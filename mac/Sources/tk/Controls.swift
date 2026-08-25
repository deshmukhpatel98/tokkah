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
// `Palette`, `Glass`, `Metric`, `Type_`, `Motion` and `GlassGroup` all moved to
// Glass.swift, which is now the design system: the material, the type ramp and the
// geometry rule, in one place. They were here, and `Glass` was an
// `NSVisualEffectView` with an opaque fill painted over the blur -- so it was not
// glass, and nothing that photographed it could tell.

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

  /// <path d="M4 20l1-4L16.5 4.5l3 3L8 19z"/><path d="M14.5 6.5l3 3"/>
  /// A pencil, for the one row in the app that changes something you own. `person`
  /// is next door and already means "this is you"; a second `person` on the row
  /// under it would say "you" twice and "editable" not at all.
  static let pencil = Shape(build: { box in path(box) { p, k in
    m(p, k, 4, 20); l(p, k, 5, 16); l(p, k, 16.5, 4.5); l(p, k, 19.5, 7.5); l(p, k, 8, 19)
    p.close()
    // The ferrule. Without it the body is a bare quadrilateral and reads as a
    // slanted banner rather than as a pencil at 18 pt, which is the only size this
    // is ever drawn at.
    m(p, k, 14.5, 6.5); l(p, k, 17.5, 9.5)
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
  // CLEAR, and interactive. A bar circle carries a glyph rather than a sentence
  // and floats over a live face, which is precisely the case the HIG names for the
  // clear variant: "components that float above media backgrounds -- such as
  // photos and videos -- to create a more immersive content experience." The dim
  // that keeps it legible is a gradient on the overlay, not a fill in here.
  private let glass = Glass(radius: 0, variant: .clear, interactive: true)
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
  // ── THE ONE PROMINENT CONTROL ──────────────────────────────────────────────
  //
  // It used to be a flat red disc with the glass hidden underneath it -- `.icon-btn.leave
  // { background: var(--bad) }`, straight from the web app's CSS. Next to four
  // circles of real material it read as a sticker: the only thing on the screen
  // that was paint rather than glass.
  //
  // It is tinted glass now, which is what the platform does with a prominent
  // action -- "Assign a tint color to suggest prominence" -- and it keeps the rule
  // this file already had. There is still exactly one dominant control, mic and
  // camera still turn their GLYPH red rather than their whole circle, and the
  // irreversible button is still the only one that looks irreversible. It is now
  // made of the same stuff as its neighbours while doing it.
  var destructive = false {
    didSet {
      guard destructive != oldValue else { return }
      // A WARM tint, not the colour itself: the colour is the fill behind the
      // glass (see `draw`). This only stops the material from cooling the red back
      // toward the blue of whatever is on the other side of it.
      glass.tint = destructive ? Palette.destructiveTint : nil
      needsDisplay = true; ink.needsDisplay = true
    }
  }
  // ── PRESS AND HOLD ─────────────────────────────────────────────────────────
  //
  // `#peek` is `pointerdown` -> show, `pointerup` -> hide. Not a toggle: the web
  // app's own comment is explicit that a persistent mirror is "the #1 measured
  // fatigue driver", and hold-to-peek exists precisely to avoid it. Built here as
  // a mode on the button rather than a second button class, because everything
  // else about it -- the circle, the glass, the glyph -- is identical.
  var onHold: ((Bool) -> Void)?
  private(set) var holding = false

  // ── TWO GESTURES ON ONE CIRCLE ─────────────────────────────────────────────
  //
  // A quick click on a hold button used to be an unclaimed gesture: `mouseDown`
  // returns before `super.mouseDown` whenever `onHold` is set, so `peek` never sent
  // an action and a tap was a self-view flash lasting one click. Claiming it costs
  // no existing behaviour, which is why it is the cheapest of the three gestures.
  //
  // ── THE HOLD STAYS INSTANT: REVEAL AT DOWN, DECIDE AT UP ───────────────────
  //
  // The naive build waits out the boundary before doing anything, which makes peek
  // slower by exactly the boundary -- on the one control whose entire value is a
  // fast answer to "is my camera working". So `onHold(true)` still fires at
  // `mouseDown`, byte-identical to the shipped version for every press past the
  // boundary, and the classification happens at `mouseUp` where the duration is
  // already known. The whole cost is that a tap flashes the tile for up to the
  // boundary before the panel opens, which is feedback that the press registered.
  var onTap: (() -> Void)?
  /// Released before this many seconds is a tap; at or after it, the hold already
  /// did its job and the release only ends it. ONE boundary, two outcomes, always
  /// exactly one of them -- a control that sometimes does nothing is worse than
  /// either wrong answer.
  ///
  /// 220 ms for peek: the hold watchdog polls at 150 ms so anything at or under
  /// that races it, deliberate click durations sit well under 200 ms, and 220 ms is
  /// below anything a person experiences as lag. `leave` raises it to its own hold
  /// boundary -- see `CallControls.leaveHoldSeconds` for why the two cannot share a
  /// number and why leave's tap window has to run all the way to its hold.
  var tapWithin: TimeInterval = 0.22
  private var downAt: Date?
  /// A tap is cancelled by sliding off the circle, the same rule `SheetRow`
  /// already implements. A HOLD is not -- `mouseDragged` below is explicit that a
  /// hold survives the pointer leaving, and that is the behaviour peek needs.
  private var slidOff = false
  /// Cumulative, because a boolean sampled after the fact is a birth certificate
  /// and not a health record. Only a count can show that one press did not
  /// classify as both a tap and a hold.
  private(set) var taps = 0

  // ── THE FIRST CLICK ON A BACKGROUND WINDOW MUST NOT HANG UP ────────────────
  //
  // `acceptsFirstMouse` is true so a click that arrives while the app is behind
  // something still counts -- right for mute, and "the whole point of a hang-up is
  // that it works the first time". But a hold that FIRES turns a click-and-hold
  // that only meant to bring the app forward into an ended call. So the state of
  // the window at `mouseDown` is recorded here and the leave hold refuses to start
  // without it. The press still activates and still arms, so nothing looks dead;
  // the hold is available from the second press on.
  private(set) var keyAtDown = false

  /// 0…1 while a hold is filling. Drawn as a sweep across the confirm capsule --
  /// the pill this widens into already exists, so the progress re-uses it instead
  /// of adding a second shape over the picture.
  var holdProgress: CGFloat = 0 {
    didSet {
      guard abs(holdProgress - oldValue) > 0.001 else { return }
      needsDisplay = true; ink.needsDisplay = true
    }
  }

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
    glass.radius = Metric.capsule(size)
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
    // HANDED TO THE GLASS, not stacked on it. See `Glass.content`: a sibling above
    // the material gets caught in the material's own resampling, and every stroked
    // glyph in the row came out soft and haloed while the one button with no glass
    // behind it -- the red leave circle -- stayed razor sharp. Same drawing code,
    // so the material was the only difference. On a Mac without Liquid Glass the
    // setter falls back to adding it as a subview, which is what it always was.
    glass.content = ink
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
    keyAtDown = window?.isKeyWindow ?? false
    guard onHold != nil else { super.mouseDown(with: event); return }
    downAt = Date()
    slidOff = false
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
    // Duration off the WALL CLOCK, not off `pressedMouseButtons`. The harness's
    // button is not a finger and is invisible to the window server -- which is the
    // whole reason `syntheticHold` exists below -- so a classifier reading the
    // physical button would file every synthetic press as a hold and the tap half
    // of this control would be untestable.
    let held = downAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
    let wasHolding = holding
    setHolding(false)
    downAt = nil
    // `wasHolding` and not `true`: the watchdog's job is "nothing is being held",
    // and a lost `mouseUp` -- hold peek, then Command-Tab away -- is not a click.
    // A tap fired from that path would open a panel nobody was looking at, and on
    // `leave` the same shape would end a call.
    guard wasHolding, !slidOff, held < tapWithin, let tap = onTap else { return }
    taps += 1
    tap()
  }
  override func mouseDragged(with event: NSEvent) {
    guard onHold == nil else {
      // A hold survives the pointer leaving; a tap does not. Same cancelled-press
      // rule every Mac button has: you can slide off a control you did not mean to
      // hit, and the slide is the cancellation.
      if !bounds.contains(convert(event.locationInWindow, from: nil)) { slidOff = true }
      return
    }
    super.mouseDragged(with: event)
  }

  func simulateHold(_ on: Bool) {
    if on { downAt = Date(); slidOff = false; keyAtDown = window?.isKeyWindow ?? false }
    setHolding(on)
  }
  /// The tap half, without a pointer. `--press peek-tap` and the menu route both
  /// come through here so they cannot drift from what a finger does.
  func simulateTap() {
    guard let tap = onTap else { return }
    taps += 1
    tap()
  }


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
    // A capsule at every width. The confirm morph stretches this button from 58 to
    // 150 points wide, and a fixed radius would have it pass through every shape
    // between a circle and a rounded rectangle on the way. Half the HEIGHT keeps it
    // a capsule throughout, so the circle grows into a pill and never looks like a
    // box with soft corners.
    glass.radius = Metric.capsule(bounds.height)
    ink.frame = bounds
  }

  override func draw(_ dirty: NSRect) {
    let d = min(bounds.width, bounds.height)
    let circle: NSBezierPath = confirming
      ? NSBezierPath(roundedRect: bounds, xRadius: 24, yRadius: 24)
      : NSBezierPath(ovalIn: NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2,
                                    width: d, height: d))
    // ── THE RED GOES BEHIND THE GLASS, NOT INTO IT ────────────────────────────
    //
    // `tintColor` was the obvious way to make this button prominent and it is the
    // wrong tool for a strong colour. The header says the tint is what the glass
    // tints the background "toward", so it BLENDS with whatever is behind: at 0.96
    // over a navy jacket, `#ef4444` photographed as a deep maroon. Correct hue,
    // wrong brightness, on the one button that has to be unmistakable.
    //
    // So the colour is a fill in this view's own backing, and the glass -- which is
    // a subview and therefore composites above it -- refracts a red field instead
    // of a blue one. Bright red, and still glass: it keeps the specular rim and the
    // interactive response, and the glyph stays crisp because it lives inside the
    // material rather than under it.
    //
    // Everything else `draw` used to do is gone. The 1 pt `--glass-line` ring
    // around every circle moved into the ink, where the material cannot resample it
    // into a soft grey band.
    if destructive {
      (hovering ? Palette.hex(0xf46b6b) : Palette.bad).setFill()
      circle.fill()
    } else if hovering {
      Palette.fill(0.10).setFill()
      circle.fill()
    }
    // ── THE HOLD, AS A RISING TIDE ACROSS THE PILL ────────────────────────────
    //
    // A veil rather than a second colour: over the red fill above, a lighter red
    // is a shade nobody can name, and over the glass paths there is no fill to
    // lighten at all. A white wash reads as "filling up" on either ground and
    // costs no new token.
    //
    // Clipped to the capsule so the sweep cannot square off the corners the morph
    // just rounded, and it is drawn HERE rather than in the ink because it belongs
    // behind the material with the colour it is washing -- the glyph and the word
    // have to stay crisp on top of it.
    if holdProgress > 0 {
      NSGraphicsContext.saveGraphicsState()
      circle.addClip()
      Palette.fill(0.28).setFill()
      NSRect(x: bounds.minX, y: bounds.minY,
             width: bounds.width * min(1, holdProgress), height: bounds.height).fill()
      NSGraphicsContext.restoreGraphicsState()
    }
  }

  /// Called by the glass, so it lands ON the material rather than under it.
  fileprivate func drawGlyph(in bounds: NSRect) {
    let d = min(bounds.width, bounds.height)
    if confirming, let text = confirmLabel {
      let r = Metric.capsule(bounds.height)
      let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                              xRadius: r, yRadius: r)
      Palette.fill(hovering ? 0.34 : 0.16).setStroke()
      edge.lineWidth = 1
      edge.stroke()
      // Glyph and word side by side, the pair centred: `gap: 8px`, 13px semibold.
      let gsize: CGFloat = 22
      let f = Type_.confirm
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
    // ── THE EDGE, DRAWN WHERE IT STAYS CRISP ──────────────────────────────────
    //
    // Liquid Glass draws a specular rim of its own, and over bright content it is
    // plenty. Over a dark navy jacket it nearly vanishes, and four discs with no
    // edge on a dark picture are four things you have to look for. So there is a
    // hairline again -- but here, in the ink, INSIDE the glass, rather than in
    // `draw` underneath it where the material resampled it into a soft grey band.
    //
    // Faint on purpose. It is helping the material find its edge on dark content,
    // not replacing it; it brightens on hover, which is the one thing the glass
    // itself has no opinion about.
    let edge = NSBezierPath(ovalIn: NSRect(
      x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
      .insetBy(dx: 0.5, dy: 0.5))
    Palette.fill(hovering ? 0.34 : 0.16).setStroke()
    edge.lineWidth = 1
    edge.stroke()
    if on {
      // `box-shadow: inset 0 0 0 1.5px rgba(255,255,255,.35)`.
      let r = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        .insetBy(dx: 1.5, dy: 1.5)
      Palette.fill(0.35).setStroke()
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
  // REGULAR: it carries words, over a face, with nothing dimming it. The regular
  // variant "blurs and adjusts the luminosity of background content to maintain
  // legibility of text", which is the whole job of this view.
  private let glass = Glass(radius: 0, variant: .regular)
  var textColor: NSColor = Palette.fg { didSet { label.textColor = textColor } }

  init(font: NSFont = Type_.status) {
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
      let font = label.font ?? Type_.status
      let size = (text as NSString).size(withAttributes: [.font: font])
      let w = ceil(size.width) + 26
      let h: CGFloat = 27
      setFrameSize(NSSize(width: w, height: h))
      glass.frame = NSRect(x: 0, y: 0, width: w, height: h)
      glass.radius = Metric.capsule(h)
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
// NOT `final`: `ContactRow` below is this row with a face drawn in the glyph slot,
// and subclassing is what makes the four scars in here -- the hit test, the first
// mouse, the hand-rolled tracking, the spoken string -- inherited instead of
// re-derived by a second row class that would get one of them wrong.
class SheetRow: NSButton {
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
  /// This value is a WORD, not a code. The code treatment is monospace at 0.09em of
  /// letter-spacing, which exists so two people can read a safety code aloud
  /// character by character -- and applied to "copy" it drew `c o p y` in a
  /// typewriter face, which reads as a serial number rather than as something to
  /// press. Same slot, different job, so it has to be told which.
  var valueIsWord = false { didSet { needsDisplay = true } }
  /// Where the words start. A stored property rather than the `glyph == nil`
  /// expression it replaces, so a subclass drawing a WIDER mark than a glyph can
  /// move the text without overriding `layout` and re-deriving the rest of it.
  var textInset: CGFloat = Metric.s3 { didSet { needsLayout = true } }

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
    textInset = glyph == nil ? Metric.s3 : Metric.rowGlyphInset
    super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 48))
    isBordered = false
    title = ""
    setAccessibilityLabel(label)
    text.font = Type_.row
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
    let x = textInset
    text.frame = NSRect(x: x, y: (bounds.height - 18) / 2, width: bounds.width - x - 40, height: 18)
  }

  override func draw(_ dirty: NSRect) {
    if hovering || pressed {
      // A VIBRANT FILL, NOT A SECOND PANE OF GLASS. "Avoid overcrowding or layering
      // Liquid Glass elements on top of each other" -- and a row highlight inside a
      // glass sheet is the most tempting place in the app to break that rule.
      //
      // The radius is CONCENTRIC with the sheet rather than picked: the row is
      // inset by `sheetPad` inside a corner of `sheetRadius`, so sharing a centre of
      // curvature means 26 - 10 = 16. It was 12, which is the kind of number that
      // looks deliberate and is off by four.
      Palette.fill(pressed ? 0.12 : 0.06).setFill()
      let r = Metric.sheetRowRadius
      NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
    }
    if ruled {
      Palette.fill(0.09).setStroke()
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
      let f = valueIsWord ? Type_.button
            : (pending ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : Type_.code)
      var a: [NSAttributedString.Key: Any] = [
        .font: f, .foregroundColor: (pending || valueIsWord) ? Palette.muted : Palette.fg,
      ]
      if !pending, !valueIsWord { a[.kern] = 13.0 * 0.09 }
      let sz = (value as NSString).size(withAttributes: a)
      (value as NSString).draw(at: NSPoint(x: bounds.width - sz.width - Metric.s3,
                                          y: (bounds.height - sz.height) / 2),
                               withAttributes: a)
    }
    if checked {
      // `.tick`: stroke 2.2, var(--ok), right-aligned.
      let t = NSBezierPath()
      let x = bounds.width - 30, y = bounds.height / 2  // 18 pt tick, 12 pt from the edge
      t.move(to: NSPoint(x: x, y: y))
      t.line(to: NSPoint(x: x + 4.5, y: y - 4.5))
      t.line(to: NSPoint(x: x + 14, y: y + 6))
      t.lineWidth = 2.2; t.lineCapStyle = .round; t.lineJoinStyle = .round
      Palette.ok.setStroke(); t.stroke()
    }
  }
}

// ── A PERSON, IN THE GLYPH SLOT ──────────────────────────────────────────────
//
// A SUBCLASS, so every scar `SheetRow` already paid for is inherited rather than
// re-derived. There are four of them and each one cost a live defect: a `hitTest`
// that takes SUPERVIEW coordinates and tests `frame`; `acceptsFirstMouse`, without
// which every row is dead while the app is behind something; the hand-rolled
// `mouseDown` tracking that exists because overriding `isFlipped` silently stops
// `NSButtonCell` from ever firing; and a `spoken` string, which exists because the
// harness has to click the list and read it back.
//
// Do not "simplify" the manual tracking away and do not touch `isFlipped`. That is
// the same bug with the diff reversed.
//
// The other return on subclassing is that `clickTargets` needed no line at all --
// it already collects `sheet.rows`, and a `ContactRow` IS a `SheetRow`.
final class ContactRow: SheetRow {
  private let handle: String
  /// Who this row is, for the action that has to ring them. `tag` is taken -- the
  /// camera rows use it as an index -- and a handle is not an integer.
  var handleName: String { handle }

  /// The handle is the row: the colour, the letter and the words all come from it.
  /// A separate display name would be a local nickname, and names are deliberately
  /// not a thing this version has -- see CONTACTS.md on why a name over the wire is
  /// a claim and needs a trust model this app does not yet have.
  init(handle: String) {
    self.handle = handle
    super.init("@" + handle, glyph: nil)
    textInset = Metric.rowAvatarInset
    setAccessibilityLabel("call @" + handle)
  }
  required init?(coder: NSCoder) { fatalError() }

  // ── DRAWN, NOT LAYERED ─────────────────────────────────────────────────────
  //
  // `Display.snapshot` is `cacheDisplay`-based and cannot see a layer-only
  // background: that blindness ran a scrim gradient backwards through every
  // screenshot ever taken of this app. A sublayer here would photograph as an
  // empty row in the app's own capture and as a circle through the window server,
  // which is two instruments disagreeing about the same screen.
  override func draw(_ dirty: NSRect) {
    super.draw(dirty)
    let d = Metric.avatar
    let box = NSRect(x: Metric.s3, y: (bounds.height - d) / 2, width: d, height: d)
    let ink = Palette.avatarInk(handle)
    // A fill and a hairline, the same idiom as every other thing that lives INSIDE
    // a glass surface. A second pane of glass here would be the one place in the
    // app that breaks "avoid layering Liquid Glass elements on top of each other",
    // and it would be a pane per contact.
    Palette.fill(0.08).setFill()
    NSBezierPath(ovalIn: box).fill()
    let ring = NSBezierPath(ovalIn: box.insetBy(dx: Metric.avatarRing / 2, dy: Metric.avatarRing / 2))
    ink.setStroke()
    ring.lineWidth = Metric.avatarRing
    ring.stroke()
    // `handle.first` uppercased, and it is always a letter: the server's rule is
    // `^[a-z][a-z0-9]{1,31}$` and `Identity.sanitize` applies it before anything
    // reaches here. No empty initial, no emoji, no combining marks to measure.
    let letter = String(handle.prefix(1)).uppercased()
    let attrs: [NSAttributedString.Key: Any] = [.font: Type_.avatar, .foregroundColor: ink]
    let sz = (letter as NSString).size(withAttributes: attrs)
    (letter as NSString).draw(at: NSPoint(x: box.midX - sz.width / 2,
                                          y: box.midY - sz.height / 2),
                              withAttributes: attrs)
  }
}

// ── THE ONE THING IN THE SHEET YOU TYPE INTO ─────────────────────────────────
//
// Built from the waiting card's dial field rather than invented: a `Vibrant` well
// with a plain `NSTextField` in it, Enter commits, and the whole row routes clicks
// to the FIELD rather than to itself.
//
// That last part is the one rule this cannot copy from `SheetRow`. Every row here
// answers `self` because a row handles its own presses; a text field cannot work
// that way, because typing needs it to become first responder and that only
// happens if the click actually reaches it. Routing this to `self` like the rest
// gives a field that draws, highlights on hover, and can never be typed into.
final class SheetField: NSView {
  private let well = Vibrant()
  let field = NSTextField()
  var onCommit: (() -> Void)?

  var text: String {
    get { field.stringValue }
    set { field.stringValue = newValue }
  }

  init(placeholder: String, text: String) {
    super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Metric.sheetRow))
    addSubview(well)
    field.font = Type_.field
    field.textColor = Palette.fg
    field.backgroundColor = .clear
    field.drawsBackground = false
    field.isBordered = false
    field.isEditable = true
    field.isSelectable = true
    field.focusRingType = .none
    field.placeholderString = placeholder
    field.stringValue = text
    field.target = self
    field.action = #selector(committed)
    addSubview(field)
  }
  required init?(coder: NSCoder) { fatalError() }

  @objc private func committed() { onCommit?() }

  /// See IconButton.acceptsFirstMouse.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, frame.contains(point) else { return nil }
    return field
  }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

  override func layout() {
    super.layout()
    let h = Metric.fieldHeight
    let r = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
    well.frame = r
    // Concentric with the sheet across the padding the sheet already puts around
    // its rows, exactly as `sheetRowRadius` is. A literal here would be the tenth
    // magic radius this design system exists to have removed.
    well.radius = Metric.sheetRowRadius
    field.frame = NSRect(x: r.minX + Metric.s3, y: r.midY - 9,
                         width: r.width - Metric.s6, height: 18)
  }
}

/// `.sheet .hint { font-size: 11px; color: var(--muted); padding: 8px 12px 2px }`
final class SheetHint: NSView {
  private let label = NSTextField(labelWithString: "")
  /// What this actually needs, rather than the 34 points every hint used to get.
  /// The one hint in the app wraps to two lines and was drawn into a box built for
  /// something between one and two, so its second line sat on the sheet's bottom
  /// edge with its descenders in the corner radius.
  private(set) var wantedHeight: CGFloat = Metric.sheetHint
  func measure(width: CGFloat) {
    let inner = width - Metric.s3 * 2
    let r = (label.stringValue as NSString).boundingRect(
      with: NSSize(width: inner, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: label.font ?? Type_.caption])
    wantedHeight = ceil(r.height) + Metric.s3 + Metric.s1
  }
  init(_ text: String) {
    super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
    label.stringValue = text
    label.font = Type_.caption
    label.textColor = Palette.muted
    label.maximumNumberOfLines = 3
    label.lineBreakMode = .byWordWrapping
    label.backgroundColor = .clear
    label.isBordered = false
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    label.frame = NSRect(x: Metric.s3, y: Metric.s1, width: bounds.width - Metric.s3 * 2,
                         height: bounds.height - Metric.s2)
  }
}

// ── AN INSET PANEL, NOT A TRAY ──────────────────────────────────────────────
//
// This was `border-radius: 20px 20px 0 0`, transcribed from the web app: a sheet
// glued to the bottom edge of the window, square where it met it. That is the
// phone idiom the web app was built for, and it is not what a Mac does any more --
// "half sheets are inset from the edge of the display to allow content to peek
// through from beneath them", and they took on a larger radius at the same time.
//
// It also fixes something that was simply wrong. Photographed with the sheet open,
// the control row showed THROUGH the panel and the hint text ran straight across
// the mute and camera buttons, because a tray pinned to the bottom edge occupies
// exactly the space the bar lives in. Floating it clear of the bar means the two
// no longer share any pixels.
final class Sheet: NSView {
  /// REGULAR: this is the one surface in the app made mostly of sentences, and the
  /// guidance names exactly this case -- "components have a significant amount of
  /// text, such as alerts, sidebars, or popovers".
  private let glass = Glass(radius: Metric.sheetRadius, variant: .regular)
  private(set) var rows: [SheetRow] = []
  /// The one field a page can carry, so `clickTargets` can name it without every
  /// caller having to hold on to the view it just handed over.
  private(set) var field: SheetField?

  // ── ONE SHEET, THREE PAYLOADS ──────────────────────────────────────────────
  //
  // People and rename are PAGES of this panel and not new surfaces, and the reason
  // is that a new panel re-earns every hard part: a `hitTest` that takes superview
  // coordinates, `acceptsFirstMouse`, hover and press states, hand-rolled click
  // tracking, a spoken string -- and the three ways out that need no aiming (a
  // click on the scrim, a swipe down, Escape). Each of those was paid for once
  // already, in this class or the one above it.
  //
  // It is also the only surface that exists on both sides of the join: the sheet
  // is there behind the waiting card and it is there mid-call, so `People` is
  // reachable at the moment somebody actually wants to ring a person.
  enum Page: String { case settings, people, rename }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    // ── A TINT, BECAUSE THIS ONE HAS TO BE READ ───────────────────────────────
    //
    // Regular glass already "blurs and adjusts the luminosity of background content
    // to maintain legibility", and over a dark room it is enough on its own. Over a
    // brightly lit face it is not: photographed open on a real call, the hint line
    // under the encryption code was grey text on a grey astronaut. Tinting is the
    // sanctioned way to push a surface toward a value -- it is still a material,
    // still refracting, just no longer at the mercy of what the camera is pointed
    // at.
    glass.tint = Palette.glassTint
    addSubview(glass)
    // The grip -- a 36x4 pill at the top -- went with the bottom tray. It is a
    // phone affordance for a sheet you drag off the bottom of a screen, and this is
    // a popover hanging under the button that opened it. Nothing here is draggable,
    // so a handle saying it is would be a lie. `onSwipeDown` still works for the
    // harness and for anyone who tries it.
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
    field = v.compactMap { $0 as? SheetField }.first
    // Measured BEFORE `wantedHeight` is asked for, or the panel is sized from a
    // hint's placeholder height and then draws a taller one inside it.
    let inner = Metric.sheetWidth - Metric.sheetPad * 2
    for h in v.compactMap({ $0 as? SheetHint }) { h.measure(width: inner) }
    v.forEach(addSubview)
    needsLayout = true
  }

  private func height(of v: NSView) -> CGFloat {
    (v as? SheetHint)?.wantedHeight ?? Metric.sheetRow
  }

  /// Padding, the items, and the same padding again. Symmetrical now: the old
  /// 10-top/26-bottom asymmetry was paying for a bottom edge that ran off the
  /// window, and there is no such edge any more.
  var wantedHeight: CGFloat {
    Metric.sheetPad + items.reduce(0) { $0 + height(of: $1) } + Metric.sheetPad
  }

  override func layout() {
    super.layout()
    glass.frame = bounds
    glass.radius = Metric.sheetRadius
    var y = bounds.height - Metric.sheetPad
    for v in items {
      let h = height(of: v)
      y -= h
      v.frame = NSRect(x: Metric.sheetPad, y: y,
                       width: bounds.width - Metric.sheetPad * 2, height: h)
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
  // ── ONE CARD, NOT FIVE THINGS FLOATING ────────────────────────────────────
  //
  // Title, hint, link, two buttons, a field and a third button, each drifting
  // separately in the middle of somebody's picture, each carrying its own
  // `text-shadow: 0 1px 8px rgba(0,0,0,.85)` to stay readable. Seven shadows is
  // what a screen looks like when nothing on it has a surface to sit on.
  //
  // A panel gives them one, and it is what the material is FOR: this is the app's
  // one text-heavy moment, so it is regular glass, tinted, with the picture
  // refracting through it. The controls are still direct subviews of this card and
  // the panel is only a sibling behind them -- the hit-testing here has been fixed
  // three times and moving every frame into a new coordinate space to gain nothing
  // visible would be asking for a fourth.
  private let panel = Glass(radius: Metric.cardRadius, variant: .regular)
  private let wash = CAGradientLayer()
  private let title = NSTextField(labelWithString: "Waiting for the other person…")
  private let hint = NSTextField(labelWithString: "This link is the key — anyone who has it can join")
  private let urlField = NSTextField(labelWithString: "")
  // NOT glass. See `Vibrant`: these sit on the card's glass, and a pane of glass on
  // a pane of glass is the one thing the guidance names outright.
  private let urlGlass = Vibrant()
  private let shareButton = PillButton("share")
  private let copyButton = PillButton("copy")
  // ── CALLING A NAME INSTEAD OF SENDING A LINK ────────────────────────────────
  //
  // The one editable thing in this app, and it lives here because this screen is
  // where somebody already is when they want to reach a person: the link is for
  // people you have never called, the field is for the ones you have.
  private let dialGlass = Vibrant()
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

  /// Put the caret in the name field. The people panel's "Call someone new" row
  /// hands over to this rather than growing a second field: there is exactly one
  /// place in this app you type a name into, and two of them would be two places
  /// that can disagree about what a name is.
  @discardableResult
  func focusDial() -> Bool {
    guard !dialField.isHidden, let w = window else { return false }
    return w.makeFirstResponder(dialField)
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

    panel.tint = Palette.glassTint
    addSubview(panel)

    for (t, font, colour) in [(title, Type_.title, Palette.fg),
                              (hint, Type_.caption, Palette.muted)]
        as [(NSTextField, NSFont, NSColor)] {
      t.font = font
      t.textColor = colour
      t.alignment = .center
      t.backgroundColor = .clear
      t.isBordered = false
      // A backstop for the same failure the width calculation fixes. The card is
      // sized to the text, but the window can be narrower than the text; when it
      // is, this ends the line with an ellipsis instead of cutting a word in half,
      // which at least reads as "there is more" rather than as a broken layout.
      t.lineBreakMode = .byTruncatingTail
      // The `text-shadow: 0 1px 8px rgba(0,0,0,.85)` that used to be set here is
      // gone. It existed to keep white text legible over an unknown camera frame,
      // and there is a panel under the text now doing that job properly. A drop
      // shadow on type sitting on a material reads as a printing fault.
      addSubview(t)
    }
    urlField.font = Type_.mono
    urlField.textColor = Palette.fg
    urlField.alignment = .center
    urlField.backgroundColor = .clear
    urlField.isBordered = false
    urlField.isSelectable = true
    // ── A BLACK RECTANGLE BEHIND THE LINK ─────────────────────────────────────
    //
    // There were two lines here, one for each field:
    //     urlGlass.layer?.backgroundColor = rgba(8,11,18,.9)
    // Harmless when `Glass` WAS the blur -- it was the fill that made the old
    // material readable. Now `Glass` is a wrapper and its own layer is the
    // un-rounded outer box, so the same line painted a hard-edged opaque black
    // rectangle across the material and out past its corners.
    //
    // Invisible for as long as this screen was photographed over black, which is
    // every screenshot ever taken of it: the app's own snapshot cannot see a
    // material, and the capture rig was running the near end with `--video off`.
    // Over a real picture -- which is what a waiting user is actually looking at,
    // because `showSelf` puts your own camera in the window until someone
    // arrives -- it was the first thing you saw.
    addSubview(urlGlass)
    addSubview(urlField)
    shareButton.onPress = { [weak self] in self?.onShare?() }
    copyButton.onPress = { [weak self] in self?.onCopy?() }
    addSubview(shareButton)
    addSubview(copyButton)

    dialField.font = Type_.row
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
    let ringing = incoming != nil
    let pad = Metric.cardPad
    let gap = Metric.s2
    let uh = Metric.fieldHeight

    // ── THE CARD IS MEASURED, NOT PLACED ──────────────────────────────────────
    //
    // Everything below used to be positioned relative to the window's centre with
    // its own margin, so the spacing between any two things was the difference of
    // two numbers written in different places. Here the ROWS are measured first,
    // the panel is sized to hold them, and every position falls out of that -- so a
    // longer link or a hidden row moves the card instead of overflowing it.
    //
    // The link is as wide as the link, within reason. It was a flat 320, which is
    // narrower than the URLs this app generates: the tail of a long room name went
    // under the right edge and the one thing on this screen you might need to read
    // character by character was the one thing clipped.
    let linkW = min(max(300, ceil((urlField.stringValue as NSString)
                   .size(withAttributes: [.font: urlField.font ?? Type_.mono]).width) + Metric.s8),
                    bounds.width * 0.6)
    let linkRowW = linkW + gap + shareButton.frame.width + gap + copyButton.frame.width
    let dialW = min(260, bounds.width * 0.45)
    let dialRowW = dialW + gap + callButton.frame.width
    let ringRowW = answerButton.frame.width + gap + declineButton.frame.width

    let titleH: CGFloat = 24, hintH: CGFloat = 16
    let rowsW = ringing ? ringRowW : max(linkRowW, dialRowW)
    let rowsH = ringing ? uh : uh * 2 + Metric.s3
    // ── THE TEXT IS PART OF THE WIDTH ─────────────────────────────────────────
    //
    // The card was sized from `rowsW` alone. That is fine for the invite state,
    // where a link 300 points wide is the widest thing in it -- and wrong for the
    // ringing state, where the widest thing is a sentence and the row is two small
    // pills. Photographed with `--incoming devesh`, the hint read
    //
    //     answer and you will both be in the sa
    //
    // clipped mid-word by a panel built around two buttons. A card has to be as
    // wide as its widest CHILD, and the words are children.
    func textW(_ f: NSTextField) -> CGFloat {
      ceil((f.stringValue as NSString)
        .size(withAttributes: [.font: f.font ?? Type_.caption]).width)
    }
    let contentW = max(rowsW, textW(title), textW(hint))
    let panelW = min(bounds.width - Metric.gutter * 2, contentW + pad * 2)
    let panelH = pad + titleH + Metric.s1 + hintH + Metric.s5 + rowsH + pad
    panel.frame = NSRect(x: cx - panelW / 2, y: cy - panelH / 2, width: panelW, height: panelH)
    panel.radius = Metric.cardRadius

    var y = panel.frame.maxY - pad - titleH
    title.frame = NSRect(x: panel.frame.minX, y: y, width: panelW, height: titleH)
    y -= Metric.s1 + hintH
    hint.frame = NSRect(x: panel.frame.minX, y: y, width: panelW, height: hintH)
    y -= Metric.s5 + uh

    // The link row: link, share, copy, centred as one.
    var x = cx - linkRowW / 2
    urlGlass.frame = NSRect(x: x, y: y, width: linkW, height: uh)
    urlGlass.radius = Metric.cardFieldRadius
    urlField.frame = NSRect(x: x + Metric.s3, y: y + (uh - 15) / 2,
                            width: linkW - Metric.s6, height: 15)
    x += linkW + gap
    shareButton.frame.origin = NSPoint(x: x, y: y + (uh - shareButton.frame.height) / 2)
    x += shareButton.frame.width + gap
    copyButton.frame.origin = NSPoint(x: x, y: y + (uh - copyButton.frame.height) / 2)

    // Answering shares the link row's line: it is the same decision in the same
    // place, and `answer` sits on the left where `copy` is not.
    var ax = cx - ringRowW / 2
    answerButton.frame.origin = NSPoint(x: ax, y: y + (uh - answerButton.frame.height) / 2)
    ax += answerButton.frame.width + gap
    declineButton.frame.origin = NSPoint(x: ax, y: y + (uh - declineButton.frame.height) / 2)

    // The dial row, one row below the link row and built the same way, so the two
    // read as alternatives rather than as two unrelated features.
    y -= Metric.s3 + uh
    var dx = cx - dialRowW / 2
    dialGlass.frame = NSRect(x: dx, y: y, width: dialW, height: uh)
    dialGlass.radius = Metric.cardFieldRadius
    dialField.frame = NSRect(x: dx + Metric.s4, y: y + (uh - 17) / 2,
                             width: dialW - Metric.s8, height: 17)
    dx += dialW + gap
    callButton.frame.origin = NSPoint(x: dx, y: y + (uh - callButton.frame.height) / 2)
  }
}

/// `#copy, #shareBtn`: a 999 px glass pill with a word in it.
final class PillButton: NSView {
  /// See IconButton.acceptsFirstMouse.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  // Every one of these lives on the waiting card's glass panel, so it is a fill.
  // It was a `Glass`, which made the card five panes deep in places.
  private let glass = Vibrant()
  private let label = NSTextField(labelWithString: "")
  private var hovering = false
  var onPress: (() -> Void)?
  var tint: NSColor = Palette.fg { didSet { label.textColor = tint } }
  /// The one button on a surface that people are meant to press. Brighter fill,
  /// heavier word -- the difference between "Join" and "Suggest" next to it.
  var prominent = false {
    didSet {
      glass.level = prominent ? 0.30 : 0.13
      glass.edge = prominent ? 0.34 : 0.14
      label.font = prominent ? Type_.buttonProminent : Type_.button
    }
  }
  private var title2Storage = ""
  var title2: String {
    get { title2Storage }
    set { setTitle(newValue) }
  }
  init(_ text: String) {
    super.init(frame: .zero)
    wantsLayer = true
    // A shade up from a field: a button asks to be pressed, a field asks to be read.
    glass.level = 0.13
    addSubview(glass)
    label.font = Type_.button
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
    let w = ceil((t as NSString).size(withAttributes: [.font: label.font!]).width) + Metric.s8
    setFrameSize(NSSize(width: w, height: Metric.pillHeight))
    needsLayout = true
  }

  override func layout() {
    super.layout()
    glass.frame = bounds
    glass.radius = Metric.capsule(bounds.height)
    label.frame = NSRect(x: 4, y: (bounds.height - 15) / 2, width: bounds.width - 8, height: 15)
  }
  override func mouseDown(with event: NSEvent) { onPress?() }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

  // A word in a pill is a target, so it answers to the pointer. The old glass
  // version could not: `NSGlassEffectView` has an interactive mode of its own and
  // a fill has none, so the feedback is drawn here.
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                   owner: self, userInfo: nil))
  }
  override func mouseEntered(with event: NSEvent) {
    hovering = true; glass.level = prominent ? 0.42 : 0.20
  }
  override func mouseExited(with event: NSEvent) {
    hovering = false; glass.level = prominent ? 0.30 : 0.13
  }
}

final class CallControls: NSView {
  /// Space at the bottom the video should not put anything important in. Published
  /// so the self-view sits above the bar rather than a second file guessing.
  /// Derived now, rather than the constant 98 it used to be, so moving the row off
  /// the edge cannot leave the self-view overlapping it.
  static let barHeight: CGFloat = Metric.barInset + Metric.control + Metric.s4

  private let roomPill = Pill(font: Type_.status)
  /// The dark layer the HIG asks for behind clear glass over bright content, at
  /// the 35% it names. Two of them, because there are controls at both ends of the
  /// window and a face in the middle that neither should touch.
  private let scrim = CAGradientLayer()
  private let topScrim = CAGradientLayer()
  /// The five bar circles, in a container that lets them notice each other. See
  /// GlassGroup: at rest the spacing is below the gap so they stay five separate
  /// targets, and it is animated up only while the row collapses into the leave
  /// confirmation, where they flow into it instead of blinking out.
  private let barGroup = GlassGroup(frame: .zero)
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
  // ── ONE CONTROL SAYING BOTH OF ITS GESTURES ────────────────────────────────
  //
  // `help` feeds the tooltip AND the accessibility label, and two gestures on one
  // circle is genuinely worse for VoiceOver than two controls. The mitigation is
  // that the gesture is never the only way in: the sheet carries a People row, the
  // Call menu carries People… with its own shortcut, and both reach the same panel.
  private let peekButton = IconButton(Glyph.peek, help: "tap for people · hold to see yourself")
  private let flipButton = IconButton(Glyph.flip, help: "switch camera")
  private let xlateButton = IconButton(Glyph.xlate, help: "live translation")
  private let leaveButton = IconButton(Glyph.leave, help: "leave call")
  /// `#more`, top-right corner, out of the thumb row -- smaller than a bar circle,
  /// because it is a secondary control and should not read as a sixth action.
  private let moreButton = IconButton(Glyph.more, size: Metric.controlSmall, help: "more")
  private let sheet = Sheet()
  private let waiting = WaitingCard()
  /// `#status`: a pill, TOP-CENTRE, not a room name in the corner. The room's name
  /// is not something the web app ever shows -- the link is.
  private let statusPill = Pill(font: Type_.status)
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
  private let warnPill = Pill(font: Type_.status)
  // `#elapsed`, the mm:ss clock above the status pill, was here. Removed on
  // request; see the note in `init` for why that loses no signal.
  /// ── THE TURN-TAKING LAYER ──────────────────────────────────────────────────
  ///
  /// The floor cue, the listening-noise bloom and the caption band. See Cues.swift
  /// for why there are three of them and why none of them says a word about what
  /// you should do. It sits UNDER the button row and passes every click through.
  private let cues = TurnCues(frame: .zero)
  /// `.sheetScrim`: a click anywhere else closes the sheet, which is how every
  /// bottom panel on a phone behaves and the only way out that needs no aiming.
  private let sheetScrim = ScrimView()
  private let camPicker = NSPopUpButton()
  private let camGlass = Glass(radius: 0, variant: .regular)
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
    onMain { [weak self] in self?.refreshSheet() }
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
    // ── 35%, WHICH IS THE HIG'S NUMBER AND NOT THE WEB APP'S ─────────────────
    //
    // This was 0.72, transcribed from CSS where it had to be that dark because
    // there was no material underneath it -- the whole job of legibility fell on
    // the scrim. There is a material now, so the scrim only has to do the part the
    // guidance describes: "If the underlying content is bright, consider adding a
    // dark dimming layer of 35% opacity." At 0.72 it was a black band across the
    // bottom of somebody's face; at 0.35 it is a shadow.
    scrim.colors = [NSColor.clear.cgColor, Palette.dim.cgColor]
    scrim.locations = [0, 0.62]
    layer?.addSublayer(scrim)

    // ── AND ONE AT THE TOP, FOR THE SAME REASON ──────────────────────────────
    //
    // The bottom of the window had a dim and the top did not, so the status pill
    // and the `more` button floated over an undimmed face -- and `more` is clear
    // glass, which over a bright forehead is a smudge you cannot find. It also
    // protects the traffic lights, which `.fullSizeContentView` put on top of the
    // picture. Lighter than the bottom and shorter, because there is one small
    // control up here and five big ones down there.
    topScrim.startPoint = CGPoint(x: 0.5, y: 0)
    topScrim.endPoint = CGPoint(x: 0.5, y: 1)
    topScrim.colors = [NSColor.clear.cgColor,
                       Palette.dim.withAlphaComponent(0.28).cgColor]
    topScrim.locations = [0, 0.7]
    layer?.addSublayer(topScrim)

    // ── THE ROW GOES IN THE GROUP, NOT ON THE OVERLAY ────────────────────────
    //
    // A glass container only merges views that are descendants of its content
    // view. Adding these five to `self` beside the container -- which is what every
    // other control in this file does -- would leave them outside the effect,
    // rendering identically and morphing not at all. `more` stays outside on
    // purpose: it lives in the opposite corner and has nothing to flow into.
    // Under the row, so a caption can never draw over a button, and above the
    // scrim, so it gets the dimming the scrim is there to give it.
    addSubview(cues)
    addSubview(barGroup)
    barGroup.spacing = CallControls.restSpacing
    for b in [micButton, camButton, peekButton, flipButton, leaveButton] {
      barGroup.content.addSubview(b)
    }
    addSubview(moreButton)
    micButton.target = self; micButton.action = #selector(toggleMic)
    camButton.target = self; camButton.action = #selector(toggleCam)
    peekButton.onHold = { [weak self] on in
      self?.onPeek?(on)
      self?.peeking = on
      // Counted on the way DOWN only, so one hold is one press and not two. It
      // was the last control on the bar that left no trace of having been used.
      if on { Metrics.tap("peek", ok: self?.peeking == true) }
    }
    // The second gesture on the same circle. A tap is not a hold that ended early:
    // it is the route to the people panel, and it is claimed here because until now
    // a quick click on peek did nothing at all except flash the tile for the length
    // of the click.
    peekButton.onTap = { [weak self] in
      Metrics.tap("peek_tap")
      self?.openPeople()
    }
    flipButton.target = self; flipButton.action = #selector(nextCamera)
    // ── LEAVE HAS NO target/action ANY MORE, AND THAT IS DELIBERATE ────────────
    //
    // `IconButton.mouseDown` returns before `super.mouseDown` whenever `onHold` is
    // set, so an `NSButton` action on a hold button never fires. Assigning one here
    // and expecting it to work is precisely the dead control this file keeps
    // finding: it would compile, validate, draw, highlight on hover and never send.
    // Both gestures come through the two closures instead.
    leaveButton.onHold = { [weak self] on in self?.leaveHold(on) }
    leaveButton.onTap = { [weak self] in self?.leaveTap() }
    // ── LEAVE'S TAP WINDOW RUNS ALL THE WAY TO ITS HOLD ───────────────────────
    //
    // peek's 220 ms boundary would leave a dead band here: a SECOND press released
    // between 220 and 600 ms is neither a tap that hangs up nor a hold that
    // completes, so the app would do nothing at the one moment somebody is trying
    // to end a call. One boundary, two outcomes -- under 600 ms it was a tap,
    // at or over it the hold has already gone.
    leaveButton.tapWithin = CallControls.leaveHoldSeconds
    moreButton.target = self; moreButton.action = #selector(toggleMore)
    sheetScrim.isHidden = true
    // It was added, framed, and wired to nothing: `moreScrim` in the web app is
    // `onclick = () => setSheet(false)`, and here a click on it went nowhere, so the
    // only way to shut the sheet was to find the same 48 px disc again.
    sheetScrim.onClick = { [weak self] in self?.closeMore() }
    sheet.onSwipeDown = { [weak self] in self?.closeMore() }
    sheet.isHidden = true
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
    // Through `dial`, not straight at `onCall`. The field and a tapped face are the
    // same act and they now travel the same line -- including the fallback for a
    // doorbell that is not wired, which the field used to be missing.
    waiting.onCall = { [weak self] h in self?.dial(h) }
    waiting.onAnswer = { [weak self] in self?.onAnswerRing?() }
    waiting.onDecline = { [weak self] in
      self?.waiting.clearIncoming()
      self?.setStatus("declined")
      self?.onDeclineRing?()
    }
    addSubview(waiting)
    // ── THE PANEL GOES ABOVE THE CARD, AND IT DID NOT ─────────────────────────
    //
    // These two were added before the waiting card, so the card drew OVER them --
    // and the two overlap the moment the sheet is more than a few rows tall,
    // because the card is centred and the panel hangs off the right gutter. With
    // two rows in it nothing touched, which is why every screenshot of the sheet
    // ever taken looked correct; the people page is the first one long enough to
    // reach the card's corner.
    //
    // It also makes the scrim's contract uniform. `sheetScrim` fills the window and
    // its whole job is to take one click and close what is in front of it -- but
    // the card sat above it and answered first, so the copy button was the one
    // place on the screen where clicking outside the panel did not close it.
    addSubview(sheetScrim)
    addSubview(sheet)

    // The one stock control left, so it gets a glass backing rather than the grey
    // AppKit bezel that made the whole bottom-left corner look like a preferences
    // pane bolted onto a call.
    camGlass.isHidden = true
    addSubview(camGlass)
    camPicker.isHidden = true
    camPicker.isBordered = false
    camPicker.font = Type_.caption
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
    topScrim.frame = CGRect(x: 0, y: h - 130, width: w, height: 130)

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
    //
    // That is still true and the group does not change it. `NSGlassEffectContainerView`
    // draws nothing itself; below its `spacing` the circles render exactly as five
    // separate discs. What it adds is that they can now FLOW into each other when
    // the row changes shape, which a set of unrelated views can never do.
    let bw = Metric.control, gap = Metric.controlGap, bottomPad = Metric.barInset
    // The group is the row's own coordinate space: a strip the height of a circle,
    // sitting where the row sits. Every button frame below is relative to it.
    barGroup.frame = NSRect(x: 0, y: bottomPad, width: w, height: bw)
    let row = [micButton, camButton, peekButton, flipButton, leaveButton]
      .filter { !$0.isHidden }
    if leaveArmed {
      // `.bar.confirming .icon-btn:not(.leave) { width: 0; opacity: 0;
      //  pointer-events: none }` -- the row contracts to the one decision. Six
      // circles plus a 150 px pill overflowed a phone, and the overflow left a live
      // mute button under the finger already travelling toward "leave".
      for b in row where b !== leaveButton {
        b.frame = NSRect(x: w / 2, y: 0, width: 0, height: bw)
        b.alphaValue = 0
      }
      leaveButton.frame = NSRect(x: (w - 150) / 2, y: 0, width: 150, height: bw)
    } else {
      let rowW = CGFloat(row.count) * bw + CGFloat(max(0, row.count - 1)) * gap
      var x = (w - rowW) / 2
      for b in row {
        b.frame = NSRect(x: x, y: 0, width: bw, height: bw)
        if barShown { b.alphaValue = 1 }
        x += bw + gap
      }
    }
    // `#more`: top-right. On the gutter, so it lines up with everything else that
    // lives against an edge instead of keeping its own private 14.
    let mb = Metric.controlSmall
    moreButton.frame = NSRect(x: w - mb - Metric.gutter, y: h - mb - Metric.gutter,
                              width: mb, height: mb)

    // ── IT COMES OUT OF THE BUTTON THAT OPENED IT ─────────────────────────────
    //
    // This was `bottom: 0; left: 50%` -- a tray glued to the bottom edge of the
    // window, transcribed from the web app, where it is the right idiom because the
    // web app is mostly used on a phone. Two things were wrong with it here.
    //
    // It sat exactly where the control row sits: photographed open on a real call,
    // the mute and camera circles showed straight through the panel and a line of
    // hint text ran across them.
    //
    // And it came from nowhere. The button that opens it is in the TOP-RIGHT
    // corner, and the panel appeared at the bottom in the middle -- "an action
    // sheet originates from the element that initiates the action, instead of from
    // the bottom edge of the display", which is the rule on a Mac and the thing
    // every popover on this machine already does. So it hangs under `#more`, its
    // right edge on the same gutter, and the whole middle of the picture is free.
    let sw = min(w - Metric.gutter * 2, Metric.sheetWidth)
    let sh = sheet.wantedHeight
    sheet.frame = NSRect(x: w - Metric.gutter - sw,
                         y: max(Metric.s3, moreButton.frame.minY - Metric.s2 - sh),
                         width: sw, height: sh)
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

    // The turn layer is the whole window too; it places its own three pieces. The
    // one thing it cannot know is how tall the button row is, so it is told --
    // rather than repeating the arithmetic and drifting the next time the row
    // moves.
    cues.frame = bounds
    cues.bottomInset = CallControls.barHeight + Metric.s3

    // `#status { top:14px; left:50%; translateX(-50%) }`. `#elapsed` used to sit
    // 18 pt below this; nothing takes its place, and the pill's own position is
    // measured from the top of the window rather than from the clock, so removing
    // it moves nothing.
    statusPill.setFrameOrigin(NSPoint(x: (w - statusPill.frame.width) / 2,
                                      y: h - statusPill.frame.height - Metric.s4))
    // THE SAME SLOT, and they cannot collide: `#status` hides itself once the
    // call connects, and the picture cannot pause before it connects. Giving the
    // warning its own row below would leave a permanent gap under a pill that is
    // almost never there.
    warnPill.setFrameOrigin(NSPoint(x: (w - warnPill.frame.width) / 2,
                                    y: h - warnPill.frame.height - Metric.s4))

    // The pills stack down the LEFT, because `#more` owns the top-right corner in
    // the web app and two things cannot have it. 36 pt clears the traffic lights,
    // which now float over the picture -- `.fullSizeContentView` put them there,
    // and at 20 pt the room pill sliced straight through all three.
    let topPad = Metric.topInset
    // Was a stack of two; the quality pill below it is gone, so there is one.
    let py = h - roomPill.frame.height - topPad
    roomPill.setFrameOrigin(NSPoint(x: Metric.gutter, y: py))
    // Bottom-left, vertically centred on the action row rather than on a number
    // that happened to line up when the row sat 14 points off the edge.
    let cpW: CGFloat = 210, cpH = Metric.pillHeight
    let cpY = Metric.barInset + (Metric.control - cpH) / 2
    camGlass.frame = NSRect(x: Metric.gutter, y: cpY, width: cpW, height: cpH)
    camGlass.radius = Metric.capsule(cpH)
    camGlass.isHidden = camPicker.isHidden
    camPicker.frame = NSRect(x: Metric.gutter + Metric.s2, y: cpY + Metric.s1,
                             width: cpW - Metric.s4, height: cpH - Metric.s2)
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
      // ── AND EVERY READOUT ABOUT THEM, BECAUSE THEY ARE GONE ────────────────
      //
      // These describe a peer, and they hold their last value forever: after a
      // departure the window said
      //
      //     the other person left        their camera is off      breaking up
      //
      // all at once. Read together that is somebody still on the call with their
      // camera off and a bad line, which is the opposite of what happened. A
      // stale fact next to a fresh one is read as current.
      //
      // Cleared HERE and not at the call site, because there is one departure
      // path today and there will be more.
      if !present {
        self.warnText = ""
        self.warnPill.text = ""
        self.qualityText = ""
      }
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
                                      y: frame.height - warnPill.frame.height - Metric.s4))
      // A warning is worthless under a hidden bar. Showing the row also makes the
      // mic and camera buttons reachable at the exact moment somebody wants them.
      showBar()
    }
    fputs("warning: \(line.isEmpty ? "(cleared)" : line)\n", stderr)
  }
  private(set) var warnText = ""

  // ── THE TURN LAYER, FORWARDED ──────────────────────────────────────────────
  //
  // Four setters, all of them called from the call loop on main, all of them
  // cheap enough to call at the loop's rate and idempotent enough that calling
  // them with the same value costs nothing. The views decide when to animate; the
  // caller only ever states what is true.

  /// What the other person is saying, as their recogniser revises it. Called from
  /// the receive thread, so it hops -- and `onMain` runs it inline when it is
  /// already there, which is what lets `--press said` be photographed in the same
  /// pass that set it.
  func setTheirWords(_ text: String, final: Bool) {
    onMain { [weak self] in self?.cues.setTheirs(text, final: final) }
  }

  /// What YOU are saying, shown only while you are the quiet side. `showing`
  /// false clears it, which is what having the floor back looks like.
  func setMyWords(_ text: String, showing: Bool) {
    onMain { [weak self] in self?.cues.setMine(text, showing: showing) }
  }

  /// A listening noise, as the word it was.
  func setListeningNoise(_ word: String) {
    onMain { [weak self] in self?.cues.setListeningNoise(word) }
  }

  /// 0 quiet, 1 listening, 2 bidding for the floor -- plus how much the ledger
  /// says this person is owed.
  func setFloor(peerVocal: Int, nudge: Double) {
    onMain { [weak self] in self?.cues.setFloor(peerVocal: peerVocal, nudge: nudge) }
  }

  var cueState: String { cues.describe }

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
      self.refreshSheet()
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
    // The button says it happened. A mute is invisible by definition -- there is no
    // change on screen to confirm it except the glyph turning red, and a colour
    // change alone is the one confirmation a colourblind user does not get.
    Motion.pop(micButton)
    onMic?(micMuted)
    setStatus(micMuted ? "you are muted" : status.contains("muted") ? "connected" : status)
  }

  @objc func toggleCam() {
    let before = camOff
    defer { Metrics.tap("cam", ok: camOff != before) }
    showBar(pin: true)
    camOff.toggle()
    camButton.off = camOff
    Motion.pop(camButton)
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
  /// Somebody typed a new name. Registering it is a signature and an HTTPS round
  /// trip, which is not this thread's work; the answer comes back through
  /// `renameAnswered`. Same shape as `onSilent`, and for the same reason -- the
  /// name on screen is not allowed to move until the server has agreed to it.
  var onRenameHandle: ((String) -> Void)?

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
    // ── WITH NO DOORBELL WIRED, STILL DO SOMETHING COMPLETE ───────────────────
    //
    // `onCall` is assigned in one place. If that assignment is ever lost, every
    // face in the panel becomes a circle that highlights, presses and does nothing
    // -- and it would audit green, because a hit test cannot tell a handler that
    // did nothing from one that is not there.
    //
    // So the fallback is the true state of the world: you can still reach this
    // person, just not by ringing them. Copying the invite and saying so is a
    // COMPLETE action, and it tells somebody the doorbell is the missing part
    // rather than that the app is broken.
    guard let ring = onCall else {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(inviteText, forType: .string)
      Metrics.tap("call", ok: false)
      fputs("call: nothing is wired to onCall -- copied the link instead\n", stderr)
      setStatus("link copied — send it to @\(h)")
      return
    }
    setStatus("calling @\(h)…")
    ring(h)
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
      self.refreshSheet()
    }
  }

  func setSilent(_ on: Bool) {
    onMain { [weak self] in
      guard let self, self.silent != on else { return }
      self.silent = on
      self.refreshSheet()
    }
  }

  @objc private func copyHandleRow(_ sender: SheetRow) { copyHandle() }

  /// Split from its `@objc` wrapper so `--press handle-copy` does not have to
  /// invent a throwaway row to pass to an argument nobody reads.
  func copyHandle() {
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
    // One curve for the whole app. This was a bare 0.22 linear fade, which next to
    // a material that eases everything it does read as the one thing on screen
    // that had not been told.
    Motion.run({ for v in row { v.animator().alphaValue = visible ? 1 : 0 } },
               duration: 0.24)
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
  /// Which payload the panel is showing. Reported in `describeTree`, because
  /// without it every `row#N` assertion is ambiguous about which list it read.
  private(set) var sheetPage: Sheet.Page = .settings

  /// Open it if it is closed. The menu item says "Show Encryption Code", and a
  /// menu item that sometimes closes the thing it offers to show is a trick.
  @objc func openMore() { showPage(.settings, opening: true) }

  /// Tap on peek, the People row, and the Call menu all land here. Opening the
  /// panel when it is already open is not a toggle: somebody who taps peek twice
  /// wants the people, not a panel that blinks.
  @objc func openPeople() { showPage(.people, opening: true) }

  /// One place changes the page, so a route that forgets to rebuild or forgets to
  /// re-lay the panel cannot exist. `opening: false` is a move BETWEEN pages of an
  /// already-open sheet -- a back row -- and must not reopen a panel somebody just
  /// closed underneath it.
  private func showPage(_ p: Sheet.Page, opening: Bool) {
    guard opening || moreOpen else { return }
    sheetPage = p
    if !moreOpen {
      moreOpen = true
      moreButton.on = true
    }
    rebuildSheet()
    // The panel is sized from its content, so a page swap has to re-lay it in the
    // same turn. Deferring to the next pass photographs the OLD page's height with
    // the new page's rows inside it.
    needsLayout = true
    layoutSubtreeIfNeeded()
    nudgeBar()
  }

  @objc func toggleMore() {
    let before = moreOpen
    defer { Metrics.tap("more", ok: moreOpen != before) }
    moreOpen.toggle()
    moreButton.on = moreOpen
    // The dots always open the settings page. A button that opens whichever page
    // you happened to leave behind is a button whose effect depends on history.
    if moreOpen { sheetPage = .settings; rebuildSheet() }
    needsLayout = true
    layoutSubtreeIfNeeded()
  }
  @objc private func closeMore() {
    guard moreOpen else { return }
    moreOpen = false
    moreButton.on = false
    sheetPage = .settings
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
    switch sheetPage {
    case .settings: buildSettingsPage()
    case .people: buildPeoplePage()
    case .rename: buildRenamePage()
    }
  }

  // ── A REBUILD IS DESTRUCTIVE, AND ONE PAGE HOLDS TYPING ────────────────────
  //
  // `setSafetyCode`, `setCameras`, `setHandle` and `setSilent` all refresh the
  // panel when it is open, and all four arrive from the call loop at moments
  // nobody chose -- the key exchange landing, a camera being plugged in. On the
  // rename page that would throw away a half-typed name mid-keystroke, which is
  // the kind of defect that only ever happens to somebody else and can never be
  // reproduced. So incidental refreshes go through here and the rename page is
  // rebuilt only when something deliberately asks for it.
  private func refreshSheet() {
    guard moreOpen, sheetPage != .rename else { return }
    rebuildSheet()
  }

  private func buildSettingsPage() {
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
    // ── THE PEOPLE ROW, AND WHY IT IS NOT ONLY A GESTURE ──────────────────────
    //
    // A tap on peek opens the same panel, and it is the fastest route. It is also
    // unavailable on an audio-only call -- peek refuses to open an empty tile when
    // no camera frame has ever arrived -- and undiscoverable to anyone who has not
    // been told. So the panel has three doors: this row, the gesture, and the Call
    // menu. A feature reachable only by a gesture nobody mentions is a feature
    // behind a flag nobody runs.
    let peopleEntry = SheetRow("People", glyph: Glyph.person)
    peopleEntry.target = self; peopleEntry.action = #selector(peopleRow(_:))
    items.append(peopleEntry)
    // ── CHANGING YOUR NAME, WHETHER OR NOT YOU HAVE ONE ──────────────────────
    //
    // Present even when `handle` is empty, and that is the case it matters most in:
    // an unclaimed handle means every name this Mac suggested was already taken,
    // and the person it happened to is exactly the one who needs to pick another.
    // Hiding the row until the name works would hide it from everybody it is for.
    let rename = SheetRow(handle.isEmpty ? "Choose your name" : "Change your name",
                          glyph: Glyph.pencil)
    rename.target = self; rename.action = #selector(renameRow(_:))
    items.append(rename)
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

  // ── THE PEOPLE PAGE ────────────────────────────────────────────────────────
  //
  // Circles with names on them, and tapping one calls that person. Capped at six,
  // and the cap is stated rather than left as a surprise: `Sheet` has no scroll
  // view, and adding one is a new container with its own hit-testing -- exactly
  // what putting this in the sheet avoids. At five contacts the panel is already
  // most of a 720 pt window.
  private static let peopleShown = 6
  private(set) var people: [String] = []

  private func buildPeoplePage() {
    people = Array(Identity.contactHandles().prefix(CallControls.peopleShown))
    var items: [NSView] = []
    if people.isEmpty {
      // NOT an empty panel, and not a greyed row. The truthful thing to say is how
      // somebody gets one, and this is the whole of it.
      items.append(SheetHint("Call someone once and they'll show up here."))
    }
    for h in people {
      let r = ContactRow(handle: h)
      r.target = self; r.action = #selector(callContactRow(_:))
      items.append(r)
    }
    // ── YOUR OWN CIRCLE, AND THE ONE STATE THAT HAS NO ROW ───────────────────
    //
    // A copy button over an empty value is worse than no copy button: it copies
    // nothing, reports success, and teaches the person the feature is broken. So an
    // unclaimed handle gets a sentence instead of a control.
    if handle.isEmpty {
      items.append(SheetHint("Your name on Kin isn't set up yet."))
    } else {
      let mine = ContactRow(handle: handle)
      mine.value = "copy"
      mine.valueIsWord = true
      mine.ruled = !people.isEmpty
      mine.target = self; mine.action = #selector(copyHandleRow(_:))
      items.append(mine)
      items.append(SheetHint("Give this to someone and they can call you."))
    }
    // Only where it can work. Mid-call there is no name field on screen to hand
    // over to, and a row that opens nothing is the defect this file keeps finding.
    if !waiting.isHidden {
      let new = SheetRow("Call someone new")
      items.append(new)
      new.target = self; new.action = #selector(callSomeoneNewRow(_:))
    }
    let back = SheetRow("Back")
    back.target = self; back.action = #selector(backToSettingsRow(_:))
    items.append(back)
    // ── ONE LEFT EDGE FOR THE WHOLE PAGE ──────────────────────────────────────
    //
    // A page of faces has a 34 pt mark column and the sheet's ordinary rows have an
    // 18 pt one, so the two kinds of row start their words 14 points apart.
    // Photographed, the list had a ragged left edge and read as two lists that
    // happened to be adjacent. These two carry no glyph at all rather than a small
    // one floating in a column built for a face -- the words are what they are, and
    // the words line up with the names above them.
    for r in items.compactMap({ $0 as? SheetRow }) where !(r is ContactRow) {
      r.textInset = Metric.rowAvatarInset
    }
    sheet.setItems(items)
  }

  // ── THE RENAME PAGE ────────────────────────────────────────────────────────
  //
  // The field is pre-filled with the name this Mac answers to, claimed or not,
  // because that is the string a person came here to edit. `Identity.handle` always
  // has one -- a name derived from the Mac exists whether or not the server has
  // ever heard of it -- so this page is never an empty box with no context.
  private func buildRenamePage() {
    var items: [NSView] = []
    items.append(SheetHint("This is the name people type to call you."))
    let f = SheetField(placeholder: "a name", text: Identity.handle)
    // Enter commits. A field you have to go looking for a button after is a field
    // people type into and then wonder why nothing happened.
    f.onCommit = { [weak self] in self?.commitRename() }
    items.append(f)
    let save = SheetRow("Save this name")
    save.target = self; save.action = #selector(saveNameRow(_:))
    items.append(save)
    let back = SheetRow("Not now")
    back.target = self; back.action = #selector(backToSettingsRow(_:))
    items.append(back)
    items.append(SheetHint("Letters and numbers, starting with a letter."))
    sheet.setItems(items)
    // The caret goes in without anybody having to aim at a 36 pt well. Deferred
    // one turn: the field is not in a window until this layout pass completes, and
    // `makeFirstResponder` on a view with no window silently does nothing.
    DispatchQueue.main.async { [weak self] in
      guard let self, let field = self.sheet.field else { return }
      self.window?.makeFirstResponder(field.field)
      // ── AND THE OLD NAME IS SELECTED, NOT SITTING THERE WAITING ──────────────
      //
      // `makeFirstResponder` alone leaves the caret at the end, so the first thing
      // typed is APPENDED: somebody who came here to become `meera` got
      // `deveshmeera`, and the harness proved it before a person could. Every
      // rename field on this platform behaves the other way -- the value is
      // selected, and typing replaces it -- because the reason you opened it is
      // that the current value is not the one you want.
      field.field.currentEditor()?.selectAll(nil)
    }
  }

  @objc private func peopleRow(_ sender: SheetRow) {
    Metrics.tap("people")
    openPeople()
  }

  @objc private func backToSettingsRow(_ sender: SheetRow) {
    Metrics.tap("people_back")
    showPage(.settings, opening: false)
  }

  @objc private func renameRow(_ sender: SheetRow) {
    Metrics.tap("rename_open")
    showPage(.rename, opening: true)
  }

  @objc private func saveNameRow(_ sender: SheetRow) { commitRename() }

  @objc private func callSomeoneNewRow(_ sender: SheetRow) { callSomeoneNew() }

  func callSomeoneNew() {
    closeMore()
    // Reported, because "the row fired" and "there is a caret in the field" are two
    // different claims and only the second one is the feature.
    Metrics.tap("call_new", ok: waiting.focusDial())
  }

  /// A face was tapped. Everything after this is `dial`'s -- the same path the
  /// name field takes, so a contact call and a typed call cannot drift into
  /// meaning different things.
  @objc private func callContactRow(_ sender: SheetRow) {
    guard let row = sender as? ContactRow else { return }
    Metrics.tap("call_contact")
    closeMore()
    dial(row.handleName)
  }

  // ── CHANGING YOUR NAME ─────────────────────────────────────────────────────
  //
  // The server is the authority and it answers on its own schedule, so this says
  // what was ASKED FOR and then what came back. The name in the sheet does not move
  // until `setHandle` arrives -- the same rule the Silent switch follows, and for
  // the same reason: telling somebody they are `@meera` when the server still has
  // that name bound to a stranger's key is the one error here that matters.
  private func commitRename() {
    guard let want = sheet.field?.text else { return }
    guard let name = Identity.sanitize(want.hasPrefix("@") ? String(want.dropFirst()) : want) else {
      Metrics.tap("rename", ok: false)
      setStatus("that is not a name")
      return
    }
    guard let ask = onRenameHandle else {
      // A callback declared and invoked but assigned NOWHERE reads as finished and
      // does nothing -- three instances in this file's history, one of them the
      // whole of "the selfie feature is not working". If this ever fires it is a
      // wiring bug, so it is loud on stderr and honest on screen rather than a row
      // that silently swallows a press.
      Metrics.tap("rename", ok: false)
      fputs("rename: nothing is wired to onRenameHandle -- the row cannot work\n", stderr)
      setStatus("cannot change your name right now")
      return
    }
    Metrics.tap("rename")
    setStatus("asking for @\(name)…")
    ask(name)
  }

  /// The answer, in plain words. Three refusals and three different things to do
  /// about them, which is why `Identity.renamed` reports which one it was instead
  /// of a boolean that can only ever produce the vaguest of the three.
  func renameAnswered(_ outcome: Identity.Renamed, name: String) {
    onMain { [weak self] in
      guard let self else { return }
      switch outcome {
      case .ok:
        self.setStatus("you are @\(name)")
        self.closeMore()
      case .taken:
        self.setStatus("@\(name) belongs to someone else")
      case .notAName:
        self.setStatus("that is not a name")
      case .noAnswer:
        self.setStatus("could not reach the internet — try again")
      }
    }
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

  // ── HOLDING THE RED BUTTON ENDS THE CALL ───────────────────────────────────
  //
  // Asked for as "a long press on the red thing should disconnect instead of you
  // having to click twice". It is built as an ADDITION rather than a replacement,
  // and that is the one judgement call in this gesture.
  //
  // Consider the person who does not know it: they tap the red button, get a pill,
  // and tap again. Today that hangs up. If the hold REPLACED the confirm, that
  // second tap would do nothing, and the app would look broken at the one moment it
  // must not. Somebody who learns the hold never sees the fallback, so it costs
  // them nothing; somebody who does not is never stranded. It also keeps
  // `--press leave,leave` and Command-Delete working, and a rig that silently
  // stopped hanging up would take a long time to notice.
  //
  /// 600 ms. Far enough from peek's 220 ms that muscle memory trained on one
  /// cannot end a call with the other -- 2.7x -- and above the 500 ms long-press
  /// convention people already know from the phone in their pocket, so it reads as
  /// a gesture rather than as a slow click. Well under the 3 s disarm below, so the
  /// pill can never expire under a finger mid-hold.
  /// ── AND ITS RIG OVERRIDE, WHICH IS NOT CONVENIENCE ────────────────────────
  ///
  /// A 600 ms fill cannot be photographed. `screencapture` takes about a second to
  /// arm, and `--press` steps are 700 ms apart, so every instrument this project
  /// has arrives after the hold has either completed or been let go -- and the one
  /// thing worth looking at, a pill half full under a finger, is invisible to all
  /// of them. Stretching the cadence is the same move `TK_REDUCE_TRANSPARENCY` and
  /// `TK_KIN_DIR` make, for the same reason: the state exists, and without an
  /// override no honest capture can reach it.
  ///
  ///     TK_LEAVE_HOLD_MS=30000 tk --window --press "@leave:25,?"
  ///
  /// Nothing in the app sets it, and the shipped number is the one above.
  static let leaveHoldSeconds: TimeInterval =
    (ProcessInfo.processInfo.environment["TK_LEAVE_HOLD_MS"].flatMap { Double($0) }
       .map { $0 / 1000 }) ?? 0.6
  /// Three seconds, because an armed hang-up left on screen is a trap for the next
  /// click that lands anywhere near it -- but never less than the hold plus room to
  /// spare, or the disarm fires under a finger that is still pressing.
  static var leaveForgetSeconds: TimeInterval { max(3.0, leaveHoldSeconds * 5) }
  /// ~30 Hz, and in `.common` modes because it has to keep firing during event
  /// tracking -- which is the mode a `mouseDown` puts the runloop into. A timer
  /// rather than a nested `nextEvent` loop because a hold must not own the main
  /// thread: six seconds of holding peek once enqueued 169 frames into a visible
  /// layer and drew a black rectangle, because Core Animation never got a turn.
  private static let leaveFillTick: TimeInterval = 1.0 / 30
  private var fillTimer: Timer?
  private var holdStart: Date?
  /// Was the pill already armed when this press went down? The answer decides
  /// whether the release hangs up, and it has to be sampled at `mouseDown` --
  /// `mouseDown` itself arms the pill, so reading `leaveArmed` at release time
  /// would say "armed" for the very first press and end a call on one click.
  private var leaveArmedAtDown = false

  private func leaveHold(_ down: Bool) {
    guard down else { stopLeaveFill(); return }
    leaveArmedAtDown = leaveArmed
    if !leaveArmed { arm(label: "hold to leave") }
    // ── A HOLD MAY NOT FIRE ON A WINDOW NOBODY WAS LOOKING AT ─────────────────
    //
    // `acceptsFirstMouse` is true on every button here so a click that arrives
    // while the app is behind something still counts, and that is right: "mute me
    // now" is pressed precisely when this window is not the one you were typing in.
    // But it turns a click-and-hold that only meant to bring the app forward into
    // an ended call. The press still activates and still arms -- the pill draws, so
    // nothing looks dead -- and the hold is available from the second press on.
    guard leaveButton.keyAtDown else { return }
    startLeaveFill()
  }

  /// A release inside the tap window. The FIRST press only arms, because arming is
  /// what `mouseDown` already did; the second one is the confirmation.
  private func leaveTap() {
    guard leaveArmedAtDown else { return }
    Metrics.tap("leave_confirm")
    leaveNow()
  }

  private func startLeaveFill() {
    fillTimer?.invalidate()
    holdStart = Date()
    let t = Timer(timeInterval: CallControls.leaveFillTick, repeats: true) { [weak self] timer in
      guard let self, let start = self.holdStart else { timer.invalidate(); return }
      let k = Date().timeIntervalSince(start) / CallControls.leaveHoldSeconds
      self.leaveButton.holdProgress = CGFloat(min(1, k))
      guard k >= 1 else { return }
      timer.invalidate()
      Metrics.tap("leave_hold")
      self.leaveNow()
    }
    fillTimer = t
    RunLoop.main.add(t, forMode: .common)
  }

  /// Released early, or Escape, or the disarm. The fill resets and the pill STAYS
  /// armed for the rest of its three seconds, so somebody who under-held sees the
  /// target still sitting there and simply presses again.
  private func stopLeaveFill() {
    fillTimer?.invalidate()
    fillTimer = nil
    holdStart = nil
    leaveButton.holdProgress = 0
  }

  /// End the call on the first invocation, with no pill in the way. For anything
  /// that is already an explicit, deliberate, named act.
  func leaveNow() {
    cancelLeaveConfirm()
    onLeave?()
  }

  @objc func leave() {
    if leaveArmed {
      Metrics.tap("leave_confirm")
      leaveNow()
      return
    }
    // "tap", not "hold": this path is the menu item, the keyboard and the rig,
    // none of which can hold anything. A pill teaching a gesture the thing that
    // armed it cannot perform is a control lying about its own way out.
    arm(label: "tap to leave")
  }

  private func arm(label: String) {
    // Counted HERE and not in `leave()`, because a press on the button arms
    // through `mouseDown` and never goes near `leave()` at all -- the one route a
    // person actually takes was the one route the counter could not see.
    Metrics.tap("leave_arm")
    leaveArmed = true
    leaveButton.confirming = true
    leaveButton.confirmLabel = label
    showBar(pin: true)
    // ── THE ROW FLOWS INTO THE DECISION ───────────────────────────────────────
    //
    // Four circles contract to zero width while a fifth stretches to a 150-point
    // pill. Done as plain frame changes that is four things vanishing next to one
    // thing growing, and it reads as a glitch.
    //
    // Raising the container's spacing past the gap between the circles is what
    // makes them MERGE -- measured on this machine: at a gap of 18, spacing 40
    // grows liquid bridges between them and spacing 80 makes them one shape. So
    // the spacing is animated up as they close, and the four buttons pour into the
    // one that is left instead of blinking out of existence.
    //
    // This is the whole reason the row is inside a glass container. Nothing else
    // in the app needs one, and no arrangement of separate views can do it.
    setRowMerge(CallControls.mergeSpacing)
    animateRow()
    // Three seconds and it forgets, because an armed hang-up left on screen is a
    // trap for the next click that lands anywhere near it.
    leaveTimer?.invalidate()
    // ── AND IT MUST OUTLAST THE GESTURE IT IS WAITING FOR ─────────────────────
    //
    // This was a bare 3.0, which is right by a comfortable margin at a 600 ms hold
    // and is a gesture that can NEVER COMPLETE the moment the hold goes past it:
    // the disarm cancels the pill, `cancelLeaveConfirm` stops the fill, and the
    // finger is still down on a button that has quietly given up. Found by
    // stretching the hold to photograph it -- the rig override made the impossible
    // condition real, and the pill vanished mid-hold in the first shot taken of it.
    //
    // Derived rather than documented, so the two numbers cannot be edited apart.
    leaveTimer = Timer.scheduledTimer(withTimeInterval: CallControls.leaveForgetSeconds,
                                      repeats: false) { [weak self] _ in
      self?.cancelLeaveConfirm()
    }
  }

  /// Below the 18-point gap between circles, so they stay five distinct shapes
  /// while nothing is happening.
  static let restSpacing: CGFloat = 12
  /// Well above it, so they merge. See GlassGroup for the measurements.
  static let mergeSpacing: CGFloat = 64

  /// Drive the container's proximity, which is what decides whether the circles
  /// notice each other. Stepped rather than jumped: a spacing that snaps produces
  /// a merge that snaps, and the whole point is that it flows.
  private func setRowMerge(_ target: CGFloat) {
    mergeTimer?.invalidate()
    guard !Motion.reduceMotion else { barGroup.spacing = target; return }
    let steps = 12
    let from = barGroup.spacing
    var i = 0
    mergeTimer = Timer.scheduledTimer(withTimeInterval: Motion.duration / Double(steps),
                                      repeats: true) { [weak self] t in
      guard let self else { t.invalidate(); return }
      i += 1
      let k = min(1.0, Double(i) / Double(steps))
      // Ease out, so most of the merging happens early and it settles rather than
      // arriving. Matches the curve the frames are travelling on.
      self.barGroup.spacing = from + (target - from) * CGFloat(1 - pow(1 - k, 3))
      if i >= steps { t.invalidate() }
    }
    RunLoop.main.add(mergeTimer!, forMode: .common)
  }
  private var mergeTimer: Timer?

  /// Re-lay the row inside an animation, so the circles travel to their new
  /// positions instead of being redrawn there.
  private func animateRow() {
    Motion.run {
      needsLayout = true
      layoutSubtreeIfNeeded()
    }
  }

  func cancelLeaveConfirm() {
    // Unconditional, and BEFORE the guard. Escape clears the pill by calling this,
    // and a fill left running behind a cleared pill would travel on toward a
    // hang-up with nothing on screen saying so.
    stopLeaveFill()
    guard leaveArmed else { return }
    leaveArmed = false
    leaveArmedAtDown = false
    leaveTimer?.invalidate()
    leaveButton.confirming = false
    // Back to five separate targets. The merge is for the moment of change; at rest
    // these are five different irreversible-to-varying-degrees actions and they
    // must not look like one control.
    setRowMerge(CallControls.restSpacing)
    animateRow()
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
      // THE WARNING IS A SENTENCE THE USER READS, so an instrument that cannot see
      // it cannot check the one thing that matters about it. "their camera is off"
      // was invisible to every rig here until this line existed.
      + "  warn=\(warnText.isEmpty ? "-" : warnText)"
      + "  picker=\(camPicker.isHidden ? "hidden" : "\(camNames.count) items")"
      + "  mic=\(micMuted ? "muted" : "on") cam=\(camOff ? "off" : "on")"
      + "  row=[\(visibleRowNames.joined(separator: " "))]"
      + "  more=\(moreOpen ? "open" : "closed") peek=\(peeking)\(peekButton.holding ? "/held" : "")"
      // A CUMULATIVE count, not a flag. A boolean sampled after the fact is a birth
      // certificate rather than a health record, and only a count can show that one
      // press did not classify as both a tap and a hold.
      + " peektap=\(peekButton.taps)"
      // The existing field EXTENDED rather than a second one beside it, because two
      // fields describing one control are two fields that can disagree. A
      // percentage is the only way a fill can be asserted without a screenshot.
      + "  leave=\(leaveState) bar=\(barShown ? "shown" : "hidden")"
      + "  handle=\(handle.isEmpty ? "-" : handle) people=\(people.count)"
      + "  clip=\(NSPasteboard.general.string(forType: .string) ?? "-")"
      + "  \(cues.describe)"
      + (moreOpen ? "\n  sheet=\(sheetPage.rawValue)["
                  + sheet.rows.map { $0.spoken }.joined(separator: " | ") + "]"
                  + (sheet.field.map { " field=\"\($0.text)\"" } ?? "") : "")
  }

  private var leaveState: String {
    guard leaveArmed else { return "idle" }
    guard leaveButton.holdProgress > 0 else { return "ARMED" }
    return "HOLDING:\(Int((leaveButton.holdProgress * 100).rounded()))"
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
    // ── THE THREE GESTURES, WITHOUT A POINTER ─────────────────────────────────
    //
    // These exist beside the `@` clicks rather than instead of them. A `@` click is
    // the only thing that can catch a control a finger cannot reach; a token is the
    // only thing that can drive a control which is not on screen at all -- the
    // people panel on an audio-only call, or the rename page's Save row before
    // anybody has opened the panel.
    case "peek-tap": peekButton.simulateTap()
    case "leave-hold":
      leaveButton.simulateHold(true)
      leaveHold(true)
    case "leave-hold-cancel":
      leaveHold(false)
      leaveButton.simulateHold(false)
    case "people": openPeople()
    case "people-back": showPage(.settings, opening: false)
    case "rename": showPage(.rename, opening: true)
    case "rename-save": commitRename()
    case "handle-copy": copyHandle()
    case "call-new": callSomeoneNew()
    // Mirrors `cam#N`, INCLUDING its loud refusal. A token that quietly does
    // nothing for an out-of-range index is a test that passes by not running.
    //
    // Reads the SOURCE rather than `people`, which is only filled once the panel
    // has been built: a token that silently needed a previous token would be a
    // dependency nobody wrote down.
    case let c where c.hasPrefix("contact#"):
      let list = Array(Identity.contactHandles().prefix(CallControls.peopleShown))
      guard let n = Int(c.dropFirst(8)), n >= 1, n <= list.count else {
        fputs("press: no contact \(what) -- this Mac knows \(list.count)"
            + " (use --contacts-fake to give it some)\n", stderr)
        return
      }
      closeMore()
      dial(list[n - 1])
    case "quality": markConnected(); setQuality(m2eMs: 11, concealPct: 0, lossPct: 0)
    // ── THE TURN LAYER, EXERCISED ─────────────────────────────────────────────
    //
    // Every one of these draws something over a face and none of them can be
    // reached by clicking, so a harness that only presses buttons would never see
    // them at all. `--press cue-claim` then `--press tree` is how the shape and
    // the words get checked without two people and two microphones.
    case "cue-quiet": setFloor(peerVocal: 0, nudge: 0)
    case "cue-listen": setFloor(peerVocal: 1, nudge: 0)
    case "cue-claim": setFloor(peerVocal: 2, nudge: 0)
    case "cue-claim-owed": setFloor(peerVocal: 2, nudge: 1)
    case "bloom": setListeningNoise("mm-hmm")
    case "said": setTheirWords("So the thing about a call is that you never really "
                             + "know whose turn it is, and that is the whole problem.",
                               final: false)
    case "said-final": setTheirWords("That is the whole problem.", final: true)
    case "said-clear": setTheirWords("", final: true)
    case "mine": setMyWords("Right, but what if we just decided", showing: true)
    case "mine-clear": setMyWords("", showing: false)
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
    // ── AN OPEN SHEET REALLY DOES TAKE THE BAR AWAY ───────────────────────────
    //
    // `sheetScrim` fills the window and sits ABOVE the row, so while the panel is
    // open a click at mic's centre closes the sheet instead of muting. That is
    // correct -- a click anywhere outside the panel is how it closes, and that exit
    // needs no aiming -- but listing the bar buttons anyway made the audit print
    // five FAILs for a screen behaving exactly as designed.
    //
    // The defect was in the INSTRUMENT, not the product: `clickTargets` is
    // documented as what is on screen right now, and a button under a scrim is not
    // something a person can press. An audit that cries wolf about a working screen
    // is an audit nobody reads the day it is right.
    if !moreOpen {
      add("mic", micButton); add("cam", camButton); add("peek", peekButton)
      add("flip", flipButton); add("leave", leaveButton)
      add("more", moreButton)
    } else {
      for (i, r) in sheet.rows.enumerated() where r.isEnabled { add("row#\(i)", r) }
      // The one thing in a sheet that is typed into rather than pressed. Named, so
      // `@name` focuses it and `+meera` has somewhere to land.
      if let f = sheet.field { add("name", f) }
    }
    // Under the scrim too, for the same reason and with the same consequence: while
    // the panel is open, a click on `copy` closes the panel rather than copying.
    if !waiting.isHidden, !moreOpen { for (n, v) in waiting.clickTargets { add(n, v) } }
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
