import Foundation
import AVFoundation
import Speech

// ── THE RECOGNISER EVERY MAC ALREADY HAS ─────────────────────────────────────
//
// Kin's first recogniser is a local Qwen3-ASR daemon, chosen by ear: it is more
// accurate than what shipped with the system, and it returns smart-turn's
// completion probability in the same response. It is also a Python LaunchAgent on
// exactly one machine on earth, and a feature that runs for the person who built
// it and nobody else is a feature that does not exist -- this project has shipped
// that mistake once already and wrote it down.
//
// macOS 26 has `SpeechAnalyzer`, which is not the old `SFSpeechRecognizer` the
// quality judgement was made against. Measured on the same recording that was
// used to choose Qwen:
//
//   Hey, I'm sitting right here next to you.  |  Listen to where my voice is
//   coming from.  |  Can you tell the difference?
//
// Word by word, correct, with sentence boundaries of its own, 6.4 seconds of
// audio in 0.18 -- and it needs no daemon, no model download, no megabytes in the
// bundle, and (checked, because it decides whether this can ship at all) NO
// authorization prompt: `SFSpeechRecognizer.authorizationStatus()` is still
// `notDetermined` after a full transcription. On-device assets, no TCC.
//
// So: Qwen when it is there, this when it is not, and the log says which.
//
// ── WHAT IS LOST WITHOUT QWEN ────────────────────────────────────────────────
//
// Smart-turn's "has this sentence landed" probability, which is what ends an
// utterance on a completed thought rather than on a silence. This engine emits
// its own `isFinal` per sentence, which is the same boundary arrived at a
// different way, so the caption still commits sentence by sentence -- but the
// gate's handover cannot use prosody. Said out loud rather than papered over.
@available(macOS 26.0, *)
final class AppleSpeech: @unchecked Sendable {
  /// `(text, isFinal)`. Volatile results carry the sentence so far and are
  /// replaced; a final commits it and the next one starts fresh.
  var onText: ((String, Bool) -> Void)?
  private(set) var available = false
  private(set) var words = 0

  private var cont: AsyncStream<AnalyzerInput>.Continuation?
  private var analyzer: SpeechAnalyzer?
  private var conv: AVAudioConverter?
  private var target: AVAudioFormat?
  /// What `Subtitles.feed` produces: 16 kHz mono float. Fixed, so the converter
  /// is built once rather than per buffer.
  private let source = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: Subtitles.RATE, channels: 1,
                                     interleaved: false)!
  private let lock = NSLock()

  func start() {
    Task { [weak self] in await self?.bringUp() }
  }

  private func bringUp() async {
    guard await SpeechTranscriber.isAvailable else {
      fputs("subtitles: the system recogniser is not available here\n", stderr); return
    }
    // ── `.fastResults`, WHICH IS THE DIFFERENCE BETWEEN USABLE AND NOT ───────
    //
    // Measured on the same recording, fed in real time at 40 and 120 ms:
    //
    //   .volatileResults                 first word at 3882 ms, then in ~4 s batches
    //   .volatileResults + .fastResults  first word at  989 ms, then every ~960 ms
    //
    // Neither the analyzer's `priority` nor the size of the buffers handed to it
    // moves that cadence, so ~1 s is what this engine costs and the flag is worth
    // three seconds of it. The daemon path revises about three times a second, so
    // the fallback IS slower and the number is written down rather than implied.
    //
    // A second late is acceptable here and would not be for the cue: the caption
    // was never the fast channel. The floor cue crosses in 0-1 ms and is what
    // stops people talking over each other; these are the words, and a person
    // takes about a second to read a line of them anyway.
    let t = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                              transcriptionOptions: [],
                              reportingOptions: [.volatileResults, .fastResults],
                              attributeOptions: [])
    // Assets are a system download, not a bundle payload. Usually already there;
    // when they are not this is a one-off and the call carries on without words
    // until it finishes.
    do {
      if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
        fputs("subtitles: fetching the system speech model…\n", stderr)
        try await req.downloadAndInstall()
      }
    } catch {
      fputs("subtitles: could not install the system speech model (\(error))\n", stderr)
      return
    }
    let a = SpeechAnalyzer(modules: [t],
                           options: SpeechAnalyzer.Options(priority: .high,
                                                           modelRetention: .whileInUse))
    guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]),
          let c = AVAudioConverter(from: source, to: fmt) else {
      fputs("subtitles: the system recogniser wants a format we cannot make\n", stderr); return
    }
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    lock.lock(); analyzer = a; conv = c; target = fmt; cont = continuation; lock.unlock()

    Task { [weak self] in
      do {
        for try await r in t.results {
          let s = String(r.text.characters).trimmingCharacters(in: .whitespaces)
          guard !s.isEmpty else { continue }
          self?.words += 1
          self?.onText?(s, r.isFinal)
        }
      } catch {
        fputs("subtitles: the system recogniser stopped (\(error))\n", stderr)
        self?.available = false
      }
    }
    do { try await a.start(inputSequence: stream) } catch {
      fputs("subtitles: the system recogniser would not start (\(error))\n", stderr); return
    }
    available = true
    fputs("subtitles: using the system recogniser (on-device, no daemon)\n", stderr)
  }

  /// 16 kHz mono float, the same thing the daemon path is handed. Safe from any
  /// thread: `AsyncStream.Continuation.yield` is the one part of this API that is.
  func feed(_ x: [Float]) {
    lock.lock()
    let c = conv, fmt = target, k = cont
    lock.unlock()
    guard let c, let fmt, let k, !x.isEmpty else { return }
    guard let inBuf = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(x.count)),
          let ch = inBuf.floatChannelData?[0] else { return }
    x.withUnsafeBufferPointer { ch.update(from: $0.baseAddress!, count: x.count) }
    inBuf.frameLength = AVAudioFrameCount(x.count)
    let outCap = AVAudioFrameCount(Double(x.count) * fmt.sampleRate / source.sampleRate) + 1024
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: outCap) else { return }
    var done = false
    var err: NSError?
    c.convert(to: outBuf, error: &err) { _, s -> AVAudioBuffer? in
      if done { s.pointee = AVAudioConverterInputStatus.noDataNow; return nil }
      done = true; s.pointee = AVAudioConverterInputStatus.haveData; return inBuf
    }
    guard err == nil, outBuf.frameLength > 0 else { return }
    k.yield(AnalyzerInput(buffer: outBuf))
  }

  /// The far end has stopped. Nothing is forced: this engine finds its own
  /// sentence boundaries and cutting it off mid-word would lose the last one.
  func stop() {
    lock.lock(); let k = cont; cont = nil; lock.unlock()
    k?.finish()
    available = false
  }
}
