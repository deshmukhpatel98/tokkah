import Foundation

// ── FUZZING, IN THE BINARY THAT SHIPS ────────────────────────────────────────
//
// Two surfaces, two harnesses, both built into `tk` so they run the exact code
// a call runs, with the exact compiler flags (bounds and overflow checks ON since
// 0.129.0, so an out-of-range read or a wrapped integer is a trap here and a
// finding, not a silent misread).
//
//  1. BEFORE AUTHENTICATION -- bytes anyone on the internet can send:
//     the STUN binding reply, the TURN allocate/refresh/permission replies
//     (success and error, with realm/nonce/ERROR-CODE attributes), the TURN
//     ChannelData unwrap, and the signed handshake. `--fuzz-parsers <secs>`
//     mutates valid templates and random garbage into each, in-process, as
//     fast as it can. Any trap is a crash, and the rig reads the crash report.
//
//  2. AFTER AUTHENTICATION -- bytes only the far end can send, but the far end
//     is a machine somebody else controls: the audio header and its lossless
//     payload, the video fragment header and reassembly, the time probe with
//     its three optional tails, the subtitle packet, the keyframe request.
//     `--fuzz-send <count>` turns THIS process into a hostile peer: once the
//     handshake completes it seals and sends `count` mutated packets of every
//     kind, interleaved with its real audio, at the real end under test.
//     tools/fuzz-check.sh runs the pair and requires the target to be alive,
//     still decrypting, and crash-free afterwards.
//
// Deterministic: the generator is seeded (default 1), so a finding reproduces
// with the same seed and count. Mutations: random field values inside valid
// layouts, truncation, extension to 1400 bytes, byte flips, and pure garbage.
enum Fuzz {
  // A small, fast, seedable generator (xorshift64*); `SystemRandomNumberGenerator`
  // cannot be seeded and a fuzzer that cannot replay its own finding is a rumour.
  struct Rng: RandomNumberGenerator {
    var s: UInt64
    init(seed: UInt64) { s = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
      s ^= s >> 12; s ^= s << 25; s ^= s >> 27
      return s &* 0x2545_F491_4F6C_DD1D
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
    mutating func chance(_ pct: Int) -> Bool { int(100) < pct }
  }

  static func put32(_ b: inout [UInt8], _ at: Int, _ v: UInt32) {
    withUnsafeBytes(of: v.littleEndian) { for i in 0..<4 where at + i < b.count { b[at + i] = $0[i] } }
  }
  static func put64(_ b: inout [UInt8], _ at: Int, _ v: UInt64) {
    withUnsafeBytes(of: v.littleEndian) { for i in 0..<8 where at + i < b.count { b[at + i] = $0[i] } }
  }
  static func put16(_ b: inout [UInt8], _ at: Int, _ v: UInt16) {
    withUnsafeBytes(of: v.littleEndian) { for i in 0..<2 where at + i < b.count { b[at + i] = $0[i] } }
  }

  /// Truncate, extend, flip. Applied to every template after its fields are set.
  static func mutate(_ p: inout [UInt8], _ r: inout Rng) {
    switch r.int(6) {
    case 0: if p.count > 1 { p.removeLast(r.int(p.count)) }              // truncate
    case 1: p.append(contentsOf: (0..<r.int(1400)).map { _ in r.byte() }) // extend
    case 2: for _ in 0..<(1 + r.int(8)) where !p.isEmpty { p[r.int(p.count)] = r.byte() }
    case 3: for _ in 0..<(1 + r.int(4)) where !p.isEmpty { p[r.int(p.count)] ^= UInt8(1 << r.int(8)) }
    case 4: if p.count > 4 { let k = r.int(p.count); p[k] = [0x00, 0xff, 0x7f, 0x80][r.int(4)] }
    default: break                                                        // fields only
    }
    if p.count > 1500 { p.removeLast(p.count - 1500) }
  }

  // ── templates: the post-authentication packets ─────────────────────────────

  static func audioPacket(_ r: inout Rng) -> [UInt8] {
    let frames = [32, 32, 32, r.int(70_000), 0, 1, 65535][r.int(7)]
    let pcm16 = r.chance(70), lp = r.chance(50)
    var p = [UInt8](repeating: 0, count: HDR)
    put32(&p, 0, MAGIC)
    put32(&p, 4, UInt32(truncatingIfNeeded: r.chance(20) ? r.next() : UInt64(r.int(100_000))))
    put64(&p, 8, r.chance(20) ? r.next() : UInt64(Clock.now()))
    put32(&p, 16, UInt32(frames & 0xffff) | (pcm16 ? 1 << 16 : 0) | (lp ? 1 << 17 : 0) | (r.chance(10) ? UInt32(r.int(1 << 14)) << 18 : 0))
    if lp {
      let m = r.chance(30) ? r.int(256) : r.int(80)
      p.append(UInt8(m))
      p.append(contentsOf: (0..<(r.chance(20) ? r.int(m + 1) : m)).map { _ in r.byte() })
      if r.chance(50) {   // the redundant block: capHost(8) + a second payload
        var c = [UInt8](repeating: 0, count: 8); put64(&c, 0, r.next()); p.append(contentsOf: c)
        let m2 = r.int(120); p.append(UInt8(m2)); p.append(contentsOf: (0..<r.int(m2 + 1)).map { _ in r.byte() })
      }
    } else {
      let want = min(1400, (frames & 0xffff) * (pcm16 ? 2 : 4))
      p.append(contentsOf: (0..<(r.chance(30) ? r.int(want + 1) : want)).map { _ in r.byte() })
    }
    mutate(&p, &r)
    return p
  }

  static func videoPacket(_ r: inout Rng, seq: inout Int32) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: VHDR)
    put32(&p, 0, VMAGIC)
    if r.chance(70) { seq += 1 }
    put32(&p, 4, r.chance(15) ? UInt32(truncatingIfNeeded: r.next()) : UInt32(bitPattern: seq))
    put64(&p, 8, r.chance(20) ? r.next() : UInt64(Clock.now()))
    let nfrag = [1, 2, 3, 4096, 4097, 0, 65535, r.int(20)][r.int(8)]
    let frag = [0, nfrag - 1, nfrag, nfrag + 1, 65535, r.int(20)][r.int(6)]
    put16(&p, 16, UInt16(truncatingIfNeeded: max(0, frag)))
    put16(&p, 18, UInt16(truncatingIfNeeded: max(0, nfrag)))
    put16(&p, 20, UInt16(truncatingIfNeeded: r.chance(30) ? 1 : r.int(4)))
    put16(&p, 22, UInt16(truncatingIfNeeded: [0, 1, VPAYLOAD, VPAYLOAD + 1, 65535, r.int(2000)][r.int(6)]))
    let body = [0, 1, VPAYLOAD, VPAYLOAD - 1, r.int(VPAYLOAD + 200)][r.int(5)]
    p.append(contentsOf: (0..<body).map { _ in r.byte() })
    mutate(&p, &r)
    return p
  }

  static func probePacket(_ r: inout Rng) -> [UInt8] {
    let n = [TPKT, TPKTX, TPKTY, TPKTZ, TPKTZ + 8, TPKT - 1, r.int(80)][r.int(7)]
    var p = [UInt8](repeating: 0, count: max(4, n))
    put32(&p, 0, TMAGIC)
    put32(&p, 4, UInt32(r.int(3)))
    for at in stride(from: 8, to: min(n, TPKT), by: 8) { put64(&p, at, r.chance(30) ? r.next() : UInt64(Clock.now())) }
    for at in stride(from: TPKT, to: n, by: 4) { put32(&p, at, r.chance(40) ? UInt32(truncatingIfNeeded: r.next()) : UInt32(r.int(1000))) }
    mutate(&p, &r)
    return p
  }

  static func subtitlePacket(_ r: inout Rng) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: 7)
    put32(&p, 0, SMAGIC)
    p[4] = r.byte()
    let n = [0, 1, 40, 65535, 1400, r.int(300)][r.int(6)]
    put16(&p, 5, UInt16(n))
    let body = r.chance(50) ? min(n, 1300) : r.int(300)
    p.append(contentsOf: (0..<body).map { _ in r.chance(70) ? UInt8(0x20 + r.int(90)) : r.byte() })
    mutate(&p, &r)
    return p
  }

  static func keyframePacket(_ r: inout Rng) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: [8, 4, 20][r.int(3)])
    put32(&p, 0, KMAGIC); mutate(&p, &r); return p
  }

  static func garbage(_ r: inout Rng) -> [UInt8] {
    var p = (0..<(1 + r.int(200))).map { _ in r.byte() }
    if r.chance(50) { put32(&p, 0, [MAGIC, VMAGIC, KMAGIC, TMAGIC, SMAGIC, HMAGIC, Crypto.HS_MAGIC, 0x544B_0004, 0x544B_00FF][r.int(9)]) }
    return p
  }

  /// One mutated post-authentication packet. Never a goodbye: the target
  /// hanging up on request is correct behaviour and would end the run.
  static func hostilePacket(_ r: inout Rng, vseq: inout Int32) -> [UInt8] {
    var p: [UInt8]
    switch r.int(10) {
    case 0, 1, 2: p = audioPacket(&r)
    case 3, 4, 5: p = videoPacket(&r, seq: &vseq)
    case 6: p = probePacket(&r)
    case 7: p = subtitlePacket(&r)
    case 8: p = keyframePacket(&r)
    default: p = garbage(&r)
    }
    // A bit flip turns 0x544B0007 into 0x544B0008, the goodbye, and the target
    // hanging up when its peer says so is correct -- it ended the first run of
    // this rig with a clean exit that read as a death. Never send one.
    if p.count >= 4, UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24 == BMAGIC { put32(&p, 0, KMAGIC) }
    return p
  }

  // ── templates: the pre-authentication packets ──────────────────────────────

  static func stunReply(_ r: inout Rng, txid: [UInt8]) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: 20)
    p[0] = r.chance(85) ? 0x01 : r.byte(); p[1] = r.chance(85) ? 0x01 : r.byte()
    p[4] = 0x21; p[5] = 0x12; p[6] = 0xA4; p[7] = 0x42
    for i in 0..<12 { p[8 + i] = txid[i] }
    var body = [UInt8]()
    func attr(_ t: UInt16, _ v: [UInt8]) {
      body.append(UInt8(t >> 8)); body.append(UInt8(t & 0xff))
      let l = r.chance(20) ? r.int(65536) : v.count
      body.append(UInt8(l >> 8)); body.append(UInt8(l & 0xff))
      body.append(contentsOf: v)
      let pad = (4 - v.count % 4) % 4
      body.append(contentsOf: [UInt8](repeating: 0, count: r.chance(10) ? 0 : pad))
    }
    for _ in 0..<r.int(5) {
      let t: UInt16 = [0x0020, 0x0001, 0x0016, 0x0009, 0x0014, 0x0015, 0x8022, UInt16(truncatingIfNeeded: r.next())][r.int(8)]
      var v = (0..<[8, 8, 4, 0, 20, 1, r.int(64)][r.int(7)]).map { _ in r.byte() }
      // Decided BEFORE the call: `attr` captures `r` inout, and a closure that
      // also reads `r` while `attr` runs is an exclusivity violation -- which the
      // first run of this harness found in itself ("Fatal access conflict").
      if v.count > 1, r.chance(70) { v[1] = 0x01 }
      attr(t, v)
    }
    let len = r.chance(20) ? r.int(65536) : body.count
    p[2] = UInt8(len >> 8); p[3] = UInt8(len & 0xff)
    p.append(contentsOf: body)
    mutate(&p, &r)
    return p
  }

  /// Runs every pre-authentication parser on mutated input for `seconds`. Returns
  /// the number of inputs tried. A trap does not return.
  static func parsers(seconds: Double, seed: UInt64) -> Int {
    var r = Rng(seed: seed)
    let txid = (0..<12).map { _ in r.byte() }
    let turn = TurnClient(host: "127.0.0.1", port: 3478, username: "u", credential: "c")
    var from = sockaddr_in()
    from.sin_family = sa_family_t(AF_INET); from.sin_port = UInt16(3478).bigEndian
    from.sin_addr.s_addr = inet_addr("127.0.0.1")
    let seedA = Data(repeating: 0x11, count: 32)
    let hs = Crypto(roomSalt: "fuzz-room", identitySeed: seedA)
    let hsPeer = Crypto(roomSalt: "fuzz-room", identitySeed: Data(repeating: 0x22, count: 32))
    let goodHs = hsPeer.handshakePacket(caps: CAP_PCM16 | CAP_PCM_LP)
    let asm = VideoAssembler()
    var vseq: Int32 = 0
    var lpcOut = [Int16](repeating: 0, count: Lpc.MAXN + 8)
    let t0 = Date()
    var n = 0
    var counts = [String: Int]()
    while Date().timeIntervalSince(t0) < seconds {
      n += 1
      switch r.int(6) {
      case 0:  // STUN binding reply
        var p = stunReply(&r, txid: txid)
        if p.count < 512 { p.append(contentsOf: [UInt8](repeating: 0, count: 512 - p.count)) }
        let m = Stun.parseBindingReply(p, min(p.count, 20 + r.int(492)), txid: txid)
        counts[m == nil ? "stun-nil" : "stun-mapped", default: 0] += 1
      case 1:  // TURN reply (success or error), through the same STUN grammar
        var p = stunReply(&r, txid: txid)
        if p.count < 2 { p = [0x01, 0x13] }
        if r.chance(50) { p[0] = 0x01; p[1] = [0x13, 0x03, 0x08][r.int(3)] }   // success classes
        if r.chance(30) { p[0] = 0x01; p[1] = 0x13 }                            // Allocate error
        if p.count < 1024 { p.append(contentsOf: [UInt8](repeating: 0, count: 1024 - p.count)) }
        let rep = turn.parse(p, min(p.count, 20 + r.int(1004)))
        counts[rep.ok ? "turn-ok" : (rep.errorCode != nil ? "turn-err" : "turn-none"), default: 0] += 1
      case 2:  // ChannelData unwrap
        var p = (0..<(r.int(40))).map { _ in r.byte() }
        if r.chance(50), p.count >= 4 { p[0] = 0x40; p[1] = 0x00 }
        let got = p.withUnsafeBufferPointer { bp -> Bool in
          guard let base = bp.baseAddress else { return false }
          return turn.unwrap(base, bp.count, from: from) != nil
        }
        counts[got ? "unwrap-yes" : "unwrap-no", default: 0] += 1
      case 3:  // the signed handshake, mutated from a valid one and from garbage
        var p = r.chance(60) ? goodHs : (0..<(r.int(200))).map { _ in r.byte() }
        if r.chance(80) { mutate(&p, &r) }
        let a = p.withUnsafeBufferPointer { bp -> Crypto.Adopt in
          guard let base = bp.baseAddress else { return .refused("empty") }
          return hs.adoptHandshake(base, bp.count)
        }
        switch a {
        case .adopted: counts["hs-adopted", default: 0] += 1
        case .unchanged: counts["hs-same", default: 0] += 1
        case .refused: counts["hs-refused", default: 0] += 1
        }
      case 4:  // video reassembly with the header fields the receive loop admits
        let p = videoPacket(&r, seq: &vseq)
        guard p.count >= VHDR else { continue }
        let seq = Int32(bitPattern: UInt32(p[4]) | UInt32(p[5]) << 8 | UInt32(p[6]) << 16 | UInt32(p[7]) << 24)
        let frag = Int(p[16]) | Int(p[17]) << 8, nfrag = Int(p[18]) | Int(p[19]) << 8
        let flags = Int(p[20]) | Int(p[21]) << 8, parLast = Int(p[22]) | Int(p[23]) << 8
        let isPar = flags & 1 == 1
        if nfrag < 1 || nfrag > 4096 || frag > nfrag || (!isPar && frag == nfrag) { counts["video-rejected", default: 0] += 1; continue }
        p.withUnsafeBufferPointer { bp in
          asm.take(seq: seq, frag: frag, nfrag: nfrag, capHost: 0, bytes: bp.baseAddress! + VHDR, n: bp.count - VHDR,
                   parity: isPar, parLastLen: parLast)
        }
        counts["video-taken", default: 0] += 1
      default: // lossless audio payload
        let m = r.int(300), frames = [32, 1, Lpc.MAXN, Lpc.MAXN + 1, r.int(200)][r.int(5)]
        let p = (0..<max(1, m)).map { _ in r.byte() }
        let ok = p.withUnsafeBufferPointer { bp in
          lpcOut.withUnsafeMutableBufferPointer { op in Lpc.decode(bp.baseAddress!, bp.count, frames, into: op.baseAddress!) }
        }
        counts[ok ? "lpc-ok" : "lpc-refused", default: 0] += 1
      }
    }
    let summary = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    fputs("fuzz: \(n) inputs in \(Int(seconds)) s (seed \(seed)): \(summary)\n", stderr)
    return n
  }

  /// The hostile peer. Called on its own thread once the key exists; sends
  /// `count` mutated packets through the real sealed send path, paced so the
  /// target's socket is not simply flooded (the question is parsing, not load).
  static func send(via wire: Wire, count: Int, seed: UInt64, perSecond: Int = 3000) {
    var r = Rng(seed: seed)
    var vseq: Int32 = 1
    var kinds = [String: Int]()
    let gap = UInt32(1_000_000 / max(1, perSecond))
    for i in 0..<count {
      let p = hostilePacket(&r, vseq: &vseq)
      guard p.count >= 4 else { continue }
      let magic = UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
      kinds[String(format: "%08x", magic), default: 0] += 1
      p.withUnsafeBufferPointer { bp in wire.rawSend(bp.baseAddress!, bp.count, .ctl) }
      if i % 10 == 0 { usleep(gap * 10) }
    }
    let top = kinds.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key):\($0.value)" }.joined(separator: " ")
    fputs("fuzz: sent \(count) hostile packets (seed \(seed)) -- \(top)\n", stderr)
  }
}
