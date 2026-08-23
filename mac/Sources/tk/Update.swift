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
  static let base = "https://room.tokkah.com/macos"

  struct Manifest: Decodable { let version: String; let url: String; let sha256: String; let notes: String? }

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

  /// Ad-hoc re-sign of the enclosing bundle. macOS ties a microphone or camera
  /// grant to the CODE SIGNATURE of the thing that asked, so a bundle whose
  /// contents changed under its signature is treated as a different application and
  /// the prompts come back mid-conversation. Best-effort by design: a failure costs
  /// a prompt, and refusing to update over it would cost the fix.
  private static func resign() {
    let me = selfPath()
    guard me.path.contains("/Contents/MacOS/") else { return }
    let appDir = me.deletingLastPathComponent()   // MacOS
      .deletingLastPathComponent()                // Contents
      .deletingLastPathComponent()                // Tokkah.app
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

  /// Downloads, verifies, swaps, and re-execs. Returns only on failure.
  static func apply(_ m: Manifest) {
    fputs("update: \(m.version) available (\(m.notes ?? "")) -- downloading\n", stderr)
    guard let tgz = get(m.url, timeout: 120) else { fputs("update: download failed\n", stderr); return }
    let got = SHA256.hash(data: tgz).map { String(format: "%02x", $0) }.joined()
    guard got == m.sha256.lowercased() else {
      fputs("update: sha256 mismatch (want \(m.sha256), got \(got)) -- refusing\n", stderr); return
    }
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("tk-upd-\(m.version)")
    try? fm.removeItem(at: tmp)
    guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil else { return }
    let tgzPath = tmp.appendingPathComponent("tk.tar.gz")
    guard (try? tgz.write(to: tgzPath)) != nil else { return }

    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-xzf", tgzPath.path, "-C", tmp.path]
    guard (try? tar.run()) != nil else { return }
    tar.waitUntilExit()
    let newBin = tmp.appendingPathComponent("tk")
    guard fm.fileExists(atPath: newBin.path) else { fputs("update: archive has no tk\n", stderr); return }
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBin.path)

    // DOES IT RUN? A binary that verifies and then crashes on launch bricks the
    // far machine, which is the one thing an auto-updater must never do. So the
    // candidate is executed once, in a subprocess, before it is allowed to
    // replace anything.
    let probe = Process()
    probe.executableURL = newBin
    probe.arguments = ["--version"]
    probe.standardOutput = FileHandle.nullDevice
    probe.standardError = FileHandle.nullDevice
    guard (try? probe.run()) != nil else { fputs("update: candidate will not launch\n", stderr); return }
    probe.waitUntilExit()
    guard probe.terminationStatus == 0 else {
      fputs("update: candidate exited \(probe.terminationStatus) on --version -- refusing\n", stderr); return
    }

    let me = Bundle.main.executableURL?.resolvingSymlinksInPath()
      ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
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

    resign()
    fputs("update: installed \(m.version) -- restarting\n", stderr)
    var argv = CommandLine.arguments.map { strdup($0) }
    argv.append(nil)
    execv(me.path, &argv)
    fputs("update: execv failed (errno \(errno)) -- exiting so a supervisor can restart\n", stderr)
    exit(0)
  }

  /// Background poll. Applies and re-execs; a few seconds of interruption beats
  /// a machine 15 km away running last week's code.
  /// Set when the peer is provably running a different build -- a refused wire
  /// format, today. That is not a hint that an update might exist, it is proof,
  /// and waiting out the rest of a 60 s poll while a live call sits silent is a
  /// minute nobody should have to spend. Checked once and cleared, so a peer that
  /// is genuinely OLDER than us cannot turn this into a poll loop.
  nonisolated(unsafe) static var urgent = false

  static func startPolling(current: String, every seconds: Double) {
    Thread {
      var waited = 0.0
      while true {
        Thread.sleep(forTimeInterval: 0.5)
        waited += 0.5
        var due = waited >= seconds
        if urgent {
          urgent = false
          due = true
          fputs("update: peer is on a different build -- checking now rather than waiting\n", stderr)
        }
        guard due else { continue }
        waited = 0
        if let (m, _) = available(current: current) { apply(m) }
      }
    }.start()
  }
}
