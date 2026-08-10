import { chromium } from 'playwright-core';
const CHROME = process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const b = await chromium.launch({ executablePath: CHROME, headless: true, args: [
  '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
  '--autoplay-policy=no-user-gesture-required', '--alsa-output-device=null',
  '--unsafely-treat-insecure-origin-as-secure=http://127.0.0.1:8794'] });
const page = await (await b.newContext()).newPage();
const errs = [];
page.on('pageerror', (e) => errs.push(String(e.message).slice(0, 150)));
page.on('console', (m) => { if (m.type() === 'error') errs.push('console: ' + m.text().slice(0, 150)); });
await page.goto('http://127.0.0.1:8794/?xlate=en', { waitUntil: 'domcontentloaded' });
await page.waitForSelector('#join');
await page.click('#more'); await page.fill('#room', 'ds-xl-' + Date.now()); await page.keyboard.press('Escape');
await page.click('#join');
await page.waitForFunction(() => !!document.getElementById('xlateCaps'), null, { timeout: 20000 });
const capsBefore = await page.evaluate(() => document.getElementById('xlateCaps') !== null);
await page.evaluate(async () => {
  const d = (await navigator.mediaDevices.enumerateDevices()).find((x) => x.kind === 'audioinput');
  await window.__tape.switchMic(d.deviceId);
});
await new Promise((r) => setTimeout(r, 3000));
const capsAfter = await page.evaluate(() => document.getElementById('xlateCaps') !== null);
console.log('xlate ui before switch:', capsBefore, ' after restart:', capsAfter);
console.log('errors:', errs.length ? errs.slice(0, 5) : 'none');
await b.close();
process.exit(capsBefore && capsAfter && !errs.length ? 0 : 1);
