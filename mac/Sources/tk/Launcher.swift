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
  }

  /// Which of the three things this card is currently for. One value, because two
  /// booleans that have to agree are a state that can be both -- the bug
  /// `WaitingCard.Mode` was extracted to fix, in the same shape, one screen away.
  enum Mode { case people, word, name }

  static func home() -> Intent? {
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
    func setHint(_ s: String) {
      hint.stringValue = s
      hintPill.isHidden = s.isEmpty
      hint.isHidden = s.isEmpty
      guard !s.isEmpty else { return }
      let tw = ceil((s as NSString).size(withAttributes: [.font: Type_.status]).width)
      let pw = tw + Metric.s8
      hintPill.frame = NSRect(x: (W - pw) / 2, y: hintY, width: pw, height: Metric.pillHeight)
      hint.frame = NSRect(x: (W - pw) / 2, y: hintY + (Metric.pillHeight - 16) / 2,
                          width: pw, height: 16)
    }
    v.addSubview(hintPill)
    v.addSubview(hint)

    let session = AVCaptureSession()
    setHint("Starting camera…")

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
    let people = Array(Identity.contactHandles().prefix(5))
    let pad = Metric.cardPad
    let cardW = W - Metric.gutter * 2
    let rowW = cardW - pad * 2
    let card = Glass("joinCard", radius: Metric.cardRadius)
    v.addSubview(card)

    // ── THE ONE EDITABLE THING, TWICE, BECAUSE THEY ARE TWO QUESTIONS ─────────
    //
    // `field` is a ROOM: a shared word, and also the encryption salt, which is why
    // it is validated rather than normalised (see `validate`). `nameField` is a
    // HANDLE: somebody's name in the registry, checked by `Identity.sanitize`,
    // which is the server's own rule. They look identical and they are not
    // interchangeable -- a room name may contain `-` and `_` and a handle may not
    // -- so typing one into the other has to fail rather than half-work.
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

    let title = NSTextField(labelWithString: "")
    title.font = Type_.title
    title.textColor = Palette.fg
    title.backgroundColor = .clear
    title.isBordered = false
    v.addSubview(title)

    let sub = NSTextField(labelWithString: "")
    sub.font = Type_.caption
    sub.textColor = Palette.muted
    sub.maximumNumberOfLines = 2
    sub.lineBreakMode = .byWordWrapping
    sub.backgroundColor = .clear
    sub.isBordered = false
    v.addSubview(sub)

    // The room half: field, Suggest, Join. Every line of this is the code that was
    // here before, moved rather than rewritten -- it is the path a first-time pair
    // of Macs still takes, and it was correct.
    let fieldBack = vibrant(Metric.fieldHeight)
    let field = plainField("a word you both know",
                           UserDefaults.standard.string(forKey: lastRoomKey) ?? suggestRoom())
    let newBtn = PillButton("Suggest")
    let join = PillButton("Join")
    join.prominent = true
    newBtn.setFrameSize(NSSize(width: 84, height: Metric.fieldHeight))
    join.setFrameSize(NSSize(width: 92, height: Metric.fieldHeight))
    for x in [fieldBack, field, newBtn, join] as [NSView] { v.addSubview(x) }

    // The handle half.
    let nameBack = vibrant(Metric.fieldHeight)
    let nameField = plainField("their name", "")
    let callBtn = PillButton("Call")
    callBtn.prominent = true
    callBtn.setFrameSize(NSSize(width: 92, height: Metric.fieldHeight))
    for x in [nameBack, nameField, callBtn] as [NSView] { v.addSubview(x) }

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
    let newRow = SheetRow("Call someone new", glyph: Glyph.person)
    let wordRow = SheetRow("Join with a word")
    let backRow = SheetRow("Back")
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
    let reachRow = SheetRow("Let people reach you when Kin is closed")
    let reachHint = SheetHint("Kin starts when you log in, just to listen for calls.")
    reachRow.textInset = Metric.rowAvatarInset
    v.addSubview(reachRow)
    v.addSubview(reachHint)
    for r in peopleRows { v.addSubview(r) }
    for x in [newRow, wordRow, backRow, mineRow] as [NSView] { v.addSubview(x) }
    v.addSubview(mineHint)
    v.addSubview(emptyHint)
    // `newRow` and `wordRow` carry no glyph column of their own beside a list of
    // 34 pt faces -- a page of faces has a 56 pt mark column and an ordinary row
    // an 18 pt one, and the two together draw a ragged left edge that reads as two
    // lists that happen to be adjacent. Same fix as `buildPeoplePage`.
    for r in [wordRow, backRow] { r.textInset = Metric.rowAvatarInset }
    newRow.textInset = Metric.rowAvatarInset
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
    for r in [newRow, wordRow, backRow, mineRow, reachRow] { r.acceptsFirstClick = false }

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
      var mode = Mode.people
      let field: NSTextField
      let nameField: NSTextField
      let status: NSTextField
      /// Minted when the pointer arrives on a face, used when the click lands.
      /// One per handle: hovering across a list five times must not mint five
      /// rooms and warm all of them.
      var warmed: [String: String] = [:]
      var relayout: () -> Void = {}
      var ring: (String) -> Void = { _ in }
      /// Turn on the login item. A closure rather than a method body because the
      /// row it reports into is built outside this class.
      var makeReachable: () -> Void = {}
      init(field: NSTextField, nameField: NSTextField, status: NSTextField) {
        self.field = field; self.nameField = nameField; self.status = status
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

      @objc func go() {
        guard !ringing, let name = validate(field.stringValue) else { return }
        out = .room(name)
        done = true
      }
      @objc func suggest() {
        field.stringValue = Launcher.suggestRoom()
        status.stringValue = ""
        // Typed or suggested, the room is knowable now and the click is not for
        // another second or two. Same free time the faces use.
        if let r = validate(field.stringValue) { Warm.room(r, why: "suggested") }
      }
      /// A face was clicked. Everything after this is the ring, and the room is the
      /// one that was minted and warmed when the pointer arrived.
      @objc func callRow(_ sender: SheetRow) {
        guard !ringing, let row = sender as? ContactRow else { return }
        ring(row.handleName)
      }
      @objc func callTyped() {
        guard !ringing else { return }
        let raw = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
        guard let who = Identity.sanitize(bare) else {
          // The server's rule, said in words rather than as a regex. A handle is
          // not a room name and the two fields refuse different things.
          status.stringValue = raw.isEmpty ? "Type their name."
                                           : "Names are letters and numbers, starting with a letter."
          return
        }
        ring(who)
      }
      @objc func copyMine(_ sender: SheetRow) {
        guard let row = sender as? ContactRow, !row.handleName.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("@" + row.handleName, forType: .string)
        row.value = "copied"
      }
      @objc func showName() { guard !ringing else { return }; status.stringValue = ""; mode = .name; relayout() }
      @objc func showWord() { guard !ringing else { return }; status.stringValue = ""; mode = .word; relayout() }
      @objc func showPeople() { guard !ringing else { return }; status.stringValue = ""; mode = .people; relayout() }
      @objc func reachable() { guard !ringing else { return }; makeReachable() }
      @objc func cancel() { done = true }
    }
    let t = Target(field: field, nameField: nameField, status: status)
    // With nobody in the list there is no people page to be the default: the card
    // opens on the room field, which is exactly the screen this used to be.
    t.mode = people.isEmpty ? .word : .people

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
    t.ring = { [weak t] who in
      guard let t, !t.done, !t.ringing else { return }
      t.ringing = true
      let room = t.warmed[who] ?? Launcher.mintRoom()
      setHint("Calling \(Identity.display(who))…")
      Thread {
        Metrics.count("ring_sent_try")
        let got = Identity.ring(to: who, room: room)
        let listening = Identity.lastRingListening
        DispatchQueue.main.async {
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
    let relayout = { [weak t] in
      guard let t else { return }
      let words = t.mode == .people
      title.stringValue = words ? "" : (t.mode == .name ? "Call someone new" : "Join with a word")
      sub.stringValue = t.mode == .word
        ? "Type the same word on both Macs. It is also the password, so pick something only you two would say."
        : (t.mode == .name ? "Their name is the one their Mac told them, like @meera." : "")

      // What is on screen in this mode, top to bottom. Everything else is hidden,
      // and hidden is the DEFAULT rather than something each branch has to undo --
      // a view left visible by a mode that forgot it is the bug this shape exists
      // to make impossible.
      var column: [NSView] = []
      let heads: [NSView] = t.mode == .people ? [] : [title, sub]
      switch t.mode {
      case .people:
        column += people.isEmpty ? [emptyHint] : peopleRows
        column += [newRow, wordRow]
        // Below the things you came here to do and above your own name, which is
        // the other thing on this card about being reachable rather than about
        // reaching somebody.
        if !watchOK { column += [reachRow, reachHint] }
        column += Identity.handle.isEmpty ? [mineHint] : [mineRow, mineHint]
      case .name:
        column += [nameBack, status]
        column += people.isEmpty ? [] : [backRow]
      case .word:
        column += [fieldBack, status]
        column += people.isEmpty ? [] : [backRow]
      }
      let shown = Set((heads + column).map { ObjectIdentifier($0) })
      for x in [title, sub, fieldBack, field, newBtn, join, nameBack, nameField, callBtn,
                status, newRow, wordRow, backRow, mineRow, mineHint, emptyHint,
                reachRow, reachHint] as [NSView] {
        x.isHidden = !shown.contains(ObjectIdentifier(x))
      }
      for r in peopleRows { r.isHidden = !shown.contains(ObjectIdentifier(r)) }
      // The two fields are not in `column` -- they ride inside their `Vibrant`
      // backing -- so their visibility follows the thing they sit in.
      field.isHidden = fieldBack.isHidden
      newBtn.isHidden = fieldBack.isHidden
      join.isHidden = fieldBack.isHidden
      nameField.isHidden = nameBack.isHidden
      callBtn.isHidden = nameBack.isHidden

      func heightOf(_ x: NSView) -> CGFloat {
        if x === title { return 24 }
        if x === sub { return 32 }
        if x === status { return statusH }
        // ASK the hint, do not assume. `Metric.sheetHint` is 34 and the hint that
        // says why this Mac has no name wraps to three lines; a fixed box put its
        // last line under the card's bottom edge everywhere else this was done by
        // hand. The measure needs the width, which is known here and nowhere else.
        if let h = x as? SheetHint { h.measure(width: rowW); return h.wantedHeight }
        if x === fieldBack || x === nameBack { return Metric.fieldHeight }
        return Metric.sheetRow
      }
      let gap = Metric.s1
      var h = pad + pad
      for (i, x) in (heads + column).enumerated() { h += heightOf(x) + (i == 0 ? 0 : gap) }
      // The title and the subtitle want more air under them than two rows want
      // between them; without it the sentence and the field it is about read as
      // one block.
      if !heads.isEmpty { h += Metric.s3 }
      card.frame = NSRect(x: Metric.gutter, y: Metric.gutter, width: cardW, height: h)

      var y = card.frame.maxY - pad
      for (i, x) in (heads + column).enumerated() {
        let hh = heightOf(x)
        y -= hh + (i == 0 ? 0 : gap)
        if x === sub { y -= 0 }
        x.frame = NSRect(x: card.frame.minX + pad, y: y, width: rowW, height: hh)
        if x === title || x === sub || x === status { /* labels fill the row */ }
        if x === fieldBack {
          // The field shares its line with Suggest and Join, so it is the only
          // thing here that is not full width.
          let w = rowW - Metric.s2 * 2 - join.frame.width - newBtn.frame.width
          x.setFrameSize(NSSize(width: w, height: hh))
          field.frame = NSRect(x: x.frame.minX + Metric.s4, y: y + (hh - 19) / 2,
                               width: w - Metric.s4 * 2, height: 19)
          newBtn.setFrameOrigin(NSPoint(x: x.frame.maxX + Metric.s2, y: y))
          join.setFrameOrigin(NSPoint(x: newBtn.frame.maxX + Metric.s2, y: y))
        }
        if x === nameBack {
          let w = rowW - Metric.s2 - callBtn.frame.width
          x.setFrameSize(NSSize(width: w, height: hh))
          nameField.frame = NSRect(x: x.frame.minX + Metric.s4, y: y + (hh - 19) / 2,
                                   width: w - Metric.s4 * 2, height: 19)
          callBtn.setFrameOrigin(NSPoint(x: x.frame.maxX + Metric.s2, y: y))
        }
        if x === title || x === sub { y -= (x === sub ? Metric.s3 : 0) }
        x.needsDisplay = true
      }
      // The hint pill sits over the picture ABOVE the card, and the card's height
      // changes with the mode. Derived rather than a fraction of the window, so a
      // tall card cannot slide underneath it.
      // A clear band between the pill and the card. At `s5` the two were two
      // points apart and photographed as one object with a bubble growing out of
      // its top edge -- the pill is a statement about the PICTURE, and it has to
      // sit in the picture rather than on the furniture.
      hintY = card.frame.maxY + Metric.s8
      card.needsDisplay = true
      v.needsLayout = true
    }
    t.relayout = relayout

    // ── WIRING ────────────────────────────────────────────────────────────────
    join.onPress = { t.go() }
    newBtn.onPress = { t.suggest() }
    callBtn.onPress = { t.callTyped() }
    // Return commits, in whichever field is on screen. `keyEquivalent` belonged to
    // the buttons this replaced; the field is where Return is actually pressed,
    // which is one fewer thing to keep in agreement.
    field.target = t; field.action = #selector(Target.go)
    nameField.target = t; nameField.action = #selector(Target.callTyped)
    newRow.target = t; newRow.action = #selector(Target.showName)
    wordRow.target = t; wordRow.action = #selector(Target.showWord)
    backRow.target = t; backRow.action = #selector(Target.showPeople)
    mineRow.target = t; mineRow.action = #selector(Target.copyMine(_:))
    reachRow.target = t
    reachRow.action = #selector(Target.reachable)
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
        guard raw.count >= 3, raw.count <= 64,
              raw.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return }
        Warm.room(raw, why: "typed")
      }
    defer { NotificationCenter.default.removeObserver(typing) }

    relayout()

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
      case "new": return newRow
      case "word": return wordRow
      case "back": return backRow
      case "reach": return reachRow
      case "mine": return mineRow
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
    for (n, r) in [("new", newRow), ("word", wordRow), ("back", backRow),
                   ("reach", reachRow), ("mine", mineRow as SheetRow)] {
      audit.append("\(n)=\(r.acceptsFirstMouse(for: nil))")
    }
    fputs("home firstmouse " + audit.joined(separator: " ") + "\n", stderr)

    if let token = arg("press") {
      // Deferred one turn of the run loop: the pump below has not started, and a
      // press that fires before it does would set `done` on a window that has not
      // drawn once -- which photographs as the app never opening.
      DispatchQueue.main.async {
        let bits = token.split(separator: ":", maxSplits: 1).map(String.init)
        switch bits[0] {
        case "join":
          if bits.count > 1 { field.stringValue = bits[1] }
          t.go()
        case "type":
          if bits.count > 1 { nameField.stringValue = bits[1] }
          t.callTyped()
        default:
          guard let r = rowNamed(bits.count > 1 ? bits[1] : bits[0]),
                !r.isHidden, let tgt = r.target, let act = r.action else {
            fputs("press: no row named " + token + " on this screen\n", stderr)
            return
          }
          NSApp.sendAction(act, to: tgt, from: r)
        }
        fputs("press: \(token) done -- mode is now \(t.mode)\n", stderr)
      }
    }

    w.makeKeyAndOrderFront(nil)
    // ── THE CARET GOES WHERE THE MODE IS ─────────────────────────────────────
    //
    // Unconditionally `field` before, which was right when the room field was the
    // only thing on the card. It is now hidden on the default screen, and AppKit
    // will happily make a hidden text field the first responder: the caret would
    // be in a box nobody can see, and the first thing typed would go into it.
    w.makeFirstResponder(t.mode == .word ? field : (t.mode == .name ? nameField : nil))
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
    // Release the device before the re-exec, so the call opens it cleanly rather
    // than racing a session this process is about to stop existing to own.
    if session.isRunning { session.stopRunning() }
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
