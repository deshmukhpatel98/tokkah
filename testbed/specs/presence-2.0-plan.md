# Presence 2.0 — the plan for "better than in person"

Reset directive (2026-08-12): "It really has to be better than how people
interact in the real world in person, face-to-face… we are not even 0.1%
there. Plan this properly and test this properly by yourself, then ask me to
give it a look." Standing constraints: super lightweight on low-end devices at
the same experienced quality; zero added latency to the AV pipeline; features
default ON; all verification on live prod calls with real human media; the
operator is asked to look ONCE per feature, after every measurable threshold
is green ([[self-test-before-user-review]]).

## 0. What "better than in person" decomposes into

In person, the medium adds nothing: no latency, no frame, no self-view, no
freeze. A call CAN beat in person only on dimensions where physical presence
is itself constrained — but first the medium's own tax must drop below notice.
Two workstreams, strictly ordered:

**W1 — Remove the medium tax (parity work).** Everything a 6-month-old already
gets in person: things move when you move (depth), people are the right size
(scale), eyes meet (gaze), you know what others see of you (self-awareness),
sound and sight are one event (sync), answers come back as fast as thought
(latency — already ~50ms, world-class).

**W2 — Beat the room (superiority work, only after W1 holds).** Where a call
can exceed in-person: always-perfect sight lines (no bad seat), lossless
whisper-quality audio at any distance, presence across continents with
sub-100ms conversation gaps, translation, memory of the conversation. W2 is
worthless while W1 leaks — a magical translation on a jerky window is a toy.

## 1. The audit standard (defined BEFORE building)

Every W1 feature ships only when ALL of its numbers are green in the
metrology rig (testbed: CDP frame capture on live prod calls, real fixtures,
Chrome AND WebKit arms — the operator is on Safari, 19.3Hz realized tracker,
strong tier, 8 cores, 1080p30 cam, dpr 2, per beat id=152/153):

| Dimension | Metric (measured from rendered frames) | Green |
|---|---|---|
| Responsiveness | motion-to-photon: fixture head-move onset → first rendered picture displacement | < 100 ms Chrome, < 130 ms WebKit (then close the gap) |
| Smoothness | rendered displacement is C1: no frame-over-frame velocity reversals during a monotone head sweep; jerk bounded | 0 reversals; p95 per-frame Δv < 15%/s² norm |
| Stillness | transform variance while fixture head is still ≥5 s | 0.000 px (bit-still) |
| State truth | unseen fires ≤2 s after face truly leaves; rebloom ≤400 ms after return; NEVER fires with a live face present | 100% over ≥10 transitions |
| Do no harm | mouthToEarMs, concealPct, framesDecoded rate vs ?window=0 control on same fixture | statistically indistinguishable |
| Weight | added bytes fetched on weak tier; main-thread ms/tick on 4-core throttled | ≤300 KB; ≤3 ms/tick |

A feature that cannot state its table row like this is not ready to build.

## 2. W1 roadmap (each row = one operator look at the end)

1. **Window that feels real** (in flight): aperture parallax + peekaboo.
   Remaining to green: WebKit cadence/lag row, smoothness row measured (not
   felt), stillness row re-proven after every tuning change. The 2.5%/±3%
   gains are LAST-mile tuning — only after the physics rows are green.
2. **True-scale presence** (brief §2): remote face rendered at personal/social
   boundary angular size, scale coupled to viewer distance (lean back →
   they recede). Mostly the same transform; its rig rows are scale-specific
   (no pumping with breath: scale spectral power above 0.3 Hz ≈ 0).
3. **Eye-line** (brief §3, static term already shipped): measure where remote
   eyes actually land vs the 1.76°-below-camera target across viewport sizes;
   make the offset computed, not the current fixed 2%.
4. **Sync & turn-gap instrumentation to the fatigue bar**: humanGapMs fleet
   p50 < 300 ms (in-person is ~208; Zoom ~487); A/V offset inside +45/−125 ms
   detectability on every tier.
5. **Self-awareness without a mirror**: edge cues + unseen state are shipped;
   the remaining question is dosage (opacities/timings) — tune only against
   recorded self-tests, not operator rounds.

## 3. W2 candidates (locked until W1 rows are green)

Ranked by presence-per-effort from the research brief + product state:
three-person mesh (built, staging-proven, flag-off), spatial voice placement
(shipped, needs W1-grade verification), live translation depth, "perfect
seat" (auto-framing that in-person cannot do), room-scale audio presence.

## 4. Operating rules for this plan

- The metrology rig is the ONLY judge until all rows are green; the operator
  is the judge of magic, once, at the end of each roadmap row.
- WebKit is a first-class arm in every rig run (the operator lives there).
- Every tuning change re-runs the full table — smoothness and stillness
  regress silently otherwise (proven twice this week).
- Fleet telemetry fields (apTracker/apHz/apTrackedPct/tier + the echo panel)
  are the ground truth for "does it hold on real machines we don't own."
