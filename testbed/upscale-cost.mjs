// What did the upscale actually cost? Same camera, same content, same QP,
// one variable: whether the encoder runs at the camera's size or at the ceiling.
// `?upscale=1` restores the old behaviour, so both arms are the same build.
//
// The previous attempt compared a 720p synthetic fixture against a 1080p camera
// fixture and got 14x. That was content, not resolution, and reporting it would
// have been a confident wrong number.
import { chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';
const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const TB = '/Users/earningsgpt/video calling/testbed';
const SETTLE = 12000, WINDOW = 20000;

// Build guard: a stale edge asset already cost one full run on this project.
// Refuse to report rather than measure yesterday's code.
const src = await (await fetch(`https://room.tokkah.com/tape.js?cb=${Math.random()}`)).text();
if (!src.includes('encodeSize') || !src.includes("get('upscale')")) {
  console.log('ABORT: deployed tape.js lacks encodeSize/upscale — stale asset, not measuring.');
  process.exit(1);
}

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

const bytes = (e) => e.p.evaluate(async () => {
  const pc = window.__tape?.pc;
  if (!pc) return null;
  let sent = 0;
  (await pc.getStats()).forEach((v) => { if (v.type === 'transport') sent += v.bytesSent ?? 0; });
  return { sent, t: performance.now() };
});

const run = async (label, qs) => {
  const A = await mk(`${TB}/media/cam720.mjpeg`);
  const B = await mk(`${TB}/media/cam720.mjpeg`);
  await A.p.goto(`https://room.tokkah.com/${qs}`, { waitUntil: 'domcontentloaded' });
  await A.p.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
  await A.p.click('#join');
  await A.p.waitForFunction(() => /waiting|connected/i.test(document.querySelector('#status')?.textContent ?? ''), null, { timeout: 20000 });
  let url = await A.p.evaluate(() => location.href);
  // The joiner must carry the same arm.
  if (qs && !url.includes('upscale=1')) url += '&upscale=1';
  await B.p.goto(url, { waitUntil: 'domcontentloaded' });
  await B.p.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
  await B.p.click('#join');
  await B.p.waitForFunction(() => { const c = document.getElementById('remoteCanvas'); return c && c.width > 1; },
    null, { timeout: 45000 }).catch(() => {});

  await A.p.waitForTimeout(SETTLE);
  const t0 = await bytes(A);
  await A.p.waitForTimeout(WINDOW);
  const t1 = await bytes(A);
  const size = await B.p.evaluate(() => { const c = document.getElementById('remoteCanvas'); return c ? `${c.width}x${c.height}` : '?'; });
  for (const e of [A, B]) await e.c.close();
  if (!t0 || !t1) { console.log(`${label}: no stats`); return null; }
  const dt = (t1.t - t0.t) / 1000;
  const mbps = ((t1.sent - t0.sent) * 8) / dt / 1e6;
  console.log(`  ${label.padEnd(34)} ${mbps.toFixed(2)} Mbps   far end ${size}`);
  return { mbps, size };
};

console.log(`\n720p REAL CAMERA content, identical fixture and QP in both arms:\n`);
const oldArm = await run('encode at ceiling (?upscale=1)', '?upscale=1');
const newArm = await run('encode at camera size (default)', '');

if (oldArm && newArm) {
  const saved = (1 - newArm.mbps / oldArm.mbps) * 100;
  console.log(`\n  the upscale cost ${(oldArm.mbps - newArm.mbps).toFixed(2)} Mbps — ${saved.toFixed(0)}% of the stream,`);
  console.log(`  for zero additional picture (${oldArm.size} envelope around ${newArm.size} of real detail).`);
}
