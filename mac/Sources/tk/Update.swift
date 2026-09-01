import CryptoKit
import Darwin
import Foundation

// ── Self-update ─────────────────────────────────────────────────────────────
//
// Exists because one of the two machines under test is 15 km away in someone
// else's house. A fix that requires a person to walk to that machine is a fix
// that lands once a week, and this project needs it to land in minutes.
//
// SIGNED, not merely downloaded. An updater that installs whatever a URL serves
// is a remote-code-execution channel into both machines -- if DNS, the CDN, the
// bucket, or the account is ever wrong for one minute, it executes as the user.
// So the manifest carries an Ed25519 signature, the public key is compiled in
// below, and an unverifiable manifest is a no-op rather than a prompt. There is
// no override flag on purpose: a security control with a bypass is decoration.
//
// Notarisation is deliberately NOT part of this. Files fetched by curl are not
// quarantined -- only quarantine-aware apps like browsers set that attribute --
// so an install and an update over curl never meet Gatekeeper and need no Apple
// Developer ID. The signature above is ours and does the job Apple's would.
enum Update {
  /// The key this app SHIPS with, and the trust root for every release ever
  /// installed by a copy of it. Still compiled in, still the default, and still
  /// the only key in play unless this run was launched with `--update-key`.
  static let publicKeyHex = "d07822edb36c8692c83f3478c26683102cd3cf6fb1d0c263496404c15fd95b2a"

  /// The key THIS RUN verifies with: a self-hoster's, if they supplied one, and
  /// the shipped one otherwise.
  ///
  /// Optional, and nothing below is allowed to proceed without it. There is no
  /// branch here that treats "no usable key" as "skip the check" -- that is the
  /// single bug in an updater that ends with somebody else's code running as the
  /// user, so it fails closed, loudly, and with no flag that changes its mind.
  static let publicKey: Curve25519.Signing.PublicKey? = {
    guard let raw = Server.updateKeyRaw ?? hex(publicKeyHex) else { return nil }
    return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
  }()

  /// Where releases are fetched from. Resolved once, in Server.swift.
  ///
  /// `TK_UPDATE_BASE` is unchanged and still means exactly what it meant: the
  /// update-path rig's override. Safe to expose for the reason it always was --
  /// everything fetched from here is Ed25519-verified before a byte of it is
  /// trusted, so pointing it elsewhere cannot inject code, only offer releases
  /// the key already trusted signed. `mac/tools/update-check.sh` depends on that
  /// and signs its own manifests with the real key; moving it would delete the
  /// only end-to-end proof this updater has.
  static let base = Server.updates

  // ── A SERVER WE CANNOT CHECK IS A SERVER WE DO NOT INSTALL FROM ───────────
  //
  // `--server https://kin.example.com` points a self-hoster's copy at their own
  // release feed. Their releases are signed with THEIR key, which this build does
  // not have -- so every manifest they serve fails the signature check below, and
  // fails it correctly.
  //
  // What was wrong was the SENTENCE. The refusal that came out was "an update was
  // refused because it wasn't signed by Kin" -- the wording for an attack in
  // progress, put in front of somebody whose only mistake was not passing a
  // second flag. So the case is NAMED, before the fetch, instead of being
  // discovered after it.
  //
  // This is not a way past the gate and it does not make verification
  // conditional. It is an extra refusal in FRONT of a check that still runs,
  // unchanged, on every byte that gets past it. It can only ever turn an install
  // into a no-op, never a no-op into an install. There is still no flag that
  // skips a signature and there is still no unsigned path.
  private static var cannotVerifyReason: String? {
    guard Server.updatesSelfHosted, Server.updateKeyRaw == nil else { return nil }
    return "pointed at \(base) for updates with no key to check it against"
         + " -- this build has only Kin's own update key, which did not sign that"
         + " server's releases. Pass --update-key <base64> (or set TK_UPDATE_KEY)"
         + " with the public half of the key that signs \(base)/manifest.json."
         + " Nothing will be installed until then."
  }

  // ── AN UPDATER THAT COULD NOT REPORT ITS OWN FAILURE ───────────────────────
  //
  // Everything below used to end at `return nil`. Six different endings -- the
  // server unreachable, the signature file missing, the signature not even
  // base64, the manifest not JSON, the payload not unpacking, and the manifest
  // simply not being newer -- arrived at the same place, in the same silence, and
  // reached the person as nothing at all.
  //
  // That is `blind-instruments-report-negatives` in the one mechanism that can
  // brick a Mac: an instrument that cannot see the event returns the same value
  // as a real negative, so an updater that cannot say why it did nothing reports
  // success by staying quiet. The Ed25519 refusal is the worst of them, because
  // it is the security boundary DOING ITS JOB -- and it looked exactly like "you
  // are already up to date".
  //
  // So each ending gets its own sentence. Nothing here weakens a check: a refused
  // manifest is still refused, the key still has no override, and the change is
  // entirely about SAYING SO.

  /// Who hears about an outcome.
  ///
  /// Not every failure is the person's business. A download that failed mid-call
  /// is not something they can act on, and overwriting the call's own status line
  /// with it once a minute would be exactly the lab-instrument noise the consumer
  /// surface is not allowed to carry. But a person who OPENED THE MENU and asked
  /// is owed an answer whatever it is -- including "nothing".
  private enum Reach {
    /// Only when somebody asked. The answer to a question they just put.
    case answer
    /// Always. Something they can act on, or must know about: this copy cannot
    /// install anything, or a release was refused by the signature gate.
    case act
  }

  /// The last sentence put in front of the person, so a poller finding the same
  /// thing wrong every minute does not repaint the status line every minute.
  /// Cleared whenever a check completes cleanly, so a problem that comes BACK is
  /// announced again rather than being suppressed forever by its own first
  /// occurrence.
  nonisolated(unsafe) private static var said: String?

  /// Whether anything went wrong during the tick that is running now. The poller
  /// clears `said` at the end of a tick that raised nothing, which is what makes
  /// the line above true in both directions: a standing problem is stated once,
  /// and a problem that GOES AWAY and comes back is stated again.
  ///
  /// It was `said = nil` on every successfully-verified manifest instead, and that
  /// is subtly wrong: a release whose binary refuses to launch verifies its
  /// manifest perfectly every single time, so the failure downstream of it would
  /// have repainted the person's status line once a minute forever.
  nonisolated(unsafe) private static var raised = false

  /// True for the duration of a check somebody asked for from the menu. Set from
  /// the poller, which is the only place that knows the difference between
  /// `urgent` meaning "a person clicked Check for Updates" and `urgent` meaning
  /// "the peer is on a different build".
  nonisolated(unsafe) private static var asked = false

  /// Puts a sentence where a person is looking, and says whether anything was
  /// there to receive it.
  ///
  /// NOT a callback assigned in main.swift. A hook declared here and assigned
  /// nowhere reads as finished and tells nobody -- three of those have shipped in
  /// this app already (`dead-controls-declared-never-wired`). `Menu.controls` has
  /// exactly one assignment site, in Display.swift where the window is built, and
  /// it is already the surface the menu's own Check for Updates item writes
  /// "checking for updates…" to. This is the other half of that sentence.
  ///
  /// False means there was no window -- the headless CLI, and `tk --watch`, which
  /// is the process most likely to be the one that found the problem. "Nobody was
  /// there to be told" is a different fact from "nothing was wrong", and it is
  /// printed as one rather than being inferred from silence.
  private static func show(_ s: String) -> Bool {
    guard let c = Menu.controls else { return false }
    c.setStatus(s)          // hops to main on its own
    return true
  }

  private static func note(_ line: String) { fputs("update: \(line)\n", stderr) }

  // ── THE UPDATER HAD NO TELEMETRY AT ALL ────────────────────────────────────
  //
  // Reported as "the Mac mini would not update itself, I closed and opened it a
  // few times". The analytics could not answer it, and not because the answer
  // was hidden: this file recorded NOTHING. No check, no outcome, no refusal --
  // 0 `Metrics.` calls in 1200 lines, while every other subsystem reports. The
  // one machine-readable trace of an update was the version number changing on
  // the NEXT call somebody happened to make, so a Mac that updated late and a
  // Mac that simply did not call looked identical.
  //
  // `stage` is the furthest point this copy reached, last writer wins, so one
  // short string says where it stopped. The counters say how often. Both are
  // one dictionary write on a thread that is already doing HTTPS, which is the
  // cheapest thing in the function by several orders of magnitude.
  private static func atStage(_ s: String) { Metrics.fact("update_stage", s) }

  /// Set by the `--watch` image only. The app in a call already beats every few
  /// seconds and does not need a second channel; the background watcher is the
  /// one that never said anything.
  nonisolated(unsafe) static var reportsAsWatcher = false

  /// One outcome: a line for the log, always, and a sentence for the person when
  /// this is one they asked for or one they can do something about.
  private static func tell(_ line: String, _ human: String, _ reach: Reach) {
    note(line)
    switch reach {
    case .answer:
      guard asked else { return }
    case .act:
      raised = true
      guard asked || human != said else { return }
      said = human
    }
    note(show(human) ? "told the window: \(human)" : "nothing on screen to tell: \(human)")
  }

  struct Manifest: Decodable {
    let version: String; let url: String; let sha256: String; let notes: String?
    /// The name the app should be called on disk, when that has changed.
    ///
    /// Optional, and absent from every manifest written so far -- which is the
    /// point. A rename cannot be shipped in one release: the code that has to move
    /// the files is the code ALREADY INSTALLED, and it does not know how. So the
    /// ability ships first and lies dormant, and the release after it sets this
    /// field and every install migrates itself. Ship the flip in the same release
    /// as the ability and you strand exactly the people who have not updated yet.
    let appName: String?
  }

  // "0.10.2" > "0.9.9": compared as numbers, per component. String comparison
  // gets this wrong at exactly the version where it starts to matter.
  static func newer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
      let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
      if p != q { return p > q }
    }
    return false
  }

  private static func get(_ url: String, timeout: TimeInterval = 12) -> Data? {
    guard let u = URL(string: url) else { return nil }
    var out: Data?
    let sem = DispatchSemaphore(value: 0)
    var req = URLRequest(url: u)
    req.timeoutInterval = timeout
    req.cachePolicy = .reloadIgnoringLocalCacheData
    URLSession.shared.dataTask(with: req) { d, r, _ in
      if let h = r as? HTTPURLResponse, h.statusCode == 200 { out = d }
      sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 2)
    return out
  }

  private static func hex(_ s: String) -> Data? {
    var d = Data(); var i = s.startIndex
    while i < s.endIndex {
      let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
      guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
      d.append(b); i = j
    }
    return d
  }

  /// The version last offered by the server, so "nothing to install" is logged
  /// when the answer CHANGES rather than once a minute for the life of a watcher
  /// that runs from login to logout.
  nonisolated(unsafe) private static var lastOffered: String?

  /// Returns the version that is available and verified, or nil.
  ///
  /// One guard used to cover the first five failures here. They are five different
  /// events with five different meanings and only one of them is anybody's fault,
  /// so they are now five different lines -- see the Reach comment above for why
  /// only some of them reach the window.
  static func available(current: String) -> (Manifest, Data)? {
    if let why = cannotVerifyReason {
      atStage("no-key"); Metrics.count("update_fail")
      tell(why, "Kin isn’t set up to install updates from your own server", .act)
      return nil
    }
    guard let mData = get("\(base)/manifest.json") else {
      atStage("unreachable"); Metrics.count("update_unreachable")
      tell("cannot reach \(base) for manifest.json", "couldn’t check for updates", .answer)
      return nil
    }
    // A manifest without its signature is not a manifest we are allowed to read.
    // Worth its own line because it is the shape a half-published release takes:
    // the JSON is up and the .sig is not, and the app that finds it is refusing
    // something that is genuinely ours.
    guard let sigB64 = get("\(base)/manifest.json.sig") else {
      tell("manifest.json is there but manifest.json.sig is not -- refusing an unsigned manifest",
           "couldn’t check for updates", .answer)
      return nil
    }
    // Refused SILENTLY before this line, and update-check.sh had a comment saying
    // so: "a signature that is not even base64 is refused with no line on stderr
    // at all -- the same verdict for a corrupted file as for an attack." They are
    // not the same event and they no longer read the same.
    guard let sig = Data(base64Encoded: String(decoding: sigB64, as: UTF8.self)
                          .trimmingCharacters(in: .whitespacesAndNewlines)) else {
      tell("manifest.json.sig is not base64 -- the signature file did not arrive intact",
           "couldn’t check for updates", .answer)
      return nil
    }
    guard let pk = publicKey else {
      // Unreachable unless the constant at the top of this file is edited wrong.
      // A bad `--update-key` cannot land here either: a value that is not 32 bytes
      // is refused by Server.check() at startup, before anything opens a socket,
      // because "the key did not parse" must never quietly become "use the shipped
      // key instead" -- that would restore the exact trust root the person was
      // replacing. And precisely because this is unreachable it must not be
      // silent: a build in this state can never accept any release again, and
      // would look like a Mac that simply stopped receiving updates.
      tell("the compiled-in public key does not parse -- this build can never verify a release",
           "Kin can’t check for updates — please install it again", .act)
      return nil
    }
    // VERIFY BEFORE PARSE. Parsing attacker-controlled JSON is a smaller risk
    // than acting on it, but it is not zero, and the order costs nothing.
    guard pk.isValidSignature(sig, for: mData) else {
      // ── THE ONE THAT MATTERS MOST ──────────────────────────────────────────
      //
      // This is the gate working. Either somebody is serving a manifest we did
      // not sign, or a release went out wrong -- and in both cases Kin has
      // STOPPED updating itself and will go on not updating itself, which the
      // person had no way to find out. `.act`, so it reaches the window even
      // though nobody asked.
      atStage("bad-signature"); Metrics.count("update_fail")
      tell("manifest signature INVALID -- ignoring",
           "an update was refused because it wasn’t signed by Kin", .act)
      return nil
    }
    guard let m = try? JSONDecoder().decode(Manifest.self, from: mData) else {
      tell("the manifest verified but is not the JSON this build understands",
           "couldn’t check for updates", .answer)
      return nil
    }
    guard newer(m.version, than: current) else {
      if asked || m.version != lastOffered {
        lastOffered = m.version
        atStage("current")
        tell("\(base) offers \(m.version) and this is \(current) -- nothing to install",
             "Kin is up to date", .answer)
      }
      return nil
    }
    lastOffered = m.version
    return (m, mData)
  }

  // ── CAN THIS COPY INSTALL ANYTHING AT ALL? ──────────────────────────────────
  //
  // Asked BEFORE the download, which is the whole point of it.
  //
  // /Applications is drwxrwxr-x root:admin. On a Mac where an admin installed Kin
  // and the person using it every day is a standard account, every poll fetched
  // the manifest, fetched the entire release, failed at the swap, dropped the
  // staged copy on the floor and did the same thing again on the next tick --
  // every 30 minutes, forever, with nothing visible anywhere. Measured against
  // the previous build by the read-only arm of update-check.sh: the whole 2.3 MB
  // archive fetched twice inside a 14-second window at a 3 s poll (the rig's
  // earlier note records three). At the production interval that is roughly 48
  // downloads a day of a thing that can never install, on somebody else's battery
  // and somebody else's data, while the app looks perfectly healthy.
  //
  // Two places, and either one is enough, because there are two install paths:
  //   the .app's PARENT directory -- what `swapBundle` needs. It stages a sibling
  //                                  and RENAME_SWAPs; it never writes inside the
  //                                  bundle it is replacing.
  //   Contents/MacOS              -- what the legacy binary-only path needs.
  // So this says no only when NEITHER path could possibly work. A preflight that
  // is stricter than the thing it guards would stop updates on installs that
  // update perfectly well today, which is a far worse failure than the one being
  // fixed.
  //
  // access(2) through FileManager, the same call Install.swift uses to choose
  // between /Applications and ~/Applications -- so the two halves of "where can
  // this app live" cannot disagree.
  //
  /// nil when this copy could install an update. Otherwise a line for the log and
  /// a sentence for the person, in that order.
  static func installBlocker() -> (log: String, human: String)? {
    let fm = FileManager.default
    let me = selfPath()
    guard me.path.contains("/Contents/MacOS/") else {
      // The bare CLI at ~/.local/bin/tk. `commit` writes `.tk.new` beside it and
      // renames over itself, so the directory is what has to be writable.
      let dir = me.deletingLastPathComponent()
      guard !fm.isWritableFile(atPath: dir.path) else { return nil }
      return ("\(dir.path) is not writable -- this command-line copy cannot replace itself",
              "Kin can’t update itself where it is")
    }
    let macos = me.deletingLastPathComponent()
    let appDir = macos.deletingLastPathComponent().deletingLastPathComponent()
    let parent = appDir.deletingLastPathComponent()
    if fm.isWritableFile(atPath: parent.path) { return nil }   // swapBundle can work
    if fm.isWritableFile(atPath: macos.path) { return nil }    // the legacy path can work
    // Named, because the two cases have different answers. Moving the app is the
    // fix everywhere except /Applications, where moving it is the one thing a
    // standard account cannot do.
    if parent.path == "/Applications" {
      return ("\(appDir.path) is in /Applications and this account can write neither it nor"
            + " the bundle -- /Applications is root:admin, so this is a standard account",
              "Kin can’t update itself in Applications — an admin needs to allow it")
    }
    return ("neither \(parent.path) nor \(macos.path) is writable -- this copy cannot replace itself",
            "Kin can’t update itself where it is — move it to your Applications folder")
  }


  /// Where this executable lives, resolved the same way in every path.
  private static func selfPath() -> URL {
    Bundle.main.executableURL?.resolvingSymlinksInPath()
      ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
  }

  /// The version the BUNDLE claims, which is what macOS and Finder show. Nil when
  /// not in a bundle.
  static func bundleVersion() -> String? {
    let me = selfPath()
    guard me.path.contains("/Contents/MacOS/") else { return nil }
    let plist = me.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Info.plist")
    guard let d = try? Data(contentsOf: plist),
          let any = try? PropertyListSerialization.propertyList(from: d, format: nil),
          let dict = any as? [String: Any] else { return nil }
    return dict["CFBundleShortVersionString"] as? String
  }

  // ── THE BUNDLE, NOT JUST THE BINARY ────────────────────────────────────────
  //
  // The tarball used to be exactly one executable, so `Contents/` was frozen at
  // install time forever. The evidence was sitting on this machine: a bundle whose
  // Info.plist said 0.28.0 wrapped around a binary reporting 0.33.0, five releases
  // later. Cosmetic on its own -- and fatal the moment a release changes anything
  // OUTSIDE the executable. A new icon, a new URL scheme, a new usage string for a
  // permission prompt: all of it would ship, verify, install, and reach nobody who
  // already had the app.
  //
  // Best-effort per file: a bundle that updated its binary and kept an old icon
  // still works, and refusing the whole update over a resource would throw away
  // the fix it was carrying.
  @discardableResult
  private static func installBundle(from tmp: URL, version: String) -> [String] {
    let fm = FileManager.default
    let me = selfPath()
    guard me.path.contains("/Contents/MacOS/") else { return [] }
    let contents = me.deletingLastPathComponent().deletingLastPathComponent()
    let src = tmp.appendingPathComponent("bundle")
    var applied: [String] = []
    // Info.plist carries the version macOS shows, so it is templated the same way
    // release.sh does it -- the archive holds __VERSION__ and the placeholder is
    // filled in here rather than shipping a plist per release.
    if let raw = try? String(contentsOf: src.appendingPathComponent("Info.plist"), encoding: .utf8) {
      let filled = raw.replacingOccurrences(of: "__VERSION__", with: version)
      if (try? filled.write(to: contents.appendingPathComponent("Info.plist"),
                            atomically: true, encoding: .utf8)) != nil {
        applied.append("Info.plist")
      }
    }
    let res = contents.appendingPathComponent("Resources")
    try? fm.createDirectory(at: res, withIntermediateDirectories: true)
    for name in ["AppIcon.icns"] {
      let from = src.appendingPathComponent(name)
      guard fm.fileExists(atPath: from.path) else { continue }
      let to = res.appendingPathComponent(name)
      try? fm.removeItem(at: to)
      if (try? fm.copyItem(at: from, to: to)) != nil { applied.append(name) }
    }
    if !applied.isEmpty {
      fputs("update: refreshed \(applied.joined(separator: ", "))\n", stderr)
      // The icon is cached by the Dock and Finder per bundle path, so a new one is
      // invisible until something tells them to look again. `touch` on the bundle
      // is what LaunchServices watches.
      let touch = Process()
      touch.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
      touch.arguments = [contents.deletingLastPathComponent().path]
      touch.standardError = FileHandle.nullDevice
      if (try? touch.run()) != nil { touch.waitUntilExit() }
    }
    return applied
  }

  /// Replaces the enclosing `.app` with the already-signed bundle from a staged
  /// archive, in one atomic exchange. Returns false when the archive carries no
  /// bundle payload, or carries one under a different name than the app being
  /// updated, in which case the caller falls back to the legacy path.
  private static func swapBundle(from tmp: URL, at me: URL) -> Bool {
    let fm = FileManager.default
    guard me.path.contains("/Contents/MacOS/") else { return false }
    let appDir = me.deletingLastPathComponent()   // MacOS
      .deletingLastPathComponent()                // Contents
      .deletingLastPathComponent()                // Kin.app
    // Matched by name on purpose. A copy still called Tokkah.app is mid-rename,
    // and the legacy path below is what knows how to move it -- swapping a
    // Kin.app payload onto a Tokkah.app path would leave the directory and the
    // bundle disagreeing about what the app is called. Those copies rename on
    // this update and swap on the next one.
    let src = tmp.appendingPathComponent(appDir.lastPathComponent)
    guard fm.fileExists(atPath: src.path) else { return false }
    guard fm.fileExists(atPath: src.appendingPathComponent(
            "Contents/MacOS/\(me.lastPathComponent)").path) else {
      fputs("update: staged bundle has no \(me.lastPathComponent) -- using legacy path\n", stderr)
      return false
    }
    // Staged beside the app so the exchange below is a rename within one volume
    // rather than a copy that could be interrupted half way through.
    //
    // ── AND UNDER THIS PROCESS'S OWN NAME ─────────────────────────────────────
    //
    // This was one fixed path, `.Kin.app.new`, and the moment the watcher grew an
    // update poller of its own there were two processes on one Mac that could be
    // inside this function at the same time. What that does is not a failed
    // update -- it is a SUCCESSFUL one that installs an incomplete bundle:
    // each `removeItem` below deletes files out of the other's in-flight `ditto`,
    // ditto returns 0 having copied what was left, and RENAME_SWAP puts the short
    // tree in place atomically and silently. Measured on this machine with a
    // 6000-file payload: four runs in six installed a bundle missing 3-9% of its
    // files, with no error printed by either process.
    //
    // The missing files are not random. `ditto` walks Contents in directory
    // order -- Info.plist, MacOS, PkgInfo, Resources, _CodeSignature -- so what
    // gets dropped is the tail, and the tail is the signature. A bundle missing
    // `_CodeSignature/` still launches and still reports the right version, and
    // `codesign --verify` says "invalid resource directory". The designated
    // requirement is what macOS pins a camera or microphone grant to, so the
    // visible symptom is the app asking for the camera again for no reason
    // anybody could ever trace -- which is the exact bug the certificate signing
    // in mkapp.sh exists to prevent.
    //
    // Two updaters now stage into two directories, each copies a complete tree,
    // and the two RENAME_SWAPs simply happen one after the other. There is no
    // moment at which the live path holds a partial bundle.
    let parent = appDir.deletingLastPathComponent()
    let stem = ".\(appDir.lastPathComponent).new."
    let next = parent.appendingPathComponent("\(stem)\(getpid())")
    try? fm.removeItem(at: next)
    // A per-process name leaks a full copy of the app if an updater is killed
    // mid-ditto, where the single fixed path used to be reused by the next one.
    // So sweep -- but only copies whose process is GONE. Deleting a live
    // updater's staging tree is precisely the defect above, and a cleanup that
    // reintroduced it would be worse than the leak.
    if let sibs = try? fm.contentsOfDirectory(atPath: parent.path) {
      for s in sibs where s.hasPrefix(stem) {
        guard let pid = Int32(s.dropFirst(stem.count)), pid != getpid() else { continue }
        if kill(pid, 0) == 0 || errno == EPERM { continue }   // still running
        try? fm.removeItem(at: parent.appendingPathComponent(s))
      }
    }
    // `ditto`, not copyItem: it carries the extended attributes parts of a
    // signature live in. A bundle that arrives without them stops verifying, and
    // on a machine with no signing key that damage is permanent.
    let cp = Process()
    cp.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    cp.arguments = [src.path, next.path]
    cp.standardOutput = FileHandle.nullDevice
    cp.standardError = FileHandle.nullDevice
    guard (try? cp.run()) != nil else { return false }
    cp.waitUntilExit()
    guard cp.terminationStatus == 0 else {
      // `installBlocker` is supposed to have caught this before the download was
      // ever spent. It is still checked here: the preflight reads a permission and
      // this reads the outcome, and a permission can change between the two.
      tell("cannot stage a bundle next to \(appDir.path) -- is it writable?",
           installBlocker()?.human ?? "Kin can’t update itself where it is", .act)
      try? fm.removeItem(at: next); return false
    }
    // RENAME_SWAP exchanges the two directories in a single step. Plain rename(2)
    // cannot: the destination is a non-empty directory. Remove-then-move would
    // leave a window in which the app does not exist at all, and a crash or a
    // power cut inside that window uninstalls the program.
    guard renamex_np(next.path, appDir.path, UInt32(RENAME_SWAP)) == 0 else {
      tell("bundle swap failed (errno \(errno))",
           "Kin couldn’t install its update — the app is unchanged", .act)
      try? fm.removeItem(at: next); return false
    }
    try? fm.removeItem(at: next)   // now holds the bundle we just replaced
    // LaunchServices and the Dock cache the icon per bundle path.
    let touch = Process()
    touch.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
    touch.arguments = [appDir.path]
    touch.standardError = FileHandle.nullDevice
    if (try? touch.run()) != nil { touch.waitUntilExit() }
    return true
  }

  /// Ad-hoc re-sign of the enclosing bundle. macOS ties a microphone or camera
  /// grant to the CODE SIGNATURE of the thing that asked, so a bundle whose
  /// contents changed under its signature is treated as a different application and
  /// the prompts come back mid-conversation. Best-effort by design: a failure costs
  /// a prompt, and refusing to update over it would cost the fix.
  ///
  /// Takes the bundle explicitly. It used to re-derive the path from
  /// `Bundle.main.executableURL`, which is captured at launch -- so on the one
  /// update that also RENAMES the bundle, this ran against a path that no longer
  /// existed, failed, and left the moved copy carrying a signature computed over
  /// its pre-update contents. An invalid signature matches nothing at all, which
  /// is worse than a changed one, and the only trace was a line on stderr.
  /// True when the running app carries a real certificate rather than an ad-hoc
  /// signature. `codesign -d -r -` prints the designated requirement, which names
  /// a `certificate root` in the first case and a bare `cdhash` in the second.
  /// Written against the requirement and not against `flags=0x2(adhoc)` because
  /// the requirement is what TCC actually matches a grant on.
  ///
  /// Verified on two inputs it must rank differently: a certificate-signed build
  /// prints `identifier "com.tokkah.tk" and certificate root = H"ef8e905f..."`,
  /// and a copy that arrived through the legacy ad-hoc path prints
  /// `cdhash H"fbfe9c05..."`. Reads the pipe before waiting, so a chatty codesign
  /// cannot deadlock startup.
  private static func isCertificateSigned(at bundle: URL? = nil) -> Bool {
    let appDir: URL
    if let b = bundle {
      appDir = b
    } else {
      let me = selfPath()
      guard me.path.contains("/Contents/MacOS/") else { return false }
      appDir = me.deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    }
    let cs = Process()
    cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    cs.arguments = ["-d", "-r", "-", appDir.path]
    let pipe = Pipe()
    cs.standardOutput = pipe
    cs.standardError = pipe
    guard (try? cs.run()) != nil else { return false }
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    cs.waitUntilExit()
    return String(decoding: out, as: UTF8.self).contains("certificate root")
  }

  private static func resign(at bundle: URL? = nil) {
    let appDir: URL
    if let b = bundle {
      appDir = b
    } else {
      let me = selfPath()
      guard me.path.contains("/Contents/MacOS/") else { return }
      appDir = me.deletingLastPathComponent()     // MacOS
        .deletingLastPathComponent()              // Contents
        .deletingLastPathComponent()              // Kin.app
    }
    let cs = Process()
    cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    cs.arguments = ["--force", "--sign", "-", appDir.path]
    cs.standardOutput = FileHandle.nullDevice
    cs.standardError = FileHandle.nullDevice
    guard (try? cs.run()) != nil else { return }
    cs.waitUntilExit()
    if cs.terminationStatus != 0 {
      fputs("update: re-sign returned \(cs.terminationStatus)"
          + " -- macOS may ask for microphone permission again\n", stderr)
    }
  }

  // ── REPAIR A BUNDLE THAT AN OLD UPDATER LEFT BEHIND ────────────────────────
  //
  // The half of an update that INSTALLS is the old half. A machine on 0.33.0 --
  // whose `apply()` had never heard of `bundle/` -- fetches 0.35.0, takes the new
  // binary, and leaves the icon and Info.plist untouched. There is then no NEWER
  // release to trigger the refresh, so that bundle would stay wrong forever: the
  // one set of users who most need the fix are the only ones who cannot get it.
  //
  // So the app checks its own bundle against itself at startup. If the plist does
  // not say what the binary says, it re-fetches its OWN version's archive -- same
  // signed manifest, same hash check, no version comparison involved -- and applies
  // only the bundle half. No binary swap, so no re-exec: the icon simply becomes
  // right, once, quietly.
  static func repairBundleIfStale(current: String) {
    guard let claimed = bundleVersion(), claimed != current else { return }
    fputs("update: bundle says \(claimed) but this binary is \(current) -- repairing\n", stderr)
    // ── BUT NEVER OVER A CERTIFICATE SIGNATURE ────────────────────────────────
    //
    // Replacing bundle files invalidates the signature over them, so this path
    // has to re-sign -- and the only key on a user's machine is ad-hoc
    // (`codesign --force --sign -`, `resign()` above). Ad-hoc signing makes the
    // cdhash the identity, so re-signing a certificate-signed install turns it
    // into a DIFFERENT app as far as TCC is concerned, and macOS asks for the
    // camera and the microphone all over again.
    //
    // A stale icon is a cosmetic defect. Re-prompting for permissions is the
    // complaint this whole line of work exists to fix, so the trade is not close.
    // On a certificate-signed install, decline and wait: the normal update path
    // replaces the bundle whole (`swapBundle`) and never runs codesign at all, so
    // it brings both halves and keeps the certificate.
    if isCertificateSigned() {
      fputs("update: certificate-signed install -- leaving the stale bundle alone"
          + " rather than ad-hoc re-signing it and re-asking for camera and"
          + " microphone; the next release brings both halves at once\n", stderr)
      return
    }
    if let why = cannotVerifyReason {
      fputs("update: \(why)\n", stderr); return
    }
    guard let mData = get("\(base)/manifest.json"),
          let sigB64 = get("\(base)/manifest.json.sig"),
          let sig = Data(base64Encoded: String(decoding: sigB64, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)),
          let pk = publicKey,
          pk.isValidSignature(sig, for: mData),
          let m = try? JSONDecoder().decode(Manifest.self, from: mData)
    else { fputs("update: cannot verify manifest -- leaving the bundle alone\n", stderr); return }
    // Only repair to the version this binary IS. If the manifest has moved on, the
    // normal update path will bring both halves in one step and this would be a
    // wasted download of the wrong thing.
    guard m.version == current else {
      fputs("update: manifest is \(m.version); the normal update will fix both halves\n", stderr); return
    }
    // Five silent `return`s used to live between here and the untar, and this is
    // the one path where silence is genuinely cheap -- a repair that does not
    // happen costs a stale icon, not an update. It still gets lines: the whole
    // reason this function exists is that a defect can hide in the half of an
    // update nobody looks at, and "it ran and did nothing" needs to be
    // distinguishable from "it never ran". stderr only, no `.act`: nothing here is
    // the person's problem.
    guard let tgz = get(m.url, timeout: 120) else {
      note("repair: could not download \(m.url) -- leaving the bundle as it is"); return
    }
    let got = SHA256.hash(data: tgz).map { String(format: "%02x", $0) }.joined()
    guard got == m.sha256.lowercased() else {
      fputs("update: repair sha256 mismatch -- refusing\n", stderr); return
    }
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("tk-repair-\(m.version)")
    try? fm.removeItem(at: tmp)
    guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil else {
      note("repair: cannot create \(tmp.path)"); return
    }
    let tgzPath = tmp.appendingPathComponent("tk.tar.gz")
    guard (try? tgz.write(to: tgzPath)) != nil else {
      note("repair: cannot write the archive to \(tgzPath.path)"); return
    }
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-xzf", tgzPath.path, "-C", tmp.path]
    guard (try? tar.run()) != nil else { note("repair: could not run tar"); return }
    tar.waitUntilExit()
    // Same unread status as `stage` had. Here it matters less -- `installBundle`
    // is per-file best-effort -- but a half-unpacked archive would silently
    // "repair" the bundle to something incomplete, and that is the bug this
    // function is named after.
    guard tar.terminationStatus == 0 else {
      note("repair: tar exited \(tar.terminationStatus) -- leaving the bundle as it is")
      try? fm.removeItem(at: tmp); return
    }
    let applied = installBundle(from: tmp, version: m.version)
    try? fm.removeItem(at: tmp)
    if applied.isEmpty {
      fputs("update: this release carries no bundle files -- nothing to repair\n", stderr)
    } else {
      resign()
    }
  }

  // ── STAGED, THEN COMMITTED ─────────────────────────────────────────────────
  //
  // This used to be one function: the poller found a newer version and restarted
  // the app out from under whoever was using it. That is right for the lab machine
  // 15 km away and wrong for a person mid-sentence, and the two only conflict for
  // the few seconds a call is actually live -- so the download stops being the
  // same event as the restart.
  //
  // `stage` does everything that can be done invisibly: fetch, verify the hash,
  // and RUN the candidate once to prove it launches. `commit` does the part that
  // interrupts. Splitting them means a verified update can sit ready and cost
  // nothing until the moment it is free to land.

  /// A verified, launch-probed update sitting in a temp directory, ready to swap in.
  struct Staged { let manifest: Manifest; let dir: URL }

  /// The update that is downloaded and waiting for a quiet moment. Read by the
  /// poller and by the menu; written only by the poller thread.
  nonisolated(unsafe) static var pending: Staged?

  /// Downloads and verifies without touching the running install. Returns nil on
  /// any failure, having changed nothing.
  static func stage(_ m: Manifest) -> Staged? {
    atStage("downloading"); Metrics.fact("update_offered", m.version); Metrics.count("update_offered_n")
    note("\(m.version) available (\(m.notes ?? "")) -- downloading")
    guard let tgz = get(m.url, timeout: 120) else {
      atStage("download-failed"); Metrics.count("update_fail")
      tell("download failed", "the update didn’t finish downloading", .answer); return nil
    }
    let got = SHA256.hash(data: tgz).map { String(format: "%02x", $0) }.joined()
    guard got == m.sha256.lowercased() else {
      // The second independent gate, and the same class of event as a bad
      // signature: what arrived is not the release that was signed. `.act` for the
      // same reason -- Kin has stopped updating and will keep not updating.
      tell("sha256 mismatch (want \(m.sha256), got \(got)) -- refusing",
           "an update was refused because it didn’t arrive intact", .act)
      return nil
    }
    let fm = FileManager.default
    // Per process, for the same reason `swapBundle` stages under its own name:
    // `temporaryDirectory` is the one per-user directory, and since the watcher
    // grew a poller two processes can be staging the same version at the same
    // moment. They shared this path, and the first thing each one does is delete
    // it -- so one untarred into a directory the other had just removed and got
    // "archive has neither tk nor a bundle", observed. The dangerous version of
    // that is quieter: a HALF-extracted tree that still has an executable in it,
    // which passes the launch probe below and is then copied faithfully into the
    // install.
    let tmp = fm.temporaryDirectory
      .appendingPathComponent("tk-upd-\(m.version)-\(getpid())")
    try? fm.removeItem(at: tmp)
    // Three silent `return nil`s lived here, and between them they covered a full
    // disk, a TMPDIR that has been swept, and a tar that cannot run. All three
    // look identical from outside -- and identical to "there is no update".
    guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil else {
      tell("cannot create a staging directory at \(tmp.path)",
           "the update couldn’t be unpacked", .answer); return nil
    }
    let tgzPath = tmp.appendingPathComponent("tk.tar.gz")
    guard (try? tgz.write(to: tgzPath)) != nil else {
      tell("cannot write \(tgz.count) bytes to \(tgzPath.path) -- is the disk full?",
           "there wasn’t room to download the update", .answer); return nil
    }

    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-xzf", tgzPath.path, "-C", tmp.path]
    guard (try? tar.run()) != nil else {
      tell("could not run /usr/bin/tar", "the update couldn’t be unpacked", .answer); return nil
    }
    tar.waitUntilExit()
    // ── AND THE STATUS WAS NEVER READ ──────────────────────────────────────────
    //
    // A tar that fails part way leaves a HALF-EXTRACTED tree, and the checks below
    // ask only whether an executable is present -- which it may well be, because
    // `tk` sorts before `bundle/` and `Kin.app/`. So a partial unpack could pass
    // the launch probe and be copied faithfully into the install, which is the
    // same defect as the unconditional `mv` in install.sh and is why both are
    // being fixed together.
    guard tar.terminationStatus == 0 else {
      tell("tar exited \(tar.terminationStatus) -- the archive did not unpack whole",
           "the update didn’t arrive intact", .answer)
      try? fm.removeItem(at: tmp); return nil
    }
    // An archive may carry the bare `tk` (what every updater up to 0.45.0 needs),
    // a signed .app bundle (what this one prefers), or both, which is what the
    // transitional releases ship. Accepting either means the legacy payload can
    // eventually be dropped without this refusing every release as empty.
    let newBin = tmp.appendingPathComponent("tk")
    var bundled: URL? = nil
    if let entries = try? fm.contentsOfDirectory(atPath: tmp.path),
       let appName = entries.first(where: { $0.hasSuffix(".app") }) {
      let macos = tmp.appendingPathComponent(appName)
        .appendingPathComponent("Contents/MacOS")
      if let exe = (try? fm.contentsOfDirectory(atPath: macos.path))?.first {
        bundled = macos.appendingPathComponent(exe)
      }
    }
    guard fm.fileExists(atPath: newBin.path) || bundled != nil else {
      tell("archive has neither tk nor a bundle", "that update had nothing in it", .answer)
      try? fm.removeItem(at: tmp); return nil
    }
    if fm.fileExists(atPath: newBin.path) {
      try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBin.path)
    }

    // DOES IT RUN? A binary that verifies and then crashes on launch bricks the
    // far machine, which is the one thing an auto-updater must never do. So the
    // candidate is executed once, in a subprocess, before it is allowed to
    // replace anything. Done at STAGE time, not commit time: the whole value of
    // holding an update is that when the moment comes it is already trustworthy.
    //
    // The bundled executable is probed in preference to the loose one, because it
    // is the copy that will actually be installed -- and it is the signed one, so
    // this also catches a bundle whose signature did not survive the archive.
    let probe = Process()
    probe.executableURL = bundled ?? newBin
    probe.arguments = ["--version"]
    probe.standardOutput = FileHandle.nullDevice
    probe.standardError = FileHandle.nullDevice
    guard (try? probe.run()) != nil else {
      tell("candidate will not launch",
           "that update wouldn’t start, so Kin kept the version you have", .act)
      try? fm.removeItem(at: tmp); return nil
    }
    probe.waitUntilExit()
    guard probe.terminationStatus == 0 else {
      tell("candidate exited \(probe.terminationStatus) on --version -- refusing",
           "that update wouldn’t start, so Kin kept the version you have", .act)
      try? fm.removeItem(at: tmp); return nil
    }
    atStage("staged")
    note("\(m.version) staged and verified")
    return Staged(manifest: m, dir: tmp)
  }

  // ── AN IMAGE THAT IS ABOUT TO BE REPLACED FILES ITS REPORT FIRST ───────────
  //
  // `Launcher.reexec` has had `beforeReexec` since answering a ring became a
  // re-exec, and its comment says why: "execv is an ending as final as a hang-up
  // -- the process stops existing on the next line -- and everything it had not
  // yet reported dies with it. Measured: a ring answered inside five seconds
  // reported NOTHING." The updater re-execs too, through its own `execv` down
  // there, and it never had the hook -- so every update was an unreported ending
  // and the row for that call simply stopped, which on the dashboard is
  // indistinguishable from a laptop lid closing.
  //
  // Now that a call SURVIVES the restart, that matters more than it did: without
  // this the dashboard sees a call vanish and an unrelated one start, when what
  // happened was one call that took an update. Whatever this returns is prepended
  // to the new argv, so the successor carries `--prev-call` and the two rows
  // join.
  nonisolated(unsafe) static var beforeRestart: (() -> [String])?

  /// argv for the successor: the handoff first, then this process's own argv with
  /// anything the handoff already supplied dropped. Same dedup rule and the same
  /// reason as `Launcher.reexec` -- a flag repeated across three updates would
  /// otherwise grow the command line forever.
  private static func restartArgv(_ me: String) -> [String] {
    let handoff = beforeRestart?() ?? []
    var seen = Set(handoff.filter { $0.hasPrefix("--") })
    var out = [me] + handoff
    let carried = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < carried.count {
      let t = carried[i]; i += 1
      guard t.hasPrefix("--") else { out.append(t); continue }
      let value: String? = (i < carried.count && !carried[i].hasPrefix("--")) ? carried[i] : nil
      if value != nil { i += 1 }
      if seen.contains(t) { continue }
      seen.insert(t)
      out.append(t)
      if let v = value { out.append(v) }
    }
    return out
  }

  /// Swaps in a staged update and re-execs. Returns only on failure.
  static func commit(_ s: Staged) {
    let m = s.manifest, tmp = s.dir
    let fm = FileManager.default
    let newBin = tmp.appendingPathComponent("tk")
    let me = Bundle.main.executableURL?.resolvingSymlinksInPath()
      ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()

    // ── PREFERRED: SWAP THE WHOLE SIGNED BUNDLE ────────────────────────────────
    //
    // Everything below this branch is the legacy path, which replaces the binary
    // and then patches files inside the live bundle. That is why permissions kept
    // coming back: macOS pins a camera or microphone grant to the bundle's
    // DESIGNATED REQUIREMENT, and an ad-hoc signature's requirement is
    // `cdhash H"..."` -- a hash of the contents. Change a byte and it is a
    // different application as far as TCC is concerned, so the grants are gone and
    // the prompts return. Re-signing here could never fix that: this machine has
    // no key, so the best it could do was mint yet another content hash.
    //
    // Releases now ship the bundle already signed with a certificate, whose
    // requirement is `identifier "..." and certificate root = H"..."` and is
    // identical for every build. Preserving that means never editing the bundle
    // in place -- only replacing it whole, and never running codesign here.
    if swapBundle(from: tmp, at: me) {
      pending = nil
      atStage("installed"); Metrics.fact("update_installed", m.version)
      // The launchd job is re-registered in `restart` below -- both install
      // paths end there, and only one of them had it when this was written here.
      fputs("update: installed \(m.version) -- restarting\n", stderr)
      restart(into: me)
    }

    // Checked HERE and not at the top of this function, because only the legacy
    // path needs a bare `tk`. When the transitional payload is eventually dropped
    // and archives carry nothing but the signed bundle, a guard up there would
    // reject every release as empty and updates would stop dead with a message
    // about a payload that was never supposed to be there.
    guard fm.fileExists(atPath: newBin.path) else {
      // The staging directory lives in /tmp, which the OS is free to sweep. A
      // vanished payload is not a failed update, it is an update that has to be
      // fetched again -- so drop it and let the poller find it next time.
      fputs("update: staged payload for \(m.version) is gone -- will re-fetch\n", stderr)
      pending = nil; return
    }
    let staging = me.deletingLastPathComponent().appendingPathComponent(".tk.new")
    try? fm.removeItem(at: staging)
    guard (try? fm.copyItem(at: newBin, to: staging)) != nil else {
      tell("cannot stage next to \(me.path) -- is it writable?",
           installBlocker()?.human ?? "Kin can’t update itself where it is", .act)
      return
    }
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
    // rename(2) over a RUNNING executable is safe on macOS: the current image is
    // already mapped, and the swap is atomic, so there is no window in which the
    // path holds a partial binary.
    guard rename(staging.path, me.path) == 0 else {
      tell("rename failed (errno \(errno))",
           "Kin couldn’t install its update — the app is unchanged", .act)
      return
    }
    installBundle(from: tmp, version: m.version)

    // The app may be changing its name. Do it after the payload is in place, so a
    // failure here leaves a working app under the old name rather than half of a
    // new one, and re-exec from wherever it actually ended up.
    let restart = m.appName.flatMap { relocate(bundleTo: $0, from: me) } ?? me
    // Re-signed WHERE IT ENDED UP, not where it started. `relocate` may just have
    // moved this bundle, and re-deriving the path from Bundle.main would name the
    // directory it used to live in.
    resign(at: restart.path.contains("/Contents/MacOS/")
             ? restart.deletingLastPathComponent()
                      .deletingLastPathComponent()
                      .deletingLastPathComponent()
             : nil)
    pending = nil
    atStage("installed"); Metrics.fact("update_installed", m.version)
    fputs("update: installed \(m.version) -- restarting\n", stderr)
    Update.restart(into: restart)
  }

  /// ── A RESIDENT RESTARTS THROUGH launchd, NOT THROUGH execv ────────────────
  ///
  /// The watcher is invisible on purpose: `Watch.run` sets `.accessory`, so no
  /// Dock icon and no cmd-Tab entry. After an `execv` that call SILENTLY FAILS --
  /// the new image inherits the LaunchServices registration of the one it
  /// replaced, which is already checked in as Foreground -- so every self-update
  /// left a SECOND Kin in the Dock, beside the real app. That is the two icons
  /// in the report, and they had nothing to do with two apps being opened.
  ///
  /// Measured on this Mac: a re-exec'd resident reports `.regular`, a
  /// launchd-started one reports `.accessory`.
  ///
  /// `getppid() == 1` is the test for "something is supervising this". A
  /// resident started by hand from a shell has no launchd to come back through
  /// and must still execv; the installed one has KeepAlive set unconditionally,
  /// so exiting is a restart. `Watch.run` already ends this way when it notices
  /// the binary change underneath it.
  /// ── THE NEW BINARY MUST BE LAUNCHABLE BEFORE THIS ONE LETS GO ────────────
  ///
  /// Every self-update filed a crash report:
  ///
  ///     Process: Tokkah   Parent: launchd   Coalition: com.tokkah.tk.watch
  ///     EXC_CRASH (SIGKILL (Code Signature Invalid))
  ///     Termination: CODESIGNING, Launch Constraint Violation
  ///
  /// 67 ms after launch, before anything but dyld. The staged payload IS probed
  /// -- `stage()` runs it with `--version` and refuses a candidate that will not
  /// start -- but it probes the copy in /tmp, BEFORE the swap. What macOS refuses
  /// here is the binary at its new path, moments after a different file with a
  /// different cdhash occupied it, and nothing had ever asked whether THAT would
  /// launch.
  ///
  /// It self-heals: KeepAlive tries again and the second one works, so the Mac
  /// ends up current and the only lasting trace is a crash report per release.
  /// That is precisely why it survived four of them -- "recovers on its own" and
  /// "nobody has looked" produce the same graph.
  ///
  /// So the process holding the job does not exit until it has watched the new
  /// binary start. `--version` costs a few milliseconds, touches no device and
  /// opens no port. If it never becomes launchable, exiting anyway is still
  /// right: launchd retrying forever is a better failure than a resident that
  /// stays on the old build and reports itself healthy.
  static func launchable(_ path: URL, within: Double = 10) -> Int {
    let deadline = Date().addingTimeInterval(within)
    var tries = 0
    while Date() < deadline {
      tries += 1
      let p = Process()
      p.executableURL = path
      p.arguments = ["--version"]
      p.standardOutput = FileHandle.nullDevice
      p.standardError = FileHandle.nullDevice
      if (try? p.run()) != nil {
        p.waitUntilExit()
        // Exit 0 is the answer. A SIGKILL from the code-signing monitor arrives
        // as an uncaught signal, which is what this is waiting out.
        if p.terminationStatus == 0 { return tries }
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
    return -tries
  }

  static func restart(into path: URL) -> Never {
    // ── AND launchd HAS TO BE TOLD THE CODE CHANGED ─────────────────────────
    //
    // Here, and not at either install site, for the reason this file keeps
    // learning: there are TWO install paths -- the signed bundle swap and the
    // legacy binary replace -- and a rule written at one of them is a rule the
    // other one does not have. The first cut of this fix sat on the bundle
    // swap, and the rig caught the legacy arm installing without it (6 of 7).
    // Both paths end here.
    //
    // Not when we ARE the job: the branch further down does it with a detached
    // helper, because a bootout of our own label kills us before we could
    // bootstrap.
    let iAmTheWatcher = CommandLine.arguments.contains("--watch") && getppid() == 1
    if !iAmTheWatcher, Watch.installed {
      let ok = Watch.reregister()
      let said = ok ? "ok" : "FAILED -- the next ring may not reach a closed Mac"
      fputs("update: re-registered the watcher's launchd job -- \(said)\n", stderr)
      Metrics.tap("update_watch_reregister", ok: ok)
    }
    // Both restart routes go through this, because both hand the path to
    // something that will exec it: launchd below, execv further down.
    let tries = launchable(path)
    if tries < 0 {
      fputs("update: the installed binary at \(path.path) still will not launch after"
          + " \(-tries) tries -- restarting anyway and letting the supervisor retry\n", stderr)
      Metrics.count("update_relaunch_unproven")
    } else if tries > 1 {
      fputs("update: the installed binary needed \(tries) tries before macOS would"
          + " launch it -- waited rather than leaving a crash report behind\n", stderr)
      Metrics.count("update_relaunch_waited")
      Metrics.fact("update_relaunch_tries", String(tries))
    }
    if CommandLine.arguments.contains("--watch"), getppid() == 1 {
      fputs("update: restarting through launchd -- an execv'd resident cannot go"
          + " invisible and would leave a second Kin in the Dock\n", stderr)
      // ── AND launchd HAS TO BE TOLD THE CODE CHANGED ────────────────────────
      //
      // Otherwise it relaunches a job pinned to the previous build's cdhash and
      // macOS refuses that launch once -- see `Watch.reregister`, which has the
      // reproduction. The helper boots this job out, which is what ends this
      // process; the sleep below is only there so that the ordinary exit does
      // not beat it to the punch and hand launchd the refused launch anyway.
      if Watch.reregister() { Thread.sleep(forTimeInterval: 5) }
      exit(3)
    }
    var argv = restartArgv(path.path).map { strdup($0) }
    argv.append(nil)
    execv(path.path, &argv)
    fputs("update: execv failed (errno \(errno)) -- exiting so a supervisor can restart\n", stderr)
    exit(0)
  }


  /// Fetch and install in one step, for the launch-time check -- nothing is live
  /// at launch, so there is no reason to defer.
  static func apply(_ m: Manifest) {
    guard let s = stage(m) else { return }
    commit(s)
  }

  // ── RENAMING AN APP THAT IS RUNNING ────────────────────────────────────────
  //
  // Three things carry the name and they must agree or the app will not launch:
  // the bundle directory (`Kin.app`), the executable file inside it
  // (`Contents/MacOS/Kin`), and `CFBundleExecutable` in Info.plist. The plist
  // arrives from the archive, so this moves the other two to match IT -- never the
  // other way round, because the plist is the half that has already been written.
  //
  // Every step is best-effort and ordered so that stopping anywhere leaves a
  // launchable app: the executable is COPIED to its new name before the old one is
  // removed, and the directory move is last.
  // Named `relocate`, not `rename`: a method called `rename` on this type shadows
  // POSIX `rename(2)`, which is the call the atomic binary swap above depends on.
  static func relocate(bundleTo appName: String, from me: URL) -> URL? {
    let fm = FileManager.default
    guard me.path.contains("/Contents/MacOS/") else { return nil }
    let macos = me.deletingLastPathComponent()
    let contents = macos.deletingLastPathComponent()
    let appDir = contents.deletingLastPathComponent()

    // What does the freshly-installed plist say the executable is called?
    guard let plist = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
          let any = try? PropertyListSerialization.propertyList(from: plist, format: nil),
          let dict = any as? [String: Any],
          let wantExec = dict["CFBundleExecutable"] as? String
    else { fputs("update: cannot read Info.plist -- not renaming\n", stderr); return nil }

    var current = me
    if wantExec != me.lastPathComponent {
      let dst = macos.appendingPathComponent(wantExec)
      try? fm.removeItem(at: dst)
      guard (try? fm.copyItem(at: me, to: dst)) != nil else {
        fputs("update: could not put the binary at \(wantExec) -- staying \(me.lastPathComponent)\n",
              stderr)
        return nil
      }
      try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
      // Only now is the old name expendable. Deleting first would leave a bundle
      // with no executable at all if the copy failed.
      try? fm.removeItem(at: me)
      current = dst
      fputs("update: executable is now \(wantExec)\n", stderr)
    }

    guard appDir.lastPathComponent != "\(appName).app" else { return current }
    let newApp = appDir.deletingLastPathComponent().appendingPathComponent("\(appName).app")
    guard !fm.fileExists(atPath: newApp.path) else {
      fputs("update: \(newApp.lastPathComponent) already exists -- leaving this copy where it is\n",
            stderr)
      return current
    }
    guard (try? fm.moveItem(at: appDir, to: newApp)) != nil else {
      fputs("update: could not move \(appDir.lastPathComponent) to \(newApp.lastPathComponent)"
          + " -- the app still works, just under the old name\n", stderr)
      return current
    }
    fputs("update: moved \(appDir.lastPathComponent) -> \(newApp.lastPathComponent)\n", stderr)
    return newApp.appendingPathComponent("Contents/MacOS/\(current.lastPathComponent)")
  }

  // ── WHEN IS IT RUDE TO RESTART? ─────────────────────────────────────────────
  //
  // Host time of the last packet accepted from the peer. Net.swift already keeps
  // this as `Wire.lastRecvHost` and its comment says why it is the right signal:
  // "a remembered address is a claim about the past, and the only evidence a path
  // still works is traffic on it." A locked socket is not a live peer.
  //
  // Stamped at the one place media arrival is recorded rather than read through a
  // callback, because a callback declared here and assigned nowhere would read as
  // finished and silently report "never in a call" -- which fails in the safe
  // direction and so would never be noticed. There is exactly one assignment
  // site, and it is the same line that sets lastRecvHost.
  nonisolated(unsafe) static var lastMediaHost: UInt64 = 0

  /// Grace matches the 3 s the call UI itself uses to decide the peer is gone
  /// (main.swift), so "the app thinks we are connected" and "the updater thinks
  /// we are busy" cannot disagree.
  static func callIsLive() -> Bool {
    guard lastMediaHost != 0 else { return false }
    return Clock.msSigned(Clock.now(), lastMediaHost) < 3000
  }

  /// "Check now instead of waiting out the poll interval." Nothing more. Set by a
  /// refused wire format and by the Check for Updates menu item, and checked once
  /// and cleared, so a peer that is genuinely OLDER than us cannot turn this into a
  /// poll loop.
  nonisolated(unsafe) static var urgent = false

  /// ── AND THE PART THAT MAY INTERRUPT A CONVERSATION ─────────────────────────
  ///
  /// Set ONLY when the peer is provably running a different build -- a refused wire
  /// format, today. That is not a hint that an update might exist, it is proof, and
  /// the call it interrupts is two people sitting in silence, so this one is
  /// allowed to commit through a live call.
  ///
  /// Separate from `urgent` because they were one flag, and the menu item set it.
  /// So a person who opened the menu to ASK whether an update existed had their
  /// call restarted for answering yes -- an update landing mid-sentence, chosen by
  /// nobody. `urgent` says when to look; this says whether looking is allowed to
  /// end the call. Set alongside `urgent`, and always BEFORE it, so the poll thread
  /// can never observe an urgent check whose reason has not been published yet.
  nonisolated(unsafe) static var wireMismatch = false

  /// Set from the menu: the user asked for it, so land it even mid-call.
  nonisolated(unsafe) static var restartNow = false

  /// ── LANDING AN UPDATE DURING A LIVE CALL, ON PURPOSE ───────────────────────
  ///
  /// Rig override, sibling of `TK_UPDATE_POLL` and `TK_UPDATE_BASE`. Production
  /// never sets it and the default is unchanged: an update waits for the call to
  /// end, because a second of silence chosen by nobody in the middle of a
  /// sentence is worse than a restart at the end of a call that nobody notices.
  ///
  /// It exists because that sentence is a CLAIM about a cost, and the only way to
  /// know the cost is to make the path reachable and measure it. Without this the
  /// mid-call branch could only be reached by shipping a release and waiting for
  /// somebody to be on a call, which is not a measurement.
  nonisolated(unsafe) static let midCallAllowed =
    ProcessInfo.processInfo.environment["TK_UPDATE_MIDCALL"] == "1"

  /// How long to wait before asking again, once this copy has been found unable to
  /// install anything at all.
  ///
  /// Six hours, and deliberately not the poll interval. Nothing about the
  /// permissions on /Applications changes on a minute's timescale, and the defect
  /// this backoff exists to end is precisely a retry cadence that assumes the next
  /// attempt might work. It is a hold and not a stop: an admin can fix the
  /// permissions, and Check for Updates in the menu ignores this entirely, because
  /// somebody asking is the likeliest moment for the answer to have changed.
  ///
  /// Rig override, sibling of `TK_UPDATE_POLL` -- a six-hour cadence that no test
  /// can reach is a behaviour nobody has ever seen recover.
  /// (No `nonisolated(unsafe)`, unlike its sibling above: the compiler says it is
  /// unnecessary for a `Sendable` constant, and it is right about both of them.)
  static let blockedRetry =
    max(1, Double(ProcessInfo.processInfo.environment["TK_UPDATE_BLOCKED_RETRY"] ?? "") ?? 21600)

  /// Called when a staged update starts waiting, so the window can say so. Wired
  /// in main.swift; unset for the headless CLI, which has no window to tell.
  nonisolated(unsafe) static var onPending: ((String) -> Void)?

  // ── Background poll ─────────────────────────────────────────────────────────
  //
  // Two jobs now. Find updates, and pick the moment.
  //
  // The old loop applied the instant it found something, which is what the far lab
  // machine needs -- a fix that waits for a human lands once a week -- and is also
  // how you cut somebody off mid-sentence. Both are served by the same rule: a
  // verified update lands IMMEDIATELY when nothing is live, and waits when
  // something is. The lab machine idles between measurements, so it still picks up
  // a fix in about a minute; a person on a call gets restarted the moment they hang
  // up, with no button to find. Deferring is the exception, not the default.
  //
  // ── AND IT IS NOW THE ONLY CHECK ────────────────────────────────────────────
  //
  // The launch path used to run `available()` synchronously before the window was
  // even created: two blocking HTTPS GETs with a 12 s timeout each, measured at
  // 1155 ms of black screen on every single launch. This poller is a strict
  // superset of it -- same available(), same stage(), and it commits the moment
  // callIsLive() is false -- so the launch check is gone and `firstAfter` is what
  // replaces it: one early tick, after first paint, on the launch that actually
  // has an update waiting.
  //
  // firstAfter MUST NOT BE SMALL. callIsLive() is false for the whole of call
  // setup -- no peer packet has arrived yet -- so a 2 s first tick on the first
  // launch after a release re-execs at about 2.5 s, and the window vanishes while
  // the user is still reading the invite link they were about to send. Ten
  // seconds. (Not a "setup in flight" flag instead: the far lab machine sits solo
  // for hours, and a flag that only clears on peer arrival would strand it
  // un-updateable.)
  /// ── CHECK WHEN SOMETHING HAPPENS, NOT ONLY WHEN A TIMER SAYS SO ──────────
  ///
  /// Asked for in as many words: check on every restart, every open, and every
  /// call. A cadence -- any cadence -- is a guess about when a person will next
  /// care, and the moments they actually care about are knowable: they just
  /// opened the app, they just started talking to somebody, they just finished.
  /// Those are also the moments a stale build is most visible, because the other
  /// end of the call is running a different one.
  ///
  /// Routed through the same `urgent` flag the Check for Updates menu item uses,
  /// so there is one path that decides what a check does. It does NOT set
  /// `wireMismatch`: that is the separate permission to interrupt a live call,
  /// and "the app just opened" is not a reason to end a conversation.
  ///
  /// Cheap by construction: the check is a conditional GET of a small manifest.
  /// What is not cheap is COMMITTING at a bad moment, and that is decided
  /// elsewhere -- see `settling` below.
  static func checkNow(_ why: String) {
    guard !urgent else { return }          // one is already queued
    lastReason = why
    urgent = true
  }
  nonisolated(unsafe) static var lastReason = ""
  /// ── WHO ASKED ─────────────────────────────────────────────────────────────
  ///
  /// `urgent` used to mean two things at once, and the second one is about a
  /// PERSON: the Check for Updates menu item is owed an answer whatever happens,
  /// including "you are already up to date" and "I could not reach the server".
  /// An automatic check is owed nothing -- nobody is looking, and a download that
  /// failed once in the middle of somebody's call is not their business.
  ///
  /// Reading "a person asked" off `urgent && !wireMismatch` was true while the
  /// menu was the only thing that set it. The moment opening the app checked too,
  /// every launch on a flaky network put "couldn't check for updates" on somebody's
  /// status line. Caught by update-check's paired arm, which exists for exactly
  /// this: the refusal that must be raised, beside the one that must not.
  nonisolated(unsafe) static var urgentPerson = false
  /// The Check for Updates menu item, and nothing else.
  static func checkNowForPerson() {
    lastReason = "asked from the menu"
    urgentPerson = true
    urgent = true
  }

  /// ── AND A CHECK IS NOT A LICENCE TO RESTART IN SOMEBODY'S FACE ───────────
  ///
  /// The launch check used to be deferred by ten seconds, and the reason was
  /// never the network -- it was that `callIsLive()` is false for the whole of
  /// call setup, so an update found immediately would re-exec while somebody was
  /// still reading their invite link. Checking on open is what was asked for;
  /// re-execing the window somebody just opened is not.
  ///
  /// So the wait moved off the CHECK and onto the COMMIT, which is where it
  /// belonged: find out at once, land it once the app has settled.
  nonisolated(unsafe) static var settleUntil = Date.distantPast
  static func armSettle(_ s: Double) { settleUntil = Date().addingTimeInterval(s) }
  static var settling: Bool { Date() < settleUntil }

  static func startPolling(current: String, every seconds: Double, firstAfter: Double) {
    Thread {
      var waited = 0.0
      var announced = false
      var firstTick = true
      /// Extra seconds on top of the normal interval, set when this copy has been
      /// found unable to install anything. Additive rather than a replacement for
      /// `seconds` so that the first tick's grace still applies on top of it and
      /// there is only one place that decides when a check is due.
      var holdOff = 0.0
      while true {
        Thread.sleep(forTimeInterval: 0.5)

        // Something is already downloaded and waiting. The only question left is
        // whether this is a good moment, so ask that twice a second rather than
        // once a minute -- the point is to land the instant the call ends.
        if let s = pending {
          if restartNow {
            restartNow = false
            note("asked to restart now")
            commit(s)          // returns only on failure; keep waiting if so
            continue
          }
          if settling && !midCallAllowed && !restartNow {
            // Found, verified, waiting for the window to stop being new. Not a
            // stall: the same loop lands it a few seconds later without anybody
            // asking again.
            continue
          }
          if !callIsLive() || midCallAllowed { commit(s); continue }
          if !announced {
            announced = true
            atStage("held-for-call"); Metrics.count("update_held_n")
            note("\(s.manifest.version) is ready, holding until the call ends")
            onPending?(s.manifest.version)
          }
          continue
        }

        waited += 0.5
        var due = waited >= (firstTick ? firstAfter : seconds) + holdOff
        // Two different things arrive as `urgent`, and only one of them may end a
        // conversation. Read the reason, then clear both.
        var mayInterruptCall = false
        // And a third question the reason answers: is a PERSON waiting for the
        // result? `urgent` without `wireMismatch` is the Check for Updates menu
        // item and nothing else, and it is the one case where every outcome --
        // including "you are already up to date" -- has somebody owed an answer.
        var personAsked = false
        if urgent {
          urgent = false
          due = true
          if wireMismatch {
            wireMismatch = false
            mayInterruptCall = true
            note("peer is on a different build -- checking now rather than waiting")
          } else if urgentPerson {
            urgentPerson = false
            personAsked = true
            note("asked to check now")
          } else {
            // Automatic: opened, restarted, a call started. Logged, never raised.
            note("checking now -- \(lastReason)")
          }
        }
        guard due else { continue }
        waited = 0
        firstTick = false
        holdOff = 0
        asked = personAsked
        raised = false
        defer { asked = false; if !raised { said = nil } }
        // ── REPORT THE CHECK, WHATEVER IT DECIDED ──────────────────────────────
        //
        // In a `defer` and above the `guard`, so it fires on every path out of
        // this iteration. Below the guard it would only ever report checks that
        // FOUND something, and "offers 0.70.0 and this is 0.70.0 -- nothing to
        // install" is both the most common outcome and the one that proves a Mac
        // is checking at all. That distinction -- checking and current, versus
        // not checking -- is the entire question this was added to answer.
        //
        // Watcher only. The app posts beats of its own during a call, and this
        // exists for the Mac that is not on one.
        Metrics.count("update_checks")
        defer { if reportsAsWatcher { Telemetry.watchBeat() } }
        guard let (m, _) = available(current: current) else { continue }
        // ── THE INSTALL QUESTION, BEFORE THE DOWNLOAD ──────────────────────────
        //
        // A copy that cannot write its own bundle used to find that out at the
        // END: manifest, whole tarball, hash, launch probe, and only then a failed
        // swap -- with the staged copy dropped and the entire thing repeated on
        // the next tick, forever. `installBlocker` reads two permission bits and
        // costs nothing, and the hold is what stops the loop.
        //
        // Deliberately asked HERE and not before `available()`. A Mac that cannot
        // install anything and has nothing to install has no problem worth
        // interrupting anybody about; this only speaks when there is a real
        // release it is really unable to take.
        if let b = installBlocker() {
          // The likeliest silent cause of "it would not update itself", and
          // until now it was reported to a log nobody reads on a Mac nobody
          // is sitting at. The reason goes on the wire, trimmed to 64 chars
          // by `fact` itself.
          atStage("blocked"); Metrics.count("update_blocked_n"); Metrics.fact("update_blocked", b.log)
          tell("\(m.version) is available and this copy cannot install it: \(b.log)", b.human, .act)
          note("not downloading it; asking again in \(Int(blockedRetry)) s")
          holdOff = blockedRetry
          continue
        }
        // Download either way. Holding an UNFETCHED update would mean the restart,
        // when it finally comes, still has to wait for a download -- and on a bad
        // connection that is the difference between a blink and a minute.
        guard let s = stage(m) else { continue }
        // The hold protects a CONVERSATION from being interrupted. A peer running
        // a refused wire format is not a conversation -- it is two people in
        // silence -- and `wireMismatch` is set for exactly that case and nothing
        // else. Holding there parks the fix that ends the silence behind a call with
        // nothing to protect, so that one case commits instead of waiting for a
        // hang-up. Every other reason to check early -- the menu item, above all --
        // still waits, because a person asking whether an update exists has not
        // asked to be cut off.
        if callIsLive() && !mayInterruptCall && !midCallAllowed {
          pending = s
          announced = false
        } else {
          commit(s)
        }
      }
    }.start()
  }
}

// ── PROVING THE RENAME BEFORE IT RUNS ON SOMEBODY ELSE'S MAC ─────────────────
//
// `relocate` fires exactly once per install, on a machine that is not this one,
// and the failure mode is an app that no longer launches. There is no second
// chance and no way to look. So it gets exercised against a bundle built for the
// purpose, and release.sh runs this before it will publish anything.
extension Update {
  static func selftestRename() -> Bool {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tk-rename-test-\(getpid())")
    try? fm.removeItem(at: root)
    let old = root.appendingPathComponent("Old.app")
    let macos = old.appendingPathComponent("Contents/MacOS")
    var ok = true
    func check(_ what: String, _ cond: Bool) {
      fputs("  \(cond ? "OK  " : "FAIL") \(what)\n", stderr); if !cond { ok = false }
    }
    do {
      try fm.createDirectory(at: macos, withIntermediateDirectories: true)
      let exe = macos.appendingPathComponent("Old")
      try "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
      try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
      // The plist is the half that has already been written when relocate runs, so
      // it names the executable relocate has to produce.
      let plist: [String: Any] = ["CFBundleExecutable": "New", "CFBundleName": "New"]
      let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      try data.write(to: old.appendingPathComponent("Contents/Info.plist"))

      let got = Update.relocate(bundleTo: "New", from: exe)
      let new = root.appendingPathComponent("New.app")
      check("returned a path", got != nil)
      check("Old.app is gone", !fm.fileExists(atPath: old.path))
      check("New.app exists", fm.fileExists(atPath: new.path))
      let newExe = new.appendingPathComponent("Contents/MacOS/New")
      check("executable is Contents/MacOS/New", fm.fileExists(atPath: newExe.path))
      check("old executable name is gone",
            !fm.fileExists(atPath: new.appendingPathComponent("Contents/MacOS/Old").path))
      check("it is still executable", fm.isExecutableFile(atPath: newExe.path))
      check("returned path is the new executable", got?.path == newExe.path)

      // Idempotent: a second run must be a no-op, because the poller can see the
      // same appName again and must not move a bundle that is already correct.
      let again = Update.relocate(bundleTo: "New", from: newExe)
      check("second run is a no-op", again?.path == newExe.path && fm.fileExists(atPath: newExe.path))

      // And it must refuse rather than clobber a bundle that is already there.
      let other = root.appendingPathComponent("Taken.app/Contents/MacOS")
      try fm.createDirectory(at: other, withIntermediateDirectories: true)
      let otherExe = other.appendingPathComponent("New")
      try "x".write(to: otherExe, atomically: true, encoding: .utf8)
      try data.write(to: other.deletingLastPathComponent().appendingPathComponent("Info.plist"))
      _ = Update.relocate(bundleTo: "New", from: otherExe)
      check("refuses to overwrite an existing New.app",
            fm.fileExists(atPath: root.appendingPathComponent("Taken.app").path))
    } catch {
      check("setup (\(error))", false)
    }
    try? fm.removeItem(at: root)
    return ok
  }
}
