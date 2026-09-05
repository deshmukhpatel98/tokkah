import Foundation
import Accelerate
import CoreAudio

// ── THE LAB THE CALLS RUN IN ─────────────────────────────────────────────────
//
// The owner's brief, 2026-09-05: "I just do the calls, and you look at the data
// and keep improving the product. I don't even have to tell you how the audio
// felt." Every number in this file exists to answer a question a LISTENER would
// answer -- what did I hear, what left my machine, did I hear myself -- per
// direction, from a real call, with nobody describing anything. `conceal_*`,
// `aec_*`, `floor_*` say what the machinery did; these say what a person got.
// The contract, units and the known inputs every ruler must pass (including the
// two it must reject) are in `mac/TELEMETRY-AUDIO.md`.
//
// THE ONE RULE: nothing here may cost the audio a microsecond it can hear. The
// capture and render threads increment counters, accumulate sums and memcpy into
// preallocated rings, single-writer, no locks, no allocation, no Foundation. The
// FFTs, the correlations and the percentiles run on one background thread at
// 1 Hz or on the reporter thread at beat time. A metric that adds latency is a
// worse product with better paperwork.
final class AudioLab {

  // ── 50 ms frames, the unit every level number is built from ────────────────
  //
  // The audio threads hand in blocks (16 samples on this machine, 128 under
  // VoiceProcessingIO, anything under load); the frame boundary is a SAMPLE
  // count, never a block count (`per-block-constants-hide-block-size`). A block
  // that straddles a frame is attributed whole to the frame in progress, which
  // makes frames 2400 ± one block long and changes no answer that matters.
  struct Frame {
    var postDb: Float   // level of what was played (rx) / what left (tx)
    var preDb: Float    // rx: same as post; tx: the microphone before the gate
    var voiced: Float   // share of the frame's samples the side called voice
    var silent: Float   // share that was DIGITAL silence (abs < 1e-5)
  }
  static let FRAME = 2400                     // 50 ms at 48 kHz
  final class FrameRing {
    static let CAP = 2048                     // 102 s; the beat reads every ~5 s
    let frames: UnsafeMutablePointer<Frame>
    nonisolated(unsafe) var w = 0             // monotonic; written by one audio thread
    private var n = 0
    private var sumPost: Double = 0, sumPre: Double = 0
    private var voicedN = 0, silentN = 0
    init() {
      frames = .allocate(capacity: FrameRing.CAP)
      frames.initialize(repeating: Frame(postDb: -120, preDb: -120, voiced: 0, silent: 0),
                        count: FrameRing.CAP)
    }
    @inline(__always) func addBlock(postSq: Double, preSq: Double, n bn: Int, voicedN vn: Int, silentN sn: Int) {
      sumPost += postSq; sumPre += preSq; n += bn; voicedN += vn; silentN += sn
      if n >= AudioLab.FRAME {
        let inv = 1.0 / Double(n)
        let post = 20 * log10((sumPost * inv).squareRoot() + 1e-9)
        let pre = 20 * log10((sumPre * inv).squareRoot() + 1e-9)
        frames[w & (FrameRing.CAP - 1)] = Frame(postDb: Float(post), preDb: Float(pre),
                                                voiced: Float(Double(voicedN) * inv),
                                                silent: Float(Double(silentN) * inv))
        w += 1
        n = 0; sumPost = 0; sumPre = 0; voicedN = 0; silentN = 0
      }
    }
  }
  let rx = FrameRing()
  let tx = FrameRing()

  // ── Counters. Single writer each (render thread for rx*, capture for tx*). ──
  nonisolated(unsafe) var rxVoiceS = 0            // far voice active at the speaker
  nonisolated(unsafe) var rxConcealVoicedS = 0    // concealed while it was
  nonisolated(unsafe) var rxConcealQuietS = 0     // concealed while it was not
  nonisolated(unsafe) var rxGlitches = 0          // seams a person would hear
  nonisolated(unsafe) var rxSilenceS = 0          // received digital silence
  nonisolated(unsafe) var rxClipS = 0             // received at or past full scale
  nonisolated(unsafe) var rxS = 0                 // received samples played
  nonisolated(unsafe) var rxSilentRun = 0
  nonisolated(unsafe) var rateFastS = 0           // governor above 1.004
  nonisolated(unsafe) var rateMaxDev: Double = 0
  nonisolated(unsafe) var txKneeS = 0             // entered the soft limiter's knee
  nonisolated(unsafe) var txS = 0                 // samples sent

  // ── Analysis rings: the last few seconds of four signals ───────────────────
  //
  // Written per sample by the audio threads, read in one-second slices by the
  // lab thread. Power-of-two so the index is a mask. The voiced flag rides in a
  // parallel byte ring, so the bandwidth ruler can pick segments that lie wholly
  // inside a voiced run -- a spectrum taken across a splice would report the
  // splice's own broadband splatter as bandwidth the voice never had.
  static let AN = 1 << 18                       // 262144 samples, 5.46 s
  static let AMASK = AN - 1
  let rxAn: UnsafeMutablePointer<Float>          // decoded far stream, before presence
  let rxAnV: UnsafeMutablePointer<UInt8>
  nonisolated(unsafe) var rxAnW = 0
  let txAn: UnsafeMutablePointer<Float>          // this microphone, before the gate
  let txAnV: UnsafeMutablePointer<UInt8>
  nonisolated(unsafe) var txAnW = 0
  let sentHist: UnsafeMutablePointer<Float>      // what left, after the gate
  nonisolated(unsafe) var sentW = 0

  /// Mouth-to-ear median, handed in by the reporter so the echo-return lag window
  /// can be aimed. 0 = unknown, and the window falls back to 20–600 ms.
  nonisolated(unsafe) var m2eMsHint: Double = 0

  // ── Results the lab thread publishes and the beat consumes ─────────────────
  private let lock = NSLock()
  private var rxBwWin: [Double] = []
  private var txBwWin: [Double] = []
  private var echoCorrWin: Double?
  private var echoDbWin: Double?
  private var echoLagWin: Double?
  private(set) var echoTalkS = 0
  private(set) var echoReturnS = 0
  private var rxRead = 0, txRead = 0             // frame ring read cursors (beat)
  private var running = false

  let tape = Tape()

  init() {
    rxAn = .allocate(capacity: AudioLab.AN); rxAn.initialize(repeating: 0, count: AudioLab.AN)
    rxAnV = .allocate(capacity: AudioLab.AN); rxAnV.initialize(repeating: 0, count: AudioLab.AN)
    txAn = .allocate(capacity: AudioLab.AN); txAn.initialize(repeating: 0, count: AudioLab.AN)
    txAnV = .allocate(capacity: AudioLab.AN); txAnV.initialize(repeating: 0, count: AudioLab.AN)
    sentHist = .allocate(capacity: AudioLab.AN); sentHist.initialize(repeating: 0, count: AudioLab.AN)
  }

  // ── Hooks: render thread ──────────────────────────────────────────────────

  /// One decoded sample that was PLAYED (the good path). `val` is the clean
  /// stream before presence; `emitted` is what left the speaker (for the tape).
  /// Returns whether the sample was digital silence, so the caller can count it
  /// into the frame without a second compare.
  @inline(__always) @discardableResult
  func rxPlayed(val: Float, emitted: Float) -> Bool {
    rxAn[rxAnW & AudioLab.AMASK] = val
    rxAnW += 1
    let a = abs(val)
    if a >= 0.997 { rxClipS += 1 }
    var silent = false
    if a < 1e-5 {
      silent = true
      rxSilentRun += 1
      if rxSilentRun > FPP { rxSilenceS += 1 }
    } else { rxSilentRun = 0 }
    rxS += 1
    tape.played(emitted)
    return silent
  }
  /// One concealed sample. Nothing was received, so it is not in the analysis
  /// ring, but the tape still carries what the speaker emitted.
  @inline(__always) func rxConcealed(emitted: Float) { tape.played(emitted) }
  /// Once per render callback: the block's far-voice state and its split.
  @inline(__always) func rxBlock(n: Int, playedN: Int, concealedN: Int, sumSq: Double,
                                 silentN: Int, farActive: Bool, rate: Double) {
    if farActive {
      rxVoiceS += n
      rxConcealVoicedS += concealedN
    } else {
      rxConcealQuietS += concealedN
    }
    // The voiced flag for the samples just written, so the ruler can trust it.
    if playedN > 0 {
      let v: UInt8 = farActive ? 1 : 0
      var i = rxAnW - playedN
      let end = rxAnW
      while i < end { rxAnV[i & AudioLab.AMASK] = v; i += 1 }
    }
    rx.addBlock(postSq: sumSq, preSq: sumSq, n: n, voicedN: farActive ? n : 0, silentN: silentN)
    let dev = abs(rate - 1.0)
    if dev > rateMaxDev { rateMaxDev = dev }
    if rate > 1.004 { rateFastS += n }
  }
  /// A seam has just been measured: the worst sample step within ±64 samples of
  /// it, against the level of the audio around it. A cross-faded return to real
  /// speech steps by almost nothing; a zero-fill steps by the whole waveform.
  @inline(__always) func seam(step: Float, rms: Float) {
    if step > max(0.01, 0.35 * rms) { rxGlitches += 1 }
  }

  // ── Hooks: capture thread ─────────────────────────────────────────────────

  /// The microphone's own envelope (35 ms release), for the bandwidth ruler's
  /// flag. Not the gate's verdict: the gate says "voice" for the loud cores of
  /// syllables, and a ruler fed only vowels reads a telephone band on a real
  /// voice -- measured live, 4.0 kHz on speech the whole-second ruler read at 9.
  /// The consonants carry the bandwidth, and this envelope keeps them.
  nonisolated(unsafe) var txEnv: Float = 0
  /// The block BEFORE the gate: the microphone as it would be sent if open.
  @inline(__always) func txPre(_ x: UnsafePointer<Float>, _ n: Int) -> Double {
    var sq: Double = 0
    var peak: Float = 0
    for k in 0..<n {
      let v = x[k]
      txAn[(txAnW + k) & AudioLab.AMASK] = v
      sq += Double(v) * Double(v)
      let a = abs(v); if a > peak { peak = a }
    }
    let decay = Float(exp(-Double(n) / SR / 0.035))
    txEnv = peak > txEnv ? peak : txEnv * decay
    let flag: UInt8 = txEnv > 0.004 ? 1 : 0
    for k in 0..<n { txAnV[(txAnW + k) & AudioLab.AMASK] = flag }
    txAnW += n
    return sq
  }
  /// The same block AFTER the gate, with the gate's verdict on it.
  @inline(__always) func txPost(_ x: UnsafePointer<Float>, _ n: Int, preSq: Double, voiced: Bool) {
    var sq: Double = 0
    var silent = 0
    for k in 0..<n {
      let v = x[k]
      sentHist[(sentW + k) & AudioLab.AMASK] = v
      sq += Double(v) * Double(v)
      if abs(v) < 1e-5 { silent += 1 }
    }
    sentW += n
    tx.addBlock(postSq: sq, preSq: preSq, n: n, voicedN: voiced ? n : 0, silentN: silent)
  }
  /// One packet is leaving. `knee` samples of it were past 0.80 on the way into
  /// the soft limiter, which is where a voice starts to bend.
  @inline(__always) func txPacket(knee: Int) { txKneeS += knee; txS += FPP }

  // ── The lab thread: one second at a time ───────────────────────────────────

  func start() {
    guard !running else { return }
    running = true
    let t = Thread { [weak self] in
      guard let self else { return }
      while true {
        Thread.sleep(forTimeInterval: 1.0)
        self.tick()
      }
    }
    t.qualityOfService = .utility
    t.start()
  }

  private var anBuf = [Float](repeating: 0, count: 48000)
  private var anFlag = [UInt8](repeating: 0, count: 48000)
  private var sentBuf = [Float](repeating: 0, count: 6000)
  private var recvBuf = [Float](repeating: 0, count: 6000 + 9000)

  private func tick() {
    // Bandwidth of what was heard and of what this microphone picks up, on the
    // last second, only across samples the side called voice.
    if let bw = bandwidthOfRing(rxAn, rxAnV, rxAnW) { lock.lock(); rxBwWin.append(bw); lock.unlock() }
    if let bw = bandwidthOfRing(txAn, txAnV, txAnW) { lock.lock(); txBwWin.append(bw); lock.unlock() }
    echoTick()
  }

  private func bandwidthOfRing(_ ring: UnsafeMutablePointer<Float>, _ flags: UnsafeMutablePointer<UInt8>, _ w: Int) -> Double? {
    guard w > 48000 else { return nil }
    let start = w - 48000
    for i in 0..<48000 {
      anBuf[i] = ring[(start + i) & AudioLab.AMASK]
      anFlag[i] = flags[(start + i) & AudioLab.AMASK]
    }
    return AudioLab.bandwidthKHz(anBuf, voiced: anFlag)
  }

  private func echoTick() {
    // The window the sent voice is taken from ends Lmax ago, so that every lag up
    // to Lmax has its return already inside the received history.
    let m2e = m2eMsHint
    var lagMinMs = 20.0, lagMaxMs = 600.0
    if m2e > 0 {
      lagMinMs = max(20, 1.2 * m2e + 10)
      lagMaxMs = min(1500, 3.0 * m2e + 150)
    }
    let D = 8
    let W = 6000                                  // 1 s at 6 kHz
    let lagMin = Int(lagMinMs / 1000.0 * SR) / D
    let lagMax = Int(lagMaxMs / 1000.0 * SR) / D
    guard lagMax > lagMin, lagMax <= 9000 else { return }
    let sW = sentW, rW = rxAnW
    let needS = (W + lagMax) * D
    guard sW > needS + 4096, rW > needS + 4096 else { return }
    // sent: (now - Lmax - W, now - Lmax];  recv: (now - Lmax - W, now]
    let sBase = sW - (W + lagMax) * D
    for i in 0..<W {
      var a: Float = 0
      for j in 0..<D { a += sentHist[(sBase + i * D + j) & AudioLab.AMASK] }
      sentBuf[i] = a / Float(D)
    }
    let rBase = rW - (W + lagMax) * D
    let RN = W + lagMax
    for i in 0..<RN {
      var a: Float = 0
      for j in 0..<D { a += rxAn[(rBase + i * D + j) & AudioLab.AMASK] }
      recvBuf[i] = a / Float(D)
    }
    var sE: Float = 0
    vDSP_svesq(sentBuf, 1, &sE, vDSP_Length(W))
    let sRms = (sE / Float(W)).squareRoot()
    guard sRms > 0.0056 else { return }          // -45 dBFS: this end was not talking
    lock.lock(); echoTalkS += 1; lock.unlock()
    guard let r = AudioLab.echoReturn(sent: Array(sentBuf[0..<W]), recv: Array(recvBuf[0..<RN]),
                                      lagMin: lagMin, lagMax: lagMax) else { return }
    lock.lock()
    echoCorrWin = max(echoCorrWin ?? 0, r.corr)
    if r.corr >= AudioLab.RETURN_CORR {
      echoReturnS += 1
      if echoDbWin == nil || r.corr >= (echoCorrWin ?? 0) {
        echoDbWin = r.gainDb
        echoLagWin = Double(r.lag * D) / SR * 1000.0
      }
    }
    lock.unlock()
  }

  // ── The rulers, pure functions so the selftest measures the same code ─────

  /// Bandwidth of a voice, in kHz, from up to one second of 48 kHz audio and a
  /// per-sample voiced flag. Hann 2048 at 50% overlap over segments that lie
  /// wholly inside voiced runs; 1/6-octave bands from 100 Hz; the highest band
  /// still within 40 dB of the voice's own 300–3000 Hz core. Returns nil when
  /// there is nothing to measure -- a number for silence would be a lie with a
  /// unit. Calibrated in `selftest` on real speech untouched, low-passed at 7 and
  /// 3.4 kHz, white noise, silence, and too little voice.
  static func bandwidthKHz(_ x: [Float], voiced: [UInt8]? = nil) -> Double? {
    let N = 2048, hop = 1024
    guard x.count >= N else { return nil }
    // At least 300 ms of the window must be voice, whatever the segments say:
    // half-voiced segments around a 170 ms burst would otherwise make six.
    if let v = voiced {
      var on = 0
      for f in v where f != 0 { on += 1 }
      guard on >= 14400 else { return nil }
    }
    let log2n = vDSP_Length(11)
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
    defer { vDSP_destroy_fftsetup(setup) }
    var window = [Float](repeating: 0, count: N)
    vDSP_hann_window(&window, vDSP_Length(N), Int32(vDSP_HANN_NORM))
    var re = [Float](repeating: 0, count: N / 2), im = [Float](repeating: 0, count: N / 2)
    var seg = [Float](repeating: 0, count: N)
    var power = [Double](repeating: 0, count: N / 2)
    var segs = 0
    var pos = 0
    while pos + N <= x.count {
      // A segment counts if at least half of it is inside the voice's envelope.
      // Requiring the whole segment kept only the loud cores of syllables, and
      // vowels alone read as a 4 kHz voice; the consonant tails are where the
      // bandwidth lives. Half, not less: the quiet half of a segment is the same
      // voice trailing off, not the room.
      var ok = true
      if let v = voiced {
        var on = 0
        var i = pos
        while i < pos + N { if v[i] != 0 { on += 1 }; i += 1 }
        ok = on * 2 >= N
      }
      if ok {
        vDSP_vmul(Array(x[pos..<pos + N]), 1, window, 1, &seg, 1, vDSP_Length(N))
        re.withUnsafeMutableBufferPointer { rp in
          im.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            seg.withUnsafeBufferPointer { sp in
              sp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: N / 2) { cp in
                vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(N / 2))
              }
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
          }
        }
        for k in 1..<(N / 2) { power[k] += Double(re[k] * re[k] + im[k] * im[k]) }
        segs += 1
      }
      pos += hop
    }
    guard segs >= 6 else { return nil }          // under 300 ms of usable voice
    var total: Double = 0
    for k in 1..<(N / 2) { total += power[k] }
    guard total / Double(segs) > 1e-6 else { return nil }   // digital silence
    // 1/6-octave bands from 100 Hz up to the last one that fits under Nyquist.
    let binHz = SR / Double(N)
    var centres: [Double] = [], bandPow: [Double] = []
    var k = 0
    while true {
      let fc = 100.0 * pow(2.0, Double(k) / 6.0)
      let lo = fc / pow(2.0, 1.0 / 12.0), hi = fc * pow(2.0, 1.0 / 12.0)
      if hi >= SR / 2 { break }
      let b0 = max(1, Int(lo / binHz)), b1 = min(N / 2 - 1, Int(hi / binHz))
      if b1 >= b0 {
        var s: Double = 0
        for b in b0...b1 { s += power[b] }
        centres.append(fc); bandPow.append(s / Double(b1 - b0 + 1))
      }
      k += 1
    }
    guard !centres.isEmpty else { return nil }
    var coreSum: Double = 0; var coreN = 0
    for (i, fc) in centres.enumerated() where fc >= 300 && fc <= 3000 {
      coreSum += bandPow[i]; coreN += 1
    }
    guard coreN > 0 else { return nil }
    let core = coreSum / Double(coreN)
    // Forty decibels under the voice's own core, and nothing else. The first
    // version also admitted any band 15 dB above the QUIETEST band, and on a
    // 3.4 kHz low-passed voice the quietest band was the filter's -90 dB stopband
    // at 20 kHz -- so the -60 dB transition residue at 5 kHz "cleared the floor"
    // and the ruler read 5.1 kHz for a telephone band. Inaudible energy is not
    // bandwidth; the ear judges against the voice, and so does this.
    let thresh = core * pow(10, -4.0)
    var i = centres.count - 1
    while i >= 0 {
      if bandPow[i] >= thresh { return centres[i] / 1000.0 }
      i -= 1
    }
    return nil
  }

  /// A return is detected at this normalised correlation. 0.20, not 0.30: a
  /// -10 dB copy of my voice under an equal-level far voice can only ever reach
  /// about 0.29 (sqrt of 0.09 / 1.09), which is the ordinary double-talk case, and
  /// the null -- an unrelated voice, the best of 9000 lags over one second -- was
  /// measured at 0.06. Three times the null and under the weakest real case.
  static let RETURN_CORR = 0.20

  /// My voice, returning. `sent` is W samples at 6 kHz; `recv` is W + lagMax
  /// samples ending now, so the return of sent[i] at lag L is recv[i + L].
  /// Normalised cross-correlation over the lag window; the regression gain at
  /// the peak is how loud the returning copy is relative to the voice that left.
  static func echoReturn(sent: [Float], recv: [Float], lagMin: Int, lagMax: Int)
    -> (corr: Double, gainDb: Double, lag: Int)? {
    let W = sent.count
    guard W > 0, recv.count >= W + lagMax, lagMax >= lagMin, lagMin >= 0 else { return nil }
    let L = lagMax + 1
    var num = [Float](repeating: 0, count: L)
    vDSP_conv(recv, 1, sent, 1, &num, 1, vDSP_Length(L), vDSP_Length(W))
    var sE: Float = 0
    vDSP_svesq(sent, 1, &sE, vDSP_Length(W))
    guard sE > 0 else { return nil }
    // Sliding energy of recv over a W-long window, via a prefix sum.
    var sq = [Float](repeating: 0, count: recv.count)
    vDSP_vsq(recv, 1, &sq, 1, vDSP_Length(recv.count))
    var prefix = [Double](repeating: 0, count: recv.count + 1)
    for i in 0..<recv.count { prefix[i + 1] = prefix[i] + Double(sq[i]) }
    var best = -1.0, bestLag = lagMin
    for lag in lagMin...lagMax {
      let rE = prefix[lag + W] - prefix[lag]
      guard rE > 1e-12 else { continue }
      let c = Double(num[lag]) / (Double(sE) * rE).squareRoot()
      if c > best { best = c; bestLag = lag }
    }
    guard best >= 0 else { return nil }
    let gain = Double(num[bestLag]) / Double(sE)
    let gainDb = 20 * log10(max(abs(gain), 1e-9))
    return (best, gainDb, bestLag)
  }

  // ── The beat ──────────────────────────────────────────────────────────────

  private static func pct(_ v: [Double], _ q: Double) -> Double {
    let s = v.sorted()
    let i = min(s.count - 1, max(0, Int(Double(s.count - 1) * q + 0.5)))
    return s[i]
  }

  /// Frames written since the last beat, oldest first. If the beat fell more
  /// than the ring behind, the oldest are gone and only the newest CAP are read.
  private func drain(_ r: FrameRing, _ cursor: inout Int) -> [Frame] {
    let w = r.w
    var from = cursor
    if w - from > FrameRing.CAP { from = w - FrameRing.CAP }
    var out: [Frame] = []
    out.reserveCapacity(w - from)
    var i = from
    while i < w { out.append(r.frames[i & (FrameRing.CAP - 1)]); i += 1 }
    cursor = w
    return out
  }

  /// Level statistics of a run of frames: (p50, p90, swing, noise).
  private static func levels(_ fr: [Frame], noiseFrom pre: Bool) -> (p50: Double?, p90: Double?, swing: Double?, noise: Double?) {
    let voiced = fr.filter { $0.voiced >= 0.5 }.map { Double($0.postDb) }
    var p50: Double?, p90: Double?
    if voiced.count >= 6 { p50 = pct(voiced, 0.5); p90 = pct(voiced, 0.9) }
    let quiet = fr.filter { $0.voiced < 0.5 && $0.silent < 0.5 }.map { Double(pre ? $0.preDb : $0.postDb) }
    let noise: Double? = quiet.count >= 6 ? pct(quiet, 0.1) : nil
    // Adjacent one-second means of the voiced frames, needing at least half a
    // second of voice in each second to count.
    var swing: Double?
    var secMeans: [Double] = []
    var i = 0
    while i + 20 <= fr.count {
      let v = fr[i..<i + 20].filter { $0.voiced >= 0.5 }.map { Double($0.postDb) }
      if v.count >= 10 { secMeans.append(v.reduce(0, +) / Double(v.count)) } else { secMeans.append(.nan) }
      i += 20
    }
    for j in 1..<max(1, secMeans.count) {
      let a = secMeans[j - 1], b = secMeans[j]
      if a.isFinite && b.isFinite { swing = max(swing ?? 0, abs(b - a)) }
    }
    return (p50, p90, swing, noise)
  }

  /// Everything the contract lists, into the beat. Cumulative fields always;
  /// window fields only when the window had something to measure.
  func beatFields(into f: inout [String: Any], txVoiceS: Int, txVoiceMutedS: Int, m2eP50: Double?) {
    if let m = m2eP50 { m2eMsHint = m }
    let ms = 1000.0 / SR
    f["a_rx_voice_ms"] = Double(rxVoiceS) * ms
    f["a_rx_conceal_voiced_ms"] = Double(rxConcealVoicedS) * ms
    f["a_rx_conceal_quiet_ms"] = Double(rxConcealQuietS) * ms
    f["a_rx_glitches"] = rxGlitches
    f["a_rx_silence_ms"] = Double(rxSilenceS) * ms
    f["a_rx_clip_pct"] = rxS > 0 ? Double(rxClipS) * 100.0 / Double(rxS) : 0
    f["a_rate_fast_ms"] = Double(rateFastS) * ms
    f["a_rate_max_pct"] = rateMaxDev * 100.0
    f["a_tx_voice_ms"] = Double(txVoiceS) * ms
    f["a_tx_voice_muted_ms"] = Double(txVoiceMutedS) * ms
    f["a_tx_softlimit_pct"] = txS > 0 ? Double(txKneeS) * 100.0 / Double(txS) : 0

    let rxF = drain(rx, &rxRead)
    let l = AudioLab.levels(rxF, noiseFrom: false)
    if let v = l.p50 { f["a_rx_level_db_p50"] = v }
    if let v = l.p90 { f["a_rx_level_db_p90"] = v }
    if let v = l.swing { f["a_rx_level_swing_db"] = v }
    if let v = l.noise { f["a_rx_noise_db"] = v }
    let txF = drain(tx, &txRead)
    let t = AudioLab.levels(txF, noiseFrom: true)
    if let v = t.p50 { f["a_tx_level_db_p50"] = v }
    if let v = t.noise { f["a_tx_noise_db"] = v }
    if let p = t.p50, let n = t.noise { f["a_tx_snr_db"] = p - n }

    lock.lock()
    if !rxBwWin.isEmpty { f["a_rx_bw_khz"] = AudioLab.pct(rxBwWin, 0.5); rxBwWin.removeAll(keepingCapacity: true) }
    if !txBwWin.isEmpty { f["a_tx_bw_khz"] = AudioLab.pct(txBwWin, 0.5); txBwWin.removeAll(keepingCapacity: true) }
    f["a_echo_talk_s"] = echoTalkS
    f["a_echo_return_s"] = echoReturnS
    if let c = echoCorrWin { f["a_echo_return_corr"] = c }
    if let d = echoDbWin { f["a_echo_return_db"] = d }
    if let lg = echoLagWin { f["a_echo_return_lag_ms"] = lg }
    echoCorrWin = nil; echoDbWin = nil; echoLagWin = nil
    lock.unlock()

    f["tape_bytes"] = tape.bytes
    f["tape_full"] = tape.anyFull ? 1 : 0
  }

  // ── What it was running on ────────────────────────────────────────────────

  static func transportName(_ t: UInt32) -> String {
    switch t {
    case kAudioDeviceTransportTypeBuiltIn: return "builtin"
    case kAudioDeviceTransportTypeUSB: return "usb"
    case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
    case kAudioDeviceTransportTypeHDMI: return "hdmi"
    case kAudioDeviceTransportTypeDisplayPort: return "displayport"
    case kAudioDeviceTransportTypeAggregate: return "aggregate"
    case kAudioDeviceTransportTypeVirtual: return "virtual"
    case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
    case kAudioDeviceTransportTypeAirPlay: return "airplay"
    case kAudioDeviceTransportTypePCI: return "pci"
    case kAudioDeviceTransportTypeFireWire: return "firewire"
    default: return "other:" + String(t, radix: 16)
    }
  }

  struct DeviceFacts { var name: String; var transport: String; var rate: Double; var channels: Int; var rates: [Int] }

  /// Read what a device IS, so a bad-sounding call can be explained by the thing
  /// it ran on rather than guessed at. Called at start, off the audio thread.
  static func deviceFacts(_ dev: AudioDeviceID, input: Bool) -> DeviceFacts {
    var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var name = "?"
    var nameRef: CFString? = nil; var sz = UInt32(MemoryLayout<CFString?>.size)
    if AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &nameRef) == noErr, let n = nameRef { name = n as String }
    var t = UInt32(0); sz = 4
    a.mSelector = kAudioDevicePropertyTransportType
    let transport = AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &t) == noErr ? transportName(t) : "?"
    var rate: Float64 = 0; sz = UInt32(MemoryLayout<Float64>.size)
    a.mSelector = kAudioDevicePropertyNominalSampleRate
    AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &rate)
    // Channels in the device's own stream layout, on the side it is used for.
    var channels = 0
    a.mSelector = kAudioDevicePropertyStreamConfiguration
    a.mScope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    sz = 0
    if AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &sz) == noErr, sz > 0 {
      let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: 16)
      defer { raw.deallocate() }
      if AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, raw) == noErr {
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        for b in abl { channels += Int(b.mNumberChannels) }
      }
    }
    var rates: [Int] = []
    a.mSelector = kAudioDevicePropertyAvailableNominalSampleRates
    a.mScope = kAudioObjectPropertyScopeGlobal
    sz = 0
    if AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &sz) == noErr, sz > 0 {
      let n = Int(sz) / MemoryLayout<AudioValueRange>.size
      var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: n)
      if AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &ranges) == noErr {
        for r in ranges { let v = Int(r.mMinimum); if !rates.contains(v) { rates.append(v) } }
        rates.sort()
      }
    }
    return DeviceFacts(name: name, transport: transport, rate: rate, channels: channels, rates: rates)
  }

  /// Record both devices as facts, and the one verdict that has ruined more
  /// listening tests here than anything else: a Bluetooth headset in phone mode.
  static func recordDeviceFacts(inDev: AudioDeviceID, outDev: AudioDeviceID) -> (DeviceFacts, DeviceFacts) {
    let i = deviceFacts(inDev, input: true), o = deviceFacts(outDev, input: false)
    Metrics.fact("in_dev", i.name); Metrics.fact("in_transport", i.transport)
    Metrics.fact("in_rate_hw", String(Int(i.rate))); Metrics.fact("in_ch", String(i.channels))
    Metrics.fact("in_rates", i.rates.map(String.init).joined(separator: ","))
    Metrics.fact("out_dev", o.name); Metrics.fact("out_transport", o.transport)
    Metrics.fact("out_rate_hw", String(Int(o.rate))); Metrics.fact("out_ch", String(o.channels))
    func hfp(_ d: DeviceFacts) -> Bool {
      d.transport.hasPrefix("bluetooth") && (d.channels == 1 || (d.rate > 0 && d.rate <= 16000))
    }
    Metrics.fact("bt_hfp", (hfp(i) || hfp(o)) ? "yes" : "no")
    return (i, o)
  }

  // ── Tapes: the audio itself, on the lab machines ──────────────────────────
  //
  // Numbers answer the questions somebody thought to ask. When lab mode is on,
  // three streams and two timelines are written to disk so any question can be
  // answered afterwards: the microphone as heard, what left for the wire, what
  // left the speaker, where every concealed sample fell and what the gate did to
  // every packet. Nothing is uploaded, ever. Only a machine whose owner turned
  // lab mode on (or whose install the owner's server lists) writes them.
  final class Tape {
    static let CAP = 1 << 18                   // 5.46 s of samples per stream
    static let RCAP = 1 << 14                  // 16384 render records, 5.5 s
    static let CCAP = 1 << 13                  // 8192 capture records, 5.5 s
    static let REC = 32
    let rawRing: UnsafeMutablePointer<Float>
    let sentRing: UnsafeMutablePointer<Int16>
    let playedRing: UnsafeMutablePointer<Int16>
    let renderRec: UnsafeMutableRawPointer
    let capRec: UnsafeMutableRawPointer
    nonisolated(unsafe) var rawW = 0, sentW = 0, playedW = 0, renderW = 0, capW = 0
    nonisolated(unsafe) var on = false          // read by the audio threads; set before start
    nonisolated(unsafe) var rawFull = false, sentFull = false, playedFull = false, renderFull = false, capFull = false
    nonisolated(unsafe) var bytes = 0
    var anyFull: Bool { rawFull || sentFull || playedFull || renderFull || capFull }
    private var dir: URL?
    private var files: [String: FileHandle] = [:]
    private var flushed = (raw: 0, sent: 0, played: 0, render: 0, cap: 0)
    private var written = (raw: 0, sent: 0, played: 0, render: 0, cap: 0)
    private var stopping = false
    private var finished = false
    private var startedAt = Date()
    private var startHost: UInt64 = 0
    private let ioLock = NSLock()
    static let MAX_SECONDS = 3600.0

    init() {
      rawRing = .allocate(capacity: Tape.CAP); rawRing.initialize(repeating: 0, count: Tape.CAP)
      sentRing = .allocate(capacity: Tape.CAP); sentRing.initialize(repeating: 0, count: Tape.CAP)
      playedRing = .allocate(capacity: Tape.CAP); playedRing.initialize(repeating: 0, count: Tape.CAP)
      renderRec = .allocate(byteCount: Tape.RCAP * Tape.REC, alignment: 16)
      renderRec.initializeMemory(as: UInt8.self, repeating: 0, count: Tape.RCAP * Tape.REC)
      capRec = .allocate(byteCount: Tape.CCAP * Tape.REC, alignment: 16)
      capRec.initializeMemory(as: UInt8.self, repeating: 0, count: Tape.CCAP * Tape.REC)
    }

    // Writers. Each is one store and one increment; the ring never blocks. A
    // stream whose reader fell a whole ring behind is stopped by the READER --
    // the writer cannot know, and must not check.
    @inline(__always) func raw(_ x: UnsafePointer<Float>, _ n: Int) {
      guard on, !rawFull else { return }
      for k in 0..<n { rawRing[(rawW + k) & (Tape.CAP - 1)] = x[k] }
      rawW += n
    }
    @inline(__always) func sent(_ q: Int16) {
      guard on, !sentFull else { return }
      sentRing[sentW & (Tape.CAP - 1)] = q; sentW += 1
    }
    @inline(__always) func played(_ v: Float) {
      guard on, !playedFull else { return }
      let c = max(-1.0, min(1.0, v))
      playedRing[playedW & (Tape.CAP - 1)] = Int16(c * 32767.0); playedW += 1
    }
    @inline(__always) func render(hostNs: UInt64, pos: Double, n: Int, concealed: Int, rate: Double, ear: Float) {
      guard on, !renderFull else { return }
      let p = renderRec + (renderW & (Tape.RCAP - 1)) * Tape.REC
      p.storeBytes(of: hostNs.littleEndian, toByteOffset: 0, as: UInt64.self)
      p.storeBytes(of: pos.bitPattern.littleEndian, toByteOffset: 8, as: UInt64.self)
      p.storeBytes(of: UInt16(min(n, 65535)).littleEndian, toByteOffset: 16, as: UInt16.self)
      p.storeBytes(of: UInt16(min(concealed, 65535)).littleEndian, toByteOffset: 18, as: UInt16.self)
      p.storeBytes(of: Float(rate).bitPattern.littleEndian, toByteOffset: 20, as: UInt32.self)
      p.storeBytes(of: ear.bitPattern.littleEndian, toByteOffset: 24, as: UInt32.self)
      p.storeBytes(of: UInt32(0), toByteOffset: 28, as: UInt32.self)
      renderW += 1
    }
    @inline(__always) func capture(seq: Int32, hostNs: UInt64, gain: Float, muted: Bool, voiced: Bool) {
      guard on, !capFull else { return }
      let p = capRec + (capW & (Tape.CCAP - 1)) * Tape.REC
      p.storeBytes(of: seq.littleEndian, toByteOffset: 0, as: Int32.self)
      p.storeBytes(of: hostNs.littleEndian, toByteOffset: 4, as: UInt64.self)
      p.storeBytes(of: gain.bitPattern.littleEndian, toByteOffset: 12, as: UInt32.self)
      p.storeBytes(of: UInt8(muted ? 1 : 0), toByteOffset: 16, as: UInt8.self)
      p.storeBytes(of: UInt8(voiced ? 1 : 0), toByteOffset: 17, as: UInt8.self)
      p.storeBytes(of: UInt16(0), toByteOffset: 18, as: UInt16.self)
      p.storeBytes(of: UInt64(0), toByteOffset: 20, as: UInt64.self)
      p.storeBytes(of: UInt32(0), toByteOffset: 28, as: UInt32.self)
      capW += 1
    }

    var dirPath: String? { dir?.path }
    /// The selftest's own directory, set in-process because the environment is
    /// read once at launch and cannot be trusted to change under a running test.
    nonisolated(unsafe) static var baseOverride: URL?
    static func baseDir() -> URL {
      if let o = baseOverride { return o }
      if let d = ProcessInfo.processInfo.environment["TK_TAPES_DIR"] {
        return URL(fileURLWithPath: d, isDirectory: true)
      }
      return Watch.logDir().appendingPathComponent("tapes", isDirectory: true)
    }

    /// Keep the newest `keep - 1` tape directories (the new one makes `keep`) and
    /// no more than `maxBytes` in total; oldest go first.
    static func prune(_ base: URL, keep: Int = 3, maxBytes: Int = 3 << 30) -> Int {
      let fm = FileManager.default
      guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return 0 }
      func size(_ u: URL) -> Int {
        (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.fileSizeKey]))?
          .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } ?? 0
      }
      var dirs = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
      dirs.sort { (a, b) in
        let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return da > db
      }
      var removed = 0
      var total = 0
      for (i, d) in dirs.enumerated() {
        total += size(d)
        if i >= keep - 1 || total > maxBytes {
          try? fm.removeItem(at: d); removed += 1
        }
      }
      return removed
    }

    private static func wavHeader(float: Bool, dataBytes: UInt32) -> Data {
      var d = Data()
      func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
      func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
      d.append("RIFF".data(using: .ascii)!)
      u32(4 + (8 + 18) + (8 + dataBytes))
      d.append("WAVE".data(using: .ascii)!)
      d.append("fmt ".data(using: .ascii)!)
      u32(18)
      u16(float ? 3 : 1)                        // IEEE float / PCM
      u16(1)                                    // mono
      u32(UInt32(SR))
      let bps: UInt32 = float ? 4 : 2
      u32(UInt32(SR) * bps)
      u16(UInt16(bps))
      u16(UInt16(bps * 8))
      u16(0)                                    // cbSize
      d.append("data".data(using: .ascii)!)
      u32(dataBytes)
      return d
    }

    /// Open the files and start the drain. Called once, before the units start,
    /// off the audio thread. Returns the directory or the reason there is none.
    func start(callId: String, facts: [String: String]) -> String {
      let base = Tape.baseDir()
      let fm = FileManager.default
      try? fm.createDirectory(at: base, withIntermediateDirectories: true)
      let pruned = Tape.prune(base)
      let d = base.appendingPathComponent(callId, isDirectory: true)
      do { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
      catch { return "tapes: cannot create \(d.path): \(error.localizedDescription)" }
      dir = d
      for (name, float) in [("raw.wav", true), ("sent.wav", false), ("played.wav", false)] {
        let u = d.appendingPathComponent(name)
        fm.createFile(atPath: u.path, contents: Tape.wavHeader(float: float, dataBytes: 0))
        guard let h = FileHandle(forWritingAtPath: u.path) else { return "tapes: cannot open \(u.path)" }
        h.seekToEndOfFile()
        files[name] = h
      }
      for name in ["render.bin", "capture.bin"] {
        let u = d.appendingPathComponent(name)
        fm.createFile(atPath: u.path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: u.path) else { return "tapes: cannot open \(u.path)" }
        files[name] = h
      }
      startedAt = Date()
      startHost = Clock.now()
      writeMeta(callId: callId, facts: facts, final: false)
      on = true
      let t = Thread { [weak self] in
        guard let self else { return }
        while true {
          Thread.sleep(forTimeInterval: 0.25)
          self.ioLock.lock()
          let stop = self.stopping
          if !stop { self.drain() }
          self.ioLock.unlock()
          if stop { return }
          if Date().timeIntervalSince(self.startedAt) > Tape.MAX_SECONDS { self.on = false }
        }
      }
      t.qualityOfService = .utility
      t.start()
      return "tapes: recording to \(d.path)" + (pruned > 0 ? " (pruned \(pruned) older)" : "")
    }

    private func drain() {
      // Snapshot the writers' indices once; anything they add after this is next time's.
      let rw = rawW, sw = sentW, pw = playedW, rr = renderW, cw = capW
      func drainSamples<T>(_ ring: UnsafeMutablePointer<T>, cap: Int, w: Int, flushed: inout Int, written: inout Int,
                           full: inout Bool, file: FileHandle?) {
        guard let fh = file, !full else { return }
        if w - flushed > cap {
          // The reader fell a whole ring behind, so what is left is overwritten
          // audio from two different moments. Stop and say so; never splice.
          full = true
          return
        }
        var i = flushed
        while i < w {
          let slot = i & (cap - 1)
          let run = min(w - i, cap - slot)
          let data = Data(bytes: UnsafeRawPointer(ring + slot), count: run * MemoryLayout<T>.stride)
          fh.write(data)
          written += run
          bytes += data.count
          i += run
        }
        flushed = w
      }
      func drainRecords(_ mem: UnsafeMutableRawPointer, cap: Int, w: Int, flushed: inout Int, written: inout Int,
                        full: inout Bool, file: FileHandle?) {
        guard let fh = file, !full else { return }
        if w - flushed > cap { full = true; return }
        var i = flushed
        while i < w {
          let slot = i & (cap - 1)
          let run = min(w - i, cap - slot)
          let data = Data(bytes: mem + slot * Tape.REC, count: run * Tape.REC)
          fh.write(data)
          written += run
          bytes += data.count
          i += run
        }
        flushed = w
      }
      drainSamples(rawRing, cap: Tape.CAP, w: rw, flushed: &flushed.raw, written: &written.raw, full: &rawFull, file: files["raw.wav"])
      drainSamples(sentRing, cap: Tape.CAP, w: sw, flushed: &flushed.sent, written: &written.sent, full: &sentFull, file: files["sent.wav"])
      drainSamples(playedRing, cap: Tape.CAP, w: pw, flushed: &flushed.played, written: &written.played, full: &playedFull, file: files["played.wav"])
      drainRecords(renderRec, cap: Tape.RCAP, w: rr, flushed: &flushed.render, written: &written.render, full: &renderFull, file: files["render.bin"])
      drainRecords(capRec, cap: Tape.CCAP, w: cw, flushed: &flushed.cap, written: &written.cap, full: &capFull, file: files["capture.bin"])
    }

    private func writeMeta(callId: String, facts: [String: String], final: Bool) {
      guard let d = dir else { return }
      var m: [String: Any] = [
        "call": callId, "install": Telemetry.install, "version": VERSION,
        "sr": Int(SR), "fpp": FPP,
        "started_wall": ISO8601DateFormatter().string(from: startedAt),
        "start_host_ns": Clock.ns(startHost),
        "facts": facts,
        "record_formats": [
          "render.bin": "32 B LE: u64 host_ns, f64 ring_pos, u16 n, u16 concealed_n, f32 rate, f32 ear_gain, pad4",
          "capture.bin": "32 B LE: i32 seq, u64 cap_host_ns, f32 tx_gain, u8 muted, u8 voiced, pad14",
        ],
        "streams": ["raw.wav": "float32 mono 48k: mic after trim+HPF, before canceller/gate",
                    "sent.wav": "int16 mono 48k: what was handed to the wire, after gate/floor/mute/softLimit",
                    "played.wav": "int16 mono 48k: what left the speaker (after presence and the ear ramp)"],
      ]
      if final {
        m["duration_s"] = Date().timeIntervalSince(startedAt)
        m["samples"] = ["raw": written.raw, "sent": written.sent, "played": written.played]
        m["records"] = ["render": written.render, "capture": written.cap]
        m["full"] = ["raw": rawFull, "sent": sentFull, "played": playedFull, "render": renderFull, "capture": capFull]
        m["bytes"] = bytes
      }
      if let data = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: d.appendingPathComponent("meta.json"))
      }
    }

    /// Final drain, header patch and meta. Synchronous; called once on the way out.
    func finish(callId: String, facts: [String: String]) {
      ioLock.lock()
      defer { ioLock.unlock() }
      guard !finished, dir != nil else { return }
      finished = true
      on = false
      stopping = true
      drain()
      for (name, float, n) in [("raw.wav", true, written.raw), ("sent.wav", false, written.sent), ("played.wav", false, written.played)] {
        guard let fh = files[name] else { continue }
        let bytesPer: UInt32 = float ? 4 : 2
        fh.seek(toFileOffset: 0)
        fh.write(Tape.wavHeader(float: float, dataBytes: UInt32(n) * bytesPer))
        fh.closeFile()
      }
      files["render.bin"]?.closeFile(); files["capture.bin"]?.closeFile()
      files.removeAll()
      writeMeta(callId: callId, facts: facts, final: true)
    }

    var state: String {
      if finished { return "finished" }
      if anyFull { return "full" }
      return on ? "recording" : "off"
    }
  }

  // ── The selftest: every ruler on known inputs, and on inputs it must reject ──

  private static func findMedia(_ name: String) -> String? {
    for d in ["testbed/media/real", "../testbed/media/real", "../../testbed/media/real"] {
      let p = d + "/" + name
      if FileManager.default.fileExists(atPath: p) { return p }
    }
    return nil
  }

  /// Windowed-sinc low-pass (Blackman, 601 taps). The only honest way to make a
  /// band-limited copy for a ruler calibration -- an IIR or a linear interpolation
  /// colours the passband and the ruler would be graded against the colouring.
  static func lowpass(_ x: [Float], cutoffHz: Double) -> [Float] {
    let taps = 601, M = (taps - 1) / 2
    var h = [Float](repeating: 0, count: taps)
    let fc = cutoffHz / SR
    var sum: Double = 0
    for n in 0..<taps {
      let k = Double(n - M)
      let sinc = k == 0 ? 2 * fc : sin(2 * Double.pi * fc * k) / (Double.pi * k)
      let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(n) / Double(taps - 1)) + 0.08 * cos(4 * Double.pi * Double(n) / Double(taps - 1))
      h[n] = Float(sinc * w); sum += Double(h[n])
    }
    for n in 0..<taps { h[n] /= Float(sum) }
    guard x.count > taps else { return x }
    var y = [Float](repeating: 0, count: x.count - taps + 1)
    vDSP_conv(x, 1, h, 1, &y, 1, vDSP_Length(y.count), vDSP_Length(taps))
    return y
  }

  static func selftest() -> Bool {
    var fail = 0
    func say(_ ok: Bool, _ what: String) {
      fputs("  \(ok ? "ok   " : "FAIL ") \(what)\n", stderr)
      if !ok { fail += 1 }
    }
    func fmt(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "absent" }
    fputs("audiolab selftest\n", stderr)

    guard let pa = findMedia("realA.wav"), let pb = findMedia("realB.wav"),
          let a = Audio.loadMono48(pa), let b = Audio.loadMono48(pb), a.count > SR_I * 4, b.count > SR_I * 4 else {
      fputs("  FAIL testbed/media/real/realA.wav and realB.wav are required -- a ruler calibrated on nothing is not calibrated\n", stderr)
      return false
    }
    let all = [UInt8](repeating: 1, count: 48000)
    // ── bandwidth ──
    let aSec = Array(a[SR_I..<SR_I * 2])
    let bwRaw = bandwidthKHz(aSec, voiced: all)
    say((bwRaw ?? 0) >= 8, "bandwidth: real speech untouched reads \(fmt(bwRaw)) kHz (>= 8)")
    let a7 = lowpass(Array(a[SR_I..<SR_I * 2 + 601]), cutoffHz: 7000)
    let bw7 = bandwidthKHz(Array(a7[0..<48000]), voiced: all)
    say((bw7 ?? 0) >= 6 && (bw7 ?? 99) <= 8.1, "bandwidth: 7 kHz low-pass reads \(fmt(bw7)) kHz (6-8)")
    let a34 = lowpass(Array(a[SR_I..<SR_I * 2 + 601]), cutoffHz: 3400)
    let bw34 = bandwidthKHz(Array(a34[0..<48000]), voiced: all)
    say((bw34 ?? 0) >= 3 && (bw34 ?? 99) <= 4.1, "bandwidth: 3.4 kHz low-pass reads \(fmt(bw34)) kHz (3-4)")
    var rng = SystemRandomNumberGenerator()
    let white = (0..<48000).map { _ in Float.random(in: -0.3...0.3, using: &rng) }
    let bwW = bandwidthKHz(white, voiced: all)
    say((bwW ?? 0) >= 18, "bandwidth: white noise reads \(fmt(bwW)) kHz (>= 18)")
    let bwS = bandwidthKHz([Float](repeating: 0, count: 48000), voiced: all)
    say(bwS == nil, "bandwidth: digital silence reports nothing (\(fmt(bwS))) -- REJECT row")
    var half = all; for i in 0..<40000 { half[i] = 0 }
    let bwU = bandwidthKHz(aSec, voiced: half)
    say(bwU == nil, "bandwidth: under 300 ms of voice reports nothing (\(fmt(bwU))) -- REJECT row")
    // The flag the LIVE ruler runs under: the voice's own envelope, 35 ms
    // release, 0.004 threshold -- syllables and their tails, not a whole second.
    var envFlags = [UInt8](repeating: 0, count: 48000)
    var env: Float = 0
    let dec = Float(exp(-1.0 / SR / 0.035))
    for i in 0..<48000 { let a = abs(aSec[i]); env = a > env ? a : env * dec; envFlags[i] = env > 0.004 ? 1 : 0 }
    let bwE = bandwidthKHz(aSec, voiced: envFlags)
    say((bwE ?? 0) >= 8, "bandwidth: the same speech under the live envelope flag reads \(fmt(bwE)) kHz (>= 8; whole-second read \(fmt(bwRaw)))")

    // ── echo return ──
    func dec8(_ x: [Float]) -> [Float] {
      var out = [Float](repeating: 0, count: x.count / 8)
      for i in 0..<out.count { var s: Float = 0; for j in 0..<8 { s += x[i * 8 + j] }; out[i] = s / 8 }
      return out
    }
    let W = 3 * SR_I, lagS = Int(0.350 * SR), lagMaxS = Int(0.600 * SR)
    let sent = Array(a[SR_I..<SR_I + W])
    var recv = [Float](repeating: 0, count: W + lagMaxS)
    let far = Array(b[SR_I..<SR_I + W + lagMaxS])
    var sE: Float = 0, fE: Float = 0
    vDSP_svesq(sent, 1, &sE, vDSP_Length(W)); vDSP_svesq(far, 1, &fE, vDSP_Length(W))
    let match = (sE / max(fE, 1e-12)).squareRoot()
    for i in 0..<recv.count {
      var v = far[i] * match
      if i >= lagS, i - lagS < W { v += 0.30 * sent[i - lagS] }
      recv[i] = v
    }
    let r1 = echoReturn(sent: dec8(sent), recv: dec8(recv), lagMin: Int(0.020 * SR) / 8, lagMax: lagMaxS / 8)
    let lagMs1 = r1.map { Double($0.lag * 8) / SR * 1000 }
    say((r1?.corr ?? 0) >= RETURN_CORR && abs((lagMs1 ?? 0) - 350) <= 5 && abs((r1?.gainDb ?? 0) - (-10.46)) <= 2,
        "echo return: planted 0.30x at 350 ms under an equal-level far voice -> corr \(fmt(r1?.corr)) (>= \(RETURN_CORR)) lag \(fmt(lagMs1)) ms level \(fmt(r1?.gainDb)) dB")
    var recv2 = [Float](repeating: 0, count: W + lagMaxS)
    for i in 0..<recv2.count { recv2[i] = far[i] * match }
    let r2 = echoReturn(sent: dec8(sent), recv: dec8(recv2), lagMin: Int(0.020 * SR) / 8, lagMax: lagMaxS / 8)
    say((r2?.corr ?? 0) < RETURN_CORR, "echo return: an unrelated far voice alone -> corr \(fmt(r2?.corr)) (< \(RETURN_CORR)) -- REJECT row")
    let r3 = echoReturn(sent: dec8(sent), recv: [Float](repeating: 0, count: (W + lagMaxS) / 8), lagMin: Int(0.020 * SR) / 8, lagMax: lagMaxS / 8)
    say(r3 == nil || r3!.corr < RETURN_CORR, "echo return: silence -> \(r3 == nil ? "nothing" : fmt(r3?.corr)) -- REJECT row")

    // ── levels, noise, snr, swing ──
    let lab = AudioLab()
    func pushFrames(_ ring: FrameRing, db: Float, voiced: Bool, seconds: Double) {
      let amp = Double(pow(10, db / 20))
      let sq = amp * amp
      for _ in 0..<Int(seconds * 20) {
        ring.addBlock(postSq: sq * Double(FRAME), preSq: sq * Double(FRAME), n: FRAME, voicedN: voiced ? FRAME : 0, silentN: 0)
      }
    }
    pushFrames(lab.rx, db: -20, voiced: true, seconds: 1)
    pushFrames(lab.rx, db: -14, voiced: true, seconds: 1)
    pushFrames(lab.rx, db: -60, voiced: false, seconds: 1)
    pushFrames(lab.tx, db: -20, voiced: true, seconds: 2)
    pushFrames(lab.tx, db: -60, voiced: false, seconds: 1)
    var f: [String: Any] = [:]
    lab.beatFields(into: &f, txVoiceS: 48000, txVoiceMutedS: 9600, m2eP50: nil)
    let rxp50 = f["a_rx_level_db_p50"] as? Double, rxn = f["a_rx_noise_db"] as? Double, sw = f["a_rx_level_swing_db"] as? Double
    say(rxp50 != nil && abs(rxp50! - (-17)) <= 3.5, "levels: rx p50 \(fmt(rxp50)) dBFS over -20/-14 (about -17)")
    say(rxn != nil && abs(rxn! - (-60)) <= 0.5, "levels: rx noise \(fmt(rxn)) dBFS (-60 +- 0.5)")
    say(sw != nil && abs(sw! - 6) <= 0.5, "levels: swing \(fmt(sw)) dB between adjacent seconds at -20 and -14 (6 +- 0.5)")
    let txp50 = f["a_tx_level_db_p50"] as? Double, txn = f["a_tx_noise_db"] as? Double, snr = f["a_tx_snr_db"] as? Double
    say(txp50 != nil && abs(txp50! - (-20)) <= 0.5, "levels: tx p50 \(fmt(txp50)) dBFS (-20 +- 0.5)")
    say(txn != nil && abs(txn! - (-60)) <= 0.5, "levels: tx noise \(fmt(txn)) dBFS (-60 +- 0.5)")
    say(snr != nil && abs(snr! - 40) <= 1, "levels: snr \(fmt(snr)) dB (40 +- 1)")
    say(abs((f["a_tx_voice_muted_ms"] as? Double ?? 0) - 200) < 0.01 && abs((f["a_tx_voice_ms"] as? Double ?? 0) - 1000) < 0.01,
        "voice muted: 9600 of 48000 voiced samples under gain -> \(fmt(f["a_tx_voice_muted_ms"] as? Double)) of \(fmt(f["a_tx_voice_ms"] as? Double)) ms")
    let empty = AudioLab()
    var g: [String: Any] = [:]
    empty.beatFields(into: &g, txVoiceS: 0, txVoiceMutedS: 0, m2eP50: nil)
    say(g["a_rx_level_db_p50"] == nil && g["a_rx_bw_khz"] == nil && g["a_echo_return_db"] == nil,
        "levels: an empty window sends NO level, bandwidth or echo field -- REJECT row")

    // ── glitches ──
    let quiet = AudioLab()
    quiet.seam(step: 0.002, rms: 0.05)
    say(quiet.rxGlitches == 0, "glitch: a cross-faded seam (step 0.002 on 0.05 rms) is not a glitch")
    quiet.seam(step: 0.09, rms: 0.05)
    say(quiet.rxGlitches == 1, "glitch: a zero-fill seam (step 0.09 on 0.05 rms) is one glitch")
    quiet.seam(step: 0.02, rms: 0.0)
    say(quiet.rxGlitches == 2, "glitch: a 0.02 step on silence is audible -- counted")
    quiet.seam(step: 0.005, rms: 0.0)
    say(quiet.rxGlitches == 2, "glitch: a 0.005 step on silence is not -- REJECT row")

    // ── dead air ──
    let dead = AudioLab()
    for _ in 0..<SR_I { dead.rxPlayed(val: 0, emitted: 0) }
    let deadMs = Double(dead.rxSilenceS) / SR * 1000
    say(abs(deadMs - 1000) <= 20, "dead air: 1 s of exact zeros -> \(String(format: "%.0f", deadMs)) ms (1000 +- 20)")
    let noisy = AudioLab()
    for _ in 0..<SR_I { noisy.rxPlayed(val: Float.random(in: -0.001...0.001, using: &rng), emitted: 0) }
    say(noisy.rxSilenceS == 0, "dead air: 1 s of -60 dBFS noise -> \(noisy.rxSilenceS) samples (0) -- REJECT row")

    // ── tapes: wav round trip, lab flag, retention ──
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("audiolab-\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    Tape.baseOverride = tmp.appendingPathComponent("tapes", isDirectory: true)
    defer { Tape.baseOverride = nil }
    let tp = Tape()
    let msg = tp.start(callId: "selftest", facts: ["cam": "none"])
    say(msg.hasPrefix("tapes: recording"), msg)
    var rawIn = [Float](repeating: 0, count: SR_I)
    for i in 0..<SR_I { rawIn[i] = Float(sin(Double(i) * 0.01)) * 1.5 }   // peaks past 1.0 on purpose
    rawIn.withUnsafeBufferPointer { tp.raw($0.baseAddress!, SR_I) }
    for i in 0..<SR_I { tp.sent(Int16(truncatingIfNeeded: i % 30000 - 15000)); tp.played(Float(i % 100) / 100.0 - 0.5) }
    for i in 0..<3000 { tp.render(hostNs: UInt64(i), pos: Double(i) * 16, n: 16, concealed: i % 7 == 0 ? 16 : 0, rate: 1.001, ear: 1) }
    for i in 0..<1500 { tp.capture(seq: Int32(i), hostNs: UInt64(i) * 666_666, gain: i < 750 ? 1 : 0.2, muted: false, voiced: true) }
    Thread.sleep(forTimeInterval: 0.6)
    tp.finish(callId: "selftest", facts: ["cam": "none"])
    let dir = tmp.appendingPathComponent("tapes/selftest")
    func readWav(_ name: String) -> (float: Bool, bytes: Data)? {
      guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)), d.count > 46 else { return nil }
      let tag = d[20] | (d[21] << 8)
      let dataLen = Int(d[42]) | Int(d[43]) << 8 | Int(d[44]) << 16 | Int(d[45]) << 24
      guard d.count == 46 + dataLen else { return nil }
      return (tag == 3, d.subdata(in: 46..<d.count))
    }
    if let r = readWav("raw.wav") {
      let back = r.bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
      say(r.float && back.count == SR_I && back == rawIn, "tape: raw.wav is float32, \(back.count) samples, sample-exact including peaks past 1.0")
    } else { say(false, "tape: raw.wav unreadable or its header disagrees with its length") }
    if let s = readWav("sent.wav") {
      let back = s.bytes.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
      var exact = back.count == SR_I
      if exact { for i in 0..<SR_I where back[i] != Int16(truncatingIfNeeded: i % 30000 - 15000) { exact = false; break } }
      say(!s.float && exact, "tape: sent.wav is int16, \(back.count) samples, sample-exact")
    } else { say(false, "tape: sent.wav unreadable or its header disagrees with its length") }
    let rb = (try? Data(contentsOf: dir.appendingPathComponent("render.bin")))?.count ?? -1
    let cb = (try? Data(contentsOf: dir.appendingPathComponent("capture.bin")))?.count ?? -1
    say(rb == 3000 * 32 && cb == 1500 * 32, "tape: render.bin \(rb) B (3000 records), capture.bin \(cb) B (1500 records)")
    if let md = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
       let m = try? JSONSerialization.jsonObject(with: md) as? [String: Any],
       let samples = m["samples"] as? [String: Int] {
      say(samples["raw"] == SR_I && samples["played"] == SR_I && (m["duration_s"] as? Double ?? 0) > 0.5, "tape: meta.json carries the final counts (raw \(samples["raw"] ?? -1), played \(samples["played"] ?? -1))")
    } else { say(false, "tape: meta.json missing its final counts") }
    // A stopped tape refuses new samples: nothing written after finish.
    tp.played(0.5)
    say(tp.playedW == SR_I, "tape: a finished tape takes no more samples -- REJECT row")
    // Retention: five directories, keep three at the next start.
    let base = tmp.appendingPathComponent("tapes")
    for i in 0..<5 {
      let d = base.appendingPathComponent("old\(i)", isDirectory: true)
      try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
      try? Data(repeating: 0, count: 1000).write(to: d.appendingPathComponent("x"))
      try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(-100 + i))], ofItemAtPath: d.path)
    }
    _ = Tape.prune(base)
    let left = (try? FileManager.default.contentsOfDirectory(atPath: base.path))?.count ?? -1
    say(left == 2, "tape: retention leaves the newest 2 of 6 directories for a new call to make 3 (left \(left))")
    // Lab flag round trip, in a scratch identity dir.
    Lab.dirOverride = tmp.appendingPathComponent("kin", isDirectory: true)
    defer { Lab.dirOverride = nil }
    say(Lab.tapesOn() == false, "lab: no lab.json means off")
    _ = Lab.set(tapes: true, source: "cli")
    say(Lab.tapesOn() == true && Lab.state().contains("cli"), "lab: --lab on persists and names its source (\(Lab.state()))")
    say(Lab.set(tapes: true, source: "server") == false, "lab: the same answer again is not a change -- REJECT row")
    say(Lab.set(tapes: false, source: "server") == true && Lab.tapesOn() == false, "lab: the server can turn it off, and that is a change")

    fputs("audiolab selftest: \(fail == 0 ? "PASS" : "FAIL (\(fail))")\n", stderr)
    return fail == 0
  }
}

let SR_I = Int(SR)

// ── Lab mode: the switch, and who may flip it ────────────────────────────────
//
// `lab.json` beside `identity.json`. The CLI writes it (`--lab on|off`), and so
// does the owner's own server through the reply to every beat -- so the owner's
// Macs never need a command typed on them. Nothing else reads it and nothing on
// the consumer surface shows it.
enum Lab {
  nonisolated(unsafe) static var dirOverride: URL?
  static var dir: URL { dirOverride ?? Identity.dir }
  static var file: URL { dir.appendingPathComponent("lab.json") }
  /// `--no-tapes`: this process tapes nothing whatever the file says. The rig's
  /// control arm.
  nonisolated(unsafe) static var noTapesForRun = false

  static func read() -> [String: Any]? {
    guard let d = try? Data(contentsOf: file),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return j
  }
  static func tapesOn() -> Bool { (read()?["tapes"] as? Bool) ?? false }
  static func state() -> String {
    guard let j = read() else { return "off (no lab.json at \(file.path))" }
    let on = (j["tapes"] as? Bool) ?? false
    return "\(on ? "on" : "off") (\(j["source"] as? String ?? "?") at \(j["at"] as? String ?? "?"))"
  }
  /// Returns true only if the state CHANGED, so callers can log a flip and never
  /// a repeat.
  @discardableResult
  static func set(tapes: Bool, source: String) -> Bool {
    let was = read()
    if let w = was, (w["tapes"] as? Bool) == tapes { return false }
    let j: [String: Any] = ["tapes": tapes, "source": source, "at": ISO8601DateFormatter().string(from: Date())]
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let d = try? JSONSerialization.data(withJSONObject: j, options: [.sortedKeys]) else { return false }
    try? d.write(to: file, options: .atomic)
    return true
  }
  /// The server's answer to a beat. Only ever acted on when it differs from the
  /// file, and said out loud when it does.
  static func applyServer(_ on: Bool) {
    if set(tapes: on, source: "server") {
      fputs("lab: the server turned tapes \(on ? "ON" : "off") for this install\n", stderr)
      Metrics.fact("lab", on ? "on" : "off")
    }
  }
}
