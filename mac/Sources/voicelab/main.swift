import AppKit
import AVFoundation

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

  static func render(_ x: [Float], azimuth: Double, room: Bool) -> ([Float], [Float]) {
    let th = azimuth * Double.pi / 180
    let itd = (headR / c) * (th + sin(th)) * SR
    var R = shadow(x, cosToEar: cos(th - .pi / 2))
    var L = shadow(delay(x, itd), cosToEar: cos(th + .pi / 2))
    let farGain = Float(pow(10, -3.0 / 20))
    for i in 0..<L.count { L[i] *= farGain }
    if room {
      // A small room seen from a seat beside you. The first reflection lands
      // ~7 ms after the direct sound: late enough to read as a room, early
      // enough not to read as an echo. DIFFERENT per ear on purpose -- it is the
      // difference between the ears that sounds spacious; the same reverb in
      // both is just a mono voice in a bucket.
      let tapsL: [(Double, Float)] = [(0.0068, 0.34), (0.0131, 0.24), (0.0204, 0.17), (0.0296, 0.12)]
      let tapsR: [(Double, Float)] = [(0.0081, 0.30), (0.0157, 0.22), (0.0229, 0.15), (0.0331, 0.11)]
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
    // Must be set BEFORE the format is read: turning voice processing on changes
    // the node's format, and a converter built from the old one produces silence.
    try? input.setVoiceProcessingEnabled(!pureMic)
    let inFmt = input.outputFormat(forBus: 0)
    let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SR,
                               channels: 1, interleaved: false)!
    conv = AVAudioConverter(from: inFmt, to: outFmt)
    input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in
      guard let self, let conv = self.conv else { return }
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
  var takes: [(String, [Float], [Float])] = []
  var recording = false
  var timer: Timer?
  var startedAt = Date()

  func applicationDidFinishLaunching(_ n: Notification) {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 730),
                     styleMask: [.titled, .closable, .miniaturizable],
                     backing: .buffered, defer: false)
    w.title = "Voice Lab"
    w.backgroundColor = Ink.bg
    w.center()
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 730))
    root.wantsLayer = true
    root.layer?.backgroundColor = Ink.bg.cgColor

    // AppKit measures from the bottom; people read from the top. Every position
    // below is "distance down from the top edge", converted once here. The
    // previous version nudged bottom-up constants one at a time and three
    // elements ended up drawn on top of each other.
    let H: CGFloat = 730
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
    _ = label("Record your voice, then hear it three ways.", 15, Ink.fg, top(16, 25), .semibold)
    _ = label("Wear headphones. The whole effect is the difference between your two ears.", 12, Ink.warn, top(46, 22))

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
    recBtn.frame = NSRect(x: 180, y: top(146, 54), width: 200, height: 54)
    recBtn.title = "Record"
    recBtn.onTap = { [weak self] in self?.toggle() }
    root.addSubview(recBtn)

    meter.frame = NSRect(x: 100, y: top(212, 10), width: 360, height: 10)
    root.addSubview(meter)

    status.font = .systemFont(ofSize: 12)
    status.textColor = Ink.dim
    status.alignment = .center
    status.frame = NSRect(x: 20, y: top(232, 18), width: 520, height: 18)
    status.stringValue = "Press Record and talk for about ten seconds."
    root.addSubview(status)

    let titles = [("As it is today", "one voice, both ears — inside your head"),
                  ("Beside you", "head model only, no room"),
                  ("Beside you, in a room", "head model plus early reflections")]
    for (i, t) in titles.enumerated() {
      // TOP TO BOTTOM in the order they should be heard. AppKit lays subviews out
      // from the bottom, so index 0 at y=60 put "as it is today" -- the thing you
      // compare everything against -- underneath its own comparisons.
      let b = Btn(frame: NSRect(x: 40, y: top(266 + CGFloat(i) * 66, 56), width: 480, height: 56))
      b.title = t.0; b.sub = t.1; b.enabled = false
      b.onTap = { [weak self] in self?.playTake(i) }
      root.addSubview(b)
      plays.append(b)
    }
    _ = label("Your takes — click one to load it", 11, Ink.dim, top(490, 16))
    for i in 0..<5 {
      let b = Btn(frame: NSRect(x: 40, y: top(512 + CGFloat(i) * 34, 30), width: 480, height: 30))
      b.enabled = false
      b.onTap = { [weak self] in self?.select(i) }
      root.addSubview(b)
      takeRows.append(b)
    }
    openBtn.frame = NSRect(x: 190, y: top(686, 30), width: 180, height: 30)
    openBtn.title = "Show recordings"
    openBtn.enabled = false
    openBtn.onTap = { [weak self] in
      if let f = self?.lastFolder { NSWorkspace.shared.open(f) }
    }
    root.addSubview(openBtn)

    advice.font = .systemFont(ofSize: 11)
    advice.textColor = Ink.dim
    advice.alignment = .center
    advice.frame = NSRect(x: 20, y: top(462, 16), width: 520, height: 16)
    root.addSubview(advice)

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
    if history.count > 5 { history.removeLast() }
    select(0)
    save(raw: norm)
    advice.stringValue = "Play them in order. Ask where the voice is, not whether it is clean."
  }

  /// Load one of the kept takes into the three play buttons. Re-rendering here
  /// rather than storing three stereo copies per take: the passes are linear and
  /// finish inside the click, and holding every version of every take would be
  /// tens of megabytes to save a few milliseconds nobody can feel.
  func select(_ i: Int) {
    guard i < history.count else { return }
    selected = i
    let raw = history[i].raw
    takes = [("As it is today", raw, raw)]
    let a = Spatial.render(raw, azimuth: 32, room: false)
    let b = Spatial.render(raw, azimuth: 32, room: true)
    takes.append(("Beside you", a.0, a.1))
    takes.append(("Beside you, in a room", b.0, b.1))
    plays.forEach { $0.enabled = true; $0.playing = false }
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
    let stamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: "T", with: " ")
      .prefix(19)
    let mode = rec.pureMic ? "pure-mic" : "like-a-call"
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Desktop/Voice Lab/\(stamp) \(mode)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    Wav.write(raw, nil, to: dir.appendingPathComponent("0 raw mono.wav"))
    let names = ["1 as it is today.wav", "2 beside you.wav", "3 beside you in a room.wav"]
    for (i, t) in takes.enumerated() where i < names.count {
      Wav.write(t.1, t.2, to: dir.appendingPathComponent(names[i]))
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

let app = NSApplication.shared
let lab = Lab()
app.delegate = lab
app.setActivationPolicy(.regular)
app.run()
