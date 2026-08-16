/**
 * camdeath.mjs — when the camera hard-dies mid-call, does the call get it back?
 *
 * The ilx-swig-xox call (2026-08-16): Android's "Source failed to restart" left
 * a track with readyState 'ended', and reviveEval's live-track guard meant
 * nothing ever retried — dead video for the rest of the call. The fix: an
 * ended-track path (4 s persistence so camera flips don't race their own
 * getUserMedia) that re-acquires with exponential backoff, so a camera the OS
 * still holds is asked again instead of abandoned.
 *
 * STIMULUS: __tape.killCam() stops the live track (readyState 'ended', user
 * toggle untouched) — the same end state the Android HAL leaves. The first
 * 12 s of re-acquire attempts are made to FAIL by patching getUserMedia to
 * throw NotReadableError, which is the OS-holds-the-camera case; the patch
 * then lifts, and recovery must come through the backoff retry, not luck.
 *
 * Arms:
 *   fixed  (default)     A's camera returns (srcprobe live again, frames
 *                        advancing; B sees fps again) AND A's AUDIO never
 *                        stopped flowing to B during the whole outage.
 *   control (&revive=0)  the defect: track stays 'ended' forever. If THIS arm
 *                        recovers, something else healed it and the fix is
 *                        unproven; say so.
 *
 *   node testbed/camdeath.mjs
 */
import { chromium } from 'playwright-core';

const BASE = process.env.URL ?? 'https://room.tokkah.com';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);

const HOLD_MS = 12000;   // how long getUserMedia refuses (the OS holding the camera)
const WATCH_S = 40;      // outage + backoff retries + adoption all inside this

const launch = (side) => chromium.launch({
  executablePath: CHROME, headless: true,
  args: [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    `--use-file-for-fake-video-capture=${media(`real${side}.mjpeg`)}`,
    `--use-file-for-fake-audio-capture=${media(`real${side}.wav`)}`,
    '--autoplay-policy=no-user-gesture-required',
    '--disable-features=WebRtcHideLocalIpsWithMdns',
  ],
});

async function arm(label, extra) {
  const room = `cd-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 5)}`;
  const A = await launch('A'), B = await launch('B');
  try {
    const a = await A.newPage(), b = await B.newPage();
    for (const [p, who] of [[a, 'A'], [b, 'B']]) {
      await p.goto(`${BASE}/?r=${room}${extra}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
      await p.waitForSelector('#join', { timeout: 20000 });
      await p.click('#join').catch(() => {});
      if (who === 'A') await p.waitForTimeout(1200);
    }
    for (const p of [a, b]) {
      await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });
    }
    await a.waitForTimeout(15000); // settle past the stepper warmup

    // ── the stimulus: OS holds the camera, then the track dies ───────────────
    const killed = await a.evaluate((holdMs) => {
      const real = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
      let held = true;
      setTimeout(() => { held = false; }, holdMs);
      window.__gumAsks = 0;
      navigator.mediaDevices.getUserMedia = (c) => {
        window.__gumAsks++;
        if (held && c?.video) {
          const e = new DOMException('Could not start video source', 'NotReadableError');
          return Promise.reject(e);
        }
        return real(c);
      };
      return window.__tape.killCam();
    }, HOLD_MS);
    if (killed !== 'ended') throw new Error(`${label}: killCam returned ${killed} — stimulus did not land`);

    // Audio continuity is sampled DURING the outage, not inferred at the end:
    // B's frames-received from A must keep advancing at ~125/s throughout.
    const audioSamples = [];
    const bRecv = () => b.evaluate(() => window.__tape?.pcm?.framesRecv ?? null);
    let last = await bRecv();
    const t0 = Date.now();
    while (Date.now() - t0 < WATCH_S * 1000) {
      await b.waitForTimeout(4000);
      const cur = await bRecv();
      if (last != null && cur != null) audioSamples.push((cur - last) / 4); // frames/s
      last = cur;
    }

    const aEnd = await a.evaluate(() => ({
      ready: window.__tape?.srcprobe?.readyState ?? null,
      frames: window.__tape?.srcprobe?.frames ?? null,
      gumAsks: window.__gumAsks ?? 0,
    }));
    await a.waitForTimeout(4000);
    const aEnd2 = await a.evaluate(() => window.__tape?.srcprobe?.frames ?? null);
    const camFlowing = aEnd.ready === 'live' && aEnd2 != null && aEnd.frames != null && aEnd2 > aEnd.frames;
    const audioMin = audioSamples.length ? Math.min(...audioSamples) : null;
    const r = { camFlowing, ready: aEnd.ready, gumAsks: aEnd.gumAsks, audioMin, n: audioSamples.length };
    console.log(`  [${label}] cam ${camFlowing ? 'RECOVERED' : 'dead'} (readyState=${aEnd.ready}, ` +
      `${aEnd.gumAsks} getUserMedia asks)  audio min ${audioMin?.toFixed(1)} frames/s over ${r.n} samples`);
    return r;
  } finally {
    await A.close(); await B.close();
  }
}

const fixed = await arm('fixed  ', '');
const control = await arm('control', '&revive=0');

let fails = 0;
const check = (name, ok, detail) => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  (${detail})`);
  if (!ok) fails++;
};
check('a dead camera stays dead without the fix (the defect)', !control.camFlowing,
  `control readyState=${control.ready}, ${control.gumAsks} asks`);
check('the fix retries through the held-camera window', fixed.gumAsks >= 2,
  `${fixed.gumAsks} getUserMedia asks (first ones refused for ${HOLD_MS / 1000}s)`);
check('and the camera comes BACK, frames flowing', fixed.camFlowing,
  `readyState=${fixed.ready}`);
check('audio never stopped during the whole outage (>=100 frames/s at worst)',
  fixed.audioMin != null && fixed.audioMin >= 100,
  `min ${fixed.audioMin?.toFixed(1)} frames/s across ${fixed.n} four-second windows`);
console.log(fails === 0 ? '\nVERDICT: PASS' : `\nVERDICT: FAIL (${fails})`);
process.exit(fails ? 1 : 0);
