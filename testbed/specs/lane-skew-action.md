# Acting on lane skew: a design study

**Scope.** The receiver now knows per-lane transport skew exactly. This brief asks the only
question left: *what do we do with it?* Written against the code as it stands
(`tape-app/public/pcm.js`, `core/pcmsw.js`, `tape-app/public/app.js`,
`testbed/netsim.mjs`, `testbed/deskew-divergence.mjs`) and against the divergence rig's
2026-08-13 verdict, which is the reason this document exists.

**The honest headline up front.** De-skewing the estimator failed for a reason that
generalises: *a receiver cannot make a slow lane fast.* The only two places the 16–32 ms
can actually be reclaimed are (a) the sender's choice of which lane a frame rides, and
(b) recovering the slow lane's frames from parity that arrives on a fast lane. This brief
argues that (b) is (a) with 33–100% more bytes, that (a) is a ~40-line change to four
functions that are already written in the right shape, and that (a) is *bit-identical*
when lanes don't diverge — not by measurement but by construction, because when nothing is
demoted the new expression reduces literally to the old one.

---

## 0. What we already know, and what it cost to learn

From `MEASURED.md` §"De-skew divergence verdict" (deskew-divergence rig, DEPLOYED prod
through local delay lines, 24/12/24 ms lane offsets, 6 ms one-sided heavy tail, 60 s arms):

| Quantity | de-skew ON | control (OFF) | zero-divergence control |
|---|---|---|---|
| `laneSkew.perLane` (divergent lanes) | 25.5 / 11.6 / 25.3 | (measured, not applied) | ~1 ms |
| `ringDepthMs` | 31.1 | 58.7 | — |
| `mouthToEarMs` | 118.4 | 141.1 | — |
| `concealedMs` / 60 s | 4064 | 3072 | 232–344 |

Four facts to carry forward, each load-bearing later:

1. **Detection is exact.** 25.5/11.6/25.3 against 24/12/24 injected — a ≤1.5 ms error on a
   decaying-minimum estimator (`pcm.js:1618–1653`). Whatever we build on top of this
   number, the number itself is not the risk.
2. **The buffer win is real and is exactly the structural offset.** 58.7 → 31.1 ms of ring
   is 27.6 ms, against 24 ms of injected skew plus one frame of `D_MARGIN_FRAMES`
   quantisation. The estimator is behaving exactly as `pcm.js:1970` says it will.
3. **The concealment cost is the arithmetic identity of the win.** Three of six lanes were
   structurally 12–24 ms late; a ring sized to the fast three cannot hold their frames.
   +992 ms/60 s (repeat seed: +472) is what "half the stream arrives after the playhead"
   sounds like.
4. **Divergence costs conceal in BOTH arms.** 3072 ms in the un-corrected arm against
   232–344 ms in the zero-divergence control — a 10× penalty that de-skew never touched
   and that no receiver-side change can touch. Whatever we build has to fix *this* number,
   not just the depth.

**The mechanism, stated once so the rest of the brief can lean on it.** The ring has one
playhead. A frame is playable iff it arrives before that playhead passes its slot. The
playhead's position is set by the deepest structural delay in the *set of lanes that
carry data*. Therefore the only two moves that exist are: **shrink that set** (§2) or
**manufacture the slow lanes' frames from data that arrived on the fast ones** (§3). The
receiver-only move — pretend the slow frames arrived earlier — was tried and is the thing
that failed.

---

## 1. What the code gives us for free

Before evaluating designs, the four properties of this codebase that decide which design
is cheap:

**1.1 Lane identity is symmetric and stable.** `attachChannel(channel, idx)`
(`pcm.js:2142`) is called with idx 0 for the main pc's `pcm-audio` channel and idx 1..N−1
for `pcm-audio-${idx}` on the stripe pcs (`app.js:2174`, `app.js:2178`). Both ends attach
the same label at the same index, and both ends' `assocs[k]` is therefore the *same SCTP
association*. **A feedback message that names lane 4 is unambiguous at the far end.** This
is the single fact that makes sender-side action cheap; without it every design in this
brief needs a lane-naming handshake.

**1.2 There is already a receiver→sender advisory channel, with a precedent for
extending it.** `sendLossReport()` (`pcm.js:1414`) fires every 250 ms off `lossTimer`
(`pcm.js:2154`), 3 bytes, on every open association, and its own comment (`pcm.js:1383`)
records that it was extended in place once already and that the extension was "safe
against a peer that predates it, because the byte is advisory". Unknown types fall off the
end of `onMessage` (`pcm.js:102`). A skew report is the same shape of thing: advisory,
small, periodic, and harmless when lost or ignored.

> **Trap, named because it has already cost this project a whole deploy.** `onMessage` has
> a blanket `if (data.byteLength < 9) return;` at `pcm.js:1518`. T_LOSS is handled *above*
> it precisely because that guard "silently ate every loss report on the first deployed
> build". A skew report at `2 + PAIRS` = 8 bytes lands on exactly the same rake. Its branch
> goes above line 1518, beside T_LOSS, or it does not work and looks like it does.

**1.3 The pickers are already written as "prefer home, fall forward through everything
else".** `pickDataAssoc` (`pcm.js:964`), `pickTwinAssoc` (`982`), `pickParityAssoc` (`992`)
and the inline picker in `sendSwParity` (`1047`) all compute `home` and then walk
`(home + k) % PAIRS` for k in 0..PAIRS−1. **Changing which lane is "home" is a change to
one expression per picker; the fall-forward escape hatch — the thing that keeps audio
flowing when a lane stalls — is untouched.** That is the whole reason §2 is cheap and §3
is not.

**1.4 The gate already budgets for concentration.** `backlogLimit` (`pcm.js:286`) budgets
each association against the **full** design rate `OFFER_BPS` = 125 pps × 1168 B × 1.3 ≈
190 KB/s ≈ 1.52 Mbps, deliberately *not* divided by N, with the comment: "an association
absorbing spilled frames from a congested sibling needs headroom for exactly that". At
pairs=6 a lane carries ~0.25 Mbps of a ~1.5 Mbps stream. Concentrating onto 3 lanes makes
it ~0.5 Mbps — **a third of what the gate already permits.** Concentration does not trip
the gate. (It does reduce aggregate SCTP cwnd; see §2.5.)

**1.5 Reordering is already free.** The transport is `ordered: false, maxRetransmits: 0`
(`app.js:2133`, `app.js:2174`); the loss detector lags 64 frames = 512 ms specifically so
"reordering across the PAIRS associations is not counted as loss" (`pcm.js:1188`). A frame
changing lanes mid-stream is, to every consumer, indistinguishable from the reordering the
stripe already produces.

---

## 2. Option 1 — Skew-aware striping (sender demotes slow lanes)

### 2.1 The design

Receiver already computes `perLane` skew every frame (`pcm.js:1618–1653`) and republishes
it in the snapshot (`pcm.js:2324`). Add:

- **Wire.** `T_SKEW = 0x09` (0x09 is free: 0x01–0x08, 0x50/0x51, 0x60/0x61 are taken —
  `pcm.js:63–135`). Layout `u8 type | u8 laneCount | u8 skewQ[laneCount]`, `skewQ =
  min(255, round(skew_ms × 2))` — 0.5 ms resolution, saturating at 127.5 ms, which is past
  any skew that leaves us with a call. 8 bytes at pairs=6, emitted on the existing 250 ms
  `lossTimer` beside `sendLossReport`. **32–192 B/s against ~190 KB/s of media: 0.1%.**
- **Sender state**, next to `assocs` (`pcm.js:498`): `peerSkewMs = new Float64Array(PAIRS)`,
  `fastOrder = Int8Array` (a permutation), `nFast`, `laneStateSince = Float64Array(PAIRS)`.
- **Policy.** Demote lane k when its reported skew ≥ `SKEW_DEMOTE_MS = 8` (one frame — below
  a frame the estimator's `ceil(spread/8)` quantisation cannot spend the win anyway).
  Re-promote at ≤ `SKEW_PROMOTE_MS = 4`. Dwell ≥ 5 s in a state before flipping. Never
  demote below `MIN_FAST = 3`; when more than PAIRS−3 lanes exceed the threshold, demote
  the *worst* PAIRS−3 by rank.
- **Routing.** `pickDataAssoc(seq)`: `home = fastOrder[seq % nFast]`, then the identical
  `(…+k) % PAIRS` fall-forward across **all** lanes, demoted ones included.
  `pickTwinAssoc`: `home = fastOrder[(seq + max(1, nFast>>1)) % nFast]`.
  `pickParityAssoc` / `sendSwParity`: same substitution on the parity ordinal. Parity is
  latency-critical (its deadline is the playhead), so it goes on **fast** lanes too — see
  §3.1 for why "parity to the slow lanes" is the one intuition to discard.
- **Demoted lanes are not dead.** They keep ping/pong (raise 2 s → 500 ms while demoted, so
  `baseRttMs` stays fresh enough to justify a re-promotion), they keep receiving loss and
  skew reports, they remain in the fall-forward tail, and `sendPad` (`pcm.js:1473`) already
  round-robins pre-warm bytes across all open associations — call it on a lane at the
  moment it is promoted, which is exactly the job it was written for.

### 2.2 The re-promotion trap, and why it is the real design problem

`laneBase[k]` is a decaying minimum over *arrivals on lane k*, drifting up at 1 ms/s
(`pcm.js:1629`) and requiring 50 samples to be "warm" (`pcm.js:1643`). **A demoted lane
stops receiving data frames, so its `laneBase` stops being refreshed and drifts upward
forever — it will look progressively slower and can never be re-promoted.** A demotion is
therefore permanent by accident, which is a route-flap bug waiting to happen: the lane the
network fixed at t+40 s stays demoted for the rest of the call.

Two fixes, and they should both ship:

1. **Freeze the drift on lanes with no recent arrivals.** The drift term exists to let a
   lane's minimum recover after a transient; a lane that is receiving nothing has nothing
   to recover from. Guard `pcm.js:1627–1632` on "this lane saw an arrival in the last
   2 s"; otherwise hold `laneBase[k]` and mark it stale.
2. **Re-promote on `baseRttMs`, confirm on arrivals.** `perAssoc[k].baseRttMs`
   (`pcm.js:1541`, published at `pcm.js:2259`) is a running per-association RTT minimum
   maintained by ping/pong on *every* open association, demoted or not. Half its divergence
   from the fastest lane is the forward skew **under the symmetric-path assumption the geo
   brief §0 warns about** — too coarse to size a buffer with, entirely good enough to say
   "this lane may be worth trying again". Promote provisionally on that signal; the
   arrival minima then confirm or re-demote within the 2.4 s it takes 50 samples to
   accumulate at 125/nFast frames per second per lane.

### 2.3 Expected win

Estimator: `target = max(2, ceil(spreadHold / 8) + 1)` frames (`pcm.js:1970`), where
`spread` is (second-largest − min) of arrival delay over 320 frames (`pcm.js:1923`).
Structural lane offset enters `spread` additively; demotion removes it entirely, because
the demoted lanes contribute no arrivals.

**Measured profile (24/12/24 across 6 lanes, 6 ms heavy tail).** The de-skew ON arm is a
direct read of what the estimator does when the structural term is removed: depth 31.1 ms
(target 3 frames), implying a residual jitter spread of ~14 ms. Demotion produces the same
spread — but now every frame the receiver waits for actually arrives inside the window.

| | today | de-skew (measured) | skew-striping (predicted) |
|---|---|---|---|
| `ringDepthMs` | 58.7 | 31.1 | **~31** |
| `mouthToEarMs` | 141.1 | 118.4 | **≤118** |
| `concealedMs`/60 s | 3072 | 4064 | **~232–344** (the zero-divergence control) |

The m2e prediction is deliberately "≤", not "=". De-skew's m2e fell 22.7 ms against a
27.6 ms depth win, i.e. `ageP50` *rose* ~5 ms — the late frames it admitted were, by
construction, old ones. Demotion does the opposite: with 3 of 6 lanes carrying 12–24 ms of
extra one-way delay, half the arrivals are currently inflating `ageP50` directly
(`pcm.js:1602`). Removing them should pull `ageP50` down as well as `depthMs`, so **the m2e
win should exceed the depth win** — predicted −25 to −40 ms. Flagged as prediction; it is
assert #6 in §5.

**US-East↔India, geo brief profile (`oneWayMs` 109, `jitterMs` 12, `lossPct` 0.5).**
Scaling the rig's observed jitter-only spread (~14 ms at `jitterMs` 6, heavy) gives ~28 ms
at `jitterMs` 12. Then, for a divergence D:

| divergence D | spread today | target today | spread after | target after | depth win |
|---|---|---|---|---|---|
| 16 ms | 44 ms | 7 f = 56 ms | 28 ms | 5 f = 40 ms | **16 ms** |
| 24 ms | 52 ms | 8 f = 64 ms | 28 ms | 5 f = 40 ms | **24 ms** |
| 32 ms | 60 ms | 9 f = 72 ms | 28 ms | 5 f = 40 ms | **32 ms** |

**The win is the divergence, quantised up to a whole 8 ms frame.** That is exactly the
16–32 ms the geo brief §4.3 predicted, recovered without the concealment.

And a finding the geo brief could not have made, because it predates the measurement:
**§1.3's "realistic 24–40 ms buffer" row is only reachable on a divergent path if we act on
the skew.** With D = 24 ms the buffer is 64 ms and mouth-to-ear is 8 + ~109 + 64 + 11 =
**~192 ms**, not the 144–182 the brief tabled. Divergence is what moves US-East↔India from
*straddling* G.114's 150 ms line to *clearly over* it, and skew-striping moves it back to
~168 ms. Doubled through §5.2's turn-gap arithmetic, that is ~48 ms off the turn gap on the
hardest pair in the brief.

### 2.4 Complexity in this codebase

Small, and concentrated in files that are already about exactly this.

| Site | Change |
|---|---|
| `pcm.js:63–135` | `const T_SKEW = 0x09;` |
| `pcm.js:498–513` | `peerSkewMs`, `fastOrder`, `nFast`, `laneStateSince` beside `assocs`/`laneBase` |
| `pcm.js:1618–1653` and `pcm.js:2324–2364` | **These two blocks are a copy-paste of the same warm/min/drift logic.** Extract one `laneSkewNow()` and call it from both — otherwise the policy and the telemetry can silently disagree, which is the worst possible failure for a feature whose whole justification is a telemetry number |
| `pcm.js:1627–1632` | Freeze the 1 ms/s drift on lanes with no arrival in 2 s (§2.2) |
| `pcm.js:1414` `sendLossReport` | Add `sendSkewReport()` on the same 250 ms timer |
| `pcm.js:1510` (above the `<9` guard at 1518) | `T_SKEW` receive branch → `peerSkewMs`, then `recomputeLaneOrder()` |
| `pcm.js:964, 982, 992, 1047` | One `home =` expression each. Consider a single `laneHome(ordinal)` helper so the four cannot drift apart |
| `pcm.js:2324` `laneSkew` snapshot | Add `nFast`, `fastOrder`, `demotions`, `peerSkewMax` — the rig and the fleet both need to see the *sender's* view, not just the receiver's |
| `app.js:1602` cfg / `app.js:1676` flag parse | `pcmSkewStripe: QS.get('pcmskewstripe')` |
| telemetry end beat | `nFastMin`, `demotions` beside the existing `laneSkewMaxMs` / `deskewApplied` |
| `testbed/skew-stripe.mjs` (new) | Fork of `deskew-divergence.mjs`; `netsim.mjs:409 laneOffsetsMs` and `netsim.mjs:452 flap` already exist |

Estimate: ~40 lines of new logic, ~15 lines of wire, ~25 lines of telemetry, one new rig.

### 2.5 Risks

**The no-op invariant is structural, not empirical.** With no lane above threshold,
`nFast === PAIRS` and `fastOrder` is the identity permutation, so
`fastOrder[seq % nFast]` **is** `seq % PAIRS` — the same expression, evaluated through one
array lookup. Same-route calls are bit-identical by inspection. This is a strictly stronger
guarantee than de-skew had (whose no-op rested on `laneSkew.max` measuring ~1.1 ms, which
had to be *demonstrated* on a live call — `deskew-noop.mjs`).

**Aggregate cwnd is the real cost.** The stripe exists because SCTP's per-association AIMD
cwnd caps one association below what Lane A needs (`pcm.js:35–37`). Six lanes multiply the
available cwnd; three lanes halve that headroom — **on precisely the long-RTT paths where
cwnd is scarcest**, since in-flight bytes scale with BDP. At 218 ms RTT and 0.5 Mbps per
lane, each fast lane needs ~14 KB in flight; `backlogLimit` permits ~64 KB (§1.4), so the
*gate* is not binding, but SCTP's own cwnd collapse under loss is not something the gate
sees. `MIN_FAST = 3` and the untouched fall-forward are the mitigations, and the "kill the
fast lanes" arm in §5 is how we find out whether they are enough.

**Route flap.** `netsim.mjs:452 flap(index, deltaMs)` exists for this. A role change costs
reordering, which §1.5 says is free. The residual risk is *oscillation*: a lane hovering at
8 ms flipping every dwell period. Hysteresis (8 down / 4 up) plus a 5 s dwell bounds it,
and the estimator's peak-hold release of 2 ms per 250 ms tick (`JIT_RELEASE`,
`pcm.js:1811`) means one wrong promotion of a 24 ms-slow lane costs ~24 ms of extra depth
for ~3 s. That is the whole cost of a wrong flip: bounded, brief, and countable
(`demotions`).

**Fast lanes stall.** `pickDataAssoc` returns the next open, under-budget association
including demoted ones (`pcm.js:967–972`), so audio never stops — it degrades to
today's behaviour for the duration. This is the property §3 has to *build* and §2 gets for
free.

**A pre-existing interaction, worth fixing in passing.** `ringWrite` calls
`noteArrival(seq, skewMs)` unconditionally at `pcm.js:644`, *including* for a duplicate
that a burst-shield twin delivered. A twin is sent `DUP_DELAY_F = 3` frames late by design
(`pcm.js:847`) and rides a lane half the stripe away (`pcm.js:983`), so under divergence a
twin injects a `d` sample inflated by 24 ms of pacing *plus* the lane skew — straight into
the spread window that sizes the buffer. The shield only engages above the ladder cap
(`pcm.js:900`), so this is rare, but it is the estimator being fed an arrival it already
had. One line: skip `noteArrival` when the seq is already in the ring.

---

## 3. Option 2 — FEC-side early recovery

### 3.1 "Parity to the slow lanes" is backwards

The premise of the option as usually stated — keep striping, send parity down the slow
lanes — inverts the deadline. **Parity's deadline is the playhead, exactly like data's.**
`swRepairTry` (`pcm.js:1314`) writes recovered frames through `ringWrite` and splits them
into `fecRepaired` vs `fecRepairedLate` on precisely that test. Parity arriving 24 ms late
repairs frames the playhead has already passed. `pcmsw.js` exists *because* repair latency
is a first-class term: it bounds repair to `SW_STRIDE = 3` frames = 24 ms rather than RS's
80 ms span, after measuring that "67% of position-0 repairs arrived after the playhead had
passed".

So parity placement must be skew-aware in the same direction as data: **parity onto fast
lanes.** Which means Option 2 needs the identical `T_SKEW` feedback channel, the identical
sender-side lane ordering, and the identical staleness/flap handling as Option 1. *It is
not the cheaper option; it is Option 1 plus a code rate.*

### 3.2 The overhead arithmetic, which is the disqualifier

Let `f_slow` = fraction of data frames that ride structurally-late lanes. If we keep
striping round-robin over all six, `f_slow = (#slow lanes)/PAIRS`.

The sliding window emits one parity per `SW_STRIDE` data frames, each covering
`SW_WINDOW = 12` frames (`pcmsw.js:55–56`). A window containing `e` erasures needs ≥ `e`
independent parities covering it, and the code is explicitly **not MDS** — "random-ish
Cauchy coefficients make any e × e submatrix nonsingular with overwhelming probability but
NOT provably" (`pcmsw.js` header). So the parity rate `1/STRIDE` must exceed the erasure
rate with margin, and the erasure rate here is `f_slow + lossPct`, not `lossPct`:

| profile | slow lanes | `f_slow` | required parity rate | `SW_STRIDE` | overhead |
|---|---|---|---|---|---|
| geo brief, D on 2 of 6 lanes | 2 | 0.33 | > 0.33 + 0.005 | 2 | **50%** |
| **measured rig profile** | 3 | 0.50 | > 0.50 + 0.005 | **1** | **100%** |

Today's shipped stride of 3 is 33% overhead. Option 2 costs **+0.3 Mbps** on the geo
profile and **+1.05 Mbps** — a full second copy of the stream — on the profile we actually
measured. And at `SW_STRIDE = 1` there is no margin left for real loss at all; the next
rung does not exist.

**What the +100% buys is a re-transmission, over the fast lanes, of the frames we chose to
put on the slow lanes.** Option 1 sends them on the fast lanes in the first place, for 0%.
That is the entire comparison.

### 3.3 The two ways it fails badly

**High loss and high skew together.** These are *correlated*: the geo brief §4.1 lists the
mechanisms that produce loss on a long path (cross-ocean queuing, ECMP rehash, access-link
bufferbloat) and they are the same mechanisms that produce divergence. The parity budget
must cover `f_slow + loss` simultaneously, the ladder's `rungTop` table
(`pcm.js:239–266`) is built for `loss` alone, and once `SW_STRIDE` hits 1 the code
degrades straight to concealment — at exactly the moment both stresses coincide. This
codebase has already run this experiment under a different name: `FEC_LATE`
(`pcm.js:1391–1399`) tried to buy lateness back with parity and lost on all three metrics,
with the verdict "**redundancy cannot fix a congestion symptom, because redundancy IS
congestion**". Option 2 is FEC_LATE with a better excuse.

**The estimator fights it.** Repaired frames go through `ringWrite` → `noteArrival` *at
their repair time*, and `pcm.js:640–644` says that is deliberate: "a frame that only
existed once its RS group closed was genuinely available that late, and pretending
otherwise would size the buffer too small for exactly the frames FEC is there to save."
So repairs of structurally-late frames push `spread` — and therefore the target — back up,
undoing the depth win they were built to enable. Suppressing that would require de-skewing
repair arrivals too, i.e. re-introducing the exact correction the divergence rig killed.
**Option 2's win is self-cancelling unless it is paired with the thing that was measured
harmful.**

### 3.4 The one thing it has that Option 1 doesn't

Every lane keeps carrying data, so a fast-lane stall degrades gracefully with no policy
involved. But §2.5 shows Option 1 gets that from `pickDataAssoc`'s existing fall-forward at
zero cost. There is no residual advantage.

**Verdict: dominated. Do not build.** Keep one idea from it: on a divergent route, a
`FEC_N_MIN`-style floor is *more* valuable, because concentrating data on fewer lanes
concentrates the consequences of any one lane's loss. That is a one-constant change
(`pcm.js:234`) and belongs to the geo brief's item 6, not to this design.

---

## 4. Option 3 — the hybrid, and the alternatives that close the space

**Recommended: skew-ordered striping with hysteresis, a floor of 3 lanes, and the existing
fall-forward as the failure path.** That is Option 1 as specified in §2, which already
*is* the hybrid — it is lane-count reduction that keeps every lane open, warm, measured,
and available. Naming the alternatives it beats:

**Blunt lane-count reduction (`pairs` 6 → 3 on divergent routes).** The geo brief's §4.3
fix (3). Strictly worse: it drops the slow lanes' associations entirely, so they stop being
measurable (no re-promotion, ever), stop being available as spill capacity, and the change
has to happen at negotiation time (`app.js:1602`) rather than mid-call. Ordered demotion is
the same idea with the three properties that make it survivable.

**Skew-compensated send scheduling — send the slow lane's frame earlier.** Impossible, and
worth stating so nobody re-proposes it: frames leave at their capture tick and there is no
earlier tick to leave at. The realisable dual of "send this frame sooner" is "send this
frame down a faster lane", which is demotion.

**Per-frame deadline scheduling — let slow-lane frames play from a deeper effective
buffer.** There is one ring and one playhead (`pcm.js:536–556`). Not available.

**Continuous skew weighting instead of a binary demote.** Route a lane a share of frames
proportional to `exp(−skew/8)` rather than 0 or 1. Rejected: the estimator is quantised to
whole frames (`ceil(spread/8)`), so a lane carrying *any* steady share of frames at +24 ms
sets the spread to 24 ms and the win is zero. **The threshold has to be binary because the
buffer is.** This is the sharpest single argument in the brief for the design as specified
and it should not be softened during implementation.

**Keep the estimator de-skew (`?deskew=1`) alongside.** Unnecessary and mildly harmful.
Once demotion works, the arrivals feeding the estimator are all fast-lane arrivals and the
measured residual skew is ~0, so the correction is a no-op that can only mis-fire during
the 2.4 s warm-up and the dwell windows around a flip. **Ship demotion with `deskew`
staying opt-in-off, and retire the flag once demotion is default.**

---

## 5. How the rig verifies it

`testbed/skew-stripe.mjs`, forked from `deskew-divergence.mjs` (whose netsim profile —
`oneWayMs: 40`, `jitterMs: 6`, `jitterModel: 'heavy'`, `laneOffsetsMs: [0,24,0,12,0,24,0,0]`,
seeded — is reused verbatim so the two rigs' numbers are comparable). Arms: `?pcmskewstripe=1`
vs bare, plus the `--offsets=0` same-route control the existing rig already supports.

The asserts, and what each one is *for*:

1. `rewrites > 0` in both arms — the delay line is genuinely in the path. Unchanged.
2. `laneSkew.peerSkewMax >= 10` in the ON arm. **Note this is the sender's view, not
   `laneSkew.max`.** After demotion converges, the *receiver's* measured skew across
   active lanes collapses toward zero — the old assert would fail on success. The rig must
   read what the far end reported, which is why §2.4 adds it to the snapshot.
3. `laneSkew.nFast <= 3` in the ON arm, `=== PAIRS` in the control arm.
4. **`perAssoc[k].framesRecv` for demoted lanes ≤ 2% of the fast lanes' share.** This is
   the assert de-skew could never have: direct proof that the *striping* changed, not just
   an estimator's opinion of it. It also catches the silent failure where the report never
   crosses (§1.2's `<9` guard) and the feature no-ops while looking enabled.
5. `on.ringDepthMs <= off.ringDepthMs - 6`. Expect ~31 vs ~59.
6. **`on.concealedMs <= off.concealedMs + 200`** — *the assert that killed de-skew*
   (4064 vs 3072). It is now the headline, and it should not merely pass but win: expect ON
   near the zero-divergence control (232–344 ms) against OFF's ~3072. Consider tightening
   to `on.concealedMs <= 600` once one run confirms it.
7. `on.mouthToEarMs <= off.mouthToEarMs - 15`. De-skew scored −22.7; demotion should beat
   it (§2.3), so this is a floor, not a target.
8. **`on.bytesSent` within 2% of `off.bytesSent`.** The assert that distinguishes this
   design from Option 2, which would fail it by 33–100%. Cheap, and it is the one number
   that would catch a well-meaning "just add parity too" during implementation.
9. **Flap arm.** `sim.flap(idx, +24)` on a *fast* lane at t+30 s. Assert `nFast` recovers
   its value within 10 s, `demotions <= 2` over the 60 s run (no oscillation), and
   `concealedMs` in the 5 s after the flap stays under a stated bound.
10. **Stall arm.** Close three fast datachannels mid-call. Assert `framesRecv` keeps
    advancing and `concealedMs` lands within the OFF arm's range — i.e. the failure mode is
    "today's behaviour", not a hole.
11. **Same-route no-op** (reuse `deskew-noop.mjs`'s shape, live prod, no delay line):
    `nFast === PAIRS`, `demotions === 0`, and per-lane `framesRecv` within ±5% of an even
    six-way split. Since §2.5 makes this true by construction, a failure here means the
    permutation plumbing is wrong, which is exactly what it is there to catch.

---

## 6. Recommendation and staging

**Build skew-aware striping (§2). Do not build FEC-side early recovery (§3).**

Each stage is independently verifiable on the rig; nothing goes default-on until the rig
and one live long-path call agree.

**Stage 0 — the gate (already shipped).** Skew is measured unconditionally and reported on
every real call's end beat (`laneSkewMaxMs`, `deskewApplied`). **Decision rule, stated now
so it is not negotiated later: if fleet p95 `laneSkewMaxMs` on real calls is < 8 ms, this
whole brief is a null and we stop.** Below one frame, the estimator's quantisation cannot
spend the win. Also record the *distribution*, not just the max — "2 of 6 lanes diverge"
and "1 of 6 diverges" have different `MIN_FAST` implications.

**Stage 1 — feedback only, no routing change.** `T_SKEW` on the wire, `peerSkewMs` on the
sender, `nFast`/`fastOrder`/`peerSkewMax` in the snapshot, `laneSkewNow()` deduplicated,
drift frozen on quiet lanes. Flag gates whether the report is *sent*. Rig gate: the
sender's `peerSkewMs` matches the injected offsets within 2 ms (receiver-side detection
already scored ±1.5 ms), and `perAssoc[].framesSent` is **unchanged to the frame** against
the control. This stage is where the `<9`-byte guard bug either bites or doesn't, in
isolation, where it is trivial to see.

**Stage 2 — demotion, opt-in `?pcmskewstripe=1`.** `MIN_FAST = 3`, demote ≥ 8 ms, promote
≤ 4 ms, 5 s dwell. Rig asserts 1–8 and 11. **Advance only if all three of: depth −6 ms or
better, conceal ≤ control + 200 (and ideally ≤ 600), bytes within 2%.** Any one of those
failing is the same kind of result de-skew produced, and the same response applies.

**Stage 3 — flap and failure hardening.** Assert 9 and 10. Re-promotion warm-up via
`sendPad` on a promoted lane; `baseRttMs`-based provisional promotion (§2.2). This is the
stage that decides whether `MIN_FAST = 3` is right or whether it needs to be 4.

**Stage 4 — one live long-path call.** This is the dependency that does not yet exist: the
geo brief §6.3(b) cloud-VM vantage (`us-east-1` first). Report both ends'
`clockOffsetMs` and check they sum to ~0 before quoting any m2e (geo brief §0) — on a
divergent path with an asymmetric route, the m2e number is biased in opposite directions at
the two ends and a one-sided reading could manufacture the win. Also report `nFast`,
`peerSkewMax`, and `perAssoc[].framesSent` so the live call answers "does real divergence
look like the injected kind?"

**Stage 5 — default on.** Per the project's convention, ship default-on with
`?pcmskewstripe=0` as the control, once Stage 2's rig verdict and Stage 4's live call
agree. Retire `?deskew` at the same time: demotion makes the estimator correct rather than
correcting the estimator, and two overlapping corrections is how a measured control law
quietly becomes a tuned one.

**What would make me abandon this.** Fleet p95 skew < 8 ms (Stage 0). Or Stage 2 showing
the depth win but with conceal above the control — which would mean the fast lanes cannot
carry the concentrated rate, and the answer would then be `MIN_FAST = 4` or nothing. Or
Stage 3 showing oscillation that hysteresis cannot damp on a real flapping route, in which
case the honest fallback is a *one-way ratchet*: demote on evidence, never re-promote
within a call, and accept losing a lane permanently to a transient.

---

## 7. Sources

### Measurements
- `MEASURED.md` §"Per-lane de-skew" and §"De-skew divergence verdict" (2026-08-13) — the
  25.5/11.6/25.3 detection, ring 31.1 vs 58.7, m2e 118.4 vs 141.1, conceal 4064 vs 3072,
  zero-divergence control 232–344, second-seed repeat +472
- `testbed/deskew-noop.mjs` — same-route safety arm, `laneSkew.max` 1.1 ms

### Repo sources read
- `/Users/deveshpatel/Downloads/video calling/tape-app/public/pcm.js` — striping and pickers
  (964, 982, 992, 1047), gate budget (270–291), lane skew estimator (500–513, 1618–1653)
  and its duplicate in the snapshot (2324–2364), arrival estimator (1749–1877, 1970),
  `noteArrival` from `ringWrite` (632–644), loss-report feedback channel (1414–1434,
  1510–1517) and the `<9`-byte guard (1518), wire types (63–135), FEC ladder (225–266),
  `FEC_LATE` verdict (1391–1399), sliding-window send/repair (1151–1163, 1314–1330),
  burst shield (826–847, 1133–1145), pad pre-warm (1466–1498), `attachChannel` (2142)
- `/Users/deveshpatel/Downloads/video calling/core/pcmsw.js` — `SW_WINDOW = 12`,
  `SW_STRIDE = 3`, `setStride`, the non-MDS caveat in the header
- `/Users/deveshpatel/Downloads/video calling/tape-app/public/app.js` — `pairs: 6` (1602),
  flag parsing (1676), stripe pc / channel labels (2133, 2174, 2178)
- `/Users/deveshpatel/Downloads/video calling/testbed/netsim.mjs` — `laneOffsetsMs` (409),
  `jitterModel: 'heavy'` (273), `flap` (452)
- `/Users/deveshpatel/Downloads/video calling/testbed/deskew-divergence.mjs` — the rig this
  brief's rig forks, and its assert set
- `/Users/deveshpatel/Downloads/video calling/testbed/specs/latency-geo.md` — §0 clock
  asymmetry, §1.3 m2e-by-pair, §4.2–4.3 estimator and divergence lever, §4.4 RFC 8854 /
  `FEC_N_MIN`, §5.2 turn-gap arithmetic, §6.3(b) cloud vantage, §6.4 profiles
