import Foundation

// ── WHOSE TURN IT IS ─────────────────────────────────────────────────────────
//
// The design is written out in `mac/FLOOR.md`. The short version, because a file
// that decides whether a person is audible should say what it believes at the
// top:
//
//   One microphone is live at a time, and that machine's speaker is not.
//
// `Audio.DuplexGate` answers a different question -- "is this microphone hearing
// more than the far end's echo can explain" -- and answers it per block, alone,
// with no idea what the other end decided. It is a good echo rule and it cannot
// be a turn rule, because at the instant of decision an interruption and an echo
// are the same signal. That is stated in Audio.swift and it was measured: being
// kinder to interruptions took suppression from 19.3 dB to 1.7.
//
// This file holds the TURN decision, which is a slower and more forgiving thing.
// It is fed scalars, it returns scalars, and it never touches a sample. Audio.swift
// applies what it says.
//
// ── THE INVARIANT, WHICH OUTRANKS THE RULE ───────────────────────────────────
//
// Audio.swift objects to exactly this design, in writing, and the objection is
// correct: two ends looking at each other through a hundred milliseconds can
// deadlock with BOTH microphones down. So:
//
//   The floor is a LEASE HELD BY A TRANSMITTER, never a permission required to
//   transmit. The state on missing information is OPEN.
//
// Nothing here may close a microphone because it is unsure, because a message did
// not arrive, or because a timer expired. Every timeout in this file opens.
// See `held-is-a-one-way-door` and `idle-signaling-socket-dies`: a recovery gate
// whose evidence stream can stop must survive its evidence stream stopping.
//
// ── NOT YET IN THE CALL PATH ─────────────────────────────────────────────────
//
// Nothing constructs this outside `Floor.selfTest`. It is proven before it is
// wired, deliberately -- but an unwired thing is not a shipped thing, and
// `feature-behind-a-flag-nobody-runs` is what happens when that is forgotten.
// The wiring is: Audio's block loop calls `step`, the cue path feeds `noteFar`,
// and `Predict.probability` feeds `noteEndProb`.
final class Floor {

  enum State: Int {
    /// Nobody holds it. BOTH ends may transmit on first voice, immediately,
    /// locally, with no round trip. Most turn changes happen through here and
    /// cost nothing at all -- which is why an ordinary pause is allowed to
    /// release the floor rather than hand it over.
    case idle = 0
    case mine = 1
    case theirs = 2
  }

  /// What an end publishes about its own voice. Deliberately the same three
  /// values `DuplexGate.Vocal` already produces, so there is one classifier in
  /// the product and not two -- `second-copy-of-a-rule`.
  enum Voice: Int {
    case quiet = 0
    /// "mm-hm". Produced without intent to take a turn, so it must NOT move the
    /// floor. It is drawn, not granted.
    case backchannel = 1
    /// Sustained. Somebody wants to say something.
    case claim = 2
  }

  struct Cfg {
    /// Far cue silence past which this end stops believing anything it was told
    /// and reverts to the purely local gate. OPENS. Never closes.
    var staleMs: Double = 1000
    /// Holder silent this long -> `idle`. The same 450 ms the gate already uses
    /// to end a vocalisation: 200-400 ms is a pause inside a sentence, past that
    /// the person has stopped.
    var releaseMs: Double = 450
    /// Both claiming for this long is a deadlock, not a conversation. Brief
    /// overlap is what talking SOUNDS like and nothing here touches it.
    var deadlockMs: Double = 450
    /// ── THE LONGEST ANYONE MAY BE HELD DOWN WHILE TALKING ────────────────────
    ///
    /// The first version of this file had no such bound and its own test printed
    /// the consequence: in a deadlock the end that loses the tiebreak was held
    /// down for 4530 ms of continuous speech. The tiebreak was working exactly as
    /// designed and the design was wrong -- an ordering that decides who speaks
    /// first must not also decide who speaks at all.
    ///
    /// So the lease has a hard ceiling. Past this, a person who is still talking
    /// gets the floor no matter what anybody believes about whose turn it is,
    /// because at that point the model is provably not describing the
    /// conversation in the room. It is the same reasoning as the yield being a
    /// 9 dB duck instead of a mute: a wrong decision must cost somebody a moment,
    /// never their sentence.
    var maxHeldDownMs: Double = 1500
    /// `Predict` above this, at a pause, pre-releases the floor to `idle` before
    /// the last word lands -- so the next person's first syllable costs nothing,
    /// because the decision was already made. This is the whole point of having
    /// a predictor and the largest win available in the turn layer.
    ///
    /// It may only ever PRE-RELEASE. A prediction is a prior, never a trigger,
    /// and nothing it says may be the sole reason a sample is turned down --
    /// which here is structural: releasing opens a microphone, it never closes
    /// one.
    var predictP: Double = 0.7
    /// How long the ear stays open after the floor leaves me. The far end's
    /// audio already in flight is their last half-word; closing my speaker the
    /// instant the floor flips chops it off. One hop, from TimeSync.
    var playoutLagMs: Double = 60
    var on = true
  }

  var cfg = Cfg()

  private(set) var state = State.idle
  /// Milliseconds since the far end last said anything about itself. Grows
  /// without bound while the channel is dead, which is what triggers the
  /// fallback.
  private(set) var farAgeMs: Double = 1e9
  private var farVoice = Voice.quiet
  /// How long the far end says IT has been quiet, on its own clock, as of the
  /// cue that carried it.
  private var farQuietMs: Double = 0
  /// How long the far end has been claiming, by its own report.
  private var farClaimMs: Double = 0
  private var nearClaimMs: Double = 0
  private var holderQuietMs: Double = 0
  /// Consecutive time this end has been talking while not allowed to transmit.
  private var heldDownMs: Double = 0
  private var endProb: Double = 0
  /// Milliseconds left on the ear-open hold after the floor arrived at me.
  private var playoutHold: Double = 0
  /// Last block's state, so the hold can be armed on the EDGE into `.mine`
  /// rather than re-armed every block while I hold -- which would hold the ear
  /// open for the whole turn and quietly delete the speaker half of the rule.
  private var wasState = State.idle

  /// ── THE TIEBREAK ──────────────────────────────────────────────────────────
  ///
  /// Set once, at call setup, from comparing the two peer ids. It has to be
  /// decided by something both ends compute the same way and neither end
  /// chooses, or a deadlock is broken by both sides yielding -- which is the
  /// silence this whole file exists to make impossible.
  var yieldsOnTie = false

  /// True when this machine's output is loudspeakers rather than an ear. The
  /// speaker half of the rule exists ONLY to kill an acoustic path; on
  /// headphones there is no path, so the holder keeps hearing everything and the
  /// call is fully duplex in the ear. Applying a route's property to a route
  /// that does not have it is `directional-property-measured-at-wrong-end`.
  var speakers = true

  struct Decision {
    /// Whether this end's captured audio goes on the wire. NOT whether the
    /// microphone is capturing -- capture never stops, so that a grant can be
    /// applied to audio that was already recorded and a handover need not happen
    /// before the words it carries.
    var mayTransmit: Bool
    /// Whether the far end's audio reaches this ear.
    var playoutOpen: Bool
    /// True when this end has stopped believing the far end and is running on
    /// the local gate alone. Reported, because an instrument that cannot see
    /// its own fallback reports the fallback as health.
    var fallback: Bool
    var state: State
  }

  /// One step. `dt` in seconds, `near` from this end's own classifier.
  @discardableResult
  func step(dt: Double, near: Voice) -> Decision {
    let ms = dt * 1000
    farAgeMs += ms
    playoutHold = max(0, playoutHold - ms)

    nearClaimMs = near == .claim ? nearClaimMs + ms : 0
    farClaimMs = farVoice == .claim ? farClaimMs + ms : 0

    // ── THE FALLBACK, FIRST, BECAUSE IT OUTRANKS EVERYTHING ─────────────────
    //
    // No word from the far end for a second: this end knows nothing about whose
    // turn it is, so it stops pretending to and hands the question back to the
    // local echo gate, which needs no agreement with anybody. `idle` is the
    // OPEN state -- reverting here can only ever open a microphone.
    let stale = farAgeMs > cfg.staleMs
    if !cfg.on || stale {
      state = .idle
      wasState = .idle
      nearClaimMs = 0; farClaimMs = 0; holderQuietMs = 0
      return Decision(mayTransmit: true, playoutOpen: true, fallback: true, state: .idle)
    }

    // ── THE HOLDER GOING QUIET RELEASES IT ───────────────────────────────────
    //
    // Not "hands it to the other person" -- releases it to nobody. The next
    // speaker takes it locally on their first block, with no round trip, and
    // that is how nearly every turn in a real conversation changes hands.
    // ── AND IT IS MEASURED ON THE HOLDER'S CLOCK, NOT ON MINE ────────────────
    //
    // This counted local time since the "I have stopped" cue ARRIVED, and the
    // sweep caught it: at 80 ms of one-way delay, ordinary clean alternation
    // failed -- the second person to speak was held back, at 40 ms they were
    // not, and nothing about the conversation had changed. A 450 ms release
    // measured from the arrival of stale news is really 450 ms PLUS A HOP, so
    // the rule got stricter the further apart two people were. That is a hidden
    // distance limit and this project has shipped four of them
    // (`rtt-blind-timeouts`); the fix is always the same, which is to take the
    // propagation back out.
    //
    // The far end already knows how long it has been quiet -- `DuplexGate`
    // tracks exactly that as `quietMsNow` -- so it says so, and this end adds
    // the age of the news. Distance cancels.
    let holderVoice: Voice = state == .mine ? near : (state == .theirs ? farVoice : .quiet)
    if state == .theirs {
      holderQuietMs = farVoice == .quiet ? farQuietMs + farAgeMs : 0
    } else {
      holderQuietMs = holderVoice == .quiet ? holderQuietMs + ms : 0
    }
    if state != .idle {
      // A prediction cannot take the floor from anybody. It can only let go of
      // it early, at a pause, on behalf of the person who already has it.
      let predictedEnd = state == .mine && endProb >= cfg.predictP && holderQuietMs > 0
      if holderQuietMs >= cfg.releaseMs || predictedEnd { state = .idle; holderQuietMs = 0 }
    }

    // ── TAKING IT ────────────────────────────────────────────────────────────
    //
    // From `idle`, either end takes it on voice. A backchannel does not: a
    // listening noise is produced without intent to take a turn, and granting
    // the floor to one would end the other person's sentence for saying "mm-hm".
    if state == .idle, near != .quiet, near != .backchannel {
      state = .mine
    } else if state == .idle, farVoice == .claim {
      state = .theirs
    }

    // ── AND TAKING IT FROM SOMEBODY ──────────────────────────────────────────
    //
    // A sustained bid over a holder is an interruption, and interruptions are
    // allowed -- that is a conversation. What is not allowed is the deadlock:
    // both of you going, neither backing off. Past `deadlockMs` one of you has
    // to give, and it is decided by an ordering neither end picked.
    let nearInsists = nearClaimMs >= cfg.deadlockMs
    let farInsists = farClaimMs >= cfg.deadlockMs
    if state == .theirs, nearInsists {
      // I take it, unless we are both insisting and the ordering says I am the
      // one who gives.
      if !(farInsists && yieldsOnTie) { state = .mine }
    } else if state == .mine, farInsists {
      if !nearInsists || yieldsOnTie { state = .theirs }
    }

    // ── AND THE CEILING, WHICH NO BELIEF SURVIVES ────────────────────────────
    //
    // Last, so it overrides every rule above it including the tiebreak. If this
    // end has been talking and held down for `maxHeldDownMs`, whatever this
    // machine thinks it knows about the far end is wrong, and it is wrong in the
    // one direction that costs a person their sentence.
    if state == .theirs, heldDownMs >= cfg.maxHeldDownMs { state = .idle }
    heldDownMs = state == .theirs && near == .claim ? heldDownMs + ms : 0

    // ── THE EAR ──────────────────────────────────────────────────────────────
    //
    // It closes only while I hold the floor AND the sound comes out of a
    // loudspeaker, because closing it is an ECHO measure and headphones have no
    // echo path.
    //
    // THE LAG IS ON THE CLOSING EDGE, which is the edge that can destroy
    // something. At the moment the floor becomes mine, the far end's last
    // half-word is already on the wire; it was spoken before anybody decided
    // anything and it has a hop still to travel. So the ear stays open one hop
    // INTO my turn and then closes. The opening edge takes no lag at all --
    // that direction restores hearing, and the rule everywhere in this app is
    // that the direction which restores something is never the slow one.
    if state == .mine, wasState != .mine { playoutHold = cfg.playoutLagMs }
    wasState = state
    let earClosed = state == .mine && speakers && playoutHold <= 0

    return Decision(mayTransmit: state != .theirs,
                    playoutOpen: !earClosed,
                    fallback: false, state: state)
  }

  /// The far end's cue arrived. `quietMs` is how long THEY say they have been
  /// silent, by their own clock, which is what makes the release distance-blind.
  /// Scalars only across the thread boundary -- `unexplained-death-is-a-bug`.
  /// `transitMs` is how long the cue spent in flight -- the measured one-way
  /// delay from `TimeSync`. It is NOT zero and assuming it was is what kept the
  /// distance limit alive through the first fix: news that has crossed the
  /// planet is already 120 ms old when it lands, and an age measured from
  /// ARRIVAL says it is brand new. The same mistake in a second place.
  func noteFar(_ v: Voice, quietMs: Double = 0, transitMs: Double = 0) {
    farVoice = v; farQuietMs = quietMs; farAgeMs = transitMs
  }
  /// `Predict.probability`, 0-1, that this end's current turn is ending.
  func noteEndProb(_ p: Double) { endProb = p }
}

// ── PROVING IT ───────────────────────────────────────────────────────────────
//
// Two floors, a real one-way delay between them, and a script of who is talking.
// The delay is the entire point: a symmetric rig with no delay cannot show any
// of the bugs this design can have, because every one of them is two ends
// disagreeing about the present.
//
// Run: `tk --floor-test`, and `tk --floor-test --floor-owd 100` for Delhi-NL.
extension Floor {

  /// One end's script: what its own classifier says, block by block.
  private struct Sim {
    var floor = Floor()
    var pending: [(due: Double, v: Voice, quietMs: Double)] = []
    /// This end's own quiet clock, which is what it publishes. The rig has to
    /// model it or it cannot see the distance fix at all.
    var quietMs: Double = 0
    /// Every block where this end was producing a claim and was NOT allowed to
    /// transmit. This is the number that matters -- it is speech that a listener
    /// would have to be given back out of the retroactive buffer, and past the
    /// buffer's length it is speech that is simply gone.
    var blockedMs: Double = 0
    var worstRunMs: Double = 0
    var runMs: Double = 0
    var earShutMs: Double = 0
  }

  static func selfTest(owdMs: Double = 40, verbose: Bool = true) -> Bool {
    var failures = 0
    func check(_ ok: Bool, _ what: String) {
      if !ok { failures += 1 }
      if verbose || !ok { print("  \(ok ? "ok  " : "FAIL") \(what)") }
    }

    let dt = 0.010

    /// Runs `seconds` of a scripted conversation and returns both ends' tallies.
    /// `voice(end, t)` gives what end 0 and end 1 are doing at time t.
    /// `deliver` false from `cutAt` onwards kills the cue channel.
    func run(seconds: Double,
             speakers: Bool = true,
             cutAt: Double = .infinity,
             voice: (Int, Double) -> Voice) -> (Sim, Sim) {
      var a = Sim(), b = Sim()
      // The ordering neither end chooses. Exactly one of them yields.
      a.floor.yieldsOnTie = true
      b.floor.yieldsOnTie = false
      a.floor.speakers = speakers; b.floor.speakers = speakers
      // Both ends start believing they have heard from the other, or the first
      // block is a fallback block for reasons that are an artefact of t=0.
      a.floor.noteFar(.quiet); b.floor.noteFar(.quiet)

      var t = 0.0
      while t < seconds {
        for i in 0..<2 {
          let mine = i == 0 ? a : b
          var me = mine
          // Deliver anything whose hop has landed.
          var still: [(due: Double, v: Voice, quietMs: Double)] = []
          for p in me.pending {
            if p.due <= t {
              me.floor.noteFar(p.v, quietMs: p.quietMs, transitMs: owdMs)
            } else { still.append(p) }
          }
          me.pending = still
          let v = voice(i, t)
          me.quietMs = v == .quiet ? me.quietMs + dt * 1000 : 0
          let d = me.floor.step(dt: dt, near: v)
          if v == .claim && !d.mayTransmit {
            me.blockedMs += dt * 1000
            me.runMs += dt * 1000
            me.worstRunMs = max(me.worstRunMs, me.runMs)
          } else {
            me.runMs = 0
          }
          if !d.playoutOpen { me.earShutMs += dt * 1000 }
          if i == 0 { a = me } else { b = me }
          // My cue crosses to the other end, one hop from now -- unless the
          // channel is cut.
          if t < cutAt {
            let hop = (due: t + owdMs / 1000, v: v, quietMs: me.quietMs)
            if i == 0 { b.pending.append(hop) } else { a.pending.append(hop) }
          }
        }
        t += dt
      }
      return (a, b)
    }

    print("FLOOR TEST  one-way delay \(Int(owdMs)) ms")

    // ── 1. ORDINARY ALTERNATION ──────────────────────────────────────────────
    // A talks 0-2 s, stops. B talks 2.5-4.5 s. Nobody is ever interrupted, and
    // nobody should ever be held back for a single block. This is the case that
    // is 95% of a conversation, and it must cost exactly nothing.
    let (a1, b1) = run(seconds: 5) { i, t in
      if i == 0 { return t < 2.0 ? .claim : .quiet }
      return (t >= 2.5 && t < 4.5) ? .claim : .quiet
    }
    check(a1.blockedMs == 0, "clean alternation: first speaker never held back")
    check(b1.blockedMs == 0, "clean alternation: second speaker never held back")

    // ── 2. A LISTENING NOISE DOES NOT TAKE THE FLOOR ─────────────────────────
    // B says "mm-hm" over A. A must not lose a single block: a person does not
    // surrender their sentence because the other person agreed with them.
    let (a2, _) = run(seconds: 4) { i, t in
      if i == 0 { return t < 3.0 ? .claim : .quiet }
      return (t >= 1.0 && t < 1.3) ? .backchannel : .quiet
    }
    check(a2.blockedMs == 0, "backchannel over a holder does not move the floor")

    // ── 3. A REAL INTERRUPTION IS ALLOWED ────────────────────────────────────
    // B starts talking over A and keeps going. B must get the floor, and the
    // wait must fit inside the retroactive buffer -- if it does, B loses nothing
    // at all, because the buffered onset goes out when the grant lands.
    let (_, b3) = run(seconds: 6) { i, t in
      if i == 0 { return t < 4.0 ? .claim : .quiet }
      return t >= 1.0 ? .claim : .quiet
    }
    check(b3.worstRunMs > 0, "interrupter is held at all (otherwise this proves nothing)")
    check(b3.worstRunMs <= 600,
          String(format: "interruption covered by the 600 ms buffer (worst %.0f ms)",
                 b3.worstRunMs))

    // ── 4. THE DEADLOCK RESOLVES, AND ONLY ONE WAY ───────────────────────────
    // Both start together and neither backs off. Exactly one must end up
    // speaking. The failure this guards is not "the wrong one won" -- it is BOTH
    // of them going quiet, which is the silence the whole design exists to make
    // impossible.
    let (a4, b4) = run(seconds: 6) { _, t in t >= 1.0 ? .claim : .quiet }
    check(min(a4.blockedMs, b4.blockedMs) == 0 || a4.blockedMs != b4.blockedMs,
          "deadlock is broken by the ordering, not by both yielding")
    // THE NUMBER THAT MATTERS IS THE RUN, NOT THE TOTAL. Somebody losing the
    // ordering is fine and it is the point; somebody losing it for five seconds
    // of unbroken speech is the failure, and the first version of this file did
    // exactly that while printing a pass.
    let worst4 = max(a4.worstRunMs, b4.worstRunMs)
    check(worst4 <= 1600,
          String(format: "nobody is held down past the ceiling in a deadlock "
                       + "(worst run %.0f ms)", worst4))

    // ── 5. THE CHANNEL DIES AND BOTH ENDS OPEN ───────────────────────────────
    // The invariant that outranks the rule. `held-is-a-one-way-door`.
    //
    // THIS TEST WAS VACUOUS AND PASSED ANYWAY. Cutting the channel before anyone
    // had the floor meant neither end was ever held down, so it reported "worst
    // 0 / 0 ms" -- the same output a genuinely fixed bug gives, from an
    // instrument that could not see the event. `blind-instruments-report-negatives`.
    //
    // So B takes the floor FIRST and is holding it when the channel dies, and
    // the ruler is calibrated against a control that must rank the other way:
    // with the channel alive, A is held down; with it dead, A is not.
    // `validate-the-ruler-against-known-inputs`.
    let script: (Int, Double) -> Voice = { i, t in
      if i == 1 { return t >= 0.2 ? .claim : .quiet }   // B holds from the start
      return t >= 2.0 ? .claim : .quiet                 // A starts talking at 2 s
    }
    let (aLive, _) = run(seconds: 8, voice: script)
    let (aDead, bDead) = run(seconds: 8, cutAt: 1.2, voice: script)
    check(aLive.worstRunMs > 300,
          String(format: "control: with the channel alive A IS held down (%.0f ms)",
                 aLive.worstRunMs))
    check(aDead.worstRunMs < aLive.worstRunMs,
          String(format: "dead cue channel opens the held-down mic (%.0f ms dead "
                       + "vs %.0f ms alive)", aDead.worstRunMs, aLive.worstRunMs))
    check(bDead.worstRunMs == 0, "dead cue channel never closes the other mic either")

    // ── 6. THE EAR ───────────────────────────────────────────────────────────
    // On loudspeakers the holder's ear closes -- that is the rule. On headphones
    // it must NEVER close, because closing it there buys nothing and costs the
    // person the whole other half of the call.
    let (a6s, _) = run(seconds: 4) { i, t in
      i == 0 && t < 3.0 ? .claim : .quiet
    }
    check(a6s.earShutMs > 1000,
          String(format: "on speakers the holder's ear closes (%.0f ms)", a6s.earShutMs))
    let (a6h, b6h) = run(seconds: 4, speakers: false) { i, t in
      i == 0 && t < 3.0 ? .claim : .quiet
    }
    check(a6h.earShutMs == 0 && b6h.earShutMs == 0,
          "on headphones no ear ever closes")

    print(failures == 0 ? "FLOOR TEST PASSED" : "FLOOR TEST FAILED (\(failures))")
    return failures == 0
  }
}
