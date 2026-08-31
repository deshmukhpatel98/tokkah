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
    /// What the floor last said about this end's speaker. The echo the room
    /// returns depends on it, so the rig has to carry it block to block.
    var lastPlayoutOpen = true
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
    /// ── ONSET TO WIRE, WHICH IS THE NUMBER A PERSON FEELS ────────────────────
    ///
    /// Reported 2026-08-31 as "a delay of one second... latency in deciding who
    /// is speaking". Nothing here measured it: `lostMs` is a total and
    /// `worstRunMs` is the worst case anywhere in the call, so 700 ms of dead
    /// air at the START of every single utterance -- the classifier's own
    /// `claimMs`, before which strict idle transmitted nothing -- averaged into
    /// a number that looked survivable. This is per utterance, from the first
    /// block of real speech to the first block that got out.
    var onsets: [Double] = []
    var onsetsLost = 0
    /// ── AND THE SUBSET THAT IS ACTUALLY A TURN START ─────────────────────────
    ///
    /// Most utterances in a turn begin while this end ALREADY holds the floor,
    /// and those are free -- so a median over all of them is 0 ms whatever the
    /// turn rule does, which is exactly what the control arm caught: the old
    /// rule scored the same p50 as the fix. What a person feels is the
    /// utterance that begins when the floor is NOT theirs: the moment they
    /// start talking after the other person. That is this.
    var handovers: [Double] = []
    var handoversLost = 0
    private var onsetMs: Double = -1
    private var onsetHandover = false
    private var gapMs: Double = 0

    /// `farSpoke` is the OTHER end's ground truth. The onset clock stops while
    /// it is true: time spent waiting for somebody who is genuinely still
    /// talking is turn-taking, not latency, and counting it measured 313 ms of
    /// "delay" that was entirely the rig's own scripted 300 ms of overlap. What
    /// is left is dead air the app ADDED -- the number the complaint is about.
    func note(spoke: Bool, gain: Float, ms: Double, floorMine: Bool = true,
              farSpoke: Bool = false) {
      guard spoke else {
        // ── AN UTTERANCE ENDS ON A GAP, NOT ON A QUIET BLOCK ─────────────────
        //
        // A block is 0.33 ms at the size the machine actually uses, and speech
        // is only voiced about half the time at that resolution -- so ending
        // an utterance at the first quiet block counted 201 "utterances" in
        // 19 s of one person talking, i.e. glottal periods, and every one of
        // them wanted its own onset. The classifier uses 450 ms to end a
        // vocalisation; 200 ms is the shortest gap that is a pause between
        // words rather than a gap between syllables.
        gapMs += ms
        if onsetMs >= 0, gapMs >= 200 {
          onsetsLost += 1
          if onsetHandover { handoversLost += 1 }
          onsetMs = -1
        }
        runMs = 0
        return
      }
      gapMs = 0
      speechMs += ms
      if onsetMs < 0, onsets.count + onsetsLost < 4096 {
        onsetMs = 0
        // Classified at the START of the utterance: whether this person had to
        // be GIVEN the floor to be heard, which is what makes it a handover.
        onsetHandover = !floorMine
      }
      if gain > 0.05 {
        if onsetMs >= 0 {
          onsets.append(onsetMs)
          if onsetHandover { handovers.append(onsetMs) }
          onsetMs = -1
        }
        if gain < 0.7 { duckedMs += ms }
        runMs = 0
        return
      }
      if onsetMs >= 0, !farSpoke { onsetMs += ms }
      lostMs += ms
      runMs += ms
      worstRunMs = max(worstRunMs, runMs)
    }
    /// Median, and the worst -- an onset p50 of 20 ms with a 700 ms tail is a
    /// different product from one that is flat.
    var onsetP50: Double { onsets.isEmpty ? -1 : onsets.sorted()[onsets.count / 2] }
    var onsetMax: Double { onsets.max() ?? -1 }
    var handoverP50: Double { handovers.isEmpty ? -1 : handovers.sorted()[handovers.count / 2] }
    var handoverMax: Double { handovers.max() ?? -1 }
    var handoverN: Int { handovers.count }
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
                  turnS: Double, overlapS: Double, strict: Bool = true,
                  idleTakesAnyVoice: Bool = true) -> (a: (lost: Double, speech: Double, worst: Double, ducked: Double, onsetP50: Double, onsetMax: Double, onsetsLost: Int, hP50: Double, hMax: Double, hN: Int, hLost: Int),
                                                  b: (lost: Double, speech: Double, worst: Double, ducked: Double, onsetP50: Double, onsetMax: Double, onsetsLost: Int, hP50: Double, hMax: Double, hN: Int, hLost: Int)) {
    let a = End(), b = End()
    a.floor.yieldsOnTie = true
    b.floor.yieldsOnTie = false
    for e in [a, b] {
      e.floor.speakers = true
      e.floor.cfg.strict = strict
      e.floor.cfg.idleTakesAnyVoice = idleTakesAnyVoice
      e.gate.cfg = Audio.Gate()
      e.floor.noteFar(.quiet, transitMs: owdMs)
    }
    a.voice = (Predict.readWav(Self.locate(paths[0]))?.pcm) ?? []
    b.voice = (Predict.readWav(Self.locate(paths[1]))?.pcm) ?? []
    envelope(&a.voice, mine: true, turnS: turnS, overlapS: overlapS)
    envelope(&b.voice, mine: false, turnS: turnS, overlapS: overlapS)
    let n = min(a.voice.count, b.voice.count)
    guard n > blockN * 4 else { return ((0, 0, 0, 0, -1, -1, 0, -1, -1, 0, 0), (0, 0, 0, 0, -1, -1, 0, -1, -1, 0, 0)) }

    let dtMs = Double(blockN) / SR * 1000
    let hop = max(1, Int((owdMs / 1000 * SR).rounded()) / blockN)   // in blocks
    // What each end most recently PUT ON THE WIRE, delayed by a hop, is what the
    // other end plays -- and what the other end's microphone therefore also
    // hears, at `coupling`. That is the loop the classifier has to survive.
    var wireA = [[Float]](repeating: [Float](repeating: 0, count: blockN), count: hop + 1)
    var wireB = wireA
    var cueA = [Floor.Voice](repeating: .quiet, count: hop + 1)
    var cueB = cueA
    // The fast voicing bit rides its own delay lane, exactly like the cue: it
    // is a real wire signal (`Wire.ST_VOICING`) and a rig that fed it
    // instantly would measure a protocol nobody has.
    var vocA = [Bool](repeating: false, count: hop + 1)
    var vocB = vocA

    var mic = [Float](repeating: 0, count: blockN)
    var i = 0, blk = 0
    while i + blockN <= n {
      for (me, you, myWire, yourWire, myCue, yourCue) in
          [(a, b, 0, 1, 0, 1), (b, a, 1, 0, 1, 0)] as [(End, End, Int, Int, Int, Int)] {
        let src = me === a ? a.voice : b.voice
        let farPlayed = (me === a ? wireB : wireA)[blk % (hop + 1)]
        let farCue = (me === a ? cueB : cueA)[blk % (hop + 1)]
        let farVoicing = (me === a ? vocB : vocA)[blk % (hop + 1)]
        _ = you; _ = myWire; _ = yourWire; _ = myCue; _ = yourCue

        // The room: my own voice, plus the far end's playout coming back off my
        // speaker. This is the signal the classifier actually gets.
        // ── THE EAR IS PART OF THE ROOM ────────────────────────────────────
        //
        // The floor CLOSES the holder's speaker (that is half the rule: one mic
        // live, that machine's speaker off). This rig injected the far end's
        // audio into the microphone regardless, so the holder's own mic was fed
        // an echo the product would never have produced -- and the holder's
        // classifier then heard it, kept claiming through its own silence
        // (measured: 8345 blocks reporting voicing while the source was quiet),
        // and the other person waited on a cue that never came. The room has to
        // be the room the product builds.
        let earOpen = me.lastPlayoutOpen
        var peak: Float = 0
        for k in 0..<blockN {
          mic[k] = src[i + k] + (earOpen ? coupling * farPlayed[k] : 0)
          peak = max(peak, abs(src[i + k]))
        }
        // Ground truth: was this person REALLY speaking in this block? Taken
        // from the clean recording before the room touched it, because the
        // whole point is to judge the machine against what was actually said.
        let spoke = peak > 0.02

        // ── SAMPLE BY SAMPLE, BECAUSE THAT IS WHAT THE PRODUCT DOES ──────────
        //
        // This fed ONE RMS per block. `noteFar` is a per-SAMPLE peak envelope
        // with a 35 ms release, fed from the render callback a sample at a time
        // -- and speech peaks run 3-6x its RMS, so the rig was handing the
        // classifier a far-end reference four times too small. Its echo bar
        // (`expected * effMargin`) was therefore four times too low, B's gate
        // called A's echo B's own voice, and B's cue claimed the floor through
        // the whole of A's turn: 35% of A silenced by a rig artefact that looked
        // exactly like a product defect. `fixture-is-not-the-real-shape`.
        for k in 0..<blockN { me.gate.noteFar(farPlayed[k]) }
        // The floor's fastest witness that the holder stopped is the far
        // stream going silent in this speaker, and a rig that never fed it
        // could not measure the release it drives -- it would sit inert and
        // read as "the fix does nothing". Same source and same threshold as
        // the render callback's `playoutRmsNow`.
        me.floor.notePlayout(live: rms(farPlayed) > Float(Audio.PLAYOUT_LIVE_RMS))
        me.floor.noteFar(farCue, transitMs: owdMs, voicing: farVoicing)
        me.gate.process(&mic, blockN)
        let d = me.floor.step(dt: Double(blockN) / SR,
                              near: Floor.Voice(rawValue: me.gate.vocal.rawValue) ?? .quiet)
        me.gate.floorMuted = floorOn && !d.mayTransmit && !d.duckOnly
        me.gate.floorDucked = floorOn && d.duckOnly
        me.gate.floorGranted = floorOn && !d.playoutOpen
        me.lastPlayoutOpen = !floorOn || d.playoutOpen
        // The other end's ground truth for THIS block, from their clean
        // recording -- the same source `spoke` comes from, so the two are
        // measured the same way.
        var farPeak: Float = 0
        let farSrc = me === a ? b.voice : a.voice
        for k in 0..<blockN { farPeak = max(farPeak, abs(farSrc[i + k])) }
        me.note(spoke: spoke, gain: me.gate.appliedGainNow, ms: dtMs,
                floorMine: me.floor.state == .mine, farSpoke: farPeak > 0.02)
        if ProcessInfo.processInfo.environment["TK_RIG_WHY"] != nil, me === b, spoke,
           farPeak <= 0.02, me.gate.appliedGainNow <= 0.05 {
          fputs("B held: \(me.floor.dbg) near=\(me.gate.vocal.rawValue)"
              + String(format: " gain=%.3f floorG=%.3f\n",
                       me.gate.appliedGainNow, me.gate.floorGainNow), stderr)
        }

        let slot = (blk + hop) % (hop + 1)
        if me === a {
          wireA[slot] = mic; cueA[slot] = Floor.Voice(rawValue: me.gate.vocal.rawValue) ?? .quiet
          vocA[slot] = me.gate.voicingNow
        } else {
          wireB[slot] = mic; cueB[slot] = Floor.Voice(rawValue: me.gate.vocal.rawValue) ?? .quiet
          vocB[slot] = me.gate.voicingNow
        }
      }
      i += blockN; blk += 1
    }
    return ((a.lostMs, a.speechMs, a.worstRunMs, a.duckedMs, a.onsetP50, a.onsetMax, a.onsetsLost,
             a.handoverP50, a.handoverMax, a.handoverN, a.handoversLost),
            (b.lostMs, b.speechMs, b.worstRunMs, b.duckedMs, b.onsetP50, b.onsetMax, b.onsetsLost,
             b.handoverP50, b.handoverMax, b.handoverN, b.handoversLost))
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
      // ── TWO FLOOR ARMS, BECAUSE THEY PROMISE DIFFERENT THINGS ──────────────
      //
      // `soft` (--floor-soft) ducks an out-of-turn voice to -20 dB, so it stays
      // audible and the "added loss" bar below is meaningful. `strict` -- what
      // ships since 0.95.0, by the user's decision -- SILENCES it: one mic at a
      // time, no duck. Under strict the added loss is not a defect, it is the
      // feature, and measuring strict against soft's bar is how this rig
      // started failing the moment strict shipped (it was not run; that is its
      // own lesson). So each arm is judged on what it claims, and the numbers
      // that mean the same thing in both -- the worst unbroken stretch, and how
      // fast a turn START is heard -- are the ones that gate the verdict.
      let soft = run(paths: paths, owdMs: owdMs, coupling: coupling, floorOn: true,
                     blockN: bn, turnS: turnS, overlapS: overlapS, strict: false)
      let on = run(paths: paths, owdMs: owdMs, coupling: coupling, floorOn: true,
                   blockN: bn, turnS: turnS, overlapS: overlapS, strict: true)
      // The pre-0.98.0 rule, kept as an arm: a voice still in its backchannel
      // phase could not take an empty floor, so under a silent strict idle the
      // first 700 ms of every sentence was dead air. This is the number the
      // user described as "a delay of one second deciding who is speaking".
      let old = run(paths: paths, owdMs: owdMs, coupling: coupling, floorOn: true,
                    blockN: bn, turnS: turnS, overlapS: overlapS, strict: true,
                    idleTakesAnyVoice: false)
      guard off.a.speech > 500 else {
        print("  no speech loaded from \(paths) -- rig cannot see anything"); return false
      }
      print("  --- block \(bn) samples ---")
      for (name, o, sf, f, ol) in [("A", off.a, soft.a, on.a, old.a),
                                   ("B", off.b, soft.b, on.b, old.b)] {
        print(String(format: "  floor off  %@  %7.0f ms  %7.0f ms  %7.0f ms  %7.0f ms",
                     name, o.speech, o.lost, o.worst, o.ducked))
        print(String(format: "  soft       %@  %7.0f ms  %7.0f ms  %7.0f ms  %7.0f ms",
                     name, sf.speech, sf.lost, sf.worst, sf.ducked))
        print(String(format: "  STRICT     %@  %7.0f ms  %7.0f ms  %7.0f ms  %7.0f ms",
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
        // SOFT's bar: it keeps an out-of-turn voice audible, so it may not eat
        // measurably more of somebody than no floor at all.
        let addedSoft = sf.lost - o.lost
        if addedSoft > o.speech * 0.05 {
          print(String(format: "  FAIL %@ the soft floor added %.0f ms of loss (>5%% of speech)",
                       name, addedSoft))
          ok = false
        }
        // STRICT's cost, stated rather than judged: this is speech during
        // somebody else's turn, and silencing it is the rule. Printed as a
        // share of the person so it can never quietly grow to swallow them --
        // past a third of somebody's speech the turn-taking is wrong even if
        // every other bar holds, because a conversation is not one monologue.
        let overlapCost = f.lost - o.lost
        print(String(format: "  strict silenced %@ for %.0f ms of out-of-turn speech (%.0f%% of them)",
                     name, overlapCost, 100 * overlapCost / max(1, o.speech)))
        if overlapCost > o.speech * 0.34 {
          print(String(format: "  FAIL %@ lost %.0f%% of their speech to the turn rule",
                       name, 100 * overlapCost / max(1, o.speech)))
          ok = false
        }
        // ── AND THE START OF A SENTENCE IS ITS OWN BAR ────────────────────────
        //
        // The two bars above are about TOTAL speech and the WORST stretch
        // anywhere. Neither could see 700 ms of dead air at the front of every
        // utterance -- the classifier needs `claimMs` to call a voice a bid,
        // and strict idle transmitted nothing until it did. That is the
        // "one second of latency deciding who is speaking" that was reported,
        // and it is the moment a conversation is won or lost, so it gets its
        // own number and its own bar.
        //
        // 150 ms: a human turn gap is 200 ms and this must sit inside one.
        print(String(format: "  onset->wire  %@  all: p50 %4.0f worst %4.0f (%d lost)"
                           + "   TAKING THE TURN (n=%d): p50 %4.0f worst %4.0f (%d lost)",
                     name, f.onsetP50, f.onsetMax, f.onsetsLost,
                     f.hN, f.hP50, f.hMax, f.hLost))
        print(String(format: "               old rule: all p50 %4.0f   TAKING THE TURN (n=%d):"
                           + " p50 %4.0f worst %4.0f (%d lost)",
                     ol.onsetP50, ol.hN, ol.hP50, ol.hMax, ol.hLost))
        // The arm has to be VISIBLY worse, or this rig cannot see the thing it
        // is claiming to have fixed and both numbers are noise.
        if ol.hP50 <= f.hP50, ol.hLost <= f.hLost {
          print(String(format: "  FAIL %@ the old rule measured no worse at a handover -- this"
                             + " rig cannot see the onset fix, so its numbers prove nothing", name))
          ok = false
        }
        // THE BAR, and it is on the handover: a human turn gap is ~200 ms and
        // being heard has to fit inside one.
        if f.hP50 > 150 {
          print(String(format: "  FAIL %@ taking the turn waited %.0f ms to be heard",
                       name, f.hP50))
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
