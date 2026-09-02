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
// ── and four bytes of "what I can receive" ──────────────────────────────────
//
// Appended past HPKT, and the receive path already tests `n >= HPKT`, so a build
// that predates this reads its 36 bytes exactly as before and simply advertises
// nothing. Which is the point: a format change that assumes the far end can parse
// it is a silent break, and the two ends of a call update up to 60 s apart.
let HPKTX = HPKT + 4
let CAP_PCM16: UInt32 = 1 << 0
/// Lossless prediction + Rice coding on the payload. Advertised, never assumed:
/// a peer that does not know the format would read the mode byte as a sample.
let CAP_PCM_LP: UInt32 = 1 << 1
let MAGIC: UInt32 = 0x544B_0001
/// "send me a keyframe". Eight bytes, no payload, sent by a receiver that cannot
/// decode. Necessary because H.264 parameter sets ride only with keyframes and
/// keyframes here are on demand -- a receiver that joins late, or loses the one
/// packet that carried them, is otherwise blind for the entire call. Measured
/// exactly that: a peer starting 2 s late logged noFmt 346 and decoded nothing.
let KMAGIC: UInt32 = 0x544B_0003
// ── WORDS, NOT AUDIO ─────────────────────────────────────────────────────────
//
// The muted person's microphone never leaves their machine. Their own device
// recognises what they said and sends the TEXT, which is a few dozen bytes
// against a few dozen kilobytes -- so a subtitle costs one recognition on the
// speaker's own hardware and no network round trip at all, which is the only way
// it can keep up with somebody talking.
//
// It rides the media socket, so it is sealed by the same key as everything else
// and takes the same path the voice takes.
let SMAGIC: UInt32 = 0x544B_0007
// ── "I HUNG UP", SAID ON THE CALL ITSELF ────────────────────────────────────
//
// A call now outlives the process that was carrying it (Resume.swift), which
// means the far end can no longer read silence as a departure -- it has to be
// TOLD. There was already a way to say it, `Identity.ring(kind: "bye")`, and it
// cannot do this job: it is addressed to a HANDLE, and a call joined from a link
// has no handles at either end. It is also an HTTPS round trip through a mailbox,
// so it arrives after the process that sent it has gone.
//
// So the goodbye rides the media socket, sealed by the same key, straight to the
// address the media is already flowing to. Eight bytes, sent four times because
// UDP, and it is the last thing a leaving process does.
//
// AN OLD BUILD IS SAFE. `recvLoop` dispatches on the magic and this one matches
// nothing it knows, so it falls through to `if magic != MAGIC { continue }` and
// is dropped -- the same property that let the capability bits and the redundant
// block ship without breaking anybody. An old peer simply falls back to the room
// lease, which is the bound Resume.swift documents.
let BMAGIC: UInt32 = 0x544B_0008

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
  var recv = 0, dup = 0, jumps = 0, tooOld = 0, snaps = 0
  // ── TWO OPPOSITE FAULTS WERE SHARING ONE COUNTER ────────────────────────────
  //
  // `snaps` counts both directions of cursor repair, and they mean opposite
  // things about the jitter buffer:
  //
  //   snapsBehind -- the cursor was left with a BACKLOG: this machine stalled and
  //                  then had to catch up. A bigger buffer would not have
  //                  prevented it and would make every recovery longer.
  //   snapsPast   -- the cursor ran off the END of the stream and was reading
  //                  packets that had not arrived. That IS the buffer being too
  //                  small for the path, and growing is the whole remedy.
  //
  // The grow-veto downstream reads the union and calls all of it "stall, not
  // jitter", so starvation -- the one piece of evidence that the buffer is too
  // small -- was the reason given for refusing to enlarge it. Chronic starvation
  // therefore pinned the buffer at its opening size for the whole call.
  var snapsBehind = 0
  var snapsPast = 0
  // ── Count SAMPLES, not packet boundaries ───────────────────────────────────
  //
  // These were counted once per packet, at the sample where the read cursor
  // landed exactly on a packet boundary (`off == 0`). That gate is not always
  // reachable. A callback consumes 16 samples of a 32-sample packet, so it
  // crosses a boundary every other callback -- but the cursor is FRACTIONAL, and
  // at a rate a hair off 1.0 it skips exactly one input sample every other
  // callback. When the skipped sample is sample 0 of a packet, `off == 0` never
  // happens, and because the rate is within 0.08% of 1 the phase drifts so
  // slowly that it STAYS there. Measured on a healthy loopback call: 6542
  // consecutive callbacks, 2181 ms, without one boundary crossing.
  //
  // Two things rode that gate and both went blind together: `played` froze, so
  // the playout watchdog declared silence on perfect audio and re-anchored the
  // cursor -- causing the only real glitch in the run -- and `concealed` froze
  // with it, which is the dangerous half. A genuine two-second dropout during a
  // phase-lock would have reported `conceal 0`.
  //
  // A sample count cannot be skipped by any phase. Packet-equivalents are these
  // divided by FPP, so every consumer and the wire format keep their units.
  var playedS = 0, concealedS = 0, concealLostS = 0, concealStarvedS = 0
  /// Highest sequence any sample of which was actually OUTPUT. This is what
  /// separates the two ways a cursor ends up past the stream: displaced forward
  /// (it skipped packets that were never played, so rewinding plays them) versus
  /// a stalled stream (it played everything there was, so rewinding REPLAYS it).
  var maxPlayedSeq: Int64 = -1
  var played: Int { playedS / FPP }
  var concealed: Int { concealedS / FPP }
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
  /// Late arrivals that missed by less than one packet -- the only ones a single
  /// extra packet of buffer would have saved.
  var nearLate = 0
  /// Packets written into the ring. Distinct from `played`: a healthy receive with
  /// a dead playout is a real state and it needs two counters to be visible.
  var accepted = 0

  /// One sample by ABSOLUTE index, or nil if the packet holding it is not here.
  /// The resampler needs neighbours either side of the read cursor and a missing
  /// neighbour has to be visible as missing -- substituting a zero would put a
  /// notch in the waveform at every packet edge.
  @inline(__always) func sampleAt(_ i: Int64) -> Float? {
    guard i >= 0 else { return nil }
    let sq = Int32(i / Int64(FPP))
    guard present(sq) else { return nil }
    return samples[(Int(sq) % RING) * FPP + Int(i % Int64(FPP))]
  }
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
  var concealLost: Int { concealLostS / FPP }
  var concealStarved: Int { concealStarvedS / FPP }
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
      if ms < 0 {
        lateArrivals += 1
        // ── Lateness that one more packet of buffer would actually have caught ──
        //
        // Growing the buffer by one packet saves an arrival that missed by LESS
        // THAN ONE PACKET. It does nothing for one that missed by 15 ms, and the
        // controller had no way to tell the two apart: it grew on the count of
        // late arrivals, so a path that stalls 15 ms every three seconds drove it
        // from 6 packets to 26 and still climbing, with grows logged at slack p01
        // +5.15 ms and +14.44 ms -- comfortable margin, deep outliers, and twenty
        // consecutive grows that could not have helped and did not.
        //
        // This is the same attribution the controller already does for stalls and
        // for loss, applied to the one case it was still missing: attribute the
        // symptom to a MAGNITUDE the action can address, not just to a count.
        if ms > -(Double(FPP) / SR * 1000.0) { nearLate += 1 }
      }
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
    accepted += 1
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
  var turn: TurnClient?
  /// Once the race picks the TURN path, media is ChannelData to the TURN server
  /// instead of raw UDP to the peer.
  var sendViaTurn = false
  /// Sent in the clear, necessarily: it is what establishes the key. Contains a
  /// public key and nothing else -- no identity, no room code, nothing that is
  /// worth anything to a listener on its own.
  func sendHandshake() {
    guard let c = crypto else { return }
    // Signed once and cached inside Crypto; this is a 136-byte copy per beat.
    let out = c.handshakePacket(caps: Wire.myCaps)
    out.withUnsafeBufferPointer { wireSend($0.baseAddress!, $0.count) }
  }
  /// Fired on the receive thread when a NEW, verified identity keyed the call.
  /// The argument is the peer's Ed25519 identity, base64 -- what contacts.json
  /// stores. main.swift pins it under the handle this call is with.
  var onPeerIdentity: ((String) -> Void)?
  /// Float in [-1,1] to signed 16-bit. Clamped, because a microphone CAN exceed
  /// full scale and a wrapped sample is a click at full amplitude. 32767 both ways
  /// so the round trip is exact rather than off by one part in 32768.
  @inline(__always) private func unpack16(_ src: UnsafePointer<UInt8>, _ n: Int,
                                          into dst: UnsafeMutablePointer<Float>) {
    src.withMemoryRebound(to: Int16.self, capacity: n) { p in
      for i in 0..<n { dst[i] = Float(Int16(littleEndian: p[i])) / 32767.0 }
    }
  }

  @inline(__always) private func pack16(_ src: UnsafePointer<Float>, _ n: Int,
                                        into dst: UnsafeMutablePointer<UInt8>) {
    dst.withMemoryRebound(to: Int16.self, capacity: n) { out in
      for i in 0..<n {
        let v = max(-1.0, min(1.0, src[i])) * 32767.0
        out[i] = Int16(v.rounded())
      }
    }
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
    // ── 16-bit on the wire, when the far end says it can read it ────────────
    //
    // The audio was costing 2.43 Mbps and the VIDEO of a person talking costs
    // 0.15 -- sixteen times less -- because the samples went out as 32-bit float.
    // A microphone's own noise floor is nowhere near 96 dB down, so the bottom
    // sixteen bits of every sample are the preamp's noise sent at full price.
    //
    // The format rides in the high bits of the frame count, which is only safe
    // because a packet is never sent in this format until the peer has advertised
    // it in the handshake. Guessing here would mean an old build computing
    // frames = 65568 and dropping the packet in silence.
    let pcm16 = sendPcm16
    let lp = sendLp
    let bps = pcm16 ? 2 : 4
    let tag = UInt32(n) | (pcm16 ? (1 << 16) : 0) | (lp ? (1 << 17) : 0)
    (scratch + 16).withMemoryRebound(to: UInt32.self, capacity: 1) { $0[0] = tag.littleEndian }
    // A compressed block is variable length, so it carries its own length byte.
    // Deriving it from the datagram size would work for the primary block and be
    // ambiguous the moment a redundant block follows.
    func put(_ from: UnsafePointer<Float>, _ at: Int) -> Int {
      guard lp else {
        if pcm16 { pack16(from, n, into: scratch + at) } else { memcpy(scratch + at, from, n * 4) }
        return n * bps
      }
      pack16(from, n, into: lpTmp)
      let m = lpTmp.withMemoryRebound(to: Int16.self, capacity: n) {
        Lpc.encode($0, n, into: scratch + at + 1)
      }
      scratch[at] = UInt8(m)
      lpIn += n * 2; lpOut += m + 1
      if scratch[at + 1] & 0x80 != 0 { lpRaws += 1 }
      return 1 + m
    }
    var total = HDR + put(src, HDR)
    if let r = redundant {
      (scratch + total).withMemoryRebound(to: UInt64.self, capacity: 1) { $0[0] = redundantCap.littleEndian }
      let before = total
      total += 8 + put(r, total + 8)
      genFec += total - before
      redundantSent += 1
    }
    // Through rawSend, not sendto. This path used to call sendto directly, which
    // meant the impairment gate -- and anything else that ever belongs on the way
    // out -- saw video fragments and clock probes but never a single audio packet.
    // A 20% loss arm dropped 13 packets out of twelve thousand and the receiver
    // reported zero concealment, so the rig said the app shrugs off heavy loss
    // while actually testing nothing. One send path, one gate.
    rawSend(scratch, total, .audio)
  }

  // ── Which stream those bytes belonged to ──────────────────────────────────
  //
  // `sentBytes` sums audio, video, clock probes and keyframe requests into one
  // number, and DESIGN 17.105 then named an "unexplained" inflation to 1.4-2.4
  // Mbps under 3% loss as a possible video problem. It was not video. Audio
  // redundancy turns on under loss and sends a full copy of the previous packet,
  // which doubles the audio stream -- a documented feature of this same program,
  // read through an instrument that cannot tell three streams apart. Attribute
  // before acting; an aggregate counter cannot attribute.
  //
  // Counted HERE, at the point the program decides to emit, rather than in
  // wireSend: the rig's drop and delay stages sit in between, and the question
  // this answers is "what did the app choose to send", which is the question a
  // bandwidth number is always really asking. `sentBytes` still measures what
  // reached the socket, so the difference is exactly the impairment.
  enum TxCls { case audio, video, probe, ctl }
  /// Armed from the peer's own report of loss on the path from here. See sendVideo.
  nonisolated(unsafe) var videoParity = false
  nonisolated(unsafe) var parityFragsSent = 0
  private(set) var genAudio = 0, genVideo = 0, genProbe = 0, genCtl = 0
  /// Of `genAudio`, the bytes that were a second copy of an earlier packet. This
  /// is the price of loss repair, and it should be readable on its own.
  private(set) var genFec = 0

  /// One datagram, already framed by the caller. Shared by the audio and video
  /// paths so there is exactly one socket, one port and one NAT binding per peer
  /// -- two ports would mean two hole-punches and two things to go wrong.
  ///
  /// `cls` has no default on purpose: a new send path that forgets to say what it
  /// is would otherwise be silently filed as audio, which is the exact failure
  /// this parameter exists to have prevented.
  func rawSend(_ p: UnsafePointer<UInt8>, _ n: Int, _ cls: TxCls) {
    switch cls {
    case .audio: genAudio += n + 28
    case .video: genVideo += n + 28
    case .probe: genProbe += n + 28
    case .ctl:   genCtl += n + 28
    }
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
            if im.shouldDrop(bytes: m) { return }
            // A FULL LINK, not a lossy one: the excess waits behind what is
            // already queued instead of vanishing. See `Impair.queueDelayMs`.
            if im.capacityQueue, im.capacityMbps > 0 {
              guard let waitMs = im.queueDelayMs(m) else { return }   // queue full
              if waitMs > 0.05, let q = delayQ {
                q.push(out, m, due: Clock.now() + Clock.ticks(ns: UInt64(waitMs * 1_000_000))); return
              }
            }
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
    // No key yet. NOTHING goes out in the clear -- not audio, not video, not a
    // clock probe. v1 sent plaintext here "until the handshake completed", which
    // was a downgrade an attacker could hold open by dropping 136-byte packets.
    // Dropped and counted; the handshake has its own path (`sendHandshake`).
    crypto?.notePreKeyDrop()
    return
  }

  private(set) var cryptSendFails = 0
  private(set) var handshakeReplies = 0
  private(set) var redundantSent = 0

  private func wireSend(_ p: UnsafePointer<UInt8>, _ n: Int) {
    if sendViaTurn, let t = turn {
      if t.sendChannel(fd: fd, p, n) { sent += 1; sentBytes += n + 28 + 4 }
      else { sendErrs += 1 }
      return
    }
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
  // Two long-lived threads touch this array for the whole call: the 0.5 s
  // rediscovery loop (main.swift:1151) appends, iterates and clears it, and the
  // 20 s directory refresh (main.swift:1235) appends to it. An `append` that
  // reallocates while the other thread is mid-iteration is the SIGSEGV that has
  // already ended live calls from the render callback -- no Swift collection is
  // shared across threads here without a lock. Same reason and same shape as
  // `pathLock` below; the send loop copies out and releases before any syscall,
  // because a lock held across `sendto` is a lock held across the network.
  private let candLock = NSLock()
  private(set) var locked = false
  private(set) var lockedFrom = ""

  func addCandidate(ip: String, port: UInt16) {
    var a = sockaddr_in()
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    a.sin_addr.s_addr = inet_addr(ip)
    candLock.lock()
    if !candidates.contains(where: { $0.sin_addr.s_addr == a.sin_addr.s_addr && $0.sin_port == a.sin_port }) {
      candidates.append(a)
    }
    candLock.unlock()
  }

  func clearCandidates() { candLock.lock(); candidates.removeAll(); candLock.unlock() }

  /// Punch every candidate. Cheap: a 32-byte clock probe doubles as the probe
  /// that opens the NAT binding, so connectivity and offset are established by
  /// the same packet.
  func probeAllCandidates() {
    guard !locked else { return }
    var out = [UInt8](repeating: 0, count: TPKTZ)
    out.withUnsafeMutableBytes { p in
      p.storeBytes(of: TMAGIC.littleEndian, toByteOffset: 0, as: UInt32.self)
      p.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 4, as: UInt32.self)
      p.storeBytes(of: Clock.now().littleEndian, toByteOffset: 8, as: UInt64.self)
      appendRxReport(p)
    }
    candLock.lock()
    let targets = candidates
    candLock.unlock()
    for c in targets {
      var a = c
      out.withUnsafeBufferPointer { b in
        _ = withUnsafePointer(to: &a) { pp in
          pp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            sendto(fd, b.baseAddress!, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
          }
        }
      }
    }
    // And through our TURN allocation, so the relayed path is in the same race.
    if let t = turn {
      out.withUnsafeBufferPointer { t.sendChannel(fd: fd, $0.baseAddress!, $0.count) }
    }
  }

  /// A packet arrived and parsed. We do NOT lock onto the first address that
  /// answers — that is the public-internet path as often as the short one.
  /// Candidates are raced by measured RTT (time-sync replies) for ~150 ms, then
  /// the lowest wins. First packet still starts media flowing (tentative).
  /// Host time of the last packet we accepted from the peer. This, not
  /// `locked`, is what "connected" means -- a remembered address is a claim about
  /// the past, and the only evidence a path still works is traffic on it.
  private(set) var lastRecvHost: UInt64 = 0
  /// The last packet from THE ADDRESS THIS END IS LOCKED TO, which is a different
  /// question from `lastRecvHost` and the only honest input to "have they gone".
  ///
  /// Answering a ring re-execs the callee, and the new image can come from a new
  /// address -- a fresh TURN allocation always does. The caller stays locked to
  /// the dead one, while the new one's probes keep refreshing `lastRecvHost` on
  /// every packet, so a silence detector reading that stamp never fires: media
  /// goes on being sent to an address nobody is at, forever. Liveness is
  /// last-heard-from THE PEER, never last-heard-from anybody.
  private(set) var lastFromPeer: UInt64 = 0
  /// The last packet before a silence of more than a second, and the first one
  /// after it. Written only by the receive thread, read by the poll loop, and
  /// deliberately NOT cleared here -- the reader clears them, so a reader that is
  /// late still gets the true pair rather than a gap that grew while it waited.
  var peerGoneAt: UInt64 = 0
  var peerBackAt: UInt64 = 0
  private(set) var relocks = 0
  private var pathRtt: [String: Double] = [:]
  private var pathAddr: [String: sockaddr_in] = [:]
  private var raceBegan: UInt64 = 0
  private var raceSettled = false

  // ── TWO THREADS, ONE DICTIONARY ─────────────────────────────────────────────
  //
  // `pathRtt` and `pathAddr` are written by the RECEIVE thread (a probe reply
  // reaches `notePath`) and emptied by the REDISCOVERY thread
  // (`unlockForRediscovery`, from main.swift's poll loop). Two threads mutating
  // one Swift Dictionary is not a stale read, it is heap corruption: a resize
  // moves the storage under the other thread's feet, and the app vanishes
  // mid-call with no message. A SIGSEGV out of a real-time callback has already
  // ended live calls in this project, which is why the rule here is that no
  // Swift collection is shared across threads without a lock.
  //
  // AND THE TWO EVENTS ARE CORRELATED, NOT INDEPENDENT, which is what makes this
  // likely rather than theoretical: the media gap that provokes rediscovery ends
  // with the peer's probe reply arriving, so the `removeAll()` and the insert are
  // provoked by the same instant. The race is not a coincidence waiting to
  // happen, it is the reconnection path.
  //
  // A lock on the time-constraint receive thread is affordable HERE and would not
  // be a few lines lower: `notePath` is reached only by a TMAGIC probe *reply*,
  // which is about 1 Hz. Audio is 375 packets a second and never touches these.
  // The critical section is a handful of dictionary operations and no I/O at all
  // -- every `fputs` is deferred until after the unlock, so a blocked stderr
  // cannot hold this lock while the receive thread waits behind it. Same pattern,
  // and for the same reason, as `RelayBox` in Turn.swift.
  private let pathLock = NSLock()

  private func pathKey(_ a: sockaddr_in) -> String {
    var ipb = [CChar](repeating: 0, count: 64)
    var f = a
    inet_ntop(AF_INET, &f.sin_addr, &ipb, 64)
    let kind = turn?.isTurnServer(a) == true ? "relay" : "direct"
    return "\(kind) \(String(cString: ipb)):\(UInt16(bigEndian: a.sin_port))"
  }

  func notePath(_ from: sockaddr_in, rttMs: Double) {
    // Outside the lock on purpose: `pathKey` allocates (a [CChar], a String, an
    // interpolation) and allocation is the one thing that must not happen while
    // the receive thread holds a lock the rediscovery thread also wants.
    let k = pathKey(from)
    var firstSighting = false
    var line: String?
    pathLock.lock()
    pathAddr[k] = from
    if let prev = pathRtt[k] {
      if rttMs < prev { pathRtt[k] = rttMs }
    } else {
      pathRtt[k] = rttMs
      firstSighting = true
    }
    if raceBegan == 0 { raceBegan = Clock.now() }
    line = pickBestPathLocked()
    pathLock.unlock()
    // Both of these used to be inside what is now the critical section. stderr can
    // block for an unbounded time (a full pipe, a slow terminal), and a lock held
    // across a blocking write is a lock held for as long as the reader is asleep.
    if firstSighting {
      fputs("path: \(k) rtt \(String(format: "%.2f", rttMs)) ms\n", stderr)
    }
    if let line { fputs(line, stderr) }
  }

  /// CALLER HOLDS `pathLock`. Returns the line to print, which the caller prints
  /// after unlocking -- the naming says so because a second `pathLock.lock()` in
  /// here would deadlock the receive thread against itself, and NSLock is not
  /// recursive.
  private func pickBestPathLocked() -> String? {
    guard let best = pathRtt.min(by: { $0.value < $1.value }),
          let addr = pathAddr[best.key] else { return nil }
    let elapsed = raceBegan == 0 ? 0 : Clock.ms(Clock.now() - raceBegan)
    // Tentative: first working path so the call starts. Settled after 150 ms
    // of racing, or sooner if two paths have spoken and 60 ms have passed.
    let settle = elapsed >= 150 || (pathRtt.count >= 2 && elapsed >= 60)
    if !locked {
      adopt(addr)
      sendViaTurn = turn?.isTurnServer(addr) == true
    }
    guard settle, !raceSettled else { return nil }
    raceSettled = true
    if pathKey(peer) != best.key {
      // Read BEFORE the reassignment below: the line says which path we are
      // leaving, and `lockedFrom` is about to stop being that.
      let was = lockedFrom
      peer = addr
      locked = true
      lockedFrom = best.key
      sendViaTurn = turn?.isTurnServer(addr) == true
      return "path: picked \(best.key) at \(String(format: "%.2f", best.value)) ms rtt"
           + " (was \(was))\n"
    }
    return "path: kept \(best.key) at \(String(format: "%.2f", best.value)) ms rtt\n"
  }

  /// What the PEER has lost and recovered on the path FROM HERE. Cumulative, so
  /// a reader that samples at any cadence gets a true delta -- a windowed average
  /// read on the wrong cadence has inverted an A/B in this project before.
  /// `--no-rt` exists so the thread policy can be A/B'd against itself. A change
  /// nobody can turn off is a claim, not a measurement.
  nonisolated(unsafe) static var noRealtime = false
  /// What this build can receive, and what the far end says it can.
  nonisolated(unsafe) static var myCaps: UInt32 = CAP_PCM16 | CAP_PCM_LP
  /// `--pcm32` forces the old format so the change can be A/B'd from either side.
  nonisolated(unsafe) static var forceFloat = false
  nonisolated(unsafe) static var forceNoLp = false
  private(set) var peerCaps: UInt32 = 0
  var sendPcm16: Bool { !Wire.forceFloat && (peerCaps & CAP_PCM16) != 0 }
  /// Compression rides ON TOP of 16-bit: the coder's input is int16 samples, so
  /// without pcm16 there is nothing for it to compress.
  var sendLp: Bool { !Wire.forceNoLp && sendPcm16 && (peerCaps & CAP_PCM_LP) != 0 }
  /// Wire bytes actually spent on payload, coded and raw, so the ratio the call
  /// achieved is reported rather than assumed from an offline measurement.
  nonisolated(unsafe) var lpIn = 0
  nonisolated(unsafe) var lpOut = 0
  nonisolated(unsafe) var lpRaws = 0
  nonisolated(unsafe) var lpBadDecode = 0
  /// int16 staging for the coder's input, owned by the capture thread.
  private let lpTmp = UnsafeMutablePointer<UInt8>.allocate(capacity: Lpc.MAXN * 2)
  private(set) var peerRxLost: Int = 0
  private(set) var peerRxRecovered: Int = 0
  /// What the far end reports about ITSELF. `peerPlayed` is the one that
  /// separates "they cannot hear me" from "they are fine and I am not sending".
  private(set) var peerPlayed: Int = 0
  private(set) var peerMuted = false
  private(set) var peerQLevel = 0
  private(set) var peerStatus = 0
  private(set) var peerReportsState = false
  /// Our own half of the same report, set once a second by the reporter.
  var selfMuted = false
  var selfQLevel = 0
  // ── THE STATUS BYTE: WHY THE PICTURE STOPPED ───────────────────────────────
  //
  // This byte has been on the wire in every packet since the TPKTX arm was
  // added, and nothing has ever written to it -- a channel with a reader and no
  // sender. It now carries the two reasons video legitimately stops, because
  // the far end cannot tell either of them from a crash: frames simply cease,
  // the last one stays on screen, and a still face is the single most alarming
  // thing a call can do.
  //
  // Two bits, not one, and that distinction is the whole point. "Their
  // connection is weak" and "they turned their camera off" produce identical
  // wire behaviour and demand opposite reactions from the person watching.
  // Guessing between them from frame arrival alone would be a coin flip
  // presented as a diagnosis.
  static let ST_VPAUSED = 1        // video stopped because the link could not carry it
  static let ST_CAMOFF  = 2        // video stopped because a human pressed the button
  // WHAT THIS END'S VOICE IS DOING, so the other end can DRAW it. These are cues
  // and never commands: nothing at the far end is muted, opened or overridden by
  // them. A person reads the cue and stops talking, and their stopping is what
  // opens this microphone -- through a purely local rule, with nothing
  // arbitrating and nothing to deadlock.
  static let ST_BACKCHAN = 4       // a listening noise: "mm-hm", not a bid
  static let ST_CLAIM    = 8       // this end wants to say something
  // ── PRESENT IS NOT THE SAME AS ANSWERED ───────────────────────────────────
  //
  // A Mac that is only being ASKED now joins the room and receives, so that the
  // person can see who is calling before deciding. It sends no audio and no
  // video -- but it does punch a hole, and packets arriving from an address is
  // exactly what this app has always taken for "they are here". That reading is
  // what made a ring answer itself once already. So the asking end says so, and
  // every conclusion drawn from arrival has to consult this bit first.
  static let ST_RINGING  = 16      // this end is being asked and has not said yes
  // ── MAKING SOUND RIGHT NOW, WHICH IS NOT THE SAME AS CLAIMING ─────────────
  //
  // `ST_CLAIM` is a classification and it deliberately OUTLIVES the sound: the
  // gate keeps a vocalisation alive through 450 ms of silence so a breath
  // between words does not end somebody's turn, and the edge drawing wants
  // exactly that. The floor wants the opposite. Measured in `--turn-test`: the
  // second speaker was silenced for 35% of everything they said, because the
  // holder's cue still said CLAIM for 450 ms after they had actually stopped,
  // so the release clock never even started -- `one-condition-two-concerns`,
  // one bit answering "whose turn is it" and "is a voice coming out now".
  //
  // This bit is the second question, with a 120 ms hangover of its own: longer
  // than a plosive closure, far shorter than a turn gap. An older build leaves
  // it clear, and a peer that never sets it is read as "cannot say", which
  // falls back to the claim-based release -- today's behaviour exactly.
  static let ST_VOICING  = 32      // a voice is leaving this microphone now
  // ── AND WHAT THE CAMERA AT THIS END CAN SEE (0.102.0) ─────────────────────
  //
  // The lip-motion detector was local-only in 0.100/0.101: each Mac watched its
  // own camera and used it for its own decisions, and the far end learnt
  // nothing. This bit is the other half, and it is the one that can beat the
  // network.
  //
  // A mouth starts moving BEFORE sound comes out of it -- the jaw and lips open
  // for a vowel some tens of milliseconds ahead of voicing. So a cue sent the
  // instant the mouth moves can arrive at the far end BEFORE the first audio of
  // that same word would have. One hop of propagation is paid out of the
  // pre-speech lead rather than added on top, which is the only mechanism in
  // this project that can make a handover feel like it cost nothing.
  //
  // What the receiver may do with it is deliberately narrow: a holder may LET GO
  // sooner. It may never mute anybody, never grant a floor, and a build that
  // does not set the bit reads as "cannot say" rather than "not talking" --
  // `blind-instruments-report-negatives`, and this is the wire's version of it.
  static let ST_SEEN_TALKING = 64  // a camera here sees this end's mouth moving
  // MUTE IS NOT IN THIS BYTE. It rides at TPKTX+4 as its own byte and has since
  // before this one existed -- see `selfMuted`/`peerMuted` above. Noted here
  // because "the status byte" reads like the complete list of what one end tells
  // the other, and it is not.

  /// The turn-end prior, 0-1, packed into TPKTX+7 (the byte that used to be pad).
  /// An older build writes 0 and never reads it, which is the value that changes
  /// nothing at this end -- so a mixed-version call behaves as 0.92.0.
  static func endProbByte(_ p: Double) -> UInt8 {
    UInt8(clamping: Int((min(1, max(0, p)) * 255.0).rounded()))
  }
  static func endProb(from b: UInt8) -> Double { Double(b) / 255.0 }

  var selfStatus = 0
  /// What the far end's status byte says. Both are false against a build that
  /// predates the byte, which is correct: it never pauses and never reports.
  var peerVideoPaused: Bool { peerStatus & Wire.ST_VPAUSED != 0 }
  var peerCamOff: Bool { peerStatus & Wire.ST_CAMOFF != 0 }
  var peerBackchannel: Bool { peerStatus & Wire.ST_BACKCHAN != 0 }
  var peerClaim: Bool { peerStatus & Wire.ST_CLAIM != 0 }
  /// The far end is looking at a ring card, not at you. False against every build
  /// that predates the bit -- correct, because those never joined before
  /// answering, so their arrival really did mean answered.
  var peerRinging: Bool { peerStatus & Wire.ST_RINGING != 0 }
  /// Has a status byte ever arrived from the far end? False both for a peer that
  /// has said nothing yet and for a build older than the byte -- so a caller
  /// waiting on it needs a deadline as well.
  private(set) var peerStatusSeen = false
  var peerVocal: Bool { peerStatus & (Wire.ST_BACKCHAN | Wire.ST_CLAIM) != 0 }
  /// Is the far end making sound right now? `nil` when they cannot say -- a
  /// build older than `ST_VOICING`, or nothing heard from them yet -- which is
  /// the value that changes nothing at this end.
  var peerVoicing: Bool? {
    guard peerStatusSeen, peerVocalSeen else { return nil }
    return peerStatus & Wire.ST_VOICING != 0
  }
  /// Does a camera at the FAR end see their mouth moving? `nil` when they
  /// cannot say -- a build older than the bit, a peer with no camera, a dark
  /// room, or nothing heard yet. Same three-state rule as the local detector:
  /// absence of evidence is never evidence of silence.
  var peerSeenTalking: Bool? {
    guard peerStatusSeen, peerSeenTalkingSeen else { return nil }
    return peerStatus & Wire.ST_SEEN_TALKING != 0
  }
  /// Has a peer that sets the seen-talking bit ever been observed setting it?
  /// The bit being CLEAR only means something from a build (and a camera) that
  /// would have set it, and the sole evidence of that is having seen it once.
  private(set) var peerSeenTalkingSeen = false

  /// Has a peer that sets the voicing bit ever been seen? The bit being CLEAR
  /// is meaningful only from a build that would have set it, and the only
  /// evidence of that is having seen it set once.
  private(set) var peerVocalSeen = false
  /// The same byte as the turn layer's tri-state. A bid outranks a listening
  /// noise if a build ever sets both, because mistaking a bid for a continuer
  /// costs somebody their turn and the other way round costs a cue.
  var peerVoice: Floor.Voice {
    if peerStatus & Wire.ST_CLAIM != 0 { return .claim }
    if peerStatus & Wire.ST_BACKCHAN != 0 { return .backchannel }
    return .quiet
  }
  /// 0 quiet, 1 listening noise, 2 bid for the floor. Fires only when it changes.
  var onPeerVocal: ((Int) -> Void)?
  private var lastVocalSent = -1

  // ── THE STATE THE CUE RIDES ON, SENT WHEN IT CHANGES ──────────────────────
  //
  // Polled rather than pushed, because the thing that knows -- the duplex gate --
  // runs inside the capture callback, and a socket write from a real-time audio
  // thread is how this project has killed live calls before. So a plain thread
  // watches the classification and sends a probe the moment it moves.
  //
  // A probe, not a new packet type: it already carries the whole state block, the
  // far end already parses it, and an extra 32 bytes a few times a second is
  // nothing next to a 3 Mbps call. It also buys a free clock sample.
  private var lastVocalOut = -1
  private var lastVoicingOut = false
  private var lastStateFlush: UInt64 = 0
  private var lastPredictAbove = false
  /// Returns true if the classification has moved since the last flush and enough
  /// time has passed to send another. Called from the watcher thread only.
  func vocalChanged() -> Bool {
    let v: Int
    switch Audio.sharedGate.vocal {
    case .quiet: v = 0
    case .backchannel: v = 1
    case .claim: v = 2
    }
    // The voicing bit rides the same watcher, because a signal with a 120 ms
    // hangover that only travelled on a 300 ms heartbeat would arrive after
    // the wait it exists to end (`fast-signal-on-a-slow-carrier`).
    let voicing = Audio.sharedGate.voicingNow
    guard v != lastVocalOut || voicing != lastVoicingOut else { return false }
    // A floor under the rate, so a classifier chattering on a noisy microphone
    // cannot turn into a packet storm. 15 ms is far below anything a person can
    // see and far above anything a gate does in normal speech.
    let now = Clock.now()
    guard lastStateFlush == 0 || Clock.ms(now - lastStateFlush) > 15 else { return false }
    lastVocalOut = v
    lastVoicingOut = voicing
    lastStateFlush = now
    return true
  }
  /// True when this end's turn-end prior has crossed the floor's threshold
  /// since the last flush. Same watcher, same 15 ms floor as `vocalChanged` --
  /// a prior that only rides the 1 Hz probe is a prior that arrives a second
  /// late (`fast-signal-on-a-slow-carrier`), which is longer than the 450 ms
  /// wait it exists to skip.
  /// True when the camera's verdict about this end has flipped since the last
  /// flush. Its own edge trigger, for the same reason `predictCrossed` has one:
  /// a signal whose entire worth is arriving BEFORE the voice must not wait for
  /// a periodic carrier (`fast-signal-on-a-slow-carrier`). Same 15 ms floor.
  private var lastSeenTalking = false
  func seenTalkingCrossed() -> Bool {
    let now2 = Mouth.on && Mouth.visualKnown && Mouth.visualVoice
    guard now2 != lastSeenTalking else { return false }
    let now = Clock.now()
    guard lastStateFlush == 0 || Clock.ms(now - lastStateFlush) > 15 else { return false }
    lastSeenTalking = now2
    lastStateFlush = now
    return true
  }

  func predictCrossed() -> Bool {
    let above = Audio.turnEndProb >= Audio.sharedFloor.cfg.predictP
    guard above != lastPredictAbove else { return false }
    let now = Clock.now()
    guard lastStateFlush == 0 || Clock.ms(now - lastStateFlush) > 15 else { return false }
    lastPredictAbove = above
    lastStateFlush = now
    return true
  }
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
    // The TPKTY arm. Guarded on the buffer actually being long enough, because
    // this function is also handed the shorter probe on paths that have not been
    // widened -- writing past the end there would be memory corruption, not a
    // missing field.
    guard p.count >= TPKTY else { return }
    p.storeBytes(of: UInt32(truncatingIfNeeded: r?.played ?? 0).littleEndian,
                 toByteOffset: TPKTX, as: UInt32.self)
    p.storeBytes(of: UInt8(selfMuted ? 1 : 0), toByteOffset: TPKTX + 4, as: UInt8.self)
    p.storeBytes(of: UInt8(truncatingIfNeeded: selfQLevel), toByteOffset: TPKTX + 5, as: UInt8.self)
    // ── READ HERE, BUT SENT WHEN? ─────────────────────────────────────────────
    //
    // This used to say "read at packet time, not once a video frame", which was
    // true about the READ and silent about the delivery -- and the delivery is the
    // whole number. The only packet with a TPKTY payload is the time probe, and
    // the probe settles to ONE A SECOND after the first few. So the cue that this
    // design promises lands "one hop after they open their mouth" was arriving up
    // to a second late, and on a live call it showed a listening noise through six
    // seconds of somebody talking.
    //
    // Fixed by `wantsStateFlush` below: the state is still carried here, unchanged,
    // and a watcher sends an EXTRA probe the moment the classification changes.
    // Edge-triggered for speed, level-triggered once a second for repair -- so a
    // dropped edge costs a second of staleness rather than a cue that is wrong for
    // the rest of the call.
    var vocalBits: Int
    switch Audio.sharedGate.vocal {
    case .quiet:       vocalBits = 0
    case .backchannel: vocalBits = Wire.ST_BACKCHAN
    case .claim:       vocalBits = Wire.ST_CLAIM
    }
    if Audio.sharedGate.voicingNow { vocalBits |= Wire.ST_VOICING }
    // The camera's verdict about THIS end, beside the voice cue it belongs with.
    let seenBits = (Mouth.on && Mouth.visualKnown && Mouth.visualVoice)
      ? Wire.ST_SEEN_TALKING : 0
    p.storeBytes(of: UInt8(truncatingIfNeeded: selfStatus | vocalBits | seenBits),
                 toByteOffset: TPKTX + 6, as: UInt8.self)
    // ── THE PRIOR RIDES BESIDE THE VOCAL BYTE ────────────────────────────────
    //
    // TPKTX+7 was pad. The number is computed where the words are (this
    // machine's transcript) and applied where the gate is (the far end's floor),
    // which is why it has to travel: subtitles only cross when the sender cannot
    // be heard, and the interesting moment is while they still hold the floor.
    // An older build writes 0 here and never reads it.
    p.storeBytes(of: Wire.endProbByte(Audio.turnEndProb),
                 toByteOffset: TPKTX + 7, as: UInt8.self)
    // The video's own receive-side numbers. See TPKTZ.
    guard p.count >= TPKTZ, let v = reportVideo else { return }
    p.storeBytes(of: UInt32(truncatingIfNeeded: v.missing).littleEndian,
                 toByteOffset: TPKTY, as: UInt32.self)
    p.storeBytes(of: UInt32(truncatingIfNeeded: v.fragsIn).littleEndian,
                 toByteOffset: TPKTY + 4, as: UInt32.self)
  }

  /// The video assembler whose counters get reported to the peer, set when the
  /// receive loop starts. Weak and optional for the same reason `reportRing` is:
  /// an audio-only call has none and reports nothing rather than zeros.
  private weak var reportVideo: VideoAssembler?
  /// The far end's video loss, cumulative since ITS process start, and whether it
  /// tells us at all. `peerVideoFrags` is the denominator -- a count with nothing
  /// to divide by is the bug class this repo already has a name for.
  private(set) var peerVideoMissing = 0
  private(set) var peerVideoFrags = 0
  private(set) var peerReportsVideoLoss = false

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
    // ── AND FORGET WHAT THE OLD PROCESS SAID ABOUT ITSELF ────────────────────
    //
    // Answering a ring RE-EXECS the callee, so the peer this end is about to
    // rediscover is a different image of the same app -- one that is no longer
    // ringing. Keeping `peerStatus` across that gap would leave `ST_RINGING` set
    // against a process that has answered, and the caller's microphone is zeroed
    // on exactly that bit: the first words after somebody picks up would be
    // silence, for as long as it took the new image's first probe to arrive.
    // A status is a statement by a particular process, and this is the line
    // where that process stops existing as far as this end is concerned.
    peerStatus = 0
    peerStatusSeen = false
    peerVocalSeen = false
    peerSeenTalkingSeen = false
    Audio.peerTurnEndProb = 0
    Audio.sharedFloor.noteFarEndProb(0)
    // Not nested inside `pathLock` below: nothing takes both, and keeping them
    // sequential means no future caller can invent a lock-order deadlock here.
    candLock.lock()
    candidates.removeAll()
    candLock.unlock()
    // Under the lock: this runs on the rediscovery thread while the receive thread
    // may be inserting the very probe reply that ends the gap which sent us here.
    pathLock.lock()
    pathRtt.removeAll()
    pathAddr.removeAll()
    raceBegan = 0
    raceSettled = false
    pathLock.unlock()
    sendViaTurn = false
    relocks += 1
  }

  /// Stamped at the lock so the silence detector starts from a fresh reading
  /// rather than from whatever the previous peer left behind.
  func markPeerFresh() { lastFromPeer = Clock.now() }

  private func adopt(_ from: sockaddr_in) {
    guard !locked else { return }
    adoptFrom(from)
  }

  static func describe(_ from: sockaddr_in) -> String {
    var ipb = [CChar](repeating: 0, count: 64)
    var f = from
    inet_ntop(AF_INET, &f.sin_addr, &ipb, 64)
    return "\(String(cString: ipb)):\(UInt16(bigEndian: from.sin_port))"
  }

  /// The same move without the "only once" guard, for the one caller that has
  /// already established the lock is pointing somewhere the far end is not
  /// sending from. Kept as a separate entry point rather than relaxing `adopt`,
  /// because `adopt`'s guard is what stops every arriving packet re-pointing a
  /// settled call, and there is exactly one place that has earned the right to
  /// override it.
  ///
  /// Run only on the receive thread, which is the only writer of `peer` --
  /// `adopt` and `pickBestPathLocked` are both reached from it and nowhere else.
  private func adoptFrom(_ from: sockaddr_in) {
    peer = from
    locked = true
    sendViaTurn = turn?.isTurnServer(from) == true
    var ipb = [CChar](repeating: 0, count: 64)
    var f = from
    inet_ntop(AF_INET, &f.sin_addr, &ipb, 64)
    lockedFrom = "\(String(cString: ipb)):\(UInt16(bigEndian: from.sin_port))"
  }

  /// Consecutive media packets that decrypted but came from somewhere other than
  /// the address this end is sending to. See the note at the assignment site.
  private var offPathRun = 0

  var peerDescription: String {
    var b = [CChar](repeating: 0, count: 32)
    var a = peer.sin_addr
    inet_ntop(AF_INET, &a, &b, 32)
    return "\(String(cString: b)):\(UInt16(bigEndian: peer.sin_port))"
  }

  /// Called on the socket thread when the peer asks for a keyframe.
  var onKeyRequest: (() -> Void)?

  /// What the far end is saying, as their own machine heard it. `final` marks
  /// the end of an utterance; everything before it is a running guess that will
  /// be revised, which is what makes it feel live rather than late.
  /// `(text, final, wasAListeningNoise)`. The third flag is the sender's own
  /// classification of the sound the words came from, not a guess made from the
  /// words: "yeah" is a listening noise when it lasted 300 ms under somebody
  /// else's sentence and a full turn when it did not, and only the machine that
  /// heard it knows which. It decides whether these words bloom for a second over
  /// the picture or run in the caption band.
  var onSubtitle: ((String, Bool, Bool) -> Void)?

  /// Capped so one long sentence cannot become a jumbo packet. 512 bytes is far
  /// more than anybody says between two revisions.
  /// Byte 4 is a FLAG BYTE, not a boolean, and it was one from the first version
  /// -- bit 0 committed, bit 1 "this was a listening noise". Reusing the spare
  /// bits of a byte that was already there keeps the frame the same size and the
  /// same shape, which matters because the two ends of a call update
  /// independently and an older build has to keep working: it reads bit 0 the way
  /// it always did and ignores the rest.
  func sendSubtitle(_ text: String, final: Bool, listening: Bool = false) {
    var bytes = Array(text.utf8)
    if bytes.count > 512 { bytes = Array(bytes.suffix(512)) }
    var out = [UInt8](repeating: 0, count: 7 + bytes.count)
    out.withUnsafeMutableBytes { p in
      p.storeBytes(of: SMAGIC.littleEndian, toByteOffset: 0, as: UInt32.self)
      p.storeBytes(of: UInt8((final ? 1 : 0) | (listening ? 2 : 0)), toByteOffset: 4, as: UInt8.self)
      p.storeBytes(of: UInt8(bytes.count & 0xFF), toByteOffset: 5, as: UInt8.self)
      p.storeBytes(of: UInt8(bytes.count >> 8), toByteOffset: 6, as: UInt8.self)
    }
    for (i, b) in bytes.enumerated() { out[7 + i] = b }
    out.withUnsafeBufferPointer { _ = rawSend($0.baseAddress!, $0.count, .ctl) }
  }

  /// The far end hung up. Fired from the receive thread, once per call: the
  /// handler ends the process, and a second delivery of the same goodbye must not
  /// be able to run it again while the first is still posting its final beat.
  var onPeerBye: (() -> Void)?
  private var byeSeen = false

  /// Say goodbye and mean it. Four copies rather than one because this is UDP and
  /// there is no second chance -- the process is about to stop existing, so a lost
  /// datagram would leave the far end holding the call open for the whole room
  /// lease. Four is 32 bytes of insurance against a minute and a half of somebody
  /// waiting for a person who already left.
  ///
  /// Sent through `rawSend`, so it is encrypted like everything else and so the
  /// impairment gate can drop it in a rig -- which is the arm that proves the
  /// lease fallback actually works rather than being decoration.
  func sendGoodbye() {
    var out = [UInt8](repeating: 0, count: 8)
    out.withUnsafeMutableBytes { p in
      p.storeBytes(of: BMAGIC.littleEndian, toByteOffset: 0, as: UInt32.self)
      p.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 4, as: UInt32.self)
    }
    for _ in 0..<4 {
      out.withUnsafeBufferPointer { rawSend($0.baseAddress!, $0.count, .ctl) }
    }
  }

  func requestKeyframe(scratch: UnsafeMutablePointer<UInt8>) {
    scratch.withMemoryRebound(to: UInt32.self, capacity: 2) {
      $0[0] = KMAGIC.littleEndian; $0[1] = 0
    }
    rawSend(scratch, 8, .ctl)
  }

  /// One offset probe. Cheap enough (32 bytes) to send often, and it rides the
  /// media socket so it measures the path the media actually takes.
  func sendTimeProbe() {
    var out = [UInt8](repeating: 0, count: TPKTZ)
    out.withUnsafeMutableBytes { p in
      p.storeBytes(of: TMAGIC.littleEndian, toByteOffset: 0, as: UInt32.self)
      p.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 4, as: UInt32.self)
      p.storeBytes(of: Clock.now().littleEndian, toByteOffset: 8, as: UInt64.self)
      appendRxReport(p)
    }
    out.withUnsafeBufferPointer { _ = rawSend($0.baseAddress!, $0.count, .probe) }
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
    reportVideo = video
    /// The value of `ring.restarts` this loop has already acted on. A counter and
    /// not a flag, so a second restart later in the same call is a second event
    /// rather than one that has already been consumed.
    var seenRingRestarts = ring.restarts
    if !Wire.noRealtime { fputs(goRealtime() + "\n", stderr) }
    // One buffer big enough for either kind. Audio and video share the socket, so
    // the loop dispatches on the magic rather than owning two sockets: two ports
    // means two NAT bindings, and the second one is the one that fails.
    let cap = max(HDR + FPP * 4, VHDR + VPAYLOAD) + 128
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
    // One receive thread, so one decrypt scratch is safe -- unlike the send side,
    // which is reached from three.
    let dbuf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
    // One float scratch for unpacking 16-bit payloads. Safe as a single buffer for
    // the same reason dbuf is: there is exactly one receive thread.
    let fbuf = UnsafeMutablePointer<Float>.allocate(capacity: FPP + 8)
    // Compressed payload lands here as int16 first, then converts to float. Both
    // buffers belong to this thread alone, which is why neither needs a lock.
    let ibuf = UnsafeMutablePointer<Int16>.allocate(capacity: Lpc.MAXN)
    /// Decode a coded block into `fbuf`. Takes the pointer to the LENGTH BYTE, not
    /// to the payload, so it mirrors the sender's framing exactly -- the first
    /// version took the payload pointer and the two call sites passed the length
    /// byte, so the decoder read it as the mode byte and refused every packet on
    /// the call. `recv 0/s` for three minutes while bytes kept arriving.
    ///
    /// False means malformed, which a corrupt or hostile packet is allowed to be:
    /// counted and dropped, never trusted.
    func expand(_ at: UnsafePointer<UInt8>, _ frames: Int) -> Bool {
      let len = Int(at[0])
      guard frames <= Lpc.MAXN, len > 0, Lpc.decode(at + 1, len, frames, into: ibuf) else {
        lpBadDecode += 1
        return false
      }
      for i in 0..<frames { fbuf[i] = Float(ibuf[i]) / 32767.0 }
      return true
    }
    while true {
      var src = sockaddr_in()
      var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
      var n = withUnsafeMutablePointer(to: &src) { sp in
        sp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          recvfrom(fd, buf, cap, 0, $0, &srcLen)
        }
      }
      if n < 8 { if n < 0 { usleep(200) }; continue }
      recvBytes += Int(n) + 28
      // ChannelData from our TURN server is the media, wrapped. Slide the
      // payload to the front so the rest of this loop does not know about TURN.
      if let t = turn, let inner = t.unwrap(buf, Int(n), from: src) {
        if inner.1 < 8 { continue }
        memmove(buf, inner.0, inner.1)
        n = inner.1
      }
      var magic = buf.withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) }

      // THE HANDSHAKE, and it is the one thing never encrypted -- it is what
      // creates the key. Answered from this thread so the exchange completes in
      // one round trip.
      //
      // An UNSIGNED (v1) handshake is refused and counted: the far end is a build
      // from before the handshake was signed, and connecting to it would mean
      // accepting a key nobody vouched for. The beat says `hs_old`, the summary
      // says "old build", and the call keys the moment they update.
      if magic == HMAGIC {
        crypto?.noteOldHandshake()
        continue
      }
      if magic == Crypto.HS_MAGIC, Int(n) >= Crypto.HS_LEN {
        guard let c = crypto else { continue }
        // REPLY ONLY WHEN THE KEY WAS NEW. The previous version replied to every
        // handshake it received, and so did the peer, so a reply provoked a
        // reply: on loopback that ran at about ten thousand round trips a second.
        // Liveness does not need the echo. Both ends beat a handshake on a timer
        // -- fast while unkeyed, every 5 s after -- so a peer that restarts with
        // a fresh key is adopted on its next beat, that adoption IS a change, and
        // the single reply that follows completes the exchange in one round trip.
        switch c.adoptHandshake(buf, Int(n)) {
        case .adopted:
          // The address is adopted only from a VERIFIED handshake. Before this,
          // the first 36 bytes with the right magic pointed the media anywhere.
          if !locked { adopt(src) }
          let c2 = Crypto.caps(of: buf, Int(n))
          if c2 != peerCaps {
            peerCaps = c2
            fputs("peer can receive: \(c2 & CAP_PCM16 != 0 ? "16-bit pcm" : "32-bit float only")\(c2 & CAP_PCM_LP != 0 ? ", lossless-compressed" : "")\n", stderr)
          }
          fputs("crypto: \(c.summary)\n", stderr)
          sendHandshake()
          handshakeReplies += 1
          if let k = c.peerIdentityB64 { onPeerIdentity?(k) }
        case .unchanged:
          if !locked { adopt(src) }
        case .refused(let why):
          fputs("crypto: handshake refused (\(why)) from \(Wire.describe(src))\n", stderr)
        }
        continue
      }

      // Decrypt, then treat the PLAINTEXT as the packet. A datagram that fails to
      // decrypt is not dispatched at all: accepting it as plaintext would let
      // anyone who can reach the port inject audio into a call that believes
      // itself encrypted. And before a key exists NOTHING is dispatched: there is
      // no plaintext window any more.
      var plain: UnsafeMutablePointer<UInt8> = buf
      var plainN = Int(n)
      guard let c = crypto, c.established else {
        crypto?.notePlaintextRx()
        continue
      }
      if magic == MAGIC || magic == VMAGIC || magic == TMAGIC || magic == KMAGIC || magic == SMAGIC || magic == BMAGIC {
        // A recognised magic in the clear while a key exists: an old build on
        // the far end, or someone probing. Counted, never used.
        c.notePlaintextRx()
        continue
      }
      guard let m = c.open(buf, Int(n), into: dbuf) else { continue }
      plain = dbuf
      plainN = m
      magic = dbuf.withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) }

      // ── A GOODBYE IS NOT EVIDENCE OF LIFE ─────────────────────────────────
      //
      // Handled ABOVE the liveness block on purpose. Every other recognised magic
      // refreshes `lastRecvHost`, `lastFromPeer` and `Update.lastMediaHost` --
      // "traffic on the path" -- and a goodbye is the one packet that means the
      // opposite. Stamping it would leave the call looking live for three seconds
      // after the person hung up, and would tell the updater a call was in
      // progress when it had just ended.
      //
      // Only from an established key. Before that, anyone who can reach this port
      // could end a call by guessing eight bytes; after it, sending this required
      // holding the session key.
      if magic == BMAGIC, crypto?.established == true {
        if !byeSeen {
          byeSeen = true
          fputs("bye: the other end hung up\n", stderr)
          onPeerBye?()
        }
        continue
      }
      // A recognised magic from a reachable address is enough to point media
      // there. Once encryption is up this is genuine authentication: the packet
      // decrypted, so it came from someone holding the key.
      if magic == MAGIC || magic == VMAGIC || magic == TMAGIC || magic == KMAGIC || magic == SMAGIC {
        lastRecvHost = Clock.now()
        if locked, src.sin_addr.s_addr == peer.sin_addr.s_addr, src.sin_port == peer.sin_port {
          // ── THE TWO STAMPS THAT BOUND A SILENCE ────────────────────────────
          //
          // Recorded HERE, on the receive thread, at the exact packet that ends
          // the gap. The poll loop above cannot do this: `lastFromPeer` is the
          // MOST RECENT packet, so by the time a half-second tick reads it the
          // stream has already moved it on, and the reported gap grows by
          // however long the loop took to look. A gap is bounded by two
          // packets, so it is measured by two packets and by nothing else.
          //
          // One comparison per packet at 1500 packets a second, on a thread that
          // already stamps the clock on the line above -- nothing here allocates
          // and nothing locks.
          if lastFromPeer != 0, Clock.msSigned(lastRecvHost, lastFromPeer) > 1000 {
            peerGoneAt = lastFromPeer
            peerBackAt = lastRecvHost
          }
          lastFromPeer = lastRecvHost
          offPathRun = 0
        } else if locked {
          // ── A LOCK THAT CAN ONLY BE BROKEN BY SILENCE IS A ONE-WAY DOOR ──────
          //
          // `lastFromPeer` counts only packets arriving FROM the address this end
          // chose to send to, and that is right -- it is what stops a stranger's
          // probes standing in for a peer that has gone. It also assumes the two
          // ends agree about which address the call is on, and they need not.
          //
          // Measured, on the rejoin rig, twice in three runs: both Macs are behind
          // one NAT, so each end has a public candidate and a LAN candidate for
          // the other. After a rejoin the path race runs again from scratch and the
          // two ends settle DIFFERENTLY -- this end on the LAN address, the far end
          // still on the public one. Media flows perfectly in both directions
          // (recv 1500/s the whole time), and every packet arrives translated by
          // the hairpin, so it comes from the public address while this end is
          // locked to the LAN one. `lastFromPeer` freezes on a healthy call, the
          // 3 s silence detector fires, and the call the person just got back
          // drops again for four seconds. Twice, in a row, in one run.
          //
          // `held-is-a-one-way-door`, exactly: a recovery gate whose evidence the
          // other side controls. The remedy is this file's own stated principle,
          // one screen up -- "a packet that arrives carries the only address that
          // is definitely reachable, the one it came from". So a sustained stream
          // from somewhere else is not noise to be ignored until the timeout; it is
          // better evidence than the address we picked, and this end moves to it.
          //
          // A RUN, not one packet: a single stray datagram must never be able to
          // re-point a call. 256 audio packets is 170 ms at FPP=32, far above any
          // reordering and far below the 3 s detector it is rescuing.
          //
          // Only under an established key. Before that anyone who can reach this
          // port could steer the call by sending 256 packets; after it, doing so
          // requires holding the session key, which is the same bar `adopt` uses.
          if crypto?.established == true {
            offPathRun += 1
            if offPathRun >= 256 {
              offPathRun = 0
              relocks += 1
              // READ BEFORE THE REASSIGNMENT. `peerDescription` is derived from
              // `peer`, and `adoptFrom` is about to overwrite it -- so a line
              // composed afterwards prints the SAME address twice and reads as a
              // move to where we already were, which is exactly what the first
              // run of this printed and exactly the wrong conclusion.
              let was = peerDescription
              adoptFrom(src)
              lastFromPeer = lastRecvHost
              fputs("path: their media has been arriving from \(pathKey(src)) and we were"
                  + " sending to \(was) -- moving to theirs\n", stderr)
            }
          }
        }
        // The updater asks "is a call live?" before it restarts the app, and this
        // is the only evidence that answers it. Stamped here rather than exposed
        // as a callback: a hook assigned nowhere would answer "never in a call"
        // and fail invisibly, in the direction that cuts someone off mid-sentence.
        //
        // ── AND IT IS THE SAME LINE AS `lastRecvHost`, DELIBERATELY ───────────
        //
        // This was narrowed to `magic == MAGIC || magic == VMAGIC` on the theory
        // that a clock probe or a keyframe request proves a process is alive
        // without proving a conversation exists, so a call sitting in silence
        // behind a refused wire format would be held un-updateable by its own
        // probes. BOTH HALVES OF THAT WERE WRONG, so the narrowing is reverted and
        // the reasons are written down rather than left to be re-derived:
        //
        //  1. It fixed nothing. On a refused wire format the packet IS `MAGIC` and
        //     it DOES decrypt -- the refusal is `frames != FPP`, read out of the
        //     decrypted plaintext some sixty lines below. So audio was refreshing
        //     this stamp 375 times a second throughout the silence, exactly as
        //     before. The silent-call case is handled where it belongs, by the
        //     wire-mismatch bypass in Update.startPolling.
        //  2. It broke an invariant that `Update.callIsLive()` states in its own
        //     comment: it reads the same evidence as the app's own peer-gone
        //     detector, which watches `wire.lastRecvHost` (main.swift). Two
        //     variables meant to agree cannot be assigned on different conditions.
        //     The worst case is a SUPPORTED configuration: a peer with the mic
        //     denied and the camera off sends neither MAGIC nor VMAGIC, so this
        //     stamp would stay 0 for the whole call, `callIsLive()` would be false
        //     from beginning to end, and the first poll tick would restart the app
        //     out from under a working one-way call.
        Update.lastMediaHost = lastRecvHost
        if !locked { adopt(src) }
      }
      if magic == VMAGIC {
        guard let v = video, plainN >= VHDR else { continue }
        let seq = Int32(bitPattern: (plain + 4).withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) })
        let cap8 = (plain + 8).withMemoryRebound(to: UInt64.self, capacity: 1) { UInt64(littleEndian: $0[0]) }
        let frag = Int((plain + 16).withMemoryRebound(to: UInt16.self, capacity: 1) { UInt16(littleEndian: $0[0]) })
        let nfrag = Int((plain + 18).withMemoryRebound(to: UInt16.self, capacity: 1) { UInt16(littleEndian: $0[0]) })
        let vflags = Int((plain + 20).withMemoryRebound(to: UInt16.self, capacity: 1) { UInt16(littleEndian: $0[0]) })
        let isPar = vflags & 1 == 1
        let parLast = Int((plain + 22).withMemoryRebound(to: UInt16.self, capacity: 1) { UInt16(littleEndian: $0[0]) })
        // A parity fragment rides at frag == nfrag, one past the data. Everything
        // else must still be a real index, so the bound only relaxes for parity.
        if nfrag < 1 || nfrag > 4096 || frag > nfrag || (!isPar && frag == nfrag) { continue }
        v.take(seq: seq, frag: frag, nfrag: nfrag, capHost: cap8, bytes: plain + VHDR, n: plainN - VHDR,
               parity: isPar, parLastLen: parLast)
        continue
      }
      if magic == KMAGIC { onKeyRequest?(); continue }
      if magic == SMAGIC {
        guard plainN >= 7 else { continue }
        // `& 1`, not `== 1`: byte 4 carries flags now, and an equality test would
        // have quietly stopped seeing "committed" the moment anything else was
        // set alongside it.
        let final = plain[4] & 1 != 0
        let listening = plain[4] & 2 != 0
        let n = Int(plain[5]) | Int(plain[6]) << 8
        guard n >= 0, 7 + n <= plainN else { continue }
        let txt = n == 0 ? "" : (String(bytes: UnsafeBufferPointer(start: plain + 7, count: n),
                                        encoding: .utf8) ?? "")
        onSubtitle?(txt, final, listening)
        continue
      }
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
        if plainN >= TPKTZ {
          let vm = (plain + TPKTY).withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) }
          let vf = (plain + TPKTY + 4).withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) }
          peerVideoMissing = Int(vm)
          peerVideoFrags = Int(vf)
          peerReportsVideoLoss = true
        }
        if plainN >= TPKTY {
          let pl = (plain + TPKTX).withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) }
          peerPlayed = Int(pl)
          peerMuted = plain[TPKTX + 4] == 1
          peerQLevel = Int(plain[TPKTX + 5])
          peerStatus = Int(plain[TPKTX + 6])
          // ONE WORD FROM THEM, and it is the difference between "their status
          // byte says they are not ringing" and "we have never heard their
          // status byte". Those are the same zero, and the caller has to tell
          // them apart before it decides a call has been answered.
          peerStatusSeen = true
          Audio.peerVocalNow = peerVocal
          // ── AND THE TURN LAYER HEARS IT HERE ──────────────────────────────
          //
          // On the receive thread, the instant the byte lands, rather than
          // waiting for the next capture block to poll it. The cue's whole
          // promise is that it arrives one hop after somebody opens their
          // mouth, and `transitMs` is what stops that hop being counted as
          // zero -- an age measured from arrival says news that crossed the
          // planet is brand new, which was a hidden distance limit.
          Audio.peerVoiceNow = peerVoice
          // Latched the first time a peer sets it, so a CLEAR bit can be told
          // from a build that never sets one (`blind-instruments-report-negatives`).
          if peerStatus & Wire.ST_VOICING != 0 { peerVocalSeen = true }
          if peerStatus & Wire.ST_SEEN_TALKING != 0 { peerSeenTalkingSeen = true }
          Audio.sharedFloor.noteFar(peerVoice, transitMs: Audio.owdMsNow,
                                    voicing: peerVoicing)
          // Their camera's verdict, three-state. Level-triggered like the
          // voicing bit, plus its own edge flush at the sender.
          // Consumed only when this end is acting on vision at all. The bit is
          // still RECORDED either way, so a live call can say whether it crossed.
          Audio.sharedFloor.farSeenTalking = Mouth.influence ? peerSeenTalking : nil
          // The prior belongs to THIS floor, computed on THEIR transcript.
          // Level-triggered: every TPKTY packet carries the standing value, so a
          // dropped crossing costs a second of staleness rather than a prior
          // that is wrong for the rest of the call -- same repair as the vocal
          // byte. Zero is what 0.92.0 writes, and zero changes nothing.
          Audio.peerTurnEndProb = Wire.endProb(from: plain[TPKTX + 7])
          Audio.sharedFloor.noteFarEndProb(Audio.peerTurnEndProb)
          // ── THE FAST HALF OF THE TURN LAYER ─────────────────────────────────
          //
          // Fired on CHANGE, from the receive thread, rather than polled by the
          // window. The whole claim of the floor cue is that it lands one hop
          // after somebody opens their mouth; a 12 Hz poll in the UI would have
          // put up to 83 ms of the thing back, which is most of an ocean, and
          // there is nothing to poll for anyway -- this byte only ever changes a
          // few times a second.
          let v = peerClaim ? 2 : (peerBackchannel ? 1 : 0)
          if v != lastVocalSent { lastVocalSent = v; onPeerVocal?(v) }
          peerReportsState = true
        }
        if kind == 0 {
          // A request. Reply from THIS thread, immediately -- handing it to
          // another thread would put that thread's scheduling delay inside t3-t2,
          // where it is indistinguishable from network asymmetry and biases the
          // offset by half of it.
          var out = [UInt8](repeating: 0, count: TPKTZ)
          out.withUnsafeMutableBytes { p in
            p.storeBytes(of: TMAGIC.littleEndian, toByteOffset: 0, as: UInt32.self)
            p.storeBytes(of: UInt32(1).littleEndian, toByteOffset: 4, as: UInt32.self)
            p.storeBytes(of: t1.littleEndian, toByteOffset: 8, as: UInt64.self)
            p.storeBytes(of: t4.littleEndian, toByteOffset: 16, as: UInt64.self)   // t2
            p.storeBytes(of: Clock.now().littleEndian, toByteOffset: 24, as: UInt64.self)  // t3
            appendRxReport(p)
          }
          out.withUnsafeBufferPointer { _ = rawSend($0.baseAddress!, $0.count, .probe) }
        } else {
          let t2 = (plain + 16).withMemoryRebound(to: UInt64.self, capacity: 1) { UInt64(littleEndian: $0[0]) }
          let t3 = (plain + 24).withMemoryRebound(to: UInt64.self, capacity: 1) { UInt64(littleEndian: $0[0]) }
          tsync?.note(t1: t1, t2: t2, t3: t3, t4: t4)
          // One-way is not observable. Round trip of THIS packet on THIS address
          // is, and that is how we pick the path.
          let rtt = Clock.msSigned(t4, t1) - Clock.msSigned(t3, t2)
          if rtt > 0, rtt < 5000 {
            notePath(src, rttMs: rtt)
            // Half a round trip is the age of every cue the moment it lands.
            // Smoothed, because a single probe's RTT carries one queue's worth
            // of noise and the turn layer wants the PATH, not this packet.
            Audio.owdMsNow = Audio.owdMsNow == 0 ? rtt / 2
                                                 : Audio.owdMsNow * 0.9 + rtt / 2 * 0.1
          }
        }
        continue
      }
      if magic != MAGIC || plainN < HDR { continue }
      let seq = Int32(bitPattern: (plain + 4).withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) })
      let cap = (plain + 8).withMemoryRebound(to: UInt64.self, capacity: 1) { UInt64(littleEndian: $0[0]) }
      let tag = (plain + 16).withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) }
      let frames = Int(tag & 0xffff)
      // MASK THE BIT, do not compare the whole field. This read `(tag >> 16) == 1`,
      // which is the same thing only while pcm16 is the only flag up there -- the
      // next flag added silently turns every 16-bit packet into a 32-bit one and
      // the audio becomes noise. One bit per question.
      let bps = (tag >> 16) & 1 == 1 ? 2 : 4
      let lp = (tag >> 17) & 1 == 1
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
      // A compressed block's length is in the byte before it; an uncompressed one
      // is frames * bps. Either way the payload must be entirely inside the packet.
      let plen = lp ? (plainN > HDR ? 1 + Int(plain[HDR]) : 0) : frames * bps
      if frames <= 0 || plen <= 0 || plainN < HDR + plen { continue }
      if frames != FPP {
        fmtMismatch += 1
        // The far end is on another build and this call is going nowhere until one
        // of us moves. Ask the updater to look now instead of at the end of its
        // minute -- a wire-format change otherwise costs up to 60 s of silence in
        // the middle of a real conversation.
        // `wireMismatch` FIRST: it is the reason, `urgent` is only the trigger, and
        // the poll thread reads the reason the moment it sees the trigger. Set the
        // other way round and a tick landing between the two stores would see an
        // urgent check with no reason attached, and hold the fix behind the silent
        // call it exists to end.
        if fmtMismatch == 1 { Update.wireMismatch = true; Update.urgent = true }
        if fmtMismatch == 1 || fmtMismatch % 4000 == 0 {
          fputs("audio: peer sends \(frames)-sample packets, this build expects \(FPP)"
              + " -- the two ends are on different versions, one side needs the update"
              + " (\(fmtMismatch) packets refused)\n", stderr)
        }
        continue
      }
      if lp {
        if expand(plain + HDR, frames) { ring.write(seq: seq, cap: cap, src: fbuf, n: frames) }
      } else if bps == 2 {
        unpack16(plain + HDR, frames, into: fbuf)
        ring.write(seq: seq, cap: cap, src: fbuf, n: frames)
      } else {
        (plain + HDR).withMemoryRebound(to: Float.self, capacity: frames) { ring.write(seq: seq, cap: cap, src: $0, n: frames) }
      }
      // The audio ring works out that the sender restarted forty times faster than
      // the video assembler can, because audio arrives forty times more often. Tell
      // it, rather than making it wait out its own thirty stale frames -- that is a
      // second of frozen face after the voice is already back. See
      // `VideoAssembler.peerRestarted`.
      if ring.restarts != seenRingRestarts {
        seenRingRestarts = ring.restarts
        video?.peerRestarted()
      }
      // A trailing block means this packet is also carrying an earlier one. Fill
      // the hole only if it IS a hole -- ring.write already refuses a duplicate,
      // and refuses anything the cursor has passed, so nothing here can overwrite
      // audio about to play.
      let redOff = HDR + plen
      let rLen = lp ? (plainN > redOff + 8 ? 1 + Int(plain[redOff + 8]) : 0) : frames * bps
      if rLen > 0, plainN >= redOff + 8 + rLen, seq > 0 {
        let rCap = (plain + redOff).withMemoryRebound(to: UInt64.self, capacity: 1) { UInt64(littleEndian: $0[0]) }
        let rSeq = seq - 1
        if !ring.present(rSeq) {
          if lp {
            if expand(plain + redOff + 8, frames) { ring.write(seq: rSeq, cap: rCap, src: fbuf, n: frames) }
          } else if bps == 2 {
            unpack16(plain + redOff + 8, frames, into: fbuf)
            ring.write(seq: rSeq, cap: rCap, src: fbuf, n: frames)
          } else {
            (plain + redOff + 8).withMemoryRebound(to: Float.self, capacity: frames) {
              ring.write(seq: rSeq, cap: rCap, src: $0, n: frames)
            }
          }
          if ring.present(rSeq) { ring.recovered += 1 }
        }
      }
    }
  }
}
