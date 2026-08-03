// Force a camera resize mid-call and prove the far end follows it without
// breaking. A reconfigure resets the encoder's reference chain, so the failure
// mode to hunt is not "wrong size" — it is a frozen or black remote picture
// while every counter still looks healthy. Check the PIXELS, not the state.
import { chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';
const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const TB = '/Users/earningsgpt/video calling/testbed';

const src = await (await fetch(`https://room.tokkah.com/tape.js?cb=${Math.random()}`)).text();
if (!src.includes('tape-resize') || !src.includes('RESIZE_HOLD')) {
  console.log('ABORT: deployed tape.js lacks the resize path — stale asset.');
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

// Is the remote surface showing a live, changing picture? Two samples of a
// downscaled luma strip; identical bytes twice running means frozen.
const LIVE = `
window.__live = async () => {
  const el = document.getElementById('remoteCanvas');
  if (!el || el.width < 2) return { ok: false, why: 'no surface' };
  const grab = () => {
    const c = document.createElement('canvas'); c.width = 24; c.height = 14;
    const g = c.getContext('2d', { willReadFrequently: true });
    g.drawImage(el, 0, 0, 24, 14);
    return Array.from(g.getImageData(0, 0, 24, 14).data);
  };
  const a = grab();
  await new Promise((r) => setTimeout(r, 400));
  const b = grab();
  let diff = 0, sum = 0, sum2 = 0;
  for (let i = 0; i < a.length; i += 4) {
    if (a[i] !== b[i]) diff++;
    const y = b[i]; sum += y; sum2 += y * y;
  }
  const n = a.length / 4, m = sum / n;
  return { ok: true, size: el.width + 'x' + el.height,
           moving: diff > n * 0.05, variance: +Math.sqrt(Math.max(0, sum2 / n - m * m)).toFixed(1) };
};`;

const A = await mk(`${TB}/media/cam1080.mjpeg`);
const B = await mk(`${TB}/media/cam1080.mjpeg`);
await B.p.addInitScript(LIVE);

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

// The app logs `tape-resize` through telemetry, which POSTs it. That is the
// authoritative record that the reconfigure path actually ran — an in-page
// stats snapshot may simply not have refreshed yet, which is what made the
// first version of this probe report a null and cry failure.
const resizeEvents = [];
A.p.on('request', (r) => {
  if (!/\/log$/.test(r.url())) return;
  try {
    for (const e of JSON.parse(r.postData() ?? '{}').events ?? []) {
      if ((e.kind ?? '') === 'tape-resize') resizeEvents.push(e.data ?? e);
    }
  } catch {}
});

const lost = () => A.p.evaluate(() => {
  const s = window.__tape?.stats ?? {};
  return { reconfigs: s.reconfigs ?? null, fails: s.reconfigFails ?? null, framesLost: s.framesLost ?? null };
});

console.log('\nbefore resize :', JSON.stringify(await B.p.evaluate(() => window.__live())), JSON.stringify(await lost()));

// The ladder's step-down, reproduced exactly: re-apply capture constraints at a
// lower tier on the live track.
for (const [w, h] of [[1280, 720], [640, 360]]) {
  const applied = await A.p.evaluate(async ([w, h]) => {
    const t = (document.querySelector('#preview')?.srcObject?.getVideoTracks?.() ?? [])[0];
    if (!t) return 'no track';
    await t.applyConstraints({ width: { ideal: w }, height: { ideal: h }, resizeMode: 'none' });
    const s = t.getSettings();
    return `${s.width}x${s.height}`;
  }, [w, h]);
  await new Promise((r) => setTimeout(r, 5000));
  const far = await B.p.evaluate(() => window.__live());
  console.log(`asked ${String(w + 'x' + h).padEnd(9)} camera now ${String(applied).padEnd(9)} far end ${JSON.stringify(far)}  ${JSON.stringify(await lost())}`);
}

await B.p.screenshot({ path: '/private/tmp/claude-501/-Users-earningsgpt-video-calling/477cd6ea-c192-43a3-b107-a2011157fa96/scratchpad/after-resize.png' });
const final = await B.p.evaluate(() => window.__live());
const st = await lost();
for (const e of [A, B]) await e.c.close();

console.log(`\nlogged tape-resize events: ${JSON.stringify(resizeEvents)}`);
console.log(`in-page counters (may lag a flush): ${JSON.stringify(st)}`);

console.log('\n=== verdict ===');
const fails = resizeEvents.filter((e) => e.err);
const good = final.ok && final.moving && resizeEvents.length > 0 && !fails.length
  && final.size === '640x360';
console.log(good
  ? `PASS: encoder followed the camera ${resizeEvents.length}x (${resizeEvents.map((e) => e.from + '->' + e.to).join(', ')}), far end ${final.size} and still moving, 0 failed reconfigures.`
  : `FAIL / inconclusive: ${JSON.stringify({ final, resizeEvents, fails })}`);
