import Foundation
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
  private var inBufList: UnsafeMutablePointer<AudioBufferList>
  private var inScratch: UnsafeMutablePointer<Float>

  // Measurement
  var m2e = Quantiles()
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
    capScratch = .allocate(capacity: HDR + FPP * 4 + 64)
    capScratch.initialize(repeating: 0, count: HDR + FPP * 4 + 64)
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
        wire?.send(seq: capSeq, cap: cap, src: capBuf, n: FPP, scratch: capScratch)
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
    if hi - curSeq > Int64(RING - 2) || curSeq > hi + 2 {
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
    let SNAP_PKTS: Int64 = 11        // ~29 ms
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
        out[i] = mute ? 0 : a + (b - a) * fr
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
        }
      } else {
        out[i] = 0
        if off == 0 { ring.concealed += 1 }
      }
    }
    ring.pos += Double(n) * ring.rate
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
