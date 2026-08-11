#!/usr/bin/env node
/**
 * One-line embed live test — the README's headline integration, end to end.
 *
 * A third-party page carries nothing but the one script tag (the REAL
 * deployed embed.js); the iframe it injects is the REAL prod app; the peer
 * is a normal app tab. Found broken 2026-08-11 (frame-ancestors 'none'
 * refused every embedding site since the embed shipped) — this rig exists
 * so that can never be silent again.
 *
 *   node testbed/embed-call.mjs [--base=https://room.tokkah.com]
 */
import { chromium } from 'playwright-core';

const KNOWN = new Set(['base', 'headed']);
const args = {};
for (const a of process.argv.slice(2)) {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/);
  if (!m || !KNOWN.has(m[1])) { console.error(`unknown flag: ${a}`); process.exit(2); }
  args[m[1]] = m[2] ?? '1';
}
const BASE = args.base ?? 'https://room.tokkah.com';
const CHROME =
  process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');

async function launch() {
  const browser = await chromium.launch({
    executablePath: CHROME,
    headless: !args.headed,
    args: [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      // The testing-realism law (2026-08-11): real talking-head media, never
      // synthetic artifacts — a fake device's beep-and-spinner exercises nothing
      // a human call exercises. Fixtures: testbed/media/real/fetch.sh.
      `--use-file-for-fake-audio-capture=${decodeURIComponent(new URL('./media/real/realA.wav', import.meta.url).pathname)}`,
      `--use-file-for-fake-video-capture=${decodeURIComponent(new URL('./media/real/realA.mjpeg', import.meta.url).pathname)}`,
      '--autoplay-policy=no-user-gesture-required',
      '--alsa-output-device=null',
    ],
  });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e).slice(0, 100)));
  return { browser, page, errors };
}

const ROOM = `emb-${Date.now().toString(36)}`;
const A = await launch(); // the embedding page
const B = await launch(); // a normal app peer

// The embedding page must live on a REAL https origin: an about:blank parent
// (page.setContent) cannot delegate camera/mic to the iframe, which no real
// website suffers. route() serves the third-party page in-browser; the
// script and the iframe it injects still hit the real deployed BASE.
const embCtx = A.page.context();
await embCtx.route('https://embed-host.example/**', (route) => route.fulfill({
  contentType: 'text/html',
  body: `<!doctype html><html><body><h1>Some third-party site</h1>
    <script src="${BASE}/embed.js" data-room="${ROOM}"></script>
  </body></html>`,
}));
await A.page.goto('https://embed-host.example/');
const frame = await (await A.page.waitForSelector('iframe', { timeout: 15000 })).contentFrame();
await frame.waitForSelector('#join:not([disabled])', { timeout: 20000 });
await frame.click('#join');

await B.page.goto(`${BASE}/?r=${ROOM}`);
await B.page.click('#join');
const okB = await B.page.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 45000 }).then(() => true, () => false);
await B.page.waitForTimeout(12000);

const emb = await frame.evaluate(() => ({
  conn: window.__tape?.pc?.connectionState,
  framesSent: window.__tape?.pcm?.framesSent ?? 0,
  mode: window.__tape?.pcm?.mode ?? null, // iframe on a plain parent is not isolated → 'port' is the expected answer
  status: document.getElementById('joinStatus')?.textContent ?? '',
})).catch((e) => ({ err: String(e).slice(0, 100) }));
const app = await B.page.evaluate(() => ({
  conn: window.__tape?.pc?.connectionState,
  pcmRecv: window.__tape?.pcm?.framesRecv ?? 0,
  conceal: window.__tape?.pcm?.concealedMs,
}));

const ok = okB && emb.conn === 'connected' && emb.framesSent > 200 && app.pcmRecv > 200
  && A.errors.length === 0 && B.errors.length === 0;
console.log(`embed=${JSON.stringify(emb)} app=${JSON.stringify(app)} errEmbedPage=${A.errors.length} errApp=${B.errors.length}`);
console.log(`\nverdict: ${ok ? 'OK' : 'FAIL'}`);
await A.browser.close();
await B.browser.close();
process.exit(ok ? 0 : 1);
