import Foundation
import os

// ── EVERY CONTROL, EVERY PHASE, COUNTED ──────────────────────────────────────
//
// A dashboard that only carries rates and averages can say a call was bad. It
// cannot say WHICH THING a person pressed and whether pressing it did anything,
// and that is the difference between "audio was poor" and "they pressed mute
// four times and it never took". Three interaction bugs in this codebase lived
// between the handler and the finger and none of them would have shown up in a
// rate.
//
// Rules this file follows, because analytics that costs latency is a defect:
//
//   * NOTHING here allocates or locks on the audio or video path. Every counter
//     is bumped from the main thread (controls) or a report thread, never from a
//     render callback -- the SIGSEGV that ended live calls came from a Swift
//     collection touched by the audio thread, so the lock is real and the rule
//     that keeps this off hot paths is not negotiable.
//   * The beat already leaves once a second. This adds fields to a message that
//     was being sent anyway; it opens no socket and starts no timer.
//   * A counter that is zero is still reported, because "nobody pressed it" and
//     "the field was dropped" must not look the same.
enum Metrics {
  // ── AND THE RULE ABOVE IS NOW ENFORCED, NOT JUST WRITTEN ──────────────────
  //
  // Every one of those bullets was true when written and stayed true by
  // everybody remembering it. That is not a property, it is a habit, and this
  // file is about to grow a lot more call sites -- every stage of a join, every
  // step of an update.
  //
  // So the audio thread identifies itself once, and every entry point below
  // checks. On the render thread the call takes NO LOCK and returns: a blocked
  // audio callback is a glitch in somebody's ear, and no counter is worth that.
  // It is not silent about it either -- `telemetry_on_audio_thread` rides out on
  // the next beat, so a mark added to a hot path in future shows up as a number
  // rather than as an unexplained stall. Reported, dropped, never blocking.
  //
  // The cost off the audio thread is one atomic load and a compare, which is
  // nothing next to the NSLock it guards.
  nonisolated(unsafe) private static var audioThread = pthread_t(bitPattern: 0)
  private static let onAudioThread = OSAllocatedUnfairLock(initialState: 0)

  /// Called once by the render callback, the first time it runs.
  static func claimAudioThread() {
    if audioThread == pthread_t(bitPattern: 0) { audioThread = pthread_self() }
  }

  /// True when the caller is the real-time audio thread, which must never block.
  @inline(__always) private static func hot() -> Bool {
    let a = audioThread
    guard a != pthread_t(bitPattern: 0) else { return false }
    guard pthread_equal(a, pthread_self()) != 0 else { return false }
    onAudioThread.withLock { $0 += 1 }
    return true
  }

  /// How many telemetry calls were refused for being on the audio thread. Zero
  /// on every build so far; a non-zero here is a latency bug with a name.
  static var refusedOnAudioThread: Int { onAudioThread.withLock { $0 } }

  private static let lock = NSLock()
  private static var taps: [String: Int] = [:]
  private static var fails: [String: Int] = [:]
  private static var marks: [String: Int] = [:]     // one-shot millisecond stamps
  private static var counts: [String: Int] = [:]    // free-form event counters
  private static var facts: [String: String] = [:]  // WHAT this call was made WITH

  /// A control was pressed. `ok: false` means the press was received and did NOT
  /// do its job -- a dead control, a refused action, a copy that did not land.
  static func tap(_ name: String, ok: Bool = true) {
    guard !hot() else { return }
    lock.lock()
    taps[name, default: 0] += 1
    if !ok { fails[name, default: 0] += 1 }
    lock.unlock()
  }

  /// A named moment, in milliseconds since launch. First writer wins: these are
  /// "when did this first happen", and a second write would turn a birth
  /// certificate into a health record.
  static func mark(_ name: String, _ ms: Int) {
    guard !hot() else { return }
    lock.lock()
    if marks[name] == nil { marks[name] = ms }
    lock.unlock()
  }

  static func count(_ name: String, _ n: Int = 1) {
    guard !hot() else { return }
    lock.lock(); counts[name, default: 0] += n; lock.unlock()
  }

  /// ── WHAT THE CALL WAS MADE WITH, NOT JUST HOW IT WENT ──────────────────────
  ///
  /// Rates and counters describe the RESULT. They cannot tell you that the Mac
  /// with the pixelated picture has no built-in camera, so it was running an
  /// external webcam handing us frames that were already lossily compressed
  /// before we re-encoded them -- which looks exactly like "it goes blocky when
  /// he moves" and is nothing to do with the network or the encoder.
  ///
  /// Last writer wins, unlike `mark`: a camera can be switched mid-call, and the
  /// one being used is the one that matters.
  static func fact(_ name: String, _ value: String) {
    guard !hot() else { return }
    lock.lock(); facts[name] = String(value.prefix(64)); lock.unlock()
  }

  static func has(_ name: String) -> Bool {
    lock.lock(); defer { lock.unlock() }; return marks[name] != nil
  }

  /// Snapshot for the beat. Returns plain dictionaries so `JSONSerialization`
  /// can take them; the caller decides which go on the wire.
  static func snapshot() -> (taps: [String: Int], fails: [String: Int],
                             marks: [String: Int], counts: [String: Int],
                             facts: [String: String]) {
    lock.lock(); defer { lock.unlock() }
    return (taps, fails, marks, counts, facts)
  }
}
