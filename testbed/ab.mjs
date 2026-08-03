// canvas vs <video> for the far-end surface, repeated and interleaved.
//
// A single run of each said 23.8 vs 21.1 ms — but the canvas arm had measured
// 27.2 ms on the identical build minutes earlier. Run-to-run spread (3.4 ms) was
// larger than the effect (2.7 ms), so n=1 each could not tell them apart.
//
// Interleaved A,B,A,B so that anything drifting over the session (thermal, CPU
// contention from other work) hits both arms equally instead of loading onto
// whichever ran second.
import { execFileSync } from 'node:child_process';

const TB = '/Users/earningsgpt/video calling/testbed';
const REPS = Number(process.env.REPS ?? 4);
// SEC=40 for anything with a warm-up: the adaptive code rate spends its first
// ~5.6 s at the starting rung (no loss report can exist until LOSS_LAG +
// LOSS_WIN frames have been seen), so a 20 s run averages a third of its bytes
// over a state no real call spends its time in.
const SEC = Number(process.env.SEC ?? 20);

// node ab.mjs "label=qs" "label=qs"            (empty qs = shipping default)
//
// An arm whose value starts with `--` is passed to competitor.mjs as raw flags
// instead of as an app query string, so the two arms can sit on DIFFERENT
// emulated networks: "clean=--rtt=80" vs "loss5=--rtt=80 --loss=5". Splitting
// here rather than in a shell variable is deliberate — zsh does not word-split
// unquoted expansions, and "--rtt=80 --loss=5" arriving as one argv entry is
// exactly how a run once reported clean numbers under a lossy heading.
const ARMS = process.argv.length > 2
  ? process.argv.slice(2).map((a) => {
      const i = a.indexOf('=');
      const label = a.slice(0, i), val = a.slice(i + 1);
      if (!val) return [label, []];
      return [label, val.startsWith('--') ? val.split(/\s+/) : [`--qs=${val}`]];
    })
  : [['canvas   (default)', []], ['<video>  (l2canvas=0)', ['--qs=l2canvas=0']]];

const got = new Map(ARMS.map(([n]) => [n, []]));

for (let r = 0; r < REPS; r++) {
  for (const [name, extra] of ARMS) {
    let out = '';
    try {
      // NET="--rtt=80 --loss=1" puts both arms on the same emulated network. It goes
      // to every arm by construction, so a network condition can never end up applied
      // to one arm only — which would look exactly like a lane difference.
      // --dump unconditionally: it only adds printing, and the audio lane's
      // numbers (conceal, bytes per parity) live behind it. An A/B that could
      // not see them would be blind to every change made to lane A.
      out = execFileSync('node', [`${TB}/competitor.mjs`, '--self', '--dump', `--sec=${SEC}`,
                                  ...(process.env.NET ? process.env.NET.split(/\s+/) : []), ...extra],
        { cwd: TB, encoding: 'utf8', timeout: 300000 });
    } catch (e) { out = String(e.stdout ?? ''); }
    const m = out.match(/glass-to-glass p50 ([\d.]+) ms, p95 ([\d.]+) ms/);
    if (!m) { console.log(`  rep${r + 1} ${name}: NO RESULT (rig refused or failed) — not counted`); continue; }
    // Delivery travels with latency or the comparison is worthless: an arm that
    // drops frames and shows the rest promptly wins on p50 alone. Taken from the
    // winning candidate's row, which is the one the result line was computed from.
    const c = out.match(/cov ([\d.]+)%[^\n]*\n[\s\S]*?=== result ===/) ?? out.match(/cov ([\d.]+)%/);
    const cov = c ? +c[1] : null;
    // Audio: the mean of the two directions. Both ends run the same build on the
    // same emulated link, so a large asymmetry is noise, not a finding — and a
    // one-sided reading would let a lucky direction carry the arm.
    const cs = [...out.matchAll(/-> conceal ([\d.]+)%/g)].map((x) => +x[1]);
    const conceal = cs.length ? cs.reduce((x, y) => x + y, 0) / cs.length : null;
    const ps = [...out.matchAll(/bPerParity (\d+)/g)].map((x) => +x[1]);
    const bPar = ps.length ? Math.round(ps.reduce((x, y) => x + y, 0) / ps.length) : null;
    // What the audio lane actually costs, in Mbps offered. For the adaptive
    // code rate this is the axis the change is FOR — concealment is the axis it
    // must not move. An A/B that reported only concealment would score this
    // change t = 0 and call it worthless.
    const ms = [...out.matchAll(/mbpsSent ([\d.]+)/g)].map((x) => +x[1]);
    const mbps = ms.length ? ms.reduce((x, y) => x + y, 0) / ms.length : null;
    // The rate in force at the end of each rep, so a summary can never average
    // over reps where the ladder silently failed to engage.
    const fs = [...out.matchAll(/fecN (\d+)\/3/g)].map((x) => +x[1]);
    const fecN = fs.length ? fs.reduce((x, y) => x + y, 0) / fs.length : null;
    // INSTRUMENT THE INSTRUMENT. An arm that offers more packets can lose a lane
    // to the EMULATOR rather than to the link: bwDropped is the shaper actually
    // binding, sendErrors is the rig failing to keep up. Both look exactly like
    // a real regression in cov. If these differ between arms, the comparison is
    // about the rig and not about the build — check before believing a delta.
    const bw = out.match(/bwDropped \d+ \(([\d.]+)%\)/);
    const se = out.match(/sendErrors \d+ \(([\d.]+)%\)/);
    const bwDrop = bw ? +bw[1] : null;
    const sendErr = se ? +se[1] : null;
    got.get(name).push({ p50: +m[1], p95: +m[2], cov, conceal, bPar, mbps, fecN, bwDrop, sendErr });
    console.log(`  rep${r + 1} ${name.padEnd(22)} p50 ${m[1].padStart(5)}  p95 ${m[2].padStart(5)}` +
                `  cov ${cov == null ? '   ?' : String(cov).padStart(5)}%` +
                `  conceal ${conceal == null ? '  ?' : conceal.toFixed(2).padStart(5)}%` +
                `  bPar ${bPar ?? '?'}  mbps ${mbps == null ? '?' : mbps.toFixed(3)}` +
                `  fecN ${fecN == null ? '?' : fecN.toFixed(1)}` +
                (bwDrop ? `  bwDrop ${bwDrop}%` : '') + (sendErr ? `  sendErr ${sendErr}%` : ''));
  }
}

const stat = (xs) => {
  const n = xs.length, mean = xs.reduce((a, b) => a + b, 0) / n;
  const sd = Math.sqrt(xs.reduce((a, b) => a + (b - mean) ** 2, 0) / Math.max(1, n - 1));
  return { n, mean, sd, min: Math.min(...xs), max: Math.max(...xs) };
};

console.log('\n=== summary ===');
const s = {};
for (const [name] of ARMS) {
  const rows = got.get(name);
  if (!rows.length) { console.log(`${name}: no runs`); continue; }
  s[name] = stat(rows.map((r) => r.p50));
  const q = stat(rows.map((r) => r.p95));
  const covs = rows.map((r) => r.cov).filter((x) => x != null);
  const cv = covs.length ? stat(covs) : null;
  const cns = rows.map((r) => r.conceal).filter((x) => x != null);
  const cn = cns.length ? stat(cns) : null;
  const bps = rows.map((r) => r.bPar).filter((x) => x != null);
  console.log(`${name.padEnd(22)} p50 ${s[name].mean.toFixed(1)} +/- ${s[name].sd.toFixed(1)} ms (n=${s[name].n}, ${s[name].min}-${s[name].max})   p95 ${q.mean.toFixed(1)} +/- ${q.sd.toFixed(1)}` +
              (cv ? `   delivered ${cv.mean.toFixed(1)} +/- ${cv.sd.toFixed(1)}% (${cv.min}-${cv.max})` : ''));
  if (cn) console.log(`${' '.repeat(22)} audio conceal ${cn.mean.toFixed(2)} +/- ${cn.sd.toFixed(2)}% (${cn.min}-${cn.max})` +
              (bps.length ? `   bPerParity ${Math.round(bps.reduce((x, y) => x + y, 0) / bps.length)} B` : ''));
  const mbs = rows.map((r) => r.mbps).filter((x) => x != null);
  const fns = rows.map((r) => r.fecN).filter((x) => x != null);
  if (mbs.length) {
    const mb = stat(mbs);
    console.log(`${' '.repeat(22)} lane ${mb.mean.toFixed(3)} +/- ${mb.sd.toFixed(3)} Mbps (${mb.min}-${mb.max})` +
      (fns.length ? `   mean fecN ${(fns.reduce((x, y) => x + y, 0) / fns.length).toFixed(2)}` : ''));
  }
  // Rig health per arm. A delivery difference is only about the BUILD if the
  // emulator behaved the same for both arms; unequal bwDropped means the arms
  // were shaped differently, and any sendErrors at all means the rig dropped
  // packets it was asked to carry.
  const bds = rows.map((r) => r.bwDrop).filter((x) => x != null);
  const ses = rows.map((r) => r.sendErr).filter((x) => x != null);
  if (bds.length || ses.length) {
    const b = bds.length ? stat(bds) : null, e = ses.length ? stat(ses) : null;
    console.log(`${' '.repeat(22)} rig  ` +
      (b ? `bwDropped ${b.mean.toFixed(2)} +/- ${b.sd.toFixed(2)}% (${b.min}-${b.max})` : '') +
      (e ? `   sendErrors ${e.mean.toFixed(2)}%${e.max > 0 ? '  <- NONZERO, rig may be the bottleneck' : ''}` : ''));
  }
}

// Welch's t on both axes. Latency alone used to be the only test here, and under
// loss that is the WRONG axis: at RTT 80 / 5% loss the p50 is dominated by
// propagation delay and moves for nobody, while the thing that actually varies
// between arms is how many frames arrive at all (a hold-deadline expiry drops
// ~8-10 frames at once and leaves p50 untouched). An arm can win decisively on
// delivery and score t = 0 on latency.
const welch = (a, b, unit, note) => {
  if (!a || !b || a.n < 2 || b.n < 2) return;
  const diff = a.mean - b.mean;
  const se = Math.sqrt(a.sd ** 2 / a.n + b.sd ** 2 / b.n);
  console.log(`\n${note}: difference ${diff.toFixed(2)} ${unit} (arm 1 minus arm 2)`);
  // Zero pooled error is not "no signal" — it is the strongest signal this rig
  // can produce, and a t-test cannot express it (diff/0). It happens on
  // quantities that are derived rather than sampled: the audio lane's offered
  // rate is set by the code rate, so every rep of an arm returns the identical
  // number. Scoring that 0.195 Mbps difference as `t = 0.00, do not claim a
  // winner` is the instrument contradicting itself, so say what actually held.
  if (se === 0) {
    console.log(diff === 0
      ? `  identical in all ${a.n}+${b.n} reps — no difference at all`
      : `  zero spread within BOTH arms over ${a.n}+${b.n} reps  ->  EXACT, not statistical` +
        ` (every rep of each arm returned the same value)`);
    return;
  }
  const t = diff / se;
  console.log(`  pooled standard error ${se.toFixed(2)} ${unit}  ->  t = ${t.toFixed(2)}  ` +
    (Math.abs(t) >= 2.5 ? 'DISTINGUISHABLE' : 'not distinguishable — do not claim a winner'));
};
const pick = (f) => ARMS.map(([n]) => {
  const xs = (got.get(n) ?? []).map(f).filter((x) => x != null);
  return xs.length ? stat(xs) : null;
});
const [a, b] = ARMS.map(([n]) => s[n]);
welch(a, b, 'ms', 'latency p50');
const [ca, cb] = pick((r) => r.cov);
welch(ca, cb, '%', 'delivered');
const [na, nb] = pick((r) => r.conceal);
welch(na, nb, '%', 'audio conceal (lower is better)');
const [ma, mb] = pick((r) => r.mbps);
welch(ma, mb, 'Mbps', 'audio lane offered rate (lower is cheaper)');
