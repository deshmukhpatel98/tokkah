/**
 * What does a frame actually cost to encode, at 1080p, as a function of frame rate?
 *
 * This decides how far we can follow a 144 Hz display. It needs no camera fixture — a
 * synthetic canvas with real changing content is enough to load the encoder, and it
 * keeps the measurement off the fixture's ceiling (a 30 fps fixture cannot tell you
 * anything about 144 fps).
 *
 * Reports ms of encode per frame AND the resulting fraction of one core, because the
 * second is what says whether a rate is affordable. Also reports bytes/frame, since a
 * rate we cannot carry is as unusable as one we cannot encode.
 */
import { chromium } from '/Users/deveshpatel/Downloads/video calling/testbed/node_modules/playwright-core/index.mjs';
const CHROME = process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const b = await chromium.launch({ executablePath: CHROME });
const ctx = await b.newContext({ ignoreHTTPSErrors: true });
const p = await ctx.newPage();
await ctx.route('https://enc.test/**', (r) => r.fulfill({ contentType: 'text/html', body: '<html><body></body></html>' }));
await p.goto('https://enc.test/');
const rows = await p.evaluate(async () => {
  const out = [];
  for (const fps of [30, 60, 72, 120, 144]) {
    const N = Math.min(240, fps * 2);
    const cvs = new OffscreenCanvas(1920, 1080);
    const g = cvs.getContext('2d');
    let bytes = 0, chunks = 0, err = null;
    const enc = new VideoEncoder({ output: (c) => { chunks++; bytes += c.byteLength; }, error: (e) => { err = String(e); } });
    // The lane's real config: fixed QP, realtime, annexb.
    enc.configure({ codec: 'avc1.640028', width: 1920, height: 1080, framerate: fps,
      latencyMode: 'realtime', bitrateMode: 'quantizer', avc: { format: 'annexb' } });
    const t0 = performance.now();
    let done = 0;
    for (let i = 0; i < N; i++) {
      // The error callback closes the codec, so a loop that keeps calling encode() turns
      // the REAL failure into a generic InvalidStateError on the next call — which is
      // what hid the first reading entirely.
      if (err) break;
      // Real motion, so the encoder cannot cheat with a static scene.
      g.fillStyle = `hsl(${(i * 7) % 360} 60% 45%)`;
      g.fillRect(0, 0, 1920, 1080);
      g.fillStyle = '#fff';
      g.fillRect((i * 23) % 1700, (i * 11) % 900, 200, 160);
      g.font = '120px sans-serif';
      g.fillText(`frame ${i}`, 60 + ((i * 3) % 400), 300);
      const f = new VideoFrame(cvs, { timestamp: Math.round((i * 1e6) / fps) });
      try { enc.encode(f, { keyFrame: i === 0, avc: { quantizer: 24 } }); done++; }
      catch (e) { err = err ?? `${e.name}: ${e.message}`; f.close(); break; }
      f.close();
      // Do not let the queue grow without bound — that measures the queue, not the encoder.
      if (enc.encodeQueueSize > 8) await new Promise((r) => setTimeout(r, 0));
    }
    await enc.flush().catch((e) => { err = err ?? String(e); });
    const wall = performance.now() - t0;
    try { enc.close(); } catch { /* already closed by the error path */ }
    const n = Math.max(1, done);
    out.push({ fps, frames: done, msPerFrame: +(wall / n).toFixed(2),
      coreFrac: +((fps * (wall / n)) / 1000).toFixed(3),
      kbPerFrame: chunks ? +(bytes / chunks / 1024).toFixed(1) : null,
      mbps: chunks ? +((bytes / chunks) * 8 * fps / 1e6).toFixed(2) : null, chunks, err });
  }
  return out;
});
console.log(`\n1080p H.264 High, fixed QP 24, realtime — encode cost vs frame rate`);
console.log(`  fps    ms/frame   share of 1 core   KB/frame   implied Mbps`);
for (const r of rows) {
  if (r.err) { console.log(`  ${String(r.fps).padStart(3)}    FAILED after ${r.frames} frames: ${r.err}`); continue; }
  console.log(`  ${String(r.fps).padStart(3)}    ${String(r.msPerFrame).padStart(8)}   ` +
    `${String((r.coreFrac * 100).toFixed(1) + '%').padStart(15)}   ${String(r.kbPerFrame).padStart(8)}   ` +
    `${String(r.mbps).padStart(12)}${r.err ? '  ERR ' + r.err : ''}`);
}
await b.close();
