/**
 * codec-frontier.mjs — standalone WebCodecs encode→decode→score harness for the
 * codec frontier probe (task #34). Sibling of vmaf-call.mjs, but WITHOUT the app,
 * the call, or the transport: one headless Chrome, one fake camera, an in-page
 * VideoEncoder -> VideoDecoder -> canvas loop, stills at 2 fps written as
 * dist_%03d.png so the UNMODIFIED vmaf-score.mjs can align+score the run dir.
 *
 * Measures, per arm:
 *   - encoder output bytes over the capture window -> Mbps (encoder wire rate)
 *     and Mbps-at-fps (normalised to 30 fps, the §17.16 column)
 *   - per-frame encode latency (submit -> output callback), p50/p95
 *   - per-frame decode latency (submit -> output callback), p50/p95
 *   - admission (frames submitted / frames read) under a queue gate of 4,
 *     the same gate tape.js uses
 *   - isConfigSupported matrix incl. whether bitrateMode:'quantizer' survives
 *     the echo, and a live preflight that the per-frame quantizer knob moves
 *     bytes (a silently-ignored option would make the whole arm fiction)
 *
 *   node codec-frontier.mjs --tag=av1-q120 --codec=av01.0.04M.08 --qp=120 \
 *     --video=media/cam1080.mjpeg --out=/path/dir
 *
 * SERIAL RULE (shared machine): caller gates on the heavy-run mutex
 * (pgrep for call|cadence-call|sctpwall|corpus-score|g2g-probe|ui-call|vmaf .mjs)
 * before launching; this script does not police other agents. It also does NOT
 * touch the dev server on :8794 — it serves its own page on an ephemeral port.
 */

import { chromium } from 'playwright-core';
import { createServer } from 'node:http';
import { writeFileSync, mkdirSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

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

const TAG = args.tag ?? 'frontier';
const CODEC = String(args.codec ?? 'avc1.640028');
const QP = Number(args.qp ?? 24);
const VIDEO = resolve(HERE, String(args.video ?? 'media/cam1080.mjpeg'));
const OUTDIR = args.out ? resolve(String(args.out)) : join(HERE, 'runs', `${TAG}-${Date.now().toString(36)}`);
const WARMUP_MS = Number(args.warmup ?? 3) * 1000;
const CAP_MS = Number(args.capms ?? 15000);
const CAP_FPS = Number(args.fps ?? 2);
const GOP = Number(args.gop ?? 150);
const WIDTH = Number(args.width ?? 1920);
const HEIGHT = Number(args.height ?? 1080);
const FPS = Number(args.rate ?? 30);
const QUEUE_GATE = 4;

const log = (s) => console.log(s);

// The whole in-page harness. Self-contained: no app files, no dev server.
const PAGE = `<!doctype html><meta charset=utf-8><title>codec-frontier</title><body>
<canvas id=gl width=${WIDTH} height=${HEIGHT}></canvas>
<script>
window.__stills = [];
window.__run = async (CFG) => {
  const R = { support: [], preflight: null, errors: [] };
  const optKey = CFG.codec.startsWith('avc1') ? 'avc' : CFG.codec.startsWith('av01') ? 'av1' : CFG.codec.startsWith('vp09') ? 'vp9' : null;
  if (!optKey) { R.errors.push('unknown codec family'); return R; }

  // ── support matrix: does quantizer mode survive the echo? ──────────────────
  for (const [name, codec] of [['h264', 'avc1.640028'], ['av1', 'av01.0.04M.08'], ['vp9', 'vp09.00.10.08']]) {
    for (const mode of ['constant', 'variable', 'quantizer']) {
      const cfg = { codec, width: CFG.width, height: CFG.height, framerate: CFG.fps,
        latencyMode: 'realtime', bitrateMode: mode };
      if (mode !== 'quantizer') cfg.bitrate = 8000000;
      if (name === 'h264') cfg.avc = { format: 'annexb' };
      try {
        const r = await VideoEncoder.isConfigSupported(cfg);
        R.support.push({ codec: name, mode, supported: !!r.supported,
          echoedMode: r.config?.bitrateMode ?? null, hw: r.config?.hardwareAcceleration ?? null });
      } catch (e) { R.support.push({ codec: name, mode, supported: false, error: String(e).slice(0, 120) }); }
    }
  }

  const mkNoise = (w, h) => {
    const buf = new Uint8Array(w * h * 4);
    for (let i = 0; i < buf.length; i += 4) {
      const v = (Math.random() * 255) | 0;
      buf[i] = v; buf[i + 1] = v; buf[i + 2] = v; buf[i + 3] = 255;
    }
    return buf;
  };

  // ── preflight: is the per-frame quantizer knob actually wired? ────────────
  // 24 noisy 640x360 frames at a low QP and at a high QP. If mean delta-frame
  // bytes don't differ by >1.5x, the option is being ignored and every number
  // this arm would produce is fiction.
  {
    const encAt = async (qp) => {
      const sizes = [];
      const enc = new VideoEncoder({ output: (c) => sizes.push(c.byteLength), error: (e) => R.errors.push('preflight enc: ' + e) });
      const cfg = { codec: CFG.codec, width: 640, height: 360, framerate: 30,
        latencyMode: 'realtime', bitrateMode: 'quantizer' };
      if (optKey === 'avc') cfg.avc = { format: 'annexb' };
      enc.configure(cfg);
      let ts = 0;
      for (let i = 0; i < 24; i++) {
        const f = new VideoFrame(mkNoise(640, 360), { format: 'RGBA', codedWidth: 640, codedHeight: 360, timestamp: ts });
        const o = { keyFrame: i === 0 }; o[optKey] = { quantizer: qp };
        enc.encode(f, o); f.close(); ts += 33333;
      }
      try { await enc.flush(); } catch (e) { R.errors.push('preflight flush qp=' + qp + ': ' + e); }
      try { enc.close(); } catch {}
      const deltas = sizes.slice(1);
      return deltas.reduce((s, x) => s + x, 0) / Math.max(1, deltas.length);
    };
    const qLo = optKey === 'avc' ? 18 : 30;
    const qHi = optKey === 'avc' ? 46 : 220;
    const lo = await encAt(qLo), hi = await encAt(qHi);
    R.preflight = { qLo, qHi, meanBytesLo: Math.round(lo), meanBytesHi: Math.round(hi),
      ratio: +(lo / Math.max(1, hi)).toFixed(2), alive: lo > hi * 1.5 };
  }
  R.stage = 'preflight-done';
  if (!R.preflight.alive) { R.errors.push('preflight: quantizer knob appears dead'); return R; }

  // main-config support check BEFORE configure (tape.js does the same): a silent
  // bitrateMode downgrade would make the arm VBR wearing a fixed-QP costume.
  {
    const cfg = { codec: CFG.codec, width: CFG.width, height: CFG.height, framerate: CFG.fps,
      latencyMode: 'realtime', bitrateMode: 'quantizer' };
    if (optKey === 'avc') cfg.avc = { format: 'annexb' };
    try {
      const sup = await VideoEncoder.isConfigSupported(cfg);
      R.mainSupport = { supported: !!sup?.supported, echoedMode: sup?.config?.bitrateMode ?? null,
        hw: sup?.config?.hardwareAcceleration ?? null };
      if (!sup?.supported) { R.errors.push('main config unsupported'); return R; }
      if (sup.config?.bitrateMode && sup.config.bitrateMode !== 'quantizer') {
        R.errors.push('bitrateMode downgraded to ' + sup.config.bitrateMode); return R;
      }
    } catch (e) { R.errors.push('main isConfigSupported threw: ' + e); return R; }
  }
  R.stage = 'main-support-ok';

  // ── main arm: camera -> encoder -> decoder -> canvas, stills at 2 fps ─────
  const submitT = new Map();   // frame.timestamp -> ms at encode() submit
  const decSubmitT = new Map(); // chunk.timestamp -> ms at decode() submit
  const encLat = [], decLat = [];
  const stats = { read: 0, submitted: 0, droppedQueue: 0, chunks: 0, keyChunks: 0,
    bytes: 0, winBytes: 0, winChunks: 0, winSubmitted: 0, decoded: 0, winStart: 0, winEnd: 0 };
  try {
  const stream = await navigator.mediaDevices.getUserMedia({
    video: { width: CFG.width, height: CFG.height, frameRate: CFG.fps }, audio: false });
  const track = stream.getVideoTracks()[0];
  const settings = track.getSettings();
  R.track = { width: settings.width, height: settings.height, frameRate: settings.frameRate };

  const cvs = document.getElementById('gl');
  const ctx = cvs.getContext('2d', { alpha: false });

  const dec = new VideoDecoder({
    output: (f) => {
      const t = performance.now();
      const ts = decSubmitT.get(f.timestamp);
      if (ts != null) { decLat.push(t - ts); decSubmitT.delete(f.timestamp); }
      try { ctx.drawImage(f, 0, 0); } catch (e) { R.errors.push('draw: ' + e); }
      stats.decoded++;
      f.close();
    },
    error: (e) => R.errors.push('decoder: ' + e),
  });
  let decConfigured = false;

  const enc = new VideoEncoder({
    output: (chunk, meta) => {
      const t = performance.now();
      const ts = submitT.get(chunk.timestamp);
      if (ts != null) { encLat.push(t - ts); submitT.delete(chunk.timestamp); }
      stats.chunks++; stats.bytes += chunk.byteLength;
      if (chunk.type === 'key') stats.keyChunks++;
      if (stats.winStart && !stats.winEnd) { stats.winBytes += chunk.byteLength; stats.winChunks++; }
      if (!decConfigured) {
        const dc = meta?.decoderConfig;
        dec.configure({ codec: dc?.codec ?? CFG.codec,
          codedWidth: dc?.codedWidth ?? CFG.width, codedHeight: dc?.codedHeight ?? CFG.height,
          ...(dc?.description ? { description: dc.description } : {}),
          optimizeForLatency: true });
        decConfigured = true;
        R.decoderConfig = { codec: dc?.codec ?? CFG.codec, hasDescription: !!dc?.description,
          hw: dc?.hardwareAcceleration ?? null };
      }
      decSubmitT.set(chunk.timestamp, performance.now());
      dec.decode(chunk);
    },
    error: (e) => R.errors.push('encoder: ' + e),
  });
  const encCfg = { codec: CFG.codec, width: CFG.width, height: CFG.height, framerate: CFG.fps,
    latencyMode: 'realtime', bitrateMode: 'quantizer' };
  if (optKey === 'avc') encCfg.avc = { format: 'annexb' };
  enc.configure(encCfg);

  // stills grabber (same pattern as vmaf-call.mjs: offscreen copy + toBlob)
  const off = document.createElement('canvas');
  const offCtx = off.getContext('2d', { alpha: false });
  const stillsTimer = setInterval(() => {
    try {
      if (!cvs.width || !cvs.height) return;
      if (off.width !== cvs.width || off.height !== cvs.height) { off.width = cvs.width; off.height = cvs.height; }
      offCtx.drawImage(cvs, 0, 0);
      off.toBlob((b) => { if (b) window.__stills.push(b); }, 'image/png');
    } catch (e) { R.errors.push('stills: ' + e); }
  }, 1000 / CFG.stillsFps);

  const t0 = performance.now();
  const reader = new MediaStreamTrackProcessor({ track }).readable.getReader();
  let n = 0;
  while (performance.now() - t0 < CFG.warmupMs + CFG.capMs) {
    const { value: frame, done } = await reader.read();
    if (done) break;
    stats.read++;
    const now = performance.now();
    if (!stats.winStart && now - t0 >= CFG.warmupMs) stats.winStart = now;
    const inWindow = stats.winStart && now - t0 < CFG.warmupMs + CFG.capMs;
    if (enc.encodeQueueSize <= CFG.queueGate) {
      const o = { keyFrame: n % CFG.gop === 0 };
      o[optKey] = { quantizer: CFG.qp };
      submitT.set(frame.timestamp, performance.now());
      enc.encode(frame, o);
      stats.submitted++;
      if (inWindow) stats.winSubmitted++;
      n++;
    } else {
      stats.droppedQueue++;
    }
    frame.close();
  }
  stats.winEnd = performance.now();
  R.stage = 'capture-done';
  try { await enc.flush(); } catch (e) { R.errors.push('enc flush: ' + e); }
  try { await dec.flush(); } catch (e) { R.errors.push('dec flush: ' + e); }
  clearInterval(stillsTimer);
  reader.releaseLock();
  track.stop();
  } catch (e) { R.errors.push('main@' + R.stage + ': ' + e); }

  R.stats = stats;
  R.encLat = encLat;
  R.decLat = decLat;
  R.windowS = stats.winStart && stats.winEnd ? (stats.winEnd - stats.winStart) / 1000 : null;
  return R;
};
</script></body>`;

// ephemeral secure-ish origin for WebCodecs (flag below marks it trustworthy)
const server = createServer((req, res) => {
  res.setHeader('content-type', 'text/html');
  res.end(PAGE);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const PORT = server.address().port;
const ORIGIN = `http://127.0.0.1:${PORT}`;

const browser = await chromium.launch({
  executablePath: CHROME,
  headless: true,
  args: [
    '--use-fake-ui-for-media-stream',
    '--use-fake-device-for-media-stream',
    `--use-file-for-fake-video-capture=${VIDEO}`,
    '--autoplay-policy=no-user-gesture-required',
    `--unsafely-treat-insecure-origin-as-secure=${ORIGIN}`,
    '--allow-running-insecure-content',
  ],
});
const page = await browser.newPage();
const errors = [];
page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text().slice(0, 200)); });
page.on('pageerror', (e) => errors.push('pageerror: ' + String(e.message).slice(0, 200)));
await page.goto(ORIGIN + '/', { waitUntil: 'domcontentloaded' });

mkdirSync(OUTDIR, { recursive: true });
log(`  ${TAG}  codec=${CODEC} qp=${QP}  video=${VIDEO}`);
log(`  origin ${ORIGIN}  out ${OUTDIR}`);

// start the arm; pull stills while it runs
const runP = page.evaluate((CFG) => window.__run(CFG), {
  codec: CODEC, qp: QP, width: WIDTH, height: HEIGHT, fps: FPS,
  warmupMs: WARMUP_MS, capMs: CAP_MS, stillsFps: CAP_FPS, gop: GOP, queueGate: QUEUE_GATE,
});

const t0 = Date.now();
let nSaved = 0;
const pull = async () => {
  const batch = await page.evaluate(async () => {
    const blobs = window.__stills.splice(0);
    const out = [];
    for (const b of blobs) {
      const u8 = new Uint8Array(await b.arrayBuffer());
      let s = '';
      for (let i = 0; i < u8.length; i += 65536) s += String.fromCharCode.apply(null, u8.subarray(i, i + 65536));
      out.push(btoa(s));
    }
    return out;
  }).catch(() => []);
  for (const b64 of batch) {
    writeFileSync(join(OUTDIR, `dist_${String(nSaved).padStart(3, '0')}.png`), Buffer.from(b64, 'base64'));
    nSaved++;
  }
};
while (Date.now() - t0 < WARMUP_MS + CAP_MS + 2000) {
  await new Promise((r) => setTimeout(r, 3000));
  await pull();
}
const R = await runP;
await new Promise((r) => setTimeout(r, 800));
await pull();

const pct = (arr, p) => {
  const a = arr.filter((x) => Number.isFinite(x)).slice().sort((x, y) => x - y);
  if (!a.length) return null;
  return +a[Math.max(0, Math.min(a.length - 1, Math.floor((p / 100) * (a.length - 1))))].toFixed(2);
};
const lat = (arr) => {
  const inWin = arr.slice(Math.max(0, arr.length - Math.round(CAP_MS / 1000 * FPS)));
  return { p50: pct(inWin, 50), p95: pct(inWin, 95), mean: inWin.length ? +(inWin.reduce((s, x) => s + x, 0) / inWin.length).toFixed(2) : null, n: inWin.length };
};

const s = R.stats ?? {};
const windowS = R.windowS && R.windowS > 0 ? R.windowS : CAP_MS / 1000;
const result = {
  tag: TAG, codec: CODEC, qp: QP, video: VIDEO,
  ua: await page.evaluate(() => navigator.userAgent),
  support: R.support, preflight: R.preflight, mainSupport: R.mainSupport ?? null, decoderConfig: R.decoderConfig ?? null,
  track: R.track ?? null,
  capture: { windowS, stills: nSaved, warmupMs: WARMUP_MS, capMs: CAP_MS },
  frames: { read: s.read, submitted: s.submitted, droppedQueue: s.droppedQueue,
    winSubmitted: s.winSubmitted, chunks: s.chunks, keyChunks: s.keyChunks, decoded: s.decoded,
    admitted: s.read ? +(s.submitted / s.read).toFixed(3) : null },
  bytes: { total: s.bytes, window: s.winBytes },
  mbps: s.winBytes ? +((s.winBytes * 8) / windowS / 1e6).toFixed(2) : null,
  mbpsAtFps: s.winBytes && s.winChunks ? +(((s.winBytes / s.winChunks) * 8 * FPS) / 1e6).toFixed(2) : null,
  encLatMs: lat(R.encLat ?? []), decLatMs: lat(R.decLat ?? []),
  pageErrors: [...(R.errors ?? []), ...errors],
};
writeFileSync(join(OUTDIR, 'run.json'), JSON.stringify(result, null, 1));
log(`  RESULT ${JSON.stringify({ tag: TAG, codec: CODEC, qp: QP, stills: nSaved, mbps: result.mbps, mbpsAtFps: result.mbpsAtFps, admitted: result.frames.admitted, encP50: result.encLatMs.p50, encP95: result.encLatMs.p95, decP50: result.decLatMs.p50, preflight: result.preflight?.alive, errs: result.pageErrors.length })}`);

await browser.close();
server.close();
process.exit(0);
