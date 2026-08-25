import AppKit
import QuartzCore

// ── THE PART OF THE CALL THAT IS NOT AUDIO ───────────────────────────────────
//
// Kin lets one person be audible at a time. That is the whole design: on
// speakers, two open microphones is two microphones each recording the other's
// loudspeaker, and every product that has tried to fix that afterwards has done
// it by processing the voice until it survives being cancelled. This one does not
// process the voice. It decides whose turn it is.
//
// A rule like that is only kind if the other person is never LOST while it is in
// force. So the quiet side keeps three ways of reaching you, and this file is all
// three:
//
//   1. THE FLOOR CUE -- wordless, and fast. The far end's classification rides in
//      the status byte of the very next audio packet, so it lands one network hop
//      after they open their mouth: about 5 ms on a desk, 60 ms across an ocean.
//      Nothing that has to be recognised can be that quick. It is pre-verbal on
//      purpose -- motion and brightness are noticed without being read, and being
//      noticed without being read is the difference between a cue and an
//      interruption.
//
//   2. THE BLOOM -- the listening noise itself, as a word, large, appearing and
//      fading. "mm-hmm" is not a sentence and does not belong in a running
//      caption; it is the sound somebody makes to say they are still with you,
//      and it should behave like one. Brief, warm, gone.
//
//   3. THE CAPTION BAND -- a real utterance, running, revised as the recogniser
//      changes its mind. This is the slow channel, because words have to be heard
//      before they can be written; ~260 ms of speech plus the recogniser plus a
//      hop. Slow is fine: by the time it says anything, the cue has already told
//      you that somebody is there.
//
// The two speeds are the reason both exist. A cue with no words leaves you
// guessing what they want; words with no cue arrive after you have already talked
// over them.
//
// ── WHY THE CUE IS NOT A LABEL ───────────────────────────────────────────────
//
// The obvious build is a badge that says "wants to speak". It was not built, for
// a reason worth writing down: reading competes with listening. Text is processed
// by the same language machinery that is currently busy parsing the sentence
// somebody is saying to you, so a word placed on screen DURING their speech costs
// attention that was already spent -- which is the exact mechanism behind video
// call fatigue this app exists to remove. Size, motion and colour are not
// language. They are noticed by a system that is otherwise idle.
//
// So: no words in the cue, ever. Words only where they are the payload.

// ── ONE ORGAN, TWO INTENSITIES ───────────────────────────────────────────────
//
// A listening noise and a bid for the floor are the same event acoustically --
// the far end's voice, arriving while yours is out -- separated by how long it
// lasts and how hard it pushes. So they are one shape here too, at two points on
// a single continuum, and the movement BETWEEN them is the signal. Three soft
// dots breathing is "I am with you". The same three dots swelling, closing up
// into a bar and lighting is "I would like to say something". Nothing blinks on;
// nothing appears from nowhere. You watch a thing you were already half-aware of
// change its mind.
final class FloorCue: NSView {
  /// 0 quiet, 1 listening noise, 2 bid for the floor. The same three values the
  /// audio gate classifies, carried in the status byte.
  var vocal: Int = 0
  /// 0...1 from the speaking ledger: how much this person is OWED, because the
  /// last few contested starts went the other way. It does not decide anything.
  /// It makes their bid louder and quicker to arrive, so the person who has been
  /// winning is the one who gets nudged -- which is the whole point of keeping
  /// the record.
  var nudge: Double = 0

  /// Eased position on the continuum. Everything drawn below is a function of
  /// this one number, which is what makes backchannel-to-claim a morph rather
  /// than a swap.
  private(set) var level: CGFloat = 0
  private var phase: CGFloat = 0

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var isOpaque: Bool { false }

  /// Where the shape wants to be, before easing.
  private var target: CGFloat {
    switch vocal {
    case 1: return 0.42
    case 2: return min(1.0, 0.82 + 0.18 * CGFloat(max(0, min(1, nudge))))
    default: return 0
    }
  }

  /// One frame of animation. `dt` in seconds.
  ///
  /// Rise is faster than fall, and a bid rises faster than a listening noise: the
  /// cost of noticing a bid late is that you talk over somebody, and the cost of
  /// a cue lingering is nothing at all. A ledger nudge shortens the rise further,
  /// which is what "louder and quicker" means in practice.
  func step(_ dt: CGFloat) {
    let t = target
    // 50 ms, and the number is set by the frame rate as much as by taste: at 30 Hz
    // a time constant below ~33 ms is a snap rather than a rise, and a snap reads
    // as a notification popping in. 50 ms puts the shape past three quarters of
    // its travel inside 100 ms -- comfortably shorter than the vowel somebody is
    // in the middle of -- while still visibly moving. A listening noise gets three
    // times as long, because it is not urgent and should feel like a breath.
    let riseTau: CGFloat = vocal == 2 ? (0.050 - 0.015 * CGFloat(max(0, min(1, nudge)))) : 0.16
    let tau = t > level ? riseTau : 0.34
    level += (t - level) * min(1, dt / tau)
    if abs(t - level) < 0.002 { level = t }
    phase += dt
    needsDisplay = true
  }

  var idle: Bool { level < 0.01 && target == 0 }
  /// For `--cue-test`: how long the shape takes to get from wherever it is to
  /// `to`, driven at a fixed frame time. Returns milliseconds, or nil if it never
  /// arrives inside `limitMs`.
  ///
  /// The direction is taken from where the level IS, not from the sign of `to`.
  /// The first version asked `to > 0 ? level >= to : level <= to`, so measuring a
  /// FADE to 0.005 returned 33 ms -- the level was already above it -- and
  /// reported an instant disappearance as a pass.
  func timeTo(_ to: CGFloat, frameMs: CGFloat = 1000.0 / 30.0, limitMs: CGFloat = 4000) -> CGFloat? {
    let falling = level > to
    var t: CGFloat = 0
    while t < limitMs {
      step(frameMs / 1000)
      t += frameMs
      if falling ? level <= to : level >= to { return t }
    }
    return nil
  }

  /// The shape is drawn from `level` alone, so there is no state here that can
  /// disagree with the state above.
  override func draw(_ dirty: NSRect) {
    guard level > 0.01, let ctx = NSGraphicsContext.current?.cgContext else { return }
    let t = level
    // ── THREE DOTS AND ONE BAR ARE THE SAME DRAWING ──────────────────────────
    //
    // Each of the three is a horizontal capsule. Its HEIGHT grows with `t`, and
    // its LENGTH grows only in the top half of the range -- so a listening noise
    // is three separate dots that swell a little, and a bid is the same three
    // shapes stretched until they overlap into one solid bar. Nothing is hidden
    // and nothing is shown; the geometry does all of it, which is why there is no
    // frame in the middle where it looks like neither.
    let r = 3.0 + 4.0 * t                         // half-height
    let spacing = 13.0 - 2.0 * t                  // centre to centre
    let stretch = max(0, (t - 0.5) / 0.5) * 12.0  // extra half-LENGTH; merges them
    // LEFT aligned, not centred. The shape's width changes with `t`, so centring
    // it would slide its leading edge sideways every time the far end went from
    // listening to bidding -- and it sits directly above the first word of the
    // caption, where a moving edge reads as the layout twitching.
    let cy = bounds.midY, x0 = 2 + r + stretch
    let xs = [x0, x0 + spacing, x0 + 2 * spacing]

    // Colour walks from the app's plain foreground to its accent, and gains
    // opacity on the way. A listening noise is meant to be almost subliminal.
    let a = 0.55 + 0.45 * t
    let col = blend(Palette.fg, Palette.accent, t).withAlphaComponent(a)

    let path = CGMutablePath()
    for (i, x) in xs.enumerated() {
      // Breathing, only while it is a breath. It fades out as the shape becomes a
      // bid, because a bid that pulses reads as a notification badge and a
      // notification badge is a thing you dismiss.
      let breathe = max(0, 1 - t / 0.7)
      let sc = 1 + 0.30 * breathe * sin(phase * 2 * .pi * 0.95 + CGFloat(i) * 0.7)
      let rr = r * sc, hw = r * sc + stretch
      path.addRoundedRect(in: CGRect(x: x - hw, y: cy - rr, width: hw * 2, height: rr * 2),
                          cornerWidth: rr, cornerHeight: rr)
    }

    // ── LEGIBLE ON A WHITE WALL ──────────────────────────────────────────────
    //
    // This floats on the picture with no material under it, and the picture is
    // somebody's office: the first version of it vanished against a bright wall.
    // A soft dark halo costs nothing, follows the shape exactly, and is the same
    // trick the bloom uses two hundred lines up.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 8,
                  color: NSColor.black.withAlphaComponent(0.55).cgColor)
    ctx.setFillColor(col.cgColor)
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()

    // The glow is the part peripheral vision actually catches, so it belongs to
    // the bid and not to the breath. Painted as a second pass over the halo,
    // because one context can only carry one shadow.
    if t > 0.5 {
      let g = (t - 0.5) / 0.5
      ctx.saveGState()
      ctx.setShadow(offset: .zero, blur: 16 * g,
                    color: Palette.accent.withAlphaComponent(0.75 * g).cgColor)
      ctx.setFillColor(col.cgColor)
      ctx.addPath(path)
      ctx.fillPath()
      ctx.restoreGState()
    }

    // ── AND THE PART THAT MOVES ───────────────────────────────────────────────
    //
    // A bar that is merely brighter than a dot is a state; a bar with something
    // travelling along it is an event, and events are what the eye is built to
    // catch off-axis. It sweeps left to right, once every 900 ms, only while this
    // is a bid.
    if t > 0.6 {
      let g = (t - 0.6) / 0.4
      let left = xs[0] - r - stretch, right = xs[2] + r + stretch
      let w = right - left
      let head = left + w * CGFloat((phase / 0.9).truncatingRemainder(dividingBy: 1))
      ctx.saveGState()
      ctx.addPath(path)
      ctx.clip()
      let cols = [NSColor.clear.cgColor,
                  Palette.fill(0.85 * g).cgColor,
                  NSColor.clear.cgColor] as CFArray
      if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: cols, locations: [0, 0.5, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: head - 16, y: cy),
                               end: CGPoint(x: head + 16, y: cy), options: [])
      }
      ctx.restoreGState()
    }
  }

  private func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    let x = a.usingColorSpace(.sRGB) ?? a, y = b.usingColorSpace(.sRGB) ?? b
    return NSColor(srgbRed: x.redComponent + (y.redComponent - x.redComponent) * t,
                   green: x.greenComponent + (y.greenComponent - x.greenComponent) * t,
                   blue: x.blueComponent + (y.blueComponent - x.blueComponent) * t,
                   alpha: 1)
  }
}

// ── "mm-hmm" ─────────────────────────────────────────────────────────────────
//
// The listening noise, as the word it was. It rises a few points, holds, and
// fades -- the whole life is about a second and a half, which is roughly how long
// the noise itself stays relevant. It is centred over the picture rather than
// docked in the caption band, because it is not part of a transcript: putting it
// in the running text would break somebody's sentence in half around a grunt.
final class BloomLabel: NSView {
  private let label = NSTextField(labelWithString: "")
  private var born: CFTimeInterval = -1
  private static let life: CFTimeInterval = 1.5

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override init(frame: NSRect) {
    super.init(frame: frame)
    label.font = Type_.bloom
    label.textColor = Palette.fg
    label.alignment = .center
    label.backgroundColor = .clear
    label.isBordered = false
    addSubview(label)
    alphaValue = 0
  }
  required init?(coder: NSCoder) { fatalError() }

  private(set) var word = ""

  /// ── WHAT COUNTS AS A NOISE RATHER THAN A SENTENCE ──────────────────────────
  ///
  /// A hard ceiling, checked HERE and not only where the routing decision is
  /// made. On a live call the classifier mislabelled six seconds of speech as a
  /// listening noise and this view rendered the whole paragraph at 30 pt, running
  /// off both edges of the window. The classifier is now fixed; this guard is
  /// what makes the drawing safe whatever the classifier decides next, because a
  /// view that can be told to draw a paragraph in display type eventually will
  /// be. Real continuers -- "mm-hmm", "yeah", "right", "okay", "sure", "oh wow"
  /// -- are all comfortably inside this.
  static let maxWords = 3
  static let maxChars = 24

  /// Repeating the same noise does not restart the animation -- somebody saying
  /// "mm-hmm, mm-hmm" is one continuous act of listening, and a word that flashes
  /// twice reads as a bug. A DIFFERENT word does restart it.
  ///
  /// Returns false if the text is too long to be a listening noise, so the caller
  /// can put it where a sentence belongs instead of dropping it.
  @discardableResult
  func show(_ w: String) -> Bool {
    let clean = w.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return false }
    guard clean.count <= BloomLabel.maxChars,
          clean.split(separator: " ").count <= BloomLabel.maxWords else { return false }
    if clean.caseInsensitiveCompare(word) == .orderedSame, alive { return true }
    word = clean
    // ── A WORD WITH NO BOX HAS TO CARRY ITS OWN CONTRAST ──────────────────────
    //
    // Photographed over a beige sweater, #e8eaed on a shadow alone was washed
    // out to the point of being decorative. A pane of glass around a two-syllable
    // grunt is a dialog box, so the contrast has to come from the glyphs: a dark
    // stroke OUTSIDE the fill (negative `strokeWidth` means stroke and fill, not
    // stroke instead of fill) plus the shadow. It follows the letterforms exactly
    // and disappears with them, which a rectangle cannot do.
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(0.85)
    sh.shadowBlurRadius = 16
    sh.shadowOffset = NSSize(width: 0, height: -1)
    label.attributedStringValue = NSAttributedString(string: clean, attributes: [
      .font: Type_.bloom,
      .foregroundColor: Palette.fg,
      .strokeColor: NSColor.black.withAlphaComponent(0.55),
      .strokeWidth: -3.0,
      .shadow: sh,
    ])
    born = CACurrentMediaTime()
    let size = (clean as NSString).size(withAttributes: [.font: Type_.bloom])
    let w = ceil(size.width) + 40, h = ceil(size.height) + 8
    label.frame = NSRect(x: (bounds.width - w) / 2, y: 0, width: w, height: h)
    setFrameSize(NSSize(width: bounds.width, height: h))
    needsLayout = true
    return true
  }

  var alive: Bool { born > 0 && CACurrentMediaTime() - born < BloomLabel.life }

  /// Cut it short, leaving only the fade. Used when the caption band picks up the
  /// same words: the first 700 ms of every turn is genuinely unclassifiable, so
  /// the opening word blooms and then the sentence resolves underneath it -- and
  /// seeing "Hey." twice, once large and once in the caption, reads as a glitch
  /// rather than as the two things it is.
  func retire() {
    guard alive else { return }
    born = CACurrentMediaTime() - (BloomLabel.life - 0.45)
  }

  /// Returns the vertical offset it wants, so the owner can place it. Keeping the
  /// rise OUT of this view means the animation cannot fight the layout pass.
  @discardableResult
  func step() -> CGFloat {
    guard born > 0 else { alphaValue = 0; return 0 }
    let age = CACurrentMediaTime() - born
    guard age < BloomLabel.life else { alphaValue = 0; born = -1; word = ""; return 0 }
    // in over 140 ms, hold, out over the last 450
    let inA = min(1, age / 0.14)
    let outA = min(1, max(0, (BloomLabel.life - age) / 0.45))
    alphaValue = CGFloat(min(inA, outA))
    // A short rise, eased out, so it feels like it was said rather than posted.
    let p = CGFloat(min(1, age / 0.5))
    return 10 * (1 - pow(1 - p, 3))
  }
}

// ── THE RUNNING CAPTION ──────────────────────────────────────────────────────
//
// Fixed width, left aligned, text bottom-anchored inside a two-line well so new
// words push the old ones up. Broadcast captioning has drawn it this way for
// forty years and the reason holds here: a centred caption re-centres itself on
// every revision, and this one revises about three times a second, so centring
// would make the whole band shimmer while somebody is trying to read it.
//
// Head truncation, not tail: the newest words are the ones that matter, so what
// falls off the front is what falls off.
final class CaptionBand: NSView {
  private let glass = Glass(radius: 0, variant: .regular)
  private let holder = NSView()
  private let theirs = NSTextField(labelWithString: "")
  private let mine = NSTextField(labelWithString: "")

  static let pad: CGFloat = 12
  /// Caption width. Broadcast practice is a little under two thirds of the
  /// frame: wider than that and the eye has to travel, narrower and a sentence
  /// wraps every four words.
  static let maxWidth: CGFloat = 720
  static let widthFraction: CGFloat = 0.64

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(glass)
    for (f, font, col) in [(theirs, Type_.said, Palette.fg),
                           (mine, Type_.saidMine, Palette.muted)] {
      f.font = font
      f.textColor = col
      f.backgroundColor = .clear
      f.isBordered = false
      f.alignment = .left
      // ── A LABEL DOES NOT WRAP BECAUSE YOU ASKED IT TO, AND ORDER MATTERS ───
      //
      // `NSTextField(labelWithString:)` builds a SINGLE-LINE cell, and
      // `maximumNumberOfLines = 2` on a single-line cell is ignored in silence.
      // Photographed: a 118-character caption drew ONE line, clipped mid-word at
      // the right edge, inside a band correctly sized for two -- which reads as a
      // bug in the fitting code and is not one.
      //
      // The order below is the fix and not a style. `usesSingleLineMode` owns
      // `lineBreakMode`: assigning it stamps the cell's break mode, so setting
      // the break mode FIRST and the flag second -- which is how this was written
      // the first time -- puts `.byClipping` back and clips exactly the way it
      // did before the fix. Flag, then wrapping, then the mode, then the count.
      f.usesSingleLineMode = false
      f.cell?.wraps = true
      f.cell?.isScrollable = false
      f.lineBreakMode = .byWordWrapping
      f.maximumNumberOfLines = 2
      holder.addSubview(f)
    }
    mine.maximumNumberOfLines = 1
    // ── WHOSE WORDS ARE WHOSE, WITHOUT A LABEL ─────────────────────────────────
    //
    // Theirs left, yours right. Every messaging app on the planet has taught this
    // and it needs no legend, no name and no colour key -- which matters because
    // the alternative was a third line of grey text under two lines of white text
    // that read as a continuation of the same sentence. Smaller and dimmer already
    // said "secondary"; the side is what says "you".
    mine.alignment = .right
    // Handed over, not stacked. `NSGlassEffectView` guarantees nothing about the
    // z-order of arbitrary subviews and resamples the ones it catches -- which is
    // how every glyph in this app came out soft the first time it was tried.
    glass.content = holder
    alphaValue = 0
  }
  required init?(coder: NSCoder) { fatalError() }

  var theirText = "" { didSet { if theirText != oldValue { dirty = true } } }
  var myText = "" { didSet { if myText != oldValue { dirty = true } } }
  private var dirty = true

  /// How many lines the other person's words currently need, with a floor that
  /// only falls back down after a moment. A live transcript revises about three
  /// times a second and crosses the one-line boundary repeatedly on the way
  /// through a sentence; without the hold, the band pumped.
  private var twoLineUntil: CFTimeInterval = 0
  private var theirLines: CGFloat {
    guard !theirText.isEmpty else { return 0 }
    let innerW = bounds.width - CaptionBand.pad * 2
    let lh = CaptionBand.lineHeight(Type_.said)
    if heightOf(theirs, width: innerW) > lh + 1 { twoLineUntil = CACurrentMediaTime() + 0.8; return 2 }
    return CACurrentMediaTime() < twoLineUntil ? 2 : 1
  }

  /// Height it wants, given what it is holding. It follows the content rather
  /// than always reserving two lines: a band with an empty half is a box waiting
  /// to be filled, and the 30 Hz ease above turns the growth into a slide.
  var wantedHeight: CGFloat {
    guard !theirText.isEmpty || !myText.isEmpty else { return 0 }
    let lh = CaptionBand.lineHeight(Type_.said)
    var h = CaptionBand.pad * 2 + lh * theirLines
    if !myText.isEmpty {
      h += CaptionBand.lineHeight(Type_.saidMine)
      if !theirText.isEmpty { h += Metric.s1 }
    }
    return ceil(h)
  }

  // ── ASK THE TEXT SYSTEM, NOT THE FONT ──────────────────────────────────────
  //
  // `ceil(ascender - descender + leading)` is the arithmetic everybody writes and
  // it is not the number the text system uses. For the 16 pt system font it comes
  // out at 18 where AppKit lays out at 19, so a two-line well was sized 36 against
  // a cell that needed 38 -- and the second line was clipped away entirely. The
  // caption looked like it had been truncated mid-sentence, which sent the search
  // to the string-fitting code, which was correct all along.
  //
  // `NSLayoutManager.defaultLineHeight` is the number the layout actually uses.
  // Cached because this is asked several times per frame at 30 Hz and building a
  // layout manager is not free.
  private static let lm = NSLayoutManager()
  private static var lhCache: [String: CGFloat] = [:]
  /// What is actually being drawn, after head-truncation. `theirText` is what was
  /// received; this is what fits.
  var theirDrawn: String { theirs.stringValue }
  var myDrawn: String { mine.stringValue }
  /// The height the CELL needs against the height the FIELD was given. A cell
  /// taller than its field is a clipped last line, which is the exact regression
  /// that shipped a caption cut off mid-sentence.
  var clippedBy: CGFloat {
    let innerW = bounds.width - CaptionBand.pad * 2
    return heightOf(theirs, width: innerW) - theirs.frame.height
  }

  static func lineHeight(_ f: NSFont) -> CGFloat {
    let key = "\(f.fontName)|\(f.pointSize)"
    if let c = lhCache[key] { return c }
    let h = ceil(lm.defaultLineHeight(for: f))
    lhCache[key] = h
    return h
  }

  private var fitWidth: CGFloat = 0

  override func layout() {
    super.layout()
    let w = bounds.width, h = bounds.height
    // A resize changes how much fits on a line, so the strings have to be cut
    // again. Without this the band kept the previous window's truncation and a
    // widened window showed a leading ellipsis in front of a half-empty line.
    if w != fitWidth { fitWidth = w; dirty = true; refit() }
    glass.frame = bounds
    glass.radius = Metric.captionRadius
    holder.frame = bounds
    let innerW = w - CaptionBand.pad * 2
    let mh = myText.isEmpty ? 0
      : CaptionBand.lineHeight(Type_.saidMine) + (theirText.isEmpty ? 0 : Metric.s1)
    // Their two-line well sits above your one line, and the text inside it is
    // bottom-anchored: one line of theirs sits on the floor of the well, and the
    // second line appears ABOVE it. That is what makes a caption roll instead of
    // jump.
    let wellBottom = CaptionBand.pad + mh
    let need = heightOf(theirs, width: innerW)
    theirs.frame = NSRect(x: CaptionBand.pad, y: wellBottom, width: innerW, height: need)
    theirs.isHidden = theirText.isEmpty
    if ProcessInfo.processInfo.environment["KIN_CUE_DEBUG"] != nil {
      let cs = theirs.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: innerW, height: 1e5))
      fputs("band: w=\(Int(w)) inner=\(Int(innerW)) need=\(need) frame=\(theirs.frame)"
          + " single=\(theirs.usesSingleLineMode) wraps=\(theirs.cell?.wraps ?? false)"
          + " lbm=\(theirs.lineBreakMode.rawValue) maxLines=\(theirs.maximumNumberOfLines)"
          + " cellSize=\(cs.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-")"
          + " len=\(theirs.stringValue.count)\n", stderr)
    }
    mine.frame = NSRect(x: CaptionBand.pad, y: CaptionBand.pad, width: innerW,
                        height: CaptionBand.lineHeight(Type_.saidMine))
    mine.isHidden = myText.isEmpty
    _ = h
  }

  /// Re-fits the strings to the current width. Separate from `layout` because
  /// fitting measures text and layout runs on every window resize tick, and
  /// re-measuring a paragraph at 30 Hz for a window nobody is dragging is waste.
  func refit(force: Bool = false) {
    guard dirty || force else { return }
    dirty = false
    let innerW = bounds.width - CaptionBand.pad * 2
    guard innerW > 40 else { return }
    theirs.stringValue = CaptionBand.fitTail(theirText, font: Type_.said, width: innerW, lines: 2)
    mine.stringValue = CaptionBand.fitTail(myText, font: Type_.saidMine, width: innerW, lines: 1)
    needsLayout = true
  }

  /// How tall the FIELD needs to be, asked of the cell that will draw it rather
  /// than of a free-standing string measurement. The cell already knows about
  /// `maximumNumberOfLines`, so a two-line cap needs no arithmetic here and
  /// cannot disagree with what gets rendered -- which is exactly how the last
  /// line went missing.
  private func heightOf(_ f: NSTextField, width: CGFloat) -> CGFloat {
    guard !f.stringValue.isEmpty, let c = f.cell else { return 0 }
    return ceil(c.cellSize(forBounds: NSRect(x: 0, y: 0, width: width,
                                             height: .greatestFiniteMagnitude)).height)
  }

  /// The LAST `lines` lines of `s`, with a leading ellipsis if anything was cut.
  /// Binary search on the word index, because height is monotone in how much you
  /// drop from the front, and this runs several times a second on a live call.
  static func fitTail(_ s: String, font: NSFont, width: CGFloat, lines: Int) -> String {
    guard !s.isEmpty, width > 20 else { return s }
    let maxH = lineHeight(font) * CGFloat(lines) + 1
    func h(_ t: String) -> CGFloat {
      (t as NSString).boundingRect(
        with: NSSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
    }
    if h(s) <= maxH { return s }
    let words = s.split(separator: " ", omittingEmptySubsequences: false)
    var a = 0, b = words.count, best = words.count
    while a < b {
      let m = (a + b) / 2
      if h("… " + words[m...].joined(separator: " ")) <= maxH { best = m; b = m } else { a = m + 1 }
    }
    guard best < words.count else { return "…" }
    return "… " + words[best...].joined(separator: " ")
  }
}

// ── ALL THREE, PLACED ────────────────────────────────────────────────────────
//
// One view over the whole window, holding the cue, the bloom and the band, with a
// single 30 Hz tick that stops itself the moment there is nothing moving. It
// passes every click through: none of this is a control, and the quickest way to
// break a call is to put a transparent rectangle over the hang-up button.
final class TurnCues: NSView {
  private let cue = FloorCue(frame: .zero)
  private let bloom = BloomLabel(frame: .zero)
  private let band = CaptionBand(frame: .zero)
  /// ── THE ROOM LIGHTS UP ─────────────────────────────────────────────────────
  ///
  /// A stroke just inside the window's own rounded edge, accent coloured, that
  /// comes up only for a BID and not for a listening noise. It exists because the
  /// pill above the caption is a LOCAL marker -- you have to be looking near it --
  /// and the moment somebody starts to speak is exactly the moment your eyes are
  /// on their face, or on your own notes, or anywhere else.
  ///
  /// The edge of the visual field is the one place that is always in view. It is
  /// also the only channel here that costs nothing to monitor: peripheral vision
  /// is poor at detail and excellent at change, so a rim that brightens is
  /// noticed without being looked at, which is the entire requirement.
  ///
  /// A layer rather than a `draw(_:)`, because the alternative is invalidating a
  /// 1280x720 view thirty times a second to repaint two hundred pixels of stroke.
  private let rim = CAShapeLayer()
  private var timer: Timer?
  private var lastTick = CACurrentMediaTime()

  /// How far off the bottom of the window the band floats. Set by the owner,
  /// because the owner is the thing that knows how tall the button row is.
  var bottomInset: CGFloat = 110 { didSet { needsLayout = true } }

  /// Eased band height, so the band growing a line for your own words slides
  /// instead of snapping.
  private var bandH: CGFloat = 0
  private var bandA: CGFloat = 0
  /// When the other person's words last changed. The band holds for a moment
  /// after they stop and then goes, because a caption of a sentence that finished
  /// ten seconds ago is litter on somebody's face.
  private var theirsAt: CFTimeInterval = -1
  private var theirsFinal = false
  private var mineAt: CFTimeInterval = -1

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    rim.fillColor = nil
    rim.lineWidth = 3
    rim.strokeColor = Palette.accent.cgColor
    rim.shadowColor = Palette.accent.cgColor
    rim.shadowOffset = .zero
    rim.shadowRadius = 18
    rim.shadowOpacity = 0
    rim.opacity = 0
    layer?.addSublayer(rim)
    addSubview(band)
    addSubview(cue)
    addSubview(bloom)
    autoresizingMask = [.width, .height]
  }
  required init?(coder: NSCoder) { fatalError() }

  // ── WHAT THE CALL PUSHES IN ────────────────────────────────────────────────

  /// The other person's live transcript. `final` means the recogniser has
  /// committed; it only changes how long the words linger.
  func setTheirs(_ text: String, final: Bool) {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // The caption has taken over these words; the bloom was the first guess at
    // them. Compared case- and punctuation-insensitively, because "Hey." blooms
    // and "Hey, I'm sitting" is what the caption says next.
    if bloom.alive, !t.isEmpty {
      let head = bloom.word.lowercased().filter { $0.isLetter || $0.isNumber }
      let body = t.lowercased().filter { $0.isLetter || $0.isNumber }
      if !head.isEmpty, body.hasPrefix(head) { bloom.retire() }
    }
    if t != band.theirText { theirsAt = CACurrentMediaTime() }
    band.theirText = t
    theirsFinal = final
    if !t.isEmpty { theirsAt = CACurrentMediaTime() }
    wake()
  }

  /// Your own words, shown only while your microphone is not the audible one --
  /// which is exactly when you need to know you are still getting through. When
  /// you have the floor you can hear yourself, so this stays empty.
  func setMine(_ text: String, showing: Bool) {
    let t = showing ? text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    if t != band.myText { mineAt = CACurrentMediaTime() }
    band.myText = t
    wake()
  }

  /// A listening noise, as a word. Nothing happens if it did not come with one --
  /// the cue has already carried the fact of it. Anything too long to BE a
  /// listening noise falls through to the caption band rather than being dropped:
  /// whatever the classifier believed, those are words somebody said and the
  /// quiet side is not allowed to lose them.
  func setListeningNoise(_ word: String) {
    if bloom.show(word) { wake(); return }
    setTheirs(word, final: false)
  }

  func setFloor(peerVocal: Int, nudge: Double) {
    cue.vocal = peerVocal
    cue.nudge = nudge
    wake()
  }

  /// For the harness, and for the report line: what is actually on screen.
  /// For `--cue-test`. Nothing on the call reads these; they exist so an
  /// assertion can be made about a thing that only ever moves.
  var testCue: FloorCue { cue }
  var testBand: CaptionBand { band }
  var testBloom: BloomLabel { bloom }
  var testTicking: Bool { timer != nil }
  func testTick(_ dt: CGFloat) { lastTick -= Double(dt); tick() }

  var describe: String {
    "cue=\(["quiet", "listening", "claiming"][max(0, min(2, cue.vocal))])"
      + "/\(String(format: "%.2f", cue.level))"
      + " bloom=\(bloom.alive ? bloom.word : "-")"
      + " theirs=\(band.theirText.isEmpty ? "-" : "\"\(band.theirText)\"")"
      + " mine=\(band.myText.isEmpty ? "-" : "\"\(band.myText)\"")"
      + " band=\(String(format: "%.0f", bandA * 100))%"
  }

  // ── THE TICK ───────────────────────────────────────────────────────────────

  private func wake() {
    guard timer == nil else { return }
    lastTick = CACurrentMediaTime()
    // 30 Hz. It draws three dots and moves two text fields; the audio thread will
    // never notice it, and it stops as soon as everything has settled.
    let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
    // `.common`, or it freezes solid the whole time a menu is open or a window is
    // being dragged -- which are two of the moments somebody is most likely to be
    // mid-sentence.
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  private func tick() {
    let now = CACurrentMediaTime()
    let dt = CGFloat(min(0.1, max(0.001, now - lastTick)))
    lastTick = now

    cue.step(dt)
    let rise = bloom.step()

    // The rim answers to the top half of the cue's range only: a "mm-hmm" must
    // not light the room. `nudge` raises the ceiling, so somebody who has been
    // waiting their turn gets a brighter one -- which is the ledger being felt
    // instead of displayed.
    let g = max(0, (cue.level - 0.5) / 0.5)
    // One slow breath, ±12%. Enough that the edge is alive rather than painted
    // on; far short of a flash, which would read as an alarm and make people
    // stop mid-word instead of finishing their sentence.
    let breath = 1 + 0.12 * sin(CGFloat(now) * 2 * .pi * 0.55)
    CATransaction.begin()
    CATransaction.setDisableActions(true)   // or every frame animates over 0.25 s
    rim.opacity = Float(min(1, g * breath) * (0.55 + 0.45 * CGFloat(max(0, min(1, cue.nudge)))))
    rim.shadowOpacity = Float(g * 0.7)
    CATransaction.commit()

    // ── THE BAND'S LIFE IS THE SPEAKER'S, NOT THE TRANSCRIPT'S ───────────────
    //
    // Timing this from the last REVISION was wrong in the one case that matters:
    // somebody pausing in the middle of a thought. Three seconds of silence
    // between two halves of a sentence made the first half vanish and the second
    // half appear on its own, which is the opposite of "should not miss a beat".
    //
    // So the clock only starts once they have actually stopped -- the status byte
    // says so, and it says so within a hop. The hard ceiling is there because a
    // peer that leaves mid-word stops sending status too, and a caption that
    // never expires is litter on a face for the rest of the call.
    if !band.theirText.isEmpty {
      let quiet = cue.vocal == 0
      let since = now - theirsAt
      if (quiet && since > (theirsFinal ? 1.6 : 2.2)) || since > 12 { band.theirText = "" }
    }
    if !band.myText.isEmpty, now - mineAt > 3.0 { band.myText = "" }

    band.refit()
    let wantH = band.wantedHeight
    let wantA: CGFloat = wantH > 0 ? 1 : 0
    bandH += (wantH - bandH) * min(1, dt / 0.12)
    bandA += (wantA - bandA) * min(1, dt / 0.18)
    if abs(wantH - bandH) < 0.5 { bandH = wantH }
    if abs(wantA - bandA) < 0.004 { bandA = wantA }

    place(bloomRise: rise)

    // Stop when nothing is moving. A timer that runs for the whole call to draw
    // nothing is the kind of thing that shows up later as "the app warms my legs".
    if cue.idle, !bloom.alive, bandA < 0.005, bandH < 0.5 {
      timer?.invalidate(); timer = nil
      cue.isHidden = true; band.isHidden = true
    }
  }

  override func layout() {
    super.layout()
    place(bloomRise: 0)
  }

  private func place(bloomRise: CGFloat) {
    let w = bounds.width, h = bounds.height
    // Inset by half the stroke so the line lands INSIDE the window instead of
    // straddling an edge the compositor is about to round away, and concentric
    // with the window's own corner so it reads as the window glowing rather than
    // as a rectangle drawn on top of one.
    let ins = rim.lineWidth / 2
    let r = max(0, Metric.windowRadius - ins)
    rim.frame = bounds
    rim.path = CGPath(roundedRect: bounds.insetBy(dx: ins, dy: ins),
                      cornerWidth: r, cornerHeight: r, transform: nil)
    let bw = min(w - Metric.gutter * 2, CaptionBand.maxWidth,
                 max(360, w * CaptionBand.widthFraction))
    band.isHidden = bandA < 0.005
    band.alphaValue = bandA
    band.frame = NSRect(x: (w - bw) / 2, y: bottomInset, width: bw, height: max(0, bandH))
    // The cue sits just above the band, on the band's left edge rather than in the
    // middle of the window: it belongs to the words underneath it, and an eye that
    // has to travel from the centre of the screen to the start of a line has
    // already lost the thing it was reading.
    let cueW: CGFloat = 76, cueH: CGFloat = 24
    let bandTop = bottomInset + max(0, bandH)
    cue.isHidden = cue.level < 0.01
    cue.frame = NSRect(x: (w - bw) / 2 + CaptionBand.pad - 2, y: bandTop + Metric.s2,
                       width: cueW, height: cueH)
    // ── ABOVE THE CAPTION, NOT ON THE FACE ────────────────────────────────────
    //
    // The first version put this in the middle of the picture, which is where
    // somebody's face is, and covering the face of a person who is listening to
    // you in order to tell you that they are listening to you is self-defeating.
    // It sits in the caption's airspace instead: the strip your eyes already flick
    // to for words, clear of the head, and above the band when there is one.
    bloom.setFrameSize(NSSize(width: w, height: bloom.frame.height))
    bloom.setFrameOrigin(NSPoint(x: 0, y: bottomInset + max(bandH, 40) + 46 + bloomRise))
    _ = h
  }
}
