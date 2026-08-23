import AVFoundation
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
  // ── An invite should be a link, not a room name to retype ─────────────────
  //
  // `tokkah://join/<room>` arrives as an Apple Event, not as an argument, and it
  // can arrive BEFORE or AFTER the join window is on screen depending on whether
  // the app was already running. So the handler is installed first and simply
  // records the room; whoever is waiting picks it up.
  //
  // Registered in Info.plist rather than by any runtime call, because
  // LaunchServices reads the bundle -- which is the whole reason this program ships
  // as one.
  nonisolated(unsafe) private static var urlRoom: String?

  static func installURLHandler() {
    NSAppleEventManager.shared().setEventHandler(
      Handler.shared,
      andSelector: #selector(Handler.handle(event:reply:)),
      forEventClass: AEEventClass(kInternetEventClass),
      andEventID: AEEventID(kAEGetURL))
  }

  final class Handler: NSObject {
    static let shared = Handler()
    @objc func handle(event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
      guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let u = URL(string: s), u.scheme == "tokkah" else { return }
      // tokkah://join/<room> and tokkah://<room> both work: people will write
      // either, and refusing one of them would be pedantry with a cost.
      var name = u.path.hasPrefix("/") ? String(u.path.dropFirst()) : u.path
      if name.isEmpty { name = u.host ?? "" }
      if u.host == "join", name.isEmpty { name = "" }
      let ok = !name.isEmpty && name.count <= 64
        && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
      guard ok else {
        fputs("url: refusing \(s) -- a room is letters, numbers, - and _ only\n", stderr)
        return
      }
      Launcher.urlRoom = name
      fputs("url: joining \(name)\n", stderr)
    }
  }

  /// A room handed over by a `tokkah://` link, if one arrived. Consumed once.
  static func takeURLRoom() -> String? {
    let r = urlRoom
    urlRoom = nil
    return r
  }

  // ── Recent rooms, remembered ────────────────────────────────────────────────
  //
  // A room name is the rendezvous key AND the crypto salt, so it is never
  // normalised or guessed at -- but the ones you have actually used are worth
  // offering back. Five, most recent first.
  private static let recentKey = "tk.recentRooms"
  static var recentRooms: [String] {
    UserDefaults.standard.stringArray(forKey: recentKey) ?? []
  }
  static func remember(_ room: String) {
    var r = recentRooms.filter { $0 != room }
    r.insert(room, at: 0)
    UserDefaults.standard.set(Array(r.prefix(5)), forKey: recentKey)
    UserDefaults.standard.set(room, forKey: lastRoomKey)
  }

  /// A room nobody else is in. Three words, because a name you can say down a
  /// phone is worth more here than one that is hard to guess -- the rendezvous
  /// lease is seconds long and both ends have to be live at the same moment, so
  /// the name is not the security boundary. The encryption key is.
  static func suggestRoom() -> String {
    let a = ["ripe", "quiet", "warm", "bright", "kind", "swift", "clear", "brave", "calm", "keen"]
    let b = ["mango", "cedar", "harbour", "meadow", "lantern", "compass", "river", "ember", "willow", "summit"]
    let c = ["jam", "path", "light", "song", "stone", "drift", "bell", "field", "wave", "spark"]
    return "\(a.randomElement()!)-\(b.randomElement()!)-\(c.randomElement()!)"
  }

  static func askRoom() -> String? {
    // NSApplication FIRST, for the same reason the video path does it: AppKit
    // will happily build an NSWindow before the application object exists and
    // then behave as though the window belongs to nothing.
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let W: CGFloat = 520, PREVIEW: CGFloat = 268, H: CGFloat = PREVIEW + 214
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
    w.title = "Tokkah"
    w.center()
    w.isReleasedWhenClosed = false

    let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

    // ── THE CAMERA, BEFORE YOU COMMIT TO A CALL ───────────────────────────────
    //
    // The permission prompt used to appear after joining, at which point the
    // window was showing nothing and there was no way to tell a refused camera
    // from a broken one from a call that had not connected. Here it is answered
    // while you are looking at the thing it is about, and a picture of your own
    // face is the only proof of a working camera that needs no explanation.
    //
    // AVCaptureVideoPreviewLayer, not our own frame handling: this window does not
    // encode anything, so the capture pipeline it needs is the one AVFoundation
    // already has. The session is torn down before the re-exec so the real call
    // opens the device cleanly.
    let camBox = NSView(frame: NSRect(x: 0, y: H - PREVIEW, width: W, height: PREVIEW))
    camBox.wantsLayer = true
    let host = CALayer()
    host.backgroundColor = NSColor.black.cgColor
    camBox.layer = host
    v.addSubview(camBox)

    let hint = NSTextField(labelWithString: "")
    hint.font = .systemFont(ofSize: 12)
    hint.textColor = .secondaryLabelColor
    hint.alignment = .center
    hint.frame = NSRect(x: 20, y: H - PREVIEW / 2 - 9, width: W - 40, height: 18)
    v.addSubview(hint)

    let session = AVCaptureSession()
    var preview: AVCaptureVideoPreviewLayer?
    if let dev = AVCaptureDevice.default(for: .video),
       let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
      session.addInput(input)
      let pl = AVCaptureVideoPreviewLayer(session: session)
      pl.videoGravity = .resizeAspectFill
      pl.frame = CGRect(x: 0, y: 0, width: W, height: PREVIEW)
      host.addSublayer(pl)
      preview = pl
      DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    } else {
      // Said plainly, in the window. A black rectangle with no caption is how a
      // person concludes the app is broken when the answer is one settings toggle.
      hint.stringValue = "No camera available — audio only.\nAllow camera access in System Settings › Privacy & Security."
      hint.maximumNumberOfLines = 2
      hint.frame = NSRect(x: 20, y: H - PREVIEW / 2 - 18, width: W - 40, height: 36)
    }
    _ = preview

    let title = NSTextField(labelWithString: "Join a call")
    title.font = .systemFont(ofSize: 20, weight: .semibold)
    title.frame = NSRect(x: 24, y: H - PREVIEW - 38, width: 300, height: 26)
    v.addSubview(title)

    let sub = NSTextField(labelWithString: "Both of you type the same room name — that is the whole setup. "
                        + "It is also the encryption key, so pick something only the two of you would say.")
    sub.font = .systemFont(ofSize: 11)
    sub.textColor = .secondaryLabelColor
    sub.maximumNumberOfLines = 2
    sub.frame = NSRect(x: 24, y: H - PREVIEW - 74, width: W - 48, height: 32)
    v.addSubview(sub)

    let field = NSTextField(frame: NSRect(x: 24, y: H - PREVIEW - 112, width: W - 48 - 96, height: 30))
    field.placeholderString = "room name"
    field.stringValue = UserDefaults.standard.string(forKey: lastRoomKey) ?? suggestRoom()
    field.font = .systemFont(ofSize: 15)
    v.addSubview(field)

    let newBtn = NSButton(title: "Suggest", target: nil, action: nil)
    newBtn.frame = NSRect(x: W - 24 - 88, y: H - PREVIEW - 112, width: 88, height: 30)
    newBtn.bezelStyle = .rounded
    v.addSubview(newBtn)

    let status = NSTextField(labelWithString: "")
    status.font = .systemFont(ofSize: 11)
    status.textColor = .secondaryLabelColor
    status.frame = NSRect(x: 24, y: 20, width: W - 150, height: 16)
    v.addSubview(status)

    let join = NSButton(title: "Join", target: nil, action: nil)
    join.frame = NSRect(x: W - 24 - 104, y: 14, width: 104, height: 32)
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
      func validate(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Refuse rather than silently normalise: the room name is the rendezvous
        // key AND the crypto salt, so "My Room" and "my-room" being quietly the
        // same thing would be a surprise at exactly the wrong moment.
        guard !name.isEmpty else { status.stringValue = "Type a room name."; return nil }
        guard name.count <= 64,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
          status.stringValue = "Letters, numbers, - and _ only."
          return nil
        }
        return name
      }
      @objc func go() {
        guard let name = validate(field.stringValue) else { return }
        picked = name
        done = true
      }
      @objc func suggest() {
        field.stringValue = Launcher.suggestRoom()
        status.stringValue = ""
      }
      /// A recent room, from its button. The name rides in the button's title, so
      /// there is no parallel array to fall out of step with what is on screen.
      @objc func pickRecent(_ sender: NSButton) {
        field.stringValue = sender.title
        guard let name = validate(sender.title) else { return }
        picked = name
        done = true
      }
      @objc func cancel() { done = true }
    }
    let t = Target(field: field, status: status)
    join.target = t
    join.action = #selector(Target.go)
    newBtn.target = t
    newBtn.action = #selector(Target.suggest)

    // Rooms you have actually been in, one click each.
    let recents = recentRooms
    if !recents.isEmpty {
      let lbl = NSTextField(labelWithString: "Recent")
      lbl.font = .systemFont(ofSize: 10, weight: .semibold)
      lbl.textColor = .tertiaryLabelColor
      lbl.frame = NSRect(x: 24, y: H - PREVIEW - 140, width: 60, height: 14)
      v.addSubview(lbl)
      var x: CGFloat = 24
      for r in recents.prefix(4) {
        let b = NSButton(title: r, target: t, action: #selector(Target.pickRecent(_:)))
        b.bezelStyle = .inline
        b.font = .systemFont(ofSize: 11)
        let width = min(150, b.intrinsicContentSize.width + 18)
        if x + width > W - 24 { break }
        b.frame = NSRect(x: x, y: H - PREVIEW - 166, width: width, height: 22)
        v.addSubview(b)
        x += width + 8
      }
    }

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
    // Release the device before the re-exec, so the call opens it cleanly rather
    // than racing a session this process is about to stop existing to own.
    if session.isRunning { session.stopRunning() }
    if let r = t.picked { remember(r) }
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
