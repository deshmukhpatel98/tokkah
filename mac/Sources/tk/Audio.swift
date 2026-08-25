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
  private(set) var echoErleDb: Double = 0

  // ── AND THE SAME SEARCH RUN BACKWARDS: ARE YOU TWO IN THE SAME ROOM? ───────
  //
  // Reported from a live call: "two devices side by side, a lot of echo, and only
  // one mic is active at a time, which was very confusing." It is confusing
  // because it is not echo and no echo canceller can touch it. Person speaks.
  // This Mac's microphone hears them through the air. The OTHER Mac's microphone
  // hears them too, ships it over the network, and this Mac's SPEAKER plays them
  // back into the same room a mouth-to-ear later. They hear themselves, late,
  // out of the machine in front of them. Nothing about that is this speaker
  // feeding this microphone, and the duplex gate cannot help either -- the
  // problem is a live SPEAKER, not a second live microphone.
  //
  // So the fix is not cancellation, it is noticing. And there is a signature
  // that a genuinely remote call cannot produce:
  //
  //     same room:   playout(t)  ~=  mic(t - L)      L = one crossing, 30-150 ms
  //                  -> THE MICROPHONE HEARD THEM BEFORE THE SPEAKER DID
  //
  // A remote voice cannot be in this room before the network delivers it. The
  // existing estimator searches the other direction only -- mic(t) ~= spk(t-lag),
  // "my speaker reached my mic" -- so it is blind to this by construction, which
  // is why the complaint had no number attached to it for so long.
  //
  // The two searches share a thread, a decimation and a score, so `roomCorr` and
  // `echoCorr` are the same kind of number and can be compared to each other.
  private(set) var roomCorr: Double = 0
  private(set) var roomLagMs: Double = -1
  /// How loud each side of the last estimate was. Published because the first
  /// live run of this feature produced correlations from 0.13 to 0.98 on one
  /// call, and the only way to tell a weak ROOM from a weak WINDOW is to be able
  /// to see how much sound was in the window at all.
  private(set) var roomRefRms: Double = 0
  private(set) var roomMicRms: Double = 0
  /// What the backward hit was attributed to. See `RoomVerdict`.
  private(set) var roomVerdict = RoomVerdict.unknown
  /// ── HOW MANY OF THE LAST TWENTY SAID "ROOM" ───────────────────────────────
  ///
  /// A rate over a window, not a run of consecutive estimates, and that is a
  /// change made BY measurement rather than by preference. Driven through a real
  /// call carrying a genuine same-room signature, the per-estimate correlation
  /// ranged from 0.22 to 0.98 -- within one call, one room, one recording, with
  /// the LAG pinned to 43-72 ms the whole time. The evidence is unmistakable and
  /// individual half-seconds of it are not.
  ///
  /// Some of that is the jitter buffer: the playout is resampled by a governor
  /// that tracks the sender, so over a 400 ms window the reference is stretched
  /// by a few tenths of a percent against a microphone that is not stretched at
  /// all, which is enough to halve a correlation on its own. `--sameroom-test`
  /// measures how much (see the time-warp case). It is a property of every call
  /// this feature will ever run on, so the controller is built for it instead of
  /// against it.
  ///
  /// Requiring six consecutive strong estimates would therefore have produced a
  /// feature that never fires: measured on that call, the longest run was two.
  /// Requiring eight of the last twenty separates it from a genuinely remote
  /// call by 52 percentage points against 0.
  private var roomWin: UInt32 = 0
  private var roomWinN = 0
  /// Same-room estimates among the last `ROOM_WINDOW` scored ones, and how full
  /// that window is. A judgement is refused until it is full.
  var roomRecent: Int { roomWin.nonzeroBitCount }
  var roomWindowFull: Bool { roomWinN >= Audio.ROOM_WINDOW }
  /// Half-second estimates that landed in each band, for the end-of-call line.
  private(set) var roomHits = 0, loopbackHits = 0
  /// Estimates that were scored at all: the denominator. A bare hit count with
  /// nothing to divide it by is decoration (`counted-without-a-denominator`).
  private(set) var roomScored = 0
  /// CONFIRMED, and therefore acted on. Written by the estimator thread, read by
  /// the render callback as a plain load, exactly like `mute`.
  private(set) var roomConfirmed = false
  /// How many times the judgement has flipped on. One is correct for a call held
  /// in one room; a number that climbs is the oscillation this whole design is
  /// built to avoid, and it is reported rather than assumed away.
  private(set) var roomEnters = 0
  /// The person said no. Survives until they say otherwise or the call ends: an
  /// automatic action that re-applies itself over a decision somebody just made
  /// is worse than not having the action.
  var roomOverride = false
  /// Off switch for the whole layer (`--no-sameroom`), so the rig has a control
  /// arm that is the same binary with the behaviour disabled.
  var sameRoomEnabled = true
  /// What the speaker actually does. THIS is the one the render callback reads.
  var roomSpeakerOff: Bool { roomConfirmed && !roomOverride }

  enum RoomVerdict: Int {
    /// Not enough history, the far end is silent, or this call has no honest
    /// mouth-to-ear yet -- so there is nothing to attribute. An instrument that
    /// cannot see the event must not return the same answer as a real negative
    /// (`blind-instruments-report-negatives`), so this is its own value.
    case unknown = 0
    /// The microphone does not hear the far voice early. A real remote call.
    case remote = 1
    /// Early by ONE crossing, while the far stream is vocal. Same room.
    case sameRoom = 2
    /// Early by TWO crossings: our own voice going out, coming off THEIR speaker
    /// into THEIR microphone, and arriving back. A real and different fault --
    /// counted and named, never acted on from this end, because the machine that
    /// can fix it is the other one.
    case farLoopback = 3
  }

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
  private var lastOpenAt: UInt64 = 0
  private var wasOpen = true

  /// Called once per capture block, which is the only place that sees this end's
  /// state and the far end's in the same instant.
  func accountTurn(peerVocal: Bool, audible: Bool) {
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
    if wantYield != dgate.yielding {
      dgate.yielding = wantYield
      if wantYield { turns.yields += 1 }
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
    if Audio.gateAuto {
      Audio.gate.on = speakers
      Audio.sharedGate.cfg = Audio.gate
    }
    Metrics.fact("output_route", speakers ? "speakers" : "headphones")
    let how = speakers ? "one at a time, so nobody hears themselves"
                       : "both at once, nothing in the way"
    fputs("output\(firstLook ? ":" : " is now:") \(name) -- \(how)\n", stderr)
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
    else if peak > 0.92 { want = max(cur - 0.08, 0.15) }   // clipping, back off
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
      guard let ch = capHist, let eh = echoHist else { continue }
      let cw = capHistW, ew = echoW
      guard cw > win * D + 2000, ew > (win + maxLag) * D + 2000 else { continue }
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
      guard micE > 1e-6 else { continue }       // a silent mic has no echo to find

      var best = -1, bestScore: Float = 0
      for lag in 0..<maxLag {
        var num: Float = 0, den: Float = 0
        let off = maxLag - lag
        for i in 0..<win {
          let sv = spk[i + off]
          num += mic[i] * sv
          den += sv * sv
        }
        guard den > 1e-9 else { continue }
        // Normalised by BOTH energies, so the score is a correlation coefficient
        // rather than a number that grows with how loud the speaker happens to be.
        let r = abs(num) / (den * micE).squareRoot()
        if r > bestScore { bestScore = r; best = lag }
      }
      guard best >= 0 else { continue }
      echoCorr = Double(bestScore)
      echoDelayMs = Double(best * D) / SR * 1000.0

      // ── AND NOW THE SAME 400 ms, SLID THE OTHER WAY ─────────────────────────
      //
      // Same thread, same cadence, same decimation, same normalisation, so the
      // two numbers mean the same thing. It reads the same two histories one
      // more time rather than reusing the arrays above, because the fixed side
      // and the sliding side swap over and the windows are different lengths.
      let hit = Audio.scoreSameRoom(mic: ch, micW: cw, spk: eh, spkW: ew,
                                    micWin: &backMic, refWin: &backRef)
      judgeSameRoom(hit)
    }
  }

  // ── THE BACKWARD SEARCH, AS A FUNCTION OF ITS INPUTS AND NOTHING ELSE ──────
  //
  // Pure, static, and given its own scratch, for one reason: it is the RULER, and
  // a ruler has to be calibrated against known answers before anything is allowed
  // to act on it (`validate-the-ruler-against-known-inputs`). `--sameroom-test`
  // calls THIS function -- not a copy of it written to agree with it -- on
  // synthetic and on real speech, and prints what it says about inputs whose
  // answer is known in advance.
  //
  // Fix the most recent WIN of PLAYOUT. Slide MIC HISTORY earlier by 0..MAXBACK.
  // A hit at lag L means the microphone had that content L ms before the speaker
  // did, which is the one thing a remote voice cannot do.
  static let RD = 8                                   // decimation -> 6 kHz, as above
  static let RWIN = 19200 / RD                        // 400 ms of evidence
  static let RMAXBACK = Int(0.300 * SR) / RD          // search out to 300 ms early
  /// A vocal far end, in peak-normalised RMS. Matches the duplex gate's own
  /// `farTalking` threshold (0.004) so "the far end is talking" means one thing
  /// in this file rather than two.
  static let RFAR_VOCAL = 0.004

  struct RoomHit {
    var corr: Double = 0
    var lagMs: Double = -1
    /// How loud the fixed PLAYOUT window was. This is the far-end-vocal test, and
    /// it is deliberately taken from `echoHist` rather than from the speaker:
    /// see the note on `roomSpeakerOff` in the render callback.
    var refRms: Double = 0
    var micRms: Double = 0
    /// ── HOW FAR THE PEAK STANDS ABOVE THE REST OF THE SEARCH ─────────────────
    ///
    /// The correlation coefficient answers "how much of the microphone is this",
    /// and that is the right question for entering. It is the WRONG question for
    /// staying, because adding an uncorrelated near voice inflates the
    /// denominator and the coefficient falls even though the room has not
    /// changed at all: measured on real speech, 0.794 -> 0.285 as a second voice
    /// goes from silent to equal-loudness, with the peak at 70.0 ms throughout.
    ///
    /// This is the peak divided by the mean score over all 1801 candidate lags.
    /// Both halves fall together when energy is added, so it barely moves -- and
    /// an unrelated signal has no peak to stand proud of its own sidelobes.
    ///
    /// ── AND IT IS REPORTED, NOT USED. IT FAILED CALIBRATION. ─────────────────
    ///
    /// It was built to fix exactly the weakness above and on real speech it does:
    /// null worst 7.18, same room 12.8-18.9, and 16.5 at the double-talk level
    /// where `corr` had already fallen to 0.471. A clean 2x separation.
    ///
    /// On the synthetic voice the SAME statistic ranks BACKWARDS: null worst
    /// 2.95, and a true same-room case with an equally loud near voice scores
    /// 2.80. Two calibrated sources disagree about which way it points, so there
    /// is no threshold that is right on both, and a number that ranks backwards
    /// on any known input is not a ruler yet (`no-reference-picture-quality-
    /// failed`, where three blockiness metrics died the same way).
    ///
    /// The synthetic voice is more self-similar than a person -- fixed formants,
    /// one syllable rate -- so its sidelobes are unusually high, and it is
    /// plausible that real speech is the fair test. Plausible is not measured.
    /// It stays printed on every run, because the next person to look at this
    /// should have the numbers rather than the argument.
    var snr: Double = 0
    /// False when there was not enough history or the playout window was silent.
    /// NOT the same as a low correlation, and never collapsed into one.
    var scored = false
  }

  static func scoreSameRoom(mic: UnsafeMutablePointer<Float>, micW: Int,
                            spk: UnsafeMutablePointer<Float>, spkW: Int,
                            micWin: inout [Float], refWin: inout [Float]) -> RoomHit {
    var out = RoomHit()
    let D = RD, win = RWIN, maxBack = RMAXBACK
    // Enough history on both sides, with a couple of thousand samples of margin
    // so the read never walks into the region a callback is writing.
    guard spkW > win * D + 2000, micW > (win + maxBack) * D + 2000 else { return out }
    if refWin.count != win { refWin = [Float](repeating: 0, count: win) }
    if micWin.count != win + maxBack { micWin = [Float](repeating: 0, count: win + maxBack) }
    // Decimate by AVERAGING, not by dropping -- dropping aliases everything above
    // 3 kHz down into the band the correlation is computed in.
    for i in 0..<win {
      var a: Float = 0
      for j in 0..<D { a += spk[((spkW - (win - i) * D + j) % ECHO_MAX + ECHO_MAX) % ECHO_MAX] }
      refWin[i] = a / Float(D)
    }
    for i in 0..<(win + maxBack) {
      var a: Float = 0
      for j in 0..<D { a += mic[((micW - (win + maxBack - i) * D + j) % CAPH + CAPH) % CAPH] }
      micWin[i] = a / Float(D)
    }
    var refE: Float = 0
    for v in refWin { refE += v * v }
    var micEAll: Float = 0
    for v in micWin { micEAll += v * v }
    out.refRms = Double((refE / Float(win)).squareRoot())
    out.micRms = Double((micEAll / Float(win + maxBack)).squareRoot())
    // A SILENT PLAYOUT IS NOT A REMOTE CALL. It is no evidence at all, and the
    // difference is the whole reason `scored` exists.
    guard out.refRms > RFAR_VOCAL, refE > 1e-6 else { return out }
    out.scored = true

    var best = -1, bestScore: Float = 0
    var sum: Double = 0, nLags = 0
    for lag in 0...maxBack {
      var num: Float = 0, den: Float = 0
      // ref[i] sits at playout time (spkW - (win-i)*D); the mic sample lag*D
      // EARLIER than it is micWin[maxBack + i - lag]. Derived once, here, rather
      // than tuned until the numbers looked right.
      let off = maxBack - lag
      for i in 0..<win {
        let mv = micWin[i + off]
        num += refWin[i] * mv
        den += mv * mv
      }
      guard den > 1e-9 else { continue }
      // Normalised by BOTH energies -- the same coefficient the forward search
      // reports, with the fixed and sliding sides swapped.
      let r = abs(num) / (den * refE).squareRoot()
      sum += Double(r); nLags += 1
      if r > bestScore { bestScore = r; best = lag }
    }
    guard best >= 0, nLags > 0 else { out.scored = false; return out }
    out.corr = Double(bestScore)
    out.lagMs = Double(best * D) / SR * 1000.0
    // One lag out of eighteen hundred cannot move the mean enough to matter, so
    // it is not excluded -- which keeps this a single pass with no second buffer.
    let floorScore = sum / Double(nLags)
    out.snr = floorScore > 1e-9 ? out.corr / floorScore : 0
    return out
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

  private func judgeSameRoom(_ hit: RoomHit) {
    roomCorr = hit.corr
    roomLagMs = hit.lagMs
    roomRefRms = hit.refRms
    roomMicRms = hit.micRms
    guard sameRoomEnabled else { roomVerdict = .unknown; return }
    guard hit.scored else {
      // The far end is quiet. That confirms nothing and denies nothing, so
      // neither counter moves and the state is HELD. A pause in a conversation
      // is not evidence that the two of you left the room, and treating it as
      // evidence is how a control loop learns to flap once a second.
      roomVerdict = .unknown
      return
    }
    roomScored += 1
    guard let pipe = roomPipeMs, let m2eP50 = m2e.p(0.50) else {
      roomVerdict = .unknown
      return
    }
    // Half a mouth-to-ear of slack above one crossing. A loop exceeds one
    // crossing by a WHOLE mouth-to-ear plus the far room, so the band that
    // separates them is as wide as the thing being measured.
    let ceiling = pipe + max(15.0, m2eP50 * 0.5)
    // And it cannot be EARLIER than one crossing by more than the jitter buffer
    // moves; the far machine's capture cannot precede the sound reaching it.
    let floorMs = max(0.0, pipe - 30.0)
    let inBand = hit.lagMs >= floorMs && hit.lagMs <= ceiling
    // ── AND THE FIRST VERSION OF THIS WAS A ONE-WAY DOOR ─────────────────────
    //
    // It had two thresholds and only counted AGAINST below the lower one, so an
    // estimate landing between them moved nothing -- and the measured null sits
    // exactly there. The rig caught it in one run: the state entered and could
    // never leave, whatever it was shown afterwards. `held-is-a-one-way-door`,
    // built fresh, inside a feature whose entire design note is about not
    // building it. Every scored estimate now moves the window by one, either
    // way, and the hysteresis is in the two RATES rather than in two levels.
    var same = false
    if inBand, hit.corr >= Audio.ROOM_ON {
      roomVerdict = .sameRoom
      roomHits += 1
      same = true
    } else if hit.corr >= Audio.ROOM_ON, hit.lagMs > ceiling {
      // NAMED AND COUNTED, NOT ACTED ON. It is worth saying out loud because
      // "there is an echo" gets reported for this and for the same-room case in
      // identical words, and the two need opposite fixes on opposite machines.
      roomVerdict = .farLoopback
      loopbackHits += 1
    } else {
      roomVerdict = .remote
    }
    // Every SCORED estimate moves the window by exactly one, whichever way it
    // went. An estimate that moved nothing is how the first version of this
    // became a door that only opened.
    let mask: UInt32 = Audio.ROOM_WINDOW >= 32 ? .max : (1 << UInt32(Audio.ROOM_WINDOW)) - 1
    roomWin = ((roomWin << 1) | (same ? 1 : 0)) & mask
    roomWinN = min(roomWinN + 1, Audio.ROOM_WINDOW)
    guard roomWinN >= Audio.ROOM_WINDOW else { return }
    let hits = roomWin.nonzeroBitCount
    if !roomConfirmed, hits >= Audio.ROOM_ENTER {
      roomConfirmed = true
      roomEnters += 1
      fputs("room: you are both in the same room -- this speaker is off"
          + String(format: " (%d of the last %d estimates, %.2f at %.0f ms,"
                         + " one crossing is %.0f ms)",
                   hits, Audio.ROOM_WINDOW, hit.corr, hit.lagMs, pipe) + "\n", stderr)
    } else if roomConfirmed, hits <= Audio.ROOM_LEAVE {
      roomConfirmed = false
      // START THE WINDOW AGAIN. Without this the very next same-room estimate is
      // judged against a window that is already nearly full of them, and the
      // decision can come straight back -- which is the flap this whole design
      // exists to prevent, rebuilt one line lower down.
      roomWin = 0; roomWinN = 0
      fputs("room: not the same room any more -- this speaker is back"
          + String(format: " (%d of the last %d)", hits, Audio.ROOM_WINDOW) + "\n", stderr)
    }
  }

  /// ── THE THRESHOLD, AND THE NULL IT WAS CHOSEN FROM ────────────────────────
  ///
  /// `tk --sameroom-test`, 2026-08-26, twenty independent draws per arm:
  ///
  ///                                  real recorded speech    synthetic voice
  ///   remote, two different voices        worst 0.385          worst 0.426
  ///   remote, and they sound ALIKE        worst 0.385          worst 0.371
  ///   same room, one person talking       0.792 - 0.901        0.802 - 0.888
  ///   their room looping us back          0.939 at 180 ms      0.940 at 180 ms
  ///
  /// So the null is 0.43, not the 0.26 the FORWARD search measured -- this one
  /// searches 300 ms instead of 200, half again as many candidate lags for an
  /// unrelated signal to find something in. The first version of these constants
  /// was written before the measurement and put the leave threshold at 0.40,
  /// UNDER the synthetic null: noise alone could have held a confirmed room on
  /// forever. Measured first, then written down.
  ///
  /// ── AND WHY IT IS 0.50 RATHER THAN 0.62 ───────────────────────────────────
  ///
  /// Those offline numbers are one clean window each. Driven through a real call
  /// the same evidence scores 0.22 to 0.98 estimate to estimate (see `roomWin`),
  /// so a per-estimate threshold set where the offline same-room cases sit would
  /// have fired on a fifth of them. 0.50 is above every remote draw either
  /// source has produced and below the live median of 0.50-0.54, and the SAFETY
  /// margin has been moved into the rate: a remote call has to produce eight
  /// separate coincidences inside ten seconds, all of them in the lag band.
  ///
  /// Measured hit rates at this threshold, live: same room 52%, remote 0%.
  static var ROOM_ON = 0.50
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

  /// One estimate over a pair of prepared histories. Writes them into rings of
  /// exactly the shipped sizes, at a write head that is not a multiple of
  /// anything, so a wrap bug in the indexing shows up here rather than on a call.
  private static func oneEstimate(mic: [Float], spk: [Float],
                                  micWin: inout [Float], refWin: inout [Float]) -> RoomHit {
    let ch = UnsafeMutablePointer<Float>.allocate(capacity: CAPH)
    let eh = UnsafeMutablePointer<Float>.allocate(capacity: ECHO_MAX)
    defer { ch.deallocate(); eh.deallocate() }
    ch.initialize(repeating: 0, count: CAPH)
    eh.initialize(repeating: 0, count: ECHO_MAX)
    let cw = CAPH + 7717, ew = ECHO_MAX + 3313
    let micTake = min(mic.count, (RWIN + RMAXBACK) * RD + 8000)
    let spkTake = min(spk.count, RWIN * RD + 8000)
    for k in 0..<micTake { ch[((cw - micTake + k) % CAPH + CAPH) % CAPH] = mic[mic.count - micTake + k] }
    for k in 0..<spkTake { eh[((ew - spkTake + k) % ECHO_MAX + ECHO_MAX) % ECHO_MAX] = spk[spk.count - spkTake + k] }
    return scoreSameRoom(mic: ch, micW: cw, spk: eh, spkW: ew, micWin: &micWin, refWin: &refWin)
  }

  /// `tk --sameroom-test [--sameroom-audio a.wav,b.wav]`. Returns true on pass.
  static func sameRoomSelfTest(_ files: String?) -> Bool {
    let n = Int(SR * 20)
    var srcA: [Float], srcB: [Float], what: String
    if let f = files {
      let parts = f.split(separator: ",").map(String.init)
      guard parts.count == 2, let a = loadMono48(parts[0]), let b = loadMono48(parts[1]),
            a.count > 2 * ((RWIN + RMAXBACK) * RD + 20000),
            b.count > (RWIN + RMAXBACK) * RD + 20000 else {
        print("  cannot read two usable files from --sameroom-audio \(f)")
        return false
      }
      srcA = a; srcB = b
      what = "REAL RECORDED SPEECH"
    } else {
      srcA = voice(seed: 0x5A11, n: n, f0: 118, syllHz: 3.1, shimmerHz: 5.3,
                   formants: [(620, 80), (1180, 100), (2500, 140)])
      srcB = voice(seed: 0xB0B2, n: n, f0: 168, syllHz: 4.4, shimmerHz: 7.1,
                   formants: [(420, 70), (1900, 110), (2820, 150)])
      what = "a synthetic source-filter voice (no recording given)"
    }
    print("  ruler calibrated on \(what)")
    var micWin = [Float](), refWin = [Float]()
    func slice(_ x: [Float], from: Int, len: Int) -> [Float] {
      var out = [Float](repeating: 0, count: len)
      for i in 0..<len { out[i] = x[(from + i) % x.count] }
      return out
    }
    let need = (RWIN + RMAXBACK) * RD + 8000

    // ── 1. THE NULL ───────────────────────────────────────────────────────────
    //
    // A genuinely remote call: the microphone has one person in it and the
    // playout has the other, and they share nothing but being speech. Fourteen
    // independent draws, because one draw of a null is an anecdote -- and the
    // number that matters for a false positive is the WORST of them.
    var nulls: [Double] = [], nullSnrs: [Double] = []
    for k in 0..<8 {
      let mic = throughRoom(slice(srcA, from: k * 31_000 + 1000, len: need), seedNoise: 0xA1 &+ UInt64(k))
      let spk = slice(srcB, from: k * 47_000 + 500, len: need)
      let h = oneEstimate(mic: mic, spk: spk, micWin: &micWin, refWin: &refWin)
      if h.scored { nulls.append(h.corr); nullSnrs.append(h.snr) }
    }
    // ── AND THE HARDEST NULL THERE IS: THE SAME VOICE, TWICE ─────────────────
    //
    // Two different people is the easy version. The adversarial remote call is
    // one where both ends sound alike -- same pitch, same tract, same room tone,
    // different words -- because then the only thing separating them is that the
    // content does not line up. A detector that cannot hold that apart silences
    // calls between people with similar voices, which nobody would ever guess
    // from the outside. Half the source apart, always, so the two stretches can
    // never be the same words with a wrap in between.
    var sameVoiceNulls: [Double] = []
    let half = srcA.count / 2
    for k in 0..<6 {
      let at = (k * srcA.count) / 8
      let mic = throughRoom(slice(srcA, from: at, len: need), seedNoise: 0xA9 &+ UInt64(k))
      let spk = slice(srcA, from: at + half, len: need)
      let h = oneEstimate(mic: mic, spk: spk, micWin: &micWin, refWin: &refWin)
      if h.scored { sameVoiceNulls.append(h.corr); nullSnrs.append(h.snr) }
    }
    guard !nulls.isEmpty else { print("  the null case scored nothing at all"); return false }
    if let w = sameVoiceNulls.max() {
      print(String(format: "  remote, and they sound ALIKE (%d draws): worst %.3f", sameVoiceNulls.count, w))
      nulls.append(contentsOf: sameVoiceNulls)
    }
    let nullWorst = nulls.max()!, nullMean = nulls.reduce(0, +) / Double(nulls.count)
    print(String(format: "  remote (unrelated voices, %d draws): worst %.3f, mean %.3f  <- THE NULL",
                 nulls.count, nullWorst, nullMean))
    print(String(format: "      and its peak-over-floor: worst %.2f, mean %.2f",
                 nullSnrs.max() ?? 0,
                 nullSnrs.isEmpty ? 0 : nullSnrs.reduce(0, +) / Double(nullSnrs.count)))

    // ── 2. THE SAME ROOM ──────────────────────────────────────────────────────
    //
    // One person, two machines. The far machine captured them and this one plays
    // them out L ms later; this machine's own microphone heard them directly, so
    // it has them EARLY by L. The microphone copy goes through a different set of
    // early reflections and picks up room noise.
    var rooms: [(Double, Double, Double, Double)] = []   // corr, lag, expected, peak/floor
    for (k, lagMs) in [30.0, 55.0, 90.0, 140.0].enumerated() {
      let lag = Int(lagMs / 1000 * SR)
      let base = k * 37_000 + 2000
      let mic = throughRoom(slice(srcA, from: base + lag, len: need), seedNoise: 0xB1 &+ UInt64(k))
      let spk = slice(srcA, from: base, len: need)
      let h = oneEstimate(mic: mic, spk: spk, micWin: &micWin, refWin: &refWin)
      rooms.append((h.corr, h.lagMs, lagMs, h.snr))
    }
    let roomWorst = rooms.map(\.0).min()!
    for (c, l, e, sn) in rooms {
      print(String(format: "  same room, one crossing of %.0f ms: %.3f at %.1f ms (%+.1f ms), peak/floor %.1f",
                   e, c, l, l - e, sn))
    }

    // ── 3. THE SAME ROOM, WITH THE NEAR PERSON TALKING TOO ───────────────────
    //
    // Swept rather than asserted at one level, because a detector has a level at
    // which it stops working and the useful output is WHERE, not pass/fail. The
    // ratio is the near voice against the far voice as the near microphone
    // receives it -- the far one arrives across a room, so 1.0 is already a near
    // talker considerably louder than the far one.
    let lagDT = Int(0.070 * SR)
    let dtRef = slice(srcA, from: 5000, len: need)
    var dtRow: [(Double, Double, Double, Double)] = []   // ratio, corr, lag, peak/floor
    var micDT = [Float]()
    for ratio in [0.0, 0.25, 0.5, 1.0, 2.0] {
      var m = throughRoom(slice(srcA, from: 5000 + lagDT, len: need), seedNoise: 0xC1)
      let nearOwn = slice(srcB, from: 12_345, len: need)
      for i in 0..<need { m[i] += nearOwn[i] * Float(ratio) }
      let h = oneEstimate(mic: m, spk: dtRef, micWin: &micWin, refWin: &refWin)
      dtRow.append((ratio, h.corr, h.lagMs, h.snr))
      if ratio == 0.5 { micDT = m }
    }
    print("  same room, with the near person talking too (70 ms crossing):")
    for (r, c, l, sn) in dtRow {
      print(String(format: "      near voice at %.2fx the far one: %.3f at %.1f ms, peak/floor %.1f%@",
                   r, c, l, sn, c >= ROOM_ON ? "" : "   <- below the threshold"))
    }
    let dt = dtRow.first { $0.0 == 0.5 }!

    // ── 4. AND WITH THE JITTER BUFFER STRETCHING THE PLAYOUT ──────────────────
    //
    // This is why a live estimate is noisier than any of the ones above, and it
    // is not a defect in either end. The playout is resampled by a governor
    // tracking the far sender's clock; the microphone is not resampled at all.
    // Over a 400 ms window a few tenths of a percent is a fraction of a
    // millisecond of drift, which is a large fraction of a cycle at the top of
    // the band being correlated.
    print("  same room, with the playout clock running slightly fast or slow:")
    var warpRow: [(Double, Double)] = []
    for eps in [0.0, 0.001, 0.003, 0.010] {
      let m = throughRoom(warp(slice(srcA, from: 5000 + lagDT, len: need + 2000), eps: eps),
                          seedNoise: 0xC3)
      let h = oneEstimate(mic: Array(m.prefix(need)), spk: dtRef, micWin: &micWin, refWin: &refWin)
      warpRow.append((eps, h.corr))
      print(String(format: "      %.1f%% clock offset: %.3f at %.1f ms", eps * 100, h.corr, h.lagMs))
    }

    // ── 5. THE FAR END LOOPING US BACK ────────────────────────────────────────
    //
    // Our own voice, off their speaker, into their microphone, returned. It is
    // an early hit too -- and it must NOT be called same room, because silencing
    // this speaker would not fix it. It is early by two crossings, not one.
    let rt = Int(0.180 * SR)
    let loopMic = throughRoom(slice(srcB, from: 9000 + rt, len: need), seedNoise: 0xD1)
    let loop = oneEstimate(mic: loopMic, spk: slice(srcB, from: 9000, len: need),
                           micWin: &micWin, refWin: &refWin)
    print(String(format: "  their room looping us back, two crossings:    %.3f at %.1f ms, peak/floor %.1f (expected 180)",
                 loop.corr, loop.lagMs, loop.snr))

    // ── 6. A SILENT FAR END IS NOT A REMOTE CALL ──────────────────────────────
    let quiet = oneEstimate(mic: throughRoom(slice(srcA, from: 3000, len: need), seedNoise: 0xE1),
                            spk: [Float](repeating: 0, count: need),
                            micWin: &micWin, refWin: &refWin)
    print("  far end silent: \(quiet.scored ? "SCORED ANYWAY -- wrong" : "not scored, which is the honest answer")")

    // ── THE VERDICT IS THE MARGIN ─────────────────────────────────────────────
    let margin = roomWorst - nullWorst
    print(String(format: "  MARGIN: worst same room %.3f - worst remote %.3f = %.3f", roomWorst, nullWorst, margin))
    print(String(format: "  shipped: fire above %.2f, and %d of the last %d estimates to decide (leave at %d)",
                 ROOM_ON, ROOM_ENTER, ROOM_WINDOW, ROOM_LEAVE))

    var bad = false
    func check(_ ok: Bool, _ line: String) {
      print(ok ? "   ok   \(line)" : "  WRONG \(line)")
      if !ok { bad = true }
    }
    check(margin >= 0.20, String(format: "the two known inputs rank opposite ways by %.3f", margin))
    check(nullWorst < ROOM_ON, "no remote draw reaches the threshold at all")
    check(roomWorst >= ROOM_ON, "every same-room case clears it")
    // ── DOUBLE TALK IS REPORTED, NOT GRADED ──────────────────────────────────
    //
    // On real speech the room stops being detectable once an UNCORRELATED near
    // voice reaches about half the far one, and that is a property of
    // cross-correlation rather than a bug to tune out. It costs detections,
    // never false ones -- which is the safe direction, and is what is asserted.
    // It also matters less than it looks: when the near person talks, the FAR
    // machine's gate closes on them, the far stream goes quiet, and the estimate
    // is not scored at all.
    let loudest = dtRow.filter { $0.1 >= ROOM_ON }.map(\.0).max() ?? 0
    print(String(format: "  LIMIT: double talk holds up to a near voice %.2fx the far one, and not above", loudest))
    print(String(format: "  LIMIT: a %.1f%% playout clock offset takes it from %.3f to %.3f",
                 warpRow.last!.0 * 100, warpRow.first!.1, warpRow.last!.1))
    var monotone = true
    for i in 1..<dtRow.count where dtRow[i].1 > dtRow[i - 1].1 + 0.02 { monotone = false }
    check(monotone, "a louder near voice only ever makes it LESS sure, never more")
    check(dt.1 < roomWorst + 0.01, "double talk cannot raise the score above the clean case")
    for (_, l, e, _) in rooms {
      check(abs(l - e) <= 8, String(format: "the %.0f ms crossing is located to within 8 ms", e))
    }
    check(loop.corr >= ROOM_ON, "the far-end loop is seen at all")
    check(abs(loop.lagMs - 180) <= 12, "and is located at two crossings, not one")
    check(!quiet.scored, "a silent far end scores nothing rather than scoring low")

    // ── 7. THE CONTROLLER, INCLUDING THE PART AFTER IT ACTS ───────────────────
    //
    // A rig that only tests the entry condition cannot see an oscillation. The
    // buffers here are IDENTICAL before and after the speaker is silenced,
    // because that is what silencing does to them -- nothing: `echoHist` is fed
    // `played` regardless, and `capHist` is the raw microphone regardless. So
    // this replays the same evidence long after the decision and requires the
    // state to hold and the decision count to stay at one.
    let a = Audio()
    a.thetaValid = true
    a.outLatencyMs = 12; a.inLatencyMs = 9
    // A call whose mouth-to-ear is 91 ms: one crossing lands at 91-12-9 = 70 ms,
    // which is where the evidence below sits.
    for _ in 0..<64 { a.m2e.add(91.0) }
    let roomEvidence = oneEstimate(mic: throughRoom(slice(srcA, from: 5000 + lagDT, len: need),
                                                    seedNoise: 0xC2),
                                   spk: dtRef, micWin: &micWin, refWin: &refWin)
    let hardEvidence = oneEstimate(mic: micDT, spk: dtRef, micWin: &micWin, refWin: &refWin)
    let remoteEvidence = oneEstimate(mic: throughRoom(slice(srcA, from: 1000, len: need), seedNoise: 0xF1),
                                     spk: slice(srcB, from: 500, len: need),
                                     micWin: &micWin, refWin: &refWin)
    var enteredAfter = -1
    for i in 0..<(ROOM_WINDOW + 30) {
      a.judgeSameRoom(roomEvidence)
      if a.roomConfirmed, enteredAfter < 0 { enteredAfter = i + 1 }
    }
    check(enteredAfter == ROOM_WINDOW,
          "it refuses to decide until the window is full, then does (\(enteredAfter) of \(ROOM_WINDOW))")
    check(a.roomConfirmed, "and it is STILL sure fifteen seconds after the speaker went off")
    check(a.roomEnters == 1, "having decided ONCE (\(a.roomEnters)), which is what not oscillating looks like")
    check(a.roomVerdict == .sameRoom, "and it still names the room as the reason")
    // A quiet far end must HOLD, not restore: a pause in a conversation is not
    // evidence that anybody left the room, and a gate that reads a pause as a
    // negative flips once per sentence.
    for _ in 0..<40 { a.judgeSameRoom(quiet) }
    check(a.roomConfirmed, "a long silence holds the decision instead of flipping it")
    // Sustained double talk. Measured to drop the decision on real speech and to
    // hold it on the synthetic voice; both are right for the evidence each
    // carries. What must not happen is the two alternating.
    for _ in 0..<12 { a.judgeSameRoom(hardEvidence) }
    let survivedDT = a.roomConfirmed
    for _ in 0..<(ROOM_WINDOW + 6) { a.judgeSameRoom(roomEvidence) }
    check(a.roomConfirmed, "it is sure again once the near person stops talking over them")
    check(a.roomEnters <= 2, "and that whole sequence produced \(a.roomEnters) decision(s), not a flap")
    print("  double talk for 6 s while confirmed: \(survivedDT ? "held" : "dropped, and recovered")")
    // Now the evidence genuinely stops: they left, or it was never a room.
    var leftAfter = -1
    for i in 0..<(ROOM_WINDOW + 10) {
      a.judgeSameRoom(remoteEvidence)
      if !a.roomConfirmed, leftAfter < 0 { leftAfter = i + 1 }
    }
    check(leftAfter == ROOM_WINDOW - ROOM_LEAVE,
          "and it comes back once the window has emptied (\(leftAfter) estimates)")
    // AND IT MUST NOT COME STRAIGHT BACK ON. The window is restarted on the way
    // out, so re-deciding needs a fresh quorum of evidence -- not the single
    // estimate that would otherwise top up a window still full of the decision
    // that was just abandoned.
    var reEntered = -1
    for i in 0..<(ROOM_WINDOW * 2) {
      a.judgeSameRoom(roomEvidence)
      if a.roomConfirmed, reEntered < 0 { reEntered = i + 1 }
    }
    check(reEntered >= ROOM_ENTER,
          "re-deciding needs \(ROOM_ENTER) fresh estimates, not one (took \(reEntered))")

    // And the loop case, on the same call, must never confirm.
    let b = Audio()
    b.thetaValid = true
    b.outLatencyMs = 12; b.inLatencyMs = 9
    for _ in 0..<64 { b.m2e.add(91.0) }
    for _ in 0..<(ROOM_WINDOW * 3) { b.judgeSameRoom(loop) }
    check(!b.roomConfirmed, "the far-end loop never silences this speaker")
    check(b.roomVerdict == .farLoopback && b.loopbackHits > 0,
          "it is counted and named as their room, not ours (\(b.loopbackHits) estimates)")

    print(bad ? "  SAME ROOM TEST FAILED"
              : "  SAME ROOM TEST PASSED -- the detector ranks a room and a remote call opposite ways,"
              + String(format: " by %.3f, and survives its own fix", margin))
    return !bad
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
    var p = Presence()
    private let buf: UnsafeMutablePointer<Float>
    private var w = 0
    private var lo: Float = 0, hi: Float = 0, dull: Float = 0
    init() {
      buf = .allocate(capacity: PresenceFilter.PRES)
      buf.initialize(repeating: 0, count: PresenceFilter.PRES)
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
  static var presence = Presence() { didSet { sharedPresence.p = presence } }
  nonisolated(unsafe) static let sharedPresence = PresenceFilter()
  private let pres = Audio.sharedPresence

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
    var floorDb: Double = -22
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
    private var yieldGain: Float = 1
    private(set) var yieldSamples = 0
    /// Where the duck has actually got to, so a test can assert the bound rather
    /// than the intent.
    var yieldGainNow: Float { yieldGain }
    /// How long this end has been silent inside the current vocalisation. Read by
    /// the subtitle thread: a completion judgement is only meaningful AT A PAUSE,
    /// and this is the pause.
    var quietMsNow: Double { Double(quietSamples) / SR * 1000 }
    var vocalMsNow: Double { Double(vocalSamples) / SR * 1000 }
    private(set) var closedFrames = 0
    private(set) var openFrames = 0
    private(set) var backchannels = 0
    private(set) var claims = 0
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
      farRun = farTalking ? farRun + n : 0
      // NOT AT THE ONSET. When the far end starts, the echo has not arrived yet
      // -- it is a room away and a buffer behind -- so for a few milliseconds
      // the microphone is honestly silent while the playout is loud. A minimum
      // tracker fed that moment learns "there is no echo here" and never closes
      // again. One transient, latched forever.
      if farTalking, farRun > Int(SR * 0.08), nearEnv > 0.0008 {
        let r = min(max(nearEnv / max(far, 1e-6), 0.002), 4)
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
      let expected = coupling * far
      // THE MARGIN CANNOT BE A CONSTANT, BECAUSE THE MISTAKE IT GUARDS IS NOT
      // SYMMETRIC. A generous margin suppresses echo well and, in a room where
      // the microphone sits inches from the speaker, sits ABOVE an ordinary
      // speaking voice -- so the person is gated while they talk. Leaking some
      // echo is a worse call; being cut off is an unusable one. Measured across
      // simulated rooms, a fixed 2.2 gives 19 dB at light coupling and alters
      // the near voice once the microphone hears the speaker at 80% of playout,
      // which a laptop does. So it relaxes as the coupling rises: there is less
      // room to be clever exactly where being clever is dangerous.
      let effMargin = max(1.35, cfg.margin - 1.5 * coupling)
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
      let voiced = aboveEcho && aboveRoom
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
      let nearTalking = !farTalking || aboveEcho
      // ONE OF THE TWO PLACES THAT TOUCHES SAMPLES, and the only one that is
      // about echo. On headphones this is always 1: nothing is held down,
      // because nothing would be heard twice.
      let want: Float = (cfg.on && farTalking && !nearTalking)
        ? Float(pow(10, cfg.floorDb / 20)) : 1

      // OPEN FAST, CLOSE SLOW. Backwards, this clips the first syllable of every
      // interruption, which is the one thing a person notices immediately.
      let step: Float = want > gain ? 0.02 : 0.0006
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
      for k in 0..<n {
        gain += (want - gain) * step
        yieldGain += (yWant - yieldGain) * yStep
        x[k] *= gain * yieldGain
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
    let scratchBytes = HDR + FPP * 4 + 8 + FPP * 4 + 64
    capScratch = .allocate(capacity: scratchBytes)
    capScratch.initialize(repeating: 0, count: scratchBytes)
    prevBuf = .allocate(capacity: FPP)
    prevBuf.initialize(repeating: 0, count: FPP)
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

  private func makeUnit(input: Bool) throws -> AudioUnit {
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
    var dev = defaultDevice(input: input)
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
      iu = try makeUnit(input: true)
      ou = try makeUnit(input: false)
    }
    inUnit = iu; outUnit = ou
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

  /// Tear the graph down and build it again. Heavier than a stop/start, and
  /// deliberately so: rebuilding re-runs the rate check, the buffer size and the
  /// stream format, which is exactly the state a device change invalidated.
  private func restart() {
    if let u = inUnit { AudioOutputUnitStop(u); AudioUnitUninitialize(u); AudioComponentInstanceDispose(u) }
    if let u = outUnit { AudioOutputUnitStop(u); AudioUnitUninitialize(u); AudioComponentInstanceDispose(u) }
    inUnit = nil; outUnit = nil; started = false
    do {
      let iu = try makeUnit(input: true)
      let ou = try makeUnit(input: false)
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

    // What the microphone actually delivered. Placed HERE deliberately: after the
    // file substitution so a rig measures its own input, and before the simulated
    // echo below, so a rig's echo injection cannot be mistaken for a room's.
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
    if echoArmed, let e = echoHist, echoW > echoDelay {
      let w = echoW
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

    // NOTHING SUBTRACTS HERE ANY MORE. The microphone reaches the wire exactly
    // as it was captured, or turned down whole -- never filtered, never guessed
    // at. Whose turn it is is the only thing between the room and the far end.
    duplexGate(inScratch, Int(n))
    accountTurn(peerVocal: Audio.peerVocalNow, audible: dgate.gain > 0.5)

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
        wire?.send(seq: capSeq, cap: cap, src: capBuf, n: FPP, scratch: capScratch,
                   redundant: (redundancy && havePrev) ? prevBuf : nil,
                   redundantCap: prevCap)
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
    if hi < 0 { for i in 0..<Int(n) { out[i] = 0 }; return }
    if ring.pos < 0 {
      guard hi >= Int64(jitTarget) else { for i in 0..<Int(n) { out[i] = 0 }; return }
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
    // In MILLISECONDS. As `11 packets` this meant 29 ms at the old packet size and
    // silently became 14.7 ms when packets halved -- third instance of the same
    // mistake in this one file, so it is now derived rather than typed.
    let SNAP_PKTS = max(Int64(4), Int64((30.0 / (Double(FPP) / SR * 1000.0)).rounded()))
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
    let r = 1.0 + errSamples / (SR * 2.0)
    ring.rate = min(1.004, max(0.996, r))
    ring.rateSum += ring.rate; ring.rateN += 1
    ring.errMs = errSamples / SR * 1000.0

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
        out[i] = (mute || roomSpeakerOff) ? 0 : played
        noteEdge(val)
        prevOut = val
        if let d = dumpBuf { if dumpW < dumpCap { d[dumpW] = val; dumpW += 1 } else { dumpFull = true } }
        if let e = echoHist { e[echoW % Audio.ECHO_MAX] = played; echoW += 1 }
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
        // The concealment path silences too, or a room that has been detected
        // still leaks every invented sample out of the speaker. Same placement,
        // same reason: `echoHist` below is written either way.
        out[i] = (mute || roomSpeakerOff) ? 0 : played
        noteEdge(val)
        prevOut = val
        if let d = dumpBuf { if dumpW < dumpCap { d[dumpW] = val; dumpW += 1 } else { dumpFull = true } }
        if let e = echoHist { e[echoW % Audio.ECHO_MAX] = played; echoW += 1 }
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
  Unmanaged<Audio>.fromOpaque(refCon).takeUnretainedValue().onRender(ts, frames, io)
  return noErr
}

enum Err: Error { case e(String) }
func ck(_ s: OSStatus, _ what: String) throws {
  if s != noErr { throw Err.e("\(what) failed: \(s)") }
}
