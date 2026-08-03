/**
 * Score a run against the ground truth baked into its fixture.
 *
 * This is the file that decides whether the design's claims survive contact with real
 * audio, so it is written to be able to say no. Every question it asks has a numeric
 * answer with a known correct value:
 *
 *   1. Was every turn detected at all, on the right side?
 *   2. When did the detector think it started, versus when it actually did?
 *   3. Was a real inhale still classified as an inhale *after* crossing the network?
 *   4. Was the reported breath lead the lead that was planted?
 *   5. Were the turn gaps the gaps that were planted?
 *
 * Question 3 is the one the design lives on, and the local-versus-remote split is what
 * makes it an experiment rather than an assertion. The same inhale is observed twice:
 * once on the machine that produced it, and once on the far machine after capture,
 * Opus, the network, the jitter buffer and decode. If it survives locally and dies
 * remotely, §3.1 lever 1 is broken as built, and no amount of local success hides that.
 *
 * Usage: node score.mjs runs/<dir>            or  node score.mjs runs/<dir> --verbose
 */

import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2];
if (!dir) {
  console.error('usage: node score.mjs runs/<dir>');
  process.exit(2);
}
const VERBOSE = process.argv.includes('--verbose');

const truth = JSON.parse(readFileSync(join(dir, 'truth.json'), 'utf8'));
const meta = JSON.parse(readFileSync(join(dir, 'meta.json'), 'utf8'));
const sides = {};
for (const s of ['A', 'B']) {
  const p = join(dir, `${s}.json`);
  if (existsSync(p)) sides[s] = JSON.parse(readFileSync(p, 'utf8'));
}

const med = (xs) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return +(s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2).toFixed(1);
};
const mean = (xs) => (xs.length ? +(xs.reduce((a, b) => a + b, 0) / xs.length).toFixed(1) : null);
const f = (v, u = '') => (v == null ? '—' : `${v}${u}`);

console.log(`\n${'═'.repeat(74)}`);
console.log(`  ${meta.tag}   ${dir.split('/').pop()}`);
console.log(`  ${truth.turns.length} turns planted, ${truth.turns.filter((t) => t.withBreath).length} with a real inhale`);
console.log(`  audio processing: ${meta.forced.processing ? 'AEC + NS + AGC ON (control arm)' : 'all OFF (our config)'}`);
console.log(`  connected in ${meta.connectMs} ms${meta.forced.relay ? ' · media via TURN relay' : ''}`);
console.log(`${'═'.repeat(74)}`);

const overall = { localBreath: [], remoteBreath: [], localLead: [], remoteLead: [] };
// Per-side gap medians, kept so the two sides can be cross-checked against each other
// after the loop. See the mouth-to-ear section at the bottom for why that matters.
const gaps = {};

for (const [side, data] of Object.entries(sides)) {
  const onsets = data.events.filter((e) => e.kind === 'onset');
  if (!onsets.length) {
    console.log(`\n  ${side}: no onset events at all — the detectors never ran.`);
    continue;
  }

  // Group raw events into detected turns, per observing detector.
  const turnsOf = (obs) => {
    const evs = onsets.filter((e) => e.data.side === obs);
    const out = [];
    let cur = null;
    // Sample-accurate detector time where available — see the note in analyze.mjs.
    const at = (e) => e.data.ctxMs ?? e.t;
    for (const e of evs) {
      const d = e.data;
      if (d.type === 'onset') {
        cur = { onsetT: at(e), kind: null, voicedT: null, leadMs: null, endT: null, snrDb: d.snrDb };
        out.push(cur);
      } else if (!cur) continue;
      else if (d.type === 'classified') cur.kind = d.kind;
      else if (d.type === 'voiced') { cur.voicedT = at(e); cur.leadMs = d.leadMs; }
      else if (d.type === 'end') cur.endT = at(e);
    }
    return out;
  };

  // Which truth turns should each detector have seen? The local mic hears this
  // machine's own turns; the received-audio detector hears the peer's.
  const own = truth.turns.filter((t) => t.side === side);
  const peer = truth.turns.filter((t) => t.side !== side);

  for (const [obs, expected] of [['local', own], ['remote', peer]]) {
    const det = turnsOf(obs);

    // The fixture's timeline and the browser's differ by a constant: capture start,
    // worklet spin-up, and for the remote side the network too. Estimate it as the
    // median offset of the best pairing rather than assuming it, then report it — a
    // wild offset would itself be a finding.
    const cands = [];
    for (const t of expected) {
      const want = t.breathAtMs ?? t.speechAtMs;
      for (const d of det) cands.push(d.onsetT - want);
    }
    // The offset is the tightest cluster of candidate differences.
    let best = null;
    for (const c of cands) {
      const near = cands.filter((x) => Math.abs(x - c) < 250);
      if (!best || near.length > best.n) best = { off: med(near), n: near.length };
    }
    const off = best?.off ?? 0;

    // Match each planted turn to the nearest detected onset within a tolerance.
    const rows = [];
    const used = new Set();
    for (const t of expected) {
      const want = (t.breathAtMs ?? t.speechAtMs) + off;
      let pick = null, bestD = Infinity;
      for (let i = 0; i < det.length; i++) {
        if (used.has(i)) continue;
        const d = Math.abs(det[i].onsetT - want);
        if (d < bestD) { bestD = d; pick = i; }
      }
      // 400 ms is generous but unambiguous here: planted turns are seconds apart.
      const hit = pick != null && bestD <= 400;
      if (hit) used.add(pick);
      rows.push({ t, d: hit ? det[pick] : null, errMs: hit ? +(det[pick].onsetT - want).toFixed(0) : null });
    }

    const found = rows.filter((r) => r.d);
    const withBreath = rows.filter((r) => r.t.withBreath && r.d);
    const noBreath = rows.filter((r) => !r.t.withBreath && r.d);
    const calledBreath = withBreath.filter((r) => r.d.kind === 'breath');
    const falseBreath = noBreath.filter((r) => r.d.kind === 'breath');
    const leadErrs = withBreath.filter((r) => r.d.leadMs != null).map((r) => r.d.leadMs - r.t.leadMs);

    const label = obs === 'local' ? `${side} own mic` : `${side} hears peer (post-network)`;
    console.log(`\n  ${label}   [timeline offset ${off == null ? '—' : Math.round(off)} ms]`);
    console.log(`    turns detected        ${found.length}/${rows.length}` +
      (found.length < rows.length ? `   MISSED ${rows.filter((r) => !r.d).map((r) => '#' + r.t.n).join(', ')}` : ''));
    if (found.length) {
      const errs = found.map((r) => r.errMs);
      console.log(`    onset timing error    median ${f(med(errs), ' ms')}   spread ${Math.min(...errs)} … ${Math.max(...errs)} ms`);
    }
    if (withBreath.length) {
      const rate = (calledBreath.length / withBreath.length) * 100;
      console.log(`    real inhale kept      ${calledBreath.length}/${withBreath.length} = ${rate.toFixed(0)}%` +
        `   ${rate >= 70 ? '✓' : rate >= 40 ? '~ degraded' : '✗ destroyed'}`);
      (obs === 'local' ? overall.localBreath : overall.remoteBreath).push(rate);
    }
    if (noBreath.length) {
      console.log(`    false inhale calls    ${falseBreath.length}/${noBreath.length} turns that had none`);
    }
    if (leadErrs.length) {
      console.log(`    breath lead error     median ${f(med(leadErrs), ' ms')}   mean ${f(mean(leadErrs), ' ms')}` +
        `   (negative = under-reports, the safe direction)`);
      const arr = obs === 'local' ? overall.localLead : overall.remoteLead;
      arr.push(...leadErrs);
    }
    if (VERBOSE) {
      console.log(`      turn  planted            detected           kind      lead: planted → got`);
      for (const r of rows) {
        console.log(
          `      #${String(r.t.n).padEnd(3)} ${String(Math.round((r.t.breathAtMs ?? r.t.speechAtMs))).padStart(6)} ms` +
            `${r.t.withBreath ? ' (inhale)' : ' (voice) '}   ` +
            (r.d ? `${String(Math.round(r.d.onsetT - off)).padStart(6)} ms  err ${String(r.errMs).padStart(5)}  ${String(r.d.kind ?? '?').padEnd(9)}` : `    MISSED                       `) +
            (r.t.withBreath ? ` ${String(r.t.leadMs).padStart(4)} → ${r.d?.leadMs != null ? String(Math.round(r.d.leadMs)).padStart(4) : '   —'}` : ''),
        );
      }
    }
  }

  // Gap accuracy against the planted gaps.
  const clean = data.transitions.filter((t) => !t.negative && !t.overlap && !t.lull && !t.backchannel);
  const human = clean.filter((t) => t.metric === 'human').map((t) => t.gapMs);
  const perceived = clean.filter((t) => t.metric === 'perceived').map((t) => t.gapMs);
  const plantedToEvidence = med(truth.expected.map((e) => e.toEvidenceMs));
  gaps[side] = {
    human: med(human), humanN: human.length,
    perceived: med(perceived), perceivedN: perceived.length,
    rtt: med(data.events.filter((e) => e.kind === 'stats').map((e) => e.data?.pair?.rttMs).filter((v) => v != null)),
    late: data.summary?.lateEvents ?? 0,
  };
  console.log(`\n    gaps   planted ${f(plantedToEvidence, ' ms')} to first evidence`);
  console.log(`           human median ${f(med(human), ' ms')} (n=${human.length})` +
    `   perceived median ${f(med(perceived), ' ms')} (n=${perceived.length})`);
  console.log(`           ${data.summary?.usable ?? 0} usable of ${data.summary?.total ?? 0} transitions` +
    `   discarded: overlap ${data.summary?.discarded?.overlap ?? 0}, lull ${data.summary?.discarded?.lull ?? 0},` +
    ` backchannel ${data.summary?.discarded?.backchannel ?? 0}, negative ${data.summary?.discarded?.negative ?? 0}`);
  // A non-zero count means the analyser processed something out of chronological order,
  // which is the one failure mode that can make every gap above meaningless.
  if (data.summary?.lateEvents) {
    console.log(`           ⚠ ${data.summary.lateEvents} event(s) arrived too late to reorder — gaps are suspect`);
  }

  const stats = data.events.filter((e) => e.kind === 'stats');
  if (stats.length) {
    const rtt = med(stats.map((e) => e.data?.pair?.rttMs).filter((v) => v != null));
    const play = med(stats.map((e) => e.data?.audio?.playoutMs).filter((v) => v != null));
    const last = stats[stats.length - 1].data ?? {};
    console.log(`    link   rtt ${f(rtt, ' ms')}   playout buffer ${f(play, ' ms')}` +
      `   video ${last.video?.w ?? '?'}×${last.video?.h ?? '?'}@${last.video?.fps ?? '?'}` +
      `   freezes ${last.video?.freezeCount ?? '—'}`);
  }
}

// ── Mouth-to-ear delay, from the two sides against each other ───────────────
//
// The identity is exact and needs no clock sync. On my machine:
//
//   perceived = (I see their onset)  − (I see my own end)
//
// and on theirs, for the same pair of turns:
//
//   human     = (they see their own onset) − (they see my end)
//
// Subtract them and the two human response times cancel — they are the same person
// answering the same turn — leaving one transit each way:
//
//   my perceived − their human = delay(me→them) + delay(them→me) = mouth-to-ear RTT
//
// Doing it *across* machines is what makes it valid. The per-machine version compares
// my response time with theirs, so it only reconciles if two different people happen to
// answer at the same speed; here nothing about the humans is assumed at all.
//
// Two independent estimates fall out, one per direction, and they have to agree. They
// also measure something the ICE round trip does not: ICE times a STUN ping, while this
// times audio through encode, packetisation, the jitter buffer, decode and playout. On a
// loopback link ICE reads zero and this does not, and the difference is the delay the
// stack adds on its own — which is the number §3 is trying to spend.
if (gaps.A && gaps.B) {
  console.log(`\n${'═'.repeat(74)}`);
  console.log('  MOUTH-TO-EAR DELAY  (cross-checked between the two machines)\n');
  const e1 = gaps.A.perceived != null && gaps.B.human != null ? +(gaps.A.perceived - gaps.B.human).toFixed(1) : null;
  const e2 = gaps.B.perceived != null && gaps.A.human != null ? +(gaps.B.perceived - gaps.A.human).toFixed(1) : null;
  console.log(`    A perceived ${f(gaps.A.perceived, ' ms')} − B human ${f(gaps.B.human, ' ms')}` +
    `  =  ${f(e1, ' ms')}   (n=${gaps.A.perceivedN}/${gaps.B.humanN})`);
  console.log(`    B perceived ${f(gaps.B.perceived, ' ms')} − A human ${f(gaps.A.human, ' ms')}` +
    `  =  ${f(e2, ' ms')}   (n=${gaps.B.perceivedN}/${gaps.A.humanN})`);
  if (e1 != null && e2 != null) {
    const spread = Math.abs(e1 - e2);
    console.log(`\n    the two estimates ${spread <= 30 ? 'agree' : 'DISAGREE'} to ${spread.toFixed(0)} ms` +
      `   ${spread <= 30 ? '✓ instrument is self-consistent' : '✗ one side is measuring something else'}`);
    const m2e = (e1 + e2) / 2;
    const iceRtt = med([gaps.A.rtt, gaps.B.rtt].filter((v) => v != null)) ?? 0;
    console.log(`    mouth-to-ear round trip   ${m2e.toFixed(0)} ms`);
    console.log(`    ICE round trip            ${iceRtt.toFixed(0)} ms   (network only)`);
    const own = m2e - iceRtt;
    console.log(`    ─────────────────────────────────────`);
    console.log(`    added by our own stack    ${own.toFixed(0)} ms round trip = ${(own / 2).toFixed(0)} ms each way`);
    console.log(
      own / 2 <= 40
        ? `\n    Within the §3 budget for local processing.`
        : `\n    Above the §3 budget: ${(own / 2).toFixed(0)} ms of one-way delay is self-inflicted, before\n` +
          `    a single packet crosses a network. Playout buffer is the first place to look.`,
    );
  }
  // Human response time is the figure that compares to Boland's face-to-face control,
  // and it is the one number here that no amount of engineering can improve.
  const hs = [gaps.A.human, gaps.B.human].filter((v) => v != null);
  if (hs.length) {
    console.log(`\n    human response time, this pair: ${hs.map((v) => `${v} ms`).join(' and ')}` +
      `   (Boland face-to-face control: 297 ms)`);
  }
}

// ── The verdict on lever 1 ───────────────────────────────────────────────────
console.log(`\n${'═'.repeat(74)}`);
console.log('  DOES THE BREATH SURVIVE THE PIPELINE?\n');
const L = mean(overall.localBreath);
const R = mean(overall.remoteBreath);
console.log(`    at the microphone that produced it   ${f(L, '%')}`);
console.log(`    at the far end, after the network    ${f(R, '%')}`);
if (L != null && R != null) {
  const drop = L - R;
  console.log(
    drop <= 15
      ? `\n    ✓ Survives transit — ${drop.toFixed(0)} pt drop. The inhale reaches the listener,\n` +
        `      which is what §3.1 lever 1 requires.`
      : drop <= 45
        ? `\n    ~ Degraded in transit — ${drop.toFixed(0)} pt drop. Lever 1 is real but smaller than claimed.`
        : `\n    ✗ Destroyed in transit — ${drop.toFixed(0)} pt drop. It is captured and then lost on the\n` +
          `      wire. §3.1 lever 1 does not work as built, and this is a transport finding.`,
  );
}
const rl = med(overall.remoteLead);
if (rl != null) {
  console.log(`\n    reported lead error at the far end: median ${rl} ms` +
    `  ${rl <= 10 ? '(under-reports — the safe direction)' : '(OVER-reports — flatters the design)'}`);
}
console.log();
