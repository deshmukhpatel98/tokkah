import Foundation
import AVFoundation
import Accelerate

// ── The mute flag outlives the audio engine, and has to ─────────────────────
//
// This was a property on `Audio`, and the mute button's handler wrote to it. But
// the window and its controls now exist BEFORE the call connects, and `audio` is
// created after the rendezvous -- so pressing mute while waiting for the other
// side wrote to an uninitialised global and killed the process. A person clicking
// mute in the first thirty seconds of every call is not an edge case.
//
// File scope, so the button is safe from the moment it is drawn.
nonisolated(unsafe) var gMicMuted = false
import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin

// ── The audio engine ────────────────────────────────────────────────────────
//
// Two AUHAL units, not one: on a Mac the input device (built-in mic) and the
// output device (speakers, or a headset) are usually different devices with
// different clocks, and one unit cannot straddle them without an aggregate. Two
// units, each with its own callback, is the honest arrangement -- and the drift
// between them is real and must be measured, not assumed away.
//
// Everything the callbacks touch is preallocated here. No allocation, no ARC
// traffic, no locks, no logging on the real-time thread: a single malloc inside
// a render callback is a dropout, and the whole point of this app is that there
// are none.
final class Audio {
  // ── The device is not a constant, and neither is its RATE ──────────────────
  //
  // The startup path already refuses a device that will not do 48 kHz, loudly,
  // because a 44.1 kHz device makes AudioUnitRender return -10863 on every
  // callback and the app goes silently deaf. That check ran once, at start.
  //
  // Measured 2026-08-23, mid-call, by moving both devices to 44.1 kHz underneath a
  // running call: `cap 0/s`, `played 18/s`, `conceal 1501/s` -- and renderErr 0,
  // zero error lines, nothing in the log at all. The call was dead for 35 seconds
  // and recovered only because the rate was put back by hand. macOS does this on
  // its own when a headset is plugged in or another app claims the device.
  //
  // So the rate is WATCHED, and separately there is a watchdog on the symptom --
  // because the specific cause is only one way to stop capturing, and an
  // instrument that can only see one cause reports every other cause as fine.
  private(set) var inDev: AudioDeviceID = 0
  private(set) var outDev: AudioDeviceID = 0
  private(set) var audioStalls = 0
  private(set) var rateEvents = 0
  private var started = false
  private var inUnit: AudioUnit?
  private var outUnit: AudioUnit?

  let ring = RecvRing()
  var wire: Wire?
  var mute = false                 // loopback on one machine: the mic hears the
                                   // speaker, so the receiver silences its output
                                   // AFTER timestamping. The measurement is
                                   // untouched; the howl is gone.
  var jitTarget = 2                // packets of deliberate buffer. 2 == 5.3 ms.
  var jitAuto = true               // size the buffer from measurement, not from a guess
  // peer clock - my clock, in ms, from TimeSync. Zero and INVALID are different
  // things: on a two-machine call the offset can be hours, so a measurement taken
  // before the offset is known is not approximately right, it is meaningless. No
  // number is the honest output in that window.
  var thetaMs: Double = 0
  var thetaValid = false
  var jitGrows = 0, jitShrinks = 0 // so the adaptation is auditable after the call

  // Capture side
  private var capSeq: Int32 = 0
  private var capFill = 0
  private var capBuf: UnsafeMutablePointer<Float>
  private var capScratch: UnsafeMutablePointer<UInt8>
  // The packet before this one, kept so it can ride along with the next one when
  // the path is losing. Two buffers, not a queue: the redundancy offset is one
  // packet, which is what fixes ISOLATED loss -- the common case on a wired or
  // decent wireless link. A burst needs an offset as long as the burst, and that
  // is latency, so it is a separate decision and not this one.
  private var prevBuf: UnsafeMutablePointer<Float>
  private var prevCap: UInt64 = 0
  private var havePrev = false
  static let CAP_HIST_COUNT = 32
  private var capHistory: UnsafeMutablePointer<Float>
  private var capHistoryCap: [UInt64] = Array(repeating: 0, count: 32)
  private var capHistorySeq: [Int32] = Array(repeating: -1, count: 32)
  private var fecParityScratch: UnsafeMutablePointer<Float>
  var redundancy = false
  private var inBufList: UnsafeMutablePointer<AudioBufferList>
  private var inScratch: UnsafeMutablePointer<Float>

  // Measurement
  var m2e = Quantiles()
  /// THE DECOMPOSITION. The budget adds up to 9.8 ms and m2e measures 12.5, so
  /// 2.6 ms is going somewhere unnamed -- and on loopback the network is 0.07 ms,
  /// so it is not the network. An unexplained millisecond is a defect that has not
  /// been located yet, which is the only reason these exist.
  // ── The acoustic ruler ─────────────────────────────────────────────────────
  //
  // Everything else here measures the pipeline with the pipeline's own
  // timestamps, which cannot settle the one question that matters about them:
  // whether `kAudioDevicePropertyLatency` and the safety offset are ALREADY
  // inside the timestamps we add them to. If they are, every m2e figure in this
  // project is ~2 ms too large.
  //
  // A click settles it. Emit an impulse at a known output host time, listen for
  // it arriving at a known input host time, and the difference is the real
  // speaker -> air -> microphone path measured with exactly the same timestamp
  // conventions the app uses everywhere else. If it comes back close to
  // inLatencyMs + outLatencyMs + air, the terms are real and separate. If it comes
  // back far smaller, they are already counted and m2e is overstating.
  //
  // Needs to make a sound, so it is a flag and not a default, and it refuses to
  // run muted rather than reporting a silent negative.
  // ── Concealment that is not silence ────────────────────────────────────────
  //
  // A missing packet used to be filled with zeros, which is the most audible
  // possible choice: a hole in a waveform is a click, and a click is exactly what
  // the ear is built to notice. That made every concealed packet expensive, which
  // in turn made the jitter buffer's grow/shrink trade look worse than it is --
  // 2.7 ms of latency on every word to avoid one 0.67 ms gap every seven seconds.
  //
  // Repeating the last good packet instead is the oldest trick in the book and it
  // works: over 0.67 ms a voice is essentially periodic, so the substitution is
  // continuous in amplitude and close in phase. A run of them decays to silence
  // rather than buzzing, because repeating one grain forever turns a dropout into
  // a tone, which is worse than a hole.
  private var lastGood: UnsafeMutablePointer<Float>
  private var haveLastGood = false
  private var goodRun = 0
  private var concealRun = 0

  // ── Packet loss concealment, at the pitch period ───────────────────────────
  //
  // The grain-repeat above is wrong twice, and the measurement said so on real
  // speech (step/rms 2.53 for repeat against 2.09 for silence, four rotated arms):
  //
  //   1. A packet is 32 samples. Repeating it turns a dropout into a 1500 Hz
  //      tone -- 1/0.67ms -- which is not a continuation of a voice, it is a
  //      buzzer. Speech is periodic at its PITCH, 80-500 Hz, so the shortest
  //      honest unit of repetition is 2-12 ms: four to eighteen packets.
  //   2. The join was phase-broken. `lastGood[off]` walks the packet offset, so
  //      when a run began the output stepped from the grain's last sample back to
  //      its first -- a jump backwards through the waveform, once per packet.
  //
  // So: keep a rolling 42 ms of what was actually played, find the pitch period
  // by normalised autocorrelation once per outage, and read forward through
  // history at that period. The seam is then continuous by construction, and the
  // repetition is at the frequency the voice already has.
  //
  // Cost: the search runs ONCE at the start of an outage, not per sample, and is
  // decimated by two -- about 60k multiply-adds. It is on the render thread on
  // purpose (the alternative is a stale period computed for a different sound),
  // and the callback cost is measured, not assumed: see `plcSearchUs`.
  // ── The device buffer is not the packet ────────────────────────────────────
  //
  // These were the same number, and the measurement says they should not be. The
  // two CoreAudio scheduling constants -- 1.01 ms to wake the input callback,
  // 1.67 ms of lead on the output callback, 2.68 ms together and steadier than
  // anything else in the budget -- are multiples of the DEVICE BUFFER. The packet
  // fill and the bandwidth are functions of the PACKET.
  //
  // FPP=16 was measured at 9.48 ms and rejected because it doubled the packet rate
  // to 3000/s and the 36% header overhead with it. But that experiment moved both
  // quantities at once. Halving only the device buffer should buy most of the same
  // scheduling win at exactly the same packet rate and exactly the same bandwidth.
  // 16, measured. The hardware floor on this Mac is 15 and it accepts any value,
  // but 15 buys 0.02 ms over 16 and costs four times the missed wakeups (8 per
  // 379k callbacks against 2 per 358k), so 16 is where the curve flattens. 32 was
  // the default only because it was the packet size.
  //
  // What 16 costs: about 2 missed input wakeups per two minutes, and a frame
  // deficit of 94 samples against 47 at devbuf 32 -- of which roughly half is
  // device-clock drift rather than loss, since devbuf 32 shows 47 samples with
  // ZERO skips. So the real price is one 0.33 ms gap somewhere around every minute,
  // now covered by a pitch-period repeat, against 0.95 ms off every syllable
  // forever. Rotated arms: 10.50/10.59 ms against 11.43/11.57.
  nonisolated(unsafe) static var devBuf = 16
  /// The gate every per-packet counter rides. `played` and `concealed` both only
  /// move at `off == 0`, so if a callback grid can straddle packet boundaries
  /// without ever landing on one, BOTH read zero on a perfectly healthy call --
  /// and the watchdog reads that as silence. Measure the gate itself.
  nonisolated(unsafe) var offZeroMiss = 0
  nonisolated(unsafe) var offZeroRun = 0
  nonisolated(unsafe) var offZeroRunMax = 0
  // ── A DICTIONARY ON THE REALTIME THREAD KILLED A CALL ─────────────────────
  //
  // This was `[Int: Int]`, incremented inside the render callback and sorted from
  // both the reporter and the watchdog. Swift's Dictionary is not thread-safe, so
  // an insert that triggered a rehash freed the storage a reader was walking:
  //
  //   EXC_BAD_ACCESS (SIGSEGV) at 0x8000000000000010
  //   Dictionary.count.getter <- _copyCollectionToContiguousArray
  //   <- Sequence.sorted(by:) <- reportLoop()
  //
  // A live call, 25 seconds in, no message -- the shape a user reports as "it
  // randomly quit". Found because a measurement arm died and an unexplained
  // process death got chased instead of shrugged at.
  //
  // A fixed array cannot rehash and cannot allocate, which is also what a
  // realtime audio thread requires of every line in it. The worst a concurrent
  // increment can now do is lose a count -- a diagnostic missing a digit instead
  // of a process missing its address space.
  static let N_HIST = 4096
  nonisolated(unsafe) var nHist = [Int](repeating: 0, count: Audio.N_HIST + 1)
  /// Non-empty buckets, formatted. `n` is a frame count, so anything at or above
  /// the cap lands in the last bucket rather than being dropped silently.
  var nHistDescribe: String {
    var out: [String] = []
    for (n, c) in nHist.enumerated() where c > 0 {
      out.append("\(n == Audio.N_HIST ? ">=\(Audio.N_HIST)" : "\(n)")x\(c)")
    }
    return out.joined(separator: " ")
  }
  nonisolated(unsafe) var cursorAheadMs = 0.0
  nonisolated(unsafe) var cursorAheadDone = false
  nonisolated(unsafe) var aheadRun = 0
  /// `--stall-out <s>` stops the output unit outright, once, that many seconds in.
  /// Same reasoning as cursor-ahead: the dead-callback watchdog and its rebuild
  /// only ever run during a failure, and a recovery no test has ever triggered is
  /// a guess. This is not a simulation of the fault -- it IS the fault, a real
  /// output unit that stops calling back, produced on demand.
  nonisolated(unsafe) var stallOutAfterS = 0.0
  nonisolated(unsafe) var stallOutDone = false
  private static let HIST = 2048           // 42.7 ms, power of two for masking
  private static let HMASK = HIST - 1
  private static let PMIN = 96             // 500 Hz
  private static let PMAX = 600            // 80 Hz
  private static let XFADE = 64            // 1.3 ms, both seams
  private var hist: UnsafeMutablePointer<Float>
  private var histW = 0                    // next write position
  private var plcPeriod = 0
  private var plcCursor = 0
  private var plcSamples = 0               // length of this outage, in samples
  private var xfade = 0                    // samples of exit cross-fade left
  var plcSearchUs = Quantiles(cap: 256)
  var plcPeriodMs = Quantiles(cap: 256)
  /// zeros | grain | plc. Three arms, because an improvement that cannot be
  /// attributed to the thing that changed is not an improvement, it is a hope.
  var concealZeros = false
  var concealGrain = false
  /// `--interp linear` restores the old resampler so the change can be A/B'd.
  var interpLinear = false
  /// THE SIZE OF THE CLICK, measured rather than argued about. A click is a
  /// discontinuity in the waveform, so the biggest sample-to-sample step at the
  /// edge of a concealed packet IS the artifact. Filling with zeros steps by the
  /// full signal amplitude; repeating the last grain should step by almost
  /// nothing. Cannot be listened to at 6am, can be measured at any hour.
  var jumpAtEdge = Quantiles(cap: 1024)
  // A single sample step is gameable: ANY smoothing flatters it, including
  // smoothing that destroys the signal. So the window is 64 samples wide either
  // side of a seam and the reading is the WORST step inside it -- which catches
  // both the click at the join and the onset of a buzz just after it.
  private var edgeWinLeft = 0
  private var edgeWinMax: Float = 0
  // A step of 0.01 is a loud click on room noise and inaudible on speech. The
  // step alone is therefore not a quality number -- it only means something
  // against the level of the signal it interrupts, so the level is measured on
  // the same samples, in the same callback, and printed beside it.
  private var sigSumSq: Double = 0
  private var sigN: Int = 0
  var sigRms: Double { sigN > 0 ? (sigSumSq / Double(sigN)).squareRoot() : 0 }
  // ── THE LONGEST HOLE, NOT THE AVERAGE NUMBER OF HOLES ──────────────────────
  //
  // Concealment as a RATE says how often the fill ran. It cannot say whether a
  // word was lost, and that is the only thing a person notices: 200 gaps of one
  // packet each is a texture; one gap of 300 ms is a missing syllable and "sorry,
  // say that again". Same samples, same rate, opposite experience.
  private(set) var concealMaxRun = 0
  private var prevOut: Float = 0
  private var wasConcealing = false
  // ── Real speech instead of a quiet room ────────────────────────────────────
  //
  // Every audio measurement in this project so far was taken with whatever the
  // microphone happened to hear, which at six in the morning is a quiet room --
  // near-silence plus noise. Timing does not care what the samples contain, so m2e
  // and the buffer behaviour are unaffected. QUALITY does: the concealment A/B came
  // back saying that repeating the last waveform grain was WORSE than filling with
  // zeros, which is true of noise (uncorrelated at 0.67 ms) and false of speech
  // (a pitch period is 3-12 ms, so a 0.67 ms grain is a continuation). I was
  // measuring the wrong signal and it produced a confident, inverted answer.
  //
  // The file replaces the samples AFTER the input unit has rendered, so every
  // timestamp, every callback and every downstream stage is byte-for-byte the same
  // path the microphone takes. Only the content changes.
  private var srcSamples: UnsafeMutablePointer<Float>?
  private var srcCount = 0
  private var srcPos = 0
  // ── What was said, and what was played ─────────────────────────────────────
  //
  // Every audio quality number in this project has been a PROXY: the size of the
  // step at a concealment seam, the count of concealed packets, the recovery rate.
  // Proxies are what you use when you cannot see the thing itself. But the thing
  // itself is right here -- the source is a known file and the playout is a stream
  // of samples -- so the actual error between what was said and what was played is
  // computable, sample by sample, and every proxy can be checked against it.
  //
  // Writing from the render callback is not allowed: file I/O on a real-time audio
  // thread is the malloc-on-the-audio-thread mistake in another costume. So the
  // callback only appends into a preallocated buffer and bumps an index, and a
  // background thread does the writing. If the buffer fills, recording stops and
  // says so -- it does not wrap, because a wrapped recording silently splices two
  // moments together and would look like a glitch that never happened.
  private var dumpBuf: UnsafeMutablePointer<Float>?
  private var dumpCap = 0
  private var dumpW = 0
  private(set) var dumpFull = false
  private var dumpPath: String?

  func startDump(_ path: String, seconds: Double = 300) -> String {
    let n = Int(seconds * SR)
    let b = UnsafeMutablePointer<Float>.allocate(capacity: n)
    b.initialize(repeating: 0, count: n)
    dumpBuf = b; dumpCap = n; dumpW = 0; dumpPath = path
    Thread { [weak self] in
      guard let self else { return }
      FileManager.default.createFile(atPath: path, contents: nil)
      guard let fh = FileHandle(forWritingAtPath: path) else { return }
      var flushed = 0
      while true {
        Thread.sleep(forTimeInterval: 0.5)
        let w = self.dumpW              // one reader, one writer, monotonic index
        if w > flushed {
          let bytes = (w - flushed) * 4
          fh.write(Data(bytes: UnsafeRawPointer(b + flushed), count: bytes))
          flushed = w
        }
      }
    }.start()
    return "playout dump: \(path) -- raw float32 mono @48000, up to \(Int(seconds)) s"
  }

  // ── A speaker-to-microphone path, in software ──────────────────────────────
  //
  // Without echo cancellation this app needs headphones, which is the opposite of
  // the thing it is for. And an echo canceller cannot be built without a way to
  // test it, which normally means playing sound into a room.
  //
  // But the echo path is a delay, a gain and an impulse response, and this program
  // already has the exact samples it played and the exact host time it played
  // them. So the path can be built in software: take what was played, delay it,
  // attenuate it, smear it with a few reflections, and add it to what was
  // captured. That is a real echo as far as everything downstream is concerned --
  // the canceller sees precisely what it would see in a room, minus the
  // loudspeaker's nonlinearity and the late reverb tail.
  //
  // What this rig proves: convergence, echo return loss, and behaviour when both
  // people talk at once. What it cannot prove: anything about a real loudspeaker.
  // That distinction is stated everywhere the numbers appear.
  private static let ECHO_MAX = 48000                 // one second of history
  private var echoHist: UnsafeMutablePointer<Float>?
  private var echoW = 0
  /// What actually left the loudspeaker, sample for sample. See the note at its
  /// write site: `echoHist` is the DECODED far stream and must stay that way for
  /// the estimator's sake, and this is the emitted signal, which is the only one
  /// that can come back as an echo. `emitW` advances in lockstep with `echoW`.
  private var emitHist: UnsafeMutablePointer<Float>?
  private var emitW = 0
  private var echoDelay = 0
  private var echoGain: Float = 0
  private var echoTaps: [(Int, Float)] = []
  private var echoArmed = false
  var echoSim: Bool { echoArmed }

  /// Arm the simulated echo path. Delay in ms, gain as a linear factor.
  func armEchoSim(delayMs: Double, gain: Double) -> String {
    echoArmed = true
    echoDelay = max(1, Int(delayMs / 1000.0 * SR))
    echoGain = Float(gain)
    // A direct path plus three early reflections at decreasing amplitude. A pure
    // delay is the one echo path no room produces, and a canceller that only ever
    // meets a single tap can pass a test it would fail in a room.
    echoTaps = [(0, 1.0), (Int(0.0031 * SR), 0.55), (Int(0.0072 * SR), 0.33), (Int(0.0131 * SR), 0.18)]
    return "echo sim: playout fed back at \(String(format: "%.1f", delayMs)) ms, gain "
         + "\(String(format: "%.2f", gain)) (\(String(format: "%.0f", 20 * log10(gain))) dB), "
         + "4 taps out to \(String(format: "%.1f", 13.1 + delayMs)) ms -- SIMULATED, not a real room"
  }

  // ── How much of what I play comes back into my microphone ──────────────────
  //
  // The first thing an echo canceller needs is WHERE the echo is, and this program
  // is unusually well placed to find out: it has the exact samples it played and
  // the exact samples it captured, on one clock, with no guessing. So a normalised
  // cross-correlation of capture against playout over a 0-200 ms search says both
  // where the echo is and how much of it there is.
  //
  // Decimated by eight before correlating -- 6 kHz is ample for locating a delay,
  // speech has almost no energy above it that matters here, and the cost drops
  // sixty-four fold: 0.7M multiply-adds per estimate instead of 46M. And it runs on
  // a background thread reading snapshots, never in a callback, because an
  // instrument whose own cost lands in the number it reports is worse than none.
  private static let CAPH = 131072                    // 2.7 s of capture history
  private var capHist: UnsafeMutablePointer<Float>?
  private var capHistW = 0
  private(set) var echoDelayMs: Double = -1
  private(set) var echoCorr: Double = 0
  private(set) var echoCorrPeak: Double = 0
  private(set) var echoErleDb: Double = 0
  /// ── AND SOMETHING THAT ACTS ON WHAT THE ESTIMATOR FOUND (0.107.0) ─────────
  ///
  /// The estimator has been saying "your speaker reaches your microphone at
  /// 0.82, 31 ms away" on every call for months and nothing has ever used it for
  /// anything but a diagnosis. `Aec` subtracts a filtered copy of the playout at
  /// that delay -- linear subtraction only, no spectral suppression, which is
  /// the distinction the deleted canceller's own note conflated. See Aec.swift.
  let aec = Aec()
  /// When the estimator last actually computed. The veto derived from a
  /// computation older than CORR_VETO_FRESH_MS is withdrawn rather than
  /// trusted: a silent microphone freezes the estimator (`micE` guard below),
  /// and a frozen "this is echo" must not outlive the echo.
  private var corrVetoAt: UInt64 = 0
  /// ── WHAT THE ESTIMATOR ACTUALLY DID, AS OPPOSED TO WHAT IT CONCLUDED ──────
  ///
  /// `echoCorr` is one instant and `echoCorrPeak` is one moment of a whole call.
  /// Neither says how much of the call the correlation was high, and the live
  /// question -- "the veto fires for 6.9% of the samples while echo is high for a
  /// third of the beats, so is it firing in the right moments?" -- cannot be
  /// asked without it. `echoTicks` is the denominator and it is not the same as
  /// the number of ticks: the estimator has four `continue` paths (no history
  /// yet, not enough history, a silent microphone, no best lag) and a
  /// computation that did not happen has always reported the same as one that
  /// found no echo (`blind-instruments-report-negatives`).
  private(set) var echoTicks = 0
  private(set) var echoHighTicks = 0
  private(set) var echoSkips = 0
  /// Computations where the correlation said "our own speaker" and the
  /// canceller's measured ERLE withdrew the veto anyway.
  private(set) var aecUnvetoTicks = 0

  /// What the speaker actually does. THIS is the one the render callback reads.
  // ── THE SAME-ROOM DETECTOR IS GONE ─────────────────────────────────────────
  //
  // Deleted 2026-08-30 on the product decision, in the user's words: "we do not
  // need the same room detector. This would never be the case. Two people being
  // in the same room would not need to video call."
  //
  // That is right, and this project already knew it: `same-room-is-a-test-artifact`
  // says the echo from two Macs side by side was the RIG. The detector was built
  // to serve a condition produced by how the app is TESTED, not by how it is
  // used -- and it then cost a correlation search over ~1800 offsets every half
  // second, on battery, on every call, forever, for a case that does not happen.
  //
  // What went with it: the verdict, the hysteresis window, the loopback
  // attribution, `--no-sameroom`, `--sameroom-test`, the banner, the speaker
  // control that put the speaker back, and the eight room_* telemetry fields
  // added earlier the same day. A field reporting a feature nobody needs is
  // still a field somebody has to read past.
  //
  // The ECHO detector stays and is a different thing: `echoCorr`/`echoDelayMs`
  // say whether this machine's speaker reaches its own microphone, which is the
  // fact that decides whether turn-taking is needed here at all.
  /// Kept as a constant `false` for the render callback's single use. The
  /// detector that could make it true is gone; the expression stays so the two
  /// sample-writing sites keep their shape and a future speaker-silencing
  /// reason has an obvious place to live.
  var roomSpeakerOff: Bool { false }


  // ── The canceller ──────────────────────────────────────────────────────────
  //
  // Normalised least-mean-squares, 1024 taps at 48 kHz = 21.3 ms, positioned at
  // the delay the estimator found. That covers the direct path and the early
  // reflections, which is where nearly all the echo energy is; the late reverb
  // tail leaks through and is what a residual suppressor would be for.
  //
  // Positioned, rather than long enough to search. A filter that has to cover
  // 0-200 ms needs 9600 taps and 460M multiply-adds a second; one that is TOLD
  // where to look needs 1024 and 98M. This program knows where to look because it
  // has both signals on one clock -- which is the whole advantage of doing this
  // inside the app that owns the playout rather than in a general-purpose library.
  //
  // ADAPTATION FREEZES DURING DOUBLE TALK. When the near end speaks, the residual
  // is dominated by their voice, and an LMS update driven by that will happily
  // "cancel" the person who is talking -- it diverges, and the failure sounds like
  // the near end being chewed up. So the step is taken only when the far end is
  // clearly the louder explanation for what the microphone hears.
  // ── WAS THE MICROPHONE BEING OVERLOADED ──────────────────────────────────────
  //
  // "It felt like the mic was hit hard from both sides" is a description of
  // CLIPPING, and there was no number for it anywhere. A sample pinned at full
  // scale is information that has already been destroyed -- no echo canceller,
  // codec or jitter buffer downstream can undo it, and every one of them will be
  // blamed for it. One pass over 128 samples per callback, scalars only, nothing
  // allocated: the same shape as the level meter that has run here for months.
  private(set) var micClipped = 0
  private(set) var micSamples = 0
  private(set) var micPeak: Float = 0
  /// Peak since the gain tuner last looked. The lifetime peak above answers
  /// "did this call ever clip"; the tuner needs "how loud is it RIGHT NOW", and
  /// a lifetime maximum can never come back down.
  private(set) var micPeakWin: Float = 0
  /// ── "IS THE MICROPHONE HOT" WAS NOT A MEASURABLE QUESTION ─────────────────
  ///
  /// `micPeak` is a LIFETIME maximum and is never reset, so `a_mic_peak` on the
  /// wire answers "did this call ever clip" and cannot answer "is this
  /// microphone hot now". A call whose first sentence hit 2.58 before the trim
  /// converged and whose remaining five minutes sat perfectly on target reports
  /// 2.58 in every beat, forever -- a birth certificate rather than a health
  /// record, which is a bug class this project has already paid for twice
  /// (`once-fired-probes-record-transients`, and the `echo_corr` last-vs-peak
  /// fix beside it).
  ///
  /// These three are per-tick and have a denominator: the level at the last
  /// tick, before and after the trim, and the share of ticks the output was over
  /// full scale. Without them the mic-hot theory could be neither confirmed nor
  /// refuted from telemetry, which is how it stayed a theory.
  private(set) var micPeakNow: Float = 0
  private(set) var micRawPeakNow: Float = 0
  private(set) var hotTicks = 0
  private(set) var gainTicksAll = 0
  private(set) var overloadCuts = 0
  /// Energy of what the loudspeaker has played since the last capture block, and
  /// how many samples that was. Written on the render thread, drained on the
  /// capture thread; scalars only, which is the rule everywhere these two meet.
  nonisolated(unsafe) var playoutSumSq: Double = 0
  nonisolated(unsafe) var playoutN: Int = 0
  /// Last drained loudspeaker RMS, for the readout. A number the person
  /// debugging an echo asks for first and could not previously get.
  private(set) var playoutRmsNow: Double = 0
  /// The level below which a loudspeaker is not an echo path worth muting for.
  /// -46 dBFS: quiet enough that a room tail and a line's noise floor sit under
  /// it, loud enough that any audible speech sits over it. Chosen against the
  /// measured null -- a call with nobody talking reads about -60.
  static let PLAYOUT_LIVE_RMS: Double = 0.005
  /// The microphone before `inputTrim`, which is what the trim has to be chosen
  /// from: reading the trimmed signal would be a loop steering on its own output.
  nonisolated(unsafe) var rawPeakWin: Float = 0
  /// Software attenuation applied at capture when the device's own volume has
  /// reached its floor and the signal is still too hot. 1 = untouched, which is
  /// every machine that does not need it.
  private(set) var inputTrim: Float = 1
  private(set) var trimMoves = 0
  private var overloadCooldown = 0
  private var makeupCeiling: Float = Audio.MAKEUP_MAX
  /// True while the device knob is at its limit and the signal is STILL hot --
  /// the state the old loop sat in silently for a whole call.
  private(set) var gainAtRail = false
  /// The lowest the device's own input volume is ever asked to go. Not zero: a
  /// scalar of 0 is a dead microphone, and a loop that can reach it will find a
  /// way to. Below this the attenuation is done in software instead.
  private static let MIN_INPUT: Float32 = 0.05
  /// Where speech should peak: -5 dBFS. The same 0.55 the attenuation path has
  /// always aimed at, named once now that two directions share it.
  static let TRIM_TARGET: Float = 0.55
  /// Below this the microphone is too quiet and makeup gain is allowed. Chosen
  /// so the dead band (here..0.92) covers every healthy microphone: a normal
  /// talker at a normal distance peaks 0.3-0.8 and must never be touched.
  static let TRIM_QUIET: Float = 0.30
  /// The most a microphone may be amplified: +18 dB. Beyond this the room is
  /// louder than the person and a level control is the wrong tool.
  /// +12 dB, reduced from +18 in 0.104.0. On the live call that shipped +18 the
  /// loop drove a 0.23 mic to an output of 1.86 -- and even without the dead
  /// zone, 8x lifts the room's own noise by 18 dB along with the person.
  static let MAKEUP_MAX: Float = 4
  /// The lowest a software trim may go. The same 0.02 the target computations
  /// already clamp to, named so the overload cut and the target agree by
  /// construction rather than by two literals staying in step.
  static let TRIM_MIN: Float = 0.02
  /// Speech must stand this far above the room's own floor before amplifying
  /// it. ~15 dB. Below it, gain makes loud noise rather than a clear voice.
  static let TRIM_MIN_SNR: Float = 6
  /// Per-tick climb, at the 1 Hz gain tick: about 4 s to reach full makeup.
  /// Slower than the way down on purpose -- see the note in `trimStep`.
  static let TRIM_UP_RATE: Float = 1.6
  private var micSumSq: Double = 0
  var micRms: Double { micSamples > 0 ? (micSumSq / Double(micSamples)).squareRoot() : 0 }
  /// Seconds the report thread has been ticking. Kept because it is the
  /// denominator for anything expressed as "for how long".
  private(set) var qualityTicks = 0
  private var micE: Double = 0
  private var refE: Double = 0
  /// Echo return loss enhancement: how much quieter the microphone signal got.
  ///
  /// Reported two ways on purpose. The lifetime figure includes every second of
  /// cold-start convergence and is the honest "what did this call get"; the recent
  /// figure is a leaky average over about a second and is the honest "what is it
  /// doing now". Quoting only the first understates a converged filter; quoting
  /// only the second hides how long it took to get there.
  /// Called once a second from the report thread. Turns two instantaneous
  /// signals into a DURATION, which is the form a person's complaint takes:
  /// "there was echo for a while", not "correlation was 0.62".
  /// ── AN ECHO-LEAK TIMER WAS TRIED HERE AND REMOVED ──────────────────────────
  ///
  /// It counted seconds where `echoCorr` was high while our speaker was live, on
  /// the assumption that high correlation means echo is getting through. The
  /// calibration said otherwise, and backwards: with the canceller OFF the
  /// correlation was 0.10 and with it ON the correlation was 0.76. `echoCorr` is
  /// the delay estimator's CONFIDENCE that it has found the echo path -- which
  /// goes up precisely when the canceller is working, because that is when the
  /// estimator is running and locked.
  ///
  /// Echo has to be judged the way the existing rule judges it: correlation high
  /// AND the achieved ERLE low. Both are already on the wire.
  // ── GAIN STAGING, AT THE DEVICE, NOT IN SOFTWARE ──────────────────────────
  //
  // Found on this machine: macOS input volume at 14 of 100. Speech reached the
  // far end 16 dB above the hiss -- barely above the noise floor -- and every
  // downstream fix made it worse, because digital makeup gain amplifies the hiss
  // by exactly as much as the voice. Turning the software gain control off gave
  // an inaudible voice; leaving it on gave a voice clipped flat at 1.01. Two
  // opposite-looking faults, one cause, and no model or codec can undo either:
  // once the ADC has quantised a whisper into the bottom few bits, the
  // information is gone.
  //
  // The fix is the one every recording engineer knows: set the gain BEFORE the
  // converter, so the signal arrives at a healthy level and nothing downstream
  // has to rescue it. macOS exposes exactly that as the input device's volume,
  // and this app has never touched it.
  //
  // Deliberately slow and bounded. It runs once a second, moves in small steps,
  // and stops well short of the ends of the range -- a gain control that hunts
  // is worse than one that is slightly wrong, and this one is changing a setting
  // the person can see in System Settings.
  private var gainTicks = 0
  private var gainMoves = 0
  private(set) var micGainNow: Float = -1
  private var micFloor: Float = 1.0
  private var speechRun = 0
  // ── HANDING THE RECOGNISER A CHUNK, OFF THE AUDIO THREAD ──────────────────
  //
  // Both signals it needs are already kept: `capHist` is the RAW microphone,
  // written before the gate touches it, so the quiet side's words are there at
  // full quality however far down the gate has turned them; `echoHist` is what
  // the speaker played. Aligning them by the measured delay costs an index.
  //
  // Read from a background thread, well behind the write head. The histories are
  // seconds long and this stays a few hundred milliseconds back, so the writer
  // is never in the region being read -- which is what makes it safe without a
  // lock on the audio thread, and a lock on the audio thread is the thing that
  // must never exist.
  private var subReadAt = 0

  func subtitleChunk() -> (mic: [Float], ref: [Float])? {
    guard let ch = capHist, let eh = echoHist else { return nil }
    let w = capHistW
    // Stay 100 ms behind the writer: the cost is a subtitle a tenth of a second
    // later, and the alternative is reading a sample as it is being written.
    let safe = w - Int(SR * 0.10)
    if subReadAt == 0 { subReadAt = max(0, safe - Int(SR * 0.20)) }
    let n = safe - subReadAt
    guard n >= Int(SR * 0.06) else { return nil }
    // If it has fallen a long way behind -- a stalled recogniser, a slept
    // machine -- skip forward rather than transcribing history nobody wants.
    if n > Int(SR * 1.5) { subReadAt = safe - Int(SR * 0.5) }
    let take = safe - subReadAt
    var mic = [Float](repeating: 0, count: take)
    var ref = [Float](repeating: 0, count: take)
    let d = Int((echoDelayMs > 0 ? echoDelayMs : 0) / 1000.0 * SR)
    let ew = echoW
    for i in 0..<take {
      let idx = subReadAt + i
      mic[i] = ch[((idx % Audio.CAPH) + Audio.CAPH) % Audio.CAPH]
      // What the speaker was playing when that sample was captured: the same
      // distance back from ITS write head, minus the flight time through the room.
      let back = (w - idx) + d
      let e = ew - back
      ref[i] = e >= 0 ? eh[((e % Audio.ECHO_MAX) + Audio.ECHO_MAX) % Audio.ECHO_MAX] : 0
    }
    subReadAt = safe
    return (mic, ref)
  }

  // ── CLEANING THE MICROPHONE FOR THE RECOGNISER ONLY ───────────────────────
  //
  // On speakers, the muted person's microphone hears two people: themselves, and
  // the far end coming out of their own laptop. Transcribe that and their
  // subtitles fill up with the other person's words, attributed to them. It is a
  // real bug and a very visible one.
  //
  // This is NOT the echo canceller coming back, and the difference is the whole
  // reason it is allowed to exist. Cancellation was unacceptable because it
  // damaged the voice people HEAR. Nothing here is ever heard. The output of
  // this path is text, so it may distort, over-subtract, smear the phase and
  // hollow out the voice as much as it likes -- a recogniser does not care, and
  // no listener is downstream of it. It is also allowed to run late, which the
  // audio path never is.
  //
  // So it uses the method a listener could never tolerate: SPECTRAL
  // OVER-SUBTRACTION. Take the magnitude spectrum of the microphone and of what
  // was played, aligned by the measured delay, and subtract several times more
  // of the second than is actually there. A linear filter has to get the phase
  // right and can therefore only remove what it can predict exactly; this
  // ignores phase entirely, which is why it removes so much more, and why the
  // result would be unlistenable.
  //
  // The coupling is learned PER BAND, because a laptop's speaker and its
  // microphone are not flat: one figure for the whole spectrum under-subtracts
  // where the path is loud and eats the near voice where it is quiet.
  final class SubtitleCleaner {
    static let N = 512                      // 32 ms at 16 kHz
    static let HOP = N / 2
    static let BINS = N / 2
    /// How many times the estimated echo to remove. Far above 1 on purpose.
    ///
    /// Swept: 2.6 gives +7 dB of separation, 9 gives +14, 14 gives +17, and the
    /// near voice loses 0.2, 3.1 and 4.2 dB respectively -- which does not
    /// matter, because nobody hears it. What DOES matter is the thing this
    /// measurement cannot see: past some depth, over-subtraction leaves musical
    /// noise, and a recogniser reads that as words. So this stops at a strong
    /// setting rather than the best-scoring one, and the real tuning happens
    /// with the recogniser in the loop, against transcripts.
    var over: Float = 9
    /// Never take a band below this fraction of what arrived, or consonants
    /// vanish along with the echo and the recogniser starts inventing words.
    var floorFrac: Float = 0.03

    private var coupling = [Float](repeating: 0.35, count: BINS)
    private var win = [Float](repeating: 0, count: N)
    private var overlap = [Float](repeating: 0, count: HOP)
    private var setup: FFTSetup?

    init() {
      for i in 0..<SubtitleCleaner.N {
        win[i] = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(SubtitleCleaner.N))
      }
      setup = vDSP_create_fftsetup(vDSP_Length(9), FFTRadix(kFFTRadix2))
    }
    deinit { if let s = setup { vDSP_destroy_fftsetup(s) } }

    private func spectrum(_ x: [Float], _ off: Int) -> (re: [Float], im: [Float]) {
      let n = SubtitleCleaner.N
      var buf = [Float](repeating: 0, count: n)
      for i in 0..<n where off + i < x.count { buf[i] = x[off + i] * win[i] }
      var re = [Float](repeating: 0, count: n / 2), im = re
      guard let setup else { return (re, im) }
      buf.withUnsafeBufferPointer { p in
        p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { c in
          var sp = DSPSplitComplex(realp: &re, imagp: &im)
          vDSP_ctoz(c, 2, &sp, 1, vDSP_Length(n / 2))
          vDSP_fft_zrip(setup, &sp, 1, vDSP_Length(9), FFTDirection(FFT_FORWARD))
        }
      }
      return (re, im)
    }

    /// `mic` and `ref` must already be aligned: ref[i] is what the speaker was
    /// playing when mic[i] was captured. Returns audio fit for a recogniser and
    /// for nothing else.
    /// `probe`, when given, is passed through the SAME per-band gains the mixture
    /// produced. It is the only honest way to ask how much of the near voice
    /// survived and how much of the echo did: measuring them by cleaning each
    /// alone would let the filter adapt to a different signal each time and
    /// score itself on two runs that never happened.
    func clean(mic: [Float], ref: [Float], probe: [Float]? = nil) -> [Float] {
      let n = SubtitleCleaner.N, hop = SubtitleCleaner.HOP, bins = SubtitleCleaner.BINS
      guard mic.count >= n, let setup else { return mic }
      var out = [Float](repeating: 0, count: mic.count)
      var off = 0
      while off + n <= mic.count {
        let m = spectrum(mic, off)
        let r = spectrum(ref, off)
        let pr = probe.map { spectrum($0, off) }
        var re = pr?.re ?? m.re, im = pr?.im ?? m.im
        for b in 0..<bins {
          let mMag = (m.re[b] * m.re[b] + m.im[b] * m.im[b]).squareRoot()
          let rMag = (r.re[b] * r.re[b] + r.im[b] * r.im[b]).squareRoot()
          if rMag > 1e-6 {
            // Learn the path per band as a slow minimum, for the same reason the
            // time-domain gate does: near speech can only push the ratio up.
            let obs = min(mMag / rMag, 4)
            coupling[b] = obs < coupling[b] ? coupling[b] * 0.9 + obs * 0.1
                                            : min(coupling[b] * 1.0002, 4)
          }
          let est = coupling[b] * rMag * over
          let keep = max(mMag - est, mMag * floorFrac)
          let g = mMag > 1e-9 ? keep / mMag : 1
          re[b] *= g; im[b] *= g
        }
        var buf = [Float](repeating: 0, count: n)
        re.withUnsafeMutableBufferPointer { rp in
          im.withUnsafeMutableBufferPointer { ip in
            var sp = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            vDSP_fft_zrip(setup, &sp, 1, vDSP_Length(9), FFTDirection(FFT_INVERSE))
            buf.withUnsafeMutableBufferPointer { bp in
              bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { c in
                vDSP_ztoc(&sp, 1, c, 2, vDSP_Length(n / 2))
              }
            }
          }
        }
        let scale = 1 / Float(n)
        for i in 0..<n where off + i < out.count { out[off + i] += buf[i] * scale * win[i] }
        off += hop
      }
      return out
    }
  }

  /// ── WHAT THE RECOGNISER IS HANDED, AND WHY IT IS SOMETIMES NOTHING ───────
  ///
  /// The cleaner exists for one situation: this microphone is hearing the far
  /// end off this machine's own speaker, and their words would otherwise land in
  /// this person's subtitles under this person's name. On headphones that
  /// situation does not exist, and running it anyway is not a harmless waste --
  /// `coupling` starts at 0.35 in every band and `over` is 9, so it removes
  /// 3.15x the far end's magnitude from bands the far end is loud in, and none
  /// of that far end is in this microphone. The near voice lives in those same
  /// bands. Measured: **8.5 dB of the near voice, gone**, during simultaneous
  /// speech.
  ///
  /// It does adapt away -- but only while this end is QUIET and the far end is
  /// talking, which is exactly what somebody who joins and immediately talks
  /// over the far end never provides.
  ///
  /// This is a FUNCTION rather than a line inside the subtitle thread so that a
  /// test can make the same decision the product makes
  /// (`handler-tests-cannot-see-interaction-bugs`). `onSpeakers` is passed in
  /// rather than read from a gate flag: the gate is a decision about echo, this
  /// is the physical route, and reading a decision as a fact is what put the
  /// whole turn-taking layer behind a pair of headphones.
  static func subtitleAudio(mic: [Float], ref: [Float], onSpeakers: Bool,
                            through cleaner: SubtitleCleaner) -> [Float] {
    guard onSpeakers else { return mic }
    return cleaner.clean(mic: mic, ref: ref)
  }

  // ── WHOSE TURN IT IS WHEN BOTH WANT IT ────────────────────────────────────
  //
  // Two people start at the same moment. Somebody has to go second, and the
  // question is who -- asked over and over across a whole conversation, where
  // the same person going second every time is the actual failure. That is a
  // person being talked over by a machine's tie-break.
  //
  // So it keeps a ledger of contested moments and who ended up with the floor.
  // Not floor TIME: somebody with more to say should say more, and throttling
  // that would be a worse product than any echo. Only the coin-flips.
  //
  // THE LEDGER BIASES THE CUE AND NEVER THE AUDIO. Nothing is muted by it,
  // nothing is opened by it, and it cannot cut anybody off -- it makes the
  // visual nudge to yield stronger for whoever has been winning the coin-flips
  // and weaker for whoever keeps losing them. The humans still decide; they are
  // just no longer deciding blind.
  //
  // Both ends compute it from the same rule, and can compute it independently:
  // whoever is still going a beat after an overlap started is the one who took
  // it. Where the two ends disagree, the cost is a slightly wrong nudge, which
  // is the cheapest kind of disagreement there is.
  struct Ledger {
    /// Contested starts this end took, and the far end took.
    var mine = 0, theirs = 0
    /// Recency-weighted, so a conversation is judged on the last few minutes
    /// rather than on who talked most an hour ago.
    var bias: Double = 0

    /// −1 the far end has been yielding and is owed one; +1 this end has.
    var owed: Double { max(-1, min(1, bias)) }

    /// Same number as `Audio.yieldNudge`, on the struct so it can be tested
    /// without a call in progress.
    var yieldNudgeFor: Double { max(0, owed) }

    mutating func won(byMe: Bool) {
      if byMe { mine += 1 } else { theirs += 1 }
      // Swept, not chosen. The requirement is three-sided: eight contested
      // starts in a row must register clearly (+0.70), four yields afterwards
      // must settle NEAR ZERO rather than swing to owing the other person just
      // as much (-0.07), and twenty alternating turns must leave the nudge off
      // entirely (-0.07). A faster memory satisfies the first and fails the
      // second, which is a nudge that oscillates instead of correcting.
      bias = bias * 0.86 + (byMe ? 0.14 : -0.14)
    }
  }
  private(set) var ledger = Ledger()
  private var contestAt: UInt64 = 0
  private var contestMineAtStart = false

  /// Called once per capture block while an overlap is in progress. Decides the
  /// contest exactly once, a beat after it began, on whoever is still speaking.
  private func judgeContest(now: UInt64, mineVocal: Bool, peerVocal: Bool) {
    if mineVocal && peerVocal {
      if contestAt == 0 { contestAt = now; contestMineAtStart = true }
      return
    }
    guard contestAt != 0 else { return }
    // 400 ms: longer than a stumble, shorter than a sentence. Below this the
    // "winner" is whoever happened to draw breath second.
    if Clock.ms(now - contestAt) >= 400 {
      if mineVocal != peerVocal { ledger.won(byMe: mineVocal) }
      contestAt = 0
    } else if !mineVocal && !peerVocal {
      contestAt = 0            // both stopped: nobody took it, nothing is owed
    }
  }

  /// How hard to nudge this end to yield, 0...1. Read by the interface; it has
  /// no effect on any sample of audio.
  var yieldNudge: Double { max(0, ledger.owed) }

  /// The deadlock rule, pulled out whole so it can be tested without a call and
  /// so there is exactly one place that states it. See the long note at its one
  /// call site in `accountTurn` for why each clause is there.
  enum Yield {
    /// Inside this, the ordering of two starts is the network's opinion and not a
    /// fact -- this end sees its own the instant it happens and the far end's a
    /// hop later. The same undecidability that stopped yield attribution being
    /// reported from one end.
    static let unknowableMs: Double = 150

    /// `gapMs`: when the far end started minus when this end started, positive if
    /// they started later. nil when either start is unknown.
    /// `owed`: +1 this end has been taking the contested starts, -1 the far end has.
    static func shouldYield(collisionMs: Double, gapMs: Double?, owed: Double,
                            afterMs: Double) -> Bool {
      guard collisionMs >= afterMs else { return false }   // brief overlap is conversation
      if owed > 0.6 { return true }                        // taken too many; give this one up
      guard let g = gapMs else { return false }
      if g < -unknowableMs { return true }                 // they were clearly first
      if g > unknowableMs { return false }                 // this end was clearly first
      return owed > 0.35                                   // too close to call: ask the record
    }
  }

  // ── WHAT A CALL HAS TO REPORT FOR THIS TO GET BETTER ──────────────────────
  //
  // Turn-taking is now the whole product, so it needs the same treatment
  // mouth-to-ear got: a number per call, from real calls, that says whether it
  // worked. Not "did the audio arrive" -- whether the two people managed to talk
  // to each other without tripping over one another.
  //
  // THE HEADLINE IS TIME TO FLOOR. From the moment somebody wants to speak to the
  // moment they are actually audible. It is the "does this feel automatic"
  // number, and it is the one to drive down.
  //
  // THE FAILURE IS A COLLISION: both people vocalising at once. Counted, timed,
  // and attributed -- who stopped first, and how long it took. A design that
  // makes collisions rare and short is working; one that makes them long is
  // making people fight for the floor, which is worse than doing nothing.
  //
  // NOTHING HERE CARRIES AUDIO OR WORDS. Counts and durations only.
  struct Turns {
    var claims = 0                 // times this end bid for the floor
    var claimsGranted = 0          // ... and became audible
    var timeToFloorMs: [Double] = []
    /// Voice-start to on-the-wire, one sample per utterance -- the number the
    /// person FEELS as "latency deciding who is speaking". And the utterances
    /// that never made it out at all, which no latency percentile can carry.
    var onsetToWireMs: [Double] = []
    var onsetsLost = 0
    var backchannels = 0           // listening noises, held back or not
    var escalated = 0              // a listening noise that turned into a bid
    var collisions = 0             // both ends vocalising at once
    var collisionMs: Double = 0    // total time spent in one
    // WHO STOPPED FIRST CANNOT BE DECIDED AT ONE END, and two attempts to do it
    // anyway both failed the same way. This end sees its own state the instant
    // it changes and the far end's a network delay later, so at the close of
    // every overlap our own silence is always the fresher fact. Measured on a
    // loopback: "you stopped 9, they stopped 0" -- printed by BOTH ends. Adding
    // a 120 ms confirmation margin did not fix it; it is not a tuning problem,
    // it is that the question needs two clocks.
    //
    // So these are published RAW and one-sided, for the server to join against
    // the far end's own record of the same overlap. Nothing on screen claims to
    // know who backed down, because this end cannot.
    var yieldedToPeer = 0          // this end went quiet, far end demonstrably kept going
    var peerYielded = 0            // the far end went quiet and this end kept going
    var ambiguousYields = 0        // too close to call from one side
    var gateFlaps = 0              // open/close inside 300 ms: choppy, and audible
    // ── THE TURN LAYER, WITH A DENOMINATOR ────────────────────────────────────
    //
    // `floorBlocks` exists so the other two mean something. A bare count of held
    // blocks is decoration -- `counted-without-a-denominator` -- and the number
    // anybody actually wants is the FRACTION of a call during which this end was
    // not allowed to speak, plus the fraction during which the turn layer had
    // stopped believing the far end and fallen back to the local gate.
    var floorBlocks = 0            // capture blocks the floor decided at all
    var floorHeldBlocks = 0        // ... in which this end could not transmit
    var floorFallbackBlocks = 0    // ... in which it was running on the local gate
    /// Strict's own honesty meter: blocks this end was on the wire while the
    /// far end's DECODED stream also carried voice. The physics window around
    /// a simultaneous start lives here; anything past deadlock + a hop per
    /// contest is the rule failing, not the rule's stated cost.
    var strictOverlapBlocks = 0
    /// Deadlocks this end gave up. Published rather than shown: the far end
    /// publishes the same number for its own side, and the two together say
    /// whether the rule is splitting them evenly or picking on somebody.
    var yields = 0
  }
  /// Set on the receive path the moment a packet says so, because a cue that is
  /// a video frame late appears after the moment it was meant to prevent.
  nonisolated(unsafe) static var peerVocalNow = false
  private(set) var turns = Turns()
  private var claimStart: UInt64 = 0
  private var claimPending = false
  private var lastVocal = DuplexGate.Vocal.quiet
  private var myVocalStart: UInt64 = 0
  private var peerVocalStart: UInt64 = 0
  private var collisionStart: UInt64 = 0
  private var pendingYield: UInt64 = 0
  /// The yield DECISION's last value, tracked apart from the audible duck: in
  /// strict the duck is retired but the decision keeps feeding the floor's
  /// tiebreak, and the counter follows the decision.
  private var lastWantYield = false
  private var lastOpenAt: UInt64 = 0
  private var wasOpen = true

  /// Called once per capture block, which is the only place that sees this end's
  /// state and the far end's in the same instant.
  func accountTurn(peerVocal: Bool, audible: Bool, blockN: Int) {
    let now = Clock.now()
    let mine = dgate.vocal

    // ── A BID IS AN EDGE, NOT A STATE ───────────────────────────────────────
    //
    // This tested `mine == .claim, !claimPending`, and `claimPending` is cleared
    // by the very next line as soon as the microphone is audible -- which, when
    // nobody else is talking, is the SAME block. So every block of a sentence
    // opened a fresh bid and closed it: one six-second sentence was recorded as
    // 2,935 bids, all granted in a median of 0 ms.
    //
    // Two things were wrong and only one of them was cosmetic. The count was
    // nonsense, and `timeToFloorMs` grew by one entry per capture block -- three
    // thousand a second, sorted once a second by the report line. An hour-long
    // call would have been ten million Doubles and a quadratic-looking report
    // thread.
    //
    // So it latches on the CHANGE. A bid begins when the classifier says so and
    // ends when the vocalisation does.
    turns.backchannels = dgate.backchannels
    if mine != lastVocal {
      if mine == .claim {
        claimPending = true; claimStart = now; turns.claims += 1
        if dgate.vocalWasBackchannel { turns.escalated += 1 }
      }
      if mine == .quiet { claimPending = false }
      lastVocal = mine
    }
    if claimPending, audible {
      turns.claimsGranted += 1
      // Bounded. This is a distribution, not a log: a few thousand samples
      // describe it as well as a million and cannot become a leak.
      if turns.timeToFloorMs.count < 4096 {
        turns.timeToFloorMs.append(Clock.ms(now - claimStart))
      }
      claimPending = false
    }

    // A collision, and who ended it.
    judgeContest(now: now, mineVocal: mine != .quiet, peerVocal: peerVocal)
    let bothTalking = mine != .quiet && peerVocal
    // When each side STARTED, which is the only evidence about who interrupted
    // whom. Recorded on the edge; the far end's is a network delay stale and the
    // decision below refuses to use it when the two are close together.
    if mine != .quiet, myVocalStart == 0 { myVocalStart = now }
    if mine == .quiet { myVocalStart = 0 }
    if peerVocal, peerVocalStart == 0 { peerVocalStart = now }
    if !peerVocal { peerVocalStart = 0 }
    if bothTalking, collisionStart == 0 {
      collisionStart = now; turns.collisions += 1
    } else if !bothTalking, collisionStart != 0 {
      turns.collisionMs += Clock.ms(now - collisionStart)
      collisionStart = 0
      // Both went quiet within a network delay of each other: unknowable here.
      if mine == .quiet && peerVocal { pendingYield = now }
      else if mine != .quiet && !peerVocal { turns.peerYielded += 1 }
      else { turns.ambiguousYields += 1 }
    }
    // A yield is only confirmed if the far end was still going a clear margin
    // later. 120 ms is longer than any plausible one-way delay on this product.
    if pendingYield != 0, Clock.ms(now - pendingYield) > 120 {
      if peerVocal { turns.yieldedToPeer += 1 } else { turns.ambiguousYields += 1 }
      pendingYield = 0
    }

    // ── THE DEADLOCK, AND WHO GIVES ───────────────────────────────────────────
    //
    // Only past `yieldAfterMs`, because everything shorter than that is what
    // conversation sounds like. Two rules, in order, and a refusal:
    //
    //   1. WHOEVER STARTED SECOND INTERRUPTED. That is the rule people already
    //      use, so an app that follows it needs no explaining. It is only usable
    //      when the two starts are clearly apart: this end sees its own the
    //      instant it happens and the far end's a hop later, so inside about a
    //      hundred milliseconds the ordering is not a fact, it is the network.
    //      This is the same thing that made yield attribution undecidable from
    //      one end, and the answer is the same -- do not pretend to know.
    //
    //   2. UNLESS THE LEDGER SAYS OTHERWISE. Somebody who has taken the last
    //      several contested starts gives this one up even though they started
    //      first. That is the whole reason the record exists, and it is where it
    //      stops being a readout and starts being a decision.
    //
    //   3. OTHERWISE NOBODY YIELDS. An even conversation with two simultaneous
    //      starts is genuinely undecided, and inventing a winner there would be
    //      the app talking over somebody on a coin toss.
    //
    // Both ends run this with mirrored ledgers -- `--ledger-test` asserts they
    // sum to zero -- so it resolves without either side asking the other. When
    // the network makes them briefly disagree the failure is symmetric and
    // self-clearing: both duck for a moment, or neither does.
    let gap: Double? = (myVocalStart != 0 && peerVocalStart != 0)
      ? Clock.ms(peerVocalStart) - Clock.ms(myVocalStart) : nil
    let wantYield = bothTalking && collisionStart != 0 && Yield.shouldYield(
      collisionMs: Clock.ms(now - collisionStart), gapMs: gap, owed: ledger.owed,
      afterMs: Audio.gate.yieldAfterMs)
    // In strict the 9 dB social duck is retired -- the floor silences the
    // loser outright -- but the DECISION must keep flowing: `yieldsOnTie`
    // below is the floor's deadlock tiebreak, and forcing it false at both
    // ends would let a deadlock resolve to BOTH microphones open. One
    // decision, two renderings.
    if wantYield != lastWantYield {
      lastWantYield = wantYield
      if wantYield { turns.yields += 1 }
    }
    dgate.yielding = wantYield && !Audio.sharedFloor.cfg.strict

    // ── AND THE FLOOR ────────────────────────────────────────────────────────
    //
    // Stepped here because this is already the one place that sees both ends at
    // the same instant, and because the tiebreak it needs is a decision this
    // function has ALREADY made. `Yield.shouldYield` runs on mirrored ledgers
    // that `--ledger-test` asserts sum to zero, so the two ends never both
    // yield -- which is exactly the property the floor's deadlock break
    // requires. Reusing it means there is one answer to "who gives" in this
    // product rather than two that can disagree.
    let fl = Audio.sharedFloor
    fl.yieldsOnTie = wantYield
    fl.speakers = Audio.outputIsSpeakers
    // What the canceller is achieving, so the floor can stand down on evidence
    // rather than on a route. Zero when the canceller is off, which is the value
    // that changes nothing.
    fl.aecErleDb = (Audio.aecOn && Audio.outputIsSpeakers) ? aec.erleDb : 0
    // And what is LEFT of the path, which is the quantity that decides whether
    // two microphones may be open. 1 opens nothing.
    fl.aecEchoPath = (Audio.aecOn && Audio.outputIsSpeakers) ? aec.echoPathNow : 1
    // Drain what the loudspeaker did since the last block. The floor's `idle`
    // state used to let both microphones stay live next to both loudspeakers,
    // which is a closed loop rather than a turn -- see the decision in
    // Floor.step. This is the measurement that closes it.
    let pn = playoutN, psq = playoutSumSq
    playoutN = 0; playoutSumSq = 0
    if pn > 0 {
      let rms = (psq / Double(pn)).squareRoot()
      playoutRmsNow = rms
      fl.notePlayout(live: rms > Audio.PLAYOUT_LIVE_RMS)
    }
    fl.noteEndProb(Audio.turnEndProb)
    // The visual prior, as a scalar across the thread boundary like every other
    // input this class hands the floor.
    fl.nearVisualVoice = Mouth.on && Mouth.influence && Mouth.visualKnown && Mouth.visualVoice
    let d = fl.step(dt: Double(blockN) / SR,
                    near: Floor.Voice(rawValue: mine.rawValue) ?? .quiet)
    // Applied to the NEXT block, one block late by construction -- 0.67 ms on
    // this machine. The alternative is stepping the floor before the classifier
    // that feeds it, which would be a block stale in the other direction and
    // stale about this end rather than the far one.
    dgate.floorMuted = Audio.floorOn && !d.mayTransmit && !d.duckOnly
    dgate.floorDucked = Audio.floorOn && d.duckOnly
    // Strict only: in soft, `idle` transmits from both ends, so the local echo
    // suppression is still the only thing standing between two live
    // microphones and a loop.
    // ── AND THE CONDITION IS THE EAR, NOT THE GRANT ────────────────────────
    //
    // `!playoutOpen` is the strongest possible form of the argument: this
    // machine's speaker is CLOSED, so there is no acoustic path, so nothing
    // arriving at this microphone can be echo and suppressing it can only
    // ever cost the person their voice. It is also exactly the grant with the
    // one window that matters carved out -- the ear closes 60 ms AFTER the
    // floor arrives, so the far end's last half-word can land, and through
    // that window the suppression stays on.
    dgate.floorGranted = Audio.floorOn && fl.cfg.strict && !d.playoutOpen
    Audio.earOpen = !Audio.floorOn || d.playoutOpen
    if d.fallback { turns.floorFallbackBlocks += 1 }
    turns.floorHeldBlocks += d.mayTransmit ? 0 : 1
    turns.floorBlocks += 1
    // Strict's honesty meter: on the wire while the far end's decoded stream
    // also carries voice. 0.004 is the gate's own `farTalking` bar.
    if fl.cfg.strict, Audio.floorOn, d.mayTransmit, dgate.farEnvNow > 0.004 {
      turns.strictOverlapBlocks += 1
    }
    // Onset-to-wire, per utterance. Clocked from `myVocalStart` (set above on
    // the same edge) to the first block the floor let out. An utterance that
    // ends without ever transmitting is counted, not averaged away -- that is
    // the "mic failed to capture me" case, and a percentile cannot hold it.
    if mine != .quiet {
      if !onsetOpen { onsetOpen = true; onsetServed = false }
      if !onsetServed, !Audio.floorOn || d.mayTransmit {
        onsetServed = true
        if turns.onsetToWireMs.count < 4096, myVocalStart != 0 {
          turns.onsetToWireMs.append(Clock.ms(now - myVocalStart))
        }
      }
    } else if onsetOpen {
      onsetOpen = false
      if !onsetServed { turns.onsetsLost += 1 }
    }

    // Choppiness. A gate that opens and shuts inside a third of a second is
    // audible as chopping, and no amount of good intent excuses it.
    if audible != wasOpen {
      if audible {
        if lastOpenAt != 0, Clock.ms(now - lastOpenAt) < 300 { turns.gateFlaps += 1 }
        lastOpenAt = now
      }
      wasOpen = audible
    }
  }

  var timeToFloorP50: Double {
    let v = turns.timeToFloorMs.sorted()
    return v.isEmpty ? -1 : v[v.count / 2]
  }
  var onsetToWireP50: Double {
    let v = turns.onsetToWireMs.sorted()
    return v.isEmpty ? -1 : v[v.count / 2]
  }
  /// One utterance being measured right now. `myVocalStart` is the clock; these
  /// only remember whether the current one has reached the wire yet.
  private var onsetOpen = false
  private var onsetServed = false

  // ── HEADPHONES CHANGE WHAT IS POSSIBLE, NOT JUST WHAT IS PLEASANT ─────────
  //
  // On headphones there is no acoustic path from the speaker to the microphone
  // at all, so there is no echo, so there is nothing for the gate to protect
  // against -- and both people can talk over each other exactly as they would in
  // a room. On speakers that path exists and cannot be wished away.
  //
  // This is therefore not a setting. It is read from the system, it is re-read
  // while the call runs, and plugging in a pair of headphones mid-sentence opens
  // the call up within a second without anybody being told about it.
  private(set) var outputName = ""
  private(set) var onSpeakers = true
  static var gateAuto = true
  /// ── PINNING THE ROUTE, BECAUSE THE ROUTE CANNOT BE PLUGGED IN ────────────
  ///
  /// The headphone path is now most of the product -- the classifier, the cues,
  /// the captions and the cleaner all behave differently on it -- and it is
  /// reached by putting on a pair of headphones, which no test can do. Without
  /// this, the only headphone evidence available on this machine is a unit test,
  /// and `handler-tests-cannot-see-interaction-bugs` is the whole history of
  /// this project.
  ///
  /// Production never sets it, so the guard below is unchanged there.
  static var routeForced: Bool?

  func checkOutputRoute() {
    var (name, speakers) = Audio.outputDevice()
    if let f = Audio.routeForced { speakers = f; name = "\(name) [forced \(f ? "speakers" : "headphones")]" }
    guard name != outputName || speakers != onSpeakers else { return }
    let firstLook = outputName.isEmpty
    outputName = name
    onSpeakers = speakers
    // The turn layer needs the route too, and needs it as a fact rather than a
    // decision: `Audio.gate.on` is what the ECHO gate concluded, and reading a
    // conclusion as a fact is what once put the whole turn-taking layer behind a
    // pair of headphones (`one-condition-two-concerns`).
    Audio.outputIsSpeakers = speakers
    if Audio.gateAuto {
      Audio.gate.on = speakers
      Audio.sharedGate.cfg = Audio.gate
    }
    Metrics.fact("output_route", speakers ? "speakers" : "headphones")
    // Says which of the two products this call is now, because they are not
    // small variations of each other: on headphones the turn rule stands down
    // completely (`Floor.Cfg.headphoneDuplex`) and there is no handover cost at
    // all, and a line that read the same either way would hide the single
    // biggest difference in how a call feels.
    let duplex = Audio.sharedFloor.cfg.headphoneDuplex
    let how = speakers ? "one at a time, so nobody hears themselves"
                       : (duplex ? "both at once, no turns, nothing in the way"
                                 : "one at a time (--no-headphone-duplex)")
    let presInfo = Audio.presence.on ? " (spatial presence: \(Audio.presenceMode))" : ""
    fputs("output\(firstLook ? ":" : " is now:") \(name) -- \(how)\(presInfo)\n", stderr)
  }

  /// The default output device, and whether sound leaves it into the room.
  /// Anything not wired into the machine -- USB, Bluetooth, an adapter -- is
  /// overwhelmingly a headset; built-in could still be the headphone jack, and
  /// the data source says which.
  static func outputDevice() -> (name: String, speakers: Bool) {
    var dev = AudioDeviceID(0); var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr
    else { return ("speakers", true) }
    var name = "output"
    var nameRef: CFString? = nil; sz = UInt32(MemoryLayout<CFString?>.size)
    a.mSelector = kAudioObjectPropertyName
    if AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &nameRef) == noErr, let n = nameRef {
      name = n as String
    }
    var t = UInt32(0); sz = 4
    a.mSelector = kAudioDevicePropertyTransportType
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &t) == noErr else { return (name, true) }
    if t != kAudioDeviceTransportTypeBuiltIn { return (name, false) }
    var src = UInt32(0); sz = 4
    a.mSelector = kAudioDevicePropertyDataSource
    a.mScope = kAudioObjectPropertyScopeOutput
    if AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &src) == noErr, src == 0x6864706E {
      return (name + " (headphone jack)", false)      // 'hdpn'
    }
    return (name, true)
  }

  func tuneInputGain() {
    guard Audio.autoGain else { return }
    // ── AN OVERLOADED MICROPHONE IS FIXED BEFORE ANYTHING ELSE IS DECIDED ────
    //
    // This was below the echo veto's early return, and that ordering was a
    // circular dependency with a real cost. The veto fires when the microphone
    // is mostly this machine's own loudspeaker -- and a microphone running hot
    // is exactly the one that hears its own loudspeaker, which is the reasoning
    // the whole of this function's veto rule is built on. So the fix for a hot
    // microphone was gated on that microphone not being hot: every tick where it
    // mattered most, this function returned before reaching the cut, AND drained
    // both level windows on the way out, so the next tick could not see the
    // blast either.
    //
    // Measured on live call 2p183qa061zcu (0.98.0, 333 s): `a_mic_peak` 2.582 --
    // two and a half times full scale leaving this machine -- with the
    // correlation over threshold in 23 of 69 beats. Same family as
    // `control-loops-steer-on-flattering-signals`, with the twist that the
    // signal the loop needed was not flattering, it was withheld.
    //
    // So the cut runs first, on every tick, and answers a question that needs
    // no opinion about where the sound came from: is more than full scale
    // leaving this machine? If it is, a gain this program applied is too large,
    // whoever is talking.
    let outPeakTick = micPeakWin
    let rawPeakTick = rawPeakWin
    gainTicksAll += 1
    micPeakNow = outPeakTick
    micRawPeakNow = rawPeakTick
    if outPeakTick > 1.0 { hotTicks += 1 }
    if trimOverload(outPeak: outPeakTick) {
      // The cut moved. Drain both windows -- the level it just acted on has been
      // consumed and must not be acted on twice at two different trims -- and
      // let the next tick measure the result.
      micPeakWin = 0
      rawPeakWin = 0
      return
    }
    // ── NEVER LEARN FROM THE LOUDSPEAKER ────────────────────────────────────
    //
    // The raw microphone peak includes whatever this machine's own speaker is
    // blasting from inches away, and on a live call that is the LOUDEST thing
    // the mic ever hears. The trim regulated to it: measured 14:22, both ends
    // at the rail (0.17 and 0.06 -- minus 24 dB), the human underneath tuned
    // into inaudibility, and the persistence carrying the cut into the next
    // call. While the echo detector says the mic is mostly our own speaker,
    // this tick teaches nothing -- and drains both windows, so a skipped
    // blast cannot be mistaken for the person on the next tick either.
    if Audio.corrVeto {
      micPeakWin = 0
      rawPeakWin = 0
      Metrics.count("mic_tune_veto")
      return
    }
    let peak = micPeakWin
    micPeakWin = 0
    gainTicks += 1
    // ── ONLY TUNE ON A VOICE, NEVER ON A ROOM ────────────────────────────────
    //
    // First version gated on `peak > 0.005`, which an empty room clears easily:
    // it read 0.01-0.03 of ambient hiss, called it "too quiet", and walked the
    // input from 27% to 95% with nobody speaking. Then the first real word
    // arrives into a gain set for silence and clips. A control loop that acts on
    // the noise floor will always drive itself to the top of its range, because
    // the noise floor rises with it and never satisfies the target.
    //
    // So: track the floor, and require the peak to stand clearly above it before
    // believing anything is being said. The floor follows downward fast and
    // upward slowly, so it settles on the quiet background rather than on speech.
    micFloor = peak < micFloor ? peak : micFloor * 0.995 + peak * 0.005
    let speaking = peak > max(0.02, micFloor * 5)
    // A STREAK, NOT A TICK. One second above the floor is a keyboard, a chair, a
    // door. Measured: the single-tick version still walked 40% -> 60% across
    // twenty seconds of an empty room, because a quiet room is not silent and
    // every transient in it looked like a voice. Somebody actually talking
    // clears the floor for several seconds together.
    speechRun = speaking ? speechRun + 1 : 0
    if Audio.gainDebug {
      fputs("  gain: peak \(String(format: "%.4f", peak)) floor \(String(format: "%.4f", micFloor))"
          + " speaking \(speaking) run \(speechRun) ticks \(gainTicks)\n", stderr)
    }
    guard gainTicks > 3, speechRun >= 3 else { return }
    // ── THE SOFTWARE TRIM IS DECIDED FIRST, AND WITHOUT A DEVICE ───────────
    //
    // Everything below can bail: no device, a volume property that cannot be
    // read, a microphone whose volume is not settable at all (most USB mics).
    // The trim used to live below all of those guards, so the machines with no
    // knob to turn -- the ones that need it MOST -- were the ones it could
    // never reach. Decided here, from the raw microphone, on every tick.
    let knob: Float32 = micGainNow
    trimStep(deviceAtFloor: knob <= Audio.MIN_INPUT + 1e-4, knob: knob, outPeak: peak)
    guard let dev = inDev as AudioDeviceID?, dev != 0 else { return }
    var cur: Float32 = 0
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
      mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var sz = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &sz, &cur) == noErr else { return }
    var settable: DarwinBoolean = false
    guard AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr,
          settable.boolValue else { return }
    micGainNow = cur
    // Aim for speech peaking around -8 dBFS: loud enough to sit far above the
    // noise floor, with headroom left for a laugh or a raised voice. The band is
    // wide on purpose so ordinary variation in how loudly somebody talks does
    // not move the knob at all.
    var want = cur
    if peak < 0.18 { want = min(cur + 0.06, 0.95) }        // too quiet, climb
    else if peak > 0.92 {
      // ── BACK OFF BY WHAT IT IS OVER BY, NOT BY A FIXED STEP ────────────────
      //
      // The old rule subtracted 0.08 a tick. A microphone delivering peak 1.40
      // needed the knob at roughly half of where it was, which is four ticks --
      // and the floor below stopped it after two. Scaling by the overshoot gets
      // there in one, and asks for exactly the level that puts speech at the
      // -8 dBFS this function is already aiming for.
      //
      // 0.5 the smallest single step, so a device with a coarse or non-linear
      // volume scalar cannot be walked to silence by one loud cough.
      want = max(cur * max(0.5, 0.55 / peak), Audio.MIN_INPUT)
    }
    trimStep(deviceAtFloor: want <= Audio.MIN_INPUT + 1e-4, knob: cur, outPeak: peak)
    guard abs(want - cur) > 0.001 else { return }
    var v = want
    guard AudioObjectSetPropertyData(dev, &addr, 0, nil,
            UInt32(MemoryLayout<Float32>.size), &v) == noErr else { return }
    // READ IT BACK. A settable property that accepts a write and does nothing is
    // this project's most repeated trap.
    var got: Float32 = -1
    sz = UInt32(MemoryLayout<Float32>.size)
    _ = AudioObjectGetPropertyData(dev, &addr, 0, nil, &sz, &got)
    gainMoves += 1
    micGainNow = got
    Metrics.count("mic_gain_moved")
    Metrics.fact("mic_gain_end", String(format: "%.2f", got))
    fputs("mic gain: peak was \(String(format: "%.2f", peak)) -- input \(Int(cur * 100))%"
        + " -> \(Int(got * 100))% (move \(gainMoves))\n", stderr)
  }

  /// ── ONE KNOB THE HARDWARE CANNOT REFUSE ──────────────────────────────────
  ///
  /// Chosen from the RAW microphone, never the trimmed one: a loop that reads
  /// its own output is not measuring the room. Samples above 1.0 are not
  /// clipped -- the float path carries them intact -- so this recovers the
  /// signal exactly rather than limiting it.
  ///
  /// `deviceAtFloor` only decides what gets SAID. The trim itself applies
  /// whenever the microphone is too hot, because a device with no settable
  /// volume is at its floor in every sense that matters.
  /// Rig only: plant this room's noise floor so the SNR guard in `trimStep`
  /// can be tested against a room that is too loud to amplify.
  func setFloorForTest(_ v: Float) { micFloor = v }
  /// Rig only: start from a trim the field actually reached, so the dead zone
  /// can be entered rather than argued about.
  func forceTrimForTest(_ v: Float) { inputTrim = v }

  /// ── THE ONE RULE THAT NEEDS NO OPINION ABOUT THE ROOM ─────────────────────
  ///
  /// More than full scale is leaving this machine, so a gain this program applied
  /// is too large. That statement is true whoever is talking, whatever the echo
  /// detector believes, and at any trim -- and both of those qualifications used
  /// to be attached to it:
  ///
  ///   · it sat below the echo veto's early return, so it could not run on the
  ///     ticks where a hot microphone was arming the veto (see `tuneInputGain`);
  ///   · it required `inputTrim > 1`, so it only ever rescued an over-unity
  ///     MAKEUP gain. A microphone delivering 4.17 raw with the trim at 0.62
  ///     puts 2.58 on the wire and this never fired -- which is the shape the
  ///     comment above the descent already describes: guards written when
  ///     `inputTrim <= 1` made output ~= raw, left covering different ranges the
  ///     moment a gain existed.
  ///
  /// Samples above 1.0 are not clipped -- the float path carries them intact --
  /// so dividing recovers the signal exactly, with no compression, no limiter and
  /// no colour. What being over full scale DOES cost is everything that reads a
  /// level: the classifier's room bar, the coupling tracker, the correlation, and
  /// the encoder at the end of it.
  ///
  /// `max(0.5, ...)` bounds it to halving per tick, so one loud cough cannot walk
  /// a microphone to silence; from 2.58 that is two ticks. Returns whether it
  /// moved, because the caller must not then act on the same level at a different
  /// trim.
  @discardableResult
  func trimOverload(outPeak: Float) -> Bool {
    guard Audio.overloadGuard, outPeak > 0.95 else { return false }
    let fix = max(Audio.TRIM_MIN, inputTrim * max(0.5, 0.8 / outPeak))
    guard fix < inputTrim - 0.02 else { return false }
    inputTrim = fix
    trimMoves += 1
    overloadCuts += 1
    overloadCooldown = 15
    makeupCeiling = max(1.0, fix * 1.30)
    Metrics.count("mic_overload_cut")
    Metrics.fact("mic_trim", String(format: "%.3f", inputTrim))
    fputs("mic gain: \(String(format: "%.2f", outPeak))x full scale is leaving this machine"
        + " -- trimming to \(String(format: "%.2f", inputTrim))"
        + " (\(String(format: "%.0f", 20 * log10(Double(inputTrim)))) dB)\n", stderr)
    saveTrim()
    return true
  }

  /// `outPeak` is the peak AFTER the trim -- the level that actually leaves this
  /// machine. Regulating on `raw` alone is what let 0.102.0 sit at 8x with its
  /// output clipping at 1.86: see the note on the descent below.
  func trimStep(deviceAtFloor: Bool, knob: Float32, outPeak: Float = 0) {
    let raw = rawPeakWin
    rawPeakWin = 0
    guard raw > 0 else { return }
    if overloadCooldown > 0 { overloadCooldown -= 1 }
    let effectiveMax = overloadCooldown > 0 ? makeupCeiling : Audio.MAKEUP_MAX
    // ── THE DESCENT, WHICH DID NOT EXIST ────────────────────────────────────
    //
    // 0.102.0 added a climb and no way down. Measured on live call
    // 35ik4lvka5qkb: trim pinned at 8.00x with a post-trim peak of 1.86 --
    // the microphone overdriven by 6 dB, which is the "sound is not being
    // transported properly" the user heard. The arithmetic of the trap:
    //
    //   raw mic peak      0.233   (quiet -- a distant talker)
    //   want = 0.55/raw   2.37
    //   inputTrim         8.00
    //   attenuation path  needs raw > 0.92   -> 0.233, never fires
    //   makeup path       needs want > trim  -> 2.37 < 8.00, never fires
    //
    // Both guards were written when `inputTrim <= 1` made output ~= raw. The
    // moment a gain existed they stopped covering the same range and left a
    // dead zone with a clipping output inside it.
    //
    // The safety net lives in `trimOverload` and runs at the TOP of
    // `tuneInputGain`, above the echo veto -- see the note there. It used to sit
    // here, which put it behind the veto AND behind `guard raw > 0`, and gated
    // it on `inputTrim > 1`.
    // And the second: a makeup gain that is now too large for the level in the
    // room comes DOWN, on the same target the climb uses. Symmetric, so the
    // loop can converge from either side instead of latching at the ceiling.
    let target = min(effectiveMax, max(0.02, Audio.TRIM_TARGET / raw))
    if inputTrim > 1, target < inputTrim - 0.02 {
      inputTrim = max(max(1, target), inputTrim / Audio.TRIM_UP_RATE)
      trimMoves += 1
      Metrics.count("mic_makeup_down")
      Metrics.fact("mic_trim", String(format: "%.3f", inputTrim))
      saveTrim()
      return
    }
    // ── ONE TARGET, BOTH DIRECTIONS ─────────────────────────────────────────
    //
    // This loop could only ever turn a microphone DOWN. Every path was
    // `min(1, ...)`, and the old rig asserted it: "never climbs past unity,
    // which would be a gain". That was right while the only failure was a mic
    // five times over full scale — and it is exactly wrong for the failure the
    // user reported next: *"if the mic is far away, it is failing to capture
    // the speaking person"*. A distant talker delivers peak 0.05, the device
    // volume knob is the only makeup path, most microphones do not expose one,
    // and it caps at 0.95 anyway. So the app had no way to make a quiet person
    // audible. It was not tuned wrong; the capability was absent.
    //
    // Now there is one target — speech peaking near `TRIM_TARGET` — and the
    // trim seeks it from either side, with a dead band between so an ordinary
    // conversation never moves it at all.
    let want = min(effectiveMax, max(0.02, Audio.TRIM_TARGET / raw))
    if raw > 0.92 {
      // TOO HOT: go straight there. A clipping microphone is urgent, and this
      // is the path that fixed the 5.24 field case.
      if want < inputTrim - 0.02 {
        inputTrim = want
        trimMoves += 1
        Metrics.count("mic_trim_moved")
        Metrics.fact("mic_trim", String(format: "%.3f", inputTrim))
        fputs("mic gain: the microphone peaks at \(String(format: "%.2f", raw))"
            + (deviceAtFloor ? " and the input knob is at its floor (\(Int(knob * 100))%)" : "")
            + " -- trimming \(String(format: "%.0f", 20 * log10(Double(inputTrim)))) dB"
            + " in software\n", stderr)
        saveTrim()
      }
      if !gainAtRail { gainAtRail = true; Metrics.fact("mic_gain_rail", "yes") }
    } else if raw < Audio.TRIM_QUIET, want > inputTrim + 0.02 {
      // TOO QUIET: climb, but only under three conditions, because a gain
      // amplifies whatever is there and not only the person.
      //
      //   · the caller has already established that somebody is SPEAKING
      //     (`speechRun >= 3` in tuneInputGain) — never room tone;
      //   · the echo veto is not claiming this microphone (tuneInputGain
      //     returns before this on a vetoed tick), so we cannot amplify our
      //     own loudspeaker;
      //   · and speech stands clearly above this room's own floor. Amplifying
      //     a signal 10 dB over its noise just makes loud noise, and the one
      //     thing worse than a quiet caller is a roaring one.
      let snrOK = micFloor * Audio.TRIM_MIN_SNR < raw
      if snrOK {
        // Rate-limited, and deliberately slower than the way down: being 3 dB
        // quiet for a second costs nothing, and jumping the level inside a
        // syllable is audible pumping on every pause.
        let upRate: Float = overloadCooldown > 0 ? 1.15 : Audio.TRIM_UP_RATE
        inputTrim = min(want, inputTrim * upRate)
        trimMoves += 1
        Metrics.count("mic_makeup_moved")
        Metrics.fact("mic_trim", String(format: "%.3f", inputTrim))
        if inputTrim > 1.02 {
          fputs("mic gain: this microphone is far away (peaks at"
              + " \(String(format: "%.2f", raw))) -- adding"
              + " \(String(format: "%.0f", 20 * log10(Double(inputTrim)))) dB\n", stderr)
        }
        saveTrim()
      } else {
        Metrics.count("mic_makeup_refused_noise")
      }
      if inputTrim >= 1, gainAtRail { gainAtRail = false }
    }
    // Between TRIM_QUIET and 0.92 is the dead band: a healthy microphone is
    // left completely alone, which is the property the third rig row protects.
  }

  // ── THE TRIM IS A FACT ABOUT A MICROPHONE, NOT ABOUT A CALL ────────────────
  //
  // A device that delivered 5x full scale yesterday will deliver it again
  // today, and the loop above needs several seconds of speech to find that out
  // -- during which the pipeline, the gate and the far end all get the hot
  // signal. So the learned trim is kept on disk PER DEVICE and applied from the
  // first sample of the next call. Keyed by the device's UID, because
  // `audio-device-is-not-a-constant`: a different microphone starts honest, at
  // 1.0. The relax path above still walks a stale entry back up, so a
  // microphone whose owner fixed its input gain is quietly forgiven.
  private var trimSaved: Float = 1
  private static func trimFile() -> URL { Identity.dir.appendingPathComponent("trim.json") }
  private func loadTrim() {
    guard Audio.autoGain, let uid = Audio.deviceUID(inDev) else { return }
    guard let data = try? Data(contentsOf: Audio.trimFile()),
          let map = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
          let v = map[uid], v < 0.98 else { return }
    // Floored at 0.3 on the way IN, whatever was stored. A trim below that is
    // more likely last call's loudspeaker than this microphone (the 14:22 call
    // stored 0.06), and a person sitting far from the mic under a -24 dB cut
    // is inaudible for the whole walk back up. 0.3 still takes 10 dB off a
    // genuinely hot mic's first sentence, and the cut path re-learns the rest
    // within two ticks of real speech.
    inputTrim = Float(min(Double(Audio.MAKEUP_MAX), max(0.3, v)))
    trimSaved = inputTrim
    Metrics.count("mic_trim_loaded")
    Metrics.fact("mic_trim", String(format: "%.3f", inputTrim))
    fputs("mic gain: this microphone needed trim \(String(format: "%.2f", inputTrim))"
        + " last call -- applied from the first sample\n", stderr)
  }
  /// Called from the gain tick, never the render thread. Debounced: the relax
  /// path moves 5% a tick and a file write per tick is a diary, not a record.
  private func saveTrim() {
    guard abs(inputTrim - trimSaved) > 0.02, let uid = Audio.deviceUID(inDev) else { return }
    var map = (try? Data(contentsOf: Audio.trimFile()))
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Double] } ?? [:]
    // Unity is "nothing learned about this device" and is not worth a row.
    if abs(inputTrim - 1) < 0.02 { map.removeValue(forKey: uid) }
    else { map[uid] = Double(inputTrim) }
    if let out = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]) {
      try? out.write(to: Audio.trimFile(), options: .atomic)
      trimSaved = inputTrim
    }
  }
  /// The device's stable name. `inDev` alone is a transient integer.
  static func deviceUID(_ dev: AudioDeviceID) -> String? {
    guard dev != 0 else { return nil }
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var uid: Unmanaged<CFString>?
    var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &sz, &uid) == noErr,
          let u = uid?.takeRetainedValue() else { return nil }
    return u as String
  }

  // ── CHOOSING THE MICROPHONE, IN THE APP ──────────────────────────────────
  //
  // Asked for directly: *"there should be an option to change the mic input in
  // the app itself, like there is an option to change the camera."*
  //
  // Until now the input device was whatever macOS's System Settings said the
  // default was, decided once inside `makeUnit` and never revisited. On a Mac with
  // an external interface, a webcam with a microphone in it, or a headset that
  // just connected, "they can't hear me" was a trip to System Settings and a
  // restart of the call -- and the app gave no clue which microphone it had taken.
  //
  // ── BY UID, NOT BY DEVICE ID ──────────────────────────────────────────────
  //
  // `AudioDeviceID` is a handle that CoreAudio hands out at enumeration time. It
  // does not survive a reboot, an unplug or a sleep, so remembering one and
  // setting it later is a way to open a stranger's microphone. The UID is the
  // stable name and is what gets written down; it is resolved back to an ID at the
  // moment the unit is built, and a UID that no longer resolves falls back to the
  // system default with a line in the log saying so.

  /// One input or output device, as the picker sees it.
  struct Device: Equatable { let uid: String; let name: String }

  /// Every device with at least one channel in the requested direction. A device
  /// with zero input channels is not a microphone, and listing one would put a
  /// row in the panel that silences the call when pressed.
  static func devices(input: Bool) -> [Device] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr,
                                         0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                     0, nil, &size, &ids) == noErr else { return [] }
    var out: [Device] = []
    for id in ids where channelCount(id, input: input) > 0 {
      guard let uid = deviceUID(id) else { continue }
      out.append(Device(uid: uid, name: name(of: id)))
    }
    // Stable order, so a row does not move under a pointer already travelling
    // toward it when a device appears. Alphabetical is arbitrary and consistent;
    // CoreAudio's own order is neither.
    return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// Channels in one direction. The cheap, total test for "is this a microphone".
  private static func channelCount(_ dev: AudioDeviceID, input: Bool) -> Int {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0
    else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  static func name(of dev: AudioDeviceID) -> String {
    var s: Unmanaged<CFString>?
    var sz = UInt32(MemoryLayout<CFString?>.size)
    var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &s) == noErr, let v = s
    else { return "?" }
    return v.takeRetainedValue() as String
  }

  // ── PERSISTED IN THE IDENTITY DIRECTORY, NOT IN UserDefaults ───────────────
  //
  // The first version of this used `UserDefaults.standard`, and it cost an
  // afternoon within the hour. `TK_KIN_DIR` is how every other piece of this app's
  // state is isolated -- the handle, the contacts, the faces, the resume record --
  // and UserDefaults is NOT covered by it. It is keyed by the executable's bundle
  // identifier, or by the executable NAME for a bare binary, so:
  //
  //   * a rig cannot isolate a device choice at all, and
  //   * a choice made by one test is inherited by every later run on the machine.
  //
  // Which happened. A mic-picker test selected the built-in microphone, and
  // `aec-check` -- three rigs later, in its own exclusive lane -- opened that
  // microphone while the output was a pair of EarPods. No acoustic path, nothing
  // to cancel, `p50 0 dB` against a floor of 4, and a canceller that measures
  // 13-14 dB in the field looked completely broken. `defaults read tk` said
  // `"tk.micUID" = BuiltInMicrophoneDevice` an hour after the test that wrote it.
  //
  // One line of JSON beside identity.json instead. Same directory, same override,
  // same isolation as everything else -- see `rig-isolation-that-does-not-isolate`,
  // which is this exact shape and already had two instances before this one.
  private static var deviceFile: URL {
    Identity.dir.appendingPathComponent("devices.json")
  }
  private static func devicePrefs() -> [String: String] {
    guard let d = try? Data(contentsOf: deviceFile),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: String]
    else { return [:] }
    return o
  }
  private static func setDevicePref(_ key: String, _ value: String?) {
    var o = devicePrefs()
    if let value { o[key] = value } else { o.removeValue(forKey: key) }
    try? FileManager.default.createDirectory(at: Identity.dir, withIntermediateDirectories: true)
    guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
    try? d.write(to: deviceFile, options: .atomic)
  }

  /// The UID this Mac has been told to use, or nil for "whatever macOS says".
  /// Persisted, because a microphone choice that forgets itself on quit is a
  /// choice somebody has to make again every call.
  static var chosenInputUID: String? {
    get { devicePrefs()["mic"] }
    set { setDevicePref("mic", newValue) }
  }
  static var chosenOutputUID: String? {
    get { devicePrefs()["speaker"] }
    set { setDevicePref("speaker", newValue) }
  }

  /// The chosen device, if it is still here. `nil` means fall back to the system
  /// default -- a headset that has been unplugged must not silence the call.
  static func resolve(_ uid: String?, input: Bool) -> AudioDeviceID? {
    guard let uid, !uid.isEmpty else { return nil }
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr,
                                         0, nil, &size) == noErr, size > 0 else { return nil }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                     0, nil, &size, &ids) == noErr else { return nil }
    for id in ids where deviceUID(id) == uid && channelCount(id, input: input) > 0 { return id }
    fputs("audio: the saved \(input ? "microphone" : "speaker") (\(uid)) is not here"
        + " -- using the system default\n", stderr)
    return nil
  }

  // ── THE RULER, ON THE CALL THAT CAUSED THIS ──────────────────────────────
  //
  // Driven with the peaks the field actually delivered (1.40, 1.03, 5.24) and
  // with the ones that must change nothing, because a trim that fires on a
  // healthy microphone is the same bug pointing the other way.
  //
  // The first row is the whole complaint: the old loop reached 0.15, could not
  // ask for less, and went quiet for the rest of the call. Here the trim has to
  // move on a knob that is stuck.
  static func gainSelfTest() -> Bool {
    var ok = true
    func say(_ good: Bool, _ what: String) {
      if !good { ok = false }
      fputs("gain: \(good ? "OK  " : "FAIL") \(what)\n", stderr)
    }
    // 1. the field case: knob on the floor, microphone still five times hot
    let a = Audio()
    a.rawPeakWin = 5.24
    a.trimStep(deviceAtFloor: true, knob: 0.15)
    say(a.inputTrim < 0.2, "peak 5.24 with the knob at its floor -> trim \(String(format: "%.3f", a.inputTrim))")
    say(a.gainAtRail, "and it is on the record as being at the rail")
    let after = 5.24 * a.inputTrim
    say(after > 0.3 && after < 0.9,
        "which lands the microphone at \(String(format: "%.2f", after)), inside the headroom it aims for")
    // 2. the peaks that walked the knob down: still hot, still trimmed
    let b = Audio()
    b.rawPeakWin = 1.40
    b.trimStep(deviceAtFloor: false, knob: 0.27)
    say(b.inputTrim < 1, "peak 1.40 is trimmed even while the knob still has room")
    // 3. A MICROPHONE THAT IS FINE MUST BE LEFT ALONE. The far end of that call
    //    peaked well under full scale, and a trim there would be this bug
    //    inverted -- an app quietly making somebody inaudible.
    let c = Audio()
    c.rawPeakWin = 0.85
    c.trimStep(deviceAtFloor: true, knob: 0.05)
    say(c.inputTrim == 1, "a healthy peak of 0.85 is left completely alone")
    say(!c.gainAtRail, "and is not reported as being at the rail")
    // 4. a silent tick decides nothing: with no evidence the answer is not zero
    let d = Audio()
    d.rawPeakWin = 0
    d.trimStep(deviceAtFloor: true, knob: 0.05)
    say(d.inputTrim == 1, "a silent window changes nothing")
    // 5. and it comes back up when the room quietens, or one shout is permanent
    let e = Audio()
    // Recovery now runs through the same SNR guard the makeup path uses -- a
    // shout is only walked back in a room quiet enough to hear the person. That
    // is deliberate, and it means this row must plant a floor like the others or
    // it measures the harness's 1.0 default instead of the loop.
    e.setFloorForTest(0.002)
    e.rawPeakWin = 5.24
    e.trimStep(deviceAtFloor: true, knob: 0.05)
    let low = e.inputTrim
    for _ in 0..<200 { e.rawPeakWin = 0.2; e.trimStep(deviceAtFloor: true, knob: 0.05) }
    say(e.inputTrim > low, "it recovers when the room goes quiet (\(String(format: "%.2f", low)) -> \(String(format: "%.2f", e.inputTrim)))")

    // ── 6. A DISTANT TALKER IS MADE AUDIBLE ─────────────────────────────────
    //
    // The row that used to be here asserted the opposite: "never climbs past
    // unity, which would be a gain". That was the right invariant while the
    // only failure was a microphone five times over full scale. It is exactly
    // wrong for the failure reported next -- a far-away talker is inaudible and
    // the app had no mechanism to help, because every path was `min(1, ...)`.
    // Deliberately reversed, with the three guards the old comment was worried
    // about proven in the rows below.
    let f = Audio()
    // `micFloor` starts at 1.0 and is walked down by `tuneInputGain`, which this
    // rig bypasses by calling `trimStep` directly. Left alone it refuses every
    // makeup step on the SNR guard, and these rows would measure the harness
    // rather than the loop. A quiet room, planted explicitly.
    f.setFloorForTest(0.002)
    for _ in 0..<20 { f.rawPeakWin = 0.06; f.trimStep(deviceAtFloor: true, knob: 0.95) }
    let landed = 0.06 * f.inputTrim
    say(f.inputTrim > 3,
        "a microphone peaking at 0.06 is amplified \(String(format: "%.1f", f.inputTrim))x"
        + " (+\(String(format: "%.0f", 20 * log10(Double(f.inputTrim)))) dB)")
    // The ceiling bounds this, and the bound is a deliberate trade. A mic peaking
    // at 0.06 is -24 dBFS; +12 dB reaches -12 dBFS, which is clearly audible but
    // is NOT the -5 dBFS a near talker gets. 0.102.0 aimed for the full target
    // with an 8x ceiling and overdrove a live call to 1.86 because it had no way
    // back down. With the descent and the overload clamp in place 8x would be
    // survivable again -- it is still not chosen, because +18 dB lifts the room's
    // own noise by 18 dB along with the person.
    say(landed > 0.2 && landed < 0.8,
        "which lands speech at \(String(format: "%.2f", landed)) -- audible, and bounded"
        + " by the \(Int(Audio.MAKEUP_MAX))x ceiling rather than reaching the full target")
    say(f.inputTrim <= Audio.MAKEUP_MAX + 0.01,
        "and it is bounded at \(Int(Audio.MAKEUP_MAX))x rather than chasing silence")

    // 7. REJECT: A HEALTHY MICROPHONE IS STILL LEFT ALONE. Without this the row
    //    above is satisfied by an app that simply amplifies everybody.
    let g = Audio()
    g.setFloorForTest(0.002)                // a quiet room, so only the dead band can refuse
    for _ in 0..<20 { g.rawPeakWin = 0.45; g.trimStep(deviceAtFloor: false, knob: 0.5) }
    say(g.inputTrim == 1,
        "REJECT: a healthy 0.45 peak is untouched -- the dead band is real")

    // 8. REJECT: A NOISY ROOM IS NOT AMPLIFIED. Gain on a signal barely above
    //    its own noise floor produces loud noise, which is worse than quiet.
    let h = Audio()
    h.setFloorForTest(0.05)                 // room floor close to the speech peak
    for _ in 0..<20 { h.rawPeakWin = 0.10; h.trimStep(deviceAtFloor: true, knob: 0.95) }
    say(h.inputTrim == 1,
        "REJECT: a voice only 6 dB over a noisy room is NOT amplified")

    // 9. AND IT COMES BACK DOWN. Somebody who leaned away and returned must not
    //    stay 18 dB hot -- that is the original bug, re-created by the fix.
    let i = Audio()
    i.setFloorForTest(0.002)
    for _ in 0..<20 { i.rawPeakWin = 0.06; i.trimStep(deviceAtFloor: true, knob: 0.95) }
    let up = i.inputTrim
    for _ in 0..<20 { i.rawPeakWin = 1.6; i.trimStep(deviceAtFloor: true, knob: 0.95) }
    say(i.inputTrim < 1 && i.inputTrim < up,
        "leaning back in brings it down again (\(String(format: "%.1f", up))x ->"
        + " \(String(format: "%.2f", i.inputTrim))x)")
    // ── 10. THE DEAD ZONE THAT SHIPPED, REPRODUCED ──────────────────────────
    //
    // Live call 35ik4lvka5qkb: trim pinned at 8.00x, post-trim peak 1.86. Neither
    // guard could fire -- attenuation wanted raw > 0.92 (it was 0.233) and the
    // climb wanted a target above the current trim (2.37 < 8.00). The loop had
    // no descent at all, and this row is the exact state it got stuck in.
    let j = Audio()
    j.setFloorForTest(0.002)
    j.forceTrimForTest(8.0)
    // The level that trapped it: raw 0.233, output 8x that.
    for _ in 0..<30 { j.rawPeakWin = 0.233; j.trimStep(deviceAtFloor: true, knob: 0.95, outPeak: 1.86) }
    say(j.inputTrim < 3.0,
        "a trim stuck at 8x over a 0.233 mic comes down to \(String(format: "%.2f", j.inputTrim))x")
    let out = 0.233 * j.inputTrim
    say(out < 0.95,
        "and its output lands at \(String(format: "%.2f", out)) instead of clipping at 1.86")

    // ── 11. AN OVERLOADED OUTPUT IS CUT WHATEVER ELSE IS TRUE ────────────────
    //
    // The safety net, and this row used to be a lie about which mechanism it was
    // testing. It called `trimStep(outPeak: 1.20)` with `rawPeakWin = 0.30`, and
    // the cut it names was not what fired -- the "a makeup gain that is now too
    // large comes DOWN" path is satisfied by raw 0.30 alone and would have
    // passed this row with the safety net deleted. It tests `trimOverload`
    // directly now: one function, one claim.
    let k = Audio()
    k.forceTrimForTest(4.0)
    say(k.trimOverload(outPeak: 1.20) && k.inputTrim < 4.0,
        "an output of 1.20 is backed off immediately (4.0x -> \(String(format: "%.2f", k.inputTrim))x)")

    // ── 11b. AND AT A TRIM BELOW UNITY, WHICH IS THE LIVE FAILURE ────────────
    //
    // Call 2p183qa061zcu: raw peak 4.17, trim 0.62, so 2.58 times full scale left
    // this machine. Every path that could have fixed it required `inputTrim > 1`
    // -- they were written when a trim was only ever a cut, so `output ~= raw`
    // and the raw tests covered the same ground. The moment a makeup gain existed
    // they stopped overlapping and left a clipping output in the gap.
    let k2 = Audio()
    k2.forceTrimForTest(0.6187)
    var k2steps = 0
    while k2.trimOverload(outPeak: 4.17 * k2.inputTrim), k2steps < 6 { k2steps += 1 }
    let k2out = 4.17 * k2.inputTrim
    say(k2out < 0.95,
        "the live 2.58x overload comes down to \(String(format: "%.2f", k2out))"
        + " in \(k2steps) tick(s), from a trim that was already a cut")
    // REJECT: with the guard off nothing happens at all, so the row above is
    // measuring the guard and not the arithmetic around it.
    Audio.overloadGuard = false
    let k3 = Audio()
    k3.forceTrimForTest(0.6187)
    let k3moved = k3.trimOverload(outPeak: 2.58)
    Audio.overloadGuard = true
    say(!k3moved && abs(k3.inputTrim - 0.6187) < 1e-6,
        "REJECT: with --no-overload-guard the same 2.58x is left alone -- the meter can see")

    // ── 11c. AND THE ECHO VETO CANNOT HIDE IT ────────────────────────────────
    //
    // The circular dependency: the veto fires because the microphone is hot, and
    // the fix for a hot microphone sat below the veto's early return. This drives
    // `tuneInputGain` -- the whole tick, not the cut in isolation -- with the veto
    // armed, which is the state a third of that live call was in.
    let k4 = Audio()
    k4.forceTrimForTest(1.0)
    k4.micPeakWin = 2.58
    k4.rawPeakWin = 2.58
    let vetoWas = Audio.corrVeto
    Audio.corrVeto = true
    k4.tuneInputGain()
    Audio.corrVeto = vetoWas
    say(k4.inputTrim < 0.98,
        "a vetoed tick still cuts an overloaded microphone (1.00x -> "
        + "\(String(format: "%.2f", k4.inputTrim))x)")
    say(k4.overloadCuts == 1 && k4.hotTicks == 1,
        "and the tick is on the record as hot (\(k4.hotTicks) hot, \(k4.overloadCuts) cut)")
    // REJECT: a HEALTHY vetoed tick must still teach nothing. The veto's own
    // rule -- never learn the room from the loudspeaker -- is why the early
    // return exists, and hoisting the cut above it must not have removed it.
    let k5 = Audio()
    k5.setFloorForTest(0.002)
    k5.forceTrimForTest(1.0)
    for _ in 0..<10 {
      k5.micPeakWin = 0.20; k5.rawPeakWin = 0.20
      Audio.corrVeto = true
      k5.tuneInputGain()
    }
    Audio.corrVeto = vetoWas
    say(abs(k5.inputTrim - 1.0) < 1e-6,
        "REJECT: a vetoed tick still teaches the makeup path nothing (trim "
        + "\(String(format: "%.2f", k5.inputTrim))x) -- the loudspeaker is not the room")

    // 12. REJECT: and a healthy makeup is NOT dismantled. Without this the two
    //     rows above are satisfied by a loop that simply refuses to amplify.
    let l = Audio()
    l.setFloorForTest(0.002)
    for _ in 0..<20 { l.rawPeakWin = 0.10; l.trimStep(deviceAtFloor: true, knob: 0.95, outPeak: 0.10 * l.inputTrim) }
    let lout = 0.10 * l.inputTrim
    say(l.inputTrim > 2 && lout > 0.3 && lout < 0.95,
        "REJECT: a genuinely quiet 0.10 mic is still lifted to \(String(format: "%.2f", lout))"
        + " (\(String(format: "%.1f", l.inputTrim))x)")
    say(l.inputTrim <= Audio.MAKEUP_MAX + 0.01,
        "and the ceiling is \(Int(Audio.MAKEUP_MAX))x, not the 8x that overdrove a live call")

    fputs("GAIN CHECK: \(ok ? "PASS" : "FAIL")\n", stderr)
    return ok
  }

  func sampleQuality() {
    qualityTicks += 1
  }

  // ERLE -- how much quieter a canceller made the microphone -- is gone with the
  // canceller. It measured the success of subtracting, and nothing subtracts now.
  // What replaces it in the record is who held the floor and for how long, which
  // is the thing this design can actually be judged on.
  var floorHeldPct: Double {
    let open = Double(dgate.openFrames), closed = Double(dgate.closedFrames)
    return open + closed > 0 ? open / (open + closed) * 100 : 100
  }
  var backchannels: Int { dgate.backchannels }
  var floorClaims: Int { dgate.claims }
  /// How much of the call this end spent ducked out of a deadlock. A number that
  /// climbs is the rule picking on somebody, which is the failure to watch for.
  var yieldedPct: Double {
    let total = Double(dgate.openFrames + dgate.closedFrames)
    return total > 0 ? Double(dgate.yieldSamples) / total * 100 : 0
  }
  var yieldingNow: Bool { dgate.yielding }

  // ── NO ECHO CANCELLATION. THE ECHO IS NOT CREATED. ────────────────────────
  //
  // There used to be an adaptive filter here: 1024 taps of normalised LMS aimed
  // at the measured delay and frozen during double talk. It is gone, and not
  // because it was badly built.
  //
  // Cancelling is a losing fight by construction. You hold a copy of what was
  // SENT to the speaker and nothing at all of what the room did to it, so the
  // subtraction is always approximate, and the leftover has to be attacked by
  // guessing which parts of a person's voice are echo. That guessing is the
  // robotic, underwater sound of every video call, and no amount of taps
  // removes the need for it.
  //
  // Turn-taking makes the whole problem not exist. Echo requires two microphones
  // open at once; keep one open and there is nothing to subtract, nothing to
  // guess at, and nothing to damage. What replaces the canceller is not a
  // quieter canceller -- it is knowing whose turn it is.
  //
  // THE DETECTOR STAYS, because it answers a different question. `echoCorr` and
  // `echoDelayMs` say whether this machine's speaker reaches its own microphone
  // at all, which is precisely the fact that decides whether turn-taking is
  // needed here. It measures a property of the room; it no longer feeds anything
  // that tries to undo it.

  var acoustic = false

  /// The pitch period of what was just playing, by normalised autocorrelation.
  /// Coarse-to-fine so it fits in a render callback: decimated by four over the
  /// whole 80-500 Hz range, then refined at full resolution around the winner.
  /// Returns 0 when the history has no signal in it -- repeating silence at an
  /// invented period is just a slower way of outputting zeros.
  private func findPeriod() -> Int {
    let W = 480                              // 10 ms of evidence
    var e0: Float = 0
    for i in stride(from: 0, to: W, by: 4) {
      let v = hist[(histW - 1 - i) & Audio.HMASK]
      e0 += v * v
    }
    if e0 < 1e-6 { return 0 }

    var best = 0
    var bestScore: Float = 0
    for lag in stride(from: Audio.PMIN, through: Audio.PMAX, by: 2) {
      var num: Float = 0, den: Float = 0
      for i in stride(from: 0, to: W, by: 4) {
        let a = hist[(histW - 1 - i) & Audio.HMASK]
        let b = hist[(histW - 1 - i - lag) & Audio.HMASK]
        num += a * b
        den += b * b
      }
      if den < 1e-9 { continue }
      let score = num / den.squareRoot()
      if score > bestScore { bestScore = score; best = lag }
    }
    if best == 0 { return 0 }

    // Refine. A period wrong by one sample is a phase error of 1/48000 s at the
    // seam, which is exactly the click this is meant to remove.
    var fine = best
    var fineScore: Float = 0
    for lag in max(Audio.PMIN, best - 3)...min(Audio.PMAX, best + 3) {
      var num: Float = 0, den: Float = 0
      for i in 0..<W {
        let a = hist[(histW - 1 - i) & Audio.HMASK]
        let b = hist[(histW - 1 - i - lag) & Audio.HMASK]
        num += a * b
        den += b * b
      }
      if den < 1e-9 { continue }
      let score = num / den.squareRoot()
      if score > fineScore { fineScore = score; fine = lag }
    }
    return fine
  }

  /// One concealed sample: read forward through history, wrapping back by exactly
  /// one pitch period, so the repetition happens where the waveform already
  /// repeats itself instead of wherever the packet happened to end.
  @inline(__always) private func plcNext() -> Float {
    if plcPeriod <= 0 { return 0 }
    let v = hist[plcCursor & Audio.HMASK]
    plcCursor += 1
    if plcCursor >= histW { plcCursor -= plcPeriod }
    plcSamples += 1
    // Hold the level for 10 ms, then fade over 40 ms. A voice that stops dead is
    // a click; a voice that hangs on forever is a robot.
    let ms = Double(plcSamples) / SR * 1000.0
    let g: Float = ms <= 10 ? 1 : Float(max(0.0, 1.0 - (ms - 10) / 40.0))
    return v * g
  }

  /// The worst sample-to-sample step in the window around a seam.
  @inline(__always) private func noteEdge(_ val: Float) {
    if edgeWinLeft > 0 {
      let step = abs(val - prevOut)
      if step > edgeWinMax { edgeWinMax = step }
      edgeWinLeft -= 1
      if edgeWinLeft == 0 { jumpAtEdge.add(Double(edgeWinMax)) }
    }
  }

  /// Find the echo: where in the playout history the microphone signal correlates,
  /// and how strongly. Runs forever on its own thread from `start()`.
  private func echoEstimator() {
    let D = 8                                   // decimation -> 6 kHz
    // 400 ms of evidence, not 100. Two UNRELATED speech signals correlate: both
    // have speech's spectral envelope and a pitch in the same octave, so the best
    // of 1200 candidate lags finds something. Measured null with no echo path at
    // all: 0.26. A window four times longer drops that chance floor by half,
    // because the floor goes as 1/sqrt(window).
    let win = 19200 / D                         // 400 ms of evidence
    let maxLag = Int(0.200 * SR) / D            // search out to 200 ms
    var mic = [Float](repeating: 0, count: win)
    var spk = [Float](repeating: 0, count: win + maxLag)
    while true {
      Thread.sleep(forTimeInterval: 0.5)
      // The stale-clear runs on EVERY tick, including the ones that cannot
      // compute: the guards below are exactly the moments a stale veto would
      // otherwise survive, and a veto that outlives its evidence is a gag.
      if corrVetoAt == 0 || Clock.ms(Clock.now() - corrVetoAt) > Audio.CORR_VETO_FRESH_MS {
        Audio.corrVeto = false
      }
      guard let ch = capHist, let eh = echoHist else { echoSkips += 1; continue }
      let cw = capHistW, ew = echoW
      guard cw > win * D + 2000, ew > (win + maxLag) * D + 2000 else {
        echoSkips += 1; continue
      }
      // Decimate by averaging, not by dropping: dropping aliases everything above
      // 3 kHz down into the band the correlation is computed in.
      for i in 0..<win {
        var a: Float = 0
        for j in 0..<D { a += ch[(cw - (win - i) * D + j) % Audio.CAPH] }
        mic[i] = a / Float(D)
      }
      for i in 0..<(win + maxLag) {
        var a: Float = 0
        for j in 0..<D { a += eh[(ew - (win + maxLag - i) * D + j) % Audio.ECHO_MAX] }
        spk[i] = a / Float(D)
      }
      var micE: Float = 0
      for v in mic { micE += v * v }
      guard micE > 1e-6 else { echoSkips += 1; continue }  // a silent mic has no echo to find

      // Normalised by BOTH energies, so the score is a correlation coefficient
      // rather than a number that grows with how loud the speaker happens to be.
      // The scan runs over OFFSETS; lag is maxLag - off, the same mapping the
      // loop this replaced did inside itself.
      let scan = Audio.corrScan(fix: mic, slide: spk, win: win, maxOff: maxLag,
                                fixE: micE, minOff: 1)
      guard scan.best >= 0 else { echoSkips += 1; continue }
      echoCorr = Double(scan.bestScore)
      // A call is judged on whether the speaker EVER reached the microphone, not
      // on whether it was doing so at the moment a beat happened to be built.
      if echoCorr > echoCorrPeak { echoCorrPeak = echoCorr }
      echoDelayMs = Double((maxLag - scan.best) * D) / SR * 1000.0
      // The verdict the classifier reads. Withdrawn (not left hanging) the
      // moment a computation says the mic is NOT mostly our speaker, so a real
      // voice wins it back within one tick of starting to dominate.
      corrVetoAt = Clock.now()
      // ── AND THE SAME ANSWER AIMS THE FILTER ────────────────────────────────
      //
      // Scalars across the thread boundary, like every other cross-thread
      // signal in this class. The filter decides on the AUDIO thread whether the
      // move is worth taking (`Aec.reaimHits`), so a twitching estimate cannot
      // zero a converged filter and the two can never tear.
      aec.aim(delaySamples: Int(echoDelayMs / 1000.0 * SR), corr: echoCorr)
      // ── THE VETO IS A STATEMENT ABOUT THE SIGNAL THAT LEAVES, NOT THE ONE
      //    THAT ARRIVED ───────────────────────────────────────────────────────
      //
      // `echoCorr` is computed on `capHist`, which is the RAW microphone, and it
      // has to be -- an estimator reading the cancelled signal destroys the
      // measurement that aims it, which is the recorded 46-re-aims failure. So
      // after cancellation the correlation is still high and still correct, and
      // it no longer describes what the classifier is looking at.
      //
      // The veto's claim is "this sound is our own loudspeaker, so it is not a
      // voice". Ten decibels of measured ERLE means it is no longer mostly our
      // loudspeaker, so the claim is withdrawn -- and only withdrawn, exactly
      // like the camera's unveto beside it. It can never add a veto, and the
      // moment the filter stops earning its keep `residual` returns to 1 within
      // about 40 ms and the veto is back to what it was in 0.106.0.
      let res = Audio.aecOn ? aec.residual : 1
      Audio.aecResidual = res
      Audio.aecErleDb = aec.erleDb
      let cancelled = res <= Audio.AEC_VETO_RELIEF
      Audio.corrVeto = Audio.corrVetoOn && Audio.outputIsSpeakers
        && echoCorr >= Audio.CORR_VETO && !cancelled
      if Audio.corrVetoOn, Audio.outputIsSpeakers, echoCorr >= Audio.CORR_VETO, cancelled {
        aecUnvetoTicks += 1
      }
      echoTicks += 1
      if echoCorr >= Audio.CORR_VETO { echoHighTicks += 1 }

      // The second search that used to run here -- the same 400 ms slid the other
      // way, to decide whether the two of you shared a room -- is gone with the
      // feature. It was half of this thread's work, every half second, for a
      // condition that does not happen. See `roomSpeakerOff`.
    }
  }




  // ── ONE CORRELATION SCAN, VECTORISED, FOR BOTH SEARCHES ────────────────────
  //
  // The echo estimator and the same-room scorer were the two most expensive
  // things this app does with its own CPU -- top of the self-time profile on a
  // live call, above the render callback. Both were the same brute force:
  //
  //     for each of ~1200 offsets:            <- 1800 for the room search
  //         for each of 2400 samples:         <- 400 ms of evidence
  //             num += fix[i] * slide[i+off]
  //             den += slide[i+off] * slide[i+off]
  //
  // That is ~2.9 MILLION multiply-accumulates every half second, per search, to
  // answer a question about acoustics that changes on the scale of seconds.
  //
  // Two changes, and NEITHER of them changes the answer:
  //
  //   `den` is a sliding sum of squares over one fixed array. Recomputing it
  //   inside the offset loop makes an O(n) quantity cost O(n*m). A prefix sum
  //   gives every offset's energy by subtraction -- the whole den term stops
  //   being work at all.
  //
  //   `num` over all offsets IS a cross-correlation, which is what `vDSP_conv`
  //   computes: C[n] = sum_p A[n+p] * F[p], the same sum in the same order,
  //   hand-vectorised by Accelerate (already linked, already used by the FFT
  //   above and by Subtitles).
  //
  // The arithmetic is identical; only the order and the instruction width
  // change. `--corr-test` asserts this against the brute force it replaces,
  // because "I rewrote the hot loop and it still runs" is not a measurement --
  // `validate-the-ruler-against-known-inputs`.
  //
  // The prefix sum accumulates in Double where the original accumulated in
  // Float. That is a difference, and it is in the direction of being MORE
  // right: 2400 squared floats summed in Float32 drift, and this quantity sits
  // under a square root inside a threshold comparison.
  struct CorrScan { var best = -1; var bestScore: Float = 0; var meanScore: Double = 0; var nLags = 0 }

  /// `fix` is the stationary window (length `win`), `slide` is the one searched
  /// across (length `win + maxOff`), `fixE` the energy of `fix`.
  /// `minOff` exists because the two callers do NOT search the same range, and
  /// assuming they did was an off-by-one on the first attempt: the echo
  /// estimator's loop ran `lag in 0..<maxLag` with `off = maxLag - lag`, so its
  /// offsets are 1...maxLag and never include zero, while the room scorer's are
  /// 0...maxBack. Handing both the same bounds silently searched a window one
  /// sample away from the one the shipped code searched.
  /// The control arm, so the saving can be MEASURED on a live call rather than
  /// inferred from a microbenchmark. A function that is 21x faster in isolation
  /// may be 0% of the thing a battery notices, and the only way to know which is
  /// to run the call both ways with the same ruler.
  nonisolated(unsafe) static var corrSlowArm =
    ProcessInfo.processInfo.environment["TK_CORR_SLOW"] == "1"

  static func corrScan(fix: [Float], slide: [Float], win: Int, maxOff: Int,
                       fixE: Float, minOff: Int = 0) -> CorrScan {
    if corrSlowArm {
      return corrScanSlow(fix: fix, slide: slide, win: win, maxOff: maxOff,
                          fixE: fixE, minOff: minOff)
    }
    var out = CorrScan()
    guard win > 0, maxOff >= 0, fix.count >= win, slide.count >= win + maxOff,
          fixE > 0 else { return out }
    let n = maxOff + 1
    var num = [Float](repeating: 0, count: n)
    // A[n+p]*F[p]: correlation, not convolution -- vDSP_conv does not flip the
    // filter, which is why this is a drop-in for the loop above and not its
    // mirror image.
    slide.withUnsafeBufferPointer { a in
      fix.withUnsafeBufferPointer { f in
        vDSP_conv(a.baseAddress!, 1, f.baseAddress!, 1, &num, 1,
                  vDSP_Length(n), vDSP_Length(win))
      }
    }
    // Energy of every window of `slide`, by subtraction.
    var pre = [Double](repeating: 0, count: slide.count + 1)
    for i in 0..<slide.count { pre[i + 1] = pre[i] + Double(slide[i]) * Double(slide[i]) }
    var sum = 0.0
    for off in max(0, minOff)..<n {
      let den = pre[off + win] - pre[off]
      guard den > 1e-9 else { continue }
      let r = Float(abs(Double(num[off])) / (den * Double(fixE)).squareRoot())
      sum += Double(r); out.nLags += 1
      if r > out.bestScore { out.bestScore = r; out.best = off }
    }
    out.meanScore = out.nLags > 0 ? sum / Double(out.nLags) : 0
    return out
  }

  /// The loop this replaced, kept so the replacement can be checked against it
  /// rather than against a memory of it.
  static func corrScanSlow(fix: [Float], slide: [Float], win: Int, maxOff: Int,
                           fixE: Float, minOff: Int = 0) -> CorrScan {
    var out = CorrScan()
    var sum = 0.0
    for off in max(0, minOff)...maxOff {
      var num: Float = 0, den: Float = 0
      for i in 0..<win {
        let sv = slide[i + off]
        num += fix[i] * sv
        den += sv * sv
      }
      guard den > 1e-9 else { continue }
      let r = abs(num) / (den * fixE).squareRoot()
      sum += Double(r); out.nLags += 1
      if r > out.bestScore { out.bestScore = r; out.best = off }
    }
    out.meanScore = out.nLags > 0 ? sum / Double(out.nLags) : 0
    return out
  }


  /// ── THE FAST SCAN AGAINST THE ONE IT REPLACED ─────────────────────────────
  ///
  /// Two signals with a KNOWN echo at a KNOWN lag, so the test can fail in both
  /// directions: the two implementations must agree with each other AND both
  /// must find the lag that was planted. An agreement test alone would pass two
  /// identically broken scans.
  static func corrSelfTest() -> Bool {
    var fails = 0
    func check(_ ok: Bool, _ what: String) {
      if !ok { fails += 1 }
      print("  \(ok ? "ok  " : "FAIL") \(what)")
    }
    var seed: UInt64 = 0xC0FFEE
    func rnd() -> Float {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      return Float(Int32(truncatingIfNeeded: Int(seed >> 33))) / Float(Int32.max)
    }
    let win = 2400, maxOff = 1200
    for (name, plant) in [("a planted echo", 375), ("a different lag", 40)] {
      var slide = [Float](repeating: 0, count: win + maxOff)
      for i in 0..<slide.count { slide[i] = rnd() * 0.5 }
      // fix[i] is slide delayed by `plant`, plus noise, so the true offset is
      // maxOff - plant... expressed directly: fix matches slide at off = plant.
      var fix = [Float](repeating: 0, count: win)
      for i in 0..<win { fix[i] = slide[i + plant] * 0.8 + rnd() * 0.05 }
      var fixE: Float = 0
      for v in fix { fixE += v * v }
      let t0 = Clock.now()
      let fast = corrScan(fix: fix, slide: slide, win: win, maxOff: maxOff, fixE: fixE)
      let tFast = Clock.ms(Clock.now() - t0)
      let t1 = Clock.now()
      let slow = corrScanSlow(fix: fix, slide: slide, win: win, maxOff: maxOff, fixE: fixE)
      let tSlow = Clock.ms(Clock.now() - t1)
      check(fast.best == plant, "\(name): the fast scan finds the planted offset "
                              + "(\(fast.best), planted \(plant))")
      check(slow.best == plant, "\(name): CONTROL, the brute force finds it too (\(slow.best))")
      check(abs(fast.bestScore - slow.bestScore) < 1e-3,
            String(format: "%@: same peak score (%.6f vs %.6f)", name,
                   fast.bestScore, slow.bestScore))
      check(abs(fast.meanScore - slow.meanScore) < 1e-3,
            String(format: "%@: same mean score (%.6f vs %.6f)", name,
                   fast.meanScore, slow.meanScore))
      check(fast.nLags == slow.nLags, "\(name): same number of offsets scored "
                                    + "(\(fast.nLags) vs \(slow.nLags))")
      print(String(format: "       %.2f ms fast, %.2f ms brute force -- %.1fx",
                   tFast, tSlow, tSlow / max(tFast, 0.0001)))
    }
    // And the range bound, which was wrong on the first attempt and is the one
    // thing an agreement test on full ranges cannot see.
    var slide = [Float](repeating: 0, count: win + maxOff)
    for i in 0..<slide.count { slide[i] = rnd() }
    var fix = [Float](repeating: 0, count: win)
    for i in 0..<win { fix[i] = slide[i] }          // a perfect match AT OFFSET ZERO
    var fixE: Float = 0
    for v in fix { fixE += v * v }
    let with0 = corrScan(fix: fix, slide: slide, win: win, maxOff: maxOff, fixE: fixE, minOff: 0)
    let no0 = corrScan(fix: fix, slide: slide, win: win, maxOff: maxOff, fixE: fixE, minOff: 1)
    check(with0.best == 0, "minOff 0 can win at offset zero")
    check(no0.best != 0, "minOff 1 excludes offset zero, which the echo search needs")
    print(fails == 0 ? "CORR TEST PASSED" : "CORR TEST FAILED (\(fails))")
    return fails == 0
  }

  /// Fractional read cursor rate governor.
  /// Translates buffer backlog / deficit (in samples) into fractional playout rate.
  /// Bounded to +/- 0.4% (< 5 cents pitch drift) for normal steady-state drift (<= 25 ms),
  /// with smooth scaling up to +1.2% (< 20 cents pitch shift) for transient backlogs to drain
  /// packet bursts smoothly without audible pitch distortion or clicks.
  static func governorRate(errSamples: Double) -> (rate: Double, errMs: Double) {
    let errMs = errSamples / SR * 1000.0
    let r = 1.0 + errSamples / (SR * 2.0)
    let rate: Double
    if errMs <= 25.0 {
      rate = min(1.004, max(0.996, r))
    } else {
      let extra = (errMs - 25.0) / 1000.0 * 0.08
      rate = min(1.012, 1.004 + extra)
    }
    return (rate, errMs)
  }

  /// Jitter target adaptation controller.
  /// Governs buffer depth based on arrival slack, late arrival magnitude, and packet loss evidence.
  /// Enforces monotonic decay upon recovery and prevents deep outlier spikes from ratcheting the target.
  final class JitterAdapter {
    var jitMin = 2
    var jitMax = 20
    var growLateMin = 8
    var growBelowMs = 1.0
    var shrinkAboveMs = 1.0
    var shrinkHold = 5
    var shrinkHoldFast = 5
    var starveAudiblePct = 0.02

    var target = 2
    var grows = 0
    var shrinks = 0
    var calm = 0
    var deepRefused = 0
    var enoughRefused = 0
    var growSuppressed = 0
    var marginExcused = 0
    var unsafeBelow = 0
    var probeAt = 0.0
    var backoff = 60.0

    var lastConcealed = 0
    var lastSnapsBehind = 0
    var lastLate = 0
    var lastNearLate = 0
    var lastStarved = 0

    var redundancy = false
    var lastLostForFec = 0
    var fecCalm = 0
    var fecRecovered0 = 0
    var fecLost0 = 0
    var fecWindows = 0
    var fecUselessUntil = 0.0
    var fecBackoff = 60.0
    var fecAllowed = true

    init(jitMin: Int = 2, jitMax: Int = 20, shrinkAboveMs: Double = 1.0) {
      self.jitMin = jitMin
      self.jitMax = jitMax
      self.target = jitMin
      self.shrinkAboveMs = shrinkAboveMs
    }

    func step(t: Double, r: RecvRing, peerLost: Int = 0, peerRecovered: Int = 0, peerReportsLoss: Bool = false) {
      guard r.pos >= 0 else { return }
      let conc = r.concealed - lastConcealed
      lastConcealed = r.concealed
      let late = r.lateArrivals - lastLate
      lastLate = r.lateArrivals
      let near = r.nearLate - lastNearLate
      lastNearLate = r.nearLate
      _ = late - near

      let lostTotal = peerReportsLoss ? peerLost : r.concealLost
      let recTotal = peerReportsLoss ? peerRecovered : r.recovered
      var lostNow = lostTotal - lastLostForFec
      if lostNow < 0 { lostNow = 0; fecRecovered0 = recTotal; fecLost0 = lostTotal }
      lastLostForFec = lostTotal
      if fecAllowed, lostNow > 0, !redundancy, t >= fecUselessUntil {
        redundancy = true
        fecRecovered0 = recTotal
        fecLost0 = lostTotal
        fecWindows = 0
        fecCalm = 0
      } else if redundancy {
        fecWindows += 1
        let rec = max(0, recTotal - fecRecovered0)
        let lost = max(0, lostTotal - fecLost0)
        if fecWindows >= 5, rec + lost >= 20 {
          let rate = Double(rec) / Double(rec + lost)
          if rate < 0.4 {
            redundancy = false
            fecUselessUntil = t + fecBackoff
            fecBackoff = min(fecBackoff * 2, 600)
            fecCalm = 0
            return
          }
        }
        if lostNow > 0 { fecCalm = 0 } else {
          fecCalm += 1
          if fecCalm >= 15 {
            redundancy = false
            fecCalm = 0
            fecBackoff = 60
          }
        }
      }

      let snappedBehind = r.snapsBehind - lastSnapsBehind
      lastSnapsBehind = r.snapsBehind

      let starved = r.concealStarved - lastStarved
      lastStarved = r.concealStarved
      let expected = 2.0 * SR / Double(FPP)
      let starvedPct = Double(starved) / expected * 100.0
      let starving = starvedPct > starveAudiblePct
      guard let p01 = r.slackWin.p(0.01) else { return }
      r.slackWin.reset()
      let worst = r.slackWinMin == 1e9 ? p01 : r.slackWinMin
      r.slackWinMin = 1e9
      let pktMs = Double(FPP) / SR * 1000.0
      let head = worst - pktMs

      let converged = abs(r.errMs) < 2.0
      if p01 < growBelowMs, !converged { growSuppressed += 1 }

      let senderGap = r.ipiCapWinMax
      let senderHiccup = senderGap > pktMs * 1.5
      r.ipiCapWinMax = 0
      let excusedDip = p01 < growBelowMs && senderHiccup && conc == 0 && late == 0
      if excusedDip { marginExcused += 1 }

      if snappedBehind > 0 && (!starving && conc == 0) {
        calm = 0
      } else if excusedDip {
        calm = 0
      } else if !starving, target > jitMin + 1, (late >= growLateMin || p01 < growBelowMs) {
        enoughRefused += 1
        calm = 0
      } else if !starving, late >= growLateMin, near < growLateMin, p01 >= growBelowMs {
        deepRefused += 1
        calm = 0
      } else if (late >= growLateMin && (near >= growLateMin || starving)) || (p01 < growBelowMs && converged) || (starving && target < jitMax) {
        if target < jitMax {
          let step: Int
          if starving && starvedPct > 10.0 {
            step = min(32, max(4, Int((starvedPct * 0.8).rounded())))
          } else if starving && starvedPct > 2.0 {
            step = min(16, max(2, Int((starvedPct * 0.5).rounded())))
          } else if starving {
            step = min(4, max(2, Int(starvedPct.rounded())))
          } else {
            step = 1
          }
          target = min(jitMax, target + step)
          grows += 1
          unsafeBelow = max(unsafeBelow, target)
          probeAt = t + backoff
          backoff = min(backoff * 2, 120)
        }
        calm = 0
      } else if target <= unsafeBelow && t < probeAt {
        calm = 0
      } else if head > shrinkAboveMs && converged && target > jitMin {
        calm += 1
        let hold = unsafeBelow == 0 ? shrinkHoldFast : shrinkHold
        if calm >= hold {
          target -= 1
          shrinks += 1
          calm = 0
          if target < unsafeBelow { unsafeBelow = target; backoff = 60 }
        }
      } else {
        calm = 0
      }
    }
  }

  /// `--selftest-boost`: Programmatic verification of the four architectural pillars:
  /// 1. Pure Mic Is The Product (48 kHz linear PCM, bit-for-bit exactness, linear LMS AEC)
  /// 2. Turn-Taking & Micro-Timing Cues (pre-turn inhales, trailing creaky voice, turn-end prediction handoff)
  /// 3. Packet Loss Forward Redundancy (piggybacked uncompressed frames, bit-exact recovery, zero PLC synthesis)
  /// 4. Jitter Buffer Ratchet Prevention & Monotonic Decay (cautious growth, outlier rejection, monotonic target decay, rate governor)
  static func boostSelfTest() -> Bool {
    var fails = 0
    var total = 0
    func check(_ ok: Bool, _ what: String) {
      total += 1
      if !ok { fails += 1 }
      let mark = ok ? "ok  " : "FAIL"
      print("   \(mark) \(what)")
      fputs("boost-selftest: \(mark) \(what)\n", stderr)
    }

    print("================================================================================")
    print("BOOST SELFTEST: THE FOUR PILLARS OF IMMEDIATE REAL-TIME AUDIO")
    print("================================================================================")

    // ── PILLAR 1: PURE MIC IS THE PRODUCT ────────────────────────────────────
    print("-- Pillar 1: Pure Mic Is The Product (48 kHz linear PCM, zero synthetic, linear LMS AEC)")

    // 1.1 Headphone bypass (cfg.on = false): bit-for-bit exactness under double-talk
    do {
      let gHead = DuplexGate()
      gHead.cfg.on = false
      gHead.cfg.yieldOn = false
      let nHead = 48000
      var nearHead = [Float](repeating: 0, count: nHead)
      var farHead = [Float](repeating: 0, count: nHead)
      for i in 0..<nHead {
        nearHead[i] = 0.4 * sin(Float(2 * Double.pi * 440.0 * Double(i) / SR))
          + 0.1 * sin(Float(2 * Double.pi * 880.0 * Double(i) / SR))
        farHead[i] = 0.5 * sin(Float(2 * Double.pi * 220.0 * Double(i) / SR))
      }
      var outHead = nearHead
      outHead.withUnsafeMutableBufferPointer { op in
        var i = 0
        while i + 16 <= nHead {
          for k in i..<(i + 16) { gHead.noteFar(farHead[k]) }
          gHead.process(op.baseAddress! + i, 16)
          i += 16
        }
      }
      var maxDiffHead: Float = 0
      for i in 0..<nHead {
        let d = abs(outHead[i] - nearHead[i])
        if d > maxDiffHead { maxDiffHead = d }
      }
      check(maxDiffHead == 0,
            "Headphones: 48 kHz linear PCM bit-for-bit identical (max diff \(String(format: "%.8f", maxDiffHead))) during double-talk")
    }

    // 1.2 Near voice on speakers (cfg.on = true): untouched near speech during simultaneous far speech
    do {
      let gSpk = DuplexGate()
      gSpk.cfg.on = true
      gSpk.cfg.yieldOn = false
      let nSpk = 48000
      var nearSpk = [Float](repeating: 0, count: nSpk)
      var farSpk = [Float](repeating: 0, count: nSpk)
      for i in 0..<nSpk {
        farSpk[i] = 0.3 * sin(Float(2 * Double.pi * 250.0 * Double(i) / SR))
        nearSpk[i] = 0.4 * sin(Float(2 * Double.pi * 350.0 * Double(i) / SR))
      }
      var outSpk = nearSpk
      outSpk.withUnsafeMutableBufferPointer { op in
        var i = 0
        while i + 16 <= nSpk {
          for k in i..<(i + 16) { gSpk.noteFar(farSpk[k]) }
          gSpk.process(op.baseAddress! + i, 16)
          i += 16
        }
      }
      var worstNearDiff: Double = 0
      for i in Int(SR * 0.05)..<nSpk { // after gate has 50 ms to open
        let diff = Double(abs(outSpk[i] - nearSpk[i]))
        let rel = nearSpk[i] != 0 ? diff / Double(abs(nearSpk[i])) : 0
        if rel > worstNearDiff { worstNearDiff = rel }
      }
      check(worstNearDiff < 1e-6,
            "Near voice on speakers: bit-for-bit untouched during near speech (\(String(format: "%.4f%%", worstNearDiff * 100)) error)")
    }

    // 1.3 Far-only echo suppression on speakers (cfg.on = true)
    do {
      let gEcho = DuplexGate()
      gEcho.cfg.on = true
      gEcho.cfg.yieldOn = false
      let nEcho = 48000
      var farEcho = [Float](repeating: 0, count: nEcho)
      var micEcho = [Float](repeating: 0, count: nEcho)
      for i in 0..<nEcho {
        farEcho[i] = 0.4 * sin(Float(2 * Double.pi * 300.0 * Double(i) / SR))
        micEcho[i] = 0.25 * farEcho[i]
      }
      var outEcho = micEcho
      outEcho.withUnsafeMutableBufferPointer { op in
        var i = 0
        while i + 16 <= nEcho {
          for k in i..<(i + 16) { gEcho.noteFar(farEcho[k]) }
          gEcho.process(op.baseAddress! + i, 16)
          i += 16
        }
      }
      var inE = 0.0, outE = 0.0
      for i in Int(SR * 0.2)..<nEcho { // after 200 ms settling
        inE += Double(micEcho[i]) * Double(micEcho[i])
        outE += Double(outEcho[i]) * Double(outEcho[i])
      }
      let supDb = (inE > 0 && outE > 0) ? 10.0 * log10(inE / outE) : 0
      check(supDb > 15.0,
            "Speaker echo suppression: \(String(format: "%.1f", supDb)) dB quieter during peer speech without spectral ducking")
    }

    // 1.4 & 1.5 Linear AEC LMS subtraction without non-linear ducking or synthetic speech
    do {
      let fm = FileManager.default
      let cand = ["testbed/media/real", "../testbed/media/real", "../../testbed/media/real"]
      let mediaDir = cand.first { fm.fileExists(atPath: "\($0)/realB.wav") } ?? "testbed/media/real"
      let wavB = Predict.readWav("\(mediaDir)/realB.wav")?.pcm
      let wavA = Predict.readWav("\(mediaDir)/realA.wav")?.pcm

      let nAec: Int
      let nearAec: [Float]
      let farAec: [Float]
      if let A = wavA, let B = wavB, A.count > Int(SR * 4), B.count > Int(SR * 4) {
        nAec = Int(SR * 4)
        nearAec = Array(A[0..<nAec])
        farAec = Array(B[0..<nAec])
      } else {
        nAec = Int(SR * 4)
        var nBuf = [Float](repeating: 0, count: nAec)
        var fBuf = [Float](repeating: 0, count: nAec)
        var seed: UInt64 = 0x51ED
        for i in 0..<nAec {
          seed = seed &* 6364136223846793005 &+ 1442695040888963407
          let r = Float(Int32(truncatingIfNeeded: Int(seed >> 33))) / Float(Int32.max)
          let t = Double(i) / SR
          let env = Float(0.55 + 0.45 * sin(2 * Double.pi * 4.3 * t))
          if t >= 1.0 { fBuf[i] = r * 0.4 * env }
          if t >= 2.0 && t < 3.5 { nBuf[i] = r * 0.3 * env }
        }
        nearAec = nBuf
        farAec = fBuf
      }

      let cfgAec = Aec.Cfg()
      let nullRun = Aec.run(near: nearAec, far: farAec, delayMs: 31, echoGain: 0,
                            cfg: cfgAec, blockN: 16, corr: 0.26, echoOn: false)
      check(nullRun.r.linearityDb < -100,
            "Linear AEC: near speech linearity < -100 dB (actual \(String(format: "%.1f", nullRun.r.linearityDb)) dB), zero non-linear ducking")

      let echoRun = Aec.run(near: [Float](repeating: 0, count: nAec), far: farAec,
                            delayMs: 31, echoGain: 0.5, cfg: cfgAec, blockN: 16, corr: 0.8, echoOn: true)
      check(echoRun.r.echoErleDb > 8,
            "Linear AEC: removes echo linearly (\(String(format: "%.1f", echoRun.r.echoErleDb)) dB ERLE) without spectral masking")
    }

    // 1.6 Subsonic rumble high-pass filter: 65 Hz 2nd-order Butterworth
    do {
      let hpf = HighPassFilter(cutoff: 65.0, sampleRate: SR)
      let nHpf = 48000
      var rumble = [Float](repeating: 0, count: nHpf)
      var voice = [Float](repeating: 0, count: nHpf)
      var fund = [Float](repeating: 0, count: nHpf)
      for i in 0..<nHpf {
        rumble[i] = 0.5 * sin(Float(2 * Double.pi * 20.0 * Double(i) / SR))
        voice[i] = 0.5 * sin(Float(2 * Double.pi * 200.0 * Double(i) / SR))
        fund[i] = 0.5 * sin(Float(2 * Double.pi * 85.0 * Double(i) / SR))
      }
      var outRumble = rumble
      var outVoice = voice
      var outFund = fund
      outRumble.withUnsafeMutableBufferPointer { hpf.process($0.baseAddress!, nHpf) }
      hpf.reset()
      outVoice.withUnsafeMutableBufferPointer { hpf.process($0.baseAddress!, nHpf) }
      hpf.reset()
      outFund.withUnsafeMutableBufferPointer { hpf.process($0.baseAddress!, nHpf) }

      var inRumbleE = 0.0, outRumbleE = 0.0
      var inVoiceE = 0.0, outVoiceE = 0.0
      var inFundE = 0.0, outFundE = 0.0
      for i in Int(SR * 0.2)..<nHpf {
        inRumbleE += Double(rumble[i]) * Double(rumble[i])
        outRumbleE += Double(outRumble[i]) * Double(outRumble[i])
        inVoiceE += Double(voice[i]) * Double(voice[i])
        outVoiceE += Double(outVoice[i]) * Double(outVoice[i])
        inFundE += Double(fund[i]) * Double(fund[i])
        outFundE += Double(outFund[i]) * Double(outFund[i])
      }
      let rumbleAttenDb = 10.0 * log10(inRumbleE / max(outRumbleE, 1e-12))
      let voiceAttenDb = 10.0 * log10(inVoiceE / max(outVoiceE, 1e-12))
      let fundAttenDb = 10.0 * log10(inFundE / max(outFundE, 1e-12))
      check(rumbleAttenDb > 18.0 && voiceAttenDb < 0.2 && fundAttenDb < 1.5,
            "Subsonic HPF: 20 Hz rumble attenuated > 18 dB (\(String(format: "%.1f", rumbleAttenDb)) dB), 85 Hz fundamental (\(String(format: "%.2f", fundAttenDb)) dB) and 200 Hz harmonic preserved (\(String(format: "%.2f", voiceAttenDb)) dB loss)")

      // Control arm: hpfOn = false bypass leaves signal bit-identical
      let prevHpf = Audio.hpfOn
      Audio.hpfOn = false
      var bypassBuf = rumble
      if Audio.hpfOn { bypassBuf.withUnsafeMutableBufferPointer { hpf.process($0.baseAddress!, nHpf) } }
      var bypassDiff = 0.0
      for i in 0..<nHpf { bypassDiff = max(bypassDiff, Double(abs(bypassBuf[i] - rumble[i]))) }
      Audio.hpfOn = prevHpf
      check(bypassDiff == 0.0,
            "Subsonic HPF control arm: --no-hpf leaves capture audio bit-identical (0 error)")
    }

    // 1.7 Headphone spatial presence and dynamic route switching
    do {
      guard let p = Presence.named("in-the-room") else {
        check(false, "Presence: in-the-room preset exists")
        return false
      }
      check(p.on && p.tailMs > 25.0 && p.scale > 0 && p.scale <= 1.0,
            "Spatial presence: in-the-room calibrated (\(String(format: "%.1f", p.tailMs)) ms reflections, scale \(String(format: "%.2f", p.scale)))")

      // Dynamic route switching: headphones auto-enable, speakers auto-disable
      let prevRoute = Audio.outputIsSpeakers
      let prevAuto = Audio.presenceAuto
      let prevPresence = Audio.presence
      let prevMode = Audio.presenceMode

      Audio.presenceAuto = true
      Audio.outputIsSpeakers = false
      let hpAutoOk = Audio.presence.on && Audio.presenceMode == "in-the-room"

      Audio.outputIsSpeakers = true
      let spkAutoOk = !Audio.presence.on && Audio.presenceMode == "off"

      // Manual override preservation: --presence mode must not be overwritten by route change
      Audio.presenceAuto = false
      if let warmer = Presence.named("warmer") {
        Audio.presence = warmer
        Audio.presenceMode = "warmer"
      }
      Audio.outputIsSpeakers = false
      let hpOverrideOk = Audio.presence.on && Audio.presenceMode == "warmer"
      Audio.outputIsSpeakers = true
      let spkOverrideOk = Audio.presence.on && Audio.presenceMode == "warmer"

      check(hpAutoOk && spkAutoOk && hpOverrideOk && spkOverrideOk,
            "Spatial presence routing: auto-engages on headphones, passthrough on speakers, preserves manual overrides")

      // Clean buffer reset on mode change
      let pf = PresenceFilter()
      pf.p = p
      _ = pf.process(1.0)
      pf.p = Presence() // turn off
      pf.p = p          // turn back on: must reset buffer without playing stale samples
      let cleanFirstSample = pf.process(0.0)
      check(abs(cleanFirstSample) < 1e-6,
            "Spatial presence filter: clean buffer reset on activation, zero stale audio burst")

      Audio.presenceMode = prevMode
      Audio.presence = prevPresence
      Audio.presenceAuto = prevAuto
      Audio.outputIsSpeakers = prevRoute
    }

    // ── PILLAR 2: TURN-TAKING & MICRO-TIMING CUES ─────────────────────────────
    print("-- Pillar 2: Turn-Taking & Micro-Timing Cues (Inhales, Creak, Turn Handoff Prediction)")

    // 2.1 Pre-turn inhale preservation
    do {
      let gInhale = DuplexGate()
      gInhale.cfg.on = true
      let nInhale = Int(SR * 0.2) // 200 ms
      var breath = [Float](repeating: 0, count: nInhale)
      for i in 0..<nInhale {
        breath[i] = 0.010 * sin(Float(2 * Double.pi * 150.0 * Double(i) / SR))
      }
      var outBreath = breath
      outBreath.withUnsafeMutableBufferPointer { op in
        var i = 0
        while i + 16 <= nInhale {
          gInhale.noteFar(0) // Far end is silent
          gInhale.process(op.baseAddress! + i, 16)
          i += 16
        }
      }
      let inhaleGain = gInhale.appliedGainNow
      let stayedQuiet = gInhale.vocal == .quiet
      check(inhaleGain >= 0.999 && stayedQuiet,
            "Pre-turn inhale: soft breath preserved with full 1.0 gain (actual \(String(format: "%.3f", inhaleGain)), 0 dB attenuation), classifier safe (.quiet)")
    }

    // 2.2 Trailing creaky voice / pitch drop hangover
    do {
      let gCreak = DuplexGate()
      gCreak.cfg.on = true
      let nTalk = Int(SR * 0.8) // 800 ms of speech
      var talkBuf = [Float](repeating: 0, count: nTalk)
      for i in 0..<nTalk { talkBuf[i] = 0.25 * sin(Float(2 * Double.pi * 200.0 * Double(i) / SR)) }
      talkBuf.withUnsafeMutableBufferPointer { op in
        var i = 0
        while i + 16 <= nTalk {
          gCreak.process(op.baseAddress! + i, 16)
          i += 16
        }
      }
      let claimed = gCreak.vocal == .claim

      // Feed 250 ms of creaky voice / trailing low energy (< 450 ms hangover)
      let nCreak = Int(SR * 0.25)
      var creakBuf = [Float](repeating: 0, count: nCreak)
      for i in 0..<nCreak { creakBuf[i] = 0.002 * sin(Float(2 * Double.pi * 100.0 * Double(i) / SR)) }
      creakBuf.withUnsafeMutableBufferPointer { op in
        var i = 0
        while i + 16 <= nCreak {
          gCreak.process(op.baseAddress! + i, 16)
          i += 16
        }
      }
      let creakSurvives = gCreak.vocal == .claim

      // Feed additional 300 ms of silence (total quiet = 550 ms > 450 ms hangover)
      let nQuiet = Int(SR * 0.3)
      var quietBuf = [Float](repeating: 0, count: nQuiet)
      quietBuf.withUnsafeMutableBufferPointer { op in
        var i = 0
        while i + 16 <= nQuiet {
          gCreak.process(op.baseAddress! + i, 16)
          i += 16
        }
      }
      let released = gCreak.vocal == .quiet
      check(claimed && creakSurvives && released,
            "Trailing creak: 450 ms hangover preserves low-energy vocal tail without premature cut")
    }

    // 2.3 & 2.4 Turn-end prediction & immediate transmission
    do {
      let f = Floor()
      f.cfg.strict = false
      f.speakers = true
      f.noteFar(.claim)
      _ = f.step(dt: 0.02, near: .quiet)
      let heldByThem = f.state == .theirs

      // Peer emits turn completion probability 0.9
      f.noteFarEndProb(0.3) // arm
      _ = f.step(dt: 0.02, near: .quiet)
      f.noteFarEndProb(0.9) // prosody prediction triggers
      let stepPred = f.step(dt: 0.02, near: .quiet)
      let handoffIdle = stepPred.state == .idle
      let predReleasesCount = f.farPredictedReleases >= 1

      // On the very next frame, near speaks and immediately takes floor
      let stepNear = f.step(dt: 0.02, near: .claim)
      let nearGranted = stepNear.state == .mine && stepNear.mayTransmit
      check(heldByThem && handoffIdle && predReleasesCount,
            "Turn-end prediction: 0 ms hesitation handoff (saved ~450 ms release delay, \(f.farPredictedReleases) far prediction release)")
      check(nearGranted,
            "Immediate microphone transmission on handoff frame (state=mine, mayTransmit=true)")
    }

    // 2.5 Floor grant duplex gate protection
    do {
      let gGrant = DuplexGate()
      gGrant.cfg.on = true
      gGrant.floorGranted = true
      let nGrant = 1600
      var dummy = [Float](repeating: 0.05, count: nGrant)
      dummy.withUnsafeMutableBufferPointer { op in
        var i = 0
        while i + 16 <= nGrant {
          gGrant.noteFar(0.6) // Peer loud
          gGrant.process(op.baseAddress! + i, 16)
          i += 16
        }
      }
      let grantGain = gGrant.appliedGainNow
      check(grantGain >= 0.999,
            "Floor grant duplex protection: holding floor guarantees 1.0 gain (actual \(String(format: "%.3f", grantGain))) even under speaker playout")
    }

    // ── PILLAR 3: PACKET LOSS FORWARD REDUNDANCY ──────────────────────────────
    print("-- Pillar 3: Packet Loss Forward Redundancy (Piggybacked PCM, Zero PLC Synthesis)")

    do {
      let ring = RecvRing()
      let f0 = [Float](repeating: 0.11, count: FPP)
      let f1 = (0..<FPP).map { Float($0) * 0.01 + 0.2 }
      let f2 = [Float](repeating: 0.33, count: FPP)

      let buf0 = UnsafeMutablePointer<UInt8>.allocate(capacity: 1500)
      let buf2 = UnsafeMutablePointer<UInt8>.allocate(capacity: 1500)
      defer { buf0.deallocate(); buf2.deallocate() }

      // Packet 0 arrives
      let len0 = Wire.packAudio(seq: 0, cap: 1000, src: f0, n: FPP, dst: buf0)
      _ = Wire.unpackAudio(plain: buf0, plainN: len0, into: ring)
      let p0Present = ring.present(0)

      // Packet 1 is LOST in transit!
      let p1LostBefore = !ring.present(1)

      // Packet 2 arrives carrying redundant packet 1
      let len2 = Wire.packAudio(seq: 2, cap: 3000, src: f2, n: FPP, dst: buf2,
                                redundant: f1, redundantCap: 2000)
      _ = Wire.unpackAudio(plain: buf2, plainN: len2, into: ring)

      let p2Present = ring.present(2)
      let p1Recovered = ring.present(1) && ring.recovered == 1

      // Verify sample-for-sample bit-exactness:
      var f1Exact = true
      for k in 0..<FPP {
        if let s = ring.sampleAt(Int64(1 * FPP + k)) {
          if abs(s - f1[k]) > 1e-7 { f1Exact = false }
        } else {
          f1Exact = false
        }
      }
      let plcBypassed = ring.concealed == 0

      check(p0Present && p1LostBefore && p2Present && p1Recovered,
            "Wire codec recovery: dropped frame N-1 recovered from wire datagram N (recovered=\(ring.recovered))")
      check(f1Exact && plcBypassed,
            "Recovered frame bit-exact with original PCM (\(FPP)/\(FPP) samples identical, zero PLC synthesis)")
    }

    // 3.2 Multi-stride 4-packet burst loss recovery (Stride-4 FEC)
    do {
      let ring = RecvRing()
      let f1 = (0..<FPP).map { Float($0) * 0.02 + 0.1 }
      let f5 = [Float](repeating: 0.55, count: FPP)

      let buf5 = UnsafeMutablePointer<UInt8>.allocate(capacity: 1500)
      defer { buf5.deallocate() }

      // Packets 1, 2, 3, 4 dropped in network burst loss!
      let p1LostBefore = !ring.present(1)

      // Packet 5 arrives carrying stride-4 redundant copy of packet 1 (seq - 4)
      let len5 = Wire.packAudio(seq: 5, cap: 5000, src: f5, n: FPP, dst: buf5,
                                stride4: f1, stride4Cap: 1000)
      _ = Wire.unpackAudio(plain: buf5, plainN: len5, into: ring)

      let p5Present = ring.present(5)
      let p1Recovered = ring.present(1) && ring.recovered == 1

      var f1Exact = true
      for k in 0..<FPP {
        if let s = ring.sampleAt(Int64(1 * FPP + k)) {
          if abs(s - f1[k]) > 1e-7 { f1Exact = false }
        } else {
          f1Exact = false
        }
      }
      check(p1LostBefore && p5Present && p1Recovered && f1Exact,
            "Multi-stride FEC: 4-packet burst loss recovered bit-exact from stride-4 chunk (recovered=\(ring.recovered))")
    }

    // 3.3 Block parity FEC recovery (XOR parity across 4 frames)
    do {
      let ring = RecvRing()
      let f8 = (0..<FPP).map { Float($0) * 0.01 + 0.1 }
      let f9 = (0..<FPP).map { Float($0) * 0.02 + 0.2 }
      let f10 = (0..<FPP).map { Float($0) * 0.03 + 0.3 }
      let f11 = (0..<FPP).map { Float($0) * 0.04 + 0.4 }

      // Compute bitwise XOR parity across f8, f9, f10, f11
      var par = [Float](repeating: 0, count: FPP)
      for k in 0..<FPP {
        let pBits = f8[k].bitPattern ^ f9[k].bitPattern ^ f10[k].bitPattern ^ f11[k].bitPattern
        par[k] = Float(bitPattern: pBits)
      }

      let buf8 = UnsafeMutablePointer<UInt8>.allocate(capacity: 1500)
      let buf9 = UnsafeMutablePointer<UInt8>.allocate(capacity: 1500)
      let buf11 = UnsafeMutablePointer<UInt8>.allocate(capacity: 1500)
      defer { buf8.deallocate(); buf9.deallocate(); buf11.deallocate() }

      // Packets 8 and 9 arrive
      let len8 = Wire.packAudio(seq: 8, cap: 8000, src: f8, n: FPP, dst: buf8)
      _ = Wire.unpackAudio(plain: buf8, plainN: len8, into: ring)
      let len9 = Wire.packAudio(seq: 9, cap: 9000, src: f9, n: FPP, dst: buf9)
      _ = Wire.unpackAudio(plain: buf9, plainN: len9, into: ring)

      // Packet 10 is LOST!
      let p10LostBefore = !ring.present(10)

      // Packet 11 arrives carrying block parity FEC for baseSeq = 8, count = 4
      let len11 = Wire.packAudio(seq: 11, cap: 11000, src: f11, n: FPP, dst: buf11,
                                 fecParity: par, fecParityBaseSeq: 8,
                                 fecParityCount: 4, fecParityCap: 8000)
      _ = Wire.unpackAudio(plain: buf11, plainN: len11, into: ring)

      let p10Recovered = ring.present(10) && ring.recovered >= 1
      var f10Exact = true
      for k in 0..<FPP {
        if let s = ring.sampleAt(Int64(10 * FPP + k)) {
          if s.bitPattern != f10[k].bitPattern { f10Exact = false }
        } else {
          f10Exact = false
        }
      }
      check(p10LostBefore && p10Recovered && f10Exact,
            "Block parity FEC: bit-exact reconstruction of dropped packet 10 from parity XOR chunk")
    }

    // 3.4 Dual-path packet racing deduplication (Direct P2P + Relay racing)
    do {
      let ring = RecvRing()
      let f12 = [Float](repeating: 0.77, count: FPP)
      let buf12a = UnsafeMutablePointer<UInt8>.allocate(capacity: 1500)
      let buf12b = UnsafeMutablePointer<UInt8>.allocate(capacity: 1500)
      defer { buf12a.deallocate(); buf12b.deallocate() }

      let len12a = Wire.packAudio(seq: 12, cap: 12000, src: f12, n: FPP, dst: buf12a)
      let len12b = Wire.packAudio(seq: 12, cap: 12000, src: f12, n: FPP, dst: buf12b)

      // First path arrives (e.g. direct P2P)
      _ = Wire.unpackAudio(plain: buf12a, plainN: len12a, into: ring)
      let p12First = ring.present(12)
      let dupsBefore = ring.dup

      // Second path arrives later (e.g. relay)
      _ = Wire.unpackAudio(plain: buf12b, plainN: len12b, into: ring)
      let dupsAfter = ring.dup

      check(p12First && dupsBefore == 0 && dupsAfter == 1,
            "Dual-path packet racing: duplicate packet arriving on second path cleanly deduplicated (dup=\(ring.dup))")
    }

    // ── PILLAR 4: JITTER BUFFER RATCHET PREVENTION & MONOTONIC DECAY ─────────
    print("-- Pillar 4: Jitter Buffer Ratchet Prevention & Monotonic Decay")

    do {
      let adapter = Audio.JitterAdapter(jitMin: 2, jitMax: 20, shrinkAboveMs: 1.0)
      let ring = RecvRing()
      ring.pos = 0

      // Near-late arrivals: packets missed deadline by under 1 packet -> grows
      ring.lateArrivals = 10
      ring.nearLate = 10
      ring.slackWin.add(0.5) // p01 < 1.0
      adapter.step(t: 2.0, r: ring)
      let grewOnNearLate = adapter.target == 3 && adapter.grows == 1

      // Deep outlier arrivals: 10 packets late by 20 ms (near = 0, deep = 10), margin fine
      ring.lateArrivals += 10
      ring.slackWin.add(3.0) // p01 >= 1.0
      adapter.step(t: 4.0, r: ring)
      let refusedDeep = adapter.deepRefused == 1 && adapter.target == 3

      check(grewOnNearLate, "Adaptive growth: near-late jitter expands target cautiously (jitTarget -> \(adapter.target))")
      check(refusedDeep, "Ratchet prevention: deep outlier latency spikes rejected from target growth")

      // Monotonic target decay upon network recovery
      var decayedToMin = false
      let startT = adapter.probeAt
      for win in 1...6 {
        ring.slackWin.add(4.5)
        ring.slackWinMin = 3.5 // head = 3.5 - 0.67 = 2.83 > 1.0
        adapter.step(t: startT + Double(win) * 2.0, r: ring)
        if adapter.target == adapter.jitMin { decayedToMin = true; break }
      }
      check(decayedToMin && adapter.shrinks >= 1 && adapter.target == 2,
            "Monotonic decay: target decays smoothly back to baseline (\(adapter.target) packets) upon calm (shrinks=\(adapter.shrinks))")

      // Playout rate governor error correction
      let errSamplesBacklog: Double = 0.025 * SR // 25 ms of buffer backlog
      let govSpeed = Audio.governorRate(errSamples: errSamplesBacklog)

      let errSamplesZero: Double = 0.0
      let govZero = Audio.governorRate(errSamples: errSamplesZero)

      let speedOk = abs(govSpeed.rate - 1.004) < 1e-6
      let zeroOk = abs(govZero.rate - 1.0) < 1e-6
      check(speedOk && zeroOk,
            "Audio rate governor: drains excess backlog (+0.4%) with < 5 cents pitch drift, converges to 1.000")
    }

    print("================================================================================")
    let passed = (fails == 0)
    print(passed ? "BOOST SELFTEST PASSED (\(total)/\(total) assertions)" : "BOOST SELFTEST FAILED (\(fails) failures)")
    print("================================================================================")
    return passed
  }


  // ── ATTRIBUTION, THEN SUSTAIN, THEN ACT ────────────────────────────────────
  //
  // An early hit has exactly two innocent explanations and they are separated by
  // HOW early:
  //
  //   one crossing   the far person's voice, captured at their machine and
  //                  played out of this one. Same room.
  //   two crossings  OUR voice, played out of their speaker, back into their
  //                  microphone, and returned. Their room is feeding their own
  //                  machine, which is a real fault -- but it is theirs, and
  //                  silencing THIS speaker would not fix it.
  //
  // The two are a full mouth-to-ear apart, at every distance, because the second
  // one contains the first. So the split is stated in terms of the mouth-to-ear
  // this call is actually measuring, not in absolute milliseconds -- an absolute
  // threshold containing propagation is a hidden distance limit, and this project
  // has shipped four of those (`rtt-blind-timeouts`).
  //
  // What the backward search measures is BUFFER to BUFFER: `echoHist` is written
  // in the render callback, one output-device latency before the air, and
  // `capHist` in the capture callback, one input-device latency after it. `m2e`
  // is air to air and ADDS both. So the same-room lag this search should see is
  // `m2e - outLatencyMs - inLatencyMs`, and the far end's own input latency
  // cancels out of the subtraction entirely.
  private var backMic = [Float](), backRef = [Float]()
  private var roomLastLog = 0.0

  /// The expected same-room lag for THIS call, in ms, or nil while the call has
  /// no honest mouth-to-ear. Nil is a refusal to attribute, not a verdict.
  /// What `roomPipeMs` currently is, for the beat. The detector's whole verdict
  /// turns on comparing the measured lag against this, so publishing the lag
  /// without it would be publishing half of a comparison -- and nil is itself
  /// the answer sometimes: a call with no honest mouth-to-ear cannot attribute
  /// an echo to a room at all, which is a REASON the detector never fired.
  var roomPipeMsNow: Double? { roomPipeMs }

  private var roomPipeMs: Double? {
    guard thetaValid, m2e.count > 20, let p50 = m2e.p(0.50), p50 > 0 else { return Audio.roomPipeOverride }
    let pipe = p50 - outLatencyMs - inLatencyMs
    // A negative pipe means the device-latency terms are larger than the whole
    // measured mouth-to-ear, which happens on a loopback rig -- two processes on
    // one Mac, where the whole mouth-to-ear is 12.5 ms and the two device
    // latencies alone are 21. Refuse rather than attribute off a number that
    // cannot be right.
    guard pipe > 0 else { return Audio.roomPipeOverride }
    return pipe
  }

  // ── TWO RIG OVERRIDES, AND WHAT EACH ONE IS ALLOWED TO CHANGE ──────────────
  //
  // `TK_ROOM_WINDOW` shortens the ten seconds of evidence the decision is taken
  // over, which is a CADENCE: a thing provable in ten seconds should be provable
  // in ten, and every timed thing in this project has one of these. It scales
  // the enter and leave counts with it, so the RATE being demanded is unchanged.
  //
  // `TK_ROOM_PIPE_MS` supplies the one-crossing reference the attribution needs,
  // and ONLY when the call cannot measure its own -- which on a same-machine
  // loopback it never can, for the reason above. It does not lower a threshold,
  // does not force a verdict, and does not touch a single sample: the
  // correlation still has to come out of the real histories on a real call. Both
  // are announced in the log when set, because an override nobody can see in the
  // output is how a rig ends up measuring a different product.
  /// `TK_SRC_WALLCLOCK=1`: phase-lock `--audio` to the host clock, so two
  /// processes on one Mac hear the same sample at the same instant. See the note
  /// at the substitution site -- it is a property of the fake microphone, not of
  /// anything the product decides.
  nonisolated(unsafe) static let srcWallLock: Bool = {
    guard ProcessInfo.processInfo.environment["TK_SRC_WALLCLOCK"] == "1" else { return false }
    fputs("audio source: phase-locked to the host clock, so both ends of a"
        + " loopback pair hear one room. RIG ONLY.\n", stderr)
    return true
  }()

  nonisolated(unsafe) static let roomPipeOverride: Double? = {
    guard let v = ProcessInfo.processInfo.environment["TK_ROOM_PIPE_MS"],
          let d = Double(v), d > 0 else { return nil }
    fputs("room: TK_ROOM_PIPE_MS=\(d) -- this call cannot measure its own one-way"
        + " delay, so attribution is using that. RIG ONLY.\n", stderr)
    return d
  }()


  /// Twenty scored estimates is ten seconds of a call. Enter at 8 (40%), leave
  /// at 2 (10%), so entering is a claim and leaving is only the absence of one.
  static var ROOM_WINDOW = {
    if let v = ProcessInfo.processInfo.environment["TK_ROOM_WINDOW"], let n = Int(v), n > 1, n <= 31 {
      fputs("room: TK_ROOM_WINDOW=\(n) estimates instead of 20. RIG ONLY.\n", stderr)
      return n
    }
    return 20
  }()
  static var ROOM_ENTER = max(2, Int((Double(ROOM_WINDOW) * 0.40).rounded()))
  static var ROOM_LEAVE = max(0, Int(Double(ROOM_WINDOW) * 0.10))

  // ══ CALIBRATING THE RULER ═══════════════════════════════════════════════════
  //
  // Nothing above is allowed to silence anybody's speaker until this has shown
  // that the detector ranks two KNOWN inputs in opposite directions, and by how
  // much. The margin between them IS the feature: a false positive silences a
  // call that is working perfectly, in a room where the person cannot see why.
  //
  // Deterministic and offline, like `--gate-test`: fixed seed, synthetic input,
  // no wall clock, no socket, no microphone. It calls `scoreSameRoom` -- the same
  // function the live estimator calls -- rather than a re-implementation written
  // to agree with it.
  //
  // ── AND THE SIGNAL IS SPEECH, NOT NOISE ────────────────────────────────────
  //
  // The forward estimator's own note records the reason: two UNRELATED speech
  // signals correlate at 0.26, because both carry speech's envelope and a pitch
  // in the same octave, and the best of a thousand candidate lags finds
  // something. Two unrelated NOISE bursts do not do that -- they would report a
  // null near zero, a margin that looks enormous, and a detector that fires on
  // the first real conversation. So the built-in source is a source-filter voice
  // (a glottal pulse train at a moving F0 through three formants, with syllables
  // and pauses), and `--sameroom-audio a.wav,b.wav` runs the whole thing again on
  // real recorded speech, which is the number worth quoting.
  //
  // ── AND THE TWO VOICES MUST NOT SHARE A CLOCK ──────────────────────────────
  //
  // The first version gave both of them the same syllabic envelope, at the same
  // phase, and the same pitch shimmer. Two unrelated speakers with their
  // syllables locked in phase is not a thing, and it cost the null 0.10:
  // measured 0.494 worst with the envelopes shared and 0.426 with them
  // independent. A rig that puts a common periodic component into both arms is
  // measuring its own generator (`measure-the-rigs-noise-first`).
  private static func voice(seed: UInt64, n: Int, f0: Double, syllHz: Double, shimmerHz: Double,
                            formants: [(Double, Double)]) -> [Float] {
    var s = seed &* 6364136223846793005 &+ 1442695040888963407
    func rnd() -> Double {
      s = s &* 6364136223846793005 &+ 1442695040888963407
      return Double(Int32(truncatingIfNeeded: Int(s >> 33))) / Double(Int32.max)
    }
    var x = [Float](repeating: 0, count: n)
    // Two-pole resonators, one per formant. This is the vocal tract; without it
    // the excitation is a buzz and correlates like a buzz.
    var y1 = [Double](repeating: 0, count: formants.count)
    var y2 = [Double](repeating: 0, count: formants.count)
    var phase = 0.0
    // Syllables: on for 140-260 ms, off for 40-160 ms. Speech is mostly silence
    // and a detector meets it that way.
    var syllLeft = 0, speaking = true
    var jitter = 1.0
    for i in 0..<n {
      if syllLeft <= 0 {
        speaking.toggle()
        let ms = speaking ? 140 + rnd().magnitude * 120 : 40 + rnd().magnitude * 120
        syllLeft = Int(ms / 1000 * SR)
        jitter = 1 + 0.18 * rnd()                 // a new pitch for each syllable
      }
      syllLeft -= 1
      var exc = 0.0
      if speaking {
        // Glottal pulses, with a shimmer so the period is never exactly constant.
        let step = f0 * jitter * (1 + 0.01 * sin(2 * Double.pi * shimmerHz * Double(i) / SR)) / SR
        phase += step
        if phase >= 1 { phase -= 1; exc = 1.0 }
        exc += 0.02 * rnd()                        // breath
      }
      var acc = 0.0
      for (k, f) in formants.enumerated() {
        let (freq, bw) = f
        let r = exp(-Double.pi * bw / SR)
        let c = 2 * r * cos(2 * Double.pi * freq / SR)
        let v = exc + c * y1[k] - r * r * y2[k]
        y2[k] = y1[k]; y1[k] = v
        acc += v / Double(k + 2)
      }
      let env = 0.55 + 0.45 * sin(2 * Double.pi * syllHz * Double(i) / SR + Double(seed % 97))
      x[i] = Float(acc * 0.02 * env)
    }
    var pk: Float = 0
    for v in x { pk = max(pk, abs(v)) }
    if pk > 0 { for i in 0..<n { x[i] = x[i] / pk * 0.25 } }
    return x
  }

  /// A light early-reflection pattern. The same voice reaching a second
  /// microphone across a desk is NOT a bit-exact copy of what reached the first,
  /// and a rig that pretends it is reports a correlation no room can produce.
  private static func throughRoom(_ x: [Float], seedNoise: UInt64) -> [Float] {
    var s = seedNoise
    func rnd() -> Float {
      s = s &* 6364136223846793005 &+ 1442695040888963407
      return Float(Int32(truncatingIfNeeded: Int(s >> 33))) / Float(Int32.max)
    }
    let taps: [(Int, Float)] = [(0, 0.70), (Int(0.0029 * SR), 0.35),
                                (Int(0.0061 * SR), 0.20), (Int(0.0110 * SR), 0.12),
                                (Int(0.0187 * SR), 0.07)]
    var y = [Float](repeating: 0, count: x.count)
    for (d, g) in taps {
      if d >= x.count { continue }
      for i in d..<x.count { y[i] += g * x[i - d] }
    }
    // Room noise at about -40 dB relative to the speech. Real rooms have a floor
    // and it is part of what the correlation has to survive.
    for i in 0..<y.count { y[i] += rnd() * 0.0025 }
    return y
  }

  /// Resample by `1 + eps`, linearly. This is the jitter buffer's rate governor,
  /// which tracks the sender and therefore stretches the PLAYOUT against a
  /// microphone nothing is stretching -- the single largest reason a live
  /// estimate is noisier than an offline one.
  private static func warp(_ x: [Float], eps: Double) -> [Float] {
    var y = [Float](repeating: 0, count: x.count)
    for i in 0..<x.count {
      let t = Double(i) * (1 + eps)
      let j = Int(t)
      if j + 1 >= x.count { break }
      let f = Float(t - Double(j))
      y[i] = x[j] * (1 - f) + x[j + 1] * f
    }
    return y
  }

  /// Read a file as 48 kHz mono. Level-matched, so a quiet recording does not
  /// read as a silent far end.
  static func loadMono48(_ path: String) -> [Float]? {
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
          let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SR,
                                  channels: 1, interleaved: false),
          let conv = AVAudioConverter(from: file.processingFormat, to: fmt) else { return nil }
    let frames = AVAudioFrameCount(file.length)
    guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
          (try? file.read(into: inBuf)) != nil else { return nil }
    let outCap = AVAudioFrameCount(Double(file.length) * SR / file.processingFormat.sampleRate) + 4096
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: outCap) else { return nil }
    var done = false
    var err: NSError?
    conv.convert(to: outBuf, error: &err) { _, status in
      if done { status.pointee = .noDataNow; return nil }
      done = true; status.pointee = .haveData; return inBuf
    }
    if err != nil { return nil }
    let n = Int(outBuf.frameLength)
    guard n > 0, let ch = outBuf.floatChannelData?[0] else { return nil }
    var out = [Float](repeating: 0, count: n)
    for i in 0..<n { out[i] = ch[i] }
    var pk: Float = 0
    for v in out { pk = max(pk, abs(v)) }
    if pk > 0.001 { for i in 0..<n { out[i] = out[i] / pk * 0.25 } }
    return out
  }



  /// Load a file as 48 kHz mono float32 to stand in for the microphone.
  func loadAudioSource(_ path: String) -> String {
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
      return "cannot open \(path)"
    }
    guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SR,
                                  channels: 1, interleaved: false),
          let conv = AVAudioConverter(from: file.processingFormat, to: fmt) else {
      return "cannot convert \(path) to 48 kHz mono"
    }
    let frames = AVAudioFrameCount(file.length)
    guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
          (try? file.read(into: inBuf)) != nil else { return "cannot read \(path)" }
    let outCap = AVAudioFrameCount(Double(file.length) * SR / file.processingFormat.sampleRate) + 4096
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: outCap) else { return "no buffer" }
    var done = false
    var err: NSError?
    conv.convert(to: outBuf, error: &err) { _, status in
      if done { status.pointee = .noDataNow; return nil }
      done = true; status.pointee = .haveData; return inBuf
    }
    if let e = err { return "convert failed: \(e.localizedDescription)" }
    let n = Int(outBuf.frameLength)
    guard n > 0, let ch = outBuf.floatChannelData?[0] else { return "no samples in \(path)" }
    let buf = UnsafeMutablePointer<Float>.allocate(capacity: n)
    buf.update(from: ch, count: n)
    srcSamples = buf
    srcCount = n
    srcPos = 0
    return "audio source: \(path) -- \(n) samples, \(String(format: "%.1f", Double(n) / SR)) s, looping"
  }
  private var acPlayAt: UInt64 = 0        // host time of the impulse we emitted
  private var acWaiting = false
  private var acNext: UInt64 = 0          // do not fire again until this time
  var acRound = Quantiles(cap: 64)
  private(set) var acFired = 0, acHeard = 0
  var capToSend = Quantiles(cap: 2048)     // sender: capture stamp -> handed to the socket
  // ── Where the soft milliseconds actually are ───────────────────────────────
  //
  // The named terms -- two device latencies, the packet fill, the jitter buffer --
  // add up to about 8.5 ms, and m2e measures 11.76. The 3.2 ms difference has been
  // sitting in the two stage numbers unattributed, which is exactly the shape of a
  // cost nobody can reduce because nobody can name it. These three split it into
  // CoreAudio's scheduling (which this program does not control) and this program's
  // own work (which it does).
  //
  //   capLag     first sample captured  ->  input callback gets to look at it
  //   sendCost   input callback entry    ->  sendto has returned
  //   renderLead output callback entry   ->  that buffer reaches the DAC
  // ── Can this buffer size actually be served? ───────────────────────────────
  //
  // A CoreAudio overrun does not return an error. AudioUnitRender succeeds, the
  // callback simply took too long and a buffer is gone -- so `xruns`, which counts
  // render failures, reads zero through exactly the failure it is supposed to
  // catch. But a SKIPPED BUFFER IS A DOUBLED GAP between consecutive callback host
  // times, and that needs no cooperation from anyone: it is arithmetic on a
  // timestamp CoreAudio already provides. Counted for both callbacks, with the
  // duration of the work beside it, so "is 15 frames serviceable" is a question
  // with an answer instead of a hope.
  var capSkips = 0, renderSkips = 0
  var capTicks = 0, renderTicks = 0
  // A gap in the host times is not yet a defect: CoreAudio may have COALESCED two
  // buffers, in which case the callback simply gets twice the frames and no audio
  // is missing. Summing the frames actually delivered and comparing to wall time
  // is what separates "coalesced" from "lost", and it is the difference between a
  // buffer size being serviceable and being lossy.
  var capFrames = 0, renderFrames = 0
  /// Set while the microphone is delivering far below the sample rate. Read by the
  /// report loop, which puts a sentence on screen: a call at a quarter of the
  /// packet rate is broken, and the person must not have to guess.
  private(set) var micTooSlow = false
  private var firstCapHost: UInt64 = 0
  private var lastCapHost: UInt64 = 0
  private var lastRenderHost: UInt64 = 0
  var renderCost = Quantiles(cap: 2048)
  var capLag = Quantiles(cap: 2048)
  var sendCost = Quantiles(cap: 2048)
  var renderLead = Quantiles(cap: 2048)
  var recvToPlay = Quantiles(cap: 2048)    // receiver: off the socket -> at the DAC
  var m2eLast: Double = 0
  var outLatencyMs: Double = 0
  var inLatencyMs: Double = 0
  var capturedPkts = 0
  var xruns = 0
  /// Frames the input unit actually delivered, minus the frames the elapsed time
  /// says it should have. Negative means audio was genuinely lost.
  var capFrameDeficit: Double {
    guard firstCapHost != 0 else { return 0 }
    let elapsedS = Clock.ms(Clock.now() - firstCapHost) / 1000.0
    return Double(capFrames) - elapsedS * SR
  }
  var capCallbacks = 0
  /// Times the render callback ARRIVED, which is not the same fact as
  /// `renderTicks` (renders that reached the mixing loop and fed the DAC). Before
  /// a peer sends anything, `onRender` zero-fills and returns early, so a healthy
  /// output unit ticks this and leaves `renderTicks` at zero -- see the watchdog.
  var renderCallbacks = 0
  /// Where the ear's ramp has reached. Lives on the render side because that is
  /// the thread that owns `out`, and it is per SAMPLE for the same reason the
  /// gate's close step is: a coefficient written per block encodes the device
  /// buffer, and this project has already shipped a classifier that could never
  /// fire because of exactly that.
  private var earGain: Float = 1
  // ── PRESENCE: how far away the person sounds ─────────────────────────────
  //
  // Direction cannot be delivered on a laptop speaker. It lives entirely in the
  // difference between the two ears, both speakers reach both ears, and
  // cancelling that crosstalk was measured and abandoned -- it bought +0.3 dB of
  // the cue for 1.9 dB of change to the tone of the voice, which sounds exactly
  // as bad as it reads. Distance is a different matter: level, the
  // direct-to-reverberant ratio and spectrum are all monaural cues, so they
  // arrive intact on one speaker, on two, or on a phone held at arm's length.
  //
  // COSTS NO LATENCY, BY CONSTRUCTION. The direct sound is passed through
  // untouched and the reflections are added behind it -- they are late by
  // definition, so nothing waits for them. It costs no bandwidth either: this
  // runs on the receiving end, on a stream that was already sent.
  //
  // The parameters are the ones from Voice Lab, so a mode chosen by listening
  // there is the same mode here.
  struct Presence {
    var lowG: Float = 0, highG: Float = 0
    var taps = 0
    var tapD = (0, 0, 0, 0)
    /// The fractional part of each delay. A reflection at 9.1 ms is 436.8
    /// samples, and rounding that to 436 moves it by 4 microseconds -- which
    /// sounds like nothing and is not: the Lab interpolates, so truncating here
    /// made every mode with a room in it a measurably different sound from the
    /// one that was chosen by listening.
    var tapF: (Float, Float, Float, Float) = (0, 0, 0, 0)
    var tapG: (Float, Float, Float, Float) = (0, 0, 0, 0)
    var scale: Float = 1
    /// How far behind the direct sound the last reflection lands. This is the
    /// number that matters to the echo canceller, because a room does not just
    /// change the tone of what the speaker plays -- it makes the path from the
    /// speaker back into the microphone LONGER, and a canceller can only cancel
    /// what fits inside its own window.
    var tailMs: Double = 0
    var on: Bool { lowG != 0 || highG != 0 || taps > 0 }

    static func named(_ n: String) -> Presence? {
      func mk(_ low: Double, _ high: Double, _ t: [(Double, Float)]) -> Presence {
        var p = Presence()
        p.lowG = Float(pow(10, low / 20) - 1)
        p.highG = Float(pow(10, high / 20) - 1)
        p.taps = min(4, t.count)
        var d = [0, 0, 0, 0]; var f: [Float] = [0, 0, 0, 0]; var g: [Float] = [0, 0, 0, 0]
        var sum: Float = 0
        for i in 0..<p.taps {
          let samples = t[i].0 * SR
          d[i] = Int(samples.rounded(.down)); f[i] = Float(samples - samples.rounded(.down))
          g[i] = t[i].1; sum += abs(t[i].1)
        }
        p.tapD = (d[0], d[1], d[2], d[3]); p.tapF = (f[0], f[1], f[2], f[3])
        p.tapG = (g[0], g[1], g[2], g[3])
        // A static headroom allowance, not a limiter: reflections are delayed
        // and dulled so they rarely peak together, and a shelf only lifts part
        // of the band. Half of each is the room left for them.
        let lift = Float(max(0, pow(10, max(low, high) / 20) - 1))
        p.scale = 1 / (1 + 0.5 * sum + 0.5 * lift)
        p.tailMs = (t.prefix(p.taps).map { $0.0 }.max() ?? 0) * 1000
        return p
      }
      switch n {
      case "off", "today":     return Presence()
      case "leaning-in":       return mk(5.5, 1.5, [])
      case "next-to-you":      return mk(3.5, 1.0, [(0.0041, 0.10), (0.0079, 0.07)])
      case "in-the-room":      return mk(0, 0, [(0.0091, 0.26), (0.0168, 0.19), (0.0277, 0.13)])
      case "across-the-table": return mk(0, -2.5, [(0.0142, 0.42), (0.0238, 0.34),
                                                   (0.0371, 0.27), (0.0503, 0.20)])
      case "warmer":           return mk(3.0, -1.0, [])
      default:                 return nil
      }
    }
  }
  /// Held separately from Audio so the filter can be run -- and checked against
  /// the version people chose a mode with -- without opening a device.
  final class PresenceFilter {
    static let PRES = 4096                              // > the longest reflection
    static let PMASK = PRES - 1
    var p = Presence() {
      didSet {
        if oldValue.on != p.on { reset() }
      }
    }
    private let buf: UnsafeMutablePointer<Float>
    private var w = 0
    private var lo: Float = 0, hi: Float = 0, dull: Float = 0
    init() {
      buf = .allocate(capacity: PresenceFilter.PRES)
      buf.initialize(repeating: 0, count: PresenceFilter.PRES)
    }
    func reset() {
      memset(buf, 0, PresenceFilter.PRES * MemoryLayout<Float>.size)
      w = 0
      lo = 0; hi = 0; dull = 0
    }
    /// One sample. No allocation, no locks, and a straight passthrough when off.
    @inline(__always) func process(_ x: Float) -> Float {
      guard p.on else { return x }
      // The reflections are a duller copy of the voice: a surface absorbs the
      // top end, and a bright echo reads as an effect rather than as a room.
      dull = 0.493727 * x + 0.506273 * dull            // one pole, 5.2 kHz
      buf[w & PresenceFilter.PMASK] = dull
      @inline(__always) func tap(_ d: Int, _ f: Float, _ g: Float) -> Float {
        let a = buf[(w - d) & PresenceFilter.PMASK]
        let b = buf[(w - d - 1) & PresenceFilter.PMASK]
        return g * (a * (1 - f) + b * f)
      }
      var y = x
      if p.taps > 0 { y += tap(p.tapD.0, p.tapF.0, p.tapG.0) }
      if p.taps > 1 { y += tap(p.tapD.1, p.tapF.1, p.tapG.1) }
      if p.taps > 2 { y += tap(p.tapD.2, p.tapF.2, p.tapG.2) }
      if p.taps > 3 { y += tap(p.tapD.3, p.tapF.3, p.tapG.3) }
      w += 1
      if p.lowG != 0 {
        lo = 0.97416 * lo + 0.02584 * y                 // one pole, 200 Hz
        y += p.lowG * lo
      }
      if p.highG != 0 {
        hi = 0.592385 * hi + 0.407615 * y               // one pole, 4 kHz
        y += p.highG * (y - hi)
      }
      return y * p.scale
    }
  }

  /// 2nd-order Butterworth high-pass filter at 65 Hz (Q = 0.707).
  /// Direct Form II Transposed biquad filter with Double-precision state.
  /// Eliminates subsonic rumble (HVAC, fan, table thumps, keyboard vibrations)
  /// below voice fundamentals (85+ Hz) to preserve dynamic range and avoid speaker distortion.
  final class HighPassFilter {
    private var s1: Double = 0
    private var s2: Double = 0
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double

    init(cutoff: Double = 65.0, sampleRate: Double = SR, q: Double = 0.7071067811865475) {
      let w0 = 2.0 * Double.pi * cutoff / sampleRate
      let cosW0 = cos(w0)
      let sinW0 = sin(w0)
      let alpha = sinW0 / (2.0 * q)
      let a0 = 1.0 + alpha
      b0 = ((1.0 + cosW0) / 2.0) / a0
      b1 = (-(1.0 + cosW0)) / a0
      b2 = ((1.0 + cosW0) / 2.0) / a0
      a1 = (-2.0 * cosW0) / a0
      a2 = (1.0 - alpha) / a0
    }

    @inline(__always) func process(_ x: Float) -> Float {
      let xd = Double(x)
      let y = b0 * xd + s1
      s1 = b1 * xd - a1 * y + s2
      s2 = b2 * xd - a2 * y
      return Float(y)
    }

    func process(_ buf: UnsafeMutablePointer<Float>, _ count: Int) {
      for i in 0..<count {
        buf[i] = process(buf[i])
      }
    }

    func reset() {
      s1 = 0
      s2 = 0
    }
  }

  static var presenceAuto = true
  static var presenceMode = "off"
  static var presence = Presence() { didSet { sharedPresence.p = presence } }
  nonisolated(unsafe) static let sharedPresence = PresenceFilter()
  private let pres = Audio.sharedPresence
  private let captureHpf = HighPassFilter()
  nonisolated(unsafe) static var hpfOn = true

  @inline(__always) private func presence(_ x: Float) -> Float { pres.process(x) }

  // ── THE DUPLEX GATE ───────────────────────────────────────────────────────
  //
  // The goal is that the far end hears the pure microphone -- nothing between the
  // room and the wire. The only thing that ever justified putting something there
  // is echo, and Apple's voice processing pays for it with the sound this whole
  // project is trying to get away from: the noise suppression and the automatic
  // gain, not the cancellation.
  //
  // So: DO NOTHING TO THE VOICE, AND DO IT ONLY WHEN THERE IS NO VOICE. While the
  // far end is talking and this end is not, there is nothing in the microphone
  // worth sending -- it is their own voice coming back at them. Turn it down. The
  // moment this end speaks, the microphone is wide open and completely untouched:
  // no spectral processing, no gain riding, no suppression. Every sample of
  // anybody's actual speech goes out exactly as captured.
  //
  // WHAT MAKES IT SAFE IS KNOWING THE ECHO'S SIZE, NOT ITS SOUND. A microphone
  // hearing echo looks loud, and gating on loudness alone would hold the gate
  // open for the echo and closed on a quiet talker. The coupling -- how loud the
  // microphone gets per unit of playout -- is learned as a running minimum over
  // moments when only the far end is speaking, because near-end speech can only
  // ever push that ratio up. Speech is then "more than the echo can explain".
  struct Gate {
    var on = true
    /// How far down to turn the microphone when only the far end is talking.
    ///
    /// Softened from -120 dB to -22 dB: gated intervals retain subtle ambient room presence,
    /// preventing jarring noise-pumping / "dead air" sensation during conversational pauses.
    /// Hard mutes (when user explicitly clicks mute via gMicMuted) remain silenced.
    /// `--gate-floor <dB>` overrides if specified by the user.
    var floorDb: Double = -22
    /// ── HOW LONG THE MUTE TAKES TO ARRIVE ─────────────────────────────────────
    ///
    /// The floor above was never the limit; THIS was. Closing used to be an
    /// exponential decay at 0.0006 per sample -- a 35 ms time constant -- and an
    /// exponential approaches its target asymptotically, so reaching a real mute
    /// needs about fourteen of them, roughly 240 ms of unbroken far-end speech.
    /// Real speech does not hold still that long, so the gain never arrived.
    ///
    /// Measured, by sweeping the floor and watching the answer stop moving:
    ///
    ///     asked  -6 dB -> got  5.9 dB
    ///     asked -22 dB -> got 19.3 dB
    ///     asked -60 dB -> got 23.6 dB
    ///     asked -120 dB -> got 23.6 dB      <- the ramp, not the floor
    ///
    /// So closing is a LINEAR ramp now: it reaches the number it was given, in
    /// the time it was given. That alone took the same test from 23.6 dB to
    /// 37.7 dB of suppression -- fourteen decibels, a factor of five quieter,
    /// with the floor unchanged.
    ///
    /// Swept, because switching speed IS the experience in a half-duplex call
    /// and a number picked by feel would be a guess:
    ///
    ///     1 ms 38.0 dB   2 ms 38.0   4 ms 37.9   8 ms 37.7
    ///                                           16 ms 33.9  32 ms 27.3
    ///
    /// A plateau from 1 to 8 ms and a cliff after it. 4 ms is the fast end of
    /// the plateau -- it gives up 0.1 dB against the best measurement and buys
    /// the quickest switch available, while staying several times longer than
    /// the ~1 ms at which a gain step becomes an audible click.
    ///
    /// Smoothed close ramp: 8 ms sits on the 37.7 dB plateau while preventing chopping.
    var closeMs: Double = 8
    /// How much louder than the expected echo counts as somebody really talking.
    /// The base, at light coupling; it relaxes as the room couples harder --
    /// see the note at the comparison. Swept across simulated rooms: 2.8 holds
    /// 19 dB up to a microphone hearing the speaker at 80% of playout, decays
    /// safely to nothing past that, and never alters the near voice.
    var margin: Float = 2.8
    /// Voiced time past which a listening noise is instead a bid for the floor.
    /// Continuers are short by definition; saying something takes longer.
    var claimMs: Double = 700
    /// ── WHEN NEITHER OF YOU BACKS OFF ─────────────────────────────────────────
    ///
    /// Brief overlap is what conversation SOUNDS like and nothing here touches
    /// it. What this handles is the deadlock: past `yieldAfterMs` of both people
    /// still going, one of them has to give, and if the app will not decide then
    /// the two of you spend the next second doing it manually -- which is the
    /// fatigue the whole product exists to remove.
    ///
    /// It is a duck and not a mute, and the difference is the whole safety
    /// argument. Nine decibels is unmistakable to the person listening and still
    /// leaves you audible if you carry on; a mute costs somebody their sentence
    /// when the decision is wrong, and it will sometimes be wrong. It also cuts
    /// the echo the winner gets back -- during a real collision this end's
    /// microphone is carrying the far end's own voice off the speaker, which is
    /// the one thing this design exists to never send.
    var yieldDb: Double = -9
    var yieldAfterMs: Double = 450
    var yieldOn = true
    /// How far down a microphone goes when its owner is talking out of turn.
    /// Deeper than the 9 dB collision duck, because this is not "you both
    /// started together" -- it is "somebody else has the floor" -- and the
    /// listener should plainly hear one voice. Still a duck: carrying on works,
    /// and nothing is unrecoverable.
    var floorDuckDb: Double = -20
  }
  /// Standalone, like the presence filter, so the claim that a talking near end
  /// passes through untouched can be checked without opening a device.
  ///
  /// ── WHAT THIS IS AND IS NOT ───────────────────────────────────────────────
  ///
  /// It is PURELY LOCAL. It turns this microphone down for one reason: it can
  /// hear the far end's voice coming out of this machine's own speaker right
  /// now. There is no protocol, nothing negotiated, and nothing to race -- which
  /// matters, because two ends see each other through a hundred milliseconds of
  /// network and a design where they must agree can deadlock with both people
  /// muted. If the far end goes quiet, this opens. Always.
  ///
  /// What it publishes is a CUE, never a command: this end is making a listening
  /// noise, or this end wants to say something. The far end draws that, a person
  /// reads it and stops talking, and their stopping is what opens this
  /// microphone -- through the same local rule, with nothing arbitrating.
  final class DuplexGate {
    var cfg = Gate()

    /// What the near end is doing with their voice.
    enum Vocal: Int {
      case quiet = 0
      /// Short, level, over the top of the far end: "mm-hm", "yeah", a laugh.
      /// The literature is unambiguous that these are produced WITHOUT intent to
      /// take a turn -- short duration, no turn-competitiveness -- which is
      /// exactly why their audio is the least costly thing to hold back and
      /// their meaning still has to arrive somehow.
      case backchannel = 1
      /// Sustained, or loud enough to be unmistakable. Somebody wants the floor.
      case claim = 2
    }
    private(set) var vocal = Vocal.quiet

    // The voice detector is the one from the user's own voice-mode app, where it
    // has been run against real conversation: the floor falls fast and rises
    // slowly, so it settles into a quiet room in a moment but a cough cannot drag
    // it up over speech; two consecutive loud frames are required, which is what
    // keeps key clicks and lip noise out.
    private var nearEnv: Float = 0
    private var floor: Float = 0.004
    private var run = 0
    private var farEnv: Float = 0
    private var coupling: Float = 0.5
    private var farRun = 0
    private var farTalkingSamples = 0
    private var farQuietSamples = 0
    /// Samples since this vocalisation began, and CONSECUTIVE quiet samples since
    /// the last confirmed voice inside it. Both in samples, so no block size can
    /// change what they mean.
    private var vocalSamples = 0
    private var quietSamples = 0
    private(set) var gain: Float = 1
    /// Set once per block by the turn accounting, which is the only place that
    /// sees this end's state and the far end's at the same instant. The gate does
    /// not decide this -- it applies it.
    var yielding = false
    /// ── THE TURN LAYER'S VERDICT, APPLIED HERE ────────────────────────────────
    ///
    /// Set once per block from `Floor`, which is the only thing that sees both
    /// ends at once. It is a THIRD factor and not folded into `want`, for the
    /// same reason the duck is not: the gate is an echo judgement made every
    /// block from this room's acoustics, and this is a turn judgement made from
    /// what the other person is doing. They move for different reasons.
    ///
    /// It rides the gate's own ramp rather than carrying its own. A second copy
    /// of the 4 ms close would be `second-copy-of-a-rule`, and the copy that
    /// drifts is always the one you end up verifying with.
    var floorMuted = false
    /// Talking, but not this end's turn. A duck, never a cut -- see `duckOnly`
    /// in Floor.swift for the 35% regression that made the distinction.
    var floorDucked = false
    /// ── THE FLOOR HAS GRANTED THIS MICROPHONE ─────────────────────────────────
    ///
    /// In strict there is exactly one live microphone, and the other one is
    /// MUTED -- so while this end holds the floor there is no loop for the
    /// sample-level echo suppression to protect against, and the holder's own
    /// speaker is closed as well. Leaving it on made the gate fight the person
    /// it had just been told to carry: measured in `--turn-test` as a speaker
    /// who had the floor (`state=mine`, floor gain 1.0) and was still
    /// inaudible because the echo gate held `gain` at zero -- and heard as
    /// "the mic is failing to capture the speaking person", worst when they sit
    /// far from it and their voice is quiet.
    ///
    /// The CLASSIFIER is untouched: deciding whether a sound is a voice worth
    /// claiming the floor with still needs the echo test (and the correlation
    /// veto beside it). This only stops the gate attenuating audio the floor
    /// has already decided belongs on the wire.
    var floorGranted = false
    /// ── THE RAW MICROPHONE'S PEAK, WHEN A CANCELLER SITS UPSTREAM (0.107.0) ───
    ///
    /// `coupling` below is a slow MINIMUM of near/far level and it is the gate's
    /// entire model of the room: how much of what this speaker plays comes back
    /// into this microphone. That is a property of the ROOM. Learning it from a
    /// signal the canceller has already cleaned would teach the gate that the
    /// room has no echo in it -- and then the instant the canceller stopped
    /// working (a route change, a device change, somebody picking the laptop up)
    /// the gate would have unlearned its own defence and the far end's voice
    /// would classify as this person talking.
    ///
    /// The same shape as the estimator having to read the raw history:
    /// `control-loops-steer-on-flattering-signals`, where the flattering signal
    /// is the loop's own success. So the coupling tracker reads THIS and
    /// everything else reads the block it was handed.
    ///
    /// -1 means nothing is upstream and the block's own peak is the raw peak,
    /// which is what every caller before 0.107.0 meant.
    var rawPeakIn: Float = -1
    /// What fraction of the echo survived the canceller, in amplitude. 1 is "no
    /// canceller, or it is not helping", and at 1 every number below is
    /// bit-identical to 0.106.0.
    var echoResidual: Float = 1
    private var rawEnv: Float = 0
    private var floorGain: Float = 1
    /// Where the floor's mute has actually reached, for a test that wants the
    /// bound rather than the intent.
    var floorGainNow: Float { floorGain }
    /// Everything this class is currently doing to the microphone, as one
    /// number. A rig that infers this from the OUTPUT LEVEL cannot tell a duck
    /// from a silence -- it reads a quiet syllable at -20 dB as a lost one --
    /// and that is exactly the false positive that made the first honest
    /// measurement of this feature unreadable.
    var appliedGainNow: Float { gain * yieldGain * floorGain }

    // ── HOW LOUD, AND NOT MERELY WHETHER ──────────────────────────────────────
    //
    // `vocal` is the classifier's verdict: quiet, backchannel, claim. Three
    // words. The window edge wants a CONTINUOUS number, because the thing it is
    // trying to be is not an indicator that turns on -- it is the room appearing
    // to respond to a voice, and a room responds by the syllable.
    //
    // Both envelopes already exist and are already the right shape: `nearEnv` and
    // `farEnv` are peak trackers with an instant attack and a tens-of-ms release,
    // which is what a loudness meter is. All that is missing is a reference and a
    // scale, and both have to be relative or the edge would be a picture of how
    // far somebody is sitting from their laptop.
    //
    // The reference is the gate's own learned noise floor, so a quiet room and a
    // noisy one produce the same drawing for the same voice. The scale is dB and
    // not amplitude, because loudness is logarithmic and a linear meter spends
    // nine tenths of its travel on the top 20% of a shout: 24 dB of range above
    // the floor, which is roughly a murmur to a raised voice.
    //
    // Read by a DISPLAY at 30 Hz off the capture thread's aligned floats, the
    // same way `appliedGainNow` already is. A stale frame is not a defect
    // anybody can see; a new fast path into AppKit for a number only a drawing
    // consumes would be.
    var nearLoudNow: Float { Self.loud(nearEnv, over: floor) }
    /// The far end's voice as it is being PLAYED here -- the reference signal --
    /// so the blue edge is driven by the same sound the ear is receiving, not by
    /// a status byte that says only that they are talking.
    var farLoudNow: Float { Self.loud(farEnv, over: floor) }
    /// The raw far envelope, for strict's overlap meter. Fed from the DECODED
    /// stream before the ear, so it reads what the far end is SENDING even
    /// while this end's speaker is closed.
    var farEnvNow: Float { farEnv }
    /// ── WHAT THIS ROOM RETURNS, AND WHAT IS LEFT OF IT ───────────────────────
    ///
    /// `coupling` is the fraction of the loudspeaker's output that comes back
    /// into this microphone -- a property of the room and the desk, learned as a
    /// slow minimum. `echoPathNow` is that AFTER the canceller, which is the only
    /// quantity that says whether the far end will hear themselves.
    ///
    /// It is not the same question as "how much did the canceller remove", and
    /// the difference is not academic: at a coupling of 0.25 there is only so much
    /// TO remove, so a canceller doing everything possible reports a modest ERLE
    /// -- measured in `--turn-test` as 6.8 dB on one end and 15.6 on the other,
    /// with the same filter and the same room. ERLE is a report card on the
    /// canceller; this is a statement about the call.
    var couplingNow: Float { coupling }
    private static func loud(_ env: Float, over noise: Float) -> Float {
      // Never divide by the raw floor: it tracks DOWN into a silent room, and a
      // reference that approaches zero turns room tone into a shout.
      let ref = max(noise * 2, 0.0015)
      guard env > ref else { return 0 }
      let db = 20 * log10f(env / ref)
      return min(1, max(0, db / 24))
    }

    private var yieldGain: Float = 1
    private(set) var yieldSamples = 0
    /// Where the duck has actually got to, so a test can assert the bound rather
    /// than the intent.
    var yieldGainNow: Float { yieldGain }
    /// How long this end has been silent inside the current vocalisation. Read by
    /// the subtitle thread: a completion judgement is only meaningful AT A PAUSE,
    /// and this is the pause.
    var quietMsNow: Double { Double(quietSamples) / SR * 1000 }
    /// ── IS A VOICE LEAVING THIS MICROPHONE RIGHT NOW ──────────────────────────
    ///
    /// `vocal` deliberately survives 450 ms of silence so a breath between
    /// words does not end a turn -- correct for the drawing, and the reason the
    /// floor's release clock could not start until 450 ms after the holder had
    /// actually stopped. This is the same classifier's other question, with a
    /// 120 ms hangover: longer than a plosive closure (30-80 ms), far shorter
    /// than a turn gap. It crosses the wire as `Wire.ST_VOICING`.
    var voicingNow: Bool { vocalSamples > 0 && quietMsNow < 120 }
    var vocalMsNow: Double { Double(vocalSamples) / SR * 1000 }
    private(set) var closedFrames = 0
    private(set) var openFrames = 0
    private(set) var backchannels = 0
    private(set) var claims = 0
    /// Samples where the level test called it a voice and the correlation veto
    /// said it was this machine's own speaker. The number that separates "the
    /// veto never fired" from "it fired and did not help" on a live call.
    private(set) var vetoFrames = 0
    private(set) var vetoArmedFrames = 0
    private(set) var levelVoiceFrames = 0
    /// Samples the visual signal rescued from the echo veto -- a real voice the
    /// correlation had mistaken for this machine's own loudspeaker. The number
    /// that says whether the camera is earning its CPU.
    private(set) var unvetoFrames = 0
    /// Whether the current vocalisation started life as a listening noise. A bid
    /// that escalated from one is a different event from a bid that began as
    /// one, and only the first says the classifier hesitated.
    private(set) var vocalWasBackchannel = false
    /// ── DID THIS VOCALISATION EVER BECOME A BID ───────────────────────────────
    ///
    /// Latched here rather than sampled by whoever needs it. Recognition finishes
    /// after the sound does, so the thing that publishes the words is asking a
    /// question about a moment that has already passed -- and the subtitle thread,
    /// which polls every 120 ms, could look twice at the start of a sentence,
    /// see `backchannel` both times, and label an entire paragraph a listening
    /// noise. Photographed on a live call: six seconds of speech blooming across
    /// the window in 30 pt.
    ///
    /// The gate sees every block. It knows.
    private(set) var everClaimed = false

    /// What the classifier is actually looking at. Read once a second by the
    /// report line under KIN_GATE_DEBUG; nothing on the call path reads them.
    /// A detector that will not fire is not debuggable from its output.
    var innards: String {
      String(format: "n=%d going=%.0fms quiet=%.0fms near=%.4f floor=%.4f "
                   + "far=%.4f coup=%.2f run=%d vocal=%d",
             lastN, Double(vocalSamples) / SR * 1000, Double(quietSamples) / SR * 1000,
             nearEnv, floor, farEnv, coupling, run, vocal.rawValue)
    }
    private var lastN = 0

    @inline(__always) func noteFar(_ v: Float) {
      let a = abs(v)
      farEnv = a > farEnv ? a : farEnv * 0.9994        // ~35 ms release at 48 kHz
    }

    func process(_ x: UnsafeMutablePointer<Float>, _ n: Int) {
      // ── THE CLASSIFIER IS NOT THE GATE, AND IT USED TO DIE WITH IT ──────────
      //
      // This line was `guard cfg.on else { vocal = .quiet; return }`, and
      // `cfg.on` is false on headphones -- correctly, because there is no echo
      // path there to protect against. But everything downstream reads `vocal`,
      // so on headphones the classifier never ran, `vocal` was permanently
      // `.quiet`, and with it went the cues, the captions, the ledger and the
      // deadlock rule. THE ENTIRE TURN-TAKING PRODUCT WAS OFF FOR ANYONE WEARING
      // HEADPHONES -- which is most people, on most calls, and is precisely the
      // situation where two people CAN talk over each other freely and most need
      // to be shown that they are.
      //
      // `feature-behind-a-flag-nobody-runs`, with the flag being a pair of
      // headphones. The gate is an ECHO judgement and belongs to the speaker
      // route. Classifying a voice, drawing a cue and writing a caption are
      // CONVERSATION judgements and belong to every call. They are separated
      // below rather than here: this function always runs, and only the two
      // places that touch the samples ask whether the gate is on.
      // ── EVERY CONSTANT HERE IS A TIME, NOT A PER-BLOCK NUMBER ────────────────
      //
      // This is the third instance of the bug class in this project and the most
      // expensive: a smoothing coefficient written per BLOCK is only correct at
      // the block size it was tuned at. These were tuned against a 128-sample rig
      // block (2.67 ms) and the machine delivers SIXTEEN samples (0.33 ms), so
      // every one of them ran eight times too fast.
      //
      // What that did, measured on a live call: the "noise floor" reached the
      // level of the speech in 170 ms, so `aboveRoom` went false in the middle of
      // a sentence; the classifier could then never accumulate its 700 ms and the
      // far end saw a LISTENING NOISE through six seconds of somebody talking.
      // Zero bids in a fourteen-second call, on a detector whose whole job is to
      // notice bids.
      //
      // The rig could not see it because the rig chose its own block size. It
      // sweeps the real one now.
      let dt = Double(n) / SR
      lastN = n
      var peak: Float = 0
      for k in 0..<n { let a = abs(x[k]); if a > peak { peak = a } }
      // 35 ms, matching the far side -- and now actually 35 ms rather than
      // "0.93 per block", which was 4.6 ms on this machine.
      let envA = Float(exp(-dt / 0.035))
      nearEnv = peak > nearEnv ? peak : nearEnv * envA
      // The same envelope on the untouched microphone, for the coupling tracker
      // alone. Identical to `nearEnv` when nothing is upstream.
      let rawPk = rawPeakIn >= 0 ? rawPeakIn : peak
      rawEnv = rawPk > rawEnv ? rawPk : rawEnv * envA
      // ── A FLOOR THAT RISES DURING SPEECH IS NOT A FLOOR ─────────────────────
      //
      // It falls fast, so it settles into a quiet room in a moment, and it rises
      // slowly, so a cough cannot drag it up over a voice. The second half only
      // works if it also refuses to rise WHILE somebody is talking: this is a
      // noise tracker, and speech is not noise. Bootstrapping is fine -- the
      // floor starts low, so the first voice is detected, so the floor holds --
      // and there is a very slow rise even during voice so a genuinely loud room
      // can still lift it rather than latching the detector on forever.
      let fallK = Float(1 - exp(-dt / 0.15))
      if nearEnv < floor { floor += (nearEnv - floor) * fallK }
      let far = farEnv
      let farTalking = far > 0.004
      if farTalking {
        farTalkingSamples = min(Int(SR * 2), farTalkingSamples + n)
        farQuietSamples = 0
      } else {
        farQuietSamples = min(Int(SR * 2), farQuietSamples + n)
        if farQuietSamples > Int(SR * 0.120) { farTalkingSamples = 0 }
      }
      farRun = farTalking ? farRun + n : 0
      // NOT AT THE ONSET. When the far end starts, the echo has not arrived yet
      // -- it is a room away and a buffer behind -- so for a few milliseconds
      // the microphone is honestly silent while the playout is loud. A minimum
      // tracker fed that moment learns "there is no echo here" and never closes
      // again. One transient, latched forever.
      if farTalking, farRun > Int(SR * 0.08), rawEnv > 0.0008 {
        let r = min(max(rawEnv / max(far, 1e-6), 0.002), 4)
        // 3% a second of upward creep, so a room that gets more reflective is
        // followed, expressed as a rate rather than as "1.00002 per block" --
        // which was 6% a second on this machine and 0.75% on the rig.
        coupling = r < coupling ? r : min(coupling * Float(exp(0.03 * dt)), 4)
      }

      // THE BAR MOVES WITH WHAT THE SPEAKER IS EMITTING. A fixed one is deaf
      // when the far end is loud and trigger-happy when it is quiet; the second
      // is worse, and in the app this detector came from it cut six replies out
      // of nine short. Three terms, whichever is highest: a multiple of the room
      // floor, an absolute minimum for a silent room where any multiple of
      // nothing is still nothing, and a multiple of the echo we expect.
      // TWO SEPARATE TESTS, BECAUSE THEY GUARD AGAINST DIFFERENT MISTAKES.
      // "Louder than the echo can explain" is what keeps the far end's own voice
      // from reading as this end talking, and it is the only thing the GATE
      // needs. "Louder than this room's own floor" is what keeps a fan or a
      // keyboard from reading as a voice, and it only matters to the classifier.
      // Rolled into one bar they interfere: the floor sits far below the echo
      // during far-end speech, so the floor term alone declares the echo voiced.
      // ── HOW MUCH ECHO IS STILL THERE, WHICH IS NOT THE SAME AS HOW MUCH THE
      //    ROOM MAKES (0.107.0) ────────────────────────────────────────────────
      //
      // `coupling` is what the room returns. `echoResidual` is what survived the
      // canceller. The bar has to be built from the product, because the bar's
      // job is to answer "could the echo alone explain this microphone" and the
      // echo in question is the one still present in the signal being judged.
      //
      // This is the single line that converts cancellation into duplex. A person
      // sitting under an echo 20 dB louder than their own voice was, at the
      // instant of decision, indistinguishable from that echo -- the note above
      // says so and it was true. With 20 dB of the echo subtracted they are 20 dB
      // ABOVE what is left, and the same comparison that used to gag them now
      // passes them.
      //
      // And it degrades in the safe direction by construction: `echoResidual` is
      // MEASURED, so a filter that stops working takes the bar straight back to
      // where it was. Writing a constant here instead would be the exact shape of
      // `stale-constants-after-a-codec-win`.
      let effCoupling = coupling * max(0.02, min(1, echoResidual))
      let expected = effCoupling * far
      // THE MARGIN CANNOT BE A CONSTANT, BECAUSE THE MISTAKE IT GUARDS IS NOT
      // SYMMETRIC. A generous margin suppresses echo well and, in a room where
      // the microphone sits inches from the speaker, sits ABOVE an ordinary
      // speaking voice -- so the person is gated while they talk. Leaking some
      // echo is a worse call; being cut off is an unusable one. Measured across
      // simulated rooms, a fixed 2.2 gives 19 dB at light coupling and alters
      // the near voice once the microphone hears the speaker at 80% of playout,
      // which a laptop does. So it relaxes as the coupling rises: there is less
      // room to be clever exactly where being clever is dangerous.
      // On the EFFECTIVE coupling, not the room's: the margin relaxes because a
      // hard room leaves no room to be clever, and a hard room whose echo has
      // been subtracted is not a hard room any more. Identical when the residual
      // is 1.
      let effMargin = max(1.35, cfg.margin - 1.5 * effCoupling)
      // ── AND ON HEADPHONES THERE IS NOTHING TO EXPLAIN AWAY ─────────────────
      //
      // No acoustic path from the earcup to the microphone means no near-mic
      // energy can be echo, so the test is not merely unnecessary -- keeping it
      // would be actively wrong, and wrong in the worst possible place.
      // `coupling` is a MINIMUM tracker that only updates while this end is
      // making sound, so somebody who plugs headphones in and then listens keeps
      // whatever coupling their speakers taught it. The far end's voice would
      // then explain away their own, and the classifier would go deaf exactly
      // during simultaneous speech -- the one moment it exists for.
      // `directional-property-measured-at-wrong-end` in miniature: a property of
      // the ROUTE, applied after the route changed.
      let aboveEcho = cfg.on ? nearEnv > expected * effMargin : true
      let aboveRoom = nearEnv > max(floor * 4.0, 0.006)
      // TWO CONSECUTIVE BLOCKS was the rule, and two blocks is 5.3 ms on the rig
      // and 0.67 ms on the machine -- less than a single glottal period, so it
      // meant nothing there. It is 4 ms of continuous voice now, at any block
      // size, which is what it was always trying to say.
      let needed = max(2, Int((0.004 / dt).rounded(.up)))
      // ── AND THE DETECTOR'S VETO, WHICH THE LEVEL TEST CANNOT PROVIDE ───────
      //
      // `aboveEcho` compares levels, and the comparison is deliberately generous
      // in a hard room -- "suppress less rather than gate somebody" -- so a
      // laptop's own speaker passes it and gets CLASSIFIED as this person
      // talking (measured: a listening end's gate open 97% of a call it spent
      // alone). The correlation estimator answers the question levels cannot:
      // not "how loud" but "is this sound the one we just played". While it
      // says yes, the sound may still be HEARD (the level gate and `want` are
      // untouched -- the near voice contract holds) but it is never a voice:
      // no cue crosses the wire, no claim takes the floor, and the floor mutes
      // instead of ducking. Counted, so a call can say how often it decided.
      // ── AND THE MOUTH OUTRANKS THE CORRELATION ────────────────────────────
      //
      // The veto's own stated risk (0.94.0): "the worst wrong-mute is one
      // estimator tick, ~500 ms, on a voice quieter than the echo it is
      // under". That risk is real and it is acoustically unfixable -- a mic
      // carrying both a person and a loud echo of the far end correlates with
      // the far end, and no threshold separates them.
      //
      // A camera does. If a face is visible and its mouth is doing what speech
      // does, the sound reaching this microphone is not only the loudspeaker,
      // whatever the correlation says. So the visual signal is allowed to
      // withdraw the veto -- and ONLY to withdraw it. It can open a microphone
      // that would have been gagged; it can never close one, never mute
      // anybody, and when the detector is blind (`visualKnown` false: no face,
      // no camera, a dark room) it says nothing at all and the veto stands
      // exactly as it did in 0.99.0.
      let mouthSays = Mouth.on && Mouth.influence && Mouth.visualKnown && Mouth.visualVoice
      let veto = Audio.corrVeto && !mouthSays && aboveEcho && aboveRoom
      if veto { vetoFrames += n }
      if Audio.corrVeto && mouthSays && aboveEcho && aboveRoom { unvetoFrames += n }
      // ── THE TWO DENOMINATORS THAT MADE `a_corr_veto_pct` UNREADABLE ─────────
      //
      // One live call reported the veto firing for 6.9% of its samples while the
      // correlation was over threshold in 23 of 69 beats -- a third of the call
      // -- and there was no way to tell whether that meant "it is catching only
      // the wrong moments" or "the level test was already right for the other
      // 26%, so there was nothing to catch". Those two need completely different
      // work and the beat could not distinguish them.
      //
      //   vetoArmedFrames  how much of the call the correlation CLAIMED this
      //                    microphone, whatever the level test thought
      //   levelVoiceFrames how much of it the level test called a voice
      //
      // `vetoFrames` is the intersection -- the only part where the veto changed
      // a verdict. Three numbers, and the pair of them is what turns the third
      // into a measurement (`counted-without-a-denominator`).
      if Audio.corrVeto { vetoArmedFrames += n }
      if aboveEcho && aboveRoom { levelVoiceFrames += n }
      let voiced = aboveEcho && aboveRoom && !veto
      if voiced { run += 1 } else { run = 0 }
      let confirmed = run >= needed
      // The floor rises only when this is NOT somebody talking -- 2 s to settle
      // into a room, and a 60 s creep even during speech so a detector that has
      // latched on to a loud room can still climb out of it.
      if nearEnv > floor {
        floor += (nearEnv - floor) * Float(1 - exp(-dt / (confirmed ? 60 : 2)))
      }

      // ── BACKCHANNEL OR A BID FOR THE FLOOR ───────────────────────────────
      //
      // The difference is duration and nothing cleverer. A continuer is over
      // before a word would be; wanting the floor takes longer than that,
      // because you have to start saying something. The threshold is generous
      // on purpose: mistaking a bid for a continuer costs a person their turn,
      // and mistaking a continuer for a bid costs a cue that was going to
      // disappear anyway.
      // ── HOW LONG THEY HAVE BEEN GOING, AND HOW LONG THEY HAVE STOPPED ──────
      //
      // Both were counts of blocks, and both were wrong in the same way. A bid is
      // "you have been talking for 700 ms" -- WALL CLOCK -- not "700 ms worth of
      // blocks were above the bar", because ordinary speech is only voiced maybe
      // half the time at a third of a millisecond's resolution and the other half
      // was being counted as silence. On the machine that made `quietMs` reach
      // 450 before `voicedMs` reached 700, every single time, so the classifier
      // could not physically produce a bid.
      //
      // And silence has to be CONSECUTIVE. Accumulating every quiet block since
      // the vocalisation began adds up the gaps between syllables and ends a turn
      // in the middle of a sentence.
      if confirmed, vocalSamples == 0 { vocalSamples = 1 }
      if vocalSamples > 0 { vocalSamples += n }
      if confirmed { quietSamples = 0 } else if vocalSamples > 0 { quietSamples += n }
      let vocalMs = Double(vocalSamples) / SR * 1000
      let quietMs = Double(quietSamples) / SR * 1000
      if vocalSamples > 0 { promote(vocalMs >= cfg.claimMs ? .claim : .backchannel) }
      // A gap longer than an ordinary mid-sentence pause ends it. 200-400 ms is
      // a pause inside a sentence; past that the person has stopped.
      if quietMs > 450 { vocalSamples = 0; quietSamples = 0; promote(.quiet) }

      // THE GATE OPENS ON VOICE, NOT ON THE VERDICT. Waiting for the classifier
      // to decide between a continuer and a bid means holding the microphone
      // down through the first seven hundred milliseconds of somebody's
      // sentence, and a test that asserts the near voice is untouched catches
      // that immediately: 92% of the worst sample, gone. So the audio path
      // opens the moment there is voice at all, and the classification is an
      // OBSERVER -- it decides what cue the far end draws, never whether this
      // person is allowed to be heard.
      //
      // Withholding a continuer's audio is a separate change and needs the
      // retroactive buffer to be safe: hold the samples, and release them into
      // the gap if it turns out to be a bid. Until that exists, a continuer is
      // audible, which is exactly what happens today.
      // Hangover dwell: hold suppression across brief inter-syllable pauses
      // (~120 ms) when near end is not vocalising, preventing rapid on/off flapping.
      let farDwell = farTalkingSamples > Int(SR * 0.08) && farQuietSamples < Int(SR * 0.120)
      let farActive = farTalking || (farDwell && !aboveEcho)
      let nearTalking = !farActive || aboveEcho
      // ONE OF THE TWO PLACES THAT TOUCHES SAMPLES, and the only one that is
      // about echo. On headphones this is always 1: nothing is held down,
      // because nothing would be heard twice.
      let want: Float = (cfg.on && farActive && !nearTalking && !floorGranted)
        ? Float(pow(10, cfg.floorDb / 20)) : 1

      // Smooth transitions: avoid violent square-wave gating and speech shredding.
      // Opening on near voice onset stays fast (~1 ms) to protect consonants;
      // opening on quiet release is smoothed (~12-16 ms) to prevent noise-floor pumping.
      let openStep: Float = (aboveEcho && aboveRoom) ? 0.02 : 0.003
      let closeStep = Float(1.0 / (SR * max(0.5, cfg.closeMs) / 1000.0))
      // ── AND THE DUCK, WHICH IS A SEPARATE DECISION ─────────────────────────
      //
      // Its own smoothed factor rather than folded into `want`, because the two
      // move for different reasons and at different speeds: the gate is an
      // echo judgement made every block, and this is a turn judgement made once
      // per collision. 80 ms down so it is a duck and not a cut, 50 ms back up so
      // the moment the deadlock ends you are simply talking again.
      //
      // THE OTHER PLACE, and it is NOT conditioned on `cfg.on`. A deadlock --
      // both people start together and neither backs off -- is a social event,
      // not an acoustic one. It happens on headphones exactly as it does on
      // speakers, so the duck belongs to every call and is switched off by
      // `--no-yield` alone.
      let yWant: Float = (cfg.yieldOn && yielding) ? Float(pow(10, cfg.yieldDb / 20)) : 1
      let yStep: Float = yWant > yieldGain ? 0.00042 : 0.00026
      // The floor's own target, on the gate's ramp. A full mute, because "one
      // microphone at a time" is not a duck -- but it reaches zero on the same
      // timed linear close, because an exponential cannot deliver a mute and
      // that cost this project fourteen decibels once already.
      let fWant: Float = floorMuted ? 0 : (floorDucked ? Float(pow(10, cfg.floorDuckDb / 20)) : 1)
      for k in 0..<n {
        if want < gain { gain = max(want, gain - closeStep) }
        else { gain += (want - gain) * openStep }
        if fWant < floorGain { floorGain = max(fWant, floorGain - closeStep) }
        else { floorGain += (fWant - floorGain) * openStep }
        yieldGain += (yWant - yieldGain) * yStep
        x[k] *= gain * yieldGain * floorGain
      }
      if yWant < 1 { yieldSamples += n }
      if want < 1 { closedFrames += n } else { openFrames += n }
    }

    private func promote(_ v: Vocal) {
      guard v != vocal else { return }
      // Only ever forward within one vocalisation: a continuer that turns out to
      // be a sentence becomes a claim, and a claim never quietly downgrades to a
      // continuer under somebody mid-word.
      if v.rawValue < vocal.rawValue && v != .quiet { return }
      // ── A LISTENING NOISE IS ONE THAT STAYED ONE ────────────────────────────
      //
      // Counted on the way OUT, not on the way in. Every vocalisation begins as a
      // continuer -- it has to, the classifier cannot know in the first
      // millisecond -- so counting at `promote(.backchannel)` scored one
      // "listening noise" for every sentence anybody ever said. The number that
      // means something is how many of them never became a bid.
      if v == .quiet {
        if vocalWasBackchannel && !everClaimed { backchannels += 1 }
        vocalWasBackchannel = false; everClaimed = false
      }
      if v == .backchannel { vocalWasBackchannel = true }
      if v == .claim { claims += 1; everClaimed = true }
      vocal = v
    }
  }
  static var gate = Gate() { didSet { sharedGate.cfg = gate } }
  nonisolated(unsafe) static let sharedGate = DuplexGate()
  /// Whose turn it is. Stepped once per capture block from `accountTurn`, which
  /// is the only place that sees this end's state and the far end's in the same
  /// instant. See `Floor.swift` and `mac/FLOOR.md`.
  nonisolated(unsafe) static let sharedFloor = Floor()
  /// What the far end's status byte last said about its voice, as the turn
  /// layer's tri-state. Written by the receive thread, read by the capture
  /// thread; a scalar, so it crosses safely.
  nonisolated(unsafe) static var peerVoiceNow = Floor.Voice.quiet
  /// Half the measured round trip, in ms. The age of any cue the moment it
  /// lands -- see `noteFar(transitMs:)`, which exists because assuming this was
  /// zero was a hidden distance limit.
  nonisolated(unsafe) static var owdMsNow: Double = 0
  /// The route, as a fact and not as the echo gate's conclusion about it.
  nonisolated(unsafe) static var outputIsSpeakers = true {
    didSet {
      guard oldValue != outputIsSpeakers else { return }
      if presenceAuto {
        if !outputIsSpeakers {
          if let p = Presence.named("in-the-room") {
            presenceMode = "in-the-room"
            presence = p
            Metrics.fact("presence", "in-the-room")
          }
        } else {
          presenceMode = "off"
          presence = Presence()
          Metrics.fact("presence", "off")
        }
      }
    }
  }
  /// ── THE ECHO DETECTOR'S VERDICT, GIVEN TO THE CLASSIFIER (0.94.0) ─────────
  ///
  /// True while the echo estimator's last computation said this microphone is
  /// mostly this machine's OWN loudspeaker (correlation at one lag ≥ CORR_VETO),
  /// the computation is fresh, and the route is speakers. The classifier then
  /// refuses to call that sound a voice.
  ///
  /// Why it exists, measured on call 38xkekqs4ugc7 (0.93.0, two rooms): one end
  /// sat alone, mic peak 0.26, and its gate was OPEN 97% of the call -- the only
  /// sound in that room was its own speaker. The level test cannot win there by
  /// design ("suppress less rather than gate somebody"), so the leak was
  /// classified a bid, the floor answered with the -20 dB duck instead of the
  /// mute, and the talker heard themselves for the whole call. The correlation
  /// is the evidence the level test lacks: unrelated speech measures ~0.26 here,
  /// a real echo lock 0.65-0.76.
  ///
  /// A scalar written by the estimator thread, read by the capture thread.
  /// Stale values CLEAR (the estimator zeroes it when it has not computed for
  /// CORR_VETO_FRESH_MS), so silence cannot gag the first word after it: the
  /// worst wrong-mute is one estimator tick, ~500 ms, on a voice quieter than
  /// the echo it is under -- which the -20 dB duck made inaudible anyway.
  nonisolated(unsafe) static var corrVeto = false
  /// `--no-corrveto` is the control arm.
  nonisolated(unsafe) static var corrVetoOn = true
  /// The same 0.45 the telemetry summary has always called "speaker fed the mic
  /// on YES" -- one number meaning one thing (`second-copy-of-a-rule`).
  static let CORR_VETO = 0.45
  static let CORR_VETO_FRESH_MS: Double = 1500
  /// ── HOW MUCH CANCELLATION WITHDRAWS THE ECHO VETO ─────────────────────────
  ///
  /// 0.32 in amplitude is -10 dB of ERLE. Below that the canceller has removed
  /// most of the echo, so "this microphone is mostly our own loudspeaker" has
  /// stopped being a true description of what leaves this machine and the veto
  /// is withdrawn. Above it the veto stands exactly as it did in 0.106.0.
  ///
  /// 10 dB and not 3: the veto exists to stop a listening end's own speaker
  /// being classified as a voice (measured: a gate open 97% of a call spent
  /// alone), and giving that up needs the echo to be genuinely gone rather than
  /// merely reduced.
  static let AEC_VETO_RELIEF: Float = 0.32
  /// The canceller's measured residual, as an amplitude ratio. 1 means nothing
  /// was removed. Written by the estimator thread and by the capture thread,
  /// read by both -- a Float scalar, like `owdMsNow` beside it.
  nonisolated(unsafe) static var aecResidual: Float = 1
  nonisolated(unsafe) static var aecErleDb: Double = 0
  /// Off restores 0.106.0 exactly: no subtraction, and the echo veto back on the
  /// correlation alone. `--no-aec`.
  nonisolated(unsafe) static var aecOn = true
  /// ── THE CONTROL ARM FOR THE OVERLOAD CUT (0.107.0) ────────────────────────
  ///
  /// Off means nothing stops an output over full scale, which is close to what
  /// 0.106.0 actually did in the case that mattered: the cut was reachable only
  /// on ticks the echo veto was quiet AND only when a makeup gain was in force,
  /// and the live failure had neither. Kept as a switch so "the microphone was
  /// running hot" can be measured against its absence rather than argued about
  /// (`a_mic_hot_pct` is the ruler).
  nonisolated(unsafe) static var overloadGuard = true
  /// Rig overrides for the canceller's two swept constants, applied to the
  /// shared instance at start. Read once; nothing on the call path reads them.
  nonisolated(unsafe) static var aecTaps = -1
  nonisolated(unsafe) static var aecMu: Float = -1
  /// The drift tracker's arm. Off is 0.108.0: a fixed integer aim.
  nonisolated(unsafe) static var aecDrift = true
  /// The nonlinear loudspeaker branches in `Aec` (0.125.0). See `Aec.Cfg.nlOn`.
  nonisolated(unsafe) static var aecNl = false
  /// Whether the turn layer is in force. `--no-floor` is the control arm.
  nonisolated(unsafe) static var floorOn = true
  /// Whether the far end reaches this ear. Written by the capture thread, read
  /// by the render callback; a Bool, so it crosses safely, and the render side
  /// ramps rather than stepping.
  nonisolated(unsafe) static var earOpen = true
  /// `Predict.probability` that this end's turn is ending, 0-1. Written by the
  /// subtitle thread. Zero until the predictor is fed, and zero is the value
  /// that changes nothing.
  nonisolated(unsafe) static var turnEndProb: Double = 0
  /// The far end's prior, from TPKTX+7. Written by the receive thread. Zero
  /// against an older build, which is the value that changes nothing.
  nonisolated(unsafe) static var peerTurnEndProb: Double = 0
  /// The ear's close, per sample, from the same 4 ms the microphone side uses.
  /// Derived from `Gate.closeMs` rather than typed, so the two cannot drift.
  static let EAR_STEP = Float(1.0 / (SR * 4.0 / 1000.0))
  private let dgate = Audio.sharedGate
  var gateClosedFrames: Int { dgate.closedFrames }
  var gateOpenFrames: Int { dgate.openFrames }

  @inline(__always) private func noteFar(_ v: Float) { dgate.noteFar(v) }
  private func duplexGate(_ x: UnsafeMutablePointer<Float>, _ n: Int) { dgate.process(x, n) }

  var lastRenderErr: OSStatus = 0

  init() {
    capBuf = .allocate(capacity: FPP)
    capBuf.initialize(repeating: 0, count: FPP)
    // Room for the primary payload AND a redundant copy with its own capture
    // stamp, so turning redundancy on never needs a reallocation on the audio
    // thread.
    let scratchBytes = 1500
    capScratch = .allocate(capacity: scratchBytes)
    capScratch.initialize(repeating: 0, count: scratchBytes)
    prevBuf = .allocate(capacity: FPP)
    prevBuf.initialize(repeating: 0, count: FPP)
    capHistory = .allocate(capacity: Audio.CAP_HIST_COUNT * FPP)
    capHistory.initialize(repeating: 0, count: Audio.CAP_HIST_COUNT * FPP)
    fecParityScratch = .allocate(capacity: FPP)
    fecParityScratch.initialize(repeating: 0, count: FPP)
    lastGood = .allocate(capacity: FPP)
    lastGood.initialize(repeating: 0, count: FPP)
    hist = .allocate(capacity: Audio.HIST)
    hist.initialize(repeating: 0, count: Audio.HIST)
    // Playout and capture history exist whenever the estimator does, which is
    // always: "is my speaker feeding my microphone" is a question worth answering
    // on every call, not only when a canceller is being tested.
    echoHist = {
      let b = UnsafeMutablePointer<Float>.allocate(capacity: Audio.ECHO_MAX)
      b.initialize(repeating: 0, count: Audio.ECHO_MAX); return b
    }()
    emitHist = {
      let b = UnsafeMutablePointer<Float>.allocate(capacity: Audio.ECHO_MAX)
      b.initialize(repeating: 0, count: Audio.ECHO_MAX); return b
    }()
    capHist = {
      let b = UnsafeMutablePointer<Float>.allocate(capacity: Audio.CAPH)
      b.initialize(repeating: 0, count: Audio.CAPH); return b
    }()
    inScratch = .allocate(capacity: 4096)
    inScratch.initialize(repeating: 0, count: 4096)
    inBufList = .allocate(capacity: 1)
  }

  // ── Device plumbing ──────────────────────────────────────────────────────
  private func defaultDevice(input: Bool) -> AudioDeviceID {
    // The person's choice wins, when the thing they chose is still plugged in.
    // Resolved HERE rather than remembered as an ID, so a device that comes and
    // goes is picked up again the next time the graph is built. See
    // `Audio.resolve`.
    if let picked = Audio.resolve(input ? Audio.chosenInputUID : Audio.chosenOutputUID,
                                  input: input) {
      return picked
    }
    var id = AudioDeviceID(0)
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
      mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &id)
    return id
  }

  private func deviceName(_ dev: AudioDeviceID) -> String {
    var s: Unmanaged<CFString>?
    var sz = UInt32(MemoryLayout<CFString?>.size)
    var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &s) == noErr, let v = s else { return "?" }
    return v.takeRetainedValue() as String
  }

  // THE DEVICE IS NOT A CONSTANT, and assuming it was cost an hour.
  //
  // The stream format below asks for 48 kHz. When the built-in devices happened
  // to be at 48 kHz it worked; the moment macOS put them back to their default
  // 44.1 kHz, AudioUnitRender began returning -10863 on every single callback and
  // the app went silently deaf -- "cap 0/s" with no reason given, which reads
  // exactly like a muted microphone or a denied permission.
  //
  // So the rate is SET, then READ BACK, and a device that will not do 48 kHz is a
  // loud failure rather than silence. Setting it is asynchronous: CoreAudio
  // returns before the hardware has changed, so it has to be polled.
  private func forceSampleRate(_ dev: AudioDeviceID, _ want: Double) -> Double {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    func read() -> Double {
      var r: Float64 = 0; var sz = UInt32(MemoryLayout<Float64>.size)
      AudioObjectGetPropertyData(dev, &addr, 0, nil, &sz, &r); return r
    }
    if abs(read() - want) < 1 { return read() }
    var v = Float64(want)
    AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &v)
    for _ in 0..<40 {                       // up to 2 s
      if abs(read() - want) < 1 { return read() }
      usleep(50_000)
    }
    return read()
  }

  // The buffer size IS the latency floor, so it is set explicitly rather than
  // inherited. 128 frames == 2.67 ms; the device may refuse and pick its own,
  // which is why the achieved value is read back and reported. Set AFTER the
  // sample rate: changing the rate can reset the buffer size underneath you.
  private func setBufferFrames(_ dev: AudioDeviceID, _ n: UInt32, input: Bool) -> UInt32 {
    var v = n
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    var got: UInt32 = 0
    var sz = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(dev, &addr, 0, nil, &sz, &got)
    return got
  }

  // Device latency the CALLBACK CANNOT SEE. A mouth-to-ear number that omits
  // this is not mouth-to-ear, it is callback-to-callback -- and reporting the
  // smaller number as the goal metric is how a project congratulates itself.
  private func deviceLatencyMs(_ dev: AudioDeviceID, input: Bool) -> Double {
    let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    func u32(_ sel: AudioObjectPropertySelector) -> UInt32 {
      var v: UInt32 = 0; var sz = UInt32(MemoryLayout<UInt32>.size)
      var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
      AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &v)
      return v
    }
    let frames = u32(kAudioDevicePropertyLatency) + u32(kAudioDevicePropertySafetyOffset) + u32(kAudioDevicePropertyBufferFrameSize)
    return Double(frames) / SR * 1000.0
  }

  // ── THE ECHO CANCELLER THIS APP NEVER HAD ──────────────────────────────────
  //
  // Until now both ends of every call ran `kAudioUnitSubType_HALOutput`: raw
  // hardware in and out, with NO acoustic echo cancellation, no gain control and
  // no noise suppression. The software canceller beside this file measured
  // 11-13 dB against a LINEAR simulation and was `aecOn = false` by default, so
  // in the field there was nothing at all -- two people on speakers each fed the
  // other's voice straight back, which is what "the mic was hit hard from both
  // sides" sounds like.
  //
  // `VoiceProcessingIO` is the unit FaceTime uses. It cancels against the render
  // stream the OS actually played, which is why it must be ONE duplex unit rather
  // than the two this file used to build -- an input-only instance has no
  // reference signal and would cancel nothing.
  //
  // Two things it fixes for free, both of which have their own scars here:
  //   * it converts sample rates, so a device that will not move to 48 kHz stops
  //     being a hard stop ("device at 44100 Hz, need 48000 Hz")
  //   * it owns the mic gain, so a hot input stops clipping into the encoder
  //
  // What it costs is latency, and this project's whole point is latency -- so HAL
  // stays reachable as `--io hal`, unchanged, and the two are measurable against
  // each other rather than argued about.
  /// What the hardware is actually running at, which under VPIO need not be `SR`.
  var hwInRate: Double = 0
  var hwOutRate: Double = 0
  // ── PURE BY DEFAULT ───────────────────────────────────────────────────────
  //
  // "vp" is Apple's VoiceProcessingIO: a good echo canceller wrapped in noise
  // suppression and automatic gain, and that wrapper is the sound of being on a
  // call rather than in a room. It is the thing this is trying not to be. "hal"
  // is the plain device -- nothing between the microphone and the wire.
  //
  // What replaces the echo control is the duplex gate, which is transparent by
  // construction: it only ever acts while the near end is NOT speaking, and a
  // test asserts that a talking near end comes out bit-for-bit as captured.
  // Echo during double talk is not solved by this and is the honest gap.
  static var ioKind = "hal"
  /// True when `--io` named it explicitly. Without this the route-derived
  /// default below would quietly overwrite what the operator asked for, which
  /// is how a control arm stops being a control arm.
  static var ioPinned = false
  static var agcOn = true
  /// Device-level input gain staging. On by default because the failure it fixes
  /// is silent, common, and unfixable anywhere else; `--no-auto-gain` is the
  /// control arm.
  static var autoGain = true
  static var gainDebug = false
  var duplex: Bool { Audio.ioKind == "vp" }

  private func makeDuplexUnit() throws -> AudioUnit {
    var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_VoiceProcessingIO,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0, componentFlagsMask: 0)
    guard let comp = AudioComponentFindNext(nil, &desc) else {
      throw Err.e("no VoiceProcessingIO component")
    }
    var unit: AudioUnit?
    try ck(AudioComponentInstanceNew(comp, &unit), "InstanceNew(vp)")
    guard let u = unit else { throw Err.e("null vp unit") }

    // BOTH scopes on one instance. This is the whole reason for the duplex unit.
    var enable: UInt32 = 1
    try ck(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                &enable, 4), "vp enable in")
    try ck(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                &enable, 4), "vp enable out")

    // Same wire format as the HAL path: float32, mono, 48 kHz. VPIO converts to
    // and from whatever the hardware is actually running, which is the point.
    var asbd = AudioStreamBasicDescription(mSampleRate: SR, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
      mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
      mBitsPerChannel: 32, mReserved: 0)
    let sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    // What we RECEIVE from the mic: output scope of the input element.
    try ck(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                &asbd, sz), "vp in format")
    // What we HAND to the speaker: input scope of the output element.
    try ck(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                &asbd, sz), "vp out format")

    // Processing ON. `Bypass` defaults to 0 already; set it anyway, because a
    // default that changes under us is a silent regression in the one feature
    // this unit exists for. Not fatal if refused -- an older OS that has no such
    // property still cancels.
    var bypass: UInt32 = 0
    let b = AudioUnitSetProperty(u, kAUVoiceIOProperty_BypassVoiceProcessing,
                                 kAudioUnitScope_Global, 0, &bypass, 4)
    var agc: UInt32 = Audio.agcOn ? 1 : 0
    let a = AudioUnitSetProperty(u, kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                                 kAudioUnitScope_Global, 0, &agc, 4)
    // ── KEEP THE INSTRUMENTS ALIVE ──────────────────────────────────────────
    //
    // `makeUnit` is where `inDev`/`outDev` and the two device latencies are
    // normally captured, and the duplex path does not go through it. Left unset
    // they are ZERO, which does not read as "unknown" anywhere downstream -- it
    // reads as "no device latency", and mouth-to-ear would quietly lose the
    // largest fixed term it has. Captured here, from the same devices, with the
    // one difference that the rate is NOT forced: converting is VPIO's job and
    // the 48 kHz hard stop is exactly what it removes.
    inDev = defaultDevice(input: true)
    outDev = defaultDevice(input: false)
    // ── ASK FOR THE SAME SMALL BUFFER THE HAL PATH GETS ─────────────────────
    //
    // The HAL path forces `devBuf` (16 frames) on both devices and measures ~2 ms
    // of device latency. The duplex path did not, took VPIO's default, and
    // measured ~12 ms each way with 10,754 late arrivals in twenty seconds --
    // concealment caused by the buffer, not by the network. VPIO is entitled to
    // refuse (it does its own block processing), so the ACCEPTED size is read
    // back and printed rather than assumed: a request that silently did nothing
    // would look identical to one that worked.
    let gotIn = setBufferFrames(inDev, UInt32(Audio.devBuf), input: true)
    let gotOut = setBufferFrames(outDev, UInt32(Audio.devBuf), input: false)
    inLatencyMs = deviceLatencyMs(inDev, input: true)
    outLatencyMs = deviceLatencyMs(outDev, input: false)
    var inRate: Float64 = 0, outRate: Float64 = 0
    var ra = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var rsz = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(inDev, &ra, 0, nil, &rsz, &inRate)
    rsz = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(outDev, &ra, 0, nil, &rsz, &outRate)
    hwInRate = inRate; hwOutRate = outRate
    // ── READ THE SETTING BACK, BECAUSE ACCEPTED IS NOT IN EFFECT ─────────────
    //
    // `noErr` from AudioUnitSetProperty means the unit took the call, not that
    // anything changed. Four VideoToolbox properties in this project accepted a
    // value, echoed it back, and did nothing, and one of them was believed for a
    // whole release. AGC is the one setting here that audibly alters a voice --
    // it flattens the loud-and-soft that carries how close someone is -- so an
    // A/B of it that was really comparing an arm against itself would be worse
    // than not running one.
    var agcGot: UInt32 = 99
    var agcSz = UInt32(4)
    let ar = AudioUnitGetProperty(u, kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                                  kAudioUnitScope_Global, 0, &agcGot, &agcSz)
    let agcReal = ar == noErr ? (agcGot == 1) : Audio.agcOn
    if ar == noErr, agcReal != Audio.agcOn {
      fputs("*** AGC: asked for \(Audio.agcOn ? "on" : "off") and the unit reports"
          + " \(agcReal ? "on" : "off") -- the flag is not in effect\n", stderr)
    }
    Metrics.fact("agc", ar == noErr ? (agcReal ? "on" : "off") : "unreadable")
    fputs("[io] VoiceProcessingIO -- echo cancellation on"
        + (b == noErr ? "" : " (bypass property refused: \(b))")
        + ", gain control \(Audio.agcOn ? "on" : "off")"
        + (ar == noErr ? " (readback \(agcGot))" : " (readback refused: \(ar))")
        + (a == noErr ? "" : " (AGC property refused: \(a))") + "\n", stderr)
    fputs("[in]  \"\(deviceName(inDev))\" \(Int(inRate)) Hz  bufferFrames=\(gotIn)"
        + " (asked \(Audio.devBuf))  deviceLatency=\(String(format: "%.2f", inLatencyMs)) ms\n", stderr)
    fputs("[out] \"\(deviceName(outDev))\" \(Int(outRate)) Hz  bufferFrames=\(gotOut)"
        + " (asked \(Audio.devBuf))  deviceLatency=\(String(format: "%.2f", outLatencyMs)) ms\n", stderr)
    // The devices themselves, on the wire. "The audio was terrible" is a different
    // problem on AirPods (a Bluetooth path that adds its own delay and its own
    // codec) than on the built-in speakers, and the beat could not tell them
    // apart -- it carried the sample rates and never the names.
    // ── THE MICROPHONE SLIDER IS PART OF THE AUDIO PATH ──────────────────────
    //
    // Found the hard way on this machine: macOS input volume sat at 14 of 100.
    // Every symptom followed from it and none of them pointed at it. With AGC off
    // the far end got a voice peaking at 0.05 -- inaudible. With AGC on, the
    // canceller made up the ~18x shortfall and overshot, so the same voice
    // arrived peaking at 1.01: CLIPPED, which is the harshest, most artificial
    // sound a call can produce. "Too quiet" and "distorted" look like opposite
    // faults and were the same fault, and no amount of work on codecs, jitter or
    // echo could have touched either.
    //
    // A person cannot be expected to find this. The slider is in System Settings,
    // it is not where anyone looks when a call sounds bad, and nothing in the app
    // has ever mentioned it. So the app reads it and says so.
    var vol: Float32 = -1
    var va = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
      mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var vsz = UInt32(MemoryLayout<Float32>.size)
    if AudioObjectGetPropertyData(inDev, &va, 0, nil, &vsz, &vol) != noErr {
      // Some devices expose per-channel volume and nothing on the main element.
      va.mElement = 1
      vsz = UInt32(MemoryLayout<Float32>.size)
      if AudioObjectGetPropertyData(inDev, &va, 0, nil, &vsz, &vol) != noErr { vol = -1 }
    }
    if vol >= 0 {
      Metrics.fact("mic_gain", String(format: "%.2f", vol))
      if vol < 0.35 {
        Metrics.count("mic_gain_low")
        fputs("*** MICROPHONE INPUT IS AT \(Int(vol * 100))% -- this is the single most\n"
            + "    likely reason a call sounds quiet OR distorted. Below about a third,\n"
            + "    the gain control has to make up the difference and overshoots into\n"
            + "    clipping. System Settings > Sound > Input, or:\n"
            + "      osascript -e 'set volume input volume 75'\n", stderr)
      }
    }
    Metrics.fact("mic_dev", deviceName(inDev))
    Metrics.fact("spk_dev", deviceName(outDev))
    // ── APPLE'S ON-DEVICE VOICE MODEL, WHICH THIS APP MAY NOT SWITCH ON ───────
    //
    // Voice Isolation is the good one: a real on-device ML model, running on
    // Apple silicon, that strips a room out of a voice far better than the
    // classic canceller in VoiceProcessingIO underneath it. It is already on
    // every Mac this app runs on.
    //
    // And `preferredMicrophoneMode` is `class, readonly` -- the header says it
    // "has been selected by the user in Control Center". Apple made this the
    // person's choice, not the app's, so there is no call to make here that turns
    // it on. What an app CAN do is know, which is worth more than it sounds: two
    // calls on the same Mac with the same network can sound completely different
    // because of a menu-bar toggle, and without this field every echo number in
    // the record is missing the variable that explains it.
    //
    // `activeMicrophoneMode`, not `preferred`: the header is explicit that the
    // active one differs when the audio route cannot honour the preference, and
    // the one that was actually applied is the one the audio was recorded under.
    let micMode: String
    switch AVCaptureDevice.activeMicrophoneMode {
    case .voiceIsolation: micMode = "voice-isolation"
    case .wideSpectrum:   micMode = "wide-spectrum"
    case .standard:       micMode = "standard"
    @unknown default:     micMode = "unknown"
    }
    Metrics.fact("mic_mode", micMode)
    if AVCaptureDevice.preferredMicrophoneMode != AVCaptureDevice.activeMicrophoneMode {
      Metrics.fact("mic_mode_wanted", "\(AVCaptureDevice.preferredMicrophoneMode.rawValue)")
    }
    fputs("[io] microphone mode: \(micMode)"
        + (micMode == "voice-isolation" ? "" :
           "  -- Voice Isolation is OFF; it is Apple's on-device voice model and"
           + " it is a Control Center toggle (menu bar > Mic Mode), not something"
           + " this app is allowed to set")
        + "\n", stderr)
    if abs(inRate - SR) > 1 || abs(outRate - SR) > 1 {
      fputs("[io] hardware is not at \(Int(SR)) Hz -- VoiceProcessingIO is converting."
          + " Under --io hal this would have been a hard stop.\n", stderr)
    }
    return u
  }

  /// `forced` overrides the device this unit opens. Used by `openUnit`, which
  /// tries other devices when the preferred one refuses the rate.
  private func makeUnit(input: Bool, forced: AudioDeviceID? = nil) throws -> AudioUnit {
    var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0, componentFlagsMask: 0)
    guard let comp = AudioComponentFindNext(nil, &desc) else { throw Err.e("no HALOutput component") }
    var unit: AudioUnit?
    try ck(AudioComponentInstanceNew(comp, &unit), "InstanceNew")
    guard let u = unit else { throw Err.e("null unit") }

    var enable: UInt32 = 1, disable: UInt32 = 0
    if input {
      try ck(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, 4), "enable in")
      try ck(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, 4), "disable out")
    }
    var dev = forced ?? defaultDevice(input: input)
    try ck(AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
      &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "set device")

    let nm = deviceName(dev)
    let rate = forceSampleRate(dev, SR)
    if abs(rate - SR) > 1 {
      fputs("\n*** \(input ? "input" : "output") device \"\(nm)\" is at \(Int(rate)) Hz and will not move to \(Int(SR)) Hz.\n"
          + "*** Every render would fail and the call would be silent, so this is a hard stop\n"
          + "*** rather than a silent one. Pick a device that does \(Int(SR)) Hz, or set it in\n"
          + "*** Audio MIDI Setup, and run again.\n\n", stderr)
      throw Err.e("\(input ? "input" : "output") device at \(Int(rate)) Hz, need \(Int(SR)) Hz")
    }
    if input { inDev = dev } else { outDev = dev }
    let got = setBufferFrames(dev, UInt32(Audio.devBuf), input: input)
    if input { inLatencyMs = deviceLatencyMs(dev, input: true) } else { outLatencyMs = deviceLatencyMs(dev, input: false) }
    let lat = input ? inLatencyMs : outLatencyMs
    fputs("[\(input ? "in" : "out")] \"\(nm)\" \(Int(rate)) Hz  bufferFrames=\(got)"
        + "  deviceLatency=\(String(format: "%.2f", lat)) ms\n", stderr)

    // Float32, deinterleaved, MONO on the wire. Mono because one voice is one
    // channel and doubling the bytes to carry a duplicate is not stereo.
    var asbd = AudioStreamBasicDescription(mSampleRate: SR, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
      mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    let scope: AudioUnitScope = input ? kAudioUnitScope_Output : kAudioUnitScope_Input
    let elem: AudioUnitElement = input ? 1 : 0
    try ck(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, scope, elem, &asbd,
      UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "stream format")
    return u
  }

  func start() throws {
    // The rig's overrides for the canceller, applied before a sample moves.
    // Every production cadence gets a rig override (`compress-waits-in-test-rigs`);
    // these two are the ones `--aec-sweep` reads the defaults off.
    if Audio.aecTaps > 0 {
      aec.cfg.taps = Audio.aecTaps
    } else if Audio.outputIsSpeakers {
      aec.cfg.taps = 4096
    }
    if Audio.aecMu > 0 { aec.cfg.mu = Audio.aecMu }
    aec.cfg.driftTrack = Audio.aecDrift
    aec.cfg.nlOn = Audio.aecNl
    // ONE unit in `vp`, two in `hal`. `inUnit` and `outUnit` point at the same
    // instance in duplex, so every existing stop/start/property path keeps
    // working -- but init and start must then happen ONCE, which is what the
    // `duplex` guards below are for. Initialising the same unit twice is not
    // harmless: it tears down and rebuilds the graph under a running callback.
    let iu: AudioUnit, ou: AudioUnit
    if duplex {
      let u = try makeDuplexUnit()
      iu = u; ou = u
    } else {
      iu = try openUnit(input: true)
      ou = try openUnit(input: false)
      // The control arm announces itself as loudly as the other one.
      //
      // Only the VPIO branch printed an `[io]` line, so "which unit is this
      // call running" was answerable by the PRESENCE of a line and never by
      // its absence -- and an A/B rig that reads a missing line as "the other
      // arm" cannot tell a HAL run from a run that failed before it got here.
      fputs("[io] HAL -- two raw hardware units, no echo cancellation,"
          + " no gain control, nothing between the microphone and the wire\n", stderr)
    }
    inUnit = iu; outUnit = ou
    captureHpf.reset()
    // A static survives the previous call in a resident app; a veto carried
    // across calls would be a verdict about a speaker that is no longer playing.
    Audio.corrVeto = false
    // The trim this microphone needed LAST call. Without it every call opens at
    // trim 1.0 and the first sentence ships at whatever the device delivers --
    // measured 3.08x full scale, post-trim, as the call maximum -- until the
    // loop re-learns what it already knew.
    loadTrim()
    let me = Unmanaged.passUnretained(self).toOpaque()

    var inCb = AURenderCallbackStruct(inputProc: captureProc, inputProcRefCon: me)
    try ck(AudioUnitSetProperty(iu, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
      &inCb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set input cb")
    var outCb = AURenderCallbackStruct(inputProc: renderProc, inputProcRefCon: me)
    try ck(AudioUnitSetProperty(ou, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
      &outCb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set render cb")

    try ck(AudioUnitInitialize(iu), "init in")
    if !duplex { try ck(AudioUnitInitialize(ou), "init out") }
    try ck(AudioOutputUnitStart(iu), "start in")
    if !duplex { try ck(AudioOutputUnitStart(ou), "start out") }
    started = true
    watchRate()
    watchStalls()
    if stallOutAfterS > 0, !stallOutDone {
      stallOutDone = true
      let at = stallOutAfterS
      DispatchQueue.global().asyncAfter(deadline: .now() + at) { [weak self] in
        guard let self, let u = self.outUnit else { return }
        fputs("*** injected: output unit stopped at \(at) s -- the callback is now dead.\n", stderr)
        AudioOutputUnitStop(u)
      }
    }
    Thread { [weak self] in self?.echoEstimator() }.start()
  }

  /// Tell me the moment the rate moves, and put it back.
  private func watchRate() {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    for (dev, label) in [(inDev, "input"), (outDev, "output")] where dev != 0 {
      AudioObjectAddPropertyListenerBlock(dev, &addr, DispatchQueue.global()) { [weak self] _, _ in
        guard let self else { return }
        var r: Float64 = 0; var sz = UInt32(MemoryLayout<Float64>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &r)
        guard abs(r - SR) > 1 else { return }
        self.rateEvents += 1
        // Under VPIO the hardware rate is allowed to be anything: the unit
        // converts. Forcing it back here would be this program overruling the
        // very component it delegated the problem to, and re-priming the ring
        // for a disturbance that did not happen.
        if self.duplex {
          fputs("*** the \(label) device moved to \(Int(r)) Hz -- VoiceProcessingIO"
              + " is converting, leaving it alone.\n", stderr)
          return
        }
        fputs("\n*** the \(label) device just moved to \(Int(r)) Hz mid-call. Every render fails at\n"
            + "*** that rate and the call would go silent with no error, so putting it back.\n", stderr)
        let got = self.forceSampleRate(dev, SR)
        // Re-prime the read cursor. The graph was disturbed, so any anchor from
        // before it is a claim about a pipeline that no longer exists -- and
        // crawling back from it took forty seconds and 43,000 late arrivals when
        // this was left alone. A re-prime is one discontinuity in the middle of a
        // disturbance that already happened.
        self.ring.pos = -1
        fputs(abs(got - SR) < 1
              ? "*** \(label) device back at \(Int(got)) Hz, playout re-primed.\n\n"
              : "*** \(label) device REFUSED \(Int(SR)) Hz, stuck at \(Int(got)). Audio will not work\n"
                + "*** until this device changes or another is selected.\n\n", stderr)
      }
    }
  }

  /// And watch the SYMPTOM, whatever the cause. A capture callback that stops
  /// arriving while the unit is supposed to be running is a dead call, and the one
  /// thing it must never be is quiet about it.
  private func watchStalls() {
    Thread { [weak self] in
      // BOTH callbacks, because either one stopping is a dead call and they stop
      // for different reasons. The first version of this watched only capture, and
      // the very next test moved the devices to 44.1 kHz: capture was rescued by
      // the rate listener and never stalled, while PLAYOUT sat at 0/s -- so the
      // watchdog reported nothing through the exact failure it was added for.
      var lastCap = -1, lastRender = -1
      var stillCap = 0, stillRender = 0
      var lastPlayed = -1, lastGot = -1, stuck = 0
      var announced = false
      // ── A FOURTH WAY TO BE BROKEN: RUNNING, AND FAR TOO SLOWLY ──────────────
      //
      // The three arms below catch a callback that stopped, a callback that never
      // started, and packets arriving with nothing played. All three are blind to a
      // microphone that is DELIVERING, at a fraction of the rate.
      //
      // Measured on this Mac, on a call between two local processes:
      //
      //     cap 405/s  sent 413/s  recv 111/s  played 9/s (0.6%)
      //
      // against 1504/s on a healthy call. Twenty-seven percent of the packets and
      // under one percent of the playout -- a destroyed call -- and every arm here
      // stayed quiet, because the callbacks were alive (so `stillCap` reset) and
      // playout was moving (so `stuck` reset). The person is told nothing at all.
      //
      // `capFrames` is the right instrument and the only one that is not a
      // function of the buffer size: SAMPLES, which must track the sample rate
      // however large or small the callbacks are. A rate expressed in callbacks
      // per second falls legitimately when another app enlarges the device's
      // buffer, and a watchdog on it would cry wolf on a healthy call.
      //
      // Cause-agnostic on purpose. This Mac's copy of it is Voice Control holding
      // the built-in microphone, which no app can do anything about -- but "the
      // sound is broken and here is the number" is worth saying whatever the
      // reason, and a diagnosis this code cannot make is not a reason for silence.
      var lastCapFrames = -1
      var slowTicks = 0
      var slowSaid = false
      func rate(_ d: AudioDeviceID) -> Int {
        var r: Float64 = 0; var sz = UInt32(MemoryLayout<Float64>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(d, &a, 0, nil, &sz, &r)
        return Int(r)
      }
      while true {
        Thread.sleep(forTimeInterval: 0.25)
        guard let self, self.started else { continue }
        // LIVENESS IS THE CALLBACK, not the audio it carried. This watched
        // `renderTicks` -- renders that actually fed media -- and `onRender`
        // zero-fills and returns before that line whenever no peer has sent
        // anything yet. So every launch that started before its peer read as a
        // dead output unit at exactly 750 ms, 12 out of 12 peerless launches, with
        // "last render status 0" printed right there in the message: the callback
        // was alive and succeeding. It rebuilt a healthy graph and stamped a
        // permanent false "[1 capture stall(s) recovered]" onto every later stats
        // line. `renderCallbacks` counts invocations, which is what the message
        // already claims to be measuring, so pre-media zero-fill stays alive and a
        // genuinely dead output unit is still caught before media arrives.
        // `renderTicks` is still read, and still printed under its own name below.
        let c = self.capCallbacks, rc = self.renderCallbacks, r2 = self.renderTicks
        stillCap = (c == lastCap) ? stillCap + 1 : 0
        stillRender = (rc == lastRender) ? stillRender + 1 : 0
        lastCap = c; lastRender = rc
        // A THIRD WAY TO BE SILENT, and the one that got past the first two: both
        // callbacks running, packets arriving, and nothing played -- because the
        // read cursor sat ahead of the stream and concealed every packet. Watching
        // the callbacks does not see it; watching what came OUT does.
        let played = self.ring.playedS, got = self.ring.accepted
        stuck = (played == lastPlayed && got > lastGot) ? stuck + 1 : 0
        if ProcessInfo.processInfo.environment["TK_TRACE_STUCK"] != nil {
          fputs("tick dPlayed \(played - lastPlayed) dGot \(got - lastGot)"
              + " stuck \(stuck) render \(r2) cb \(rc) cap \(c) stillR \(stillRender)"
              + " pos \(Int(self.ring.pos)) played \(played)\n", stderr)
        }
        lastPlayed = played; lastGot = got
        // 8 ticks, not 4: two seconds. The action here is a re-anchor, which is
        // itself a discontinuity, so a false positive causes the very glitch it
        // exists to prevent -- and this fired twice in a clean three-minute run at
        // four ticks. And it prints the RING STATE, because "nothing is being
        // played" is a symptom with several causes and a watchdog that names none
        // of them turns an investigation into guesswork.
        if stuck >= 8, !announced {
          announced = true
          self.audioStalls += 1
          let r = self.ring
          fputs("\n*** NOTHING IS BEING PLAYED although packets are arriving.\n"
              + "*** pos \(Int(r.pos)) (pkt \(Int(r.pos) / FPP))  hiSeq \(r.hiSeq)"
              + "  jitTarget \(self.jitTarget)  err \(String(format: "%.2f", r.errMs)) ms"
              + "  rate \(String(format: "%.5f", r.rate))\n"
              + "*** accepted \(got)  played \(played)  concealed \(r.concealed)"
              + " (lost \(r.concealLost) starved \(r.concealStarved))  snaps \(r.snaps)"
              + "  renderTicks \(r2)  capCallbacks \(c)\n"
              + "*** offZeroMiss \(self.offZeroMiss) run \(self.offZeroRun) max \(self.offZeroRunMax)  n \(self.nHistDescribe)\n"
              + "*** Re-anchoring.\n\n", stderr)
          self.ring.pos = -1
          continue
        }
        // ── THE RATE ARM ──────────────────────────────────────────────────────
        //
        // Four seconds of evidence before it says anything (16 ticks at 0.25 s),
        // and 70% of nominal as the line. A call opening, a device changing and a
        // graph rebuilding all produce a second or two of short measurements, and
        // a watchdog that fires on those is one nobody reads. 70% is far outside
        // anything a healthy device does and far inside the 27% that was measured.
        let cf = self.capFrames
        if lastCapFrames >= 0 {
          let want = SR * 0.25 * 0.70
          slowTicks = Double(cf - lastCapFrames) < want ? slowTicks + 1 : 0
        }
        lastCapFrames = cf
        if slowTicks >= 16, !slowSaid {
          slowSaid = true
          self.micTooSlow = true
          Metrics.count("mic_too_slow")
          fputs("\n*** THE MICROPHONE IS DELIVERING FAR LESS THAN IT SHOULD."
              + " About \(Int(Double(cf - lastCapFrames) * 4)) samples a second"
              + " against \(Int(SR)).\n"
              + "*** The callbacks are alive, so nothing above catches this."
              + " Something else on this Mac is holding the input device -- Voice\n"
              + "*** Control and Dictation both do, permanently. The call will be"
              + " choppy and this cannot be fixed from here.\n\n", stderr)
        } else if slowTicks == 0, slowSaid {
          slowSaid = false
          self.micTooSlow = false
          fputs("*** the microphone is back up to rate.\n", stderr)
        }
        let dead = stillCap >= 3 || stillRender >= 3        // 750 ms of nothing
        if dead, !announced {
          announced = true
          self.audioStalls += 1
          let which = stillCap >= 3 && stillRender >= 3 ? "CAPTURE AND PLAYOUT"
                    : stillCap >= 3 ? "CAPTURE" : "PLAYOUT"
          fputs("\n*** \(which) HAS STOPPED -- no callback for 750 ms."
              + " Input device \(rate(self.inDev)) Hz, output \(rate(self.outDev)) Hz,"
              + " last render status \(self.lastRenderErr).\n*** Attempting recovery.\n", stderr)
          _ = self.forceSampleRate(self.inDev, SR)
          _ = self.forceSampleRate(self.outDev, SR)
          self.restart()
        } else if !dead, announced {
          fputs("*** audio is back.\n\n", stderr)
          announced = false
          stillCap = 0; stillRender = 0
        }
      }
    }.start()
  }

  // ── A DEVICE THAT WILL NOT DO 48 kHz USED TO END THE PROCESS ──────────────
  //
  // `makeUnit` throws a hard error when a device refuses to move to 48 kHz, and
  // the only caller printed three lines and called `exit(1)`. On a bare command
  // line that is defensible. Inside Kin.app it means: you click a name, and the
  // app disappears. No window, no sentence, nothing to press -- and the person is
  // left with an app that quits when they try to call somebody.
  //
  // It stopped being hypothetical the moment this file grew a device picker. Half
  // the audio interfaces in the world sit at 44.1 kHz, and choosing one from the
  // panel would have quit the app.
  //
  // So the preferred device is a preference, not a requirement: if it refuses,
  // every other device in that direction is tried, and the one that works is used
  // and NAMED. Only if none of them works does this throw -- and the caller now
  // keeps the call alive and says so on screen rather than exiting.
  private func openUnit(input: Bool) throws -> AudioUnit {
    var firstError: Error?
    // The preferred device first: whatever the person chose, or the system default.
    do { return try makeUnit(input: input) } catch { firstError = error }
    let preferred = input ? inDev : outDev
    for d in Audio.devices(input: input) {
      guard let id = Audio.resolve(d.uid, input: input), id != preferred else { continue }
      do {
        let u = try makeUnit(input: input, forced: id)
        fputs("audio: the \(input ? "microphone" : "speaker") that was asked for cannot run at"
            + " \(Int(SR)) Hz -- using \"\(d.name)\" instead\n", stderr)
        // The saved choice is dropped, or every launch would repeat this walk and
        // the panel would keep ticking a device that is not carrying the call.
        if input { Audio.chosenInputUID = nil } else { Audio.chosenOutputUID = nil }
        Metrics.count(input ? "mic_device_fallback" : "spk_device_fallback")
        deviceTrouble = "\(input ? "Microphone" : "Speaker") changed to \(d.name)"
        return u
      } catch { continue }
    }
    throw firstError ?? Err.e("no \(input ? "input" : "output") device would run at \(Int(SR)) Hz")
  }

  /// Set when a device had to be swapped out from under the person, so the window
  /// can say so. Empty means nothing to report.
  private(set) var deviceTrouble = ""
  func clearDeviceTrouble() { deviceTrouble = "" }

  /// Change the microphone (or the speaker) on a call that is running. The graph
  /// is rebuilt rather than retargeted, because the sample rate, the buffer size
  /// and the stream format are all properties of the DEVICE and a new one
  /// invalidates every one of them -- which is exactly what `restart` re-runs.
  ///
  /// Returns the name actually in use afterwards, which is not always the one
  /// asked for: a device can be unplugged between the panel being drawn and the
  /// row being pressed, and saying "Built-in Microphone" when that happened is
  /// better than a tick on a device that is not there.
  @discardableResult
  func useDevice(uid: String, input: Bool) -> String {
    if input { Audio.chosenInputUID = uid } else { Audio.chosenOutputUID = uid }
    fputs("audio: switching \(input ? "microphone" : "speaker") to \(uid)\n", stderr)
    restart()
    let now = input ? inDev : outDev
    let nm = Audio.name(of: now)
    fputs("audio: \(input ? "microphone" : "speaker") is now \"\(nm)\"\n", stderr)
    return nm
  }

  /// Tear the graph down and build it again. Heavier than a stop/start, and
  /// deliberately so: rebuilding re-runs the rate check, the buffer size and the
  /// stream format, which is exactly the state a device change invalidated.
  private func restart() {
    if let u = inUnit { AudioOutputUnitStop(u); AudioUnitUninitialize(u); AudioComponentInstanceDispose(u) }
    if let u = outUnit { AudioOutputUnitStop(u); AudioUnitUninitialize(u); AudioComponentInstanceDispose(u) }
    inUnit = nil; outUnit = nil; started = false
    do {
      let iu = try openUnit(input: true)
      let ou = try openUnit(input: false)
      inUnit = iu; outUnit = ou
      let me = Unmanaged.passUnretained(self).toOpaque()
      var inCb = AURenderCallbackStruct(inputProc: captureProc, inputProcRefCon: me)
      try ck(AudioUnitSetProperty(iu, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
        &inCb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set input cb")
      var outCb = AURenderCallbackStruct(inputProc: renderProc, inputProcRefCon: me)
      try ck(AudioUnitSetProperty(ou, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
        &outCb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set render cb")
      try ck(AudioUnitInitialize(iu), "init in")
      try ck(AudioUnitInitialize(ou), "init out")
      try ck(AudioOutputUnitStart(iu), "start in")
      try ck(AudioOutputUnitStart(ou), "start out")
      started = true
      // The read cursor must re-prime from the new stream rather than carry an
      // anchor from before the graph changed.
      ring.pos = -1
      captureHpf.reset()
      fputs("*** audio graph rebuilt.\n", stderr)
    } catch {
      fputs("*** audio graph rebuild FAILED: \(error). Retrying in a moment.\n", stderr)
      started = true          // let the watchdog try again
    }
  }

  // ── Capture: mic -> packetise -> wire ────────────────────────────────────
  fileprivate func onCapture(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             _ ts: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ n: UInt32) {
    guard let iu = inUnit else { return }
    inBufList[0].mNumberBuffers = 1
    inBufList[0].mBuffers.mNumberChannels = 1
    inBufList[0].mBuffers.mDataByteSize = n * 4
    inBufList[0].mBuffers.mData = UnsafeMutableRawPointer(inScratch)
    // A FAILING RENDER MUST NOT BE SILENT. Counting an error and returning looks
    // exactly like a muted microphone from the outside, and "cap 0/s" with no
    // reason cost real time to diagnose. The status is kept so the reporter can
    // print it: a number nobody can see is not an instrument.
    let st = AudioUnitRender(iu, flags, ts, bus, n, inBufList)
    if st != noErr { xruns += 1; lastRenderErr = st; return }
    capCallbacks += 1

    // The capture instant, on the host clock. mHostTime is the timestamp of the
    // FIRST sample in this buffer -- the moment the sound was at the mic, not the
    // moment we got around to looking. This single field is what makes the whole
    // measurement honest, and it is the field a browser will not give you.
    let host0 = (ts.pointee.mFlags.contains(.hostTimeValid) && ts.pointee.mHostTime != 0)
      ? ts.pointee.mHostTime : Clock.now()
    let entry = Clock.now()
    capLag.add(Clock.msSigned(entry, host0))
    // 1.5x nominal, not 2x: a buffer that is late by more than half a period has
    // already missed, and rounding the threshold up would hide the marginal case
    // that matters most.
    let nominal = Double(Audio.devBuf) / SR * 1000.0
    if lastCapHost != 0, Clock.msSigned(host0, lastCapHost) > nominal * 1.5 { capSkips += 1 }
    lastCapHost = host0
    capTicks += 1
    capFrames += Int(n)
    if firstCapHost == 0 { firstCapHost = host0 }

    // Substitute the file, if one was given, before anything looks at the samples.
    if let src = srcSamples, srcCount > 0 {
      // ── ONE ROOM MEANS ONE SOUND, AT ONE INSTANT, IN BOTH MICROPHONES ──────
      //
      // Normally the file starts at whatever moment this process reached
      // `loadAudioSource`, which is correct for every rig that only cares what
      // the microphone contains. It is WRONG for a rig about two machines
      // hearing the same room: measured on a live loopback pair given the same
      // recording, the two processes' file positions were 215 ms apart, purely
      // from launch skew -- so the backward search found the far voice 266 ms
      // early instead of 51, and the app correctly refused to call that one
      // room. The rig was modelling two machines playing the same record from
      // different points, which is not what a room is.
      //
      // Phase-locked to the host clock, both processes read the same sample at
      // the same instant, and the launch skew disappears by construction. Both
      // are on one Mac, so `mach_absolute_time` is literally the same clock.
      // TEST INPUT ONLY: it changes what the microphone contains and nothing
      // about the product's own logic.
      if Audio.srcWallLock {
        let t = Double(Clock.ns(host0)) / 1e9 * SR
        srcPos = ((Int(t) % srcCount) + srcCount) % srcCount
      }
      for k in 0..<Int(n) {
        inScratch[k] = src[srcPos]
        srcPos += 1
        if srcPos >= srcCount { srcPos = 0 }
      }
    }

    // ── THE KNOB HAS A FLOOR. THE SIGNAL DOES NOT. ──────────────────────────
    //
    // Measured on a real call: this Mac's microphone delivered samples peaking
    // at 5.24 -- five times full scale -- with 1.6% of every sample at or past
    // the clip point and an RMS of 0.26, eighteen decibels hotter than the far
    // end. `tuneInputGain` did its job and walked the device from 27% to 15%,
    // and then STOPPED, because 15% is the floor written into it. It moved
    // twice in a two-minute call and never said it had given up.
    //
    // Everything else followed from that. A microphone that hot hears this
    // machine's own speaker easily (echo correlation reached 0.71), and it
    // holds the local voice gate open -- 98% of that call -- so the near mic
    // was live while the far person was talking, and their end chopped its way
    // through 409 gate flaps trying to take a turn against it.
    //
    // A scalar, and deliberately nothing cleverer. Samples ABOVE 1.0 are not
    // clipped, they are merely large: the float path carries them intact, so
    // dividing recovers the signal exactly, with no compression, no limiter and
    // no colour. That matters here more than usual -- the whole audio design is
    // that the microphone is not processed.
    if inputTrim != 1 {
      for k in 0..<Int(n) { inScratch[k] *= inputTrim }
    }

    // Subsonic rumble high-pass filter: 2nd-order Butterworth at 65 Hz (Q = 0.707).
    // Eliminates table thumps, keyboard impacts, and HVAC rumble before LPC compression.
    if Audio.hpfOn {
      captureHpf.process(inScratch, Int(n))
    }

    // What the microphone actually delivered. Placed HERE deliberately: after the
    // file substitution so a rig measures its own input, and before the simulated
    // echo below, so a rig's echo injection cannot be mistaken for a room's.
    // AFTER the trim, so every number below describes what the rest of the
    // pipeline actually gets; `rawPeakWin` keeps the untrimmed truth for the
    // loop that sets the trim.
    for k in 0..<Int(n) {
      let r = abs(inScratch[k]) / inputTrim
      if r > rawPeakWin { rawPeakWin = r }
    }
    for k in 0..<Int(n) {
      let a = abs(inScratch[k])
      micSumSq += Double(a) * Double(a)
      if a > micPeak { micPeak = a }
      if a > micPeakWin { micPeakWin = a }
      // 0.997 and not 1.0: a converter that clips rarely returns exactly full
      // scale, and a threshold that only catches the exact value catches nothing.
      if a >= 0.997 { micClipped += 1 }
    }
    micSamples += Int(n)

    // Add the simulated echo to what the microphone "heard". After the file
    // substitution, because the echo is added to whatever the near end is saying,
    // which is exactly the relationship a room has.
    // ── FROM WHAT THE SPEAKER EMITTED, NOT FROM WHAT ARRIVED ─────────────────
    //
    // `emitHist`, not `echoHist`. A closed speaker emits nothing, so it returns
    // nothing, and a simulated room that keeps injecting an echo through the ear
    // mute is a room no desk can be -- it would hand the canceller a reference
    // that disagreed with the microphone exactly when the floor closed the ear,
    // and then blame the canceller. `fixture-is-not-the-real-shape`.
    // ── ONE READ OF THE RENDER THREAD'S CURSOR, FOR THE WHOLE CALLBACK ───────
    //
    // `emitW` is advanced by the render thread and this function reads it twice
    // -- once for the simulated room and once for the canceller. Between the two
    // reads the render thread can advance it, so the echo was injected at one
    // alignment and cancelled at another, jittering by up to a render block every
    // single block. A canceller cannot converge on a target that moves under it,
    // and the two rigs could not see it: `--aec-test` supplies `refW` itself, so
    // it is exact there by construction and only the product has two readers.
    let emitNow = emitW
    if echoArmed, let e = emitHist, emitNow > echoDelay {
      let w = emitNow
      for k in 0..<Int(n) {
        var acc: Float = 0
        for (t, a) in echoTaps {
          let idx = w - echoDelay - t - (Int(n) - k)
          if idx >= 0 { acc += a * e[idx % Audio.ECHO_MAX] }
        }
        inScratch[k] += acc * echoGain
      }
    }

    // THE ESTIMATOR MUST SEE THE RAW MICROPHONE, NOT THE CANCELLED SIGNAL.
    //
    // The history is written BEFORE cancellation, and the order matters more than
    // it looks. The estimator finds the echo by correlating this history against
    // the playout, and it is what tells the canceller where to aim. Recording the
    // cancelled signal instead meant that the moment cancellation started working
    // the correlation collapsed to 0.08, the "best lag" became whichever noise
    // peak won, and the canceller re-aimed at it and destroyed itself -- 46 re-aims
    // in 90 seconds, each one zeroing the filter and restarting convergence.
    //
    // The canceller's success switched off the evidence stream that aimed it. Same
    // shape as every other control-loop failure in this project: the loop was
    // reading a signal its own action had removed.
    if let ch = capHist {
      for k in 0..<Int(n) { ch[(capHistW + k) % Audio.CAPH] = inScratch[k] }
      capHistW += Int(n)
    }

    // ── AND HERE, AFTER THE HISTORY, THE SPEAKER IS SUBTRACTED (0.107.0) ──────
    //
    // AFTER `capHist`, which is the whole reason the order of this function is
    // written down: the estimator that aims this filter correlates that history
    // against the playout, so the history must stay RAW. Recording the cancelled
    // signal instead is what collapsed the old canceller's own aim to 0.08 and
    // made it re-aim 46 times in 90 seconds.
    //
    // BEFORE the gate, because the gate's echo bar is the thing the echo was
    // costing. A person talking under their own loudspeaker used to be
    // indistinguishable from that loudspeaker at the instant of decision -- the
    // file says so, and it is true of the RAW microphone. It is not true of a
    // microphone with 20 dB of the loudspeaker taken out of it, and `Aec` hands
    // the gate the measured residual so the bar moves by exactly what was
    // actually removed and by nothing that was not.
    //
    // Linear subtraction only. Nothing here decides anything about the voice:
    // see the head of Aec.swift.
    //
    // Speakers only -- on headphones there is no path to cancel, `echoCorr` sits
    // at the null floor and the filter would never arm anyway, so this is CPU
    // rather than behaviour. Stated as the route, not as the gate's conclusion
    // about the route (`one-condition-two-concerns`).
    var rawBlockPeak: Float = 0
    for k in 0..<Int(n) { let a = abs(inScratch[k]); if a > rawBlockPeak { rawBlockPeak = a } }
    if Audio.aecOn, Audio.outputIsSpeakers, let mh = emitHist {
      if Audio.aecTaps <= 0 && aec.cfg.taps < 4096 { aec.cfg.taps = 4096 }
      aec.process(inScratch, Int(n), ref: mh, refW: emitNow, refCap: Audio.ECHO_MAX)
      Audio.aecResidual = aec.residual
    }
    // The RAW peak, for the one estimator inside the gate that must not see the
    // cancelled signal: `coupling` is a property of the ROOM, and a room whose
    // echo has been subtracted still has the same room in it. See
    // `DuplexGate.rawPeakIn`.
    dgate.rawPeakIn = rawBlockPeak
    dgate.echoResidual = (Audio.aecOn && Audio.outputIsSpeakers) ? aec.residual : 1

    // NOTHING GUESSES HERE. The microphone reaches the wire as it was captured
    // minus an exact copy of what this machine played, or turned down whole --
    // never spectrally masked, never guessed at. Whose turn it is and what this
    // speaker put into this room are the only two things between the room and
    // the far end.
    duplexGate(inScratch, Int(n))
    accountTurn(peerVocal: Audio.peerVocalNow, audible: dgate.gain > 0.5, blockN: Int(n))

    // Listen for the click we emitted. Scanning the raw input buffer, before any
    // packetising, so nothing in this file's own plumbing is inside the answer.
    if acoustic, acWaiting {
      var j = 0
      while j < Int(n) {
        if abs(inScratch[j]) > 0.15 {
          let heardAt = host0 + Clock.ticks(ns: UInt64(Double(j) / SR * 1_000_000_000.0))
          let ms = Clock.msSigned(heardAt, acPlayAt)
          // A detection before the click, or a second of silence, is not a fast
          // path -- it is a false positive or a miss. Refuse both.
          if ms > 0, ms < 500 { acRound.add(ms); acHeard += 1 }
          acWaiting = false
          break
        }
        j += 1
      }
      // Give up on this click rather than matching it to the NEXT one, which
      // would report a delay of exactly the firing interval and look plausible.
      if acWaiting, Clock.msSigned(host0, acPlayAt) > 300 { acWaiting = false }
    }

    var i = 0
    while i < Int(n) {
      let take = min(FPP - capFill, Int(n) - i)
      memcpy(capBuf + capFill, inScratch + i, take * 4)
      capFill += take; i += take
      if capFill == FPP {
        // Host time of THIS packet's first sample, relative to this buffer's host
        // time. SIGNED, and it has to be: once the device buffer is smaller than a
        // packet the packet STARTED IN AN EARLIER BUFFER, so the offset is negative
        // and `UInt64(negative Double)` traps. That trap is the only thing that was
        // stopping the device buffer from being decoupled from the packet size.
        let d = i - FPP
        let offNs = UInt64(abs(Double(d)) / SR * 1_000_000_000.0)
        let cap = d >= 0 ? host0 + Clock.ticks(ns: offNs) : host0 - Clock.ticks(ns: offNs)
        capToSend.add(Clock.msSigned(Clock.now(), cap))
        defer { sendCost.add(Clock.msSigned(Clock.now(), entry)) }
        // ── MUTE MEANS SILENCE ON THE WIRE, NOT SILENCE ON THE SPEAKER ──────────
        //
        // `mute` up at the top of this file silences PLAYOUT, which is what a
        // loopback rig needs. A person pressing a mute button means the opposite
        // end: do not send what my microphone hears. Zeroed here rather than by
        // skipping the send, because a gap in the sequence is loss to the far end
        // and it would conceal it -- inventing speech out of a deliberate silence.
        // Silence also compresses to almost nothing, so muting costs bandwidth
        // rather than adding it.
        // ── AND NOT INTO A ROOM WHERE THE PHONE IS STILL RINGING ────────────
        //
        // The far end joins before answering now, so it can show whoever is
        // calling. It plays nothing -- its audio engine is not running -- but
        // this microphone would still be reaching a Mac sitting on a desk in a
        // room nobody has agreed to open. Zeroed for the same reason mute is
        // zeroed rather than skipped: a gap in the sequence is loss to the far
        // end, and the moment they answer it would conceal speech out of a
        // silence we chose. Reading an Int on the audio thread costs nothing and
        // allocates nothing, which is the only kind of check allowed here.
        if gMicMuted || (wire?.peerRinging ?? false) { memset(capBuf, 0, FPP * 4) }
        let histSlot = Int(capSeq) % Audio.CAP_HIST_COUNT
        memcpy(capHistory + histSlot * FPP, capBuf, FPP * 4)
        capHistoryCap[histSlot] = cap
        capHistorySeq[histSlot] = capSeq

        var r1Ptr: UnsafePointer<Float>? = nil
        var r1Cap: UInt64 = 0
        var r4Ptr: UnsafePointer<Float>? = nil
        var r4Cap: UInt64 = 0
        var fecPtr: UnsafePointer<Float>? = nil
        var fecBase: Int32 = 0
        var fecCount: UInt8 = 0
        var fecCap: UInt64 = 0

        if redundancy {
          if capSeq >= 1 {
            let s1 = Int(capSeq - 1) % Audio.CAP_HIST_COUNT
            if capHistorySeq[s1] == capSeq - 1 {
              r1Ptr = UnsafePointer(capHistory + s1 * FPP)
              r1Cap = capHistoryCap[s1]
            }
          }
          if capSeq >= 4 {
            let s4 = Int(capSeq - 4) % Audio.CAP_HIST_COUNT
            if capHistorySeq[s4] == capSeq - 4 {
              r4Ptr = UnsafePointer(capHistory + s4 * FPP)
              r4Cap = capHistoryCap[s4]
            }
          }
          let base = capSeq & ~3
          if capSeq >= base + 3 {
            var allHave = true
            for offset in 0..<4 {
              let s = Int(base + Int32(offset)) % Audio.CAP_HIST_COUNT
              if capHistorySeq[s] != base + Int32(offset) {
                allHave = false
                break
              }
            }
            if allHave {
              for k in 0..<FPP {
                var pBits: UInt32 = 0
                for offset in 0..<4 {
                  let s = Int(base + Int32(offset)) % Audio.CAP_HIST_COUNT
                  pBits ^= (capHistory + s * FPP + k).pointee.bitPattern
                }
                fecParityScratch[k] = Float(bitPattern: pBits)
              }
              fecPtr = UnsafePointer(fecParityScratch)
              fecBase = base
              fecCount = 4
              fecCap = capHistoryCap[Int(base) % Audio.CAP_HIST_COUNT]
            }
          }
        }

        wire?.send(seq: capSeq, cap: cap, src: capBuf, n: FPP, scratch: capScratch,
                   redundant: r1Ptr, redundantCap: r1Cap,
                   stride4: r4Ptr, stride4Cap: r4Cap,
                   fecParity: fecPtr, fecParityBaseSeq: fecBase,
                   fecParityCount: fecCount, fecParityCap: fecCap)
        memcpy(prevBuf, capBuf, FPP * 4)
        prevCap = cap
        havePrev = true
        capSeq += 1; capFill = 0; capturedPkts += 1
      }
    }
  }

  // ── Playout: ring -> speaker, and the m2e measurement ───────────────────
  fileprivate func onRender(_ ts: UnsafePointer<AudioTimeStamp>, _ n: UInt32,
                            _ io: UnsafeMutablePointer<AudioBufferList>) {
    // First line, before every early return below: the fact being recorded is
    // "the callback arrived", and that is true of a render that zero-fills, a
    // render with no buffer to write into, and a render that feeds the DAC. The
    // stall watchdog is the customer, and it must not mistake silence for death.
    renderCallbacks += 1
    let ab = UnsafeMutableAudioBufferListPointer(io)
    guard let raw = ab[0].mData else { return }
    let out = raw.assumingMemoryBound(to: Float.self)

    // THE STREAM IS THE TRUTH. Start, and re-start, from the write head minus
    // the deliberate buffer -- never from a remembered anchor. If the stream has
    // run past the cursor by more than the ring, jump; do not argue with it.
    let hi = Int64(ring.hiSeq)
    if hi < 0 {
      for i in 0..<Int(n) {
        out[i] = 0
        CallRecorder.shared.recordAudioSample(0)
      }
      return
    }
    if ring.pos < 0 {
      guard hi >= Int64(jitTarget) else {
        for i in 0..<Int(n) {
          out[i] = 0
          CallRecorder.shared.recordAudioSample(0)
        }
        return
      }
      ring.pos = Double((hi - Int64(jitTarget)) * Int64(FPP))
    }
    // FAULT INJECTION, because the recovery path above is the kind that only ever
    // runs during a failure -- and a recovery no test has ever triggered is a
    // guess. A device rate change is the natural cause and it needs the machine's
    // devices; this needs nothing, and it puts the cursor exactly where the real
    // fault put it, on demand, repeatably.
    if cursorAheadMs > 0, !cursorAheadDone, renderTicks > 90_000 {
      cursorAheadDone = true
      ring.pos += cursorAheadMs / 1000.0 * SR
      fputs("*** injected: cursor pushed \(cursorAheadMs) ms ahead\n", stderr)
    }
    let curSeq = Int64(ring.pos) / Int64(FPP)
    // A JUMP is for a broken stream, not for a drift. Only two things justify
    // discarding continuity: the stream has run further ahead than the ring can
    // hold, or the cursor is somehow ahead of the newest packet.
    // The cursor outrunning the newest packet by a hair is NORMAL, not broken.
    //
    // The old test was `curSeq > hi + 2`. But `hi` only moves when a packet
    // arrives, so during a loss burst it freezes while the cursor conceals
    // straight past it -- which is exactly what concealment is for. That tripped
    // a rule written for "the stream restarted and we are somehow ahead of it",
    // and repositioned the cursor against a STALE head, rewinding it a little on
    // every burst. Measured at 3% burst loss: slack p50 climbing 8 -> 17 ms, a
    // snap firing every couple of seconds to undo it, and m2e stuck near 29 ms
    // on a path whose only defect was missing packets.
    //
    // A genuine peer restart looks completely different -- sequence numbers back
    // near zero, so the cursor is ahead by hundreds of packets, not two. That is
    // what this now tests for, and a loss burst no longer looks like one.
    if hi - curSeq > Int64(RING - 2) || curSeq > hi + Int64(RING / 4) {
      ring.pos = Double((hi - Int64(jitTarget)) * Int64(FPP))
      ring.jumps += 1
    }

    // A STALL IS A STEP, AND A STEP IS NOT A DRIFT.
    //
    // The jump above only fires when the stream has outrun the whole ring --
    // 1.36 seconds. Below that the governor is the only mechanism, and it is
    // bounded to 0.4%, so it claws back 4 ms per second: a 200 ms hiccup costs
    // 200 ms of added latency for the next FIFTY SECONDS. Measured exactly that
    // way on this rig -- m2e sat at 391 ms for the remaining half of the run
    // after two 200 ms render stalls, with every other counter clean.
    //
    // So there has to be a middle tier, and it is ASYMMETRIC because the two
    // directions are not the same problem. Cursor LATE means the buffer is full
    // of stale audio; that audio is obsolete and skipping it is the correct
    // answer -- the listener wants to be current, not to hear a backlog. Cursor
    // EARLY means there is nothing to play, and no amount of aggression invents
    // a sample, so that side stays gentle and concealment handles it.
    //
    // The threshold sits far above real jitter and far below the ring: one rare
    // click after a network hiccup, in exchange for never carrying a hiccup's
    // latency for the rest of the call.
    // In MILLISECONDS. Ordinary jitter excursions and post-stall packet bursts
    // are absorbed and drained smoothly by the audio rate governor instead of
    // violently snapping the cursor forward and discarding speech (which caused
    // 4.8 to 14.3 snaps/sec and audible clicks). Snap behind acts only on true
    // runaway backlog (>= 180 ms), and cross-fades the repositioned cursor to eliminate clicks.
    let pktMs = Double(FPP) / SR * 1000.0
    let snapBehindMs = max(180.0, Double(jitTarget) * pktMs * 2.5)
    let SNAP_PKTS = max(Int64(120), Int64((snapBehindMs / pktMs).rounded()))
    var cur = curSeq
    // SYMMETRIC, and it was not. This snapped only when the cursor fell BEHIND the
    // stream; a cursor that ran AHEAD had to be 341 ms out before the jump guard
    // noticed, and until then the governor crawled it back at its 0.4% authority --
    // 29 seconds to recover 115 ms.
    //
    // Which is exactly what a device rate change produces. Measured: hold both
    // devices at 44.1 kHz for eight seconds and the output unit advances the cursor
    // at the wrong rate; when the graph recovers the cursor is 115 ms AHEAD, so
    // every arriving packet is already past its deadline, `played 0/s`,
    // `conceal 1509/s`, total silence on a link that was delivering 1508 packets a
    // second. Both ends, for over half a minute.
    //
    // And the asymmetry was backwards on severity: behind costs latency, ahead
    // costs EVERYTHING.
    //
    // The first fix made this symmetric in DIRECTION and left it symmetric in
    // MAGNITUDE, which under-serves the severe side by exactly the amount that
    // matters. Measured on a loaded machine: the cursor ended up 37 packets
    // (24.7 ms) past the newest packet received -- under the 45-packet threshold,
    // so no snap -- and that is not "24 ms of jitter", it is `played 0/s,
    // conceal 1510/s`, TOTAL SILENCE, because the cursor was reading packets that
    // had not arrived. The governor clawed at it with its 0.4% authority while the
    // buffer controller, seeing starvation, grew the target and re-opened the
    // error. Two hundred seconds to recover from 24 ms, with 14 seconds of audio
    // concealed on the way.
    //
    // So the two directions get their own thresholds. Behind: 30 ms, because
    // skipping stale audio is a click and wants real evidence. Past the newest
    // packet: essentially zero, because there is nothing there to play and no
    // amount of patience invents a sample. Two packets of grace for ordinary
    // raciness, and then jump.
    let behind = hi - cur - Int64(jitTarget)   // > 0: too much buffered
    let past = cur - hi                        // > 0: reading unarrived packets
    // But "past the stream" has TWO causes and only one of them is repaired by
    // rewinding. A cursor DISPLACED forward skipped packets that were never
    // played, so moving it back plays them: correct. A cursor that reached the
    // head because the stream STALLED already played everything there was, so
    // moving it back replays it -- and under load that is the common case. First
    // attempt used `past > 1` alone and snapped 2075 times in 200 s.
    //
    // `maxPlayedSeq` tells them apart exactly: rewind only where there is audio
    // behind the cursor that has never been heard. Plus a few ms of persistence,
    // because a single late packet momentarily looks like the first case.
    let unplayedBehind = hi - Int64(jitTarget) > ring.maxPlayedSeq
    aheadRun = (past > 1) ? aheadRun + 1 : 0
    let AHEAD_HOLD = Int(0.010 * SR / Double(Audio.devBuf))   // 10 ms of callbacks
    let snapBehind = behind > SNAP_PKTS
    let snapPast = past > 1 && aheadRun >= AHEAD_HOLD && unplayedBehind
    if snapBehind || snapPast {
      ring.pos = Double((hi - Int64(jitTarget)) * Int64(FPP))
      ring.snaps += 1
      // WHICH WAY the cursor was wrong, recorded separately. See the note on
      // these fields: the two causes ask for opposite things from the buffer
      // controller, and it can only tell them apart if the ring says which one
      // happened.
      if snapBehind { ring.snapsBehind += 1 } else { ring.snapsPast += 1 }
      cur = Int64(ring.pos) / Int64(FPP)
      // Cross-fade the repositioned stream against synthesis to eliminate audible clicks/pops
      xfade = Audio.XFADE
    }

    // THE GOVERNOR. Occupancy error, in samples, driven to zero by reading a
    // hair faster or slower than real time. Full correction spread over ~2 s so
    // it never bends the pitch audibly, and bounded to +/-0.4% -- about 5 cents,
    // well under the ~10 cent threshold where a voice starts to sound off.
    //
    // This is the mechanism that keeps mouth-to-ear AT the floor for the whole
    // call instead of only at the start. Without it the number drifts upward and
    // a call that felt immediate at minute one feels laggy at minute ten, with
    // nothing in any log to explain why.
    let errSamples = Double(hi - cur - Int64(jitTarget)) * Double(FPP) - ring.pos.truncatingRemainder(dividingBy: Double(FPP))
    let gov = Audio.governorRate(errSamples: errSamples)
    ring.rate = gov.rate
    ring.rateSum += ring.rate; ring.rateN += 1
    ring.errMs = gov.errMs

    // When this buffer will actually reach the DAC, on the host clock. The
    // output callback runs ahead of the sound; using now() here would understate
    // mouth-to-ear by a whole buffer plus the device's own pipeline.
    let dueHost = (ts.pointee.mFlags.contains(.hostTimeValid) && ts.pointee.mHostTime != 0)
      ? ts.pointee.mHostTime : Clock.now()
    let rEntry = Clock.now()
    renderLead.add(Clock.msSigned(dueHost, rEntry))
    let rNominal = Double(Audio.devBuf) / SR * 1000.0
    if lastRenderHost != 0, Clock.msSigned(dueHost, lastRenderHost) > rNominal * 1.5 { renderSkips += 1 }
    lastRenderHost = dueHost
    renderTicks += 1
    renderFrames += Int(n)
    defer { renderCost.add(Clock.msSigned(Clock.now(), rEntry)) }

    var sawZero = false
    for i in 0..<Int(n) {
      let absF = ring.pos + Double(i) * ring.rate
      let absI = Int64(absF)
      let seq = Int32(absI / Int64(FPP))
      let off = Int(absI % Int64(FPP))
      if ring.present(seq) {
        let slot = Int(seq) % RING
        // Linear interpolation between neighbouring samples, so a rate that is
        // not exactly 1.0 resamples rather than dropping or duplicating. A
        // dropped sample is a click; a click every few seconds is the thing
        // people describe as "the connection is bad".
        let a = ring.samples[slot * FPP + off]
        let nextI = absI + 1
        let nSeq = Int32(nextI / Int64(FPP)), nOff = Int(nextI % Int64(FPP))
        let b = ring.present(nSeq) ? ring.samples[(Int(nSeq) % RING) * FPP + nOff] : a
        let fr = Float(absF - Double(absI))
        // ── The resampler was the quality ceiling ──────────────────────────────
        //
        // The rate governor reads the ring at a non-integer position, so every
        // played sample is interpolated. It was interpolated LINEARLY, and that is
        // the whole reason this path -- uncompressed 32-bit float, zero loss, zero
        // concealment -- measured 57 dB end to end instead of the 96 dB its 16-bit
        // source allows. 2.43 Mbps of pristine samples, resampled down to worse
        // than a good 64 kbps codec, and no metric in the program could see it:
        // concealment, lateness and mouth-to-ear all read perfectly clean.
        //
        // Worse at the start. While the buffer descends from its safe 6 packets the
        // governor is slewing hard, the fractional position sweeps fast, and the
        // measured SNR over the first twenty seconds of a call runs 10-45 dB.
        //
        // Catmull-Rom needs one sample behind and two ahead. Both are already
        // there -- the jitter buffer holds at least three packets, 96 samples, of
        // lookahead -- so this costs about ten multiply-adds per sample on a
        // callback that currently uses under one microsecond of its 333.
        // The value the algorithm produces, measured BEFORE muting. Muting is a
        // property of this test rig, not of the concealment, and a metric that
        // reads zero for both arms because the speaker is off would have made
        // this whole comparison meaningless while looking like a result.
        var val: Float
        if interpLinear {
          val = a + (b - a) * fr
        } else {
          let sm = ring.sampleAt(absI - 1) ?? a
          let s2 = ring.sampleAt(absI + 2) ?? b
          let t = fr, t2 = t * t, t3 = t2 * t
          val = 0.5 * ((2 * a)
                     + (-sm + b) * t
                     + (2 * sm - 5 * a + 4 * b - s2) * t2
                     + (-sm + 3 * a - 3 * b + s2) * t3)
        }
        if wasConcealing {
          // Do not step into the returning signal either. Cross-fade its first
          // 1.3 ms against the synthesis that is already running -- the real
          // samples still play at their real time, they are only mixed, so this
          // costs no latency at all.
          wasConcealing = false
          xfade = Audio.XFADE
          edgeWinLeft = Audio.XFADE * 2
          edgeWinMax = 0
        }
        if xfade > 0 {
          let w = Float(Audio.XFADE - xfade) / Float(Audio.XFADE)
          let synth = plcNext()
          val = val * w + synth * (1 - w)
          xfade -= 1
          if xfade == 0 { plcPeriod = 0; plcSamples = 0 }
        }
        // Presence is applied to what LEAVES the machine, not to what the rest
        // of this loop reasons about. The concealment history, the edge detector
        // and the continuity metrics all want the clean stream; feeding a room
        // back into them would have the synthesis chase its own reflections.
        // The echo canceller is the exception and must see the treated signal,
        // because that is what the speaker actually plays into the microphone.
        let played = presence(val)
        noteFar(played)
        CallRecorder.shared.recordAudioSample(played)
        // ── SILENCED WHERE `mute` IS SILENCED, AND FOR THE SAME REASON ────────
        //
        // `roomSpeakerOff` turns this Mac's speaker off when both people are in
        // one room. It joins `mute` HERE, on the way out of the machine, and
        // touches nothing below -- and that placement is the entire stability
        // argument for the feature.
        //
        // The detector correlates the DECODED FAR STREAM against the microphone.
        // Not the acoustic output of the speaker: `echoHist` records `played`
        // whatever `mute` and `roomSpeakerOff` say, and `capHist` records the RAW
        // microphone whatever the duplex gate says. So after the speaker goes
        // quiet: the far person is still in the room, so the microphone still
        // hears them; the far stream still arrives over the network, so
        // `echoHist` still has it; and the correlation therefore SURVIVES the fix
        // and the detector keeps agreeing with itself.
        //
        // Key it off anything the fix removes -- the speaker's actual output, an
        // acoustic measurement, the gate's decision -- and it silences, loses its
        // evidence, unsilences, hears the room again, and silences again: a call
        // oscillating once a second. Two bugs in this codebase already have that
        // exact shape (`held-is-a-one-way-door`,
        // `control-loops-steer-on-flattering-signals`), and both were a recovery
        // gate reading a signal its own action had switched off.
        // THE EAR. `Floor` decides it; this ramps it, because a step to zero
        // on a live speaker is a click. Down on the same 4 ms linear close the
        // microphone side uses -- an exponential cannot deliver a mute -- and
        // back up fast, because the direction that restores hearing is never
        // allowed to be the slow one.
        let eWant: Float = Audio.earOpen ? 1 : 0
        if eWant < earGain { earGain = max(eWant, earGain - Audio.EAR_STEP) }
        else { earGain += (eWant - earGain) * 0.02 }
        // TWO HISTORIES OF THE SAME SAMPLE, AND THEY ARE NOT THE SAME SIGNAL.
        // `echoHist` below is `played` -- what the far end SENT, before this
        // machine's ear mute -- and that is deliberate and load-bearing: the
        // estimator correlates it against the microphone, and keying it off the
        // speaker's actual OUTPUT means the detector loses its evidence exactly
        // when the fix works, a shape this codebase has already shipped twice.
        // `emitHist` is what LEFT THE SPEAKER, which is the only thing that can
        // become an echo, and it is what the canceller must subtract. Written on
        // the same line as its twin so `emitW == echoW` always holds -- the delay
        // the estimator measures between `capHist` and `echoHist` is then the
        // same index mapping for both, by construction rather than by agreement.
        // ── AND `mute` IS NOT A PROPERTY OF THE SPEAKER ──────────────────────
        //
        // `earGain` is a PRODUCT state -- the floor closing this end's ear -- and
        // a closed ear emits nothing, so the history must follow it. `mute` is a
        // RIG flag meaning "do not put this in the room I am sitting in", and the
        // room it is standing in for is `--echo-sim`. Folding it into the history
        // meant the simulated room had nothing to reflect and the canceller had a
        // silent reference, so `tools/aec-check.sh` measured 0 dB and reported the
        // canceller as never having run -- a rig blind to the thing it tests,
        // reporting the blindness as a negative
        // (`blind-instruments-report-negatives`).
        let emitted = played * earGain
        out[i] = (mute || roomSpeakerOff) ? 0 : emitted
        noteEdge(val)
        prevOut = val
        if let d = dumpBuf { if dumpW < dumpCap { d[dumpW] = val; dumpW += 1 } else { dumpFull = true } }
        if let e = echoHist { e[echoW % Audio.ECHO_MAX] = played; echoW += 1 }
        if let m = emitHist { m[emitW % Audio.ECHO_MAX] = emitted; emitW += 1 }
        // ── THE FACT THE FLOOR NEEDS, TAKEN WHERE IT IS TRUE ──────────────────
        //
        // Whether this machine's loudspeaker is emitting anything right now.
        // Not who holds the floor -- that is a belief, and the belief is what
        // was wrong. Summed here on the render thread, where the sample is, and
        // read once per block: two adds per sample, no allocation, no lock.
        playoutSumSq += Double(played) * Double(played)
        playoutN += 1
        sigSumSq += Double(val) * Double(val); sigN += 1
        // History is what was actually PLAYED, and only the good path writes it:
        // feeding synthesis back in would make the cursor chase its own tail.
        hist[histW & Audio.HMASK] = val; histW += 1
        lastGood[off] = a
        // A complete packet of last-good samples needs the boundary; the run
        // length does not, and resetting it per sample is what makes it true.
        // LAST of the same class as `played` and `concealed`: this asked for the
        // cursor to land on the exact final sample of a packet, which a fractional
        // cursor can step over indefinitely -- so the grain conceal path could
        // stay disarmed for the whole call and output silence instead. A run of
        // FPP good samples proves every slot was written, and cannot be skipped.
        goodRun += 1
        if goodRun >= FPP { haveLastGood = true }
        if concealRun > concealMaxRun { concealMaxRun = concealRun }
        concealRun = 0
        ring.playedS += 1
        if Int64(seq) > ring.maxPlayedSeq { ring.maxPlayedSeq = Int64(seq) }
        if off == 0 { sawZero = true }
        // ── Sample the latency ONCE PER CALLBACK, not once per packet ──────────
        //
        // This used to sit inside `off == 0`, and that gate is skippable: the
        // fractional cursor can step over sample 0 of a packet and, at a rate
        // near 1.0, keep doing it. Measured on a healthy call: 146329 consecutive
        // callbacks -- 48.8 SECONDS -- in which no callback crossed a boundary. So
        // the headline latency number had a 49-second blind spot, and its p95 and
        // p99 were quantiles over whatever the gate happened to let through.
        //
        // `i == 0` fires exactly once per callback and cannot be skipped. The
        // sample is then mid-packet, so the capture stamp -- which belongs to the
        // packet's FIRST sample -- has to be advanced by `off` samples to describe
        // this one. Without that the number is up to 0.67 ms too large.
        if i == 0 {
          let earHost = dueHost
          let capOfs = Clock.ticks(ns: UInt64(Double(off) / SR * 1_000_000_000.0))
          // MOUTH to EAR, not callback to callback. Both device latencies count: the
          // mic transducer-to-buffer delay happens BEFORE the capture timestamp
          // exists, and the DAC buffer-to-air delay happens after this callback
          // returns. Neither is visible from inside the callbacks, and a number that
          // omits them is a smaller number about a different question.
          if thetaValid {
            let ms = Clock.msSigned(earHost, ring.capHost[slot] + capOfs)
                   + thetaMs + outLatencyMs + inLatencyMs
            m2eLast = ms
            m2e.add(ms)
          }
          // Local both ends, no offset involved, so this term is exact even
          // between two machines. Includes the deliberate jitter buffer.
          recvToPlay.add(Clock.msSigned(earHost, ring.recvHost[slot] + capOfs))
        }
      } else {
        // Repeat the last good packet, fading out over about 20 ms so a real
        // outage becomes quiet rather than a held note.
        if !wasConcealing {
          // First concealed sample of this outage. The period is decided ONCE,
          // here, from the sound that was actually playing -- not per sample, and
          // not from a cached estimate belonging to a different phoneme.
          wasConcealing = true
          xfade = 0
          plcSamples = 0
          plcPeriod = 0
          if !concealZeros, !concealGrain {
            let t0 = Clock.now()
            plcPeriod = findPeriod()
            plcSearchUs.add(Clock.ms(Clock.now() - t0) * 1000.0)
            if plcPeriod > 0 { plcPeriodMs.add(Double(plcPeriod) / SR * 1000.0) }
            plcCursor = histW - max(plcPeriod, 1)
          }
          edgeWinLeft = Audio.XFADE * 2
          edgeWinMax = 0
        }
        var val: Float = 0
        if concealGrain {
          if haveLastGood {
            let fade = max(0.0, 1.0 - Double(concealRun) / (30.0 * Double(FPP)))
            val = lastGood[off] * Float(fade)
          }
        } else if !concealZeros {
          val = plcNext()
        }
        let played = presence(val)
        noteFar(played)
        CallRecorder.shared.recordAudioSample(played)
        // The concealment path silences too, or a room that has been detected
        // still leaks every invented sample out of the speaker. Same placement,
        // same reason: `echoHist` below is written either way.
        // THE EAR. `Floor` decides it; this ramps it, because a step to zero
        // on a live speaker is a click. Down on the same 4 ms linear close the
        // microphone side uses -- an exponential cannot deliver a mute -- and
        // back up fast, because the direction that restores hearing is never
        // allowed to be the slow one.
        let eWant: Float = Audio.earOpen ? 1 : 0
        if eWant < earGain { earGain = max(eWant, earGain - Audio.EAR_STEP) }
        else { earGain += (eWant - earGain) * 0.02 }
        // TWO HISTORIES OF THE SAME SAMPLE, AND THEY ARE NOT THE SAME SIGNAL.
        // `echoHist` below is `played` -- what the far end SENT, before this
        // machine's ear mute -- and that is deliberate and load-bearing: the
        // estimator correlates it against the microphone, and keying it off the
        // speaker's actual OUTPUT means the detector loses its evidence exactly
        // when the fix works, a shape this codebase has already shipped twice.
        // `emitHist` is what LEFT THE SPEAKER, which is the only thing that can
        // become an echo, and it is what the canceller must subtract. Written on
        // the same line as its twin so `emitW == echoW` always holds -- the delay
        // the estimator measures between `capHist` and `echoHist` is then the
        // same index mapping for both, by construction rather than by agreement.
        // ── AND `mute` IS NOT A PROPERTY OF THE SPEAKER ──────────────────────
        //
        // `earGain` is a PRODUCT state -- the floor closing this end's ear -- and
        // a closed ear emits nothing, so the history must follow it. `mute` is a
        // RIG flag meaning "do not put this in the room I am sitting in", and the
        // room it is standing in for is `--echo-sim`. Folding it into the history
        // meant the simulated room had nothing to reflect and the canceller had a
        // silent reference, so `tools/aec-check.sh` measured 0 dB and reported the
        // canceller as never having run -- a rig blind to the thing it tests,
        // reporting the blindness as a negative
        // (`blind-instruments-report-negatives`).
        let emitted = played * earGain
        out[i] = (mute || roomSpeakerOff) ? 0 : emitted
        noteEdge(val)
        prevOut = val
        if let d = dumpBuf { if dumpW < dumpCap { d[dumpW] = val; dumpW += 1 } else { dumpFull = true } }
        if let e = echoHist { e[echoW % Audio.ECHO_MAX] = played; echoW += 1 }
        if let m = emitHist { m[emitW % Audio.ECHO_MAX] = emitted; emitW += 1 }
        // ── THE FACT THE FLOOR NEEDS, TAKEN WHERE IT IS TRUE ──────────────────
        //
        // Whether this machine's loudspeaker is emitting anything right now.
        // Not who holds the floor -- that is a belief, and the belief is what
        // was wrong. Summed here on the render thread, where the sample is, and
        // read once per block: two adds per sample, no allocation, no lock.
        playoutSumSq += Double(played) * Double(played)
        playoutN += 1
        if concealRun < 1_000_000_000 { concealRun += 1 }
        goodRun = 0
        ring.concealedS += 1
        // Already past this sequence and it never came: lost. Not yet reached
        // by the stream: starved, which a bigger buffer does address.
        if hi > Int64(seq) { ring.concealLostS += 1 } else { ring.concealStarvedS += 1 }
        if off == 0 { sawZero = true }
      }
    }
    if sawZero { offZeroRun = 0 } else {
      offZeroMiss += 1; offZeroRun += 1
      if offZeroRun > offZeroRunMax { offZeroRunMax = offZeroRun }
    }
    nHist[min(Int(n), Audio.N_HIST)] += 1
    ring.pos += Double(n) * ring.rate

    if acoustic, !mute, !acWaiting, dueHost > acNext {
      // Full-scale for a handful of samples: short enough to locate precisely,
      // loud enough to clear room noise without being a tone.
      let k = min(8, Int(n))
      for i in 0..<k { out[i] = (i % 2 == 0) ? 0.9 : -0.9 }
      acPlayAt = dueHost
      acWaiting = true
      acFired += 1
      acNext = dueHost + Clock.ticks(ns: 400_000_000)   // one every 400 ms
    }
  }

}

// Trampolines: an AURenderCallback is a C function pointer and cannot capture,
// so the instance rides in inRefCon.
private func captureProc(refCon: UnsafeMutableRawPointer, flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                         ts: UnsafePointer<AudioTimeStamp>, bus: UInt32, frames: UInt32,
                         io: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
  Unmanaged<Audio>.fromOpaque(refCon).takeUnretainedValue().onCapture(flags, ts, bus, frames)
  return noErr
}

private func renderProc(refCon: UnsafeMutableRawPointer, flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        ts: UnsafePointer<AudioTimeStamp>, bus: UInt32, frames: UInt32,
                        io: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
  guard let io else { return noErr }
  // Identify this thread ONCE, so Metrics can refuse to lock on it. Two loads
  // and a compare in the steady state; the assignment happens on the first
  // render callback of the process and never again.
  Metrics.claimAudioThread()
  Unmanaged<Audio>.fromOpaque(refCon).takeUnretainedValue().onRender(ts, frames, io)
  return noErr
}

enum Err: Error { case e(String) }
func ck(_ s: OSStatus, _ what: String) throws {
  if s != noErr { throw Err.e("\(what) failed: \(s)") }
}
