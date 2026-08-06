// Reproduce the LIVE-CALL path: no ?xlate= param, user clicks the 🌐 button.
// A's browser locale is es-ES, B's en-US — the languages the button infers.
import { chromium } from 'playwright-core';
const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const WAV = '/Users/earningsgpt/video calling/testbed/media/conv/A.wav';
const BASE = process.env.BASE ?? 'https://room.tokkah.com';
const LOC_A = process.env.LOC_A ?? 'es-ES';
const LOC_B = process.env.LOC_B ?? 'en-US';
const SECS = Number(process.env.SECS ?? 60);
const CLICKER = process.env.CLICKER ?? 'A'; // which side presses the globe

const b = await chromium.launch({ executablePath: CHROME, headless: true, args: [
  '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
  `--use-file-for-fake-audio-capture=${WAV}`,
  '--autoplay-policy=no-user-gesture-required', '--mute-audio'] });
const room = 'gb' + Math.random().toString(36).slice(2, 8);
const mk = async (locale) => {
  const ctx = await b.newContext({ locale, permissions: ['camera', 'microphone'] });
  const p = await ctx.newPage();
  p.on('pageerror', (e) => console.log(`[pageerror ${locale}]`, String(e).slice(0, 200)));
  await p.goto(`${BASE}/?r=${room}`, { waitUntil: 'domcontentloaded' });
  await p.waitForSelector('#join');
  await p.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 20000 });
  return p;
};
const A = await mk(LOC_A);
const B = await mk(LOC_B);
console.log('room', room, 'A locale', LOC_A, 'B locale', LOC_B, 'clicker', CLICKER);
console.log('A navigator.language =', await A.evaluate(() => navigator.language));
console.log('B navigator.language =', await B.evaluate(() => navigator.language));
await A.click('#join'); await B.click('#join');
await A.waitForFunction(() => document.getElementById('status')?.textContent === 'connected', null, { timeout: 30000 });
await B.waitForFunction(() => document.getElementById('status')?.textContent === 'connected', null, { timeout: 30000 });
console.log('connected; clicking the globe on', CLICKER);
const clicker = CLICKER === 'A' ? A : B;
await clicker.click('#xlate');
await new Promise((r) => setTimeout(r, SECS * 1000));
const read = (p) => p.evaluate(() => {
  const x = window.__xlateStats;
  const tel = (window.__tape?.tel?.mirror ?? []).filter((e) => /xlate/.test(e.kind)).slice(-8)
    .map((e) => e.kind + ' ' + JSON.stringify(e.data).slice(0, 100));
  return { btnOff: document.getElementById('xlate')?.getAttribute('data-off'),
    stats: x ? { open: x.open, ready: x.ready, capsPeer: x.capsPeer, partials: x.partials,
      binChunks: x.binChunks, binBytes: x.binBytes, voiceOnsets: x.voiceOnsets.length,
      flushes: x.flushes, errs: x.errs.slice(-4), lastCap: x.lastCap } : null, tel };
});
for (const [n, p] of [['A', A], ['B', B]]) {
  const r = await read(p);
  console.log(`\n== ${n} == btn data-off=${r.btnOff}`);
  console.log('  stats', JSON.stringify(r.stats));
  console.log('  tel:\n   ', r.tel.join('\n    '));
}
await b.close();
