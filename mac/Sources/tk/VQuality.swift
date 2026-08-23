import Foundation

// ── How good the picture is allowed to be ────────────────────────────────────
//
// `--vpsnr` measured what the encoder can do (DESIGN 17.104):
//
//   quality unset  37.9 dB  0.122 Mbps      0.7  45.5 dB  1.185 Mbps  <- lossless
//   quality 0.6    43.0 dB  0.485 Mbps      0.8  47.7 dB  3.059 Mbps
//
// So visually lossless is reachable and costs about 1.2 Mbps. The reason it was
// not simply switched on is that nothing watched what happened next: on a link
// that cannot carry it, 1.2 Mbps of video queues, and a queue is latency -- which
// is the thing this whole program exists to remove. Better a slightly soft picture
// than a call that feels laggy.
//
// So: aim high, and give up quality the instant the link complains.
//
// The rules here are the ones the jitter-buffer controller had to learn the hard
// way, applied in the mirror image:
//
//   * ASYMMETRIC ON PURPOSE. Stepping DOWN is the safe direction, so it happens
//     on the first sign of harm. Stepping UP is a bet, so it needs sustained
//     quiet. The jitter buffer grows instantly and shrinks slowly for the same
//     reason, in the other direction.
//   * REMEMBER FAILED LEVELS, WITH BACKOFF. Without it the thing steps up into
//     the level that just failed, hurts, steps down, waits out its timer and does
//     it again forever. That exact cycle was observed in the buffer at 2->1->2->1.
//   * WATCH FOR HARM WE CAN ACTUALLY FIX. A lost video frame and a grown audio
//     buffer are both "this link is unhappy about volume", which is a thing less
//     video volume addresses. Round-trip time is not, and neither is a device
//     stall, so neither is wired in here.
final class VQuality {
  /// Lowest first. ALL NUMERIC, and that is a bug fix: the bottom rung was `nil`,
  /// meaning "clear the property and go back to the old default", and
  /// `VTSessionSetProperty(Quality, nil)` is REFUSED. So under 3% loss the
  /// controller stepped 0.7 -> 0.6 -> 0.5 -> off, printed the retreat, and the
  /// encoder quietly stayed at 0.5 -- the one step that mattered most was the one
  /// that did not happen.
  ///
  /// A number is also a better floor. Measured over 240 frames at a 3 Mbps target:
  ///
  ///   0.2  33.1 dB  0.060 Mbps      0.5  40.1 dB  0.221 Mbps
  ///   0.3  35.6 dB  0.089 Mbps      0.6  43.0 dB  0.485 Mbps
  ///   0.4  37.5 dB  0.129 Mbps      0.7  45.5 dB  1.185 Mbps  <- lossless
  ///   unset 37.9 dB 0.122 Mbps      0.8  47.7 dB  3.059 Mbps
  ///
  /// 0.4 is indistinguishable from unset, so 0.3 is a genuine retreat below the
  /// old behaviour rather than a relabelling of it.
  static let LEVELS: [Double] = [0.3, 0.5, 0.6, 0.7]

  private(set) var level: Int
  private let ceiling: Int
  /// Wall-clock seconds until a level may be tried again, indexed like LEVELS.
  private var blockedUntil = [Double](repeating: 0, count: LEVELS.count)
  private var penalty = [Double](repeating: 60, count: LEVELS.count)
  private var quietFor = 0
  private(set) var stepDowns = 0, stepUps = 0, refusedUps = 0

  /// Seconds of no harm before trying the next level up.
  private let quietNeeded = 15
  /// Seconds at the start of a call during which nothing counts as harm.
  private let warmup = 8

  /// Freeze the controller at its ceiling. `--vquality 0.7` sets a ceiling and the
  /// controller still descends from it, so there was no way to compare two levels
  /// under identical impairment -- an A/B of "is retreating the right call" pinned
  /// neither arm and measured nothing. A control arm has to be holdable.
  private let held: Bool

  init(ceiling: Double? = nil, hold: Bool = false) {
    held = hold
    // A `--vquality` value pins the ceiling; without one the ceiling is the top
    // rung, which is the point of the exercise.
    if let c = ceiling {
      var best = 0
      for (i, l) in VQuality.LEVELS.enumerated() where l <= c + 1e-9 { best = i }
      self.ceiling = best
    } else {
      self.ceiling = VQuality.LEVELS.count - 1
    }
    self.level = self.ceiling
  }

  var quality: Double { VQuality.LEVELS[level] }

  /// One tick per second, with what happened since the last one. Returns the new
  /// quality when it changed, so the caller only touches the encoder on a change.
  func tick(now: Double, framesLost: Int, concealed: Int, jitGrew: Bool) -> Double? {
    if held { return nil }
    // ── Ignore the first seconds entirely ────────────────────────────────────
    //
    // A call's opening is full of harm that means nothing: the buffer finding its
    // level, the first keyframe, the estimators converging. Observed on a
    // perfectly clean link -- one immediate step down to 0.6, then fifteen
    // seconds of waiting to climb back. Sampling before the inputs settle is how
    // a wrong value gets learned, and this one costs real picture quality for the
    // first half-minute of every call.
    guard now >= Double(warmup) else { return nil }
    let harmed = framesLost > 0 || concealed > 0 || jitGrew
    if harmed {
      quietFor = 0
      guard level > 0 else { return nil }          // already at the floor
      // This level hurt. Do not come back to it soon, and double the wait each
      // time it hurts again -- a level that fails twice is not unlucky.
      blockedUntil[level] = now + penalty[level]
      penalty[level] = min(penalty[level] * 2, 480)
      level -= 1
      stepDowns += 1
      return quality
    }
    quietFor += 1
    guard quietFor >= quietNeeded, level < ceiling else { return nil }
    let next = level + 1
    if now < blockedUntil[next] {
      refusedUps += 1
      quietFor = 0                                  // wait out the block, quietly
      return nil
    }
    level = next
    stepUps += 1
    quietFor = 0
    return quality
  }

  var describe: String {
    (held ? "HELD q" : "q") + String(format: "%.1f", quality)
      + " (level \(level)/\(ceiling), \(stepDowns) down \(stepUps) up"
      + (refusedUps > 0 ? " \(refusedUps) up-refused" : "") + ")"
  }
}
