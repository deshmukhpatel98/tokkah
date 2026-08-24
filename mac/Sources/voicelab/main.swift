import AppKit
import AVFoundation
import Accelerate

// ── Voice Lab ────────────────────────────────────────────────────────────────
//
// A place to hear a decision instead of arguing about it.
//
// Every audio question on this project so far has been settled by a number, and
// the numbers keep being right about the wrong thing: a call can measure 20 ms
// mouth-to-ear, zero concealment and a lossless codec, and still not sound like
// a person in the room. The only instrument for that is an ear, and an ear needs
// the same voice rendered two ways, back to back, with one thing changed.
//
// So: record yourself, then hear yourself three ways. Nothing here is part of a
// call. It exists so the call can be decided.

let SR = 48000.0

// ── Putting a mono voice outside the listener's head ─────────────────────────
//
// Three cues, in the order the ear uses them. The literature on externalisation
// is blunt that the third one is what actually does the work: anechoic signals
// are less often heard as outside the head than reverberant ones, which is why
// noise suppression makes a voice cleaner AND more trapped inside your skull --
// it deletes the reflections that place a person in a room.
//
// COSTS NO LATENCY, and that is the point. Reflections arrive AFTER the direct
// sound, so the direct path is untouched; the only added delay is the 0.28 ms
// the far ear waits, which is the physics of having a head.
enum Spatial {
  static let headR = 0.0875, c = 343.0

  static func onePole(_ x: [Float], _ fc: Double) -> [Float] {
    let a = Float(exp(-2 * Double.pi * fc / SR))
    var y = [Float](repeating: 0, count: x.count)
    var acc: Float = 0
    for i in 0..<x.count { acc = (1 - a) * x[i] + a * acc; y[i] = acc }
    return y
  }

  /// Brown & Duda's head shadow: the far ear hears a duller version, because a
  /// head is in the way and only the long wavelengths bend around it.
  static func shadow(_ x: [Float], cosToEar: Double) -> [Float] {
    let alpha = Float(1.05 + 0.95 * cosToEar)
    let lp = onePole(x, 1600)
    var y = [Float](repeating: 0, count: x.count)
    for i in 0..<x.count { y[i] = alpha * 0.5 * x[i] + (1 - alpha * 0.5) * lp[i] }
    return y
  }

  static func delay(_ x: [Float], _ d: Double) -> [Float] {
    let i = Int(floor(d)), f = Float(d - floor(d))
    var y = [Float](repeating: 0, count: x.count + i + 1)
    for k in 0..<x.count { y[k + i] += x[k] * (1 - f); y[k + i + 1] += x[k] * f }
    return y
  }

  // ── DISTANCE IS A SEPARATE KNOB FROM DIRECTION ────────────────────────────
  //
  // "Beside you" and "beside you in a room" differ only in whether a room is
  // there at all, and that turned out to be a hard thing to have an opinion
  // about. The literature says why: the two cues that carry DISTANCE
  // independently of loudness are the direct-to-reverberant ratio and, for a
  // nearby source off the midline, the interaural level difference -- which
  // grows sharply inside a metre or so. Neither was on a control here.
  //
  // So the presets move along that axis on purpose. Same voice, same direction,
  // three distances, and the differences are large enough to have an opinion
  // about instead of a shrug.
  struct Preset {
    let name: String, sub: String
    let azimuth: Double
    /// Extra level drop at the far ear, in dB. Bigger = closer (near-field ILD).
    let farEarDb: Double
    /// Reflections as (delay seconds, gain). Fewer, earlier and quieter = a
    /// higher direct-to-reverberant ratio = closer.
    let taps: [(Double, Float)]
    /// Below ~200 Hz. The proximity effect: get close to any directional
    /// microphone and the low end rises. It is the reason a radio voice sounds
    /// like it is in the room with you, and it needs only one ear.
    var lowShelfDb: Double = 0
    /// Above ~4 kHz. Air absorbs the top end over distance, so less of it reads
    /// as further away.
    var highShelfDb: Double = 0
  }

  /// Which set of renderings is honest for what the listener is on.
  static func list(speakers: Bool) -> [Preset] { speakers ? monoPresets : presets }

  static func shelf(_ x: [Float], lowDb: Double, highDb: Double) -> [Float] {
    var y = x
    if lowDb != 0 {
      let g = Float(pow(10, lowDb / 20) - 1)
      let lp = onePole(x, 200)
      for i in 0..<y.count { y[i] += g * lp[i] }
    }
    if highDb != 0 {
      let g = Float(pow(10, highDb / 20) - 1)
      let lp = onePole(y, 4000)
      for i in 0..<y.count { y[i] += g * (y[i] - lp[i]) }
    }
    return y
  }

  // ── WHAT SURVIVES ON A LAPTOP SPEAKER ─────────────────────────────────────
  //
  // Direction does not. It is carried entirely by the difference between the two
  // ears, and speakers hand both channels to both ears; cancelling that crosstalk
  // was measured and abandoned, because buying +0.3 dB of the cue cost 1.9 dB of
  // change to the tone of the voice, and that trade sounds exactly as bad as it
  // reads.
  //
  // DISTANCE survives, because it does not need two ears. The far-field distance
  // cues are level, the direct-to-reverberant ratio, and spectrum -- all of them
  // monaural. So on speakers the axis is how FAR away the person is and how
  // close to your ear they feel, not where they are sitting. Every preset here
  // is identical in both channels, which is what makes it immune to the problem
  // that killed the other approach.
  static let monoPresets: [Preset] = [
    Preset(name: "As it is today", sub: "untouched", azimuth: 0, farEarDb: 0, taps: []),
    Preset(name: "Leaning in", sub: "very close, nothing between you",
           azimuth: 0, farEarDb: 0, taps: [], lowShelfDb: 5.5, highShelfDb: 1.5),
    Preset(name: "Right next to you", sub: "close, barely any room",
           azimuth: 0, farEarDb: 0,
           taps: [(0.0041, 0.10), (0.0079, 0.07)], lowShelfDb: 3.5, highShelfDb: 1),
    Preset(name: "In the room with you", sub: "a room, but a small one",
           azimuth: 0, farEarDb: 0,
           taps: [(0.0091, 0.26), (0.0168, 0.19), (0.0277, 0.13)]),
    Preset(name: "Across the table", sub: "further off, more room",
           azimuth: 0, farEarDb: 0,
           taps: [(0.0142, 0.42), (0.0238, 0.34), (0.0371, 0.27), (0.0503, 0.20)],
           highShelfDb: -2.5),
    Preset(name: "Warmer, no room", sub: "tone only — is it the room or the voice?",
           azimuth: 0, farEarDb: 0, taps: [], lowShelfDb: 3, highShelfDb: -1),
  ]

  static let presets: [Preset] = [
    Preset(name: "As it is today", sub: "one voice, both ears — inside your head",
           azimuth: 0, farEarDb: 0, taps: []),
    Preset(name: "Beside you", sub: "direction only, no room",
           azimuth: 32, farEarDb: 3, taps: []),
    Preset(name: "Beside you, in a room", sub: "direction plus early reflections",
           azimuth: 32, farEarDb: 3,
           taps: [(0.0068, 0.34), (0.0131, 0.24), (0.0204, 0.17), (0.0296, 0.12)]),
    Preset(name: "Right next to you", sub: "close: big ear difference, almost no room",
           azimuth: 34, farEarDb: 7.5,
           taps: [(0.0037, 0.13), (0.0071, 0.09)]),
    Preset(name: "Across the table", sub: "further: small ear difference, more room",
           azimuth: 26, farEarDb: 2,
           taps: [(0.0124, 0.40), (0.0203, 0.33), (0.0311, 0.26), (0.0442, 0.20)]),
    Preset(name: "Just in front of you", sub: "nearly centred, a little room",
           azimuth: 12, farEarDb: 1.2,
           taps: [(0.0079, 0.20), (0.0148, 0.14)]),
  ]

  // ── MOST CALLS HAPPEN ON THE LAPTOP'S OWN SPEAKERS ────────────────────────
  //
  // Everything above encodes the DIFFERENCE between the two ears, and that
  // difference only survives if each ear hears one channel. Out of speakers
  // both ears hear both channels, so the whole rendering is erased by acoustic
  // crosstalk somewhere between the screen and the head. A listening test run
  // through speakers therefore returns "they all sound the same" whether the
  // rendering is good, bad, or absent -- the same verdict as a true negative.
  //
  // The fix is not to give up on speakers, it is to cancel the crosstalk. Two
  // speakers this close together are the best case for it, not the worst:
  // Kirkeby, Nelson and Hamada's stereo dipole is exactly a pair spanning
  // 10-30 degrees, and a laptop lid is about 26 cm of span at arm's length,
  // which is 15. Their result is that a span this narrow is unusually ROBUST to
  // the listener moving, which is the usual reason this technique is a party
  // trick rather than a feature.
  //
  // Two deliberate compromises, both from the literature and both about not
  // sounding worse when the geometry is wrong:
  //
  //  * BANDLIMITED. Cancelling below ~300 Hz needs enormous boost, because down
  //    there the two ears genuinely do hear the same thing and inverting that
  //    is close to dividing by zero; above ~6 kHz the required precision is
  //    finer than the listener holds their head. Both bands are passed straight
  //    through, and only the band between them is cancelled.
  //  * PARTIAL. Cancelling 100% of a crosstalk path you have estimated wrongly
  //    is worse than cancelling 75% of it, so the loop is deliberately shy.
  // Aimed WIDER than the speakers actually are: about 15 degrees off at arm's
  // length, cancelled as though 20. Tuning at the nominal geometry gives the
  // best number for a listener holding perfectly still and the worst one for
  // everybody else. These three constants were swept, not chosen -- head
  // positions from 8 to 30 degrees (a metre away down to a hunch over the
  // keyboard), scored on BOTH ear cues, and only a narrow window of settings
  // helps the level difference everywhere without pulling the arrival time away
  // from the truth. 18-20 degrees at 0.7-0.85 depth is that window; everything
  // outside it fails at one end of the range or the other.
  //
  // Caveat worth stating plainly: this simulation is symmetric, so it can model
  // the listener sitting nearer or further, and cannot model them sitting off
  // to one side, which is the case this technique handles worst.
  static var dipoleDeg = 20.0
  /// 0 = off. DEFAULTED BACK TO OFF after listening: see the note on
  /// `speakerMode`. The sweep below optimised cue accuracy and was blind to what
  /// the cancellation does to the sound of the voice.
  static var ctcDepth: Float = 0.85
  enum SpeakerMode: String { case off, ctc, wide }
  /// ── THE MEASUREMENT SAID BETTER AND THE EARS SAID WORSE ──────────────────
  ///
  /// Crosstalk cancellation measurably restored the ear cues -- level difference
  /// from +2.2 to +4.3 dB, arrival time to within a tenth of a sample -- and the
  /// verdict on hearing it was "the speaker ones are really, really bad", with
  /// the plain headphone renderings preferred even when played on speakers.
  ///
  /// Both are true. Cancellation works by subtracting a delayed copy of the
  /// opposite channel, which is a comb filter; it moves the cue into place and
  /// puts notches through the voice on the way. The cue metrics cannot see a
  /// notch, so they reported a clean win. The ear is the ground truth and it
  /// says the timbre damage costs more than the cue is worth.
  ///
  /// Off by default until something scores well on BOTH.
  static var speakerMode = SpeakerMode.off
  /// Only the band between these is cancelled; see the note above.
  static var ctcLo = 150.0
  static var ctcHi = 6000.0

  /// What the far ear hears of a speaker: later, quieter, duller.
  private static func crossPath(_ halfAngleDeg: Double) -> (Int, Float, Float) {
    let th = halfAngleDeg * Double.pi / 180
    // The contralateral ear sits at th + 90 degrees from the speaker.
    let itd = (headR / c) * (th + sin(th)) * SR
    let alpha = Float(1.05 + 0.95 * cos(th + .pi / 2))
    return (max(1, Int(itd.rounded())), alpha * 0.5, Float(pow(10, -1.6 / 20)))
  }

  static func forSpeakers(_ L: [Float], _ R: [Float]) -> ([Float], [Float]) {
    switch speakerMode {
    case .off:  return (L, R)
    case .ctc:  return crosstalkCancel(L, R)
    case .wide: return widen(L, R)
    }
  }

  // ── THE GENTLE ALTERNATIVE ────────────────────────────────────────────────
  //
  // Crosstalk does two things to a stereo pair: it leaves the part both channels
  // share alone and it shrinks the part where they differ. Cancellation attacks
  // that by inverse-filtering the path, which is where the combing comes from.
  // The other way round is Blumlein's shuffler: split into what the channels
  // share and how they differ, and simply turn the difference up. There is no
  // delay, no subtraction of a delayed copy, and no notch -- and when the two
  // channels are identical the difference is zero, so a mono voice comes out
  // bit-for-bit unchanged. It cannot restore arrival time, only level.
  static var wideGain: Float = 2.0
  static func widen(_ L: [Float], _ R: [Float]) -> ([Float], [Float]) {
    let n = min(L.count, R.count)
    var oL = [Float](repeating: 0, count: n), oR = oL
    for i in 0..<n {
      let m = (L[i] + R[i]) * 0.5, s = (L[i] - R[i]) * 0.5 * wideGain
      oL[i] = m + s; oR[i] = m - s
    }
    return (oL, oR)
  }

  static func crosstalkCancel(_ L: [Float], _ R: [Float]) -> ([Float], [Float]) {
    let n = min(L.count, R.count)
    guard n > 8 else { return (L, R) }
    let (d, direct, lvl) = crossPath(dipoleDeg)
    let g = lvl * ctcDepth
    let a = Float(exp(-2 * Double.pi * 1600 / SR))

    // Split each channel into low / mid / high. Only mid is cancelled.
    let loL = onePole(L, ctcLo), loR = onePole(R, ctcLo)
    let bandL = onePole(L, ctcHi), bandR = onePole(R, ctcHi)
    var midL = [Float](repeating: 0, count: n), midR = midL
    var restL = midL, restR = midL
    for i in 0..<n {
      midL[i] = bandL[i] - loL[i]; midR[i] = bandR[i] - loR[i]
      restL[i] = L[i] - midL[i];   restR[i] = R[i] - midR[i]
    }

    // yL = midL - crosspath(yR), and the mirror. The delay is >= 1 sample so
    // the recursion is causal; loop gain is g^2 < 1 so it settles.
    var yL = [Float](repeating: 0, count: n), yR = yL
    var lpL: Float = 0, lpR: Float = 0
    for i in 0..<n {
      let fL = i >= d ? yL[i - d] : 0
      let fR = i >= d ? yR[i - d] : 0
      lpL = (1 - a) * fL + a * lpL
      lpR = (1 - a) * fR + a * lpR
      let xR = direct * fR + (1 - direct) * lpR
      let xL = direct * fL + (1 - direct) * lpL
      yL[i] = midL[i] - g * xR
      yR[i] = midR[i] - g * xL
    }
    for i in 0..<n { yL[i] += restL[i]; yR[i] += restR[i] }
    return (yL, yR)
  }

  /// What the two ears actually receive when a stereo pair is played over the
  /// speakers -- direct path plus the crosstalk from the opposite speaker. This
  /// exists so the cancellation can be CHECKED rather than believed.
  static func earsFromSpeakers(_ L: [Float], _ R: [Float],
                               halfAngleDeg: Double = dipoleDeg) -> ([Float], [Float]) {
    let n = min(L.count, R.count)
    let (d, direct, lvl) = crossPath(halfAngleDeg)
    let a = Float(exp(-2 * Double.pi * 1600 / SR))
    var eL = [Float](repeating: 0, count: n), eR = eL
    var lpL: Float = 0, lpR: Float = 0
    for i in 0..<n {
      let fL = i >= d ? L[i - d] : 0
      let fR = i >= d ? R[i - d] : 0
      lpL = (1 - a) * fL + a * lpL
      lpR = (1 - a) * fR + a * lpR
      eL[i] = L[i] + lvl * (direct * fR + (1 - direct) * lpR)
      eR[i] = R[i] + lvl * (direct * fL + (1 - direct) * lpL)
    }
    return (eL, eR)
  }

  static func render(_ x: [Float], _ p: Preset, speakers: Bool = false) -> ([Float], [Float]) {
    // A preset with no direction is a MONO treatment: identical in both
    // channels, so nothing about it can be erased by crosstalk.
    if p.azimuth == 0 {
      var y = x
      if !p.taps.isEmpty {
        let dull = onePole(x, 5200)
        for (t, g) in p.taps {
          var tap = dull; for i in 0..<tap.count { tap[i] *= g }
          let d = delay(tap, t * SR)
          if d.count > y.count { y += [Float](repeating: 0, count: d.count - y.count) }
          for i in 0..<d.count { y[i] += d[i] }
        }
      }
      y = shelf(y, lowDb: p.lowShelfDb, highDb: p.highShelfDb)
      var peak: Float = 1e-9
      for v in y { peak = max(peak, abs(v)) }
      if peak > 0.89 { let g = 0.89 / peak; for i in 0..<y.count { y[i] *= g } }
      return (y, y)
    }
    var (L, R) = render(x, azimuth: p.azimuth, farEarDb: p.farEarDb, taps: p.taps)
    if speakers { (L, R) = forSpeakers(L, R) }
    let n = min(L.count, R.count)
    var peak: Float = 1e-9
    for i in 0..<n { peak = max(peak, max(abs(L[i]), abs(R[i]))) }
    if peak > 0.89 { let g = 0.89 / peak; for i in 0..<n { L[i] *= g; R[i] *= g } }
    return (L, R)
  }

  static func render(_ x: [Float], azimuth: Double, farEarDb: Double,
                     taps: [(Double, Float)]) -> ([Float], [Float]) {
    let room = !taps.isEmpty
    let th = azimuth * Double.pi / 180
    let itd = (headR / c) * (th + sin(th)) * SR
    var R = shadow(x, cosToEar: cos(th - .pi / 2))
    var L = shadow(delay(x, itd), cosToEar: cos(th + .pi / 2))
    let farGain = Float(pow(10, -farEarDb / 20))
    for i in 0..<L.count { L[i] *= farGain }
    if room {
      // A small room seen from a seat beside you. The first reflection lands
      // ~7 ms after the direct sound: late enough to read as a room, early
      // enough not to read as an echo. DIFFERENT per ear on purpose -- it is the
      // difference between the ears that sounds spacious; the same reverb in
      // both is just a mono voice in a bucket.
      // The two ears get DIFFERENT reflection patterns. Identical reverb in both
      // is just a mono voice in a bucket; it is the mismatch between the ears
      // that reads as space rather than as effect.
      let tapsL = taps
      let tapsR = taps.map { (t, g) in (t * 1.19 + 0.0013, g * 0.88) }
      let dull = onePole(x, 5200)
      func add(_ dst: inout [Float], _ taps: [(Double, Float)]) {
        for (t, g) in taps {
          var tap = dull; for i in 0..<tap.count { tap[i] *= g }
          let d = delay(tap, t * SR)
          if d.count > dst.count { dst += [Float](repeating: 0, count: d.count - dst.count) }
          for i in 0..<d.count { dst[i] += d[i] }
        }
      }
      add(&L, tapsL); add(&R, tapsR)
    }
    let n = max(L.count, R.count)
    if L.count < n { L += [Float](repeating: 0, count: n - L.count) }
    if R.count < n { R += [Float](repeating: 0, count: n - R.count) }
    var peak: Float = 1e-9
    for i in 0..<n { peak = max(peak, max(abs(L[i]), abs(R[i]))) }
    let g = min(1.0, 0.89 / peak)
    for i in 0..<n { L[i] *= g; R[i] *= g }
    return (L, R)
  }
}

// ── Keeping a take ───────────────────────────────────────────────────────────
//
// Every comparison so far has been thrown away the moment the process ended, so
// "the one from before" could never be played again -- and a judgement you
// cannot repeat tomorrow is not a judgement. Takes go to the Desktop as ordinary
// WAV files: playable in anything, mailable, and still there next week.
enum Wav {
  static func write(_ L: [Float], _ R: [Float]?, to url: URL) {
    let ch = R == nil ? 1 : 2
    let n = R == nil ? L.count : min(L.count, R!.count)
    var pcm = Data(capacity: n * ch * 2)
    for i in 0..<n {
      func s16(_ v: Float) -> Int16 { Int16(max(-32768, min(32767, v * 32767))) }
      withUnsafeBytes(of: s16(L[i]).littleEndian) { pcm.append(contentsOf: $0) }
      if let R { withUnsafeBytes(of: s16(R[i]).littleEndian) { pcm.append(contentsOf: $0) } }
    }
    var d = Data()
    func str(_ x: String) { d.append(x.data(using: .ascii)!) }
    func u32(_ x: UInt32) { withUnsafeBytes(of: x.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ x: UInt16) { withUnsafeBytes(of: x.littleEndian) { d.append(contentsOf: $0) } }
    str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
    str("fmt "); u32(16); u16(1); u16(UInt16(ch)); u32(UInt32(SR))
    u32(UInt32(Int(SR) * ch * 2)); u16(UInt16(ch * 2)); u16(16)
    str("data"); u32(UInt32(pcm.count))
    d.append(pcm)
    try? d.write(to: url)
  }

  /// Mono 16-bit read, for pulling old takes back off the disk at launch.
  /// Deliberately minimal: it only ever has to read what write() produced.
  static func readMono(_ url: URL) -> [Float]? {
    guard let d = try? Data(contentsOf: url), d.count > 44 else { return nil }
    func u32(_ o: Int) -> UInt32 {
      UInt32(d[o]) | UInt32(d[o+1]) << 8 | UInt32(d[o+2]) << 16 | UInt32(d[o+3]) << 24
    }
    func u16(_ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o+1]) << 8 }
    guard d[0] == 0x52, d[1] == 0x49 else { return nil }        // "RI"
    var o = 12, ch = 1, bits = 16
    var data: Range<Int>? = nil
    while o + 8 <= d.count {
      let id = String(bytes: d[o..<o+4], encoding: .ascii) ?? ""
      let len = Int(u32(o + 4))
      let body = o + 8
      if id == "fmt " , body + 16 <= d.count { ch = Int(u16(body + 2)); bits = Int(u16(body + 14)) }
      if id == "data" { data = body..<min(d.count, body + len); break }
      o = body + len + (len & 1)
    }
    guard let r = data, bits == 16, ch >= 1 else { return nil }
    let frames = r.count / (2 * ch)
    var out = [Float](repeating: 0, count: frames)
    for i in 0..<frames {
      let o = r.lowerBound + i * 2 * ch
      out[i] = Float(Int16(bitPattern: u16(o))) / 32767
    }
    return out
  }
}

// ── Capture ──────────────────────────────────────────────────────────────────
final class Recorder {
  private let engine = AVAudioEngine()
  private var conv: AVAudioConverter?
  private(set) var samples: [Float] = []
  private(set) var level: Float = 0
  private(set) var peak: Float = 0
  var onLevel: ((Float) -> Void)?

  /// The single most common reason a Mac sounds broken on a call, and the one
  /// nobody finds: the input slider. At 14% a voice reaches the far end 16 dB
  /// above the hiss, and no processing anywhere downstream can undo it -- the
  /// quiet parts were already thrown away by the converter. Set the gain BEFORE
  /// the converter and none of it happens.
  /// Which of Apple's microphone modes is in force. It is a Control Center
  /// toggle an app is not allowed to set -- `preferredMicrophoneMode` is
  /// class/readonly -- so the only honest thing to do is report it, because two
  /// takes made under different modes are not comparable and nothing else on
  /// screen would say so.
  static func micMode() -> String {
    switch AVCaptureDevice.activeMicrophoneMode {
    case .voiceIsolation: return "Voice Isolation ON"
    case .wideSpectrum: return "Wide Spectrum"
    case .standard: return "Standard"
    @unknown default: return "unknown"
    }
  }

  // ── WHAT YOU ARE LISTENING ON DECIDES WHICH RENDERING IS CORRECT ──────────
  //
  // This is not a preference, it is a fact about the room, and it silently
  // decides whether any of this works. There is no honest way to offer a
  // headphone rendering to somebody on speakers and call the result a listening
  // test -- so the app reads the output device and renders for it.
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

    // Anything not wired into the machine -- USB, Bluetooth, an adapter -- is
    // overwhelmingly a headset. Built-in could still be the headphone jack, and
    // the data source says which: 'hdpn'.
    var t = UInt32(0); sz = 4
    a.mSelector = kAudioDevicePropertyTransportType
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &t) == noErr else { return (name, true) }
    if t != kAudioDeviceTransportTypeBuiltIn { return (name, false) }

    var src = UInt32(0); sz = 4
    a.mSelector = kAudioDevicePropertyDataSource
    a.mScope = kAudioObjectPropertyScopeOutput
    if AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &src) == noErr {
      if src == 0x6864706E { return (name + " (headphone jack)", false) }   // 'hdpn'
    }
    return (name, true)
  }

  static func raiseInputIfLow() -> String {
    var dev = AudioDeviceID(0); var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr
    else { return "" }
    var va = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
      mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var cur: Float32 = -1; sz = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(dev, &va, 0, nil, &sz, &cur) == noErr else { return "" }
    if cur >= 0.5 { return String(format: "mic input %d%%", Int(cur * 100)) }
    var settable: DarwinBoolean = false
    guard AudioObjectIsPropertySettable(dev, &va, &settable) == noErr, settable.boolValue
    else { return String(format: "mic input %d%% (cannot be raised)", Int(cur * 100)) }
    var want: Float32 = 0.75
    guard AudioObjectSetPropertyData(dev, &va, 0, nil, UInt32(MemoryLayout<Float32>.size), &want) == noErr
    else { return String(format: "mic input %d%%", Int(cur * 100)) }
    var got: Float32 = -1; sz = UInt32(MemoryLayout<Float32>.size)
    _ = AudioObjectGetPropertyData(dev, &va, 0, nil, &sz, &got)
    return String(format: "mic input raised %d%% -> %d%%", Int(cur * 100), Int(got * 100))
  }

  /// PURE means nothing between the microphone and the file: no echo canceller,
  /// no gain control, no Voice Isolation. macOS applies its microphone modes only
  /// to apps that use voice processing, so switching this off is also the only
  /// way to hear the room as the microphone actually hears it -- which is the
  /// reference every processed version should be judged against.
  var pureMic = true

  func start() throws {
    samples.removeAll(); samples.reserveCapacity(48000 * 30); peak = 0
    let input = engine.inputNode
    // ── VOICE PROCESSING IS A DUPLEX UNIT, AND IT NEEDS BOTH HALVES ──────────
    //
    // "Like a call" came out as noise with no voice in it. The unit behind it is
    // the same VoiceProcessingIO the call uses, and it is duplex by nature: it
    // cancels the echo of what is being PLAYED out of what is coming IN, so it
    // expects a render side. With only an input tap attached there is no render
    // side, the engine ran the input at a format nobody had agreed on, and the
    // capture was garbage.
    //
    // So both ends get it, and the graph is completed with a silent path to the
    // mixer -- silent because this is a recorder, not a call, and nothing should
    // come out of the speaker while it runs.
    try? input.setVoiceProcessingEnabled(!pureMic)
    // Read the format AFTER all of that: enabling voice processing changes it,
    // and a converter built from the old one is the silence this started as.
    let inFmt = input.outputFormat(forBus: 0)
    fputs("capture: \(pureMic ? "pure" : "voice-processed") \(inFmt.sampleRate) Hz "
        + "\(inFmt.channelCount) ch\n", stderr)
    // ── VOICE PROCESSING HANDS BACK FIVE CHANNELS ────────────────────────────
    //
    // Measured: pure capture is 48000 Hz 1 ch, and the same node with voice
    // processing enabled reports 48000 Hz 5 ch. Connecting that to the mixer
    // failed outright (-10875) and building a mono converter from it produced
    // the noise that was actually shipped -- a five-channel buffer read as
    // though it were one is every channel interleaved into nonsense, which is
    // exactly what noise sounds like.
    //
    // The rate already matches, so there is nothing to convert: take channel 0
    // and leave the converter out of the path entirely. Fewer moving parts, and
    // the one that was moving was the one that broke.
    let direct = (inFmt.sampleRate == SR)
    if direct { conv = nil }
    let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SR,
                               channels: 1, interleaved: false)!
    conv = AVAudioConverter(from: inFmt, to: outFmt)
    input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in
      guard let self else { return }
      if direct {
        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        var pk: Float = 0
        for i in 0..<n { let v = ch[i]; self.samples.append(v); pk = max(pk, abs(v)) }
        self.peak = max(self.peak, pk)
        self.level = self.level * 0.7 + pk * 0.3
        DispatchQueue.main.async { self.onLevel?(self.level) }
        return
      }
      guard let conv = self.conv else { return }
      let cap = AVAudioFrameCount(Double(buf.frameLength) * SR / inFmt.sampleRate) + 64
      guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
      var err: NSError?
      var done = false
      conv.convert(to: out, error: &err) { _, status in
        if done { status.pointee = .noDataNow; return nil }
        done = true; status.pointee = .haveData; return buf
      }
      guard err == nil, let ch = out.floatChannelData?[0] else { return }
      let n = Int(out.frameLength)
      var pk: Float = 0
      for i in 0..<n { let v = ch[i]; self.samples.append(v); pk = max(pk, abs(v)) }
      self.peak = max(self.peak, pk)
      self.level = self.level * 0.7 + pk * 0.3
      DispatchQueue.main.async { self.onLevel?(self.level) }
    }
    engine.prepare()
    try engine.start()
  }

  func stop() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    // Leave no connection behind: the next take may be in the other mode, and a
    // graph built for voice processing does not survive being reused without it.
    engine.disconnectNodeOutput(engine.inputNode)
    engine.mainMixerNode.outputVolume = 1
  }

  /// How far the voice stands above the room. Below about 25 dB nothing else
  /// matters -- amplifying a recording amplifies its hiss by exactly as much.
  var snrDb: Double {
    guard samples.count > 48000 else { return 0 }
    let blk = 4800
    var lv: [Double] = []
    var i = 0
    while i + blk < samples.count {
      var s = 0.0
      for k in i..<(i + blk) { s += Double(samples[k]) * Double(samples[k]) }
      lv.append((s / Double(blk)).squareRoot()); i += blk
    }
    guard lv.count > 8 else { return 0 }
    lv.sort()
    let quiet = max(lv[lv.count / 10], 1e-9), loud = lv[lv.count - lv.count / 10 - 1]
    return 20 * log10(loud / quiet)
  }
}

// ── Playback ─────────────────────────────────────────────────────────────────
final class Player {
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private var wired = false
  var onDone: (() -> Void)?

  func play(_ L: [Float], _ R: [Float]) {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SR,
                            channels: 2, interleaved: false)!
    if !wired {
      engine.attach(node)
      engine.connect(node, to: engine.mainMixerNode, format: fmt)
      wired = true
    }
    let n = AVAudioFrameCount(min(L.count, R.count))
    guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
    buf.frameLength = n
    let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
    for i in 0..<Int(n) { l[i] = L[i]; r[i] = R[i] }
    node.stop()
    if !engine.isRunning { try? engine.start() }
    node.scheduleBuffer(buf, at: nil, options: .interrupts) { [weak self] in
      DispatchQueue.main.async { self?.onDone?() }
    }
    node.play()
  }
  func stop() { node.stop() }
}

// ── The window ───────────────────────────────────────────────────────────────
//
// One decision per screen. Record, then hear three versions. No numbers on the
// buttons and no settings: the whole instrument is "which of these sounds like a
// person", and anything else on screen is something to read instead of listen.

enum Ink {
  static let bg = NSColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)
  static let fg = NSColor(srgbRed: 0.91, green: 0.92, blue: 0.93, alpha: 1)
  static let dim = NSColor(srgbRed: 0.55, green: 0.58, blue: 0.63, alpha: 1)
  static let hot = NSColor(srgbRed: 0.94, green: 0.29, blue: 0.33, alpha: 1)
  static let good = NSColor(srgbRed: 0.35, green: 0.80, blue: 0.55, alpha: 1)
  static let warn = NSColor(srgbRed: 0.98, green: 0.75, blue: 0.14, alpha: 1)
}

final class Meter: NSView {
  var level: Float = 0 { didSet { needsDisplay = true } }
  override var isFlipped: Bool { true }
  override func draw(_ r: NSRect) {
    NSColor(white: 1, alpha: 0.07).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    // A meter you can SEE move is the whole reason this is an app: the terminal
    // version recorded silence twice and neither of us knew until afterwards.
    let w = bounds.width * CGFloat(min(1, level * 3.2))
    guard w > 1 else { return }
    (level > 0.9 ? Ink.hot : level > 0.06 ? Ink.good : Ink.warn).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height),
                 xRadius: 4, yRadius: 4).fill()
  }
}

final class Btn: NSView {
  var title = "" { didSet { needsDisplay = true } }
  var sub = "" { didSet { needsDisplay = true } }
  var enabled = true { didSet { needsDisplay = true } }
  var playing = false { didSet { needsDisplay = true } }
  var onTap: (() -> Void)?
  private var hot = false
  override var isFlipped: Bool { true }

  override func draw(_ r: NSRect) {
    let bg = !enabled ? NSColor(white: 1, alpha: 0.04)
           : playing ? Ink.good.withAlphaComponent(0.22)
           : hot ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 1, alpha: 0.08)
    bg.setFill()
    let p = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
    p.fill()
    (playing ? Ink.good : NSColor(white: 1, alpha: 0.10)).setStroke()
    p.lineWidth = playing ? 2 : 1
    p.stroke()
    let c = enabled ? Ink.fg : Ink.dim
    let t = NSMutableParagraphStyle(); t.alignment = .center
    let y = sub.isEmpty ? (bounds.height - (bounds.height < 34 ? 17 : 20)) / 2 : bounds.height / 2 - 21
    (title as NSString).draw(in: NSRect(x: 8, y: y, width: bounds.width - 16, height: 24),
      withAttributes: [.font: NSFont.systemFont(ofSize: bounds.height < 34 ? 12 : 15,
                                                weight: bounds.height < 34 ? .regular : .semibold),
                       .foregroundColor: c, .paragraphStyle: t])
    if !sub.isEmpty {
      (sub as NSString).draw(in: NSRect(x: 10, y: bounds.height / 2 + 2, width: bounds.width - 20, height: 34),
        withAttributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: Ink.dim, .paragraphStyle: t])
    }
  }
  override func mouseEntered(with e: NSEvent) { hot = true; needsDisplay = true }
  override func mouseExited(with e: NSEvent) { hot = false; needsDisplay = true }
  override func mouseDown(with e: NSEvent) { if enabled { onTap?() } }
  override func updateTrackingAreas() {
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                   owner: self, userInfo: nil))
  }
  /// The window is usually behind something when you reach for it. Without this
  /// the first click is spent activating the app and the button does nothing --
  /// which reads as a broken button, not as a focus rule.
  override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}

final class Lab: NSObject, NSApplicationDelegate {
  var win: NSWindow!
  let rec = Recorder()
  let player = Player()
  var meter = Meter()
  var recBtn = Btn()
  var status = NSTextField(labelWithString: "")
  var advice = NSTextField(labelWithString: "")
  var plays: [Btn] = []
  var modeBtns: [Btn] = []
  // ── EVERY TAKE STAYS PLAYABLE ─────────────────────────────────────────────
  //
  // Pressing Record used to disable the three play buttons, so starting a new
  // recording destroyed your ability to hear the last one -- which is precisely
  // when you want it, because the only useful comparison is against what came
  // before. Takes are kept as their raw mono and re-rendered on selection; the
  // rendering is a handful of linear passes and costs less than the click.
  struct Take { let label: String; let raw: [Float] }
  var history: [Take] = []
  var selected = -1
  var takeRows: [Btn] = []
  var takeNo = 0
  var lastFolder: URL?
  var openBtn = Btn()
  var outLabel = NSTextField(labelWithString: "")
  var lastOut = ""
  var outTimer: Timer?
  var takes: [(String, [Float], [Float])] = []
  var recording = false
  var timer: Timer?
  var startedAt = Date()

  func applicationDidFinishLaunching(_ n: Notification) {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 790),
                     styleMask: [.titled, .closable, .miniaturizable],
                     backing: .buffered, defer: false)
    w.title = "Voice Lab"
    w.backgroundColor = Ink.bg
    w.center()
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 790))
    root.wantsLayer = true
    root.layer?.backgroundColor = Ink.bg.cgColor

    // AppKit measures from the bottom; people read from the top. Every position
    // below is "distance down from the top edge", converted once here. The
    // previous version nudged bottom-up constants one at a time and three
    // elements ended up drawn on top of each other.
    let H: CGFloat = 790
    func top(_ down: CGFloat, _ h: CGFloat) -> CGFloat { H - down - h }

    func label(_ s: String, _ size: CGFloat, _ col: NSColor, _ y: CGFloat, _ weight: NSFont.Weight = .regular) -> NSTextField {
      let f = NSTextField(labelWithString: s)
      f.font = .systemFont(ofSize: size, weight: weight)
      f.textColor = col
      f.alignment = .center
      f.frame = NSRect(x: 20, y: y, width: 520, height: size + 10)
      root.addSubview(f)
      return f
    }
    _ = label("Record your voice, then hear it six ways.", 15, Ink.fg, top(16, 25), .semibold)
    // WHAT YOU ARE LISTENING ON IS NOT A PREFERENCE, IT DECIDES WHICH RENDERING
    // IS CORRECT -- so it is read from the system and shown, not asked for.
    outLabel = label("", 12, Ink.warn, top(46, 22))

    // ── WHAT THE MICROPHONE IS ALLOWED TO DO TO YOU ──────────────────────────
    //
    // Two capture chains, chosen before recording, because they cannot be
    // compared any other way: processing happens at capture and cannot be undone
    // afterwards. "Pure" is the reference -- the room as the microphone actually
    // hears it. "Like a call" is Kin's own chain, echo canceller and all, which
    // is also the only mode macOS applies Voice Isolation to.
    for (i, t) in [("Pure mic", "nothing between you and the file"),
                   ("Like a call", "echo canceller + gain control")].enumerated() {
      let b = Btn(frame: NSRect(x: 40 + CGFloat(i) * 245, y: top(84, 46), width: 235, height: 46))
      b.title = t.0; b.sub = t.1
      b.playing = (i == 0)
      b.onTap = { [weak self] in self?.setMode(pure: i == 0) }
      root.addSubview(b)
      modeBtns.append(b)
    }
    recBtn.frame = NSRect(x: 180, y: top(138, 48), width: 200, height: 48)
    recBtn.title = "Record"
    recBtn.onTap = { [weak self] in self?.toggle() }
    root.addSubview(recBtn)

    meter.frame = NSRect(x: 100, y: top(194, 8), width: 360, height: 8)
    root.addSubview(meter)

    status.font = .systemFont(ofSize: 12)
    status.textColor = Ink.dim
    status.alignment = .center
    status.frame = NSRect(x: 20, y: top(208, 18), width: 520, height: 18)
    status.stringValue = "Press Record and talk for about ten seconds."
    root.addSubview(status)

    // TOP TO BOTTOM in the order they should be heard: nearest-to-today first,
    // then direction, then distance. AppKit lays subviews out from the bottom,
    // so this once put "as it is today" -- the thing everything is compared
    // against -- underneath its own comparisons.
    for (i, p) in Spatial.list(speakers: Recorder.outputDevice().speakers).enumerated() {
      let b = Btn(frame: NSRect(x: 40, y: top(236 + CGFloat(i) * 52, 46), width: 480, height: 46))
      b.title = p.name; b.sub = p.sub; b.enabled = false
      b.onTap = { [weak self] in self?.playTake(i) }
      root.addSubview(b)
      plays.append(b)
    }
    _ = label("Your takes — click one to load it", 11, Ink.dim, top(578, 16))
    for i in 0..<4 {
      let b = Btn(frame: NSRect(x: 40, y: top(600 + CGFloat(i) * 32, 28), width: 480, height: 28))
      b.enabled = false
      b.onTap = { [weak self] in self?.select(i) }
      root.addSubview(b)
      takeRows.append(b)
    }
    openBtn.frame = NSRect(x: 190, y: top(736, 30), width: 180, height: 30)
    openBtn.title = "Show recordings"
    openBtn.enabled = false
    openBtn.onTap = { [weak self] in
      if let f = self?.lastFolder { NSWorkspace.shared.open(f) }
    }
    root.addSubview(openBtn)

    advice.font = .systemFont(ofSize: 11)
    advice.textColor = Ink.dim
    advice.alignment = .center
    advice.frame = NSRect(x: 20, y: top(552, 16), width: 520, height: 16)
    root.addSubview(advice)

    refreshOut()
    loadHistory()
    outTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
      self?.refreshOut()
    }

    w.contentView = root
    w.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    win = w
    player.onDone = { [weak self] in self?.plays.forEach { $0.playing = false } }
    advice.stringValue = Recorder.raiseInputIfLow() + "   ·   macOS mic mode: " + Recorder.micMode()
  }

  func setMode(pure: Bool) {
    guard !recording else { return }
    rec.pureMic = pure
    modeBtns[0].playing = pure
    modeBtns[1].playing = !pure
    status.textColor = Ink.dim
    status.stringValue = pure
      ? "Pure mic — the room exactly as the microphone hears it."
      : "Like a call — echo canceller and gain control on, same as Kin."
  }

  func toggle() {
    if recording { finish(); return }
    do { try rec.start() } catch {
      status.stringValue = "Could not open the microphone: \(error.localizedDescription)"
      return
    }
    recording = true
    startedAt = Date()
    recBtn.title = "Stop"
    // The previous take stays playable while this one records. Disabling it here
    // was the whole complaint: Record erased the thing you were comparing to.
    rec.onLevel = { [weak self] l in self?.meter.level = l }
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      guard let self, self.recording else { return }
      let t = Date().timeIntervalSince(self.startedAt)
      self.status.stringValue = String(format: "recording  %.0f s   —  say anything, normally", t)
      if t > 30 { self.finish() }
    }
  }

  func finish() {
    guard recording else { return }
    recording = false
    timer?.invalidate()
    rec.stop()
    recBtn.title = "Record again"
    meter.level = 0
    let x = rec.samples
    guard x.count > 24000 else {
      status.stringValue = "Too short — hold Record and talk for about ten seconds."
      return
    }
    // SAY WHETHER THE RECORDING IS USABLE, before anybody judges anything by it.
    // A voice sitting close to the noise floor sounds bad in every version, and
    // then the comparison measures the microphone instead of the rendering.
    let snr = rec.snrDb, pk = rec.peak
    if pk < 0.03 || snr < 15 {
      status.stringValue = String(format: "Too quiet to judge — voice only %.0f dB above the room. Move closer and record again.", snr)
      status.textColor = Ink.hot
      return
    }
    status.textColor = snr > 25 ? Ink.good : Ink.warn
    status.stringValue = String(format: "%.0f s recorded · loudest %.2f · voice %.0f dB above the room%@",
                                Double(x.count) / SR, pk, snr,
                                snr > 25 ? "" : " (a bit noisy)")
    var norm = x
    let g = 0.7 / max(pk, 1e-6)
    for i in 0..<norm.count { norm[i] *= g }
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    history.insert(Take(label: String(format: "%@  ·  %@  ·  %.0f s  ·  %.0f dB",
                                      f.string(from: Date()),
                                      rec.pureMic ? "pure mic" : "like a call",
                                      Double(norm.count) / SR, snr),
                        raw: norm), at: 0)
    if history.count > 4 { history.removeLast() }
    select(0)
    save(raw: norm)
    advice.stringValue = "Play them in order. Ask where the voice is, not whether it is clean."
  }

  /// Reads the output device and, if it changed, re-renders the loaded take for
  /// it. Plugging in headphones mid-session should change what you hear next
  /// time you press play, without you having to know that it should.
  func refreshOut() {
    let (name, speakers) = Recorder.outputDevice()
    let key = name + (speakers ? "|s" : "|h")
    guard key != lastOut else { return }
    let first = lastOut.isEmpty
    lastOut = key
    outLabel.stringValue = speakers
      ? "Playing through \(name) — these are distances, not directions."
      : "Playing through \(name) — direction works here."
    outLabel.textColor = Ink.good
    for (i, p) in Spatial.list(speakers: speakers).enumerated() where i < plays.count {
      plays[i].title = p.name
      plays[i].sub = p.sub
    }
    if !first && selected >= 0 { select(selected) }
  }

  /// Load one of the kept takes into the play buttons. Re-rendering here rather
  /// than storing every version of every take: the passes are linear and finish
  /// inside the click, and keeping them all would be tens of megabytes to save a
  /// few milliseconds nobody can feel. It also means a take recorded on speakers
  /// is re-rendered for headphones the moment you plug them in.
  func select(_ i: Int) {
    guard i < history.count else { return }
    selected = i
    let raw = history[i].raw
    let speakers = Recorder.outputDevice().speakers
    takes = Spatial.list(speakers: speakers).map { p in
      let (L, R) = Spatial.render(raw, p, speakers: speakers)
      return (p.name, L, R)
    }
    plays.forEach { $0.enabled = true; $0.playing = false }
    refreshRows()
  }

  // ── TAKES OUTLIVE THE PROCESS ────────────────────────────────────────────
  //
  // The history used to live only in memory, so quitting the app -- or me
  // installing a new build -- silently threw away every recording the list
  // could reach, while the files sat on the Desktop the whole time. "I'm not
  // able to play the previous recordings" was exactly this. The raw mono take
  // is the only thing worth keeping, because every rendering is derived from it.
  func loadHistory() {
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Desktop/Voice Lab")
    let fm = FileManager.default
    guard let kids = try? fm.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
    func when(_ u: URL) -> Date {
      (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
    let f = DateFormatter(); f.dateFormat = "d MMM, HH:mm"; f.timeZone = .current
    for folder in kids.sorted(by: { when($0) > when($1) }) {
      guard history.count < 4 else { break }
      let raw = folder.appendingPathComponent("0 raw mono.wav")
      guard let x = Wav.readMono(raw), x.count > Int(SR) else { continue }
      let mode = folder.lastPathComponent.hasSuffix("like-a-call") ? "like a call" : "pure mic"
      history.append(Take(label: String(format: "%@  ·  %@  ·  %.0f s",
                                        f.string(from: when(folder)), mode, Double(x.count) / SR),
                          raw: x))
      if lastFolder == nil { lastFolder = folder }
    }
    if !history.isEmpty {
      openBtn.enabled = true
      select(0)
      status.stringValue = "Loaded your last \(history.count) recording\(history.count == 1 ? "" : "s"). Press play, or record a new one."
    }
    refreshRows()
  }

  func refreshRows() {
    for (i, row) in takeRows.enumerated() {
      if i < history.count {
        row.enabled = true
        row.title = history[i].label
        row.playing = (i == selected)
      } else {
        row.enabled = false
        row.title = ""
        row.playing = false
      }
    }
  }

  /// Written the moment a take is judged usable, not on a button, because the
  /// take that gets lost is always the one nobody thought to keep.
  func save(raw: [Float]) {
    takeNo += 1
    // ISO8601DateFormatter is UTC by default, so a take made at 2am was filed
    // under the previous evening and looked like somebody else's.
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HH-mm-ss"
    fmt.timeZone = .current
    let stamp = fmt.string(from: Date())
    let mode = rec.pureMic ? "pure-mic" : "like-a-call"
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Desktop/Voice Lab/\(stamp) \(mode)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    Wav.write(raw, nil, to: dir.appendingPathComponent("0 raw mono.wav"))
    for (i, t) in takes.enumerated() {
      Wav.write(t.1, t.2, to: dir.appendingPathComponent("\(i + 1) \(t.0).wav"))
    }
    // A note in the folder, because in a week the folder name will not be enough
    // to say what was different about this take.
    let note = """
      Voice Lab take \(takeNo)
      capture:      \(mode)
      macOS mic:    \(Recorder.micMode())
      input level:  \(Recorder.raiseInputIfLow())
      length:       \(String(format: "%.1f", Double(raw.count) / SR)) s
      voice above room noise: \(String(format: "%.0f", rec.snrDb)) dB

      0 raw mono   what the microphone captured, mono
      1 today      the same signal in both ears -- what a call sounds like now
      2 beside you head model only: time and level difference between your ears
      3 in a room  head model plus early reflections, arriving AFTER the direct
                   sound, so it costs no latency

      Listen on headphones. The effect is entirely interaural and collapses
      on speakers.
      """
    try? note.write(to: dir.appendingPathComponent("what this is.txt"),
                    atomically: true, encoding: .utf8)
    lastFolder = dir
    openBtn.enabled = true
    openBtn.title = "Show recordings (\(takeNo))"
  }

  func playTake(_ i: Int) {
    guard i < takes.count else { return }
    plays.forEach { $0.playing = false }
    plays[i].playing = true
    player.play(takes[i].1, takes[i].2)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }
}

// ── The app testing its own capture ──────────────────────────────────────────
//
// "Like a call" produced noise with no voice in it, and there was no way to find
// that out except by asking a person to press a button and listen. A GUI that
// can only be checked by a human is a GUI whose bugs ship. `--selftest` records
// in both modes and says what it got.
//
// Zero-crossing rate is the discriminator: speech crosses zero a few hundred to
// about two thousand times a second and varies as it goes; broadband noise
// crosses far more often and stays flat. It cannot tell a good voice from a bad
// one, but it can tell a voice from garbage, which is the failure that happened.
// ── Does the cancellation actually reach the ears? ───────────────────────────
//
// The whole speaker path rests on a claim about physics, so it gets measured
// against a known answer instead of believed. A voice is rendered to the ear
// difference it is supposed to have, then played through a simulated pair of
// laptop speakers, and what arrives at each ear is measured -- with the
// cancellation and without it.
//
// The important half is the LAST column. The canceller assumes the listener is
// 15 degrees off each speaker; the simulation is also run at 11 and 19, which
// is the head moving. Inverting a path you have estimated wrongly is the way
// this technique earns its reputation for sounding worse than doing nothing,
// so a pass requires it to still help when the geometry is wrong.
func argVal(_ k: String) -> Double? {
  let a = CommandLine.arguments
  guard let i = a.firstIndex(of: k), i + 1 < a.count, let v = Double(a[i + 1]) else { return nil }
  return v
}
if let v = argVal("--ctc-depth") { Spatial.ctcDepth = Float(v) }
if let v = argVal("--ctc-deg")   { Spatial.dipoleDeg = v }
if let v = argVal("--ctc-lo")    { Spatial.ctcLo = v }
if let v = argVal("--ctc-hi")    { Spatial.ctcHi = v }
if let v = argVal("--wide-gain") { Spatial.wideGain = Float(v) }
if CommandLine.arguments.contains("--spatial-test") || CommandLine.arguments.contains("--selftest") {
  func band(_ x: [Float]) -> [Float] {
    let lo = Spatial.onePole(x, 300), hi = Spatial.onePole(x, 6000)
    return (0..<x.count).map { hi[$0] - lo[$0] }
  }
  func rms(_ x: [Float]) -> Double {
    guard !x.isEmpty else { return 0 }
    var a = 0.0; for v in x { a += Double(v) * Double(v) }
    return (a / Double(x.count)).squareRoot()
  }
  /// Level difference between the ears, in dB, in the band the cue lives in.
  func ild(_ l: [Float], _ r: [Float]) -> Double {
    let a = rms(band(l)), b = rms(band(r))
    guard a > 1e-12, b > 1e-12 else { return 0 }
    return 20 * log10(b / a)
  }
  /// Arrival-time difference between the ears, in samples.
  ///
  /// VALIDATE THE RULER FIRST. The obvious version -- cross-correlate the two
  /// ears over the whole voice band -- reported the timing collapsing from 13
  /// samples to 6 under cancellation, and 6 is exactly the delay of the
  /// crosstalk path. The correlator was locking onto the reflection of the
  /// opposite speaker rather than onto the voice. Timing is carried below about
  /// 1.5 kHz anyway, and down there the crosstalk comb is far weaker, so the
  /// estimate is made in that band with the peak interpolated between samples.
  func itd(_ l: [Float], _ r: [Float]) -> Double {
    func low(_ x: [Float]) -> [Float] {
      let lo = Spatial.onePole(x, 150), hi = Spatial.onePole(x, 1500)
      return (0..<x.count).map { hi[$0] - lo[$0] }
    }
    let a = low(l), b = low(r)
    let n = min(a.count, b.count)
    guard n > 4000 else { return 0 }
    var c = [Double](repeating: 0, count: 51)
    for (k, lag) in (-25...25).enumerated() {
      var acc = 0.0
      var i = max(0, -lag)
      let end = min(n, n - lag)
      while i < end { acc += Double(a[i]) * Double(b[i + lag]); i += 1 }
      c[k] = acc
    }
    var k = 0; for i in 1..<c.count where c[i] > c[k] { k = i }
    var frac = 0.0
    if k > 0, k < c.count - 1 {
      let d = c[k - 1] - 2 * c[k] + c[k + 1]
      if abs(d) > 1e-12 { frac = 0.5 * (c[k - 1] - c[k + 1]) / d }
      frac = max(-1, min(1, frac))
    }
    return Double(k - 25) + frac
  }

  // ── THE METRIC THAT WAS MISSING ──────────────────────────────────────────
  //
  // Cue accuracy went up and the sound got worse, which means the instrument
  // could not see the damage. Cancellation subtracts a delayed copy of the
  // opposite channel; that is a comb filter, and a comb puts a row of notches
  // through the voice. Notches are invisible to a level difference and to a
  // cross-correlation, so both reported a clean win.
  //
  // RIPPLE is what they were missing: the magnitude spectrum at the ear,
  // measured against a smoothed version of itself. A smooth spectrum with a
  // tilt is a tone colour. A spectrum with regular deep notches in it is the
  // hollow, phasey sound of comb filtering, and it shows up here as a big
  // number no matter where the notches happen to land.
  /// Average magnitude spectrum in dB, Welch-averaged over Hann windows.
  func spectrum(_ x: [Float]) -> [Double] {
    let log2n = vDSP_Length(12), n = 1 << 12
    guard x.count >= n * 2, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    else { return [] }
    defer { vDSP_destroy_fftsetup(setup) }
    var win = [Float](repeating: 0, count: n)
    vDSP_hann_window(&win, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    var mag = [Float](repeating: 0, count: n / 2)
    var frames = 0, off = 0
    while off + n <= x.count {
      var re = [Float](repeating: 0, count: n / 2), im = re
      var chunk = [Float](repeating: 0, count: n)
      vDSP_vmul(Array(x[off..<off + n]), 1, win, 1, &chunk, 1, vDSP_Length(n))
      chunk.withUnsafeBufferPointer { p in
        p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { c in
          var split = DSPSplitComplex(realp: &re, imagp: &im)
          vDSP_ctoz(c, 2, &split, 1, vDSP_Length(n / 2))
          vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
          var m = [Float](repeating: 0, count: n / 2)
          vDSP_zvabs(&split, 1, &m, 1, vDSP_Length(n / 2))
          for i in 0..<n / 2 { mag[i] += m[i] }
        }
      }
      frames += 1; off += n / 2
    }
    guard frames > 0 else { return [] }
    return (0..<n / 2).map { 20 * log10(Double(mag[$0]) / Double(frames) + 1e-9) }
  }

  // ── THE METRIC THAT WAS MISSING ──────────────────────────────────────────
  //
  // Cue accuracy went up and the sound got worse, which means the instrument
  // could not see the damage. Cancellation works by subtracting a delayed copy
  // of the opposite channel, and anything of that shape rearranges the spectrum
  // -- a broad hollowing, a row of notches, or both. A level difference and a
  // cross-correlation are blind to every bit of it, which is why they reported
  // a clean win on something that sounds wrong.
  //
  // This compares the tone of the voice at the ear before and after the
  // treatment. The average difference is subtracted first, so turning the
  // volume up scores zero and only a change in SHAPE counts -- which is what
  // "it sounds hollow" actually means.
  func colourChange(_ a: [Float], _ b: [Float]) -> Double {
    let sa = spectrum(a), sb = spectrum(b)
    guard !sa.isEmpty, sa.count == sb.count else { return 0 }
    let hz = SR / 4096.0
    // 80 Hz to 10 kHz. The first version started at 200 and was therefore blind
    // to the proximity effect, which lives below it -- it scored a 5.5 dB low
    // shelf as 0.4 dB of change and called two clearly different modes
    // indistinguishable. A metric's band has to contain the thing it is judging.
    let lo = Int(80 / hz), hi = min(sa.count - 1, Int(10000 / hz))
    var mean = 0.0
    for i in lo...hi { mean += sb[i] - sa[i] }
    mean /= Double(hi - lo + 1)
    var acc = 0.0
    for i in lo...hi { let d = (sb[i] - sa[i]) - mean; acc += d * d }
    return (acc / Double(hi - lo + 1)).squareRoot()
  }

  /// The biggest change in any third-octave band, in dB. RMS across the whole
  /// spectrum answers "how much was rearranged"; this answers "would anyone
  /// notice", which is a different question -- a strong lift confined to one
  /// region is plainly audible and barely moves an average taken over ten
  /// kilohertz. Roughly 1.5 dB in a band is where a tone change stops being
  /// something you have to go looking for.
  func bandChange(_ a: [Float], _ b: [Float]) -> Double {
    let sa = spectrum(a), sb = spectrum(b)
    guard !sa.isEmpty, sa.count == sb.count else { return 0 }
    let hz = SR / 4096.0
    var worst = 0.0
    var f = 80.0
    while f < 10000 {
      let lo = Int(f / hz), hi = min(sa.count - 1, Int(f * 1.26 / hz))
      if hi > lo {
        var d = 0.0
        for i in lo...hi { d += sb[i] - sa[i] }
        worst = max(worst, abs(d / Double(hi - lo + 1)))
      }
      f *= 1.26
    }
    return worst
  }

  // A deterministic voice-band signal: no microphone, no randomness, same
  // numbers on every machine.
  var seed: UInt64 = 0x5eed
  func rnd() -> Float {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Float(Int32(truncatingIfNeeded: Int(seed >> 33))) / Float(Int32.max)
  }
  var x = (0..<Int(SR * 4)).map { i -> Float in
    // noise, amplitude-modulated at a syllable rate so it has speech-like structure
    rnd() * 0.5 * Float(0.55 + 0.45 * sin(2 * Double.pi * 3.7 * Double(i) / SR))
  }
  x = Spatial.onePole(x, 7000)

  // CALIBRATE THE RULER BEFORE TRUSTING IT. A metric for comb filtering has to
  // rank two known inputs the right way round: a plain signal, and the same
  // signal with a delayed copy added, which is a comb by construction.
  // Three known answers it must get right: the same signal is no change, the
  // same signal twice as loud is no change of TONE, and a deliberate comb is.
  let comb = (0..<x.count).map { i -> Float in i >= 9 ? x[i] - 0.8 * x[i - 9] : x[i] }
  let louder = x.map { $0 * 2 }
  let same = colourChange(x, x), vol = colourChange(x, louder), cmb = colourChange(x, comb)
  let ruled = same < 0.1 && vol < 0.1 && cmb > 1.5
  print(String(format: "  ruler check: identical %.2f dB, twice as loud %.2f dB, deliberate comb %.2f dB -- %@",
               same, vol, cmb, ruled ? "ok" : "RULER IS BLIND"))
  guard ruled else { print("  SPATIAL TEST FAILED -- the tone metric cannot be trusted"); exit(1) }

  let p = Spatial.presets[1]                       // "Beside you": direction only
  let (iL, iR) = Spatial.render(x, azimuth: p.azimuth, farEarDb: p.farEarDb, taps: p.taps)
  let want = itd(iL, iR)
  print(String(format: "  intended at the ears (headphones): level %+.1f dB, timing %.1f samples",
               ild(iL, iR), want))
  print("")

  // Every candidate scored on all three at once: does the cue survive, does the
  // timing survive, and what does it do to the sound of the voice.
  var okAll = true
  var best = ("", -99.0)
  for mode in [Spatial.SpeakerMode.off, .ctc, .wide] {
    Spatial.speakerMode = mode
    let (cL, cR) = Spatial.forSpeakers(iL, iR)
    var worstGain = Double.infinity, added = 0.0, timingOK = true
    for deg in [8.0, 12.0, 15.0, 20.0, 25.0, 30.0] {
      let (aL, aR) = Spatial.earsFromSpeakers(iL, iR, halfAngleDeg: deg)
      let (bL, bR) = Spatial.earsFromSpeakers(cL, cR, halfAngleDeg: deg)
      worstGain = min(worstGain, ild(bL, bR) - ild(aL, aR))
      // What the treatment does to the tone of the voice at that ear, against
      // plain stereo heard from the same seat.
      added = max(added, (colourChange(aL, bL) + colourChange(aR, bR)) / 2)
      if abs(itd(bL, bR) - want) > abs(itd(aL, aR) - want) + 1 { timingOK = false }
    }
    let clean = added < 1.5
    print(String(format: "  %-5@ : worst cue %+.1f dB   timing %@   tone change %.1f dB vs plain stereo   %@",
                 mode.rawValue as NSString, worstGain, timingOK ? "kept" : "WRECKED", added,
                 clean ? "clean" : "COMBED -- this is the hollow sound"))
    if clean && timingOK && worstGain > best.1 { best = (mode.rawValue, worstGain) }
  }
  Spatial.speakerMode = .off
  print("")

  // ── THE SPEAKER SET ───────────────────────────────────────────────────────
  //
  // Two things have to be true of these. MONO-SAFE: identical in both channels,
  // so crosstalk has nothing to erase and the rendering that arrives is the
  // rendering that was made. TELLABLE APART: a set of modes a listener shrugs at
  // is not a choice, it is a menu, and the last round produced exactly that.
  print("  on speakers (mono — distance, not direction):")
  var monoOK = true
  var prev: [Float]? = nil
  let (base, _) = Spatial.render(x, Spatial.monoPresets[0], speakers: true)
  for p in Spatial.monoPresets {
    let (L, R) = Spatial.render(x, p, speakers: true)
    let safe = L == R
    let vsBase = bandChange(base, L)
    let vsPrev = prev.map { bandChange($0, L) } ?? 0
    prev = L
    let distinct = p.name == "As it is today" || (vsBase > 1.5 && vsPrev > 1.5)
    if !safe || !distinct { monoOK = false }
    let pad = p.name.padding(toLength: 22, withPad: " ", startingAt: 0)
    print(String(format: "    %@%@   %.1f dB from today, %.1f dB from the one above  %@",
                 pad, safe ? "mono-safe" : "NOT MONO-SAFE",
                 vsBase, vsPrev,
                 distinct ? "" : "<- too close to tell apart"))
  }
  print(monoOK ? "  speaker set ok -- every mode is mono-safe and audibly its own thing"
               : "  SPEAKER SET FAILED")
  print("")
  if best.0.isEmpty {
    print("  no speaker treatment earns its keep -- plain stereo it is")
  } else {
    print("  best speaker treatment: \(best.0)  (\(String(format: "%+.1f", best.1)) dB of cue, tone left alone)")
  }
  okAll = monoOK
  if CommandLine.arguments.contains("--spatial-test") { exit(okAll ? 0 : 1) }
  if !okAll { exit(1) }
}

if CommandLine.arguments.contains("--selftest") {
  func zcr(_ x: [Float]) -> Double {
    guard x.count > 1 else { return 0 }
    var c = 0
    for i in 1..<x.count where (x[i - 1] < 0) != (x[i] < 0) { c += 1 }
    return Double(c) * SR / Double(x.count)
  }
  var bad = false
  for pure in [true, false] {
    let r = Recorder()
    r.pureMic = pure
    let name = pure ? "pure mic   " : "like a call"
    do { try r.start() } catch {
      print("  \(name): FAILED to start -- \(error.localizedDescription)"); bad = true; continue
    }
    // Something to hear. The echo canceller will fight this in the processed
    // arm, which is correct behaviour and not the thing under test.
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", "Samantha", "Testing one two three, the quick brown fox jumps over the lazy dog."]
    try? say.run()
    Thread.sleep(forTimeInterval: 6)
    say.terminate()
    r.stop()
    let x = r.samples
    let z = zcr(x)
    let ok = x.count > Int(SR * 3) && r.peak > 0.002 && z > 80 && z < 6000
    print(String(format: "  %@: %6d samples (%.1f s)  peak %.4f  zero-crossings %.0f/s  %@",
                 name, x.count, Double(x.count) / SR, r.peak, z,
                 ok ? "looks like audio" : (z >= 6000 ? "NOISE, not a voice" : "nothing captured")))
    if !ok { bad = true }
  }
  print(bad ? "  SELFTEST FAILED" : "  SELFTEST PASSED")
  exit(bad ? 1 : 0)
}

let app = NSApplication.shared
let lab = Lab()
app.delegate = lab
app.setActivationPolicy(.regular)
app.run()
