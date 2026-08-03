/**
 * Read a set of runs side by side as a function of emulated distance.
 *
 * The question this answers is the one a single run cannot: **does our own cost stay put
 * as the network gets longer?** DESIGN.md §3 spends its latency budget as though the
 * pipeline's contribution were a constant that the network is then added to. If the jitter
 * buffer grows with RTT — and it does — then the budget compounds, and every "we beat Zoom
 * by X" figure has to be quoted at a distance rather than in the abstract.
 *
 * Usage: node sweep.mjs                (every run with a netsim config)
 *        node sweep.mjs d20 d80 d160   (specific run prefixes)
 */

import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const RUNS = join(HERE, 'runs');

const wanted = process.argv.slice(2);
const dirs = readdirSync(RUNS)
  .filter((d) => (wanted.length ? wanted.some((w) => d.startsWith(w)) : true))
  .map((d) => join(RUNS, d))
  .filter((d) => existsSync(join(d, 'meta.json')));

const med = (xs) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return +(s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2).toFixed(1);
};
const f = (v, w = 6) => (v == null ? '—'.padStart(w) : String(v).padStart(w));

const rows = [];
const rejected = [];
for (const dir of dirs) {
  const meta = JSON.parse(readFileSync(join(dir, 'meta.json'), 'utf8'));
  const sides = {};
  for (const s of ['A', 'B']) {
    const p = join(dir, `${s}.json`);
    if (existsSync(p)) sides[s] = JSON.parse(readFileSync(p, 'utf8'));
  }
  if (!sides.A || !sides.B) continue;

  const stat = (d, path) => {
    const vals = d.events
      .filter((e) => e.kind === 'stats')
      .map((e) => path.split('.').reduce((o, k) => o?.[k], e.data))
      .filter((v) => v != null);
    return med(vals);
  };
  const clean = (d, metric) =>
    med(
      d.transitions
        .filter((t) => !t.negative && !t.overlap && !t.lull && !t.backchannel && t.metric === metric)
        .map((t) => t.gapMs),
    );

  // The cross-machine identity from §17.1: my perceived minus their human is transit only.
  const e1 = clean(sides.A, 'perceived') != null && clean(sides.B, 'human') != null
    ? clean(sides.A, 'perceived') - clean(sides.B, 'human') : null;
  const e2 = clean(sides.B, 'perceived') != null && clean(sides.A, 'human') != null
    ? clean(sides.B, 'perceived') - clean(sides.A, 'human') : null;
  const m2e = e1 != null && e2 != null ? (e1 + e2) / 2 : (e1 ?? e2);

  const iceRtt = med([stat(sides.A, 'pair.rttMs'), stat(sides.B, 'pair.rttMs')].filter((v) => v != null));
  const playout = med([stat(sides.A, 'audio.playoutMs'), stat(sides.B, 'audio.playoutMs')].filter((v) => v != null));
  const vPlayout = med([stat(sides.A, 'video.playoutMs'), stat(sides.B, 'video.playoutMs')].filter((v) => v != null));

  // Head start as delivered to the far end. NOT truth-matched — score.mjs does that against
  // the fixture; this is the raw distribution, which is the right thing here because the
  // question is how the *reported* number behaves as the path degrades.
  //
  // The median alone hides the failure: under loss it is the tail that goes, so `leadBad`
  // counts head starts larger than any that were planted. A planted lead never exceeds
  // 258 ms, so anything past 300 ms is the instrument being wrong, not a long breath.
  const leads = [];
  let concealedEvents = 0;
  for (const d of [sides.A, sides.B]) {
    for (const e of d.events.filter((e) => e.kind === 'onset' && e.data.side === 'remote')) {
      if (e.data.type === 'voiced' && e.data.leadMs != null) leads.push(e.data.leadMs);
      if (e.data.concealed) concealedEvents++;
    }
  }
  const leadBad = leads.filter((v) => v > 300).length;
  const freezes = (d) => {
    const s = d.events.filter((e) => e.kind === 'stats');
    return s.length ? (s[s.length - 1].data?.video?.freezeCount ?? null) : null;
  };
  const lost = (d) => {
    const s = d.events.filter((e) => e.kind === 'stats');
    return s.length ? (s[s.length - 1].data?.audio?.packetsLost ?? null) : null;
  };

  // A negative mouth-to-ear is not a small number, it is a broken run: it means one side's
  // transitions are unusable, so `my perceived − their human` came out backwards. Runs from
  // before the event-reordering fix do this. Averaging them in would drag the aggregate
  // hundreds of milliseconds negative, so they are excluded and counted out loud.
  if (m2e != null && m2e < 0) {
    rejected.push({ tag: meta.tag, m2e: Math.round(m2e) });
    continue;
  }

  rows.push({
    tag: meta.tag,
    setRtt: meta.netsim?.rttMs ?? 0,
    jitter: meta.netsim?.jitterMs ?? 0,
    loss: meta.netsim?.lossPct ?? 0,
    iceRtt,
    m2e: m2e == null ? null : +m2e.toFixed(0),
    ownCost: m2e == null || iceRtt == null ? null : +((m2e - iceRtt) / 2).toFixed(0),
    playout,
    vPlayout,
    lead: med(leads),
    leadBad,
    leadMax: leads.length ? Math.round(Math.max(...leads)) : null,
    concealedEvents,
    freezes: [freezes(sides.A), freezes(sides.B)].filter((v) => v != null).reduce((a, b) => a + b, 0),
    lostPkts: [lost(sides.A), lost(sides.B)].filter((v) => v != null).reduce((a, b) => a + b, 0),
    conn: meta.connectMs,
  });
}

rows.sort((a, b) => a.setRtt - b.setRtt || a.tag.localeCompare(b.tag));

console.log(`\n  DISTANCE SWEEP — ${rows.length} runs\n`);
console.log('  run        set    ICE   mouth   our cost   audio   video    head start at far end    freeze  lost');
console.log('             RTT    RTT   to ear  each way   buf     buf    median    max  impossible          ');
console.log('  ' + '─'.repeat(102));
for (const r of rows) {
  console.log(
    `  ${r.tag.padEnd(10)} ${f(r.setRtt, 4)}  ${f(r.iceRtt, 5)}  ${f(r.m2e, 5)}   ${f(r.ownCost, 7)}   ` +
      `${f(r.playout, 5)}   ${f(r.vPlayout, 5)}   ${f(r.lead, 6)} ${f(r.leadMax, 6)}  ${f(r.leadBad, 6)}` +
      `${r.leadBad ? ' ⚠' : '  '}     ${f(r.freezes, 4)}  ${f(r.lostPkts, 4)}`,
  );
}
if (rows.some((r) => r.leadBad)) {
  console.log(
    `\n  ⚠ "impossible" counts head starts over 300 ms, which the fixture never plants (max 258).\n` +
      `    Every one is a false onset from a noise floor that chased a jitter-buffer underrun\n` +
      `    below the room — DESIGN.md §17.1, fixed by FLOOR_DROP_HOLD_MS in core/onset.js.\n` +
      `    They inflate the design's headline number, so they must be excluded, not averaged in.`,
  );
}

// The point of the table: is our own contribution flat?
const withCost = rows.filter((r) => r.ownCost != null && r.iceRtt != null);
if (withCost.length >= 2) {
  const lo = withCost[0];
  const hi = withCost[withCost.length - 1];
  const dCost = hi.ownCost - lo.ownCost;
  const dRtt = hi.iceRtt - lo.iceRtt;
  // Judged on the spread of all the runs, not on the two endpoints. Two points cannot
  // distinguish a trend from noise, and the per-run estimate has real spread — reading a
  // trend off the ends would be exactly the kind of flattering conclusion this file exists
  // to prevent.
  const costs = withCost.map((r) => r.ownCost);
  const spread = Math.max(...costs) - Math.min(...costs);
  console.log(`\n  Our own one-way cost, every run: ${withCost.map((r) => `${r.ownCost}@${Math.round(r.iceRtt)}`).join('  ')}  (ms @ ms RTT)`);
  console.log(`  range ${Math.min(...costs)}–${Math.max(...costs)} ms, spread ${spread} ms across ${dRtt} ms of added path`);
  console.log(
    spread <= 15
      ? `  Flat within measurement spread. §3 may treat it as a constant added to the network.`
      : `  The spread (${spread} ms) is too large to call it constant, but with one run per point it is\n` +
        `  also too large to call it a trend. What is certain is the floor: ${Math.min(...costs)} ms each way is\n` +
        `  self-inflicted at every distance measured, including zero. Repeat runs per point would\n` +
        `  settle whether it grows.`,
  );
}
if (rejected.length) {
  console.log(
    `  Excluded ${rejected.length} run(s) with a negative mouth-to-ear, which is not a measurement:\n` +
      rejected.map((r) => `    ${r.tag}  ${r.m2e} ms`).join('\n'),
  );
}
console.log();
