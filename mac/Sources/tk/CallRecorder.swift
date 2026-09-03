import AVFoundation
import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import VideoToolbox

/// ── CALL RECORDING: THE REAL PLAYOUT PATH ──────────────────────────────────
///
/// Records the call exactly as perceived and rendered in real time:
/// - Audio: decoded audio samples with concealment/breaks as they are fed to
///   the CoreAudio playback buffer. If the stream starves, conceals, or drops,
///   the recorded audio captures that exact broken sound.
/// - Video: decoded video frames as rendered to the display. If frames drop,
///   freeze, or repeat, the exact sequence and timing of that stall is captured.
///
/// Built for solo evaluation of live network call quality without a second person.
final class CallRecorder: @unchecked Sendable {
  static let shared = CallRecorder()

  private(set) var isRecording = false
  private(set) var recordingURL: URL?
  var onRecordingStateChanged: ((Bool) -> Void)?

  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var audioInput: AVAssetWriterInput?
  private var audioFormatDesc: CMAudioFormatDescription?

  private let queue = DispatchQueue(label: "tk.callrecorder", qos: .userInitiated)

  // ── Lock-free circular audio buffer ─────────────────────────────────────────
  //
  // Written monotonically on the real-time CoreAudio render thread with zero
  // locks, zero allocations, and zero syscalls. Drained periodically by the
  // recording worker queue.
  private let audioBufCapacity = 48000 * 30 // 30 seconds of 48 kHz mono float
  private var audioBuf: UnsafeMutablePointer<Float>
  private var audioWriteIndex: UInt64 = 0
  private var audioReadIndex: UInt64 = 0
  private var audioSamplesAppended: Int64 = 0

  // ── Video cadence and freeze tracking (Strict 30.000 fps grid) ───────────────
  private var startHostTime: UInt64 = 0
  private var nextVideoFrameIndex: Int64 = 0
  private var lastVideoHostTime: UInt64 = 0
  private var lastPixelBuffer: CVPixelBuffer?
  private var blankPixelBuffer: CVPixelBuffer?
  private var videoWidth: Int = 1280
  private var videoHeight: Int = 720
  private var transferSession: VTPixelTransferSession?
  private var pixelBufferPool: CVPixelBufferPool?
  private let ciContext = CIContext()

  // ── Metrics ─────────────────────────────────────────────────────────────────
  private(set) var videoFramesReceived: Int = 0
  private(set) var videoFramesAppended: Int = 0
  private(set) var videoFramesRepeated: Int = 0
  private(set) var audioSamplesRecorded: Int64 = 0

  private var ticker: DispatchSourceTimer?
  private var isPaused: Bool = false
  private var isCamOff: Bool = false

  private init() {
    audioBuf = UnsafeMutablePointer<Float>.allocate(capacity: audioBufCapacity)
    audioBuf.initialize(repeating: 0, count: audioBufCapacity)
    VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transferSession)
  }

  deinit {
    audioBuf.deallocate()
  }

  static func recordingsDirectory() -> URL {
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Movies/Kin", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static func defaultRecordingURL() -> URL {
    let dir = recordingsDirectory()
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd-HHmmss"
    return dir.appendingPathComponent("Kin-\(df.string(from: Date())).mov")
  }

  /// Start recording the call to the specified file.
  @discardableResult
  func start(to url: URL, width: Int? = nil, height: Int? = nil) -> Bool {
    var result = false
    let sem = DispatchSemaphore(value: 0)
    queue.async { [self] in
      if isRecording {
        fputs("callrec: already recording\n", stderr)
        sem.signal()
        return
      }

      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

      let fileType: AVFileType = (url.pathExtension.lowercased() == "mp4") ? .mp4 : .mov
      guard let w = try? AVAssetWriter(outputURL: url, fileType: fileType) else {
        fputs("callrec: cannot create asset writer for \(url.path)\n", stderr)
        sem.signal()
        return
      }
      w.movieFragmentInterval = CMTime(seconds: 1.0, preferredTimescale: 1000)

      let rawW = width ?? (gRxWidth > 0 ? gRxWidth : 1280)
      let rawH = height ?? (gRxHeight > 0 ? gRxHeight : 720)
      let targetW = max(320, (rawW / 2) * 2)
      let targetH = max(180, (rawH / 2) * 2)
      videoWidth = targetW
      videoHeight = targetH

      // Setup pixel buffer pool for scaled / converted frames
      let poolAttrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: targetW,
        kCVPixelBufferHeightKey as String: targetH,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
      ]
      pixelBufferPool = nil
      CVPixelBufferPoolCreate(nil, nil, poolAttrs as CFDictionary, &pixelBufferPool)

      // Video input (hardware accelerated H.264)
      let vSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: targetW,
        AVVideoHeightKey: targetH
      ]
      let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
      vIn.expectsMediaDataInRealTime = true
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: nil)
      if w.canAdd(vIn) {
        w.add(vIn)
      } else {
        fputs("callrec: cannot add video input\n", stderr)
        sem.signal()
        return
      }

      // Audio input (AAC 48kHz mono)
      let aSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 128000
      ]
      let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
      aIn.expectsMediaDataInRealTime = true
      if w.canAdd(aIn) {
        w.add(aIn)
      } else {
        fputs("callrec: cannot add audio input\n", stderr)
        sem.signal()
        return
      }

      // Audio format description for LPCM float32 inputs
      var asbd = AudioStreamBasicDescription(
        mSampleRate: 48000.0,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0
      )
      audioFormatDesc = nil
      CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                     magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                     formatDescriptionOut: &audioFormatDesc)

      guard w.startWriting() else {
        fputs("callrec: startWriting failed: \(String(describing: w.error))\n", stderr)
        sem.signal()
        return
      }
      w.startSession(atSourceTime: .zero)

      writer = w
      videoInput = vIn
      pixelBufferAdaptor = adaptor
      audioInput = aIn
      recordingURL = url

      startHostTime = Clock.now()
      nextVideoFrameIndex = 0
      lastVideoHostTime = startHostTime
      videoFramesReceived = 0
      videoFramesAppended = 0
      videoFramesRepeated = 0
      audioSamplesAppended = 0
      audioWriteIndex = 0
      audioReadIndex = 0

      // Create initial ground frame
      blankPixelBuffer = makeSolidPixelBuffer(width: targetW, height: targetH, r: 10, g: 14, b: 22)
      lastPixelBuffer = blankPixelBuffer
      if let blank = blankPixelBuffer {
        let pts = CMTime(value: 0, timescale: 30000)
        appendVideo(blank, at: pts)
        nextVideoFrameIndex = 1
        videoFramesAppended = 1
      }

      // Ticker to flush audio and repeat video frames on drops/stalls
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + .milliseconds(33), repeating: .milliseconds(33))
      timer.setEventHandler { [weak self] in
        self?.onCadenceTick()
      }
      timer.resume()
      self.ticker = timer

      isRecording = true
      result = true
      fputs("callrec: recording started -> \(url.path)\n", stderr)
      let cb = onRecordingStateChanged
      DispatchQueue.main.async { cb?(true) }
      sem.signal()
    }
    sem.wait()
    return result
  }

  /// Real-time audio render hook. Called from CoreAudio render proc.
  /// Lock-free, allocation-free, single atomic increment.
  @inline(__always)
  func recordAudioSample(_ s: Float) {
    guard isRecording else { return }
    let w = audioWriteIndex
    audioBuf[Int(w % UInt64(audioBufCapacity))] = s
    audioWriteIndex &+= 1
  }

  /// Real-time video frame hook. Called when a decoded remote frame is delivered.
  func recordVideo(_ pb: CVImageBuffer, at hostTime: UInt64) {
    guard isRecording else { return }
    queue.async { [weak self] in
      guard let self = self, self.isRecording else { return }
      self.handleIncomingVideoFrame(pb, at: hostTime)
    }
  }

  /// Notification that peer video is paused (blurred) or camera is turned off.
  func setPaused(_ paused: Bool, peerCamOff: Bool = false) {
    guard isRecording else { return }
    queue.async { [weak self] in
      guard let self = self else { return }
      self.isPaused = paused
      self.isCamOff = peerCamOff
      if paused, let last = self.lastPixelBuffer {
        self.lastPixelBuffer = self.blurPixelBuffer(last) ?? last
      } else if peerCamOff {
        self.lastPixelBuffer = self.makeCameraOffBuffer() ?? self.blankPixelBuffer
      }
    }
  }

  /// Stops recording and finalizes the output movie file.
  @discardableResult
  func stop() -> String {
    guard isRecording else { return "callrec: not recording" }
    isRecording = false

    var summary = ""
    let sem = DispatchSemaphore(value: 0)
    queue.async { [weak self] in
      guard let self = self else { sem.signal(); return }
      self.ticker?.cancel()
      self.ticker = nil

      // Drain remaining audio from ring buffer
      self.drainAudio()

      // Align audio and video durations to max of both
      let totalVideoSec = Double(self.nextVideoFrameIndex) / 30.0
      let totalAudioSec = Double(self.audioSamplesAppended) / 48000.0
      let finalSec = max(totalVideoSec, totalAudioSec)

      // Pad audio if shorter than finalSec
      let targetAudioSamples = Int64(round(finalSec * 48000.0))
      if self.audioSamplesAppended < targetAudioSamples {
        let padCount = Int(targetAudioSamples - self.audioSamplesAppended)
        self.padAudioSilence(count: padCount)
      }

      // Pad video if shorter than finalSec
      let targetVideoFrames = Int64(round(finalSec * 30.0))
      if self.nextVideoFrameIndex < targetVideoFrames, let pb = self.lastPixelBuffer ?? self.blankPixelBuffer {
        while self.nextVideoFrameIndex < targetVideoFrames {
          let pts = CMTime(value: self.nextVideoFrameIndex * 1000, timescale: 30000)
          self.appendVideo(pb, at: pts)
          self.nextVideoFrameIndex += 1
          self.videoFramesAppended += 1
          self.videoFramesRepeated += 1
        }
      }

      self.videoInput?.markAsFinished()
      self.audioInput?.markAsFinished()

      let finSem = DispatchSemaphore(value: 0)
      if let w = self.writer, w.status == .writing {
        w.finishWriting {
          finSem.signal()
        }
        finSem.wait()
      } else {
        finSem.signal()
      }

      if let w = self.writer, w.status == .failed {
        fputs("callrec: finishWriting failed: \(String(describing: w.error))\n", stderr)
      }

      let size = (try? FileManager.default.attributesOfItem(atPath: self.recordingURL?.path ?? "")[.size] as? Int) ?? 0
      let durationSec = Double(self.audioSamplesAppended) / 48000.0
      summary = "callrec: saved \(self.videoFramesAppended) frames (\(self.videoFramesRepeated) repeated/stalled), \(self.audioSamplesAppended) audio samples (\(String(format: "%.2f", durationSec)) s, \(size / 1024) KiB) to \(self.recordingURL?.path ?? "nil")"

      self.writer = nil
      self.videoInput = nil
      self.pixelBufferAdaptor = nil
      self.audioInput = nil
      self.lastPixelBuffer = nil
      self.blankPixelBuffer = nil
      fputs("\(summary)\n", stderr)
      let cb = self.onRecordingStateChanged
      DispatchQueue.main.async { cb?(false) }
      sem.signal()
    }
    sem.wait()
    return summary
  }

  func stopSync() {
    if isRecording { _ = stop() }
  }

  // ── PRIVATE PIPELINE METHODS ───────────────────────────────────────────────

  private func handleIncomingVideoFrame(_ pb: CVImageBuffer, at hostTime: UInt64) {
    videoFramesReceived += 1
    let elapsedMs = Clock.ms(hostTime - startHostTime)
    let targetIndex = max(nextVideoFrameIndex, Int64(round(Double(elapsedMs) / 1000.0 * 30.0)))

    // If there was a stall (one or more frame intervals missed), repeat last frame
    if targetIndex > nextVideoFrameIndex, let prev = lastPixelBuffer ?? blankPixelBuffer {
      while nextVideoFrameIndex < targetIndex {
        let pts = CMTime(value: nextVideoFrameIndex * 1000, timescale: 30000)
        appendVideo(prev, at: pts)
        videoFramesRepeated += 1
        videoFramesAppended += 1
        nextVideoFrameIndex += 1
      }
    }

    let frameToAppend = scaleIfNeeded(pb)
    let pts = CMTime(value: nextVideoFrameIndex * 1000, timescale: 30000)
    appendVideo(frameToAppend, at: pts)
    lastPixelBuffer = frameToAppend
    lastVideoHostTime = hostTime
    videoFramesAppended += 1
    nextVideoFrameIndex += 1
  }

  private func onCadenceTick() {
    drainAudio()

    // Video stall detection: if time has advanced past nextVideoFrameIndex, repeat last frame
    let now = Clock.now()
    let elapsedMs = Clock.ms(now - startHostTime)
    let targetIndex = Int64(floor(Double(elapsedMs) / 1000.0 * 30.0))

    if targetIndex >= nextVideoFrameIndex, let pb = lastPixelBuffer ?? blankPixelBuffer {
      while nextVideoFrameIndex <= targetIndex {
        let pts = CMTime(value: nextVideoFrameIndex * 1000, timescale: 30000)
        appendVideo(pb, at: pts)
        if videoFramesReceived > 0 {
          videoFramesRepeated += 1
        }
        videoFramesAppended += 1
        nextVideoFrameIndex += 1
      }
      lastVideoHostTime = now
    }
  }

  private func padAudioSilence(count: Int) {
    var remaining = count
    while remaining > 0 {
      let chunkSize = min(4800, remaining)
      let chunk = [Float](repeating: 0, count: chunkSize)
      let pts = CMTime(value: audioSamplesAppended, timescale: 48000)
      appendAudio(samples: chunk, pts: pts)
      audioSamplesAppended += Int64(chunkSize)
      remaining -= chunkSize
    }
    audioSamplesRecorded = audioSamplesAppended
  }

  private func drainAudio() {
    let now = Clock.now()
    let elapsedMs = Clock.ms(now - startHostTime)
    let targetSamples = Int64(Double(elapsedMs) / 1000.0 * 48000.0)

    let w = audioWriteIndex
    var r = audioReadIndex

    // If audio engine has not started or fallen severely behind (> 50ms = 2400 samples)
    let available = Int64(w - r)
    if audioSamplesAppended + available < targetSamples - 2400 {
      let deficit = Int(targetSamples - 2400 - (audioSamplesAppended + available))
      padAudioSilence(count: deficit)
    }

    guard w > r else { return }

    if w - r > UInt64(audioBufCapacity) {
      r = w - UInt64(audioBufCapacity)
    }
    let count = Int(w - r)
    var offset = 0
    while offset < count {
      let chunkSize = min(4800, count - offset)
      var chunk = [Float](repeating: 0, count: chunkSize)
      for i in 0..<chunkSize {
        chunk[i] = audioBuf[Int((r + UInt64(offset + i)) % UInt64(audioBufCapacity))]
      }
      let pts = CMTime(value: audioSamplesAppended, timescale: 48000)
      appendAudio(samples: chunk, pts: pts)
      audioSamplesAppended += Int64(chunkSize)
      offset += chunkSize
    }
    audioReadIndex = r + UInt64(count)
    audioSamplesRecorded = audioSamplesAppended
  }

  private func appendVideo(_ pb: CVPixelBuffer, at pts: CMTime) {
    guard let vIn = videoInput, let adaptor = pixelBufferAdaptor else { return }
    var spins = 0
    while !vIn.isReadyForMoreMediaData && spins < 200 {
      usleep(1000)
      spins += 1
    }
    guard vIn.isReadyForMoreMediaData else {
      fputs("callrec: video input not ready, dropping frame\n", stderr)
      return
    }
    if !adaptor.append(pb, withPresentationTime: pts) {
      fputs("callrec: video append failed: \(String(describing: writer?.error))\n", stderr)
    }
  }

  private func appendAudio(samples: [Float], pts: CMTime) {
    guard let aIn = audioInput, let fmt = audioFormatDesc else { return }
    var spins = 0
    while !aIn.isReadyForMoreMediaData && spins < 200 {
      usleep(1000)
      spins += 1
    }
    guard aIn.isReadyForMoreMediaData else {
      fputs("callrec: audio input not ready, dropping buffer\n", stderr)
      return
    }

    var blockBuffer: CMBlockBuffer?
    let byteCount = samples.count * 4
    guard CMBlockBufferCreateWithMemoryBlock(
      allocator: nil,
      memoryBlock: nil,
      blockLength: byteCount,
      blockAllocator: nil,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: byteCount,
      flags: 0,
      blockBufferOut: &blockBuffer
    ) == noErr, let bb = blockBuffer else { return }

    samples.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      CMBlockBufferReplaceDataBytes(with: base, blockBuffer: bb, offsetIntoDestination: 0, dataLength: byteCount)
    }

    var sampleBuffer: CMSampleBuffer?
    guard CMAudioSampleBufferCreateWithPacketDescriptions(
      allocator: nil,
      dataBuffer: bb,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: fmt,
      sampleCount: samples.count,
      presentationTimeStamp: pts,
      packetDescriptions: nil,
      sampleBufferOut: &sampleBuffer
    ) == noErr, let sb = sampleBuffer else { return }

    if !aIn.append(sb) {
      fputs("callrec: audio append failed: \(String(describing: writer?.error))\n", stderr)
    }
  }

  private func scaleIfNeeded(_ pb: CVImageBuffer) -> CVPixelBuffer {
    let w = CVPixelBufferGetWidth(pb)
    let h = CVPixelBufferGetHeight(pb)
    if w == videoWidth && h == videoHeight {
      return pb
    }
    guard let pool = pixelBufferPool, let session = transferSession else { return pb }
    var dst: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst)
    guard let d = dst else { return pb }
    VTPixelTransferSessionTransferImage(session, from: pb, to: d)
    return d
  }

  private func blurPixelBuffer(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
    guard let pool = pixelBufferPool else { return nil }
    var dst: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst)
    guard let target = dst else { return nil }

    let ci = CIImage(cvPixelBuffer: pb)
    let ext = ci.extent
    guard ext.width > 1, ext.height > 1 else { return nil }
    let radius = max(14.0, min(ext.width, ext.height) / 18.0)
    let blurred = ci.clampedToExtent()
      .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
      .cropped(to: ext)

    ciContext.render(blurred, to: target)
    return target
  }

  private func makeSolidPixelBuffer(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
    guard let buffer = pb else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let ptr = CVPixelBufferGetBaseAddress(buffer) {
      let bpr = CVPixelBufferGetBytesPerRow(buffer)
      let p = ptr.assumingMemoryBound(to: UInt8.self)
      for y in 0..<height {
        let row = y * bpr
        for x in 0..<width {
          let px = row + x * 4
          p[px] = b
          p[px + 1] = g
          p[px + 2] = r
          p[px + 3] = 255
        }
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
  }

  private func makeCameraOffBuffer() -> CVPixelBuffer? {
    makeSolidPixelBuffer(width: videoWidth, height: videoHeight, r: 18, g: 24, b: 36)
  }
}
