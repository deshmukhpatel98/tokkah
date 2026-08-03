/**
 * Scores the paired jitter-buffer-ceiling calls from jb.sh.
 *
 * WRITTEN BEFORE THE DATA ARRIVES. The metric list, the sign convention, the statistic
 * and the two-column rule below are all fixed here in advance, because with six runs
 * and a dozen fields there is always a favourable p-value available to whoever picks
 * the test afterwards. This project already has an F-test that returned p=0.0143 on two
 * arms that were byte-identical.
 *
 * THE QUESTION: at 1/8 CPU speed — a budget phone, not this laptop — the audio lane
 * conceals ~6-7% of frames while the jitter estimator sits pinned at its 15-frame
 * (120 ms) ceiling. Does letting it ask for 30 frames buy the concealment back?
 *
 * THE TWO-COLUMN RULE: concealment and latency are reported TOGETHER and neither alone
 * decides. A delivery-only comparison crowns whichever arm buffers the most, and a
 * latency-only comparison crowns whichever arm drops the most frames; this project has
 * been burned by the latter. A bigger ceiling that fixes concealment by adding 100 ms of
 * mouth-to-ear has not fixed anything — the goal is a call that replaces being in the
 * same room, and 100 ms of delay is felt in turn-taking even when every sample arrives.
 *
 * THE STATISTIC: paired t on the within-call difference, big-ceiling minus default, so
 * NEGATIVE favours the bigger ceiling on concealment and POSITIVE is its latency cost.
 * Arms are identified by the `jitMaxTarget` each side reports — read out of the page,
 * never inferred from which side it was, because side asymmetry on this project has
 * reached 45x and would otherwise become the result.
 *
 *   node testbed/jb-score.mjs
 */
import fs from 'node:fs';

const DIR = '/private/tmp/claude-501/-Users-earningsgpt-video-calling/477cd6ea-c192-43a3-b107-a2011157fa96/scratchpad/jb';

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

// The p-routine is tested before it is used. A subtly wrong one yields a confident
// wrong conclusion that looks exactly like a correct one, so a failure ABORTS.
{
  const CASES = [[2.306004, 8, 0.05], [2.364624, 7, 0.05], [3.182446, 3, 0.05],
                 [1.959964, 1e7, 0.05], [3.499483, 7, 0.01], [2.570582, 5, 0.05]];
  const bad = CASES.filter(([t, df, want]) => Math.abs(pFromT(t, df) - want) > 5e-4);
  if (bad.length) {
    console.error(`STATS SELF-TEST FAILED: ` + bad.map(([t, df, w]) => `t=${t} df=${df} got ${pFromT(t, df)?.toFixed(5)} want ${w}`).join('; '));
    process.exit(4);
  }
  console.log(`  stats self-test: ${CASES.length} textbook critical values reproduced to 5e-4`);
}

const load = (f) => { try { return JSON.parse(fs.readFileSync(`${DIR}/${f}`, 'utf8')); } catch { return null; } };
const files = fs.existsSync(DIR) ? fs.readdirSync(DIR).filter((f) => f.endsWith('.json')).sort() : [];
if (!files.length) { console.error(`no reports in ${DIR}`); process.exit(1); }

const both = (r) => r?.sides?.brave && r?.sides?.peer;

// ── the noise floor comes FIRST, and it is not decoration ────────────────────────
// Equal settings on both ends of one call. Whatever difference shows up there is the
// floor any claimed effect has to clear. Reporting an effect without it is how a
// 0.07-percentage-point "win" got taken seriously on this project once.
console.log(`\nNOISE FLOOR — identical settings on both ends of one call`);
const eqs = files.filter((f) => f.startsWith('eq')).map(load).filter(both);
const floor = [];
for (const r of eqs) {
  const a = r.sides.brave, b = r.sides.peer;
  floor.push({ conceal: b.concealPct - a.concealPct, depth: b.depthMs - a.depthMs, late: b.lateFrames - a.lateFrames });
  console.log(`  ${r.meta.room}  conceal ${a.concealPct}% vs ${b.concealPct}%   depth ${a.depthMs} vs ${b.depthMs} ms   ` +
    `late ${a.lateFrames} vs ${b.lateFrames}   clampedTicks ${a.jitClampedTicks}/${b.jitClampedTicks}   cap ${a.jitMaxTarget}f`);
}
if (!eqs.length) console.log(`  (none yet)`);
else {
  const mx = (k) => Math.max(...floor.map((x) => Math.abs(x[k]))).toFixed(2);
  console.log(`  floor (largest |B-A| with settings equal): conceal ${mx('conceal')} pp, depth ${mx('depth')} ms, late ${mx('late')} frames`);
}

// ── did the flag even take effect? ───────────────────────────────────────────────
const runs = [];
for (const f of files.filter((x) => x.startsWith('p'))) {
  const r = load(f);
  if (!both(r)) { console.log(`  skip ${f}: incomplete (a side is missing — the run did not finish)`); continue; }
  const sides = [r.sides.brave, r.sides.peer];
  const big = sides.find((s) => s.jitMaxTarget === 30);
  const def = sides.find((s) => s.jitMaxTarget === 15);
  if (!big || !def) {
    console.log(`  skip ${f}: caps are ${sides.map((s) => s.jitMaxTarget).join('/')}f, not 30/15 — ` +
      `?pcmjbmax did not take effect, so this run measures nothing`);
    continue;
  }
  runs.push({ f, big, def, bigSide: big === r.sides.brave ? 'A' : 'B', cpu: r.meta.cpuThrottle, load: r.meta.hostLoadStart });
}
if (runs.length < 3) { console.error(`\nonly ${runs.length} usable paired runs — not enough`); process.exit(1); }

console.log(`\nPAIRED n=${runs.length}  —  1/${runs[0].cpu} CPU on both ends, ceiling 30f vs 15f, sides alternating`);
console.log(`statistic: within-call difference, BIG minus DEFAULT.\n`);
console.log(`  run              big-cap side   host load   clampedTicks big/def`);
for (const r of runs) {
  console.log(`  ${r.f.padEnd(17)}${r.bigSide.padEnd(15)}${String(r.load).padEnd(12)}${r.big.jitClampedTicks}/${r.def.jitClampedTicks}`);
}

// Metrics fixed in advance. The first two are DELIVERY, the third is COST. Both get
// printed every time; neither is allowed to stand alone.
const METRICS = [
  ['frames concealed        [delivery]', (s) => s.lostFrames],
  ['conceal %               [delivery]', (s) => s.concealPct],
  ['late frames             [delivery]', (s) => s.lateFrames],
  ['playout depth (ms)      [COST]', (s) => s.depthMs],
  ['target frames at end    [COST]', (s) => s.targetFrames],
];

const results = {};
for (const [name, get] of METRICS) {
  const d = runs.map((r) => get(r.big) - get(r.def));
  if (!d.every((x) => Number.isFinite(x))) { console.log(`\n  ${name}: a run is missing this field — NOT TESTED`); continue; }
  const n = d.length;
  const mean = d.reduce((a, b) => a + b, 0) / n;
  const sd = Math.sqrt(d.reduce((a, b) => a + (b - mean) ** 2, 0) / (n - 1));
  const se = sd / Math.sqrt(n);
  const t = se === 0 ? null : mean / se;
  const p = t === null ? null : pFromT(t, n - 1);
  const neg = d.filter((x) => x < 0).length;
  results[name] = { mean, p, neg, n };
  console.log(`\n  ${name}`);
  console.log(`    per-run: ${d.map((x) => x.toFixed(2)).join(', ')}`);
  console.log(`    mean ${mean.toFixed(3)}  sd ${sd.toFixed(3)}  ${t === null ? 't undefined (zero variance)' : `t ${t.toFixed(3)}  p ${p.toFixed(4)}`}`);
  console.log(`    big-ceiling lower in ${neg}/${n} runs`);
  if (se === 0) console.log(`    ZERO VARIANCE — a perfectly repeatable difference needs no significance test.`);
  else if (p < 0.05 && neg !== n && neg !== 0) console.log(`    p < 0.05 but the sign is NOT unanimous (${neg}/${n}) — report the split, not just the p.`);
}

console.log(`\nHOW TO READ THIS`);
console.log(`  A ceiling raise is only a win if a DELIVERY row improves by more than the noise`);
console.log(`  floor AND the COST rows stay flat. If concealment falls while depth rises by a`);
console.log(`  comparable number of milliseconds, nothing was fixed — the delay was moved from`);
console.log(`  the glitch into the conversation, and turn-taking pays for it either way.`);
console.log(`\nWHAT THIS CANNOT SETTLE`);
console.log(`  - 1/8 CPU throttling is CDP's renderer-side stall injection, not a real phone's`);
console.log(`    slower memory, thermals or scheduler. It is a better slow-device proxy than`);
console.log(`    anything this testbed had before, and it is still a proxy.`);
console.log(`  - two Brave instances on one host: a local path, no real internet loss.`);
console.log(`  - the ceiling was reached here by CPU starvation. Whether it should also move`);
console.log(`    under bandwidth scarcity is a different regime and a different measurement:`);
console.log(`    at --bw=0.3 the cap has been measured to clamp 419 of 490 ticks with the`);
console.log(`    estimator asking for 1201 frames, where no ceiling this side of absurd binds.`);
