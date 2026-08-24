import Darwin
import Foundation

// ── PUTTING ITSELF WHERE IT CAN LIVE ────────────────────────────────────────
//
// The curl install has no problem here: install.sh assembles the bundle straight
// into /Applications, and files fetched with curl are never quarantined, so it
// never meets Gatekeeper. The .dmg is the path that breaks, and it breaks for
// EVERY user rather than for a misconfigured one:
//
//   1. A browser sets com.apple.quarantine on the download. We are ad-hoc
//      signed, not notarised, so Gatekeeper refuses to launch.
//   2. The user clicks "Open Anyway" in Privacy & Security. That grants
//      permission to RUN the binary. It does not install anything, and nothing
//      appears in /Applications -- which is the first thing anybody looks for.
//   3. Worse: because the app came from a quarantined disk image, macOS runs it
//      under App Translocation, from a randomised READ-ONLY path under
//      /private/var/folders/.../AppTranslocation/. Not the .dmg, not
//      /Applications, and not writable.
//
// Step 3 is the one that matters, because it silently kills the updater. Update
// .apply() stages the next binary as `.tk.new` NEXT TO the running executable and
// rename(2)s over it. On a read-only mount that copy fails, every sixty seconds,
// forever, printing "cannot stage next to ... is it writable?" to a stderr nobody
// is reading. So a .dmg user got an app that was invisible AND frozen at whatever
// version they happened to download -- the updater shipping only what it can
// install, again, from a direction the curl path could never show.
//
// The fix needs no Apple Developer ID and no notarisation: if we are not running
// from a writable home, copy ourselves to one, clear the quarantine flag, re-sign,
// and relaunch from there. The .dmg then behaves the way its Applications symlink
// has been promising all along, and the updater lands in a directory it can write.
enum Install {
  /// Where this executable lives. Same resolution as Update.selfPath, and for the
  /// same reason: two answers to "where am I" is how a bundle ends up half moved.
  private static func selfPath() -> URL {
    Bundle.main.executableURL?.resolvingSymlinksInPath()
      ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
  }

  /// The enclosing `.app`, or nil when this is the bare command-line binary.
  ///
  /// The CLI install is deliberately NOT relocated. `~/.local/bin/tk` is exactly
  /// where install.sh puts it and where the user's PATH expects it; moving it
  /// would break the command while "fixing" it.
  private static func appBundle() -> URL? {
    let me = selfPath()
    guard me.path.contains("/Contents/MacOS/") else { return nil }
    return me.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }

  /// Is this bundle somewhere it can never update itself from?
  ///
  /// Three ways to be homeless, and they are checked by PATH rather than by
  /// probing for writability. A translocated mount is read-only today and Apple
  /// is free to change that; the reason to leave it is not the permission bits,
  /// it is that the path is randomised per launch and disappears when the volume
  /// ejects. An app that updated itself there would lose the update.
  static func needsRelocation(_ app: URL) -> Bool {
    let p = app.path
    if p.contains("/AppTranslocation/") { return true }   // opened from a quarantined DMG
    if p.hasPrefix("/Volumes/") { return true }           // run in place off the mounted DMG
    if p.hasPrefix("/Applications/") { return false }
    if p.hasPrefix(NSHomeDirectory() + "/Applications/") { return false }
    return true                                          // Downloads, Desktop, anywhere else
  }

  private static func run(_ tool: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
  }

  private static func shortVersion(ofBundle app: URL) -> String? {
    let plist = app.appendingPathComponent("Contents/Info.plist")
    guard let d = try? Data(contentsOf: plist),
          let any = try? PropertyListSerialization.propertyList(from: d, format: nil),
          let dict = any as? [String: Any] else { return nil }
    return dict["CFBundleShortVersionString"] as? String
  }

  /// The bundle identifier, read the same way. Used to be sure a `Tokkah.app`
  /// sitting next to us is OUR old install and not somebody else's app that
  /// happens to share the name.
  private static func bundleIdentifier(ofBundle app: URL) -> String? {
    let plist = app.appendingPathComponent("Contents/Info.plist")
    guard let d = try? Data(contentsOf: plist),
          let any = try? PropertyListSerialization.propertyList(from: d, format: nil),
          let dict = any as? [String: Any] else { return nil }
    return dict["CFBundleIdentifier"] as? String
  }

  /// Relocate to /Applications and relaunch. Returns only if nothing was done --
  /// on success this process is replaced by the installed copy.
  ///
  /// Called before the update check and before any audio or camera device is
  /// opened, so a user who double-clicks the .dmg copy never gets as far as
  /// granting microphone permission to a bundle that is about to move. macOS ties
  /// those grants to the code signature at the path that asked; earning them at a
  /// translocated path spends the user's one prompt on an app that will not exist
  /// in a minute.
  static func relocateIfHomeless() {
    // ── A PRODUCTION BEHAVIOUR THAT CANNOT BE SWITCHED OFF CANNOT BE MEASURED ─
    //
    // Camera timing has to be read from a SIGNED bundle -- the bare binary is
    // denied the camera, so `FIRST FRAME` never prints and every number is a
    // measurement of the denial path. But a probe bundle lives outside
    // /Applications, which is exactly `needsRelocation`, so measuring it made the
    // app install itself over the user's working copy and hand off with `open -n`
    // -- orphaning stderr and destroying the release that was already there. That
    // happened, and the install had to be restored from prod.
    //
    // So the rig can say no. Registered in KNOWN_FLAGS and echoed on startup,
    // because a switch this consequential must not be silent in either direction.
    if flag("no-relocate") {
      fputs("install: --no-relocate -- staying at"
          + " \(appBundle()?.path ?? Bundle.main.bundlePath)"
          + " (this copy cannot update itself; measurement build)\n", stderr)
      return
    }
    guard let app = appBundle() else { return }          // bare CLI binary: leave it alone
    guard needsRelocation(app) else { return }

    let fm = FileManager.default
    var dir = "/Applications"
    if !fm.isWritableFile(atPath: dir) { dir = NSHomeDirectory() + "/Applications" }

    fputs("install: running from \(app.path)\n", stderr)
    fputs("install: that is not a place this app can update itself from -- installing to \(dir)\n",
          stderr)
    guard let dst = install(app, into: dir) else { return }
    fputs("install: installed \(dst.path) -- restarting from there\n", stderr)
    handOff(to: dst)
  }

  /// Copy `app` into `dir`, replacing what is there. Returns the path to launch,
  /// or nil if nothing usable happened.
  ///
  /// Split out from `relocateIfHomeless` and given the directory explicitly so the
  /// self-test can drive the real code against a temp directory. A test that
  /// exercises a reimplementation of this proves nothing about it.
  static func install(_ app: URL, into dir: String) -> URL? {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let dst = URL(fileURLWithPath: dir).appendingPathComponent(app.lastPathComponent)

    // ── DO NOT DOWNGRADE SOMEBODY'S WORKING INSTALL ──────────────────────────
    //
    // A user with 0.42.0 already installed who opens an old 0.38.0 .dmg out of
    // their Downloads folder must not have the new one replaced by the old one.
    // The installed copy is newer, so hand over to IT rather than clobbering it:
    // the user gets the app they wanted either way, and the version that stays on
    // disk is the better one.
    if let there = shortVersion(ofBundle: dst),
       let mine = shortVersion(ofBundle: app), Update.newer(there, than: mine) {
      fputs("install: \(dst.lastPathComponent) is already \(there), newer than this \(mine)"
          + " -- launching that instead\n", stderr)
      return dst
    }

    // Copy to a sibling and swap it in, so an interrupted copy can never leave a
    // half-written bundle at the real path. The user's existing install keeps
    // working until the replacement is complete.
    let tmp = URL(fileURLWithPath: dir).appendingPathComponent(".\(app.lastPathComponent).incoming")
    try? fm.removeItem(at: tmp)
    guard (try? fm.copyItem(at: app, to: tmp)) != nil else {
      fputs("install: could not copy into \(dir) -- continuing from here,"
          + " but this copy cannot update itself\n", stderr)
      return nil
    }
    // Clearing quarantine on OUR OWN copy is not a Gatekeeper bypass: the user
    // has already been shown the warning and already said Open Anyway, and the
    // bytes are the ones they approved. Without this the installed copy would ask
    // again on its first launch, which reads as the install having failed.
    _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", tmp.path])
    // NOT re-signed here, deliberately. This bundle arrived already signed with
    // the release certificate, and that signature is the whole reason the camera
    // and microphone grants survive an update: macOS pins them to the designated
    // requirement, which for a certificate is stable across every build. Running
    // `codesign --sign -` over it -- which this line used to do -- replaced that
    // with an ad-hoc signature whose requirement is a hash of the contents, so it
    // changed on every release and took the grants with it. This machine has no
    // key, so there is nothing better it could sign with: the correct move is to
    // leave the signature it was given alone.

    // Now make it the real thing. Move the old one aside first rather than
    // deleting it, so a failed swap is recoverable.
    let old = URL(fileURLWithPath: dir).appendingPathComponent(".\(app.lastPathComponent).previous")
    try? fm.removeItem(at: old)
    if fm.fileExists(atPath: dst.path) { try? fm.moveItem(at: dst, to: old) }
    guard (try? fm.moveItem(at: tmp, to: dst)) != nil else {
      fputs("install: could not put the bundle at \(dst.path)\n", stderr)
      if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: dst) }
      try? fm.removeItem(at: tmp)
      return nil
    }
    try? fm.removeItem(at: old)
    // ── THE APP THIS ONE IS THE RENAME OF ────────────────────────────────────
    //
    // A Kin.app installed next to the Tokkah.app it renames would leave two
    // apps, two updaters fetching the same manifest every minute, and two
    // microphone identities -- with no way for the user to know which one a
    // kin:// link opens. Only OUR old install goes, identified by bundle id
    // rather than by name, and only when it is not newer than what we just put
    // down: a newer Tokkah.app is somebody mid-upgrade, and deleting the better
    // copy to install the worse one is the downgrade the check above refuses.
    if dst.lastPathComponent == "Kin.app" {
      let legacy = URL(fileURLWithPath: dir).appendingPathComponent("Tokkah.app")
      if fm.fileExists(atPath: legacy.path),
         bundleIdentifier(ofBundle: legacy) == "com.tokkah.tk" {
        let mine = shortVersion(ofBundle: dst) ?? "0.0.0"
        let there = shortVersion(ofBundle: legacy) ?? "0.0.0"
        if Update.newer(there, than: mine) {
          fputs("install: leaving \(legacy.path) -- it is \(there), newer than this"
              + " \(mine); two apps for now rather than deleting the better one\n", stderr)
        } else {
          try? fm.removeItem(at: legacy)
          fputs("install: removed \(legacy.path) -- same app, now called Kin\n", stderr)
        }
      }
    }
    // Tell the Finder and the Dock to notice, the same way the updater does after
    // it refreshes an icon.
    _ = run("/usr/bin/touch", [dst.path])
    return dst
  }

  // ── HANDING OVER TO THE INSTALLED COPY ──────────────────────────────────────
  //
  // `open` and not execv. execv would replace this image with the new binary but
  // keep this process -- and with it the translocated mount that macOS attached
  // to it, the parent Finder relationship, and every inherited file descriptor.
  // The self-updater has already been bitten once by execv inheriting fds; here
  // the whole point is to stop being the process that is pinned to a read-only
  // volume, so the old process must actually exit.
  //
  // `-n` forces a new instance: LaunchServices would otherwise see a running app
  // with the same bundle identifier -- us -- and just bring our own window
  // forward, leaving the copy on the DMG running and the install looking like it
  // did nothing.
  private static func handOff(to app: URL) {
    var args = ["-n", "-a", app.path]
    // Pass our own flags through, so `tk --room x` inside a bundle survives the
    // move. Finder launches add -psn_* , which means nothing to the new copy.
    var passthrough = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
    // ── THE ROOM DOES NOT SURVIVE THE MOVE ON ITS OWN ────────────────────────
    //
    // A first-ever launch from a link is the worst case of the lot: the DMG copy
    // is what LaunchServices hands the `tokkah://` event to, this relocation runs
    // before the launch path ever reads it, and `open` starts the installed copy
    // with no event of its own. The invite dies in the process that is exiting.
    //
    // So catch it here. The handler is installed for this alone -- relocation
    // happens before main installs it -- and the wait is short because the only
    // launch that pays it is one where no link was ever clicked, and that one is
    // about to relaunch anyway.
    if !passthrough.contains("--room") {
      Launcher.installURLHandler()
      // 0.25, and awaitURLRoom now also returns on the LAUNCH event -- so the
      // relocation that carries no link stops paying for the one that does.
      if let r = Launcher.awaitURLRoom(within: 0.25) {
        fputs("install: carrying room \(r) through the move\n", stderr)
        passthrough += ["--room", r, "--video", "camera", "--window"]
      }
    }
    if !passthrough.isEmpty { args.append("--args"); args.append(contentsOf: passthrough) }
    let status = run("/usr/bin/open", args)
    guard status == 0 else {
      fputs("install: could not launch \(app.path) (open exited \(status))"
          + " -- staying here so the user still has a running app\n", stderr)
      return
    }
    exit(0)
  }
}

// ── PROVING THE INSTALL BEFORE IT RUNS ON SOMEBODY ELSE'S MAC ────────────────
//
// Same reasoning as selftestRename, and the same gate in release.sh. This fires
// once per install, on a machine that is not this one, and a mistake in it moves
// or deletes the app the user just downloaded. There is no second chance.
//
// The FIRST half is calibrating the ruler: needsRelocation is the decision the
// whole feature turns on, and a version of it that answered "yes" to everything
// would relocate a healthy /Applications install on every launch, while one that
// answered "no" to everything would be a silent no-op that looks exactly like
// success. So it is checked against paths where the two answers must differ,
// including the real ones this bug came from.
extension Install {
  static func selftest() -> Bool {
    let fm = FileManager.default
    var ok = true
    func check(_ what: String, _ cond: Bool) {
      fputs("  \(cond ? "OK  " : "FAIL") \(what)\n", stderr); if !cond { ok = false }
    }

    fputs("== needsRelocation ==\n", stderr)
    let home = NSHomeDirectory()
    // Must relocate: every one of these is a path the updater cannot write, or
    // cannot find again next launch.
    for p in [
      "/private/var/folders/8z/x/T/AppTranslocation/6B8FF783/d/Tokkah.app",  // the observed one
      "/Volumes/Tokkah 0.42.0/Tokkah.app",                                   // run in place off the DMG
      "\(home)/Downloads/Tokkah.app",                                        // dragged to Downloads
      "\(home)/Desktop/Tokkah.app",
    ] {
      check("relocates \(p)", needsRelocation(URL(fileURLWithPath: p)))
    }
    // Must NOT relocate: these are the two homes the app is allowed to have, and
    // a false positive here means relocating on every single launch.
    for p in ["/Applications/Tokkah.app", "\(home)/Applications/Tokkah.app"] {
      check("leaves \(p) alone", !needsRelocation(URL(fileURLWithPath: p)))
    }

    fputs("== install ==\n", stderr)
    let root = fm.temporaryDirectory.appendingPathComponent("tk-install-test-\(getpid())")
    try? fm.removeItem(at: root)

    /// A minimal but real bundle: the code reads CFBundleShortVersionString out of
    /// it to decide about downgrades, so a stub without one would not exercise that.
    func makeApp(at url: URL, version: String, bundleId: String = "com.tokkah.tk") throws {
      let macos = url.appendingPathComponent("Contents/MacOS")
      try fm.createDirectory(at: macos, withIntermediateDirectories: true)
      let exe = macos.appendingPathComponent("Tokkah")
      try "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
      try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
      let plist: [String: Any] = ["CFBundleExecutable": "Tokkah",
                                  "CFBundleIdentifier": bundleId,
                                  "CFBundleName": url.deletingPathExtension().lastPathComponent,
                                  "CFBundleShortVersionString": version,
                                  "CFBundleVersion": version]
      let d = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      try d.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    do {
      let src = root.appendingPathComponent("src/Tokkah.app")
      let dest = root.appendingPathComponent("Applications").path
      try makeApp(at: src, version: "0.42.0")

      // 1. A clean install into an empty directory.
      let got = install(src, into: dest)
      let landed = URL(fileURLWithPath: dest).appendingPathComponent("Tokkah.app")
      check("returned the installed path", got?.path == landed.path)
      check("bundle is there", fm.fileExists(atPath: landed.path))
      check("executable came with it",
            fm.isExecutableFile(atPath: landed.appendingPathComponent("Contents/MacOS/Tokkah").path))
      check("source is untouched", fm.fileExists(atPath: src.path))
      check("installed version is 0.42.0", shortVersion(ofBundle: landed) == "0.42.0")

      // 2. Reinstalling the same version over itself must work, not fail on the
      //    existing bundle -- this is the ordinary case of opening the DMG twice.
      check("reinstall over itself succeeds", install(src, into: dest)?.path == landed.path)
      check("still there after reinstall", fm.fileExists(atPath: landed.path))

      // 3. Upgrade: an older install gets replaced.
      let newer = root.appendingPathComponent("src2/Tokkah.app")
      try makeApp(at: newer, version: "0.43.0")
      _ = install(newer, into: dest)
      check("0.43.0 replaced 0.42.0", shortVersion(ofBundle: landed) == "0.43.0")

      // 4. THE DOWNGRADE REFUSAL. Opening a stale .dmg out of Downloads must not
      //    replace a newer working install. This is the one that costs a user
      //    something real if it is wrong, and string comparison gets it wrong at
      //    exactly the version where it starts to matter ("0.9.9" vs "0.10.0").
      let older = root.appendingPathComponent("src3/Tokkah.app")
      try makeApp(at: older, version: "0.38.0")
      let back = install(older, into: dest)
      check("refuses the downgrade", shortVersion(ofBundle: landed) == "0.43.0")
      check("and hands off to the installed copy instead", back?.path == landed.path)

      // 4b. THE RENAME'S OTHER HALF. Kin.app is the same app as Tokkah.app under
      //     a new name, so installing it next to an older Tokkah.app of ours must
      //     leave one app behind, not two.
      let kinDest = root.appendingPathComponent("Applications2").path
      let oldTokkah = URL(fileURLWithPath: kinDest).appendingPathComponent("Tokkah.app")
      let kinSrc = root.appendingPathComponent("src4/Kin.app")
      try makeApp(at: oldTokkah, version: "0.42.0")
      try makeApp(at: kinSrc, version: "0.43.0")
      let kinLanded = URL(fileURLWithPath: kinDest).appendingPathComponent("Kin.app")
      check("Kin.app installed", install(kinSrc, into: kinDest)?.path == kinLanded.path)
      check("older Tokkah.app removed", !fm.fileExists(atPath: oldTokkah.path))

      // 4c. But a NEWER Tokkah.app is somebody mid-upgrade. Deleting it to leave
      //     an older Kin.app is the same downgrade case 4 refuses, so both stay.
      let kinDest2 = root.appendingPathComponent("Applications3").path
      let newTokkah = URL(fileURLWithPath: kinDest2).appendingPathComponent("Tokkah.app")
      try makeApp(at: newTokkah, version: "0.44.0")
      let olderKin = root.appendingPathComponent("src5/Kin.app")
      try makeApp(at: olderKin, version: "0.43.0")
      _ = install(olderKin, into: kinDest2)
      check("newer Tokkah.app is left alone", fm.fileExists(atPath: newTokkah.path))
      check("and it is still 0.44.0", shortVersion(ofBundle: newTokkah) == "0.44.0")

      // 5. No debris. A leftover .incoming or .previous would be a half-bundle
      //    sitting in /Applications forever.
      let junk = (try? fm.contentsOfDirectory(atPath: dest))?
        .filter { $0.hasPrefix(".") } ?? []
      check("no staging leftovers in \(dest) (\(junk))", junk.isEmpty)

      // 6. An unwritable destination must fail cleanly rather than destroying the
      //    source -- the user's download has to survive a failed install.
      let ro = root.appendingPathComponent("readonly").path
      try fm.createDirectory(atPath: ro, withIntermediateDirectories: true)
      try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: ro)
      check("unwritable destination returns nil", install(src, into: ro) == nil)
      check("source survived a failed install", fm.fileExists(atPath: src.path))
      try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ro)
    } catch {
      check("setup (\(error))", false)
    }
    try? fm.removeItem(at: root)
    return ok
  }
}
