import AppKit

// ── THE MENU BAR ────────────────────────────────────────────────────────────
//
// There wasn't one. The app ran with `setActivationPolicy(.regular)`, put a real
// window on screen, and left the menu bar empty -- which means Command-Q did not
// quit, Command-W did not close, Command-M did not minimise, and the app's own
// name had nothing under it. Every one of those is a reflex a Mac user has before
// they have a thought, and an app that ignores all four does not feel like a Mac
// app no matter how the buttons are drawn.
//
// Built in code rather than a nib because there is no nib: this binary is also a
// command-line tool, and the menu only exists on the path that opens a window.
//
// The shortcuts here deliberately duplicate the ones the key monitor already
// handles. The monitor swallows what it handles, so nothing fires twice -- and the
// menu is where a person FINDS a shortcut. An undiscoverable shortcut is a secret.
enum Menu {
  /// What the menu needs to be able to do. Held weakly: the menu outlives nothing.
  static weak var controls: CallControls?
  static var onQuit: (() -> Void)?
  /// Opens the front door's settings card. See `Target.homeSettings`.
  static var onHomeSettings: (() -> Void)?

  // ── THE EDIT MENU, WHICH WAS SIMPLY NOT THERE ───────────────────────────────
  //
  // Command-V did nothing. Anywhere. In either window.
  //
  // Cut, Copy, Paste, Select All and Undo are not menu decoration on a Mac -- the
  // menu is where their key equivalents LIVE. `NSTextView` implements every one of
  // those actions and nothing was sending them, so the field on the front door
  // (the one whose placeholder says "Type a handle") and the rename field in the
  // sheet could both be typed into and neither could be pasted into.
  //
  // The way a call link actually arrives is a message somebody sends you. You copy
  // it. Then you open Kin and press Command-V. That was the app's most likely
  // first interaction and it was inert -- the one thing saving it was the
  // clipboard row on the front door, a feature that exists to make pasting
  // unnecessary and was quietly the only way to paste.
  //
  // Nil targets throughout, deliberately: these resolve through the responder
  // chain to whatever is being edited, which is exactly how every Mac app does it
  // and the only way one menu can serve two windows and a field editor that does
  // not exist until somebody clicks into a field.
  private static func editMenu() -> NSMenuItem {
    let item = NSMenuItem()
    let m = NSMenu(title: "Edit")
    m.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = m.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    m.addItem(.separator())
    m.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    m.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
    m.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    item.submenu = m
    return item
  }

  /// `⌘,`. The one keystroke every Mac user tries when they want to change
  /// something, and it reached nothing: this app's settings are behind a `…`
  /// button in the corner of a window, which is discoverable by looking and not by
  /// reflex. Both windows get it and each opens its own panel.
  private static func settingsItem(_ app: NSMenu, home: Bool) {
    let it = app.addItem(withTitle: "Settings\u{2026}",
                         action: home ? #selector(Target.homeSettings) : #selector(Target.more),
                         keyEquivalent: ",")
    it.target = Target.shared
  }

  static func install(appName: String = "Kin") {
    let main = NSMenu()

    // ── Tokkah ────────────────────────────────────────────────────────────────
    let appItem = NSMenuItem()
    let app = NSMenu()
    app.addItem(withTitle: "About \(appName)", action: #selector(Target.about), keyEquivalent: "")
      .target = Target.shared
    app.addItem(.separator())
    // ── ITS OWN STATEMENT, AND THE TARGET IS THE WHOLE POINT ──────────────────
    //
    // This item was inserted between the `addItem` above and its trailing
    // `.target = Target.shared` continuation, so the target landed on the NEXT
    // item and this one had none. It compiled -- an imported ObjC method is
    // implicitly @discardableResult -- and it did not read as broken either:
    // a nil-target item resolves its action through the RESPONDER CHAIN, `NSWindow`
    // has a public `-update`, so the item validated, drew ENABLED, posted a window
    // notification and never once reached `Target.update()`. Not even its own
    // "checking for updates…" feedback appeared. Third instance in this codebase of
    // a control that looks live and is not, so the target gets its own line and
    // cannot be orphaned by the next insertion.
    let check = app.addItem(withTitle: "Check for Updates…", action: #selector(Target.update),
                            keyEquivalent: "")
    check.target = Target.shared
    // Only meaningful while something is actually held. `Target` returns false from
    // validateMenuItem for it otherwise, so it greys out rather than being a
    // control that looks live and does nothing.
    let restart = app.addItem(withTitle: "Restart to Update", action: #selector(Target.restart),
                              keyEquivalent: "")
    restart.target = Target.shared
    app.addItem(.separator())
    settingsItem(app, home: false)
    app.addItem(.separator())
    let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    let servicesMenu = NSMenu()
    services.submenu = servicesMenu
    NSApp.servicesMenu = servicesMenu
    app.addItem(services)
    app.addItem(.separator())
    app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = app.addItem(withTitle: "Hide Others",
                                 action: #selector(NSApplication.hideOtherApplications(_:)),
                                 keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
                keyEquivalent: "")
    app.addItem(.separator())
    // Quit has to END THE CALL, not just stop the process: the far end is waiting
    // on a goodbye, and the camera light is the user's business.
    app.addItem(withTitle: "Quit \(appName)", action: #selector(Target.quit), keyEquivalent: "q")
      .target = Target.shared
    appItem.submenu = app
    main.addItem(appItem)
    main.addItem(editMenu())

    // ── Call ──────────────────────────────────────────────────────────────────
    let callItem = NSMenuItem()
    let call = NSMenu(title: "Call")
    let mute = call.addItem(withTitle: "Mute", action: #selector(Target.mic), keyEquivalent: "a")
    mute.keyEquivalentModifierMask = [.command, .shift]; mute.target = Target.shared
    let cam = call.addItem(withTitle: "Turn Camera Off", action: #selector(Target.cam), keyEquivalent: "v")
    cam.keyEquivalentModifierMask = [.command, .shift]; cam.target = Target.shared
    let rec = call.addItem(withTitle: "Record Call", action: #selector(Target.record), keyEquivalent: "r")
    rec.keyEquivalentModifierMask = [.command, .shift]; rec.target = Target.shared
    let openRec = call.addItem(withTitle: "Open Recordings in Finder", action: #selector(Target.openRecordings), keyEquivalent: "")
    openRec.target = Target.shared
    call.addItem(.separator())
    // ── THE THIRD DOOR TO THE PEOPLE PANEL ────────────────────────────────────
    //
    // The fast route is a tap on the peek button, and it has two problems a menu
    // item does not: it is undiscoverable, and it does not exist on an audio-only
    // call, where peek refuses to open a tile with no camera frames behind it. The
    // sheet's own People row is the second door. This is the one a person finds by
    // looking, and it is the only one that works with no pointer at all.
    let people = call.addItem(withTitle: "People…", action: #selector(Target.people), keyEquivalent: "p")
    people.keyEquivalentModifierMask = [.command, .shift]; people.target = Target.shared
    let copy = call.addItem(withTitle: "Copy Invite Link", action: #selector(Target.invite), keyEquivalent: "c")
    copy.keyEquivalentModifierMask = [.command, .shift]; copy.target = Target.shared
    // ── THE SHARE SHEET KEPT A DOOR ────────────────────────────────────────────
    //
    // `share` was a pill on the waiting card until the card became a link and a
    // button. Deleting the button without moving the action would have deleted the
    // feature: AirDrop and Messages are how an invite actually reaches somebody
    // sitting in the next room, and the clipboard is not a substitute for either.
    // A menu item is where a Mac keeps a capability that does not deserve a
    // permanent control.
    call.addItem(withTitle: "Share Invite…", action: #selector(Target.share),
                 keyEquivalent: "").target = Target.shared
    let code = call.addItem(withTitle: "Show Encryption Code", action: #selector(Target.more), keyEquivalent: "")
    code.target = Target.shared
    // The integrated VPN: the call, routed via Cloudflare's relay in South America
    // (Brazil / Chile) and back.
    let far = call.addItem(withTitle: "Integrated VPN", action: #selector(Target.farTest), keyEquivalent: "t")
    far.keyEquivalentModifierMask = [.command, .shift]; far.target = Target.shared
    call.addItem(.separator())
    // Command-Delete, the same key a Mac uses everywhere else for "get rid of it",
    // and it still asks: the menu arms the confirm exactly as the button does.
    let leave = call.addItem(withTitle: "Leave Call", action: #selector(Target.leave), keyEquivalent: "\u{8}")
    leave.keyEquivalentModifierMask = [.command]; leave.target = Target.shared
    callItem.submenu = call
    main.addItem(callItem)

    // ── Window ────────────────────────────────────────────────────────────────
    let winItem = NSMenuItem()
    let win = NSMenu(title: "Window")
    win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    win.addItem(.separator())
    // ── AND THE ONE A VIDEO CALL ACTUALLY WANTS ─────────────────────────────
    //
    // The window has `.resizable`, so full screen works from the green button --
    // and had no keyboard route and no menu entry, which on a Mac is where people
    // look for it. `⌃⌘F` is the system's own.
    let fs = win.addItem(withTitle: "Enter Full Screen",
                         action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    fs.keyEquivalentModifierMask = [.command, .control]
    win.addItem(.separator())
    win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    winItem.submenu = win
    main.addItem(winItem)
    NSApp.windowsMenu = win

    NSApp.mainMenu = main
  }

  // ── THE FRONT DOOR GETS A MENU BAR TOO ──────────────────────────────────────
  //
  // `install()` is called from `Display.open` only, so the home window -- the
  // first screen of the app, and the one a person sits looking at longest -- had
  // no Command-Q, no Command-W, no Command-M. The reflex fires and nothing
  // happens.
  //
  // Not `install()` itself: half of it is a Call menu whose every item reaches
  // `Menu.controls`, which is nil here. A greyed Mute is merely useless; a Mute
  // that LOOKS live (nil target resolves through the responder chain, so several
  // of those items would validate) is the dead-control defect this file already
  // carries a scar for. So the front door gets the two menus that mean something
  // with no call in progress, and `install()` replaces this wholesale when one
  // starts.
  static func installHome(appName: String = "Kin") {
    let main = NSMenu()

    let appItem = NSMenuItem()
    let app = NSMenu()
    app.addItem(withTitle: "About \(appName)", action: #selector(Target.about),
                keyEquivalent: "").target = Target.shared
    app.addItem(.separator())
    let check = app.addItem(withTitle: "Check for Updates…", action: #selector(Target.update),
                            keyEquivalent: "")
    check.target = Target.shared
    app.addItem(.separator())
    settingsItem(app, home: true)
    let openRec = app.addItem(withTitle: "Open Recordings in Finder", action: #selector(Target.openRecordings),
                              keyEquivalent: "")
    openRec.target = Target.shared
    app.addItem(.separator())
    app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)),
                keyEquivalent: "h")
    app.addItem(.separator())
    app.addItem(withTitle: "Quit \(appName)", action: #selector(Target.quit),
                keyEquivalent: "q").target = Target.shared
    appItem.submenu = app
    main.addItem(appItem)
    main.addItem(editMenu())

    let winItem = NSMenuItem()
    let win = NSMenu(title: "Window")
    win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m")
    win.addItem(.separator())
    // Nil target on purpose: this resolves through the responder chain to the key
    // window's own `performClose`, which is the SAME path the red button takes --
    // including the pump's exit on `!w.isVisible`.
    win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w")
    winItem.submenu = win
    main.addItem(winItem)
    NSApp.windowsMenu = win

    NSApp.mainMenu = main
  }

  // ── A MENU ITEM THE HARNESS CAN ACTUALLY CLICK ──────────────────────────────
  //
  // `--press` reaches the in-window bar and nothing else, so every menu item in
  // this file has only ever been tested by calling its handler -- which is the one
  // test that cannot see the defect these items actually had. The target was
  // missing; the handler was fine. So the harness gets a way in, by TITLE, and
  // uses the two AppKit calls a real click uses: `NSMenu.update()` (what opening
  // the menu does, and what decides whether the item is enabled) and
  // `performActionForItem` (what clicking it does, including resolving a nil
  // target through the responder chain).
  static func find(_ title: String) -> (NSMenu, Int)? {
    func walk(_ m: NSMenu) -> (NSMenu, Int)? {
      for (i, it) in m.items.enumerated() {
        if it.title == title { return (m, i) }
        if let sub = it.submenu, let hit = walk(sub) { return hit }
      }
      return nil
    }
    guard let root = NSApp.mainMenu else { return nil }
    return walk(root)
  }

  /// Clicks a menu item by title and describes what the click found, so a missing
  /// target is a line in the log rather than an absence in it.
  static func click(_ title: String) -> String {
    guard let (menu, idx) = find(title) else { return "NOT IN THE MENU" }
    let item = menu.items[idx]
    menu.update()                       // exactly what opening the menu does
    let owner = item.target.map { String(describing: type(of: $0)) } ?? "nil (responder chain)"
    let desc = "in \"\(menu.title)\" target=\(owner)"
             + " action=\(item.action.map { NSStringFromSelector($0) } ?? "-")"
             + " \(item.isEnabled ? "enabled" : "greyed")"
    guard item.isEnabled else { return desc + " -- not clicked, it is greyed" }
    menu.performActionForItem(at: idx)  // exactly what clicking it does
    return desc + " -- clicked"
  }

  /// One object to own the actions. `NSApp.mainMenu` items need a target that is
  /// alive for the life of the app, and the controls come and go with the window.
  final class Target: NSObject, NSMenuItemValidation {
    static let shared = Target()
    @objc func mic() { Menu.controls?.toggleMic(); Menu.controls?.nudgeBar() }
    @objc func cam() { Menu.controls?.toggleCam(); Menu.controls?.nudgeBar() }
    @objc func invite() { Menu.controls?.invite(); Menu.controls?.nudgeBar() }
    @objc func share() { Menu.controls?.share(); Menu.controls?.nudgeBar() }
    @objc func more() { Menu.controls?.nudgeBar(); Menu.controls?.openMore() }
    @objc func people() { Menu.controls?.nudgeBar(); Menu.controls?.openPeople() }
    @objc func leave() { Menu.controls?.nudgeBar(); Menu.controls?.leave() }
    @objc func farTest() {
      guard let f = FarTest.shared else { Menu.controls?.setStatus("Start a call first"); Menu.controls?.nudgeBar(); return }
      f.toggle()
      Menu.controls?.setStatus(f.short)
      Menu.controls?.nudgeBar()
    }
    @objc func record() {
      if CallRecorder.shared.isRecording {
        let summary = CallRecorder.shared.stop()
        Menu.controls?.setStatus("recording saved")
        fputs("\(summary)\n", stderr)
      } else {
        let url = CallRecorder.defaultRecordingURL()
        if CallRecorder.shared.start(to: url) {
          Menu.controls?.setStatus("recording call")
        }
      }
      Menu.controls?.nudgeBar()
    }
    @objc func openRecordings() {
      let dir = CallRecorder.recordingsDirectory()
      NSWorkspace.shared.open(dir)
    }
    @objc func quit() { Menu.onQuit?(); NSApp.terminate(nil) }
    /// The front door's own `…` button, from the keyboard. Set by `Launcher` while
    /// its window is up and cleared when it goes, so `⌘,` is greyed rather than
    /// silently dead once the call takes over.
    @objc func homeSettings() { Menu.onHomeSettings?() }
    /// The background poller already checks every minute; this just makes it check
    /// now.
    ///
    /// `urgent` and NOT the wire-mismatch flag, and the difference matters: this
    /// item used to share the one flag that also authorises committing an update
    /// THROUGH a live call, so somebody idly asking "is there an update?" in the
    /// middle of a conversation got the conversation restarted. Asking is not
    /// consenting. `urgent` now means only "check now instead of waiting out the
    /// poll interval"; the menu already has a separate, correctly-gated "Restart to
    /// Update" for a person who does want it to land immediately.
    @objc func update() {
      Update.checkNowForPerson()
      Menu.controls?.setStatus("checking for updates…")
    }
    /// The poller restarts on its own as soon as the call ends. This is for
    /// somebody who does not want to wait for that.
    @objc func restart() {
      guard Update.pending != nil else { return }
      Update.restartNow = true
      Menu.controls?.setStatus("restarting…")
    }
    /// A menu item that fires into a guard and does nothing is a dead control.
    /// Grey it out instead, so the menu tells the truth about whether an update
    /// is actually waiting.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
      if item.action == #selector(Target.restart) { return Update.pending != nil }
      // Same rule, same reason: an item whose handler returns into a nil optional
      // is a dead control, and a dead control that draws enabled is the defect
      // this file already carries two scars for.
      if item.action == #selector(Target.homeSettings) { return Menu.onHomeSettings != nil }
      if item.action == #selector(Target.more) { return Menu.controls != nil }
      if item.action == #selector(Target.record) {
        item.title = CallRecorder.shared.isRecording ? "Stop Recording" : "Record Call"
        return Menu.controls != nil
      }
      if item.action == #selector(Target.farTest) {
        let f = FarTest.shared
        item.state = (f?.mine == true) ? .on : .off
        if let f, f.mine {
          let c = f.activeCountry
          item.title = c.isEmpty ? "Integrated VPN" : "Integrated VPN (\(c))"
        } else if let f, f.theirs {
          let c = f.activeCountry
          item.title = c.isEmpty ? "Integrated VPN" : "Integrated VPN (Remote: \(c))"
        } else {
          item.title = "Integrated VPN"
        }
        return f != nil
      }
      return true
    }
    @objc func about() {
      let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? VERSION
      NSApp.orderFrontStandardAboutPanel(options: [
        .applicationVersion: v,
        .credits: NSAttributedString(
          string: "A video call that tries to be as fast as light allows.\n"
                + Server.inviteHost,
          attributes: [.font: NSFont.systemFont(ofSize: 11)]),
      ])
    }
  }
}
