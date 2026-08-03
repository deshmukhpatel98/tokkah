// HUMAN-VALIDATION.md asks two people for 30 minutes. That is the scarcest
// resource on this project, and a protocol that describes a UI which no longer
// exists wastes all of it. Check its factual claims against the LIVE app before
// anyone runs it.
//
// Uses a 720p camera deliberately: that is what most laptops have, and it is
// what a real tester will see.
import { chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';
const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const TB = '/Users/earningsgpt/video calling/testbed';

const c = await chromium.launchPersistentContext('', {
  executablePath: CHROME, headless: true,
  args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
    `--use-file-for-fake-video-capture=${TB}/media/cam720.mjpeg`,
    `--use-file-for-fake-audio-capture=${TB}/media/conv/A.wav`,
    '--autoplay-policy=no-user-gesture-required'],
  viewport: { width: 1280, height: 860 },
});
const p = await c.newPage();
await p.goto('https://room.tokkah.com/', { waitUntil: 'domcontentloaded' });
await p.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
await p.waitForTimeout(4000);

const found = await p.evaluate(() => {
  const txt = (id) => document.getElementById(id)?.textContent?.trim() ?? null;
  const vis = (id) => { const e = document.getElementById(id); if (!e) return false;
    const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  const room = document.getElementById('room');
  return {
    capBadge: txt('capBadge'),
    roomInputPresent: !!room,
    roomInputVisible: vis('room'),
    roomPlaceholder: room?.placeholder ?? null,
    joinLabel: txt('join'),
    headphoneCheck: !!document.getElementById('hpCheck') || /headphone/i.test(document.body.innerText),
    bodyText: document.body.innerText.replace(/\s+/g, ' ').slice(0, 240),
  };
});
await p.screenshot({ path: '/private/tmp/claude-501/-Users-earningsgpt-video-calling/477cd6ea-c192-43a3-b107-a2011157fa96/scratchpad/lobby.png' });
await c.close();

console.log('\n=== live lobby, 720p camera (what a real tester sees) ===');
for (const [k, v] of Object.entries(found)) console.log(`  ${k.padEnd(20)} ${JSON.stringify(v)}`);

console.log('\n=== HUMAN-VALIDATION.md claims ===');
const check = (claim, ok, note) => console.log(`  ${ok ? 'OK  ' : 'STALE'} ${claim}${note ? '  -> ' + note : ''}`);
check('"type the same room code"', found.roomInputVisible, found.roomInputVisible ? null : 'no visible room input');
check('"badge like `1080p · 30`"',
  found.capBadge === '1080p · 30',
  found.capBadge ? `actual: "${found.capBadge}"` : 'no badge');
