// Quick diagnostic: what does the app see on emulator Android Chrome —
// with a desktop peer, so the tape lane actually negotiates.
import { chromium } from 'playwright-core';
const BASE = 'https://room.tokkah.com';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
const ROOM = `emuprobe${Date.now().toString(36)}`;

console.log(`room: ${ROOM}`);
const b = await chromium.connectOverCDP(process.env.EMU_CDP ?? 'http://127.0.0.1:9223');
const ctx = b.contexts()[0];
await ctx.grantPermissions(['camera', 'microphone'], { origin: BASE }).catch(() => {});
const p = await ctx.newPage();
p.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') console.log(`[android ${m.type()}] ${m.text().slice(0, 220)}`); });
p.on('pageerror', (e) => console.log(`[android pageerror] ${e.message.slice(0, 220)}`));

const D = await chromium.launch({
  executablePath: CHROME, headless: true,
  args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    `--use-file-for-fake-video-capture=${media('realB.mjpeg')}`,
    `--use-file-for-fake-audio-capture=${media('realB.wav')}`,
    '--autoplay-policy=no-user-gesture-required'],
});
const d = await D.newPage();

for (const [pg, who] of [[p, 'android'], [d, 'desktop']]) {
  await pg.goto(`${BASE}/?r=${ROOM}&rig=1`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await pg.waitForSelector('#join', { timeout: 30000 });
  const cam = await pg.waitForFunction(() => /ready|blocked/.test(document.getElementById('previewBadge')?.textContent ?? ''), null, { timeout: 25000 })
    .then(() => pg.evaluate(() => document.getElementById('previewBadge')?.textContent)).catch(() => 'timeout');
  console.log(`${who} lobby badge: ${cam}`);
  await pg.click('#join').catch(() => {});
  if (who === 'android') await pg.waitForTimeout(2000);
}
await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 90000 }).catch(() => console.log('android: never connected'));
await p.waitForTimeout(20000);

const dump = (pg) => pg.evaluate(() => {
  const v = window.__tape?.video ?? {};
  return {
    status: document.getElementById('status')?.textContent ?? null,
    tapeMode: window.__tape?.tapeMode ?? null,
    videoSample: { fps: v.achievedFps, w: v.w, h: v.h, qp: v.qp, mbps: v.mbpsAtFps, keys: Object.keys(v).length },
    srcFrames: window.__tape?.srcprobe?.frames ?? null,
    hz: window.__tape?.hz ?? null,
  };
});
console.log('android:', JSON.stringify(await dump(p), null, 1));
console.log('desktop:', JSON.stringify(await dump(d), null, 1));
await p.close().catch(() => {});
await D.close();
process.exit(0);
