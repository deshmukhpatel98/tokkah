/**
 * vmaf-call.mjs — receiver-side frame capture for the fixed-QP vs VP8-under-GCC
 * quality comparison (the §17.11-confessed cross-stack debt: latency was compared
 * across two different stacks; the QUALITY comparison is owed).
 *
 * Two browsers, the standard 1080p fake-camera fixture, one call, loopback.
 * Captures what the RECEIVER (B) actually presents — `#remoteCanvas` on the
 * custom lane (§17.8 paint-on-arrival; backing store = full frame) or
 * `<video id="remote">` on the RTP fallback — as 1080p PNG stills at 2 fps,
 * plus the counters needed to state each arm's DELIVERED bitrate over exactly
 * the captured window (tape.snapshot() diff for lane 2, getStats diff for VP8).
 *
 * The VP8 bitrate cap is applied from HERE (sender setParameters maxBitrate,
 * the app's own mechanism at app.js:1289) so no app file changes per arm.
 * Law 1 untouched: setParameters is never called on a tape=2 page.
 *
 *   node vmaf-call.mjs --tag=lane-qp24 --q='tape=2&pcmaudio=1&qp=24' --out=/path/dir
 *   node vmaf-call.mjs --tag=vp8-2000k --q='codec=vp8' --cap=2000 --out=/path/dir
 *   node vmaf-call.mjs --tag=vp8-free --q='codec=vp8' --out=/path/dir   (app's 12M cap)
 *
 * SERIAL RULE (shared machine): the caller must pgrep -f "call\.mjs|sctpwall\.mjs"
 * before launching; this script does not police other agents.
 */

import { chromium } from 'playwright-core';
import { writeFileSync, mkdirSync, existsSync, readFileSync, readdirSync, unlinkSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const CHROME =
  process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');

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
const ROOM = `vmaf-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
const TAG = args.tag ?? 'vmaf';
const OUTDIR = args.out ? resolve(String(args.out)) : join(HERE, 'runs', `${TAG}-${ROOM}`);
const VIDEO = resolve(HERE, String(args.video ?? 'media/cam1080.mjpeg'));
const CAP_KBPS = args.cap ? Number(args.cap) : 0; // 0 = leave the app's own 12 Mbps sender cap
const WARMUP_MS = Number(args.warmup ?? 10) * 1000;
const CAP_MS = Number(args.capms ?? 26000);
const CAP_FPS = Number(args.fps ?? 2);
const HEADED = !!args.headed;

const log = (s) => console.log(s);

async function launch(side, wav) {
  const browser = await chromium.launch({
    executablePath: CHROME,
    headless: !HEADED,
    args: [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      `--use-file-for-fake-video-capture=${VIDEO}`,
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
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text().slice(0, 200)); });
  page.on('pageerror', (e) => errors.push('pageerror: ' + String(e.message).slice(0, 200)));
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

const A = await launch('A', resolve(HERE, String(args.wavA ?? 'media/conv/A.wav')));
const B = await launch('B', resolve(HERE, String(args.wavB ?? 'media/conv/B.wav')));
log(`  ${TAG}  room ${ROOM}  url ${PAGE_URL}`);
await Promise.all([A.page.click('#join'), B.page.click('#join')]);

const connected = async (p, ms) => {
  try {
    await p.page.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: ms });
    return true;
  } catch { return false; }
};
const [ca, cb] = await Promise.all([connected(A, 45000), connected(B, 45000)]);
log(`  connected: A=${ca} B=${cb}`);
if (!ca || !cb) {
  for (const s of [A, B]) {
    const st = await s.page.evaluate(() => ({
      status: document.getElementById('status')?.textContent,
      ice: window.__tape?.pc?.iceConnectionState,
      conn: window.__tape?.pc?.connectionState,
      mode: window.__tape?.tapeMode,
    })).catch(() => null);
    log(`  ${s.side}: ${JSON.stringify(st)}  errors: ${s.errors.slice(0, 3).join(' | ')}`);
  }
  process.exit(1);
}

// VP8 sweep knob: cap the video sender's maxBitrate. This is exactly the app's own
// sender-params write (app.js:1289 sets 12_000_000 once at join); we overwrite it
// here per arm. Only ever invoked on fallback (wantTape=0) pages — lane-2 arms
// never pass --cap, and the guard below refuses to run if one does.
if (CAP_KBPS) {
  for (const s of [A, B]) {
    const r = await s.page.evaluate(async (kbps) => {
      if (window.__tape?.tapeMode?.wanted === 2) return 'REFUSED: tape=2 page (law 1)';
      let n = 0;
      for (const snd of window.__tape.pc.getSenders()) {
        if (snd.track?.kind !== 'video') continue;
        const p = snd.getParameters();
        p.encodings = p.encodings?.length ? p.encodings : [{}];
        p.encodings[0].maxBitrate = kbps * 1000;
        await snd.setParameters(p);
        n++;
      }
      return `capped ${n} video sender(s) at ${kbps} kbps`;
    }, CAP_KBPS);
    log(`  ${s.side}: ${r}`);
  }
}

// What is B actually looking at? #remoteCanvas on the custom lane (§17.8),
// <video id="remote"> on the RTP fallback. Record which for the note.
const disp = await B.page.evaluate(() => ({
  canvas: !!document.getElementById('remoteCanvas'),
  video: !!document.getElementById('remote'),
  mode: window.__tape?.tapeMode,
  fellBack: window.__tape?.tapeMode?.fellBack ?? null,
}));
log(`  B display: ${JSON.stringify(disp)}`);

const snapLane = (s) => s.page.evaluate(() => window.__tape?.video ?? null).catch(() => null);
const snapRtp = async (s, dir) =>
  s.page.evaluate(async (dir) => {
    const pc = window.__tape?.pc;
    if (!pc) return null;
    const out = { bytes: 0, frames: 0, framesDropped: 0, ts: performance.now() };
    (await pc.getStats()).forEach((r) => {
      if (dir === 'out' && r.type === 'outbound-rtp' && (r.kind ?? r.mediaType) === 'video') {
        out.bytes += r.bytesSent ?? 0; out.frames += r.framesSent ?? r.framesEncoded ?? 0;
      }
      if (dir === 'in' && r.type === 'inbound-rtp' && (r.kind ?? r.mediaType) === 'video') {
        out.bytes += r.bytesReceived ?? 0; out.frames += r.framesDecoded ?? 0;
        out.framesDropped += r.framesDropped ?? 0;
      }
    });
    return out;
  }, dir).catch(() => null);

log(`  warmup ${WARMUP_MS / 1000}s (GCC ramp / governor climb)…`);
await new Promise((r) => setTimeout(r, WARMUP_MS));

// Arm the in-page grabber on B. toBlob (async encode) rather than toDataURL so the
// PNG encode stays off the critical paint path as much as the platform allows;
// Node pulls accumulated blobs every ~3 s to bound page memory.
await B.page.evaluate((fps) => {
  window.__stills = [];
  window.__capErr = null;
  window.__capFrames = 0;
  const el = document.getElementById('remoteCanvas') || document.getElementById('remote');
  if (!el) { window.__capErr = 'no display element'; return; }
  const off = document.createElement('canvas');
  const ctx = off.getContext('2d', { alpha: false });
  window.__capTimer = setInterval(() => {
    try {
      const w = el.tagName === 'VIDEO' ? el.videoWidth : el.width;
      const h = el.tagName === 'VIDEO' ? el.videoHeight : el.height;
      if (!w || !h) return;
      if (off.width !== w || off.height !== h) { off.width = w; off.height = h; }
      ctx.drawImage(el, 0, 0);
      window.__capFrames++;
      off.toBlob((b) => { if (b) window.__stills.push(b); }, 'image/png');
    } catch (e) { window.__capErr = String(e); }
  }, 1000 / fps);
}, CAP_FPS);

mkdirSync(OUTDIR, { recursive: true });
// REFUSE to write over another arm. `dist_NNN.png` and `run.json` are fixed names, so
// pointing two arms at one --out silently replaces the first arm's captures with the
// second's and leaves a directory that LOOKS like a complete run. That happened: a
// fixed-QP arm and a forced-VBR arm were run back to back into one dir and only the VBR
// stills survived, with nothing in the output saying so. An A/B whose two arms cannot
// coexist on disk must fail loudly, not quietly become a single arm measured twice.
{
  const prior = join(OUTDIR, 'run.json');
  if (existsSync(prior)) {
    let priorTag = null;
    try { priorTag = JSON.parse(readFileSync(prior, 'utf8')).tag ?? null; } catch { priorTag = '(unparseable)'; }
    if (priorTag !== TAG) {
      console.error(`\nREFUSING to run: ${OUTDIR} already holds arm "${priorTag}".`);
      console.error(`  dist_*.png and run.json are fixed names, so this run would overwrite it and`);
      console.error(`  the result would look like one complete arm instead of a destroyed A/B.`);
      console.error(`  Give each arm its own --out (e.g. --out=<dir>/${TAG}), or omit --out.`);
      process.exit(2);
    }
    const stale = readdirSync(OUTDIR).filter((f) => /^dist_\d+\.png$/.test(f));
    for (const f of stale) unlinkSync(join(OUTDIR, f));
    if (stale.length) log(`  cleared ${stale.length} still(s) from a previous run of this same arm`);
  }
}
const sLaneA0 = await snapLane(A), sLaneB0 = await snapLane(B);
const sRtpA0 = await snapRtp(A, 'out'), sRtpB0 = await snapRtp(B, 'in');

const t0 = Date.now();
let nSaved = 0;
while (Date.now() - t0 < CAP_MS) {
  await new Promise((r) => setTimeout(r, 3000));
  const batch = await B.page.evaluate(async () => {
    const blobs = window.__stills.splice(0);
    const out = [];
    for (const b of blobs) {
      const u8 = new Uint8Array(await b.arrayBuffer());
      let s = '';
      for (let i = 0; i < u8.length; i += 65536) s += String.fromCharCode.apply(null, u8.subarray(i, i + 65536));
      out.push(btoa(s));
    }
    return out;
  }).catch((e) => { log(`  pull error: ${e?.message ?? e}`); return []; });
  for (const b64 of batch) {
    writeFileSync(join(OUTDIR, `dist_${String(nSaved).padStart(3, '0')}.png`), Buffer.from(b64, 'base64'));
    nSaved++;
  }
}
await B.page.evaluate(() => clearInterval(window.__capTimer));
// drain the tail
await new Promise((r) => setTimeout(r, 1200));
const tail = await B.page.evaluate(async () => {
  const blobs = window.__stills.splice(0);
  const out = [];
  for (const b of blobs) {
    const u8 = new Uint8Array(await b.arrayBuffer());
    let s = '';
    for (let i = 0; i < u8.length; i += 65536) s += String.fromCharCode.apply(null, u8.subarray(i, i + 65536));
    out.push(btoa(s));
  }
  return { out, err: window.__capErr, frames: window.__capFrames };
});
for (const b64 of tail.out) {
  writeFileSync(join(OUTDIR, `dist_${String(nSaved).padStart(3, '0')}.png`), Buffer.from(b64, 'base64'));
  nSaved++;
}

const sLaneA1 = await snapLane(A), sLaneB1 = await snapLane(B);
const sRtpA1 = await snapRtp(A, 'out'), sRtpB1 = await snapRtp(B, 'in');

const windowS = (Date.now() - t0) / 1000;
const laneDelta = (a, b) =>
  a && b ? {
    bytesSent: (b.bytesSent ?? 0) - (a.bytesSent ?? 0),
    framesEncoded: (b.framesEncoded ?? 0) - (a.framesEncoded ?? 0),
    framesIn: (b.framesIn ?? 0) - (a.framesIn ?? 0),
    framesOut: (b.framesOut ?? 0) - (a.framesOut ?? 0),
    framesLost: (b.framesLost ?? 0) - (a.framesLost ?? 0),
    mbpsAtFps: b.mbpsAtFps,
    ageP50: b.ageP50, fullAgeP50: b.fullAgeP50,
    // WHY frames went missing, not just how many. The hard-content VBR arm encoded 365 of
    // 830 frames and the cause was unattributable from this report — a 56% frame loss with
    // no mechanism beside it is a number, not a finding. These are the same five causes
    // realpair.mjs reconciles; a sum that misses the total means a cause is unlisted.
    skipPaced: (b.skipPaced ?? 0) - (a.skipPaced ?? 0),
    skipBuffered: (b.skipBuffered ?? 0) - (a.skipBuffered ?? 0),
    skipEncQueue: (b.skipEncQueue ?? 0) - (a.skipEncQueue ?? 0),
    skipDecodeStalled: (b.skipDecodeStalled ?? 0) - (a.skipDecodeStalled ?? 0),
    skipShed: (b.skipShed ?? 0) - (a.skipShed ?? 0),
    carrierDropped: (b.carrierDropped ?? 0) - (a.carrierDropped ?? 0),
    encQueuePeak: b.encQueuePeak ?? null,
    admitRate: b.admitRate ?? null,
    rcQp: b.rcQp ?? null,
    rcVbrBps: b.rcVbrBps ?? null, rcBudgetMbps: b.rcBudgetMbps ?? null,
    rateControl: b.rateControl ?? null,
  } : null;
const rtpDelta = (a, b) =>
  a && b ? {
    bytes: b.bytes - a.bytes,
    frames: b.frames - a.frames,
    framesDropped: (b.framesDropped ?? 0) - (a.framesDropped ?? 0),
  } : null;

const result = {
  tag: TAG, room: ROOM, url: PAGE_URL, capKbps: CAP_KBPS || null,
  capture: { fps: CAP_FPS, windowS, stills: nSaved, capErr: tail.err, capFrames: tail.frames },
  display: disp,
  lane: { senderA: laneDelta(sLaneA0, sLaneA1), receiverB: laneDelta(sLaneB0, sLaneB1) },
  rtp: { senderA: rtpDelta(sRtpA0, sRtpA1), receiverB: rtpDelta(sRtpB0, sRtpB1) },
  laneEnd: { A: sLaneA1, B: sLaneB1 },
  errors: { A: A.errors, B: B.errors },
};
writeFileSync(join(OUTDIR, 'run.json'), JSON.stringify(result, null, 1));
log(`  captured ${nSaved} stills over ${windowS.toFixed(1)}s → ${OUTDIR}`);
log(`  RESULT ${JSON.stringify({ tag: TAG, stills: nSaved, lane: result.lane, rtp: result.rtp, display: disp.mode })}`);

await Promise.all([A.browser.close(), B.browser.close()]);
process.exit(0);
