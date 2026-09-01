import AppKit
import CoreVideo

// ── WHAT IS BEHIND THE GLASS ─────────────────────────────────────────────────
//
// The complaint that this file answers, in the words it arrived in: *"visibility
// has to be best even in bright environments, because this is liquid glass."*
//
// It was not a matter of taste. Photographed over a bright picture -- a white
// wall, a window behind somebody, a lamp -- the control row measured as light grey
// discs with WHITE glyphs on them, around 1.3:1. The `more` button in the corner
// came out at pixel min 241 over a 255 background: a control that is on screen,
// hit-testable, and invisible. Nothing in the app could see it, because every
// screenshot this repo takes of its own layer tree is taken over black, where a
// white glyph on a dark disc is perfect.
//
// ── WHY A CONSTANT DIM CANNOT SOLVE IT ──────────────────────────────────────
//
// `Glass.dim` was 0.35 for every surface, which is the HIG's number, and the HIG
// gives it as advice for bright content:
//
//     "If the underlying content is bright, consider adding a dark dimming layer
//      of 35% opacity."
//
// Note the condition. 0.35 of near-black under pure white leaves 0.65 x 255 = 166,
// and white text on 166 is 1.9:1 -- still illegible. To carry white text at the
// 4.5:1 the guidelines ask for, the surface has to land at about 119, which over
// white needs 0.60, not 0.35. And 0.60 over a DARK picture would be the milky slab
// the person using this app has already rejected twice by name.
//
// One number cannot be both. So the number stops being a constant: this class is a
// coarse map of how bright the picture is, per region of the window, and every
// glass surface asks it what is behind ITSELF and dims by exactly what that patch
// needs. Over a night-time call nothing changes at all; over a sunlit one the
// discs under the glyphs get dark enough to read and the rest of the picture is
// still untouched -- which is the rule this app already had (`GLASS.md`: the
// picture gets nothing, the dim stops at the control's own corners).
//
// ── IT IS FED BY THE PICTURE ITSELF, WHICH COSTS NOTHING ────────────────────
//
// Every decoded frame already passes through `Display.show`. A 420 pixel format
// carries luma in plane 0, so "how bright is this region" is a handful of byte
// reads -- no colour conversion, no CoreImage, no second pass over the frame. It
// is sampled on a 16x9 grid every third frame and published at 5 Hz, which is
// slower than a face moves and far faster than a light changes.
//
// ── AND IT HAS TO BE ABLE TO BE WRONG ───────────────────────────────────────
//
// A brightness meter that returns a constant looks exactly like a call in a dark
// room. `--backdrop-test` runs it over synthetic frames whose answers are known,
// INCLUDING two it must reject, and `tools/contrast-check.sh` photographs the real
// window over a white picture and measures the glyph against the disc it sits on.
final class Backdrop {
  static let shared = Backdrop()

  /// 16x9 keeps a cell at about 80x80 points in a 1280x720 window -- larger than a
  /// control, so a 58 pt circle always lands inside two or three of them, and small
  /// enough that a bright window behind somebody's shoulder does not drag the whole
  /// map up.
  static let cols = 16, rows = 9

  /// Luma per cell, 0…1, row 0 at the TOP of the window. Written on the decode
  /// thread, read on main.
  private var grid = [Float](repeating: 0, count: Backdrop.cols * Backdrop.rows)
  private let lock = NSLock()
  /// Frames seen, so the sampler can take every third one without a timer.
  private var frames: UInt64 = 0
  /// Bumped whenever the map changes enough to be worth redrawing for.
  private(set) var generation: UInt64 = 0
  private var lastPublish = Date.distantPast
  private var everSampled = false
  private var saidUnreadable = false

  /// True once a real frame has been measured. Until then every surface keeps the
  /// dim it was built with: guessing "bright" before there is a picture would flash
  /// a dark slab over the first frame of every call.
  var live: Bool { lock.lock(); defer { lock.unlock() }; return everSampled }

  /// The app's own ground, behind the letterbox bars and before any picture. See
  /// `Palette.bg` -- this is its luma, and it is dark.
  private static let groundLuma: Float = 0.03

  // ── THE MAP ────────────────────────────────────────────────────────────────

  // ── THE GEOMETRY LIVES HERE, BEHIND THE SAME LOCK ─────────────────────────
  //
  // The first version of this kept the layer box and the window size as plain
  // properties on `Display`, written on main when the window resized and read on
  // the DECODE thread once a frame. Two `CGRect`s and a `CGSize` are twelve words
  // between them: a read racing a write does not get one value or the other, it
  // gets half of each, and a torn rectangle would send the sampler off the end of
  // a pixel buffer. Nothing in this program touches a Swift value from two threads
  // without a lock, and this is why.
  private var layerBox = CGRect.zero
  private var winSize = CGSize.zero

  /// Where the video layer sits and how big the window's content is, in points with
  /// the ORIGIN AT THE TOP-LEFT. Called on main, whenever either changes.
  func setGeometry(layerRect: CGRect, windowSize: CGSize) {
    lock.lock()
    layerBox = layerRect
    winSize = windowSize
    lock.unlock()
  }

  /// Sample a decoded frame. The letterbox is computed here from the frame's own
  /// dimensions against the geometry last published by `setGeometry` -- the layer
  /// is `.resizeAspect`, so the bars are the app's own ground and must not be
  /// measured as picture. Cheap enough to call per frame; it skips two in three.
  func sample(_ pb: CVPixelBuffer, mirrored: Bool) {
    lock.lock()
    let box = layerBox, windowSize = winSize
    lock.unlock()
    guard box.width > 1, box.height > 1, windowSize.width > 1, windowSize.height > 1
    else { return }
    let iw = CGFloat(CVPixelBufferGetWidth(pb)), ih = CGFloat(CVPixelBufferGetHeight(pb))
    guard iw > 0, ih > 0 else { return }
    let scale = min(box.width / iw, box.height / ih)
    let vw = iw * scale, vh = ih * scale
    let videoRect = CGRect(x: box.minX + (box.width - vw) / 2,
                           y: box.minY + (box.height - vh) / 2, width: vw, height: vh)
    sample(pb, videoRect: videoRect, windowSize: windowSize, mirrored: mirrored)
  }

  /// The explicit form, for the front door -- whose preview is `.resizeAspectFill`
  /// and has no letterbox -- and for the selftest, which needs to plant one.
  func sample(_ pb: CVPixelBuffer, videoRect: CGRect, windowSize: CGSize, mirrored: Bool) {
    guard windowSize.width > 1, windowSize.height > 1 else { return }
    frames &+= 1
    guard frames % 3 == 0 else { return }
    guard let cells = Backdrop.measure(pb, videoRect: videoRect, windowSize: windowSize,
                                       mirrored: mirrored) else {
      // A format this cannot read is not a quiet fallback: it is a legibility
      // feature that has silently stopped running. Said once.
      if !saidUnreadable {
        saidUnreadable = true
        fputs("backdrop: cannot read pixel format"
            + " \(FourCharCode(CVPixelBufferGetPixelFormatType(pb)))"
            + " -- surfaces keep their built-in dim\n", stderr)
      }
      return
    }
    var changed = false
    lock.lock()
    // A little smoothing, because a camera's auto-exposure hunts and a surface that
    // re-dims with it would breathe. 0.25 settles in about half a second at 10 Hz,
    // which is slower than the eye reads as motion on a translucent panel.
    for i in 0..<grid.count {
      let next = grid[i] + (cells[i] - grid[i]) * (everSampled ? 0.25 : 1.0)
      if abs(next - grid[i]) > 0.01 { changed = true }
      grid[i] = next
    }
    if !everSampled { everSampled = true; changed = true }
    if changed { generation &+= 1 }
    // ── EDGE-TRIGGERED FOR SPEED, LEVEL-TRIGGERED FOR REPAIR ──────────────────
    //
    // Publishing only when the map MOVED is not enough, and the way it fails is
    // worth writing down. A surface that appears later has to sample a map that is
    // not changing: the settings panel opened over a still gradient, the map had
    // long since settled, no notification was due, and the panel's own `layout`
    // did not run because its frame had not changed. Measured: `behind=0.00` on a
    // 420x565 panel sitting on a backdrop the button beside it read as 1.00 -- so
    // the one surface in the app made mostly of sentences was the one that did not
    // dim for them.
    //
    // Same shape as the vocal status byte on the wire, and the same fix: an edge
    // for latency, and a standing republish so a dropped edge costs half a second
    // of staleness rather than being wrong for the rest of the call.
    let since = Date().timeIntervalSince(lastPublish)
    let due = (changed && since > 0.2) || since > 0.5
    if due { lastPublish = Date() }
    lock.unlock()
    if due {
      DispatchQueue.main.async { Backdrop.onChange?() }
    }
  }

  /// Nothing is being shown: the window is the app's own ground. Called when the
  /// picture is flushed, so a surface does not keep dimming for a face that left.
  func clear() {
    lock.lock()
    for i in 0..<grid.count { grid[i] = Backdrop.groundLuma }
    everSampled = true
    generation &+= 1
    lock.unlock()
    DispatchQueue.main.async { Backdrop.onChange?() }
  }

  /// Told directly, for a window whose content is not a video frame -- the front
  /// door's `AVCaptureVideoPreviewLayer`, which hands out no buffers.
  func setUniform(_ luma: CGFloat) {
    lock.lock()
    let v = Float(max(0, min(1, luma)))
    for i in 0..<grid.count { grid[i] = grid[i] + (v - grid[i]) * (everSampled ? 0.3 : 1.0) }
    everSampled = true
    generation &+= 1
    lock.unlock()
    DispatchQueue.main.async { Backdrop.onChange?() }
  }

  /// Mean luma under a rectangle given in window points, top-left origin. Area
  /// weighted across the cells it covers, so a control straddling a bright edge
  /// gets the average of what it is actually sitting on rather than of the cell its
  /// centre happens to land in.
  func luma(under rect: CGRect, in windowSize: CGSize) -> CGFloat {
    guard windowSize.width > 1, windowSize.height > 1, !rect.isEmpty else { return 0 }
    let cw = windowSize.width / CGFloat(Backdrop.cols)
    let ch = windowSize.height / CGFloat(Backdrop.rows)
    let c0 = max(0, Int(floor(rect.minX / cw)))
    let c1 = min(Backdrop.cols - 1, Int(floor((rect.maxX - 0.01) / cw)))
    let r0 = max(0, Int(floor(rect.minY / ch)))
    let r1 = min(Backdrop.rows - 1, Int(floor((rect.maxY - 0.01) / ch)))
    guard c0 <= c1, r0 <= r1 else { return 0 }
    lock.lock(); defer { lock.unlock() }
    guard everSampled else { return 0 }
    var total: CGFloat = 0, area: CGFloat = 0
    for r in r0...r1 {
      let y0 = max(rect.minY, CGFloat(r) * ch), y1 = min(rect.maxY, CGFloat(r + 1) * ch)
      for c in c0...c1 {
        let x0 = max(rect.minX, CGFloat(c) * cw), x1 = min(rect.maxX, CGFloat(c + 1) * cw)
        let a = max(0, x1 - x0) * max(0, y1 - y0)
        guard a > 0 else { continue }
        total += CGFloat(grid[r * Backdrop.cols + c]) * a
        area += a
      }
    }
    return area > 0 ? total / area : 0
  }

  /// The whole map, for the rig and for `describeTree`.
  var describe: String {
    lock.lock(); defer { lock.unlock() }
    guard everSampled else { return "backdrop: no picture yet" }
    let mean = grid.reduce(0, +) / Float(grid.count)
    return "backdrop: mean \(String(format: "%.2f", mean))"
      + " min \(String(format: "%.2f", grid.min() ?? 0))"
      + " max \(String(format: "%.2f", grid.max() ?? 0))"
  }

  /// Called on main whenever the map moved. `Glass` installs one.
  nonisolated(unsafe) static var onChange: (() -> Void)?

  // ── READING THE PIXELS ─────────────────────────────────────────────────────

  /// Point-samples the frame into a `cols x rows` grid of luma, mapped through the
  /// letterbox so a cell that is off the picture reads as the app's own ground.
  /// Returns nil for a format it cannot read, which is not a failure to hide: a
  /// grid of zeros would read as "very dark" and every surface would go glassy over
  /// a picture nobody had measured.
  static func measure(_ pb: CVPixelBuffer, videoRect: CGRect, windowSize: CGSize,
                      mirrored: Bool) -> [Float]? {
    let fmt = CVPixelBufferGetPixelFormatType(pb)
    let planar = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
      || fmt == kCVPixelFormatType_420YpCbCr8Planar
    let bgra = fmt == kCVPixelFormatType_32BGRA || fmt == kCVPixelFormatType_32ARGB
    // ── 4:2:2, WHICH IS WHAT THE BUILT-IN CAMERA ACTUALLY HANDS OUT ──────────
    //
    // The first build of this read 420 and BGRA, which is what the DECODER
    // produces, and the front door's own preview session delivers `2vuy` -- packed
    // UYVY. So the card over somebody's live camera picture was the one surface
    // this could not measure, which is the one surface the complaint was about.
    // Caught only because the reader says out loud when it cannot read a format
    // rather than returning a grid of zeros, which would have read as a very dark
    // room and looked exactly like working.
    let uyvy = fmt == kCVPixelFormatType_422YpCbCr8            // '2vuy': U Y V Y
    let yuy2 = fmt == kCVPixelFormatType_422YpCbCr8_yuvs       // 'yuvs': Y U Y V
    guard planar || bgra || uyvy || yuy2 else { return nil }
    // Video range packs 16…235 into a byte; full range uses 0…255. Getting this
    // wrong is a 7% error, which is nothing here, but the two constants cost one
    // branch outside the loop.
    let videoRange = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || uyvy
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    guard w > 0, h > 0 else { return nil }
    let base: UnsafeMutableRawPointer?
    let stride: Int
    if planar {
      base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)
      stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    } else {
      base = CVPixelBufferGetBaseAddress(pb)
      stride = CVPixelBufferGetBytesPerRow(pb)
    }
    guard let p = base?.assumingMemoryBound(to: UInt8.self) else { return nil }

    var out = [Float](repeating: groundLuma, count: cols * rows)
    let cw = windowSize.width / CGFloat(cols)
    let chh = windowSize.height / CGFloat(rows)
    for r in 0..<rows {
      for c in 0..<cols {
        // The cell's centre, in window points, top-left origin.
        let px = (CGFloat(c) + 0.5) * cw
        let py = (CGFloat(r) + 0.5) * chh
        guard videoRect.contains(CGPoint(x: px, y: py)) else { continue }
        var u = (px - videoRect.minX) / videoRect.width
        let v = (py - videoRect.minY) / videoRect.height
        if mirrored { u = 1 - u }
        // Four taps in a small box rather than one, so a cell that lands on a
        // single specular pixel does not report the whole region as blown out.
        var acc: Float = 0
        var n: Float = 0
        for du in [-0.02, 0.02] as [CGFloat] {
          for dv in [-0.02, 0.02] as [CGFloat] {
            let x = min(w - 1, max(0, Int((u + du) * CGFloat(w))))
            let y = min(h - 1, max(0, Int((v + dv) * CGFloat(h))))
            if planar {
              let b = Float(p[y * stride + x])
              acc += videoRange ? max(0, (b - 16) / 219) : b / 255
            } else if uyvy || yuy2 {
              // Two pixels per four bytes. Luma is the second byte of each pair in
              // UYVY and the first in YUY2.
              let o = y * stride + x * 2 + (uyvy ? 1 : 0)
              let b = Float(p[o])
              acc += videoRange ? max(0, (b - 16) / 219) : b / 255
            } else {
              // BGRA: Rec.709 luma, cheap integer weights.
              let o = y * stride + x * 4
              let bl = Float(p[o]), g = Float(p[o + 1]), rr = Float(p[o + 2])
              acc += (0.2126 * rr + 0.7152 * g + 0.0722 * bl) / 255
            }
            n += 1
          }
        }
        out[r * cols + c] = min(1, max(0, acc / n))
      }
    }
    return out
  }

  // ── THE RULE EVERY SURFACE USES ────────────────────────────────────────────

  /// How much dark a surface has to put under itself, given what is behind it.
  ///
  /// `base` is the surface's design value -- 0.35 for anything sitting straight on
  /// the picture, 0 for a surface that has opted out entirely and must stay out.
  /// The answer is never below `base`: this only ever ADDS dim over a bright
  /// backdrop, so a call in a dark room renders byte-identically to before.
  ///
  /// Solved rather than tuned. White text needs the surface at about 0.47 in sRGB
  /// to reach 4.5:1; the dim's ink is `Palette.dimInk`, near-black at 0.03. Mixing
  /// ink into a backdrop of luma L at opacity a gives L(1-a) + 0.03a, so
  ///
  ///     a = (L - want) / (L - 0.03)
  ///
  /// and the ceiling is what stops a white wall from producing an opaque tile.
  /// `want` is how bright the finished surface is allowed to be, in the same 0…1
  /// gamma-encoded scale the map is in. 0.42 carries a white GLYPH at 4.5:1 and is
  /// the default; a surface with SENTENCES on it asks for 0.26, because secondary
  /// text is a step below white and 11 pt is the size the guidelines are strictest
  /// about. See `Glass.wantLuma`.
  static func dim(base: CGFloat, backdrop L: CGFloat, want: CGFloat = 0.42) -> CGFloat {
    guard base > 0 else { return 0 }
    guard L > want else { return base }
    let need = (L - want) / max(0.05, L - 0.03)
    return max(base, min(Backdrop.maxDim, need))
  }
  /// Past this the surface stops reading as glass and starts reading as a tile.
  /// Measured against a white background: 0.72 lands the disc at 74/255, which is
  /// 8.6:1 for white and still visibly refracting.
  static let maxDim: CGFloat = 0.72

  // ── THE ARM THAT HAS TO FAIL ───────────────────────────────────────────────

  /// `--backdrop-test`. Six frames whose answers are known, two of which the meter
  /// MUST get wrong if it is wired to a constant. Every measuring device in this
  /// repo earns one of these; the two that did not both shipped a reader that
  /// returned the same number for everything.
  static func selftest() -> Bool {
    var ok = true
    func say(_ name: String, _ got: CGFloat, _ want: CGFloat, tol: CGFloat = 0.06) {
      let good = abs(got - want) <= tol
      if !good { ok = false }
      fputs("  \(good ? "OK  " : "FAIL") \(name): got \(String(format: "%.3f", got))"
          + " want \(String(format: "%.3f", want))\n", stderr)
    }
    func frame(_ fill: (Int, Int, Int, Int) -> UInt8, w: Int = 320, h: Int = 180) -> CVPixelBuffer {
      var pb: CVPixelBuffer?
      CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                          [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                          &pb)
      let b = pb!
      CVPixelBufferLockBaseAddress(b, [])
      let p = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
      let s = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
      for y in 0..<h { for x in 0..<w { p[y * s + x] = fill(x, y, w, h) } }
      CVPixelBufferUnlockBaseAddress(b, [])
      return b
    }
    let win = CGSize(width: 1280, height: 720)
    let full = CGRect(origin: .zero, size: win)
    let whole = CGRect(origin: .zero, size: win)

    // 1. A white frame reads as white.
    var g = measure(frame { _, _, _, _ in 255 }, videoRect: full, windowSize: win, mirrored: false)!
    say("white frame", CGFloat(g.reduce(0, +) / Float(g.count)), 1.0)
    // 2. A black frame reads as black. A meter wired to a constant fails one of
    //    these two, whichever constant it was wired to.
    g = measure(frame { _, _, _, _ in 0 }, videoRect: full, windowSize: win, mirrored: false)!
    say("black frame", CGFloat(g.reduce(0, +) / Float(g.count)), 0.0)
    // 3. A half-and-half frame must report the two halves DIFFERENTLY. A meter that
    //    averages the whole picture passes 1 and 2 and fails this.
    let split = frame { x, _, w, _ in x < w / 2 ? 255 : 0 }
    let bd = Backdrop()
    bd.sample(split, videoRect: full, windowSize: win, mirrored: false)
    bd.sample(split, videoRect: full, windowSize: win, mirrored: false)
    bd.sample(split, videoRect: full, windowSize: win, mirrored: false)
    let left = bd.luma(under: CGRect(x: 40, y: 300, width: 100, height: 100), in: win)
    let right = bd.luma(under: CGRect(x: 1140, y: 300, width: 100, height: 100), in: win)
    say("split: left half", left, 1.0)
    say("split: right half", right, 0.0)
    // 4. Mirroring swaps them, which is the only proof the self-view's flip is
    //    carried through rather than ignored.
    let bm = Backdrop()
    for _ in 0..<3 { bm.sample(split, videoRect: full, windowSize: win, mirrored: true) }
    say("mirrored: left half", bm.luma(under: CGRect(x: 40, y: 300, width: 100, height: 100), in: win), 0.0)
    // 5. Letterboxed: the picture occupies the middle third, and the bars must read
    //    as the app's ground rather than as the picture.
    let bl = Backdrop()
    let inset = CGRect(x: 0, y: 240, width: 1280, height: 240)
    for _ in 0..<3 { bl.sample(frame { _, _, _, _ in 255 }, videoRect: inset, windowSize: win, mirrored: false) }
    say("letterbox: bar", bl.luma(under: CGRect(x: 40, y: 20, width: 100, height: 100), in: win),
        CGFloat(groundLuma))
    say("letterbox: picture", bl.luma(under: CGRect(x: 600, y: 330, width: 60, height: 60), in: win), 1.0)
    _ = whole
    // 6. The format the built-in camera actually delivers. The first version of
    //    this reader handled every format except this one, and the surface it
    //    could not measure was the front door -- the only screen in the app with a
    //    card floating over a live camera picture.
    do {
      var pb: CVPixelBuffer?
      let w = 320, h = 180
      CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_422YpCbCr8,
                          [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                          &pb)
      if let b = pb {
        CVPixelBufferLockBaseAddress(b, [])
        let p = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        let st = CVPixelBufferGetBytesPerRow(b)
        // U Y V Y: chroma at the even bytes, luma at the odd ones. Chroma is set to
        // 128 and luma to 235, so a reader that grabbed the wrong byte would
        // measure 0.5 rather than 1.0 and this arm would fail.
        for y in 0..<h { for x in 0..<(w * 2) { p[y * st + x] = x % 2 == 0 ? 128 : 235 } }
        CVPixelBufferUnlockBaseAddress(b, [])
        let g2 = measure(b, videoRect: full, windowSize: win, mirrored: false)
        say("2vuy frame", CGFloat((g2?.reduce(0, +) ?? 0) / Float(g2?.count ?? 1)), 1.0)
      } else { fputs("  FAIL 2vuy frame: could not allocate\n", stderr); ok = false }
    }
    // 7. And the rule the surfaces use, at its three interesting points.
    say("dim over black", dim(base: 0.35, backdrop: 0.0), 0.35, tol: 0.001)
    say("dim over mid", dim(base: 0.35, backdrop: 0.42), 0.35, tol: 0.001)
    say("dim over white", dim(base: 0.35, backdrop: 1.0), 0.598, tol: 0.01)
    say("dim opted out stays out", dim(base: 0, backdrop: 1.0), 0, tol: 0.001)
    say("dim over white, text surface", dim(base: 0.35, backdrop: 1.0, want: 0.26), 0.72, tol: 0.01)
    return ok
  }
}
