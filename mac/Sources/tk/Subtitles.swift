import Foundation
import Accelerate

// ── WHAT THE MUTED PERSON IS SAYING ──────────────────────────────────────────
//
// On speakers only one person is audible at a time, which is what removes echo
// from the product entirely. The cost is that the other person is not heard --
// and the whole design rests on them not being LOST either. Their words still
// have to arrive, in time to matter, or the quiet half of the call is somebody
// talking into nothing.
//
// SO THE AUDIO NEVER TRAVELS. Their own machine already holds their microphone
// at full quality -- the gate turns it down on the way to the wire, it does not
// stop capturing -- so recognition happens there and only the TEXT crosses the
// network. A few dozen bytes against a few dozen kilobytes, and no round trip
// inside the loop that has to keep up with a person talking.
//
// It runs against the local Qwen3-ASR daemon rather than the system recogniser,
// which is a quality judgement made by ear, not a technical one. The daemon
// returns the transcript and smart-turn's "have they finished" probability in
// the SAME response, so one request buys both: about 85 ms for the words and 13
// for the prosody.
final class Subtitles {
    static let RATE = 16000.0
    /// How often a running guess is revised while somebody is still talking.
    /// Fast enough to read along with, slow enough that the daemon is never
    /// asked to do two things at once.
    static let REVISE_MS = 350.0
    /// Nothing shorter than this is worth a request; it is not a word yet.
    static let MIN_MS = 260.0
    /// One person does not say more than this without a pause worth ending on.
    static let MAX_S = 14.0

    private let url: URL
    private let session: URLSession
    private let q = DispatchQueue(label: "subtitles", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [Float] = []          // 16 kHz, current utterance
    private var inFlight = false
    private var lastSentAt = Date.distantPast
    private var lastText = ""

    /// A revision of what this end is saying, and whether it is the last one.
    var onText: ((String, Bool) -> Void)?
    /// Smart-turn's probability that the sentence has landed rather than trailed
    /// off. It reads the waveform, so it hears prosody -- the thing no transcript
    /// can recover.
    var onComplete: ((Double) -> Void)?

    private(set) var requests = 0
    private(set) var failures = 0
    private(set) var lastMs: Double = 0
    /// True once EITHER engine is running. `feed` is a no-op before that, so a
    /// call that starts before the recogniser is up simply has no words for a
    /// moment rather than queueing audio nobody will read.
    private(set) var available = false
    /// ── THE SECOND ENGINE ──────────────────────────────────────────────────
    ///
    /// The daemon is a Python LaunchAgent on one machine. Everybody else gets the
    /// system recogniser, which on macOS 26 is a different and much better model
    /// than the `SFSpeechRecognizer` the quality judgement was made against -- see
    /// AppleSpeech.swift for the measurement. Preferred order is Qwen, then this,
    /// and the log says which is running so a transcript is never anonymous.
    private var apple: AnyObject?
    private(set) var engine = "none"
    private var emptyRun = 0
    private var fellBack = false
    /// An utterance ended while a request was in flight. The final is owed.
    private var finalWanted = false

    // ── 48 kHz TO 16, WITHOUT EATING THE CONSONANTS ────────────────────────
    //
    // This was four cascaded one-poles at alpha 0.6. It does stop the aliasing,
    // and it is 24 dB per octave starting around 3.5 kHz -- so it also removes
    // most of the energy in s, sh, f and t, which is exactly the band a
    // recogniser uses to tell them apart. Measured against ground truth on a live
    // call it cost about a third of the word errors: the same engine that
    // transcribes a file at near zero was running at 28% through this.
    //
    // A windowed-sinc instead: flat to 6.8 kHz, 60 dB down by 8, which is what a
    // decimator is supposed to look like. 95 taps at 16 kHz output is 1.5 million
    // multiplies a second on a thread that wakes eight times a second.
    private let dec = Decimator3()

    // ── WHICH ENGINE, AND THE MEASUREMENT THAT DECIDED IT ──────────────────
    //
    // Scored against ground truth -- LibriSpeech dev-clean, real read speech with
    // a known correct transcript -- end to end through a live two-process call,
    // each arm run twice:
    //
    //   the system recogniser     3.0%,  3.0% word error
    //   the Qwen daemon          50.9%, 46.2%
    //
    // And then the same six utterances handed to the daemon whole, one request
    // each, no streaming:
    //
    //   the Qwen MODEL            3.0%
    //
    // The models are identical. The entire gap is this file's streaming of the
    // daemon: it re-transcribes a growing window every 350 ms, publishes finals
    // at boundaries that overlap, and loses the tail of any utterance that ends
    // while a request is in flight. Chasing that further is not worth it when a
    // tied-accuracy path exists that streams natively, needs no daemon, no model
    // download and no authorization prompt.
    //
    // So the system recogniser is the default and the daemon is opt-in. What the
    // daemon still buys is smart-turn's completion probability, which is what
    // ends an utterance on a landed thought rather than on a silence -- the
    // system engine finds its own sentence boundaries instead, which is the same
    // job done a different way.
    //
    /// `prefer`: "apple" (default) uses the system recogniser; "qwen" prefers the
    /// local daemon and falls back to the system one if it is not ready; "auto"
    /// is the old order, daemon first. One flag, so an A/B is not a LaunchAgent
    /// being stopped and started.
    init(host: String = "127.0.0.1", port: Int = 8789, prefer: String = "apple") {
        url = URL(string: "http://\(host):\(port)/transcribe")!
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.httpMaximumConnectionsPerHost = 1     // keep-alive: skip the handshake
        session = URLSession(configuration: c)
        if prefer == "apple" { startApple(); return }
        // "qwen" now MEANS "prefer qwen", not "qwen or nothing": refusing to fall
        // back left the quiet side mute whenever the daemon was loaded but its
        // model was not, which is a state it reaches on its own.
        probe(host: host, port: port, fallBack: true)
    }

    private func probe(host: String, port: Int, fallBack: Bool) {
        var r = URLRequest(url: URL(string: "http://\(host):\(port)/health")!)
        r.timeoutInterval = 2
        session.dataTask(with: r) { [weak self] d, resp, _ in
            guard let self else { return }
            // ── 200 IS NOT THE SAME AS READY ──────────────────────────────────
            //
            // The daemon answers /health the moment its HTTP server is up and
            // reports `ready: false` while the model is still loading -- or, as
            // happened here, permanently, after a stale import error. Checking
            // only the status code picked it anyway, sent seventeen requests that
            // all came back with nothing, and left the quiet side with no words
            // and no fallback because the choice had already been made.
            var ready = (resp as? HTTPURLResponse)?.statusCode == 200 && d != nil
            var why = ""
            if ready, let d,
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                if let r = o["ready"] as? Bool, !r {
                    ready = false
                    why = (o["error"] as? String).map { " -- \($0.prefix(120))" } ?? " -- not ready"
                }
            }
            let ok = ready
            if ok {
                self.available = true
                self.engine = "qwen"
                fputs("subtitles: local recogniser is up\n", stderr)
                return
            }
            fputs("subtitles: no local recogniser at \(host):\(port)\(why)\n", stderr)
            if fallBack { self.startApple() }
            else { fputs("subtitles: the quiet side will have no words\n", stderr) }
        }.resume()
    }

    private func startApple() {
        guard #available(macOS 26.0, *) else {
            fputs("subtitles: this Mac is older than the system recogniser"
                + " -- the quiet side will have no words\n", stderr)
            return
        }
        let a = AppleSpeech()
        a.onText = { [weak self] text, final in
            guard let self else { return }
            // The same contract the daemon path publishes: a running revision,
            // then a commit. Nothing downstream can tell which engine wrote it.
            if !self.available { self.available = true; self.engine = "apple" }
            self.onText?(text, final)
        }
        apple = a
        a.start()
    }

    /// Feed it 48 kHz mono that has already been cleaned for the recogniser.
    /// Safe to call from the audio thread: it filters, decimates and appends,
    /// and never allocates beyond the append.
    func feed(_ x: UnsafePointer<Float>, _ n: Int) {
        // The Apple engine is fed even before `available` flips, because it comes
        // up asynchronously and its own stream tolerates being written to from
        // the first block. The daemon path must not: it would buffer audio for a
        // server that is not there.
        if #available(macOS 26.0, *), let a = apple as? AppleSpeech {
            a.feed(dec.run(x, n))
            return
        }
        guard available else { return }
        let out = dec.run(x, n)
        lock.lock()
        pending.append(contentsOf: out)
        let cap = Int(Subtitles.RATE * Subtitles.MAX_S)
        if pending.count > cap { pending.removeFirst(pending.count - cap) }
        lock.unlock()
    }

    /// Called when the classifier says this end stopped talking.
    ///
    /// ── THE FINAL CANNOT BE SKIPPED, AND IT WAS ────────────────────────────
    ///
    /// `transcribe` refuses to start while another request is in flight, which is
    /// right for a revision -- the next one will cover more audio anyway -- and
    /// fatal for the last one, because this method then threw the buffer away.
    /// Every utterance that happened to end while a request was outstanding lost
    /// its tail permanently. Measured against ground truth on a live call: 47%
    /// word error through this path against 3% for the same model handed whole
    /// utterances, which is the entire gap between them.
    ///
    /// So a final that cannot go now is REMEMBERED, and the completion handler
    /// issues it. Nothing is cleared until it has actually been sent.
    func endUtterance() {
        // The system engine finds its own sentence boundaries and emits its own
        // finals; forcing one here would cut the last word off.
        if #available(macOS 26.0, *), apple is AppleSpeech { return }
        lock.lock(); let busy = inFlight; if busy { finalWanted = true }; lock.unlock()
        guard !busy else { return }
        transcribe(final: true)
        lock.lock(); pending.removeAll(keepingCapacity: true); lastText = ""; lock.unlock()
    }

    /// Called while this end is talking; rate-limits itself.
    func tick() {
        if #available(macOS 26.0, *), apple is AppleSpeech { return }   // it streams
        guard Date().timeIntervalSince(lastSentAt) * 1000 >= Subtitles.REVISE_MS else { return }
        transcribe(final: false)
    }

    private func transcribe(final: Bool) {
        guard available else { return }
        lock.lock()
        let audio = pending
        let busy = inFlight
        if !busy { inFlight = true }
        lock.unlock()
        // ONE REQUEST AT A TIME. Two in flight would return out of order and the
        // subtitle would jump backwards, which reads as the app malfunctioning
        // rather than as a person revising.
        guard !busy else { return }
        guard Double(audio.count) / Subtitles.RATE * 1000 >= Subtitles.MIN_MS else {
            lock.lock(); inFlight = false; lock.unlock()
            if final, !lastText.isEmpty { onText?(lastText, true) }
            return
        }
        lastSentAt = Date()
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.httpBody = audio.withUnsafeBufferPointer { Data(buffer: $0) }
        requests += 1
        session.dataTask(with: r) { [weak self] d, _, err in
            guard let self else { return }
            // ── RELEASE THE SLOT EXPLICITLY, NOT WITH `defer` ────────────────
            //
            // A `defer` at the top of this closure runs after the whole body, so
            // anything inside the body that wants to START A NEW REQUEST finds
            // `inFlight` still true and is silently dropped. The first version of
            // the owed-final fix put its work in a nested `defer` and hit exactly
            // that -- an inner `defer` fires at the end of its own block, before
            // the outer one, so it re-issued into a slot that was still taken.
            //
            // Explicit, in order: release, then decide, then re-issue.
            self.lock.lock()
            self.inFlight = false
            let owed = self.finalWanted
            self.finalWanted = false
            self.lock.unlock()
            defer {
                // The utterance ended while this request was in the air. Send its
                // final now that the slot is free, and only then let the buffer
                // go -- clearing it first is what lost the tail of every sentence
                // that happened to end during a request.
                if owed {
                    self.transcribe(final: true)
                    self.lock.lock()
                    self.pending.removeAll(keepingCapacity: true); self.lastText = ""
                    self.lock.unlock()
                }
            }
            guard let d, err == nil,
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                self.failures += 1; return
            }
            if let ms = o["ms"] as? Double { self.lastMs = ms }
            if let c = o["complete"] as? Double { self.onComplete?(c) }
            let text = (o["text"] as? String) ?? ""
            // ── AND IT CAN GO BAD MID-CALL ────────────────────────────────────
            //
            // `transcribe` only runs while the classifier says somebody is
            // talking, so a run of answers with no words in them is not silence,
            // it is a recogniser that has stopped recognising. Rather than
            // leaving the quiet side mute for the rest of the call, hand over to
            // the system engine and say so once.
            if text.isEmpty {
                self.emptyRun += 1
                if self.emptyRun == 6, self.engine == "qwen", self.fellBack == false {
                    self.fellBack = true
                    fputs("subtitles: the local recogniser has stopped returning words"
                        + " -- switching to the system one\n", stderr)
                    self.available = false
                    self.startApple()
                }
            } else { self.emptyRun = 0 }
            // An empty revision is not a correction, it is the recogniser having
            // nothing yet -- publishing it would blank a subtitle mid-sentence.
            guard !text.isEmpty || final else { return }
            if !text.isEmpty { self.lastText = text }
            self.onText?(text.isEmpty ? self.lastText : text, final)
        }.resume()
    }
}


// ── THE DECIMATOR, AND A RULER FOR IT ────────────────────────────────────────
//
// 48 kHz in, 16 out, with the anti-alias filter a factor of three actually
// requires. Not on the audio thread -- the subtitle chunk reader is a plain
// 120 ms thread -- so it can afford to be correct rather than cheap.
final class Decimator3 {
    static let taps = 95
    /// Windowed sinc, cut at 6.8 kHz of a 48 kHz band, Blackman window. Built
    /// once; a table this small is nothing and computing it beats writing 95
    /// numbers down where one typo is a filter nobody would ever notice was wrong.
    static let h: [Float] = {
        let n = taps, fc = 6800.0 / 48000.0
        let mid = Double(n - 1) / 2
        var t = [Float](repeating: 0, count: n)
        var sum = 0.0
        for i in 0..<n {
            let k = Double(i) - mid
            let sinc = k == 0 ? 2 * fc : sin(2 * .pi * fc * k) / (.pi * k)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1))
                         + 0.08 * cos(4 * .pi * Double(i) / Double(n - 1))
            let v = sinc * w
            t[i] = Float(v); sum += v
        }
        for i in 0..<n { t[i] /= Float(sum) }      // unity at DC
        return t
    }()

    private var hist = [Float](repeating: 0, count: Decimator3.taps)
    private var w = 0
    private var phase = 0

    /// Streaming: history carries across calls, so a chunk boundary is not a
    /// discontinuity. Returns roughly n/3 samples.
    func run(_ x: UnsafePointer<Float>, _ n: Int) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(n / 3 + 2)
        let N = Decimator3.taps
        Decimator3.h.withUnsafeBufferPointer { hp in
            hist.withUnsafeMutableBufferPointer { hb in
                for i in 0..<n {
                    hb[w] = x[i]
                    w = (w + 1) % N
                    phase += 1
                    if phase == 3 {
                        phase = 0
                        var acc: Float = 0
                        var idx = w
                        // hist[w] is the OLDEST sample, so walking forward from it
                        // pairs the oldest input with h[0] -- which is symmetric
                        // here anyway, and stated because getting it backwards is
                        // invisible in a symmetric filter and fatal in any other.
                        for k in 0..<N { acc += hb[idx] * hp[k]; idx = idx + 1 == N ? 0 : idx + 1 }
                        out.append(acc)
                    }
                }
            }
        }
        return out
    }
}
