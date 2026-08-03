// Does "1920x1080 delivered" survive contact with a 720p source?
//
// MEASURED.md claims 1920x1080 "decoded off the remote surface". That number
// came from the competitor rig, whose fixture is 1280x720. The app hard-codes
// its encoder to WANT_W/WANT_H (1920x1080) rather than following the camera,
// so the canvas could be 1080p-sized while carrying upscaled 720p. Those are
// very different claims and only one of them is honest.
//
// Read every link in the chain in one call, with the SAME fixture the rig used:
//   camera track settings -> preview element -> encoder config -> remote canvas
// If the camera says 720 and the canvas says 1080, we are upscaling and the
// blog line has to change.
import { chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';
const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const TB = '/Users/earningsgpt/video calling/testbed';

const FIXTURE = process.argv.includes('--1080')
  ? `${TB}/media/cam1080.mjpeg`
  : `${TB}/media/timecode720.y4m`;

const mk = async (vid) => {
  const c = await chromium.launchPersistentContext('', {
    executablePath: CHROME, headless: true,
    args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
      `--use-file-for-fake-video-capture=${vid}`,
      '--autoplay-policy=no-user-gesture-required'],
    viewport: { width: 1280, height: 800 },
  });
  return { c, p: await c.newPage() };
};

// Second browser gets the b-variant so both are the same size but distinct.
const A = await mk(FIXTURE);
const B = await mk(process.argv.includes('--1080') ? FIXTURE : `${TB}/media/timecode720b.y4m`);

await A.p.goto('https://room.tokkah.com/', { waitUntil: 'domcontentloaded' });
await A.p.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
await A.p.click('#join');
await A.p.waitForFunction(() => /waiting|connected/i.test(document.querySelector('#status')?.textContent ?? ''), null, { timeout: 20000 });
const url = await A.p.evaluate(() => location.href);

await B.p.goto(url, { waitUntil: 'domcontentloaded' });
await B.p.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
await B.p.click('#join');

// Let the custom lane come up and the canvas take its real size.
const gotPic = await B.p.waitForFunction(
  () => { const c = document.getElementById('remoteCanvas'); return c && c.width > 1; },
  null, { timeout: 45000 }).then(() => true).catch(() => false);
await B.p.waitForTimeout(6000);

const chain = async (e, side) => e.p.evaluate(async (side) => {
  const t = window.__tape;
  const track = (document.querySelector('#preview')?.srcObject?.getVideoTracks?.() ?? [])[0];
  const s = track?.getSettings?.() ?? {};
  const cap = track?.getCapabilities?.() ?? {};
  const rc = document.getElementById('remoteCanvas');
  const rv = document.getElementById('remote');
  // The authoritative decoded size on the far end, straight from the pipeline
  // rather than from the element we happen to paint into.
  let stats = null;
  try {
    for (const pc of [t?.pc].filter(Boolean)) {
      const r = await pc.getStats();
      r.forEach((v) => {
        if (v.type === 'inbound-rtp' && v.kind === 'video') stats = { w: v.frameWidth, h: v.frameHeight, fps: v.framesPerSecond };
      });
    }
  } catch {}
  return {
    side,
    cameraTrack: `${s.width}x${s.height}@${s.frameRate}`,
    cameraMax: `${cap.width?.max}x${cap.height?.max}`,
    preview: `${document.querySelector('#preview')?.videoWidth}x${document.querySelector('#preview')?.videoHeight}`,
    remoteCanvas: rc ? `${rc.width}x${rc.height}` : null,
    remoteVideo: rv?.videoWidth ? `${rv.videoWidth}x${rv.videoHeight}` : null,
    inboundRtp: stats ? `${stats.w}x${stats.h}@${stats.fps}` : null,
    lane: t?.lane ?? t?.wantTape ?? null,
  };
}, side);

const [a, b] = [await chain(A, 'A'), await chain(B, 'B')];
for (const e of [A, B]) await e.c.close();

console.log(`\nfixture: ${FIXTURE.split('/').pop()}   remote canvas appeared: ${gotPic}`);
for (const r of [a, b]) {
  console.log(`\n--- ${r.side} ---`);
  for (const [k, v] of Object.entries(r)) if (k !== 'side') console.log(`  ${k.padEnd(14)} ${v}`);
}

const px = (s) => (s ? Number(String(s).split('x')[1]?.split('@')[0]) : 0);
const camH = px(a.cameraTrack), outH = px(b.remoteCanvas) || px(b.remoteVideo);
console.log('\n=== verdict ===');
if (!outH) console.log('  no remote surface — inconclusive, do not touch the docs');
else if (outH > camH) console.log(`  UPSCALE: camera ${camH}p -> remote surface ${outH}p. "delivered ${outH}p" is NOT honest with a ${camH}p source.`);
else if (outH === camH) console.log(`  faithful: camera ${camH}p -> remote surface ${outH}p, no resampling.`);
else console.log(`  DOWNSCALE: camera ${camH}p -> remote surface ${outH}p.`);
