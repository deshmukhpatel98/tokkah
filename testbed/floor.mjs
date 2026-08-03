/**
 * Read the detector's actual floor and SNR against the real fake-mic stream.
 *
 * Written because a turn stopped ending in a real call and the reason was not
 * deducible from the code. Two numbers decide it — the tracked floor and the level of
 * the arriving audio — and neither was visible.
 */

import { chromium } from 'playwright-core';
import { createServer } from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { join, dirname, extname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const CHROME =
  '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';

const wav = process.argv[2] ?? join(HERE, 'media/conv/A.wav');
const ms = Number(process.argv[3] ?? 50000);

const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json' };
const server = createServer((req, res) => {
  const url = req.url.split('?')[0];
  // `/core/*` maps to the shared DSP directory so the probe runs the same file the app
  // ships, not a copy that could drift from it.
  const path = url.startsWith('/core/')
    ? join(HERE, '..', url)
    : join(HERE, url === '/' ? 'floor.html' : url);
  if (!existsSync(path)) {
    res.writeHead(404).end('no');
    return;
  }
  res.writeHead(200, { 'content-type': TYPES[extname(path)] ?? 'application/octet-stream' });
  res.end(readFileSync(path));
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const port = server.address().port;

const browser = await chromium.launch({
  executablePath: CHROME,
  headless: true,
  args: [
    '--use-fake-ui-for-media-stream',
    '--use-fake-device-for-media-stream',
    `--use-file-for-fake-audio-capture=${wav}`,
    '--autoplay-policy=no-user-gesture-required',
  ],
});
const page = await browser.newPage();
page.on('pageerror', (e) => console.log('  [pageerror]', e.message));
await page.goto(`http://127.0.0.1:${port}/?ms=${ms}`);
await page.waitForFunction(() => window.__floor?.done, null, { timeout: ms + 20000 });
const { trace, events } = await page.evaluate(() => ({ trace: window.__floor.trace, events: window.__floor.events }));

console.log(`\n${wav}\n`);
console.log('events:');
for (const e of events) {
  console.log(
    `  ${String(e.t).padStart(6)} ${e.type.padEnd(11)} ${String(e.kind ?? '').padEnd(10)}` +
      `${e.snrDb != null ? ` snr ${String(e.snrDb).padStart(6)}` : ''}` +
      `${e.floorDb != null ? ` floor ${String(e.floorDb).padStart(7)}` : ''}` +
      `${e.durationMs != null ? ` dur ${String(e.durationMs).padStart(6)}` : ''}${e.forced ? '  FORCED' : ''}`,
  );
}

// The diagnostic that matters: what does "quiet" actually measure against the floor?
const idle = trace.filter((r) => r.state === 'idle' && r.snr != null);
const active = trace.filter((r) => r.state === 'active' && r.snr != null);
const pct = (xs, p) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  return +s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))].toFixed(1);
};
console.log(`\nidle samples (n=${idle.length}): level ${pct(idle.map((r) => r.db), 50)} dBFS, floor ${pct(idle.map((r) => r.floor), 50)} dBFS`);
console.log(`  SNR while idle — this is what "quiet" measures as:`);
console.log(`    p10 ${pct(idle.map((r) => r.snr), 10)}  p50 ${pct(idle.map((r) => r.snr), 50)}  p90 ${pct(idle.map((r) => r.snr), 90)}  max ${pct(idle.map((r) => r.snr), 100)} dB`);
console.log(`  END_SNR_DB is 3 — anything at or above it while quiet means a turn cannot end.`);
if (active.length) {
  const quiet = active.filter((r) => r.db < -45);
  console.log(`\nactive samples (n=${active.length}); of those, ${quiet.length} were genuinely quiet (< -45 dBFS)`);
  if (quiet.length) {
    console.log(`  their SNR against the frozen floor: p50 ${pct(quiet.map((r) => r.snr), 50)}  p90 ${pct(quiet.map((r) => r.snr), 90)} dB`);
  }
  console.log(`  longest active stretch: ${Math.max(...active.map((r) => r.active))} hops = ${((Math.max(...active.map((r) => r.active)) * 240) / 48).toFixed(0)} ms`);
}
console.log(`\nfirst 40 trace rows:`);
for (const r of trace.slice(0, 40)) {
  console.log(
    `  ${String(r.t).padStart(6)} ${r.state.padEnd(7)} lvl ${String(r.db).padStart(7)} floor ${String(r.floor).padStart(7)} snr ${String(r.snr).padStart(6)} quiet ${String(r.quiet).padStart(4)} active ${String(r.active).padStart(5)} real ${r.real}`,
  );
}

await browser.close();
server.close();
