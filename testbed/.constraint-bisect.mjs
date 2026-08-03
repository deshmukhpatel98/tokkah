// Which part of the app's join-time video constraint does the M13 refuse?
// The app only ever survives because it REUSES the lobby preview track; its
// cold-join ask (`askBoth`) may never have run on this device.
import { chromium } from 'playwright-core';

const BASE = 'http://127.0.0.1:8794';
const b = await chromium.connectOverCDP('http://127.0.0.1:9222');
const ctx = b.contexts()[0];
for (const p of ctx.pages()) if (!p.isClosed() && p.url().startsWith(BASE)) await p.close().catch(() => {});
await ctx.grantPermissions(['camera', 'microphone'], { origin: BASE });

const page = await ctx.newPage();
// Load the app so we are on its origin, but kill its lobby preview immediately.
await page.goto(`${BASE}/?room=bisect`, { waitUntil: 'domcontentloaded' });
await page.waitForTimeout(2500);

const out = await page.evaluate(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const release = async () => {
    const pv = document.querySelector('#preview');
    pv?.srcObject?.getTracks?.().forEach((t) => t.stop());
    if (pv) pv.srcObject = null;
    await sleep(2000);
  };
  await release();

  const AUDIO = { echoCancellation: false, noiseSuppression: false, autoGainControl: false, channelCount: 1, sampleRate: 48000 };
  const cases = [
    ['video:true', { video: true }],
    ['1280 ideal (lobby ask)', { video: { width: { ideal: 1280 }, frameRate: { ideal: 30 } } }],
    ['1920x1080 ideal', { video: { width: { ideal: 1920 }, height: { ideal: 1080 }, frameRate: { ideal: 30 } } }],
    ['resizeMode none only', { video: { resizeMode: 'none' } }],
    ['1920x1080 + resizeMode (APP COLD-JOIN ASK)', { video: { width: { ideal: 1920 }, height: { ideal: 1080 }, frameRate: { ideal: 30 }, resizeMode: 'none' } }],
    ['APP COLD-JOIN ASK + audio (askBoth)', { video: { width: { ideal: 1920 }, height: { ideal: 1080 }, frameRate: { ideal: 30 }, resizeMode: 'none' }, audio: AUDIO }],
    ['1280x720 + resizeMode + audio', { video: { width: { ideal: 1280 }, height: { ideal: 720 }, frameRate: { ideal: 30 }, resizeMode: 'none' }, audio: AUDIO }],
    ['video:true + audio', { video: true, audio: AUDIO }],
  ];

  const results = [];
  for (const [name, c] of cases) {
    let r;
    try {
      const s = await navigator.mediaDevices.getUserMedia(c);
      const v = s.getVideoTracks()[0];
      const g = v?.getSettings?.() ?? {};
      r = { name, ok: true, got: `${g.width}x${g.height}@${g.frameRate}`, resizeMode: g.resizeMode ?? null };
      s.getTracks().forEach((t) => t.stop());
    } catch (e) {
      r = { name, ok: false, err: e.name, constraint: e.constraint ?? null, msg: String(e.message).slice(0, 90) };
    }
    results.push(r);
    await sleep(2000); // let the HAL settle between opens
  }
  return results;
});

for (const r of out) {
  console.log(r.ok ? `  ok    ${r.name}  ->  ${r.got}  resizeMode=${r.resizeMode}` : `  FAIL  ${r.name}  ->  ${r.err}${r.constraint ? ` (constraint=${r.constraint})` : ''}  ${r.msg}`);
}
await page.close().catch(() => {});
await b.close();
