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
        else { fputs("video: cannot read \(self.url.path)\n", stderr); return }
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

  func start() throws {
    guard let dev = AVCaptureDevice.default(for: .video) else { throw Err.e("no camera") }
    name = dev.localizedName
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
    session.startRunning()
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
  private var wantKey = false

  init(width: Int, height: Int, bitrate: Int, quality: Double? = nil) throws {
    var s: VTCompressionSession?
    let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
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
    set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate), "AverageBitRate")
    set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: 100_000), "MaxKeyFrameInterval")
    set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 100_000), "MaxKeyFrameIntervalDuration")
    set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 30), "ExpectedFrameRate")
    // ── AverageBitRate alone did not spend the budget ─────────────────────────
    //
    // Measured with --vpsnr: asked for 20 Mbps, the encoder produced 0.639, and
    // stopped at 42.8 dB PSNR -- which is neither the requested rate nor a
    // transparent picture, so the bitrate was not the binding constraint. Quality
    // is a separate knob and was never set.
    if let q = quality {
      set(kVTCompressionPropertyKey_Quality, NSNumber(value: q), "Quality")
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
    fputs("encoder: H.264 \(width)x\(height) bitrate asked \(bitrate) got \(gotBps), B-frames off\n", stderr)
    VTCompressionSessionPrepareToEncodeFrames(sess)
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
