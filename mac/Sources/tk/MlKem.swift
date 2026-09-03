import Foundation

// ── ML-KEM-768 (FIPS 203), in Swift, for the post-quantum half of the key ────
//
// WHY THIS FILE EXISTS. The call's key exchange is X25519. A recording of a
// call made today can be decrypted by whoever, one day, has a quantum computer
// large enough to break the curve -- "harvest now, decrypt later". FIPS 203's
// ML-KEM is the standard answer, and the two ends now agree on the call key
// TWICE: once with X25519, once with ML-KEM-768, and both would have to fall.
//
// WHY NOT A LIBRARY. CryptoKit has ML-KEM only from macOS 26; this app runs from
// macOS 14, and a key exchange that is post-quantum on some Macs and classical
// on others is a downgrade waiting to be negotiated. swift-crypto on Apple
// platforms is a thin shim over CryptoKit with the same floor. So the algorithm
// is here, in full, held byte-for-byte to BouncyCastle's implementation on the
// Android end (CryptoTest: same seed -> same key; a ciphertext from either end
// decapsulates on the other to the same secret) and to the FIPS 203 sizes.
//
// CONSTANT TIME, where it matters. Nothing here branches on, or indexes memory
// by, a secret: the NTT and its inverse are fixed sequences of Montgomery and
// Barrett reductions; sampling from the seed is public (the seed's expansion is
// what the standard makes public); the one secret comparison in decapsulation
// (the re-encryption check) is a constant-time byte compare followed by a
// constant-time select. `Int32` arithmetic throughout, no division by a secret.
//
// Cost, measured on this machine in --selftest-crypto: keygen, encaps and
// decaps each well under a millisecond, once per call, off the audio thread.
enum MlKem {
  static let K = 3, N = 256, Q: Int32 = 3329
  static let ETA1 = 2, ETA2 = 2, DU = 10, DV = 4
  static let PK_BYTES = 1184, SK_BYTES = 2400, CT_BYTES = 1088, SS_BYTES = 32, SEED_BYTES = 64

  // ── Keccak / SHA-3 / SHAKE ─────────────────────────────────────────────────
  struct Keccak {
    private static let RC: [UInt64] = [
      0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
      0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
      0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
      0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
      0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
      0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
    private static let ROT: [Int] = [1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44]
    private static let PI: [Int] = [10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1]
    var s = [UInt64](repeating: 0, count: 25)
    let rate: Int
    var pos = 0
    var squeezing = false
    let pad: UInt8
    init(rateBytes: Int, pad: UInt8) { rate = rateBytes; self.pad = pad }

    private mutating func permute() {
      var bc = [UInt64](repeating: 0, count: 5)
      for round in 0..<24 {
        for i in 0..<5 { bc[i] = s[i] ^ s[i + 5] ^ s[i + 10] ^ s[i + 15] ^ s[i + 20] }
        for i in 0..<5 {
          let t = bc[(i + 4) % 5] ^ ((bc[(i + 1) % 5] << 1) | (bc[(i + 1) % 5] >> 63))
          for j in stride(from: 0, to: 25, by: 5) { s[j + i] ^= t }
        }
        var t = s[1]
        for i in 0..<24 {
          let j = Keccak.PI[i]
          let tmp = s[j]
          s[j] = (t << UInt64(Keccak.ROT[i])) | (t >> UInt64(64 - Keccak.ROT[i]))
          t = tmp
        }
        for j in stride(from: 0, to: 25, by: 5) {
          for i in 0..<5 { bc[i] = s[j + i] }
          for i in 0..<5 { s[j + i] ^= (~bc[(i + 1) % 5]) & bc[(i + 2) % 5] }
        }
        s[0] ^= Keccak.RC[round]
      }
    }
    private mutating func xorByte(_ i: Int, _ b: UInt8) { s[i >> 3] ^= UInt64(b) << UInt64(8 * (i & 7)) }
    private func byte(_ i: Int) -> UInt8 { UInt8(truncatingIfNeeded: s[i >> 3] >> UInt64(8 * (i & 7))) }

    mutating func absorb(_ data: [UInt8]) {
      precondition(!squeezing)
      for b in data {
        xorByte(pos, b); pos += 1
        if pos == rate { permute(); pos = 0 }
      }
    }
    mutating func finish() {
      xorByte(pos, pad); xorByte(rate - 1, 0x80)
      permute(); pos = 0; squeezing = true
    }
    mutating func squeeze(_ n: Int) -> [UInt8] {
      if !squeezing { finish() }
      var out = [UInt8](); out.reserveCapacity(n)
      while out.count < n {
        if pos == rate { permute(); pos = 0 }
        out.append(byte(pos)); pos += 1
      }
      return out
    }
  }
  static func sha3_256(_ d: [UInt8]) -> [UInt8] { var k = Keccak(rateBytes: 136, pad: 0x06); k.absorb(d); return k.squeeze(32) }
  static func sha3_512(_ d: [UInt8]) -> [UInt8] { var k = Keccak(rateBytes: 72, pad: 0x06); k.absorb(d); return k.squeeze(64) }
  static func shake256(_ d: [UInt8], _ n: Int) -> [UInt8] { var k = Keccak(rateBytes: 136, pad: 0x1f); k.absorb(d); return k.squeeze(n) }
  static func shake128Stream(_ d: [UInt8]) -> Keccak { var k = Keccak(rateBytes: 168, pad: 0x1f); k.absorb(d); k.finish(); return k }
  /// J(s) = SHAKE256(s, 32), the implicit-rejection secret.
  static func J(_ d: [UInt8]) -> [UInt8] { shake256(d, 32) }
  /// PRF_eta(s, b) = SHAKE256(s || b, 64*eta)
  static func prf(_ s: [UInt8], _ b: UInt8, _ eta: Int) -> [UInt8] { shake256(s + [b], 64 * eta) }

  // ── Field arithmetic ───────────────────────────────────────────────────────
  static let QINV: Int32 = -3327      // q^-1 mod 2^16
  @inline(__always) static func montReduce(_ a: Int32) -> Int32 {
    let t = Int32(truncatingIfNeeded: Int16(truncatingIfNeeded: a &* QINV))
    return (a &- t &* Q) >> 16
  }
  @inline(__always) static func barrett(_ a: Int32) -> Int32 {
    let v: Int32 = ((1 << 26) + Q / 2) / Q
    let t = (v &* a &+ (1 << 25)) >> 26
    return a &- t &* Q
  }
  @inline(__always) static func fqmul(_ a: Int32, _ b: Int32) -> Int32 { montReduce(a &* b) }
  /// Canonical representative in [0, q) for any input in (-q, 2q), constant-time:
  /// add q if negative, then subtract q if still >= q. Barrett's output is
  /// CENTRED (it can be negative), so a plain "subtract q if >= q" is not enough
  /// -- the first build of this trapped on it converting to UInt16.
  @inline(__always) static func csubq(_ a: Int32) -> Int32 {
    var r = a &+ ((a >> 31) & Q)
    r = r &- Q; r &+= (r >> 31) & Q
    return r
  }

  static let ZETAS: [Int32] = {
    // Precomputed zetas in Montgomery form (Kyber/ML-KEM reference table).
    var z = [Int32](repeating: 0, count: 128)
    func bitrev7(_ i: Int) -> Int { var r = 0; for b in 0..<7 where i & (1 << b) != 0 { r |= 1 << (6 - b) }; return r }
    let mont: Int32 = 2285   // 2^16 mod q
    var pow: [Int32] = [1]
    for i in 1..<128 { pow.append(Int32((Int(pow[i - 1]) * 17) % Int(Q))) }
    for i in 0..<128 {
      var v = Int32((Int(pow[bitrev7(i)]) * Int(mont)) % Int(Q))
      if v > Q / 2 { v -= Q }
      z[i] = v
    }
    return z
  }()

  typealias Poly = [Int32]   // 256 coefficients

  static func ntt(_ pIn: Poly) -> Poly {
    var p = pIn
    var k = 1, len = 128
    while len >= 2 {
      var start = 0
      while start < 256 {
        let zeta = ZETAS[k]; k += 1
        for j in start..<(start + len) {
          let t = fqmul(zeta, p[j + len])
          p[j + len] = p[j] &- t
          p[j] = p[j] &+ t
        }
        start += 2 * len
      }
      len >>= 1
    }
    for i in 0..<256 { p[i] = barrett(p[i]) }
    return p
  }

  static func invntt(_ pIn: Poly) -> Poly {
    var p = pIn
    var k = 127, len = 2
    let f: Int32 = 1441   // mont^2 / 128
    while len <= 128 {
      var start = 0
      while start < 256 {
        let zeta = ZETAS[k]; k -= 1
        for j in start..<(start + len) {
          let t = p[j]
          p[j] = barrett(t &+ p[j + len])
          p[j + len] = fqmul(zeta, p[j + len] &- t)
        }
        start += 2 * len
      }
      len <<= 1
    }
    for i in 0..<256 { p[i] = fqmul(p[i], f) }
    return p
  }

  static func basemul(_ a: Poly, _ b: Poly) -> Poly {
    var r = Poly(repeating: 0, count: 256)
    for i in 0..<64 {
      let z = ZETAS[64 + i]
      func bm(_ a0: Int32, _ a1: Int32, _ b0: Int32, _ b1: Int32, _ zeta: Int32) -> (Int32, Int32) {
        var r0 = fqmul(a1, b1); r0 = fqmul(r0, zeta); r0 &+= fqmul(a0, b0)
        var r1 = fqmul(a0, b1); r1 &+= fqmul(a1, b0)
        return (r0, r1)
      }
      let (r0, r1) = bm(a[4 * i], a[4 * i + 1], b[4 * i], b[4 * i + 1], z)
      let (r2, r3) = bm(a[4 * i + 2], a[4 * i + 3], b[4 * i + 2], b[4 * i + 3], -z)
      r[4 * i] = r0; r[4 * i + 1] = r1; r[4 * i + 2] = r2; r[4 * i + 3] = r3
    }
    return r
  }
  static func toMont(_ p: Poly) -> Poly { let f: Int32 = 1353; return p.map { fqmul($0, f) } }   // 2^32 mod q
  static func add(_ a: Poly, _ b: Poly) -> Poly { var r = a; for i in 0..<256 { r[i] = a[i] &+ b[i] }; return r }
  static func sub(_ a: Poly, _ b: Poly) -> Poly { var r = a; for i in 0..<256 { r[i] = a[i] &- b[i] }; return r }
  static func reduce(_ a: Poly) -> Poly { a.map { barrett($0) } }

  // ── Sampling ───────────────────────────────────────────────────────────────
  /// SampleNTT from an XOF stream (rejection sampling on public data).
  static func sampleNTT(_ rho: [UInt8], _ i: UInt8, _ j: UInt8) -> Poly {
    var xof = shake128Stream(rho + [i, j])
    var p = Poly(repeating: 0, count: 256)
    var n = 0
    while n < 256 {
      let b = xof.squeeze(3)
      let d1 = Int32(b[0]) | (Int32(b[1] & 0x0f) << 8)
      let d2 = Int32(b[1] >> 4) | (Int32(b[2]) << 4)
      if d1 < Q { p[n] = d1; n += 1 }
      if d2 < Q, n < 256 { p[n] = d2; n += 1 }
    }
    return p
  }
  /// CBD_eta on 64*eta bytes (eta = 2 here).
  static func cbd2(_ buf: [UInt8]) -> Poly {
    var p = Poly(repeating: 0, count: 256)
    for i in 0..<32 {
      let t = UInt32(buf[4 * i]) | UInt32(buf[4 * i + 1]) << 8 | UInt32(buf[4 * i + 2]) << 16 | UInt32(buf[4 * i + 3]) << 24
      var d = t & 0x5555_5555
      d &+= (t >> 1) & 0x5555_5555
      for j in 0..<8 {
        let a = Int32((d >> UInt32(4 * j)) & 3)
        let b = Int32((d >> UInt32(4 * j + 2)) & 3)
        p[8 * i + j] = a - b
      }
    }
    return p
  }

  // ── Encoding ───────────────────────────────────────────────────────────────
  static func byteEncode12(_ p: Poly) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 384)
    for i in 0..<128 {
      let t0 = UInt16(csubq(p[2 * i])), t1 = UInt16(csubq(p[2 * i + 1]))
      out[3 * i] = UInt8(t0 & 0xff)
      out[3 * i + 1] = UInt8((t0 >> 8) | (t1 << 4) & 0xff)
      out[3 * i + 2] = UInt8(t1 >> 4)
    }
    return out
  }
  static func byteDecode12(_ b: ArraySlice<UInt8>) -> Poly {
    var p = Poly(repeating: 0, count: 256)
    let s = b.startIndex
    for i in 0..<128 {
      p[2 * i] = Int32(b[s + 3 * i]) | (Int32(b[s + 3 * i + 1] & 0x0f) << 8)
      p[2 * i + 1] = Int32(b[s + 3 * i + 1] >> 4) | (Int32(b[s + 3 * i + 2]) << 4)
    }
    return p
  }
  /// Compress_d then ByteEncode_d, d in {1, 4, 10}.
  static func compress(_ p: Poly, _ d: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 32 * d)
    var acc: UInt64 = 0, bits = 0, o = 0
    for c in p {
      let x = UInt64(csubq(c))
      // round(2^d * x / q) mod 2^d, in integers
      let v = ((x << UInt64(d)) + UInt64(Q) / 2) / UInt64(Q) & ((1 << UInt64(d)) - 1)
      acc |= v << UInt64(bits); bits += d
      while bits >= 8 { out[o] = UInt8(acc & 0xff); o += 1; acc >>= 8; bits -= 8 }
    }
    return out
  }
  static func decompress(_ b: ArraySlice<UInt8>, _ d: Int) -> Poly {
    var p = Poly(repeating: 0, count: 256)
    var acc: UInt64 = 0, bits = 0, i = b.startIndex
    for n in 0..<256 {
      while bits < d { acc |= UInt64(b[i]) << UInt64(bits); i += 1; bits += 8 }
      let v = acc & ((1 << UInt64(d)) - 1); acc >>= UInt64(d); bits -= d
      // round(q * v / 2^d)
      p[n] = Int32((v * UInt64(Q) + (1 << UInt64(d - 1))) >> UInt64(d))
    }
    return p
  }

  // ── K-PKE ──────────────────────────────────────────────────────────────────
  struct PkeKeys { var ek: [UInt8]; var dk: [UInt8] }

  static func expandA(_ rho: [UInt8], transposed: Bool) -> [[Poly]] {
    var a = [[Poly]](repeating: [Poly](repeating: [], count: K), count: K)
    for i in 0..<K { for j in 0..<K {
      a[i][j] = transposed ? sampleNTT(rho, UInt8(i), UInt8(j)) : sampleNTT(rho, UInt8(j), UInt8(i))
    } }
    return a
  }

  static func pkeKeyGen(_ d: [UInt8]) -> PkeKeys {
    let g = sha3_512(d + [UInt8(K)])
    let rho = Array(g[0..<32]), sigma = Array(g[32..<64])
    let a = expandA(rho, transposed: false)
    var s = [Poly](), e = [Poly]()
    var n: UInt8 = 0
    for _ in 0..<K { s.append(ntt(cbd2(prf(sigma, n, ETA1)))); n += 1 }
    for _ in 0..<K { e.append(ntt(cbd2(prf(sigma, n, ETA1)))); n += 1 }
    var t = [Poly]()
    for i in 0..<K {
      var acc = Poly(repeating: 0, count: 256)
      for j in 0..<K { acc = add(acc, basemul(a[i][j], s[j])) }
      acc = toMont(reduce(acc))
      t.append(reduce(add(acc, e[i])))
    }
    var ek = [UInt8](); for i in 0..<K { ek += byteEncode12(t[i]) }; ek += rho
    var dk = [UInt8](); for i in 0..<K { dk += byteEncode12(s[i]) }
    return PkeKeys(ek: ek, dk: dk)
  }

  static func pkeEncrypt(_ ek: [UInt8], _ m: [UInt8], _ r: [UInt8]) -> [UInt8] {
    var t = [Poly]()
    for i in 0..<K { t.append(byteDecode12(ek[(384 * i)..<(384 * i + 384)])) }
    let rho = Array(ek[(384 * K)..<(384 * K + 32)])
    let at = expandA(rho, transposed: true)
    var y = [Poly](), e1 = [Poly]()
    var n: UInt8 = 0
    for _ in 0..<K { y.append(ntt(cbd2(prf(r, n, ETA1)))); n += 1 }
    for _ in 0..<K { e1.append(cbd2(prf(r, n, ETA2))); n += 1 }
    let e2 = cbd2(prf(r, n, ETA2))
    var u = [Poly]()
    for i in 0..<K {
      var acc = Poly(repeating: 0, count: 256)
      for j in 0..<K { acc = add(acc, basemul(at[i][j], y[j])) }
      u.append(reduce(add(invntt(reduce(acc)), e1[i])))
    }
    var tv = Poly(repeating: 0, count: 256)
    for j in 0..<K { tv = add(tv, basemul(t[j], y[j])) }
    let mu = decompress(m[0..<32], 1)
    let v = reduce(add(add(invntt(reduce(tv)), e2), mu))
    var c = [UInt8]()
    for i in 0..<K { c += compress(u[i], DU) }
    c += compress(v, DV)
    return c
  }

  static func pkeDecrypt(_ dk: [UInt8], _ c: [UInt8]) -> [UInt8] {
    var u = [Poly]()
    for i in 0..<K { u.append(ntt(decompress(c[(320 * i)..<(320 * i + 320)], DU))) }
    let v = decompress(c[(320 * K)..<(320 * K + 128)], DV)
    var s = [Poly]()
    for i in 0..<K { s.append(byteDecode12(dk[(384 * i)..<(384 * i + 384)])) }
    var acc = Poly(repeating: 0, count: 256)
    for i in 0..<K { acc = add(acc, basemul(s[i], u[i])) }
    let w = reduce(sub(v, invntt(reduce(acc))))
    return compress(w, 1)
  }

  // ── ML-KEM ─────────────────────────────────────────────────────────────────
  /// The decapsulation key is kept as its 64-byte seed (d || z) and expanded on
  /// use; the full 2400-byte form is never stored.
  struct PrivateKey {
    let seed: [UInt8]         // d || z
    let ek: [UInt8]           // encapsulation key, 1184 B
    private let dkPke: [UInt8]
    private let h: [UInt8]    // H(ek)

    init(seed: [UInt8]) {
      precondition(seed.count == SEED_BYTES)
      self.seed = seed
      let kp = pkeKeyGen(Array(seed[0..<32]))
      ek = kp.ek; dkPke = kp.dk; h = sha3_256(kp.ek)
    }
    init() {
      var s = [UInt8](repeating: 0, count: SEED_BYTES)
      s.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, SEED_BYTES, $0.baseAddress!) }
      self.init(seed: s)
    }
    var publicKey: [UInt8] { ek }

    /// Decaps. Never fails on a bad ciphertext: returns the implicit-rejection
    /// secret instead, in constant time, exactly as FIPS 203 Algorithm 18 says.
    func decapsulate(_ c: [UInt8]) -> [UInt8]? {
      guard c.count == CT_BYTES else { return nil }
      let z = Array(seed[32..<64])
      let mPrime = pkeDecrypt(dkPke, c)
      let g = sha3_512(mPrime + h)
      let kPrime = Array(g[0..<32]), rPrime = Array(g[32..<64])
      let kBar = J(z + c)
      let cPrime = pkeEncrypt(ek, mPrime, rPrime)
      // Constant-time compare and select.
      var diff: UInt8 = 0
      for i in 0..<CT_BYTES { diff |= c[i] ^ cPrime[i] }
      let mask = UInt8(truncatingIfNeeded: (Int(diff) &- 1) >> 8)   // 0xff when equal, 0x00 when not
      var out = [UInt8](repeating: 0, count: 32)
      for i in 0..<32 { out[i] = (kPrime[i] & mask) | (kBar[i] & ~mask) }
      return out
    }
  }

  struct Encaps { let ciphertext: [UInt8]; let sharedSecret: [UInt8] }

  /// Encaps to a peer's encapsulation key. nil when the key is not a valid
  /// ML-KEM-768 key (wrong length, or coefficients that do not round-trip --
  /// FIPS 203's modulus check).
  static func encapsulate(_ ek: [UInt8], m mIn: [UInt8]? = nil) -> Encaps? {
    guard ek.count == PK_BYTES else { return nil }
    // Modulus check: ByteEncode12(ByteDecode12(ek)) == ek for the t part.
    for i in 0..<K {
      let slice = ek[(384 * i)..<(384 * i + 384)]
      if byteEncode12(byteDecode12(slice)) != Array(slice) { return nil }
    }
    var m = mIn ?? [UInt8](repeating: 0, count: 32)
    if mIn == nil { m.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) } }
    let g = sha3_512(m + sha3_256(ek))
    let k = Array(g[0..<32]), r = Array(g[32..<64])
    let c = pkeEncrypt(ek, m, r)
    return Encaps(ciphertext: c, sharedSecret: k)
  }
}
