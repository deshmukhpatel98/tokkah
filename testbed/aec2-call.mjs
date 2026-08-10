#!/usr/bin/env node
/**
 * AEC2 end-to-end test.
 *
 * Arms:
 *   on  — both pages ?aec2=1: AEC2 DSP core active in capture worklet.
 *   off — no flag: AEC2 disabled, stats().aec2 is null/undefined.
 *
 *   node testbed/aec2-call.mjs [--url=http://127.0.0.1:8794]
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

async function runArm(mode) {
  const q = mode === 'on' ? '&aec2=1' : '';
  const ROOM = `aec2-${mode}-${Date.now().toString(36)}`;
  const A = await launch();
  const B = await launch();
  for (const S of [A, B]) {
    await S.page.goto(`${URL_BASE}/?r=${ROOM}${q}`);
    await S.page.click('#join');
  }
  await A.page.waitForFunction(() => (window.__tape?.pcm?.framesSent ?? 0) > 100, null, { timeout: 30000 });

  let ok = false, detail = '';
  if (mode === 'on') {
    const gotStats = await A.page
      .waitForFunction(() => window.__tape?.pcm?.aec2 != null, null, { timeout: 20000 })
      .then(() => true, () => false);
    const aec2Stats = gotStats ? await A.page.evaluate(() => window.__tape?.pcm?.aec2) : null;
    const pcmB = await B.page.evaluate(() => window.__tape?.pcm?.framesRecv ?? 0);
    const noErrors = A.errors.length === 0 && B.errors.length === 0;
    const validDelay = aec2Stats?.delayBlocks != null && aec2Stats.delayBlocks >= 0;
    const validErle = aec2Stats != null && (aec2Stats.erleDb === null || aec2Stats.erleDb > -5);
    ok = gotStats && noErrors && pcmB > 100 && validDelay && validErle;
    detail = `aec2=${JSON.stringify(aec2Stats)} B.pcmRecv=${pcmB} errA=${A.errors.length} errB=${B.errors.length}`;
  } else {
    const aec2Stats = await A.page.evaluate(() => window.__tape?.pcm?.aec2);
    const pcmB = await B.page.evaluate(() => window.__tape?.pcm?.framesRecv ?? 0);
    const noErrors = A.errors.length === 0 && B.errors.length === 0;
    const isNull = aec2Stats == null;
    ok = isNull && noErrors && pcmB > 100;
    detail = `aec2=${JSON.stringify(aec2Stats)} B.pcmRecv=${pcmB} errA=${A.errors.length} errB=${B.errors.length}`;
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
