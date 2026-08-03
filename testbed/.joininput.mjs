// The two ways a person types their way out of a call: pasting the whole
// invite link into the room box, and a name with a space in it. Both used to
// come back as "this call may already have two people in it".
import { chromium } from 'playwright-core';

const CHROME =
  '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const BASE = process.argv[2] ?? 'http://127.0.0.1:8795';

const browser = await chromium.launch({
  executablePath: CHROME,
  headless: true,
  args: [
    '--use-fake-ui-for-media-stream',
    '--use-fake-device-for-media-stream',
    '--autoplay-policy=no-user-gesture-required',
    '--alsa-output-device=null',
    '--disable-features=WebRtcHideLocalIpsWithMdns',
  ],
});
const results = [];
async function ready(page, url) {
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page
    .waitForFunction(() => /ready|blocked|no camera/.test(document.getElementById('previewBadge')?.textContent ?? ''), { timeout: 25000 })
    .catch(() => {});
}
const state = (p) =>
  p.evaluate(() => ({
    lobby: getComputedStyle(document.getElementById('lobby')).display !== 'none',
    joinStatus: document.getElementById('joinStatus')?.textContent?.trim() ?? '',
    status: document.getElementById('status')?.textContent?.trim() ?? '',
    room: new URLSearchParams(location.search).get('r'),
    namedRowShown: getComputedStyle(document.getElementById('namedRow')).display !== 'none',
    joinLabel: document.getElementById('join')?.textContent?.trim() ?? '',
  }));
function rec(name, pass, detail) { results.push(pass); console.log(`  ${pass ? 'PASS' : 'FAIL'}  ${name}\n        ${detail}`); }

try {
  // 1. Paste the whole invite link into the "named room" box.
  let p = await browser.newPage();
  await ready(p, BASE);
  await p.fill('#room', `${BASE}/?r=paste-target-xyz`);
  await p.click('#join');
  await p.waitForTimeout(6000);
  let s = await state(p);
  rec('pasted invite link resolves to the room, not an error',
    !s.lobby && s.room === 'paste-target-xyz',
    `inCall:${!s.lobby} room:${s.room} status:"${s.status}" joinStatus:"${s.joinStatus}"`);
  await p.close();

  // 2. A room name with a space.
  p = await browser.newPage();
  await ready(p, BASE);
  await p.fill('#room', 'morning call');
  await p.click('#join');
  await p.waitForTimeout(6000);
  s = await state(p);
  rec('a name with a space still joins', !s.lobby && s.room === 'morning-call',
    `inCall:${!s.lobby} room:${s.room} joinStatus:"${s.joinStatus}"`);
  await p.close();

  // 3. Something genuinely unusable is refused in words, in the lobby.
  p = await browser.newPage();
  await ready(p, BASE);
  await p.fill('#room', 'room!!😀<script>');
  await p.click('#join');
  await p.waitForTimeout(3000);
  s = await state(p);
  rec('an impossible name is refused in words, not as "room is full"',
    s.lobby && /characters we can/.test(s.joinStatus),
    `lobby:${s.lobby} joinStatus:"${s.joinStatus}"`);
  await p.close();

  // 4. Arriving by link: no editable key on screen, button says Join.
  p = await browser.newPage();
  await ready(p, `${BASE}/?r=abcDEF123_-x`);
  s = await state(p);
  rec('invite link hides the raw room key and says "Join call"',
    !s.namedRowShown && /join call/i.test(s.joinLabel),
    `namedRowShown:${s.namedRowShown} button:"${s.joinLabel}"`);
  await p.close();

  // 5. The plain path is untouched: no link, mint a fresh room.
  p = await browser.newPage();
  await ready(p, BASE);
  s = await state(p);
  const label = s.joinLabel;
  await p.click('#join');
  await p.waitForTimeout(6000);
  s = await state(p);
  rec('cold lobby still mints a new room', !s.lobby && !!s.room && s.room.length > 10,
    `button was "${label}" | inCall:${!s.lobby} room:${s.room}`);
  await p.close();
} catch (e) {
  rec('harness', false, e.message);
} finally {
  const pass = results.filter(Boolean).length;
  console.log(`\n=== ${pass}/${results.length} pass ===`);
  await browser.close();
  process.exit(pass === results.length ? 0 : 1);
}
