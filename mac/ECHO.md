# The echo, and what is actually left of it

This project deleted an echo canceller on 2026-08-25 and wrote down why. The
reasoning has to be answered rather than ignored, because most of it was right:

> You hold a copy of what was SENT to the speaker and nothing at all of what the
> room did to it, so the subtraction is always approximate, and the leftover has
> to be attacked by guessing which parts of a person's voice are echo. That
> guessing is the robotic, underwater sound of every video call.

The first sentence is true. The second is a statement about a **different
algorithm**. Everything after "the leftover" describes **spectral suppression** —
deciding band by band that some of a person's voice is probably echo and turning
it down. That is what makes voices sound underwater, it is why Apple's voice
processing was rejected here, and there is none of it in `Aec.swift`.

What 0.107.0 adds is **linear subtraction and nothing else**:

    out[k] = mic[k] - sum_j f[j] * emitted[k - delay - j]

A filtered copy of a signal this program already owns exactly, taken away from the
microphone. It decides nothing about the voice, attenuates nothing, and has no
spectral mask, no gain floor, no comfort noise and no residual suppressor. The
failure mode is *less cancellation*, never a damaged voice — and that is asserted
as an identity rather than hoped for:

    out = mic - mix*y(ref) = near + (echo - mix*y(ref))

`y` is a function of the reference alone, so the near term passes through exactly.
`--aec-test` computes `out - echoProbeOut - near` and requires it to be zero to
floating point (**−157 dB** measured), because a bug could break that linearity —
an update that read the microphone, a mix applied to the wrong buffer — and the
failure would be inaudible in every other number.

## What it achieves

`tk --aec-test`, 20 s of real recorded speech, a simulated room with four
reflections out to 13 ms, 16-sample blocks — the block size the machine actually
delivers:

| | |
|---|---|
| far end alone | **18.8 dB** of echo removed (probe), 25.5 dB instantaneous |
| a conversation, 4 s turns, 300 ms overlap | **10.0 dB** |
| 20 s of unbroken double talk (stress) | 6.8 dB |
| near voice | **exact** — −157 dB of error |
| convergence to 10 dB | 1663 ms |
| cost | **1.6 µs p99** of a 333 µs block — 0.5% |

`--aec-sweep` prints the table the two constants were read off. 1024 taps
(21.3 ms) and a step of 0.10, and the step is the interesting one:

| mu | far-only | conversation | foreground divergences |
|---|---|---|---|
| 0.03 | 13.7 | 7.4 | 1 |
| 0.06 | 16.5 | 10.1 | 0 |
| **0.10** | **18.8** | **10.0** | **0** |
| 0.15 | 20.7 | 7.7 | 2 |

A bigger step removes *more* echo when the far end is alone and *less* during a
conversation, because a fast filter fits whatever is in the microphone — including
a near voice — and then has to be thrown out. The far-only column is the one that
flatters a canceller; the conversation column is the product.

Weight leakage was added to bound the filter and then **the sweep said it was not
what bounded it**: at every tap count and every step size, a 5 s leak scored 1–3 dB
worse with the same zero divergences. It is kept as a switch (`leakTau`) with the
negative result written down, because a negative nobody can re-run is a claim.

## Why the last one measured minus twenty-one decibels

The recorded failure was `erle -21.7 dB` — the canceller making the microphone
twenty-one decibels *louder* — and −21.6 dB with no echo path armed at all, which
is what localised it. Its update was

    let g = mu * e / (xe + 1e-6)

During near-end-only speech `xe` is nearly zero, `1e-6` is not a level, and the
step explodes. NLMS driven by an uncorrelated reference does not converge slowly,
it random walks.

Four things make that death impossible here, and each was measured rather than
argued:

1. **The normaliser has a real floor**, and adaptation requires the reference to
   be above a real level. Dividing by silence *is* the bug.
2. **A divergence guard**: residual louder than the microphone for 100 ms zeroes
   the filter. `--aec-test` runs the old configuration deliberately (freeze
   disabled, mu 1.9, aimed at a call with no echo) and the guard holds it to
   **0.0 dB** instead of −21.7, with the resets counted so the row cannot pass by
   the guard not existing.
3. **The subtraction is scaled by whether it is helping.** `mix` ramps to 1 only
   while the measured ERLE is positive and out in 4 ms when it is not, so a filter
   not earning its place is a no-op on the audio rather than a hazard.
4. **Two filters, and only one touches the audio.** Below.

## The microphone level, which decides how much echo there is at all

A hot microphone hears the loudspeaker better, so this belongs here. Two real
holes were found and closed, and the framing they were found under turned out to be
wrong in a way worth writing down.

**The claim was that the trim was pinned and the mic was running at 2.58× full
scale.** On the call in question (`2p183qa061zcu`, 0.98.0) `a_mic_peak` was indeed
2.582 — but `micPeak` is a **lifetime maximum and is never reset**, so that is the
peak from before the loop converged, and the trim's steady state on that call was
0.62 against a raw peak of 0.89, which is exactly on its −5 dBFS target. There was
no per-beat number anywhere that could tell "hot now" from "hot once", so the claim
could be neither confirmed nor refuted from telemetry. That is
`once-fired-probes-record-transients` and it is the third instance in this project.

Fixed: `a_mic_peak_now`, `a_mic_raw_peak_now` and `a_mic_hot_pct` are per-tick with
a denominator.

**And the two real holes, both in the safety net that cuts an over-full-scale
output:**

1. **It sat below the echo veto's early return.** The veto fires when the
   microphone is mostly this machine's own loudspeaker — and a microphone running
   hot is exactly the one that hears its own loudspeaker, which is the reasoning
   the veto rule is built on. So the fix for a hot microphone was gated on that
   microphone not being hot, and on the ticks where it mattered most the function
   returned before reaching the cut *and drained both level windows on the way
   out*, so the next tick could not see the blast either. A third of that live
   call was in that state.
2. **It required `inputTrim > 1`**, so it only ever rescued an over-unity *makeup*
   gain. A microphone delivering 4.17 raw with the trim at 0.62 puts 2.58 on the
   wire and nothing fired — the same shape the comment above it already describes:
   guards written when a trim was only ever a cut, left covering different ranges
   the moment a gain existed.

The cut runs first now, on every tick, and answers a question that needs no opinion
about where the sound came from: *is more than full scale leaving this machine?* If
it is, a gain this program applied is too large, whoever is talking. Asserted in
`--gate-test`, including the pair that matters — a **vetoed** tick still cuts an
overloaded microphone, and a **healthy** vetoed tick still teaches the makeup path
nothing, because "never learn the room from the loudspeaker" is why the early
return exists and hoisting the cut above it must not have removed it.

`--no-overload-guard` is the control arm.

## Two paths, because "is it safe to adapt" is unanswerable

An adaptive filter has to adapt, and deciding when it is safe means deciding
whether the microphone currently contains a near voice — which at the instant of
decision is exactly the question this product says cannot be answered from the
audio alone. Every single-filter attempt failed on it, in order, and each failure
is in the file:

| attempt | what happened |
|---|---|
| scalar path-gain minimum (mic/ref) | latched at 0.116 against a true 0.6 on turn-gated speech, froze through the far end's entire turn: 48189 of 59881 blocks, **1.3 dB** removed against 21 for far-only |
| the filter's own prediction | cannot arm while the filter is cold, so "adapt freely until it works" adapted through the first overlap and diverged — residual **3.2×** the microphone |
| gating that on the foreground's ERLE | a one-way door: the backstop zeroes the foreground → its prediction is 0 → every microphone is "louder than the echo can explain" → freeze → and the ERLE that armed the freeze is only updated on non-frozen blocks. **1018 adapting blocks in 59881**, frozen at 9.7 dB forever (`held-is-a-one-way-door`) |

So `fBg` adapts and `fFg` is on the audio, and `fFg` is only ever replaced by a
copy of `fBg` **measured** to leave a smaller residual on real audio for 100 ms —
against the current foreground *and* against no filter at all. That second
condition is not redundant: without it the rule is only a ratchet, and once the
foreground is bad a marginally-less-bad background walks itself onto the audio one
3% improvement at a time (measured: the foreground's residual reached **7×** the
microphone).

The question stops being "is it safe to adapt" and becomes "did adapting help",
which is answerable *after* the fact, on the audio that actually arrived, with no
guess about what the microphone contains. The background is allowed to diverge —
it is not connected to anything — and when it does it is restarted from the
foreground rather than from zero.

## Two histories of the same sample

`echoHist` is the **decoded far stream**, before this machine's ear mute, and must
stay that way: the estimator correlates it against the microphone, and keying it
off the speaker's actual output means the detector loses its evidence exactly when
the fix works. That is not hypothetical — the old canceller wrote its *output* into
the capture history, its own success collapsed the correlation to 0.08, and it
re-aimed at whichever noise peak won: **46 re-aims in 90 seconds**.

`emitHist` is what **left the speaker**, which is the only thing that can become an
echo, and it is what the canceller subtracts. They are written on the same line so
`emitW == echoW` always holds — the delay the estimator measures between `capHist`
and `echoHist` is then the same index mapping for both, by construction rather than
by agreement.

For the same reason the duplex gate's `coupling` tracker still learns from the
**raw** microphone peak (`rawPeakIn`). It is the gate's entire model of the room;
learning it from a cleaned signal would teach the gate that the room has no echo,
and the moment the canceller stopped working the gate would have unlearned its own
defence.

## What it buys the classifier — the line that converts cancellation into duplex

`Audio.swift` states the problem: *at the instant of decision, an interruption and
an echo are the same signal.* That is true of the **raw** microphone. It is not
true of a microphone with 19 dB of the loudspeaker taken out of it. One line:

    let effCoupling = coupling * echoResidual
    let expected = effCoupling * far

A person sitting under an echo louder than their own voice was indistinguishable
from that echo. With the echo subtracted they are *above* what is left, and the
same comparison that used to gag them now passes them. And it degrades in the safe
direction by construction: `echoResidual` is **measured**, so a filter that stops
working takes the bar straight back to where it was within about 40 ms. A constant
there would be `stale-constants-after-a-codec-win`.

The correlation veto is withdrawn the same way, and only ever withdrawn — at 10 dB
of measured ERLE, "this microphone is mostly our own loudspeaker" has stopped being
a true description of what leaves this machine.

## And what it does not buy: full duplex on loudspeakers

The honest number, from `--turn-test` on real speech at a coupling of 0.25:

    STRICT                  A silenced for 12862 ms of 19201  (67%)
    + the canceller         10463 ms   — 19% less, from the classifier alone
    + speakers full duplex   9745 ms   — the floor stands down for the 11%
                                         of the call the path is under -26 dB

    echo path LEFT after linear subtraction:  -18.5 dB p50,  -33.4 dB best

**−18.5 dB is not enough to open two microphones in two live rooms.** The bar in
`Floor.Cfg.speakerDuplexPath` is −26 dB and telephony practice says −40 dB before
echo stops being perceptible at all. The missing 15–20 dB is precisely what every
other product buys with spectral suppression — the underwater sound, the rejected
thing.

So `--speaker-duplex` exists, is measured, and **ships off**. It gates on the
remaining path rather than on the canceller's ERLE, and that distinction was itself
a measured correction: the same filter in the same room scored 6.8 dB on one end
and 15.6 on the other because one end simply had less echo to remove, so an
ERLE gate would have refused the quiet end and admitted the loud one. The first
version of the gate read the duplex gate's `coupling` and reported the path at
**−45 dB** in a rig whose room was built at −18, because that tracker compares
against an undelayed reference and under-reads. It is measured inside `Aec` now,
where `xwin` is positioned at the delay and the two signals are aligned.

Where the remaining 20 dB could come from, in order of how much it costs the sound:

1. **A longer filter and a real measured delay on a real desk.** The rig's room ends
   at 13 ms; a real room does not, and this is the direction the rig understates.
2. **A nonlinear speaker model.** Small loudspeakers driven loudly are not linear,
   and no linear filter can cancel what a linear model cannot predict. This is
   probably the single biggest remaining term and it costs nothing in voice
   quality, because it is still subtraction.
3. **Spectral suppression.** Available, standard, and rejected — it is the thing the
   product is against.

Only a real two-room call can move any of this from theory. `--speaker-duplex` on
one such call, with `aec_erle_db`, `aec_residual` and `floor_duplex_pct` in the
beat, answers it.

## Reading it on a live call

Every call prints one line a second when the canceller has run:

    echo: 19 dB removed (call 14 dB), -22 dB of the path left -- aimed 31 ms,
          subtracting 100%, 37 handovers

and the beat carries `aec_erle_db`, `aec_erle_life_db`, `aec_residual`, `aec_mix`,
`aec_off_pct`, `aec_transfers`, `aec_bg_resets`, `aec_diverges` and
`aec_cost_us_p99`. `aec_diverges` should be 0; it is published so that "should be"
is a reading.

Three numbers were also added beside the echo veto, because `a_corr_veto_pct`
reading 6.9% while the correlation was over threshold in 23 of 69 beats was
uninterpretable — "it is catching only the wrong moments" and "the level test was
already right, so there was nothing left to catch" need completely different work
and looked identical:

- `a_veto_armed_pct` — how much of the call the correlation **claimed** the mic
- `a_level_voice_pct` — how much of it the level test called a voice
- `a_corr_veto_pct` — the intersection, the only part where the veto changed a
  verdict

plus `echo_ticks` against `echo_skips`, because a computation that did not happen
has always reported the same as one that found no echo.
