import CoreMedia
import Darwin
import Foundation
import VideoToolbox

// ── Decoder ────────────────────────────────────────────────────────────────
//
// The format description is built from the parameter sets that ride in band with
// every keyframe, so a receiver can start cold, or recover from losing the one
// packet that carried them, without any handshake.
final class VDecoder {
  private var session: VTDecompressionSession?
  private var fmt: CMVideoFormatDescription?
  private var psHash = 0
  var onDecoded: ((CVImageBuffer, UInt64) -> Void)?
  var decodes = 0, decFails = 0, noFormat = 0
  var decLatMs = Quantiles()

  private func ensureSession(_ sets: [[UInt8]]) -> Bool {
    guard !sets.isEmpty else { return session != nil }
    var h = 17
    for s in sets { for b in s { h = h &* 31 &+ Int(b) } }
    if h == psHash, session != nil { return true }

    var ptrs: [UnsafePointer<UInt8>] = []
    var lens: [Int] = []
    var keep: [UnsafeMutablePointer<UInt8>] = []
    for s in sets {
      let p = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count)
      p.update(from: s, count: s.count)
      keep.append(p); ptrs.append(UnsafePointer(p)); lens.append(s.count)
    }
    defer { keep.forEach { $0.deallocate() } }

    var f: CMVideoFormatDescription?
    let st = ptrs.withUnsafeBufferPointer { pb in
      lens.withUnsafeBufferPointer { lb in
        CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil,
          parameterSetCount: sets.count, parameterSetPointers: pb.baseAddress!,
          parameterSetSizes: lb.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &f)
      }
    }
    guard st == noErr, let fd = f else { return false }
    fmt = fd; psHash = h
    if let old = session { VTDecompressionSessionInvalidate(old) }
    var s: VTDecompressionSession?
    // Native pixel format, no conversion: a decoder that also converts colour is
    // doing work the display can do for free, on the critical path.
    let attrs: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd,
      decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
      outputCallback: nil, decompressionSessionOut: &s) == noErr, let ss = s else { return false }
    session = ss
    return true
  }

  func decode(_ payload: Data, hostTime: UInt64) {
    var i = 0
    func u8() -> Int? { guard i < payload.count else { return nil }; defer { i += 1 }; return Int(payload[payload.startIndex + i]) }
    func u16() -> Int? {
      guard i + 2 <= payload.count else { return nil }
      let b = payload.startIndex + i; defer { i += 2 }
      return Int(payload[b]) | (Int(payload[b + 1]) << 8)
    }
    func u32() -> Int? {
      guard i + 4 <= payload.count else { return nil }
      let b = payload.startIndex + i; defer { i += 4 }
      return Int(payload[b]) | (Int(payload[b+1]) << 8) | (Int(payload[b+2]) << 16) | (Int(payload[b+3]) << 24)
    }
    guard let n = u8() else { return }
    var sets: [[UInt8]] = []
    for _ in 0..<n {
      guard let l = u16(), i + l <= payload.count else { return }
      sets.append([UInt8](payload[(payload.startIndex + i)..<(payload.startIndex + i + l)]))
      i += l
    }
    guard ensureSession(sets), let sess = session, let fd = fmt else { noFormat += 1; return }
    guard let len = u32(), i + len <= payload.count else { return }
    let sample = [UInt8](payload[(payload.startIndex + i)..<(payload.startIndex + i + len)])

    var bb: CMBlockBuffer?
    let mem = UnsafeMutablePointer<UInt8>.allocate(capacity: len)
    mem.update(from: sample, count: len)
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: mem, blockLength: len,
      blockAllocator: kCFAllocatorMalloc, customBlockSource: nil, offsetToData: 0,
      dataLength: len, flags: 0, blockBufferOut: &bb) == noErr, let blk = bb else {
      mem.deallocate(); decFails += 1; return
    }
    var sb: CMSampleBuffer?
    var sizes = [len]
    var timing = CMSampleTimingInfo(duration: .invalid,
      presentationTimeStamp: CMTime(value: CMTimeValue(hostTime), timescale: 1_000_000_000),
      decodeTimeStamp: .invalid)
    guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: blk, formatDescription: fd,
      sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sb) == noErr,
      let s = sb else { decFails += 1; return }

    let t0 = Clock.now()
    // Synchronous, no temporal processing: asynchronous decode buys throughput
    // by holding frames, and holding frames is the thing being minimised.
    let st = VTDecompressionSessionDecodeFrame(sess, sampleBuffer: s,
      flags: [._1xRealTimePlayback], infoFlagsOut: nil) { [weak self] status, _, img, _, _ in
      guard let self else { return }
      guard status == noErr, let img else { self.decFails += 1; return }
      self.decLatMs.add(Clock.ms(Clock.now() - t0))
      self.decodes += 1
      self.onDecoded?(img, hostTime)
    }
    if st != noErr { decFails += 1 }
  }
}

// ── Fragmentation and reassembly ───────────────────────────────────────────
//
// One encoded frame is far larger than a datagram, so it is split. Reassembly
// keeps a small ring of in-flight frames and, when a newer frame completes,
// abandons older incomplete ones: a partial frame is not worth waiting for and
// waiting is the only cost that cannot be undone later.
final class VideoAssembler {
  private struct Slot {
    var seq: Int32 = -1
    var nfrag = 0
    var have = 0
    var mask = [Bool]()
    var buf = [UInt8]()
    var sizes = [Int]()
    var capHost: UInt64 = 0
  }
  private var slots = [Slot](repeating: Slot(), count: VRING)
  private(set) var complete = 0, dropped = 0, dupFrag = 0, fragsIn = 0
  // FRAMES THAT NEVER ARRIVED AT ALL.
  //
  // `dropped` counts a slot reused while still incomplete, which only ever
  // happens to a frame that arrived in pieces. At these bitrates a frame is about
  // 300 bytes and fits in ONE fragment, so a lost frame never creates a slot and
  // never touched that counter: the report said "partial-drops 0, decFails 0" at
  // 3% packet loss and meant it, while every lost frame went unmentioned. An
  // instrument that cannot see the event returns the same value as a real
  // negative, and this one was doing it on the headline video line.
  //
  // Sequence gaps are the answer, and they are exact.
  private(set) var missing = 0
  private var staleRun = 0
  private(set) var restarts = 0
  private(set) var lastDone: Int32 = -1
  var onFrame: ((Data, UInt64) -> Void)?

  func take(seq: Int32, frag: Int, nfrag: Int, capHost: UInt64, bytes: UnsafePointer<UInt8>, n: Int) {
    fragsIn += 1
    // Same restart trap as the audio ring, and just as fatal: after a peer
    // restart every frame number is <= lastDone, so every frame is discarded as
    // "already delivered" and the picture never returns. A run of them with
    // nothing accepted in between is a restarted sender, not a late frame.
    if seq <= lastDone {
      staleRun += 1
      if staleRun >= 30 {          // one second of video and not a frame accepted
        restarts += 1
        staleRun = 0
        lastDone = -1
        for i in 0..<VRING { slots[i].seq = -1 }
      } else {
        return
      }
    } else {
      staleRun = 0
    }
    let idx = Int(seq) % VRING
    if slots[idx].seq != seq {
      if slots[idx].seq >= 0 && slots[idx].have < slots[idx].nfrag { dropped += 1 }
      slots[idx] = Slot(seq: seq, nfrag: nfrag, have: 0, mask: [Bool](repeating: false, count: nfrag),
                        buf: [UInt8](repeating: 0, count: nfrag * VPAYLOAD), sizes: [Int](repeating: 0, count: nfrag),
                        capHost: capHost)
    }
    guard frag < slots[idx].nfrag else { return }
    if slots[idx].mask[frag] { dupFrag += 1; return }
    slots[idx].mask[frag] = true
    slots[idx].sizes[frag] = n
    slots[idx].buf.withUnsafeMutableBufferPointer { b in
      memcpy(b.baseAddress! + frag * VPAYLOAD, bytes, n)
    }
    slots[idx].have += 1
    guard slots[idx].have == slots[idx].nfrag else { return }

    var out = Data(capacity: slots[idx].sizes.reduce(0, +))
    for f in 0..<slots[idx].nfrag {
      slots[idx].buf.withUnsafeBufferPointer { b in
        out.append(UnsafeBufferPointer(start: b.baseAddress! + f * VPAYLOAD, count: slots[idx].sizes[f]))
      }
    }
    complete += 1
    if lastDone >= 0 && seq > lastDone + 1 { missing += Int(seq - lastDone - 1) }
    lastDone = seq
    onFrame?(out, slots[idx].capHost)
    slots[idx].seq = -1
  }
}

extension Wire {
  /// Split one encoded frame across datagrams. Sent oldest-fragment-first with no
  /// pacing: the frame is already late by the time it exists, and a pacer here
  /// would only add the delay it is trying to smooth.
  func sendVideo(seq: Int32, capHost: UInt64, payload: Data, scratch: UnsafeMutablePointer<UInt8>) {
    let n = payload.count
    let nfrag = max(1, (n + VPAYLOAD - 1) / VPAYLOAD)
    payload.withUnsafeBytes { raw in
      let src = raw.bindMemory(to: UInt8.self).baseAddress!
      for f in 0..<nfrag {
        let off = f * VPAYLOAD
        let len = min(VPAYLOAD, n - off)
        scratch.withMemoryRebound(to: UInt32.self, capacity: 1) { $0[0] = VMAGIC.littleEndian }
        (scratch + 4).withMemoryRebound(to: UInt32.self, capacity: 1) { $0[0] = UInt32(bitPattern: seq).littleEndian }
        (scratch + 8).withMemoryRebound(to: UInt64.self, capacity: 1) { $0[0] = capHost.littleEndian }
        (scratch + 16).withMemoryRebound(to: UInt16.self, capacity: 1) { $0[0] = UInt16(f).littleEndian }
        (scratch + 18).withMemoryRebound(to: UInt16.self, capacity: 1) { $0[0] = UInt16(nfrag).littleEndian }
        (scratch + 20).withMemoryRebound(to: UInt16.self, capacity: 1) { $0[0] = 0 }
        (scratch + 22).withMemoryRebound(to: UInt16.self, capacity: 1) { $0[0] = 0 }
        memcpy(scratch + VHDR, src + off, len)
        rawSend(scratch, VHDR + len, .video)
      }
    }
  }
}
