import AppKit
import AVFoundation

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
    // ── ONE CONDITION, TWO CONCERNS ──────────────────────────────────────────
    //
    // `timer` was the sound AND the "is this still ringing" flag that three later
    // closures test. With the sound now a looping player, the flag needs to exist
    // on its own -- so this timer's only job is to be that flag, and it fires
    // nothing.
    let t = Timer(timeInterval: 3600, repeats: false) { _ in }
    timer = t
    lock.unlock()

    Metrics.count("ring_ui_shown")
    // ── --mute MEANS THE SPEAKERS, NOT JUST THE CALL ─────────────────────────
    //
    // Reported by the person whose Mac this is, while they were watching
    // something: the test rigs kept ringing out loud. Every rig passes `--mute`,
    // and `--mute` silenced PLAYOUT -- the call audio -- because the ringtone is
    // an AVAudioPlayer that predates nothing and was simply never asked. A
    // switch called mute that leaves one sound playing is a switch nobody can
    // rely on. Same shape as one-condition-two-concerns, the other way round: two
    // sounds, one of them exempt from the only control over them.
    let quiet = flag("mute")
      || ProcessInfo.processInfo.environment["TK_MUTE"] == "1"
      || ProcessInfo.processInfo.environment["TK_NO_RAISE"] == "1"
    if quiet {
      fputs("ring: silent -- this copy is muted\n", stderr)
      Metrics.count("ring_tone_muted")
    } else {
      NSApp.requestUserAttention(.criticalRequest)
      startTone()
    }
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
    // ── A RIG DOES NOT NEED THE WHOLE MAC ────────────────────────────────────
    //
    // Everything below exists to put this window in front of whatever somebody is
    // doing, which is right for a ringing phone and wrong for a test: four ring
    // windows fighting for the front while a person uses their Mac means their
    // taps land on cards they cannot see, which is a real bug (the card refuses
    // them now) and also makes every windowed rig depend on whether anybody
    // happened to touch the trackpad. `firstrun-ring-check` is where the raising
    // itself is proved; every other rig sets this and is left alone.
    if ProcessInfo.processInfo.environment["TK_NO_RAISE"] == "1" {
      fputs("ring: not raising the window -- TK_NO_RAISE\n", stderr)
      return
    }
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
    stopTone()
    lock.lock()
    timer?.invalidate(); timer = nil
    let w = raised; raised = nil
    let lvl = priorLevel, beh = priorBehavior
    lock.unlock()
    // Back to an ordinary window. A call you answered should not spend the next
    // hour floating over everything else you own.
    if let w { DispatchQueue.main.async { w.level = lvl; w.collectionBehavior = beh } }
  }

  // ── THE SOUND A CALL MAKES ON A MAC ────────────────────────────────────────
  //
  // It was `NSSound(named: "Submarine")` on a 2.5 s timer -- a system ALERT, the
  // noise a Mac makes when something needs looking at. A call is not an alert, and
  // "Submarine" is what nothing else on this machine uses for a call, so an
  // arriving call sounded like a notification from an app nobody could name.
  //
  // Apple's own ringtones are already on every Mac, in the tone library FaceTime
  // and Messages draw from. Reading one is not shipping one: nothing is bundled,
  // nothing is redistributed, and the file only ever plays on the machine it came
  // from. `Reflection` is the current default; `Opening` was the default before
  // it and is still present on older systems, so it is the first fallback rather
  // than a guess. If the library has moved, a system alert is still better than
  // silence -- which is why the old path is the last rung and not deleted.
  private static let toneDir =
    "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/"
  private static var player: AVAudioPlayer?

  /// The ladder, tried in order, reported so a Mac that lands on a lower rung
  /// says which one. A ring that fell back silently would be indistinguishable
  /// from a ring that chose to sound like an alert.
  private static func startTone() {
    for name in ["Reflection", "Opening", "Marimba"] {
      let url = URL(fileURLWithPath: toneDir + name + ".m4r")
      guard FileManager.default.isReadableFile(atPath: url.path) else { continue }
      do {
        let p = try AVAudioPlayer(contentsOf: url)
        // A ringtone is a loop, not a sample. The old 2.5 s timer was a stand-in
        // for looping and it would have layered a 25 s tone on top of itself ten
        // times over.
        p.numberOfLoops = -1
        p.prepareToPlay()
        p.play()
        lock.lock(); player = p; lock.unlock()
        fputs("ring: sounding \(name) -- Apple's own ringtone\n", stderr)
        Metrics.count("ring_tone_apple")
        return
      } catch {
        fputs("ring: \(name).m4r would not play (\(error))\n", stderr)
      }
    }
    // No tone library on this Mac. An alert on a repeating timer, which is what
    // this always was.
    fputs("ring: no ringtone found -- falling back to a system alert\n", stderr)
    Metrics.count("ring_tone_fallback")
    let t = Timer(timeInterval: 2.5, repeats: true) { _ in
      if let s = NSSound(named: "Submarine") { s.play() } else { NSSound.beep() }
    }
    lock.lock(); alertTimer = t; lock.unlock()
    RunLoop.main.add(t, forMode: .common)
    if let s = NSSound(named: "Submarine") { s.play() } else { NSSound.beep() }
  }

  private static var alertTimer: Timer?

  private static func stopTone() {
    lock.lock()
    let p = player; player = nil
    let t = alertTimer; alertTimer = nil
    lock.unlock()
    p?.stop()
    t?.invalidate()
  }
}
