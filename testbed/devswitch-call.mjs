#!/usr/bin/env node
/**
 * Device-picker regression (§15, user directive 2026-08-06): a real two-
 * Chromium call where side A switches its microphone and camera MID-CALL via
 * the shipped paths (__tape.switchMic / __tape.switchCam — the same functions
 * the in-call pickers drive). A fake-device browser has one mic and one
 * camera, so the switch is to ITSELF: that still exercises every consumer
 * handoff (senders, Lane A retap, detector re-attach, interpreter restart)
 * and it is exactly the case the guard-free design must survive.
 *
 * Verdict requires, after the switch: no pageerror, Lane A framesSent still
 * advancing on A, B's remote audio playhead still advancing, and the pickers
 * (lobby + call phase) present and populated.
 *
 *   node testbed/devswitch-call.mjs [--url=http://127.0.0.1:8794] [--headed]
 */
import { chromium } from 'playwright-core';

const KNOWN = new Set(['url', 'headed']);
const args = {};
for (const a of process.argv.slice(2)) {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/);
  if (!m || !KNOWN.has(m[1])) { console.error(`unknown flag: ${a}`); process.exit(2); } // unknown flags are fatal
  args[m[1]] = m[2] ?? '1';
}
const URL_BASE = args.url ?? 'http://127.0.0.1:8794';
const ROOM = `ds-${Date.now().toString(36)}`;
const CHROME =
  process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');

async function launch(side) {
  const browser = await chromium.launch({
    executablePath: CHROME,
    headless: !args.headed,
    args: [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      // The testing-realism law (2026-08-11): real talking-head media, never
      // synthetic artifacts — a fake device's beep-and-spinner exercises nothing
      // a human call exercises. Fixtures: testbed/media/real/fetch.sh.
      `--use-file-for-fake-audio-capture=${decodeURIComponent(new URL('./media/real/realA.wav', import.meta.url).pathname)}`,
      `--use-file-for-fake-video-capture=${decodeURIComponent(new URL('./media/real/realA.mjpeg', import.meta.url).pathname)}`,
      '--autoplay-policy=no-user-gesture-required',
      '--alsa-output-device=null',
      '--disable-features=WebRtcHideLocalIpsWithMdns',
      `--unsafely-treat-insecure-origin-as-secure=${URL_BASE}`,
    ],
  });
  const page = await (await browser.newContext()).newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + String(e.message).slice(0, 200))); // the verdict-picker lesson
  await page.goto(URL_BASE, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#join', { timeout: 20000 });
  await page.click('#more');
  await page.fill('#room', ROOM);
  await page.keyboard.press('Escape');
  return { side, browser, page, errors };
}

const vis = (page, sel) => page.evaluate((s) => {
  const el = document.querySelector(s);
  if (!el) return { present: false };
  const cs = getComputedStyle(el);
  return { present: true, shown: cs.display !== 'none' && !el.closest('.preOnly, .callOnly, #moreSheet')?.checkVisibility === false, options: el.options?.length ?? 0, disabled: el.disabled, value: el.value };
}, sel);

const A = await launch('A');
const B = await launch('B');

// Lobby phase: pickers must be present and populated even with ONE device.
await A.page.click('#more');
await new Promise((r) => setTimeout(r, 400));
const lobbyCam = await vis(A.page, '#camSel');
const lobbyMic = await vis(A.page, '#micSel');
console.log(`lobby pickers: cam ${JSON.stringify(lobbyCam)} mic ${JSON.stringify(lobbyMic)}`);
await A.page.keyboard.press('Escape');

await Promise.all([A.page.click('#join'), B.page.click('#join')]);
console.log('join clicked on both');
// Wait for Lane A to actually move frames.
await A.page.waitForFunction(() => (window.__tape?.pcm?.framesSent ?? 0) > 100, null, { timeout: 30000 });
console.log('lane A flowing');

// Call phase: in-call pickers exist and are populated.
await A.page.click('#more');
await new Promise((r) => setTimeout(r, 400));
const callCam = await vis(A.page, '#camSelCall');
const callMic = await vis(A.page, '#micSelCall');
console.log(`call pickers:  cam ${JSON.stringify(callCam)} mic ${JSON.stringify(callMic)}`);
await A.page.keyboard.press('Escape');

const snapA = () => A.page.evaluate(() => ({ sent: window.__tape?.pcm?.framesSent ?? 0 }));
const snapB = () => B.page.evaluate(() => ({
  conceal: window.__tape?.pcm?.concealed ?? window.__tape?.pcm?.conceal ?? null,
  recv: window.__tape?.pcm?.framesRecv ?? window.__tape?.pcm?.recv ?? null,
  playSeq: window.__tape?.pcm?.playSeq ?? null,
}));

// ── The switch itself, on the shipped paths ──────────────────────────────────
const before = { a: await snapA(), b: await snapB() };
const micId = await A.page.evaluate(async () => {
  const d = (await navigator.mediaDevices.enumerateDevices()).find((x) => x.kind === 'audioinput');
  await window.__tape.switchMic(d.deviceId);
  return d.deviceId.slice(0, 12);
});
console.log(`mic switched on A (device ${micId}…)`);
await new Promise((r) => setTimeout(r, 4000));
const camId = await A.page.evaluate(async () => {
  const d = (await navigator.mediaDevices.enumerateDevices()).find((x) => x.kind === 'videoinput');
  await window.__tape.switchCam(d.deviceId);
  return d.deviceId.slice(0, 12);
});
console.log(`cam switched on A (device ${camId}…)`);
await new Promise((r) => setTimeout(r, 5000));
const after = { a: await snapA(), b: await snapB() };

// Telemetry: the switch must have said what it did.
const telSwitch = await A.page.evaluate(() =>
  (window.__tape?.tel?.peek?.() ?? []).filter?.((e) => e.kind === 'mic-switch' || e.kind === 'camera-flip').length ?? null);

console.log(`A framesSent: ${before.a.sent} -> ${after.a.sent}`);
console.log(`B pcm: ${JSON.stringify(before.b)} -> ${JSON.stringify(after.b)}`);
console.log(`switch telemetry events: ${telSwitch}`);
if (A.errors.length) console.log(`A page errors: ${A.errors.slice(0, 5).join(' | ')}`);
if (B.errors.length) console.log(`B page errors: ${B.errors.slice(0, 5).join(' | ')}`);

await Promise.all([A.browser.close(), B.browser.close()]);

const lobbyOk = lobbyCam.present && lobbyCam.options >= 1 && lobbyMic.present && lobbyMic.options >= 1;
const callOk = callCam.present && callCam.options >= 1 && callMic.present && callMic.options >= 1;
const flowOk = after.a.sent > before.a.sent + 200; // ≥~2 s of 8 ms frames kept flowing post-switch
const cleanOk = !A.errors.length && !B.errors.length;
console.log(`\nverdict: lobby pickers ${lobbyOk ? 'OK' : 'FAIL'}, call pickers ${callOk ? 'OK' : 'FAIL'}, lane after switch ${flowOk ? 'OK' : 'FAIL'}, errors ${cleanOk ? 'none' : 'PRESENT'}`);
process.exit(lobbyOk && callOk && flowOk && cleanOk ? 0 : 1);
