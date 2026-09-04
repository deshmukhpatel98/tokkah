import Foundation
import Darwin

// ── THE FAR-AWAY TEST ────────────────────────────────────────────────────────
//
// Two Macs in one room in Delhi cannot tell you what a call to the other side
// of the planet feels like. This does: with the test on, every packet of the
// call -- both directions -- is sent to a relay that Cloudflare places in South
// America (Durable Object `locationHint: "sam"`; Santiago / Buenos Aires / São
// Paulo are the far side of the earth from Delhi) and comes back. That is what
// one person sitting behind a VPN in Santiago would do to the call: THEIR
// packets go out via Santiago, and everything sent TO them goes via Santiago
// too. Both directions cross, so both ends relay -- there is no "near" end in
// the physics, only in the label.
//
// Pure Cloudflare, by request: no VPN, no third party. The Mac opens one
// WebSocket to room.tokkah.com; Cloudflare's nearest edge (Delhi) carries it
// over Cloudflare's own backbone to the object in South America, which hands
// each datagram to the other Mac's WebSocket. The relay's own round trip is
// measured every two seconds with a ping the object answers, so the screen can
// say how far away the relay actually is -- and say so honestly when a hint
// was not honoured and the object landed somewhere near.
//
// Media from the relay arrives on a loopback socket this class owns and is
// re-sent to the app's own media port, so the receive loop reads it exactly as
// it reads a packet from the network. `Wire` knows that socket's port and
// treats packets from it as the locked path -- never adopted, never "off path".
final class CloudflareTunnel {
  let relayRoom: String
  private(set) var isConnected = false
  private(set) var active = false
  /// The relay's own round trip, ms; -1 until measured.
  private(set) var relayRttMs: Double = -1
  /// How many sockets the relay object currently holds -- ours included. Media
  /// is routed only at 2: one end alone on the relay would be sending its half of
  /// the call into a room with nobody in it. Pushed by the object on every join
  /// and leave, and carried on every pong for repair.
  private(set) var relayPeers = 0
  private(set) var packetsSent = 0, packetsRecv = 0, bytesSent = 0, bytesRecv = 0
  private(set) var loopbackPort: UInt16 = 0
  private(set) var lastError = ""
  private(set) var relayCountry = ""
  private(set) var relayCountryCode = ""
  private(set) var relayCity = ""
  private(set) var relayColo = ""
  private(set) var myCountry = ""
  private(set) var myCity = ""
  private(set) var peerCountry = ""
  private(set) var peerCity = ""

  private var wsTask: URLSessionWebSocketTask?
  private var session: URLSession?
  private var loopbackFd: Int32 = -1
  private let targetPort: UInt16
  private let base: String
  private let lock = NSLock()
  private var generation = 0
  private var pinger: Thread?

  init(relayRoom: String, targetPort: UInt16, base: String = Server.base) {
    self.relayRoom = relayRoom
    self.targetPort = targetPort
    self.base = base
    loopbackFd = socket(AF_INET, SOCK_DGRAM, 0)
    if loopbackFd >= 0 {
      fcntl(loopbackFd, F_SETFD, FD_CLOEXEC)
      var me = sockaddr_in()
      me.sin_family = sa_family_t(AF_INET)
      me.sin_port = 0
      me.sin_addr.s_addr = inet_addr("127.0.0.1")
      let r = withUnsafePointer(to: &me) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(loopbackFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
      }
      var got = sockaddr_in()
      var len = socklen_t(MemoryLayout<sockaddr_in>.size)
      if r == 0, withUnsafeMutablePointer(to: &got, { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(loopbackFd, $0, &len) } }) == 0 {
        loopbackPort = UInt16(bigEndian: got.sin_port)
      }
    }
  }

  deinit {
    setActive(false)
    if loopbackFd >= 0 { Darwin.close(loopbackFd) }
  }

  /// Packets the relay handed us come from here. Checked per packet on the
  /// receive thread: two integer compares, nothing allocated.
  func isLoopbackSource(_ a: sockaddr_in) -> Bool {
    loopbackPort != 0 && UInt16(bigEndian: a.sin_port) == loopbackPort
      && UInt32(bigEndian: a.sin_addr.s_addr) == 0x7F00_0001
  }

  /// Media goes through the relay only while it is wanted AND the socket is up.
  /// Before it connects, and if it drops, media takes the direct path -- a test
  /// that silences the call while it warms up would be testing nothing.
  var isRouting: Bool {
    lock.lock(); defer { lock.unlock() }
    return active && isConnected && relayPeers >= 2
  }

  /// Switch the relay on or off. On: open the WebSocket and keep it open, retrying
  /// every few seconds while wanted. Off: close it, keep the object -- `Wire`
  /// holds one reference for the life of the call, so a toggle never swaps a
  /// pointer under the send thread.
  func setActive(_ want: Bool) {
    lock.lock()
    if active == want { lock.unlock(); return }
    active = want
    generation += 1
    let gen = generation
    let task = wsTask
    wsTask = nil
    isConnected = false
    relayRttMs = -1
    relayPeers = 0
    lock.unlock()
    task?.cancel(with: .normalClosure, reason: nil)
    if want {
      fputs("far test: on -- reaching Cloudflare's relay in South America (\(relayRoom))\n", stderr)
      Metrics.count("far_test_on")
      open(gen)
      let t = Thread { [weak self] in self?.pingLoop(gen) }
      t.name = "far-test-ping"
      t.start()
      pinger = t
    } else {
      fputs("far test: off -- back on the direct path\n", stderr)
      Metrics.count("far_test_off")
    }
  }

  private func open(_ gen: Int) {
    lock.lock()
    guard active, generation == gen, wsTask == nil else { lock.unlock(); return }
    var host = base
    for p in ["https://", "http://"] where host.hasPrefix(p) { host.removeFirst(p.count) }
    while host.hasSuffix("/") { host.removeLast() }
    let scheme = base.hasPrefix("http://") ? "ws" : "wss"
    guard let url = URL(string: "\(scheme)://\(host)/api/room/\(relayRoom)/cf-relay") else {
      lastError = "bad relay url"; lock.unlock(); return
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 10
    cfg.timeoutIntervalForResource = 24 * 3600
    let sess = URLSession(configuration: cfg)
    session = sess
    let task = sess.webSocketTask(with: url)
    task.maximumMessageSize = 1 << 20
    wsTask = task
    lock.unlock()
    task.resume()
    receive(task, gen)
  }

  private func receive(_ task: URLSessionWebSocketTask, _ gen: Int) {
    task.receive { [weak self] result in
      guard let self else { return }
      self.lock.lock()
      let live = self.active && self.generation == gen && self.wsTask === task
      self.lock.unlock()
      guard live else { return }
      switch result {
      case .success(let msg):
        switch msg {
        case .data(let d): self.deliver(d)
        case .string(let s): self.control(s)
        @unknown default: break
        }
        self.receive(task, gen)
      case .failure(let err):
        self.lock.lock()
        self.isConnected = false
        self.relayRttMs = -1
        self.relayPeers = 0
        self.wsTask = nil
        self.lastError = err.localizedDescription
        self.lock.unlock()
        fputs("far test: relay dropped (\(err.localizedDescription)) -- media is direct until it is back\n", stderr)
        Metrics.count("far_test_drops")
      }
    }
  }

  /// Once a second while wanted: reconnect if down, ping if up.
  private func pingLoop(_ gen: Int) {
    var n = 0
    while true {
      Thread.sleep(forTimeInterval: 1.0)
      lock.lock()
      let live = active && generation == gen
      let task = wsTask
      lock.unlock()
      guard live else { return }
      if task == nil { open(gen); continue }
      n += 1
      guard n % 2 == 0 else { continue }
      let t = Clock.now()
      task?.send(.string("{\"type\":\"xcont-ping\",\"t\":\(t)}")) { _ in }
    }
  }

  private func control(_ s: String) {
    guard let d = s.data(using: .utf8),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let type = j["type"] as? String else { return }
    let peers = (j["peers"] as? NSNumber)?.intValue
    switch type {
    case "xcont-welcome":
      lock.lock()
      let first = !isConnected
      isConnected = true
      if let rc = j["relayCountry"] as? String, !rc.isEmpty { relayCountry = rc }
      if let rcc = j["relayCountryCode"] as? String, !rcc.isEmpty { relayCountryCode = rcc }
      if let rci = j["relayCity"] as? String, !rci.isEmpty { relayCity = rci }
      if let rco = j["relayColo"] as? String, !rco.isEmpty { relayColo = rco }
      if let mc = j["country"] as? String, !mc.isEmpty { myCountry = mc }
      if let mci = j["city"] as? String, !mci.isEmpty { myCity = mci }
      let rCountry = relayCountry
      let rCity = relayCity
      lock.unlock()
      if first {
        let cName = FarTest.countryName(codeOrName: rCountry.isEmpty ? "Brazil" : rCountry)
        let loc = cName.isEmpty ? "south america" : "\(cName)\(rCity.isEmpty ? "" : " (\(rCity))")"
        fputs("far test: relay reached (\(j["ingress"] as? String ?? "?") -> \(loc))\n", stderr)
        Metrics.count("far_test_connects")
        Metrics.count("vpn_connects")
      }
      if let peers { notePeers(peers) }
    case "xcont-peers":
      lock.lock()
      if let rc = j["relayCountry"] as? String, !rc.isEmpty { relayCountry = rc }
      if let rcc = j["relayCountryCode"] as? String, !rcc.isEmpty { relayCountryCode = rcc }
      if let rci = j["relayCity"] as? String, !rci.isEmpty { relayCity = rci }
      if let rco = j["relayColo"] as? String, !rco.isEmpty { relayColo = rco }
      if let pc = j["peerCountry"] as? String, !pc.isEmpty { peerCountry = pc }
      if let pci = j["peerCity"] as? String, !pci.isEmpty { peerCity = pci }
      lock.unlock()
      if let peers { notePeers(peers) }
    case "xcont-pong":
      lock.lock()
      if let rc = j["relayCountry"] as? String, !rc.isEmpty { relayCountry = rc }
      if let rcc = j["relayCountryCode"] as? String, !rcc.isEmpty { relayCountryCode = rcc }
      if let rci = j["relayCity"] as? String, !rci.isEmpty { relayCity = rci }
      if let rco = j["relayColo"] as? String, !rco.isEmpty { relayColo = rco }
      lock.unlock()
      if let peers { notePeers(peers) }
      // `t` went out as an integer host-clock stamp and comes back verbatim.
      var t: UInt64 = 0
      if let n = j["t"] as? NSNumber { t = n.uint64Value }
      guard t != 0 else { return }
      let rtt = Clock.ms(Clock.now() - t)
      lock.lock()
      relayRttMs = relayRttMs < 0 ? rtt : relayRttMs * 0.7 + rtt * 0.3
      let shown = relayRttMs
      lock.unlock()
      Metrics.mark("far_test_relay_rtt_ms", Int(shown))
    default: break
    }
  }

  private func notePeers(_ n: Int) {
    lock.lock()
    let was = relayPeers >= 2
    relayPeers = n
    let now = active && isConnected && n >= 2
    let rCountry = relayCountry
    lock.unlock()
    if now != was {
      let cName = FarTest.countryName(codeOrName: rCountry.isEmpty ? "South America" : rCountry)
      fputs(now ? "far test: both ends on the relay -- routing the call through \(cName)\n"
                : "far test: the other end is not on the relay -- media is direct until it is\n", stderr)
    }
  }

  private func deliver(_ d: Data) {
    lock.lock()
    packetsRecv += 1
    bytesRecv += d.count
    let fd = loopbackFd, port = targetPort
    lock.unlock()
    guard fd >= 0, port > 0 else { return }
    var dst = sockaddr_in()
    dst.sin_family = sa_family_t(AF_INET)
    dst.sin_port = port.bigEndian
    dst.sin_addr.s_addr = inet_addr("127.0.0.1")
    d.withUnsafeBytes { raw in
      guard let b = raw.baseAddress else { return }
      _ = withUnsafePointer(to: &dst) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          sendto(fd, b, d.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
  }

  /// One sealed datagram, relay-bound. False means "not routing": the caller
  /// sends it directly instead.
  func send(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
    lock.lock()
    guard active, isConnected, let task = wsTask else { lock.unlock(); return false }
    packetsSent += 1
    bytesSent += n
    lock.unlock()
    task.send(.data(Data(bytes: p, count: n))) { _ in }
    return true
  }
}

/// The switch, shared by the menu, the in-call sheet, `--far-test`, and the
/// far end. The test is on for the call if EITHER end asked for it: the other
/// Mac learns this from a sealed beat (`XMAGIC`) once a second, and forgets it
/// five seconds after the beats stop.
final class FarTest {
  nonisolated(unsafe) static var shared: FarTest?

  let room: String
  private let wire: Wire
  private let tunnel: CloudflareTunnel
  private let lock = NSLock()
  private(set) var mine = false
  private(set) var theirs = false
  private var theirsAt: UInt64 = 0

  init(room: String, wire: Wire) {
    self.room = room
    self.wire = wire
    // Its own object, never the call's: the call's room object was created by
    // the first Mac to touch it and lives near Delhi. Only a NEW object takes a
    // placement hint, so the relay gets a name of its own with the prefix the
    // worker pins to South America.
    tunnel = CloudflareTunnel(relayRoom: "xcont-\(room)", targetPort: wire.boundPort)
    wire.cfTunnel = tunnel
    wire.onPeerFarTest = { [weak self] on in self?.notePeer(on) }
  }

  var on: Bool { lock.lock(); defer { lock.unlock() }; return mine || theirs }
  var connected: Bool { tunnel.isRouting }
  var relayRttMs: Double { tunnel.relayRttMs }

  func setMine(_ want: Bool) {
    lock.lock()
    let changed = mine != want
    mine = want
    lock.unlock()
    guard changed else { return }
    Metrics.fact("far_test", want ? "on" : "off")
    // Three copies now, then the once-a-second beat: UDP, and the other end
    // decides on this bit whether to open its own relay socket.
    for _ in 0..<3 { wire.sendFarTest(on: want) }
    apply()
  }

  func toggle() { setMine(!mine) }

  private func notePeer(_ on: Bool) {
    lock.lock()
    let changed = theirs != on
    theirs = on
    theirsAt = Clock.now()
    lock.unlock()
    if changed {
      fputs("far test: the other end turned it \(on ? "on" : "off")\n", stderr)
      apply()
    }
  }

  /// Once a second from the status tick in main.swift.
  func tick() {
    lock.lock()
    let m = mine
    var expired = false
    if theirs, theirsAt != 0, Clock.msSigned(Clock.now(), theirsAt) > 5000 { theirs = false; expired = true }
    lock.unlock()
    if m { wire.sendFarTest(on: true) }
    if expired {
      fputs("far test: the other end's beat stopped -- treating it as off\n", stderr)
      apply()
    }
  }

  private func apply() { tunnel.setActive(on) }

  var relayCountry: String { tunnel.relayCountry }
  var relayCity: String { tunnel.relayCity }
  var myCountry: String { tunnel.myCountry }
  var peerCountry: String { tunnel.peerCountry }

  static func countryName(codeOrName: String) -> String {
    let trimmed = codeOrName.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "" }
    if trimmed.count == 2 {
      if let name = Locale(identifier: "en_US").localizedString(forRegionCode: trimmed.uppercased()) {
        return name
      }
    }
    return trimmed
  }

  var activeCountry: String {
    if !tunnel.relayCountry.isEmpty {
      return FarTest.countryName(codeOrName: tunnel.relayCountry)
    }
    return "Brazil"
  }

  /// What the sheet and the status pill say. Plain words; the one number is the
  /// number this feature exists to show.
  var sentence: String {
    guard on else {
      return "Off. Turn it on to route this call via an integrated VPN."
    }
    let who = mine ? "" : " (turned on from the other end)"
    let cName = activeCountry
    let loc = tunnel.relayCity.isEmpty ? cName : "\(cName) (\(tunnel.relayCity))"
    guard connected else { return "Turning on\(who)… reaching integrated VPN in \(loc)." }
    let rtt = relayRttMs
    if rtt < 0 { return "On\(who). Every packet is routed via VPN in \(loc). Measuring the relay…" }
    return "On\(who). Every packet is routed via VPN in \(loc). Relay round trip \(Int(rtt)) ms."
  }

  /// The per-2-second log line: counts and the relay's round trip.
  var relayLine: String {
    let rtt = tunnel.relayRttMs
    return "far test: relay sent \(tunnel.packetsSent) recv \(tunnel.packetsRecv), \(rtt < 0 ? -1 : Int(rtt)) ms round trip"
      + (tunnel.isRouting ? "" : " (not connected -- media is direct)")
  }

  var short: String {
    guard on else { return "Integrated VPN off" }
    let cName = activeCountry
    guard connected else { return "VPN: reaching \(cName)…" }
    let rtt = relayRttMs
    return rtt < 0 ? "VPN: routed via \(cName)" : "VPN: routed via \(cName) (\(Int(rtt)) ms)"
  }
}
