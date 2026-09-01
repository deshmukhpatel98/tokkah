import Foundation

// A TEST INSTRUMENT, and it announces itself in every report line it touches.
//
// Every latency number in this app so far was measured across loopback: zero
// loss, zero jitter, no radio. The call it exists for is wifi in one house to
// wifi in another, and this project has a standing rule that a measurement taken
// through a clean pipe does not describe a real path. pfctl and dnctl want a
// password this process does not have, so the impairment goes here instead --
// on the send side, where both directions get it because both ends run the same
// binary with the same flags.
//
// Loss is modelled two ways because wifi does not lose packets uniformly. It
// loses a burst while the radio retries, then nothing for a second. A 1% uniform
// loss and a 1% burst loss sound completely different, and only one of them is
// what a real call meets.
//
// This is NOT a substitute for the real call. It is the thing that tells me what
// to build before the real call, and which numbers to distrust.
final class Impair {
  let dropPct: Double
  let burstMs: Double
  let jitterMs: Double
  // ── Propagation, which this app has never once been tested with ────────────
  //
  // Every latency number in the native app to date is loopback: base delay zero.
  // The call it exists for is Delhi to the Netherlands, where the measured
  // one-way propagation is about 65 ms and no amount of engineering removes it.
  // This project has a recorded bug class -- four instances -- of absolute
  // thresholds that silently contain propagation, so a hardcoded "300 ms" or
  // "30 packets" becomes a hidden distance limit that only fails far from home.
  // A base delay is the only way to find the fifth instance before a real call
  // does.
  let delayMs: Double
  // And real jitter is not uniform. A real path is mostly steady with occasional
  // spikes -- a wifi retry, a queue that fills, a route that flaps -- so uniform
  // 0..N over-exercises the "thin margin" path and never exercises the "one big
  // spike" path at all. Shape matters more than magnitude to a controller that
  // reacts to percentiles.
  //
  // A SPIKE IS AN EVENT, NOT A PER-PACKET DRAW. The first version of this drew a
  // spike independently per packet at 0.5% -- which, at 1500 packets a second
  // through a FIFO queue, is seven and a half stalls a second, a path far more
  // hostile than anything real. Worse, it was hostile in a way the parameter name
  // hid: "0.5% spikes" reads as rare. A real queue event holds EVERY packet that
  // arrives during it and releases them together, so the honest parameters are
  // events per second and a duration -- and the release burst that follows is part
  // of the phenomenon, not an artefact.
  let spikeMs: Double
  let spikeHz: Double
  // ── A LINK WITH A CEILING, WHICH IS WHAT CONGESTION ACTUALLY IS ────────────
  //
  // Every impairment above is a COIN FLIP: the loss rate does not depend on how
  // much is being sent. That models a radio with interference and it cannot model
  // a queue that is full -- and a queue that is full is the only thing "send less
  // video" can fix.
  //
  // Which mattered, because the video-pause controller in `VQuality` acts on loss
  // by stopping the picture, and until this existed there was no way to test it on
  // a path where that action WORKS. Every arm ran against rate-independent loss,
  // where pausing can only ever be useless -- so the arm that must rank the other
  // way did not exist, and the shipped behaviour was a controller nobody had ever
  // watched succeed.
  //
  // A leaky bucket: tokens accrue at `capacityMbps`, every packet spends its own
  // size, and a packet that cannot pay is dropped. 50 ms of burst tolerance,
  // because a bucket with none drops on every jitter spike and models nothing.
  //
  // The state is touched from the audio callback and the encoder thread without a
  // lock, exactly as `seed` and `burstUntil` above already are: this is a test
  // instrument, a torn double costs one wrong packet, and a lock on the audio
  // thread is a dropout.
  let capacityMbps: Double
  private var bucketBytes: Double = 0
  private var bucketAt: UInt64 = 0
  private(set) var overCapacity = 0
  private var stallUntil: UInt64 = 0
  var enabled: Bool {
    dropPct > 0 || jitterMs > 0 || delayMs > 0 || spikeMs > 0 || capacityMbps > 0
  }
  var holdsPackets: Bool { jitterMs > 0 || delayMs > 0 || spikeMs > 0 }
  private(set) var stalls = 0


  private(set) var dropped = 0
  private(set) var delayed = 0
  private var burstUntil: UInt64 = 0
  private var seed: UInt64 = 0x2545_F491_4F6C_DD1D
  // ── A LINK THAT GETS BETTER ────────────────────────────────────────────────
  //
  // Every impairment here is permanent for the life of the process, which can
  // only ever prove the half of a controller that gives things up. The half that
  // hands them back -- the one that turns a bad minute into a bad call when it is
  // wrong -- had no way to be exercised on a live call at all.
  //
  // `--imp-until 20` heals the path at t=20 s. Not a shorter test of the same
  // thing: it is the only test of the other thing.
  private let untilS: Double
  private var healed = false
  private var startedAt: UInt64 = 0

  init(dropPct: Double, burstMs: Double, jitterMs: Double,
       delayMs: Double = 0, spikeMs: Double = 0, spikeHz: Double = 0,
       untilS: Double = 0, capacityMbps: Double = 0) {
    self.untilS = untilS
    self.capacityMbps = capacityMbps
    self.dropPct = dropPct
    self.burstMs = burstMs
    self.jitterMs = jitterMs
    self.delayMs = delayMs
    self.spikeMs = spikeMs
    self.spikeHz = spikeHz
  }

  // xorshift rather than a system RNG: this is called on the audio capture
  // callback's thread and must not allocate, lock, or syscall.
  @inline(__always) private func rnd() -> Double {
    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
    return Double(seed >> 11) * (1.0 / 9_007_199_254_740_992.0)
  }

  /// true if this packet should vanish. `bytes` is only read by the capacity
  /// model; the coin-flip models do not care how big a packet is, which is the
  /// whole difference between them.
  func shouldDrop(bytes: Int = 0) -> Bool {
    if capacityMbps > 0, bytes > 0, overBudget(bytes) { return true }
    guard dropPct > 0 else { return false }
    let now = Clock.now()
    if untilS > 0 {
      // Measured from the first packet, not from process start: the socket, the
      // room and the peer all happen first, and anchoring on launch would spend
      // most of a short window on setup.
      if startedAt == 0 { startedAt = now }
      if !healed, Clock.msSigned(now, startedAt) > untilS * 1000 {
        healed = true
        fputs("IMPAIRED: path healed at \(Int(untilS)) s -- loss stops here\n", stderr)
      }
      if healed { return false }
    }
    if burstMs > 0 {
      if now < burstUntil { dropped += 1; return true }
      // Scale the per-packet probability so a burst of B ms fires often enough to
      // average out at dropPct overall. Without this, "1% with 20 ms bursts"
      // silently becomes a far heavier loss than 1%.
      let pktMs = Double(FPP) / SR * 1000.0
      let p = (dropPct / 100.0) * pktMs / max(burstMs, pktMs)
      if rnd() < p {
        burstUntil = now + Clock.ticks(ns: UInt64(burstMs * 1e6))
        dropped += 1
        return true
      }
      return false
    }
    if rnd() < dropPct / 100.0 { dropped += 1; return true }
    return false
  }

  /// The bucket. True when this packet cannot be paid for.
  @inline(__always) private func overBudget(_ bytes: Int) -> Bool {
    let now = Clock.now()
    let burst = capacityMbps * 125_000 * 0.05        // 50 ms of tolerance, in bytes
    if bucketAt == 0 { bucketAt = now; bucketBytes = burst }
    if now > bucketAt {
      bucketBytes = min(burst, bucketBytes + Clock.ms(now - bucketAt) / 1000.0
                                             * capacityMbps * 125_000)
      bucketAt = now
    }
    if bucketBytes < Double(bytes) {
      dropped += 1
      overCapacity += 1
      return true
    }
    bucketBytes -= Double(bytes)
    return false
  }

  /// Extra delay for this packet: propagation, plus uniform jitter, plus the
  /// occasional spike. Propagation is added to EVERY packet and reorders nothing,
  /// which is what makes it a distance rather than an impairment.
  func delayTicks() -> UInt64 {
    guard holdsPackets else { return 0 }
    var ms = delayMs
    if jitterMs > 0 { ms += rnd() * jitterMs }
    if spikeMs > 0, spikeHz > 0 {
      let now = Clock.now()
      // Per-packet probability that yields spikeHz events per second.
      let pktMs = Double(FPP) / SR * 1000.0
      if now >= stallUntil, rnd() < spikeHz * pktMs / 1000.0 {
        stallUntil = now + Clock.ticks(ns: UInt64(spikeMs * 1e6))
        stalls += 1
      }
      // Everything arriving during the event waits for it to end. Packets after it
      // are unaffected, which is what makes this a queue and not a per-packet coin
      // flip.
      if now < stallUntil {
        ms = max(ms, Clock.ms(stallUntil - now) + delayMs)
      }
    }
    guard ms > 0 else { return 0 }
    delayed += 1
    return Clock.ticks(ns: UInt64(ms * 1e6))
  }

  var description: String {
    var s: [String] = []
    if dropPct > 0 { s.append(burstMs > 0 ? "\(dropPct)% loss in \(burstMs) ms bursts" : "\(dropPct)% uniform loss") }
    if delayMs > 0 { s.append("\(delayMs) ms one-way propagation (\(delayMs * 2) ms rtt)") }
    if jitterMs > 0 { s.append("0..\(jitterMs) ms jitter") }
    if spikeMs > 0 { s.append("\(spikeMs) ms queue stalls, \(spikeHz)/s") }
    if capacityMbps > 0 { s.append("\(capacityMbps) Mbps ceiling (a full queue, not a coin flip)") }
    return s.joined(separator: ", ")
  }
}

// A held packet, released later. Small, allocating, thread-based -- all fine,
// because nothing about this runs when the flags are absent.
final class DelayQueue {
  // A FIXED POOL, because push() runs on the audio capture callback.
  //
  // The first version allocated a [UInt8] per packet there. At 750 packets a
  // second, on a real-time thread, that is a malloc in the one place a malloc
  // must never be -- and it would have shown up as render stalls that I would
  // then have attributed to the network jitter I was trying to measure. An
  // instrument whose own cost lands in the number it reports is worse than none.
  private let SLOTS = 4096
  private let MAXP = 2048
  private var buf: UnsafeMutablePointer<UInt8>
  private var due: UnsafeMutablePointer<UInt64>
  private var len: UnsafeMutablePointer<Int32>
  private var head = 0, tail = 0
  private(set) var overflow = 0
  private let lock = NSCondition()
  private let send: (UnsafePointer<UInt8>, Int) -> Void

  init(send: @escaping (UnsafePointer<UInt8>, Int) -> Void) {
    self.send = send
    buf = .allocate(capacity: SLOTS * MAXP)
    due = .allocate(capacity: SLOTS); due.initialize(repeating: 0, count: SLOTS)
    len = .allocate(capacity: SLOTS); len.initialize(repeating: 0, count: SLOTS)
    let t = Thread { [weak self] in self?.run() }
    t.stackSize = 512 << 10
    t.start()
  }

  func push(_ p: UnsafePointer<UInt8>, _ n: Int, due d: UInt64) {
    guard n <= MAXP else { send(p, n); return }
    lock.lock()
    let next = (tail + 1) % SLOTS
    if next == head { overflow += 1; lock.unlock(); send(p, n); return }
    memcpy(buf + tail * MAXP, p, n)
    due[tail] = d
    len[tail] = Int32(n)
    tail = next
    lock.signal()
    lock.unlock()
  }

  private func run() {
    // FIFO, and deliberately so: releasing strictly in push order means the delay
    // is added without reordering. Reordering is a different impairment and it
    // deserves its own flag rather than riding along inside this one, unnamed.
    while true {
      lock.lock()
      while head == tail { lock.wait() }
      let i = head
      let d = due[i]
      let now = Clock.now()
      if d > now {
        let waitS = Double(Clock.ns(d - now)) / 1e9
        lock.unlock()
        Thread.sleep(forTimeInterval: min(waitS, 0.02))
        continue
      }
      let n = Int(len[i])
      head = (head + 1) % SLOTS
      lock.unlock()
      send(buf + i * MAXP, n)
    }
  }
}
