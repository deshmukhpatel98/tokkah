import AppKit

// ── The part that makes it an application ────────────────────────────────────
//
// Everything else in this program is about the twelve milliseconds above the
// speed of light. None of it mattered, because the window had no controls, no way
// to invite anyone, and closing it left the camera running with nothing on screen.
//
// ── AND THEN: IT HAS TO LOOK LIKE SOMETHING ─────────────────────────────────
//
// The first version was a flat black strip with stock AppKit buttons, and the
// verdict was fair: "just look wise, we need better -- our web app was way too
// good." So the design is not invented here, it is TAKEN from the web app, which
// already has one the author likes. Its variables, verbatim:
//
//   --fg #e8eaed   --muted #9aa4b2   --accent #60a5fa
//   --ok #4ade80   --warn #fbbf24    --bad #ef4444
//   --glass-bg rgba(10,14,22,.72)    --glass-line rgba(255,255,255,.14)
//   --glass-blur blur(18px) saturate(1.4)
//   circles for actions, 999px pills for information, a scrim under the bar
//
// Two surfaces, one design. A native app that looks like a different product from
// the web app of the same name is a worse outcome than either alone.
//
// Structurally this is now an OVERLAY filling the window rather than a strip at
// the bottom: information sits in pills at the top, actions float in a glass bar
// at the bottom, and the video runs full-bleed underneath all of it -- which is
// what FaceTime does, and what the web app does.
enum Palette {
  static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: a)
  }
  static let fg = hex(0xe8eaed)
  static let muted = hex(0x9aa4b2)
  static let accent = hex(0x60a5fa)
  static let ok = hex(0x4ade80)
  static let warn = hex(0xfbbf24)
  static let bad = hex(0xef4444)
  static let bg = hex(0x06080d)
  static let glass = NSColor(srgbRed: 10/255, green: 14/255, blue: 22/255, alpha: 0.72)
  static let glassLine = NSColor(white: 1, alpha: 0.14)
}

/// A rounded, blurred surface. `NSVisualEffectView` is the real thing -- the web
/// app's `backdrop-filter: blur(18px)` has an exact native counterpart and there is
/// no reason to fake it with a flat fill.
final class Glass: NSVisualEffectView {
  // ── DECORATION IS NOT A TARGET ─────────────────────────────────────────────
  //
  // The blur is a subview of the button it sits inside, so `hitTest` handed every
  // click to the glass and not to the button. Two consequences, both invisible in
  // a handler test: `acceptsFirstMouse` was asked of the glass (which says no), so
  // the first click on a background window was always eaten; and every audit that
  // started at the content view happily reported the right control was reachable.
  // A pane of glass has nothing to do with a click. It passes them through.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  init(radius: CGFloat, circle: Bool = false) {
    super.init(frame: .zero)
    material = .hudWindow
    blendingMode = .withinWindow
    state = .active
    appearance = NSAppearance(named: .vibrantDark)
    wantsLayer = true
    layer?.cornerRadius = radius
    layer?.masksToBounds = true
    layer?.borderWidth = 1
    layer?.borderColor = Palette.glassLine.cgColor
    layer?.backgroundColor = Palette.glass.cgColor
    _ = circle
  }
  required init?(coder: NSCoder) { fatalError() }
}

// ── THE WEB APP'S OWN ICONS, AS PATHS ───────────────────────────────────────
//
// SF Symbols were the wrong answer to "make it look like the web app". They are
// filled, weighted and shaped by Apple, and next to the web app's 1.8 px stroked
// line art they simply read as a different product -- which is exactly what was
// reported: "why don't we have the exact interface as we have in the web app".
//
// So the glyphs are the web app's, transcribed from `index.html` in its own 24x24
// viewBox and drawn with the same stroke width, round caps and round joins. One
// source of truth for a shape, in two languages, and they are the same shape.
enum Glyph {
  /// A 24x24-viewBox path, scaled into a square of any size at draw time.
  struct Shape { let build: (CGFloat) -> NSBezierPath; let filled: Bool }

  private static func path(_ box: CGFloat, _ draw: (NSBezierPath, CGFloat) -> Void) -> NSBezierPath {
    let p = NSBezierPath()
    // The SVG viewBox is y-down and AppKit is y-up, so every y below is written
    // as the SVG number and flipped once here. Transcribing pre-flipped numbers is
    // how a glyph ends up upside down and nobody can find the reason in the diff.
    draw(p, box / 24)
    let flip = NSAffineTransform()
    flip.scaleX(by: 1, yBy: -1)
    flip.translateX(by: 0, yBy: -box)
    p.transform(using: flip as AffineTransform)
    return p
  }

  private static func rr(_ p: NSBezierPath, _ k: CGFloat,
                         _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
    p.appendRoundedRect(NSRect(x: x * k, y: y * k, width: w * k, height: h * k),
                        xRadius: r * k, yRadius: r * k)
  }
  private static func m(_ p: NSBezierPath, _ k: CGFloat, _ x: CGFloat, _ y: CGFloat) {
    p.move(to: NSPoint(x: x * k, y: y * k))
  }
  private static func l(_ p: NSBezierPath, _ k: CGFloat, _ x: CGFloat, _ y: CGFloat) {
    p.line(to: NSPoint(x: x * k, y: y * k))
  }

  /// <rect x=9 y=3 width=6 height=10.5 rx=3/><path d="M5 11a7 7 0 0 0 14 0"/><path d="M12 18v3"/>
  static let mic = Shape(build: { box in path(box) { p, k in
    rr(p, k, 9, 3, 6, 10.5, 3)
    // The arc under the capsule: a semicircle of radius 7 centred at (12, 11).
    m(p, k, 5, 11)
    p.appendArc(withCenter: NSPoint(x: 12 * k, y: 11 * k), radius: 7 * k,
                startAngle: 180, endAngle: 0, clockwise: true)
    m(p, k, 12, 18); l(p, k, 12, 21)
  } }, filled: false)

  /// <rect x=2.5 y=6 width=13 height=12 rx=3/><path d="M15.5 10.5l6-3.5v10l-6-3.5z"/>
  static let cam = Shape(build: { box in path(box) { p, k in
    rr(p, k, 2.5, 6, 13, 12, 3)
    m(p, k, 15.5, 10.5); l(p, k, 21.5, 7); l(p, k, 21.5, 17); l(p, k, 15.5, 13.5)
    p.close()
  } }, filled: false)

  /// <circle cx=12 cy=9 r=3.2/><path d="M5.5 19c1.2-3 3.6-4.5 6.5-4.5s5.3 1.5 6.5 4.5"/>
  /// <rect x=2.8 y=3.2 width=18.4 height=17.6 rx=4.5/>  -- "hold to see yourself"
  static let peek = Shape(build: { box in path(box) { p, k in
    p.appendOval(in: NSRect(x: (12 - 3.2) * k, y: (9 - 3.2) * k, width: 6.4 * k, height: 6.4 * k))
    m(p, k, 5.5, 19)
    p.curve(to: NSPoint(x: 12 * k, y: 14.5 * k),
            controlPoint1: NSPoint(x: 6.7 * k, y: 16 * k), controlPoint2: NSPoint(x: 9.1 * k, y: 14.5 * k))
    p.curve(to: NSPoint(x: 18.5 * k, y: 19 * k),
            controlPoint1: NSPoint(x: 14.9 * k, y: 14.5 * k), controlPoint2: NSPoint(x: 17.3 * k, y: 16 * k))
    rr(p, k, 2.8, 3.2, 18.4, 17.6, 4.5)
  } }, filled: false)

  /// The camcorder body again with a double-headed arrow over it: the shape is
  /// already learned from the button next door, so the only new information is
  /// "go round to the next one". The web app's comment is explicit that two bare
  /// arcs read as a refresh icon at 22 px and cost someone a live call.
  static let flip = Shape(build: { box in path(box) { p, k in
    rr(p, k, 2.6, 10.2, 11.4, 10.2, 2.6)
    m(p, k, 13.9, 13.7); l(p, k, 19.4, 10.7); l(p, k, 19.4, 19.3); l(p, k, 13.9, 16.3)
    p.close()
    // `a 7.8 7.8 0 0 1 13.6 -0.8` -- a real elliptical arc, and the first version
    // guessed two cubic control points at it by eye. That is why the switch-camera
    // glyph did not match: the arc over the camera body was the wrong shape, and it
    // is the only part of this icon that carries the meaning.
    //
    // Solved rather than eyeballed. Chord (5.2,7.6)->(18.8,6.8) is 13.623 long, so
    // with r=7.8 the centre sits h=sqrt(r^2-(d/2)^2)=3.801 off the chord midpoint
    // (12.0,7.2) along its perpendicular. large-arc=0 with sweep=1 picks the centre
    // BELOW the chord, which is the one whose minor arc bulges upward over the
    // camera: (12.223, 10.994), swept from -154.2 deg to -32.5 deg.
    m(p, k, 5.2, 7.6)
    p.appendArc(withCenter: NSPoint(x: 12.223 * k, y: 10.994 * k), radius: 7.8 * k,
                startAngle: -154.2, endAngle: -32.5, clockwise: false)
    m(p, k, 18.9, 2.9); l(p, k, 18.9, 6.9); l(p, k, 14.9, 6.9)
    m(p, k, 5.1, 3.4); l(p, k, 5.1, 7.4); l(p, k, 9.1, 7.4)
  } }, filled: false)

  /// <circle r=9/><path d="M3 12h18"/><path d="M12 3a14.5 14.5 0 0 1 0 18a14.5 14.5 0 0 1 0-18"/>
  static let xlate = Shape(build: { box in path(box) { p, k in
    p.appendOval(in: NSRect(x: 3 * k, y: 3 * k, width: 18 * k, height: 18 * k))
    m(p, k, 3, 12); l(p, k, 21, 12)
    m(p, k, 12, 3)
    p.curve(to: NSPoint(x: 12 * k, y: 21 * k),
            controlPoint1: NSPoint(x: 18 * k, y: 8 * k), controlPoint2: NSPoint(x: 18 * k, y: 16 * k))
    p.curve(to: NSPoint(x: 12 * k, y: 3 * k),
            controlPoint1: NSPoint(x: 6 * k, y: 16 * k), controlPoint2: NSPoint(x: 6 * k, y: 8 * k))
  } }, filled: false)

  /// The handset, filled -- the only filled glyph, on the only filled button.
  static let leave = Shape(build: { box in path(box) { p, k in
    m(p, k, 2.6, 14.9)
    p.curve(to: NSPoint(x: 21.4 * k, y: 14.9 * k),
            controlPoint1: NSPoint(x: 7.8 * k, y: 9.8 * k), controlPoint2: NSPoint(x: 16.2 * k, y: 9.8 * k))
    l(p, k, 19.1, 17.2)
    p.curve(to: NSPoint(x: 17.0 * k, y: 17.2 * k),
            controlPoint1: NSPoint(x: 18.5 * k, y: 17.8 * k), controlPoint2: NSPoint(x: 17.6 * k, y: 17.8 * k))
    l(p, k, 15.5, 15.8)
    p.curve(to: NSPoint(x: 15.05 * k, y: 14.35 * k),
            controlPoint1: NSPoint(x: 15.15 * k, y: 15.45 * k), controlPoint2: NSPoint(x: 14.95 * k, y: 14.9 * k))
    l(p, k, 15.3, 13.05)
    p.curve(to: NSPoint(x: 8.8 * k, y: 13.05 * k),
            controlPoint1: NSPoint(x: 13.2 * k, y: 12.5 * k), controlPoint2: NSPoint(x: 10.9 * k, y: 12.5 * k))
    l(p, k, 9.05, 14.35)
    p.curve(to: NSPoint(x: 8.6 * k, y: 15.8 * k),
            controlPoint1: NSPoint(x: 9.15 * k, y: 14.9 * k), controlPoint2: NSPoint(x: 8.95 * k, y: 15.45 * k))
    l(p, k, 7.1, 17.2)
    p.curve(to: NSPoint(x: 5.0 * k, y: 17.2 * k),
            controlPoint1: NSPoint(x: 6.5 * k, y: 17.8 * k), controlPoint2: NSPoint(x: 5.6 * k, y: 17.8 * k))
    p.close()
  } }, filled: true)

  /// Three filled dots.
  static let more = Shape(build: { box in path(box) { p, k in
    for cx in [5.5, 12.0, 18.5] {
      p.appendOval(in: NSRect(x: (cx - 1.7) * k, y: (12 - 1.7) * k, width: 3.4 * k, height: 3.4 * k))
    }
  } }, filled: true)

  // `#c-hud`'s bar glyph was here. It had exactly one user -- the "Connection
  // numbers" row -- and that row is gone, so the glyph went with it. Not kept "for
  // parity": the web app's `#c-hud` is not something this app offers.

  /// `#c-safety`: <rect x=4 y=10.5 width=16 height=10.5 rx=2.5/><path d="M8 10.5V7a4 4 0 0 1 8 0v3.5"/>
  static let lock = Shape(build: { box in path(box) { p, k in
    rr(p, k, 4, 10.5, 16, 10.5, 2.5)
    m(p, k, 8, 10.5); l(p, k, 8, 7)
    // `a 4 4 0 0 1 8 0` -- a half circle of radius 4 centred at (12, 7). sweep=1
    // arcs UPWARD on screen, which is toward SMALLER y in this viewBox and therefore
    // BELOW the centre in the y-up space these paths are built in, so the angle
    // increases and the arc is counter-clockwise. `mic` next door has the opposite
    // sweep and is therefore clockwise; getting this backwards drew the shackle
    // inside the body and the padlock came out as a notched box.
    p.appendArc(withCenter: NSPoint(x: 12 * k, y: 7 * k), radius: 4 * k,
                startAngle: 180, endAngle: 360, clockwise: false)
    l(p, k, 16, 10.5)
  } }, filled: false)

  // The chain link went with the invite row it was drawn for. It had one user and
  // it is not in the web app's set either, so there is nothing it keeps parity with.

  /// The slash that appears over a glyph that is OFF: <path d="M4 4l16 16"/>.
  static let slash = Shape(build: { box in path(box) { p, k in
    m(p, k, 4, 4); l(p, k, 20, 20)
  } }, filled: false)

  /// <circle cx=12 cy=8.5 r=3.6/><path d="M5 19.5c1.3-3.4 3.9-5 7-5s5.7 1.6 7 5"/>
  /// `peek` without its frame -- the frame is what makes that one mean "see
  /// yourself", and a name is about a person, not a viewfinder.
  static let person = Shape(build: { box in path(box) { p, k in
    p.appendOval(in: NSRect(x: (12 - 3.6) * k, y: (8.5 - 3.6) * k,
                            width: 7.2 * k, height: 7.2 * k))
    m(p, k, 5, 19.5)
    p.curve(to: NSPoint(x: 19 * k, y: 19.5 * k),
            controlPoint1: NSPoint(x: 8 * k, y: 13 * k),
            controlPoint2: NSPoint(x: 16 * k, y: 13 * k))
  } }, filled: false)

  /// <path d="M6.5 17V10a5.5 5.5 0 0 1 11 0v7"/><path d="M4.5 17h15"/><path d="M10 20a2 2 0 0 0 4 0"/>
  static let bell = Shape(build: { box in path(box) { p, k in
    m(p, k, 6.5, 17); l(p, k, 6.5, 10)
    p.appendArc(withCenter: NSPoint(x: 12 * k, y: 10 * k), radius: 5.5 * k,
                startAngle: 180, endAngle: 0, clockwise: false)
    l(p, k, 17.5, 17)
    m(p, k, 4.5, 17); l(p, k, 19.5, 17)
    m(p, k, 10, 20)
    p.appendArc(withCenter: NSPoint(x: 12 * k, y: 20 * k), radius: 2 * k,
                startAngle: 180, endAngle: 0, clockwise: true)
  } }, filled: false)
}

// ── ONE CIRCLE, THE WEB APP'S ─────────────────────────────────────────────────
//
// `.icon-btn`, transcribed: 58 px in the bar, a 26 px glyph, `border-radius: 50%`,
// `--glass-bg` behind a 1 px `--glass-line`, and a real blur.
//
// The states are the part that was wrong before, not the shape. OFF does NOT fill
// the circle red -- it turns the GLYPH red and shows the slash, so the surface
// stays glass and `leave` remains the only filled control on the screen. Filling
// three circles red put two more of them next to the one irreversible button.
final class IconButton: NSButton {
  private let shape: Glyph.Shape
  private let glass = Glass(radius: 0)
  private var hovering = false
  /// Bar circles are 58; the corner `more` button is 48, like the web app.
  private let box: CGFloat

  /// Draws the glyph above the blur, and is transparent to the mouse so the
  /// button underneath still gets every click.
  final class Ink: NSView {
    weak var owner: IconButton?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirty: NSRect) { owner?.drawGlyph(in: bounds) }
  }
  private let ink = Ink()

  /// Muted, camera dark, translation off: red glyph plus the slash.
  var off = false { didSet { needsDisplay = true; ink.needsDisplay = true } }
  /// Active: `box-shadow: inset 0 0 0 1.5px rgba(255,255,255,.35)`.
  var on = false { didSet { needsDisplay = true; ink.needsDisplay = true } }
  /// The one filled control.
  var destructive = false { didSet { needsDisplay = true; ink.needsDisplay = true } }
  // ── PRESS AND HOLD ─────────────────────────────────────────────────────────
  //
  // `#peek` is `pointerdown` -> show, `pointerup` -> hide. Not a toggle: the web
  // app's own comment is explicit that a persistent mirror is "the #1 measured
  // fatigue driver", and hold-to-peek exists precisely to avoid it. Built here as
  // a mode on the button rather than a second button class, because everything
  // else about it -- the circle, the glass, the glyph -- is identical.
  var onHold: ((Bool) -> Void)?
  private(set) var holding = false

  // ── THE CIRCLE MORPHS IN PLACE ─────────────────────────────────────────────
  //
  //   .icon-btn.leave.confirming { width: 150px; border-radius: 24px; gap: 8px;
  //                                grid-auto-flow: column }
  //   .icon-btn.leave.confirming .lbl { display: block }
  //
  // "are you sure" is not a thing an icon can say, so the button says a word. Not
  // a modal: a modal over a live face is worse than the mistake it prevents, and it
  // moves the target under a finger that is already travelling.
  var confirmLabel: String?
  var confirming = false { didSet { needsDisplay = true; ink.needsDisplay = true } }

  init(_ shape: Glyph.Shape, size: CGFloat = 58, help: String) {
    self.shape = shape
    self.box = size
    super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
    isBordered = false
    title = ""
    toolTip = help
    setAccessibilityLabel(help)
    wantsLayer = true
    glass.frame = NSRect(x: 0, y: 0, width: size, height: size)
    glass.layer?.cornerRadius = size / 2
    addSubview(glass)
    // ── THE GLYPH HAS TO BE ABOVE THE BLUR ────────────────────────────────────
    //
    // `NSVisualEffectView` is a SUBVIEW, and subviews draw after their parent's
    // own `draw(_:)`. So the glass painted straight over every glyph and the row
    // came out as six empty discs -- except `leave`, whose glass is hidden because
    // it is filled, which is why exactly one button in the screenshot had an icon.
    // A convincing false negative: the drawing code was right the whole time.
    ink.frame = NSRect(x: 0, y: 0, width: size, height: size)
    ink.owner = self
    addSubview(ink)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                   owner: self, userInfo: nil))
  }
  override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true; ink.needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true; ink.needsDisplay = true }

  override func mouseDown(with event: NSEvent) {
    guard onHold != nil else { super.mouseDown(with: event); return }
    setHolding(true)
    startHoldWatchdog()
  }

  // ── A HOLD THAT NEVER ENDS ─────────────────────────────────────────────────
  //
  // `mouseUp` is the normal way out and it is not guaranteed to arrive. A test
  // found it first -- an open sheet ate the release and the self-view stayed on
  // screen for the rest of the call -- but the same thing happens to a person who
  // holds peek and then Command-Tabs away, and a self-view stuck on is not a
  // cosmetic bug. So the window server gets the last word: if no mouse button is
  // physically down, nothing is being held, whatever this view believes.
  private var watchdog: Timer?
  private func startHoldWatchdog() {
    watchdog?.invalidate()
    let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] timer in
      guard let self, self.holding else { timer.invalidate(); return }
      guard !self.syntheticHold else { return }
      if NSEvent.pressedMouseButtons & 1 == 0 { timer.invalidate(); self.setHolding(false) }
    }
    watchdog = t
    RunLoop.main.add(t, forMode: .common)
  }
  /// Set only by the click harness, whose "button" is not a finger and so is not
  /// visible to `pressedMouseButtons`. Nothing in the app sets it.
  var syntheticHold = false
  private func setHolding(_ on: Bool) {
    guard holding != on else { return }
    holding = on
    self.on = on
    onHold?(on)
  }
  /// For `--press`: a hold long enough to be photographed, then released.
  // ── A HOLD MUST NOT OWN THE MAIN THREAD ────────────────────────────────────
  //
  // The hold used to be a nested `while let e = window?.nextEvent(matching:)` loop,
  // which is the classic AppKit tracking idiom and was wrong here for one reason:
  // it blocks the main thread for as long as the finger is down. Everything the
  // hold is FOR then starves. Six seconds of holding peek enqueued 169 frames into
  // a visible layer with a correct frame and drew a black rectangle, because Core
  // Animation never got a turn to put them on screen.
  //
  // Plain `mouseUp` instead. After a `mouseDown` AppKit routes every following
  // mouse event to this view until the button comes up, wherever the pointer has
  // wandered to -- which is the release-anywhere behaviour the loop was written to
  // get, for free and without holding the thread hostage.
  override func mouseUp(with event: NSEvent) {
    guard onHold != nil else { super.mouseUp(with: event); return }
    setHolding(false)
  }
  override func mouseDragged(with event: NSEvent) {
    guard onHold == nil else { return }   // a hold survives the pointer leaving
    super.mouseDragged(with: event)
  }

  func simulateHold(_ on: Bool) { setHolding(on) }


  // ── THE FIRST CLICK COUNTS ─────────────────────────────────────────────────
  //
  // Without this, a click that arrives while the app is behind another window is
  // spent activating the app and thrown away: the button does nothing and you
  // click it again. On a call that is unacceptable -- "mute me now" is pressed
  // precisely when this window is NOT the one you were typing in, and the whole
  // point of a hang-up is that it works the first time. Apple's own call controls
  // accept first mouse for the same reason.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func layout() {
    super.layout()
    glass.frame = bounds
    glass.layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    glass.isHidden = destructive
    ink.frame = bounds
  }

  override func draw(_ dirty: NSRect) {
    let d = min(bounds.width, bounds.height)
    let circle: NSBezierPath = confirming
      ? NSBezierPath(roundedRect: bounds, xRadius: 24, yRadius: 24)
      : NSBezierPath(ovalIn: NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2,
                                    width: d, height: d))
    if destructive {
      // `.icon-btn.leave { background: var(--bad) }`, and #f26464 on hover.
      (hovering ? Palette.hex(0xf26464) : Palette.bad).setFill()
      circle.fill()
    }
    // `border: 1px solid var(--glass-line)`, brightening to .28 on hover.
    (destructive ? (hovering ? Palette.hex(0xf26464) : Palette.bad)
                 : NSColor(white: 1, alpha: hovering ? 0.28 : 0.14)).setStroke()
    circle.lineWidth = 1
    circle.stroke()
  }

  /// Called by the overlay, so it lands on top of the blur.
  fileprivate func drawGlyph(in bounds: NSRect) {
    let d = min(bounds.width, bounds.height)
    if confirming, let text = confirmLabel {
      // Glyph and word side by side, the pair centred: `gap: 8px`, 13px semibold.
      let gsize: CGFloat = 22
      let f = NSFont.systemFont(ofSize: 13, weight: .semibold)
      let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.white]
      let tw = (text as NSString).size(withAttributes: a)
      let total = gsize + 8 + tw.width
      var x = (bounds.width - total) / 2
      let g = shape.build(gsize)
      let t = NSAffineTransform()
      t.translateX(by: x, yBy: (bounds.height - gsize) / 2)
      g.transform(using: t as AffineTransform)
      NSColor.white.setFill(); NSColor.white.setStroke()
      if shape.filled { g.fill() } else {
        g.lineWidth = 1.8 * (gsize / 24); g.lineCapStyle = .round; g.lineJoinStyle = .round; g.stroke()
      }
      x += gsize + 8
      (text as NSString).draw(at: NSPoint(x: x, y: (bounds.height - tw.height) / 2), withAttributes: a)
      return
    }
    if on {
      // `box-shadow: inset 0 0 0 1.5px rgba(255,255,255,.35)`.
      let r = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        .insetBy(dx: 1.5, dy: 1.5)
      NSColor(white: 1, alpha: 0.35).setStroke()
      let ring = NSBezierPath(ovalIn: r); ring.lineWidth = 1.5; ring.stroke()
    }
    // 26 px of a 58 px circle, centred, stroke 1.8 scaled with it.
    let gsize = box >= 58 ? 26.0 : 22.0
    let g = shape.build(gsize)
    let colour: NSColor = destructive ? .white : (off ? Palette.bad : Palette.fg)
    let t = NSAffineTransform()
    t.translateX(by: (bounds.width - gsize) / 2, yBy: (bounds.height - gsize) / 2)
    g.transform(using: t as AffineTransform)
    colour.setStroke(); colour.setFill()
    if shape.filled {
      g.fill()
    } else {
      g.lineWidth = 1.8 * (gsize / 24)
      g.lineCapStyle = .round
      g.lineJoinStyle = .round
      g.stroke()
    }
    if off {
      let sl = Glyph.slash.build(gsize)
      sl.transform(using: t as AffineTransform)
      sl.lineWidth = 1.8 * (gsize / 24)
      sl.lineCapStyle = .round
      sl.stroke()
    }
  }
}

/// A 999px information pill: room name, call quality, a warning.
final class Pill: NSView {
  private let label = NSTextField(labelWithString: "")
  private let glass = Glass(radius: 13)
  var textColor: NSColor = Palette.fg { didSet { label.textColor = textColor } }

  init(font: NSFont = .systemFont(ofSize: 12, weight: .medium)) {
    super.init(frame: .zero)
    addSubview(glass)
    label.font = font
    label.textColor = Palette.fg
    label.backgroundColor = .clear
    label.isBordered = false
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }

  var text: String = "" {
    didSet {
      label.stringValue = text
      isHidden = text.isEmpty
      // MEASURE THE STRING, NOT THE FIELD. `intrinsicContentSize` under-reported
      // by enough to clip the last word: "clear" and "headphones" both lost their
      // tails inside a pill that was otherwise correctly placed, which reads as a
      // broken layout rather than a measurement bug. The font and the text are
      // both right here, so ask them directly.
      let font = label.font ?? .systemFont(ofSize: 12)
      let size = (text as NSString).size(withAttributes: [.font: font])
      let w = ceil(size.width) + 26
      let h: CGFloat = 27
      setFrameSize(NSSize(width: w, height: h))
      glass.frame = NSRect(x: 0, y: 0, width: w, height: h)
      glass.layer?.cornerRadius = h / 2
      // AND GIVE IT SLACK, because `size(withAttributes:)` is still a point or two
      // short of what the field draws -- the right side bearing of the last glyph
      // lands outside it. Sizing the label to EXACTLY the measured width sheared
      // the final letter off vertically: "studio · connected" lost the stem of its
      // "d", which looks like a broken layout and not a rounding error.
      //
      // So the label is wider than the text and centred, and the slack is spent
      // inside padding that is empty anyway. Centring is the part that matters: it
      // makes the fix independent of HOW wrong the measurement is, instead of
      // correct for exactly the amount of slack guessed here.
      label.alignment = .center
      label.lineBreakMode = .byClipping
      label.frame = NSRect(x: 4, y: (h - ceil(size.height)) / 2 + 1,
                           width: w - 8, height: ceil(size.height))
    }
  }
}

// ── `.sheet`, TRANSCRIBED ─────────────────────────────────────────────────────
//
//   .sheet { left:50%; bottom:0; width:min(92vw,420px);
//            border-radius: 20px 20px 0 0; padding: 10px 10px 26px;
//            background: var(--glass-text) /* rgba(8,11,18,.90) */;
//            border: 1px solid var(--glass-line); border-bottom: 0; }
//   .sheet .grip { width:36px; height:4px; border-radius:999px; rgba(255,255,255,.2) }
//   .sheet .row  { min-height:48px; padding:0 12px; border-radius:12px; font-size:14px;
//                  color: rgba(232,234,237,.86) }  hover: rgba(255,255,255,.06)
//   .sheet .row .tick { color: var(--ok); shown when data-on="1" }
//
// This is where the invite went. The web app has no link button in its row of six,
// and copying an invite is not a thing anyone does twice in a call -- but it is the
// whole flow ("the call just starts, you copy the link and share it"), so it is the
// first row of the sheet rather than something removed.
final class SheetRow: NSButton {
  private let glyph: Glyph.Shape?
  private let text: NSTextField
  private var hovering = false
  var checked = false { didSet { needsDisplay = true } }
  /// Held down. Drawn like hover, a shade stronger -- feedback under the finger.
  private var pressed = false { didSet { needsDisplay = true } }
  /// An action, not a toggle -- ruled off above so it never reads as a switch.
  var ruled = false { didSet { needsDisplay = true } }
  /// A fact about this call: nothing to press.
  var inert = false
  /// `.sheet .row .code` -- a monospaced value pinned right, for the encryption code.
  var value: String = "" { didSet { needsDisplay = true } }

  /// What this row actually says, for a test that has to read the screen.
  var spoken: String {
    text.stringValue + (checked ? " ✓" : "") + (value.isEmpty ? "" : " = \(value)")
  }

  // ── SAY WHICH WAY IS UP ────────────────────────────────────────────────────
  //
  // Left to the default, the tick drew as a caret and the divider landed one row
  // low -- two symptoms, one cause, and both of them look like arithmetic bugs
  // rather than a coordinate system. `NSButton` is not documented to be flipped
  // and the containing `Sheet` is not, so the geometry below was written for y-up
  // and is now guaranteed to get it.

  // ── THE FIRST CLICK COUNTS ─────────────────────────────────────────────────
  //
  // Without this, a click that arrives while the app is behind another window is
  // spent activating the app and thrown away: the button does nothing and you
  // click it again. On a call that is unacceptable -- "mute me now" is pressed
  // precisely when this window is NOT the one you were typing in, and the whole
  // point of a hang-up is that it works the first time. Apple's own call controls
  // accept first mouse for the same reason.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  // A row is one target, not a label with a row behind it. `hitTest` was handing
  // clicks to the `NSTextField` that draws the words -- which does nothing, and
  // whose `acceptsFirstMouse` says no -- so whether the row worked depended on
  // whether the window happened to be key. Same lesson as the glass: everything
  // inside a control is decoration.
  override func hitTest(_ point: NSPoint) -> NSView? {
    // `point` arrives in the SUPERVIEW's coordinates, so it belongs against
    // `frame`, which is also in the superview's coordinates. Converting it into our
    // own space first and then testing `frame` compares a local point to a parent
    // rectangle: it answers "no" for every row that is not near the sheet's origin,
    // which is every row.
    guard isEnabled, !isHidden else { return nil }
    return frame.contains(point) ? self : nil
  }

  // ── THE DRAWING FIX THAT DISABLED THE BUTTON ───────────────────────────────
  //
  // `NSButton.isFlipped` is `true`. Overriding it to `false` below is what makes
  // the tick and the divider land where they are drawn -- and it also silently
  // stopped every row from firing, because `NSButtonCell.trackMouse` lays out the
  // cell rect in the coordinate system the view claims and then tests the mouse
  // point in the other one. The cell decided the finger was outside itself, so it
  // returned "not a click" and no action was ever sent. The row still drew
  // perfectly, still highlighted on hover, still had a target and an action.
  //
  // So the click is tracked here instead, where the geometry is ours. `NSCell` is
  // not involved and cannot disagree with the drawing.
  override func mouseDown(with event: NSEvent) {
    pressed = true
    var inside = true
    while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
      inside = bounds.contains(convert(e.locationInWindow, from: nil))
      pressed = inside
      if e.type == .leftMouseUp { break }
    }
    pressed = false
    // Released outside the row is a cancelled press, the way every Mac button
    // behaves: you can slide off a row you did not mean to hit.
    guard inside, let t = target, let a = action else { return }
    NSApp.sendAction(a, to: t, from: self)
  }

  override var isFlipped: Bool { false }

  init(_ label: String, glyph: Glyph.Shape? = nil) {
    self.glyph = glyph
    text = NSTextField(labelWithString: label)
    super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 48))
    isBordered = false
    title = ""
    setAccessibilityLabel(label)
    text.font = .systemFont(ofSize: 14)
    text.textColor = NSColor(white: 232.0 / 255, alpha: 0.86)
    text.backgroundColor = .clear
    text.isBordered = false
    addSubview(text)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                   owner: self, userInfo: nil))
  }
  override func mouseEntered(with event: NSEvent) {
    guard !inert else { return }
    hovering = true; needsDisplay = true
  }
  override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
  override func resetCursorRects() {
    if !inert { addCursorRect(bounds, cursor: .pointingHand) }
  }

  override func layout() {
    super.layout()
    let x: CGFloat = glyph == nil ? 12 : 42
    text.frame = NSRect(x: x, y: (bounds.height - 18) / 2, width: bounds.width - x - 40, height: 18)
  }

  override func draw(_ dirty: NSRect) {
    if hovering || pressed {
      NSColor(white: 1, alpha: pressed ? 0.12 : 0.06).setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }
    if ruled {
      NSColor(white: 1, alpha: 0.09).setStroke()
      let line = NSBezierPath()
      line.move(to: NSPoint(x: 0, y: bounds.maxY - 0.5))
      line.line(to: NSPoint(x: bounds.width, y: bounds.maxY - 0.5))
      line.lineWidth = 1
      line.stroke()
    }
    text.textColor = NSColor(white: 232.0 / 255, alpha: checked ? 1.0 : 0.86)
    if let g = glyph {
      let size: CGFloat = 18
      let path = g.build(size)
      let t = NSAffineTransform()
      t.translateX(by: 12, yBy: (bounds.height - size) / 2)
      path.transform(using: t as AffineTransform)
      let ink = NSColor(white: 232.0 / 255, alpha: 0.86)
      ink.setStroke(); ink.setFill()
      if g.filled { path.fill() } else {
        path.lineWidth = 1.8 * (size / 24); path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.stroke()
      }
    }
    if !value.isEmpty {
      // `.sheet .code { font: 600 13px/1 ui-monospace; letter-spacing: .09em;
      //                 color: var(--fg) }`
      // `.sheet .code[data-pending="1"] { color: var(--muted); font-weight: 400;
      //                                  letter-spacing: 0 }`
      // The pending state is a DIFFERENT weight and colour on purpose: a dim "…"
      // reads as "not yet", where the same treatment as a real code reads as a
      // code that failed to print.
      let pending = value == "…"
      let f = NSFont.monospacedSystemFont(ofSize: 13, weight: pending ? .regular : .semibold)
      var a: [NSAttributedString.Key: Any] = [
        .font: f, .foregroundColor: pending ? Palette.muted : Palette.fg,
      ]
      if !pending { a[.kern] = 13.0 * 0.09 }
      let sz = (value as NSString).size(withAttributes: a)
      (value as NSString).draw(at: NSPoint(x: bounds.width - sz.width - 12,
                                          y: (bounds.height - sz.height) / 2),
                               withAttributes: a)
    }
    if checked {
      // `.tick`: stroke 2.2, var(--ok), right-aligned.
      let t = NSBezierPath()
      let x = bounds.width - 30, y = bounds.height / 2
      t.move(to: NSPoint(x: x, y: y))
      t.line(to: NSPoint(x: x + 4.5, y: y - 4.5))
      t.line(to: NSPoint(x: x + 14, y: y + 6))
      t.lineWidth = 2.2; t.lineCapStyle = .round; t.lineJoinStyle = .round
      Palette.ok.setStroke(); t.stroke()
    }
  }
}

/// `.sheet .hint { font-size: 11px; color: var(--muted); padding: 8px 12px 2px }`
final class SheetHint: NSView {
  private let label = NSTextField(labelWithString: "")
  init(_ text: String) {
    super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
    label.stringValue = text
    label.font = .systemFont(ofSize: 11)
    label.textColor = Palette.muted
    label.maximumNumberOfLines = 2
    label.lineBreakMode = .byWordWrapping
    label.backgroundColor = .clear
    label.isBordered = false
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    label.frame = NSRect(x: 12, y: 2, width: bounds.width - 24, height: bounds.height - 4)
  }
}

/// The panel itself: glass, rounded at the top only, with a grip.
final class Sheet: NSView {
  private let glass = Glass(radius: 0)
  private let grip = NSView()
  private(set) var rows: [SheetRow] = []

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    addSubview(glass)
    grip.wantsLayer = true
    grip.layer?.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
    grip.layer?.cornerRadius = 2
    addSubview(grip)
  }
  required init?(coder: NSCoder) { fatalError() }

  /// Rows and hints, in the order they should appear top to bottom.
  private var items: [NSView] = []
  /// See IconButton.acceptsFirstMouse.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// `e.clientY - y0 > 40` -- a downward drag throws the sheet away.
  var onSwipeDown: (() -> Void)?
  private var dragStart: CGFloat?
  override func mouseDown(with event: NSEvent) {
    dragStart = event.locationInWindow.y
    super.mouseDown(with: event)
  }
  override func mouseUp(with event: NSEvent) {
    if let y0 = dragStart, y0 - event.locationInWindow.y > 40 { onSwipeDown?() }
    dragStart = nil
    super.mouseUp(with: event)
  }

  func setItems(_ v: [NSView]) {
    items.forEach { $0.removeFromSuperview() }
    items = v
    rows = v.compactMap { $0 as? SheetRow }
    v.forEach(addSubview)
    needsLayout = true
  }

  private func height(of v: NSView) -> CGFloat { v is SheetHint ? 34 : 48 }

  /// 10 top padding + grip + the items + 26 bottom.
  var wantedHeight: CGFloat { 10 + 14 + items.reduce(0) { $0 + height(of: $1) } + 26 }

  override func layout() {
    super.layout()
    glass.frame = bounds
    // `border-radius: 20px 20px 0 0` -- rounded at the top, square where it meets
    // the bottom of the window, because that edge is not there.
    glass.layer?.cornerRadius = 20
    glass.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    grip.frame = NSRect(x: (bounds.width - 36) / 2, y: bounds.height - 14, width: 36, height: 4)
    var y = bounds.height - 24
    for v in items {
      let h = height(of: v)
      y -= h
      v.frame = NSRect(x: 10, y: y, width: bounds.width - 20, height: h)
    }
  }
}

// ── `#waiting`, TRANSCRIBED ───────────────────────────────────────────────────
//
//   #waiting { position:absolute; inset:0; display:grid; place-items:center;
//              text-align:center; text-shadow: 0 1px 8px rgba(0,0,0,.85);
//              background: radial-gradient(ellipse at center,
//                            rgba(6,8,13,.55), transparent 72%); }
//   "Waiting for the other person…"                 16px
//   "This link is the key — anyone who has it can join"  12px, --muted
//   #shareUrl { width:320px; radius:999px; rgba(8,11,18,.9); 1px --glass-line; 12px mono }
//   #copy, #shareBtn { radius:999px; padding:9px 16px; 12px; --glass-text; glass }
//
// This is the whole first experience of the app: no name to invent, no lobby, no
// button to press before anything happens. The call is already live behind this
// card -- the card is only how you tell somebody else where it is.
final class WaitingCard: NSView {
  private let wash = CAGradientLayer()
  private let title = NSTextField(labelWithString: "Waiting for the other person…")
  private let hint = NSTextField(labelWithString: "This link is the key — anyone who has it can join")
  private let urlField = NSTextField(labelWithString: "")
  private let urlGlass = Glass(radius: 14)
  private let shareButton = PillButton("share")
  private let copyButton = PillButton("copy")
  // ── CALLING A NAME INSTEAD OF SENDING A LINK ────────────────────────────────
  //
  // The one editable thing in this app, and it lives here because this screen is
  // where somebody already is when they want to reach a person: the link is for
  // people you have never called, the field is for the ones you have.
  private let dialGlass = Glass(radius: 14)
  private let dialField = NSTextField()
  private let callButton = PillButton("call")
  private let answerButton = PillButton("answer")
  private let declineButton = PillButton("decline")
  var url = "" { didSet { urlField.stringValue = url; needsLayout = true } }
  var onCopy: (() -> Void)?
  var onShare: (() -> Void)?
  /// A handle was typed and confirmed. The card does not know how to ring, only
  /// that somebody asked to.
  var onCall: ((String) -> Void)?
  var onAnswer: (() -> Void)?
  var onDecline: (() -> Void)?

  /// Somebody is ringing. Set to switch the card from "invite" to "answer": the
  /// two states share a layout on purpose, because they are the same screen
  /// answering the same question -- who is going to be on this call.
  private(set) var incoming: (from: String, room: String)?

  func setIncoming(from: String, room: String) {
    incoming = (from, room)
    title.stringValue = "@\(from) is calling"
    hint.stringValue = "answer and you will both be in the same room"
    applyMode()
  }

  func clearIncoming() {
    incoming = nil
    title.stringValue = "Waiting for the other person…"
    hint.stringValue = "This link is the key — anyone who has it can join"
    applyMode()
  }

  /// One place decides what is on screen, so the two states cannot both be.
  private func applyMode() {
    let ringing = incoming != nil
    for v in [urlGlass, urlField, shareButton, copyButton, dialGlass, dialField, callButton] {
      v.isHidden = ringing
    }
    answerButton.isHidden = !ringing
    declineButton.isHidden = !ringing
    needsLayout = true
    needsDisplay = true
  }

  /// What is typed in the field, cleaned up the way the server will see it.
  private func dialled() -> String? {
    let raw = dialField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return Identity.sanitize(raw.hasPrefix("@") ? String(raw.dropFirst()) : raw)
  }

  @objc private func dialConfirmed() {
    guard let h = dialled() else { Metrics.tap("call", ok: false); return }
    Metrics.tap("call")
    dialField.stringValue = ""
    onCall?(h)
  }

  /// `#copy:disabled { opacity: 1; color: var(--ok) }` -- "copied ✓" is a
  /// confirmation, not a dead control.
  func confirmCopied() {
    copyButton.title2 = "copied ✓"
    copyButton.tint = Palette.ok
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
      self?.copyButton.title2 = "copy"
      self?.copyButton.tint = Palette.fg
    }
  }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    // `radial-gradient(ellipse at center, rgba(6,8,13,.55), transparent 72%)`.
    wash.type = .radial
    wash.colors = [NSColor(srgbRed: 6/255, green: 8/255, blue: 13/255, alpha: 0.55).cgColor,
                   NSColor.clear.cgColor]
    wash.locations = [0, 0.72]
    wash.startPoint = CGPoint(x: 0.5, y: 0.5)
    wash.endPoint = CGPoint(x: 1.0, y: 1.0)
    layer?.addSublayer(wash)

    for (t, size, colour) in [(title, 16.0, Palette.fg), (hint, 12.0, Palette.muted)] as [(NSTextField, Double, NSColor)] {
      t.font = .systemFont(ofSize: size)
      t.textColor = colour
      t.alignment = .center
      t.backgroundColor = .clear
      t.isBordered = false
      // `text-shadow: 0 1px 8px rgba(0,0,0,.85)` -- a soft shadow is what keeps
      // white text legible over an unknown frame without putting it on a slab.
      t.shadow = { let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.85)
                   sh.shadowBlurRadius = 8; sh.shadowOffset = NSSize(width: 0, height: -1); return sh }()
      addSubview(t)
    }
    urlField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    urlField.textColor = Palette.fg
    urlField.alignment = .center
    urlField.backgroundColor = .clear
    urlField.isBordered = false
    urlField.isSelectable = true
    urlGlass.layer?.backgroundColor = NSColor(srgbRed: 8/255, green: 11/255, blue: 18/255, alpha: 0.9).cgColor
    addSubview(urlGlass)
    addSubview(urlField)
    shareButton.onPress = { [weak self] in self?.onShare?() }
    copyButton.onPress = { [weak self] in self?.onCopy?() }
    addSubview(shareButton)
    addSubview(copyButton)

    dialGlass.layer?.backgroundColor = NSColor(srgbRed: 8/255, green: 11/255,
                                               blue: 18/255, alpha: 0.9).cgColor
    dialField.font = .systemFont(ofSize: 13)
    dialField.textColor = Palette.fg
    dialField.alignment = .center
    dialField.backgroundColor = .clear
    dialField.drawsBackground = false
    dialField.isBordered = false
    dialField.isEditable = true
    dialField.isSelectable = true
    dialField.focusRingType = .none
    dialField.placeholderString = "call a name, like @devesh"
    // Enter sends the action. A field you have to reach for a button after is a
    // field people type into and then wonder why nothing happened.
    dialField.target = self
    dialField.action = #selector(dialConfirmed)
    addSubview(dialGlass)
    addSubview(dialField)
    // See the note above mouseDown: `call` commits on release, via the card.
    addSubview(callButton)

    answerButton.tint = Palette.ok
    // Deliberately NO `onPress` on these three: the card routes them through
    // mouseDown/mouseUp above so they commit on release. Wiring `onPress` as well
    // would give them a second, press-to-commit path -- the exact thing being
    // removed.
    answerButton.isHidden = true
    declineButton.isHidden = true
    addSubview(answerButton)
    addSubview(declineButton)
  }
  required init?(coder: NSCoder) { fatalError() }

  // ── A FULL-SURFACE OVERLAY MUST NOT EAT THE BAR ────────────────────────────
  //
  // `#waiting` is `inset: 0` so its wash is centred on the window rather than on a
  // box, which means it covers the buttons too. In CSS that is harmless -- the bar
  // has a higher z-index. Here it is a subview added last, so without this it would
  // swallow every click on mic, camera and leave, and the call would look frozen
  // while being perfectly fine.
  /// A card that appears the instant the app opens: its first click is the one
  /// that matters most, and it used to be eaten by activation.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// Only what is actually on screen, so the `?` audit cannot report a control
  /// the current mode has hidden.
  var clickTargets: [(String, NSView)] {
    if incoming != nil { return [("answer", answerButton), ("decline", declineButton)] }
    return [("share", shareButton), ("copy", copyButton), ("link", urlGlass),
            ("dial", dialField), ("call", callButton)]
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let p = convert(point, from: superview)
    // ── THE ONE THING THAT MUST NOT BE ROUTED TO SELF ────────────────────────
    //
    // Every other target here answers `self`, because the card handles its own
    // presses. A TEXT FIELD cannot work that way: typing needs it to become first
    // responder, and that only happens if the click actually reaches it. Routing
    // it to `self` like the rest would give a field that draws, highlights on
    // hover, and can never be typed into.
    if !dialField.isHidden, dialGlass.frame.contains(p) { return dialField }
    for v in [urlGlass, shareButton, copyButton, callButton, answerButton, declineButton]
    where !v.isHidden && v.frame.contains(p) { return self }
    return nil
  }

  // ── THE THREE CONSEQUENTIAL ONES COMMIT ON RELEASE ─────────────────────────
  //
  // Copy and share are harmless and fire on press, as they always have. Answer,
  // decline and call are not: answering joins a room, and a control that commits
  // on mouse-DOWN commits to whatever the pointer happened to be over. One
  // unattributed auto-answer during testing was enough -- press-then-release
  // inside the same pill is what every Mac button does, and it also lets somebody
  // slide off a pill they did not mean to hit.
  private var armed: NSView?

  /// The link itself copies when clicked -- `#shareUrl { cursor: pointer }`.
  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    armed = nil
    for v in [answerButton, declineButton, callButton] as [NSView]
    where !v.isHidden && v.frame.contains(p) { armed = v; return }
    if !urlGlass.isHidden, urlGlass.frame.contains(p) { onCopy?(); return }
    if !shareButton.isHidden, shareButton.frame.contains(p) { onShare?(); return }
    if !copyButton.isHidden, copyButton.frame.contains(p) { onCopy?(); return }
    super.mouseDown(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    let was = armed
    armed = nil
    guard let v = was, !v.isHidden, v.frame.contains(p) else {
      super.mouseUp(with: event); return
    }
    if v === answerButton { onAnswer?() }
    else if v === declineButton { onDecline?() }
    else if v === callButton { dialConfirmed() }
  }
  override func resetCursorRects() { addCursorRect(urlGlass.frame, cursor: .pointingHand) }

  override func layout() {
    super.layout()
    wash.frame = bounds
    let cx = bounds.midX, cy = bounds.midY
    title.frame = NSRect(x: 0, y: cy + 22, width: bounds.width, height: 22)
    hint.frame = NSRect(x: 0, y: cy + 2, width: bounds.width, height: 16)
    // `#shareBox { margin-top: 14px }`, the three controls centred as one row.
    let uw = min(320, bounds.width * 0.7), uh: CGFloat = 34
    let gap: CGFloat = 10
    let rowW = uw + gap + shareButton.frame.width + gap + copyButton.frame.width
    var x = cx - rowW / 2
    let y = cy - 16 - uh
    urlGlass.frame = NSRect(x: x, y: y, width: uw, height: uh)
    urlGlass.layer?.cornerRadius = uh / 2
    urlField.frame = NSRect(x: x + 12, y: y + (uh - 15) / 2, width: uw - 24, height: 15)
    x += uw + gap
    shareButton.frame.origin = NSPoint(x: x, y: y + (uh - shareButton.frame.height) / 2)
    x += shareButton.frame.width + gap
    copyButton.frame.origin = NSPoint(x: x, y: y + (uh - copyButton.frame.height) / 2)

    // The dial row, one row below the link row and built the same way, so the two
    // read as alternatives rather than as two unrelated features.
    let dw = min(260, bounds.width * 0.55)
    let drowW = dw + gap + callButton.frame.width
    var dx = cx - drowW / 2
    let dy = y - 12 - uh
    dialGlass.frame = NSRect(x: dx, y: dy, width: dw, height: uh)
    dialGlass.layer?.cornerRadius = uh / 2
    dialField.frame = NSRect(x: dx + 14, y: dy + (uh - 17) / 2, width: dw - 28, height: 17)
    dx += dw + gap
    callButton.frame.origin = NSPoint(x: dx, y: dy + (uh - callButton.frame.height) / 2)

    // Answering shares the link row's line: it is the same decision in the same
    // place, and `answer` sits on the left where `copy` is not.
    let arowW = answerButton.frame.width + gap + declineButton.frame.width
    var ax = cx - arowW / 2
    answerButton.frame.origin = NSPoint(x: ax, y: y + (uh - answerButton.frame.height) / 2)
    ax += answerButton.frame.width + gap
    declineButton.frame.origin = NSPoint(x: ax, y: y + (uh - declineButton.frame.height) / 2)
  }
}

/// `#copy, #shareBtn`: a 999 px glass pill with a word in it.
final class PillButton: NSView {
  /// See IconButton.acceptsFirstMouse.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  private let glass = Glass(radius: 14)
  private let label = NSTextField(labelWithString: "")
  private var hovering = false
  var onPress: (() -> Void)?
  var tint: NSColor = Palette.fg { didSet { label.textColor = tint } }
  private var title2Storage = ""
  var title2: String {
    get { title2Storage }
    set { setTitle(newValue) }
  }
  init(_ text: String) {
    super.init(frame: .zero)
    wantsLayer = true
    addSubview(glass)
    label.font = .systemFont(ofSize: 12, weight: .medium)
    label.alignment = .center
    label.backgroundColor = .clear
    label.isBordered = false
    addSubview(label)
    // NOT `title2 = text`. Swift does not run property observers during
    // initialisation, so the didSet that measures the word and sizes the pill never
    // fired -- both buttons existed, drew nothing, and occupied a zero-width frame.
    // Invisible and un-clickable, from one assignment that looks like it works.
    setTitle(text)
  }
  required init?(coder: NSCoder) { fatalError() }

  private func setTitle(_ t: String) {
    title2Storage = t
    label.stringValue = t
    let w = ceil((t as NSString).size(withAttributes: [.font: label.font!]).width) + 32
    setFrameSize(NSSize(width: w, height: 30))
    needsLayout = true
  }

  override func layout() {
    super.layout()
    glass.frame = bounds
    glass.layer?.cornerRadius = bounds.height / 2
    label.frame = NSRect(x: 4, y: (bounds.height - 15) / 2, width: bounds.width - 8, height: 15)
  }
  override func mouseDown(with event: NSEvent) { onPress?() }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class CallControls: NSView {
  /// Space at the bottom the video should not put anything important in. Published
  /// so the self-view sits above the bar rather than a second file guessing.
  /// `padding: 26px 12px 14px` around a 58 px circle.
  static let barHeight: CGFloat = 98

  private let roomPill = Pill(font: .systemFont(ofSize: 12, weight: .semibold))
  private let scrim = CAGradientLayer()
  /// ── THE READOUT IS A STRING NOW, NOT A VIEW ────────────────────────────────
  ///
  /// `qualityPill` used to draw this over the picture whenever the "Connection
  /// numbers" switch was on. The switch is gone, so nothing could ever have shown
  /// the pill again and it went with it. The SENTENCE is kept: `setQuality` still
  /// composes it, `describeTree` still reports it, so the harness that reads the
  /// screen and the `--press quality` token both still see what the call looked
  /// like. Removing the display is not removing the measurement.
  private(set) var qualityText = ""

  // THE ROW: mic, cam, peek, flip, leave. Translation is parked — not this
  // release. Flip hides itself with one camera exactly as `#flip` does.
  private let micButton = IconButton(Glyph.mic, help: "microphone")
  private let camButton = IconButton(Glyph.cam, help: "camera")
  private let peekButton = IconButton(Glyph.peek, help: "hold to see yourself")
  private let flipButton = IconButton(Glyph.flip, help: "switch camera")
  private let xlateButton = IconButton(Glyph.xlate, help: "live translation")
  private let leaveButton = IconButton(Glyph.leave, help: "leave call")
  /// `#more`, top-right corner, out of the thumb row -- 48 px, not 58.
  private let moreButton = IconButton(Glyph.more, size: 48, help: "more")
  private let sheet = Sheet()
  private let waiting = WaitingCard()
  /// `#status`: a pill, TOP-CENTRE, not a room name in the corner. The room's name
  /// is not something the web app ever shows -- the link is.
  private let statusPill = Pill(font: .systemFont(ofSize: 11))
  /// ── THE ONE WARNING THAT EARNS ITS PLACE OVER A FACE ───────────────────────
  ///
  /// The readout this replaces was a diagnostics panel -- millisecond figures
  /// behind a "Connection numbers" switch -- and it was removed for being one.
  /// This is not that. It carries a sentence, never a number, it appears only
  /// when the picture has actually stopped, and it explains a thing the person
  /// can otherwise only misread: a still face that is not a crash.
  ///
  /// Amber, not red. Red is for a call that has failed; this one is still
  /// working, and the audio -- which is the call -- has not lost a sample.
  private let warnPill = Pill(font: .systemFont(ofSize: 11, weight: .medium))
  // `#elapsed`, the mm:ss clock above the status pill, was here. Removed on
  // request; see the note in `init` for why that loses no signal.
  /// `.sheetScrim`: a click anywhere else closes the sheet, which is how every
  /// bottom panel on a phone behaves and the only way out that needs no aiming.
  private let sheetScrim = ScrimView()
  private let camPicker = NSPopUpButton()
  private let camGlass = Glass(radius: 13)
  private var camNames: [String] = []

  private(set) var micMuted = false
  private(set) var camOff = false
  var onMic: ((Bool) -> Void)?
  var onCam: ((Bool) -> Void)?
  var onLeave: (() -> Void)?
  var onCamPick: ((Int) -> Void)?
  var inviteText = "" { didSet { onMain { [weak self] in self?.waiting.url = self?.inviteText ?? "" } } }
  /// Set once the key exchange has happened; blank until then, and a blank code
  /// shows as "…" rather than as an empty row that reads as broken.
  private(set) var safetyCode = ""
  func setSafetyCode(_ c: String) {
    guard c != safetyCode else { return }
    safetyCode = c
    onMain { [weak self] in if self?.moreOpen == true { self?.rebuildSheet() } }
  }
  private let room: String
  private var startedAt: Date?
  private var status = "waiting for the other person"

  init(room: String, width: CGFloat) {
    self.room = room
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: 720))
    wantsLayer = true
    autoresizingMask = [.width, .height]

    // A scrim, so white text over a bright picture stays readable. The web app
    // does exactly this: linear-gradient(transparent, rgba(6,8,13,.72) 62%).
    //
    // ── THE DIRECTION HAS TO BE SAID OUT LOUD ─────────────────────────────────
    //
    // CAGradientLayer defaults to start (0.5, 0) -> end (0.5, 1), and in an
    // unflipped AppKit layer (0,0) is the BOTTOM. So [clear, dark] ran dark at the
    // TOP of the scrim and cleared toward the bottom: a hard dark edge straight
    // across the picture 190 pt up, and the buttons sitting on the brightest,
    // least-scrimmed part of it. Measured on a real frame: 97.6 average brightness
    // above the edge, 37.0 just below it, 139.2 at the very bottom -- precisely
    // backwards, and doing harm at both ends.
    //
    // It survived every screenshot because the app photographs its own layer tree,
    // which cannot see an AVSampleBufferDisplayLayer, so every check was a scrim
    // over black -- where a gradient between two invisible shades of nothing looks
    // correct whichever way round it is. A contrast device can only be judged
    // against the thing it is meant to give contrast against.
    scrim.startPoint = CGPoint(x: 0.5, y: 1)   // top of the scrim, transparent
    scrim.endPoint = CGPoint(x: 0.5, y: 0)     // bottom of the window, darkest
    scrim.colors = [NSColor.clear.cgColor,
                    NSColor(srgbRed: 6/255, green: 8/255, blue: 13/255, alpha: 0.72).cgColor]
    // 62% like the web app: full darkness is reached before the bottom and simply
    // stays, so the fade is gentle where it meets the picture and solid where the
    // buttons are.
    scrim.locations = [0, 0.62]
    layer?.addSublayer(scrim)

    for b in [micButton, camButton, peekButton, flipButton, leaveButton, moreButton] {
      addSubview(b)
    }
    micButton.target = self; micButton.action = #selector(toggleMic)
    camButton.target = self; camButton.action = #selector(toggleCam)
    peekButton.onHold = { [weak self] on in
      self?.onPeek?(on)
      self?.peeking = on
      // Counted on the way DOWN only, so one hold is one press and not two. It
      // was the last control on the bar that left no trace of having been used.
      if on { Metrics.tap("peek", ok: self?.peeking == true) }
    }
    flipButton.target = self; flipButton.action = #selector(nextCamera)
    leaveButton.target = self; leaveButton.action = #selector(leave)
    moreButton.target = self; moreButton.action = #selector(toggleMore)
    sheetScrim.isHidden = true
    // It was added, framed, and wired to nothing: `moreScrim` in the web app is
    // `onclick = () => setSheet(false)`, and here a click on it went nowhere, so the
    // only way to shut the sheet was to find the same 48 px disc again.
    sheetScrim.onClick = { [weak self] in self?.closeMore() }
    sheet.onSwipeDown = { [weak self] in self?.closeMore() }
    addSubview(sheetScrim)
    sheet.isHidden = true
    addSubview(sheet)
    rebuildSheet()
    // `#flip { display: none }` until there is more than one camera.
    // Translation is parked (not this release) — the globe is not in the row.
    flipButton.isHidden = true
    xlateButton.off = true
    xlateButton.isHidden = true
    // `.icon-btn.leave` is the only filled control on the screen -- the web app's
    // own rule, and the reason mic and camera turn their GLYPH red rather than
    // their whole circle. One filled thing per screen keeps the rest calm, and it
    // keeps the irreversible button the only one that looks irreversible.
    leaveButton.destructive = true

    // The room pill is gone from the call surface: `#status` says what is
    // happening and the waiting card says where the call is. A room NAME is a
    // detail of the old flow, and this window no longer has that flow.
    roomPill.isHidden = true
    addSubview(roomPill)
    statusPill.text = "waiting for the other person"
    addSubview(statusPill)
    warnPill.textColor = Palette.warn
    warnPill.text = ""
    addSubview(warnPill)
    // ── TWO THINGS THAT USED TO SIT OVER SOMEBODY'S FACE ──────────────────────
    //
    // `#hud`, the latency pill, was here behind an opt-in switch, and `#elapsed`,
    // the mm:ss call clock, was here unconditionally. Both are gone at the user's
    // request, and the reasoning is the same for both: this is a consumer app, and
    // a number laid over the person you are talking to is instrumentation wearing
    // the app's clothes. Every figure either one showed is still on stderr once a
    // second and in the telemetry beat.
    //
    // The clock had one real job -- a running counter over a frozen picture was the
    // only way to tell a dead call from a still one. That job now belongs to the
    // held/paused state, which says it in words instead of leaving a person to
    // interpret a number. The signal is not lost, the worse version of it is.
    waiting.onCopy = { [weak self] in
      guard let self else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(self.inviteText, forType: .string)
      self.waiting.confirmCopied()
      // Read the clipboard BACK. "The handler ran" is not the same claim as
      // "the link is on the clipboard", and only the second one is the feature.
      Metrics.tap("copy_link",
                  ok: NSPasteboard.general.string(forType: .string) == self.inviteText)
    }
    waiting.onShare = { [weak self] in self?.share() }
    waiting.onCall = { [weak self] h in
      self?.setStatus("calling @\(h)…")
      self?.onCall?(h)
    }
    waiting.onAnswer = { [weak self] in self?.onAnswerRing?() }
    waiting.onDecline = { [weak self] in
      self?.waiting.clearIncoming()
      self?.setStatus("declined")
      self?.onDeclineRing?()
    }
    addSubview(waiting)

    // The one stock control left, so it gets a glass backing rather than the grey
    // AppKit bezel that made the whole bottom-left corner look like a preferences
    // pane bolted onto a call.
    camGlass.isHidden = true
    addSubview(camGlass)
    camPicker.isHidden = true
    camPicker.isBordered = false
    camPicker.font = .systemFont(ofSize: 11, weight: .medium)
    camPicker.contentTintColor = Palette.fg
    camPicker.target = self
    camPicker.action = #selector(camPicked)
    addSubview(camPicker)
    setStatus(status)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let w = bounds.width, h = bounds.height
    scrim.frame = CGRect(x: 0, y: 0, width: w, height: 190)

    // ── `.bar`, TRANSCRIBED ───────────────────────────────────────────────────
    //
    //   .bar { position:absolute; left:0; right:0; bottom:0;
    //          padding: 26px 12px 14px; gap: 18px;
    //          display:flex; align-items:center; justify-content:center;
    //          background: linear-gradient(transparent, rgba(6,8,13,.72) 62%); }
    //   .bar .icon-btn { width:58px; height:58px }
    //
    // There is NO capsule behind the row. A rounded glass container holding four
    // circles was invented here and it is the single thing that made the native
    // window not look like the web app: the web app's buttons float individually
    // on the scrim, and the scrim IS the bar. The report was exact -- "why don't we
    // have the exact interface as we have in the web app" -- and the answer was
    // that this file was designed from the web app's colours instead of copied
    // from its layout.
    let bw: CGFloat = 58, gap: CGFloat = 18, bottomPad: CGFloat = 14
    let row = [micButton, camButton, peekButton, flipButton, leaveButton]
      .filter { !$0.isHidden }
    if leaveArmed {
      // `.bar.confirming .icon-btn:not(.leave) { width: 0; opacity: 0;
      //  pointer-events: none }` -- the row contracts to the one decision. Six
      // circles plus a 150 px pill overflowed a phone, and the overflow left a live
      // mute button under the finger already travelling toward "leave".
      for b in row where b !== leaveButton {
        b.frame = NSRect(x: w / 2, y: bottomPad, width: 0, height: bw)
        b.alphaValue = 0
      }
      leaveButton.frame = NSRect(x: (w - 150) / 2, y: bottomPad, width: 150, height: bw)
    } else {
      let rowW = CGFloat(row.count) * bw + CGFloat(max(0, row.count - 1)) * gap
      var x = (w - rowW) / 2
      for b in row {
        b.frame = NSRect(x: x, y: bottomPad, width: bw, height: bw)
        if barShown { b.alphaValue = 1 }
        x += bw + gap
      }
    }
    // `#more`: top-right, 14 px in, riding the same row as the pills but in the
    // corner the web app puts it in.
    moreButton.frame = NSRect(x: w - 48 - 14, y: h - 48 - 14, width: 48, height: 48)

    // `.sheet { left:50%; bottom:0; width:min(92vw,420px) }`
    let sw = min(w * 0.92, 420)
    let sh = sheet.wantedHeight
    sheet.frame = NSRect(x: (w - sw) / 2, y: 0, width: sw, height: sh)
    sheetScrim.frame = bounds
    sheet.isHidden = !moreOpen
    sheetScrim.isHidden = !moreOpen

    // ── CLEAR OF THE TRAFFIC LIGHTS ───────────────────────────────────────────
    //
    // The window uses `.fullSizeContentView` so the picture runs to the very top
    // edge, which means the close/minimise/zoom buttons now float over the content
    // -- and at a 20 pt top margin the room pill's rounded top sliced straight
    // through all three of them. The overlap could not exist before the title bar
    // went transparent, and it appeared the moment it did.
    //
    // 36 pt clears the standard 28 pt title bar area with room to spare, and BOTH
    // top pills use it so the top row stays level. One constant, so the left side
    // cannot drift away from the right.
    // `#waiting { inset: 0 }` -- it is the whole surface, so the wash is centred on
    // the window and not on a box.
    waiting.frame = bounds

    // `#status { top:14px; left:50%; translateX(-50%) }`. `#elapsed` used to sit
    // 18 pt below this; nothing takes its place, and the pill's own position is
    // measured from the top of the window rather than from the clock, so removing
    // it moves nothing.
    statusPill.setFrameOrigin(NSPoint(x: (w - statusPill.frame.width) / 2,
                                      y: h - statusPill.frame.height - 14))
    // THE SAME SLOT, and they cannot collide: `#status` hides itself once the
    // call connects, and the picture cannot pause before it connects. Giving the
    // warning its own row below would leave a permanent gap under a pill that is
    // almost never there.
    warnPill.setFrameOrigin(NSPoint(x: (w - warnPill.frame.width) / 2,
                                    y: h - warnPill.frame.height - 14))

    // The pills stack down the LEFT, because `#more` owns the top-right corner in
    // the web app and two things cannot have it. 36 pt clears the traffic lights,
    // which now float over the picture -- `.fullSizeContentView` put them there,
    // and at 20 pt the room pill sliced straight through all three.
    let topPad: CGFloat = 36
    // Was a stack of two; the quality pill below it is gone, so there is one.
    let py = h - roomPill.frame.height - topPad
    roomPill.setFrameOrigin(NSPoint(x: 20, y: py))
    // Bottom-left, level with the action bar.
    let cpW: CGFloat = 210, cpH: CGFloat = 28, cpY: CGFloat = 22 + (46 + 28 - cpH) / 2
    camGlass.frame = NSRect(x: 20, y: cpY, width: cpW, height: cpH)
    camGlass.layer?.cornerRadius = cpH / 2
    camGlass.isHidden = camPicker.isHidden
    camPicker.frame = NSRect(x: 30, y: cpY + 4, width: cpW - 20, height: cpH - 8)
  }

  // ── APPLY NOW IF WE ARE ALREADY ON MAIN ───────────────────────────────────
  //
  // These setters are called from the report thread, so they hop to main. But
  // `simulate` calls them FROM main, and `DispatchQueue.main.async` from the main
  // thread defers to the next loop iteration -- which is after the snapshot that
  // was supposed to photograph the result. The echo warning was set, photographed
  // as absent, and looked exactly like a warning that had never been wired up.
  private func onMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
  }

  func setStatus(_ s: String) {
    status = s
    onMain { [weak self] in
      guard let self else { return }
      self.statusPill.text = s
      self.needsLayout = true
    }
  }

  // ── PRESENCE IS A STATE, AND IT HAS TWO DIRECTIONS ──────────────────────────
  //
  // `markConnected` sets `waiting.isHidden = true`, and NOTHING set it back. A
  // one-way door: the other person left, and what you were left with was a dead
  // frame, no card, no link and nothing to do -- and with the sheet's "Copy invite
  // link" row now gone, no route to a link at all. That row was only ever safe to
  // remove because this exists.
  //
  // It is also the right screen on its own merits. "The other person left" IS the
  // waiting state; the app already has a screen for it, and that screen already
  // holds the link and both ways to copy it. There was never a second thing to
  // build, only a boolean that was never set back.
  //
  // Why this is not `markConnected` doing double duty: `markConnected` is called
  // behind `if !sawRemote` and therefore fires exactly once per process. It cannot
  // be what hides the card again when somebody comes BACK, and a card left on top
  // of a returning peer's picture is a worse bug than the one being fixed. So the
  // two directions live in one call that cannot be half-wired.
  func setPeerPresent(_ present: Bool) {
    onMain { [weak self] in
      guard let self else { return }
      // Re-stated, not trusted. `inviteText`'s observer is what normally pushes the
      // URL into the card, and it last ran before the call; this is the one place
      // that reads it back out after a whole call has happened.
      if !present { self.waiting.url = self.inviteText }
      // A ring that arrived and was never answered must not be sitting on this
      // card when the peer leaves and it comes back -- the room in it is long
      // expired, and "answer" would join an empty one.
      if !present { self.waiting.clearIncoming() }
      if present { self.sawPeer = true }
      self.waiting.isHidden = present
      // The control row must not fade out while this card is the only way off this
      // screen. Bounded pin, the same one `markConnected` uses.
      if !present { self.showBar(pin: true) }
      self.needsLayout = true
      self.layoutSubtreeIfNeeded()
    }
  }

  /// `#waiting.gone` -- the card goes the moment there is someone to look at, and
  /// `#status.gone`: "connected" is said once and then gets out of the face's way.
  func markConnected() {
    let first = startedAt == nil
    if first { startedAt = Date() }
    if first { onMain { [weak self] in self?.showBar(pin: true) } }
    onMain { [weak self] in
      guard let self else { return }
      self.waiting.isHidden = true
      self.statusPill.text = "connected"
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
        self?.statusPill.isHidden = true
      }
      self.needsLayout = true
    }
  }

  /// `share`: macOS has a real share sheet, so the button opens it rather than
  /// pretending a second copy button is a different feature.
  @objc func share() {
    Metrics.tap("share")
    let picker = NSSharingServicePicker(items: [inviteText])
    picker.show(relativeTo: .zero, of: self, preferredEdge: .minY)
  }

  /// Latency and the fraction of audio that had to be invented, once a second.
  /// Turns the numbers into a sentence and a colour.
  /// The picture stopped, and this says why in words. An empty string clears it.
  /// `Pill.text` hides itself when empty, so there is no second visibility flag
  /// to keep in agreement with the string -- the two have drifted apart in this
  /// file before.
  func setWarning(_ line: String) {
    guard line != warnText else { return }
    warnText = line
    warnPill.text = line
    if !line.isEmpty {
      // Re-centre: the pill resizes itself to the sentence, so the origin set at
      // layout time belongs to whatever text was there before.
      warnPill.setFrameOrigin(NSPoint(x: (frame.width - warnPill.frame.width) / 2,
                                      y: frame.height - warnPill.frame.height - 14))
      // A warning is worthless under a hidden bar. Showing the row also makes the
      // mic and camera buttons reachable at the exact moment somebody wants them.
      showBar()
    }
    fputs("warning: \(line.isEmpty ? "(cleared)" : line)\n", stderr)
  }
  private(set) var warnText = ""

  func setQuality(m2eMs: Double?, concealPct: Double, lossPct: Double) {
    var parts: [String] = []
    // The mm:ss call clock was updated from here. Removed on request. `startedAt`
    // STAYS: it is also what tells `markConnected` this is the first connection,
    // and what stops the control row from auto-hiding before the call has begun.
    var word = "", colour = Palette.fg
    if let ms = m2eMs, ms > 0 {
      parts.append("\(Int(ms.rounded())) ms")
      // Concealment outranks latency, deliberately: it is audio the listener never
      // heard, so a 40 ms call that drops nothing sounds better than a 15 ms one
      // that does.
      if concealPct > 1.0 { word = "breaking up"; colour = Palette.bad }
      else if concealPct > 0.1 { word = "patchy"; colour = Palette.warn }
      else if ms < 60 { word = "clear"; colour = Palette.ok }
      else if ms < 150 { word = "good"; colour = Palette.ok }
      else { word = "far away"; colour = Palette.warn }
    }
    if lossPct >= 0.5, colour == Palette.ok { word += " (repairing)" }
    if !word.isEmpty { parts.append(word) }
    // Composed and kept, shown nowhere.
    //
    // ASSIGNED ON MAIN, and that is not cosmetic: `reportLoop` calls this from its
    // own thread, and `describeTree` reads it from the main thread. A Swift String
    // is refcounted, so a plain cross-thread store here would be a torn retain --
    // the same class of bug as the path dictionaries in Net.swift. Every other
    // write in this function already went through `onMain` for the same reason.
    let text = parts.joined(separator: "  ·  ")
    onMain { [weak self] in self?.qualityText = text }
  }

  // ── THE ECHO WARNING IS GONE FROM THE SCREEN ──────────────────────────────
  //
  // There used to be a pill here reading "your room is loud -- try headphones"
  // above 0.30 correlation. It was removed on request: it fired often enough to
  // read as background noise rather than advice, it sat over the picture for the
  // rest of the call, and the person it interrupted usually could not act on it.
  // A warning that cannot be dismissed and cannot be acted on is a defect no
  // matter how true it is.
  //
  // The MEASUREMENT stays -- capture against playout, cross-correlated over a
  // 0-200 ms search -- because the delay estimator and the end-of-call summary
  // both read `audio.echoCorr`, and it is the only evidence we have that a room
  // is feeding the speaker back into the microphone. It goes to the log and the
  // telemetry beat and nowhere a person has to look. This function is kept as a
  // no-op so the one caller in the report loop stays where it is; if a future
  // treatment for echo is automatic rather than advisory, it lands here.
  func setEcho(_ correlation: Double) { _ = correlation }

  /// Shown only when there is more than one camera: a one-entry menu teaches
  /// nothing and takes the space of something that would.
  func setCameras(_ names: [String], current: Int) {
    camNames = names
    onMain { [weak self] in
      guard let self else { return }
      self.camPicker.removeAllItems()
      self.camPicker.addItems(withTitles: names)
      if current >= 0, current < names.count { self.camPicker.selectItem(at: current) }
      // The stock popup stays OFF the call surface. The web app has no dropdown on
      // the picture -- device choice lives in the sheet, and switching cameras is
      // `#flip`. A grey AppKit bezel over someone's face was the last thing in this
      // window that still looked like a preferences pane.
      self.camPicker.isHidden = true
      // `#flip { display: none }` -> shown only when there IS a next camera.
      self.flipButton.isHidden = names.count < 2
      self.rebuildSheet()
      self.needsLayout = true
    }
  }

  @objc private func camPicked() { onCamPick?(camPicker.indexOfSelectedItem) }

  @objc func toggleMic() {
    let before = micMuted
    defer { Metrics.tap("mic", ok: micMuted != before) }
    showBar(pin: true)
    micMuted.toggle()
    micButton.off = micMuted
    onMic?(micMuted)
    setStatus(micMuted ? "you are muted" : status.contains("muted") ? "connected" : status)
  }

  @objc func toggleCam() {
    let before = camOff
    defer { Metrics.tap("cam", ok: camOff != before) }
    showBar(pin: true)
    camOff.toggle()
    camButton.off = camOff
    onCam?(camOff)
  }

  // ── YOUR HANDLE, AND WHETHER ANYONE MAY RING IT ────────────────────────────
  //
  // Both are set from outside: this file draws and reports, and the network half
  // lives in Identity.swift. `handle` stays empty until the server has actually
  // agreed the name is ours, because a row inviting someone to share a name that
  // might belong to a stranger is worse than no row.
  private(set) var handle = ""
  private(set) var silent = false
  /// Someone pressed Silent. The app answers by calling `setSilent` back once the
  /// server has agreed -- the switch is not allowed to move on its own.
  var onSilent: ((Bool) -> Void)?
  /// A handle was dialled. The app rings it and joins the room it sent.
  var onCall: ((String) -> Void)?

  /// Dial without a pointer -- `--call`, and anything later that wants to start a
  /// call by name. Goes through exactly what the field goes through, so the two
  /// cannot drift apart.
  func dial(_ raw: String) {
    guard let h = Identity.sanitize(raw.hasPrefix("@") ? String(raw.dropFirst()) : raw) else {
      // Counted as a FAILED call, not skipped. A press that produced nothing is
      // the single most valuable thing this can record, and a counter that only
      // ever increments on success is decoration.
      Metrics.tap("call", ok: false)
      setStatus("that is not a name"); return
    }
    setStatus("calling @\(h)…")
    onCall?(h)
  }
  var onAnswerRing: (() -> Void)?
  var onDeclineRing: (() -> Void)?

  /// Somebody is ringing this Mac. Ignored while a call is already up: joining a
  /// second room would end the first one, and "call waiting" is not a thing this
  /// app claims to do.
  func showIncoming(from: String, room: String) {
    onMain { [weak self] in
      guard let self, self.waiting.isHidden == false || !self.sawPeer else { return }
      guard self.waiting.incoming == nil else { return }
      self.waiting.setIncoming(from: from, room: room)
      self.setStatus("@\(from) is calling")
      self.nudgeBar()
    }
  }

  func hideIncoming() { onMain { [weak self] in self?.waiting.clearIncoming() } }

  /// True once the far end has been seen, which is what makes a ring untimely.
  private var sawPeer = false

  func setHandle(_ h: String) {
    onMain { [weak self] in
      guard let self, self.handle != h else { return }
      self.handle = h
      if self.moreOpen { self.rebuildSheet() }
    }
  }

  func setSilent(_ on: Bool) {
    onMain { [weak self] in
      guard let self, self.silent != on else { return }
      self.silent = on
      if self.moreOpen { self.rebuildSheet() }
    }
  }

  @objc private func copyHandleRow(_ sender: SheetRow) {
    guard !handle.isEmpty else { Metrics.tap("copy_handle", ok: false); return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("@" + handle, forType: .string)
    Metrics.tap("copy_handle",
                ok: NSPasteboard.general.string(forType: .string) == "@" + handle)
    let was = status
    setStatus("@\(handle) copied")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in self?.setStatus(was) }
    closeMore()
  }

  @objc private func toggleSilentRow(_ sender: SheetRow) {
    Metrics.tap("silent")
    let want = !silent
    // Say what was asked for, not what is true yet. The switch itself only moves
    // when `setSilent` comes back, so a refusal leaves it where it was rather
    // than telling someone they are unreachable when they are not.
    setStatus(want ? "going silent…" : "turning silence off…")
    onSilent?(want)
    closeMore()
  }

  @objc func invite() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(inviteText, forType: .string)
    // Read it back. A copy button that reports success without checking is the
    // one control whose failure is completely invisible to the person using it.
    Metrics.tap("invite", ok: NSPasteboard.general.string(forType: .string) == inviteText)
    // Confirmed, briefly. A copy button that gives no feedback is a copy button
    // people press three times.
    let was = status
    setStatus("invite copied")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in self?.setStatus(was) }
  }

  // ── peek: HOLD TO SEE YOURSELF ──────────────────────────────────────────────
  //
  // The web app's `#peek` shows your own camera full-screen while held. Native
  // already keeps a corner self-view, so this toggles the corner rather than
  // taking the window: same question answered ("is my camera working"), without
  // covering the person who is talking.
  var onPeek: ((Bool) -> Void)?
  fileprivate(set) var peeking = false

  /// `#flip`: the next camera in the list. Hidden while there is only one, exactly
  /// as `display: none` does, so the row is six buttons or five and never a dead one.
  @objc func nextCamera() {
    Metrics.tap("flip")
    guard camNames.count > 1 else { return }
    // "a flip is a state change; the bar earns its 10 s again"
    showBar(pin: true)
    let next = (camPicker.indexOfSelectedItem + 1) % camNames.count
    camPicker.selectItem(at: next)
    onCamPick?(next)
    setStatus(camNames[next])
  }

  /// Translation is parked. The globe is not in the row. simulate("xlate")
  /// still names the decision rather than pretending the control exists.
  @objc func toggleXlate() {
    Metrics.tap("xlate")
    setStatus("translation is off")
  }

  /// `#more`: the sheet. Native's equivalents of its rows are the camera picker and
  /// the invite, so the button reveals those rather than an empty panel.
  // ── `.bar.show` ─────────────────────────────────────────────────────────────
  //
  //   .bar { opacity: 0; pointer-events: none; transition: opacity .22s }
  //   .bar.show { opacity: 1; pointer-events: auto }
  //
  // Driven by `#call.barShown` in the web app, which the app puts on for a few
  // seconds after any pointer activity. The middle of the screen is a face, and
  // six circles permanently parked over it is the fatigue this design exists to
  // remove.
  private var barShown = true
  private var barTimer: Timer?
  /// `Math.max(2600, barPinnedUntil - now)`.
  private static let barStillness: TimeInterval = 2.6
  /// `showBar(true)` pins for 10 s -- a state change earns the row that long.
  private static let barPin: TimeInterval = 10.0
  private var barPinnedUntil = Date.distantPast

  /// `pin: true` for a state change (a mute, a camera swap): the row has just said
  /// something and taking it away in 2.6 s is taking away the confirmation.
  private func showBar(pin: Bool = false) {
    barTimer?.invalidate()
    setBar(visible: true)
    if pin { barPinnedUntil = max(barPinnedUntil, Date().addingTimeInterval(CallControls.barPin)) }
    scheduleBarHide()
  }

  private func scheduleBarHide() {
    barTimer?.invalidate()
    // ── NOT BEFORE THE CALL ───────────────────────────────────────────────────
    //
    // `if (!joined) return;` -- "Before the call the screen is your own mirror and
    // one button, and hiding the controls there just makes the app look broken."
    // This app hid them anyway, so the waiting screen sat there with a link and no
    // visible way to mute, turn the camera off, or leave.
    guard startedAt != nil else { return }
    // Whichever ends later: 2.6 s of stillness, or the pin. Sizing the timer to the
    // ACTUAL remaining time is the difference between the row disappearing where the
    // rule says and up to one tick later.
    let wait = max(CallControls.barStillness, barPinnedUntil.timeIntervalSinceNow)
    barTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
      guard let self else { return }
      // A sheet open or a leave half-confirmed is a decision in progress, and taking
      // the controls away mid-decision is how you get a hang-up nobody meant.
      if self.moreOpen || self.leaveArmed { self.scheduleBarHide(); return }
      self.setBar(visible: false)
    }
  }
  private func setBar(visible: Bool) {
    guard visible != barShown else { return }
    barShown = visible
    let row: [NSView] = [micButton, camButton, peekButton, flipButton, leaveButton, moreButton]
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.22
      for v in row { v.animator().alphaValue = visible ? 1 : 0 }
    }
  }
  override func mouseMoved(with event: NSEvent) { showBar() }
  override func mouseEntered(with event: NSEvent) { showBar() }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds,
                                   options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil))
  }
  /// Armed once the window exists: the row is visible on arrival and then settles.
  func armBarAutoHide() { showBar() }
  /// A press is activity. Without this, `--press` drove the controls while the row
  /// was invisible and every photograph of the result was of an empty bar.
  func nudgeBar() { showBar() }

  /// Half-confirmed leave. Declared here because the auto-hide has to know about it:
  /// the row must not vanish between the two clicks.
  private(set) var leaveArmed = false

  private(set) var moreOpen = false
  /// Open it if it is closed. The menu item says "Show Encryption Code", and a
  /// menu item that sometimes closes the thing it offers to show is a trick.
  @objc func openMore() { if !moreOpen { toggleMore() } }

  @objc func toggleMore() {
    let before = moreOpen
    defer { Metrics.tap("more", ok: moreOpen != before) }
    moreOpen.toggle()
    moreButton.on = moreOpen
    if moreOpen { rebuildSheet() }
    needsLayout = true
    layoutSubtreeIfNeeded()
  }
  @objc private func closeMore() {
    guard moreOpen else { return }
    moreOpen = false
    moreButton.on = false
    needsLayout = true
    layoutSubtreeIfNeeded()
  }
  /// A click on the scrim -- anywhere outside the panel -- closes it.
  override func mouseDown(with event: NSEvent) {
    if moreOpen, !sheet.frame.contains(convert(event.locationInWindow, from: nil)) {
      closeMore(); return
    }
    super.mouseDown(with: event)
  }

  /// The sheet's `.callOnly` rows, in native terms: one row per camera with a tick
  /// on the live one, then the encryption code.
  ///
  /// ── NO "COPY INVITE LINK" ROW ───────────────────────────────────────────────
  ///
  /// There was one, first in the list. It is gone, and the reason is the shape of
  /// the product: this is a call between two people. While one of them is waiting,
  /// the link is already on screen with three ways to copy it -- the URL glass
  /// itself, a `copy` button and a `share` button -- and once the other one arrives
  /// there is nobody left to invite, so the row spent the entire call being dead
  /// weight in the one menu the app has.
  ///
  /// This is only safe because the waiting card now COMES BACK when the other
  /// person leaves (`setPeerPresent`). Before that, `waiting.isHidden = true` was a
  /// one-way door, and removing this row would have left a departed call with no
  /// route to the link at all.
  private func rebuildSheet() {
    var rows: [SheetRow] = []
    for (i, name) in camNames.enumerated() {
      let r = SheetRow(name, glyph: Glyph.cam)
      r.checked = i == camPicker.indexOfSelectedItem
      r.tag = i
      r.target = self; r.action = #selector(pickCameraRow(_:))
      rows.append(r)
    }
    // ── NO "CONNECTION NUMBERS" ROW ───────────────────────────────────────────
    //
    // There was one here, a switch that put a latency readout over the other
    // person's face. Removed on the user's ruling, twice given: this is a consumer
    // app, and a switch offering somebody a millisecond figure is a test harness
    // wearing the app's clothes. The numbers did not go away -- every one of them
    // is still on stderr once a second and in the telemetry beat. Diagnostics in
    // this project live hidden, they do not stop existing.
    //
    // ── AND NO DIVIDER RULE ───────────────────────────────────────────────────
    //
    // `if let first = rows.dropFirst().first { first.ruled = true }` was here. It
    // meant one thing: rule off the first switch-like row so the ACTION above it --
    // "Copy invite link" -- could not be mistaken for a switch. That action is gone,
    // and the line does not degrade gracefully with it: `rows` is now cameras only,
    // so `dropFirst().first` is the SECOND CAMERA, and a machine with two cameras
    // would have drawn a divider through the middle of the camera list. A rule
    // computed from positions rather than from meaning goes stale the moment the
    // positions change, so it goes rather than gets re-pointed.
    //
    // `#c-safety` below is `inert`, which is how the sheet already says "this one is
    // not a control" -- it does not need a line to say it a second time.

    // `#c-safety`: neither a switch nor an action -- a fact about this call, with
    // nothing to press, because there is no decision here for anyone to make.
    let safety = SheetRow("Encryption code", glyph: Glyph.lock)
    safety.inert = true
    safety.value = safetyCode.isEmpty ? "…" : safetyCode

    var items: [NSView] = []
    // The name first: it is the one thing in here somebody came looking for.
    // Absent until claimed -- see `handle`.
    if !handle.isEmpty {
      let h = SheetRow("Your handle", glyph: Glyph.person)
      h.value = "@" + handle
      h.target = self; h.action = #selector(copyHandleRow(_:))
      items.append(h)
    }
    items += rows as [NSView]
    // Silent is a switch, so it carries a tick and never a value.
    let q = SheetRow("Silent", glyph: Glyph.bell)
    q.checked = silent
    q.target = self; q.action = #selector(toggleSilentRow(_:))
    items.append(q)
    items.append(safety)
    items.append(SheetHint(silent
      ? "Silent: nobody can ring you. To them you simply look away."
      : "Read it aloud. Same code on both screens means nobody is in the middle."))
    sheet.setItems(items)
  }

  // `inviteFromSheet` was here, the sheet row's action. The row is gone; `invite()`
  // itself stays -- the Command-Shift-C menu item and the `--press invite` token
  // both still use it, and so does the waiting card's own copy button.
  @objc private func pickCameraRow(_ sender: SheetRow) {
    Metrics.tap("pick_camera", ok: camNames.indices.contains(sender.tag))
    camPicker.selectItem(at: sender.tag)
    onCamPick?(sender.tag)
    setStatus(camNames.indices.contains(sender.tag) ? camNames[sender.tag] : "camera changed")
    closeMore()
  }

  private var leaveTimer: Timer?
  @objc func leave() {
    Metrics.tap(leaveArmed ? "leave_confirm" : "leave_arm")
    if leaveArmed {
      cancelLeaveConfirm()
      onLeave?()
      return
    }
    leaveArmed = true
    leaveButton.confirming = true
    leaveButton.confirmLabel = "tap to leave"
    showBar(pin: true)
    needsLayout = true
    layoutSubtreeIfNeeded()
    // Three seconds and it forgets, because an armed hang-up left on screen is a
    // trap for the next click that lands anywhere near it.
    leaveTimer?.invalidate()
    leaveTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
      self?.cancelLeaveConfirm()
    }
  }

  func cancelLeaveConfirm() {
    guard leaveArmed else { return }
    leaveArmed = false
    leaveTimer?.invalidate()
    leaveButton.confirming = false
    needsLayout = true
    layoutSubtreeIfNeeded()
    scheduleBarHide()
  }

  /// What is actually in the window, printed, because a snapshot that comes back
  /// empty cannot distinguish "nothing is there" from "the capture does not work".
  /// The row as it actually renders, for the tests -- a button hidden by
  /// `isHidden` is invisible to a screenshot and would otherwise be indistinguishable
  /// from one that was never added.
  /// What is on the bar RIGHT NOW. It used to be a hardcoded list with one `if` in
  /// it, so it reported five buttons through a confirm that had collapsed four of
  /// them to zero width -- an instrument describing the code's intent instead of
  /// the screen.
  var visibleRowNames: [String] {
    [("mic", micButton), ("cam", camButton), ("peek", peekButton), ("flip", flipButton),
     ("xlate", xlateButton), ("leave", leaveButton)]
      .filter { !$0.1.isHidden && $0.1.alphaValue > 0.01 && $0.1.frame.width > 4 }
      .map { $0.0 }
  }

  var describeTree: String {
    "controls \(Int(bounds.width))x\(Int(bounds.height))"
      + "  status=\(status.isEmpty ? "-" : status)"
      + "  room=\(roomPill.text)"
      + "  quality=\(qualityText.isEmpty ? "-" : qualityText)"
      + "  picker=\(camPicker.isHidden ? "hidden" : "\(camNames.count) items")"
      + "  mic=\(micMuted ? "muted" : "on") cam=\(camOff ? "off" : "on")"
      + "  row=[\(visibleRowNames.joined(separator: " "))]"
      + "  more=\(moreOpen ? "open" : "closed") peek=\(peeking)\(peekButton.holding ? "/held" : "")"
      + "  leave=\(leaveArmed ? "ARMED" : "idle") bar=\(barShown ? "shown" : "hidden")"
      + "  clip=\(NSPasteboard.general.string(forType: .string) ?? "-")"
      + (moreOpen ? "\n  sheet=[" + sheet.rows.map { $0.spoken }.joined(separator: " | ") + "]" : "")
  }

  /// --press mic,cam,invite,leave,echo,cam#2 -- exercise the wiring before
  /// photographing it. A control that draws and does nothing is this project's
  /// most repeated defect and does not get to be assumed.
  // ── THE KEYS A MAC USER ALREADY PRESSES ────────────────────────────────────
  //
  // Escape closes the sheet and disarms the hang-up, exactly as the web app's
  // `keydown` does. The other two are the shortcuts every Mac video app has
  // agreed on -- Command-Shift-A for the microphone, Command-Shift-V for the
  // camera -- and reaching for them and getting nothing is a large part of what
  // makes a native app feel like a web page in a frame.
  @discardableResult
  func handleKey(_ event: NSEvent) -> Bool {
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.keyCode == 53 {  // esc
      guard moreOpen || leaveArmed else { return false }
      closeMore(); cancelLeaveConfirm(); nudgeBar()
      return true
    }
    guard mods == [.command, .shift], let ch = event.charactersIgnoringModifiers?.lowercased() else {
      return false
    }
    switch ch {
    case "a": toggleMic(); nudgeBar(); return true
    case "v": toggleCam(); nudgeBar(); return true
    default: return false
    }
  }

  func simulate(_ what: String) {
    switch what {
    case "esc", "cmd-mic", "cmd-cam":
      let ch = what == "esc" ? "\u{1b}" : (what == "cmd-mic" ? "a" : "v")
      let code: UInt16 = what == "esc" ? 53 : (what == "cmd-mic" ? 0 : 9)
      let mods: NSEvent.ModifierFlags = what == "esc" ? [] : [.command, .shift]
      if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                  context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                  isARepeat: false, keyCode: code) {
        fputs("key \(what): handled=\(handleKey(e))\n", stderr)
      }
    // Reading the menu bar back rather than photographing it: a screenshot of the
    // menu bar is a screenshot of whatever app is frontmost, which on a test
    // machine is not this one -- and is somebody's private screen.
    case "menu":
      guard let m = NSApp.mainMenu else { fputs("menu: NONE INSTALLED\n", stderr); break }
      for top in m.items {
        // AppKit shows the SUBMENU's title for a top-level item whose own title is
        // empty, so that is the name a person actually reads up there.
        let name = top.title.isEmpty ? (top.submenu?.title.isEmpty == false
                                        ? top.submenu!.title : "(app)") : top.title
        let kids = (top.submenu?.items ?? []).map { i -> String in
          if i.isSeparatorItem { return "--" }
          var k = i.title
          if !i.keyEquivalent.isEmpty {
            let mods = i.keyEquivalentModifierMask
            var pre = ""
            if mods.contains(.command) { pre += "cmd-" }
            if mods.contains(.shift) { pre += "shift-" }
            if mods.contains(.option) { pre += "opt-" }
            let ch = i.keyEquivalent == "\u{8}" ? "delete" : i.keyEquivalent
            k += " [\(pre)\(ch)]"
          }
          if i.action == nil && i.submenu == nil { k += " (DEAD)" }
          return k
        }
        fputs("menu \(name): \(kids.joined(separator: ", "))\n", stderr)
      }
    case "swipe-sheet": sheet.onSwipeDown?()
    // The red X, not the red circle. Closing the window has to end the call, and
    // the only way to know it does is to close the window.
    case "close-window": window?.performClose(nil)
    case "scrim": closeMore()
    case "mic": toggleMic()
    case "cam": toggleCam()
    case "invite": invite()
    case "peek": peekButton.simulateHold(true)
    case "unpeek": peekButton.simulateHold(false)
    case "flip": nextCamera()
    case "xlate": toggleXlate()
    case "more": toggleMore()
    case "leave": leave()
    case "unleave": cancelLeaveConfirm()
    case "quality": markConnected(); setQuality(m2eMs: 11, concealPct: 0, lossPct: 0)
    case let c where c.hasPrefix("cam#"):
      guard let n = Int(c.dropFirst(4)), n >= 1, n <= camPicker.numberOfItems else {
        fputs("press: no camera \(c)\n", stderr); return
      }
      camPicker.selectItem(at: n - 1)
      camPicked()
    default: fputs("press: no control called \(what)\n", stderr)
    }
  }
}

// ── Closing the window has to end the call ───────────────────────────────────
//
// It did not. `NSWindow` was created with `.closable` and no delegate, so closing
// it left the process running with no window at all: the camera light stays on,
// the microphone stays open, and the only way out is Activity Monitor. That is a
// privacy bug, not a tidiness one, and it is the first thing anybody does when
// they want a call to stop.
final class WindowCloser: NSObject, NSWindowDelegate {
  private let onClose: () -> Void
  init(onClose: @escaping () -> Void) { self.onClose = onClose }
  func windowWillClose(_ notification: Notification) { onClose() }
}

// ── EVERY CONTROL, CLICKED WHERE IT ACTUALLY IS ──────────────────────────────
//
// `--press mic` calls `toggleMic()`. That proves the handler works and proves
// nothing at all about the button, and the last three interaction bugs here were
// all in the gap: six discs with no glyph on them, a share button `didSet` never
// sized so it drew at zero, and a full-bleed waiting card whose `hitTest`
// swallowed the whole bar. Every one of those passes a handler test.
//
// So the audit asks the question a finger asks: at the middle of this control,
// which view does `hitTest` hand the click to? Then it sends a real
// `NSEvent` through `window.sendEvent`, the same path the window server uses,
// and reads the state back.
extension CallControls {
  /// Everything a person can click, and where. Only what is on screen right now.
  var clickTargets: [(String, NSView)] {
    var out: [(String, NSView)] = []
    func add(_ n: String, _ v: NSView) {
      guard !v.isHidden, v.alphaValue > 0.01, v.bounds.width > 4, v.bounds.height > 4,
            !v.frame.isEmpty else { return }
      out.append((n, v))
    }
    add("mic", micButton); add("cam", camButton); add("peek", peekButton)
    add("flip", flipButton); add("leave", leaveButton)
    add("more", moreButton)
    if moreOpen { for (i, r) in sheet.rows.enumerated() where r.isEnabled { add("row#\(i)", r) } }
    if !waiting.isHidden { for (n, v) in waiting.clickTargets { add(n, v) } }
    return out
  }

  /// `hitTest` from the content view down, exactly as a click arrives.
  func auditClicks() -> [String] {
    guard let win = window, let root = win.contentView else { return ["no window"] }
    // The audit converts to window coordinates and hit-tests the content view,
    // whose `hitTest` takes points in its SUPERVIEW's space. Those agree only while
    // the content view sits at the window origin -- true under
    // `.fullSizeContentView`, and a silently wrong answer the day it isn't.
    guard root.frame.origin == .zero else { return ["content view is not at the window origin"] }
    var lines: [String] = []
    for (name, v) in clickTargets {
      let mid = NSPoint(x: v.bounds.midX, y: v.bounds.midY)
      let p = v.convert(mid, to: nil)
      let hit = root.hitTest(p)
      // The glyph overlay and the glass blur are both subviews of the button, so a
      // hit on either IS a hit on the button. Anything else is a control a finger
      // cannot reach.
      var reached = false
      var walk: NSView? = hit
      while let w = walk { if w === v { reached = true; break }; walk = w.superview }
      // A card that claims its own bounds and routes by frame in `mouseDown` is a
      // legitimate third answer, so it gets its own word. Calling it FAIL made the
      // audit cry wolf about the one card that works.
      var forwards = false
      if !reached, let h = hit {
        var up: NSView? = v.superview
        while let u = up { if u === h { forwards = true; break }; up = u.superview }
      }
      let got = hit.map { "\(type(of: $0))" } ?? "nil"
      let verdict = reached ? "OK  " : (forwards ? "SELF" : "FAIL")
      lines.append("\(verdict) \(name) at (\(Int(p.x)),\(Int(p.y))) -> \(got)")
    }
    return lines
  }

  /// Real keystrokes, through THIS window. A text field filled by assigning
  /// `stringValue` proves nothing about typing into it, and a system-wide event
  /// tap proves it by aiming at whatever happens to be in front -- which, on a
  /// Mac somebody is using, is not this app. Measured the hard way: a handle
  /// typed at screen coordinates landed in the browser the user was watching.
  /// These events carry this window's number, so nothing else can receive them.
  @discardableResult
  func typeText(_ s: String) -> Bool {
    guard let win = window else { return false }
    for ch in s {
      let str = String(ch)
      func ev(_ t: NSEvent.EventType) -> NSEvent? {
        NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: win.windowNumber, context: nil,
                         characters: str, charactersIgnoringModifiers: str,
                         isARepeat: false, keyCode: 0)
      }
      guard let d = ev(.keyDown), let u = ev(.keyUp) else { return false }
      win.sendEvent(d); win.sendEvent(u)
    }
    fputs("  typed \"\(s)\" -> first responder \(win.firstResponder.map { "\(type(of: $0))" } ?? "none")\n", stderr)
    return true
  }

  /// A real click, through the window, at the control's own centre.
  /// `holdFor` keeps the button down that long, for press-and-hold controls.
  func click(_ name: String, holdFor: TimeInterval = 0) -> Bool {
    guard let win = window else { return false }
    guard let (_, v) = clickTargets.first(where: { $0.0 == name }) else {
      fputs("click: \(name) is not on screen\n", stderr); return false
    }
    let p = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
    func ev(_ t: NSEvent.EventType) -> NSEvent? {
      NSEvent.mouseEvent(with: t, location: p, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: win.windowNumber, context: nil,
                         eventNumber: 0, clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1)
    }
    guard let down = ev(.leftMouseDown), let up = ev(.leftMouseUp) else { return false }
    let hitNow = win.contentView?.hitTest(p)
    fputs("  click \(name) at (\(Int(p.x)),\(Int(p.y))) frame=\(v.frame) hit=\(hitNow.map { "\(type(of: $0))" } ?? "nil")"
        + " key=\(win.isKeyWindow) active=\(NSApp.isActive)\n", stderr)
    // Queue the release FIRST. Press-and-hold runs its own event loop on
    // `nextEvent(matching: .leftMouseUp)`, and a synthetic press with no release
    // behind it hangs the process there forever -- waiting for a finger that does
    // not exist.
    if holdFor <= 0 {
      win.postEvent(up, atStart: false)
      win.sendEvent(down)
      return true
    }
    // A real hold. The release cannot go through `DispatchQueue.main`: the hold's
    // own `nextEvent(matching:)` owns the main thread until the release arrives, so
    // the release would be queued behind the thing it is meant to release. A
    // `Timer` in `.common` modes fires during event tracking, which is exactly the
    // mode a hold puts the runloop into.
    // The release goes STRAIGHT to the view, not through `postEvent`. AppKit gives a
    // real drag an implicit capture -- every event after a `mouseDown` goes to the
    // view that received it, wherever the pointer has moved to. A posted event gets
    // hit-tested afresh instead, so an open sheet over the bar swallowed the
    // release and the hold never ended. Delivering it directly is what models the
    // capture a finger actually gets.
    (v as? IconButton)?.syntheticHold = true
    let t = Timer(timeInterval: holdFor, repeats: false) { _ in
      (v as? IconButton)?.syntheticHold = false
      v.mouseUp(with: up)
    }
    RunLoop.main.add(t, forMode: .common)
    win.sendEvent(down)
    return true
  }
}

/// `.sheetScrim`: the dark nothing behind an open sheet. Its whole job is to take
/// one click and close what is in front of it.
final class ScrimView: NSView {
  /// See IconButton.acceptsFirstMouse.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  var onClick: (() -> Void)?
  override func mouseDown(with event: NSEvent) { onClick?() }
  override func hitTest(_ point: NSPoint) -> NSView? {
    // Superview coordinates in, superview-coordinate `frame` to test. See SheetRow.
    isHidden ? nil : (frame.contains(point) ? self : nil)
  }
}
