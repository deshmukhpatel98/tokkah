import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// One luma plane to a grayscale PNG, so a filter can be judged by eyes and not
/// only by a PSNR -- a PSNR counts removed noise as damage.
@discardableResult
func writeGrayPNG(_ buf: [UInt8], w: Int, h: Int, path: String) -> Bool {
  guard let provider = CGDataProvider(data: Data(buf) as CFData),
        let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                   "public.png" as CFString, 1, nil) else { return false }
  CGImageDestinationAddImage(dest, cg, nil)
  return CGImageDestinationFinalize(dest)
}

// ── Take the noise out BEFORE the encoder sees it ────────────────────────────
//
// The picture ladder's "visually lossless" rung (q0.7, 45.5 dB) costs 1.2 Mbps
// on a clean talking-head file and 4.4-4.7 Mbps on every live call this month
// (~18.5 KB/frame, 17 fragments). Same encoder, same quality, same kind of
// content. The difference is what a real sensor adds to every frame: a fresh
// random pattern of noise that no reference frame predicts, so the encoder pays
// for it in full, thirty times a second, and then pays again when a fragment is
// lost because there were more fragments to lose.
//
// Noise is not detail. Detail is where the picture is the same from one frame to
// the next; noise is where it is different by a little for no reason. A pixel
// that moved by a few levels is almost certainly noise and gets averaged with
// its own past; a pixel that moved a lot is a lip, an eyebrow or a hand and is
// taken whole. That is the entire filter: one blend weight per pixel, chosen by
// how far the pixel moved, applied against the FILTERED previous frame so the
// average deepens over still regions and resets instantly on motion.
//
// It has to be cheap -- it runs on the capture thread in front of a 720p30
// encoder that is itself under 3 ms -- so it is one SIMD pass over the bytes,
// integer only, no allocations after the first frame.
//
// What it must NOT do: smear the mouth. Mouth.swift reads lip motion from the
// camera to tell a person from an echo (visual-turn-taking), and a filter that
// ghosts moving lips would blunt the one signal that separates them. Hence the
// threshold is LOW (a moving lip differs by far more than 24 levels) and the
// ramp is linear, so real motion passes at full weight. Mouth reads the raw
// frame anyway; only the encoder sees the filtered one.
final class VDenoise {
  /// The reference frames are kept in Q4 fixed point (16 bits, 4 fractional).
  /// In 8 bits the blend rounds to zero for exactly the differences that ARE the
  /// noise -- a 1-level flicker at the floor weight is 0.28 of a level, which
  /// rounds to nothing, so the first version of this filter left dark-room grain
  /// almost untouched (crops of raw and filtered were indistinguishable). With
  /// four fractional bits the average accumulates and the grain goes.
  private var prevY: UnsafeMutablePointer<Int16>?
  private var prevC: UnsafeMutablePointer<Int16>?
  private var w = 0, h = 0
  private var pool: CVPixelBufferPool?
  /// The motion threshold IN FORCE, in luma levels. Adaptive unless pinned.
  private(set) var threshold: Int
  /// Pinned by `--vdenoise-t`; nil means follow the measured noise.
  private let pinned: Int?
  let floorWeight: Double
  // ── THE THRESHOLD FOLLOWS THE NOISE ─────────────────────────────────────────
  //
  // A fixed 24 measured 12% grain removal on a dark room (std 5.8 -> 5.1). The
  // frame-to-frame difference of noise that size is ~8 levels, and at 8 the ramp
  // was already handing the pixel half-weight: the filter was reading the noise
  // as motion. So the threshold is set from the noise itself, every frame: the
  // mean |difference| of the pixels judged still, times four (3.2 sigma for a
  // Gaussian), clamped so a pitch-black frame cannot pin it at the bottom and a
  // shaking camera cannot open it wide enough to smear a face.
  //
  // FIRST VERSION OF THIS TRAPPED ITSELF AT THE BOTTOM: it averaged only the
  // pixels already under the threshold, so a low threshold admitted only small
  // differences, which read as low noise, which kept the threshold low (settled
  // at the clamp, 6, on a room whose noise wanted ~26). The estimate now comes
  // from a histogram of |difference| over EVERY luma pixel and takes the median:
  // moving pixels are a few percent of a talking head and cannot move a median,
  // and nothing about the current threshold feeds back into it.
  //
  // GAIN, measured on two real captures: a lit room (median 0.7) and a dark one
  // (median 2.3). Lit content wants ~8 (at 16 a slow pan already reads 45 dB of
  // filter change, at 40 the whole face is a ghost); the dark room wants ~28-40
  // to take the grain out (-58% bits at 40 vs -19% at 10). 12 lands both.
  static let adaptGain = 12, tMin = 6, tMax = 40
  private var hist = [Int32](repeating: 0, count: 256)
  /// Milliseconds per frame, so the cost is a number in the beat and not a guess.
  var cost = Quantiles()
  /// Where inside the frame the time goes: getting and locking the buffers,
  /// the luma pass, the chroma pass. Attribution, so "2 ms" can be attacked.
  var costSetup = Quantiles(), costLuma = Quantiles(), costChroma = Quantiles()
  private(set) var frames = 0
  /// Frames handed back untouched because the format or size was not the one
  /// the encoder is configured for. Non-zero means the filter is not running.
  private(set) var bypassed = 0
  /// The camera's own noise as the encoder would otherwise have seen it: the
  /// MEDIAN |frame-to-frame luma difference| against the filtered reference, in
  /// levels. A lit room reads 1-2; a laptop in the dark 5 and more.
  private(set) var noiseX100 = 0
  /// Share of luma pixels judged still (below threshold) on the last frame, %.
  private(set) var stillPct = 0

  init(threshold: Int? = nil, floorWeight: Double = 0.25) {
    pinned = threshold.map { max(1, min(255, $0)) }
    self.threshold = pinned ?? 24
    self.floorWeight = max(0, min(1, floorWeight))
  }

  deinit { prevY?.deallocate(); prevC?.deallocate() }

  private func prepare(_ w: Int, _ h: Int) -> Bool {
    if self.w == w, self.h == h, pool != nil { return true }
    prevY?.deallocate(); prevC?.deallocate()
    prevY = .allocate(capacity: w * h)
    prevC = .allocate(capacity: w * h / 2)   // interleaved CbCr: (w/2 * 2) * (h/2)
    self.w = w; self.h = h
    frames = 0
    let attrs: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelBufferWidthKey: w,
      kCVPixelBufferHeightKey: h,
      // IOSurface-backed, because that is what VideoToolbox wants to read without
      // a copy, and what the camera hands us in the first place.
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 4]
    var p: CVPixelBufferPool?
    let st = CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &p)
    guard st == kCVReturnSuccess, let p else {
      fputs("denoise: pool failed (\(st)) -- frames pass through unfiltered\n", stderr)
      pool = nil
      return false
    }
    pool = p
    return true
  }

  /// The filtered frame, or the input itself when it cannot be filtered.
  func filter(_ src: CVPixelBuffer) -> CVPixelBuffer {
    guard CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
          CVPixelBufferGetPlaneCount(src) == 2 else { bypassed += 1; return src }
    let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
    guard w > 0, h > 0, h % 2 == 0, prepare(w, h), let pool else { bypassed += 1; return src }
    var outOpt: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outOpt) == kCVReturnSuccess, let out = outOpt else {
      bypassed += 1; return src
    }
    let tPool = Clock.now()
    CVPixelBufferLockBaseAddress(src, .readOnly)
    CVPixelBufferLockBaseAddress(out, [])
    defer {
      CVPixelBufferUnlockBaseAddress(out, [])
      CVPixelBufferUnlockBaseAddress(src, .readOnly)
    }
    guard let sy = CVPixelBufferGetBaseAddressOfPlane(src, 0), let sc = CVPixelBufferGetBaseAddressOfPlane(src, 1),
          let dy = CVPixelBufferGetBaseAddressOfPlane(out, 0), let dc = CVPixelBufferGetBaseAddressOfPlane(out, 1),
          let py = prevY, let pc = prevC else { bypassed += 1; return src }
    let t0 = Clock.now()
    costSetup.add(Clock.ms(t0 - tPool))
    let ssY = CVPixelBufferGetBytesPerRowOfPlane(src, 0), ssC = CVPixelBufferGetBytesPerRowOfPlane(src, 1)
    let dsY = CVPixelBufferGetBytesPerRowOfPlane(out, 0), dsC = CVPixelBufferGetBytesPerRowOfPlane(out, 1)
    let hC = CVPixelBufferGetHeightOfPlane(src, 1)
    let cw = CVPixelBufferGetWidthOfPlane(src, 1) * 2   // interleaved Cb,Cr bytes per row

    if frames == 0 {
      // Nothing to average with yet: the first frame is the reference.
      for y in 0..<h {
        let s = sy.assumingMemoryBound(to: UInt8.self) + y * ssY
        let p = py + y * w
        for x in 0..<w { p[x] = Int16(s[x]) << 4 }
        memcpy(dy + y * dsY, s, w)
      }
      for y in 0..<hC {
        let s = sc.assumingMemoryBound(to: UInt8.self) + y * ssC
        let p = pc + y * cw
        for x in 0..<cw { p[x] = Int16(s[x]) << 4 }
        memcpy(dc + y * dsC, s, cw)
      }
      frames = 1
      cost.add(Clock.ms(Clock.now() - t0))
      return out
    }

    let T = Int32(threshold)
    var stillN: Int32 = 0
    for i in 0..<256 { hist[i] = 0 }
    // ── SIXTEEN PIXELS AT A TIME ───────────────────────────────────────────────
    //
    // The scalar loop with a 256-entry table cost 3.5 ms a frame on the capture
    // thread (p99 over 20 ms under load), and glass-to-glass on the filtered
    // direction of a loopback call read 3.4 ms longer than the unfiltered one.
    // A table lookup does not vectorise, so the weight is the same ramp as an
    // expression: w = min(256, floor + |d| * slope), which does. The histogram
    // samples one lane in sixteen -- 57k samples a frame is plenty for a median.
    let wf = Int32(floorWeight * 256)
    let slope = Int32(((256 - Int(wf)) * 256) / threshold)     // Q8 per level
    // ── EIGHT 16-BIT LANES, NOT SIXTEEN 32-BIT ONES ────────────────────────────
    //
    // Measured standalone (swiftc -O, 1280x720): SIMD16<Int32> 1.00 ms, scalar
    // 0.34 ms, SIMD8<Int16> 0.25 ms. The values fit 16 bits (Q4 <= 4080); only
    // the weight multiply needs 32, so only it widens. The in-app version of the
    // 32-bit loop read 3.2 ms because the histogram branch sat inside it; the
    // statistics are now a separate pass over every fourth row.
    let vWf = SIMD8<Int32>(repeating: wf), vSlope = SIMD8<Int32>(repeating: slope)
    let v256 = SIMD8<Int32>(repeating: 256), v255 = SIMD8<Int32>(repeating: 255)
    let v128 = SIMD8<Int32>(repeating: 128), v8 = SIMD8<Int16>(repeating: 8)
    @inline(__always)
    func run(_ s: UnsafePointer<UInt8>, _ p: UnsafeMutablePointer<Int16>, _ d: UnsafeMutablePointer<UInt8>, _ n: Int) {
      var x = 0
      while x + 8 <= n {
        let cur = SIMD8<Int16>(truncatingIfNeeded: UnsafeRawPointer(s + x).loadUnaligned(as: SIMD8<UInt8>.self)) &<< 4
        let prev = UnsafeRawPointer(p + x).loadUnaligned(as: SIMD8<Int16>.self)
        let diff = SIMD8<Int32>(truncatingIfNeeded: cur &- prev)
        let ad = pointwiseMin(pointwiseMax(diff, 0 &- diff) &>> 4, v255)
        let w = pointwiseMin(vWf &+ ((ad &* vSlope) &>> 8), v256)
        let v = SIMD8<Int16>(truncatingIfNeeded: (diff &* w &+ v128) &>> 8) &+ prev
        UnsafeMutableRawPointer(p + x).storeBytes(of: v, as: SIMD8<Int16>.self)
        UnsafeMutableRawPointer(d + x).storeBytes(of: SIMD8<UInt8>(truncatingIfNeeded: (v &+ v8) &>> 4), as: SIMD8<UInt8>.self)
        x &+= 8
      }
      // Tail (widths that are not a multiple of 8), scalar.
      while x < n {
        let cur = Int32(s[x]) << 4, prev = Int32(p[x])
        let diff = cur &- prev
        let ad = min((diff < 0 ? 0 &- diff : diff) >> 4, 255)
        let w = min(wf &+ ((ad &* slope) >> 8), 256)
        let v = prev &+ ((diff &* w &+ 128) >> 8)
        p[x] = Int16(truncatingIfNeeded: v)
        d[x] = UInt8(truncatingIfNeeded: (v &+ 8) >> 4)
        x &+= 1
      }
    }
    /// The noise statistics for one row, BEFORE it is filtered: |raw - reference|
    /// per pixel, one in eight sampled into the histogram, all counted for still.
    @inline(__always)
    func stats(_ s: UnsafePointer<UInt8>, _ p: UnsafePointer<Int16>, _ n: Int, _ H: UnsafeMutableBufferPointer<Int32>) -> Int32 {
      var x = 0, still: Int32 = 0
      while x + 8 <= n {
        let cur = SIMD8<Int16>(truncatingIfNeeded: UnsafeRawPointer(s + x).loadUnaligned(as: SIMD8<UInt8>.self)) &<< 4
        let prev = UnsafeRawPointer(p + x).loadUnaligned(as: SIMD8<Int16>.self)
        let diff = cur &- prev
        let ad = pointwiseMin(pointwiseMax(diff, 0 &- diff) &>> 4, SIMD8<Int16>(repeating: 255))
        H[Int(ad[0])] &+= 1
        still &+= Int32(SIMD8<Int16>(repeating: 0).replacing(with: 1, where: ad .< SIMD8<Int16>(repeating: Int16(T))).wrappedSum())
        x &+= 8
      }
      return still
    }
    hist.withUnsafeMutableBufferPointer { H in
      // Statistics on every fourth row, taken before that row is filtered (the
      // reference is still last frame's). A median over 14k samples is the same
      // median, and this keeps the scatter store out of the hot loop entirely.
      for y in 0..<h {
        let s = sy.assumingMemoryBound(to: UInt8.self) + y * ssY
        if y & 3 == 0 { stillN &+= stats(s, py + y * w, w, H) }
        run(s, py + y * w, dy.assumingMemoryBound(to: UInt8.self) + y * dsY, w)
      }
    }
    let tL = Clock.now()
    costLuma.add(Clock.ms(tL - t0))
    // Chroma, same rule. Chroma noise is where the colour speckle lives and it
    // is as expensive to the encoder as the luma kind.
    for y in 0..<hC {
      run(sc.assumingMemoryBound(to: UInt8.self) + y * ssC, pc + y * cw,
          dc.assumingMemoryBound(to: UInt8.self) + y * dsC, cw)
    }
    frames += 1
    costChroma.add(Clock.ms(Clock.now() - tL))
    stillPct = Int(stillN) * 100 / max(1, (w / 16) * 16 * ((h + 3) / 4))
    // Median of |difference| from the histogram. The bins are whole levels, so
    // interpolate within the median bin for a number that moves smoothly.
    var counted: Int32 = 0
    for i in 0..<256 { counted &+= hist[i] }
    let half = counted / 2
    var acc: Int32 = 0, med = 0
    for i in 0..<256 {
      let next = acc &+ hist[i]
      if next >= half {
        let frac = hist[i] > 0 ? Double(half - acc) / Double(hist[i]) : 0
        noiseX100 = Int((Double(i) + frac) * 100)
        med = i
        break
      }
      acc = next
    }
    _ = med
    if pinned == nil {
      let want = max(Self.tMin, min(Self.tMax, noiseX100 * Self.adaptGain / 100))
      if want != threshold { threshold = want }
    }
    cost.add(Clock.ms(Clock.now() - t0))
    return out
  }
}
