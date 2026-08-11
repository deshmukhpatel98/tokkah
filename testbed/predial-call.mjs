#!/usr/bin/env node
/**
 * WS pre-dial live A/B — real browsers on production, N calls per arm.
 *
 * Each call: both pages load the lobby with the room in the URL (so the
 * pre-dial fires at load, as it does for a real deep-link join), DWELL in
 * the lobby like a human would, then click. Measured: click → ws welcome
 * (the slice pre-dial attacks) and click → pc connected, per side, via the
 * page's own telemetry timeline.
 *
 *   node testbed/predial-call.mjs [--url=https://room.tokkah.com] [--n=5]
 */
import { chromium } from 'playwright-core';

const KNOWN = new Set(['url', 'n', 'headed']);
const args = {};
for (const a of process.argv.slice(2)) {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/);
  if (!m || !KNOWN.has(m[1])) { console.error(`unknown flag: ${a}`); process.exit(2); }
  args[m[1]] = m[2] ?? '1';
}
const URL_BASE = args.url ?? 'https://room.tokkah.com';
const N = Number(args.n ?? 5);
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

async function oneCall(mode) {
  const q = mode === 'predial' ? '' : '&predial=0';
  const ROOM = `pd-${mode}-${Date.now().toString(36)}`;
  const A = await launch();
  const B = await launch();
  try {
    for (const S of [A, B]) await S.page.goto(`${URL_BASE}/?r=${ROOM}${q}`);
    // Human-shaped lobby dwell: long enough for pre-dial + DO warm to land.
    await A.page.waitForTimeout(2500);
    const t = async (S) => {
      await S.page.evaluate(() => { window.__pdClick = performance.now(); });
      await S.page.click('#join');
    };
    await t(A);
    await t(B);
    for (const S of [A, B]) {
      await S.page.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 30000 });
    }
    const read = (S) => S.page.evaluate(() => {
      const conn = performance.now();
      return { clickToConn: +(conn - window.__pdClick).toFixed(0) };
    });
    const a = await read(A);
    const b = await read(B);
    const errs = A.errors.length + B.errors.length;
    return { a: a.clickToConn, b: b.clickToConn, errs };
  } finally {
    await A.browser.close().catch(() => {});
    await B.browser.close().catch(() => {});
  }
}

const med = (arr) => { const s = [...arr].sort((x, y) => x - y); return s[Math.floor(s.length / 2)]; };

for (const mode of ['predial', 'control']) {
  const bs = [];
  let errs = 0;
  for (let i = 0; i < N; i++) {
    const r = await oneCall(mode);
    bs.push(r.b); // B joins second — the user-felt path
    errs += r.errs;
    console.log(`  ${mode} run ${i + 1}: B click->connected ${r.b} ms (A ${r.a})${r.errs ? `  pageerrors ${r.errs}` : ''}`);
  }
  console.log(`arm=${mode}: B median ${med(bs)} ms over ${N} runs, pageerrors ${errs}`);
}
