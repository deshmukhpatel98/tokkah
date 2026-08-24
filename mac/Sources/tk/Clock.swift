import Darwin

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
  func p(_ q: Double) -> Double? {
    if Int(bitPattern: v) < 4096 { return nil }
    let m = min(cap, wrapped ? cap : n)
    guard m > 0 else { return nil }
    var tmp = [Double](repeating: 0, count: m)
    for i in 0..<m { tmp[i] = v[i] }
    tmp.sort()
    let i = min(m - 1, max(0, Int((Double(m) * q).rounded(.down))))
    return tmp[i]
  }

  mutating func reset() { n = 0; wrapped = false }
}
