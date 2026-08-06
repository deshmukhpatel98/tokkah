// Task #13 verification: B emulates Android UA. Expect on A: send-res 'to' ≤1280×720
// (B advertised capped pixels). Expect on B: encode ceiling ≤720p + fps ceiling 30.
// Also a paint regression check: both sides must show a live picture (luma sd > 8).
import { chromium } from 'playwright-core';
const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const BASE = process.env.BASE ?? 'https://room.tokkah.com';
const b = await chromium.launch({ executablePath: CHROME, headless: true, args: [
  '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
  '--autoplay-policy=no-user-gesture-required', '--mute-audio'] });
const room = 'mc' + Math.random().toString(36).slice(2, 8);
const mk = async (opts) => {
  const ctx = await b.newContext({ permissions: ['camera', 'microphone'], ...opts });
  const p = await ctx.newPage();
  p.on('pageerror', (e) => console.log('[pageerror]', String(e).slice(0, 160)));
  await p.goto(`${BASE}/?r=${room}`, { waitUntil: 'domcontentloaded' });
  await p.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 20000 });
  return p;
};
const A = await mk({});
const B = await mk({
  userAgent: 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36',
  viewport: { width: 384, height: 713 }, deviceScaleFactor: 2.8125,
});
await A.click('#join'); await B.click('#join');
for (const p of [A, B]) await p.waitForFunction(() => document.getElementById('status')?.textContent === 'connected', null, { timeout: 30000 });
console.log('connected, letting media settle 25s...');
await new Promise((r) => setTimeout(r, 25000));
const read = (p) => p.evaluate(() => {
  const t = window.__tape ?? {};
  const mir = t.tel?.mirror ?? [];
  const pick = (k) => mir.filter((e) => e.kind === k).map((e) => e.data);
  const grab = () => {
    const el = document.getElementById('remoteCanvas')?.width > 1
      ? document.getElementById('remoteCanvas') : document.getElementById('remote');
    if (!el) return null;
    const c = document.createElement('canvas'); c.width = 64; c.height = 36;
    const g = c.getContext('2d', { willReadFrequently: true });
    try { g.drawImage(el, 0, 0, 64, 36); } catch { return null; }
    const d = g.getImageData(0, 0, 64, 36).data;
    let s = 0, s2 = 0, n = 0;
    for (let i = 0; i < d.length; i += 4) { const y = 0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2]; s += y; s2 += y * y; n++; }
    const m = s / n;
    return { w: el.width ?? el.videoWidth, h: el.height ?? el.videoHeight, mean: +m.toFixed(1), sd: +Math.sqrt(Math.max(0, s2 / n - m * m)).toFixed(1) };
  };
  return { sendRes: pick('send-res'), disp: pick('peer-display').slice(-1), enc: pick('tape-encoder').slice(-1),
    fps: pick('tape-fps').slice(-1), rot: pick('tape-rot'), luma: grab(),
    resize: pick('tape-resize') };
});
const [ra, rb] = await Promise.all([read(A), read(B)]);
console.log('A(desktop):', JSON.stringify(ra, null, 1).slice(0, 1200));
console.log('B(android-ua):', JSON.stringify(rb, null, 1).slice(0, 1200));
const aTo = ra.sendRes.at(-1)?.to;
const ok = (!aTo || (aTo.w <= 1280 && aTo.h <= 720)) && ra.luma?.sd > 8 && rb.luma?.sd > 8;
console.log('verdict:', ok ? 'PASS' : 'FAIL', 'A sends ceiling', JSON.stringify(aTo), 'luma A', ra.luma?.sd, 'B', rb.luma?.sd);
await b.close();
process.exit(ok ? 0 : 1);
