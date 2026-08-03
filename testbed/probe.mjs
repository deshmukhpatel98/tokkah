/**
 * Does `--use-file-for-fake-audio-capture` actually reach getUserMedia?
 *
 * Everything else in this testbed depends on the answer, so it gets its own check
 * rather than being assumed inside a larger script. If this prints SILENT, no amount
 * of downstream cleverness matters.
 */

import { chromium } from 'playwright-core';
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
export const CHROME =
  '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';

const wav = process.argv[2] ?? join(HERE, 'media/probe.wav');

// getUserMedia needs a secure context; http://localhost qualifies.
const server = createServer((req, res) => {
  res.writeHead(200, { 'content-type': 'text/html' });
  res.end(readFileSync(join(HERE, 'probe.html')));
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const port = server.address().port;

const browser = await chromium.launch({
  executablePath: CHROME,
  headless: true,
  args: [
    '--use-fake-ui-for-media-stream', // auto-grant, no permission dialog
    '--use-fake-device-for-media-stream', // synthetic devices instead of real hardware
    `--use-file-for-fake-audio-capture=${wav}`, // ← the whole point
    '--autoplay-policy=no-user-gesture-required',
  ],
});
const page = await browser.newPage();
page.on('console', (m) => console.log('  [browser]', m.text()));
await page.goto(`http://127.0.0.1:${port}/`);
await page.waitForFunction(() => window.__probe?.done, null, { timeout: 20000 });
const r = await page.evaluate(() => window.__probe);

console.log('\n' + JSON.stringify(r, null, 1));
console.log(
  r.ok
    ? '\n✓ Real recorded audio is reaching getUserMedia. The testbed is viable.'
    : `\n✗ No audio. ${r.err ?? 'Track was silent.'}`,
);

await browser.close();
server.close();
process.exit(r.ok ? 0 : 1);
