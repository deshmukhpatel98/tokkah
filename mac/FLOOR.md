# The floor: who is heard, and who hears

The rule, decided by the person this app is for:

> **One microphone is live at a time, and that same machine's speaker is not.**

Everything below is how to make that rule invisible. A rule that is noticed is a
walkie-talkie; the whole product is the rule being obeyed and nobody feeling it.

## Strict, which is what ships (0.95.0)

Restated by the user on 2026-08-31, after hearing the soft edges leak on a live
call: *"only one mic is enabled at any given moment in time, and only one
speaker is enabled, and it can't be the same person's."* So the shipping floor
is **strict**: the state machine below is unchanged — who holds, who releases,
who wins a deadlock, the predictor, the ceiling — but its verdict is rendered
harder:

- **Out of turn is silent.** The −20 dB duck is retired. A barge-in still works
  — the claim crosses as a cue and flips the floor — but until it flips, the
  interrupter is not heard. Capture never stops, so the classifier still sees
  them instantly.
- **A pause transmits nothing.** `idle` no longer lets both ends send. The
  first voice takes the floor locally, in its own block, so the first speaker
  still pays nothing.
- **A dead cue channel holds roles.** The old fallback opened both ends; strict
  keeps the holder talking on its own evidence, treats the blind far end as
  quiet, and lets the listener take an empty floor after `releaseMs`. Proven:
  the survivor of a dead peer speaks 9 ms after asking.
- **The holder's speaker is closed on every route,** headphones included. The
  rule is a product statement now, not an echo measure — and with the far
  microphone muted there is nothing real for a talker's speaker to carry.

What strict cannot remove is the speed of light: two people who start inside
one hop of each other both take an empty floor, and the deadlock break then
silences exactly one. Measured in `Floor.strictSelfTest` with the hop modeled:
**0 ms** of double-open in alternation, **one hop** (~40 ms) at a barge-in,
**`deadlockMs` + hops** (~480 ms) at a genuinely simultaneous start — and that
last window is counted on every live call as `strict_overlap_pct`.

`--floor-soft` is the control arm and restores the 0.94.0 behaviour described
below. The soft rules remain documented because they are the fallback arm and
the self-tests keep both honest.

## Interrupting, and the 1150 ms nobody could see (0.99.0)

Strict shipped with a hidden cost that a live call finally exposed: **50 whole
utterances on one 333 s call never reached the wire at all.** Not late —
deleted. Taking the floor from a holder needed 450 ms of sustained `.claim`,
and `.claim` itself needs 700 ms of continuous voice before the classifier will
say it. **1150 ms**, and in strict that wait is silence rather than a duck, so
every interjection shorter than it — "yeah", "no", "wait", every "mm-hm" — was
thrown away.

Two constants fixed it, and they only work as a pair:

- the contest runs on **any voice from its first block** (`nearVoiceMs`), at
  **180 ms** instead of 450. Rig: the floor changes hands after 160 ms.
- the **onset grace window** keeps that voice audible while the contest
  resolves, bounded at 400 ms. A 300 ms interjection loses 0 ms.

The grace window could not have shipped before 0.94.0. Opening a microphone on
"any near voice" over a live loudspeaker means opening it on this machine's own
echo — and the correlation veto is what finally tells those apart. A vetoed
block classifies as `.quiet`, and `.quiet` is the one input the window refuses.

## Seeing who is talking (0.100.0)

Audio.swift states the root problem in writing: *at the instant of decision, an
interruption and an echo are the same signal.* They are the same **acoustic**
signal. A loudspeaker has no mouth.

`Mouth.swift` watches the camera this app already runs — Apple's Vision
framework, no dependency, ~2.9 ms of CPU per look at 12 Hz — and measures the
**rate of change** of lip aperture, normalised by the face's own bounding box.
Not "is the mouth open": a person sitting open-mouthed is not speaking and
mouth shapes differ between faces. What separates speech from a face at rest is
that the aperture keeps changing, 3–8 Hz.

Three states, and the third is load-bearing:

| | meaning |
|---|---|
| `moving` | a face is visible and its mouth is doing what speech does |
| `still` | a face is visible and it is not |
| `unknown` | no face, no camera, no frame, a failed request — **says nothing** |

The aperture is measured on the **lip contour's own two axes** — how open the
mouth is relative to how wide it is — which is dimensionless and identical under
any rotation, scale or distance. That is not decoration: the first version took
vertical extent in bounding-box units, and a clip turned 90° still had its face
found in 100% of frames (Vision needs no orientation hint to *detect* a face)
while the talking verdict silently fell from 100% to 86%, because "vertical"
had become partly mouth *width*. No orientation search can find that bug —
nothing fails, the numbers just get worse — so the measurement stopped
depending on the answer. Rotated verdict is now 96% against 100% upright.

Measured on real talking-head footage: talking rate p50 **0.63** aperture-ratio/s
against the same face held still at p90 **0.08** — **7.9× apart**, and the
invariant measure is a *stronger* signal than the 4.4× it replaced. The
threshold (0.15) is read off that, and it has been wrong twice before being
measured: once as a pure guess (4× too high, called a speaking face silent 100%
of the time) and once because changing the measure changed the units and the old
constant survived (`stale-constants-after-a-codec-win`). `--mouth-test` sweeps
neighbours on every run.

It is allowed to do exactly two things, both of which can only open a
microphone or speed up a handover:

1. **Withdraw the echo veto.** The veto's own stated risk was gagging a real
   voice quieter than the echo it sits under — acoustically unfixable. A
   visible moving mouth overrules the correlation.
2. **Shorten the contest** to `visualDeadlockMs` (80 ms), because two
   independent signals need less of each. Rig: a camera-confirmed voice takes
   the floor in **60 ms**.

It can never mute anybody, and when it is blind everything reverts to 0.99.0
exactly — asserted in `strictSelfTest` as a REJECT row, because
`blind-instruments-report-negatives` would otherwise make every dark room and
every camera-off call slower than it was. `--no-mouth` is the control arm.

**Not yet done:** the signal is local only. Crossing it to the far end — so the
holder's own release can be informed by seeing that somebody else has started
talking — is a protocol change and a separate release.

## What is wrong with the gate we ship today

`Audio.DuplexGate` is purely local and purely reactive. Every block it asks one
question — *is this microphone hearing more than the far end's echo can
explain?* — and it is a good question with a fatal property, which the file
itself states: **at the instant of decision, an interruption and an echo look
identical.** Tuning cannot separate them. Relaxing the threshold to be kind to
interruptions took suppression from 19.3 dB to 1.7.

It is also an *echo* rule wearing a *turn* rule's clothes. Two ends can be open
at once (echo), and neither end ever knows what the other decided.

## The decomposition

The fix is not a better threshold. It is to stop entangling three separate
things that today are one gain multiply:

| | today | after |
|---|---|---|
| **Capture** | gated | **never gated — always running, always into a ring buffer** |
| **Transmit** | = capture | gated by the floor |
| **Playout** | never gated | gated by the floor **and** the output route |

Capture never stopping is what buys everything else. It means a floor decision
can be applied to audio *that was already recorded*, so a handover does not have
to happen before the words it carries.

---

## Question 1 — who is muted, and when

There is exactly one **floor**, in one of three states, and the third is the
important one:

```
IDLE            nobody is speaking. BOTH ends may transmit on first voice,
                instantly, locally, with no round trip.
HELD(me)        I transmit. Far end does not.
HELD(them)      They transmit. I do not.
```

**Most turn transitions never negotiate anything**, because a normal pause drops
the floor to IDLE and the next speaker simply takes it. Negotiation is only for
the interesting case: somebody starting while somebody else is still going.

### The four ways the floor moves

1. **Release** — holder has been silent past a real end-of-turn pause (> 450 ms,
   the existing `quietMs` rule) → `IDLE`. Costs nothing, needs no agreement.

2. **Predicted handover** — `Predict.swift` says this turn is ending. At p >
   threshold, the floor is **pre-released** to `IDLE` before the last word
   lands. Two halves:
   - **Local** (0.92.0): my transcript, my pause, I let go of a floor I hold.
   - **Far** (0.93.0): the same number rides TPKTX+7 beside the vocal byte, so
     the listener's microphone is already open before the speaker finishes.
     A leftover high p at the start of a new turn does not fire.
   The next speaker's first syllable then costs zero, because the decision was
   already made when they opened their mouth. This is the entire reason
   `Predict` exists and is the single largest win available here.

3. **Bid** — the quiet end's local detector reaches `.claim` (sustained voice,
   the existing 700 ms rule) while the other holds. The floor moves to them.
   This is the reactive path and it is the one with a network hop in it — which
   is why it is paired with the retroactive buffer below.

4. **Deadlock** — both bid inside `yieldAfterMs`. Resolved by the existing 9 dB
   duck plus a deterministic tiebreak (lower peer id yields) so it *always*
   terminates. Never by muting both.

### The retroactive buffer — why a hop does not cost a word

The quiet end is still capturing. When it wins the floor, it begins transmitting
**from the buffered onset of its own voice**, not from the moment of the grant.
600 ms of ring is more than a round trip anywhere on earth
(`goal-limits-of-light`), so:

> **No handover, at any distance, may ever cost a syllable.**

The catch-up is spent by playing the buffered audio slightly fast at the far end
(≤ 4 % — inaudible) until it is live again. Nothing is dropped and nothing is
heard twice.

### The invariant that makes this safe

The code's own objection to a negotiated design is written in `Audio.swift`: two
ends seeing each other through 100 ms of network *can deadlock with both muted*.
It is a correct objection and it decides the architecture:

> **The floor is a lease held by a transmitter, never a permission required to
> transmit.** The state on missing information is OPEN, never closed. If the
> floor channel goes quiet for > 1 s, both ends fall back to today's purely
> local gate and keep talking.

Muting is never a fallback, never a default, and never the result of a timeout.
Compare `held-is-a-one-way-door` and `idle-signaling-socket-dies`: every
recovery gate here must survive its own evidence stream disappearing.

---

## Question 2 — whose speaker is on, and when

The holder's playout is attenuated; the quiet end's is full. Three refinements
separate this from a walkie-talkie:

**It is conditioned on the route, not on the floor alone.** Muting the holder's
playout exists to kill the acoustic path. On headphones there is no acoustic
path, so the holder keeps hearing everything and the call is fully duplex in the
ear. Applying a speaker rule to a route that does not need it is exactly
`directional-property-measured-at-wrong-end`. `Audio.outputDevice()` already
detects this and `routeForced` already lets a test drive it.

**It lags the floor by one hop.** When the floor moves away from me, the far
end's audio *already in flight* is their last half-word. Muting my speaker the
instant the floor flips chops it off. Playout mute is therefore delayed by the
measured one-way delay from `TimeSync` — the floor moves now, the ear closes a
hop from now.

**It ramps like the mic does, and for the same reason.** Down on a 4 ms linear
ramp (an exponential cannot deliver a mute — that was the 23.6 → 37.9 dB bug),
up on a ~1 ms exponential, because the direction that restores hearing must never
be the slow one.

### What replaces hearing, while you cannot hear

Nothing about this is safe unless the quiet person is never *lost*. That is
already the shipped answer and the user's own words for it: subtitles and the
green lines, so the person speaking knows the other is there. `Cues.swift`
carries the bloom and the caption band; `Controls.swift` `micFloor` says whose
voice is going out. The floor state is what those draw — so this change gives
them a real state to draw instead of a locally-guessed one.

---

## How it is proven

- The invariant first: a test that kills the floor channel mid-call and asserts
  both ends end up **open**, never both closed.
- Handover cost in milliseconds of lost speech, measured with real recorded
  conversation (`realistic-test-media`), swept over one-way delay out to
  Delhi↔NL. Target: **0 ms lost at every distance.**
- A null A/B first, to know the rig's own noise (`measure-the-rigs-noise-first`).
- Route switching mid-call, forced through `routeForced`.
- Then, and only then, a real two-room call. No rig on this machine can hear
  acoustic echo — both ends share hardware (`same-room-is-a-test-artifact`).
