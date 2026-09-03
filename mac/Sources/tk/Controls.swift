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

  /// A speaker cone and two waves. Same 24x24 grid, same 1.8 pt stroke as every
  /// other glyph here, so the device rows read as one family.
  /// <path d="M4 9.5h3.5L12 5.5v13L7.5 14.5H4z"/><path d="M16 9.5a4.5 4.5 0 0 1 0 5"/>
  /// <path d="M18.6 7a8 8 0 0 1 0 10"/>
  static let speaker = Shape(build: { box in path(box) { p, k in
    m(p, k, 4, 9.5); l(p, k, 7.5, 9.5); l(p, k, 12, 5.5); l(p, k, 12, 18.5)
    l(p, k, 7.5, 14.5); l(p, k, 4, 14.5)
    p.close()
    m(p, k, 16, 9.5)
    p.curve(to: NSPoint(x: 16 * k, y: 14.5 * k),
            controlPoint1: NSPoint(x: 18.2 * k, y: 10.6 * k),
            controlPoint2: NSPoint(x: 18.2 * k, y: 13.4 * k))
    m(p, k, 18.6, 7)
    p.curve(to: NSPoint(x: 18.6 * k, y: 17 * k),
            controlPoint1: NSPoint(x: 22.2 * k, y: 9.2 * k),
            controlPoint2: NSPoint(x: 22.2 * k, y: 14.8 * k))
  } }, filled: false)

  /// <rect x=2.5 y=6 width=13 height=12 rx=3/><path d="M15.5 10.5l6-3.5v10l-6-3.5z"/>
  static let cam = Shape(build: { box in path(box) { p, k in
    rr(p, k, 2.5, 6, 13, 12, 3)
    m(p, k, 15.5, 10.5); l(p, k, 21.5, 7); l(p, k, 21.5, 17); l(p, k, 15.5, 13.5)
    p.close()
  } }, filled: false)

  static let record = Shape(build: { box in path(box) { p, k in
    p.appendOval(in: NSRect(x: 6 * k, y: 6 * k, width: 12 * k, height: 12 * k))
  } }, filled: true)

  static let folder = Shape(build: { box in path(box) { p, k in
    rr(p, k, 3, 5, 18, 14, 2)
    m(p, k, 3, 14); l(p, k, 9, 14); l(p, k, 11, 16.5); l(p, k, 17, 16.5); l(p, k, 19, 14)
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

  // ── ONE HANDSET AT TWO ANGLES ──────────────────────────────────────────────
  //
  // A call glyph and a hang-up glyph are the same handset rotated -- that is how
  // every icon set on every platform draws the pair, and it is why you can read
  // one as the opposite of the other at 16 pt. Transcribing a second outline by
  // hand would give two shapes that drift apart the first time either is nudged,
  // and the two of them would stop reading as a pair without anyone being able to
  // say why.
  //
  // The rotation is NEGATIVE because `path()` has already flipped the y axis: the
  // 135 degrees clockwise that separates them in the y-down SVG frame is 135
  // counter-clockwise here. Getting this backwards points the earpiece at the
  // floor, which is exactly the hang-up glyph, at which point the two controls in
  // this app that mean opposite things look identical.
  static let phone = Shape(build: { box in
    let p = leave.build(box)
    let t = NSAffineTransform()
    t.translateX(by: box / 2, yBy: box / 2)
    t.rotate(byDegrees: -135)
    t.translateX(by: -box / 2, yBy: -box / 2)
    p.transform(using: t as AffineTransform)
    return p
  }, filled: true)
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
  // Clear and interactive, like every surface in the app now. A bar circle carries
  // a glyph rather than a sentence and floats over a live face, which is precisely
  // the case the HIG names: "components that float above media backgrounds -- such
  // as photos and videos -- to create a more immersive content experience." The
  // dim that keeps it legible is inside this circle, and stops at its edge.
  private let glass: Glass
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
  var off = false {
    didSet {
      needsDisplay = true; ink.needsDisplay = true
      // ── A SCREEN READER CANNOT SEE A RED GLYPH ──────────────────────────────
      //
      // `setAccessibilityLabel(help)` in `init` gives these buttons a name --
      // "microphone", "camera", "leave call" -- and that was the whole of it. The
      // state is drawn: the glyph turns red and gains a slash. So VoiceOver read
      // "microphone" whether the microphone was live or muted, on the one control
      // where getting it wrong means talking to somebody who cannot hear you.
      //
      // Label is the NAME and value is the STATE, which is the platform's own
      // division and what every system control does. A word rather than a checkbox
      // 0/1, because "microphone, checked" does not say which way round that is.
      setAccessibilityValue(off ? "off" : "on")
    }
  }
  /// Active: `box-shadow: inset 0 0 0 1.5px rgba(255,255,255,.35)`.
  var on = false { didSet { needsDisplay = true; ink.needsDisplay = true } }
  // ── HOW MUCH OF THIS CONTROL IS ACTUALLY REACHING THE OTHER PERSON ─────────
  //
  // 0...1, multiplied into the glyph's own alpha. One is the ordinary button and
  // is what every control in the app draws at; anything less says this control's
  // function is being held back right now by something that is not the person's
  // choice. Only the microphone sets it, and only the turn-taking layer moves it
  // -- see `CallControls.MicFloor`.
  //
  // ── WHY OPACITY, WHEN THE APP HAS A GLOW AND A TINT AND A RING ────────────
  //
  // Because the person this is for said "there should not be any effect", and a
  // glow, a tint, a pulsing ring or a badge are all effects: a thing that happens
  // TO a control rather than a thing the control IS. Contrast is the one channel
  // that is not an effect -- it is how every operating system has said "this
  // control is not doing its thing right now" for forty years, it has no motion
  // of its own, and it moves only because the underlying state moves.
  //
  // It survives the objection that a dim glyph is hard to judge in the absolute,
  // because it is never seen in the absolute: this button sits in a row of four
  // others drawn at 1.0, twelve points away, and the row is the reference. That
  // is also why the held value is 0.34 rather than something tasteful -- measured
  // on a photograph of the real window, the mic glyph's ink falls to 0.42x its
  // neighbour's, which is a step nobody has to look for.
  var reach: CGFloat = 1 {
    didSet {
      // Against what was last DRAWN, not against the previous assignment. An
      // ease arrives asymptotically, so a run of sub-threshold steps compared
      // pairwise each look like nothing while together they are a visible
      // change -- and the glyph would settle several hundredths away from the
      // number this view believes it is showing, with nothing to say so.
      guard abs(reach - drawnReach) > 0.002 else { return }
      ink.needsDisplay = true
    }
  }
  private var drawnReach: CGFloat = 1
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

  // ── HOW MUCH DIM, AND WHY IT IS STILL A PARAMETER ──────────────────────────
  //
  // This used to choose a MATERIAL -- `.clear` for the bar, `.regular` for the one
  // button that needed more help -- and there is only one material now, so the
  // parameter is the dim instead.
  //
  // It defaults to the HIG's number rather than to 0, and that changed when the
  // window's two scrims were deleted. While they existed, a bar circle sat in
  // 0.35 of gradient already and adding its own would have compounded to 0.58; the
  // circles were the one place in the app the borrowed contrast was correct. With
  // nothing painted on the picture any more there is nothing to borrow, so every
  // circle carries its own dim inside its own 58 pt round rectangle -- which is
  // the same total darkness a person sees at the button, and none of it anywhere
  // else. That is the entire trade this change makes.
  //
  // Which means no caller passes anything but the default today. The parameter
  // stays because the question is real -- put a control back inside something dark
  // and its own dim becomes double-counting -- but if it is still the only value a
  // year from now, delete it, the way `Glass.Variant` was deleted for being a
  // choice that was never once made differently.
  init(_ shape: Glyph.Shape, size: CGFloat = 58, help: String,
       dim: CGFloat = Palette.dimAlpha) {
    self.shape = shape
    self.box = size
    self.glass = Glass("icon:\(help)", radius: 0, dim: dim, interactive: true)
    super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
    isBordered = false
    title = ""
    toolTip = help
    setAccessibilityLabel(help)
    setAccessibilityValue("on")
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

  // ── A CIRCLE NOBODY CAN SEE IS NOT A TARGET ────────────────────────────────
  //
  // `alphaValue` is a DRAWING property and AppKit's hit testing has no opinion
  // about it: a button faded to nothing is still exactly where it was and still
  // fires. For as long as the auto-hide was only an opacity change, the row was
  // invisible and fully armed -- five circles a person cannot see, with the
  // hang-up in the middle of them, sitting over the other person's face.
  //
  // So invisibility is enforced once, here, for every circle in the app rather
  // than for the bar alone: the same rule the leave confirmation already relies
  // on when it collapses four of them to zero. A refused click is not a lost
  // click -- it falls through to `CallControls`, which brings the row back, which
  // is what somebody groping for the mute button actually wants to happen.
  override func hitTest(_ point: NSPoint) -> NSView? {
    alphaValue > 0.01 ? super.hitTest(point) : nil
  }

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
    // `reach` rides on the glyph's alpha and on nothing else: not the circle, not
    // the hairline, not the material. The button is still exactly where it was and
    // still the same size, because the thing being said is about the microphone
    // and not about whether you may press it -- and a control that shrinks or
    // moves under a finger already travelling toward it is a worse bug than
    // anything this could report.
    let colourBase: NSColor = destructive ? .white : (off ? Palette.bad : Palette.fg)
    drawnReach = reach
    let colour = reach >= 0.999 ? colourBase
      : colourBase.withAlphaComponent(colourBase.alphaComponent * max(0, min(1, reach)))
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
  // It carries words, over a face, with nothing else dimming it -- the top scrim
  // is 0.28 and stops well short of a pill in the middle of the window. So: clear,
  // over the full dim, which is the same job `.regular` used to be asked for and
  // is the half of it that was actually about legibility.
  private let glass = Glass("pill", radius: 0, textual: true)
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

  // ── THE LABEL INSIDE IT MUST NOT EAT THE CLICK ─────────────────────────────
  //
  // The warning pill became a control -- clicking "Kin can't hear you" opens the
  // right System Settings pane -- and the click did not arrive. The audit said
  // why: `hit=NSTextField`. The gesture recogniser is on the PILL; the hit was
  // its label, an NSTextField, which handles mouseDown itself for text selection
  // and swallowed it. Third instance of `decoration-inside-a-control-eats-clicks`
  // in this file, after the blur inside a button and the glyph overlay.
  //
  // No pill in this app contains text anybody selects -- they are sentences drawn
  // over a video -- so the whole pill is one target and the label is never
  // consulted.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0.01 else { return nil }
    return super.hitTest(point) == nil ? nil : self
  }

  // ── AND THE PRESS IS TRACKED BY HAND ───────────────────────────────────────
  //
  // `NSClickGestureRecognizer` was the first attempt and it never fired: the
  // audit showed the click reaching the pill (`hit=Pill`) and the handler not
  // running. Every other control in this file tracks its own mouseDown/mouseUp
  // for the same reason -- a recogniser depends on AppKit's own routing, and this
  // window is parked, not key, and `ignoresMouseEvents` under the harness. A
  // control that only works when the app is frontmost is a control the harness
  // can never prove, which is how a dead button gets shipped.
  var onClick: (() -> Void)?
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {
    guard onClick != nil else { super.mouseDown(with: event); return }
  }
  override func mouseUp(with event: NSEvent) {
    guard let go = onClick else { super.mouseUp(with: event); return }
    let p = convert(event.locationInWindow, from: nil)
    if bounds.contains(p) { go() }
  }

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
  private(set) var hovering = false
  var checked = false { didSet { needsDisplay = true } }
  /// Held down. Drawn like hover, a shade stronger -- feedback under the finger.
  private var pressed = false { didSet { needsDisplay = true } }
  /// An action, not a toggle -- ruled off above so it never reads as a switch.
  var ruled = false { didSet { needsDisplay = true } }
  /// A fact about this call: nothing to press.
  var inert = false
  /// Held on by something other than the pointer -- the row you just clicked,
  /// while the ring it started is still travelling. Drawn exactly like `pressed`,
  /// because it IS still pressed as far as the person is concerned: the finger
  /// came off but the thing they asked for has not happened yet.
  var forcedActive = false { didSet { needsDisplay = true } }
  /// The keyboard is on this row. Stronger than hover and weaker than a press, so
  /// a pointer resting on one row and the arrow keys sitting on another read as
  /// two different things rather than as two rows both half-lit.
  var keySelected = false { didSet { needsDisplay = true } }
  /// `.sheet .row .code` -- a monospaced value pinned right, for the encryption code.
  var value: String = "" { didSet { needsDisplay = true; needsLayout = true; announce() } }
  /// This value is a WORD, not a code. The code treatment is monospace at 0.09em of
  /// letter-spacing, which exists so two people can read a safety code aloud
  /// character by character -- and applied to "copy" it drew `c o p y` in a
  /// typewriter face, which reads as a serial number rather than as something to
  /// press. Same slot, different job, so it has to be told which.
  var valueIsWord = false { didSet { needsDisplay = true } }
  // ── A ROW HAS TO SAY WHAT PRESSING IT WILL DO ──────────────────────────────
  //
  // Everything on the right-hand side of a row was drawn identically: "yesterday",
  // "copy", "only when open", "0.118.0". A timestamp, a button, a switch and a
  // fact, in the same 12 pt grey, in the same place. There was no way to look at
  // the settings card and know which of those four you were about to press, and
  // the one that mattered most -- whether anybody can reach this Mac -- was a
  // sentence fragment that toggled.
  //
  // Three accessories, and they are the three every settings list on this machine
  // has had for fifteen years. Nothing here is invented: a switch is a switch, a
  // chevron means "this opens something", a chip means "this does something now".
  /// A real switch, drawn where the value would be. `nil` for a row that is not a
  /// setting.
  var switchState: Bool? { didSet { needsDisplay = true; announce() } }
  /// This row opens another page. Drawn as a chevron on the right.
  var chevron = false { didSet { needsDisplay = true } }
  /// The word on the right is a BUTTON, not a fact -- "copy". Drawn as a chip so
  /// the difference between it and "yesterday" is visible rather than remembered.
  var valueIsAction = false { didSet { needsDisplay = true } }
  /// Which audio device this row selects. `tag` is an Int and already taken by the
  /// camera list; a CoreAudio UID is a string.
  var deviceUID: String?
  var deviceIsInput = true
  /// Where the words start. A stored property rather than the `glyph == nil`
  /// expression it replaces, so a subclass drawing a WIDER mark than a glyph can
  /// move the text without overriding `layout` and re-deriving the rest of it.
  var textInset: CGFloat = Metric.s3 { didSet { needsLayout = true } }
  // ── A SECOND THING TO PRESS, INSIDE THE ONE BUTTON ──────────────────────────
  //
  // The whole row is one `NSButton` and `hitTest` returns `self` for every point
  // in it, on purpose: a subview in front of a row is how this file has eaten
  // clicks before (`decoration-inside-a-control-eats-clicks`). So a row that
  // needs a second action -- "remove" on a person's row, where the row itself
  // RINGS them -- gets it as a strip at the right end that the tracking loop
  // checks on release, not as a view. `trailingReserve` is width the value word
  // moves left to leave free, RESERVED WHETHER OR NOT anything is drawn in it:
  // the strip appears on hover, and a word that shifts when the pointer arrives
  // is a target moving under a finger already travelling towards it.
  var trailingReserve: CGFloat = 0 { didSet { needsLayout = true; needsDisplay = true } }
  var trailingAction: (() -> Void)?
  var trailingRect: NSRect {
    guard trailingReserve > 0 else { return .zero }
    // Wider than what is drawn: the strip runs to the row's edge and takes the
    // full row height, so a press that is roughly on the × is on the ×.
    return NSRect(x: bounds.width - trailingReserve - Metric.s3, y: 0,
                  width: trailingReserve + Metric.s3, height: bounds.height)
  }

  /// Change what the row says after it has been built. A row whose words are
  /// fixed at `init` forces anything with two states -- a switch that reports what
  /// it did, an action that becomes its own result -- to be two rows that swap
  /// places, and a hidden row is a row that can be left visible by a path that
  /// forgot it. The accessibility label moves with the words, which is the half
  /// that gets forgotten when this is done by hand at a call site.
  func setLabel(_ s: String) {
    text.stringValue = s
    setAccessibilityLabel(s)
    needsLayout = true
    needsDisplay = true
    announce()
  }

  /// What VoiceOver reads out for the right-hand side. A switch that is only a
  /// drawing is a switch a screen reader cannot report, and this app has exactly
  /// one setting that decides whether anybody can reach the person using it.
  private func announce() {
    if let on = switchState {
      setAccessibilityRole(.checkBox)
      setAccessibilityValue(on ? 1 : 0)
    } else if !value.isEmpty {
      setAccessibilityValue(value)
    }
  }

  /// Just the words, with none of `spoken`'s decoration. A row whose LABEL is the
  /// datum -- a room name you can click to rejoin -- needs the string back
  /// unchanged, and `spoken` appends " ✓" and " = value" for the harness.
  var spokenName: String { text.stringValue }

  /// What this row actually says, for a test that has to read the screen.
  var spoken: String {
    // ── A SWITCH HAS TO SAY WHICH WAY IT IS ───────────────────────────────────
    //
    // The two settings that became switches used to carry a tick, and `checked`
    // put " ✓" in here. A switch is drawn, not ticked, so this went silent about
    // the one thing the row is for: "Calls when Kin is closed" read identically
    // whether anybody could reach this Mac or not. Invisible to a rig, and
    // invisible to VoiceOver until `announce()` was added beside it.
    //
    // ` = on` / ` = off` rather than a new word, because `= value` is the grammar
    // every reader of this string already knows.
    text.stringValue + (checked ? " ✓" : "")
      + (switchState.map { " = \($0 ? "on" : "off")" } ?? (value.isEmpty ? "" : " = \(value)"))
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
  // ── EXCEPT WHERE A FIRST CLICK REACHES ANOTHER PERSON ─────────────────────
  //
  // The same rule `WaitingCard.acceptsFirstMouse` already applies to answer,
  // decline, cancel and call-again, for the same reason and with the same
  // evidence behind it: a window that raises and activates ITSELF lands under
  // wherever the pointer already was, and this app has had a real trackpad tap
  // ANSWER a call nobody had decided to take.
  //
  // The home screen is the other half of that. It activates on launch, opens
  // centred, and what is now under the resting pointer is a list of people --
  // observed, before this existed: a launch put the list under the pointer and
  // the next click rang @arjun. So rows whose action reaches somebody or changes
  // the Mac turn this off, and the call bar's rows keep it, where a swallowed
  // click ("mute me now") is itself the bug.
  var acceptsFirstClick = true
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    // Counted, because this is a refusal nobody sees: without it the only trace
    // of "that click was aimed at another app" is that nothing happened, which is
    // indistinguishable from a row that does not work.
    if !acceptsFirstClick { Metrics.count("row_first_mouse_refused") }
    return acceptsFirstClick
  }

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
    var at = convert(event.locationInWindow, from: nil)
    while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
      at = convert(e.locationInWindow, from: nil)
      inside = bounds.contains(at)
      pressed = inside
      if e.type == .leftMouseUp { break }
    }
    pressed = false
    // Released outside the row is a cancelled press, the way every Mac button
    // behaves: you can slide off a row you did not mean to hit.
    guard inside else { return }
    // Judged where the finger LIFTED, like the row itself: a press that starts
    // on the name and slides onto the × removes, and the reverse rings, which
    // is what every button on this Mac does with a slide.
    if let go = trailingAction, trailingRect.contains(at) { go(); return }
    guard let t = target, let a = action else { return }
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
  // ── THE POINTER ARRIVING IS THE EARLIEST HONEST SIGNAL OF INTENT ──────────
  //
  // The front door uses this to warm a room before the click: a room object costs
  // ~1108 ms on the first request that touches it (CONTACTS.md), and the pointer
  // reaches a row some hundreds of milliseconds before the button goes down. That
  // is free time, and it was being spent on nothing.
  //
  // Fires on ENTER only, never on exit and never repeatedly, so a handler may
  // assume it is called about as often as a person moves across a list. Whatever
  // it starts must be idempotent and must not be something the click then waits
  // on -- a prefetch that the click blocks on is slower than no prefetch at all.
  var onHover: (() -> Void)?

  override func mouseEntered(with event: NSEvent) {
    guard !inert else { return }
    hovering = true; needsDisplay = true
    onHover?()
  }
  override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
  override func resetCursorRects() {
    if !inert { addCursorRect(bounds, cursor: .pointingHand) }
  }

  override func layout() {
    super.layout()
    let x = textInset
    // The right-hand gutter is what the accessory needs, not a constant 40 that
    // happened to fit the widest value anyone had tried. A long label used to run
    // under "only when open" and the two overlapped.
    var gutter: CGFloat = 40
    if switchState != nil { gutter = 34 + Metric.s3 * 2 }
    else if !value.isEmpty {
      let f: NSFont = valueIsWord ? Type_.button : Type_.code
      gutter = (value as NSString).size(withAttributes: [.font: f]).width
             + Metric.s3 * 2 + (valueIsAction ? 20 : 0)
             // A chevron sits outside the value, so it is not one or the other.
             + (chevron ? Metric.s4 : 0)
    } else if chevron { gutter = 28 }
    gutter += trailingReserve
    text.frame = NSRect(x: x, y: (bounds.height - 18) / 2,
                        width: max(20, bounds.width - x - gutter), height: 18)
  }

  override func draw(_ dirty: NSRect) {
    if hovering || pressed || forcedActive || keySelected {
      // A VIBRANT FILL, NOT A SECOND PANE OF GLASS. "Avoid overcrowding or layering
      // Liquid Glass elements on top of each other" -- and a row highlight inside a
      // glass sheet is the most tempting place in the app to break that rule.
      //
      // The radius is CONCENTRIC with the sheet rather than picked: the row is
      // inset by `sheetPad` inside a corner of `sheetRadius`, so sharing a centre of
      // curvature means 26 - 10 = 16. It was 12, which is the kind of number that
      // looks deliberate and is off by four.
      Palette.fill(pressed || forcedActive ? 0.12 : (keySelected ? 0.10 : 0.06)).setFill()
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
    // ── THE SWITCH ────────────────────────────────────────────────────────────
    if let on = switchState {
      let tw: CGFloat = 34, th: CGFloat = 20
      let box = NSRect(x: bounds.width - tw - Metric.s3, y: (bounds.height - th) / 2,
                       width: tw, height: th)
      (on ? Palette.switchOn : Palette.switchOff()).setFill()
      NSBezierPath(roundedRect: box, xRadius: th / 2, yRadius: th / 2).fill()
      // A hairline, so an OFF switch is still a shape over a bright picture rather
      // than a slightly different grey.
      Palette.chipLine.setStroke()
      let edge = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
                              xRadius: th / 2, yRadius: th / 2)
      edge.lineWidth = 1; edge.stroke()
      let k: CGFloat = th - 4
      let kx = on ? box.maxX - k - 2 : box.minX + 2
      NSColor.white.setFill()
      NSBezierPath(ovalIn: NSRect(x: kx, y: box.minY + 2, width: k, height: k)).fill()
    } else if chevron {
      // `>` -- 8 pt, 2 pt stroke, the same one every disclosure on this machine
      // draws. It costs nothing and it is the difference between a row that looks
      // inert and a row that looks like a door.
      let cx = bounds.width - Metric.s3 - 4, cy = bounds.height / 2
      let p = NSBezierPath()
      p.move(to: NSPoint(x: cx - 4, y: cy + 5))
      p.line(to: NSPoint(x: cx + 1, y: cy))
      p.line(to: NSPoint(x: cx - 4, y: cy - 5))
      p.lineWidth = 1.8; p.lineCapStyle = .round; p.lineJoinStyle = .round
      NSColor(white: 232.0 / 255, alpha: hovering ? 0.9 : 0.55).setStroke()
      p.stroke()
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
      // An ACTION reads at full strength inside a chip; a fact reads muted and bare.
      let ink: NSColor = valueIsAction ? Palette.fg
        : ((pending || valueIsWord) ? Palette.muted : Palette.fg)
      var a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: ink]
      if !pending, !valueIsWord { a[.kern] = 13.0 * 0.09 }
      let sz = (value as NSString).size(withAttributes: a)
      // ── A VALUE AND A CHEVRON SHARE ONE EDGE ────────────────────────────────
      //
      // Both were pinned to `bounds.width - Metric.s3`, so on the rows that have
      // both -- Microphone, Speaker, Camera -- the device name ran underneath the
      // chevron: "MacBook Air Microphon>". The whole point of naming the device on
      // the row is that you can read which one it is.
      let rightEdge = bounds.width - Metric.s3 - (chevron ? Metric.s4 : 0) - trailingReserve
      var tx = rightEdge - sz.width
      if valueIsAction {
        let padX: CGFloat = 10, h: CGFloat = 24
        let chip = NSRect(x: rightEdge - sz.width - padX * 2,
                          y: (bounds.height - h) / 2, width: sz.width + padX * 2, height: h)
        Palette.fill(hovering || pressed || forcedActive ? 0.20 : 0.10).setFill()
        NSBezierPath(roundedRect: chip, xRadius: h / 2, yRadius: h / 2).fill()
        Palette.chipLine.setStroke()
        let e = NSBezierPath(roundedRect: chip.insetBy(dx: 0.5, dy: 0.5),
                             xRadius: h / 2, yRadius: h / 2)
        e.lineWidth = 1; e.stroke()
        tx = chip.minX + padX
      }
      (value as NSString).draw(at: NSPoint(x: tx, y: (bounds.height - sz.height) / 2),
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
  /// ── CAN THIS PERSON BE REACHED, RIGHT NOW ────────────────────────────────
  ///
  /// Three states, and the third is load-bearing: `true` draws the dot, `false`
  /// draws nothing, and `nil` -- not asked yet, or the server unreachable --
  /// also draws nothing but says nothing. A dot that defaulted to grey-means-
  /// away would report every network hiccup as everybody having left
  /// (`blind-instruments-report-negatives`); absence of a dot merely reverts
  /// this row to what it was before presence existed.
  var reachable: Bool? {
    didSet {
      guard reachable != oldValue else { return }
      needsDisplay = true
      setAccessibilityLabel("call @" + handle + (reachable == true ? ", reachable now" : ""))
    }
  }

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

  // ── TAKING SOMEBODY OFF THE LIST ───────────────────────────────────────────
  //
  // Two ways in, because each covers the other's blind spot. An × at the right
  // end of the row, shown while the pointer is over it, is the one a person can
  // FIND; a right-click "Remove @meera" is the one a Mac user REACHES FOR, and
  // it is also the only one of the two that works with the pointer never
  // having to cross the name of somebody the row will ring on a click.
  //
  // Set by the owner; a row with no `onRemove` draws no × and reserves nothing,
  // so the rows inside a call are exactly what they were.
  var onRemove: (() -> Void)? {
    didSet {
      trailingReserve = onRemove == nil ? 0 : Metric.s6
      trailingAction = onRemove
    }
  }
  @objc private func removeSelf() { onRemove?() }
  override func menu(for event: NSEvent) -> NSMenu? {
    guard onRemove != nil else { return super.menu(for: event) }
    let m = NSMenu()
    let item = NSMenuItem(title: "Remove @" + handle, action: #selector(removeSelf),
                          keyEquivalent: "")
    item.target = self
    m.addItem(item)
    return m
  }

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
    Avatar.draw(handle, in: box, ring: Metric.avatarRing, font: Type_.avatar)
    // The dot, on the avatar's shoulder, punched out of it by a gap the colour
    // of nothing -- drawn as a clear circle rather than a background-coloured
    // one, because this row sits on glass and there is no one background colour
    // to imitate.
    if reachable == true {
      let dd: CGFloat = 9
      let at = NSRect(x: box.maxX - dd + 1, y: box.minY - 1, width: dd, height: dd)
      NSGraphicsContext.current?.saveGraphicsState()
      NSGraphicsContext.current?.compositingOperation = .destinationOut
      NSBezierPath(ovalIn: at.insetBy(dx: -2, dy: -2)).fill()
      NSGraphicsContext.current?.restoreGraphicsState()
      Palette.ok.setFill()
      NSBezierPath(ovalIn: at).fill()
    }
    // The ×, only while the pointer is on the row: at rest the row is a name and
    // a day, and a delete control on every row of a list of friends is a list
    // that looks like a to-do. Drawn, not a subview, for the reason the avatar is.
    if onRemove != nil, hovering {
      let d: CGFloat = 20
      let r = trailingRect
      let box = NSRect(x: r.maxX - Metric.s3 - d + 2, y: (bounds.height - d) / 2, width: d, height: d)
      Palette.fill(0.14).setFill()
      NSBezierPath(ovalIn: box).fill()
      let x = NSBezierPath()
      let c = NSPoint(x: box.midX, y: box.midY), k: CGFloat = 3.5
      x.move(to: NSPoint(x: c.x - k, y: c.y - k)); x.line(to: NSPoint(x: c.x + k, y: c.y + k))
      x.move(to: NSPoint(x: c.x - k, y: c.y + k)); x.line(to: NSPoint(x: c.x + k, y: c.y - k))
      x.lineWidth = 1.6; x.lineCapStyle = .round
      Palette.fg.setStroke(); x.stroke()
    }
  }
}

// ── ONE FACE, DRAWN IN ONE PLACE ─────────────────────────────────────────────
//
// A contact row has one and the calling card has one four times the size, and two
// copies of this drawing would be two faces for the same person that drift apart
// the first time either is nudged -- different ring weight, different letter
// inset, and nobody able to say which is the real one. It is a free function
// rather than a view because one caller draws it inside a row's own `draw` and the
// other needs a view of its own.
enum Avatar {
  static func draw(_ handle: String, in box: NSRect, ring rw: CGFloat, font: NSFont) {
    let ink = Palette.avatarInk(handle)
    // ── THE PERSON'S ACTUAL FACE, WHEN A CALL HAS PROVIDED ONE ───────────────
    //
    // Clipped to the same circle the initial lived in, with the same ink ring on
    // top -- the ring is the person's colour identity and it survives the
    // upgrade, so a face arriving does not make the row a stranger. Falls back
    // to the initial for anyone not yet called with video, which keeps this a
    // drawing decision made per handle in one place rather than two row species.
    if let img = Faces.image(handle) {
      NSGraphicsContext.current?.saveGraphicsState()
      NSBezierPath(ovalIn: box).addClip()
      img.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
      NSGraphicsContext.current?.restoreGraphicsState()
      let r = NSBezierPath(ovalIn: box.insetBy(dx: rw / 2, dy: rw / 2))
      ink.setStroke()
      r.lineWidth = rw
      r.stroke()
      return
    }
    // A fill and a hairline, the same idiom as every other thing that lives INSIDE
    // a glass surface. A second pane of glass here would be the one place in the
    // app that breaks "avoid layering Liquid Glass elements on top of each other".
    Palette.fill(0.08).setFill()
    NSBezierPath(ovalIn: box).fill()
    let r = NSBezierPath(ovalIn: box.insetBy(dx: rw / 2, dy: rw / 2))
    ink.setStroke()
    r.lineWidth = rw
    r.stroke()
    // `handle.first` uppercased, and it is always a letter: the server's rule is
    // `^[a-z][a-z0-9]{1,31}$` and `Identity.sanitize` applies it before anything
    // reaches here. No empty initial, no emoji, no combining marks to measure.
    let letter = String(handle.prefix(1)).uppercased()
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
    let sz = (letter as NSString).size(withAttributes: attrs)
    (letter as NSString).draw(at: NSPoint(x: box.midX - sz.width / 2,
                                          y: box.midY - sz.height / 2),
                              withAttributes: attrs)
  }
}

// ── WHEN THERE IS NO PICTURE, SHOW THE PERSON ────────────────────────────────
//
// A connected call whose far camera is off was a BLACK RECTANGLE. The only thing
// on it was a 12 pt warning pill at the top saying "their camera is off", and the
// row of buttons at the bottom -- which fades. So the ordinary case of somebody
// turning their camera off, on a call that is working perfectly, looked exactly
// like a call that had died: no name, no face, no sound you can see, nothing.
//
// Every other calling app answers this the same way and has for fifteen years:
// the person's circle, their name, and a word for what is happening. That is what
// this is. It reuses the same `Avatar.draw` the contact rows and the calling card
// use, so there is one face per person in this app and it cannot drift.
//
// It is NOT glass and it takes no dim. It is not a control floating above the
// content -- while it is up it IS the content, which is the one case the material
// policy in `Glass.swift` explicitly excludes ("don't use Liquid Glass in the
// content layer").
final class CameraOffPoster: NSView {
  private let face = Face()
  private let name = NSTextField(labelWithString: "")
  private let note = NSTextField(labelWithString: "")
  /// Decoration over the picture. Every click goes through to the controls.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    for (v, f, c) in [(name, Type_.name, Palette.fg), (note, Type_.status, Palette.muted)] {
      v.font = f
      v.textColor = c
      v.alignment = .center
      v.backgroundColor = .clear
      v.isBordered = false
      addSubview(v)
    }
    addSubview(face)
    isHidden = true
  }
  required init?(coder: NSCoder) { fatalError() }

  /// Whose face. An empty handle means a link-join, where the app does not know
  /// who is there -- the poster still says the camera is off, with no name and no
  /// circle, because inventing either would be worse than the blank.
  func setPerson(_ handle: String) {
    face.handle = handle
    face.isHidden = handle.isEmpty
    name.stringValue = handle.isEmpty ? "" : Identity.display(handle)
    needsLayout = true
    needsDisplay = true
  }

  /// The sentence under the name. Two states so far: their camera is off, and
  /// their picture has stopped while the call is still up.
  func setNote(_ s: String) {
    note.stringValue = s
    needsLayout = true
  }

  var describe: String {
    isHidden ? "hidden"
      : "\(face.handle.isEmpty ? "-" : face.handle)/\(note.stringValue)"
  }

  override func layout() {
    super.layout()
    // A column, centred, sized so it still fits a 320 pt window: the face shrinks
    // with the window rather than being clipped by it.
    let d = min(Metric.faceBig * 2, max(64, min(bounds.width, bounds.height) * 0.22))
    let gap = Metric.s4
    let nameH: CGFloat = name.stringValue.isEmpty ? 0 : 28
    let noteH: CGFloat = note.stringValue.isEmpty ? 0 : 18
    let total = (face.isHidden ? 0 : d + gap) + nameH + (nameH > 0 ? Metric.s2 : 0) + noteH
    var y = bounds.midY + total / 2
    if !face.isHidden {
      face.frame = NSRect(x: bounds.midX - d / 2, y: y - d, width: d, height: d)
      y -= d + gap
    }
    if nameH > 0 {
      name.frame = NSRect(x: 0, y: y - nameH, width: bounds.width, height: nameH)
      y -= nameH + Metric.s2
    }
    if noteH > 0 { note.frame = NSRect(x: 0, y: y - noteH, width: bounds.width, height: noteH) }
  }
}

/// The big one, as a view, for the card that is about a person.
final class Face: NSView {
  var handle = "" { didSet { needsDisplay = true } }
  /// Decoration on a card that routes its own clicks by frame. It must never be
  /// the answer to a hit test -- see `decoration-inside-a-control-eats-clicks`.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirty: NSRect) {
    guard !handle.isEmpty else { return }
    Avatar.draw(handle, in: bounds.insetBy(dx: 0.5, dy: 0.5),
                ring: Metric.faceBigRing, font: Type_.avatarBig)
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
  let field = Field()
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

  // ── THE CARET AND THE SELECTION, WHICH THE APP DOES NOT OWN BY DEFAULT ─────
  //
  // An `NSTextField` does not draw its own text while it is being edited: the
  // window lends it a FIELD EDITOR, a shared `NSTextView`, and that is what owns
  // the caret colour and the selection colours. So `field.textColor` -- which this
  // sets correctly -- has no say over either.
  //
  // Both were wrong on dark glass and one of them was wrong on every Mac. The
  // caret is the system default, which is nearly invisible on a dimmed well; and
  // the selection is drawn with the person's ACCENT COLOUR, which the app has no
  // control over at all -- somebody on the yellow accent gets white text on
  // yellow. Photographed over a bright picture, the pre-selected name in the
  // rename field was grey on grey and simply could not be read.
  //
  // ── APPLIED IN `becomeFirstResponder`, WHICH IS WHEN THE EDITOR EXISTS ─────
  //
  // The first version of this observed `textDidBeginEditing` and never once took
  // effect: `editor=selection=system caret=system` in the audit, with the field
  // focused and an editor present. `becomeFirstResponder` is the documented moment
  // AppKit installs the field editor, and returning from `super` is the first
  // instant `currentEditor()` is the object that will do the drawing.
  //
  // Per-session rather than once, because the editor is SHARED by every field in
  // the window: whatever it was last dressed in is what the next field inherits.
  final class Field: NSTextField {
    override func becomeFirstResponder() -> Bool {
      let ok = super.becomeFirstResponder()
      if ok, let tv = currentEditor() as? NSTextView {
        tv.insertionPointColor = Palette.caret
        tv.selectedTextAttributes = [
          .backgroundColor: Palette.selectionFill,
          .foregroundColor: NSColor.white,
        ]
      }
      return ok
    }
  }

  /// What the field editor is actually dressed in, for the audit. A colour set on
  /// a shared object by a notification is exactly the kind of thing that stops
  /// happening and leaves no trace.
  var describeEditor: String {
    guard let tv = field.currentEditor() as? NSTextView else { return "not editing" }
    let sel = (tv.selectedTextAttributes[.backgroundColor] as? NSColor)
      .map { $0 == Palette.selectionFill ? "ours" : "system" } ?? "none"
    let car = tv.insertionPointColor == Palette.caret ? "ours" : "system"
    return "selection=\(sel) caret=\(car)"
  }

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
  /// Kept, because `describeTree` reports it. A hint is a SENTENCE THE PERSON
  /// READS and hints are not `SheetRow`s, so every one of them was invisible to
  /// every rig here -- the same argument that put `warn=` in the state dump. The
  /// one that says why this Mac has no name is the whole of what a person gets
  /// told about being uncallable, and nothing could see it.
  private(set) var text: String

  /// Replace the sentence. The height a hint wants depends on the words in it, so
  /// this re-measures rather than leaving the caller to remember to -- a hint that
  /// grew from one line to two and kept its old box put the second line under the
  /// bottom edge, which is the defect `wantedHeight` was added to fix in the first
  /// place. `describeTree` reads `text`, so it moves too.
  func setText(_ s: String) {
    text = s
    label.stringValue = s
    measure(width: bounds.width)
    needsLayout = true
    needsDisplay = true
  }

  init(_ text: String) {
    self.text = text
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
  /// The one surface in the app made mostly of sentences, which is the case the
  /// guidance names for `.regular` -- "components have a significant amount of
  /// text, such as alerts, sidebars, or popovers". It is clear anyway, because the
  /// person whose app this is asked for that everywhere; the reading it has to
  /// carry is why it takes the full dim and not a fraction of it.
  private let glass = Glass("sheet", radius: Metric.sheetRadius, textual: true)
  private(set) var rows: [SheetRow] = []
  /// The one field a page can carry, so `clickTargets` can name it without every
  /// caller having to hold on to the view it just handed over.
  private(set) var field: SheetField?
  /// The page's sentences, in order. Read by `describeTree`.
  var hints: [String] { items.compactMap { ($0 as? SheetHint)?.text } }

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
  // ── AND THREE MORE, ONE PER PIECE OF HARDWARE ─────────────────────────────
  //
  // The camera list used to sit inline on the settings page, which worked because
  // most Macs have one camera. Microphones and speakers do not behave like that:
  // a Mac with a display, a headset and an interface plugged in has four of each,
  // and twelve ticked rows above "Encryption code" is not a settings panel.
  //
  // So each becomes a row that NAMES what is in use and opens a page of choices --
  // the idiom every settings pane on this machine uses, and the one that scales
  // from one device to eight. Naming the current device on the row is half the
  // value on its own: "which microphone is Kin actually using" was previously
  // unanswerable from inside the app.
  enum Page: String { case settings, people, rename, camera, microphone, speaker }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    // ── THE TINT THAT USED TO BE HERE ─────────────────────────────────────────
    //
    // `glass.tint = Palette.glassTint`, and the reason given was real: over a
    // brightly lit face, the hint line under the encryption code photographed as
    // grey text on a grey astronaut. The fix was aimed one layer too high. A tint
    // is IN the material, so it dims the picture and the refraction together and
    // the surface stops reading as glass; stacked on `.regular` it is the milky
    // slab the person using this app reported. The dim under the material does the
    // same contrast job and leaves the refraction alone. It is `Palette.dimAlpha`
    // by default and this surface takes all of it -- see the declaration above.
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

  // ── A PANEL TALLER THAN THE WINDOW ─────────────────────────────────────────
  //
  // Photographed at the smallest window this app will now open -- 480x320, the
  // floor `contentMinSize` sets -- every row of the settings panel came back
  // `audit FAIL`, at y coordinates of 543, 495, 447, 399 and 351 in a window 320
  // points tall. The panel was drawn ABOVE the top edge of its own window. Nine
  // rows and three sentences want 565 points; the window had 258 to give; nothing
  // in the arithmetic compared the two, so the panel simply grew off the screen
  // and took every control on it out of reach. Not one setting was clickable, and
  // there was no scrollbar and no clipped edge to say why -- the rows were not
  // hidden, they were somewhere a mouse cannot go.
  //
  // It could not have been seen before, either: every rig here opens the default
  // window, so the smallest legal size was a floor nobody had ever photographed
  // AT. That is the whole reason `--window-size` exists.
  //
  // The fix is the ordinary answer for a list that outgrows its box, and it needs
  // no scroll view: the panel takes the room it is given, and the CONTENT moves
  // inside it. `scrollOffset` is how far down the list we are looking, in points,
  // from 0 to `maxScroll`; `layout()` adds it to the starting edge, so a larger
  // offset brings later rows up into the box. The rows keep their own frames and
  // their own `hitTest`, so click routing, `clickTargets` and the audit all keep
  // working unchanged -- the only thing that changes is which rows are inside the
  // box, and `onScreen` now asks that question.
  var scrollOffset: CGFloat = 0 { didSet { if scrollOffset != oldValue { needsLayout = true } } }
  /// How far the content can move. Zero when everything fits, which is the case
  /// on every window anyone has actually opened -- so the clip below, and every
  /// behaviour that follows from it, is inert at any ordinary size.
  var maxScroll: CGFloat { max(0, wantedHeight - bounds.height) }
  var scrolls: Bool { maxScroll > 0.5 }
  func clampScroll() { scrollOffset = min(max(0, scrollOffset), maxScroll) }
  /// A wheel or a two-finger swipe. Precise deltas are already points; a notched
  /// wheel reports lines, and half a row per line is the usual conversion.
  func scrollBy(_ delta: CGFloat, precise: Bool) {
    scrollOffset = min(max(0, scrollOffset - (precise ? delta : delta * Metric.sheetRow / 2)),
                       maxScroll)
  }

  /// Bring one item fully inside the box, and say whether anything moved. This is
  /// what lets a rig -- and the keyboard, and `click(_:)` -- reach a row that is
  /// currently scrolled out, instead of reporting it missing.
  @discardableResult
  func reveal(_ v: NSView) -> Bool {
    guard scrolls, items.contains(where: { $0 === v }) else { return false }
    // Where the item sits in the content, measured from the content's top.
    var top = Metric.sheetPad
    for it in items {
      if it === v { break }
      top += height(of: it)
    }
    let h = height(of: v)
    let before = scrollOffset
    // Offset counts down the list, so the item is inside the box when
    // `top >= offset` (not off the top) and `top + h <= offset + boxHeight`.
    if top < scrollOffset { scrollOffset = top }
    else if top + h > scrollOffset + bounds.height { scrollOffset = top + h - bounds.height }
    clampScroll()
    if scrollOffset != before { needsLayout = true; layoutSubtreeIfNeeded() }
    return scrollOffset != before
  }

  /// What a rig can read instead of guessing: how many rows are actually inside
  /// the box, and where in the list we are. An instrument that cannot see the
  /// clip would report the same thing for a panel that fits and one that hides
  /// four settings.
  var describeScroll: String {
    guard scrolls else { return "fits" }
    let shown = items.filter { $0.frame.minY >= -0.5 && $0.frame.maxY <= bounds.height + 0.5 }.count
    return "\(shown)/\(items.count) shown scroll=\(Int(scrollOffset))/\(Int(maxScroll))"
  }

  override func layout() {
    super.layout()
    glass.frame = bounds
    glass.radius = Metric.sheetRadius
    clampScroll()
    // ── CLIPPED ONLY WHEN IT HAS TO BE ──────────────────────────────────────
    //
    // A mask on this layer is what makes a half-row at the edge read as "there is
    // more" -- the only affordance this panel has, and the one every list on this
    // machine uses. It is also a mask over a glass surface, and the material
    // samples what is behind it, so it is switched on ONLY while the content
    // overflows. At every ordinary window size this line does nothing, which is
    // deliberate: a change that alters how the glass draws for everybody, to fix
    // a case that only exists below 320 points, would be the wrong trade.
    layer?.cornerRadius = Metric.sheetRadius
    layer?.masksToBounds = scrolls
    var y = bounds.height - Metric.sheetPad + scrollOffset
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
final class WaitingCard: NSView, NSTextFieldDelegate {
  // ── THE WHOLE INVITE, IN TWO CONTROLS ──────────────────────────────────────
  //
  // This card used to be seven things: a title, a hint, a link, `share`, `copy`, a
  // name field and `call`, inside a panel sized to hold them all. Every one of
  // them was defensible on its own and together they were a form -- a form that
  // opened over your own face, in an app whose entire pitch is that there is
  // nothing to fill in before a call starts.
  //
  // What is left is the link and one round button. The link copies when you click
  // it, which it always did and never said; the button turns the link into a name
  // field, because sending a link and calling a name are the same intention --
  // reach a person -- and only one of them can be what you meant at a time.
  //
  // The panel went with the words. A panel exists to hold text on top of a moving
  // picture; with no text there is nothing to hold, and a pane of glass around a
  // pane of glass was the thing that made this read as a dialog.
  // ── PLACING A CALL IS A STATE, AND IT LOOKED LIKE NO STATE AT ALL ─────────
  //
  // `calling` and `noAnswer` are the caller's half of `ringing`, and their absence
  // was a real bug: placing a call re-execs into the new room, the successor knows
  // only that it is in a room by itself, and so it drew the ordinary waiting card
  // -- "Waiting for the other person…" over an invite link. Identical, to the
  // pixel, to an app that had just been opened and was doing nothing.
  //
  // So the person who pressed call saw no name, no progress and no way to stop,
  // and had to guess between "it is ringing" and "it crashed". The two states are
  // built here as one screen with two sides on purpose: whatever the person
  // ringing sees, the person being rung should see the mirror of.
  enum Mode: String { case invite, dial, ringing, calling, noAnswer }
  /// One value decides what is on screen, so two states cannot both be. This was
  /// three booleans that had to agree, and the ringing state got its visibility
  /// from a different one than its layout did.
  private(set) var mode: Mode = .invite

  // ── STILL A CARD WHEN SOMEBODY IS RINGING ─────────────────────────────────
  //
  // The ringing state is the one moment here that has to say words -- WHO is
  // calling -- and a name over an unknown camera frame needs a surface. So the
  // panel, the title and the hint are alive, and they belong to `.ringing` alone.
  /// THE CARD IN THE SCREENSHOT. It was `.regular` with `glassTint` painted into
  /// it, over a 0.55 radial wash across the whole window -- three dimming devices
  /// and a blur, and what came out was a milky slab with a face somewhere behind
  /// it. Clear now, over one dim, and the dim stops at the card's own corners.
  private let panel = Glass("card", radius: Metric.cardRadius, textual: true)
  /// Who the card is about. There is no photograph in this app and never will be
  /// (see CONTACTS.md), so the circle IS the person: their own colour, derived
  /// from their handle and the same on both Macs for ever.
  private let face = Face()
  private let title = NSTextField(labelWithString: "")
  private let hint = NSTextField(labelWithString: "")

  private let urlField = NSTextField(labelWithString: "")
  // ── WHICH ONE OF THESE IS CORRECT DEPENDS ON WHAT IS UNDER IT ──────────────
  //
  // This was a `Vibrant` -- a flat white-at-10% fill -- and the comment above it
  // said, correctly, that a pane of glass on a pane of glass is the one thing the
  // guidance names outright. That was true while there was a PANEL under it.
  //
  // There is no panel now, so the rule points the other way: this is a lone
  // control sitting directly on somebody's picture, which is the case the real
  // material exists for. The flat fill could not do it -- white at 10% over a
  // white wall is a white box, and the link on it measured 3.7:1. Clear glass over
  // the dim beats both: the dim is a known quantity under a material that adapts
  // to what is behind it, which is what a constant alpha cannot do on its own.
  private let urlGlass = Glass("url", radius: Metric.cardFieldRadius, textual: true)
  // ── A HOLDER, BECAUSE THE GLASS OWNS ITS CONTENT VIEW ─────────────────────
  //
  // `NSGlassEffectView` places and sizes whatever it is given as `contentView` --
  // that is the guarantee, and it is the reason the field goes inside rather than
  // on top. It also means a frame set on the field itself is a frame the glass is
  // free to overwrite, which it does: the link handed over directly drew hard
  // against the top of the pill instead of through the middle of it.
  //
  // So the glass is handed a plain view to place, and the field is positioned
  // inside THAT, in coordinates nothing else is going to rewrite.
  private let urlHolder = NSView()
  // ── CALLING A NAME INSTEAD OF SENDING A LINK ────────────────────────────────
  //
  // The one editable thing in this app. It is in the same place as the link and
  // never beside it: the link is for people you have never called, the field is
  // for the ones you have, and being asked to choose between two boxes at the
  // moment you open the app is the choice this screen exists to not make you make.
  private let dialGlass = Glass("dial", radius: Metric.cardFieldRadius, textual: true)
  private let dialHolder = NSView()
  private let dialField = NSTextField()
  /// A handset, not the word "call". The row it sits in is a link and a button;
  /// the link is already the only thing here carrying text, and a word next to it
  /// makes two things to read where there is one thing to do.
  private let callIcon = IconButton(Glyph.phone, size: Metric.fieldHeight,
                                    help: "Call someone by name")
  private let answerButton = PillButton("answer")
  private let declineButton = PillButton("decline")
  private let cancelButton = PillButton("cancel")
  private let againButton = PillButton("call again")
  // ── SOMETHING THAT IS OBVIOUSLY ALIVE ─────────────────────────────────────
  //
  // The complaint this whole state answers is "you don't know if you're calling or
  // something crashed", and a caption alone cannot settle that -- a frozen app
  // shows its last caption perfectly. Three dots taking turns cannot be a
  // screenshot of a dead process.
  //
  // Layers with their own animations rather than a timer retitling the label: the
  // panel is sized to its widest child, so text that grows and shrinks four times
  // a second would resize the card four times a second. These are drawn at a fixed
  // place and the layout never hears about them.
  // ── AND THEY HAVE TO BE ABOVE THE PANEL ───────────────────────────────────
  //
  // These began as sublayers of the CARD's own layer, which is below `panel` --
  // a subview added on top of it. They animated perfectly, behind a pane of
  // glass, and the photograph showed a card with a considerate empty gap in it
  // where the one moving thing was supposed to be. A layer added to `self.layer`
  // is under every subview, and the panel is a subview.
  //
  // A view of their own, added after the panel, puts them where the title and the
  // hint already are.
  private let dotsView = NSView()
  private let dots = [CALayer(), CALayer(), CALayer()]
  private var calleeName = ""

  /// Kept separately from `urlField.stringValue`, which the copy confirmation
  /// borrows for two seconds. Reading the link back out of the label would hand
  /// somebody "copied ✓" as their invite.
  private var urlText = ""
  var url = "" {
    didSet {
      urlText = url
      if !confirming { urlField.stringValue = url }
      needsLayout = true
    }
  }
  var onCopy: (() -> Void)?
  /// A handle was typed and confirmed. The card does not know how to ring, only
  /// that somebody asked to.
  var onCall: ((String) -> Void)?
  var onAnswer: (() -> Void)?
  var onDecline: (() -> Void)?
  /// Stop calling. There is no un-ring -- the ring is already in their mailbox and
  /// they may still answer -- so this ends the call this side, exactly as hanging
  /// up on a phone that is still ringing does.
  var onCancelCall: (() -> Void)?
  /// The card gave up. The pill says what the card says, or it sits there reading
  /// "calling @meera…" underneath a card that has stopped calling anybody.
  var onCallGaveUp: ((String) -> Void)?

  /// Somebody is ringing. Set to switch the card from "invite" to "answer".
  private(set) var incoming: (from: String, room: String)?

  /// When the ring card appeared. Read by the keyboard path -- see
  /// `CallControls.handleKey`.
  private(set) var ringingSince: Date?

  func setIncoming(from: String, room: String) {
    incoming = (from, room)
    ringingSince = Date()
    face.handle = from
    // ── THE SENTENCE UNDER IT IS GONE, ON BOTH SIDES ─────────────────────────
    //
    // It read "answer and you will both be in the same room". Two problems, and
    // the second is the one that mattered. It explained something nobody needs
    // explaining -- a person looking at a face, a name and a button marked
    // `answer` knows what answering does. And "room" is this app's OWN word: an
    // implementation detail from the version where you joined a URL, kept in the
    // sentence people read at the one moment they are least interested in how it
    // works. You call a person. There is no room.
    title.stringValue = "\(Identity.display(from)) is calling"
    hint.stringValue = ""
    mode = .ringing
    applyMode()
  }

  /// This app is ringing somebody. The mirror of `setIncoming`.
  func setOutgoing(to who: String) {
    Metrics.fact("outcome", "calling")
    calleeName = who
    face.handle = who
    title.stringValue = "Calling \(Identity.display(who))"
    hint.stringValue = ""
    mode = .calling
    applyMode()
    startRingTimeout()
  }

  /// They picked up. Separate from "the card was hidden": the card is hidden and
  /// shown for several reasons, and a ring that is still counting down behind a
  /// hidden card will eventually declare no-answer in the middle of the call it
  /// is answering -- then show that verdict the moment the other person steps
  /// away and the card comes back.
  func callAnswered() {
    ringTimer?.invalidate(); ringTimer = nil
    guard mode == .calling || mode == .noAnswer else { return }
    calleeName = ""
    mode = .invite
    applyMode()
  }

  /// Nobody picked up. Not an error -- a person who was not at their Mac.
  private func ringTimedOut() {
    guard mode == .calling else { return }
    Metrics.count("ring_timed_out")
    Metrics.fact("outcome", "no answer")
    // "their Mac may be closed" asked the reader to think about a machine. What
    // they want to know is about a person, and the honest answer is short: we put
    // the call through and nobody picked it up.
    setCallFailed("\(Identity.display(calleeName)) didn\u{2019}t answer",
                  because: "they might be away")
  }

  /// The two ways a call can fail to start, in one state. A ring that could not be
  /// delivered and a ring nobody answered look different from here and identical
  /// to the person waiting: no call. What differs is the sentence.
  func setCallFailed(_ line: String, because why: String) {
    guard mode == .calling else { return }
    title.stringValue = line
    hint.stringValue = why
    mode = .noAnswer
    applyMode()
    onCallGaveUp?(line)
  }

  // ── A CADENCE WITH A RIG OVERRIDE ─────────────────────────────────────────
  //
  // 45 s is about as long as a phone rings. A test that had to sit through it
  // would be a test nobody runs, so the wait is settable from the environment and
  // the product's own number is the default.
  private var ringTimer: Timer?
  private func startRingTimeout() {
    ringTimer?.invalidate()
    let secs = Double(ProcessInfo.processInfo.environment["TK_RING_TIMEOUT"] ?? "") ?? 45
    let t = Timer(timeInterval: secs, repeats: false) { [weak self] _ in self?.ringTimedOut() }
    RunLoop.main.add(t, forMode: .common)
    ringTimer = t
  }

  func clearIncoming() {
    guard incoming != nil || mode == .ringing else { return }
    incoming = nil
    mode = .invite
    applyMode()
  }

  /// One place decides what is on screen.
  // ── A CLICK NOBODY AIMED ───────────────────────────────────────────────────
  //
  // Three times in one afternoon this card answered a call with nobody at the
  // keyboard, each time at a slightly different point inside the answer pill --
  // so a real pointer, not this app's own synthetic presses, which always land on
  // a control's exact centre. The shape is always the same: the ring window sets
  // itself `.floating`, orders itself in front of everything and activates five
  // times over two seconds (see Ringer), and it does all of that UNDERNEATH a
  // pointer that has been sitting still. Whatever click then arrives was aimed at
  // whatever used to be there.
  //
  // Two facts separate that from a person answering, and both are recorded the
  // moment the card changes mode:
  //
  //   · a person has to SEE the card before they can decide. Nobody reads a name
  //     and hits a 74-point pill in under a third of a second.
  //   · a person MOVES THE POINTER to the button. A click at the exact pixel the
  //     pointer was already parked on, with no movement in between, was aimed at
  //     whatever was on screen before this card took the front.
  //
  // Either one alone would be too blunt. Together they refuse the accident and
  // let every real press through -- and a refusal says so, because a control that
  // silently ignores a finger is the bug this is meant to prevent, inverted.
  private var modeAt = Date.distantPast
  private var pointerAtMode = NSPoint(x: -10_000, y: -10_000)

  private func applyMode() {
    modeAt = Date()
    pointerAtMode = NSEvent.mouseLocation
    let m = mode
    // The three states that say a person's name are the three that need a surface
    // under the words. `invite` and `dial` are two controls on the picture.
    let worded = m == .ringing || m == .calling || m == .noAnswer
    panel.isHidden = !worded
    title.isHidden = !worded
    hint.isHidden = !worded
    urlGlass.isHidden = m != .invite
    urlField.isHidden = m != .invite
    dialGlass.isHidden = m != .dial
    dialField.isHidden = m != .dial
    callIcon.isHidden = worded
    answerButton.isHidden = m != .ringing
    declineButton.isHidden = m != .ringing
    cancelButton.isHidden = m != .calling && m != .noAnswer
    againButton.isHidden = m != .noAnswer
    // While it is ringing, this stops the call: `cancel`. Once the call is over
    // there is nothing left to cancel and the button only puts the card away, so
    // it says `close`. One control, and it says what it does at the time.
    cancelButton.title2 = m == .noAnswer ? "close" : "cancel"
    face.isHidden = !worded
    dotsView.isHidden = m != .calling
    if m == .calling { startDots() } else { stopDots() }
    if m != .calling { ringTimer?.invalidate(); ringTimer = nil }
    // The same circle means "ask me who" and then "ring them". Saying so is the
    // difference between a button that changed and a button that moved.
    callIcon.toolTip = m == .dial ? "Call this name" : "Call someone by name"
    callIcon.setAccessibilityLabel(callIcon.toolTip)
    // A field left holding half a name is a field that answers the NEXT question
    // with the last one's answer. The field editor too -- see `dialConfirmed`.
    if m != .dial { dialField.currentEditor()?.string = ""; dialField.stringValue = "" }
    needsLayout = true
    needsDisplay = true
    window?.invalidateCursorRects(for: self)
  }

  // ── THE SWAP ────────────────────────────────────────────────────────────────
  //
  // The link does not slide aside to make room; it goes, and the field takes its
  // place. Both rows are laid out at the SAME width for the same reason -- the
  // button must not move under a finger that is already on it, because the second
  // click somebody makes here is on the same circle as the first.
  func enterDial() {
    guard mode != .ringing else { return }
    mode = .dial
    applyMode()
    layoutSubtreeIfNeeded()
    _ = window?.makeFirstResponder(dialField)
    Metrics.tap("dial_open")
  }

  /// Back to the link, with nothing typed carried over.
  @discardableResult
  func leaveDial() -> Bool {
    guard mode == .dial else { return false }
    mode = .invite
    applyMode()
    if window?.firstResponder === dialField.currentEditor() || window?.firstResponder === dialField {
      _ = window?.makeFirstResponder(nil)
    }
    return true
  }

  /// Whatever is in the name field right now, live -- including the letters the
  /// field editor is holding, which is where they live while somebody is still
  /// typing. Reading `stringValue` alone reports the value as of the last commit,
  /// so a rig that types and then looks sees an empty box and calls it a failure.
  var dialText: String { dialField.currentEditor()?.string ?? dialField.stringValue }

  /// What is typed in the field, cleaned up the way the server will see it.
  private func dialled() -> String? {
    let raw = dialText.trimmingCharacters(in: .whitespacesAndNewlines)
    return Identity.sanitize(raw.hasPrefix("@") ? String(raw.dropFirst()) : raw)
  }

  @objc private func dialConfirmed() {
    // An empty field is not a failed call, it is a change of mind: the same
    // circle that opened this closes it. Counting that as a failure would put a
    // fault in the record every time somebody looked at the field and thought
    // better of it.
    // `dialText`, NOT `stringValue`. While somebody is typing, the letters live in
    // the field editor and `stringValue` still holds the value as of the last
    // COMMIT -- which, for a field nobody has pressed Enter in, is the empty
    // string. Enter commits first and hid this completely; the button does not,
    // and reading `stringValue` there meant: type a name, click the handset, watch
    // the name disappear and no call happen. The control that exists to start a
    // call would have been the one way to start no call.
    if dialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      leaveDial(); return
    }
    guard let h = dialled() else { Metrics.tap("call", ok: false); return }
    Metrics.tap("call")
    // Both halves: the field editor is what is on screen, `stringValue` is what
    // the next read returns, and clearing one and not the other leaves the name
    // behind in whichever of them the next reader happens to look at.
    dialField.currentEditor()?.string = ""
    dialField.stringValue = ""
    mode = .invite
    applyMode()
    onCall?(h)
  }

  /// Put the caret in the name field. The people panel's "Call someone new" row
  /// hands over to this rather than growing a second field: there is exactly one
  /// place in this app you type a name into, and two of them would be two places
  /// that can disagree about what a name is.
  @discardableResult
  func focusDial() -> Bool {
    guard mode != .ringing, window != nil else { return false }
    enterDial()
    return window?.firstResponder === dialField || window?.firstResponder === dialField.currentEditor()
  }

  // ── THE CONFIRMATION IS ON THE THING YOU CLICKED ───────────────────────────
  //
  // "copied ✓" used to appear on the `copy` button, which was fine while the
  // button existed and was the whole problem the moment the link itself became
  // the control: you clicked a box, the box did nothing visible, and the only
  // evidence was on a pill three inches away. A click with no answer is a click
  // people make twice and then stop making.
  private var confirming = false
  func confirmCopied() {
    confirming = true
    urlField.stringValue = "copied ✓"
    urlField.textColor = Palette.ok
    let token = urlText
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
      guard let self, self.confirming else { return }
      self.confirming = false
      // From `urlText`, not from the label, and only if the link has not changed
      // underneath the confirmation.
      self.urlField.stringValue = self.urlText.isEmpty ? token : self.urlText
      self.urlField.textColor = Palette.fg
      self.needsLayout = true
    }
  }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    // `radial-gradient(ellipse at center, rgba(6,8,13,.55), transparent 72%)`.
    // ── THE RADIAL WASH IS GONE ───────────────────────────────────────────────
    //
    // `radial-gradient(ellipse at center, rgba(6,8,13,.55), transparent 72%)`,
    // transcribed from the web app and kept for as long as this card has existed.
    // It was a window-sized ellipse of dark centred on the middle of the picture:
    // the textbook definition of a vignette, and the single largest thing making
    // the calling card look like a slab -- 55% of the frame gone before the
    // material had done anything at all.
    //
    // What it was for lives inside `panel` now, at the card's own size and with
    // the card's own corners. Nothing this class owns paints outside a control.

    // No tint. It was `Palette.glassTint` and it was half of what the person using
    // this app was looking at when they said "transparent, not frosted" -- see the
    // declaration of `panel` and rule 2 in `Glass.swift`.
    addSubview(panel)
    addSubview(face)

    for (t, font, colour) in [(title, Type_.name, Palette.fg),
                              (hint, Type_.caption, Palette.muted)]
        as [(NSTextField, NSFont, NSColor)] {
      t.font = font
      t.textColor = colour
      t.alignment = .center
      t.backgroundColor = .clear
      t.isBordered = false
      // A backstop for the same failure the width calculation fixes: when the
      // window is narrower than the sentence, end the line with an ellipsis
      // instead of cutting a word in half.
      t.lineBreakMode = .byTruncatingTail
      addSubview(t)
    }
    urlField.font = Type_.mono
    urlField.textColor = Palette.fg
    urlField.alignment = .center
    urlField.backgroundColor = .clear
    urlField.isBordered = false
    // NOT selectable any more. A selectable label swallows the click that is now
    // the control: you would drag out a text selection instead of copying, which
    // is the exact gesture people try when a copy button has just been taken away.
    urlField.isSelectable = false
    addSubview(urlGlass)
    urlHolder.addSubview(urlField)
    urlGlass.content = urlHolder

    dialField.font = Type_.row
    dialField.textColor = Palette.fg
    // ── LEFT, WHERE THE CARET IS ──────────────────────────────────────────────
    //
    // Centred, an empty field puts the insertion point at the middle of the box
    // and the placeholder around it, so the caret is drawn INSIDE the hint --
    // photographed as a cursor sitting in the middle of the word "want". It reads
    // as text somebody already typed and half-deleted rather than as an empty box
    // waiting for a name. Every search field on this platform is left aligned for
    // this reason, and the link above it is centred because a link is a value to
    // read, not a place to type.
    dialField.alignment = .left
    dialField.backgroundColor = .clear
    dialField.drawsBackground = false
    dialField.isBordered = false
    dialField.isEditable = true
    dialField.isSelectable = true
    dialField.focusRingType = .none
    dialField.placeholderString = "who do you want to call?"
    // Enter sends the action. A field you have to reach for a button after is a
    // field people type into and then wonder why nothing happened.
    dialField.target = self
    dialField.action = #selector(dialConfirmed)
    dialField.delegate = self
    addSubview(dialGlass)
    dialHolder.addSubview(dialField)
    dialGlass.content = dialHolder

    // A real NSButton action, not the card's frame routing: `IconButton` with no
    // `onHold` falls through to `super`, which is press-here-release-here, which
    // is what every Mac button does and what a control that starts a call has to
    // do. See the note on `mouseDown` below for why the other three cannot.
    callIcon.target = self
    callIcon.action = #selector(callIconPressed)
    addSubview(callIcon)

    cancelButton.tint = Palette.fg
    againButton.prominent = true
    addSubview(cancelButton)
    addSubview(againButton)
    dotsView.wantsLayer = true
    // Decoration. It must never take a click that belongs to the card underneath.
    dotsView.isHidden = true
    addSubview(dotsView)
    for d in dots {
      d.backgroundColor = Palette.fg.cgColor
      d.cornerRadius = 3
      dotsView.layer?.addSublayer(d)
    }
    // The one thing on the screen a person is meant to press. It was green TEXT on
    // an ordinary pill while `call again` on the next card over was a prominent
    // one, so the app's primary action looked less primary than its consolation
    // prize. `prominent` is the file's own word for this: brighter fill, heavier
    // type, exactly one per surface.
    answerButton.prominent = true
    answerButton.tint = Palette.ok
    // Deliberately NO `onPress` on these two: the card routes them through
    // mouseDown/mouseUp below so they commit on release. Wiring `onPress` as well
    // would give them a second, press-to-commit path -- the exact thing being
    // removed.
    addSubview(answerButton)
    addSubview(declineButton)
    applyMode()
  }
  required init?(coder: NSCoder) { fatalError() }

  // ── ESCAPE HAS TO BE ASKED FOR HERE ────────────────────────────────────────
  //
  // Not in `CallControls.handleKey` with the app's other keys. While a field is
  // being typed into, AppKit routes the key to its FIELD EDITOR, which turns
  // Escape into `cancelOperation:` and consumes it -- so the window's `keyDown`
  // never sees it and an Escape handler written up there is dead exactly when
  // somebody wants it. This is the one place the key actually arrives.
  func control(_ control: NSControl, textView: NSTextView,
               doCommandBy sel: Selector) -> Bool {
    guard sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
    return leaveDial()
  }

  /// Clicking away from an empty field is the same change of mind as pressing the
  /// button again, and leaving a blank box with no link under it would be a screen
  /// with nothing on it at all.
  func controlTextDidEndEditing(_ obj: Notification) {
    guard mode == .dial,
          dialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    leaveDial()
  }

  // Phase-shifted so they take turns rather than blinking together, which reads as
  // a fault light rather than as waiting.
  private func startDots() {
    for (i, d) in dots.enumerated() where d.animation(forKey: "pulse") == nil {
      let a = CABasicAnimation(keyPath: "opacity")
      a.fromValue = 0.25; a.toValue = 1.0
      a.duration = 0.55
      a.autoreverses = true
      a.repeatCount = .infinity
      a.beginTime = CACurrentMediaTime() + Double(i) * 0.18
      a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      d.add(a, forKey: "pulse")
    }
  }
  private func stopDots() { for d in dots { d.removeAnimation(forKey: "pulse") } }

  /// Whether the waiting dots are actually running, for the state dump. "The
  /// layer exists" and "it is animating" are two claims and only the second one is
  /// the reassurance this state is for.
  var dotsAlive: Bool { dots.allSatisfy { $0.animation(forKey: "pulse") != nil } }

  /// What the card is saying, when it is saying anything. Empty in the two states
  /// that are controls rather than sentences.
  var cardWords: String { title.isHidden ? "" : title.stringValue }

  /// Whose circle is on the card, or empty when there is no card.
  var faceOf: String { face.isHidden ? "" : face.handle }

  @objc private func callIconPressed() {
    if mode == .dial { dialConfirmed() } else { enterDial() }
  }

  // ── A FULL-SURFACE OVERLAY MUST NOT EAT THE BAR ────────────────────────────
  //
  // `#waiting` is `inset: 0` so its wash is centred on the window rather than on a
  // box, which means it covers the buttons too. In CSS that is harmless -- the bar
  // has a higher z-index. Here it is a subview added last, so without the
  // `hitTest` below it would swallow every click on mic, camera and leave, and the
  // call would look frozen while being perfectly fine.
  // ── THE CLICK THAT BRINGS KIN FORWARD MUST NOT ANSWER THE CALL ────────────
  //
  // Measured, twice, on a ring nobody touched:
  //
  //     ring: answer committed by leftMouseUp at (606.75, 294.92)
  //     ring: answer committed by leftMouseUp at (605.44, 289.64)
  //
  // Two different fractional points a few pixels apart -- so not this app's own
  // synthetic presses, which always land on a control's exact centre. That is a
  // real pointer, over a window that had just raised and activated ITSELF to
  // ring, with `acceptsFirstMouse` saying yes to everything on it. The call was
  // answered, the microphone went live, and nobody had decided anything.
  //
  // So the card now answers that question per control. The link still copies on
  // a first click -- it always did, it is harmless, and a card that appears the
  // instant the app opens should not need two clicks to be useful. Answer,
  // decline, cancel and call-again do not: they join a room, end a call, or place
  // one, and every Mac app makes you bring a window forward before a control like
  // that will fire. This is the same argument as commit-on-release two hundred
  // lines below, one step earlier in the same event.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    guard let event else { return true }
    let p = convert(event.locationInWindow, from: nil)
    for v in [answerButton, declineButton, cancelButton, againButton] as [NSView]
    where !v.isHidden && v.frame.contains(p) {
      // Counted, because this is a refusal nobody sees. Without it the only trace
      // of "somebody's click was aimed at another app" is that nothing happened,
      // which is indistinguishable from a control that does not work.
      Metrics.count("card_first_mouse_refused")
      return false
    }
    return true
  }

  /// What `acceptsFirstMouse` would say at a control's own centre, for the audit.
  /// Read out rather than reasoned about: the rule above is geometry, and geometry
  /// written down in a comment is geometry nobody checks again.
  func firstMouseAt(_ v: NSView) -> Bool {
    let mid = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: self)
    for c in [answerButton, declineButton, cancelButton, againButton] as [NSView]
    where !c.isHidden && c.frame.contains(mid) { return false }
    return true
  }

  /// Only what is actually on screen, so the `?` audit cannot report a control
  /// the current mode has hidden.
  var clickTargets: [(String, NSView)] {
    switch mode {
    case .ringing: return [("answer", answerButton), ("decline", declineButton)]
    case .calling: return [("cancel", cancelButton)]
    case .noAnswer: return [("again", againButton), ("cancel", cancelButton)]
    case .invite:
      // Named for the same reason the buttons are: a screen reader landing here
      // otherwise announces a rectangle. The link IS the invite, and clicking it
      // copies -- which is the part a person cannot guess and a reader must say.
      urlGlass.setAccessibilityRole(.button)
      urlGlass.setAccessibilityLabel("Invite link \(url), click to copy")
      return [("link", urlGlass), ("call", callIcon)]
    case .dial: return [("dial", dialField), ("call", callIcon)]
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let p = convert(point, from: superview)
    // ── TWO THINGS THAT MUST NOT BE ROUTED TO SELF ──────────────────────────
    //
    // The pills answer `self`, because the card handles its own presses by frame.
    // A TEXT FIELD cannot work that way: typing needs it to become first
    // responder, and that only happens if the click actually reaches it. Routing
    // it to `self` would give a field that draws, highlights on hover, and can
    // never be typed into.
    //
    // The call button is the second, for a different reason: it is a real
    // NSButton and its own press/release tracking is what makes it commit on
    // release. Intercepting the click here to call the action by hand would be a
    // second, press-to-commit path to starting a call.
    if !dialField.isHidden, dialGlass.frame.contains(p) { return dialField }
    if !callIcon.isHidden, callIcon.frame.contains(p) { return callIcon }
    for v in [urlGlass, answerButton, declineButton, cancelButton, againButton]
    where !v.isHidden && v.frame.contains(p) { return self }
    return nil
  }

  // ── THE CONSEQUENTIAL ONES COMMIT ON RELEASE ───────────────────────────────
  //
  // Copy is harmless and fires on press, as it always has. Answer and decline are
  // not: answering joins a room, and a control that commits on mouse-DOWN commits
  // to whatever the pointer happened to be over. One unattributed auto-answer
  // during testing was enough -- press-then-release inside the same pill is what
  // every Mac button does, and it also lets somebody slide off a pill they did not
  // mean to hit. `call` gets the same guarantee from NSButton itself.
  private var armed: NSView?

  /// The link itself copies when clicked -- `#shareUrl { cursor: pointer }`, and
  /// now the only way to copy it from this screen.
  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    armed = nil
    for v in [answerButton, declineButton, cancelButton, againButton] as [NSView]
    where !v.isHidden && v.frame.contains(p) {
      let since = Date().timeIntervalSince(modeAt)
      let here = NSEvent.mouseLocation
      let moved = abs(here.x - pointerAtMode.x) > 2 || abs(here.y - pointerAtMode.y) > 2
      // `eventNumber == 0` is this app's own harness, which has no pointer to move
      // and is not the thing being defended against.
      // ONE SECOND, and it is not a guess. Caught in the act while four test rigs
      // were running and somebody was using this Mac at the same time:
      //
      //   card: PillButton ringing armed at 612,309 -- eventNumber=2777 subtype=3
      //   card: PillButton ringing armed at 603,284 -- eventNumber=2810 clicks=2
      //
      // Real trackpad taps (subtype 3, non-zero event numbers, one of them a
      // double-click) landing on a ring card that had just thrown itself in front
      // of what that person was doing. Their click was aimed at another app and
      // answered a call instead. A second is longer than any accident and shorter
      // than anybody who has to see a name before deciding.
      // THE THIRD ONE, and it is the one that caught the real taps. A tap landed
      // 1.6 seconds after the card appeared with the pointer having moved, so
      // neither test above saw it -- and it was still nobody's decision, because
      // the pointer had been sitting where that pill appeared the whole time.
      // A person answering MOVES ONTO the button; if the hover began at the same
      // instant the card did, the card came to the pointer. `hoverSince` is nil
      // when there is no tracking at all (the window never became key), and that
      // falls back to the two tests above rather than refusing -- a guard that can
      // make the control dead is worse than the accident it prevents.
      // Two ways to know, because the first one is not always available: the
      // tracking areas that maintain `hoverSince` only run in a key window, and a
      // window that never became key would report nil for a pointer sitting right
      // on the pill. The geometric test needs nothing -- was the pointer inside
      // this pill's rectangle at the instant the card took the screen?
      let hovered = (v as? PillButton)?.hoverSince
        .map { $0.timeIntervalSince(modeAt) < 0.15 } ?? false
      let wasOverIt = window
        .map { $0.convertToScreen(convert(v.frame, to: nil)).contains(pointerAtMode) } ?? false
      let arrivedWithCard = hovered || wasOverIt
      // The one second has a rig override, like every other cadence here: a rig
      // that has to wait out a production timer either waits or tests something
      // else, and this one is otherwise only reachable by having a person tap the
      // trackpad at the right moment.
      let aim = (Double(ProcessInfo.processInfo.environment["TK_AIM_MS"] ?? "") ?? 1000) / 1000
      if event.eventNumber != 0, since < aim || !moved || arrivedWithCard {
        fputs("card: ignored a click nobody aimed -- \(Int(since * 1000)) ms after the"
            + " \(mode.rawValue) card appeared, pointer moved=\(moved)"
            + " arrivedWithCard=\(arrivedWithCard)\n", stderr)
        Metrics.count("card_click_unaimed")
        return
      }
      armed = v
      // ── WHERE A CONSEQUENTIAL PRESS CAME FROM ────────────────────────────
      //
      // These four join a room, end a call or place one, and this app has twice
      // recorded one committing with nobody at the keyboard. `eventNumber` is the
      // window server's own counter: a real device event carries a non-zero one,
      // and this app's own synthetic presses are built with zero. `clickCount`
      // and `pressure` say the same thing from another angle. Printed at the
      // PRESS, because by the release the process may already be gone.
      fputs("card: \(type(of: v)) \(mode.rawValue) armed at \(Int(p.x)),\(Int(p.y))"
          + " -- eventNumber=\(event.eventNumber) clicks=\(event.clickCount)"
          + " pressure=\(event.pressure) active=\(NSApp.isActive)"
          + " subtype=\(event.subtype.rawValue)"
          + " after=\(Int(since * 1000))ms moved=\(moved)\n", stderr)
      return
    }
    if !urlGlass.isHidden, urlGlass.frame.contains(p) { onCopy?(); return }
    super.mouseDown(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    let was = armed
    armed = nil
    guard let v = was, !v.isHidden, v.frame.contains(p) else {
      // ── A PRESS THAT DID NOT COMMIT SAYS WHY ────────────────────────────────
      //
      // This is the release half of answer, decline, cancel and call again -- the
      // four presses in this app that a person cannot repeat without consequence.
      // It refused one in ten under test and said nothing at all, which is the
      // same silence as no click ever arriving. Three separate conditions can
      // refuse it, so the log names which.
      if was != nil || mode == .ringing || mode == .calling || mode == .noAnswer {
        fputs("card: a release did NOT commit -- armed="
            + (was.map { "\(type(of: $0))" } ?? "nothing")
            + " hidden=\(was?.isHidden.description ?? "-")"
            + " inside=\(was.map { $0.frame.contains(p).description } ?? "-")"
            + " at \(Int(p.x)),\(Int(p.y)) mode=\(mode.rawValue)\n", stderr)
      }
      super.mouseUp(with: event); return
    }
    if v === answerButton { onAnswer?() }
    else if v === declineButton { onDecline?() }
    else if v === cancelButton { onCancelCall?() }
    else if v === againButton {
      Metrics.tap("call_again")
      Metrics.count("call_again")
      let who = calleeName
      setOutgoing(to: who)
      onCall?(who)
    }
  }

  /// The hand is the affordance. With the `copy` button gone it is the only thing
  /// on screen that says the link is a control rather than a caption, so it is
  /// added and removed with the link rather than left pointing at empty space.
  override func resetCursorRects() {
    guard mode == .invite, !urlGlass.frame.isEmpty else { return }
    addCursorRect(urlGlass.frame, cursor: .pointingHand)
  }

  // ── THE DIM IS THE SIZE OF THE THING IT IS DIMMING FOR ────────────────────
  //
  // `setWash(alpha:)` used to be here, and the heading above it was already
  // arguing the right principle while the code kept getting the scope wrong. It
  // started window-sized at 0.55, was cut to the width of the link row when the
  // card shrank, and was still an ellipse of dark on somebody's picture in every
  // version of it.
  //
  // The heading survives because it is now literally true and enforced by
  // geometry: the only dimming device left is `Glass.dim`, whose bounds ARE the
  // control's bounds. There is no alpha to tune and no ellipse to size, so no
  // future edit can widen it back onto the face by half a screen.

  override func layout() {
    super.layout()
    let cx = bounds.midX, cy = bounds.midY
    let worded = mode == .ringing || mode == .calling || mode == .noAnswer
    let gap = Metric.s2
    let uh = Metric.fieldHeight

    func textW(_ f: NSTextField, _ s: String? = nil) -> CGFloat {
      ceil(((s ?? f.stringValue) as NSString)
        .size(withAttributes: [.font: f.font ?? Type_.caption]).width)
    }

    // ── ONE WIDTH FOR BOTH ROWS ───────────────────────────────────────────────
    //
    // The link is as wide as the link, and the name field is as wide as the link
    // too. Sizing each to its own content would move the button sideways at the
    // exact moment somebody has just clicked it -- the swap is meant to read as
    // the box changing its mind, not as the row rebuilding itself.
    //
    // The old floor was a flat 300, which is what made this "way too big": a box
    // padded out to a width nothing in it needed, with two buttons beside it.
    // ── A LABEL IS WIDER THAN ITS STRING ──────────────────────────────────────
    //
    // `size(withAttributes:)` measures GLYPHS. An NSTextField draws them inside a
    // cell that keeps a couple of points to itself on each side, so a field given
    // exactly the measured width has less room than it needs and drops whatever
    // does not fit off the end -- silently, with no ellipsis to say so. Measured:
    // the box rendered
    //
    //     https://kin.tokkah.com/gxg-kcrq-vw
    //
    // for a link ending in `vwp`, which is not a shorter link, it is a WRONG one.
    // Nobody proof-reads a URL they are about to send, and this is the one string
    // in the app where a missing character is the difference between reaching
    // somebody and a dead page.
    let cellInk = Metric.s2
    let linkText = textW(urlField, urlText.isEmpty ? urlField.stringValue : urlText) + cellInk
    let dialText = textW(dialField, dialField.placeholderString ?? "") + cellInk
    let boxW = min(max(max(linkText, dialText) + Metric.s6, 180), bounds.width * 0.7)
    let rowW = boxW + gap + callIcon.frame.width

    // ── THE THREE STATES THAT SAY A NAME SHARE ONE LAYOUT ─────────────────────
    //
    // Deliberately, and it is the whole point of the change: the person ringing
    // and the person being rung are looking at the same card in the same place
    // with the same shape, so neither of them has to work out which side of the
    // call they are on. Only the words and the buttons differ.
    if worded {
      let pad = Metric.cardPad
      let titleH: CGFloat = 28, hintH: CGFloat = 16
      let faceD = Metric.faceBig
      let row: [PillButton]
      switch mode {
      case .ringing: row = [answerButton, declineButton]
      case .calling: row = [cancelButton]
      case .noAnswer: row = [againButton, cancelButton]
      default: row = []
      }
      let rowW = row.reduce(0) { $0 + $1.frame.width } + gap * CGFloat(max(0, row.count - 1))
      // A card has to be as wide as its widest CHILD, and the words are children:
      // sized from the row alone, the hint once read "answer and you will both be
      // in the sa", clipped mid-word by a panel built around two small pills.
      let contentW = max(rowW, textW(title), textW(hint))
      // Every band is present only if it has something in it. Reserving space for
      // an empty hint is how a card ends up with a considerate gap in the middle
      // of it, which is exactly what the waiting dots were hiding behind.
      let hasHint = !hint.stringValue.isEmpty
      let dotD: CGFloat = 6
      // ── ONE CURSOR, TOP TO BOTTOM, NO BAND WITHOUT CONTENT ──────────────────
      //
      // The first version of this reserved a band for the dots and then placed
      // them relative to a cursor that had already moved past it, so they came out
      // six points above the button and read as part of it. Written as a single
      // downward cursor -- subtract the gap, subtract the height, place -- the
      // arithmetic is the same shape as the layout and cannot disagree with the
      // panel height computed from the same terms.
      let bandsH = faceD + Metric.s4 + titleH
                 + (hasHint ? Metric.s1 + hintH : 0)
                 + (mode == .calling ? Metric.s5 + dotD : 0)
                 + Metric.s5 + uh
      // A floor on the width. Sized to its content alone, a card holding one short
      // name came out narrower than it was tall -- a column, not a card. The words
      // still win when they are longer than this.
      let panelW = min(bounds.width - Metric.gutter * 2, max(contentW + pad * 2, 300))
      let panelH = pad + bandsH + pad
      panel.frame = NSRect(x: cx - panelW / 2, y: cy - panelH / 2,
                           width: panelW, height: panelH)
      panel.radius = Metric.cardRadius

      var y = panel.frame.maxY - pad
      y -= faceD
      face.frame = NSRect(x: cx - faceD / 2, y: y, width: faceD, height: faceD)
      y -= Metric.s4 + titleH
      title.frame = NSRect(x: panel.frame.minX, y: y, width: panelW, height: titleH)
      if hasHint {
        y -= Metric.s1 + hintH
        hint.frame = NSRect(x: panel.frame.minX, y: y, width: panelW, height: hintH)
      }
      if mode == .calling {
        y -= Metric.s5 + dotD
        // No implicit animation on the placement. A CALayer animates its own frame
        // by default, so every layout pass would slide the dots across the card --
        // on top of the pulse they are running, which is the one motion here that
        // is supposed to mean something.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let w = dotD * 3 + 7 * 2
        dotsView.frame = NSRect(x: cx - w / 2, y: y, width: w, height: dotD)
        var dx: CGFloat = 0
        for dot in dots {
          dot.frame = CGRect(x: dx, y: 0, width: dotD, height: dotD)
          dx += dotD + 7
        }
        CATransaction.commit()
      }
      y -= Metric.s5 + uh
      var ax = cx - rowW / 2
      for b in row {
        b.frame.origin = NSPoint(x: ax, y: y + (uh - b.frame.height) / 2)
        ax += b.frame.width + gap
      }
      return
    }

    // Invite and dial share one line through the middle of the window. Nothing is
    // above it and nothing is below it, so it is centred on the window rather than
    // on a card that no longer exists.
    let y = cy - uh / 2
    let x = cx - rowW / 2
    let box = NSRect(x: x, y: y, width: boxW, height: uh)
    urlGlass.frame = box
    urlGlass.radius = Metric.cardFieldRadius
    dialGlass.frame = box
    dialGlass.radius = Metric.cardFieldRadius
    // ── THE FIELDS ARE INSIDE THE GLASS NOW ───────────────────────────────────
    //
    // So their frames are in the HOLDER's coordinate space, not the card's. Left as
    // card coordinates they would be laid out several hundred points off the side
    // of their own parent -- present, correct, and nowhere on screen.
    urlHolder.frame = NSRect(x: 0, y: 0, width: boxW, height: uh)
    dialHolder.frame = urlHolder.frame
    urlField.frame = NSRect(x: Metric.s3, y: (uh - 15) / 2,
                            width: boxW - Metric.s6, height: 15)
    // A little further in than the link: text that starts at a left edge needs
    // more air off the curve than text that is centred between two of them.
    dialField.frame = NSRect(x: Metric.s4, y: (uh - 17) / 2,
                             width: boxW - Metric.s8, height: 17)
    callIcon.frame.origin = NSPoint(x: x + boxW + gap,
                                    y: y + (uh - callIcon.frame.height) / 2)
    // The link stops being a control the moment it stops being on screen.
    window?.invalidateCursorRects(for: self)
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
    // ── AND A NAME, EVERY TIME THE WORDS CHANGE ────────────────────────────
    //
    // The `answer` button on an incoming call announced as nothing at all -- found
    // by the audit's UNNAMED marker in `cancelrace-check`, in the most important
    // moment the app has. Set here rather than in `init` because these buttons are
    // relabelled in place (`answer`, `decline`, `cancel`, `call`), so a name
    // assigned once would go stale the first time the card changed its mind.
    setAccessibilityRole(.button)
    setAccessibilityLabel(t)
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
  /// When the pointer arrived on this pill, or nil if it is not on it. Read by
  /// the waiting card: a pointer that arrived AT THE SAME MOMENT as the card did
  /// not travel here, the card travelled to it.
  private(set) var hoverSince: Date?
  override func mouseEntered(with event: NSEvent) {
    hoverSince = Date()
    hovering = true; glass.level = prominent ? 0.42 : 0.20
  }
  override func mouseExited(with event: NSEvent) {
    hoverSince = nil
    hovering = false; glass.level = prominent ? 0.30 : 0.13
  }
}

final class CallControls: NSView {
  /// Space at the bottom the video should not put anything important in. Published
  /// so the self-view sits above the bar rather than a second file guessing.
  /// Derived now, rather than the constant 98 it used to be, so moving the row off
  /// the edge cannot leave the self-view overlapping it.
  static let barHeight: CGFloat = Metric.barInset + Metric.control + Metric.s4

  // ── WHO, AND FOR HOW LONG ──────────────────────────────────────────────────
  //
  // This was `roomPill`, and it was dead: built, laid out, never given a string,
  // and reported by `describeTree` as an empty field for months. Meanwhile a
  // connected call said NOTHING about who was on it. Every other calling app on
  // this machine puts a name and a clock somewhere, and this one had a picture
  // and four circles -- which is fine right up to the moment their camera is off,
  // and then it is a black rectangle with no name on it.
  //
  // Same slot, same size, top-left, clear of the traffic lights. It fades with the
  // control row, because it is chrome and the picture is the point.
  private let whoPill = Pill(font: Type_.status)
  /// The person, when there is no picture of them. See `CameraOffPoster`.
  private let poster = CameraOffPoster(frame: .zero)
  /// Who this call is with, as a handle. Empty for a link-join, where the app
  /// genuinely does not know and must not invent one.
  private(set) var peerHandle = ""
  /// Ticks the clock in `whoPill` once a second while a call is up.
  private var elapsedTimer: Timer?
  // ── THE TWO GRADIENTS THAT USED TO BE HERE ─────────────────────────────────
  //
  // `scrim` was 190 pt of dark up from the bottom edge, `topScrim` 130 pt down
  // from the top, and between them they were the HIG's dimming rule applied to the
  // WINDOW instead of to the surfaces. Both are gone. The report was "there should
  // be no vignette of any kind... it should all be very natural", and a gradient
  // fading across a person's chin is exactly a vignette however well it is
  // justified in the comment above it.
  //
  // What they were doing is still done, one layer lower and inside each control's
  // own rounded rectangle -- see `Glass.dim`. That is the distinction the whole
  // change turns on: a dark patch the size and shape of a button is part of the
  // button; a dark patch the size of the window is something painted on the person.
  // The bar circles used to pass `dim: 0` because the scrim was doing it for them,
  // and they carry their own now.
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
  private let sheetScrim: ScrimView = {
    let v = ScrimView()
    // The full-window dismiss layer. A click anywhere on it closes the panel and
    // it is the most-used way out, so it is not "an unlabelled region" to anyone
    // navigating by voice.
    v.setAccessibilityRole(.button)
    v.setAccessibilityLabel("Close settings")
    return v
  }()
  private let camPicker = NSPopUpButton()
  /// The camera picker's surface. Up beside the `more` button in the top corner,
  /// where the scrim is only 0.28 and is a gradient rather than a floor, so it
  /// carries the full dim of its own.
  private let camGlass = Glass("camPicker", radius: 0, textual: true)
  private var camNames: [String] = []

  private(set) var micMuted = false
  private(set) var camOff = false
  var onMic: ((Bool) -> Void)?
  var onCam: ((Bool) -> Void)?
  var onLeave: (() -> Void)?
  /// Cancelling a call that has not been answered. Distinct from `onLeave`
  /// because there is somebody on the other end who has to be TOLD -- see
  /// `sendBye` in main.swift. Optional, and the fallback below is `onLeave`.
  var onHangUp: (() -> Void)?
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

    // ── NOTHING IS PAINTED ON THE PICTURE ─────────────────────────────────────
    //
    // Two `CAGradientLayer`s used to be added here, and the case for them was a
    // good one: the HIG's "if the underlying content is bright, consider adding a
    // dark dimming layer of 35% opacity", and a measured defect where one of them
    // ran the wrong way round and put a hard dark edge across the middle of the
    // frame. Both are deleted rather than fixed further.
    //
    // The reason is what a person watching a call actually said, and it is not a
    // point about gradients: "there should be no vignette of any kind. There
    // should not be any effect. It should all be very natural." What they were
    // looking at was somebody's face with the corners and the chin quietly darker
    // than the middle -- which nobody reads as a legibility device. They read it as
    // the video being wrong.
    //
    // So the rule this file follows now: the picture gets NOTHING. Every dimming
    // device in the app is inside the bounds of the control it is for, and those
    // bounds are a rounded rectangle you can point at. If a control is hard to read
    // over a bright face, the answer is in `Glass.dim` for that control -- never a
    // wash across the frame that also lands on somebody's cheek.

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
    // ── THE GREEN EDGE GOES IN LAST ───────────────────────────────────────────
    //
    // After every `addSubview`, so it sits above their layers and cannot be
    // covered. Nothing else in this window draws within two points of the frame,
    // so this is belt and braces rather than a fix -- but a state indicator that
    // is sometimes behind something is worse than one that is never there.
    //
    // It is a LAYER, so it takes no part in hit testing: `decoration-inside-a-
    // control-eats-clicks` cost this app every glass button once, and the answer
    // there was that a view over a control is a view a click can land on. This
    // cannot be, at any width.
    edge.fillColor = nil
    edge.lineWidth = CallControls.edgeWidth
    // `Palette.ok`, which this app already uses for "clear", "good" and the
    // answer button. A new green would have been a second word for a thing the
    // palette already says.
    edge.strokeColor = Palette.ok.cgColor
    edge.opacity = 0
    layer?.addSublayer(edge)
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
    whoPill.isHidden = true
    addSubview(whoPill)
    // BELOW the pills and the row, ABOVE nothing -- it is the content while it is
    // up, so it goes in first and everything else floats over it as usual.
    addSubview(poster, positioned: .below, relativeTo: nil)
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
    // Through `dial`, not straight at `onCall`. The field and a tapped face are the
    // same act and they now travel the same line -- including the fallback for a
    // doorbell that is not wired, which the field used to be missing.
    waiting.onCall = { [weak self] h in self?.dial(h) }
    waiting.onAnswer = { [weak self] in self?.onAnswerRing?() }
    waiting.onCallGaveUp = { [weak self] line in self?.setStatus(line) }
    waiting.onCancelCall = { [weak self] in
      guard let self else { return }
      Metrics.tap("cancel_call")
      self.setStatus("call cancelled")
      // Through the hang-up hook when there is one, so the other Mac is told
      // instead of ringing on into a timeout nobody can see. Falls back to the
      // plain leave, which is what this did when there was nothing to send: an
      // unwired hook must never be the difference between leaving and staying.
      if let hangUp = self.onHangUp { hangUp() } else { self.onLeave?() }
    }
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
    // The edge follows the window, so its path is rebuilt whenever the window
    // changes shape and never on the 30 Hz tick, which only touches opacity.
    layoutEdge()

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
    // ── AND IT STOPS AT THE BOTTOM OF THE WINDOW ──────────────────────────────
    //
    // This was `y: max(s3, moreY - s2 - sh)` with `sh` the panel's full wanted
    // height, which pinned the BOTTOM edge at the gutter and let the top edge go
    // wherever the content wanted -- off the top of the window, on any window
    // shorter than about 660 points. See `Sheet.scrollOffset`. Now the top edge is
    // fixed under the button that opened the panel, the bottom stops at the same
    // gutter everything else uses, and the height is whichever is smaller: what
    // the content wants, or the room there is. The content scrolls inside it.
    let top = moreButton.frame.minY - Metric.s2
    let room = max(Metric.sheetRow * 2, top - Metric.s3)
    let sh = min(sheet.wantedHeight, room)
    sheet.frame = NSRect(x: w - Metric.gutter - sw, y: max(0, top - sh),
                         width: sw, height: sh)
    sheet.clampScroll()
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
    poster.frame = bounds

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
    let py = h - whoPill.frame.height - topPad
    whoPill.setFrameOrigin(NSPoint(x: Metric.gutter, y: py))
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
  /// The far end has gone quiet and the call is being held open for them. Not the
  /// same question as `peerPresent`, which stays true through a hold because the
  /// CALL has not ended -- this is the narrower "is anybody actually there right
  /// now", and it is what the control row has to answer.
  private var barHolding = false
  func setHolding(_ on: Bool) {
    guard on != barHolding else { return }
    barHolding = on
    // Shown, deliberately NOT pinned. A pin would hold the row for ten seconds and
    // then hand it to `barHoldReason`, which means for those ten seconds the row
    // is up for a reason nobody can observe -- and the fade timer, the thing that
    // has to refuse, never fires at all. `waiting` holds it up on its own for as
    // long as the hold lasts, so showing it once is enough and the refusal is
    // visible the first time the timer comes round. A pin here would have hidden
    // whether the fix worked.
    if on { showBar() } else { nudgeBar() }
  }

  func setPeerPresent(_ present: Bool) {
    onMain { [weak self] in
      guard let self else { return }
      // Re-stated, not trusted. `inviteText`'s observer is what normally pushes the
      // URL into the card, and it last ran before the call; this is the one place
      // that reads it back out after a whole call has happened.
      // They picked up. Stops the no-answer countdown, which would otherwise fire
      // in the middle of the call it is measuring and leave that verdict waiting
      // on the card for the moment the other person steps away.
      if present { self.waiting.callAnswered() }
      if !present { self.waiting.url = self.inviteText }
      // A ring that arrived and was never answered must not be sitting on this
      // card when the peer leaves and it comes back -- the room in it is long
      // expired, and "answer" would join an empty one.
      if !present { self.waiting.clearIncoming(); self.waiting.leaveDial() }
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
      // ── THE FADE'S OWN PRECONDITION, STATED WHERE IT IS KNOWN ───────────────
      //
      // `sawPeer` is a LATCH -- it exists so a ring arriving mid-call is refused,
      // and it never clears. "Somebody is here now" is a different question, and
      // it is the one the immersive fade turns on: a window with nobody in it
      // keeps its controls, whatever has happened to it earlier in the call.
      self.peerPresent = present
      self.waiting.isHidden = present
      // The control row must not fade out while this card is the only way off this
      // screen. Bounded pin, the same one `markConnected` uses.
      if !present { self.showBar(pin: true) }
      // And a peer who comes BACK restarts the stillness clock. `markConnected`
      // fires once per process and cannot do it a second time, so without this a
      // returning peer gets a row that never fades again for the rest of the call.
      if present { self.showBar() }
      self.needsLayout = true
      self.layoutSubtreeIfNeeded()
    }
  }

  /// `#waiting.gone` -- the card goes the moment there is someone to look at, and
  /// `#status.gone`: "connected" is said once and then gets out of the face's way.
  /// Who is on the other end. Told once, by whichever of the three routes into a
  /// call knew it -- a ring placed, a ring answered, a resume. A link-join has no
  /// answer and gets none: an invented name on a call is worse than no name.
  func setPeer(_ handle: String) {
    onMain { [weak self] in
      guard let self, !handle.isEmpty, handle != self.peerHandle else { return }
      self.peerHandle = handle
      self.renderWho()
      self.poster.setPerson(handle)
    }
  }

  /// `Meera · 4:12`. The name alone before the call starts, the clock alone when
  /// there is no name.
  private func renderWho() {
    let name = peerHandle.isEmpty ? "" : Identity.display(peerHandle)
    var t = ""
    if let s = startedAt {
      let secs = Int(Date().timeIntervalSince(s))
      t = secs >= 3600
        ? String(format: "%d:%02d:%02d", secs / 3600, (secs / 60) % 60, secs % 60)
        : String(format: "%d:%02d", secs / 60, secs % 60)
    }
    let line = [name, t].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    whoPill.text = line
    whoPill.isHidden = line.isEmpty || !barShown
    if !line.isEmpty {
      whoPill.setFrameOrigin(NSPoint(x: Metric.gutter,
                                     y: frame.height - whoPill.frame.height - Metric.topInset))
    }
  }

  func markConnected() {
    let first = startedAt == nil
    if first { startedAt = Date() }
    if first {
      // `.common`, so the clock keeps running while a menu is open or the window
      // is being dragged -- the two moments a frozen clock looks like a frozen app.
      let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.renderWho() }
      RunLoop.main.add(t, forMode: .common)
      elapsedTimer = t
      onMain { [weak self] in self?.renderWho() }
    }
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
  /// ── THE ONLY SETTER ON THIS VIEW THAT DID NOT HOP ─────────────────────────
  ///
  /// `setStatus` directly above, and `setTheirWords`/`setMyWords` directly below,
  /// all go through `onMain`. This one did not, and it touches `NSView` state
  /// three ways -- the pill's text, its origin, and `showBar()`, which reaches
  /// `-[NSView _setHidden:]`. Called off the main thread that is a SIGABRT, and
  /// it was: a report-thread call to `setWarning` killed a process outright while
  /// the same-room work was being built.
  ///
  /// It has survived in shipping builds only by luck. `reportLoop` calls
  /// `setWarning("")` every second from its own thread, and clearing an already
  /// clear pill returns at the guard below before touching a view -- so the app
  /// is one non-empty warning off the main thread away from aborting, and always
  /// has been. See `unexplained-death-is-a-bug`: no AppKit object is touched from
  /// a thread that is not the main one, and "it has not crashed yet" is not the
  /// test.
  ///
  /// The guard and the log stay on the CALLING thread on purpose: `warnText` is
  /// the de-duplication and belongs with the caller's ordering, and a log line
  /// deferred to a main-queue hop would timestamp the wrong moment.
  /// ── TWO WRITERS, ONE PILL, AND A ROW THAT NEVER FADED ────────────────────
  ///
  /// There is one warning pill and there were two independent writers for it:
  /// `Display.setPaused` says what the far end's microphone, camera and link are
  /// doing, and the report loop says whether the two of you are in one room. Each
  /// republishes once a second, so with both true they overwrote each other
  /// forever:
  ///
  ///     76  warning: their camera is off
  ///     74  warning: You're in the same room, so Kin turned this speaker off.
  ///
  /// Every one of those 150 flips is a `showBar()`, and `showBar` re-arms the
  /// 2.6 s stillness timer -- so the control row could never fade for the rest of
  /// the call. Six of immersive-check's assertions failed and every one of them
  /// named the fade, which is the symptom and not the fault. It took `--no-sameroom`
  /// ranking 0 failures against 5 in three paired runs to place it here at all.
  ///
  /// Neither writer was wrong. A single-valued sink with two owners and no
  /// precedence has no correct writer -- so the precedence is written down, once,
  /// here. The room sentence wins: it explains something KIN has just done to the
  /// sound, and in one room you can hear the other person with your own ears
  /// whatever their microphone is doing.
  ///
  /// The pill only moves when the WINNER changes, so a slot updating underneath a
  /// higher one costs nothing and cannot re-show the row.
  private var warnPeer = ""
  @objc private func troubleClicked() {
    guard !troubleLocal.isEmpty, let go = onTroubleClick else { return }
    fputs("trouble: the person clicked \"\(troubleLocal)\"\n", stderr)
    Metrics.count("trouble_click")
    go()
  }
  private var warnRoom = ""
  /// What the far end's devices and link are doing. Every existing caller.
  func setWarning(_ line: String) { warnPeer = line; renderWarning() }

  // ── SOMETHING IS WRONG AT THIS END, AND ONLY THIS END KNOWS ────────────────
  //
  // Every sentence this pill carried was about the OTHER person: their camera is
  // off, their connection is weak, they'll be right back. There was no way for it
  // to say anything about this Mac -- and the worst failure in the app is exactly
  // that shape.
  //
  // A person who has denied the microphone gets a call that looks completely
  // normal. The timer runs, the picture is there, the controls work, and nobody
  // can hear them. `gMicAccess` knew; it went into two telemetry fields and
  // nowhere else, so the only trace was a line on stderr that nobody sees. The
  // far end hears silence and both people blame the app.
  //
  // It takes precedence over the peer sentence because it is actionable and
  // theirs is not: a weak link mends itself, a permission does not.
  func setTrouble(_ line: String?) {
    troubleLocal = line ?? ""
    renderWarning()
  }
  /// What clicking the pill should open, when the trouble is a permission. Set
  /// beside the sentence so the two cannot disagree.
  var onTroubleClick: (() -> Void)?
  private var troubleLocal = ""

  // ── AND THE SAME FACT, DRAWN LARGE ────────────────────────────────────────
  //
  // The warning pill and the poster are two renderings of ONE state, so they are
  // set from one place. Two independent writers for one fact is the shape this
  // file has already paid for twice -- see the note over `warnPeer`.
  /// `nil` means there is a picture. A string means there is not, and it is the
  /// sentence to put under their name.
  func setNoPicture(_ why: String?) {
    onMain { [weak self] in
      guard let self else { return }
      let show = why != nil && self.startedAt != nil
      if let why { self.poster.setNote(why) }
      guard show != !self.poster.isHidden else { return }
      self.poster.isHidden = !show
      self.poster.needsLayout = true
      fputs("poster: \(show ? "showing \(self.poster.describe)" : "hidden")\n", stderr)
    }
  }
  /// Kin's own action on the sound. Outranks the above while it is non-empty.
  func setRoomWarning(_ line: String) { warnRoom = line; renderWarning() }

  private func renderWarning() {
    // Local first, then the room, then the peer. See `setTrouble`.
    let line = !troubleLocal.isEmpty ? troubleLocal : (warnRoom.isEmpty ? warnPeer : warnRoom)
    guard line != warnText else { return }
    warnText = line
    fputs("warning: \(line.isEmpty ? "(cleared)" : line)\n", stderr)
    onMain { [weak self] in
      guard let self else { return }
      self.warnPill.text = line
      // ── AND IT IS CLICKABLE WHEN THERE IS SOMETHING TO DO ─────────────────
      //
      // "Turn on the microphone in System Settings" is four clicks away through a
      // pane most people have never opened. The front door already learnt this
      // for the camera ("Camera access is off — click here to turn it on"); the
      // call surface had no way to say it at all. The gesture is added once and
      // its target is swapped, never accumulated -- a recogniser added on every
      // render is a pill that fires the handler five times.
      let actionable = !self.troubleLocal.isEmpty && self.onTroubleClick != nil
      self.warnPill.toolTip = actionable ? "Opens System Settings" : nil
      self.warnPill.onClick = actionable ? { [weak self] in self?.troubleClicked() } : nil
      // ── AND IT SAYS WHAT IT IS ──────────────────────────────────────────────
      //
      // VoiceOver reads the sentence either way; without a role it reads it as
      // static text, so the one thing a person needs to know -- that this is the
      // fix and it can be pressed -- is the part that does not get said.
      self.warnPill.setAccessibilityRole(actionable ? .button : .staticText)
      self.warnPill.setAccessibilityLabel(
        actionable ? line + ", opens System Settings" : line)
      guard !line.isEmpty else { return }
      // Re-centre: the pill resizes itself to the sentence, so the origin set at
      // layout time belongs to whatever text was there before.
      self.warnPill.setFrameOrigin(
        NSPoint(x: (self.frame.width - self.warnPill.frame.width) / 2,
                y: self.frame.height - self.warnPill.frame.height - Metric.s4))
      // A warning is worthless under a hidden bar. Showing the row also makes the
      // mic and camera buttons reachable at the exact moment somebody wants them.
      self.showBar()
    }
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
    // ── THE RECEIVING HALF OF THE SUBTITLE STOPWATCH ─────────────────────────
    //
    // Absolute epoch, matching `cue in`/`cue out` in main.swift, because the two
    // ends of a subtitle are two processes and a per-process clock cannot be
    // subtracted from another one. Stamped HERE rather than at the socket: the
    // question "how long from a word being recognised to it being on the far
    // screen" is about the screen, and everything between the socket and this
    // line -- the decode, the hop onto main -- is inside the answer.
    if !text.isEmpty, ProcessInfo.processInfo.environment["KIN_CUE_DEBUG"] != nil {
      fputs(String(format: "sub in  %.3f  \"%@\"%@\n", Date().timeIntervalSince1970,
                   text, final ? " ." : " …"), stderr)
    }
    onMain { [weak self] in self?.cues.setTheirs(text, final: final) }
  }

  /// A listening noise, as the word it was.
  func setListeningNoise(_ word: String) {
    onMain { [weak self] in self?.cues.setListeningNoise(word) }
  }

  /// 0 quiet, 1 listening, 2 bidding for the floor -- plus how much the ledger
  /// says this person is owed.
  func setFloor(peerVocal: Int, nudge: Double) {
    onMain { [weak self] in
      self?.cues.setFloor(peerVocal: peerVocal, nudge: nudge)
      // ── AND THIS IS WHAT WAKES THE MICROPHONE BUTTON ───────────────────────
      //
      // Fired from the receive thread the instant the far end's status byte
      // changes, which is one hop after they open their mouth. It is also, and
      // this is the part that makes the whole arrangement stop when a call is
      // quiet, the ONLY thing that can start a hold: this end's microphone is
      // held either because the far end claimed the floor (this bit, exactly)
      // or because their audio is coming out of the speaker (which requires
      // them to be making a sound, which is the same bit).
      //
      // So a poll is not needed to find out that a hold has begun. One is
      // needed to watch it end, and `floorTick` stops itself when it has.
      self?.wakeFloor()
    }
  }

  // ── WHOSE TURN IT IS, SAID BY THE CONTROL RATHER THAN BY THE PICTURE ───────
  //
  // The three states a person needs, and the words they would use for them:
  //
  //   through   my voice is going out
  //   bidding   I have started talking and am about to be heard
  //   held      the other person has the floor and I am not getting through
  //
  // MUTED IS ITS OWN CASE, and it draws at FULL ink. It is already unmistakable
  // -- red glyph, slash -- and it is the person's own decision, so dimming it as
  // well would be saying the same thing twice in two vocabularies. It is a case
  // rather than a flag beside the enum because the green edge below has to tell
  // it apart from `through`, and two booleans answering one question is how this
  // file has been bitten before.
  enum MicFloor: String {
    case through, bidding, held, muted
    /// What the glyph draws at. `held` is 0.34 rather than something fainter
    /// because the ink has to stay clearly PRESENT: the reading is "this one is
    /// quieter than its neighbours", never "this one is missing".
    var reach: CGFloat {
      switch self {
      case .through, .muted: return 1.00
      case .bidding:         return 0.66
      case .held:            return 0.34
      }
    }
  }
  private(set) var micFloor = MicFloor.through
  /// Eased, so `held -> bidding -> through` is one movement and not two jumps.
  private var micReach: CGFloat = 1
  private var floorTimer: Timer?
  private var floorLastTick = CACurrentMediaTime()
  private var floorSettled = 0
  /// ── PINNED, FOR A PHOTOGRAPH ───────────────────────────────────────────────
  ///
  /// `--press floor-held` and friends set this, and `tools/floor-check.sh` uses
  /// it to photograph a known state -- the same trick `TK_CAPTION_SCALE` plays
  /// with the caption's lifetime. Nothing in the app sets it, and the rig's LIVE
  /// arm leaves it nil precisely so that the gate reaching the same place is
  /// proved rather than assumed. A rig that only ever drove the override would be
  /// testing its own override.
  var floorPin: MicFloor?

  // ── THE GREEN EDGE ─────────────────────────────────────────────────────────
  //
  // Asked for in these words: "we will need a green edge border or something
  // like that, very thin, which when you are actually audible is visible, so that
  // you know for sure that you are audible -- that's the visual confirmation that
  // you're allowed to speak and you can speak. And people interrupt when the
  // green thing is not visible, but when they actually say something it becomes
  // visible, and then they can go say it."
  //
  // ── AND WHY THIS IS NOT THE THING THAT WAS REFUSED ────────────────────────
  //
  // The rim deleted in the commit before this one was three points wide with an
  // eighteen-point glow, BREATHING at 0.55 Hz, and it reported the FAR end taking
  // the floor. This is one and a half points, steady, no shadow, no gradient, no
  // pulse, and it reports THIS end actually reaching the other person. One is
  // decoration applied to the picture; the other is a state indicator, and the
  // difference is not the width -- it is that this one only ever says a fact
  // about the person looking at it, and says it without moving.
  //
  // If a glow, a pulse, a gradient or a breath ever gets added to this layer it
  // has become the other thing. There is a photographed assertion in
  // `tools/floor-check.sh` that the edge does not change when the FAR end takes
  // the floor, which is exactly the old bug wearing a new colour.
  //
  // A layer and not a `draw(_:)`, for the reason the old one gave and got right:
  // the alternative is invalidating a 1280x720 view thirty times a second to
  // repaint two hundred pixels of stroke.
  private let edge = CAShapeLayer()
  /// 0...1, eased. Not a bool, because a gate transition every few hundred
  /// milliseconds would otherwise strobe the whole window edge.
  private var edgeOn: CGFloat = 0
  /// 1 green (this end speaking), 0 blue (listening). Eased, so a handover is a
  /// colour moving rather than a colour cutting.
  private var edgeHue: CGFloat = 0
  /// 0...1 phase of the six-second drift. Not wall-clock, so it cannot jump when
  /// the timer sleeps and wakes.
  private var breath: CGFloat = 0
  /// The felt channel: current stroke width and the width its path was last
  /// cut for. See the width note in `floorTick`.
  private var edgeWidthNow: CGFloat = CallControls.edgeWidth
  private var edgePathWidth: CGFloat = CallControls.edgeWidth

  /// Blue at 0, green at 1, in sRGB. Both are already in the palette: `ok` is
  /// what this app means by "clear" and `accent` is its calm blue, so the edge
  /// borrows the two words the rest of the interface already uses rather than
  /// inventing a third.
  static func edgeTint(_ t: CGFloat) -> NSColor {
    let a = Palette.accent, b = Palette.ok
    let k = max(0, min(1, t))
    return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * k,
                   green: a.greenComponent + (b.greenComponent - a.greenComponent) * k,
                   blue: a.blueComponent + (b.blueComponent - a.blueComponent) * k,
                   alpha: 1)
  }
  /// Very thin, and 1.5 rather than 1 so it is three whole pixels on a 2x screen
  /// rather than two -- a 1 pt stroke inset by 0.5 lands on a half-pixel boundary
  /// and comes out as two grey rows instead of one green one.
  static let edgeWidth: CGFloat = 1.5

  /// What the gate is actually doing to this end's voice, right now: the word the
  /// microphone glyph draws with, and whether this person is genuinely reaching
  /// the far end.
  ///
  /// ONE FUNCTION RETURNING BOTH, from a single read of the gate. They are two
  /// renderings of one fact and they must never be able to disagree -- the glyph
  /// saying `through` while the edge is dark would be the app contradicting
  /// itself about the only thing either of them is for.
  ///
  /// Read straight off `Audio.sharedGate` rather than pushed in from the audio
  /// thread. Two reasons, and the second is the real one: a push would need a new
  /// fast path from the audio callback into AppKit for a value that only a
  /// display consumes, and this thing is a DISPLAY -- it should sample at the
  /// display's rate and nothing else's. `gain` and `yieldGainNow` are aligned
  /// 32-bit floats written by the capture thread; the subtitle thread in
  /// main.swift already reads exactly this pair the same way, and a display that
  /// reads a stale float for one frame at 30 Hz is not a defect anybody can see.
  private func floorNow() -> (MicFloor, Bool) {
    // ── MUTED OUTRANKS THE TEST PIN, AND THAT ORDER IS LOAD-BEARING ─────────
    //
    // The pin was first and the rig caught it: `floor-held` then a real click on
    // the microphone reported `micfloor=held/0.89` -- muted, and still claiming
    // a floor state, with the glyph easing back DOWN toward held while the slash
    // said otherwise. Two writers disagreeing about one value, because
    // `toggleMic` sets `.muted` directly and the next tick put the pin back.
    //
    // A pin exists to hold a DRAWING still for a photograph. It must never
    // outrank something the person actually did, and it must never be able to
    // photograph a state the product cannot be in -- a muted microphone that is
    // audible does not exist, and a rig able to depict one is a rig that can
    // certify a lie.
    if micMuted { return (.muted, false) }
    if let p = floorPin { return (p, p == .through) }
    // NOBODY TO REACH. Before the other person arrives there is no such thing as
    // being audible to them, so the edge stays dark rather than promising a
    // through-line to an empty room.
    guard startedAt != nil else { return (.through, false) }
    let g = Audio.sharedGate
    // ── AND IT HAS TO INCLUDE THE FLOOR ──────────────────────────────────────
    //
    // `gain * yieldGainNow` was the whole product of what the gate does to a
    // microphone until the turn layer added a third factor. Left alone, the edge
    // would light green while the floor held this end silent -- the app
    // contradicting itself about the only thing this indicator is for.
    // `appliedGainNow` is that product, computed once inside the gate, so a
    // fourth factor can never be forgotten here again.
    if g.appliedGainNow > 0.5 { return (.through, true) }
    return (g.vocal == .claim ? .bidding : .held, false)
  }

  /// Concentric with the window's own corner and inset by half the stroke, so the
  /// line lands INSIDE the window rather than straddling an edge the compositor
  /// is about to round away.
  private func layoutEdge() {
    // At the CURRENT width, not the resting constant -- a resize mid-sentence
    // would otherwise snap a wide speaking stroke onto a hairline's path and
    // clip its outer half until the next tick re-cut it.
    let ins = edgeWidthNow / 2
    edgePathWidth = edgeWidthNow
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    edge.frame = bounds
    edge.path = CGPath(roundedRect: bounds.insetBy(dx: ins, dy: ins),
                       cornerWidth: max(0, Metric.windowRadius - ins),
                       cornerHeight: max(0, Metric.windowRadius - ins), transform: nil)
    CATransaction.commit()
  }

  private func wakeFloor() {
    guard floorTimer == nil else { floorSettled = 0; return }
    floorLastTick = CACurrentMediaTime()
    floorSettled = 0
    let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.floorTick() }
    // `.common`, or it stops dead while a menu is open or the window is being
    // dragged -- two of the moments somebody is most likely to be mid-sentence.
    RunLoop.main.add(t, forMode: .common)
    floorTimer = t
    floorTick()
  }

  private func floorTick() {
    let now = CACurrentMediaTime()
    let dt = CGFloat(min(0.1, max(0.001, now - floorLastTick)))
    floorLastTick = now
    let (want, audible) = floorNow()
    // ── A RECORD, NOT FIVE SNAPSHOTS ─────────────────────────────────────────
    //
    // Printed on the CHANGE. A rig that samples this through the audit line sees
    // whatever instant its press happened to land on, and a state that is true
    // 60% of a call can be missed by five samples -- a birth certificate rather
    // than a health record, which has cost this project a whole false root cause
    // before. Every transition, in order, with the gate's own numbers beside it
    // so a disagreement between what the gate did and what the button drew is
    // visible in one line rather than inferred from two.
    if want != micFloor, ProcessInfo.processInfo.environment["KIN_CUE_DEBUG"] != nil {
      let g = Audio.sharedGate
      fputs(String(format: "mic floor %.3f  %@ -> %@  edge %@  (gain %.2f x yield %.2f, vocal %d%@)\n",
                   Date().timeIntervalSince1970, micFloor.rawValue, want.rawValue,
                   audible ? "on" : "off",
                   g.gain, g.yieldGainNow, g.vocal.rawValue,
                   floorPin != nil ? ", PINNED" : ""), stderr)
    }
    micFloor = want
    // ── UP FAST, DOWN SLOW, AND THE ASYMMETRY IS THE FILTER ──────────────────
    //
    // Getting the floor back is news and is said immediately: 60 ms is two
    // frames. Losing it is said over 300 ms, and that slow fall is not decoration
    // -- it is what stops a 100 ms duck (the echo gate ticking down around a
    // syllable of theirs) from flashing the button dark. An exponential with tau
    // 0.3 moves less than a third of the way in 100 ms, so a real hold shows and
    // a flicker does not, with no extra state and no dead time.
    let target = want.reach
    micReach += (target - micReach) * min(1, dt / (target > micReach ? 0.06 : 0.30))
    if abs(target - micReach) < 0.004 { micReach = target }
    micButton.reach = micReach

    // ── THE EDGE, ON THE SAME CLOCK AND THE SAME CONSTANTS ───────────────────
    //
    // 60 ms on, 300 ms off, identical to the glyph beside it: they are two
    // renderings of one fact, so easing them differently would let a person watch
    // them disagree. Quick on because the whole promise is "you are through now,
    // go ahead" and a person mid-interruption is waiting for exactly that;
    // slower off because a gate that ticks shut around one syllable of theirs
    // must not strobe the window.
    // ── GREEN IS SPEAKING. BLUE IS LISTENING. ────────────────────────────────
    //
    // The bug this replaces: the edge lit whenever this microphone was OPEN, and
    // with nobody talking both microphones are open -- so both people sat looking
    // at a green window, which says "you are being heard" to two people at once
    // when at most one of them is saying anything. Reported in exactly those
    // words: "I see the green thing glowing on both sides, which should not be
    // the case."
    //
    // Open is not the same as speaking. So the edge now reports which of the two
    // of you has the floor, and it can only ever be one:
    //
    //   green  this end is making sound AND it is reaching them
    //   blue   the other person has it -- you are listening
    //   dark   neither, which is most of a call and should look like nothing
    //
    // Blue is not a warning and must not read as one: it is the colour of the
    // room being someone else's for a moment.
    // A pin exists to hold a DRAWING still for a photograph, so it has to be able
    // to produce every drawing -- otherwise the rig can only photograph the
    // states that happen to need no audio, which is the dark one. `.through`
    // pinned means "this end has the floor and is using it", which is the green
    // the pin was added to capture.
    let speaking: Bool
    let listening: Bool
    if let p = floorPin {
      speaking = p == .through
      listening = false
    } else {
      speaking = audible && Audio.sharedGate.vocal != .quiet
      listening = !speaking && Audio.peerVoiceNow != .quiet
    }
    let eTarget: CGFloat = (speaking || listening) ? 1 : 0
    edgeOn += (eTarget - edgeOn) * min(1, dt / (eTarget > edgeOn ? 0.06 : 0.30))
    if abs(eTarget - edgeOn) < 0.004 { edgeOn = eTarget }
    // 1 is green, 0 is blue. Eased at the same rate in both directions, because
    // neither of these is news the other one outranks -- a hard cut between two
    // saturated colours at a handover is the opposite of soothing.
    let hTarget: CGFloat = speaking ? 1 : (listening ? 0 : edgeHue)
    edgeHue += (hTarget - edgeHue) * min(1, dt / 0.22)

    // ── THE BREATH, WHICH WAS REFUSED ONCE AND IS NOW ASKED FOR ──────────────
    //
    // The note on `edge` forbids a pulse, and it was right for what it was
    // describing: a three-point rim with an eighteen-point glow breathing at
    // 0.55 Hz over the picture. That was refused as an EFFECT. The refusal
    // still stands for glow, shadow and gradient -- nothing bleeds over the
    // picture, ever.
    //
    // WIDTH stopped being on that list on 2026-08-31, by the user, in their
    // words: the hairline was "really hard to spot, and you have to constantly
    // look at them... you should FEEL, yes, your voice is going through...
    // maybe a thicker bar." So width is now the felt channel, the one
    // peripheral vision actually has: speaking, the stroke is wide and moves
    // with your own syllables (`nearLoudNow`, the loudness the gate already
    // publishes for displays); listening, a calm three points; nobody's, the
    // original hairline. Attack fast (your first syllable is the news), decay
    // slow (a breath between words must not flutter the frame).
    breath += dt / 6.0
    if breath > 1 { breath -= 1 }
    let sway = 1 - 0.10 * (1 - cos(2 * .pi * breath)) / 2

    let wTarget: CGFloat
    if speaking {
      wTarget = 4.5 + 3.5 * CGFloat(min(1, max(0, Audio.sharedGate.nearLoudNow)))
    } else if listening {
      wTarget = 3
    } else {
      wTarget = CallControls.edgeWidth
    }
    edgeWidthNow += (wTarget - edgeWidthNow) * min(1, dt / (wTarget > edgeWidthNow ? 0.05 : 0.20))

    CATransaction.begin()
    CATransaction.setDisableActions(true)   // or every frame animates over 0.25 s
    edge.opacity = Float(edgeOn * sway)
    edge.strokeColor = CallControls.edgeTint(edgeHue).cgColor
    // The stroke is centered on its path, so a wider line must sit on a path
    // inset by half its own width or the compositor clips its outer half at
    // the rounded corner. Re-cut only on a visible change; a 30 Hz CGPath for
    // a stroke that is not moving is work nobody can see.
    if abs(edgeWidthNow - edgePathWidth) > 0.25 {
      edgePathWidth = edgeWidthNow
      let ins = edgeWidthNow / 2
      edge.path = CGPath(roundedRect: bounds.insetBy(dx: ins, dy: ins),
                         cornerWidth: max(0, Metric.windowRadius - ins),
                         cornerHeight: max(0, Metric.windowRadius - ins), transform: nil)
    }
    edge.lineWidth = edgeWidthNow
    CATransaction.commit()

    // Stop when there is nothing to watch: fully through, settled, and a second
    // of that. It cannot miss the START of a hold -- see `setFloor` above for why
    // there is exactly one thing that can begin one and why it wakes this.
    // ── AND IT MAY NOT SLEEP DURING A CALL ANY MORE ──────────────────────────
    //
    // It used to stop after a second of "through and settled", which was right
    // when the edge only ever reported a fact about THIS end: nothing but this
    // person's own microphone could change it, and `setFloor` woke it.
    //
    // Both halves of that are now false. The edge turns blue when the FAR end
    // speaks, and nothing local happens when they do -- so a sleeping timer would
    // simply never show blue, which is the larger half of the feature. And the
    // breath is a continuous animation: a timer that stops freezes it mid-drift.
    //
    // So during a call it runs, and between calls it sleeps as before. Thirty
    // ticks a second setting two properties on one shape layer is not a cost
    // worth a class of bug that presents as "the other person never lights up".
    let still = micReach >= 0.999 && abs(eTarget - edgeOn) < 0.004
    let inCall = startedAt != nil
    floorSettled = (!inCall && want == .through && still) ? floorSettled + 1 : 0
    if floorSettled > 30 {
      floorTimer?.invalidate(); floorTimer = nil
    }
  }

  /// The word for the audit line, plus where the ease has actually got to, so an
  /// assertion can be made about the DRAWING and not only about the decision.
  var micFloorState: String {
    "\(micFloor.rawValue)/\(String(format: "%.2f", micReach))"
  }
  /// The green edge, as the layer is actually drawing it. A separate field from
  /// `micfloor` on purpose: they answer two questions -- "how much of my voice is
  /// getting out" and "am I through, yes or no" -- and the whole point of the
  /// edge is the second one. A rig can assert this without a photograph; the
  /// photograph is what proves the layer agrees with it.
  var edgeState: String {
    // The width is part of the state now that it carries the message -- an
    // audit that reported only opacity could not tell a felt speaking edge
    // from the hairline it replaced.
    (edgeOn > 0.5 ? "on" : "off") + "/" + String(format: "%.2f", edgeOn)
      + "/w" + String(format: "%.1f", edgeWidthNow)
  }

  /// Flattens foreign text for the one-line state dump. See `clip=` in
  /// `describeTree` for what it cost to learn that this was needed.
  static func oneLine(_ raw: String?, cap: Int = 120) -> String {
    guard let raw, !raw.isEmpty else { return "-" }
    var out = ""
    for ch in raw {
      if ch == "\n" || ch == "\r" { out += "\u{23CE}" }        // ⏎
      else if ch == "\t" { out += " " }
      else { out.append(ch) }
      if out.count >= cap { return out + "\u{2026}" }
    }
    return out
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
    // Muting has to take the glyph back to full ink in the same breath, or a
    // microphone that was being HELD when you pressed it stays half-drawn in red
    // and reads as a mute that half worked. `floorNow` already answers `.muted`
    // here; this is what makes the drawing agree without waiting a frame.
    if micMuted { micReach = 1; micFloor = .muted; micButton.reach = 1 }
    wakeFloor()
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
    // Before the round trip, not after it. Signing and an HTTPS ring take long
    // enough to notice, and this is precisely the gap the person was staring into.
    // The successor process re-enters the same state from `--calling`, so the card
    // is continuous across the re-exec rather than blinking back to the link.
    waiting.setOutgoing(to: h)
    setStatus("calling \(Identity.display(h))…")
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
      self.setStatus("\(Identity.display(from)) is calling")
      self.nudgeBar()
    }
  }

  func hideIncoming() { onMain { [weak self] in self?.waiting.clearIncoming() } }

  /// This Mac is ringing somebody. The mirror of `showIncoming`, and the reason
  /// the caller no longer stares at an invite link wondering if it worked.
  /// `away` is the server's answer to "was anybody listening when we rang",
  /// carried across the re-exec by `--callee-away`. It is only ever true when
  /// the server said so outright -- it has a third answer, "no idea", and that
  /// one must never reach a person as "they are offline".
  func showOutgoing(to who: String, away: Bool = false) {
    onMain { [weak self] in
      guard let self, !self.sawPeer else { return }
      self.waiting.setOutgoing(to: who)
      // Still calling, and still worth calling: the ring is in their mailbox and
      // keeps for a minute, so a Mac that wakes up in time still rings. What
      // changes is that the person waiting is told why nothing is happening
      // instead of watching a ringing screen and drawing their own conclusion.
      self.setStatus(away ? "\(Identity.display(who)) isn\u{2019}t listening right now"
                          : "calling \(Identity.display(who))…")
      if away {
        self.showCallFailed("\(Identity.display(who)) isn\u{2019}t listening for calls",
                            because: "their Mac hasn\u{2019}t checked in \u{2014} it will ring if it wakes up soon")
      }
      self.nudgeBar()
    }
  }

  /// The ring could not be delivered at all. Said on the card, not only in the
  /// status pill: the pill is four words in a corner and the card is what the
  /// person is looking at.
  func showCallFailed(_ line: String, because why: String) {
    onMain { [weak self] in self?.waiting.setCallFailed(line, because: why) }
  }

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
      guard let self else { return }
      let moved = self.silent != on
      self.silent = on
      // Refresh even when nothing moved: the switch is drawn busy while the round
      // trip is out, and a request that comes back with the SAME answer still has
      // to put it back. Without this a refused change left the switch spinning for
      // the rest of the call.
      guard moved || self.silentBusy else { return }
      self.silentBusy = false
      self.refreshSheet()
    }
  }

  /// The server said no. The switch goes back to where it was and the reason
  /// lands under it, inside the panel somebody is looking at.
  func silentRefused(_ why: String) {
    onMain { [weak self] in
      guard let self else { return }
      self.silentBusy = false
      self.settingsNote = why
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

    // Tapping it does the whole job, or explains the one thing it cannot do. Three
  // outcomes and none of them is a dead end: turn it on, move Kin where it can be
  // turned on, or open the exact panel where macOS is refusing.
  @objc private func toggleWatchRow(_ sender: Any?) {
    Metrics.tap("watch_row")
    let w = Watch.reach()
    if w.on {
      Metrics.count("watch_turned_off")
      Thread {
        _ = Watch.uninstall()
        DispatchQueue.main.async { [weak self] in
          self?.setStatus("Kin will only ring while it\u{2019}s open")
          self?.refreshSheet()
        }
      }.start()
      return
    }
    switch w.fix {
    case .moveToApplications:
      Metrics.count("watch_fix_move")
      setStatus("moving Kin to Applications\u{2026}")
      // Relaunches from the new place and never returns. If it DOES return there
      // is nothing left to try automatically, and saying so beats a spinner.
      Install.relocateIfHomeless()
      setStatus("drag Kin into Applications and open it again")
    case .openLoginItems:
      Metrics.count("watch_fix_loginitems")
      // The exact panel, not the top of System Settings. macOS is the thing
      // saying no here, and this is where it says it.
      if let u = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
        NSWorkspace.shared.open(u)
      }
      setStatus("switch Kin on under Login Items")
    case .restart:
      // The one repair on this row that needs nothing from the person and no
      // panel in System Settings: the login item is already approved, it simply
      // is not running. Off the main thread because `launchctl` is a process.
      Metrics.count("watch_fix_restart")
      setStatus("turning it back on\u{2026}")
      Thread {
        let ok = Watch.restart()
        Metrics.count(ok ? "watch_restarted" : "watch_restart_fail")
        DispatchQueue.main.async { [weak self] in
          self?.setStatus(ok ? "Kin is listening for calls again"
                             : "couldn\u{2019}t turn it back on \u{2014} open Kin again")
          self?.refreshSheet()
        }
      }.start()
    case .install, .none:
      setStatus("setting up\u{2026}")
      Thread {
        let said = Watch.install()
        let ok = said.contains("installed")
        Metrics.count(ok ? "watch_turned_on" : "watch_turn_on_fail")
        fputs("watch: asked from the panel -- \(said)\n", stderr)
        DispatchQueue.main.async { [weak self] in
          self?.setStatus(ok ? "people can reach you even when Kin is closed"
                             : "couldn\u{2019}t set that up \u{2014} try Login Items in System Settings")
          self?.refreshSheet()
        }
      }.start()
    }
  }

@objc private func toggleSilentRow(_ sender: SheetRow) {
    Metrics.tap("silent")
    guard !silentBusy else { return }
    let want = !silent
    // Say what was asked for, not what is true yet. The switch itself only moves
    // when `setSilent` comes back, so a refusal leaves it where it was rather
    // than telling someone they are unreachable when they are not.
    setStatus(want ? "going silent…" : "turning silence off…")
    // ── AND THE PANEL STAYS OPEN ───────────────────────────────────────────
    //
    // `closeMore()` was here. Pressing the one switch in the app shut the panel
    // the switch lives in, so the result of the press was never visible: the
    // state it landed in, and the sentence explaining a refusal, both arrived on
    // a surface that had just been taken off screen. The status pill it wrote to
    // is in the top-left corner and this panel hangs on the right, so even that
    // was only readable because the panel had gone.
    //
    // A setting that reports its outcome somewhere you can only see by leaving is
    // a setting people press twice -- which for this one means two round trips
    // inside the server's rate limit, and the second is the one that gets refused.
    silentBusy = true
    settingsNote = ""
    refreshSheet()
    onSilent?(want)
  }

  /// Mid-flight, so the switch reads as busy rather than as the state it is
  /// leaving. Cleared by `setSilent` or `silentRefused`.
  private var silentBusy = false
  /// A sentence under the switch, for the case where the server said no. It is
  /// where somebody is already looking; the status pill is not.
  private var settingsNote = ""

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
  // ── AND THIS NUMBER IS THE WHOLE OF THE IMMERSIVE STATE ───────────────────
  //
  // Asked for in these words: "while the call is on ... all the controls should
  // fade away. Except subtitles only. And they should only come back when there
  // is a touch of a mouse or a keyboard or something like that. And they will
  // again fade away in two to three seconds. So it's truly immersive."
  //
  // Most of it was already here and doing the wrong half of the job: the row went
  // to zero opacity and stayed exactly as clickable as before. What was missing
  // was never the timer -- it was that a faded control is not a control
  // (`IconButton.hitTest`), that seven states must stop the fade outright
  // (`barHoldReason`), and that everything a person does counts as being there.
  //
  /// `Math.max(2600, barPinnedUntil - now)`.
  // A CADENCE, so it gets a rig override like `TK_RING_TIMEOUT` and
  // `TK_LEAVE_HOLD_MS`. A rig that has to sit out two and a half seconds of
  // stillness per assertion is a rig somebody shortens by deleting assertions.
  // Nothing in the app sets it; the shipped number is the default below.
  private static let barStillness: TimeInterval =
    (ProcessInfo.processInfo.environment["TK_IMMERSIVE_MS"].flatMap { Double($0) }
       .map { $0 / 1000 }) ?? 2.6
  /// `showBar(true)` pins for 10 s -- a state change earns the row that long.
  /// ── A MULTIPLE, NOT A SECOND CONSTANT ────────────────────────────────────
  ///
  /// Written as two independent numbers, `TK_IMMERSIVE_MS` shortens the fade and
  /// then leaves a rig sitting out a ten-second pin it never asked about -- a
  /// cadence with no override hiding inside a cadence that has one. 10 over 2.6 is
  /// the shipped pair, so the default here is the number that was always here.
  private static var barPin: TimeInterval { barStillness * (10.0 / 2.6) }
  private var barPinnedUntil = Date.distantPast

  /// `pin: true` for a state change (a mute, a camera swap): the row has just said
  /// something and taking it away in 2.6 s is taking away the confirmation.
  private func showBar(pin: Bool = false) {
    barTimer?.invalidate()
    setBar(visible: true)
    if pin { barPinnedUntil = max(barPinnedUntil, Date().addingTimeInterval(CallControls.barPin)) }
    scheduleBarHide()
  }

  // ── THE SEVEN STATES THE ROW IS NOT ALLOWED TO LEAVE IN ───────────────────
  //
  // A STRING and not a boolean, and that is not decoration. "The bar did not fade"
  // is the same observation for seven different reasons, and a rig that cannot
  // tell them apart proves whichever one happened to be true rather than the one
  // it was written for. `describeTree` prints this, so an assertion can name it.
  //
  // Every one of them makes the app unusable if the row goes:
  //
  //   notyet   nobody has connected. "Before the call the screen is your own
  //            mirror and one button, and hiding the controls there just makes
  //            the app look broken."
  //   card     the waiting, ringing or calling card is on screen. Its buttons --
  //            answer, decline, cancel, the invite link -- are the only way off
  //            that screen
  //   alone    connected once, nobody here NOW, and no card either
  //   panel    a decision in progress
  //   leaving  a hang-up half-confirmed, between the two clicks
  //   held     a finger is down on peek or on leave
  //   typing   the caret is in something
  //
  // ORDER IS THE ANSWER, not just the list. A departure makes `card` and `alone`
  // true together -- `setPeerPresent(false)` brings the card back -- and the card
  // is the one a person is looking at, so it is the one this reports. `alone`
  // stays underneath it for the case with no card: `markConnected` on its own,
  // which is a state the rig paths can reach and a real call passes through.
  private var barHoldReason: String? {
    if startedAt == nil { return "notyet" }
    if !waiting.isHidden { return "card" }
    if !peerPresent { return "alone" }
    // ── WAITING FOR SOMEBODY TO COME BACK ──────────────────────────────────
    //
    // A held call passes through none of the three above: it has started, no
    // card is up, and `peerPresent` stays TRUE on purpose so that nothing tears
    // down while the person is only away. So the row faded on its stillness
    // timer and stayed faded -- the picture frozen on their last frame, "they'll
    // be right back" in a pill, and no hang-up button anywhere until the person
    // moved the mouse to find out whether the app was still alive. The one
    // moment they most need a way out was the one moment the way out was
    // invisible.
    if barHolding { return "waiting" }
    if moreOpen { return "panel" }
    if leaveArmed { return "leaving" }
    if peekButton.holding || leaveButton.holding { return "held" }
    if typing { return "typing" }
    return nil
  }

  /// Whether the caret is in something. Asked of the WINDOW rather than of the two
  /// fields this app owns, because focus is AppKit's fact and not this file's:
  /// while a field is being typed into the first responder is its field EDITOR, a
  /// text view neither field holds a reference to. Asking the window is also the
  /// only version of this that stays true for a field added later.
  ///
  /// A BACKSTOP, and today it can never be the reason on its own: both fields
  /// this app has live inside something that already holds the row up -- the
  /// rename field is in the panel, the name field is on the card -- so `typing`
  /// is always shadowed and `immersive-check` cannot assert it in isolation. It
  /// is here for the third field, which is the one that would otherwise ship with
  /// the words disappearing out from under a half-typed name.
  private var typing: Bool {
    guard let r = window?.firstResponder else { return false }
    return r is NSTextView || r is NSTextField
  }

  /// The last thing `setPeerPresent` was told. See the note there for why this is
  /// not `sawPeer`.
  private(set) var peerPresent = false

  private func scheduleBarHide() {
    barTimer?.invalidate()
    // ── NOT BEFORE THE CALL ───────────────────────────────────────────────────
    //
    // `if (!joined) return;` -- "Before the call the screen is your own mirror and
    // one button, and hiding the controls there just makes the app look broken."
    // This app hid them anyway, so the waiting screen sat there with a link and no
    // visible way to mute, turn the camera off, or leave.
    //
    // The ONE reason that stops the timer rather than retrying it: nothing on a
    // screen with no call on it can turn into a reason to fade, and `markConnected`
    // is what arms this. Every other reason below clears on its own.
    guard startedAt != nil else { return }
    // Whichever ends later: 2.6 s of stillness, or the pin. Sizing the timer to the
    // ACTUAL remaining time is the difference between the row disappearing where the
    // rule says and up to one tick later.
    let wait = max(CallControls.barStillness, barPinnedUntil.timeIntervalSinceNow)
    barTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
      guard let self else { return }
      // ASKED AT THE MOMENT OF FIRING, not at the moment of arming. Every reason
      // above can become true during the wait -- a panel opened, the other person
      // left, a finger went down -- and a fade decided 2.6 s ago is a fade decided
      // about a different screen. This was two of the seven, checked here, and it
      // is why the list lives in one property both this and the readout share.
      if let why = self.barHoldReason {
        // A RETRY, not a cancellation. The reason will clear -- a panel closes, a
        // finger lifts, somebody stops typing -- and nothing else would restart
        // this, so the row would simply stay up for the rest of the call.
        if why != self.heldSaid { self.heldSaid = why; fputs("bar: staying up -- \(why)\n", stderr) }
        self.scheduleBarHide(); return
      }
      self.heldSaid = nil
      self.setBar(visible: false)
    }
  }
  /// So a reason that holds for a whole call says so once instead of every 2.6 s.
  private var heldSaid: String?

  /// Supersedes an in-flight fade. See `setBar`.
  private var barFade: UInt32 = 0

  private func setBar(visible: Bool) {
    // ── AND IT RUNS ON MAIN, BECAUSE IT NOW TOUCHES `isHidden` ────────────────
    //
    // For as long as this was only `animator().alphaValue`, an off-main call got
    // away with it. Hiding a view does not: `-[NSView _setHidden:]` posts a window
    // notification, and off the main thread that is an ObjC exception and a
    // SIGABRT. It was one, immediately -- `setHolding` is called from the report
    // thread, and `leave-check` died with `Abort trap: 6` in
    // `_postWindowNeedsToResetDragMargins`.
    //
    // The guard is INSIDE the hop, not outside it: read from another thread,
    // `barShown` is a race, and two hops that both decided "it changed" would run
    // two fades. See `unexplained-death-is-a-bug` -- this file's rule is that no
    // AppKit object is touched from a thread that is not the main one, and "it has
    // not crashed yet" is not the test.
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.setBar(visible: visible) }
      return
    }
    guard visible != barShown else { return }
    barShown = visible
    let row: [NSView] = [micButton, camButton, peekButton, flipButton, leaveButton, moreButton]
    // ── WHAT IS NOT IN THAT LIST ──────────────────────────────────────────────
    //
    // The caption band, the floor cue and the bloom -- `cues`, the whole turn
    // layer. "Except subtitles only": the words the other person is saying are the
    // one thing on this screen that is not furniture, and taking them away with
    // the buttons would make the immersive state the state in which you can no
    // longer read what somebody said. They are also below the row already and pass
    // every click through, so there is nothing to hide them FROM.
    //
    // Nor the pills. A warning is a sentence about the call rather than something
    // to press, and `setWarning` deliberately brings the row back when one arrives.
    //
    // ── AND IT IS NOT ONLY OPACITY ────────────────────────────────────────────
    //
    // For as long as this was the whole of the fade, the row was invisible and
    // fully armed. `IconButton.hitTest` refuses a click on a circle below 0.01
    // alpha, which is the value this line sets, so the drawing and the hit testing
    // cannot disagree about what is on screen. `clickTargets` reads the same alpha
    // for the same reason.
    //
    // ── BACK FASTER THAN IT WENT ──────────────────────────────────────────────
    //
    // Going away is the app's decision and it should be gentle. Coming back is the
    // PERSON's, made with a hand that is already moving, and any part of it they
    // can perceive as a wait is the app arguing with them. One curve either way --
    // half the time on the way in. Reduce Motion gets neither, the same answer
    // `setRowMerge` gives.
    // ── THE FADE HAS TO BE APPLIED TO THE GROUP, NOT TO THE CIRCLES ──────────
    //
    // For every release that had a `GlassGroup` under the row, this line did
    // nothing at all on screen and everything to the hit testing, which is the
    // worst possible half of a fade.
    //
    // `NSGlassEffectContainerView` composites the material for every glass view
    // inside it in ONE pass of its own, and a child's `alphaValue` is not an input
    // to that pass -- the container draws the union of its children's shapes
    // whatever opacity the child views are carrying. The glyphs went with it,
    // because on macOS 26 the glyph is the glass's `contentView` and therefore
    // inside the same pass. So the row stayed fully drawn: four circles and a red
    // hang-up, at rest, over the picture.
    //
    // `IconButton.hitTest` reads that same alpha and refuses below 0.01. Measured
    // over a bright picture, 2.6 s after the last movement: mic at pixel min 136,
    // leave at 131 -- fully painted -- and both dead to the first click. The one
    // button not in the group, `more`, faded correctly, which is what made this
    // look like a drawing quirk rather than what it is.
    //
    // So the fade goes on the GROUP, which is an ordinary view outside the effect,
    // and the group is HIDDEN outright when the fade lands. `isHidden` is the only
    // state where drawing and hit testing cannot disagree: a hidden view is not
    // reached by `hitTest` at all, so there is no second reader of a number to keep
    // in step with the first.
    let dur = Motion.reduceMotion ? 0 : (visible ? 0.12 : 0.24)
    if visible { barGroup.isHidden = false; moreButton.isHidden = false }
    // The name and the clock are chrome: they go with the row rather than staying
    // on somebody's face after the app has decided the call is the whole window.
    whoPill.isHidden = !visible || whoPill.text.isEmpty
    barFade &+= 1
    let token = barFade
    Motion.run({
      barGroup.animator().alphaValue = visible ? 1 : 0
      moreButton.animator().alphaValue = visible ? 1 : 0
    }, duration: dur)
    if !visible {
      // Not in the completion handler: `Motion.run`'s handler fires for whichever
      // group finishes, and a show that starts mid-fade would otherwise be hidden
      // by the fade it interrupted. The token is what makes a superseded fade
      // harmless.
      DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.02) { [weak self] in
        guard let self, self.barFade == token, !self.barShown else { return }
        self.barGroup.isHidden = true
        self.moreButton.isHidden = true
      }
    }
    // Said out loud: a row at zero opacity and a row that was never built
    // photograph identically, and this is the app's own account of the moment it
    // took the controls off somebody's screen.
    fputs("bar: \(visible ? "back" : "faded away -- the call is the whole window")\n", stderr)
  }
  override func mouseMoved(with event: NSEvent) { showBar() }
  override func mouseEntered(with event: NSEvent) { showBar() }
  // ── A SCROLL IS A PERSON ──────────────────────────────────────────────────
  //
  // Nothing in this window scrolls, which is exactly why this is here rather than
  // absent: two fingers on a trackpad is somebody at this Mac, the rule is "a
  // touch of a mouse or a keyboard or something like that", and a gesture the app
  // has no other use for costs nothing at all to accept as presence.
  override func scrollWheel(with event: NSEvent) {
    // A scroll over an overflowing settings panel moves the list; anywhere else
    // it is a person moving, which is what wakes the control row.
    if moreOpen, sheet.scrolls,
       sheet.frame.contains(convert(event.locationInWindow, from: nil)) {
      sheet.scrollBy(event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
      layoutSubtreeIfNeeded()
      return
    }
    showBar()
  }
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

  // ── THE ONE QUESTION `@mic` CANNOT ASK ────────────────────────────────────
  //
  // Every `--press` token calls `nudgeBar()` before it runs, and that is right: a
  // press models somebody who has just moved a pointer onto a button. It also
  // means no `@` click can ever land on a FADED control, which is the only thing
  // about a faded control worth proving.
  //
  // So this is one experiment with two arms, and they share every line of it: the
  // same real click at the mute circle's own centre, built the same way, delivered
  // through the window and therefore through every `hitTest` on the way down,
  // differing only in what the row is doing when it arrives. `faded: true` must
  // change nothing and bring the row back; `faded: false` must mute. An arm that
  // ranks the same way as the other one proves the click never reached anything.
  //
  // It cannot go through `click(_:)` next door, and the reason is the point:
  // `click` can only reach what `clickTargets` lists, `clickTargets` is documented
  // as what is on screen RIGHT NOW, and the moment the row fades it correctly
  // stops being able to name the mute button at all.
  private func tapWhereTheMicIs(faded: Bool) {
    // NO `NSApp.activate` HERE, unlike `click`. This press has to be able to
    // arrive at a window that is not key -- that is half of what it is testing,
    // and it is the state a real call spends most of its time in. It is also the
    // press that found `CallControls.acceptsFirstMouse` missing, which activating
    // first would have hidden completely.
    guard let win = window else { fputs("bar-tap: no window\n", stderr); return }
    // `setBar` is what the stillness timer calls, so the row is left in exactly
    // the state two and a half still seconds would have left it in -- and the
    // timer is stopped, or it fires mid-assertion and the arms swap.
    if faded { setBar(visible: false); barTimer?.invalidate() } else { showBar() }
    let p = micButton.convert(NSPoint(x: micButton.bounds.midX, y: micButton.bounds.midY),
                              to: nil)
    let wasShown = barShown
    let before = micMuted
    let hit = win.contentView?.hitTest(p)
    func ev(_ t: NSEvent.EventType) -> NSEvent? {
      NSEvent.mouseEvent(with: t, location: p, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: win.windowNumber, context: nil,
                         eventNumber: 0, clickCount: 1,
                         pressure: t == .leftMouseUp ? 0 : 1)
    }
    guard let down = ev(.leftMouseDown), let up = ev(.leftMouseUp) else { return }
    // The release goes into the queue FIRST when an `NSControl` is under the point.
    // Every button here runs its own tracking loop inside `mouseDown` and pulls the
    // release out of the queue itself, so a press with nothing behind it hangs the
    // main thread waiting for a finger that does not exist -- see `click`, which
    // paid for this once already. A plain view takes the release by hand.
    let tracks = hit is NSControl
    if tracks { win.postEvent(up, atStart: false) }
    win.sendEvent(down)
    if !tracks { win.sendEvent(up) }
    fputs("bar-tap: the row was \(wasShown ? "SHOWN" : "HIDDEN") when the click landed"
        + " -- hit=\(hit.map { "\(type(of: $0))" } ?? "nil")"
        + " mic \(before ? "muted" : "on")->\(micMuted ? "muted" : "on")"
        + " row now \(barShown ? "shown" : "hidden")\n", stderr)
  }

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
    // A new page starts at its top. `setItems` only CLAMPS the offset, because a
    // refresh -- a camera appearing, an update check finishing -- must not yank
    // the list out from under somebody's eyes; an explicit page change is the
    // opposite, and arriving half way down a list nobody has scrolled is wrong.
    sheet.scrollOffset = 0
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
    if moreOpen { sheetPage = .settings; sheet.scrollOffset = 0; rebuildSheet() }
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
  // ── THE OVERLAY HAS TO ACCEPT THE FIRST CLICK TOO ─────────────────────────
  //
  // Every control in this file says yes to this and the surface they sit on said
  // nothing, which was harmless while the surface did nothing. It is not harmless
  // now: the click that wakes a faded row lands HERE, and without this it is spent
  // activating Kin and thrown away -- the row stays invisible and the person
  // clicks again into a window with no controls on it.
  //
  // Measured on the harness before it was added, and this is exactly the shape:
  //
  //     bar-tap: the row was HIDDEN when the click landed -- hit=CallControls
  //              mic on->on row now hidden
  //
  // The hit test named this view, the press never arrived, and the fade looked
  // like a bar that could not be woken. `mouseDown` below is not consequential --
  // it shows the row and closes an open panel, which are the two things somebody
  // bringing this window forward is most likely to have meant.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// A click on the scrim -- anywhere outside the panel -- closes it.
  override func mouseDown(with event: NSEvent) {
    // ── AND A CLICK ON A FADED ROW BRINGS IT BACK RATHER THAN PRESSING ───────
    //
    // This is where a click that found nothing arrives. The circles refuse the hit
    // while they are invisible (`IconButton.hitTest`), the turn layer passes
    // everything through, and the hidden card and scrim are not in the search at
    // all -- so a finger aimed at where the mute button used to be lands here.
    // Showing the row is the whole of the right answer: the person now sees what
    // they were reaching for and can press it, instead of having pressed something
    // they could not see. FIRST in this method, because the scrim path below
    // returns and a person closing a panel is still a person.
    showBar()
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
  func rebuildSheet() {
    switch sheetPage {
    case .settings: buildSettingsPage()
    case .people: buildPeoplePage()
    case .rename: buildRenamePage()
    case .camera, .microphone, .speaker: buildDevicePage(sheetPage)
    }
    needsLayout = true
    layoutSubtreeIfNeeded()
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
    // ── AND LAY IT OUT, IN THE SAME TURN ──────────────────────────────────────
    //
    // `showPage` has done this since the day a page swap photographed the old
    // page's height with the new page's rows in it. This did not, and the
    // consequence is worse than a wrong height: `setItems` replaces every row with
    // a NEW view at its init frame, so until a layout pass runs they are all
    // stacked at (0,0,400,48). Every one of them hit-tests to whatever is actually
    // at that point.
    //
    // It became reachable the moment anything refreshed the panel on a timer. The
    // device names are re-read once a second so the rows track the graph rather
    // than the last thing pressed, and the audit caught the result: eighteen rows
    // reporting the same coordinate and resolving to a `SheetHint`. A panel full of
    // settings that cannot be clicked, from a refresh whose whole job was to keep
    // them honest.
    //
    // One place rebuilds and one place lays out, so a route that forgets cannot
    // exist.
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  private func buildSettingsPage() {
    var rows: [SheetRow] = []
    // ── THE HARDWARE, AS THREE DOORS ──────────────────────────────────────────
    //
    // The camera was here as a flat ticked list and the microphone was not here at
    // all -- it was whatever System Settings said, decided once when the call
    // started, never named on screen. "They can't hear me" meant leaving the app.
    //
    // A row per piece of hardware, each showing what is in use and opening its own
    // page. The camera row is hidden when there is exactly one camera, the way the
    // flip button already is: a choice between one thing is not a choice. The
    // microphone and speaker rows are always here, because even with one of each
    // the row answers "which one is it" -- and the name it prints is read off the
    // live audio graph rather than off what was asked for.
    if camNames.count > 1 {
      let c = SheetRow("Camera", glyph: Glyph.cam)
      c.value = camNames.indices.contains(camPicker.indexOfSelectedItem)
        ? camNames[camPicker.indexOfSelectedItem] : ""
      c.valueIsWord = true
      c.chevron = true
      c.target = self; c.action = #selector(cameraPageRow(_:))
      rows.append(c)
    }
    let m = SheetRow("Microphone", glyph: Glyph.mic)
    m.value = micName.isEmpty ? "…" : micName
    m.valueIsWord = true
    m.chevron = true
    m.target = self; m.action = #selector(micPageRow(_:))
    rows.append(m)
    let sp = SheetRow("Speaker", glyph: Glyph.speaker)
    sp.value = speakerName.isEmpty ? "…" : speakerName
    sp.valueIsWord = true
    sp.chevron = true
    sp.target = self; sp.action = #selector(speakerPageRow(_:))
    rows.append(sp)
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
      // Not "Your handle". The hint under this row already explains it in plain
      // words -- "This is the name people type to call you" -- and then the row
      // above it used a word from the other register. A person has a name.
      let h = SheetRow("Your name", glyph: Glyph.person)
      h.value = "@" + handle
      // Pressing it copies it, so it is drawn as something you press.
      h.valueIsWord = true
      h.valueIsAction = true
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
    peopleEntry.chevron = true
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
    rename.chevron = true
    rename.target = self; rename.action = #selector(renameRow(_:))
    items.append(rename)
    let recRow = SheetRow(CallRecorder.shared.isRecording ? "Stop recording" : "Record call", glyph: Glyph.record)
    recRow.target = self; recRow.action = #selector(recordRow(_:))
    if CallRecorder.shared.isRecording {
      recRow.value = "recording"
      recRow.valueIsWord = true
    }
    items.append(recRow)
    let openRecRow = SheetRow("Open Recordings in Finder", glyph: Glyph.folder)
    openRecRow.target = self; openRecRow.action = #selector(openRecordingsRow(_:))
    items.append(openRecRow)
    items += rows as [NSView]
    // -- THE SETTING THAT DECIDES WHETHER YOU CAN BE CALLED AT ALL ------------
    //
    // It was already automatic: an installed copy writes its own login item on
    // every launch. Then it did not work on somebody's second Mac and there was
    // no way to find that out from inside the app -- the only report was
    // `--watch-status`, in a terminal, saying "plist present, launchd running".
    // A feature whose whole promise is "people can reach you" has to say, on the
    // screen, whether people can reach you.
    let w = Watch.reach()
    let reach = SheetRow("Calls when Kin is closed", glyph: Glyph.phone)
    // A SWITCH, not a tick. A tick on the right of a row means "this one is
    // selected" everywhere else in this same panel -- it is what the camera list
    // above uses -- so the same mark was doing two opposite jobs three rows apart.
    // This is the setting that decides whether anybody can reach this Mac at all;
    // it should be the least ambiguous control in the app.
    reach.switchState = w.on
    reach.target = self; reach.action = #selector(toggleWatchRow(_:))
    items.append(reach)
    // Only when it is off, and it always names the one thing that fixes it.
    if !w.on, !w.says.isEmpty { items.append(SheetHint(w.says)) }
    // Silent is a switch, so it carries a tick and never a value.
    let q = SheetRow("Silent", glyph: Glyph.bell)
    q.switchState = silentBusy ? nil : silent
    q.value = silentBusy ? "…" : ""
    q.inert = silentBusy
    q.target = self; q.action = #selector(toggleSilentRow(_:))
    items.append(q)
    if !settingsNote.isEmpty { items.append(SheetHint(settingsNote)) }
    items.append(safety)
    items.append(SheetHint(silent
      ? "Silent: nobody can ring you. To them you simply look away."
      : "Read it aloud. Same code on both screens means nobody is in the middle."))
    // ── WHICH KIN THIS IS ─────────────────────────────────────────────────────
    //
    // Asked for directly, and the reason is worth writing down because it is not
    // vanity: this app updates itself silently, so the person testing it has no
    // way to know which build is in front of them. Two Macs side by side running
    // different versions look identical and behave differently, and every
    // conclusion drawn from that pair is worthless. It is the first thing to
    // check before any comparison and it was not on the screen anywhere.
    //
    // Inert, like the encryption code above it: a fact about this copy, with
    // nothing to press. Last in the panel because it is the thing you go looking
    // for rather than the thing you come here to do. `describeTree` prints the
    // sheet's rows, so a rig can assert the version on screen IS `VERSION`.
    // ── AND IT IS THE ROW YOU PRESS TO GET A NEWER ONE ────────────────────────
    //
    // `inert = true` was right when this row was only a fact. It is the only place
    // in the app where the version appears, so it is also where somebody goes when
    // they want to know whether they have the latest -- and the answer to that
    // question lived in a menu item two menus away.
    //
    // Three states, and the row is the whole of the feedback: pressing it says
    // "checking…", finding nothing says so, and an update that is already
    // downloaded and waiting turns the row into the thing that lands it.
    let ver = SheetRow("Version", glyph: Glyph.more)
    if Update.pending != nil {
      ver.setLabel("Update ready")
      ver.value = "restart"
      ver.valueIsWord = true
      ver.valueIsAction = true
      ver.target = self; ver.action = #selector(restartForUpdateRow(_:))
    } else if updateChecking {
      ver.value = "checking\u{2026}"
      ver.valueIsWord = true
      ver.inert = true
    } else {
      ver.value = VERSION
      ver.valueIsWord = true
      ver.valueIsAction = true
      ver.target = self; ver.action = #selector(checkUpdateRow(_:))
    }
    items.append(ver)
    if !updateNote.isEmpty { items.append(SheetHint(updateNote)) }
    // ── AND WHAT IT IS ────────────────────────────────────────────────────────
    //
    // Kin is AGPL-3.0, and that gives the person running it rights: to the
    // source, to change it, to run their own copy of the server it talks to.
    // Until this row the only places that was said were a website they may never
    // have visited and a line in `--help` they will never type. An app whose
    // users cannot tell from inside it that it is free software is failing the
    // standard that costs the least to meet.
    //
    // Inert, and directly under the version, because both are the same kind of
    // thing: a fact about this copy with nothing to press. The repository goes in
    // a hint rather than in the value slot -- that slot is one short
    // right-aligned token, and a URL put there would be truncated into something
    // nobody could type back in. `describeTree` prints rows AND hints, so a rig
    // can assert both halves are actually on screen.
    let lic = SheetRow("Licence", glyph: Glyph.more)
    lic.inert = true
    lic.value = "AGPL-3.0"
    items.append(lic)
    items.append(SheetHint("Free software. The source, and your right to run your own: "
                         + "github.com/deshmukhpatel98/tokkah"))
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
      items.append(SheetHint("Talk to someone once and they’ll show up here."))
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
      // ── AND IT HAS TO SAY WHY, NOT JUST THAT ─────────────────────────────
      //
      // This was one fixed sentence. A fresh install on this Mac was refused its
      // handle with a 429, retried nothing, and the only report of that anywhere
      // was a line in stderr -- so the person was uncallable, for the whole
      // launch, under a hint that read like a step still in progress. Which of
      // the three reasons it is (no network, the server is busy, every name is
      // taken) is the whole of what someone would do differently, and only the
      // last one is theirs to fix. Read live, so opening the panel again after
      // the network comes back shows the sentence that is true now.
      items.append(SheetHint(Identity.nameTroubleLine))
    } else {
      let mine = ContactRow(handle: handle)
      mine.value = "copy"
      mine.valueIsWord = true
      mine.valueIsAction = true
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

  @objc private func recordRow(_ sender: Any?) {
    Menu.Target.shared.record()
    rebuildSheet()
  }

  @objc private func openRecordingsRow(_ sender: Any?) {
    Menu.Target.shared.openRecordings()
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
    // ── BACK, NOT SHUT ────────────────────────────────────────────────────────
    //
    // `closeMore()` was here. Picking a camera took the whole panel off screen, so
    // the tick that says which one you now have was drawn onto a surface that had
    // just been hidden -- you had to reopen the panel to find out whether the press
    // had worked. Every other settings list on this machine leaves you where you
    // were with the tick moved.
    showPage(.settings, opening: false)
  }

  @objc private func cameraPageRow(_ sender: SheetRow) { showPage(.camera, opening: true) }
  @objc private func micPageRow(_ sender: SheetRow) { showPage(.microphone, opening: true) }
  @objc private func speakerPageRow(_ sender: SheetRow) { showPage(.speaker, opening: true) }

  @objc private func pickAudioRow(_ sender: SheetRow) {
    guard let uid = sender.deviceUID else { return }
    let input = sender.deviceIsInput
    Metrics.tap(input ? "pick_mic" : "pick_speaker")
    // Optimistic, then corrected: `onAudioDevice` rebuilds the audio graph and
    // hands back the name that is ACTUALLY in use, which is not always the one
    // asked for -- a headset can be unplugged between this panel being drawn and
    // this row being pressed.
    if input { micName = sender.spokenName } else { speakerName = sender.spokenName }
    showPage(.settings, opening: false)
    onAudioDevice?(uid, input)
  }

  /// The chosen microphone or speaker, changed live. `main.swift` rebuilds the
  /// audio graph and calls `setAudioNames` back with what actually happened.
  var onAudioDevice: ((String, Bool) -> Void)?
  /// What the live audio graph is using, as names. Empty until it exists.
  private(set) var micName = ""
  private(set) var speakerName = ""

  func setAudioNames(mic: String, speaker: String) {
    onMain { [weak self] in
      guard let self, mic != self.micName || speaker != self.speakerName else { return }
      self.micName = mic
      self.speakerName = speaker
      self.refreshSheet()
    }
  }

  /// One page, three kinds. The list, a tick on the live one, and a way back.
  private func buildDevicePage(_ kind: Sheet.Page) {
    var items: [NSView] = []
    switch kind {
    case .camera:
      for (i, name) in camNames.enumerated() {
        let r = SheetRow(name, glyph: Glyph.cam)
        r.checked = i == camPicker.indexOfSelectedItem
        r.tag = i
        r.target = self; r.action = #selector(pickCameraRow(_:))
        items.append(r)
      }
    case .microphone, .speaker:
      let input = kind == .microphone
      let live = input ? micName : speakerName
      let list = Audio.devices(input: input)
      if list.isEmpty {
        items.append(SheetHint(input
          ? "No microphone found. Plug one in, or check Privacy & Security."
          : "No speaker found."))
      }
      for d in list {
        let r = SheetRow(d.name, glyph: input ? Glyph.mic : Glyph.speaker)
        // Ticked from the LIVE device's name, not from what was saved: a saved
        // choice that is unplugged falls back to the system default, and a tick on
        // a device that is not carrying the call is the instrument lying.
        r.checked = d.name == live
        r.deviceUID = d.uid
        r.deviceIsInput = input
        r.target = self; r.action = #selector(pickAudioRow(_:))
        items.append(r)
      }
    default: break
    }
    let back = SheetRow("Back")
    back.target = self; back.action = #selector(backToSettings(_:))
    items.append(back)
    sheet.setItems(items)
  }

  @objc private func backToSettings(_ sender: SheetRow) { showPage(.settings, opening: false) }

  /// Whether a check asked for from the panel is still out, and what it said.
  private var updateChecking = false
  private var updateNote = ""

  @objc private func checkUpdateRow(_ sender: SheetRow) {
    Metrics.tap("check_update_row")
    guard !updateChecking else { return }
    updateChecking = true
    updateNote = ""
    refreshSheet()
    Update.checkNowForPerson()
    // The poller answers on its own thread and there is no completion to hang on,
    // so the row waits a bounded time and then reports what it can see. A spinner
    // with no end is worse than either answer.
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
      guard let self else { return }
      self.updateChecking = false
      self.updateNote = Update.pending != nil
        ? "" : "This is the newest version."
      self.refreshSheet()
      // The sentence is a moment, not a state: it answers a press and then gets
      // out of the way. A panel that keeps telling you it is up to date is a panel
      // with a stale sentence on it the next time you open it.
      DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
        guard let self, !self.updateNote.isEmpty else { return }
        self.updateNote = ""
        self.refreshSheet()
      }
    }
  }

  @objc private func restartForUpdateRow(_ sender: SheetRow) {
    Metrics.tap("restart_for_update_row")
    guard Update.pending != nil else { return }
    Update.restartNow = true
    setStatus("restarting\u{2026}")
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
      // ── ASKED OF THE WHOLE CHAIN, NOT OF THE BUTTON ────────────────────────
      //
      // The buttons' own alpha stopped being the answer the day the row's fade
      // moved onto the `GlassGroup` they sit in: a child of a hidden container is
      // not hidden and its alpha is still 1. This reported four visible buttons on
      // a screen with none -- an instrument describing the code's intent instead of
      // the screen, which is the exact failure `describeTree` exists to prevent.
      .filter { CallControls.onScreen($0.1) && $0.1.frame.width > 4 }
      .map { $0.0 }
  }

  /// Reachable AND drawn: this view and every ancestor up to the overlay. The one
  /// question two separate readers here kept answering differently.
  static func onScreen(_ v: NSView) -> Bool {
    var w: NSView? = v
    while let x = w {
      if x.isHidden || x.alphaValue <= 0.01 { return false }
      // ── AND CLIPPED IS NOT ON SCREEN EITHER ────────────────────────────────
      //
      // The third way a control can be undrawn, after `isHidden` and a zero
      // alpha: inside a container that masks to its bounds, at a position outside
      // them. The settings panel scrolls at small window sizes, so a row can be
      // perfectly visible in the view hierarchy and above the top edge of the
      // panel holding it -- and this reader is the one both `clickTargets` and
      // `visibleRowNames` ask, so answering `true` there would put a row nobody
      // can see into the audit and then report it FAIL.
      if let sv = x.superview, sv.layer?.masksToBounds == true,
         !sv.bounds.insetBy(dx: -1, dy: -1).contains(NSPoint(x: x.frame.midX, y: x.frame.midY)) {
        return false
      }
      if x is CallControls { return true }
      w = x.superview
    }
    return true
  }

  var describeTree: String {
    "controls \(Int(bounds.width))x\(Int(bounds.height))"
      + "  status=\(status.isEmpty ? "-" : status)"
      + "  who=\(whoPill.text.isEmpty ? "-" : whoPill.text)"
      + "  poster=\(poster.describe)"
      + "  quality=\(qualityText.isEmpty ? "-" : qualityText)"
      // THE WARNING IS A SENTENCE THE USER READS, so an instrument that cannot see
      // it cannot check the one thing that matters about it. "their camera is off"
      // was invisible to every rig here until this line existed.
      + "  warn=\(warnText.isEmpty ? "-" : warnText)"
      // Separate from `warn=`: they are two different claims -- one about this
      // Mac, one about the other person -- and a rig asserting on a local fault
      // must not be satisfied by a remote one that happens to be showing.
      + "  trouble=\(troubleLocal.isEmpty ? "-" : troubleLocal)"
      // WHICH card is up, not just whether one is. The link and the name field
      // occupy the same rectangle, so a rig reading frames alone cannot tell the
      // two apart -- and "the button swapped them" is the whole feature.
      + "  card=\(waiting.isHidden ? "hidden" : waiting.mode.rawValue)"
      // WHAT IS IN THE BOX, not just which box. `--press "@call,+meera"` proved
      // the field could be focused and typed into and could not show that the
      // letters arrived -- an instrument blind to the one thing the step is for.
      + (waiting.mode == .dial ? "  dialtext=\"\(waiting.dialText)\"" : "")
      // The card's own words, which are the whole of the calling state, and
      // whether the dots are ANIMATING rather than merely present -- "it is on
      // screen" and "it is visibly alive" are two claims and this state exists
      // entirely for the second one.
      + (waiting.cardWords.isEmpty ? "" : "  says=\"\(waiting.cardWords)\"")
      + (waiting.mode == .calling ? "  dots=\(waiting.dotsAlive ? "alive" : "STILL")" : "")
      // WHOSE face. The circle is the only picture of a person this app has, and a
      // card showing the right name over the wrong initial and colour is a defect
      // no assertion about the words could ever see.
      + (waiting.faceOf.isEmpty ? "" : "  face=\(waiting.faceOf)")
      + "  picker=\(camPicker.isHidden ? "hidden" : "\(camNames.count) items")"
      + "  mic=\(micMuted ? "muted" : "on") cam=\(camOff ? "off" : "on")"
      // WHOSE TURN IT IS, as the microphone button is drawing it. The word is the
      // decision and the number is where the ease actually got to, in one field,
      // because two fields describing one control are two fields that can
      // disagree -- this file has paid for that before. Without the number an
      // assertion can only see that the app CHOSE a state, which is exactly the
      // half that was never the bug here.
      + "  micfloor=\(micFloorState) edge=\(edgeState)"
      + "  row=[\(visibleRowNames.joined(separator: " "))]"
      + "  more=\(moreOpen ? "open" : "closed") peek=\(peeking)\(peekButton.holding ? "/held" : "")"
      // A CUMULATIVE count, not a flag. A boolean sampled after the fact is a birth
      // certificate rather than a health record, and only a count can show that one
      // press did not classify as both a tap and a hold.
      + " peektap=\(peekButton.taps)"
      // The existing field EXTENDED rather than a second one beside it, because two
      // fields describing one control are two fields that can disagree. A
      // percentage is the only way a fill can be asserted without a screenshot.
      + "  leave=\(leaveState) bar=\(barState)"
      + "  handle=\(handle.isEmpty ? "-" : handle) people=\(people.count)"
      // ── SOMEBODY ELSE'S TEXT, INSIDE OUR RECORD ────────────────────────────
      //
      // This is the one field whose contents this app does not control: it is
      // whatever the person happened to copy. Pasted in raw, a clipboard holding
      // a newline SPLITS THIS LINE IN TWO -- and everything after `clip=`, which
      // is the entire caption section, lands on a second line that no rig
      // matches. That is exactly what happened: `immersive-check` part seven
      // reported "the subtitles broke" on a healthy build, three runs running,
      // because a URL had been copied on this Mac. A diagnostic that a bystander
      // can corrupt by copying text is not a diagnostic.
      //
      // Newlines and tabs become a visible glyph rather than being dropped, so a
      // multi-line clipboard still reads as multi-line, and the whole thing is
      // capped -- the invite links this field exists to prove are short, and a
      // copied document has no business in a one-line state dump.
      + "  clip=\(Self.oneLine(NSPasteboard.general.string(forType: .string)))"
      + "  \(cues.describe)"
      + (moreOpen ? "\n  sheet=\(sheetPage.rawValue)["
                  + sheet.rows.map { $0.spoken }.joined(separator: " | ") + "]"
                  // The sentences, not only the controls. See `SheetHint.text`.
                  + " hints=[" + sheet.hints.map { Self.oneLine($0) }
                                      .joined(separator: " | ") + "]"
                  + (sheet.field.map { " field=\"\($0.text)\" editor=\($0.describeEditor)" } ?? "")
                  // ── A NEW FACT GOES IN A NEW FIELD ──────────────────────────
                  //
                  // How much of the panel is showing went inside `sheet=` first,
                  // as `sheet=settings(fits)[...]`, and it broke four assertions
                  // in `controls-check` and three more in `watch-check`,
                  // `stress-check` and `firstrun-ring-check` -- all of which match
                  // `sheet=settings\[`, correctly, because that field has meant one
                  // thing for months. Every one of those failures named a page
                  // navigation that was working perfectly. A state dump is an
                  // interface: adding to it is free, changing the shape of a field
                  // in it is a rename with seven callers.
                  + "  panel=\(sheet.describeScroll)" : "")
  }

  private var leaveState: String {
    guard leaveArmed else { return "idle" }
    guard leaveButton.holdProgress > 0 else { return "ARMED" }
    return "HOLDING:\(Int((leaveButton.holdProgress * 100).rounded()))"
  }

  /// `shown`, `hidden`, or `shown/held:<reason>`. The EXISTING word plus why, in
  /// the field that already carried it, because two fields describing one control
  /// are two fields that can disagree -- this file has paid for that before. And
  /// the reason is not optional detail: "it did not fade" has seven causes, and an
  /// assertion that cannot name the one it is testing passes on any of them.
  private var barState: String {
    (barShown ? "shown" : "hidden") + (barHoldReason.map { "/held:\($0)" } ?? "")
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
    // ── EVERY KEY IS A PERSON, INCLUDING THE ONES THIS APP IGNORES ────────────
    //
    // Before the switch and before every guard. The three keys below are the only
    // ones this window does anything with, and "the controls come back when you
    // touch the keyboard" is not a claim about those three -- it is a claim about
    // the keyboard. A key that falls straight through, which is nearly all of
    // them, is still somebody sitting at this Mac.
    //
    // Safe to put ahead of the returns because this is a local monitor: the event
    // carries on to whoever it belonged to whatever happens here.
    nudgeBar()
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    // ── ANSWERING WITHOUT A MOUSE ─────────────────────────────────────────────
    //
    // A call could only be answered by clicking, which is a gap on a Mac (Return
    // answers in FaceTime) and a wall for anyone who does not use a trackpad.
    //
    // Return is guarded and Escape is not, and the asymmetry is the whole design.
    // Declining ends something: the worst a stray Escape can do is refuse a call,
    // which the caller sees and can repeat. Answering STARTS A CAMERA AND A
    // MICROPHONE, and this window raises itself in front of whatever somebody was
    // typing in -- the exact accident this project has already had with the mouse,
    // where "real trackpad taps ANSWERED Kin calls" because the ring window
    // arrived under a finger that was already moving. A keystroke in flight when
    // the card appears must not be the thing that opens a camera.
    //
    // 600 ms is longer than the gap between deciding to press a key and pressing
    // it, and far shorter than the time it takes to read a name and choose. The
    // window is also required to be KEY: a ring that has not been brought forward
    // is not one somebody is looking at.
    if !waiting.isHidden, waiting.mode == .ringing {
      // ── THE AGE IS THE GUARD, AND IT IS THE ONLY ONE ────────────────────────
      //
      // `window.isKeyWindow` was in this condition too and came out again. It adds
      // nothing in production -- a keyDown only reaches this app's monitor while
      // the app is frontmost, and a window that is not key cannot be the one
      // receiving it -- and it made the defence UNTESTABLE: every rig here parks
      // its window with `TK_NO_RAISE` precisely so it never takes the front, so the
      // guard could only ever be observed refusing. A defence whose passing half
      // cannot be exercised is one nobody has seen work
      // (`handler-tests-cannot-see-interaction-bugs`).
      let age = waiting.ringingSince.map { Date().timeIntervalSince($0) } ?? 0
      if event.keyCode == 36 || event.keyCode == 76 {           // return / enter
        guard age >= 0.6 else {
          fputs("ring: Return ignored -- the card is only \(Int(age * 1000)) ms old."
              + " A key already travelling must not answer a call.\n", stderr)
          return true
        }
        fputs("ring: answered from the keyboard (Return, card \(Int(age * 1000)) ms old)\n", stderr)
        Metrics.count("answer_key")
        waiting.onAnswer?()
        return true
      }
      if event.keyCode == 53 {                                  // esc
        fputs("ring: declined from the keyboard (Escape)\n", stderr)
        Metrics.count("decline_key")
        waiting.onDecline?()
        return true
      }
    }
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
    case "r": Menu.Target.shared.record(); return true
    default: return false
    }
  }

  func simulate(_ what: String) {
    switch what {
    // ── THROUGH THE WINDOW, NOT INTO THE HANDLER ──────────────────────────────
    //
    // This called `handleKey` directly, with `windowNumber: 0`. That is a handler
    // test wearing an NSEvent, and it is blind to the thing keys actually do:
    // AppKit decides WHO gets the key before any handler sees it. While the name
    // field is being typed into, Escape belongs to its field editor, which turns it
    // into `cancelOperation:` -- so the card's text delegate is what cancels a dial,
    // and `handleKey` never runs at all.
    //
    // Measured: `--press "@call,+meera,esc,?"` reported `key esc: handled=false` and
    // left the card in dial mode, which is what a WORKING Escape also looks like
    // from inside `handleKey`. The token could not tell the two apart.
    //
    // So it goes through `window.sendEvent`, the path the window server uses, and
    // lands wherever it really lands. `handleKey` stays as the fallback for a
    // headless run, where there is no window to send anything to.
    case "esc", "cmd-mic", "cmd-cam", "cmd-rec":
      let ch = what == "esc" ? "\u{1b}" : (what == "cmd-mic" ? "a" : (what == "cmd-cam" ? "v" : "r"))
      let code: UInt16 = what == "esc" ? 53 : (what == "cmd-mic" ? 0 : (what == "cmd-cam" ? 9 : 15))
      let mods: NSEvent.ModifierFlags = what == "esc" ? [] : [.command, .shift]
      guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window?.windowNumber ?? 0,
                                     context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                     isARepeat: false, keyCode: code) else { break }
      // ── POSTED, NOT SENT ──────────────────────────────────────────────────
      //
      // `window.sendEvent` looked like the real path and skipped half of it. The
      // app's keys are wired to an `addLocalMonitorForEvents` monitor -- see
      // `Display` -- which the application object fires on its way from the event
      // QUEUE to the window. Handing the event straight to the window arrives
      // downstream of that, so Escape reached the field editor and never reached
      // the monitor: measured as `more=open` before and after, a sheet that would
      // not close for a key that closes it.
      //
      // Posting puts it in the queue and lets the whole chain run in order, which
      // is the only version of this that can be wrong in the same ways the real
      // key can. It is asynchronous, which is why the result is read by the NEXT
      // token rather than by this one.
      if window != nil {
        NSApp.postEvent(e, atStart: false)
        if let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: mods,
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window?.windowNumber ?? 0, context: nil,
                                     characters: ch, charactersIgnoringModifiers: ch,
                                     isARepeat: false, keyCode: code) {
          NSApp.postEvent(up, atStart: false)
        }
        fputs("key \(what): posted to the app queue\n", stderr)
      } else {
        fputs("key \(what): no window, straight to handleKey ->"
            + " handled=\(handleKey(e))\n", stderr)
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
    // ── THE IMMERSIVE STATE, REACHED WITHOUT WAITING FOR IT ───────────────────
    //
    // `fade` puts the row exactly where two and a half still seconds would put it,
    // through the same call the timer makes. It is how the faded window gets
    // photographed at all: `screencapture` takes about a second to arm and every
    // press token nudges the row back on its way past.
    //
    // `blind-tap` and `sighted-tap` are the two arms of one experiment -- see
    // `tapWhereTheMicIs` for why a `@mic` click can never be the first of them.
    case "fade": setBar(visible: false); barTimer?.invalidate()
    case "blind-tap": tapWhereTheMicIs(faded: true)
    case "sighted-tap": tapWhereTheMicIs(faded: false)
    case "people": openPeople()
    case "people-back": showPage(.settings, opening: false)
    case "rename": showPage(.rename, opening: true)
    case "rename-save": commitRename()
    case "handle-copy": copyHandle()
    case "call-new": callSomeoneNew()
    // The swap, without a pointer. `@call` clicks the circle and is the better
    // test of the two; these are how a rig reaches the same state when the card
    // is not the thing being photographed.
    case "dial-open": waiting.enterDial()
    case "dial-close": waiting.leaveDial()
    case "share": share()
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
    // ── THE MICROPHONE BUTTON'S THREE STATES, HELD STILL ──────────────────────
    //
    // A photograph needs the state to sit still, and the real one is a gate
    // reacting to somebody's voice several times a second. These pin it -- see
    // `floorPin`. They are the LAST resort of `tools/floor-check.sh` and not its
    // first: the live arm of that rig never touches them, so what these prove is
    // the DRAWING, and what the live arm proves is that the gate arrives here.
    // A rig built only on these would be testing its own pin.
    case "floor-held": floorPin = .held; wakeFloor()
    case "floor-bid": floorPin = .bidding; wakeFloor()
    case "floor-through": floorPin = .through; wakeFloor()
    case "floor-live": floorPin = nil; wakeFloor()
    // ── HOW MANY FRAMES BEFORE THE WORDS ARE READABLE ─────────────────────────
    //
    // The press loop puts its tokens 0.7 s apart, which is two and a half times
    // longer than the thing being measured -- an audit taken then reads "98%"
    // whether the band rose in one frame or in twenty-five, so a rig built on it
    // would report a pass on either. `frames-blind-to-the-effect` in one line.
    //
    // So this drives a throwaway band at a FIXED frame time and counts, with no
    // wall clock in the answer: synthetic input, fixed step, deterministic, the
    // `--gate-test` model. It is a real `TurnCues` through the real setter, so
    // what it counts is what a person waits for.
    case "band-rise":
      let probe = TurnCues(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
      probe.setTheirs("So the thing about a call is that you never really know "
                    + "whose turn it is, and that is the whole problem.", final: false)
      probe.layoutSubtreeIfNeeded()
      var frames = 0, readable = -1, full = -1, firstH: CGFloat = -1
      while frames < 120, readable < 0 || full < 0 {
        probe.testTick(1.0 / 30.0)
        frames += 1
        if firstH < 0 { firstH = probe.testBandHeightFraction }
        if readable < 0, probe.testBandAlpha >= 0.90 { readable = frames }
        if full < 0, probe.testBandAlpha >= 0.999 { full = frames }
      }
      fputs("band-rise: readable(>=90%) after \(readable) frame(s),"
          + " full after \(full) frame(s), at 30 Hz"
          + String(format: "  -- %d ms / %d ms;  height on frame 1 = %.0f%% of what it needs",
                   readable * 1000 / 30, full * 1000 / 30, firstH * 100) + "\n", stderr)
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
      // ── AN ANCESTOR'S STATE IS THIS VIEW'S STATE ──────────────────────────
      //
      // `!v.isHidden` alone was a lie the moment the row's fade moved onto the
      // GlassGroup: the buttons themselves are never hidden, their container is,
      // and `hitTest` stops at the container. An audit that reports five reachable
      // controls on a screen with none is exactly the instrument this file keeps
      // finding -- so reachability is asked of the whole chain, which is what a
      // click actually walks.
      guard CallControls.onScreen(v) else { return }
      guard v.bounds.width > 4, v.bounds.height > 4, !v.frame.isEmpty else { return }
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
      // ── THE WARNING IS A CONTROL WHEN IT CARRIES A FIX ──────────────────────
      //
      // "Kin can't hear you -- turn on the microphone" opens System Settings when
      // clicked, which makes it the only sentence in the app that is also a
      // button -- and a control the harness cannot reach is a control whose
      // handler is the only thing ever tested (`handler-tests-cannot-see-
      // interaction-bugs`). Listed only while it is actionable, because a plain
      // notice is not something to press.
      if !troubleLocal.isEmpty, onTroubleClick != nil { add("warning", warnPill) }
    } else {
      // ── NAMED BY WHAT THEY SAY, NOT BY WHERE THEY SIT ─────────────────────
      //
      // `row#3` is a position, and every row in this panel changes position: the
      // camera list is one row on this Mac and three on another, the name row is
      // absent until a handle is claimed, and pressing `People` replaces the whole
      // page. A rig that clicks `row#3` twice clicks two different things and has
      // no way to know. The index names stay, because existing invocations use
      // them, and every row gains the name a person would call it by.
      for (i, r) in sheet.rows.enumerated() where r.isEnabled {
        add("row#\(i)", r)
        let slug = CallControls.slug(r.spokenName)
        if !slug.isEmpty { add("row:" + slug, r) }
      }
      // The one thing in a sheet that is typed into rather than pressed. Named, so
      // `@name` focuses it and `+meera` has somewhere to land.
      if let f = sheet.field { add("name", f) }
      // ── AND THE WAY OUT THAT NEEDS NO AIMING ────────────────────────────────
      //
      // A click anywhere outside the panel closes it, and that is the primary
      // route: the corner button cannot close it (it is under the scrim, which is
      // correct and is why it is absent from this list while the panel is open),
      // Escape is a keyboard reflex, and the swipe is for a trackpad. So the most
      // used exit in the app was the one no click had ever tested -- and a rig
      // that cannot close the panel cannot test anything that comes after it.
      add("scrim", sheetScrim)
    }
    // Under the scrim too, for the same reason and with the same consequence: while
    // the panel is open, a click on `copy` closes the panel rather than copying.
    if !waiting.isHidden, !moreOpen { for (n, v) in waiting.clickTargets { add(n, v) } }
    return out
  }

  /// Lowercase, letters and digits only. `"Calls when Kin is closed"` becomes
  /// `callswhenkinisclosed`, which is ugly and unambiguous; a rig can also pass a
  /// PREFIX of it (see `click`).
  static func slug(_ s: String) -> String {
    String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
             .map(Character.init))
  }

  // ── WHERE TO AIM AT A CONTROL ────────────────────────────────────────────
  //
  // The centre of the control, which is what a person aims at and what every
  // press in this file has always used -- with one exception that only exists
  // now that the settings panel can fill a small window.
  //
  // `scrim` is the whole window; the way to close the panel is a click ON the
  // scrim, meaning anywhere the panel is not. At a normal size its centre is well
  // clear of the panel and its centre is the right point. At 480x320 the panel is
  // 452x258 of a 480x320 window, so the scrim's CENTRE is under the panel -- and
  // aiming there does not close anything, it presses whichever setting happens to
  // be in the middle of the list. Two consequences, and the second is worse than
  // the first: the audit printed `FAIL scrim` about a screen that was working,
  // and `click("scrim")` -- the way four rigs in this directory close the panel
  // between steps -- would have pressed a settings row instead, silently, and
  // gone on to test whatever that row did.
  //
  // So the aim point for a covered scrim is the middle of the largest band of it
  // that the panel leaves free. One reader, used by the audit and by `click`,
  // because two places computing one aim point is two places that can disagree --
  // and the disagreement would be invisible in both.
  func probeCentre(_ v: NSView) -> NSPoint {
    let mid = NSPoint(x: v.bounds.midX, y: v.bounds.midY)
    guard v === sheetScrim, moreOpen, !sheet.isHidden else { return mid }
    let s = sheet.frame, b = v.bounds
    guard s.contains(v.convert(mid, to: self)) else { return mid }
    // The four bands around the panel, in this view's own coordinates.
    let bands: [NSRect] = [
      NSRect(x: b.minX, y: s.maxY, width: b.width, height: max(0, b.maxY - s.maxY)),
      NSRect(x: b.minX, y: b.minY, width: b.width, height: max(0, s.minY - b.minY)),
      NSRect(x: b.minX, y: b.minY, width: max(0, s.minX - b.minX), height: b.height),
      NSRect(x: s.maxX, y: b.minY, width: max(0, b.maxX - s.maxX), height: b.height),
    ]
    guard let best = bands.filter({ $0.width > 8 && $0.height > 8 })
                          .max(by: { $0.width * $0.height < $1.width * $1.height })
    else { return mid }
    return NSPoint(x: best.midX, y: best.midY)
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
      let p = v.convert(probeCentre(v), to: nil)
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
      // `first=no` means a click that merely brings Kin forward will not fire
      // this control. It should read `no` on everything consequential and `yes`
      // on the rest -- see WaitingCard.acceptsFirstMouse.
      let first = waiting.clickTargets.contains(where: { $0.1 === v })
        ? (waiting.firstMouseAt(v) ? "  first=yes" : "  first=no") : ""
      // ── AND WHAT A VOICEOVER USER MEETS ───────────────────────────────────
      //
      // A control with no accessibility label announces as "button", which is the
      // same thing every other unnamed control announces as. That is not a
      // cosmetic gap: it is a screen with six identical buttons on it. Reported
      // per control, in the audit that already walks every one of them, so it
      // cannot be a separate pass that nobody runs.
      let named = (v.accessibilityLabel()?.isEmpty == false)
      lines.append("\(verdict) \(name) at (\(Int(p.x)),\(Int(p.y))) -> \(got)\(first)"
                 + (named ? "" : "  UNNAMED"))
    }
    return lines
  }

  /// Every clickable thing that a screen reader would announce as nothing in
  /// particular. Empty is the only acceptable answer.
  var unnamedControls: [String] {
    clickTargets.filter { $0.1.accessibilityLabel()?.isEmpty != false }.map { $0.0 }
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
  /// `stray: true` builds the event with a non-zero `eventNumber`, which is how
  /// the waiting card tells a finger from this harness. It exists so the guard
  /// against clicks nobody aimed can be PROVED to fire -- a defence that only
  /// ever runs in production is a defence nobody has seen work.
  func click(_ name: String, holdFor: TimeInterval = 0, stray: Bool = false) -> Bool {
    guard let win = window else { return false }
    // ── SCROLL TO IT FIRST, AS A PERSON WOULD ─────────────────────────────────
    //
    // `clickTargets` lists what is reachable RIGHT NOW, which is the only useful
    // definition -- and in a small window some settings rows are scrolled out of
    // the panel. A person scrolls and then clicks; so does this. Without it every
    // rig in the directory would report the last four settings "not on screen" at
    // any window under about 660 points tall, which is true and useless.
    if moreOpen, sheet.scrolls, !clickTargets.contains(where: { $0.0 == name }) {
      // Both spellings a rig can use: the name a person would read off the row,
      // and the index that existing invocations still pass.
      var target: SheetRow?
      if name.hasPrefix("row:") {
        let want = String(name.dropFirst(4))
        target = sheet.rows.first { CallControls.slug($0.spokenName).hasPrefix(want) }
      } else if name.hasPrefix("row#"), let i = Int(name.dropFirst(4)),
                i >= 0, i < sheet.rows.count {
        target = sheet.rows[i]
      }
      if let r = target, sheet.reveal(r) {
        fputs("  scrolled the panel to reach \(name) (\(sheet.describeScroll))\n", stderr)
      }
    }
    let targets = clickTargets
    // Exact first, then a unique prefix -- `row:calls` for "Calls when Kin is
    // closed". Ambiguity is refused rather than resolved: a rig that quietly
    // pressed whichever row matched first would be a rig that pressed a different
    // row on a Mac with two cameras.
    var found = targets.first(where: { $0.0 == name })?.1
    if found == nil {
      let hits = targets.filter { $0.0.hasPrefix(name) }
      if hits.count > 1 {
        fputs("click: \(name) matches \(hits.map(\.0).joined(separator: ", "))"
            + " -- say which\n", stderr)
        return false
      }
      found = hits.first?.1
    }
    guard let v = found else {
      fputs("click: \(name) is not on screen -- on screen: "
          + targets.map(\.0).joined(separator: " ") + "\n", stderr)
      return false
    }
    // ── FORWARD FIRST, BECAUSE THAT IS WHAT A FINGER DOES ────────────────────
    //
    // A person clicking a control has already brought the window to the front --
    // either it was there, or their click did it and the next one acted. A
    // synthetic press into a window that is neither key nor active is testing
    // AppKit's activation rules instead of the button, and it showed: the same
    // `@decline` press committed in one run and vanished without a trace in the
    // next, differing only in `key=` and `active=`. Now the harness starts from
    // the state a real press starts from, and the activation rules have their own
    // assertion (`first=` in the audit) rather than being tested by accident.
    if !win.isKeyWindow {
      NSApp.activate(ignoringOtherApps: true)
      win.makeKeyAndOrderFront(nil)
      // AND WAIT FOR IT. `activate` is a request to the window server; keyness
      // arrives on a later turn of the run loop, so the line above on its own
      // still clicked into an inactive window -- which is where a posted release
      // goes missing. Bounded, and said out loud when it does not arrive, because
      // a harness that quietly presses into a window nobody can reach reports the
      // same nothing as a broken button.
      let deadline = Date().addingTimeInterval(1)
      while !win.isKeyWindow, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
      }
      if !win.isKeyWindow { fputs("  click: window never became key -- pressing anyway\n", stderr) }
    }
    // ── AND NUDGE AGAIN, BECAUSE THE PUMP ABOVE IS DEAD TIME ──────────────────
    //
    // `--press` nudges the row before calling this, on the reasoning that a press
    // models somebody who has just moved a pointer onto a button. The wait for
    // keyness then spends up to a second in a runloop with nothing happening in
    // it -- which is exactly what the stillness timer is looking for. Measured:
    //
    //     bar: back                      <- the nudge from --press
    //     bar: faded away                <- the timer, during the pump
    //     click peek at (678,53) hit=CallControls key=false
    //
    // The press named `peek`, was aimed at peek's own centre, and woke the row
    // instead, because by the time the event was built there was nothing there.
    // A finger does not pause for a second between arriving and pressing.
    nudgeBar()
    let p = v.convert(probeCentre(v), to: nil)
    func ev(_ t: NSEvent.EventType) -> NSEvent? {
      NSEvent.mouseEvent(with: t, location: p, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: win.windowNumber, context: nil,
                         eventNumber: stray ? 7777 : 0, clickCount: 1,
                         pressure: t == .leftMouseUp ? 0 : 1)
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
      // ── A WINDOW THAT WILL NOT BECOME KEY ────────────────────────────────
      //
      // Measured: the same `@decline` press committed in one run and vanished
      // without a trace in the next -- no commit, and not even the "release did
      // NOT commit" line, because neither half reached the view. The difference
      // was `key=false active=false`, and on a bare command-line binary with
      // another copy of the app fighting for the front, activation is simply
      // refused: the pump above gives up saying so.
      //
      // Through the window when it IS key, which is the faithful path and the one
      // that exercises AppKit's own routing. Straight to the view when it is not,
      // because otherwise the harness is testing activation policy instead of the
      // button -- and the activation rule that actually matters has its own
      // assertion, `first=` in the audit, rather than being proved by accident.
      let direct = win.isKeyWindow ? nil : hitNow
      // ── WHO EATS THE RELEASE ─────────────────────────────────────────────
      //
      // `NSControl` -- every NSButton on this window, and SheetRow -- runs its own
      // tracking loop inside `mouseDown` and pulls the release out of the event
      // queue itself. It must therefore be QUEUED before the press, or the press
      // blocks the main thread forever waiting for a finger that does not exist;
      // that is what the original ordering here was for, and dropping it hung the
      // invite card's handset mid-run. Handing such a control a second, direct
      // release would be a second click.
      //
      // A plain NSView -- the waiting card, its pills -- commits on a release that
      // has to be handed over here, because a queued one never reaches a window
      // that is not key. Queuing one anyway would land later on an already
      // disarmed card and log a refusal that did not happen.
      let tracks = (direct ?? hitNow) is NSControl
      if direct == nil || tracks { win.postEvent(up, atStart: false) }
      guard let direct else { win.sendEvent(down); return true }
      fputs("  click: window is not key -- delivering straight to \(type(of: direct))\n", stderr)
      direct.mouseDown(with: down)
      if !tracks { direct.mouseUp(with: up) }
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
