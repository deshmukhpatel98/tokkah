/**
 * m2e-ab.mjs — the clean-path budget, measured properly.
 *
 * m2e-decompose runs ONE call and prints medians. That is fine for reading a
 * breakdown and useless for grading a change, because the metric's run-to-run
 * spread is about 7 ms (42.4-49.2 observed in a single day) — wider than most
 * changes worth making. Reading one call per arm produced, in one session: a
 * "20% improvement" that was 4%, a -139 ms latency claim that did not
 * replicate, and a 4 ms ping "regression" that was contradicted by the next
 * run after the default had already been changed on the strength of it.
 *
 * So: N PAIRED ROUNDS with the ARM ORDER ALTERNATED. Order matters because the
 * two calls in a pair are not exchangeable — the first pays for a cold page,
 * cold encoder and cold host — and a fixed order feeds that entirely to one
 * arm. The verdict is the median of per-round deltas, every round printed, and
 * UNRESOLVED whenever the rounds straddle zero.
 *
 *   node testbed/m2e-ab.mjs --repeat=3 --on='' --off='&pcmpingms=2000'
 *
 * Run it against ITSELF first (--on and --off identical). That null A/B is the
 * resolution limit, and anything smaller is the instrument talking.
 */
import { spawnSync } from 'node:child_process';

const arg = (k, d) => process.argv.find((a) => a.startsWith(`--${k}=`))?.slice(k.length + 3) ?? d;
const REPEAT = Math.max(1, Number(arg('repeat', '3')) || 3);
const ON = arg('on', '');
const OFF = arg('off', '&pcmpingms=2000');

const runOne = (qs, label) => {
  process.stdout.write(`  [${label}] qs=[${qs}] ... `);
  const r = spawnSync(process.execPath, ['testbed/m2e-decompose.mjs', `--qs=${qs}`],
    { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  const line = (r.stdout ?? '').split('\n').find((l) => l.startsWith('M2ERESULT '));
  if (!line) { console.log('NO RESULT'); return null; }
  const v = JSON.parse(line.slice(10));
  const m2e = ((v.m2eA ?? NaN) + (v.m2eB ?? NaN)) / 2;
  const ring = ((v.ringA ?? NaN) + (v.ringB ?? NaN)) / 2;
  console.log(`m2e ${m2e.toFixed(1)} ms, ring ${ring.toFixed(1)} ms`);
  return { m2e, ring, out: ((v.outA ?? NaN) + (v.outB ?? NaN)) / 2 };
};

const rounds = [];
for (let r = 0; r < REPEAT; r++) {
  const onFirst = r % 2 === 0;              // alternate; see the header
  console.log(`[round ${r + 1}/${REPEAT}] ${onFirst ? 'ON first' : 'OFF first'}`);
  const a = runOne(onFirst ? ON : OFF, onFirst ? 'ON ' : 'OFF');
  const b = runOne(onFirst ? OFF : ON, onFirst ? 'OFF' : 'ON ');
  const [on, off] = onFirst ? [a, b] : [b, a];
  if (on && off) rounds.push({ on, off });
  else console.log(`[round ${r + 1}] DROPPED (a call produced no result)`);
}

if (!rounds.length) { console.log('VERDICT: UNMEASURABLE'); process.exit(2); }
if (rounds.length < REPEAT) console.log(`NOTE: ${REPEAT - rounds.length} of ${REPEAT} rounds dropped`);

const median = (xs) => {
  const s = [...xs].sort((x, y) => x - y);
  return s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2;
};
console.log(`\n── ${rounds.length} paired round(s), ON=[${ON}] OFF=[${OFF}] ──`);
for (const [name, key] of [['mouth-to-ear', 'm2e'], ['ring depth  ', 'ring'], ['output path ', 'out']]) {
  const per = rounds.map((r) => r.on[key] - r.off[key]);
  const med = median(per);
  const straddles = Math.min(...per) < 0 && Math.max(...per) > 0;
  console.log(`${name}: ON ${median(rounds.map((r) => r.on[key])).toFixed(1)} ms vs OFF `
    + `${median(rounds.map((r) => r.off[key])).toFixed(1)} ms  ->  median delta `
    + `${med > 0 ? '+' : ''}${med.toFixed(1)} ms  [per-round ${per.map((d) => (d > 0 ? '+' : '') + d.toFixed(1)).join(', ')}]`
    + (rounds.length < 2 ? '  (1 round: NOT RESOLVABLE)' : straddles ? '  (UNRESOLVED: rounds straddle zero)' : ''));
}
