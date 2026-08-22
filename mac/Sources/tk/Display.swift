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

  func open(title: String, w: Int, h: Int) {
    let rect = NSRect(x: 0, y: 0, width: w, height: h)
    let window = NSWindow(contentRect: rect,
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered, defer: false)
    window.title = title
    window.center()
    let view = NSView(frame: rect)
    view.wantsLayer = true
    view.layer = CALayer()
    view.layer?.backgroundColor = NSColor.black.cgColor
    layer.frame = rect
    layer.videoGravity = .resizeAspect
    view.layer?.addSublayer(layer)
    window.contentView = view
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
