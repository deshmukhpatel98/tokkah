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
// force. So the quiet side keeps two ways of reaching you, and this file is both:
//
//   1. THE BLOOM -- the listening noise itself, as a word, large, appearing and
//      fading. "mm-hmm" is not a sentence and does not belong in a running
//      caption; it is the sound somebody makes to say they are still with you,
//      and it should behave like one. Brief, warm, gone.
//
//   2. THE CAPTION BAND -- a real utterance, running, revised as the recogniser
//      changes its mind. This is the slow channel, because words have to be heard
//      before they can be written; ~260 ms of speech plus the recogniser plus a
//      hop.
//
// Both of those are WORDS, which is to say they are the payload. Neither is an
// effect over the picture, and that distinction is the whole of the next note.
//
// ── WHAT WAS HERE, AND WHY IT IS GONE ────────────────────────────────────────
//
// There used to be a third channel, and it was the fast one: a wordless FLOOR CUE
// drawn straight onto the video. Three dots that breathed while the far end made
// a listening noise, swelling and merging into a lit bar with a glow and a light
// travelling along it when they wanted to speak -- and, above all of it, a
// three-point accent stroke around the entire window with an eighteen-point glow,
// pulsing at 0.55 Hz, under a comment that said "THE ROOM LIGHTS UP".
//
// Its argument was good and it is written down in `git log`: peripheral vision is
// poor at detail and excellent at change, so an edge that brightens is noticed
// without being looked at. The person the app is for disagreed, in these words:
//
//    "There should be no vignette of any kind. There should not be any effect.
//     It should all be very natural."
//
// They had said, two messages later, that people must always know who has the
// floor. Those two are not reconcilable by tuning the glow down. They are
// reconcilable by moving the answer off the picture and onto the CONTROL that was
// already claiming to answer it -- see `IconButton.reach` and `CallControls`
// `micFloor` in Controls.swift. The microphone button is the honest place: it is
// the thing that already says whether your voice is going out, a person looking
// for "am I being heard" looks there, and a control changing state is not an
// effect happening to the picture.
//
// Photographed before and after, window edge, 0-4 pt in, far end claiming the
// floor, as a mean of (blue - max(red, green)):
//
//     before   quiet  +4.9    claiming  +25.5     the edge, 6.4x brighter
//     after    quiet  +4.9    claiming   +4.9     nothing happens to the picture
//
// `FloorCue` below survives with no `draw` at all. That is not a dead control:
// its eased `level` is what decides when a caption expires, what the audit line
// reports, and what `--cue-test` measures. It stopped painting; it did not stop
// being read.
//
// ── WHY THE CUE WAS NEVER A LABEL, WHICH STILL HOLDS ─────────────────────────
//
// The obvious build is a badge that says "wants to speak". It was not built, for
// a reason worth keeping: reading competes with listening. Text is processed by
// the same language machinery that is currently busy parsing the sentence
// somebody is saying to you, so a word placed on screen DURING their speech costs
// attention that was already spent -- which is the exact mechanism behind video
// call fatigue this app exists to remove.
//
// So: no words about turn-taking, ever. Words only where they are the payload.

// ── ONE ORGAN, TWO INTENSITIES ───────────────────────────────────────────────
//
// A listening noise and a bid for the floor are the same event acoustically --
// the far end's voice, arriving while yours is out -- separated by how long it
// lasts and how hard it pushes. So they are one number here too, at two points on
// a single continuum: `level` eases toward 0.42 for a listening noise and toward
// 0.82-1.0 for a bid, faster on the way up than on the way down, and faster still
// for somebody the ledger says is owed a turn.
//
// Nothing draws it any more. It is read by the caption's expiry rule, by the
// audit line, and by `--cue-test`, which measures the four properties that matter
// and never looked at a pixel: a bid crosses 0.75 inside 120 ms, a listening
// noise settles below it, being owed a turn arrives sooner and goes further, and
// all of it leaves again.
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

  /// Eased position on the continuum. Everything downstream is a function of this
  /// one number, which is what makes backchannel-to-claim a morph rather than a
  /// swap.
  private(set) var level: CGFloat = 0

  /// Where the level wants to be, before easing.
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
  }

  var idle: Bool { level < 0.01 && target == 0 }
  /// For `--cue-test`: how long the level takes to get from wherever it is to
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

  // ── NO `draw`, DELIBERATELY ─────────────────────────────────────────────────
  //
  // There were ninety lines here: three capsules whose height and length were
  // functions of `level`, a dark halo so they survived a bright wall, an accent
  // glow above 0.5, and a gradient head sweeping along the bar every 900 ms above
  // 0.6. Every one of those was doing its job. All of them were the thing the
  // person using this app asked not to see -- see the file header.
  //
  // The class is not a leftover. `level` is read three times on the live path:
  // `TurnCues.tick` uses `vocal == 0` to know the far end has actually stopped
  // before it expires a caption, `describe` puts both on the audit line, and
  // `--cue-test` measures the easing. Nothing draws it, and the only correct way
  // to say that is to have no drawing code at all rather than an early return
  // somebody will later "fix".
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
/// ── HOW LONG A CAPTION LIVES, WITH A RIG OVERRIDE ON IT ──────────────────────
///
/// A caption is a cadence like every other one in this app, and every other one
/// has a way for a test to compress it. This did not, and it cost a real
/// diagnosis: `immersive-check` proves the row can fade while the words stay,
/// which needs one audit holding both facts at once. The words expire 2.2 s after
/// they arrive; the rig's presses queue by up to 1.5 s on a loaded machine. So on
/// a quiet machine it passed and on a busy one it reported "the subtitles broke"
/// -- a rig failing for a reason that has nothing to do with its subject, which
/// is how a rig stops being believed.
///
/// A MULTIPLIER rather than an absolute, so the three lifetimes keep their
/// relationship to each other -- an interim caption still goes before a final
/// one, and the twelve-second backstop still outlives both. Nothing in the app
/// sets it; the shipped behaviour is scale 1.
enum CaptionClock {
  static let scale: Double =
    (ProcessInfo.processInfo.environment["TK_CAPTION_SCALE"].flatMap { Double($0) })
      .map { max(1.0, $0) } ?? 1.0
}

// ── ONE BAND, ONE VOICE ──────────────────────────────────────────────────────
//
// This used to draw two lines: theirs, left-aligned, and YOURS, right-aligned,
// smaller and dimmer, whenever your own microphone was not the audible one. That
// half is gone, and it is worth writing down why, because it did not stop working
// -- it stopped being reachable.
//
// The rule for subtitles is now the one they were always for: if somebody's voice
// cannot be heard, the OTHER person reads it. Which means your own words never
// belong on your own screen, and the only surviving call to `setMyWords` in the
// whole shipping path passed `""` -- main.swift, once, to clear a caption that
// nothing could ever have set. Layout, fitting, fade and height arithmetic for a
// line that could not appear.
//
// That is `dead-controls-declared-never-wired`, which this app has now paid for
// four times: a control that compiles, draws, validates and is invoked, and does
// nothing, reads as finished to everybody including the person who wrote it. The
// choice was to remove it or to name a case that still reached it. There is no
// such case, so it is removed, and `tools/subtitle-check.sh`'s "only once"
// assertion is now true by construction rather than by observation.
final class CaptionBand: NSView {
  // Clear, over the HIG's dim. The band floats in the MIDDLE of the window, where
  // neither scrim reaches, so it is on its own for contrast -- and it is two lines
  // of somebody's speech, which is the most reading anyone does in this app.
  private let glass = Glass("caption", radius: 0, textual: true)
  private let holder = NSView()
  private let theirs = NSTextField(labelWithString: "")

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
    theirs.font = Type_.said
    theirs.textColor = Palette.fg
    theirs.backgroundColor = .clear
    theirs.isBordered = false
    theirs.alignment = .left
    // ── A LABEL DOES NOT WRAP BECAUSE YOU ASKED IT TO, AND ORDER MATTERS ─────
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
    theirs.usesSingleLineMode = false
    theirs.cell?.wraps = true
    theirs.cell?.isScrollable = false
    theirs.lineBreakMode = .byWordWrapping
    theirs.maximumNumberOfLines = 2
    holder.addSubview(theirs)
    // Handed over, not stacked. `NSGlassEffectView` guarantees nothing about the
    // z-order of arbitrary subviews and resamples the ones it catches -- which is
    // how every glyph in this app came out soft the first time it was tried.
    glass.content = holder
    alphaValue = 0
  }
  required init?(coder: NSCoder) { fatalError() }

  var theirText = "" { didSet { if theirText != oldValue { dirty = true } } }
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
    guard !theirText.isEmpty else { return 0 }
    return ceil(CaptionBand.pad * 2 + CaptionBand.lineHeight(Type_.said) * theirLines)
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
    // The text inside the two-line well is bottom-anchored: one line sits on the
    // floor of the well, and the second appears ABOVE it. That is what makes a
    // caption roll instead of jump.
    let need = heightOf(theirs, width: innerW)
    theirs.frame = NSRect(x: CaptionBand.pad, y: CaptionBand.pad, width: innerW, height: need)
    theirs.isHidden = theirText.isEmpty
    if ProcessInfo.processInfo.environment["KIN_CUE_DEBUG"] != nil {
      let cs = theirs.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: innerW, height: 1e5))
      fputs("band: w=\(Int(w)) inner=\(Int(innerW)) need=\(need) frame=\(theirs.frame)"
          + " single=\(theirs.usesSingleLineMode) wraps=\(theirs.cell?.wraps ?? false)"
          + " lbm=\(theirs.lineBreakMode.rawValue) maxLines=\(theirs.maximumNumberOfLines)"
          + " cellSize=\(cs.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-")"
          + " len=\(theirs.stringValue.count)\n", stderr)
    }
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

// ── THE WORDS, PLACED ────────────────────────────────────────────────────────
//
// One view over the whole window holding the bloom and the band, with a single
// 30 Hz tick that stops itself the moment there is nothing moving. It passes
// every click through: none of this is a control, and the quickest way to break a
// call is to put a transparent rectangle over the hang-up button.
//
// It also owns `cue`, which draws nothing. The eased level is what tells the band
// whether the far end has ACTUALLY stopped talking -- see the expiry rule in
// `tick` -- and it is on the audit line so a rig can read it. It used to be a
// third view; see the file header for the photograph of what that looked like.
final class TurnCues: NSView {
  private let cue = FloorCue(frame: .zero)
  private let bloom = BloomLabel(frame: .zero)
  private let band = CaptionBand(frame: .zero)
  private var timer: Timer?
  private var lastTick = CACurrentMediaTime()

  /// How far off the bottom of the window the band floats. Set by the owner,
  /// because the owner is the thing that knows how tall the button row is.
  var bottomInset: CGFloat = 110 { didSet { needsLayout = true } }

  /// Eased band height, so a caption growing from one line to two slides instead
  /// of snapping. It does NOT ease up from nothing -- see `tick`.
  private var bandH: CGFloat = 0
  private var bandA: CGFloat = 0
  /// When the other person's words last changed. The band holds for a moment
  /// after they stop and then goes, because a caption of a sentence that finished
  /// ten seconds ago is litter on somebody's face.
  private var theirsAt: CFTimeInterval = -1
  private var theirsFinal = false

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    addSubview(band)
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

  /// A listening noise, as a word. Anything too long to BE a listening noise
  /// falls through to the caption band rather than being dropped: whatever the
  /// classifier believed, those are words somebody said and the quiet side is not
  /// allowed to lose them.
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
  /// How opaque the caption actually is, and how much of the height it needs it
  /// actually has. `--press band-rise` counts frames against these: "the app
  /// decided to show a caption" and "a person can read it" are two claims, and
  /// only the second one was ever the complaint.
  var testBandAlpha: CGFloat { bandA }
  var testBandHeightFraction: CGFloat {
    let want = band.wantedHeight
    return want > 0 ? bandH / want : 1
  }

  var describe: String {
    "cue=\(["quiet", "listening", "claiming"][max(0, min(2, cue.vocal))])"
      + "/\(String(format: "%.2f", cue.level))"
      + " bloom=\(bloom.alive ? bloom.word : "-")"
      + " theirs=\(band.theirText.isEmpty ? "-" : "\"\(band.theirText)\"")"
      + " band=\(String(format: "%.0f", bandA * 100))%"
  }

  // ── THE TICK ───────────────────────────────────────────────────────────────

  private func wake() {
    guard timer == nil else { return }
    lastTick = CACurrentMediaTime()
    // 30 Hz. It moves one text field and eases two numbers; the audio thread will
    // never notice it, and it stops as soon as everything has settled.
    let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
    // `.common`, or it freezes solid the whole time a menu is open or a window is
    // being dragged -- which are two of the moments somebody is most likely to be
    // mid-sentence.
    RunLoop.main.add(t, forMode: .common)
    timer = t
    // ── AND ONE FRAME NOW, NOT IN 33 ms ───────────────────────────────────────
    //
    // `Timer` does not fire when you create it. So every caption that arrived
    // while the layer was asleep -- which is EVERY first caption of a turn, since
    // the layer stops itself between turns -- waited a whole frame before the
    // words were laid out and placed, on a channel whose brief is "real time with
    // zero latency". A third of the receive-side budget, spent doing nothing.
    //
    // Last, because `tick` can invalidate the timer it has just been handed
    // (`setTheirs("")` wakes a layer with nothing in it), and this way that is
    // simply the correct outcome rather than a nil `timer` being overwritten.
    tick()
  }

  private func tick() {
    let now = CACurrentMediaTime()
    let dt = CGFloat(min(0.1, max(0.001, now - lastTick)))
    lastTick = now

    cue.step(dt)
    let rise = bloom.step()

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
      if (quiet && since > (theirsFinal ? 1.6 : 2.2) * CaptionClock.scale)
          || since > 12 * CaptionClock.scale { band.theirText = "" }
    }
    // ── HOW WIDE, BEFORE ASKING HOW TALL ─────────────────────────────────────
    //
    // `wantedHeight` asks how many lines the words need, and that answer depends
    // entirely on how wide the band is -- and the width was set in `place`, which
    // runs at the BOTTOM of this function. So the first frame of every caption
    // measured a two-line sentence against the previous frame's width, which for
    // a caption arriving from nothing is zero, and reserved one line for text
    // that needed two. Caught by `--press band-rise`, which reported the band at
    // 79% of the height it needed on frame one -- a clipped second line for one
    // frame, which is exactly the regression this file has shipped before at a
    // slower speed.
    band.setFrameSize(NSSize(width: bandWidth(), height: band.frame.height))
    band.refit()
    let wantH = band.wantedHeight
    let wantA: CGFloat = wantH > 0 ? 1 : 0

    // ── APPEARING IS NOT THE SAME MOVE AS CHANGING ───────────────────────────
    //
    // Both of these used to be one symmetric ease: alpha toward its target with a
    // 180 ms time constant, height with 120 ms, up and down alike. Measured on
    // the real band by `--press band-rise`, driving it at a fixed 30 Hz:
    //
    //   before   readable (90%) after 12 frames = 400 ms, full after 27 = 900 ms
    //            and the band was 30% of the height it needed on frame one
    //   after    readable and full on frame ONE, 33 ms, at full height
    //
    // Four hundred milliseconds of a caption fading up is not a style choice on a
    // channel whose written requirement is "optimised for easy readability and
    // real time with zero latency" -- it is a third of the whole receive-side
    // budget, spent making words hard to read. And for the first frames of it the
    // text was laid out inside a well shorter than it needed.
    //
    // The asymmetry is the fix, and it is the same one the floor level has used
    // all along: the cost of a caption arriving late is that somebody cannot read
    // it, and the cost of one leaving slowly is nothing at all. Appearing from
    // nothing is not eased at all -- broadcast captions have cut straight in for
    // forty years -- and everything after that still slides, so a sentence that
    // grows a second line does not jump.
    let appearing = bandA < 0.005 && wantA > 0
    if appearing {
      bandA = 1; bandH = wantH
    } else {
      bandH += (wantH - bandH) * min(1, dt / 0.12)
      bandA += (wantA - bandA) * min(1, dt / (wantA > bandA ? 0.04 : 0.30))
    }
    if abs(wantH - bandH) < 0.5 { bandH = wantH }
    if abs(wantA - bandA) < 0.004 { bandA = wantA }

    place(bloomRise: rise)

    // Stop when nothing is moving. A timer that runs for the whole call to draw
    // nothing is the kind of thing that shows up later as "the app warms my legs".
    if cue.idle, !bloom.alive, bandA < 0.005, bandH < 0.5 {
      timer?.invalidate(); timer = nil
      band.isHidden = true
    }
  }

  override func layout() {
    super.layout()
    place(bloomRise: 0)
  }

  /// One place that knows how wide a caption is, because `tick` has to ask
  /// before it can know how tall, and `place` has to ask again to put it there.
  private func bandWidth() -> CGFloat {
    let w = bounds.width
    return min(w - Metric.gutter * 2, CaptionBand.maxWidth,
               max(360, w * CaptionBand.widthFraction))
  }

  private func place(bloomRise: CGFloat) {
    let w = bounds.width, h = bounds.height
    let bw = bandWidth()
    band.isHidden = bandA < 0.005
    band.alphaValue = bandA
    band.frame = NSRect(x: (w - bw) / 2, y: bottomInset, width: bw, height: max(0, bandH))
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
