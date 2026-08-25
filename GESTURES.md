# Two gestures on one circle, and a hold that ends a call

What was asked for, verbatim: *"A long press on the self view button should show
you self view. But a single click on the self view should take you to contacts
where you can just click on handles or, like, pictures of people, like circles,
their profile picture, and instantly call them. A long press on the red thing
should disconnect the call instead of you having to click twice to disconnect.
Like, really consumer grade, amazing user experience."*

Three gestures and one new surface. Anchors below were resolved against the tree
on 2026-08-24. Nothing here is implemented.

---

## F1 — the self-view picture cannot be clicked, and the reason is a design decision

`Display.peeking` (`Display.swift:328-357`) is the **only** thing that unhides
`selfLayer`, and the comment above it says why out loud — *"NO PERSISTENT
MIRROR"*, the web app's own ruling that an ambient tile is the #1 measured
fatigue driver. `peeking` is fed from `CallControls.onPeek`
(`Controls.swift:1105`), which is fed from `IconButton.onHold`, which is true
only between `mouseDown` and `mouseUp` (`:345-349`, `:393-396`).

So during a call the self-view tile exists **only while a finger is physically
down on the peek button.** You cannot click the tile without releasing the button
that keeps it alive, and releasing hides it.

A hit target on that tile would be a control that can never be reached. That is
`dead-controls-declared-never-wired` in a new costume, and it is also
`a-hidden-control-returns-the-same-nothing-as-a-broken-one`: it would audit
green, screenshot fine, and never fire.

**But there is a real self view, and it is enormous.** Before the far end
arrives, `Display.showSelf` sends your camera to the *main* layer
(`Display.swift:372`, `if !selfViewOn`). Pre-connect, the self view is the whole
window.

So "single click on the self view" has two truthful readings, and they are
complementary rather than competing:

| reading | when it exists | verdict |
|---|---|---|
| **A** the peek **button** — the thing the same sentence calls "the self view button" | always | **build this.** One control, two gestures |
| **B** the pre-call full-window self picture | until someone arrives | **build second.** The literal reading, and it is nice |
| **C** the peek **tile** | only while held | **refuse.** Unreachable by construction (F1) |

---

## F2 — what owns that region today: the window drag

`CallControls` has no `hitTest` override. The five that exist are `Glass:57`,
`IconButton.Ink:278`, `SheetRow:605`, `WaitingCard:918`, `ScrimView:1874` —
none of them is the container. So the default applies: deepest descendant, else
self.

Walk the tile region (`Display.selfFrame`, `Display.swift:41-56` → x 12…252,
y 76…211) against `CallControls`' subviews in reverse z-order:

- `camPicker`, `camGlass` — hidden (`Controls.swift:1162-1164`, `:1263`)
- `waiting` — `hitTest` returns nil except on `urlGlass`/`share`/`copy`
  (`:918-922`), all centred
- `sheet`, `sheetScrim` — hidden while closed (`:1226-1227`)
- the button row — y 14…72 (`bottomPad` 14 + 58, `:1195`, `:1212`). The tile
  starts at y 76. **Four points of clearance**, disjoint but tight; anything that
  grows the tile or the bar collides.

→ `CallControls` answers, `CallControls.mouseDown` (`:1533-1538`) calls
`super.mouseDown`, the responder chain reaches the window, and
`window.isMovableByWindowBackground = true` (`Display.swift:93`) turns it into a
**window drag**.

That is the behaviour a tap target there would take away, and with
`.fullSizeContentView` plus a hidden title (`Display.swift:91-92`) the picture is
most of the drag surface this window has. Any tap target over the video must give
the drag back — see §B.

## F3 — a tap on peek is currently an unclaimed gesture

`IconButton.mouseDown` returns before `super.mouseDown` when `onHold != nil`
(`:346`), so `peekButton` never sends an action, and `Controls.swift:1105`
assigns `onHold` and no target. A quick click today is: `holding` true, then
immediately false — a self-view flash lasting one click, or with
`localFrames == 0` nothing at all (`Display.swift:346-351`).

**Claiming the tap costs no existing behaviour.** That is the cheapest of the
three gestures and the reason to build it first.

---

## The thresholds, and why there is no ambiguous band

| gesture | boundary | if it fires wrongly |
|---|---|---|
| peek: tap → people, hold → self view | **220 ms** | a panel you dismiss, or a flash of your own face — **recoverable both ways** |
| leave: hold → hang up | **600 ms** | the call is over — **irrecoverable** |

They cannot share a number, and the numbers are not guesses.

**220 ms for peek.** The hold watchdog polls at 150 ms
(`Controls.swift:362`), so anything at or under that races it. Deliberate
mouse-click durations sit well under 200 ms; 220 ms is above every one of them
and below anything a person experiences as lag — which matters because peek is
the control that answers "is my camera working" and `instant-everywhere` applies
to it. It is also a *classifier* and not a delay: see the next section.

**600 ms for leave.** It must be far enough from 220 ms that muscle memory
trained on peek cannot end a call — 2.7× is that. It is above the 500 ms
long-press convention people already know from the phone in their pocket, so it
reads as a gesture rather than a slow click. And it is far below the 3 s
disarm timer (`Controls.swift:1603`), so the pill cannot expire under a finger
mid-hold.

**There is no dead zone, in either gesture.** A dead zone is a control that
sometimes does nothing, which is worse than either wrong outcome. One boundary,
two outcomes, always exactly one:

- **peek** — release before 220 ms → tap (people). Release at or after 220 ms →
  it was a hold, the hold already did its job, and the release just ends it.
- **leave** — release before 600 ms → cancelled, and the pill **stays armed** for
  the rest of its 3 s still reading "hold to leave", so someone who under-held
  sees the target still sitting there and simply presses again. Release at or
  after 600 ms → already gone; the release lands on a window that is closing.

So: nothing is neither cleanly short nor cleanly long.

### Peek stays instant: reveal at down, decide at up

The naive build makes peek 220 ms slower, because you cannot show the tile until
you know it is not a tap. That is a real regression on the one control whose
entire value is a fast answer.

Instead:

- `mouseDown` → `onHold(true)` **immediately, exactly as today.** Peek's
  behaviour is byte-identical to the shipped version for every press ≥ 220 ms.
- `mouseUp` → `onHold(false)` always (the tile goes, as today), **and** if the
  press lasted < 220 ms, also fire `onTap`.

The entire cost is that a tap flashes the tile for up to 220 ms before the sheet
opens. Take the flash in v1: it is feedback that the press registered, and the
tile is bottom-left while the sheet opens bottom-centre. If it reads as noise, a
140 ms fade-in on `selfLayer` hides it — but that adds an animation to the
control that must not gain latency, so it is a second move and not the first one.
**Only a person can judge that**; it is not a threshold question.

This also preserves the scar the machinery was built around
(`Controls.swift:351-369`): `mouseUp` hides, the watchdog hides, and **the
watchdog path fires no tap.** A lost `mouseUp` — hold peek, Command-Tab away — is
not a click. Nor may the watchdog ever *complete* the leave hold: its job is
"nothing is being held", and a hold that fires because the app lost track of a
finger would hang up a call nobody was looking at.

---

## Gesture 1 — long press on peek: already built, and what would break it

`Controls.swift:289-296` documents it (`pointerdown` → show, `pointerup` → hide,
deliberately not a toggle) and `:345-402` is the machinery. Read as shipped, it
is correct. Verify rather than rebuild: `--press "@peek:1.0,~,?"` must show
`peek=true/held` while held and `peek=false` after.

Three things the new gestures could break in it, all avoidable:

1. **The instant reveal.** Covered above: reveal at `mouseDown`, classify at
   `mouseUp`. If anyone implements "wait 220 ms then show", peek gets slower and
   the regression will not appear in any assertion currently written.
2. **The watchdog's exemption.** `syntheticHold` (`Controls.swift:372`) is set
   only by `click(_:holdFor:)` (`:1856`) because the harness's button is not a
   finger and is invisible to `pressedMouseButtons`. A tap classifier that reads
   wall-clock duration works for both; one that reads `pressedMouseButtons` would
   silently classify every harness press as a hold.
3. **`mouseDragged` (`:397-400`) — "a hold survives the pointer leaving".** Keep
   that. A tap, by contrast, must not: a press that slides off the circle and
   releases elsewhere is a cancelled tap, the same rule `SheetRow.mouseDown`
   already implements (`:627-640`, *"you can slide off a row you did not mean to
   hit"*).

**The help string has to say both things.** `Controls.swift:1027` is
`help: "hold to see yourself"`, and it feeds both `toolTip` and
`setAccessibilityLabel` (`:317-318`). Two gestures on one control is genuinely
worse for VoiceOver than two controls, and the mitigation is that the gesture is
never the only way in: the ⋯ sheet carries a **People** row, the Call menu
carries **People…** (⌘⇧P), and `handleKey` (`:1659-1674`) grows one case beside
`a` and `v`. New string: `"tap for people · hold to see yourself"`.

---

## Gesture 2 — single click on peek: the people sheet

### Where contacts lives: the ⋯ More sheet, as a second page

Recommended over a new panel and over the launch window, for four reasons.

**It is the only surface that exists on both sides of the join.**
`CallControls` is built for every window (`Display.swift:147`), so the sheet is
there pre-connect (behind the `WaitingCard`) and mid-call. The launch window is
off the default path entirely: `shouldPrompt` returns `forced` only
(`Launcher.swift:42-44`) and a double-click mints a room and dives straight in
(`main.swift:231-243`). Building people there puts the feature where nobody goes.

**The launch-window landing is not mine to decide.** `CONTACTS.md:141-150` is
explicit: it reverses *"whenever you hit the site, the meeting starts"* and
spends the cold-launch budget the launch lane is earning right now — *"Do not
ship it without asking."* The sheet needs no such permission, and everything in
v1 is testable from it.

**`SheetRow` already solves every hard part, and each one was paid for once
already.** A `hitTest` that takes superview coordinates and tests `frame`
(`:605-613`); `acceptsFirstMouse` (`:598`); hover and press states; its own
`mouseDown` tracking (`:627-640`); a right-aligned monospace `value` (`:575`);
and a `spoken` string (`:578`) whose comment says it exists *because the harness
must click the list and read it back*. A new panel re-earns all of it.

**It already dismisses three ways, none of which need aiming**: a click on the
scrim (`:1113`), a swipe down (`:1114`), Escape (`:1661-1664`). A surface that can
open by accident must close without thought, and this one does.

Concretely: `Sheet` gains `page: .settings | .people`; `rebuildSheet()`
(`:1542-1577`) takes the page; the peek tap calls
`openPeople()` = `page = .people; if !moreOpen { toggleMore() }`. The ⋯ button
opens `.settings` as today and gains a **People** row at the top; `.people` gains
a back row. One sheet, two payloads, no new container, no new hit-testing.

### The rows: a subclass, so the scars are inherited and not re-derived

`ContactRow: SheetRow`, overriding `draw` to paint the avatar in the glyph slot
and widening `layout`'s text inset from 42 to 56 (`:674-678`). Three rules:

- **Do not override `isFlipped`.** `SheetRow` already sets it `false` (`:642`),
  and `:615-626` records why that was allowed: overriding it *"silently stopped
  every row from firing"* because `NSButtonCell.trackMouse` laid the cell out in
  one coordinate system and tested the mouse in the other — *"The row still drew
  perfectly, still highlighted on hover, still had a target and an action."* The
  override survives only because the click is tracked by hand at `:627-640`.
  Inherit both halves. Do not touch either, and above all do not "simplify" the
  manual tracking away — that is the same bug with the diff reversed.
- **The avatar is drawn in `draw(_:)`, not as a sublayer.** `Display.snapshot`
  is `cacheDisplay`-based (`Display.swift:270-274`) and cannot see a layer-only
  background; the blindness is already recorded at `Controls.swift:1078-1085`,
  where a scrim gradient ran backwards through every screenshot ever taken.
- **Nothing new gets added to `clickTargets`.** `Controls.swift:1779` already
  collects `sheet.rows` when the sheet is open, and a `ContactRow` *is* a
  `SheetRow`. Zero lines. That is the return on subclassing.

### The avatar: the hue lands on the ring and the letter, not on a filled disc

Deterministic from the handle:

```
h    = FNV-1a 32-bit over lowercased handle bytes   (basis 2166136261, prime 16777619)
idx  = h % 22
hue  = ((idx + 1) * 15) mod 360                     // 15°…330°, 22 buckets
```

- **FNV-1a, not `String.hashValue`.** Swift's `Hasher` is seeded per process.
  The same person would be a different colour on every launch — and, worse,
  *stable within a session*, so it would test green and only ever be reported
  from the field.
- **Not SHA-256.** Correct, and it drags CryptoKit into a drawing path for a
  value that needs 9 bits.
- **22 buckets at 15°, not 360 free hues.** Two contacts then either share a
  colour or are visibly different, instead of sitting 4° apart and reading as a
  rendering fault.
- **Steps 0 and 23 are dropped, which removes 345°–15°.** `Palette.bad`
  (0xef4444) is hue ≈ 0, and `Controls.swift:1124-1128` is explicit that
  `leave` is the only filled control on the screen — *"Filling three circles red
  put two more of them next to the one irreversible button."* A red avatar beside
  the hang-up is precisely that mistake. Dropping two buckets is cheaper than a
  rotate-if-inside-band special case.
- Hue from the **handle**, never from the local name. Names are local-only
  (`CONTACTS.md` §2) and renaming somebody must not change their colour, or the
  recognition the circle exists for is destroyed.

**A filled coloured disc with white text does not work, and here is the
arithmetic.** At S 0.62 / B 0.80, white on the blue end is 6.4:1 — fine — and
white on hue 60° (yellow) is **1.71:1**. Illegible. A single fixed
saturation/brightness cannot carry white text across the wheel, and solving for
constant luminance per hue is a numerical search inside a `draw` call.

So: a **dark glass disc, a 1.5 pt ring in the hue, and the initial drawn in the
hue** at S 0.55 / B 0.98. Worst case (deep blue) measures 5.2:1 against the
0x06080d ground; every hue clears 4.5:1. This is also the app's own rule already
written down at `Controls.swift:264-266` — OFF does not fill the circle red, it
turns the *glyph* red and keeps the surface glass. Same idiom, one row down.

Diameter 34 pt in a 48 pt row; initial 15 pt semibold. `handle.first` uppercased
— handles are `^[a-z][a-z0-9]{1,31}$` (`RINGING.md`), so the first character is
always a letter: no empty initial, no emoji, no combining marks.

**One conversion, easily missed:** `NSColor(hue:saturation:brightness:alpha:)`
is in the *calibrated* space and the rest of this file is `srgbRed:`
(`Palette.hex`, `Controls.swift:30-32`). Without `.usingColorSpace(.sRGB)` the
avatars drift away from the palette on a wide-gamut display, and this Mac has
one.

### The empty state — which is what ships first

No contacts, so the panel is mostly about the person's own handle:

```
People                                          (SheetHint, section label)
Call someone once and they'll show up here.     (SheetHint)
──
[D]  devesh                          copy       (handle row — avatar + handle + value)
Give this to someone and they can call you.     (SheetHint)
──
Call someone new                                (SheetRow, Glyph.link)
```

Copy is taken from `CONTACTS.md:294-298` rather than reinvented.

- **The handle row is literally the same row object in both pages.** One
  `handleRow()` constructor, used by `.people` and by `.settings`. The user asked
  for the handle in ⋯ More *and* it belongs on the people page; the way two
  presentations stay consistent is by being one, not by being kept in sync.
- It is **not** `inert` (unlike the encryption row at `:1571`) because there is
  something to press. Tapping it copies the handle and flips `value` to
  `"copied ✓"` for 1.8 s — same duration and same idea as
  `WaitingCard.confirmCopied` (`:853-860`). Do not use `checked` for this: the
  tick draws at `bounds.width - 30` and the value at `bounds.width - sz.width - 12`
  (`:707-735`), and they would overlap.
- **`mine == nil` is today's real state.** No `Identity.swift` exists. Then the
  row is replaced by a `SheetHint` reading *"Your name on Kin isn't set up
  yet."* — never a copy control over an empty value. A copy button that copies
  `""` is worse than no copy button.
- **Cap the list at six** (`.prefix(6)`). `Sheet` has no scroll view, and adding
  one is a new container with its own hit-testing — exactly what this design
  avoids. Stated as a known limit, not left as a surprise: at 5 contacts the
  sheet is already ~454 pt of a 720 pt window.

### The contact source: one small injectable thing

```swift
struct Contact { let handle: String; let name: String?; let lastCall: Date? }
protocol ContactSource { var mine: String? { get }; func contacts() -> [Contact] }
```

`CallControls.contactSource: ContactSource?`, **assigned at exactly one site**:
`Display.open`, beside `c.onMic = onMic; c.onCam = onCam; c.onLeave = onLeave`
(`Display.swift:149`), from a parameter `main.swift` passes.

The named site is the whole point. *A callback declared and invoked but assigned
nowhere reads as finished and does nothing* — three instances here, two of them
recorded in the files this design touches: `onPeek` was declared, called and
assigned nowhere, which is what *"the selfie feature is not working"* actually
was (`Display.swift:308-313`); and `sheetScrim` was added, framed, and wired to
nothing (`Controls.swift:1110-1113`).

v1 implementations: `StaticContacts` (from `--contacts-fake`, `mine` from
`--handle` or `NSUserName()`), and later `JSONContacts` over
`~/Library/Application Support/Kin/contacts.json` — 0600, staged-then-swapped
(`CONTACTS.md:110-114`). Note `grep -rn "Application Support" mac/Sources/tk/`
returns nothing: no code has ever written there.

**Nothing in the view reads a file and nothing in it knows about identity.**
`rebuildSheet(.people)` calls `contactSource?.contacts() ?? []` once per open,
synchronously on main: at most six rows out of a few KB. An async path would need
a spinner state for a read that has never been measured above a millisecond. The
day it is, that is when it earns one.

### "Instantly call them" — the contract, and what it does before the doorbell exists

`var onCallContact: ((Contact) -> Void)?`, assigned in `Display.open` alongside
`onMic`/`onCam`/`onLeave` (`Display.swift:149`).

1. The row fires **once** per completed click and passes the whole `Contact`.
2. The **view** then closes the sheet and shows the `WaitingCard`
   (`Controls.swift:839`) reading `"Calling Meera…"` in place of the link copy —
   `CONTACTS.md` §6. That is the view's entire job, and it does it whether or not
   a doorbell exists.
3. Everything after is `main.swift`'s: mint the room, fire
   `GET /api/room/<code>/warm` — deployed, worth ~1100 ms, and
   `grep -rn "/warm" mac/Sources/tk` returns nothing (`CONTACTS.md` Error 0) —
   `POST /api/kin/<handle>/ring`, publish to `/rv`, wait.

**With `onCallContact` unassigned — today — tapping a contact must copy the
invite link and say so**: status `"link copied — send it to Meera"`. Not a
disabled row and not a silent stub. That is the true state of the world (you can
reach this person, just not by ringing them yet), it is a *complete* action, and
it means the row is clicked, fired and observable in `describeTree` from day one,
before a line of identity code exists. A greyed row teaches the person the
feature is broken; this teaches them the doorbell is the missing part.

---

## Gesture 3 — long press on the red button

Keep the widened pill and re-purpose it as hold progress. The drawing already
exists and is already correct: `confirming` rounds the rect at 24 and fills
`--bad` (`:425-438`), `drawGlyph` puts the handset and a 13 pt semibold word side
by side with `gap: 8` (`:444-462`), and `layout` collapses the other five buttons
to zero width and gives leave 150×58 (`:1198-1207`) — with a comment explaining
that the collapse exists so the row cannot leave *"a live mute button under the
finger already travelling toward leave."*

New behaviour on the one control:

- `mouseDown` on `leaveButton` → arm (`confirming = true`,
  `confirmLabel = "hold to leave"`, `showBar(pin: true)`) and start the fill.
- fill reaches 600 ms → `onLeave?()`.
- release before 600 ms → fill resets, **pill stays armed** for the remainder of
  its 3 s.
- the fill is a `Timer` at ~1/30 s in `.common` modes, invalidated on release.
  `.common` because it must fire during event tracking (`:1846-1850`), and a
  timer rather than a nested `nextEvent` loop because *a hold must not own the
  main thread* (`:380-392`) — six seconds of holding peek once enqueued 169
  frames into a visible layer and drew a black rectangle.

### I would keep the second tap alive, and argue for it

The user asked to replace two clicks. A hold delivers that. But consider the
person who does not know the gesture: they tap the red button, get a pill reading
"hold to leave", and tap again. Today that hangs up. If the hold *replaces* the
confirm, that second tap does nothing, and the app looks broken at the one moment
it must not.

So the hold is an **addition** — a faster route for whoever learns it — and
`leaveArmed` + tap still leaves, exactly as `:1589-1592` does now. Someone who
holds never sees the fallback, so it costs them nothing; someone who does not is
never stranded. It also keeps `--press leave,leave` and ⌘⌫ working (below).

If that is unacceptable, the label must change to carry the instruction on its
own and the tap-again path must give explicit feedback rather than silence. But I
would ship the additive version.

### One hazard the design has to close: `acceptsFirstMouse` on a hold that hangs up

`IconButton.acceptsFirstMouse` returns `true` (`:405-413`) so the first click on
a background window counts — right for mute, and the comment says *"the whole
point of a hang-up is that it works the first time."* But a hold that *fires*
turns a click-and-hold that only meant to bring the app forward into an ended
call.

**So the leave hold refuses to start when the window was not key at
`mouseDown`.** The first press activates and arms (the pill draws, so nothing
looks dead); the hold is available from the second press on. One line, and it
closes the only path where a hold ends a call the person never looked at.

### Five things in the existing code this would break, and the fix for each

1. **`Menu.swift:90-91` / `:154` — "Leave Call" ⌘⌫** calls `controls.leave()`.
   A menu item cannot be held. Point it at a new `leaveNow()` instead: a menu
   item is an explicitly named, deliberate act and should hang up on the first
   invocation. Leave it on `leave()` and it becomes a control that arms a pill it
   can never complete.
2. **`--press leave,leave`** (`Controls.swift:1728`, and the scar at
   `main.swift:2276-2279` where exactly that sequence reproduced a SIGSEGV) must
   keep leaving. The additive design above preserves it for free. If the second
   tap were removed, every rig invocation would silently stop hanging up —
   `silent-no-op-flags` shaped, and it would take a while to notice.
3. **Escape** (`:1661-1664`) disarms `leaveArmed`. It must also invalidate the
   fill timer, or Escape clears the label while the fill keeps running toward a
   hang-up with nothing on screen.
4. **`scheduleBarHide`** (`:1481`) refuses to hide the bar while `leaveArmed` —
   *"taking the controls away mid-decision is how you get a hang-up nobody
   meant."* The hold must keep that property, or the bar can fade out from under
   a finger at 400 ms.
5. **The 3 s forget timer** (`:1603`) must stay longer than the hold. At 600 ms
   there is 2.4 s of headroom; anyone raising the hold past 3 s builds a gesture
   that can never complete.

---

## §B — the pre-call full-window tap (phase 2)

The literal reading of the request, and the one piece that takes a click away
from something that works (F2). Worth building, worth building second.

A **view**, not the layer: `TapCatcher: NSView` in `CallControls`, bounds-sized
in `layout()`, inserted below `waiting`, and **live only while `startedAt == nil`
and `!waiting.isHidden`** — before anyone has arrived, which is the only time the
window *is* your self view.

- `hitTest` returns **self**. It is the control, not decoration. The `Glass`
  idiom at `:53-58` returns `nil` because a pane of glass has nothing to do with
  a click; copying the wrong half of that lesson gives a target that cannot be
  hit. And because it is the view the hit test lands on, it must answer
  `acceptsFirstMouse` itself — `decoration-inside-a-control-eats-clicks` is
  exactly the trap of putting a target over video.
- **It gives the window drag back.** Track `mouseDown` → `mouseDragged`; if the
  pointer moves more than **3 pt**, call `window?.performDrag(with: event)` and
  fire nothing. Only a press that moved under 3 pt and released inside is a tap
  — the same cancelled-press rule as `SheetRow.mouseDown` (`:627-640`).
- It must not shadow `WaitingCard`'s three controls. `waiting.hitTest`
  (`:918-922`) answers first because `waiting` is above it, so this is structural
  rather than a coordinate check — but it is one `?` assertion, not an assumption.

---

## The dangerous accident: a panel opening when the person meant to peek

Four things keep it from mattering, in the order they act:

1. **One boundary, no dead zone** (above). A press produces exactly one outcome.
2. **The hold reveals at `mouseDown`.** Someone who means to peek sees the tile
   before the classifier has run, so the failure mode *"I released because
   nothing was happening"* is designed out rather than tuned around.
3. **The cost is bounded and the exits already exist.** The sheet opens
   bottom-centre; the far end's face stays visible above it; and it closes on
   Escape (`:1661-1664`), on a click anywhere outside (`:1113`), or on a swipe
   down (`:1114`). Three exits, none needing aim.
4. **The panel must not move the peek button.** `layout` (`:1196-1216`) keeps the
   row where it is, so the second press lands where the first one did.

There is a real consequence of (4) to state plainly: the sheet is drawn **above**
the bar (`addSubview` order, `:1100-1117`) and at 250–450 pt tall it covers the
button row. While the people sheet is open, peek and mute are behind it. That is
already true of today's ⋯ sheet.

---

## Verification: the harness must click

*Every interaction bug in this project has lived between the handler and the
finger* (`handler-tests-cannot-see-interaction-bugs`), and
`Controls.swift:1755-1766` names the last three: six discs with no glyph, a share
button whose `didSet` never sized it so it drew at zero width, and a full-bleed
waiting card whose `hitTest` swallowed the entire bar. Every one passes a handler
test.

### `simulate` tokens (`Controls.swift:1676-1739`) — the weak half

`people`, `people-back`, `handle-copy`, `contact#1` (mirroring the `cam#N` shape
at `:1731-1736`, **including its loud refusal** for an out-of-range index),
`leave-hold`, `leave-hold-cancel`, `peek-tap`.

### `@` clicks (`main.swift:743-753`) — the half that can actually fail

These go through `hitTest` and `window.sendEvent`, which is the path a finger
takes.

| press string | must produce |
|---|---|
| `--press "@peek:0.05,~,?"` | sheet opens on `.people`; `peek=false` — the tile did not stay |
| `--press "@peek:1.0,?"` | `peek=true/held` while held **and `more=closed`** — a hold must never open the panel |
| `--press "@leave:0.2,?,@leave:1.0"` | under-hold does not hang up and leaves the pill armed; over-hold does |
| `--press "people,@row#0,?"` | a real click on an avatar row fires `onCallContact` |
| `--press "people,%People…,?"` | the menu route works — `%` goes through AppKit's own dispatch (`main.swift:736-742`) |

Plus one negative that no other test covers: **`@row#0` with the app not
frontmost must still fire.** `SheetRow` already answers `acceptsFirstMouse`
(`:598`); the test proves the subclass did not break it. `RINGING.md` states the
same requirement for the Answer button, and the whole scar (`:405-413`,
`:590-598`) is *"every glass button was dead while the app was behind."*

### `describeTree` (`Controls.swift:1634-1646`) additions

- `sheet=settings|people` — without it every `row#N` assertion is ambiguous about
  which list it read.
- `people=N` and `handle=<h>|-`.
- extend the existing `leave=` field to `idle|ARMED|HOLDING:<pct>` rather than
  adding a second one. A percentage is the only way a fill can be asserted
  without a screenshot.
- `peektap=<n>` — a **cumulative count**, not a flag. A boolean sampled after the
  fact is a birth certificate, not a health record
  (`once-fired-probes-record-transients`), and only a count can prove one press
  did not classify as both a tap and a hold.

### `?` audit (`auditClicks`, `:1785-1816`)

- **Sheet closed: exactly the pre-existing targets** — `mic cam peek leave more`,
  plus `flip` with two cameras, plus `share copy link` pre-connect (the 8 that
  `LAUNCH.md` measured all-OK). Every verdict `OK`, and **no new name may
  appear**: a target that exists while the sheet is closed is a target sitting
  over the video.
- **`.people` open:** `row#0…row#N` all `OK`, and the `->` column must name
  `ContactRow`. `Glass` there is `decoration-inside-a-control-eats-clicks`;
  `NSTextField` there is the exact bug `SheetRow.hitTest` (`:605-613`) was
  written to fix.

**Predicted, and it is not the new code's fault.** `clickTargets` (`:1769-1782`)
lists `mic/cam/peek/leave` whether or not the sheet covers them, and `Sheet` has
no `hitTest` override, so with any sheet open the audit will report those bar
buttons as `FAIL` — the hit lands on `Sheet` or a `SheetRow`, which is neither
the button nor an ancestor of it (`:1800-1812`). `LAUNCH.md`'s all-OK run had the
sheet closed, so this has probably never been printed. It is the truth about the
screen, not a regression. The fix is in the **instrument**: exclude bar buttons
the open sheet's frame covers. Stated here so the next lane does not chase it as
a product bug.

### Rig override, and the reason it is mandatory

`--contacts-fake devesh,meera,arjun`, registered in `KNOWN_FLAGS`
(`main.swift:142-152`) and echoed at startup. An unregistered flag is refused
loudly (`:155-165`), and three A/Bs here once compared an arm against itself
because a flag did nothing quietly (`silent-no-op-flags`).

Without it, `?` can only ever audit an **empty** list, and the day `contacts.json`
finally lands is the first day the rows are ever clicked. That is
`a-hidden-control-returns-the-same-nothing-as-a-broken-one`: an instrument blind
to the populated state reports the same green as one where it works.

Its limit, stated so it is not overclaimed: the flag proves the **view and the
clicks**. It proves nothing about identity, pairing or ringing. The acceptance
test for the feature is still two Macs on a live prod call (`CONTACTS.md` §8,
`test-on-live-calls-only`).

The same argument covers the other absent conditions: `flip` is hidden with one
camera (`:1376`) and peek refuses to open an empty tile with no camera frames
(`Display.swift:346-351`) — both already have `--video <file>` and `--video off`
to exercise them, and the people page must be reachable on an audio-only call
where there is no self view to tap at all. That is the second reason the ⋯ sheet
and the menu item are not optional extras: they are the only routes that exist
when the gesture's own surface does not.

---

## Build order — what proves the direction with the least code

1. **`ContactRow` + the `.people` page + `--contacts-fake`, opened by the peek
   tap.** One subclass (~40 lines), one enum on `Sheet`, one branch in
   `rebuildSheet`, `onTap` on `IconButton` (~15 lines), one flag. No identity, no
   crypto, no server, no wire, no new hit-testing container — and it puts the
   gesture, the panel, the circles, the empty state and the handle row on screen
   and under `?` in a single build.
2. **The leave hold.** Irreversible, so it is judged on its own, with items 1-5
   of §"five things this would break" closed before anyone holds it on a real
   call.
3. **§B, the pre-call full-window tap** — the literal reading, and the only piece
   that takes a click away from something that works today.
4. The doorbell is a different lane (`CONTACTS.md`, `RINGING.md`).

## Only a person can answer these

Whether a ≤220 ms flash of your own face before the sheet opens reads as feedback
or as noise; whether a 600 ms hold on the red button feels *deliberate* rather
than sticky; whether a dark disc with a coloured ring reads as "a person" at
34 pt or as a status light; whether the additive second tap is an acceptable
answer to *"instead of you having to click twice"*; and whether the ⋯ sheet is
where someone would look for their people, or whether it needs the launch window
after all — the one decision `CONTACTS.md:141-150` says is the user's.
