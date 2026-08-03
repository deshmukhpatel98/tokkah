// Which RS(K, K+n) operating point, and which ladder rungs to go with it.
//
// The metric is EXPECTED CONCEALED FRAMES PER 100 DATA FRAMES, not group
// failure rate. Group failure rate is the wrong thing to optimise and it led
// this project to the wrong candidate once: K=6 n=2 has a group-failure rate
// close to the shipped K=10 n=3 (3.8% vs 3.4%) and looks like a bargain at a
// 48 ms span, but a group of 6 that fails costs fewer frames than a group of
// 10 that fails, so the rates are not comparable. Weighted by group size, K=6
// n=2 is 35% WORSE than shipped. It measured +0.60 pp against a predicted
// +0.39 pp — the model is directional, so use it before spending 20 minutes
// of A/B on a dominated config.
//
//   node testbed/kchoice.mjs            # table + ladder for the default K
//   node testbed/kchoice.mjs 5          # ladder for a candidate K
//
// Span (K x FRAME_MS) is a latency term as well as a deadline term — see the
// "RS span" section of MEASURED.md — so read the span column as a cost, not a
// free parameter.
const FRAME_MS = 8;
const RS_P = 3;             // parity symbols the codec can carry (Cauchy rows)

function binom(n, k) { let r = 1; for (let i = 0; i < k; i++) r = (r * (n - i)) / (i + 1); return r; }

// An RS(K, K+n) group survives iff erasures <= n. If it fails, every erased
// DATA symbol is concealed — the symbols that did arrive still play, so the
// cost is the erasure count, not the whole group.
export function concealPer100(K, n, p) {
  if (n >= K + n) return 0;
  const N = K + n;
  let frames = 0;
  for (let e = n + 1; e <= N; e++) {
    const pe = binom(N, e) * p ** e * (1 - p) ** (N - e);
    frames += pe * e * (K / N);   // K/N of the erasures are data, on average
  }
  return (frames / K) * 100;
}

// The ladder: smallest n whose expected concealment stays under `target`.
// 0.1 per 100 frames is one concealed 8 ms frame every 10 s — below audibility
// for PCM concealment, and the threshold the shipped K=10 rungs happen to sit
// on, which is why they reproduce exactly when you run this at K=10.
export function ladderFor(K, target = 0.1, nMax = RS_P) {
  const rungs = [];
  for (let n = 0; n <= nMax; n++) {
    // highest p this n still covers
    let lo = 0, hi = 0.5;
    if (concealPer100(K, n, hi) <= target) { rungs.push({ n, upTo: hi }); continue; }
    if (concealPer100(K, n, 1e-6) > target) { rungs.push({ n, upTo: 0 }); continue; }
    for (let i = 0; i < 60; i++) {
      const mid = (lo + hi) / 2;
      if (concealPer100(K, n, mid) <= target) lo = mid; else hi = mid;
    }
    rungs.push({ n, upTo: lo });
  }
  return rungs;
}

// Importable: only run the CLI when invoked directly, so `import` from another
// script does not dump the whole table into that script's output.
const isMain = process.argv[1] && import.meta.url.endsWith(process.argv[1].split('/').pop());
const arg = Number(process.argv[2]);
const P = [0.05, 0.10, 0.15, 0.20];

if (!isMain) {
  // nothing — consumer wants concealPer100 / ladderFor only
} else if (!Number.isFinite(arg)) {
  const cands = [[5, 2], [5, 3], [6, 2], [6, 3], [8, 2], [8, 3], [10, 2], [10, 3], [12, 3], [16, 3]];
  console.log('expected concealed frames per 100 data frames\n');
  console.log('K   n  span  redun   ' + P.map(p => `p=${(p * 100).toFixed(0)}%`.padStart(8)).join(''));
  console.log('-'.repeat(20 + 8 * P.length));
  for (const [K, n] of cands) {
    const row = P.map(p => concealPer100(K, n, p).toFixed(2).padStart(8)).join('');
    const tag = (K === 10 && n === 3) ? '   <- shipped default' : '';
    console.log(`${String(K).padEnd(3)} ${n}  ${String(K * FRAME_MS + 'ms').padStart(5)} ` +
      `${String(Math.round(100 * n / K) + '%').padStart(5)}  ${row}${tag}`);
  }
  const base = concealPer100(10, 3, 0.10);
  console.log('\nat p=10%, against the shipped default (span is the price):');
  for (const [K, n] of cands) {
    const c = concealPer100(K, n, 0.10), d = c - base;
    console.log(`  K=${String(K).padEnd(2)} n=${n}  span ${String(K * FRAME_MS).padStart(3)}ms  ` +
      `conceal ${c.toFixed(2)}%  ${d >= 0 ? '+' : ''}${d.toFixed(2)} pp  ` +
      `redundancy ${String(Math.round(100 * n / K)) + '%'}`);
  }
  console.log('\nfor the ladder rungs at a given K:  node testbed/kchoice.mjs <K>');
} else {
  const K = Math.round(arg);
  console.log(`ladder for K=${K} (span ${K * FRAME_MS} ms), target <= 0.1 concealed per 100:\n`);
  const rungs = ladderFor(K);
  for (const { n, upTo } of rungs) {
    const pct = (upTo * 100);
    console.log(`  n=${n}  redundancy ${String(Math.round(100 * n / K)) + '%'}`.padEnd(28) +
      (pct >= 50 ? 'covers any loss' : `covers loss up to ${pct.toFixed(2)}%`));
  }
  console.log('\n  as ladderFor() in pcm.js:');
  const lines = rungs.filter(r => r.n > 0 && r.upTo > 0 && r.upTo < 0.5);
  console.log('    if (pct <= 0) return 0;');
  for (const { n, upTo } of lines) console.log(`    if (pct <= ${(upTo * 100).toFixed(1)}) return ${n};`);
  console.log('    return RS_P;');
  console.log('\n  shipped rungs (K=10) for comparison: 1 @<=1.5%, 2 @<=4%, 3 above');
}
