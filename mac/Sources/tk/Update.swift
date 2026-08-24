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
  static let publicKeyHex = "d07822edb36c8692c83f3478c26683102cd3cf6fb1d0c263496404c15fd95b2a"
  /// Overridable for the update-path test rig ONLY. Safe to expose: everything
  /// fetched from here is Ed25519-verified against the compiled-in key before a
  /// byte of it is trusted, so pointing base somewhere else cannot inject code --
  /// it can only offer updates the real key signed. An attacker who can set our
  /// environment can already run code as us.
  static let base = ProcessInfo.processInfo.environment["TK_UPDATE_BASE"]
    ?? "https://room.tokkah.com/macos"

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

  /// Returns the version that is available and verified, or nil.
  static func available(current: String) -> (Manifest, Data)? {
    guard let mData = get("\(base)/manifest.json"),
          let sigB64 = get("\(base)/manifest.json.sig"),
          let sig = Data(base64Encoded: String(decoding: sigB64, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
          let pkRaw = hex(publicKeyHex),
          let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: pkRaw)
    else { return nil }
    // VERIFY BEFORE PARSE. Parsing attacker-controlled JSON is a smaller risk
    // than acting on it, but it is not zero, and the order costs nothing.
    guard pk.isValidSignature(sig, for: mData) else {
      fputs("update: manifest signature INVALID -- ignoring\n", stderr); return nil
    }
    guard let m = try? JSONDecoder().decode(Manifest.self, from: mData) else { return nil }
    guard newer(m.version, than: current) else { return nil }
    return (m, mData)
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
    let next = appDir.deletingLastPathComponent()
      .appendingPathComponent(".\(appDir.lastPathComponent).new")
    try? fm.removeItem(at: next)
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
      fputs("update: cannot stage a bundle next to \(appDir.path) -- is it writable?\n", stderr)
      try? fm.removeItem(at: next); return false
    }
    // RENAME_SWAP exchanges the two directories in a single step. Plain rename(2)
    // cannot: the destination is a non-empty directory. Remove-then-move would
    // leave a window in which the app does not exist at all, and a crash or a
    // power cut inside that window uninstalls the program.
    guard renamex_np(next.path, appDir.path, UInt32(RENAME_SWAP)) == 0 else {
      fputs("update: bundle swap failed (errno \(errno))\n", stderr)
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
    guard let mData = get("\(base)/manifest.json"),
          let sigB64 = get("\(base)/manifest.json.sig"),
          let sig = Data(base64Encoded: String(decoding: sigB64, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)),
          let pkRaw = hex(publicKeyHex),
          let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: pkRaw),
          pk.isValidSignature(sig, for: mData),
          let m = try? JSONDecoder().decode(Manifest.self, from: mData)
    else { fputs("update: cannot verify manifest -- leaving the bundle alone\n", stderr); return }
    // Only repair to the version this binary IS. If the manifest has moved on, the
    // normal update path will bring both halves in one step and this would be a
    // wasted download of the wrong thing.
    guard m.version == current else {
      fputs("update: manifest is \(m.version); the normal update will fix both halves\n", stderr); return
    }
    guard let tgz = get(m.url, timeout: 120) else { return }
    let got = SHA256.hash(data: tgz).map { String(format: "%02x", $0) }.joined()
    guard got == m.sha256.lowercased() else {
      fputs("update: repair sha256 mismatch -- refusing\n", stderr); return
    }
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("tk-repair-\(m.version)")
    try? fm.removeItem(at: tmp)
    guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil else { return }
    let tgzPath = tmp.appendingPathComponent("tk.tar.gz")
    guard (try? tgz.write(to: tgzPath)) != nil else { return }
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-xzf", tgzPath.path, "-C", tmp.path]
    guard (try? tar.run()) != nil else { return }
    tar.waitUntilExit()
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
    fputs("update: \(m.version) available (\(m.notes ?? "")) -- downloading\n", stderr)
    guard let tgz = get(m.url, timeout: 120) else { fputs("update: download failed\n", stderr); return nil }
    let got = SHA256.hash(data: tgz).map { String(format: "%02x", $0) }.joined()
    guard got == m.sha256.lowercased() else {
      fputs("update: sha256 mismatch (want \(m.sha256), got \(got)) -- refusing\n", stderr); return nil
    }
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("tk-upd-\(m.version)")
    try? fm.removeItem(at: tmp)
    guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil else { return nil }
    let tgzPath = tmp.appendingPathComponent("tk.tar.gz")
    guard (try? tgz.write(to: tgzPath)) != nil else { return nil }

    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-xzf", tgzPath.path, "-C", tmp.path]
    guard (try? tar.run()) != nil else { return nil }
    tar.waitUntilExit()
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
      fputs("update: archive has neither tk nor a bundle\n", stderr); return nil
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
      fputs("update: candidate will not launch\n", stderr); try? fm.removeItem(at: tmp); return nil
    }
    probe.waitUntilExit()
    guard probe.terminationStatus == 0 else {
      fputs("update: candidate exited \(probe.terminationStatus) on --version -- refusing\n", stderr)
      try? fm.removeItem(at: tmp); return nil
    }
    fputs("update: \(m.version) staged and verified\n", stderr)
    return Staged(manifest: m, dir: tmp)
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
      fputs("update: installed \(m.version) -- restarting\n", stderr)
      var argv = CommandLine.arguments.map { strdup($0) }
      argv.append(nil)
      execv(me.path, &argv)
      fputs("update: execv failed (errno \(errno)) -- exiting so a supervisor can restart\n", stderr)
      exit(0)
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
      fputs("update: cannot stage next to \(me.path) -- is it writable?\n", stderr); return
    }
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
    // rename(2) over a RUNNING executable is safe on macOS: the current image is
    // already mapped, and the swap is atomic, so there is no window in which the
    // path holds a partial binary.
    guard rename(staging.path, me.path) == 0 else {
      fputs("update: rename failed (errno \(errno))\n", stderr); return
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
    fputs("update: installed \(m.version) -- restarting\n", stderr)
    var argv = CommandLine.arguments.map { strdup($0) }
    argv.append(nil)
    execv(restart.path, &argv)
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
  static func startPolling(current: String, every seconds: Double, firstAfter: Double) {
    Thread {
      var waited = 0.0
      var announced = false
      var firstTick = true
      while true {
        Thread.sleep(forTimeInterval: 0.5)

        // Something is already downloaded and waiting. The only question left is
        // whether this is a good moment, so ask that twice a second rather than
        // once a minute -- the point is to land the instant the call ends.
        if let s = pending {
          if restartNow {
            restartNow = false
            fputs("update: asked to restart now\n", stderr)
            commit(s)          // returns only on failure; keep waiting if so
            continue
          }
          if !callIsLive() { commit(s); continue }
          if !announced {
            announced = true
            fputs("update: \(s.manifest.version) is ready, holding until the call ends\n", stderr)
            onPending?(s.manifest.version)
          }
          continue
        }

        waited += 0.5
        var due = waited >= (firstTick ? firstAfter : seconds)
        // Two different things arrive as `urgent`, and only one of them may end a
        // conversation. Read the reason, then clear both.
        var mayInterruptCall = false
        if urgent {
          urgent = false
          due = true
          if wireMismatch {
            wireMismatch = false
            mayInterruptCall = true
            fputs("update: peer is on a different build -- checking now rather than waiting\n", stderr)
          } else {
            fputs("update: asked to check now\n", stderr)
          }
        }
        guard due else { continue }
        waited = 0
        firstTick = false
        guard let (m, _) = available(current: current) else { continue }
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
        if callIsLive() && !mayInterruptCall {
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
