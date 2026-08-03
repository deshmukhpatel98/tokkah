/**
 * The paired t-test this testbed keeps needing, in one place, with its self-test.
 *
 * Written because the routine had already been hand-copied into two scorers. A copied
 * statistic is a statistic that can diverge silently between runs that get compared to
 * each other, and this project already has an F-test that returned p=0.0143 on two arms
 * that were byte-identical — a wrong p-value looks exactly like a right one.
 *
 * `selfTest()` runs on import and THROWS. A module that cannot compute p must not be
 * allowed to hand one back.
 */
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

/** Two-sided p for a t statistic on `df` degrees of freedom. */
export const pFromT = (t, df) => (df <= 0 ? null : betai(df / 2, 0.5, df / (df + t * t)));

/** Textbook two-sided critical values. Throws rather than warns. */
export function selfTest() {
  const CASES = [[2.306004, 8, 0.05], [2.364624, 7, 0.05], [3.182446, 3, 0.05],
                 [1.959964, 1e7, 0.05], [3.499483, 7, 0.01], [2.570582, 5, 0.05],
                 [4.302653, 2, 0.05]];
  const bad = CASES.filter(([t, df, want]) => Math.abs(pFromT(t, df) - want) > 5e-4);
  if (bad.length) {
    throw new Error(`pairedt self-test FAILED: ` +
      bad.map(([t, df, w]) => `t=${t} df=${df} got ${pFromT(t, df)?.toFixed(5)} want ${w}`).join('; '));
  }
  return CASES.length;
}

/**
 * Paired statistics on one array of within-pair differences.
 * Returns zero-variance explicitly rather than dividing by zero: a perfectly
 * repeatable difference needs no significance test, and `t` there is not "infinite",
 * it is undefined.
 */
export function paired(diffs) {
  const d = diffs.filter((x) => Number.isFinite(x));
  if (d.length !== diffs.length) return { n: d.length, incomplete: true };
  const n = d.length;
  if (n < 2) return { n, tooFew: true };
  const mean = d.reduce((a, b) => a + b, 0) / n;
  const sd = Math.sqrt(d.reduce((a, b) => a + (b - mean) ** 2, 0) / (n - 1));
  const se = sd / Math.sqrt(n);
  const t = se === 0 ? null : mean / se;
  return {
    n, mean, sd, se, t, p: t === null ? null : pFromT(t, n - 1),
    zeroVariance: se === 0,
    negatives: d.filter((x) => x < 0).length,
    diffs: d,
  };
}

const N = selfTest();
export const SELF_TEST_CASES = N;
