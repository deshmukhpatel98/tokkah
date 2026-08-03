/**
 * SUPERSEDED by testbed/relpair.mjs for any COMPARISON. Kept because it is the simplest
 * thing that measures the absolute cost of one hole, and its result stands: one 99.9 ms
 * hole raised the buffer 14.7 -> 68.7 ms and took ~80 s to clear.
 *
 * KNOWN DEFECT, deliberately left documented rather than silently patched: this file has
 * NO PREFLIGHT ON ITS OWN BASELINE. It once printed a tidy result table for a run whose
 * baseline read `depthMs -22935` with 2867 frames concealed — a call whose playhead was
 * running 23 s ahead of its audio. It also cannot resolve a release-rate A/B at all,
 * because sequential arms on this laptop move the metric further than the variable does
 * (run 1 ended at the 2-frame floor; runs 2, 3 and 4 all ended pinned at the 15f ceiling,
 * monotone in run order). Use relpair.mjs, which gates its baseline and pairs its arms
 * inside one call. If you use this file, check the baseline by hand.
 *
 * The cross-engine investigation ended somewhere more interesting than WebKit. The
 * stalls it found are host contention, and because both browsers share one laptop
 * that coupling is partly the rig's own doing. But it exposed a property of OUR code
 * that has nothing to do with which browser is on the other end:
 *
 *   `spread` is second-largest-minus-min over a 2.56 s window, so ONE isolated hole
 *   sets it. The peak-hold then releases at 1 ms/s. A single 90 ms hiccup should
 *   therefore raise the audio buffer and keep it raised for about ninety seconds.
 *
 * "Should" is the problem. That is a reading of the source, not a measurement, and
 * this project has a long record of readings that were confidently wrong. Two earlier
 * buffer changes were argued from mechanism and both made things worse; one predicted
 * +80 ms of latency and measured a FALL. So the rule here is: measure the cost of the
 * current behaviour before touching it, and let the number decide whether there is
 * anything to fix.
 *
 * METHOD. Two Chromium peers, same engine on purpose — the point is to isolate the
 * estimator's response, not to re-litigate cross-engine. Let the call settle to its
 * floor. Then block ONE receiver's main thread for exactly one interval, which is
 * what a real stall does to arrival timestamping: packets stop being dispatched, then
 * arrive in a clump. Sample the buffer every second until it comes back, or until
 * time runs out and the report says so.
 *
 * WHAT WOULD MAKE THIS A LIE, and what stops it:
 *   - The injection silently doing nothing. A fixture that fails to stimulate looks
 *     exactly like a system that shrugged it off. So the run ABORTS unless a stall of
 *     roughly the injected size appears in the receiver's own stall list.
 *   - Claiming a recovery time when the window ended first. Recovery is reported as
 *     NOT RECOVERED with a lower bound instead.
 *   - Attributing drift to the injection. --hole=0 runs the identical timeline with
 *     no injection, so "the buffer would have risen anyway" is testable, not assumed.
 *   - A host too busy to time anything. Same 4 ms scheduler probe as rig.mjs; p95
 *     >= 20 ms and every row is stamped UNTRUSTED.
 *
 *   node testbed/onehole.mjs [--hole=90] [--settle=25] [--recover=150]
 *                            [--query=tape=2] [--base=URL] [--json=PATH]
 */
import { chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';
import os from 'node:os';
import fs from 'node:fs';

const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const CAM = '/Users/earningsgpt/video calling/testbed/media/cam1080.mjpeg';
const AUD = '/Users/earningsgpt/video calling/testbed/media/conv/A.wav';

const KNOWN = new Set(['hole', 'settle', 'recover', 'query', 'base', 'json', 'holes', 'gap']);
for (const a of process.argv.slice(2)) {
  const m = /^--([a-z]+)(=|$)/.exec(a);
  if (!m || !KNOWN.has(m[1])) {
    console.error(`unknown flag: ${a}\nknown: ${[...KNOWN].map((k) => '--' + k).join(' ')}`);
    process.exit(2);
  }
}
const arg = (k, d) => {
  const m = process.argv.find((a) => a.startsWith(`--${k}=`));
  return m ? m.slice(k.length + 3) : d;
};
const HOLE = Number(arg('hole', 90));
const HOLES = Number(arg('holes', 1));   // how many, to reach the RECURRING regime
const GAP = Number(arg('gap', 10));      // seconds between them
const SETTLE = Number(arg('settle', 25));
const RECOVER = Number(arg('recover', 150));
const QUERY = arg('query', 'tape=2');
const BASE = arg('base', 'https://room.tokkah.com');
const JSON_OUT = arg('json', null);
for (const [k, v, min] of [['hole', HOLE, 0], ['settle', SETTLE, 15], ['recover', RECOVER, 30],
                           ['holes', HOLES, 1], ['gap', GAP, 1]]) {
  if (!Number.isFinite(v) || v < min) { console.error(`--${k} must be a number >= ${min}`); process.exit(2); }
}
// The release rate is READ BACK OUT of the query the run will actually use, never
// assumed. `?pcmjitrel=` sets ms of spread released per 250 ms tick, so x4 is per
// second; app.js falls back to pcm.js's 0.25 default when it is absent or zero.
// Printing a hardcoded "1 ms/s" while the page ran at 8 would make every prediction
// in the report agree with itself and disagree with the software.
const relPerTick = Number(new URLSearchParams(QUERY).get('pcmjitrel')) || 0.25;

/** Reading a field that does not exist is a BUG, not a missing datum. */
function need(o, k, where) {
  if (o == null) throw new Error(`${where}: object is ${o}, cannot read "${k}"`);
  if (o[k] === undefined) throw new Error(`${where}: field "${k}" does not exist. Available: ${Object.keys(o).slice(0, 40).join(', ')}`);
  return o[k];
}

const mk = async (tag) => {
  const ctx = await chromium.launchPersistentContext('', {
    executablePath: CHROME, headless: true,
    args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
      `--use-file-for-fake-video-capture=${CAM}`, `--use-file-for-fake-audio-capture=${AUD}`,
      '--autoplay-policy=no-user-gesture-required'],
    viewport: { width: 1000, height: 700 },
  });
  return { ctx, page: await ctx.newPage(), tag };
};

// `window.__tape.pcm` IS the snapshot object — not a getter. Guessing `.stats()` here
// made this abort with "PCM lane not running" on a perfectly healthy lane. The abort
// was correct behaviour on a wrong premise, which is the good failure mode: a `?? null`
// would have measured a null buffer for 150 s and printed it as a flat line.
const snap = (p) => p.evaluate(() => ({
  hasTape: !!window.__tape,
  pcm: window.__tape?.pcm ?? null,
  status: document.getElementById('status')?.textContent ?? null,
}));

const schedLag = (p, ms = 2000) => p.evaluate((dur) => new Promise((res) => {
  const STEP = 4, late = [];
  let prev = performance.now(); const t0 = prev;
  const id = setInterval(() => {
    const now = performance.now();
    late.push(now - prev - STEP); prev = now;
    if (now - t0 >= dur) {
      clearInterval(id);
      const s = late.filter((x) => x > 0).sort((a, b) => a - b);
      const q = (f) => (s.length ? +s[Math.min(s.length - 1, Math.floor(f * s.length))].toFixed(1) : 0);
      res({ n: late.length, p50: q(0.5), p95: q(0.95), max: s.length ? +s[s.length - 1].toFixed(1) : 0 });
    }
  }, STEP);
}), ms);

/**
 * THE STIMULUS. A busy-wait on the main thread, which is where pcm.js timestamps
 * arrivals — so for the duration nothing is dispatched and the datachannel backlog
 * lands in a clump afterwards. That is the measured signature of the real stalls
 * (one large gap, then near-zero gaps), so it is the faithful stimulus rather than a
 * convenient one. Returns the ACHIEVED block duration: asking for 90 ms and getting
 * 4 would invalidate the run, so it is reported rather than assumed.
 */
const block = (p, ms) => p.evaluate((dur) => {
  const t0 = performance.now();
  while (performance.now() - t0 < dur) { /* deliberately hot */ }
  return +(performance.now() - t0).toFixed(1);
}, ms);

const room = 'hole' + Math.random().toString(36).slice(2, 7);
const report = {
  meta: { room, holeMs: HOLE, settleS: SETTLE, recoverS: RECOVER, query: QUERY, base: BASE,
          at: new Date().toISOString(), host: `${os.cpus().length} cores, ${os.platform()} ${os.release()}` },
  calibration: null, baseline: null, injection: null, series: [], verdict: null, limits: [],
};

console.log(`\n${'━'.repeat(78)}\nONE HOLE  room=${room}  hole=${HOLE}ms  settle=${SETTLE}s  recover=${RECOVER}s\n${'━'.repeat(78)}`);
if (HOLE === 0) console.log(`\n  CONTROL ARM: no injection. Any rise below is drift, not the hole.\n`);

// Host headroom: two browsers plus a busy-wait cannot share a saturated laptop.
{
  const load = os.loadavg()[0] / os.cpus().length;
  console.log(`  host load ${(100 * load).toFixed(0)}% of ${os.cpus().length} cores`);
  if (load > 0.7) { console.error(`  ABORT: host at ${(100 * load).toFixed(0)}% — arrival timing here would be this laptop, not the lane`); process.exit(3); }
}

const A = await mk('A'), B = await mk('B');
const url = `${BASE}/?r=${room}&${QUERY}`;
try {
  for (const e of [A, B]) {
    await e.page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await e.page.waitForSelector('#join', { timeout: 30000 });
  }
  await A.page.click('#join');
  await A.page.waitForTimeout(700);
  await B.page.click('#join');
  for (const e of [A, B]) {
    await e.page.waitForFunction(() => document.querySelector('#status')?.textContent === 'connected', null, { timeout: 40000 });
  }
  console.log(`  connected. settling ${SETTLE}s so the buffer reaches its floor and the ${'warm-up'} window passes`);
  await B.page.waitForTimeout(SETTLE * 1000);

  const L = await schedLag(B.page);
  const trusted = L.p95 < 20;
  report.calibration = { lag: L, timingTrusted: trusted };
  console.log(`  scheduler lateness on B: p50 ${L.p50} p95 ${L.p95} max ${L.max} ms -> timing ${trusted ? 'TRUSTED' : 'UNTRUSTED'}`);
  if (!trusted) report.limits.push(`scheduler p95 ${L.p95} ms — every row untrusted`);

  const s0 = await snap(B.page);
  if (!s0.hasTape) throw new Error('B: window.__tape absent — nothing readable');
  if (!s0.pcm) throw new Error('B: PCM lane not running — this experiment is about the PCM buffer');
  const base = {
    target: need(s0.pcm, 'targetFrames', 'pcm'), depth: need(s0.pcm, 'depthMs', 'pcm'),
    spread: need(s0.pcm, 'jitSpreadMaxRun', 'pcm'), stalls: (need(s0.pcm, 'stalls', 'pcm')).length,
    conceal: need(s0.pcm, 'lostFrames', 'pcm'), recv: need(s0.pcm, 'framesRecv', 'pcm'),
  };
  report.baseline = base;
  console.log(`\nBASELINE after ${SETTLE}s   target ${base.target}f   depth ${base.depth} ms   spreadMaxRun ${base.spread} ms   stalls so far ${base.stalls}\n`);

  // Injection runs on its own clock, concurrently with sampling, so the RECURRING
  // regime is possible at all. The slow release exists BECAUSE bursts recur, so a
  // single hole only tests the half of the tradeoff that favours changing it.
  let achieved = 0;
  const fired = [];
  const inject = (async () => {
    for (let i = 0; i < HOLES && HOLE > 0; i++) {
      if (i) await new Promise((r) => setTimeout(r, GAP * 1000));
      const a = await block(B.page, HOLE);
      achieved = a; fired.push({ i, at: Date.now(), ms: a });
      console.log(`  INJECT #${i + 1}/${HOLES}: ${a} ms main-thread block on B (asked ${HOLE})`);
    }
  })();
  if (HOLES === 1) await inject;

  console.log(`\n  t(s)  target  depth   spreadMaxRun  gapMax  stalls   [watching for return to ${base.target}f]`);
  const t0 = Date.now();
  // Depth and target peak INDEPENDENTLY, and the first version of this gated depth on
  // target being at its own max. Target snapped to 12f at t+0 and started falling while
  // depth was still ramping in, so it reported a 26.5 ms peak on a run whose true depth
  // max was 68.7 ms — understated by 2.6x. The two are different quantities: target is
  // an allowance the estimator asks for, depth is the latency actually being carried.
  let peakT = { v: base.target, at: 0 }, peakD = { v: base.depth, at: 0 };
  let backAt = null, sawStall = null;
  while (Date.now() - t0 < RECOVER * 1000) {
    const s = await snap(B.page);
    const q = s.pcm;
    if (!q) throw new Error('B: PCM lane vanished mid-run');
    const el = +((Date.now() - t0) / 1000).toFixed(1);
    const target = need(q, 'targetFrames', 'pcm'), depth = need(q, 'depthMs', 'pcm');
    const st = need(q, 'stalls', 'pcm');
    if (sawStall === null && st.length > base.stalls) {
      // Only stalls AFTER the baseline count, and only ones big enough to be ours.
      const fresh = st.slice(base.stalls);
      const m = fresh.find((x) => x.g >= 0.6 * HOLE);
      if (m) sawStall = m;
    }
    if (target > peakT.v) peakT = { v: target, at: el };
    if (depth > peakD.v) peakD = { v: depth, at: el };
    // Only count a return once every hole has been fired, or a gap between holes reads
    // as recovery.
    if (backAt === null && el > 1 && target <= base.target && fired.length >= HOLES) backAt = el;
    report.series.push({ t: el, target, depth, spread: need(q, 'jitSpreadMaxRun', 'pcm'),
                         gapMax: need(q, 'gapMaxRun', 'pcm'), stalls: st.length, lost: need(q, 'lostFrames', 'pcm') });
    console.log(`  ${String(el).padStart(5)}  ${String(target).padStart(6)}  ${String(depth).padStart(5)}   ` +
      `${String(need(q, 'jitSpreadMaxRun', 'pcm')).padStart(12)}  ${String(need(q, 'gapMaxRun', 'pcm')).padStart(6)}  ${String(st.length).padStart(6)}` +
      `${backAt !== null && backAt === el ? '   <- back to baseline' : ''}`);
    await new Promise((r) => setTimeout(r, 2000));
  }

  // ── did the stimulus land? ──
  if (HOLE > 0) {
    if (!sawStall) {
      throw new Error(`the ${achieved} ms block produced NO stall >= ${(0.6 * HOLE).toFixed(0)} ms in B's own stall list ` +
        `(had ${base.stalls} before, ${report.series.at(-1).stalls} after). Either the block did not ` +
        `interrupt arrival timestamping, or the threshold missed it. A stimulus that does not stimulate ` +
        `makes an unaffected system and a broken instrument look identical, so this run is VOID.`);
    }
    console.log(`\n  stimulus CONFIRMED: B recorded a ${sawStall.g} ms gap of its own (asked ${HOLE}, blocked ${achieved})`);
  }
  report.injection = { asked: HOLE, achieved, stallSeen: sawStall };

  await inject;
  const rose = peakT.v > base.target;
  const lastLost = report.series.at(-1).lost;
  // Latency INTEGRAL: the excursion's area, ms of extra buffer x seconds. A peak alone
  // cannot compare a tall brief excursion against a low sustained one, and those are
  // exactly the two shapes a release-rate change trades between.
  let area = 0;
  for (let i = 1; i < report.series.length; i++) {
    const a = report.series[i - 1], b = report.series[i];
    area += ((a.depth - base.depth) + (b.depth - base.depth)) / 2 * (b.t - a.t);
  }
  console.log(`\nRESULT`);
  console.log(`  baseline        target ${base.target}f   depth ${base.depth} ms`);
  console.log(`  peak target     ${peakT.v}f at t+${peakT.at}s     (the allowance the estimator asked for)`);
  console.log(`  peak depth      ${peakD.v} ms at t+${peakD.at}s   (the latency actually carried)`);
  console.log(`  cost:  +${peakT.v - base.target} frames of allowance, +${(peakD.v - base.depth).toFixed(1)} ms of real buffered latency`);
  console.log(`  excursion area  ${area.toFixed(0)} ms*s above baseline   [the figure to minimise: peak alone cannot`);
  console.log(`                  compare a tall brief excursion against a low sustained one]`);
  console.log(`  concealment     ${lastLost - base.conceal} frames lost during the window (baseline had ${base.conceal})`);
  report.area = +area.toFixed(0);
  report.lostInWindow = lastLost - base.conceal;
  if (!rose) {
    console.log(`  the buffer DID NOT RISE. ${HOLE === 0 ? 'Correct for the control arm.' :
      'Either the hole is not enough to move the estimator, or it recovered inside the 2 s sampling gap.'}`);
  } else if (backAt !== null) {
    console.log(`  RECOVERED at t+${backAt}s — ${HOLES} hole(s) cost ${backAt}s of elevated latency`);
  } else {
    console.log(`  NOT RECOVERED within ${RECOVER}s: still ${report.series.at(-1).target}f at the end of the window.`);
    console.log(`  So the cost of one ${HOLE} ms hole is AT LEAST ${RECOVER}s of elevated buffer — a lower bound, not the value.`);
    report.limits.push(`recovery time is a lower bound (${RECOVER}s), not a measurement`);
  }
  const predicted = base.spread > 0 ? null : null;
  console.log(`\n  the mechanism this tests: spread is second-largest-minus-min over 2.56 s, so one hole sets it,`);
  console.log(`  and the peak-hold releases at ${(4 * relPerTick).toFixed(1)} ms/s (pcmjitrel=${relPerTick}/tick). Predicted hold`);
  console.log(`  for a ${HOLE} ms hole: ~${(HOLE / (4 * relPerTick)).toFixed(0)}s. Measured above — the two should agree, or one of them is wrong.`);
  report.verdict = { rose, base, peakTarget: peakT, peakDepth: peakD, recoveredAtS: backAt, notRecovered: backAt === null && rose,
                     timingTrusted: trusted };

  console.log(`\nLIMITS`);
  for (const l of ['two Chromium peers on one host: no real network, no distance, no cross-traffic',
                   'the stimulus is a main-thread block, which is ONE cause of arrival stalls, not all of them',
                   'n=1 per invocation: run it repeatedly before quoting a recovery time to the second',
                   ...report.limits]) console.log(`  - ${l}`);
} finally {
  if (JSON_OUT) { fs.writeFileSync(JSON_OUT, JSON.stringify(report, null, 2)); console.log(`\n  json -> ${JSON_OUT}`); }
  for (const e of [A, B]) { try { await e.ctx.close(); } catch {} }
}
