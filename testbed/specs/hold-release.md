# How long to hold the peak: a design study

**Scope.** `pcm.js`'s arrival-spread estimator holds the peak of its input and releases it
slowly. Its own comment ends by admitting the open question — *holding the peak at all is
justified, but how long to hold it is not settled.* This brief answers that. Written against
the code as it stands (`tape-app/public/pcm.js`, `tape-app/public/pcm-worklet.js`,
`tape-app/public/app.js`, `testbed/netsim.mjs`, `testbed/relpair.mjs`,
`testbed/onehole.mjs`, `testbed/skewstripe-stage2.mjs`) and against the release-rate arc
already recorded in `MEASURED.md`, which is longer and better-measured than the question
looks.

Line numbers are against the working tree with the uncommitted lane-skew Stage 3 diff
applied (it shifts the estimator down 37 lines and touches nothing in it).

---

## 0. The honest headline up front, and it is not the one the question implies

**The brief that commissioned this — "raise `JIT_RELEASE`" — is answered and shipped.** The
comment block at `pcm.js:2220` still says "SHIPPED RELEASE IS 0.25 ms/tick = 1 ms/s". The
constant twelve lines below it reads `const JIT_RELEASE = cfg.jitterRelease ?? 2` —
**8 ms/s**, shipped 2026-08-03 as Version `36e26723` after `testbed/relsweep.sh` proved the
pro-slow n=8 was a null (the target was pinned at `maxTargetFrames` in that regime, so
`want = min(cap, raw)` discarded the release term and both arms ran the identical control
law). The 68.7 ms / 80 s / ~54 ms figures in that comment are **pre-flip measurements of a
law that no longer ships.** The same comment complains, correctly and at length, that "an
earlier revision of this comment said 8 ms/s and was left in place after the constant
changed" — and then does it again in the other direction. `testbed/onehole.mjs:89` carries
the same rot (`… .get('pcmjitrel')) || 0.25`), so that rig prints a prediction computed from
a release rate the page is not running.

Under the shipped 8 ms/s, the answer to the commissioning question is arithmetic: to return
a 96 ms hold to the floor in ~10 s you need `JIT_RELEASE = (96 − 8) / (4 × 10) = 2.2`
ms/tick. **Shipped is 2, and measured recovery is 12–14 s** (`relpair`, paired, sides
swapped). There is nothing left on that knob.

**What is actually broken is different, larger, and has never been named.** The hold's
memory is *linear* in the event's magnitude, but the estimator's *output* saturates at
112 ms of spread. Everything above 112 ms is memory the control law cannot spend and the
release must still grind away at 8 ms/s. That is why:

| event | measured where | held spread | time the target stays elevated |
|---|---|---|---|
| one 90–100 ms hole | `relpair` | 88 ms | 10 s (both constants agree — §1.3) |
| one 1.3 s host stall | `skewstripe-stage2` contamination | 1329 ms | **165 s** |
| one 3.8 s freeze | `relpair` 250 ms arm, reproduced on demand | 3798 ms | **474 s** |
| `--bw=0.3` opening transient, side B | `startup.mjs` | 9594 ms | **1198 s** (20 min) |

Three of those four are longer than the call. **A hiccup 13× bigger is remembered 16×
longer, and a hiccup 100× bigger is remembered 120× longer — while producing exactly the
same 15-frame target, because the ceiling saturated at the first one.** The rarest, least
predictive events are the ones the estimator remembers longest, which is precisely backwards.

The recommendation is therefore not a new time constant. It is a one-line clamp that makes
the hold's memory bounded by the ceiling it feeds, and a later, flag-gated discriminator for
the residue the clamp cannot reach. Both are argued below against the measured record, and
the first one is **output-identical at the moment of every peak**, by construction rather
than by measurement.

---

## 1. The mechanism, in closed form, because every number below leans on it

### 1.1 What the code actually does

`noteArrival` (`pcm.js:2117`) writes `d = (arrival − skew) − seq × FRAME_MS` into a 320-slot
Float64 ring (`D_WIN`, `pcm.js:2038`) — 2.56 s at 125 fps — and separately keeps an
inter-arrival gap ring, a `gapClump` counter (`gap < 1 ms`, `:2137`) and a raw stall list
(`gap > 3 × FRAME_MS`, capped at 128, `:2145`).

Every 250 ms (`pcm.js:2177`), once `dN ≥ 64`:

```js
const spread = s[Math.max(0, dN - 2)] - s[0];              // :2199  second-largest − min
spreadHold  = Math.max(spread, spreadHold - JIT_RELEASE);  // :2243  JIT_RELEASE = 2 ms/tick
const raw   = Math.max(cfg.targetFrames, Math.ceil(spreadHold / FRAME_MS) + D_MARGIN_FRAMES);
const want  = Math.min(cfg.maxTargetFrames, raw);          // :2247  cap = 15 frames
```

then UP immediately (`eff > target → setTarget(eff)`), DOWN at **one frame per second**
(`:2320`, guarded by `now() - lastDrop > 1000`).

The worklet turns a target into depth at a bounded slew: `maxDrift = driftPpm / 1e6 = 0.2%`
(`pcm-worklet.js:192`, `app.js:1579`), i.e. **±2 ms of buffer per second**, with a wider
one-directional drain only once the excess exceeds 25 ms (`pcm-worklet.js:466–468`).
`relpair` measured the fill directly: 17.5 → 72.3 ms over 30 s = 1.8 ms/s.

### 1.2 The four constants that decide everything

| constant | value | site |
|---|---|---|
| `FRAME_MS` | 8 ms | `pcm.js:56` |
| `D_WIN` | 320 frames = 2.56 s | `pcm.js:2038` |
| `D_MARGIN_FRAMES` | 1 | `pcm.js:2068` |
| `JIT_RELEASE` | 2 ms/tick = **8 ms/s** | `pcm.js:2087` |
| `cfg.targetFrames` | 2 (16 ms) | `app.js:1573` |
| `cfg.maxTargetFrames` | 15 (120 ms) | `app.js:1578` |
| output decay | 1 frame/s = **8 ms/s** | `pcm.js:2320` |
| depth slew | **2 ms/s** (0.2%) | `pcm-worklet.js:192, 469` |

### 1.3 Three rate limits in series, and two of them are exactly equal

Let `H` be the spread the event set. Time for the *input* hold to reach the floor:

    T_hold = (H − 8) / 8   seconds

Peak target `= ceil(H/8) + 1`, and the *output* decays one frame per second, so:

    T_out  = ceil(H/8) + 1 − 2 = ceil(H/8) − 1   seconds

For any `H` below the ceiling these are **the same number**, not approximately: at H = 88,
T_hold = 10 s and T_out = 12 − 2 = 10 s. That is not luck — the peak-hold shipped at
`JIT_RELEASE = 2` precisely because it was "deliberately the same rate as the existing
1 frame/s output decay so no second time constant enters" (`MEASURED.md`, 37df85e2).

**Consequence, and it is the single most useful fact in this brief: below the ceiling, no
single-constant change can shorten the excursion.** Halve the hold's memory and the output
decay still walks the target down at 1 frame/s. Halve the output decay and the hold still
feeds it. They must move together or not at all.

Above the ceiling the symmetry breaks completely. `T_out` saturates at 13 s (15f → 2f) but
`T_hold = (H − 8)/8` keeps growing without bound. **The hold is the only term in this system
with no upper limit, and it is the one whose extra magnitude the output provably cannot
spend.**

### 1.4 The cost of an excursion, and the model checked against every recorded run

Depth cannot follow the target faster than 2 ms/s, so for an excursion of duration `T`
seconds the depth traces a triangle of peak `2T` (until it saturates against the target
height) and area:

    peak added depth   ≈ min(2T, H)          ms
    excursion area     ≈ 2T²                 ms·s      (while 2T ≤ H)

| run | law | H | predicted T | measured T | predicted peak | measured peak |
|---|---|---|---|---|---|---|
| `onehole`, 99.9 ms hole | 1 ms/s | 88 | 80 s | **80 s** | saturates ~54 ms | **54.0 ms** |
| `relpair` isolated, slow | 1 ms/s | ~90 | 80 s | 76 / 62 s | saturates | 52.4 / 49.5 ms |
| `relpair` isolated, fast | 8 ms/s | ~88 | 10 s | 14 / 12 s | 20 ms | **19.7 / 23.8 ms** |
| `skewstripe-stage2` contaminated run | 8 ms/s | 1329 | 165 s | > 60 s (arm ended) | ceiling | ceiling |
| `startup.mjs --bw=0.3` side B | 1 ms/s | 9594 | never | never | ceiling | ceiling |

The model reproduces the recorded numbers on both sides of the release-rate flip and at
both ends of the magnitude range. It is what the options below are evaluated with.

---

## 2. Option 1 — faster or adaptive release

### 2.1 Faster: done, and the remaining headroom is zero

Answered in §0. `JIT_RELEASE = 2` already returns a 96 ms hold in ~11 s and measures 12–14.
To return the *1329 ms* hold in 10 s you would need `JIT_RELEASE = (1329 − 8)/40 = 33`
ms/tick = 132 ms/s — at which rate a genuine 96 ms burst is forgotten in **0.67 s, shorter
than `D_WIN` itself**. At that point `spreadHold ≡ spread` and the feature is
`?pcmjithold=0`, whose A/B is already on the record (`MEASURED.md`, 37df85e2: tail latency
4.8× more consistent *with* the hold, F-test p=0.00049).

**A linear release cannot separate a 100 ms hiccup from a 1.3 s stall, because the only
thing distinguishing them is magnitude, and magnitude is the one thing a linear release
converts directly into time.** That disqualifies the whole family and is why §3 and §4 exist.

### 2.2 Adaptive: "the pain stopped" detector

Accelerate the release after the measured `spread` has sat below the held value for N
consecutive ticks. This is genuinely well-shaped for the problem: on a bursty link the
spread pops up often, the accelerator keeps resetting, and the hold behaves as today; on a
clean link after one hiccup it runs away and drains fast.

Quantified against the model: a release that doubles every 4 ticks (1 s) after the pain
stops takes a 1329 ms hold to the floor in ~7 s, and a 96 ms hold in ~4 s, i.e. recovery
becomes **logarithmic in event size** — the property we want.

**Rejected anyway, on this codebase's own evidence.** It buys nothing that §3's one-line
clamp does not, and it costs two new hand-set constants (the dwell and the multiplier) in a
control law whose file comment says of `D_MARGIN_FRAMES`: *"Not tunable on purpose: the
estimator is supposed to be the answer, and a knob here is how a measured control law
quietly becomes a hand-tuned one again."* Two buffer tunings on this project exploded in
variance when given more authority, and a third (`FEC_LATE`) was built, measured, failed and
reverted. Keep it named as the fallback if §3 + §5 leave a measurable residue on a bursty
link; do not build it first.

**Same verdict, same reasoning, for multiplicative (exponential) release** —
`hold = spread + (hold − spread) × ρ`. Elegant, one constant, log-time recovery. But §3
achieves a *bounded* recovery with **zero** new constants, because the bound is already in
the file: it is `maxTargetFrames`.

---

## 3. Option 4a (recommended, and it is the whole prize) — clamp the hold to what the target can spend

### 3.1 The design

```js
// The target saturates at cfg.maxTargetFrames, so every millisecond of hold above
// (maxTargetFrames − D_MARGIN_FRAMES) × FRAME_MS produces the identical `want` and is
// memory the control law cannot spend. Unclamped, the release still has to grind it away
// at 8 ms/s before the target can begin to fall: a 1329 ms host stall pins the buffer at
// the 120 ms ceiling for 165 s, and a 9594 ms shaped-link opening pins it for 20 minutes.
const HOLD_CEIL = (cfg.maxTargetFrames - D_MARGIN_FRAMES) * FRAME_MS;   // 112 ms today
spreadHold = Math.min(HOLD_CEIL, Math.max(spread, spreadHold - JIT_RELEASE));
```

One line changed at `pcm.js:2243`, one constant added beside `D_MARGIN_FRAMES` at
`pcm.js:2068`. It is derived, not tuned: raise `?pcmjbmax=` and the clamp follows; drop it to
the 2-frame floor and the clamp correctly makes the hold inert.

`raw ≥ 15` requires `ceil(hold/8) ≥ 14`, i.e. `hold > 104`. The tightest output-preserving
cap is therefore anything in `(104, 112]`; **112 is chosen because it is the natural
expression of "one frame below the ceiling" and is one frame conservative.**

### 3.2 Why it cannot cost anything at the peak — by construction, not by measurement

`spreadHold` has exactly two consumers: `raw` (`pcm.js:2246`) and `stats.jitHoldMaxRun`
(`:2244`). For every tick on which the unclamped hold is ≥ 112 ms, both laws compute
`want = 15` and are **bit-identical**. The clamped and unclamped trajectories first differ
only on the tick where the clamped hold has fallen below 104 ms while the unclamped one has
not — i.e. the clamp *cannot* change how the estimator responds to an event; it can only
change when the estimator stops responding to one that is over.

That is a strictly stronger guarantee than de-skew had (whose no-op rested on a measured
~1.1 ms) and the same class of guarantee that made skew-striping safe.

### 3.3 Expected win

| event | T today | T clamped | mean excess depth over a 60 s call, today → clamped |
|---|---|---|---|
| 90–100 ms hole | 10 s | **10 s (no change)** | 3 ms → 3 ms |
| 300 ms burst | 36.5 s | **13 s** | 22 ms → 5 ms |
| 1.3 s host stall at t+10 s | 165 s | **13 s** | **~45 ms → ~6 ms** |
| 3.8 s freeze | 474 s | **13 s** | ~45 ms → ~6 ms |
| `--bw=0.3` opening transient | 1198 s | **13 s** | ~50 ms → ~6 ms |

**~39 ms of mean mouth-to-ear on any call containing one stall above ~1 s**, and it is
capped: after the clamp, an event of *any* size costs at most 13 s of elevation, ≤26 ms of
peak depth and ≤340 ms·s of excursion area. Unbounded becomes bounded, with the bound
written in terms of a constant that already exists.

Two further consequences worth stating because they are not obvious:

1. **The clamp is connected exactly where the release rate is disconnected.** `relsweep.sh`
   proved `JIT_RELEASE` has no authority at 0.3/0.8/1.5 Mbps because the target is pinned at
   the cap. The clamp acts *only* above the cap. The two knobs partition the regime space
   between them, and the half that `JIT_RELEASE` could never reach is the half that produced
   the 165 s and 1198 s numbers.
2. **It repairs the instrument that measures this project's other work.** The
   `skewstripe-stage2` rig had to add a validity gate and an `UNMEASURABLE` exit *because* a
   single 1.3 s host arrival hole inflated one side's buffer for the remainder of a 60 s call
   (`MEASURED.md`, Stage 2 entry; `skewstripe-stage2.mjs:23–29`). Post-clamp that event
   decays in 13 s and the A/B is measurable. Every future 60 s two-arm rig on this laptop
   inherits that.

### 3.4 The diagnostic that must not be lost in implementation

`raw` currently doubles as the control-law input **and** as the honesty instrument:
`stats.jitWantMaxRun` is "the raw run-max … the only way to know the ceiling ever bound", and
`stats.jitClampedTicks` counts the ticks where it did. Clamping `spreadHold` silently caps
`raw` at 15, which would drive `jitClampedTicks` to 0 and `jitWantMaxRun` to 15 forever — a
change that would read as "the ceiling stopped binding" when in fact the ceiling is now the
only thing binding.

**The fix belongs in the same commit:** keep an unclamped shadow (`spreadHoldRaw`, released
at the same rate, never consumed) and compute `jitWantMaxRun` / `jitClampedTicks` /
`jitHoldMaxRun` from it. Three lines. This is the exact defect class the file's own comments
were written to prevent, and it will be introduced by anyone implementing §3.1 literally.

### 3.5 Risk, stated precisely

**A link with recurring bursts larger than 112 ms, spaced 15–40 s apart.** That is the one
condition where the clamped law is at the 2-frame floor when the next burst lands and the
unclamped law is still at the ceiling. Arithmetic for a 300 ms burst every 20 s: a 15f
(120 ms) buffer covers 15 of the burst's 37 frames, a 2f buffer covers 2 — a difference of
**13 frames = 104 ms of concealment per burst**.

The honest counterweight, and it halves the number before it is measured: **depth fills at
2 ms/s, so on a 20 s burst cadence the unclamped law never actually reaches 120 ms of
depth** — it hovers around 40 ms above baseline — so the real difference is closer to 5
frames per burst. It is still real and it is §6's control arm, with a numeric gate, not a
prediction.

**Not a risk:** the response to a burst is unchanged (§3.2). **Not a risk:** a sustained
overload such as `--bw=0.3`, where `spread` itself stays above 104 ms continuously — the
clamp is inert there because the live measurement, not the memory, is what holds the target
up.

---

## 4. Option 3 — percentile sizing instead of a held max

Size to p95 or p99 of the D window rather than holding the max. The window statistics are
already computed every tick and published (`pcm.js:2288–2289`, surfaced at `:2573`), so this
is a two-line change.

**It is a clump-size filter, and its threshold is derivable.** A stall of `g` ms puts
`ceil(g / FRAME_MS)` elevated-D samples into a 320-slot window, so quantile `q` rejects the
clump iff `g/8 < (1 − q) × 320`:

| quantile | rejects holes up to | on the events actually recorded |
|---|---|---|
| p99 | 3 frames = **24 ms** | rejects nothing we have ever measured |
| p95 | 16 frames = **128 ms** | rejects the 90–100 ms hole; **not** the 1.3 s stall (165 samples = 51% of the window) |
| p90 | 32 frames = 256 ms | still fails on 1.3 s |
| p50 | 160 frames = 1280 ms | rejects the 1.3 s stall and the entire concept of a buffer |

**No percentile above the median rejects the event that actually broke a rig**, because a
1.3 s stall is half the window. Meanwhile the cost is structural and already measured: the
file's own comment records that p99 "on a clean path measured 0.2% concealment where the old
law reached 0.0% — trading a headline claim ('lossless by default') for a win that only
applies to lossy paths". p95 is that trade, five times over, by construction: it *defines*
5% of arrivals as acceptable losses.

**Verdict: rejected.** But keep the derivation, because it says something the rest of the
brief needs: the right filter for a stall is expressed in **sample count and arrival
pattern**, and a percentile sets that threshold as a side effect of `D_WIN`'s length — which
is chosen for sender-clock-drift reasons (`pcm.js:2031–2037`) and has no business also
setting the stall threshold.

---

## 5. Option 2 — stall-versus-jitter discrimination, done at the one place it can work

### 5.1 Why the obvious discriminator is wrong

A stall's signature is a hole followed by a clump. `noteArrival` already computes both
halves. The tempting rule — *suppress D samples that arrive with `gap < 1 ms` after a
`gap > 24 ms`* — is wrong on this codebase's own terms, in three separate ways:

1. **Bufferbloat produces exactly that signature and is genuinely predictive.** A competing
   flow fills the access-link queue (`netsim.mjs` models this with `queueMs = 100`), our
   packets queue, then drain as a clump. That is the regime where the buffer prevents
   something, and the file's own comment names it: CLUMPING versus STRETCHING have opposite
   fixes and `gapClumpPct` alone does not separate them.
2. **FEC repairs arrive in clumps by construction.** `swRepairTry` (`pcm.js:1577+`) and the
   RS path (`:1541`) write recovered frames through `ringWrite` → `noteArrival` at *repair*
   time, and `pcm.js:909–912` says that is deliberate: "pretending otherwise would size the
   buffer too small for exactly the frames FEC is there to save." A gap-shape discriminator
   would suppress the FEC path's samples on a lossy link — the one place they matter most.
3. **The burst shield perturbs the input.** `ringWrite` calls `noteArrival` at `pcm.js:913`,
   **before** the duplicate rejection at `pcm.js:1029`. A shield twin rides `DUP_DELAY_F = 3`
   frames (24 ms) behind its original by design and arrives as a *second* datagram, so under
   the shield the arrival rate doubles, gaps halve, and `gapClumpPct` rises for reasons that
   have nothing to do with the network. (The lane-skew brief flagged this same line as a
   one-line fix — skip `noteArrival` when the seq is already in the ring — and it has not
   landed. It should land regardless of this brief.)

### 5.2 The discriminator that does work: our own scheduler

A receiver-side stall blocks the main thread. `noteArrival` timestamps arrivals on that
thread — and so does the estimator's own `setInterval(…, 250)` at `pcm.js:2177`. **The
network cannot make our own timer late.** So:

```js
// inside the 250 ms tick, first thing:
const tn = now();
const tickLate = lastTickT ? (tn - lastTickT) - 250 : 0;   // ms our own thread stole
lastTickT = tn;
```

`now()` is `performance.timeOrigin + performance.now()` (`pcm.js:148`) — monotonic within
the page, which is what this needs.

**Discriminator:** a stall recorded in this tick is self-inflicted iff `tickLate ≥ 0.5 × g`
for the largest gap `g` seen in the tick. `stats.gapMaxRun` (`pcm.js:2153`) is run-scoped, so
this needs one extra tick-scoped `gapMaxTick`, reset at each tick — three lines total, all in
`noteArrival` and the tick head. Resolution is 250 ms, which is coarse but exactly matched to
the target: the stall threshold already in the file is `3 × FRAME_MS = 24 ms`, and any stall
worth suppressing exceeds it by a wide margin.

**The false-positive mode, named and priced.** A host stall that *coincides* with a genuine
network burst inside the same 250 ms tick. Cost: one burst of under-buffering. That cost is
bounded by the buffer's *measured* protective value against stalls, which this project has
already quantified — `relpair`'s recurring arm (6 holes, 10 s apart) concealed 28 frames at
the slow release against 35 at the fast one, i.e. **≈1.2 frames ≈ 9 ms of concealment
prevented per stall**, for 2× the excursion area. The coincidence probability is the host's
stall duty cycle times the burst rate, and both are measurable; `MEASURED.md` already
contains the statistical idiom for exactly this (stalls overlapping rig activity: 3 of 20,
expected 3.1 at 15% duty).

### 5.3 Where the suppression has to be applied, and the half-version trap

**Applying it to `spreadHold` alone is worth approximately nothing, and this is the trap most
likely to be built.** Suppose a self-inflicted 1.3 s stall is barred from setting the hold.
The *live* `spread` is still 1329 ms for the 2.56 s the samples sit in `dRing`, so `want`
still clamps to 15f, the target still snaps to 15f, and the output still walks down at
1 frame/s — 13 s. Post-§3 clamp, that is the same 13 s the clamp already gives. Net gain:
**~0**.

The value is only available at `noteArrival` (`pcm.js:2113–2115`): **do not write
backlog-clump samples into `dRing` at all** when the tick spanning them was itself late.
Then `spread` never rises, `want` never rises, the target never moves, and the excursion is
zero rather than bounded.

- **Prize:** the full sub-ceiling residue — ~20 ms of depth for ~12 s per hiccup, which on a
  host stalling at the measured cross-engine rate of ~4/minute is a **permanent** +20–25 ms
  of mouth-to-ear that never comes back down.
- **Exemptions that must be coded, not assumed:** repair-path writes (thread a flag through
  `ringWrite`'s existing signature — it already carries `zip` and `skewMs`) and duplicate
  writes (fix `pcm.js:913` vs `:1029` first, per §5.1.3).
- **Non-negotiable telemetry:** a `dSuppressed` counter and the tick-lateness distribution.
  A suppressor that silently eats real samples looks exactly like a clean link.

### 5.4 Is a self-inflicted stall really not predictive? — the honest answer

It is *somewhat* predictive: host contention recurs (~4 stalls/minute cross-engine,
simultaneous on both ends, which is how it was identified as host rather than wire). But the
buffer's demonstrated ability to convert that prediction into saved audio is
**1.2 frames per stall, 0.04% of the stream** (§5.2), against a latency cost of 20–25 ms
carried continuously. That is a bad exchange rate at this operating point, and it is the same
exchange rate the fast release already won 8/8 on (`reln8`, paired, p=0.0346 on mean
mouth-to-ear, unanimous sign).

It is also worth being explicit about a thing the hold cannot do at all: **the buffer cannot
grow in time to cover the stall that is happening.** Depth slews at 2 ms/s; the stall is
instantaneous. Every measured arm confirms it — the same 90–100 ms hole concealed 9 frames at
the slow release and 10 at the fast one. **The hold's entire value is predictive, so evidence
that is not predictive is pure cost.**

---

## 6. How the rig proves it

`testbed/holdcap.mjs`, forked from `relpair.mjs` — not from `onehole.mjs`, whose header
already says it is superseded for any comparison and which has no preflight on its own
baseline.

### 6.1 Why relpair's shape is mandatory here

`?pcmjitrel=`, `?pcmjithold=` and the two flags proposed below are **receive-side only**, so
the two arms run as **the two sides of one call**: same host, same instant, same stimulus,
run order and accumulated host state cancelling by construction. This is not a stylistic
preference. Four sequential arms of this exact experiment produced "four result tables and
zero information" — runs 2, 3 and 4 all ended pinned at the 15-frame ceiling, monotone in run
order, which is the shape of host state, not of the variable.

Preflight, inherited verbatim: abort on non-positive depth, depth > 300 ms, < 1000 frames
received, concealment > 0.5%, scheduler p95 ≥ 20 ms, and **on the page disagreeing with the
flag it was asked for**. Host-load gate must WAIT rather than void (`os.loadavg()[0]` is a
one-minute average and contains the previous run's browsers — it voided 7 of 8 runs once).

Media: `testbed/media/real/realA.{mjpeg,wav}` / `realB.*` — real talking-head fixtures, per
the house migration. Verdicts come from DEPLOYED prod at `room.tokkah.com` through
`startP2PSim`, never from a local build.

### 6.2 One emulator addition, and it is the load-bearing one

**Every existing hole rig injects its stimulus by blocking a browser's main thread.** That is
the faithful stimulus for a *host* stall — and it is, by construction, exactly what §5's
discriminator suppresses. A rig that can only produce self-inflicted stalls cannot test the
control that matters.

Add a true network-side stall to `delayProxy` (`netsim.mjs:134`), ~4 lines beside the
existing `hold()` at `:268`:

```js
let stallUntil = 0;
// inside hold(), after `d` is computed and BEFORE the timer is armed:
const dueAt = performance.now() + d;
if (dueAt < stallUntil) d += stallUntil - dueAt;
```

plus `stall(ms)` on the proxy and `stallAll(ms)` on `startP2PSim`'s returned object beside
the existing `flap` (`:452`) and `setLoss` (`:511`). Every packet due during the window is
delivered at its end, in order — one gap of `ms` followed by a clump, which is the exact
arrival signature of the real thing, with **neither browser's main thread involved**.

Critical detail: adjust `d` *before* arming the timer, so `stats.lateMs` (the emulator's own
punctuality, `:281`) stays near zero. Injected stall recorded as emulator lateness would trip
the rig's own validity gate on every run — a harness voiding itself for doing its job.

Second addition, ~3 lines: hold `bps` in a cell so `bwMbps` can be changed mid-call, for the
startup-transient arm (§6.3 arm F). `lossPct` and `delayMs` are already cells for exactly
this reason ("a jitter buffer that grows on pain and shrinks slowly can only be caught by a
run where the pain stops and you watch what happens next").

### 6.3 The arms

Flags: `?pcmholdcap=0` disables the §3 clamp (control); `?pcmholdstall=1` enables the §5
suppressor (opt-in).

| arm | stimulus | tests | the arm exists to catch |
|---|---|---|---|
| **A** null | 1.3 s block, both sides same flags | instrument floor | side-to-side spread; nothing may be quoted inside it |
| **B** big host stall | 1.3 s main-thread block at t+25 s | §3 clamp | the event that made a shipped A/B unmeasurable |
| **C** small host hole | 100 ms block at t+25 s | §3 is a **no-op** below the ceiling | a clamp that changed something it provably cannot |
| **D** network transient | `sim.stallAll(300)` at t+25 s, no block | §5 must **NOT** suppress | a discriminator that eats real network evidence |
| **E** bursty link — **the control that must not regress** | `sim.stallAll(150)` ×6 at 20 s spacing | §3 + §5 vs the hold earning its keep | the one regime where the memory pays |
| **F** startup transient | `bwMbps` 0.3 for 0–15 s, then 3.0 | §3 clamp, shaped | "a bad first few seconds costs the entire call" |
| **G** sustained overload | `--bw=0.3` throughout | §3 inert by construction | a clamp acting where `spread` itself is high |

Profile for A–E: `oneWayMs: 40, jitterMs: 6, jitterModel: 'heavy', lossPct: 0`, seeded —
the same profile as `deskew-divergence.mjs` and `skewstripe-stage2.mjs`, so the numbers are
comparable across all three rigs. Arms E and G additionally at `lossPct: 5`, since that is
where the last two n=8s were run.

### 6.4 The asserts, with numbers

Latency metrics: `mouthToEarMs` (`pcm.js:2583`), `m2eParts.ringDepthMs` (`:2596`), and the
**excursion integral** on both depth and `ageP50 + depth` (relpair proved they agree to 0.1%
on a local path and would not on a WAN — print both or the claim is untestable elsewhere).

Delivery metrics: `concealedMs`, `lostFrames`, and — the sharp one — **`lateFrames`**
(`:2569`, `wl.lateFrames + stats.late`). *Concealment can rise from genuine loss, which no
buffer fixes. `lateFrames` can only rise from the buffer being too shallow for frames that
did arrive.* **That is how "latency saved" is distinguished from "conceal traded", and it is
the assert the whole brief turns on.** Health: `farFuture === 0`, `ringReseeds === 0`.

1. `rewrites > 0` on both sides of every arm — the delay line is genuinely in the path.
2. **Arm A first, always.** Report added-latency, area, recovery-time and conceal spreads.
   Prior floors from `relpair`: 0.0 ms added latency, 0.7% area, 2.0 s recovery, 1 frame
   conceal on a clean link; 4.3 ms m2e and 2 frames at 5% loss. **Refuse any verdict whose
   margin is under 2× the floor measured in this session** — an F-test here once returned
   p=0.0143 on byte-identical arms.
3. **Mechanism, arm B:** `jitHoldMaxRun ≤ 112` in the clamped arm and `≥ 1000` in the
   control. Without this an A/B can pass while the flag does nothing (the `govTrimTicks`
   lesson: "an A/B where this reads 0 in the governed arm compared two identical control
   laws").
4. **Arm B win:** `targetFrames` back to ≤ 3f within **20 s** of the injection in the clamped
   arm; still ≥ 12f at t+60 s in the control. Excursion area **≥ 3× smaller**, expect
   ~340 ms·s vs ~4000+.
5. **Arm B no-harm:** `lateFrames_clamped ≤ lateFrames_control + floor(A)`, and
   `concealedMs_clamped ≤ concealedMs_control + max(floor(A), 100 ms)`.
6. **Arm C invariant:** `|area_clamped − area_control| ≤ floor(A)` and
   `|peakDepth difference| ≤ 2 ms`. §3.2 says this is true by construction; the assert exists
   because a literal implementation that clamps in the wrong place would break it and nothing
   else would notice.
7. **Arm D false-negative guard:** with `?pcmholdstall=1`, `jitHoldMaxRun ≥ 104` and
   `dSuppressed === 0`. A network stall must move the estimator exactly as it does today.
   **This is the assert that would have caught a gap-shape discriminator (§5.1) and it must be
   written before the discriminator is.**
8. **Arm E, the control that must not regress:** `lateFrames_treatment ≤
   lateFrames_control + max(floor(A), 6 frames)` — one frame per burst — and
   `concealedMs_treatment ≤ concealedMs_control + max(floor(A), 250 ms)`, from §3.5's
   fill-limited estimate of ~5 frames/burst. **If arm E fails, §3 ships and §5 does not**;
   they are separable and their gates are separate.
9. **Arm F:** control still ≥ 12f at t+60 s (the "bad first seconds cost the whole call"
   signature); clamped arm back to ≤ 3f within 20 s of the bandwidth restoring.
10. **Arm G inertness:** `jitClampedTicks > 0.9 × ticks` in both arms and depth difference
    inside floor(A) — the clamp must not act where the live spread is what holds the target up.
    This assert doubles as the check on §3.4: a naive implementation drives `jitClampedTicks`
    to 0 in the clamped arm and fails here, which is the cheapest possible way to find out
    that the honesty instruments were clamped along with the control law.
11. **Bytes:** `bytesSent` within 1% across arms. Nothing here should touch the wire, and a
    cheap assert catches a well-meaning "while we're in here".

### 6.5 Validity gating — and the one gate that cannot be inherited

`skewstripe-stage2.mjs:176–204` gates on `jitSpreadMaxRun > 300 ms`, sim `lateness().max
> 50`, `loopLag().max > 50`, retries twice, then reports **UNMEASURABLE (exit 2)**. Keep the
sim gates and the exit code verbatim.

**The `jitSpreadMaxRun > 300` gate is un-inheritable here**: this rig's stimulus is a 1329 ms
spread on purpose, so the existing gate would void every valid run. Replace it with
**injection attribution**: `stats.stalls` carries `{t, g}` in wall clock
(`pcm.js:2145, 2549`), and the rig knows its own injection windows. Assert that every stall
with `g > 50 ms` falls inside an injection window ±500 ms, and **void the run on any
unattributed stall**. That is strictly stronger than a magnitude threshold — it distinguishes
"the host stalled" from "we stalled the host" instead of conflating them — and the
null-model idiom for it is already in the house (`report.activity`, stall-overlap against
duty cycle).

Also print, per arm: the new `tickLateMs` distribution, `jitSpreadMaxAtMs` /
`jitSpreadMaxLate` (so a startup transient is separable from the injected event), and
`jitClampedTicks`. A run whose control arm suffered an unplanned host stall is not a control.

---

## 7. Interaction with everything already shipped

**Sliding-window FEC repair.** Repairs call `noteArrival` at repair time by design
(`pcm.js:909–912`). §3 does not touch this. §5 must exempt the repair path explicitly
(§5.3), and arm E at `lossPct: 5` is where a mistake there shows up as concealment.

**Burst-shield twins.** `noteArrival` at `pcm.js:913` runs *before* the dup rejection at
`:1029`, so a twin sent `DUP_DELAY_F = 3` frames late injects an inflated `d` into the
window. Independently flagged by the lane-skew brief; unfixed. **It should be fixed before
§5**, because a discriminator reading gap statistics that the shield is doubling is reading a
perturbed input.

**Latency governor (`?pcmgov=1`).** Its ship gates were not met, explicitly because "the
estimator's fast release (`jitterRelease=2`, shipped) already drains what this law was built
to drain" (`app.js:1650`). §3 drains more, so the governor's remaining headroom shrinks
further. It is also structurally incapable of solving this problem: its floor is a true
rolling minimum over 20 s and any pain zeroes the tick, so **in a recurring-stall regime the
governor stands down entirely by design** — the exact regime §5 targets. Recommendation: leave
it opt-in, and re-run its gates after §3 rather than before.

**Per-lane skew work (Stages 1–3).** Skew-striping removes the *structural* component from
`spread`, so what remains is jitter plus stalls — a cleaner input for §5. In the other
direction, a lane flip is a step change in arrival delay and reads as a transient: the
skew-stripe brief priced a wrong promotion at "~24 ms of extra depth for ~3 s", computed from
`JIT_RELEASE = 2`, which §3 leaves unchanged below the ceiling. The uncommitted Stage 3
RTT-probe promotion (`pcm.js:600–625`) makes promotions more frequent, so that price is now
paid more often — another small argument for §3, since a flap that overshoots the ceiling is
today remembered for minutes.

**`maxTargetFrames` as a dial.** `MEASURED.md` records "the 120 ms ceiling is a dial, not a
defect". §3 derives its clamp from that dial, so the two stay consistent automatically —
including per-side, which `relpair`'s `--jbmaxA/--jbmaxB` needs.

**`?pcmjithold=0`.** Unchanged and still the control arm for the hold's existence. §3 is a
clamp on a feature, not a replacement for it.

---

## 8. Recommendation and staging

**Build §3 (ceiling-clamped hold). Instrument §5 before building it. Do not build §2 or §4.**

**Stage 0 — hygiene, no behaviour change, ships immediately.** Correct the comment block at
`pcm.js:2220–2242` to describe the shipped 8 ms/s and to relabel the 68.7 ms / 80 s / ~54 ms
figures as pre-flip. Fix `testbed/onehole.mjs:89`'s `|| 0.25` fallback. Fix the twin →
`noteArrival` ordering (`pcm.js:913` vs `:1029`). Add `tickLateMs` to the snapshot,
measured and published but **not consumed** — the same discipline `JIT_WARM` is held to.
Zero risk, and it is the input Stage 2 needs.

**Stage 1 — the clamp, `?pcmholdcap=0` as control, default ON.** Per the project's
default-on convention, and defensible here in a way lane-skew Stage 2 was not: §3.2 makes it
output-identical at every peak by construction. Ships with the §3.4 shadow-stat fix in the
same commit. Rig gate: **asserts 1–6 and 9–11 green, arm A floor established first.** Advance
on all three of: arm B area ≥3× smaller, arm C invariant inside the floor, arm E
`lateFrames` inside its bound.

**Stage 2 — measure the prevalence of what is left.** With Stage 1 shipped, the residual is
bounded at ~26 ms for ~13 s per event. Publish, per call: the count of hold-setting ticks
where `tickLate ≥ 24 ms` (would-be self-inflicted), and the count where it did not. Add both
to the end beat beside `jitSpreadMaxRun`, `jitAboveFloorMs` and `laneSkewMaxMs`.
**Decision rule, stated now so it is not negotiated later: if fewer than 25% of real calls'
peak-setting events coincide with our own scheduler lateness, §5 is a null and we stop.**
Below that the discriminator would be firing rarely, on a bounded 26 ms residue, against a
measured 1.2-frames-per-stall protective value — not worth the risk to the FEC path.

**Stage 3 — the suppressor, `?pcmholdstall=1`, opt-in and staying opt-in.** Suppression at
`noteArrival` only (§5.3), with the repair-path and duplicate exemptions coded, and
`dSuppressed` published. Rig gate: **asserts 7 and 8 are the ones that matter** — arm D
proves it does not eat network evidence, arm E proves it does not trade conceal. Deliberately
against the default-ON law, exactly as skew-striping Stage 2 was: this is a change to *what
the estimator is allowed to see*, and that class of change has been measured harmful on this
project once already.

**Stage 4 — the live gate, and it is the one this machine cannot provide.** A real call on a
path with real cross-traffic. The local emulator's "bursty link" is a seeded heavy tail
through two userspace hops at 40 ms one-way; it is not an access link with a neighbour's
video call on it. This is the same missing dependency the lane-skew brief named (§6.3(b),
a `us-east-1` cloud vantage) and it gates Stage 3's flip, not Stage 1's.

### What cannot be verified from a single machine

1. **Stage 2's prevalence question.** "Are real peak-setting events self-inflicted or on the
   wire?" is a fleet question. The instrument is a two-line addition; the *answer* needs real
   calls, and this repo's real-call corpus is two human calls.
2. **The bursty-link control at a realistic operating point (arm E).** Seeded heavy-tailed
   jitter on loopback is a model of queueing, not queueing. A negative arm E on the emulator
   is a stop; a positive one is not a licence.
3. **Mobile.** WebKit does its media work in separate processes and a booted iOS simulator
   alone costs ~1.3 s host stalls in this project's concealment rigs. A scheduler-lateness
   discriminator behaves differently there and the *phone* arm remains this repo's known
   missing input.
4. **Both-ends clock honesty for any m2e claim.** `mouthToEarMs` rests on the ping offset's
   symmetric-path assumption; report both ends' `clockOffsetMs` and check they sum to ~0
   before quoting the number, per the geo brief.

### What would make me abandon this

**Stage 1:** arm C failing — a clamp changing something §3.2 proves it cannot means the
implementation clamped in the wrong place, and the fix is the implementation, not the design.
Arm E failing at 5% loss, i.e. the unclamped memory genuinely preventing concealment on a
bursty link, would narrow §3 to "clamp at 2× the ceiling" rather than at it — the same
answer, one frame weaker.

**Stage 3:** Stage 2 measuring under 25% self-inflicted (a null, stop). Or arm D showing any
suppression of a network stall — that is not a tuning failure, it is the discriminator being
wrong about what it detects, and the honest fallback is to keep §3's bound and accept the
26 ms.

**The whole brief:** if fleet data shows real calls rarely exceed 112 ms of spread at all,
then §3 never fires in the wild and this is engineering for the rig. That is a real
possibility and it is worth stating: **the strongest evidence in this document is a rig
contamination and two shaped-link transients, not a user complaint.** Stage 2's telemetry
answers it either way, which is why Stage 0 ships first and separately.

---

## 9. Sources

### Measurements
- `MEASURED.md` §"SHIPPED: peak-hold on the jitter estimator's input" (37df85e2) — the
  variance result, F=23.17 p=0.00049 on p95 latency; release chosen to match the 1 frame/s
  output decay
- `MEASURED.md` §"SHIPPED: release rate 8 ms/s → 1 ms/s" (42119460) and §"What one hiccup
  costs, measured" — the 68.7 ms / 80 s / ~54 ms figures, **on the 1 ms/s law**
- `MEASURED.md` §"The noise floor, measured" / §"The result, paired and swapped" — 0.0 ms
  added-latency floor, 0.7% area floor, 2.0 s recovery floor; fast 19.7/23.8 ms vs slow
  52.4/49.5 ms; recurring arm 28 vs 35 concealed
- `MEASURED.md` §"The n=8 the release rate deserved, at 5% sustained loss" — paired t,
  −8.11 ms mean m2e, p=0.0346, 8/8 sign; conceal claim withdrawn at that n
- `MEASURED.md` §"The contradiction was a disconnected knob" (2026-08-03) — `relsweep.sh`,
  the release rate inert at 0.3/0.8/1.5 Mbps, **`JIT_RELEASE` 0.25 → 2 shipped**, Version
  36e26723; ~9 ms mean-depth noise floor in a shaped regime
- `MEASURED.md` §"The estimator does NOT learn its buffer size from the handshake" —
  `startup.mjs`, side B's 9594.6 ms spread at `--bw=0.3`, 419/490 clamped ticks
- `MEASURED.md` §"Lane-skew Stage 2" — the 1.3 s host stall (`jitSpreadMaxRun` 1329 against
  a normal ~50), the validity gate and `UNMEASURABLE` exit it forced
- `MEASURED.md` §"Why one hole costs a minute of latency" and §"A 1000x units error in the
  report itself" — the `holdSecs()` identity

### Repo sources read
- `/Users/deveshpatel/Downloads/video calling/tape-app/public/pcm.js` — `FRAME_MS` (56),
  `RING_F` (146), `now()` (148), `ringWrite` (901) and its `noteArrival` call (913), the
  late/far-future/dup gates (1027–1029), RS repair (1541) and sliding-window repair (1577+),
  the estimator block: `D_WIN` (2038), `JIT_WARM` (2064), `D_MARGIN_FRAMES` (2068),
  `JIT_HOLD` (2069), `JIT_RELEASE` (2087), governor (2089–2114), `noteArrival` (2117) with
  gap/clump/stall statistics (2137–2148), `bumpTarget` (2157), the 250 ms tick (2177–2321),
  `spread` (2199), the peak-hold comment (2205–2242) and its one line (2243), `raw`/`want`
  (2246–2247), output decay (2320); snapshot fields (2527–2596); lane-skew Stage 3 promotion
  probe (577–660, uncommitted)
- `/Users/deveshpatel/Downloads/video calling/tape-app/public/pcm-worklet.js` — `maxDrift`
  (192), late gate (312), drift control and the asymmetric drain (446–469), overflow skip
  (474)
- `/Users/deveshpatel/Downloads/video calling/tape-app/public/app.js` — `targetFrames` (1573),
  `maxTargetFrames` (1578), `driftPpm` (1579), `jitterHold` (1637), `jitterRelease` (1641)
  and the governor's stated non-gate (1642–1653)
- `/Users/deveshpatel/Downloads/video calling/testbed/netsim.mjs` — `delayProxy` (134), the
  loop-lag probe and why it exists (225–247), `lateness()` sampling (249–291), `startP2PSim`
  (400), `flap` (452), `lateness`/`loopLag` (494–502), `setLoss` (511)
- `/Users/deveshpatel/Downloads/video calling/testbed/relpair.mjs` — the paired design, the
  null arm, `UNDER_TEST`, LEVER AUTHORITY, preflight
- `/Users/deveshpatel/Downloads/video calling/testbed/onehole.mjs` — the superseded-header
  discipline, the stimulus-confirmation void, the stale `|| 0.25` at line 89
- `/Users/deveshpatel/Downloads/video calling/testbed/skewstripe-stage2.mjs` — validity
  gating (176–204), delta-vs-cumulative leakage (206–241), `UNMEASURABLE` exit 2
- `/Users/deveshpatel/Downloads/video calling/testbed/skewstripe-stall.mjs` — the
  blackhole-by-flap idiom (uncommitted)
- `/Users/deveshpatel/Downloads/video calling/testbed/specs/lane-skew-action.md` — §2.5's
  `noteArrival`-on-duplicate finding, the staging shape this brief follows
