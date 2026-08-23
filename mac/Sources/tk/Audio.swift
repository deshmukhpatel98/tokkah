import Foundation
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
  var recvToPlay = Quantiles(cap: 2048)    // receiver: off the socket -> at the DAC
  var m2eLast: Double = 0
  var outLatencyMs: Double = 0
  var inLatencyMs: Double = 0
  var capturedPkts = 0
  var xruns = 0
  var capCallbacks = 0
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
    let got = setBufferFrames(dev, UInt32(FPP), input: input)
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

    // Substitute the file, if one was given, before anything looks at the samples.
    if let src = srcSamples, srcCount > 0 {
      for k in 0..<Int(n) {
        inScratch[k] = src[srcPos]
        srcPos += 1
        if srcPos >= srcCount { srcPos = 0 }
      }
    }

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
        // Host time of THIS packet's first sample: the buffer's host time plus
        // the samples already consumed from it.
        let off = UInt64(Double(i - FPP) / SR * 1_000_000_000.0)
        let cap = host0 + Clock.ticks(ns: off)
        capToSend.add(Clock.msSigned(Clock.now(), cap))
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
    if hi - cur - Int64(jitTarget) > SNAP_PKTS {
      ring.pos = Double((hi - Int64(jitTarget)) * Int64(FPP))
      ring.snaps += 1
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
        // The value the algorithm produces, measured BEFORE muting. Muting is a
        // property of this test rig, not of the concealment, and a metric that
        // reads zero for both arms because the speaker is off would have made
        // this whole comparison meaningless while looking like a result.
        var val = a + (b - a) * fr
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
        out[i] = mute ? 0 : val
        noteEdge(val)
        prevOut = val
        sigSumSq += Double(val) * Double(val); sigN += 1
        // History is what was actually PLAYED, and only the good path writes it:
        // feeding synthesis back in would make the cursor chase its own tail.
        hist[histW & Audio.HMASK] = val; histW += 1
        lastGood[off] = a
        if off == FPP - 1 { haveLastGood = true; concealRun = 0 }
        if off == 0 {
          ring.played += 1
          // capture -> this sample at the DAC, plus the output hardware the
          // callback cannot see.
          let earHost = dueHost + Clock.ticks(ns: UInt64(Double(i) / SR * 1_000_000_000.0))
          // MOUTH to EAR, not callback to callback. Both device latencies count: the
          // mic transducer-to-buffer delay happens BEFORE the capture timestamp
          // exists, and the DAC buffer-to-air delay happens after this callback
          // returns. Neither is visible from inside the callbacks, and a number that
          // omits them is a smaller number about a different question.
          if thetaValid {
            let ms = Clock.msSigned(earHost, ring.capHost[slot]) + thetaMs + outLatencyMs + inLatencyMs
            m2eLast = ms
            m2e.add(ms)
          }
          // Local both ends, no offset involved, so this term is exact even
          // between two machines. Includes the deliberate jitter buffer.
          recvToPlay.add(Clock.msSigned(earHost, ring.recvHost[slot]))
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
            let fade = max(0.0, 1.0 - Double(concealRun) / 30.0)
            val = lastGood[off] * Float(fade)
          }
        } else if !concealZeros {
          val = plcNext()
        }
        out[i] = mute ? 0 : val
        noteEdge(val)
        prevOut = val
        if off == 0 {
          if concealRun < 1_000_000 { concealRun += 1 }
          ring.concealed += 1
          // Already past this sequence and it never came: lost. Not yet reached
          // by the stream: starved, which a bigger buffer does address.
          if hi > Int64(seq) { ring.concealLost += 1 } else { ring.concealStarved += 1 }
        }
      }
    }
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
