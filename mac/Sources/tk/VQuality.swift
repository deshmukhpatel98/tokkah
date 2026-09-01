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

  // ── A PAUSE THAT DOES NOT HELP IS NOT A PAUSE, IT IS AN OUTAGE ─────────────
  //
  // Reported from the field: *"my Internet speed is quite good, even then when I'm
  // trying to make a call it is saying connection paused due to slow Internet
  // speed... my Internet speed is actually sometimes one Gbps."*
  //
  // The telemetry from those calls says exactly what happened, per beat:
  //
  //     dLost  vmbps  qlvl  paused
  //       161  1.147     1       0      <- loss appears, picture retreats
  //       176  0.392     0       0
  //       207  0.379     0       0
  //        70      0     0       1      <- video stops
  //       171      0     0       1
  //       142      0     0       1
  //       162      0     0       1      <- ...and the loss is UNCHANGED
  //
  // The picture went away for the rest of the call and the harm it went away to
  // fix carried on at the same rate with nothing being sent. That is the whole
  // proof: the loss was not caused by video volume, so no amount of sending less
  // video could reduce it -- and the resume rule ("come back after N quiet
  // seconds") can never fire on a path that is losing packets for its own
  // reasons. One bad minute cost the entire rest of the conversation.
  //
  // The signal is also not what the name suggests. `peerRxLost` is the far end's
  // AUDIO concealment count: packets of voice that did not arrive in time. It is
  // reasonable evidence that a path is unhappy and it is not evidence that OUR
  // video is why -- and this controller was treating it as both.
  //
  // So the pause now has to earn its keep. The harm in the seconds before it is
  // remembered, the harm in the seconds after it is measured, and if stopping the
  // video did not materially reduce it then the pause is abandoned and never tried
  // again on this call. A control loop that cannot tell whether its own action
  // worked is a control loop steering on a signal it does not move.
  /// Harm counted in the seconds leading up to a pause.
  private var harmBefore = 0
  /// Harm counted in the judging window after one.
  private var harmAfter = 0
  private var judgeTicks = 0
  /// Seconds of video-off before the verdict is read. Long enough for the far
  /// end's counters to reflect a link with no video on it, short enough that a
  /// wrong pause costs a few seconds of picture rather than a conversation.
  private static let judgeWindow = 4
  /// Set once a pause has been measured to make no difference. Pausing is then off
  /// for the rest of the call.
  private(set) var pauseHelpless = false
  /// What the last verdict was, for the log and the beat.
  private(set) var pauseVerdict = ""
  /// The last few seconds of harm, so `harmBefore` is a real number rather than
  /// the one tick that happened to cross the line.
  private var recentHarm: [Int] = []
  /// Hard ceiling on one pause. Even a pause that IS working must let the picture
  /// try again: a permanently lossy path would otherwise mean a permanently black
  /// call, and a soft picture beats no picture. Re-judged when it comes back.
  private static let maxPausedTicks = 30
  private var thisPauseTicks = 0
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
  /// `harmRaw` is the harm counted this second WHETHER OR NOT it crossed the line
  /// that makes it actionable. `framesLost` is the actionable half and is what the
  /// rules below steer on; `harmRaw` is what the pause is judged by, because a
  /// verdict computed from a number that has been zeroed by a threshold can only
  /// ever say "it worked".
  /// ── TWO SIGNALS, EACH STEERING THE THING IT CAN ACTUALLY MOVE ────────────
  ///
  /// `pictureHarmed` is the far end losing VIDEO. That is what the quality ladder
  /// is for: a smaller picture is fewer bytes and fewer fragments to lose.
  ///
  /// `voiceHarmed` / `voiceHarmRaw` is the far end losing AUDIO. That is what the
  /// PAUSE is for, and the code has always said so in as many words -- "audio is
  /// the call, video is the nice part... the video stops entirely and the voice
  /// gets the whole link". The pause exists to protect the voice, so the voice is
  /// what decides whether to take it and whether it worked.
  ///
  /// Getting this the wrong way round is not hypothetical, it is what shipped: one
  /// signal (audio concealment) drove both, so a path losing voice packets for its
  /// own reasons stopped the picture forever, and a path destroying the picture
  /// while FEC repaired the voice was invisible.
  ///
  /// And the verdict CANNOT be read off the video's own loss, which is the trap in
  /// the obvious fix: with the video paused there are no video fragments, so video
  /// harm is necessarily zero and every pause would grade itself a success. A
  /// metric that cannot see the failure returns the same value as a pass.
  func tick(now: Double, pictureHarmed: Bool, voiceHarmed: Bool,
            voiceHarmRaw: Int) -> Double? {
    if held { return nil }
    recentHarm.append(voiceHarmRaw)
    if recentHarm.count > pauseAfter { recentHarm.removeFirst() }
    // ── Ignore the first seconds entirely ────────────────────────────────────
    //
    // A call's opening is full of harm that means nothing: the buffer finding its
    // level, the first keyframe, the estimators converging. Observed on a
    // perfectly clean link -- one immediate step down to 0.6, then fifteen
    // seconds of waiting to climb back. Sampling before the inputs settle is how
    // a wrong value gets learned, and this one costs real picture quality for the
    // first half-minute of every call.
    guard now >= Double(warmup) else { return nil }
    // Either kind of unhappiness stops the picture climbing; only the picture's own
    // loss makes it step down, and only the voice's makes it stop.
    let harmed = pictureHarmed || voiceHarmed

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
      thisPauseTicks += 1
      // ── THE VERDICT ────────────────────────────────────────────────────────
      //
      // Read once, `judgeWindow` seconds in, on the raw count rather than on the
      // thresholded half: a number already zeroed by a threshold can only ever say
      // the pause worked. Compared as RATES -- see below for what happened when it
      // was not.
      if judgeTicks < VQuality.judgeWindow {
        harmAfter += voiceHarmRaw
        judgeTicks += 1
        if judgeTicks == VQuality.judgeWindow {
          // ── THE BAR IS "DID IT FIX IT", NOT "DID IT MOVE IT" ────────────────
          //
          // At the floor rung the video is about 0.22 Mbps against the voice's
          // 1.33, so stopping it gives back roughly a seventh of the link. On a
          // path that is a little over capacity that seventh is decisive and the
          // loss goes to nothing; on a path that is far over it, or one losing
          // packets for reasons that have nothing to do with volume, a seventh
          // changes nothing you could hear.
          //
          // So a bar of "fell by a third" would be measuring the wrong thing in
          // both directions: it would credit a pause that shaved the edge off a
          // still-broken call, and it can only ever be met at all when the video
          // was a large share of the traffic. Halved-or-better is the line, and
          // the `max(2,...)` is there because at small counts every ratio is
          // noise -- two packets to one is not evidence of anything.
          // ── RATES, NOT SUMS ─────────────────────────────────────────────────
          //
          // `harmBefore` is summed over `pauseAfter` seconds and `harmAfter` over
          // `judgeWindow` seconds, and those are different numbers. Comparing the
          // two totals directly made a pause that took the loss to nothing read as
          // a pause that had DOUBLED it: measured 211 before, 354 after, on a link
          // where the voice was demonstrably fine the moment the video stopped.
          // Two seconds against four. A constant written per block hides the block
          // size, and this file just paid for that once.
          let beforeRate = Double(harmBefore) / Double(max(1, pauseAfter))
          let afterRate = Double(harmAfter) / Double(VQuality.judgeWindow)
          let helped = afterRate <= max(2.0, beforeRate * 0.5)
          let word = helped ? "the pause is helping" : "THE PAUSE IS NOT HELPING"
          pauseVerdict = String(format: "voice harm %.0f/s -> %.0f/s", beforeRate, afterRate)
            + " over \(VQuality.judgeWindow)s with no video: \(word)"
          if !helped {
            // Stopping the video did not reduce the harm, so the video was never
            // the cause. Give the picture back and do not take it away again on
            // this call: whatever this path is doing, less video is not the answer
            // and a black call is a worse one.
            pauseHelpless = true
            paused = false
            thisPauseTicks = 0
            level = 0
            quietFor = 0
            harmedAtFloor = 0
            quietPaused = 0
            return nil
          }
        }
      }
      // Even a pause that IS working does not get the rest of the call. See
      // `maxPausedTicks`.
      if thisPauseTicks >= VQuality.maxPausedTicks {
        pauseVerdict += " -- \(VQuality.maxPausedTicks)s is long enough; trying the picture again"
        paused = false
        thisPauseTicks = 0
        level = 0
        quietFor = 0
        harmedAtFloor = 0
        quietPaused = 0
        return nil
      }
      // While paused the picture cannot be harmed -- there is none -- so the only
      // question that means anything is whether the VOICE is still suffering.
      if voiceHarmed { quietPaused = 0; return nil }
      quietPaused += 1
      let need = min(resumeQuietBase << min(pauses - 1, 3), 60)
      guard quietPaused >= need else { return nil }
      paused = false
      thisPauseTicks = 0
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
        // The pause protects the voice, so the voice is what arms it. A picture
        // being damaged on a link whose audio is perfectly fine is a reason to send
        // a smaller picture, and there is no smaller one -- it is not a reason to
        // send none.
        guard voiceHarmed, canPause, !pauseHelpless else { return nil }
        harmedAtFloor += 1
        guard harmedAtFloor >= pauseAfter else { return nil }
        paused = true
        pauses += 1
        quietPaused = 0
        harmedAtFloor = 0
        // The baseline the verdict is measured against, taken from the seconds
        // that caused the pause -- before it, because after it there is nothing to
        // compare with.
        harmBefore = recentHarm.reduce(0, +)
        harmAfter = 0
        judgeTicks = 0
        thisPauseTicks = 0
        return nil
      }
      // Only the picture's own loss steps the picture down. A voice-only problem
      // has nothing to do with which quantiser the encoder is using, and treating
      // it as though it did is how a clean link ended up at the bottom rung.
      guard pictureHarmed else { return nil }
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
      + (pauses > 0 ? ", \(pauses) pause\(pauses == 1 ? "" : "s") \(pausedTicks)s" : "")
      + (pauseHelpless ? ", pausing ABANDONED" : "") + ")"
      + (pauseVerdict.isEmpty ? "" : " [\(pauseVerdict)]")
  }
}
