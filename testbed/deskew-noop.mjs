// De-skew safety invariant, live prod: on a same-route call (all six lanes one
// path) the feature must be a strict no-op — skew ~0, buffer target unchanged
// vs the ?deskew=0 control arm. Real media both arms.
import { chromium } from 'playwright-core';
const CHROME = process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const A = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
const mk = (v, w) => (['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
  `--use-file-for-fake-video-capture=${A(v)}`, `--use-file-for-fake-audio-capture=${A(w)}`,
  '--autoplay-policy=no-user-gesture-required']);
async function arm(qs) {
  const bA = await chromium.launch({ executablePath: CHROME, headless: true, args: mk('realA.mjpeg', 'realA.wav') });
  const bB = await chromium.launch({ executablePath: CHROME, headless: true, args: mk('realB.mjpeg', 'realB.wav') });
  const R = `deskew${qs ? 'off' : 'on'}-${Date.now().toString(36)}`;
  const pA = await bA.newPage(), pB = await bB.newPage();
  await pA.goto(`https://room.tokkah.com/?r=${R}${qs}`); await pA.click('#join');
  await pB.goto(`https://room.tokkah.com/?r=${R}${qs}`); await pB.click('#join');
  for (const p of [pA, pB]) await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });
  await pA.waitForTimeout(45000);
  const s = await pA.evaluate(() => {
    const pc = window.__tape?.pcm;
    const snap = (typeof pc?.snapshot === 'function' ? pc.snapshot() : pc) ?? {};
    return {
      laneSkew: snap.laneSkew ?? null,
      m2e: snap.mouthToEarMs ?? null,
      ringDepthMs: snap.m2eParts?.ringDepthMs ?? null,
      framesRecv: window.__tape?.pcm?.framesRecv ?? null,
      conceal: window.__tape?.pcm?.concealedMs ?? null,
    };
  });
  await bA.close(); await bB.close();
  return s;
}
// PCM occasionally fails to start under stacked headless Chromes (seen live
// 2026-08-13: one arm returned all nulls, re-run alone was clean). One retry
// on a null-pcm arm keeps the rig from crying wolf.
async function armRetry(qs) {
  let s = await arm(qs);
  if (s.framesRecv == null) { console.log(`[retry] arm '${qs || 'on'}' returned null pcm; retrying once`); s = await arm(qs); }
  return s;
}
const on = await armRetry('');
const off = await armRetry('&deskew=0');
console.log('deskew ON :', JSON.stringify(on));
console.log('deskew OFF:', JSON.stringify(off));
const skewMax = on.laneSkew?.max ?? null;
console.log('assert laneSkew surfaced:', on.laneSkew ? 'PASS' : 'FAIL');
console.log('assert same-route skew ~0 (<2ms):', skewMax != null && skewMax < 2 ? 'PASS' : `FAIL (${skewMax})`);
const dd = (on.ringDepthMs != null && off.ringDepthMs != null) ? Math.abs(on.ringDepthMs - off.ringDepthMs) : null;
console.log('assert ring depth within 6ms of control:', dd != null && dd <= 6 ? 'PASS' : `FAIL (Δ${dd})`);
console.log('assert both arms played frames:', (on.framesRecv > 1000 && off.framesRecv > 1000) ? 'PASS' : 'FAIL');
const pass = !!on.laneSkew && skewMax != null && skewMax < 2 && dd != null && dd <= 6 && on.framesRecv > 1000 && off.framesRecv > 1000;
process.exitCode = pass ? 0 : 1;
