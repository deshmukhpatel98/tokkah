import Foundation
import Darwin

let SR = 48_000.0
// samples per packet -> 0.667 ms, and ALSO the CoreAudio device buffer size, so
// this one number lands in the mic path, the packetisation, the jitter buffer and
// the speaker path. It was 128 because that was what got typed first; the hardware
// reports a usable range of 15..4096.
//
// Measured, release build, 95 s, audio+video both ways, encrypted:
//   FPP=64  m2e 15.71 / 16.88 ms   FPP=32  m2e 12.44 ms   both zero concealment
// and under ten busy-loop threads of CPU starvation: 15.32 vs 11.65 ms, still
// zero concealment and zero snaps, because CoreAudio's render thread runs with
// time-constraint priority and normal-priority load cannot displace it.
//
// The cost is a doubled packet rate: 1511/s instead of 758/s, about 2.4 Mbps
// instead of 2.0 for uncompressed float32 audio, and 0.12% of a core in crypto.
// 32 was rejected once before at 12 concealed packets -- that was under a jitter
// buffer that grew on loss it could not fix, and a run confounded by the handshake
// flood of 17.84. With both fixed it conceals nothing.
let FPP = 32
let RING = 2048           // packets == 1.37 s. Generous: the ring is not the
                         // latency, the read cursor's DISTANCE behind the write
                         // head is, and a big ring only buys recovery headroom.
let HDR = 20             // magic(4) seq(4) capHost(8) frames(4)
let HMAGIC: UInt32 = 0x544B_0006   // key handshake; the ONLY packet always in the clear
let HPKT = 4 + 32
let MAGIC: UInt32 = 0x544B_0001
/// "send me a keyframe". Eight bytes, no payload, sent by a receiver that cannot
/// decode. Necessary because H.264 parameter sets ride only with keyframes and
/// keyframes here are on demand -- a receiver that joins late, or loses the one
/// packet that carried them, is otherwise blind for the entire call. Measured
/// exactly that: a peer starting 2 s late logged noFmt 346 and decoded nothing.
let KMAGIC: UInt32 = 0x544B_0003

// ── The receive ring ────────────────────────────────────────────────────────
//
// Written by the socket thread, read by the audio render thread, no locks. The
// audio thread must never block: a mutex held by a socket thread that the
// scheduler decided to deprioritise is a dropout, and dropouts are exactly what
// this project exists to eliminate.
//
// THE ANCHORING RULE, learned the hard way today. The web app rejects an
// arriving frame when it sits beyond the accept window, and gates its recovery
// on a wall-clock plausibility bound derived from the FIRST sequence it ever
// saw. Measured live on Safari: 255,171 frames arrived, 261,146 were refused as
// "too far in the future", the recovery fired ZERO times, and 39 frames played
// in eight minutes. Total silence, with the rescue one line away, refused by a
// guard computed from the very anchor that was wrong.
//
// So the rule here is the opposite and it is absolute: THE STREAM IS THE TRUTH.
// If the write head gets further ahead of the read cursor than the ring can
// hold, the cursor JUMPS to the stream. There is no plausibility test, because
// there is no prior worth defending against arriving data.
final class RecvRing {
  let samples: UnsafeMutablePointer<Float>
  let tags: UnsafeMutablePointer<Int32>       // seq present in this slot, or -1
  let capHost: UnsafeMutablePointer<UInt64>   // capture host time of that packet
  /// When THIS machine took the packet off the socket. Local, so it needs no
  /// clock offset, and it is what splits "the network was slow" from "we sat on
  /// it" -- the difference between a defect that is mine and one that is not.
  let recvHost: UnsafeMutablePointer<UInt64>
  private(set) var hiSeq: Int32 = -1          // newest seq ever written

  // Read cursor, in ABSOLUTE samples, FRACTIONAL. Owned by the audio thread.
  //
  // Fractional because latency has to be GOVERNED, not merely initialised. A
  // cursor that free-runs at exactly 1.0 samples per sample keeps whatever
  // distance it happened to start with -- measured on this rig: --jit 1 settled
  // at 33.70 ms while --jit 2 sat at 24.72 ms, the opposite of the intent,
  // because the cursor drifted back and nothing pulled it forward. Reading at a
  // rate of 1 +/- a few parts per thousand closes that error continuously and
  // inaudibly, and it is the difference between a call that holds its floor and
  // one that silently gets laggier the longer you talk.
  var pos: Double = -1
  var rate: Double = 1.0
  var rateSum: Double = 0, rateN: Int = 0   // so the governor is observable

  // Counters. Written by whichever thread owns the event; read by the reporter.
  // Plain vars rather than atomics: they are diagnostics, a torn read costs a
  // wrong log line, and an atomic on the audio path costs a real-time budget.
  var recv = 0, dup = 0, jumps = 0, played = 0, concealed = 0, tooOld = 0, snaps = 0
  // LATE and LOST are different events with opposite remedies, and the buffer
  // controller has no business acting until it knows which one it is looking at.
  //
  // A late packet arrived after its deadline: a bigger buffer would have caught
  // it, so grow. A lost packet is never coming: no buffer size on earth catches
  // it, so growing is pure donated latency. Measured, at 1% loss: the controller
  // grew to its ceiling and m2e went 15.93 -> 22.22 ms, six milliseconds spent
  // waiting for packets that did not exist.
  //
  // The test is exact and already available -- a late arrival is one with
  // negative slack.
  var lateArrivals = 0
  // ── Is the tail the sender's or the receiver's? ────────────────────────────
  //
  // The buffer controller keeps settling at 3, 4 or 5 packets across runs, worth
  // 1.3 ms, and it decides on the 1st percentile of arrival slack. So the thing
  // that actually sets the latency is the TAIL of the arrival distribution -- and
  // "arrival" has two components that a single number cannot separate: when the
  // sender managed to emit the packet, and how long it then took to get here and be
  // noticed. On loopback the second should be nothing, and the observed tail is
  // 3.2 ms, so one of those two assumptions is wrong.
  //
  // Both are measurable at the receiver, in the same window, on the same packets:
  // the gap between consecutive CAPTURE stamps is the sender's own cadence (its
  // clock, but a difference, so the offset cancels), and the gap between arrivals
  // is that cadence plus everything after it. Consecutive sequence numbers only --
  // a gap across a lost packet is not a cadence measurement.
  var ipiCap = Quantiles(cap: 4096)
  var ipiRecv = Quantiles(cap: 4096)
  var ipiCapMax = 0.0, ipiRecvMax = 0.0
  /// Worst sender cadence gap in the current controller window, reset by the
  /// controller when it reads it. This is what lets a margin dip be ATTRIBUTED:
  /// a gap of two packet periods means the far end missed an input wakeup, and no
  /// buffer size on this machine prevents that.
  var ipiCapWinMax = 0.0
  private var lastIpiSeq: Int32 = -1
  private var lastIpiCap: UInt64 = 0
  private var lastIpiRecv: UInt64 = 0
  /// Packets that would have been a click and were not, because a later packet
  /// carried a second copy.
  var recovered = 0
  /// Consecutive refusals-as-too-old with no successful write between them. Only
  /// a peer whose sequence numbers went backwards produces a run of these.
  private var oldRun = 0
  var restarts = 0
  var concealLost = 0, concealStarved = 0
  // Occupancy error in ms, published by the audio thread so the buffer
  // controller can tell "the buffer is roomy" from "the cursor is behind".
  var errMs: Double = 0

  // ARRIVAL SLACK: how long before its deadline each packet turned up.
  //
  // Why this exists. Mouth-to-ear here is CONSTANT by construction -- the
  // governor pins the read cursor to the target, so as long as a packet beats
  // its deadline the ear experiences the designed delay and nothing else. That
  // is the right definition of latency, and it is also blind in a way that
  // matters: "zero concealment with 1 ms to spare" and "zero concealment with
  // 20 ms to spare" produce byte-identical reports, and only one of them
  // survives a real path. Slack is the margin that m2e cannot show.
  //
  // It is computed from the local read cursor alone -- no peer clock, no offset
  // estimate, no sync. So it reads exactly the same on loopback as it does
  // between two continents, which is the entire reason to trust it there.
  var slack = Quantiles(cap: 8192)
  var slackMin = 1e9
  // A second, SHORT window, for control rather than reporting. The lifetime
  // quantile above is the honest record; a controller must not steer on it. A
  // 30 s average read after a 12 s change has inverted a result in this project
  // before, and a buffer that steers on lifetime slack would refuse to shrink
  // for minutes after the path improved.
  var slackWin = Quantiles(cap: 2048)
  var slackWinMin = 1e9   // the WORST case in the window: what a shrink risks

  init() {
    samples = .allocate(capacity: RING * FPP)
    samples.initialize(repeating: 0, count: RING * FPP)
    tags = .allocate(capacity: RING)
    tags.initialize(repeating: -1, count: RING)
    capHost = .allocate(capacity: RING)
    capHost.initialize(repeating: 0, count: RING)
    recvHost = .allocate(capacity: RING)
    recvHost.initialize(repeating: 0, count: RING)
  }

  @inline(__always) func present(_ seq: Int32) -> Bool {
    seq >= 0 && tags[Int(seq) % RING] == seq
  }

  // Socket thread.
  func write(seq: Int32, cap: UInt64, src: UnsafePointer<Float>, n: Int) {
    recv += 1
    let slot = Int(seq) % RING
    if tags[slot] == seq { dup += 1; return }
    // A packet older than the cursor by more than the ring is unusable: its slot
    // now belongs to a newer packet. Counted, never written -- writing it would
    // corrupt audio about to be played.
    if pos >= 0 {
      let curSeq = Int64(pos) / Int64(FPP)
      if Int64(seq) < curSeq - Int64(RING) {
        tooOld += 1
        oldRun += 1
        // A PEER THAT RESTARTED IS NOT A LATE PACKET, AND THIS WAS FATAL.
        //
        // Sequence numbers begin at zero. After thirteen minutes the cursor is
        // past a million, so every packet from a restarted peer is "older than
        // the ring" and refused -- which means hiSeq never moves, the cursor
        // never re-anchors, and the call is dead for good. Measured exactly that
        // way when both ends took a self-update mid-call: old 1518/s (every
        // packet arriving), conceal 1494/s, played 1.8%, and m2e p95 66 SECONDS
        // from the handful of ancient samples still in the ring.
        //
        // It was live in every release, and shipping a self-updater is what made
        // restarts routine enough to find it: the update mechanism manufactured
        // the condition that exposed the bug it would go on to trigger.
        //
        // One stray old packet must not reset anything, so the test is a RUN of
        // them with no successful write in between -- 64 packets, about 43 ms.
        // Nothing but a restarted stream produces that.
        if oldRun >= 64 {
          restarts += 1
          tags.update(repeating: -1, count: RING)
          hiSeq = -1
          pos = -1          // the render callback re-primes from the new stream
          oldRun = 0
          // fall through and write this packet as the first of the new stream
        } else {
          return
        }
      } else {
        oldRun = 0
      }
    }
    if pos >= 0 {
      // Deadline of this packet's first sample, minus where the cursor is now.
      let ms = (Double(Int64(seq) * Int64(FPP)) - pos) / SR * 1000.0
      slack.add(ms)
      slackWin.add(ms)
      if ms < slackMin { slackMin = ms }
      if ms < slackWinMin { slackWinMin = ms }
      if ms < 0 { lateArrivals += 1 }
    }
    memcpy(samples + slot * FPP, src, min(n, FPP) * 4)
    let now = Clock.now()
    if seq == lastIpiSeq + 1, lastIpiCap != 0 {
      let dc = Clock.msSigned(cap, lastIpiCap)
      let dr = Clock.msSigned(now, lastIpiRecv)
      ipiCap.add(dc); if dc > ipiCapMax { ipiCapMax = dc }
      if dc > ipiCapWinMax { ipiCapWinMax = dc }
      ipiRecv.add(dr); if dr > ipiRecvMax { ipiRecvMax = dr }
    }
    lastIpiSeq = seq; lastIpiCap = cap; lastIpiRecv = now
    capHost[slot] = cap
    recvHost[slot] = now
    tags[slot] = seq
    if seq > hiSeq { hiSeq = seq }
  }
}

// ── UDP ─────────────────────────────────────────────────────────────────────
//
// BSD sockets, not Network.framework. NWConnection is pleasant and it owns its
// own queues and buffering, and "owns its own buffering" is precisely the thing
// a latency measurement must not have between the wire and the ring.
final class Wire {
  // Non-zero means the far end is on a different build. Reported, never hidden:
  // a count of zero and a count of thousands must not print the same line.
  var fmtMismatch = 0
  var tsync: TimeSync?
  var impair: Impair?
  var crypto: Crypto?
  /// Sent in the clear, necessarily: it is what establishes the key. Contains a
  /// public key and nothing else -- no identity, no room code, nothing that is
  /// worth anything to a listener on its own.
  func sendHandshake() {
    guard let c = crypto else { return }
    var out = [UInt8](repeating: 0, count: HPKT)
    out.withUnsafeMutableBytes { p in
      p.storeBytes(of: HMAGIC.littleEndian, toByteOffset: 0, as: UInt32.self)
    }
    c.myPublic.copyBytes(to: &out[4], count: 32)
    out.withUnsafeBufferPointer { wireSend($0.baseAddress!, $0.count) }
  }
  private(set) var delayQ: DelayQueue?
  func armDelayQueue() { delayQ = DelayQueue { [weak self] p, n in self?.wireSend(p, n) } }
  /// Exposed so STUN can run on THIS socket. A mapping discovered on any other
  /// socket describes that socket's NAT hole, not this one's, and most NATs give
  /// a different external port per source port -- so the wrong socket yields an
  /// address that looks valid and drops every media packet.
  let fd: Int32
  private var peer = sockaddr_in()
  private(set) var sent = 0
  private(set) var sendErrs = 0

  init?(listen port: UInt16, peerHost: String, peerPort: UInt16) {
    fd = socket(AF_INET, SOCK_DGRAM, 0)
    if fd < 0 { return nil }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    // CLOSE ON EXEC, and this line is load-bearing.
    //
    // The updater re-execs this process in place. execv replaces the image but
    // KEEPS open file descriptors, so without this the new image inherits a
    // socket already bound to our port, its own bind() returns EADDRINUSE, and
    // the peer is dead. Measured exactly that on the first auto-update test:
    // "update: installed 0.1.2 -- restarting" followed by "socket/bind failed".
    // On a machine 15 km away that is a self-inflicted brick with no way in.
    fcntl(fd, F_SETFD, FD_CLOEXEC)
    // A big receive buffer so a scheduling hiccup on the socket thread drops
    // nothing: the kernel holds the burst instead of discarding it, and a
    // discarded packet is indistinguishable from a network loss in the numbers.
    var rcv: Int32 = 1 << 21
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))

    var me = sockaddr_in()
    me.sin_family = sa_family_t(AF_INET)
    me.sin_port = port.bigEndian
    me.sin_addr.s_addr = INADDR_ANY
    let bound = withUnsafePointer(to: &me) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    // RETRY, NEVER DIE. A bind that fails right now may succeed in a second --
    // the previous image's socket can still be closing, the port can be in a
    // transient state, or a supervisor may be mid-restart. Exiting turns a
    // one-second race into a permanently unreachable peer, so the loop below
    // keeps trying and says so, and the process stays alive to be updated again.
    if bound < 0 {
      var tries = 0
      var ok = false
      while tries < 60 {
        usleep(500_000)
        tries += 1
        let r = withUnsafePointer(to: &me) { p in
          p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r == 0 { ok = true; break }
        if tries % 10 == 0 { fputs("bind: port \(port) still busy after \(tries / 2)s, still trying\n", stderr) }
      }
      if !ok { return nil }
    }

    peer.sin_family = sa_family_t(AF_INET)
    peer.sin_port = peerPort.bigEndian
    peer.sin_addr.s_addr = inet_addr(peerHost)
  }

  /// REDUNDANCY THAT NEEDS NO FORMAT CHANGE.
  ///
  /// A concealed packet is an audible click, and at FPP=32 even 0.1% loss is
  /// about 1.5 clicks a second. The fix is to carry a second copy of an earlier
  /// packet -- but a new header field would break every peer on an older build
  /// and cost another silent-until-updated cycle (17.85).
  ///
  /// It does not need one. The header already declares `frames`, and the receiver
  /// only requires the datagram to be AT LEAST that long, so bytes past the
  /// declared payload are ignored by every build that does not know to look. The
  /// redundant block rides there: capHost(8) + payload. An old peer sees a
  /// slightly larger datagram and behaves exactly as before.
  ///
  /// `redundantOf` is the sequence the extra copy belongs to. Sent only when the
  /// path has actually been losing packets, so a clean call pays nothing.
  func send(seq: Int32, cap: UInt64, src: UnsafePointer<Float>, n: Int, scratch: UnsafeMutablePointer<UInt8>,
            redundant: UnsafePointer<Float>? = nil, redundantCap: UInt64 = 0) {
    scratch.withMemoryRebound(to: UInt32.self, capacity: 1) { $0[0] = MAGIC.littleEndian }
    (scratch + 4).withMemoryRebound(to: UInt32.self, capacity: 1) { $0[0] = UInt32(bitPattern: seq).littleEndian }
    (scratch + 8).withMemoryRebound(to: UInt64.self, capacity: 1) { $0[0] = cap.littleEndian }
    (scratch + 16).withMemoryRebound(to: UInt32.self, capacity: 1) { $0[0] = UInt32(n).littleEndian }
    memcpy(scratch + HDR, src, n * 4)
    var total = HDR + n * 4
    if let r = redundant {
      (scratch + total).withMemoryRebound(to: UInt64.self, capacity: 1) { $0[0] = redundantCap.littleEndian }
      memcpy(scratch + total + 8, r, n * 4)
      total += 8 + n * 4
      redundantSent += 1
    }
    // Through rawSend, not sendto. This path used to call sendto directly, which
    // meant the impairment gate -- and anything else that ever belongs on the way
    // out -- saw video fragments and clock probes but never a single audio packet.
    // A 20% loss arm dropped 13 packets out of twelve thousand and the receiver
    // reported zero concealment, so the rig said the app shrugs off heavy loss
    // while actually testing nothing. One send path, one gate.
    rawSend(scratch, total)
  }

  /// One datagram, already framed by the caller. Shared by the audio and video
  /// paths so there is exactly one socket, one port and one NAT binding per peer
  /// -- two ports would mean two hole-punches and two things to go wrong.
  func rawSend(_ p: UnsafePointer<UInt8>, _ n: Int) {
    // The impairment sits here rather than at the two call sites so that nothing
    // can slip past it -- audio, video fragments and clock probes all get the
    // same treatment a real path would give them. Impairing the clock probes is
    // deliberate: the offset estimator's min-delay filter is supposed to survive
    // a lossy jittery path, and if it does not I want to find out here.
    // Encrypt FIRST, then impair: the network sees ciphertext, so a rig that
    // models the network must too.
    //
    // Stack scratch, not a shared buffer: three threads reach this, and one
    // shared output buffer would interleave two packets into each other. Stack
    // allocation makes the question disappear rather than answering it with a
    // second lock.
    if let c = crypto, c.established {
      var sentOK = false
      withUnsafeTemporaryAllocation(byteCount: n + 32, alignment: 8) { tmp in
        let out = tmp.baseAddress!.assumingMemoryBound(to: UInt8.self)
        if let m = c.seal(p, n, into: out) {
          sentOK = true
          if let im = impair, im.enabled {
            if im.shouldDrop() { return }
            let d = im.delayTicks()
            if d > 0, let q = delayQ { q.push(out, m, due: Clock.now() + d); return }
          }
          wireSend(out, m)
        }
      }
      if sentOK { return }
      // Sealing failed. Falling through to plaintext would silently undo the
      // encryption, so it does not: the packet is dropped and counted.
      cryptSendFails += 1
      return
    }
    // No key yet. Plaintext is permitted only in this window, and it is counted
    // so that a call which never encrypts cannot look like one that did.
    crypto?.notePlaintextTx()
    if let im = impair, im.enabled {
      if im.shouldDrop() { return }
      let d = im.delayTicks()
      if d > 0, let q = delayQ { q.push(p, n, due: Clock.now() + d); return }
    }
    wireSend(p, n)
  }

  private(set) var cryptSendFails = 0
  private(set) var handshakeReplies = 0
  private(set) var redundantSent = 0

  private func wireSend(_ p: UnsafePointer<UInt8>, _ n: Int) {
    let r = withUnsafePointer(to: &peer) { pp in
      pp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        sendto(fd, p, n, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if r < 0 { sendErrs += 1 } else { sent += 1; sentBytes += n + 28 }
  }

  /// Bytes actually put on the wire, plus 28 for the UDP and IP headers each
  /// datagram carries. Reported because this is uncompressed float32 audio and
  /// the number is not small -- someone on a home connection is entitled to know
  /// what a call costs them before it starts stuttering.
  private(set) var sentBytes = 0
  private(set) var recvBytes = 0

  // Blocking receive loop, run on its own thread.
  /// Point the media at a different address, once rendezvous has found the peer.
  func setPeer(ip: String, port: UInt16) {
    peer.sin_family = sa_family_t(AF_INET)
    peer.sin_port = port.bigEndian
    peer.sin_addr.s_addr = inet_addr(ip)
  }

  // ── Candidate racing ────────────────────────────────────────────────────────
  //
  // Two machines behind two routers have more than one plausible address for each
  // other, and picking one is a guess. The old code guessed: same public IP means
  // same LAN, so use the private address, otherwise use the public one. When that
  // guess is wrong the call does not degrade, it simply never starts -- and the
  // first real attempt at this is between two houses I cannot test from here.
  //
  // So: send to EVERY candidate, and let the one that works identify itself. A
  // packet that arrives carries the only address that is definitely reachable --
  // the one it came from. Adopt it. This is the useful half of what ICE does, and
  // it needs no state machine: probe everything, lock onto whatever answers.
  private var candidates: [sockaddr_in] = []
  private(set) var locked = false
  private(set) var lockedFrom = ""

  func addCandidate(ip: String, port: UInt16) {
    var a = sockaddr_in()
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    a.sin_addr.s_addr = inet_addr(ip)
    if !candidates.contains(where: { $0.sin_addr.s_addr == a.sin_addr.s_addr && $0.sin_port == a.sin_port }) {
      candidates.append(a)
    }
  }

  func clearCandidates() { candidates.removeAll() }

  /// Punch every candidate. Cheap: a 32-byte clock probe doubles as the probe
  /// that opens the NAT binding, so connectivity and offset are established by
  /// the same packet.
  func probeAllCandidates() {
    guard !locked else { return }
    var out = [UInt8](repeating: 0, count: TPKTX)
    out.withUnsafeMutableBytes { p in
      p.storeBytes(of: TMAGIC.littleEndian, toByteOffset: 0, as: UInt32.self)
      p.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 4, as: UInt32.self)
      p.storeBytes(of: Clock.now().littleEndian, toByteOffset: 8, as: UInt64.self)
      appendRxReport(p)
    }
    for c in candidates {
      var a = c
      out.withUnsafeBufferPointer { b in
        _ = withUnsafePointer(to: &a) { pp in
          pp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            sendto(fd, b.baseAddress!, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
          }
        }
      }
    }
  }

  /// A packet arrived and parsed. Whatever address it came from is reachable, so
  /// that is the peer from now on. Only the FIRST one wins: after that, changing
  /// the peer on arriving traffic would let a stray packet steal the call.
  /// Host time of the last packet we accepted from the peer. This, not
  /// `locked`, is what "connected" means -- a remembered address is a claim about
  /// the past, and the only evidence a path still works is traffic on it.
  private(set) var lastRecvHost: UInt64 = 0
  private(set) var relocks = 0

  /// What the PEER has lost and recovered on the path FROM HERE. Cumulative, so
  /// a reader that samples at any cadence gets a true delta -- a windowed average
  /// read on the wrong cadence has inverted an A/B in this project before.
  /// `--no-rt` exists so the thread policy can be A/B'd against itself. A change
  /// nobody can turn off is a claim, not a measurement.
  nonisolated(unsafe) static var noRealtime = false
  private(set) var peerRxLost: Int = 0
  private(set) var peerRxRecovered: Int = 0
  /// Whether the far end reports at all. False means an older build, and the
  /// controller must then fall back to the local numbers and SAY SO -- a silent
  /// fallback to the wrong signal is the bug this field exists to fix.
  private(set) var peerReportsLoss = false
  /// The ring whose counters get reported to the peer. Set when the receive loop
  /// starts; nil before that, which reports zeros and is harmless.
  private weak var reportRing: RecvRing?

  /// Append this machine's receive-side counters to a time-sync packet.
  private func appendRxReport(_ p: UnsafeMutableRawBufferPointer) {
    let r = reportRing
    let lost = UInt32(truncatingIfNeeded: r?.concealLost ?? 0)
    let rec = UInt32(truncatingIfNeeded: r?.recovered ?? 0)
    p.storeBytes(of: lost.littleEndian, toByteOffset: TPKT, as: UInt32.self)
    p.storeBytes(of: rec.littleEndian, toByteOffset: TPKT + 4, as: UInt32.self)
  }

  /// Nothing has arrived for a while, so the address we locked onto is no longer
  /// true. Reasons this happens on a real daily call and not just in a test: the
  /// peer's router hands out a new port, someone changes room and joins another
  /// access point, DHCP renews, a laptop sleeps and wakes. In every one of them the
  /// remembered address is now wrong and the call is silent forever, because
  /// `adopt` only ever fires once.
  ///
  /// So it can fire again. Unlock, forget the candidates, and let the rendezvous
  /// and the probes find the peer the same way they did at the start.
  func unlockForRediscovery() {
    guard locked else { return }
    locked = false
    lockedFrom = ""
    candidates.removeAll()
    relocks += 1
  }

  private func adopt(_ from: sockaddr_in) {
    guard !locked else { return }
    peer = from
    locked = true
    var ipb = [CChar](repeating: 0, count: 64)
    var f = from
    inet_ntop(AF_INET, &f.sin_addr, &ipb, 64)
    lockedFrom = "\(String(cString: ipb)):\(UInt16(bigEndian: from.sin_port))"
  }

  var peerDescription: String {
    var b = [CChar](repeating: 0, count: 32)
    var a = peer.sin_addr
    inet_ntop(AF_INET, &a, &b, 32)
    return "\(String(cString: b)):\(UInt16(bigEndian: peer.sin_port))"
  }

  /// Called on the socket thread when the peer asks for a keyframe.
  var onKeyRequest: (() -> Void)?

  func requestKeyframe(scratch: UnsafeMutablePointer<UInt8>) {
    scratch.withMemoryRebound(to: UInt32.self, capacity: 2) {
      $0[0] = KMAGIC.littleEndian; $0[1] = 0
    }
    rawSend(scratch, 8)
  }

  /// One offset probe. Cheap enough (32 bytes) to send often, and it rides the
  /// media socket so it measures the path the media actually takes.
  func sendTimeProbe() {
    var out = [UInt8](repeating: 0, count: TPKTX)
    out.withUnsafeMutableBytes { p in
      p.storeBytes(of: TMAGIC.littleEndian, toByteOffset: 0, as: UInt32.self)
      p.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 4, as: UInt32.self)
      p.storeBytes(of: Clock.now().littleEndian, toByteOffset: 8, as: UInt64.self)
      appendRxReport(p)
    }
    out.withUnsafeBufferPointer { _ = rawSend($0.baseAddress!, $0.count) }
  }

  /// Ask the scheduler to treat this thread the way it treats CoreAudio's own IO
  /// thread.
  ///
  /// Why this belongs in the latency budget at all: on loopback the network jitter
  /// is 0.1 ms, and yet the arrival-slack minimum goes to -1.38 ms and the jitter
  /// buffer sizes itself to 4 packets, 2.67 ms -- a quarter of the entire
  /// mouth-to-ear number. The buffer is not absorbing the network. It is absorbing
  /// THIS THREAD'S WAKEUP, and this thread was running at whatever priority a
  /// default pthread gets while the two audio callbacks around it run at
  /// time-constraint priority. The receive side of a real-time pipeline was the
  /// only part of it that was not real-time.
  ///
  /// Time-constraint rather than merely "high", because the work genuinely is
  /// periodic -- one packet every FPP/SR seconds -- which is exactly the contract
  /// this policy exists to express. Preemptible, because this thread must never be
  /// able to starve the audio callbacks it feeds.
  private func goRealtime() -> String {
    var tb = mach_timebase_info()
    mach_timebase_info(&tb)
    let toAbs = { (ns: Double) -> UInt32 in
      UInt32(max(1, ns * Double(tb.denom) / Double(tb.numer)))
    }
    let periodNs = Double(FPP) / SR * 1_000_000_000.0
    var pol = thread_time_constraint_policy(
      period: toAbs(periodNs),
      // Measured, not guessed: the receive path's work is a decrypt and a memcpy,
      // p95 well under 20 us. Asking for a fifth of the period is generous and
      // still leaves the scheduler room to say no.
      computation: toAbs(periodNs / 5),
      constraint: toAbs(periodNs),
      preemptible: 1)
    let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &pol) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        thread_policy_set(pthread_mach_thread_np(pthread_self()),
                          UInt32(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
      }
    }
    // Reported rather than assumed. A failed policy call leaves the thread at
    // default priority and every number after it describes a different program.
    return kr == KERN_SUCCESS
      ? "recv thread: time-constraint, period \(String(format: "%.2f", periodNs / 1000)) us"
      : "recv thread: NOT real-time (thread_policy_set = \(kr)) -- arrival jitter will include this thread's scheduling"
  }

  func recvLoop(into ring: RecvRing, video: VideoAssembler? = nil) {
    reportRing = ring
    if !Wire.noRealtime { fputs(goRealtime() + "\n", stderr) }
    // One buffer big enough for either kind. Audio and video share the socket, so
    // the loop dispatches on the magic rather than owning two sockets: two ports
    // means two NAT bindings, and the second one is the one that fails.
    let cap = max(HDR + FPP * 4, VHDR + VPAYLOAD) + 128
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
    // One receive thread, so one decrypt scratch is safe -- unlike the send side,
    // which is reached from three.
    let dbuf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
    while true {
      var src = sockaddr_in()
      var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
      let n = withUnsafeMutablePointer(to: &src) { sp in
        sp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          recvfrom(fd, buf, cap, 0, $0, &srcLen)
        }
      }
      if n < 8 { if n < 0 { usleep(200) }; continue }
      recvBytes += Int(n) + 28
      var magic = buf.withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) }

      // THE HANDSHAKE, and it is the one thing never encrypted -- it is what
      // creates the key. Answered from this thread so the exchange completes in
      // one round trip.
      if magic == HMAGIC, Int(n) >= HPKT {
        if !locked { adopt(src) }
        if let c = crypto {
          // REPLY ONLY WHEN THE KEY WAS NEW. The previous version replied to every
          // handshake it received, and so did the peer, so a reply provoked a
          // reply: on loopback that ran at about ten thousand round trips a second
          // -- 20,000 packets/s sent against 758 captured, 36 bytes each, roughly
          // 6 Mbps of pure echo per direction. It cost nothing measurable on
          // loopback, where bandwidth is free and latency stayed at 17 ms, and it
          // would have swamped the real link between two houses. It shipped in
          // 0.9.0 and 0.9.1.
          //
          // Liveness does not need the echo. Both ends beat a handshake on a timer
          // -- fast while unkeyed, every 5 s after -- so a peer that restarts with
          // a fresh key is adopted on its next beat, that adoption IS a change, and
          // the single reply that follows completes the exchange in one round trip.
          if c.adoptPeer(Data(bytes: buf + 4, count: 32)) {
            fputs("crypto: \(c.summary)\n", stderr)
            sendHandshake()
            handshakeReplies += 1
          }
        }
        continue
      }

      // Decrypt, then treat the PLAINTEXT as the packet. A datagram that fails to
      // decrypt is not dispatched at all: accepting it as plaintext would let
      // anyone who can reach the port inject audio into a call that believes
      // itself encrypted.
      var plain: UnsafeMutablePointer<UInt8> = buf
      var plainN = Int(n)
      if let c = crypto, c.established {
        if magic == MAGIC || magic == VMAGIC || magic == TMAGIC || magic == KMAGIC {
          // A recognised magic in the clear while a key exists: an old build on
          // the far end, or someone probing. Counted, never used.
          c.notePlaintextRx()
          continue
        }
        guard let m = c.open(buf, Int(n), into: dbuf) else { continue }
        plain = dbuf
        plainN = m
        magic = dbuf.withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) }
      }

      // A recognised magic from a reachable address is enough to point media
      // there. Once encryption is up this is genuine authentication: the packet
      // decrypted, so it came from someone holding the key.
      if magic == MAGIC || magic == VMAGIC || magic == TMAGIC || magic == KMAGIC {
        lastRecvHost = Clock.now()
        if !locked { adopt(src) }
      }
      if magic == VMAGIC {
        guard let v = video, plainN >= VHDR else { continue }
        let seq = Int32(bitPattern: (plain + 4).withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) })
        let cap8 = (plain + 8).withMemoryRebound(to: UInt64.self, capacity: 1) { UInt64(littleEndian: $0[0]) }
        let frag = Int((plain + 16).withMemoryRebound(to: UInt16.self, capacity: 1) { UInt16(littleEndian: $0[0]) })
        let nfrag = Int((plain + 18).withMemoryRebound(to: UInt16.self, capacity: 1) { UInt16(littleEndian: $0[0]) })
        if nfrag < 1 || nfrag > 4096 || frag >= nfrag { continue }
        v.take(seq: seq, frag: frag, nfrag: nfrag, capHost: cap8, bytes: plain + VHDR, n: plainN - VHDR)
        continue
      }
      if magic == KMAGIC { onKeyRequest?(); continue }
      if magic == TMAGIC {
        guard plainN >= TPKT else { continue }
        let t4 = Clock.now()   // stamp FIRST: everything after this is our own cost
        let kind = (plain + 4).withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) }
        let t1 = (plain + 8).withMemoryRebound(to: UInt64.self, capacity: 1) { UInt64(littleEndian: $0[0]) }
        // The far end's view of the path FROM HERE, on both the request and the
        // reply, so the report flows at the full probe rate in both directions.
        if plainN >= TPKTX {
          let l = (plain + TPKT).withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) }
          let rv = (plain + TPKT + 4).withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) }
          // Taken as-is. These CAN go backwards -- a peer restart zeroes them --
          // so the reader has to tolerate a negative delta rather than this end
          // pretending the counter is monotonic when it is not.
          peerRxLost = Int(l)
          peerRxRecovered = Int(rv)
          peerReportsLoss = true
        }
        if kind == 0 {
          // A request. Reply from THIS thread, immediately -- handing it to
          // another thread would put that thread's scheduling delay inside t3-t2,
          // where it is indistinguishable from network asymmetry and biases the
          // offset by half of it.
          var out = [UInt8](repeating: 0, count: TPKTX)
          out.withUnsafeMutableBytes { p in
            p.storeBytes(of: TMAGIC.littleEndian, toByteOffset: 0, as: UInt32.self)
            p.storeBytes(of: UInt32(1).littleEndian, toByteOffset: 4, as: UInt32.self)
            p.storeBytes(of: t1.littleEndian, toByteOffset: 8, as: UInt64.self)
            p.storeBytes(of: t4.littleEndian, toByteOffset: 16, as: UInt64.self)   // t2
            p.storeBytes(of: Clock.now().littleEndian, toByteOffset: 24, as: UInt64.self)  // t3
            appendRxReport(p)
          }
          out.withUnsafeBufferPointer { _ = rawSend($0.baseAddress!, $0.count) }
        } else {
          let t2 = (plain + 16).withMemoryRebound(to: UInt64.self, capacity: 1) { UInt64(littleEndian: $0[0]) }
          let t3 = (plain + 24).withMemoryRebound(to: UInt64.self, capacity: 1) { UInt64(littleEndian: $0[0]) }
          tsync?.note(t1: t1, t2: t2, t3: t3, t4: t4)
        }
        continue
      }
      if magic != MAGIC || plainN < HDR { continue }
      let seq = Int32(bitPattern: (plain + 4).withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) })
      let cap = (plain + 8).withMemoryRebound(to: UInt64.self, capacity: 1) { UInt64(littleEndian: $0[0]) }
      let frames = Int((plain + 16).withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) })
      // EXACTLY our packet size, or nothing. The old test was `frames > FPP`,
      // which is wrong in both directions during a rollout -- and the two machines
      // in a call update up to 60 s apart, so a rollout is guaranteed.
      //
      // A larger packet was dropped SILENTLY, which is indistinguishable from a
      // peer that is not sending at all. A smaller one PASSED, and wrote its
      // samples into a slot sized for ours, leaving the remainder as whatever the
      // previous packet left there: half the audio becomes stale garbage, which is
      // far worse than silence and says nothing about why.
      //
      // Now it is neither. A mismatch is refused and named, so the failure tells
      // you what it is and which side to fix.
      if frames <= 0 || plainN < HDR + frames * 4 { continue }
      if frames != FPP {
        fmtMismatch += 1
        // The far end is on another build and this call is going nowhere until one
        // of us moves. Ask the updater to look now instead of at the end of its
        // minute -- a wire-format change otherwise costs up to 60 s of silence in
        // the middle of a real conversation.
        if fmtMismatch == 1 { Update.urgent = true }
        if fmtMismatch == 1 || fmtMismatch % 4000 == 0 {
          fputs("audio: peer sends \(frames)-sample packets, this build expects \(FPP)"
              + " -- the two ends are on different versions, one side needs the update"
              + " (\(fmtMismatch) packets refused)\n", stderr)
        }
        continue
      }
      (plain + HDR).withMemoryRebound(to: Float.self, capacity: frames) { ring.write(seq: seq, cap: cap, src: $0, n: frames) }
      // A trailing block means this packet is also carrying an earlier one. Fill
      // the hole only if it IS a hole -- ring.write already refuses a duplicate,
      // and refuses anything the cursor has passed, so nothing here can overwrite
      // audio about to play.
      let redOff = HDR + frames * 4
      if plainN >= redOff + 8 + frames * 4, seq > 0 {
        let rCap = (plain + redOff).withMemoryRebound(to: UInt64.self, capacity: 1) { UInt64(littleEndian: $0[0]) }
        let rSeq = seq - 1
        if !ring.present(rSeq) {
          (plain + redOff + 8).withMemoryRebound(to: Float.self, capacity: frames) {
            ring.write(seq: rSeq, cap: rCap, src: $0, n: frames)
          }
          if ring.present(rSeq) { ring.recovered += 1 }
        }
      }
    }
  }
}
