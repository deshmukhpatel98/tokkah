/**
 * What can the REAL webcam on this machine do?
 *
 * Every frame-rate figure measured today came from a browser launched with
 * --use-file-for-fake-video-capture, so all of them are facts about a FIXTURE. cam1080.mjpeg
 * is capped at 30 by the MJPEG container (Chrome ignores its declared 25/1 and delivers 30),
 * which looks exactly like a 30 fps camera. Launched WITHOUT that flag, on a throwaway
 * profile, so the answer is about the hardware.
 *
 * Only the initial getUserMedia decides the rate — a live track's frame rate cannot be raised
 * by applyConstraints on this machine — so each rung is a fresh open.
 */
import { chromium } from '/Users/deveshpatel/Downloads/video calling/testbed/node_modules/playwright-core/index.mjs';
const BRAVE = '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser';
const ctx = await chromium.launchPersistentContext(process.argv[2], {
  executablePath: BRAVE, headless: false,
  args: ['--use-fake-ui-for-media-stream', '--no-first-run', '--no-default-browser-check'],
});
await ctx.grantPermissions(['camera', 'microphone'], { origin: 'https://room.tokkah.com' });
const page = await ctx.newPage();
await page.goto('https://room.tokkah.com/?r=camprobe' + Date.now(), { waitUntil: 'domcontentloaded' });
const out = await page.evaluate(async () => {
  const res = { devices: [], caps: null, ladder: [] };
  const s0 = await navigator.mediaDevices.getUserMedia({ video: true });
  const t0 = s0.getVideoTracks()[0];
  res.caps = { label: t0.label, ...(t0.getCapabilities?.() ?? {}) };
  res.devices = (await navigator.mediaDevices.enumerateDevices())
    .filter((d) => d.kind === 'videoinput').map((d) => d.label);
  s0.getTracks().forEach((t) => t.stop());
  for (const [w, h, fps] of [[1920,1080,72],[1920,1080,60],[1920,1080,30],[1280,720,72],[1280,720,60],[640,480,60]]) {
    try {
      const st = await navigator.mediaDevices.getUserMedia({
        video: { width: { ideal: w }, height: { ideal: h }, frameRate: { ideal: fps } } });
      const t = st.getVideoTracks()[0];
      await new Promise((r) => setTimeout(r, 800)); // let the driver settle before reading
      const g = t.getSettings();
      res.ladder.push({ ask: `${w}x${h}@${fps}`, w: g.width, h: g.height, fps: g.frameRate });
      st.getTracks().forEach((x) => x.stop());
      await new Promise((r) => setTimeout(r, 200));
    } catch (e) { res.ladder.push({ ask: `${w}x${h}@${fps}`, err: String(e).slice(0, 60) }); }
  }
  return res;
});
console.log(`\n  video inputs: ${out.devices.join(' | ')}`);
console.log(`  default open: ${out.caps.label}`);
console.log(`  capabilities: width ${JSON.stringify(out.caps.width)}  height ${JSON.stringify(out.caps.height)}  frameRate ${JSON.stringify(out.caps.frameRate)}`);
const even = (hz, f) => f > 0 && Math.abs(hz - Math.round(hz / f) * f) < 0.5;
console.log(`\n  ask              -> delivered            cadence on your 144 Hz display`);
for (const r of out.ladder) {
  if (r.err) { console.log(`  ${r.ask.padEnd(16)} -> FAILED ${r.err}`); continue; }
  const tag = even(144, r.fps) ? `EVEN — ${144 / r.fps} refreshes per frame`
    : `uneven — ratio ${(144 / r.fps).toFixed(2)}`;
  console.log(`  ${r.ask.padEnd(16)} -> ${`${r.w}x${r.h}@${r.fps}`.padEnd(20)} ${tag}`);
}
await ctx.close();
