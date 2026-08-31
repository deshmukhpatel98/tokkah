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
// ── IN THE CALL PATH ─────────────────────────────────────────────────────────
//
// Audio's block loop calls `step`, the cue path feeds `noteFar`,
// `Predict.probability` feeds `noteEndProb`, and the far end's prior arrives
// next to the vocal byte as `noteFarEndProb`.
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
    /// ── THE SAME WAIT, WHEN SOMEBODY IS ALREADY TALKING INTO IT ─────────────
    ///
    /// 450 ms is the right answer to "has the holder finished?" asked in an
    /// empty room: it protects a thinking pause from being read as the end of a
    /// turn. It is the WRONG answer when the other person has already started
    /// speaking, because then the room is not empty and the cost of waiting is
    /// not caution -- it is dead air on somebody's live voice. Measured in
    /// `--turn-test` at 4 s turns with 0.3 s of overlap: the second speaker was
    /// silenced for 35% of everything they said, nearly all of it this wait,
    /// and reported by the user as "a delay of one second... latency in
    /// deciding who is speaking".
    ///
    /// 120 ms is longer than the gap between two syllables (a plosive closure
    /// is 30-80 ms) and far shorter than a turn gap, so it cannot be triggered
    /// by the holder drawing breath -- and if the holder was only pausing, they
    /// are still voicing, so they take the floor straight back from `idle` on
    /// their next block, with the contest below deciding it.
    ///
    /// Only ever SHORTENS a release, so like every other timeout in this file
    /// it can only open a microphone.
    var contendedReleaseMs: Double = 120
    /// ── THE FASTEST WITNESS THERE IS: THEIR OWN AUDIO ───────────────────────
    ///
    /// Every other way of learning that the holder has stopped costs a cue: the
    /// classification waits 450 ms before it will say `.quiet`, `ST_VOICING`
    /// waits 120 ms and then a transit. But this end is PLAYING their stream --
    /// silence in it is direct evidence, and its travel is already paid. No
    /// hangover, no second message, and no protocol at all, so it works
    /// against every build.
    ///
    /// 60 ms: longer than a plosive closure at the top of its range, shorter
    /// than any gap a person hears as a pause. It only counts while somebody at
    /// THIS end is already voicing, so the worst case is taking the floor from
    /// a holder who paused 60 ms mid-word while another person was talking --
    /// which is a contest, decided by the contest and the ceiling below exactly
    /// as it would have been.
    var playoutQuietMs: Double = 60
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
    /// ── STRICT: ONE MICROPHONE, ONE LOUDSPEAKER, NEVER THE SAME END ─────────
    ///
    /// The user's decision, 2026-08-31, in their words: "only one mic is
    /// enabled at any given moment in time, and only one speaker is enabled,
    /// and it can't be the same person's." Three soft edges go:
    ///
    ///   - the -20 dB out-of-turn duck: out of turn is SILENT, full stop.
    ///     Barging in still works -- the claim crosses as a CUE and flips the
    ///     floor -- but until it flips, the interrupter is not heard.
    ///   - `idle` as an open state: nobody transmits in a pause. The first
    ///     voice takes the floor LOCALLY, same block, so it still costs the
    ///     first speaker nothing.
    ///   - the stale-cue fallback opening both ends: roles HOLD when the far
    ///     end goes dark. The holder keeps the floor on its own evidence; the
    ///     listener's escape is that a blind holder reads as quiet, releases
    ///     in `releaseMs`, and the listener takes an empty floor.
    ///
    /// What strict cannot remove is the speed of light: two people who start
    /// inside one hop of each other both take an empty floor, and the deadlock
    /// break then silences exactly one. So "one mic" holds everywhere except a
    /// window bounded by `deadlockMs` plus a hop around a genuinely
    /// simultaneous start -- counted on every call as `strict_overlap_pct`.
    /// `--floor-soft` is the control arm (0.94.0 behaviour).
    var strict = true
    /// ── HOW LONG IT TAKES TO INTERRUPT, AND WHY IT WAS A SECOND ────────────
    ///
    /// Measured on a 333 s two-person call (2p183qa061zcu / 2adf00o87punm,
    /// 0.98.0): 140 collisions, and **50 whole utterances that never reached
    /// the wire at all** -- p50 onset-to-wire 0 ms, so every utterance was
    /// either instant or entirely deleted. Reported as "it is still cutting
    /// people in between and words are dropping while they speak".
    ///
    /// The arithmetic behind that second: taking the floor from a holder
    /// required `nearClaimMs >= deadlockMs` (450 ms) -- and `nearClaimMs` only
    /// starts counting when the classifier promotes a voice to `.claim`, which
    /// takes `claimMs` (700 ms) of sustained sound. So an interruption cost
    /// **1150 ms** before it was formally allowed, and in strict every one of
    /// those milliseconds is silence rather than a duck. Any interjection
    /// shorter than that was not delayed, it was deleted.
    ///
    /// Two constants, and they work as a pair:
    ///
    ///   `strictDeadlockMs` -- the contest runs on ANY near voice from its
    ///   first block (see `nearVoiceMs`), not on the 700 ms-old `.claim`
    ///   promotion, and it is 180 ms rather than 450. 180 ms is longer than a
    ///   cough or a keystroke and shorter than the first syllable of a word.
    ///
    ///   `onsetGraceMs` -- and until that contest resolves the voice is
    ///   AUDIBLE, so the 180 ms is not lost either. This is the piece that
    ///   could not exist before 0.94.0: opening a microphone on "any near
    ///   voice" over a live loudspeaker used to mean opening it on this
    ///   machine's own echo, and the correlation veto is what finally tells
    ///   those two apart (a vetoed block is classified `.quiet`, so it can
    ///   never reach the grace window at all).
    ///
    /// Net: you start talking, you are heard from the first block, and 180 ms
    /// later you formally hold the floor -- or, if it was an "mm-hm", you stop
    /// and it returns to them with nothing lost either way. The cost is a
    /// bounded genuine overlap, which is what a conversation sounds like, and
    /// it is counted (`strict_overlap_pct`).
    var strictDeadlockMs: Double = 180
    var onsetGraceMs: Double = 400
    /// The contest when a camera has confirmed the voice -- see
    /// `nearVisualVoice`. 80 ms is two 40 ms syllable-scale samples of visual
    /// motion plus audio energy in the same window; below that the two signals
    /// are not independent of each other's jitter.
    var visualDeadlockMs: Double = 80
    /// ── THE CONTROL ARM FOR "ANY VOICE TAKES AN EMPTY FLOOR" ────────────────
    ///
    /// False restores the pre-0.98.0 rule, where a vocalisation still in its
    /// backchannel phase could not take `idle` -- which under a silent strict
    /// idle meant the first `claimMs` (700 ms) of every sentence was dead air.
    /// Kept as a real switch, not a comment, because "we made it faster" is
    /// worth nothing without the arm that shows how much
    /// (`--turn-test` prints both).
    var idleTakesAnyVoice = true
  }

  var cfg = Cfg()

  private(set) var state = State.idle
  /// Milliseconds since the far end last said anything about itself. Grows
  /// without bound while the channel is dead, which is what triggers the
  /// fallback.
  private(set) var farAgeMs: Double = 1e9
  /// Milliseconds of loudspeaker tail still to run. See `notePlayout`.
  private(set) var playoutTail: Double = 0
  /// How long the far end's stream has been silent at this speaker, and
  /// whether it was EVER heard. `playoutHeard` is the guard that keeps a
  /// call which has not started -- or one whose audio never arrives -- from
  /// reading as a holder who has politely stopped
  /// (`blind-instruments-report-negatives`).
  private var playoutSilentMs: Double = 0
  private var playoutHeard = false
  private var playoutLiveNow = false
  /// Turns this end let go of early because its own sentence was ending, and the
  /// milliseconds of the 450 ms silence rule that saved. `predictedReleases` is
  /// both halves; `farPredictedReleases` is only the half that arrived on the
  /// wire -- a total that cannot name which side fired is how 0.92.0 would have
  /// hidden a protocol that never landed.
  private(set) var predictedReleases = 0
  private(set) var predictedSavedMs: Double = 0
  private(set) var farPredictedReleases = 0
  private(set) var farPredictedSavedMs: Double = 0
  /// Peak of the far end's prior over the call. Zero against an older build, and
  /// zero on a 0.93 call where they talked is the protocol not arriving -- those
  /// two look the same if you only count releases.
  private(set) var farEndProbPeak: Double = 0
  /// Blocks the idle echo guard muted, and blocks where it COULD have (idle, on
  /// speakers). The second is the denominator: a count with nothing to divide by
  /// says nothing about a call's length.
  private(set) var echoGuardBlocks = 0
  private(set) var guardableBlocks = 0
  /// Rig-only window into the release decision. Never read in production.
  var dbg: String {
    String(format: "st=%d hq=%.0f pq=%.0f fv=%d fk=%d fsil=%.0f",
           state.rawValue, holderQuietMs, playoutSilentMs,
           farVoicing ? 1 : 0, farVoicingKnown ? 1 : 0, farSilentMs)
  }
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
  /// Their prior, last heard. Written by the receive thread, read here.
  private var farEndProb: Double = 0
  /// p has been below the threshold during the current hold. A leftover 0.9
  /// from the previous sentence must not release the first word of this one.
  private var farPredArmed = false
  /// ── THE CONTEST CLOCK RUNS ON VOICE, NOT ON A 700 ms-OLD VERDICT ─────────
  ///
  /// `nearClaimMs`/`farClaimMs` count only `.claim`, which the classifier
  /// cannot say until 700 ms of sound. These count ANY voice from its first
  /// block, which is what "somebody is talking over the holder" actually is.
  private var nearVoiceMs: Double = 0
  private var farVoiceMs: Double = 0
  /// Blocks the onset grace window kept a real voice audible over a holder,
  /// and utterances that used it -- the interjections that 0.98.0 deleted.
  private(set) var graceBlocks = 0
  private(set) var graceOnsets = 0
  /// Floors taken by the fast strict contest rather than the 1150 ms one.
  private(set) var fastTakes = 0
  private var inGrace = false
  /// The far end's fast voicing bit, and how long it has said "no sound" for.
  /// `farVoicingKnown` stays false against a build that cannot say, which is
  /// what keeps this from reading silence into every older peer.
  private var farVoicing = false
  private var farVoicingKnown = false
  private var farSilentMs: Double = 0
  /// We pre-released THEIR hold because they said it was ending. They must not
  /// take it back on the same claim that was wrapping up -- without this, the
  /// next line of `step` would see `farVoice == .claim` and undo the release
  /// in the same block.
  private var farWrapping = false
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
  /// ── A CAMERA SAYS THIS PERSON IS TALKING (0.100.0) ──────────────────────────
  ///
  /// Fed from `Mouth`, and true only when a face is actually visible and its
  /// mouth is moving the way speech moves it. False covers both "sitting
  /// quietly" and "cannot see", which is safe HERE and only here, because the
  /// single thing this is allowed to do is shorten the contest -- so its
  /// absence restores 0.99.0 exactly rather than closing anything.
  var nearVisualVoice = false
  /// Floors won early because a camera confirmed the voice.
  private(set) var visualTakes = 0

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
    // Any voice, from its first block. A backchannel counts: at the moment
    // somebody starts making sound over a holder, nothing on earth knows yet
    // whether it will turn into a word, and waiting to find out is the delay.
    nearVoiceMs = near != .quiet ? nearVoiceMs + ms : 0
    farVoiceMs = farVoice != .quiet ? farVoiceMs + ms : 0
    if farVoice == .quiet { farQuietMs += ms }
    if farVoicingKnown, !farVoicing { farSilentMs += ms }
    // From the FIRST block their stream is quiet, not from the end of the
    // 150 ms echo tail: `playoutTail` answers "could this speaker still be
    // feeding the microphone", which is a different question with a
    // deliberately longer answer.
    if playoutHeard, !playoutLiveNow { playoutSilentMs += ms }

    // ── THE FALLBACK, FIRST, BECAUSE IT OUTRANKS EVERYTHING ─────────────────
    //
    // No word from the far end for a second: this end knows nothing about whose
    // turn it is, so it stops pretending to and hands the question back to the
    // local echo gate, which needs no agreement with anybody. `idle` is the
    // OPEN state -- reverting here can only ever open a microphone.
    let stale = farAgeMs > cfg.staleMs
    if !cfg.on || (stale && !cfg.strict) {
      state = .idle
      wasState = .idle
      nearClaimMs = 0; farClaimMs = 0; holderQuietMs = 0
      return Decision(mayTransmit: true, duckOnly: false, playoutOpen: true,
                      fallback: true, state: .idle)
    }
    // ── STRICT AND BLIND: ROLES HOLD, NOTHING OPENS ──────────────────────────
    //
    // Opening both microphones is the one thing strict exists to never do, so
    // a dead cue channel cannot do it either. The far end's last word is
    // treated as quiet -- a frozen `.claim` must not keep insisting on behalf
    // of a peer that may be gone -- and the ordinary machinery does the rest:
    // a blind holder reads as quiet, releases in `releaseMs`, and this end
    // takes an empty floor the moment it speaks. A holder needs no far
    // evidence to keep talking, so both-muted cannot stick either.
    // Reported as fallback, because "running without far evidence" is what
    // that field has always meant.
    let farBlind = stale && cfg.strict
    if farBlind { farVoice = .quiet }

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
      // Their fast bit when they send one, their classification when they do
      // not. The bit is the SAME fact measured without the 450 ms hangover, so
      // a holder who has genuinely stopped is quiet here within a hop plus
      // 120 ms instead of within a hop plus 570.
      // Two independent witnesses that the holder stopped, and the more
      // responsive one wins: their cue (a classification, or the faster
      // `ST_VOICING` bit) and their own audio going silent in this speaker.
      // The audio needs no protocol and carries no hangover, so on a healthy
      // call it is normally the one that answers first.
      let byCue = farVoicingKnown ? (farVoicing ? 0 : farSilentMs)
                                  : (farVoice == .quiet ? farQuietMs : 0)
      holderQuietMs = max(byCue, playoutSilentMs)
    } else {
      holderQuietMs = holderVoice == .quiet ? holderQuietMs + ms : 0
    }
    // A p below threshold while they hold means a later rise is this sentence
    // wrapping up, not a leftover from the last one. Armed once per hold.
    if state == .theirs, farEndProb < cfg.predictP { farPredArmed = true }

    if state != .idle {
      // A prediction cannot take the floor from anybody. It can only let go of
      // it early, on behalf of the person who already has it.
      let localPred = state == .mine && endProb >= cfg.predictP && holderQuietMs > 0
      // ── THE FAR HALF ─────────────────────────────────────────────────────
      //
      // 0.92.0 wired the local half: my transcript releases MY turn early, at a
      // pause. The bigger win is the other way -- they tell us THEIR turn is
      // ending, so this microphone is already open before their last word
      // lands. Two ways, both only ever PRE-RELEASE:
      //
      //   a pause, same as local: skip the remaining 450 ms
      //   they are still claiming, but p rose during this hold: release now
      //
      // A leftover high p at the START of their turn does not fire, because
      // farPredArmed is false until p has been below the threshold on this hold.
      // That is the case `predictFarSelfTest` requires to FAIL when the arming
      // is removed -- a stale 0.9 would otherwise steal the first word of every
      // sentence.
      let farPause = state == .theirs && farEndProb >= cfg.predictP && holderQuietMs > 0
      let farEarly = state == .theirs && farPredArmed && farEndProb >= cfg.predictP
      let predictedEnd = localPred || farPause || farEarly
      // ── HOW LONG THIS RELEASE IS ALLOWED TO TAKE ─────────────────────────
      //
      // Contended when the end that does NOT hold the floor is voicing: they
      // are waiting on this release, and every millisecond of it is silence
      // over a live voice. A backchannel counts -- "mm-hm" into a pause is
      // still somebody making sound, and releasing to `idle` does not grant
      // them anything (the contest below needs a voice, and `farWrapping`
      // stops a wrapping claim taking it straight back).
      let contended = state == .theirs ? near != .quiet
                                       : (farVoicingKnown ? farVoicing : farVoice != .quiet)
      // ── AND THE SAME SILENCE IS NOT CHARGED FOR TWICE ────────────────────
      //
      // `ST_VOICING` only goes false after 120 ms of no sound at the holder's
      // own microphone, and that report is already a transit old when it
      // lands. So for a peer that sends the bit, the "has the holder really
      // stopped" question has ALREADY been answered before this clock starts,
      // and adding `contendedReleaseMs` on top measured as 313 ms at a
      // handover in `--turn-test` -- most of it a second waiting period for a
      // silence that was proven the first time. When somebody is voicing into
      // that gap, release on the news itself.
      //
      // Against a peer that cannot say (`farVoicingKnown` false) the clock is
      // running on the CLASSIFICATION, which outlives the sound rather than
      // proving its absence, so the 120 ms filter is still needed there.
      // Their audio going quiet is already a 60 ms observation by the time it
      // counts, so like the voicing bit it must not be charged for twice.
      let proven = (farVoicingKnown && !farVoicing) || playoutSilentMs >= cfg.playoutQuietMs
      let contendedWait = proven && state == .theirs ? 0 : cfg.contendedReleaseMs
      let waitMs = contended ? min(contendedWait, cfg.releaseMs) : cfg.releaseMs
      if holderQuietMs >= waitMs || predictedEnd {
        // Counted, because "the predictor is wired" and "the predictor fires"
        // are two claims and only the second one is worth anything. This is the
        // number that says how much of the 450 ms wait it is actually saving.
        if predictedEnd {
          predictedReleases += 1
          predictedSavedMs += max(0, cfg.releaseMs - holderQuietMs)
          if state == .theirs {
            farPredictedReleases += 1
            farPredictedSavedMs += max(0, cfg.releaseMs - holderQuietMs)
            farWrapping = true
            // ── ONCE PER HOLD, WHICH IS WHAT THE COMMENT ALWAYS CLAIMED ────
            //
            // `farPredArmed` was set whenever p dipped below the threshold and
            // never cleared when it fired, so every block with p above it
            // fired AGAIN. Measured on one 333 s call: 6838 far releases and a
            // reported saving of 2,623,182 ms -- 20 releases a second, and
            // 7.9x the length of the call "saved". A number that large is not
            // a win, it is a counter describing a state machine thrashing
            // between `theirs` and `idle` twenty times a second, which is
            // exactly what the other end recorded as 241 choppy gate flaps.
            // Disarmed here: p must dip below the threshold again -- a real
            // new wrap-up -- before this can fire once more.
            farPredArmed = false
          }
        }
        state = .idle; holderQuietMs = 0
      }
    }

    if state != .theirs { farPredArmed = false }
    if farVoice == .quiet || farEndProb < cfg.predictP { farWrapping = false }

    // ── TAKING IT ────────────────────────────────────────────────────────────
    //
    // From `idle`, either end takes it on voice. A backchannel does not: a
    // listening noise is produced without intent to take a turn, and granting
    // the floor to one would end the other person's sentence for saying "mm-hm".
    // `farWrapping`: they told us this claim is ending, so it must not take the
    // floor back in the same block the release ran.
    // ── STRICT: THE FIRST BLOCK OF ANY VOICE TAKES AN EMPTY FLOOR ────────────
    //
    // Every vocalisation begins life as a continuer -- the classifier cannot
    // tell "mm-hm" from a sentence for `claimMs` (700 ms). "A backchannel does
    // not take the floor" was written when idle TRANSMITTED, where it protected
    // a HOLDER from being dethroned by a listening noise -- and it still does:
    // the contest below requires a claim, unchanged. But strict idle is silent,
    // so in strict the old rule silenced the first 700 ms of every sentence --
    // measured 14:22 as both ends floor-muted 63%/71% of a two-person call, and
    // heard as "a second of latency deciding who is speaking". From idle there
    // is nobody to protect: take it, speak, and if it really was an "mm-hm"
    // the ordinary release returns the floor within releaseMs.
    if state == .idle, near != .quiet,
       ((cfg.strict && cfg.idleTakesAnyVoice) || near != .backchannel) {
      state = .mine
    } else if state == .idle, farVoice != .quiet,
              (farVoice == .claim || (cfg.strict && cfg.idleTakesAnyVoice)), !farWrapping {
      // The mirror, for the same reason: their first block took THEIR empty
      // floor, their audio is already on the wire, and an end that waited for
      // their cue to say `claim` sat with its ear open and its state idle for
      // 700 ms -- which is where a second speaker collides with them.
      state = .theirs
    }

    // ── AND TAKING IT FROM SOMEBODY ──────────────────────────────────────────
    //
    // A sustained bid over a holder is an interruption, and interruptions are
    // allowed -- that is a conversation. What is not allowed is the deadlock:
    // both of you going, neither backing off. Past `deadlockMs` one of you has
    // to give, and it is decided by an ordering neither end picked.
    // ── AND IN STRICT IT RUNS ON THE VOICE, AT 180 ms ───────────────────────
    //
    // `nearClaimMs` cannot start until the classifier has heard 700 ms of
    // sound, so this contest used to open 700 ms after somebody began talking
    // and then take another 450 -- see `strictDeadlockMs`. On the voice clock
    // instead, and shorter, because in strict the waiting is not a duck, it is
    // deletion. Soft keeps the old pair exactly.
    // ── AND THE CONTEST IS SHORTER WHEN A CAMERA AGREES ─────────────────────
    //
    // 180 ms of audio is how long it takes to be reasonably sure a sound is a
    // person rather than a cough, a keystroke or an echo. A visible mouth
    // moving in time with it is independent evidence of the same thing, and two
    // independent signals need less of each. So a confirmed voice takes the
    // floor in `visualDeadlockMs`.
    //
    // Only ever SHORTER, never longer, and only when a face is genuinely
    // visible: a blind detector leaves this at 180 ms, which is 0.99.0.
    let visualNow = cfg.strict && nearVisualVoice
    let contestMs = cfg.strict
      ? (visualNow ? min(cfg.visualDeadlockMs, cfg.strictDeadlockMs) : cfg.strictDeadlockMs)
      : cfg.deadlockMs
    let nearInsists = cfg.strict ? nearVoiceMs >= contestMs : nearClaimMs >= contestMs
    let farInsists = cfg.strict ? farVoiceMs >= contestMs : farClaimMs >= contestMs
    let wasTheirs = state == .theirs
    if state == .theirs, nearInsists {
      // I take it, unless we are both insisting and the ordering says I am the
      // one who gives.
      if !(farInsists && yieldsOnTie) { state = .mine }
    } else if state == .mine, farInsists {
      if !nearInsists || yieldsOnTie { state = .theirs }
    }
    if cfg.strict, wasTheirs, state == .mine {
      fastTakes += 1
      if visualNow { visualTakes += 1 }
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
    // COUNTED, because this is the fix under test and the whole call is about
    // whether it fires. Without a counter the only evidence would be the echo
    // number going down, and "it fired and did not help" and "it never fired"
    // would look identical -- which is how the last two echo theories survived.
    if echoRisk { echoGuardBlocks += 1 }
    guardableBlocks += state == .idle && speakers ? 1 : 0
    // ── STRICT: THE SAME STATE, A HARDER ANSWER ──────────────────────────────
    //
    // Everything above -- who holds, who releases, who wins a deadlock, the
    // predictor, the ceiling -- is unchanged. Strict only maps the verdict:
    // the microphone is on the wire ONLY while the floor is mine, out of turn
    // is silent rather than ducked, idle transmits nothing, and my ear closes
    // whenever I hold, on every output route -- the rule is a product
    // statement now, not an echo measure, and with the far microphone muted
    // there is nothing for a talker's speaker to carry anyway. The closing
    // edge keeps its one-hop lag so their last half-word still lands.
    if cfg.strict {
      // ── THE ONSET GRACE: AN INTERJECTION IS DELAYED, NEVER DELETED ────────
      //
      // The contest above needs `strictDeadlockMs` to resolve. Those 180 ms
      // are the first syllable of whatever this person just started saying,
      // and strict has no duck to fall back on -- so they are audible while it
      // resolves. Bounded by `onsetGraceMs` so a person talking straight
      // through somebody else's turn is not simply granted a parallel channel:
      // past the window, if the contest did not hand them the floor, they are
      // held like before.
      //
      // `near != .quiet` is doing the safety work, and it is stronger than it
      // looks: a block the echo veto has claimed is classified `.quiet`, so
      // this end's own loudspeaker can never open this window. That is the
      // whole reason this is safe in 0.99.0 and would not have been in 0.93.
      let grace = state == .theirs && near != .quiet && nearVoiceMs <= cfg.onsetGraceMs
      if grace {
        graceBlocks += 1
        if !inGrace { inGrace = true; graceOnsets += 1 }
      } else if state != .theirs || near == .quiet {
        inGrace = false
      }
      return Decision(mayTransmit: state == .mine || grace,
                      duckOnly: false,
                      playoutOpen: !(state == .mine && playoutHold <= 0),
                      fallback: farBlind, state: state)
    }
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
  func noteFar(_ v: Voice, transitMs: Double = 0, voicing: Bool? = nil) {
    if v == .quiet, farVoice != .quiet { farQuietMs = transitMs }
    if v != .quiet { farQuietMs = 0 }
    farVoice = v
    farAgeMs = 0
    farTransitMs = transitMs
    // ── AND THE FAST ANSWER, WHEN THEY CAN GIVE ONE ──────────────────────────
    //
    // `Wire.ST_VOICING`: sound leaving their microphone in the last 120 ms, as
    // opposed to `v`, which is a classification that outlives the sound by
    // 450 ms. The release clock below runs on THIS when it is available,
    // seeded to one transit exactly like `farQuietMs` -- the news is already
    // that old when it lands, and assuming otherwise is the distance limit
    // this project has shipped six times.
    //
    // nil means they cannot say (an older build): the clock is left alone and
    // the claim-based release is unchanged.
    if let voicing {
      farVoicingKnown = true
      if voicing { farSilentMs = 0 }
      else if farVoicing { farSilentMs = transitMs }
      farVoicing = voicing
    }
  }
  /// `Predict.probability`, 0-1, that this end's current turn is ending.
  func noteEndProb(_ p: Double) { endProb = p }
  /// The FAR end's prior, 0-1, from the byte beside the vocal status. Zero is
  /// what an older build sends (the pad), and zero is the value that changes
  /// nothing -- so a mixed-version call behaves as 0.92.0.
  func noteFarEndProb(_ p: Double) {
    farEndProb = p
    if p > farEndProbPeak { farEndProbPeak = p }
  }

  /// ── IS THIS MACHINE'S LOUDSPEAKER LIVE RIGHT NOW? ─────────────────────────
  ///
  /// Not "does the far end hold the floor" -- that is a belief, and it is the
  /// belief that was wrong. This is the fact: sound is coming out of the speaker
  /// on this desk, so a microphone next to it is an echo path, whatever anybody
  /// thinks about whose turn it is. Fed from the render callback.
  func notePlayout(live: Bool) {
    playoutLiveNow = live
    if live { playoutTail = cfg.playoutTailMs; playoutSilentMs = 0; playoutHeard = true }
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
      // This suite proves the SOFT arm (`--floor-soft`, the 0.94.0 rules).
      // The shipping default is strict, proven by `strictSelfTest`.
      f.cfg.strict = false
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
    c2.cfg.strict = false
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
    f.cfg.strict = false
    f.speakers = true
    f.notePlayout(live: true)
    let df = f.step(dt: 2.0, near: .quiet)      // 2 s with no cue at all
    say(df.fallback && df.mayTransmit, "a stale far end still falls back to open, not shut")
    fputs("FLOOR ECHO CHECK: \(ok ? "PASS" : "FAIL")\n", stderr)
    return ok
  }

  /// ── THE FAR-END PRIOR, ON ANSWERS ALREADY KNOWN ───────────────────────────
  ///
  /// 0.92.0 wired the local half. This is the other half: their number arrives
  /// beside the vocal byte, and this microphone is open before they finish.
  /// Every row that asserts a win has a twin that must FAIL when the prior is
  /// left at 0 -- otherwise a test that cannot see the protocol reports PASS
  /// on a build where the byte never moved.
  static func predictFarSelfTest() -> Bool {
    var ok = true
    func say(_ good: Bool, _ what: String) {
      if !good { ok = false }
      fputs("floor: \(good ? "OK  " : "FAIL") \(what)\n", stderr)
    }
    func heldByThem() -> Floor {
      let f = Floor()
      // Soft arm, like echoStateSelfTest: the release/prior machinery under
      // test is IDENTICAL in strict, but the open-idle assertions are not.
      f.cfg.strict = false
      f.speakers = true
      f.noteFar(.quiet)
      _ = f.step(dt: 0.02, near: .quiet)
      f.noteFar(.claim)
      _ = f.step(dt: 0.02, near: .quiet)
      return f
    }

    // CONTROL: they hold, no prior, I start talking. I am held. Without this
    // row the tests below would pass on a floor that never mutes anyone.
    let ctrl = heldByThem()
    var blocked = 0.0
    for _ in 0..<30 {
      if !ctrl.step(dt: 0.02, near: .claim).mayTransmit { blocked += 20 }
    }
    say(blocked > 300,
        "CONTROL: with no prediction, barging in is held (\(Int(blocked)) ms)")

    // 1. They hold, p goes 0.3 then 0.9 while they still claim. Floor goes idle.
    let a = heldByThem()
    a.noteFarEndProb(0.3)
    _ = a.step(dt: 0.02, near: .quiet)          // arm
    a.noteFarEndProb(0.9)
    let da = a.step(dt: 0.02, near: .quiet)
    say(da.state == .idle,
        "far-end prior at 0.9 releases their hold while they still claim")
    say(a.farPredictedReleases == 1,
        "and it is counted as a far release, not only a local one")

    // 2. This microphone transmits on the first block of my voice.
    let db = a.step(dt: 0.02, near: .claim)
    say(db.state == .mine && db.mayTransmit,
        "so this microphone transmits on the first block")

    // 3. REJECT: the same barge-in with p=0 is still held.
    let c = heldByThem()
    c.noteFarEndProb(0)
    _ = c.step(dt: 0.02, near: .quiet)
    c.noteFarEndProb(0)
    _ = c.step(dt: 0.02, near: .quiet)
    let dc = c.step(dt: 0.02, near: .claim)
    say(dc.state == .theirs && !dc.mayTransmit,
        "REJECT: the same barge-in with p=0 is still held — otherwise this proves nothing")

    // 4. A leftover 0.9 at the START of their turn does not release.
    let d = Floor()
    d.cfg.strict = false
    d.speakers = true
    d.noteFar(.quiet)
    _ = d.step(dt: 0.02, near: .quiet)
    d.noteFarEndProb(0.9)
    d.noteFar(.claim)
    let dd = d.step(dt: 0.02, near: .quiet)
    say(dd.state == .theirs,
        "a leftover 0.9 at the START of their turn does not release")

    // 5. High p plus their pause skips the 450 ms wait.
    let e = heldByThem()
    e.noteFarEndProb(0.3)
    _ = e.step(dt: 0.02, near: .quiet)
    e.noteFarEndProb(0.9)
    e.noteFar(.quiet, transitMs: 40)
    let de = e.step(dt: 0.02, near: .quiet)
    say(de.state == .idle,
        "high p plus their pause releases without waiting 450 ms")
    let f = heldByThem()
    f.noteFar(.quiet, transitMs: 40)
    let df = f.step(dt: 0.02, near: .quiet)
    say(df.state == .theirs,
        "REJECT: a pause with p=0 still waits")

    // 6. After a far-end release the idle echo guard still shuts the mic.
    let g = heldByThem()
    g.noteFarEndProb(0.3)
    _ = g.step(dt: 0.02, near: .quiet)
    g.noteFarEndProb(0.9)
    _ = g.step(dt: 0.02, near: .quiet)
    g.notePlayout(live: true)
    let dg = g.step(dt: 0.02, near: .quiet)
    say(dg.state == .idle && !dg.mayTransmit,
        "after a far-end release the idle echo guard still shuts the mic next to a live speaker")

    // 7. A high LOCAL prior does not mute the person who has the floor.
    let h = Floor()
    h.cfg.strict = false
    h.speakers = true
    h.noteFar(.quiet)
    _ = h.step(dt: 0.02, near: .quiet)
    _ = h.step(dt: 0.02, near: .claim)
    h.noteEndProb(0.9)
    let dh = h.step(dt: 0.02, near: .claim)
    say(dh.state == .mine && dh.mayTransmit,
        "a high local prior does not mute the person who has the floor")

    // 8. If the prior falls they take the floor back (false-alarm recovery).
    let i = heldByThem()
    i.noteFarEndProb(0.3)
    _ = i.step(dt: 0.02, near: .quiet)
    i.noteFarEndProb(0.9)
    _ = i.step(dt: 0.02, near: .quiet)
    i.noteFarEndProb(0.2)
    i.noteFar(.claim)
    let di = i.step(dt: 0.02, near: .quiet)
    say(di.state == .theirs, "if the prior falls they take the floor back")

    // 9. An older build (p=0 forever) still releases after ~450 ms of quiet.
    let j = heldByThem()
    j.noteFar(.quiet, transitMs: 10)
    var waited = 0.0
    var last = j.step(dt: 0.02, near: .quiet)
    while waited < 1.0, last.state == .theirs {
      waited += 0.02
      last = j.step(dt: 0.02, near: .quiet)
    }
    say(waited > 0.35 && waited < 0.55,
        "an older build (p=0) still releases after ~450 ms (\(Int(waited * 1000)) ms)")

    // 10. The wire byte. 0.7 is the threshold; 0 is what 0.92.0 writes.
    let back = Wire.endProb(from: Wire.endProbByte(0.7))
    say(abs(back - 0.7) < 0.01, "0.7 survives the wire byte (got \(String(format: "%.3f", back)))")
    say(Wire.endProbByte(0) == 0 && Wire.endProb(from: 0) == 0,
        "an older build's pad byte reads as no prediction")

    fputs("FLOOR FAR-PREDICT CHECK: \(ok ? "PASS" : "FAIL")\n", stderr)
    return ok
  }

  /// ── STRICT, PROVEN WITH THE WIRE IN ───────────────────────────────────────
  ///
  /// The claim is "one microphone, one loudspeaker, never the same end", and a
  /// claim about two ends is only testable with two floors and a real hop
  /// between them. Every scenario runs twice: strict must hold the claim, and
  /// soft must VISIBLY break it -- a meter that reads zero on both arms is a
  /// meter that cannot see (`green-metrics-can-hide-defects`).
  static func strictSelfTest(owdMs: Double = 40) -> Bool {
    var ok = true
    func say(_ good: Bool, _ what: String) {
      if !good { ok = false }
      fputs("floor: \(good ? "OK  " : "FAIL") \(what)\n", stderr)
    }
    let dt = 0.010
    let cfg0 = Cfg()
    struct Tally {
      var bothOpenMs = 0.0        // both ends on the wire in the same block
      var noneOpenWhileClaimMs = 0.0  // somebody claiming, NOBODY audible
      var aOpenMs = 0.0, bOpenMs = 0.0
      var duckSeen = false        // any duckOnly decision -- strict must never
      var bOpenAfterMs: Double? = nil  // first time B transmitted
    }
    /// Two floors, one hop apart. `cutAt` kills the cue channel both ways.
    func run(seconds: Double, strict: Bool, cutAt: Double = .infinity,
             speakers: Bool = true,
             voice: (Int, Double) -> Voice) -> Tally {
      let fa = Floor(), fb = Floor()
      fa.cfg.strict = strict; fb.cfg.strict = strict
      fa.yieldsOnTie = true; fb.yieldsOnTie = false
      fa.speakers = speakers; fb.speakers = speakers
      fa.noteFar(.quiet); fb.noteFar(.quiet)
      var pa: [(due: Double, v: Voice)] = [], pb: [(due: Double, v: Voice)] = []
      var t = 0.0, tally = Tally()
      while t < seconds {
        var open = [false, false]
        for i in 0..<2 {
          let f = i == 0 ? fa : fb
          var pending = i == 0 ? pa : pb
          var still: [(due: Double, v: Voice)] = []
          for p in pending { if p.due <= t { f.noteFar(p.v, transitMs: owdMs) } else { still.append(p) } }
          pending = still
          if i == 0 { pa = pending } else { pb = pending }
          let v = voice(i, t)
          let d = f.step(dt: dt, near: v)
          open[i] = d.mayTransmit || d.duckOnly
          if d.duckOnly { tally.duckSeen = true }
          if t < cutAt {
            let hop = (due: t + owdMs / 1000, v: v)
            if i == 0 { pb.append(hop) } else { pa.append(hop) }
          }
        }
        if open[0] && open[1] { tally.bothOpenMs += dt * 1000 }
        if open[0] { tally.aOpenMs += dt * 1000 }
        if open[1] { tally.bOpenMs += dt * 1000; if tally.bOpenAfterMs == nil { tally.bOpenAfterMs = t * 1000 } }
        if (voice(0, t) == .claim || voice(1, t) == .claim) && !open[0] && !open[1] {
          tally.noneOpenWhileClaimMs += dt * 1000
        }
        t += dt
      }
      return tally
    }
    let hop = owdMs

    // 1. CLEAN ALTERNATION. A talks 0-2, B talks 2.5-4.5. In strict the pause
    //    belongs to nobody and NOTHING overlaps, ever.
    let alt: (Int, Double) -> Voice = { i, t in
      if i == 0 { return t < 2.0 ? .claim : .quiet }
      return (t >= 2.5 && t < 4.5) ? .claim : .quiet
    }
    let s1 = run(seconds: 5, strict: true, voice: alt)
    say(s1.bothOpenMs == 0, "alternation: not one block of both microphones (\(Int(s1.bothOpenMs)) ms)")
    say(!s1.duckSeen, "alternation: the duck does not exist in strict")
    let s1soft = run(seconds: 5, strict: false, voice: alt)
    say(s1soft.bothOpenMs > 100,
        "REJECT: soft opens both through the pauses (\(Int(s1soft.bothOpenMs)) ms) -- the meter can see")

    // 2. INTERRUPTION. B barges into A's turn and keeps going. The interrupter
    //    is SILENT until the floor flips (no duck), and the overlap at the flip
    //    is bounded by the hop, not by politeness.
    let barge: (Int, Double) -> Voice = { i, t in
      if i == 0 { return t < 4.0 ? .claim : .quiet }
      return t >= 1.0 ? .claim : .quiet
    }
    let s2 = run(seconds: 6, strict: true, voice: barge)
    // ── THE BOUND THE GRACE WINDOW MOVED, AND ON PURPOSE ──────────────────
    //
    // This was `2 * hop + 30` (110 ms at 40 ms owd), and it was the right bound
    // for a design that deleted the interrupter's first 180 ms. It is now the
    // hops PLUS the onset grace, because those milliseconds are exactly what a
    // barge-in used to lose: an overlap this long IS the interjection being
    // audible. Still bounded, still counted live as `strict_overlap_pct`, and
    // still nowhere near a duplex channel.
    let bargeBound = 2 * hop + cfg0.onsetGraceMs + 60
    say(s2.bothOpenMs <= bargeBound,
        "barge-in: overlap bounded by hops + the onset grace (\(Int(s2.bothOpenMs)) ms <= \(Int(bargeBound)))")
    say(!s2.duckSeen, "barge-in: held means silent or heard, never ducked")
    say(s2.bOpenMs > 1000, "barge-in: the interrupter does get the floor (\(Int(s2.bOpenMs)) ms)")
    let s2soft = run(seconds: 6, strict: false, voice: barge)
    say(s2soft.duckSeen, "REJECT: soft ducks the interrupter -- the meter can see")

    // 3. SIMULTANEOUS START. Both take an empty floor inside one hop; the
    //    deadlock break silences exactly one. This is the window strict cannot
    //    remove, and the bound is stated rather than hidden: deadlockMs + hops.
    let together: (Int, Double) -> Voice = { _, t in t >= 1.0 ? .claim : .quiet }
    let s3 = run(seconds: 6, strict: true, voice: together)
    say(s3.bothOpenMs <= 450 + 2 * hop + 30,
        "simultaneous start: overlap inside deadlock + hops (\(Int(s3.bothOpenMs)) ms)")
    say(s3.bothOpenMs > 0, "REJECT: the collision is real (otherwise this proves nothing)")
    say(s3.noneOpenWhileClaimMs <= 2 * hop + 30,
        "simultaneous start: never both silent beyond a hop (\(Int(s3.noneOpenWhileClaimMs)) ms)")

    // 4. DEAD CUE CHANNEL. Cues stop mid-call. Strict may not open the
    //    listener; the talker keeps talking on their own evidence.
    let cutTalk: (Int, Double) -> Voice = { i, t in
      i == 0 && t < 6.0 ? .claim : .quiet
    }
    let s4 = run(seconds: 6, strict: true, cutAt: 2.0, voice: cutTalk)
    say(s4.bothOpenMs == 0, "dead cues: still not one block of both (\(Int(s4.bothOpenMs)) ms)")
    say(s4.aOpenMs > 5500, "dead cues: the talker never loses the floor (\(Int(s4.aOpenMs)) ms)")
    say(s4.bOpenMs == 0, "dead cues: the silent listener stays silent")
    let s4soft = run(seconds: 6, strict: false, cutAt: 2.0, voice: cutTalk)
    say(s4soft.bothOpenMs > 200,
        "REJECT: soft falls back to open on dead cues (\(Int(s4soft.bothOpenMs)) ms) -- the meter can see")

    // 5. THE PEER DIES. A talks, goes silent forever, cues die with it. B must
    //    still be able to take the floor -- strict must not entomb the call.
    let orphan: (Int, Double) -> Voice = { i, t in
      if i == 0 { return t < 2.0 ? .claim : .quiet }
      return t >= 4.0 ? .claim : .quiet
    }
    let s5 = run(seconds: 6, strict: true, cutAt: 2.0, voice: orphan)
    say(s5.bOpenMs > 1500 && (s5.bOpenAfterMs ?? 9e9) < 4200,
        "dead peer: the survivor takes the floor at \(Int(s5.bOpenAfterMs ?? -1)) ms (asked at 4000)")
    say(s5.bothOpenMs == 0, "dead peer: and still never both")

    // 6. THE EAR. While I hold, my speaker is closed -- on headphones too, in
    //    strict, because the rule is a product statement now. One block after
    //    the lag it must be shut; in idle it must be open.
    let e = Floor()
    e.cfg.strict = true
    e.speakers = false                        // headphones: the hard case
    e.noteFar(.quiet)
    _ = e.step(dt: 0.02, near: .quiet)
    var de = e.step(dt: 0.02, near: .claim)   // take the floor
    var waited = 0.0
    while waited < 0.5, de.playoutOpen { de = e.step(dt: 0.02, near: .claim); waited += 0.02 }
    say(de.state == .mine && !de.playoutOpen,
        "holder's ear closes even on headphones (after \(Int(waited * 1000)) ms of lag)")
    let e2 = Floor()
    e2.cfg.strict = true
    e2.noteFar(.quiet)
    say(e2.step(dt: 0.02, near: .quiet).playoutOpen, "and an idle ear is open")

    // 7. IDLE IS SILENT, TAKING IS INSTANT. The strict pause transmits nothing,
    //    and the first voice is on the wire in the same block that produced it.
    let q = Floor()
    q.cfg.strict = true
    q.noteFar(.quiet)
    say(!q.step(dt: 0.02, near: .quiet).mayTransmit, "idle transmits nothing")
    say(q.step(dt: 0.02, near: .claim).mayTransmit, "and the first voice is out in its own block")

    // 8. AND "FIRST VOICE" MEANS WHAT THE CLASSIFIER ACTUALLY SAYS FIRST.
    //    Every vocalisation begins as a BACKCHANNEL for 700 ms -- a rig that
    //    feeds `.claim` directly is testing an input the product cannot
    //    produce at an onset (`rig-picks-a-parameter-the-product-does-not`).
    //    The old rule held that phase silent from idle, which was 700 ms of
    //    dead air on every turn start.
    let q2 = Floor()
    q2.cfg.strict = true
    q2.noteFar(.quiet)
    _ = q2.step(dt: 0.02, near: .quiet)
    let dq2 = q2.step(dt: 0.02, near: .backchannel)
    say(dq2.state == .mine && dq2.mayTransmit,
        "a voice still in its backchannel phase takes an empty floor at once")
    let q3 = Floor()
    q3.cfg.strict = false
    q3.noteFar(.quiet)
    _ = q3.step(dt: 0.02, near: .quiet)
    say(q3.step(dt: 0.02, near: .backchannel).state == .idle,
        "REJECT: soft keeps the old rule, so the arms are distinguishable")
    // Their side of the same onset: their cue still says backchannel, their
    // audio is already flowing -- this ear opens as THEIRS, not as a bystander.
    let q4 = Floor()
    q4.cfg.strict = true
    q4.noteFar(.quiet)
    _ = q4.step(dt: 0.02, near: .quiet)
    q4.noteFar(.backchannel)
    let dq4 = q4.step(dt: 0.02, near: .quiet)
    say(dq4.state == .theirs && !dq4.mayTransmit,
        "their backchannel-phase voice holds this mic shut from idle")
    // And the protection the old rule was FOR is intact: an "mm-hm" over a
    // holder still does not move the floor.
    let q5 = Floor()
    q5.cfg.strict = true
    q5.noteFar(.quiet)
    _ = q5.step(dt: 0.02, near: .quiet)
    q5.noteFar(.claim)
    _ = q5.step(dt: 0.02, near: .quiet)          // they hold
    let dq5 = q5.step(dt: 0.02, near: .backchannel)
    // ── WHAT AN mm-hm MUST AND MUST NOT DO, RESTATED ────────────────────────
    //
    // This row asserted the mm-hm was INAUDIBLE, which is the deletion 0.99.0
    // exists to end -- "mm-hm" is the single most important thing a listener
    // says, and holding it back is what made the app feel like a walkie-talkie.
    // The property that actually matters is unchanged and still checked: it
    // does not take the FLOOR away from the person talking. It is heard, it
    // changes nothing, and when it stops the holder never noticed.
    say(dq5.state == .theirs,
        "an mm-hm over a holder does not take the floor away from them")
    say(dq5.mayTransmit,
        "and it is still HEARD -- a listening noise held back is the deletion")

    // ── 9. AN INTERJECTION IS NEVER DELETED ─────────────────────────────────
    //
    // The defect this release exists for: 50 utterances on one live call that
    // never reached the wire at all. A short interjection over a holder must be
    // audible from its first block, and the floor must actually change hands
    // fast enough that a normal interruption is not a special case.
    func heldByThemStrict() -> Floor {
      let f = Floor()
      f.cfg.strict = true
      f.speakers = true
      f.noteFar(.quiet)
      _ = f.step(dt: 0.02, near: .quiet)
      f.noteFar(.claim)
      _ = f.step(dt: 0.02, near: .quiet)
      return f
    }
    // A 300 ms interjection -- "wait", "no", "yeah" -- entirely within what the
    // old 1150 ms contest deleted.
    let s9 = heldByThemStrict()
    var outMs = 0.0, blockedMs = 0.0
    for _ in 0..<15 {                                  // 300 ms of voice
      if s9.step(dt: 0.02, near: .backchannel).mayTransmit { outMs += 20 } else { blockedMs += 20 }
    }
    say(blockedMs == 0,
        "a 300 ms interjection over a holder is audible for all of it (\(Int(outMs)) ms out, \(Int(blockedMs)) ms lost)")
    // The REJECT twin. Soft mode ducks instead of deleting, so it has never had
    // this defect and must not be read as proof: the arm that has to fail is
    // strict WITHOUT the grace window, which is what 0.98.0 shipped.
    let s9b = heldByThemStrict()
    s9b.cfg.onsetGraceMs = 0
    s9b.cfg.strictDeadlockMs = 450
    var lost9b = 0.0
    for _ in 0..<15 {
      if !s9b.step(dt: 0.02, near: .backchannel).mayTransmit { lost9b += 20 }
    }
    say(lost9b >= 280,
        "REJECT: without the grace window the same interjection is deleted (\(Int(lost9b)) ms lost) -- the meter can see")

    // 10. AND THE FLOOR REALLY CHANGES HANDS, on the voice clock, at 180 ms.
    let s10 = heldByThemStrict()
    var took = 0.0
    var d10 = s10.step(dt: 0.02, near: .backchannel)
    while took < 1000, d10.state != .mine {
      took += 20
      d10 = s10.step(dt: 0.02, near: .backchannel)
    }
    say(d10.state == .mine && took <= 260,
        "the floor changes hands after \(Int(took)) ms of voice, not after 1150")
    say(s10.fastTakes == 1, "and it is counted as a fast take")

    // 11. THE WINDOW IS BOUNDED. Somebody talking straight through does not get
    //     a parallel channel forever -- either they won the floor or they stop.
    let s11 = heldByThemStrict()
    s11.cfg.strictDeadlockMs = 9999          // never let the contest resolve it
    var openMs = 0.0, mineMs = 0.0
    for _ in 0..<60 {                        // 1.2 s of continuous voice
      // Their cue, every block, exactly as a live call delivers it (the probe
      // beats every 300 ms). Without this the 1.2 s loop crosses `staleMs` at
      // block 50, the holder goes blind, releases, and this end takes the floor
      // legitimately -- measuring the staleness path while claiming to measure
      // the grace bound.
      s11.noteFar(.claim)
      let d = s11.step(dt: 0.02, near: .backchannel)
      if d.mayTransmit { openMs += 20; if d.state == .mine { mineMs += 20 } }
    }
    // Reports WHICH mechanism held the mic open. A bound that fails without
    // naming the path is a number somebody has to re-derive by hand.
    say(openMs <= s11.cfg.onsetGraceMs + 40,
        "the grace window is bounded at \(Int(s11.cfg.onsetGraceMs)) ms"
        + " (\(Int(openMs)) ms open: \(s11.graceBlocks) grace blocks, \(Int(mineMs)) ms as holder)")

    // 12. AND THE ECHO CANNOT OPEN IT. A block the veto claimed is classified
    //     `.quiet` upstream, and `.quiet` is the one input the window refuses.
    let s12 = heldByThemStrict()
    var echoOut = 0.0
    for _ in 0..<30 {
      if s12.step(dt: 0.02, near: .quiet).mayTransmit { echoOut += 20 }
    }
    say(echoOut == 0, "a vetoed (quiet) block never opens the grace window")

    // 13. THE PREDICTOR FIRES ONCE PER HOLD, NOT TWENTY TIMES A SECOND.
    //     Live: 6838 far releases in 333 s, "saving" 7.9x the call length.
    let s13 = heldByThemStrict()
    for _ in 0..<50 {
      s13.noteFarEndProb(0.3)                // dip: arms
      _ = s13.step(dt: 0.02, near: .quiet)
      s13.noteFarEndProb(0.9)                // rise: fires
      _ = s13.step(dt: 0.02, near: .quiet)
      s13.noteFar(.claim)                    // they are still talking
    }
    say(s13.farPredictedReleases <= 50,
        "the far predictor fired \(s13.farPredictedReleases)x over 50 dip-rise cycles, not once per block")
    say(s13.farPredictedSavedMs <= 50 * 450,
        "and its claimed saving stays inside one release per cycle (\(Int(s13.farPredictedSavedMs)) ms)")

    // ── 14. THE CAMERA MAY ONLY EVER HELP ───────────────────────────────────
    //
    // Three rows, and the third is the one that matters most: a detector that
    // cannot see must leave the floor behaving exactly as it did without one.
    // `blind-instruments-report-negatives` -- if blindness read as "not
    // talking" anywhere in this path, every dark room and every camera-off
    // call would get slower turn-taking than 0.99.0 had.
    let v1 = heldByThemStrict()
    v1.nearVisualVoice = true
    var vTook = 0.0
    var dv1 = v1.step(dt: 0.02, near: .backchannel)
    while vTook < 1000, dv1.state != .mine {
      vTook += 20
      v1.noteFar(.claim)
      dv1 = v1.step(dt: 0.02, near: .backchannel)
    }
    say(dv1.state == .mine && vTook <= 120,
        "a camera-confirmed voice takes the floor in \(Int(vTook)) ms")
    say(v1.visualTakes == 1, "and it is counted as a visual take")

    let v2 = heldByThemStrict()
    v2.nearVisualVoice = false            // blind, or sitting quietly
    var bTook = 0.0
    var dv2 = v2.step(dt: 0.02, near: .backchannel)
    while bTook < 1000, dv2.state != .mine {
      bTook += 20
      v2.noteFar(.claim)
      dv2 = v2.step(dt: 0.02, near: .backchannel)
    }
    say(dv2.state == .mine && bTook >= 140,
        "REJECT: with no camera the contest is unchanged at \(Int(bTook)) ms -- blindness costs nothing")
    say(v2.visualTakes == 0, "and nothing is booked to the camera that it did not do")

    // And it cannot mute: a camera that says nothing while this end holds the
    // floor must not take it away.
    let v3 = Floor()
    v3.cfg.strict = true
    v3.noteFar(.quiet)
    _ = v3.step(dt: 0.02, near: .quiet)
    _ = v3.step(dt: 0.02, near: .claim)          // I take the floor
    v3.nearVisualVoice = false                   // and the camera sees nothing
    let dv3 = v3.step(dt: 0.02, near: .claim)
    say(dv3.state == .mine && dv3.mayTransmit,
        "a blind camera never takes the floor from the person holding it")

    fputs("FLOOR STRICT CHECK: \(ok ? "PASS" : "FAIL")\n", stderr)
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
      // This harness scripts the SOFT arm; strict runs its own two-end sweep
      // in `strictSelfTest` with the same hop model.
      a.floor.cfg.strict = false
      b.floor.cfg.strict = false
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
