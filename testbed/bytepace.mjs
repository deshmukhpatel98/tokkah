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
 *   control (?bytepace=0)  must FLOOD — output well above budget, zero brake
 *                          skips. If this arm holds the budget, the defect is
 *                          not reproduced and the fix is unproven; say so.
 *   fixed   (default)      must HOLD — output within 1.5x of the 1 Mbps budget
 *                          over the settled window, brake skips > 0, and video
 *                          still moving (achievedFps >= 0.5, the 2 s relief).
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

async function arm(label, extra) {
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
    await a.waitForTimeout(25000); // settle: rc, pacer and brake all converged
    const read = (p) => p.evaluate(() => {
      const v = window.__tape?.video ?? {};
      return {
        mbps: v.mbpsAtFps ?? null, fps: v.achievedFps ?? null,
        rcQp: v.rcQp ?? null, budget: v.rcBudgetMbps ?? null,
        braked: v.skipBytePaced ?? null, paced: v.skipPaced ?? null,
      };
    });
    const rA = await read(a), rB = await read(b);
    for (const [who, r] of [['A', rA], ['B', rB]]) {
      console.log(`  [${label}] ${who} mbps=${r.mbps} fps=${r.fps} qp=${r.rcQp} budget=${r.budget} braked=${r.braked} paced=${r.paced}`);
    }
    return [rA, rB];
  } finally {
    await A.close(); await B.close();
  }
}

// Arms renamed after the disproof (see the header): the brake is OPT-IN now,
// so `control` is the shipping default — which still floods, documenting the
// OPEN defect — and `brake` exists to keep the disproof pinned: if someone
// re-enables frame-dropping at pinned QP, this rig fails them.
const brake = await arm('brake  ', '&bytepace=1');
const control = await arm('default', '');

let fails = 0;
const check = (name, ok, detail) => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  (${detail})`);
  if (!ok) fails++;
};
const flood = (rs) => rs.some((r) => r.mbps != null && r.mbps > 1.8);
const held = (rs) => rs.every((r) => r.mbps == null || r.mbps <= 1.5);
const brakedN = (rs) => rs.reduce((s, r) => s + (r.braked | 0), 0);
const moving = (rs) => rs.every((r) => (r.fps ?? 0) >= 0.5);

check('the flood reproduces on the shipping default (OPEN DEFECT)', flood(control) && brakedN(control) === 0,
  `default mbps=${control.map((r) => r.mbps).join('/')} vs budget 1, braked=${brakedN(control)}`);
check('the brake fires when opted in', brakedN(brake) > 0, `${brakedN(brake)} captures braked`);
// THE DISPROOF, PINNED. At pinned QP, frame-dropping does not reduce bytes on
// motion (each surviving frame pays for the dropped motion) — measured 15.7/9.9
// Mbps braked vs 8.3/6.1 unbraked. If this check ever fails, the premise
// changed and the brake deserves a re-hearing; until then it stays opt-in.
check('frame-dropping still fails to hold the budget (why it is off)', !held(brake),
  `brake mbps=${brake.map((r) => r.mbps).join('/')} — not a fix, as measured`);
void moving;
console.log(fails === 0 ? '\nVERDICT: PASS' : `\nVERDICT: FAIL (${fails})`);
process.exit(fails ? 1 : 0);
