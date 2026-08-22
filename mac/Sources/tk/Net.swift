import Darwin

let SR = 48_000.0
let FPP = 64            // samples per packet -> 2.667 ms. One packet per device
                         // buffer in the common case, so the reader consumes
                         // exactly what the callback asks for.
let RING = 1024           // packets == 1.37 s. Generous: the ring is not the
                         // latency, the read cursor's DISTANCE behind the write
                         // head is, and a big ring only buys recovery headroom.
let HDR = 20             // magic(4) seq(4) capHost(8) frames(4)
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
      if Int64(seq) < curSeq - Int64(RING) { tooOld += 1; return }
    }
    if pos >= 0 {
      // Deadline of this packet's first sample, minus where the cursor is now.
      let ms = (Double(Int64(seq) * Int64(FPP)) - pos) / SR * 1000.0
      slack.add(ms)
      slackWin.add(ms)
      if ms < slackMin { slackMin = ms }
      if ms < slackWinMin { slackWinMin = ms }
    }
    memcpy(samples + slot * FPP, src, min(n, FPP) * 4)
    capHost[slot] = cap
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

  func send(seq: Int32, cap: UInt64, src: UnsafePointer<Float>, n: Int, scratch: UnsafeMutablePointer<UInt8>) {
    scratch.withMemoryRebound(to: UInt32.self, capacity: 1) { $0[0] = MAGIC.littleEndian }
    (scratch + 4).withMemoryRebound(to: UInt32.self, capacity: 1) { $0[0] = UInt32(bitPattern: seq).littleEndian }
    (scratch + 8).withMemoryRebound(to: UInt64.self, capacity: 1) { $0[0] = cap.littleEndian }
    (scratch + 16).withMemoryRebound(to: UInt32.self, capacity: 1) { $0[0] = UInt32(n).littleEndian }
    memcpy(scratch + HDR, src, n * 4)
    let r = withUnsafePointer(to: &peer) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        sendto(fd, scratch, HDR + n * 4, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if r < 0 { sendErrs += 1 } else { sent += 1 }
  }

  /// One datagram, already framed by the caller. Shared by the audio and video
  /// paths so there is exactly one socket, one port and one NAT binding per peer
  /// -- two ports would mean two hole-punches and two things to go wrong.
  func rawSend(_ p: UnsafePointer<UInt8>, _ n: Int) {
    let r = withUnsafePointer(to: &peer) { pp in
      pp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        sendto(fd, p, n, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if r < 0 { sendErrs += 1 } else { sent += 1 }
  }

  // Blocking receive loop, run on its own thread.
  /// Point the media at a different address, once rendezvous has found the peer.
  func setPeer(ip: String, port: UInt16) {
    peer.sin_family = sa_family_t(AF_INET)
    peer.sin_port = port.bigEndian
    peer.sin_addr.s_addr = inet_addr(ip)
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
    var out = [UInt8](repeating: 0, count: TPKT)
    out.withUnsafeMutableBytes { p in
      p.storeBytes(of: TMAGIC.littleEndian, toByteOffset: 0, as: UInt32.self)
      p.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 4, as: UInt32.self)
      p.storeBytes(of: Clock.now().littleEndian, toByteOffset: 8, as: UInt64.self)
    }
    out.withUnsafeBufferPointer { _ = rawSend($0.baseAddress!, $0.count) }
  }

  func recvLoop(into ring: RecvRing, video: VideoAssembler? = nil) {
    // One buffer big enough for either kind. Audio and video share the socket, so
    // the loop dispatches on the magic rather than owning two sockets: two ports
    // means two NAT bindings, and the second one is the one that fails.
    let cap = max(HDR + FPP * 4, VHDR + VPAYLOAD) + 128
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
    while true {
      let n = recvfrom(fd, buf, cap, 0, nil, nil)
      if n < 8 { if n < 0 { usleep(200) }; continue }
      let magic = buf.withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) }
      if magic == VMAGIC {
        guard let v = video, n >= VHDR else { continue }
        let seq = Int32(bitPattern: (buf + 4).withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) })
        let cap8 = (buf + 8).withMemoryRebound(to: UInt64.self, capacity: 1) { UInt64(littleEndian: $0[0]) }
        let frag = Int((buf + 16).withMemoryRebound(to: UInt16.self, capacity: 1) { UInt16(littleEndian: $0[0]) })
        let nfrag = Int((buf + 18).withMemoryRebound(to: UInt16.self, capacity: 1) { UInt16(littleEndian: $0[0]) })
        if nfrag < 1 || nfrag > 4096 || frag >= nfrag { continue }
        v.take(seq: seq, frag: frag, nfrag: nfrag, capHost: cap8, bytes: buf + VHDR, n: Int(n) - VHDR)
        continue
      }
      if magic == KMAGIC { onKeyRequest?(); continue }
      if magic == TMAGIC {
        guard Int(n) >= TPKT else { continue }
        let t4 = Clock.now()   // stamp FIRST: everything after this is our own cost
        let kind = (buf + 4).withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) }
        let t1 = (buf + 8).withMemoryRebound(to: UInt64.self, capacity: 1) { UInt64(littleEndian: $0[0]) }
        if kind == 0 {
          // A request. Reply from THIS thread, immediately -- handing it to
          // another thread would put that thread's scheduling delay inside t3-t2,
          // where it is indistinguishable from network asymmetry and biases the
          // offset by half of it.
          var out = [UInt8](repeating: 0, count: TPKT)
          out.withUnsafeMutableBytes { p in
            p.storeBytes(of: TMAGIC.littleEndian, toByteOffset: 0, as: UInt32.self)
            p.storeBytes(of: UInt32(1).littleEndian, toByteOffset: 4, as: UInt32.self)
            p.storeBytes(of: t1.littleEndian, toByteOffset: 8, as: UInt64.self)
            p.storeBytes(of: t4.littleEndian, toByteOffset: 16, as: UInt64.self)   // t2
            p.storeBytes(of: Clock.now().littleEndian, toByteOffset: 24, as: UInt64.self)  // t3
          }
          out.withUnsafeBufferPointer { _ = rawSend($0.baseAddress!, $0.count) }
        } else {
          let t2 = (buf + 16).withMemoryRebound(to: UInt64.self, capacity: 1) { UInt64(littleEndian: $0[0]) }
          let t3 = (buf + 24).withMemoryRebound(to: UInt64.self, capacity: 1) { UInt64(littleEndian: $0[0]) }
          tsync?.note(t1: t1, t2: t2, t3: t3, t4: t4)
        }
        continue
      }
      if magic != MAGIC || n < HDR { continue }
      let seq = Int32(bitPattern: (buf + 4).withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) })
      let cap = (buf + 8).withMemoryRebound(to: UInt64.self, capacity: 1) { UInt64(littleEndian: $0[0]) }
      let frames = Int((buf + 16).withMemoryRebound(to: UInt32.self, capacity: 1) { UInt32(littleEndian: $0[0]) })
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
      if frames <= 0 || Int(n) < HDR + frames * 4 { continue }
      if frames != FPP {
        fmtMismatch += 1
        if fmtMismatch == 1 || fmtMismatch % 4000 == 0 {
          fputs("audio: peer sends \(frames)-sample packets, this build expects \(FPP)"
              + " -- the two ends are on different versions, one side needs the update"
              + " (\(fmtMismatch) packets refused)\n", stderr)
        }
        continue
      }
      (buf + HDR).withMemoryRebound(to: Float.self, capacity: frames) { ring.write(seq: seq, cap: cap, src: $0, n: frames) }
    }
  }
}
