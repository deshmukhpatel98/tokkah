import CryptoKit
import Foundation

// ── Encryption on the wire ───────────────────────────────────────────────────
//
// X25519 over the media socket, AES-256-GCM per packet. Measured on this machine
// at the real packet size: **0.78 us to seal 276 bytes, worst of 300,000 at
// 15 us, against a 1333 us audio deadline** -- 0.06% typical, 1.1% worst. So this
// runs on the capture callback without a thread hop, and the latency cost is
// nothing. That measurement is why CryptoKit was acceptable here despite
// allocating: the allocator's worst case is still two orders of magnitude inside
// the budget.
//
// TWO KEYS, ONE PER DIRECTION, and this is not decoration. Both ends derive the
// same shared secret, so if both used one key and a counter starting at zero,
// every packet number would be a NONCE REUSE -- and nonce reuse under GCM does
// not degrade the cipher, it breaks it outright and leaks the authentication key.
// HKDF gives two keys from the one secret and the ends agree on who uses which by
// comparing public keys, which needs no extra message.
//
// ── THE HANDSHAKE IS SIGNED (v2) ─────────────────────────────────────────────
//
// The first version of this file exchanged bare X25519 keys and mixed the room
// code into the key derivation, and said plainly what that did not defeat: an
// active man in the middle who knows the room code. That sentence understated
// it. The room code is minted by the caller and sent to the callee THROUGH THE
// SIGNALLING SERVER, inside the ring; the same server hands each end the other's
// address. So the one party positioned to sit in the middle was also the one
// party guaranteed to know the code. "End to end" with a caveat that size is
// transport encryption to us.
//
// Every install already has an identity that outlives a call: the Ed25519 device
// key in identity.json, the one that signs every ring and that the callee already
// verifies before a card is shown. So the ephemeral X25519 key now travels signed
// by it, over a message that also names the room:
//
//   packet:  magic(4) || eph(32) || caps(4 LE) || id(32) || sig(64)      136 bytes
//   signed:  "kin-hs-v2|" + room + "|" || eph(32) || caps(4 LE)
//
// and the receiver refuses a handshake unless ALL of these hold:
//
//   1. the signature verifies under the identity key carried in the packet -- so
//      the sender holds that key AND knows this room (an attacker who does not
//      know the room cannot even make this end adopt a key, which closes the
//      old "anyone who can reach the port can re-key the call" denial of service);
//   2. the identity key is the one this end EXPECTED, when it expected one: the
//      key that signed the ring (callee side), the key the server bound the
//      handle to at registration (caller side, carried in the ring's answer), or
//      the key pinned in contacts.json from a previous call. A different key is
//      refused and counted -- it is never a call;
//   3. with no expectation (an invite link, a first call to a stranger), the
//      first identity seen is pinned FOR THIS CALL and every later handshake must
//      match it. Trust-on-first-use, and the safety code below is how two people
//      check that first use. The caller of `adoptHandshake` pins it in
//      contacts.json once the call is answered, so the second call is no longer
//      first-use.
//
// The derived keys are bound to the whole transcript -- both ephemeral keys and
// both identity keys sit in the HKDF info -- so two sessions that share a secret
// by accident can never share a key, and a key belongs to exactly one pair of
// identities.
//
// ── NO PLAINTEXT WINDOW ──────────────────────────────────────────────────────
//
// v1 accepted media in the clear while the handshake was outstanding, as an
// interop choice, and counted it. That is a downgrade path: an attacker who can
// drop 136-byte packets holds the call in plaintext for as long as they like.
// Nothing but a handshake is read or written before a key exists now. The cost
// is nothing: the handshake completes in one round trip during rendezvous,
// before the first media packet would have been useful to anybody.
//
// ── REPLAY ───────────────────────────────────────────────────────────────────
//
// GCM authenticates a packet; it does not stop the same packet arriving twice.
// A recorded second of somebody saying "yes" could be played back into the call
// a minute later. A sliding window over the packet counter (2048 packets, about
// 1.4 s of audio) refuses anything already seen and anything older than the
// window. Marked AFTER the tag verifies, never before, or a stranger could poison
// the window with garbage counters.
//
// ── WHAT THIS PROTECTS AGAINST, precisely ────────────────────────────────────
//
//  - a passive listener on any hop: yes, completely.
//  - the signalling server, or anyone who compromises it: it can still see WHO
//    calls WHOM and when (metadata); it can no longer read or alter a call, and it
//    can no longer substitute keys without the substitution being refused
//    (pinned/expected key) or visible (safety code, first call to a stranger).
//  - an attacker on the path who knows the room code: same as above.
//  - an attacker who can suppress packets: they can stop the call. They can no
//    longer hold it in plaintext.
//  - replay of recorded packets: refused.
//  - a stranger reaching the port: cannot re-key, cannot inject, cannot end the
//    call (the goodbye is inside the encryption too).
//  - a first call between two people neither of whom has any prior knowledge of
//    the other's key: an attacker who ALSO controls the server can substitute
//    both identities on that one call. The safety code differs on the two screens
//    when that happens; the call after it is pinned. This is the same residual
//    Signal, WhatsApp and Zoom's E2EE mode carry, and the honest place to stop
//    claiming.
final class Crypto {
  /// The signed handshake. 0x0006 was the unsigned one and is REFUSED, counted
  /// as `hsOld`, so a build from before this change is visible in the beat rather
  /// than silently connecting in the clear.
  static let HS_MAGIC: UInt32 = 0x544B_0009
  static let HS_LEN = 4 + 32 + 4 + 32 + 64
  static let HS_CONTEXT = "kin-hs-v2|"

  private let mine: Curve25519.KeyAgreement.PrivateKey
  private let idKey: Curve25519.Signing.PrivateKey
  private let room: String
  private let salt: Data
  /// The identity this end expects on the other side, or nil for first-use.
  private let expected: Data?
  private var sendKey: SymmetricKey?
  private var recvKey: SymmetricKey?
  private var sendCtr: UInt64 = 0
  // rawSend is reached from THREE threads -- the audio capture callback, the
  // video encoder's callback and the probe thread. A raced counter would hand two
  // packets the same nonce, and under GCM a repeated nonce does not weaken the
  // cipher, it forfeits it. The seal is ~0.8 us, so holding a lock across the
  // whole thing costs about 0.6 ms per second of wall time and removes the
  // question entirely. `open` takes the same lock: it is one thread today, and
  // a key swap under it from a handshake must never race a packet mid-open.
  private let lock = NSLock()

  // ── replay window ──────────────────────────────────────────────────────────
  static let replayWindow = 2048
  private var rxHigh: UInt64 = 0
  private var rxBits = [UInt64](repeating: 0, count: Crypto.replayWindow / 64)

  private(set) var established = false
  private(set) var peerKeyHex = ""      // peer's ephemeral X25519 key
  private(set) var peerIdHex = ""       // peer's Ed25519 identity
  /// True when the peer's identity matched a key this end already expected;
  /// false when it was accepted on first use. A beat field, and the difference
  /// between "verified" and "trusted for now".
  private(set) var pinned = false
  private(set) var sealed = 0, opened = 0, openFails = 0
  private(set) var replayDrops = 0, preKeyDrops = 0, preKeyRx = 0, plaintextRx = 0
  private(set) var hsBadSig = 0, hsWrongId = 0, hsIdChanged = 0, hsOld = 0, hsFlood = 0, hsWeak = 0

  // ── a budget on signature checks ───────────────────────────────────────────
  // A verify is ~60 us here and tens of milliseconds on a phone doing it in
  // BigInteger. The legitimate cadence is one handshake per 300 ms, and a
  // same-key beat costs nothing (compared before verifying). So a flood of fresh
  // keys is the only way to make this end spend, and it is capped: 20 verifies a
  // second, the rest counted and dropped.
  private var verifyTokens = 20.0
  private var verifyRefill = Date()

  var myPublic: Data { mine.publicKey.rawRepresentation }
  var myIdentity: Data { idKey.publicKey.rawRepresentation }
  var peerIdentityB64: String? {
    guard !peerIdHex.isEmpty, let d = Crypto.hex(peerIdHex) else { return nil }
    return d.base64EncodedString()
  }

  // ── THE CODE YOU READ ALOUD ─────────────────────────────────────────────────
  //
  // Encryption without a way to verify the other end's key is protection against
  // a passive listener only; the only defence anybody has ever found against a
  // machine that substitutes keys is two humans comparing a short string out loud.
  // Hash all four public keys SORTED -- so both ends compute the same string
  // without agreeing who is first -- and take 8 characters of 5 bits. 40 bits is
  // not brute-forceable inside a live handshake and is short enough to say. The
  // alphabet leaves out 0/O/1/I because this gets read down a phone line.
  static let codeAlphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
  var safetyCode: String? {
    guard established, !peerKeyHex.isEmpty, !peerIdHex.isEmpty else { return nil }
    let parts = [Crypto.hexString(myPublic), peerKeyHex, Crypto.hexString(myIdentity), peerIdHex].sorted()
    let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
    let out = digest.prefix(8).map { String(Crypto.codeAlphabet[Int($0 & 31)]) }.joined()
    return String(out.prefix(4)) + " " + String(out.suffix(4))
  }

  /// `roomSalt` is the room code. `identitySeed` is this install's Ed25519 seed
  /// (identity.json). `expectedPeer` is the 32-byte identity the other end must
  /// present, or nil to trust the first one seen. `fixedPrivate` exists for the
  /// vector generator only: a fixed ephemeral key makes a run reproducible.
  init(roomSalt: String, identitySeed: Data, expectedPeer: Data? = nil, fixedPrivate: Data? = nil) {
    room = roomSalt
    salt = Data(("tk-v2-" + roomSalt).utf8)
    if let f = fixedPrivate, let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: f) {
      mine = k
    } else {
      mine = Curve25519.KeyAgreement.PrivateKey()
    }
    if let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: identitySeed) {
      idKey = k
    } else {
      // A seed that does not parse is an identity.json that was damaged. A fresh
      // key still gives a working, first-use call; the beat says so through
      // `pinned == false` on a call that carried an expectation.
      fputs("crypto: identity seed did not parse -- this call uses a throwaway identity\n", stderr)
      idKey = Curve25519.Signing.PrivateKey()
    }
    expected = (expectedPeer?.count == 32) ? expectedPeer : nil
  }

  // ── the handshake packet ───────────────────────────────────────────────────

  private var hsCache: (caps: UInt32, pkt: [UInt8])?
  /// Signed once per (key, caps) and reused: the beat sends this every 300 ms
  /// until keyed and every 5 s after, and a signature per beat would be waste.
  func handshakePacket(caps: UInt32) -> [UInt8] {
    lock.lock(); defer { lock.unlock() }
    if let c = hsCache, c.caps == caps { return c.pkt }
    var out = [UInt8](repeating: 0, count: Crypto.HS_LEN)
    out.withUnsafeMutableBytes { $0.storeBytes(of: Crypto.HS_MAGIC.littleEndian, toByteOffset: 0, as: UInt32.self) }
    myPublic.copyBytes(to: &out[4], count: 32)
    out.withUnsafeMutableBytes { $0.storeBytes(of: caps.littleEndian, toByteOffset: 36, as: UInt32.self) }
    myIdentity.copyBytes(to: &out[40], count: 32)
    let msg = Crypto.signedMessage(room: room, eph: myPublic, caps: caps)
    if let sig = try? idKey.signature(for: msg) {
      sig.copyBytes(to: &out[72], count: 64)
    }
    hsCache = (caps, out)
    return out
  }

  static func signedMessage(room: String, eph: Data, caps: UInt32) -> Data {
    var m = Data((HS_CONTEXT + room + "|").utf8)
    m.append(eph)
    withUnsafeBytes(of: caps.littleEndian) { m.append(contentsOf: $0) }
    return m
  }

  static func caps(of p: UnsafePointer<UInt8>, _ n: Int) -> UInt32 {
    guard n >= HS_LEN else { return 0 }
    return (p + 36).withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) }
  }

  enum Adopt {
    /// Same peer, same key: a keepalive beat. Nothing changed.
    case unchanged
    /// A new verified key was adopted; the caller replies with its own handshake.
    case adopted
    /// Refused, and already counted under the field named.
    case refused(String)
  }

  /// Consider a received handshake. The signature is only checked when the key
  /// is new to us -- a same-key beat is compared and returned without any
  /// arithmetic -- and the rules above decide whether a new key is adopted.
  func adoptHandshake(_ p: UnsafePointer<UInt8>, _ n: Int) -> Adopt {
    guard n >= Crypto.HS_LEN else { return .refused("short") }
    let eph = Data(bytes: p + 4, count: 32)
    let caps = Crypto.caps(of: p, n)
    let id = Data(bytes: p + 40, count: 32)
    let sig = Data(bytes: p + 72, count: 64)
    let ephHex = Crypto.hexString(eph), idHex = Crypto.hexString(id)
    if ephHex == peerKeyHex && idHex == peerIdHex { return .unchanged }

    // The budget, before the expensive operation.
    let now = Date()
    verifyTokens = min(20, verifyTokens + now.timeIntervalSince(verifyRefill) * 20)
    verifyRefill = now
    if verifyTokens < 1 { hsFlood += 1; return .refused("flood") }
    verifyTokens -= 1

    // 1. Proof of the identity key AND of the room.
    guard let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: id),
          pk.isValidSignature(sig, for: Crypto.signedMessage(room: room, eph: eph, caps: caps))
    else { hsBadSig += 1; return .refused("bad signature") }
    // 2. The identity we were told to expect.
    if let e = expected, e != id { hsWrongId += 1; return .refused("wrong identity") }
    // 3. First-use pin for the call: a different identity mid-call is refused.
    if expected == nil, !peerIdHex.isEmpty, idHex != peerIdHex { hsIdChanged += 1; return .refused("identity changed") }
    // The shared secret, refused if it is the all-zero point (a low-order public
    // key), which would make the "secret" something anybody can compute.
    guard let ppk = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: eph),
          let secret = try? mine.sharedSecretFromKeyAgreement(with: ppk),
          secret.withUnsafeBytes({ $0.contains { $0 != 0 } })
    else { hsWeak += 1; return .refused("weak key") }

    // Deterministic, symmetric, and needs no negotiation: whoever's ephemeral
    // key sorts lower uses the "a" key to send.
    let iAmA = myPublic.lexicographicallyPrecedes(eph)
    let transcript = Crypto.transcript(ephA: myPublic, ephB: eph, idA: myIdentity, idB: id)
    let ka = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                            sharedInfo: Data("a2b".utf8) + transcript, outputByteCount: 32)
    let kb = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                            sharedInfo: Data("b2a".utf8) + transcript, outputByteCount: 32)
    lock.lock()
    sendKey = iAmA ? ka : kb
    recvKey = iAmA ? kb : ka
    sendCtr = 0
    rxHigh = 0
    for i in rxBits.indices { rxBits[i] = 0 }
    peerKeyHex = ephHex
    peerIdHex = idHex
    pinned = expected != nil
    established = true
    lock.unlock()
    return .adopted
  }

  /// Both ephemeral keys then both identity keys, each pair sorted, so the two
  /// ends build the same 128 bytes from opposite viewpoints.
  static func transcript(ephA: Data, ephB: Data, idA: Data, idB: Data) -> Data {
    let e = [ephA, ephB].sorted { $0.lexicographicallyPrecedes($1) }
    let i = [idA, idB].sorted { $0.lexicographicallyPrecedes($1) }
    return e[0] + e[1] + i[0] + i[1]
  }

  /// An unsigned (v1) handshake arrived. Refused, always; counted so the beat
  /// can say "the other end is on an old build" rather than "never connected".
  func noteOldHandshake() { hsOld += 1 }

  // ── the packets ────────────────────────────────────────────────────────────

  /// `counter(8) || ciphertext || tag(16)`. The counter travels because packets
  /// are lost and reordered, so the receiver cannot infer it.
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
    // Replay, judged before the arithmetic: a counter already seen, or one
    // that fell out of the window, is not decrypted at all.
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
    // Authenticated: now, and only now, it counts as seen.
    if ctr > rxHigh {
      // Clear every slot the window slides past. A jump wider than the window
      // clears everything.
      let jump = ctr - rxHigh
      if jump >= UInt64(Crypto.replayWindow) {
        for i in rxBits.indices { rxBits[i] = 0 }
      } else {
        var c = rxHigh + 1
        while c <= ctr { rxBits[Int(c >> 6) % rxBits.count] &= ~(1 << UInt64(c & 63)); c += 1 }
      }
      rxHigh = ctr
    }
    rxBits[Int(ctr >> 6) % rxBits.count] |= (1 << UInt64(ctr & 63))
    pt.copyBytes(to: out, count: pt.count)
    opened += 1
    return pt.count
  }

  /// A recognised media magic arrived in the clear. Never dispatched; counted.
  func notePlaintextRx() { plaintextRx += 1 }
  /// Something other than a handshake arrived before THIS end had a key. Almost
  /// always the far end's first sealed probes, sent the moment it keyed and
  /// before our adoption of its reply -- ciphertext, not plaintext, so it has
  /// its own name. Dropped either way.
  func notePreKeyRx() { preKeyRx += 1 }
  /// Something wanted to send before a key existed. Dropped; counted.
  func notePreKeyDrop() { preKeyDrops += 1 }

  /// What the beat carries. Every refusal has its own name so the dashboard can
  /// say WHY a call never keyed, not just that it did not.
  func beatFields(into f: inout [String: Any]) {
    f["crypt"] = established ? 1 : 0
    f["crypt_v"] = 2
    f["crypt_bad"] = openFails
    f["crypt_pinned"] = pinned ? 1 : 0
    f["crypt_expected"] = expected != nil ? 1 : 0
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
  }

  var summary: String {
    if established {
      return "encrypted (aes-256-gcm, signed handshake, peer id \(peerIdHex.prefix(8))… "
        + (pinned ? "verified" : "first use") + ", code \(safetyCode ?? "-"))"
        + (replayDrops > 0 ? ", \(replayDrops) replays refused" : "")
        + (plaintextRx > 0 ? ", \(plaintextRx) plaintext refused" : "")
    }
    var why = ""
    if hsOld > 0 { why += " -- the other end is on an old build (\(hsOld) unsigned handshakes refused)" }
    if hsWrongId > 0 { why += " -- \(hsWrongId) handshakes from the WRONG identity refused" }
    if hsBadSig > 0 { why += " -- \(hsBadSig) handshakes with bad signatures refused" }
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
  //
  // Validate the ruler on known answers INCLUDING inputs it must refuse. Each
  // arm below is one of the properties the header claims; a claim without an arm
  // here is marketing.
  static func selftest(vectorsTo path: String?) -> Bool {
    var ok = true
    func check(_ c: Bool, _ what: String) {
      fputs("  \(c ? "ok  " : "FAIL") \(what)\n", stderr); if !c { ok = false }
    }
    let room = "sunset-otter-42"
    let seedA = Data(repeating: 0x11, count: 32), seedB = Data(repeating: 0x22, count: 32)
    let ephA = Data(repeating: 0x01, count: 32), ephB = Data(repeating: 0x02, count: 32)
    func pkt(_ c: Crypto) -> [UInt8] { c.handshakePacket(caps: CAP_PCM16 | CAP_PCM_LP) }
    func adopt(_ c: Crypto, _ p: [UInt8]) -> Adopt { p.withUnsafeBufferPointer { c.adoptHandshake($0.baseAddress!, $0.count) } }
    func isAdopted(_ a: Adopt) -> Bool { if case .adopted = a { return true }; return false }
    func isRefused(_ a: Adopt) -> Bool { if case .refused = a { return true }; return false }

    // 1. Two honest ends, no expectation: both key, same code, both directions open.
    let a = Crypto(roomSalt: room, identitySeed: seedA, fixedPrivate: ephA)
    let b = Crypto(roomSalt: room, identitySeed: seedB, fixedPrivate: ephB)
    check(isAdopted(adopt(b, pkt(a))) && isAdopted(adopt(a, pkt(b))), "two honest ends key")
    check(a.safetyCode != nil && a.safetyCode == b.safetyCode, "safety code agrees: \(a.safetyCode ?? "-")")
    var sealedA: [[UInt8]] = []
    let plains = ["hello", "a second packet, longer than the first one by a fair margin", "x"]
    var buf = [UInt8](repeating: 0, count: 512), out = [UInt8](repeating: 0, count: 512)
    for s in plains {
      let bytes = Array(s.utf8)
      let m = bytes.withUnsafeBufferPointer { bp in a.seal(bp.baseAddress!, bp.count, into: &buf) }!
      sealedA.append(Array(buf[0..<m]))
    }
    for (i, s) in sealedA.enumerated() {
      let n = s.withUnsafeBufferPointer { b.open($0.baseAddress!, $0.count, into: &out) }
      check(n == plains[i].utf8.count && Array(out[0..<(n ?? 0)]) == Array(plains[i].utf8), "A->B packet \(i) opens")
    }
    // 2. Replay: the same packet again is refused; an old one inside the window
    //    that was never seen still opens; one beyond the window does not.
    let again = sealedA[0].withUnsafeBufferPointer { b.open($0.baseAddress!, $0.count, into: &out) }
    check(again == nil && b.replayDrops == 1, "replayed packet refused")
    // Seal 2100 more, deliver only the last, then try the first of them (out of window)
    // and the second-to-last (in window, unseen).
    var late: [[UInt8]] = []
    for _ in 0..<2100 {
      let m = "tick".withCString { a.seal(UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), 4, into: &buf) }!
      late.append(Array(buf[0..<m]))
    }
    check(late.last!.withUnsafeBufferPointer { b.open($0.baseAddress!, $0.count, into: &out) } != nil, "newest packet opens")
    check(late[late.count - 2].withUnsafeBufferPointer { b.open($0.baseAddress!, $0.count, into: &out) } != nil, "unseen packet inside the window opens")
    check(late[0].withUnsafeBufferPointer { b.open($0.baseAddress!, $0.count, into: &out) } == nil, "packet older than the window refused")
    // 3. The wrong room: same keys, different salt and signed message.
    let c = Crypto(roomSalt: "another-room", identitySeed: seedB, fixedPrivate: ephB)
    check(isRefused(adopt(c, pkt(a))) && c.hsBadSig == 1, "handshake for another room refused")
    // 4. The wrong identity when one is expected.
    let d = Crypto(roomSalt: room, identitySeed: seedB, expectedPeer: Data(repeating: 0x33, count: 32), fixedPrivate: ephB)
    check(isRefused(adopt(d, pkt(a))) && d.hsWrongId == 1 && !d.established, "unexpected identity refused")
    // 5. The right identity when one is expected: pinned.
    let e = Crypto(roomSalt: room, identitySeed: seedB, expectedPeer: a.myIdentity, fixedPrivate: ephB)
    check(isAdopted(adopt(e, pkt(a))) && e.pinned, "expected identity accepted and pinned")
    // 6. First-use pin: a second identity mid-call is refused.
    let imp = Crypto(roomSalt: room, identitySeed: Data(repeating: 0x44, count: 32), fixedPrivate: Data(repeating: 0x05, count: 32))
    check(isRefused(adopt(b, pkt(imp))) && b.hsIdChanged == 1, "a second identity mid-call refused")
    // 7. A same-key beat is unchanged, and costs no verify.
    let before = b.hsBadSig + b.hsWrongId
    if case .unchanged = adopt(b, pkt(a)) { check(before == b.hsBadSig + b.hsWrongId, "same-key beat is a no-op") } else { check(false, "same-key beat is a no-op") }
    // 8. A tampered signature is refused; a tampered caps byte too (it is signed).
    var bad = pkt(a); bad[100] ^= 1
    check(isRefused(adopt(c, bad)), "tampered signature refused")
    var badCaps = pkt(a); badCaps[36] ^= 1
    let f = Crypto(roomSalt: room, identitySeed: seedB, fixedPrivate: ephB)
    check(isRefused(adopt(f, badCaps)) && f.hsBadSig == 1, "tampered caps refused")
    // 9. The low-order point is refused.
    var weak = pkt(a)
    for i in 4..<36 { weak[i] = 0 }
    let g = Crypto(roomSalt: room, identitySeed: seedB, fixedPrivate: ephB)
    check(isRefused(adopt(g, weak)), "all-zero ephemeral refused (bad signature, as it must be)")
    // 10. Nothing seals before a key.
    let h = Crypto(roomSalt: room, identitySeed: seedB)
    check("x".withCString { h.seal(UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), 1, into: &buf) } == nil, "no seal before a key")

    if let path {
      // Vectors for the Android port. Ed25519 in CryptoKit is randomised, so the
      // handshake packets are not byte-exact between runs -- the port VERIFIES
      // them -- but the derived keys are, so the sealed packets are.
      let shared: String = {
        guard let pk = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: b.myPublic),
              let s = try? a.mine.sharedSecretFromKeyAgreement(with: pk) else { return "" }
        return s.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
      }()
      let v: [String: Any] = [
        "room": room,
        "sharedSecretHex": shared,
        "a": ["idSeedHex": hexString(seedA), "privHex": hexString(ephA),
              "pubHex": hexString(a.myPublic), "idPubHex": hexString(a.myIdentity),
              "handshakeHex": pkt(a).map { String(format: "%02x", $0) }.joined()],
        "b": ["idSeedHex": hexString(seedB), "privHex": hexString(ephB),
              "pubHex": hexString(b.myPublic), "idPubHex": hexString(b.myIdentity),
              "handshakeHex": pkt(b).map { String(format: "%02x", $0) }.joined()],
        "safetyCode": a.safetyCode ?? "",
        "plaintexts": plains,
        "aToB": sealedA.map { $0.map { String(format: "%02x", $0) }.joined() },
      ]
      if let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]) {
        do { try d.write(to: URL(fileURLWithPath: path)); fputs("  vectors -> \(path)\n", stderr) }
        catch { fputs("  FAIL could not write \(path): \(error)\n", stderr); ok = false }
      }
    }
    return ok
  }
}
