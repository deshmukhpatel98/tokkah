/**
 * Two real browsers, real recorded speech, one real WebRTC call, no human present.
 *
 * Each Chrome instance is given a WAV file as its microphone via
 * `--use-file-for-fake-audio-capture`, so the audio goes through the genuine path:
 * getUserMedia → Chrome's audio processing → Opus → the network → the jitter buffer →
 * decode → the app's AudioWorklet detector. Nothing about the media path is simulated.
 *
 * A useful accident of the app's design makes this precise: the lobby preview asks for
 * *video only*, and the microphone is acquired at join time. Chrome starts reading the
 * WAV when capture starts, so clicking Join on both browsers in the same tick starts
 * both files within a few milliseconds of each other. The 22 s of room tone at the head
 * of each fixture then covers connection setup.
 *
 * Usage:
 *   node call.mjs                                  baseline, our constraints
 *   node call.mjs --ns                             force noiseSuppression + AEC + AGC on
 *   node call.mjs --relay                          force media through a TURN relay
 *   node call.mjs --url=https://…workers.dev       run against real Cloudflare
 *   node call.mjs --headed                         watch it happen
 */

import { chromium } from 'playwright-core';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startNetsim, startP2PSim } from './netsim.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const CHROME =
  process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');

const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    // Split on the FIRST '=' only. Splitting on all of them silently truncated any value that
    // contained one — `--q=res=720&codec=vp8` arrived as `q: "res"`, so a four-arm codec matrix
    // ran the same default configuration four times and looked like a real result.
    const body = a.replace(/^--/, '');
    const i = body.indexOf('=');
    return i === -1 ? [body, true] : [body.slice(0, i), body.slice(i + 1)];
  }),
);

const URL_BASE = args.url ?? 'http://127.0.0.1:8794';
// `--trace` asks the app for the full 20 Hz level trace instead of the decimated 4 Hz one.
// Needed to see a floor that is briefly wrong: at 4 Hz a jitter-buffer underrun falls
// between samples. Costs ~20× the log volume, so it is opt-in.
// Extra query string for the page under test, e.g. --q=res=1080&codec=h264. Lets one driver
// A/B app-level settings without editing the app between arms.
const EXTRA_Q = args.q ? String(args.q).replace(/^\?/, '') : '';
const PAGE_URL =
  args.trace || EXTRA_Q
    ? `${URL_BASE}/?${[args.trace ? 'trace=1' : '', EXTRA_Q].filter(Boolean).join('&')}`
    : URL_BASE;
// Emulated distance. `--rtt` is the round trip we want ICE to measure; netsim.mjs turns it
// into a per-crossing delay in front of a local TURN relay. Zero means no simulator at all,
// so the default run stays exactly as it was.
// ── REALISM PROFILES, AND WHY BARE --rtt IS NOW AN ERROR ────────────────────
// `--rtt` on its own leaves jitter 0, loss 0 and bandwidth unlimited: a
// CONSTANT-DELAY PIPE, which is not a network and does not exist anywhere on
// earth. A whole distance sweep was run that way and reported as "how far can a
// call go" — every number optimistic by an unknown margin, because the one thing
// a jitter buffer exists to absorb had been removed from the test.
//
// The knobs were always here. The failure was that the artificial condition was
// the DEFAULT and cost nothing to reach, so it got reached. It now has to be
// asked for by name, and the profile is stamped into the run tag so a number can
// never be quoted without the conditions that produced it.
//
// The profile values are representative, NOT measured by this project — they are
// the honest part of a simulation and are labelled so. `real` is a long
// intercontinental leg on decent fixed line; `mobile` is a 4G handset; `poor` is
// the congested wifi most complaints come from.
const NET_PROFILES = {
  // MODEL, not just magnitude. netsim's default jitter is UNIFORM — every delay
  // equally likely inside a band — and real network jitter is nothing like that.
  // It is heavy-tailed: mostly punctual with occasional large excursions, and the
  // excursions are the entire reason a jitter buffer exists. A uniform band with
  // the same mean is the second way this rig was flattering itself, after the
  // constant-delay pipe. 'heavy' is netsim's exponential model, capped at 8x.
  real:     { jitter: 8,  loss: 0.3, bw: 0, model: 'heavy', note: 'intercontinental fixed line' },
  mobile:   { jitter: 30, loss: 1.0, bw: 3, model: 'heavy', note: '4G handset' },
  poor:     { jitter: 20, loss: 0.5, bw: 5, model: 'heavy', note: 'congested wifi' },
  puredelay:{ jitter: 0,  loss: 0,   bw: 0, model: 'uniform', note: 'ARTIFICIAL: constant delay, no network' },
};
const NET = args.net ? String(args.net) : null;
if (NET && !NET_PROFILES[NET]) {
  console.error(`unknown --net=${NET}. known: ${Object.keys(NET_PROFILES).join(' ')}`);
  process.exit(2);
}
const PROF = NET ? NET_PROFILES[NET] : null;
const SIM_RTT = Number(args.rtt ?? 0);
const SIM_JITTER = Number(args.jitter ?? PROF?.jitter ?? 0);
const SIM_LOSS = Number(args.loss ?? PROF?.loss ?? 0);
const SIM_JMODEL = args.jittermodel ?? PROF?.model ?? 'uniform';
if (SIM_RTT > 0 && !NET && args.jitter === undefined && args.loss === undefined) {
  console.error(
    `\n--rtt=${SIM_RTT} with no jitter and no loss is a CONSTANT-DELAY PIPE, not a network.\n`
    + 'Numbers from it are optimistic by an unknown margin and must not be quoted as\n'
    + 'real-world latency. Pick a profile:\n'
    + Object.entries(NET_PROFILES).map(([k, v]) =>
        `  --net=${k.padEnd(10)} jitter ${String(v.jitter).padStart(2)} ms, loss ${v.loss}%`
        + `${v.bw ? `, ${v.bw} Mbps` : ''}   (${v.note})`).join('\n')
    + '\n\nOr pass --jitter=/--loss= explicitly. --net=puredelay opts into the artificial\n'
    + 'case on purpose, and stamps it into the run tag so nobody quotes it by mistake.\n');
  process.exit(2);
}
// A capacity ceiling in Mbps, per participant per direction, and how much the bottleneck may
// queue before it tail-drops. `--bw` alone is enough to make a run simulated: a slow link with
// no added delay or loss is a perfectly real condition and the most common one users hit.
const SIM_BW = Number(args.bw ?? PROF?.bw ?? 0);
const SIM_QUEUE = Number(args.queue ?? 100);
// `--p2psim` emulates distance by rewriting candidates instead of routing through node-turn.
// The relay is the ~40 s cliff, so this is the only way to take a trustworthy long run.
const P2P = !!args.p2psim;
const SIMULATED = SIM_RTT > 0 || SIM_JITTER > 0 || SIM_LOSS > 0 || SIM_BW > 0;
const CONV = join(HERE, 'media', args.conv ?? 'conv');
const ROOM = args.room ?? `bot-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
const TAG =
  args.tag ??
  (args.ns ? 'ns-on' : args.relay ? 'relay'
    // The conditions travel WITH the run. A tag of "rtt260" says nothing about
    // whether that run saw a network or a delay line.
    : SIMULATED ? `rtt${SIM_RTT}-${NET ?? 'custom'}-j${SIM_JITTER}${SIM_JMODEL === 'heavy' ? 'h' : ''}-l${SIM_LOSS}${SIM_BW ? `-bw${SIM_BW}` : ''}`
    : 'baseline');
const OUTDIR = join(HERE, 'runs', `${TAG}-${ROOM}`);
const HEADED = !!args.headed;
// `--realcam[=a|b]`: real camera + real mic instead of fake devices, on both sides
// or one. The one latency component the fake camera cannot show is the capture-side
// sensor/ISP/driver depth (§19.1 ladder) — cap→read reads ~0.2 ms on a fake device
// by construction. fake-ui still auto-accepts the permission prompt; macOS TCC must
// already trust the Chrome binary (run --headed once if the OS prompt appears).
// Two real cameras on one machine share the sensor AND the CPU — a one-sided arm
// (realcam=a) is the clean sender measurement.
const realcamFor = (side) => args.realcam === true || String(args.realcam).toLowerCase() === side.toLowerCase();

const truth = JSON.parse(readFileSync(join(CONV, 'truth.json'), 'utf8'));
// Let the whole fixture play, plus slack for setup and the final turn's tail.
const RUN_MS = Number(args.ms ?? truth.totalMs + 12000);

const log = (s) => console.log(s);

// ── Init scripts, injected before any page code runs ─────────────────────────
// The point of overriding rather than editing the app is that both arms of an A/B run
// the *same* shipping code. If the app itself were switched, a difference in result
// could be a difference in the app.
const FORCE_PROCESSING = `
  // Reproduce what every other conferencing product does: full audio processing on.
  // This is the arm of the experiment that should destroy the breath.
  const orig = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
  navigator.mediaDevices.getUserMedia = (c) => {
    if (c && c.audio && typeof c.audio === 'object') {
      c = { ...c, audio: { ...c.audio,
        echoCancellation: true, noiseSuppression: true, autoGainControl: true } };
      window.__forcedProcessing = true;
    }
    return orig(c);
  };
`;

// `servers` replaces the app's ICE configuration when the network simulator is running, so
// media goes through the relay we control rather than whichever one /api/ice hands out.
// Passing null keeps the app's own servers and only forces relay-only candidates.
const forceRelay = (servers) => `
  // Media must traverse a real TURN relay rather than going host-to-host over
  // loopback, which is the only way to get real network distance into the media path
  // from one machine.
  const OrigPC = window.RTCPeerConnection;
  const SIM_SERVERS = ${servers ? JSON.stringify(servers) : 'null'};
  window.RTCPeerConnection = function (cfg, ...rest) {
    const c = { ...(cfg || {}), iceTransportPolicy: 'relay' };
    if (SIM_SERVERS) c.iceServers = SIM_SERVERS;
    window.__forcedRelay = true;
    return new OrigPC(c, ...rest);
  };
  window.RTCPeerConnection.prototype = OrigPC.prototype;
`;

// Emulated distance without a TURN relay: rewrite every *remote* candidate so it points at a
// delay proxy that fronts the peer, and the peer's real address is never learned. See
// `startP2PSim` in netsim.mjs for why the relay had to go — it, not the transport, is the ~40 s
// cliff, so any run longer than that had harness-contaminated loss.
//
// This patches `addIceCandidate` rather than the signalling layer, so it works without the app
// knowing anything about it. `__simProxy` is exposed from Node and returns the proxy port to use.
const P2P_REWRITE = `
  const OrigPC = window.RTCPeerConnection;
  window.__rewrites = [];
  // candidate:FOUND COMPONENT udp PRIORITY IP PORT typ host ...
  //   fields:  0             1         2   3        4  5
  const rewrite = async (line) => {
    const f = String(line).split(' ');
    if (f.length < 7 || !/^udp$/i.test(f[2])) return null;   // TCP candidates carry no media here
    const ip = f[4], port = Number(f[5]);
    if (!ip || !Number.isFinite(port) || port <= 0) return null;
    const np = await window.__simProxy(ip, port);
    if (!np) return null;
    f[5] = String(np);
    window.__rewrites.push({ from: ip + ':' + port, to: ip + ':' + np, typ: f[7] || '?' });
    return f.join(' ');
  };
  class SimPC extends OrigPC {
    async addIceCandidate(cand) {
      try {
        const line = typeof cand === 'string' ? cand : cand && cand.candidate;
        // An empty candidate is the end-of-candidates signal and must pass through untouched.
        if (line) {
          const out = await rewrite(line);
          if (out) {
            const init = typeof cand === 'string'
              ? out
              : { candidate: out, sdpMid: cand.sdpMid, sdpMLineIndex: cand.sdpMLineIndex,
                  usernameFragment: cand.usernameFragment };
            return super.addIceCandidate(init);
          }
        }
      } catch (e) { window.__rewrites.push({ error: String(e).slice(0, 120) }); }
      return super.addIceCandidate(cand);
    }
    async setRemoteDescription(desc) {
      // Chrome sometimes ships candidates inside the SDP rather than trickling them. Those
      // would be a direct path around the delay line, so they need the same treatment — and
      // missing them would show up as a run that reports 80 ms while measuring 0.
      try {
        const sdp = desc && desc.sdp;
        if (sdp && /^a=candidate:/m.test(sdp)) {
          const lines = sdp.split(/\\r?\\n/);
          for (let i = 0; i < lines.length; i++) {
            if (!lines[i].startsWith('a=candidate:')) continue;
            const out = await rewrite(lines[i].slice(2));
            if (out) lines[i] = 'a=' + out;
          }
          return super.setRemoteDescription({ type: desc.type, sdp: lines.join('\\r\\n') });
        }
      } catch (e) { window.__rewrites.push({ error: 'sdp ' + String(e).slice(0, 100) }); }
      return super.setRemoteDescription(desc);
    }
  }
  window.RTCPeerConnection = SimPC;
`;

// Records every constraint set actually handed to getUserMedia, so the run's own log
// says what processing was in effect instead of relying on the flag that was passed.
const RECORD_CONSTRAINTS = `
  window.__gum = [];
  const o = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
  navigator.mediaDevices.getUserMedia = async (c) => {
    const s = await o(c);
    try {
      window.__gum.push({ req: JSON.parse(JSON.stringify(c)),
        got: s.getTracks().map((t) => ({ kind: t.kind, label: t.label, settings: t.getSettings() })) });
    } catch {}
    return s;
  };
`;

async function launch(side, wav) {
  const browser = await chromium.launch({
    executablePath: CHROME,
    headless: !HEADED,
    args: [
      '--use-fake-ui-for-media-stream',
      ...(realcamFor(side)
        ? []
        : [
            '--use-fake-device-for-media-stream',
            // A real video file as the camera, the same trick as the WAV-as-microphone above.
            // Chrome's synthetic fake camera is a near-static rolling pattern that any encoder
            // compresses to a few hundred kbps, so it cannot tell you whether a bitrate ceiling is
            // honoured or whether quality is being limited — the two things the video path is about.
            // A Y4M of real (or high-entropy) content can, because it actually demands the bits.
            // The testing-realism law (2026-08-11): the DEFAULT camera is a
            // real talking head (media/real/fetch.sh), not Chrome's rolling
            // pattern — an explicit --video= still overrides for bandwidth
            // fixtures.
            `--use-file-for-fake-video-capture=${args.video ?? decodeURIComponent(new URL('./media/real/realA.mjpeg', import.meta.url).pathname)}`,
            `--use-file-for-fake-audio-capture=${wav}`,
          ]),
      '--autoplay-policy=no-user-gesture-required',
      // Without this, headless Chrome may not run the audio render pipeline at all,
      // and the received-audio detector would see silence for the wrong reason.
      '--alsa-output-device=null',
      '--disable-features=WebRtcHideLocalIpsWithMdns',
      `--unsafely-treat-insecure-origin-as-secure=${URL_BASE}`,
      '--allow-running-insecure-content',
    ],
  });
  const page = await browser.newPage();
  const errors = [];
  const netFails = [];
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push(m.text().slice(0, 300));
  });
  page.on('pageerror', (e) => errors.push('pageerror: ' + String(e.message).slice(0, 300)));
  // "404 Not Found" in a console message does not say *what* 404'd, which makes it
  // impossible to tell a missing favicon from a missing module.
  page.on('response', (r) => {
    if (r.status() >= 400) netFails.push(`${r.status()} ${r.url()}`);
  });
  page.on('requestfailed', (r) => netFails.push(`failed ${r.url()} — ${r.failure()?.errorText ?? '?'}`));

  // Capture the room's logToken from the signaling welcome (worker hardening,
  // task #32: GET /log and /summary now require ?token=). A 'message' listener
  // on a WebSocket subclass sees the welcome no matter what handler the app
  // itself sets, and older workers simply never set the field — the harvest
  // then falls back to a tokenless request.
  await page.addInitScript(`
    (() => {
      const NativeWS = window.WebSocket;
      window.WebSocket = class extends NativeWS {
        constructor(url, protocols) {
          super(url, protocols);
          this.addEventListener('message', (ev) => {
            try {
              const m = JSON.parse(ev.data);
              if (m && m.type === 'welcome' && m.logToken) window.__tapeLogToken = m.logToken;
            } catch {}
          });
        }
      };
    })();
  `);
  // Order matters: record last so it wraps whatever the override installed.
  if (args.ns) await page.addInitScript(FORCE_PROCESSING);
  // Two mutually exclusive ways to get distance into the media path. Candidate rewriting keeps
  // the P2P path and needs no relay; forcing relay-only is mandatory for the TURN route,
  // because a host candidate over loopback would bypass the delay line and the run would
  // silently measure nothing.
  if (P2P && sim) {
    await page.exposeFunction('__simProxy', async (h, p) => sim.portFor(h, p));
    await page.addInitScript(P2P_REWRITE);
  } else if (args.relay || SIMULATED) {
    await page.addInitScript(forceRelay(sim?.iceServers ?? null));
  }
  await page.addInitScript(RECORD_CONSTRAINTS);

  await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#join', { timeout: 20000 });
  // The named-room field moved into the lobby setup sheet (••• ) when the first
  // screen became one button. Open it, type, close — the same three moves a
  // person makes.
  await page.click('#more');
  await page.fill('#room', ROOM);
  await page.keyboard.press('Escape');
  return { side, browser, page, errors, netFails };
}

// ── Run ──────────────────────────────────────────────────────────────────────
// The simulator must exist before the browsers launch, because its TURN address is baked
// into their init script. A distinct port per run lets two runs overlap.
const sim = !SIMULATED
  ? null
  : P2P
    ? // One crossing per direction, so the full one-way delay goes here and loss is not
      // compounded — both corrections the TURN path needs and this one does not.
      await startP2PSim({
        oneWayMs: SIM_RTT / 2,
        jitterMs: SIM_JITTER,
        jitterModel: SIM_JMODEL,
        lossPct: SIM_LOSS,
        bwMbps: SIM_BW,
        queueMs: SIM_QUEUE,
      })
    : await startNetsim({
        oneWayMs: SIM_RTT / 2,
        jitterMs: SIM_JITTER,
        jitterModel: SIM_JMODEL,
        lossPct: SIM_LOSS,
        bwMbps: SIM_BW,
        queueMs: SIM_QUEUE,
        turnPort: 3478 + (Number(process.pid) % 500),
      });

log(`\n${'═'.repeat(68)}`);
log(`  ${TAG}   room ${ROOM}`);
log(`  ${URL_BASE}`);
log(`  fixture: ${truth.turns.length} turns, ${truth.turns.filter((t) => t.withBreath).length} with a real inhale`);
log(`  ${args.ns ? 'AEC + NS + AGC FORCED ON (the control arm)' : 'raw audio — all processing off (our config)'}`);
if (args.relay && !SIMULATED) log(`  media forced through a TURN relay`);
if (SIMULATED) {
  log(
    `  network simulator: ${SIM_RTT} ms RTT, ${SIM_JITTER} ms jitter, ${SIM_LOSS}% loss, ` +
      (SIM_BW ? `${SIM_BW} Mbps ceiling with ${SIM_QUEUE} ms of queue` : 'no bandwidth ceiling'),
  );
  log(
    P2P
      ? `  no relay — remote candidates rewritten onto delay lines` +
          `   — ICE should measure about ${sim.expectedRttMs} ms`
      : `  relay 127.0.0.1:${sim.turnPort} via delay line :${sim.proxyPort}` +
          `   — ICE should measure about ${sim.expectedRttMs} ms`,
  );
}
log(`${'═'.repeat(68)}\n`);

// wav overrides resolve against THIS directory: Chrome resolves a relative
// --use-file-for-fake-audio-capture against its own cwd, which is neither the
// testbed's nor stable — a missing file silently becomes the default fake
// beep (measured, opust-mode-off arm 1: capture reported 44100 Hz/2ch).
const A = await launch('A', args.wavA ? resolve(HERE, args.wavA) : join(CONV, 'A.wav'));
const B = await launch('B', args.wavB ? resolve(HERE, args.wavB) : join(CONV, 'B.wav'));
log('  both browsers up, lobby loaded');

// Join in the same tick so the two WAVs — and therefore the two timelines — start
// together. Skew is measured afterwards rather than assumed away.
const t0 = Date.now();
await Promise.all([A.page.click('#join'), B.page.click('#join')]);
log('  join clicked on both');

// Connection is up when the app's own peer connection says so.
const connected = async (p, ms) => {
  try {
    await p.page.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: ms });
    return true;
  } catch {
    return false;
  }
};
const [ca, cb] = await Promise.all([connected(A, 45000), connected(B, 45000)]);
const tConn = Date.now() - t0;
log(`  connected: A=${ca} B=${cb} after ${tConn} ms`);

// #21 spectrum tap: raw PCM off the decoded remote stream, so the encoder's
// bandpass can be read off the FAR end rather than inferred from SDP.
// AnalyserNode is DEAF on this graph (measured across opus2–opus6: -58 dB
// direct, -61 dB on a clone track, while the app's AudioWorkletNode hears
// the same stream at -18 dB). The worklet is the node type that demonstrably
// pulls — so the tap is a capture worklet and the FFT happens in Node.
if (args.spectap) {
  for (const [name, s] of [['A', A], ['B', B]]) {
    const ok = await s.page.evaluate(async () => {
      const el = document.getElementById('remoteAudio');
      if (!el?.srcObject) return false;
      // A probe-created AudioContext has no user gesture and stays suspended
      // (measured: -100 dB floor on a stream the app's own detector heard
      // fine). The app's context was created inside the join click — running.
      const ac = await window.__tape.audioCtx;
      if (!ac || ac.state !== 'running') return false;
      // Wait for the remote track to unmute before arming — it reads muted
      // during the first second or two of every run (startup transient).
      const at = el.srcObject.getAudioTracks()[0];
      const mutedAtArm = at?.muted ?? null;
      if (at?.muted) {
        await new Promise((res) => {
          const t = setTimeout(res, 8000);
          at.addEventListener('unmute', () => { clearTimeout(t); res(); }, { once: true });
        });
      }
      await ac.audioWorklet.addModule('/spec-worklet.js');
      const src = ac.createMediaStreamSource(el.srcObject);
      const node = new AudioWorkletNode(ac, 'spec-capture', { numberOfOutputs: 0 });
      // No destination connect: mirrors onset-monitor.js attachDetector, the
      // pattern measured to pull this exact stream.
      src.connect(node);
      const tap = { sampleRate: ac.sampleRate, pcm: [], blocks: 0, diag: { acState: ac.state, mutedAtArm, unmutedAt: at?.muted === false ? 'armed-unmuted' : 'waited' } };
      node.port.onmessage = (e) => { tap.pcm.push(e.data); tap.blocks++; };
      window.__specTap = tap;
      return true;
    }).catch((e) => { log(`  spectap on ${name} threw: ${e?.message ?? e}`); return false; });
    log(`  spectap on ${name}: ${ok ? 'armed (worklet)' : 'NO remoteAudio stream'}`);
  }
}

if (!ca || !cb) {
  for (const s of [A, B]) {
    const st = await s.page.evaluate(() => ({
      status: document.getElementById('status')?.textContent,
      joinStatus: document.getElementById('joinStatus')?.textContent,
      ice: window.__tape?.pc?.iceConnectionState,
      conn: window.__tape?.pc?.connectionState,
    })).catch(() => null);
    log(`  ${s.side}: ${JSON.stringify(st)}`);
    if (s.errors.length) log(`  ${s.side} errors: ${s.errors.slice(0, 4).join(' | ')}`);
  }
}

// Let the conversation play out. Progress ticks make a 100 s wait legible.
const started = Date.now();
let lastLine = '';
while (Date.now() - started < RUN_MS) {
  await new Promise((r) => setTimeout(r, 5000));
  const el = Math.round((Date.now() - started) / 1000);
  const snap = await A.page
    .evaluate(() => {
      const s = window.__tape?.turns?.summary?.();
      const ons = window.__tape?.tel?.mirror?.filter((e) => e.kind === 'onset') ?? [];
      const cls = ons.filter((e) => e.data?.type === 'classified');
      return {
        total: s?.total ?? 0, usable: s?.usable ?? 0,
        human: s?.humanMedian, perceived: s?.perceivedMedian,
        lead: s?.leadMedian, breath: s?.breathRate, breathLocal: s?.breathRateLocal,
        localOn: ons.filter((e) => e.data?.side === 'local' && e.data?.type === 'onset').length,
        remoteOn: ons.filter((e) => e.data?.side === 'remote' && e.data?.type === 'onset').length,
        localBreath: cls.filter((e) => e.data?.side === 'local' && e.data?.kind === 'breath').length,
        remoteBreath: cls.filter((e) => e.data?.side === 'remote' && e.data?.kind === 'breath').length,
      };
    })
    .catch(() => null);
  if (snap) {
    const line =
      `  ${String(el).padStart(3)}s  onsets local ${snap.localOn} / remote ${snap.remoteOn}` +
      `   breath-classified local ${snap.localBreath} / remote ${snap.remoteBreath}` +
      `   turns ${snap.usable}/${snap.total}` +
      `   human ${snap.human ?? '—'}  perceived ${snap.perceived ?? '—'}  lead ${snap.lead ?? '—'}`;
    if (line.slice(6) !== lastLine) { log(line); lastLine = line.slice(6); }
  }
}

// ── Collect ──────────────────────────────────────────────────────────────────
const grab = async (s) =>
  s.page.evaluate(async () => {
    const t = window.__tape;
    // The analyser holds recent events to put them back in order; without this the
    // tail of every run would be missing its last transitions.
    t?.turns?.flush?.();
    return {
      summary: t?.turns?.summary?.() ?? null,
      transitions: t?.turns?.transitions ?? [],
      leads: t?.turns?.leads ?? null,
      events: t?.tel?.mirror ?? [],
      health: t?.tel?.health ?? null,
      stats: t?.stats ?? null,
      // The custom video lane is invisible to getStats() — WebRTC sees datachannel
      // bytes and nothing else — so these counters are the only instrument for it.
      tapeVideo: t?.video ?? null,
      tapeMode: t?.tapeMode ?? null,
      // Lane A (lossless PCM audio) is likewise invisible to getStats() —
      // with the lane on, the pc carries no audio track at all.
      pcmAudio: t?.pcm ?? null,
      // Reconnects. Read straight off the window, because the previous attempt to
      // count these grepped the driver's stdout and found 0 at both rtt=180 and
      // rtt=300 -- the status text lives in the DOM, so the instrument could not
      // see the event and reported the same number either way.
      recovers: (typeof window !== 'undefined' && window.__recoverStats) || null,
      // §10 session-clock sync (offset/drift/epoch) — null when the bundle is off.
      timesync: t?.timesync ?? null,
      // Lane 0 (§3.1 levers 3+4): app-side policy counters; wire counters ride
      // in pcmAudio (pred/pad), yield counters in tapeVideo (l0*).
      lane0: t?.lane0 ?? null,
      // §12–13 stall machine: app-side HOLD state (video regime + lane-P
      // counters ride in tapeVideo.stall).
      stall: t?.stall ?? null,
      gum: window.__gum ?? [],
      specTap: (() => {
        const t = window.__specTap;
        if (!t) return null;
        // Concat the worklet's PCM blocks and ship as base64 — CDP mangles
        // multi-megabyte typed arrays on return, a string survives intact.
        let total = 0;
        for (const c of t.pcm) total += c.length;
        const pcm = new Float32Array(total);
        let o = 0;
        for (const c of t.pcm) { pcm.set(c, o); o += c.length; }
        const u8 = new Uint8Array(pcm.buffer);
        let bin = '';
        for (let i = 0; i < u8.length; i += 65536) bin += String.fromCharCode.apply(null, u8.subarray(i, i + 65536));
        return { sampleRate: t.sampleRate, blocks: t.blocks, b64: btoa(bin), diag: t.diag };
      })(),
      forcedProcessing: !!window.__forcedProcessing,
      forcedRelay: !!window.__forcedRelay,
      pc: { conn: t?.pc?.connectionState, ice: t?.pc?.iceConnectionState },
      // Post-mortem negotiation state, collected after the run — the answerer-carrier
      // race lives inside the signaling window, so it must be observed from the final
      // state, never probed mid-flight.
      transceivers: (t?.pc?.getTransceivers?.() ?? []).map((tr) => ({
        mid: tr.mid, dir: tr.direction, cur: tr.currentDirection, stopped: tr.stopped,
        rkind: tr.receiver?.track?.kind ?? null, strack: tr.sender?.track?.kind ?? null,
      })),
      sdpLocal: t?.pc?.localDescription?.sdp ?? null,
      sdpRemote: t?.pc?.remoteDescription?.sdp ?? null,
      // Per-sender outbound-rtp, post-mortem: whether each encoder ever ran, what
      // limited it, and what it actually sent. The answerer-carrier starvation shows
      // up here as a sendonly video sender with zero framesEncoded.
      senderStats: await Promise.all((t?.pc?.getSenders?.() ?? []).map(async (sn) => {
        const obs = [];
        try {
          (await sn.getStats()).forEach((r) => {
            if (r.type === 'outbound-rtp') {
              obs.push({
                ssrc: r.ssrc, kind: r.kind ?? r.mediaType, active: r.active,
                fe: r.framesEncoded, fs: r.framesSent, b: r.bytesSent, p: r.packetsSent,
                // Retransmission accounting. Traffic was measured scaling 2.6x
                // from rtt=180 to rtt=300 with no extra data offered, and these
                // are the counters that say whether video RTX owns it.
                nack: r.nackCount, rtxP: r.retransmittedPacketsSent, rtxB: r.retransmittedBytesSent,
                ql: r.qualityLimitationReason, target: r.targetBitrate,
              });
            }
          });
        } catch { /* sender torn down mid-read */ }
        return { track: sn.track?.kind ?? null, obs };
      })),
    };
  });

const [ra, rb] = await Promise.all([grab(A), grab(B)]);
await Promise.all([A.page.evaluate(() => window.__tape?.tel?.flush?.()).catch(() => {}),
                   B.page.evaluate(() => window.__tape?.tel?.flush?.()).catch(() => {})]);
await new Promise((r) => setTimeout(r, 1500));

let serverLog = '';
try {
  // Hardened workers (task #32) 403 tokenless reads; the token came in A's welcome.
  const logToken = await A.page.evaluate(() => window.__tapeLogToken ?? null).catch(() => null);
  const res = await fetch(`${URL_BASE}/api/room/${ROOM}/log${logToken ? `?token=${logToken}` : ''}`);
  if (!res.ok) log(`  server log fetch: HTTP ${res.status}${res.status === 403 && !logToken ? ' (no logToken captured — worker hardened?)' : ''}`);
  serverLog = await res.text();
} catch (e) {
  log(`  server log fetch failed: ${e.message}`);
}

mkdirSync(OUTDIR, { recursive: true });
const meta = {
  tag: TAG, room: ROOM, url: URL_BASE, conv: CONV, at: new Date().toISOString(),
  connectMs: tConn, connected: { A: ca, B: cb }, runMs: RUN_MS,
  forced: { processing: !!args.ns, relay: !!args.relay || SIMULATED },
  netsim: SIMULATED
    ? {
        rttMs: SIM_RTT,
        jitterMs: SIM_JITTER,
        jitterModel: SIM_JMODEL,
        lossPct: SIM_LOSS,
        bwMbps: SIM_BW,
        queueMs: SIM_QUEUE,
        expectedRttMs: sim.expectedRttMs,
        // Summaries, not the raw sample arrays. Spreading `stats` wrote 4000 floats into every
        // meta.json and buried the four numbers anyone actually reads.
        proxy: {
          sent: sim.stats.sent,
          dropped: sim.stats.dropped,
          sendErrors: sim.stats.sendErrors,
          bytes: sim.stats.bytes,
          bwDropped: sim.stats.bwDropped,
          unreachable: sim.stats.unreachable,
          errCodes: sim.stats.errCodes,
          loopLag: sim.loopLag(),
          lateness: sim.lateness(),
          queueDelay: sim.queueDelay(),
        },
      }
    : null,
  errors: { A: A.errors, B: B.errors },
  netFails: { A: A.netFails, B: B.netFails },
};
writeFileSync(join(OUTDIR, 'meta.json'), JSON.stringify(meta, null, 1));
writeFileSync(join(OUTDIR, 'A.json'), JSON.stringify(ra, null, 1));
writeFileSync(join(OUTDIR, 'B.json'), JSON.stringify(rb, null, 1));
if (serverLog.trim()) writeFileSync(join(OUTDIR, 'server.ndjson'), serverLog);
writeFileSync(join(OUTDIR, 'truth.json'), JSON.stringify(truth, null, 1));

// Opus-path mouth-to-ear, composed the same way pcm.js composes its own so the
// two are comparable: one-way + jitter buffer + output latency. Only meaningful
// with ?pcmaudio=0; with the lossless lane on there is no Opus audio to measure.
for (const [who, r] of [['A', ra], ['B', rb]]) {
  if (r.pcmAudio) continue; // lossless lane on; pcm.js already reported m2e
  const m = await (who === 'A' ? A : B).page.evaluate(async () => {
    const pc = window.__mediaPc;
    if (!pc?.getStats) return null;
    const s = await pc.getStats();
    let jbDelay = 0, jbCount = 0, rtt = null, kind = null;
    s.forEach((v) => {
      if (v.type === 'inbound-rtp' && v.kind === 'audio') {
        jbDelay = v.jitterBufferDelay ?? 0; jbCount = v.jitterBufferEmittedCount ?? 0; kind = 'audio';
      }
      if (v.type === 'candidate-pair' && v.nominated && v.currentRoundTripTime != null) rtt = v.currentRoundTripTime * 1000;
    });
    if (!kind || !jbCount) return null;
    const ctx = window.__pcmCtx ?? null;
    const outL = ctx?.outputLatency != null ? ctx.outputLatency * 1000 : 20; // 20 ms is this platform's floor
    const jb = (jbDelay / jbCount) * 1000;
    return { jbMs: +jb.toFixed(1), rttMs: rtt == null ? null : +rtt.toFixed(1), outMs: +outL.toFixed(1),
             m2eMs: rtt == null ? null : +((rtt / 2) + jb + outL).toFixed(1) };
  }).catch(() => null);
  if (m) {
    log(`  ${who}: OPUS mouthToEar ${m.m2eMs ?? '?'} ms  = oneWay ${m.rttMs == null ? '?' : (m.rttMs / 2).toFixed(1)}` +
        ` + jitterBuffer ${m.jbMs} + out ${m.outMs}`);
  } else {
    log(`  ${who}: OPUS mouthToEar unavailable (no inbound audio stats)`);
  }
}
await Promise.all([A.browser.close(), B.browser.close()]);
if (sim) {
  log(
    `\n  delay line carried ${sim.stats.sent} datagrams (${(sim.stats.bytes / 1e6).toFixed(1)} MB), ` +
      `dropped ${sim.stats.dropped} on purpose, ${sim.stats.bwDropped} to the bandwidth ceiling, ` +
      `${sim.stats.sendErrors} by accident` +
      (sim.stats.unreachable ? `, ${sim.stats.unreachable} to an unreachable address (benign)` : '') +
      (sim.stats.sendErrors ? `  [${Object.entries(sim.stats.errCodes).map(([k, v]) => k + '×' + v).join(', ')}]` : '') +
      (sim.stats.sendErrors ? '  ← THE EMULATOR LOST PACKETS; the run is not trustworthy' : '') +
      // THE RULER'S OWN STEADINESS. netsim holds every datagram in a setTimeout, so
      // emulated distance is a property of THIS event loop's punctuality: if the
      // loop is late by L, every packet in flight is late by up to L, and from
      // inside the browser that is indistinguishable from the network doing it.
      // netsim has measured this all along and call.mjs never printed it -- the
      // third counter today that existed and was invisible. A batched-arrival
      // finding at long RTT is exactly what a lagging emulator would fake, so
      // this has to be on the same line as the verdict it could invalidate.
      (() => {
        const l = sim.loopLag?.() ?? null;
        if (!l) return '';
        const bad = (l.p95 ?? 0) > 20 || (l.max ?? 0) > 100;
        return `\n  emulator loop lag p50 ${l.p50 ?? '?'} p95 ${l.p95 ?? '?'} max ${l.max ?? '?'} ms` +
          (bad ? '  ← THE RULER WAS JOSTLED; arrival-timing findings from this run are not trustworthy' : '  (steady)');
      })(),
  );
  const qd = sim.queueDelay();
  // The queue delay is the finding, not a diagnostic: it is how much latency the sender's own
  // overshoot cost, and a sender that respects the ceiling keeps it near zero.
  if (qd) log(`  bottleneck queue delay: p50 ${qd.p50} ms, p95 ${qd.p95} ms, p99 ${qd.p99} ms, max ${qd.max} ms`);
  sim.stop();
}

log(`\n  wrote ${OUTDIR}`);
for (const [side, r] of [['A', ra], ['B', rb]]) {
  const audio = r.gum.find((g) => g.got.some((t) => t.kind === 'audio'));
  const st = audio?.got.find((t) => t.kind === 'audio')?.settings ?? {};
  log(
    `  ${side}: aec=${st.echoCancellation} ns=${st.noiseSuppression} agc=${st.autoGainControl}` +
      `  ${r.events.length} events  ${r.transitions.length} transitions` +
      `  errors ${side === 'A' ? A.errors.length : B.errors.length}`,
  );
}
// ── The custom video lane ────────────────────────────────────────────────────
// Reported separately because none of it is in getStats(). The two numbers that decide
// whether fixed-QP is shippable are `mbps` (what this quality costs on the wire) and the
// skip breakdown (whether time absorbed the shock, and which shock).
if (ra.tapeMode?.wanted || rb.tapeMode?.wanted) {
  log('\n  custom video lane (fixed-QP WebCodecs over datachannel):');
  for (const [side, r] of [['A', ra], ['B', rb]]) {
    const v = r.tapeVideo;
    if (!v) {
      log(`  ${side}: not running` +
        (r.tapeMode?.fellBack ? ' — FELL BACK to RTP' : '') +
        (r.tapeMode?.wanted ? '' : ' (not requested)'));
      continue;
    }
    const inRate = v.framesIn ? ((v.framesEncoded / v.framesIn) * 100).toFixed(0) : '—';
    log(
      `  ${side}: sent ${v.framesEncoded}/${v.framesIn} frames (${inRate}% admitted)` +
        `  ${(v.bytesSent / 1e6).toFixed(1)} MB  ${v.mbpsAtFps} Mbps-at-fps` +
        `  RTX ${v.rtxP ?? '?'}p/${v.packetsSent ?? '?'}p ${(((v.rtxB ?? 0) / 1e6)).toFixed(1)}MB nack ${v.nack ?? '?'}` +
        `  key ${v.keyframesSent}` +
        (r.tapeMode?.fellBack ? '  — FELL BACK to RTP' : ''),
    );
    log(
      `      skipped ${v.framesSkipped}` +
        ` (link ${v.skipBuffered}, encoder ${v.skipEncQueue}, peer-decoder ${v.skipDecodeStalled})` +
        `  frame bytes mean ${v.frameBytesMean} p95 ${v.frameBytesP95}`,
    );
    log(
      `      recv ${v.framesOut} frames  ${v.fragsRecv} frags  lost ${v.framesLost} frames` +
        `  gapped ${v.framesGapped}  late ${v.fragsLate}` +
        `  keyReq sent ${v.keyReqSent} recv ${v.keyReqRecv}  decodeErr ${v.decodeErrors}`,
    );
    // The FEC line is the one that says whether the redundancy is earning its bandwidth.
    log(
      `      FEC parity sent ${v.paritySent} (${(v.parityBytes / 1e6).toFixed(1)} MB, ` +
        `${v.bytesSent ? ((v.parityBytes / v.bytesSent) * 100).toFixed(1) : '—'}% of bytes)` +
        `  repaired ${v.fecRepaired} frags  unrepairable ${v.fecUnrepairable}` +
        `  holdExp ${v.fecHoldExpired}  fragReq sent ${v.fragReqSent} recv ${v.fragReqRecv}  retxSent ${v.retxSent}`,
    );
    log(
      `      age p50 ${v.ageP50} ms  p95 ${v.ageP95} ms` +
        `  (rtt ${v.rttMs} ms, clock offset ${v.clockOffsetMs} ms)`,
    );
    // #14 glass-to-glass decomposition: capture→read + encode (sender, this
    // side) and capture→decode-out + decode-out→present (receiver, this side).
    if (v.capLagP50 != null || v.fullAgeP50 != null || v.presentLagP50 != null) {
      log(
        `      #14  cap→read p50 ${v.capLagP50} (p95 ${v.capLagP95})  encode p50 ${v.encLatP50} (p95 ${v.encLatP95})` +
          `  fullAge p50 ${v.fullAgeP50} (p95 ${v.fullAgeP95})  present p50 ${v.presentLagP50} (p95 ${v.presentLagP95}) ms  glassToGlass ${v.glassToGlassMs} ms`,
      );
      // The CADENCE side of the trade. glassToGlass alone prices what a
      // shorter presenter anchor WINS and says nothing about what it SPENDS —
      // and the anchor exists to keep remote cadence as smooth as the self
      // view. Without these three numbers the ?vpd A/B measures one half of a
      // two-sided decision, which is how a latency win quietly becomes a
      // smoothness regression.
      log(`      #33  IPI p50 ${v.ipiP50} p95 ${v.ipiP95} p99 ${v.ipiP99} ms  (vp anchor ${v.vp?.dMs ?? '?'} ms, depth ${v.vp?.depth ?? '?'})`);
    }
    // Lane 0 lever 3/4b: Lane B yield windows (count + total requested ms)
    // and the worker-side count of carrier ticks that went out empty.
    if (v.l0Yields || v.l0PreStalls || v.l0YieldTicks) {
      log(
        `      Lane 0: onset yields ${v.l0Yields} (${v.l0YieldMs} ms)` +
          `  pre-stalls ${v.l0PreStalls} (${v.l0PreStallMs} ms)  empty carrier ticks ${v.l0YieldTicks}`,
      );
    }
    // §10 A-V sync (audio master): present-vs-hold counts, the applied
    // audio-lead offset distribution (budget [0, 45] ms, §3), queue depth.
    if (v.avEngaged) {
      log(
        `      A-V sync: engaged  presents ${v.avPresents}  holds ${v.avHolds}` +
          `  drops ${v.avDrops}  skips ${v.avSkips}  queue ${v.avqDepth}` +
          `  offset p50 ${v.avOffP50} ms  p95 ${v.avOffP95} ms  peerAvDelta ${v.peerAvDeltaUs} µs`,
      );
    } else if (v.avPresents != null && (v.avPresents || v.avHolds || v.avDrops)) {
      log(`      A-V sync: never engaged (paints on arrival as §17.8)`);
    }
    // §12–13 stall machine: the regime trace (transitions are seconds since
    // arm), shed/resume counters both directions of the ctl, and lane P.
    if (v.stall) {
      log(
        `      stall: regime ${v.stall.regime}${v.stall.shedded ? ' (uplink shed)' : ''}` +
          `  shed sent ${v.shedSent} recv ${v.shedRecv}  resume sent ${v.resumeSent} recv ${v.resumeRecv}` +
          `  skipShed ${v.skipShed}  shedSkipped ${v.shedSkipped}  purged ${v.shedPurged}  encDropped ${v.shedDroppedEnc}`,
      );
      if (v.lpSent || v.lpRecv) {
        log(
          `      lane P: stills sent ${v.lpSent} (${((v.lpBytes ?? 0) / 1e6).toFixed(2)} MB)` +
            `  recv ${v.lpRecv}  painted ${v.lpPainted}  age p50 ${v.stall.lpAgeP50} ms`,
        );
      }
      if (v.stall.transitions?.length) {
        log(`      transitions: ${v.stall.transitions.map((x) => `${x.from}→${x.to}@${(x.t / 1000).toFixed(0)}s(${x.why})`).join('  ')}`);
      }
    }
  }
  // App-side HOLD (§12: cannot carry even audio) — lives outside tapeVideo.
  for (const [side, r] of [['A', ra], ['B', rb]]) {
    if (r.stall?.enabled) log(`  ${side} stall: audioHold ${r.stall.audioHold}  videoHeld ${r.stall.videoHeld}`);
  }
}

// ── §10 TIME_SYNC: session clock quality ────────────────────────────────────
// Offset must be stable (min-filtered, 10 s window), drift slope plausible for
// two crystals (|ppm| ≲ 100 on one machine), epoch map reported as an estimate.
if (ra.timesync || rb.timesync) {
  log('\n  TIME_SYNC (session epoch, 5 Hz over ctl):');
  for (const [side, r] of [['A', ra], ['B', rb]]) {
    const s = r.timesync;
    if (!s) { log(`  ${side}: not running`); continue; }
    log(
      `  ${side}: offset ${s.offsetMs} ms  minRtt ${s.rttMinMs} ms  spread ${s.offSpreadMs} ms` +
        `  drift ${s.driftPpm} ppm (fits ${s.fitN})  pings ${s.pings}/${s.pongs}` +
        `  epochOffset ${s.epochOffsetMs} ms`,
    );
  }
}

// ── Lane A: lossless PCM audio ───────────────────────────────────────────────
// The numbers that decide whether the lane is honest: frames sent vs received
// (125 pps steady), FEC repairs earned, concealment bounded, depth vs target.
if (ra.pcmAudio || rb.pcmAudio) {
  log('\n  PCM audio lane (48 kHz/24-bit linear, no codec):');
  for (const [side, r] of [['A', ra], ['B', rb]]) {
    const p = r.pcmAudio;
    if (!p) {
      log(`  ${side}: not running`);
      continue;
    }
    log(
      `  ${side}: sent ${p.framesSent}/${p.captureFrames} frames  ${p.mbpsSent} Mbps` +
        `  parity ${p.paritySent}  drop(link) ${p.skipBuffered}` +
        `  recv ${p.framesRecv}  lost ${p.lostFrames}  late ${p.lateFrames}  dup ${p.dup}  farFuture ${p.farFuture}`,
    );
    log(
      `      FEC repaired ${p.fecRepaired} (late ${p.fecRepairedLate ?? 0})  failed ${p.fecFailed}  parityUnused ${p.parityUnused}` +
        `  concealed ${p.concealedMs} ms (extrapolated ${p.extrapolatedMs}, held ${p.heldMs})` +
        `  overflowSkips ${p.overflowSkips}` +
        // reAnchors, because the far-future rescue is the thing under suspicion
        // and this line printed every counter around it except whether it fired.
        // 624 refusals were observed with no way to tell "never reached" from
        // "reached and lost the anchor again" — different bugs, one counter.
        `  reAnchors ${p.reAnchors ?? '?'}`,
    );
    log(
      `      depth ${p.depthMs} ms  target ${p.targetFrames}f  drift ${p.driftPpm} ppm` +
        `  age p50 ${p.ageP50} ms  p95 ${p.ageP95} ms  (rtt ${p.rttMs}, baseRtt ${p.baseRttMs}, offset ${p.clockOffsetMs})` +
        `  mode ${p.mode}  outLatency ${p.outputLatencyMs} ms  mouthToEar ${p.mouthToEarMs} ms`,
    );
    // The BANDWIDTH axis of the goal, which this rig has never printed. Every
    // number here was already in the snapshot; 17.47 asked for wire bytes
    // beside latency and they were sitting unread. bPerFrame is the real
    // post-compression payload, so at 8 ms/frame it is also kbps exactly
    // (125 frames/s x B x 8 bits = 1000 x B bit/s) -- stated rather than
    // assumed, because that identity dies the moment FRAME_MS changes.
    const fms = p.pcmFrameMs ?? 8;
    log(
      `      wire ${p.bPerFrame ?? '?'} B/frame` +
        `  ${p.bPerFrame ? Math.round((p.bPerFrame * 8) / fms) : '?'} kbps @${fms}ms` +
        `  parity ${p.bPerParity ?? '?'} B x ${p.framesSent ? (p.paritySent / p.framesSent).toFixed(2) : '?'}/frame` +
        // TOTAL is what the goal's ~1 Mbps is measured against; the data lane
        // alone (682 kbps observed) is only part of what goes on the wire, and
        // FEC is ADAPTIVE so the parity share is not a constant to assume.
        `  = ${p.bPerFrame && p.framesSent ? Math.round(((p.bPerFrame + (p.bPerParity ?? 0) * (p.paritySent / p.framesSent)) * 8) / fms) : '?'} kbps total` +
        `  wastedShift ${p.wastedShift ?? '?'} (>=8 on ${p.shift8Pct ?? '?'}%)` +
        `  fit16 ${p.fit32767Pct ?? '?'}/${p.fit32768Pct ?? '?'}%  rxWasted ${p.rxWastedShift ?? '?'}`,
    );
    // The estimator's own inputs. Without these the target is a number with no
    // provenance: a run showed target 22f while age p95-p50 was 7.8 ms, and there
    // was no way to tell whether spread had genuinely seen 168 ms of dispersion
    // or the demand had come from somewhere else entirely. Printing the raw
    // want, the held peak and the post-warm spread max separates those.
    // Arrival PATTERN. Spread says how wide the dispersion is; this says what
    // SHAPE it has, and the two have opposite fixes. High clump WITH high p95 is
    // the sender or the transport delivering in batches (pacing); low clump with
    // high p95 is the path stretching. This is the counter that separates them
    // and it already existed -- it was simply never printed.
    log(`      mainthread lateMax ${p.tickLateMax ?? '?'} ms @${p.tickLateAtMs ?? '?'}  >100ms ${p.tickLate100 ?? '?'}/${p.tickN ?? '?'} ticks  >500ms ${p.tickLate500 ?? '?'}`);
    log(`      gaps p50 ${p.gapP50 ?? '?'} p95 ${p.gapP95 ?? '?'} p99 ${p.gapP99 ?? '?'} maxRun ${p.gapMaxRun ?? '?'} ms` +
        `  clump ${p.gapClumpPct ?? '?'}%  stalls ${(p.stalls ?? []).length}` +
        `  biggest ${(p.stalls ?? []).slice().sort((a, b) => b.g - a.g).slice(0, 3).map((x) => `${x.g}@${x.t}`).join(' ') || '-'}`);
    if (r.recovers) {
      const rc = r.recovers;
      log(`      recovers asked ${rc.asked ?? 0}  ran ${rc.ran ?? 0}  capped ${rc.capped ?? 0}  why ${JSON.stringify(rc.why ?? {})}`);
    }
    log(
      `      jit spreadMax ${p.jitSpreadMaxRun ?? '?'} ms @${p.jitSpreadMaxAtMs ?? '?'} ms (warm ${p.jitWarmMs ?? '?'}; late ${p.jitSpreadMaxLate ?? '?'} @${p.jitSpreadMaxLateAtMs ?? '?'} ms)` +
        `  holdMax ${p.jitHoldMaxRun ?? '?'} ms  wantMax ${p.jitWantMaxRun ?? '?'}f  clampedTicks ${p.jitClampedTicks ?? '?'}` +
        `  elMaxRun ${p.elMaxRun ?? "?"}f  painEvents ${p.painEvents ?? '?'}` +
        `  window[p90 ${p.jitP90Ms ?? '?'} p99 ${p.jitP99Ms ?? '?'} max ${p.jitMaxMs ?? '?'}]` +
        `  purge ${p.jitPurge === false ? 'OFF' : `@${p.jitPurgedAtMs ?? 'never'}`}` +
        `  holdArm ${p.holdArm === false ? 'OFF' : `@${p.holdArmedAtMs ?? 'NEVER'} from ${p.holdArmDroppedF ?? '?'}f`}` +
        `  bands ${(p.jitBands ?? []).join('/')}`,
    );
    // Lane 0 (§3.1 lever 4) wire counters: T_PRED pairs sent/received (+ the
    // duplicate copies proving the duplication works) and T_PAD pre-warm
    // bytes in both directions. T_PAD never enters an RS group — the proof is
    // that fecFailed/parityUnused above do not move when padding runs.
    if (p.predSent || p.predRecv || p.padBytesSent || p.padBytesRecv) {
      log(
        `      Lane 0: pred sent ${p.predSent}  recv ${p.predRecv} (dup copies ${p.predDup})` +
          `  pad sent ${p.padMsgsSent} msgs/${p.padBytesSent} B  recv ${p.padMsgsRecv} msgs/${p.padBytesRecv} B`,
      );
    }
    // §17.12 striping (?pcmpairs=N): per-association counters — ping/buffered/
    // backpressure are per-association, so the stripe is judged per row and
    // the even split (~1/N of frames each) is the health signature.
    if (p.perAssoc?.length > 1) {
      log(`      striping ${p.pairs ?? p.perAssoc.length} associations:`);
      for (const a of p.perAssoc) {
        log(
          `        [${a.i}] ${a.open ? 'open' : 'CLOSED'}  sent ${a.framesSent}  recv ${a.framesRecv}` +
            `  drop(link) ${a.skipBuffered}  parity ${a.paritySent}` +
            `  rtt ${a.rttMs}  baseRtt ${a.baseRttMs}  buffered ${a.buffered}` +
            (a.padBytesSent || a.padBytesRecv ? `  pad sent ${a.padBytesSent} B  recv ${a.padBytesRecv} B` : ''),
        );
      }
    }
  }
}

// ── Lane 0 policy counters (§3.1 levers 3+4) ────────────────────────────────
// The chain, proved end to end: predictor fires on the sender's mic → one
// T_PRED pair per detected fall (cooldown suppressions counted) → receiver
// dedupes and, ONLY in a listening stretch, pads + pre-stalls.
if (ra.lane0 || rb.lane0) {
  log('\n  Lane 0 (turn-end pre-warm + onset preemption):');
  for (const [side, r] of [['A', ra], ['B', rb]]) {
    const l = r.lane0;
    if (!l) { log(`  ${side}: not running`); continue; }
    log(
      `  ${side}: ${l.enabled ? 'enabled' : 'DISABLED'}  turnend fires ${l.turnendFires}` +
        `  suppressed ${l.predSuppressed}  wire sent ${l.predWireSent}  wire recv ${l.predWireRecv}` +
        `  recv-while-speaking ${l.predSkippedSpeaking}  pre-warms ${l.preWarms}  onset yields ${l.onsetYields}` +
        `  (listening now: ${l.listening})`,
    );
  }
}

const nf = [...new Set([...A.netFails, ...B.netFails])];
if (nf.length) {
  log(`\n  ${nf.length} failed request(s):`);
  for (const f of nf.slice(0, 8)) log(`    ${f}`);
}
const errs = [...A.errors, ...B.errors];
if (errs.length) {
  log(`\n  ${errs.length} console error(s):`);
  for (const e of [...new Set(errs)].slice(0, 6)) log(`    ${e}`);
}
log('');
process.exit(0);
