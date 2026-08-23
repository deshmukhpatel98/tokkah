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
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered, defer: false)
    window.title = title
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
    layer.backgroundColor = NSColor.black.cgColor
    videoView.layer = layer
    videoView.autoresizingMask = [.width, .height]
    root.addSubview(videoView)
    if let room {
      let c = CallControls(room: room, width: CGFloat(w))
      c.onMic = onMic; c.onCam = onCam; c.onLeave = onLeave
      c.inviteText = invite
      root.addSubview(c)
      controls = c
    }
    window.contentView = root
    if let onLeave {
      let cl = WindowCloser(onClose: onLeave)
      window.delegate = cl
      closer = cl
    }
    window.makeKeyAndOrderFront(nil)
    win = window
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
    if let c = controls { out += "  [micMuted=\(c.micMuted) camOff=\(c.camOff)]" }
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
      self.layer.frame = NSRect(x: 0, y: 0, width: w, height: h)
    }
  }

  /// Called from the decoder's output callback. Wraps the decoded buffer with no
  /// copy and asks for immediate display.
  func show(_ img: CVImageBuffer) {
    var fmt: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: img,
      formatDescriptionOut: &fmt) == noErr, let fd = fmt else { enqueueFails += 1; return }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: img,
      formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sb) == noErr,
      let s = sb else { enqueueFails += 1; return }
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
    if layer.status == .failed { layer.flush() }
    layer.enqueue(s)
    shown += 1
  }
}
