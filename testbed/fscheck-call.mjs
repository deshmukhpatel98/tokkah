// Fullscreen-video verification: join a room with two browsers, assert the
// remote video wraps fill the viewport and aspect is cover-preserved.
import { chromium } from 'playwright-core';

const CHROME =
  process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const BASE = process.argv[2] || 'http://127.0.0.1:8794';
const ROOM = 'fs' + Math.random().toString(36).slice(2, 8);
const ARGS = [
  '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
  '--use-file-for-fake-video-capture=/Users/deveshpatel/Downloads/video calling/testbed/media/cam1080.mjpeg',
  '--use-file-for-fake-audio-capture=/Users/deveshpatel/Downloads/video calling/testbed/media/conv/A.wav',
  '--autoplay-policy=no-user-gesture-required',
];

const ctxA = await chromium.launchPersistentContext('', { executablePath: CHROME, headless: true, args: ARGS, viewport: { width: 1512, height: 945 } });
const ctxB = await chromium.launchPersistentContext('', { executablePath: CHROME, headless: true, args: ARGS, viewport: { width: 1512, height: 945 } });
const a = await ctxA.newPage(), b = await ctxB.newPage();

for (const [p, name] of [[a, 'A'], [b, 'B']]) {
  p.on('pageerror', (e) => console.log(`${name} pageerror:`, String(e).slice(0, 120)));
  await p.goto(`${BASE}/?r=${ROOM}`, { waitUntil: 'domcontentloaded' });
}
await a.click('#join'); await b.click('#join');
await a.waitForFunction(() => document.querySelector('#status')?.textContent === 'connected', null, { timeout: 15000 });
await b.waitForFunction(() => document.querySelector('#status')?.textContent === 'connected', null, { timeout: 15000 });
await a.waitForTimeout(3000); // let video metadata + layout settle

for (const [p, name] of [[a, 'A'], [b, 'B']]) {
  const m = await p.evaluate(() => {
    const rw = document.querySelector('#remoteWrap').getBoundingClientRect();
    const v = document.querySelector('#remote');
    const c = document.querySelector('#remoteCanvas');
    const cs = getComputedStyle(c ?? v);
    return {
      wrap: { x: rw.x, y: rw.y, w: rw.width, h: rw.height },
      win: { w: innerWidth, h: innerHeight },
      fillClass: document.querySelector('#call').className,
      objectFit: cs.objectFit,
      videoIntrinsic: v.videoWidth ? `${v.videoWidth}x${v.videoHeight}` : null,
      canvasIntrinsic: c ? `${c.width}x${c.height}` : null,
      showing: c ? 'canvas' : 'video',
      contain: document.querySelector('#call').classList.contains('contain'),
      fillShown: getComputedStyle(document.querySelector('#remoteFill')).display !== 'none',
      flat: document.querySelector('#call').classList.contains('flat'),
    };
  });
  const full = m.wrap.x === 0 && m.wrap.y === 0 && m.wrap.w === m.win.w && m.wrap.h === m.win.h;
  console.log(`${name}: wrap ${m.wrap.w}x${m.wrap.h} @(${m.wrap.x},${m.wrap.y}) vs window ${m.win.w}x${m.win.h} → fullscreen: ${full}`);
  console.log(`   fill-class:"${m.fillClass}" object-fit:${m.objectFit} showing:${m.showing} intrinsic video:${m.videoIntrinsic} canvas:${m.canvasIntrinsic}`);
  // The wrap is always the whole window. The FIT is aspect-dependent since the
  // cross-device policy landed: matched aspect crops nothing and covers;
  // mismatched aspect switches to contain and paints the letterbox with the
  // blurred fill (or a flat wash on a weak device). Asserting "cover" flatly
  // was true only while both ends were assumed to share an aspect ratio.
  const fitOk = m.contain
    ? m.objectFit === 'contain' && (m.fillShown || m.flat)
    : m.objectFit === 'cover';
  console.log(`   contain:${m.contain} fill-painted:${m.fillShown} flat:${m.flat} → fit ok: ${fitOk}`);
  if (!full || !fitOk) { console.log('FAIL'); process.exitCode = 1; }
}

// Toggle round-trip: lifesize on (needs cal+geom; assert no crash and class
// flips back off when geom missing). The toggles live in the more sheet now,
// not the bar, so the sheet has to be open for the row to be hittable.
await a.mouse.move(400, 400); // bar auto-shows on pointer activity, hides after 2.6 s
await a.waitForTimeout(150);
await a.click('#more');
await a.waitForTimeout(300);
await a.click('#c-lifesize');
await a.waitForTimeout(300);
const cls = await a.evaluate(() => document.querySelector('#call').className);
console.log(`lifesize=on without cal/geom → class "${cls}" (expect still fill: no cal/peerGeom)`);
await a.click('#c-lifesize');
await a.waitForTimeout(300);
console.log(`lifesize back off → class "${await a.evaluate(() => document.querySelector('#call').className)}"`);
await a.keyboard.press('Escape');

await ctxA.close(); await ctxB.close();
console.log(process.exitCode ? 'FAILED' : 'PASS');
