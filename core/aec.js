/**
 * Reference-based acoustic echo cancellation — DESIGN.md §5 v2.
 *
 * With the browser's DSP chain refused (echoCancellation:false — §5's "podcast
 * voice" requirement), the speakers feed the mic and the far end hears
 * themselves. v1's answer was headphones. v2's is this: because we own the
 * playout ring and the audio clock, we know sample-accurately what went to the
 * DAC, so the canceller gets a known reference instead of the browser's blind
 * guess — a fundamentally easier problem, and one that can be solved
 * LINEAR-ONLY.
 *
 * Linear-only is the one hard requirement (§5, tell 8): the output is always
 * `mic − filter(ref)`. There is no suppressor, no gain ducking, no comfort
 * noise, no gate anywhere in this file. The only nonlinear element is the
 * decision to PAUSE ADAPTATION during double-talk — the filter keeps
 * subtracting with its last good weights while both parties speak, so the
 * near end is never pumped or ducked. The accepted price (design note §5.2):
 * during double-talk the residual echo rises, because the filter is frozen
 * while the room may be changing. §5 chose that trade; do not "fix" it by
 * adding a suppressor.
 *
 * Algorithm: partitioned-block frequency-domain NLMS (MDF), 4096 taps as
 * 32 partitions × 128 samples (85 ms tail — real rooms run 50–100 ms of
 * reverb), overlap-save, per-bin normalized step sizes, rotating gradient
 * constraint, two-path filter (background adaptive + foreground fixed,
 * copy-over only when the background provably wins by 6 dB — Speex/WebRTC-
 * AECM's oldest trick, insurance against divergence), and a power-ratio
 * double-talk detector gated on convergence so it cannot stall startup.
 *
 * Alignment honesty: D = outputLatency + inputLatency + acousticDelay is
 * bounded-but-nonzero and WANDERS slowly (Chrome's capture resampler, design
 * note §2.2). The caller passes its best delay estimate per block; this
 * module absorbs sub-millisecond wander in the filter tail and re-aligns its
 * spectrum cache when the estimate moves. `alignmentScan` is the coarse
 * cross-correlation the worklet's tracker uses to re-measure D from loud
 * far-end single-talk.
 *
 * No browser dependencies, no allocation in the steady-state hot path (every
 * buffer is allocated at construction; the per-block return object is the one
 * exception, 375 tiny objects/s — the same discipline onset.js applies to its
 * event arrays). Runs identically under an AudioWorklet and under node, which
 * is how it is tested. Slated for the shared Rust core (§19.3).
 */

export const AEC_SAMPLE_RATE = 48000;
export const AEC_BLOCK = 128; // the AudioWorklet render quantum
export const AEC_PARTITIONS = 32; // × 128 samples = 4096 taps = 85 ms tail

// ── Tuning ───────────────────────────────────────────────────────────────────
const MU = 1.0; // normalized step size. With the per-bin normaliser and the
//                 attack/release power tracker, measured on speech-like
//                 synthetic echo: 20 dB ERLE by ~300 ms, 50–80 dB steady-state.
//                 0.75 was tried first ("misadjustment margin") and REJECTED on
//                 measurement: the synthetic speech f0 wanders ±25 Hz, its
//                 harmonics cross bins every syllable, and 0.75 cannot track
//                 within a syllable — per-syllable residual sat ~15 dB, with
//                 pops 6–11 dB over the room-tone floor that fired the onset
//                 detector on echo alone. At 1.0 (exact per-block projection)
//                 those pops drop below the floor and steady ERLE gains
//                 12–40 dB. 1.25 overshoots (oscillatory, measured worse).
const POW_RELEASE = 0.05; // per-bin reference-power tracker: INSTANT attack,
//                 slow (~50 ms) release. Symmetric smoothing was measured to
//                 destabilise adaptation on speech: at syllable onsets the
//                 lagging normaliser undershoots the true frame energy, the
//                 normalised step overshoots, and ERLE collapses mid-
//                 convergence (ablation: white noise clean, speech dipped to
//                 −9 dB). Attack/release is the standard fix.

const POW_FLOOR_REL = 1e-4; // quiet-bin step cap, relative to the loudest bin:
//                 without it, bins the reference never energises get a
//                 near-zero normaliser and adapt on pure noise.
const REF_MIN_POW = 1e-7; // −70 dBFS: below this the reference carries nothing
//                 learnable, and adapting would only chase mic noise.
const DT_RATIO = 4; // double-talk: mic power ≥ 6 dB over the estimated echo
//                 power (attack/release tracked, so syllable onsets don't
//                 outrun it). Only armed once `adapted`, so it can never stall
//                 initial convergence.
const GEIGEL_RATIO = 2; // secondary peak test — against the ESTIMATE, not the
//                 raw reference. The classic Geigel form (mic ≥ ½·max|ref|)
//                 is structurally broken here: at −6 dB echo the echo alone
//                 sits exactly at the 0.5 ratio and freezes adaptation
//                 forever (measured). Referenced to the estimate instead:
//                 echo-only blocks sit at ratio ≈ 1, near-end speech lifts it.
// A third, residual-ratio test (freeze when resid ≳ mic/2) was tried and
//                 REMOVED: after an echo-path step (delay or gain change) the
//                 residual is legitimately large until re-convergence, and the
//                 test deadlocked adaptation exactly when it was needed. A
//                 missed quiet double-talk instead diverges the background and
//                 is caught by the two-path revert — which is what the
//                 two-path is for.
const DT_HOLD_BLOCKS = 24; // ≈64 ms hangover: speech pauses inside one
//                 utterance must not re-arm adaptation mid-double-talk.
const CMP_WINDOW = 48; // two-path comparison window, blocks (≈128 ms)
const COPY_MARGIN = 4; // 6 dB: background must beat foreground by this much
//                 power-ratio to be copied over — hysteresis against chatter.
const CONSTRAINT_PER_BLOCK = 4; // partitions gradient-constrained per block
//                 (rotating): each partition is windowed every 8 blocks ≈ 21 ms.
//                 Speex's staggered-update trick — the full 32 every block would
//                 triple the FFT budget for no measurable ERLE.
const SCAN_DEFAULT_HALFWIDTH = 240; // ±5 ms around the delay hint (design §2.2)

const EPS = 1e-12;
const db10 = (x) => 10 * Math.log10(Math.max(x, EPS));

/** Smallest power of two ≥ n. */
function pow2ceil(n) {
  let p = 1;
  while (p < n) p <<= 1;
  return p;
}

/**
 * In-place iterative radix-2 FFT, twiddles and bit-reversal precomputed once.
 * Buffers are separate re/im Float32Arrays of length n; nothing is allocated
 * per call. Inverse is the conjugate trick with 1/n scaling.
 */
class Fft {
  constructor(n) {
    this.n = n;
    this.rev = new Uint32Array(n);
    for (let i = 0; i < n; i++) {
      let r = 0;
      for (let b = 0; b < 32; b++) if (i & (1 << b)) r |= 1 << (31 - b);
      this.rev[i] = r >>> (32 - Math.log2(n));
    }
    const half = n >> 1;
    this.cos = new Float32Array(half);
    this.sin = new Float32Array(half);
    for (let k = 0; k < half; k++) {
      this.cos[k] = Math.cos((-2 * Math.PI * k) / n);
      this.sin[k] = Math.sin((-2 * Math.PI * k) / n);
    }
  }

  forward(re, im) {
    const n = this.n;
    const rev = this.rev;
    for (let i = 0; i < n; i++) {
      const j = rev[i];
      if (j > i) {
        const tr = re[i]; re[i] = re[j]; re[j] = tr;
        const ti = im[i]; im[i] = im[j]; im[j] = ti;
      }
    }
    for (let size = 2; size <= n; size <<= 1) {
      const half = size >> 1;
      const step = n / size;
      for (let base = 0; base < n; base += size) {
        for (let j = 0; j < half; j++) {
          const t = j * step;
          const c = this.cos[t];
          const s = this.sin[t];
          const a = base + j;
          const b = a + half;
          const xr = re[b] * c - im[b] * s;
          const xi = re[b] * s + im[b] * c;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
        }
      }
    }
  }

  inverse(re, im) {
    const n = this.n;
    for (let i = 0; i < n; i++) im[i] = -im[i];
    this.forward(re, im);
    for (let i = 0; i < n; i++) {
      re[i] /= n;
      im[i] = -im[i] / n;
    }
  }
}

/**
 * The canceller. One instance per capture direction.
 *
 *   const aec = new Aec({ sampleRate: 48000, block: 128, partitions: 32 });
 *   aec.pushReference(refBlock);            // what the speaker is playing
 *   const { erleDb, dtFlag } = aec.process(micBlock, outBlock, {
 *     delaySamples: D,                      // caller's current D estimate
 *   });                                     // outBlock = mic − estimated echo
 *
 * Contract and honesty notes:
 *  - pushReference and process are expected in lockstep, one block each, ref
 *    first. The delay hint says how many samples EARLIER the reference window
 *    for this mic block ends: the mic block ending "now" echoes the reference
 *    that ended at `refCount − delaySamples`. D is an estimate (design §2.2);
 *    the module caches partition spectra aligned to D and rebuilds them when
 *    D moves, so moves are cheap but not free — the tracker should move D in
 *    stable steps, not chase it per block.
 *  - The canceller is linear-only BY CONSTRUCTION: out = mic − filter(ref),
 *    always. Double-talk only freezes adaptation; the subtraction continues.
 *  - `delaySamples` is clamped to [0, maxDelay]. Echo energy beyond
 *    partitions×block samples past D is outside the tail and will not be
 *    cancelled — size maxDelay and partitions for the real room, not the hoped
 *    one.
 */
export class Aec {
  constructor(opts = {}) {
    this.sampleRate = opts.sampleRate ?? AEC_SAMPLE_RATE;
    this.block = opts.block ?? AEC_BLOCK;
    this.partitions = opts.partitions ?? AEC_PARTITIONS;
    this.mu = opts.mu ?? MU;
    // Largest bulk delay the caller may hint. 8192 samples ≈ 170 ms covers
    // outputLatency + inputLatency + acoustic with the design's 4× headroom.
    this.maxDelay = opts.maxDelay ?? 8192;

    const L = this.block;
    const N = 2 * L;
    const P = this.partitions;
    this.L = L;
    this.N = N;
    this.P = P;

    this.fft = new Fft(N);

    // Reference sample history: everything the spectra windows can reach,
    // maxDelay + full tail + one window, rounded up to a power of two ring.
    this.histLen = pow2ceil(this.maxDelay + P * L + N);
    this.histMask = this.histLen - 1;
    this.refHist = new Float32Array(this.histLen);
    this.refCount = 0; // absolute samples pushed
    this.delaySamples = 0;

    // Partition spectrum ring. Slot layout: partition p (0 = newest) lives at
    // slot (specPos − 1 − p + 2P) mod P. Interleaved per-partition re then im.
    this.Xre = new Float32Array(P * N);
    this.Xim = new Float32Array(P * N);
    this.specPos = 0;
    this.specFilled = 0; // blocks written since construction/flush, ≤ P

    this.ps = new Float32Array(N); // running Σ_p |X_p[k]|²
    this.power = new Float32Array(N); // smoothed ps, the NLMS normaliser

    // Two-path weights: background adapts, foreground produces the output.
    this.Wre = new Float32Array(P * N);
    this.Wim = new Float32Array(P * N);
    this.Fre = new Float32Array(P * N);
    this.Fim = new Float32Array(P * N);
    // Known-good anchor: a snapshot of the foreground taken while ERLE is
    // provably high. The filter taps are RELATIVE to the delay hint, so when
    // the tracker moves the hint to follow a true delay change, the pre-move
    // adaptation (which had begun chasing the echo at its new relative
    // position, and had already been copied into the foreground — measured)
    // is exactly wrong and the anchor is exactly right. §17.14's discipline,
    // one level down: one anchor, refreshed only from trustworthy
    // observations.
    this.snapRe = new Float32Array(P * N);
    this.snapIm = new Float32Array(P * N);
    this.snapValid = false;
    this.lastSnapBlock = -1000;

    // Per-block scratch.
    this.winRe = new Float32Array(N); // current ref window / its spectrum
    this.winIm = new Float32Array(N);
    this.Yre = new Float32Array(N); // estimate spectrum (foreground)
    this.Yim = new Float32Array(N);
    this.Bre = new Float32Array(N); // estimate spectrum (background)
    this.Bim = new Float32Array(N);
    this.Ere = new Float32Array(N); // error spectrum
    this.Eim = new Float32Array(N);
    this.conRe = new Float32Array(N); // gradient-constraint scratch
    this.conIm = new Float32Array(N);
    this.yfg = new Float32Array(L); // time-domain echo estimates
    this.ybg = new Float32Array(L);
    this.ebg = new Float32Array(L);

    // Double-talk state: estimate-referenced level trackers, attack/release
    // (instant up, ~60–130 ms down) so speech onsets can't outrun them.
    this.yPowSm = 0; // foreground-estimate power
    this.yPkSm = 0; // foreground-estimate peak magnitude
    this.dtHold = 0;
    this.dtFlag = false;
    this.adapted = false; // foreground filter is known-decent

    // Two-path comparison accumulators (windowed, reset on swap).
    this.cmpResBg = 0;
    this.cmpResFg = 0;
    this.cmpN = 0;

    // Alignment-scan accumulators (absolute-lag axis; only the requested
    // window is touched per call). Reference energy is accumulated PER LAG:
    // normalising by the centre lag's energy alone lets strong ref self-
    // correlation (speech pitch periods) outscore the true echo lag once the
    // hint window moves off it (measured: the tracker walked away in ±pitch
    // steps). With per-lag energies the score is a true normalised
    // correlation — but note it still cannot separate "echo at lag D" from
    // "echo of a periodic signal at lag D+T0" on level alone; the caller's
    // stability voting and ERLE gating carry that.
    this.scanAcc = new Float32Array(this.maxDelay + 1);
    this.scanRefE = new Float32Array(this.maxDelay + 1);
    this.scanMicE = 0;
    this.scanN = 0;

    // Telemetry (EWMAs, read via `stats`).
    this.erleEwma = null;
    this.dtFrac = 0;
    this.blocksProcessed = 0;
  }

  /** Append reference (speaker-bound) samples. Any length ≤ histLen/2. */
  pushReference(samples) {
    const h = this.refHist;
    const m = this.histMask;
    let p = this.refCount & m;
    for (let i = 0; i < samples.length; i++) {
      h[p] = samples[i];
      p = (p + 1) & m;
    }
    this.refCount += samples.length;
  }

  /** Read ref samples [end − n, end) into out, zero where before stream start. */
  _readRef(end, n, out) {
    const h = this.refHist;
    const m = this.histMask;
    for (let i = 0; i < n; i++) {
      const idx = end - n + i;
      out[i] = idx >= 0 ? h[idx & m] : 0;
    }
  }

  /**
   * Rebuild the older partition spectra from the sample history at the new
   * alignment, after the delay hint moved. Partition 0 (the current block's
   * window) is deliberately left to the normal write path of the process()
   * call in progress — its slot convention then stays intact. Costs P−1 FFTs
   * once, vs 85 ms of misaligned subtraction on a stale ring.
   */
  _refillSpectra(refEnd) {
    const { L, N, P } = this;
    this.ps.fill(0);
    for (let p = P - 1; p >= 1; p--) {
      this._readRef(refEnd - p * L, N, this.winRe);
      this.winIm.fill(0);
      this.fft.forward(this.winRe, this.winIm);
      const slot = ((this.specPos - p + 2 * P) % P) * N;
      for (let k = 0; k < N; k++) {
        const re = this.winRe[k];
        const im = this.winIm[k];
        this.Xre[slot + k] = re;
        this.Xim[slot + k] = im;
        this.ps[k] += re * re + im * im;
      }
    }
    // Ring reads as full except the slot the in-progress write is about to
    // fill — so that write must not subtract stale power from the fresh sum.
    this.specFilled = P - 1;
  }

  _blockPow(x, off) {
    let s = 0;
    for (let i = off; i < off + this.L; i++) s += x[i] * x[i];
    return s / this.L;
  }

  /**
   * Run one block. `mic` and `out` are Float32Array(block); `delaySamples` is
   * the caller's current D estimate (optional — omit to keep the last value).
   * Returns { erleDb, dtFlag }: the block's instantaneous ERLE (dB, capped)
   * and whether adaptation was frozen this block.
   */
  process(mic, out, opts = {}) {
    const { L, N, P } = this;
    if (opts.delaySamples != null) {
      const d = Math.max(0, Math.min(this.maxDelay, Math.round(opts.delaySamples)));
      if (d !== this.delaySamples) {
        this.delaySamples = d;
        this._refillSpectra(this.refCount - d);
        // Re-anchor the filters: their taps are relative to the hint, so the
        // last known-good set is the best estimate at the new alignment. If
        // the room genuinely changed too, re-adaptation proceeds from here;
        // the two-path copy will overtake it within a window if wrong.
        if (this.snapValid) {
          this.Fre.set(this.snapRe);
          this.Fim.set(this.snapIm);
          this.Wre.set(this.snapRe);
          this.Wim.set(this.snapIm);
          this.cmpResBg = 0;
          this.cmpResFg = 0;
          this.cmpN = 0;
          this.adapted = true;
        } else {
          // No anchor (bootstrap): the current weights are aligned to the OLD
          // hint and are anti-signal at the new one — measured: keeping them
          // drives ERLE negative, the estimate-referenced DTD then deadlocks
          // adaptation for seconds. A clean restart converges in ~400 ms.
          this.Fre.fill(0);
          this.Fim.fill(0);
          this.Wre.fill(0);
          this.Wim.fill(0);
          this.cmpResBg = 0;
          this.cmpResFg = 0;
          this.cmpN = 0;
          this.adapted = false;
          this.dtHold = 0;
          this.yPowSm = 0;
          this.yPkSm = 0;
        }
      }
    }
    const refEnd = this.refCount - this.delaySamples;

    // One new window into the spectrum ring. The window [refEnd−N, refEnd) is
    // the current reference block preceded by its neighbour — overlap-save.
    // After a delay-change refill the ring is full and correctly aligned, and
    // this write simply overwrites the oldest partition (which sits exactly at
    // specPos by the slot convention).
    this._readRef(refEnd, N, this.winRe);
    this.winIm.fill(0);
    const pRef = this._blockPow(this.winRe, L);
    this.fft.forward(this.winRe, this.winIm);
    const slot = (this.specPos % P) * N;
    if (this.specFilled === P) {
      // Subtract the spectrum being overwritten from the running power sum.
      for (let k = 0; k < N; k++) {
        const re = this.Xre[slot + k];
        const im = this.Xim[slot + k];
        this.ps[k] -= re * re + im * im;
      }
    }
    for (let k = 0; k < N; k++) {
      this.Xre[slot + k] = this.winRe[k];
      this.Xim[slot + k] = this.winIm[k];
      this.ps[k] += this.winRe[k] * this.winRe[k] + this.winIm[k] * this.winIm[k];
    }
    this.specPos = (this.specPos + 1) % P;
    if (this.specFilled < P) this.specFilled++;
    this._pRef = pRef;

    // Attack/release normaliser, floored relative to the loudest bin.
    let pMax = 0;
    for (let k = 0; k < N; k++) {
      const ps = Math.max(this.ps[k], 0);
      if (ps > this.power[k]) this.power[k] = ps;
      else this.power[k] += (ps - this.power[k]) * POW_RELEASE;
      if (this.power[k] > pMax) pMax = this.power[k];
    }
    const powFloor = Math.max(pMax * POW_FLOOR_REL, EPS);

    // ── Estimates: foreground (output) and background (adaptation) ──────────
    this.Yre.fill(0);
    this.Yim.fill(0);
    this.Bre.fill(0);
    this.Bim.fill(0);
    for (let p = 0; p < P; p++) {
      const Xb = ((this.specPos - 1 - p + 2 * P) % P) * N;
      const Wb = p * N;
      for (let k = 0; k < N; k++) {
        const xr = this.Xre[Xb + k];
        const xi = this.Xim[Xb + k];
        this.Yre[k] += this.Fre[Wb + k] * xr - this.Fim[Wb + k] * xi;
        this.Yim[k] += this.Fre[Wb + k] * xi + this.Fim[Wb + k] * xr;
        this.Bre[k] += this.Wre[Wb + k] * xr - this.Wim[Wb + k] * xi;
        this.Bim[k] += this.Wre[Wb + k] * xi + this.Wim[Wb + k] * xr;
      }
    }
    this.fft.inverse(this.Yre, this.Yim);
    this.fft.inverse(this.Bre, this.Bim);

    // Overlap-save: the last L samples are the valid convolution output.
    let pMic = 0;
    let pResFg = 0;
    let pResBg = 0;
    let dMax = 0;
    for (let i = 0; i < L; i++) {
      const yf = this.Yre[L + i];
      const yb = this.Bre[L + i];
      this.yfg[i] = yf;
      this.ybg[i] = yb;
      const m = mic[i];
      const ef = m - yf;
      const eb = m - yb;
      out[i] = ef;
      this.ebg[i] = eb;
      pMic += m * m;
      pResFg += ef * ef;
      pResBg += eb * eb;
      const a = m < 0 ? -m : m;
      if (a > dMax) dMax = a;
    }
    pMic /= L;
    pResFg /= L;
    pResBg /= L;
    const pYfg = this._arrPow(this.yfg);
    let yPk = 0;
    for (let i = 0; i < L; i++) {
      const a = this.yfg[i] < 0 ? -this.yfg[i] : this.yfg[i];
      if (a > yPk) yPk = a;
    }
    // Attack/release trackers of the ESTIMATE's level: instant attack, slow
    // release. A symmetric smoother lags speech onsets, the mic power then
    // outruns it by more than the 6 dB ratio and the DTD freezes on echo
    // alone (measured: dt fractions of 0.7–1.0 in pure single-talk).
    this.yPowSm = Math.max(pYfg, this.yPowSm * 0.98);
    this.yPkSm = Math.max(yPk, this.yPkSm * 0.98);

    // ── Double-talk freeze ──────────────────────────────────────────────────
    // Gated on `adapted`: pre-convergence the estimate is small by definition,
    // so any ratio test against it would freeze startup forever. All three
    // tests are estimate- or residual-referenced — see GEIGEL_RATIO for why
    // the raw-reference Geigel form is unusable at loud echo levels.
    const refActive = this._pRef > REF_MIN_POW;
    if (this.adapted && refActive) {
      if (
        pMic > DT_RATIO * this.yPowSm + EPS ||
        dMax >= GEIGEL_RATIO * this.yPkSm
      ) {
        this.dtHold = DT_HOLD_BLOCKS;
      }
    }
    if (this.dtHold > 0) {
      this.dtHold--;
      this.dtFlag = true;
    } else {
      this.dtFlag = false;
    }
    this.dtFrac += ((this.dtFlag ? 1 : 0) - this.dtFrac) * 0.01;

    // ── Adaptation (background filter only) ─────────────────────────────────
    if (refActive && !this.dtFlag) {
      // Error spectrum: [zeros(L), e_bg(L)] — overlap-save gradient.
      this.Ere.fill(0);
      this.Eim.fill(0);
      for (let i = 0; i < L; i++) this.Ere[L + i] = this.ebg[i];
      this.fft.forward(this.Ere, this.Eim);

      const mu = this.mu;
      for (let p = 0; p < P; p++) {
        const Xb = ((this.specPos - 1 - p + 2 * P) % P) * N;
        const Wb = p * N;
        for (let k = 0; k < N; k++) {
          const denom = this.power[k] > powFloor ? this.power[k] : powFloor;
          const step = mu / denom;
          // E · conj(X)
          this.Wre[Wb + k] += step * (this.Ere[k] * this.Xre[Xb + k] + this.Eim[k] * this.Xim[Xb + k]);
          this.Wim[Wb + k] += step * (this.Eim[k] * this.Xre[Xb + k] - this.Ere[k] * this.Xim[Xb + k]);
        }
      }

      // Rotating gradient constraint: window the tail out of a few partitions
      // per block, so circular-convolution wrap cannot accumulate.
      const base = (this.blocksProcessed * CONSTRAINT_PER_BLOCK) % P;
      for (let c = 0; c < CONSTRAINT_PER_BLOCK; c++) {
        const p = (base + c) % P;
        const Wb = p * N;
        for (let k = 0; k < N; k++) {
          this.conRe[k] = this.Wre[Wb + k];
          this.conIm[k] = this.Wim[Wb + k];
        }
        this.fft.inverse(this.conRe, this.conIm);
        for (let i = L; i < N; i++) {
          this.conRe[i] = 0;
          this.conIm[i] = 0;
        }
        this.fft.forward(this.conRe, this.conIm);
        for (let k = 0; k < N; k++) {
          this.Wre[Wb + k] = this.conRe[k];
          this.Wim[Wb + k] = this.conIm[k];
        }
      }
    }

    // ── Two-path bookkeeping ────────────────────────────────────────────────
    // Copy-over only on a proven 6 dB win, revert on a proven 6 dB loss; both
    // measured over clean single-talk windows so double-talk can't poison the
    // comparison.
    if (refActive && !this.dtFlag) {
      this.cmpResBg += pResBg;
      this.cmpResFg += pResFg;
      this.cmpN++;
      if (this.cmpN >= CMP_WINDOW) {
        const bg = this.cmpResBg / this.cmpN;
        const fg = this.cmpResFg / this.cmpN;
        if (bg * COPY_MARGIN < fg) {
          this.Fre.set(this.Wre);
          this.Fim.set(this.Wim);
          this.adapted = true;
        } else if (this.adapted && fg * COPY_MARGIN < bg) {
          // The background has diverged (a missed double-talk, a path step):
          // throw it away and re-adapt from the last good foreground.
          this.Wre.set(this.Fre);
          this.Wim.set(this.Fim);
        }
        this.cmpResBg = 0;
        this.cmpResFg = 0;
        this.cmpN = 0;
      }
    }

    // Anchor refresh — only from trustworthy observations (high ERLE), at
    // most once a second so a briefly-good stretch can't churn it.
    if (
      this.erleEwma !== null && this.erleEwma > 25 &&
      this.blocksProcessed - this.lastSnapBlock >= 375
    ) {
      this.snapRe.set(this.Fre);
      this.snapIm.set(this.Fim);
      this.snapValid = true;
      this.lastSnapBlock = this.blocksProcessed;
    }

    this.blocksProcessed++;
    const erleDb = Math.min(db10(pMic / Math.max(pResFg, EPS)), 120);
    if (refActive) {
      this.erleEwma = this.erleEwma === null ? erleDb : this.erleEwma + (erleDb - this.erleEwma) * 0.05;
    }
    return { erleDb, dtFlag: this.dtFlag };
  }

  _arrPow(x) {
    let s = 0;
    for (let i = 0; i < x.length; i++) s += x[i] * x[i];
    return s / x.length;
  }

  /**
   * Coarse reference↔mic cross-correlation for the alignment tracker (design
   * §2.2). Call after the block's pushReference+process; correlations
   * ACCUMULATE across calls until resetAlignmentScan(), so the tracker can
   * integrate over as much loud far-end single-talk as it wants before
   * reading the peak. Only lags within [center−halfWidth, center+halfWidth]
   * are computed (cost ≈ 2·halfWidth·L MACs per call).
   *
   * Returns { lag, score, samples }: the accumulated winner, its normalised
   * correlation score (0..1 — trust moves only when this is high, the worklet
   * tracker EWMAs and triple-checks before moving), and how many samples the
   * accumulator holds.
   */
  alignmentScan(mic, opts = {}) {
    const center = Math.round(opts.center ?? this.delaySamples);
    const half = Math.min(opts.halfWidth ?? SCAN_DEFAULT_HALFWIDTH, this.maxDelay >> 1);
    const lo = Math.max(0, center - half);
    const hi = Math.min(this.maxDelay, center + half);
    const L = this.L;
    const t0 = this.refCount; // mic block aligns with the latest pushed ref
    const h = this.refHist;
    const m = this.histMask;

    let micE = 0;
    for (let i = 0; i < L; i++) micE += mic[i] * mic[i];
    this.scanMicE += micE;

    for (let lag = lo; lag <= hi; lag++) {
      let s = 0;
      let e = 0;
      const base = t0 - lag - L;
      for (let i = 0; i < L; i++) {
        const idx = base + i;
        if (idx >= 0) {
          const v = h[idx & m];
          s += mic[i] * v;
          e += v * v;
        }
      }
      this.scanAcc[lag] += s;
      this.scanRefE[lag] += e;
    }
    this.scanN += L;

    let best = lo;
    let bestScore = 0;
    for (let lag = lo; lag <= hi; lag++) {
      const a = this.scanAcc[lag] < 0 ? -this.scanAcc[lag] : this.scanAcc[lag];
      const denom = Math.sqrt(this.scanMicE * Math.max(this.scanRefE[lag], EPS));
      const sc = denom > 0 ? a / denom : 0;
      if (sc > bestScore) {
        bestScore = sc;
        best = lag;
      }
    }
    return { lag: best, score: bestScore, samples: this.scanN };
  }

  resetAlignmentScan() {
    this.scanAcc.fill(0);
    this.scanRefE.fill(0);
    this.scanMicE = 0;
    this.scanN = 0;
  }

  /** Telemetry snapshot — the worklet ships this on its 1 Hz tick. */
  get stats() {
    return {
      erleDb: this.erleEwma,
      dtFrac: this.dtFrac,
      delaySamples: this.delaySamples,
      adapted: this.adapted,
      refActive: this._pRef > REF_MIN_POW,
    };
  }
}
