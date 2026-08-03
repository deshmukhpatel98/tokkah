/**
 * Offline analysis of a call log.
 *
 *   node analyze.mjs tape-log.ndjson
 *   curl -s https://<worker>/api/room/morning/log | node analyze.mjs
 *
 * Re-derives every metric from the raw event stream rather than trusting the live
 * summary, for two reasons. First, the live figures were computed by code running
 * inside a real-time audio path and are worth cross-checking. Second — and this is
 * the point of logging raw events at all — the filters that decide what counts as a
 * turn transition are judgement calls, and judgement calls should be revisable after
 * you have seen the data. Everything here can be re-run with different thresholds.
 *
 * Prints the comparison the design is actually making:
 *
 *   Boland et al. 2021, same task, measured:   face-to-face 297 ms · Zoom 976 ms
 *   This call:                                 human ___ ms · perceived ___ ms
 */

import { readFileSync } from 'node:fs';
import { TurnTaking, median } from './public/turntaking.js';

const CONTROL_MS = 297; // Boland face-to-face
const ZOOM_MS = 976; // Boland over Zoom

// ── Load ─────────────────────────────────────────────────────────────────────
const file = process.argv[2];
const text = file ? readFileSync(file, 'utf8') : readFileSync(0, 'utf8');
const events = text
  .split('\n')
  .filter((l) => l.trim())
  .map((l) => {
    try {
      return JSON.parse(l);
    } catch {
      return null;
    }
  })
  .filter(Boolean);

if (!events.length) {
  console.error('no events found');
  process.exit(1);
}

// Sessions are independent: two peers log into the same room, and each one's `t` is
// relative to its own page load. Mixing them would produce nonsense.
const sessions = new Map();
for (const e of events) {
  const key = `${e.session}|${e.role}`;
  if (!sessions.has(key)) sessions.set(key, []);
  sessions.get(key).push(e);
}

const pct = (xs, p) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  return +s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))].toFixed(1);
};
const fmt = (v, u = ' ms') => (v == null ? '—' : `${Math.round(v)}${u}`);
const bar = (v, max, width = 34) => {
  if (v == null) return '';
  const n = Math.max(1, Math.min(width, Math.round((v / max) * width)));
  return '█'.repeat(n);
};

console.log(`\n${events.length} events · ${sessions.size} session(s)\n`);

const combined = { human: [], perceived: [], leadRemote: [], leadLocal: [], wordGaps: [] };

for (const [key, evs] of sessions) {
  const [session, role] = key.split('|');
  const wall = evs.map((e) => e.wall).filter(Boolean);
  const durMin = wall.length ? (Math.max(...wall) - Math.min(...wall)) / 60000 : 0;

  console.log('─'.repeat(72));
  console.log(`session ${session}  role ${role}  ·  ${durMin.toFixed(1)} min  ·  ${evs.length} events`);

  // ── Rebuild turn-taking from raw onset events ─────────────────────────────
  const tt = new TurnTaking(null);
  let onsetCount = 0;
  for (const e of evs) {
    if (e.kind !== 'onset') continue;
    onsetCount++;
    const d = e.data ?? {};
    const ev = { type: d.type, kind: d.kind ?? undefined, leadMs: d.leadMs ?? undefined };
    // `ctxMs` is the detector's sample-accurate time; `e.t` is when the handler ran.
    // They differ by up to HANG_MS on an `end`, which is enough to reorder an end
    // after the reply's onset and destroy every human-gap measurement. Prefer the
    // former and only fall back for logs written before it was recorded.
    const at = d.ctxMs ?? e.t;
    if (d.side === 'local') tt.local_(ev, at);
    else if (d.side === 'remote') tt.remote_(ev, at);
  }
  // The analyser holds recent events to put them back in chronological order; without
  // this the last transitions of the log would never be assembled. See turntaking.js.
  tt.flush();
  const s = tt.summary();

  if (!onsetCount) {
    console.log('  no onset events — the detectors did not run in this session');
    continue;
  }

  const cleanT = tt.transitions.filter((t) => !t.negative && !t.overlap && !t.lull && !t.backchannel);
  const human = cleanT.filter((t) => t.metric === 'human').map((t) => t.gapMs);
  const perceived = cleanT.filter((t) => t.metric === 'perceived').map((t) => t.gapMs);

  combined.human.push(...human);
  combined.perceived.push(...perceived);
  combined.leadRemote.push(...tt.leads.remote);
  combined.leadLocal.push(...tt.leads.local);
  combined.wordGaps.push(...cleanT.filter((t) => t.gapToWordMs != null).map((t) => t.gapToWordMs));

  console.log(`\n  turn transitions: ${s.total} seen, ${s.usable} usable`);
  console.log(
    `    discarded — overlap ${s.discarded.overlap}, backchannel ${s.discarded.backchannel}, ` +
      `lull ${s.discarded.lull}, negative ${s.discarded.negative}`,
  );

  console.log(`\n  HUMAN gap (their audio stopped → I started; no network in it)`);
  console.log(`    n=${human.length}  median ${fmt(median(human))}  p25 ${fmt(pct(human, 25))}  p75 ${fmt(pct(human, 75))}`);
  console.log(`  PERCEIVED gap (I stopped → their reply reached me; contains RTT)`);
  console.log(`    n=${perceived.length}  median ${fmt(median(perceived))}  p25 ${fmt(pct(perceived, 25))}  p75 ${fmt(pct(perceived, 75))}`);

  // ── The consistency check ─────────────────────────────────────────────────
  // perceived − human should reconcile with the measured RTT. This is the one thing
  // that says whether to trust any of the above.
  const rtts = evs.filter((e) => e.kind === 'stats' && e.data?.pair?.rttMs != null).map((e) => e.data.pair.rttMs);
  const rttMed = median(rtts);
  const implied = median(human) != null && median(perceived) != null ? median(perceived) - median(human) : null;
  console.log(`\n  consistency: perceived − human = ${fmt(implied)}   measured RTT = ${fmt(rttMed)}`);
  if (implied != null && rttMed != null) {
    const off = Math.abs(implied - rttMed);
    console.log(
      off < 60
        ? `    ✓ reconciles within ${Math.round(off)} ms — the two gap measurements are trustworthy`
        : `    ⚠ off by ${Math.round(off)} ms — treat the gap figures with suspicion, not the conversation`,
    );
  }

  // ── The breath ────────────────────────────────────────────────────────────
  console.log(`\n  BREATH`);
  console.log(
    `    their turns opening with an audible breath: ${s.breathRate == null ? '—' : s.breathRate + '%'}` +
      `    (yours, as a control: ${s.breathRateLocal == null ? '—' : s.breathRateLocal + '%'})`,
  );
  console.log(
    `    their breath head start: n=${tt.leads.remote.length}  median ${fmt(median(tt.leads.remote))}` +
      `  p25 ${fmt(pct(tt.leads.remote, 25))}  p75 ${fmt(pct(tt.leads.remote, 75))}`,
  );
  if (s.breathRateLocal > 40 && s.breathRate != null && s.breathRate < 15) {
    console.log(`    ⚠ your breaths are detected but theirs are not — the inhale is being lost in transit,`);
    console.log(`      not at the microphone. That is a transport finding and it kills §3.1 lever 1 as built.`);
  }

  // ── Connection quality ────────────────────────────────────────────────────
  const stats = evs.filter((e) => e.kind === 'stats');
  if (stats.length) {
    const last = stats[stats.length - 1].data ?? {};
    const playouts = stats.map((e) => e.data?.audio?.playoutMs).filter((v) => v != null);
    const freezes = stats.map((e) => e.data?.video?.freezeCount).filter((v) => v != null);
    const conceal = stats.map((e) => e.data?.audio?.concealmentEvents).filter((v) => v != null);
    console.log(`\n  CONNECTION  (${stats.length} samples)`);
    console.log(`    rtt          median ${fmt(rttMed)}  p95 ${fmt(pct(rtts, 95))}`);
    console.log(`    playout buf  median ${fmt(median(playouts))}  p95 ${fmt(pct(playouts, 95))}`);
    console.log(`    video        ${last.video?.w ?? '?'}×${last.video?.h ?? '?'} @ ${last.video?.fps ?? '?'} fps`);
    console.log(`    freezes      ${freezes.length ? Math.max(...freezes) : '—'}  ·  audio glitches ${conceal.length ? Math.max(...conceal) : '—'}`);
    if (last.video?.qualityLimitation && last.video.qualityLimitation !== 'none') {
      console.log(`    ⚠ encoder was limited by: ${last.video.qualityLimitation}`);
    }
    // Playout buffer is the reason to distrust a human-gap figure: if the receiver
    // was holding 200 ms, part of what looks like human hesitation is the buffer.
    if (median(playouts) != null && median(playouts) > 120) {
      console.log(`    ⚠ playout buffer median ${Math.round(median(playouts))} ms — high enough that some of the`);
      console.log(`      "human" gap is really the receiver holding audio. Subtract it before comparing to 297 ms.`);
    }
  }

  const errs = evs.filter((e) => e.kind === 'error');
  if (errs.length) {
    console.log(`\n  ${errs.length} error(s):`);
    const byWhere = {};
    for (const e of errs) byWhere[e.data?.where ?? '?'] = (byWhere[e.data?.where ?? '?'] ?? 0) + 1;
    for (const [w, n] of Object.entries(byWhere)) console.log(`    ${w}: ${n}`);
  }
  console.log();
}

// ── The verdict ──────────────────────────────────────────────────────────────
console.log('═'.repeat(72));
console.log('THE COMPARISON\n');

const H = median(combined.human);
const P = median(combined.perceived);
const W = median(combined.wordGaps);
const maxV = Math.max(ZOOM_MS, P ?? 0, 400);

console.log(`  face to face (Boland 2021)   ${fmt(CONTROL_MS).padStart(7)}  ${bar(CONTROL_MS, maxV)}`);
console.log(`  over Zoom    (Boland 2021)   ${fmt(ZOOM_MS).padStart(7)}  ${bar(ZOOM_MS, maxV)}`);
console.log(`  ── this call ──`);
console.log(`  human only                   ${fmt(H).padStart(7)}  ${bar(H, maxV)}`);
console.log(`  perceived (what you felt)    ${fmt(P).padStart(7)}  ${bar(P, maxV)}`);
if (W != null) console.log(`  to their first word          ${fmt(W).padStart(7)}  ${bar(W, maxV)}`);
console.log();

if (H != null) {
  const off = H - CONTROL_MS;
  console.log(
    Math.abs(off) <= 120
      ? `  ✓ Human gap is within 120 ms of the face-to-face control (${off > 0 ? '+' : ''}${Math.round(off)} ms).\n` +
          `    §1.1c survives: raw audio on ordinary WebRTC did not cost the 179 ms Zoom loses.`
      : `  ✗ Human gap is ${Math.round(off)} ms off the face-to-face control.\n` +
          `    Either the cue-restoration argument in §1.1c is wrong, or something in this\n` +
          `    call's audio path is still destroying turn-end cues. Check the playout buffer first.`,
  );
}
if (P != null) {
  console.log(
    P < ZOOM_MS
      ? `  ✓ Perceived gap beats Zoom's measured 976 ms by ${Math.round(ZOOM_MS - P)} ms.`
      : `  ✗ Perceived gap is no better than Zoom's measured 976 ms.`,
  );
}
const LR = median(combined.leadRemote);
if (LR != null) {
  console.log(
    `  ${LR >= 100 ? '✓' : '✗'} Their breath arrived ${Math.round(LR)} ms before their words` +
      `${LR >= 100 ? ' — the head start is real.' : ' — smaller than §3.1 lever 1 assumes.'}`,
  );
} else {
  console.log(`  · No breath leads measured from their side. Either they open turns without an audible`);
  console.log(`    inhale, or the inhale is not surviving the path. Compare against the local control.`);
}
console.log();
