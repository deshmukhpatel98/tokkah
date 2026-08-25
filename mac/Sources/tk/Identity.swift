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
  /// True while `claim()` is walking the ladder. Read by `awaitClaim`, which is
  /// how `ring()` stops failing during the several seconds a first install spends
  /// asking the server for a name.
  nonisolated(unsafe) private(set) static var claiming = false
  private static let claimGate = NSLock()

  /// Wait up to `secs` for a claim that is already in flight, and start one if
  /// none is. CALL THIS OFF THE MAIN THREAD -- it blocks.
  ///
  /// A first install spends 5 to 8 seconds walking @devesh, @deveshp, @devesh2
  /// ... before it owns a name, and `ring()` refused outright for the whole of
  /// that window: launch Kin, type a friend's handle, press call, and the first
  /// thing the app ever does is fail. Same shape as the doorbell that would not
  /// start on a first install -- a one-shot read of a value that arrives later.
  @discardableResult
  static func awaitClaim(_ secs: Double) -> Bool {
    if claimed { return true }
    claimGate.lock()
    let needStart = !claiming && !claimed
    claimGate.unlock()
    if needStart { Thread { claim() }.start() }
    let deadline = Date().addingTimeInterval(secs)
    while !claimed, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
      if !claiming, !claimed { break }        // it finished, and it failed
    }
    return claimed
  }

  static func claim() {
    claimGate.lock()
    if claiming { claimGate.unlock(); return }   // one ladder at a time
    claiming = true
    claimGate.unlock()
    defer { claimGate.lock(); claiming = false; claimGate.unlock() }
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
    /// nil on an ordinary ring. "bye" means the sender is NO LONGER calling --
    /// they declined, or they cancelled before this end answered. Same envelope,
    /// opposite news, and it is why a cancelled call stops looking like a call.
    let kind: String?
  }

  /// The words a ring may carry. Anything else is dropped rather than shown: a
  /// future client will invent one, and a message this version cannot act on is
  /// not a message it should guess about.
  static let ringKinds: Set<String> = ["bye"]

  /// Its own domain, and it covers every field with an effect: swap any of them
  /// and the signature stops verifying.
  private static func ringMessage(to: String, from: String, room: String, t: Int,
                                 kind: String? = nil) -> String {
    // A HANG-UP SIGNS A DIFFERENT DOMAIN, and that is the whole compatibility
    // story. An older client verifies every ring it is handed against the v1
    // string, so a `bye` it has never heard of fails verification and is
    // dropped -- it falls back to the ring timeout, which is exactly what it did
    // before byes existed. Sign the same domain and that same old client would
    // instead verify a valid signature and draw a card for a call nobody is on.
    // New meaning, new domain.
    guard let kind else { return "kin-ring-v1|\(to)|\(from)|\(room)|\(t)" }
    return "kin-\(kind)-v1|\(to)|\(from)|\(room)|\(t)"
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

  // ── EVERYONE THIS MAC COULD TAP ────────────────────────────────────────────
  //
  // `contacts()` is the truth and it is keyed by handle, so the panel is that
  // keyset sorted. Sorted rather than "most recent first" because nothing here
  // records when a call happened -- and an ordering derived from a field that does
  // not exist is a list that reshuffles itself for reasons nobody can explain.
  //
  // ── AND THE RIG OVERRIDE, WHICH IS NOT OPTIONAL ────────────────────────────
  //
  // Without `--contacts-fake` the panel can only ever be audited EMPTY, and the
  // day a real contact finally lands is the first day a row is ever clicked. That
  // is an instrument blind to the populated state reporting the same green as one
  // where it works. It proves the view and the clicks and nothing about identity,
  // pairing or ringing -- those are still two Macs on a live call.
  //
  // Echoed once, because a flag that does nothing quietly has cost this project
  // three A/Bs that compared an arm against itself.
  nonisolated(unsafe) private static var announcedFake = false
  static func contactHandles() -> [String] {
    if let fake = arg("contacts-fake") {
      let list = fake.split(separator: ",").compactMap { sanitize(String($0)) }
      if !announcedFake {
        announcedFake = true
        fputs("contacts: --contacts-fake is on -- \(list.count) pretend"
            + " (\(list.joined(separator: ", "))), the real list is not read\n", stderr)
      }
      return list
    }
    return contacts().keys.sorted()
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
  static func ring(to raw: String, room: String, kind: String? = nil) -> String? {
    guard let to = sanitize(raw) else {
      fputs("ring: @\(raw) is not a handle\n", stderr); return nil
    }
    if let kind { precondition(ringKinds.contains(kind), "unknown ring kind \(kind)") }
    let noun = kind == nil ? "ring" : kind!
    var s = ensure()
    // A name is the return address on the ring, so there is no ringing without
    // one. Every caller of this is already off the main thread (`onCall` spawns
    // a Thread precisely because this signs and makes an HTTPS round trip).
    if !s.claimed { Identity.awaitClaim(6); s = ensure() }
    guard s.claimed else { fputs("ring: this Mac has no handle yet\n", stderr); return nil }
    guard to != s.handle else {
      Metrics.count("ring_to_self")
      fputs("ring: that is you\n", stderr); return nil
    }
    guard let url = URL(string: "\(base)/api/kin/\(to)/ring"),
          let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: s.seed)
    else { return nil }
    let t = Int(Date().timeIntervalSince1970)
    guard let sig = sign(ringMessage(to: to, from: s.handle, room: room, t: t, kind: kind),
                        seed: s.seed)
    else { return nil }
    var body: [String: Any] = [
      "to": to, "from": s.handle, "room": room, "t": t, "sig": sig,
      "k": k.publicKey.rawRepresentation.base64EncodedString(),
    ]
    if let kind { body["kind"] = kind }
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
      fputs("\(noun): @\(to) -> \(status) \(payload)\n", stderr)
      return nil
    }
    fputs("\(noun): @\(to) in room \(room)\n", stderr)
    return room
  }

  // ── AN EMPTY MAILBOX AND A DEAD NETWORK ARE THE SAME RETURN VALUE ──────────
  //
  // `poll()` hands back `[]` for "nobody called", for a 429, for a 403 and for a
  // Mac with the Wi-Fi off. That is fine for a poll loop, which only ever wants
  // the rings -- and it is the whole story for anything that has to TELL someone
  // whether they can be reached. A menu bar that says "Ready for calls" off the
  // back of an empty array is `blind-instruments-report-negatives`: the same
  // green light for a quiet afternoon and for an unreachable machine, and the
  // second one is precisely the state a person needs to be told about.
  //
  // So the last answer from the server is recorded, and the resident reads it.
  // Deliberately the raw status and not a verdict: 429 means "asking too often,
  // still reachable" and calls for a back-off, while 0 means nothing arrived at
  // all -- a bool would have to pick one of those and be wrong about the other.
  nonisolated(unsafe) private(set) static var lastPollStatus = 0
  nonisolated(unsafe) private(set) static var lastPollAt = Date.distantPast

  /// True when the doorbell answered recently enough that a ring placed now
  /// would be found. Nothing here is shown as a number; it decides one word.
  static var reachable: Bool {
    (lastPollStatus == 200 || lastPollStatus == 429)
      && Date().timeIntervalSince(lastPollAt) < 90
  }

  /// Drain the mailbox once, answering straight away. Unverifiable rings are
  /// dropped here and never reach the caller of this function.
  static func poll() -> [Ring] {
    if case .answer(let rings, _) = pollOnce(waitMs: 0) { return rings }
    return []
  }

  /// What one poll turned out to be. The four cases exist because they are four
  /// different facts, and this endpoint's worst failure is treating them as one:
  /// "nobody is calling" and "the question never got through" have looked
  /// identical here before, and the second one is a missed call.
  enum PollOutcome {
    /// HTTP 200. `serverHolds` is nil when we did not ask to wait; otherwise it
    /// is whether the server proved it understands waiting.
    case answer(rings: [Ring], serverHolds: Bool?)
    /// HTTP 204 -- the server held the line for the full wait and nothing came.
    /// The line is now free; arm another immediately.
    case held
    /// HTTP 429, carrying the server's own retry hint in ms. NOT an empty
    /// mailbox: a poll refused for going too fast has told us nothing at all
    /// about whether somebody is calling, and hammering is what turns one 429
    /// into a locked-out minute.
    case rate(Int)
    /// No answer, or a status we cannot act on.
    case failed
  }

  /// How long a held poll asks the server to hold it. Comfortably inside the
  /// server's own 30 s ceiling, and a rig override because a test that has to
  /// wait 25 s to watch a deadline expire will not be run.
  static var holdMs: Int {
    Int(ProcessInfo.processInfo.environment["TK_RING_WAIT_MS"] ?? "") ?? 25_000
  }

  /// ── THE POLL GETS ITS OWN SESSION, AND THAT IS NOT TIDINESS ────────────────
  ///
  /// A held poll occupies one connection to room.tokkah.com for 25 seconds at a
  /// time, and `URLSession.shared` is also what `ring`, `claim`, `setQuiet`,
  /// `Update` and `Telemetry` use. Sharing a per-host connection pool between a
  /// request that is DESIGNED to sit idle for half a minute and every other
  /// request the app makes is asking for one of them to queue behind the other,
  /// and a queued task is invisible: no error, no status, nothing on the wire.
  ///
  /// `timeoutIntervalForResource` is the one that matters here. `timeoutInterval`
  /// on the request bounds IDLE time, and a held poll is idle by design -- so it
  /// is the resource timeout, which bounds the whole task, that guarantees this
  /// ever comes back.
  private static let pollSession: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 40
    c.timeoutIntervalForResource = 45
    c.httpMaximumConnectionsPerHost = 2
    c.waitsForConnectivity = false
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: c)
  }()

  /// One poll. `waitMs` of 0 asks for an answer now -- which is what every
  /// deployed client does and what an older server is only capable of. Anything
  /// else asks the server to hold the request open until somebody rings, which
  /// is the whole difference between a doorbell that answers in a tenth of a
  /// second and one that averages two and a half.
  static func pollOnce(waitMs: Int) -> PollOutcome {
    let s = ensure()
    guard s.claimed else {
      // Not the same as an empty mailbox, and it used to be indistinguishable
      // from one. An identity that never won its handle has no mailbox to read,
      // and reporting that as "no rings" sends whoever is debugging to look at
      // the sender.
      fputs("ring: not polling -- @\(s.handle) is not claimed by this install\n", stderr)
      return .failed
    }
    let wait = waitMs > 0 ? "&wait=\(waitMs)" : ""
    guard let url = URL(string: "\(base)/api/kin/\(s.handle)/poll?tok=\(s.tok)\(wait)")
    else { return .failed }
    var req = URLRequest(url: url)
    // Must OUTLAST the wait we asked for, with room for the round trip. A
    // timeout shorter than the hold abandons every held poll a moment before
    // the server was going to answer it -- the fast path failing on a schedule,
    // and looking like a flaky network while it does.
    req.timeoutInterval = waitMs > 0 ? Double(waitMs) / 1000 + 10 : 8
    req.cachePolicy = .reloadIgnoringLocalCacheData
    var out: [Ring] = []
    var quiet: Bool?
    var outcome = PollOutcome.failed
    let sem = DispatchSemaphore(value: 0)
    let task = pollSession.dataTask(with: req) { data, resp, _ in
      defer { sem.signal() }
      let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
      // Recorded before the guard, so a failure is recorded as a failure rather
      // than leaving the last success standing and reading as still healthy.
      lastPollStatus = code
      lastPollAt = Date()
      // Every answer the doorbell gives, counted by class. "nobody called" and
      // "this Mac has not reached the doorbell in ten minutes" are the same empty
      // array to everything above this line, and only one of them is a person
      // who cannot be called.
      switch code {
      case 200, 204: Metrics.count("poll_ok")
      case 401, 403: Metrics.count("poll_refused")
      case 429:      Metrics.count("poll_rate")
      case 0:        Metrics.count("poll_no_answer")
      default:       Metrics.count("poll_error")
      }
      // 204 is the held line coming back empty, and no older worker has ever
      // produced one on this route -- so it is both the answer and the proof
      // that this server holds.
      if code == 204 { outcome = .held; return }
      if code == 429 {
        let o = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        outcome = .rate((o?["retryMs"] as? Int) ?? 2000)
        return
      }
      guard code == 200, let data,
            let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let offeredRings = o["rings"] as? [[String: Any]]
      else {
        // A 429, a 403 and a dead network all used to look exactly like an empty
        // mailbox. Silence is a legitimate answer to "is anyone calling"; it is
        // never a legitimate answer to "did the question get through".
        //
        // A 200 with no `rings` key is refused here too, on purpose: that is
        // what a server which accepted the wait and then forgot to hold would
        // send, and reading it as an empty mailbox is exactly the silent
        // negative this whole block exists to stop.
        fputs("ring: poll failed -- \(code == 0 ? "no answer" : "http \(code)")\n", stderr)
        return
      }
      if let q = o["quiet"] as? [String: Any] { quiet = q["on"] as? Bool }
      let known = contacts()
      let offered = offeredRings.count
      // WHETHER THIS SERVER HOLDS, and it must be a positive statement rather
      // than a guess from timing. An older worker ignores an unknown query
      // parameter in silence and answers at once, which is indistinguishable
      // from a fast new server unless the new one says so out loud. `waitedMs`
      // is that sentence; its absence is an old worker, and the loop below
      // drops back to the 5 s cadence on the strength of it.
      let holds: Bool? = waitMs > 0 ? (o["waitedMs"] != nil) : nil
      defer { outcome = .answer(rings: out, serverHolds: holds) }
      // Offered vs verified, always. "0 verified" out of 3 offered is a key
      // problem; out of 0 offered it is a quiet afternoon.
      if offered > 0 { fputs("ring: \(offered) offered by the server\n", stderr) }
      for r in offeredRings {
        guard let from = r["from"] as? String, let room = r["room"] as? String,
              let t = r["t"] as? Int, let sig = r["sig"] as? String,
              let kb64 = r["k"] as? String,
              let sigD = Data(base64Encoded: sig), sigD.count == 64,
              let pkD = Data(base64Encoded: kb64), pkD.count == 32,
              let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: pkD)
        else {
          Metrics.count("ring_malformed")
          fputs("ring: dropped a malformed ring\n", stderr); continue
        }
        // A word this version does not know is dropped BEFORE the signature is
        // checked, because there is nothing sensible to do with a valid
        // signature over a meaning we cannot read. Named in the log: a client
        // silently discarding a message a newer peer keeps sending is the
        // hardest kind of incompatibility to find from either end.
        let kind = r["kind"] as? String
        if let kind, !ringKinds.contains(kind) {
          fputs("ring: @\(from) sent \"\(kind)\", which this version does not know -- dropped\n",
                stderr)
          Metrics.count("ring_kind_unknown")
          continue
        }
        let msg = ringMessage(to: s.handle, from: from, room: room, t: t, kind: kind)
        guard pk.isValidSignature(sigD, for: Data(msg.utf8)) else {
          // Never shown. An unverifiable ring is not a call from someone whose
          // name we cannot confirm -- it is a ring nobody proved they sent.
          Metrics.count("ring_unverified")
          fputs("ring: @\(from) failed verification -- dropped\n", stderr); continue
        }
        out.append(Ring(from: from, room: room, t: t, k: kb64,
                        ageMs: (r["ageMs"] as? Int) ?? 0,
                        known: known[from] == kb64,
                        keyChanged: known[from] != nil && known[from] != kb64,
                        kind: kind))
      }
    }
    task.resume()
    // Must outlast the request's own timeout, or this function reports failure
    // while the request it is waiting on is still perfectly alive -- and the
    // loop arms a second one on top of it.
    //
    // `DispatchTime` AND NOT `.now()`. Written as `.now()` Swift resolves this
    // to `wait(wallTimeout:)`, which is the WALL CLOCK -- a stack sample caught
    // it in `semaphore_timedwait_trap` under exactly that overload. A wall-clock
    // deadline is not a deadline: it moves with an NTP step, a timezone update
    // and, on the machine this actually runs on, a laptop closing its lid, which
    // is the single most likely thing to happen during a 25-second held request.
    // The whole point of this line is to be the thing that CANNOT fail to fire.
    if sem.wait(timeout: DispatchTime.now() + req.timeoutInterval + 8) == .timedOut {
      // CANCEL IT. A task abandoned here still owns its connection, and the next
      // poll queues behind a request nobody is listening to any more -- which
      // presents as a doorbell that simply stops, with no error anywhere.
      task.cancel()
      fputs("ring: poll gave no answer in time -- abandoned\n", stderr)
      lastPollStatus = 0
      lastPollAt = Date()
    }
    // The poll is also the authoritative read of our own silent state, for free.
    if let q = quiet {
      lock.lock()
      quietCache = q
      if var c = cached, c.quiet != q { c.quiet = q; cached = c; lock.unlock(); save(c) }
      else { lock.unlock() }
    }
    return outcome
  }

  // ── LISTENING ───────────────────────────────────────────────────────────────
  //
  // A 5 s poll rings the callee's screen after 2.5 s on average and 5 s at
  // worst. A phone rings in well under one second, so the poll IS the defect.
  //
  // So the request is HELD: the callee asks the server to keep its GET open for
  // 25 s and answer the instant a ring lands. Mean ring latency stops being half
  // a poll interval and becomes one round trip. Measured on a local worker, same
  // binary both arms, n=12: median 2794 ms before, 18 ms after.
  //
  // ── AND IT HAS TO WORK AGAINST A SERVER THAT CANNOT DO THAT ───────────────
  //
  // Two ends of a call update independently, and a Mac that self-updated this
  // morning will be talking to whatever the worker was yesterday. An older
  // worker ignores `wait` in silence and answers immediately; something between
  // us and it may buffer the response instead of streaming it. Neither may be
  // allowed to mean "nobody ever calls me again" -- so this loop watches for
  // both and drops back to the 5 s cadence, which is byte for byte the code that
  // shipped.
  //
  // The re-probe costs NOTHING, and that is the point of doing it this way: a
  // fallen-back client puts `wait` back on one poll a minute, and that poll is a
  // real poll either way. If the far side has since been deployed, the 204 or
  // the `waitedMs` comes back and the fast path resumes with no extra request
  // and nothing to restart.

  /// Polls after which a client that fell back re-offers to wait. 12 x 5 s is a
  /// minute: soon enough that a deploy is not a lasting regression, rare enough
  /// that an old server is not asked twelve times a minute.
  private static let reprobeEvery = 12
  /// Held polls between one plain one. A held poll answers 204 with no body, and
  /// the body is the only place the server's view of our own silence comes back;
  /// 3 holds is about 75 s, so a silence deadline that expired server-side shows
  /// as lifted within that. It costs one extra round trip per 75 s and loses
  /// nothing: a plain poll drains the same mailbox.
  private static let resyncEvery = 4
  /// Said once per process, never per poll. A line every 5 s is a line nobody
  /// reads.
  nonisolated(unsafe) private static var saidSlow = false
  nonisolated(unsafe) private static var saidBusy = false
  nonisolated(unsafe) private static var saidStandDown = false
  /// One line per poll, off by default. A ring loop that stops working stops
  /// PRINTING, and silence is what an idle doorbell looks like too -- so without
  /// this, "nobody called" and "this loop is wedged" are not distinguishable
  /// from outside the process at all. `TK_RING_DEBUG=1`.
  private static let ringDebug = ProcessInfo.processInfo.environment["TK_RING_DEBUG"] != nil

  // ── ONE HANDLE, ONE HOLDER ──────────────────────────────────────────────────
  //
  // There are now two processes that listen for the same person's calls: the
  // menu-bar resident, which runs from login to logout, and the app itself when
  // it is open. Both poll the same mailbox with the same credential, and the
  // server allows one arming per second per handle -- so with both running, one
  // of them is being refused most of the time. That was observed as "429s
  // throughout" before this existed.
  //
  // Two holders is not merely wasteful, it is WRONG: a drain is destructive, so
  // whichever poll returns first takes the ring and the other gets an empty
  // answer. A ring could land on the resident, which launches a second copy of
  // the app, while the copy already open and already able to ring shows nothing.
  //
  // So the app wins and the resident stands down, because the app is the one
  // that can turn a ring into a lit screen with no launch in between. The signal
  // is an exclusive `flock` the app holds for its life: a lock disappears when
  // its holder does, so there is no stale file to reap and no way for a crashed
  // app to leave this Mac uncallable -- which a marker file or a pid file both
  // allow, and which is the worse failure by a distance.
  private static var lockFile: URL { dir.appendingPathComponent("ring.lock") }
  nonisolated(unsafe) private static var lockFd: Int32 = -1

  /// Claim the line for this process, for as long as it lives. Best effort: if
  /// the lock cannot be taken the app still polls, because being rung twice is a
  /// far smaller fault than not being rung at all.
  private static func claimLine() {
    guard lockFd < 0 else { return }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { lockFd = fd } else { close(fd) }
  }

  /// Is some OTHER process holding the line? Asked by the resident before every
  /// poll, and answered by trying the lock rather than by reading anything: the
  /// only fact that matters is whether a live process holds it right now.
  private static func lineHeldByApp() -> Bool {
    if lockFd >= 0 { return false }               // we hold it; nobody else can
    let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
    return true
  }

  /// The listening loop itself, on whatever thread calls it. `until` is a
  /// deadline for the measurement flags; nil means the life of the process.
  ///
  /// Shared with `--rings-for` and with the menu-bar resident on purpose. A rig
  /// with its own copy of this loop measures its own copy: the version this
  /// replaced polled every 2.2 s while the app polled every 5, so the harness
  /// could not have seen the app's real ring latency even in principle.
  ///
  /// `standDown` is for the resident: it yields the mailbox while the app is
  /// open. See the block above `claimLine`.
  ///
  /// `onRing` FIRES ON THIS THREAD, and the hop to main belongs to
  /// `startRinging` rather than here. A loop that always dispatched to main
  /// would deliver nothing at all to `--rings-for`, which runs on main itself
  /// and is inside this loop while such a block waits for main to be free.
  ///
  /// `onTick` runs once per turn of the loop, before anything else, and exists
  /// so the resident's other duties -- noticing a swapped binary, retrying an
  /// unclaimed handle, redrawing its menu bar item -- keep happening on the same
  /// beat they always did. They must run even on a turn this process stands
  /// down, or a Mac whose app is open stops noticing it has been updated.
  static func ringLoop(gapMs: Int = 5000, until: Date? = nil, standDown: Bool = false,
                       onTick: (() -> Void)? = nil,
                       onRing: @escaping (Ring) -> Void) {
    let gap = Double(max(2000, gapMs)) / 1000
    if !standDown { claimLine() }
    var holds = true          // does this server hold? assumed until it says otherwise
    var read = false          // has ONE full body come back yet
    var since = 0             // polls in the current mode, for the two periodic duties
    var trouble = 0.0         // consecutive failures, for the backoff
    func slow(_ why: String) {
      guard !saidSlow else { return }
      saidSlow = true
      fputs("ring: \(why) -- checking for calls every \(Int(gap)) seconds instead\n", stderr)
    }
    /// Say it once, from either of the two answers that can carry the news: a
    /// 204 proves the server held just as well as `waitedMs` does, and a
    /// recovery announced on only one of them is announced on the rarer one.
    func fast() {
      guard !holds else { return }
      holds = true
      since = 0
      fputs("ring: calls are coming through instantly again\n", stderr)
    }
    /// 0.5, 1, 2, 4, then the poll cadence, with jitter. CAPPED AT THE CADENCE,
    /// not at the 30 s a reconnect ladder would use: every second spent backed
    /// off is a second of missed calls, so the worst case here must never be
    /// worse than the thing this replaced.
    func backoff() -> Double {
      trouble += 1
      return min(0.25 * pow(2, trouble), gap) * Double.random(in: 0.75...1.25)
    }
    // REPEAT, not while. `--rings` passes a deadline of now, and a while-loop
    // would evaluate it as already past and drain the mailbox zero times --
    // reporting "no rings" without ever having asked. One poll always happens.
    repeat {
      onTick?()
      if standDown, lineHeldByApp() {
        if !saidStandDown {
          saidStandDown = true
          fputs("watch: Kin is open and listening for calls itself -- standing by\n", stderr)
        }
        // A second is short enough that closing the app makes this Mac callable
        // again straight away, and it costs one uncontended flock.
        Thread.sleep(forTimeInterval: 1)
        continue
      }
      // ── WHICH POLLS ARE PLAIN, AND WHY ANY OF THEM STILL ARE ───────────────
      //
      // A held poll comes back 204 with NO BODY, and the body is where our own
      // silent-mode row comes back from the server. Hold every poll and this
      // device never hears that a "silence for an hour" deadline has passed --
      // the switch would sit there saying nobody can reach you while everybody
      // can. That is the one error in this feature that matters, and it used to
      // be impossible because every 5 s poll re-read it.
      //
      //   · until ONE full body has been read, poll plainly. Not "until the
      //     first poll", which a run of 429s can consume without ever bringing
      //     a body back.
      //   · then one plain poll every few holds, to re-read that row.
      //   · in fallback, the opposite duty: every twelfth poll offers to wait,
      //     so a server deployed since we gave up is noticed. It costs nothing
      //     extra -- that poll is a real poll either way.
      var wait: Int
      if !read { wait = 0 }
      else if holds { wait = since % resyncEvery == resyncEvery - 1 ? 0 : holdMs }
      else { wait = since % reprobeEvery == reprobeEvery - 1 ? holdMs : 0 }
      // Never hold past the caller's own deadline. `--rings-for 30` that armed a
      // 25 s wait at second 29 would run for 54 -- a harness whose stated
      // duration is not its duration, which is how a rig starts lying about
      // everything else it measures. Below the server's own floor for a wait,
      // ask for none.
      if let u = until { wait = min(wait, Int(u.timeIntervalSinceNow * 1000)) }
      if wait < 1000 { wait = 0 }
      since += 1
      let sent = Date()
      let result = pollOnce(waitMs: wait)
      if ringDebug {
        let took = Int(Date().timeIntervalSince(sent) * 1000)
        let what: String
        switch result {
        case .answer(let rs, let h): what = "answer \(rs.count) ring(s) holds=\(h.map(String.init) ?? "-")"
        case .held: what = "held, nothing came"
        case .rate(let ms): what = "429, retry in \(ms) ms"
        case .failed: what = "FAILED"
        }
        fputs("ring: poll #\(since) wait=\(wait) -> \(what) in \(took) ms\n", stderr)
      }
      switch result {
      case .answer(let rings, let serverHolds):
        trouble = 0
        read = true
        if serverHolds == true { fast() }
        else if serverHolds == false, holds {
          holds = false
          since = 0
          slow("this server answers polls instead of holding them")
        }
        // ── EVERY MESSAGE IN THE BATCH, OLDEST FIRST ─────────────────────
        //
        // This used to hand over `rings.max(by: t)` alone and drop the rest of
        // the drained mailbox, on the grounds that a stack of missed calls is a
        // feature nobody asked for. That was true when every message was a ring.
        // It stopped being true the moment a hang-up travelled the same mailbox:
        //
        //   Alice rings (t=1000). Carol rings (t=1001). Alice cancels (t=1002).
        //   One poll drains all three, `max(by: t)` picks Alice's BYE, and
        //   Carol's ring is destroyed -- this Mac never rings for Carol at all.
        //
        // And `t` is integer SECONDS, so a ring and its own cancel inside one
        // second tie, `max(by:)` keeps the first, and the cancel is the one
        // thrown away. Ordered oldest first so a ring is always seen before the
        // bye that ends it; the "no stack of missed calls" rule lives where it
        // belongs, in the receiver's own age guard.
        if !rings.isEmpty {
          for r in rings.sorted(by: { $0.t < $1.t }) { onRing(r) }
          // Arm the next one NOW. A poll that delivered a ring costs no arming
          // budget on the server precisely so this line is free, and the gap it
          // closes is where a second ring would otherwise sit.
        } else if !holds {
          Thread.sleep(forTimeInterval: gap)          // the cadence that always worked
        } else if wait > 0 {
          // An empty answer to a poll that ASKED to be held means the server
          // declined to hold it -- it is at its concurrency cap. Re-arming at
          // once would spin against that cap; wait out the arming window.
          Thread.sleep(forTimeInterval: 1)
        }
        // Otherwise this was a plain poll in hold mode -- the first of the
        // process, or a re-read -- it found nothing, and the very next thing to
        // do is hold the line again. No sleep.
      case .held:
        // The line was held for the full wait and nobody called. Arm another
        // immediately: the gap between two held polls is the only window in
        // which a ring has to sit and wait, so it is kept to one round trip.
        // `read` is deliberately NOT set here: a 204 has no body, so it proves
        // the server holds and proves nothing about our silent-mode row. It can
        // only be reached once a body has already come back anyway, since that
        // is what allows a poll to ask for the wait in the first place.
        trouble = 0
        fast()
      case .rate(let retryMs):
        // A 429 IS NOT AN EMPTY MAILBOX, and the difference is a missed call.
        // Said out loud once, because a doorbell being throttled is the one
        // failure a person would want to know about and it is otherwise
        // indistinguishable from a quiet afternoon.
        if !saidBusy {
          saidBusy = true
          fputs("ring: the server asked this Mac to check for calls less often\n", stderr)
        }
        // Honour the server's own hint, and add our own backoff on top, so a
        // client already refused does not keep asking at exactly the rate that
        // was refused.
        Thread.sleep(forTimeInterval: max(Double(retryMs) / 1000, backoff()))
      case .failed:
        // THREE IN A ROW, counted -- not "the backoff got long", which is the
        // same shape as a rate that was never converted to events per second.
        // One failure is a hiccup; three consecutive is a server or a path that
        // cannot do this, and the answer is the cadence that has always worked.
        let pause = backoff()
        if trouble >= 3, holds { holds = false; since = 0; slow("calls are not coming through quickly") }
        Thread.sleep(forTimeInterval: pause)
      }
    } while until == nil || Date() < until!
  }

  /// Listen for rings for as long as the app is open, on a thread of its own,
  /// and hand every one to main -- the caller draws a window with it.
  static func startRinging(gapMs: Int = 5000, onRing: @escaping (Ring) -> Void) {
    Thread {
      ringLoop(gapMs: gapMs) { r in DispatchQueue.main.async { onRing(r) } }
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

    // ── DOMAIN SEPARATION, WHICH IS THE WHOLE COMPATIBILITY STORY FOR A BYE ──
    //
    // Every version of Kin ever shipped verifies a polled ring against the v1
    // RING string. A `bye` is signed under its own domain precisely so those
    // clients fail that check and drop it -- falling back to the 45 s timeout,
    // which is exactly what they did before byes existed. Sign the same domain
    // and an old client would instead see a valid signature and draw a card for
    // a call nobody is on.
    //
    // Asserted as a PAIR, because a verifier that refuses everything would pass
    // the negative half on its own and would also have killed the doorbell.
    let k = Curve25519.Signing.PrivateKey()
    let (to, from, room, t) = ("meera", "devesh", "abcd-efgh-ijk", 1_800_000_000)
    let ringMsg = ringMessage(to: to, from: from, room: room, t: t)
    let byeMsg  = ringMessage(to: to, from: from, room: room, t: t, kind: "bye")
    eq("ring domain", ringMsg, "kin-ring-v1|meera|devesh|abcd-efgh-ijk|1800000000")
    eq("bye domain", byeMsg, "kin-bye-v1|meera|devesh|abcd-efgh-ijk|1800000000")
    func check(_ what: String, sign: String, verify: String, want: Bool) {
      guard let sig = try? k.signature(for: Data(sign.utf8)) else {
        ok = false; fputs("  FAIL \(what): could not sign\n", stderr); return
      }
      let got = k.publicKey.isValidSignature(sig, for: Data(verify.utf8))
      if got != want { ok = false; fputs("  FAIL \(what): verified=\(got), want \(want)\n", stderr) }
      else { fputs("  ok   \(what) -> verified=\(got)\n", stderr) }
    }
    check("a ring verifies as a ring", sign: ringMsg, verify: ringMsg, want: true)
    check("a bye verifies as a bye", sign: byeMsg, verify: byeMsg, want: true)
    check("a BYE read as a ring is refused", sign: byeMsg, verify: ringMsg, want: false)
    check("and a ring read as a bye is refused", sign: ringMsg, verify: byeMsg, want: false)
    // The room is covered too: a bye lifted from one call must not end another.
    check("a bye for another room is refused", sign: byeMsg,
          verify: ringMessage(to: to, from: from, room: "zzzz-yyyy-xxx", t: t, kind: "bye"),
          want: false)
    return ok
  }

  /// `stripPossessive` is private and the test needs it; exposing it is cheaper
  /// than making the test lie about what it checks.
  static func stripPossessiveT(_ s: String) -> String { stripPossessive(s) }

  // ── A REFUSAL HAS TO SAY WHICH REFUSAL IT WAS ──────────────────────────────
  //
  // `rename` returned `false` for three completely different situations: a name
  // that is not a name, a name that belongs to somebody else, and a server that
  // never answered. A person can act on all three, and they act differently -- pick
  // another name, pick another name, or try again in a minute -- so collapsing them
  // into one boolean means the screen can only ever say the vaguest of the three.
  //
  // This is the same shape as the poll that reported a 429, a 403 and a dead
  // network as an empty mailbox. Silence is a legitimate answer to "is this name
  // free"; it is never a legitimate answer to "did the question get through".
  // ── A HANDLE IS A NAME, AND ON A CARD IT SHOULD LOOK LIKE ONE ──────────────
  //
  // Handles are `^[a-z][a-z0-9]{1,31}$`, so the stored form of a person is
  // `meera`, and the app has always shown that form with an `@` in front of it.
  // That is right where the handle is the SUBJECT -- the row you copy, the name
  // you type, the thing you give somebody so they can reach you.
  //
  // It is wrong on the card that says who is calling. `@meera` is a username
  // convention; a screen reader says "at meera", and the one word on the screen at
  // the moment somebody's Mac is ringing should be a person, not an address. So
  // the card capitalises it and drops the sigil, and every place that is teaching
  // the handle keeps it.
  static func display(_ handle: String) -> String {
    guard let f = handle.first else { return handle }
    return f.uppercased() + handle.dropFirst()
  }

  enum Renamed {
    case ok
    /// Not `^[a-z][a-z0-9]{1,31}$`, so it was never sent.
    case notAName
    /// The server has this name bound to a different key. First come, first served.
    case taken
    /// No answer, or an answer nobody planned for. Nothing was changed.
    case noAnswer
  }

  /// Someone changed their handle in the UI. Only a successful claim moves the
  /// stored name, so a rejected rename leaves them as who they were.
  static func renamed(to raw: String) -> Renamed {
    guard let want = sanitize(raw) else { return .notAName }
    var s = ensure()
    guard want != s.handle || !s.claimed else { return .ok }
    switch attempt(want, s) {
    case 200: break
    case 403: return .taken
    default: return .noAnswer
    }
    s.handle = want; s.claimed = true
    lock.lock(); cached = s; lock.unlock()
    save(s)
    fputs("identity: you are now @\(want)\n", stderr)
    return .ok
  }

  @discardableResult
  static func rename(to raw: String) -> Bool { renamed(to: raw) == .ok }
}
