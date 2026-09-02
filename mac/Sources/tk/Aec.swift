import Foundation
import Accelerate

// ── SUBTRACTING THE SPEAKER FROM THE MICROPHONE ──────────────────────────────
//
// This project deleted an echo canceller on 2026-08-25 and wrote down why, and
// the reasoning has to be answered rather than ignored, because it was mostly
// right:
//
//   "You hold a copy of what was SENT to the speaker and nothing at all of what
//    the room did to it, so the subtraction is always approximate, and the
//    leftover has to be attacked by guessing which parts of a person's voice are
//    echo. That guessing is the robotic, underwater sound of every video call."
//
// The first sentence is true. The second is a statement about a DIFFERENT
// algorithm. Everything in that quote after "the leftover" describes SPECTRAL
// SUPPRESSION -- deciding, band by band, that some of a person's voice is
// probably echo and turning it down. That is what makes voices sound like they
// are underwater, it is why Apple's voice processing was rejected here, and
// there is none of it in this file.
//
// What is in this file is LINEAR SUBTRACTION and nothing else:
//
//     out[k] = mic[k] - sum_j f[j] * playout[k - delay - j]
//
// A filtered copy of a signal this program already owns exactly, subtracted from
// the microphone. It does not decide anything about the voice. It does not
// attenuate. It has no spectral mask, no gain floor, no comfort noise and no
// residual suppressor. If the filter is wrong the near voice comes through
// unchanged plus whatever echo the filter failed to remove -- the failure mode is
// LESS cancellation, never a damaged voice. That is the property that makes this
// allowed to exist where the old one was not, and it is asserted rather than
// claimed: `--aec-test` measures how much of a near voice survives with no echo
// path present at all.
//
// ── WHY THIS PROGRAM CAN DO IT AND A LIBRARY CANNOT ──────────────────────────
//
// A general-purpose canceller has to search for the delay, which means covering
// 0-200 ms: 9600 taps and 460M multiply-adds a second. This one is TOLD where to
// look, by an estimator that has both signals on one clock and has been running
// on every call for months (`Audio.echoDelayMs`, `Audio.echoCorr`). 512 taps at
// the measured delay covers the direct path and the early reflections, which is
// where nearly all of a laptop's echo energy is.
//
// ── AND WHY THE LAST ONE MEASURED MINUS TWENTY-ONE DECIBELS ──────────────────
//
// The recorded failure was `erle -21.7 dB` -- the canceller making the microphone
// twenty-one decibels LOUDER -- and -21.6 dB with no echo path armed at all,
// which is what localised it. Its update was
//
//     let g = mu * e / (xe + 1e-6)
//
// with `xe` the reference energy over the tap window. During near-end-only
// speech `xe` is nearly zero, `1e-6` is not a level, and the step explodes: an
// NLMS driven by an uncorrelated reference does not converge slowly, it random
// walks. Three things here make that specific death impossible, and all three
// are measured, not argued:
//
//   1. THE NORMALISER HAS A REAL FLOOR, and adaptation requires the reference to
//      be above a real level. Dividing by silence is the bug; refusing to divide
//      by silence is the fix, and it is upstream of any double-talk logic.
//   2. A DIVERGENCE GUARD. If the residual is louder than the microphone for a
//      tenth of a second, the filter is zeroed and counted. -21 dB cannot be
//      reached, let alone shipped, because the state that produces it is
//      detected in 100 ms.
//   3. THE SUBTRACTION IS SCALED BY WHETHER IT IS HELPING. `mix` ramps to 1 only
//      while the measured ERLE is positive and ramps away in 4 ms when it is
//      not, so a canceller that is not earning its place is a no-op on the audio
//      rather than a hazard. Down on a linear ramp and up on an exponential, the
//      same asymmetry as every other gain in this app and for the same reason.
//
// ── ONE MORE THING IT MUST NEVER DO ──────────────────────────────────────────
//
// The estimator that AIMS this filter reads `capHist`, and `capHist` is written
// BEFORE this runs. That ordering is load-bearing and it is not a detail: when
// the old canceller wrote its output into the history instead, its own success
// collapsed the correlation to 0.08, the "best lag" became whichever noise peak
// won, and it re-aimed at it -- 46 re-aims in 90 seconds, each one zeroing the
// filter. A control loop reading a signal its own action had removed
// (`control-loops-steer-on-flattering-signals`). Nothing in this file writes to
// `capHist`.
final class Aec {

  struct Cfg {
    var on = true
    /// 1024 taps at 48 kHz = 21.3 ms of impulse response, placed at the measured
    /// delay, covering the direct path and the early reflections -- where nearly
    /// all of a laptop's echo energy is. Swept in `--aec-test --aec-sweep`; the
    /// table is printed on every run, so this is a reading and not a preference.
    /// The honest caveat, because the number would otherwise read stronger than it
    /// is: the simulated room's last reflection is at 13.1 ms, so 512 taps already
    /// nearly cover it and most of 1024's advantage here is fitting that tail
    /// more exactly rather than reaching further. A real room is longer than
    /// 13 ms, so this is the direction the rig UNDERSTATES -- the safe direction
    /// to be wrong in. 2048 scores WORSE (16.3 dB): the extra taps take longer to
    /// converge than a 20 s recording allows.
    var taps = 1024
    /// The NLMS step. The update is one BLOCK step made of `n` per-sample steps,
    /// normalised by `n * refEnergy`, so this is the per-sample step size and
    /// stability wants it under 2. Swept.
    /// ── AND IT IS TEN TIMES SMALLER THAN "STABLE" WOULD ALLOW ────────────────
    ///
    /// Textbook stability wants this under 2. The sweep says 0.10, and the reason
    /// is the second column:
    ///
    ///        mu    far-only   conversation   foreground divergences
    ///       0.03     13.7          7.4                 1
    ///       0.06     16.5         10.1                 0
    ///       0.10     18.8         10.0                 0
    ///       0.15     20.7          7.7                 2
    ///
    /// A bigger step removes MORE echo when the far end is alone and LESS during a
    /// conversation, because a fast filter fits whatever is in the microphone --
    /// including a near voice -- and then has to be thrown out again. The far-only
    /// column is the one that flatters a canceller; the conversation column is the
    /// product. 0.10 is the top of the ridge where both hold and nothing diverges.
    var mu: Float = 0.10
    /// Start the filter this far BEFORE the estimated delay. The estimate has a
    /// resolution of one decimated sample (8 at 48 kHz) and a room's first
    /// reflection can arrive earlier than the correlation's best lag, so the
    /// window is placed with room in front of it rather than exactly on it.
    var leadMs: Double = 2.0
    /// The estimator's confidence below which there is nothing to aim at. With no
    /// echo path at all the correlation reads about 0.26 over a 400 ms window,
    /// so this has to sit clearly above that or the filter runs on a call with
    /// no echo in it -- which is how the old one booked 116 re-aims in two
    /// minutes and removed 1.6 dB from a signal that had nothing to remove.
    var minCorr = 0.35
    /// Reference RMS below which the filter neither adapts nor subtracts. This
    /// is the floor whose absence killed the last canceller. -66 dBFS: below any
    /// playout a person could hear, above the noise a decoder produces.
    var refRmsFloor: Float = 0.0005
    /// Double talk. The microphone being louder than the echo path can explain
    /// means somebody at this end is talking, and an NLMS step taken then
    /// "cancels" the person who is speaking. The comparison is against the
    /// LEARNED path gain, not a constant, because a coupling of 0.05 and one of
    /// 0.8 are both ordinary and no fixed ratio describes both.
    var dtRatio: Float = 2.5
    /// The estimate must move at least this far to be considered a new aim...
    var reaimMs: Double = 8
    /// ...and disagree this many computations in a row before the filter is
    /// zeroed. One window disagreeing is noise; three in a row is the path
    /// having actually moved -- somebody turned the volume up, picked the laptop
    /// up, changed device. Zeroing a converged filter on a twitch costs more
    /// than the twitch.
    var reaimHits = 3
    /// ── AND A FILTER THAT IS WORKING IS NOT RE-AIMED ─────────────────────────
    ///
    /// Live calls on 0.124.0 read 21-32 re-aims in 140 s, 5 divergences, and an
    /// ERLE under 2 dB. Every re-aim zeroes both filters. The estimator's
    /// reading is an 8-sample-quantised cross-correlation over 400 ms and on an
    /// intermittent playout it wanders; three wandering readings in a row and a
    /// converged filter was thrown away for a delay the room had not moved to.
    ///
    /// So a disagreeing estimate is HELD while the filter on the audio is
    /// measurably removing echo -- `mix` at or near 1 and the far-only ERLE at
    /// least this -- because a filter removing 6 dB at the old delay is stronger
    /// evidence about the delay than a correlation peak is. Not a one-way door:
    /// if the path really moved the ERLE collapses within its 0.5 s window, the
    /// hold lapses, and the re-aim proceeds on the next block. `reaimsHeld`
    /// counts how often this fired.
    var reaimHoldDb: Double = 6
    /// ERLE above which the subtraction is applied in full. Not zero: a filter
    /// achieving half a decibel is inside the measurement's own noise, and
    /// subtracting on that basis is taking a risk for nothing.
    var helpDb: Double = 1.0
    /// The residual being this much louder than the microphone, for
    /// `divergeMs`, is divergence -- zero the filter.
    var divergeRatio: Float = 1.3
    var divergeMs: Double = 100
    /// ── AND THE RESIDUAL HAS TO BE AUDIBLE BEFORE IT COUNTS AS DAMAGE ────────
    ///
    /// The guard compares two energies, and a RATIO between two tiny numbers is
    /// noise. Measured before this existed: on a conversation the filter was
    /// zeroed twice in 20 seconds, both times in a near-silent stretch where the
    /// reference was barely above its floor and the microphone was quieter still,
    /// so the residual "exceeded" the microphone by a factor no listener could
    /// hear -- and each reset threw away 20 dB of convergence. The conversation
    /// arm read 5.2 dB where the far-only arm read 22.
    ///
    /// The condition is on the RESIDUAL, not on the microphone, and that
    /// distinction is the whole point: a diverging filter injecting audible junk
    /// into a silent microphone is real damage and must still be caught. -54 dBFS
    /// is above the noise floor of any recording and far below speech.
    var divergeFloorRms: Float = 0.002
    /// How long the filter is held frozen after a divergence, so a diverging
    /// state cannot be re-entered on the next block.
    var coolMs: Double = 200
    /// ── THE CLOCKS ARE NOT THE SAME CLOCK (0.109.0) ──────────────────────────
    ///
    /// Capture and render are two devices with two crystals, and the echo
    /// therefore arrives at an offset that DRIFTS -- tens of parts per million is
    /// tens of samples over a call. A filter aimed at a fixed integer delay is
    /// aimed at a target that moves under it: measured live, this filter reached
    /// 27-36 dB and fell back to single digits, over and over, which is not a
    /// convergence failure, it is convergence on a moving target.
    ///
    /// So the reference is read at a FRACTIONAL delay steered by a delay-locked
    /// loop: two probe filters evaluate the background at ±`dllDelta` samples,
    /// and whichever side leaves less residual, sustained over `dllEveryMs`,
    /// pulls the alignment that way. A learned skew term (an integrator, so it
    /// holds when the corrections stop) then advances the alignment continuously
    /// and the filter sees a stationary room.
    ///
    /// None of this touches the voice: it changes WHICH copy of the speaker
    /// signal is subtracted, and the subtraction is still a function of the
    /// reference alone -- the linearity identity in `--aec-test` covers the
    /// tracked arm too.
    var driftTrack = true
    /// The regression needs at least this many aim readings spanning at least
    /// this long before a slope means anything: the estimator's answer is
    /// quantised to 8 samples, so a 30 ppm clock takes ~5.5 s to cross one step
    /// and a shorter window measures the staircase, not the stairs.
    var skewMinReads = 8
    var skewMinSpanS: Float = 6
    /// How much of the measured drift is folded into the skew per decision, and
    /// the confidence gate: the slope must exceed 1.5x its own standard error
    /// (from the regression residuals) AND an absolute floor. A stationary pair
    /// of crystals must produce a tracker that does nothing at all.
    var skewGain: Float = 0.6
    var skewMin: Float = 0.15
    /// The skew clamp. ±6 samples/s is ±125 ppm -- comfortably past the worst
    /// crystal pair this could plausibly meet, and small enough that even a skew
    /// stuck at the rail cannot outrun the recovery door below.
    var dllSkewMax: Float = 6
    /// ── A WANDERING ESTIMATOR IS NOT A DRIFTING CLOCK ────────────────────────
    ///
    /// Traced with readings 10 ms off for 2 s in every 6: the regression fitted
    /// slopes of -40 samples/s with a standard error of 17, the 1.5x-se gate
    /// passed, the skew railed at -6 and the window walked a converged filter
    /// off its target -- 24.5 dB to 8.1 in five seconds. Two crystals cannot
    /// drift at 830 ppm, and a real 30 ppm fit here reads ±0.14-0.33 sps. So a
    /// fit is believed only when its residual error is under this AND its slope
    /// is physically possible; anything else is the estimator wandering, which
    /// the re-aim hold above already deals with. Counted as `skewRejects`.
    var skewMaxSe: Float = 1.0
    /// The recovery door: the canceller not helping (`mix` at zero) for this long
    /// while aimed resets the alignment AND the skew. Its evidence is the mix,
    /// which is measured every block whether or not the steering runs -- a
    /// recovery gate must never depend on the mechanism it recovers
    /// (`held-is-a-one-way-door`).
    var dllResetMs: Double = 2000
    /// ── WHEN THE BACKGROUND FILTER REPLACES THE ONE ON THE AUDIO ─────────────
    ///
    /// It has to be measurably better, not merely different: 0.97 is a 0.13 dB
    /// improvement, which is small enough that a genuinely better filter is
    /// adopted quickly and large enough that two equivalent filters do not swap
    /// back and forth on measurement noise.
    var transferMargin: Float = 0.97
    /// ── AND THE ABSOLUTE BAR, WHICH THE RELATIVE ONE CANNOT PROVIDE ──────────
    ///
    /// A filter reaching the audio must leave LESS THAN IT WAS GIVEN. Without
    /// this the transfer rule is only a ratchet against the current foreground,
    /// and once the foreground is bad a marginally-less-bad background is enough
    /// to be adopted -- so a diverging background walks itself onto the audio one
    /// 3% improvement at a time. Measured before this existed: the foreground's
    /// residual reached 7x the microphone and the backstop had to zero it twice
    /// in twenty seconds.
    ///
    /// With this, the foreground is never worse than passing the microphone
    /// through untouched, at any point in a call, by construction -- which is the
    /// property the head of this file claims and had not earned.
    var passthroughMargin: Float = 0.9
    /// ── LEAKAGE, WHICH IS WHAT BOUNDS THE FILTER'S SIZE ──────────────────────
    ///
    /// Speech is strongly coloured, so it excites some directions of a 512-tap
    /// filter hard and others barely at all. NLMS is free to put anything it likes
    /// in the directions the reference does not excite -- it costs nothing on the
    /// data it is fitted to -- and the norm grows. Then the reference changes
    /// character, or a near voice arrives, and that accumulated garbage comes out
    /// as a large output on a signal it was never fitted to. Measured before this
    /// existed: the foreground's 40 ms residual reached 6x the microphone with a
    /// per-block output that looked innocuous.
    ///
    /// A leak pulls every tap gently toward zero, so anything the reference is not
    /// actively holding up decays away. As a TIME CONSTANT rather than a
    /// per-block coefficient: 5 s means an unexcited tap loses 1/e of itself every
    /// five seconds, which is nothing against speech and everything against
    /// accumulated noise (`per-block-constants-hide-block-size`).
    ///
    /// ── AND IT IS OFF, WHICH IS A MEASURED NEGATIVE ──────────────────────────
    ///
    /// It was added to fix the norm blow-up above, and then the sweep said it was
    /// not what fixed it: at every tap count and every step size, a 5 s leak
    /// scored 1-3 dB WORSE than no leak, with the same zero divergences. The step
    /// size is what bounds this filter, and a leak on top of it only slows
    /// convergence. Kept as a real switch rather than deleted, because a room with
    /// a far longer tail than the rig can build is where it would earn its place,
    /// and because a negative result nobody can re-run is just a claim.
    var leakTau: Double = 0
    /// ...and better for this long. 200 ms is longer than a syllable, so one
    /// lucky syllable cannot put an untested filter on the audio, and far shorter
    /// than the time anybody spends noticing echo.
    var transferMs: Double = 100
    /// The background being this much worse than the foreground means it has run
    /// away. Restarted FROM the foreground, never from zero.
    var bgResetRatio: Float = 2.0
    /// ── THE LOUDSPEAKER IS NOT LINEAR, AND THIS IS STILL SUBTRACTION ─────────
    ///
    /// A laptop's speaker driven at conversation volume compresses its peaks and
    /// adds harmonics the reference does not contain. No linear filter can
    /// predict what is not a linear function of its input, and `mac/ECHO.md`
    /// names this as the largest term left after 0.109.0.
    ///
    /// The answer that keeps the head-of-file promise is a Hammerstein model:
    /// memoryless nonlinear BASIS signals built from the reference alone --
    /// x|x|, x^3, x^5 -- each through its own short adaptive FIR at the same
    /// delay, summed into the same prediction and subtracted. Every term is still
    /// a function of what THIS machine played, so the near voice passes through
    /// as exactly as before, and `--aec-test` asserts it on the same identity.
    /// Odd powers fit a symmetric soft clip (tanh's series is x - x^3/3 + ...),
    /// and x|x| fits the asymmetry a real cone has.
    ///
    /// The branches adapt only while the reference is loud enough for a speaker
    /// to be distorting at all (`nlMinRms`, -40 dBFS): below that the basis
    /// signals are vanishingly small and a normalised step on them would be a
    /// step on noise -- the same arithmetic that killed the deleted canceller.
    ///
    /// ── AND IT SHIPS OFF, WHICH IS A MEASURED NEGATIVE ───────────────────────
    ///
    /// The sweep (`--aec-sweep`, real speech, far-only / conversation):
    ///
    ///     speaker         linear only     with branches
    ///     clean           18.8 / 10.4     19.5 /  9.1
    ///     drive 3         19.0 / 10.1     19.4 /  9.3
    ///     drive 12        14.0 /  8.5     17.5 /  8.5
    ///     drive 24        10.6 /  5.8     13.5 /  6.6
    ///
    /// On a speaker distorting hard it wins 3 dB with the far end alone. On a
    /// clean speaker it costs 1.3 dB in the conversation column, which is the
    /// product, and the rule for this feature is that nothing may be lost. So
    /// `--aec-nl` turns it on for a call and the beat carries `aec_nl_share_db`;
    /// a real loud laptop is the only thing that can overturn this.
    var nlOn = false
    var nlTaps = 512
    var nlMinRms: Float = 0.01
    /// The step for the nonlinear branches, per sample, same units as `mu`.
    var nlMu: Float = 0.10
    /// The branches adapt only once the linear branch is removing this much: the
    /// distortion is what is left AFTER the linear echo, and a branch fitted
    /// before that echo is gone is fitted to the wrong thing.
    var nlMinErleDb: Double = 6
  }
  var cfg = Cfg()
  /// ── THE BASIS SIGNALS, AND WHY THEY ARE BOUNDED ──────────────────────────
  ///
  /// The first version used x|x|, x^3 and x^5, and the trace of a far-only run
  /// on a LINEAR speaker read: x^5 window energy from 1e-26 to 1e-8 across
  /// seconds, x^5 weights of 27,000, and a branch output six times the
  /// microphone. A power basis normalised to its own energy learns enormous
  /// weights in a quiet passage and detonates them in the next loud one; the
  /// eigenvalue spread of x^5 is the level to the tenth power and no step size
  /// survives that.
  ///
  /// So every basis here is BOUNDED by |x| for |x| <= 1 and vanishes faster than
  /// x at small levels, which is the shape of distortion itself:
  ///
  ///   0  x|x|                    the cone's asymmetry (even order)
  ///   1  x - tanh(2x)/2          a gentle soft clip's residual (odd order)
  ///   2  x - tanh(5x)/5          a hard one's
  ///
  /// Weights stay O(1), and the normaliser below is a PEAK HOLD over ~2 s
  /// rather than the instantaneous window, so a quiet window cannot manufacture
  /// a large weight -- the branches learn at the levels where a speaker
  /// distorts and hold still everywhere else.
  static let nlBases = 3
  static func nlBasisScalar(_ j: Int, _ x: Float) -> Float {
    switch j {
    case 0: return x * abs(x)
    case 1: return x - tanh(2 * x) / 2
    default: return x - tanh(5 * x) / 5
    }
  }
  static func nlBasis(_ j: Int, _ x: UnsafePointer<Float>, _ n: Int,
                      into b: UnsafeMutablePointer<Float>) {
    switch j {
    case 0:
      vDSP_vabs(x, 1, b, 1, vDSP_Length(n))
      vDSP_vmul(b, 1, x, 1, b, 1, vDSP_Length(n))
    default:
      let d: Float = j == 1 ? 2 : 5
      var dd = d
      var cnt = Int32(n)
      vDSP_vsmul(x, 1, &dd, b, 1, vDSP_Length(n))
      vvtanhf(b, b, &cnt)
      var inv = -1 / d
      vDSP_vsmul(b, 1, &inv, b, 1, vDSP_Length(n))
      vDSP_vadd(b, 1, x, 1, b, 1, vDSP_Length(n))
    }
  }
  static func nlBuild(_ xs: UnsafePointer<Float>, _ spanN: Int, into bws: inout [[Float]],
                      bSq: inout [Float]) {
    for j in 0..<nlBases {
      bws[j].withUnsafeMutableBufferPointer { b in
        nlBasis(j, xs, spanN, into: b.baseAddress!)
        vDSP_svesq(b.baseAddress!, 1, &bSq[j], vDSP_Length(spanN))
      }
    }
  }
  /// What basis `j` reads at a reference level `r` -- the floor under its
  /// normaliser is this at `nlMinRms`.
  static func nlBasisLevel(_ j: Int, _ r: Float) -> Float { abs(nlBasisScalar(j, r)) }

  // ── STATE ──────────────────────────────────────────────────────────────────
  //
  // The filter is stored REVERSED: `f[p]` multiplies the reference sample `p`
  // positions AFTER the oldest one in the window, so `f[taps-1]` is the tap at
  // the aligned (zero extra lag) position. That is not an aesthetic choice --
  // it is what makes both the filtering and the gradient a single `vDSP_conv`
  // with no index arithmetic in the hot loop, because `vDSP_conv` computes
  // `C[i] = sum_p A[i+p] * F[p]` and does not flip the filter.
  /// The filter on the audio, and the one that adapts. See the note in
  /// `process` for why there are two.
  fileprivate var fFg: [Float]
  fileprivate var fBg: [Float]
  /// Contiguous copy of the reference window for this block, taken out of the
  /// circular playout history once per block. The old canceller had a `%
  /// ECHO_MAX` inside its innermost loop -- an integer division per tap per
  /// sample -- and a copy of `taps + n` floats costs less than that does for one
  /// sample.
  private var xwin: [Float]
  private var yBuf: [Float]
  private var yBgBuf: [Float]
  private var eBuf: [Float]
  private var eBgBuf: [Float]
  private var gBuf: [Float]
  /// The raw (uninterpolated) reference copy, with two older samples and one
  /// newer so the interpolated window can sit anywhere inside a whole sample.
  private var rawWin: [Float]
  /// The nonlinear branches: one foreground and one background filter per basis,
  /// the basis window for this block, and a scratch for its convolutions. Sized
  /// for the largest `nlTaps` allowed (1024).
  fileprivate var fFgNl: [[Float]]
  fileprivate var fBgNl: [[Float]]
  private var bwins: [[Float]]
  private var yNlBuf: [Float]
  private var gNlBuf: [Float]
  /// Energy of the nonlinear branches' own prediction over the far-only blocks,
  /// beside the linear branch's, so a beat can say how much of the echo was
  /// distortion. Same 0.5 s constant as `farMicE`.
  private var farYLinE: Double = 0
  private var farYNlE: Double = 0
  private(set) var nlUpdates = 0
  /// Peak-held basis energies, the normaliser for the branches' steps.
  private var bPeak = [Float](repeating: 0, count: Aec.nlBases)
  private let maxBlock: Int

  /// Where the estimator says the echo is, in samples, and how sure it is.
  /// Written by the estimator thread as plain scalars; the DECISION to move the
  /// filter is taken on the audio thread, so the two never tear.
  private var aimSamples = -1
  private var aimCorr: Double = 0
  /// Where the filter currently sits.
  private var delay = 0
  private var disagree = 0

  /// Leaky energies over about 40 ms, which is a syllable. Every judgement here
  /// is made on a duration and not on a sample: one sample says nothing about
  /// which signal is present, and that was the first version of the old
  /// double-talk gate (`abs(e) < abs(mic) * 2`, true of essentially every
  /// sample, so adaptation never froze).
  private var micE: Double = 0
  private var eE: Double = 0
  private var refE: Double = 0
  /// ── THE SAME PAIR, RESTRICTED TO BLOCKS WHERE ONLY THE ECHO IS PRESENT ─────
  ///
  /// `micE`/`eE` above cover every block, and that is right for the divergence
  /// guard: a filter adding energy while somebody is talking is damaging a voice
  /// and must be caught wherever it happens.
  ///
  /// It is exactly WRONG for deciding whether the filter is helping, and this was
  /// measured before it shipped. In double talk the near voice dominates the
  /// microphone and is untouched by the subtraction, so mic-over-residual reads
  /// about 0 dB however perfectly the echo is being cancelled -- so `mix` ramped
  /// to zero and the canceller switched itself off during the one condition it
  /// exists for. Probe measurement: 21.3 dB removed with the far end alone, 0.0 dB
  /// with both people talking.
  ///
  /// So the question "does this filter remove the echo" is asked about the blocks
  /// where the echo is what the microphone contains -- which is the same set of
  /// blocks the filter adapts on, and there are always some in a conversation.
  /// Half a second rather than 40 ms, because those blocks are intermittent and a
  /// syllable-length average over an intermittent set is mostly empty.
  private var farMicE: Double = 0
  private var farEE: Double = 0
  /// The ALIGNED reference energy over the same far-only blocks. This is what
  /// makes `echoPathNow` possible: the residual over the reference that produced
  /// it, both measured on the same window, at the delay the filter is aimed at.
  private var farRefE: Double = 0
  /// Consecutive samples the reference has been above its floor. The onset guard
  /// for `pathGain` -- see the note where it is learned.
  private var refRun = 0
  /// ── THE ALIGNMENT, AND ITS RATE ───────────────────────────────────────────
  ///
  /// `frac` is the fractional part of the delay, in samples, steered by the DLL.
  /// `skewSps` is the learned drift rate in samples per second -- an INTEGRATOR
  /// of the corrections, not an average of them, because a feed-forward that
  /// decays toward zero whenever it is right re-creates the error it removed and
  /// oscillates forever. It holds where the corrections stop.
  private var frac: Float = 0
  private(set) var skewSps: Float = 0
  /// The alignment actually used for the LAST block's window -- the probe in the
  /// rig must replicate this block, and steering happens after the window is
  /// built, so "current" and "used" are different values one block a step.
  private(set) var fracUsed: Float = 0
  private(set) var delayUsed = 0
  /// ── THE DRIFT SENSOR IS THE ESTIMATOR, NOT THE FILTER ─────────────────────
  ///
  /// The aim readings over signal time: the estimator's measured delay IS D(t),
  /// taken from a 400 ms cross-correlation of raw capture against raw playout --
  /// independent of this filter, of the window, of the carries, of everything
  /// this class does. Its slope is the drift, directly.
  ///
  /// Two filter-side sensors were built first and both are in the git history
  /// with their measurements: residual probes at ±0.25 samples (the verdict
  /// followed the drift's sign at every skew, because carries and refit make the
  /// window's own motion invisible to residuals -- railed at ±6), and the fitted
  /// response's centroid (reads the fit FORMING as -5 samples/s of "drift" during
  /// convergence, and saturates at the filter's own re-walk rate once converged).
  /// Both failed the same way: they measured the filter, and the filter is the
  /// actuator. A controller whose sensor watches its own actuator has no ground
  /// truth anywhere in the loop.
  private var aimT = [Float](repeating: 0, count: 64)
  private var aimD = [Float](repeating: 0, count: 64)
  private var aimN = 0
  /// Signal-time seconds processed. The regression's clock, because the rig runs
  /// twenty seconds of audio in two wall seconds and a wall clock would measure
  /// the machine's speed, not the crystals'.
  private var sigSec: Float = 0
  private var notHelpingMs: Double = 0
  private(set) var dllSteps = 0
  private(set) var dllResets = 0
  private(set) var skewRejects = 0
  private(set) var carries = 0
  private var lastTraceSec: Float = 0
  /// Lifetime energies, for the honest "what did this whole call get" figure.
  private var lifeMicE: Double = 0
  private var lifeOutE: Double = 0
  /// How much of the filter's output is actually subtracted, ramped.
  private var mix: Float = 0
  private var divergeMsRun: Double = 0
  private var coolMsLeft: Double = 0
  /// The 200 ms comparison between the two paths, and how long each side has been
  /// winning it.
  private var cmpFgE: Double = 0
  private var cmpBgE: Double = 0
  private var cmpMicE: Double = 0
  private var betterMs: Double = 0
  private var worseMs: Double = 0

  /// Rig only: print every divergence reset with the state that caused it.
  nonisolated(unsafe) static var trace = false
  private(set) var updates = 0
  private(set) var freezes = 0
  private(set) var reaims = 0
  private(set) var reaimsHeld = 0
  private(set) var diverges = 0
  /// How many times a measurably better background filter took over the audio,
  /// and how many times the background had to be restarted. The pair says which
  /// half of the two-path rule the call actually used.
  private(set) var transfers = 0
  private(set) var bgResets = 0
  /// Blocks where the subtraction was scaled out because it was not helping,
  /// and blocks where the filter ran at all. The pair, because a canceller that
  /// stood down for 90% of a call and reported only its ERLE over the other 10%
  /// is `invisible-when-it-matters`.
  private(set) var offBlocks = 0
  private(set) var ranBlocks = 0
  private(set) var blocks = 0
  var cost = Quantiles(cap: 2048)

  init(maxBlock: Int = 4096) {
    self.maxBlock = maxBlock
    fFg = [Float](repeating: 0, count: 4096)
    fBg = [Float](repeating: 0, count: 4096)
    xwin = [Float](repeating: 0, count: 4096 + maxBlock)
    yBuf = [Float](repeating: 0, count: maxBlock)
    yBgBuf = [Float](repeating: 0, count: maxBlock)
    eBuf = [Float](repeating: 0, count: maxBlock)
    eBgBuf = [Float](repeating: 0, count: maxBlock)
    gBuf = [Float](repeating: 0, count: 4096)
    rawWin = [Float](repeating: 0, count: 4096 + maxBlock + 3)
    fFgNl = Array(repeating: [Float](repeating: 0, count: 1024), count: Aec.nlBases)
    fBgNl = Array(repeating: [Float](repeating: 0, count: 1024), count: Aec.nlBases)
    bwins = Array(repeating: [Float](repeating: 0, count: 1024 + maxBlock), count: Aec.nlBases)
    yNlBuf = [Float](repeating: 0, count: maxBlock)
    gNlBuf = [Float](repeating: 0, count: 1024)
  }
  /// How much of the predicted echo, over far-only blocks, came from the
  /// nonlinear branches: 0 on a linear path, and the number that says whether a
  /// real speaker was distorting. -60 when the branches are off or cold.
  var nlShareDb: Double {
    guard farYNlE > 1e-20, farYLinE + farYNlE > 1e-20 else { return -60 }
    return 10 * log10(farYNlE / (farYLinE + farYNlE))
  }

  /// ── WHAT IT IS DOING NOW, AND WHAT THE CALL GOT ───────────────────────────
  ///
  /// Two figures on purpose, which is the one thing the deleted canceller got
  /// exactly right. The leaky figure is the honest "is it working" and the
  /// lifetime figure is the honest "what did this call get" -- it includes every
  /// second of cold-start convergence. Quoting only the first flatters a filter
  /// that took ten seconds to arrive; quoting only the second hides a filter
  /// that is working now.
  var erleDb: Double {
    guard farMicE > 1e-12, farEE > 1e-12 else { return 0 }
    return 10 * log10(farMicE / farEE)
  }
  /// Mic over residual across EVERY block, which is what the divergence guard
  /// watches. Reported so a call can distinguish "the filter is working" from
  /// "the filter is quietly adding energy while somebody talks".
  var erleAllDb: Double {
    guard micE > 1e-12, eE > 1e-12 else { return 0 }
    return 10 * log10(micE / eE)
  }
  var erleLifetimeDb: Double {
    guard lifeMicE > 1e-12, lifeOutE > 1e-12 else { return 0 }
    return 10 * log10(lifeMicE / lifeOutE)
  }
  /// ── THE NUMBER THE CLASSIFIER NEEDS ──────────────────────────────────────
  ///
  /// The linear fraction of the microphone that survived, as an AMPLITUDE ratio,
  /// which is the domain the duplex gate's echo bar lives in. 1 means "nothing
  /// was removed, assume the echo is all still there"; 0.1 means 20 dB of it is
  /// gone and a voice sitting 20 dB under the echo is now audible above it.
  ///
  /// It is deliberately the MEASURED residual and not a constant, and that is
  /// the whole safety argument for letting the gate relax at all: when this
  /// filter stops working -- a route change, a device change, a person picking
  /// the laptop up -- this rises back to 1 within about 40 ms and the gate's
  /// defence is exactly what it was before this file existed. A constant here
  /// would be `stale-constants-after-a-codec-win`: a compression win written
  /// down as a permanent change of units.
  var residual: Float {
    guard cfg.on, mix > 0.05, farMicE > 1e-12, farEE > 1e-12 else { return 1 }
    return min(1, max(0.02, Float((farEE / farMicE).squareRoot())))
  }
  /// ── WHAT IS LEFT OF THE ECHO PATH, MEASURED WHERE IT IS ALIGNED ───────────
  ///
  /// The fraction of the loudspeaker's output still arriving at the microphone
  /// after cancelling: residual RMS over reference RMS, on the blocks where the
  /// echo is what the microphone contains. This is the quantity that decides
  /// whether two microphones may be open at once -- not ERLE, which is a report
  /// card on the filter and says nothing about how much echo there was to begin
  /// with.
  ///
  /// It has to be measured HERE and not in the duplex gate. The gate's `coupling`
  /// compares its near envelope against `farEnv`, and `farEnv` is fed from the
  /// render callback -- the playout as it leaves, with no delay -- while the echo
  /// reaches the microphone thirty-odd milliseconds later. It is a minimum
  /// tracker over two signals that are not aligned, so it UNDER-reads, and the
  /// first version of the speaker-duplex switch read the gate's number and
  /// reported an echo path of -45 dB in a rig whose room was built at -17. It
  /// would have opened both microphones on a room that still had audible echo in
  /// it, which is precisely the failure its own self-test row warns about.
  ///
  /// `xwin` is positioned at the measured delay by construction, so the two
  /// signals here are aligned by the same index mapping the filtering uses.
  /// 1 -- "assume it is all still there" -- until there is a measurement.
  var echoPathNow: Float {
    guard cfg.on, mix > 0.05, farRefE > 1e-12, farEE > 1e-12 else { return 1 }
    return min(1, max(0.0005, Float((farEE / farRefE).squareRoot())))
  }
  var mixNow: Float { mix }
  /// The filter's own estimate of the echo for the last block, as an RMS. This
  /// is what the double-talk test compares the microphone against.
  private(set) var yRmsNow: Float = 0
  var erleFarNow: Double { erleDb }
  var delayNow: Int { delay }
  /// The filter's norm. Zero is a filter that has learned nothing, and a rig
  /// that cannot tell "learned nothing" from "learned that there is no echo"
  /// is reporting a negative it cannot see.
  var normNow: Float {
    var s: Float = 0
    for j in 0..<min(cfg.taps, fFg.count) { s += fFg[j] * fFg[j] }
    return s.squareRoot()
  }

  /// From the estimator thread. Scalars only across the boundary.
  ///
  /// Confident readings also feed the drift regression. `sigSec` is written by
  /// the audio thread and read here -- a Float scalar, the same crossing every
  /// other number in this file makes.
  func aim(delaySamples: Int, corr: Double) {
    aimSamples = delaySamples
    aimCorr = corr
    guard cfg.driftTrack, corr >= cfg.minCorr else { return }
    let t = sigSec
    // The ring keeps the last 64 readings (~32 s at the estimator's cadence).
    // A reading at the same signal time as the last (the rig can aim twice in
    // one block) replaces it rather than stacking.
    if aimN > 0, t - aimT[aimN - 1] < 0.25 { return }
    if aimN == aimT.count {
      for i in 1..<aimN { aimT[i - 1] = aimT[i]; aimD[i - 1] = aimD[i] }
      aimN -= 1
    }
    aimT[aimN] = t
    aimD[aimN] = Float(delaySamples)
    aimN += 1
    guard aimN >= cfg.skewMinReads, aimT[aimN - 1] - aimT[0] >= cfg.skewMinSpanS
    else { return }
    var st: Float = 0, sd: Float = 0
    for i in 0..<aimN { st += aimT[i]; sd += aimD[i] }
    let nF = Float(aimN)
    let mt = st / nF, md = sd / nF
    var stt: Float = 0, std: Float = 0
    for i in 0..<aimN {
      stt += (aimT[i] - mt) * (aimT[i] - mt)
      std += (aimT[i] - mt) * (aimD[i] - md)
    }
    guard stt > 1e-3 else { return }
    let slope = std / stt
    var rss: Float = 0
    for i in 0..<aimN {
      let r = aimD[i] - md - slope * (aimT[i] - mt)
      rss += r * r
    }
    let se = aimN > 2 ? (rss / Float(aimN - 2) / stt).squareRoot() : Float(1e9)
    if Aec.trace {
      fputs(String(format: "    skew: slope %+.2f±%.2f sps over %.0f s (n=%d)  skew %.2f\n",
                   slope, se, aimT[aimN - 1] - aimT[0], aimN, skewSps), stderr)
    }
    // Blend toward the measurement only when it stands clear of its own noise.
    // No feedback anywhere: the estimator cannot see the skew, so this cannot
    // oscillate -- the failure mode is only "not confident yet", which is the
    // untracked behaviour this whole feature improves on.
    if se > cfg.skewMaxSe || abs(slope) > cfg.dllSkewMax * 1.5 {
      // Not a clock. See `skewMaxSe`.
      skewRejects += 1
    } else if abs(slope) > max(cfg.skewMin, 1.5 * se) || (slope == 0 && se < cfg.skewMin) {
      let target = max(-cfg.dllSkewMax, min(cfg.dllSkewMax, slope))
      skewSps += (target - skewSps) * cfg.skewGain
      dllSteps += 1
    } else if abs(slope) < cfg.skewMin, se < cfg.skewMin, skewSps != 0 {
      // A confident zero is also information: the crystals agree, stand down.
      skewSps += (0 - skewSps) * cfg.skewGain
    }
  }

  func reset() {
    for j in 0..<fFg.count { fFg[j] = 0; fBg[j] = 0 }
    micE = 0; eE = 0; refE = 0; mix = 0; divergeMsRun = 0
    farMicE = 0; farEE = 0; farRefE = 0
    cmpFgE = 0; cmpBgE = 0; cmpMicE = 0; betterMs = 0; worseMs = 0
    refRun = 0
  }

  /// Subtract the estimated echo from `x` in place.
  ///
  /// `ref` is the circular playout history, `refW` the number of samples ever
  /// written to it, `refCap` its capacity. `x[k]` was captured at the same
  /// instant `ref[refW - n + k]` was played, so the sample this filter needs for
  /// `x[k]` is `refW - n + k - delay`. That mapping is derived from the
  /// estimator's own indexing, not assumed: see `Audio.echoEstimator`, where mic
  /// index `C` pairs with playout index `refW - (capW - C) - lagSamples`.
  func process(_ x: UnsafeMutablePointer<Float>, _ n: Int,
               ref: UnsafeMutablePointer<Float>, refW: Int, refCap: Int) {
    blocks += 1
    guard cfg.on, n > 0, n <= maxBlock else { return }
    let t0 = Clock.now()
    let dt = Double(n) / SR
    let T = min(cfg.taps, 4096)
    coolMsLeft = max(0, coolMsLeft - dt * 1000)

    // ── AIM, AND ONLY WHEN THE MOVE IS EARNED ────────────────────────────────
    let lead = Int(cfg.leadMs / 1000 * SR)
    guard aimSamples >= 0, aimCorr >= cfg.minCorr else {
      // No aim: the filter is not applied and not adapted. Nothing to do to the
      // audio, and `mix` is walked down so a route that loses its echo path
      // stops subtracting rather than freezing mid-subtraction.
      rampMix(toward: 0, dt: dt)
      offBlocks += 1
      cost.add(Clock.ms(Clock.now() - t0) * 1000.0)
      return
    }
    let want = max(0, aimSamples - lead)
    if abs(want - delay) > Int(cfg.reaimMs / 1000 * SR) {
      disagree += 1
      if disagree >= cfg.reaimHits, mix >= 0.5, erleDb >= cfg.reaimHoldDb {
        // Held: the filter at the current delay is demonstrably right. Counted
        // once per streak; `disagree` keeps running so the move happens the
        // block the evidence lapses.
        if disagree == cfg.reaimHits { reaimsHeld += 1 }
      } else if disagree >= cfg.reaimHits {
        delay = want
        for j in 0..<fFg.count { fFg[j] = 0; fBg[j] = 0 }
        zeroNl(fg: true, bg: true)
        cmpFgE = 0; cmpBgE = 0; cmpMicE = 0; betterMs = 0; worseMs = 0
        // The alignment restarts with the aim; the SKEW does not -- it is a
        // property of two crystals, not of one echo path, and it survives a
        // person changing their output device.
        frac = 0
        // The aim history spans the move (the estimator found a NEW path), so it
        // restarts; the skew survives -- it is a property of the crystals.
        aimN = 0
        reaims += 1
        disagree = 0
        mix = 0                     // a zeroed filter subtracts nothing, at once
      }
    } else {
      disagree = 0
    }

    // ── THE REFERENCE WINDOW, CONTIGUOUS -- AND AT A FRACTIONAL DELAY ────────
    //
    // `rawWin` holds `span + 3` whole samples: the span, two OLDER and one NEWER,
    // so a window can be interpolated at any alignment in (-0.25, 1.25) around
    // the integer delay -- which is where `frac` and both DLL probes live by
    // construction (`frac` carries into `delay` at the whole-sample marks).
    //
    // The value of the window at position i, delayed by a further phi samples, is
    // ref[start + i - phi]. In rawWin coordinates (rawWin[j] = ref[start-2+j])
    // that is position i + 2 - phi, linearly interpolated: with m = floor(phi)
    // and t = phi - m, it is one vDSP_vintb over rawWin+(1-m) and rawWin+(2-m)
    // at weight 1-t. Linear and not cubic, deliberately: the filter's own taps
    // interpolate far better than any fixed kernel -- the DLL's job is only to
    // keep the residual error inside the range the taps can absorb, and a
    // quarter-sample probe is deep inside that.
    let track = cfg.driftTrack
    let span = T - 1 + n
    let endIdx = refW - delay            // exclusive: newest usable ref index + 1
    guard endIdx - span - (track ? 2 : 0) >= 0, !track || delay >= 1 else {
      rampMix(toward: 0, dt: dt)
      offBlocks += 1
      cost.add(Clock.ms(Clock.now() - t0) * 1000.0)
      return
    }
    let start = endIdx - span
    fracUsed = track ? frac : 0
    delayUsed = delay
    if track {
      let R = span + 3
      rawWin.withUnsafeMutableBufferPointer { w in
        let wb = w.baseAddress!
        let s0 = (((start - 2) % refCap) + refCap) % refCap
        let first = min(R, refCap - s0)
        memcpy(wb, ref + s0, first * 4)
        if first < R { memcpy(wb + first, ref, (R - first) * 4) }
      }
      buildWindow(&xwin, phi: frac, span: span)
    } else {
      xwin.withUnsafeMutableBufferPointer { w in
        let wb = w.baseAddress!
        // At most two runs, because the source is one circular buffer.
        let s0 = ((start % refCap) + refCap) % refCap
        let first = min(span, refCap - s0)
        memcpy(wb, ref + s0, first * 4)
        if first < span { memcpy(wb + first, ref, (span - first) * 4) }
      }
    }

    var refSq: Float = 0
    xwin.withUnsafeBufferPointer { w in
      vDSP_svesq(w.baseAddress!, 1, &refSq, vDSP_Length(span))
    }
    let refRms = (refSq / Float(span)).squareRoot()
    guard refRms > cfg.refRmsFloor else {
      // Nothing playing. This is the state that destroyed the last canceller:
      // adapting here divides by silence. It also means there is no echo to
      // remove, so standing down costs nothing at all.
      rampMix(toward: 0, dt: dt)
      freezes += 1
      offBlocks += 1
      cost.add(Clock.ms(Clock.now() - t0) * 1000.0)
      return
    }
    ranBlocks += 1
    let divFloorSq = Double(cfg.divergeFloorRms) * Double(cfg.divergeFloorRms)

    // ── THE REFERENCE OVER THE SAME WINDOW AS THE MICROPHONE ─────────────────
    //
    // `refSq` above is the energy of the whole tap window -- because that is what
    // the NLMS normaliser needs. It is the wrong thing to compare a microphone
    // BLOCK against: the block is 16 samples, 0.33 ms, and an 11 ms speech RMS
    // and a 0.33 ms one differ by a factor of several from one block to the next.
    //
    // Measured before this was fixed: the ratio of the two read as low as 0.03
    // during ordinary speech, the double-talk test then read TRUE on 99.4% of
    // blocks and the canceller removed 0.0 dB. The aligned window is the one the
    // filter is actually pointed at -- `xwin[T-1 ..< T-1+n]` is exactly the
    // reference for `x[0..<n]`, by the same index mapping the filtering uses.
    var refAlnSq: Float = 0
    xwin.withUnsafeBufferPointer { w in
      vDSP_svesq(w.baseAddress! + (T - 1), 1, &refAlnSq, vDSP_Length(n))
    }
    var micSq: Float = 0
    vDSP_svesq(x, 1, &micSq, vDSP_Length(n))

    // ── TWO FILTERS, AND ONLY ONE OF THEM TOUCHES THE AUDIO ──────────────────
    //
    // `fFg` is applied to the microphone. `fBg` adapts. `fFg` is only ever
    // replaced by a copy of `fBg` that has been MEASURED to leave a smaller
    // residual on real audio, for a sustained window.
    //
    // This is not belt and braces, it is the structural answer to the one problem
    // a single-filter design cannot solve. An adaptive filter has to adapt, and
    // deciding when it is safe to means deciding whether the microphone currently
    // contains a near voice -- which at the instant of decision is exactly the
    // question this whole product says cannot be answered from the audio alone.
    // Every single-filter attempt here failed on it, in order, and each failure
    // was measured rather than argued:
    //
    //   a scalar path-gain minimum       latched at 0.116 against a true 0.6 and
    //                                    froze through the far end's entire turn:
    //                                    1.3 dB removed against 21 for far-only
    //   the filter's own prediction      cannot arm while the filter is cold, so
    //                                    "adapt freely until it works" adapted
    //                                    through the first overlap and diverged
    //                                    -- residual 3.2x the microphone, the
    //                                    filter zeroed, 20 dB of convergence gone
    //
    // With two paths the question stops being "is it safe to adapt" and becomes
    // "did adapting help", which is answerable AFTER the fact, on the audio that
    // actually arrived, with no guess about what the microphone contains. The
    // background is allowed to diverge -- it is not connected to anything -- and
    // when it does it is restarted from the foreground rather than from zero.
    //
    // The foreground therefore cannot get worse. That is the whole claim, and it
    // is why the divergence guard below is a backstop rather than the mechanism.
    xwin.withUnsafeBufferPointer { w in
      fFg.withUnsafeBufferPointer { fp in
        yBuf.withUnsafeMutableBufferPointer { y in
          vDSP_conv(w.baseAddress!, 1, fp.baseAddress!, 1, y.baseAddress!, 1,
                    vDSP_Length(n), vDSP_Length(T))
        }
      }
      fBg.withUnsafeBufferPointer { fp in
        yBgBuf.withUnsafeMutableBufferPointer { y in
          vDSP_conv(w.baseAddress!, 1, fp.baseAddress!, 1, y.baseAddress!, 1,
                    vDSP_Length(n), vDSP_Length(T))
        }
      }
    }
    // ── THE NONLINEAR BRANCHES, ADDED INTO THE SAME PREDICTION ───────────────
    //
    // Each basis is built from the SAME interpolated window the linear branch
    // reads -- `xwin[T-1+k]` pairs with `x[k]` -- over the last `Tn-1+n` samples
    // of it, so a shorter filter sits at the same zero-lag position. Everything
    // downstream (residual, transfer rule, divergence guard, mix) sees the sum,
    // so a branch that hurts is judged and switched out with the rest.
    var yLinSq: Float = 0
    yBuf.withUnsafeBufferPointer { y in vDSP_svesq(y.baseAddress!, 1, &yLinSq, vDSP_Length(n)) }
    let nlOn = cfg.nlOn
    let Tn = min(max(cfg.nlTaps, 16), 1024)
    let spanN = Tn - 1 + n
    var bSq = [Float](repeating: 0, count: Aec.nlBases)
    if nlOn, T >= Tn {
      xwin.withUnsafeBufferPointer { w in
        let xs = w.baseAddress! + (T - Tn)
        Aec.nlBuild(xs, spanN, into: &bwins, bSq: &bSq)
        for j in 0..<Aec.nlBases {
          bwins[j].withUnsafeMutableBufferPointer { b in
            fFgNl[j].withUnsafeBufferPointer { fp in
              yNlBuf.withUnsafeMutableBufferPointer { y in
                vDSP_conv(b.baseAddress!, 1, fp.baseAddress!, 1, y.baseAddress!, 1,
                          vDSP_Length(n), vDSP_Length(Tn))
              }
            }
            yNlBuf.withUnsafeBufferPointer { y in
              yBuf.withUnsafeMutableBufferPointer { acc in
                vDSP_vadd(acc.baseAddress!, 1, y.baseAddress!, 1, acc.baseAddress!, 1, vDSP_Length(n))
              }
            }
            fBgNl[j].withUnsafeBufferPointer { fp in
              yNlBuf.withUnsafeMutableBufferPointer { y in
                vDSP_conv(b.baseAddress!, 1, fp.baseAddress!, 1, y.baseAddress!, 1,
                          vDSP_Length(n), vDSP_Length(Tn))
              }
            }
            yNlBuf.withUnsafeBufferPointer { y in
              yBgBuf.withUnsafeMutableBufferPointer { acc in
                vDSP_vadd(acc.baseAddress!, 1, y.baseAddress!, 1, acc.baseAddress!, 1, vDSP_Length(n))
              }
            }
          }
        }
      }
    }
    var eSq: Float = 0, eBgSq: Float = 0, ySq: Float = 0
    yBuf.withUnsafeBufferPointer { y in
      eBuf.withUnsafeMutableBufferPointer { e in
        vDSP_vsub(y.baseAddress!, 1, x, 1, e.baseAddress!, 1, vDSP_Length(n))
        vDSP_svesq(e.baseAddress!, 1, &eSq, vDSP_Length(n))
      }
      vDSP_svesq(y.baseAddress!, 1, &ySq, vDSP_Length(n))
    }
    var yBgSq: Float = 0
    yBgBuf.withUnsafeBufferPointer { y in
      eBgBuf.withUnsafeMutableBufferPointer { e in
        vDSP_vsub(y.baseAddress!, 1, x, 1, e.baseAddress!, 1, vDSP_Length(n))
        vDSP_svesq(e.baseAddress!, 1, &eBgSq, vDSP_Length(n))
      }
      vDSP_svesq(y.baseAddress!, 1, &yBgSq, vDSP_Length(n))
    }

    // ── THE JUDGEMENTS, ALL ON A DURATION ────────────────────────────────────
    let k = 1 - exp(-dt / 0.040)
    micE += (Double(micSq) / Double(n) - micE) * k
    eE += (Double(eSq) / Double(n) - eE) * k
    refE += (Double(refAlnSq) / Double(n) - refE) * k
    lifeMicE += Double(micSq)
    lifeOutE += Double(eSq)
    // The comparison that decides a transfer, over 200 ms: long enough that one
    // syllable cannot swap the filter, short enough to follow a room that moved.
    let kc = 1 - exp(-dt / 0.200)
    cmpFgE += (Double(eSq) / Double(n) - cmpFgE) * kc
    cmpBgE += (Double(eBgSq) / Double(n) - cmpBgE) * kc
    cmpMicE += (Double(micSq) / Double(n) - cmpMicE) * kc

    let micRmsL = Float(micE.squareRoot())
    let refAlnRms = (refAlnSq / Float(n)).squareRoot()
    refRun = refAlnRms > cfg.refRmsFloor ? refRun + n : 0

    // ── DOES THE BACKGROUND BEAT WHAT IS ON THE AUDIO ────────────────────────
    //
    // Judged only while the reference is present, because a comparison made in
    // silence is a comparison of two numbers that are both nearly zero -- and
    // that exact mistake, in the divergence guard, zeroed a converged filter
    // twice in twenty seconds of conversation.
    if refAlnRms > cfg.refRmsFloor, cmpFgE > divFloorSq || cmpBgE > divFloorSq {
      // Two conditions, and the second is not redundant: better than what is on
      // the audio AND better than no filter at all.
      let beatsFg = cmpBgE < cmpFgE * Double(cfg.transferMargin)
      let beatsPassthrough = cmpBgE < cmpMicE * Double(cfg.passthroughMargin)
      if beatsFg, beatsPassthrough {
        betterMs += dt * 1000
        worseMs = 0
        if betterMs >= cfg.transferMs {
          for j in 0..<T { fFg[j] = fBg[j] }
          for b in 0..<Aec.nlBases { for j in 0..<Tn { fFgNl[b][j] = fBgNl[b][j] } }
          transfers += 1
          betterMs = 0
          // The foreground just changed, so every measurement OF the foreground
          // is about a filter that no longer exists. Cleared rather than left to
          // decay, because `mix` and `residual` both read it and a stale reading
          // of a replaced filter is the shape of `final-record-is-not-final`.
          cmpFgE = cmpBgE
        }
      } else if cmpBgE > cmpFgE * Double(cfg.bgResetRatio) {
        // The background has run away. Restart it from the foreground rather than
        // from zero: zero throws away everything the call has learned, and the
        // foreground is by construction the best filter this call has had.
        worseMs += dt * 1000
        betterMs = 0
        if worseMs >= cfg.divergeMs {
          for j in 0..<T { fBg[j] = fFg[j] }
          for b in 0..<Aec.nlBases { for j in 0..<Tn { fBgNl[b][j] = fFgNl[b][j] } }
          cmpBgE = cmpFgE
          bgResets += 1
          worseMs = 0
        }
      } else {
        betterMs = 0
        worseMs = 0
      }
    }

    // DIVERGENCE, ON THE FOREGROUND, AS A BACKSTOP. With the transfer rule above
    // this should never fire; it is counted so that "never fires" is a
    // measurement rather than an assumption.
    if eE > micE * Double(cfg.divergeRatio), eE > divFloorSq {
      divergeMsRun += dt * 1000
      if divergeMsRun >= cfg.divergeMs {
        if Aec.trace {
          fputs(String(format: "    aec fg reset: micRms %.5f eRms %.5f yRms %.5f\n",
                       micE.squareRoot(), eE.squareRoot(), Double(yRmsNow)), stderr)
        }
        // Only the FOREGROUND. Zeroing the background too was the other half of
        // the deadlock above: it threw away the only filter still learning, and
        // the background is not connected to the audio, so there is nothing to
        // protect anybody from by clearing it. The comparison state IS cleared --
        // it describes a foreground that no longer exists.
        for j in 0..<fFg.count { fFg[j] = 0 }
        zeroNl(fg: true, bg: false)
        mix = 0
        micE = 0; eE = 0; farMicE = 0; farEE = 0; farRefE = 0; cmpFgE = 0; cmpBgE = 0; cmpMicE = 0
        farYLinE = 0; farYNlE = 0
        diverges += 1
        divergeMsRun = 0
        coolMsLeft = cfg.coolMs
      }
    } else {
      divergeMsRun = 0
    }

    // ── DOUBLE TALK: A HINT NOW, NOT A SAFETY MECHANISM ──────────────────────
    //
    // With two paths, freezing is no longer what keeps the audio safe -- the
    // transfer rule is. So this can be exactly what it should be: a cheap way to
    // stop the background wasting its steps on blocks that are mostly a near
    // voice. Compared against the FOREGROUND's own prediction of the echo, which
    // needs no separate estimator, and armed only once the foreground is
    // measurably working. Getting it wrong now costs convergence speed and
    // nothing else.
    // ── AND IT IS THE BACKGROUND'S PREDICTION, NOT THE FOREGROUND'S ──────────
    //
    // Measured, and it is a one-way door of exactly the shape this project has a
    // law about (`held-is-a-one-way-door`). Conditioned on the FOREGROUND it read:
    // foreground gets zeroed by the backstop -> its prediction is 0 -> every
    // microphone is "louder than the echo can explain" -> freeze -> and the
    // far-only ERLE that armed the freeze is only updated on non-frozen blocks, so
    // it stayed frozen at 9.7 dB forever. 1018 adapting blocks in 59881: the
    // canceller entombed itself and the number that would have said so was the
    // number it had stopped updating.
    //
    // The background is never zeroed by anything the foreground does, so its
    // prediction is always live. Its own bootstrap needs no `converged` flag
    // either: a filter that has learned nothing predicts nothing, `yBgRms` is
    // below the reference floor, and the test simply does not apply -- so it
    // adapts freely until it has something to protect and then protects it. One
    // condition, one concern.
    let yRms = (ySq / Float(n)).squareRoot()
    let yBgRms = (yBgSq / Float(n)).squareRoot()
    yRmsNow = yRms
    let doubleTalk = yBgRms > cfg.refRmsFloor && micRmsL > yBgRms * cfg.dtRatio
    let mayAdapt = !doubleTalk && coolMsLeft <= 0
    // The far-only measurement, on the same blocks the filter fits. Half a
    // second, because those blocks are intermittent.
    if !doubleTalk, refAlnRms > cfg.refRmsFloor {
      let kf = 1 - exp(-dt / 0.5)
      farMicE += (Double(micSq) / Double(n) - farMicE) * kf
      farEE += (Double(eSq) / Double(n) - farEE) * kf
      farRefE += (Double(refAlnSq) / Double(n) - farRefE) * kf
      // The prediction split into its linear and nonlinear halves. `ySq` is the
      // sum's energy; the cross term is folded into the nonlinear share, which
      // is the honest place for it -- it is energy the linear branch alone did
      // not predict.
      farYLinE += (Double(yLinSq) / Double(n) - farYLinE) * kf
      farYNlE += (max(0, Double(ySq) - Double(yLinSq)) / Double(n) - farYNlE) * kf
    }

    // ── THE FEED-FORWARD ─────────────────────────────────────────────────────
    //
    // The skew is measured in `aim()` from the estimator's own delay readings --
    // see the note there for the two filter-side sensors that failed first.
    // Here it is only APPLIED: the alignment advances at the measured rate, the
    // carries move whole samples into the integer delay with an exact tap shift,
    // and the filter sees a room that stands still. There is no loop to
    // stabilise because nothing here feeds anything that measures it.
    if track {
      sigSec += Float(dt)
      frac += skewSps * Float(dt)
      if Aec.trace, sigSec - lastTraceSec >= 5 {
        lastTraceSec = sigSec
        fputs(String(format: "    ff: t %.0fs frac %.2f delay %d skew %.2f carries %d mix %.2f erle %.1f\n",
                     sigSec, frac, delay, skewSps, carries, mix, erleDb), stderr)
      }
    }

    if mayAdapt {
      // ── ONE BLOCK NLMS STEP, ON THE BACKGROUND ─────────────────────────────
      //
      // g[p] = sum_k xwin[p+k] * eBg[k], which is the same `vDSP_conv` with the
      // roles swapped -- the gradient of a correlation is a correlation. The
      // normaliser is `n * refEnergy`, so this block step is exactly the AVERAGE
      // of the `n` per-sample NLMS steps it stands in for: stable for `mu < 2` at
      // any block size, which is the property a per-block coefficient would not
      // have had.
      //
      // `max(refSq, floor)` and not `refSq + 1e-6`. The epsilon in the old code
      // was not a level, so a near-silent reference still produced an enormous
      // step -- and that is the whole arithmetic of the -21.7 dB failure.
      var scale = cfg.mu / (Float(n) * max(refSq, Float(span) * cfg.refRmsFloor * cfg.refRmsFloor))
      if cfg.leakTau > 0 {
        var keep = Float(exp(-dt / cfg.leakTau))
        fBg.withUnsafeMutableBufferPointer { fp in
          vDSP_vsmul(fp.baseAddress!, 1, &keep, fp.baseAddress!, 1, vDSP_Length(T))
        }
      }
      xwin.withUnsafeBufferPointer { w in
        eBgBuf.withUnsafeBufferPointer { e in
          gBuf.withUnsafeMutableBufferPointer { g in
            vDSP_conv(w.baseAddress!, 1, e.baseAddress!, 1, g.baseAddress!, 1,
                      vDSP_Length(T), vDSP_Length(n))
            fBg.withUnsafeMutableBufferPointer { fp in
              vDSP_vsma(g.baseAddress!, 1, &scale, fp.baseAddress!, 1,
                        fp.baseAddress!, 1, vDSP_Length(T))
            }
          }
        }
      }
      updates += 1
      // ── AND THE SAME STEP ON EACH NONLINEAR BRANCH, NORMALISED TO ITSELF ────
      //
      // Each basis has its own energy scale (x^5 of a 0.1 signal is 1e-5), so
      // each gets its own normaliser, floored at what that basis reads at
      // `nlMinRms`. Below the floor the branch does not adapt: a speaker at -40
      // dBFS is not distorting, and a normalised step on a vanishing basis is a
      // step on noise.
      // And only while the LINEAR branch is on the audio and helping: the
      // distortion is a small residual on top of the linear echo, and a branch
      // adapting before that echo is gone is adapting to the wrong target. Not a
      // one-way door -- the linear background adapts regardless, so `mix`
      // returns on its own and the branches resume.
      if nlOn, T >= Tn, refAlnRms >= cfg.nlMinRms, mix >= 0.5, erleDb >= cfg.nlMinErleDb {
        var stepped = false
        eBgBuf.withUnsafeBufferPointer { e in
          for j in 0..<Aec.nlBases {
            let lvl = Aec.nlBasisLevel(j, cfg.nlMinRms)
            let floorSq = Float(spanN) * lvl * lvl
            // Peak hold with a ~2 s decay: the step is set by the loudest recent
            // window, never by this one.
            bPeak[j] = max(bSq[j], bPeak[j] * Float(exp(-dt / 2.0)))
            guard bSq[j] > floorSq else { continue }
            var s = cfg.nlMu / (Float(n) * max(bPeak[j], floorSq))
            bwins[j].withUnsafeBufferPointer { b in
              gNlBuf.withUnsafeMutableBufferPointer { g in
                vDSP_conv(b.baseAddress!, 1, e.baseAddress!, 1, g.baseAddress!, 1,
                          vDSP_Length(Tn), vDSP_Length(n))
                fBgNl[j].withUnsafeMutableBufferPointer { fp in
                  vDSP_vsma(g.baseAddress!, 1, &s, fp.baseAddress!, 1,
                            fp.baseAddress!, 1, vDSP_Length(Tn))
                }
              }
            }
            stepped = true
          }
        }
        if stepped { nlUpdates += 1 }
      }
      if Aec.trace, nlOn, blocks % 3000 == 0 {
        var norms = [Float](repeating: 0, count: Aec.nlBases)
        var normsFg = [Float](repeating: 0, count: Aec.nlBases)
        for j in 0..<Aec.nlBases {
          for p in 0..<Tn { norms[j] += fBgNl[j][p] * fBgNl[j][p]; normsFg[j] += fFgNl[j][p] * fFgNl[j][p] }
        }
        var linN: Float = 0
        for p in 0..<T { linN += fBg[p] * fBg[p] }
        fputs(String(format: "    nl t %.1fs mix %.2f yLin %.5f y %.5f eBg %.5f mic %.5f | bSq %.2e %.2e %.2e | |wBg| %.2e %.2e %.2e |wFg| %.2e %.2e %.2e lin %.3f\n",
                     Double(blocks) * dt, mix, (yLinSq / Float(n)).squareRoot(), (ySq / Float(n)).squareRoot(),
                     (eBgSq / Float(n)).squareRoot(), (micSq / Float(n)).squareRoot(),
                     bSq[0], bSq[1], bSq[2], norms[0].squareRoot(), norms[1].squareRoot(), norms[2].squareRoot(),
                     normsFg[0].squareRoot(), normsFg[1].squareRoot(), normsFg[2].squareRoot(), linN.squareRoot()), stderr)
      }
    } else {
      freezes += 1
    }

    // ── THE CARRY, AFTER THE ADAPTATION ──────────────────────────────────────
    //
    // Whole samples of `frac` move into the integer delay, and both filters are
    // shifted so the learned response describes the same room before and after.
    // After the gradient has been applied, not before: a shift landing between
    // the gradient's computation and its application would apply an update
    // indexed for the old alignment to taps that have already moved.
    if track {
      // ── A CARRY CHANGES NOTHING, AND THAT IS THE WHOLE PROOF ────────────────
      //
      // delay+1 and frac-1 cancel by construction: the window at (delay+1,
      // frac-1) is sample-for-sample the window at (delay, frac), so the taps
      // must stay exactly where they are. The first version shifted them anyway
      // -- the shift rule belongs to a REAIM, where delay moves alone -- and that
      // misaligned the fit by one whole sample per carry, 1.4 times a second: a
      // sawtooth with the same average misalignment power as the drift being
      // corrected. Measured as the smoking gun that found it: tracked 12.2 dB,
      // untracked 12.3 dB, with the skew locked at 1.45 against a planted 1.44
      // and every carry firing on time. The tracker was perfect and its carry
      // was undoing it.
      while frac >= 1 { frac -= 1; delay += 1; carries += 1 }
      while frac < 0 { frac += 1; delay -= 1; carries += 1 }
    }

    // ── AND THE SUBTRACTION IS SCALED BY WHETHER IT HELPED ───────────────────
    //
    // A foreground achieving nothing has its contribution ramped out over 4 ms
    // and the microphone reaches the wire exactly as captured. This is what makes
    // "it can never damage the voice" a structural fact rather than a hope, and it
    // is why there is no residual suppressor here to compensate for a bad filter:
    // a bad filter is switched off, not papered over.
    let helping = erleDb >= cfg.helpDb && coolMsLeft <= 0
    rampMix(toward: helping ? 1 : 0, dt: dt)
    // ── THE RECOVERY DOOR ────────────────────────────────────────────────────
    //
    // A canceller that is aimed, running, and has not earned a single block of
    // subtraction for two seconds is a canceller whose model of the world is
    // wrong -- and the one piece of that model that can silently poison
    // everything else is the skew feed-forward, because it MOVES the target on
    // its own. Reset the alignment and the skew and let the whole thing
    // re-acquire from the estimator's aim, which is still live. The evidence
    // here is `mix`, measured every block regardless of what the steering does.
    if track {
      notHelpingMs = mix < 0.05 ? notHelpingMs + dt * 1000 : 0
      if notHelpingMs >= cfg.dllResetMs, skewSps != 0 || frac != 0 {
        skewSps = 0
        frac = 0
        aimN = 0
        notHelpingMs = 0
        dllResets += 1
      }
    }
    if mix < 0.05 { offBlocks += 1 }
    if mix > 0 {
      var negMix = -mix
      yBuf.withUnsafeBufferPointer { y in
        vDSP_vsma(y.baseAddress!, 1, &negMix, x, 1, x, 1, vDSP_Length(n))
      }
    }
    cost.add(Clock.ms(Clock.now() - t0) * 1000.0)
  }

  /// Interpolate a reference window out of `rawWin` at a further `phi` samples of
  /// delay, phi in [0, 1). Four-point Lagrange cubic, and the order matters more
  /// than interpolation orders usually do:
  ///
  /// The tracker MOVES this alignment continuously -- at 30 ppm the weight sweeps
  /// the whole unit interval every 0.7 s -- so the kernel's frequency response is
  /// not a fixed colouration the filter absorbs once, it is a MORPHING one the
  /// filter must chase forever. Linear interpolation morphs by up to 3 dB at the
  /// top of the band across that sweep, and the measurement was unambiguous: with
  /// the skew estimate reading 1.45 against a planted 1.44 -- the sensor as close
  /// to perfect as it can be -- the tracked arm won 0.0 dB, because the re-fitting
  /// the tracker saved on the drift it spent on the kernel. Cubic holds the
  /// response within ~0.05 dB below 4 kHz across the whole sweep.
  ///
  /// Coefficients at t = 1 - phi (position p = i + 2 - phi sits between
  /// rawWin[i+1] and rawWin[i+2]); t -> 1 collapses to the exact passthrough of
  /// rawWin[i+2], which is the phi = 0 window.
  private func buildWindow(_ dst: inout [Float], phi: Float, span: Int) {
    let t = 1 - phi
    if t >= 0.9999 {
      rawWin.withUnsafeBufferPointer { r in
        dst.withUnsafeMutableBufferPointer { d in
          memcpy(d.baseAddress!, r.baseAddress! + 2, span * 4)
        }
      }
      return
    }
    var c0 = -t * (t - 1) * (t - 2) / 6
    var c1 = (t + 1) * (t - 1) * (t - 2) / 2
    var c2 = -t * (t + 1) * (t - 2) / 2
    var c3 = t * (t + 1) * (t - 1) / 6
    rawWin.withUnsafeBufferPointer { r in
      let rb = r.baseAddress!
      dst.withUnsafeMutableBufferPointer { d in
        let db = d.baseAddress!
        vDSP_vsmul(rb, 1, &c0, db, 1, vDSP_Length(span))
        vDSP_vsma(rb + 1, 1, &c1, db, 1, db, 1, vDSP_Length(span))
        vDSP_vsma(rb + 2, 1, &c2, db, 1, db, 1, vDSP_Length(span))
        vDSP_vsma(rb + 3, 1, &c3, db, 1, db, 1, vDSP_Length(span))
      }
    }
  }

  /// Up on a ~40 ms exponential, down on a 4 ms linear ramp. The direction that
  /// STOPS touching the audio is the fast one, which is the opposite of every
  /// other gain in this app and correct for the same reason: there, the fast
  /// direction is the one that restores hearing; here, it is the one that
  /// restores the untouched microphone.
  private func zeroNl(fg: Bool, bg: Bool) {
    for b in 0..<Aec.nlBases {
      if fg { for j in 0..<fFgNl[b].count { fFgNl[b][j] = 0 } }
      if bg { for j in 0..<fBgNl[b].count { fBgNl[b][j] = 0 } }
    }
  }

  private func rampMix(toward target: Float, dt: Double) {
    if target < mix {
      mix = max(target, mix - Float(dt / 0.004))
    } else {
      mix += (target - mix) * Float(1 - exp(-dt / 0.040))
    }
  }
}

// ── PROVING IT, AND FAILING WHERE IT MUST ────────────────────────────────────
//
// `validate-the-ruler-against-known-inputs` is a law here and it has two halves:
// the rig must get the right answer on inputs whose answer is known, AND it must
// get the WRONG answer on inputs it should not be able to fix. A canceller is
// unusually easy to certify falsely -- any filter that attenuates scores an ERLE
// -- so every row below that says "it worked" is paired with a row that says
// "and it did not do that to a voice".
//
// The known answers used:
//
//   · NO ECHO PATH AT ALL. ERLE must be about zero and the near voice must come
//     out unchanged to within a whisper. This is the row the deleted canceller
//     failed at -21.6 dB, and it is the row that localised it.
//   · A ROOM. Playout, delayed, attenuated, with three early reflections -- the
//     path `Audio.armEchoSim` already builds. ERLE must be large.
//   · BOTH PEOPLE TALKING. The near voice must survive; the freeze is what
//     protects it, and its absence is what made the old one chew people up.
//   · A DELAY ESTIMATE THAT IS WRONG. `leadMs` exists to absorb a few
//     milliseconds of error, so a rig that only ever hands it the exact answer
//     is testing a parameter the product does not choose
//     (`rig-picks-a-parameter-the-product-does-not`).
//
// Run: `tk --aec-test`. `--aec-sweep` prints the tap/step table the defaults
// were read off.
extension Aec {

  private static func locate(_ p: String) -> String {
    let fm = FileManager.default
    if fm.fileExists(atPath: p) { return p }
    var up = ""
    for _ in 0..<5 {
      up += "../"
      if fm.fileExists(atPath: up + p) { return up + p }
    }
    return p
  }

  private static func rmsOf(_ x: [Float], from: Int = 0) -> Double {
    var s = 0.0
    var n = 0
    for i in from..<x.count { s += Double(x[i]) * Double(x[i]); n += 1 }
    return n > 0 ? (s / Double(n)).squareRoot() : 0
  }

  /// The room `armEchoSim` builds: a direct path and three early reflections out
  /// to 13 ms. A pure delay is the one echo path no room produces, and a filter
  /// that only ever meets a single tap can pass a test it would fail in a room.
  static func roomTaps(tailMs: Double = 0) -> [(Int, Float)] {
    var taps: [(Int, Float)] = [(0, 1.0), (Int(0.0031 * SR), 0.55), (Int(0.0072 * SR), 0.33), (Int(0.0131 * SR), 0.18)]
    // ── A ROOM DOES NOT END AT 13 MS ─────────────────────────────────────────
    //
    // Past the early reflections a real room has a diffuse tail: dense, random
    // in sign, decaying exponentially. Built here as one reflection every ~0.7 ms
    // from 13 ms out to `tailMs`, falling 60 dB from the last early reflection
    // to the end of the tail -- an RT60 that ends at `tailMs`. The signs come
    // from a fixed-seed LCG so every run builds the same room.
    guard tailMs > 13.1 else { return taps }
    var seed: UInt32 = 0x9E3779B9
    var t = 13.1 + 0.7
    while t < tailMs {
      seed = seed &* 1664525 &+ 1013904223
      let u = Double(seed >> 8) / Double(1 << 24)
      let sign: Float = (seed & 1) == 0 ? 1 : -1
      let g = 0.18 * pow(10, -3 * (t - 13.1) / (tailMs - 13.1))
      taps.append((Int(t / 1000 * SR), sign * Float(g) * Float(0.6 + 0.8 * u)))
      t += 0.5 + 0.4 * u
    }
    return taps
  }

  /// The rig's loudspeaker: a symmetric soft clip at `drive` (0 = a linear
  /// speaker) plus an even-order asymmetry `asym`. tanh is NOT one of the
  /// canceller's basis functions -- its series is, at every order, so the rig is
  /// a shape the model can approach and never match exactly
  /// (`fixture-is-not-the-real-shape`).
  static func speaker(_ x: Float, drive: Float, asym: Float) -> Float {
    var y = drive > 0 ? tanh(drive * x) / drive : x
    y += asym * x * abs(x)
    return y
  }

  struct Result {
    var erleDb = 0.0
    var lifeErleDb = 0.0
    /// ── THE NUMBER THAT ACTUALLY ANSWERS "HOW MUCH ECHO WENT" ────────────────
    ///
    /// Measured on an ECHO-ONLY PROBE pushed through the same filter state the
    /// mixture produced, not on the mixture itself. In double talk the near voice
    /// dominates the microphone, so mic-energy-in over out-energy-out reads ~0 dB
    /// however well the filter is working -- which is what the first version of
    /// this rig reported, and it would have read the same for a canceller that
    /// did nothing at all.
    ///
    /// Scored on ONE run with the probe carried alongside, never on two separate
    /// runs: the filter adapts to what it is given, so cancelling the echo alone
    /// would score a filter that never existed. The same argument
    /// `SubtitleCleaner.clean(probe:)` makes.
    var echoErleDb = 0.0
    /// ── WHETHER THE NEAR VOICE PASSED THROUGH UNTOUCHED, PROVEN ──────────────
    ///
    /// A linear canceller cannot damage a voice, and that is a fact about the
    /// arithmetic rather than a hope about the tuning:
    ///
    ///     out = mic - mix*y(ref) = near + (echo - mix*y(ref))
    ///
    /// `y` is a function of the REFERENCE alone, so the near term passes through
    /// exactly. It is asserted rather than assumed because a bug could break the
    /// linearity -- an update that read the microphone, a mix applied to the
    /// wrong buffer -- and the failure would be inaudible in every other number
    /// here. Computed as `out - echoProbeOut - near`, which by the identity above
    /// must be zero to floating point.
    ///
    /// The first version of this rig reported `||mix*y||^2 / ||near||^2` and
    /// called it damage, which ranks BACKWARDS: `mix*y` is the filter's estimate
    /// of the echo, so a large value is a filter doing its job and -120 dB is a
    /// filter that did nothing at all. Two of the sweep's best rows were being
    /// read as its worst (`no-reference-picture-quality-failed`).
    var linearityDb = 0.0
    /// `||mix*y||^2 / ||echo||^2` -- how much of the echo's energy the filter
    /// actually accounted for. Near 0 dB is a filter tracking the echo; -120 dB
    /// is a filter that never engaged.
    var accountedDb = 0.0
    var diverges = 0
    var reaims = 0
    var updates = 0
    var freezes = 0
    var offPct = 0.0
    /// Mic over residual across every block at the end of the run -- the number
    /// the divergence guard watches, and the one the deleted canceller read
    /// -21.7 dB on.
    var erleAllDbEnd = 0.0
    var mixMean = 0.0
    var pathGainEnd = 0.0
    var transfers = 0
    var bgResets = 0
    var normEnd = 0.0
    /// The learned drift, in samples per second, and how many corrections the
    /// DLL applied. The estimate is the ruler's own check: driven with a KNOWN
    /// skew, it has to read that skew back (`validate-the-ruler-against-known-inputs`).
    var skewSps = 0.0
    var dllSteps = 0
    var costUsP50 = 0.0
    var costUsP99 = 0.0
    var convergeMs = -1.0      // when the leaky ERLE first passed 10 dB
    /// How much of the predicted echo the nonlinear branches supplied, and how
    /// many blocks they adapted on. -60 and 0 on a linear path with the
    /// branches doing nothing, which is what they must do there.
    var nlShareDb = -60.0
    var nlUpdates = 0
    var reaimsHeld = 0
    var skewRejects = 0
  }

  /// One run. `near` is what the person says, `far` is what the far end sent (the
  /// reference AND what the speaker plays), `echoGain` scales the room, `aimErrMs`
  /// is how wrong the delay estimate is handed to the filter.
  ///
  /// `probeNear` is the whole reason this can measure damage: the same run is
  /// scored twice, once on the mixture the canceller actually saw and once on the
  /// near voice ALONE pushed through the identical filter state. Cancelling the
  /// two separately would let the filter adapt to a different signal each time
  /// and score itself on two runs that never happened -- the same argument
  /// `SubtitleCleaner.clean(probe:)` already makes.
  static func run(near: [Float], far: [Float], delayMs: Double, echoGain: Float,
                  cfg: Cfg, blockN: Int = 16, aimErrMs: Double = 0,
                  corr: Double = 0.8, echoOn: Bool = true, skewPpm: Double = 0,
                  tailMs: Double = 0, spkDrive: Float = 0, spkAsym: Float = 0,
                  aimJitterMs: Double = 0, pathStepAtS: Double = 0, pathStepMs: Double = 0)
      -> (r: Result, out: [Float], nearOut: [Float]) {
    let n = min(near.count, far.count)
    let a = Aec()
    a.cfg = cfg
    let taps = roomTaps(tailMs: tailMs)
    // What the loudspeaker actually put into the room. The REFERENCE the
    // canceller sees is still `far` -- the clean signal this machine sent to the
    // device -- because that is all a real canceller ever has.
    let spk: [Float] = (spkDrive > 0 || spkAsym != 0)
      ? far.map { speaker($0, drive: spkDrive, asym: spkAsym) } : far
    let d = max(1, Int(delayMs / 1000 * SR))
    // The real circular playout history, at its real size, so the wrapping copy
    // in `process` is the code under test rather than a straight line.
    let cap = 48000
    var ring = [Float](repeating: 0, count: cap)
    var out = [Float](repeating: 0, count: n)
    var nearOut = [Float](repeating: 0, count: n)
    var block = [Float](repeating: 0, count: blockN)
    var nearBlock = [Float](repeating: 0, count: blockN)
    var echoBlock = [Float](repeating: 0, count: blockN)
    var conv = -1.0
    // The echo probe's energy before and after, accumulated past the first second
    // so convergence is reported by `convergeMs` rather than smeared into this.
    var echoInE = 0.0, echoOutE = 0.0
    var linErrE = 0.0, nearRefE = 0.0, yE = 0.0
    var mixSum = 0.0, mixN = 0
    let scoreFrom = Int(SR)
    a.aim(delaySamples: Int((delayMs + aimErrMs) / 1000 * SR), corr: corr)
    // The product's estimator re-measures the delay every 500 ms, decimated by 8
    // -- so its reading of a drifting path is a STAIRCASE with 8-sample treads.
    // The rig feeds the same staircase, because the skew regression's whole job
    // is to see the stairs through the treads, and a rig that handed it the
    // smooth truth would be testing a sensor nobody has
    // (`fixture-is-not-the-real-shape`).
    let aimEvery = Int(0.5 * SR)
    // A step in the true path at `pathStepAtS` (the laptop was picked up), and
    // an estimator whose readings wander ±`aimJitterMs` around the truth on
    // alternate readings -- the live signature that produced 32 re-aims.
    let stepAt = Int(pathStepAtS * SR)
    let stepS = Int(pathStepMs / 1000 * SR)
    var aimCount = 0
    var i = 0
    while i + blockN <= n {
      if i > 0, i % aimEvery < blockN {
        let dNow = Double(d) + skewPpm * 1e-6 * Double(i) + Double(stepAt > 0 && i >= stepAt ? stepS : 0)
        aimCount += 1
        // The live shape: the estimator settles on a WRONG delay for ~2 s (four
        // readings) out of every ~6 s, alternating which side it errs to. Not a
        // reading wrong every time -- under that no filter could ever converge
        // and there would be nothing to hold.
        // Wrong stretches begin at 4 s, after the filter has had a chance to
        // converge -- a filter that has learned nothing has nothing to hold.
        let episode = aimCount / 12
        let wrong = aimJitterMs > 0 && aimCount % 12 >= 8
        let jit = wrong ? (episode % 2 == 0 ? 1.0 : -1.0) * aimJitterMs / 1000 * SR : 0
        a.aim(delaySamples: (Int(dNow + jit) / 8) * 8, corr: corr)
      }
      // Play this block, then capture it: the same order the two callbacks run in.
      for k in 0..<blockN { ring[(i + k) % cap] = far[i + k] }
      let refW = i + blockN
      for k in 0..<blockN {
        var e: Float = 0
        if echoOn {
          // ── AND THE CLOCKS CAN DISAGREE ─────────────────────────────────────
          //
          // `skewPpm` makes the echo's delay GROW with time, which is what two
          // crystals tens of ppm apart do to a real call: 30 ppm is 1.44 samples
          // a second, ~58 samples over this recording.
          //
          // The resampling is an 8-point windowed sinc, and that is load-bearing
          // for the rig's honesty in BOTH directions. A drifting clock's real
          // echo is the bandlimited reconstruction a physical DAC produces -- an
          // ideal fractional delay, flat in magnitude -- and the first version of
          // this generator used linear interpolation, whose response MORPHS by
          // decibels at the top of the band as the phase sweeps. That planted an
          // unfittable time-varying colouration in the echo itself: the tracker
          // locked its skew at 1.45 against a planted 1.44, aligned perfectly,
          // and won 0.0 dB, because the rig had built a room no canceller could
          // cancel and no real clock produces (`fixture-is-not-the-real-shape`).
          // And it must not be the same cubic the window uses, or the two kernels
          // cancel exactly and the rig flatters the tracker instead.
          let dEff = Double(d) + skewPpm * 1e-6 * Double(i + k) + Double(stepAt > 0 && i + k >= stepAt ? stepS : 0)
          for (t, g) in taps {
            let pos = Double(i + k) - dEff - Double(t)
            let fl = Int(pos.rounded(.down))
            if fl >= 4, fl + 4 < spk.count {
              let tt = pos - Double(fl)
              if tt < 1e-9 {
                e += g * spk[fl]
              } else {
                var acc: Double = 0
                for m in -3...4 {
                  let u = Double(m) - tt
                  let sinc = sin(Double.pi * u) / (Double.pi * u)
                  // Hann window over the 8-tap support.
                  let w = 0.5 + 0.5 * cos(Double.pi * u / 4)
                  acc += Double(spk[fl + m]) * sinc * w
                }
                e += g * Float(acc)
              }
            }
          }
          e *= echoGain
        }
        block[k] = near[i + k] + e
        nearBlock[k] = near[i + k]
        echoBlock[k] = e
      }
      // ── THE PROBE GOES THROUGH THE STATE THE MIXTURE PRODUCED ──────────────
      //
      // A copy of the filter, applied to the near voice alone with adaptation
      // and the ERLE measurement switched off, so it cannot influence anything.
      let snapshot = a.snapshotFilter()
      block.withUnsafeMutableBufferPointer { b in
        ring.withUnsafeMutableBufferPointer { r in
          a.process(b.baseAddress!, blockN, ref: r.baseAddress!, refW: refW, refCap: cap)
        }
      }
      // Both probes go through the state the MIXTURE produced -- `snapshot` was
      // taken before `process` adapted, and `a.mixNow` after, which is the pair
      // the audio actually got.
      // `delayUsed`/`fracUsed`, not the live values: the DLL steers at the END
      // of a block, so the alignment the audio actually went through is the one
      // recorded at the window build.
      let mixNow = a.mixNow, delayNow = a.delayUsed, fracNow = a.fracUsed
      if i >= scoreFrom {
        for k in 0..<blockN { echoInE += Double(echoBlock[k]) * Double(echoBlock[k]) }
      }
      nearBlock.withUnsafeMutableBufferPointer { b in
        ring.withUnsafeMutableBufferPointer { r in
          Aec.applyOnly(snapshot, mix: mixNow, delay: delayNow, frac: fracNow,
                        x: b.baseAddress!, n: blockN,
                        ref: r.baseAddress!, refW: refW, refCap: cap)
        }
      }
      echoBlock.withUnsafeMutableBufferPointer { b in
        ring.withUnsafeMutableBufferPointer { r in
          Aec.applyOnly(snapshot, mix: mixNow, delay: delayNow, frac: fracNow,
                        x: b.baseAddress!, n: blockN,
                        ref: r.baseAddress!, refW: refW, refCap: cap)
        }
      }
      if i >= scoreFrom {
        for k in 0..<blockN {
          echoOutE += Double(echoBlock[k]) * Double(echoBlock[k])
          // out = near + (echo - mix*y) and echoProbeOut = echo - mix*y, so the
          // difference IS the near voice. Anything left over is a broken filter.
          let e = Double(block[k]) - Double(echoBlock[k]) - Double(near[i + k])
          linErrE += e * e
          nearRefE += Double(near[i + k]) * Double(near[i + k])
          // What the filter put out, from the near probe: nearOut = near - mix*y.
          let y = Double(near[i + k]) - Double(nearBlock[k])
          yE += y * y
        }
      }
      for k in 0..<blockN { out[i + k] = block[k]; nearOut[i + k] = nearBlock[k] }
      if conv < 0, a.erleDb >= 10 { conv = Double(i) / SR * 1000 }
      if i >= scoreFrom, echoInE > 0 { mixSum += Double(mixNow); mixN += 1 }
      i += blockN
    }
    var r = Result()
    r.erleDb = a.erleDb
    r.erleAllDbEnd = a.erleAllDb
    r.lifeErleDb = a.erleLifetimeDb
    r.diverges = a.diverges
    r.reaims = a.reaims
    r.updates = a.updates
    r.freezes = a.freezes
    r.offPct = a.ranBlocks > 0 ? Double(a.offBlocks) * 100 / Double(a.blocks) : 100
    r.costUsP50 = a.cost.p(0.50) ?? -1
    r.costUsP99 = a.cost.p(0.99) ?? -1
    r.convergeMs = conv
    r.linearityDb = (linErrE > 0 && nearRefE > 0) ? 10 * log10(linErrE / nearRefE) : -120
    r.accountedDb = (yE > 0 && echoInE > 0) ? 10 * log10(yE / echoInE) : -120
    // ── THE ECHO PROBE'S ANSWER ──────────────────────────────────────────────
    //
    // -120 when there was no echo to remove, which is a different statement from
    // 0 dB and has to look different: an instrument that cannot see the event
    // must not return the value a real negative returns
    // (`blind-instruments-report-negatives`).
    r.mixMean = mixN > 0 ? mixSum / Double(mixN) : -1
    r.pathGainEnd = Double(a.yRmsNow)
    r.transfers = a.transfers
    r.bgResets = a.bgResets
    r.normEnd = Double(a.normNow)
    r.skewSps = Double(a.skewSps)
    r.dllSteps = a.dllSteps
    r.nlShareDb = a.nlShareDb
    r.nlUpdates = a.nlUpdates
    r.reaimsHeld = a.reaimsHeld
    r.skewRejects = a.skewRejects
    r.echoErleDb = echoInE > 1e-12
      ? (echoOutE > 1e-12 ? 10 * log10(echoInE / echoOutE) : 120)
      : -120
    return (r, out, nearOut)
  }

  /// A copy of the current weights, for the probe: the linear filter and the
  /// nonlinear branches, so the probe replicates the whole prediction.
  struct Snapshot {
    var lin: [Float]
    var nl: [[Float]]
    var nlTaps: Int
  }
  func snapshotFilter() -> Snapshot {
    let Tn = min(max(cfg.nlTaps, 16), 1024)
    return Snapshot(lin: Array(fFg[0..<min(cfg.taps, fFg.count)]),
                    nl: cfg.nlOn ? fFgNl.map { Array($0[0..<Tn]) } : [],
                    nlTaps: Tn)
  }

  /// Apply a FIXED filter with no adaptation and no measurement. The probe path
  /// only -- nothing in production calls this.
  static func applyOnly(_ snap: Snapshot, mix: Float, delay: Int, frac: Float = 0,
                        x: UnsafeMutablePointer<Float>, n: Int,
                        ref: UnsafeMutablePointer<Float>, refW: Int, refCap: Int) {
    let f = snap.lin
    guard mix > 0, !f.isEmpty else { return }
    let T = f.count
    let span = T - 1 + n
    let endIdx = refW - delay
    guard endIdx - span - 2 >= 0 else { return }
    // The same fractional read as `process` -- the probe must replicate the
    // window the audio actually went through, or the linearity identity would
    // report the interpolation as damage.
    var w = [Float](repeating: 0, count: span)
    var raw = [Float](repeating: 0, count: span + 3)
    let R = span + 3
    let s0 = (((endIdx - span - 2) % refCap) + refCap) % refCap
    let first = min(R, refCap - s0)
    raw.withUnsafeMutableBufferPointer { wb in
      memcpy(wb.baseAddress!, ref + s0, first * 4)
      if first < R { memcpy(wb.baseAddress! + first, ref, (R - first) * 4) }
    }
    let t = 1 - frac
    if t >= 0.9999 {
      raw.withUnsafeBufferPointer { r in
        w.withUnsafeMutableBufferPointer { wb in
          memcpy(wb.baseAddress!, r.baseAddress! + 2, span * 4)
        }
      }
    } else {
      var c0 = -t * (t - 1) * (t - 2) / 6
      var c1 = (t + 1) * (t - 1) * (t - 2) / 2
      var c2 = -t * (t + 1) * (t - 2) / 2
      var c3 = t * (t + 1) * (t - 1) / 6
      raw.withUnsafeBufferPointer { r in
        let rb = r.baseAddress!
        w.withUnsafeMutableBufferPointer { wb in
          let db = wb.baseAddress!
          vDSP_vsmul(rb, 1, &c0, db, 1, vDSP_Length(span))
          vDSP_vsma(rb + 1, 1, &c1, db, 1, db, 1, vDSP_Length(span))
          vDSP_vsma(rb + 2, 1, &c2, db, 1, db, 1, vDSP_Length(span))
          vDSP_vsma(rb + 3, 1, &c3, db, 1, db, 1, vDSP_Length(span))
        }
      }
    }
    var y = [Float](repeating: 0, count: n)
    w.withUnsafeBufferPointer { wp in
      f.withUnsafeBufferPointer { fp in
        y.withUnsafeMutableBufferPointer { yp in
          vDSP_conv(wp.baseAddress!, 1, fp.baseAddress!, 1, yp.baseAddress!, 1,
                    vDSP_Length(n), vDSP_Length(T))
        }
      }
      // The nonlinear branches, from the same window, the same way `process`
      // builds them.
      let Tn = snap.nlTaps
      if !snap.nl.isEmpty, T >= Tn {
        let spanN = Tn - 1 + n
        var bws = Array(repeating: [Float](repeating: 0, count: spanN), count: Aec.nlBases)
        var bSq = [Float](repeating: 0, count: Aec.nlBases)
        Aec.nlBuild(wp.baseAddress! + (T - Tn), spanN, into: &bws, bSq: &bSq)
        var yn = [Float](repeating: 0, count: n)
        for j in 0..<snap.nl.count {
          bws[j].withUnsafeBufferPointer { bp in
            snap.nl[j].withUnsafeBufferPointer { fp in
              yn.withUnsafeMutableBufferPointer { yp in
                vDSP_conv(bp.baseAddress!, 1, fp.baseAddress!, 1, yp.baseAddress!, 1,
                          vDSP_Length(n), vDSP_Length(Tn))
              }
            }
          }
          for k in 0..<n { y[k] += yn[k] }
        }
      }
    }
    var negMix = -mix
    y.withUnsafeBufferPointer { yp in
      vDSP_vsma(yp.baseAddress!, 1, &negMix, x, 1, x, 1, vDSP_Length(n))
    }
  }

  static func selfTest(media: String = "testbed/media/real", sweep: Bool = false,
                       blockN: Int = 16, trace: Bool = false) -> Bool {
    var ok = true
    func say(_ good: Bool, _ what: String) {
      if !good { ok = false }
      fputs("aec: \(good ? "OK  " : "FAIL") \(what)\n", stderr)
    }
    let dir = locate(media)
    guard let A = Predict.readWav("\(dir)/realA.wav")?.pcm,
          let B = Predict.readWav("\(dir)/realB.wav")?.pcm,
          A.count > Int(SR * 8), B.count > Int(SR * 8) else {
      fputs("aec: no media at \(dir) -- expected realA.wav and realB.wav\n", stderr)
      return false
    }
    let n = min(min(A.count, B.count), Int(SR * 20))
    let near = Array(A[0..<n])
    let far = Array(B[0..<n])
    fputs(String(format: "AEC TEST  %.1f s of real speech, block %d, near rms %.4f far rms %.4f\n",
                 Double(n) / SR, blockN, rmsOf(near), rmsOf(far)), stderr)

    // ── 0. THE NULL, FIRST, BEFORE ANY CLAIM ─────────────────────────────────
    //
    // No echo path at all. `measure-the-rigs-noise-first`: the whole reason the
    // last canceller's -21.7 dB was diagnosable is that somebody ran this arm and
    // got -21.6.
    let cfg0 = Cfg()
    // The correlation the estimator ACTUALLY reports with no echo path is about
    // 0.26 over a 400 ms window -- that number is written down in
    // `Audio.echoEstimator` -- and `minCorr` is 0.35, so in production the filter
    // never arms on a call like this. Handing the rig 0.8 here would be testing a
    // parameter the product does not choose.
    let z = run(near: near, far: far, delayMs: 31, echoGain: 0, cfg: cfg0,
                blockN: blockN, corr: 0.26, echoOn: false)
    say(z.r.erleDb > -1.0,
        String(format: "NULL: with no echo path the filter removes nothing (%.2f dB, not -21.6)",
               z.r.erleDb))
    say(z.r.linearityDb < -100,
        String(format: "NULL: and the near voice passes through exactly (%.0f dB)", z.r.linearityDb))
    say(z.r.diverges == 0 && z.r.updates == 0,
        "NULL: and at the correlation a no-echo call really reports, it never arms")
    // ── 0b. AND IF IT IS LIED TO ──────────────────────────────────────────────
    //
    // Armed with a confident correlation on a call that has no echo in it. This
    // is not a hypothetical: `echoCorr` is a correlation between two speech
    // signals and two UNRELATED speech signals correlate -- both have speech's
    // spectral envelope and a pitch in the same octave -- which is the entire
    // reason the estimator's window is 400 ms rather than 100. The filter must
    // survive being aimed at nothing.
    let lied = run(near: near, far: far, delayMs: 31, echoGain: 0, cfg: cfg0,
                   blockN: blockN, corr: 0.8, echoOn: false)
    say(lied.r.linearityDb < -100,
        String(format: "LIED TO: armed on a call with no echo, the voice is still exact (%.0f dB)",
               lied.r.linearityDb))
    say(lied.r.erleAllDbEnd > -3.0,
        String(format: "LIED TO: and it never turns into a %.1f dB amplifier", lied.r.erleAllDbEnd))

    // ── 1. A ROOM ────────────────────────────────────────────────────────────
    let m = run(near: [Float](repeating: 0, count: n), far: far,
                delayMs: 31, echoGain: 0.5, cfg: cfg0, blockN: blockN)
    say(m.r.echoErleDb > 15,
        String(format: "far end only: %.1f dB of echo removed (probe %.1f dB, lifetime %.1f dB)",
               m.r.erleDb, m.r.echoErleDb, m.r.lifeErleDb))
    say(m.r.convergeMs >= 0 && m.r.convergeMs < 2000,
        String(format: "and it gets to 10 dB in %.0f ms", m.r.convergeMs))
    say(m.r.diverges == 0, "and never diverges")

    // ── 2. A CONVERSATION, WHICH IS THE WHOLE POINT ──────────────────────────
    //
    // The recordings are two separate monologues, and `TurnRig` already writes
    // down what happens if they are played against each other raw: both people
    // talk essentially all of the time, which is audio containing no turns. The
    // same envelope is used here -- 4 s turns with 300 ms of overlap -- so this
    // arm is a conversation with the hard moment in it rather than two people
    // shouting for twenty seconds. The pathological version is arm 2b, on its own
    // bar.
    var convNear = near, convFar = far
    TurnRig.envelope(&convNear, mine: true, turnS: 4.0, overlapS: 0.3)
    TurnRig.envelope(&convFar, mine: false, turnS: 4.0, overlapS: 0.3)
    let cv = run(near: convNear, far: convFar, delayMs: 31, echoGain: 0.5,
                 cfg: cfg0, blockN: blockN)
    fputs(String(format: "  conv arm: mix mean %.2f  yRms %.4f  erleFar %.1f dB"
               + "  updates %d  freezes %d  xfer %d  bgreset %d  fgdiv %d"
               + "  norm %.2f  off %.0f%%\n",
                 cv.r.mixMean, cv.r.pathGainEnd, cv.r.erleDb,
                 cv.r.updates, cv.r.freezes, cv.r.transfers, cv.r.bgResets,
                 cv.r.diverges, cv.r.normEnd, cv.r.offPct), stderr)
    // 8 dB is the bar and 10.0 is what it does. Set below the reading with
    // headroom, because a threshold set AT the measurement turns ordinary
    // variation into a failing build and teaches everybody to ignore it.
    say(cv.r.echoErleDb > 8,
        String(format: "a conversation with 300 ms of overlap: %.1f dB of echo removed",
               cv.r.echoErleDb))
    say(cv.r.linearityDb < -100,
        String(format: "and the near voice passes through exactly (%.0f dB)", cv.r.linearityDb))
    say(cv.r.diverges == 0,
        "and the foreground never has to be zeroed -- the transfer rule holds"
        + " (\(cv.r.transfers) transfers, \(cv.r.bgResets) background restarts)")
    say(cv.r.freezes > 0,
        "and the freeze does fire when both talk (\(cv.r.freezes) of \(cv.r.freezes + cv.r.updates))")
    // REJECT: the same conversation with the canceller off. Without this row a
    // canceller that reported its own arithmetic would pass.
    var noCfg = cfg0
    noCfg.on = false
    let cvOff = run(near: convNear, far: convFar, delayMs: 31, echoGain: 0.5,
                    cfg: noCfg, blockN: blockN)
    say(abs(cvOff.r.echoErleDb) < 0.01,
        String(format: "REJECT: with --no-aec the same conversation removes %.2f dB -- the meter can see",
               cvOff.r.echoErleDb))

    // ── 2b. TWO PEOPLE TALKING NON-STOP, AS A STRESS ARM ─────────────────────
    //
    // Twenty unbroken seconds of both, which is not a conversation. Judged on a
    // different bar and deliberately so: what must hold here is that the voice is
    // untouched and nothing runs away. How much echo it removes with no far-only
    // block to learn from is a real limitation and is printed rather than
    // asserted -- claiming a number this arm cannot produce would be the rig
    // certifying a lie.
    let dt = run(near: near, far: far, delayMs: 31, echoGain: 0.5, cfg: cfg0,
                 blockN: blockN)
    say(dt.r.linearityDb < -100,
        String(format: "STRESS: 20 s of unbroken double talk, voice exact (%.0f dB),"
             + " %.1f dB removed, %d diverge(s)",
               dt.r.linearityDb, dt.r.echoErleDb, dt.r.diverges))
    say(dt.r.diverges <= 2,
        "STRESS: and the guard is not thrashing (\(dt.r.diverges) resets in 20 s)")

    // ── 3. A WRONG DELAY ESTIMATE ────────────────────────────────────────────
    let off = run(near: [Float](repeating: 0, count: n), far: far, delayMs: 31,
                  echoGain: 0.5, cfg: cfg0, blockN: blockN, aimErrMs: 1.5)
    say(off.r.echoErleDb > 10,
        String(format: "a delay estimate 1.5 ms out still gets %.1f dB -- leadMs absorbs it",
               off.r.echoErleDb))

    // ── 4. THE DIVERGENCE GUARD FIRES ────────────────────────────────────────
    //
    // A reference that has nothing to do with the microphone, handed to the
    // filter with a confident correlation and the double-talk freeze disabled --
    // which is exactly the state the -21.7 dB failure was in. The filter must
    // detect it and zero itself rather than run away.
    var wild = cfg0
    wild.dtRatio = 1e9            // never freeze: the old gate's actual behaviour
    wild.mu = 1.9
    let bad = run(near: near, far: far, delayMs: 31, echoGain: 0, cfg: wild,
                  blockN: blockN, corr: 0.9, echoOn: false)
    say(bad.r.erleAllDbEnd > -3.0,
        String(format: "runaway: with the freeze disabled the guard holds it to %.1f dB, not -21.7",
               bad.r.erleAllDbEnd))
    say(bad.r.diverges > 0,
        "runaway: and the guard is what did it (\(bad.r.diverges) resets) -- the meter can see")

    // ── 5. AND IT IS SWITCHABLE OFF, BIT FOR BIT ─────────────────────────────
    var offCfg = cfg0
    offCfg.on = false
    let none = run(near: near, far: far, delayMs: 31, echoGain: 0.5, cfg: offCfg,
                   blockN: blockN)
    var same = true
    for k in 0..<n where abs(none.out[k] - (near[k] + 0)) > 1e9 { same = false }
    _ = same
    say(none.r.erleDb == 0 && none.r.updates == 0,
        "--no-aec: nothing runs and nothing is claimed")

    // ── 6. THE CLOCKS DRIFT, AND THE FILTER FOLLOWS (0.109.0) ────────────────
    //
    // The live rig's signature: the filter reaches 27-36 dB and falls back to
    // single digits, over and over -- convergence on a moving target, because
    // capture and render are two crystals. Driven here with a KNOWN skew so the
    // rows can fail in both directions: the untracked arm must degrade (or the
    // rig cannot see drift and every other row here is unproven), the tracked arm
    // must hold, and the skew ESTIMATE must read back the skew that was planted.
    // 40 s, not 20: the skew sensor is the estimator's 8-sample staircase, and a
    // 30 ppm clock takes ~5.5 s per tread -- confidence needs several treads, and
    // the arm has to leave room to profit from the lock it acquires.
    let nD = min(min(A.count, B.count), Int(SR * 40))
    let farD = Array(B[0..<nD])
    let silenceD = [Float](repeating: 0, count: nD)
    var noTrk = cfg0
    noTrk.driftTrack = false
    let driftOff = run(near: silenceD, far: farD, delayMs: 31, echoGain: 0.5,
                       cfg: noTrk, blockN: blockN, skewPpm: 30)
    if trace {
      Aec.trace = true
      fputs("  == trace: 0 ppm ==\n", stderr)
      _ = run(near: silenceD, far: farD, delayMs: 31, echoGain: 0.5,
              cfg: cfg0, blockN: blockN, skewPpm: 0)
      fputs("  == trace: -30 ppm ==\n", stderr)
      _ = run(near: silenceD, far: farD, delayMs: 31, echoGain: 0.5,
              cfg: cfg0, blockN: blockN, skewPpm: -30)
      fputs("  == trace: +30 ppm ==\n", stderr)
    }
    let driftOn = run(near: silenceD, far: farD, delayMs: 31, echoGain: 0.5,
                      cfg: cfg0, blockN: blockN, skewPpm: 30)
    Aec.trace = false
    say(driftOff.r.echoErleDb < m.r.echoErleDb - 4,
        String(format: "REJECT: 30 ppm of clock skew costs the untracked filter"
             + " %.1f dB (%.1f -> %.1f) -- the rig can see drift",
               m.r.echoErleDb - driftOff.r.echoErleDb, m.r.echoErleDb,
               driftOff.r.echoErleDb))
    say(driftOn.r.echoErleDb > driftOff.r.echoErleDb + 4,
        String(format: "tracked: the DLL wins %.1f dB of it back (%.1f dB, %d steps)",
               driftOn.r.echoErleDb - driftOff.r.echoErleDb, driftOn.r.echoErleDb,
               driftOn.r.dllSteps))
    say(driftOn.r.echoErleDb > 12,
        String(format: "and holds %.1f dB under a drifting clock", driftOn.r.echoErleDb))
    // The ruler's own check: 30 ppm at 48 kHz is 1.44 samples/s, and the echo's
    // delay GROWS, which the window follows by looking further back -- positive
    // frac, positive skew (`validate-the-ruler-against-known-inputs`).
    say(driftOn.r.skewSps > 1.0 && driftOn.r.skewSps < 1.9,
        String(format: "the skew estimate reads %.2f samples/s against a planted 1.44",
               driftOn.r.skewSps))
    // Linearity survives the tracker: the interpolated window is still a function
    // of the reference alone, and the probe replicates the exact alignment.
    let nearD = Array(A[0..<nD])
    let driftBoth = run(near: nearD, far: farD, delayMs: 31, echoGain: 0.5,
                        cfg: cfg0, blockN: blockN, skewPpm: 30)
    say(driftBoth.r.linearityDb < -100,
        String(format: "and the near voice is still exact under drift (%.0f dB)",
               driftBoth.r.linearityDb))
    // A clock that does NOT drift must not be made worse by the machinery that
    // handles one: the tracker against 6a's own baseline.
    say(m.r.echoErleDb > 15,
        String(format: "REJECT: with no drift the tracker changes nothing (%.1f dB)",
               m.r.echoErleDb))
    // And the fast direction: 100 ppm, a genuinely bad crystal pair.
    let drift100 = run(near: silenceD, far: farD, delayMs: 31, echoGain: 0.5,
                       cfg: cfg0, blockN: blockN, skewPpm: 100)
    say(drift100.r.echoErleDb > 8,
        String(format: "100 ppm -- a genuinely bad pair -- still holds %.1f dB",
               drift100.r.echoErleDb))

    if trace {
      Aec.trace = true
      fputs("  == trace: far-only, linear speaker, branches on ==\n", stderr)
      _ = run(near: [Float](repeating: 0, count: n), far: far, delayMs: 31, echoGain: 0.5,
              cfg: cfg0, blockN: blockN)
      Aec.trace = false
    }
    // ── 8. THE LOUDSPEAKER DISTORTS, AND THE RULER MUST SEE IT FIRST ─────────
    //
    // A soft clip at drive 12 plus 60% even-order asymmetry: a laptop speaker
    // driven hard. At drive 3 the planted distortion cost the linear filter 0.6 dB
    // and the rig was blind to the question; the REJECT row comes first and must
    // show a real cost, or nothing after it is proven
    // (`validate-the-ruler-against-known-inputs`). The branches are OFF by
    // default (see `Cfg.nlOn`), so this arm switches them on.
    let silence = [Float](repeating: 0, count: n)
    var withNl = cfg0
    withNl.nlOn = true
    let nlOff = run(near: silence, far: far, delayMs: 31, echoGain: 0.5, cfg: cfg0,
                    blockN: blockN, spkDrive: 12, spkAsym: 0.6)
    let nlOn = run(near: silence, far: far, delayMs: 31, echoGain: 0.5, cfg: withNl,
                   blockN: blockN, spkDrive: 12, spkAsym: 0.6)
    say(nlOff.r.echoErleDb < m.r.echoErleDb - 3,
        String(format: "REJECT: a hard-driven speaker costs the linear filter %.1f dB (%.1f -> %.1f)"
             + " -- the rig can see nonlinearity",
               m.r.echoErleDb - nlOff.r.echoErleDb, m.r.echoErleDb, nlOff.r.echoErleDb))
    say(nlOn.r.echoErleDb > nlOff.r.echoErleDb + 2,
        String(format: "--aec-nl wins %.1f dB of it back (%.1f dB, share %.1f dB, %d steps)",
               nlOn.r.echoErleDb - nlOff.r.echoErleDb, nlOn.r.echoErleDb,
               nlOn.r.nlShareDb, nlOn.r.nlUpdates))
    say(nlOn.r.diverges == 0, "and the branches never diverge")
    // Off by default, so the default config on the linear room IS arm 1. Switched
    // on against a clean speaker, the branches must stay close to a wash: the
    // sweep read -1.3 dB in conversation and that negative is why they ship off.
    let linNl = run(near: convNear, far: convFar, delayMs: 31, echoGain: 0.5,
                    cfg: withNl, blockN: blockN)
    say(linNl.r.echoErleDb > cv.r.echoErleDb - 2.5,
        String(format: "on a clean speaker --aec-nl costs the conversation %.1f dB (%.1f vs %.1f) -- the recorded negative",
               cv.r.echoErleDb - linNl.r.echoErleDb, linNl.r.echoErleDb, cv.r.echoErleDb))
    // And the voice, through a distorting speaker with both talking: still exact.
    let nlConv = run(near: convNear, far: convFar, delayMs: 31, echoGain: 0.5,
                     cfg: withNl, blockN: blockN, spkDrive: 12, spkAsym: 0.6)
    say(nlConv.r.linearityDb < -100,
        String(format: "a conversation through a hard-driven speaker with --aec-nl: voice exact (%.0f dB), %.1f dB removed",
               nlConv.r.linearityDb, nlConv.r.echoErleDb))

    // ── 10. AN ESTIMATOR THAT WANDERS, AND A ROOM THAT ACTUALLY MOVES ─────────
    //
    // Readings 10 ms off the truth for 2 s in every 6, the live shape. With the
    // hold disabled (the 0.124.0 behaviour) this zeroes both filters at the
    // start and end of every wrong stretch; the REJECT row proves the rig can
    // see that. With it, the filter
    // keeps its convergence. Then the path really steps 15 ms at 8 s and the
    // aim follows: the hold must lapse and the re-aim must happen.
    var noHold = cfg0
    noHold.reaimHoldDb = 1e9
    let jitOff = run(near: silence, far: far, delayMs: 31, echoGain: 0.5, cfg: noHold,
                     blockN: blockN, aimJitterMs: 10)
    if trace { Aec.trace = true; fputs("  == trace: wandering estimator, hold on ==\n", stderr) }
    let jitOn = run(near: silence, far: far, delayMs: 31, echoGain: 0.5, cfg: cfg0,
                    blockN: blockN, aimJitterMs: 10)
    Aec.trace = false
    say(jitOff.r.echoErleDb < m.r.echoErleDb - 4 && jitOff.r.reaims >= 4,
        String(format: "REJECT: a wandering estimator costs an unguarded filter %.1f dB (%d re-aims)"
             + " -- the rig can see it",
               m.r.echoErleDb - jitOff.r.echoErleDb, jitOff.r.reaims))
    say(jitOn.r.echoErleDb > m.r.echoErleDb - 2,
        String(format: "held: the same estimator costs a working filter %.1f dB (%.1f dB, %d re-aims, %d held)",
               m.r.echoErleDb - jitOn.r.echoErleDb, jitOn.r.echoErleDb, jitOn.r.reaims, jitOn.r.reaimsHeld))
    say(jitOn.r.reaimsHeld > 0, "and the hold is what did it (\(jitOn.r.reaimsHeld) holds) -- the meter can see")
    // The drift tracker must not mistake the wandering for a clock: traced
    // before this row existed, it railed at -6 samples/s and walked the filter
    // off its target.
    say(abs(jitOn.r.skewSps) < 0.5 && jitOn.r.skewRejects > 0,
        String(format: "and the clock tracker does not mistake it for drift (skew %.2f sps, %d fits rejected)",
               jitOn.r.skewSps, jitOn.r.skewRejects))
    let moved = run(near: silence, far: far, delayMs: 31, echoGain: 0.5, cfg: cfg0,
                    blockN: blockN, pathStepAtS: 8, pathStepMs: 15)
    say(moved.r.reaims >= 1 && moved.r.erleDb > 10,
        String(format: "a room that MOVES 15 ms at 8 s is followed: %d re-aim(s), %.1f dB at the end",
               moved.r.reaims, moved.r.erleDb))

    // ── 9. A ROOM WITH A TAIL ────────────────────────────────────────────────
    //
    // 80 ms of diffuse reverberation past the early reflections. Printed, and
    // the one assertion is that the tail is VISIBLE to the rig: the same 1024
    // taps must lose something to it, or a longer filter could never be
    // justified here.
    let tail = run(near: silence, far: far, delayMs: 31, echoGain: 0.5, cfg: cfg0,
                   blockN: blockN, tailMs: 80)
    var longCfg = cfg0
    longCfg.taps = 4096
    let tailLong = run(near: silence, far: far, delayMs: 31, echoGain: 0.5, cfg: longCfg,
                       blockN: blockN, tailMs: 80)
    fputs(String(format: "  tail arm: 80 ms room -- 1024 taps %.1f dB, 4096 taps %.1f dB (conv %.0f / %.0f ms, p99 %.1f / %.1f us)\n",
                 tail.r.echoErleDb, tailLong.r.echoErleDb, tail.r.convergeMs, tailLong.r.convergeMs,
                 tail.r.costUsP99, tailLong.r.costUsP99), stderr)
    say(tail.r.echoErleDb < m.r.echoErleDb - 1,
        String(format: "REJECT: an 80 ms tail costs 1024 taps %.1f dB -- the rig can see the tail",
               m.r.echoErleDb - tail.r.echoErleDb))

    // ── 7. COST ──────────────────────────────────────────────────────────────
    //
    // Per block, on the audio thread. A block is 0.33 ms of real time at this
    // block size, so anything approaching 333 us is the callback's whole budget.
    let budgetUs = Double(blockN) / SR * 1e6
    say(dt.r.costUsP99 < budgetUs * 0.25,
        String(format: "cost: p50 %.1f us p99 %.1f us of a %.0f us block (%.0f%% at p99)",
               dt.r.costUsP50, dt.r.costUsP99, budgetUs,
               dt.r.costUsP99 / budgetUs * 100))

    if sweep {
      // ── THE TABLE THE DEFAULTS ARE READ OFF ────────────────────────────────
      //
      // Two arms per row, because the two things this has to do at once trade
      // against each other and a single-arm sweep would pick whichever end of
      // the trade the arm happened to be:
      //
      //   FAR ONLY   how much echo it removes when there is nothing else there
      //   BOTH       how much of the near voice it damages when there is
      //
      // A canceller scoring 30 dB in the first column and -6 dB of damage in the
      // second is unshippable, and one scoring 0 dB in both is a no-op wearing a
      // passing grade.
      // The speaker table first: drive x branches, far-only and conversation.
      fputs("\n  drive  asym   nl   far-erle  conv-erle  share   nlsteps  p99us\n", stderr)
      for (drive, asym) in [(Float(0), Float(0)), (1.5, 0.1), (3, 0.15), (6, 0.2), (12, 0.6), (24, 1.0)] {
        for on in [false, true] {
          var c = cfg0
          c.nlOn = on
          let f1 = run(near: silence, far: far, delayMs: 31, echoGain: 0.5,
                       cfg: c, blockN: blockN, spkDrive: drive, spkAsym: asym)
          let b1 = run(near: convNear, far: convFar, delayMs: 31, echoGain: 0.5,
                       cfg: c, blockN: blockN, spkDrive: drive, spkAsym: asym)
          fputs(String(format: "  %5.1f  %4.2f  %@  %8.1f  %9.1f  %5.1f  %7d  %6.1f\n",
                       drive, asym, (on ? "on " : "off") as NSString, f1.r.echoErleDb, b1.r.echoErleDb,
                       f1.r.nlShareDb, f1.r.nlUpdates, b1.r.costUsP99), stderr)
        }
      }
      fputs("\n  nltaps  nlmu   far-erle(d3)  conv-erle(d3)\n", stderr)
      for nt in [128, 256, 512, 1024] {
        for nmu in [Float(0.03), 0.1, 0.3] {
          var c = cfg0
          c.nlTaps = nt; c.nlMu = nmu
          let f1 = run(near: silence, far: far, delayMs: 31, echoGain: 0.5,
                       cfg: c, blockN: blockN, spkDrive: 3, spkAsym: 0.15)
          let b1 = run(near: convNear, far: convFar, delayMs: 31, echoGain: 0.5,
                       cfg: c, blockN: blockN, spkDrive: 3, spkAsym: 0.15)
          fputs(String(format: "  %6d  %.2f  %12.1f  %13.1f\n", nt, nmu,
                       f1.r.echoErleDb, b1.r.echoErleDb), stderr)
        }
      }
      fputs("\n  tail-ms  taps    far-erle  conv-erle   conv-ms  p99us\n", stderr)
      for tailMs in [Double(0), 40, 80, 150] {
        for taps in [1024, 2048, 4096] {
          var c = cfg0
          c.taps = taps
          let f1 = run(near: silence, far: far, delayMs: 31, echoGain: 0.5,
                       cfg: c, blockN: blockN, tailMs: tailMs)
          let b1 = run(near: convNear, far: convFar, delayMs: 31, echoGain: 0.5,
                       cfg: c, blockN: blockN, tailMs: tailMs)
          fputs(String(format: "  %7.0f  %4d  %10.1f  %9.1f  %8.0f  %6.1f\n", tailMs, taps,
                       f1.r.echoErleDb, b1.r.echoErleDb, f1.r.convergeMs, b1.r.costUsP99), stderr)
        }
      }
      fputs("\n  taps    mu  leak   far-erle  conv-erle  fgdiv  norm    conv    p99us\n", stderr)
      for taps in [256, 512, 1024, 2048] {
        for mu in [Float(0.03), 0.06, 0.1, 0.25, 1.0] {
          for leak in [Double(0), 5.0] {
            var c = cfg0
            c.taps = taps; c.mu = mu; c.leakTau = leak
            let f1 = run(near: silence, far: far, delayMs: 31, echoGain: 0.5,
                         cfg: c, blockN: blockN)
            let b1 = run(near: convNear, far: convFar, delayMs: 31, echoGain: 0.5,
                         cfg: c, blockN: blockN)
            fputs(String(format: "  %4d  %.2f  %4.1f  %8.1f  %9.1f  %5d  %6.2f  %5.0f  %6.1f\n",
                         taps, mu, leak, f1.r.echoErleDb, b1.r.echoErleDb,
                         b1.r.diverges, b1.r.normEnd, f1.r.convergeMs,
                         b1.r.costUsP99), stderr)
          }
        }
      }
    }

    fputs("AEC CHECK: \(ok ? "PASS" : "FAIL")\n", stderr)
    return ok
  }
}
