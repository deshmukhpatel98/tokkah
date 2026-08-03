/**
 * Dry-run 2: processed arm (raw audio UNTICKED) + CSV export check.
 *
 * Expectation: with noiseSuppression/AGC/AEC on at capture, B's inhales are
 * gated before they cross the network, so replies that were breath-opened in
 * the raw run arrive as plain voice onsets — kind 'voice', no head start.
 * That is the whole A/B the experiment exists to show.
 */
import { createRequire } from 'node:module';
const require = createRequire('/Users/earningsgpt/video calling/testbed/package.json');
const { chromium } = require('playwright-core');

const CHROME =
  '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1228/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const BASE = 'http://127.0.0.1:8793';
const ROOM = `dryp-${Date.now().toString(36)}`;
const MEDIA = '/Users/earningsgpt/video calling/testbed/media/conv';

async function launch(side, wav) {
  const browser = await chromium.launch({
    executablePath: CHROME,
    headless: true,
    args: [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      `--use-file-for-fake-audio-capture=${wav}`,
      '--autoplay-policy=no-user-gesture-required',
      '--alsa-output-device=null',
      '--disable-features=WebRtcHideLocalIpsWithMdns',
      `--unsafely-treat-insecure-origin-as-secure=${BASE}`,
      '--allow-running-insecure-content',
    ],
  });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + String(e.message).slice(0, 200)));
  await page.goto(`${BASE}/turns`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#join', { timeout: 20000 });
  await page.fill('#room', ROOM);
  await page.fill('#runlabel', 'proc');
  await page.uncheck('#raw');
  return { side, browser, page, errors };
}

// Launch BOTH browsers first, then join A then B a beat apart — keeps the two
// capture clocks close (A must still join first to get role 'a').
const A = await launch('A', `${MEDIA}/A.wav`);
const B = await launch('B', `${MEDIA}/B.wav`);
await A.page.click('#join');
await new Promise((r) => setTimeout(r, 400));
await B.page.click('#join');

let rows = [];
const deadline = Date.now() + 95000;
while (Date.now() < deadline) {
  rows = await A.page.evaluate(() => window.__turns?.state.rows ?? []);
  if (rows.length >= 4) break;
  await new Promise((r) => setTimeout(r, 2000));
}
await new Promise((r) => setTimeout(r, 3000));
rows = await A.page.evaluate(() => window.__turns.state.rows);
const meta = await A.page.evaluate(() => ({
  raw: window.__turns.state.raw,
  peerRaw: window.__turns.state.peerRaw,
  peermodeText: document.getElementById('peermode').textContent,
}));

console.log('=== processed-arm run ===');
console.log('A raw:', meta.raw, ' peerRaw:', meta.peerRaw, ' |', meta.peermodeText);
for (const r of rows) {
  console.log(
    `row ${r.n}: ttfe=${r.ttfe.toFixed(0)} voice=${r.voice.toFixed(0)} credit=${r.credit.toFixed(0)} kind=${r.kind} human=${r.human?.toFixed(0)}`,
  );
}
const breaths = rows.filter((r) => r.kind === 'breath').length;
console.log(`breath-opened: ${breaths}/${rows.length}  (raw run was 3/5)`);

// CSV export check
const dl = A.page.waitForEvent('download', { timeout: 10000 });
await A.page.click('#csv');
const download = await dl;
console.log('CSV download:', download.suggestedFilename());
const path = await download.path();
const { readFileSync } = await import('node:fs');
const csv = readFileSync(path, 'utf8');
console.log('CSV head + first row:\n' + csv.split('\n').slice(0, 2).join('\n'));

console.log('page errors A:', A.errors.length ? A.errors : 'none');
await A.browser.close();
await B.browser.close();
