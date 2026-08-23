import Darwin
import Foundation

// ── STUN ────────────────────────────────────────────────────────────────────
//
// Learns what the outside world sees when this socket sends -- the public
// address and, critically, the public PORT the NAT assigned. Two Macs in two
// houses cannot reach each other by private address; each has to discover its own
// mapping, tell the other, and then both send, which punches the holes.
//
// It MUST use the same socket the media uses. A mapping discovered on a second
// socket describes that socket's hole, not this one's, and most NATs assign a
// different external port per source port -- so a "working" STUN result from the
// wrong socket produces an address that silently drops every media packet.
//
// RFC 5389, the 20 % of it that matters: a 20-byte header with a magic cookie and
// a 96-bit transaction id, and an XOR-MAPPED-ADDRESS attribute in the reply whose
// port and address are obfuscated by that cookie. Parsed by hand because pulling
// in a library for 60 lines would be the larger dependency.
enum Stun {
  static let cookie: UInt32 = 0x2112_A442

  struct Mapped { let ip: String; let port: UInt16 }

  /// The servers to ask, in order. One hardcoded hostname is one outage away from
  /// an app that will not start, and the failure mode was `exit(1)` before a window
  /// ever appeared -- from the Dock that looks like the app simply vanishing.
  static let servers = ["stun.cloudflare.com", "stun.l.google.com:19302", "stun1.l.google.com:19302"]

  /// Ask each in turn and take the first answer. Costs one 20-byte datagram per
  /// server, and only pays the timeout for the ones that are actually down.
  static func discoverAny(fd: Int32, servers list: [String]? = nil, timeoutMs: Int = 1200) -> Mapped? {
    for entry in list ?? servers {
      var host = entry
      var port: UInt16 = 3478
      // `host:port`, because Google's STUN does not live on 3478.
      if let colon = entry.lastIndex(of: ":"), let p = UInt16(entry[entry.index(after: colon)...]) {
        host = String(entry[..<colon]); port = p
      }
      if let m = discover(fd: fd, server: host, port: port, timeoutMs: timeoutMs) {
        if entry != (list ?? servers).first { fputs("stun: \(entry) answered\n", stderr) }
        return m
      }
      fputs("stun: no answer from \(entry)\n", stderr)
    }
    return nil
  }

  static func discover(fd: Int32, server: String, port: UInt16 = 3478, timeoutMs: Int = 1200) -> Mapped? {
    var req = [UInt8](repeating: 0, count: 20)
    req[0] = 0x00; req[1] = 0x01                      // Binding Request
    req[2] = 0x00; req[3] = 0x00                      // length 0
    req[4] = 0x21; req[5] = 0x12; req[6] = 0xA4; req[7] = 0x42
    var txid = [UInt8](repeating: 0, count: 12)
    for i in 0..<12 { txid[i] = UInt8.random(in: 0...255) }
    for i in 0..<12 { req[8 + i] = txid[i] }

    // Resolve by name: STUN servers move, and a hardcoded address is a rig that
    // breaks quietly a month later.
    var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                         ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(server, String(port), &hints, &res) == 0, let ai = res else { return nil }
    defer { freeaddrinfo(res) }

    _ = req.withUnsafeBufferPointer { b in
      sendto(fd, b.baseAddress!, 20, 0, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
    }

    // ── THE TIMEOUT THAT WAS NEVER INSTALLED ─────────────────────────────────
    //
    // This read used to hang the app forever. `tv_usec` is the SUB-SECOND part of a
    // `timeval` and must be under 1,000,000; `1200 * 1000` is 1.2 million, so
    // `setsockopt` returned EINVAL, nobody looked, and the socket kept its default
    // of "block until a packet arrives". Every STUN server that answered hid it.
    // One that did not answer froze the main thread in `recvfrom` -- no window, no
    // room join, no way out but Activity Monitor. Found by a test that clicked a
    // button and waited: the click never landed because the process was already
    // dead on its feet at startup.
    //
    // So: carry the seconds in the seconds field, and check the return value,
    // because a timeout that fails to install is exactly as dangerous as no
    // timeout at all and says nothing either way.
    var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
    if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)) != 0 {
      // Refuse to read at all rather than read without a deadline. No STUN mapping
      // costs us a direct path on some networks; a frozen app costs everything.
      fputs("stun: cannot set a \(timeoutMs) ms receive timeout (\(errno)) -- skipping discovery"
          + " rather than risking a blocking read on the main thread\n", stderr)
      return nil
    }
    defer {
      var zero = timeval(tv_sec: 0, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &zero, socklen_t(MemoryLayout<timeval>.size))
    }

    var buf = [UInt8](repeating: 0, count: 512)
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
      let n = buf.withUnsafeMutableBufferPointer { b in recvfrom(fd, b.baseAddress!, 512, 0, nil, nil) }
      if n < 20 { continue }
      guard buf[0] == 0x01, buf[1] == 0x01 else { continue }          // Binding Success
      var ok = true
      for i in 0..<12 where buf[8 + i] != txid[i] { ok = false; break }
      guard ok else { continue }                                       // not our transaction
      var i = 20
      let end = 20 + (Int(buf[2]) << 8 | Int(buf[3]))
      while i + 4 <= min(end, Int(n)) {
        let type = Int(buf[i]) << 8 | Int(buf[i + 1])
        let len = Int(buf[i + 2]) << 8 | Int(buf[i + 3])
        let v = i + 4
        // 0x0020 XOR-MAPPED-ADDRESS, 0x0001 MAPPED-ADDRESS (older servers).
        if (type == 0x0020 || type == 0x0001), len >= 8, v + len <= Int(n), buf[v + 1] == 0x01 {
          let xor = type == 0x0020
          let p = UInt16(buf[v + 2]) << 8 | UInt16(buf[v + 3])
          let port = xor ? p ^ UInt16(cookie >> 16) : p
          var o = [UInt8](repeating: 0, count: 4)
          for k in 0..<4 {
            o[k] = xor ? buf[v + 4 + k] ^ UInt8((cookie >> (8 * (3 - UInt32(k)))) & 0xff) : buf[v + 4 + k]
          }
          return Mapped(ip: "\(o[0]).\(o[1]).\(o[2]).\(o[3])", port: port)
        }
        i = v + len + ((4 - len % 4) % 4)              // attributes are 4-byte aligned
      }
    }
    return nil
  }
}

/// This machine's address on its own network. Needed because the two most likely
/// topologies want different answers: two Macs in one house should talk over the
/// LAN (lower latency, and sending to your own public address needs NAT
/// hairpinning, which plenty of routers simply refuse), while two Macs in two
/// houses have no choice but the public mapping. Gathering both and choosing is
/// what every real implementation does, and it is four lines here.
func localIPv4() -> String? {
  var ifap: UnsafeMutablePointer<ifaddrs>?
  guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
  defer { freeifaddrs(ifap) }
  var best: String?
  var p: UnsafeMutablePointer<ifaddrs>? = first
  while let cur = p {
    let f = cur.pointee
    if let sa = f.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
       (f.ifa_flags & UInt32(IFF_UP)) != 0, (f.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 {
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(NI_MAXHOST),
                     nil, 0, NI_NUMERICHOST) == 0 {
        let ip = String(cString: host)
        let name = String(cString: f.ifa_name)
        // en0 first when present: on a Mac that is the real wifi or ethernet, and
        // the alternatives are utun/bridge/awdl interfaces that route nowhere useful.
        if name.hasPrefix("en") { return ip }
        if best == nil { best = ip }
      }
    }
    p = f.ifa_next
  }
  return best
}

// ── Rendezvous ──────────────────────────────────────────────────────────────
//
// The one thing two Macs in two houses cannot work out alone: what the other
// side's NAT calls it. Each publishes the mapping STUN gave it and reads the
// other's back. Then both start sending, and the outbound packets create the
// inbound holes -- which is why BOTH sides must send even before either has
// received anything.
enum Rendezvous {
  struct Peer { let id: String; let ip: String; let port: UInt16; let ageMs: Int; let localIP: String?; let localPort: UInt16? }

  /// Publish our address and return whoever else is in the room.
  static func exchange(room: String, me: String, addr: String?, local: String? = nil, base: String = "https://room.tokkah.com") -> [Peer] {
    var u = "\(base)/api/room/\(room)/rv?me=\(me)"
    if let a = addr { u += "&addr=\(a)" }
    if let l = local { u += "&local=\(l)" }
    guard let url = URL(string: u) else { return [] }
    var out: [Peer] = []
    let sem = DispatchSemaphore(value: 0)
    var req = URLRequest(url: url)
    req.timeoutInterval = 8
    req.cachePolicy = .reloadIgnoringLocalCacheData
    URLSession.shared.dataTask(with: req) { d, _, _ in
      defer { sem.signal() }
      guard let d,
            let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let arr = o["peers"] as? [[String: Any]] else { return }
      for p in arr {
        guard let a = p["addr"] as? String, let id = p["id"] as? String else { continue }
        let bits = a.split(separator: ":")
        guard bits.count == 2, let port = UInt16(bits[1]) else { continue }
        var lip: String?; var lport: UInt16?
        if let l = p["local"] as? String {
          let lb = l.split(separator: ":")
          if lb.count == 2, let lp = UInt16(lb[1]) { lip = String(lb[0]); lport = lp }
        }
        out.append(Peer(id: id, ip: String(bits[0]), port: port,
                        ageMs: (p["ageMs"] as? Int) ?? 0, localIP: lip, localPort: lport))
      }
    }.resume()
    _ = sem.wait(timeout: .now() + 10)
    return out
  }
}
