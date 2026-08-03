// Mechanism probe for task #41 lever 1 (send-on-encode-output).
//
// The lane-2 carrier is canvas.captureStream(60): tape frames ride carrier
// ticks, so an encoded frame waits for the next tick (§17.20: ~⅔ tick mean,
// the entire loopback "transport" term). The candidate fix: call
// CanvasCaptureMediaStreamTrack.requestFrame() the moment the encoder emits,
// forcing an extra carrier tick on demand instead of waiting for the auto
// cadence. Three unknowns, measured here before any tape.js edit:
//
//   A. What does the auto (flicker-driven) tick cadence actually run at in
//      this headless fixture? (§17.20 reads ~30 Hz although 60 was asked.)
//   B. Does requestFrame() on an auto-capturing track produce EXTRA frames,
//      and what is the request→track-delivery latency? (MediaStreamTrackProcessor
//      reader on the track itself.)
//   C. End to end: request → carrier frame visible at the SEND transform
//      (the point where a tape frame could be spliced). Loopback pc pair,
//      transform worker posts each carrier arrival to the main thread.
//
// Read-only: one page on the dev origin, no app code touched.
//   node reqframe-probe.mjs [--secs=8]
import { chromium } from 'playwright-core';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const CHROME =
  '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const args = Object.fromEntries(process.argv.slice(2).map((a) => {
  const b = a.replace(/^--/, ''); const i = b.indexOf('=');
  return i === -1 ? [b, true] : [b.slice(0, i), b.slice(i + 1)];
}));
const SECS = Number(args.secs ?? 8);
const URL_BASE = args.url ?? 'http://127.0.0.1:8794';

const browser = await chromium.launch({
  executablePath: CHROME,
  headless: true,
  args: [`--unsafely-treat-insecure-origin-as-secure=${URL_BASE}`, '--allow-running-insecure-content'],
});
const page = await browser.newPage();
page.on('console', (m) => console.log('[page]', m.text()));
await page.goto(URL_BASE + '/');

const res = await page.evaluate(async (SECS) => {
  const out = {};
  const pct = (a, p) => {
    if (!a.length) return null;
    const s = [...a].sort((x, y) => x - y);
    return +s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))].toFixed(2);
  };

  // ── Carrier replica: exactly the tape.js canvas+flicker construction ──────
  const canvas = document.createElement('canvas');
  canvas.width = 320; canvas.height = 180;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#000'; ctx.fillRect(0, 0, canvas.width, canvas.height);
  let flick = false;
  setInterval(() => {
    flick = !flick;
    ctx.fillStyle = flick ? '#000' : '#101010';
    ctx.fillRect(0, 0, 1, 1);
  }, 16);
  const track = canvas.captureStream(60).getVideoTracks()[0];
  out.hasRequestFrame = typeof track.requestFrame === 'function';

  const reader = new MediaStreamTrackProcessor({ track }).readable.getReader();
  let stamps = []; // delivery times of track frames
  let closed = false;
  (async () => {
    for (;;) {
      const { done, value: f } = await reader.read();
      if (done) return;
      stamps.push(performance.now());
      f.close();
      if (closed) return;
    }
  })();

  // Phase A: auto cadence only.
  await new Promise((r) => setTimeout(r, SECS * 1000));
  const aIpi = stamps.slice(1).map((t, i) => t - stamps[i]);
  out.phaseA = { frames: stamps.length, perSec: +(stamps.length / SECS).toFixed(1),
    ipi: { p50: pct(aIpi, 50), p95: pct(aIpi, 95), max: +Math.max(...aIpi).toFixed(1) } };

  // Phase B: add requestFrame() at ~30 Hz (33 ms interval, jittered phase).
  const reqs = [];
  const iv = setInterval(() => {
    track.requestFrame?.();
    reqs.push(performance.now());
  }, 33);
  const base0 = stamps.length;
  await new Promise((r) => setTimeout(r, SECS * 1000));
  clearInterval(iv);
  const bStamps = stamps.slice(base0);
  const bIpi = bStamps.slice(1).map((t, i) => t - bStamps[i]);
  // request → next-delivery latency: pair each request with the first frame
  // delivered after it (frames may also come from the auto cadence — the
  // measurement is "how long until ANY frame emits after a request", which
  // is exactly the splice-opportunity latency lever 1 cares about).
  const lags = [];
  {
    let si = base0;
    for (const t of reqs) {
      while (si < stamps.length && stamps[si] <= t) si++;
      if (si < stamps.length) lags.push(stamps[si] - t);
    }
  }
  out.phaseB = { frames: bStamps.length, perSec: +(bStamps.length / SECS).toFixed(1),
    requests: reqs.length,
    ipi: { p50: pct(bIpi, 50), p95: pct(bIpi, 95) },
    reqToFrameMs: { p50: pct(lags, 50), p95: pct(lags, 95), max: lags.length ? +Math.max(...lags).toFixed(1) : null } };

  // Phase C: loopback pc pair, send transform worker stamps carrier arrivals.
  const workerSrc = `
    self.onerror = (m) => postMessage({ type: 'err', e: String(m).slice(0, 120) });
    onrtctransform = (e) => {
      const tf = e.transform ?? e.transformer;
      const role = tf.options.role;
      const reader = tf.readable.getReader();
      const writer = tf.writable.getWriter();
      (async () => {
        for (;;) {
          const { done, value: frame } = await reader.read();
          if (done) return;
          if (role === 'send') postMessage({ type: 'tick', t: performance.now() });
          await writer.write(frame);
        }
      })();
    };`;
  const worker = new Worker(URL.createObjectURL(new Blob([workerSrc], { type: 'text/javascript' })));
  const ticks = [];
  worker.onmessage = (e) => { if (e.data.type === 'tick') ticks.push(performance.now()); };
  const pc1 = new RTCPeerConnection();
  const pc2 = new RTCPeerConnection();
  pc2.ontrack = () => {};
  pc1.onicecandidate = (e) => e.candidate && pc2.addIceCandidate(e.candidate);
  pc2.onicecandidate = (e) => e.candidate && pc1.addIceCandidate(e.candidate);
  const tx = pc1.addTransceiver(track, { direction: 'sendonly' });
  tx.sender.transform = new RTCRtpScriptTransform(worker, { role: 'send' });
  const offer = await pc1.createOffer();
  await pc1.setLocalDescription(offer);
  await pc2.setRemoteDescription(offer);
  const ans = await pc2.createAnswer();
  await pc2.setLocalDescription(ans);
  await pc1.setRemoteDescription(ans);
  await new Promise((r) => setTimeout(r, 3000)); // let the pipe warm
  const reqsC = [];
  const ticks0 = ticks.length;
  const iv2 = setInterval(() => {
    track.requestFrame?.();
    reqsC.push(performance.now());
  }, 33);
  await new Promise((r) => setTimeout(r, SECS * 1000));
  clearInterval(iv2);
  const cTicks = ticks.slice(ticks0);
  const cIpi = cTicks.slice(1).map((t, i) => t - cTicks[i]);
  const lagsC = [];
  {
    let si = 0;
    for (const t of reqsC) {
      while (si < cTicks.length && cTicks[si] <= t) si++;
      if (si < cTicks.length) lagsC.push(cTicks[si] - t);
    }
  }
  out.phaseC = { ticks: cTicks.length, perSec: +(cTicks.length / SECS).toFixed(1),
    requests: reqsC.length,
    ipi: { p50: pct(cIpi, 50), p95: pct(cIpi, 95) },
    reqToTransformMs: { p50: pct(lagsC, 50), p95: pct(lagsC, 95), max: lagsC.length ? +Math.max(...lagsC).toFixed(1) : null } };

  closed = true;
  pc1.close(); pc2.close(); worker.terminate();
  return out;
}, SECS);

console.log(JSON.stringify(res, null, 2));
await browser.close();
