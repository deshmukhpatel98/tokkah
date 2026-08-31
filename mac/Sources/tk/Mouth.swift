import Foundation
import Vision
import CoreVideo
import AVFoundation

// ── WHO IS TALKING, SEEN RATHER THAN HEARD ───────────────────────────────────
//
// Every turn-taking bug in this project has one root, and Audio.swift states it
// in writing: *at the instant of decision, an interruption and an echo are the
// same signal.* They are the same ACOUSTIC signal. A camera does not have that
// problem -- a loudspeaker has no mouth -- so a picture is independent evidence
// about the one question sound cannot answer.
//
// The user asked for exactly this ("maybe a lightweight mediapipe model that
// works in realtime to understand and work in tandem with the microphone to
// decide who wants to speak"). Apple's Vision framework is the same capability
// with no dependency to vendor, no model to ship, and the Neural Engine to run
// it on, against frames this app already has in hand.
//
// ── WHAT IS MEASURED, AND WHY IT IS A DERIVATIVE ─────────────────────────────
//
// Not "is the mouth open". A person sitting with their mouth open is not
// speaking, a person mid-consonant has it shut, and mouth shapes differ enormously
// between faces. What separates speech from a face at rest is that the aperture
// KEEPS CHANGING -- roughly a syllable at a time, 3-8 Hz. So the signal is the
// rate of change of lip aperture, which needs no per-face calibration and no
// threshold on anybody's anatomy.
//
// Normalised by the face's own bounding box, so leaning towards the camera
// changes nothing.
//
// ── AND IT MUST NEVER BE THE REASON A MICROPHONE CLOSES ──────────────────────
//
// The same law as `Predict`: this is a prior, never a trigger. `blind-instruments-
// report-negatives` is the trap that matters here -- a detector that cannot see a
// face must NOT return the same value as one watching somebody sit in silence, or
// every dark room, every camera-off call and every failed request becomes "this
// person is not talking". So there are three states and the third is load-bearing:
//
//   moving   a face is visible and its mouth is doing what speech does
//   still    a face is visible and it is not
//   unknown  no face, no camera, no frame, a request that failed -- SAYS NOTHING
//
// Only `moving` and `still` are allowed to influence anything, and only ever in
// the direction that OPENS a microphone or SPEEDS UP a handover.
final class Mouth {
  nonisolated(unsafe) static let shared = Mouth()

  /// A face is visible and its mouth is moving the way speech moves it. Written
  /// on the vision queue, read by the capture thread -- a Bool, so it crosses.
  nonisolated(unsafe) static var visualVoice = false
  /// A face is visible at all. False means this detector is BLIND and every
  /// consumer must fall back to audio alone.
  nonisolated(unsafe) static var visualKnown = false
  /// `--no-mouth` stops the detector entirely.
  nonisolated(unsafe) static var on = true
  /// ── MEASURED, BUT NOT ACTED ON, UNTIL IT IS CALIBRATED ON REAL FACES ──────
  ///
  /// OFF by default as of 0.104.0, and this is a retraction rather than a
  /// caution. Live call 1tv8qd52vuitl / 35ik4lvka5qkb, both ends 0.103.0:
  ///
  ///   mouth moving 70%  and  96%  of the call
  ///
  /// A two-person conversation cannot have both people talking 70-96% of the
  /// time. The detector was not reporting speech, it was reporting *being alive
  /// in front of a camera* — and the reason is the calibration, not the maths.
  /// The rig footage is a talking head whose head barely moves; a real caller
  /// moves constantly, and head YAW changes the apparent width of the mouth by
  /// foreshortening, so the opening-over-width ratio moves when the pose moves
  /// and not only when the jaw does. `validate-the-ruler-against-known-inputs`
  /// held on the clip it was given and the clip was not the world.
  ///
  /// What that cost, on the same call: the echo veto is withdrawn whenever this
  /// says "moving", so it fell from 6.9% of samples to 2.1% and 0.0%, echo
  /// peaked at 0.92 — the worst measured in this project — and both microphones
  /// were live for 23% and 29% of the call. The signal that was supposed to
  /// separate a person from a loudspeaker had switched off the thing that
  /// already did.
  ///
  /// So: the detector keeps LOOKING and keeps reporting, because a real call is
  /// now the only place a threshold can honestly be derived and the beats are
  /// how it gets derived. It influences nothing until `--mouth-influence`.
  ///
  /// The fix it needs is a different measure, not a bigger number: speech is an
  /// OSCILLATION at 3-8 Hz and a head turn is a slow monotonic drift. Band-pass
  /// energy separates those; a magnitude threshold cannot. That needs a faster
  /// look rate than 12 Hz (Nyquist 6 Hz is inside the band) and is the next
  /// piece of work, not a tuning pass.
  nonisolated(unsafe) static var influence = false

  /// How often frames are looked at. 12 Hz is three or four samples per
  /// syllable -- enough to see the rate of change -- at 40% of the cost of
  /// every frame. A call already spends ~0.16 CPU-s/s; this is not the place to
  /// spend the rest of it.
  static let hz: Double = 12
  /// How fast the mouth's openness is changing, above which it is doing what
  /// speech does. Units: aperture-RATIO per second, where the ratio is mouth
  /// opening over mouth width (see `aperture`).
  ///
  /// MEASURED, twice, and wrong both times before it was measured.
  ///
  ///   1. A guessed 0.35 sat above the talking p90 of the original
  ///      face-height measure and called a speaking face silent 100% of the
  ///      time, while passing every other arm in this rig.
  ///   2. Then the measure itself changed -- from vertical extent to the lip
  ///      cloud's own axes, to survive rotation -- and that is a CHANGE OF
  ///      UNITS, which is its own trap (`stale-constants-after-a-codec-win`).
  ///      The old 0.03 was suddenly far too low: it called a face held
  ///      perfectly still "moving" 31% of the time.
  ///
  /// On real talking-head footage at 12 Hz, in the current units:
  ///
  ///   talking   rate p10 0.30  p50 0.63  p90 1.30
  ///   same face p10 0.01  p50 0.02  p90 0.08      (one frame of it, held)
  ///
  /// 7.9x apart, against 4.4x for the measure this replaced -- the invariance
  /// came with a better signal, not a worse one. 0.15 sits between the still
  /// p90 and the talking p10; the rig sweeps neighbours on every run.
  nonisolated(unsafe) static var moveThreshold: Double = 0.15
  /// Speech pauses between words and inside them, and a detector that drops on
  /// every closed consonant would flap. Held this long past the last sample
  /// that cleared the bar. Shorter than the audio VAD's 560 ms hangover on
  /// purpose: this signal only ever confirms, so a stale `true` is worth less
  /// than a late one.
  static let hangoverMs: Double = 250
  /// No face for this long and the detector says so rather than remembering.
  static let blindAfterMs: Double = 400

  /// ── THE ORIENTATION IS DISCOVERED, NOT ASSUMED ────────────────────────────
  ///
  /// Vision needs to be told which way up a buffer is, and getting it wrong
  /// does not fail loudly: it finds NO FACES, which this detector correctly
  /// reports as `unknown` -- so a wrong constant here is a feature that ships,
  /// runs, costs CPU and does nothing, forever, with every self-test passing.
  /// `feature-behind-a-flag-nobody-runs`, except the flag is a rotation.
  ///
  /// It cannot be settled by testing on this machine: a rig binary is refused
  /// the camera because TCC binds a grant to code identity
  /// (`tcc-identity-is-a-content-hash`), and the file-based rig carries its own
  /// orientation. So the code does not guess. It tries the plausible ones, one
  /// per look, until a face appears -- about 0.4 s at 12 Hz -- and latches onto
  /// the one that worked. Whichever a Mac, an iPhone Continuity camera or an
  /// external webcam actually delivers, this finds it.
  ///
  /// It never un-latches. A latched orientation that stops finding faces means
  /// somebody left the room, which is the common case, and re-searching on
  /// absence would thrash between rotations every time a person looked away.
  ///
  /// MEASURED ON A REAL SENSOR, which no rig on this Mac can do: the shipped
  /// build latches `leftMirrored` after TWO looks -- `.up` finds no face on a
  /// real camera buffer and `.leftMirrored` does. So this search is not a
  /// safety net, it is required, and it costs ~170 ms of a call at 12 Hz to
  /// settle. The file-based rig arm reaches the opposite conclusion because a
  /// 90-degree file rotation is not the rotate-and-mirror a camera applies;
  /// that arm's own note says so rather than generalising.
  static let orientations: [CGImagePropertyOrientation] =
    [.up, .leftMirrored, .rightMirrored, .right, .left, .upMirrored]
  private var orientIdx = 0
  private(set) var orientLatched: CGImagePropertyOrientation?
  /// Which rotation won, for the beat. The first real call answers a question
  /// no rig on this machine can.
  var orientName: String {
    guard let o = orientLatched else { return "searching" }
    switch o {
    case .up: return "up"
    case .upMirrored: return "upMirrored"
    case .left: return "left"
    case .leftMirrored: return "leftMirrored"
    case .right: return "right"
    case .rightMirrored: return "rightMirrored"
    default: return "other"
    }
  }

  /// ── DOWNSCALING WAS TRIED AND IS SLOWER. DO NOT RETRY IT. ─────────────────
  ///
  /// The obvious optimisation: face landmarks do not need 720p, so hand Vision
  /// a small luma-only copy. Built it with `vImageScale_Planar8` into a reused
  /// `OneComponent8` buffer, and measured 800 looks over the same footage:
  ///
  ///   native 420v, no scaling   2.90 ms/look     <- what ships
  ///   grayscale, 1280 wide      4.58 ms/look
  ///   grayscale,  320 wide      7.17 ms/look
  ///   grayscale,  240 wide     10.65 ms/look
  ///
  /// Monotonically WORSE the smaller it got, which is the giveaway: the cost is
  /// not proportional to pixels. Vision has a fast path for the biplanar format
  /// the camera and the decoder already produce, and a single-plane grayscale
  /// buffer leaves it -- so the scaling work was pure addition and the slow
  /// route cost more than the pixels saved.
  ///
  /// Reverted. Recorded here because it is the first thing anybody will think of.

  /// The size Vision scanned, stamped in `detect`. Callers use this rather than
  /// measuring the source buffer themselves, so the two can never disagree
  /// about which image a set of landmarks belongs to.
  private(set) var lastScanSize = CGSize(width: 0, height: 0)

  private let q = DispatchQueue(label: "kin.mouth", qos: .userInitiated)
  private var inFlight = false
  private var lastLookAt: UInt64 = 0
  private var lastAperture: Double = -1
  private var lastSampleAt: UInt64 = 0
  private var movingUntil: UInt64 = 0
  private var lastFaceAt: UInt64 = 0
  /// Smoothed |d aperture / dt|, in face-heights per second.
  private(set) var rateNow: Double = 0
  /// Counters, because a signal nobody can audit is a signal nobody should
  /// wire into a live call.
  private(set) var looks = 0
  private(set) var faces = 0
  private(set) var movingSamples = 0
  private(set) var stillSamples = 0
  private(set) var dropped = 0

  /// Called from the camera's `onFrame`, on whatever thread that is. Returns
  /// immediately, always: this is a video capture callback and the encoder is
  /// behind it. A frame that arrives while the last one is still being looked
  /// at is DROPPED and counted -- never queued, because a queue here would
  /// deliver a verdict about a face that has already stopped talking.
  func note(_ pb: CVPixelBuffer) {
    guard Mouth.on else { return }
    let now = Clock.now()
    if lastLookAt != 0, Clock.ms(now - lastLookAt) < 1000.0 / Mouth.hz { return }
    if inFlight { dropped += 1; return }
    lastLookAt = now
    inFlight = true
    // The buffer is retained for the hop to the vision queue. The capture path
    // recycles its pool, and a request reading a buffer that has been handed
    // back is a race that shows up as garbage landmarks rather than a crash.
    q.async { [weak self] in
      self?.look(pb, at: now)
    }
  }

  /// The one place a face is looked for. Shared by the live camera path and by
  /// the file rig, so the orientation search the rig proves is the same code a
  /// real call runs -- a second copy of it would be the copy that drifts, and
  /// this is precisely the mechanism no rig on this Mac can check against a
  /// real sensor.
  func detect(_ pb: CVPixelBuffer) -> VNFaceObservation? {
    let req = VNDetectFaceLandmarksRequest()
    lastScanSize = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
    let orient = orientLatched ?? Mouth.orientations[orientIdx % Mouth.orientations.count]
    let h = VNImageRequestHandler(cvPixelBuffer: pb, orientation: orient, options: [:])
    do { try h.perform([req]) } catch {
      Metrics.count("mouth_request_failed")
      return nil
    }
    // The LARGEST face, not the first. With two people in shot the one filling
    // the frame is the one holding this microphone.
    guard let f = (req.results ?? []).max(by: {
      $0.boundingBox.height * $0.boundingBox.width < $1.boundingBox.height * $1.boundingBox.width
    }) else {
      // While nothing has ever been found, advance the search: one candidate
      // per look, so all six are tried in about half a second at 12 Hz.
      if orientLatched == nil { orientIdx += 1 }
      return nil
    }
    if orientLatched == nil {
      orientLatched = orient
      Metrics.fact("mouth_orient", orientName)
      fputs("mouth: faces found with the camera read as \(orientName)"
          + " -- latched after \(looks) looks\n", stderr)
    }
    return f
  }

  /// Reset, so one process can scan several clips independently. Rig only.
  func forgetForTest() {
    orientLatched = nil; orientIdx = 0
    lastAperture = -1; lastSampleAt = 0; movingUntil = 0; lastFaceAt = 0
    rateNow = 0; looks = 0; faces = 0; movingSamples = 0; stillSamples = 0; dropped = 0
    Mouth.visualKnown = false; Mouth.visualVoice = false
  }

  private func look(_ pb: CVPixelBuffer, at t: UInt64) {
    defer { inFlight = false }
    looks += 1
    guard let f = detect(pb) else {          // sets lastScanSize
      // No face. Not "not talking" -- see the three states above.
      if lastFaceAt == 0 || Clock.ms(t - lastFaceAt) > Mouth.blindAfterMs {
        Mouth.visualKnown = false
        Mouth.visualVoice = false
        lastAperture = -1
      }
      return
    }
    faces += 1
    lastFaceAt = t
    guard let ap = Mouth.aperture(f, imageSize: lastScanSize) else {
      Mouth.visualKnown = false
      return
    }
    Mouth.visualKnown = true

    // Rate of change, per second, in face-heights. The first sample of a face
    // establishes a baseline and asserts nothing.
    if lastAperture >= 0, lastSampleAt != 0 {
      let dtS = max(0.001, Clock.ms(t - lastSampleAt) / 1000.0)
      let rate = abs(ap - lastAperture) / dtS
      // Smoothed a little, over about two samples, so one landmark jitter does
      // not read as a syllable.
      rateNow = rateNow * 0.5 + rate * 0.5
      if rateNow >= Mouth.moveThreshold {
        movingSamples += 1
        movingUntil = t
      } else {
        stillSamples += 1
      }
      let held = movingUntil != 0 && Clock.ms(t - movingUntil) <= Mouth.hangoverMs
      Mouth.visualVoice = held
    }
    lastAperture = ap
    lastSampleAt = t
  }

  /// ── APERTURE, MEASURED WITHOUT KNOWING WHICH WAY UP ANYTHING IS ──────────
  ///
  /// The first version took the VERTICAL extent of the inner lips in
  /// bounding-box units, and the rig caught what that costs: the same talking
  /// clip turned 90 degrees still had its face found in 100% of frames -- Vision
  /// does not need the orientation hint to DETECT a face -- but the talking
  /// verdict fell from 100% to 86%, because the landmark frame turned with the
  /// image and "vertical extent" had become partly mouth WIDTH.
  ///
  /// That is a bug no orientation search can find, precisely because nothing
  /// fails: faces are found, numbers come out, and the signal is quietly worse.
  /// So the measurement stops depending on the answer.
  ///
  /// The lip contour has its own two axes: a long one across the mouth and a
  /// short one across the opening. Their ratio -- how open the mouth is
  /// relative to how wide it is -- is dimensionless and identical under any
  /// rotation, any scale, and any distance from the camera. It also needs no
  /// face-height normalisation, because the mouth normalises itself.
  ///
  /// Taken in IMAGE pixels rather than bounding-box units: a box is
  /// axis-aligned, so box-relative coordinates are stretched differently in x
  /// and y as a head turns, and a ratio built on them would wobble with the
  /// box rather than with the mouth.
  static func aperture(_ f: VNFaceObservation, imageSize: CGSize) -> Double? {
    guard let lips = f.landmarks?.innerLips ?? f.landmarks?.outerLips,
          lips.pointCount >= 4 else { return nil }
    let pts = lips.pointsInImage(imageSize: imageSize)
    // Mean-centre.
    var mx = 0.0, my = 0.0
    for p in pts { mx += Double(p.x); my += Double(p.y) }
    mx /= Double(pts.count); my /= Double(pts.count)
    // 2x2 covariance of the point cloud.
    var sxx = 0.0, syy = 0.0, sxy = 0.0
    for p in pts {
      let dx = Double(p.x) - mx, dy = Double(p.y) - my
      sxx += dx * dx; syy += dy * dy; sxy += dx * dy
    }
    let n = Double(pts.count)
    sxx /= n; syy /= n; sxy /= n
    // Principal axis: the eigenvector of the larger eigenvalue. Closed form for
    // a symmetric 2x2 -- no iteration, no library, ~20 flops.
    let tr = sxx + syy
    let det = sxx * syy - sxy * sxy
    let disc = max(0, tr * tr / 4 - det)
    let l1 = tr / 2 + disc.squareRoot()            // larger
    // The major axis direction. When the cloud is near-circular the axes are
    // arbitrary, but so is the answer, and a mouth is never near-circular.
    var ax = 1.0, ay = 0.0
    if abs(sxy) > 1e-12 {
      ax = l1 - syy; ay = sxy
      let m = (ax * ax + ay * ay).squareRoot()
      if m > 1e-12 { ax /= m; ay /= m } else { ax = 1; ay = 0 }
    } else if syy > sxx {
      ax = 0; ay = 1
    }
    // Extents along both axes, from the actual points rather than from the
    // eigenvalues: a real extent is what a mouth opening is, and it is robust
    // to the handful of points a lip contour has.
    var majLo = Double.greatestFiniteMagnitude, majHi = -Double.greatestFiniteMagnitude
    var minLo = Double.greatestFiniteMagnitude, minHi = -Double.greatestFiniteMagnitude
    for p in pts {
      let dx = Double(p.x) - mx, dy = Double(p.y) - my
      let maj = dx * ax + dy * ay
      let mnr = -dx * ay + dy * ax                 // perpendicular
      majLo = min(majLo, maj); majHi = max(majHi, maj)
      minLo = min(minLo, mnr); minHi = max(minHi, mnr)
    }
    let width = majHi - majLo
    guard width > 1e-9 else { return nil }
    return (minHi - minLo) / width
  }

  /// What a beat reports. Zero looks means the detector never ran, which is a
  /// different thing from a detector that ran and saw nothing.
  var report: (looks: Int, faces: Int, moving: Int, still: Int, dropped: Int) {
    (looks, faces, movingSamples, stillSamples, dropped)
  }
}

// ── VALIDATING THE RULER, ON ANSWERS ALREADY KNOWN ───────────────────────────
//
// LAW in this project: calibrate a new measurement tool on known inputs,
// INCLUDING inputs it must reject. A visual voice detector has two ways to be
// useless and they look identical from a single number:
//
//   it says "moving" about everything  -> it is a light meter, not a mouth
//   it says "still" when it cannot see -> `blind-instruments-report-negatives`,
//      and every dark room becomes "this person is not talking"
//
// So three arms over real footage, and the threshold below is READ OFF this
// rather than guessed:
//
//   TALKING  a real downloaded talking head. Mostly `moving`.
//   STILL    one frame of that same face, held. Mostly `still` -- same face,
//            same lighting, same lens, so the only difference is motion.
//   BLIND    no face in frame. `unknown`, and NOT `still`.
//
// The still arm is cut from the talking arm on purpose: a synthetic still would
// differ in a dozen ways at once and prove nothing about which one mattered.
extension Mouth {

  /// One file, walked at the real sampling cadence, scored by the real aperture
  /// maths and the real threshold. What this does NOT cover is the async
  /// plumbing in `note` -- the rate limiter and the drop-if-in-flight -- which
  /// is stated rather than glossed: this rig answers whether the SIGNAL
  /// separates talking from still, not whether the queue hop is sound.
  static func scan(path: String, seconds: Double = 20) -> (frames: Int, faces: Int,
                                                           moving: Int, still: Int,
                                                           rates: [Double])? {
    // Each clip is its own discovery: the rotated arm must find its own
    // orientation rather than inherit the upright arm's.
    shared.forgetForTest()
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let reader = try? AVAssetReader(asset: asset),
          let track = asset.tracks(withMediaType: .video).first else { return nil }
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    ])
    out.alwaysCopiesSampleData = false
    reader.add(out)
    reader.startReading()

    var frames = 0, faces = 0, moving = 0, still = 0
    var rates: [Double] = []
    var lastAp = -1.0
    var rate = 0.0
    var movingUntilS = -1.0
    // The file is 30 fps and the detector looks at 12 Hz, so every third frame
    // -- the same spacing a live call gives it.
    let step = max(1, Int((30.0 / Mouth.hz).rounded()))
    var idx = 0
    while reader.status == .reading, let sb = out.copyNextSampleBuffer() {
      let tS = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
      if tS > seconds { break }
      idx += 1
      if idx % step != 0 { continue }
      guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
      frames += 1
      shared.looks += 1
      // THE SHARED DETECTOR, orientation search and all. An upright clip
      // latches `.up` on its first look at no cost, and a rotated one has to
      // find its own -- which is the arm that proves the search.
      guard let f = shared.detect(pb),
            let ap = aperture(f, imageSize: shared.lastScanSize) else {
        lastAp = -1                       // blind: the next sample re-baselines
        continue
      }
      faces += 1
      if lastAp >= 0 {
        let dtS = Double(step) / 30.0
        let r = abs(ap - lastAp) / dtS
        rate = rate * 0.5 + r * 0.5
        rates.append(rate)
        if rate >= moveThreshold { movingUntilS = tS }
        let held = movingUntilS >= 0 && (tS - movingUntilS) * 1000 <= hangoverMs
        if held { moving += 1 } else { still += 1 }
      }
      lastAp = ap
    }
    return (frames, faces, moving, still, rates)
  }

  static func selfTest(talking: String, stillPath: String, blind: String,
                       rotated: String? = nil) -> Bool {
    var ok = true
    func say(_ good: Bool, _ what: String) {
      if !good { ok = false }
      print("  \(good ? "ok  " : "FAIL") \(what)")
    }
    func pct(_ n: Int, _ d: Int) -> Double { d == 0 ? 0 : Double(n) * 100 / Double(d) }
    func p(_ v: [Double], _ q: Double) -> Double {
      guard !v.isEmpty else { return -1 }
      let s = v.sorted()
      return s[min(s.count - 1, max(0, Int(Double(s.count - 1) * q)))]
    }

    print("MOUTH TEST  \(Int(hz)) Hz, threshold \(String(format: "%.2f", moveThreshold)) aperture-ratio/s")

    guard let t = scan(path: talking) else {
      print("MOUTH TEST COULD NOT RUN -- no readable video at \(talking)"); return false
    }
    guard let s = scan(path: stillPath) else {
      print("MOUTH TEST COULD NOT RUN -- no readable video at \(stillPath)"); return false
    }
    guard let b = scan(path: blind) else {
      print("MOUTH TEST COULD NOT RUN -- no readable video at \(blind)"); return false
    }

    print(String(format: "  TALKING  %d samples, face in %.0f%%, moving %.0f%%  rate p10 %.2f p50 %.2f p90 %.2f",
                 t.frames, pct(t.faces, t.frames), pct(t.moving, t.moving + t.still),
                 p(t.rates, 0.1), p(t.rates, 0.5), p(t.rates, 0.9)))
    print(String(format: "  STILL    %d samples, face in %.0f%%, moving %.0f%%  rate p10 %.2f p50 %.2f p90 %.2f",
                 s.frames, pct(s.faces, s.frames), pct(s.moving, s.moving + s.still),
                 p(s.rates, 0.1), p(s.rates, 0.5), p(s.rates, 0.9)))
    print(String(format: "  BLIND    %d samples, face in %.0f%%",
                 b.frames, pct(b.faces, b.frames)))

    // ── AND THE NEIGHBOURS, SO THE CONSTANT IS NEVER FOLKLORE ───────────────
    //
    // `rig-picks-a-parameter-the-product-does-not`: the product picks one
    // threshold and a rig that only ever scores that one cannot say whether it
    // sits in the middle of a plateau or on the edge of a cliff. Same recorded
    // rates, re-scored at each candidate -- no second pass over the video, so
    // this costs nothing and there is no run-to-run variation to confuse it.
    func movingPct(_ rates: [Double], _ th: Double) -> Double {
      guard !rates.isEmpty else { return 0 }
      return Double(rates.filter { $0 >= th }.count) * 100 / Double(rates.count)
    }
    print("  sweep    threshold:  " + [0.05, 0.10, 0.15, 0.20, 0.30, 0.50].map {
      String(format: "%.2f", $0)
    }.joined(separator: "   "))
    print("           talking %:  " + [0.05, 0.10, 0.15, 0.20, 0.30, 0.50].map {
      String(format: "%4.0f  ", movingPct(t.rates, $0))
    }.joined(separator: " "))
    print("           still   %:  " + [0.05, 0.10, 0.15, 0.20, 0.30, 0.50].map {
      String(format: "%4.0f  ", movingPct(s.rates, $0))
    }.joined(separator: " "))

    // 1. IT CAN SEE A FACE AT ALL. Without this every other number is a
    //    statement about a detector that never ran.
    say(pct(t.faces, t.frames) > 80,
        String(format: "a face is found in %.0f%% of the talking clip", pct(t.faces, t.frames)))
    // 2. TALKING READS AS MOVING.
    say(pct(t.moving, t.moving + t.still) > 70,
        String(format: "talking reads as moving %.0f%% of the time", pct(t.moving, t.moving + t.still)))
    // 3. AND THE SAME FACE HELD STILL DOES NOT. This is the arm that makes 2
    //    mean anything: a detector that answers "moving" to any face passes 2.
    say(pct(s.moving, s.moving + s.still) < 20,
        String(format: "REJECT: the same face held still reads as moving only %.0f%%",
               pct(s.moving, s.moving + s.still)))
    // 4. THE TWO DISTRIBUTIONS ARE ACTUALLY APART, not merely either side of a
    //    threshold that happens to sit between two overlapping clouds.
    let sep = p(t.rates, 0.5) / max(0.001, p(s.rates, 0.9))
    say(sep > 2,
        String(format: "the distributions are %.1fx apart (talking p50 vs still p90)", sep))
    // 5. AND BLINDNESS IS BLINDNESS. No face must not be reported as a face
    //    that is not moving -- the whole point of the third state.
    say(pct(b.faces, b.frames) < 5,
        String(format: "REJECT: no face is found in the blind clip (%.0f%%), so it says unknown rather than still",
               pct(b.faces, b.frames)))

    // ── 6. THE ORIENTATION SEARCH, WHICH NOTHING ELSE HERE CAN PROVE ────────
    //
    // Vision must be told which way up a buffer is, a Mac camera does not
    // deliver `.up`, and a rig binary on this machine is refused the camera
    // outright (TCC binds the grant to code identity), so the live rotation is
    // untestable here. What IS testable is that the code does not depend on
    // knowing it: the same clip turned 90 degrees must still be found, by the
    // same search a real call runs.
    if let r = rotated, let rs = scan(path: r) {
      let orient = shared.orientName
      print(String(format: "  ROTATED  %d samples, face in %.0f%%, moving %.0f%%  (latched \"%@\")",
                   rs.frames, pct(rs.faces, rs.frames),
                   pct(rs.moving, rs.moving + rs.still), orient))
      say(pct(rs.faces, rs.frames) > 80,
          String(format: "the search finds the same face turned 90 degrees (%.0f%%, read as \"%@\")",
                 pct(rs.faces, rs.frames), orient))
      // ── WHAT THIS FILE ARM CAN AND CANNOT CONCLUDE ────────────────────────
      //
      // A rotated FILE is still found with `.up`, so on this evidence the
      // search looked like a mere safety net. A real Mac camera says otherwise:
      // on the shipped build, through LaunchServices, it logs
      //
      //     mouth: faces found with the camera read as leftMirrored
      //            -- latched after 2 looks
      //
      // Two looks means candidate one (`.up`) found NO FACE and `.leftMirrored`
      // did. So on real camera buffers the hint IS load-bearing, and the
      // conclusion this row used to draw -- "Vision needs no orientation hint"
      // -- was true of a 90-degree file rotation and false of the device. A
      // camera frame is rotated AND mirrored, which is not the transformation
      // this clip applies.
      //
      // Kept as the file-arm observation it honestly is, no longer generalised
      // to production. `no-camera-route-from-this-mac`: a rig binary here is
      // refused the sensor, so this is the boundary of what any local rig can
      // settle, and the real answer came from a live call's own log.
      say(orient == "up",
          "the file arm is found with no hint (a real CAMERA needs leftMirrored --"
          + " see the note: the search is load-bearing on a device)")
      let up = pct(t.moving, t.moving + t.still)
      let rot = pct(rs.moving, rs.moving + rs.still)
      say(abs(up - rot) <= 6,
          String(format: "the talking verdict is the SAME rotated as upright (%.0f%% vs %.0f%%)",
                 rot, up))
    } else if rotated != nil {
      say(false, "the rotated clip could not be read -- the search is unproven")
    }

    print(ok ? "MOUTH TEST PASSED -- a moving mouth is distinguishable from a still one, and from no mouth"
             : "MOUTH TEST FAILED")
    return ok
  }
}
