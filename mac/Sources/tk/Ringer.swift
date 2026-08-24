import AppKit

/// A ring you can hear AND see. A window that appears silently behind whatever
/// someone is doing is not a call arriving, and the whole point of the watcher
/// is to reach somebody who is not looking at Kin.
///
/// This file used to make a noise and stop there. It was wrong in a way that
/// only a real ring could show: the watcher launched Kin, Kin drew a perfect
/// incoming card, and the card came up UNDERNEATH the user's editor. The app's
/// own instrument said so in as many words -- `window visible/occluded` -- while
/// every handler test passed, because nothing in a handler test has anything in
/// front of it.
///
/// So a ring now does three things, and reports on all three:
///   - it makes a sound
///   - it bounces the dock icon until somebody looks
///   - it puts the window in front of every other app, on whatever Space the
///     user is actually on, and CHECKS that this worked
enum Ringer {
  private static var timer: Timer?
  private static var raised: NSWindow?
  private static var priorLevel = NSWindow.Level.normal
  private static var priorBehavior = NSWindow.CollectionBehavior()
  private static let lock = NSLock()

  /// `window` is the call window. Passing nil still rings audibly -- a ring with
  /// no window is worse, not a reason to stay quiet.
  static func start(raising window: NSWindow? = nil) {
    lock.lock()
    guard timer == nil else { lock.unlock(); return }
    let t = Timer(timeInterval: 2.5, repeats: true) { _ in play() }
    timer = t
    lock.unlock()

    Metrics.count("ring_ui_shown")
    NSApp.requestUserAttention(.criticalRequest)
    play()
    RunLoop.main.add(t, forMode: .common)
    // Stops itself after 40 s so a missed call does not ring the room all day.
    DispatchQueue.main.asyncAfter(deadline: .now() + 40) { stop() }

    guard let w = window else { Metrics.count("ring_no_window"); return }
    lock.lock()
    raised = w
    priorLevel = w.level
    priorBehavior = w.collectionBehavior
    lock.unlock()

    // ── WHY ALL FOUR OF THESE ─────────────────────────────────────────────────
    //
    // .floating          above the normal windows of every other app, which is
    //                    what "a call is arriving" means and what every other
    //                    call app on this Mac does.
    // canJoinAllSpaces   the user may be in a full-screen editor on another
    //                    Space. A normal window there is not merely behind, it
    //                    is on a different desktop and CANNOT be seen at all.
    // fullScreenAuxiliary  lets it sit over a full-screen app instead of forcing
    //                    a Space switch.
    // orderFrontRegardless  orders front even though this app is not active --
    //                    makeKeyAndOrderFront alone does nothing from the back.
    w.level = .floating
    w.collectionBehavior = [priorBehavior, .canJoinAllSpaces, .fullScreenAuxiliary]
    w.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)

    // Activation asked for during launch is frequently dropped on the floor by
    // macOS -- the app is not yet registered enough to be allowed to take the
    // front. One call is a coin flip; these retries are the difference between
    // ringing and not. They cost nothing once it has worked.
    for ms in [150, 400, 900, 1800] {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) {
        lock.lock(); let live = timer != nil && raised === w; lock.unlock()
        guard live, !NSApp.isActive else { return }
        w.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
      }
    }

    // ── AND THEN CHECK, because asking is not getting ─────────────────────────
    //
    // Four properties were set and the window still ended up behind: that is the
    // exact shape of the bug this code exists to fix, so the fix reports whether
    // it took. `occlusionState` is the window server's own answer to "can a human
    // see this", which is the question -- not "did we call the right method".
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
      lock.lock(); let live = timer != nil && raised === w; lock.unlock()
      guard live else { return }
      let visible = w.occlusionState.contains(.visible)
      Metrics.count(visible ? "ring_front_ok" : "ring_front_fail")
      Metrics.mark("ring_front_ms", sinceLaunch())
      if !visible {
        fputs("ring: the window did NOT reach the front -- the call is ringing"
            + " where nobody can see it\n", stderr)
      }
    }
  }

  static func stop() {
    lock.lock()
    timer?.invalidate(); timer = nil
    let w = raised; raised = nil
    let lvl = priorLevel, beh = priorBehavior
    lock.unlock()
    // Back to an ordinary window. A call you answered should not spend the next
    // hour floating over everything else you own.
    if let w { DispatchQueue.main.async { w.level = lvl; w.collectionBehavior = beh } }
  }

  private static func play() {
    // A named system sound rather than a bundled asset: nothing to ship, nothing
    // to license, and it is a sound this Mac already uses for attention.
    if let s = NSSound(named: "Submarine") { s.play() } else { NSSound.beep() }
  }
}
