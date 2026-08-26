import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// ── KNOWING A TURN IS ENDING BEFORE IT ENDS ──────────────────────────────────
//
// The gate in Audio.swift is REACTIVE, and a reactive gate can never be smooth.
// Every block it has to choose between clipping the first syllable of whoever
// speaks next and letting the room's echo through, and that trade is not a
// tuning problem -- it was tuned, and relaxing the threshold to be kinder to
// interruptions took echo suppression from 19.3 dB to 1.7. There is no setting
// that is generous to an interruption and mean to an echo, because at the moment
// of decision the two look the same.
//
// A PREDICTION escapes the trade because it does not decide in the moment. If we
// know a turn is ending 400 ms before the last word stops, the decision is
// already made when the next person opens their mouth: nothing had to be clipped
// or let through to find out which it was.
//
// So what this file produces is a PRIOR, not a trigger. It is allowed to be
// wrong, it is allowed to be 200-500 ms behind the audio, and nothing it says
// may ever be the sole reason a sample is turned down. That tolerance is the
// entire reason a language model is usable here at all.
//
// ── NOTHING HERE IS IN THE AUDIO PATH ────────────────────────────────────────
//
// `noteEnergy` is called from the 120 ms subtitle chunk thread, never from the
// render callback. `noteText` is called from the recogniser's own callback.
// `probability` is called from the subtitle thread. The audio thread reads
// nothing from this file -- a consumer that wants the prior reads a Double that
// is already sitting there.
//
// `unexplained-death-is-a-bug`: no Swift collection crosses a thread boundary
// here. `text` is a String written by the recogniser thread and read by the
// predictor thread, so it goes through a lock and is copied out; everything else
// that crosses is a scalar. The energy ring is only ever touched by the thread
// that feeds it.
final class Predict {

  // ── LAYER ONE: THE CHEAP THING, WHICH HAS TO CARRY THE FEATURE ─────────────
  //
  // `SystemLanguageModel.default.availability` can be `.appleIntelligenceNotEnabled`
  // -- a switch in Settings the person may simply never have touched -- or
  // `.deviceNotEligible`, or `.modelNotReady` because the weights have not been
  // downloaded. So the model cannot BE the mechanism. Everything below layer two
  // runs on every Mac with no download, no entitlement and no setting, and layer
  // two is only allowed to make it better.

  /// Words that cannot be the last word of a finished thought. A turn does not
  /// end on "and", on "the", or on "because" -- whatever the prosody is doing,
  /// whatever the silence looks like, the speaker is mid-sentence and coming
  /// back. It was expected to be the most valuable feature in the file, and it
  /// measured as nothing; the note in `syntax` says why, and it is a timing
  /// problem rather than a linguistic one.
  ///
  /// Deliberately NOT a general "function word" list. "It's fine" ends a turn and
  /// "fine" is not hanging; "I think it's" does not and "it's" is. The test is
  /// whether an English clause can stop there, not what part of speech it is.
  ///
  /// ── AND HALF OF THEM COULD END A CLAUSE AFTER ALL ────────────────────────
  ///
  /// The first version of this list had "so", "that", "this", "when", "where",
  /// "though", "not", "it" and "there" in it, and the finished/unfinished pair
  /// check in the rig refused the build on the spot: "yes I think so" and "we can
  /// do that" are finished sentences, and the list called both of them
  /// mid-clause. English function words are mostly two words wearing one
  /// spelling -- "so" is a conjunction AND a sentence-final adverb, "that" is a
  /// complementiser AND a demonstrative pronoun -- and only the ones that are
  /// unambiguously the first kind belong here.
  ///
  /// So: a word that can stop a clause in ANY reading is out, however common the
  /// other reading is. The cost of keeping it is vetoing a real turn end, and the
  /// cost of dropping it is one weak feature slightly weaker.
  static let hanging: Set<String> = [
    "and", "or", "but", "because", "cause", "cos", "although", "whilst",
    "if", "unless", "until", "till", "whether", "than",
    "the", "a", "an", "my", "your", "his", "her", "its", "our", "their",
    "another", "such",
    "of", "to", "in", "on", "at", "for", "with", "from", "by", "about", "into",
    "onto", "under", "between", "through", "during", "against",
    "without", "within", "upon", "toward", "towards",
    "is", "are", "was", "were", "am", "be", "been", "being", "has", "have",
    "had", "does", "did", "will", "would", "shall", "should", "may", "must",
    "gonna", "wanna", "gotta",
    "i", "we", "they", "he", "she",
    "very", "really", "quite",
  ]

  /// Sounds people make while deciding what to say next. A turn does not end on
  /// one; it is the audible form of "I have not finished".
  static let filler: Set<String> = [
    "um", "uh", "erm", "er", "ah", "hmm", "mm", "eh", "like", "well", "okay",
    "ok", "y'know", "yknow",
  ]

  /// How complete the words so far are, on their own, as a probability.
  ///
  /// Pure and static so it can be measured against a list of strings with no
  /// audio, no recogniser and no clock -- which is how the numbers in
  /// `predict-check.sh` are reproducible on a machine with three other builds
  /// running on it.
  static func syntax(_ raw: String) -> Double {
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return 0 }
    let words = t.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
    guard let lastRaw = words.last else { return 0 }
    let n = words.count
    // Enough material to be a sentence at all. One word is "yeah" or the start
    // of something; it is not evidence either way, so it is held near the middle
    // and let the energy decide.
    let bulk = min(1.0, Double(n) / 5.0)

    let tail = lastRaw.unicodeScalars.last.map { Character($0) } ?? " "
    // ── THE RECOGNISER PUNCTUATES, AND THAT IS THE WHOLE FEATURE ─────────────
    //
    // macOS 26's SpeechTranscriber emits sentence punctuation of its own inside
    // volatile partials. It is a model that has heard the clause deciding the
    // clause ended -- exactly the judgement wanted here, arriving for nothing.
    //
    // MEASURED, on 183 real pauses across two speakers (see predict-check.sh):
    //
    //   last character is . ? !     31 pauses, 29% of them were turn ends
    //   last word is "and/the/to"   73 pauses, 15%   <- the base rate exactly
    //   an ordinary content word    66 pauses,  9%
    //
    // The base rate is 15%, so the punctuation roughly doubles the odds and the
    // word list does nothing at all -- and a content word with NO full stop after
    // it is weak evidence the clause is still running, which is the opposite of
    // what the rule below used to say. The reason is timing: the transcript is
    // most of a second behind the sound, so the "last word" at the moment
    // somebody stops is a word from the middle of the clause and the list is
    // being asked about the wrong token.
    if tail == "." || tail == "?" || tail == "!" { return 0.90 }
    // And the other direction: a comma is the recogniser saying the sentence is
    // still going. Stronger evidence than any word-level rule.
    if tail == "," || tail == ";" || tail == ":" { return 0.15 }

    let last = String(lastRaw).lowercased()
      .trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
    // ── SO THE WORD LIST IS KEPT, AND KEPT MILD ─────────────────────────────
    //
    // It measured as noise HERE -- two speakers, one genre, formal interview
    // English, and a recogniser whose partials are 600 ms behind. It is not
    // deleted, because on a faster transcript it is asking a real question and
    // because 183 events across two speakers is not enough to retire a rule on.
    // It is kept at a spread narrow enough that it cannot decide anything on its
    // own: the ordering is linguistics, the magnitude is what the measurement
    // will support. Fitting these three numbers to those 183 events would be
    // fitting a word list to one interview.
    if Predict.filler.contains(last) { return 0.25 }
    if Predict.hanging.contains(last) { return 0.30 }
    // A content word at the end of enough material, and no full stop after it.
    return 0.32 + 0.06 * bulk
  }

  // ── THE OTHER HALF: A SENTENCE THAT LANDS LOSES ENERGY ────────────────────
  //
  // Declination. Across an English utterance the speaker's level falls, and it
  // falls hardest over the last syllables of a completed clause; a mid-sentence
  // hesitation does not fall, because the speaker is holding the floor and knows
  // it. That is prosody, which no transcript can recover, and it is the thing
  // Qwen's smart-turn was bought for on the one machine that runs the daemon.
  //
  // A ring of block peaks, in dB, written only by the thread that feeds audio.
  private var ring = [Float](repeating: 0, count: 128)
  private var ringW = 0
  private var ringN = 0
  /// 128 entries of whatever the chunk thread hands over. At 120 ms chunks that
  /// is 15 s, far more than one utterance; the window that is actually read is
  /// chosen in `fallDb` by count, not by the ring's length.
  func noteEnergy(_ peak: Float) {
    ring[ringW] = peak
    ringW = (ringW + 1) % ring.count
    ringN = min(ringN + 1, ring.count)
  }


  /// How far the level has fallen, in dB, from the loudest of the utterance's
  /// body to its last spoken moments. Positive means falling, which means landing.
  ///
  /// ── AND IT MUST NOT COUNT THE PAUSE ITSELF ────────────────────────────────
  ///
  /// The first version took the last 100 ms of wall clock. Measured on 300 s of
  /// real interview speech: 250 ms into ANY gap that window is silence, so the
  /// ratio saturated and the feature returned 40 dB of "falling" for every pause
  /// on the recording -- hesitations and turn ends alike. It scored 85% false
  /// alarms and the null arm with the labels rotated scored the same, which is
  /// the ruler saying the number contained no information at all.
  ///
  /// It had become a silence detector, which is precisely the reactive thing this
  /// file exists to avoid: a feature that saturates in the state you are asking
  /// about answers a different question than the one you asked. So the trailing
  /// quiet is SKIPPED and the comparison is speech against speech -- declination
  /// across the utterance, which is what prosody actually offers here.
  @inline(__always) private func at(_ back: Int) -> Float {
    ring[((ringW - 1 - back) % ring.count + ring.count) % ring.count]
  }

  /// The loudest thing in living memory, and a bar 34 dB under it. A voice sits
  /// 25-35 dB above a room, so this separates "speaking" from "not" without ever
  /// needing to know the room's absolute level.
  private func bar() -> Float {
    var loudest: Float = 0
    for k in 0..<ringN { loudest = max(loudest, at(k)) }
    return loudest > 1e-4 ? loudest / 50 : Float.greatestFiniteMagnitude
  }

  /// How far the level has fallen, in dB, from the loudest of the utterance's
  /// body to its last spoken moments. Positive means falling, which means landing.
  ///
  /// ── AND IT MUST NOT COUNT THE PAUSE ITSELF ────────────────────────────────
  ///
  /// The first version took the last 100 ms of wall clock. Measured on 300 s of
  /// real interview speech: 250 ms into ANY gap that window is silence, so the
  /// ratio saturated and the feature returned 40 dB of "falling" for every pause
  /// on the recording -- hesitations and turn ends alike. It scored 85% false
  /// alarms and the null arm with the labels rotated scored the same, which is
  /// the ruler saying the number contained no information at all.
  ///
  /// It had become a silence detector, which is precisely the reactive thing this
  /// file exists to avoid: a feature that saturates in the state you are asking
  /// about is answering a different question than the one you asked. So the
  /// trailing quiet is SKIPPED and the comparison is speech against speech --
  /// declination across the utterance, which is what prosody actually offers here.
  /// ── AND MAXIMA OVER UNEQUAL WINDOWS ARE NOT A COMPARISON ─────────────────
  ///
  /// The second version took the loudest of the last 4 voiced sub-blocks against
  /// the loudest of the 40 before them. A maximum grows with the size of the
  /// window it is taken over, so that number is mostly "40 is bigger than 4":
  /// measured over 183 real pauses it came out at 22.5 dB before a hesitation and
  /// 22.1 dB before a turn end. Identical. The feature was a constant wearing a
  /// unit.
  ///
  /// Means over the SAME number of voiced sub-blocks, in dB, is the comparison
  /// that was intended -- declination across an utterance, ten sub-blocks against
  /// the ten before them.
  private func fallDb(recent: Int = 10, body: Int = 10) -> Double {
    guard ringN >= 8 else { return 0 }
    let b = bar()
    var tail = 0.0, peak = 0.0
    var seen = 0
    for k in 0..<ringN {
      let v = at(k)
      if v < b { continue }                      // the pause, and the gaps inside words
      let db = 20 * log10(Double(max(v, 1e-7)))
      seen += 1
      if seen <= recent { tail += db } else if seen <= recent + body { peak += db }
      if seen >= recent + body { break }
    }
    guard seen >= recent + body else { return 0 }
    return peak / Double(body) - tail / Double(recent)
  }

  // ── HOW LONG THEY HAVE BEEN GOING, AND HOW LONG THEY HAVE STOPPED ─────────
  //
  // These came from `Audio.DuplexGate.vocalMsNow` and `quietMsNow`, which is the
  // shipping classifier and the obvious source. Measured over 566 s of real
  // interview speech, that classifier reported vocalMs = 0 -- no vocalisation in
  // progress at all -- at a large share of the pauses the labeller found, and the
  // `vocalMs < 500` term then multiplied the whole prior by a fifth at exactly
  // the moments it was being asked about.
  //
  // Whether the gate is right or wrong there is a question for the file that owns
  // it. What is wrong HERE is depending on it: this file already has an energy
  // trace of its own, taken from the same samples, and reading the same fact out
  // of its own ring costs nothing and cannot be switched off by somebody else's
  // detector having a bad moment. `control-plane-rides-its-own-resource`, in
  // miniature -- the evidence and the thing it reports on were the same detector.
  private func ringQuietMs() -> Double {
    let b = bar()
    var k = 0
    while k < ringN, at(k) < b { k += 1 }
    return Double(k) * 25
  }

  private func ringVocalMs() -> Double {
    let b = bar()
    var n = 0
    for k in 0..<ringN where at(k) >= b { n += 1 }
    return Double(n) * 25
  }

  // ── LAYER TWO: THE MODEL, WHICH IS NEVER ASKED AT THE MOMENT IT MATTERS ───
  //
  // An on-device answer costs hundreds of milliseconds. Asked at the pause it
  // would arrive after the pause was over, which is the whole reason a language
  // model has no business in a turn-taking decision -- unless the question is
  // asked EARLY, about the words so far, and the answer is sitting there when
  // the pause arrives. So it is asked once per revision of the transcript, at
  // whatever rate the recogniser revises, and its answer is a standing opinion
  // with an age on it.
  //
  // One in flight at a time. A queue of questions about a sentence that has
  // moved on is worse than no answer at all.
  private let lock = NSLock()
  private var text = ""
  private var textStamp = 0.0
  private var modelP = -1.0
  private var modelForStamp = -1.0
  private var modelBusy = false
  private(set) var modelAsks = 0
  private(set) var modelAnswers = 0
  private(set) var modelFails = 0
  private(set) var modelMsTotal = 0.0
  private var session: AnyObject?
  private var llm: AnyObject?
  private var modelWhyFailed = ""
  /// Set once, at construction, from `SystemLanguageModel.default.availability`.
  /// Reported rather than assumed: on a Mac with Apple Intelligence switched off
  /// this is false and every number this file produces comes from layer one.
  private(set) var modelReady = false
  private(set) var modelWhy = "not asked for"

  /// `useCase`: "general" or "tagging". `.contentTagging` is a built-in use case
  /// for exactly this size of classification and is worth an A/B; the flag exists
  /// so that A/B is one argument rather than a rebuild.
  init(model: Bool = false, useCase: String = "general") {
    guard model else { modelWhy = "off (--predict-model turns it on)"; return }
    if #available(macOS 26.0, *) {
#if canImport(FoundationModels)
      let m = useCase == "tagging" ? SystemLanguageModel(useCase: .contentTagging)
                                   : SystemLanguageModel.default
      switch m.availability {
      case .available:
        modelReady = true
        modelWhy = "available (\(useCase))"
        llm = m
        // Prewarming loads the weights, which is the expensive part and is shared
        // by every session that follows. The session it prewarms with is thrown
        // away; only the warmth is kept.
        let s = LanguageModelSession(model: m, instructions: Instructions(Predict.instructions))
        s.prewarm()
        session = s
      case .unavailable(let why):
        modelWhy = "unavailable: \(why)"
      @unknown default:
        modelWhy = "unavailable: unknown"
      }
#else
      modelWhy = "FoundationModels is not in this SDK"
#endif
    } else {
      modelWhy = "this Mac is older than the on-device model"
    }
  }

  static let instructions = """
    You judge conversational turn-taking. You are given a partial transcript of \
    what one person in a two-person call has said so far. The transcript may stop \
    mid-sentence because the person is still talking.

    Answer one question: if the speaker paused right now, could the other person \
    start talking without cutting the speaker off?

    Say done=true only when the thought is finished -- a complete statement, a \
    finished question, or an answer that has landed. Say done=false when the \
    speaker is clearly mid-thought: a trailing conjunction, a preposition or \
    article at the end, a list that has not finished, a subject with no verb yet, \
    or an audible filler.

    Being wrong in the direction of done=true costs the speaker their sentence. \
    When it is close, answer false.
    """

  /// A revision of what this end has said. Called from the recogniser's own
  /// callback thread; it takes the lock, stores a copy, and may start one model
  /// query. It never blocks that thread on the model.
  func noteText(_ t: String, at ms: Double) {
    lock.lock()
    text = t
    textStamp = ms
    revisions += 1
    let start = modelReady && !modelBusy && !t.isEmpty
    if start { modelBusy = true; modelAsks += 1 }
    let stamp = ms
    lock.unlock()
    guard start else { return }
    ask(t, stamp: stamp)
  }

  private func ask(_ t: String, stamp: Double) {
    if #available(macOS 26.0, *) {
#if canImport(FoundationModels)
      // ── A SESSION IS A CONVERSATION, AND THIS IS NOT A CONVERSATION ────────
      //
      // One `LanguageModelSession` reused for every question accumulates a
      // transcript, and the transcript is inside the context window. Measured:
      // 333 questions asked, 59 answered, 274 refused -- it worked for about a
      // minute and then failed for the rest of a nine-minute recording, which is
      // the shape of a context filling up rather than of a model that cannot
      // answer. Each question here is independent and stateless, so each one gets
      // its own session and the instructions are the only history there is.
      guard let m = llm as? SystemLanguageModel else {
        lock.lock(); modelBusy = false; lock.unlock(); return
      }
      let s = LanguageModelSession(model: m, instructions: Instructions(Predict.instructions))
      let t0 = Date()
      Task.detached(priority: .utility) { [weak self] in
        guard let self else { return }
        var p = -1.0
        do {
          let r = try await s.respond(to: Prompt("Transcript so far: \"\(t)\""),
                                      generating: FloorJudgement.self,
                                      options: GenerationOptions(sampling: .greedy))
          let c = r.content
          // A confidence the model volunteers is the difference between "yes"
          // and "yes, obviously", and the whole design here is a PRIOR rather
          // than a verdict, so a soft number is worth more than a bit.
          let sure = min(100, max(0, c.sure))
          p = c.done ? 0.5 + 0.5 * Double(sure) / 100 : 0.5 - 0.5 * Double(sure) / 100
        } catch {
          // The reason, once. A count of failures says something broke; it does
          // not say whether the model refused, ran out of room, or was not there.
          // (It was "May contain sensitive content" twice in a thousand: the
          // on-device guardrail can decline a transcript, and a predictor that
          // treats that as a crash is a predictor that stops on a swear word.)
          //
          // `withLock` and not lock/unlock: this closure is async, and a bare
          // NSLock held across a suspension point is an error in Swift 6. There
          // is no `await` between these braces, which is exactly what the scoped
          // form is for -- saying so to the compiler rather than to a reader.
          self.lock.withLock {
            self.modelFails += 1
            if self.modelWhyFailed.isEmpty {
              self.modelWhyFailed = "\(error)".prefix(140).description
            }
          }
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        self.lock.withLock {
          self.modelBusy = false
          self.modelMsTotal += ms
          if p >= 0 { self.modelP = p; self.modelForStamp = stamp; self.modelAnswers += 1 }
        }
      }
#else
      lock.lock(); modelBusy = false; lock.unlock()
#endif
    } else {
      lock.lock(); modelBusy = false; lock.unlock()
    }
  }

  /// What the words are and how old the model's opinion of them is.
  private func snapshot() -> (text: String, textMs: Double, p: Double, forMs: Double) {
    lock.lock(); defer { lock.unlock() }
    return (text, textStamp, modelP, modelForStamp)
  }

  // ── PUTTING THE TWO TOGETHER, ASYMMETRICALLY ─────────────────────────────
  //
  // `symmetric-threshold-asymmetric-cost`. The two mistakes here are not worth
  // the same. Missing a turn-end costs a beat of silence that a person recovers
  // from without noticing -- the reactive gate underneath is still there and
  // still opens on their voice. Predicting a turn-end that does not happen arms
  // the gate open under somebody who is still talking, which is the sentence the
  // whole feature exists to protect.
  //
  // So the model is allowed to VETO and only barely allowed to promote. It can
  // pull the prior all the way to the floor when it can see the speaker is
  // mid-thought -- which is what a language model is genuinely better at than a
  // word list, because it reads the clause and not the last token -- and it can
  // add at most a fifth when it agrees. Fixing the direction of a threshold is
  // not the same as fixing its magnitude, and this is the magnitude.
  static func combine(syntax s: Double, fall: Double, vocalMs: Double,
                      quietMs: Double, model: Double) -> Double {
    // ── THE PROSODY HALF DID NOT MEASURE ─────────────────────────────────────
    //
    // Energy, in dB of fall, mapped to a multiplier: 0 dB is a speaker holding
    // their level, which is what somebody who has not finished does, and 8 dB is
    // a clause landing. That is the theory, and across 28 real turn ends and 155
    // real hesitations it did not appear:
    //
    //   speaker A   before a turn end 10.5 dB   before a hesitation 10.9 dB
    //   speaker B   before a turn end  6.5 dB   before a hesitation 11.4 dB
    //
    // A is nothing. B is FIVE DECIBELS THE WRONG WAY -- less declination before a
    // turn end than before a hesitation, which is the opposite of the prediction.
    // Two speakers of formal interview English is not enough to retire prosody
    // and it is more than enough to stop leaning on it, so the range is kept
    // narrow: the whole term can move the answer by about three percent, which is
    // roughly what it has earned. It stays computed and printed by the rig so the
    // next recording can reopen the question with evidence rather than with
    // theory.
    let f = 0.45 + 0.55 * min(1.0, max(0.0, fall / 8.0))
    // A product, not a sum. Both have to hold: a sum lets a confidently falling
    // level carry a sentence that ends on "because", and that is the expensive
    // mistake in the shape it actually arrives in.
    var p = pow(max(s, 1e-6), 0.72) * pow(f, 0.28)
    // Not enough has been said for this to be an utterance at all.
    if vocalMs < 500 { p *= max(0.2, vocalMs / 500) }
    // A pause that is already running is itself weak evidence -- weak, because
    // the entire point is not to need it. It buys at most a tenth.
    p += 0.10 * min(1.0, quietMs / 450)
    if model >= 0 {
      if model < 0.5 { p *= (0.25 + 1.5 * model) }        // veto: down to a quarter
      else { p *= (1.0 + 0.2 * (model - 0.5) * 2) }       // agree: up to a fifth
    }
    return min(1.0, max(0.0, p))
  }

  /// The standing probability that this end's turn is ending. Call it as often as
  /// you like; it reads state that is already there and allocates nothing beyond
  /// the String copy in `snapshot`.
  ///
  /// `nowMs` is the audio timeline, not the wall clock, so a harness that feeds a
  /// file and a call that feeds a microphone get the same answer.
  func probability(nowMs: Double, staleMs: Double = 2500) -> Double {
    let quietMs = ringQuietMs()
    let vocalMs = ringVocalMs()
    let s = snapshot()
    // The recogniser revises about once a second, so the words are always a
    // little behind the sound. That is the tolerance this design was built to
    // have. Past `staleMs` they describe a different sentence and the text
    // feature is dropped rather than trusted.
    let textAge = nowMs - s.textMs
    let syn = (textAge <= staleMs && !s.text.isEmpty) ? Predict.syntax(s.text) : 0.4
    // The model's answer is about a specific revision. If the transcript has
    // moved on by more than one revision the answer is about a prefix, which is
    // still informative but must not be trusted as though it were current.
    let modelAge = nowMs - s.forMs
    let m = (s.p >= 0 && modelAge <= staleMs) ? s.p : -1.0
    let p = Predict.combine(syntax: syn, fall: fallDb(), vocalMs: vocalMs,
                            quietMs: quietMs, model: m)
    lastSyntax = syn
    lastFall = fallDb()
    lastModel = m
    lastQuietMs = quietMs
    lastVocalMs = vocalMs
    lastTextAge = s.text.isEmpty ? -1 : textAge
    return p
  }

  /// What went into the last answer, so a failure can be read rather than
  /// guessed at. `Subtitles.turnEndingSoon` holds the answer itself; there is no
  /// second copy of it here, because two places to read one number is how they
  /// end up disagreeing.
  private(set) var lastSyntax = 0.0
  private(set) var lastFall = 0.0
  private(set) var lastModel = -1.0
  private(set) var lastQuietMs = 0.0
  private(set) var lastVocalMs = 0.0
  /// How far behind the audio the words were, last time anybody asked. Reported
  /// rather than assumed: this engine revises about once a second, and a
  /// predictor whose text is a second stale is a different instrument from one
  /// whose text is current.
  private(set) var lastTextAge = -1.0
  var textRevisions: Int { lock.lock(); defer { lock.unlock() }; return revisions }
  private var revisions = 0

  var stats: String {
    lock.lock(); defer { lock.unlock() }
    guard modelAsks > 0 else { return "model \(modelWhy)" }
    return String(format: "model %@: %d asked, %d answered, %d failed, %.0f ms each%@",
                  modelWhy, modelAsks, modelAnswers, modelFails,
                  modelMsTotal / Double(max(1, modelAnswers)),
                  modelWhyFailed.isEmpty ? "" : "  (first failure: \(modelWhyFailed))")
  }
}

#if canImport(FoundationModels)
/// Structured output, so there is no prose to parse and no retry loop. The two
/// fields are the smallest thing that answers the question and says how hard.
@available(macOS 26.0, *)
@Generable
struct FloorJudgement {
  @Guide(description: "true only if the speaker's thought is finished and another person could start talking now without cutting them off")
  var done: Bool
  @Guide(description: "how certain, 0 to 100")
  var sure: Int
}
#endif


// ── THE RIG ──────────────────────────────────────────────────────────────────
//
// `green-metrics-can-hide-defects` and `validate-the-ruler-against-known-inputs`
// between them decide the shape of this. It is not enough to run the predictor
// and print a number it likes; the same recording has to be scored by arms that
// MUST come out worse, and by a null arm that must come out at chance, or a
// passing score says nothing about whether anything was predicted at all.
//
// ── WHERE THE GROUND TRUTH COMES FROM ────────────────────────────────────────
//
// Real speech, and the future of it. `testbed/media/real/realA.wav` is 90 s of a
// NASA interview -- a real person answering a real question, with real breaths,
// real hesitations and real sentence ends. The labels are what the speaker DID
// NEXT, which the predictor is never shown:
//
//   a gap of 700 ms or more             -- a turn end. Somebody could have spoken.
//   a gap of 250 to 700 ms they came     -- a hesitation. Speaking would have cut
//   back from                              them off mid-sentence.
//
// The predictor sees only the transcript and the energy up to the decision
// instant. Nothing it reads can see how long the silence eventually became, which
// is the one fact that would make this trivial and is exactly the fact the
// reactive gate is forced to sit and wait for.
//
// ── AND EVERY ARM IS SCORED FROM ONE PASS ────────────────────────────────────
//
// `windowed-metrics-smear-experiments`: two runs of a live recogniser over the
// same file do not produce the same transcript, so an A/B across two runs is
// comparing two transcripts as much as two predictors. So the audio is fed ONCE,
// in real time, with the model on, and every tick records the INPUTS to the
// decision -- syntax, fall, pause, and the model's standing answer. Every arm is
// then the shipping `combine` over that one trace with a different subset of its
// inputs. Identical inputs, by construction, and no rebuild between arms.
extension Predict {

  struct Tick {
    var ms: Double          // audio timeline, from samples fed -- never the wall clock
    var syntax: Double
    var fall: Double
    var vocalMs: Double
    var quietMs: Double
    /// The SHIPPING classifier's view of the same two facts, recorded only so the
    /// disagreement is visible. Nothing scores off these; see the note at
    /// `ringQuietMs` for why they stopped being the input.
    var gateVocalMs: Double
    var gateQuietMs: Double
    var model: Double       // -1 when the model has no standing answer
    var live: Double        // what the shipping path computed, for the ruler check
    var textAgeMs: Double   // how far behind the sound the words were at this tick
  }

  struct Event {
    var t0: Double          // ms at which the speaker stopped
    var gapMs: Double
    var isEnd: Bool         // true: a turn end. false: a hesitation they came back from.
  }

  // ── READING THE FILE ───────────────────────────────────────────────────────
  //
  // realA.wav carries a LIST chunk, so `data` does not start at byte 44. Walking
  // the chunks rather than assuming the canonical header is the difference
  // between speech and a header's worth of metadata read as samples.
  static func readWav(_ path: String) -> (pcm: [Float], rate: Double)? {
    guard let d = FileManager.default.contents(atPath: path), d.count > 44 else { return nil }
    var off = 12
    var rate = 48000.0
    var chans = 1
    var bits = 16
    var dataOff = -1, dataLen = 0
    while off + 8 <= d.count {
      let cid = String(bytes: d[off..<(off + 4)], encoding: .ascii) ?? ""
      let sz = Int(d[(off + 4)..<(off + 8)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
      if cid == "fmt ", off + 8 + 16 <= d.count {
        let b = off + 8
        chans = Int(d[(b + 2)..<(b + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
        rate = Double(d[(b + 4)..<(b + 8)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        bits = Int(d[(b + 14)..<(b + 16)].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
      }
      if cid == "data" { dataOff = off + 8; dataLen = min(sz, d.count - off - 8); break }
      off += 8 + sz + (sz & 1)
    }
    guard dataOff > 0, bits == 16, chans >= 1, dataLen > 0 else { return nil }
    let frames = dataLen / (2 * chans)
    var pcm = [Float](repeating: 0, count: frames)
    d.withUnsafeBytes { raw in
      let p = raw.baseAddress!.advanced(by: dataOff)
      for i in 0..<frames {
        // Unaligned on purpose: a `data` chunk following an odd-length LIST is
        // not 2-byte aligned in the file, and a plain load would trap on it.
        let v = p.advanced(by: i * 2 * chans).loadUnaligned(as: Int16.self)
        pcm[i] = Float(v) / 32768
      }
    }
    return (pcm, rate)
  }

  // ── THE LABELLER, WHICH IS NOT THE THING UNDER TEST ────────────────────────
  //
  // Deliberately NOT the shipping classifier. `DuplexGate` caps the silence it
  // will report at 450 ms -- past that the vocalisation ends and the counter
  // resets -- so it physically cannot tell a 500 ms hesitation from a four-second
  // turn end, which is the distinction this whole test is about. An instrument
  // that cannot see the event returns the same value as a real negative
  // (`blind-instruments-report-negatives`), so the labels come from a separate,
  // simple, offline detector allowed to look at the whole file at once.
  //
  // Its own honesty is printed: the voiced fraction and the two event counts. A
  // labeller that found no speech, or found silence everywhere, is one line to
  // read rather than a passing score with nothing behind it.
  static func label(_ pcm: [Float], rate: Double) -> (events: [Event], voicedFrac: Double,
                                                      note: String) {
    let frame = Int(rate * 0.010)
    let n = pcm.count / frame
    guard n > 20 else { return ([], 0, "too short") }
    var rms = [Float](repeating: 0, count: n)
    for f in 0..<n {
      var a = 0.0
      for i in (f * frame)..<((f + 1) * frame) { a += Double(pcm[i]) * Double(pcm[i]) }
      rms[f] = Float((a / Double(frame)).squareRoot())
    }
    // ── THE BAR, AND WHY IT IS TIED TO THE VOICE AND NOT TO THE ROOM ─────────
    //
    // It was `max(p10 * 3, 0.0025)`. On one of the two recordings that put the
    // bar above the mean level of the speech itself: 51% of the file "voiced",
    // and the gaps so long that a five-minute interview produced ONE turn end and
    // four hesitations. A labeller that quietly finds nothing prints the same
    // clean table as one that works.
    //
    // A voice is 25-35 dB above a room, so the bar belongs at a fixed distance
    // below the SPEECH: 26 dB under the 90th percentile, floored at three times
    // the room so a very quiet recording cannot put it inside the noise. Both
    // ends of that are printed, so the next recording that breaks it says so.
    let sorted = rms.sorted()
    let floor = sorted[max(0, sorted.count / 10)]
    let loud = sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
    let bar = max(loud / 20, floor * 3.0, 0.0015)
    var voiced = rms.map { $0 > bar }
    // A frame is 10 ms, shorter than a stop consonant and shorter than a click.
    // Fill single holes, then drop single spikes -- in that order, because the
    // reverse turns the gap inside "battery" into two utterances.
    for f in 1..<(n - 1) where !voiced[f] && voiced[f - 1] && voiced[f + 1] { voiced[f] = true }
    var clean = voiced
    for f in 1..<(n - 1) where voiced[f] && !voiced[f - 1] && !voiced[f + 1] { clean[f] = false }
    voiced = clean
    let frac = Double(voiced.filter { $0 }.count) / Double(n)

    var events: [Event] = []
    var gaps = 0
    var f = 1
    while f < n {
      guard voiced[f - 1], !voiced[f] else { f += 1; continue }
      var g = f
      while g < n && !voiced[g] { g += 1 }
      let gapMs = Double(g - f) * 10
      if gapMs >= 250 { gaps += 1 }
      // There has to have been an utterance for there to be an end of one. 700 ms
      // of voice inside the two seconds before the gap; below that the "turn" is
      // a cough and its "end" is not a handover anybody would have taken.
      var back = 0
      var k = f - 1
      while k >= 0 && (f - k) <= 200 { if voiced[k] { back += 1 }; k -= 1 }
      if Double(back) * 10 >= 700 {
        if gapMs >= 700 { events.append(Event(t0: Double(f) * 10, gapMs: gapMs, isEnd: true)) }
        else if gapMs >= 250 { events.append(Event(t0: Double(f) * 10, gapMs: gapMs, isEnd: false)) }
      }
      f = g + 1
    }
    // The tail of the file is not a turn end, it is the end of the recording.
    if let l = events.last, l.t0 + l.gapMs >= Double(n) * 10 - 20 { events.removeLast() }
    let note = String(format: "bar %.1f dB (room %.1f, speech %.1f), %d gaps over 250 ms, %d kept",
                      20 * log10(Double(bar)), 20 * log10(Double(max(floor, 1e-9))),
                      20 * log10(Double(max(loud, 1e-9))), gaps, events.count)
    return (events, frac, note)
  }

  // ── ONE REAL-TIME PASS THROUGH THE SHIPPING PATH ───────────────────────────
  //
  // The recogniser is fed at 1x on purpose. Its partials arrive about once a
  // second and this whole design has to survive that staleness; feeding faster
  // hands the predictor text that a real call never has. Under load the feed loop
  // can only slip LATE, which makes the text staler and the test harder, so three
  // other builds running on this machine cannot flatter the number.
  static func trace(_ pcm: [Float], rate: Double, subs: Subtitles,
                    gate: Audio.DuplexGate, realtime: Bool,
                    published: inout Double) -> [Tick] {
    var out: [Tick] = []
    let chunk = Int(rate * 0.120)          // the shipping subtitle thread's cadence
    let blk = 16                           // what CoreAudio hands the gate on this machine
    var i = 0
    var scratch = [Float](repeating: 0, count: chunk)
    let started = Date()
    while i + chunk <= pcm.count {
      let ms = Double(i + chunk) / rate * 1000
      // The gate first, block by block, as the render callback drives it. Nothing
      // is fed to `noteFar`: this is one person talking, which is the only case
      // the prediction is about.
      for k in stride(from: i, to: i + chunk, by: blk) {
        // `min` because a chunk is only a whole number of blocks at 48 kHz. A
        // 44.1 kHz file gives 5292 samples per chunk, and reading a full block
        // past the end of the last one is a read past the end of the recording.
        let m = min(blk, i + chunk - k)
        scratch.withUnsafeMutableBufferPointer { sp in
          for j in 0..<m { sp[j] = pcm[k + j] }
          gate.process(sp.baseAddress!, m)
        }
      }
      for j in 0..<chunk { scratch[j] = pcm[i + j] }
      let live = scratch.withUnsafeMutableBufferPointer { sp -> Double in
        subs.feedAt(sp.baseAddress!, chunk, ms: ms)
        return subs.predictAt(ms: ms)
      }
      let p = subs.predict
      // The published value is the scored value. `turnEndingSoon` is what a
      // consumer would read, `live` is what the call returned, and if they ever
      // differ then the rig is grading a number nobody can see.
      published = max(published, abs(subs.turnEndingSoon - live))
      out.append(Tick(ms: ms, syntax: p.lastSyntax, fall: p.lastFall,
                      vocalMs: p.lastVocalMs, quietMs: p.lastQuietMs,
                      gateVocalMs: gate.vocalMsNow, gateQuietMs: gate.quietMsNow,
                      model: p.lastModel, live: live, textAgeMs: p.lastTextAge))
      i += chunk
      if realtime {
        let slip = Double(i) / rate - Date().timeIntervalSince(started)
        if slip > 0 { Thread.sleep(forTimeInterval: slip) }
      }
    }
    return out
  }

  /// One arm's score: how it did on the real turn ends and on the hesitations, at
  /// one threshold, deciding `delta` ms after the speaker stopped.
  struct Score {
    var hits = 0, ends = 0, falseAlarms = 0, hesitations = 0
    var recall: Double { ends == 0 ? 0 : Double(hits) / Double(ends) }
    var faRate: Double { hesitations == 0 ? 0 : Double(falseAlarms) / Double(hesitations) }
  }

  static func score(_ ticks: [Tick], _ events: [Event], delta: Double, thr: Double,
                    useModel: Bool, flip: Bool = false) -> Score {
    var s = Score()
    for (n, e) in events.enumerated() {
      // THE NULL ARM. Same scores, same threshold, labels rotated by one event --
      // so the predictor is graded against somebody else's pause. It has to land
      // at chance, and if it does not then the events are so alike that the whole
      // measurement is measuring nothing.
      let isEnd = flip ? events[(n + 1) % events.count].isEnd : e.isEnd
      if isEnd { s.ends += 1 } else { s.hesitations += 1 }
      // The reactive rule can only answer a question it has reached: a 300 ms gap
      // never gets to 450, so the 450 ms arm is correctly silent on it. The
      // predictor is asked at `delta` whether or not the gap gets there, because
      // it does not know the gap's length -- which is the point.
      let at = e.t0 + delta
      guard let t = ticks.last(where: { $0.ms <= at }) else { continue }
      let p = combine(syntax: t.syntax, fall: t.fall, vocalMs: t.vocalMs,
                      quietMs: min(t.quietMs, delta), model: useModel ? t.model : -1)
      if p >= thr { if isEnd { s.hits += 1 } else { s.falseAlarms += 1 } }
    }
    return s
  }

  /// The arm that must come out worse. It is the rule that ships today: wait for
  /// the silence, then believe it. Nothing is predicted, so it can never be wrong
  /// about a gap it has not reached -- and it can never be right about one either.
  static func reactive(_ events: [Event], afterMs: Double) -> Score {
    var s = Score()
    for e in events {
      if e.isEnd { s.ends += 1 } else { s.hesitations += 1 }
      guard e.gapMs >= afterMs else { continue }
      if e.isEnd { s.hits += 1 } else { s.falseAlarms += 1 }
    }
    return s
  }

  /// How often the prior would arm itself in the MIDDLE of fluent speech -- not at
  /// a pause at all. The event table cannot see this and it is the cost that shows
  /// up in a real call, so it is counted separately: ticks over threshold that are
  /// not within 400 ms of any gap, per minute of the recording.
  static func spuriousPerMin(_ ticks: [Tick], _ events: [Event], thr: Double,
                             useModel: Bool) -> Double {
    guard let lastMs = ticks.last?.ms, lastMs > 0 else { return 0 }
    var n = 0
    for t in ticks {
      guard t.vocalMs > 0, t.quietMs < 120 else { continue }   // mid-speech only
      if events.contains(where: { abs($0.t0 - t.ms) < 400 }) { continue }
      let p = combine(syntax: t.syntax, fall: t.fall, vocalMs: t.vocalMs,
                      quietMs: t.quietMs, model: useModel ? t.model : -1)
      if p >= thr { n += 1 }
    }
    return Double(n) / (lastMs / 60000)
  }

  // ── THE DRIVER ─────────────────────────────────────────────────────────────
  //
  // `tk --predict-test`. Reads real speech, runs the shipping path over it at 1x,
  // and prints one table per file: what each arm did to the real turn ends and to
  // the hesitations. Exit 0 only if the predictor beat BOTH reactive arms on the
  // mistake that costs somebody their sentence, and only if the null arm came out
  // at chance.
  static func selfTest(paths: [String], seconds: Double, useModel: Bool,
                       useCase: String, budget: Double, fast: Bool) -> Never {
    var bad = false
    var ran = 0
    var decided = 0
    setvbuf(stdout, nil, _IOLBF, 0)          // so a twenty-minute run shows its work
    print("  on-device model: ", terminator: "")
    let probe = Predict(model: useModel, useCase: useCase)
    print(probe.modelWhy)

    // ── THE RULER, BEFORE THE MEASUREMENT ──────────────────────────────────
    //
    // `validate-the-ruler-against-known-inputs`: a new instrument is calibrated on
    // answers already known, INCLUDING two inputs it must rank differently. These
    // are pairs -- the same sentence finished and unfinished -- so a word list
    // that has quietly stopped being consulted cannot pass by returning one
    // constant. Costs nothing, needs no audio, and it is the half of the
    // predictor that runs on a Mac with no recogniser at all.
    let pairs: [(String, String)] = [
      ("I went to the store", "I went to the"),
      ("that is what we found", "that is what we found because"),
      ("it took about three hours", "it took about three"),
      ("yes I think so", "yes I think"),
      ("we can do that", "we can do that if"),
      ("the launch window opens tomorrow", "the launch window opens tomorrow and"),
    ]
    var wrong = 0
    for (done, notDone) in pairs where syntax(done) <= syntax(notDone) { wrong += 1 }
    print(String(format: "  the word rule ranks %d of %d finished/unfinished pairs the right way"
                 + " (\"...to the store\" %.2f vs \"...to the\" %.2f)",
                 pairs.count - wrong, pairs.count,
                 syntax(pairs[0].0), syntax(pairs[0].1)))
    if wrong > 0 {
      print("  PREDICT TEST FAILED -- the text half cannot tell a finished clause from an"
          + " unfinished one, so nothing measured below is about the words")
      exit(1)
    }

    for path in paths {
      guard let w = readWav(path) else {
        print("  COULD NOT RUN: no readable 16-bit wav at \(path)")
        print("  (testbed/media/real/fetch.sh reproduces realA.wav and realB.wav)")
        continue
      }
      var pcm = w.pcm
      let cap = Int(w.rate * seconds)
      if cap > 0 && pcm.count > cap { pcm = Array(pcm[0..<cap]) }
      let (events, frac, note) = label(pcm, rate: w.rate)
      let ends = events.filter { $0.isEnd }.count
      let hes = events.count - ends
      print(String(format: "\n  ── %@ : %.0f s, %.0f%% of it voiced, %d turn ends, %d hesitations",
                   (path as NSString).lastPathComponent,
                   Double(pcm.count) / w.rate, frac * 100, ends, hes))
      print("     labeller: " + note)
      // PRECONDITIONS, BEFORE ANY SCORE. A labeller that found nothing ranks
      // identically to a predictor that is perfect, and both print a clean table.
      if ends < 5 || hes < 5 {
        print("  COULD NOT RUN: too few events to say anything (\(ends) ends, \(hes) hesitations)")
        bad = true; continue
      }
      // ── AND HOW FINE A DIFFERENCE THIS FILE CAN EVEN RESOLVE ────────────────
      //
      // The verdict turns on the real arm beating the null arm by 12 points. With
      // ten turn ends one event is TEN points, so a file that small cannot answer
      // the question either way -- two hits against two hits is not a tie, it is
      // no measurement. It still runs and still prints every number, because
      // hiding an underpowered table is how an underpowered table gets quoted;
      // it just does not get to cast a vote. 15 ends is where one event stops
      // being larger than the effect being looked for.
      let underpowered = ends < 15

      let subs = Subtitles(prefer: "apple", predictModel: useModel, predictUseCase: useCase)
      // The recogniser comes up asynchronously and its speech assets may need
      // installing on first use. Feeding a file into an engine that is not up yet
      // measures the predictor with no words at all.
      var waited = 0.0
      while !subs.available && waited < 20 { Thread.sleep(forTimeInterval: 0.25); waited += 0.25 }
      let gate = Audio.DuplexGate()
      gate.cfg = Audio.gate
      var published = 0.0
      let ticks = trace(pcm, rate: w.rate, subs: subs, gate: gate, realtime: !fast,
                        published: &published)
      ran += 1

      // ── VALIDATE THE RULER ──────────────────────────────────────────────────
      //
      // The arms below are `combine` recomputed offline over the recorded inputs.
      // That is only a test of the shipping path if the recorded inputs really do
      // reproduce what the shipping path computed live, so it is asserted rather
      // than assumed: every tick, recomputed, must equal the value `Subtitles`
      // published at the time.
      var worst = 0.0
      for t in ticks {
        let r = combine(syntax: t.syntax, fall: t.fall, vocalMs: t.vocalMs,
                        quietMs: t.quietMs, model: t.model)
        worst = max(worst, abs(r - t.live))
      }
      let sawWords = ticks.contains { $0.syntax != 0.4 }
      let withText = ticks.filter { $0.textAgeMs >= 0 }
      let meanAge = withText.isEmpty ? -1
        : withText.reduce(0.0) { $0 + $1.textAgeMs } / Double(withText.count)
      print(String(format: "     engine %@, %d ticks, offline scorer differs from the live path by %.1e",
                   subs.engine, ticks.count, worst))
      print(String(format: "     words: %d revisions, on %.0f%% of ticks, %.0f ms behind the sound",
                   subs.predict.textRevisions,
                   Double(withText.count) / Double(max(1, ticks.count)) * 100, meanAge))
      // ── WAS THE MODEL EVER ACTUALLY THERE WHEN IT MATTERED? ────────────────
      //
      // An answer that arrives after the transcript has moved on is about a
      // different sentence, and `probability` drops it. So "the model is on" and
      // "the model had an opinion at the moment of decision" are two different
      // claims and only the second one can change a number. Both are printed.
      let withModel = ticks.filter { $0.model >= 0 }.count
      print(String(format: "     %@  --  a standing answer on %.0f%% of ticks",
                   subs.predict.stats,
                   Double(withModel) / Double(max(1, ticks.count)) * 100))
      // NAMED, NOT FIXED. `Audio.DuplexGate` belongs to another file; this line
      // exists so the disagreement is on the record with a number next to it.
      let speaking = ticks.filter { $0.vocalMs > 300 }
      let gateBlind = speaking.filter { $0.gateVocalMs == 0 }.count
      print(String(format: "     the shipping classifier saw no vocalisation at all on %d of %d"
                   + " ticks where this file's own energy trace had %@",
                   gateBlind, speaking.count, "300 ms or more of speech behind it"))
      if published > 1e-12 {
        print(String(format: "  COULD NOT RUN: what Subtitles publishes differs from what it"
                     + " computed by %.1e -- the rig is grading a number nobody can read", published))
        bad = true; continue
      }
      if worst > 1e-9 {
        print("  COULD NOT RUN: the offline scorer is not the shipping function")
        bad = true; continue
      }
      if !sawWords {
        print("  COULD NOT RUN: the recogniser produced no words at all, so only the"
            + " energy half was ever exercised")
        bad = true; continue
      }

      if ProcessInfo.processInfo.environment["KIN_PREDICT_DUMP"] != nil {
        for e in events {
          guard let t = ticks.last(where: { $0.ms <= e.t0 + 250 }) else { continue }
          fputs(String(format: "  %@ t=%.1fs gap=%.0f syn=%.2f fall=%.1f vocal=%.0f quiet=%.0f gate=%.0f/%.0f model=%.2f p=%.2f\n",
                       e.isEnd ? "END " : "hes ", e.t0 / 1000, e.gapMs, t.syntax, t.fall,
                       t.vocalMs, t.quietMs, t.gateVocalMs, t.gateQuietMs, t.model,
                       combine(syntax: t.syntax, fall: t.fall, vocalMs: t.vocalMs,
                               quietMs: min(t.quietMs, 250), model: t.model)), stderr)
        }
      }

      func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
      }
      /// `at` is when the arm decides, in ms after the speaker stopped. Lower is
      /// earlier and earlier is the entire point.
      func row(_ name: String, _ s: Score, _ at: Double, _ extra: String = "") {
        print(String(format: "     %@%2d/%-2d (%3.0f%%)      %3d/%-3d (%3.0f%%)       t0+%3.0f ms  %@",
                     pad(name, 28), s.hits, s.ends, s.recall * 100,
                     s.falseAlarms, s.hesitations, s.faRate * 100, at, extra as NSString))
      }
      // ── WHAT IS EACH FEATURE ACTUALLY WORTH? ───────────────────────────────
      //
      // Printed before any verdict, because a combined score that comes out at
      // chance says nothing about WHICH half is carrying nothing. Two rounds of
      // this file's history were spent on a feature that was a constant wearing a
      // unit, and both times the combined number looked merely disappointing.
      func sep(_ name: String, _ f: (Tick) -> Double) {
        var e = 0.0, en = 0, h = 0.0, hn = 0
        for ev in events {
          guard let t = ticks.last(where: { $0.ms <= ev.t0 + 250 }) else { continue }
          if ev.isEnd { e += f(t); en += 1 } else { h += f(t); hn += 1 }
        }
        guard en > 0, hn > 0 else { return }
        print(String(format: "       %@  before a turn end %.2f, before a hesitation %.2f",
                     pad(name, 16), e / Double(en), h / Double(hn)))
      }
      print("     what each half is worth on its own:")
      sep("words", { $0.syntax })
      sep("falling level", { $0.fall })
      sep("model", { $0.model })

      // ── COMPARED AT THE SAME COST, NOT AT THE SAME THRESHOLD ───────────────
      //
      // A threshold is a dial, and comparing two arms at one setting of it
      // compares the settings as much as the arms. So a false-alarm BUDGET is
      // fixed and each arm reports the recall it reaches inside it.
      //
      // The budget defaults to 15%, and it is a product decision stated out loud
      // rather than a number the data chose. Predicting a turn end that does not
      // happen arms the gate open under somebody mid-sentence; missing one costs
      // a beat that the reactive gate underneath still recovers, because it is
      // still there and this only arms it early. Scoring at the SHIPPING rule's
      // own 50% false-alarm rate maximises recall and lands every arm, including
      // the null one, in the same noise -- which is what the first run of this
      // did, and it read as a tie rather than as the wrong question.
      print(String(format: "     every arm below reaches for the most turn ends it can find"
                   + " while getting at most %.0f%% of hesitations wrong", budget * 100))
      func atBudget(_ delta: Double, _ useM: Bool, _ flip: Bool) -> (Score, Double) {
        var best = Score(), bestThr = 1.0
        var t = 0.02
        while t <= 0.98 {
          let s = score(ticks, events, delta: delta, thr: t, useModel: useM, flip: flip)
          if s.faRate <= budget + 1e-9, s.recall > best.recall { best = s; bestThr = t }
          t += 0.01
        }
        return (best, bestThr)
      }
      // ── AND THE REACTIVE FAMILY HAS A DIAL TOO: HOW LONG IT WAITS ──────────
      //
      // Comparing against the 450 ms rule alone would be comparing a tuned arm to
      // an untuned one. The reactive rule can buy any false-alarm rate it likes by
      // waiting longer -- that is the ONLY thing it can do -- so the fair question
      // is what it has to wait to reach the same 15%, and how much earlier the
      // prediction gets there. Past 700 ms its false alarms are zero by the way
      // the labels are defined, so that end of the curve is not evidence and the
      // sweep stops short of it.
      var reactiveWait = 700.0
      var reactiveAt = Score()
      var waitMs = 250.0
      while waitMs <= 690 {
        let s = reactive(events, afterMs: waitMs)
        if s.faRate <= budget + 1e-9 { reactiveWait = waitMs; reactiveAt = s; break }
        waitMs += 10
      }
      print("     arm                         ends called       sentences cost        decides")
      row("reactive, 450 ms silence", reactive(events, afterMs: 450), 450, "<- what ships today")
      if reactiveAt.ends > 0 {
        row(String(format: "reactive, inside %.0f%%", budget * 100), reactiveAt, reactiveWait,
            String(format: "waits %.0f ms", reactiveWait))
      } else {
        print(String(format: "     reactive, inside %.0f%%         -- no wait under 700 ms gets there --",
                     budget * 100))
      }
      // ── THE INSTANTS WORTH ASKING ABOUT ────────────────────────────────────
      //
      // t0        the last word. 450 ms before the shipping rule decides.
      // t0+250    half the shipping rule's wait.
      // t0+450    the SAME instant the shipping rule decides, so the comparison
      //           is purely "does knowing the words cost fewer sentences".
      // t0+600    the same instant as the reactive wait that reaches this error
      //           budget on its own.
      //
      // The transcript is most of a second behind the sound, so the full stop
      // that says a clause ended does not exist yet at t0 -- which is why the
      // late instants are not padding. They are where the lead actually is.
      let arms: [(String, Double, Bool, Bool)] = [
        ("predicted at the last word", 0, false, false),
        ("predicted at 250 ms", 250, false, false),
        ("predicted at 450 ms", 450, false, false),
        ("predicted at 600 ms", 600, false, false),
        ("+ model, at 250 ms", 250, true, false),
        ("+ model, at 450 ms", 450, true, false),
        ("+ model, at 600 ms", 600, true, false),
        ("NULL: labels rotated", 450, false, true),
      ]
      var best = Score(), null = Score(), bestThr = 1.0
      for (name, d, m, f) in arms {
        let (s, t) = atBudget(d, m, f)
        row(name, s, d, String(format: "at p>=%.2f", t))
        // The arm the verdict is about: the shipping rule's own instant, with no
        // model, because the model is an enhancement and cannot be the mechanism.
        if name == "predicted at 450 ms" { best = s; bestThr = t }
        if name.hasPrefix("NULL") { null = s }
      }
      print(String(format: "     at p>=%.2f it arms itself mid-sentence %.1f times a minute",
                   bestThr, spuriousPerMin(ticks, events, thr: bestThr, useModel: false)))

      // ── THE VERDICT ─────────────────────────────────────────────────────────
      //
      // Two questions, and the first one is whether there is any signal at all.
      var why: [String] = []
      // THE RULER. If rotating the labels scores the same, the two kinds of pause
      // are indistinguishable in this recording and every number above is noise.
      if best.recall - null.recall < 0.12 {
        why.append(String(format: "rotating the labels scores %.0f%% against %.0f%% -- inside"
                          + " the budget this is measuring nothing",
                          null.recall * 100, best.recall * 100))
      }
      // And the second: is it early? A prediction that needs to wait longer than
      // the silence rule does is not a prediction, it is a slower silence rule.
      if reactiveAt.ends > 0, reactiveWait <= 450 {
        why.append(String(format: "simply waiting %.0f ms reaches the same budget, which is no"
                          + " later than this decides", reactiveWait))
      }
      if best.recall < 0.25 {
        why.append(String(format: "inside a %.0f%% error budget it finds only %.0f%% of the turn"
                          + " ends -- too few to arm anything", budget * 100, best.recall * 100))
      }
      if underpowered {
        print(String(format: "     TOO FEW TO DECIDE: %d turn ends, so one event is %.0f points"
                     + " and nothing above resolves%@", ends, 100.0 / Double(ends),
                     why.isEmpty ? "" : " -- it would otherwise have failed: " + why.joined(separator: "; ")))
      } else if why.isEmpty {
        decided += 1
        print("     PASSED")
      } else {
        decided += 1
        print("     FAILED: " + why.joined(separator: "; ")); bad = true
      }
    }
    if ran == 0 {
      print("\n  PREDICT CHECK COULD NOT RUN -- no usable recordings")
      exit(2)
    }
    if decided == 0 {
      print("\n  PREDICT TEST COULD NOT DECIDE -- every recording was too short to hold"
          + " enough turn ends. Feed it more audio, not a lower bar.")
      exit(2)
    }
    print(bad ? "\n  PREDICT TEST FAILED"
              : "\n  PREDICT TEST PASSED -- a turn end is called before the silence that would"
                + " have proved it, and a hesitation is not")
    exit(bad ? 1 : 0)
  }
}
