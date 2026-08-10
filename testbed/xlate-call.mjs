#!/usr/bin/env node
/**
 * Interpreter rig (TRANSLATE-SPEC.md §8) — a real two-Chromium call where side
 * A's microphone is a WAV of real English speech and side B declares Spanish.
 * Measures, from B's seat: captions received, translated-audio bytes, and the
 * per-stage latencies the worker stamps on each segment (msStt / msMt / msTts).
 *
 * The /xlate WebSocket is tapped from inside each page (init script) — the
 * instrument watches the exact bytes the client saw, not a parallel guess.
 *
 *   node testbed/xlate-call.mjs [--url=http://127.0.0.1:8794] [--secs=30]
 *                               [--wavA=path] [--langA=en] [--langB=es] [--headed]
 */
import { chromium } from 'playwright-core';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const KNOWN = new Set(['url', 'secs', 'wavA', 'wavB', 'langA', 'langB', 'headed', 'room', 'button', 'vendor']);
const args = {};
for (const a of process.argv.slice(2)) {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/);
  if (!m || !KNOWN.has(m[1])) { console.error(`unknown flag: ${a}`); process.exit(2); } // unknown flags are fatal
  args[m[1]] = m[2] ?? '1';
}
const URL_BASE = args.url ?? 'http://127.0.0.1:8794';
const SECS = Number(args.secs ?? 30);
const ROOM = args.room ?? `xl-${Date.now().toString(36)}`;
const LANG_A = args.langA ?? 'en';
const LANG_B = args.langB ?? 'es';
const WAV_A = args.wavA ? resolve(HERE, args.wavA) : join(HERE, 'media', 'conv', 'A.wav');
// --wavB turns the rig two-way: B speaks too (media/conv/B.wav is the other
// side of the SAME conversation as A.wav — real interleaved turns), so both
// directions translate concurrently, which is what a real call does.
const WAV_B = args.wavB ? resolve(HERE, args.wavB) : null;
const CHROME =
  process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
if (!existsSync(WAV_A)) { console.error(`no such wav: ${WAV_A}`); process.exit(2); }

// B talks back silence: 5 s of 48 kHz s16le quiet, valid WAV.
const SILENCE = join(HERE, 'runs', 'xl-silence.wav');
{
  const n = 48000 * 5, data = n * 2;
  const b = Buffer.alloc(44 + data);
  b.write('RIFF', 0); b.writeUInt32LE(36 + data, 4); b.write('WAVEfmt ', 8);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(48000, 24); b.writeUInt32LE(96000, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  b.write('data', 36); b.writeUInt32LE(data, 40);
  writeFileSync(SILENCE, b);
}

// Tap every /xlate WebSocket the page opens. Records what THIS client saw.
const XL_TAP = `
  window.__xl = { open: 0, caps: [], tts: [], errs: [], bin: 0, binChunks: 0, firstBinAt: null, ready: 0 };
  const NativeWS = window.WebSocket;
  window.WebSocket = function (url, ...rest) {
    const ws = new NativeWS(url, ...rest);
    if (String(url).includes('/xlate')) {
      window.__xl.open++;
      window.__xl.sent = 0; window.__xl.sentBytes = 0; window.__xl.flushes = 0;
      const send0 = ws.send.bind(ws);
      ws.send = (d) => {
        if (typeof d === 'string') window.__xl.flushes++;
        else {
          window.__xl.sent++; window.__xl.sentBytes += d.byteLength ?? 0;
          if (window.__xl.sent % 20 === 1) {
            const i16 = new Int16Array(d); let s2 = 0;
            for (let i = 0; i < i16.length; i++) s2 += i16[i] * i16[i];
            (window.__xl.upRms = window.__xl.upRms ?? []).push(Math.round(Math.sqrt(s2 / i16.length)));
          }
        }
        return send0(d);
      };
      ws.addEventListener('message', (ev) => {
        const t = performance.now();
        if (typeof ev.data !== 'string') {
          const n = ev.data.byteLength ?? ev.data.size ?? 0;
          window.__xl.bin += n; window.__xl.binChunks++;
          if (window.__xl.firstBinAt == null) window.__xl.firstBinAt = t;
          return;
        }
        try {
          const m = JSON.parse(ev.data);
          if (m.type === 'cap' && m.fin) window.__xl.caps.push({ t, who: m.who, txt: m.txt, msStt: m.msStt, msMt: m.msMt, mtMode: m.mtMode });
          else if (m.type === 'tts') window.__xl.tts.push({ t, ...m });
          else if (m.type === 'xl-err') window.__xl.errs.push(m);
          else if (m.type === 'xl-ready') window.__xl.ready++;
          else if (m.type === 'xl-stat') window.__xl.stat = m;
          else if (m.type === 'cap' && !m.fin) window.__xl.partials = (window.__xl.partials ?? 0) + 1;
        } catch {}
      });
    }
    return ws;
  };
  window.WebSocket.prototype = NativeWS.prototype;
  Object.assign(window.WebSocket, NativeWS);
`;

async function launch(side, wav, lang) {
  const browser = await chromium.launch({
    executablePath: CHROME,
    headless: !args.headed,
    args: [
      // Button mode: no URL flags — the listening language must come from the
      // browser locale, exactly as it will for a real user.
      ...(args.button ? [`--lang=${lang}`] : []),
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      `--use-file-for-fake-audio-capture=${wav}`,
      '--autoplay-policy=no-user-gesture-required',
      '--alsa-output-device=null',
      '--disable-features=WebRtcHideLocalIpsWithMdns',
      `--unsafely-treat-insecure-origin-as-secure=${URL_BASE}`,
    ],
  });
  // locale must be on the CONTEXT: a --lang switch does not move
  // navigator.language in headless Chromium (measured: stayed en-US and the
  // worker correctly refused to translate a same-language pair).
  const page = await (await browser.newContext(args.button ? { locale: lang } : {})).newPage();
  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text().slice(0, 200)); });
  page.on('pageerror', (e) => errors.push('pageerror: ' + String(e.message).slice(0, 200))); // the verdict-picker lesson
  await page.addInitScript(XL_TAP);
  // --vendor=el|gemini pins the interpreter vendor (worker default otherwise).
  const vq = args.vendor ? `${args.button ? '/?' : '&'}xlvendor=${args.vendor}` : '';
  await page.goto(args.button ? `${URL_BASE}${vq}` : `${URL_BASE}/?xlate=${lang}${vq}`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#join', { timeout: 20000 });
  await page.click('#more');
  await page.fill('#room', ROOM);
  await page.keyboard.press('Escape');
  return { side, browser, page, errors };
}

console.log(`xlate rig: room=${ROOM} A=${LANG_A}(${WAV_A.split('/').pop()}) B=${LANG_B}(${WAV_B ? WAV_B.split('/').pop() : 'silence'}) ${SECS}s`);
const A = await launch('A', WAV_A, LANG_A);
const B = await launch('B', WAV_B ?? SILENCE, LANG_B);
await Promise.all([A.page.click('#join'), B.page.click('#join')]);
console.log('  join clicked on both');
if (args.button) {
  // Only A presses the globe; B must come up translated via the peer signal.
  await A.page.waitForFunction(() => document.getElementById('status')?.textContent?.length > 0);
  await new Promise((r) => setTimeout(r, 3000));
  await A.page.click('#xlate');
  console.log('  🌐 clicked on A only');
}
await new Promise((r) => setTimeout(r, SECS * 1000));

const snap = (s) => s.page.evaluate(() => window.__xl);
const [xa, xb] = await Promise.all([snap(A), snap(B)]);
const stats = (s) => s.page.evaluate(() => ({ xl: window.__xlateStats ?? null, pcm: window.__tape?.pcm ?? null }));
const [sa, sb] = await Promise.all([stats(A), stats(B)]);
const capDom = await B.page.evaluate(() => document.getElementById('xlateCaps')?.innerText ?? null);

// ── True T_tail (continuous vendor): end-of-phrase at the SPEAKER's mic →
// translated-audio burst onset (and → final caption) at the LISTENER. Both
// browsers run on this machine, so Date.now() is one clock. Pair each flush
// with the first event after it (≤6 s, consumed in order); a flush whose
// audio began BEFORE it (translation already streaming mid-phrase) pairs at
// ≤0 and is reported separately as "led" — that is the vendor being EARLY,
// not a miss.
function pairTail(flushes, events) {
  const out = []; let led = 0; let j = 0;
  for (const f of flushes ?? []) {
    while (j < (events?.length ?? 0) && events[j] < f - 300) { j++; led++; }
    if (j < (events?.length ?? 0) && events[j] - f <= 6000) { out.push(events[j] - f); j++; }
  }
  return { lags: out, led };
}
const third = (a) => a.slice(Math.floor((a.length * 2) / 3)); // quote the LAST third (latency ratchets)
function tailReport(name, flushes, ev) {
  const { lags, led } = pairTail(flushes, ev);
  if (!lags.length) return `  ${name}: no pairs (flushes ${flushes?.length ?? 0}, events ${ev?.length ?? 0}, led ${led})`;
  const q = (arr, p) => { const s = [...arr].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]; };
  const lt = third(lags);
  return `  ${name}: n=${lags.length}/${flushes?.length ?? 0} flushes (events ${ev?.length ?? 0}) ` +
    `p50 ${q(lags, 50)} p95 ${q(lags, 95)} max ${q(lags, 100)} ms` +
    `  (last third: p50 ${q(lt, 50)} max ${q(lt, 100)})  early-overlap ${led}`;
}

const q = (a, p) => (a.length ? +a[Math.min(a.length - 1, Math.floor((p / 100) * a.length))].toFixed(0) : null);
const st = (a) => { const s = [...a].sort((x, y) => x - y); return { n: s.length, p50: q(s, 50), p95: q(s, 95), max: q(s, 100) }; };

console.log('\n── B (listener) ──');
console.log(`  xlate socket opened: ${xb.open}  ready: ${xb.ready}`);
console.log(`  final captions from peer: ${xb.caps.filter((c) => c.who === 'peer').length}`);
for (const c of xb.caps.filter((c) => c.who === 'peer').slice(0, 6))
  console.log(`    [stt ${c.msStt}ms mt ${c.msMt}ms ${c.mtMode}] ${JSON.stringify(c.txt.slice(0, 90))}`);
console.log(`  translated audio: ${xb.binChunks} chunks, ${(xb.bin / 96000).toFixed(1)} s at 48k s16le`);
const starts = xb.tts.filter((t) => t.state === 'start');
console.log(`  tts segments: ${starts.length} started, ${xb.tts.filter((t) => t.state === 'fail').length} failed`);
if (starts.length) {
  console.log(`  msStt (commit→transcript): ${JSON.stringify(st(starts.map((s) => s.msStt).filter(Number.isFinite)))}`);
  console.log(`  msMt  (translate):         ${JSON.stringify(st(starts.map((s) => s.msMt).filter(Number.isFinite)))}`);
  console.log(`  msTts (→first byte):       ${JSON.stringify(st(starts.map((s) => s.msTts).filter(Number.isFinite)))}`);
  const ttail = starts.map((s) => (s.msStt ?? 0) + (s.msMt ?? 0) + (s.msTts ?? 0));
  console.log(`  T_tail server-side sum:    ${JSON.stringify(st(ttail))}  (+ uplink flush + downlink + 150ms prebuffer at the ear)`);
}
console.log(`  caption overlay now shows: ${JSON.stringify(capDom)}`);
console.log('\n── True T_tail, A speaks → B hears (cross-page wall clock) ──');
console.log(tailReport('flush→speech-onset', sa.xl?.flushTimes, sb.xl?.voiceOnsets));
console.log(tailReport('flush→final-caption', sa.xl?.flushTimes, sb.xl?.capTimes));
if (WAV_B) {
  console.log('── True T_tail, B speaks → A hears ──');
  console.log(tailReport('flush→speech-onset', sb.xl?.flushTimes, sa.xl?.voiceOnsets));
  console.log(tailReport('flush→final-caption', sb.xl?.flushTimes, sa.xl?.capTimes));
  console.log(`  A heard: ${sa.xl?.capsPeer ?? 0} captions, ${((sa.xl?.binBytes ?? 0) / 96000).toFixed(1)} s audio; last: ${JSON.stringify(sa.xl?.lastCap ?? '')}`);
}
// Law 0 sanity: translation must not have touched Lane A. These are the
// lane's own counters; a control run's numbers should look the same.
const lane = (n, p) => p
  ? `  laneA ${n}: concealedMs ${p.concealedMs ?? '?'} played ${p.playedFrames ?? '?'} recv ${p.framesRecv ?? '?'} late ${p.late ?? '?'}`
  : `  laneA ${n}: (no pcm)`;
console.log(lane('A', sa.pcm));
console.log(lane('B', sb.pcm));
if (xb.errs.length) console.log(`  xl-errs on B: ${JSON.stringify(xb.errs.slice(0, 5))}`);
console.log('\n── A (speaker) ──');
console.log(`  socket ${xa.open} ready ${xa.ready}; own-caption echoes: ${xa.caps.filter((c) => c.who === 'me').length}`);
console.log(`  uplink: ${xa.sent} chunks ${xa.sentBytes} B, flushes ${xa.flushes}`);
  console.log(`  worker stat: ${JSON.stringify(xa.stat ?? null)}`);
  console.log(`  uplink rms samples (int16): ${JSON.stringify(xa.upRms ?? [])}`);
  console.log(`  partials seen by B: ${xb.partials ?? 0}`);
const micInfo = await A.page.evaluate(async () => {
  const s = await navigator.mediaDevices.getUserMedia({ audio: true });
  const tr = s.getAudioTracks()[0];
  return { label: tr?.label, state: tr?.readyState, settings: tr?.getSettings?.() };
});
console.log(`  A mic: ${JSON.stringify(micInfo).slice(0, 200)}`);
if (xa.errs.length) console.log(`  xl-errs on A: ${JSON.stringify(xa.errs.slice(0, 5))}`);
if (A.errors.length) console.log(`  A page errors: ${A.errors.slice(0, 5).join(' | ')}`);
if (B.errors.length) console.log(`  B page errors: ${B.errors.slice(0, 5).join(' | ')}`);

await Promise.all([A.browser.close(), B.browser.close()]);
const capsOk = xb.caps.filter((c) => c.who === 'peer').length > 0;
const audioOk = xb.bin > 96000; // >1 s of translated speech arrived
// Two-way: the A-hears-B direction must ALSO deliver, or the run only proved
// half a call.
const backOk = !WAV_B || ((sa.xl?.capsPeer ?? 0) > 0 && (sa.xl?.binBytes ?? 0) > 96000);
console.log(`\nverdict: captions ${capsOk ? 'OK' : 'MISSING'}, translated audio ${audioOk ? 'OK' : 'MISSING'}${WAV_B ? `, reverse direction ${backOk ? 'OK' : 'MISSING'}` : ''}`);
process.exit(capsOk && audioOk && backOk ? 0 : 1);
