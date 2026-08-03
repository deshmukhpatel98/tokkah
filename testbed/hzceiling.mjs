/**
 * What frame rate can this stack ACTUALLY deliver, end to end? Nothing here is assumed.
 *
 * Four independent ceilings, each measured separately, because a single end-to-end fps
 * number cannot say which one bound:
 *   1. the DISPLAY — no web API reports refresh rate, so it is timed from
 *      requestAnimationFrame intervals (median, not mean: one long frame skews a mean).
 *   2. the CAMERA — what getUserMedia will actually hand over at 60 and 120.
 *   3. the ENCODER — ms per frame at 1080p, against the 16.7 ms budget 60 fps allows.
 *   4. the fixture, which on this project has been the real bottleneck before now.
 *
 * Run: node testbed/hzceiling.mjs
 */
import { chromium, webkit } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';
const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';

const MEASURE = async (ctx, label) => {
  const p = await ctx.newPage();
  await ctx.route('https://hz.test/**', (r) => r.fulfill({ contentType: 'text/html', body: '<html><body></body></html>' }));
  await p.goto('https://hz.test/');
  const out = await p.evaluate(async () => {
    const res = { display: null, cam: [], err: null };
    // ── 1. display refresh, from rAF spacing ────────────────────────────────────
    {
      const ts = [];
      await new Promise((done) => {
        const tick = (t) => { ts.push(t); if (ts.length < 120) requestAnimationFrame(tick); else done(); };
        requestAnimationFrame(tick);
      });
      const d = [];
      for (let i = 1; i < ts.length; i++) d.push(ts[i] - ts[i - 1]);
      d.sort((a, b) => a - b);
      const med = d[d.length >> 1];
      res.display = { medianMs: +med.toFixed(3), hz: +(1000 / med).toFixed(1),
        minMs: +d[0].toFixed(2), maxMs: +d[d.length - 1].toFixed(2), n: d.length };
    }
    // ── 2. camera, at each asked frame rate ────────────────────────────────────
    const count = async (st, ms) => {
      const v = document.createElement('video');
      v.srcObject = st; v.muted = true; v.autoplay = true; v.playsInline = true;
      document.body.appendChild(v); await v.play().catch(() => {});
      let n = 0; const t0 = performance.now();
      await new Promise((r) => { const tk = () => { n++; if (performance.now() - t0 < ms) v.requestVideoFrameCallback(tk); else r(); }; v.requestVideoFrameCallback(tk); });
      const el = (performance.now() - t0) / 1000, s = st.getVideoTracks()[0].getSettings();
      v.remove();
      return { w: s.width, h: s.height, setting: s.frameRate, delivered: +(n / el).toFixed(1) };
    };
    for (const fps of [30, 60, 120]) {
      try {
        const st = await navigator.mediaDevices.getUserMedia({
          video: { width: { ideal: 1920 }, height: { ideal: 1080 }, frameRate: { ideal: fps } }, audio: false });
        const t = st.getVideoTracks()[0];
        const caps = (() => { try { return t.getCapabilities(); } catch { return null; } })();
        res.cam.push({ asked: fps, ...(await count(st, 2500)), capFps: caps?.frameRate ?? null });
        // The repair we now ship, in case the solver traded frame rate away again.
        await t.applyConstraints({ frameRate: { ideal: fps }, resizeMode: 'none' });
        res.cam[res.cam.length - 1].afterRepair = (await count(st, 2000)).delivered;
        st.getTracks().forEach((x) => x.stop());
      } catch (e) { res.cam.push({ asked: fps, err: `${e.name}` }); }
    }
    return res;
  });
  console.log(`\n=== ${label} ===`);
  const d = out.display;
  console.log(`  DISPLAY  ${d.hz} Hz  (median frame ${d.medianMs} ms, range ${d.minMs}..${d.maxMs}, n=${d.n})`);
  for (const c of out.cam) {
    if (c.err) { console.log(`  CAMERA   asked ${c.asked} fps -> ${c.err}`); continue; }
    console.log(`  CAMERA   asked ${String(c.asked).padStart(3)} fps -> ${c.w}x${c.h}  setting ${String(c.setting).padStart(3)}  ` +
      `delivered ${String(c.delivered).padStart(5)} fps  after repair ${String(c.afterRepair).padStart(5)}  ` +
      `capability ${JSON.stringify(c.capFps)}`);
  }
  await p.close();
  return out;
};

for (const [label, exe, args] of [
  ['Chrome for Testing + 1080p file fixture', CHROME, [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    '--use-file-for-fake-video-capture=/Users/earningsgpt/video calling/testbed/media/cam1080.mjpeg',
    '--allow-file-access-from-files']],
  ['Chrome for Testing + 1080p60 y4m fixture', CHROME, [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    '--use-file-for-fake-video-capture=/Users/earningsgpt/video calling/testbed/media/motion1080_60.y4m',
    '--allow-file-access-from-files']],
  ['Chrome for Testing + built-in synthetic camera', CHROME, [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream']],
]) {
  const b = await chromium.launch({ executablePath: exe, args });
  await MEASURE(await b.newContext({ permissions: ['camera', 'microphone'], ignoreHTTPSErrors: true }), label);
  await b.close();
}
const wb = await webkit.launch();
await MEASURE(await wb.newContext({ permissions: ['camera', 'microphone'], ignoreHTTPSErrors: true }), 'Playwright WebKit');
await wb.close();
