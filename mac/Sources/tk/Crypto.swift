import CryptoKit
import Foundation

// ── Encryption on the wire ───────────────────────────────────────────────────
//
// X25519 + ML-KEM-768 over the media socket, AES-256-GCM per packet. Measured on
// this machine at the real packet size: **0.7 us to seal 276 bytes**, against a
// 1333 us audio deadline. So this runs on the capture callback without a thread
// hop, and the latency cost is nothing.
//
// TWO KEYS, ONE PER DIRECTION, and this is not decoration. Both ends derive the
// same shared secret, so if both used one key and a counter starting at zero,
// every packet number would be a NONCE REUSE -- and nonce reuse under GCM does
// not degrade the cipher, it breaks it outright and leaks the authentication key.
// HKDF gives two keys from the one secret and the ends agree on who uses which by
// comparing public keys, which needs no extra message.
//
// ── THE HANDSHAKE IS SIGNED, AND HYBRID (v3) ─────────────────────────────────
//
// v1 exchanged bare X25519 keys "authenticated" by the room code -- which travels
// to the callee THROUGH the signalling server, so the one party positioned to sit
// in the middle was the one party guaranteed to hold the secret. v2 (0.128) signed
// the ephemeral key with each install's Ed25519 identity, the key that signs every
// ring, and checked it against the identity this end expected. v3 (0.130) keeps
// all of that and adds a second, post-quantum key agreement, ML-KEM-768 (FIPS
// 203), so that a recording made today cannot be opened by a quantum computer
// built later: BOTH X25519 and ML-KEM would have to fall.
//
// Three packets, none over 1200 bytes (the datagram size every path carries):
//
//   HS3  magic | eph(32) | caps(4) | id(32) | kemHash(32) | sig(64)          168 B
//        sig = Ed25519(id) over "kin-hs-v3|" room "|" eph caps kemHash
//   HSK  magic | eph(32) | half(1) | 592 bytes of the ML-KEM public key       629 B
//        two of these carry the 1184-byte key; SHA-256 of the whole must equal
//        the kemHash that was SIGNED in HS3, so the halves are unsigned but bound
//   HSC  magic | eph(32) | ct(1088) | sig(64)                                1188 B
//        sig = Ed25519(id) over "kin-hs-v3c|" room "|" ephSender ephRecipient ct
//
// Roles fall out of the two ephemeral keys, with no extra message: whoever's
// sorts lower is A and owns the ML-KEM key that gets used; the other, B,
// encapsulates to it. Flow: both beat HS3 + HSK every 300 ms until keyed. B, on
// holding A's verified HS3 and both halves, encapsulates, derives the call key,
// and beats HSC (until it has opened a packet from A, which proves A has the key
// too). A, on a verified HSC, decapsulates and derives. One round trip when A's
// packets land first; one and a half when B's do. Nothing on the media path.
//
// The call key is HKDF(X25519 secret || ML-KEM secret) with the whole transcript
// -- both ephemerals, both identities, the ML-KEM key's hash and the ciphertext's
// -- in the info, so a key belongs to exactly one exchange between exactly two
// identities. Everything that was refused in v2 is still refused: an identity this
// end did not expect, a second identity mid-call, an unsigned or v2 handshake
// (counted hs_old), replays (2048-packet window), and anything before a key.
//
// ── WHAT THIS PROTECTS AGAINST, precisely ────────────────────────────────────
//
//  - a passive listener on any hop, now or with a quantum computer later: yes.
//  - the signalling server, or anyone who compromises it: sees who calls whom;
//    cannot read, alter, or sit inside a call between two ends that expect each
//    other's identity -- which is every Kin-to-Kin call after the first.
//  - a stranger reaching the port: cannot re-key, inject, or end a call.
//  - a first call between two strangers through a server that also lies about
//    their keys: the residual. The eight-character code differs on the two
//    screens; the pin after the call closes it.
final class Crypto {
  /// v3 magics. 0x0006 (v1, unsigned) and 0x0009 (v2, classical) are REFUSED and
  /// counted as `hsOld`, so a build from before this change is visible in the
  /// beat rather than silently connecting.
  static let HS_MAGIC: UInt32 = 0x544B_000A    // HS3: the signed offer
  static let HSK_MAGIC: UInt32 = 0x544B_000B   // HSK: half of the ML-KEM public key
  static let HSC_MAGIC: UInt32 = 0x544B_000C   // HSC: the signed ciphertext
  static let HS_V2_MAGIC: UInt32 = 0x544B_0009
  static let HS_LEN = 4 + 32 + 4 + 32 + 32 + 64      // 168
  static let HSK_HALF = MlKem.PK_BYTES / 2            // 592
  static let HSK_LEN = 4 + 32 + 1 + HSK_HALF          // 629
  static let HSC_LEN = 4 + 32 + MlKem.CT_BYTES + 64   // 1188
  static let HS_CONTEXT = "kin-hs-v3|"
  static let HSC_CONTEXT = "kin-hs-v3c|"

  private let mine: Curve25519.KeyAgreement.PrivateKey
  private let kem: MlKem.PrivateKey
  private let idKey: Curve25519.Signing.PrivateKey
  private let room: String
  private let salt: Data
  /// The identity this end expects on the other side, or nil for first-use.
  private let expected: Data?
  /// Vectors only: a fixed m for the encapsulation makes the ciphertext reproducible.
  private let fixedKemM: [UInt8]?
  private var sendKey: SymmetricKey?
  private var recvKey: SymmetricKey?
  private var sendCtr: UInt64 = 0
  // rawSend is reached from THREE threads. A raced counter would hand two packets
  // the same nonce, and under GCM a repeated nonce forfeits the cipher. The seal
  // is ~0.7 us, so one lock costs nothing. `open` and every handshake state change
  // take the same lock.
  private let lock = NSLock()

  // ── replay window ──────────────────────────────────────────────────────────
  static let replayWindow = 2048
  private var rxHigh: UInt64 = 0
  private var rxBits = [UInt64](repeating: 0, count: Crypto.replayWindow / 64)

  // ── the peer, as far as it has proved itself ───────────────────────────────
  private(set) var established = false
  private(set) var peerKeyHex = ""      // peer's ephemeral X25519 key (verified HS3)
  private(set) var peerIdHex = ""       // peer's Ed25519 identity
  private var peerEph = Data()
  private var peerId = Data()
  private var peerKemHash = Data()
  private(set) var peerCaps: UInt32 = 0
  private var peerKemHalves: [[UInt8]?] = [nil, nil]
  private var peerKemPk: [UInt8]?
  /// B's ciphertext, once made: re-sent on every beat until A proves it has the key.
  private var myCt: [UInt8]?
  private var iAmA = false
  /// True when the peer's identity matched a key this end already expected.
  private(set) var pinned = false
  private(set) var sealed = 0, opened = 0, openFails = 0
  private(set) var replayDrops = 0, preKeyDrops = 0, preKeyRx = 0, plaintextRx = 0
  private(set) var hsBadSig = 0, hsWrongId = 0, hsIdChanged = 0, hsOld = 0, hsFlood = 0, hsWeak = 0
  private(set) var hsKemHashBad = 0, hsCtRefused = 0, hsCtSeen = 0

  // ── a budget on signature checks ───────────────────────────────────────────
  private var verifyTokens = 20.0
  private var verifyRefill = Date()

  var myPublic: Data { mine.publicKey.rawRepresentation }
  var myIdentity: Data { idKey.publicKey.rawRepresentation }
  var myKemPk: [UInt8] { kem.publicKey }
  var peerIdentityB64: String? {
    guard !peerIdHex.isEmpty, let d = Crypto.hex(peerIdHex) else { return nil }
    return d.base64EncodedString()
  }
  /// The peer has proved it holds the call key: at least one packet opened.
  var peerConfirmed: Bool { opened > 0 }

  // ── THE CODE YOU READ ALOUD ─────────────────────────────────────────────────
  static let codeAlphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
  var safetyCode: String? {
    guard established, !peerKeyHex.isEmpty, !peerIdHex.isEmpty else { return nil }
    let parts = [Crypto.hexString(myPublic), peerKeyHex, Crypto.hexString(myIdentity), peerIdHex].sorted()
    let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
    let out = digest.prefix(8).map { String(Crypto.codeAlphabet[Int($0 & 31)]) }.joined()
    return String(out.prefix(4)) + " " + String(out.suffix(4))
  }

  init(roomSalt: String, identitySeed: Data, expectedPeer: Data? = nil,
       fixedPrivate: Data? = nil, fixedKemSeed: [UInt8]? = nil, fixedKemM: [UInt8]? = nil) {
    room = roomSalt
    salt = Data(("tk-v3-" + roomSalt).utf8)
    if let f = fixedPrivate, let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: f) { mine = k }
    else { mine = Curve25519.KeyAgreement.PrivateKey() }
    kem = fixedKemSeed.map { MlKem.PrivateKey(seed: $0) } ?? MlKem.PrivateKey()
    if let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: identitySeed) { idKey = k }
    else {
      fputs("crypto: identity seed did not parse -- this call uses a throwaway identity\n", stderr)
      idKey = Curve25519.Signing.PrivateKey()
    }
    expected = (expectedPeer?.count == 32) ? expectedPeer : nil
    self.fixedKemM = fixedKemM
  }

  // ── the packets this end sends ─────────────────────────────────────────────

  private var hsCache: (caps: UInt32, pkt: [UInt8])?
  /// HS3, signed once per (key, caps) and reused.
  func handshakePacket(caps: UInt32) -> [UInt8] {
    lock.lock(); defer { lock.unlock() }
    if let c = hsCache, c.caps == caps { return c.pkt }
    var out = [UInt8](repeating: 0, count: Crypto.HS_LEN)
    out.withUnsafeMutableBytes { $0.storeBytes(of: Crypto.HS_MAGIC.littleEndian, toByteOffset: 0, as: UInt32.self) }
    myPublic.copyBytes(to: &out[4], count: 32)
    out.withUnsafeMutableBytes { $0.storeBytes(of: caps.littleEndian, toByteOffset: 36, as: UInt32.self) }
    myIdentity.copyBytes(to: &out[40], count: 32)
    let kh = Crypto.kemHash(myKemPk)
    kh.copyBytes(to: &out[72], count: 32)
    let msg = Crypto.signedMessage(room: room, eph: myPublic, caps: caps, kemHash: kh)
    if let sig = try? idKey.signature(for: msg) { sig.copyBytes(to: &out[104], count: 64) }
    hsCache = (caps, out)
    return out
  }

  /// The two HSK halves, built once.
  private lazy var kemHalves: [[UInt8]] = (0..<2).map { h in
    var out = [UInt8](repeating: 0, count: Crypto.HSK_LEN)
    out.withUnsafeMutableBytes { $0.storeBytes(of: Crypto.HSK_MAGIC.littleEndian, toByteOffset: 0, as: UInt32.self) }
    myPublic.copyBytes(to: &out[4], count: 32)
    out[36] = UInt8(h)
    let pk = myKemPk
    for i in 0..<Crypto.HSK_HALF { out[37 + i] = pk[h * Crypto.HSK_HALF + i] }
    return out
  }

  private var hscCache: [UInt8]?
  /// Everything this end should send on a handshake beat, in order: HS3, the two
  /// key halves, and -- when this end is B and has encapsulated -- the ciphertext.
  /// Once the peer has proved it holds the key, only HS3 (the liveness beat).
  func handshakePackets(caps: UInt32) -> [[UInt8]] {
    var out = [handshakePacket(caps: caps)]
    lock.lock()
    let done = established && opened > 0
    let ct = myCt
    lock.unlock()
    if done { return out }
    out += kemHalves
    if let ct { out.append(hscPacket(ct)) }
    return out
  }

  private func hscPacket(_ ct: [UInt8]) -> [UInt8] {
    if let c = hscCache { return c }
    var out = [UInt8](repeating: 0, count: Crypto.HSC_LEN)
    out.withUnsafeMutableBytes { $0.storeBytes(of: Crypto.HSC_MAGIC.littleEndian, toByteOffset: 0, as: UInt32.self) }
    myPublic.copyBytes(to: &out[4], count: 32)
    for i in 0..<MlKem.CT_BYTES { out[36 + i] = ct[i] }
    let msg = Crypto.ctMessage(room: room, sender: myPublic, recipient: peerEph, ct: ct)
    if let sig = try? idKey.signature(for: msg) { sig.copyBytes(to: &out[36 + MlKem.CT_BYTES], count: 64) }
    hscCache = out
    return out
  }

  static func kemHash(_ pk: [UInt8]) -> Data { Data(SHA256.hash(data: Data(pk))) }
  static func signedMessage(room: String, eph: Data, caps: UInt32, kemHash: Data) -> Data {
    var m = Data((HS_CONTEXT + room + "|").utf8)
    m.append(eph)
    withUnsafeBytes(of: caps.littleEndian) { m.append(contentsOf: $0) }
    m.append(kemHash)
    return m
  }
  static func ctMessage(room: String, sender: Data, recipient: Data, ct: [UInt8]) -> Data {
    var m = Data((HSC_CONTEXT + room + "|").utf8)
    m.append(sender); m.append(recipient); m.append(contentsOf: ct)
    return m
  }
  static func caps(of p: UnsafePointer<UInt8>, _ n: Int) -> UInt32 {
    guard n >= HS_LEN else { return 0 }
    return (p + 36).withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) }
  }

  enum Adopt {
    /// Same peer, same key: a keepalive beat. Nothing changed.
    case unchanged
    /// A new verified offer was adopted (the address may be adopted; reply with our beat).
    case adopted
    /// The call key now exists on this end.
    case keyed
    /// Refused, and already counted under the field named.
    case refused(String)
  }

  private func spendVerify() -> Bool {
    let now = Date()
    verifyTokens = min(20, verifyTokens + now.timeIntervalSince(verifyRefill) * 20)
    verifyRefill = now
    if verifyTokens < 1 { hsFlood += 1; return false }
    verifyTokens -= 1
    return true
  }

  /// HS3: the signed offer. Rules 1-3 of the header.
  func adoptHandshake(_ p: UnsafePointer<UInt8>, _ n: Int) -> Adopt {
    guard n >= Crypto.HS_LEN else { return .refused("short") }
    let eph = Data(bytes: p + 4, count: 32)
    let caps = Crypto.caps(of: p, n)
    let id = Data(bytes: p + 40, count: 32)
    let kh = Data(bytes: p + 72, count: 32)
    let sig = Data(bytes: p + 104, count: 64)
    let ephHex = Crypto.hexString(eph), idHex = Crypto.hexString(id)
    if ephHex == peerKeyHex && idHex == peerIdHex { return .unchanged }
    guard spendVerify() else { return .refused("flood") }
    guard let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: id),
          pk.isValidSignature(sig, for: Crypto.signedMessage(room: room, eph: eph, caps: caps, kemHash: kh))
    else { hsBadSig += 1; return .refused("bad signature") }
    if let e = expected, e != id { hsWrongId += 1; return .refused("wrong identity") }
    if expected == nil, !peerIdHex.isEmpty, idHex != peerIdHex { hsIdChanged += 1; return .refused("identity changed") }
    // A low-order X25519 point yields an all-zero secret; refuse it now rather
    // than at derivation.
    guard let ppk = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: eph),
          let secret = try? mine.sharedSecretFromKeyAgreement(with: ppk),
          secret.withUnsafeBytes({ $0.contains { $0 != 0 } })
    else { hsWeak += 1; return .refused("weak key") }

    // A NEW peer offer: everything derived from the old one is gone.
    lock.lock()
    peerEph = eph; peerId = id; peerKemHash = kh; peerCaps = caps
    peerKeyHex = ephHex; peerIdHex = idHex
    peerKemHalves = [nil, nil]; peerKemPk = nil
    myCt = nil; hscCache = nil
    iAmA = myPublic.lexicographicallyPrecedes(eph)
    established = false; sendKey = nil; recvKey = nil
    pinned = expected != nil
    lock.unlock()
    return .adopted
  }

  /// HSK: half of the peer's ML-KEM key. Accepted only for the eph this end has a
  /// verified offer from, and only if the assembled key hashes to what was signed.
  func takeKemHalf(_ p: UnsafePointer<UInt8>, _ n: Int) -> Adopt {
    guard n >= Crypto.HSK_LEN else { return .refused("short") }
    let eph = Data(bytes: p + 4, count: 32)
    guard !peerEph.isEmpty, eph == peerEph else { return .refused("unknown eph") }
    let h = Int(p[36])
    guard h == 0 || h == 1 else { return .refused("bad half") }
    lock.lock()
    if peerKemPk != nil { lock.unlock(); return .unchanged }
    peerKemHalves[h] = Array(UnsafeBufferPointer(start: p + 37, count: Crypto.HSK_HALF))
    guard let a = peerKemHalves[0], let b = peerKemHalves[1] else { lock.unlock(); return .unchanged }
    let pk = a + b
    guard Crypto.kemHash(pk) == peerKemHash else {
      peerKemHalves = [nil, nil]; hsKemHashBad += 1; lock.unlock()
      return .refused("kem key does not match the signed hash")
    }
    peerKemPk = pk
    let amA = iAmA
    lock.unlock()
    // B, holding A's key, encapsulates now and derives.
    if !amA {
      guard let enc = MlKem.encapsulate(pk, m: fixedKemM) else { hsKemHashBad += 1; return .refused("kem key invalid") }
      lock.lock(); myCt = enc.ciphertext; hscCache = nil; lock.unlock()
      derive(kemSecret: enc.sharedSecret, ct: enc.ciphertext)
      return .keyed
    }
    return .adopted
  }

  /// HSC: B's ciphertext for A's key. Signed by the identity that made the offer.
  func takeCiphertext(_ p: UnsafePointer<UInt8>, _ n: Int) -> Adopt {
    guard n >= Crypto.HSC_LEN else { return .refused("short") }
    let sender = Data(bytes: p + 4, count: 32)
    guard !peerEph.isEmpty, sender == peerEph else { return .refused("unknown eph") }
    lock.lock()
    let amA = iAmA, done = established
    lock.unlock()
    guard amA else { return .refused("not the decapsulator") }
    if done { return .unchanged }
    let ct = Array(UnsafeBufferPointer(start: p + 36, count: MlKem.CT_BYTES))
    let sig = Data(bytes: p + 36 + MlKem.CT_BYTES, count: 64)
    guard spendVerify() else { return .refused("flood") }
    guard let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: peerId),
          pk.isValidSignature(sig, for: Crypto.ctMessage(room: room, sender: sender, recipient: myPublic, ct: ct))
    else { hsCtRefused += 1; return .refused("ciphertext bad signature") }
    hsCtSeen += 1
    guard let ss = kem.decapsulate(ct) else { hsCtRefused += 1; return .refused("ciphertext bad length") }
    derive(kemSecret: ss, ct: ct)
    return .keyed
  }

  private func derive(kemSecret: [UInt8], ct: [UInt8]) {
    guard let ppk = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEph),
          let secret = try? mine.sharedSecretFromKeyAgreement(with: ppk) else { return }
    let aEph = iAmA ? myPublic : peerEph, bEph = iAmA ? peerEph : myPublic
    let aId = iAmA ? myIdentity : peerId, bId = iAmA ? peerId : myIdentity
    let aKemHash = iAmA ? Crypto.kemHash(myKemPk) : peerKemHash
    let transcript = aEph + bEph + aId + bId + aKemHash + Data(SHA256.hash(data: Data(ct)))
    var ikm = secret.withUnsafeBytes { Data($0) }
    ikm.append(contentsOf: kemSecret)
    let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt)
    let ka = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("a2b".utf8) + transcript, outputByteCount: 32)
    let kb = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("b2a".utf8) + transcript, outputByteCount: 32)
    lock.lock()
    sendKey = iAmA ? ka : kb
    recvKey = iAmA ? kb : ka
    sendCtr = 0; rxHigh = 0
    for i in rxBits.indices { rxBits[i] = 0 }
    established = true
    lock.unlock()
  }

  /// A v1 or v2 handshake arrived. Refused, always; counted.
  func noteOldHandshake() { hsOld += 1 }

  // ── the packets ────────────────────────────────────────────────────────────

  func seal(_ p: UnsafePointer<UInt8>, _ n: Int, into out: UnsafeMutablePointer<UInt8>) -> Int? {
    lock.lock(); defer { lock.unlock() }
    guard let k = sendKey else { return nil }
    sendCtr += 1
    let ctr = sendCtr
    var nb = [UInt8](repeating: 0, count: 12)
    withUnsafeBytes(of: ctr.littleEndian) { for (i, b) in $0.enumerated() { nb[4 + i] = b } }
    guard let nonce = try? AES.GCM.Nonce(data: Data(nb)),
          let box = try? AES.GCM.seal(UnsafeBufferPointer(start: p, count: n), using: k, nonce: nonce)
    else { return nil }
    let ct = box.ciphertext, tag = box.tag
    withUnsafeBytes(of: ctr.littleEndian) { memcpy(out, $0.baseAddress!, 8) }
    ct.copyBytes(to: out + 8, count: ct.count)
    tag.copyBytes(to: out + 8 + ct.count, count: tag.count)
    sealed += 1
    return 8 + ct.count + tag.count
  }

  func open(_ p: UnsafePointer<UInt8>, _ n: Int, into out: UnsafeMutablePointer<UInt8>) -> Int? {
    lock.lock(); defer { lock.unlock() }
    guard let k = recvKey, n > 8 + 16 else { return nil }
    var ctr: UInt64 = 0
    withUnsafeMutableBytes(of: &ctr) { memcpy($0.baseAddress!, p, 8) }
    ctr = UInt64(littleEndian: ctr)
    guard ctr > 0 else { replayDrops += 1; return nil }
    if ctr <= rxHigh {
      let back = rxHigh - ctr
      if back >= UInt64(Crypto.replayWindow) { replayDrops += 1; return nil }
      if rxBits[Int(ctr >> 6) % rxBits.count] & (1 << UInt64(ctr & 63)) != 0 { replayDrops += 1; return nil }
    }
    var nb = [UInt8](repeating: 0, count: 12)
    withUnsafeBytes(of: ctr.littleEndian) { for (i, b) in $0.enumerated() { nb[4 + i] = b } }
    let bodyLen = n - 8 - 16
    guard let nonce = try? AES.GCM.Nonce(data: Data(nb)) else { return nil }
    let ct = Data(bytes: p + 8, count: bodyLen)
    let tag = Data(bytes: p + 8 + bodyLen, count: 16)
    guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag),
          let pt = try? AES.GCM.open(box, using: k) else { openFails += 1; return nil }
    if ctr > rxHigh {
      let jump = ctr - rxHigh
      if jump >= UInt64(Crypto.replayWindow) { for i in rxBits.indices { rxBits[i] = 0 } }
      else { var c = rxHigh + 1; while c <= ctr { rxBits[Int(c >> 6) % rxBits.count] &= ~(1 << UInt64(c & 63)); c += 1 } }
      rxHigh = ctr
    }
    rxBits[Int(ctr >> 6) % rxBits.count] |= (1 << UInt64(ctr & 63))
    pt.copyBytes(to: out, count: pt.count)
    opened += 1
    return pt.count
  }

  func notePlaintextRx() { plaintextRx += 1 }
  func notePreKeyDrop() { preKeyDrops += 1 }
  func notePreKeyRx() { preKeyRx += 1 }

  func beatFields(into f: inout [String: Any]) {
    f["crypt"] = established ? 1 : 0
    f["crypt_v"] = 3
    f["crypt_pq"] = 1
    f["crypt_bad"] = openFails
    f["crypt_pinned"] = pinned ? 1 : 0
    f["crypt_expected"] = expected != nil ? 1 : 0
    if !peerEph.isEmpty { f["crypt_role"] = iAmA ? "a" : "b" }
    if replayDrops > 0 { f["replay_drop"] = replayDrops }
    if preKeyDrops > 0 { f["prekey_drop"] = preKeyDrops }
    if preKeyRx > 0 { f["prekey_rx"] = preKeyRx }
    if plaintextRx > 0 { f["plaintext_rx"] = plaintextRx }
    if hsBadSig > 0 { f["hs_bad_sig"] = hsBadSig }
    if hsWrongId > 0 { f["hs_wrong_id"] = hsWrongId }
    if hsIdChanged > 0 { f["hs_id_changed"] = hsIdChanged }
    if hsOld > 0 { f["hs_old"] = hsOld }
    if hsFlood > 0 { f["hs_flood"] = hsFlood }
    if hsWeak > 0 { f["hs_weak"] = hsWeak }
    if hsKemHashBad > 0 { f["hs_kem_bad"] = hsKemHashBad }
    if hsCtRefused > 0 { f["hs_ct_refused"] = hsCtRefused }
  }

  var summary: String {
    if established {
      return "encrypted (aes-256-gcm, x25519 + ml-kem-768, signed handshake, role \(iAmA ? "A" : "B"), peer id \(peerIdHex.prefix(8))… "
        + (pinned ? "verified" : "first use") + ", code \(safetyCode ?? "-"))"
        + (replayDrops > 0 ? ", \(replayDrops) replays refused" : "")
        + (plaintextRx > 0 ? ", \(plaintextRx) plaintext refused" : "")
    }
    var why = ""
    if hsOld > 0 { why += " -- the other end is on an old build (\(hsOld) pre-v3 handshakes refused)" }
    if hsWrongId > 0 { why += " -- \(hsWrongId) handshakes from the WRONG identity refused" }
    if hsBadSig > 0 { why += " -- \(hsBadSig) handshakes with bad signatures refused" }
    if hsKemHashBad > 0 { why += " -- \(hsKemHashBad) ML-KEM keys did not match their signed hash" }
    if !peerEph.isEmpty { why += " -- offer verified, waiting for the \(iAmA ? "ciphertext" : "key halves")" }
    return "NO KEY YET -- nothing sent or read" + why
  }

  // ── helpers ────────────────────────────────────────────────────────────────
  static func hexString(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
  static func hex(_ s: String) -> Data? {
    guard s.count % 2 == 0 else { return nil }
    var out = Data(capacity: s.count / 2)
    var i = s.startIndex
    while i < s.endIndex {
      let j = s.index(i, offsetBy: 2)
      guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
      out.append(b); i = j
    }
    return out
  }

  // ── SELF-TEST, and the vectors the Android port is held to ─────────────────
  static func selftest(vectorsTo path: String?) -> Bool {
    var ok = true
    func check(_ c: Bool, _ what: String) { fputs("  \(c ? "ok  " : "FAIL") \(what)\n", stderr); if !c { ok = false } }
    let room = "sunset-otter-42"
    let seedA = Data(repeating: 0x11, count: 32), seedB = Data(repeating: 0x22, count: 32)
    let ephA = Data(repeating: 0x01, count: 32), ephB = Data(repeating: 0x02, count: 32)
    let kemA = [UInt8](repeating: 0x41, count: 64), kemB = [UInt8](repeating: 0x42, count: 64)
    let mB = [UInt8](repeating: 0x24, count: 32)
    let caps = CAP_PCM16 | CAP_PCM_LP
    func feed(_ c: Crypto, _ pkts: [[UInt8]]) -> [Adopt] {
      pkts.map { p in p.withUnsafeBufferPointer { bp -> Adopt in
        let base = bp.baseAddress!, n = bp.count
        let magic = UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
        switch magic {
        case HS_MAGIC: return c.adoptHandshake(base, n)
        case HSK_MAGIC: return c.takeKemHalf(base, n)
        case HSC_MAGIC: return c.takeCiphertext(base, n)
        default: return .refused("magic")
        } } }
    }
    func isKeyed(_ a: [Adopt]) -> Bool { a.contains { if case .keyed = $0 { return true }; return false } }
    func refusedCount(_ a: [Adopt]) -> Int { a.filter { if case .refused = $0 { return true }; return false }.count }
    func mk(_ seed: Data, _ eph: Data, _ kem: [UInt8], expected: Data? = nil, m: [UInt8]? = nil) -> Crypto {
      Crypto(roomSalt: room, identitySeed: seed, expectedPeer: expected, fixedPrivate: eph, fixedKemSeed: kem, fixedKemM: m)
    }

    // 1. A's packets land first (one round trip).
    var a = mk(seedA, ephA, kemA), b = mk(seedB, ephB, kemB, m: mB)
    var rb = feed(b, a.handshakePackets(caps: caps))          // B: offer + halves -> encapsulates, keyed
    check(isKeyed(rb) && b.established, "B keys on A's offer and halves (encapsulates)")
    var ra = feed(a, b.handshakePackets(caps: caps))          // A: B's offer, halves, ciphertext -> keyed
    check(isKeyed(ra) && a.established, "A keys on B's ciphertext (decapsulates)")
    check(a.safetyCode != nil && a.safetyCode == b.safetyCode, "safety code agrees: \(a.safetyCode ?? "-")")
    var buf = [UInt8](repeating: 0, count: 512), out = [UInt8](repeating: 0, count: 512)
    let plains = ["hello", "a second packet, longer than the first one by a fair margin", "x"]
    var sealedA: [[UInt8]] = []
    for s in plains {
      let bytes = Array(s.utf8)
      let m = bytes.withUnsafeBufferPointer { bp in a.seal(bp.baseAddress!, bp.count, into: &buf) }!
      sealedA.append(Array(buf[0..<m]))
    }
    for (i, s) in sealedA.enumerated() {
      let n = s.withUnsafeBufferPointer { b.open($0.baseAddress!, $0.count, into: &out) }
      check(n == plains[i].utf8.count && Array(out[0..<(n ?? 0)]) == Array(plains[i].utf8), "A->B packet \(i) opens")
    }
    let pB = "reply".withCString { b.seal(UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), 5, into: &buf) }!
    check(Array(buf[0..<pB]).withUnsafeBufferPointer { a.open($0.baseAddress!, $0.count, into: &out) } == 5, "B->A opens")
    check(b.handshakePackets(caps: caps).count == 1, "once A has proved the key, B's beat is HS3 alone")
    let vecA = a, vecB = b, vecSealed = sealedA

    // 2. B's packets land first (one and a half round trips): B cannot key yet.
    a = mk(seedA, ephA, kemA); b = mk(seedB, ephB, kemB, m: mB)
    ra = feed(a, b.handshakePackets(caps: caps))
    check(!isKeyed(ra) && !a.established, "A holds B's offer but is not keyed (no ciphertext yet)")
    rb = feed(b, a.handshakePackets(caps: caps))
    check(isKeyed(rb), "B keys once A's offer arrives")
    ra = feed(a, b.handshakePackets(caps: caps))
    check(isKeyed(ra) && a.safetyCode == b.safetyCode, "A keys on B's next beat, codes agree")

    // 3. Replay.
    let again = vecSealed[0].withUnsafeBufferPointer { vecB.open($0.baseAddress!, $0.count, into: &out) }
    check(again == nil && vecB.replayDrops == 1, "replayed packet refused")
    var late: [[UInt8]] = []
    for _ in 0..<2100 {
      let m = "tick".withCString { vecA.seal(UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), 4, into: &buf) }!
      late.append(Array(buf[0..<m]))
    }
    check(late.last!.withUnsafeBufferPointer { vecB.open($0.baseAddress!, $0.count, into: &out) } != nil, "newest packet opens")
    check(late[late.count - 2].withUnsafeBufferPointer { vecB.open($0.baseAddress!, $0.count, into: &out) } != nil, "unseen packet inside the window opens")
    check(late[0].withUnsafeBufferPointer { vecB.open($0.baseAddress!, $0.count, into: &out) } == nil, "packet older than the window refused")

    // A keyed end beats HS3 alone, so arms that need the halves use a fresh,
    // unkeyed A (same seeds, same keys) -- the first draft of this indexed
    // vecA's one-packet beat at [1] and trapped.
    let fresh = mk(seedA, ephA, kemA)
    let freshSet = fresh.handshakePackets(caps: caps)   // HS3 + two halves

    // 4. Wrong room, wrong identity, right identity, second identity.
    let c = Crypto(roomSalt: "another-room", identitySeed: seedB, fixedPrivate: ephB)
    check(refusedCount(feed(c, [freshSet[0]])) == 1 && c.hsBadSig == 1, "offer for another room refused")
    let d = mk(seedB, ephB, kemB, expected: Data(repeating: 0x33, count: 32))
    check(refusedCount(feed(d, freshSet)) >= 1 && d.hsWrongId == 1 && !d.established, "unexpected identity refused")
    let e = mk(seedB, ephB, kemB, expected: fresh.myIdentity)
    check(isKeyed(feed(e, freshSet)) && e.pinned, "expected identity accepted and pinned")
    let imp = mk(Data(repeating: 0x44, count: 32), Data(repeating: 0x05, count: 32), kemB)
    let bb = mk(seedB, ephB, kemB); _ = feed(bb, freshSet)
    check(refusedCount(feed(bb, [imp.handshakePacket(caps: caps)])) == 1 && bb.hsIdChanged == 1, "a second identity mid-call refused")

    // 5. Tampering: signature, caps, kem hash, a key half, the ciphertext.
    var bad = freshSet[0]; bad[130] ^= 1
    let f = mk(seedB, ephB, kemB); check(refusedCount(feed(f, [bad])) == 1 && f.hsBadSig == 1, "tampered signature refused")
    var badCaps = freshSet[0]; badCaps[36] ^= 1
    let g = mk(seedB, ephB, kemB); check(refusedCount(feed(g, [badCaps])) == 1, "tampered caps refused")
    var badHalf = freshSet; badHalf[1][100] ^= 1
    let h = mk(seedB, ephB, kemB)
    let rh = feed(h, badHalf)
    check(!isKeyed(rh) && h.hsKemHashBad == 1 && !h.established, "tampered ML-KEM key half refused (hash does not match the signed one)")
    // A fresh A that first sees B's offer, then B's tampered ciphertext.
    let a2 = mk(seedA, ephA, kemA); let b2 = mk(seedB, ephB, kemB, m: mB)
    _ = feed(b2, a2.handshakePackets(caps: caps))
    var bPk = b2.handshakePackets(caps: caps)
    bPk[3][200] ^= 1
    let r2 = feed(a2, bPk)
    check(!isKeyed(r2) && !a2.established && a2.hsCtRefused == 1, "tampered ciphertext refused (signature)")
    // The ciphertext re-signed by somebody else is refused too.
    let b3 = mk(Data(repeating: 0x55, count: 32), ephB, kemB, m: mB)
    _ = feed(b3, a2.handshakePackets(caps: caps))
    let r3 = feed(a2, [b3.handshakePackets(caps: caps)[3]])
    check(!isKeyed(r3) && !a2.established, "ciphertext signed by a different identity refused")
    // 6. Nothing seals before a key; a same-key beat is a no-op.
    let hh = mk(seedB, ephB, kemB)
    check("x".withCString { hh.seal(UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), 1, into: &buf) } == nil, "no seal before a key")
    let before = vecB.hsBadSig + vecB.hsWrongId
    if case .unchanged = feed(vecB, [vecA.handshakePacket(caps: caps)])[0] { check(before == vecB.hsBadSig + vecB.hsWrongId, "same-key beat is a no-op") }
    else { check(false, "same-key beat is a no-op") }
    check(vecA.handshakePackets(caps: caps).count == 1 && vecB.handshakePackets(caps: caps).count == 1, "keyed ends beat HS3 only")

    // ── ML-KEM-768 on its own ────────────────────────────────────────────────
    let kseed = [UInt8](repeating: 0x42, count: 64)
    let kk = MlKem.PrivateKey(seed: kseed)
    check(kk.publicKey.count == MlKem.PK_BYTES, "ml-kem ek is \(kk.publicKey.count) B")
    let fixedM = [UInt8](repeating: 0x24, count: 32)
    let ke = MlKem.encapsulate(kk.publicKey, m: fixedM)!
    check(ke.ciphertext.count == MlKem.CT_BYTES, "ml-kem ct is \(ke.ciphertext.count) B")
    check(kk.decapsulate(ke.ciphertext) == ke.sharedSecret, "ml-kem decaps agrees with encaps")
    var badCt = ke.ciphertext; badCt[100] ^= 1
    let kbad = kk.decapsulate(badCt)
    check(kbad != nil && kbad != ke.sharedSecret, "ml-kem tampered ct gives an implicit-rejection secret, never a failure")
    check(MlKem.encapsulate([UInt8](repeating: 0xff, count: MlKem.PK_BYTES)) == nil, "ml-kem refuses an ek that fails the modulus check")
    do {
      var tg = [Double](), te = [Double](), td = [Double]()
      for _ in 0..<50 {
        let t0 = Clock.now(); let k = MlKem.PrivateKey(); let t1 = Clock.now()
        let en = MlKem.encapsulate(k.publicKey)!; let t2 = Clock.now()
        _ = k.decapsulate(en.ciphertext); let t3 = Clock.now()
        tg.append(Double(Clock.ns(t1 - t0)) / 1000); te.append(Double(Clock.ns(t2 - t1)) / 1000); td.append(Double(Clock.ns(t3 - t2)) / 1000)
      }
      tg.sort(); te.sort(); td.sort()
      fputs(String(format: "  ml-kem-768 x 50: keygen p50 %.0f us  encaps p50 %.0f us  decaps p50 %.0f us  (max %.0f/%.0f/%.0f)\n",
                   tg[25], te[25], td[25], tg[49], te[49], td[49]), stderr)
      var pkt = [UInt8](repeating: 0x5a, count: 276), o = [UInt8](repeating: 0, count: 400)
      var samples = [Double](repeating: 0, count: 300_000)
      for i in samples.indices {
        let t0 = Clock.now()
        _ = pkt.withUnsafeBufferPointer { vecA.seal($0.baseAddress!, 276, into: &o) }
        samples[i] = Double(Clock.ns(Clock.now() - t0)) / 1000
      }
      samples.sort()
      fputs(String(format: "  seal 276 B x 300k: p50 %.2f us  p99 %.2f us  max %.1f us\n", samples[150_000], samples[297_000], samples[299_999]), stderr)
      _ = pkt
    }

    if let path {
      // Vectors for the Android port. Ed25519 in CryptoKit is randomised, so the
      // signed packets are VERIFIED there rather than compared; the ML-KEM
      // encapsulation uses a fixed m, so the ciphertext, the transcript and every
      // sealed packet are byte-exact.
      let hexs: ([UInt8]) -> String = { $0.map { String(format: "%02x", $0) }.joined() }
      let shared: String = {
        guard let pk = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: vecB.myPublic),
              let s = try? vecA.mine.sharedSecretFromKeyAgreement(with: pk) else { return "" }
        return s.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
      }()
      let aPk = vecA.handshakePackets(caps: caps)   // keyed: HS3 only -- rebuild the full set from a fresh A
      let fa = mk(seedA, ephA, kemA), fb = mk(seedB, ephB, kemB, m: mB)
      _ = feed(fb, fa.handshakePackets(caps: caps))
      let v: [String: Any] = [
        "room": room, "version": 3,
        "sharedSecretHex": shared,
        "a": ["idSeedHex": hexString(seedA), "privHex": hexString(ephA), "kemSeedHex": hexs(kemA),
              "pubHex": hexString(vecA.myPublic), "idPubHex": hexString(vecA.myIdentity), "kemPkHex": hexs(vecA.myKemPk),
              "packetsHex": fa.handshakePackets(caps: caps).map(hexs)],
        "b": ["idSeedHex": hexString(seedB), "privHex": hexString(ephB), "kemSeedHex": hexs(kemB), "kemMHex": hexs(mB),
              "pubHex": hexString(vecB.myPublic), "idPubHex": hexString(vecB.myIdentity),
              "packetsHex": fb.handshakePackets(caps: caps).map(hexs)],
        "safetyCode": vecA.safetyCode ?? "",
        "plaintexts": plains,
        "aToB": vecSealed.map(hexs),
        "mlkem": ["seedHex": hexs(kseed), "ekHex": hexs(kk.publicKey), "mHex": hexs(fixedM),
                  "ctHex": hexs(ke.ciphertext), "ssHex": hexs(ke.sharedSecret)],
      ]
      _ = aPk
      if let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]) {
        do { try d.write(to: URL(fileURLWithPath: path)); fputs("  vectors -> \(path)\n", stderr) }
        catch { fputs("  FAIL could not write \(path): \(error)\n", stderr); ok = false }
      }
    }
    return ok
  }
}
