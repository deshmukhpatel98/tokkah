/**
 * Turn-end prediction on raw 48 kHz PCM — DESIGN.md §3.1 lever 4.
 *
 * The sender runs this on its own mic, where audio is available at zero latency,
 * and predicts its own turn end ahead of time. The prediction is a few bytes on
 * Lane 0, so it reaches the peer ~95 ms before the turn actually ends, and the
 * receiver spends that window pre-warming the return path (congestion window,
 * Lane B pre-stall). It is metadata derived from real audio, used only to
 * schedule the network — never mixed into media, never shown to the user.
 *
 * The features are the turn-final cues from the conversation-science literature
 * the design already leans on (§1.1c): final-syllable lengthening, terminal
 * pitch fall, intensity fall, and creak/aperiodicity. Everything is streaming,
 * causal, and cheap: one autocorrelation pitch estimate per 10 ms frame, ring
 * buffers, no allocation in the hot path. No ML framework — the scorer is one
 * logistic regression whose weights were trained offline on LibriSpeech
 * (testbed/turnend.mjs) and are baked in below as constants.
 *
 * The bias is asymmetric, and it is the opposite of onset.js. A false
 * prediction wastes one pre-warm (a few hundred ms of padding on an otherwise
 * idle return path). A miss costs nothing but the improvement — the call
 * behaves exactly as it would without lever 4. So the operating point is
 * chosen for low false-predict rate, not for recall. Do not "improve" the
 * recall of this module without re-reading that sentence.
 *
 * No browser dependencies: runs identically under an AudioWorklet and under
 * node, which is how it is validated. Slated for the shared Rust core (§19.3).
 *
 * ── Measured performance ─────────────────────────────────────────────────────
 * Corpus: 204 LibriSpeech dev-clean utterances, 3 speakers (1272: 71, 1462: 91,
 * 1673: 42), ~10–60 s each. Speaker-disjoint splits: train on 1272+1462,
 * operating point chosen on a chapter-disjoint calibration slice of the same
 * two speakers, all reported numbers from the shipped module streaming the
 * held-out speaker 1673 (40 usable utterances after dropping clips with no
 * clean final fall).
 *
 * Held-out test, operating point THRESH=0.65 / RESET=0.45, 600 ms refire:
 *   useful recall (fire lands 95–400 ms before fall completion)   17.5%
 *   fires per utterance (all kinds)                               6.85
 *   precision among fires                                         2.5%
 *   useful lead time p10 / p50 / p90                              110 / 290 / 390 ms
 *   fires after the turn had already ended                        0
 * Calibration split at the same point: recall 21%, 3.5 fires/utterance.
 *
 * Two negative results that shaped this module, measured before the positives:
 *
 * 1. Energy-threshold labels are circular. corpus.mjs's rule (last 10 ms frame
 *    above −22 dBFS) defines "the end" by the very cue being predicted — energy
 *    rises monotonically into that label (−28 dBFS at −1200 ms out, −21.7 at
 *    −50 ms), so a model trained on it learns "loud = almost over". Ground
 *    truth here is fall-completion instead: the first frame below floor+3 dB
 *    after the last frame within 6 dB of the utterance peak — the same anchor
 *    onset.js's hang logic uses.
 *
 * 2. Final and internal falls are acoustically near-identical in read speech
 *    (58 final vs 154 internal, 60 clips): fall duration p10/50/90 = 50/110/270
 *    vs 40/90/200 ms; depth 8.3/22.8/33.9 vs 7.3/18.9/33.9 dB; pre-fall F0
 *    movement −1.1 vs −0.8 semitones. And falls complete fast — the steep part
 *    is ~110 ms at the median — so 250 ms before completion the signal is
 *    ordinary speech with no readable turn-final cue. The ~250 ms prosodic
 *    anticipation §3.1 lever 4 hopes for cannot be validated on LibriSpeech,
 *    which is read speech, not conversation (testbed/README said so before we
 *    measured it). What this module actually is: a fall-in-progress detector
 *    whose median useful lead (290 ms) comes from catching the fall's shoulder,
 *    not from anticipating it.
 *
 * Consequence for integration: a *perfect* fall detector would still fire
 * ~2.7 times per utterance on this corpus, because internal sentence falls are
 * real fall events. On this module's test numbers, ~1 in 6 utterances gets a
 * pre-warm that lands in the useful window; the rest of the fires are early
 * pre-warms on internal falls — which in a real conversation are genuine
 * turn-exchange opportunities, so the waste is less wrong than it looks, but
 * on read speech it is just waste. A miss costs nothing but the improvement.
 */

export const SAMPLE_RATE = 48000;
export const FRAME = 480; // 10 ms. Feature and scoring cadence.

// ── Tuning ───────────────────────────────────────────────────────────────────
// The gate mirrors onset.js's philosophy: thresholds are in dB above a tracked
// noise floor, never absolute, because an absolute gate fails in whichever room
// you didn't tune it in.
const GATE_DB = 6; // utterance opens here
const GATE_END_DB = 3; // and closes here — hysteresis
const HANG_MS = 350; // quiet needed to call the utterance over
const HANG_PENALTY = 4; // leaky hang — see onset.js for the derivation
const FLOOR_RATE = 0.02;
const FLOOR_MIN_DB = -85; // below this is digital silence, not a quiet room
const CALIBRATE_MS = 150; // floor is untrustworthy before this
// Don't predict the end of an utterance that just started: clicks, coughs and
// one-word backchannels carry no turn-final cues, and a fire there is a wasted
// pre-warm.
const MIN_UTT_MS = 400;

// Pitch: same decimated autocorrelation as onset.js.
const DECIM = 6; // 48 kHz → 8 kHz
const F0_MIN = 70;
const F0_MAX = 400;
const LAG_MIN = Math.floor(SAMPLE_RATE / DECIM / F0_MAX); // 20
const LAG_MAX = Math.ceil(SAMPLE_RATE / DECIM / F0_MIN); // 115
const PITCH_WIN = LAG_MAX * 2; // 230 decimated samples ≈ 28.75 ms
const VOICED_PEAK = 0.45; // normalised-autocorrelation threshold for "voiced"

// Feature windows, in frames.
const ENV_FRAMES = 60; // 600 ms rings for envelope / f0 / periodicity
const SLOPE_FRAMES = 30; // 300 ms regression windows
const PEAK_REFRACT_MS = 60; // syllable nuclei don't come faster than this
const PEAK_FALL_DB = 1.5; // a peak completes when the envelope falls this far
const PEAK_WITHIN_DB = 15; // …and only counts if it was this close to the max
const IPI_MIN_MS = 80; // inter-peak interval sanity bounds
const IPI_MAX_MS = 1200;
const IPI_RING = 8;

const HORIZON_MS = 250; // what a `predict` event claims: turn ends within this
// One fire per fall, not one per wobble: after firing, don't fire again for
// this long even if the latch re-arms. A sentence boundary and the true final
// fall are a sentence apart (~2–4 s); the wobbles *within* one fall are tens
// of ms. Measured on the calibration split, an un-limited latch fires ~8 times
// per utterance where a perfect fall detector would fire ~3.7.
const MIN_REFIRE_MS = 600;

// ── Trained constants ────────────────────────────────────────────────────────
// Logistic regression over 8 features, trained by testbed/turnend.mjs on
// LibriSpeech dev-clean (speakers 1272 + 1462, chapter-disjoint calibration
// split), speaker-disjoint from the validation speaker (1673). Positive label:
// the final fall region (fall start −100 ms … fall completion). Hard negatives
// (frames just before internal falls) all kept; easy negatives subsampled 4:1.
const FEAT_MEAN = [-6.90764, -14.62263, -2.78618, -0.28155, -0.28693, 160.98826, 1.26685, 0.66441];
const FEAT_SCALE = [73.85109, 13.73537, 40.20939, 5.87875, 0.2884, 132.95345, 1.06709, 0.27653];
const WEIGHTS = [-0.14649, 0.25579, -0.01412, -0.17694, -0.00334, 0.08079, -0.2424, 0.23715];
const BIAS = 0.04513;
// Operating point: chosen on the calibration split at the best useful recall
// among low-waste points (waste ≤ ~3.5 fires/utterance — a *perfect* fall
// detector wastes ~2.7 on this corpus, because internal sentence falls are
// acoustically almost identical to final ones). RESET < THRESH: latch
// hysteresis.
const THRESH = 0.65;
const RESET = 0.45;

const EPS = 1e-10;
const db = (x) => 20 * Math.log10(Math.max(x, EPS));

/**
 * Events emitted, all carrying `at` — an absolute sample index since
 * construction, so a caller can convert to a session timestamp without
 * guessing at buffering.
 *
 *   { type: 'score',   at, prob }            one per 10 ms frame while gated on
 *   { type: 'predict', at, prob, leadMs }    once per threshold crossing
 *   { type: 'reset',   at }                  utterance closed; predictor re-arms
 *
 * `at` on a prediction is the END of the frame that crossed the threshold: the
 * earliest moment the app could actually put the datagram on the wire. That
 * makes measured lead time (truth end − at) conservative — an instrument that
 * flatters itself is worse than none.
 * `leadMs` is the horizon the scorer was built for (250 ms); the measured
 * distribution of real leads is in the header comment above.
 */
export class TurnEndPredictor {
  constructor(opts = {}) {
    this.sampleRate = opts.sampleRate ?? SAMPLE_RATE;
    this.frame = opts.frame ?? FRAME;
    this.threshold = opts.threshold ?? THRESH;
    this.reset = opts.reset ?? RESET;
    this.debug = opts.debug ?? false;
    this.trace = opts.trace ? [] : null; // offline driver only: per-frame levels

    const msToFrames = (ms) => Math.max(1, Math.round((ms / 1000) * this.sampleRate / this.frame));
    this.hangFrames = msToFrames(HANG_MS);
    this.calibrateFrames = msToFrames(CALIBRATE_MS);
    this.minUttFrames = msToFrames(MIN_UTT_MS);
    this.peakRefractFrames = msToFrames(PEAK_REFRACT_MS);

    // Frame accumulator — input arrives in whatever block size the caller has.
    this.acc = new Float32Array(this.frame);
    this.accLen = 0;

    // Decimated ring for the pitch search (as onset.js).
    this.ring = new Float32Array(1024);
    this.ringPos = 0;
    this.decimAcc = 0;
    this.decimN = 0;
    this.pitchBuf = new Float32Array(PITCH_WIN + LAG_MAX);

    // Feature rings, ENV_FRAMES long.
    this.envDb = new Float32Array(ENV_FRAMES); // smoothed envelope
    this.f0Hz = new Float32Array(ENV_FRAMES); // 0 = unvoiced
    this.period = new Float32Array(ENV_FRAMES); // periodicity
    this.ringN = 0; // total frames pushed
    this.ringHead = 0; // next write position

    // Per-utterance state.
    this.ipiRing = new Float32Array(IPI_RING); // inter-peak intervals, ms
    this.ipiN = 0;
    this.ipiHead = 0;
    this.f0Hist = new Uint16Array(72); // 24 bins/octave above 55 Hz
    this.f0HistN = 0;
    this.uttMaxDb = -Infinity;
    this.peakCandDb = -Infinity;
    this.peakCandAt = 0;
    this.lastPeakAt = -1;
    this.ipiSorted = new Float32Array(IPI_RING);

    this.floorDb = null;
    this.realFrames = 0;
    this.floorAtOnsetDb = null;

    this.state = 'idle'; // 'idle' | 'active'
    this.samplesSeen = 0;
    this.activeFrames = 0;
    this.quietFrames = 0;
    this.armed = false;
    this.fired = false;
    this.lastFireAt = -Infinity;
    this.minRefireSamples = (MIN_REFIRE_MS / 1000) * this.sampleRate;
    this.utt = 0; // activation-segment counter, for the offline driver
  }

  /** Feed any number of samples. Returns an array of events (usually empty). */
  push(samples) {
    const events = [];
    let i = 0;
    while (i < samples.length) {
      const n = Math.min(this.frame - this.accLen, samples.length - i);
      this.acc.set(samples.subarray(i, i + n), this.accLen);
      this.accLen += n;
      i += n;
      if (this.accLen === this.frame) {
        this._frame(events);
        this.accLen = 0;
      }
    }
    return events;
  }

  _frame(events) {
    const x = this.acc;
    const N = this.frame;

    let sumSq = 0;
    for (let k = 0; k < N; k++) {
      const s = x[k];
      sumSq += s * s;
      this.decimAcc += s;
      if (++this.decimN === DECIM) {
        this.ring[this.ringPos] = this.decimAcc / DECIM;
        this.ringPos = (this.ringPos + 1) % this.ring.length;
        this.decimAcc = 0;
        this.decimN = 0;
      }
    }
    const rmsDb = db(Math.sqrt(sumSq / N));

    this.samplesSeen += N;
    const at = this.samplesSeen; // END of frame — see the event docs above.

    // ── Noise floor ─────────────────────────────────────────────────────────
    // During calibration the floor tracks the *trough* of what arrives, not the
    // EMA: seeding from the first non-silent frame latches if the stream opens
    // mid-sentence (or opens with digital silence, so the first real frame is
    // speech — the FLOOR_MIN_DB latch onset.js's header warns about). A room's
    // floor is its quietest moment; 150 ms of trough-tracking sits ~1–2 dB
    // under the true mean, which the gate margins absorb.
    const silent = rmsDb < FLOOR_MIN_DB;
    if (!silent) {
      this.realFrames++;
      if (this.floorDb === null) this.floorDb = rmsDb;
      else if (this.realFrames <= this.calibrateFrames) {
        if (rmsDb < this.floorDb) this.floorDb = rmsDb;
      } else {
        this.floorDb += (rmsDb - this.floorDb) * FLOOR_RATE;
        if (this.state !== 'idle' && this.floorAtOnsetDb !== null) {
          const ceil = this.floorAtOnsetDb + 8;
          if (this.floorDb > ceil) this.floorDb = ceil;
        }
      }
    }
    if (this.floorDb !== null && this.floorDb < FLOOR_MIN_DB) this.floorDb = FLOOR_MIN_DB;
    // Offline-driver trace: lets testbed/turnend.mjs compute the fall-completion
    // ground truth with this module's own floor, so labels and features always
    // come from the same signal path.
    if (this.trace) this.trace.push({ at, rmsDb, floorDb: this.floorDb });
    if (this.realFrames <= this.calibrateFrames) return;

    const snrDb = this.floorDb === null ? 0 : rmsDb - this.floorDb;

    // ── Gate ────────────────────────────────────────────────────────────────
    if (this.state === 'idle') {
      if (snrDb > GATE_DB) {
        this.state = 'active';
        this.activeFrames = 0;
        this.quietFrames = 0;
        this.floorAtOnsetDb = this.floorDb;
        this._resetUtterance();
      } else {
        return;
      }
    }

    // active
    this.activeFrames++;
    if (snrDb < GATE_END_DB) {
      this.quietFrames++;
    } else {
      this.quietFrames = Math.max(0, this.quietFrames - HANG_PENALTY);
    }
    if (this.quietFrames >= this.hangFrames) {
      this.state = 'idle';
      this.armed = false;
      this.fired = false;
      events.push({ type: 'reset', at });
      return;
    }

    // ── Envelope ────────────────────────────────────────────────────────────
    const prevEnv = this.ringN > 0 ? this.envDb[(this.ringHead + ENV_FRAMES - 1) % ENV_FRAMES] : rmsDb;
    const sDb = prevEnv + 0.5 * (rmsDb - prevEnv);
    const head = this.ringHead;
    this.envDb[head] = sDb;

    // ── Pitch, every frame while active ─────────────────────────────────────
    const { f0, peak } = this._pitch();
    const voiced = peak >= VOICED_PEAK && snrDb > GATE_END_DB;
    this.f0Hz[head] = voiced ? f0 : 0;
    this.period[head] = peak;
    this.ringHead = (this.ringHead + 1) % ENV_FRAMES;
    this.ringN++;

    if (sDb > this.uttMaxDb) this.uttMaxDb = sDb;
    if (voiced) {
      const bin = Math.min(71, Math.max(0, Math.round(24 * Math.log2(f0 / 55))));
      this.f0Hist[bin]++;
      this.f0HistN++;
    }

    // ── Syllable-nucleus peaks ──────────────────────────────────────────────
    // Final-syllable lengthening shows up as the time since the last energy
    // peak outgrowing the utterance's own inter-peak rhythm. Peaks are taken
    // on the smoothed envelope: a peak completes when the envelope has fallen
    // PEAK_FALL_DB from a candidate that stood within PEAK_WITHIN_DB of the
    // utterance maximum, with a refractory so micro-wobbles don't multiply.
    const nowMs = (at / this.sampleRate) * 1000;
    if (sDb >= this.peakCandDb) {
      this.peakCandDb = sDb;
      this.peakCandAt = nowMs;
    } else if (this.peakCandDb - sDb > PEAK_FALL_DB) {
      if (
        this.peakCandDb > this.uttMaxDb - PEAK_WITHIN_DB &&
        (this.lastPeakAt < 0 || this.peakCandAt - this.lastPeakAt > PEAK_REFRACT_MS)
      ) {
        if (this.lastPeakAt >= 0) {
          const ipi = Math.min(IPI_MAX_MS, Math.max(IPI_MIN_MS, this.peakCandAt - this.lastPeakAt));
          this.ipiRing[this.ipiHead] = ipi;
          this.ipiHead = (this.ipiHead + 1) % IPI_RING;
          if (this.ipiN < IPI_RING) this.ipiN++;
        }
        this.lastPeakAt = this.peakCandAt;
      }
      this.peakCandDb = sDb;
      this.peakCandAt = nowMs;
    }

    this.armed = this.activeFrames >= this.minUttFrames;
    if (!this.armed) {
      if (this.debug) events.push({ type: 'score', at, prob: 0, armed: false, utt: this.utt });
      return;
    }

    // ── Features ────────────────────────────────────────────────────────────
    const feat = this._features(nowMs);
    let z = BIAS;
    for (let k = 0; k < 8; k++) z += WEIGHTS[k] * ((feat[k] - FEAT_MEAN[k]) / FEAT_SCALE[k]);
    const prob = 1 / (1 + Math.exp(-z));

    if (this.debug) {
      events.push({ type: 'score', at, prob, armed: true, utt: this.utt, feat: Array.from(feat) });
    } else {
      events.push({ type: 'score', at, prob });
    }

    if (!this.fired && prob >= this.threshold && at - this.lastFireAt >= this.minRefireSamples) {
      this.fired = true;
      this.lastFireAt = at;
      events.push({ type: 'predict', at, prob, leadMs: HORIZON_MS });
    } else if (this.fired && prob <= this.reset) {
      this.fired = false; // re-arm
    }
  }

  _resetUtterance() {
    this.utt++;
    this.uttMaxDb = -Infinity;
    this.peakCandDb = -Infinity;
    this.lastPeakAt = -1;
    this.ipiN = 0;
    this.ipiHead = 0;
    this.f0Hist.fill(0);
    this.f0HistN = 0;
    this.ringN = 0;
    this.ringHead = 0;
    this.fired = false;
  }

  /** The 8-feature vector. Order is load-bearing: WEIGHTS/FEAT_MEAN index it. */
  _features(nowMs) {
    const F = ENV_FRAMES;
    const n = Math.min(this.ringN, F);
    // Read the rings oldest→newest into index space: idx 0 = oldest.
    const at = (ring, k) => ring[(this.ringHead - n + k + 2 * F) % F];

    // 0: energy slope over the last SLOPE_FRAMES, dB/s (least squares).
    const m = Math.min(n, SLOPE_FRAMES);
    let sx = 0, sy = 0, sxx = 0, sxy = 0;
    for (let k = 0; k < m; k++) {
      const t = k * 10; // ms
      const y = at(this.envDb, n - m + k);
      sx += t; sy += y; sxx += t * t; sxy += t * y;
    }
    const denom = m * sxx - sx * sx;
    const eSlope = denom > 0 ? ((m * sxy - sx * sy) / denom) * 1000 : 0; // dB per second

    // 1: energy drop below the 600 ms maximum, dB (≤ 0).
    let eMax = -Infinity;
    for (let k = 0; k < n; k++) {
      const v = at(this.envDb, k);
      if (v > eMax) eMax = v;
    }
    const eDrop = at(this.envDb, n - 1) - eMax;

    // 2: F0 slope over the last 300 ms of voiced frames, semitones/s.
    // 3: F0 drop below the utterance median, semitones.
    let vx = 0, vy = 0, vxx = 0, vxy = 0, vn = 0;
    let f0Now = 0;
    let voicedCount = 0;
    for (let k = 0; k < m; k++) {
      const f = at(this.f0Hz, n - m + k);
      if (f > 0) {
        const t = k * 10;
        const y = 12 * Math.log2(f);
        vx += t; vy += y; vxx += t * t; vxy += t * y;
        vn++;
        f0Now = f;
      }
    }
    const vdenom = vn * vxx - vx * vx;
    const f0Slope = vn >= 4 && vdenom > 0 ? ((vn * vxy - vx * vy) / vdenom) * 1000 : 0;
    let f0Med = 0;
    if (this.f0HistN >= 8) {
      const half = this.f0HistN / 2;
      let acc = 0;
      for (let b = 0; b < 72; b++) {
        acc += this.f0Hist[b];
        if (acc >= half) {
          f0Med = 55 * Math.pow(2, b / 24);
          break;
        }
      }
    }
    const f0Drop = f0Now > 0 && f0Med > 0 ? 12 * Math.log2(f0Now / f0Med) : 0;

    // 4: periodicity drop below the 600 ms maximum — creak/aperiodicity.
    let pMax = 0;
    for (let k = 0; k < n; k++) {
      const v = at(this.period, k);
      if (v > pMax) pMax = v;
    }
    const aperDrop = at(this.period, n - 1) - pMax;

    // 5/6: time since the last nucleus peak, raw and relative to the
    // utterance's own inter-peak rhythm (final-syllable lengthening).
    const uttStartMs = ((this.samplesSeen - this.activeFrames * this.frame) / this.sampleRate) * 1000;
    const sincePeak = this.lastPeakAt >= 0 ? nowMs - this.lastPeakAt : nowMs - uttStartMs;
    const tPeak = Math.min(1000, sincePeak);
    let lenRatio = 1;
    if (this.ipiN >= 2) {
      for (let k = 0; k < this.ipiN; k++) this.ipiSorted[k] = this.ipiRing[k];
      const s = this.ipiSorted.subarray(0, this.ipiN);
      s.sort();
      const med = this.ipiN % 2 ? s[(this.ipiN - 1) / 2] : (s[this.ipiN / 2 - 1] + s[this.ipiN / 2]) / 2;
      lenRatio = med > 0 ? Math.min(6, sincePeak / med) : 1;
    }

    // 7: fraction of the last 300 ms that was voiced.
    for (let k = 0; k < m; k++) {
      if (at(this.f0Hz, n - m + k) > 0) voicedCount++;
    }
    const voicedFrac = m > 0 ? voicedCount / m : 0;

    return [eSlope, eDrop, f0Slope, f0Drop, aperDrop, tPeak, lenRatio, voicedFrac];
  }

  /**
   * Normalised autocorrelation over the plausible F0 range on the most recent
   * ~29 ms of decimated audio — same estimator as onset.js, plus parabolic
   * interpolation on the peak so the F0 *slope* feature isn't dominated by
   * lag quantisation at 8 kHz.
   */
  _pitch() {
    const R = this.ring;
    const L = R.length;
    const win = PITCH_WIN;
    if (this.samplesSeen / DECIM < win + LAG_MAX) return { f0: 0, peak: 0 };

    const need = win + LAG_MAX;
    const buf = this.pitchBuf;
    let p = (this.ringPos - need + 2 * L) % L;
    for (let k = 0; k < need; k++) {
      buf[k] = R[p];
      p = (p + 1) % L;
    }

    let e0 = 0;
    for (let k = 0; k < win; k++) e0 += buf[k] * buf[k];
    if (e0 < EPS) return { f0: 0, peak: 0 };

    let best = 0;
    let bestLag = 0;
    const rs = this._rs ?? (this._rs = new Float32Array(LAG_MAX + 2));
    for (let lag = LAG_MIN; lag <= LAG_MAX; lag++) {
      let num = 0, eL = 0;
      for (let k = 0; k < win; k++) {
        const b = buf[k + lag];
        num += buf[k] * b;
        eL += b * b;
      }
      const r = eL < EPS ? 0 : num / Math.sqrt(e0 * eL);
      rs[lag] = r;
      if (r > best) {
        best = r;
        bestLag = lag;
      }
    }
    if (bestLag === 0) return { f0: 0, peak: 0 };

    // Parabolic interpolation around the peak lag.
    let lagF = bestLag;
    if (bestLag > LAG_MIN && bestLag < LAG_MAX) {
      const r0 = rs[bestLag - 1], r1 = rs[bestLag], r2 = rs[bestLag + 1];
      const d = r0 - 2 * r1 + r2;
      if (Math.abs(d) > EPS) lagF = bestLag + 0.5 * (r0 - r2) / d;
    }
    return { f0: (SAMPLE_RATE / DECIM) / lagF, peak: best };
  }

  /** Current noise floor in dB, for UI. Null before calibration completes. */
  get noiseFloorDb() {
    return this.realFrames > this.calibrateFrames ? this.floorDb : null;
  }
}
