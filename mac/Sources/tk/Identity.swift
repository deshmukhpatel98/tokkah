import Foundation
import CryptoKit

// ── WHO THIS MAC IS ──────────────────────────────────────────────────────────
//
// A link is a fine way to start a call with someone you have never called. It is
// a terrible way to call your sister. So every install gets a handle -- a short
// name someone can type or tap -- and it is NEVER ASKED FOR. Being made to
// choose a name before your first call is a hurdle in front of the one thing the
// app is for, so the name is taken from the Mac and can be changed later by
// someone who cares.
//
// `Devesh's MacBook Air` and `Devesh Patel` both mean `devesh`, which is the
// point: the handle should already be the thing you would have typed.
//
// ── THE KEY IS THE OWNERSHIP, AND THE FILE IS THE KEY ───────────────────────
//
// Handles are people's names, so they are guessable by anyone who has met the
// person -- `devesh` is not a secret. The server therefore refuses to hand a
// handle to whoever asks first: a registration carries this device's Ed25519
// public key and a signature over the handle, the mailbox credential and the
// time, and the handle is bound to that KEY on first claim (403 `taken` after
// that). Two consequences worth stating plainly:
//
//   * Losing `identity.json` loses the handle, permanently. There is no recovery
//     path and there cannot be one without a server that can be talked into
//     reassigning a name, which is the hole the proof exists to close.
//   * The seed is the whole secret. It is written 0600 and never leaves here.
//
// No Keychain: the decision and its reasons are in CONTACTS.md. Nothing in this
// file blocks launch -- registration happens on its own thread and a failure is
// silent to the person, because a handle they have not tried to use yet failing
// to register is not news.
enum Identity {
  /// Rig override. Same shape as `Update.base` so there is one idiom for this.
  static let base = ProcessInfo.processInfo.environment["TK_KIN_BASE"]
    ?? "https://room.tokkah.com"

  // ── The stored identity ────────────────────────────────────────────────────

  struct Stored {
    var seed: Data          // 32 bytes, the Ed25519 private key
    var tok: String         // 64 hex chars, the mailbox credential
    var handle: String      // what we last successfully claimed, or wanted to
    var claimed: Bool       // did the server ever answer 200 for `handle`
    /// Silence survives a restart. The SERVER is the authority and remembers it,
    /// so an app that forgot would show an unticked switch to somebody who is
    /// still unreachable -- the one error in this feature that matters, because
    /// it is the one where you think calls can reach you and they cannot.
    /// Only ever written from a server answer, never optimistically.
    var quiet: Bool
  }

  private static let lock = NSLock()
  private static var cached: Stored?

  static var dir: URL {
    // Rig override, and it is not optional politeness: on macOS
    // `.applicationSupportDirectory` resolves through the USER RECORD, not $HOME,
    // so `HOME=/tmp/x tk --claim` writes to the real
    // ~/Library/Application Support/Kin anyway. A test that believed otherwise
    // claimed a handle into the actual install and its own negative arm silently
    // re-read the identity it had just written.
    if let d = ProcessInfo.processInfo.environment["TK_KIN_DIR"] {
      return URL(fileURLWithPath: d, isDirectory: true)
    }
    let fm = FileManager.default
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
    return base.appendingPathComponent("Kin", isDirectory: true)
  }
  static var file: URL { dir.appendingPathComponent("identity.json") }

  /// The handle to show and to copy. Never nil once `start()` has run, because a
  /// name derived from this Mac exists whether or not the server has heard of it.
  static var handle: String {
    lock.lock(); defer { lock.unlock() }
    return cached?.handle ?? Identity.candidates().first ?? "kin"
  }

  /// True once the server has confirmed this handle belongs to this key. The UI
  /// uses it to avoid telling someone to share a name that is not theirs yet.
  static var claimed: Bool {
    lock.lock(); defer { lock.unlock() }
    return cached?.claimed ?? false
  }

  static var publicKeyB64: String {
    lock.lock(); defer { lock.unlock() }
    guard let s = cached, let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: s.seed)
    else { return "" }
    return k.publicKey.rawRepresentation.base64EncodedString()
  }

  // ── Deriving a name nobody typed ───────────────────────────────────────────

  /// `^[a-z][a-z0-9]{1,31}$` or nothing. The server's rule, applied here so a
  /// name that cannot be registered is never shown to anyone as theirs.
  static func sanitize(_ raw: String) -> String? {
    let low = raw.lowercased()
    var out = ""
    for ch in low.unicodeScalars {
      if (ch.value >= 97 && ch.value <= 122) || (ch.value >= 48 && ch.value <= 57) {
        out.unicodeScalars.append(ch)
      }
    }
    // Must START with a letter: `2devesh` is not a handle, and dropping leading
    // digits is friendlier than refusing a name outright.
    while let f = out.first, f.isNumber { out.removeFirst() }
    if out.count > 32 { out = String(out.prefix(32)) }
    return out.count >= 2 ? out : nil
  }

  /// `Devesh's` -> `Devesh`. Both apostrophes: macOS writes the computer name
  /// with a CURLY one (U+2019), and stripping only the ASCII quote would leave
  /// `deveshs` -- a plausible-looking handle that is not the person's name.
  private static func stripPossessive(_ s: String) -> String {
    for apo in ["'s", "\u{2019}s"] where s.lowercased().hasSuffix(apo) {
      return String(s.dropLast(apo.count))
    }
    return s
  }

  private static func computerName() -> String? {
    // Host.current().localizedName is the same string System Settings shows.
    Host.current().localizedName
  }

  /// Every name this Mac could answer to, best first, then the ladder. First come
  /// first served: if `devesh` is gone we ask for `deveshp`, then `devesh2`.
  static func candidates() -> [String] {
    // An explicit `--handle` is a decision, not a hint: it replaces the ladder
    // rather than heading it, because falling back from a name someone typed to
    // one we guessed would silently give them a different identity than the one
    // they asked for.
    if let want = arg("handle") {
      guard let h = sanitize(want) else {
        fputs("identity: --handle \(want) is not a usable handle"
            + " (2-32 chars, letters and digits, starting with a letter)\n", stderr)
        return []
      }
      return [h]
    }
    var out: [String] = []
    func push(_ s: String?) {
      guard let s, let h = sanitize(s), !out.contains(h) else { return }
      out.append(h)
    }
    let full = NSFullUserName()                       // "Devesh Patel"
    let words = full.split(separator: " ").map(String.init)
    push(words.first)                                 // devesh
    // "Devesh's MacBook Air" -> devesh
    push(computerName()?.split(separator: " ").first.map { stripPossessive(String($0)) })

    guard let base = out.first else {
      push(NSUserName())
      return out
    }
    // Short first, and person-like before machine-like. The brief was explicit
    // that the handle has to be SHORT, so `deveshp` outranks `deveshpatel`, and
    // both outrank `devesh2` -- a digit reads like a spare account.
    if words.count > 1, let ini = words[1].first { push(base + String(ini)) }
    push(NSUserName())                                // deveshpatel
    if words.count > 1 { push(base + words[1]) }      // deveshpatel, if not already
    for n in 2...9 { push(base + String(n)) }
    return out
  }

  // ── Disk ───────────────────────────────────────────────────────────────────

  private static func load() -> Stored? {
    guard let d = try? Data(contentsOf: file),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let seedB64 = o["seed"] as? String,
          let seed = Data(base64Encoded: seedB64), seed.count == 32,
          let tok = o["tok"] as? String, tok.count == 64,
          let handle = o["handle"] as? String
    else { return nil }
    return Stored(seed: seed, tok: tok, handle: handle,
                  claimed: (o["claimed"] as? Bool) ?? false,
                  quiet: (o["quiet"] as? Bool) ?? false)
  }

  private static func save(_ s: Stored) {
    let fm = FileManager.default
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o700])
    let o: [String: Any] = ["seed": s.seed.base64EncodedString(), "tok": s.tok,
                            "handle": s.handle, "claimed": s.claimed, "quiet": s.quiet]
    guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    else { return }
    // Write-then-rename: a half-written identity file is an identity lost, and
    // this file is not recoverable.
    let tmp = file.appendingPathExtension("tmp")
    do {
      try d.write(to: tmp, options: .atomic)
      try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
      _ = try? fm.replaceItemAt(file, withItemAt: tmp)
    } catch {
      fputs("identity: could not write \(file.path): \(error)\n", stderr)
    }
  }

  /// Load or mint. Never fails: without an identity there is no handle, and the
  /// app still has to run.
  @discardableResult
  static func ensure() -> Stored {
    lock.lock()
    if let c = cached { lock.unlock(); return c }
    if let s = load() { cached = s; quietCache = s.quiet; lock.unlock(); return s }
    lock.unlock()
    let key = Curve25519.Signing.PrivateKey()
    var tokBytes = [UInt8](repeating: 0, count: 32)
    for i in 0..<32 { tokBytes[i] = UInt8.random(in: 0...255) }
    let fresh = Stored(seed: key.rawRepresentation,
                       tok: tokBytes.map { String(format: "%02x", $0) }.joined(),
                       handle: candidates().first ?? "kin",
                       claimed: false, quiet: false)
    lock.lock(); cached = fresh; lock.unlock()
    save(fresh)
    fputs("identity: new install, asking for @\(fresh.handle)\n", stderr)
    return fresh
  }

  // ── Claiming it ────────────────────────────────────────────────────────────

  private static func sign(_ msg: String, seed: Data) -> String? {
    guard let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
          let sig = try? k.signature(for: Data(msg.utf8)) else { return nil }
    return sig.base64EncodedString()
  }

  /// One registration attempt. Returns the HTTP status, or nil if the request
  /// never completed. Synchronous on purpose: the caller is already off-main and
  /// the ladder is a sequence of decisions, not a fan-out.
  private static func attempt(_ handle: String, _ s: Stored) -> Int? {
    guard let url = URL(string: "\(base)/api/kin/\(handle)/register"),
          let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: s.seed)
    else { return nil }
    // INTEGER seconds. The timestamp is stringified into the signed message, so
    // its spelling is part of the contract -- a Double would render "1.8e+09" or
    // "1800000000.0" here and produce a signature that verifies on this device
    // and never on the server, forever, with a 401 that blames the key.
    let t = Int(Date().timeIntervalSince1970)
    guard let sig = sign("kin-reg-v1|\(handle)|\(s.tok)|\(t)", seed: s.seed) else { return nil }
    let body: [String: Any] = [
      "to": handle, "tok": s.tok,
      "k": k.publicKey.rawRepresentation.base64EncodedString(),
      "t": t, "sig": sig,
    ]
    guard let d = try? JSONSerialization.data(withJSONObject: body) else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.httpBody = d
    req.timeoutInterval = 8
    req.cachePolicy = .reloadIgnoringLocalCacheData
    var status: Int?
    var payload = ""
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, _ in
      status = (resp as? HTTPURLResponse)?.statusCode
      if let data, let s = String(data: data, encoding: .utf8) { payload = s }
      sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 10)
    if let st = status, st != 200 {
      fputs("identity: @\(handle) -> \(st) \(payload)\n", stderr)
    }
    return status
  }

  /// Walk the ladder until the server says yes. Called on its own thread.
  ///
  /// 403 `taken` is the only status that advances the ladder: it means the name
  /// belongs to a different key, which is exactly first-come-first-served
  /// working. Everything else -- a 429, a timeout, a 500 -- is about US, and
  /// moving to the next name because the network hiccuped would silently rename
  /// someone who already owns `devesh`.
  static func claim() {
    var s = ensure()
    // Already settled: refresh the lease under the SAME name and stop.
    if s.claimed {
      // Tell the UI regardless of what the refresh says: the handle is already
      // ours on disk, and hiding it because a lease refresh timed out would make
      // the name disappear from the sheet on a bad network.
      let named = s.handle
      DispatchQueue.main.async { onClaimed?(named) }
      if attempt(s.handle, s) == 200 { return }
      // A refresh that fails is not a reason to take a new name either.
      return
    }
    var tried = 0
    for cand in candidates() where tried < 12 {
      tried += 1
      guard let st = attempt(cand, s) else { return }   // no network: try next launch
      if st == 200 {
        s.handle = cand
        s.claimed = true
        lock.lock(); cached = s; lock.unlock()
        save(s)
        fputs("identity: you are @\(cand)\n", stderr)
        let named = cand
        DispatchQueue.main.async { onClaimed?(named) }
        return
      }
      if st != 403 { return }
    }
    fputs("identity: every name this Mac suggests is taken -- staying unclaimed\n", stderr)
  }

  // ── SILENT MODE ────────────────────────────────────────────────────────────
  //
  // "No one can call you." The server's half is built so that silence is
  // INDISTINGUISHABLE from being away: a silenced ring travels the whole normal
  // path and is dropped when the mailbox drains, so the caller's response is
  // byte-identical either way. Nothing here may undo that -- in particular this
  // client must never expose "they are silenced" to a caller, because the only
  // reason the server pays for that indistinguishability is so the caller cannot
  // learn it.
  private static var quietCache = false
  static var quietOn: Bool {
    lock.lock(); defer { lock.unlock() }
    return quietCache
  }

  /// Toggle silent mode. Synchronous; call it off main. Returns true if the
  /// server agreed, and only then does the local state move -- a toggle that
  /// flips the switch in the UI without the server agreeing is a person who
  /// thinks they are unreachable and is not.
  @discardableResult
  static func setQuiet(_ on: Bool, until: Int = 0) -> Bool {
    let s = ensure()
    guard s.claimed else { return false }
    guard let url = URL(string: "\(base)/api/kin/\(s.handle)/quiet"),
          let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: s.seed)
    else { return false }
    let t = Int(Date().timeIntervalSince1970)
    // Ints, and lowercase true/false. Both spellings are part of the signed
    // string: a Double renders "0.0" here and verifies on this device forever
    // while the server returns 401 and blames the key.
    guard let sig = sign("kin-quiet-v1|\(s.handle)|\(on)|\(until)|\(t)", seed: s.seed)
    else { return false }
    let body: [String: Any] = [
      "to": s.handle, "k": k.publicKey.rawRepresentation.base64EncodedString(),
      "t": t, "sig": sig, "quiet": on, "until": until,
    ]
    guard let d = try? JSONSerialization.data(withJSONObject: body) else { return false }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.httpBody = d
    req.timeoutInterval = 8
    req.cachePolicy = .reloadIgnoringLocalCacheData
    var okQuiet: Bool?
    var status = 0
    var payload = ""
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, _ in
      status = (resp as? HTTPURLResponse)?.statusCode ?? 0
      if let data, let str = String(data: data, encoding: .utf8) { payload = str }
      if status == 200, let data,
         let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        // Believe the server's READ-TIME verdict, not the value we sent: an
        // expired deadline reports quiet:false while the stored row still says
        // true, and the switch has to show what is actually true right now.
        okQuiet = (o["quiet"] as? Bool) ?? on
      }
      sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 10)
    guard let got = okQuiet else {
      fputs("identity: silent mode \(on ? "on" : "off") refused -- \(status) \(payload)\n", stderr)
      return false
    }
    lock.lock()
    quietCache = got
    var toSave = cached
    toSave?.quiet = got
    if let t = toSave { cached = t }
    lock.unlock()
    if let t = toSave { save(t) }
    fputs("identity: silent mode is \(got ? "on" : "off")\n", stderr)
    return got == on
  }

  // ── RINGING SOMEONE, AND BEING RUNG ────────────────────────────────────────
  //
  // The caller mints a room, tells the callee's mailbox about it, and joins. The
  // callee's poll finds the ring and joins the same room. No media, no signalling
  // and no addresses go through the doorbell -- it carries a room NAME, and the
  // existing rendezvous does everything it always did once both ends are in it.
  //
  // ── THE SERVER DOES NOT VERIFY THE RING, AND MUST NOT ──────────────────────
  //
  // `kinRingDecide` checks the signature's SHAPE and never decodes it, with the
  // reason written in the worker: only the callee holds the list of who may ring
  // it, and a server that could verify a ring is a server that could forge one.
  // So verification is OUR job, here, and a ring whose signature does not check
  // out is dropped without ever being shown. `k` comes back out of the poll for
  // exactly this.
  //
  // What that signature does and does not prove, stated plainly so nobody
  // assumes the stronger thing: it proves the sender holds the private half of
  // the key `k` in the ring. It does NOT prove `k` belongs to the handle in
  // `from` -- there is no route that maps a handle to its registered key, and
  // adding one would turn the doorbell into an oracle for which handles exist.
  // So a first-time caller's NAME is a claim. What is not a claim is the key:
  // once a call has been accepted, `remember` binds handle to key locally, and a
  // later ring using that handle with a different key is flagged rather than
  // silently shown as the person you know. Trust on first use, and the call's own
  // encryption code remains the thing that actually identifies who is on the far
  // end.
  struct Ring {
    let from: String
    let room: String
    let t: Int
    let k: String       // caller's device public key, base64
    let ageMs: Int
    /// This handle has rung before, from this same key.
    let known: Bool
    /// This handle has rung before from a DIFFERENT key. Someone is claiming a
    /// name that is not theirs, or the person reinstalled and lost their seed.
    let keyChanged: Bool
  }

  /// Its own domain, and it covers every field with an effect: swap any of them
  /// and the signature stops verifying.
  private static func ringMessage(to: String, from: String, room: String, t: Int) -> String {
    "kin-ring-v1|\(to)|\(from)|\(room)|\(t)"
  }

  // ── Who we have spoken to ──────────────────────────────────────────────────

  static var contactsFile: URL { dir.appendingPathComponent("contacts.json") }

  /// handle -> base64 device key. Small, local, and never sent anywhere.
  static func contacts() -> [String: String] {
    guard let d = try? Data(contentsOf: contactsFile),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: String]
    else { return [:] }
    return o
  }

  /// Bind a handle to the key that actually rang. Called when a call is accepted,
  /// not when a ring arrives -- otherwise anyone who rings once owns the name.
  static func remember(handle: String, key: String) {
    var c = contacts()
    guard c[handle] != key else { return }
    c[handle] = key
    guard let d = try? JSONSerialization.data(withJSONObject: c, options: [.sortedKeys])
    else { return }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let tmp = contactsFile.appendingPathExtension("tmp")
    if (try? d.write(to: tmp, options: .atomic)) != nil {
      _ = try? FileManager.default.replaceItemAt(contactsFile, withItemAt: tmp)
    }
    fputs("contacts: @\(handle) remembered\n", stderr)
  }

  // ── Ringing ────────────────────────────────────────────────────────────────

  /// Ring `to` and tell them which room to join. Synchronous; call it off main.
  /// Returns the room on success so the caller joins the one it actually sent.
  static func ring(to raw: String, room: String) -> String? {
    guard let to = sanitize(raw) else {
      fputs("ring: @\(raw) is not a handle\n", stderr); return nil
    }
    let s = ensure()
    guard s.claimed else { fputs("ring: this Mac has no handle yet\n", stderr); return nil }
    guard to != s.handle else { fputs("ring: that is you\n", stderr); return nil }
    guard let url = URL(string: "\(base)/api/kin/\(to)/ring"),
          let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: s.seed)
    else { return nil }
    let t = Int(Date().timeIntervalSince1970)
    guard let sig = sign(ringMessage(to: to, from: s.handle, room: room, t: t), seed: s.seed)
    else { return nil }
    let body: [String: Any] = [
      "to": to, "from": s.handle, "room": room, "t": t, "sig": sig,
      "k": k.publicKey.rawRepresentation.base64EncodedString(),
    ]
    guard let d = try? JSONSerialization.data(withJSONObject: body) else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.httpBody = d
    req.timeoutInterval = 8
    req.cachePolicy = .reloadIgnoringLocalCacheData
    var status = 0
    var payload = ""
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, _ in
      status = (resp as? HTTPURLResponse)?.statusCode ?? 0
      if let data, let str = String(data: data, encoding: .utf8) { payload = str }
      sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 10)
    guard status == 200 else {
      // A 200 says the ring is in their mailbox, nothing more. Silence and
      // "away" are indistinguishable by design, so this is the only honest
      // report either way.
      fputs("ring: @\(to) -> \(status) \(payload)\n", stderr)
      return nil
    }
    fputs("ring: @\(to) in room \(room)\n", stderr)
    return room
  }

  /// Drain the mailbox once. Unverifiable rings are dropped here and never
  /// reach the caller of this function.
  static func poll() -> [Ring] {
    let s = ensure()
    guard s.claimed else {
      // Not the same as an empty mailbox, and it used to be indistinguishable
      // from one. An identity that never won its handle has no mailbox to read,
      // and reporting that as "no rings" sends whoever is debugging to look at
      // the sender.
      fputs("ring: not polling -- @\(s.handle) is not claimed by this install\n", stderr)
      return []
    }
    guard let url = URL(string: "\(base)/api/kin/\(s.handle)/poll?tok=\(s.tok)")
    else { return [] }
    var req = URLRequest(url: url)
    req.timeoutInterval = 8
    req.cachePolicy = .reloadIgnoringLocalCacheData
    var out: [Ring] = []
    var quiet: Bool?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, _ in
      defer { sem.signal() }
      let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
      guard code == 200, let data,
            let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        // A 429, a 403 and a dead network all used to look exactly like an empty
        // mailbox. Silence is a legitimate answer to "is anyone calling"; it is
        // never a legitimate answer to "did the question get through".
        fputs("ring: poll failed -- \(code == 0 ? "no answer" : "http \(code)")\n", stderr)
        return
      }
      if let q = o["quiet"] as? [String: Any] { quiet = q["on"] as? Bool }
      let known = contacts()
      let offered = (o["rings"] as? [[String: Any]])?.count ?? 0
      // Offered vs verified, always. "0 verified" out of 3 offered is a key
      // problem; out of 0 offered it is a quiet afternoon.
      if offered > 0 { fputs("ring: \(offered) offered by the server\n", stderr) }
      for r in (o["rings"] as? [[String: Any]]) ?? [] {
        guard let from = r["from"] as? String, let room = r["room"] as? String,
              let t = r["t"] as? Int, let sig = r["sig"] as? String,
              let kb64 = r["k"] as? String,
              let sigD = Data(base64Encoded: sig), sigD.count == 64,
              let pkD = Data(base64Encoded: kb64), pkD.count == 32,
              let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: pkD)
        else { fputs("ring: dropped a malformed ring\n", stderr); continue }
        let msg = ringMessage(to: s.handle, from: from, room: room, t: t)
        guard pk.isValidSignature(sigD, for: Data(msg.utf8)) else {
          // Never shown. An unverifiable ring is not a call from someone whose
          // name we cannot confirm -- it is a ring nobody proved they sent.
          fputs("ring: @\(from) failed verification -- dropped\n", stderr); continue
        }
        out.append(Ring(from: from, room: room, t: t, k: kb64,
                        ageMs: (r["ageMs"] as? Int) ?? 0,
                        known: known[from] == kb64,
                        keyChanged: known[from] != nil && known[from] != kb64))
      }
    }.resume()
    _ = sem.wait(timeout: .now() + 10)
    // The poll is also the authoritative read of our own silent state, for free.
    if let q = quiet {
      lock.lock()
      quietCache = q
      if var c = cached, c.quiet != q { c.quiet = q; cached = c; lock.unlock(); save(c) }
      else { lock.unlock() }
    }
    return out
  }

  /// Listen for rings for as long as the app is open. One thread, one poll every
  /// `gapMs` -- the server refuses more than one poll per 2 s per handle, so the
  /// floor here is not a preference.
  static func startRinging(gapMs: Int = 5000, onRing: @escaping (Ring) -> Void) {
    let gap = max(2000, gapMs)
    Thread {
      // Only ever the newest ring is offered: a stack of missed calls is a
      // feature nobody asked for, and answering a stale room joins an empty one.
      while true {
        let rings = poll()
        if let r = rings.max(by: { $0.t < $1.t }) {
          DispatchQueue.main.async { onRing(r) }
        }
        Thread.sleep(forTimeInterval: Double(gap) / 1000)
      }
    }.start()
  }

  /// Called on main once the handle is really ours, so the UI can stop hiding it.
  nonisolated(unsafe) static var onClaimed: ((String) -> Void)?

  /// Registration, off the launch path entirely. Nothing waits on this.
  static func start() {
    ensure()
    Thread { claim() }.start()
  }

  // ── The ruler ──────────────────────────────────────────────────────────────

  /// Known inputs with known answers, including two that MUST rank differently,
  /// because a derivation that returns something plausible for everything is not
  /// a derivation. No network, no disk.
  static func selftest() -> Bool {
    var ok = true
    func eq(_ what: String, _ got: String?, _ want: String?) {
      let g = got ?? "nil", w = want ?? "nil"
      if g != w { ok = false; fputs("  FAIL \(what): got \(g), want \(w)\n", stderr) }
      else { fputs("  ok   \(what) -> \(g)\n", stderr) }
    }
    // The possessive, in both spellings macOS actually writes.
    eq("Devesh\u{2019}s (curly)", sanitize(stripPossessiveT("Devesh\u{2019}s")), "devesh")
    eq("Devesh's (ascii)", sanitize(stripPossessiveT("Devesh's")), "devesh")
    // Without the strip this is `deveshs` -- a plausible handle that is not the
    // person's name, which is exactly the failure worth a test.
    eq("no-strip control", sanitize("Devesh\u{2019}s"), "deveshs")
    eq("plain", sanitize("Devesh"), "devesh")
    eq("spaces + case", sanitize("Devesh Patel"), "deveshpatel")
    eq("leading digits", sanitize("2Devesh"), "devesh")
    eq("all digits", sanitize("2026"), nil)
    eq("one letter", sanitize("d"), nil)
    eq("punctuation", sanitize("d.e-v_e sh!"), "devesh")
    eq("32 cap", sanitize(String(repeating: "a", count: 40)), String(repeating: "a", count: 32))
    // Every candidate this Mac would offer must itself be a legal handle.
    let cands = candidates()
    fputs("  candidates on this Mac: \(cands.joined(separator: ", "))\n", stderr)
    if cands.isEmpty { ok = false; fputs("  FAIL no candidate at all\n", stderr) }
    for c in cands where sanitize(c) != c {
      ok = false; fputs("  FAIL candidate \(c) is not already canonical\n", stderr)
    }
    if Set(cands).count != cands.count { ok = false; fputs("  FAIL duplicate candidates\n", stderr) }
    return ok
  }

  /// `stripPossessive` is private and the test needs it; exposing it is cheaper
  /// than making the test lie about what it checks.
  static func stripPossessiveT(_ s: String) -> String { stripPossessive(s) }

  /// Someone changed their handle in the UI. Only a successful claim moves the
  /// stored name, so a rejected rename leaves them as who they were.
  @discardableResult
  static func rename(to raw: String) -> Bool {
    guard let want = sanitize(raw) else { return false }
    var s = ensure()
    guard want != s.handle else { return true }
    guard attempt(want, s) == 200 else { return false }
    s.handle = want; s.claimed = true
    lock.lock(); cached = s; lock.unlock()
    save(s)
    fputs("identity: you are now @\(want)\n", stderr)
    return true
  }
}
