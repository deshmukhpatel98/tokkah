import { chromium } from 'playwright-core';
const ROOM = process.env.ROOM, HOLD = Number(process.env.HOLD_S || 75);
const CHROME = process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const b = await chromium.launch({ executablePath: CHROME, args: [
  '--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream',
  '--autoplay-policy=no-user-gesture-required'] });
const p = await b.newPage();
await p.goto(`https://room.tokkah.com/${ROOM}?hb=1`, { waitUntil: 'domcontentloaded', timeout: 60000 });
await p.click('#join', { timeout: 30000 }).catch(() => {});
await p.waitForTimeout(HOLD * 1000);
const snap = await p.evaluate(() => {
  const pcm = window.__tape && window.__tape.pcm;
  const s = pcm && typeof pcm.snapshot === 'function' ? pcm.snapshot() : pcm;
  const lane = window.__tape?.lane?.snapshot?.() ?? null;
  return { mouthToEarMs: s?.mouthToEarMs ?? null, ringDepthMs: s?.m2eParts?.ringDepthMs ?? null,
           framesRecv: s?.framesRecv ?? null, concealedMs: s?.concealedMs ?? null,
           glassToGlassMs: lane?.glassToGlassMs ?? null,
           assocRtt: (s?.perAssoc ?? []).map(a => a.rttMs) };
});
console.log('LOCAL(Delhi):', JSON.stringify(snap));
await b.close();
