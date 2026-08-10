// Scenario 3 only, instrumented: did the incumbent actually receive
// `peer-joined`, and did it re-arm? URL and ws traffic, not status text.
import { chromium } from 'playwright-core';

const CHROME =
  process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const BASE = process.argv[2] ?? 'https://room.tokkah.com';

async function launch() {
  return chromium.launch({
    executablePath: CHROME,
    headless: true,
    args: [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      '--autoplay-policy=no-user-gesture-required',
      '--alsa-output-device=null',
      '--disable-features=WebRtcHideLocalIpsWithMdns',
    ],
  });
}
// Tap the socket in the page so we see exactly what the DO said and when.
const TAP = `
  window.__wsrx = [];
  const OW = WebSocket;
  window.WebSocket = function (...a) {
    const s = new OW(...a);
    s.addEventListener('message', (e) => {
      try { window.__wsrx.push([Math.round(performance.now()), JSON.parse(e.data).type]); } catch {}
    });
    return s;
  };
  window.WebSocket.prototype = OW.prototype;
  Object.assign(window.WebSocket, OW);
`;
async function ready(page, url) {
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(() => /ready|blocked|no camera/.test(document.getElementById('previewBadge')?.textContent ?? ''), { timeout: 25000 }).catch(() => {});
}
const look = (p) =>
  p.evaluate(() => {
    const v = document.getElementById('remote');
    return {
      url: location.href,
      rejoinParam: new URLSearchParams(location.search).get('rejoin'),
      rearmAt: sessionStorage.getItem('tape.rearmAt'),
      status: document.getElementById('status')?.textContent?.trim(),
      size: `${v.videoWidth}x${v.videoHeight}`,
      t: +v.currentTime.toFixed(2),
      rx: window.__wsrx ?? null,
    };
  });

const bA = await launch(), bB = await launch();
const A = await bA.newPage(), B = await bB.newPage();
await A.addInitScript(TAP);
await B.addInitScript(TAP);
for (const [tag, p] of [['A', A], ['B', B]]) {
  p.on('console', (m) => { if (/rearm|error/i.test(m.text()) && !/Content Security|cloudflareinsights/.test(m.text())) console.log(`  [${tag} console] ${m.text().slice(0, 160)}`); });
  p.on('pageerror', (e) => console.log(`  [${tag} pageerror] ${String(e.message).slice(0, 200)}`));
}
try {
  await ready(A, BASE);
  await A.click('#join');
  await A.waitForTimeout(2500);
  const link = await A.evaluate(() => document.getElementById('shareUrl').value);
  await ready(B, link);
  await B.click('#join');
  await A.waitForTimeout(10000);
  console.log('\nbaseline');
  console.log('  A', JSON.stringify(await look(A)));
  console.log('  B', JSON.stringify(await look(B)));

  console.log('\nA reloads and rejoins');
  await ready(A, A.url());
  await A.click('#join');
  for (const s of [3, 6, 10, 16]) {
    await A.waitForTimeout(s === 3 ? 3000 : s === 6 ? 3000 : s === 10 ? 4000 : 6000);
    const b = await look(B);
    console.log(`  t+${s}s  B url=${b.url.replace(BASE, '')}`);
    console.log(`         B rejoin=${b.rejoinParam} rearmAt=${b.rearmAt} status="${b.status}" size=${b.size} t=${b.t}`);
    console.log(`         B ws rx: ${JSON.stringify(b.rx)}`);
  }
  const a = await look(A);
  console.log(`  A final size=${a.size} t=${a.t} ws rx: ${JSON.stringify(a.rx)}`);
} catch (e) {
  console.log('HARNESS', e.message);
} finally {
  await bA.close(); await bB.close();
}
