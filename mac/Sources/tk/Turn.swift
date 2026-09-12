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
//
// ── WHY THIS RELAY NEVER CARRIED A CALL BEFORE 0.162.0 ──────────────────────
//
// Found on the first call between two homes (2026-09-12, Airtel <-> Excitel,
// seven attempts, not one packet either way). Three faults, each alone enough:
//
//  1. ChannelBind sent its channel number as attribute 0x001C. CHANNEL-NUMBER
//     is 0x000C (RFC 5766 §14.1); 0x001C is MESSAGE-INTEGRITY-SHA256, a
//     comprehension-required attribute with a nonsense value. Every bind was
//     refused: 0 of 109 in this Mac's log, and the failure line carried no
//     error code, so the same string meant "malformed" and "timed out".
//  2. Each call is a new process on the same UDP port, and the previous
//     process never gave its allocation back. The server still held that
//     10-minute lease on the identical 5-tuple, so the next Allocate got 437
//     (Allocation Mismatch) -- 234 times in this log, every attempt after the
//     first in any ten-minute window. The one route that works between two
//     NATed homes was refused exactly when somebody tried again.
//  3. A packet the relay forwards from a peer we have a permission for but no
//     channel to arrives as a STUN Data Indication, not ChannelData. `unwrap`
//     only knew ChannelData, so the far end's handshake -- which did reach our
//     relay -- was counted as pre-key noise and dropped.
//
// Now: 0x000C; the lease is released on every exit (Refresh, LIFETIME 0) and
// remembered on disk so a process that crashed still gets its lease evicted by
// the next one with the credentials it left behind; Data Indications are
// unwrapped, and when the far end reaches this relay from an address other than
// the one the channel is bound to (a symmetric NAT gives every destination a new
// port) we answer where they actually are, as Send Indications, and re-bind the
// channel there. Allocation, permission and channel are refreshed every four
// minutes for as long as the call lasts; before, a relayed call would have died
// at ten minutes even had it started. `--selftest-turn` holds the message
// builder to the wire numbers so the first mistake cannot come back unseen.
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
  private let cookie: UInt32 = 0x2112_A442

  // ── the channel and the peer, AS SCALARS ────────────────────────────────────
  //
  // `sendChannel` runs on the capture callback and `unwrap` on the receive
  // thread; the binds run on the main thread. A String read on one thread while
  // another writes it is a torn retain (Video.swift says why). So the peer the
  // channel is bound to, and the address the far end actually reached us from,
  // are four integers under one lock -- and the text form exists for log lines
  // only, written under the same lock and read where nothing is real-time.
  private let lock = NSLock()
  private var channel: UInt16 = 0x4000
  private var prevChannel: UInt16 = 0
  private var boundAddr: UInt32 = 0        // network byte order, as sin_addr.s_addr
  private var boundPort: UInt16 = 0        // host order; 0 = no channel yet
  private var boundText = ""
  /// The peer address the permission and channel are WANTED for -- kept even
  /// when the first bind fails so the keepalive can try again.
  private var wantAddr: UInt32 = 0
  private var wantPort: UInt16 = 0
  private var permitted = false
  /// Where the far end really reached this relay from (Data Indications). Zero
  /// until one arrives; differs from the bound peer behind a symmetric NAT.
  private var indAddr: UInt32 = 0
  private var indPort: UInt16 = 0
  private var lastRebind: UInt64 = 0
  private var pendingBind: (txid: [UInt8], ch: UInt16, addr: UInt32, port: UInt16)?
  private var pendingRefresh: [UInt8]?
  private var pendingPerm: [UInt8]?
  /// Counters for the beat, read from the poll loop.
  private(set) var indications = 0, rebinds = 0, replies = 0, staleNonces = 0
  private var allocatedFd: Int32 = -1

  // ── the lease this process holds, for whoever comes next ────────────────────
  //
  // One allocation per process, so one static. `postFinalBeat` releases it on
  // every exit this app has; the file is for the exits it does not have -- a
  // crash, a kill, a Mac that lost power -- so the NEXT process can hand the
  // relay the credentials this one died holding and evict the lease itself.
  nonisolated(unsafe) private static var active: TurnClient?
  private static let activeLock = NSLock()
  static var leaseFile: URL { Identity.dir.appendingPathComponent("relay.json") }

  var relayed: String? {
    guard let ip = relayIP, let p = relayPort else { return nil }
    return "\(ip):\(p)"
  }

  var hasChannel: Bool { lock.lock(); defer { lock.unlock() }; return boundPort != 0 }
  /// The far end has reached this relay, on the channel or as an indication.
  var peerReachedRelay: Bool { lock.lock(); defer { lock.unlock() }; return indPort != 0 }

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
    Http.session.dataTask(with: req) { d, _, _ in
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

  // ── ALLOCATE ────────────────────────────────────────────────────────────────

  /// Allocate a relayed address on `fd`. MUST run before the media recv loop
  /// starts — it briefly sets a receive timeout on the same socket STUN used.
  func allocate(fd: Int32) -> Bool {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                         ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res, let sa = ai.pointee.ai_addr else {
      fputs("turn: cannot resolve \(host)\n", stderr)
      Metrics.fact("relay", "unresolved")
      return false
    }
    defer { freeaddrinfo(res) }
    memcpy(&turnAddr, sa, min(Int(ai.pointee.ai_addrlen), MemoryLayout<sockaddr_in>.size))

    var r = allocateOnce(fd: fd)
    if r.code == 437 {
      // ── THE LEASE THE LAST PROCESS DIED HOLDING ───────────────────────────
      //
      // 437 is the server saying "this 5-tuple already has an allocation". It
      // is ours -- the previous call, same port, same NAT mapping -- and it
      // stays for its full lifetime unless somebody with its credentials says
      // otherwise. The previous process wrote them down for exactly this.
      if evictStaleLease(fd: fd) {
        r = allocateOnce(fd: fd)
      } else {
        fputs("turn: allocate failed -- 437, and no lease file to evict the old allocation with\n", stderr)
      }
    }
    guard r.ok, let rel = r.relayed else {
      // ── SAY WHICH FAILURE IT WAS ────────────────────────────────────────────
      //
      // `allocate failed` was the same string for a 400, a 401, a 403 and a
      // socket that never answered -- a blind instrument returning the same
      // value as a real negative, which is how the missing REQUESTED-TRANSPORT
      // attribute stayed hidden for so long.
      if r.noReply {
        fputs("turn: allocate failed -- no reply from \(host):\(port)\n", stderr)
        Metrics.fact("relay", "no reply")
      } else if let c = r.code {
        fputs("turn: allocate failed -- \(c)\(r.reason.isEmpty ? "" : " " + r.reason)\n", stderr)
        Metrics.fact("relay", "refused \(c)")
      } else if r.ok {
        fputs("turn: allocate succeeded with no XOR-RELAYED-ADDRESS in it\n", stderr)
        Metrics.fact("relay", "no address")
      } else {
        fputs("turn: allocate failed -- a reply that was neither success nor error\n", stderr)
        Metrics.fact("relay", "garbled")
      }
      return false
    }
    relayIP = rel.0
    relayPort = rel.1
    allocatedFd = fd
    saveLease()
    TurnClient.activeLock.lock(); TurnClient.active = self; TurnClient.activeLock.unlock()
    fputs("turn: relayed \(rel.0):\(rel.1) via \(host):\(port)\n", stderr)
    Metrics.fact("relay", "allocated")
    return true
  }

  private struct AllocResult {
    var ok = false
    var relayed: (String, UInt16)?
    var code: Int?
    var reason = ""
    var noReply = false
  }

  /// One Allocate: the unauthenticated request that earns realm and nonce, then
  /// the real one.
  private func allocateOnce(fd: Int32) -> AllocResult {
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
    auth(&attrs)
    var out = AllocResult()
    guard let r = roundTrip(fd: fd, method: 0x0003, extra: attrs, integrity: true) else {
      out.noReply = true
      return out
    }
    out.ok = r.ok
    out.relayed = r.relayed
    out.code = r.errorCode
    out.reason = r.errorReason
    return out
  }

  // ── THE LEASE FILE ──────────────────────────────────────────────────────────

  private func saveLease() {
    lock.lock(); let r = realm, nn = nonce; lock.unlock()
    let o: [String: Any] = ["host": host, "port": Int(port), "username": username,
                            "credential": credential, "realm": r, "nonce": nn,
                            "at": Date().timeIntervalSince1970]
    guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
    let f = TurnClient.leaseFile
    try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? d.write(to: f, options: .atomic)
    chmod(f.path, 0o600)
  }

  private static func clearLease() {
    try? FileManager.default.removeItem(at: leaseFile)
  }

  /// A 437 answered our Allocate: send the previous process's Refresh(0) for it.
  /// True when the server accepted the eviction (or said the lease is already
  /// gone), false when there was nothing to evict with or the server refused.
  private func evictStaleLease(fd: Int32) -> Bool {
    guard let d = try? Data(contentsOf: TurnClient.leaseFile),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let h = o["host"] as? String, let p = o["port"] as? Int,
          let u = o["username"] as? String, let c = o["credential"] as? String
    else { return false }
    guard h == host, UInt16(truncatingIfNeeded: p) == port else {
      fputs("turn: the lease on disk is for \(h):\(p), not \(host):\(port) -- not ours to evict\n", stderr)
      return false
    }
    let age = Date().timeIntervalSince1970 - ((o["at"] as? Double) ?? 0)
    let old = TurnClient(host: h, port: port, username: u, credential: c)
    old.turnAddr = turnAddr
    old.realm = (o["realm"] as? String) ?? ""
    old.nonce = (o["nonce"] as? String) ?? ""
    // Refresh with LIFETIME 0 deletes the allocation (RFC 5766 §7). The nonce
    // it was written with may be stale by now: 438 hands back a fresh one.
    var reply = old.refreshSync(fd: fd, lifetime: 0)
    if reply?.errorCode == 438 { reply = old.refreshSync(fd: fd, lifetime: 0) }
    if reply == nil && old.realm.isEmpty {
      // No realm saved: earn one with an unauthenticated Refresh, then retry.
      _ = old.roundTrip(fd: fd, method: 0x0004, extra: [(0x000D, old.u32(0))])
      reply = old.refreshSync(fd: fd, lifetime: 0)
    }
    TurnClient.clearLease()
    guard let r = reply else {
      fputs("turn: evicting the previous lease (\(Int(age)) s old) -- no reply\n", stderr)
      return false
    }
    // 437 here means "no such allocation" -- already gone, which is what we want.
    let gone = r.ok || r.errorCode == 437
    fputs("turn: evicting the previous lease (\(Int(age)) s old) -- "
        + (r.ok ? "released" : "\(r.errorCode ?? 0) \(r.errorReason)")
        + (gone ? "\n" : " -- REFUSED\n"), stderr)
    return gone
  }

  private func refreshSync(fd: Int32, lifetime: UInt32) -> Reply? {
    var attrs: [(UInt16, [UInt8])] = [(0x000D, u32(lifetime))]
    auth(&attrs)
    return roundTrip(fd: fd, method: 0x0004, extra: attrs, integrity: true)
  }

  // ── RELEASE: on every exit this app has ─────────────────────────────────────

  /// Give the allocation back. Fire-and-forget: one datagram, no wait -- the
  /// receive loop may still own the socket, and an exit must not block on a
  /// relay. The lease file goes with it.
  func release() {
    let fd = allocatedFd
    guard fd >= 0 else { return }
    allocatedFd = -1
    var attrs: [(UInt16, [UInt8])] = [(0x000D, u32(0))]
    auth(&attrs)
    var txid = [UInt8](repeating: 0, count: 12)
    arc4random_buf(&txid, 12)
    send(fd: fd, build(method: 0x0004, txid: txid, extra: attrs, integrity: true))
    TurnClient.clearLease()
    fputs("turn: released the relay (\(relayed ?? "?"))\n", stderr)
  }

  /// The one call `postFinalBeat` makes, safe before any allocation exists.
  static func releaseActive() {
    activeLock.lock()
    let a = active
    active = nil
    activeLock.unlock()
    a?.release()
  }

  // ── PERMISSION AND CHANNEL ──────────────────────────────────────────────────

  /// Permission + channel so media can ride the allocation toward `ip:port`.
  /// Synchronous: MUST run before the media recv loop starts, like `allocate`.
  func bindPeer(fd: Int32, ip: String, port: UInt16) -> Bool {
    let addr = inet_addr(ip)
    lock.lock(); wantAddr = addr; wantPort = port; lock.unlock()
    let xor = xorPeer(addr: addr, port: port)
    var attrs: [(UInt16, [UInt8])] = [(0x0012, xor)]        // XOR-PEER-ADDRESS
    auth(&attrs)
    let perm = roundTrip(fd: fd, method: 0x0008, extra: attrs, integrity: true)
    guard let r = perm, r.ok else {
      fputs("turn: CreatePermission \(ip):\(port) failed -- \(describe(reply: perm))\n", stderr)
      Metrics.fact("relay_channel", "permission failed")
      return false
    }
    lock.lock(); permitted = true; lock.unlock()
    let ch: UInt16 = 0x4000
    let bind = roundTrip(fd: fd, method: 0x0009, extra: channelBindAttrs(ch: ch, xor: xor), integrity: true)
    guard let r2 = bind, r2.ok else {
      fputs("turn: ChannelBind \(ip):\(port) failed -- \(describe(reply: bind))\n", stderr)
      Metrics.fact("relay_channel", "bind failed \(bind?.errorCode ?? 0)")
      return false
    }
    lock.lock()
    channel = ch
    boundAddr = addr; boundPort = port; boundText = "\(ip):\(port)"
    lock.unlock()
    Metrics.fact("relay_channel", "bound")
    return true
  }

  private func describe(reply r: Reply?) -> String {
    guard let r else { return "no reply" }
    if r.ok { return "ok" }
    if let c = r.errorCode { return "\(c)\(r.errorReason.isEmpty ? "" : " " + r.errorReason)" }
    return "garbled reply"
  }

  /// CHANNEL-NUMBER is 0x000C: a 16-bit channel in 0x4000...0x4FFF followed by
  /// two zero bytes (RFC 5766 §14.1). It was 0x001C, which is
  /// MESSAGE-INTEGRITY-SHA256 -- see the header.
  private func channelBindAttrs(ch: UInt16, xor: [UInt8]) -> [(UInt16, [UInt8])] {
    var a: [(UInt16, [UInt8])] = [(0x000C, u16(ch)), (0x0012, xor)]
    auth(&a)
    return a
  }

  /// Every four minutes for as long as the call lasts: the allocation (lifetime
  /// 600 s), and the permission and channel (300 / 600 s) -- a ChannelBind
  /// refreshes both. Fire-and-forget from a plain thread; the replies land in
  /// the receive loop, which hands them to `noteReply`.
  func keepAlive(fd: Int32) {
    var rf: [(UInt16, [UInt8])] = [(0x000D, u32(600))]
    auth(&rf)
    var t1 = [UInt8](repeating: 0, count: 12); arc4random_buf(&t1, 12)
    lock.lock(); pendingRefresh = t1; lock.unlock()
    send(fd: fd, build(method: 0x0004, txid: t1, extra: rf, integrity: true))
    lock.lock()
    let bA = boundAddr, bP = boundPort, ch = channel, wA = wantAddr, wP = wantPort
    lock.unlock()
    if bP != 0 {
      var t2 = [UInt8](repeating: 0, count: 12); arc4random_buf(&t2, 12)
      lock.lock(); pendingBind = (t2, ch, bA, bP); lock.unlock()
      send(fd: fd, build(method: 0x0009, txid: t2, extra: channelBindAttrs(ch: ch, xor: xorPeer(addr: bA, port: bP)), integrity: true))
    } else if wP != 0 {
      // The first bind failed: keep asking, at the keepalive's pace.
      var pa: [(UInt16, [UInt8])] = [(0x0012, xorPeer(addr: wA, port: wP))]
      auth(&pa)
      var t3 = [UInt8](repeating: 0, count: 12); arc4random_buf(&t3, 12)
      lock.lock(); pendingPerm = t3; lock.unlock()
      send(fd: fd, build(method: 0x0008, txid: t3, extra: pa, integrity: true))
      requestRebind(fd: fd, addr: wA, port: wP, force: true)
    }
  }

  /// A ChannelBind toward `addr:port` on a fresh channel number, sent without
  /// waiting. Rate-limited: once per two seconds unless forced.
  private func requestRebind(fd: Int32, addr: UInt32, port: UInt16, force: Bool) {
    lock.lock()
    let now = Clock.now()
    if !force, lastRebind != 0, Clock.msSigned(now, lastRebind) < 2000 { lock.unlock(); return }
    lastRebind = now
    // A channel cannot be re-pointed until it expires, so each re-bind takes the
    // next number; 0x4000...0x4FFF is the range every server accepts.
    var ch = channel &+ 1
    if ch > 0x4FFF || ch < 0x4000 { ch = 0x4000 }
    if ch == channel { ch = channel == 0x4000 ? 0x4001 : 0x4000 }
    var txid = [UInt8](repeating: 0, count: 12); arc4random_buf(&txid, 12)
    pendingBind = (txid, ch, addr, port)
    rebinds += 1
    lock.unlock()
    send(fd: fd, build(method: 0x0009, txid: txid, extra: channelBindAttrs(ch: ch, xor: xorPeer(addr: addr, port: port)), integrity: true))
  }

  // ── REPLIES THAT ARRIVE ON THE MEDIA SOCKET ─────────────────────────────────

  /// A STUN-class datagram from our relay that is NOT a Data Indication: a
  /// reply to a keepalive or a re-bind. The receive loop hands these here.
  func isStunFromRelay(_ buf: UnsafePointer<UInt8>, _ n: Int, from: sockaddr_in) -> Bool {
    guard isTurnServer(from), n >= 20, buf[0] & 0xC0 == 0 else { return false }
    guard buf[4] == 0x21, buf[5] == 0x12, buf[6] == 0xA4, buf[7] == 0x42 else { return false }
    return !(buf[0] == 0x00 && buf[1] == 0x17)
  }

  func noteReply(_ buf: UnsafePointer<UInt8>, _ n: Int) {
    let bytes = Array(UnsafeBufferPointer(start: buf, count: n))
    let r = parse(bytes, n)
    let txid = Array(bytes[8..<20])
    lock.lock()
    replies += 1
    let isBind = pendingBind?.txid == txid
    let isRefresh = pendingRefresh == txid
    let isPerm = pendingPerm == txid
    let pb = pendingBind
    lock.unlock()
    if r.errorCode == 438 {
      // Stale nonce: `parse` has already taken the fresh one. Send it once more.
      lock.lock(); staleNonces += 1; lock.unlock()
      let fd = allocatedFd
      guard fd >= 0 else { return }
      if isBind, let pb {
        var t = [UInt8](repeating: 0, count: 12); arc4random_buf(&t, 12)
        lock.lock(); pendingBind = (t, pb.ch, pb.addr, pb.port); lock.unlock()
        send(fd: fd, build(method: 0x0009, txid: t, extra: channelBindAttrs(ch: pb.ch, xor: xorPeer(addr: pb.addr, port: pb.port)), integrity: true))
      } else if isRefresh {
        var rf: [(UInt16, [UInt8])] = [(0x000D, u32(600))]
        auth(&rf)
        var t = [UInt8](repeating: 0, count: 12); arc4random_buf(&t, 12)
        lock.lock(); pendingRefresh = t; lock.unlock()
        send(fd: fd, build(method: 0x0004, txid: t, extra: rf, integrity: true))
      }
      return
    }
    if isBind, let pb {
      lock.lock()
      pendingBind = nil
      if r.ok {
        if pb.ch != channel { prevChannel = channel; channel = pb.ch }
        boundAddr = pb.addr; boundPort = pb.port
        boundText = TurnClient.text(addr: pb.addr, port: pb.port)
        permitted = true
      }
      let text = boundText
      lock.unlock()
      if r.ok { fputs("turn: channel bound to \(text)\n", stderr) }
      else { fputs("turn: re-bind refused -- \(describe(reply: r))\n", stderr) }
    } else if isPerm {
      lock.lock(); pendingPerm = nil; if r.ok { permitted = true }; lock.unlock()
      if !r.ok { fputs("turn: permission refused -- \(describe(reply: r))\n", stderr) }
    } else if isRefresh {
      lock.lock(); pendingRefresh = nil; lock.unlock()
      if !r.ok { fputs("turn: refresh refused -- \(describe(reply: r)) -- the relay will lapse\n", stderr) }
    }
  }

  // ── SENDING THROUGH THE RELAY ───────────────────────────────────────────────

  /// Media toward the peer, through the allocation. ChannelData on the bound
  /// channel when the far end is where the channel points; a Send Indication to
  /// where they actually reached us from when it is not. Stack allocation only:
  /// this runs on the capture callback.
  func sendChannel(fd: Int32, _ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
    lock.lock()
    let ch = channel, bA = boundAddr, bP = boundPort, iA = indAddr, iP = indPort
    lock.unlock()
    if bP == 0 && iP == 0 { return false }
    if iP != 0 && (iA != bA || iP != bP) { return sendIndication(fd: fd, p, n, addr: iA, port: iP) }
    return sendChannelData(fd: fd, ch: ch, p, n)
  }

  private func sendChannelData(fd: Int32, ch: UInt16, _ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
    let pad = (4 - (n % 4)) % 4
    let total = 4 + n + pad
    var sent = false
    var a = turnAddr
    withUnsafeTemporaryAllocation(byteCount: total, alignment: 8) { tmp in
      let out = tmp.baseAddress!.assumingMemoryBound(to: UInt8.self)
      out[0] = UInt8(ch >> 8)
      out[1] = UInt8(ch & 0xff)
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

  /// Send Indication (0x0016): XOR-PEER-ADDRESS + DATA, no authentication --
  /// the permission installed by CreatePermission is what lets it through.
  private func sendIndication(fd: Int32, _ p: UnsafePointer<UInt8>, _ n: Int, addr: UInt32, port: UInt16) -> Bool {
    let pad = (4 - (n % 4)) % 4
    let attrs = 12 + 4 + n + pad                  // XOR-PEER-ADDRESS (4+8) + DATA (4+n+pad)
    let total = 20 + attrs
    var sent = false
    var a = turnAddr
    withUnsafeTemporaryAllocation(byteCount: total, alignment: 8) { tmp in
      let out = tmp.baseAddress!.assumingMemoryBound(to: UInt8.self)
      out[0] = 0x00; out[1] = 0x16
      out[2] = UInt8(attrs >> 8); out[3] = UInt8(attrs & 0xff)
      out[4] = 0x21; out[5] = 0x12; out[6] = 0xA4; out[7] = 0x42
      arc4random_buf(out + 8, 12)
      out[20] = 0x00; out[21] = 0x12; out[22] = 0x00; out[23] = 0x08
      out[24] = 0x00; out[25] = 0x01
      let xp = port ^ 0x2112
      out[26] = UInt8(xp >> 8); out[27] = UInt8(xp & 0xff)
      withUnsafeBytes(of: addr) { ab in            // s_addr is already in network order
        out[28] = ab[0] ^ 0x21; out[29] = ab[1] ^ 0x12; out[30] = ab[2] ^ 0xA4; out[31] = ab[3] ^ 0x42
      }
      out[32] = 0x00; out[33] = 0x13
      out[34] = UInt8(n >> 8); out[35] = UInt8(n & 0xff)
      memcpy(out + 36, p, n)
      if pad > 0 { memset(out + 36 + n, 0, pad) }
      let r = withUnsafePointer(to: &a) { pp in
        pp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          sendto(fd, out, total, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      sent = r > 0
    }
    return sent
  }

  // ── RECEIVING THROUGH THE RELAY ─────────────────────────────────────────────

  /// If this datagram is from our TURN server and carries a peer's packet --
  /// ChannelData on one of our channels, or a Data Indication -- return the
  /// payload's offset and length. Otherwise nil. Pointer arithmetic only: this
  /// is on the receive thread for every relayed packet.
  func unwrap(_ buf: UnsafePointer<UInt8>, _ n: Int, from: sockaddr_in) -> (UnsafePointer<UInt8>, Int)? {
    guard isTurnServer(from), n >= 4 else { return nil }
    if buf[0] & 0xC0 == 0x40 {                          // ChannelData
      let ch = UInt16(buf[0]) << 8 | UInt16(buf[1])
      lock.lock()
      let ours = ch == channel || (prevChannel != 0 && ch == prevChannel)
      if ours && indPort == 0 { indAddr = boundAddr; indPort = boundPort }   // on the channel: they are where it points
      lock.unlock()
      guard ours else { return nil }
      let len = Int(UInt16(buf[2]) << 8 | UInt16(buf[3]))
      guard 4 + len <= n else { return nil }
      return (buf + 4, len)
    }
    // STUN Data Indication (0x0017): a packet from a peer we hold a permission
    // for but no channel to -- or from a port other than the bound one.
    guard n >= 20, buf[0] == 0x00, buf[1] == 0x17,
          buf[4] == 0x21, buf[5] == 0x12, buf[6] == 0xA4, buf[7] == 0x42 else { return nil }
    let end = min(n, 20 + (Int(buf[2]) << 8 | Int(buf[3])))
    var i = 20
    var data: (UnsafePointer<UInt8>, Int)?
    var pAddr: UInt32 = 0, pPort: UInt16 = 0
    while i + 4 <= end {
      let at = UInt16(buf[i]) << 8 | UInt16(buf[i + 1])
      let al = Int(UInt16(buf[i + 2]) << 8 | UInt16(buf[i + 3]))
      let v = i + 4
      guard v + al <= end else { break }
      if at == 0x0013 { data = (buf + v, al) }
      if at == 0x0012, al >= 8, buf[v + 1] == 0x01 {
        pPort = (UInt16(buf[v + 2]) << 8 | UInt16(buf[v + 3])) ^ 0x2112
        let b: [UInt8] = [buf[v + 4] ^ 0x21, buf[v + 5] ^ 0x12, buf[v + 6] ^ 0xA4, buf[v + 7] ^ 0x42]
        pAddr = b.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }   // network order, as s_addr
      }
      i = v + al + ((4 - al % 4) % 4)
    }
    guard let d = data else { return nil }
    if pPort != 0 { noteIndicated(addr: pAddr, port: pPort) }
    return d
  }

  /// The far end reached this relay from `addr:port`. If that is not where the
  /// channel points, answer there from now on and move the channel.
  private func noteIndicated(addr: UInt32, port: UInt16) {
    lock.lock()
    indications += 1
    let changed = addr != indAddr || port != indPort
    indAddr = addr; indPort = port
    let offChannel = addr != boundAddr || port != boundPort
    let fd = allocatedFd
    lock.unlock()
    guard offChannel, fd >= 0 else { return }
    if changed {
      fputs("turn: the far end reaches this relay from \(TurnClient.text(addr: addr, port: port))"
          + " -- answering there and moving the channel\n", stderr)
    }
    requestRebind(fd: fd, addr: addr, port: port, force: false)
  }

  // ── STUN plumbing ───────────────────────────────────────────────────────────

  struct Reply {
    var ok = false
    var relayed: (String, UInt16)?
    /// ERROR-CODE as the wire spells it: 400, 401, 403, 437, 438, 486.
    var errorCode: Int?
    var errorReason = ""
  }

  private func send(fd: Int32, _ pkt: [UInt8]) {
    var a = turnAddr
    _ = pkt.withUnsafeBufferPointer { b in
      withUnsafePointer(to: &a) { pp in
        pp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          sendto(fd, b.baseAddress!, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
  }

  private func roundTrip(fd: Int32, method: UInt16, extra: [(UInt16, [UInt8])],
                         integrity: Bool = false, timeoutMs: Int = 800) -> Reply? {
    var txid = [UInt8](repeating: 0, count: 12)
    for i in 0..<12 { txid[i] = UInt8.random(in: 0...255) }
    send(fd: fd, build(method: method, txid: txid, extra: extra, integrity: integrity))
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

  /// Internal rather than private so `Fuzz.parsers` can reach it: these are
  /// bytes anyone on the path can send before a key exists.
  func parse(_ buf: [UInt8], _ n: Int) -> Reply {
    var out = Reply()
    guard n >= 20 else { return out }
    let type = UInt16(buf[0]) << 8 | UInt16(buf[1])
    let cls = type & 0x0110
    if cls == 0x0110 {                      // error
      var i = 20
      let end = min(n, 20 + (Int(buf[2]) << 8 | Int(buf[3])))
      while i + 4 <= end {
        let at = UInt16(buf[i]) << 8 | UInt16(buf[i + 1])
        let al = Int(UInt16(buf[i + 2]) << 8 | UInt16(buf[i + 3]))
        let v = i + 4
        // Under the lock: a 438 rewrites the nonce on the RECEIVE thread while
        // the keepalive thread may be reading it into a request.
        if at == 0x0014, v + al <= n, let s = String(bytes: buf[v..<v+al], encoding: .utf8) { lock.lock(); realm = s; lock.unlock() }
        if at == 0x0015, v + al <= n, let s = String(bytes: buf[v..<v+al], encoding: .utf8) { lock.lock(); nonce = s; lock.unlock() }
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

  /// Internal so the self-test can hold the builder to the wire numbers.
  func build(method: UInt16, txid: [UInt8], extra: [(UInt16, [UInt8])],
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
    lock.lock(); let r = realm, nn = nonce; lock.unlock()
    if !username.isEmpty { attrs.append((0x0006, Array(username.utf8))) }
    if !r.isEmpty { attrs.append((0x0014, Array(r.utf8))) }
    if !nn.isEmpty { attrs.append((0x0015, Array(nn.utf8))) }
  }

  private func longTermKey() -> Data {
    // MD5(username ":" realm ":" password) — RFC 5389 long-term credentials.
    lock.lock(); let r = realm; lock.unlock()
    let s = "\(username):\(r):\(credential)"
    let d = Insecure.MD5.hash(data: Data(s.utf8))
    return Data(d)
  }

  private func xorPeer(ip: String, port: UInt16) -> [UInt8] {
    xorPeer(addr: inet_addr(ip), port: port)
  }

  /// XOR-PEER-ADDRESS for an IPv4 peer given as `s_addr` (network order).
  private func xorPeer(addr: UInt32, port: UInt16) -> [UInt8] {
    var o: [UInt8] = [0, 0x01]
    let xp = port ^ UInt16(cookie >> 16)
    o.append(UInt8(xp >> 8)); o.append(UInt8(xp & 0xff))
    withUnsafeBytes(of: addr) { ab in
      o.append(ab[0] ^ 0x21); o.append(ab[1] ^ 0x12); o.append(ab[2] ^ 0xA4); o.append(ab[3] ^ 0x42)
    }
    return o
  }

  static func text(addr: UInt32, port: UInt16) -> String {
    var a = in_addr(s_addr: addr)
    var ipb = [CChar](repeating: 0, count: 64)
    inet_ntop(AF_INET, &a, &ipb, 64)
    return "\(String(cString: ipb)):\(port)"
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

  // ── SELF-TEST: the wire numbers, held ───────────────────────────────────────
  //
  // No network, no socket. A message is built and read back as the server would
  // read it, and the arms include two things the builder MUST get wrong for the
  // test to be worth anything: the old attribute type, and a channel outside
  // the range. `validate-the-ruler-against-known-inputs`.
  static func selftest() -> Bool {
    var ok = true
    func check(_ c: Bool, _ what: String) { fputs("  \(c ? "ok  " : "FAIL") \(what)\n", stderr); if !c { ok = false } }
    let t = TurnClient(host: "relay.test", port: 3478, username: "u", credential: "p")
    t.realm = "r"; t.nonce = "n"
    // Attributes of a built message, as (type, value) -- what a server sees.
    func attrs(_ m: [UInt8]) -> [(UInt16, [UInt8])] {
      var out: [(UInt16, [UInt8])] = []
      var i = 20
      let end = min(m.count, 20 + (Int(m[2]) << 8 | Int(m[3])))
      while i + 4 <= end {
        let at = UInt16(m[i]) << 8 | UInt16(m[i + 1])
        let al = Int(UInt16(m[i + 2]) << 8 | UInt16(m[i + 3]))
        guard i + 4 + al <= m.count else { break }
        out.append((at, Array(m[(i + 4)..<(i + 4 + al)])))
        i = i + 4 + al + ((4 - al % 4) % 4)
      }
      return out
    }
    let txid = [UInt8](repeating: 7, count: 12)
    // 1. ChannelBind carries CHANNEL-NUMBER 0x000C, 4 bytes, channel in range, and never 0x001C.
    let xor = t.xorPeer(ip: "103.211.12.69", port: 7001)
    let bind = t.build(method: 0x0009, txid: txid, extra: t.channelBindAttrs(ch: 0x4000, xor: xor), integrity: true)
    let ba = attrs(bind)
    let chAttr = ba.first { $0.0 == 0x000C }
    check(chAttr != nil, "ChannelBind carries CHANNEL-NUMBER (0x000C)")
    check(chAttr?.1.count == 4 && chAttr?.1[2] == 0 && chAttr?.1[3] == 0, "CHANNEL-NUMBER is 4 bytes with the RFFU zero")
    if let v = chAttr?.1 {
      let ch = UInt16(v[0]) << 8 | UInt16(v[1])
      check((0x4000...0x4FFF).contains(ch), "channel \(String(ch, radix: 16)) is in 0x4000...0x4FFF")
    }
    check(!ba.contains { $0.0 == 0x001C }, "no 0x001C (MESSAGE-INTEGRITY-SHA256) in a ChannelBind -- the 0.161 bug")
    check(ba.contains { $0.0 == 0x0012 } && ba.contains { $0.0 == 0x0006 } && ba.contains { $0.0 == 0x0014 }
          && ba.contains { $0.0 == 0x0015 } && ba.contains { $0.0 == 0x0008 } && ba.contains { $0.0 == 0x8028 },
          "peer address, username, realm, nonce, integrity and fingerprint present")
    check(bind[0] == 0x00 && bind[1] == 0x09, "method is ChannelBind request (0x0009)")
    check(Int(bind[2]) << 8 | Int(bind[3]) == bind.count - 20, "length field covers every attribute")
    // 1b. The NEGATIVE: a bind built the old way must be caught by this same reader.
    let oldBind = t.build(method: 0x0009, txid: txid, extra: [(0x001C, t.u16(0x4000)), (0x0012, xor)], integrity: false)
    check(!attrs(oldBind).contains { $0.0 == 0x000C }, "the reader sees the old encoding as having NO channel number")
    // 2. XOR-PEER-ADDRESS round-trips through the indication parser.
    check(xor.count == 8 && xor[1] == 0x01, "XOR-PEER-ADDRESS is 8 bytes, family IPv4")
    let payload: [UInt8] = [0x0A, 0x00, 0x4B, 0x54, 1, 2, 3, 4, 5]                    // 9 bytes, needs padding
    var ind: [UInt8] = [0x00, 0x17, 0, 0, 0x21, 0x12, 0xA4, 0x42] + txid
    ind += [0x00, 0x12, 0x00, 0x08] + xor
    ind += [0x00, 0x13, 0x00, UInt8(payload.count)] + payload + [0, 0, 0]
    let alen = ind.count - 20
    ind[2] = UInt8(alen >> 8); ind[3] = UInt8(alen & 0xff)
    var srv = sockaddr_in()
    srv.sin_family = sa_family_t(AF_INET); srv.sin_port = UInt16(3478).bigEndian; srv.sin_addr.s_addr = inet_addr("141.101.90.1")
    t.turnAddr = srv
    t.allocatedFd = -1
    let got: [UInt8]? = ind.withUnsafeBufferPointer { b in
      guard let r = t.unwrap(b.baseAddress!, b.count, from: srv) else { return nil }
      return Array(UnsafeBufferPointer(start: r.0, count: r.1))
    }
    check(got == payload, "a Data Indication unwraps to exactly its DATA")
    t.lock.lock(); let ia = t.indAddr, ip = t.indPort; t.lock.unlock()
    check(ip == 7001 && TurnClient.text(addr: ia, port: ip) == "103.211.12.69:7001", "and names the peer it came from (\(TurnClient.text(addr: ia, port: ip)))")
    var other = srv; other.sin_addr.s_addr = inet_addr("1.2.3.4")
    let stranger: Bool = ind.withUnsafeBufferPointer { b in t.unwrap(b.baseAddress!, b.count, from: other) == nil }
    check(stranger, "the same bytes from an address that is not our relay are refused")
    // 3. ChannelData on our channel unwraps; on another channel it does not.
    var cd: [UInt8] = [0x40, 0x00, 0x00, UInt8(payload.count)] + payload + [0, 0, 0]
    let onChannel: [UInt8]? = cd.withUnsafeBufferPointer { b in
      guard let r = t.unwrap(b.baseAddress!, b.count, from: srv) else { return nil }
      return Array(UnsafeBufferPointer(start: r.0, count: r.1))
    }
    check(onChannel == payload, "ChannelData on 0x4000 unwraps to its payload")
    cd[1] = 0x07
    let offChannel: Bool = cd.withUnsafeBufferPointer { b in t.unwrap(b.baseAddress!, b.count, from: srv) == nil }
    check(offChannel, "ChannelData on a channel we never bound is refused")
    // 4. A Send Indication is a well-formed STUN indication naming the peer and carrying the data.
    //    Sent from a loopback UDP socket to ITSELF, standing in for the relay, so
    //    the bytes can be read back with no network -- and with a receive timeout,
    //    so a send that fails cannot hang the test (the first draft did).
    let us = socket(AF_INET, SOCK_DGRAM, 0)
    var me = sockaddr_in()
    me.sin_family = sa_family_t(AF_INET); me.sin_port = 0; me.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &me) { pp in
      pp.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(us, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    } == 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &me) { pp in
      pp.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(us, $0, &len) }
    }
    check(us >= 0 && bound && me.sin_port != 0, "loopback socket standing in for the relay")
    var tv = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(us, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    t.turnAddr = me
    let sent: Bool = payload.withUnsafeBufferPointer { b in
      t.sendIndication(fd: us, b.baseAddress!, b.count, addr: inet_addr("103.211.12.69"), port: 7001)
    }
    check(sent, "Send Indication written")
    var rb = [UInt8](repeating: 0, count: 256)
    let n = Int(recv(us, &rb, 256, 0))
    check(n == 20 + 12 + 4 + 12, "Send Indication is \(n) bytes (20 header + 12 peer + 4 + 9 data padded to 12)")
    check(n >= 20 && rb[0] == 0x00 && rb[1] == 0x16, "type is Send Indication (0x0016)")
    if n > 20 {
      let sa = attrs(Array(rb[0..<n]))
      check(sa.first { $0.0 == 0x0012 }?.1 == xor, "peer address in the indication matches XOR-PEER-ADDRESS")
      check(sa.first { $0.0 == 0x0013 }?.1 == payload, "DATA in the indication is the payload")
    }
    close(us)
    t.turnAddr = srv
    // 5. A Refresh with LIFETIME 0 is what a release sends.
    let rel = t.build(method: 0x0004, txid: txid, extra: [(0x000D, t.u32(0))], integrity: true)
    check(rel[0] == 0x00 && rel[1] == 0x04 && attrs(rel).first { $0.0 == 0x000D }?.1 == [0, 0, 0, 0], "release is Refresh (0x0004) with LIFETIME 0")
    // 6. Error replies parse to their code -- 437 and 438 are the two this file acts on.
    func errReply(_ code: Int, nonce: String) -> [UInt8] {
      var m: [UInt8] = [0x01, 0x13, 0, 0, 0x21, 0x12, 0xA4, 0x42] + txid
      m += [0x00, 0x09, 0x00, 0x04, 0, 0, UInt8(code / 100), UInt8(code % 100)]
      let nb = Array(nonce.utf8)
      m += [0x00, 0x15, 0x00, UInt8(nb.count)] + nb + [UInt8](repeating: 0, count: (4 - nb.count % 4) % 4)
      let l = m.count - 20; m[2] = UInt8(l >> 8); m[3] = UInt8(l & 0xff)
      return m
    }
    let r437 = t.parse(errReply(437, nonce: "n2"), errReply(437, nonce: "n2").count)
    check(r437.errorCode == 437 && !r437.ok, "437 Allocation Mismatch parses as 437")
    let e438 = errReply(438, nonce: "fresh")
    let r438 = t.parse(e438, e438.count)
    check(r438.errorCode == 438 && t.nonce == "fresh", "438 Stale Nonce parses and takes the new nonce")
    // 7. The lease file round-trips what an eviction needs.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tk-turn-selftest-\(getpid())", isDirectory: true)
    setenv("TK_KIN_DIR", dir.path, 1)
    t.saveLease()
    if let d = try? Data(contentsOf: TurnClient.leaseFile),
       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
      check(o["username"] as? String == "u" && o["credential"] as? String == "p" && o["nonce"] as? String == "fresh"
            && o["host"] as? String == "relay.test" && o["port"] as? Int == 3478, "lease file carries host, port, credentials and nonce")
    } else { check(false, "lease file written") }
    TurnClient.clearLease()
    check(!FileManager.default.fileExists(atPath: TurnClient.leaseFile.path), "and is gone after a release")
    try? FileManager.default.removeItem(at: dir)
    unsetenv("TK_KIN_DIR")
    return ok
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
