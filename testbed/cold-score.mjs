/**
 * Scores the cold-cache pairs from cold.sh.
 *
 * WRITTEN BEFORE THE DATA ARRIVES. Metrics, sign convention and the noise-floor rule are
 * fixed here in advance.
 *
 * THE QUESTION: a first-time visitor on a slow device has to fetch and parse the whole
 * bundle on a main thread running at 1/8 speed, while the call is already starting. Does
 * that cost the audio lane anything a returning visitor does not pay?
 *
 * THE DESIGN: one cold side and one warm side in the SAME 40 s call, alternating which
 * side is cold. The call is then its own control for host load, fixture, network and
 * clock. Running cold and warm as separate calls would have to absorb a between-call
 * concealment spread measured at 0.24%-4.38% — larger than any effect worth finding.
 *
 * SIGN: every difference is COLD minus WARM, so positive means the first-time visitor
 * paid for it.
 *
 *   node testbed/cold-score.mjs
 */
import fs from 'node:fs';
import { paired, SELF_TEST_CASES } from './pairedt.mjs';

const DIR = '/private/tmp/claude-501/-Users-earningsgpt-video-calling/477cd6ea-c192-43a3-b107-a2011157fa96/scratchpad/cold';
console.log(`  pairedt self-test: ${SELF_TEST_CASES} textbook critical values reproduced`);

const load = (f) => { try { return JSON.parse(fs.readFileSync(`${DIR}/${f}`, 'utf8')); } catch { return null; } };
const files = fs.existsSync(DIR) ? fs.readdirSync(DIR).filter((f) => f.endsWith('.json')).sort() : [];
if (!files.length) { console.error(`no reports in ${DIR}`); process.exit(1); }
const both = (r) => r?.sides?.brave && r?.sides?.peer;

// ── noise floor first ────────────────────────────────────────────────────────────
// Both sides warm, everything else identical. This is what any claimed effect has to
// clear, and it is measured rather than assumed.
console.log(`\nNOISE FLOOR — neither side cold, both ends of one call`);
const floors = [];
for (const f of files.filter((x) => x.startsWith('eq'))) {
  const r = load(f); if (!both(r)) continue;
  const a = r.sides.brave, b = r.sides.peer;
  floors.push({ conceal: b.concealPct - a.concealPct, depth: b.depthMs - a.depthMs,
                late: b.lateFrames - a.lateFrames, gapP99: b.gapP99 - a.gapP99 });
  console.log(`  ${f.padEnd(10)} conceal ${a.concealPct}% vs ${b.concealPct}%   depth ${a.depthMs} vs ${b.depthMs} ms   ` +
    `gapP99 ${a.gapP99} vs ${b.gapP99} ms   late ${a.lateFrames} vs ${b.lateFrames}`);
}
if (!floors.length) console.log(`  (none yet — the floor runs are last in cold.sh)`);
const floorOf = (k) => (floors.length ? Math.max(...floors.map((x) => Math.abs(x[k]))) : null);
if (floors.length) {
  console.log(`  floor (largest |B-A| with both warm): conceal ${floorOf('conceal').toFixed(3)} pp, ` +
    `depth ${floorOf('depth').toFixed(1)} ms, gapP99 ${floorOf('gapP99').toFixed(2)} ms, late ${floorOf('late')}`);
}

// ── the pairs ────────────────────────────────────────────────────────────────────
const runs = [];
for (const f of files.filter((x) => /^[ab]\d/.test(x))) {
  const r = load(f);
  if (!both(r)) { console.log(`  skip ${f}: a side is missing — the run did not finish`); continue; }
  const sides = [r.sides.brave, r.sides.peer];
  const cold = sides.find((s) => s.cold === true);
  const warm = sides.find((s) => s.cold === false);
  if (!cold || !warm) {
    console.log(`  skip ${f}: cold flags are ${sides.map((s) => s.cold).join('/')} — ` +
      `not one cold and one warm, so this run has no within-call contrast`);
    continue;
  }
  runs.push({ f, cold, warm, coldSide: cold === r.sides.brave ? 'A' : 'B',
              cpu: r.meta.cpuThrottle, load: r.meta.hostLoadStart });
}
if (runs.length < 3) { console.error(`\nonly ${runs.length} usable pairs — not enough`); process.exit(1); }

console.log(`\nPAIRED n=${runs.length}  —  1/${runs[0].cpu} CPU both ends, one cold side per call, alternating`);
console.log(`sign: COLD minus WARM, so POSITIVE means the first-time visitor paid.\n`);
console.log(`  run        cold side   host load   D cold / D warm (s)`);
for (const r of runs) {
  console.log(`  ${r.f.padEnd(11)}${r.coldSide.padEnd(12)}${String(r.load).padEnd(12)}` +
    `${r.cold.graphDelayS} / ${r.warm.graphDelayS}`);
}

const METRICS = [
  ['conceal %                 [delivery]', (s) => s.concealPct, 'pp', 'conceal'],
  ['frames concealed          [delivery]', (s) => s.lostFrames, '', null],
  ['late frames               [delivery]', (s) => s.lateFrames, '', 'late'],
  ['arrival gap p99 (ms)      [cause]', (s) => s.gapP99, 'ms', 'gapP99'],
  ['arrival clumped %         [cause]', (s) => s.gapClumpPct, 'pp', null],
  ['jitter spread (ms)        [cause]', (s) => s.jitSpreadMs, 'ms', null],
  ['playout depth (ms)        [COST]', (s) => s.depthMs, 'ms', 'depth'],
  ['graph race D (s)          [startup]', (s) => s.graphDelayS, 's', null],
];

for (const [name, get, unit, floorKey] of METRICS) {
  const res = paired(runs.map((r) => get(r.cold) - get(r.warm)));
  console.log(`\n  ${name}`);
  if (res.incomplete) { console.log(`    only ${res.n}/${runs.length} runs carry this field — NOT TESTED`); continue; }
  console.log(`    per-run: ${res.diffs.map((x) => x.toFixed(2)).join(', ')}`);
  console.log(`    mean ${res.mean.toFixed(3)} ${unit}  sd ${res.sd.toFixed(3)}  ` +
    `${res.zeroVariance ? 't undefined (zero variance)' : `t ${res.t.toFixed(3)}  p ${res.p.toFixed(4)}`}`);
  console.log(`    cold LOWER in ${res.negatives}/${res.n} runs  (so cold higher in ${res.n - res.negatives})`);
  const fl = floorKey ? floorOf(floorKey) : null;
  if (fl !== null) {
    const clears = Math.abs(res.mean) > fl;
    console.log(`    noise floor for this metric is ${fl.toFixed(3)} ${unit} — this effect ${clears ? 'CLEARS it' : 'does NOT clear it'}`);
  }
  if (res.zeroVariance) console.log(`    ZERO VARIANCE — perfectly repeatable, no significance test needed or possible.`);
  else if (res.p < 0.05 && res.negatives !== 0 && res.negatives !== res.n) {
    console.log(`    p < 0.05 but the sign is NOT unanimous — report the split, not just the p.`);
  }
}

console.log(`\nHOW TO READ THIS`);
console.log(`  A [cause] row moving with a [delivery] row is a mechanism. A [delivery] row moving`);
console.log(`  with no [cause] row behind it is a number, and probably noise at this n.`);
console.log(`\nWHAT THIS CANNOT SETTLE`);
console.log(`  - CDP cache clearing empties the HTTP cache but NOT the compiled-code cache the`);
console.log(`    same way a truly first-ever visit would, and both profiles have loaded this`);
console.log(`    origin many times today. So this UNDERSTATES a real first visit.`);
console.log(`  - 1/8 CPU is CDP renderer stall injection, not a phone's memory or thermals.`);
console.log(`  - the 15-frame ceiling does not bind in this regime (jitClampedTicks 0), so`);
console.log(`    nothing here says anything about the buffer cap.`);
