import Foundation
import AppKit

// ── RINGING A MAC WHOSE APP IS CLOSED ────────────────────────────────────────
//
// Until now a ring only arrived while Kin was open, because the poll that finds
// it lives inside the running app. Close the window and you are uncallable --
// which makes handle-dialling a party trick rather than a way to reach someone.
//
// The obvious answer is a push notification, and it is not available: APNs needs
// an Apple Developer ID, and there is deliberately no $99 here. So the app has to
// keep a small piece of itself running.
//
// WHAT THIS IS: a LaunchAgent in the user's own ~/Library/LaunchAgents that runs
// `tk --watch`. No privileges, no installer, no Developer ID -- a per-user agent
// is the oldest supported way to do this on macOS and it needs nothing granted.
// `--watch` sets `.prohibited` activation policy, so it has no Dock icon, no menu
// bar and no window: it is a poll loop and nothing else.
//
// WHAT IT IS NOT: it is not the app running in the background burning your
// battery. One HTTPS GET every few seconds, the same poll the open app already
// does, and it holds no camera, no microphone and no socket.
//
// WHEN A RING ARRIVES it launches the real app with `--incoming`, which shows the
// answer/decline card. The watcher keeps watching -- it does NOT become the call,
// because then a declined call would leave you uncallable again.
//
// ── AND IT LIVES IN THE MENU BAR, BECAUSE A DAEMON IS NOT A FEATURE ──────────
//
// The paragraph above was true and the feature still reached nobody. `.prohibited`
// is a process with no Dock icon, no menu bar, no window and no way to be
// addressed at all: nothing on screen said this Mac could be rung, nothing said
// it could not, and the only way to stop it was `launchctl`. A person who never
// opens a terminal had no evidence the thing existed -- which is
// `feature-behind-a-flag-nobody-runs` one level up, where the flag is invisibility.
//
// `.accessory` is the identical process with one capability added: it may own a
// status item. See `Resident` at the bottom of this file for what it shows and,
// more importantly, for what it refuses to show.
enum Watch {
  /// The production label, and a rig override beside it. A test that installs a
  /// real LaunchAgent must not be able to bootout the user's own -- and it would,
  /// because `bootout` takes a label and a label is global to the login session.
  /// Same reason `TK_KIN_DIR` exists: `rig-isolation-that-does-not-isolate`.
  static let defaultLabel = "com.tokkah.tk.watch"
  static var label: String {
    ProcessInfo.processInfo.environment["TK_WATCH_LABEL"] ?? defaultLabel
  }
  static var plistURL: URL {
    URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist")
  }

  /// The executable a LaunchAgent should run. Inside a bundle this is the real
  /// binary; the agent must NOT point at a path in a temp directory or a build
  /// tree, because it will still be there at login and the app will not.
  static func exePath() -> String {
    (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).path
  }

  static var installed: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

  /// ── launchd PINS THE JOB TO THE CODE IT BOOTSTRAPPED ─────────────────────
  ///
  /// Every self-update filed one crash report, and only one:
  ///
  ///     Parent: launchd   Coalition: com.tokkah.tk.watch
  ///     EXC_CRASH (SIGKILL (Code Signature Invalid))
  ///     Termination: CODESIGNING, Launch Constraint Violation
  ///
  /// 67 ms in, before anything but dyld, and then KeepAlive tried again and the
  /// second one worked. Four releases lived with it, because "recovers on its
  /// own" and "nobody has looked" draw the same graph.
  ///
  /// REPRODUCED on this Mac, and it took three attempts to find the ingredient:
  ///   * kill the resident, no swap                       -> relaunches cleanly
  ///   * swap in a BYTE-IDENTICAL copy, then kill         -> relaunches cleanly
  ///   * swap in a validly signed copy with a DIFFERENT
  ///     cdhash, then kill                                -> REFUSED, once
  ///
  /// So it is not the swap and not a race: launchd holds the job to the code
  /// identity it was bootstrapped with, and the first launch of a different one
  /// at that path is refused. The designated requirement is unchanged and
  /// correct -- `identifier "com.tokkah.tk" and certificate root = H"..."` -- the
  /// cdhash is what moved, and every release moves it.
  ///
  /// The answer is to tell launchd, rather than to let it find out. Ordering is
  /// the whole risk: this process IS the job, so a bootout kills us before we
  /// could bootstrap, and a bootout that is never followed by one leaves this Mac
  /// unable to answer a call until the next login -- the one failure this project
  /// treats as unacceptable. So the work is handed to a detached `sh` that
  /// outlives us, it re-writes the plist first (so a bootstrap cannot fail for
  /// want of one), and it retries.
  @discardableResult
  static func reregister() -> Bool {
    guard installed else { return false }
    let uid = getuid()
    let l = label
    let plist = plistURL.path
    // `bootout` alone is never the last thing this can do: every path through the
    // script ends in a bootstrap attempt, and the loop tries again if the job is
    // not there afterwards.
    let script = """
    /bin/launchctl bootout gui/\(uid)/\(l) 2>/dev/null
    for i in 1 2 3 4 5; do
      sleep 1
      /bin/launchctl bootstrap gui/\(uid) '\(plist)' 2>/dev/null
      if /bin/launchctl print gui/\(uid)/\(l) >/dev/null 2>&1; then exit 0; fi
    done
    # Last resort: kickstart whatever is there, so a Mac is never left with no job.
    /bin/launchctl kickstart -k gui/\(uid)/\(l) 2>/dev/null
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", script]
    // Detached: the whole point is that it runs after this process is gone.
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch {
      fputs("watch: could not re-register the login item: \(error)\n", stderr)
      return false
    }
    fputs("watch: re-registering the login item so launchd takes the new build's"
        + " code identity -- without this the first relaunch after an update is"
        + " refused and files a crash report\n", stderr)
    return true
  }

  /// ── A FILE ON DISK IS NOT A RUNNING AGENT ──────────────────────────────────
  ///
  /// The startup check used to be `installed || stale` -- does the plist exist,
  /// and does it point somewhere real. Both can be true of a Mac that launchd is
  /// not watching for calls at all: `bootout` unloads the agent and leaves the
  /// file exactly where it was. Every launch after that found a plist, decided
  /// there was nothing to do, and the Mac stayed uncallable until the next login.
  /// Observed here directly -- one bootout and three rings that opened nothing.
  ///
  /// So health is what launchd says, not what the filesystem says. Same shape as
  /// every other liveness bug in this codebase: never trust the artifact when you
  /// can ask the thing that owns it.
  static func loaded() -> Bool {
    run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).ok
  }

  /// Present, current, and actually loaded. Anything else calls for a reinstall.
  static func healthy() -> Bool { installed && !stale() && loaded() }

  /// ── AND SOMETHING THAT PUTS IT BACK ────────────────────────────────────────
  ///
  /// `healthy()` had exactly one caller and it drew a row. Nothing repaired the
  /// unhealthy case, so a job that went missing stayed missing until somebody
  /// noticed a switch was off and pressed it -- and the symptom of a missing job
  /// is silence, which nobody notices. Found on this Mac: the plist present, the
  /// service gone from launchd, and no way to be called with Kin closed. The
  /// comment above this one describes the same thing happening once before.
  ///
  /// A repair, not an install: it runs only when the plist is already there,
  /// which is the record of somebody having asked for this. It never creates one.
  /// Off the main thread -- `launchctl` is a subprocess.
  ///
  /// Returns what it did, for the log. `nil` means there was nothing to do.
  @discardableResult
  static func repairIfNeeded() -> String? {
    guard installed else { return nil }        // never asked for -- not ours to add
    if let why = staleReason() {
      // Pointing at a copy that no longer exists. `install()` rewrites the plist
      // from where this binary actually is, which is the only thing that fixes it.
      let said = install()
      return "watch: the login item was stale (\(why)) -- \(said)"
    }
    guard !loaded() else { return nil }
    let ok = reregister()
    return "watch: the login item was not loaded in launchd -- "
         + (ok ? "put back" : "COULD NOT put it back; calls will not reach this Mac while Kin is closed")
  }

  /// True when the agent's plist points at an executable that no longer exists,
  /// or at a different copy than the one running. A stale agent is worse than no
  /// agent: it fails silently at every login and nobody is reachable.
  static func stale() -> Bool { staleReason() != nil }

  /// WHY it is stale, because there are three reasons and they call for three
  /// different things. A status line that reported "points at a copy that is
  /// gone" for a plist whose copy was right there is a diagnostic that sends the
  /// next person looking in the wrong place.
  static func staleReason() -> String? {
    guard let d = try? Data(contentsOf: plistURL),
          let o = try? PropertyListSerialization.propertyList(from: d, format: nil),
          let dict = o as? [String: Any],
          let args = dict["ProgramArguments"] as? [String], let p = args.first
    else { return "unreadable" }
    if !FileManager.default.fileExists(atPath: p) { return "points at a copy that is gone" }
    if p != exePath() { return "points at a different copy: \(p)" }
    // A plist written by an older build. This one is missing the log paths, which
    // is the difference between "why did my Mac not ring" having an answer and
    // not having one -- and an agent is only ever rewritten when something here
    // says it is out of date.
    if dict["StandardErrorPath"] == nil { return "written by an older build, no log" }
    // ── A PLIST CHANGE THAT NEVER REACHES AN INSTALLED MAC ────────────────────
    //
    // `healthy()` is what decides whether install() runs again, and a plist that
    // is present, current and loaded is healthy no matter what is IN it. So every
    // Mac that already had a login item would have kept the old plist forever,
    // and the change below -- off the throttled Background band, onto the one a
    // process owning a menu bar item belongs in -- would have shipped to nobody.
    // Same shape as the log-path line above it: each key this file starts to care
    // about needs a line here or it is a change to new installs only.
    if dict["ProcessType"] as? String != "Interactive" {
      return "written by an older build, throttled priority"
    }
    // The KeepAlive fix above is worth nothing to anybody who already has a
    // login item -- which is everybody it happened to -- unless this line is
    // here. `true` is a Bool; the old value was a dictionary, so the cast is
    // also the test.
    if dict["KeepAlive"] as? Bool != true {
      return "written by an older build, a clean exit would leave it dead"
    }
    return nil
  }

  @discardableResult
  static func install() -> String {
    let env = ProcessInfo.processInfo.environment
    let exe = exePath()
    // The rig override exists so the login-item path can be PROVEN -- through
    // real launchd, at a real label, with a real plist -- without a copy in
    // /Applications. A test that has to skip the mechanism it is testing is not
    // a test of it. Production never sets this, so the guard is unchanged there.
    // `~/Applications` counts, and leaving it out was a hole: `Install` treats a
    // copy there as installed and never relocates it, so on a Mac where
    // /Applications was not writable Kin settled into the home folder and then
    // silently never got a login item. Both are stable targets at login; the one
    // thing that is not is a copy somebody double-clicked in Downloads.
    guard exe.hasPrefix("/Applications/")
       || exe.hasPrefix(NSHomeDirectory() + "/Applications/")
       || env["TK_WATCH_ANYWHERE"] == "1" else {
      return "watch: not installing a login item for \(exe) -- only an installed"
           + " copy in /Applications is a stable target at login"
    }
    // ── A WATCHER THAT LEAVES NO TRACE CANNOT BE DEBUGGED ────────────────────
    //
    // This process runs for weeks with nobody looking at it, and the only
    // question anyone will ever ask about it is "why did my Mac not ring?".
    // Without these two paths launchd sends its output to /dev/null and that
    // question has no answer at all -- not a wrong answer, none.
    let logs = logDir()
    let logName = label == defaultLabel ? "watch.log" : "\(label).log"
    var plist: [String: Any] = [
      "Label": label,
      "ProgramArguments": [exe, "--watch"],
      "RunAtLoad": true,
      // ── A CLEAN EXIT IS STILL A DEAD DOORBELL ──────────────────────────────
      //
      // This was `["SuccessfulExit": false]` -- restart it only if it died
      // badly. That policy has now cost two outages. The comment above
      // `ringLoop` records the first: a race let the agent exit 0 before the
      // handle claim landed, "and the Mac was then uncallable until the next
      // login, on the very first launch, silently." That instance was fixed by
      // removing THAT exit. The policy was left alone, so the class survived.
      //
      // The second, 2026-08-26: the agent exited 0 at 20:03 the previous
      // evening, moments after handing a real incoming call to a fresh Kin,
      // and launchd did exactly what it was told -- nothing. Twenty hours
      // later a call from another Mac rang into an empty house.
      //
      // The asymmetry is the whole argument. A clean exit we did not intend
      // costs every incoming call until the next login, silently. An extra
      // restart we did not need costs one process. So: restart it whatever
      // happened, and let the ONE exit that genuinely means "stop" say so by
      // booting itself out of launchd rather than by picking an exit code --
      // see `quit()`. ThrottleInterval keeps a binary that dies instantly from
      // spinning.
      "KeepAlive": true,
      "ThrottleInterval": 30,
      // NOT "Background". That band is for work the user is unaware of, and it
      // carries throttled I/O and a low scheduling priority -- neither of which
      // belongs on a process whose entire job is to put a window on screen the
      // instant somebody calls. `Interactive` is what this actually is: it owns a
      // status item the user looks at and it must react at human speed.
      "ProcessType": "Interactive",
      "StandardOutPath": logs.appendingPathComponent(logName).path,
      "StandardErrorPath": logs.appendingPathComponent(logName).path,
    ]
    // ── THE AGENT MUST WATCH THE MAILBOX THE APP CLAIMED ──────────────────────
    //
    // launchd hands an agent a nearly empty environment, so a rig that points
    // this build at a disposable identity gets an agent watching the REAL one --
    // and a "test" that rings the user's own handle. Carried through explicitly
    // rather than inherited, because inheritance is exactly what does not happen.
    var vars: [String: String] = [:]
    // TK_CRASH_DIR rides along for the same reason as TK_KIN_DIR: an agent
    // installed by a rig would otherwise read the machine's REAL crash folder
    // and report its own history to whatever sink that rig is running.
    for k in ["TK_KIN_DIR", "TK_KIN_BASE", "TK_WATCH_LABEL", "TK_WATCH_ANYWHERE",
              "TK_WATCH_OPEN_ARGS", "TK_WATCH_SELFTEST", "TK_WATCH_NO_DELEGATE",
              "TK_CRASH_DIR", "TK_CRASH_GRACE_S"] {
      if let v = env[k] { vars[k] = v }
    }
    if !vars.isEmpty { plist["EnvironmentVariables"] = vars }
    do {
      try FileManager.default.createDirectory(
        at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let d = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      try d.write(to: plistURL, options: .atomic)
    } catch {
      return "watch: could not write \(plistURL.path): \(error)"
    }
    // ── ONE INSTALLER AT A TIME ───────────────────────────────────────────────
    //
    // `bootout` then `bootstrap` is not atomic, and the app re-execs on the way
    // to a room: two images can be inside this window at once. Interleaved, one
    // image's bootout lands after the other's bootstrap and the agent ends up
    // unloaded -- with both processes having logged "installed". Seen: two
    // install lines from a single launch.
    //
    // A non-blocking exclusive lock, so the loser skips rather than queues. There
    // is nothing for a second installer to do that the first is not already doing.
    let lockPath = plistURL.deletingLastPathComponent()
      .appendingPathComponent(".\(label).installing").path
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) != 0 {
      close(fd)
      return "watch: another Kin is installing the login item -- leaving it to that one"
    }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }

    // Kick it now so it works without a logout.
    let r = reloadNow()
    return r.ok ? "watch: login item installed -- this Mac can now be rung while Kin is closed"
                : "watch: plist written but launchctl said: \(r.out)"
  }

  /// ── ONE BOOTOUT-THEN-BOOTSTRAP, AND IT RETRIES ────────────────────────────
  ///
  /// `bootout` returns before launchd has finished tearing the job down, and a
  /// `bootstrap` that lands inside that window fails with
  ///
  ///     Bootstrap failed: 5: Input/output error
  ///
  /// `install()` did it exactly once and put that sentence in front of the
  /// person as a permanent failure, on a Mac where the very next attempt
  /// succeeds -- observed here, and the retry by hand worked first time.
  /// `reregister()`'s detached script had a five-round retry loop all along, so
  /// the two paths that do the same thing disagreed about whether it needs one
  /// (`second-copy-of-a-rule`). This is that loop, for the callers that are not
  /// about to exit.
  ///
  /// Success is `loaded()` -- what launchd says -- and not the exit code of the
  /// last bootstrap: a bootstrap can fail because the job is ALREADY there,
  /// which is the outcome we wanted.
  @discardableResult
  static func reloadNow(tries: Int = 5) -> (ok: Bool, out: String) {
    _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
    var last = ""
    for i in 0..<tries {
      if i > 0 { Thread.sleep(forTimeInterval: 0.4) }
      let r = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
      if loaded() { return (true, "") }
      last = r.out.isEmpty ? last : r.out
    }
    // Never leave the Mac with no job because a bootstrap kept losing a race.
    _ = run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
    return (loaded(), last)
  }

  @discardableResult
  /// Stop the agent for this login session without removing it. `RunAtLoad`
  /// brings it back at the next login, which is the promise the menu makes.
  static func bootoutSelf() {
    _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
  }

  static func uninstall() -> String {
    _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
    try? FileManager.default.removeItem(at: plistURL)
    return "watch: login item removed -- this Mac can only be rung while Kin is open"
  }

  // -- CAN THIS MAC BE RUNG WITH KIN CLOSED, AND IF NOT, WHY -----------------
  //
  // `status()` below is for a terminal and says "plist present, launchd running".
  // Nobody who owns this problem is ever going to type that. This is the same
  // question answered in the words the person actually has -- and, crucially,
  // with the ONE thing that would fix it, because a setting that reports itself
  // broken and leaves you to work out the rest is a diagnostic, not a feature.
  enum Fix { case none, install, moveToApplications, openLoginItems, restart }
  struct Reach {
    let on: Bool
    /// One sentence, plain, no paths and no launchd.
    let says: String
    let fix: Fix
  }

  static func reach() -> Reach {
    let exe = exePath()
    let placed = exe.hasPrefix("/Applications/")
              || exe.hasPrefix(NSHomeDirectory() + "/Applications/")
              || ProcessInfo.processInfo.environment["TK_WATCH_ANYWHERE"] == "1"
    guard placed else {
      return Reach(on: false,
                   says: "Kin has to be in your Applications folder to answer while it\u{2019}s closed.",
                   fix: .moveToApplications)
    }
    // ── "LOADED" IS NOT "RUNNING", AND launchctl WILL NOT VOLUNTEER THE ──────
    // ── DIFFERENCE ───────────────────────────────────────────────────────────
    //
    // This used to be `run(...).ok` alone. `launchctl print` exits 0 for a job
    // that is merely REGISTERED -- including one that ran, exited, and was never
    // restarted. Calibrated on a purpose-built control: a throwaway agent
    // running /usr/bin/true reports `state = not running`, `runs = 1`,
    // `last exit code = 0`, and `launchctl print` still exits 0.
    //
    // So on 2026-08-26 this function returned `on: true` -- "people can reach
    // you with Kin closed" -- for twenty hours during which nothing on this Mac
    // was listening. Every surface that asks got the same wrong answer: the
    // settings row, the permissions check, and the startup line. `status()`
    // twenty lines below had it right all along by reading `state = running`
    // out of the output; the function everybody actually calls did not.
    //
    // An instrument that returns "fine" for the broken case is worse than no
    // instrument, because it is what stops anybody looking.
    let printed = run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])
    let loaded = printed.ok
    let running = printed.out.contains("state = running")
    if installed, loaded, running, staleReason() == nil {
      return Reach(on: true, says: "", fix: .none)
    }
    // Registered, and not running. Unlike every other case here, this one the
    // app can repair by itself and without asking anybody for permission, so
    // the sentence promises exactly that and nothing more.
    if installed, loaded, !running, staleReason() == nil {
      return Reach(on: false,
                   says: "Kin stopped listening for calls in the background. Turn it back on.",
                   fix: .restart)
    }
    // The plist is on disk and launchd is not running it. On macOS 13 and later
    // that is nearly always the person having switched Kin off under Login Items,
    // and nothing this app writes will turn it back on -- only they can.
    if installed, !loaded {
      return Reach(on: false,
                   says: "macOS has Kin switched off in Login Items, so calls stop when you quit.",
                   fix: .openLoginItems)
    }
    return Reach(on: false, says: "Right now Kin only rings while it\u{2019}s open.", fix: .install)
  }

  /// Start the agent again after it has stopped. `kickstart -k` kills any
  /// lingering instance first, so this is also the way out of a wedged one, and
  /// it needs no consent from anybody -- the login item is already approved.
  /// Returns whether the job is running afterwards, read back rather than
  /// assumed: this project has shipped a live setting that reported itself
  /// applied and was not.
  @discardableResult
  static func restart() -> Bool {
    _ = run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
    return run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])
      .out.contains("state = running")
  }

  static func status() -> String {
    let r = run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])
    let running = r.out.contains("state = running")
    let w = reach()
    return "watch: plist \(installed ? "present" : "absent")"
         + (installed ? (staleReason().map { " (STALE -- \($0))" } ?? "") : "")
         + ", launchd \(r.ok ? (running ? "running" : "loaded") : "not loaded")"
         // The verdict the app itself acts on, printed from the same call the
         // app makes. A status command that computes its own similar answer is
         // a second implementation to drift, and this one drifted silently for
         // twenty hours: `status()` read `state = running` and was right, while
         // `reach()` read only the exit code and told every screen "reachable".
         + ", reachable-closed \(w.on ? "yes" : "no")"
         + (w.on ? "" : " (\(w.says) fix=\(w.fix))")
  }

  /// `~/Library/Logs/Kin`, created on demand. Console.app already knows to look
  /// here, so a user can be asked for it by name without being asked for a path.
  /// ── A RIG MUST NOT WRITE INTO THE USER'S LOG ─────────────────────────────
  ///
  /// `open --stderr` TRUNCATES the file it is given, so a rig launching Kin
  /// through the resident wiped ~/Library/Logs/Kin/ring.log -- the record of
  /// the last real call on this Mac -- and then read its own output out of the
  /// user's log. TK_KIN_DIR already gives a rig its own identity; the logs the
  /// same run writes belong in the same lane.
  static func logDir() -> URL {
    if let d = ProcessInfo.processInfo.environment["TK_KIN_DIR"] {
      let u = URL(fileURLWithPath: d).appendingPathComponent("logs", isDirectory: true)
      try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
      return u
    }
    let d = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Kin", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
  }

  private static func run(_ path: String, _ args: [String]) -> (ok: Bool, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (false, "\(error)") }
    // Read BEFORE waiting: a child that fills the pipe buffer blocks forever if
    // the parent is inside waitUntilExit.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
  }

  // ── The watcher itself ─────────────────────────────────────────────────────

  /// Never returns. Owns the status item on the main thread, polls the doorbell
  /// on another, and launches the app when somebody rings.
  ///
  /// ── NO CAMERA, NO MICROPHONE, EVER ────────────────────────────────────────
  ///
  /// This process runs from login to logout, so anything it opens is open all
  /// day: a device grabbed here is a permission dialog at login and a green light
  /// on somebody's laptop while they are not on a call. It is structurally
  /// impossible rather than merely avoided -- `main.swift` reaches `--watch`
  /// above every line that touches AVFoundation or CoreAudio, and this function
  /// never returns, so none of that code is on any path from here.
  static func run(gapMs: Int) -> Never {
    let app = NSApplication.shared
    // `.accessory`, not `.prohibited`: same absence of a Dock icon and a ⌘-Tab
    // entry, but a process that may own a status item. `.prohibited` may not, and
    // that one word was the difference between a feature and a rumour.
    // ── AND IT MUST SAY SO WHEN IT CANNOT ─────────────────────────────────
    //
    // The return value was thrown away, and the call FAILS after an execv: the
    // new image inherits the LaunchServices registration of the one it replaced,
    // already checked in as Foreground. Every self-update therefore left a
    // resident with a Dock icon -- a second Kin sitting in the Dock next to the
    // real one, which is what "the dual app opening has not been fixed" was.
    // A silent no-op in the one line that makes this process invisible.
    if !app.setActivationPolicy(.accessory) {
      fputs("watch: WARNING -- could not go invisible, this resident will show a"
          + " Dock icon. An execv'd resident cannot; it has to be restarted by"
          + " launchd (see Update.restart).\n", stderr)
    }
    // ── A RIG MUST BE ABLE TO RUN THIS WITHOUT TOUCHING THE REAL DIRECTORY ────
    //
    // `TK_NO_IDENTITY` is how every rig in mac/tools avoids claiming a name on
    // the production server, and this call ignored it -- so a watcher rig walked
    // @devesh, @deveshp, @deveshpatel, @devesh2 ... @devesh9 against the live
    // directory on every run, which is the exact squatting mute-check.sh sets
    // the variable to prevent. The guard existed; it was declared 260 lines
    // below a function that never returns, so the watcher could not see it.
    if !noIdentity {
      Identity.ensure()
      fputs("watch: resident for @\(Identity.handle), checking every \(gapMs) ms\n", stderr)
    } else {
      fputs("watch: TK_NO_IDENTITY -- no handle claimed, this copy cannot be rung\n", stderr)
    }
    Resident.install()
    if ProcessInfo.processInfo.environment["TK_WATCH_SELFTEST"] == "1" { Resident.selftest() }
    Thread {
      Thread.current.name = "kin-doorbell"
      watchForever(gapMs: gapMs)
    }.start()
    // The run loop is what makes the status item live: without it the menu never
    // opens and the icon never redraws. It also never returns.
    app.run()
    exit(0)
  }

  /// ── A RESIDENT RUNNING LAST MONTH'S CODE ──────────────────────────────────
  ///
  /// launchd starts this at login and never again. The self-updater replaces the
  /// binary underneath it and the OLD image keeps running -- for days, until the
  /// next logout -- so every change in this file lands on nobody who already has
  /// the login item. That is `updater-ships-only-what-it-can-install` with the
  /// stranded half being the part that answers the door.
  ///
  /// Exit non-zero on purpose: `KeepAlive { SuccessfulExit: false }` restarts a
  /// failure and leaves a clean exit alone, which is also what makes the menu's
  /// Quit stay quit. So "my binary was replaced" has to be spelled as a failure.
  private static func imageStamp() -> String? {
    guard let a = try? FileManager.default.attributesOfItem(atPath: exePath()) else { return nil }
    let ino = (a[.systemFileNumber] as? Int) ?? 0
    let size = (a[.size] as? Int) ?? 0
    let mt = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return "\(ino)/\(size)/\(Int(mt))"
  }

  private static func watchForever(gapMs: Int) {
    let bundle = Bundle.main.bundleURL.path
    // ── RIG OVERRIDE, AND THE ONE IT EXISTS FOR ───────────────────────────────
    //
    // A rig copy of the app is by definition not in /Applications, which is
    // exactly `Install.needsRelocation` -- so ringing a test bundle makes the
    // app it launches install ITSELF over the user's working copy and hand off.
    // That has already destroyed a release once (see Install.relocateIfHomeless).
    // The launch args are fixed in production and this is empty there; a test
    // adds --no-relocate, --no-rings and --mute and stays in its own lane.
    let extraArgs = (ProcessInfo.processInfo.environment["TK_WATCH_OPEN_ARGS"] ?? "")
      .split(separator: " ").map(String.init)
    if !bundle.hasSuffix(".app") {
      // `open -a` takes an app, and a bare binary's `bundleURL` is the directory
      // it sits in. Said once, up front: otherwise the first evidence is a ring
      // that arrives, verifies, and opens nothing.
      fputs("watch: WARNING -- \(bundle) is not an app bundle, a ring will not"
          + " be able to open anything\n", stderr)
    }
    let born = imageStamp()
    var lastRoom = ""
    // ── A HANDLE CLAIMED ON ONE THREAD AND CHECKED ON ANOTHER ─────────────────
    //
    // This used to be `guard Identity.claimed else { exit(0) }`. On a first
    // install `Watch.install()` bootstraps the agent from one background thread
    // while `Identity.start()` claims the handle from another, so the agent
    // routinely started BEFORE the claim landed, read `claimed == false`, and
    // exited 0 -- which KeepAlive treats as "it meant to stop". The Mac was then
    // uncallable until the next login, on the very first launch, silently. So an
    // unclaimed identity is a thing to keep trying, not a reason to die.
    var nextClaim = Date.distantPast
    // ── THE SAME LOOP THE OPEN APP USES, AND STANDING DOWN FOR IT ─────────────
    //
    // This was its own `poll; sleep` copy. Two consequences, and the second is
    // the one that was actually happening: the held poll would have made a call
    // instant for everyone with Kin open and left it averaging 2.5 s for
    // everyone without -- which is the entire population this process exists for
    // -- and, with both halves polling one handle on one credential, the server
    // was refusing one of them most of the time.
    //
    // `standDown: true` yields the mailbox whenever the app is open. See the
    // block above `Identity.claimLine`: the app wins because it is the half that
    // can turn a ring into a lit screen with no launch in between, and because a
    // destructive drain means whichever poll returns first TAKES the ring --
    // two holders is not merely wasteful, it loses calls.
    //
    // `gapMs` is no longer the cadence. It is only what the loop falls back to
    // when the server turns out not to hold.
    Identity.ringLoop(gapMs: gapMs, standDown: true, onTick: {
      // A binary swapped underneath us. Checked here rather than on a timer of
      // its own so it cannot fire in the middle of opening a call.
      if let born, let now = imageStamp(), born != now {
        fputs("watch: this Mac has a newer Kin -- restarting into it\n", stderr)
        exit(3)
      }
      if !Identity.claimed, Date() >= nextClaim {
        nextClaim = Date().addingTimeInterval(60)
        Identity.claim()
      }
      Resident.refresh()
    }) { r in
      // ── A HANG-UP IS NOT A DOORBELL, AND IT IS NOT RUBBISH EITHER ──────
      //
      // `ringLoop` hands every verified message to this closure, byes included --
      // only the app's own listener filtered on kind. So a cancelled call could
      // open a window, ring, and connect to a room the caller had already left:
      // rung by somebody who had just hung up. A watcher must therefore never
      // open a window for one, and this branch is where that is decided. It also
      // deliberately does NOT touch `lastRoom` -- a bye is not a ring this Mac
      // has been shown.
      //
      // ── AND THE SENTENCE THAT USED TO BE HERE WAS FALSE ────────────────
      //
      // "there is nothing for a watcher to DO with a bye (the copy it launched
      // does its own polling and will hear its own)". It does its own polling
      // about half a second AFTER it is launched, and until then this process is
      // the only one draining this mailbox. Every hang-up that landed in that
      // half-second was taken here, dropped here, and never reached the copy that
      // was ringing at somebody -- which then rang for the full 45 s for a call
      // that had been called off. A cancel one beat after a misdial is the
      // ordinary case, not an edge one, so that window was most of them.
      //
      // The message cannot be handed back to the server: the caller signs it and
      // this process holds none of their keys. So it is left on disk for the copy
      // to find. See `Identity.noteCancelled` for who may write one, what it has
      // to match before anything acts on it, and how it expires -- the rules live
      // there because the ringing copy is the half that has to apply them.
      if r.kind != nil {
        fputs("watch: @\(r.from) sent \(r.kind!) for room \(r.room) -- not a call to open\n",
              stderr)
        if r.kind == "bye" { Identity.noteCancelled(r) }
        return
      }
      guard r.ageMs < 60_000, r.room != lastRoom else { return }
      lastRoom = r.room
      // Timestamped, because "how long from ringing to a window" is the only
      // number this feature is judged on and the two halves of it are measured
      // in two different processes.
      fputs("watch: \(String(format: "%.3f", Date().timeIntervalSince1970))"
          + " @\(r.from) is calling -- opening Kin\n", stderr)
      // A NEW process, not this one. If the watcher became the call, declining
      // it would leave nothing watching and this Mac would go uncallable until
      // the next login.
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      // `--stderr` and not a pipe: `open` returns immediately, so there is no
      // parent left to drain a pipe, and the app it launched outlives it by the
      // length of the call. A file is the only sink that survives that.
      p.arguments = ["-n", "-a", bundle,
                     "--stderr", logDir().appendingPathComponent("ring.log").path,
                     "--args",
                     "--room", r.room, "--incoming", r.from,
                     // THE KEY, not just the name. The app decides whether to
                     // connect before anybody answers -- so it can show who is
                     // calling -- and it is only allowed to do that for somebody
                     // already in the contact list. Without this the app has a
                     // handle and no way to check it, and a handle is a claim.
                     // An older watcher omits it and the app simply does not
                     // connect early, which is what it did before this existed.
                     "--incoming-key", r.k,
                     "--video", "camera", "--window"] + extraArgs
      do { try p.run() } catch {
        fputs("watch: could not open Kin: \(error)\n", stderr)
      }
    }
    // ringLoop with no deadline never returns; this is here only because the
    // signature promises Never.
    exit(0)
  }
}

// ── WHAT SITS IN THE MENU BAR ────────────────────────────────────────────────
//
// Three facts and nothing else: who you are, whether you can be reached, and how
// to make it stop. That list is the whole specification, and everything left out
// of it was left out on purpose -- no poll interval, no last-seen time, no error
// code, no count of anything. This is the consumer surface, and a menu with
// numbers in it is a menu that has to be read instead of glanced at.
//
// ── AND IT HAS TO BE TRUE, NOT OPTIMISTIC ───────────────────────────────────
//
// The one state worth building this for is "you think calls can reach you and
// they cannot", so the reachable line is driven by the last answer the doorbell
// actually gave (`Identity.reachable`) and never by the absence of rings. An
// empty mailbox and a dead network return the same thing from `poll()`; a status
// item that could not tell them apart would show a green light to an unreachable
// Mac, which is the failure it exists to prevent.
//
// Rebuilt on every open rather than kept in sync by notifications: the menu is
// looked at a handful of times a day and correctness at the moment of looking is
// worth more than a cached title being cheap.
enum Resident {
  private static var item: NSStatusItem?
  private static let target = Target()
  private static var shownState = ""

  static func install() {
    // ── A RESIDENT EATS THE FRONT DOOR UNLESS IT HANDS IT BACK ────────────────
    //
    // Touching `NSApplication.shared` registers this process with LaunchServices
    // as a running instance of com.tokkah.tk. From that moment -- login to logout
    // -- a Finder double-click, a Dock click, Spotlight and a bare `open -a Kin`
    // all resolve to THIS process and send it kAEReopenApplication instead of
    // launching anything. There is a runloop here, so the event is answered, so
    // Finder shows no error: the app simply never opens, silently, with nothing
    // for the user to report. `open -n` in the ring path and in the menu hides it
    // from us and from nobody else.
    //
    // This is not hypothetical. The `.prohibited` revision of this file produced
    // "The application "Kin" is not open anymore." on every launch after the
    // watcher started -- same registration, louder symptom. `.accessory` is
    // identical on this point and merely fails quietly, which is worse.
    //
    // So the resident answers the door and hands the caller straight back out as
    // a real launch. The user cannot tell it from a cold start.
    // The control arm, so the defect above can be re-proven rather than taken on
    // trust -- with it set, `open -a Kin` produces no process, no window and no
    // error, which is what a user would have got. Announced in both directions:
    // a switch that turns off the front door must never be silent.
    if ProcessInfo.processInfo.environment["TK_WATCH_NO_DELEGATE"] == "1" {
      fputs("watch: TK_WATCH_NO_DELEGATE -- opening Kin from Finder or the Dock will"
          + " do NOTHING while this resident runs. Control arm only.\n", stderr)
    } else {
      NSApp.delegate = target
    }
    let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    menu.delegate = target
    // ── `isEnabled` IS IGNORED UNLESS THIS IS OFF ─────────────────────────────
    //
    // An auto-enabling menu decides each item for itself: enabled if its target
    // responds to its action, and every `isEnabled = ...` written below is then a
    // line that reads as a decision and is not one. That is the same dead-control
    // shape as an item whose target never got assigned -- it just fails toward
    // "live" instead of "greyed", so nobody notices until a control that should
    // have been unavailable fires. Enablement here is a real decision, so the
    // menu is told to take it from us.
    menu.autoenablesItems = false
    it.menu = menu
    item = it
    refresh()
  }

  /// ── AND IT DOES NOT STAY INVISIBLE BY ITSELF ──────────────────────────────
  ///
  /// `.accessory` is set once at startup, and answering a reopen UNDOES IT.
  /// Measured: the resident reads `.accessory` before a Dock click and
  /// `.regular` after one, so from the first click onward there were two Kin
  /// icons in the Dock -- the app, and a watcher that is supposed to have no
  /// icon at all. That is the duplicate the report was about; the copy counts
  /// were right the whole time.
  ///
  /// Re-asserted on every tick rather than only after a reopen, because "what
  /// else promotes this process" is not a list anybody can be sure they have
  /// finished, and a state that repairs itself does not need the list. It costs
  /// one comparison per tick, and it only ever runs `setActivationPolicy` when
  /// the answer has actually drifted.
  private static var saidVisible = false
  static func stayInvisible() {
    guard NSApp?.activationPolicy() != .accessory else { return }
    let ok = NSApp?.setActivationPolicy(.accessory) ?? false
    if !saidVisible {
      saidVisible = true
      fputs("watch: this resident had become a Dock app -- put back out of sight"
          + (ok ? "" : ", AND THE CALL FAILED: there is a second Kin in the Dock")
          + "\n", stderr)
    }
  }

  /// What one word is true right now. Order matters: paused outranks reachable,
  /// because somebody who has silenced their calls is not waiting to be told
  /// their network is fine.
  private enum State: String {
    case starting, naming, offline, paused, ready
  }
  private static func state() -> State {
    if !Identity.claimed { return .naming }
    // Before the first round trip there is no evidence either way, and "can't
    // reach this Mac" for the two seconds after login would be a lie told at the
    // exact moment somebody is looking to see whether this thing works.
    if Identity.lastPollAt == .distantPast { return .starting }
    if Identity.quietOn { return .paused }
    return Identity.reachable ? .ready : .offline
  }

  /// Plain words, and each one says what it means for the person rather than for
  /// the program. "offline" is not "poll failed": from where the user sits the
  /// fact is that a call would not arrive.
  private static func words(_ s: State) -> String {
    switch s {
    case .starting: return "Getting ready…"
    case .naming:   return "Choosing your name…"
    case .offline:  return "Calls can't reach this Mac"
    case .paused:   return "Calls are paused"
    case .ready:    return "Ready for calls"
    }
  }

  /// Safe from any thread. The poll loop calls it after every round trip.
  static func refresh() {
    if !Thread.isMainThread { DispatchQueue.main.async { refresh() }; return }
    stayInvisible()
    let s = state()
    guard s.rawValue != shownState else { return }
    shownState = s.rawValue
    guard let b = item?.button else { return }
    // A template image so it inverts with a dark menu bar, and a moon for paused
    // because that is what a Mac user already reads as "do not disturb".
    let symbol = s == .paused ? "moon.fill" : "phone.fill"
    if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Kin") {
      img.isTemplate = true
      b.image = img
      b.title = ""
    } else {
      // Never seen on macOS 13+, but a status item with neither image nor title
      // is a zero-width gap in the menu bar -- an invisible resident again.
      b.image = nil
      b.title = "Kin"
    }
    // Dimmed while the answer is "not right now". Not a second icon to learn:
    // the same phone, quieter, and the menu says the words.
    b.alphaValue = (s == .ready || s == .paused) ? 1.0 : 0.45
    b.toolTip = "Kin — " + words(s)
  }

  // ── PROVING IT, THE WAY A FINGER PROVES IT ─────────────────────────────────
  //
  // `Menu.click` in Menu.swift exists because three controls in this app read as
  // finished and did nothing -- targets that landed on the wrong item, a handler
  // that was never assigned. A status item has the same two failure modes plus
  // one of its own: a button with neither an image nor a title is a zero-width
  // gap in the menu bar, which is the invisible resident all over again.
  //
  // So this reports the width, then drives the menu with `update()` (what opening
  // it does, and what runs the delegate) and reads back every item's target --
  // and then actually OPENS it, because a menu nobody has seen drawn is a menu
  // nobody has tested. `cancelTracking` is scheduled in `.eventTracking` mode
  // first: `performClick` runs a modal tracking loop and the ordinary main queue
  // does not turn while it does, so a timer in the default mode would fire only
  // after the thing it was supposed to close had already closed.
  static func selftest() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      guard let it = item, let b = it.button, let menu = it.menu else {
        fputs("watch: selftest FAIL -- there is no status item\n", stderr); return
      }
      let hasFace = b.image != nil || !(b.title.isEmpty)
      fputs("watch: selftest item width=\(Int(b.bounds.width))"
          + " face=\(hasFace ? "yes" : "NONE -- invisible") alpha=\(b.alphaValue)\n", stderr)
      // BOTH calls, in AppKit's order, and the first one is the one this test was
      // missing: `NSMenu.update()` only re-validates items that already exist, so
      // on a menu built by a delegate it walked an EMPTY array and reported
      // nothing -- a blind instrument returning the same output as a clean pass.
      // `menuNeedsUpdate` is what actually fills it, and AppKit calls it first.
      target.menuNeedsUpdate(menu)
      menu.update()
      for i in menu.items {
        if i.isSeparatorItem { continue }
        let owner = i.target.map { String(describing: type(of: $0)) } ?? "nil"
        let act = i.action.map { NSStringFromSelector($0) } ?? "-"
        fputs("watch: selftest \"\(i.title)\" target=\(owner) action=\(act)"
            + " \(i.isEnabled ? "enabled" : "greyed")"
            + (i.state == .on ? " ticked" : "") + "\n", stderr)
      }
      let close = Timer(timeInterval: 6, repeats: false) { _ in menu.cancelTracking() }
      RunLoop.main.add(close, forMode: .eventTracking)
      fputs("watch: selftest opening the menu\n", stderr)
      b.performClick(nil)
      fputs("watch: selftest menu closed\n", stderr)
    }
  }

  final class Target: NSObject, NSMenuDelegate, NSApplicationDelegate {

    /// Finder, the Dock, Spotlight, Launchpad, `open -a Kin`. All of them land
    /// here while the resident holds the bundle's registration, and all of them
    /// mean one thing: somebody wants the app. Hand it to a fresh process rather
    /// than opening a window in this one -- the "no camera, no microphone, ever"
    /// invariant on `Watch.run` is structural precisely because nothing in this
    /// process ever reaches the code that opens a device, and the moment the
    /// resident starts hosting call windows that stops being true.
    ///
    /// `true` because the reopen IS handled; `false` would let AppKit go looking
    /// for an untitled document to open, which this app does not have.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
      fputs("watch: somebody opened Kin -- handing it to a new process\n", stderr)
      launch()
      // ── AND STAY OUT OF THE DOCK WHILE DOING IT ────────────────────────────
      //
      // Handling a reopen is what promotes this process to `.regular`, and the
      // repair lived only on the resident's tick -- so between the click and the
      // next tick there really were two Kin icons in the Dock, which is the
      // report that started all of this. Put back here, at the moment it
      // happens, and again on the next turn of the run loop because AppKit sets
      // the policy AFTER this delegate returns.
      stayInvisible()
      DispatchQueue.main.async { stayInvisible() }
      return true
    }

    /// `kin://` and `tokkah://` are registered to this bundle, so a link clicked
    /// in a browser is swallowed by exactly the same registration -- and by a
    /// process that has no room, no window and no rendezvous to join with.
    ///
    /// Forwarded as a URL rather than parsed here and passed as `--room`: the
    /// rules for what a link may contain live in `Launcher.Handler` and are not
    /// trivial, and a second copy of them is a second thing to get wrong. The new
    /// instance reads its own link on its own launch path, which is the path a
    /// cold click already takes and the only one that is really tested.
    func application(_ application: NSApplication, open urls: [URL]) {
      for u in urls {
        fputs("watch: a Kin link arrived here -- handing \(u.scheme ?? "?") to a new process\n",
              stderr)
        launch(url: u)
      }
      // A link opens this process too, and promotes it exactly as a reopen does.
      stayInvisible()
      DispatchQueue.main.async { stayInvisible() }
    }

    /// `-n`, and it is the whole point: without it LaunchServices resolves the
    /// bundle to this very process and the launch turns back into the reopen we
    /// are answering, forever.
    /// ── A REOPEN IS NOT ALWAYS A LAUNCH ───────────────────────────────────────
    ///
    /// Reported as "a lot of apps are opening... every time I single click on the
    /// app, it opens a new app."
    ///
    /// Both halves above are correct and together they made this: the resident
    /// registers as com.tokkah.tk, so EVERY Dock click, Finder double-click and
    /// Spotlight hit resolves here and arrives as a reopen; and `-n` is genuinely
    /// required, because without it LaunchServices resolves the bundle straight
    /// back to this process and the launch becomes the reopen we are answering.
    ///
    /// What was missing is the question in between. Nothing asked whether Kin was
    /// ALREADY OPEN. `-n` means "new instance" unconditionally, so ten clicks are
    /// ten copies of the app, each with its own window, camera and microphone.
    ///
    /// A reopen with no URL means "show me Kin", and the honest answer to that,
    /// when Kin is already showing, is to bring it forward. Only a reopen that
    /// finds nothing running is a launch.
    ///
    /// ── THE PID IS -1 BECAUSE THE APP RE-EXEC'D, NOT BECAUSE IT DIED ──────
    ///
    /// Reported first as six clicks that did nothing ("already open (pid -1)"),
    /// and then, after a fix that read -1 as "nothing is running", as a NEW COPY
    /// OF KIN ON EVERY CLICK. Both are the same misreading of the same number.
    ///
    /// Measured on this Mac, polling `runningApplications` every 15 ms through a
    /// launch:
    ///
    ///        0 ms  70032                  <- just the resident
    ///       40 ms  70032,72721            <- the new Kin, with a real pid
    ///      256 ms  -1,70032               <- and from here on, forever
    ///
    /// 256 ms is `Launcher.reexec`. Kin opens, mints a room and `execv`s itself
    /// into it -- and execv keeps the pid, the window and the Dock icon while
    /// LaunchServices loses the process behind its record. So `-1` does not mean
    /// "gone". It means "open, and macOS can no longer address it": `activate`
    /// returns true and does nothing, and `NSRunningApplication(processIdentifier:)`
    /// built from the app's REAL pid hands back a record that still says -1.
    ///
    /// A record, then, is not evidence either way, and no reading of one can be.
    /// The question "is Kin open" is answered from the process table instead --
    /// `siblings()` -- and the answer is used for the only thing that matters
    /// here: never starting a second copy.
    ///
    /// `live` survives as the rule for records that DO carry a pid, because a
    /// record that names a pid must still name a running one.
    static func live(pid: pid_t, terminated: Bool, me: pid_t,
                     alive: (pid_t) -> Bool = Target.running) -> Bool {
      if terminated { return false }
      // -1 is the documented sentinel, 0 is "every process in my group" to
      // `kill` and has never been a running app: neither is a pid.
      if pid <= 0 { return false }
      // The resident is itself a running instance of this bundle -- that
      // registration is the whole reason we are here -- and it must never count
      // as the app being open.
      if pid == me { return false }
      return alive(pid)
    }

    /// ── kill(2) TAKES A PID AND A TARGET SET ────────────────────────────────
    ///
    /// The guard is not defensive tidiness. `kill(-1, 0)` does not ask about pid
    /// -1: it asks about EVERY process this user can signal, and answers yes. So
    /// the sentinel that started all of this reads as "running" here -- and the
    /// raise that follows, `kill(-1, SIGWINCH)`, would have gone to every process
    /// the user owns. Found by the rig, on the -1 arm, before it shipped.
    ///
    /// 0 is the same shape one step smaller: to `kill` it means this process's
    /// whole group.
    static func running(_ pid: pid_t) -> Bool {
      guard pid > 0 else { return false }
      return kill(pid, 0) == 0 || errno == EPERM
    }

    /// The path the kernel would report for this file: symlinks resolved, `/tmp`
    /// expanded to `/private/tmp`, `.` and `..` gone. `realpath(3)` because it is
    /// the same resolution `proc_pidpath` returns, and a comparison between two
    /// different resolutions of one path is a comparison that fails on a machine
    /// nobody tested on.
    static func realPath(_ p: String) -> String? {
      guard let r = realpath(p, nil) else { return nil }
      defer { free(r) }
      return String(cString: r)
    }

    /// Every live process running this bundle's executable, except this one.
    /// The process table, because it is the only place that still knows: a
    /// re-exec'd Kin is missing from LaunchServices' answer and present here.
    static func siblings() -> [pid_t] {
      // ── BOTH SIDES THROUGH realpath(3), OR NEITHER ─────────────────────────
      //
      // `proc_pidpath` always returns a fully resolved path. `URL.resolvingSymlinksInPath`
      // does not: measured here, it left `/tmp/.../Kin.app/Contents/MacOS/Tokkah`
      // as it found it while the kernel reported `/private/tmp/...` for the very
      // same process. The comparison failed, the scan came back empty, and the
      // resident opened a second Kin -- the exact bug this function exists to
      // stop, hiding inside the fix for it. Caught by the rig.
      guard let raw = Bundle.main.executableURL?.path,
            let exe = Target.realPath(raw) else { return [] }
      let me = ProcessInfo.processInfo.processIdentifier
      var n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
      guard n > 0 else { return [] }
      // Room to spare: processes can start between the sizing call and the read,
      // and a short buffer silently truncates the answer -- which here would read
      // as "no Kin is open" and start another one.
      var pids = [pid_t](repeating: 0, count: Int(n) / MemoryLayout<pid_t>.size + 128)
      n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                        Int32(pids.count * MemoryLayout<pid_t>.size))
      guard n > 0 else { return [] }
      var buf = [CChar](repeating: 0, count: 4096)
      var out: [pid_t] = []
      for p in pids where p > 0 && p != me {
        guard proc_pidpath(p, &buf, UInt32(buf.count)) > 0 else { continue }
        guard String(cString: buf) == exe else { continue }
        // ── THE SAME BINARY IS NOT THE SAME JOB ────────────────────────────
        //
        // The resident IS this executable, and so is the ring watcher, and so
        // is every `--*-test`. Counting those as "Kin is open" would answer a
        // Dock click by bringing forward a process with no window -- which is a
        // click that does nothing, the report this all started with. What the
        // person wants is a window, so a window is what is looked for.
        let a = argv(p)
        if a.contains("--watch") { continue }
        if !a.contains("--window") { continue }
        out.append(p)
      }
      return out
    }

    /// One process's argv, via KERN_PROCARGS2. Empty when it cannot be read --
    /// which is the safe direction here: an unreadable process is not counted as
    /// an open Kin, so the click starts one rather than silently doing nothing.
    static func argv(_ pid: pid_t) -> [String] {
      var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
      var size = 0
      guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
      var buf = [CChar](repeating: 0, count: size)
      guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
      else { return [] }
      // Layout: argc (4 bytes), the executable path, then NUL-padded argv.
      let bytes = buf.prefix(size).map { UInt8(bitPattern: $0) }
      let argc = bytes.prefix(4).enumerated().reduce(Int32(0)) { $0 | (Int32($1.element) << (8 * Int32($1.offset))) }
      var parts: [String] = []
      var cur: [UInt8] = []
      for b in bytes.dropFirst(MemoryLayout<Int32>.size) {
        if b == 0 {
          if !cur.isEmpty { parts.append(String(decoding: cur, as: UTF8.self)); cur = [] }
        } else {
          cur.append(b)
        }
      }
      if !cur.isEmpty { parts.append(String(decoding: cur, as: UTF8.self)) }
      // The first entry is the executable path, not argv[0]; drop it, then keep
      // argc entries.
      return Array(parts.dropFirst().prefix(Int(max(argc, 0))))
    }

    // ── THE SIGNAL A COPY THAT PREDATES IT WILL SURVIVE ───────────────────────
    //
    // An open Kin that macOS cannot activate can still raise itself, from the
    // inside, if something asks it to -- and a signal is the one channel that
    // needs no port, no permission and no handle.
    //
    // SIGWINCH and not SIGUSR1 because of the update window: the resident
    // updates itself and restarts, so a NEW resident routinely faces an OLD Kin
    // that has no handler for this. SIGUSR1's default action is to TERMINATE --
    // a click would have killed the call somebody was on. SIGWINCH's default
    // action is to do nothing at all, so the worst an old copy does is ignore it.
    static let raiseSignal = SIGWINCH

    // ── THE RULER, ON ANSWERS ALREADY KNOWN ────────────────────────────────
    //
    // Table-driven and deliberately full of cases it MUST REJECT, because a
    // predicate that answers `false` to everything would pass a table of only
    // positives -- and `false` is the safe answer for a record, so that is the
    // exact shape a broken fix would take. The two accept rows are what stop it
    // degenerating into "no record is ever usable".
    //
    // `-1` is the field case, verbatim, and it is the first row. It is REJECTED
    // here and that is still right: a record carrying the sentinel cannot be
    // activated. What changed after the second report is that rejecting it is no
    // longer the whole answer -- `siblings()` decides whether Kin is open, and
    // the last two checks are the ones that would have caught the copies.
    static func selfTestLive() -> Bool {
      let me: pid_t = 4242
      let dead: pid_t = 999_999   // above the kernel's pid ceiling: never running
      let cases: [(String, pid_t, Bool, Bool)] = [
        ("the sentinel: a record macOS cannot address", -1, false, false),
        ("a sentinel that also admits it is gone",      -1, true,  false),
        ("pid 0 -- to kill(2) that is a whole group",    0, false, false),
        ("the resident, seeing its own registration",   me, false, false),
        ("a plausible pid that has already exited",   dead, false, false),
        ("a real, live, other Kin",
         ProcessInfo.processInfo.processIdentifier, false, true),
        ("pid 1 -- launchd is always running",           1, false, true),
      ]
      // kill(-1, 0) asks about EVERY process this user can signal and answers
      // yes, so a liveness check written on `kill` alone calls the sentinel
      // alive. Asserted separately from the table because it is a property of
      // `running`, which the table reaches only through `live`.
      var ok = true
      for bad: pid_t in [-1, 0, -999] where running(bad) {
        ok = false
        fputs("reopen: FAIL running(\(bad)) says yes -- kill(2) reads a"
            + " non-positive pid as a SET of processes, not as one\n", stderr)
      }
      if ok { fputs("reopen: OK   running() refuses non-positive pids\n", stderr) }
      for (what, pid, term, want) in cases {
        let got = live(pid: pid, terminated: term, me: me)
        if got != want { ok = false }
        fputs("reopen: \(got == want ? "OK  " : "FAIL") pid=\(pid)"
            + " terminated=\(term) -> \(got ? "usable record" : "no")"
            + "  \(what)\n", stderr)
      }
      // ── AND THE HALF A RECORD CANNOT ANSWER ─────────────────────────────────
      //
      // This process IS a running copy of this executable, so a sibling scan run
      // from a second process must find it. Proving that here needs no second
      // process: `siblings()` excludes only `me`, so pointing it at our own pid
      // is the same question asked from the outside.
      let mine = ProcessInfo.processInfo.processIdentifier
      let sibs = siblings()
      if sibs.contains(mine) {
        ok = false
        fputs("reopen: FAIL siblings() returned our own pid -- the resident would"
            + " read itself as the app being open and never launch anything\n", stderr)
      } else {
        fputs("reopen: OK   siblings() excludes this process (\(sibs.count) other"
            + " cop\(sibs.count == 1 ? "y" : "ies") of this binary)\n", stderr)
      }
      // ── argv, READ BACK ON A PROCESS WHOSE ARGV WE KNOW ────────────────────
      //
      // `siblings()` now filters on argv, so a reader that silently returns
      // nothing would exclude every candidate and open a second Kin on every
      // click -- the failure looks exactly like the bug. This process's own argv
      // is the one answer available for free, and it must come back containing
      // the flag that put us in this function.
      let mineArgv = argv(mine)
      if mineArgv.contains("--reopen-test") {
        fputs("reopen: OK   argv() reads a known process (\(mineArgv.count) args)\n", stderr)
      } else {
        ok = false
        fputs("reopen: FAIL argv() could not read our own --reopen-test argv"
            + " (got \(mineArgv)) -- with argv unreadable, no running Kin is ever"
            + " recognised and every click opens another\n", stderr)
      }
      // The scan must agree with the kernel about every pid it returns: a stale
      // or truncated read here reads as "no Kin is open" and opens another one.
      for p in sibs where !running(p) {
        ok = false
        fputs("reopen: FAIL siblings() returned pid \(p), which is not running\n", stderr)
      }
      // A signal whose default action kills the process would turn a Dock click
      // into a hang-up on any copy of Kin older than the handler.
      if raiseSignal != SIGWINCH {
        ok = false
        fputs("reopen: FAIL the raise signal is not SIGWINCH -- an older Kin would"
            + " take its DEFAULT action for it, and only SIGWINCH's is to do"
            + " nothing\n", stderr)
      } else {
        fputs("reopen: OK   the raise signal is one an older Kin ignores\n", stderr)
      }
      fputs("REOPEN CHECK: \(ok ? "PASS" : "FAIL")\n", stderr)
      return ok
    }

    private func existing() -> NSRunningApplication? {
      guard let id = Bundle.main.bundleIdentifier else { return nil }
      let me = ProcessInfo.processInfo.processIdentifier
      return NSRunningApplication.runningApplications(withBundleIdentifier: id)
        .first { Target.live(pid: $0.processIdentifier, terminated: $0.isTerminated, me: me) }
    }

    private func launch(url: URL? = nil) {
      // Only the plain "show me Kin" reopen is answered this way. A ring carries a
      // URL and there is no channel to hand one to a process already running, so
      // that path still starts a copy -- narrowing this to the case actually
      // reported rather than guessing at the other one.
      // ── THE RIG ARM ────────────────────────────────────────────────────────
      //
      // There is no way to ask the process table for a Kin that is not there, so
      // the pid the question is asked about is the one thing this door opens.
      // Everything after it -- the decision, the raise, the log line and the
      // `open -n` -- is production code, so a rig run reproduces the reported
      // behaviour rather than a model of it.
      //
      // Production never sets it, and it is deliberately absent from the
      // allow-list `install` carries into the launchd plist, so even a rig that
      // sets it cannot leave it behind on a real installed watcher.
      let fake = ProcessInfo.processInfo.environment["TK_WATCH_FAKE_OPEN_PID"]
                   .flatMap { pid_t($0) }
      if url == nil {
        // The process table first and the LaunchServices record second, because
        // only the first one can see a Kin that has re-exec'd. `existing()` is
        // still consulted: when there IS an addressable record, `activate` is
        // what puts the window in front of the person, and asking the app to
        // raise itself is the fallback for when there is not.
        let open: [pid_t] = fake.map { Target.running($0) ? [$0] : [] } ?? Target.siblings()
        if let pid = open.first {
          let record = fake == nil ? existing() : nil
          if let r = record {
            r.activate(options: [.activateAllWindows])
            fputs("watch: Kin is already open (pid \(r.processIdentifier))"
                + " -- brought it forward instead of starting another\n", stderr)
          } else {
            // macOS has no usable handle on this one (see `live` above), so the
            // app is asked to come forward from the inside.
            // `pid > 0` is guaranteed by both sources above and asserted here
            // anyway, because the failure mode is not a no-op: a negative pid
            // signals every process this user owns.
            if pid > 0 { kill(pid, Target.raiseSignal) }
            fputs("watch: Kin is already open (pid \(pid), which macOS cannot"
                + " address) -- asked it to come forward instead of starting"
                + " another\n", stderr)
          }
          return
        }
      }
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      var args = ["-n", "-a", Bundle.main.bundleURL.path,
                  "--stderr", Watch.logDir().appendingPathComponent("ring.log").path]
      // The same rig override the ring path takes (`watchForever`), for the same
      // reason and then one more. A rig bundle is by definition not in
      // /Applications, so a Kin started from here with production args would
      // relocate ITSELF over the user's working copy -- and a reopen is the one
      // launch a person triggers by hand, so this was the half of the door with
      // no lock on it. Empty in production.
      let extra = (ProcessInfo.processInfo.environment["TK_WATCH_OPEN_ARGS"] ?? "")
        .split(separator: " ").map(String.init)
      // `--args` ends `open`'s own option list, so a URL -- which is a document
      // for `open`, not an argument for the app -- has to go in before it.
      if let url { args.append(url.absoluteString) }
      if !extra.isEmpty { args.append(contentsOf: ["--args"] + extra) }
      p.arguments = args
      do { try p.run() } catch {
        fputs("watch: could not open Kin: \(error)\n", stderr)
      }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
      menu.removeAllItems()
      let s = Resident.state()
      // Who you are. Disabled on purpose: it is a label, and a label that can be
      // clicked is a control that does nothing.
      let who = NSMenuItem(title: "@" + Identity.handle, action: nil, keyEquivalent: "")
      who.isEnabled = false
      menu.addItem(who)
      let line = NSMenuItem(title: Resident.words(s), action: nil, keyEquivalent: "")
      line.isEnabled = false
      menu.addItem(line)
      menu.addItem(.separator())

      // Sharing the name is the only thing anyone does with it, so the one action
      // on it is the one that matters.
      let copy = NSMenuItem(title: "Copy My Name", action: #selector(copyName), keyEquivalent: "")
      copy.target = self
      copy.isEnabled = Identity.claimed
      menu.addItem(copy)

      let open = NSMenuItem(title: "Open Kin", action: #selector(openApp), keyEquivalent: "")
      open.target = self
      menu.addItem(open)

      // A tick rather than a changing title: "Pause Calls" with a tick reads the
      // same whichever way it is set, where a title that flips between "Pause"
      // and "Resume" makes you work out which state you are in from the verb.
      let pause = NSMenuItem(title: "Pause Calls", action: #selector(togglePause), keyEquivalent: "")
      pause.target = self
      pause.state = Identity.quietOn ? .on : .off
      pause.isEnabled = Identity.claimed
      menu.addItem(pause)

      menu.addItem(.separator())
      let quit = NSMenuItem(title: "Quit Kin", action: #selector(quit), keyEquivalent: "q")
      quit.target = self
      menu.addItem(quit)
    }

    @objc func copyName() {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString("@" + Identity.handle, forType: .string)
    }

    /// The same handoff the Dock and Finder get, from the menu.
    @objc func openApp() { launch() }

    /// Off main: this is an HTTPS round trip, and the menu is still on screen.
    /// The tick is not moved here -- `setQuiet` only reports what the server
    /// agreed to, and a switch that flips locally while the server refused is
    /// somebody who believes they are unreachable and is not.
    @objc func togglePause() {
      let want = !Identity.quietOn
      Thread {
        Identity.setQuiet(want)
        Resident.refresh()
      }.start()
    }

    /// Quits until the next login, which is what launchd's KeepAlive already
    /// means by a clean exit -- so there is nothing to uninstall and nothing to
    /// remember. Somebody who wants it gone for good uses --watch-remove.
    @objc func quit() {
      fputs("watch: quit from the menu bar -- back at the next login\n", stderr)
      // KeepAlive is unconditional now, so exiting is no longer a way to stop:
      // launchd would have this back within the throttle interval. Booting the
      // job out of the login session is what "until the next login" actually
      // means, and it says it in launchd's own terms rather than by choosing an
      // exit code and hoping the policy still reads it that way.
      //
      // If bootout fails, exit anyway and let launchd bring it back. Of the two
      // ways to be wrong -- a menu item that does not appear to work, and a Mac
      // that silently stops answering calls -- only one of them loses calls.
      Watch.bootoutSelf()
      exit(0)
    }
  }
}
