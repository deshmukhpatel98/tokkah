# Liquid Glass, in Kin

The app's material, its geometry and its type ramp, and the rig that proves any of
it. Written 2026-08-25, against macOS 27.0 (build 26A5416b) and Swift 6.3.3.

Source of truth is `mac/Sources/tk/Glass.swift`. This file is why.

---

## 1. The glass was not glass

`Controls.swift` had a class called `Glass`. It was an `NSVisualEffectView` with a
flat fill painted over the blur:

```swift
material = .hudWindow                            // a real blur
layer?.backgroundColor = rgba(10, 14, 22, 0.72)  // ...covered up entirely
```

A 72%-opaque dark rectangle over a blur is a dark rectangle. Photographed through
the window server, over a real face, the control row was six opaque grey discs.

**It survived every screenshot ever taken of it**, and the reason is recorded in
`Display.swift` already: the app photographs its own *layer tree*, and a layer tree
cannot see a material. So every design check was a flat fill over black compared
against a flat fill over black — an instrument that returns the same picture
whether the material is there or not.

Two rules fall out of that, and they generalise past this change:

- **A material can only be judged through the window server.** `screencapture -l
  <id>`. The window id is printed at startup by both `Display.open` and
  `Launcher.askRoom` for exactly this.
- **A material can only be judged over content.** Glass over black is
  indistinguishable from paint over black. Every shot below is over a real decoded
  video frame.

---

## 2. What Apple actually says

Four rules from the HIG (*Materials*) and the *Liquid Glass* technology overview.
Every decision in `Glass.swift` traces to one of them.

| Rule | Quote | What it decided here |
|---|---|---|
| Glass is the **functional** layer | "Don't use Liquid Glass in the content layer." | The picture never gets a material. The bar, pills, sheet and cards float above it. |
| **Clear** over rich content | "Only use clear Liquid Glass for components that appear over visually rich backgrounds." | **Every** surface is `.clear`. The content of this app is a live face, and there is no variant parameter left to choose anything else with. |
| ~~**Regular** under text~~ | "…when components have a significant amount of text, such as alerts, sidebars, or popovers." | **Overruled.** This is the guidance for the sheet and the waiting card and it is not followed — see below. |
| **Dim** behind clear | "If the underlying content is bright, consider adding a dark dimming layer of 35% opacity." | Taken at 35%, and confined to each control's own rounded rectangle. Every window-sized version of it has been deleted. |
| **Sparingly** | "…overusing this material in multiple custom controls can provide a subpar user experience by distracting from that content." | Nothing is glass-on-glass. See §4. |

### Where this app departs from the guidance, and why

Two instructions from the person whose app it is, on two different days:

> "everywhere I want transparent liquid glass, not frosted"

> "there should be no vignette of any kind. There should not be any effect. It
> should all be very natural."

The first overrules the `.regular` row above. `.regular` is what Apple names for
panels full of sentences, and the sheet and the waiting card are exactly that; they
are clear anyway. The legibility job `.regular` was doing is now `Glass.dim`, a dark
layer **under** the material rather than a blur in it — measured, that keeps the
words readable while leaving the picture visibly moving behind them.

The second is stricter than the HIG's dimming rule, not a reading of it. Four
`CAGradientLayer`s used to dim the window: 190 pt up from the bottom, 130 pt down
from the top, a window-wide radial ellipse behind the waiting card, and one over the
join window's camera preview. Each cited the 35% sentence. Together they were a
vignette, and nobody reads a vignette as a legibility device — they read it as the
video being broken. Measured on a flat, evenly lit source frame, the old build
rendered the top of the picture at **0.758** and the bottom at **0.662** of the
middle, with the centre **1.186** darker than the sides. On a real talking head the
bottom edge of the frame came back **1.45×** brighter once they were gone.

So: **the picture gets nothing.** The only dimming device left is `Glass.dim`, whose
bounds are the control's bounds. A dark patch the size of a button is part of the
button; a dark patch the size of the window is something painted on the person.

---

## 3. Three findings the docs do not tell you

Measured on this machine, not inferred.

### 3.1 Content must go in `contentView`, not on top

Stacking the glyph as a sibling *above* the glass — the way the old
`NSVisualEffectView` version worked — renders, but **softly**. Every 1.8 pt stroke
came out mushy and haloed, while the one button with no glass behind it (the red
leave circle) stayed razor sharp. Same drawing code; the material was the only
difference.

The header says why, as a warning rather than an aside:

> `NSGlassEffectView` only guarantees the `contentView` will be placed inside the
> glass effect; arbitrary subviews aren't guaranteed specific behavior with regard
> to z-order in relation to the content view or glass effect.

A sibling is arbitrary. It gets caught in the effect's own resampling — the
treatment the material is supposed to give the picture *behind* it. `Glass.content`
hands it over instead, and falls back to `addSubview` on the paths with no glass.

### 3.2 `tintColor` cannot produce a strong colour

The tint is what the glass tints the background *toward*, so it blends with
whatever is behind it. On the hang-up button, `#ef4444` photographed as maroon at
alpha 0.82 **and** at 0.96 — right hue, wrong brightness, on the one control that
has to be unmistakable.

The colour is a fill painted **behind** the glass by `IconButton.draw`, so the
material refracts a red field instead of a blue jacket. Bright red, and still
glass: it keeps the specular rim and the interactive response, and the glyph stays
crisp because it lives inside the material.

The tint is still set, at 0.35 — just enough to stop the material cooling that red
back toward the picture.

### 3.3 The container's `spacing` is a dial, not a style

`NSGlassEffectContainerView.spacing` merges shapes closer together than its value.
Measured with five 58 pt circles at an 18 pt gap:

| spacing | result |
|---|---|
| 0, 18 | five separate circles |
| **40** | liquid bridges form — joined, still readable as five |
| **80** | one continuous blob |

So the row sits at **12** at rest (below the gap: five distinct targets, because
they are five different actions and one of them hangs up), and is animated to
**64** while the row collapses into the leave confirmation. The four circles
*pour into* the button that remains instead of blinking out.

This is the only reason the row lives in a container. No arrangement of separate
views can do it.

---

## 4. Glass on glass, and what replaced it

The waiting card was built out of `Glass` all the way down: glass buttons and glass
fields on a glass panel. It rendered, and it was wrong twice — against the
guidance, and visually, because each pane dims the one behind it, so the panel that
was supposed to be *the surface* ended up the murkiest thing on screen.

A material establishes **one** functional layer. Everything inside it is fills and
vibrancy — `Vibrant` in `Glass.swift`, which is what the sheet's rows already did.

| Surface | Material |
|---|---|
| Bar circles, `more` | `.clear` glass, interactive, each over its own 0.35 dim |
| Leave | `.clear` glass over a red fill, tinted 0.35 |
| Status / warning pills | `.clear` glass over a 0.35 dim |
| Sheet, waiting card, join card | `.clear` glass over a 0.35 dim |
| Anything **inside** those | `Vibrant` — a rounded fill + hairline |

Seventeen surfaces in the call window and two in the join window, and the table is
no longer the source of truth for any of them: each one states what it is at
runtime (`Glass.describeGlass`, printed by `--press "?"`) and `tools/glass-check.sh`
compares that against the policy. This table was wrong for months and nothing could
tell — see §9.

`Palette.glassTint` is gone. It was set on the sheet, the waiting card and the join
card, and at 0.18 it was described in the source as "barely there". It was not on
its own: it sat on `.regular`, over a 0.55 radial wash. Four dimming devices
stacked, three of them invisible from the source of any one of them.

---

## 5. Geometry

The radii were nine magic numbers that disagreed: sheet 20 with rows of 12 inside
10 pt of padding, pills 13, two fields 14, the confirm morph 24, the self-view 12.

Apple's rule is **concentricity** — a nested corner shares its centre of curvature
with the corner outside it, which happens exactly when

```
inner radius = outer radius − the padding between them
```

`Metric.concentric` is that subtraction. Nothing nested is given a literal radius
any more.

- Sheet 26, padding 10 → rows **16** (was 12, which looks deliberate and is off by four)
- Card 30, padding 22 → fields **8**, which at a 36 pt field resolves to a capsule anyway
- Window 32, gutter 20 → self-view **12** — the old literal was right, for a reason
  nobody had written down, and would not have survived the window corner changing

AppKit exposes this as `NSViewCornerConfiguration`, but `NSView.cornerConfiguration`
is **read-only** — the system sets it for its own views and there is no setter to
adopt. Hence the arithmetic.

Everything else is on a 4 pt grid (`Metric.s1`…`s8`), and every font is one of nine
names in `Type_`. There are no size or radius literals left in `Controls.swift`,
`Launcher.swift` or `Display.swift`.

---

## 6. What moved, and why

- **The bar floats.** `barInset` 14 → 24. At 14 a 58 pt circle sat almost against
  the frame. `CallControls.barHeight` is derived from it now, so the self-view
  cannot be left overlapping the row when it moves again.
- **The sheet comes out of the button that opened it.** It was `bottom: 0; left:
  50%`, a phone tray glued to the window's bottom edge — which is where the control
  row is. Photographed open, the mute and camera circles showed *through* the panel
  and a line of hint text ran across them. It now hangs under `#more`, right edges
  on the same gutter: *"an action sheet originates from the element that initiates
  the action."* The grip went with the tray; nothing there is draggable.
- **The waiting card is one card.** Title, hint, link, two buttons, a field and a
  third button used to drift separately over somebody's picture, each carrying its
  own `text-shadow: 0 1px 8px rgba(0,0,0,.85)`. Seven shadows is what a screen looks
  like when nothing on it has a surface to sit on.
- **The join window is the call window.** It was stock AppKit — a grey text field,
  `.rounded` bezels, `.inline` chips, a camera box bolted to the top half. Now:
  camera edge to edge, one pane of glass holding everything. Reachable via `--gui`.
- **No hand-drawn borders on glass.** Liquid Glass draws its own specular rim. The
  1 pt hairline is back in the *ink* (inside the material) because over a dark navy
  jacket the system rim nearly vanishes and four edgeless discs are four things you
  have to look for. Under it, the material resampled it into a soft grey band.

---

## 7. Accessibility

`Glass` collapses to an opaque surface under **Reduce Transparency**, and rebuilds
live if it is switched on mid-call. `Motion.pop` and the merge animation are off
under **Reduce Motion**.

Both are unreachable on a test machine without changing a system accessibility
setting, which a test run has no business doing to somebody's Mac. So both have rig
overrides, the way every other cadence in this program does:

```bash
TK_REDUCE_TRANSPARENCY=1 tk --room x --window
TK_REDUCE_MOTION=1        tk --room x --window
```

Nothing in the app sets either. The first shot taken this way found a real defect:
the opaque surface covered the red fill behind it, so the hang-up button was the
same dark disc as mute and camera. A person who has turned transparency off is
exactly the person who should not be asked to find a hang-up button by shape alone.
`applyTint` now colours the opaque paths too.

---

## 8. The rig

Two `tk` processes on distinct ports, a real talking head as the far end's camera,
captured through the window server.

```bash
# connected call, real video behind the controls
shoot.sh out.png                 # optionally: shoot.sh out.png "more"  (press tokens)
SOLO=1 shoot.sh waiting.png      # no far end -> the waiting card
NEARVID_OVERRIDE=<file.mov> shoot.sh peek.png "@peek:3.5"
shoot-gui.sh join.png            # the --gui window
shoot-app.sh real.png            # the signed .app from /Applications
```

Three things the rig gets right that the previous one did not:

1. **Distinct ports per process** (7101/7102). Both defaulting to 7001 is a
   20-second `bind:` retry loop that looks like a hang.
2. **The near end has a camera too.** It was `--video off`, which photographed the
   waiting screen as a black void — which it never is. `Display.showSelf` is
   explicit: *"Before the far end arrives you ARE the window."* Judging that card
   against black was judging a screen that does not exist, and it hid a real defect
   for as long as it ran (§9).
3. **It reads the window id the app prints** rather than sleeping a guess.

Interaction is checked separately, and by clicking — `--press "?,@mic,?"` runs the
hit-test audit over every control and then sends a real synthetic `NSEvent` through
`window.sendEvent`. Wrapping the row in two container views put two new `hitTest`
implementations between a finger and a button, and this file has paid for that
twice before. Every control audits `OK`, and `@mic` actually mutes.

---

## 8a. `glass-check.sh`, and the three kinds of evidence

```bash
mac/tools/glass-check.sh          # KEEP=1 to keep the photographs
```

Structural, photometric and vignette, because each is blind to something the others
catch, and **every one of them has an arm that must rank the other way**:

| Evidence | What it sees | The arm that must fail |
|---|---|---|
| **Structural** | what each of the 19 surfaces asked the system for, including ones not on screen | `TK_GLASS_STYLE=regular` — the audit has to report `regular`, or it is reading the argument and not the object |
| **Photometric** | what a camera sees through the card over 40 pt bars of two bright saturated colours | `TK_REDUCE_TRANSPARENCY=1` — an opaque rectangle, which must measure near zero |
| **Vignette** | what the app did to a flat, evenly lit frame; every ratio is 1.000 or the app painted something | the old bottom scrim re-applied to the same photograph — the meter has to see it |

`glass-measure.py --calibrate` runs first and is fatal. It asks the ruler six
questions whose answers are already known (a bare photograph, a 35% dim, a heavy
blur, opaque paint, and white text on two greys whose contrast ratios are
arithmetic). That is not ceremony — it caught three blind instruments, in §9.

Two things the rig cannot do, stated rather than hidden:

- **The material renders differently when Kin is not the front application** —
  0.67 of the picture surviving the card when it is, 0.17 when it is not, stable to
  three decimals within a run and flipping between runs of an identical command.
  The rig's own null A/B (four identical runs) puts its noise at **0.0003**, which
  is what proved the two modes were real. A rig has no business bringing a window
  to the front on a Mac somebody is using, so the clear-versus-frosted comparison
  *in pixels* only lands some runs; it is printed as not-reached otherwise. The
  structural half catches a frosted app in either state.
- **A real sensor**, as in §10.

---

## 9. Defects this found

- **A black rectangle behind the invite link.** `urlGlass.layer?.backgroundColor =
  rgba(8,11,18,.9)` was harmless when `Glass` *was* the blur. Once `Glass` became a
  wrapper, its own layer was the un-rounded outer box, so the line painted a
  hard-edged opaque rectangle across the material and out past its corners.
  Invisible for as long as the screen was shot over black — which was every
  screenshot ever taken of it.
- **The sheet overlapped the control row** (§6).
- **The hang-up button vanished under Reduce Transparency** (§7).
- **The self-view mirror is fine.** The peek tile reads `NASA` correctly, which
  looked like the mirror had stopped working. `talkingheadB.mov` is *itself* a
  pre-mirrored clip — the app un-mirrors it, which is the transform working. Checked
  before reporting, which is the only reason it is not in this list as a bug.

### And these, from the transparency pass

- **A header describing a policy the code never implemented.** §2 above said "the
  five bar circles and `more` are `.clear`" and it was true of those six surfaces
  and false of the other thirteen, every one of which spelled `.regular` at its own
  call site. `grep "variant: \.clear"` returned nothing at all. That is why every
  surface now *states* what it is into the log and a rig compares it: a comment is
  not a policy.
- **Every rig in `mac/tools` was stealing the user's focus.** `Display.open` moved
  the window into a corner, made it click-through and put it on the desktop level
  under `TK_NO_RAISE` — and then called `NSApp.activate(ignoringOtherApps: true)`
  unconditionally on the next line. Three comments explained why it must not. It
  surfaced as a measurement problem (§8a) before anyone noticed it as a rudeness.
  `Launcher.askRoom` had never honoured `TK_NO_RAISE` at all, which is why the join
  card was the one surface no rig had ever photographed.
- **The self-view tile threw a 14 pt black shadow onto the far end's face.**
  A drop shadow is a vignette that happens to be shaped like a rectangle. Removed;
  the 1 pt hairline every other floating control has is the whole of the edge.
- **Three blind instruments, all caught by calibration and control arms.** The
  transparency meter built its reference by joining the strip left of the card to
  the strip right of it, putting a phase break in a periodic pattern — it then
  reported that *nothing* survives a clear pane, a heavy blur or a sheet of paint:
  the same catastrophic-looking answer for all three. The contrast meter found text
  by brightness, so on a light background it classified the background as text and
  returned no reading in the one case that had to fail loudly. And the vignette
  check once passed on a photograph of a **black window** — all four arms shared one
  room name, the rendezvous believed a peer had come and gone, and a uniformly
  black rectangle has no vignette in it. Only the control arm caught that one: you
  cannot darken black.

---

## 10. Not proven here

- **A real sensor.** Camera access is denied for `com.tokkah.tk` on this machine —
  for the CLI binary *and* for the signed `/Applications/Kin.app`, so the local
  preview and the self-view are the far end's decoded `.mov` in every shot above.
  For a chrome change this is sound: the material refracts whatever the display
  layer presents, and a decoded frame through `AVSampleBufferDisplayLayer` is the
  same pixels either way. It is **not** sound for anything about the camera itself.
- **A real remote call.** Both ends were on localhost. Nothing here touches media,
  timing or the network, and `--selftest-rename`, `--selftest-install` and
  `--selftest-identity` all pass — but the standing rule in this project is that a
  feature is proven on a live prod call, and this has not had one.
- **A Mac without Liquid Glass.** The `macOS < 26` branch compiles and is the old
  `NSVisualEffectView` treatment unchanged, but no machine here can run it.
- **Light appearance.** The app is dark-only by construction (`Palette.bg`, vibrant
  dark). Untouched, and untested, as before.
