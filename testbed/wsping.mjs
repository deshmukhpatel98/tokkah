/**
 * Does the signaling keepalive actually fire, and does it stay off the peer?
 *
 * The signaling socket says nothing after the offer/answer/ICE exchange, and an
 * idle TCP connection through a VPN or proxy gets reaped — measured as 37
 * `recover {why:"ws-close"}` events across the captured Delhi calls. The room
 * now answers a 25 s ping itself.
 *
 * Two things have to be true and the second is the one worth testing:
 *   1. the pong comes back (the socket is being kept warm at all)
 *   2. the ping NEVER reaches the other person — it terminates at the room.
 *      A keepalive that broadcast would be a new message on the peer's
 *      signaling path every 25 s, and the peer's handler dispatches on
 *      `m.type` against a chain it does not own.
 *
 *   node wsping.mjs
 */
import { chromium } from 'playwright-core';

const URL_BASE = process.env.URL ?? 'https://room.tokkah.com';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
const room = `bot-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
// 4 s so the run is short; the shipped default is 25 s and the code path is the
// same one. The point is that the mechanism works, not that 25 is 25.
const PING_S = 4;

const launch = (side) => chromium.launch({
  executablePath: CHROME, headless: true,
  args: [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    `--use-file-for-fake-video-capture=${media(`real${side}.mjpeg`)}`,
    `--use-file-for-fake-audio-capture=${media(`real${side}.wav`)}`,
    '--autoplay-policy=no-user-gesture-required',
    '--disable-features=WebRtcHideLocalIpsWithMdns',
  ],
});

const A = await launch('A'), B = await launch('B');
const a = await A.newPage(), b = await B.newPage();

// Record EVERY frame each side receives on its signaling socket, before the app
// sees it. This is what proves a ping does not leak to the peer.
const spy = (p) => p.addInitScript(() => {
  window.__rx = [];
  const OrigWS = WebSocket;
  window.WebSocket = function (...args) {
    const s = new OrigWS(...args);
    s.addEventListener('message', (e) => {
      if (typeof e.data === 'string') {
        try { window.__rx.push(JSON.parse(e.data)?.type ?? '?'); } catch { window.__rx.push('?'); }
      }
    });
    return s;
  };
  window.WebSocket.prototype = OrigWS.prototype;
  Object.assign(window.WebSocket, OrigWS);
});

for (const [p, who] of [[a, 'A'], [b, 'B']]) {
  await spy(p);
  await p.goto(`${URL_BASE}/?wsping=${PING_S}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await p.waitForSelector('#join', { timeout: 20000 });
  await p.click('#more');
  await p.fill('#room', room);
  await p.keyboard.press('Escape');
  await p.click('#join', { timeout: 30000 }).catch(() => {});
  if (who === 'A') await p.waitForTimeout(1200);
}

await a.waitForTimeout(20000); // ~5 ping intervals

const rx = { A: await a.evaluate(() => window.__rx), B: await b.evaluate(() => window.__rx) };
const count = (arr, t) => arr.filter((x) => x === t).length;
for (const side of ['A', 'B']) {
  console.log(`${side} received: pong=${count(rx[side], 'pong')}  ping=${count(rx[side], 'ping')}  ` +
    `other=${rx[side].filter((x) => x !== 'pong' && x !== 'ping').join(',') || '-'}`);
}

const pongsFlow = count(rx.A, 'pong') >= 2 && count(rx.B, 'pong') >= 2;
const noLeak = count(rx.A, 'ping') === 0 && count(rx.B, 'ping') === 0;
console.log(`\nkeepalive answered:      ${pongsFlow ? 'PASS' : 'FAIL'}`);
console.log(`ping never reaches peer: ${noLeak ? 'PASS' : 'FAIL'}`);
const pass = pongsFlow && noLeak;
console.log(`\nVERDICT: ${pass ? 'PASS' : 'FAIL'}`);

await A.close(); await B.close();
process.exit(pass ? 0 : 1);
