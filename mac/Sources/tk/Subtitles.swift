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
    private(set) var available = false

    // Downsampling 48 kHz to 16 is a factor of three, and a factor of three
    // needs a real filter in front of it. A one-pole is 6 dB per octave and
    // leaves most of the band above 8 kHz to fold back on top of the speech --
    // which is not a linear function of anything and cannot be undone later.
    private var dsState = [Float](repeating: 0, count: 4)
    private var dsPhase = 0

    init(host: String = "127.0.0.1", port: Int = 8789) {
        url = URL(string: "http://\(host):\(port)/transcribe")!
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.httpMaximumConnectionsPerHost = 1     // keep-alive: skip the handshake
        session = URLSession(configuration: c)
        probe(host: host, port: port)
    }

    private func probe(host: String, port: Int) {
        var r = URLRequest(url: URL(string: "http://\(host):\(port)/health")!)
        r.timeoutInterval = 2
        session.dataTask(with: r) { [weak self] d, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200 && d != nil
            self?.available = ok
            fputs(ok ? "subtitles: local recogniser is up\n"
                     : "subtitles: no local recogniser at \(host):\(port) -- the quiet side will have no words\n",
                  stderr)
        }.resume()
    }

    /// Feed it 48 kHz mono that has already been cleaned for the recogniser.
    /// Safe to call from the audio thread: it filters, decimates and appends,
    /// and never allocates beyond the append.
    func feed(_ x: UnsafePointer<Float>, _ n: Int) {
        guard available else { return }
        var out = [Float]()
        out.reserveCapacity(n / 3 + 1)
        for i in 0..<n {
            var v = x[i]
            for k in 0..<4 {                    // 4 poles at ~6.5 kHz
                dsState[k] += (v - dsState[k]) * 0.60
                v = dsState[k]
            }
            dsPhase += 1
            if dsPhase == 3 { dsPhase = 0; out.append(v) }
        }
        lock.lock()
        pending.append(contentsOf: out)
        let cap = Int(Subtitles.RATE * Subtitles.MAX_S)
        if pending.count > cap { pending.removeFirst(pending.count - cap) }
        lock.unlock()
    }

    /// Called when the classifier says this end stopped talking.
    func endUtterance() {
        transcribe(final: true)
        lock.lock(); pending.removeAll(keepingCapacity: true); lastText = ""; lock.unlock()
    }

    /// Called while this end is talking; rate-limits itself.
    func tick() {
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
            defer { self.lock.lock(); self.inFlight = false; self.lock.unlock() }
            guard let d, err == nil,
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                self.failures += 1; return
            }
            if let ms = o["ms"] as? Double { self.lastMs = ms }
            if let c = o["complete"] as? Double { self.onComplete?(c) }
            let text = (o["text"] as? String) ?? ""
            // An empty revision is not a correction, it is the recogniser having
            // nothing yet -- publishing it would blank a subtitle mid-sentence.
            guard !text.isEmpty || final else { return }
            if !text.isEmpty { self.lastText = text }
            self.onText?(text.isEmpty ? self.lastText : text, final)
        }.resume()
    }
}
