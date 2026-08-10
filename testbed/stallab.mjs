/**
 * Interleaved cc-vs-cw stall count. n=1 per pairing cannot separate "WebKit causes
 * stalls" from "the host was in a bad mood during that run", and the two runs so far
 * were minutes apart. Alternating arms puts both pairings through the same host
 * conditions, which is the only way the difference means anything.
 *
 * Counts stalls in the 24-200 ms band ONLY: the multi-second freezes are host-level
 * (they appear in BOTH pairings, simultaneously on both sides, to within 0.4 ms) and
 * would swamp the band under test.
 *   node testbed/stallab.mjs [reps]
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
const REPS = Number(process.argv[2] ?? 2);
const out = { cc: [], cw: [] };
for (let r = 0; r < REPS; r++) {
  for (const eng of ['cc', 'cw']) {
    const j = `/Users/deveshpatel/Downloads/video calling/testbed/out/sab-${eng}-${r}.json`;
    try {
      execFileSync('node', ['/Users/deveshpatel/Downloads/video calling/testbed/rig.mjs',
        `--engines=${eng}`, '--sec=60', '--every=60', '--wait=400', `--json=${j}`],
        { stdio: 'ignore', timeout: 600000 });
    } catch { /* rig exits 1 on a failed picture gate; the json is still written */ }
    if (!fs.existsSync(j)) { console.log(`rep${r} ${eng}: no json (aborted early)`); continue; }
    const d = JSON.parse(fs.readFileSync(j, 'utf8'));
    const band = (l) => (l ?? []).filter((x) => x.g >= 24 && x.g <= 200).length;
    const big = (l) => (l ?? []).filter((x) => x.g > 200).length;
    const n = band(d.stalls?.A) + band(d.stalls?.B);
    const nb = big(d.stalls?.A) + big(d.stalls?.B);
    const sl = d.calibration?.lag ? Math.max(d.calibration.lag.A.p95, d.calibration.lag.B.p95) : null;
    out[eng].push(n);
    console.log(`rep${r} ${eng}: ${n} stalls in 24-200ms band, ${nb} over 200ms, sched p95 ${sl} ms`);
  }
}
const mean = (a) => (a.length ? a.reduce((x, y) => x + y, 0) / a.length : null);
console.log(`\ncc mean ${mean(out.cc)}  (${out.cc.join(',')})`);
console.log(`cw mean ${mean(out.cw)}  (${out.cw.join(',')})`);
console.log(mean(out.cw) > 3 * Math.max(1, mean(out.cc))
  ? '\nCross-engine really does add stalls, under matched host conditions.'
  : '\nNo reliable pairing effect: the earlier difference was the host, not the engine.');
