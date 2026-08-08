#!/usr/bin/env node
/**
 * Camera-flip failure regression (room rni-kqta-qak, 2026-08-08): an Android
 * HAL refuses to open the second camera while the first is live, AND keeps
 * refusing for hundreds of ms after the first one is stopped (the release is
 * asynchronous). The shipped fallback used to retry exactly once, immediately,
 * so it failed too — and the call was left with its only video track removed
 * and stopped: frozen both ways until a manual refresh.
 *
 * Two arms, both driven through the shipped __tape.switchCam path with
 * getUserMedia shadowed to throw NotReadableError for video asks:
 *   transient — refuses for 1.2 s after the last refusal, then works: the
 *               backoff must land the flip.
 *   permanent — refuses the NEW device forever, allows the OLD one back:
 *               the restore path must leave a live video track.
 *
 * Verdict requires, per arm: no pageerror, localStream has exactly one video
 * track, that track is live, and Lane A audio kept flowing on both sides.
 *
 *   node testbed/flipfail-call.mjs [--url=http://127.0.0.1:8794]
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
  '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';

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
  const ROOM = `ff-${mode}-${Date.now().toString(36)}`;
  const A = await launch();
  const B = await launch();
  for (const S of [A, B]) {
    await S.page.goto(`${URL_BASE}/?r=${ROOM}`);
    await S.page.click('#join');
  }
  await A.page.waitForFunction(() => (window.__tape?.pcm?.framesSent ?? 0) > 100, null, { timeout: 30000 });

  // Shadow getUserMedia on A the way the M13's HAL behaves. The shadow decides
  // per CALL: video asks for the "new" device refuse per the arm; everything
  // else passes through.
  await A.page.evaluate((mode) => {
    const real = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
    const oldId = document.getElementById("selfFull").srcObject?.getVideoTracks?.()[0]?.getSettings?.().deviceId ?? null;
    window.__ffLog = [];
    let lastRefusalAt = 0;
    navigator.mediaDevices.getUserMedia = async (c) => {
      if (!c?.video) return real(c);
      const asked = c.video?.deviceId?.exact ?? null;
      const now = performance.now();
      const isOld = asked !== null && asked === oldId;
      const refuse =
        mode === 'permanent' ? !isOld
        : (now - lastRefusalAt < 1200 || lastRefusalAt === 0); // transient: refuse until 1.2 s of quiet
      window.__ffLog.push({ t: Math.round(now), asked: asked === oldId ? 'old' : 'new', refuse });
      if (refuse) {
        lastRefusalAt = now;
        const e = new DOMException('Could not start video source', 'NotReadableError');
        throw e;
      }
      return real(c);
    };
  }, mode);

  // Flip to "another camera". Fake-device browsers have one camera, so pass a
  // made-up device id — exactly what makes the shadow's new-device arm fire.
  const flipErr = await A.page.evaluate(async () => {
    try { await window.__tape.switchCam('imaginary-back-camera-id'); return null; } catch (e) { return String(e?.message ?? e); }
  });

  await A.page.waitForTimeout(1000);
  const state = await A.page.evaluate(() => {
    const vts = document.getElementById("selfFull").srcObject?.getVideoTracks?.() ?? [];
    return {
      videoTracks: vts.length,
      live: vts[0]?.readyState === 'live',
      gumCalls: window.__ffLog,
    };
  });
  const pcmB = await B.page.evaluate(() => window.__tape?.pcm?.framesRecv ?? 0);
  await A.browser.close();
  await B.browser.close();

  const ok = state.videoTracks === 1 && state.live && A.errors.length === 0 && pcmB > 100;
  console.log(`arm=${mode}: tracks=${state.videoTracks} live=${state.live} pageerrors=${A.errors.length} flipErr=${JSON.stringify(flipErr)} gumAsks=${state.gumCalls.length} B.pcmRecv=${pcmB} -> ${ok ? 'OK' : 'FAIL'}`);
  if (!ok) { console.log('  gum log:', JSON.stringify(state.gumCalls)); console.log('  pageerrors:', A.errors); }
  return ok;
}

const okT = await runArm('transient');
const okP = await runArm('permanent');
console.log(`\nverdict: transient ${okT ? 'OK' : 'FAIL'}, permanent ${okP ? 'OK' : 'FAIL'}`);
process.exit(okT && okP ? 0 : 1);
