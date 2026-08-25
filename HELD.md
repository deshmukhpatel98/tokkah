# Held / paused: an honest state instead of a frozen face

PARITY #1. Today, when the far end stops arriving, the mac app shows a frozen
picture and a call timer that keeps counting. The web app has said the true
thing since 17.120; this is the port.

Anchors below were re-verified against the tree on 2026-08-24. Where a doc
elsewhere disagrees, this file is the newer reading — `PARITY.md` cites
`main.swift:731` for the reconnecting precedent; it is `main.swift:829`.

## The words

Verbatim from the web, because they were written for a person and tested on
one — `tape-app/public/app.js:2741-2784`:

- `paused` → **connection paused — reconnecting**
- `held` → **holding · audio live**

No numbers, no units, no fps ([[consumer-app-not-a-lab]]).

## Two inputs, both dimensionless

Absolute milliseconds are forbidden here. A threshold in ms that contains
propagation is a hidden distance limit, and this codebase has shipped that bug
four times (`rtt-blind-timeouts`).

**audio frac** — endpoint difference of the *cumulative* `audio.ring.concealed`
counter over an 8-beat window, divided by `expected × Δt`:

- `expected` = `SR / Double(FPP)` = 375 pkt/s, already computed at `main.swift:1462`
- enter above `0.25`, exit below `0.05` (`app.js:2670-2671`)
- refuse to judge with fewer than 3 samples (`app.js:2852`)

Endpoint difference, not a moving average: a 30 s average read after a 12 s arm
once *inverted* an A/B result here (`windowed-metrics-smear-experiments`).

**video frozen** — `dv == 0` for ≥3 consecutive beats *while* `vasm.fragsIn` is
still rising. The second clause is the whole point: it separates "they turned
their camera off" (no fragments arriving) from "sending, and I cannot decode
it". `main.swift:1345` already draws exactly this distinction for the keyframe
requester; reuse its shape.

## Precedence

`paused` outranks `held`. If audio is not arriving, never put the word "audio
live" on screen — `app.js:2769-2775`.

## Arming, and the scar that requires it

Hold is armed only once `audio.ring.played > 0` — the far end's audio has
actually arrived — and **the arming transition clears the window**.

Without this, the window contains the silence between two people joining, and
concealment is 100% of wall time by construction. On 2026-08-14, room
`ilx-swig-xox`, Delhi↔NL, both ends displayed "connection paused —
reconnecting" for the first minute-and-a-half of a *healthy* call: Safari 96 s
(entered at frac 0.997), Brave 54 s (frac 0.94). Brave's window had begun 8 s
before its peer's audio could physically exist. The comment lives at
`app.js:2823-2839`; carry it across, don't re-derive it.

Two clears the mac needs that the web did not:

1. **Negative endpoint difference → clear the window.** A restarted peer resets
   its ring counters, so the difference goes negative and the fraction becomes
   garbage (`peer-restart-resets-sequence-numbers`).
2. **`wire.unlockForRediscovery()` → clear.** It already sets its own
   "reconnecting…" status at `main.swift:833`; without the clear, two
   subsystems talk over each other.

## Where the call goes

Not beside `setQuality`. The audio fraction is computed at `main.swift:2053`
next to `concealPct` and stashed — but `dv` does not exist until
`main.swift:2248`, ~190 lines later, *inside* `if vsource != nil || vasm.fragsIn > 0`.

So: compute the fraction at 2053, and call `c.setHold(paused:held:)`
**after the video section (past 2292), unconditionally**, passing a "video
signal unknown" sentinel of `-1` when that branch didn't run. An audio-only
call then still reaches `paused`, and `held` simply never fires — rather than
the whole feature silently not existing on audio-only calls.

Cadence is `reportLoop()`'s existing 1 Hz (`main.swift:1988`). No new thread,
no new timer, nothing sampled on a state change — a metric read once at a
transition is a birth certificate, not a health record
(`once-fired-probes-record-transients`).

## The wash, and why it is a view and not a filter

`paused`: saturate .72, brightness .82, warn tint (`Palette.warn` 0xfbbf24).
`held`: saturate .92, accent tint (0x60a5fa). A 2 px indeterminate hairline at
~1.4–1.6 s.

Implement as `HoldWash: NSView`, a subview of `CallControls`, bounds-sized in
`layout()`, inserted **below** every pill and button (`Controls.swift:1098`,
1126-1157) so the chrome stays full contrast while the picture dims.

- `hitTest -> nil` and `acceptsFirstMouse -> true`, the `Glass` idiom at
  `Controls.swift:57-58`. Non-negotiable: a full-bleed decoration over every
  control is precisely `decoration-inside-a-control-eats-clicks`, which left
  every glass button dead once already.
- Paint in `draw(_:)`, **not** via `layer.backgroundColor`. `Display.snapshot`
  is `cacheDisplay`-based (`Display.swift:259-291`) and cannot see a
  layer-only background — the blindness already recorded at
  `Controls.swift:1078-1085`.

A `CALayer.filters` / `CIColorControls` pass on the video layer is a *second,
optional* path. `Display.swift:236-238` says outright that the window server
composites that layer and in-process capture cannot see it, and four
VideoToolbox properties have already accepted a live change, reported it back,
and done nothing (`readback-is-not-in-effect`). Do not ship it on a readback.

The hold pill inserts into the left stack after `Controls.swift:1254`, then
`py -= holdPill.frame.height + 8`.

**Scope note:** `MetalDisplay.swift` has no `controls`. This feature exists on
the AppKit `Display` path only. Stated here so it is a known limit, not a
later surprise.

## Verification

1. **Null A/B first.** Two clean 60 s live calls with the detector armed and
   logging `frac` per beat. Max observed frac must sit far below 0.25 or the
   threshold is wrong before the feature is even judged
   (`measure-the-rigs-noise-first`).
2. **Rig override** `--hold-win <seconds>` to compress the 8 s window to ~2 s.
   Register it in `KNOWN_FLAGS` (`main.swift:107-115`) and echo it at startup —
   an unregistered flag is refused loudly, and three A/Bs here once compared an
   arm against itself because a flag did nothing quietly (`silent-no-op-flags`).
3. **Click harness** `--press "hold,~,?,unhold" --press-after N`. `describeTree`
   must read `hold=paused` then `hold=-`. The `?` audit must list exactly the
   pre-existing targets, every verdict still `OK`, and must never name
   `HoldWash` in the `->` column. Then real `@mic` / `@leave` clicks *while the
   wash is up*. The harness must click; every interaction bug in this codebase
   has lived between the handler and the finger
   (`handler-tests-cannot-see-interaction-bugs`).
4. **`--shot` while held.** The PNG must show wash, pill and hairline. A shot
   identical to the unheld one means the wash is layer-only.
5. **The actual verdict: a live prod call** with `--imp-drop 12 --imp-burst 400`
   on one end. Words appear within ~4 s of impairment, clear within ~4 s of its
   removal, never on a clean call, never in the first 20 s after joining. Run
   the video half alone too, to see `held` rather than `paused`.

Add `hold` to the `audioBeat` field map (`main.swift:1902-1985`) so the state
is visible in the **final** beat, respecting the `quitting` guard at 1878 — a
dashboard has already trusted a `final` label that had live beats after it
(`final-record-is-not-final`).

## The exit nobody checks

Audio's exit rides concealment, which keeps flowing whether or not the state is
entered — safe. **Video's exit needs decodes to resume, which needs a keyframe
from the peer.** Confirm the requester at `main.swift:1341-1367` is still
firing during a long `held`, or the state has no exit evidence at all and
becomes another `held-is-a-one-way-door`.

## Only a person can answer these

Whether the desaturation reads as *intentional* over a real moving face rather
than as a broken display; whether the hairline reads as "still trying" and not
as a stuck progress bar; whether the chrome really stays full-contrast; whether
"holding · audio live" means anything to someone who did not write it; and
reduced-motion behaviour on a machine that has it switched on.
