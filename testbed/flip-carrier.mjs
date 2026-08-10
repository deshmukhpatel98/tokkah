// Why did lane 2 come back from a camera flip at 22 fps instead of 30?
//
// Lane 2's video sender does not hold the camera. It holds a 320x180 canvas ticking
// at 60/s: the transform substitutes our own encoded frames for its payload, so the
// carrier is only a clock. One tick carries one frame and parity frames spend ticks
// too, so tick rate is a hard throughput ceiling — tape.js:1156 computes a 30 fps
// carrier as 30 x G/(G+1) = 22.5 fps, and lifts it to 45 by asking the canvas for 60.
//
// adoptVideoTrack() replaced EVERY video sender's track, carrier included, so a flip
// swapped the 60/s canvas for the 30 fps camera and throughput fell to that ceiling.
//
// Two arms, same live build, isolating that single line:
//   control   — replace every video sender (the old body), then lane.adoptTrack()
//   treatment — window.__tape.adopt(), i.e. the shipped adoptVideoTrack, which now
//               skips tapePre.getCarrierSender()
//
// Prediction if the carrier is the cause: control ~22.5, treatment ~30.
import { chromium } from '/Users/deveshpatel/Downloads/video calling/testbed/node_modules/playwright-core/index.mjs';
const CHROME = process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const TB = '/Users/deveshpatel/Downloads/video calling/testbed';
const ARM = process.argv[2] === 'control' ? 'control' : 'treatment';

const mk = async () => {
  const c = await chromium.launchPersistentContext('', {
    executablePath: CHROME, headless: true,
    args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
      `--use-file-for-fake-video-capture=${TB}/media/timecode720.y4m`,
      '--autoplay-policy=no-user-gesture-required'],
    viewport: { width: 1280, height: 800 },
  });
  return { c, p: await c.newPage() };
};

const LIVE = `
window.__rate = async (ms) => {
  const cv = document.getElementById('remoteCanvas');
  const vd = document.getElementById('remote');
  const el = (cv && cv.width > 1) ? cv : ((vd && vd.videoWidth) ? vd : null);
  if (!el) return { ok: false, why: 'no remote surface' };
  const c = document.createElement('canvas'); c.width = 32; c.height = 8;
  const g = c.getContext('2d', { willReadFrequently: true });
  const seen = new Set();
  const t0 = performance.now();
  while (performance.now() - t0 < ms) {
    try { g.drawImage(el, 0, 0, 32, 8); } catch { return { ok: false, why: 'draw failed' }; }
    const d = g.getImageData(0, 0, 32, 8).data;
    let h = 2166136261;
    for (let i = 0; i < d.length; i += 4) { h ^= d[i]; h = Math.imul(h, 16777619); }
    seen.add(h);
    await new Promise(r => requestAnimationFrame(r));
  }
  return { ok: true, fps: +(seen.size / ((performance.now() - t0) / 1000)).toFixed(1),
           size: (el.width || el.videoWidth) + 'x' + (el.height || el.videoHeight) };
};`;

const A = await mk(), B = await mk();
await B.p.addInitScript(LIVE);
const boot = async (e, url) => {
  await e.p.goto(url, { waitUntil: 'domcontentloaded' });
  await e.p.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
  await e.p.click('#join');
};
await boot(A, 'https://room.tokkah.com/?tape=2');
await A.p.waitForFunction(() => /waiting|connected/i.test(document.querySelector('#status')?.textContent ?? ''), null, { timeout: 20000 });
await boot(B, await A.p.evaluate(() => location.href));
await B.p.waitForFunction(() => {
  const c = document.getElementById('remoteCanvas'), v = document.getElementById('remote');
  return (c && c.width > 1) || (v && v.videoWidth > 0);
}, null, { timeout: 45000 });
await B.p.waitForTimeout(8000);

console.log(`\narm         : ${ARM}`);
console.log('lane        :', JSON.stringify(await A.p.evaluate(() => window.__tape?.tapeMode ?? null)));
console.log('before swap :', JSON.stringify(await B.p.evaluate(() => window.__rate(2500))));

const swap = await A.p.evaluate(async (arm) => {
  const cam = (document.querySelector('#preview')?.srcObject?.getVideoTracks?.() ?? [])[0];
  if (!cam) return 'no camera track';
  const nv = (await navigator.mediaDevices.getUserMedia({ video: { width: { ideal: 1280 }, height: { ideal: 720 } } })).getVideoTracks()[0];
  const before = (window.__tape.pc.getSenders() ?? [])
    .filter((s) => s.track?.kind === 'video')
    .map((s) => `${s.track.label.slice(0, 22)}@${s.track.getSettings?.().frameRate ?? '?'}`);
  if (arm === 'control') {
    // The old body: every video sender, carrier included.
    for (const s of window.__tape.pc.getSenders()) {
      if (s.track?.kind === 'video') await s.replaceTrack(nv).catch(() => { });
    }
    window.__tape.lane?.adoptTrack?.(nv);
  } else {
    await window.__tape.adopt(nv); // the shipped path
  }
  cam.stop();
  const after = (window.__tape.pc.getSenders() ?? [])
    .filter((s) => s.track?.kind === 'video')
    .map((s) => `${s.track.label.slice(0, 22)}@${s.track.getSettings?.().frameRate ?? '?'}`);
  return { before, after };
}, ARM);
console.log('video senders before:', JSON.stringify(swap.before));
console.log('video senders after :', JSON.stringify(swap.after));

const rates = [];
for (const s of [5, 12, 20, 28]) {
  await new Promise((r) => setTimeout(r, 3500));
  const r = await B.p.evaluate(() => window.__rate(2500));
  rates.push(r.fps);
  console.log(`  +${String(s).padStart(2)}s far end`, JSON.stringify(r));
}
for (const e of [A, B]) await e.c.close();
const settled = rates.slice(1);
console.log(`=== ${ARM}: settled ${(settled.reduce((a, b) => a + b, 0) / settled.length).toFixed(1)} fps ===`);
