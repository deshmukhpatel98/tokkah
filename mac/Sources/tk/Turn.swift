import CryptoKit
import Darwin
import Foundation

// ── TURN, the short path on a long call ──────────────────────────────────────
//
// Direct P2P from India to the US rides the public internet at ~2× the speed of
// light in fibre (LATENCY-150.md, measured TCP RTT). Cloudflare's backbone is
// 1.2–1.3×. A relay through that backbone is not a detour on those routes — it
// is the shorter wire. This file is the client for that relay.
//
// Fail-open: if allocate fails, the call still tries STUN + LAN, same as before.
// A missing relay must never be why two people cannot talk.
final class TurnClient {
  let host: String
  let port: UInt16
  let username: String
  let credential: String
  private(set) var relayIP: String?
  private(set) var relayPort: UInt16?
  private var realm = ""
  private var nonce = ""
  private var turnAddr = sockaddr_in()
  private var channel: UInt16 = 0x4000
  private var boundIP = ""
  private var boundPort: UInt16 = 0
  private let cookie: UInt32 = 0x2112_A442

  var relayed: String? {
    guard let ip = relayIP, let p = relayPort else { return nil }
    return "\(ip):\(p)"
  }

  func isTurnServer(_ a: sockaddr_in) -> Bool {
    a.sin_addr.s_addr == turnAddr.sin_addr.s_addr && a.sin_port == turnAddr.sin_port
  }

  static func fetch(base: String = Server.base) -> TurnClient? {
    guard let url = URL(string: "\(base)/api/mac/turn") else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = 4
    req.cachePolicy = .reloadIgnoringLocalCacheData
    let sem = DispatchSemaphore(value: 0)
    var parsed: (String, UInt16, String, String)?
    URLSession.shared.dataTask(with: req) { d, _, _ in
      defer { sem.signal() }
      guard let d,
            let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            o["ok"] as? Bool == true,
            let host = o["host"] as? String,
            let user = o["username"] as? String,
            let cred = o["credential"] as? String
      else { return }
      let port = UInt16(truncatingIfNeeded: (o["port"] as? Int) ?? 3478)
      parsed = (host, port, user, cred)
    }.resume()
    _ = sem.wait(timeout: .now() + 5)
    guard let p = parsed else { return nil }
    return TurnClient(host: p.0, port: p.1, username: p.2, credential: p.3)
  }

  init(host: String, port: UInt16, username: String, credential: String) {
    self.host = host; self.port = port; self.username = username; self.credential = credential
  }

  /// Allocate a relayed address on `fd`. MUST run before the media recv loop
  /// starts — it briefly sets a receive timeout on the same socket STUN used.
  func allocate(fd: Int32) -> Bool {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                         ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res, let sa = ai.pointee.ai_addr else {
      fputs("turn: cannot resolve \(host)\n", stderr)
      return false
    }
    defer { freeaddrinfo(res) }
    memcpy(&turnAddr, sa, min(Int(ai.pointee.ai_addrlen), MemoryLayout<sockaddr_in>.size))

    // ── REQUESTED-TRANSPORT IS NOT OPTIONAL ───────────────────────────────────
    //
    // This Allocate carried LIFETIME and nothing else for as long as it has
    // existed, and `turn: allocate failed` was 9 of 9 runs. RFC 5766 6.1 makes
    // REQUESTED-TRANSPORT mandatory and says a server MUST reject an Allocate
    // without it -- so the relay was never refusing our credentials, it was
    // refusing a malformed request, and the 1.6 s it cost every launch bought
    // nothing. 17 is UDP; the three trailing bytes are RFFU and must be zero.
    //
    // On the unauthenticated probe too: some servers validate the body before
    // they challenge, and a 400 there never hands back the realm and nonce that
    // the second request needs.
    let requestedTransportUDP: (UInt16, [UInt8]) = (0x0019, [17, 0, 0, 0])

    // First request has no auth. 401 hands us realm + nonce.
    _ = roundTrip(fd: fd, method: 0x0003, extra: [requestedTransportUDP])
    var attrs: [(UInt16, [UInt8])] = [requestedTransportUDP,
                                      (0x000D, u32(600))]   // LIFETIME 10 min
    if !realm.isEmpty {
      attrs.append((0x0006, Array(username.utf8)))          // USERNAME
      attrs.append((0x0014, Array(realm.utf8)))             // REALM
      attrs.append((0x0015, Array(nonce.utf8)))             // NONCE
    }
    let reply = roundTrip(fd: fd, method: 0x0003, extra: attrs, integrity: true)
    guard let r = reply, r.ok, let rel = r.relayed else {
      // ── SAY WHICH FAILURE IT WAS ────────────────────────────────────────────
      //
      // `allocate failed` was the same string for a 400, a 401, a 403 and a
      // socket that never answered -- a blind instrument returning the same
      // value as a real negative, which is how the missing attribute above
      // stayed hidden for so long. ERROR-CODE was parsed and thrown away.
      if let r = reply {
        if let c = r.errorCode {
          fputs("turn: allocate failed -- \(c)"
              + "\(r.errorReason.isEmpty ? "" : " " + r.errorReason)\n", stderr)
        } else if r.ok {
          fputs("turn: allocate succeeded with no XOR-RELAYED-ADDRESS in it\n", stderr)
        } else {
          fputs("turn: allocate failed -- a reply that was neither success nor error\n", stderr)
        }
      } else {
        fputs("turn: allocate failed -- no reply from \(host):\(port)\n", stderr)
      }
      return false
    }
    relayIP = rel.0
    relayPort = rel.1
    fputs("turn: relayed \(rel.0):\(rel.1) via \(host):\(port)\n", stderr)
    return true
  }

  /// Permission + channel so media can ride the allocation toward `ip:port`.
  func bindPeer(fd: Int32, ip: String, port: UInt16) -> Bool {
    let xor = xorPeer(ip: ip, port: port)
    var attrs: [(UInt16, [UInt8])] = [(0x0012, xor)]        // XOR-PEER-ADDRESS
    auth(&attrs)
    guard let r = roundTrip(fd: fd, method: 0x0008, extra: attrs, integrity: true), r.ok else {
      fputs("turn: CreatePermission \(ip):\(port) failed\n", stderr)
      return false
    }
    var ch = [(UInt16, [UInt8])]()
    ch.append((0x001C, u16(channel)))                       // CHANNEL-NUMBER
    ch.append((0x0012, xor))
    auth(&ch)
    guard let r2 = roundTrip(fd: fd, method: 0x0009, extra: ch, integrity: true), r2.ok else {
      fputs("turn: ChannelBind \(ip):\(port) failed\n", stderr)
      return false
    }
    boundIP = ip
    boundPort = port
    return true
  }

  /// Wrap media as ChannelData and send it to the TURN server.
  /// Stack allocation: this can run on the capture callback.
  func sendChannel(fd: Int32, _ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
    let pad = (4 - (n % 4)) % 4
    let total = 4 + n + pad
    var sent = false
    var a = turnAddr
    withUnsafeTemporaryAllocation(byteCount: total, alignment: 8) { tmp in
      let out = tmp.baseAddress!.assumingMemoryBound(to: UInt8.self)
      out[0] = UInt8(channel >> 8)
      out[1] = UInt8(channel & 0xff)
      out[2] = UInt8(n >> 8)
      out[3] = UInt8(n & 0xff)
      memcpy(out + 4, p, n)
      if pad > 0 { memset(out + 4 + n, 0, pad) }
      let r = withUnsafePointer(to: &a) { pp in
        pp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          sendto(fd, out, total, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      sent = r > 0
    }
    return sent
  }

  /// If this datagram is ChannelData from our TURN server, return the payload
  /// offset and length. Otherwise nil.
  func unwrap(_ buf: UnsafePointer<UInt8>, _ n: Int, from: sockaddr_in) -> (UnsafePointer<UInt8>, Int)? {
    guard isTurnServer(from), n >= 4 else { return nil }
    let ch = UInt16(buf[0]) << 8 | UInt16(buf[1])
    guard ch == channel else { return nil }
    let len = Int(UInt16(buf[2]) << 8 | UInt16(buf[3]))
    guard 4 + len <= n else { return nil }
    return (buf + 4, len)
  }

  // ── STUN over this allocation ──────────────────────────────────────────────

  private struct Reply {
    var ok = false
    var relayed: (String, UInt16)?
    /// ERROR-CODE as the wire spells it: 400, 401, 403, 437, 486.
    var errorCode: Int?
    var errorReason = ""
  }

  private func roundTrip(fd: Int32, method: UInt16, extra: [(UInt16, [UInt8])],
                         integrity: Bool = false, timeoutMs: Int = 800) -> Reply? {
    var txid = [UInt8](repeating: 0, count: 12)
    for i in 0..<12 { txid[i] = UInt8.random(in: 0...255) }
    let pkt = build(method: method, txid: txid, extra: extra, integrity: integrity)
    var a = turnAddr
    _ = pkt.withUnsafeBufferPointer { b in
      withUnsafePointer(to: &a) { pp in
        pp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          sendto(fd, b.baseAddress!, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
    var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
    if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)) != 0 {
      return nil
    }
    defer {
      var zero = timeval(tv_sec: 0, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &zero, socklen_t(MemoryLayout<timeval>.size))
    }
    var buf = [UInt8](repeating: 0, count: 1024)
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
      let n = buf.withUnsafeMutableBufferPointer { b in recvfrom(fd, b.baseAddress!, 1024, 0, nil, nil) }
      if n < 20 { continue }
      var match = true
      for i in 0..<12 where buf[8 + i] != txid[i] { match = false }
      guard match else { continue }
      return parse(buf, Int(n))
    }
    return nil
  }

  private func parse(_ buf: [UInt8], _ n: Int) -> Reply {
    var out = Reply()
    let type = UInt16(buf[0]) << 8 | UInt16(buf[1])
    let cls = type & 0x0110
    if cls == 0x0110 {                      // error
      var i = 20
      let end = min(n, 20 + (Int(buf[2]) << 8 | Int(buf[3])))
      while i + 4 <= end {
        let at = UInt16(buf[i]) << 8 | UInt16(buf[i + 1])
        let al = Int(UInt16(buf[i + 2]) << 8 | UInt16(buf[i + 3]))
        let v = i + 4
        if at == 0x0014, v + al <= n { realm = String(bytes: buf[v..<v+al], encoding: .utf8) ?? realm }
        if at == 0x0015, v + al <= n { nonce = String(bytes: buf[v..<v+al], encoding: .utf8) ?? nonce }
        // ERROR-CODE: two reserved bytes, a class 3..6, a number 0..99, then a
        // UTF-8 reason. Kept, because "failed" on its own cannot be debugged.
        if at == 0x0009, al >= 4, v + al <= n {
          out.errorCode = Int(buf[v + 2] & 0x07) * 100 + Int(buf[v + 3])
          if al > 4 {
            out.errorReason = String(bytes: buf[(v + 4)..<(v + al)], encoding: .utf8) ?? ""
          }
        }
        i = v + al + ((4 - al % 4) % 4)
      }
      return out
    }
    if cls != 0x0100 { return out }         // not a success response
    out.ok = true
    var i = 20
    let end = min(n, 20 + (Int(buf[2]) << 8 | Int(buf[3])))
    while i + 4 <= end {
      let at = UInt16(buf[i]) << 8 | UInt16(buf[i + 1])
      let al = Int(UInt16(buf[i + 2]) << 8 | UInt16(buf[i + 3]))
      let v = i + 4
      if at == 0x0016, al >= 8, v + al <= n, buf[v + 1] == 0x01 {   // XOR-RELAYED-ADDRESS IPv4
        let p = UInt16(buf[v + 2]) << 8 | UInt16(buf[v + 3])
        let port = p ^ UInt16(cookie >> 16)
        var o = [UInt8](repeating: 0, count: 4)
        for k in 0..<4 { o[k] = buf[v + 4 + k] ^ UInt8((cookie >> (8 * (3 - UInt32(k)))) & 0xff) }
        out.relayed = ("\(o[0]).\(o[1]).\(o[2]).\(o[3])", port)
      }
      i = v + al + ((4 - al % 4) % 4)
    }
    return out
  }

  private func build(method: UInt16, txid: [UInt8], extra: [(UInt16, [UInt8])],
                     integrity: Bool) -> [UInt8] {
    func appendAttr(_ pkt: inout [UInt8], _ t: UInt16, _ v: [UInt8]) {
      pkt.append(UInt8(t >> 8)); pkt.append(UInt8(t & 0xff))
      pkt.append(UInt8(v.count >> 8)); pkt.append(UInt8(v.count & 0xff))
      pkt.append(contentsOf: v)
      let pad = (4 - (v.count % 4)) % 4
      if pad > 0 { pkt.append(contentsOf: [UInt8](repeating: 0, count: pad)) }
    }
    var body = [UInt8]()
    for (t, v) in extra { appendAttr(&body, t, v) }

    func header(_ len: Int) -> [UInt8] {
      var h = [UInt8](repeating: 0, count: 20)
      h[0] = UInt8(method >> 8); h[1] = UInt8(method & 0xff)
      h[2] = UInt8(len >> 8); h[3] = UInt8(len & 0xff)
      h[4] = 0x21; h[5] = 0x12; h[6] = 0xA4; h[7] = 0x42
      for i in 0..<12 { h[8 + i] = txid[i] }
      return h
    }

    if integrity {
      // Length includes MESSAGE-INTEGRITY (24 B) and excludes FINGERPRINT.
      let msg = header(body.count + 24) + body
      let key = longTermKey()
      let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(msg), using: SymmetricKey(data: key))
      appendAttr(&body, 0x0008, Array(mac))
      // Length now includes FINGERPRINT (8 B). CRC covers header+body including
      // MI, excluding the fingerprint attribute itself.
      let forCrc = header(body.count + 8) + body
      let fp = crc32(Data(forCrc)) ^ 0x5354_554E
      appendAttr(&body, 0x8028, u32(fp))
      return header(body.count) + body
    }
    return header(body.count) + body
  }

  private func auth(_ attrs: inout [(UInt16, [UInt8])]) {
    if !username.isEmpty { attrs.append((0x0006, Array(username.utf8))) }
    if !realm.isEmpty { attrs.append((0x0014, Array(realm.utf8))) }
    if !nonce.isEmpty { attrs.append((0x0015, Array(nonce.utf8))) }
  }

  private func longTermKey() -> Data {
    // MD5(username ":" realm ":" password) — RFC 5389 long-term credentials.
    let s = "\(username):\(realm):\(credential)"
    let d = Insecure.MD5.hash(data: Data(s.utf8))
    return Data(d)
  }

  private func xorPeer(ip: String, port: UInt16) -> [UInt8] {
    var o: [UInt8] = [0, 0x01]
    let xp = port ^ UInt16(cookie >> 16)
    o.append(UInt8(xp >> 8)); o.append(UInt8(xp & 0xff))
    let parts = ip.split(separator: ".").compactMap { UInt8($0) }
    let b = parts.count == 4 ? parts : [0, 0, 0, 0]
    for k in 0..<4 { o.append(b[k] ^ UInt8((cookie >> (8 * (3 - UInt32(k)))) & 0xff)) }
    return o
  }

  private func u32(_ x: UInt32) -> [UInt8] {
    [UInt8(x >> 24), UInt8(x >> 16 & 0xff), UInt8(x >> 8 & 0xff), UInt8(x & 0xff)]
  }
  private func u16(_ x: UInt16) -> [UInt8] {
    [UInt8(x >> 8), UInt8(x & 0xff), 0, 0]            // CHANNEL-NUMBER is 4 bytes, last 2 zero
  }

  private func crc32(_ d: Data) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in d {
      c ^= UInt32(b)
      for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
    }
    return ~c
  }
}

// ── A RELAY ADDRESS THAT ARRIVES LATE ────────────────────────────────────────
//
// TURN is the only thing on the launch path that is both slow and optional. The
// relayed address is nothing but a query parameter to the rendezvous: the poll
// loop republishes every iteration and the worker overwrites the entry each time.
// So the join stopped waiting for it -- it publishes without a relay and
// republishes the moment one exists, which makes TURN latency free to the join
// whether the allocate succeeds or not.
//
// Written by the TURN thread, read by three separate poll loops, hence the lock.
// A bare `var` shared across threads is how this process has crashed before.
final class RelayBox {
  private let lock = NSLock()
  private var value: String?
  func set(_ v: String?) { lock.lock(); value = v; lock.unlock() }
  func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
