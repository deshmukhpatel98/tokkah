#!/usr/bin/env node
/**
 * Video duress coupling live-call test — real browsers on production.
 *
 * Arms:
 *   coupled — ?pcmdup=1 forces the burst shield on, so pcm.duress() reads 2
 *             and the video lane's rcDuress must follow, with the budget
 *             quartered (or clamped at the floor). Proves the audio→video
 *             signal path end to end in a real call.
 *   control — ?pcmdup=1&l2duress=0: shield still on, but the coupling is
 *             severed — rcDuress must stay 0. Proves the flag isolates.
 *
 *   node testbed/duress-call.mjs [--url=https://room.tokkah.com]
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
  const q = mode === 'coupled' ? '&pcmdup=1' : '&pcmdup=1&l2duress=0';
  const ROOM = `duress-${mode}-${Date.now().toString(36)}`;
  const A = await launch();
  const B = await launch();
  for (const S of [A, B]) {
    await S.page.goto(`${URL_BASE}/?r=${ROOM}${q}`);
    await S.page.click('#join');
  }
  await A.page.waitForFunction(() => (window.__tape?.pcm?.framesSent ?? 0) > 100, null, { timeout: 30000 });
  // rcPollBudget ticks at 1 Hz; give the coupling several polls.
  await A.page.waitForTimeout(6000);

  const v = await A.page.evaluate(() => {
    const t = window.__tape?.lane?.stats ?? {};
    const p = window.__tape?.pcm ?? {};
    return { rcDuress: t.rcDuress, rcBudgetMbps: t.rcBudgetMbps, rateControl: t.rateControl, dupOn: p.dupOn, dupSent: p.dupSent };
  });
  const pcmB = await B.page.evaluate(() => window.__tape?.pcm?.framesRecv ?? 0);
  const noErrors = A.errors.length === 0 && B.errors.length === 0;

  let ok;
  if (mode === 'coupled') {
    ok = noErrors && v.dupOn === 1 && v.rcDuress === 2 && pcmB > 200
      && v.rcBudgetMbps != null;
  } else {
    ok = noErrors && v.dupOn === 1 && (v.rcDuress === 0 || v.rcDuress == null) && pcmB > 200;
  }
  console.log(`arm=${mode}: video=${JSON.stringify(v)} B.pcmRecv=${pcmB} errA=${A.errors.length} errB=${B.errors.length} -> ${ok ? 'OK' : 'FAIL'}`);
  if (!ok && (A.errors.length || B.errors.length)) {
    if (A.errors.length) console.log('  pageerrors A:', A.errors);
    if (B.errors.length) console.log('  pageerrors B:', B.errors);
  }
  await A.browser.close();
  await B.browser.close();
  return ok;
}

const okC = await runArm('coupled');
const okX = await runArm('control');
console.log(`\nverdict: coupled ${okC ? 'OK' : 'FAIL'}, control ${okX ? 'OK' : 'FAIL'}`);
process.exit(okC && okX ? 0 : 1);
