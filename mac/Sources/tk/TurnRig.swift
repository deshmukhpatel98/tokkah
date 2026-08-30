import Foundation

// ── THE TURN LAYER, ON TWO PEOPLE ACTUALLY TALKING ───────────────────────────
//
// `--floor-test` proves the state machine against a script of labels. That is
// necessary and it is not sufficient, because it never asks the question the
// person cares about:
//
//   When the rule is in force, how much of what somebody said never left the
//   machine?
//
// This rig answers that in milliseconds of real speech, using the real
// recordings in `testbed/media/real`, the real `DuplexGate` classifier, and the
// real `Floor`. Nothing here is synthetic except the room.
//
// ── WHY IT HAS TO BE A/B ─────────────────────────────────────────────────────
//
// A number like "310 ms of speech held back" is unreadable on its own: some of
// it is the echo gate that already ships, and the question is what the TURN
// layer added. So every run measures both arms over identical audio -- floor on
// and floor off -- and reports the difference. `measure-the-rigs-noise-first`.
//
// ── AND WHY THE ROOM IS SIMULATED RATHER THAN REAL ───────────────────────────
//
// It has to be. Both ends of any rig on this machine share one set of speakers
// and one microphone, so a rig here cannot hear real acoustic echo
// (`same-room-is-a-test-artifact`). What it CAN do is put each end's playout
// into the other end's microphone at a measured coupling and delay, which is
// what a room does, and that is enough to make the classifier face the actual
// ambiguity it exists for. It is not enough to judge the sound. Only a real
// two-room call does that, and this rig does not claim otherwise.
enum TurnRig {

  /// One end: its own voice, the room's copy of the far end, and the two things
  /// that decide whether it is heard.
  private final class End {
    let gate = Audio.DuplexGate()
    let floor = Floor()
    var voice: [Float] = []
    /// Milliseconds of this end's OWN speech that never reached the wire, split
    /// by which mechanism took it.
    var lostMs: Double = 0
    var speechMs: Double = 0
    /// Longest unbroken stretch of own speech that was held back. The mean is a
    /// comfort; this is the number a person would actually notice.
    var worstRunMs: Double = 0
    private var runMs: Double = 0
    var duckedMs: Double = 0
    /// ── SILENCED IS NOT THE SAME AS QUIETER ───────────────────────────────────
    ///
    /// Judged on the GAIN the gate actually applied, not on how loud the block
    /// came out. Reading the output level counts a quiet syllable under a 20 dB
    /// duck as a lost one, which reported 23% of a person missing when they were
    /// audible the whole time. -26 dB is the line: below it nothing survives, and
    /// between it and -3 dB somebody is talking under somebody else, which is
    /// what a duck is FOR.
    func note(spoke: Bool, gain: Float, ms: Double) {
      guard spoke else { runMs = 0; return }
      speechMs += ms
      if gain > 0.05 {
        if gain < 0.7 { duckedMs += ms }
        runMs = 0
        return
      }
      lostMs += ms
      runMs += ms
      worstRunMs = max(worstRunMs, runMs)
    }
  }

  /// ── THE INPUT HAS TO BE A CONVERSATION ──────────────────────────────────────
  ///
  /// The recordings are two separate monologues. Played against each other raw,
  /// both people talk essentially all of the time, and the first run of this rig
  /// duly reported that the floor ate 32 of A's 36 seconds -- 90% of a person.
  /// That number was real and the input was not: two people do not both talk for
  /// thirty-six unbroken seconds, and a rule for taking turns cannot be judged on
  /// audio containing no turns.
  ///
  /// So the rig cuts the monologues into turns. `turnS` of one person, then the
  /// other, with `overlapS` where the next speaker starts before the last one
  /// stops -- which is the only genuinely hard moment and the reason any of this
  /// exists. The pathological version is still run, as a named stress arm, and
  /// judged on a different bar.
  private static func envelope(_ x: inout [Float], mine: Bool,
                               turnS: Double, overlapS: Double) {
    guard turnS > 0 else { return }
    let period = turnS * 2
    for i in 0..<x.count {
      let t = Double(i) / SR
      let phase = t.truncatingRemainder(dividingBy: period)
      // My turn is the first half; I start `overlapS` early and stop on time.
      let start = mine ? 0.0 : turnS - overlapS
      let end = mine ? turnS : period
      var on = phase >= start && phase < end
      if !mine, phase < overlapS { on = true }   // the wrap of my own turn's tail
      if !on { x[i] = 0 }
    }
  }

  static func run(paths: [String], owdMs: Double, coupling: Float,
                  floorOn: Bool, blockN: Int,
                  turnS: Double, overlapS: Double) -> (a: (lost: Double, speech: Double, worst: Double, ducked: Double),
                                                  b: (lost: Double, speech: Double, worst: Double, ducked: Double)) {
    let a = End(), b = End()
    a.floor.yieldsOnTie = true
    b.floor.yieldsOnTie = false
    for e in [a, b] {
      e.floor.speakers = true
      e.gate.cfg = Audio.Gate()
      e.floor.noteFar(.quiet, transitMs: owdMs)
    }
    a.voice = (Predict.readWav(Self.locate(paths[0]))?.pcm) ?? []
    b.voice = (Predict.readWav(Self.locate(paths[1]))?.pcm) ?? []
    envelope(&a.voice, mine: true, turnS: turnS, overlapS: overlapS)
    envelope(&b.voice, mine: false, turnS: turnS, overlapS: overlapS)
    let n = min(a.voice.count, b.voice.count)
    guard n > blockN * 4 else { return ((0, 0, 0, 0), (0, 0, 0, 0)) }

    let dtMs = Double(blockN) / SR * 1000
    let hop = max(1, Int((owdMs / 1000 * SR).rounded()) / blockN)   // in blocks
    // What each end most recently PUT ON THE WIRE, delayed by a hop, is what the
    // other end plays -- and what the other end's microphone therefore also
    // hears, at `coupling`. That is the loop the classifier has to survive.
    var wireA = [[Float]](repeating: [Float](repeating: 0, count: blockN), count: hop + 1)
    var wireB = wireA
    var cueA = [Floor.Voice](repeating: .quiet, count: hop + 1)
    var cueB = cueA

    var mic = [Float](repeating: 0, count: blockN)
    var i = 0, blk = 0
    while i + blockN <= n {
      for (me, you, myWire, yourWire, myCue, yourCue) in
          [(a, b, 0, 1, 0, 1), (b, a, 1, 0, 1, 0)] as [(End, End, Int, Int, Int, Int)] {
        let src = me === a ? a.voice : b.voice
        let farPlayed = (me === a ? wireB : wireA)[blk % (hop + 1)]
        let farCue = (me === a ? cueB : cueA)[blk % (hop + 1)]
        _ = you; _ = myWire; _ = yourWire; _ = myCue; _ = yourCue

        // The room: my own voice, plus the far end's playout coming back off my
        // speaker. This is the signal the classifier actually gets.
        var peak: Float = 0
        for k in 0..<blockN {
          mic[k] = src[i + k] + coupling * farPlayed[k]
          peak = max(peak, abs(src[i + k]))
        }
        // Ground truth: was this person REALLY speaking in this block? Taken
        // from the clean recording before the room touched it, because the
        // whole point is to judge the machine against what was actually said.
        let spoke = peak > 0.02

        me.gate.noteFar(rms(farPlayed))
        me.floor.noteFar(farCue, transitMs: owdMs)
        me.gate.process(&mic, blockN)
        let d = me.floor.step(dt: Double(blockN) / SR,
                              near: Floor.Voice(rawValue: me.gate.vocal.rawValue) ?? .quiet)
        me.gate.floorMuted = floorOn && !d.mayTransmit && !d.duckOnly
        me.gate.floorDucked = floorOn && d.duckOnly
        me.note(spoke: spoke, gain: me.gate.appliedGainNow, ms: dtMs)

        let slot = (blk + hop) % (hop + 1)
        if me === a {
          wireA[slot] = mic; cueA[slot] = Floor.Voice(rawValue: me.gate.vocal.rawValue) ?? .quiet
        } else {
          wireB[slot] = mic; cueB[slot] = Floor.Voice(rawValue: me.gate.vocal.rawValue) ?? .quiet
        }
      }
      i += blockN; blk += 1
    }
    return ((a.lostMs, a.speechMs, a.worstRunMs, a.duckedMs),
            (b.lostMs, b.speechMs, b.worstRunMs, b.duckedMs))
  }

  /// ── A RIG WHOSE ANSWER DEPENDS ON THE WORKING DIRECTORY IS A TRAP ─────────
  ///
  /// The media paths are relative to the repository, so running this from `mac/`
  /// found nothing and the rig refused -- correctly, because a rig that cannot
  /// see its subject must never report a pass. But "correct" and "usable" are
  /// different: the same command passed from one directory and failed from
  /// another, with the reason two lines up the output. So it looks upward for
  /// the file instead of demanding a cwd.
  private static func locate(_ p: String) -> String {
    let fm = FileManager.default
    if fm.fileExists(atPath: p) { return p }
    var up = ""
    for _ in 0..<4 {
      up += "../"
      if fm.fileExists(atPath: up + p) { return up + p }
    }
    return p
  }

  private static func rms(_ x: [Float]) -> Float {
    var s: Float = 0
    for v in x { s += v * v }
    return (s / Float(max(1, x.count))).squareRoot()
  }

  static func selfTest(paths: [String], owdMs: Double, coupling: Float) -> Bool {
    // THE BLOCK SIZE IS SWEPT, NOT PICKED. A rig that chooses a buffer the
    // product does not is how a classifier that could never fire stayed green
    // for weeks (`rig-picks-a-parameter-the-product-does-not`). The machine
    // hands the gate 16.
    let blocks = [16, 128]
    var ok = true
    print(String(format: "TURN RIG  real speech, owd %.0f ms, coupling %.2f",
                 owdMs, coupling))
    print("  a conversation: 4 s turns, 0.3 s of overlap at each handover")
    print("  arm      end   speech    silenced   worst run    ducked")
    let turnS = 4.0, overlapS = 0.3
    for bn in blocks {
      let off = run(paths: paths, owdMs: owdMs, coupling: coupling, floorOn: false,
                    blockN: bn, turnS: turnS, overlapS: overlapS)
      let on = run(paths: paths, owdMs: owdMs, coupling: coupling, floorOn: true,
                   blockN: bn, turnS: turnS, overlapS: overlapS)
      guard off.a.speech > 500 else {
        print("  no speech loaded from \(paths) -- rig cannot see anything"); return false
      }
      print("  --- block \(bn) samples ---")
      for (name, o, f) in [("A", off.a, on.a), ("B", off.b, on.b)] {
        print(String(format: "  floor off  %@  %7.0f ms  %7.0f ms  %7.0f ms  %7.0f ms",
                     name, o.speech, o.lost, o.worst, o.ducked))
        print(String(format: "  floor ON   %@  %7.0f ms  %7.0f ms  %7.0f ms  %7.0f ms",
                     name, f.speech, f.lost, f.worst, f.ducked))
        // ── THE BAR ────────────────────────────────────────────────────────────
        //
        // The turn layer may not eat more of somebody's real speech than the
        // retroactive buffer can give back. 600 ms is that buffer. A longer
        // unbroken run than this is a word that is simply gone, and there is no
        // suppression figure that makes that acceptable.
        if f.worst > 600 {
          print(String(format: "  FAIL %@ lost an unbroken %.0f ms of real speech", name, f.worst))
          ok = false
        }
        // And it may not be dramatically worse than the arm that already ships.
        let added = f.lost - o.lost
        if added > o.speech * 0.05 {
          print(String(format: "  FAIL %@ the floor added %.0f ms of loss (>5%% of speech)",
                       name, added))
          ok = false
        }
      }
    }
    // ── THE STRESS ARM, WHICH IS NOT A CONVERSATION AND IS NOT SCORED THE SAME ─
    //
    // Both monologues raw, so both people talk continuously for a minute. No two
    // people do this, and the rule cannot make them both audible -- that is the
    // rule. What it still must not do is chop: the ceiling has to hold, so no
    // single unbroken stretch of anybody's speech may exceed what the buffer can
    // return. Reported always, because a stress arm that only prints on failure
    // is a stress arm nobody reads.
    let s = run(paths: paths, owdMs: owdMs, coupling: coupling, floorOn: true,
                blockN: 16, turnS: 0, overlapS: 0)
    print(String(format: "  stress (both talk nonstop, not a conversation): "
                       + "worst unbroken A %.0f ms  B %.0f ms", s.a.worst, s.b.worst))
    if max(s.a.worst, s.b.worst) > 600 {
      print("  FAIL the ceiling did not hold under sustained overlap")
      ok = false
    }

    print(ok ? "TURN RIG PASSED" : "TURN RIG FAILED")
    return ok
  }
}
