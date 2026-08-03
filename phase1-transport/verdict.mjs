/**
 * Re-read a saved gate run and print the verdicts.
 *
 * Exists because the first matrix run printed `RESULTS INVALID` for every cell on account of a
 * bug in the *driver's* validity check — it compared the harness's `pathType` against `'relay'`
 * when the harness reports `'RELAY (TURN)'`. The measurements were fine; only the printing was
 * wrong. That is a good argument for keeping every 200 ms bucket in the run file and making the
 * verdict a pure function of it: a run that takes ten minutes should never have to be repeated
 * because of a typo in a `console.log`.
 *
 * Usage: node verdict.mjs [runs/gate-….json]   (defaults to the newest run)
 */

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const RUNS = join(HERE, 'runs');

const file =
  process.argv[2] ??
  join(
    RUNS,
    readdirSync(RUNS)
      .filter((f) => f.endsWith('.json'))
      .sort()
      .pop() ?? '',
  );
if (!existsSync(file)) {
  console.error('no run file found');
  process.exit(1);
}

const cells = JSON.parse(readFileSync(file, 'utf8'));

// Clip to the send span — first bucket the pacer wrote in, last bucket it wrote in — before any
// statistic is taken. Buckets after the final write are drained channel, not measurement, and a
// p5 with a fifth of its samples reading structural zero is not a floor. See the long note on
// `verdict()` in public/stats.js: this exact tail turned three passing cells into reported
// collapse. Every bucket *inside* the span is kept, blocked-sender ones included.
const sendSpan = (rows) => {
  const wrote = rows.map((r, i) => (r.sentMbps >= 0.01 ? i : -1)).filter((i) => i >= 0);
  return wrote.length ? rows.slice(wrote[0], wrote[wrote.length - 1] + 1) : [];
};
const pct = (xs, p) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))];
};

console.log(`\n  ${file}\n`);

let passed = 0;
let judged = 0;
for (const c of cells) {
  const s = c.setting;
  const label = s.nosim
    ? 'no simulator'
    : `${s.rttMs} ms RTT, ${s.lossPct}% loss${s.jitterMs ? `, ${s.jitterMs} ms jitter` : ''}`;
  console.log(`  ── ${label} — ${s.mode}${s.mode === 'soak' ? ` @ ${s.target} Mbps` : ''}, ${s.sec} s/step`);

  // Validity first, and stated in terms of what it invalidates rather than as a bare flag.
  const bad = [];
  if (c.a.wasHidden || c.b.wasHidden) bad.push('a renderer was backgrounded — timers throttled');
  if (!s.nosim) {
    if (!c.a.forcedRelay || !c.b.forcedRelay) bad.push('media bypassed the relay, so no distance was applied');
    if (c.a.pathType && !/relay/i.test(c.a.pathType)) bad.push(`path is ${c.a.pathType}, not a relay`);
  }
  if (c.proxyLag && c.proxyLag.p95 > 20)
    bad.push(
      `delay line starved — loop lag p95 ${c.proxyLag.p95} ms (max ${c.proxyLag.max} ms), ` +
        `host load ${c.hostLoad?.[0] ?? '?'} on ${c.cores ?? '?'} cores`,
    );
  if (bad.length) {
    console.log(`     INVALID: ${bad.join('; ')}\n`);
    continue;
  }

  console.log(
    `     ICE ${c.a.iceRttMs?.toFixed?.(1) ?? '—'}/${c.b.iceRttMs?.toFixed?.(1) ?? '—'} ms` +
      (s.nosim ? '' : ` against ${c.expectedRttMs} set`) +
      `   path ${c.a.pathType}`,
  );

  // A ramp is not one verdict. Reporting only the 12 Mbps step of a ramp hides the shape, and
  // the shape is the reason to run a ramp at all — where it breaks is worth more than whether
  // it breaks.
  const rates = [...new Set(c.a.rows.map((r) => r.targetMbps))].sort((a, b) => a - b);
  if (s.mode === 'ramp') {
    console.log(`     step   recv med   recv p5   buffered p95   queue p95   loss`);
    for (const rate of rates) {
      const rows = sendSpan(c.a.rows).filter((r) => Math.abs(r.targetMbps - rate) < 0.01 && r.t > 3000);
      if (rows.length < 5) continue;
      const recv = rows.map((r) => r.recvMbps);
      const bufs = rows.map((r) => r.bufP95KB ?? 0);
      const owds = rows.map((r) => r.owdP95).filter((v) => v != null);
      const med = pct(recv, 50);
      const ok = med >= 0.97 * rate;
      console.log(
        `     ${String(rate).padStart(4)}  ${med.toFixed(2).padStart(8)}  ${pct(recv, 5).toFixed(2).padStart(8)}  ` +
          `${pct(bufs, 95).toFixed(0).padStart(11)} KB  ${(owds.length ? pct(owds, 95).toFixed(1) : '—').padStart(9)} ms` +
          `   ${ok ? '' : '  ← breaks here'}`,
      );
    }
  }

  for (const side of ['a', 'b']) {
    const tgt = s.mode === 'soak' ? s.target : 12;
    const span = sendSpan(c[side].rows ?? []);
    const settled = span.filter((r) => Math.abs(r.targetMbps - tgt) < 0.01 && r.t > 3000);
    if (settled.length < 10) {
      console.log(
        `     ${side.toUpperCase()}: no verdict — ${settled.length} settled rows at ${tgt} Mbps ` +
          `in a ${span.length}-row send span of ${(c[side].rows ?? []).length}`,
      );
      continue;
    }
    const med = pct(settled.map((r) => r.recvMbps), 50);
    const p5 = pct(settled.map((r) => r.recvMbps), 5);
    const bufP95 = pct(settled.map((r) => r.bufP95KB ?? 0), 95);
    const owds = settled.map((r) => r.owdP95).filter((v) => v != null);
    const owdP95 = owds.length ? pct(owds, 95) : null;
    const loss = c[side].verdict?.checks?.find((k) => /^loss/.test(k.name))?.got ?? '—';
    // Planned duration is derivable from the setting: a soak is one step, a ramp is one per rate.
    const nSteps = s.mode === 'ramp' ? [...new Set((c[side].rows ?? []).map((r) => r.targetMbps))].filter((v) => v > 0).length : 1;
    const plannedMs = (s.sec ?? 0) * 1000 * Math.max(1, nSteps);
    const spanEnd = settled.length ? settled[settled.length - 1].t : 0;
    const cov = plannedMs ? spanEnd / plannedMs : null;
    const checks = [
      [
        'sender survived to the end of the plan',
        cov == null || cov >= 0.95,
        cov == null ? 'no plan' : `sent until ${(spanEnd / 1000).toFixed(1)}s of ${(plannedMs / 1000).toFixed(1)}s (${(cov * 100).toFixed(0)}%)`,
      ],
      [`throughput ≥ 97% of ${tgt} Mbps (median)`, med >= 0.97 * tgt, `${med.toFixed(2)} Mbps`],
      ['throughput floor ≥ 90% (p5 bucket)', p5 >= 0.9 * tgt, `${p5.toFixed(2)} Mbps`],
      ['bufferedAmount p95 < 64 KB (pacer, not SCTP, is binding)', bufP95 < 64, `${bufP95.toFixed(1)} KB`],
      ['queueing delay p95 < 30 ms above floor', owdP95 != null && owdP95 < 30, owdP95 == null ? 'no data' : `${owdP95.toFixed(1)} ms`],
    ];
    const ok = checks.every((k) => k[1]);
    judged++;
    if (ok) passed++;
    console.log(
      `     ${side.toUpperCase()}: ${ok ? '✓ PASS' : '✗ FAIL'}   ` +
        `(${settled.length} settled of a ${span.length}-row send span; loss ${loss})`,
    );
    for (const [name, good, got] of checks) {
      if (!good || process.argv.includes('--verbose')) {
        console.log(`        ${good ? 'pass' : 'FAIL'}  ${name} — ${got}`);
      }
    }
  }

  // The proxy's own throughput, because a stalled emulator and a stalled transport look
  // identical from inside the browser.
  if (c.proxyTrace?.length > 1) {
    const gaps = [];
    for (let i = 1; i < c.proxyTrace.length; i++) {
      const dt = (c.proxyTrace[i].t - c.proxyTrace[i - 1].t) / 1000;
      const dn = c.proxyTrace[i].sent - c.proxyTrace[i - 1].sent;
      gaps.push(dt > 0 ? dn / dt : 0);
    }
    const stalled = gaps.filter((g) => g < 100).length;
    console.log(
      `     delay line: ${Math.round(pct(gaps, 50))} datagrams/s median, ` +
        `${c.proxyStats?.dropped ?? 0} dropped` +
        (c.proxyLag ? `, loop lag p50 ${c.proxyLag.p50}/p95 ${c.proxyLag.p95} ms` : '') +
        (c.hostLoad ? `, host load ${c.hostLoad[0]}` : '') +
        (stalled ? `, STALLED in ${stalled}/${gaps.length} samples` : ''),
    );
  }
  console.log('');
}

if (judged) console.log(`  ${passed}/${judged} side-verdict(s) passed\n`);
