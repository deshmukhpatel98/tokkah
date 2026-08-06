/**
 * Interpreter client (TRANSLATE-SPEC.md) — the whole feature in one module.
 *
 * Enabled by `?xlate=<my-language>` (e.g. ?xlate=en, ?xlate=es). app.js calls
 * start() once, after `welcome` (role known) with the live mic stream. From
 * then on this module is self-contained: its own worklets, its own WS to
 * /api/room/:code/xlate, its own captions overlay. Law 0: nothing in here can
 * touch signaling, the peer connections, or Lane A — kill this module mid-call
 * and the call is bit-identical to today.
 *
 * Uplink: mic → xlate-tap worklet (16 kHz s16le, 100 ms binary chunks +
 * {flush} on quiet) → WS. Downlink: JSON captions + binary 48 kHz s16le
 * translated speech → xlate-play worklet → destination.
 */

import { audioContext, addWorkletModule } from './onset-monitor.js';

export async function start({ stream, room, role, lang, tel }) {
  const ctx = await audioContext();
  await addWorkletModule(ctx, './xlate-worklet.js');

  const tap = new AudioWorkletNode(ctx, 'xlate-tap', { numberOfInputs: 1, numberOfOutputs: 0 });
  const src = ctx.createMediaStreamSource(stream);
  src.connect(tap);

  const play = new AudioWorkletNode(ctx, 'xlate-play', { numberOfInputs: 0, outputChannelCount: [1] });
  const gain = ctx.createGain();
  gain.gain.value = 1.0;
  play.connect(gain).connect(ctx.destination);

  // ── captions overlay ──────────────────────────────────────────────────────
  const ui = document.createElement('div');
  ui.id = 'xlateCaps';
  ui.style.cssText =
    'position:fixed;left:50%;bottom:12vh;transform:translateX(-50%);max-width:80vw;' +
    'z-index:60;pointer-events:none;text-align:center;font:500 clamp(16px,2.4vw,24px)/1.35 system-ui;';
  const live = document.createElement('div'); // peer's in-flight source text, faint
  live.style.cssText = 'opacity:.55;color:#fff;text-shadow:0 1px 4px #000;min-height:1.2em;';
  const fin = document.createElement('div');  // translated caption, prominent
  fin.style.cssText = 'color:#fff;text-shadow:0 1px 4px #000;background:rgba(0,0,0,.45);' +
    'border-radius:10px;padding:.25em .6em;display:inline-block;';
  fin.textContent = '';
  ui.append(live, fin);
  document.body.appendChild(ui);
  let finTimer = 0;
  const showFin = (txt) => {
    fin.textContent = txt;
    fin.style.display = txt ? 'inline-block' : 'none';
    clearTimeout(finTimer);
    if (txt) finTimer = setTimeout(() => { fin.style.display = 'none'; }, 7000);
  };
  showFin('');

  // ── socket ────────────────────────────────────────────────────────────────
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  // Vendor is the Worker's choice (Gemini Live Translate when its key exists);
  // ?xlvendor=el forces the legacy ElevenLabs pipeline for A/B runs.
  const xlv = new URLSearchParams(location.search).get('xlvendor');
  const ws = new WebSocket(
    `${proto}//${location.host}/api/room/${encodeURIComponent(room)}/xlate?role=${role}&lang=${encodeURIComponent(lang)}` +
    (xlv ? `&vendor=${encodeURIComponent(xlv)}` : ''),
  );
  ws.binaryType = 'arraybuffer';
  const log = (kind, data) => tel?.log?.(kind, data);
  let segStarted = new Map(); // seg → perf.now() at tts start marker

  // Debug surface, same contract as window.__tape: counters a rig can read
  // over ANY driver (safaridriver has executeScript but no init-script
  // injection, so an in-page tap cannot be installed there — this can).
  const xs = (window.__xlateStats = {
    open: 0, ready: 0, capsPeer: 0, capsMe: 0, partials: 0,
    ttsStart: 0, ttsEnd: 0, ttsFail: 0, binChunks: 0, binBytes: 0,
    played: 0, errs: [], lastCap: '', flushes: 0, flushTimes: [], burstTimes: [], capTimes: [],
    voiceOnsets: [], _voiced: false, _lastVoicedAt: 0,
  });
  let lastBinAt = 0;

  ws.onopen = () => { xs.open++; log('xlate-open', { lang }); };
  ws.onclose = (e) => { log('xlate-close', { code: e.code }); live.textContent = ''; };
  ws.onerror = () => log('xlate-ws-error', {});
  let pend = new Uint8Array(0); // TTS chunks split mid-sample — carry the odd byte
  ws.onmessage = (ev) => {
    if (typeof ev.data !== 'string') {
      // translated speech: s16le 48k → float
      const now = Date.now();
      xs.binChunks++; xs.binBytes += ev.data.byteLength ?? 0;
      // A burst boundary (>600 ms of downlink quiet) marks a segment onset on
      // a bursty vendor. Gemini streams CONTINUOUS audio (silence included,
      // measured 2026-08-06: 97.5 s of PCM in a 100 s run, one gap), so the
      // perceptual onset needs ENERGY: voiceOnsets stamps quiet→voiced
      // transitions in the received samples — the moment translated SPEECH
      // reaches this ear, which is what T_tail means to a person.
      if (now - lastBinAt > 600) xs.burstTimes.push(now);
      lastBinAt = now;
      {
        const i16v = new Int16Array(ev.data.slice(0), 0, Math.min(ev.data.byteLength >> 1, 24000));
        let s2 = 0;
        for (let i = 0; i < i16v.length; i++) s2 += i16v[i] * i16v[i];
        const voiced = Math.sqrt(s2 / (i16v.length || 1)) > 300;
        if (voiced && now - (xs._lastVoicedAt ?? 0) > 600) xs.voiceOnsets.push(now);
        if (voiced) xs._lastVoicedAt = now;
        xs._voiced = voiced;
      }
      const raw = new Uint8Array(ev.data);
      const all = new Uint8Array(pend.length + raw.length);
      all.set(pend); all.set(raw, pend.length);
      const even = all.length & ~1;
      pend = all.slice(even);
      const i16 = new Int16Array(all.buffer, 0, even >> 1);
      const f = new Float32Array(i16.length);
      for (let i = 0; i < i16.length; i++) f[i] = i16[i] / 32768;
      play.port.postMessage(f.buffer, [f.buffer]);
      return;
    }
    let m; try { m = JSON.parse(ev.data); } catch { return; }
    if (m.type === 'cap') {
      if (!m.fin) { xs.partials++; live.textContent = m.txt; return; }
      live.textContent = '';
      if (m.who === 'peer') {
        xs.capsPeer++; xs.lastCap = m.txt.slice(0, 160); xs.capTimes.push(Date.now());
        showFin(m.txt);
        log('xlate-cap', { seg: m.seg, msStt: m.msStt ?? null, msMt: m.msMt ?? null, mtMode: m.mtMode, chars: m.txt.length });
      } else xs.capsMe++;
    } else if (m.type === 'tts') {
      if (m.state === 'start') {
        xs.ttsStart++;
        segStarted.set(m.seg, performance.now());
        // T_tail as the far side experiences it: commit → first translated
        // audio bytes at this client (playout prebuffer adds 150 ms on top).
        log('xlate-tts', { seg: m.seg, msStt: m.msStt ?? null, msMt: m.msMt ?? null, msTts: m.msTts ?? null });
      } else if (m.state === 'end') {
        xs.ttsEnd++;
        log('xlate-tts-end', { seg: m.seg, bytes: m.bytes, ms: m.ms });
      } else if (m.state === 'fail') {
        xs.ttsFail++;
        log('xlate-tts-fail', { seg: m.seg }); // captions already shown — degraded, not stalled
      }
    } else if (m.type === 'xl-err') {
      xs.errs.push({ where: m.where, e: (m.e ?? '').slice?.(0, 120) ?? null });
      log('xlate-err', { where: m.where, e: m.e ?? null });
    } else if (m.type === 'xl-ready') {
      xs.ready++;
      log('xlate-ready', { lang: m.lang });
    }
  };

  tap.port.onmessage = (e) => {
    if (ws.readyState !== WebSocket.OPEN) return;
    if (e.data?.flush) {
      // The sender half of the true-T_tail pairing: wall time of our own
      // end-of-phrase, matched by the rig against the peer's burst onsets.
      xs.flushes++; xs.flushTimes.push(Date.now());
      ws.send(JSON.stringify({ type: 'flush' }));
      return;
    }
    ws.send(e.data); // ArrayBuffer, 100 ms of 16 kHz s16le
  };

  return {
    stop() {
      try { ws.close(); } catch { /* gone */ }
      try { src.disconnect(); tap.disconnect(); play.disconnect(); gain.disconnect(); } catch { /* partial */ }
      ui.remove();
    },
  };
}
