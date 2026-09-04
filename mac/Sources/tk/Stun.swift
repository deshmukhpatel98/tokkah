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
      if let m = parseBindingReply(buf, Int(n), txid: txid) { return m }
    }
    return nil
  }

  /// One Binding reply, parsed on its own so it can be fuzzed: this is the first
  /// packet a stranger on the path can put in front of this app, before any key
  /// exists. Returns nil for anything that is not OUR successful reply carrying an
  /// IPv4 mapped address. `buf` may be longer than `n`; nothing past `n` is read.
  static func parseBindingReply(_ buf: [UInt8], _ n: Int, txid: [UInt8]) -> Mapped? {
    guard n >= 20, buf.count >= n, txid.count == 12 else { return nil }
    guard buf[0] == 0x01, buf[1] == 0x01 else { return nil }             // Binding Success
    for i in 0..<12 where buf[8 + i] != txid[i] { return nil }           // not our transaction
    var i = 20
    let end = min(20 + (Int(buf[2]) << 8 | Int(buf[3])), n)
    while i + 4 <= end {
      let type = Int(buf[i]) << 8 | Int(buf[i + 1])
      let len = Int(buf[i + 2]) << 8 | Int(buf[i + 3])
      let v = i + 4
      // 0x0020 XOR-MAPPED-ADDRESS, 0x0001 MAPPED-ADDRESS (older servers).
      if (type == 0x0020 || type == 0x0001), len >= 8, v + len <= n, buf[v + 1] == 0x01 {
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
  struct Peer {
    let id: String
    let ip: String
    let port: UInt16
    let ageMs: Int
    let localIP: String?
    let localPort: UInt16?
    let relayIP: String?
    let relayPort: UInt16?
    let country: String?
    let city: String?
    let isVpn: Bool

    init(id: String, ip: String, port: UInt16, ageMs: Int, localIP: String?, localPort: UInt16?,
         relayIP: String?, relayPort: UInt16?, country: String? = nil, city: String? = nil, isVpn: Bool = false) {
      self.id = id; self.ip = ip; self.port = port; self.ageMs = ageMs
      self.localIP = localIP; self.localPort = localPort
      self.relayIP = relayIP; self.relayPort = relayPort
      self.country = country; self.city = city; self.isVpn = isVpn
    }
  }

  nonisolated(unsafe) static var myCountry: String = ""
  nonisolated(unsafe) static var myCity: String = ""
  nonisolated(unsafe) static var myIsVpn: Bool = false
  nonisolated(unsafe) static var peerCountry: String = ""
  nonisolated(unsafe) static var peerCity: String = ""
  nonisolated(unsafe) static var peerIsVpn: Bool = false

  static func reset() {
    myCountry = ""
    myCity = ""
    myIsVpn = false
    peerCountry = ""
    peerCity = ""
    peerIsVpn = false
  }

  /// Publish our address and return whoever else is in the room.
  ///
  /// ── nil IS NOT AN EMPTY ROOM ────────────────────────────────────────────────
  ///
  /// This returned `[]` for both "the directory says nobody else is here" and
  /// "the request never completed", and for as long as the only consumer was
  /// "keep waiting" that difference cost nothing. It is not free any more: the
  /// room directory is now the evidence that decides whether a peer who went
  /// quiet has LEFT or is coming back, and one launch with no wifi would have
  /// read as a departure and ended a call nobody hung up on.
  ///
  /// `blind-instruments-report-negatives` -- an instrument that cannot see the
  /// event returns the same value as a real negative. So the two answers are two
  /// values, and the caller that only wants to keep waiting still writes `?? []`.
  static func exchange(room: String, me: String, addr: String?, local: String? = nil,
                       relay: String? = nil, base: String = Server.base) -> [Peer]? {
    var u = "\(base)/api/room/\(room)/rv?me=\(me)"
    if let a = addr { u += "&addr=\(a)" }
    if let l = local { u += "&local=\(l)" }
    if let r = relay { u += "&relay=\(r)" }
    guard let url = URL(string: u) else { return nil }
    var out: [Peer]?
    let sem = DispatchSemaphore(value: 0)
    var req = URLRequest(url: url)
    req.timeoutInterval = 8
    req.cachePolicy = .reloadIgnoringLocalCacheData
    Http.session.dataTask(with: req) { d, _, _ in
      defer { sem.signal() }
      guard let d,
            let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let arr = o["peers"] as? [[String: Any]] else { return }
      if let mc = o["country"] as? String, !mc.isEmpty { myCountry = FarTest.countryName(codeOrName: mc) }
      if let mci = o["city"] as? String, !mci.isEmpty { myCity = mci }
      if let mv = o["isVpn"] as? Bool { myIsVpn = mv }
      // Assigned HERE and not before the guards: an answer that arrived and did
      // not parse is not an answer about the room, and promoting it to "the room
      // is empty" is the same mistake in a different costume.
      out = []
      for p in arr {
        guard let a = p["addr"] as? String, let id = p["id"] as? String else { continue }
        let bits = a.split(separator: ":")
        guard bits.count == 2, let port = UInt16(bits[1]) else { continue }
        var lip: String?; var lport: UInt16?
        if let l = p["local"] as? String {
          let lb = l.split(separator: ":")
          if lb.count == 2, let lp = UInt16(lb[1]) { lip = String(lb[0]); lport = lp }
        }
        var rip: String?; var rport: UInt16?
        if let r = p["relay"] as? String {
          let rb = r.split(separator: ":")
          if rb.count == 2, let rp = UInt16(rb[1]) { rip = String(rb[0]); rport = rp }
        }
        let pCountryRaw = p["country"] as? String
        let pCountry = pCountryRaw.map { FarTest.countryName(codeOrName: $0) }
        let pCity = p["city"] as? String
        let pIsVpn = (p["isVpn"] as? Bool) ?? false
        if let pCountry, !pCountry.isEmpty {
          peerCountry = pCountry
          peerCity = pCity ?? ""
        }
        peerIsVpn = pIsVpn
        out?.append(Peer(id: id, ip: String(bits[0]), port: port,
                         ageMs: (p["ageMs"] as? Int) ?? 0, localIP: lip, localPort: lport,
                         relayIP: rip, relayPort: rport, country: pCountry, city: pCity, isVpn: pIsVpn))
      }
    }.resume()
    _ = sem.wait(timeout: .now() + 10)
    return out
  }
}

// ── PAYING THE COLD START BEFORE ANYBODY IS WAITING ─────────────────────────
//
// A room's durable object costs **1108 ms** on the first request that touches it
// (median, n=27, range 883-2604 -- the measurement is in CONTACTS.md). Every
// call this app places mints a brand new room name, so almost every call pays
// that cost by construction, on the one path that is supposed to feel instant.
//
// The fix has been deployed on the server since before this app existed:
// `GET /api/room/<code>/warm` creates the object and returns `{warm:true}`. The
// web client has fired it for months and records the same figure in its own
// comment. `grep -rn "/warm" mac/Sources/tk` returned NOTHING until this file --
// a shipped, measured, free 1.1 s that the flagship client never asked for.
//
// Three rules, and each one is a bug that would otherwise be written here:
//
//   * FIRE AND FORGET. This is a prefetch. It must never be something the join
//     path waits on -- a warm that hangs would then be strictly worse than no
//     warm at all, which is the shape of `composed-threshold-hides-latency`.
//   * CONCURRENTLY WITH THE RING, not before it. Warming is itself a stateful
//     hop and costs ~127 ms; spending it in front of the ring would move the
//     delay onto the callee's phone instead of removing it.
//   * ONCE PER ROOM PER PROCESS. The front door fires this on focus, on hover
//     and on click, and three round trips for one room is two wasted.
enum Warm {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var asked = Set<String>()

  /// Touch a room so its object exists by the time somebody joins it. Returns
  /// immediately, always. `room` is trusted to be a sanitised room name -- every
  /// caller has already validated it, because an unvalidated one would not be
  /// joinable either.
  static func room(_ room: String, why: String = "") {
    guard !room.isEmpty else { return }
    lock.lock()
    let fresh = asked.insert(room).inserted
    lock.unlock()
    guard fresh else { return }
    guard let url = URL(string: "\(Server.base)/api/room/\(room)/warm") else { return }
    var req = URLRequest(url: url)
    // Shorter than the rendezvous timeout on purpose. Nothing waits for this, so
    // a request still outstanding when the call connects is pure waste holding a
    // connection open.
    req.timeoutInterval = 5
    req.cachePolicy = .reloadIgnoringLocalCacheData
    let began = Date()
    Http.session.dataTask(with: req) { d, resp, err in
      let ms = Int(Date().timeIntervalSince(began) * 1000)
      let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
      // On stderr and not silent: a warm that has started failing is invisible
      // in every other signal this app has -- the call still works, it is just
      // slow again, which is exactly the regression nobody would find.
      if let err {
        fputs("warm: \(room) failed after \(ms) ms -- \(err.localizedDescription)\n", stderr)
        Metrics.count("warm_fail")
        return
      }
      fputs("warm: \(room) \(code) in \(ms) ms\(why.isEmpty ? "" : " -- " + why)\n", stderr)
      Metrics.count(code == 200 ? "warm_ok" : "warm_odd")
      Metrics.mark("warm_ms", ms)
      _ = d
    }.resume()
  }

  /// For the tests: forget what this process has already warmed.
  static func forgetForTests() { lock.lock(); asked.removeAll(); lock.unlock() }
}
