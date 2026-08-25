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
| **Clear** over rich content | "Only use clear Liquid Glass for components that appear over visually rich backgrounds." | The five bar circles and `more` are `.clear`. They carry glyphs and float over a live face. |
| **Regular** under text | "…when components have a significant amount of text, such as alerts, sidebars, or popovers." | The sheet, the waiting card, the status pills. |
| **Dim** behind clear | "If the underlying content is bright, consider adding a dark dimming layer of 35% opacity." | The bottom scrim went from **0.72 → 0.35**. A top scrim was added at 0.28. |
| **Sparingly** | "…overusing this material in multiple custom controls can provide a subpar user experience by distracting from that content." | Nothing is glass-on-glass. See §4. |

The 0.72 scrim was transcribed from the web app's CSS, where it had to be that dark
because there was no material at all — legibility fell entirely on the scrim. At
0.72 it was a black band across the bottom of somebody's face. There is a material
now, so the scrim is a shadow.

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
| Bar circles, `more` | `.clear` glass, interactive, over a 0.35 dim |
| Leave | `.clear` glass over a red fill, tinted 0.35 |
| Status / warning pills | `.regular` glass |
| Sheet, waiting card, join card | `.regular` glass, tinted `glassTint` |
| Anything **inside** those | `Vibrant` — a rounded fill + hairline |

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
