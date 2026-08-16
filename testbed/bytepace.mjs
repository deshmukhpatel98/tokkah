/**
 * bytepace.mjs — when the QP lever runs out, does anything actually drop frames?
 *
 * Reproduces the Sunday-morning defect on demand: pin the QP band to a single
 * value (l2rcqpmin=l2rcqpmax=16 — "pinned" from the first frame, and QP 16 makes real motion cost several Mbps so the 1 Mbps budget is genuinely exceeded; the first version pinned at 30, which this content sails under — the rig failed its own control arm and said so)
 * and clamp the budget band to 1 Mbps (l2rcmin=l2rcmax=1) while feeding 1080p
 * real motion, which costs several Mbps at QP 30. The encoder is now over
 * budget with no QP room, which is exactly the dark-room phone's state.
 *
 * Arms:
 *   res   (default)        the shipping fix: when QP pins and bytes stay over
 *                          budget, the encoder SHRINKS RESOLUTION (÷2 then ÷4).
 *                          Quarter pixels ≈ quarter bytes at fixed QP, cadence
 *                          untouched. Must HOLD the budget within 1.5x AND keep
 *                          fps >= 20 — the whole point over frame-dropping.
 *   nores (&rcres=0)       actuator off: must FLOOD. If this arm holds the
 *                          budget, the defect is not reproduced and the fix is
 *                          unproven; say so.
 *   brake (&bytepace=1&rcres=0)  the frame-drop disproof, kept pinned.
 *
 *   node testbed/bytepace.mjs
 */
import { chromium } from 'playwright-core';

const URL_BASE = process.env.URL ?? 'https://room.tokkah.com';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);

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

const QS = 'l2rcqpmin=16&l2rcqpmax=16&l2rcmin=1&l2rcmax=1';

async function arm(label, extra, settleMs = 25000) {
  const room = `bp-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 5)}`;
  const A = await launch('A'), B = await launch('B');
  try {
    const a = await A.newPage(), b = await B.newPage();
    for (const [p, who] of [[a, 'A'], [b, 'B']]) {
      await p.goto(`${URL_BASE}/?r=${room}&${QS}${extra}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
      await p.waitForSelector('#join', { timeout: 20000 });
      await p.click('#join').catch(() => {});
      if (who === 'A') await p.waitForTimeout(1200);
    }
    for (const p of [a, b]) {
      await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });
    }
    await a.waitForTimeout(settleMs); // settle: rc, pacer and any actuator converged
    const read = (p) => p.evaluate(() => {
      const v = window.__tape?.video ?? {};
      return {
        mbps: v.mbpsAtFps ?? null, fps: v.achievedFps ?? null,
        rcQp: v.rcQp ?? null, budget: v.rcBudgetMbps ?? null,
        braked: v.skipBytePaced ?? null, paced: v.skipPaced ?? null,
        shrink: v.rcResShrink ?? null, w: v.w ?? null, h: v.h ?? null,
      };
    });
    const rA = await read(a), rB = await read(b);
    for (const [who, r] of [['A', rA], ['B', rB]]) {
      console.log(`  [${label}] ${who} mbps=${r.mbps} fps=${r.fps} qp=${r.rcQp} budget=${r.budget} braked=${r.braked} shrink=${r.shrink} ${r.w}x${r.h}`);
    }
    return [rA, rB];
  } finally {
    await A.close(); await B.close();
  }
}

// Three arms since the resolution actuator shipped (default ON): `res` is the
// shipping default and must hold the budget WITHOUT giving up frame rate;
// `nores` reproduces the open defect the actuator exists for; `brake` keeps the
// frame-dropping disproof pinned — if someone re-enables it at pinned QP, this
// rig fails them. `res` gets a longer settle: two demote steps take 2 s of
// pinned-and-over each, plus a resize/keyframe and a bitrate window per step.
const res = await arm('res    ', '', 45000);
const nores = await arm('nores  ', '&rcres=0');
const brake = await arm('brake  ', '&bytepace=1&rcres=0');

let fails = 0;
const check = (name, ok, detail) => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  (${detail})`);
  if (!ok) fails++;
};
const flood = (rs) => rs.some((r) => r.mbps != null && r.mbps > 1.8);
const held = (rs) => rs.every((r) => r.mbps == null || r.mbps <= 1.5);
const brakedN = (rs) => rs.reduce((s, r) => s + (r.braked | 0), 0);
const fpsOk = (rs) => rs.every((r) => (r.fps ?? 0) >= 20);
const shrunk = (rs) => rs.some((r) => (r.shrink ?? 1) > 1);

check('the flood reproduces with the actuator off (the defect)', flood(nores),
  `nores mbps=${nores.map((r) => r.mbps).join('/')} vs budget 1`);
check('the actuator engages (shrink > 1)', shrunk(res),
  `res shrink=${res.map((r) => r.shrink).join('/')} size=${res.map((r) => `${r.w}x${r.h}`).join('/')}`);
check('resolution holds the budget', held(res),
  `res mbps=${res.map((r) => r.mbps).join('/')} vs budget 1 (allow 1.5x)`);
check('and keeps the video MOVING (fps >= 20) — the point over frame-dropping', fpsOk(res),
  `res fps=${res.map((r) => r.fps).join('/')}`);
check('the brake fires when opted in', brakedN(brake) > 0, `${brakedN(brake)} captures braked`);
// THE DISPROOF, PINNED. At pinned QP, frame-dropping does not reduce bytes on
// motion (each surviving frame pays for the dropped motion) — measured 15.7/9.9
// Mbps braked vs 8.3/6.1 unbraked. If this check ever fails, the premise
// changed and the brake deserves a re-hearing; until then it stays opt-in.
check('frame-dropping still fails to hold the budget (why it is off)', !held(brake),
  `brake mbps=${brake.map((r) => r.mbps).join('/')} — not a fix, as measured`);
console.log(fails === 0 ? '\nVERDICT: PASS' : `\nVERDICT: FAIL (${fails})`);
process.exit(fails ? 1 : 0);
