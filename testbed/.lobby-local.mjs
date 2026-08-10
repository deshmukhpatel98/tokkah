// §15 lobby on a local Chrome with FAKE devices. Chrome's fake mic emits a
// continuous tone, so a working level meter must move and must not sit at zero.
import { chromium } from 'playwright-core';
const CHROME = process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const BASE = 'http://127.0.0.1:8794';

const browser = await chromium.launch({
  executablePath: CHROME,
  headless: true,
  args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', '--use-file-for-fake-audio-capture=/Users/deveshpatel/Downloads/video calling/testbed/media/conv-40/A.wav',
         '--autoplay-policy=no-user-gesture-required', '--disable-features=MediaFoundationAsyncH264Encoding'],
});
const ctx = await browser.newContext({ permissions: ['camera', 'microphone'] });
const page = await ctx.newPage();
const errs = [];
page.on('pageerror', (e) => errs.push(String(e).slice(0, 200)));
page.on('console', (m) => { if (m.type() === 'error' && !/503|Failed to load resource/.test(m.text())) errs.push(m.text().slice(0, 200)); });

await page.goto(BASE, { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => /ready|blocked/.test(document.getElementById('previewBadge')?.textContent ?? ''), { timeout: 20000 });
await page.waitForTimeout(2500);

const s = await page.evaluate(() => {
  const t = (id) => document.getElementById(id)?.textContent?.trim() ?? null;
  const sel = (id) => { const e = document.getElementById(id); return e ? { n: e.options.length, first: e.options[0]?.textContent, shown: e.style.display !== 'none', disabled: e.disabled } : null; };
  return { badge: t('previewBadge'), cap: t('capBadge'), capLocked: document.getElementById('capBadge')?.classList.contains('locked'),
           cam: sel('camSel'), mic: sel('micSel'), hp: t('hpOut') };
});
console.log('  previewBadge ', s.badge);
console.log('  capBadge     ', JSON.stringify(s.cap), 'locked:', s.capLocked);
console.log('  camSel       ', JSON.stringify(s.cam));
console.log('  micSel       ', JSON.stringify(s.mic));

const vals = [];
for (let i = 0; i < 15; i++) { await page.waitForTimeout(200); vals.push(await page.evaluate(() => document.getElementById('levelBar').style.right)); }
const uniq = [...new Set(vals)];
console.log('  level meter  ', uniq.length > 1 ? `MOVING (${uniq.length}/15 distinct)` : `STUCK at "${vals[0]}"`);
console.log('               ', vals.slice(0, 9).join(' '));

await page.click('#hpCheck');
await page.waitForFunction(() => !/listening|not checked/.test(document.getElementById('hpOut').textContent), { timeout: 25000 }).catch(() => {});
console.log('  headphone    ', await page.evaluate(() => document.getElementById('hpOut').textContent.trim()));

// Now join solo and check the elapsed clock + held treatment hooks exist.
await page.click('#join');
await page.waitForFunction(() => getComputedStyle(document.getElementById('call')).display !== 'none', { timeout: 25000 });
await page.waitForTimeout(1500);
const call = await page.evaluate(() => ({
  elapsedText: document.getElementById('elapsed')?.textContent,
  elapsedHidden: document.getElementById('elapsed')?.classList.contains('gone'),
  holdLineVisible: getComputedStyle(document.getElementById('holdLine')).display,
  callClasses: document.getElementById('call').className,
}));
console.log('  elapsed      ', JSON.stringify(call.elapsedText), 'hidden(no peer yet):', call.elapsedHidden);
console.log('  holdLine     ', call.holdLineVisible, '| call classes:', JSON.stringify(call.callClasses));

// Force the held state and confirm the CSS actually engages.
const held = await page.evaluate(async () => {
  const c = document.getElementById('call');
  c.classList.add('held');
  await new Promise((r) => setTimeout(r, 600));
  const f = getComputedStyle(document.getElementById('remoteWrap')).filter;
  const line = getComputedStyle(document.getElementById('holdLine')).display;
  c.classList.remove('held'); c.classList.add('paused');
  await new Promise((r) => setTimeout(r, 600));
  const f2 = getComputedStyle(document.getElementById('remoteWrap')).filter;
  c.classList.remove('paused');
  await new Promise((r) => setTimeout(r, 600));
  return { heldFilter: f, heldLine: line, pausedFilter: f2, restored: getComputedStyle(document.getElementById('remoteWrap')).filter };
});
console.log('  HELD         filter:', held.heldFilter, '| hairline:', held.heldLine);
console.log('  PAUSED       filter:', held.pausedFilter);
console.log('  restored     filter:', held.restored);
console.log('  page errors  ', errs.length ? errs : 'none');
await browser.close();
