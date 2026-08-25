import AVFoundation
import AppKit
import Security

// ── The join screen, for a Kin.app that was double-clicked ────────────────
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
  // ── NOBODY IS ASKED FOR A ROOM NAME ────────────────────────────────────────
  //
  // The web app never asks. You open it and the call is already running: your own
  // camera fills the window, a link is minted, and the middle of the screen says
  // "Waiting for the other person…" with that link under it. Naming a room is a
  // question, and a question is a thing to get wrong before anything has happened.
  //
  // The native app asked. That was a whole extra screen in front of the same call,
  // and the report was that the web app's flow is the one to have -- *"whenever you
  // hit the site, the meeting starts, and this is the link that is being displayed
  // instead of asking you the room name"*.
  //
  // So the join window is gone from the default path. It is still reachable with
  // `--join-window` for the case where somebody wants to type a name, but nothing
  // reaches it by default any more.
  static func shouldPrompt(hasRoom: Bool, hasPeer: Bool, forced: Bool) -> Bool {
    forced
  }

  /// `xxx-xxxx-xxx`, lowercase, exactly as `mintRoom()` does it: 26^10 ~ 47 bits,
  /// the same budget Meet spends, and short enough to read down a phone.
  static func mintRoom() -> String {
    var b = [UInt8](repeating: 0, count: 10)
    _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
    let c = String(b.map { Character(UnicodeScalar(97 + ($0 % 26))) })
    let s = Array(c)
    return String(s[0..<3]) + "-" + String(s[3..<7]) + "-" + String(s[7..<10])
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
            let u = URL(string: s),
            u.scheme == "tokkah" || u.scheme == "kin" else { return }
      // tokkah://join/<room> and tokkah://<room> both work: people will write
      // either, and refusing one of them would be pedantry with a cost.
      //
      // `kin` was registered in Info.plist and then refused right here, so
      // LaunchServices launched the app, handed over the scheme it had been told
      // to route, and this dropped it on the floor. The new invite funnel
      // (tape-app/public/join.js) emits tokkah:// today, but every registered
      // scheme has to land in a room: a registered scheme that does nothing
      // looks exactly like a working one, right up to the silence.
      var name = u.path.hasPrefix("/") ? String(u.path.dropFirst()) : u.path
      if name.isEmpty { name = u.host ?? "" }
      if u.host == "join", name.isEmpty { name = "" }
      let ok = !name.isEmpty && name.count <= 64
        && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
      guard ok else {
        fputs("url: refusing \(s) -- a room is letters, numbers, - and _ only\n", stderr)
        return
      }
      // A link that arrives while a call is already up has nobody waiting on the
      // mailbox: the only reader is the launch path, and the re-exec'd call
      // process is past it forever. So a live process installs a handler instead,
      // and the mailbox is the fallback for the launch that has not read it yet.
      if let f = Launcher.onURLRoom { f(name) } else { Launcher.urlRoom = name }
      fputs("url: joining \(name)\n", stderr)
    }

    /// kAEOpenApplication / kAEReopenApplication. Nothing to read out of it: the
    /// fact that it ARRIVED is the whole message -- it means this launch is a
    /// plain one and no `tokkah://` is on its way.
    @objc func launched(event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
      Launcher.sawLaunchEvent = true
    }
  }

  /// Set when a launch Apple Event arrives, which is the proof that this launch
  /// carries no URL. See awaitURLRoom.
  nonisolated(unsafe) private static var sawLaunchEvent = false

  // REGISTRATION ORDER IS LOAD-BEARING AND BACKWARDS FROM WHAT IT LOOKS LIKE:
  // finishLaunching() installs AppKit's OWN kCoreEventClass handlers, so this has
  // to run AFTER it or AppKit quietly replaces ours and the flag never sets.
  private static func installLaunchEventHandlers() {
    let m = NSAppleEventManager.shared()
    for id in [kAEOpenApplication, kAEReopenApplication] {
      m.setEventHandler(Handler.shared,
                        andSelector: #selector(Handler.launched(event:reply:)),
                        forEventClass: AEEventClass(kCoreEventClass),
                        andEventID: AEEventID(id))
    }
  }

  // ── ONE HAND-DRIVEN APPKIT PUMP ─────────────────────────────────────────────
  //
  // There were three copies of this loop -- here, in askRoom, and in the
  // rendezvous wait in main -- each with slightly different slice and exit
  // handling, which is exactly how the fourth one drifts. A main thread that does
  // not come back to the runloop is a window that exists, is key, and shows
  // nothing: the 2878 ms of blank glass this program used to open with.
  //
  // `nextEvent`/`sendEvent` and not CFRunLoopRunInMode: the AppKit queue is not
  // the runloop, and a bare CFRunLoopRunInMode after finishLaunching was measured
  // returning nil where the same wait in nextEvent had the event in 27 ms.
  static func pumpAppKit(until deadline: Date, slice: Double = 0.02,
                         while keepGoing: () -> Bool = { true }) {
    let app = NSApplication.shared
    while keepGoing(), Date() < deadline {
      let step = min(slice, max(0, deadline.timeIntervalSinceNow))
      guard let e = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: step),
                                  inMode: .default, dequeue: true) else { continue }
      app.sendEvent(e)
    }
  }

  /// The one slot `runPumping` writes its answer into. A class, so the closure
  /// that runs off-thread and the caller that reads it afterwards are looking at
  /// the same storage; a local type cannot be nested in a generic function.
  final class PumpBox<V> { var v: V? }

  // ── A BLOCKING CALL ON MAIN IS A CONTROL THAT DOES NOTHING ──────────────────
  //
  // `pumpAppKit` fixed main walking into the network and not coming back for
  // 2878 ms. It did not fix main going back IN every hundred milliseconds. The
  // rendezvous poll is a synchronous HTTPS round trip -- `URLSession` plus a
  // `DispatchSemaphore.wait`, roughly 300-400 ms to the worker -- and the loop
  // that owns the whole waiting screen ran it on main. So for about four fifths
  // of every second the invite link was drawn, hit-testable and pressable, and
  // the press went into the queue and stayed there. Measured, from a real
  // synthetic click: due at 605 ms, executed at 1546 ms.
  //
  // That is the user's complaint exactly -- "the person should be able to copy
  // the link and share it as fast as possible" -- and it is not the camera.
  //
  // The result still comes back HERE, to the caller, on the caller's thread, so
  // nothing about the program's order or its thread ownership changes: the peer
  // list is still processed on main and `wire` is still touched from one thread.
  // Only the WAITING moves. `pump: false` is the headless path, where there is no
  // window to keep alive and a thread hop would be pure cost.
  ///
  /// Run `work` off this thread and keep AppKit turning until it finishes.
  /// Returns nil if `timeout` expired -- in which case the value is deliberately
  /// NOT read, because another thread is still writing it.
  static func runPumping<T>(pump: Bool, timeout: TimeInterval = 12,
                            _ work: @escaping () -> T) -> T? {
    guard pump else { return work() }
    // A class box, and a semaphore between the write and the read. The signal/wait
    // pair is the memory barrier, so there is never a moment where one thread is
    // reading this while the other writes it -- which for anything refcounted is
    // the difference between a value and a crash.
    let box = PumpBox<T>()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      let r = work()
      box.v = r
      done.signal()
    }
    let deadline = Date().addingTimeInterval(timeout)
    // 8 ms slices: half a frame at 60 Hz, so a click is serviced within one
    // refresh of arriving rather than at the end of a network round trip.
    while Date() < deadline {
      pumpAppKit(until: min(Date().addingTimeInterval(0.008), deadline), slice: 0.008)
      if done.wait(timeout: .now()) == .success { return box.v }
    }
    return nil
  }

  /// A room handed over by a `tokkah://` link, if one arrived. Consumed once.
  static func takeURLRoom() -> String? {
    let r = urlRoom
    urlRoom = nil
    return r
  }

  /// Where a link should go once a call is already running. Set by the call
  /// process; when it is set the mailbox is bypassed entirely.
  nonisolated(unsafe) static var onURLRoom: ((String) -> Void)?

  // ── THE MAIL HAS NOT ARRIVED WHEN YOU OPEN THE MAILBOX ─────────────────────
  //
  // `tokkah://` does not come in on argv. LaunchServices starts the app and then
  // DELIVERS the URL as an Apple Event, a moment later -- so installing the
  // handler and reading `urlRoom` in the same straight line always reads nil,
  // because nothing has pumped events yet. That is exactly how every single link
  // click minted a stranger's room: the invite was sitting in the queue, unread,
  // and the re-exec that followed destroyed the queue along with it.
  //
  // Two things are load-bearing here and both were measured, not assumed:
  //
  //   `finishLaunching()` -- NSApplication HOLDS the launch Apple Events until it
  //   is called. Without it the event never arrives at all: a 3 s wait that turned
  //   the runloop the whole time still returned nil.
  //
  //   `nextEvent`/`sendEvent` -- and not `CFRunLoopRunInMode`. The AppKit queue is
  //   not the runloop; a bare 3 s of `CFRunLoopRunInMode(.defaultMode)` after
  //   finishLaunching ALSO returned nil, while the same wait spent in `nextEvent`
  //   had the room in 27 ms. Same loop askRoom() drives by hand, for the same
  //   reason.
  //
  // It returns the INSTANT the room arrives, so the only launch that pays the
  // timeout is a plain double-click -- the one with nothing to wait for.
  //
  // ── AND THAT LAUNCH WAS PAYING ALL OF IT ────────────────────────────────────
  //
  // "the only launch that pays the timeout is a plain double-click" was written as
  // if that launch were rare. It is the common one, and it paid the full 700 ms
  // every single time: first stderr at 818 ms plain against 44 ms with --room.
  // The wait was right and the unconditional budget was not.
  //
  // A plain launch is not silent -- it gets kAEOpenApplication (or
  // kAEReopenApplication), delivered on the same queue as the URL. So there are
  // two mailboxes now and the wait ends on whichever fills: a link, or the proof
  // that no link is coming. The fallback timeout is for the launch that delivers
  // neither, and it is 250 ms rather than 700 because it is now a backstop and no
  // longer the normal path.
  //
  // NAMED RISK: we replace AppKit's own oapp handler to do this. There is no app
  // delegate and no NSDocument here, so the default is close to a no-op -- but
  // "close to" is not provable by reading, which is why acceptance checks that a
  // plain launch still comes forward and still builds its menu.
  static func awaitURLRoom(within budget: Double) -> String? {
    // NSApplication FIRST, for the same reason askRoom() does it: Apple Event
    // dispatch runs through the application object, and without touching it the
    // handler installed above is never given anything to handle.
    let app = NSApplication.shared
    app.finishLaunching()
    installLaunchEventHandlers()          // AFTER finishLaunching. See above.
    let deadline = Date().addingTimeInterval(budget)
    pumpAppKit(until: deadline, while: { urlRoom == nil && !sawLaunchEvent })
    return takeURLRoom()
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

  // ── THE JOIN WINDOW, REBUILT ON THE SAME SURFACE AS THE CALL ───────────────
  //
  // What was here was stock AppKit: a grey `NSTextField`, two `.rounded` bezel
  // buttons, `.inline` chips for the recents, and a camera preview bolted to the
  // top half as a separate box with a label over it. It worked, and it looked like
  // a preferences pane from a different decade of the platform -- while the call it
  // opens is a full-bleed picture with glass floating on it. Two screens, two
  // products, ten seconds apart.
  //
  // So it is the call window's own composition: your camera edge to edge, one
  // pane of glass floating on it holding everything you can do. Nothing here is a
  // new idea; it is the same three parts the waiting card already uses, which is
  // the point -- the join window should look like the thing it is the front door
  // to.
  static func askRoom() -> String? {
    // NSApplication FIRST, for the same reason the video path does it: AppKit
    // will happily build an NSWindow before the application object exists and
    // then behave as though the window belongs to nothing.
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let W: CGFloat = 560, H: CGFloat = 520
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                     styleMask: [.titled, .closable, .fullSizeContentView],
                     backing: .buffered, defer: false)
    w.title = "Kin"
    // Same treatment as the call window: the picture runs under the title bar and
    // only the traffic lights remain. A chrome band above a face is just a
    // smaller face, here as much as there.
    w.titlebarAppearsTransparent = true
    w.titleVisibility = .hidden
    w.backgroundColor = Palette.bg
    w.center()
    w.isReleasedWhenClosed = false

    let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
    v.wantsLayer = true

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
    let camBox = NSView(frame: v.bounds)
    camBox.autoresizingMask = [.width, .height]
    camBox.wantsLayer = true
    let host = CALayer()
    host.backgroundColor = Palette.bg.cgColor
    camBox.layer = host
    v.addSubview(camBox)

    // A dim over the picture, for the same reason the call window has one: the
    // glass below is clear-adjacent and the thing behind it is a face lit by
    // whatever is in the room. 35%, the HIG's number.
    let dim = CAGradientLayer()
    dim.frame = NSRect(x: 0, y: 0, width: W, height: H * 0.62)
    dim.startPoint = CGPoint(x: 0.5, y: 1)
    dim.endPoint = CGPoint(x: 0.5, y: 0)
    dim.colors = [NSColor.clear.cgColor, Palette.dim.cgColor]
    dim.autoresizingMask = [.layerWidthSizable]
    host.addSublayer(dim)

    // ── WHAT THE CAMERA IS DOING, IN A PILL ───────────────────────────────────
    //
    // This was a bare `NSTextField` centred over a black box. It is a pill now, in
    // the middle where the picture would be, so "Starting camera…" and "Camera
    // access is off" arrive as a statement about the picture rather than as a
    // caption floating in a void.
    let hintPill = Glass(radius: Metric.capsule(Metric.pillHeight), variant: .regular)
    let hint = NSTextField(labelWithString: "")
    hint.font = Type_.status
    hint.textColor = Palette.fg
    hint.alignment = .center
    hint.backgroundColor = .clear
    hint.isBordered = false
    func setHint(_ s: String) {
      hint.stringValue = s
      hintPill.isHidden = s.isEmpty
      hint.isHidden = s.isEmpty
      guard !s.isEmpty else { return }
      let tw = ceil((s as NSString).size(withAttributes: [.font: Type_.status]).width)
      let pw = tw + Metric.s8
      hintPill.frame = NSRect(x: (W - pw) / 2, y: H * 0.62, width: pw, height: Metric.pillHeight)
      hint.frame = NSRect(x: (W - pw) / 2, y: H * 0.62 + (Metric.pillHeight - 16) / 2,
                          width: pw, height: 16)
    }
    v.addSubview(hintPill)
    v.addSubview(hint)

    let session = AVCaptureSession()
    setHint("Starting camera…")

    // ── ONE PANE OF GLASS, HOLDING EVERYTHING YOU CAN DO ──────────────────────
    let recents = Array(recentRooms.prefix(4))
    let pad = Metric.cardPad
    // Every term is a thing on screen or the space above it, so the card is
    // exactly as tall as its contents and no taller. The first version reserved a
    // status line AND a recents gap with generous spacing on both, and the two
    // empty bands together left sixty points of nothing in the middle of the card.
    let statusH: CGFloat = 14
    let cardH: CGFloat = pad + 24 + Metric.s1 + 32 + Metric.s5 + Metric.fieldHeight
                       + Metric.s1 + statusH + (recents.isEmpty ? 0 : Metric.s2 + 24) + pad
    let cardW = W - Metric.gutter * 2
    let card = Glass(radius: Metric.cardRadius, variant: .regular)
    card.tint = Palette.glassTint
    card.frame = NSRect(x: Metric.gutter, y: Metric.gutter, width: cardW, height: cardH)
    v.addSubview(card)

    let title = NSTextField(labelWithString: "Join a call")
    title.font = Type_.title
    title.textColor = Palette.fg
    title.backgroundColor = .clear
    title.isBordered = false
    var cy = card.frame.maxY - pad - 24
    title.frame = NSRect(x: card.frame.minX + pad, y: cy, width: cardW - pad * 2, height: 24)
    v.addSubview(title)

    // Shorter than it was. The old copy ran to two dense lines about the name
    // being the encryption key AND the rendezvous AND the setup; all true, and
    // more than anyone reads standing in a doorway.
    // Plainer again. "the key" is the right idea in the wrong register for the
    // one screen a first-time user meets before anything else works; "password" is
    // the word everybody already has for a secret you both know.
    let sub = NSTextField(labelWithString: "Type the same word on both Macs. It is also the "
                        + "password, so pick something only you two would say.")
    sub.font = Type_.caption
    sub.textColor = Palette.muted
    sub.maximumNumberOfLines = 2
    sub.lineBreakMode = .byWordWrapping
    sub.backgroundColor = .clear
    sub.isBordered = false
    cy -= Metric.s1 + 32
    sub.frame = NSRect(x: card.frame.minX + pad, y: cy, width: cardW - pad * 2, height: 32)
    v.addSubview(sub)

    // The row: name, Suggest, Join. Vibrant fills, not glass -- this is INSIDE a
    // glass surface, and glass on glass is the one thing the guidance rules out.
    cy -= Metric.s5 + Metric.fieldHeight
    let joinW: CGFloat = 92, suggestW: CGFloat = 84
    let fieldW = cardW - pad * 2 - Metric.s2 * 2 - joinW - suggestW
    let fieldBack = Vibrant()
    fieldBack.radius = Metric.cardFieldRadius
    fieldBack.frame = NSRect(x: card.frame.minX + pad, y: cy,
                             width: fieldW, height: Metric.fieldHeight)
    v.addSubview(fieldBack)

    let field = NSTextField(frame: NSRect(x: fieldBack.frame.minX + Metric.s4,
                                          y: cy + (Metric.fieldHeight - 19) / 2,
                                          width: fieldW - Metric.s4 * 2, height: 19))
    // Not "room name". A room is this app's own plumbing, and this box is the
    // first thing a new person is asked to fill in.
    field.placeholderString = "a word you both know"
    field.stringValue = UserDefaults.standard.string(forKey: lastRoomKey) ?? suggestRoom()
    field.font = Type_.field
    field.textColor = Palette.fg
    field.backgroundColor = .clear
    field.drawsBackground = false
    field.isBordered = false
    field.focusRingType = .none
    v.addSubview(field)

    let newBtn = PillButton("Suggest")
    let join = PillButton("Join")
    join.prominent = true
    newBtn.setFrameSize(NSSize(width: suggestW, height: Metric.fieldHeight))
    join.setFrameSize(NSSize(width: joinW, height: Metric.fieldHeight))
    newBtn.setFrameOrigin(NSPoint(x: fieldBack.frame.maxX + Metric.s2, y: cy))
    join.setFrameOrigin(NSPoint(x: newBtn.frame.maxX + Metric.s2, y: cy))
    v.addSubview(newBtn)
    v.addSubview(join)

    // Validation messages. A reserved line, so saying something does not shove
    // the recents down and move a target under a finger already travelling.
    cy -= Metric.s1 + statusH
    let status = NSTextField(labelWithString: "")
    status.font = Type_.caption
    status.textColor = Palette.warn
    status.backgroundColor = .clear
    status.isBordered = false
    status.frame = NSRect(x: card.frame.minX + pad, y: cy, width: cardW - pad * 2, height: statusH)
    v.addSubview(status)

    // Camera-denied recovery, in the same pill language as everything else.
    let settingsButton = PillButton("Open Settings")
    settingsButton.setFrameSize(NSSize(width: 132, height: Metric.pillHeight))
    settingsButton.setFrameOrigin(NSPoint(x: (W - 132) / 2, y: H * 0.62 - Metric.s2 - Metric.pillHeight))
    settingsButton.isHidden = true
    settingsButton.onPress = {
      // The exact pane, not the top of Settings: "go and find it" is how a person
      // gives up on an app.
      if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
        NSWorkspace.shared.open(u)
      }
    }
    v.addSubview(settingsButton)

    func startPreview() {
      guard let dev = AVCaptureDevice.default(for: .video) ?? CameraSource.available().first,
            let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
        setHint("No camera found — this call will be audio only.")
        return
      }
      session.addInput(input)
      let pl = AVCaptureVideoPreviewLayer(session: session)
      pl.videoGravity = .resizeAspectFill
      pl.frame = CGRect(x: 0, y: 0, width: W, height: H)
      pl.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
      // BELOW the dim, or the gradient that keeps the glass legible ends up behind
      // the picture doing nothing.
      host.insertSublayer(pl, below: dim)
      setHint("")
      DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    // ── ASK FOR THE CAMERA, HERE, AND SAY WHAT HAPPENED ───────────────────────
    //
    // Starting a capture session prompts implicitly, and if the person does not
    // answer -- clicks away, misses it behind another window -- the session simply
    // never delivers a frame and the app shows black forever with no explanation.
    // That is exactly what happened: `notDetermined` on a machine where the app had
    // been opened repeatedly and the window was always empty, and the report was
    // the only true summary available -- "I still don't see the self view."
    //
    // So it is requested explicitly, at the moment the person is looking at the
    // window it is about, and each of the three outcomes says something different.
    CameraSource.requestAccess { access in
      DispatchQueue.main.async {
        switch access {
        case .granted:
          startPreview()
        case .denied:
          setHint("Camera access is off, so they will not see you.")
          settingsButton.isHidden = false
          fputs("camera: access DENIED -- the call will be audio only\n", stderr)
        case .restricted:
          setHint("Camera use is restricted on this Mac — audio only.")
          fputs("camera: access restricted by policy\n", stderr)
        }
      }
    }

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
    join.onPress = { t.go() }
    newBtn.onPress = { t.suggest() }
    // Return joins. `keyEquivalent` belonged to the NSButton this replaced, so the
    // field's own action carries it now -- and the field is where the Return is
    // actually pressed, which is one fewer thing to keep in agreement.
    field.target = t
    field.action = #selector(Target.go)

    // Rooms you have actually been in, one click each.
    if !recents.isEmpty {
      cy -= Metric.s2 + 24
      var x = card.frame.minX + pad
      for r in recents {
        let chip = PillButton(r)
        chip.setFrameSize(NSSize(width: min(160, chip.frame.width), height: 24))
        if x + chip.frame.width > card.frame.maxX - pad { break }
        chip.setFrameOrigin(NSPoint(x: x, y: cy))
        chip.onPress = { [weak t] in
          guard let t else { return }
          t.field.stringValue = r
          if let name = t.validate(r) { t.picked = name; t.done = true }
        }
        v.addSubview(chip)
        x += chip.frame.width + Metric.s2
      }
    }

    w.makeKeyAndOrderFront(nil)
    w.makeFirstResponder(field)
    app.activate(ignoringOtherApps: true)
    // The same line the call window prints, and for the same reason: a material is
    // composited by the window server, so the only capture that can see this
    // screen is one aimed at this window.
    fputs("window id \(w.windowNumber) -- screencapture -l \(w.windowNumber) -x out.png\n", stderr)

    // Drive the event loop by hand. `app.run()` would not return, and this window
    // has to finish before the audio graph, the sockets or the camera exist.
    // Same pump as everywhere else now; the exit condition is the only difference.
    pumpAppKit(until: .distantFuture, while: { !t.done && w.isVisible })
    t.done = true                                  // they joined, or they closed it
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
  /// `why` is not decoration. This replaces the running image, so everything the
  /// process knew about how it got here is gone one line later -- and a re-exec
  /// LOOP (five of them in nine seconds, each rebuilding the camera) looked in
  /// the log exactly like the app being launched five times by something else.
  /// Called immediately before the image is replaced, and whatever it returns is
  /// prepended to the new argv. `execv` is an ending as final as a hang-up -- the
  /// process stops existing on the next line -- and everything it had not yet
  /// reported dies with it. Measured: a ring answered inside five seconds
  /// reported NOTHING; not the ring, not the answer, not the button press.
  nonisolated(unsafe) static var beforeReexec: (() -> [String])?

  static func reexec(room: String, extra: [String], why: String = "unnamed") -> Never {
    let handoff = beforeReexec?() ?? []
    let me = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).path
    fputs("launch: pid \(getpid()) re-exec into \(room) -- \(why)"
        + " (argv was: \(CommandLine.arguments.dropFirst().joined(separator: " ")))\n", stderr)
    var args = [me, "--room", room] + handoff + extra
    // Carry through anything already on the command line, so `--gui` plus a flag
    // under test still behaves. But not a flag the line above already put there:
    // after the DMG self-install hands off with our own flags attached, the
    // original argv repeats what `extra` adds (seen: `--video camera --window
    // --window`). `arg()` takes the first occurrence, so a duplicate is harmless
    // today -- and a flag for which twice differs from once would break in
    // silence. Values are separate words in this CLI, so a dropped duplicate
    // takes its value token with it.
    var seen = Set(args.filter { $0.hasPrefix("--") })
    let carried = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < carried.count {
      let t = carried[i]; i += 1
      guard t.hasPrefix("--") else { args.append(t); continue }
      let value: String? = (i < carried.count && !carried[i].hasPrefix("--")) ? carried[i] : nil
      if value != nil { i += 1 }
      // ── FLAGS THAT MUST NOT SURVIVE A RE-EXEC ────────────────────────────
      //
      // `--gui` because the room has already been chosen. `--call` because the
      // ring has already been SENT: carrying it forward makes the new image dial
      // the same person again, re-exec again, and ring forever -- observed as two
      // rings a few seconds apart before this line existed, which would also have
      // burned the callee's rate limit and shown them a stack of missed calls
      // from somebody who pressed call once.
      //
      // `--incoming` for exactly the same reason one flag later: it is what tells
      // a fresh image "somebody is ringing you", and answering re-execs. Carried
      // forward, the new image re-arms the same ring, answers it again, and
      // re-execs again -- observed as five camera bring-ups in nine seconds, one
      // process changing its mind every second, with a window that flickered.
      // A ring is an event, not a state, and events do not survive their handler.
      // `--press`/`--press-after` because a press sequence belongs to the image
      // that was asked to run it. Carried forward, the successor replays the
      // whole sequence -- so a test that pressed `call` once placed a second
      // call from the new image, and a rig that double-fires is a rig that
      // cannot tell you whether the thing under test fired once.
      // `--calling` belongs to ONE image: the successor of the process that sent
      // the ring. If that image re-execs again -- answering somebody else, a
      // deferred update -- carrying it forward would put a "Calling @meera" card
      // over a call that has nothing to do with meera. Same rule as `--incoming`
      // one line up: a call being placed is an event, not a property of the room.
      if t == "--gui" || t == "--call" || t == "--incoming" || t == "--calling"
        || t == "--press" || t == "--press-after" || seen.contains(t) { continue }
      seen.insert(t)
      args.append(t)
      if let v = value { args.append(v) }
    }
    var c = args.map { strdup($0) }
    c.append(nil)
    execv(me, &c)
    // Only reached if execv failed, which means the binary moved underneath us.
    fputs("launch: could not re-exec \(me) (errno \(errno))\n", stderr)
    exit(1)
  }
}
