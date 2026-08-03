/**
 * Self-test for pcmsw.js — run: node tape-app/public/core/pcmsw.test.mjs
 *
 * Three gates:
 *  1. Correctness: every repaired frame is BIT-EXACT against the original.
 *  2. Repair latency: for random 5% iid loss, measure how many frames after a loss
 *     its repair became solvable — the whole point of the window. Compare against
 *     block RS(10,13)'s position-dependent delay analytically.
 *  3. Failure rate: overlapping windows are not provably MDS; measure unrecovered %
 *     at 5% and 10% iid loss and at 3-frame bursts, against RS(10,13)'s analytic rate.
 */
import { SwEncoder, SwDecoder, SW_WINDOW, SW_STRIDE } from './pcmsw.js';

// VARIABLE frame lengths (the real lane sends Rice-compressed 300-1150 B frames):
// each frame's length is a deterministic function of seq so the test can rebuild it.
const lenOf = (seq) => 32 + ((seq * 17) % 33); // 32..64 B
let fails = 0;
const assert = (ok, msg) => { if (!ok) { console.error(`FAIL: ${msg}`); fails++; } };

// deterministic PRNG so a failure reproduces
let seed = 0xC0FFEE;
const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x80000000;
const mkFrame = (seq) => {
  const f = new Uint8Array(lenOf(seq));
  for (let i = 0; i < f.length; i++) f[i] = (seq * 31 + i * 7 + ((seq * i) % 13)) & 0xff;
  return f;
};

function trial(lossFn, nFrames, label) {
  const enc = SwEncoder();
  const dec = SwDecoder();
  const lost = [];
  const repairDelay = new Map(); // seq -> frames until repaired (or -1 never)
  for (let seq = 1; seq <= nFrames; seq++) {
    const data = mkFrame(seq);
    enc.add(seq, data);
    if (lossFn(seq)) lost.push(seq);
    else dec.frame(seq, data);
    if (enc.due()) {
      const p = enc.parity();
      // parity travels the same link: drop it with the same law
      if (!lossFn(-seq)) dec.parity(p);
    }
    const got = dec.repair(seq);
    for (const [q, buf] of got) {
      const want = mkFrame(q);
      assert(buf.length >= want.length
        && Buffer.compare(Buffer.from(buf.subarray(0, want.length)), Buffer.from(want)) === 0
        && buf.subarray(want.length).every((x) => x === 0),
        `${label}: repaired seq ${q} not bit-exact (padded solve must be original + zero tail)`);
      if (!repairDelay.has(q)) repairDelay.set(q, seq - q);
    }
  }
  const repaired = [...repairDelay.keys()];
  const unrec = lost.filter((q) => !repairDelay.has(q) && q <= nFrames - SW_WINDOW);
  const delays = repaired.map((q) => repairDelay.get(q)).sort((a, b) => a - b);
  const p = (arr, f) => (arr.length ? arr[Math.min(arr.length - 1, Math.floor(f * arr.length))] : null);
  return { lost: lost.length, repaired: repaired.length, unrec: unrec.length,
           delayP50: p(delays, 0.5), delayP95: p(delays, 0.95), delayMax: delays.at(-1) ?? null };
}

// Gate 1+2+3 at 5% iid
{
  const r = trial(() => rnd() < 0.05, 20000, '5% iid');
  const unrecPct = (100 * r.unrec / Math.max(1, r.lost)).toFixed(2);
  console.log(`5% iid : lost ${r.lost}  repaired ${r.repaired}  unrecovered ${r.unrec} (${unrecPct}% of losses)`);
  console.log(`         repair delay frames p50 ${r.delayP50}  p95 ${r.delayP95}  max ${r.delayMax}  (x8 for ms)`);
  // RS(10,13) at 5% iid: P(group unrecoverable) = P(>3 of 13 lost) — per-loss residual ~1.2%.
  assert(r.unrec / Math.max(1, r.lost) < 0.03, `5% iid unrecovered ${unrecPct}% — worse than 3%`);
  assert(r.delayP95 <= SW_WINDOW, `p95 repair delay ${r.delayP95} exceeds the window`);
}
// 10% iid
{
  const r = trial(() => rnd() < 0.10, 20000, '10% iid');
  console.log(`10% iid: lost ${r.lost}  repaired ${r.repaired}  unrecovered ${r.unrec} (${(100 * r.unrec / Math.max(1, r.lost)).toFixed(2)}%)`);
  console.log(`         repair delay frames p50 ${r.delayP50}  p95 ${r.delayP95}  max ${r.delayMax}`);
}
// 3-frame bursts, one per ~100 frames
{
  let burstAt = -10;
  const r = trial((seq) => {
    if (seq < 0) return rnd() < 0.05; // parity loss stays iid
    if (seq >= burstAt && seq < burstAt + 3) return true;
    if (rnd() < 0.01) burstAt = seq + 1;
    return false;
  }, 20000, 'bursts');
  console.log(`3-burst: lost ${r.lost}  repaired ${r.repaired}  unrecovered ${r.unrec} (${(100 * r.unrec / Math.max(1, r.lost)).toFixed(2)}%)`);
  console.log(`         repair delay frames p50 ${r.delayP50}  p95 ${r.delayP95}  max ${r.delayMax}`);
  assert(r.unrec / Math.max(1, r.lost) < 0.10, `burst unrecovered too high`);
}
// Overhead accounting
console.log(`overhead: 1 parity per ${SW_STRIDE} data frames = ${(100 / SW_STRIDE).toFixed(0)}% (RS(10,13) = 30%)`);

if (fails) { console.error(`\n${fails} FAILURES`); process.exit(1); }
console.log('\nALL GATES PASS');
