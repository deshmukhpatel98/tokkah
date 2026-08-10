import { chromium } from 'playwright-core';
const CHROME = process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const OUT = '/private/tmp/claude-501/-Users-earningsgpt-video-calling/27a82786-fe89-4200-9d78-e18a228066ca/scratchpad';
const browser = await chromium.launch({ executablePath: CHROME, headless: true,
  args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
         '--use-file-for-fake-audio-capture=/Users/deveshpatel/Downloads/video calling/testbed/media/conv-40/A.wav',
         '--autoplay-policy=no-user-gesture-required'] });
for (const [name, w, h] of [['lobby-desktop', 1280, 800], ['lobby-mobile', 390, 844]]) {
  const c = await browser.newContext({ permissions: ['camera', 'microphone'], viewport: { width: w, height: h } });
  const p = await c.newPage();
  await p.goto('http://127.0.0.1:8794', { waitUntil: 'domcontentloaded' });
  await p.waitForFunction(() => /ready|blocked/.test(document.getElementById('previewBadge')?.textContent ?? ''), { timeout: 20000 });
  await p.waitForTimeout(2500);
  await p.screenshot({ path: `${OUT}/${name}.png` });
  console.log('wrote', name, `${w}x${h}`);
  await c.close();
}
await browser.close();
