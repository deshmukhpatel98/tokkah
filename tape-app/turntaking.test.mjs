/**
 * Tests for the live turn-taking analyser.
 *
 * This is the module that produces the numbers the entire design will be judged on,
 * from a conversation that happens exactly once. So the tests here are less about
 * coverage and more about one specific question: **is the human/perceived
 * distinction actually implemented correctly, or does it merely look correct?**
 *
 * The distinction is subtle enough to be worth restating. Both detectors run on MY
 * machine, so:
 *
 *   remote 'end' → local 'onset'   = HUMAN gap. Their audio already crossed the
 *                                    network to reach me, so the transit is inside
 *                                    `remote end`, not added to the difference.
 *   local 'end'  → remote 'onset'  = PERCEIVED gap. My words had to reach them and
 *                                    their reply had to come back, so this contains
 *                                    a full round trip — correctly, because it is
 *                                    what I experienced as silence.
 *
 * Get that backwards and every number in the report is wrong in a way that looks
 * entirely plausible. Hence test 2.
 *
 * Run: node turntaking.test.mjs
 */

import { TurnTaking, median } from './public/turntaking.js';

let pass = 0;
let fail = 0;
const check = (name, cond, detail = '') => {
  if (cond) {
    pass++;
    console.log(`  ok    ${name}${detail ? `  — ${detail}` : ''}`);
  } else {
    fail++;
    console.log(`  FAIL  ${name}${detail ? `  — ${detail}` : ''}`);
  }
};

/**
 * Drive a scripted conversation. Each entry is
 *   [side, type, timeMs, extra?]
 * where side is 'local' | 'remote'.
 */
function play(script) {
  const seen = [];
  const tt = new TurnTaking((tr, phase) => seen.push({ ...tr, phase }));
  for (const [side, type, t, extra = {}] of script) {
    const ev = { type, ...extra };
    if (side === 'local') tt.local_(ev, t);
    else tt.remote_(ev, t);
  }
  // The analyser holds recent events to reorder them; a script that stops has to say so
  // or its last events stay held forever. Real callers do the same on hang-up.
  tt.flush();
  return { tt, seen };
}

console.log('\nturn-taking analyser\n');

// ── 1. A single clean exchange ───────────────────────────────────────────────
{
  console.log('1. one exchange: they speak, I reply with a breath');
  const { tt } = play([
    ['remote', 'onset', 0],
    ['remote', 'classified', 35, { kind: 'voice' }],
    ['remote', 'end', 1800],
    // I inhale 190 ms later, words 210 ms after that.
    ['local', 'onset', 1990],
    ['local', 'classified', 2025, { kind: 'breath' }],
    ['local', 'voiced', 2200, { leadMs: 210 }],
    ['local', 'end', 3200],
  ]);
  const t = tt.transitions[0];
  check('one transition recorded', tt.transitions.length === 1);
  check('metric is human (I responded to them)', t?.metric === 'human', t?.metric);
  check('gap = 1990 − 1800', t?.gapMs === 190, `${t?.gapMs} ms`);
  check('opening cue patched in after classification', t?.openedWith === 'breath', String(t?.openedWith));
  check('breath lead attached', t?.breathLeadMs === 210, `${t?.breathLeadMs} ms`);
  check('gap to first word = gap + lead', t?.gapToWordMs === 400, `${t?.gapToWordMs} ms`);
}

// ── 2. THE ONE THAT MATTERS: direction determines the metric ─────────────────
{
  console.log('\n2. both directions in one conversation');
  const { tt } = play([
    // They speak, I answer  → human gap (no network in it)
    ['remote', 'onset', 0],
    ['remote', 'classified', 35, { kind: 'voice' }],
    ['remote', 'end', 1000],
    ['local', 'onset', 1200],
    ['local', 'classified', 1235, { kind: 'voice' }],
    ['local', 'end', 2000],
    // I spoke, they answer  → perceived gap (contains a round trip)
    ['remote', 'onset', 2500],
    ['remote', 'classified', 2535, { kind: 'breath' }],
    ['remote', 'voiced', 2700, { leadMs: 200 }],
    ['remote', 'end', 3400],
  ]);
  const [a, b] = tt.transitions;
  check('two transitions', tt.transitions.length === 2, String(tt.transitions.length));
  check('first is human (local responded)', a?.metric === 'human' && a.responder === 'local', `${a?.metric}/${a?.responder}`);
  check('  gap 1200 − 1000', a?.gapMs === 200, `${a?.gapMs} ms`);
  check('second is perceived (remote responded)', b?.metric === 'perceived' && b.responder === 'remote', `${b?.metric}/${b?.responder}`);
  check('  gap 2500 − 2000', b?.gapMs === 500, `${b?.gapMs} ms`);
  check(
    'perceived > human, as it must be (it carries the RTT)',
    b.gapMs > a.gapMs,
    `${b.gapMs} vs ${a.gapMs}`,
  );

  const s = tt.summary();
  check('summary splits the two metrics', s.humanN === 1 && s.perceivedN === 1, `human n=${s.humanN}, perceived n=${s.perceivedN}`);
  check('  human median 200', s.humanMedian === 200, `${s.humanMedian}`);
  check('  perceived median 500', s.perceivedMedian === 500, `${s.perceivedMedian}`);
}

// ── 3. Consistency check: perceived − human ≈ RTT ────────────────────────────
// Not an assumption in the design — a property we can verify, which is what makes
// the instrument trustworthy rather than merely self-consistent.
{
  console.log('\n3. perceived − human should reconcile with RTT');
  const RTT = 300;
  const HUMAN = 250;
  const script = [];
  let t = 0;
  for (let i = 0; i < 6; i++) {
    // They talk 1.2 s, I reply after HUMAN ms
    script.push(['remote', 'onset', t], ['remote', 'classified', t + 35, { kind: 'voice' }], ['remote', 'end', t + 1200]);
    const myOnset = t + 1200 + HUMAN;
    script.push(['local', 'onset', myOnset], ['local', 'classified', myOnset + 35, { kind: 'voice' }], ['local', 'end', myOnset + 1000]);
    // They reply after HUMAN ms of thinking + RTT of travel
    const theirOnset = myOnset + 1000 + HUMAN + RTT;
    script.push(['remote', 'onset', theirOnset], ['remote', 'classified', theirOnset + 35, { kind: 'voice' }], ['remote', 'end', theirOnset + 1200]);
    t = theirOnset + 1200;
  }
  const { tt } = play(script);
  const s = tt.summary();
  const implied = s.perceivedMedian - s.humanMedian;
  check('human median recovers the true human latency', s.humanMedian === HUMAN, `${s.humanMedian} vs ${HUMAN}`);
  check(
    'perceived − human recovers the RTT',
    Math.abs(implied - RTT) < 1,
    `implied ${implied} ms vs true ${RTT} ms`,
  );
}

// ── 4. Flagging, not discarding ──────────────────────────────────────────────
{
  console.log('\n4. odd events are flagged, never dropped');
  // Written in true chronological order on purpose. The earlier version of this script
  // interleaved the two sides out of order, and the extra transition it produced was an
  // artefact of that scrambling rather than a conversational event — the kind of result
  // the watermark buffer now makes impossible.
  const { tt } = play([
    ['remote', 'onset', 0],
    ['remote', 'classified', 35, { kind: 'voice' }],
    ['remote', 'end', 1000],
    // A clean reply, 200 ms later.
    ['local', 'onset', 1200],
    ['local', 'classified', 1235, { kind: 'voice' }],
    ['local', 'end', 3000],
    // They say "mm-hm" for 300 ms — a backchannel, not a turn.
    ['remote', 'onset', 3300],
    ['remote', 'classified', 3335, { kind: 'voice' }],
    ['remote', 'end', 3600],
    // I carry on. The prior utterance was the backchannel, so this gets flagged.
    ['local', 'onset', 3800],
    ['local', 'classified', 3835, { kind: 'voice' }],
    ['local', 'end', 5000],
    // Four seconds of nothing: a lull, not a transition.
    ['remote', 'onset', 9000],
    ['remote', 'classified', 9035, { kind: 'voice' }],
    ['remote', 'end', 12000],
    // They start again and I cut in while they still have the floor.
    ['remote', 'onset', 13000],
    ['remote', 'classified', 13035, { kind: 'voice' }],
    ['local', 'onset', 13500],
    ['local', 'classified', 13535, { kind: 'voice' }],
    ['remote', 'end', 14000],
    ['local', 'end', 15000],
  ]);
  const s = tt.summary();
  check('every transition is retained', tt.transitions.length === 6, `${tt.transitions.length} recorded`);
  check('backchannel flagged', tt.transitions.some((t) => t.backchannel));
  check('lull flagged', tt.transitions.some((t) => t.lull));
  check('overlap flagged', tt.transitions.some((t) => t.overlap));
  check('the two clean transitions survive the filter', s.usable === 2, `${s.usable} usable of ${s.total}`);
  check('discard counts reported', typeof s.discarded.lull === 'number' && typeof s.discarded.backchannel === 'number');
  // Once events are ordered, `them.endAt` can never be in the future, so a negative gap
  // is arithmetically impossible. It was only ever reachable via out-of-order delivery,
  // which means a non-zero count in a real log is now a bug report, not a conversation.
  check('no negative gaps once events are ordered', s.discarded.negative === 0, `${s.discarded.negative}`);
}

// ── 5. Interruption produces a negative gap, flagged ────────────────────────
{
  console.log('\n5. interruption');
  const { tt } = play([
    ['remote', 'onset', 0],
    ['remote', 'classified', 35, { kind: 'voice' }],
    ['local', 'onset', 500], // I cut in while they are still going
    ['local', 'classified', 535, { kind: 'voice' }],
    ['remote', 'end', 900],
    ['local', 'end', 2000],
  ]);
  // No remote 'end' had happened when local onset fired, so no transition exists yet.
  check('no phantom transition before their turn ended', tt.transitions.length === 0, `${tt.transitions.length}`);
}

// ── 6. Breath rate and lead aggregation ─────────────────────────────────────
{
  console.log('\n6. aggregation across many turns');
  const script = [];
  let t = 0;
  const leads = [180, 240, 205, 0, 220]; // one turn opens with no breath
  for (const lead of leads) {
    script.push(['remote', 'onset', t], ['remote', 'classified', t + 35, { kind: 'voice' }], ['remote', 'end', t + 1000]);
    const on = t + 1000 + 200;
    script.push(['local', 'onset', on]);
    script.push(['local', 'classified', on + 35, { kind: lead ? 'breath' : 'voice' }]);
    if (lead) script.push(['local', 'voiced', on + lead, { leadMs: lead }]);
    script.push(['local', 'end', on + 900]);
    t = on + 900;
  }
  const { tt } = play(script);
  const s = tt.summary();
  const expectedLeads = leads.filter(Boolean);
  // These are all LOCAL openings, so they must land in the local buckets and leave
  // the remote ones empty. That separation is the point of the split.
  check('local lead count matches breath-opened turns', s.leadNLocal === expectedLeads.length, `${s.leadNLocal} of ${leads.length}`);
  check('local lead median correct', s.leadMedianLocal === median(expectedLeads), `${s.leadMedianLocal} vs ${median(expectedLeads)}`);
  check('local breath rate correct', s.breathRateLocal === 80, `${s.breathRateLocal}%`);
  check('remote buckets stay empty — no cross-contamination', s.leadN === 0 && s.leadMedian === null, `n=${s.leadN}, median=${s.leadMedian}`);
  check('remote breath rate is 0, not inherited from local', s.breathRate === 0, `${s.breathRate}%`);
  check('human median unaffected by lead', s.humanMedian === 200, `${s.humanMedian}`);
}

// ── 7. THE ONE REAL AUDIO FOUND: delivery order is not chronological ────────
{
  console.log('\n7. late-arriving ends do not destroy the transition');
  // Reproduces the delivery pattern measured on a real fixture. The detector cannot emit
  // an `end` until HANG_MS of quiet has accumulated, so an end describing t=28590 is
  // handed over at t=28940 — after the reply's onset at t=28910 has already been handed
  // over. Timestamps are correct; only the arrival sequence is wrong.
  //
  // Fed naively this produced a 16-second overlap where a 620 ms transition existed. The
  // script below is in *arrival* order, so it fails if the buffer is removed.
  const GAP = 620;
  const script = [];
  let t = 0;
  for (let i = 0; i < 5; i++) {
    // They speak for 2 s.
    script.push(['remote', 'onset', t], ['remote', 'classified', t + 35, { kind: 'breath' }]);
    const theirEnd = t + 2000;
    // I reply GAP after their end — which is *less* than the 350 ms hang, so my onset is
    // handed over first and their end arrives after it.
    const myOnset = theirEnd + GAP;
    script.push(['local', 'onset', myOnset]);
    script.push(['remote', 'end', theirEnd]); // late, out of order, on purpose
    script.push(['local', 'classified', myOnset + 35, { kind: 'breath' }]);
    script.push(['local', 'voiced', myOnset + 200, { leadMs: 200 }]);
    const myEnd = myOnset + 2000;
    script.push(['local', 'end', myEnd]);
    t = myEnd + GAP;
  }
  const { tt } = play(script);
  const s = tt.summary();
  const human = tt.transitions.filter((x) => x.metric === 'human' && !x.overlap && !x.lull && !x.backchannel);
  check('every human transition survives', human.length === 5, `${human.length} of 5`);
  check('the gap is the planted gap, not an overlap', s.humanMedian === GAP, `${s.humanMedian} vs ${GAP}`);
  check('no overlaps invented', s.discarded.overlap === 0, `${s.discarded.overlap}`);
  check('prior utterance durations are positive', tt.transitions.every((x) => x.priorUtteranceMs == null || x.priorUtteranceMs > 0));
  check('out-of-order arrivals were absorbed, not counted late', s.lateEvents === 0, `${s.lateEvents} late`);
  check('nothing left held after flush', s.pendingAtSummary === 0, `${s.pendingAtSummary} pending`);
}

// ── 8. An arrival too late to reorder is reported, not hidden ────────────────
{
  console.log('\n8. an arrival too late to reorder is counted');
  const tt = new TurnTaking(() => {});
  tt.remote_({ type: 'onset' }, 0);
  tt.local_({ type: 'onset' }, 5000);
  // This pushes the horizon past 5000, so the local onset is fed…
  tt.local_({ type: 'end' }, 9000);
  // …and only now does their end arrive, 4 s stale, after something newer already went
  // through. No hold time short of the whole call could have caught this one.
  tt.remote_({ type: 'end' }, 1000);
  tt.flush();
  const s = tt.summary();
  check('the out-of-order arrival is counted', s.lateEvents === 1, `${s.lateEvents}`);
  check('and still processed rather than dropped', tt.remote.endAt === 1000, `${tt.remote.endAt}`);
  check('a merely-stale arrival that still lands in order is not counted', (() => {
    const u = new TurnTaking(() => {});
    u.remote_({ type: 'onset' }, 0);
    u.local_({ type: 'onset' }, 5000); // horizon 4500 — releases the onset at 0 only
    u.remote_({ type: 'end' }, 1000); // stale, but 5000 is still held, so order survives
    u.flush();
    return u.summary().lateEvents === 0 && u.remote.endAt === 1000;
  })());
}

// ── 9. median() edge cases ──────────────────────────────────────────────────
{
  console.log('\n9. median');
  check('empty → null', median([]) === null);
  check('undefined → null', median(undefined) === null);
  check('odd length', median([3, 1, 2]) === 2);
  check('even length averages the middle two', median([1, 2, 3, 4]) === 2.5);
  check('does not mutate its input', (() => { const a = [3, 1, 2]; median(a); return a[0] === 3; })());
}

console.log(`\n${pass} passed, ${fail} failed\n`);
process.exit(fail === 0 ? 0 : 1);
