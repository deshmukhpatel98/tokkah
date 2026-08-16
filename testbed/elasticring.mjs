/**
 * elasticring.mjs — does the jitter ceiling actually stretch when the clamp is
 * provably costing audio, and does stretching actually stop the concealment?
 *
 * Born from a real call (tcu-eopa-dop, 2026-08-16): a bursty 28 ms-RTT path put
 * 53%/33% of frames behind the playhead while half the 512 ms ring sat empty
 * above the 256 ms maxTargetFrames clamp. The estimator asked, the ceiling
 * refused, the user heard "connection paused".
 *
 * STIMULUS (proven by onehole.mjs): a main-thread busy-wait on the receiver
 * stops arrival timestamping, then the datachannel backlog lands in a clump —
 * the measured signature of the real stalls. Holes here are 320 ms, RECURRING
 * every 3 s: bigger than the 256 ms configured ceiling (so the control arm
 * MUST conceal every one) and smaller than the 384 ms elastic maximum (so the
 * stretched arm CAN cover them). Stimulus is confirmed from the receiver's own
 * stall list; a run whose blocks didn't interrupt timestamping is VOID.
 *
 * Arms (sequential, same host — the holes are injected, not host noise, and
 * each arm confirms its own stimulus landed):
 *   elastic (default)      elUps > 0, ceiling > 32, and concealment during the
 *                          hole regime well below the control's.
 *   control (&pcmelastic=0) ceiling pinned at 32 and concealment accumulates —
 *                          the defect reproduced. If THIS arm doesn't conceal,
 *                          the holes were too small and the fix is unproven.
 *
 *   node testbed/elasticring.mjs
 */
import { chromium } from 'playwright-core';
import os from 'node:os';

const BASE = process.env.URL ?? 'https://room.tokkah.com';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);

const HOLE_MS = 320;      // > 256 ms configured cap, < 384 ms elastic max
const HOLES = 20;         // recurring regime, ~60 s of it
const GAP_S = 3;
const SETTLE_S = 25;
// The verdict reads the SECOND HALF only. The first holes are the EVIDENCE the
// controller needs before it may stretch (pain-gated by design), so counting
// them against it would demand the fix act before its own trigger. First run
// of this rig also proved the ceiling alone is not the fix: the target rose
// 32->48f and concealment was IDENTICAL (963 = 963), because depth toward the
// raise could only build at the 0.2% clock-tracking bound (~170 s for 128 ms).
// The build-side widening (?pcmbuild) is the other half; both are under test.
const HALF = Math.floor(HOLES / 2);

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

const block = (p, ms) => p.evaluate((dur) => {
  const t0 = performance.now();
  while (performance.now() - t0 < dur) { /* deliberately hot */ }
  return +(performance.now() - t0).toFixed(1);
}, ms);

const snap = (p) => p.evaluate(() => {
  const q = window.__tape?.pcm ?? null;
  return q && {
    target: q.targetFrames, ceil: q.jitMaxTarget, elUps: q.elUps ?? null,
    conceal: q.lostFrames, late: q.lateFrames, recv: q.framesRecv,
    depth: q.depthMs, stalls: (q.stalls ?? []).length,
    stallList: (q.stalls ?? []).slice(-40),
  };
});

async function arm(label, extra) {
  const room = `el-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 5)}`;
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
    await b.waitForTimeout(SETTLE_S * 1000);
    const base = await snap(b);
    if (!base) throw new Error(`${label}: PCM lane not running on B`);

    // The recurring-hole regime, on B (the receiver being measured).
    let achievedMax = 0;
    let mid = null;
    for (let i = 0; i < HOLES; i++) {
      const got = await block(b, HOLE_MS);
      if (got > achievedMax) achievedMax = got;
      await b.waitForTimeout(GAP_S * 1000);
      if (i === HALF - 1) mid = await snap(b); // end of the evidence-gathering half
    }
    await b.waitForTimeout(3000); // let the last clump play through or conceal
    const end = await snap(b);
    if (!end || !mid) throw new Error(`${label}: PCM lane vanished mid-run`);

    // Stimulus confirmation: B's own stall list must show gaps of roughly our
    // size AFTER the baseline. Without this an unaffected system and a broken
    // instrument are indistinguishable.
    const fresh = end.stalls - base.stalls;
    const big = end.stallList.filter((s) => s.g >= 0.6 * HOLE_MS).length;
    const r = {
      concealD: end.conceal - base.conceal,
      lateD: end.late - base.late,
      recvD: end.recv - base.recv,
      pain1: (mid.conceal - base.conceal) + (mid.late - base.late),
      pain2: (end.conceal - mid.conceal) + (end.late - mid.late),
      depthMid: mid.depth, depthEnd: end.depth,
      ceilEnd: end.ceil, ceilBase: base.ceil, elUps: end.elUps,
      targetEnd: end.target, freshStalls: fresh, bigStalls: big,
      achievedMax,
    };
    console.log(`  [${label}] ceil ${r.ceilBase}->${r.ceilEnd}f elUps=${r.elUps} target=${r.targetEnd}f depth mid=${r.depthMid} end=${r.depthEnd}ms  ` +
      `pain 1st-half=${r.pain1} 2nd-half=${r.pain2}  stalls +${fresh} (${big} >=${0.6 * HOLE_MS}ms, worst block ${achievedMax}ms)`);
    return r;
  } finally {
    await A.close(); await B.close();
  }
}

{
  const load = os.loadavg()[0] / os.cpus().length;
  console.log(`host load ${(100 * load).toFixed(0)}% of ${os.cpus().length} cores`);
  if (load > 0.7) { console.error('ABORT: host too busy — the holes would not be the only stalls'); process.exit(3); }
}

const elastic = await arm('elastic', '');
const control = await arm('control', '&pcmelastic=0&pcmbuild=0');

let fails = 0;
const check = (name, ok, detail) => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  (${detail})`);
  if (!ok) fails++;
};

// VOID beats a false verdict: if either arm's blocks failed to interrupt
// timestamping, the comparison is between two unstimulated calls.
for (const [n, r] of [['elastic', elastic], ['control', control]]) {
  if (r.bigStalls < HOLES * 0.5) {
    console.error(`VOID: ${n} arm saw only ${r.bigStalls}/${HOLES} stalls >= ${0.6 * HOLE_MS} ms — stimulus did not land`);
    process.exit(3);
  }
}

check('the clamp costs audio when it cannot stretch (the defect)', control.pain2 >= 20,
  `control 2nd-half conceal+late = ${control.pain2} over ${HOLES - HALF} holes of ${HOLE_MS}ms vs 256ms cap`);
check('the ceiling stays pinned in the control arm', control.ceilEnd === control.ceilBase && !control.elUps,
  `control ceil ${control.ceilBase}->${control.ceilEnd}, elUps=${control.elUps}`);
check('the elastic ceiling engages under the same holes', elastic.elUps > 0 && elastic.ceilEnd > elastic.ceilBase,
  `elastic ceil ${elastic.ceilBase}->${elastic.ceilEnd}f in ${elastic.elUps} raises`);
check('the raised target becomes REAL DEPTH (build-side widening works)',
  elastic.depthEnd != null && elastic.depthEnd >= HOLE_MS,
  `elastic depth end=${elastic.depthEnd}ms vs ${HOLE_MS}ms holes (control carries ${control.depthEnd}ms)`);
check('and stretching STOPS the concealment (2nd half <=33% of control)',
  elastic.pain2 <= Math.max(8, 0.33 * control.pain2),
  `2nd-half pain: elastic ${elastic.pain2} vs control ${control.pain2} concealed+late frames`);
console.log(fails === 0 ? '\nVERDICT: PASS' : `\nVERDICT: FAIL (${fails})`);
process.exit(fails ? 1 : 0);
