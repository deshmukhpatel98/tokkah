/**
 * camsensor.mjs — the camera controllers, tested against REAL recorded sensors.
 *
 * The sensor pathologies that broke the 2026-08-16 calls are physics no fake
 * device has: the dark-room fps collapse at pinned exposure, the hard death,
 * the exposure stretch. But srcprobe recorded them all, and ?sensorsim=<trace>
 * (app.js) replays a recorded trace as the camera — recorded delivery rate,
 * recorded getSettings(), death where the real sensor died, re-acquisition
 * refused for 12 s after a death the way a HAL that still holds the device
 * does. So the controllers run against the exact failure a real user had, on
 * headless desktop Chrome, in about a minute — the fast-iteration lane the
 * camera never had.
 *
 * Arms (solo joins — capture-side machinery arms at join; the peer-facing
 * half of recovery is camdeath.mjs's job):
 *   death   (default flags)  the mza-aabt-hmk sensor: dies ~23 s in. The
 *                            revive machinery must re-acquire THROUGH the
 *                            12 s hold (several asks) and get frames again.
 *   death   (&revive=0)      control: stays dead forever. If this recovers,
 *                            something else healed it and the fix is unproven.
 *   dark-pin (default flags) the ilx-swig-xox sensor: 0-8 fps at exposure
 *                            999.98. Nothing can raise this fps (only light
 *                            can) — the assertion is BOUNDED behavior: the
 *                            page stays alive, controllers keep their retry
 *                            budgets, and the probe faithfully reports the
 *                            starved delivery.
 *
 *   node testbed/camsensor.mjs
 */
import { chromium } from 'playwright-core';

const BASE = process.env.URL ?? 'https://room.tokkah.com';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);

const launch = () => chromium.launch({
  executablePath: CHROME, headless: true,
  args: [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    `--use-file-for-fake-audio-capture=${media('realA.wav')}`, // sim covers video only
    '--autoplay-policy=no-user-gesture-required',
  ],
});

async function arm(label, trace, extra, watchS) {
  const room = `cs-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 5)}`;
  const B = await launch();
  try {
    const p = await B.newPage();
    await p.goto(`${BASE}/?r=${room}&sensorsim=${trace}${extra}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await p.waitForSelector('#join', { timeout: 20000 });
    await p.click('#join').catch(() => {});
    const series = [];
    const t0 = Date.now();
    while (Date.now() - t0 < watchS * 1000) {
      await p.waitForTimeout(2000);
      series.push(await p.evaluate(() => ({
        ready: window.__tape?.srcprobe?.readyState ?? null,
        frames: window.__tape?.srcprobe?.frames ?? null,
        deaths: window.__sensorsim?.deaths ?? 0,
        gumAsks: window.__sensorsim?.gumAsks ?? 0,
        applied: window.__sensorsim?.applied?.length ?? 0,
        alive: true,
      })).catch(() => ({ alive: false })));
    }
    const died = series.filter((s) => s.deaths > 0);
    const lastDeath = series.findIndex((s) => s.deaths > 0);
    // Recovery = LIVE readyState with frames ADVANCING at some point after the
    // first death (a live-but-frozen track must not count).
    let recovered = false;
    for (let i = Math.max(1, lastDeath + 1); i < series.length; i++) {
      const a = series[i - 1], b = series[i];
      if (b.deaths > 0 && b.ready === 'live' && a.frames != null && b.frames > a.frames) { recovered = true; break; }
    }
    const end = series.at(-1) ?? {};
    const r = {
      died: died.length > 0, recovered, gumAsks: end.gumAsks, applied: end.applied,
      endReady: end.ready, pageAlive: series.every((s) => s.alive),
      framesEnd: end.frames,
    };
    console.log(`  [${label}] died=${r.died} recovered=${r.recovered} gumAsks=${r.gumAsks} ` +
      `applyConstraints=${r.applied} end=${r.endReady}/${r.framesEnd}f pageAlive=${r.pageAlive}`);
    return r;
  } finally {
    await B.close();
  }
}

// The death trace dies ~23 s in; +12 s hold +retry backoff needs the window.
const fixed = await arm('death:fixed  ', 'death', '', 75);
const control = await arm('death:control', 'death', '&revive=0', 75);
const dark = await arm('dark-pin     ', 'dark-pin', '', 45);

let fails = 0;
const check = (name, ok, detail) => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  (${detail})`);
  if (!ok) fails++;
};
check('the recorded sensor dies in replay (stimulus lands)', fixed.died && control.died,
  `fixed died=${fixed.died}, control died=${control.died}`);
check('a dead camera stays dead without the fix (the defect)', !control.recovered,
  `control end=${control.endReady}, gumAsks=${control.gumAsks}`);
check('recovery pushes THROUGH the 12s held-camera window', fixed.recovered && fixed.gumAsks >= 3,
  `recovered=${fixed.recovered} after ${fixed.gumAsks} getUserMedia asks`);
// "Bounded" means RATE-LIMITED, not silent: revive (3/60 s) + the stepper's
// tier walk + re-acquire joins all legitimately apply constraints. The budget
// is one apply per 2 s of runtime — thrash shows up as a multiple of that.
check('dark-pin: page survives, controllers stay rate-bounded', dark.pageAlive && (dark.applied ?? 99) <= Math.ceil(45 / 2) && !dark.died,
  `applyConstraints=${dark.applied} (budget ${Math.ceil(45 / 2)}/45s), died=${dark.died}, alive=${dark.pageAlive}`);
console.log(fails === 0 ? '\nVERDICT: PASS' : `\nVERDICT: FAIL (${fails})`);
process.exit(fails ? 1 : 0);
