/**
 * Synthetic-signal tests for the onset detector.
 *
 * The point of this file is not coverage. It is to put a number on the claim the
 * whole design rests on: that a pre-turn inhale gives us a measurable head start
 * over the first word (DESIGN.md §1.1c-2). Test 6 measures exactly that, and if it
 * ever reports well under ~150 ms the design's largest lever is smaller than
 * claimed and §3.1 needs rewriting.
 *
 * Run: node core/onset.test.mjs
 */

import { OnsetDetector, SAMPLE_RATE } from './onset.js';

// ── Signal generators ────────────────────────────────────────────────────────
// Deterministic PRNG so a failure is always reproducible.
let seed = 0x2f6e2b1;
function rand() {
  seed ^= seed << 13;
  seed ^= seed >>> 17;
  seed ^= seed << 5;
  seed |= 0;
  return (seed >>> 0) / 0xffffffff - 0.5;
}

const ms = (n) => Math.round((n / 1000) * SAMPLE_RATE);

function silence(durMs) {
  return new Float32Array(ms(durMs));
}

/** Room tone: very low broadband noise. Must never trigger an onset. */
function roomTone(durMs, amp = 0.0012) {
  const out = new Float32Array(ms(durMs));
  for (let i = 0; i < out.length; i++) out[i] = rand() * 2 * amp;
  return out;
}

/**
 * A pre-turn inhale: broadband noise, tilted high, with a slow raised-cosine
 * attack. Real inhales are 200–500 ms; a turn-initial one sits at the long end.
 */
function breath(durMs = 280, amp = 0.035) {
  const n = ms(durMs);
  const out = new Float32Array(n);
  let hp = 0;
  let prev = 0;
  for (let i = 0; i < n; i++) {
    const w = rand() * 2;
    // First-order high-pass ≈ 1.5 kHz, to get the spectral tilt of an inhale.
    const a = 0.82;
    hp = a * (hp + w - prev);
    prev = w;
    // Raised-cosine attack over the first 40%, gentle decay after.
    const t = i / n;
    const env = t < 0.4 ? 0.5 * (1 - Math.cos((Math.PI * t) / 0.4)) : 1 - 0.5 * ((t - 0.4) / 0.6);
    out[i] = hp * amp * env;
  }
  return out;
}

/** Voiced speech: harmonic stack with 1/n rolloff plus a little aspiration. */
function voiced(durMs = 400, f0 = 118, amp = 0.18) {
  const n = ms(durMs);
  const out = new Float32Array(n);
  const harmonics = 14;
  for (let i = 0; i < n; i++) {
    const t = i / SAMPLE_RATE;
    let s = 0;
    for (let h = 1; h <= harmonics; h++) {
      if (f0 * h > SAMPLE_RATE / 2) break;
      s += Math.sin(2 * Math.PI * f0 * h * t) / h;
    }
    // Onset ramp over 8 ms — a real voice does not start instantaneously.
    const ramp = Math.min(1, i / ms(8));
    out[i] = (s * 0.35 + rand() * 0.06) * amp * ramp;
  }
  return out;
}

/** A keyboard click: loud, very short, gone. Should not read as a turn. */
function click(durMs = 4, amp = 0.3) {
  const n = ms(durMs);
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) out[i] = rand() * 2 * amp * (1 - i / n);
  return out;
}

/**
 * Inter-sentence residual: the exhales and mouth noise that fill the gap between
 * utterances on real recordings. Louder than room tone — measured on the
 * LibriSpeech corpus at −50…−40 dBFS against a −57 floor — but ~25 dB under the
 * speech peak. This is the signal shape behind the quiet-wall defect (test 15):
 * a fixed floor+3 dB end-gate can never close a turn over it.
 *
 * The slow amplitude wander matters twice: it keeps the 2-second range above the
 * flatness test's 3 dB (so the backstop does not rescue the old gate and hide the
 * defect), while staying under 2.5 dB of rise over any 20 ms window (so the
 * residual itself must not trip a fresh onset — the rise test, not the SNR gate,
 * is what protects idle here).
 */
function residual(durMs, amp = 0.008) {
  const n = ms(durMs);
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const wander = 1 + 0.55 * Math.sin((2 * Math.PI * i) / ms(500));
    out[i] = rand() * 2 * amp * wander;
  }
  return out;
}

function concat(...parts) {
  const total = parts.reduce((a, p) => a + p.length, 0);
  const out = new Float32Array(total);
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

/** Feed in 128-sample blocks — the AudioWorklet render quantum. */
function run(signal, opts) {
  const d = new OnsetDetector(opts);
  const events = [];
  for (let i = 0; i < signal.length; i += 128) {
    for (const e of d.push(signal.subarray(i, Math.min(i + 128, signal.length)))) {
      events.push({ ...e, atMs: (e.at / SAMPLE_RATE) * 1000 });
    }
  }
  return { events, detector: d };
}

// ── Harness ──────────────────────────────────────────────────────────────────
let pass = 0;
let fail = 0;
const notes = [];

function check(name, cond, detail = '') {
  if (cond) {
    pass++;
    console.log(`  ok    ${name}${detail ? `  — ${detail}` : ''}`);
  } else {
    fail++;
    console.log(`  FAIL  ${name}${detail ? `  — ${detail}` : ''}`);
  }
}

console.log('\nonset detector — synthetic signals\n');

// ── 1. Room tone must never fire ─────────────────────────────────────────────
{
  console.log('1. room tone alone (3 s)');
  const { events } = run(roomTone(3000));
  check('no onset on steady room tone', events.length === 0, `${events.length} events`);
}

// ── 2. Breath fires fast and is labelled breath ──────────────────────────────
// The 22 ms bound was 15 ms until the floor's fast-drop path was gated on persistence
// (FLOOR_DROP_HOLD_MS). That gate cost ~5 ms of apparent sensitivity, and the 5 ms was
// never real: measured on this exact signal, the ungated path settled the floor at
// -65.53 dBFS against a true room level of -63.20, so every onset was being judged
// against a threshold 2.35 dB too low. It is the same bias the asymmetric tracking rates
// had (2.7 dB, recorded in DESIGN.md §17.1) surviving in a second place. Trading 5 ms of
// onset latency against a floor that no longer collapses under packet loss — which
// inflated reported head starts by hundreds of milliseconds — is not a close call.
{
  console.log('\n2. room tone → breath');
  const lead = 600;
  const { events } = run(concat(roomTone(lead), breath(280), roomTone(900)));
  const onset = events.find((e) => e.type === 'onset');
  const cls = events.find((e) => e.type === 'classified');
  check('fired', !!onset);
  if (onset) {
    const lateBy = onset.atMs - lead;
    check('onset within 22 ms of true start', lateBy >= -6 && lateBy <= 22, `${lateBy.toFixed(1)} ms`);
  }
  check('classified as breath', cls?.kind === 'breath', cls ? `${cls.kind} (zcr=${cls.zcr.toFixed(3)}, tilt=${cls.tiltDb.toFixed(1)} dB, periodicity=${cls.periodicity.toFixed(2)})` : 'no classification');
}

// ── 3. Voice fires fast and is labelled voice ────────────────────────────────
{
  console.log('\n3. room tone → voiced speech');
  const lead = 600;
  const { events } = run(concat(roomTone(lead), voiced(400), roomTone(900)));
  const onset = events.find((e) => e.type === 'onset');
  const cls = events.find((e) => e.type === 'classified');
  check('fired', !!onset);
  if (onset) {
    const lateBy = onset.atMs - lead;
    check('onset within 22 ms of true start', lateBy >= -6 && lateBy <= 22, `${lateBy.toFixed(1)} ms`);
  }
  check('classified as voice', cls?.kind === 'voice', cls ? `${cls.kind} (periodicity=${cls.periodicity.toFixed(2)})` : 'no classification');
}

// ── 4. A click is not a turn ─────────────────────────────────────────────────
{
  console.log('\n4. room tone → keyboard click');
  const { events } = run(concat(roomTone(600), click(4), roomTone(900)));
  const cls = events.find((e) => e.type === 'classified');
  // It may well fire — the bias is toward firing, and that is correct. What must
  // not happen is a click being labelled a speech turn.
  check('not labelled voice or breath', !cls || cls.kind === 'transient', cls ? cls.kind : 'no onset at all');
}

// ── 5. Floor adapts to a noisy room ──────────────────────────────────────────
{
  console.log('\n5. loud room (20× tone) → voiced speech');
  const lead = 900;
  const { events, detector } = run(concat(roomTone(lead, 0.024), voiced(400), roomTone(600, 0.024)));
  const onset = events.find((e) => e.type === 'onset');
  check('still fires in a noisy room', !!onset, onset ? `${(onset.atMs - lead).toFixed(1)} ms late, floor ${detector.noiseFloorDb?.toFixed(1)} dB` : '');
  check('did not fire on the noise itself', !onset || onset.atMs >= lead - 10, onset ? `at ${onset.atMs.toFixed(0)} ms vs speech at ${lead}` : '');
}

// ── 6. THE MEASUREMENT: how much head start does the breath buy? ─────────────
{
  console.log('\n6. the 200 ms credit — breath, gap, then words');
  const lead = 600;
  const breathMs = 280;
  const gapMs = 60; // inhale ends, brief hold, phonation begins
  const signal = concat(roomTone(lead), breath(breathMs), roomTone(gapMs), voiced(420), roomTone(700));
  const { events } = run(signal);

  const onsets = events.filter((e) => e.type === 'onset');
  const trueVoiceStart = lead + breathMs + gapMs;

  check('detected at least one onset', onsets.length >= 1);
  const first = onsets[0];
  if (first) {
    const credit = trueVoiceStart - first.atMs;
    notes.push(`breath head start: ${credit.toFixed(0)} ms`);
    check(
      'breath buys >=150 ms of head start over the first word',
      credit >= 150,
      `${credit.toFixed(0)} ms (breath detected at ${first.atMs.toFixed(0)} ms, words at ${trueVoiceStart})`,
    );
    check(
      'head start is in the range the literature predicts (150–400 ms)',
      credit >= 150 && credit <= 400,
      `${credit.toFixed(0)} ms`,
    );
  }

  // The hangover must hold across the inhale→phonation gap, so this reads as ONE
  // turn rather than two. If it splits, Lane 0 would send two onset bursts and
  // the receiver would see a false turn boundary.
  check(
    'inhale and words read as a single turn',
    onsets.length === 1,
    `${onsets.length} onset(s)`,
  );
}

// ── 7. Two separate turns are still two turns ────────────────────────────────
{
  console.log('\n7. two turns separated by 800 ms');
  const { events } = run(
    concat(roomTone(600), voiced(350), roomTone(800), breath(260), roomTone(50), voiced(350), roomTone(600)),
  );
  const onsets = events.filter((e) => e.type === 'onset');
  const ends = events.filter((e) => e.type === 'end');
  check('two onsets', onsets.length === 2, `${onsets.length}`);
  check('at least one end emitted', ends.length >= 1, `${ends.length}`);
}

// ── 8. Cost: must be far cheaper than real time ──────────────────────────────
{
  console.log('\n8. cost');
  const signal = concat(roomTone(300), voiced(500), roomTone(300), breath(300), roomTone(600));
  const reps = 20;
  const t0 = process.hrtime.bigint();
  for (let r = 0; r < reps; r++) run(signal);
  const elapsedMs = Number(process.hrtime.bigint() - t0) / 1e6;
  const audioMs = ((signal.length / SAMPLE_RATE) * 1000 * reps);
  const realtimeFrac = elapsedMs / audioMs;
  notes.push(`cost: ${(realtimeFrac * 100).toFixed(2)}% of real time`);
  check(
    'under 5% of real time (fits an audio thread)',
    realtimeFrac < 0.05,
    `${(realtimeFrac * 100).toFixed(2)}% — ${elapsedMs.toFixed(0)} ms of CPU for ${(audioMs / 1000).toFixed(1)} s of audio`,
  );
}

// ── 9. Sensitivity sweep: where does the expensive failure start? ────────────
// A missed breath costs the whole 200 ms head start; a spurious one costs a single
// small datagram. So the only number worth knowing here is how quiet an inhale can
// get before we lose it, expressed against the room it sits in.
{
  console.log('\n9. quiet-breath sensitivity (room tone at 0.0012 ≈ −58 dB)');
  const lead = 700;
  const rows = [];
  for (const amp of [0.05, 0.035, 0.02, 0.012, 0.008, 0.005, 0.003, 0.002]) {
    const { events } = run(concat(roomTone(lead), breath(280, amp), roomTone(800)));
    const onset = events.find((e) => e.type === 'onset');
    const cls = events.find((e) => e.type === 'classified');
    rows.push({
      amp,
      snrOverRoom: (20 * Math.log10(amp / 0.0012)).toFixed(0) + ' dB',
      detected: !!onset,
      lateMs: onset ? (onset.atMs - lead).toFixed(0) : '—',
      kind: cls?.kind ?? '—',
    });
  }
  for (const r of rows) {
    console.log(
      `     amp ${String(r.amp).padEnd(6)} ${r.snrOverRoom.padStart(7)} over room  ` +
        `${r.detected ? 'detected' : 'MISSED  '}  late ${String(r.lateMs).padStart(4)} ms  ${r.kind}`,
    );
  }
  const quietest = rows.filter((r) => r.detected).pop();
  notes.push(`detection floor: breath at amp ${quietest?.amp} (${quietest?.snrOverRoom} over room tone)`);
  check(
    'detects a breath only 20 dB above room tone',
    rows.find((r) => r.amp === 0.012)?.detected === true,
    `amp 0.012 = ${rows.find((r) => r.amp === 0.012)?.snrOverRoom} over room`,
  );
  // Latency is a function of how far the breath sits above the room, not a single
  // number, and stating it as one hid that. A loud inhale must be caught almost
  // immediately, because that is the common case and the whole 200 ms credit rides on
  // it. A breath only a few dB over the noise inevitably takes longer — its attack has
  // to climb through the noise before any threshold can be crossed — and that is
  // acceptable *because the error is conservative*: a late onset shortens the reported
  // lead rather than inflating it, which test 10 confirms as a negative mean bias. The
  // design under-claims in exactly the conditions where it is least sure.
  const loud = rows.filter((r) => r.detected && r.amp >= 0.008); // ≥16 dB over room
  const faint = rows.filter((r) => r.detected && r.amp < 0.008);
  check(
    // 45 ms, up from 35, for the reason recorded at test 2: the floor is no longer
    // biased low, so the threshold is honest and the detector is a hop slower.
    'a clearly audible inhale (≥16 dB over room) is caught within 45 ms',
    loud.every((r) => Number(r.lateMs) <= 45),
    `worst ${Math.max(...loud.map((r) => Number(r.lateMs)))} ms over ${loud.length} levels`,
  );
  check(
    'a near-threshold inhale degrades gracefully rather than being missed',
    faint.every((r) => Number(r.lateMs) <= 70),
    `worst ${faint.length ? Math.max(...faint.map((r) => Number(r.lateMs))) : 0} ms`,
  );
}

// ── 10. The `voiced` event must report a lead we can trust ───────────────────
// Test 6 showed the detector captures the head start. This checks it can *report*
// it accurately, because that reported number is what the turn-taking harness will
// use as evidence — and a measurement instrument that flatters itself is worse than
// no instrument. Ground truth is known exactly here, so any bias shows up directly.
{
  console.log('\n10. reported lead vs ground truth');
  const lead = 600;
  const rows = [];
  for (const [breathMs, gapMs] of [[280, 60], [220, 40], [350, 90], [180, 20], [450, 120]]) {
    const truth = breathMs + gapMs;
    const { events } = run(
      concat(roomTone(lead), breath(breathMs), roomTone(gapMs), voiced(420), roomTone(700)),
    );
    const v = events.find((e) => e.type === 'voiced');
    rows.push({ truth, reported: v ? v.leadMs : null, err: v ? v.leadMs - truth : null });
  }
  for (const r of rows) {
    console.log(
      `     truth ${String(r.truth).padStart(3)} ms → reported ` +
        `${r.reported === null ? 'MISSED' : r.reported.toFixed(0).padStart(3) + ' ms'}` +
        `${r.err === null ? '' : `  (err ${r.err > 0 ? '+' : ''}${r.err.toFixed(0)} ms)`}`,
    );
  }
  check('every breath-opened turn reported a lead', rows.every((r) => r.reported !== null));
  const errs = rows.filter((r) => r.err !== null).map((r) => r.err);
  if (errs.length) {
    const worst = Math.max(...errs.map(Math.abs));
    const bias = errs.reduce((a, b) => a + b, 0) / errs.length;
    notes.push(`reported-lead error: worst ${worst.toFixed(0)} ms, mean bias ${bias > 0 ? '+' : ''}${bias.toFixed(0)} ms`);
    // 50 ms, up from 40, for the reason at test 2. Note the direction: the error is
    // entirely negative, so the detector now under-reports the head start slightly more
    // than it did. Under-reporting is the safe direction — it costs accuracy, whereas
    // over-reporting would flatter §3.1 lever 1.
    check('accurate within 50 ms', worst <= 50, `worst ${worst.toFixed(0)} ms`);
    check(
      'does not over-report the lead (bias must not flatter the design)',
      bias <= 10,
      `mean bias ${bias > 0 ? '+' : ''}${bias.toFixed(0)} ms`,
    );
  }
}

// ── 11. THE LATCH: a stream that opens with digital silence ──────────────────
// A regression test for a real failure found by running two real browsers against
// each other, not by reasoning about the code. Chrome's fake audio device emits exact
// zeros for its first buffers — and so do plenty of real ones: a muted input, a driver
// spinning up its stream, a Bluetooth link that has not settled.
//
// Before the fix, those zeros calibrated the floor to about -320 dBFS. Ordinary room
// tone then measured 262 dB above "silence", an onset fired immediately, and since the
// floor is deliberately frozen while a turn is active, SNR could never fall back below
// END_SNR_DB. The turn never ended, so the floor never thawed. The detector latched on
// the first sound it ever heard and emitted nothing for the rest of the call.
//
// That failure is invisible in every other test in this file because they all begin
// with realistic room tone. It is also the worst shape a failure can take here: three
// plausible events followed by silence is indistinguishable from a quiet room.
{
  console.log('\n11. stream opens with digital silence (the latch)');
  const sig = concat(
    silence(400), // exact zeros, as a real capture start delivers
    roomTone(500),
    breath(260),
    roomTone(50),
    voiced(500),
    roomTone(600),
    breath(240), // a SECOND turn — the one the latch used to eat
    roomTone(50),
    voiced(500),
    roomTone(600),
  );
  const { events, detector } = run(sig);
  const onsets = events.filter((e) => e.type === 'onset');
  const ends = events.filter((e) => e.type === 'end');

  check('floor is physically plausible, not -320 dB', detector.floorDb > -90, `${detector.floorDb?.toFixed(1)} dBFS`);
  check(
    'no onset reports an absurd SNR',
    onsets.every((e) => e.snrDb < 80),
    `max ${Math.max(...onsets.map((e) => e.snrDb)).toFixed(1)} dB`,
  );
  check('turns actually end', ends.length >= 2, `${ends.length} ends`);
  check('the second turn is still detected', onsets.length >= 2, `${onsets.length} onsets`);
  check('never had to force an end', detector.forcedEnds === 0, `${detector.forcedEnds} forced`);
  check('floor is reported on the onset event', onsets[0]?.floorDb != null);
  // The leading zeros must not be mistaken for a quiet room the detector has measured.
  const firstOnsetMs = onsets[0]?.atMs ?? 0;
  check('did not fire during the silence', firstOnsetMs > 400, `first onset at ${firstOnsetMs.toFixed(0)} ms`);
}

// ── 12. The turn cap, independent of the floor ───────────────────────────────
// Belt and braces for the same failure class. If some future change again pins SNR
// above END_SNR_DB, the detector must recover on its own rather than going quiet.
{
  console.log('\n12. a wedged turn recovers on its own');
  const d = new OnsetDetector();
  const events = [];
  // Establish a normal floor, then feed 35 s of unbroken loud noise — longer than any
  // human utterance, so reaching the cap is the only correct behaviour.
  const feed = (sig) => {
    for (let i = 0; i < sig.length; i += 128) {
      for (const e of d.push(sig.subarray(i, Math.min(i + 128, sig.length)))) events.push(e);
    }
  };
  feed(roomTone(500));
  feed(voiced(35000));
  const forced = events.filter((e) => e.type === 'end' && e.forced);
  check('forced an end rather than latching', forced.length === 1, `${forced.length} forced ends`);
  // Not the flatness test: a harmonic stack has enough hop-to-hop RMS variation
  // (measured 5.84 dB over 2 s) to look modulated. It is the never-quiet test that
  // catches it, at 8 s rather than 30. Between them the two tests leave the 30-second cap
  // unreachable by anything this suite can construct, which is the right place for it —
  // a backstop should only fire on something nobody anticipated.
  check('caught by the never-quiet test', forced[0]?.reason === 'never-quiet', String(forced[0]?.reason));
  check('at 8 s, not 30', forced[0] && forced[0].durationMs < 9000, `${Math.round(forced[0]?.durationMs ?? -1)} ms`);
  check('returned to idle', d.state === 'idle', d.state);
  check('discarded the suspect floor', d.floorDb === null || d.floorDb > -90, String(d.floorDb));
  // And it must still work afterwards.
  feed(roomTone(600));
  feed(breath(260));
  feed(roomTone(50));
  feed(voiced(400));
  feed(roomTone(600));
  check(
    'still detects a turn after recovering',
    events.filter((e) => e.type === 'onset').length >= 2,
    `${events.filter((e) => e.type === 'onset').length} onsets total`,
  );
}

// ── 13a. A floor calibrated before the audio arrives must repair itself ──────
// The real bug, from a real call. The received-audio detector calibrates while the peer
// connection is still filling — the output is near-silent but not digitally silent, so it
// is accepted as a room. Then the actual room tone arrives 15 dB louder, opens a turn, and
// the drift clamp (whose whole job is to stop the floor climbing during a turn) is what
// prevents the floor from ever catching up. Measured on a 110-second call: two turns ran
// to the 30-second cap and swallowed the opening exchanges.
//
// The fix cannot be "raise the clamp", because during real speech the clamp is right. It
// has to distinguish a wrong floor from a long sentence, and modulation is what does that.
{
  console.log('\n13a. a floor calibrated against pre-media quiet repairs itself');
  const d = new OnsetDetector();
  const events = [];
  const feed = (sig) => {
    for (let i = 0; i < sig.length; i += 128) {
      for (const e of d.push(sig.subarray(i, Math.min(i + 128, sig.length)))) events.push(e);
    }
  };
  // Quiet enough to be nothing like a room, loud enough to clear FLOOR_MIN_DB and be
  // accepted as one — which is exactly the trap.
  feed(roomTone(700, 0.0002));
  const floorBefore = d.floorDb;
  // The stream comes up. A 15 dB step, the same size as the one measured on the call.
  feed(roomTone(6000, 0.0012));
  const forced = events.filter((e) => e.type === 'end' && e.forced);
  check('the step opened a turn, as it should', events.some((e) => e.type === 'onset'));
  check('the turn was closed, not left wedged', forced.length >= 1, `${forced.length} forced ends`);
  check('closed by the flatness test', forced[0]?.reason === 'flat', String(forced[0]?.reason));
  check(
    'within a few seconds, not thirty',
    forced[0] && forced[0].durationMs < 3500,
    `${Math.round(forced[0]?.durationMs ?? -1)} ms`,
  );
  check('and the floor moved up to the real room', d.floorDb === null || d.floorDb > floorBefore + 6,
    `${floorBefore?.toFixed(1)} → ${d.floorDb == null ? 'reset' : d.floorDb.toFixed(1)} dBFS`);
  // The point of repairing rather than merely surviving: it has to work afterwards.
  feed(roomTone(700, 0.0012));
  feed(breath(260));
  feed(roomTone(50, 0.0012));
  feed(voiced(500));
  feed(roomTone(700, 0.0012));
  const later = events.filter((e) => e.type === 'classified' && e.kind === 'breath');
  check('detects a breath-opened turn once repaired', later.length >= 1, `${later.length} breath turns`);
}

// ── 13b. The flatness test must not cut real speech short ────────────────────
// The false-positive side, and the reason FLAT_RANGE_DB is 3 rather than 6. Two
// independent measurements agree on where the boundary is: the quietest real speech on a
// recorded call varied by 5.9 dB over 1.5 s, and the synthetic voiced fixture here varies
// by 5.84 dB over 2 s. A threshold at 6 would have clipped both.
{
  console.log('\n13b. a long modulated turn is not cut short');
  const d = new OnsetDetector();
  const events = [];
  const feed = (sig) => {
    for (let i = 0; i < sig.length; i += 128) {
      for (const e of d.push(sig.subarray(i, Math.min(i + 128, sig.length)))) events.push(e);
    }
  };
  feed(roomTone(600));
  // Twelve seconds of speech modulated by only 6 dB — the tightest case that must survive
  // — with pauses too short to end the turn.
  const parts = [];
  for (let i = 0; i < 12; i++) {
    parts.push(voiced(700, 118, i % 2 ? 0.18 : 0.09));
    parts.push(roomTone(150));
  }
  feed(concat(...parts));
  feed(roomTone(700));
  const forced = events.filter((e) => e.type === 'end' && e.forced);
  const ends = events.filter((e) => e.type === 'end');
  check('no forced end', forced.length === 0, `${forced.length} forced (${forced.map((e) => e.reason).join(',')})`);
  check('the turn ran its full length', ends.some((e) => e.durationMs > 9000),
    `longest turn ${Math.round(Math.max(0, ...ends.map((e) => e.durationMs)))} ms`);
}

// ── 13. Ends must survive a noisy room, not just a quiet one ─────────────────
// The second regression from running real audio. `quietHops` used to require 350 ms of
// *consecutive* quiet, resetting to zero on any single hop above END_SNR_DB. Hop-level
// RMS over 5 ms fluctuates by more than 3 dB often enough that the run frequently never
// completed: on a real capture one turn stayed open for 11.8 s across nine seconds of
// silence, and a 4 ms click took 1505 ms to close.
//
// The room tone here is deliberately lumpy — a low-frequency wander that makes some
// hops cross the threshold — which is what a real room does and what the old flat
// synthetic tone did not.
{
  console.log('\n13. turns end in a room whose noise wobbles');
  // Room tone with a slow amplitude wander, so individual hops cross END_SNR_DB.
  const lumpyTone = (durMs) => {
    const n = ms(durMs);
    const out = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      const wander = 1 + 0.5 * Math.sin((2 * Math.PI * i) / ms(140)) * Math.sin((2 * Math.PI * i) / ms(37));
      out[i] = rand() * 2 * 0.0012 * wander;
    }
    return out;
  };

  // Check the fixture is in the regime this test is about, before testing anything.
  // Too flat and the test passes trivially; too lumpy and the wander trips the onset
  // threshold itself, which tests something else entirely. The target window is: a
  // meaningful share of hops above END_SNR_DB (3 dB), essentially none above
  // ONSET_SNR_DB (5 dB).
  {
    const probe = lumpyTone(6000);
    const hops = [];
    for (let i = 0; i + 240 <= probe.length; i += 240) {
      let s = 0;
      for (let j = 0; j < 240; j++) s += probe[i + j] * probe[i + j];
      hops.push(20 * Math.log10(Math.sqrt(s / 240) + 1e-12));
    }
    const mean = hops.reduce((a, b) => a + b, 0) / hops.length;
    const over = (t) => hops.filter((d) => d - mean > t).length / hops.length;
    const o3 = over(3), o5 = over(5);
    console.log(`     fixture: ${(o3 * 100).toFixed(1)}% of hops above 3 dB, ${(o5 * 100).toFixed(1)}% above 5 dB`);
    // With this share above 3 dB, the odds of 70 consecutive quiet hops — what the old
    // rule demanded — are (1-o3)^70, which is the reason the old code hung.
    console.log(`     old consecutive rule would have closed a turn with probability ${((1 - o3) ** 70 * 100).toFixed(1)}%`);
    check('fixture crosses the end threshold often enough to be a real test', o3 > 0.04, `${(o3 * 100).toFixed(1)}%`);
    check('fixture does not trip the onset threshold', o5 < 0.005, `${(o5 * 100).toFixed(1)}%`);
  }

  const { events } = run(
    concat(lumpyTone(900), breath(260), lumpyTone(50), voiced(600), lumpyTone(2500),
           breath(240), lumpyTone(50), voiced(600), lumpyTone(2500)),
  );
  const onsets = events.filter((e) => e.type === 'onset');
  const ends = events.filter((e) => e.type === 'end');
  check('both turns detected', onsets.length === 2, `${onsets.length} onsets`);
  check('both turns ended', ends.length === 2, `${ends.length} ends`);
  check('no end had to be forced', !ends.some((e) => e.forced));
  // A turn that ends promptly is the whole point: a late end shrinks the *next*
  // measured gap, and it is the gap that the design is judged on.
  if (ends.length === 2) {
    const durs = ends.map((e) => e.durationMs);
    // breath 260 + 50 + voiced 600 ≈ 910 ms of real activity.
    check(
      'reported duration is close to the real activity, not inflated by a late end',
      durs.every((d) => d > 700 && d < 1500),
      durs.map((d) => Math.round(d) + ' ms').join(', '),
    );
  }
}

// ── 14. A jitter-buffer underrun must not drag the floor down ────────────────
// This is the receive-path failure from DESIGN.md §17.1, reproduced without a network.
// A brief near-silent gap in received audio is a level drop of exactly the size the
// fast-drop path is looking for. If it chases it, the floor lands below the room, the
// threshold follows, and the next hop of ordinary room tone fires a false onset — which
// gets reported as a several-hundred-millisecond breath head start.
{
  console.log('\n14. brief received-audio dropouts (the lossy-network case)');
  // -infinity would be excluded as digital silence, which is the *clean* case and already
  // handled. An underrun is concealed audio fading out: quiet, but real.
  const underrun = (durMs) => roomTone(durMs, 0.0012 / 8); // ~18 dB down
  const tone = (durMs) => roomTone(durMs);

  // Sixteen 40 ms dropouts over 16 s of otherwise steady room tone — about the rate
  // measured at 1% loss, and every one shorter than FLOOR_DROP_HOLD_MS.
  const parts = [tone(1200)];
  for (let i = 0; i < 16; i++) parts.push(underrun(40), tone(960));
  const { events, detector } = run(concat(...parts));
  const onsets = events.filter((e) => e.type === 'onset');
  check('no false onset from transient dropouts', onsets.length === 0, `${onsets.length} onsets`);
  // The floor must still describe the room, not the dropouts. Room tone here is about
  // -62 dBFS; chasing the dips would put it near -80.
  const floor = detector.floorDb;
  check(
    'floor still describes the room, not the gaps',
    floor !== null && floor > -70,
    floor === null ? 'no floor' : `${floor.toFixed(1)} dBFS`,
  );

  // The inverse must still work, or the fix has broken what the fast path was for: a room
  // that genuinely gets quieter has to be followed, and quickly.
  const before = run(concat(tone(2000))).detector.floorDb;
  const { detector: after } = run(concat(tone(2000), underrun(1500)));
  check(
    'a sustained level drop is still chased',
    after.floorDb !== null && after.floorDb < before - 8,
    `${before.toFixed(1)} → ${after.floorDb.toFixed(1)} dBFS`,
  );
  // And it must be chased *fast* — that is the entire reason the path exists. At the slow
  // rate a 12 dB drop would take about a second; the fast path should do it in ~250 ms.
  const { detector: quick } = run(concat(tone(2000), underrun(350)));
  check(
    'and chased quickly once it has persisted',
    quick.floorDb !== null && quick.floorDb < before - 5,
    `${before.toFixed(1)} → ${quick.floorDb.toFixed(1)} dBFS after 350 ms`,
  );
}

// ── 15. The quiet wall: turns must close on a quiet floor ────────────────────
// The defect measured on the 209-file corpus (DESIGN.md §17.1 addendum): at a
// −57 dBFS floor the inter-sentence residual sits at −50…−40 dBFS, 7–17 dB above
// the floor, so a fixed floor+3 end-gate is never crossed — 60% of utterances
// merged into the previous turn and got no fresh onset at all. What separates
// "the talker stopped" from mouth noise in a quiet room is distance from the
// *speech*, not distance from the floor, so the gate is now the higher of
// floor+3 and this turn's peak minus TURN_DROP_DB.
//
// The pre-fix configuration is reproduced exactly by { turnDropDb: 1000 }: the
// peak term then sits a thousand dB under the floor term and the gate degenerates
// to the old fixed 3 dB. Both configurations run the SAME signal instance, so
// any difference is the gate and nothing else.
{
  console.log('\n15. quiet floor, residual between utterances (the quiet wall)');
  // speech 600–1100, residual 1100–4100, speech 4100–4500, room tone to 5500.
  const sig = concat(roomTone(600), voiced(500), residual(3000), voiced(400), roomTone(1000));

  const after = run(sig);
  const onsets = after.events.filter((e) => e.type === 'onset');
  const ends = after.events.filter((e) => e.type === 'end');
  check('both utterances get a fresh onset', onsets.length === 2, `${onsets.length} onsets`);
  check('the first turn closed on its own, not via a backstop', ends.length >= 1 && !ends[0].forced,
    ends[0] ? `end at ${ends[0].atMs.toFixed(0)} ms${ends[0].forced ? ` (forced: ${ends[0].reason})` : ''}` : 'no end');
  // Speech stopped at 1100; the end is stamped where the quiet run began.
  check('the end is stamped where speech stopped, not seconds late',
    ends.length >= 1 && ends[0].atMs > 1000 && ends[0].atMs < 1700,
    `${ends[0]?.atMs.toFixed(0)} ms (speech ended at 1100)`);

  const before = run(sig, { turnDropDb: 1000 });
  const bOnsets = before.events.filter((e) => e.type === 'onset');
  check('with the old fixed gate the second utterance MERGES — the corpus defect',
    bOnsets.length === 1, `${bOnsets.length} onset(s) (was 60% of utterances on the corpus)`);
}

// ── 15b. …but a loud floor must measure bit-identical to before ──────────────
// At a loud floor the floor term already dominates the gate (speech peaks ≈
// −14 dBFS; −14 − 20 = −34, under floor+3 once the floor is above −37), so the
// new term is dead weight there by construction — that is what TURN_DROP_DB = 20
// was chosen for, and it is why the loud-floor false-alarm counts on the corpus
// were bit-identical before and after. Pin it: same loud-room signal through
// both configurations must produce the same ends at the same timestamps.
{
  console.log('\n15b. loud floor: the peak term never engages');
  const tone = (d) => roomTone(d, 0.024); // ≈ −32 dBFS
  const sig = concat(tone(900), voiced(500), tone(3000), voiced(400), tone(800));
  const endsOf = (evts) => evts.filter((e) => e.type === 'end').map((e) => Math.round(e.atMs));
  const a = endsOf(run(sig).events);
  const b = endsOf(run(sig, { turnDropDb: 1000 }).events);
  check('identical ends, identical times, old gate vs new',
    a.length === 2 && a.join() === b.join(), `[${a.join(', ')}] vs [${b.join(', ')}]`);
  check('and they are natural ends, not backstops',
    run(sig).events.filter((e) => e.type === 'end').every((e) => !e.forced));
}

// ── 16. The second look: voice → breath revision, gated on the floor ─────────
// The second corpus defect: a real breath follows a loud exhale, so the onset
// fires early on the sub-threshold ramp and the 35 ms classification measures
// the *context* — low-tilt, quasi-periodic — and says 'voice'. On the corpus
// only 16% of detected real breaths were labelled breath. The fix is one second
// look at 150 ms on windowed features (the audio since 70 ms, which the exhale
// prefix cannot poison), revision only ever voice→breath — and only where the
// physics allows a breath to exist: §17.1's window shuts around −45 dBFS of room
// noise, so above RECLASS_MAX_FLOOR_DB a breath-shaped window is breath-shaped
// *speech* and must not flip. Measured ungated: +4 real breaths at loud floors
// against 24 flipped speech onsets — a 6:1 trade against the design.
//
// The fixture: an 80 ms voiced mumble (periodic, low-tilt — the exhale tail)
// running straight into a loud inhale body, then a gap, then words. 45 ms into
// the turn the pitch ring still holds the mumble, so the first look says voice;
// the window at 70–150 ms is all breath.
{
  console.log('\n16. breath riding an exhale tail: the second look, and its floor gate');
  const mk = (toneAmp, mumbleAmp, breathAmp, wordAmp) => concat(
    roomTone(700, toneAmp),
    voiced(45, 100, mumbleAmp),   // the context: periodic, low-tilt
    breath(260, breathAmp),       // the event the first look cannot see
    roomTone(60, toneAmp),
    voiced(400, 118, wordAmp),    // phonation — what the head start is measured against
    roomTone(900, toneAmp),
  );
  // mumble 700–745, breath 745–1005, gap, words 1065–1465; truth lead ≈ 365 ms.

  const quiet = run(mk(0.0012, 0.02, 0.06, 0.12));
  const qCls = quiet.events.filter((e) => e.type === 'classified');
  check('first look says voice (it measured the context)', qCls[0]?.kind === 'voice',
    `${qCls[0]?.kind} (periodicity ${qCls[0]?.periodicity?.toFixed(2)})`);
  const revised = qCls.find((e) => e.revised);
  check('second look revises to breath on a quiet floor', revised?.kind === 'breath',
    revised ? `at ${revised.atMs.toFixed(0)} ms, aperiodic frac ${revised.aperiodicFrac?.toFixed(2)}` : 'no revision');
  const qVoiced = quiet.events.find((e) => e.type === 'voiced');
  check('and the head start is recovered', qVoiced && qVoiced.leadMs > 250 && qVoiced.leadMs < 500,
    qVoiced ? `${qVoiced.leadMs.toFixed(0)} ms (truth ≈ 365)` : 'no voiced event');

  // The old configuration — no second look — leaves the turn mislabelled and the
  // head start unmeasured. This is the 16% the corpus measured, in miniature.
  const oldQuiet = run(mk(0.0012, 0.02, 0.06, 0.12), { reclassifyMs: 1e9 });
  check('without the second look the same breath stays voice — the corpus defect',
    oldQuiet.events.filter((e) => e.type === 'classified').every((e) => e.kind === 'voice' && !e.revised) &&
    !oldQuiet.events.some((e) => e.type === 'voiced'));

  // The gate: the identical shape at a −38 dBFS floor must NOT revise. A real
  // breath cannot clear a loud room (§17.1), so breath-shaped audio there is
  // speech — flipping it traded 24 speech onsets for 4 breaths on the corpus.
  const loud = run(mk(0.02, 0.15, 0.3, 0.5));
  const lCls = loud.events.filter((e) => e.type === 'classified');
  check('on a loud floor the same shape stays speech (the gate holds)',
    lCls.length === 1 && lCls[0].kind === 'voice' && !lCls.some((e) => e.revised),
    `${lCls.length} classification(s), floor at onset ${loud.events.find((e) => e.type === 'onset')?.floorDb?.toFixed(1)} dBFS`);
}

// ── 17. A breath-opened turn must survive the breath → speech lull ───────────
// Measured on the corpus: breath→speech lulls run 10–1700 ms (median ~530), so
// the ordinary 350 ms hang closed the turn inside the lull — and closing it
// silently discarded the head start the detector had correctly earned, because
// `voiced` can only fire while the turn is still open. A breath-opened turn now
// waits up to 1200 ms for phonation. The reported end time is unaffected: it is
// stamped where the quiet run began, and the voiced-watch clears the leaky hang
// counter the moment phonation is unambiguous.
{
  console.log('\n17. breath, 700 ms lull, then words (the await-voice hang)');
  // breath 600–880, lull 880–1580, words 1580–2000; truth lead 980 ms.
  const sig = concat(roomTone(600), breath(280), roomTone(700), voiced(420), roomTone(800));

  const { events } = run(sig);
  const onsets = events.filter((e) => e.type === 'onset');
  const ends = events.filter((e) => e.type === 'end');
  const v = events.find((e) => e.type === 'voiced');
  check('breath, lull and words read as ONE turn', onsets.length === 1, `${onsets.length} onsets`);
  check('the head start survives the lull', v && v.leadMs > 800 && v.leadMs < 1100,
    v ? `${v.leadMs.toFixed(0)} ms (truth 980)` : 'no voiced event');
  check('the end is still stamped where the audio actually stopped',
    ends.length === 1 && ends[0].atMs > 1950 && ends[0].atMs < 2300,
    `${ends[0]?.atMs.toFixed(0)} ms (words ended at 2000)`);

  // The old 350 ms hang: the turn closes in the lull, the words open a second
  // turn, and the lead the breath earned is never reported.
  const old = run(sig, { awaitVoiceHangMs: 350 });
  const oOnsets = old.events.filter((e) => e.type === 'onset');
  check('with the old hang the lull splits the turn and the lead is lost — the corpus defect',
    oOnsets.length === 2 && !old.events.some((e) => e.type === 'voiced'),
    `${oOnsets.length} onsets, voiced events: ${old.events.filter((e) => e.type === 'voiced').length}`);
}

console.log(`\n${pass} passed, ${fail} failed`);
for (const n of notes) console.log(`  · ${n}`);
console.log();
process.exit(fail === 0 ? 0 : 1);
