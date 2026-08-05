/**
 * Cadence harness (task #33, additive — call.mjs's harness logic is untouched).
 *
 * Same two-browser fixture as call.mjs, plus ONE read-only probe injected via
 * addInitScript that no app code can feel:
 *
 *   window.__cad = { remote: [], self: [], decode: [], laneP: [] }
 *
 *   remote[]  — performance.now() at every drawImage of a VideoFrame onto
 *               #remoteCanvas (the presented remote frame; in the paint-on-arrival
 *               path this is also the arrival, in the avsync path it is avTick's
 *               scheduled present).
 *   decode[]  — performance.now() at every VideoDecoder output callback (true
 *               arrival, whether or not the frame is ever painted).
 *   self[]    — performance.now() stamped inside requestVideoFrameCallback on
 *               #preview (the self-view's true presented cadence; the timestamp
 *               argument is a different clock base — law 14 — so we stamp inside).
 *   laneP[]   — drawImage of an ImageBitmap onto #remoteCanvas (§13 stills —
 *               they paint immediately by design and must not enter the video IPI).
 *
 * The probe never closes, drops, delays or repaints anything; it reads
 * `frame.timestamp` and performance.now() and returns. If any of it throws, the
 * original call already ran.
 *
 * Usage mirrors call.mjs:
 *   node cadence-call.mjs --tag=cad-loop-poa --q='tape=2' --video=media/cam1080.mjpeg --ms=75000
 *   node cadence-call.mjs --tag=cad-801-av  --q='tape=2&pcmaudio=1' --p2psim --rtt=80 --loss=1 --video=media/cam1080.mjpeg --ms=75000
 */

import { chromium } from 'playwright-core';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startNetsim, startP2PSim } from './netsim.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const CHROME =
  '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';

const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const body = a.replace(/^--/, '');
    const i = body.indexOf('=');
    return i === -1 ? [body, true] : [body.slice(0, i), body.slice(i + 1)];
  }),
);

const URL_BASE = args.url ?? 'http://127.0.0.1:8794';
const EXTRA_Q = args.q ? String(args.q).replace(/^\?/, '') : '';
const PAGE_URL = EXTRA_Q ? `${URL_BASE}/?${EXTRA_Q}` : URL_BASE;
const SIM_RTT = Number(args.rtt ?? 0);
const SIM_JITTER = Number(args.jitter ?? 0);
const SIM_LOSS = Number(args.loss ?? 0);
const SIM_BW = Number(args.bw ?? 0);
const SIM_QUEUE = Number(args.queue ?? 100);
const P2P = !!args.p2psim;
const SIMULATED = SIM_RTT > 0 || SIM_JITTER > 0 || SIM_LOSS > 0 || SIM_BW > 0;
const CONV = join(HERE, 'media', args.conv ?? 'conv');
const ROOM = args.room ?? `bot-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
const TAG = args.tag ?? (SIMULATED ? `cad-rtt${SIM_RTT}` : 'cad-loop');
const OUTDIR = join(HERE, 'runs', `${TAG}-${ROOM}`);
const HEADED = !!args.headed;

const truth = JSON.parse(readFileSync(join(CONV, 'truth.json'), 'utf8'));
const RUN_MS = Number(args.ms ?? truth.totalMs + 12000);
// The governor ramps admission 5→30+ fps over the first ~15 s (law 10); cadence
// statistics over the ramp would measure the ramp, not the path. Scoring trims it.
const WARMUP_MS = Number(args.warmup ?? 15000);

const log = (s) => console.log(s);

// ── The cadence probe (read-only) ────────────────────────────────────────────
const CADENCE_PROBE = `
(() => {
  const CAP = 60000;
  const cad = (window.__cad = { remote: [], self: [], decode: [], laneP: [], notes: [] });
  const push = (arr, v) => { if (arr.length < CAP) arr.push(v); };

  // Remote presents: drawImage(VideoFrame) onto the lane-2 display canvas.
  // drawImage(Sync) exists too; only the async one matters on this path.
  const origDraw = CanvasRenderingContext2D.prototype.drawImage;
  CanvasRenderingContext2D.prototype.drawImage = function (...a) {
    const r = origDraw.apply(this, a);
    try {
      if (this.canvas && this.canvas.id === 'remoteCanvas' && a[0]) {
        if (typeof VideoFrame !== 'undefined' && a[0] instanceof VideoFrame) {
          push(cad.remote, { t: performance.now(), ts: a[0].timestamp });
        } else if (typeof ImageBitmap !== 'undefined' && a[0] instanceof ImageBitmap) {
          push(cad.laneP, { t: performance.now() });
        }
      }
    } catch (e) { push(cad.notes, 'draw ' + String(e).slice(0, 80)); }
    return r;
  };

  // True arrivals: every VideoDecoder output, painted or not. The wrap is a
  // transparent subclass — statics inherit through extends, instance methods
  // through super.
  if (typeof VideoDecoder !== 'undefined') {
    const OrigVD = VideoDecoder;
    window.VideoDecoder = class extends OrigVD {
      constructor(init) {
        super({
          output: (frame) => {
            try { push(cad.decode, { t: performance.now(), ts: frame.timestamp }); }
            catch (e) { push(cad.notes, 'dec ' + String(e).slice(0, 80)); }
            init.output(frame);
          },
          error: init.error,
        });
      }
    };
  }

  // Self-view presents: rVFC on the self-view elements. The UI overhaul (task
  // #28) split self-view in two: #preview is the LOBBY preview, #selfFull is
  // the in-call self-view (fullscreen until peerArrived, then PiP). Watch both,
  // tagged, so the lobby reference and the in-call reference stay separable.
  // Stamped with now() inside — rVFC's own timestamp is a third clock base (law 14).
  const armSelf = (v, w) => {
    if (v.__cadArmed) return;
    v.__cadArmed = true;
    const cb = () => {
      try { push(cad.self, { t: performance.now(), w }); } catch {}
      try { v.requestVideoFrameCallback(cb); } catch {}
    };
    try { v.requestVideoFrameCallback(cb); } catch (e) { push(cad.notes, 'rvfc ' + String(e).slice(0, 80)); }
  };
  const findSelf = () => {
    const p = document.querySelector('video#preview');
    if (p) armSelf(p, 'p');
    const f = document.querySelector('video#selfFull');
    if (f) armSelf(f, 'f');
  };
  // At init-script time document.documentElement can be null — observing it
  // throws and kills the self-view probe (measured: smoke run had remote data
  // and none for self). Defer to DOMContentLoaded and poll as well.
  const boot = () => {
    findSelf();
    try {
      new MutationObserver(findSelf).observe(document.documentElement, { childList: true, subtree: true });
    } catch (e) { push(cad.notes, 'obs ' + String(e).slice(0, 80)); }
    setInterval(findSelf, 500);
  };
  if (document.documentElement) boot();
  else document.addEventListener('DOMContentLoaded', boot, { once: true });
})();
`;

// Records every constraint set actually handed to getUserMedia (same as call.mjs).
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

const forceRelay = (servers) => `
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

const P2P_REWRITE = `
  const OrigPC = window.RTCPeerConnection;
  window.__rewrites = [];
  const rewrite = async (line) => {
    const f = String(line).split(' ');
    if (f.length < 7 || !/^udp$/i.test(f[2])) return null;
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

async function launch(side, wav) {
  const browser = await chromium.launch({
    executablePath: CHROME,
    headless: !HEADED,
    args: [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      ...(args.video ? [`--use-file-for-fake-video-capture=${resolve(HERE, args.video)}`] : []),
      `--use-file-for-fake-audio-capture=${wav}`,
      '--autoplay-policy=no-user-gesture-required',
      '--alsa-output-device=null',
      '--disable-features=WebRtcHideLocalIpsWithMdns',
      `--unsafely-treat-insecure-origin-as-secure=${URL_BASE}`,
      '--allow-running-insecure-content',
    ],
  });
  const page = await browser.newPage();
  const errors = [];
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push(m.text().slice(0, 300));
  });
  page.on('pageerror', (e) => errors.push('pageerror: ' + String(e.message).slice(0, 300)));

  if (P2P && sim) {
    await page.exposeFunction('__simProxy', async (h, p) => sim.portFor(h, p));
    await page.addInitScript(P2P_REWRITE);
  } else if (args.relay || SIMULATED) {
    await page.addInitScript(forceRelay(sim?.iceServers ?? null));
  }
  await page.addInitScript(RECORD_CONSTRAINTS);
  await page.addInitScript(CADENCE_PROBE);

  await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#join', { timeout: 20000 });
  // The named-room field moved into the lobby setup sheet (••• ) when the first
  // screen became one button. Open it, type, close — the same three moves a
  // person makes.
  await page.click('#more');
  await page.fill('#room', ROOM);
  await page.keyboard.press('Escape');
  return { side, browser, page, errors };
}

// ── Run ──────────────────────────────────────────────────────────────────────
const sim = !SIMULATED
  ? null
  : P2P
    ? await startP2PSim({
        oneWayMs: SIM_RTT / 2,
        jitterMs: SIM_JITTER,
        lossPct: SIM_LOSS,
        bwMbps: SIM_BW,
        queueMs: SIM_QUEUE,
      })
    : await startNetsim({
        oneWayMs: SIM_RTT / 2,
        jitterMs: SIM_JITTER,
        lossPct: SIM_LOSS,
        bwMbps: SIM_BW,
        queueMs: SIM_QUEUE,
        turnPort: 3478 + (Number(process.pid) % 500),
      });

log(`\n${'═'.repeat(68)}`);
log(`  ${TAG}   room ${ROOM}`);
log(`  ${PAGE_URL}`);
log(`  run ${RUN_MS / 1000} s, warmup trim ${WARMUP_MS / 1000} s, video ${args.video ?? 'default fake pattern'}`);
if (SIMULATED) log(`  netsim: rtt ${SIM_RTT} loss ${SIM_LOSS}% p2p=${P2P}`);
log(`${'═'.repeat(68)}\n`);

const A = await launch('A', args.wavA ? resolve(HERE, args.wavA) : join(CONV, 'A.wav'));
const B = await launch('B', args.wavB ? resolve(HERE, args.wavB) : join(CONV, 'B.wav'));
log('  both browsers up, lobby loaded');
// Let the lobby's full-screen self-view run a moment BEFORE the call: that is
// the smoothness reference (unoccluded #preview, no network in the way).
const LOBBY_MS = Number(args.lobbyms ?? 8000);
await new Promise((r) => setTimeout(r, LOBBY_MS));

const t0 = Date.now();
await Promise.all([A.page.click('#join'), B.page.click('#join')]);
log('  join clicked on both');
// Mark the lobby→call boundary in the probe timeline: pre-join self-view entries
// are the full-screen, unoccluded self-view the user compares against.
await Promise.all([
  A.page.evaluate(() => { if (window.__cad) window.__cad.joinAt = performance.now(); }).catch(() => {}),
  B.page.evaluate(() => { if (window.__cad) window.__cad.joinAt = performance.now(); }).catch(() => {}),
]);

const connected = async (p, ms) => {
  try {
    await p.page.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: ms });
    return true;
  } catch {
    return false;
  }
};
const [ca, cb] = await Promise.all([connected(A, 30000), connected(B, 30000)]);
const tConn = Date.now() - t0;
log(`  connected: A=${ca} B=${cb} in ${(tConn / 1000).toFixed(1)} s`);
if (!ca || !cb) process.exit(1);

const started = Date.now();
while (Date.now() - started < RUN_MS) {
  await new Promise((r) => setTimeout(r, 10000));
  const el = Math.round((Date.now() - started) / 1000);
  const n = await A.page.evaluate(() => window.__cad?.remote?.length ?? -1).catch(() => -1);
  log(`  ${String(el).padStart(3)}s  A remote paints: ${n}`);
}

// ── Collect ──────────────────────────────────────────────────────────────────
const grab = async (s) =>
  s.page.evaluate(async () => {
    const t = window.__tape;
    return {
      tapeVideo: t?.video ?? null,
      pcmAudio: t?.pcm ?? null,
      timesync: t?.timesync ?? null,
      cad: window.__cad ?? null,
      gum: window.__gum ?? [],
      pc: { conn: t?.pc?.connectionState, ice: t?.pc?.iceConnectionState },
    };
  });

const [ra, rb] = await Promise.all([grab(A), grab(B)]);

mkdirSync(OUTDIR, { recursive: true });
const meta = {
  tag: TAG, room: ROOM, url: URL_BASE, q: EXTRA_Q, at: new Date().toISOString(),
  runMs: RUN_MS, warmupMs: WARMUP_MS,
  netsim: SIMULATED ? { rttMs: SIM_RTT, jitterMs: SIM_JITTER, lossPct: SIM_LOSS, p2p: P2P } : null,
  errors: { A: A.errors, B: B.errors },
};
writeFileSync(join(OUTDIR, 'meta.json'), JSON.stringify(meta, null, 1));
writeFileSync(join(OUTDIR, 'A.json'), JSON.stringify(ra));
writeFileSync(join(OUTDIR, 'B.json'), JSON.stringify(rb));
log(`\n  wrote ${OUTDIR}`);

await Promise.all([A.browser.close(), B.browser.close()]);
if (sim) await sim.close?.();

// Inline the score so a run always ends with its own numbers on stdout.
const { scoreCadenceRun } = await import('./cadence-score.mjs');
scoreCadenceRun(OUTDIR, { print: true });
process.exit(0);
