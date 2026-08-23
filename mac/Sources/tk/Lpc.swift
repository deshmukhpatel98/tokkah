import Foundation

// ── Lossless compression of the voice payload ────────────────────────────────
//
// The audio packet carried 64 bytes of raw 16-bit PCM inside 136 bytes of wire
// (20 header, 24 crypto, 28 IP/UDP), so 53% of the bandwidth was not audio. And
// raw PCM at 48 kHz is enormously redundant: the signal is sampled far above the
// frequencies speech contains, so successive samples are nearly equal and third
// differences are tiny. Measured over 90 s of real speech in both directions:
// **2.85x**, 64 bytes -> 22.4, which takes the wire to 94 bytes and the call from
// 1.64 to 1.14 Mbps.
//
// It is LOSSLESS, which is the whole point. A speech codec would cut far more and
// cost both quality and algorithmic delay; this returns the same samples bit for
// bit, with no lookahead of any kind, so it is free of latency by construction
// rather than merely cheap. The test is correspondingly absolute: for every input,
// decode(encode(x)) == x, or the build is wrong.
//
// EVERY PACKET IS INDEPENDENT. Seeding the predictor from the previous packet's
// tail would save another ~6 bytes and make one lost packet corrupt its
// successors -- trading a bounded loss for an unbounded one. Containment is worth
// more than six bytes.
//
// Fixed-order prediction plus Rice coding: the classic FLAC/Shorten subset. No
// adaptive filter, no divides, no allocation on the audio path.
enum Lpc {
  /// Widest packet this encodes. Bounds the fixed-size scratch below.
  static let MAXN = 256
  /// Worst case output for `n` samples: mode byte plus a plain copy.
  @inline(__always) static func bound(_ n: Int) -> Int { 1 + n * 2 }

  /// Rice coding needs unsigned residuals, so signed ones are zigzagged: small
  /// magnitudes of either sign become small unsigned values.
  @inline(__always) private static func zig(_ v: Int32) -> UInt32 {
    UInt32(bitPattern: (v << 1) ^ (v >> 31))
  }
  @inline(__always) private static func unzig(_ u: UInt32) -> Int32 {
    Int32(bitPattern: u >> 1) ^ -Int32(bitPattern: u & 1)
  }

  /// The p-th order difference of `s` at `i`, which needs `i >= p`. Written out
  /// rather than iterated so both sides read the same four lines and there is no
  /// in-place buffer to get wrong.
  @inline(__always) private static func residual(_ s: UnsafePointer<Int16>, _ i: Int, _ p: Int) -> Int32 {
    let a = Int32(s[i])
    switch p {
    case 0: return a
    case 1: return a - Int32(s[i - 1])
    case 2: return a - 2 * Int32(s[i - 1]) + Int32(s[i - 2])
    default: return a - 3 * Int32(s[i - 1]) + 3 * Int32(s[i - 2]) - Int32(s[i - 3])
    }
  }

  /// The same prediction, rearranged to recover the sample from its residual.
  @inline(__always) private static func predict(_ s: UnsafePointer<Int16>, _ i: Int, _ p: Int) -> Int32 {
    switch p {
    case 0: return 0
    case 1: return Int32(s[i - 1])
    case 2: return 2 * Int32(s[i - 1]) - Int32(s[i - 2])
    default: return 3 * Int32(s[i - 1]) - 3 * Int32(s[i - 2]) + Int32(s[i - 3])
    }
  }

  /// Compress `n` int16 samples into `out`, returning bytes written.
  ///
  /// Never larger than `bound(n)`: if coding would not beat a plain copy, it
  /// emits the copy. So no input can be made worse by turning this on.
  static func encode(_ src: UnsafePointer<Int16>, _ n: Int,
                     into out: UnsafeMutablePointer<UInt8>) -> Int {
    guard n > 4, n <= MAXN else { return raw(src, n, into: out) }
    var u = [UInt32](repeating: 0, count: MAXN)
    var bestBits = Int.max, bestP = 0, bestK = 0
    return u.withUnsafeMutableBufferPointer { ub -> Int in
      let uz = ub.baseAddress!
      // Order 0 is the samples themselves, and it wins on near-silence where
      // differencing only amplifies dither.
      for p in 0...3 {
        let cnt = n - p
        for i in p..<n { uz[i - p] = zig(residual(src, i, p)) }
        // All sixteen parameters, because the search is 32 shifts each and the
        // packet budget is microseconds. Optimal beats clever here.
        for k in 0...15 {
          var bits = cnt * (1 + k)
          for i in 0..<cnt { bits += Int(uz[i] >> UInt32(k)) }
          // COMPARE LIKE WITH LIKE. The first version tested bare coding bits
          // against a running best that already included `p * 16 + 8`, and since
          // that overhead is larger than the ~cnt bits each step of k adds, every
          // higher k looked better than the last -- so the search climbed to k=15
          // every time and the result never beat a plain copy. Silence coded to
          // 65 bytes.
          let total = bits + p * 16 + 8      // warm-up samples, plus the mode byte
          if total >= bestBits { continue }
          bestBits = total
          bestP = p; bestK = k
        }
      }
      guard bestBits != Int.max, (bestBits + 7) / 8 < bound(n) else { return raw(src, n, into: out) }

      let p = bestP, k = bestK
      out[0] = UInt8(p & 3) | UInt8((k & 31) << 2)
      var w = BitWriter(out: out + 1)
      for i in 0..<p { w.put(UInt32(UInt16(bitPattern: src[i])), 16) }
      for i in p..<n {
        let z = zig(residual(src, i, p))
        w.putUnary(Int(z >> UInt32(k)))
        if k > 0 { w.put(z & ((1 << UInt32(k)) - 1), k) }
      }
      return 1 + w.flush()
    }
  }

  /// Bit 7 of the mode byte means "the rest is a plain copy".
  @inline(__always) private static func raw(_ src: UnsafePointer<Int16>, _ n: Int,
                                            into out: UnsafeMutablePointer<UInt8>) -> Int {
    out[0] = 0x80
    memcpy(out + 1, src, n * 2)
    return 1 + n * 2
  }

  /// Expand `len` bytes back into exactly `n` samples.
  ///
  /// Returns false on anything malformed. This parses data that arrived over the
  /// network, so every read is bounded and a corrupt packet fails rather than
  /// walking off the end of a buffer.
  static func decode(_ src: UnsafePointer<UInt8>, _ len: Int, _ n: Int,
                     into out: UnsafeMutablePointer<Int16>) -> Bool {
    guard len >= 1, n > 0, n <= MAXN else { return false }
    if src[0] & 0x80 != 0 {
      guard len >= 1 + n * 2 else { return false }
      memcpy(out, src + 1, n * 2)
      return true
    }
    let p = Int(src[0] & 3), k = Int((src[0] >> 2) & 31)
    guard k <= 15, n > p else { return false }
    var r = BitReader(src: src + 1, len: len - 1)
    for i in 0..<p {
      guard let v = r.get(16) else { return false }
      out[i] = Int16(bitPattern: UInt16(truncatingIfNeeded: v))
    }
    for i in p..<n {
      guard let q = r.getUnary() else { return false }
      var z = UInt32(q) << UInt32(k)
      if k > 0 {
        guard let low = r.get(k) else { return false }
        z |= low
      }
      // truncatingIfNeeded, not an assert: for valid data the sum is exactly the
      // original Int16, and for corrupt data it must wrap quietly rather than trap
      // on the audio thread.
      out[i] = Int16(truncatingIfNeeded: unzig(z) + predict(out, i, p))
    }
    return true
  }
}

/// MSB-first bit writer over a caller-owned buffer. The hot path does not bounds
/// check: callers size the buffer with `Lpc.bound`, and the encoder rejects any
/// result that would not beat a plain copy, so it cannot run past it.
struct BitWriter {
  private let out: UnsafeMutablePointer<UInt8>
  private var byte = 0, acc: UInt64 = 0, bits = 0
  init(out: UnsafeMutablePointer<UInt8>) { self.out = out }
  @inline(__always) mutating func put(_ v: UInt32, _ n: Int) {
    guard n > 0 else { return }
    let mask: UInt64 = n >= 32 ? 0xffff_ffff : (1 << UInt64(n)) - 1
    acc = (acc << UInt64(n)) | (UInt64(v) & mask)
    bits += n
    while bits >= 8 {
      bits -= 8
      out[byte] = UInt8(truncatingIfNeeded: acc >> UInt64(bits))
      byte += 1
    }
  }
  /// `q` zeros then a one. Split so a long quotient cannot overflow the
  /// accumulator -- rare, but a packet of noise will find it.
  @inline(__always) mutating func putUnary(_ q: Int) {
    var left = q
    while left >= 32 { put(0, 32); left -= 32 }
    put(1, left + 1)
  }
  @inline(__always) mutating func flush() -> Int {
    if bits > 0 {
      out[byte] = UInt8(truncatingIfNeeded: acc << UInt64(8 - bits))
      byte += 1
      bits = 0
    }
    return byte
  }
}

/// MSB-first reader, every read bounded.
struct BitReader {
  private let src: UnsafePointer<UInt8>
  private let len: Int
  private var pos = 0
  init(src: UnsafePointer<UInt8>, len: Int) { self.src = src; self.len = len }
  @inline(__always) private mutating func bit() -> Int? {
    let idx = pos >> 3
    guard idx < len else { return nil }
    let b = (Int(src[idx]) >> (7 - (pos & 7))) & 1
    pos += 1
    return b
  }
  @inline(__always) mutating func get(_ n: Int) -> UInt32? {
    var v: UInt32 = 0
    for _ in 0..<n {
      guard let b = bit() else { return nil }
      v = (v << 1) | UInt32(b)
    }
    return v
  }
  @inline(__always) mutating func getUnary() -> Int? {
    var q = 0
    while true {
      guard let b = bit() else { return nil }
      if b == 1 { return q }
      q += 1
      if q > 1 << 16 { return nil }
    }
  }
}
