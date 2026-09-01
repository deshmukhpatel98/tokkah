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
//      backgrounds." Every surface in this app appears over one -- the content of
//      this app IS a live camera feed -- so EVERY surface is `.clear`. There is no
//      second variant and no parameter to choose one with.
//
//      That is a decision, not a reading of the guidance, and the guidance says
//      the opposite about half of it: `.regular` is what Apple names for "alerts,
//      sidebars, or popovers", and the sheet and the waiting card are that kind of
//      thing. The person whose app this is looked at the card that says who they
//      are calling -- a milky slab with a face somewhere behind it -- and said:
//      "everywhere I want transparent liquid glass, not frosted." Their preference
//      wins. See rule 3 for what happens to the problem `.regular` was solving,
//      because the problem is real and it does not go away by being overruled.
//
//      HOW IT DRIFTED, because the shape of this is worth more than the fix. The
//      paragraph that used to be here said "the control row is `.clear`" and it
//      was TRUE of the control row -- `IconButton` defaults to it. It was false of
//      everything else, and nothing ever said so: ten surfaces, nine of them
//      spelling `.regular` at the call site, under a header that read as though the
//      choice had been made per surface with a reason. A comment describing a
//      policy is not the policy. So `describeGlass` and `glass-check.sh` exist:
//      every surface now STATES what it is, out loud, into the log, and a rig
//      compares that against the policy in this comment. A claim in here that the
//      code does not implement is now a failing test rather than a paragraph.
//
//   3. "If the underlying content is bright, consider adding a dark dimming layer
//      of 35% opacity." This app takes the 35% and REFUSES THE LAYER, and the
//      distinction is the most important sentence in this file.
//
//      Read literally, the guidance is about a dimming layer between content and
//      glass, and it does not say how big one should be. This app answered "as big
//      as the window" four separate times: a 190 pt gradient up from the bottom
//      edge, a 130 pt one down from the top, a window-wide radial ellipse behind
//      the waiting card, and a 62% one over the join window's camera preview.
//      Every one of them was argued for in a comment, every one cited this rule,
//      and together they were a vignette. The person using the app said so: "there
//      should be no vignette of any kind. There should not be any effect. It
//      should all be very natural." They were not looking at a legibility device.
//      They were looking at a video of somebody whose chin and corners were darker
//      than their nose, and reading it as the picture being broken.
//
//      So the rule here is stricter than the HIG's and easy to check: THE PICTURE
//      GETS NOTHING. No gradient, no scrim, no wash, no drop shadow spilling off a
//      control onto a face. The only dimming device left in the app is
//      `Glass.dim`, whose bounds are exactly the bounds of the control it belongs
//      to -- a rounded rectangle you can point at, that stops at its own corners.
//      A dark patch the size of a button is part of the button. A dark patch the
//      size of the window is something painted on the person.
//
//      UNDER, not in or over, and the preposition is the other half of the idea. A
//      dark layer over the glass, or a dark tint IN the glass, is paint -- what the
//      old `Glass` did with `rgba(10,14,22,.72)` and what the card in the
//      screenshot was still doing with `glassTint` at 0.18 on top of `.regular`.
//      Paint does not refract. A dim UNDER clear glass darkens the patch of
//      picture that the material then refracts, so the words on it are legible and
//      the picture is still visibly there, moving, through them.
//
//      The cost is real and is not hidden: the bar circles used to take their
//      contrast from the bottom scrim and now carry it themselves, so the total
//      darkness at a button is about what it was -- and the face between the
//      buttons, which used to be under 35% of black, is now the camera's own
//      pixels and nothing else.
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
  /// Where a row's words start when a 18 pt glyph sits in front of them. It was a
  /// bare 42 inside `SheetRow.layout`, and the day a row wanted a WIDER mark than a
  /// glyph there was no name to move.
  static let rowGlyphInset: CGFloat = 42
  /// The same, for a row whose mark is a 34 pt face rather than an 18 pt glyph.
  /// Not `rowGlyphInset + something`: it is the glyph inset's own arithmetic --
  /// 12 pt of edge, the mark, 10 pt of air -- run again at the larger size.
  static let rowAvatarInset: CGFloat = 56

  /// A person, as a circle. 34 in a 48 pt row leaves 7 pt above and below, which
  /// is what stops a column of faces from reading as a solid bar of colour.
  static let avatar: CGFloat = 34
  /// The ring that carries the hue. Thin, because the colour is an identifier and
  /// not a status light -- see the note over `Palette.avatarInk`.
  static let avatarRing: CGFloat = 1.5
  // ── THE SAME FACE, THE SIZE THE MOMENT DESERVES ────────────────────────────
  //
  // 34 is a face in a list. On the card that names who is calling, the person IS
  // the content of the screen -- there is one name on it and nothing else -- so it
  // is drawn at the size a portrait would be. Everything about it is otherwise the
  // 34 pt one, scaled: same fill, same ring, same colour, same letter.
  static let faceBig: CGFloat = 64
  static let faceBigRing: CGFloat = 2

  /// The waiting card: one panel holding the whole invite, rather than four
  /// controls floating separately over a face.
  static let cardRadius: CGFloat = 30
  static let cardPad: CGFloat = 22
  /// A field inside the card, near its edge -- so concentric with it, not a
  /// number. At a 36 pt field this resolves to a capsule anyway, which is the
  /// answer both rules agree on.
  static var cardFieldRadius: CGFloat { concentric(cardRadius, inset: cardPad) }

  /// The caption band. Not concentric with anything -- it floats in the middle of
  /// the window rather than nesting into a corner -- so it gets its own number,
  /// one step softer than the sheet because it holds nothing but a sentence and
  /// has no edge to define.
  static let captionRadius: CGFloat = 22

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
  /// The one letter inside a contact's circle. Semibold because it is carrying a
  /// person's identity at 34 points and a regular weight at this size reads as a
  /// label that happened to land in a ring.
  static let avatar = NSFont.systemFont(ofSize: 15, weight: .semibold)
  /// The initial inside `Metric.faceBig`, in proportion with the 15 pt one.
  static let avatarBig = NSFont.systemFont(ofSize: 28, weight: .semibold)
  // ── ONE STEP ABOVE `title`, AND ONLY FOR A PERSON'S NAME ──────────────────
  //
  // 17 was the largest thing in this app because nothing in it was ever the whole
  // point of a screen. A name on the calling card is: strip the explanatory
  // sentence away and the card is a face, a name, and what you can do about it.
  // At 17 the name read as a caption for the buttons underneath rather than as the
  // subject of the card.
  static let name = NSFont.systemFont(ofSize: 22, weight: .semibold)

  // ── THE OTHER PERSON'S VOICE, AS TEXT ──────────────────────────────────────
  //
  // Bigger than every other size in this file, and deliberately. A caption is
  // read from wherever you happen to be sitting, at a glance, WHILE you are
  // listening to somebody else -- so it gets the size a subtitle gets and not the
  // size a label gets. 16 is what Apple's own Live Captions uses; 13 (`row`) was
  // legible at a desk and unreadable from a sofa.
  static let said = NSFont.systemFont(ofSize: 16, weight: .medium)
  // `saidMine` was here: the same words at 13 pt, for the right-aligned half of
  // the caption band that showed you your OWN speech while you were the quiet
  // one. That half is gone -- the subtitle rule is that a voice which cannot be
  // heard is read on the OTHER screen, so your words never belong on yours, and
  // the only caller left was passing "". The band is one voice now and this was
  // the last reference to this size.
  /// "mm-hmm". One word, appears, fades. It is not a caption -- it is the sound
  /// somebody makes to tell you they are still with you, and it should feel like
  /// that: large, brief, and gone before you finish the sentence you were on.
  static let bloom = NSFont.systemFont(ofSize: 30, weight: .semibold)
}

enum Palette {
  static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: a)
  }
  static let fg = hex(0xe8eaed)
  // ── THE SECONDARY INK, RAISED, BECAUSE IT WAS FAILING ITS ONE JOB ─────────
  //
  // This was `0x9aa4b2`, which is the web app's `--muted` and was chosen against a
  // near-black page. It is used for exactly three things and all three are
  // SENTENCES A PERSON READS: the sheet's hints, the secondary word on a row, and
  // the caption under the waiting card's title.
  //
  // Measured: relative luminance 0.368. Against a glass panel dimmed for a bright
  // picture, which lands around 0.175, that is 1.86:1 -- the guidelines ask 4.5:1
  // for text this size and the hint under "Calls when Kin is closed" photographed
  // as grey-on-grey, which is what it looked like on a real call.
  //
  // 0xc3ccd8 is luminance 0.598. Against the darker ground text-bearing surfaces
  // now ask for (`Glass.wantLuma` 0.26 -> about 0.05) that is 6.4:1, and against
  // the old dark-room ground it is 10.8:1. Still visibly a step below `fg`, which
  // is the whole point of having two inks.
  static let muted = hex(0xc3ccd8)
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

  // ── THE TINT THAT WAS HALF THE FROSTING ────────────────────────────────────
  //
  // `glassTint` -- 10,14,22 at 0.18 -- used to be set on the sheet, the waiting
  // card and the join card, and it is gone. It was described in here as "barely
  // there on purpose", and on its own it nearly was. It was not on its own: it sat
  // on `.regular`, so the card that says who you are calling was a luminosity
  // adjustment plus a blur plus a dark wash IN the material, over a 0.55 gradient.
  // Four dimming devices stacked, three of them invisible in the source of any one
  // of them.
  //
  // A tint is still the right tool for the one thing the HIG names it for --
  // "assign a tint color to suggest prominence" -- which is `destructiveTint`
  // above, on the one button that must never be mistaken for its neighbours. It is
  // not a legibility tool. Legibility is `Glass.dim`, which goes UNDER.

  // ── THE DIM, AS A NUMBER AND AN INK, AND NEVER AS A COLOUR ─────────────────
  //
  // `static let dim = rgba(6,8,13,0.35)` used to be here, and it is deleted rather
  // than left unused. It was the colour four `CAGradientLayer`s were built out of,
  // and a pre-mixed 35%-transparent dark is a thing you can only really do one
  // thing with: paint it over an area. Leaving it in the palette leaves the next
  // gradient across somebody's face one line away, which is how this one lasted.
  //
  // What is left is an alpha and an opaque ink, which is what a LAYER needs -- and
  // a layer has bounds, which is the whole point (see rule 3 in the header).

  /// The HIG's dimming number, and it is the whole of the number. Every surface
  /// that needs it asks by this name rather than typing 0.35, so there is one place
  /// to turn if the answer ever changes.
  static let dimAlpha: CGFloat = 0.35
  /// The same ink at full strength. A `CALayer` carries its own `opacity`, so the
  /// alpha belongs to the layer and not to the colour -- otherwise a surface asking
  /// for half the dim would get 0.35 x 0.5 and nobody would notice which.
  static let dimInk = NSColor(srgbRed: 6/255, green: 8/255, blue: 13/255, alpha: 1)

  /// What a surface is when there is no material: Reduce Transparency, or a Mac
  /// too old for Liquid Glass and too bright behind for `.hudWindow` alone.
  static let opaqueSurface = NSColor(srgbRed: 18/255, green: 21/255, blue: 28/255, alpha: 1)

  /// A hover or a press inside a glass surface. A vibrant fill, NOT a second pane
  /// of glass: "avoid overcrowding or layering Liquid Glass elements on top of
  /// each other."
  static func fill(_ alpha: CGFloat) -> NSColor { NSColor(white: 1, alpha: alpha) }

  /// The hairline round a chip -- a word on a row that can be PRESSED. A bare grey
  /// word pinned to the right of a row is the same treatment as a timestamp, and
  /// "copy" was drawn exactly like "yesterday": nothing on the screen said which
  /// of the two did something.
  static let chipLine = NSColor(white: 1, alpha: 0.28)
  /// A switch that is on. Green is what every switch on this machine is when it is
  /// on, and a setting whose state has to be read as a WORD is a setting people get
  /// wrong -- "only when open" was the whole of what the front door said about
  /// whether anyone could reach this Mac.
  static let switchOn = hex(0x30d158)
  static func switchOff() -> NSColor { NSColor(white: 1, alpha: 0.22) }

  // ── A SELECTION THAT CAN BE READ ON DARK GLASS ─────────────────────────────
  //
  // The rename page pre-fills the field and selects it, so typing replaces the old
  // name -- which is the right default and made the one thing in the app you type
  // into unreadable. Photographed over a bright picture: `devesh`, selected, as
  // grey letters on a grey block inside a dimmed glass well.
  //
  // The system selection is drawn with the accent colour, and the app has no say
  // in what that is: somebody on a yellow accent gets white text on yellow. So the
  // field editor is given its own pair, chosen so the arithmetic holds whatever the
  // person's accent is. #1d4ed8 is relative luminance 0.13; white on it is 7.0:1.
  static let selectionFill = hex(0x1d4ed8)
  /// The caret. `Palette.fg` on the well, because a caret the colour of the text is
  /// what every text field on this machine has -- and on dark glass the system
  /// default is nearly invisible.
  static let caret = fg

  // ── A PERSON'S COLOUR, DERIVED FROM THEIR NAME ─────────────────────────────
  //
  // A contact has no photograph and never will -- nothing in this app has ever
  // sent one -- so the circle has to be recognisable from the handle alone. That
  // means the colour must be the SAME colour on every launch, on both Macs, for
  // ever.
  //
  // FNV-1a, and not `String.hashValue`: Swift's `Hasher` is seeded per process, so
  // the same person would be a different colour every time the app started -- and,
  // worse, stable WITHIN a session, so it would test green on this machine and
  // only ever be reported from the field. Not SHA-256 either: correct, and it
  // drags CryptoKit into a drawing path for a value that needs nine bits.
  //
  // 22 buckets at 15 degrees rather than 360 free hues, because two contacts should
  // either share a colour or be visibly different. Four degrees apart reads as a
  // rendering fault, not as two people.
  //
  // Steps 0 and 23 are dropped, which removes 345-15 degrees. `Palette.bad` is hue
  // ~0 and `leave` is the only filled control on the screen; a red circle beside
  // the hang-up is exactly the mistake this file already refused once. Dropping two
  // buckets is cheaper than a rotate-if-inside-the-band special case.
  //
  // From the HANDLE, never from a local nickname. Renaming somebody must not
  // change their colour or the recognition the circle exists for is destroyed.
  static func avatarHue(_ handle: String) -> CGFloat {
    var h: UInt32 = 2166136261
    for b in handle.lowercased().utf8 { h = (h ^ UInt32(b)) &* 16777619 }
    return CGFloat(((h % 22) + 1) * 15)
  }

  // ── THE HUE LANDS ON THE RING AND THE LETTER, NOT ON A FILLED DISC ─────────
  //
  // A filled coloured disc with white text does not work, and it is arithmetic
  // rather than taste. At S 0.62 / B 0.80, white on the blue end measures 6.4:1 and
  // white on hue 60 (yellow) measures 1.71:1 -- illegible. One fixed
  // saturation/brightness cannot carry white text across the wheel, and solving for
  // constant luminance per hue is a numerical search inside a `draw` call.
  //
  // So the colour is the ring and the initial, and the disc stays a fill. That is
  // also this app's own rule one row up: OFF does not fill a circle red, it turns
  // the GLYPH red and leaves the surface alone.
  //
  // `NSColor(hue:saturation:brightness:)` is in the CALIBRATED space and every
  // other colour in this file is `srgbRed:`. Without the conversion the avatars
  // drift away from the palette on a wide-gamut display, and this Mac has one.
  static func avatarInk(_ handle: String) -> NSColor {
    let c = NSColor(hue: avatarHue(handle) / 360, saturation: 0.55, brightness: 0.98, alpha: 1)
    return c.usingColorSpace(.sRGB) ?? accent
  }
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
  // ── THERE IS NO VARIANT ────────────────────────────────────────────────────
  //
  // This was `enum Variant { case clear, regular }` and a parameter on every call
  // site. Both are gone, and the deletion is the fix: while there were two, nine
  // of the ten surfaces asked for the frosted one and the header claimed
  // otherwise. A choice that is made the same way every time is not a choice, and
  // leaving the parameter there is leaving the drift a place to happen again.
  //
  // What actually differs between surfaces is `dim` -- how much dark goes UNDER
  // the material -- and that is a real per-surface question with a real per-surface
  // answer, because it depends on whether the thing already sits in a scrim.

  /// What this surface is called in the log. Not decoration: a surface with no name
  /// cannot be asserted about, and the whole reason this file drifted for so long
  /// is that nothing in the running program ever said what it was. See
  /// `describeGlass` and `tools/glass-check.sh`.
  let name: String

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

  private let interactive: Bool
  // ── THE DIM, AND WHY IT IS A LAYER AND NOT A BACKGROUND COLOUR ─────────────
  //
  // `layer?.backgroundColor` on this view is the shape of a defect this file has
  // already paid for once: `urlGlass.layer?.backgroundColor = rgba(8,11,18,.9)`
  // was harmless while `Glass` WAS the blur, and the day it became a wrapper the
  // same line painted a hard-edged opaque rectangle across the material and out
  // past its own corners, because the wrapper's layer is the un-rounded outer box.
  // Invisible in every screenshot, because every screenshot was over black.
  //
  // So the dim is its own layer with its own `cornerRadius`, kept in step with the
  // surface's in `applyRadius`. It is added to THIS view's layer rather than as a
  // subview, which is what puts it underneath: a sublayer of a view's own layer
  // draws below every one of that view's subviews, and the material is a subview.
  private let dimLayer = CALayer()
  /// How much dark goes under the material, 0...1. `Palette.dimAlpha` is the HIG's
  /// number and the answer for anything sitting directly on somebody's face; 0 is
  /// the answer for anything already inside a scrim, because two 0.35 dims stacked
  /// are one 0.58 dim and that is the frosting coming back by another door.
  var dim: CGFloat {
    didSet { guard dim != oldValue else { return }; applyDim() }
  }
  // ── THE DIM IS NOT A CONSTANT ANY MORE ─────────────────────────────────────
  //
  // `dim` is what is on screen right now. `baseDim` is what this surface asked
  // for, and it is the FLOOR: over a dark picture the two are equal and nothing
  // about this app changes. Over a bright one `Backdrop.dim` raises it to
  // whatever that patch of picture needs to carry white text at 4.5:1 -- see
  // `Backdrop.swift`, which has the arithmetic and the arm that has to fail.
  //
  // A surface that asked for no dim keeps none: `Backdrop.dim(base: 0, …)` is 0.
  // That is deliberate rather than incidental. Opting out is how a surface inside
  // another surface's scrim avoids two dims stacking, and a rule that overrode it
  // over bright content would bring the frosting back by the one door this file
  // was written to close.
  private(set) var baseDim: CGFloat
  /// How bright this surface may end up over a bright picture. The default carries
  /// a white glyph; a surface that holds SENTENCES lowers it, because secondary
  /// ink at 11 pt needs a darker ground than a 26 pt stroke does. See
  /// `Backdrop.dim`.
  var wantLuma: CGFloat = 0.42 { didSet { refreshAdaptiveDim() } }
  /// Reported by the audit, so `glass-check.sh` can hold a text surface to the
  /// darker ground rather than the policy living only in a comment.
  var wantsTextGround: Bool { wantLuma < 0.35 }
  /// The backdrop luma this surface last dimmed for, so the audit can say what it
  /// was reacting to rather than only what it did.
  private(set) var backdropLuma: CGFloat = 0

  /// Re-read what is behind this surface and dim for it. Cheap -- one rectangle
  /// against a 144-cell map -- and idempotent, so it is safe to call from `layout`
  /// and from the map's own change notification.
  func refreshAdaptiveDim() {
    guard baseDim > 0, Backdrop.shared.live, let win = window, !bounds.isEmpty else { return }
    guard isEffectivelyVisible else { return }
    let f = convert(bounds, to: nil)
    let size = win.contentView?.bounds.size ?? win.frame.size
    guard size.height > 1 else { return }
    // TOP-LEFT origin: the map is built from a video frame and every image format
    // on this machine counts rows downward while AppKit counts them up.
    let r = CGRect(x: f.minX, y: size.height - f.maxY, width: f.width, height: f.height)
    let l = Backdrop.shared.luma(under: r, in: size)
    backdropLuma = l
    let want = Backdrop.dim(base: baseDim, backdrop: l, want: wantLuma)
    // A tenth of a step of hysteresis. Without it a surface straddling a moving
    // edge -- somebody's shoulder against a window -- re-applies its dim on every
    // publish, and a CALayer opacity change is a compositor pass.
    if abs(want - dim) > 0.02 { dim = want }
  }

  /// Every surface, once, when the map moves. Installed by the first `Glass` built.
  static func refreshAllAdaptiveDim() {
    living = living.filter { $0.g != nil }
    for w in living { w.g?.refreshAdaptiveDim() }
  }
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

  /// `textual: true` for a surface with SENTENCES on it, which needs a darker
  /// ground than one carrying a single white glyph. See `wantLuma`.
  init(_ name: String, radius: CGFloat, dim: CGFloat = Palette.dimAlpha,
       interactive: Bool = false, textual: Bool = false) {
    self.name = name
    self.radius = radius
    // A surface that asked for no dim keeps none: the bar circles sit in the
    // overlay's own gradient, and sweeping them along with the panels would be
    // sweeping two different questions with one number.
    self.dim = dim > 0 ? (Glass.forcedDim ?? dim) : 0
    self.baseDim = self.dim
    self.interactive = interactive
    self.wantLuma = textual ? 0.26 : 0.42
    super.init(frame: .zero)
    wantsLayer = true
    // The material is composited by the window server behind this view, so this
    // view must not paint anything of its own on top of it.
    layer?.backgroundColor = NSColor.clear.cgColor
    // Below the material, and below it because it is a sublayer rather than a
    // subview. Colour at full strength, alpha carried by the layer -- see
    // `Palette.dimInk`.
    dimLayer.backgroundColor = Palette.dimInk.cgColor
    layer?.addSublayer(dimLayer)

    plain.wantsLayer = true
    plain.autoresizingMask = [.width, .height]
    plain.isHidden = true
    addSubview(plain)

    build()
    Glass.living.append(Weak(self))
    // One hook for the whole app, installed by whichever surface is built first.
    // A per-surface observer would be 14 closures fired 5 times a second; this is
    // one walk of a list that is already kept for the audit.
    if Backdrop.onChange == nil { Backdrop.onChange = { Glass.refreshAllAdaptiveDim() } }
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

  /// `TK_GLASS_STYLE=regular` -- the control arm, and nothing else. See the note
  /// over `g.style` in `build()`. Any other value, including absent, is `nil` and
  /// the app is clear.
  @available(macOS 26.0, *)
  static var forcedStyle: NSGlassEffectView.Style? {
    ProcessInfo.processInfo.environment["TK_GLASS_STYLE"] == "regular" ? .regular : nil
  }

  // ── AND THE DIM SWEEPS TOO ─────────────────────────────────────────────────
  //
  // `TK_GLASS_DIM=0.15`. The dim is the one number in this file with two costs
  // pulling opposite ways -- too little and white text over a bright face is
  // unreadable, too much and the surface is the frosted slab this whole change is
  // undoing -- and a number like that should never be chosen by argument. It was
  // 0.35 because the HIG says 0.35, and the HIG is describing a dimming layer
  // under a material you built yourself, not under Apple's own clear glass, which
  // turns out to bring a darkening of its own. Photographed: clear at 0.35 came
  // out DARKER than `.regular` at 0.35, which is the two dims stacking.
  //
  // So the value ships as whatever the sweep in `glass-check.sh` says it should
  // be, and this exists so the sweep can be re-run in a minute rather than by
  // rebuilding six times.
  static let forcedDim: CGFloat? = {
    guard let s = ProcessInfo.processInfo.environment["TK_GLASS_DIM"],
          let v = Double(s) else { return nil }
    return CGFloat(max(0, min(1, v)))
  }()

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
      applyDim()
      attachContent()
      return
    }
    plain.isHidden = true
    if #available(macOS 26.0, *) {
      let g = NSGlassEffectView(frame: bounds)
      g.autoresizingMask = [.width, .height]
      // ── ALWAYS `.clear`, AND THE ONE WAY TO GET ANYTHING ELSE IS A RIG ──────
      //
      // The product has no way to ask for `.regular`. There is no parameter, no
      // per-surface choice and no branch on anything the app knows: rule 2 in the
      // header is transparent glass everywhere, and the legibility half of what
      // `.regular` was doing is `dimLayer`, one layer underneath.
      //
      // `TK_GLASS_STYLE=regular` is the arm that has to rank the other way, and
      // without it the whole check is decoration. `glass-check.sh` asserts that
      // every surface reports `style=clear` -- and a reader that had been wired to
      // a constant, or to the argument rather than the object, would pass that
      // assertion on an app that was entirely frosted. So the rig runs this once
      // and requires the audit to say `regular`, and requires the photograph to
      // measurably lose the picture. An instrument that cannot see the defect
      // returns the same value as a clean bill of health.
      //
      // Nothing in the app sets it, and it is read once at build time from the
      // environment, so no code path in the product can reach it.
      g.style = Glass.forcedStyle ?? .clear
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
    applyDim()
  }

  private func applyRadius() {
    plain.layer?.cornerRadius = radius
    effectView?.layer?.cornerRadius = radius
    dimLayer.cornerRadius = radius
    if #available(macOS 26.0, *), let g = glassView as? NSGlassEffectView {
      g.cornerRadius = radius
    }
  }

  // ── ONLY UNDER THE REAL MATERIAL ───────────────────────────────────────────
  //
  // The other two paths carry their own darkness already -- `Palette.glass` at
  // 0.72 behind the old blur, and an opaque surface under Reduce Transparency --
  // and a dim under either of those is a layer nobody can see. Worse, it would be
  // a layer nobody can see that still shows up in `describeGlass`, so the audit
  // would report a dimming device that is doing nothing. An instrument reporting a
  // thing that is not happening is the failure this whole file is a response to.
  private func applyDim() {
    let live: Bool
    if #available(macOS 26.0, *) { live = glassView != nil } else { live = false }
    dimLayer.isHidden = !live || dim <= 0
    dimLayer.opacity = Float(max(0, min(1, dim)))
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
    // A layer is not a view: nothing resizes it for us, and there is no
    // `autoresizingMask` to lean on. Left out, the dim keeps the zero frame it was
    // born with and every surface is transparent, legible over black, and
    // unreadable over a face -- which is a bug that only appears over content, and
    // this file has a whole section on instruments that cannot see content.
    // Without the transaction it also ANIMATES its way to each new frame, so a
    // resizing pill trails a dark rectangle behind itself for a third of a second.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    dimLayer.frame = bounds
    CATransaction.commit()
    // A surface that just moved is over a different patch of picture. Asked here
    // rather than only on the map's own tick, or a panel would open with the dim
    // that suited wherever it used to be.
    refreshAdaptiveDim()
    // The glass ties its geometry to its content view with Auto Layout, so the
    // content's frame is not decoration here -- it is what the material sizes
    // itself to. Setting it every pass keeps the two from disagreeing when a pill
    // resizes to a longer word.
    content?.frame = bounds
  }

  // ── EVERY SURFACE SAYS WHAT IT IS ──────────────────────────────────────────
  //
  // The header claimed a material policy for months while the code implemented a
  // different one, and nothing could catch it because nothing in the running
  // program ever stated which material it had asked for. A screenshot cannot:
  // frosted-over-a-face and clear-over-a-dim are a judgement call at a glance, and
  // "looks about right" is what let this run.
  //
  // So this is the structural half of the proof, and `tools/glass-check.sh` reads
  // it. Every field is read off the LIVE object -- `g.style`, the layer that is
  // actually in the tree -- and never off the constructor arguments, because the
  // argument is the claim and the object is the fact. `fill` is the one that
  // matters most: an opaque colour behind Liquid Glass is the exact recipe for the
  // milky slab in the screenshot that started this, and it is what the old `Glass`
  // did for its entire life.
  private final class Weak { weak var g: Glass?; init(_ g: Glass) { self.g = g } }
  /// Main thread only -- every `Glass` is built during layout and read during the
  /// `?` audit, both on main. No Swift collection in this program is ever touched
  /// from two threads; the last one that was took the process down from a render
  /// callback.
  private static var living: [Weak] = []

  static func describeAll() -> [String] {
    living = living.filter { $0.g != nil }
    return living.compactMap { $0.g?.describeGlass }
  }

  var describeGlass: String {
    var path = "none", fill = "none", style = "-"
    if !plain.isHidden {
      path = "plain"
      fill = Glass.describeFill(plain.layer?.backgroundColor)
    } else if #available(macOS 26.0, *), let g = glassView as? NSGlassEffectView {
      path = "liquid"
      style = g.style == .clear ? "clear" : "regular"
      // Two layers can carry a fill on this path and both would frost it: the
      // material's own, and this wrapper's -- which is the un-rounded outer box and
      // the shape of a defect already found here once.
      fill = Glass.describeFill(g.layer?.backgroundColor, layer?.backgroundColor)
    } else if effectView != nil {
      path = "blur"
      fill = Glass.describeFill(effectView?.layer?.backgroundColor)
    }
    let d = dimLayer.isHidden ? 0 : CGFloat(dimLayer.opacity)
    return "\(name): path=\(path) style=\(style)"
      + " dim=\(String(format: "%.2f", d))"
      + " base=\(String(format: "%.2f", baseDim))"
      + " want=\(String(format: "%.2f", wantLuma))"
      + " behind=\(String(format: "%.2f", backdropLuma))"
      + " tint=\(tint == nil ? "none" : String(format: "%.2f", tint?.alphaComponent ?? 0))"
      + " fill=\(fill) ink=\(contrastRatios) \(whereItIs()) shown=\(isEffectivelyVisible)"
  }

  // ── WHAT THE TEXT ON THIS SURFACE MEASURES AT ──────────────────────────────
  //
  // The photometric half of the legibility check needs a camera, a calibrated
  // background and a Mac nobody is using. This is the arithmetic half, and it is
  // available on every surface on every frame: the backdrop this surface last read
  // and the dim it chose are enough to say what its ground is, and therefore what
  // the two inks on it come to.
  //
  // Reported as two ratios -- `fg` (a white glyph or a heading) and `muted` (a
  // hint) -- so a rig can assert 4.5:1 without photographing anything, and so a
  // surface that is legible over black and illegible over a window says so in the
  // log rather than in a screenshot somebody has to look at.
  //
  // Gamma in, relative luminance out: the map is in the video's own gamma-encoded
  // scale, and the WCAG ratio is defined on linear luminance. `^2.2` is close
  // enough for a diagnostic and avoids a piecewise sRGB curve in a log line.
  var contrastRatios: String {
    guard baseDim > 0 else { return "-" }
    let ground = pow(max(0, min(1, backdropLuma * (1 - dim) + 0.03 * dim)), 2.2)
    func ratio(_ c: NSColor) -> Double {
      guard let s = c.usingColorSpace(.sRGB) else { return 0 }
      func lin(_ v: CGFloat) -> Double {
        let d = Double(v)
        return d <= 0.04045 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
      }
      let l = 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent)
            + 0.0722 * lin(s.blueComponent)
      let hi = max(l, Double(ground)), lo = min(l, Double(ground))
      return (hi + 0.05) / (lo + 0.05)
    }
    return String(format: "fg %.1f muted %.1f", ratio(Palette.fg), ratio(Palette.muted))
  }

  // ── WHERE IT IS, SO SOMETHING CAN PHOTOGRAPH IT ────────────────────────────
  //
  // The structural half of this audit can be satisfied by an app that is entirely
  // frosted, if the reader is reading the wrong thing -- so the other half is a
  // photograph, and a photograph needs to know which pixels are the surface. This
  // is the only way to get that without the rig guessing at a rectangle whose size
  // depends on how long somebody's name is.
  //
  // TOP-LEFT origin, because the only consumer is a screen capture and every image
  // format on this machine counts rows downward, while AppKit counts them up. The
  // conversion belongs here, once, rather than in every script that reads the log.
  private func whereItIs() -> String {
    guard let win = window else { return "at=- win=- active=-" }
    let f = convert(bounds, to: nil)                       // window coords, y up
    let h = win.contentView?.bounds.height ?? win.frame.height
    let w = win.contentView?.bounds.width ?? win.frame.width
    // ── AND WHETHER THIS WINDOW IS THE FRONT ONE ──────────────────────────────
    //
    // Because the material renders DIFFERENTLY depending on it, and the difference
    // is not subtle. Photographed with a calibrated pattern behind the card, the
    // same build with the same dim came out either 0.67 or 0.16 of the picture
    // surviving, flipping between runs of an identical command -- and stable to
    // three decimals WITHIN a run, so a single measurement of either mode looks
    // like a solid result. The rig's own null A/B put its noise at 0.0003, which
    // is what proved the two modes were real rather than scatter.
    //
    // A rig cannot raise a window on somebody's Mac while they are using it, so
    // this field is how a photograph says which of the two things it caught.
    let a = "\(win.isKeyWindow ? "key" : "-")/\(win.isMainWindow ? "main" : "-")"
          + "/\(NSApp.isActive ? "app" : "-")"
    return "at=\(Int(f.minX)),\(Int(h - f.maxY)),\(Int(f.width)),\(Int(f.height))"
         + " win=\(Int(w))x\(Int(h)) active=\(a)"
  }

  /// On screen, as opposed to merely built. A surface behind a closed sheet is
  /// still a surface and still has to obey the policy, but nothing can photograph
  /// it -- so the audit says which is which rather than the rig inferring it from
  /// a zero frame, which is also what a surface looks like before its first layout.
  private var isEffectivelyVisible: Bool {
    guard window != nil, !bounds.isEmpty else { return false }
    var v: NSView? = self
    while let cur = v {
      if cur.isHidden || cur.alphaValue < 0.01 { return false }
      v = cur.superview
    }
    return true
  }

  /// The heaviest fill among the layers handed in, as an alpha, or `none`. Alpha,
  /// because "is there a colour here" is not the question -- `clear` is a colour.
  /// How much of the picture it stops is the question.
  private static func describeFill(_ colours: CGColor?...) -> String {
    let worst = colours.compactMap { $0 }.map(\.alpha).max() ?? 0
    return worst <= 0.001 ? "none" : String(format: "%.2f", worst)
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

  // ── AN INVISIBLE GROUP IS NOT CLICKABLE ────────────────────────────────────
  //
  // `IconButton.hitTest` already refuses below 0.01 alpha, and that guard became
  // unreachable the day the row's fade moved onto this group: the CHILDREN keep
  // alpha 1 forever, so every circle stayed armed while the group faded out from
  // under them. AppKit does not do this for us -- `isHidden` stops a hit test and
  // `alphaValue` does not.
  //
  // The instant matters, not just the end state. `alphaValue` is set to its target
  // the moment an animation starts, so this refuses from the frame the app decides
  // to take the row away rather than 240 ms later when the animation lands. That
  // 240 ms is exactly where a hang-up button somebody can no longer see fires
  // under a finger that was aiming at the picture.
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
    // Invisible first, and see the block above for why AppKit will not do it: a
    // hidden view stops a hit test and a zero-alpha one does not.
    guard !isHidden, alphaValue > 0.01 else { return nil }
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
