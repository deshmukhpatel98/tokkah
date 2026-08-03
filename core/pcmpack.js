/**
 * Lossless compression of one PCM audio frame. 384 int24 samples in, a shorter
 * byte string out, and the original samples back — bit for bit, always.
 *
 * WHY, and why this is not a byte-count optimisation:
 *   The measured SCTP ceiling is ~0.4 Mbps PER ASSOCIATION at RTT 80 / 5% loss
 *   (MEASURED.md, "The second cause"), and the lane offers 1.5 Mbps + 30% FEC.
 *   At 10% loss the ceiling falls to ~0.28 Mbps per association, so 1.95 Mbps
 *   needs ~7 stripes and we ship 6 — which is exactly why 10% loss still
 *   conceals 9-10% after the stripe was widened. Cutting the RATE is therefore
 *   the lever, and lossless compression is the only way to cut it that leaves
 *   "truly lossless audio" literally true.
 *
 * HOW: FLAC's core, and deliberately only that.
 *   1. A fixed-order linear predictor (orders 0-4, binomial weights). No
 *      coefficients on the wire — the decoder runs the same recurrence.
 *   2. Rice coding of the residual: k low bits verbatim, the rest in unary.
 *   3. A verbatim escape when prediction loses, which BOUNDS the worst case at
 *      1152 B of payload. That bound is the property the datagram budget needs;
 *      a codec that can expand would put us back over 1160 B on the bad frame.
 *
 *   Computed LPC was measured and rejected: at 384 samples, order-8 coefficients
 *   cost 16 B and lose to the fixed predictors outright (760 vs 744 B on a tonal
 *   fixture, 727 vs 693 on speech); best-of-both bought 0-2%. Fixed predictors
 *   are both simpler and better here, so there is no tradeoff to make.
 *
 * MEASURED ratios (testbed/pcmpack.mjs, mean bytes of 1152):
 *   speech 0.60, natural sound 0.66, tonal sweep 0.65, white noise 0.94.
 *   White noise is incompressible by construction (lag-1 autocorrelation 0.001)
 *   and is the floor, not a failure. The ratio is insensitive to whether the
 *   source is genuinely 24-bit: dithering the low 8 bits changed it by <0.3%,
 *   because Rice already spends its low k bits verbatim.
 *
 * RS is unaffected. Parity keeps a fixed 1152 B symbol — compressed payloads are
 * zero-padded to 1152 for the RS group only. Rice decoding is self-terminating
 * at 384 samples, so trailing pad is ignored and a repaired frame needs no
 * length field. That keeps parity messages exactly as they are today.
 */

export const PACK_SAMPLES = 384;
const VERBATIM = 7; // order field value meaning "no prediction, raw int24"

// ── bit writer / reader ─────────────────────────────────────────────────────
// Bytes are filled MSB-first. The reader mirrors it exactly; any disagreement
// here is a silent audio corruption rather than an error, which is why the
// round-trip test in testbed/pcmpack.mjs asserts sample equality and not just
// length.
// Deliberately byte-at-a-time. A wider accumulator invites the bug where
// `acc * 2^take` crosses 2^32 and `>>> 0` silently wraps — and a wrapped bit
// writer produces audio that decodes to something, just not what was sent.
class BitW {
  constructor(buf) { this.b = buf; this.i = 0; this.cur = 0; this.free = 8; }
  put(v, bits) {
    while (bits > 0) {
      const take = bits < this.free ? bits : this.free;
      const chunk = (v >>> (bits - take)) & ((1 << take) - 1);
      this.cur = (this.cur << take) | chunk;
      this.free -= take; bits -= take;
      if (this.free === 0) { this.b[this.i++] = this.cur & 0xff; this.cur = 0; this.free = 8; }
    }
  }
  unary(q) { while (q >= 8) { this.put(0, 8); q -= 8; } this.put(1, q + 1); }
  flush() { if (this.free < 8) { this.b[this.i++] = (this.cur << this.free) & 0xff; this.cur = 0; this.free = 8; } return this.i; }
}
class BitR {
  constructor(buf) { this.b = buf; this.i = 0; this.cur = 0; this.left = 0; }
  get(bits) {
    let v = 0;
    while (bits > 0) {
      if (this.left === 0) { this.cur = this.i < this.b.length ? this.b[this.i++] : 0; this.left = 8; }
      const take = bits < this.left ? bits : this.left;
      v = v * (1 << take) + ((this.cur >>> (this.left - take)) & ((1 << take) - 1));
      this.left -= take; bits -= take;
    }
    return v;
  }
  unary() { let q = 0; for (;;) { if (this.get(1)) return q; if (++q > 1 << 20) return q; } }
}

// ── fixed predictors ────────────────────────────────────────────────────────
// s[] is Int32Array of PACK_SAMPLES signed 24-bit values. Warm-up samples
// (i < order) are coded verbatim as order-0 so the decoder has no special case
// beyond the same bound.
function predict(s, i, order) {
  if (i < order) return 0;
  const a = s[i - 1] | 0, b = order >= 2 ? s[i - 2] | 0 : 0;
  const c = order >= 3 ? s[i - 3] | 0 : 0, d = order >= 4 ? s[i - 4] | 0 : 0;
  return order === 1 ? a
    : order === 2 ? 2 * a - b
    : order === 3 ? 3 * a - 3 * b + c
    : 4 * a - 6 * b + 4 * c - d;
}

const zig = (v) => (v << 1) ^ (v >> 31);
const unzig = (u) => (u >>> 1) ^ -(u & 1);

// PARTITIONED Rice, and warm-up samples as literals. Both exist for the same
// reason, learned by measuring: one Rice parameter for the whole frame is
// hostage to its worst samples. The first `order` samples have no predecessors,
// so their residual IS the raw sample — two such samples forced k up to ~23 for
// all 384, and a perfect ramp (order-2 residual identically zero) fell out to
// the verbatim escape at 1153 B. Partitions then handle the same problem in the
// small: a speech onset inside one 8 ms frame no longer taxes the quiet half.
const PARTS = 4;                       // 96 samples each
const PSIZE = PACK_SAMPLES / PARTS;

// ── wasted bits ─────────────────────────────────────────────────────────────
// FLAC's field of the same name, and the single largest saving in this file.
//
// The capture worklet converts float32 to int24 with `x * 8388608`. When the
// capture chain is effectively 16-bit — which is every consumer microphone and
// every fixture in this repo — each sample is an exact multiple of 256 and the
// bottom 8 bits of all 384 samples are zero. Rice coding CANNOT exploit that:
// it spends its k low bits verbatim, so 8 known-zero bits per sample cost
// 8 x 384 / 8 = 384 B per frame of literal zeros. Measured on the shipped coder
// (testbed/pcmwasted.mjs), that is 49.7% of the payload: 768 -> 386 B mean over
// six fixtures, 0.768 -> 0.386 Mbps of lane.
//
// Two docstrings in this repo previously disagreed about this. pcmpack.mjs said
// "the bottom 8 bits are ZERO, and Rice coding eats them for free"; that is
// wrong, and the number above is what it costs. The claim below it, that
// dithering the low 8 bits changes the ratio by <0.3%, is right and is the SAME
// fact seen from the other side: zeros and noise cost the same, because both are
// paid at full price.
//
// The shift is measured per frame, never assumed, so this is not a bit-depth
// negotiation and cannot be wrong about the device. A genuine 24-bit noise floor
// has no common trailing zeros, the shift comes out 0, and the output is
// byte-identical to before — verified as the control arm of that harness. So
// there is no tradeoff here and no condition under which it costs anything.
//
// It costs zero header bytes: the frame header is `order << 5` and had 5 bits
// spare, which is exactly enough for a shift of 0..24.
const shifted = new Int32Array(PACK_SAMPLES);
function wastedShift(s, on) {
  if (!on) return 0;
  let m = 0;
  for (let i = 0; i < PACK_SAMPLES; i++) m |= s[i];
  if (m === 0) return 0; // digital silence: no common factor to pull out
  // Trailing zeros of the OR are the MINIMUM trailing zeros over all samples,
  // which is the most any of them can share. Negative values work unchanged:
  // -256 is 0xFFFFFF00, and `>> 8` then `<< 8` restores it exactly.
  let sh = 0;
  while (((m >> sh) & 1) === 0) sh++;
  return sh > 24 ? 24 : sh;
}

// Exact bit cost of coding res[lo..hi) with parameter k.
function partCost(res, lo, hi, k) {
  let bits = 0;
  for (let i = lo; i < hi; i++) {
    const q = zig(res[i]) >>> k;
    if (q > 1 << 15) return Infinity;  // pathological; verbatim will win
    bits += q + 1 + k;
  }
  return bits;
}

// k is ~log2 of the mean magnitude; search a small window around that estimate
// rather than all 24 values, which keeps the encoder at a few hundred thousand
// ops per frame instead of a few million.
function bestK(res, lo, hi) {
  let sum = 0;
  for (let i = lo; i < hi; i++) sum += zig(res[i]);
  const mean = sum / (hi - lo);
  const est = mean < 1 ? 0 : Math.floor(Math.log2(mean));
  let bk = 0, bb = Infinity;
  for (let k = Math.max(0, est - 2); k <= Math.min(23, est + 2); k++) {
    const b = partCost(res, lo, hi, k);
    if (b < bb) { bb = b; bk = k; }
  }
  return { k: bk, bits: bb };
}

/**
 * Compress one frame. Returns the number of bytes written into `out`.
 * `out` must have room for 1 + PACK_SAMPLES * 3 bytes.
 *
 * Layout: header byte = order(3 bits, 7 = verbatim) | spare(5)
 *         then `order` warm-up samples, 24 bits each
 *         then PARTS x [ k (5 bits), Rice codes for that partition ]
 */
export function packFrame(s, out, wasted = true) {
  const res = new Int32Array(PACK_SAMPLES);
  const ks = new Int32Array(PARTS);
  let bestOrder = -1, bestBits = Infinity;
  const bestKs = new Int32Array(PARTS);

  // Everything below codes `src`, not `s`. The shift is applied to a scratch
  // copy rather than in place because the caller reuses its input buffer.
  const sh = wastedShift(s, wasted);
  let src = s;
  if (sh) {
    for (let i = 0; i < PACK_SAMPLES; i++) shifted[i] = s[i] >> sh;
    src = shifted;
  }

  for (let order = 0; order <= 4; order++) {
    for (let i = order; i < PACK_SAMPLES; i++) res[i] = src[i] - predict(src, i, order);
    let bits = 8 + order * 24;
    for (let p = 0; p < PARTS; p++) {
      // Partition 0 starts after the warm-up literals; the rest are whole.
      const lo = p === 0 ? order : p * PSIZE, hi = (p + 1) * PSIZE;
      const r = bestK(res, lo, hi);
      ks[p] = r.k;
      bits += 5 + r.bits;
      if (bits >= bestBits) { bits = Infinity; break; }
    }
    if (bits < bestBits) { bestBits = bits; bestOrder = order; bestKs.set(ks); }
  }

  const verbatimBytes = 1 + PACK_SAMPLES * 3;
  if (bestOrder < 0 || 1 + Math.ceil((bestBits - 8) / 8) >= verbatimBytes) {
    // The escape stores the SHIFTED samples and carries the shift too. Storing
    // `s` here instead would decode silently wrong: the reader has no way to
    // know which domain the bytes are in beyond this header byte.
    out[0] = (VERBATIM << 5) | sh;
    for (let i = 0, o = 1; i < PACK_SAMPLES; i++, o += 3) {
      const v = src[i];
      out[o] = v & 0xff; out[o + 1] = (v >> 8) & 0xff; out[o + 2] = (v >> 16) & 0xff;
    }
    return verbatimBytes;
  }

  out[0] = (bestOrder << 5) | sh;
  const w = new BitW(out.subarray(1));
  for (let i = 0; i < bestOrder; i++) w.put(src[i] & 0xffffff, 24);
  for (let p = 0; p < PARTS; p++) {
    const k = bestKs[p];
    w.put(k, 5);
    const lo = p === 0 ? bestOrder : p * PSIZE, hi = (p + 1) * PSIZE;
    for (let i = lo; i < hi; i++) {
      const u = zig(src[i] - predict(src, i, bestOrder));
      w.unary(u >>> k);
      if (k) w.put(u & ((1 << k) - 1), k);
    }
  }
  return 1 + w.flush();
}

/**
 * Decompress into `s` (Int32Array of PACK_SAMPLES). Reads only as much of `buf`
 * as the codes require, so zero padding added for the RS group is ignored and a
 * repaired frame needs no length field.
 */
export function unpackFrame(buf, s) {
  const order = buf[0] >>> 5;
  // Clamped, not trusted. A repaired frame's header is only as good as the RS
  // group that produced it, and an unclamped 31 would left-shift a 24-bit sample
  // past the sign bit — turning one bad header into a full-scale click, the
  // loudest possible way for this codec to fail.
  const sh = Math.min(24, buf[0] & 31);
  if (order === VERBATIM) {
    for (let i = 0, o = 1; i < PACK_SAMPLES; i++, o += 3) {
      const v = buf[o] | (buf[o + 1] << 8) | (buf[o + 2] << 16);
      s[i] = (v & 0x800000) ? (v | ~0xffffff) : v;
    }
  } else {
    const r = new BitR(buf.subarray(1));
    for (let i = 0; i < order; i++) {
      const v = r.get(24);
      s[i] = (v & 0x800000) ? (v | ~0xffffff) : v;
    }
    for (let p = 0; p < PARTS; p++) {
      const k = r.get(5);
      const lo = p === 0 ? order : p * PSIZE, hi = (p + 1) * PSIZE;
      for (let i = lo; i < hi; i++) {
        const q = r.unary();
        const u = k ? q * (1 << k) + r.get(k) : q;
        s[i] = (unzig(u) + predict(s, i, order)) | 0;
      }
    }
  }
  // LAST, and for both paths. The predictor recurrence above runs in the coded
  // domain, so scaling a sample before its successors are reconstructed would
  // corrupt every sample that follows it.
  if (sh) for (let i = 0; i < PACK_SAMPLES; i++) s[i] <<= sh;
}
