/**
 * camprobe.mjs — can this harness reach a REAL camera sensor on this Mac?
 *
 * Every camera-path result in this repo is only as good as the sensor behind
 * it (the real-sensor law), and the two lanes that were supposed to provide one
 * are both unavailable here: the Android emulator's webcam passthrough is dead
 * on Darwin 27, and no phone is tethered. This asks the remaining question —
 * whether the testbed's own Chrome can open the Mac's camera — and, crucially,
 * whether what comes back is a real picture rather than the black frame macOS
 * hands to a process it has denied.
 *
 * A denied camera on macOS does NOT throw. getUserMedia resolves, the track
 * reads "live", and every frame is uniformly black. Checking only that frames
 * arrive would report success on a sensor that is switched off — the same shape
 * of mistake as a green rig shipping an upside-down picture. So this measures
 * variance and inter-frame change: a real room is never uniform and never
 * perfectly identical twice.
 *
 *   node testbed/camprobe.mjs [--headed]
 */
import { chromium } from 'playwright-core';

const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const headed = process.argv.includes('--headed');

const browser = await chromium.launch({
  executablePath: CHROME, headless: !headed,
  args: ['--use-fake-ui-for-media-stream', '--autoplay-policy=no-user-gesture-required'],
});
try {
  const page = await browser.newPage();
  // Pin a room and wait for the app to settle. Landing on `/` makes the app
  // invent a room id and rewrite the URL, and that navigation destroys the
  // execution context mid-evaluate.
  await page.goto('https://room.tokkah.com/?r=camprobe', { waitUntil: 'load', timeout: 60000 });
  await page.waitForTimeout(3000);
  const r = await page.evaluate(async () => {
    const out = { ok: false, err: null, label: null, w: 0, h: 0, mean: 0, variance: 0, change: 0 };
    let stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ video: { width: 1280, height: 720 } });
    } catch (e) { out.err = `${e.name}: ${e.message}`; return out; }
    const track = stream.getVideoTracks()[0];
    out.label = track.label; out.state = track.readyState;
    const v = document.createElement('video');
    v.srcObject = stream; v.muted = true; await v.play().catch(() => {});
    await new Promise((res) => setTimeout(res, 1500)); // let auto-exposure settle
    out.w = v.videoWidth; out.h = v.videoHeight;
    if (!out.w) { out.err = 'no frames'; track.stop(); return out; }

    const c = document.createElement('canvas');
    c.width = 160; c.height = 90;
    const ctx = c.getContext('2d', { willReadFrequently: true });
    const luma = () => {
      ctx.drawImage(v, 0, 0, 160, 90);
      const d = ctx.getImageData(0, 0, 160, 90).data;
      const a = new Float64Array(160 * 90);
      for (let i = 0; i < a.length; i++) a[i] = 0.299 * d[i * 4] + 0.587 * d[i * 4 + 1] + 0.114 * d[i * 4 + 2];
      return a;
    };
    const f0 = luma();
    await new Promise((res) => setTimeout(res, 400));
    const f1 = luma();
    let s = 0; for (const x of f0) s += x;
    out.mean = s / f0.length;
    let vsum = 0; for (const x of f0) vsum += (x - out.mean) ** 2;
    out.variance = vsum / f0.length;
    let ch = 0; for (let i = 0; i < f0.length; i++) ch += Math.abs(f1[i] - f0[i]);
    out.change = ch / f0.length;
    track.stop();
    // A denied camera resolves fine and yields a flat black picture, so the
    // proof of a real sensor is spatial detail AND frame-to-frame life.
    out.ok = out.variance > 25 && out.change > 0.2;
    return out;
  });
  console.log(JSON.stringify(r, null, 2));
  console.log(r.ok
    ? `\nREAL SENSOR: "${r.label}" ${r.w}x${r.h}, detail ${r.variance.toFixed(0)}, motion ${r.change.toFixed(2)}/px`
    : `\nNO REAL SENSOR${r.err ? ` — ${r.err}` : ' — frames arrive but the picture is flat (macOS is denying the camera)'}`);
  process.exit(r.ok ? 0 : 1);
} finally {
  await browser.close();
}
