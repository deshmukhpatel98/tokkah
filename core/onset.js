/**
 * Voice-onset and breath detection on raw 48 kHz PCM.
 *
 * This is the most valuable 200 ms in the design (DESIGN.md §1.1c-2, §3.1 lever 1,
 * §4 Lane 0). A speaker inhales ~200 ms before phonation, and inhalations before a
 * new turn are longer and deeper than within-turn ones — so the breath, not the
 * first word, is the earliest honest evidence that a reply is coming. Every
 * commercial call product deletes it as noise. We transmit it, and we transmit it
 * *first*.
 *
 * Two deliberate architectural choices:
 *
 * 1. ONSET IS DECIDED ON ENERGY ALONE. Classification (breath vs voice) needs at
 *    least two pitch periods — up to ~28 ms — and waiting for it would spend a
 *    third of the head start we are trying to win. So the state machine fires the
 *    onset in one or two hops (5–10 ms) and labels it later. The label is telemetry
 *    and predictor input; it never gates the send.
 *
 * 2. THE BIAS IS ASYMMETRIC ON PURPOSE. A false positive costs one ~60 kbps
 *    datagram. A false negative costs the entire 200 ms. Every threshold here is
 *    tuned to fire early and apologise afterwards, which is the opposite of how a
 *    VAD for bandwidth-saving is tuned. Do not "improve" the precision of this
 *    module without re-reading that sentence.
 *
 * No browser dependencies: this runs identically under an AudioWorklet and under
 * node, which is how it gets tested against synthetic signals. Intended to be
 * ported to the shared Rust core (§19.3) — kept free of allocation in the hot path
 * for that reason.
 */

export const SAMPLE_RATE = 48000;
export const HOP = 240; // 5 ms. Sets the detection-latency floor.

// ── Tuning ───────────────────────────────────────────────────────────────────
// Thresholds are in dB above the tracked noise floor, not absolute — the floor
// moves with the room, and an absolute gate would fail in either a quiet studio
// or a noisy office depending on which one you tuned it in.
// Retuned downward from 7 dB when the floor tracker was corrected below. The old floor
// settled about 2.7 dB under the room's actual level, so a nominal 7 dB threshold was
// really ~4.3 dB above the room — the detector was more sensitive than its constant
// claimed, and its measured sensitivity was partly an artefact of the biased floor.
// With the floor now centred, 5 dB restores the behaviour that was actually being
// measured while keeping honest margin over noise wobble, which is ±1.2 dB at three
// sigma for an RMS estimate over a 5 ms hop.
const ONSET_SNR_DB = 5; // fire here
const END_SNR_DB = 3; // and stop here — hysteresis, so a fading tail doesn't chatter
// A fixed floor-relative end-gate cannot close a turn in a studio-quiet room. Measured
// on the 209-file LibriSpeech corpus (testbed/corpus-score.mjs): at a −57 dBFS floor the
// inter-sentence residual — exhales, mouth noise — sits at −50…−40 dBFS, 7–17 dB above
// the floor, so a floor+3 gate is never crossed, 60% of utterances merge into the previous
// turn and get no fresh onset, and the breath head-start measurement silently vanishes in
// exactly the quiet rooms §17.1 calls the good case. At a −30 dBFS floor the merge rate is
// 3%: the same residual falls *under* floor+3 because the floor itself is louder.
//
// What separates "the talker stopped" from room noise in a quiet room is not distance from
// the floor but distance from the speech: gap residual was measured at p95 ≈ −24 dBFS
// against segment peaks of −14 (testbed/gap-levels.mjs) — the residual sits 8–10+ dB under
// the turn's own peak, while within-speech modulation keeps at least a fifth of hops well
// inside that margin (a vowel lands every ~200 ms). So the gate becomes the higher of the
// old floor-relative gate and this turn's peak minus TURN_DROP_DB. At loud floors the
// floor term already dominates and behaviour is unchanged; at quiet floors the peak term
// takes over and the turn can end. The value is a sweep measurement (corpus merge rate vs
// false-alarm rate), not a guess: swept 8–20 dB, smaller values close more turns (clean
// merge 3.4% at 8) but charge false alarms at the loud floors (51→63 at −35 dBFS for 12);
// 20 dB is the smallest value whose peak term falls under floor+3 at the −35 floor
// (speech peaks ≈ −14 dBFS: −14 − 20 = −34 < −32), so the loud floors measure
// bit-identical — false alarms 30/51/93 at −40/−35/−30, before and after — while the
// clean-floor merge rate still falls 60%→19%.
const TURN_DROP_DB = 20;
const HANG_MS = 350; // silence needed to call a turn over. Longer than a within-
//                      sentence pause, shorter than a turn gap.
// While a breath-opened turn waits for phonation, the hang is much longer: measured
// breath→speech lulls on the corpus run 10–1700 ms (median ~530), so a 350 ms hang
// closes the turn in the lull and the head-start event is lost even when the breath
// itself was classified correctly. The reported end time is unaffected (it is stamped
// where the quiet run began); the cost of the longer hold is only that the detector
// stays busy — and the hold is bounded, so a sigh that never becomes speech still ends.
const AWAIT_VOICE_HANG_MS = 1200;
// How much a single loud hop sets the hang counter back. This exists because requiring
// 350 ms of *consecutive* quiet was wrong, and wrong in a way that only real audio
// showed: with a hard reset, one hop above the threshold in seventy discards the whole
// run. Hop-level RMS over 5 ms fluctuates by more than END_SNR_DB often enough that the
// run frequently never completes — measured on a real capture, one turn stayed open for
// 11.8 s through nine seconds of silence, and a marker click took 1505 ms to close
// instead of 350. A turn that cannot end produces no transition, so this single line
// decided whether the instrument reported anything at all.
//
// "The other person stopped talking" means mostly quiet, not perfectly quiet — real
// speech tails carry lip smacks, an exhale, a chair creak. A penalty of 4 tolerates
// roughly 20% of hops being loud, which is that idea made arithmetic.
const HANG_PENALTY = 4;
const CLASSIFY_MS = 35; // enough for two pitch periods at 70 Hz
const CALIBRATE_MS = 150; // floor is untrustworthy before this
const RISE_DB = 2.5; // must be rising, not just loud — rejects a fan spinning up

// Floor tracking.
//
// The floor estimates the room's level, so it is a near-symmetric EMA. An earlier
// version used a strongly asymmetric 0.25-down / 0.0015-up pair, and that was wrong in a
// way only real audio exposed: at a 167:1 ratio the estimate does not settle at the
// room's level, it settles deep in the lower tail of the noise. Ordinary room tone then
// measured ~2.7 dB above its own floor while END_SNR_DB was 3 — so whether a turn could
// ever end came down to half a decibel of noise wobble. When it went the wrong way the
// turn never ended, and a detector that cannot end a turn cannot report a single turn
// transition.
//
// Centred on the level instead, quiet measures ~0 dB, which puts real margin under both
// thresholds. Verified on a real capture: idle SNR runs a median of 0.0 dB with a
// maximum of 1.7 dB, against an end threshold of 3 and an onset threshold of 5.
//
// Tracking runs continuously, including during a turn, bounded by FLOOR_DRIFT_MAX_DB.
const FLOOR_RATE = 0.02; // ≈250 ms — steady enough to average the noise
// A genuine level drop (a fan switching off, a door closing) is worth chasing quickly,
// and is distinguishable from noise wobble by size.
const FLOOR_DROP_DB = 6;
const FLOOR_DROP_RATE = 0.25;
// …but size alone is not enough, and this is the correction a lossy network forced.
//
// On the receive side a jitter-buffer underrun emits a brief near-silent stretch. It is a
// level drop of exactly the size this fast path is looking for, so the floor chased it down
// 6 dB in about 20 ms — and then took ~250 ms to climb back at FLOOR_RATE. For that quarter
// second the onset threshold sat below the room, and ordinary room tone tripped it. Measured
// at 160 ms RTT with 30 ms jitter and 1% loss, that produced onsets at a median SNR of
// 5.6 dB against a floor 6.4 dB under the room, and the interval until real speech arrived
// was then reported as a breath head start: a 436 ms median where 186 ms was planted, with a
// worst case of 4506 ms. The own-microphone side of the same call was untouched.
//
// What separates the two cases is duration, not depth. A room that got quieter stays
// quieter; an underrun reverts. Measured on the same call at full rate: every idle dip more
// than 6 dB below the floor lasted a single 50 ms trace sample, and the clean run at the
// same distance had none at all. So the fast path has to be *earned* by persistence, and
// 100 ms is twice the longest transient observed while still being a small fraction of any
// real acoustic change.
const FLOOR_DROP_HOLD_MS = 100;

// The floor is a claim about a room, and no room is this quiet. A real capture chain
// has thermal noise in the preamp and dither in the converter; -85 dBFS RMS over 5 ms
// is already below anything a microphone produces. Anything under it is not a quiet
// room, it is *digital silence* — a muted input, a driver that emits zeros while the
// stream spins up, a Bluetooth link that has not settled, or a synthetic device.
//
// This clamp is load-bearing, and it was added because of a real failure rather than
// on principle. Chrome's fake audio device emits exact zeros for the first buffers.
// The floor calibrated to -320 dBFS, ordinary room tone then read as 262 dB SNR, an
// onset fired immediately, and because the floor is deliberately frozen while a turn
// is active, `snrDb` could never fall back under END_SNR_DB. The turn never ended, so
// the floor never thawed: the detector latched on the first sound it ever heard and
// went silent for the rest of the call. It produced three plausible-looking events and
// then nothing, which is the worst possible failure — it looks like a quiet room.
const FLOOR_MIN_DB = -85;

// Freezing the floor outright during a turn was wrong. It protects the next onset, but
// it means the end decision is judged against a level snapshotted when the turn began,
// and rooms are not that stationary. Measured on a fixture whose noise wanders by only
// a couple of dB — far less than a fan cycling or traffic outside — the frozen floor sat
// 2.4 dB under the room's actual level for the whole turn. 35% of room-tone hops then
// read above END_SNR_DB, the hang counter never filled, and the turn never ended.
//
// So the floor keeps tracking during a turn, with a ceiling: it may not rise more than
// this far above where it stood when the turn started. That single bound is what the
// freeze was really for. Speech sits 20–30 dB over room tone, so even at the ceiling the
// floor stays far below anything that could be mistaken for silence — a turn cannot end
// early — while a room that genuinely drifts is followed within a quarter second, so a
// turn cannot fail to end either.
//
// An attempt in between, tracking the quietest level seen within the turn, failed for an
// instructive reason worth recording: the minimum of a fluctuating signal estimates its
// troughs, not its level. It settled 7 dB *below* the floor and contributed nothing. A
// mean-like estimator was already the right tool; it just needed to keep running.
const FLOOR_DRIFT_MAX_DB = 8;
// A turn this long is not a human talking, it is the state machine being wrong. No
// utterance runs half a minute without a 350 ms pause. Independent of the clamp above:
// whatever goes wrong with the floor, the detector must recover rather than die quietly.
const MAX_TURN_MS = 30000;

// ── The flatness test: telling a wrong floor from a long sentence ────────────
// Thirty seconds is far too long to notice. The clamp above cannot help either, because
// its whole job is to stop the floor climbing during a turn — which is also exactly what
// prevents recovery when the floor was wrong *before* the turn began. That case is real
// and was measured: the received-audio detector on a real call calibrated its floor
// against the near-silence that precedes the first arriving packet, then the room tone
// arrived 15 dB above it, opened a turn, and the turn ran to the backstop. Two of them,
// on a 110-second call, swallowing the opening turns whole.
//
// What separates the two situations is modulation. Speech is syllables and gaps; a wrong
// floor sitting under steady room noise is a flat line. Measured on that call, over a
// 1.5-second window: real speech never varied by less than 5.9 dB, and the wedge sat at
// 0.8 dB. So the test is cheap and the margin is wide — and the failure it catches is one
// the detector can then repair itself, by throwing the floor away and recalibrating
// against the audio that is actually arriving.
const FLAT_WIN_MS = 2000;
const FLAT_RANGE_DB = 3; // between 0.8 (a wedge) and 5.9 (the quietest real speech seen)
// The window is measured as a handful of sub-blocks so the range costs O(FLAT_BLOCKS) per
// hop instead of O(hops in window) — 8 comparisons rather than 400.
const FLAT_BLOCKS = 8;

// The flatness test catches a wedge under *steady* noise. It does not catch a wedge under
// noise that wobbles, and that turned out to be the more common case: re-measured after the
// flatness fix, one wedge remained, sitting under a room tone that varied by 7 dB — well
// clear of FLAT_RANGE_DB, so flatness correctly ignored it, and it ran the full 30 seconds.
//
// What that wedge did show, unmistakably, is that `quietHops` never left zero. Not one hop
// in thirty seconds fell under END_SNR_DB. Real speech cannot do that: stop consonants alone
// put 20–80 ms of near-silence into every second of it, and every genuine turn in the same
// recording ended by accumulating quiet in the ordinary way.
//
// So the second test is a conjunction, and the conjunction is what makes it safe. Long *and*
// never once quiet means the floor is wrong. A twenty-second monologue is long but does go
// quiet; a two-second wedge is never quiet but is not yet long. Neither is touched.
const NEVER_QUIET_MS = 8000;
// "Never quiet" needs a little tolerance, or a single stray sub-threshold hop would excuse a
// wedge forever. A quarter of the hang requirement is ~88 ms of net quiet — two orders of
// magnitude less than any real turn accumulates in eight seconds.
const NEVER_QUIET_FRAC = 0.25;

// Classification. A pre-turn inhale is broadband, aperiodic, and tilted high; a
// vowel is periodic and tilted low. These separate them cleanly enough for
// telemetry without a model.
const BREATH_ZCR = 0.18; // zero crossings per sample
const BREATH_TILT_DB = -4; // high-band minus low-band energy
const VOICE_PERIODICITY = 0.42; // normalised autocorrelation peak
const TRANSIENT_MS = 40; // a click dies before this; a breath does not

// The 35 ms classification was tuned on the fixture, where a breath follows pure
// synthetic room tone. Real breaths don't: the onset fires 70–215 ms early on the
// sub-threshold ramp (by design — that is the head start), and at 35 ms the features
// sit on the *context*, not the event: a voiced exhale tail, or real room tone, which
// is low-tilted and quasi-periodic (measured on LibriSpeech idle stretches:
// periodicity 0.3–0.6, tilt −10…−20 dB — hum and rumble, where the fixture's noise
// is flat). The classifier then says 'voice' to what is audibly an inhale: on the
// corpus only 9 of 56 detected real breaths were labelled breath (16%), against
// 100% on the fixture. The autopsy that pinned this down is
// testbed/breath-autopsy.mjs; the same breath shows textbook breath features
// (periodicity ~0.2, tilt +3…+10) 150–250 ms into the turn.
//
// So a turn labelled 'voice' at 35 ms gets one second look, later, on *windowed*
// features — the audio since RECLASS_WIN_MS, not the turn average, which the exhale
// prefix would poison. The look requires two things at once: the window mostly
// aperiodic (a *fraction* over ~14 hops, not one window — a single fricative inside
// speech is breath-shaped, which is why one window is not enough) and the window's
// zcr or tilt in the breath band. Revision only ever goes voice→breath, never the
// other way: the asymmetry of ONSET_SNR_DB applies here too.
const RECLASSIFY_MS = 150; // the second look
const RECLASS_WIN_MS = 70; // window features start here
const RECLASS_APER_FRAC = 2 / 3; // fraction of window hops that must be aperiodic
// …and only where physics allows it. §17.1's window shuts around −45 dBFS of room
// noise: above that floor a real breath cannot clear the room, so a window that
// measures aperiodic-and-high-tilted there is breath-*shaped* speech, not a breath.
// Measured on the corpus: at floors of −40…−30 the second look bought +4 real
// breaths (of 24 trials) while flipping 24 speech own-onsets (of ~210 matched) —
// a trade the quiet floors do not make (9 breaths for 9 flips). Gate on the floor
// at the turn's own onset, not the drifting current floor, so a turn cannot lose
// its second look mid-way.
const RECLASS_MAX_FLOOR_DB = -42;

const DECIM = 6; // 48 kHz → 8 kHz for the pitch search
const F0_MIN = 70;
const F0_MAX = 400;
const LAG_MIN = Math.floor(SAMPLE_RATE / DECIM / F0_MAX); // 20
const LAG_MAX = Math.ceil(SAMPLE_RATE / DECIM / F0_MIN); // 115
const PITCH_WIN = LAG_MAX * 2; // 230 samples ≈ 28.75 ms

const EPS = 1e-10;
const db = (x) => 20 * Math.log10(Math.max(x, EPS));

/**
 * Events emitted, all carrying `at` — an absolute sample index since construction,
 * so a caller can convert to a session timestamp without guessing at buffering.
 *
 *   { type: 'onset',      at, snrDb }
 *   { type: 'classified', at, kind: 'breath'|'voice'|'transient', onsetAt, ... }
 *   { type: 'voiced',     at, onsetAt, leadMs }   ← only after a 'breath'
 *   { type: 'end',        at, durationMs }
 *
 * `voiced` is the measurement the design lives or dies on. When a turn opens with
 * an inhale, this fires at the moment phonation actually begins, and `leadMs` is
 * the head start the breath bought on that specific turn. It makes the §3.1 lever-1
 * claim falsifiable on one machine with one microphone: talk, and read the number.
 */
export class OnsetDetector {
  constructor(opts = {}) {
    this.sampleRate = opts.sampleRate ?? SAMPLE_RATE;
    this.hop = opts.hop ?? HOP;
    this.onsetSnrDb = opts.onsetSnrDb ?? ONSET_SNR_DB;

    const msToHops = (ms) => Math.max(1, Math.round((ms / 1000) * this.sampleRate / this.hop));
    this.hangHops = msToHops(HANG_MS);
    this.awaitHangHops = msToHops(opts.awaitVoiceHangMs ?? AWAIT_VOICE_HANG_MS);
    this.classifyHops = msToHops(CLASSIFY_MS);
    this.classify2Hops = msToHops(opts.reclassifyMs ?? RECLASSIFY_MS);
    this.reclassWinHops = msToHops(RECLASS_WIN_MS);
    this.calibrateHops = msToHops(CALIBRATE_MS);
    this.transientHops = msToHops(TRANSIENT_MS);
    this.turnDropDb = opts.turnDropDb ?? TURN_DROP_DB;

    // Hop accumulator — input arrives in whatever block size the caller has
    // (128 under an AudioWorklet), which never divides evenly into a 5 ms hop.
    this.acc = new Float32Array(this.hop);
    this.accLen = 0;
    this.lastSample = 0; // for zero-crossing across the hop boundary

    // One-pole high-pass at 2 kHz, for the spectral-tilt feature.
    const rc = (2 * Math.PI * 2000) / this.sampleRate;
    this.hpA = 1 / (1 + rc);
    this.hpPrevIn = 0;
    this.hpPrevOut = 0;

    // Decimated ring buffer for the pitch search.
    this.ring = new Float32Array(1024);
    this.ringPos = 0;
    this.decimAcc = 0;
    this.decimN = 0;

    this.maxTurnHops = msToHops(MAX_TURN_MS);
    // Flatness window, held as FLAT_BLOCKS sub-blocks of min/max — see FLAT_RANGE_DB.
    this.flatBlockHops = Math.max(1, Math.round(msToHops(FLAT_WIN_MS) / FLAT_BLOCKS));
    this.flatMin = new Float32Array(FLAT_BLOCKS);
    this.flatMax = new Float32Array(FLAT_BLOCKS);
    this.flatIdx = 0;
    this.flatFill = 0; // sub-blocks written since the turn began
    this.flatHop = 0;  // hops into the current sub-block
    this.flatEnds = 0;
    this.neverQuietHops = msToHops(NEVER_QUIET_MS);
    this.quietPeak = 0; // highest `quietHops` reached in the current turn

    this.floorDb = null;
    this.recentDb = []; // short history for the rise test
    // Hops that carried real audio, as opposed to digital silence. Calibration is
    // gated on this rather than on elapsed hops — see FLOOR_MIN_DB.
    this.realHops = 0;
    this.forcedEnds = 0;
    // Consecutive hops well below the floor, and how many it takes to believe them.
    this.dropHops = 0;
    this.dropHoldHops = msToHops(FLOOR_DROP_HOLD_MS);

    this.state = 'idle'; // 'idle' | 'active'
    this.hopIndex = 0;
    this.samplesSeen = 0;
    this.activeHops = 0;
    this.quietHops = 0;
    this.quietFrom = null; // sample index where the current quiet run began
    this.floorAtOnsetDb = null; // floor when the current turn began; bounds drift
    this.onsetAt = 0;
    this.classified = false;
    this.feat = null;
    this.turnPeakDb = -Infinity; // absolute level peak of the current turn
    this.turnKind = null; // what the turn was last classified as
    this.reclassified = false; // the second look happens at most once
    this.feat2 = null; // windowed features for the second look (RECLASS_WIN_MS on)
    this.aperN = 0; // periodicity probes in the second-look window
    this.aperCount = 0; // …of which below VOICE_PERIODICITY

    // Set once a turn has been labelled 'breath' and we are still waiting for
    // phonation, so we can time the lead. Cleared when 'voiced' fires or the turn
    // ends without ever becoming voiced (a stray breath, a sigh, a cough).
    this.awaitingVoice = false;
  }

  /** Feed any number of samples. Returns an array of events (usually empty). */
  push(samples) {
    const events = [];
    let i = 0;
    while (i < samples.length) {
      const n = Math.min(this.hop - this.accLen, samples.length - i);
      this.acc.set(samples.subarray(i, i + n), this.accLen);
      this.accLen += n;
      i += n;
      if (this.accLen === this.hop) {
        this._hop(events);
        this.accLen = 0;
      }
    }
    return events;
  }

  _hop(events) {
    const x = this.acc;
    const N = this.hop;

    // ── Features ────────────────────────────────────────────────────────────
    let sumSq = 0;
    let crossings = 0;
    let hpSumSq = 0;
    let prev = this.lastSample;

    for (let k = 0; k < N; k++) {
      const s = x[k];
      sumSq += s * s;
      if ((s >= 0) !== (prev >= 0)) crossings++;
      prev = s;

      // High-passed copy for tilt.
      const hp = this.hpA * (this.hpPrevOut + s - this.hpPrevIn);
      this.hpPrevOut = hp;
      this.hpPrevIn = s;
      hpSumSq += hp * hp;

      // Boxcar-decimate into the pitch ring. A 6-tap average is a crude
      // anti-alias filter, but periodicity survives it and it costs one add.
      this.decimAcc += s;
      if (++this.decimN === DECIM) {
        this.ring[this.ringPos] = this.decimAcc / DECIM;
        this.ringPos = (this.ringPos + 1) % this.ring.length;
        this.decimAcc = 0;
        this.decimN = 0;
      }
    }
    this.lastSample = prev;

    const rms = Math.sqrt(sumSq / N);
    const rmsDb = db(rms);
    const hpRms = Math.sqrt(hpSumSq / N);
    const zcr = crossings / N;
    const tiltDb = db(hpRms) - db(Math.max(rms - hpRms, EPS));

    this.hopIndex++;
    this.samplesSeen += N;
    const at = this.samplesSeen;

    // ── Noise floor ─────────────────────────────────────────────────────────
    // Only tracked while idle. Once a turn is active the floor is frozen, so a
    // long utterance cannot drag it upward and swallow the next onset.
    //
    // Digital silence is excluded entirely rather than clamped after the fact: a hop
    // of exact zeros says nothing about the room, so it must neither set the initial
    // floor nor pull the tracked one down. Calibration therefore waits for real audio
    // instead of completing on a fixed number of hops that may all have been zeros.
    const silent = rmsDb < FLOOR_MIN_DB;
    if (!silent) {
      this.realHops++;
      if (this.floorDb === null) {
        this.floorDb = rmsDb;
      } else {
        // The fast path is earned by persistence, not claimed by depth — see
        // FLOOR_DROP_HOLD_MS. A transient dip is tracked at the ordinary rate, which is slow
        // enough that a 50 ms underrun moves the floor by a fraction of a dB.
        if (rmsDb < this.floorDb - FLOOR_DROP_DB) this.dropHops++;
        else this.dropHops = 0;
        const rate = this.dropHops >= this.dropHoldHops ? FLOOR_DROP_RATE : FLOOR_RATE;
        this.floorDb += (rmsDb - this.floorDb) * rate;
        // Tracking continues through a turn, but bounded — see FLOOR_DRIFT_MAX_DB.
        if (this.state !== 'idle' && this.floorAtOnsetDb !== null) {
          const ceil = this.floorAtOnsetDb + FLOOR_DRIFT_MAX_DB;
          if (this.floorDb > ceil) this.floorDb = ceil;
        }
      }
    }
    if (this.floorDb !== null && this.floorDb < FLOOR_MIN_DB) this.floorDb = FLOOR_MIN_DB;

    const snrDb = this.floorDb === null ? 0 : rmsDb - this.floorDb;

    // Rise test over the preceding ~20 ms.
    const hist = this.recentDb;
    const avgPrev = hist.length ? hist.reduce((a, b) => a + b, 0) / hist.length : rmsDb;
    hist.push(rmsDb);
    if (hist.length > 4) hist.shift();
    const rising = rmsDb - avgPrev > RISE_DB;

    // Calibration counts hops that carried actual audio, so a stream that opens with
    // half a second of zeros does not arrive "already calibrated" on nothing.
    if (this.realHops <= this.calibrateHops) return; // floor not trustworthy yet

    // ── State machine ───────────────────────────────────────────────────────
    if (this.state === 'idle') {
      if (snrDb > this.onsetSnrDb && rising) {
        this.state = 'active';
        this.activeHops = 0;
        this.quietHops = 0;
        this.classified = false;
        // Report the onset at the START of this hop: the energy that tripped it
        // is already in the buffer, so the true onset is up to one hop earlier.
        // Rounding toward the earlier edge keeps every downstream latency figure
        // honest rather than flattering.
        this.onsetAt = at - N;
        this.feat = { zcr: 0, tilt: 0, peak: -Infinity, hops: 0 };
        this.turnPeakDb = rmsDb;
        this.turnKind = null;
        this.reclassified = false;
        this.feat2 = { zcr: 0, tilt: 0, hops: 0 };
        this.aperN = 0;
        this.aperCount = 0;
        this.floorAtOnsetDb = this.floorDb; // ceiling reference for the drift bound
        this.flatIdx = 0;
        this.flatFill = 0;
        this.flatHop = 0;
        this.quietPeak = 0;
        // `floorDb` rides along on every onset. An implausible floor is the single
        // most useful thing a log can tell us after the fact, and it is invisible
        // unless it is reported — a latched detector otherwise looks like a quiet room.
        events.push({ type: 'onset', at: this.onsetAt, snrDb, floorDb: this.floorDb });
      }
      return;
    }

    // active
    this.activeHops++;
    this.feat.zcr += zcr;
    this.feat.tilt += tiltDb;
    this.feat.peak = Math.max(this.feat.peak, snrDb);
    this.feat.hops++;
    if (rmsDb > this.turnPeakDb) this.turnPeakDb = rmsDb;
    if (this.activeHops > this.reclassWinHops && this.activeHops <= this.classify2Hops) {
      this.feat2.zcr += zcr;
      this.feat2.tilt += tiltDb;
      this.feat2.hops++;
    }

    // The end-gate: the higher of floor-relative and this-turn-peak-relative. See
    // TURN_DROP_DB for why a fixed floor-relative gate cannot close a turn in a
    // studio-quiet room, and why loud floors are untouched by the second term.
    const endGateSnrDb = Math.max(END_SNR_DB, this.turnPeakDb - this.turnDropDb - this.floorDb);
    // While a breath-opened turn waits for phonation the hang is longer — see
    // AWAIT_VOICE_HANG_MS. The quiet test itself is unchanged.
    const hangHops = this.awaitingVoice ? this.awaitHangHops : this.hangHops;

    // Leaky rather than consecutive — see HANG_PENALTY. `quietFrom` records when the
    // current quiet run actually began, which a leaky counter no longer implies: with a
    // hard reset `quietHops` was exactly the hops since quiet started, but now it is a
    // net score, so `at - quietHops * N` would place the end *later* than it happened.
    // That would shrink the human gap and enlarge nothing — precisely the direction that
    // flatters the design, so it has to be tracked rather than inferred.
    if (snrDb < endGateSnrDb) {
      if (this.quietHops === 0) this.quietFrom = at - N;
      this.quietHops++;
    } else {
      this.quietHops = Math.max(0, this.quietHops - HANG_PENALTY);
      if (this.quietHops === 0) this.quietFrom = null;
    }
    if (this.quietHops > this.quietPeak) this.quietPeak = this.quietHops;

    if (!this.classified && this.activeHops >= this.classifyHops) {
      this.classified = true;
      const c = this._classify(at);
      events.push(c);
      // Only a breath-opened turn has a lead to measure.
      this.turnKind = c.kind;
      this.awaitingVoice = c.kind === 'breath';
    }

    // The second look — see RECLASSIFY_MS. Only a turn already labelled 'voice' is
    // reconsidered, and only toward 'breath'. The aperiodicity probes run every other
    // hop, the cadence the voiced watch already pays for, and only in the window.
    if (
      this.turnKind === 'voice' && !this.reclassified &&
      this.floorAtOnsetDb < RECLASS_MAX_FLOOR_DB &&
      this.activeHops > this.reclassWinHops && this.activeHops <= this.classify2Hops &&
      this.activeHops % 2 === 0
    ) {
      if (this._periodicity() < VOICE_PERIODICITY) this.aperCount++;
      this.aperN++;
    }
    if (
      this.turnKind === 'voice' && !this.reclassified &&
      this.floorAtOnsetDb < RECLASS_MAX_FLOOR_DB &&
      this.activeHops >= this.classify2Hops
    ) {
      this.reclassified = true;
      const hops2 = Math.max(this.feat2.hops, 1);
      const zcr2 = this.feat2.zcr / hops2;
      const tilt2 = this.feat2.tilt / hops2;
      const fracAper = this.aperN ? this.aperCount / this.aperN : 0;
      if (fracAper >= RECLASS_APER_FRAC && (zcr2 > BREATH_ZCR || tilt2 > BREATH_TILT_DB)) {
        this.turnKind = 'breath';
        this.awaitingVoice = true;
        events.push({
          type: 'classified', at, onsetAt: this.onsetAt, kind: 'breath', revised: true,
          zcr: zcr2, tiltDb: tilt2, aperiodicFrac: fracAper,
        });
      }
    }

    // Watch for phonation inside a breath-opened turn. Checked every other hop:
    // periodicity is the one expensive feature here, and 10 ms of extra
    // granularity on a ~200 ms measurement is not worth doubling its cost.
    if (this.awaitingVoice && this.activeHops % 2 === 0 && snrDb > END_SNR_DB) {
      const p = this._periodicity();
      if (p >= VOICE_PERIODICITY) {
        this.awaitingVoice = false;
        // Phonation is unambiguous evidence the turn is alive. The long await-hang may
        // have let quietHops grow far past the normal hang during the breath→speech
        // lull; without this reset the turn would end the instant the watch clears.
        this.quietHops = 0;
        this.quietFrom = null;
        // Attribute phonation to the start of the analysis window, not its end —
        // the periodicity we just measured was already present across it. Erring
        // later would inflate the lead, which is the number we are trying to
        // scrutinise, so err earlier.
        const voicedAt = at - PITCH_WIN * DECIM;
        events.push({
          type: 'voiced',
          at: voicedAt,
          onsetAt: this.onsetAt,
          periodicity: p,
          leadMs: ((voicedAt - this.onsetAt) / this.sampleRate) * 1000,
        });
      }
    }

    // ── Flatness ────────────────────────────────────────────────────────────
    // Accumulate this hop into the current sub-block, then judge the whole window once
    // enough of it exists. See FLAT_RANGE_DB for why modulation is the discriminator.
    if (this.flatHop === 0) {
      this.flatMin[this.flatIdx] = rmsDb;
      this.flatMax[this.flatIdx] = rmsDb;
    } else {
      if (rmsDb < this.flatMin[this.flatIdx]) this.flatMin[this.flatIdx] = rmsDb;
      if (rmsDb > this.flatMax[this.flatIdx]) this.flatMax[this.flatIdx] = rmsDb;
    }
    if (++this.flatHop >= this.flatBlockHops) {
      this.flatHop = 0;
      this.flatIdx = (this.flatIdx + 1) % FLAT_BLOCKS;
      if (this.flatFill < FLAT_BLOCKS) this.flatFill++;
    }

    // Long, and not once quiet in all that time — see NEVER_QUIET_MS.
    const neverQuiet =
      this.activeHops >= this.neverQuietHops && this.quietPeak < this.hangHops * NEVER_QUIET_FRAC;

    let flat = false;
    if (this.flatFill >= FLAT_BLOCKS) {
      let lo = Infinity;
      let hi = -Infinity;
      for (let b = 0; b < FLAT_BLOCKS; b++) {
        if (this.flatMin[b] < lo) lo = this.flatMin[b];
        if (this.flatMax[b] > hi) hi = this.flatMax[b];
      }
      flat = hi - lo < FLAT_RANGE_DB;
    }

    // Defence in depth against the latch described at FLOOR_MIN_DB. That specific
    // cause is fixed, but any future arithmetic that keeps `snrDb` pinned above
    // END_SNR_DB would strand the state machine in 'active' forever, and the symptom
    // would again be silence rather than an error. So cap the turn, force it closed,
    // and throw the floor away — being stuck is itself evidence the floor is wrong.
    const stuck = this.activeHops >= this.maxTurnHops;
    if (stuck || flat || neverQuiet) {
      events.push({
        type: 'end',
        at,
        durationMs: ((at - this.onsetAt) / this.sampleRate) * 1000,
        forced: true,
        // Which defence fired matters when reading a log: 'flat' says the floor was wrong
        // and has been rebuilt, 'stuck' says something not yet understood held the state
        // machine open for half a minute and deserves investigating.
        reason: flat ? 'flat' : neverQuiet ? 'never-quiet' : 'stuck',
        floorDb: this.floorDb,
      });
      this.state = 'idle';
      this.awaitingVoice = false;
      this.recentDb = [];
      // Throw the floor away in both cases. Being stuck is itself evidence the floor is
      // wrong, and a flat turn is a direct measurement of it — so recalibrate against the
      // audio that is actually arriving rather than keeping the estimate that failed.
      this.floorDb = null;
      this.realHops = 0;
      if (flat || neverQuiet) this.flatEnds++;
      else this.forcedEnds++;
      return;
    }

    if (this.quietHops >= hangHops) {
      // The moment the level dropped to room, not the moment we became confident of it.
      const endAt = this.quietFrom ?? at - this.quietHops * N;
      // A turn that ended before it was ever classified was a transient.
      if (!this.classified) {
        this.classified = true;
        events.push({
          type: 'classified',
          at,
          onsetAt: this.onsetAt,
          kind: 'transient',
          zcr: this.feat.zcr / Math.max(this.feat.hops, 1),
          tiltDb: this.feat.tilt / Math.max(this.feat.hops, 1),
          periodicity: 0,
        });
      }
      events.push({
        type: 'end',
        at: endAt,
        durationMs: ((endAt - this.onsetAt) / this.sampleRate) * 1000,
      });
      this.state = 'idle';
      this.awaitingVoice = false;
      this.recentDb = [];
    }
  }

  _classify(at) {
    const hops = Math.max(this.feat.hops, 1);
    const zcr = this.feat.zcr / hops;
    const tiltDb = this.feat.tilt / hops;
    const periodicity = this._periodicity();
    const durMs = (hops * this.hop * 1000) / this.sampleRate;

    let kind;
    if (periodicity >= VOICE_PERIODICITY) {
      // Periodic wins outright. A voiced onset can be breathy and still be voice.
      kind = 'voice';
    } else if (durMs < TRANSIENT_MS && this.quietHops > 0) {
      kind = 'transient';
    } else if (zcr > BREATH_ZCR || tiltDb > BREATH_TILT_DB) {
      kind = 'breath';
    } else {
      // Aperiodic, low-tilt, sustained: an unvoiced consonant or a mumble. Call
      // it voice — for Lane 0's purposes it is speech, and the cost of being
      // wrong here is a mislabelled telemetry row, not a lost 200 ms.
      kind = 'voice';
    }

    return { type: 'classified', at, onsetAt: this.onsetAt, kind, zcr, tiltDb, periodicity };
  }

  /**
   * Normalised autocorrelation peak over the plausible F0 range, on the most
   * recent ~29 ms of decimated audio. Returns 0..1; voiced speech sits well
   * above 0.4, breath and room noise well below.
   */
  _periodicity() {
    const R = this.ring;
    const L = R.length;
    const win = PITCH_WIN;
    if (this.samplesSeen / DECIM < win + LAG_MAX) return 0;

    // Copy the window out of the ring, oldest first, so lags index linearly.
    const need = win + LAG_MAX;
    const buf = new Float32Array(need);
    let p = (this.ringPos - need + L * 2) % L;
    for (let k = 0; k < need; k++) {
      buf[k] = R[p];
      p = (p + 1) % L;
    }

    let e0 = 0;
    for (let k = 0; k < win; k++) e0 += buf[k] * buf[k];
    if (e0 < EPS) return 0;

    let best = 0;
    for (let lag = LAG_MIN; lag <= LAG_MAX; lag++) {
      let num = 0;
      let eL = 0;
      for (let k = 0; k < win; k++) {
        const b = buf[k + lag];
        num += buf[k] * b;
        eL += b * b;
      }
      if (eL < EPS) continue;
      const r = num / Math.sqrt(e0 * eL);
      if (r > best) best = r;
    }
    return best;
  }

  /** Current noise floor in dB, for UI. Null before calibration completes. */
  get noiseFloorDb() {
    return this.hopIndex > this.calibrateHops ? this.floorDb : null;
  }
}
