# The floor: who is heard, and who hears

The rule, decided by the person this app is for:

> **One microphone is live at a time, and that same machine's speaker is not.**

Everything below is how to make that rule invisible. A rule that is noticed is a
walkie-talkie; the whole product is the rule being obeyed and nobody feeling it.

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

2. **Predicted handover** — `Predict.swift` says this turn is ending (it is
   built, tested, and wired to nothing today). At p > threshold *and* in a
   pause, the floor is **pre-released** to `IDLE` before the last word lands.
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
