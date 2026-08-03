// Does swapping the camera kill the custom video lane?
//
// The flip handler (app.js) does: open new track -> adoptVideoTrack(nv), which
// replaceTrack()s it onto the pc senders -> old.stop(). The lane's capture pump
// reads the OLD track through a MediaStreamTrackProcessor created once at lane
// start-up, and its loop ends on `if (done) return;` with no re-acquire. So the
// lane should stop producing frames the moment old.stop() lands.
//
// Chrome's fake device exposes one camera, so the flip BUTTON early-returns
// (`cams.length < 2`). This reproduces the sequence that actually matters —
// replaceTrack onto a fresh track, then stop the old one — against the live pc.
//
// What this proves: whether the far end survives a camera swap.
// What it does not prove: the button's own enumerateDevices/deviceId logic.
import { chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';
const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const TB = '/Users/earningsgpt/video calling/testbed';

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

// Far-end frame RATE, not "did pixels change".
//
// The first version asked whether a 24x14 strip differed over 500 ms and got a
// flickering answer, because two things can make a live lane look frozen: a
// fixture with a near-static passage, and the stall machine's VIDEO HELD mode,
// which paints ~1 fps stills over lane P. Both sample as "sometimes moving".
// Counting DISTINCT frames per second separates them cleanly:
//   ~30/s  healthy lane      ~1/s  lane P stills (lane dead, degraded)   0  frozen
// Paired with the timecode fixture, whose every frame differs by construction,
// so content can never be the reason two samples match.
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
  let samples = 0;
  while (performance.now() - t0 < ms) {
    try { g.drawImage(el, 0, 0, 32, 8); } catch { return { ok: false, why: 'draw failed' }; }
    const d = g.getImageData(0, 0, 32, 8).data;
    let h = 2166136261;
    for (let i = 0; i < d.length; i += 4) { h ^= d[i]; h = Math.imul(h, 16777619); }
    seen.add(h); samples++;
    await new Promise(r => requestAnimationFrame(r));
  }
  const secs = (performance.now() - t0) / 1000;
  return { ok: true, surface: el.id, size: (el.width || el.videoWidth) + 'x' + (el.height || el.videoHeight),
           fps: +(seen.size / secs).toFixed(1), samples };
};`;

const A = await mk(), B = await mk();
await B.p.addInitScript(LIVE);
const laneEvents = [];
for (const [side, e] of [['A', A]]) {
  e.p.on('request', (r) => {
    if (!/\/log$/.test(r.url())) return;
    try {
      for (const ev of JSON.parse(r.postData() ?? '{}').events ?? []) {
        if (/tape-fallback|fallback|tape-fail|stall|camera-flip|tape-render/.test(ev.kind ?? '')) {
          laneEvents.push(`${side}:${ev.kind} ${JSON.stringify(ev.data ?? {}).slice(0, 90)}`);
        }
      }
    } catch {}
  });
}

await A.p.goto('https://room.tokkah.com/', { waitUntil: 'domcontentloaded' });
await A.p.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
await A.p.click('#join');
await A.p.waitForFunction(() => /waiting|connected/i.test(document.querySelector('#status')?.textContent ?? ''), null, { timeout: 20000 });
const url = await A.p.evaluate(() => location.href);
await B.p.goto(url, { waitUntil: 'domcontentloaded' });
await B.p.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
await B.p.click('#join');
await B.p.waitForFunction(() => { const c = document.getElementById('remoteCanvas'); return c && c.width > 1; },
  null, { timeout: 45000 });
await B.p.waitForTimeout(8000);

console.log('\nbefore swap :', JSON.stringify(await B.p.evaluate(() => window.__rate(2000))));

// The swap, as the flip handler performs it.
const swap = await A.p.evaluate(async () => {
  const pc = window.__tape?.pc;
  if (!pc) return 'no pc';
  // The CAMERA track, not the pc sender's track. Lane 2 sends through an RTP
  // transform on a carrier canvas, so sender.track is the carrier — stopping
  // that tests nothing. The lane's MediaStreamTrackProcessor reads the camera,
  // and the camera is what the flip's `old.stop()` retires.
  const cam = (document.querySelector('#preview')?.srcObject?.getVideoTracks?.() ?? [])[0];
  if (!cam) return 'no camera track';
  const nv = (await navigator.mediaDevices.getUserMedia({ video: { width: { ideal: 1280 }, height: { ideal: 720 } } })).getVideoTracks()[0];
  // adoptVideoTrack's core, then the flip's final step.
  // adoptVideoTrack's sequence, in its order: tell the lane first, then the
  // senders, and only then retire the old sensor.
  window.__tape.lane?.adoptTrack?.(nv);
  for (const s of pc.getSenders()) if (s.track?.kind === 'video') await s.replaceTrack(nv).catch(() => {});
  cam.stop();
  return `camera ${cam.id.slice(0, 8)} (${cam.readyState}) -> ${nv.id.slice(0, 8)} (${nv.readyState})`;
});
console.log('swap        :', swap);

for (const s of [3, 10, 20, 35]) {
  await new Promise((r) => setTimeout(r, 3000));
  console.log(`  +${String(s).padStart(2)}s far end`, JSON.stringify(await B.p.evaluate(() => window.__rate(2500))));
}

await B.p.screenshot({ path: '/private/tmp/claude-501/-Users-earningsgpt-video-calling/477cd6ea-c192-43a3-b107-a2011157fa96/scratchpad/after-flip.png' });
const final = await B.p.evaluate(() => window.__rate(3000));
await new Promise((r) => setTimeout(r, 3000)); // let a telemetry flush carry events
for (const e of [A, B]) await e.c.close();

console.log(`\nlane/stall events on the sender: ${laneEvents.length ? '\n  ' + laneEvents.join('\n  ') : 'none'}`);
console.log('\n=== verdict ===');
if (!final.ok) console.log(`BROKEN: no remote surface after the swap (${final.why})`);
else if (final.fps >= 15) console.log(`SURVIVES: far end still at ${final.fps} fps on "${final.surface}" ${final.size} — the lane re-acquired the new camera.`);
else if (final.fps >= 0.3) console.log(`CONFIRMED BUG (degraded): far end fell to ${final.fps} fps — that is lane P stills, not video. The custom lane died with the old track.`);
else console.log(`CONFIRMED BUG (frozen): far end at ${final.fps} fps — no new frames at all after the camera swap.`);
