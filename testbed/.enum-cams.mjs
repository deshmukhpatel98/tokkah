import { chromium } from 'playwright-core';
const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
// Real devices, auto-granted permission: what Chrome (⇒ Meet, tokkah) actually sees.
const b = await chromium.launch({ executablePath: CHROME, headless: true, args: ['--use-fake-ui-for-media-stream'] });
const page = await (await b.newContext({ permissions: ['camera', 'microphone'] })).newPage();
await page.goto('https://room.tokkah.com', { waitUntil: 'domcontentloaded' });
const devs = await page.evaluate(async () => {
  try { (await navigator.mediaDevices.getUserMedia({ video: true, audio: true })).getTracks().forEach((t) => t.stop()); } catch (e) { /* still enumerate */ }
  return (await navigator.mediaDevices.enumerateDevices()).map((d) => `${d.kind}: ${d.label || '(no label)'}`);
});
console.log(devs.join('\n'));
await b.close();
