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
  /// True when this process was started by double-clicking the app rather than
  /// typed at a shell. The two want opposite defaults and always have: `tk` with
  /// no room is somebody measuring something, and a bundle launch with no room is
  /// somebody who wants to call a person.
  static var isBundleLaunch: Bool {
    (Bundle.main.executableURL?.path ?? CommandLine.arguments[0]).contains("/Contents/MacOS/")
  }

  static func shouldPrompt(hasRoom: Bool, hasPeer: Bool, forced: Bool) -> Bool {
    if forced { return true }
    // ── THE FRONT DOOR IS THE DEFAULT FOR A DOUBLE-CLICK ──────────────────────
    //
    // This was `forced` alone, so the only way to reach the app's own first
    // screen was `--gui` from a terminal. Opening Kin normally minted a room and
    // walked into an empty call (see the `awaitURLRoom` block in main.swift).
    // Nothing about the command line changes: `tk` with no arguments still does
    // what it did, because a shell is not a double-click.
    guard !hasRoom, !hasPeer else { return false }
    return isBundleLaunch
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

  /// The one thing a denied camera can offer: the pane that undoes it. A class
  /// because a gesture recognizer needs an objc target that outlives the closure
  /// it was born in.
  final class RevealCamera: NSObject {
    static let shared = RevealCamera()
    @objc func go() { Permissions.reveal(.camera) }
  }

  /// The room inside a call link, or nil for text that is not one. One parser
  /// for every place a link can arrive as TEXT -- typed into the field, sitting
  /// on the clipboard -- with the same shapes the Apple Event handler below
  /// accepts: tokkah://join/<room>, tokkah://<room>, kin://…, and the https
  /// links people actually send each other (kin.tokkah.com/<room>,
  /// room.tokkah.com/<room>, with or without the scheme typed).
  static func roomFromLink(_ s: String) -> String? {
    let raw = s.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = raw.lowercased()
    guard lower.contains("://") || lower.contains("tokkah.com") else { return nil }
    guard let u = URL(string: raw.contains("://") ? raw : "https://" + raw) else { return nil }
    var name = u.path.hasPrefix("/") ? String(u.path.dropFirst()) : u.path
    if u.scheme == "tokkah" || u.scheme == "kin" {
      if name.isEmpty { name = u.host ?? "" }
      if name == "join" { name = "" }
    } else {
      guard let h = u.host?.lowercased(), h == "tokkah.com" || h.hasSuffix(".tokkah.com")
      else { return nil }
    }
    let ok = !name.isEmpty && name.count <= 64
      && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    return ok ? name : nil
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
  /// What somebody decided at the front door. Three answers, and a `String?`
  /// could only carry two of them: "the room is called meera" and "we are ringing
  /// meera" are different facts and must not be able to become the same value.
  enum Intent {
    /// Join this room. Nobody has been told; whoever else turns up, turns up.
    case room(String)
    /// The ring has ALREADY BEEN SENT to `who`, and it named `room`. `away` is the
    /// server saying their Mac had stopped polling -- not a no, just the only
    /// thing anybody can honestly say about whether they are there.
    case calling(room: String, who: String, away: Bool)
    /// Walk back into a call this Mac was in and did not leave cleanly. Carries
    /// the whole record, not just the room: the port, the peer's last address and
    /// the chain field all have to come back or the "rejoin" is a NEW call that
    /// merely has the same name (`a-final-record-that-isnt-final`).
    case resume(Resume.Live)
  }

  /// Which of the three things this card is currently for. One value, because two
  /// booleans that have to agree are a state that can be both -- the bug
  /// `WaitingCard.Mode` was extracted to fix, in the same shape, one screen away.

  /// Set when the front door has stopped its preview session and detached its
  /// inputs. Read by the in-process path, which is the only caller that cannot
  /// rely on `execv` to do this for it.
  nonisolated(unsafe) private(set) static var cameraReleased = false

  /// Say so, loudly, before the call opens the device. A camera still held here
  /// surfaces as "camera: not permitted" or a session that never delivers a
  /// frame, hundreds of lines away, with nothing pointing back at this decision --
  /// and "the picture never came up" is indistinguishable from a denied grant.
  static func assertCameraReleased() {
    fputs(cameraReleased
            ? "launch: front-door camera released before the call opens it\n"
            : "launch: WARNING -- the front door never released its camera, and the"
              + " call is about to open the same device in the same process\n",
          stderr)
  }

  /// `resume` is a call this Mac was in and did not leave cleanly, which the
  /// launch path has already confirmed still has somebody in it. It is offered as
  /// a row rather than walked into, because walking into it is what opening the
  /// app used to do about everything.
  static func home(resume: Resume.Live? = nil) -> Intent? {
    // NSApplication FIRST, for the same reason the video path does it: AppKit
    // will happily build an NSWindow before the application object exists and
    // then behave as though the window belongs to nothing.
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    // ── TALLER, BECAUSE THE CARD GREW A LIST ─────────────────────────────────
    //
    // 520 was right for a card holding one field and a row of chips. The card now
    // holds up to five faces and, photographed at 520, it stood 390 points tall in
    // a 520 point window -- so the camera preview it floats over was a 110 point
    // strip showing the top of somebody's head. A pane of glass over a face is the
    // composition; a pane of glass with a face peeking out above it is a dialog.
    let W: CGFloat = 560, H: CGFloat = 660
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

    // ── AND NOTHING OVER THE PICTURE ─────────────────────────────────────────
    //
    // A `CAGradientLayer` ran up 62% of this window at 35%, so the first thing
    // anybody ever saw of themselves in this app was their own face fading into
    // the dark at the bottom. Deleted with the two in the call window and for the
    // same reason: the dimming a control needs belongs inside that control, and
    // `joinCard` and `hintPill` below both carry theirs. See the note beside the
    // scrims in `CallControls.init`.

    // ── WHAT THE CAMERA IS DOING, IN A PILL ───────────────────────────────────
    //
    // This was a bare `NSTextField` centred over a black box. It is a pill now, in
    // the middle where the picture would be, so "Starting camera…" and "Camera
    // access is off" arrive as a statement about the picture rather than as a
    // caption floating in a void.
    // It sits at the TOP edge of the gradient above, where the gradient is still
    // transparent, so it gets no help from it and carries its own dim.
    let hintPill = Glass("hintPill", radius: Metric.capsule(Metric.pillHeight))
    // ── WHERE THE PILL SITS DEPENDS ON HOW TALL THE CARD IS ──────────────────
    //
    // This was `H * 0.62`, a fraction of the window, chosen when the card below it
    // had one fixed height. The card has three heights now, and the tallest of
    // them reached past 0.62 -- so the sentence about the camera would have been
    // read through the pane of glass in front of it. Set from the card's own
    // `maxY` in `relayout` instead; a constant here is a constant that has to be
    // re-checked every time a row is added below.
    var hintY = H * 0.62
    let hint = NSTextField(labelWithString: "")
    hint.font = Type_.status
    hint.textColor = Palette.fg
    hint.alignment = .center
    hint.backgroundColor = .clear
    hint.isBordered = false
    // `measuring` is the widest string this pill is about to show, when that is
    // not the string itself: the ringing ellipsis retitles the pill four times a
    // second, and a pill sized to each frame grows and shrinks around a fixed
    // centre -- the sentence would breathe. Sized once to the longest frame, only
    // the dots move.
    func setHint(_ s: String, measuring: String? = nil) {
      hint.stringValue = s
      hintPill.isHidden = s.isEmpty
      hint.isHidden = s.isEmpty
      guard !s.isEmpty else { return }
      let tw = ceil(((measuring ?? s) as NSString)
                      .size(withAttributes: [.font: Type_.status]).width)
      let pw = tw + Metric.s8
      hintPill.frame = NSRect(x: (W - pw) / 2, y: hintY, width: pw, height: Metric.pillHeight)
      hint.frame = NSRect(x: (W - pw) / 2, y: hintY + (Metric.pillHeight - 16) / 2,
                          width: pw, height: 16)
    }
    v.addSubview(hintPill)
    v.addSubview(hint)

    let session = AVCaptureSession()
    setHint("Starting camera…")

    // ── THE CAMERA, WHICH THIS SENTENCE STOPPED BEING TRUE ABOUT ─────────────
    //
    // The 0.103.0 home-screen rebuild deleted `startPreview()` and the access
    // request while KEEPING the session object, its teardown, and the pill above
    // -- so from 0.103 to 0.110 every front door in the field said "Starting
    // camera…" over black, forever, and nothing looked broken because the
    // sentence claims work is in progress. `dead-controls-declared-never-wired`,
    // except the dead thing was the narration: a hint describing work no code
    // performs is worse than no hint, because it converts "the camera is
    // missing" into "the camera is coming".
    //
    // Restored from the pre-0.103 join screen, verbatim where possible. The
    // preview is the CONTENT of this window -- your own face, instantly, which
    // is both the proof the camera works and the thing that makes this a video
    // app rather than a settings dialog. Everything else floats above it.
    func startPreview() {
      guard let dev = AVCaptureDevice.default(for: .video) ?? CameraSource.available().first,
            let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
        setHint("No camera found — this call will be audio only.")
        fputs("camera: none found\n", stderr)
        return
      }
      session.addInput(input)
      let pl = AVCaptureVideoPreviewLayer(session: session)
      pl.videoGravity = .resizeAspectFill
      pl.frame = CGRect(x: 0, y: 0, width: W, height: H)
      pl.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
      // At index 0: everything else in the window floats above the picture.
      host.insertSublayer(pl, at: 0)
      // The pill goes quiet the moment the session actually delivers -- not when
      // startRunning is CALLED, which returns before the first frame. A KVO on
      // `running` would still be early; the first video frame is the only honest
      // "started". `isRunning` polled once after start is the cheap version that
      // cannot hang the main thread.
      DispatchQueue.global(qos: .userInitiated).async {
        session.startRunning()
        DispatchQueue.main.async {
          if session.isRunning {
            setHint("")
            // The resolution line the rig asserts on: every launch must end the
            // "Starting camera…" sentence in one of four recorded ways, because
            // the 0.103 regression was precisely a launch that never did.
            fputs("camera: preview running (\(dev.localizedName))\n", stderr)
          } else {
            setHint("The camera did not start — this call will be audio only.")
            fputs("camera: session refused to run\n", stderr)
          }
        }
      }
    }

    // ── ASK FOR THE CAMERA, HERE, AND SAY WHAT HAPPENED ───────────────────────
    //
    // Starting a capture session prompts implicitly, and if the person does not
    // answer -- clicks away, misses it behind another window -- the session
    // simply never delivers a frame and the app shows black forever with no
    // explanation. So it is requested explicitly, at the moment the person is
    // looking at the window it is about, and each outcome says something
    // different. A denial also OPENS the pane that can fix it, one click, via
    // the same reveal every other permission uses.
    CameraSource.requestAccess { access in
      DispatchQueue.main.async {
        switch access {
        case .granted:
          startPreview()
        case .denied:
          // The sentence claims a click works, so a click MUST work -- the first
          // draft of this line said "click here" with nothing wired to the
          // click, in the same commit that diagnosed five releases of a pill
          // narrating work no code performed. The recognizer rides the pill
          // itself, so wherever `setHint` moves it, the target moves with it.
          setHint("Camera access is off — click here to turn it on.")
          let click = NSClickGestureRecognizer(target: Launcher.RevealCamera.shared,
                                               action: #selector(Launcher.RevealCamera.go))
          hintPill.addGestureRecognizer(click)
          fputs("camera: access DENIED -- the front door shows no preview\n", stderr)
        case .restricted:
          setHint("Camera use is restricted on this Mac — audio only.")
          fputs("camera: access restricted by policy\n", stderr)
        }
      }
    }

    w.contentView = v

    // ── ONE PANE OF GLASS, AND ON IT THE PEOPLE ───────────────────────────────
    //
    // What was here was a room name. A text field reading "a word you both know",
    // a Suggest button, a Join button, and under them four chips of rooms you had
    // been in -- and that was the whole front door of an app whose stated goal is
    // "tap a name to call someone you have called before".
    //
    // The people were not missing. `Identity.contactHandles()` had them, and
    // `ContactRow` drew them, and tapping one already placed a call. They were
    // just somewhere nobody would ever look: INSIDE a call, behind the peek
    // button, on the second page of the more sheet. To ring somebody you had
    // spoken to yesterday you opened the app, typed a room name at it, waited for
    // a call to start with nobody in it, opened a sheet, went to a second page,
    // and tapped their face. Every one of those steps worked perfectly.
    //
    // So the list comes to the front door and the room name goes behind a row.
    // The ordering is the whole change and it is not a preference: a name is what
    // you have when you want to talk to a PERSON, and a shared secret word is what
    // you have when you want to talk to a STRANGER. The second is rarer, so it is
    // one click further away, and it is still exactly where it was for anybody who
    // needs it.
    //
    // Three things you can do here, and the card is only ever showing one of them:
    //
    //   .people   the faces. The default, whenever there is at least one.
    //   .name     a field for a handle you were told out loud but have not called.
    //   .word     the old room field, Suggest and Join, unchanged.
    //
    // One `mode` decides which, for the reason `WaitingCard` gives about its own:
    // this began as two booleans that had to agree, and two booleans that have to
    // agree are a state that can be both.
    // By recency, not by alphabet: the person you talked to yesterday is the
    // person you are most likely opening the app to reach, and burying them
    // under whoever's name starts with 'a' is the list optimising for a phone
    // book nobody is reading top to bottom.
    let people = Array(Identity.contactHandlesByRecency().prefix(5))
    let pad = Metric.cardPad
    let cardW = W - Metric.gutter * 2
    let rowW = cardW - pad * 2
    let card = Glass("joinCard", radius: Metric.cardRadius)
    v.addSubview(card)

    // ── THE ONE EDITABLE THING, ONCE ──────────────────────────────────────────
    //
    // This was TWO fields behind two rows and two modes -- "Call someone new"
    // opened a handle field, "Join with a word" opened the old room field with
    // Suggest and Join and the recent-room rows, each with a title, a sentence,
    // and a Back row. Four clicks of furniture for one question: WHO. So it is
    // one field now, always on screen, and what you put in it decides what it
    // does: a name rings them, a pasted call link joins it, and a word with a
    // `-` or `_` in it (every suggested room, and no legal handle) joins as a
    // room. The distinction the two fields guarded -- a handle may not contain
    // `-` or `_`, a room may -- is exactly what makes one field unambiguous.
    func vibrant(_ h: CGFloat) -> Vibrant {
      let b = Vibrant()
      b.radius = Metric.cardFieldRadius
      b.setFrameSize(NSSize(width: 0, height: h))
      return b
    }
    func plainField(_ placeholder: String, _ value: String) -> NSTextField {
      let f = NSTextField()
      f.placeholderString = placeholder
      f.stringValue = value
      f.font = Type_.field
      f.textColor = Palette.fg
      f.backgroundColor = .clear
      f.drawsBackground = false
      f.isBordered = false
      f.focusRingType = .none
      return f
    }

    let fieldBack = vibrant(Metric.fieldHeight)
    // Not "or paste a call link": a call link opens Kin by itself -- it is a
    // registered scheme and clicking one in a message walks straight into the
    // room. Telling somebody to copy a link out of a message and paste it into a
    // box is asking them to do by hand what the link already does.
    let field = plainField("Type a handle, like meera", "")
    for x in [fieldBack, field] as [NSView] { v.addSubview(x) }

    // Validation, on a line that is always reserved. Saying something must not
    // shove the rows below it down and move a target under a pointer already
    // travelling towards one.
    let statusH: CGFloat = 14
    let status = NSTextField(labelWithString: "")
    status.font = Type_.caption
    status.textColor = Palette.warn
    status.backgroundColor = .clear
    status.isBordered = false
    v.addSubview(status)

    let peopleRows = people.map { ContactRow(handle: $0) }
    // "yesterday" on the row, so the order explains itself. `valueIsWord` is the
    // muted small rendering the mine-row's "copy" already uses; these labels are
    // not pressable and draw exactly like every other secondary word here.
    let lastTimes = Identity.lastCallTimes()
    for r in peopleRows {
      if let t = lastTimes[r.handleName] {
        r.value = Relative.time(t)
        r.valueIsWord = true
      }
    }
    // ── THE GREEN DOTS, REFRESHED WHILE THE WINDOW IS OPEN ───────────────────
    //
    // Asked once now and every 15 s after -- the same cadence a held poll makes
    // meaningful -- and it paints dots only. It must never reorder: the order
    // was fixed above, and a row that moves under a travelling pointer is how a
    // stray click rings the wrong person. The timer rides `.common` so a menu
    // being open does not freeze the dots, and it dies with the window.
    var presenceTimer: Timer?
    if !people.isEmpty {
      let apply: () -> Void = {
        Presence.fetch(people) { map in
          for r in peopleRows { r.reachable = map[r.handleName] }
        }
      }
      apply()
      let t = Timer(timeInterval: 15, repeats: true) { _ in apply() }
      RunLoop.main.add(t, forMode: .common)
      presenceTimer = t
    }
    // ── A LINK ON THE CLIPBOARD IS A KNOCK ON THE DOOR ───────────────────────
    //
    // The way a call link actually arrives is a message: somebody sends it, you
    // copy it, you open Kin. The old answer was four clicks of furniture --
    // "Join with a word", a field, paste, Join. If the clipboard is holding a
    // call link when this window is up, the join is ONE row at the top of the
    // card, and the row says which room so a stale clipboard cannot walk you
    // into last week's call unannounced. Refreshed when the app comes forward,
    // which is the moment the copy could have changed.
    let linkRow = SheetRow("")
    linkRow.value = "from your copied link"
    linkRow.valueIsWord = true
    // ── A LINK TO HAND SOMEBODY, WITHOUT STARTING A CALL FIRST ───────────────
    //
    // The only way to invite a person who is not in the list was to start a call
    // and copy the link off the waiting screen -- so you sat alone in a room with
    // your camera on in order to get a URL. This mints the room and copies the
    // link here, and nothing opens until somebody arrives.
    let inviteRow = SheetRow("Copy a link to invite someone")
    inviteRow.value = "copy"
    inviteRow.valueIsWord = true
    inviteRow.textInset = Metric.rowAvatarInset
    // ── AND THE CALL THAT NEVER PROPERLY ENDED ───────────────────────────────
    //
    // A Mac that lost wifi, slept, or was closed the wrong way leaves a live
    // room with somebody still sitting in it. The launch path only walked back
    // in when it happened within 90 s; past that, the record was checked against
    // the room directory and then nothing was done with the answer that a person
    // could see. This is that answer, as a row.
    let resumeRow = SheetRow(resume.map { "Rejoin \($0.room)" } ?? "")
    resumeRow.value = "still going"
    resumeRow.valueIsWord = true
    resumeRow.textInset = Metric.rowAvatarInset
    // Your own name, and the one state that gets a sentence instead of a control:
    // a copy button over an empty value copies nothing, reports success, and
    // teaches the person the feature is broken. Same rule as the People page.
    let mineRow = ContactRow(handle: Identity.handle)
    mineRow.value = "copy"
    mineRow.valueIsWord = true
    mineRow.ruled = true
    let mineHint = SheetHint(Identity.handle.isEmpty ? Identity.nameTroubleLine
                                                     : "Give this to someone and they can call you.")
    let emptyHint = SheetHint("Talk to someone once and they’ll show up here.")
    // ── THE HALF OF "TAP A NAME TO CALL" THAT REACHED NOBODY ─────────────────
    //
    // Ringing a Mac whose app is closed is fully built -- a LaunchAgent, a poller,
    // a spawn, a card, all of it tested. The only way to turn it on is
    // `--watch-install` in a terminal, and the app has never mentioned it. So for
    // everybody who will not open a terminal, which is everybody, half of "call
    // someone by tapping their name" does not exist: you can ring them, and they
    // can only ever ring you back while your app happens to be open.
    //
    // Building it and making it happen are separate pieces of work and only the
    // first one feels like the feature. This row is the second one.
    //
    // IT ASKS. A login item is a persistent change to somebody's Mac and it is not
    // ours to make quietly because we think it is good for them -- the row says
    // what it does, in the sentence under it, and nothing happens until it is
    // pressed. `healthy()` and not `installed`: the plist FILE existing is not the
    // question, because one `launchctl bootout` leaves the file in place and the
    // Mac uncallable for ever while every launch decides there is nothing to do.
    var watchOK = Watch.healthy()
    let reachRow = SheetRow(watchOK ? "People can reach you when Kin is closed"
                                    : "Let people reach you when Kin is closed")
    let reachHint = SheetHint("Kin starts when you log in, just to listen for calls.")
    if watchOK { reachRow.value = "on"; reachRow.valueIsWord = true; reachRow.inert = true }
    reachRow.textInset = Metric.rowAvatarInset
    v.addSubview(reachRow)
    v.addSubview(reachHint)
    // Silent mode, from the same server switch the in-call sheet flips. The row
    // shows the SERVER's verdict, never the wish -- `setQuiet` only moves local
    // state when the server agreed, so "on" here is true unreachability.
    let quietRow = SheetRow("Don’t ring me")
    let quietHint = SheetHint("Calls to you are quietly declined until you turn this off.")
    quietRow.value = Identity.quietOn ? "on" : "off"
    quietRow.valueIsWord = true
    quietRow.textInset = Metric.rowAvatarInset
    v.addSubview(quietRow)
    v.addSubview(quietHint)
    // ── THE FURNITURE GOES BEHIND ONE BUTTON ─────────────────────────────────
    //
    // Your own handle, the login item, silent mode: all three are ABOUT you and
    // none of them is why the window is open. On the front card they sat under
    // the people list and pushed the card up over the camera picture -- the
    // person's own face, hidden behind settings. The same corner `…` the call
    // window has opens them; the card everybody actually uses is faces and one
    // field.
    let moreBtn = IconButton(Glyph.more, size: Metric.controlSmall, help: "settings")
    v.addSubview(moreBtn)
    for r in peopleRows { v.addSubview(r) }
    for x in [linkRow, inviteRow, resumeRow, mineRow] as [NSView] { v.addSubview(x) }
    v.addSubview(mineHint)
    v.addSubview(emptyHint)
    // `linkRow` carries no glyph column of its own beside a list of 34 pt faces --
    // a page of faces has a 56 pt mark column and an ordinary row an 18 pt one,
    // and the two together draw a ragged left edge that reads as two lists that
    // happen to be adjacent. Same fix as `buildPeoplePage`.
    linkRow.textInset = Metric.rowAvatarInset
    // ── A CLICK THAT ARRIVES BEFORE YOU ARE LOOKING AT THIS WINDOW IS NOT A
    //    DECISION TO RING ANYBODY ─────────────────────────────────────────────
    //
    // This window activates itself and opens centred, so it lands under whatever
    // the pointer was already over. Every row here either reaches another person
    // or changes this Mac, and none of them is worth firing on the click that
    // merely brought the app forward -- which is exactly why AppKit's default is
    // false and why `SheetRow` overriding it to true is right for the call bar and
    // wrong here. Observed, before this line: an app launch put the list under a
    // resting pointer and the next click rang @arjun.
    for r in peopleRows { r.acceptsFirstClick = false }
    for r in [linkRow, inviteRow, resumeRow, mineRow, reachRow] { r.acceptsFirstClick = false }

    // ── WHAT THIS WINDOW IS FOR, IN ONE VALUE ─────────────────────────────────
    //
    // The old target answered one question -- "did they press Join, and with what
    // text". There are three answers now and only a type can keep them apart: a
    // room to join, a person already being rung, or nothing because the window was
    // closed. Returning a `String?` for all three is what would let "the room is
    // called meera" and "we are ringing meera" become the same value.
    final class Target: NSObject {
      var out: Intent?
      var done = false
      /// A ring is in flight. ONE FLAG, guarded in every path that could start a
      /// second one -- clicking a second face while the first ring is travelling
      /// would leave two minted rooms, and the person would be told about one of
      /// them. `PillButton` is a plain `NSView` with an `onPress` and has no
      /// `isEnabled` to turn off, so the refusal lives here rather than in six
      /// places that each have to remember to switch back on.
      var ringing = false
      /// Bumped by every cancel. The ring's completion carries the value it
      /// started with and drops itself if they differ -- the POST is already gone
      /// and cannot be recalled, so "cancel" can only mean that THIS process stops
      /// acting on the answer. Without it, Esc would clear the pill and the
      /// window would re-exec into the room half a second later anyway
      /// (`a-final-record-that-isnt-final`, from the other side).
      var ringGen = 0
      /// False while the ring POST is travelling. The teardown paths wait on it:
      /// an exit that outruns the POST cannot know whether anybody was rung, and
      /// so cannot know whether anybody needs un-ringing.
      var ringSettled = true
      /// A bye is on its way to the mailbox. Exit waits for this too -- a bye
      /// believed-sent by a process that quit first was never sent.
      var byeInFlight = false
      /// The two-second revert on the mine-row's "copied". Held so teardown can
      /// kill it: a timer holding a row of a window that has gone away.
      var copyTimer: Timer?
      /// Put the screen back the way it was before the ring. Owned by `home()`,
      /// which is where the pill, the rows and the dots timer all live.
      var stopRing: () -> Void = {}
      /// The settings card is open: your handle, the login item, silent mode.
      var settingsOpen = false
      var toggleQuiet: () -> Void = {}
      @objc func settings() {
        guard !ringing else { return }
        settingsOpen.toggle()
        fputs("home: settings \(settingsOpen ? "open" : "closed")\n", stderr)
        relayout()
      }
      @objc func quietPressed() { guard !ringing else { return }; toggleQuiet() }
      let field: NSTextField
      let status: NSTextField
      /// The room parsed off the clipboard, when the clipboard holds a call link.
      /// The row that joins it shows this same value, so what fires is what was
      /// on screen -- never a re-read of a clipboard that changed under the click.
      var clipRoom: String?
      /// Minted when the pointer arrives on a face, used when the click lands.
      /// One per handle: hovering across a list five times must not mint five
      /// rooms and warm all of them.
      var warmed: [String: String] = [:]
      var relayout: () -> Void = {}
      var ring: (String) -> Void = { _ in }
      /// Turn on the login item. A closure rather than a method body because the
      /// row it reports into is built outside this class.
      var makeReachable: () -> Void = {}
      init(field: NSTextField, status: NSTextField) {
        self.field = field; self.status = status
      }

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

      /// A face was clicked. Everything after this is the ring, and the room is the
      /// one that was minted and warmed when the pointer arrived.
      @objc func callRow(_ sender: SheetRow) {
        guard !ringing, let row = sender as? ContactRow else { return }
        ring(row.handleName)
      }
      /// Return in the one field. What was typed decides what happens: a call
      /// link joins its room, a word with `-` or `_` (every suggested room, and
      /// no legal handle) joins as a room, and anything else is a name to ring.
      @objc func commit() {
        guard !ringing else { return }
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { status.stringValue = "Type a name, or paste a call link."; return }
        if let room = Launcher.roomFromLink(raw) {
          out = .room(room); done = true; return
        }
        if raw.contains("-") || raw.contains("_") {
          guard let name = validate(raw) else { return }
          out = .room(name); done = true; return
        }
        let bare = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
        guard let who = Identity.sanitize(bare) else {
          // The server's rule, said in words rather than as a regex.
          status.stringValue = "Names are letters and numbers, starting with a letter."
          return
        }
        status.stringValue = ""
        ring(who)
      }
      /// The clipboard row. Joins the room the ROW names -- `clipRoom`, parsed
      /// when the row was shown -- not a re-read of the clipboard now.
      @objc func joinClip() {
        guard !ringing, let room = clipRoom else { return }
        out = .room(room); done = true
      }
      /// Mint a room, put its link on the clipboard, and stay on this screen.
      /// Nothing is joined: the person is getting a link to send, and opening a
      /// call to produce one is what this row exists to stop.
      var invited: String?
      var inviteTimer: Timer?
      @objc func copyInvite(_ sender: SheetRow) {
        guard !ringing else { return }
        // One room per visit to this screen. Pressing copy twice must hand out
        // the same link, or the second press quietly invalidates the invitation
        // already sent with the first.
        let room = invited ?? Launcher.mintRoom()
        invited = room
        NSPasteboard.general.clearContents()
        // `roomURL`, not a second copy of it: a minted room and a named one take
        // different link shapes, and the named one 404s if you get it wrong.
        NSPasteboard.general.setString(roomURL(room), forType: .string)
        // Warmed now: the link is out in the world and the room's first request
        // is the ~1100 ms one.
        Warm.room(room, why: "invite copied")
        sender.setLabel("Link copied — send it to anyone")
        sender.value = room
        inviteTimer?.invalidate()
        let t = Timer(timeInterval: 4, repeats: false) { [weak sender] _ in
          sender?.setLabel("Copy a link to invite someone")
          sender?.value = "copy"
        }
        RunLoop.main.add(t, forMode: .common)
        inviteTimer = t
        fputs("home: invite link copied for \(room)\n", stderr)
      }
      /// Walk back into the call that never ended. The whole record travels, not
      /// just the room -- see `Intent.resume`.
      var resumable: Resume.Live?
      @objc func rejoin() {
        guard !ringing, let l = resumable else { return }
        out = .resume(l); done = true
      }
      @objc func copyMine(_ sender: SheetRow) {
        guard let row = sender as? ContactRow, !row.handleName.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("@" + row.handleName, forType: .string)
        row.value = "copied"
        // And back to "copy" after two seconds, the same revert `WaitingCard`'s
        // confirmation uses. A row that says "copied" for the rest of the session
        // stops being a button you can press again: the word is a receipt for one
        // press, and left standing it reads as a state.
        copyTimer?.invalidate()
        let t = Timer(timeInterval: 2, repeats: false) { [weak row] _ in row?.value = "copy" }
        RunLoop.main.add(t, forMode: .common)
        copyTimer = t
      }
      @objc func reachable() { guard !ringing else { return }; makeReachable() }
      @objc func cancel() { done = true }
    }
    let t = Target(field: field, status: status)
    // The one screen. There used to be three (`people`, `name`, `word`) with a
    // Back row between them; the one field made the other two redundant. The log
    // line keeps its old shape because the rig greps for it.
    fputs("home: mode people\(people.isEmpty ? " (empty)" : "") -- \(people.count) people\n",
          stderr)

    // ── PLACING THE CALL FROM HERE, AND NOT ONE PROCESS LATER ────────────────
    //
    // The obvious build is to return the name and let the call image ring them.
    // It costs a SECOND re-exec: the image would come up, dial, mint a room, ring,
    // and re-exec again into that room -- two process starts and two camera
    // bring-ups (~670 ms cold each, and the camera is a platform floor) for one
    // click. The ring is one signed HTTPS round trip and this window is already
    // running a run loop, so it happens here and the window re-execs straight into
    // the room it just made.
    //
    // Off the main thread, because signing and an HTTPS round trip on the thread
    // that draws is a window that stops repainting the moment you click a face.
    // The hint pill -- already on screen, already the place this window says what
    // it is doing -- carries the news, so there is no second "calling" surface to
    // drift out of agreement with `WaitingCard`'s.
    // ── AND WHILE IT IS TRAVELLING, SOMETHING THAT IS OBVIOUSLY ALIVE ────────
    //
    // The ring used to change the pill once, disable every control, and offer no
    // way back: a frozen app shows its last caption perfectly, so "Calling
    // Meera…" over a still screen is the same photograph as a crash. Three things
    // fix it and they are one state: a moving ellipsis, the clicked row held lit
    // while the rest of the list steps back, and Esc.
    //
    // A timer retitling the pill rather than `WaitingCard`'s three animated
    // layers: that card is sized to its widest child and could not afford text
    // that grows: this pill is measured once (see `setHint(measuring:)`) and can.
    var dotTimer: Timer?
    var hintBefore = ""
    let dimOthers: (String?) -> Void = { who in
      for r in peopleRows {
        r.forcedActive = who != nil && r.handleName == who
        // The list does not vanish, it recedes: the one row you chose stays at
        // full strength and everything else drops back, so the screen says which
        // name is in flight without a second surface saying it.
        r.alphaValue = (who == nil || r.handleName == who) ? 1 : 0.4
      }
      for r in [linkRow, mineRow, reachRow] as [NSView] {
        r.alphaValue = who == nil ? 1 : 0.4
      }
      fieldBack.alphaValue = who == nil ? 1 : 0.4
      field.alphaValue = who == nil ? 1 : 0.4
    }
    t.stopRing = { [weak t] in
      guard let t, t.ringing else { return }
      // The POST may already be gone. All this can do is make sure its answer is
      // ignored -- see `ringGen`.
      t.ringGen &+= 1
      t.ringing = false
      dotTimer?.invalidate(); dotTimer = nil
      dimOthers(nil)
      setHint(hintBefore)
      fputs("home: ring cancelled by esc\n", stderr)
    }
    t.ring = { [weak t] who in
      guard let t, !t.done, !t.ringing else { return }
      t.ringing = true
      t.ringSettled = false
      let gen = t.ringGen
      let room = t.warmed[who] ?? Launcher.mintRoom()
      hintBefore = hint.isHidden ? "" : hint.stringValue
      dimOthers(who)
      // "esc to cancel" rides the pill rather than a second line: the pill is
      // already the one place this window narrates itself, and a way out nobody
      // is told about is not a way out.
      let base = "Calling \(Identity.display(who))"
      let tail = "   ·   esc to cancel"
      let frames = ["", ".", "..", "…"]
      // Measured against the widest frame, so only the dots move.
      let widest = base + ".." + tail
      setHint(base + "…" + tail, measuring: widest)
      if !Motion.reduceMotion {
        var i = 0
        let d = Timer(timeInterval: 0.4, repeats: true) { _ in
          i = (i + 1) % frames.count
          setHint(base + frames[i] + tail, measuring: widest)
        }
        RunLoop.main.add(d, forMode: .common)
        dotTimer = d
      }
      Thread {
        Metrics.count("ring_sent_try")
        let got = Identity.ring(to: who, room: room)
        let listening = Identity.lastRingListening
        DispatchQueue.main.async {
          t.ringSettled = true
          // Cancelled while this was in flight. Not an error and not a call: the
          // window is back where it was and nothing here may touch it -- EXCEPT
          // that if the ring landed, the other Mac is ringing for a call nobody
          // is placing any more, and only this branch knows both facts. The
          // un-ring is sent from here, never from the cancel itself: a bye that
          // races its own ring and arrives first is a no-op, and the ring then
          // rings out the whole lease anyway (`held-is-a-one-way-door`, the
          // ordering half).
          guard t.ringGen == gen else {
            Metrics.count("ring_cancelled")
            if got != nil {
              t.byeInFlight = true
              sendBye(to: who, room: room, why: "cancelled-at-door") {
                DispatchQueue.main.async { t.byeInFlight = false }
              }
            }
            return
          }
          dotTimer?.invalidate(); dotTimer = nil
          dimOthers(nil)
          guard let got else {
            Metrics.count("ring_sent_fail")
            // Honest and vague on purpose: a 200 means the ring is in their
            // mailbox, anything else means we could not put it there. Neither says
            // whether they are awake.
            setHint("Couldn’t reach \(Identity.display(who)) — check the name, and try again.")
            t.ringing = false
            return
          }
          Metrics.count("ring_sent_ok")
          Metrics.fact("callee_listening", listening.map { $0 ? "yes" : "no" } ?? "unknown")
          // The ring is no longer in flight; the call is. Left true, the teardown
          // below reads a SUCCESSFUL ring as an abandoned one and says so in the
          // log of every call this window ever places.
          t.ringing = false
          t.out = .calling(room: got, who: who, away: listening == false)
          t.done = true
        }
      }.start()
    }

    // ── ONE PLACE THAT DECIDES WHERE EVERYTHING IS ───────────────────────────
    //
    // Three modes with three different card heights, and the alternative to this
    // function is three copies of the arithmetic that have to agree about the
    // padding. Rows are laid out by walking a list top-down rather than by naming
    // a y for each: adding a row to the list is then one line and cannot leave a
    // gap where a hidden view used to be.
    // ── AND IT MOVES, AFTER THE FIRST TIME ───────────────────────────────────
    //
    // Every frame here is assigned directly, so the card changing height and the
    // rows changing place happened between two paint cycles: the three modes read
    // as three different screens rather than as one card rearranging itself.
    // Wrapped in `Motion.run`, which already collapses to nothing under Reduce
    // Motion.
    //
    // NOT the first layout. The rig photographs this window at 4 s from a cold
    // start and an easing first paint is a screenshot whose contents depend on
    // when the shutter fell.
    var animateLayout = false
    let layout = { [weak t] in
      guard t != nil else { return }
      // What is on screen, top to bottom. Everything else is hidden, and hidden
      // is the DEFAULT rather than something each branch has to undo -- a view
      // left visible by a state that forgot it is the bug this shape exists to
      // make impossible.
      var column: [NSView] = []
      if t?.settingsOpen == true {
        // The card about YOU: handle, the login item, silent mode. Everything
        // here used to sit under the people list and push the card up over the
        // camera picture.
        column += Identity.handle.isEmpty ? [mineHint] : [mineRow, mineHint]
        column += [reachRow, reachHint, quietRow, quietHint]
      } else {
        // A call you are still in comes first: it is the only row on this card
        // about something already happening. Then a link somebody just sent you,
        // which is the newest intent in the room. Then the people, the field,
        // and last the link you hand OUT -- reaching somebody you have talked to
        // before is the common case, and inviting a stranger is the rare one.
        if resume != nil { column += [resumeRow] }
        if !linkRow.spokenName.isEmpty { column += [linkRow] }
        column += people.isEmpty ? [emptyHint] : peopleRows
        column += [fieldBack, status, inviteRow]
        // A brand-new install has nobody to call until somebody knows this
        // Mac's name -- so the name stays on the front card exactly until the
        // first person is in the list, then moves behind the `…`.
        if people.isEmpty {
          column += Identity.handle.isEmpty ? [mineHint] : [mineRow, mineHint]
        }
      }
      let shown = Set(column.map { ObjectIdentifier($0) })
      for x in [fieldBack, status, linkRow, inviteRow, resumeRow, mineRow, mineHint,
                emptyHint, reachRow, reachHint, quietRow, quietHint] as [NSView] {
        x.isHidden = !shown.contains(ObjectIdentifier(x))
      }
      moreBtn.on = t?.settingsOpen == true
      // The rule under the mine-row separates it from the list ABOVE it. At the
      // top of the settings card there is no list, and the line drew a divider
      // to nothing.
      mineRow.ruled = t?.settingsOpen != true
      for r in peopleRows { r.isHidden = !shown.contains(ObjectIdentifier(r)) }
      // The field is not in `column` -- it rides inside its `Vibrant` backing --
      // so its visibility follows the thing it sits in.
      field.isHidden = fieldBack.isHidden

      func heightOf(_ x: NSView) -> CGFloat {
        if x === status { return statusH }
        // ASK the hint, do not assume. `Metric.sheetHint` is 34 and the hint that
        // says why this Mac has no name wraps to three lines; a fixed box put its
        // last line under the card's bottom edge everywhere else this was done by
        // hand. The measure needs the width, which is known here and nowhere else.
        if let h = x as? SheetHint { h.measure(width: rowW); return h.wantedHeight }
        if x === fieldBack { return Metric.fieldHeight }
        return Metric.sheetRow
      }
      let gap = Metric.s1
      var h = pad + pad
      for (i, x) in column.enumerated() { h += heightOf(x) + (i == 0 ? 0 : gap) }
      card.frame = NSRect(x: Metric.gutter, y: Metric.gutter, width: cardW, height: h)

      var y = card.frame.maxY - pad
      for (i, x) in column.enumerated() {
        let hh = heightOf(x)
        y -= hh + (i == 0 ? 0 : gap)
        x.frame = NSRect(x: card.frame.minX + pad, y: y, width: rowW, height: hh)
        if x === fieldBack {
          // Full width, no buttons: Return is the commit, and the placeholder is
          // the label.
          field.frame = NSRect(x: x.frame.minX + Metric.s4, y: y + (hh - 19) / 2,
                               width: rowW - Metric.s4 * 2, height: 19)
        }
        x.needsDisplay = true
      }
      // The hint pill sits over the picture ABOVE the card, and the card's height
      // changes with the mode. Derived rather than a fraction of the window, so a
      // tall card cannot slide underneath it.
      // A clear band between the pill and the card. At `s5` the two were two
      // points apart and photographed as one object with a bubble growing out of
      // its top edge -- the pill is a statement about the PICTURE, and it has to
      // sit in the picture rather than on the furniture.
      // Centred in the sky above the card, where the camera picture lives --
      // pinned to the card's edge it sat ON the first row's face the moment the
      // card grew a tall mode. Clamped to the edge from below so a card that
      // fills the window cannot push the sentence off the top.
      // Top-right of the WINDOW, where the call window keeps its own `…`, and
      // clear of the traffic lights on the left. Pinned to the window rather
      // than to the card so it does not travel every time the card changes
      // height -- a control that moves when the content moves is a control you
      // have to find again.
      moreBtn.setFrameOrigin(NSPoint(x: W - Metric.gutter - moreBtn.frame.width,
                                     y: H - Metric.gutter - moreBtn.frame.height))
      hintY = max(card.frame.maxY + Metric.s8,
                  card.frame.maxY + (H - card.frame.maxY - Metric.pillHeight) / 2)
      // The pill is placed by `setHint` AT CALL TIME, and the camera's first
      // sentence lands before the first relayout -- so a moved hintY has to
      // re-place the pill that is already on screen or the fix only applies to
      // the next sentence.
      if !hint.isHidden {
        hintPill.frame.origin.y = hintY
        hint.frame.origin.y = hintY + (Metric.pillHeight - 16) / 2
      }
      card.needsDisplay = true
      v.needsLayout = true
      // ── WHAT IS ACTUALLY ON THE CARD, READ OUT ───────────────────────────────
      //
      // The card's whole job is to be SHORT -- it floats over the person's own
      // face, and every row on it is a row of their face it covers. A rig can
      // photograph the window but cannot say which rows those are, and "the
      // settings crept back onto the front card" is exactly the drift that
      // happens one well-meaning row at a time.
      let names = column.map { x -> String in
        if x === linkRow { return "link" }
        if x === inviteRow { return "invite" }
        if x === resumeRow { return "rejoin" }
        if x === fieldBack { return "field" }
        if x === status { return "status" }
        if x === mineRow { return "mine" }
        if x === reachRow { return "reach" }
        if x === quietRow { return "quiet" }
        if x === emptyHint { return "empty" }
        if x is SheetHint { return "hint" }
        if let c = x as? ContactRow { return "@" + c.handleName }
        return "?"
      }
      fputs("home card [\(t?.settingsOpen == true ? "settings" : "front")]: "
            + names.joined(separator: " ") + "\n", stderr)
    }
    let relayout = { if animateLayout { Motion.run { layout() } } else { layout() } }
    t.relayout = relayout

    // ── WIRING ────────────────────────────────────────────────────────────────
    // Return commits the field. `keyEquivalent` belonged to the buttons this
    // replaced; the field is where Return is actually pressed.
    field.target = t; field.action = #selector(Target.commit)
    mineRow.target = t; mineRow.action = #selector(Target.copyMine(_:))
    reachRow.target = t
    reachRow.action = #selector(Target.reachable)
    linkRow.target = t; linkRow.action = #selector(Target.joinClip)
    moreBtn.target = t; moreBtn.action = #selector(Target.settings)
    inviteRow.target = t; inviteRow.action = #selector(Target.copyInvite(_:))
    t.resumable = resume
    resumeRow.target = t; resumeRow.action = #selector(Target.rejoin)
    // The room is known and about to be joined -- the same free second the faces
    // and the clipboard row get.
    resumeRow.onHover = { if let r = resume { Warm.room(r.room, why: "hover rejoin") } }
    quietRow.target = t; quietRow.action = #selector(Target.quietPressed)
    // ── A SWITCH THAT MOVES ONLY WHEN THE SERVER SAYS IT DID ─────────────────
    //
    // `setQuiet` is an HTTPS round trip and it is the authority: a row that
    // flipped optimistically would tell somebody they are unreachable while
    // calls keep arriving, which is the one error in this feature that matters.
    // So the row says "asking…" and then reports what came back.
    t.toggleQuiet = { [weak t] in
      let want = !Identity.quietOn
      quietRow.value = "asking…"
      Thread {
        let ok = Identity.setQuiet(want)
        let now = Identity.quietOn
        DispatchQueue.main.async {
          quietRow.value = now ? "on" : "off"
          quietHint.setText(ok
            ? (now ? "Calls to you are quietly declined until you turn this off."
                   : "People can ring you.")
            : "Couldn’t reach the server — nothing changed.")
          fputs("home: quiet asked \(want), server says \(now ? "on" : "off")\n", stderr)
          t?.relayout()
        }
      }.start()
    }
    // Same free time the faces get: the room is knowable the moment the pointer
    // lands on the row, and it is very likely the one about to be joined.
    linkRow.onHover = { [weak t] in if let r = t?.clipRoom { Warm.room(r, why: "hover link") } }

    // ── READING THE CLIPBOARD, AND SAYING SO ON A ROW ────────────────────────
    //
    // Checked when the window opens and again whenever the app comes forward --
    // the only two moments the clipboard can have changed while this screen is
    // what you see. The row names the room it would join; `clipRoom` is what
    // fires, so the click always does what the row said.
    let scanClipboard = { [weak t] in
      guard let t, !t.ringing else { return }
      let s = NSPasteboard.general.string(forType: .string) ?? ""
      let room = Launcher.roomFromLink(s)
      guard room != t.clipRoom else { return }
      t.clipRoom = room
      linkRow.setLabel(room.map { "Join \($0)" } ?? "")
      fputs("home: clipboard link \(room ?? "none")\n", stderr)
      t.relayout()
    }
    scanClipboard()
    let clipWatch = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
        scanClipboard()
      }
    defer { NotificationCenter.default.removeObserver(clipWatch) }
    // ── SAYING WHAT HAPPENED, INCLUDING WHEN IT REFUSED ──────────────────────
    //
    // `Watch.install()` returns a SENTENCE, and three of the things it can say are
    // refusals -- a copy that is not in /Applications is not a stable target at
    // login, the plist could not be written, another Kin got there first. A row
    // that flips to "on" regardless would be the exact defect this project keeps
    // finding: a control that reports success for work that did not happen.
    //
    // launchctl is a subprocess, so it is not run on the thread that draws.
    t.makeReachable = { [weak t] in
      reachRow.setLabel("Turning it on…")
      Thread {
        let said = Watch.install()
        let ok = Watch.healthy()
        DispatchQueue.main.async {
          fputs(said + "\n", stderr)
          Metrics.tap("watch_install", ok: ok)
          guard ok else {
            // The sentence, not a shrug. It names which of the three it was, and
            // two of them are things the person can act on.
            reachRow.setLabel("Couldn’t turn it on")
            reachHint.setText(said.replacingOccurrences(of: "watch: ", with: ""))
            return
          }
          watchOK = true
          // It stays on the settings card once it is on, saying so, rather than
          // vanishing: a row that disappears when it succeeds leaves nowhere to
          // check the answer later.
          reachRow.setLabel("People can reach you when Kin is closed")
          reachRow.value = "on"
          reachRow.valueIsWord = true
          reachRow.inert = true
          t?.relayout()
        }
      }.start()
    }

    for r in peopleRows {
      r.target = t
      r.action = #selector(Target.callRow(_:))
      // ── THE POINTER ARRIVING IS WORTH ABOUT A SECOND ────────────────────────
      //
      // The room a contact call uses is minted at the moment of the click, and a
      // room nobody has touched costs ~1108 ms on its first request. Minting it
      // when the pointer ENTERS the row, and warming it there, moves that whole
      // cost into the time between deciding to click somebody and clicking them.
      //
      // Recorded per handle so the click uses the room that was actually warmed.
      // Without that the warm would be for a room the call never joins, which is
      // the same as no warm at all and looks identical in every log.
      r.onHover = { [weak t] in
        guard let t, t.warmed[r.handleName] == nil else { return }
        let room = Launcher.mintRoom()
        t.warmed[r.handleName] = room
        Warm.room(room, why: "hover @" + r.handleName)
      }
    }
    // Typing a room is the same signal as hovering a face: the name is knowable
    // well before Join is pressed. `Warm` asks once per room, so a person typing
    // `standup` one character at a time sends one request, not eight.
    let typing = NotificationCenter.default.addObserver(
      forName: NSControl.textDidChangeNotification, object: field, queue: .main) { _ in
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only what would JOIN as a room is worth warming as one: a `-` or `_`
        // is what routes a committed word to a room, and warming every typed
        // name would send a request per person whose room this will never be.
        guard raw.contains("-") || raw.contains("_") else { return }
        guard raw.count >= 3, raw.count <= 64,
              raw.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return }
        Warm.room(raw, why: "typed")
      }
    defer { NotificationCenter.default.removeObserver(typing) }

    relayout()
    animateLayout = true

    // ── THE MENU BAR, WHICH THIS WINDOW NEVER HAD ────────────────────────────
    //
    // `Menu.install` is called from `Display.open`, so every Mac reflex --
    // Command-Q, Command-W, Command-M -- did nothing at all on the FIRST screen
    // of the app, the one you look at before you have decided to call anybody.
    // `installHome` is the subset that means something with no call running; the
    // call replaces it wholesale when it opens.
    Menu.installHome()
    fputs("home: menu ready (\(NSApp.mainMenu?.items.count ?? 0) menus,"
        + " close=\(Menu.find("Close") != nil), quit=\(Menu.find("Quit Kin") != nil))\n", stderr)
    // ⌘Q goes through `NSApp.terminate`, which never returns to the pump below --
    // so the un-ring a close performs (see the teardown) has to happen HERE for a
    // quit, before terminate takes the process. Same cancel, same bounded wait.
    Menu.onQuit = { [weak t] in
      guard let t, !t.ringSettled else { return }
      t.ringGen &+= 1
      t.ringing = false
      fputs("home: ring abandoned by quit -- sending bye\n", stderr)
      pumpAppKit(until: Date().addingTimeInterval(2.5),
                 while: { !t.ringSettled || t.byeInFlight })
    }
    defer { Menu.onQuit = nil }

    // ── AND THE KEYBOARD ─────────────────────────────────────────────────────
    //
    // `makeFirstResponder(nil)` on the people screen, and nothing anywhere
    // handling a key: the front door was a list of names that could only be
    // reached with a pointer. Arrows walk it, Return rings, Esc backs out of a
    // mode or cancels a ring, and a letter typed at the list is taken to mean you
    // want to call somebody who is not on it.
    //
    // A LOCAL monitor, scoped to this window and torn down with it, rather than
    // an NSWindow subclass: the two text fields on this card are real field
    // editors and everything they should keep -- every letter, Return, the arrow
    // keys inside the text -- has to pass through untouched. A monitor can decide
    // per event; an override has already taken the key.
    var keySel: Int? = nil
    // The rows the arrows walk, in the order they are drawn. Recomputed per press
    // rather than captured: a hidden row is not on screen and must not be
    // selectable.
    func liveRows() -> [ContactRow] { peopleRows.filter { !$0.isHidden } }
    func paintSel() {
      let rows = liveRows()
      for (i, r) in rows.enumerated() { r.keySelected = (i == keySel) }
    }
    func moveSel(_ d: Int) {
      let rows = liveRows()
      guard !rows.isEmpty else { return }
      // Nowhere yet: the first Down lands on the top row and the first Up on the
      // bottom one. Clamped rather than wrapped -- a list of five people is short
      // enough that running off the end and reappearing at the other reads as the
      // selection having been lost.
      keySel = keySel.map { min(max($0 + d, 0), rows.count - 1) } ?? (d > 0 ? 0 : rows.count - 1)
      paintSel()
    }
    let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
      guard e.window === w else { return e }
      let editing = field.currentEditor() != nil
      // Esc first, including while the field has the caret: it is the only key
      // this window takes out from under the text editor. In order: a ring in
      // flight is cancelled, typed text is cleared, a resting caret is released
      // back to the list. Each press undoes one thing.
      if e.keyCode == 53 {
        if t.ringing { t.stopRing(); return nil }
        if t.settingsOpen { t.settings(); return nil }
        if editing, !(field.currentEditor()?.string.isEmpty ?? true) {
          field.stringValue = ""; field.currentEditor()?.string = ""
          status.stringValue = ""
          return nil
        }
        if editing { w.makeFirstResponder(nil) }
        return nil
      }
      // The field's editor keeps every other key: arrows move its caret, Return
      // fires its action, letters are letters.
      guard !editing else { return e }
      // Ringing owns the keyboard except for Esc: every other key here starts
      // something, and `Target` refuses all of it anyway.
      guard !t.ringing else { return e }
      switch e.keyCode {
      case 125: moveSel(1); return nil                                   // down
      case 126: moveSel(-1); return nil                                  // up
      case 36, 76:                                                       // return, enter
        let rows = liveRows()
        guard let i = keySel, i < rows.count else { return nil }
        // Through the row's own target/action, which is the edge a click arrives
        // on -- so a row with a stale action fails here exactly as under a finger.
        guard let tgt = rows[i].target, let act = rows[i].action else { return nil }
        NSApp.sendAction(act, to: tgt, from: rows[i])
        return nil
      default: break
      }
      // A letter at the list goes into the one field, so typing "m" never costs
      // a click first.
      guard let ch = e.charactersIgnoringModifiers, let first = ch.first, first.isLetter,
            !e.modifierFlags.contains(.command) else { return e }
      keySel = nil
      paintSel()
      w.makeFirstResponder(field)
      // The caret AFTER the character, in the live field editor -- `stringValue`
      // is the committed value and the editor is what the next keystroke goes to
      // (`committed-value-is-not-current-value`).
      if let ed = field.currentEditor() {
        ed.string = String(first)
        ed.selectedRange = NSRange(location: ed.string.count, length: 0)
      }
      return nil
    }
    fputs("home: keys ready\n", stderr)

    // ── THIS WINDOW HAD NO PRESS PATH, AND NOW IT IS THE FRONT DOOR ──────────
    //
    // The comment further down still says "this window has no press path", and
    // that was tolerable when it held one text field and a Join button. It is the
    // first screen of the app now and every way into a call starts on it, so it
    // needs what the call window has: a way for a rig to work it without a hand on
    // the trackpad.
    //
    // Through `NSApp.sendAction` on the REAL control, not by calling the closure:
    // that is the same edge a click arrives on after `SheetRow`'s own tracking,
    // so a row with a missing target or a stale action fails here exactly as it
    // would fail under a finger. What it CANNOT see is whether something
    // decorative sits in front of the row, or whether the window can become key --
    // those need a real click, and `firstMouseAt` below covers the half of it that
    // is geometry.
    func rowNamed(_ n: String) -> SheetRow? {
      switch n {
      case "reach": return reachRow
      case "mine": return mineRow
      case "link": return linkRow
      case "quiet": return quietRow
      case "invite": return inviteRow
      case "rejoin": return resumeRow
      default: return peopleRows.first { $0.handleName == n }
      }
    }
    // ── AND WHAT THE FIRST CLICK WOULD DO, READ OUT RATHER THAN REASONED ABOUT ─
    //
    // `acceptsFirstClick` is off for every row that reaches a person or changes
    // this Mac, and on for nothing else here. That is a rule written in a comment,
    // and a rule written in a comment is a rule nobody checks again -- so the
    // window says what it actually answers, per row, the way `WaitingCard`
    // publishes `firstMouseAt` for the same rule and the same reason.
    var audit: [String] = []
    for r in peopleRows { audit.append("@\(r.handleName)=\(r.acceptsFirstMouse(for: nil))") }
    for (n, r) in [("link", linkRow), ("reach", reachRow), ("mine", mineRow as SheetRow)] {
      audit.append("\(n)=\(r.acceptsFirstMouse(for: nil))")
    }
    fputs("home firstmouse " + audit.joined(separator: " ") + "\n", stderr)

    if let token = arg("press") {
      // Deferred one turn of the run loop: the pump below has not started, and a
      // press that fires before it does would set `done` on a window that has not
      // drawn once -- which photographs as the app never opening.
      //
      // A COMMA-SEPARATED SEQUENCE, spaced by `--press-after` seconds -- the same
      // shape the call window's `--press "?,~,~,?"` already has. One token still
      // fires immediately, so every existing invocation means what it meant.
      //
      // A sequence is the only way to press something while an earlier press is
      // still working: closing this window while a ring is in flight is a path
      // with no other rig route, because a global keystroke goes to whatever app
      // is frontmost -- which in a rig is somebody's own real window.
      let gap = Double(arg("press-after") ?? "") ?? 0
      for (n, one) in token.split(separator: ",").map(String.init).enumerated() {
      DispatchQueue.main.asyncAfter(deadline: .now() + gap * Double(n)) {
        let bits = one.split(separator: ":", maxSplits: 1).map(String.init)
        switch bits[0] {
        // Both verbs land in the one field now -- kept as two names so old rig
        // invocations still mean what they meant: `join:x` joins x, `type:x`
        // rings @x. What each does is decided by `commit`'s own routing.
        case "join", "type":
          if bits.count > 1 { field.stringValue = bits[1] }
          t.commit()
        // Not a row, so `rowNamed` cannot reach it -- through the real button's
        // target/action, the same edge a click arrives on.
        case "settings":
          NSApp.sendAction(moreBtn.action!, to: moreBtn.target, from: moreBtn)
        // The red button's own path, so what the rig exercises is what a finger
        // does -- including the pump's exit on `!w.isVisible` and the un-ring
        // that follows it.
        case "close": w.performClose(nil)
        default:
          guard let r = rowNamed(bits.count > 1 ? bits[1] : bits[0]),
                !r.isHidden, let tgt = r.target, let act = r.action else {
            fputs("press: no row named " + one + " on this screen\n", stderr)
            return
          }
          NSApp.sendAction(act, to: tgt, from: r)
        }
        fputs("press: \(one) done\n", stderr)
      }
      }
    }

    w.makeKeyAndOrderFront(nil)
    // ── THE CARET GOES WHERE THE MODE IS ─────────────────────────────────────
    //
    // Unconditionally `field` before, which was right when the room field was the
    // only thing on the card. It is now hidden on the default screen, and AppKit
    // will happily make a hidden text field the first responder: the caret would
    // be in a box nobody can see, and the first thing typed would go into it.
    // No caret anywhere by default: the list owns the arrows, and the first
    // letter typed puts itself in the field (see the key monitor).
    w.makeFirstResponder(nil)
    // ── THE ONE WINDOW IN THIS APP THAT STILL TOOK THE FRONT ─────────────────
    //
    // `Display.open` has had this switch since a rig's ring cards started landing
    // under a real person's trackpad taps, and the call window has been polite
    // ever since. This one was not: `activate(ignoringOtherApps:)` with nothing in
    // front of it, so every `--gui` run in a harness threw a 560x520 window over
    // whatever the person at this Mac was doing and then waited for a click to go
    // away. Which is why the join card was the one surface no rig had ever
    // photographed -- it could not be reached without interrupting somebody.
    //
    // Same switch, same three parts, same reasons written out in `Display.open`:
    // out of the way, click-through so a real finger passes to whatever is
    // behind, and no activation. Nothing in the app sets it, so a person opening
    // Kin still gets a window that comes to the front and takes the keyboard.
    if ProcessInfo.processInfo.environment["TK_NO_RAISE"] == "1" {
      if let vis = NSScreen.main?.visibleFrame {
        w.setFrameOrigin(NSPoint(x: vis.minX + 4, y: vis.minY + 4))
      }
      w.ignoresMouseEvents = true
    } else {
      app.activate(ignoringOtherApps: true)
    }
    // The same line the call window prints, and for the same reason: a material is
    // composited by the window server, so the only capture that can see this
    // screen is one aimed at this window.
    fputs("window id \(w.windowNumber) -- screencapture -l \(w.windowNumber) -x out.png\n", stderr)
    // And what its surfaces are made of. The call window says this on `--press ?`;
    // this window has no press path, and two of the app's surfaces live only here.
    // A policy that holds for fifteen surfaces and was never checked on the other
    // two is the shape of the drift this whole audit exists to catch.
    for line in Glass.describeAll() { fputs("glass \(line)\n", stderr) }

    // Drive the event loop by hand. `app.run()` would not return, and this window
    // has to finish before the audio graph, the sockets or the camera exist.
    // Same pump as everywhere else now; the exit condition is the only difference.
    pumpAppKit(until: .distantFuture, while: { !t.done && w.isVisible })
    t.done = true                                  // they joined, or they closed it
    w.orderOut(nil)
    // ── CLOSING THE DOOR IS ALSO HANGING UP ──────────────────────────────────
    //
    // A ring that has left this Mac is a Mac somewhere else that is RINGING, and
    // closing this window does not change that: the lease runs 60 s. So a close
    // (or ⌘Q -- see `Menu.onQuit` below) while a ring is travelling cancels it
    // the same way Esc does, and then WAITS -- pumping, bounded -- for the POST
    // to settle and the un-ring to actually leave. An exit that outruns its own
    // bye told nobody (`execv-discards-unsent-analytics`, the same ending).
    // `!ringSettled` and not `ringing`: the question is whether the POST is still
    // in flight, which is the only state where nobody yet knows if a Mac is
    // ringing. A ring that already came back succeeded (we are walking into that
    // call) or failed (nothing to un-ring) -- reading `ringing` here called every
    // successful call an abandoned one.
    if !t.ringSettled {
      t.ringGen &+= 1          // the completion's stale branch sends the bye
      t.ringing = false
      fputs("home: ring abandoned by close -- sending bye\n", stderr)
    }
    pumpAppKit(until: Date().addingTimeInterval(2.5),
               while: { !t.ringSettled || t.byeInFlight })
    // The dots die with the window: a timer that outlives it would keep asking
    // the server about people whose rows no longer exist.
    presenceTimer?.invalidate()
    presenceTimer = nil
    // Same rule for the other two, and for the monitor: a local key monitor is
    // installed on the APPLICATION, so one left behind would keep eating keys for
    // a window that no longer exists.
    // `addLocalMonitorForEvents` returns `Any?` -- nil means no monitor was
    // installed, and handing that to `removeMonitor` is an exception, not a no-op.
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    dotTimer?.invalidate()
    dotTimer = nil
    t.copyTimer?.invalidate()
    t.copyTimer = nil
    t.inviteTimer?.invalidate()
    t.inviteTimer = nil
    // ── RELEASING THE CAMERA, WHICH USED TO BE EXEC'S JOB ────────────────────
    //
    // `stopRunning()` alone was enough while a re-exec followed: the process
    // stopped existing a moment later and took every reference to the device with
    // it. Without the re-exec (`--in-process`) this session is the ONLY thing
    // standing between the front door and the call's own `CameraSource`, and a
    // capture input still attached to a device is that device still being held.
    //
    // So the inputs come off explicitly and the session is remembered as released.
    // `stopRunning` is synchronous and returns after the device is quiesced, which
    // is why the order is stop-then-detach and not the other way round.
    if session.isRunning { session.stopRunning() }
    for i in session.inputs { session.removeInput(i) }
    cameraReleased = true
    // ── ONLY A ROOM YOU TYPED IS A ROOM WORTH REMEMBERING ────────────────────
    //
    // `recentRooms` is a list of shared words -- things you and somebody agreed to
    // say to each other. A minted room from a contact call is a random 3-4-3 code
    // that exists for one call and that neither person ever sees; putting those in
    // the list would fill the only human-readable history in the app with noise
    // within a week of the people list working.
    if case .room(let r)? = t.out { remember(r) }
    return t.out
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
      // `--with` names who the CURRENT room is shared with, and this line is
      // where the room changes -- carried forward, a later close in a fresh
      // room would send its "can't talk" bye to somebody from a previous call.
      // The answer path passes it explicitly in `extra`, which is not filtered.
      if t == "--gui" || t == "--call" || t == "--incoming" || t == "--calling"
        || t == "--with" || t == "--press" || t == "--press-after" || seen.contains(t) { continue }
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
