# Zoom fatigue — an operational definition, and one bug it found

"Erase zoom fatigue" cannot be engineered until it is a number. This document
picks the number, says why that one, and reports what it caught.

## Why turn-taking timing, and not something else

Bailenson's nonverbal-overload theory (*Technology, Mind and Behavior* 2(1),
2021) proposes four causes: close-up gaze at unnatural size, the cognitive load
of producing nonverbal cues for a camera, mirror anxiety from constant
self-view, and reduced mobility. Three of the four are already addressed by
defaults this app ships — self-view is **off by default**, which is Bailenson's
own remedy for mirror anxiety, and the camera is never auto-cropped tighter.

None of those four is measurable from inside the app. Turn-taking timing is, and
it has the harder numbers behind it:

| finding | number | source |
|---|---|---|
| natural inter-turn gap, 10 languages | mean **+208 ms**, mode 0 ms, range +7 ms (Japanese) to +469 ms (Danish) | Stivers et al. 2009, *PNAS* 106(26) |
| same dyads, face-to-face vs Zoom | **135 ms → 487 ms** turn-transition gap | Boland, Fonseca, Mermelstein & Williamson 2022, *J. Exp. Psych: General* 151(6) |
| actual audio delay in that study | only **~30–70 ms** | ibid. |
| delay → social perception | 600/1200 ms added delay made partners be rated less attentive and less conscientious — while **call-quality ratings stayed flat** | Schoenenberg, Raake & Koeppe 2014, *IJHCS* 72(5) |
| one-way mouth-to-ear budget | 0–150 ms transparent, >400 ms unacceptable | ITU-T G.114 |

Two of these change how the system should be tuned:

1. **Boland's gap inflation was 5–10× the raw technical delay.** 30–70 ms of
   delay produced 352 ms of behavioural gap. Their proposed mechanism is
   disrupted entrainment to syllable-rate timing, so what hurts is delay that is
   **unpredictable**, not delay that is large-but-steady. Optimising p50 is not
   enough; the variance and the drift are the target.
2. **Schoenenberg's dissociation.** People blamed the *person*, not the
   connection, and rated call quality unchanged. So "nobody complained about lag"
   is not evidence that lag is doing no harm. It has to be measured.

**Operational definition adopted:** *fatigue risk = how much this app adds to the
natural turn-taking gap, measured as 2 × one-way mouth-to-ear latency, and — the
part that matters — how much that figure moves during a call.*

Mouth-to-ear here is `transit + queue`: `ageP50` is measured at frame arrival and
carries transit only, `depthMs` is audio sitting ahead of the playhead. They add.

**Honest limit:** the ZEF Scale (Fauville et al. 2021, *Computers in Human
Behavior Reports* 4) is the validated fatigue instrument, and no published study
correlates it with measured latency, resolution or frame rate — it has been
tested against usage patterns and self-reported nonverbal mechanisms only. So
this is a *proxy chosen from the delay literature*, not a validated fatigue
score, and the blog must not claim a ZEF improvement.

## What the definition caught: the jitter buffer ratcheted

`pcm.js` grows the audio playout target by one 8 ms frame per concealment, up to
15 frames (120 ms). It used to shrink by one frame per **10 s** of quiet — 0.8
ms/s, while §12's own documented bound allows 2 ms/s. Growth was fast and
per-event; shrink was slow and fixed. That is a ratchet by construction, but
whether it bites in practice is empirical, so `netsim.mjs` gained a mid-call
`setLoss()` and the run goes clean → 3% loss for 30 s → clean again.

Measured on production at RTT 80 ms:

| | before | after |
|---|---|---|
| baseline target, clean network | 2 frames (16 ms) | 2 frames (16 ms) |
| peak under 30 s of 3% loss | 15 frames (120 ms) | 15 frames (120 ms) |
| buffer depth, peak during recovery | **103.8 ms** | recovers monotonically |
| target 110 s after the loss stopped | **5 frames (40 ms)** — never recovered | **2 frames (16 ms)** |
| time to return to baseline | not within the run | **59 s** |
| settled depth vs clean baseline | 47.2 ms vs 14.6 ms | 22.5 ms vs 17.3 ms |

In turn-taking terms: a 30-second bad patch used to leave roughly **178 ms of
extra round-trip gap at its peak, and ~65 ms still there almost two minutes after
the network had healed** — against a natural gap of 135 ms. The call kept feeling
stale long after the network was fine, which is precisely the Schoenenberg
failure mode: nothing looks broken, the other person just seems slow.

### The two fixes

1. **Target decay 10 s → 4 s per frame** (`pcm.js`). This is exactly §12's
   documented 2 ms/s bound, which the code had been undershooting by 4×. The
   bound exists to stop the target oscillating back into the pain that raised it,
   so it was not exceeded.
2. **An asymmetric drift bound** (`pcm-worklet.js`). One ±0.2% clamp was serving
   two jobs with opposite requirements: tracking the sender's clock (permanent,
   must be inaudible — 0.2% is right) and giving back a burst-inflated buffer
   (temporary, one-directional). At 0.2%, returning 90 ms takes 45 s. The
   speed-up side now widens toward 2% as the excess grows past 25 ms, so below
   25 ms of excess the behaviour is byte-for-byte what it was and **only recovery
   changes.**

Recovery is now bounded by the target decay (104 ms ÷ 2 ms/s ≈ 52 s, measured
59 s), not by the drain. Going faster means raising §12's 2 ms/s bound.

**The adversarial case was run.** A faster decay could in principle shrink the
buffer during a lull and then be caught out when loss returns, so the probe also
runs four cycles of 10 s at 3% loss / 15 s clean (`OSC=1`). It behaves correctly:
the target stays elevated for as long as loss keeps recurring and only drains
once it genuinely stops, and concealment over the whole run was **4.61%** — in
line with the 4.4% measured at `pcmpairs=3` under steady shaping, so the faster
decay bought its recovery without paying in dropouts.

## The jitter target now measures instead of guessing (live `c10c0f6d`)

`testbed/fatigue.mjs` reports the proxy as a TRAJECTORY through a mid-call loss
burst — 15 s clean, 30 s at 5%, then clean — because a p50 over a whole call
cannot see the thing Boland's mechanism is about.

The old control law grew the target by one frame per **concealment** and shrank
it by one frame per 4 s. Measured on production: target 2 → 15 frames in about
five seconds and ~55 s to come back (growth ~24 ms/s against decay 2 ms/s, a
**12:1 ratchet**), and the proxy PEAKED TEN SECONDS AFTER the network had healed.

The deeper error was conceptual. A concealment has two causes and buffering only
cures one. A frame that arrived **late** says "you needed this many more ms"; a
frame that was **lost** says nothing about buffer size, because no amount of
waiting produces a packet that is not coming. Both were counted the same, so
much of the latency the law added had no benefit available to it.

**The replacement measures the arrival spread directly.** For each frame that
becomes available, `d = now() - seq*8ms`; the buffer must cover
`secondLargest(d) - min(d)` over a 320-frame (~2.6 s) window. No clock sync is
needed because the offset cancels. Second-largest rather than a percentile
because the guarantee wanted is "no concealment the buffer could have
prevented", which is the window's max; second rather than first so one
pathological arrival cannot pin the buffer for a whole window. Losses contribute no sample and so cannot inflate
it. FEC repairs contribute at their repair time, which is correct — waiting out
an RS span is a real reason to hold audio. It decays for free: a quiet window
simply stops containing the big values.

What the estimator sees, and it is a good check on the whole idea:

| | p90 spread | p99 spread | target |
|---|---:|---:|---:|
| clean | 4.3 ms | 4.3 ms | 2 frames |
| during 5% loss | 4.3 ms | **76–84 ms** | 11–12 frames |

That 76–84 ms is the **RS(10,13) repair span** (10 × 8 ms). The estimator
independently rediscovered our own FEC latency and sized the buffer to exactly
it, while p90 stayed flat — confirming it is the ~5% of frames that are repairs,
not a general slowdown.

Measured against its own control arm (`?pcmjit=0`, identical build, one flag):

| | measured | pain counter |
|---|---:|---:|
| clean baseline | 117 ms | 116 ms |
| peak during 5% loss | 230 ms | 229 ms |
| 45 s after the network healed | **+1 ms** | **+89 ms** |
| time to return within 10% of baseline | **27 s** | **never, within the run** |
| wander (p90−p10) after recovery | **28 ms** | **72 ms** |
| concealment over the run | 1.07% | 1.07% |
| clean-path concealment, n=4 interleaved | 0.05 ± 0.06% | 0.01 ± 0.03% (t = 1.19, ns) |

Same protection during the event and the same peak — both laws correctly want a
big buffer while FEC is repairing — but the new one gives the latency back.
Concealment is identical, so this is not a quality-for-latency trade.

One single run showed 0.2% clean-path concealment against the old law's 0.0% and
was briefly treated as a regression. It is not: at n=4 interleaved the two arms
are indistinguishable and both sit at effectively zero. Recorded because acting
on the n=1 reading is what prompted the second-largest change, and that change
should be justified by its own argument rather than by a result that was noise.

**The trap this time was numeric, and it produced a flattering result.** The
first version stored `d` in a `Float32Array`. `d` is a wall-clock epoch value
around 1.75e12, Float32 carries ~7 decimal digits, and its spacing up there is
~131072 — so every sample rounded to the identical float and the spread came out
as **exactly 0.0**. The estimator was blind, held the target at its floor, and
the run reported "latency perfectly flat under 5% loss," which reads as a
triumph. Exactly 0.0 across 320 samples was the tell. The `jitSpreadMs` /
`jitP90Ms` / `jitP99Ms` / `jitMaxMs` stats now publish the estimator's own input
so that tell is visible from outside instead of needing a code change to find.

## The video half: measured, and it does not ratchet

`competitor.mjs --burst=on,off --burstLoss=N` injects loss for a window inside
the recording and reports glass-to-glass p50 per **10 s window** alongside frames
decoded. Thirds cannot see a burst that starts and ends inside a run, and a
recovery taking tens of seconds is invisible sliced into three.

**Sustained 5% loss, 90 s** — p50 by 10 s window: 66.8, 66.3, 66.3, 61.6, 66.7,
66.5, 62.6, 65.8, 66.2. Thirds 66.4 → 65.8 → 65.2. **Flat.** Nine windows, no
upward trend, over three times the span of the original ratchet observation.

**A 30 s burst inside a 90 s call** — peak **+7 ms** in the burst window (70.2 vs
a 63 ms baseline), back to baseline within one window after it ends. What moves
instead is DELIVERY: frames decoded per window fall 287 → 235 during the burst
and return to 284. Identical with the old audio jitter law (`?pcmjit=0`), so the
audio buffer is not towing video latency here.

So video pays for loss in dropped frames, not in accumulated delay — which is
the right trade for a video lane. A dropped frame is a momentary stutter; delay
that accumulates is permanent, and by Schoenenberg it is the one nobody notices
and everybody blames on the person.

**This is a change from what was previously recorded** (66 → 81 → 97 ms across
30 s at 5% loss). That no longer reproduces. Most likely cause is Lane A's rate
falling 1.5 → 0.92 Mbps over the compression and parity work, which removed the
contention with lane 1; not isolated, so recorded as an observation rather than
a mechanism.

## Two traps in this measurement, both of which produced a confident wrong answer

- **A stale edge asset.** Two consecutive runs reported the *old* decay cadence
  while `curl` showed the new code deployed. The probe now fetches `/pcm.js` with
  `cache: 'reload'` and aborts unless the build fingerprint is present.
- **Teardown samples.** The last rows are collected as the browser contexts close
  and report nonsense (a buffer depth of −1779 ms). One of them became the
  headline verdict before the summary learned to drop implausible rows.

## Not done

- Recovery's remaining 28 s is now the buffer DRAINING, not the target: the
  target is back at 2 frames within ~5 s of the network healing, and the rest is
  the worklet giving depth back at an inaudible rate. Going faster means the
  drift clamp, not the control law.
- The Bailenson face-size remedy has no citable target. No degrees-of-visual-angle
  or life-size figure appears in the peer-reviewed paper; the specific
  centimetre numbers circulating come from press coverage, not psychophysics. So
  the "Life size" default is unchanged pending a real number.
- No competitor comparison of turn-taking gap. Boland's 487 ms is the only
  published Zoom figure and it is not ours to re-measure without a join link.
