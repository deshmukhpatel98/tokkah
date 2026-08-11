#!/usr/bin/env node
/**
 * Presence live-call test — real browsers in a real production call, per the
 * standing rule: verification happens ONLY in live calls (default --url is
 * production, never a simulation).
 *
 * Arms:
 *   on  — both pages ?presence=1: playout opens stereo, the room renderer
 *         (presence-core.js) runs on the audio thread, its stats ride
 *         pcm-stats into the snapshot, audio flows.
 *   off — no flag: snapshot presence is null, node stays mono — the
 *         byte-identical control arm.
 *
 *   node testbed/presence-call.mjs [--url=https://room.tokkah.com]
 */
import { chromium } from 'playwright-core';

const KNOWN = new Set(['url', 'headed']);
const args = {};
for (const a of process.argv.slice(2)) {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/);
  if (!m || !KNOWN.has(m[1])) { console.error(`unknown flag: ${a}`); process.exit(2); }
  args[m[1]] = m[2] ?? '1';
}
const URL_BASE = args.url ?? 'https://room.tokkah.com';
const CHROME =
  process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');

async function launch() {
  const browser = await chromium.launch({
    executablePath: CHROME,
    headless: !args.headed,
    args: [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      // The testing-realism law (2026-08-11): real talking-head media, never
      // synthetic artifacts — a fake device's beep-and-spinner exercises nothing
      // a human call exercises. Fixtures: testbed/media/real/fetch.sh.
      `--use-file-for-fake-audio-capture=${decodeURIComponent(new URL('./media/real/realA.wav', import.meta.url).pathname)}`,
      `--use-file-for-fake-video-capture=${decodeURIComponent(new URL('./media/real/realA.mjpeg', import.meta.url).pathname)}`,
      '--autoplay-policy=no-user-gesture-required',
      '--alsa-output-device=null',
    ],
  });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  return { browser, page, errors };
}

async function runArm(mode) {
  // presence is DEFAULT ON (2026-08-11): the on arm rides the default, the
  // off arm is the explicit ?presence=0 control.
  const q = mode === 'on' ? '' : '&presence=0';
  const ROOM = `presence-${mode}-${Date.now().toString(36)}`;
  const A = await launch();
  const B = await launch();
  for (const S of [A, B]) {
    await S.page.goto(`${URL_BASE}/?r=${ROOM}${q}`);
    await S.page.click('#join');
  }
  await A.page.waitForFunction(() => (window.__tape?.pcm?.framesSent ?? 0) > 100, null, { timeout: 30000 });

  let ok = false, detail = '';
  if (mode === 'on') {
    // presence stats arrive on the worklet's 1 Hz tick — wait for the field.
    const gotStats = await A.page
      .waitForFunction(() => window.__tape?.pcm?.presence != null, null, { timeout: 20000 })
      .then(() => true, () => false);
    const gotStatsB = await B.page
      .waitForFunction(() => window.__tape?.pcm?.presence != null, null, { timeout: 20000 })
      .then(() => true, () => false);
    const pA = gotStats ? await A.page.evaluate(() => window.__tape?.pcm?.presence) : null;
    const pB = gotStatsB ? await B.page.evaluate(() => window.__tape?.pcm?.presence) : null;
    const pcmB = await B.page.evaluate(() => window.__tape?.pcm?.framesRecv ?? 0);
    const noErrors = A.errors.length === 0 && B.errors.length === 0;
    // The renderer must have actually run (samples advance with the DAC).
    const ranA = pA?.type === 'presence' && pA.samples > 0;
    const ranB = pB?.type === 'presence' && pB.samples > 0;
    ok = gotStats && gotStatsB && ranA && ranB && noErrors && pcmB > 100;
    detail = `presenceA=${JSON.stringify(pA)} presenceB=${JSON.stringify(pB)} B.pcmRecv=${pcmB} errA=${A.errors.length} errB=${B.errors.length}`;
  } else {
    const pA = await A.page.evaluate(() => window.__tape?.pcm?.presence ?? null);
    const pcmB = await B.page.evaluate(() => window.__tape?.pcm?.framesRecv ?? 0);
    const noErrors = A.errors.length === 0 && B.errors.length === 0;
    ok = pA === null && noErrors && pcmB > 100;
    detail = `presence=${JSON.stringify(pA)} B.pcmRecv=${pcmB} errA=${A.errors.length} errB=${B.errors.length}`;
  }

  console.log(`arm=${mode}: ${detail} -> ${ok ? 'OK' : 'FAIL'}`);
  if (!ok && (A.errors.length || B.errors.length)) {
    if (A.errors.length) console.log('  pageerrors A:', A.errors);
    if (B.errors.length) console.log('  pageerrors B:', B.errors);
  }

  await A.browser.close();
  await B.browser.close();
  return ok;
}

const okOn = await runArm('on');
const okOff = await runArm('off');
console.log(`\nverdict: on ${okOn ? 'OK' : 'FAIL'}, off ${okOff ? 'OK' : 'FAIL'}`);
process.exit(okOn && okOff ? 0 : 1);
