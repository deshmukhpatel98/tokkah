// "Least clicks to start or join a call" is a goal clause that has never been
// measured. So count them — not from reading the code, but from a real cold load
// with every user gesture logged by the page itself, and with the clock running
// until a real picture is on screen.
//
// Two paths, because they are different products in practice:
//   HOST  — arrives at the bare domain with no link, needs a room to share.
//   GUEST — arrives on someone's link, needs to be in the call.
import { chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';
const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const TB = '/Users/earningsgpt/video calling/testbed';

// Count every real user gesture the page receives, in the page, so nothing the
// driver does can be missed or double-counted.
const COUNTER = `
window.__gestures = [];
for (const t of ['pointerdown', 'click', 'keydown']) {
  addEventListener(t, (e) => {
    if (!e.isTrusted) return;               // synthetic events do not count
    const el = e.target.closest?.('button, [role="button"], a, input') ?? e.target;
    window.__gestures.push({ type: t, id: el?.id || null,
      label: (el?.textContent || el?.ariaLabel || '').trim().slice(0, 28),
      t: Math.round(performance.now()) });
  }, true);
}`;

const mk = async (side) => {
  const c = await chromium.launchPersistentContext('', {
    executablePath: CHROME, headless: true,
    args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
      `--use-file-for-fake-video-capture=${TB}/media/cam1080.mjpeg`,
      `--use-file-for-fake-audio-capture=${TB}/media/conv/${side}.wav`,
      '--autoplay-policy=no-user-gesture-required'],
    viewport: { width: 390, height: 844 },   // phone: the harder, more common case
  });
  const p = await c.newPage();
  await p.addInitScript(COUNTER);
  return { c, p };
};

// A real picture, not a state string. "connected" has lied on this project before.
const hasPicture = () => {
  const rc = document.getElementById('remoteCanvas');
  const el = rc && rc.width > 1 ? rc : document.getElementById('remote');
  if (!el || !(el.videoWidth || el.width)) return false;
  const c = document.createElement('canvas'); c.width = 32; c.height = 18;
  const g = c.getContext('2d', { willReadFrequently: true });
  try { g.drawImage(el, 0, 0, 32, 18); } catch { return false; }
  const d = g.getImageData(0, 0, 32, 18).data;
  let s = 0, s2 = 0, n = 0;
  for (let i = 0; i < d.length; i += 4) { const y = 0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2]; s += y; s2 += y * y; n++; }
  const m = s / n;
  return Math.sqrt(Math.max(0, s2 / n - m * m)) > 8;
};

const H = await mk('A'), G = await mk('B');

// ── HOST: bare domain, no link ───────────────────────────────────────────────
const tHost0 = Date.now();
await H.p.goto('https://room.tokkah.com/', { waitUntil: 'domcontentloaded' });
await H.p.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
const tPreview = Date.now() - tHost0;
// The minimal host path: press join. Anything else the UI demands will show up
// in the gesture log, because the log records what actually happened.
await H.p.click('#join');
await H.p.waitForFunction(() => /waiting|connected/i.test(document.querySelector('#status')?.textContent ?? ''), null, { timeout: 20000 });
const tHostInRoom = Date.now() - tHost0;
const roomUrl = await H.p.evaluate(() => location.href);

// ── GUEST: arrives on the host's link ────────────────────────────────────────
const tG0 = Date.now();
await G.p.goto(roomUrl, { waitUntil: 'domcontentloaded' });
await G.p.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
const tGPreview = Date.now() - tG0;
await G.p.click('#join');
await G.p.waitForFunction(hasPicture, null, { timeout: 40000 });
const tGuestPicture = Date.now() - tG0;
await H.p.waitForFunction(hasPicture, null, { timeout: 20000 }).catch(() => {});
const tHostPicture = Date.now() - tHost0;

const [gh, gg] = await Promise.all([H.p.evaluate(() => window.__gestures), G.p.evaluate(() => window.__gestures)]);
await G.p.screenshot({ path: 'clicks-guest.png' });
for (const e of [H, G]) await e.c.close();

const clicks = (g) => g.filter((x) => x.type === 'click').length;
const line = (k, v) => console.log(k.padEnd(38), v);
console.log('\n=== clicks to be in a call (phone viewport, cold load) ===');
line('HOST  gestures', JSON.stringify(gh.filter((x) => x.type === 'click').map((x) => x.id || x.label)));
line('GUEST gestures', JSON.stringify(gg.filter((x) => x.type === 'click').map((x) => x.id || x.label)));
line('HOST  clicks from bare domain', clicks(gh));
line('GUEST clicks from a shared link', clicks(gg));
console.log('\n=== time (ms, from navigation start) ===');
line('host: self-preview live', tPreview);
line('host: in room, link shareable', tHostInRoom);
line('guest: self-preview live', tGPreview);
line('guest: REAL PICTURE of the other person', tGuestPicture);
line('host: real picture of the guest', tHostPicture);
console.log('\n=== floor ===');
console.log('One click each is the minimum any browser call can do: getUserMedia needs a');
console.log('user gesture, and joining unheard would be the wrong default. 0 clicks is not');
console.log('reachable for the guest; it IS reachable for the host if the bare domain minted');
console.log('a room on load — at the cost of a camera running before anyone asked.');
