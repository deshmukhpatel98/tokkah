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

## The clocks are not the same clock (0.109.0)

Capture and render are two devices with two crystals, so the echo arrives at an
offset that **drifts** — tens of ppm is tens of samples over a call — and a filter
aimed at a fixed integer delay converges and then loses its target, over and over.
That was the live signature (27–36 dB peaks collapsing to single digits), and the
rig reproduces it: a planted 30 ppm skew costs the untracked filter **6.6 dB**.

0.109.0 tracks it: the reference window is read at a fractional delay that
advances at the measured drift rate, whole samples carry into the integer delay,
and the filter sees a room that stands still.

    30 ppm:  untracked 12.3 dB  →  tracked 18.6 dB   (no-drift ceiling: 18.8)
    100 ppm: tracked 15.8 dB
    skew estimate: 1.45 samples/s against a planted 1.44
    near voice: still exact (−148 dB), still an identity

Four designs died on the way, each measured, each written in `Aec.swift`:

1. **Residual probes at ±0.25 samples** (steer toward the smaller residual): the
   verdict followed the *drift's* sign at every skew — +30 ppm railed the loop at
   +6 samples/s, −30 ppm railed it at −6 — because carries and refit make the
   window's own motion invisible to residuals. The sensor watched the actuator.
2. **Gating that loop's steering on the fit being good**: a one-way door. The
   overshooting skew degraded the fit, the degraded fit closed the gate, and the
   mechanism that could undo the skew was disabled by the damage the skew caused.
3. **The fitted response's centroid as a position sensor**: reads the fit
   *forming* as −5 samples/s of "drift" during convergence, and saturates at the
   filter's own re-walk rate after it.
4. **A per-read PI on the centroid**: oscillated — the sensor lags the actuator by
   the filter's re-walk time, so every kick was judged before it landed.

What works is a sensor **outside the loop entirely**: the delay estimator's own
readings over time. Its slope *is* the drift, it cannot see the skew (it
correlates raw capture against raw playout), so nothing feeds back and nothing can
oscillate — the failure mode is only "not confident yet", which is 0.108.0. The
regression acts only when the slope clears 1.5× its own standard error, so a
stationary pair of crystals produces a tracker that does nothing, asserted.

And the bug that hid the entire win: **a carry must not shift the taps.** When
`frac` rolls over, `delay+1` and `frac−1` cancel exactly — the window contents are
identical before and after — but the first version shifted the filter anyway
(that rule belongs to a re-aim, where delay moves alone). One whole sample of
misalignment injected per carry, 1.4 times a second: a sawtooth with the same
average misalignment power as the drift being corrected. The smoking gun was the
skew locking at 1.45 against a planted 1.44 while the tracked arm won 0.0 dB —
the tracker was perfect and its carry was undoing it.

The rig's own honesty needed two fixes to see any of this: the drifting echo must
be generated with a **windowed sinc**, because a real clock's echo is the
bandlimited reconstruction a DAC produces, and the linear-interpolation generator
planted a morphing colouration no canceller could fit and no real clock produces
(`fixture-is-not-the-real-shape`); and the window's own interpolation is cubic,
because the tracker sweeps the kernel phase continuously and a linear kernel's
response morphs by decibels across the sweep.

## A filter that is working is not re-aimed, and a wandering estimator is not a clock (0.125.0)

Three live calls on 0.124.0, read out of the beats rather than guessed at:
**21, 17 and 32 re-aims** in about 140 s each, 5–6 divergence resets, `aec_mix` at 0
for 82–97% of the call and an ERLE under 2 dB. Every re-aim zeroes both filters.
The estimator's reading is a 400 ms cross-correlation quantised to 8 samples, and
on an intermittent playout it wanders; three wandering readings in a row and a
converged filter was thrown away for a delay the room had never moved to.

Two changes, both gated on evidence the filter cannot manufacture:

1. **The hold.** A disagreeing estimate is held while the filter on the audio is
   measurably removing echo (`mix` ≥ 0.5 and far-only ERLE ≥ `reaimHoldDb`, 6 dB).
   A filter removing 6 dB at the old delay is stronger evidence about the delay
   than a correlation peak is. Not a one-way door: a room that really moves
   collapses the ERLE inside its 0.5 s window, the hold lapses, the re-aim
   proceeds. Counted as `aec_reaims_held`.
2. **The skew gate.** The drift regression believed slopes of −40 samples/s with a
   standard error of 17 — 830 ppm, which no pair of crystals does — railed the
   skew at −6 and walked a converged filter off its target: **24.5 → 8.1 dB in five
   seconds**, traced. A real 30 ppm fit reads ±0.14–0.33 sps. A fit is believed
   only when its error is under `skewMaxSe` (1.0) and its slope is physically
   possible. Counted as `aec_skew_rejects`.

The rig plants the live shape — readings 10 ms off for 2 s in every 6 — and the
rows fail in both directions:

    unguarded (0.124.0):  −12.5 dB, 7 re-aims
    held:                   0.0 dB, 1 re-aim (the first), 3 holds, skew 0.00, 26 fits rejected
    a room that MOVES 15 ms at 8 s: followed, 2 re-aims, 22.6 dB at the end

Through the real device (`tools/aec-check.sh`, 40 s, three runs each, alternated):
0.124.0 read **19, 21, 14 dB** p50; 0.125.0 read **10, 14, 17**. The ranges overlap
and the deterministic rig is identical on every pre-existing arm, so that rig's
noise is about ±4 dB p50 and it cannot see this change either way
(`measure-the-rigs-noise-first`). The live beats can: `aec_reaims` against
`aec_reaims_held` on a real call is the verdict.

### The loudspeaker model, measured and shipped off

`--aec-nl` adds a Hammerstein model: bounded nonlinear basis signals built from
the reference alone (x|x|, x − tanh(2x)/2, x − tanh(5x)/5), each through its own
short FIR at the same delay, summed into the same subtraction. Still a function of
what this machine played, so the near voice is still exact (−158 dB, asserted). The
first version used x³ and x⁵ and detonated: window energies spanning 18 orders of
magnitude, weights of 27,000, a branch output six times the microphone. Bounded
bases and a 2 s peak-hold normaliser fixed that; the trace is in `Aec.swift`.

    speaker         linear only     with branches      (far-only / conversation, dB)
    clean           18.8 / 10.4     19.5 /  9.1
    drive 3         19.0 / 10.1     19.4 /  9.3
    drive 12        14.0 /  8.5     17.5 /  8.5
    drive 24        10.6 /  5.8     13.5 /  6.6

On a speaker distorting hard it wins 3.5 dB with the far end alone. On a clean
speaker it costs 1.3 dB in the conversation column, which is the product. The rule
for this feature is that nothing may be lost, so it ships **off**; the beat carries
`aec_nl_share_db` when it is on, and a real loud laptop is the only thing that can
overturn the reading.

### Where the remaining decibels actually are

The tail sweep answers the question the 0.107.0 note left open. An 80 ms diffuse
tail costs 1024 taps 5.6 dB — and 4096 taps win back **1.2 dB** of it, while on a
room with no tail at all 2048 taps score 15.1 against 1024's 19.0. The filter is
not short; it is **slow**. Speech is coloured, NLMS converges at the rate of the
least-excited direction, and the far-only leaky ERLE is still climbing (25.5 dB)
when the 20 s recording ends. The next real gain is convergence speed — a
frequency-domain or subband update that normalises per band — not more taps and
not a speaker model. That is a separate release.

## Through the real audio device

`tools/aec-check.sh` runs two real ends of a real call with the echo path in
software, and reads the number the product itself prints. It exists because
`--aec-test` cannot see anything that only happens in the product: the real
CoreAudio callback and its sixteen-sample blocks, the real `emitHist`/`echoHist`
pair, and the real estimator aiming the filter from a real correlation rather than
from a number the rig handed it.

It found a bug the synthetic rig could not, on its first run:

> `emitW` is advanced by the **render thread**, and the capture callback read it
> twice — once for the simulated room and once for the canceller. Between the two
> reads the render thread could advance it, so the echo was injected at one
> alignment and cancelled at another, jittering by up to a render block every
> single block. A canceller cannot converge on a target that moves under it.
>
> **1–2 dB became 16 dB** when the cursor was read once per callback.
>
> `--aec-test` supplies `refW` itself, so it is exact there by construction and
> only the product has two readers. This is what `rig-picks-a-parameter-the-product-does-not`
> looks like when the parameter is a clock.

Two more things it caught, both rigs lying rather than code failing: `--mute` is a
rig flag meaning "do not put this in the room I am sitting in", and folding it into
the emitted history left the simulated room with nothing to reflect and the
canceller with a silent reference — so the rig measured 0 dB and reported the
canceller as never having run. And the echo simulator itself was reading the
*decoded* stream rather than the emitted one, which is a room that keeps reflecting
out of a switched-off speaker.

And a third, in the rig's own ruler: it read the **last** `echo:` line, which is
the leaky ERLE at the instant the process was killed, and the same binary scored
16 dB on one run and 5 dB on the next depending on which syllable the kill landed
on. Three runs of one unchanged build (`measure-the-rigs-noise-first`, done before
believing any of it):

| | peak | p50 |
|---|---|---|
| run 1 | 9 dB | 6 dB |
| run 2 | 36 dB | 9 dB |
| run 3 | 32 dB | 10 dB |

The peak swings by a factor of four and the median barely moves, so the bar is the
median. Current reading on the **shipped** binary, listener end, 22 ms path at
0.55, twice in a row:

    p50 14 dB, peak 27 dB      p50 13 dB, peak 28 dB

The estimator found 20 ms against a path built at 22, which `leadMs` absorbs.

**And the gap is the interesting part, and it is not the filter.** `--aec-test`
gets 19 dB *steadily* on the same room; here the filter reaches 27–36 dB and then
falls back to single digits, over and over. That shape is not a filter failing to
converge — it is a filter converging and then losing its target. The capture and
render streams are two independent device clocks, and the echo arrives at an offset
that drifts between them while the filter is aimed at a fixed integer delay. Tens
of parts per million is tens of samples over twenty seconds, and the render cursor
jitters by up to a block on top of that.

So **the next thing worth doing to this canceller is not more taps or a different
step size — it is tracking that alignment**: a fractional delay, re-estimated
continuously, instead of an integer one assumed to hold. That is where the missing
15 dB between −18 dB and full duplex most plausibly is, and it costs nothing in
voice quality because it is still subtraction.

What this cannot do, said here rather than discovered later: both ends share this
machine's one speaker and one microphone, so the path is simulated and has no
loudspeaker nonlinearity in it — exactly the part a linear filter cannot cancel.
This proves the code path and the arithmetic. Only a two-room call proves the sound.

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
