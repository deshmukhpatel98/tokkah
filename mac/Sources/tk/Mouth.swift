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
  /// `--no-mouth` is the control arm.
  nonisolated(unsafe) static var on = true

  /// How often frames are looked at. 12 Hz is three or four samples per
  /// syllable -- enough to see the rate of change -- at 40% of the cost of
  /// every frame. A call already spends ~0.16 CPU-s/s; this is not the place to
  /// spend the rest of it.
  static let hz: Double = 12
  /// Aperture change per second, in face-heights, above which the mouth is
  /// doing what speech does.
  ///
  /// MEASURED, and the first guess was wrong by 4x -- which is the entire
  /// reason `--mouth-test` exists. On real talking-head footage at 12 Hz:
  ///
  ///   talking   rate p10 0.04  p50 0.09  p90 0.19
  ///   same face p10 0.00  p50 0.01  p90 0.02      (one frame of it, held)
  ///
  /// A guessed 0.35 sat above the talking p90 and called a speaking face
  /// silent 100% of the time, while passing every other arm in the rig --
  /// `green-metrics-can-hide-defects` in one constant. 0.03 sits between the
  /// still p90 and the talking p10, and the rig sweeps neighbours on every run
  /// so the choice stays visible rather than becoming folklore.
  nonisolated(unsafe) static var moveThreshold: Double = 0.03
  /// Speech pauses between words and inside them, and a detector that drops on
  /// every closed consonant would flap. Held this long past the last sample
  /// that cleared the bar. Shorter than the audio VAD's 560 ms hangover on
  /// purpose: this signal only ever confirms, so a stale `true` is worth less
  /// than a late one.
  static let hangoverMs: Double = 250
  /// No face for this long and the detector says so rather than remembering.
  static let blindAfterMs: Double = 400

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

  private func look(_ pb: CVPixelBuffer, at t: UInt64) {
    defer { inFlight = false }
    looks += 1
    let req = VNDetectFaceLandmarksRequest()
    // `.leftMirrored` is what a Mac's front camera delivers to Vision for an
    // upright sitter. Getting this wrong does not fail loudly -- it finds
    // fewer faces -- which is why `faces` is counted and reported.
    let h = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .leftMirrored, options: [:])
    do { try h.perform([req]) } catch {
      Metrics.count("mouth_request_failed")
      return
    }
    // The LARGEST face, not the first. With two people in shot the one filling
    // the frame is the one holding this microphone.
    guard let f = (req.results ?? []).max(by: {
      $0.boundingBox.height * $0.boundingBox.width < $1.boundingBox.height * $1.boundingBox.width
    }) else {
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
    guard let ap = Mouth.aperture(f) else {
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

  /// Lip aperture in face-heights: the vertical extent of the inner lips,
  /// divided by the face's own bounding-box height.
  ///
  /// `normalizedPoints` are already relative to the bounding box, so the ratio
  /// is scale-free -- but the box is in IMAGE units and a 16:9 frame is not
  /// square, so the vertical extent is multiplied back by the box height to get
  /// a fraction of the face rather than a fraction of the frame.
  static func aperture(_ f: VNFaceObservation) -> Double? {
    guard let lips = f.landmarks?.innerLips ?? f.landmarks?.outerLips,
          lips.pointCount >= 4 else { return nil }
    let pts = lips.normalizedPoints
    var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
    for p in pts {
      let y = Double(p.y)
      if y < lo { lo = y }
      if y > hi { hi = y }
    }
    guard hi > lo else { return 0 }
    return hi - lo
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
      let req = VNDetectFaceLandmarksRequest()
      // UPRIGHT here, not `.leftMirrored`: a file already carries the
      // orientation a camera has to be told about. A rig that applied the
      // camera's rotation to a file would find no faces and report a detector
      // that cannot see -- measuring the harness.
      let h = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
      try? h.perform([req])
      guard let f = (req.results ?? []).max(by: {
              $0.boundingBox.height * $0.boundingBox.width < $1.boundingBox.height * $1.boundingBox.width
            }), let ap = aperture(f) else {
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

  static func selfTest(talking: String, stillPath: String, blind: String) -> Bool {
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

    print("MOUTH TEST  \(Int(hz)) Hz, threshold \(String(format: "%.2f", moveThreshold)) face-heights/s")

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
    print("  sweep    threshold:  " + [0.01, 0.02, 0.03, 0.05, 0.10, 0.20].map {
      String(format: "%.2f", $0)
    }.joined(separator: "   "))
    print("           talking %:  " + [0.01, 0.02, 0.03, 0.05, 0.10, 0.20].map {
      String(format: "%4.0f  ", movingPct(t.rates, $0))
    }.joined(separator: " "))
    print("           still   %:  " + [0.01, 0.02, 0.03, 0.05, 0.10, 0.20].map {
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

    print(ok ? "MOUTH TEST PASSED -- a moving mouth is distinguishable from a still one, and from no mouth"
             : "MOUTH TEST FAILED")
    return ok
  }
}
