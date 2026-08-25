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
      // Restart it if it dies, but not in a tight loop if it dies instantly.
      "KeepAlive": ["SuccessfulExit": false] as [String: Any],
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
    for k in ["TK_KIN_DIR", "TK_KIN_BASE", "TK_WATCH_LABEL", "TK_WATCH_ANYWHERE",
              "TK_WATCH_OPEN_ARGS", "TK_WATCH_SELFTEST", "TK_WATCH_NO_DELEGATE"] {
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

    // Kick it now so it works without a logout. `bootout` first, because
    // bootstrapping an already-loaded label is an error rather than a refresh.
    _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
    let r = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
    return r.ok ? "watch: login item installed -- this Mac can now be rung while Kin is closed"
                : "watch: plist written but launchctl said: \(r.out)"
  }

  @discardableResult
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
  enum Fix { case none, install, moveToApplications, openLoginItems }
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
    let loaded = run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).ok
    if installed, loaded, staleReason() == nil {
      return Reach(on: true, says: "", fix: .none)
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

  static func status() -> String {
    let r = run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])
    let running = r.out.contains("state = running")
    return "watch: plist \(installed ? "present" : "absent")"
         + (installed ? (staleReason().map { " (STALE -- \($0))" } ?? "") : "")
         + ", launchd \(r.ok ? (running ? "running" : "loaded") : "not loaded")"
  }

  /// `~/Library/Logs/Kin`, created on demand. Console.app already knows to look
  /// here, so a user can be asked for it by name without being asked for a path.
  static func logDir() -> URL {
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
    app.setActivationPolicy(.accessory)
    Identity.ensure()
    fputs("watch: resident for @\(Identity.handle), checking every \(gapMs) ms\n", stderr)
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
      // ── A HANG-UP IS NOT A DOORBELL ────────────────────────────────────
      //
      // `ringLoop` hands every verified message to this closure, byes included --
      // only the app's own listener filtered on kind. So a cancelled call could
      // open a window, ring, and connect to a room the caller had already left:
      // rung by somebody who had just hung up. There is nothing for a watcher to
      // DO with a bye (the copy it launched does its own polling and will hear
      // its own), so it is dropped here, named, and deliberately does NOT touch
      // `lastRoom` -- a bye is not a ring this Mac has been shown.
      if r.kind != nil {
        fputs("watch: @\(r.from) sent \(r.kind!) for room \(r.room) -- not a call to open\n",
              stderr)
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
    }

    /// `-n`, and it is the whole point: without it LaunchServices resolves the
    /// bundle to this very process and the launch turns back into the reopen we
    /// are answering, forever.
    private func launch(url: URL? = nil) {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      var args = ["-n", "-a", Bundle.main.bundleURL.path,
                  "--stderr", Watch.logDir().appendingPathComponent("ring.log").path]
      if let url { args.append(url.absoluteString) }
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
      exit(0)
    }
  }
}
