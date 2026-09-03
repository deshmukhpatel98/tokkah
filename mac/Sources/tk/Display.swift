import AVFoundation
import CoreImage
import AppKit
import CoreMedia
import Foundation
import QuartzCore

// ── The window ──────────────────────────────────────────────────────────────
//
// AVSampleBufferDisplayLayer, not an NSImageView and not Metal-by-hand. It takes
// CMSampleBuffers straight to the compositor with no intermediate copy, and it is
// the only path on macOS where you can say "show this NOW" and be obeyed.
//
// DisplayImmediately is the whole point. Without it the layer honours the
// sample's presentation timestamp against a timebase, which is correct for
// playback and wrong for a call: on a call the frame is already as late as it
// will ever be, and any scheduling is latency added to a frame that has no future
// value. This is the same argument as no-B-frames, one stage later.
final class Display {
  private var win: NSWindow?
  /// Kept so the resize hook can be removed with the window. See `open`.
  private var resizeObserver: NSObjectProtocol?
  /// The window itself, for the one caller that needs to act on the WINDOW
  /// rather than on what is drawn inside it: an arriving call has to come
  /// forward, and "forward" is not a property of any view.
  var callWindow: NSWindow? { win }
  private let layer = AVSampleBufferDisplayLayer()
  // ── Yourself, in the corner ────────────────────────────────────────────────
  //
  // A second display layer, not compositing of our own: the window server already
  // composites layers for free, and the alternative is a shader written twice
  // (once here, once for Metal) and then kept agreeing with itself.
  //
  // It matters for a reason beyond vanity. Without it you cannot tell "my camera
  // is broken" from "they are not sending" from "the app is frozen" -- all three
  // look like a still picture of somebody else. Watching yourself move is the only
  // in-app proof that YOUR end works, which is why the web app has had it from
  // early on ("hold to see yourself") and why every video app on earth does.
  private let selfLayer = AVSampleBufferDisplayLayer()
  private(set) var selfShown = 0
  /// Kept only as "the far end is on screen", which is what decides whether YOUR
  /// camera goes to the window or nowhere. It no longer shows a corner tile: see
  /// `peeking`.
  var selfViewOn = false

  /// Where the corner view sits for a given content rect. One place, so the first
  /// layout and every resize cannot disagree about it.
  static func selfFrame(in r: NSRect) -> NSRect {
    // ── `#selfSense`, TRANSCRIBED ─────────────────────────────────────────────
    //
    //   #selfSense { left: 12px; bottom: max(76px, ...);
    //                width: clamp(96px, 18vmin, 160px); aspect-ratio: 16/9;
    //                border-radius: 12px; transform: scaleX(-1);
    //                box-shadow: 0 4px 18px rgba(0,0,0,.45) }
    //   #selfSense.peeking { width: clamp(140px, 26vmin, 240px) }
    //
    // Bottom-LEFT, not bottom-right, and the peeking width -- because peeking is
    // the only time it is ever on screen here.
    //
    // ── ON THE GUTTER, AND CLEAR OF THE ROW ───────────────────────────────────
    //
    // `x: 12, y: 76` were two numbers that belonged to nothing. 12 is not the
    // margin anything else in this app uses, and 76 was chosen when the control
    // row sat 14 points off the bottom edge -- it clears the row today by accident
    // rather than by construction, and the next time the row moves it stops
    // clearing it silently.
    //
    // `Metric.gutter` is the margin every other corner element uses, so the tile
    // lines up with the `more` button in the opposite corner. `barHeight` is the
    // row's own published height, so this cannot collide with it at any window
    // width -- which `y: 76` could, once a narrow window pushed the row's left
    // edge past the tile.
    let vmin = min(r.width, r.height)
    let w = max(140, min(vmin * 0.26, 240))
    let h = w * 9.0 / 16.0
    return NSRect(x: Metric.gutter, y: CallControls.barHeight, width: w, height: h)
  }

  // ── WHAT A PAUSED PICTURE LOOKS LIKE ───────────────────────────────────────
  //
  // Not a frozen frame. A held face is the most dishonest thing this app can
  // draw: it is indistinguishable from a crash, from a hang, and from someone
  // sitting very still, and people talk to it for thirty seconds before
  // realising. The blur says "this is not live" in the first tenth of a second,
  // without a word being read, and it says it in the picture itself rather than
  // in a caption somebody has to notice.
  //
  // It is the LAST frame, blurred once, not a blur applied per frame: there are
  // no new frames during a pause, so a repeated blur would be the same
  // computation over and over for an identical result. One CIGaussianBlur into
  // one CGImage, held as layer contents until the picture comes back.
  private let pauseLayer = CALayer()
  /// The one decoded frame kept alive so there is something to blur when the
  /// link gives out. Exactly one: a decoder pool can spare a buffer, and the
  /// alternative is having nothing to show at the moment it matters most.
  private var lastRemote: CVImageBuffer?
  /// The same frame, for the report thread's once-a-call face snapshot. A
  /// reference copy under ARC: the pool cannot recycle a buffer somebody still
  /// holds, and the reader never touches the layer tree.
  var lastRemoteForFace: CVImageBuffer? { lastRemote }
  private let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
  private(set) var peerPaused = false
  private(set) var selfPaused = false
  private(set) var peerCamOff = false

  private(set) var shown = 0, enqueueFails = 0
  /// Screen refresh period, so the display term in the budget is stated rather
  /// than quietly omitted: a frame handed to the compositor still waits, on
  /// average, half a refresh for the panel.
  private(set) var refreshMs: Double = 0

  /// The control bar, and the delegate that makes closing the window end the call.
  /// Held so neither is deallocated the moment `open` returns -- AppKit keeps only
  /// weak references to a window delegate.
  private(set) var controls: CallControls?
  private var keyMonitor: Any?
  private var closer: WindowCloser?

  /// `onLeave` is the hang-up control: it ends the call for both people.
  /// `onClose` is the red button and Command-Q: it puts the app away, and since a
  /// call now outlives its process those are two different acts. They were one
  /// closure, which is the `one-condition-two-concerns` shape this project keeps
  /// paying for -- and here it meant that closing a window hung up on somebody.
  /// `onClose` falls back to `onLeave` so a caller that has not been taught the
  /// difference behaves exactly as before rather than losing its window delegate.
  func open(title: String, w: Int, h: Int, room: String? = nil,
            onMic: ((Bool) -> Void)? = nil, onCam: ((Bool) -> Void)? = nil,
            onLeave: (() -> Void)? = nil, onClose: (() -> Void)? = nil,
            invite: String = "") {
    let onClose = onClose ?? onLeave
    let rect = NSRect(x: 0, y: 0, width: w, height: h)
    let window = NSWindow(contentRect: rect,
      styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = title
    // ── THE PICTURE RUNS UNDER THE TITLE BAR ──────────────────────────────────
    //
    // A standard title bar puts an opaque grey strip across the top of the window,
    // and the whole point of the layout below is that the picture is full-bleed and
    // the controls float on it. With the strip there, the window read as "a video
    // in an app" rather than "a call" -- FaceTime has no visible title bar at all,
    // and neither does the web app, because a face is the content and a chrome band
    // above it is just a smaller face.
    //
    // `.fullSizeContentView` extends the content under the bar; transparent and
    // hidden-title leave only the three traffic lights, which have to stay: they
    // are how a person closes a call window, and closing it ends the call.
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    // ── FULL SCREEN, SAID RATHER THAN INFERRED ────────────────────────────────
    //
    // A `.titled` `.resizable` window usually gets this for free, and "usually" is
    // not a property to ship: with it unstated, `toggleFullScreen:` validated as
    // GREYED under the rig's window level, so the Window menu offered an item that
    // could not be chosen. A video call is the app most likely to be run full
    // screen, and the state that made it unavailable was a default nobody had
    // written down.
    window.collectionBehavior.insert(.fullScreenPrimary)
    // ── A FLOOR UNDER THE LAYOUT ──────────────────────────────────────────────
    //
    // Every frame in this window is placed by hand in `layout()`, and none of that
    // arithmetic has a lower bound: the control row is four 58 pt circles plus
    // three 18 pt gaps plus a 20 pt gutter either side, which needs 344 pt before
    // anything overlaps, and the settings panel is 420 pt wide before it starts
    // being clamped to the window. Dragged narrower than that the row runs off its
    // own edges and the panel is wider than the thing it hangs inside.
    //
    // 480x320 is comfortably clear of both and still small enough to tuck a call
    // into a corner of a screen, which is the thing people actually do with one.
    // Stated rather than defended per-control: a minimum is one number in one
    // place, and clamping nine frames individually is nine places to forget.
    window.contentMinSize = NSSize(width: 480, height: 320)
    window.isMovableByWindowBackground = true
    window.backgroundColor = Palette.bg
    // ── A TEST WINDOW DOES NOT SIT WHERE SOMEBODY IS WORKING ─────────────────
    //
    // Centred is right for the product and wrong for a rig: measured repeatedly,
    // a person's trackpad taps landed on ring cards parked in the middle of their
    // screen -- real events, non-zero event numbers, subtype 3 -- and both the
    // rig's verdict and that person's afternoon suffered for it. Same switch that
    // stops the ringer taking the front.
    if ProcessInfo.processInfo.environment["TK_NO_RAISE"] == "1" {
      if let vis = NSScreen.main?.visibleFrame {
        window.setFrameOrigin(NSPoint(x: vis.minX + 4, y: vis.minY + 4))
      }
      // ── AND THE POINTER GOES STRAIGHT THROUGH IT ───────────────────────────
      //
      // Moving it into a corner was not enough: a 1280x720 window covers a good
      // deal of a laptop screen wherever it sits, and the taps kept landing. This
      // makes the window server route every real click to whatever is behind --
      // while `--press` is unaffected, because it delivers through `sendEvent`
      // and straight to the view, neither of which the window server sees. So the
      // harness can still click every control and the person at the keyboard
      // cannot click any of them by accident.
      window.ignoresMouseEvents = true
      // And BEHIND everything. Corner placement plus click-through still left a
      // 1280x720 window appearing over whatever the person at this Mac was
      // watching, again and again, as each rig launched. On the desktop level it
      // is under every ordinary window -- still composited, so `screencapture -l`
      // and the audit still see it, and invisible to somebody using their Mac.
      window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
      window.collectionBehavior.insert(.stationary)
    } else {
      window.center()
    }
    // ── LAYER-HOSTING VIEWS MUST NOT HAVE SUBVIEWS ────────────────────────────
    //
    // This was one view with `wantsLayer = true` AND a manually assigned layer,
    // which makes it layer-HOSTING rather than layer-backed, and Apple is explicit
    // that such a view may not have subviews. The control bar was added as a
    // subview of exactly that view, so it was never drawn -- not in a snapshot and
    // not on screen. Every attempt to photograph it came back blank, which read as
    // a broken camera and was actually the truth about the window.
    //
    // So: a plain container, the video surface as its own layer-hosting child, and
    // the bar as a SIBLING above it. Structure AppKit supports, and the bar draws.
    let root = NSView(frame: rect)
    let videoView = NSView(frame: rect)
    videoView.wantsLayer = true
    layer.frame = rect
    layer.videoGravity = .resizeAspect
    layer.backgroundColor = Palette.bg.cgColor
    videoView.layer = layer
    // A SUBLAYER of the hosted layer, not a subview. The comment above is explicit
    // that this layer-hosting view may not have subviews -- that mistake already
    // cost this file an invisible control bar. Sublayers are fine.
    selfLayer.videoGravity = .resizeAspectFill
    selfLayer.isHidden = true
    // ── CONCENTRIC WITH THE WINDOW ────────────────────────────────────────────
    //
    // This was the literal 12, and 12 turns out to be right -- but for a reason
    // nobody had written down, which is why it would not have survived the window
    // corner changing. A shape inset from a rounded container shares its centre of
    // curvature when its radius is the container's radius minus the inset, so a
    // tile 20 points inside a 32-point window corner wants exactly 12. Derived now,
    // so it tracks the window instead of agreeing with it by luck.
    selfLayer.cornerRadius = Metric.selfRadius
    selfLayer.masksToBounds = true
    // The same hairline the bar circles draw, so the corner tile is edged like
    // everything else floating on the picture rather than being the one thing with
    // no edge at all.
    selfLayer.borderWidth = 1
    // `transform: scaleX(-1)`. A self-view that is not mirrored is the one thing
    // everybody notices instantly and cannot name: you raise your left hand and the
    // wrong hand moves.
    selfLayer.transform = CATransform3DMakeScale(-1, 1, 1)
    // The web app's glass line. The hairline is the whole of the edge now.
    selfLayer.borderColor = Palette.fill(0.16).cgColor
    selfLayer.backgroundColor = Palette.bg.cgColor
    // ── AND NO DROP SHADOW ────────────────────────────────────────────────────
    //
    // `shadowOpacity = 0.45, shadowRadius = 14, offset (0, -4)`, so the tile threw
    // a soft black halo fourteen points out onto the far end's face. The argument
    // for it was that the corner should read as floating rather than punched in,
    // and that is a real thing a shadow does -- but it is also ink on somebody's
    // picture that fades across it, which is the one thing this pass is removing
    // everywhere else in the app. A dark cloud around a rectangle is a vignette
    // whether it is called a scrim or a shadow.
    //
    // The tile still reads as floating: it has the same 1 pt hairline every glass
    // control in the app has, and Liquid Glass draws its own specular rim beside
    // it. That is how everything else here says "above the picture".
    selfLayer.masksToBounds = true
    selfLayer.frame = Display.selfFrame(in: rect)
    // The blur covers the far end's picture and nothing else. It goes UNDER the
    // corner tile on purpose: your own camera is still running during their
    // pause, and blurring your own face for their bad link would be a lie about
    // whose connection is at fault.
    pauseLayer.frame = rect
    pauseLayer.isHidden = true
    pauseLayer.contentsGravity = .resizeAspect
    pauseLayer.backgroundColor = Palette.bg.cgColor
    pauseLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    layer.addSublayer(pauseLayer)
    layer.addSublayer(selfLayer)
    videoView.autoresizingMask = [.width, .height]
    root.addSubview(videoView)
    if let room {
      // FULL-WINDOW OVERLAY, not a strip. Information pills sit at the top, the
      // action bar floats at the bottom, and the picture runs full-bleed under
      // both -- which is what FaceTime does and what the web app does. As a strip
      // it could only ever be a black band across the bottom of someone's face.
      let c = CallControls(room: room, width: CGFloat(w))
      c.frame = rect
      c.onMic = onMic; c.onCam = onCam; c.onLeave = onLeave
      // The one control whose effect lives here rather than in main.swift.
      c.onPeek = { [weak self] on in
        self?.peeking = on
        fputs("peek \(on ? "on" : "off") localFrames=\(self?.localFrames ?? -1)"
            + " selfShown=\(self?.selfShown ?? -1) hidden=\(self?.selfLayer.isHidden ?? true)"
            + " frame=\(self?.selfLayer.frame ?? .zero)\n", stderr)
      }
      c.inviteText = invite
      root.addSubview(c)
      controls = c
      // The window has to accept mouse-moved events for the bar to know anything
      // is happening; without this the row would appear once and never come back.
      window.acceptsMouseMovedEvents = true
      c.armBarAutoHide()
      // A local monitor rather than `keyDown` on a view: the first responder here is
      // whatever AppKit last handed focus to, and a reflex like Escape has to work
      // from wherever the pointer happens to have left it.
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak c] e in
        (c?.handleKey(e) ?? false) ? nil : e
      }
      // A real menu bar, so Command-Q, Command-W and Command-M mean what they mean
      // everywhere else. Installed here because this is the path that has a window.
      Menu.controls = c
      // Command-Q is "put this away", not "hang up on them" -- same reasoning as
      // the red button below.
      Menu.onQuit = onClose
      Menu.install()
    }
    window.contentView = root
    // ── A WINDOW SOMEBODY DRAGGED BIGGER ─────────────────────────────────────
    //
    // `resize(w:h:)` exists for the far end changing shape and was the ONLY thing
    // that ever moved `selfLayer` -- which is a sublayer with no autoresizing mask,
    // so dragging the window's corner left the self-view tile pinned to where the
    // bottom-left of the OLD window used to be, floating in the middle of the
    // picture. The overlay resizes (it has a mask), the video layer resizes (it is
    // the hosted layer of a view that has one), and the one hand-placed layer did
    // not.
    //
    // The backdrop map is measured in window points too, so it has to be told the
    // new geometry in the same breath or every surface would dim for the rectangle
    // the window used to be.
    resizeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
        guard let self, let root = window.contentView else { return }
        let r = root.bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        self.layer.frame = r
        self.pauseLayer.frame = r
        self.selfLayer.frame = Display.selfFrame(in: r)
        CATransaction.commit()
        self.noteGeometry()
        Glass.refreshAllAdaptiveDim()
      }
    if let onClose {
      let cl = WindowCloser(onClose: onClose)
      window.delegate = cl
      closer = cl
    }
    noteGeometry()
    // ── WHAT THIS WINDOW CAN DO, SAID OUT LOUD ────────────────────────────────
    //
    // `toggleFullScreen:` validates against the window, so a rig can only ever
    // observe the ANSWER -- and under `TK_NO_RAISE` the answer is no, because the
    // window is parked at the desktop level on purpose and a window at an
    // abnormal level cannot go full screen. That is the rig's doing, not the
    // product's, and the two are indistinguishable from outside.
    //
    // So the window states what it asked for. `fullscreen=allowed` is a property
    // of the app; `level=desktop` is the rig explaining why the menu item is grey
    // in that mode and nowhere else.
    fputs("window: fullscreen=\(window.collectionBehavior.contains(.fullScreenPrimary) ? "allowed" : "REFUSED")"
        + " resizable=\(window.styleMask.contains(.resizable))"
        + " level=\(window.level == .normal ? "normal" : "desktop")\n", stderr)
    window.makeKeyAndOrderFront(nil)
    // A call window that opens behind whatever you were reading is a call you miss.
    // Every other call app on this machine comes forward when it starts; this one
    // opened unfocused, which also meant the first click on any control was spent
    // activating the app instead of pressing the button.
    //
    // ── EXCEPT UNDER TK_NO_RAISE, WHICH IT WAS IGNORING ──────────────────────
    //
    // The block forty lines up has moved this window into a corner, made it
    // click-through and put it on the desktop level, all so a rig cannot land on
    // top of somebody who is using their Mac -- and then this line took the whole
    // application to the front anyway. Every rig in `mac/tools` has been pulling
    // focus off whatever the person at this keyboard was doing, on every run,
    // while three separate comments explained why it must not.
    //
    // It surfaced as a measurement problem before anybody noticed it as a rudeness:
    // `NSGlassEffectView` renders markedly more opaque when its window is not the
    // active one, so whether the activation happened to win decided whether a
    // photograph of the card measured 0.67 or 0.16 of the picture surviving. Six
    // identical runs came out three of each, and each one was stable to three
    // decimal places within itself -- so either answer looked solid on its own.
    // `describeGlass` reports `active=` for this reason and `glass-check.sh`
    // refuses to compare two arms that were not in the same state.
    if ProcessInfo.processInfo.environment["TK_NO_RAISE"] != "1" {
      NSApp.activate(ignoringOtherApps: true)
    }
    win = window
    // ── SAY WHICH WINDOW THIS IS ───────────────────────────────────────────────
    //
    // The app's own snapshot renders the layer tree, and the layer tree does not
    // contain the picture: an AVSampleBufferDisplayLayer is composited by the
    // window server, and so is the glass blur behind the controls. So every design
    // photograph taken that way showed the bar over pure black -- which is judging
    // the one thing the redesign is not about. The controls exist to be legible
    // OVER A FACE.
    //
    // A window-server capture can see all of it, and printing the id is what makes
    // that capture safe: `screencapture -l <id>` photographs THIS window and
    // nothing else. The alternative, a plain screen grab, once captured the user's
    // own desktop -- a real screenshot of a game they were playing -- and that must
    // not be the way this app gets tested.
    fputs("window id \(window.windowNumber) -- screencapture -l \(window.windowNumber) -x out.png\n", stderr)
    if let sid = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
      let hz = CGDisplayCopyDisplayMode(CGDirectDisplayID(sid.uint32Value))?.refreshRate ?? 0
      refreshMs = hz > 0 ? 1000.0 / hz : 0
    }
  }

  /// Evidence that the window is really on screen, for when a screenshot is not
  /// available (a locked display captures only the desktop). `visible` and
  /// `occluded` together distinguish "no window" from "window behind something"
  /// from "window shown and being composited".
  var state: String {
    guard let w = win else { return "no-window" }
    let occ = w.occlusionState.contains(.visible) ? "onscreen" : "occluded"
    let st: String
    switch layer.status {
    case .rendering: st = "rendering"
    case .failed: st = "FAILED"
    case .unknown: st = "unknown"
    @unknown default: st = "?"
    }
    return "\(w.isVisible ? "visible" : "hidden")/\(occ)/layer:\(st)"
  }

  // ── The app photographs its own window ──────────────────────────────────────
  //
  // Checking a UI change meant a full-screen `screencapture`, which sweeps up
  // whatever else the person has open -- their messages, their tabs, their work.
  // That is not an acceptable price for looking at a button, and it was also
  // unreliable: the window is often behind something, and fronting it needs
  // accessibility permission the controlling process does not have.
  //
  // So the app renders its own view hierarchy. Only this window, never the desktop.
  // Note the video layer is composited by the window server rather than drawn by
  // the view, so it comes out empty here -- this photographs the CONTROLS, which is
  // the thing that needed looking at.
  /// What is actually in the window, printed. Four blank PNGs in a row taught the
  /// lesson: a capture that comes back empty cannot distinguish "nothing is there"
  /// from "the capture does not work", so the structure gets stated separately.
  var describeTree: String {
    guard let v = win?.contentView else { return "no content view" }
    var out = "content \(Int(v.bounds.width))x\(Int(v.bounds.height)) subviews \(v.subviews.count)"
    out += "  peeking=\(peeking) tile=\(selfLayer.isHidden ? "hidden" : "shown")"
      + " localFrames=\(localFrames) shown=\(shown) selfShown=\(selfShown)"
    if let c = controls { out += "\n  " + c.describeTree }
    out += ":"
    for sv in v.subviews {
      out += "\n    \(type(of: sv)) frame \(Int(sv.frame.origin.x)),\(Int(sv.frame.origin.y))"
        + " \(Int(sv.frame.width))x\(Int(sv.frame.height))"
        + " inWindow=\(sv.window != nil) hidden=\(sv.isHidden) layer=\(sv.layer != nil)"
        + " subviews=\(sv.subviews.count)"
    }
    return out
  }

  @discardableResult func snapshot(to path: String) -> Bool {
    guard let v = win?.contentView, let root = v.layer else { return false }
    let w = Int(v.bounds.width), h = Int(v.bounds.height)
    guard w > 0, h > 0 else { return false }
    // `cacheDisplay` came out BLANK WHITE: it drives `draw(_:)` down the view
    // hierarchy, and every view here is layer-backed with no drawing code of its
    // own -- a background colour on a CALayer is invisible to it. The layer tree
    // is what is actually on screen, so the layer tree is what gets rendered.
    // Draw-based now, so cacheDisplay works and is the honest one: it exercises the
    // same `draw(_:)` the screen does. Kept the layer path as a fallback for the
    // video surface, which the window server composites and no in-process capture
    // can see.
    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
      v.cacheDisplay(in: v.bounds, to: rep)
      if let png = rep.representation(using: .png, properties: [:]),
         (try? png.write(to: URL(fileURLWithPath: path))) != nil { return true }
    }
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
    else { return false }
    // CoreGraphics is origin-bottom-left and so is AppKit, but CALayer renders
    // top-down, so the context is flipped once here rather than the image being
    // flipped afterwards.
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    root.render(in: ctx)
    guard let img = ctx.makeImage() else { return false }
    let rep = NSBitmapImageRep(cgImage: img)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
  }

  func resize(w: Int, h: Int) {
    DispatchQueue.main.async { [weak self] in
      guard let self, let win = self.win else { return }
      var f = win.frame
      f.size = NSSize(width: w, height: h)
      win.setFrame(f, display: true)
      let r = NSRect(x: 0, y: 0, width: w, height: h)
      self.layer.frame = r
      self.pauseLayer.frame = r
      self.selfLayer.frame = Display.selfFrame(in: r)
      self.noteGeometry()
    }
  }

  /// Called from the decoder's output callback. Wraps the decoded buffer with no
  /// copy and asks for immediate display.
  /// Your own camera frame, into the corner. Same wrapping as `show`, different
  /// layer, and it returns immediately while the corner is hidden -- so before the
  /// call connects this costs one branch per frame, not a second enqueue.
  // ── peek: THE TWO PICTURES SWAP ────────────────────────────────────────────
  //
  // `#peek` in the web app -- "hold to see yourself" -- and the button existed here
  // with `onPeek` declared, called, and ASSIGNED NOWHERE. Pressing it did nothing
  // at all, which is what "the selfie feature is not working" was: a dead control,
  // the same class of defect as a camera picker that draws and picks nothing.
  //
  // Rather than covering the other person, the two pictures trade places: you take
  // the window, they take the corner. Same question answered -- "is my camera
  // alive" -- without losing sight of who is talking.
  // ── NO PERSISTENT MIRROR ────────────────────────────────────────────────────
  //
  // The web app has no ambient self-view at all, on purpose: *"No persistent mirror
  // (the #1 measured fatigue driver), no ambient tile: you look exactly when you
  // choose to, for exactly as long as you choose to."* This app had a corner tile
  // that appeared on the first remote frame and stayed for the whole call -- the
  // exact thing that design decision exists to prevent.
  //
  // So `peeking` is the only thing that puts it on screen, and releasing the button
  // takes it away.
  var peeking = false {
    didSet {
      guard peeking != oldValue else { return }
      let on = peeking
      // ── A HOLD OWNS THE MAIN THREAD ──────────────────────────────────────────
      //
      // This used to be an unconditional `DispatchQueue.main.async`, and holding the
      // button is exactly the moment that cannot wait for the main queue: the hold
      // is implemented as a nested `nextEvent(matching:)` loop, so the block that
      // was supposed to reveal the tile sat behind the hold that asked for it and
      // ran after the release -- which then immediately hid it again. The button
      // appeared to do nothing at all.
      let apply: () -> Void = { [weak self] in
        guard let self else { return }
        // AND ONLY IF THERE IS SOMETHING IN IT. Holding the button with no camera
        // permission put an empty box on screen -- reported as "a window is
        // appearing, but there is nothing to see", which is worse than no button:
        // it looks like the feature works and the camera is broken.
        if on, self.localFrames == 0 {
          fputs("peek: no camera frames to show -- not opening an empty tile."
              + " System Settings > Privacy & Security > Camera\n", stderr)
          self.selfLayer.isHidden = true
          return
        }
        self.selfLayer.isHidden = !on
        if !on { self.selfLayer.flushAndRemoveImage() }
      }
      if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }
  }
  /// Proof that our own camera is producing anything at all, which is what decides
  /// whether the tile has content to show.
  private(set) var localFrames = 0


  /// Your own camera. The window before anyone arrives, the peek tile while the
  /// button is held, and nowhere at all otherwise -- which is the whole point.
  func showSelf(_ img: CVImageBuffer) {
    localFrames += 1
    if peeking {
      if enqueue(img, into: selfLayer) { selfShown += 1 }
      return
    }
    // Before the far end arrives you ARE the window.
    if !selfViewOn {
      if enqueue(img, into: layer) { shown += 1 }
      // ...so YOU are also what is behind the glass, mirrored the way the layer
      // mirrors you. This is the state the front door and the whole wait before
      // somebody answers are in, which is where a bright room actually shows up.
      sampleBackdrop(img, mirrored: false)
    }
  }

  /// How bright the picture is, for the surfaces floating on it. The letterbox and
  /// the geometry are `Backdrop`'s own business now -- see `setGeometry` there for
  /// why they cannot be plain properties read from this thread.
  private func sampleBackdrop(_ img: CVImageBuffer, mirrored: Bool = false) {
    guard let pb = img as CVPixelBuffer? else { return }
    Backdrop.shared.sample(pb, mirrored: mirrored)
  }

  /// Tell the brightness map where the picture is. On main, at every point the
  /// window or the layer moves.
  func noteGeometry() {
    let r = layer.frame
    let h = win?.contentView?.bounds.height ?? r.height
    let w = win?.contentView?.bounds.width ?? r.width
    // TOP-LEFT origin: the map is built from a video frame, and every image format
    // on this machine counts rows downward while AppKit counts them up.
    Backdrop.shared.setGeometry(layerRect: CGRect(x: r.minX, y: h - r.maxY,
                                                  width: r.width, height: r.height),
                                windowSize: CGSize(width: w, height: h))
  }


  /// ── STOP SHOWING SOMEBODY THEIR OWN FROZEN FACE ──────────────────────────
  ///
  /// Before the far end arrives, YOU are the window -- a mirror, which is right
  /// while you are waiting. The moment they arrive `selfViewOn` turns on and
  /// `showSelf` stops feeding this layer, so if they have no camera the window
  /// keeps the LAST frame of you: a frozen face, in an app whose own HELD.md
  /// exists because a frozen face is the worst thing to show. Worse here,
  /// because it is a frozen face of the wrong person, and the banner above it
  /// says "their camera is off" -- so it reads as THEM, stopped.
  ///
  /// Flushed instead. The window becomes the app's own ground, the banner
  /// explains it, and their first real frame fills it the moment one arrives.
  func clearPicture() {
    DispatchQueue.main.async { [weak self] in
      self?.layer.flushAndRemoveImage()
      // Nothing is being shown, so nothing is behind the glass but the app's own
      // dark ground. Without this the surfaces keep the dim they were carrying for
      // a face that has gone.
      Backdrop.shared.clear()
    }
  }

  /// The far end's picture: always the window. Peeking puts YOU in the corner tile
  /// on top, it does not displace the person talking.
  func show(_ img: CVImageBuffer) {
    if enqueue(img, into: layer) {
      shown += 1
      noteFrameShown()
    }
    // How bright the thing behind the glass is. See `Backdrop.swift`: this is what
    // stops white glyphs from being drawn on white glass in a bright room, and it
    // costs a few dozen byte reads on a frame that is already in memory.
    sampleBackdrop(img)
    // Kept whether or not the enqueue succeeded: a layer that refused a frame is
    // exactly when having a picture to fall back on matters.
    lastRemote = img
  }

  // ── PAUSED: BLUR IT AND SAY SO ──────────────────────────────────────────────
  //
  // Called once a second from the reporter, off the main thread, so every touch
  // of the view tree is hopped onto main. Idempotent by design -- it is called
  // with the same values sixty times a minute and must do nothing on all but the
  // transitions.
  func setPaused(peer: Bool, selfSide: Bool, peerCamOff camOff: Bool, peerMuted muted: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let hideBlur = !peer
      let wasPeerPaused = self.peerPaused
      if peer != self.peerPaused || camOff != self.peerCamOff {
        self.peerPaused = peer
        self.peerCamOff = camOff
        CallRecorder.shared.setPaused(peer, peerCamOff: camOff)
        if hideBlur {
          self.pauseLayer.isHidden = true
          self.pauseLayer.contents = nil
        } else {
          // No frame yet means the link failed before the first picture ever
          // arrived. A flat panel is the honest answer; inventing one is not.
          self.pauseLayer.contents = self.lastRemote.flatMap { self.blur($0) }
          self.pauseLayer.isHidden = false
        }
      }
      // ── A DELIBERATE PAUSE IS NOT A FREEZE ───────────────────────────────
      //
      // `noteFrameShown` measures the gap between frames, and a sixteen-second
      // pause is a sixteen-second gap. Left alone it books the longest freeze of
      // the call, trips the "their face stopped moving" verdict, and reports a
      // feature working exactly as designed as the worst defect in the record.
      //
      // Zeroing the anchor on BOTH edges is what makes it correct: the entry
      // stops the gap being measured from the last live frame, and the exit
      // discards any stray in-flight frame that landed mid-pause and would
      // otherwise become the anchor the first real frame is measured against.
      if peer != wasPeerPaused { self.forgetFrameGap() }
      self.selfPaused = selfSide
      // PLAIN WORDS, NO NUMBERS. The readout that used to live over the picture
      // was a diagnostics panel and it was removed for being one. This is a
      // sentence a person acts on.
      let line: String
      // MUTE FIRST. It is the most actionable thing on this list -- you are
      // talking to somebody who cannot be heard, and every second you keep going
      // is wasted. A weak link is worth saying and it is worth saying second; it
      // comes back on its own the moment they unmute.
      if muted && camOff {
        line = "their microphone and camera are off"
      } else if muted {
        line = "their microphone is off"
      } else if peer && camOff {
        line = "their camera is off and their connection is weak"
      } else if peer {
        line = "their connection is weak \u{2014} video paused, audio is still on"
      } else if camOff {
        line = "their camera is off"
      } else if selfSide {
        line = "your connection is weak \u{2014} your video is paused, audio is still on"
      } else {
        line = ""
      }
      // ── THE SAME FACT, LARGE, AND SAID ONLY ONCE ──────────────────────────
      //
      // The pill is 12 pt in a corner and it fades with the row. When there is no
      // picture at all it is the ONLY thing on the screen saying so, which is how
      // an ordinary camera-off call came to look identical to a call that had
      // died. The poster puts the person's circle and name in the middle instead;
      // see `CameraOffPoster`.
      //
      // And when the poster is up it OWNS the sentence: a pill reading "their
      // camera is off" eight points above a face captioned "Camera off" is the
      // app saying one thing twice, in two registers, in two places. The pill
      // carries only what the poster does not.
      //
      // Only when there is genuinely nothing to look at. A weak link still shows
      // their blurred last frame, which is a picture of them and not a void.
      let blank = camOff || (peer && self.lastRemote == nil)
      if blank {
        self.controls?.setNoPicture(muted && camOff ? "Camera and microphone off"
                                    : camOff ? "Camera off" : "Reconnecting\u{2026}")
        // The link half is still worth a pill: "their camera is off" is a choice
        // they made and "their connection is weak" is not, and only the second
        // one tells you why the sound might go next.
        self.controls?.setWarning(peer && camOff
          ? "their connection is weak \u{2014} audio is still on" : "")
      } else {
        self.controls?.setNoPicture(nil)
        self.controls?.setWarning(line)
      }
    }
  }

  /// One frame, blurred hard enough that no detail survives. The radius scales
  /// with the frame so a 1080p pause is not sharper than a 720p one -- a blur
  /// specified in pixels means different things on different cameras, which is
  /// the same units bug that has bitten this codebase in three other places.
  private func blur(_ pb: CVImageBuffer) -> CGImage? {
    let ci = CIImage(cvImageBuffer: pb)
    let ext = ci.extent
    guard ext.width > 1, ext.height > 1 else { return nil }
    let radius = max(14.0, min(ext.width, ext.height) / 18.0)
    // `clampedToExtent` before the blur and a crop after it: without the clamp a
    // Gaussian samples past the edge, finds transparency, and draws a soft dark
    // frame around the whole picture that reads as a vignette nobody asked for.
    let out = ci.clampedToExtent()
      .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
      .cropped(to: ext)
    return ciCtx.createCGImage(out, from: ext)
  }

  // ── A FROZEN FACE IS THE FATIGUE, NOT THE LATENCY ───────────────────────────
  //
  // Every video number here was a RATE or an AVERAGE: 30 frames a second, 2 lost,
  // 0.6 ms to decode. All of them stay healthy through the thing people actually
  // find exhausting -- a face that holds still for a third of a second and then
  // jumps. Thirty frames arrived; they just did not arrive evenly, and an average
  // is exactly the wrong instrument for that.
  //
  // So: the longest a single frame stayed on screen, and how many times the gap
  // was long enough to see. 150 ms is where a held frame stops reading as motion
  // and starts reading as a stall; 400 ms is where people say "you froze".
  private(set) var freezeMaxMs = 0
  private(set) var freezes150 = 0
  private(set) var freezes400 = 0
  private var lastShownT: UInt64 = 0
  /// Drop the anchor the next gap would be measured from, so the next frame
  /// starts a fresh interval instead of closing one that spans a pause.
  func forgetFrameGap() { lastShownT = 0 }
  private func noteFrameShown() {
    let now = Clock.now()
    defer { lastShownT = now }
    guard lastShownT != 0 else { return }
    let gap = Int(Clock.msSigned(now, lastShownT))
    if gap > freezeMaxMs { freezeMaxMs = gap }
    if gap >= 150 { freezes150 += 1 }
    if gap >= 400 { freezes400 += 1 }
  }

  @discardableResult
  private func enqueue(_ img: CVImageBuffer, into target: AVSampleBufferDisplayLayer) -> Bool {
    var fmt: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: img,
      formatDescriptionOut: &fmt) == noErr, let fd = fmt else { enqueueFails += 1; return false }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: img,
      formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sb) == noErr,
      let s = sb else { enqueueFails += 1; return false }
    if let arr = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: true),
       CFArrayGetCount(arr) > 0 {
      let d = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(d,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    // A layer that has failed needs a flush before it will accept anything again;
    // without this a single transient error freezes the picture for the whole call
    // while every counter still reads healthy.
    if target.status == .failed { target.flush() }
    target.enqueue(s)
    return true
  }
}
