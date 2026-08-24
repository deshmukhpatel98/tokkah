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
  /// 0.4 is indistinguishable from unset, so 0.3 was a genuine retreat below the
  /// old behaviour rather than a relabelling of it.
  ///
  /// AND THAT WAS THE PROBLEM. 0.3 is 35.6 dB at 0.089 Mbps on a 1280x720 frame,
  /// and there is no resolution ladder under it -- the frame size is fixed, so the
  /// whole retreat is spent on quantiser. 0.089 Mbps of 720p is the picture two
  /// people described as "highly pixelated" while the other end looked perfect.
  /// It is not a degraded picture, it is a broken one, and a floor nobody wants to
  /// land on is not a floor. 0.5 is 40.1 dB at 0.221 Mbps: soft, watchable, and
  /// still an eighth of the lossless rung's bandwidth, so it retreats just as far
  /// in the direction that matters (queue, therefore latency) without the mush.
  static let LEVELS: [Double] = [0.5, 0.6, 0.7]

  private(set) var level: Int
  private let ceiling: Int
  /// Wall-clock seconds until a level may be tried again, indexed like LEVELS.
  private var blockedUntil = [Double](repeating: 0, count: LEVELS.count)
  private var penalty = [Double](repeating: 60, count: LEVELS.count)
  private var quietFor = 0
  private(set) var stepDowns = 0, stepUps = 0, refusedUps = 0

  // ── BELOW THE FLOOR THERE IS NO SMALLER PICTURE, SO STOP SENDING ONE ───────
  //
  // The ladder ends at 0.5 because everything under it was the "highly
  // pixelated" bug report, and a floor nobody wants to land on is not a floor.
  // But a link that keeps losing packets at the floor was then handed the one
  // answer this controller had left: nothing. It held 0.5 and kept pushing
  // 0.22 Mbps into a path that had already said no, and every one of those
  // packets shares a queue with the audio.
  //
  // Audio is the call. Video is the nice part. So when the floor is not enough,
  // the video stops entirely and the voice gets the whole link -- which is also
  // what people do by hand on a bad call, and they do it because it works.
  //
  // Pausing is NOT another rung. A rung is a picture; this is the absence of
  // one, it has to be visible to the person on the other end, and it has to be
  // hard to flap: a picture that comes and goes every four seconds is worse
  // than no picture at all. Hence a streak to enter, a longer quiet to leave,
  // and a resume-wait that doubles every time the link fools us again.
  private(set) var paused = false
  private(set) var pauses = 0
  private(set) var pausedTicks = 0
  /// Consecutive harmed seconds while already at the floor.
  private var harmedAtFloor = 0
  /// Consecutive quiet seconds while paused.
  private var quietPaused = 0
  /// Harmed seconds at the floor before the video stops.
  private let pauseAfter: Int
  /// Quiet seconds before it comes back -- doubling per pause, capped.
  private let resumeQuietBase: Int
  private let canPause: Bool

  /// Seconds of no harm before trying the next level up.
  private let quietNeeded = 15
  /// Seconds at the start of a call during which nothing counts as harm.
  private let warmup = 8

  /// Freeze the controller at its ceiling. `--vquality 0.7` sets a ceiling and the
  /// controller still descends from it, so there was no way to compare two levels
  /// under identical impairment -- an A/B of "is retreating the right call" pinned
  /// neither arm and measured nothing. A control arm has to be holdable.
  private let held: Bool

  init(ceiling: Double? = nil, hold: Bool = false, pause: Bool = true,
       pauseAfter: Int = 3, resumeQuiet: Int = 8) {
    held = hold
    canPause = pause
    self.pauseAfter = max(1, pauseAfter)
    self.resumeQuietBase = max(1, resumeQuiet)
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

    // ── WHILE PAUSED, THE ONLY QUESTION IS WHEN TO COME BACK ──────────────────
    //
    // Handled before anything else because none of the rules below apply: there
    // is no picture to step down, and stepping UP into a link that just refused
    // the floor would be the 2->1->2->1 cycle wearing a different hat.
    //
    // The wait doubles per pause in the same call. One pause is bad luck; three
    // is a link that is going to do it again, and each recovery costs the far
    // end a black-to-blur-to-face flicker they did not ask for.
    if paused {
      pausedTicks += 1
      if harmed { quietPaused = 0; return nil }
      quietPaused += 1
      let need = min(resumeQuietBase << min(pauses - 1, 3), 60)
      guard quietPaused >= need else { return nil }
      paused = false
      // Back at the FLOOR, never at the level that was in effect when the link
      // gave out -- the picture has to earn its way up through the same quiet
      // seconds as everybody else. `level` is already 0 (pausing can only happen
      // there), so the encoder needs no rebuild and this returns no change.
      level = 0
      quietFor = 0
      harmedAtFloor = 0
      return nil
    }

    if harmed {
      quietFor = 0
      if level == 0 {
        // Already at the floor and still being hurt. There is nothing smaller to
        // send, so send nothing -- but only after a STREAK. A single harmed
        // second at the floor is an ordinary internet hiccup, and stopping the
        // video for it would make the feature the fault.
        guard canPause else { return nil }
        harmedAtFloor += 1
        guard harmedAtFloor >= pauseAfter else { return nil }
        paused = true
        pauses += 1
        quietPaused = 0
        harmedAtFloor = 0
        return nil
      }
      // This level hurt. Do not come back to it soon, and double the wait each
      // time it hurts again -- a level that fails twice is not unlucky.
      //
      // The cap is 120 s, not 480. Doubling from a 60-second start reached eight
      // minutes after three bad seconds, and eight minutes is longer than most
      // calls: one bad minute on a link that then recovered pinned the picture at
      // the bottom for the entire rest of the conversation, with nothing on screen
      // saying why. Two minutes is long enough to stop the 2->1->2->1 cycle this
      // backoff exists to break, and short enough that a link which got better is
      // re-tested inside the same call.
      blockedUntil[level] = now + penalty[level]
      penalty[level] = min(penalty[level] * 2, 120)
      level -= 1
      stepDowns += 1
      return quality
    }
    quietFor += 1
    // A quiet second at the floor breaks the streak. Without this the counter is
    // a lifetime total of bad seconds rather than consecutive ones, and a link
    // that hiccups once a minute would eventually stop the video for good.
    harmedAtFloor = 0
    guard quietFor >= quietNeeded, level < ceiling else { return nil }
    let next = level + 1
    if now < blockedUntil[next] {
      refusedUps += 1
      // DO NOT reset `quietFor` here. It used to, and that made the up-path
      // starvable: a refusal is not harm, it is this controller declining its own
      // request, and zeroing the quiet counter on it meant the next attempt was
      // another 15 s away -- so a level blocked for 120 s was retried at 15, 30,
      // 45... and each retry pushed the clock out again. On a link that had gone
      // quiet the picture could never climb back at all. Keep the credit: the
      // quiet seconds were real, and the moment the block expires the step up
      // happens on the very next tick.
      return nil
    }
    level = next
    stepUps += 1
    quietFor = 0
    return quality
  }

  var describe: String {
    (paused ? "PAUSED (was q" : (held ? "HELD q" : "q")) + String(format: "%.1f", quality)
      + (paused ? ")" : "")
      + " (level \(level)/\(ceiling), \(stepDowns) down \(stepUps) up"
      + (refusedUps > 0 ? " \(refusedUps) up-refused" : "")
      + (pauses > 0 ? ", \(pauses) pause\(pauses == 1 ? "" : "s") \(pausedTicks)s" : "") + ")"
  }
}
