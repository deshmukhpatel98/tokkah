import { chromium } from 'playwright-core';
const CHROME = process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const OUT = process.env.OUT ?? '/tmp';
const b = await chromium.launch({ executablePath: CHROME, headless: true, args: [
  '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
  '--autoplay-policy=no-user-gesture-required', '--alsa-output-device=null',
  '--unsafely-treat-insecure-origin-as-secure=http://127.0.0.1:8794'] });
const page = await (await b.newContext({ viewport: { width: 420, height: 780 } })).newPage();
await page.goto('http://127.0.0.1:8794/', { waitUntil: 'domcontentloaded' });
await page.waitForSelector('#join');
await page.waitForTimeout(1500);
await page.click('#more');
await page.waitForTimeout(600);
await page.screenshot({ path: `${OUT}/picker-lobby.png` });
await page.fill('#room', 'shot-' + Date.now());
await page.keyboard.press('Escape');
await page.click('#join');
await page.waitForTimeout(3500);
await page.click('#more');
await page.waitForTimeout(600);
await page.screenshot({ path: `${OUT}/picker-call.png` });
await b.close();
console.log('shots written');
