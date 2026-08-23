import CryptoKit
import Foundation

// ── Encryption on the wire ───────────────────────────────────────────────────
//
// Until now audio and video crossed the internet in the clear, and the download
// page said so: treat a call as overheard. For a tool whose purpose is that two
// people talk to each other every day, that is not a footnote.
//
// X25519 over the media socket, AES-256-GCM per packet. Measured on this machine
// at the real packet size: **0.78 us to seal 276 bytes, worst of 300,000 at
// 15 us, against a 1333 us audio deadline** -- 0.06% typical, 1.1% worst. So this
// runs on the capture callback without a thread hop, and the latency cost is
// nothing. That measurement is why CryptoKit was acceptable here despite
// allocating: the allocator's worst case is still two orders of magnitude inside
// the budget. CommonCrypto's allocation-free one-shot GCM is not exposed to
// Swift, so the alternative was hand-rolled AES-CTR plus HMAC, which is more code
// and more ways to be wrong for no measurable gain.
//
// TWO KEYS, ONE PER DIRECTION, and this is not decoration. Both ends derive the
// same shared secret, so if both used one key and a counter starting at zero,
// every packet number would be a NONCE REUSE -- and nonce reuse under GCM does
// not degrade the cipher, it breaks it outright and leaks the authentication key.
// HKDF gives two keys from the one secret and the ends agree on who uses which by
// comparing public keys, which needs no extra message.
//
// WHAT THIS PROTECTS AGAINST, precisely, because overclaiming here would be worse
// than the plaintext:
//
//  - a passive listener on any hop: yes, completely.
//  - an attacker who does not know the room code: yes. The room code is mixed
//    into the key derivation, and it travels between the two people out of band
//    (one of them says it to the other), so it authenticates the exchange.
//  - an active man in the middle who DOES know the room code: no. They can run
//    their own exchange with each side. Fixing that needs identity that outlives
//    a call, which does not exist here yet.
//  - an attacker who can suppress packets: they can hold the call in plaintext,
//    because plaintext is still accepted while the handshake is outstanding. That
//    is a deliberate interop choice (see below) and it is REPORTED, never silent.
final class Crypto {
  private let mine = Curve25519.KeyAgreement.PrivateKey()
  private var sendKey: SymmetricKey?
  private var recvKey: SymmetricKey?
  private var sendCtr: UInt64 = 0
  private let salt: Data
  // rawSend is reached from THREE threads -- the audio capture callback, the
  // video encoder's callback and the probe thread. A raced counter would hand two
  // packets the same nonce, and under GCM a repeated nonce does not weaken the
  // cipher, it forfeits it: the authentication key falls out of the pair. The
  // seal is ~0.8 us, so holding a lock across the whole thing costs about 0.6 ms
  // per second of wall time and removes the question entirely.
  private let lock = NSLock()

  private(set) var established = false
  private(set) var peerKeyHex = ""
  private(set) var sealed = 0, opened = 0, openFails = 0, plaintextRx = 0, plaintextTx = 0

  var myPublic: Data { mine.publicKey.rawRepresentation }

  /// `roomSalt` is the room code when there is one. It is the only thing an
  /// attacker cannot obtain from the wire, so it is what turns this from
  /// "unauthenticated, stops eavesdroppers" into "authenticated against anyone
  /// who was not told the code".
  init(roomSalt: String) {
    salt = Data(("tk-v1-" + roomSalt).utf8)
  }

  func adoptPeer(_ raw: Data) -> Bool {
    guard raw.count == 32 else { return false }
    let hex = raw.map { String(format: "%02x", $0) }.joined()
    if hex == peerKeyHex { return established }   // same peer, nothing to redo
    guard let pk = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw),
          let secret = try? mine.sharedSecretFromKeyAgreement(with: pk) else { return false }
    // Deterministic, symmetric, and needs no negotiation: whoever's public key
    // sorts lower uses the "a" key to send. Both ends reach the same answer from
    // information they already have.
    let iAmA = myPublic.lexicographicallyPrecedes(raw)
    let ka = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                            sharedInfo: Data("a2b".utf8), outputByteCount: 32)
    let kb = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                            sharedInfo: Data("b2a".utf8), outputByteCount: 32)
    sendKey = iAmA ? ka : kb
    recvKey = iAmA ? kb : ka
    sendCtr = 0
    peerKeyHex = hex
    established = true
    return true
  }

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
    guard let k = recvKey, n > 8 + 16 else { return nil }
    var ctr: UInt64 = 0
    withUnsafeMutableBytes(of: &ctr) { memcpy($0.baseAddress!, p, 8) }
    ctr = UInt64(littleEndian: ctr)
    var nb = [UInt8](repeating: 0, count: 12)
    withUnsafeBytes(of: ctr.littleEndian) { for (i, b) in $0.enumerated() { nb[4 + i] = b } }
    let bodyLen = n - 8 - 16
    guard let nonce = try? AES.GCM.Nonce(data: Data(nb)) else { return nil }
    let ct = Data(bytes: p + 8, count: bodyLen)
    let tag = Data(bytes: p + 8 + bodyLen, count: 16)
    guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag),
          let pt = try? AES.GCM.open(box, using: k) else { openFails += 1; return nil }
    pt.copyBytes(to: out, count: pt.count)
    opened += 1
    return pt.count
  }

  func notePlaintextRx() { plaintextRx += 1 }
  func notePlaintextTx() { plaintextTx += 1 }

  var summary: String {
    established
      ? "encrypted (aes-256-gcm, peer \(peerKeyHex.prefix(8))…)"
        + (plaintextRx > 0 ? ", \(plaintextRx) plaintext received before handshake" : "")
      : "PLAINTEXT -- handshake not complete"
  }
}
