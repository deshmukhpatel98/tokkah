import AppKit

// ── The join screen, for a Tokkah.app that was double-clicked ────────────────
//
// `tk` grew up as a command with flags, which is right for measuring things and
// useless for handing to someone on another Mac. An app bundle needs to do
// something sensible when it is launched with no arguments at all.
//
// Rather than restructure the whole program around a UI, this asks for a room and
// then RE-EXECS with `--room <name>`. Everything downstream sees exactly the
// command line it has always seen, so there is one code path for a call and no
// second way for it to be configured. `Bundle.main.executableURL` is the same
// binary either way, which is also what the self-updater re-execs, so this adds
// no new assumption about where the program lives.
enum Launcher {
  /// Remembered so the second launch is one click. A room name is not a secret --
  /// the crypto salt is derived from it, but a call still needs both ends to be
  /// live at the same moment and the rendezvous lease is seconds long.
  private static let lastRoomKey = "tk.lastRoom"

  /// True when this process looks like it was opened from the Finder rather than
  /// typed: inside an .app bundle, and with nothing on the command line that says
  /// where to call. A terminal user running the bundled binary directly gets the
  /// same window, which is the behaviour they would want anyway.
  static func shouldPrompt(hasRoom: Bool, hasPeer: Bool, forced: Bool) -> Bool {
    if forced { return true }
    if hasRoom || hasPeer { return false }
    let path = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    return path.contains("/Contents/MacOS/")
  }

  /// Show the window and block until the user joins or closes it. Returns the
  /// room name, or nil if they closed it -- in which case the caller must exit
  /// rather than fall through to a call with no destination.
  static func askRoom() -> String? {
    // NSApplication FIRST, for the same reason the video path does it: AppKit
    // will happily build an NSWindow before the application object exists and
    // then behave as though the window belongs to nothing.
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 210),
                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
    w.title = "Tokkah"
    w.center()
    w.isReleasedWhenClosed = false

    let v = NSView(frame: w.contentLayoutRect)
    let title = NSTextField(labelWithString: "Join a call")
    title.font = .systemFont(ofSize: 22, weight: .semibold)
    title.frame = NSRect(x: 28, y: 148, width: 364, height: 30)
    v.addSubview(title)

    let sub = NSTextField(labelWithString: "Both people type the same room name.")
    sub.font = .systemFont(ofSize: 12)
    sub.textColor = .secondaryLabelColor
    sub.frame = NSRect(x: 28, y: 126, width: 364, height: 18)
    v.addSubview(sub)

    let field = NSTextField(frame: NSRect(x: 28, y: 78, width: 364, height: 28))
    field.placeholderString = "room name"
    field.stringValue = UserDefaults.standard.string(forKey: lastRoomKey) ?? ""
    field.font = .systemFont(ofSize: 15)
    v.addSubview(field)

    let status = NSTextField(labelWithString: "")
    status.font = .systemFont(ofSize: 11)
    status.textColor = .secondaryLabelColor
    status.frame = NSRect(x: 28, y: 22, width: 240, height: 16)
    v.addSubview(status)

    let join = NSButton(title: "Join", target: nil, action: nil)
    join.frame = NSRect(x: 296, y: 16, width: 96, height: 30)
    join.bezelStyle = .rounded
    join.keyEquivalent = "\r"                      // Return joins
    v.addSubview(join)
    w.contentView = v

    // A tiny target rather than a delegate class: the whole interaction is "did
    // they press Join, and with what text".
    final class Target: NSObject {
      var picked: String?
      var done = false
      let field: NSTextField
      let status: NSTextField
      init(field: NSTextField, status: NSTextField) { self.field = field; self.status = status }
      @objc func go() {
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Refuse rather than silently normalise: the room name is the rendezvous
        // key AND the crypto salt, so "My Room" and "my-room" being quietly the
        // same thing would be a surprise at exactly the wrong moment.
        guard !name.isEmpty else { status.stringValue = "Type a room name."; return }
        guard name.count <= 64,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
          status.stringValue = "Letters, numbers, - and _ only."
          return
        }
        picked = name
        done = true
      }
      @objc func cancel() { done = true }
    }
    let t = Target(field: field, status: status)
    join.target = t
    join.action = #selector(Target.go)

    w.makeKeyAndOrderFront(nil)
    w.makeFirstResponder(field)
    app.activate(ignoringOtherApps: true)

    // Drive the event loop by hand. `app.run()` would not return, and this window
    // has to finish before the audio graph, the sockets or the camera exist.
    while !t.done {
      guard let e = app.nextEvent(matching: .any, until: .distantFuture,
                                 inMode: .default, dequeue: true) else { continue }
      app.sendEvent(e)
      if !w.isVisible { t.done = true }             // they closed it
    }
    w.orderOut(nil)
    if let r = t.picked { UserDefaults.standard.set(r, forKey: lastRoomKey) }
    return t.picked
  }

  /// Replace this process with the same binary, plus the arguments a joined call
  /// needs. execv rather than spawning: one process, so the dock icon, the
  /// permission grants and the self-updater all keep referring to the same thing.
  static func reexec(room: String, extra: [String]) -> Never {
    let me = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).path
    var args = [me, "--room", room] + extra
    // Carry through anything already on the command line, so `--gui` plus a flag
     // under test still behaves.
    args += CommandLine.arguments.dropFirst().filter { $0 != "--gui" }
    var c = args.map { strdup($0) }
    c.append(nil)
    execv(me, &c)
    // Only reached if execv failed, which means the binary moved underneath us.
    fputs("launch: could not re-exec \(me) (errno \(errno))\n", stderr)
    exit(1)
  }
}
