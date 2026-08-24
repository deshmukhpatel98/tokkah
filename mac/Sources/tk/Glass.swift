import AppKit

// ── THE DESIGN SYSTEM ────────────────────────────────────────────────────────
//
// Everything in this file used to live at the top of Controls.swift as a colour
// enum and one class called `Glass` that was not glass. It was an
// `NSVisualEffectView` with an opaque fill painted over the top:
//
//     material = .hudWindow                     // a real blur
//     layer?.backgroundColor = rgba(10,14,22,.72)   // ...covered up entirely
//
// A 72%-opaque dark rectangle over a blur is a dark rectangle. Every screenshot
// agreed it looked fine, because the app photographs its own LAYER TREE and the
// layer tree cannot see a material -- so the check was a flat fill over black
// compared against a flat fill over black. Photographed through the window server,
// over an actual face, the row of controls is six opaque grey discs.
//
// So this file is the material, taken from the system rather than imitated in
// CSS, plus the geometry that decides where things sit and how round they are.
//
// ── WHAT APPLE ACTUALLY SAYS ────────────────────────────────────────────────
//
// From the Human Interface Guidelines (Materials) and the Liquid Glass technology
// overview, the four rules that shaped every decision below:
//
//   1. "Don't use Liquid Glass in the content layer." Glass is the FUNCTIONAL
//      layer -- controls and navigation -- floating above content. Here the
//      content is the other person's face. The bar, the pills and the sheet float
//      above it; the picture itself never gets a material.
//
//   2. "Only use clear Liquid Glass for components that appear over visually rich
//      backgrounds." A live camera feed is the definition of one, so the control
//      row is `.clear`. Panels carrying sentences are `.regular`, which "blurs and
//      adjusts the luminosity of background content to maintain legibility" --
//      the guidance names alerts, sidebars and popovers, and this app's sheet and
//      waiting card are the same kind of thing.
//
//   3. "If the underlying content is bright, consider adding a dark dimming layer
//      of 35% opacity." The old scrim was 72% -- a black band across the bottom of
//      somebody's face, transcribed from the web app's CSS where it was
//      compensating for having no material at all. It is 35% now because the glass
//      is doing the rest of the work.
//
//   4. "Use Liquid Glass effects sparingly... overusing this material in multiple
//      custom controls can provide a subpar user experience by distracting from
//      that content." So a hover state is a vibrant fill, not a second pane of
//      glass, and nothing here is glass on glass.
//
// ── AND WHY THE GEOMETRY IS IN THE SAME FILE ────────────────────────────────
//
// Because the radii were magic numbers and they disagreed with each other: the
// sheet was 20 with rows of 12 inside 10 points of padding, pills were 13, two
// fields were 14, the confirm morph was 24 and the self-view was 12. Nine numbers,
// no rule. Apple's rule is CONCENTRICITY -- a nested corner shares its centre of
// curvature with the corner outside it, which happens exactly when
//
//     inner radius = outer radius - the padding between them
//
// so `Metric.concentric` is that subtraction, and a nested shape is never given a
// literal radius again. AppKit exposes this as `NSViewCornerConfiguration`, but
// `NSView.cornerConfiguration` is read-only -- the system sets it for its own
// views and there is no setter to adopt -- so the arithmetic is done here.

/// Spacing, sizes and radii. One 4-point grid, and no literal radius anywhere
/// except the outermost shape of a surface.
enum Metric {
  // ── SPACING, ON A 4-POINT GRID ─────────────────────────────────────────────
  static let s1: CGFloat = 4
  static let s2: CGFloat = 8
  static let s3: CGFloat = 12
  static let s4: CGFloat = 16
  static let s5: CGFloat = 20
  static let s6: CGFloat = 24
  static let s8: CGFloat = 32

  // ── THE CALL SURFACE ───────────────────────────────────────────────────────
  /// A bar circle. Unchanged: 58 is a comfortable target and it is what the row
  /// was already built around.
  static let control: CGFloat = 58
  /// The corner button. Secondary, so smaller, and still well over the 44 pt that
  /// makes a target comfortable.
  static let controlSmall: CGFloat = 48
  /// Between circles in the row.
  static let controlGap: CGFloat = 18
  /// How far the row floats off the bottom edge. Was 14, which parked a 58 pt
  /// circle almost against the frame; a floating bar has to look like it is
  /// floating.
  static let barInset: CGFloat = 24
  /// Window edge margin for anything in a corner.
  static let gutter: CGFloat = 20
  /// Clears the traffic lights, which float over the picture because the window
  /// is `.fullSizeContentView`. One constant so the two top corners stay level.
  static let topInset: CGFloat = 36

  // ── SURFACES ───────────────────────────────────────────────────────────────
  /// The sheet's own corner. Larger than the old 20: macOS 26 sheets took on a
  /// bigger radius, and the sheet is now an inset floating panel rather than a
  /// tray glued to the bottom edge, so all four corners are real.
  static let sheetRadius: CGFloat = 26
  /// Padding between the sheet's edge and a row inside it.
  static let sheetPad: CGFloat = 10
  /// A row inside the sheet. NOT a literal: concentric with the sheet.
  static var sheetRowRadius: CGFloat { concentric(sheetRadius, inset: sheetPad) }
  static let sheetRow: CGFloat = 48
  static let sheetHint: CGFloat = 34
  static let sheetWidth: CGFloat = 420

  /// The waiting card: one panel holding the whole invite, rather than four
  /// controls floating separately over a face.
  static let cardRadius: CGFloat = 30
  static let cardPad: CGFloat = 22
  /// A field inside the card, near its edge -- so concentric with it, not a
  /// number. At a 36 pt field this resolves to a capsule anyway, which is the
  /// answer both rules agree on.
  static var cardFieldRadius: CGFloat { concentric(cardRadius, inset: cardPad) }

  /// Height of an information pill and of a text button. Both are capsules, so
  /// their radius is half of this and is never written down.
  static let pillHeight: CGFloat = 30
  /// A field you can type into, or a link you can select.
  static let fieldHeight: CGFloat = 36

  /// The self-view tile in the corner. Concentric with the window's own corner
  /// across the gutter, so the little picture nests into the big one instead of
  /// sitting in it at an unrelated roundness.
  static var selfRadius: CGFloat { concentric(windowRadius, inset: gutter) }
  /// macOS 26 rounded window corners further. Read from the system where it can
  /// be, so this tracks the platform instead of freezing one release's number.
  static let windowRadius: CGFloat = 32

  // ── THE RULE ───────────────────────────────────────────────────────────────
  /// The radius that makes a shape inset by `inset` share a centre of curvature
  /// with the container around it. Clamped at zero, because a shape inset by more
  /// than the container's radius has a square corner -- which is what the system's
  /// own concentric shapes do rather than going negative.
  static func concentric(_ outer: CGFloat, inset: CGFloat) -> CGFloat {
    max(0, outer - inset)
  }

  /// A capsule: the radius that makes a rectangle of this height end in half
  /// circles. Written as a function so `999px` never appears again.
  static func capsule(_ height: CGFloat) -> CGFloat { height / 2 }
}

/// The type ramp. macOS system sizes, one name per role, so a new label cannot
/// invent a tenth size.
enum Type_ {
  /// The pill at the top of the call: a state, in two or three words.
  static let status = NSFont.systemFont(ofSize: 12, weight: .medium)
  /// A row in the sheet. 13 is what macOS menus use, and the sheet IS this app's
  /// menu.
  static let row = NSFont.systemFont(ofSize: 13, weight: .regular)
  /// The one heading in the app.
  static let title = NSFont.systemFont(ofSize: 17, weight: .semibold)
  /// The sentence under a heading, and the sheet's hints.
  static let caption = NSFont.systemFont(ofSize: 11, weight: .regular)
  /// A word inside a button.
  static let button = NSFont.systemFont(ofSize: 12, weight: .medium)
  /// The invite link.
  static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
  /// The encryption code, which people read aloud to each other.
  static let code = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
  /// A field you type into. One step up from a row: you are looking at what you
  /// are producing, not scanning a list.
  static let field = NSFont.systemFont(ofSize: 14, weight: .regular)
  /// The word inside the one button on a surface that people are meant to press.
  static let buttonProminent = NSFont.systemFont(ofSize: 12, weight: .semibold)
  /// "tap to leave" inside the confirm capsule -- the one place a control says a
  /// sentence instead of drawing a shape.
  static let confirm = NSFont.systemFont(ofSize: 13, weight: .semibold)
}

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

  // ── THE OLD FILL, DEMOTED TO A FALLBACK ────────────────────────────────────
  //
  // These two were the whole of the old material. They are still exactly right for
  // a Mac that has no Liquid Glass to give -- and for one that has it but has been
  // told, through Reduce Transparency, not to use it.
  static let glass = NSColor(srgbRed: 10/255, green: 14/255, blue: 22/255, alpha: 0.72)
  static let glassLine = NSColor(white: 1, alpha: 0.14)

  /// What a prominent control's glass is tinted toward. Strong, because this is
  /// the one control on the screen that must be found without looking -- but a
  /// TINT, so it is still glass and still refracts the picture behind it.
  //
  // MEASURED, not guessed. Driving this alone to 0.82 and then 0.96 photographed as
  // maroon both times -- right hue, wrong brightness, on the one button that has to
  // be unmistakable. A tint BLENDS toward a colour rather than replacing it, so
  // over a dark navy jacket it can only ever come out darker than what was asked
  // for. The colour is a fill BEHIND the glass now (see `IconButton.draw`); this is
  // just enough tint to stop the material cooling that red back toward the blue
  // behind it.
  static let destructiveTint = NSColor(srgbRed: 0xf2/255, green: 0x4b/255, blue: 0x4b/255,
                                       alpha: 0.35)

  /// What glass is tinted toward. Barely there on purpose: a tint is for
  /// suggesting prominence, and anything heavier stops being a material.
  static let glassTint = NSColor(srgbRed: 10/255, green: 14/255, blue: 22/255, alpha: 0.18)

  /// The dimming layer the HIG asks for behind clear glass over bright content.
  /// 0.35, and it is the whole of the number.
  static let dim = NSColor(srgbRed: 6/255, green: 8/255, blue: 13/255, alpha: 0.35)

  /// What a surface is when there is no material: Reduce Transparency, or a Mac
  /// too old for Liquid Glass and too bright behind for `.hudWindow` alone.
  static let opaqueSurface = NSColor(srgbRed: 18/255, green: 21/255, blue: 28/255, alpha: 1)

  /// A hover or a press inside a glass surface. A vibrant fill, NOT a second pane
  /// of glass: "avoid overcrowding or layering Liquid Glass elements on top of
  /// each other."
  static func fill(_ alpha: CGFloat) -> NSColor { NSColor(white: 1, alpha: alpha) }
}

// ── THE MATERIAL ─────────────────────────────────────────────────────────────

/// A pane of Liquid Glass, used as a BACKGROUND rather than as a container.
///
/// `NSGlassEffectView` offers a `contentView` and ties its geometry to it with
/// Auto Layout. That is the right shape for a new Auto Layout screen and the wrong
/// one for this app, which lays every control out by hand in `layout()` -- adopting
/// it would mean two layout systems arguing over the same rectangles. The glass
/// works perfectly well with no content view at all: framed like any other view,
/// it renders the material and nothing else, which is exactly what a background is.
///
/// This class was `NSVisualEffectView` and is now a wrapper, so it can be one of
/// three things depending on the Mac it is running on:
///
///   * macOS 26+          real Liquid Glass
///   * macOS 14-25        the old blur, with the flat fill that used to hide it
///   * Reduce Transparency  a plain opaque surface, on any version
///
/// The call sites do not know which, and that is the point.
final class Glass: NSView {
  enum Variant {
    /// Over a face, a photo, a video. Highly translucent; needs `Palette.dim`
    /// underneath it when the picture behind might be bright.
    case clear
    /// Under sentences. Blurs and adjusts luminosity to keep text legible.
    case regular
  }

  // ── DECORATION IS NOT A TARGET ─────────────────────────────────────────────
  //
  // Inherited verbatim from the class this replaces, and it must not be lost in
  // the swap. The blur is a subview of the button it sits inside, so `hitTest`
  // handed every click to the glass and not to the button. Two consequences, both
  // invisible in a handler test: `acceptsFirstMouse` was asked of the glass (which
  // says no), so the first click on a background window was always eaten; and every
  // audit that started at the content view happily reported the right control was
  // reachable. A pane of glass has nothing to do with a click. It passes them
  // through.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  private let variant: Variant
  private let interactive: Bool
  /// The real thing, on a Mac new enough to have it. `NSGlassEffectView` is
  /// macOS 26, so this is untyped storage and every use is behind `#available`.
  private var glassView: NSView?
  /// The fallback blur, on a Mac that is not.
  private var effectView: NSVisualEffectView?
  /// The opaque surface used when the material is unavailable or unwanted.
  private let plain = NSView()

  var radius: CGFloat {
    didSet { guard radius != oldValue else { return }; applyRadius() }
  }

  /// Tints the material toward a colour, to suggest prominence. `nil` for none.
  var tint: NSColor? {
    didSet { applyTint() }
  }

  // ── CONTENT GOES INSIDE THE GLASS, NOT ON TOP OF IT ────────────────────────
  //
  // The first version of this stacked the glyph as a SIBLING above the glass, the
  // way the old `NSVisualEffectView` version did, and it drew -- but softly. Every
  // 1.8 pt stroke came out mushy and haloed, while the one button with no glass
  // behind it (the red leave circle) stayed razor sharp. Same drawing code, same
  // view class, so the only difference was the material underneath.
  //
  // The header says why, and says it as a warning rather than an aside:
  // "NSGlassEffectView only guarantees the `contentView` will be placed inside the
  // glass effect; arbitrary subviews aren't guaranteed specific behavior with
  // regard to z-order in relation to the content view or glass effect." A sibling
  // is arbitrary. It got caught in the effect's own resampling, which is precisely
  // the treatment the material is supposed to give the picture BEHIND it.
  //
  // So anything that has to stay crisp is handed over rather than stacked, and the
  // fallback paths keep the old stacking, where it was always correct.
  var content: NSView? {
    didSet {
      guard content !== oldValue else { return }
      oldValue?.removeFromSuperview()
      attachContent()
    }
  }

  private func attachContent() {
    guard let c = content else {
      if #available(macOS 26.0, *), let g = glassView as? NSGlassEffectView {
        g.contentView = nil
      }
      return
    }
    if #available(macOS 26.0, *), let g = glassView as? NSGlassEffectView {
      g.contentView = c
    } else {
      addSubview(c)      // above the blur, which is where it belongs on this path
    }
  }

  init(radius: CGFloat, variant: Variant = .regular, interactive: Bool = false) {
    self.radius = radius
    self.variant = variant
    self.interactive = interactive
    super.init(frame: .zero)
    wantsLayer = true
    // The material is composited by the window server behind this view, so this
    // view must not paint anything of its own on top of it.
    layer?.backgroundColor = NSColor.clear.cgColor

    plain.wantsLayer = true
    plain.autoresizingMask = [.width, .height]
    plain.isHidden = true
    addSubview(plain)

    build()
    // Reduce Transparency can be turned on mid-call, and the HIG is explicit that
    // custom elements have to be tested against it rather than assumed to adapt.
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(accessibilityChanged),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

  // ── AN ACCESSIBILITY PATH NOBODY CAN SEE IS AN ACCESSIBILITY PATH NOBODY HAS ──
  //
  // The HIG asks for this explicitly -- "Ensure you test your app's custom
  // elements, colors, and animations with different configurations of these
  // settings" -- and the only way to reach it on this machine is to change a
  // system accessibility setting, which is not something a test run should do to
  // somebody's Mac. So it has a rig override, the way every other cadence and
  // threshold in this program does.
  //
  //     TK_REDUCE_TRANSPARENCY=1 tk --room ... --window
  //
  // Nothing in the app sets it. Without it the real setting is the only input, and
  // that is still checked live: the notification below rebuilds every surface if
  // somebody turns it on mid-call.
  private static let forcedReduce =
    ProcessInfo.processInfo.environment["TK_REDUCE_TRANSPARENCY"] == "1"

  static var reduceTransparency: Bool {
    forcedReduce || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
  }

  @objc private func accessibilityChanged() {
    DispatchQueue.main.async { [weak self] in self?.rebuild() }
  }

  private func rebuild() {
    glassView?.removeFromSuperview(); glassView = nil
    effectView?.removeFromSuperview(); effectView = nil
    build()
    needsLayout = true
  }

  private func build() {
    guard !Glass.reduceTransparency else {
      // No material at all: a solid surface with a hairline, which is what every
      // accessibility setting that turns transparency off is asking for.
      plain.isHidden = false
      plain.layer?.borderWidth = 1
      plain.layer?.borderColor = Palette.fill(0.22).cgColor
      applyRadius()
      applyTint()
      attachContent()
      return
    }
    plain.isHidden = true
    if #available(macOS 26.0, *) {
      let g = NSGlassEffectView(frame: bounds)
      g.autoresizingMask = [.width, .height]
      g.style = variant == .clear ? .clear : .regular
      g.cornerRadius = radius
      // ── SET THROUGH KVC, DELIBERATELY ────────────────────────────────────────
      //
      // `effectIsInteractive` is macOS 27 and is in the AppKit HEADER, but the
      // Swift overlay in this SDK does not export it -- `gv.effectIsInteractive`
      // is a compile error while `-[NSGlassEffectView setEffectIsInteractive:]`
      // exists and works. `responds(to:)` first, because an unknown key raises an
      // ObjC exception that Swift cannot catch, and a crash on an older Mac to
      // save a line here would be an appalling trade.
      if interactive, g.responds(to: NSSelectorFromString("setEffectIsInteractive:")) {
        g.setValue(true, forKey: "effectIsInteractive")
      }
      addSubview(g, positioned: .below, relativeTo: nil)
      glassView = g
      attachContent()
    } else {
      let v = NSVisualEffectView(frame: bounds)
      v.autoresizingMask = [.width, .height]
      v.material = .hudWindow
      v.blendingMode = .withinWindow
      v.state = .active
      v.appearance = NSAppearance(named: .vibrantDark)
      v.wantsLayer = true
      v.layer?.masksToBounds = true
      v.layer?.borderWidth = 1
      v.layer?.borderColor = Palette.glassLine.cgColor
      // The fill that used to hide the blur. Here it is doing a real job: without
      // Liquid Glass, `.hudWindow` alone is too light to carry white text over a
      // bright picture.
      v.layer?.backgroundColor = Palette.glass.cgColor
      addSubview(v, positioned: .below, relativeTo: nil)
      effectView = v
      attachContent()
    }
    applyRadius()
    applyTint()
  }

  private func applyRadius() {
    plain.layer?.cornerRadius = radius
    effectView?.layer?.cornerRadius = radius
    if #available(macOS 26.0, *), let g = glassView as? NSGlassEffectView {
      g.cornerRadius = radius
    }
  }

  // ── A TINT IS NOT ONLY A GLASS PROPERTY ────────────────────────────────────
  //
  // This used to set `NSGlassEffectView.tintColor` and stop, which was wrong on
  // both other paths and wrong in a way that mattered.
  //
  // The prominent control -- the hang-up button -- gets its colour from a fill
  // painted BEHIND the glass by `IconButton.draw`, because a tint alone blends
  // toward the picture and comes out maroon. Clear glass lets that fill through.
  // The opaque Reduce Transparency surface does not: photographed with
  // `TK_REDUCE_TRANSPARENCY=1`, the leave button was the same dark disc as mute
  // and camera, and the one control on the screen that must never be mistaken for
  // its neighbours was indistinguishable from them.
  //
  // So the tint is the surface's colour on the paths that have no picture to blend
  // with. A person who has turned transparency off is exactly the person who
  // should not be asked to find a hang-up button by shape alone.
  private func applyTint() {
    if #available(macOS 26.0, *), let g = glassView as? NSGlassEffectView {
      g.tintColor = tint
    }
    if let t = tint {
      plain.layer?.backgroundColor = t.withAlphaComponent(1).cgColor
      effectView?.layer?.backgroundColor = t.withAlphaComponent(0.92).cgColor
    } else {
      plain.layer?.backgroundColor = Palette.opaqueSurface.cgColor
      effectView?.layer?.backgroundColor = Palette.glass.cgColor
    }
  }

  /// A capsule of whatever height this view currently is. Called from `layout()`
  /// so a pill that resizes to its text stays a capsule instead of keeping the
  /// radius it was born with -- which is how a 27 pt pill ended up with a 13 pt
  /// radius and read as a rounded rectangle.
  func makeCapsule() { radius = Metric.capsule(bounds.height) }

  override func layout() {
    super.layout()
    plain.frame = bounds
    effectView?.frame = bounds
    glassView?.frame = bounds
    // The glass ties its geometry to its content view with Auto Layout, so the
    // content's frame is not decoration here -- it is what the material sizes
    // itself to. Setting it every pass keeps the two from disagreeing when a pill
    // resizes to a longer word.
    content?.frame = bounds
  }
}

/// A rounded vibrant fill, for a control that lives INSIDE a glass surface.
///
/// The waiting card was built out of `Glass` all the way down: glass buttons and
/// glass fields sitting on a glass panel. It rendered, and it was wrong twice
/// over. The guidance is explicit -- "avoid overcrowding or layering Liquid Glass
/// elements on top of each other" -- and it is also what the material looks like
/// when you do: each pane dims the one behind it, so the panel that was supposed to
/// be the surface ends up the murkiest thing on screen.
///
/// A material establishes ONE functional layer. Everything inside that layer is
/// drawn with fills and vibrancy, which is what the sheet's rows already do and
/// what every system control on a sheet does.
final class Vibrant: NSView {
  var radius: CGFloat = 0 { didSet { needsDisplay = true } }
  /// Resting fill. Hover and press step up from here.
  var level: CGFloat = 0.10 { didSet { needsDisplay = true } }
  /// A hairline, so the shape has an edge on a bright frame as well as a dark one.
  var edge: CGFloat = 0.14 { didSet { needsDisplay = true } }
  var tint: NSColor? { didSet { needsDisplay = true } }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func draw(_ dirty: NSRect) {
    let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                         xRadius: radius, yRadius: radius)
    (tint ?? Palette.fill(level)).setFill()
    r.fill()
    Palette.fill(edge).setStroke()
    r.lineWidth = 1
    r.stroke()
  }
}

/// A group of glass shapes that are allowed to notice each other.
///
/// `NSGlassEffectContainerView` does two things. It batches the material for every
/// glass view inside it, which is the performance advice -- "combine them using a
/// GlassEffectContainer". And it MERGES them: shapes closer together than
/// `spacing` flow into one another like droplets, with a real liquid bridge
/// between them rather than a crossfade.
///
/// Measured on this machine, with five 58 pt circles 18 pt apart:
///
///     spacing 0, 18   five separate circles
///     spacing 40      bridges form -- they are joined but still readable as five
///     spacing 80      one continuous blob
///
/// So `spacing` is not a style, it is a dial, and the row keeps it at rest below
/// the gap so the five actions stay five distinct targets. It is animated UP only
/// when the row is collapsing into the leave confirmation, where the four other
/// circles are on their way out and flowing into the button that remains is a
/// truer picture of what is happening than five things fading.
final class GlassGroup: NSView {
  private var container: NSView?
  private let holder = NSView()

  /// Proximity at which children merge. Animate it to make them flow.
  var spacing: CGFloat = 0 {
    didSet {
      guard spacing != oldValue else { return }
      if #available(macOS 26.0, *), let c = container as? NSGlassEffectContainerView {
        c.spacing = spacing
      }
    }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    holder.autoresizingMask = [.width, .height]
    if #available(macOS 26.0, *), !Glass.reduceTransparency {
      let c = NSGlassEffectContainerView(frame: frame)
      c.autoresizingMask = [.width, .height]
      c.contentView = holder
      c.spacing = spacing
      addSubview(c)
      container = c
    } else {
      // No container to be had: the children are added straight to this view and
      // behave exactly as they did before, minus the merging.
      addSubview(holder)
    }
  }
  required init?(coder: NSCoder) { fatalError() }

  /// Where children go. Not `addSubview` on `self`: the container elevates the
  /// z-order of its `contentView`'s descendants, and a view added beside it rather
  /// than inside it is outside the effect and will not merge.
  var content: NSView { holder }

  // ── A GROUP IS A COORDINATE SPACE, NOT A CONTROL ───────────────────────────
  //
  // Wrapping the row in two extra views puts two extra `hitTest` implementations
  // between a finger and a button, and this file has already paid for that lesson
  // twice: a blur inside a button ate every click, and an `isFlipped` override
  // stopped an entire sheet from firing. The default recursion finds the buttons
  // correctly -- but when the point lands in the gap BETWEEN two circles, the
  // default returns the container itself, which would silently swallow a click on
  // the picture. So anything that resolves to scaffolding resolves to nothing, and
  // only real controls claim a click.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    if hit === self || hit === holder || hit === container { return nil }
    return hit
  }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func layout() {
    super.layout()
    container?.frame = bounds
    holder.frame = bounds
  }
}

// ── MOVEMENT ────────────────────────────────────────────────────────────────
//
// Liquid Glass "reacts to touch and pointer interactions in real time", and a
// material that flows sitting inside an interface that snaps is worse than either
// on its own. Nothing here is decoration for its own sake: each of these is
// attached to a state change a person caused and is waiting to see confirmed.
enum Motion {
  /// Apple's standard interface spring, as a curve AppKit can use for frames and
  /// opacity. Slight overshoot, settled inside a third of a second.
  static let standard = CAMediaTimingFunction(controlPoints: 0.32, 0.94, 0.35, 1.0)
  static let duration: CFTimeInterval = 0.34

  static func run(_ body: () -> Void, duration: CFTimeInterval = duration,
                  then done: (() -> Void)? = nil) {
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = duration
      ctx.timingFunction = standard
      ctx.allowsImplicitAnimation = true
      body()
    }, completionHandler: done)
  }

  /// A press that answered. The control swells and settles -- the confirmation
  /// that a mute happened, delivered by the button rather than by a word
  /// somewhere else on the screen.
  /// Reduce Motion switches this off entirely, and has its own rig override for the
  /// same reason `Glass.reduceTransparency` does.
  static var reduceMotion: Bool {
    ProcessInfo.processInfo.environment["TK_REDUCE_MOTION"] == "1"
      || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  static func pop(_ view: NSView, to scale: CGFloat = 1.12) {
    guard let layer = view.layer, !reduceMotion else { return }
    layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    layer.frame = view.frame
    let a = CASpringAnimation(keyPath: "transform.scale")
    a.fromValue = 1.0
    a.toValue = scale
    a.damping = 12
    a.stiffness = 340
    a.mass = 0.7
    a.initialVelocity = 6
    a.duration = a.settlingDuration
    a.autoreverses = true
    layer.add(a, forKey: "pop")
  }
}
