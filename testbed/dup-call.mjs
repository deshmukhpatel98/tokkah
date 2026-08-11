#!/usr/bin/env node
/**
 * Burst-shield live-call test — real browsers in a real production call.
 *
 * Arms:
 *   force — both pages ?pcmdup=1: shield engaged from frame one; sender's
 *           dupSent grows, twins ride a different stripe, RECEIVER's dupRecv
 *           counts them as redundant arrivals (loopback loses nothing), and
 *           the lane stays clean (audio flows, no page errors).
 *   auto  — no flag: on a clean live path the loss reads stay at 0, so the
 *           shield must stay DISENGAGED (dupOn 0, dupSent 0) — proves the
 *           default arm costs nothing when the network is fine.
 *   off   — ?pcmdup=0: counters all zero, byte-identical posture.
 *
 *   node testbed/dup-call.mjs [--url=https://room.tokkah.com]
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
  const q = mode === 'force' ? '&pcmdup=1' : mode === 'off' ? '&pcmdup=0' : '';
  const ROOM = `dup-${mode}-${Date.now().toString(36)}`;
  const A = await launch();
  const B = await launch();
  for (const S of [A, B]) {
    await S.page.goto(`${URL_BASE}/?r=${ROOM}${q}`);
    await S.page.click('#join');
  }
  await A.page.waitForFunction(() => (window.__tape?.pcm?.framesSent ?? 0) > 100, null, { timeout: 30000 });
  // Let both directions run long enough for twins and their counters.
  await A.page.waitForTimeout(8000);

  const sA = await A.page.evaluate(() => {
    const p = window.__tape?.pcm ?? {};
    return { dupOn: p.dupOn, dupSent: p.dupSent, dupBytes: p.dupBytes, dupRecv: p.dupRecv, dupSkipped: p.dupSkipped, framesSent: p.framesSent, conceal: p.concealedMs };
  });
  const sB = await B.page.evaluate(() => {
    const p = window.__tape?.pcm ?? {};
    return { dupOn: p.dupOn, dupSent: p.dupSent, dupRecv: p.dupRecv, framesRecv: p.framesRecv, conceal: p.concealedMs };
  });
  const noErrors = A.errors.length === 0 && B.errors.length === 0;

  let ok;
  if (mode === 'force') {
    // Twins flow A→B and B→A; loopback loses nothing so B's dupRecv should
    // track A's dupSent closely (small in-flight tail allowed).
    ok = noErrors && sA.dupOn === 1 && sA.dupSent > 200 && sB.framesRecv > 200
      && sB.dupRecv > sA.dupSent * 0.8 && sB.conceal === 0;
  } else {
    ok = noErrors && sA.dupOn === 0 && sA.dupSent === 0 && sB.dupRecv === 0
      && sB.framesRecv > 200;
  }
  console.log(`arm=${mode}: A=${JSON.stringify(sA)} B=${JSON.stringify(sB)} errA=${A.errors.length} errB=${B.errors.length} -> ${ok ? 'OK' : 'FAIL'}`);
  if (!ok && (A.errors.length || B.errors.length)) {
    if (A.errors.length) console.log('  pageerrors A:', A.errors);
    if (B.errors.length) console.log('  pageerrors B:', B.errors);
  }
  await A.browser.close();
  await B.browser.close();
  return ok;
}

const okF = await runArm('force');
const okA = await runArm('auto');
const okO = await runArm('off');
console.log(`\nverdict: force ${okF ? 'OK' : 'FAIL'}, auto ${okA ? 'OK' : 'FAIL'}, off ${okO ? 'OK' : 'FAIL'}`);
process.exit(okF && okA && okO ? 0 : 1);
