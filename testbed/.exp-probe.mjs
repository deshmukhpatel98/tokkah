// Directly interrogate the M13's exposure control, with no app in the way.
//   1. open the camera, let AE settle, measure delivered fps + read back exposureTime
//   2. apply the shipped low-light constraints, measure again
//   3. report scene statistics (min/mean/max luma) so "dark" can be told apart
//      from "lens covered"
// Answers: are the getSettings() exposure numbers trustworthy, and is the fps
// win real or an artifact of how the harness samples.
import { chromium } from 'playwright-core';

const BASE = 'http://127.0.0.1:8794';
const b = await chromium.connectOverCDP('http://127.0.0.1:9222');
const ctx = b.contexts()[0];
for (const p of ctx.pages()) if (!p.isClosed() && p.url().startsWith(BASE)) await p.close().catch(() => {});
await ctx.grantPermissions(['camera', 'microphone'], { origin: BASE });

const page = await ctx.newPage();
// The HAL needs several seconds to release between runs; reload until the
// app's own lobby badge says the camera actually opened.
let ready = false;
for (let i = 0; i < 8 && !ready; i++) {
  await page.goto(`${BASE}/?room=expprobe`, { waitUntil: 'domcontentloaded' });
  ready = await page
    .waitForFunction(() => /ready/.test(document.getElementById('previewBadge')?.textContent ?? ''), { timeout: 8000 })
    .then(() => true)
    .catch(() => false);
  if (!ready) await page.waitForTimeout(2500);
}
if (!ready) throw new Error('lobby camera never became ready');

const out = await page.evaluate(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  // Take over the lobby preview's track rather than opening a second camera:
  // that is precisely what production does (getMedia's `reuseV` branch), and
  // the M13 will not hand out a second handle anyway.
  const track = document.querySelector('#preview')?.srcObject?.getVideoTracks?.()[0];
  if (!track || track.readyState !== 'live') throw new Error('no live preview track to borrow');
  // The app's join-time re-apply, same constraint object.
  await track.applyConstraints({ width: { ideal: 1920 }, height: { ideal: 1080 }, frameRate: { ideal: 30 }, resizeMode: 'none' });

  // Count real delivered frames off the same API the app uses.
  const proc = new MediaStreamTrackProcessor({ track });
  const reader = proc.readable.getReader();
  let frames = 0;
  let last = null;
  (async () => {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) return;
      frames++;
      if (last) last.close();
      last = value;
    }
  })();

  const cv = document.createElement('canvas');
  cv.width = 64;
  cv.height = 36;
  const cx = cv.getContext('2d', { willReadFrequently: true });
  const scene = async () => {
    if (!last) return null;
    const bmp = await createImageBitmap(last);
    cx.drawImage(bmp, 0, 0, 64, 36);
    bmp.close();
    const d = cx.getImageData(0, 0, 64, 36).data;
    let s = 0;
    let mn = 255;
    let mx = 0;
    for (let i = 0; i < d.length; i += 4) {
      const y = 0.2126 * d[i] + 0.7152 * d[i + 1] + 0.0722 * d[i + 2];
      s += y;
      if (y < mn) mn = y;
      if (y > mx) mx = y;
    }
    return { mean: +(s / (d.length / 4)).toFixed(1), min: +mn.toFixed(1), max: +mx.toFixed(1) };
  };

  const measure = async (ms) => {
    const f0 = frames;
    const t0 = performance.now();
    await sleep(ms);
    return +(((frames - f0) / (performance.now() - t0)) * 1000).toFixed(1);
  };
  const pickS = () => {
    const s = track.getSettings();
    return { exposureTime: s.exposureTime, exposureMode: s.exposureMode, iso: s.iso, w: s.width, h: s.height, fr: s.frameRate };
  };

  const caps = track.getCapabilities();
  await sleep(3000); // let AE settle on the real scene
  const phaseAE = { fps: await measure(4000), settings: pickS(), scene: await scene() };

  // Exactly what the shipped low-light path does, in the same order.
  let applyErr = null;
  try {
    await track.applyConstraints({ frameRate: { ideal: 30 } });
    await track.applyConstraints({ exposureMode: 'manual', exposureTime: 33.33, iso: 2500 });
  } catch (e) {
    applyErr = e.name + ': ' + e.message;
  }
  await sleep(1200);
  const phaseManual = { fps: await measure(4000), settings: pickS(), scene: await scene(), applyErr };

  // And a deliberately LONG exposure, to see whether the read-back tracks at all.
  let longErr = null;
  try {
    await track.applyConstraints({ exposureMode: 'manual', exposureTime: 300, iso: 2500 });
  } catch (e) {
    longErr = e.name + ': ' + e.message;
  }
  await sleep(1200);
  const phaseLong = { fps: await measure(4000), settings: pickS(), scene: await scene(), longErr };

  reader.cancel().catch(() => {});
  // leave the track alone — it belongs to the page
  return { caps: { exposureTime: caps.exposureTime, iso: caps.iso, exposureMode: caps.exposureMode }, phaseAE, phaseManual, phaseLong };
});

console.log(JSON.stringify(out, null, 2));
await page.close().catch(() => {});
await b.close();
