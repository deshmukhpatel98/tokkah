import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

// ── Video: capture -> hardware encode -> wire -> hardware decode ─────────────
//
// Every setting below is chosen for LATENCY, and the ones that matter most are
// the ones a general-purpose encoder gets wrong by default:
//
//   RealTime            = true   -- encode on arrival, do not batch for quality
//   AllowFrameReordering= false  -- NO B-FRAMES. A B-frame is a frame you cannot
//                                   send until you have encoded the one after it,
//                                   which is a whole frame interval of latency
//                                   bought purely for bitrate. On a call it is
//                                   the worst trade available.
//   MaxKeyFrameInterval = huge   -- keyframes on demand, not on a timer: a
//                                   periodic 10x-size frame is a periodic latency
//                                   spike, and the only reason to send one is
//                                   that the peer actually lost the chain.
//
// The capture timestamp rides with every frame all the way to the decoder output,
// on the host clock, so glass-to-glass is a subtraction and never an estimate.

let VMAGIC: UInt32 = 0x544B_0002
let VHDR = 24              // magic(4) frameSeq(4) capHost(8) frag(2) nfrag(2) flags(2) pad(2)
let VPAYLOAD = 1150        // fits a 1200-byte datagram inside any sane MTU without
                           // relying on path MTU discovery, which fails silently.
let VRING = 8              // in-flight frames being reassembled

// ── Sources ────────────────────────────────────────────────────────────────
protocol FrameSource: AnyObject {
  var onFrame: ((CVPixelBuffer, UInt64) -> Void)? { get set }
  func start() throws
  var describe: String { get }
}

/// A real talking head from a file, paced by the host clock. Not a synthetic
/// pattern: a colour ramp compresses to nothing, so a call carrying one measures
/// an empty pipe and reports it as video. Loops seamlessly.
final class FileSource: FrameSource {
  var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
  private let url: URL
  private let fps: Double
  var describe: String { "file \(url.lastPathComponent) @\(Int(fps))fps" }

  /// Frames actually handed on. Distinguishes "the path was wrong" from "the file
  /// went away mid-call", which deserve opposite responses.
  private var framesOut = 0

  init(path: String, fps: Double = 30) { url = URL(fileURLWithPath: path); self.fps = fps }

  func start() throws {
    Thread { [weak self] in
      guard let self else { return }
      let interval = 1.0 / self.fps
      var next = Date().timeIntervalSinceReferenceDate
      while true {
        // ONE asset instance. Building the reader from one AVURLAsset and taking
        // the track from a second one throws: the track belongs to the other
        // asset. A fresh asset per loop iteration is correct and cheap.
        let asset = AVURLAsset(url: self.url)
        guard let reader = try? AVAssetReader(asset: asset),
              let track = asset.tracks(withMediaType: .video).first
        else {
          // AN ARM NAMED "VIDEO" MUST NOT RUN WITHOUT VIDEO.
          //
          // This warned and returned, and three consecutive measurement runs went
          // by with `enc 0/s` while being labelled the video arm -- the media path
          // contains a space, the harness expanded it unquoted, and `--video
          // /Users/.../Downloads/video calling/x.mp4` arrived as a path ending at
          // "video". Same failure as a misspelled flag, one level down, and the
          // flag guard cannot see it because the value looks like a path.
          //
          // Fatal only if NOTHING was ever produced, which is the "you typed it
          // wrong" case. A file that stops being readable after ten thousand good
          // frames is a disk or a removable volume, and killing a live call over
          // that would be worse than dropping to audio.
          if self.framesOut == 0 {
            fputs("video: cannot read \(self.url.path)\n"
                + "  the video source was requested and does not exist, so this run would\n"
                + "  measure a call with no video while claiming to have one. Refusing.\n"
                + "  (a path with spaces needs quoting)\n", stderr)
            exit(2)
          }
          fputs("video: source became unreadable after \(self.framesOut) frames "
              + "-- continuing without video\n", stderr)
          return
        }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        reader.startReading()
        while reader.status == .reading, let sb = out.copyNextSampleBuffer() {
          guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
          // Paced against the wall clock, so the sender's cadence is a real
          // 30 fps rather than "as fast as the disk goes".
          next += interval
          let wait = next - Date().timeIntervalSinceReferenceDate
          if wait > 0 { usleep(UInt32(wait * 1_000_000)) } else { next = Date().timeIntervalSinceReferenceDate }
          self.framesOut += 1
          self.onFrame?(pb, Clock.now())
        }
      }
    }.start()
  }
}

/// The real sensor. Used when camera permission exists; a claim about the camera
/// is only ever proved here, never on a file.
final class CameraSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {
  var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
  private let session = AVCaptureSession()
  private let out = AVCaptureVideoDataOutput()
  private let q = DispatchQueue(label: "tk.cam")
  private var name = "?"
  var describe: String { "camera \(name)" }

  // ── EVERY CAMERA, NOT JUST THE DEFAULT ────────────────────────────────────
  //
  // `AVCaptureDevice.default(for: .video)` picks one and offers no way to change
  // it, which on a Mac is wrong more often than it is right: an external webcam, a
  // Continuity Camera iPhone and the built-in one are all plausible, and the
  // default is whichever macOS decided. The web app has had a camera picker from
  // early on for exactly this reason.
  //
  // External devices first in the list, because a person who plugged one in did so
  // on purpose.
  // ── ASK FOR THE CAMERA, DO NOT HOPE FOR IT ────────────────────────────────
  //
  // Starting an AVCaptureSession prompts implicitly, and if the person does not
  // answer -- clicks away, misses it behind another window -- the session simply
  // never delivers a frame. The app then shows a black rectangle forever with no
  // explanation, which is exactly what happened: `notDetermined` on a machine
  // where the app had been launched repeatedly and the window was always empty.
  //
  // So it is asked FOR, explicitly, and every one of the four answers has a
  // consequence the person can see. `.denied` is the important one: only System
  // Settings can undo it, so the app has to say so instead of looking broken.
  enum Access { case granted, denied, restricted }
  static func requestAccess(_ done: @escaping (Access) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: done(.granted)
    case .denied: done(.denied)
    case .restricted: done(.restricted)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { ok in done(ok ? .granted : .denied) }
    @unknown default: done(.denied)
    }
  }

  static func available() -> [AVCaptureDevice] {
    let types: [AVCaptureDevice.DeviceType] = [.external, .continuityCamera, .builtInWideAngleCamera]
    let s = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
    return s.devices
  }
  /// Remembered across launches: choosing a camera every call is not a feature.
  private static let pickKey = "tk.cameraId"
  static var preferred: AVCaptureDevice? {
    guard let id = UserDefaults.standard.string(forKey: pickKey) else { return nil }
    return available().first { $0.uniqueID == id }
  }
  static func remember(_ d: AVCaptureDevice) {
    UserDefaults.standard.set(d.uniqueID, forKey: pickKey)
  }
  private(set) var current: AVCaptureDevice?

  /// Swap the camera on a live session. Configuration is atomic between begin and
  /// commit, so frames stop for the swap and resume -- no teardown of the session,
  /// which would drop the output delegate and the encoder's frame supply with it.
  func switchTo(_ dev: AVCaptureDevice) {
    session.beginConfiguration()
    for i in session.inputs { session.removeInput(i) }
    if let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
      session.addInput(input)
      current = dev
      name = dev.localizedName
      CameraSource.remember(dev)
      fputs("camera: switched to \(dev.localizedName)\n", stderr)
    } else {
      fputs("camera: could not switch to \(dev.localizedName) -- keeping the old one\n", stderr)
    }
    session.commitConfiguration()
    configure(current)
  }

  func start() throws {
    let devs = CameraSource.available()
    // The remembered one if it is still plugged in, else whatever macOS prefers,
    // else the first thing we can find.
    guard let dev = CameraSource.preferred ?? AVCaptureDevice.default(for: .video) ?? devs.first
    else { throw Err.e("no camera") }
    current = dev
    name = dev.localizedName
    if devs.count > 1 {
      fputs("cameras: \(devs.map { $0.localizedName }.joined(separator: ", "))"
          + " -- using \(dev.localizedName)\n", stderr)
    }
    let input = try AVCaptureDeviceInput(device: dev)
    session.beginConfiguration()
    guard session.canAddInput(input) else { throw Err.e("cannot add camera input") }
    session.addInput(input)
    out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    // Drop, never queue. A late frame is worthless on a call and a queue of them
    // is just latency with extra steps.
    out.alwaysDiscardsLateVideoFrames = true
    out.setSampleBufferDelegate(self, queue: q)
    guard session.canAddOutput(out) else { throw Err.e("cannot add video output") }
    session.addOutput(out)
    session.commitConfiguration()
    configure(dev)
    session.startRunning()
  }

  /// 720p at the highest frame rate the device offers. Factored out so a switched
  /// camera gets the same treatment as the first one -- otherwise the second camera
  /// runs at whatever default it likes and the frame rate silently halves.
  private func configure(_ dev: AVCaptureDevice?) {
    guard let dev else { return }
    // Highest frame rate the format allows: fewer, older frames is the one thing
    // that cannot be fixed downstream.
    if let f = dev.formats.last(where: {
      let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
      return d.width == 1280 && d.height == 720
    }) {
      try? dev.lockForConfiguration()
      dev.activeFormat = f
      let best = f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30
      dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(best))
      dev.unlockForConfiguration()
    }
  }

  func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
    // The sensor's own timestamp, converted to the host clock -- the same clock
    // the audio path stamps with. This is the whole reason for being native.
    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
    let host = CMClockConvertHostTimeToSystemUnits(pts)
    onFrame?(pb, host == 0 ? Clock.now() : host)
  }
}

// ── Encoder ────────────────────────────────────────────────────────────────
final class VEncoder {
  private var session: VTCompressionSession?
  var onEncoded: ((Data, UInt64, Bool) -> Void)?
  var encodes = 0
  /// MILLISECONDS. Named `Us` until 2026-08-23, while storing `Clock.ms(...)`
  /// -- and the moment it was read by something that trusted the name, it
  /// produced a telemetry field claiming 720p encoded in 2.56 MICROSECONDS.
  /// A unit in a name is a claim; this project has now been wrong about one
  /// four times.
  var encLatMs = Quantiles()

  /// Change the quality target on a live session. The controller in VQuality
  /// drives this, so the picture can retreat without tearing down the encoder --
  /// a rebuild would cost a keyframe, and the moment a link is struggling is the
  /// worst possible moment to send one.
  @discardableResult func setQuality(_ q: Double) -> Bool {
    guard let sess = session else { return false }
    let st = VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_Quality,
                                  value: NSNumber(value: q))
    // READ IT BACK. `noErr` from VTSessionSetProperty means "accepted", and this
    // codebase has already been burned twice today by properties that were
    // accepted and did something other than advertised. If the session does not
    // report the value we just set, the controller is steering nothing.
    var back: CFNumber?
    VTSessionCopyProperty(sess, key: kVTCompressionPropertyKey_Quality,
                          allocator: nil, valueOut: &back)
    let now = (back as NSNumber?)?.doubleValue
    qualityNow = now
    qualityAsked = q
    return st == noErr && now != nil && abs(now! - q) < 0.01
  }
  // ── The knob that actually moves on a live session ──────────────────────────
  //
  // `setQuality` above is a NO-OP after the session is running. Proved, not
  // suspected: with 3% loss on its send, one end retreated 0.7 -> 0.6 -> 0.5 ->
  // 0.3, the readback agreed at every step, and its P-frames came out at 7,650 B
  // against the peer's 7,301 B at quality 0.7 -- LARGER at the floor than at the
  // ceiling. Set at session INIT the same two values give 226 B and 6,673 B, a
  // 23x spread. So Quality is an init-time property that accepts and reports
  // live changes it does not make, and the entire retreat controller has never
  // altered a single byte on the wire.
  //
  // That is the third time this file has been lied to by a readback in one day
  // (DataRateLimits, encLatUs, and now Quality), so this one is NOT verified by
  // reading the property back. `--vq-step` exists to verify it the only way that
  // counts: change it mid-call and look at the bytes that come out.
  @discardableResult func setBitrate(_ bps: Int) -> Bool {
    guard let sess = session else { return false }
    let st = VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate,
                                  value: NSNumber(value: bps))
    bitrateAsked = bps
    var back: CFTypeRef?
    VTSessionCopyProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate,
                          allocator: nil, valueOut: &back)
    bitrateNow = (back as? NSNumber)?.intValue
    // Reported, but deliberately NOT the return value's only basis -- see above.
    return st == noErr
  }
  var bitrateNow: Int?
  var bitrateAsked: Int?

  /// What the session is actually set to, for the report line. Not what was asked
  /// for -- those have differed before.
  var qualityNow: Double?
  /// What the controller last asked for, so asked and in-effect can be compared.
  var qualityAsked: Double?
  private var wantKey = false

  // ── Rebuilding is the only way to change how this encoder encodes ───────────
  //
  // Quality and AverageBitRate both accept a live change, both read the new value
  // back, and neither alters a byte. Measured on a clean link with `--vq-step`:
  // the ceiling was dropped from 3 Mbps to 400 kbps at t=40 s, accepted, read back
  // as 400000, and the output went from 1.7 Mbps to 2.0 -- while the untouched
  // control end moved identically, so the change was the content and not the knob.
  //
  // So the config is kept and the session is REBUILT. Video.swift used to argue
  // against that ("a rebuild would cost a keyframe, and the moment a link is
  // struggling is the worst time for one"), and that argument was right about the
  // cost and wrong about the alternative: the alternative was a controller that
  // did nothing at all. One keyframe to actually shed 20x the bandwidth is a good
  // trade, and a struggling link is currently being sent 180 keyframes in 90
  // seconds anyway.
  private let cfgW: Int, cfgH: Int, cfgBitrate: Int
  private var cfgQuality: Double?
  /// Set by the controller on any thread; consumed on the capture thread inside
  /// `encode`. A pending flag rather than a lock, matching `wantKey`: rebuilding
  /// under the encoder's own thread means no other thread can be inside it.
  nonisolated(unsafe) var pendingQuality: Double?
  private(set) var rebuilds = 0

  init(width: Int, height: Int, bitrate: Int, quality: Double? = nil) throws {
    cfgW = width; cfgH = height; cfgBitrate = bitrate; cfgQuality = quality
    try buildSession()
  }

  /// Everything that configures the encoder, in one place so a rebuild is
  /// provably the same encoder and not a second slightly different one.
  private func buildSession() throws {
    var s: VTCompressionSession?
    let st = VTCompressionSessionCreate(allocator: nil, width: Int32(cfgW), height: Int32(cfgH),
      codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
      compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
    guard st == noErr, let sess = s else { throw Err.e("VTCompressionSessionCreate \(st)") }
    session = sess
    // A REFUSED PROPERTY MUST NOT BE SILENT. Ignoring these return codes is how
    // an encoder ends up running at a default nobody chose while the code reads
    // as if it were configured -- the same failure shape as the audio device
    // silently staying at 44.1 kHz.
    var refused: [String] = []
    func set(_ k: CFString, _ v: CFTypeRef, _ name: String) {
      let st = VTSessionSetProperty(sess, key: k, value: v)
      if st != noErr { refused.append("\(name)=\(st)") }
    }
    set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, "RealTime")
    set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, "AllowFrameReordering")   // no B-frames
    set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel, "ProfileLevel")
    set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: cfgBitrate), "AverageBitRate")
    set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: 100_000), "MaxKeyFrameInterval")
    set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 100_000), "MaxKeyFrameIntervalDuration")
    set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 30), "ExpectedFrameRate")
    // ── AverageBitRate alone did not spend the budget ─────────────────────────
    //
    // Measured with --vpsnr: asked for 20 Mbps, the encoder produced 0.639, and
    // stopped at 42.8 dB PSNR -- which is neither the requested rate nor a
    // transparent picture, so the bitrate was not the binding constraint. Quality
    // is a separate knob and was never set.
    if let q = cfgQuality {
      set(kVTCompressionPropertyKey_Quality, NSNumber(value: q), "Quality")
      qualityNow = q
      // NO DataRateLimits HERE, and that is a measured decision, not an omission.
      //
      // Quality overrides AverageBitRate -- q=1.0 against a 3 Mbps target produced
      // 25 Mbps -- so a hard cap seemed obviously right. It was tried, as
      // [bytes, 1 second] at 1.5x the target, and READ BACK as in effect
      // (562500, 1). What it actually did:
      //
      //   without cap   q 0.5 -> 40.0 dB   0.6 -> 42.9   0.7 -> 45.5   0.8 -> 47.8
      //   with cap      q 0.5 -> 37.5 dB   0.6 -> 37.5   0.7 -> 37.6   0.8 -> 37.6
      //
      // It collapsed every quality setting onto one bad operating point (0.105
      // Mbps, worse than no quality setting at all) AND did not bind where it was
      // needed: q=1.0 still produced 44 Mbps through a 4.5 Mbps cap. So it made the
      // picture worse everywhere and enforced nothing anywhere.
      //
      // The real cap has to be the app's own: pick the quality, then watch what
      // comes out. That controller does not exist yet, which is why the default
      // stays unset -- see DESIGN 17.104.
    }
    if !refused.isEmpty { fputs("encoder: REFUSED \(refused.joined(separator: " "))\n", stderr) }
    // Read the bitrate BACK. Setting is not applying.
    var got: CFTypeRef?
    VTSessionCopyProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, allocator: nil, valueOut: &got)
    // READ BACK the cap too. A property that returns noErr and does nothing is
    // this project's most repeated trap, and VideoToolbox has plenty of them:
    // "accepted" is not "in effect".
    var drl: CFArray?
    VTSessionCopyProperty(sess, key: kVTCompressionPropertyKey_DataRateLimits,
                          allocator: nil, valueOut: &drl)
    var q: CFNumber?
    VTSessionCopyProperty(sess, key: kVTCompressionPropertyKey_Quality,
                          allocator: nil, valueOut: &q)
    fputs("encoder: DataRateLimits readback \(drl.map { String(describing: $0 as NSArray) } ?? "nil")"
        + "  Quality readback \(q.map { "\($0 as NSNumber)" } ?? "nil")\n", stderr)
    let gotBps = (got as? NSNumber)?.intValue ?? -1
    fputs("encoder: H.264 \(cfgW)x\(cfgH) bitrate asked \(cfgBitrate) got \(gotBps), B-frames off\n", stderr)
    VTCompressionSessionPrepareToEncodeFrames(sess)
  }

  /// Tear the session down and build an identical one at a new quality. Called on
  /// the capture thread only. Silent about its own success on purpose -- the caller
  /// reports the bytes per frame afterwards, which is the only evidence that has
  /// not lied today.
  private func rebuild(quality q: Double) {
    guard let old = session else { return }
    // Flush first: frames already handed over still deliver through the callback,
    // and invalidating underneath them loses the tail of the picture.
    VTCompressionSessionCompleteFrames(old, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(old)
    session = nil
    cfgQuality = q
    do {
      try buildSession()
      rebuilds += 1
      // A fresh session has no reference frames and the decoder on the far side
      // has the old parameter sets, so the next frame MUST be an IDR carrying new
      // ones. A fresh session emits one anyway; asking makes it not depend on that.
      wantKey = true
    } catch {
      fputs("video: encoder rebuild FAILED (\(error)) -- the picture stops here\n", stderr)
    }
  }

  func requestKeyframe() { wantKey = true }

  /// Mean luma of the frame being handed to the encoder, 0-255. Exists because
  /// 291 bytes per 720p frame is exactly what a BLACK picture costs, and no
  /// bitrate number can tell that apart from a very efficient encoder. An
  /// instrument that cannot see an empty input will happily certify one.
  var lastLuma = -1
  /// Mean absolute frame-to-frame difference of the sampled pixels, 0-255.
  /// "There is a picture" and "the picture is moving" are different claims, and
  /// only the second one explains a bitrate. A still image legitimately costs
  /// almost nothing, so without this a frozen source and an efficient encoder
  /// produce identical numbers.
  var lastDiff = -1
  /// Encoder output split by frame type, so "the picture got expensive" can name
  /// which kind of frame got expensive.
  nonisolated(unsafe) var keyFrames = 0, pFrames = 0, keyBytes = 0, pBytes = 0
  private var prevSample: [UInt8] = []
  private var lumaTick = 0

  private func probeLuma(_ pb: CVPixelBuffer) {
    lumaTick += 1
    guard lumaTick % 15 == 0 else { return }              // twice a second
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { lastLuma = -2; return }
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    let h = CVPixelBufferGetHeightOfPlane(pb, 0)
    let w = CVPixelBufferGetWidthOfPlane(pb, 0)
    let p = base.assumingMemoryBound(to: UInt8.self)
    var sum = 0, n = 0
    var samp: [UInt8] = []
    samp.reserveCapacity(4096)
    var y = 0
    while y < h {
      var x = 0
      while x < w { let v = p[y * stride + x]; sum += Int(v); samp.append(v); n += 1; x += 16 }
      y += 8
    }
    lastLuma = n > 0 ? sum / n : -3
    if prevSample.count == samp.count && !samp.isEmpty {
      var d = 0
      for i in 0..<samp.count { d += abs(Int(samp[i]) - Int(prevSample[i])) }
      lastDiff = d / samp.count
    }
    prevSample = samp
  }

  func encode(_ pb: CVPixelBuffer, hostTime: UInt64) {
    // Consumed here, on the encoder's own thread, so a rebuild can never happen
    // while a frame is inside VTCompressionSessionEncodeFrame.
    if let q = pendingQuality {
      pendingQuality = nil
      if q != cfgQuality { rebuild(quality: q) }
    }
    guard let sess = session else { return }
    probeLuma(pb)
    let t0 = Clock.now()
    var props: CFDictionary?
    if wantKey {
      wantKey = false
      props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
    }
    // The host time rides as the presentation timestamp so the encode callback
    // gets it back without a side table that could ever disagree.
    let pts = CMTime(value: CMTimeValue(hostTime), timescale: 1_000_000_000)
    VTCompressionSessionEncodeFrame(sess, imageBuffer: pb, presentationTimeStamp: pts,
      duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sb in
      guard let self, status == noErr, let sb, CMSampleBufferDataIsReady(sb) else { return }
      self.encLatMs.add(Clock.ms(Clock.now() - t0))
      self.encodes += 1
      guard let payload = Self.serialize(sb) else { return }
      let key = Self.isKeyframe(sb)
      // SPLIT THE BYTES BY FRAME TYPE.
      //
      // "10,000 B/frame at quality 0.3, where a clean link at the same setting
      // sends 226" has two completely different explanations -- giant keyframes
      // being requested by a lossy peer, or a Quality property that reads back
      // correctly on a live session and does nothing. An average over both frame
      // types cannot tell them apart, and guessing which one it is has already
      // sent this investigation to the wrong file once today.
      if key { self.keyFrames += 1; self.keyBytes += payload.count }
      else { self.pFrames += 1; self.pBytes += payload.count }
      self.onEncoded?(payload, hostTime, key)
    }
  }

  private static func isKeyframe(_ sb: CMSampleBuffer) -> Bool {
    guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false),
          CFArrayGetCount(arr) > 0 else { return true }
    let d = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFDictionary.self)
    let notSync = CFDictionaryGetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
    return notSync == nil
  }

  /// Wire form: parameter sets first (only present on keyframes), then the AVCC
  /// sample. The parameter sets ride IN BAND with every keyframe on purpose --
  /// a receiver that joins late, or loses the one packet that carried them, must
  /// be able to start from the next keyframe alone and never from a handshake
  /// that may never be repeated.
  private static func serialize(_ sb: CMSampleBuffer) -> Data? {
    var out = Data()
    if isKeyframe(sb), let fd = CMSampleBufferGetFormatDescription(sb) {
      var count = 0
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
        parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
      out.append(UInt8(min(count, 255)))
      for i in 0..<count {
        var ptr: UnsafePointer<UInt8>?
        var len = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i,
          parameterSetPointerOut: &ptr, parameterSetSizeOut: &len, parameterSetCountOut: nil,
          nalUnitHeaderLengthOut: nil) == noErr, let p = ptr else { return nil }
        var l16 = UInt16(len).littleEndian
        withUnsafeBytes(of: &l16) { out.append(contentsOf: $0) }
        out.append(UnsafeBufferPointer(start: p, count: len))
      }
    } else {
      out.append(UInt8(0))
    }
    guard let bb = CMSampleBufferGetDataBuffer(sb) else { return nil }
    var total = 0
    var dp: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
      totalLengthOut: &total, dataPointerOut: &dp) == noErr, let d = dp else { return nil }
    var l32 = UInt32(total).littleEndian
    withUnsafeBytes(of: &l32) { out.append(contentsOf: $0) }
    out.append(UnsafeBufferPointer(start: UnsafeRawPointer(d).assumingMemoryBound(to: UInt8.self), count: total))
    return out
  }
}
