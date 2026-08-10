/**
 * colormtx-probe.mjs — which YCbCr→RGB matrix does Chrome's canvas apply to the
 * fake camera's VideoFrames? Needed to score presented stills against the
 * source fixture honestly (601 vs 709 moves PSNR by ~5 dB on this content).
 *
 * One browser, no call: getUserMedia the fake camera, drawImage to a canvas,
 * toDataURL, save one PNG. Scored offline against matrix variants.
 */
import { chromium } from 'playwright-core';
import { writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const CHROME =
  process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const OUT = process.argv[2];
const VIDEO = resolve(HERE, 'media/cam1080.mjpeg');

const browser = await chromium.launch({
  executablePath: CHROME,
  headless: true,
  args: [
    '--use-fake-ui-for-media-stream',
    '--use-fake-device-for-media-stream',
    `--use-file-for-fake-video-capture=${VIDEO}`,
    '--autoplay-policy=no-user-gesture-required',
    '--unsafely-treat-insecure-origin-as-secure=http://127.0.0.1:8794',
    '--allow-running-insecure-content',
  ],
});
const page = await browser.newPage();
await page.goto('http://127.0.0.1:8794/', { waitUntil: 'domcontentloaded' });
await page.waitForSelector('#join', { timeout: 20000 });
// Wait past the lobby preview's own startup, then grab three frames 700 ms apart.
for (let i = 0; i < 3; i++) {
  await new Promise((r) => setTimeout(r, 700));
  const b64 = await page.evaluate(async () => {
    const v = document.createElement('video');
    v.muted = true;
    if (!window.__probeStream) {
      window.__probeStream = await navigator.mediaDevices.getUserMedia({
        video: { width: { ideal: 1920 }, height: { ideal: 1080 } }, audio: false,
      });
    }
    v.srcObject = window.__probeStream;
    await v.play();
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    const c = document.createElement('canvas');
    c.width = v.videoWidth; c.height = v.videoHeight;
    c.getContext('2d', { alpha: false }).drawImage(v, 0, 0);
    return c.toDataURL('image/png').split(',')[1];
  });
  writeFileSync(`${OUT}/probe_${i}.png`, Buffer.from(b64, 'base64'));
}
await browser.close();
console.log('wrote probe stills to ' + OUT);
