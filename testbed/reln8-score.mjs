/**
 * Scores the eight paired calls from reln8.sh.
 *
 * WRITTEN BEFORE THE DATA ARRIVES, on purpose. With eight runs and six metrics there
 * are enough combinations to find a favourable p-value by choosing the test afterwards,
 * and this project already has a case of an F-test returning p=0.0143 on two arms that
 * were byte-identical. So the statistic, the sign convention and the required margin are
 * all fixed here in advance.
 *
 * THE STATISTIC: a PAIRED t-test on the within-call difference, fast minus slow, so
 * negative favours the fast release. Paired rather than Welch because the two arms share
 * a call by construction — the whole point of the design — and the between-call variance
 * that a two-sample test would have to absorb is enormous here (the same setting
 * concealed 201 frames in one call and 300 in another, while the two ends of one call
 * agreed to within 2).
 *
 * Sides alternate across the eight runs, so the per-run difference is computed by
 * RELEASE RATE read out of each report, never by side. Reading it by side would bake the
 * measured side asymmetry (~3 ms of baseline depth) straight into the result.
 *
 *   node testbed/reln8-score.mjs
 */
import fs from 'node:fs';

const DIR = '/private/tmp/claude-501/-Users-earningsgpt-video-calling/477cd6ea-c192-43a3-b107-a2011157fa96/scratchpad/n8';

// Two-sided p from a t statistic, via an incomplete-beta continued fraction. Same
// routine shape as the rest of the testbed so results stay comparable.
function betacf(a, b, x) {
  const MAXIT = 200, EPS = 3e-14, FPMIN = 1e-300;
  const qab = a + b, qap = a + 1, qam = a - 1;
  let c = 1, d = 1 - (qab * x) / qap;
  if (Math.abs(d) < FPMIN) d = FPMIN;
  d = 1 / d;
  let h = d;
  for (let m = 1; m <= MAXIT; m++) {
    const m2 = 2 * m;
    let aa = (m * (b - m) * x) / ((qam + m2) * (a + m2));
    d = 1 + aa * d; if (Math.abs(d) < FPMIN) d = FPMIN;
    c = 1 + aa / c; if (Math.abs(c) < FPMIN) c = FPMIN;
    d = 1 / d; h *= d * c;
    aa = (-(a + m) * (qab + m) * x) / ((a + m2) * (qap + m2));
    d = 1 + aa * d; if (Math.abs(d) < FPMIN) d = FPMIN;
    c = 1 + aa / c; if (Math.abs(c) < FPMIN) c = FPMIN;
    d = 1 / d;
    const del = d * c; h *= del;
    if (Math.abs(del - 1) < EPS) break;
  }
  return h;
}
const lgamma = (z) => {
  const g = [76.18009172947146, -86.50532032941677, 24.01409824083091,
    -1.231739572450155, 0.1208650973866179e-2, -0.5395239384953e-5];
  let x = z, y = z, tmp = x + 5.5;
  tmp -= (x + 0.5) * Math.log(tmp);
  let ser = 1.000000000190015;
  for (let j = 0; j < 6; j++) ser += g[j] / ++y;
  return -tmp + Math.log((2.5066282746310005 * ser) / x);
};
function betai(a, b, x) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  const bt = Math.exp(lgamma(a + b) - lgamma(a) - lgamma(b) + a * Math.log(x) + b * Math.log(1 - x));
  return x < (a + 1) / (a + b + 2) ? (bt * betacf(a, b, x)) / a : 1 - (bt * betacf(b, a, 1 - x)) / b;
}
const pFromT = (t, df) => (df <= 0 ? null : betai(df / 2, 0.5, df / (df + t * t)));

// ── the statistics test THEMSELVES before testing anything else ─────────────────
// A p-value routine that is subtly wrong yields a confident wrong conclusion, and it
// would look exactly like a correct one. Checked against textbook two-sided critical
// values; a failure ABORTS rather than warns, because a scorer that cannot compute p
// must not print one.
{
  const CASES = [[2.306004, 8, 0.05], [2.364624, 7, 0.05], [3.182446, 3, 0.05],
                 [1.959964, 1e7, 0.05], [3.499483, 7, 0.01]];
  const bad = CASES.filter(([t, df, want]) => Math.abs(pFromT(t, df) - want) > 5e-4);
  if (bad.length) {
    console.error(`STATS SELF-TEST FAILED on ${bad.length} case(s): ` +
      bad.map(([t, df, w]) => `t=${t} df=${df} got ${pFromT(t, df).toFixed(5)} want ${w}`).join('; '));
    process.exit(4);
  }
  console.log(`  stats self-test: ${CASES.length} textbook critical values reproduced to 5e-4`);
}

// ── load ──
const files = fs.readdirSync(DIR).filter((f) => f.endsWith('.json')).sort();
const runs = [];
for (const f of files) {
  let r;
  try { r = JSON.parse(fs.readFileSync(`${DIR}/${f}`, 'utf8')); } catch (e) { console.log(`  skip ${f}: unreadable (${e.message})`); continue; }
  if (!r.result) { console.log(`  skip ${f}: no result block — the run aborted, which is the gate working`); continue; }
  // Identify arms BY RELEASE RATE, never by side.
  const slow = ['A', 'B'].find((t) => r.result[t].relPerSec === 1);
  const fast = ['A', 'B'].find((t) => r.result[t].relPerSec === 8);
  if (!slow || !fast) { console.log(`  skip ${f}: arms are ${r.result.A.relPerSec}/${r.result.B.relPerSec} ms/s, not 1/8`); continue; }
  const drop = r.shaper ? (100 * r.shaper.dropped) / Math.max(1, r.shaper.sent) : null;
  runs.push({ f, side: slow, slow: r.result[slow], fast: r.result[fast], dropPct: drop });
}
if (runs.length < 3) { console.error(`only ${runs.length} usable runs — not enough to test`); process.exit(1); }

// ── metrics, fixed in advance. Negative difference favours FAST. ──
const METRICS = [
  ['mean mouth-to-ear (ms)', (a) => a.steadyMeanE2E],
  ['last-third m2e (ms)', (a) => a.steadyLastThirdE2E],
  ['frames concealed', (a) => a.steadyLost],
];

console.log(`\nPAIRED n=${runs.length}  —  5% sustained loss, sides alternating`);
console.log(`statistic: within-call difference, FAST minus SLOW. Negative favours fast.\n`);
console.log(`  run                 slow side   shaper drop`);
for (const r of runs) console.log(`  ${r.f.padEnd(20)}${r.side.padEnd(12)}${r.dropPct === null ? 'n/a' : r.dropPct.toFixed(2) + '%'}`);

for (const [name, get] of METRICS) {
  const d = runs.map((r) => get(r.fast) - get(r.slow)).filter((x) => Number.isFinite(x));
  if (d.length !== runs.length) { console.log(`\n  ${name}: only ${d.length}/${runs.length} runs carry this field — NOT TESTED`); continue; }
  const n = d.length;
  const mean = d.reduce((a, b) => a + b, 0) / n;
  const sd = Math.sqrt(d.reduce((a, b) => a + (b - mean) ** 2, 0) / (n - 1));
  const se = sd / Math.sqrt(n);
  const t = se === 0 ? null : mean / se;
  const p = t === null ? null : pFromT(t, n - 1);
  const wins = d.filter((x) => x < 0).length;
  console.log(`\n  ${name}`);
  console.log(`    per-run diffs: ${d.map((x) => x.toFixed(1)).join(', ')}`);
  console.log(`    mean ${mean.toFixed(2)}  sd ${sd.toFixed(2)}  n ${n}  ` +
    `${t === null ? 't undefined (zero variance)' : `t ${t.toFixed(3)}  p ${p.toFixed(4)}`}`);
  console.log(`    fast better in ${wins}/${n} runs`);
  if (se === 0) {
    console.log(`    ZERO VARIANCE: every run gave the same difference. A t-test is undefined and`);
    console.log(`    unnecessary — a perfectly repeatable difference needs no significance test.`);
  } else if (p < 0.05 && wins !== n && wins !== 0) {
    console.log(`    p < 0.05 but the sign is NOT unanimous (${wins}/${n}). Report the split, not just the p.`);
  }
}
// ── DESCRIPTIVE ONLY, NO TEST ───────────────────────────────────────────────────
// The first valid run showed `baseTarget: 15` on BOTH sides — the maxTargetFrames
// ceiling is already bound at settle under 5% loss — while `finalTarget` came down to
// 13 on the slow side and 11 on the fast one. That reframes what this regime measures:
// not how high the buffer goes, but how fast it comes back DOWN off the startup
// transient. Worth seeing, so it is printed; NOT given a p-value, because it was
// chosen after looking at the data and the metric list above was fixed before it
// precisely so that could not happen. If it looks like an effect, it needs its own run.
{
  console.log(`\nDESCRIPTIVE (chosen after seeing run 1 — no p-value, on purpose)`);
  console.log(`  target frames, base -> final       slow            fast`);
  for (const r of runs) {
    const f = (a) => `${a.baseTarget} -> ${a.finalTarget}`;
    console.log(`  ${r.f.padEnd(34)}${f(r.slow).padEnd(16)}${f(r.fast)}`);
  }
  const ceil = runs.filter((r) => r.slow.baseTarget >= 15 && r.fast.baseTarget >= 15).length;
  console.log(`  ${ceil}/${runs.length} runs began with BOTH sides pinned at the 15-frame ceiling.`);
  if (ceil === runs.length) {
    console.log(`  So every run here starts in the regime where the estimator's target cannot rise`);
    console.log(`  further and the release rate's only remaining job is the descent.`);
  }
}

console.log(`\nWHAT THIS CANNOT SETTLE`);
console.log(`  - the n=8 in pcm.js measured DIFFERENT quantities (rig p50/p95, delivered pp, lane`);
console.log(`    rate) at --bw=0.3. Matching its condition needs its metrics too; this matches its`);
console.log(`    sample size and its regime's LOSS, not its instrument.`);
console.log(`  - two Chromium peers on one host: emulated loss on a local path, not the internet.`);
// This limitation was pre-registered and then MEASURED FALSE, so it is corrected rather
// than left standing. testbed/startup.mjs at --loss=5 reports jitClampedTicks of 0 and 3
// out of ~480 ticks, with want peaking at 13f and 16f against the 15f cap. The ceiling
// therefore barely binds in this regime and does NOT suppress the effect — which makes the
// n=8 result stronger than its own stated caveat allowed. (It does bind hard elsewhere:
// 419 and 490 clamped ticks at --bw=0.3, with want peaking at 28f and 1201f.)
console.log(`  - the 15-frame ceiling barely binds under 5% loss — MEASURED, 0 and 3 clamped ticks`);
console.log(`    of ~480, want peaking at 13f/16f against the 15f cap. An earlier version of this`);
console.log(`    note claimed the ceiling suppressed the effect here; that was wrong, and the`);
console.log(`    correction makes the result above stronger rather than weaker. The ceiling DOES`);
console.log(`    bind at --bw=0.3 (419/490 clamped ticks, want 28f and 1201f), so a release-rate`);
console.log(`    A/B in THAT regime is the one that measures nothing.`);
