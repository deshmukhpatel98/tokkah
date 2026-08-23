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

  static func install(appName: String = "Tokkah") {
    let main = NSMenu()

    // ── Tokkah ────────────────────────────────────────────────────────────────
    let appItem = NSMenuItem()
    let app = NSMenu()
    app.addItem(withTitle: "About \(appName)", action: #selector(Target.about), keyEquivalent: "")
      .target = Target.shared
    app.addItem(.separator())
    app.addItem(withTitle: "Check for Updates…", action: #selector(Target.update), keyEquivalent: "")
      .target = Target.shared
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

    // ── Call ──────────────────────────────────────────────────────────────────
    let callItem = NSMenuItem()
    let call = NSMenu(title: "Call")
    let mute = call.addItem(withTitle: "Mute", action: #selector(Target.mic), keyEquivalent: "a")
    mute.keyEquivalentModifierMask = [.command, .shift]; mute.target = Target.shared
    let cam = call.addItem(withTitle: "Turn Camera Off", action: #selector(Target.cam), keyEquivalent: "v")
    cam.keyEquivalentModifierMask = [.command, .shift]; cam.target = Target.shared
    call.addItem(.separator())
    let copy = call.addItem(withTitle: "Copy Invite Link", action: #selector(Target.invite), keyEquivalent: "c")
    copy.keyEquivalentModifierMask = [.command, .shift]; copy.target = Target.shared
    let code = call.addItem(withTitle: "Show Encryption Code", action: #selector(Target.more), keyEquivalent: "")
    code.target = Target.shared
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
    win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    winItem.submenu = win
    main.addItem(winItem)
    NSApp.windowsMenu = win

    NSApp.mainMenu = main
  }

  /// One object to own the actions. `NSApp.mainMenu` items need a target that is
  /// alive for the life of the app, and the controls come and go with the window.
  final class Target: NSObject {
    static let shared = Target()
    @objc func mic() { Menu.controls?.toggleMic(); Menu.controls?.nudgeBar() }
    @objc func cam() { Menu.controls?.toggleCam(); Menu.controls?.nudgeBar() }
    @objc func invite() { Menu.controls?.invite(); Menu.controls?.nudgeBar() }
    @objc func more() { Menu.controls?.nudgeBar(); Menu.controls?.openMore() }
    @objc func leave() { Menu.controls?.nudgeBar(); Menu.controls?.leave() }
    @objc func quit() { Menu.onQuit?(); NSApp.terminate(nil) }
    /// The background poller already checks every minute; this just makes it
    /// check now, using the same "the peer is on a different build" fast path.
    @objc func update() {
      Update.urgent = true
      Menu.controls?.setStatus("checking for updates…")
    }
    @objc func about() {
      let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? VERSION
      NSApp.orderFrontStandardAboutPanel(options: [
        .applicationVersion: v,
        .credits: NSAttributedString(
          string: "A video call that tries to be as fast as light allows.\n"
                + "room.tokkah.com",
          attributes: [.font: NSFont.systemFont(ofSize: 11)]),
      ])
    }
  }
}
