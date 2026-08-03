// Does swapping the camera kill LANE 1 (the datachannel fallback)?
//
// Lane 2's version of this bug is fixed and documented. Lane 1 had the same shape:
// `pumpCapture()` built one MediaStreamTrackProcessor at start-up and its loop ended
// on `if (done) return;` with no re-acquire, so the flip's final `old.stop()` retired
// the lane for the rest of the call.
//
// This runs BOTH arms against the SAME live build, which is the only honest way to
// show the bug now that the fix is deployed:
//
//   control   — swap the camera WITHOUT calling adoptTrack(). curTrack never moves,
//               so `swapped` is false and the pump returns: exactly the old code path.
//   treatment — swap the way adoptVideoTrack() does, adoptTrack() first.
//
// Same binary, same fixture, same sequence; the single difference is the one call.
import { chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';
const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const TB = '/Users/earningsgpt/video calling/testbed';
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

// Far-end frame RATE, not "did pixels change" — see flip-lane.mjs for why that
// distinction cost two wrong answers. Lane 1 delivers through a
// MediaStreamTrackGenerator into the <video>, so accept either surface.
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
  const secs = (performance.now() - t0) / 1000;
  return { ok: true, surface: el.id, size: (el.width || el.videoWidth) + 'x' + (el.height || el.videoHeight),
           fps: +(seen.size / secs).toFixed(1) };
};`;

const A = await mk(), B = await mk();
await B.p.addInitScript(LIVE);
const ev = [];
A.p.on('request', (r) => {
  if (!/\/log$/.test(r.url())) return;
  try {
    for (const e of JSON.parse(r.postData() ?? '{}').events ?? []) {
      if (/tape-track-swap|tape-resize|tape-fail|tape-start|tape-encoder|fallback/.test(e.kind ?? '')) {
        ev.push(`${e.kind} ${JSON.stringify(e.data ?? {}).slice(0, 110)}`);
      }
    }
  } catch { }
});

const boot = async (e, url) => {
  await e.p.goto(url, { waitUntil: 'domcontentloaded' });
  await e.p.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
  await e.p.click('#join');
};
await boot(A, 'https://room.tokkah.com/?tape=1');
await A.p.waitForFunction(() => /waiting|connected/i.test(document.querySelector('#status')?.textContent ?? ''), null, { timeout: 20000 });
const url = await A.p.evaluate(() => location.href);
await boot(B, url);
// Either remote surface counts as "video is flowing".
await B.p.waitForFunction(() => {
  const c = document.getElementById('remoteCanvas'), v = document.getElementById('remote');
  return (c && c.width > 1) || (v && v.videoWidth > 0);
}, null, { timeout: 45000 });
await B.p.waitForTimeout(8000);

const lane = await A.p.evaluate(() => window.__tape?.tapeMode ?? null);
console.log(`\narm         : ${ARM}`);
console.log('lane        :', JSON.stringify(lane));
if (lane?.wanted !== 1 || !lane?.running) {
  console.log('ABORT: not on lane 1 — this test would measure the wrong thing.');
  for (const e of [A, B]) await e.c.close();
  process.exit(1);
}
console.log('before swap :', JSON.stringify(await B.p.evaluate(() => window.__rate(2000))));

const swap = await A.p.evaluate(async (arm) => {
  const cam = (document.querySelector('#preview')?.srcObject?.getVideoTracks?.() ?? [])[0];
  if (!cam) return 'no camera track';
  const nv = (await navigator.mediaDevices.getUserMedia({ video: { width: { ideal: 1280 }, height: { ideal: 720 } } })).getVideoTracks()[0];
  // The one difference between the arms.
  if (arm === 'treatment') window.__tape.lane?.adoptTrack?.(nv);
  for (const s of (window.__tape?.pc?.getSenders() ?? [])) {
    if (s.track?.kind === 'video') await s.replaceTrack(nv).catch(() => { });
  }
  cam.stop();
  return `${cam.id.slice(0, 8)} (${cam.readyState}) -> ${nv.id.slice(0, 8)} (${nv.readyState})`;
}, ARM);
console.log('swap        :', swap);

for (const s of [3, 10, 20, 30]) {
  await new Promise((r) => setTimeout(r, 3000));
  console.log(`  +${String(s).padStart(2)}s far end`, JSON.stringify(await B.p.evaluate(() => window.__rate(2500))));
}
const final = await B.p.evaluate(() => window.__rate(3000));
const snap = await A.p.evaluate(() => {
  const v = window.__tape?.video ?? {};
  return { framesIn: v.framesIn, framesEncoded: v.framesEncoded, trackSwaps: v.trackSwaps, reconfigs: v.reconfigs };
});
await new Promise((r) => setTimeout(r, 3000)); // let a telemetry flush carry events
for (const e of [A, B]) await e.c.close();

console.log('sender      :', JSON.stringify(snap));
console.log(`events      : ${ev.length ? '\n  ' + ev.join('\n  ') : 'none'}`);
console.log('=== verdict ===');
if (!final.ok) console.log(`DEAD: no remote surface after the swap (${final.why})`);
else if (final.fps >= 15) console.log(`ALIVE: far end at ${final.fps} fps on "${final.surface}" ${final.size}`);
else console.log(`DEAD: far end fell to ${final.fps} fps — the lane did not survive the camera swap.`);
