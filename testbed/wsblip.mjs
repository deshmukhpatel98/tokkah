/**
 * Does a signaling blip end the other person's call?
 *
 * Until 2026-08-14 it did. The room announced `peer-left` the instant a socket
 * closed, and the peer's handler puts "they left" on screen, empties back to
 * the lobby and stops the clock — while the media peer connection underneath is
 * still connected and still carrying audio and video. Across the captured Delhi
 * calls `recover {why:"ws-close"}` fired 37 times, so this was not a corner.
 *
 * The room now holds the announcement for LEAVE_GRACE_MS and cancels it if the
 * same tab (sessionStorage `sid`, which survives the recovery reload) comes
 * back. This drives exactly that: two real browsers on prod, kill ONE side's
 * websocket mid-call, and read the OTHER side's status line.
 *
 *   node wsblip.mjs                 against room.tokkah.com
 *   node wsblip.mjs --headed        watch it
 */
import { chromium } from 'playwright-core';

const URL_BASE = process.env.URL ?? 'https://room.tokkah.com';
const HEADED = process.argv.includes('--headed');
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
// Same shape call.mjs uses — the room code is validated server-side.
const room = `bot-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;

const launch = (side) => chromium.launch({
  executablePath: CHROME, headless: !HEADED,
  args: [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    `--use-file-for-fake-video-capture=${media(`real${side}.mjpeg`)}`,
    `--use-file-for-fake-audio-capture=${media(`real${side}.wav`)}`,
    '--autoplay-policy=no-user-gesture-required',
    '--disable-features=WebRtcHideLocalIpsWithMdns',
  ],
});

// The words on the screen, which is what the user actually experiences — not
// pc.connectionState, which stayed 'connected' through every one of the 37.
const status = (p) => p.evaluate(() => {
  const el = document.getElementById('status') || document.querySelector('#waiting, .status');
  return {
    status: (el?.textContent ?? '').trim().slice(0, 60),
    conn: window.__tape?.pc?.connectionState ?? null,
    wsState: window.__tape?.ws?.readyState ?? null,
    lobby: !document.getElementById('waiting')?.classList.contains('gone'),
  };
});

const A = await launch('A'), B = await launch('B');
const a = await A.newPage(), b = await B.newPage();
// The same three moves a person makes, and the same ones call.mjs makes: the
// named-room field lives in the lobby setup sheet, not the URL. Navigating
// straight to /<room> 404s unless the code already matches the generated shape.
for (const [p, who] of [[a, 'A'], [b, 'B']]) {
  await p.goto(URL_BASE, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await p.waitForSelector('#join', { timeout: 20000 });
  await p.click('#more');
  await p.fill('#room', room);
  await p.keyboard.press('Escape');
  await p.click('#join', { timeout: 30000 }).catch(() => {});
  if (who === 'A') await p.waitForTimeout(1200); // A first, so it takes role a
}
await a.waitForTimeout(12000); // let both settle into a real call

const before = { A: await status(a), B: await status(b) };
console.log('BEFORE   A:', JSON.stringify(before.A), '\n         B:', JSON.stringify(before.B));

// The blip: kill A's signaling socket only. The media pc is untouched, exactly
// as in the real failure.
await a.evaluate(() => window.__tape?.ws?.close());
console.log('\n-- killed A signaling socket --\n');

// B is the one under test. Sample across the whole grace window: the old code
// flipped B to "they left" within milliseconds.
for (const t of [500, 1500, 3000, 6000, 9000]) {
  await b.waitForTimeout(t === 500 ? 500 : t - (t === 1500 ? 500 : t === 3000 ? 1500 : t === 6000 ? 3000 : 6000));
  const s = await status(b);
  const verdict = /they left/i.test(s.status) ? 'CALL ENDED ON B' : s.lobby ? 'B back in lobby' : 'B still in call';
  console.log(`  +${t} ms  B: ${JSON.stringify(s)}  -> ${verdict}`);
}

const after = { A: await status(a), B: await status(b) };
console.log('\nAFTER    A:', JSON.stringify(after.A), '\n         B:', JSON.stringify(after.B));
const blipHidden = !/they left/i.test(after.B.status) && after.B.conn === 'connected';

// ── CONTROL ARM ─────────────────────────────────────────────────────────────
// A test that cannot fail proves nothing. Holding the announcement is only
// correct if a REAL departure still arrives — otherwise this "fix" just deleted
// the peer-left message and the arm above would pass for the wrong reason.
// Close A for good and require B to notice, late but reliably.
console.log('\n-- closing A for good (genuine departure) --\n');
await A.close();
let sawLeft = false;
for (let i = 1; i <= 6 && !sawLeft; i++) {
  await b.waitForTimeout(2000);
  const s = await status(b);
  sawLeft = /they left/i.test(s.status) || s.lobby;
  console.log(`  +${i * 2}s  B: ${JSON.stringify(s)}${sawLeft ? '  -> departure reported' : ''}`);
}

console.log(`\nblip hidden from peer:      ${blipHidden ? 'PASS' : 'FAIL'}`);
console.log(`real departure still shown: ${sawLeft ? 'PASS' : 'FAIL'}`);
const pass = blipHidden && sawLeft;
console.log(`\nVERDICT: ${pass ? 'PASS — blips are invisible, real exits still reported' : 'FAIL'}`);

await B.close();
process.exit(pass ? 0 : 1);
