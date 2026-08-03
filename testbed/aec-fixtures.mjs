/**
 * Synthetic fixtures and drivers for the AEC v2 offline suite (task #27,
 * design note aec-v2-design.md §4.1). Everything is deterministic: one seeded
 * PRNG, same discipline as core/onset.test.mjs.
 *
 * Signal conventions: 48 kHz mono Float32Array, full scale ±1. Echo levels are
 * stated relative to the REFERENCE (the far-end signal that goes to the
 * speaker), per the design note — "−12 dB echo" means the mic sees the
 * reference convolved with the echo path and scaled by 10^(−12/20).
 *
 * The Tracker class is the OFFLINE STAND-IN for the worklet's alignment
 * tracker (design §2.2, worklet plumbing is a later step): it drives
 * aec.alignmentScan in fixed cycles, votes for stability, and moves the delay
 * hint. Kept here so the worklet implementation can be tested against the
 * same behaviour.
 */

export const SR = 48000;

// Deterministic PRNG so a failure is always reproducible.
let seed = 0x2f6e2b1;
export function reseed(s = 0x2f6e2b1) { seed = s; }
export function rand() {
  seed ^= seed << 13;
  seed ^= seed >>> 17;
  seed ^= seed << 5;
  seed |= 0;
  return (seed >>> 0) / 0xffffffff - 0.5;
}

export const ms = (n) => Math.round((n / 1000) * SR);

export function silence(durMs) {
  return new Float32Array(ms(durMs));
}

/** Room tone: very low broadband noise, as onset.test.mjs (~−63 dBFS RMS). */
export function roomTone(durMs, amp = 0.0012) {
  const out = new Float32Array(ms(durMs));
  for (let i = 0; i < out.length; i++) out[i] = rand() * 2 * amp;
  return out;
}

/**
 * Far-end speech stand-in: harmonic stack with wandering f0, syllabic on/off
 * gating (60% duty at 4 Hz) and amplitude modulation, plus a little
 * aspiration noise. Deliberately hostile to an echo canceller: sparse
 * spectrum, hard onsets every ~270 ms, frequent silence.
 */
export function speech(durMs, amp = 0.15) {
  const n = ms(durMs);
  const out = new Float32Array(n);
  let phase = 0;
  for (let i = 0; i < n; i++) {
    const t = i / SR;
    const f0 = 110 + 25 * Math.sin(2 * Math.PI * t * 0.7);
    const sy = (t * 4) % 1;
    const on = sy < 0.6 ? 1 : 0;
    const am = on ? (0.5 + 0.5 * Math.sin(2 * Math.PI * t * 3.7)) : 0;
    phase += (2 * Math.PI * f0) / SR;
    let s = 0;
    for (let h = 1; h <= 14; h++) s += Math.sin(phase * h) / h;
    out[i] = (s * 0.35 * am + rand() * 0.02) * amp;
  }
  return out;
}

/** A pre-turn inhale, as onset.test.mjs. */
export function breath(durMs = 280, amp = 0.035) {
  const n = ms(durMs);
  const out = new Float32Array(n);
  let hp = 0;
  let prev = 0;
  for (let i = 0; i < n; i++) {
    const w = rand() * 2;
    const a = 0.82;
    hp = a * (hp + w - prev);
    prev = w;
    const t = i / n;
    const env = t < 0.4 ? 0.5 * (1 - Math.cos((Math.PI * t) / 0.4)) : 1 - 0.5 * ((t - 0.4) / 0.6);
    out[i] = hp * amp * env;
  }
  return out;
}

/** Voiced speech, as onset.test.mjs. */
export function voiced(durMs = 400, f0 = 118, amp = 0.18) {
  const n = ms(durMs);
  const out = new Float32Array(n);
  const harmonics = 14;
  for (let i = 0; i < n; i++) {
    const t = i / SR;
    let s = 0;
    for (let h = 1; h <= harmonics; h++) {
      if (f0 * h > SR / 2) break;
      s += Math.sin(2 * Math.PI * f0 * h * t) / h;
    }
    const ramp = Math.min(1, i / ms(8));
    out[i] = (s * 0.35 + rand() * 0.06) * amp * ramp;
  }
  return out;
}

/**
 * A longer near-end utterance for the turn-end transparency test: voiced with
 * syllabic peaks and a terminal fall (f0 −25%, intensity → −30 dB over
 * 450 ms, rising aperiodicity). The shipped predictor does not fire on this
 * (max prob ≈ 0.59 vs threshold 0.65 — real falls differ from read-speech
 * models) — it exists to compare the predictor's score STREAM across arms,
 * not to elicit fires.
 */
export function utterance(durMs = 4000, amp = 0.2) {
  const n = ms(durMs);
  const out = new Float32Array(n);
  let phase = 0;
  const fallStart = durMs / 1000 - 0.8;
  for (let i = 0; i < n; i++) {
    const t = i / SR;
    let f0 = 120;
    let a = amp;
    let noiseAmp = 0.004;
    if (t > fallStart) {
      const u = Math.min(1, (t - fallStart) / 0.45);
      f0 = 120 * (1 - 0.28 * u);
      a = amp * Math.pow(10, (-30 * u) / 20);
      noiseAmp = 0.004 + 0.09 * u;
    }
    const sy = (t * 4) % 1;
    const am = t > fallStart || sy < 0.7 ? 0.5 + 0.5 * Math.sin(2 * Math.PI * t * 3.7) : 0;
    phase += (2 * Math.PI * f0) / SR;
    let s = 0;
    for (let h = 1; h <= 12; h++) s += Math.sin(phase * h) / h;
    out[i] = s * 0.35 * a * am + rand() * 2 * noiseAmp;
  }
  return out;
}

export function concat(...parts) {
  const total = parts.reduce((a, p) => a + p.length, 0);
  const out = new Float32Array(total);
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

// ── Echo paths ───────────────────────────────────────────────────────────────

/** Impulse response: single direct tap at `delayMs`, unity gain. */
export function singleTapIR(delayMs) {
  const h = new Float32Array(ms(delayMs) + 1);
  h[ms(delayMs)] = 1;
  return h;
}

/** Direct tap + early reflection at +8 ms, −6 dB relative to the direct tap. */
export function twoTapIR(delayMs) {
  const h = new Float32Array(ms(delayMs + 8) + 1);
  h[ms(delayMs)] = 1;
  h[ms(delayMs + 8)] = 0.5;
  return h;
}

/**
 * Measured-ish room tail: exponentially decaying noise with RT60 ≈ `rt60Ms`,
 * direct tap at `delayMs`. Total length `lenMs` (default 90 ms). With the
 * delay hint at the direct tap the whole tail sits inside the canceller's
 * 85 ms filter (hint+4096 covers 100 ms absolute at delayMs=15), so the
 * fixture tests tail LEARNING, not tail truncation: the stochastic tail is
 * excitation-limited under speech and measured steady-state is 22–26 dB for
 * any lenMs in 60–90 (the direct tap itself cancels in ~400 ms). That is the
 * honest speech-driven limit — still above the 20 dB gate.
 */
export function reverbIR(delayMs, rt60Ms = 150, lenMs = 90) {
  const n = ms(lenMs);
  const h = new Float32Array(n);
  const d0 = ms(delayMs);
  h[d0] = 1;
  const tau = rt60Ms / 1000 / 6.908; // RT60: 60 dB decay in rt60Ms
  for (let i = d0 + ms(2); i < n; i++) {
    const t = (i - d0) / SR;
    h[i] = rand() * 2 * Math.exp(-t / tau) * 0.3;
  }
  return h;
}

/** mic = conv(ref, h) · gain, plus any near-end signal already in `near`. */
export function applyEcho(ref, h, echoDb, near = null) {
  const g = Math.pow(10, echoDb / 20);
  const out = new Float32Array(ref.length);
  for (let i = 0; i < ref.length; i++) {
    let s = 0;
    for (let j = 0; j < h.length && j <= i; j++) s += h[j] * ref[i - j];
    out[i] = s * g + (near ? near[i] : 0);
  }
  return out;
}

// ── Drivers ──────────────────────────────────────────────────────────────────

/**
 * Run the canceller over full-length ref/mic in 128-sample blocks, writing
 * the cleaned signal into a fresh array. Options:
 *   delaySamples — fixed hint (the calibrated path), or
 *   tracker      — a Tracker instance; its step() supplies the hint per block
 *   onBlock(aec, blockIndex) — per-block inspection hook (dtFlag counts etc.)
 */
export function driveAec(aec, ref, mic, opts = {}) {
  const out = new Float32Array(mic.length);
  const blk = new Float32Array(128);
  let b = 0;
  for (let i = 0; i + 128 <= mic.length; i += 128, b++) {
    aec.pushReference(ref.subarray(i, i + 128));
    const d = opts.tracker ? opts.tracker.hint : (opts.delaySamples ?? 0);
    aec.process(mic.subarray(i, i + 128), blk, { delaySamples: d });
    if (opts.tracker) opts.tracker.step(mic.subarray(i, i + 128));
    if (opts.onBlock) opts.onBlock(aec, b);
    out.set(blk, i);
  }
  return out;
}

/**
 * Offline stand-in for the worklet's alignment tracker (design §2.2). Scan
 * cycles of `cycleBlocks` blocks; the same lag winning `stable` consecutive
 * cycles moves the hint. Scans are skipped entirely while ERLE is healthy —
 * speech's pitch-period self-correlation rivals the echo peak on normalised
 * score, and the only robust gate is "don't look when already aligned".
 *
 * Two modes: until the first move it BOOTSTRAPS — a wide ±40 ms scan every
 * 4th block (the design's "online bootstrap": no calibration chirp needed);
 * after locking it tracks narrowly (±10 ms around the hint, every block).
 */
export class Tracker {
  constructor(aec, { halfWidth = 480, cycleBlocks = 24, stable = 3, scoreMin = 0.25 } = {}) {
    this.aec = aec;
    this.halfWidth = halfWidth;
    this.cycleBlocks = cycleBlocks;
    this.stableNeeded = stable;
    this.scoreMin = scoreMin;
    this.hint = 0;
    this.cyc = 0;
    this.lastLag = -1;
    this.stable = 0;
    this.locked = false;
    this.block = 0;
    this.moves = []; // { block, from, to, score } — telemetry for the report
  }

  /** Call once per block, AFTER pushReference+process. Returns the hint. */
  step(micBlock) {
    const a = this.aec;
    this.block++;
    const st = a.stats;
    const erleOk = (st.erleDb ?? 0) > 15;
    if (erleOk || !st.refActive || st.dtFrac > 0.5) return this.hint;

    const wide = !this.locked;
    if (wide && this.block % 4 !== 0) return this.hint; // wide scans cost ~8×
    const center = wide ? 1920 : this.hint;
    const half = wide ? 1920 : this.halfWidth;
    const s = a.alignmentScan(micBlock, { center, halfWidth: half });
    // Wide-mode cycles count SCANS (every 4th block), narrow count blocks:
    // both come out at ≈64 ms per evaluation cycle.
    if (++this.cyc >= (wide ? 6 : this.cycleBlocks)) {
      if (s.score > this.scoreMin && Math.abs(s.lag - this.hint) > 16) {
        if (s.lag === this.lastLag) this.stable++;
        else { this.stable = 1; this.lastLag = s.lag; }
        if (this.stable >= this.stableNeeded) {
          this.moves.push({ block: this.block, from: this.hint, to: s.lag, score: s.score });
          this.hint = s.lag;
          this.locked = true;
          this.stable = 0;
          this.lastLag = -1;
        }
      } else {
        this.stable = 0;
        this.lastLag = -1;
      }
      a.resetAlignmentScan();
      this.cyc = 0;
    }
    return this.hint;
  }
}

/**
 * Windowed ERLE series. Windows of `winMs`; a window whose mic power is under
 * −50 dBFS is a speech gap and reports null (the ratio mic/residual is
 * meaningless when both are numerical noise). Returns [{ tMs, erleDb|null }].
 */
export function erleSeries(mic, out, winMs = 50, gatePow = 1e-5) {
  const w = ms(winMs);
  const res = [];
  for (let a = 0; a + w <= out.length; a += w) {
    let m = 0;
    let r = 0;
    for (let i = a; i < a + w; i++) {
      m += mic[i] * mic[i];
      r += out[i] * out[i];
    }
    m /= w;
    r /= w;
    res.push({ tMs: ((a + w) / SR) * 1000, erleDb: m > gatePow ? 10 * Math.log10(m / Math.max(r, 1e-12)) : null });
  }
  return res;
}

/** Mean ERLE over the active windows in [fromMs, toMs). Null windows skipped. */
export function meanErle(series, fromMs, toMs) {
  const xs = series.filter((s) => s.tMs > fromMs && s.tMs <= toMs && s.erleDb !== null);
  if (!xs.length) return null;
  return xs.reduce((a, s) => a + s.erleDb, 0) / xs.length;
}

/** First window-end time (ms) at which ERLE ≥ bar, or null. */
export function timeToErle(series, barDb) {
  const hit = series.find((s) => s.erleDb !== null && s.erleDb >= barDb);
  return hit ? hit.tMs : null;
}
