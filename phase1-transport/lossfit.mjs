/**
 * Fit throughput against measured packet loss, and report the loss a loss-based congestion
 * controller can tolerate before it stops carrying the design's bitrate.
 *
 * Why fit rather than quote a textbook: the Mathis bound, BW ≈ C·MSS/(RTT·√p), has a constant
 * that depends on the ACK strategy, delayed-ACK behaviour and the loss model, and published
 * values for C range from about 0.9 to 1.5. That is a factor of 1.6 on the answer, which is the
 * difference between "this transport works on good paths" and "it does not." So both the exponent
 * and the constant are taken from our own measurements. The exponent is the real test: AIMD
 * predicts −0.5, and if the data does not show that, the mechanism is something else and the
 * extrapolation has no basis.
 *
 * Loss is the MEASURED application-level rate, not the emulator's requested rate — those differ
 * by about 2.5x because a relayed packet crosses the delay proxy more times than the emulator's
 * model assumed. Using the requested rate would shift the x-axis by that factor.
 *
 * Usage: node lossfit.mjs
 */

// 80 ms RTT, 12 Mbps target, 25 s soak, forced through a TURN relay.
// [measured app-level loss %, median received Mbps]
// Two x-axes, deliberately, because they bracket a real methodological worry.
//
// MEASURED is app-level loss: what the receiver actually missed. It is the physically right
// variable, but it is not fully independent of the y-axis — about half of it is excess over what
// the delay line injected, and the excess grows with severity, which points at usrsctp shedding
// from its own buffers once the window collapses. If some measured loss is *caused by* the
// collapse, regressing throughput on it is partly circular.
//
// INJECTED is what the delay line applied, computed from its own drop counters over the two
// crossings a one-way trip makes (the delay model says two, and ICE agrees to 0.1 ms). It is set
// by us and cannot be influenced by the transport, so it breaks the circularity — at the cost of
// undercounting the loss the peers really saw.
//
// The truth is bracketed by the pair. Both are reported; if they disagree about whether this
// transport can carry the design's bitrate, that disagreement is the finding.
const AXES = {
  measured: [
    [0.617, 2.12],
    [1.281, 1.55],
    [2.169, 1.11],
    [3.643, 0.78],
  ],
  injected: [
    [0.310, 2.12],
    [0.490, 1.55],
    [1.058, 1.11],
    [1.971, 0.78],
  ],
};
const WHICH = process.argv[2] === 'injected' ? 'injected' : 'measured';
const POINTS = AXES[WHICH];

const TARGET_MBPS = 12;
const RTT_MS = 80;

// Least squares on log(BW) = log(A) + b·log(p).
const xs = POINTS.map(([p]) => Math.log(p / 100));
const ys = POINTS.map(([, bw]) => Math.log(bw));
const n = xs.length;
const mx = xs.reduce((a, b) => a + b) / n;
const my = ys.reduce((a, b) => a + b) / n;
const b = xs.reduce((s, x, i) => s + (x - mx) * (ys[i] - my), 0) / xs.reduce((s, x) => s + (x - mx) ** 2, 0);
const logA = my - b * mx;
const A = Math.exp(logA);

const predict = (lossPct) => A * Math.pow(lossPct / 100, b);
// Invert: what loss still carries TARGET_MBPS?
const lossFor = (mbps) => Math.pow(mbps / A, 1 / b) * 100;

// R² so the fit's quality is stated rather than assumed.
const ssTot = ys.reduce((s, y) => s + (y - my) ** 2, 0);
const ssRes = ys.reduce((s, y, i) => s + (y - (logA + b * xs[i])) ** 2, 0);

console.log(`\n  Throughput vs ${WHICH.toUpperCase()} loss — ${RTT_MS} ms RTT, ${TARGET_MBPS} Mbps offered, relayed\n`);
console.log('    loss            median recv   fit');
for (const [p, bw] of POINTS) {
  console.log(`    ${p.toFixed(3).padStart(9)}%   ${bw.toFixed(2).padStart(9)}    ${predict(p).toFixed(2)}`);
}
console.log(`\n  fit: BW = ${A.toFixed(4)} · p^${b.toFixed(3)}   (R² = ${(1 - ssRes / ssTot).toFixed(4)})`);
console.log(`  AIMD / loss-based congestion control predicts an exponent of -0.5.`);
console.log(
  `  Measured ${b.toFixed(3)} — ${Math.abs(b + 0.5) < 0.07 ? 'consistent. The controller is the constraint, not the emulator.' : 'NOT consistent; mechanism unclear.'}`,
);

console.log(`\n  What this transport can carry, extrapolated:\n`);
console.log('    path loss     ceiling      verdict at 12 Mbps');
for (const p of [0.01, 0.024, 0.05, 0.1, 0.5, 1]) {
  const bw = predict(p);
  console.log(
    `    ${p.toFixed(3).padStart(7)}%   ${bw.toFixed(2).padStart(6)} Mbps   ${bw >= TARGET_MBPS ? 'carries it' : `short by ${(TARGET_MBPS - bw).toFixed(1)} Mbps`}`,
  );
}
const need = lossFor(TARGET_MBPS);
console.log(
  `\n  To carry ${TARGET_MBPS} Mbps at ${RTT_MS} ms RTT the path must lose less than ` +
    `${need.toFixed(4)}% — about 1 packet in ${Math.round(100 / need).toLocaleString()}.\n`,
);
