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
enum Watch {
  static let label = "com.tokkah.tk.watch"
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
    return nil
  }

  @discardableResult
  static func install() -> String {
    let exe = exePath()
    guard exe.hasPrefix("/Applications/") else {
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
    let plist: [String: Any] = [
      "Label": label,
      "ProgramArguments": [exe, "--watch"],
      "RunAtLoad": true,
      // Restart it if it dies, but not in a tight loop if it dies instantly.
      "KeepAlive": ["SuccessfulExit": false] as [String: Any],
      "ThrottleInterval": 30,
      "ProcessType": "Background",
      "StandardOutPath": logs.appendingPathComponent("watch.log").path,
      "StandardErrorPath": logs.appendingPathComponent("watch.log").path,
    ]
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

  /// Never returns. Polls the doorbell and launches the app when somebody rings.
  static func run(gapMs: Int) -> Never {
    NSApplication.shared.setActivationPolicy(.prohibited)
    Identity.ensure()
    guard Identity.claimed else {
      fputs("watch: this Mac has no claimed handle yet -- nothing to watch for\n", stderr)
      // Not an error worth restarting over: claim happens on the next real run.
      exit(0)
    }
    fputs("watch: listening for calls to @\(Identity.handle) every \(gapMs) ms\n", stderr)
    let bundle = Bundle.main.bundleURL.path
    var lastRoom = ""
    while true {
      for r in Identity.poll() {
        guard r.ageMs < 60_000, r.room != lastRoom else { continue }
        lastRoom = r.room
        fputs("watch: @\(r.from) is calling -- opening Kin\n", stderr)
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
                       "--video", "camera", "--window"]
        do { try p.run() } catch {
          fputs("watch: could not open Kin: \(error)\n", stderr)
        }
      }
      Thread.sleep(forTimeInterval: Double(max(2000, gapMs)) / 1000)
    }
  }
}
