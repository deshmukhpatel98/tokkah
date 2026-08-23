import AVFoundation
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
    let vmin = min(r.width, r.height)
    let w = max(140, min(vmin * 0.26, 240))
    let h = w * 9.0 / 16.0
    return NSRect(x: 12, y: 76, width: w, height: h)
  }

  private(set) var shown = 0, enqueueFails = 0
  /// Screen refresh period, so the display term in the budget is stated rather
  /// than quietly omitted: a frame handed to the compositor still waits, on
  /// average, half a refresh for the panel.
  private(set) var refreshMs: Double = 0

  /// The control bar, and the delegate that makes closing the window end the call.
  /// Held so neither is deallocated the moment `open` returns -- AppKit keeps only
  /// weak references to a window delegate.
  private(set) var controls: CallControls?
  private var closer: WindowCloser?

  func open(title: String, w: Int, h: Int, room: String? = nil,
            onMic: ((Bool) -> Void)? = nil, onCam: ((Bool) -> Void)? = nil,
            onLeave: (() -> Void)? = nil, invite: String = "") {
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
    window.isMovableByWindowBackground = true
    window.backgroundColor = Palette.bg
    window.center()
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
    selfLayer.cornerRadius = 12
    selfLayer.masksToBounds = true
    selfLayer.borderWidth = 0
    // `transform: scaleX(-1)`. A self-view that is not mirrored is the one thing
    // everybody notices instantly and cannot name: you raise your left hand and the
    // wrong hand moves.
    selfLayer.transform = CATransform3DMakeScale(-1, 1, 1)
    // The web app's glass line, and a real shadow so the corner reads as floating
    // above the picture rather than punched into it.
    selfLayer.cornerRadius = 12
    selfLayer.borderColor = Palette.glassLine.cgColor
    selfLayer.backgroundColor = Palette.bg.cgColor
    selfLayer.shadowColor = NSColor.black.cgColor
    selfLayer.shadowOpacity = 0.45
    selfLayer.shadowRadius = 14
    selfLayer.shadowOffset = CGSize(width: 0, height: -4)
    // masksToBounds clips the shadow, so the rounding is done by the corner radius
    // on a layer that is allowed to draw outside itself.
    selfLayer.masksToBounds = true
    selfLayer.frame = Display.selfFrame(in: rect)
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
        fputs("peek \(on ? "on -- you have the window" : "off")\n", stderr)
      }
      c.inviteText = invite
      root.addSubview(c)
      controls = c
      // The window has to accept mouse-moved events for the bar to know anything
      // is happening; without this the row would appear once and never come back.
      window.acceptsMouseMovedEvents = true
      c.armBarAutoHide()
    }
    window.contentView = root
    if let onLeave {
      let cl = WindowCloser(onClose: onLeave)
      window.delegate = cl
      closer = cl
    }
    window.makeKeyAndOrderFront(nil)
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
      self.selfLayer.frame = Display.selfFrame(in: r)
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
      DispatchQueue.main.async { [weak self] in
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
    if !selfViewOn { if enqueue(img, into: layer) { shown += 1 } }
  }


  /// The far end's picture: always the window. Peeking puts YOU in the corner tile
  /// on top, it does not displace the person talking.
  func show(_ img: CVImageBuffer) {
    if enqueue(img, into: layer) { shown += 1 }
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
