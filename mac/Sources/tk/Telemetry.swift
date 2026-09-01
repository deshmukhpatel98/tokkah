import Foundation

// ── What the call actually did, visible from somewhere other than a terminal ──
//
// Every diagnostic this program has ever produced went to stderr and then
// vanished. That is fine while the person reading it is the person who wrote it,
// and useless the moment the app is on someone else's Mac: a call goes badly,
// they say "it was choppy", and there is nothing to look at.
//
// So a call posts a compact summary of itself every few seconds, and again when
// it ends. Not audio, not the room, not anything about who is talking -- the
// numbers this project already prints, sent somewhere they survive.
//
// WHAT IS DELIBERATELY NOT SENT:
//   * The room name. It is the crypto salt. It must never leave the two machines,
//     so a per-call random id is used instead and there is no way back from it to
//     a room.
//   * Any audio or video, in any form, ever.
//   * Anything identifying the person. The install id is a random number made
//     once, and its only purpose is telling "one Mac, six calls" apart from
//     "six Macs, one call each".
enum Telemetry {
  nonisolated(unsafe) static var enabled = true
  nonisolated(unsafe) static var endpoint = Server.base + "/api/mac/beat"
  /// Where a crash goes. Its own route because a crash is not a beat: it belongs
  /// to a PREVIOUS process, it is stored in its own table, and it must not be
  /// rate limited into oblivion by a machine that is also making calls.
  ///
  /// Derived from `endpoint` whenever that is set, so `--tel-endpoint` remains
  /// the single control and a rig pointing beats at a local sink cannot
  /// accidentally leave crashes going to production -- which is the shape of
  /// mistake that has sent rig traffic to the real server before.
  nonisolated(unsafe) static var crashEndpoint = Server.base + "/api/mac/crash"
  static func aimAt(_ beat: String) {
    endpoint = beat
    crashEndpoint = beat.hasSuffix("/beat") ? String(beat.dropLast(4)) + "crash" : beat
  }
  /// Random per install, so repeat calls from one machine can be grouped without
  /// knowing whose machine it is.
  nonisolated(unsafe) private(set) static var install: String = {
    let k = "tk.installId"
    if let v = UserDefaults.standard.string(forKey: k) { return v }
    let v = String(UInt64.random(in: 0..<UInt64.max), radix: 36)
    UserDefaults.standard.set(v, forKey: k)
    return v
  }()
  /// Random per process. This is what the dashboard groups a call by, and it is
  /// unrelated to the room, on purpose.
  nonisolated(unsafe) static let call = String(UInt64.random(in: 0..<UInt64.max), radix: 36)

  nonisolated(unsafe) static var sent = 0
  nonisolated(unsafe) static var failed = 0
  nonisolated(unsafe) static var lastError = ""

  /// Model identifier, so "this is slow" can be read against what it is running
  /// on. `hw.model` is the machine type, not a serial number.
  nonisolated(unsafe) static let model: String = {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    guard size > 0 else { return "mac" }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &buf, &size, nil, 0)
    return String(cString: buf)
  }()

  /// Fire and forget, on a background queue. A beat must never delay a call:
  /// nothing here runs on the audio path, and a failure is counted and dropped
  /// rather than retried, because a stale beat is worth less than a fresh one.
  /// `done` fires when the request has finished, however it finished, and says
  /// WHETHER IT LANDED. It exists for the two paths that post and then
  /// immediately `exit(0)`: without it the FINAL beat of every call was handed to
  /// URLSession and then killed with the process a microsecond later, so the
  /// record the dashboard cares about most was the one least likely to arrive.
  /// Measured against a local sink: not one final beat from the Leave button was
  /// delivered. It is called on every exit from this function, including the
  /// three `guard`s, so a waiter can never be left holding a semaphore that
  /// nothing will signal.
  ///
  /// The Bool was added for crash reporting, where it is load bearing rather than
  /// informational: the mark that stops a crash being sent twice is written only
  /// when this says the server took it, and reading the shared `sent` counter
  /// instead would race with whatever beat the live call posted in the meantime.
  /// One small beat from the background watcher: this Mac is alive, on this
  /// version, and here is what it last did about updating itself.
  ///
  /// The watcher never posted ANYTHING, and that is the whole reason "why did
  /// the Mac mini not update" was unanswerable: every row in the dashboard is
  /// written by a call, so a Mac is visible only while somebody is talking on
  /// it -- and the machine being asked about was exactly the one that had
  /// stopped calling. A Mac that updated late and a Mac that made no calls
  /// produced identical evidence: none.
  ///
  /// Cheap on purpose. It rides the update check, so it is one small POST every
  /// 30 minutes -- 48 a day from a machine that is idle anyway -- and it carries
  /// only what a fleet view needs. `phase: "watch"` keeps it out of the call
  /// listings, which group by `call` and would otherwise show a zero-length call
  /// per heartbeat.
  static func watchBeat(_ extra: [String: Any] = [:]) {
    guard enabled else { return }
    var f: [String: Any] = ["uptime_s": sinceLaunch() / 1000]
    for (k, v) in extra { f[k] = v }
    let m = Metrics.snapshot()
    if !m.facts.isEmpty { f["facts"] = m.facts }
    if !m.counts.isEmpty { f["events"] = m.counts }
    post(f, phase: "watch")
  }

  static func post(_ fields: [String: Any], to url0: String? = nil, final: Bool = false,
                   phase: String? = nil,
                   done: (@Sendable (Bool) -> Void)? = nil) {
    guard enabled else { done?(false); return }
    var f = fields
    f["install"] = install
    f["call"] = call
    // The row this one continues, when an answered ring or a followed link
    // replaced the image mid-call. Absent on a call that began at launch.
    if let prev = arg("prev-call") { f["prev_call"] = prev }
    f["version"] = VERSION
    f["model"] = model
    f["phase"] = phase ?? (final ? "final" : "live")
    if unreadable > 0 { f["beat_unreadable_total"] = unreadable }
    if repaired > 0 { f["beat_repaired_total"] = repaired }
    // ── A SINGLE NaN USED TO END THE PROCESS ────────────────────────────────
    //
    // `JSONSerialization.data(withJSONObject:)` does not throw on a non-finite
    // number -- it raises `NSInvalidArgumentException`, an ObjC exception, which
    // Swift cannot catch and `try?` does not see. Measured, on this machine:
    //
    //     *** Terminating app due to uncaught exception 'NSInvalidArgumentException',
    //         reason: 'Invalid number value (NaN) in JSON write'
    //
    // Every beat is built from ratios -- percentages of a call, per-second rates,
    // ERLE in dB, means of a window -- and there was not one `isFinite` anywhere
    // on the path. Any one of those dividing by a zero denominator (a call with no
    // frames yet, a window with nothing in it, a device that never opened) killed
    // the app MID-CALL, at the next beat, from a diagnostic. Sibling of
    // `objc-setters-raise-and-swift-cannot-catch`: the guard has to be BEFORE the
    // call, because there is no after.
    //
    // The offenders are counted and named rather than dropped in silence: a beat
    // that quietly loses a field looks exactly like a build that never had it.
    var nonFinite: [String] = []
    f = (Telemetry.finite(f, path: "", bad: &nonFinite) as? [String: Any]) ?? f
    if !nonFinite.isEmpty {
      f["beat_nonfinite"] = nonFinite.count
      f["beat_nonfinite_keys"] = nonFinite.prefix(8).joined(separator: ",")
    }
    guard let body = try? JSONSerialization.data(withJSONObject: f) else { done?(false); return }
    keep(body)
    guard let url = URL(string: url0 ?? endpoint) else { done?(false); return }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.httpBody = body
    // Short timeout: this is a report about a live call, and one that takes ten
    // seconds to deliver is describing the past.
    req.timeoutInterval = final ? 6 : 4
    URLSession.shared.dataTask(with: req) { _, resp, err in
      var ok = false
      if let err {
        failed += 1
        lastError = err.localizedDescription
      } else if let h = resp as? HTTPURLResponse, h.statusCode >= 300 {
        failed += 1
        lastError = "http \(h.statusCode)"
      } else {
        sent += 1
        ok = true
      }
      done?(ok)
    }.resume()
  }

  // ── AND A COPY ON THIS MACHINE ─────────────────────────────────────────────
  //
  // Every beat used to exist in exactly one place: a Durable Object behind a key
  // that lives in a browser cookie on one Mac and a `wrangler secret` nothing can
  // read back. So a real complaint about a real call was investigated out of a
  // STDERR LOG, because the telemetry built to answer exactly that question could
  // not be opened -- not from this Mac, not from anywhere.
  //
  // The same JSON that goes to the server is appended here first. It costs one
  // append per beat, it survives the network being down and the server refusing,
  // and it is the copy that is still there when somebody asks "what happened on
  // that call" an hour later.
  //
  // Written BEFORE the request, deliberately: a beat that fails to send is
  // exactly the one worth having on disk.
  nonisolated(unsafe) private static var beatFile: FileHandle?
  nonisolated(unsafe) private static var beatBytes = 0
  // A call is ~24 beats of ~3 KB. 32 MB is months of them, and the oldest are
  // dropped whole-file rather than truncated: a half-written JSON line read by a
  // tolerant parser is worse than no line, because it reads as a beat that was
  // BLIND rather than one that is missing.
  private static let BEAT_MAX = 32 * 1024 * 1024
  static func beatLogURL() -> URL {
    Watch.logDir().appendingPathComponent("beats.ndjson")
  }
  /// Every non-finite number replaced by null, recursively, with the keys that
  /// were replaced reported back. Doubles, Floats, CGFloats and NSNumbers all
  /// arrive here as `Any`; each is asked the only question that matters.
  private static func finite(_ v: Any, path: String, bad: inout [String]) -> Any {
    switch v {
    // BOOL FIRST. An NSNumber holding a bool satisfies `as? Double` -- so without
    // this line `true` would be rewritten as `1` on its way through a guard whose
    // only business is non-finite numbers. A sanitiser that changes a type it was
    // not asked about is a second fault.
    case is Bool: return v
    case let d as Double:
      if d.isFinite { return d }; bad.append(path); return NSNull()
    case let f as Float:
      if f.isFinite { return Double(f) }; bad.append(path); return NSNull()
    case let n as NSNumber:
      // A bridged Float/Double arrives as NSNumber on some paths. `doubleValue`
      // of a NaN NSNumber is a NaN, which is the thing being caught.
      if n.doubleValue.isFinite { return n }; bad.append(path); return NSNull()
    case let m as [String: Any]:
      var out: [String: Any] = [:]
      out.reserveCapacity(m.count)
      for (k, sub) in m { out[k] = finite(sub, path: path.isEmpty ? k : path + "." + k, bad: &bad) }
      return out
    case let a as [Any]:
      return a.enumerated().map { finite($1, path: "\(path)[\($0)]", bad: &bad) }
    default:
      return v
    }
  }

  /// How many beats this process could not write as valid JSON. Reported in the
  /// next beat, so the fault names itself instead of leaving a line no parser can
  /// read -- see `keep`.
  nonisolated(unsafe) static var unreadable = 0
  /// How many beats had to have a comma removed before they were valid JSON.
  nonisolated(unsafe) static var repaired = 0

  // ── A STRICT READER, BECAUSE APPLE'S IS NOT ────────────────────────────────
  //
  // 366 of 1824 lines in the real beat log end `,}` -- one comma too many, which
  // RFC 8259 forbids and every strict parser refuses. The reason nobody noticed
  // for months is measured here:
  //
  //     JSONSerialization.jsonObject(with: "{\"a\":1,}")   -> ACCEPTS
  //     JSONDecoder().decode(...,        from: "{\"a\":1,}")   -> ACCEPTS
  //     python3 json.loads("{\"a\":1,}")                    -> refuses
  //
  // So the writer that produced these lines and the reader that would have
  // caught them are the same tolerant stack, and the first thing to read the file
  // strictly was a person with python. A round-trip check through
  // `JSONSerialization` is therefore worth nothing HERE, which is the whole
  // reason this scanner exists. `size-guard-corrupts-the-record` is the same
  // lesson from the other end: a tolerant parser turns a damaged record into a
  // confident wrong answer.
  //
  // It is a scanner and not a parser: it tracks strings and escapes (so a comma
  // inside a value is not a fault), and reports the two things that actually
  // happen -- a comma before a closer, and a document that ends unclosed.
  static func strictFault(_ d: Data) -> String? {
    var inString = false, escaped = false
    var depth = 0
    var lastSignificant: UInt8 = 0
    for b in d {
      if escaped { escaped = false; continue }
      if inString {
        if b == 0x5C { escaped = true }         // backslash
        else if b == 0x22 { inString = false; lastSignificant = b }
        continue
      }
      switch b {
      case 0x22: inString = true; lastSignificant = b          // "
      case 0x7B, 0x5B: depth += 1; lastSignificant = b          // { [
      case 0x7D, 0x5D:                                          // } ]
        if lastSignificant == 0x2C { return "comma before a closer" }
        depth -= 1
        if depth < 0 { return "closed more than it opened" }
        lastSignificant = b
      case 0x20, 0x09, 0x0A, 0x0D: continue                     // whitespace
      default: lastSignificant = b
      }
    }
    if inString { return "ends inside a string" }
    if depth != 0 { return "ends with \(depth) unclosed" }
    return nil
  }

  /// Every comma that sits directly before a closer, removed. Nothing else is
  /// touched -- a repair that rewrites more than the fault is a second fault.
  static func dropTrailingCommas(_ d: Data) -> Data? {
    var out = [UInt8](); out.reserveCapacity(d.count)
    var inString = false, escaped = false
    var pendingComma = -1                        // index in `out` of a comma we may drop
    for b in d {
      if escaped { out.append(b); escaped = false; continue }
      if inString {
        out.append(b)
        if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
        continue
      }
      switch b {
      case 0x2C:                                 // ,
        out.append(b); pendingComma = out.count - 1
      case 0x7D, 0x5D:                           // } ]
        if pendingComma >= 0 {
          // Only whitespace may sit between the comma and the closer.
          let between = out[(pendingComma + 1)...]
          if between.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) {
            out.removeSubrange(pendingComma..<out.count)
          }
        }
        out.append(b); pendingComma = -1
      case 0x20, 0x09, 0x0A, 0x0D: out.append(b)
      case 0x22: inString = true; out.append(b); pendingComma = -1
      default: out.append(b); pendingComma = -1
      }
    }
    return out.isEmpty ? nil : Data(out)
  }

  private static func keep(_ body: Data) {
    queue.sync {
      if beatFile == nil {
        let u = beatLogURL()
        if !FileManager.default.fileExists(atPath: u.path) {
          FileManager.default.createFile(atPath: u.path, contents: nil)
        }
        // ── O_APPEND, BECAUSE TWO KINS SHARE THIS FILE ──────────────────────
        //
        // `FileHandle(forWritingTo:)` + `seekToEnd()` gives each PROCESS its own
        // file offset, stamped once at open. This path is `~/Library/Logs/Kin`,
        // which is fixed -- it does not move with `TK_KIN_DIR` -- so a second Kin
        // (a rig, a second install, the app while a rig runs) writes at ITS own
        // advancing offset, straight over the first one's records. Measured in the
        // real file: 9 lines with two records spliced into one and 17 that begin
        // mid-token, out of 1824.
        //
        // `O_APPEND` makes every write land at the true end of the file under the
        // kernel's own lock, which is the whole fix: two processes can no longer
        // overwrite each other, and a single `write` of one line is atomic.
        let fd = open(u.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        beatFile = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
        beatBytes = (try? FileManager.default
          .attributesOfItem(atPath: u.path)[.size] as? Int) as? Int ?? 0
      }
      guard let h = beatFile else { return }
      if beatBytes > BEAT_MAX {
        try? h.truncate(atOffset: 0)
        // AND SEEK. Under O_APPEND the offset is recomputed per write, so this is
        // belt and braces -- but the old handle was NOT in append mode and kept a
        // 32 MB offset across the truncate, which would have left a 32 MB hole of
        // zero bytes at the front of the file. A hole reads as neither a beat nor
        // an absence.
        try? h.seek(toOffset: 0)
        beatBytes = 0
      }
      // ── AND IT IS CHECKED BEFORE IT IS WRITTEN ────────────────────────────
      //
      // 366 lines of the real file end in `,}` -- valid JSON with one comma too
      // many, which every strict parser refuses. `JSONSerialization` cannot
      // produce that, so something on the way to disk did, and the record was
      // useless by the time anybody looked. A tolerant parser makes it worse:
      // `size-guard-corrupts-the-record` is the same lesson, where a half-written
      // line read as a beat that was BLIND rather than one that was missing.
      //
      // So the line is parsed back before it is appended. A line that does not
      // round-trip is replaced by a SHORT record that says so and carries its own
      // tail, which is both readable and diagnostic -- and the count goes into the
      // next beat, so the server sees the fault without anybody reading this file.
      var line = body
      if let fault = Telemetry.strictFault(body) {
        // A comma too many is the fault the real file has, 366 lines of it, and
        // the record on either side of that comma is perfectly good -- so it is
        // REPAIRED rather than thrown away. Anything else becomes a short record
        // that says what it was, which is readable and diagnostic where the
        // original was neither.
        if let fixed = Telemetry.dropTrailingCommas(body), Telemetry.strictFault(fixed) == nil {
          repaired += 1
          line = fixed
        } else {
          unreadable += 1
          let tail = String(decoding: body.suffix(90), as: UTF8.self)
            .replacingOccurrences(of: "\"", with: "'")
          let alt = "{\"beat_unreadable\":1,\"why\":\"\(fault)\","
                  + "\"bytes\":\(body.count),\"tail\":\"\(tail)\"}"
          line = Data(alt.utf8)
        }
      }
      line.append(0x0a)
      try? h.write(contentsOf: line)
      beatBytes += line.count
    }
  }
  private static let queue = DispatchQueue(label: "tk.beatlog")

  /// ── WHAT THE WRITER DOES WITH A BEAT IT CANNOT ENCODE ──────────────────────
  ///
  /// Three arms, and the middle one is the whole point: an input that MUST be
  /// rejected, per `validate-the-ruler-against-known-inputs`. Prints to stdout and
  /// exits, so a rig reads a verdict rather than inferring one from silence.
  static func selftestBeat() -> Never {
    var ok = true
    func say(_ good: Bool, _ what: String) {
      print("  \(good ? "OK  " : "FAIL") \(what)"); if !good { ok = false }
    }
    // 1. The walk itself, on values that are all finite: nothing is touched.
    var bad: [String] = []
    let clean: [String: Any] = ["a": 1.5, "b": ["c": 2.0, "d": [1.0, 2.0]], "s": "x", "i": 7]
    _ = finite(clean, path: "", bad: &bad)
    say(bad.isEmpty, "a beat with no non-finite values reports none (\(bad.count))")
    // 2. THE INPUT IT MUST REJECT. A NaN at the top level, an Inf inside a nested
    // object, and a NaN inside an array -- the three shapes a beat really has.
    bad = []
    let dirty: [String: Any] = ["pct": Double.nan,
                                "nest": ["erle_db": Double.infinity, "fine": 3.0],
                                "arr": [1.0, Float.nan],
                                "kept": 42]
    let fixed = finite(dirty, path: "", bad: &bad) as? [String: Any] ?? [:]
    say(bad.count == 3, "three non-finite values found in three shapes (\(bad.count)): \(bad.sorted())")
    say(bad.contains("pct") && bad.contains("nest.erle_db"),
        "and each is named by its full path")
    say((fixed["kept"] as? Int) == 42, "the fields around them survive")
    // The proof that matters: it can now be encoded at all. Before the sanitizer
    // this line was an uncatchable NSInvalidArgumentException and the process died.
    let encoded = try? JSONSerialization.data(withJSONObject: fixed)
    say(encoded != nil, "and the result encodes -- the call that used to abort the app")
    if let d = encoded, let s = String(data: d, encoding: .utf8) {
      say(s.contains("null"), "with the offenders written as null: \(s.prefix(60))…")
    } else { say(false, "no encoded form to inspect") }
    // 3. THE READER, on the inputs it must accept and the ones it must refuse --
    // including the two Apple's own parsers accept, which is why this exists.
    say(strictFault(Data("{\"a\":1,\"b\":[1,2],\"s\":\"x,}\"}".utf8)) == nil,
        "a good record with a comma and a brace INSIDE a string is not a fault")
    say(strictFault(Data("{\"a\":1,}".utf8)) != nil,
        "a trailing comma IS a fault (JSONSerialization and JSONDecoder both accept it)")
    say(strictFault(Data("{\"a\":[1,2,]}".utf8)) != nil, "and so is one inside an array")
    say(strictFault(Data("{\"a\":1".utf8)) != nil, "an unclosed record is a fault")
    say(strictFault(Data("{\"a\":\"x".utf8)) != nil, "so is one that ends inside a string")
    // 4. THE REPAIR. The fault the real file has, and the record either side of
    // the comma is good -- so it is mended rather than discarded.
    if let fixed = dropTrailingCommas(Data("{\"a\":1,\"b\":[1,2,],}".utf8)),
       let str = String(data: fixed, encoding: .utf8) {
      say(strictFault(fixed) == nil && str == "{\"a\":1,\"b\":[1,2]}",
          "both commas removed and nothing else changed: \(str)")
    } else { say(false, "the repair produced nothing") }
    if let kept = dropTrailingCommas(Data("{\"s\":\"a,]\"}".utf8)),
       let str = String(data: kept, encoding: .utf8) {
      say(str == "{\"s\":\"a,]\"}", "a comma inside a string survives the repair: \(str)")
    } else { say(false, "the repair ate a string") }
    // 5. And end to end, through the writer, into the file.
    let before = repaired
    keep(Data("{\"beat_selftest\":1,}".utf8))
    say(repaired == before + 1, "a beat with a comma too many is repaired on the way out")
    if let tail = (try? String(contentsOf: beatLogURL(), encoding: .utf8))?
                    .split(separator: "\n").last(where: { !$0.isEmpty }) {
      say(strictFault(Data(tail.utf8)) == nil && tail.contains("beat_selftest"),
          "and what lands in the file is strictly valid: \(tail.prefix(70))")
    } else { say(false, "could not read the beat log back") }
    let b2 = unreadable
    keep(Data("{\"a\":1".utf8))
    say(unreadable == b2 + 1, "a record that cannot be mended is counted and replaced")
    print(ok ? "BEAT SELFTEST PASSED -- a NaN is named and dropped, a comma too many is mended"
             : "BEAT SELFTEST FAILED")
    exit(ok ? 0 : 1)
  }
}
