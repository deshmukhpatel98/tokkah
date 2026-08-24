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
  nonisolated(unsafe) static var endpoint = "https://room.tokkah.com/api/mac/beat"
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
  /// `done` fires when the request has finished, however it finished. It exists
  /// for the two paths that post and then immediately `exit(0)`: without it the
  /// FINAL beat of every call was handed to URLSession and then killed with the
  /// process a microsecond later, so the record the dashboard cares about most
  /// was the one least likely to arrive. Measured against a local sink: not one
  /// final beat from the Leave button was delivered. It is called on every exit
  /// from this function, including the two `guard`s, so a waiter can never be
  /// left holding a semaphore that nothing will signal.
  static func post(_ fields: [String: Any], final: Bool = false,
                   done: (@Sendable () -> Void)? = nil) {
    guard enabled else { done?(); return }
    var f = fields
    f["install"] = install
    f["call"] = call
    // The row this one continues, when an answered ring or a followed link
    // replaced the image mid-call. Absent on a call that began at launch.
    if let prev = arg("prev-call") { f["prev_call"] = prev }
    f["version"] = VERSION
    f["model"] = model
    f["phase"] = final ? "final" : "live"
    guard let body = try? JSONSerialization.data(withJSONObject: f) else { done?(); return }
    guard let url = URL(string: endpoint) else { done?(); return }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.httpBody = body
    // Short timeout: this is a report about a live call, and one that takes ten
    // seconds to deliver is describing the past.
    req.timeoutInterval = final ? 6 : 4
    URLSession.shared.dataTask(with: req) { _, resp, err in
      if let err {
        failed += 1
        lastError = err.localizedDescription
      } else if let h = resp as? HTTPURLResponse, h.statusCode >= 300 {
        failed += 1
        lastError = "http \(h.statusCode)"
      } else {
        sent += 1
      }
      done?()
    }.resume()
  }
}
