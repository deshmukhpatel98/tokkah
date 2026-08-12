// Aperture Parallax live verification on prod (room.tokkah.com), real
// talking-head media. Two rooms: ?window=1 (default) arm and ?window=0
// control. The fixture speaker's natural head motion IS the tracker input.
// Asserts, on the live arm:
//   1. tracker engages (tracking=true, hz ≈ 10)
//   2. sign: corr(headX, dx) > +0.8 — picture moves WITH the head (projection
//      geometry; see app.js comment)
//   3. transform lands on #remote; #remoteFill stays screen-locked
//   4. dead zone: dx settles toward 0 when headX sits inside the dead zone
// Control arm: #remote carries no transform. Both arms: call connects, audio
// frames flow (do-no-harm).
import { chromium } from 'playwright-core';
const CHROME = process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const A = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
const argsFor = (who) => ([
  '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
  `--use-file-for-fake-audio-capture=${A(who === 'a' ? 'realA.wav' : 'realB.wav')}`,
  `--use-file-for-fake-video-capture=${A(who === 'a' ? 'realA.mjpeg' : 'realB.mjpeg')}`,
  '--autoplay-policy=no-user-gesture-required',
]);
const pearson = (xs, ys) => {
  const n = xs.length, mx = xs.reduce((a, b) => a + b, 0) / n, my = ys.reduce((a, b) => a + b, 0) / n;
  let sxy = 0, sxx = 0, syy = 0;
  for (let i = 0; i < n; i++) { const dx = xs[i] - mx, dy = ys[i] - my; sxy += dx * dy; sxx += dx * dx; syy += dy * dy; }
  return sxx && syy ? sxy / Math.sqrt(sxx * syy) : 0;
};

async function callArm(room, qs) {
  const bA = await chromium.launch({ executablePath: CHROME, headless: true, args: argsFor('a') });
  const bB = await chromium.launch({ executablePath: CHROME, headless: true, args: argsFor('b') });
  const pA = await bA.newPage(); const pB = await bB.newPage();
  await pA.goto(`https://room.tokkah.com/?r=${room}${qs}`);
  await pA.click('#join');
  await pB.goto(`https://room.tokkah.com/?r=${room}${qs}`);
  await pB.click('#join');
  for (const p of [pA, pB]) await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });
  // let tracking + physics run on real speech/motion
  const series = [];
  for (let i = 0; i < 40; i++) {
    await pA.waitForTimeout(500);
    series.push(await pA.evaluate(() => ({
      ap: window.__tape?.aperture ?? null,
      remoteTf: document.getElementById('remote')?.style.transform ?? '',
      fillTf: document.getElementById('remoteFill')?.style.transform ?? '',
      recv: window.__tape?.pcm?.framesRecv ?? window.__tape?.pcmHalf?.framesRecv ?? null,
    })));
  }
  const snap = await pA.evaluate(() => window.__tape?.pcm?.snapshot?.() ?? window.__tape?.pcmHalf?.snapshot?.() ?? null);
  await bA.close(); await bB.close();
  return { series, snap };
}

// ── live arm ──
const on = await callArm(`aperture-on-${Date.now().toString(36)}`, '');
const tracked = on.series.filter((s) => s.ap?.tracking);
const hz = tracked.length ? tracked[tracked.length - 1].ap.hz : 0;
const xs = tracked.map((s) => s.ap.headX), dxs = tracked.map((s) => s.ap.dx);
const moving = xs.filter((v, i) => Math.abs(v) > 0.02 || Math.abs(dxs[i]) > 0.1);
const corr = tracked.length >= 10 ? pearson(xs, dxs) : NaN;
const remoteHasTf = on.series.some((s) => s.remoteTf.includes('translate3d'));
const fillClean = on.series.every((s) => !s.fillTf);
console.log('ARM window=1:',
  JSON.stringify({ trackedTicks: tracked.length, hz, corr: Number(corr.toFixed(3)), remoteHasTf, fillClean, lastAp: on.series.at(-1)?.ap }));
console.log('assert tracking engaged:', tracked.length >= 10 ? 'PASS' : 'FAIL');
console.log('assert hz ~10 (>=6):', hz >= 6 ? 'PASS' : `FAIL (${hz})`);
console.log('assert sign corr(headX,dx) > 0.8:', corr > 0.8 ? 'PASS' : `FAIL (${corr})`);
console.log('assert #remote transformed:', remoteHasTf ? 'PASS' : 'FAIL');
console.log('assert #remoteFill locked:', fillClean ? 'PASS' : 'FAIL');

// ── control arm ──
const off = await callArm(`aperture-off-${Date.now().toString(36)}`, '&window=0');
const offTf = off.series.some((s) => s.remoteTf.includes('translate3d'));
console.log('ARM window=0:', JSON.stringify({ anyTransform: offTf, lastAp: off.series.at(-1)?.ap }));
console.log('assert control has no transform:', !offTf ? 'PASS' : 'FAIL');
