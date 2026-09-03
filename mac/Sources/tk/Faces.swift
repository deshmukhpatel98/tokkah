import AppKit
import CoreImage
import CoreVideo

// ── THE FRONT DOOR LEARNS WHAT YOUR PEOPLE LOOK LIKE ─────────────────────────
//
// The home screen's stated job is "tap a name to call someone you have called
// before", and it was drawing those people as coloured initials -- in an app
// whose whole business is putting their actual face on this screen. Every call
// decodes thousands of frames of the person; keeping one of them is what makes
// the list read as PEOPLE rather than as a phonebook.
//
// The picture is taken FROM A CALL YOU WERE IN -- your own record of a
// conversation you attended, like a photo in your own camera roll. It never
// crosses the wire (the wire already carried it, inward), it is never uploaded,
// and it lives in the same 0o700 directory as the identity key. CONTACTS.md's
// rule that a NAME over the wire is an unverifiable claim does not apply: this
// is not a claim somebody sent, it is what this machine itself saw.
//
// One face per handle, overwritten on later calls, newest wins. Faces are only
// saved when the call knows WHO it is with (a ring in either direction carries
// the handle); a word-room call with no handle saves nothing, because a face
// filed under a room name would surface under whoever uses that word next.
enum Faces {
  private static var dir: URL {
    Identity.dir.appendingPathComponent("faces", isDirectory: true)
  }
  private static func file(_ handle: String) -> URL {
    dir.appendingPathComponent(handle + ".jpg")
  }

  /// Cache with NEGATIVE entries: the home list redraws on every hover, and a
  /// row whose person has no picture must not cost a disk stat per frame of
  /// pointer movement. `NSNull` is "looked, nothing there".
  private static let lock = NSLock()
  nonisolated(unsafe) private static var cache: [String: Any] = [:]

  static func image(_ handle: String) -> NSImage? {
    lock.lock(); defer { lock.unlock() }
    if let hit = cache[handle] { return hit as? NSImage }
    let img = NSImage(contentsOf: file(handle))
    cache[handle] = img ?? NSNull()
    return img
  }

  /// One CIContext, reused: the save path runs at most every couple of minutes
  /// and a context per save would still be the expensive way to do it.
  private static let ci = CIContext(options: [.useSoftwareRenderer: false])

  /// Save the centre square of a decoded frame as this person's face, 256 px --
  /// big enough for the 68 pt calling card at any plausible backing scale, small
  /// enough (~10 KB) that a lifetime of contacts costs less than one photo.
  ///
  /// Called from the report thread, never from a media callback: the crop and
  /// JPEG encode are milliseconds, which is nothing at 1 Hz and an eternity in
  /// an audio block.
  static func save(_ handle: String, from buffer: CVImageBuffer) {
    guard Identity.sanitize(handle) == handle else { return }
    var img = CIImage(cvImageBuffer: buffer)
    let e = img.extent
    guard e.width >= 64, e.height >= 64 else { return }
    // The centre square: a talking head sits in the middle of a video call
    // frame. Smarter cropping (the face detector) runs on the LOCAL camera only
    // and its verdicts are about the local person -- reusing it here would need
    // a second Vision pipeline on the remote stream for a thumbnail.
    let side = min(e.width, e.height)
    img = img.cropped(to: CGRect(x: e.midX - side / 2, y: e.midY - side / 2,
                                 width: side, height: side))
    let scale = 256 / side
    img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    guard let cg = ci.createCGImage(img, from: img.extent) else { return }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let jpeg = rep.representation(using: .jpeg,
                                        properties: [.compressionFactor: 0.8]) else { return }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let tmp = file(handle).appendingPathExtension("tmp")
    do {
      try jpeg.write(to: tmp)
      try FileManager.default.moveItem(at: tmp, to: {
        try? FileManager.default.removeItem(at: file(handle)); return file(handle)
      }())
      lock.lock(); cache[handle] = nil; lock.unlock()
      Metrics.count("face_saved")
    } catch {
      try? FileManager.default.removeItem(at: tmp)
    }
  }
}

// ── WHO CAN BE REACHED, RIGHT NOW ─────────────────────────────────────────────
//
// The one question the front door could not answer: is tapping this name going
// to reach a person, or ring a Mac that has been asleep since Tuesday? The
// server already knows -- every reachable Mac holds a poll open on its own
// mailbox -- and /api/kin/presence says it out loud. See the worker's note on
// why the route is at ring parity: ringing somebody already reveals this, and
// louder.
//
// The answer paints a dot and REORDERS NOTHING. Rows that shuffle under a
// pointer are how a stray click rings the wrong person
// (`a-list-of-people-under-a-self-raising-window`), so the order is fixed at
// build and presence only ever changes a colour.
enum Presence {
  /// Rig override: `TK_PRESENCE_FAKE="arjun=1,meera=0"`. A rig cannot make the
  /// real server hold polls for pretend people, and a presence dot that has
  /// only ever been audited grey is an instrument blind to its own positive
  /// (`feature-behind-a-flag-nobody-runs`).
  // ── ONE PERSON, ASKED BEFORE THE RING, WITH THE ANSWER IN HAND ─────────────
  //
  // `fetch` paints dots and is allowed to be wrong for a moment; this decides
  // whether a call happens at all, so it is synchronous (call it off main, like
  // `Identity.ring`) and it keeps its three states apart. `registered == false`
  // is the only answer that STOPS a ring: a name nobody has claimed is not a
  // person, and ringing it opened a call window that said "calling @meeraa…"
  // for ever. `here == false` merely changes what the card says while the ring
  // goes out -- a quiet Mac may still wake to it. Any transport failure is
  // `nil` twice and the ring proceeds exactly as it did before this existed
  // (`blind-instruments-report-negatives`).
  struct Answer { var registered: Bool?; var here: Bool? }
  static func ask(_ handle: String) -> Answer {
    if let fake = ProcessInfo.processInfo.environment["TK_PRESENCE_FAKE"] {
      // `name=1` here, `name=0` registered and quiet, `name=x` never claimed.
      for pair in fake.split(separator: ",") {
        let kv = pair.split(separator: "=")
        guard kv.count == 2, kv[0] == handle[...] else { continue }
        if kv[1] == "x" { return Answer(registered: false, here: false) }
        return Answer(registered: true, here: kv[1] == "1")
      }
      return Answer()
    }
    guard let who = Identity.sanitize(handle),
          let url = URL(string: Server.base + "/api/kin/presence?who=" + who) else { return Answer() }
    var req = URLRequest(url: url)
    req.timeoutInterval = 4
    req.cachePolicy = .reloadIgnoringLocalCacheData
    var out = Answer()
    let sem = DispatchSemaphore(value: 0)
    Http.session.dataTask(with: req) { data, _, _ in
      defer { sem.signal() }
      guard let data,
            let o = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
            let v = o[who] else { return }
      out.registered = v["registered"] as? Bool
      out.here = v["here"] as? Bool
    }.resume()
    _ = sem.wait(timeout: .now() + 5)
    return out
  }

  static func fetch(_ handles: [String], done: @escaping ([String: Bool]) -> Void) {
    if let fake = ProcessInfo.processInfo.environment["TK_PRESENCE_FAKE"] {
      var out: [String: Bool] = [:]
      for pair in fake.split(separator: ",") {
        let kv = pair.split(separator: "=")
        if kv.count == 2 { out[String(kv[0])] = kv[1] == "1" }
      }
      DispatchQueue.main.async { done(out) }
      return
    }
    let who = handles.compactMap { Identity.sanitize($0) }.prefix(12)
    guard !who.isEmpty,
          let url = URL(string: Server.base + "/api/kin/presence?who="
                        + who.joined(separator: ",")) else { return }
    var req = URLRequest(url: url)
    req.timeoutInterval = 6
    Http.session.dataTask(with: req) { data, _, _ in
      guard let data,
            let o = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
      else { return }
      var out: [String: Bool] = [:]
      for (h, v) in o { out[h] = v["here"] as? Bool ?? false }
      DispatchQueue.main.async { done(out) }
    }.resume()
  }
}

// ── "YESTERDAY", NOT A TIMESTAMP ──────────────────────────────────────────────
//
// The list is ordered by recency, and the order is only legible if the rows say
// why. Buckets, not arithmetic precision: "3w" and "25d" are the same fact to a
// person, and the coarser spelling never needs updating while the window sits
// open.
enum Relative {
  static func time(_ then: Double, now: Double = Date().timeIntervalSince1970) -> String {
    let s = now - then
    guard s >= 0 else { return "" }
    if s < 90 { return "just now" }
    if s < 3600 { return "\(Int(s / 60))m ago" }
    if s < 86400 * 2 { return s < 86400 && Calendar.current.isDateInToday(
      Date(timeIntervalSince1970: then)) ? "today" : "yesterday" }
    if s < 86400 * 7 { return "\(Int(s / 86400))d ago" }
    if s < 86400 * 30 { return "\(Int(s / 86400 / 7))w ago" }
    return "\(Int(s / 86400 / 30))mo ago"
  }
}
