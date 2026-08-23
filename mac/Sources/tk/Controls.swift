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

  /// `#c-hud`: <path d="M4 20V10"/><path d="M10 20V4"/><path d="M16 20v-7"/><path d="M22 20H2"/>
  static let bars = Shape(build: { box in path(box) { p, k in
    m(p, k, 4, 20); l(p, k, 4, 10)
    m(p, k, 10, 20); l(p, k, 10, 4)
    m(p, k, 16, 20); l(p, k, 16, 13)
    m(p, k, 22, 20); l(p, k, 2, 20)
  } }, filled: false)

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

  /// A chain link, for the invite row. Not in the web app's set -- it has no link
  /// button -- so it is drawn in the same language rather than borrowed from a
  /// different icon family, which is what makes a set look like a set.
  static let link = Shape(build: { box in path(box) { p, k in
    m(p, k, 10, 14)
    p.curve(to: NSPoint(x: 14 * k, y: 10 * k),
            controlPoint1: NSPoint(x: 11.2 * k, y: 12.8 * k), controlPoint2: NSPoint(x: 12.8 * k, y: 11.2 * k))
    m(p, k, 8.5, 11)
    p.curve(to: NSPoint(x: 5.5 * k, y: 14 * k),
            controlPoint1: NSPoint(x: 7.5 * k, y: 12 * k), controlPoint2: NSPoint(x: 6.5 * k, y: 13 * k))
    p.curve(to: NSPoint(x: 10 * k, y: 18.5 * k),
            controlPoint1: NSPoint(x: 3 * k, y: 16.5 * k), controlPoint2: NSPoint(x: 7.5 * k, y: 21 * k))
    p.curve(to: NSPoint(x: 13 * k, y: 15.5 * k),
            controlPoint1: NSPoint(x: 11 * k, y: 17.5 * k), controlPoint2: NSPoint(x: 12 * k, y: 16.5 * k))
    m(p, k, 15.5, 13)
    p.curve(to: NSPoint(x: 18.5 * k, y: 10 * k),
            controlPoint1: NSPoint(x: 16.5 * k, y: 12 * k), controlPoint2: NSPoint(x: 17.5 * k, y: 11 * k))
    p.curve(to: NSPoint(x: 14 * k, y: 5.5 * k),
            controlPoint1: NSPoint(x: 21 * k, y: 7.5 * k), controlPoint2: NSPoint(x: 16.5 * k, y: 3 * k))
    p.curve(to: NSPoint(x: 11 * k, y: 8.5 * k),
            controlPoint1: NSPoint(x: 13 * k, y: 6.5 * k), controlPoint2: NSPoint(x: 12 * k, y: 7.5 * k))
  } }, filled: false)

  /// The slash that appears over a glyph that is OFF: <path d="M4 4l16 16"/>.
  static let slash = Shape(build: { box in path(box) { p, k in
    m(p, k, 4, 4); l(p, k, 20, 20)
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
    // Track the drag ourselves so a release ANYWHERE ends the hold. `setPointerCapture`
    // is what the web app does for the same reason: letting go outside the circle
    // must not leave the self-view stuck on screen.
    while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
      if e.type == .leftMouseUp { break }
    }
    setHolding(false)
  }
  private func setHolding(_ on: Bool) {
    guard holding != on else { return }
    holding = on
    self.on = on
    onHold?(on)
  }
  /// For `--press`: a hold long enough to be photographed, then released.
  func simulateHold(_ on: Bool) { setHolding(on) }

  override func layout() {
    super.layout()
    glass.frame = bounds
    glass.layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    glass.isHidden = destructive
    ink.frame = bounds
  }

  override func draw(_ dirty: NSRect) {
    let d = min(bounds.width, bounds.height)
    let circle = NSBezierPath(ovalIn: NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2,
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
  /// An action, not a toggle -- ruled off above so it never reads as a switch.
  var ruled = false { didSet { needsDisplay = true } }
  /// A fact about this call: nothing to press.
  var inert = false
  /// `.sheet .row .code` -- a monospaced value pinned right, for the encryption code.
  var value: String = "" { didSet { needsDisplay = true } }

  // ── SAY WHICH WAY IS UP ────────────────────────────────────────────────────
  //
  // Left to the default, the tick drew as a caret and the divider landed one row
  // low -- two symptoms, one cause, and both of them look like arithmetic bugs
  // rather than a coordinate system. `NSButton` is not documented to be flipped
  // and the containing `Sheet` is not, so the geometry below was written for y-up
  // and is now guaranteed to get it.
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
    if hovering {
      NSColor(white: 1, alpha: 0.06).setFill()
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
      let f = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
      let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: Palette.fg]
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
  var url = "" { didSet { urlField.stringValue = url; needsLayout = true } }
  var onCopy: (() -> Void)?
  var onShare: (() -> Void)?

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
  }
  required init?(coder: NSCoder) { fatalError() }

  // ── A FULL-SURFACE OVERLAY MUST NOT EAT THE BAR ────────────────────────────
  //
  // `#waiting` is `inset: 0` so its wash is centred on the window rather than on a
  // box, which means it covers the buttons too. In CSS that is harmless -- the bar
  // has a higher z-index. Here it is a subview added last, so without this it would
  // swallow every click on mic, camera and leave, and the call would look frozen
  // while being perfectly fine.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let p = convert(point, from: superview)
    for v in [urlGlass, shareButton, copyButton] where v.frame.contains(p) { return self }
    return nil
  }

  /// The link itself copies when clicked -- `#shareUrl { cursor: pointer }`.
  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if urlGlass.frame.contains(p) { onCopy?(); return }
    if shareButton.frame.contains(p) { onShare?(); return }
    if copyButton.frame.contains(p) { onCopy?(); return }
    super.mouseDown(with: event)
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
  }
}

/// `#copy, #shareBtn`: a 999 px glass pill with a word in it.
final class PillButton: NSView {
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
  private let qualityPill = Pill(font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium))
  private let echoPill = Pill(font: .systemFont(ofSize: 12, weight: .medium))
  private let scrim = CAGradientLayer()

  // THE WEB APP'S ROW, IN ITS ORDER: mic, cam, peek, flip, xlate, leave. `flip`
  // hides itself with one camera exactly as `#flip` does, and `peek` is the
  // hold-to-see-yourself button the web app has had since early on.
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
  /// `#elapsed`: the clock, chrome-less, above the status pill.
  private let elapsedLabel = NSTextField(labelWithString: "")
  /// `.sheetScrim`: a click anywhere else closes the sheet, which is how every
  /// bottom panel on a phone behaves and the only way out that needs no aiming.
  private let sheetScrim = NSView()
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

    for b in [micButton, camButton, peekButton, flipButton, xlateButton, leaveButton, moreButton] {
      addSubview(b)
    }
    micButton.target = self; micButton.action = #selector(toggleMic)
    camButton.target = self; camButton.action = #selector(toggleCam)
    peekButton.onHold = { [weak self] on in self?.onPeek?(on); self?.peeking = on }
    flipButton.target = self; flipButton.action = #selector(nextCamera)
    xlateButton.target = self; xlateButton.action = #selector(toggleXlate)
    leaveButton.target = self; leaveButton.action = #selector(leave)
    moreButton.target = self; moreButton.action = #selector(toggleMore)
    sheetScrim.isHidden = true
    addSubview(sheetScrim)
    sheet.isHidden = true
    addSubview(sheet)
    rebuildSheet()
    // `#flip { display: none }` until there is more than one camera, and live
    // translation is off until it exists natively -- shown, off, and honest about
    // it rather than absent from a row the web app has six buttons in.
    flipButton.isHidden = true
    xlateButton.off = true
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
    // `#hud` is OPT-IN in the web app -- "more sheet -> Connection numbers" -- and
    // its default is off. A permanent latency readout over someone's face is
    // instrumentation, and this app has plenty of that on stderr for whoever wants
    // it. So the pill starts hidden and the sheet row turns it on.
    qualityPill.isHidden = true
    elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    elapsedLabel.textColor = NSColor(white: 232.0 / 255, alpha: 0.62)
    elapsedLabel.alignment = .center
    elapsedLabel.backgroundColor = .clear
    elapsedLabel.isBordered = false
    elapsedLabel.shadow = { let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.95)
                            sh.shadowBlurRadius = 3; return sh }()
    addSubview(elapsedLabel)
    waiting.onCopy = { [weak self] in
      guard let self else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(self.inviteText, forType: .string)
      self.waiting.confirmCopied()
    }
    waiting.onShare = { [weak self] in self?.share() }
    addSubview(waiting)
    addSubview(qualityPill)
    echoPill.textColor = Palette.warn
    addSubview(echoPill)

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
    let row = [micButton, camButton, peekButton, flipButton, xlateButton, leaveButton]
      .filter { !$0.isHidden }
    let rowW = CGFloat(row.count) * bw + CGFloat(max(0, row.count - 1)) * gap
    var x = (w - rowW) / 2
    for b in row {
      b.frame = NSRect(x: x, y: bottomPad, width: bw, height: bw)
      x += bw + gap
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

    // `#status { top:14px; left:50%; translateX(-50%) }` and `#elapsed` above it.
    statusPill.setFrameOrigin(NSPoint(x: (w - statusPill.frame.width) / 2,
                                      y: h - statusPill.frame.height - 14))
    elapsedLabel.frame = NSRect(x: 0, y: h - statusPill.frame.height - 32, width: w, height: 14)

    // The pills stack down the LEFT, because `#more` owns the top-right corner in
    // the web app and two things cannot have it. 36 pt clears the traffic lights,
    // which now float over the picture -- `.fullSizeContentView` put them there,
    // and at 20 pt the room pill sliced straight through all three.
    let topPad: CGFloat = 36
    var py = h - roomPill.frame.height - topPad
    roomPill.setFrameOrigin(NSPoint(x: 20, y: py))
    py -= qualityPill.frame.height + 8
    qualityPill.setFrameOrigin(NSPoint(x: 20, y: py))
    py -= echoPill.frame.height + 8
    echoPill.setFrameOrigin(NSPoint(x: 20, y: py))
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

  /// `#waiting.gone` -- the card goes the moment there is someone to look at, and
  /// `#status.gone`: "connected" is said once and then gets out of the face's way.
  func markConnected() {
    if startedAt == nil { startedAt = Date() }
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
    let picker = NSSharingServicePicker(items: [inviteText])
    picker.show(relativeTo: .zero, of: self, preferredEdge: .minY)
  }

  /// Latency and the fraction of audio that had to be invented, once a second.
  /// Turns the numbers into a sentence and a colour.
  func setQuality(m2eMs: Double?, concealPct: Double, lossPct: Double) {
    var parts: [String] = []
    if let t = startedAt {
      let s = Int(Date().timeIntervalSince(t))
      // The clock lives on its own, chrome-less, where `#elapsed` puts it.
      onMain { [weak self] in self?.elapsedLabel.stringValue = String(format: "%d:%02d", s / 60, s % 60) }
    }
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
    let text = parts.joined(separator: "  ·  ")
    onMain { [weak self] in
      guard let self else { return }
      self.qualityPill.textColor = colour
      self.qualityPill.text = text
      // `Pill.text` hides itself when empty and SHOWS itself otherwise, which would
      // undo the opt-in a second after it was set. The switch decides.
      self.qualityPill.isHidden = !self.numbersShown || text.isEmpty
      self.needsLayout = true
    }
  }

  // ── "YOUR ROOM IS LOUD" ───────────────────────────────────────────────────
  //
  // The one call problem whose fix belongs entirely to the person: the microphone
  // is hearing the speaker. The measurement already existed -- capture against
  // playout, cross-correlated over a 0-200 ms search, printed every second and
  // shown to nobody -- and 0.30 is the threshold the delay estimator already
  // trusts.
  func setEcho(_ correlation: Double) {
    let text = correlation > 0.30 ? "your room is loud — try headphones" : ""
    onMain { [weak self] in
      self?.echoPill.text = text
      self?.needsLayout = true
    }
  }

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
    micMuted.toggle()
    micButton.off = micMuted
    onMic?(micMuted)
    setStatus(micMuted ? "you are muted" : status.contains("muted") ? "connected" : status)
  }

  @objc func toggleCam() {
    camOff.toggle()
    camButton.off = camOff
    onCam?(camOff)
  }

  @objc func invite() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(inviteText, forType: .string)
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
    guard camNames.count > 1 else { return }
    let next = (camPicker.indexOfSelectedItem + 1) % camNames.count
    camPicker.selectItem(at: next)
    onCamPick?(next)
    setStatus(camNames[next])
  }

  /// `#xlate`: live translation. It exists in the web app and not yet here, so the
  /// button is present and OFF -- pressing it says so rather than doing nothing,
  /// because a control that swallows a click is worse than one that declines it.
  @objc func toggleXlate() {
    setStatus("live translation is web-only for now")
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
  private static let barLinger: TimeInterval = 3.5

  private func showBar() {
    barTimer?.invalidate()
    setBar(visible: true)
    barTimer = Timer.scheduledTimer(withTimeInterval: CallControls.barLinger, repeats: false) { [weak self] _ in
      // Never hide the row while the sheet it opened is standing on top of it.
      guard let self, !self.moreOpen else { return }
      self.setBar(visible: false)
    }
  }
  private func setBar(visible: Bool) {
    guard visible != barShown else { return }
    barShown = visible
    let row: [NSView] = [micButton, camButton, peekButton, flipButton, xlateButton, leaveButton, moreButton]
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

  private(set) var moreOpen = false
  @objc func toggleMore() {
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

  /// The sheet's `.callOnly` rows, in native terms: the invite first because it is
  /// the flow, then one row per camera with a tick on the live one.
  private func rebuildSheet() {
    var rows: [SheetRow] = []
    let inv = SheetRow("Copy invite link", glyph: Glyph.link)
    inv.target = self; inv.action = #selector(inviteFromSheet)
    rows.append(inv)
    for (i, name) in camNames.enumerated() {
      let r = SheetRow(name, glyph: Glyph.cam)
      r.checked = i == camPicker.indexOfSelectedItem
      r.tag = i
      r.target = self; r.action = #selector(pickCameraRow(_:))
      rows.append(r)
    }
    // `#c-hud`: "Connection numbers", a switch with a tick.
    let hud = SheetRow("Connection numbers", glyph: Glyph.bars)
    hud.checked = numbersShown
    hud.target = self; hud.action = #selector(toggleNumbers)
    rows.append(hud)
    if let first = rows.dropFirst().first { first.ruled = true }

    // `#c-safety`: neither a switch nor an action -- a fact about this call, with
    // nothing to press, because there is no decision here for anyone to make.
    let safety = SheetRow("Encryption code", glyph: Glyph.lock)
    safety.inert = true
    safety.value = safetyCode.isEmpty ? "…" : safetyCode
    var items: [NSView] = rows
    items.append(safety)
    items.append(SheetHint("Read it aloud. Same code on both screens means nobody is in the middle."))
    sheet.setItems(items)
  }

  private(set) var numbersShown = false
  @objc private func toggleNumbers() {
    numbersShown.toggle()
    qualityPill.isHidden = !numbersShown || qualityPill.text.isEmpty
    rebuildSheet()
    needsLayout = true
  }

  @objc private func inviteFromSheet() { invite(); closeMore() }
  @objc private func pickCameraRow(_ sender: SheetRow) {
    camPicker.selectItem(at: sender.tag)
    onCamPick?(sender.tag)
    setStatus(camNames.indices.contains(sender.tag) ? camNames[sender.tag] : "camera changed")
    closeMore()
  }

  @objc func leave() { onLeave?() }

  /// What is actually in the window, printed, because a snapshot that comes back
  /// empty cannot distinguish "nothing is there" from "the capture does not work".
  /// The row as it actually renders, for the tests -- a button hidden by
  /// `isHidden` is invisible to a screenshot and would otherwise be indistinguishable
  /// from one that was never added.
  var visibleRowNames: [String] {
    var out = ["mic", "cam", "peek"]
    if !flipButton.isHidden { out.append("flip") }
    out += ["xlate", "leave"]
    return out
  }

  var describeTree: String {
    "controls \(Int(bounds.width))x\(Int(bounds.height))"
      + "  room=\(roomPill.text)"
      + "  quality=\(qualityPill.text.isEmpty ? "-" : qualityPill.text)"
      + "  echo=\(echoPill.isHidden ? "-" : echoPill.text)"
      + "  picker=\(camPicker.isHidden ? "hidden" : "\(camNames.count) items")"
      + "  mic=\(micMuted ? "muted" : "on") cam=\(camOff ? "off" : "on")"
      + "  row=[\(visibleRowNames.joined(separator: " "))]"
      + "  more=\(moreOpen ? "open" : "closed") peek=\(peeking)"
  }

  /// --press mic,cam,invite,leave,echo,cam#2 -- exercise the wiring before
  /// photographing it. A control that draws and does nothing is this project's
  /// most repeated defect and does not get to be assumed.
  func simulate(_ what: String) {
    switch what {
    case "mic": toggleMic()
    case "cam": toggleCam()
    case "invite": invite()
    case "peek": peekButton.simulateHold(true)
    case "unpeek": peekButton.simulateHold(false)
    case "flip": nextCamera()
    case "xlate": toggleXlate()
    case "more": toggleMore()
    case "leave": leave()
    case "echo": setEcho(0.9)
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
