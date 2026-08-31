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
    /// ── HOW LONG THE SPEAKER GOES ON BEING AN ECHO PATH ─────────────────────
    ///
    /// After the last far-end sample leaves the loudspeaker, the room it is in
    /// carries on returning it for a while, and the microphone is still hearing
    /// the tail. Opening the moment the level drops puts the last syllable of
    /// their sentence back on the wire. 150 ms is longer than a laptop's room
    /// tail and shorter than the gap between two people's turns.
    var playoutTailMs: Double = 150
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
  /// Milliseconds of loudspeaker tail still to run. See `notePlayout`.
  private(set) var playoutTail: Double = 0
  private var farVoice = Voice.quiet
  /// How long the far end has been quiet, on ITS clock: seeded to one transit
  /// when the first quiet cue lands, then counted here.
  private var farQuietMs: Double = 0
  private var farTransitMs: Double = 0
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
    /// ── WHAT "NOT YOUR TURN" DOES TO A MICROPHONE SOMEBODY IS TALKING INTO ────
    ///
    /// Not the same thing as to one they are not, and conflating the two was
    /// measured as a 35% regression on real conversation before this existed.
    ///
    ///   - The far end is talking and this person is NOT: mute, all the way.
    ///     Nothing is lost, because there is nothing there but the far end's own
    ///     voice coming back off this speaker. THIS is the echo case, and it is
    ///     the overwhelming majority of the time the floor is held elsewhere.
    ///
    ///   - This person IS talking and it is not their turn: DUCK. A mute here
    ///     costs somebody a word, and until the retroactive buffer exists there
    ///     is nothing to give it back with. Deep enough that the listener plainly
    ///     hears one voice, shallow enough that carrying on works.
    ///
    /// The rule the app is for -- one voice at a time -- is delivered by the
    /// first case, because the second one only happens during the half-second of
    /// genuine overlap at a handover, which is what conversation sounds like.
    var duckOnly: Bool
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
    playoutTail = max(0, playoutTail - ms)

    nearClaimMs = near == .claim ? nearClaimMs + ms : 0
    farClaimMs = farVoice == .claim ? farClaimMs + ms : 0
    if farVoice == .quiet { farQuietMs += ms }

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
      return Decision(mayTransmit: true, duckOnly: false, playoutOpen: true,
                      fallback: true, state: .idle)
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
      holderQuietMs = farVoice == .quiet ? farQuietMs : 0
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

    // ── AND THE STATE THIS RULE FORGOT ───────────────────────────────────────
    //
    // `idle` is nobody's turn, and it was reached by "the holder went quiet for
    // 450 ms" -- which is every pause between two sentences. In it, BOTH ends
    // may transmit and BOTH ears are open, so both microphones sit live next to
    // both loudspeakers. That is not a turn-taking state, it is a closed loop,
    // and a call spends about 40% of itself there.
    //
    // Measured on the call this was found in, with both ends on 0.89.0: the
    // floor muted one end for 22% of the call and the other for 38%, both
    // correct, and the echo still peaked at 0.81 and 0.72. The missing 40% is
    // this state.
    //
    // So in idle, a microphone next to a live loudspeaker does not transmit.
    // This is the SAME rule the design already states -- one voice at a time, so
    // nobody hears themselves -- applied to the case where the floor has no
    // opinion. It costs nothing in a conversation: the instant this end actually
    // speaks, `near` is no longer quiet, the block above has already moved the
    // state to `.mine`, and this guard does not apply. Barging in still works,
    // because the classifier reads the microphone BEFORE the gate mutes it.
    //
    // `speakers` because it is an echo measure and headphones have no echo path,
    // exactly like the ear above.
    // ── AND ONLY WHEN THIS END IS SAYING NOTHING ─────────────────────────────
    //
    // `near == .quiet` is not belt and braces, it is the difference between an
    // echo measure and a gag. Normally it is implied: idle plus a voice becomes
    // `.mine` in the block above, so the guard cannot reach anybody talking.
    // There is one path where it is NOT implied, and it is the one that matters
    // most -- the ceiling on line 288 releases a held-down speaker to `idle`
    // AFTER that block has run, precisely to give somebody their sentence back.
    // Without this term the guard took it away again, on exactly the complaint
    // this whole area exists to answer.
    //
    // A backchannel is left alone too. "mm-hm" is the thing the other person is
    // listening for, and it does not take the floor.
    let echoRisk = state == .idle && speakers && playoutTail > 0 && near == .quiet
    return Decision(mayTransmit: state != .theirs && !echoRisk,
                    duckOnly: state == .theirs && near != .quiet,
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
  ///
  /// ── AND THE FAR QUIET CLOCK IS DERIVED, NOT SENT ──────────────────────────
  ///
  /// The first version took the far end's own quiet duration as a parameter,
  /// which would have meant a new field on the wire. It does not need one. The
  /// moment their FIRST quiet cue lands, they have already been quiet for
  /// exactly one transit -- that is what it means for the news to have travelled
  /// -- and from there this end can simply count. Same distance-invariance, no
  /// protocol change, and nothing to negotiate with an older build.
  func noteFar(_ v: Voice, transitMs: Double = 0) {
    if v == .quiet, farVoice != .quiet { farQuietMs = transitMs }
    if v != .quiet { farQuietMs = 0 }
    farVoice = v
    farAgeMs = 0
    farTransitMs = transitMs
  }
  /// `Predict.probability`, 0-1, that this end's current turn is ending.
  func noteEndProb(_ p: Double) { endProb = p }

  /// ── IS THIS MACHINE'S LOUDSPEAKER LIVE RIGHT NOW? ─────────────────────────
  ///
  /// Not "does the far end hold the floor" -- that is a belief, and it is the
  /// belief that was wrong. This is the fact: sound is coming out of the speaker
  /// on this desk, so a microphone next to it is an echo path, whatever anybody
  /// thinks about whose turn it is. Fed from the render callback.
  func notePlayout(live: Bool) {
    if live { playoutTail = cfg.playoutTailMs }
  }
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
    var pending: [(due: Double, v: Voice)] = []
    /// Every block where this end was producing a claim and was NOT allowed to
    /// transmit. This is the number that matters -- it is speech that a listener
    /// would have to be given back out of the retroactive buffer, and past the
    /// buffer's length it is speech that is simply gone.
    var blockedMs: Double = 0
    var worstRunMs: Double = 0
    var runMs: Double = 0
    var earShutMs: Double = 0
  }

  /// ── THE ECHO STATE, ON ANSWERS ALREADY KNOWN ─────────────────────────────
  ///
  /// `idle` let both ends transmit with both loudspeakers live, and that is
  /// where the echo that survived four releases was living. Every row here is a
  /// case the shipped build got wrong or a case the fix must not break -- and
  /// the second kind outnumbers the first, because "never transmit" would pass
  /// a table of only the first.
  static func echoStateSelfTest() -> Bool {
    var ok = true
    func say(_ good: Bool, _ what: String) {
      if !good { ok = false }
      fputs("floor: \(good ? "OK  " : "FAIL") \(what)\n", stderr)
    }
    func fresh() -> Floor {
      let f = Floor()
      f.speakers = true
      f.noteFar(.quiet)                    // not stale, nobody talking
      _ = f.step(dt: 0.02, near: .quiet)
      return f
    }
    // 1. THE BUG: nobody's turn, my speaker is live, my mic must be shut.
    let a = fresh()
    a.notePlayout(live: true)
    let da = a.step(dt: 0.02, near: .quiet)
    say(da.state == .idle, "the pause after somebody speaks is idle, as before")
    say(!da.mayTransmit, "and a microphone next to a live loudspeaker does NOT transmit")
    say(da.playoutOpen, "while the ear stays open -- muting the mic is not going deaf")

    // 2. AND IT MUST LET GO. A tail that never expires is a mic that never opens.
    let b = fresh()
    b.notePlayout(live: true)
    _ = b.step(dt: 0.02, near: .quiet)
    var waited = 0.0
    while waited < 2.0, !b.step(dt: 0.02, near: .quiet).mayTransmit { waited += 0.02 }
    say(waited > 0.05 && waited < 0.5,
        "and it opens again \(Int(waited * 1000)) ms after the loudspeaker goes quiet")

    // 3. BARGING IN STILL WORKS. This is the one that matters: the complaint
    //    that started all of this was somebody being cut off mid-sentence.
    let c = fresh()
    c.notePlayout(live: true)
    _ = c.step(dt: 0.02, near: .quiet)
    let dc = c.step(dt: 0.02, near: .claim)
    say(dc.mayTransmit, "somebody who actually speaks transmits at once, live speaker or not")
    say(dc.state == .mine, "and the floor is theirs")

    // 3b. AND THE CEILING'S RESCUE MUST SURVIVE IT. Being held down too long
    //     while talking releases the floor to `idle` at the very END of step(),
    //     after the block that would have made it `.mine`. Without a `near`
    //     term the new guard re-muted exactly the person the ceiling had just
    //     rescued -- the complaint this whole area exists to answer.
    let c2 = Floor()
    c2.speakers = true
    // The tiebreak has to point AWAY from this end, or it simply wins the
    // deadlock at 450 ms and is never held down at all -- which is what the
    // first version of this row measured, and it reported a ceiling that had not
    // fired as a ceiling that does not exist.
    c2.yieldsOnTie = true
    var held = 0.0
    var lastRescue = Decision(mayTransmit: true, duckOnly: false, playoutOpen: true,
                              fallback: false, state: .idle)
    while held < 4.0 {
      c2.noteFar(.claim)                    // they hold it and will not stop
      c2.notePlayout(live: true)            // and their voice is coming out here
      lastRescue = c2.step(dt: 0.02, near: .claim)   // while this end is talking
      held += 0.02
      if lastRescue.state == .idle { break }         // the ceiling let go
    }
    say(lastRescue.state == .idle, "the ceiling releases a held-down speaker after \(Int(held * 1000)) ms")
    say(lastRescue.mayTransmit, "and they get their sentence back, live loudspeaker or not")

    // 4. HEADPHONES HAVE NO ECHO PATH, so none of this applies to them.
    let d = fresh()
    d.speakers = false
    d.notePlayout(live: true)
    say(d.step(dt: 0.02, near: .quiet).mayTransmit, "on headphones the mic is left alone")

    // 4b. A LISTENING NOISE IS WHAT THE OTHER PERSON IS LISTENING FOR.
    let bc = fresh()
    bc.notePlayout(live: true)
    _ = bc.step(dt: 0.02, near: .quiet)
    say(bc.step(dt: 0.02, near: .backchannel).mayTransmit,
        "an \"mm-hm\" over a live loudspeaker still reaches them")

    // 5. A SILENT LOUDSPEAKER IS NOT AN ECHO PATH.
    let e = fresh()
    say(e.step(dt: 0.02, near: .quiet).mayTransmit, "with nothing playing, idle transmits as before")

    // 6. AND THE FALLBACK STILL OUTRANKS EVERYTHING. No word from the far end
    //    means this end knows nothing, and reverting can only ever OPEN a mic.
    let f = Floor()
    f.speakers = true
    f.notePlayout(live: true)
    let df = f.step(dt: 2.0, near: .quiet)      // 2 s with no cue at all
    say(df.fallback && df.mayTransmit, "a stale far end still falls back to open, not shut")
    fputs("FLOOR ECHO CHECK: \(ok ? "PASS" : "FAIL")\n", stderr)
    return ok
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
          var still: [(due: Double, v: Voice)] = []
          for p in me.pending {
            if p.due <= t {
              me.floor.noteFar(p.v, transitMs: owdMs)
            } else { still.append(p) }
          }
          me.pending = still
          let v = voice(i, t)
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
            let hop = (due: t + owdMs / 1000, v: v)
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
