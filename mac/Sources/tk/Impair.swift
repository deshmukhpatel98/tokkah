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
  var enabled: Bool { dropPct > 0 || jitterMs > 0 }

  private(set) var dropped = 0
  private(set) var delayed = 0
  private var burstUntil: UInt64 = 0
  private var seed: UInt64 = 0x2545_F491_4F6C_DD1D

  init(dropPct: Double, burstMs: Double, jitterMs: Double) {
    self.dropPct = dropPct
    self.burstMs = burstMs
    self.jitterMs = jitterMs
  }

  // xorshift rather than a system RNG: this is called on the audio capture
  // callback's thread and must not allocate, lock, or syscall.
  @inline(__always) private func rnd() -> Double {
    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
    return Double(seed >> 11) * (1.0 / 9_007_199_254_740_992.0)
  }

  /// true if this packet should vanish.
  func shouldDrop() -> Bool {
    guard dropPct > 0 else { return false }
    let now = Clock.now()
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

  /// Extra delay for this packet, in host ticks. Uniform 0..jitterMs.
  func delayTicks() -> UInt64 {
    guard jitterMs > 0 else { return 0 }
    delayed += 1
    return Clock.ticks(ns: UInt64(rnd() * jitterMs * 1e6))
  }

  var description: String {
    var s: [String] = []
    if dropPct > 0 { s.append(burstMs > 0 ? "\(dropPct)% loss in \(burstMs) ms bursts" : "\(dropPct)% uniform loss") }
    if jitterMs > 0 { s.append("0..\(jitterMs) ms jitter") }
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
