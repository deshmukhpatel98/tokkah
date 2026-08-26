import Foundation

// ── WHICH SERVER THIS COPY TALKS TO ─────────────────────────────────────────
//
// `https://room.tokkah.com` was written out seven times, across six files. Every
// one of them was correct, and together they made a sentence in the README false:
// you could clone Kin, build it, and the app you built still phoned OUR server.
// An app that can only ever talk to the author's backend is open source in the
// licence and closed in the way that matters to somebody trying to run it.
//
// So the seven literals live here, once, and everything else asks. THREE origins,
// because they are genuinely three things and folding them into one would be a
// lie about how this is actually deployed:
//
//   base     signalling and the small HTTP API -- rendezvous (`/api/room/.../rv`),
//            TURN credentials, telemetry, the handle registry.
//   updates  the release feed. Ed25519-signed, and therefore its own trust
//            boundary -- see the long comment at the top of Update.swift. That is
//            the entire reason it is a separate field and not `base + "/macos"`
//            computed at the point of use: moving where code comes from must be a
//            deliberate, visible act.
//   invite   the origin that goes into a link somebody pastes to a friend. A
//            different HOST from `base` in the shipped configuration --
//            `kin.tokkah.com` is three letters before the dot, short enough to
//            read down a phone -- with the same worker behind it.
//
// ── RESOLUTION ORDER, highest first ─────────────────────────────────────────
//
//   1. `--server <url>`, which sets all three for this run.
//   2. the per-purpose environment variables that already existed: TK_KIN_BASE,
//      TK_UPDATE_BASE. Every rig in mac/tools sets one of these and NONE of them
//      passes `--server`, so every one of them resolves exactly as it did before
//      this file existed. Breaking them would have deleted the only proof the
//      update path has.
//   3. `server.json` in the app's own directory, for the copy that is
//      DOUBLE-CLICKED. A self-hosting switch that exists only as a command-line
//      flag reaches nobody who does not open a terminal, and this project has
//      already shipped one feature that way -- fully built, to zero users.
//   4. the shipped defaults immediately below.
//
// With no flag, no environment variable and no file, every field resolves to the
// exact string that was compiled in at 0.69.0. That is the whole safety property
// of this file: an existing install must not be able to tell it was added. The
// proof is a command, and it is written down in SELF-HOSTING.md.
enum Server {
  // ── The shipped defaults ──────────────────────────────────────────────────
  //
  // Changing one of these changes where every Kin built from this tree points.
  // They are `let`s in one place so that is a one-line, reviewable diff instead
  // of a hunt through six files.
  static let defaultBase = "https://room.tokkah.com"
  static let defaultInvite = "https://kin.tokkah.com"
  /// Spelled as a concatenation rather than as its own literal so the two can
  /// never drift apart, and it still resolves to the byte-identical string that
  /// `Update.base` was compiled with: "https://room.tokkah.com/macos".
  static let defaultUpdates = defaultBase + "/macos"

  /// Where a persisted answer lives.
  ///
  /// Under `Identity.dir`, deliberately, and not in `UserDefaults`: that is keyed
  /// by bundle id and does NOT move with `TK_KIN_DIR` or `HOME`, so a rig that
  /// set it would rewrite the real install's server. This project has been caught
  /// by exactly that (`rig-isolation-that-does-not-isolate`), and the blast
  /// radius here is "the user's app now points at a machine that no longer
  /// exists", which is not a defect you can debug from inside the app.
  static var file: URL { Identity.dir.appendingPathComponent("server.json") }

  /// The persisted shape. Every field optional: a file that sets only `base` is a
  /// legitimate thing to write by hand, and it should not have to restate the
  /// defaults it is not changing.
  ///
  /// THERE IS NO `updateKey` FIELD, AND THAT IS A SECURITY DECISION.
  ///
  /// The compiled-in Ed25519 key is this app's trust root. If a key could be
  /// supplied by a file in `~/Library/Application Support/Kin`, then writing one
  /// user-writable file would be enough to point the updater at an attacker's
  /// host with the attacker's key -- and the payload would then be installed by
  /// Kin's own updater, which re-signs and keeps the app's TCC identity intact.
  /// Overwriting the bundle directly does NOT get an attacker that: it changes
  /// the ad-hoc cdhash, so macOS treats it as a different app and asks for the
  /// camera and microphone again, which is the one thing a user would notice.
  /// So the file may move where updates are FETCHED from -- harmless, because a
  /// manifest we cannot verify is refused -- and may not move what verifies them.
  /// A self-hoster who wants a double-clickable app that updates itself either
  /// launches it with `--update-key`, or builds their own copy with their own key
  /// in `Update.publicKeyHex`. Both are stated plainly in SELF-HOSTING.md.
  struct Stored: Codable {
    var base: String?
    var updates: String?
    var invite: String?
  }

  // ── Everything is decided once, here ──────────────────────────────────────
  //
  // One `static let` holding a struct rather than four separate lazily-resolved
  // statics. Four would each initialise on first touch, on whichever thread got
  // there first, and they would need to share a mutable `problems` array between
  // them -- a data race in the code whose entire job is to be boring. One
  // initialiser, one lock-free answer, and `problems` is a plain `let` inside it.
  private struct Resolved {
    let base: String
    let updates: String
    let invite: String
    /// The 32 raw bytes of a custom update key, or nil for "use the shipped one".
    let updateKeyRaw: Data?
    /// True only when the update feed was moved by the SELF-HOSTING controls
    /// (`--server`, or `server.json`) to somewhere that is not the shipped feed.
    /// See `Update.cannotVerifyReason` for what this gates, and why
    /// `TK_UPDATE_BASE` deliberately does not set it.
    let updatesSelfHosted: Bool
    /// True when the SELF-HOSTING controls were used at all -- `--server`, or a
    /// `server.json` on disk. Deliberately not "the origin differs from the
    /// default": the pre-existing env overrides differ from the default on every
    /// rig run in mac/tools, and none of them wants a new line in its log.
    let selfHosted: Bool
    /// Everything wrong with what was asked for, in plain words. Empty is the
    /// normal case.
    let problems: [String]
  }

  private static let r: Resolved = resolve()

  static var base: String { r.base }
  static var updates: String { r.updates }
  static var invite: String { r.invite }
  static var updateKeyRaw: Data? { r.updateKeyRaw }
  static var updatesSelfHosted: Bool { r.updatesSelfHosted }
  static var selfHosted: Bool { r.selfHosted }

  /// Forces resolution and hands back everything wrong with it. main.swift calls
  /// this once, below the unknown-flag guard and above anything that opens a
  /// socket, and exits rather than starting a call it already knows will fail.
  ///
  /// Because that is the alternative: `--server kin.example.com`, with no scheme,
  /// makes every `URL(string:)` in Stun, Turn, Telemetry and Update return nil,
  /// and every one of those failures is a `return nil` that is indistinguishable
  /// from a network that is simply down. A typo would have read as an outage.
  static func check() -> [String] { r.problems }

  /// The invite origin with the scheme taken off, for places that show it to a
  /// person rather than fetch it. "https://kin.tokkah.com" -> "kin.tokkah.com".
  static var inviteHost: String {
    var s = invite
    for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
    return s
  }

  /// One line naming every origin, for `--server-print` and for the log. Written
  /// as one string on purpose: the failure this is here to catch is two origins
  /// disagreeing, and you cannot see that in three separate log lines a minute
  /// apart.
  static func describe() -> String {
    "base=\(base) updates=\(updates) invite=\(invite)"
      + " update-key=\(updateKeyRaw == nil ? "built-in" : "custom")"
  }

  /// Every origin this program will actually use, read back from the LIVE values
  /// rather than rebuilt from the defaults.
  ///
  /// This is the instrument the default-unchanged proof is made with, so it must
  /// not be a second copy of the answer -- a report that recomputes what it is
  /// reporting can agree with itself while both halves are wrong. `Telemetry`,
  /// `Update` and `Identity` are asked for the strings they are holding; only the
  /// two that are default arguments on a function (`Rendezvous.exchange`,
  /// `TurnClient.fetch`) are named by the origin they take, because a default
  /// argument cannot be read without calling the thing.
  static func report() -> String {
    let key = updateKeyRaw.map { _ in "custom (--update-key/TK_UPDATE_KEY)" }
      ?? "built-in \(Update.publicKeyHex.prefix(8))…"
    return """
    base             \(base)
    identity         \(Identity.base)
    rendezvous       \(base)/api/room/<room>/rv
    turn             \(base)/api/mac/turn
    telemetry-beat   \(Telemetry.endpoint)
    telemetry-crash  \(Telemetry.crashEndpoint)
    updates          \(Update.base)
    invite           \(invite)/<room>
    update-key       \(key)
    """
  }

  // ── Resolution ────────────────────────────────────────────────────────────

  private static func resolve() -> Resolved {
    let env = ProcessInfo.processInfo.environment
    var problems: [String] = []

    /// Trim, drop trailing slashes, and insist on a scheme and a host.
    ///
    /// The trailing slash matters more than it looks: `--server https://x.dev/`
    /// would otherwise build `https://x.dev//api/mac/turn`, which some servers
    /// route and some 404, so it would work on the machine it was tested on.
    func clean(_ raw: String, _ what: String) -> String? {
      var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      while s.hasSuffix("/") { s.removeLast() }
      guard s.hasPrefix("https://") || s.hasPrefix("http://") else {
        problems.append("\(what) is \"\(raw)\" -- it needs a scheme on the front,"
                      + " like https://\(s.isEmpty ? "your-server.example" : s)")
        return nil
      }
      guard let u = URL(string: s), let h = u.host, !h.isEmpty else {
        problems.append("\(what) is \"\(raw)\" -- that is not a URL this build can parse")
        return nil
      }
      return s
    }

    // `--server`. Read through main.swift's own `arg()`, so a forgotten value
    // (`--server --room x`) is refused there, once, in the same words as every
    // other flag in this program.
    let flagBase = arg("server").flatMap { clean($0, "--server") }

    // ── base ────────────────────────────────────────────────────────────────
    let storedFile = readStored(&problems)
    let base = flagBase
      ?? env["TK_KIN_BASE"].flatMap { clean($0, "TK_KIN_BASE") }
      ?? storedFile?.base.flatMap { clean($0, "\"base\" in \(file.path)") }
      ?? defaultBase

    // ── updates, and where the answer came from ─────────────────────────────
    //
    // The provenance is computed HERE, in the same if/else that picks the value,
    // rather than inferred afterwards from "is it the default?". Inferring it
    // would get the mixed case wrong -- `server.json` setting `updates` while
    // TK_UPDATE_BASE is also set resolves to the env var, and must therefore be
    // treated as the rig override it is.
    //
    // WHY TK_UPDATE_BASE IS NOT SELF-HOSTING: it has been the update rig's
    // override since long before this file, and `mac/tools/update-check.sh`
    // signs its own manifests WITH THE REAL PRIVATE KEY precisely because there
    // was no key override to use -- its own line 111 says so. Treating that as
    // self-hosting would fail every one of those arms closed and destroy the
    // only end-to-end proof the updater has. It keeps today's exact semantics:
    // fetched from wherever it points, verified against the shipped key.
    let updates: String
    let selfHosted: Bool
    if let f = flagBase {
      updates = f + "/macos"; selfHosted = true
    } else if let e = env["TK_UPDATE_BASE"] {
      updates = clean(e, "TK_UPDATE_BASE") ?? defaultUpdates; selfHosted = false
    } else if let s = storedFile?.updates, let c = clean(s, "\"updates\" in \(file.path)") {
      updates = c; selfHosted = true
    } else {
      updates = defaultUpdates; selfHosted = false
    }

    // ── invite ──────────────────────────────────────────────────────────────
    //
    // Cannot be derived from `base` by concatenation the way `updates` can: in
    // the shipped configuration it is a different hostname entirely. A
    // self-hoster running one origin gets that origin, which is the right answer
    // for a deployment that is one worker.
    let invite = flagBase
      ?? env["TK_INVITE_BASE"].flatMap { clean($0, "TK_INVITE_BASE") }
      ?? storedFile?.invite.flatMap { clean($0, "\"invite\" in \(file.path)") }
      ?? defaultInvite

    // ── the update key ──────────────────────────────────────────────────────
    var keyRaw: Data?
    if let text = arg("update-key") ?? env["TK_UPDATE_KEY"] {
      let what = arg("update-key") != nil ? "--update-key" : "TK_UPDATE_KEY"
      if let d = keyBytes(text) {
        keyRaw = d
      } else {
        // Loud, and fatal at the call site. A key that does not parse must never
        // read as "no key given", because "no key given" means "use the shipped
        // one" -- so a typo would silently restore the very trust root the person
        // was trying to replace.
        problems.append("\(what) is not a 32-byte Ed25519 public key."
                      + " Give it as base64 (44 characters) or hex (64 characters).")
      }
    }

    return Resolved(base: base, updates: updates, invite: invite,
                    updateKeyRaw: keyRaw, updatesSelfHosted: selfHosted && updates != defaultUpdates,
                    selfHosted: flagBase != nil || storedFile != nil,
                    problems: problems)
  }

  /// A missing file is the normal case and says nothing. A file that EXISTS and
  /// cannot be used says so out loud -- a config file that is silently ignored is
  /// how somebody spends an afternoon wondering why their setting does nothing,
  /// and it is the same silent-no-op class as a misspelled flag.
  private static func readStored(_ problems: inout [String]) -> Stored? {
    let path = file.path
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    guard let d = try? Data(contentsOf: file) else {
      problems.append("\(path) exists but cannot be read")
      return nil
    }
    guard let s = try? JSONDecoder().decode(Stored.self, from: d) else {
      problems.append("\(path) is not the JSON this build understands"
                    + " -- expected {\"base\": \"https://...\"}")
      return nil
    }
    return s
  }

  /// 32 raw bytes from base64 or hex.
  ///
  /// Both forms are accepted because the key that ships is written as HEX three
  /// lines into Update.swift, and that is the form somebody will copy when they
  /// want a build that trusts the official feed from their own mirror. The two
  /// are unambiguous by alphabet and length, and anything that is neither is
  /// refused rather than truncated into a key that can never verify anything.
  static func keyBytes(_ s: String) -> Data? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.count == 64, t.allSatisfy({ $0.isHexDigit }) {
      var d = Data(); var i = t.startIndex
      while i < t.endIndex {
        let j = t.index(i, offsetBy: 2)
        guard let b = UInt8(t[i..<j], radix: 16) else { return nil }
        d.append(b); i = j
      }
      return d.count == 32 ? d : nil
    }
    guard let d = Data(base64Encoded: t), d.count == 32 else { return nil }
    return d
  }

  // ── Writing the persisted answer ──────────────────────────────────────────
  //
  // `--save-server` and `--forget-server` are a PAIR, and the second one is not
  // optional politeness. A setting that points the app at a host and cannot be
  // undone without editing JSON in a Library folder is a trap: the failure mode
  // is an app that launches, reaches nothing, and gives the person no way back.

  /// Writes the origins this command line resolves to. Returns a sentence.
  static func save() -> String {
    let s = Stored(base: base, updates: updates, invite: invite)
    do {
      try FileManager.default.createDirectory(at: Identity.dir, withIntermediateDirectories: true)
      let enc = JSONEncoder()
      enc.outputFormatting = [.prettyPrinted, .sortedKeys]
      try enc.encode(s).write(to: file, options: .atomic)
    } catch {
      return "server: could not write \(file.path): \(error)"
    }
    return "server: wrote \(file.path)\n  \(describe())\n"
      + "  this copy will use those origins from now on; --forget-server undoes it."
      + (updatesSelfHosted
         ? "\n  updates are OFF for this server until it is launched with --update-key:"
         + " a release that cannot be signature-checked is not installed. See SELF-HOSTING.md."
         : "")
  }

  /// Removes it. Saying "there was nothing to remove" is a different fact from
  /// "removed", and both are printed rather than being inferred from silence.
  static func forget() -> String {
    let path = file.path
    guard FileManager.default.fileExists(atPath: path) else {
      return "server: nothing saved at \(path) -- already using the built-in server"
    }
    do { try FileManager.default.removeItem(at: file) } catch {
      return "server: could not remove \(path): \(error)"
    }
    return "server: removed \(path) -- back to \(defaultBase)"
  }
}
