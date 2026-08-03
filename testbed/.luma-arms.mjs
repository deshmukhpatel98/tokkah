// Two luma readers, ONE camera track, same scene, same second.
//   A = exactly the shipped watchdog: hidden 2px off-screen <video> -> drawImage
//   B = the VideoFrame the source probe already receives -> drawImage
// If A reads ~0 while B reads a real number, the watchdog is blind and the
// low-light trigger (luma < 20) fires unconditionally on this device.
// Also runs A in a VISIBLE video element, to separate "off-screen" from
// "video element" as the cause.
import { chromium } from 'playwright-core';

const BASE = 'http://127.0.0.1:8794';
const b = await chromium.connectOverCDP('http://127.0.0.1:9222');
const ctx = b.contexts()[0];
for (const p of ctx.pages()) if (!p.isClosed() && p.url().startsWith(BASE)) await p.close().catch(() => {});
await ctx.grantPermissions(['camera', 'microphone'], { origin: BASE });

const page = await ctx.newPage();
let ready = false;
for (let i = 0; i < 8 && !ready; i++) {
  await page.goto(`${BASE}/?room=lumaarms`, { waitUntil: 'domcontentloaded' });
  ready = await page
    .waitForFunction(() => /ready/.test(document.getElementById('previewBadge')?.textContent ?? ''), { timeout: 8000 })
    .then(() => true)
    .catch(() => false);
  if (!ready) await page.waitForTimeout(2500);
}
if (!ready) throw new Error('lobby camera never became ready');

const out = await page.evaluate(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const track = document.querySelector('#preview').srcObject.getVideoTracks()[0];

  const mk = () => {
    const c = document.createElement('canvas');
    c.width = 64;
    c.height = 36;
    return c.getContext('2d', { willReadFrequently: true });
  };
  const meanOf = (cx) => {
    const d = cx.getImageData(0, 0, 64, 36).data;
    let s = 0;
    for (let i = 0; i < d.length; i += 4) s += 0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2];
    return +(s / (d.length / 4)).toFixed(1);
  };

  // ARM A — the shipped watchdog, verbatim (app.js startLumaWatchdog).
  const vHidden = document.createElement('video');
  vHidden.muted = true;
  vHidden.playsInline = true;
  vHidden.autoplay = true;
  vHidden.style.cssText = 'position:absolute;left:-9999px;top:-9999px;width:2px;height:2px';
  document.body.appendChild(vHidden);
  vHidden.srcObject = new MediaStream([track]);
  const cxA = mk();

  // ARM A' — same thing but ON SCREEN and full size: isolates off-screen-ness.
  const vShown = document.createElement('video');
  vShown.muted = true;
  vShown.playsInline = true;
  vShown.autoplay = true;
  vShown.style.cssText = 'position:fixed;left:0;top:0;width:160px;height:120px;z-index:99999';
  document.body.appendChild(vShown);
  vShown.srcObject = new MediaStream([track]);
  const cxB = mk();

  // ARM B — the VideoFrame path.
  const reader = new MediaStreamTrackProcessor({ track }).readable.getReader();
  let lastFrame = null;
  let frames = 0;
  (async () => {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) return;
      frames++;
      if (lastFrame) lastFrame.close();
      lastFrame = value;
    }
  })().catch(() => {});
  const cxC = mk();

  await sleep(4000); // AE settles; every element has had time to start

  const rows = [];
  for (let i = 0; i < 6; i++) {
    await sleep(1000);
    let a = null;
    let aState = `rs=${vHidden.readyState} vw=${vHidden.videoWidth} paused=${vHidden.paused}`;
    try {
      if (vHidden.readyState >= 2 && vHidden.videoWidth) {
        cxA.drawImage(vHidden, 0, 0, 64, 36);
        a = meanOf(cxA);
      }
    } catch (e) {
      aState += ' ERR ' + e.name;
    }
    let a2 = null;
    try {
      if (vShown.readyState >= 2 && vShown.videoWidth) {
        cxB.drawImage(vShown, 0, 0, 64, 36);
        a2 = meanOf(cxB);
      }
    } catch {}
    let c = null;
    if (lastFrame) {
      const bmp = await createImageBitmap(lastFrame);
      cxC.drawImage(bmp, 0, 0, 64, 36);
      bmp.close();
      c = meanOf(cxC);
    }
    rows.push({ hiddenVideo: a, shownVideo: a2, videoFrame: c, hiddenState: aState });
  }

  reader.cancel().catch(() => {});
  vHidden.remove();
  vShown.remove();
  return { rows, frames, settings: track.getSettings() };
});

console.log('  reader                sample means');
const col = (k) => out.rows.map((r) => String(r[k]).padStart(6)).join(' ');
console.log('  hidden 2px <video>  ', col('hiddenVideo'));
console.log('  visible <video>     ', col('shownVideo'));
console.log('  VideoFrame          ', col('videoFrame'));
console.log('  hidden element state ', out.rows[out.rows.length - 1].hiddenState);
console.log('  frames delivered     ', out.frames, ' settings', JSON.stringify({ w: out.settings.width, h: out.settings.height, exp: out.settings.exposureTime }));
await page.close().catch(() => {});
await b.close();
