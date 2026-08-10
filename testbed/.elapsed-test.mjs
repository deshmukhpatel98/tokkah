// Two peers in one room: the elapsed clock must appear on peer arrival, count
// up, and survive. It must NOT be running while you are alone in the room.
import { chromium } from 'playwright-core';
const CHROME = process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const BASE = 'http://127.0.0.1:8794';
const ROOM = 'elapsed-' + Math.random().toString(36).slice(2, 7);
const browser = await chromium.launch({ executablePath: CHROME, headless: true,
  args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
         '--use-file-for-fake-audio-capture=/Users/deveshpatel/Downloads/video calling/testbed/media/conv-40/A.wav',
         '--autoplay-policy=no-user-gesture-required'] });
const mk = async () => {
  const c = await browser.newContext({ permissions: ['camera', 'microphone'] });
  const p = await c.newPage();
  await p.goto(`${BASE}/?room=${ROOM}`, { waitUntil: 'domcontentloaded' });
  await p.waitForFunction(() => /ready|blocked/.test(document.getElementById('previewBadge')?.textContent ?? ''), { timeout: 20000 });
  await p.click('#join');
  await p.waitForFunction(() => getComputedStyle(document.getElementById('call')).display !== 'none', { timeout: 25000 });
  return p;
};
const read = (p) => p.evaluate(() => ({
  txt: document.getElementById('elapsed').textContent,
  hidden: document.getElementById('elapsed').classList.contains('gone'),
  waiting: !document.getElementById('waiting').classList.contains('gone'),
}));

const A = await mk();
await A.waitForTimeout(3000);
console.log('  A alone      ', JSON.stringify(await read(A)), '<- must be hidden, waiting=true');
const B = await mk();
await B.waitForTimeout(4000);
console.log('  A with peer  ', JSON.stringify(await read(A)));
console.log('  B with peer  ', JSON.stringify(await read(B)));
await A.waitForTimeout(5000);
console.log('  A +5s        ', JSON.stringify(await read(A)), '<- must have advanced');
await B.close();
await B.context().close();
await A.waitForTimeout(4000);
console.log('  A after B left', JSON.stringify(await read(A)), '<- clock must stop/hide');
await browser.close();
