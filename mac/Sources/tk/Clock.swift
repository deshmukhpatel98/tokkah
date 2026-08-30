import Foundation
import Darwin
import Foundation

// ONE CLOCK.
//
// This file is the whole reason the native app is worth building. In the browser
// the audio graph speaks `AudioContext.currentTime` (zero when the context was
// constructed) and video capture speaks `VideoFrame.timestamp` (the capture
// clock), with NO defined relationship between them -- so the web app has to
// ESTIMATE the offset, ship the estimate to the peer, and hope. Measured on a
// live call this week that estimate was wrong by 124 seconds, and the presenter
// dutifully held 5,870 frames waiting for a moment in the past.
//
// On macOS, audio timestamps, AVFoundation capture timestamps and the display
// link all hang off the SAME host clock. There is nothing to estimate. The bug
// class is not fixed here, it is inexpressible.
enum Clock {
  // mach_absolute_time ticks are not nanoseconds on every machine -- on Apple
  // silicon the timebase is 125/3 -- so the ratio is read once and applied
  // everywhere. Hardcoding 1:1 is a class of bug that only shows up on the
  // machines you did not test.
  private static let tb: mach_timebase_info = {
    var t = mach_timebase_info()
    mach_timebase_info(&t)
    return t
  }()

  @inline(__always) static func now() -> UInt64 { mach_absolute_time() }

  @inline(__always) static func ns(_ ticks: UInt64) -> UInt64 {
    ticks * UInt64(tb.numer) / UInt64(tb.denom)
  }

  // The inverse. Needed because a host timestamp has to be OFFSET by a duration
  // in seconds (samples / 48000), and adding nanoseconds to a tick count is only
  // correct on a machine whose timebase happens to be 1:1 -- which Apple silicon
  // is not.
  @inline(__always) static func ticks(ns: UInt64) -> UInt64 {
    ns == 0 ? 0 : ns * UInt64(tb.denom) / UInt64(tb.numer)
  }

  @inline(__always) static func ms(_ ticks: UInt64) -> Double {
    Double(ns(ticks)) / 1_000_000.0
  }

  // Signed, because a receiver comparing its own clock to a peer's WILL see
  // negative values before the two are related, and a UInt64 subtraction that
  // wraps to 18 quintillion is how a plausibility check learns to refuse real
  // data forever.
  @inline(__always) static func msSigned(_ a: UInt64, _ b: UInt64) -> Double {
    a >= b ? ms(a - b) : -ms(b - a)
  }

  static var timebaseDescription: String { "\(tb.numer)/\(tb.denom)" }

  // ── THE TIME BEFORE OUR FIRST LINE OF CODE ─────────────────────────────────
  //
  // `launchT0` is stamped by the first statement in main.swift, so everything
  // measured against it starts AFTER dyld has mapped every framework this binary
  // links -- AVFoundation, AppKit, CoreAudio, VideoToolbox. Any claim of the form
  // "process start to first frame" that uses launchT0 is therefore too small by
  // however long that took, and a budget that cannot see a stage cannot decide
  // whether the stage is worth attacking.
  //
  // The kernel knows. `p_starttime` is the fork time, which is the earliest
  // moment this process can be said to exist, and the difference is the runtime's
  // own bill. Measured on this Mac: 17-21 ms on a warm bundle, and ~470 ms on the
  // first launch after the bundle's signature changes -- which is worth knowing
  // before anybody times a launch straight after a build.
  //
  /// Milliseconds from `fork` to now, so a stage breakdown can start where the
  /// process does rather than where our code does.
  static func sinceExec() -> Double {
    var kp = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0 else { return -1 }
    let t = kp.kp_proc.p_starttime
    var nowTV = timeval()
    gettimeofday(&nowTV, nil)
    return Double(nowTV.tv_sec - t.tv_sec) * 1000
         + Double(Int(nowTV.tv_usec) - Int(t.tv_usec)) / 1000.0
  }
}

// A fixed-capacity percentile bucket. Allocation-free after construction
// because the audio render thread touches it: a malloc on the real-time thread
// is a glitch with a 50% duty cycle of being invisible in testing.
struct Quantiles {
  private var v: UnsafeMutablePointer<Double>
  private let cap: Int
  private var n = 0
  private var wrapped = false

  init(cap: Int = 4096) {
    self.cap = cap
    v = .allocate(capacity: cap)
    v.initialize(repeating: 0, count: cap)
  }

  @inline(__always) mutating func add(_ x: Double) {
    v[n % cap] = x
    n += 1
    if n >= cap { wrapped = true }
  }

  var count: Int { n }

  // Copy-out, then sort the copy. The audio thread writes this buffer; the
  // reporter and leaveCall used to sort it in place, and hang-up was a
  // SIGSEGV at 0xe8 in Quantiles.p — 20+ crash reports on 0.41.0. A torn
  // snapshot is a slightly wrong percentile. A shared sort is a dead app.
  /// ── SELECT, DO NOT SORT ───────────────────────────────────────────────────
  ///
  /// This sorted the whole buffer to read ONE element out of it, and the report
  /// asks the same object for p50, p95 and p99 -- three copies and three full
  /// sorts of identical, unchanged data. Across the beat and the second-by-second
  /// line that is 47 sorts of up to 4096 doubles per tick, and it was the last of
  /// our own code left in the CPU profile after the correlation work
  /// (`_merge<A>`, top of the self-time list).
  ///
  /// A percentile does not need the array ordered. It needs ONE element in its
  /// final position, which is quickselect: partition, recurse into the side that
  /// contains the index, and stop. O(m) instead of O(m log m), and the element
  /// returned is by construction the same one `sort()` would have put there.
  ///
  /// The copy-out STAYS, and it is not the slow part. The audio thread writes
  /// this buffer while the reporter reads it; sorting in place is what made
  /// hang-up a SIGSEGV at 0xe8 with 20+ crash reports on 0.41.0. A torn snapshot
  /// is a slightly wrong percentile. A shared sort is a dead app.
  ///
  /// Median-of-three pivot, so ordered and reverse-ordered input -- which is
  /// exactly what a latency series often is -- cannot hit the quadratic case.
  /// `--quantile-test` checks it against `sort()` on both, plus all-equal and
  /// single-element buffers.
  func p(_ q: Double) -> Double? {
    if Int(bitPattern: v) < 4096 { return nil }
    let m = min(cap, wrapped ? cap : n)
    guard m > 0 else { return nil }
    var tmp = [Double](repeating: 0, count: m)
    for i in 0..<m { tmp[i] = v[i] }
    let i = min(m - 1, max(0, Int((Double(m) * q).rounded(.down))))
    return Quantiles.select(&tmp, i)
  }

  /// The element that would sit at `k` if `a` were sorted. Rearranges `a`.
  /// Control arm, so the saving is measured on a live call rather than assumed
  /// from a complexity argument. O(m) beating O(m log m) is a fact about the
  /// operation, not about the battery.
  nonisolated(unsafe) static let sortArm =
    ProcessInfo.processInfo.environment["TK_QUANT_SORT"] == "1"

  static func select(_ a: inout [Double], _ k: Int) -> Double {
    if sortArm { a.sort(); return a[k] }
    var lo = 0, hi = a.count - 1
    while lo < hi {
      // Median of three, placed at `lo` as the pivot.
      let mid = lo + (hi - lo) / 2
      if a[mid] < a[lo] { a.swapAt(mid, lo) }
      if a[hi] < a[lo] { a.swapAt(hi, lo) }
      if a[hi] < a[mid] { a.swapAt(hi, mid) }
      a.swapAt(mid, lo)
      let pivot = a[lo]
      var i = lo, j = hi
      // Hoare partition. `i <= j` with the two inner loops bounded by the pivot
      // value rather than by an index is what keeps all-equal input linear
      // instead of quadratic -- both scans still advance on an equal element.
      while i <= j {
        while a[i] < pivot { i += 1 }
        while a[j] > pivot { j -= 1 }
        if i <= j {
          a.swapAt(i, j)
          i += 1; j -= 1
        }
      }
      if k <= j { hi = j } else if k >= i { lo = i } else { return a[k] }
    }
    return a[k]
  }

  mutating func reset() { n = 0; wrapped = false }
}

extension Quantiles {
  /// ── AGAINST THE SORT IT REPLACED ──────────────────────────────────────────
  ///
  /// Every case that breaks a naive quickselect, plus the two that a latency
  /// series actually produces. An agreement test on random data alone would pass
  /// an implementation that goes quadratic on sorted input -- which is the shape
  /// this buffer holds most often.
  static func selfTest() -> Bool {
    var fails = 0
    func check(_ ok: Bool, _ what: String) {
      if !ok { fails += 1 }
      print("  \(ok ? "ok  " : "FAIL") \(what)")
    }
    var seed: UInt64 = 0x5EED
    func rnd() -> Double {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      return Double(seed >> 40) / Double(1 << 24)
    }
    let cases: [(String, [Double])] = [
      ("random 4096", (0..<4096).map { _ in rnd() }),
      ("already sorted", (0..<2000).map { Double($0) }),
      ("reverse sorted", (0..<2000).map { Double(2000 - $0) }),
      ("all equal", [Double](repeating: 7, count: 1500)),
      ("two values", (0..<1000).map { $0 % 2 == 0 ? 1.0 : 2.0 }),
      ("single", [42.0]),
      ("pair", [9.0, -3.0]),
      ("with negatives", (0..<777).map { _ in rnd() * 2 - 1 }),
    ]
    for (name, data) in cases {
      let sorted = data.sorted()
      var wrong = 0
      // Every index, not a sample of them: an off-by-one at one end is exactly
      // the bug this can have, and p99 lives at one end.
      for k in 0..<data.count {
        var copy = data
        if Quantiles.select(&copy, k) != sorted[k] { wrong += 1 }
      }
      check(wrong == 0, "\(name): all \(data.count) indices match sort() (\(wrong) wrong)")
    }
    // And through the real API, wrapped, the way the app uses it.
    var q = Quantiles(cap: 256)
    for i in 0..<1000 { q.add(Double((i * 37) % 1000)) }
    let ref = (0..<256).map { Double((($0 + 744) * 37) % 1000) }.sorted()
    let got = q.p(0.50)
    check(got == ref[128], "through add()/p(0.50) on a wrapped buffer "
                         + "(\(got.map { String($0) } ?? "nil") vs \(ref[128]))")
    check(Quantiles(cap: 16).p(0.5) == nil, "an empty buffer is nil, not zero")
    print(fails == 0 ? "QUANTILE TEST PASSED" : "QUANTILE TEST FAILED (\(fails))")
    return fails == 0
  }
}
