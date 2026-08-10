#!/usr/bin/env node
/**
 * AEC latch end-to-end. Chrome's fake audio device is a PERIODIC beep, so in a
 * two-Chromium call each side hears a beep train whose envelope correlates
 * with its own mic's beep train at a stable lag — which is indistinguishable
 * from acoustic echo to an envelope correlator, and that is exactly the point:
 * it drives the shipped detect → latch → reacquire chain in a real call
 * without needing real acoustics (fake devices cannot feed playout back into
 * capture, so genuine echo is impossible here).
 *
 * Arms:
 *   auto  — no flag: the detector must latch, and the mic track must come back
 *           with echoCancellation:true while NS/AGC stay false.
 *   off   — ?aec=0: nothing may fire for the whole window and the mic stays raw.
 *   force — ?aec=1: echoCancellation:true from the FIRST getUserMedia.
 *
 *   node testbed/aec-call.mjs [--url=http://127.0.0.1:8794]
 */
import { chromium } from 'playwright-core';

const KNOWN = new Set(['url', 'headed']);
const args = {};
for (const a of process.argv.slice(2)) {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/);
  if (!m || !KNOWN.has(m[1])) { console.error(`unknown flag: ${a}`); process.exit(2); } // unknown flags are fatal
  args[m[1]] = m[2] ?? '1';
}
const URL_BASE = args.url ?? 'http://127.0.0.1:8794';
const CHROME =
  process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');

async function launch() {
  const browser = await chromium.launch({
    executablePath: CHROME,
    headless: !args.headed,
    args: [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      '--autoplay-policy=no-user-gesture-required',
      '--alsa-output-device=null',
    ],
  });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  return { browser, page, errors };
}

const micSettings = (page) =>
  page.evaluate(() => {
    const t = document.getElementById('selfFull').srcObject?.getAudioTracks?.()[0];
    if (!t) return null;
    const s = t.getSettings?.() ?? {};
    return { ec: s.echoCancellation, ns: s.noiseSuppression, agc: s.autoGainControl, state: t.readyState };
  });

async function runArm(mode) {
  // With aec2 default ON the echo-detected latch stands down to telemetry —
  // every arm here pins ?aec2=0 because this rig tests the FALLBACK path
  // (the Chrome-AEC latch), which must stay healthy for non-isolated pages
  // where the SAB lane (and so aec2) cannot run.
  const q = (mode === 'off' ? '&aec=0' : mode === 'force' ? '&aec=1' : '') + '&aec2=0';
  const ROOM = `ae-${mode}-${Date.now().toString(36)}`;
  const A = await launch();
  const B = await launch();
  for (const S of [A, B]) {
    await S.page.goto(`${URL_BASE}/?r=${ROOM}${q}`);
    await S.page.click('#join');
  }
  await A.page.waitForFunction(() => (window.__tape?.pcm?.framesSent ?? 0) > 100, null, { timeout: 30000 });

  let ok, detail;
  if (mode === 'force') {
    const s = await micSettings(A.page);
    ok = s?.ec === true && s?.ns === false && s?.agc === false && s?.state === 'live';
    detail = JSON.stringify(s);
  } else if (mode === 'auto') {
    // The detector needs ≥2 s of both envelopes plus 3 consecutive 500 ms polls;
    // give it a wide margin, then require the reacquired track.
    ok = await A.page
      .waitForFunction(() => {
        const s = document.getElementById('selfFull').srcObject?.getAudioTracks?.()[0]?.getSettings?.();
        return s?.echoCancellation === true;
      }, null, { timeout: 45000 })
      .then(() => true, () => false);
    const s = await micSettings(A.page);
    ok = ok && s?.ns === false && s?.agc === false && s?.state === 'live';
    detail = JSON.stringify(s);
  } else {
    // off: hold the same window the auto arm gets, then demand a raw mic.
    await A.page.waitForTimeout(20000);
    const s = await micSettings(A.page);
    ok = s?.ec === false && s?.state === 'live';
    detail = JSON.stringify(s);
  }
  const pcmB = await B.page.evaluate(() => window.__tape?.pcm?.framesRecv ?? 0);
  ok = ok && A.errors.length === 0 && pcmB > 100;
  console.log(`arm=${mode}: mic=${detail} pageerrors=${A.errors.length} B.pcmRecv=${pcmB} -> ${ok ? 'OK' : 'FAIL'}`);
  if (!ok && A.errors.length) console.log('  pageerrors:', A.errors);
  await A.browser.close();
  await B.browser.close();
  return ok;
}

const okF = await runArm('force');
const okO = await runArm('off');
const okA = await runArm('auto');
console.log(`\nverdict: force ${okF ? 'OK' : 'FAIL'}, off ${okO ? 'OK' : 'FAIL'}, auto ${okA ? 'OK' : 'FAIL'}`);
process.exit(okF && okO && okA ? 0 : 1);
