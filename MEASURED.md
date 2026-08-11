# Every number we can defend

Source of truth for the launch blog. If a claim is not in this file with a method
next to it, it does not go in the blog. Anything comparative against a named
competitor is in `BENCHMARK.md` and is **blocked** — see the end of this file.

All figures measured against **production** at `room.tokkah.com`, 2026-08-02 and
2026-08-03 (live `45b344fe`).

> **Under-loss figures recorded before 2026-08-03 are void.** The rig deduped on
> a timecode index that wraps every 256 frames, so it reported only the first
> 8.5 s of every run and its delivery ratio saturated toward 100%. Clean-path
> figures and arm-vs-arm comparisons survive — both arms were truncated
> identically. See "Every latency number this rig produced covered the first 8.5
> seconds".

## Getting into a call

| | measured | method |
|---|---:|---|
| clicks, host, from the bare domain | **1** | every trusted gesture logged in-page, cold load, phone viewport |
| clicks, guest, from a shared link | **1** | same |
| guest: link opened → **real picture of the other person** | **2,083 ms** | luma-variance gate on the remote surface, not a status string |
| self-preview live | ~1,300 ms | `#preview.videoWidth > 0` |

One click is the floor, not a target we stopped short of: `getUserMedia` requires
a user gesture, so zero is unreachable for a guest. It is reachable for a *host*
if the bare domain minted a room on load — at the cost of a camera running before
anyone asked for it, which is the wrong trade.

*Caveat:* both browsers on one machine, so the 2,083 ms excludes real-world RTT
to the signalling edge. It is a floor.

## Video

| | measured | method |
|---|---:|---|
| glass-to-glass, p50 | **23.0 ± 1.7 ms** (n=10) | timecoded fixture, in-page rAF, receiver display minus sender preview |
| glass-to-glass, p95 | **43.0 ± 4.4 ms** (n=10) | same |
| resolution delivered | **the camera's own** — 720p in → 720p out, 1080p in → 1080p out | encoder config off the wire + far-end surface, both arms |
| outbound, 720p camera | **6.43 Mbps** | sender transport stats, 20 s window after 12 s settle |
| under RTT 80 ms / 1% loss | **holds 1080p** where stock WebRTC collapses to 1280×720 | `--p2psim` shaping, two 45 s arms |
| frames lost under that shaping | **0** vs 460–468 packets and 2 freezes for stock | `getStats` |

The rig is validated: it reproduces these against an independently built probe
that reported 27.3/46.9, and it correctly rejects all four self-view elements on
the page. See `BENCHMARK.md` for the three instrument bugs that had to be fixed
before it could be trusted.

### The "1920×1080" in the row above used to be a lie

The encoder was configured at `WANT_W × WANT_H` (1920×1080) regardless of what
the camera produced. Feed it a 720p sensor and WebCodecs upscaled: 2.25× the
pixels carrying no extra information. Because the far-end canvas faithfully
tracks `frame.displayWidth`, **every instrument downstream dutifully reported
"1080p delivered"** — the measurement was correct and the thing it measured was
a defect. A bigger number from the instrument was the bug, not the achievement.

Fixed: `cfg.width/height` is now a ceiling, not a target. A sensor above it is
still downscaled; only the upscale is gone. Priced with the same camera, same
content and same QP in both arms (`?upscale=1` restores the old behaviour and
exists only as that control arm):

| 720p camera, real content | outbound |
|---|---:|
| encode at the ceiling (old) | 7.89 Mbps |
| encode at the camera's size (now) | 6.43 Mbps |
| **cost of the upscale** | **1.46 Mbps — 19% of the stream, for zero extra picture** |

It is **also** a latency win, which took a second look to establish. Comparing
two single runs (28.5 → 27.2 ms) said "barely moved", and that went into this
file. It was wrong: run-to-run spread on one fixed build is ±1.7 ms, so a single
pair cannot see a 4 ms effect. Five runs per arm, interleaved so drift loads on
both equally:

| 720p camera, p50 | p95 |
|---|---:|---|
| upscaled to 1080p (`?upscale=1`) | 26.5 ± 1.6 ms | 48.4 ± 2.0 ms |
| native 720p (now) | 22.7 ± 1.4 ms | 41.2 ± 2.1 ms |
| **difference** | **3.8 ms** (t = 4.0) | **7.2 ms** |

So: 19% of the bandwidth *and* ~3.8 ms p50 / ~7.2 ms p95, for a 720p camera —
which is most laptop webcams. Every number in this file that came from a single
run should be read with that ±1.7 ms in mind.

A shaped run at RTT 80 ms / 1% loss shows the two peers now encoding 1080p and
720p independently, each following its own sensor, with **0 frames lost, 0
gapped, 0 decode errors** on both sides — the headline shaping claim is
unaffected by the change.

**The capture ladder case is now fixed too.** When the fps probe finds the
camera starving it steps capture down a tier, which used to leave a smaller
track feeding an encoder still configured at the old size — reinstating the
upscale mid-call, in exactly the bad conditions where the waste hurts most. The
encoder now follows the frame, after a new size holds for 5 consecutive frames
(~167 ms at 30 fps, so one odd frame cannot trigger a reconfigure). Verified
against production by forcing a real `applyConstraints` step-down on a live
call:

```
tape-resize {lane: "rtp", from: "1920x1080", to: "640x360"}
far end: 640x360, still moving (luma variance 125.5), 0 failed reconfigures
```

The far-end picture was checked in **pixels**, not counters — a reconfigure
resets the reference chain, so the failure to hunt is a frozen remote view while
every counter still reads healthy. A same-size request produced no reconfigure,
as intended. No latency cost from the per-frame check: 21.8 / 22.2 / 22.4 ms p50
afterwards, inside the 23.0 ± 1.7 band.

### A camera flip used to end the video lane for the rest of the call

Found by reading the flip path, then confirmed against production. The lane's
capture pump reads the camera through a `MediaStreamTrackProcessor` created once
at lane start-up, and its loop ended on `if (done) return;`. The flip's last act
is `old.stop()`, which ends that reader — so the pump returned and never came
back. There was no RTP fallback either.

| far end, after the camera is swapped | before fix | after fix |
|---|---:|---:|
| frame rate | **0.4 fps** (lane P stills) | **29.0 fps** |
| recovered within 35 s | no | immediately |

The pump now re-attaches: `adoptTrack(nv)` moves the pump's track and cancels
the reader, the pump sees the track has moved and re-attaches, forcing a
keyframe. `adoptVideoTrack()` calls it **before** the caller stops the old
sensor.

**Both lanes had it.** Lane 1 (the datachannel fallback) was the same shape and
is now fixed the same way. Proven with both arms on one live build, the only
difference being whether `adoptTrack` is called: control 30 fps → **0.4 fps**,
permanent through +30 s, `trackSwaps: 0`; treatment 30.3 → **29.9 fps**,
`trackSwaps: 1`. `testbed/flip-lane1.mjs`.

#### The 22 fps was a second bug, and it is fixed

The first write-up of this section said the far end settled at ~22 fps instead
of ~30 and that I could not attribute the drop. It is attributable, and it was
not the fixture.

Lane 2's video sender does not hold the camera. It holds a **320×180 canvas
ticking at 60/s** — the transform substitutes our own encoded frames for its
payload, so the carrier is only a clock. One tick carries one frame and parity
frames spend ticks too, which makes the tick rate a hard throughput ceiling.
`tape.js` had already computed it: a 30 fps carrier caps data at
30 × G/(G+1) = **22.5 fps**, and asking the canvas for 60 is what lifts that
ceiling to 45.

`adoptVideoTrack()` replaced **every** video sender's track, carrier included.
So a flip swapped the 60/s canvas for the 30 fps camera and throughput fell to
the ceiling the carrier exists to lift — and libwebrtc began encoding a full
720p frame per tick that is then thrown away. The fix skips
`tapePre.getCarrierSender()`; every other video sender still takes the new
track, because that is the plain-RTP fallback path and it does carry the camera.

| lane 2, after a flip | old body | fixed |
|---|---:|---:|
| far end settled | **22.7 fps** | **29.0 fps** |
| video sender holds | camera @30 | carrier canvas @60 |

Measured 22.3 and 22.7 against a figure of 22.5 that the source predicted before
I measured it. The two arms ran against the same deployment; the sender's own
track label and frame rate are printed each run, so "did the carrier survive"
is read out rather than assumed. `testbed/flip-carrier.mjs`.

One honesty note remains. The fake-device browser exposes one camera, so the
flip *button* early-returns (`cams.length < 2`); the tests drive
`adoptVideoTrack` itself — exposed as `window.__tape.adopt` for exactly this
reason — so the button's own device-enumeration logic is still unverified.

Diagnosing it needed two instrument fixes first, both of which produced a
confident wrong answer: a "did the pixels change in 500 ms" probe flickered
between moving and frozen (a near-static fixture passage and 1 fps stills both
look like that), and the first version stopped `sender.track` — which on lane 2
is the **carrier canvas**, not the camera, so it proved nothing and reported
"SURVIVES". Counting distinct frames per second against the timecode fixture
separates 30 fps / 1 fps / 0 fps unambiguously.

The receiver needed no change: `avc: { format: 'annexb' }` carries SPS/PPS
inline, so the keyframe after a reconfigure is self-describing and the canvas
already tracks `frame.displayWidth`. Sending a fresh `cfg` would have rebuilt
its decoder for nothing. **Lane 1 now has the same mid-call resize and the same
`adoptTrack`**, so the fallback lane is no longer the one that breaks on a flip.

## Audio under loss: one byte count, and then a bandwidth ceiling behind it

Fixed and deployed 2026-08-03. Concealment at 5% loss went **36–41% → 2.5–4.3%**,
and at 10% loss **60–76% → 4–10%**. It took two causes, and the second was
invisible until the first was fixed — the framing bug was large enough to hide a
congestion bug of similar size sitting directly behind it.

**The claim's state before.** On a clean path audio is genuinely bit-exact:
`concealedMs 8` and `0` on a 60 s call, `fecFailed 0`. Under 5% loss it was not
close: 36–41% of played audio was concealed rather than received
(`concealedMs 35984` of a ~102 s call), and that is invented signal, not
lossless. The clean path is unchanged by everything below; only the loss path
moved.

**Why FEC does not save it.** RS(10,13) tolerates 3 erasures in 13. The
emulator's loss is independent Bernoulli (`rnd() * 100 < loss`), so at 5.6% only
~0.3% of groups should be unrepairable. `fecFailed` is instead the largest term
in the accounting. FEC is not underpowered — it is being handed a much worse
channel than the one configured.

**The cause: an audio frame is bigger than a datagram.** A frame is 384 samples
× int24 = 1152 B plus a 24 B header = **1176 B**. The emulator counts what it
actually carried, and the two do not reconcile:

| | |
|---|---|
| datagrams dropped | 5.56% (asked 5%), `sendErrors 0`, `unreachable 0` |
| audio frames missing at the receiver | **13.4%** (B sent 12686, A received 10982) |
| sender's own contribution | `skipBuffered` ~110 total — negligible |

The sender put them on the wire and the emulator dropped 5.6% of datagrams, yet
13.4% of frames failed to arrive. A message split across *k* datagrams is lost if
any piece is: `1 − (1 − 0.0556)^k` gives 10.8% at k=2 and 15.8% at k=3, so the
observed 13.4% implies **k ≈ 2.4**.

Counted directly, in one 60 s run: the two sides sent 23,346 audio messages of
1176 B, plus ~3,600 video frames of similar size — ~27,000 messages that each
need a full-size datagram. The emulator carried **16,666 datagrams ≥1100 B**
(~17,650 offered). Far fewer full-size datagrams than full-size messages, so a
1176 B frame demonstrably does not travel as one.

This codebase already knows the safe size: the video lane fragments at **1100 B**.
The audio lane sits 76 B above it and pays for it on every single frame.

**Consequence.** The effective audio loss rate is ~2.4× the network's. At 5.6%
network loss RS(10,13) leaves ~0.3% of groups unrepairable; at the 13.4% the lane
actually sees, ~8%. The FEC was sized for the link and is being run against a
channel the framing made 2.4× worse.

**The budget is measured, not assumed: 1160 B.** `testbed/mtuprobe.mjs` wires two
peer connections through the same UDP proxy the loss tests use, sends 150
messages at each size, and reads the proxy's own packet-size histogram — so the
answer comes from the emulator rather than from anything the application believes
about itself. The step is unmistakable:

| message size | datagrams/message | tiny tails per 150 |
|---|---|---|
| 1150 | 1.53 | 79 |
| 1158 | 1.50 | 75 |
| **1160** | **1.53** | 79 |
| **1162** | **3.01** | 302 |
| 1176 (ours) | 3.00 | 300 |

One datagram up to **1160 B**, two from **1162 B**; ~77 B of DTLS/SCTP overhead
per datagram. (Baseline is ~1.5 rather than 1.0 because SCTP SACKs ride the same
path; fragmenting doubles data packets and SACKs together, so the step is
1.5 → 3.0.) **The PCM frame is over by exactly 16 bytes.**

That rules out the cheap fix. The 24 B header is `type`(1) + `parityIdx`(1) +
`bitmap`(2) + `seq`(4) + `wall`(f64) + `capUs`(f64); demoting both f64s to u32
saves only 8. Reaching 1160 needs an **8-byte header** — dropping `wall` and
`capUs` from the wire entirely and deriving them from `seq`
(`capUs = base + seq × 8000`, base sent once over ctl). That is exactly
reconstructible, but it is a wire-format change plus a semantic change to `age`
(it would become time-since-ideal-capture rather than time-since-send, which is
arguably the more correct anchor for A/V sync anyway), and both sides must change
together.

### Fixed and deployed: compact framing, 1176 B → 1157 B

The 8-byte header turned out to be reachable without touching the sample format.
Bytes 1–3 of the data header are *written as zero and never read*, so a data
frame needs only `type`(1) + `seq`(4) = **5 B → 1157 B**. The parity receiver
reads `idx`/`bitmap`/`base` and never its `wall`, so parity needs
`type`(1) + `idx`(1) + `bitmap`(2) + `base`(4) = **8 B → 1160 B**. Both f64s move
to a 21 B `T_ANCH` sent 4×/s (84 B/s):

- `capUs` extrapolates **exactly** — 8000 µs per seq by construction, which is
  the same mechanism `capUsFor()` already used for FEC-repaired frames, since
  parity covers payload only and a repaired frame has no header to read.
- `wall` becomes time-since-ideal-capture rather than time-since-send. The
  anchor is chosen as the **least-delayed** frame of each window (minimum of
  `wall − seq×8`), not the latest, because the receiver derives ~31 frames from
  one anchor and would otherwise inherit that one frame's main-thread jitter
  across all of them.

RS is untouched: parity covers payload only, so header size never entered it.
`?pcmc=0` restores the 24 B header as a control arm, and the receiver reads both.

**Verified on the wire, not assumed.** The sender now reports `bPerFrame` /
`bPerParity` off its own byte counters, because "the fix is deployed" and "the
frames on this call are 1157 B" are different claims. Both arms, 60 s, RTT 80,
5% loss, `pcmpairs=3`:

| | legacy (`pcmc=0`) | compact | |
|---|---:|---:|---|
| bytes per data frame | 1176 | **1157** | sender's own counters |
| audio frames missing | 13.5% | **10.0%** | `framesSent` vs peer `framesRecv` |
| `fecFailed` | 5393 / 4311 | **3260 / 3296** | per side |
| datagrams <120 B | 58,302 | **46,246** | the fragment tails, gone |
| datagrams offered, whole call | 134,773 | **127,613** | fewer packets for the same call |

### The second cause: one SCTP association cannot carry the lane

10.0% was still not 5.6%, and the remaining gap is **not** framing. The probe now
measures *message survival* at a known link loss instead of counting datagrams —
datagram counting cannot work on a live call, where the histogram mixes SRTP
video, STUN, SACKs and three associations into one bucket. At 5% link loss a
1-datagram message should lose ~5%, a 2-datagram one ~9.8%:

| message size | message loss | peak `bufferedAmount` | |
|---|---:|---:|---|
| 800 B | 6.8% | 800 | one datagram |
| **1157 B** | **5.6%** | 4,628 | **one datagram — the fix is real** |
| 1176 B | 10.0% | 7,056 | two datagrams |

So 1157 B costs one datagram in isolation. Holding the size at 1157 B and
varying only the *rate* on one association:

| offered | | message loss | peak `bufferedAmount` |
|---|---|---:|---:|
| 25 msg/s | 0.23 Mbps | 7.0% | 1,157 (one message) |
| 42 msg/s | 0.39 Mbps | 8.0% | 3,471 |
| **59 msg/s** | **0.54 Mbps** | **12.6%** | **120,717** |
| 83 msg/s | 0.77 Mbps | 38.0% | 297,386 |

The loss is rate-dependent, and `bufferedAmount` says why: past ~0.4 Mbps the
association queues without bound. That is AIMD — SCTP's congestion window is
**per association**, and a Reno-like window carries roughly `MSS×1.22/(RTT×√p)`,
which at MSS 1234 B / RTT 80 ms / p=0.05 is ~0.67 Mbps as an upper bound. The
audio lane offers 1.5 Mbps + 30% FEC ≈ 1.95 Mbps; across 3 associations that is
0.65 Mbps each — sitting exactly on the ceiling, where any oscillation queues.

Two mistakes were needed to see this, both of them the probe measuring itself:
at 1250 msg/s it reported 80% loss at *every* size (SCTP abandons the queued
burst before it reaches the wire), and at 125 msg/s — the whole lane's rate — it
still reported 40–58% with `bufferedAmount` at 1.6 MB. The probe now prints
`maxBuf` on every row so backpressure can never again be read as path loss.

### Widening the stripe: the actual fix for loss

`?pcmpairs=N` already existed (N associations, N congestion windows). 60 s per
arm, RTT 80, compact framing, concealment is *invented* audio as a share of
played audio:

| link loss | pairs | concealed A / B | `fecFailed` A / B | frames missing | frames sent of captured |
|---:|---:|---:|---:|---:|---|
| 0% | 3 | 0.0% / 0.0% | 0 / 0 | 0.0% | 9044 / 9044 |
| 0% | 6 | 0.0% / 0.0% | 0 / 0 | 0.0% | 9040 / 9040 |
| 5% | 3 | 27.0% / 25.2% | 3260 / 3296 | 10.0% | full |
| 5% | 5 | 4.3% / 1.6% | 280 / 140 | 6.7% | full |
| 5% | 6 | 3.1% / 2.7% | 413 / 369 | 5.8% | full |
| 5% | 8 | 2.5% / 2.5% | 152 / 239 | 6.0% | full |
| 10% | 3 | **76.5% / 60.2%** | 6677 / 7190 | — | **8143 of 10327** |
| 10% | 6 | 9.6% / 4.1% | 1094 / 349 | — | 9040 of 10312 (full) |

At 5% loss, frames missing falls to 5.8% — the link's own 5.5%, i.e. **the
transport is no longer adding loss of its own.** At 10% loss, `pairs=3` cannot
even get the audio out of the sender (`framesSent` 8143 of 10327 captured,
`bufferedAmount` 16 KB and 57 KB) and 60–76% of what the listener hears is
invented; `pairs=6` sends every frame and conceals 4–10%.

The clean path is unchanged at 0.0% concealed either way, and **no clean-path
cost is measurable.** Video latency, 4 interleaved reps per arm at RTT 80: 62.2
± 2.1 ms at `pairs=3` vs 64.3 ± 1.2 at `pairs=6`, t = 1.80 — not distinguishable,
so the effect is bounded at a few ms rather than shown to be zero. Jitter depth
first read 12.9 → 17.8 ms and looked like a real cost; it did not replicate
(`pairs=6` measured 12.3 / 12.2 ms on the shipped-default run against 12.9 / 12.8
at `pairs=3`), so that was run noise and is withdrawn.

**Both fixes are load-bearing — neither is redundant.** The 2×2, run interleaved,
concealment per side:

| | legacy 1176 B | compact 1157 B |
|---|---|---|
| 5% loss, pairs 3 | 41.4 / 24.7% | 27.0 / 25.2% |
| 5% loss, pairs 6 | 6.5 / 6.7 / 7.3 / 7.0% | **2.5 / 1.2 / 2.9 / 1.1%** |
| 10% loss, pairs 3 | — | 76.5 / 60.2% |
| 10% loss, pairs 6 | 18.3 / 12.3% | **7.9 / 5.4%** |

At `pairs=6` the framing alone is still worth 3.6× at 5% loss and 2.3× at 10%,
and audio frame loss is 10.9% legacy against **5.9%** compact — exactly the
two-datagram versus one-datagram prediction. Legacy also puts ~30% more datagrams
on the wire for the identical call (158,836 against 124,477 offered).

**A/V sync did not regress** when `capUs` moved off every frame onto the anchor,
which was the correctness risk in the change: `avDrops 0` in every arm, and
`avOffP50` 50.8 / 63.7 ms compact against 66.8 / 66.4 legacy. The extrapolation
is exact rather than approximate because the `AudioContext` is constructed with
an explicit `sampleRate: 48000`, making 384 samples exactly 8 ms.

**Shipped defaults verified end to end** (no query overrides, `pairs=6`,
compact): `bPerFrame 1157` / `bPerParity 1160`, concealment 0.0% at 0% loss,
3.3% / 0.5% at 5%, 9.0% / 10.0% at 10%, `avDrops 0` throughout.

### Still open

1160 B was measured on a 1500 B path, so a VPN or a 1400 B PMTU puts parity back
over the line — 1157 B data would still fit, but with no margin. The durable fix
remains **lossless compression of the frame**: linear prediction + Rice coding
takes 30–50% off 24-bit speech, which clears the budget at any plausible PMTU,
and — now that the rate ceiling is the binding constraint — cuts the offered
1.5 Mbps by a third, which is worth more than the byte count. 384 samples and the
8 ms unit are hardcoded across the SAB ring layout and both worklets.

### Two more counters the rig never read

Both existed and were never printed, which is how the above stayed invisible:
the PCM lane's FEC accounting (`fecRepaired` / `fecRepairedLate` / `fecFailed` /
`late`, and `captureFrames` vs `framesSent` vs `framesRecv`), and **the
emulator's own** `dropped` / `bwDropped` / `sendErrors` / `unreachable`. The
second is now printed on every run as `netsim actual:` with a HARNESS LOSS
warning above 0.5%, because an application counter cannot tell an injected drop
from an emulator one. On this run it exonerated the harness — 5.56% asked 5%,
zero send errors — which is what made the 13.4% attributable to framing.

## The code rate was a constant, and it was wrong at both ends

Deployed **9080820c**, control arm `?pcmfecadapt=0`. RS(10,13) corrects 3
erasures in 13 — a tolerance of 23.1% — and it was applied to every link
identically. Both ends of that were measured, on one build, same day:

| link | conceal | fecRepaired | fecFailed | what the parity did |
|---|---:|---:|---:|---|
| clean | 0.0% | **0** | 0 | 1577 packets, **~0.30 Mbps, zero repairs** |
| 10% loss | 1.9%¹ | 478 | 25 | near its theoretical floor |
| 20% loss | 26.1% | 277 | **1415** | tolerance exhausted |

A third of the audio lane, spent always, buying nothing on a good link and
unable to save a bad one. That is not a code rate, it is a constant.

**The fix is sender-local and needed no wire change for the audio itself.**
`rsDecode()` already collects whatever parity slots arrived and requires only
`pr.length >= erasures`, so *sending* fewer symbols is indistinguishable at the
receiver from parity lost in flight. Nothing is negotiated; the rate may change
between one group and the next. Each rung is the smallest `n` whose binomial
group-failure probability `P(Bin(10+n, p) > n)` stays near 1%:

| measured loss | n | redundancy |
|---|---:|---:|
| none at all | 0 | 0% |
| ≤ 1.5% | 1 | 10% |
| ≤ 4% | 2 | 20% |
| > 4% | 3 | 30% |

n=0 is reserved for windows that saw *no* loss, not merely little: with no
parity, concealment equals raw loss exactly.

Feedback is a 2-B→3-B `T_LOSS` datagram, 4×/s on every association, travelling
**opposite** to the audio it describes — a receiver reports what it is missing
so the peer can set *its* rate. Loss is measured on the data sequence itself,
never on the group bitmap: that bitmap is only ever set by an arriving parity
message, so at n=0 it stays zero forever and a ladder built on it could never
climb back out.

### What it bought, and what it cost

Interleaved `testbed/ab.mjs`, n=4 per arm, 40–60 s runs, both arms on the
identical emulated link.

| condition | adaptive | fixed | verdict |
|---|---:|---:|---|
| **clean, lane** | **0.730 Mbps** | 0.925 Mbps | **−21.1%, exact** |
| clean, conceal | 0.01 ± 0.03% | 0.04 ± 0.08% | t = −0.63, no change |
| clean, delivered | 98.1 ± 0.6% | 97.8 ± 0.6% | t = 0.61, no change |
| 10% loss, lane | 0.925 | 0.925 | identical — converges to n=3 |
| 10% loss, conceal | 4.54 ± 1.06% | 5.95 ± 0.76% | t = −2.17, **not claimed** |
| burst, conceal | 3.09–3.19% | 2.84–2.98% | **+0.2 pp, the real cost** |
| burst, lane | 0.830 | 0.930 | −10.8%, exact |

The clean-link saving has **zero spread in both arms across all four reps** —
it is arithmetic, not a sample. Under sustained loss the adaptive arm *becomes*
the fixed arm, which is why nothing there moves.

The burst cost is real. Over clean→10%→clean the ladder starts at n=0 and needs
about a second to believe a burst, and that costs ~0.2 percentage points of
concealment. It never reached the rig's t ≥ 2.5 bar in any single A/B (2.40,
1.75, 1.69) but it was the same sign and size in all three, which is more
persuasive than any one of them.

**Two attempts to remove it both failed, and are recorded because they looked
obviously right.** A second, fast (512 ms) loss window driving raises only —
reaction ~1.5 s → ~0.9 s — moved the deficit from +0.21 to **+0.25** pp. And
flooring the ladder at n=1, so isolated loss is repaired with *zero* reaction
time, gave **+0.17 pp** while costing 0.035 Mbps more: no measurable gain for a
third of the byte win. Reaction time was never the binding constraint. The fast
window is kept (it is free and it is the right shape); the floor stays at 0.

¹ **That 1.9% was a lucky single run.** Eight interleaved runs at 10% loss put
it at 4.5–6.0%. It is left in the table above because it is what the diagnosis
was made from, and because concealment at a fixed loss rate has a run-to-run
spread wide enough to invent findings — see `below-the-ceiling-rate-cuts-buy-nothing`.

#### The rungs were right for a group size we do not use

The ladder above picks its rungs by **group-failure rate** — smallest n with
`P(Bin(K+n, p) > n)` near 1%. That criterion is wrong, and wrong in a way that
is invisible until you change K: it counts a failed group of 5 exactly like a
failed group of 10, when the first conceals half as much speech. Weighted by
group size the right criterion is *expected concealed frames per frame*, and
re-deriving on that basis moves the K=10 rungs:

| | n=1 up to | n=2 up to | n=3 up to |
|---|---:|---:|---:|
| shipped (hand-tuned) | 1.5% | 4.0% | — |
| correct for K=10 | **1.02%** | **2.78%** | 5.03% |
| correct for K=5 | 1.43% | 4.21% | 7.76% |

**The shipped pair is the K=5 ladder, running on a K=10 codec.** At the top of
its n=1 rung concealment is 0.21 per 100 against a 0.1 target (2.1× over); at
the top of n=2 it is 0.28 (2.8× over). Avoidable concealment **0.19 pp at
p=1.5% and 0.23 pp at p=4%** — small, but paid in exactly the band where a link
is nearly good and a listener is not expecting artefacts.

`pcm.js` now derives `rungTop[]` from `RS_K` at stream start (~40 binomial
evaluations per rung, once per call) instead of carrying constants, so the
ladder stays correct if the span ever moves. `testbed/kchoice.mjs` prints the
same table and holds the target: **0.1 concealed frames per 100**, one 8 ms
frame per 10 s. The in-app derivation is checked against it at K=5, 6, 8, 10,
12 and 16, along with monotonicity, `clean → n=0`, saturation at `RS_P`, and
that K=5 reproduces the old 1.5/4 exactly.

**The same error nearly cost a 20-minute A/B.** Group-failure rate made K=6 n=2
look like a bargain — 3.8% against the shipped 3.4%, at a 48 ms span instead of
80. Weighted properly it is 1.50 vs 1.11 concealed per 100, i.e. **35% worse**.
Three reps measured **+0.60 pp** against the model's predicted +0.39: right
sign, right size, dominated config. Run `kchoice.mjs` before running the rig.

### Over half the repairs arrive too late to play, and it is the span

Not shipped — `?pcmrsk=` is a test flag and the default is unchanged at K=10.
Recorded because the mechanism is confirmed and the lead is strong.

`fecRepairedLate` (161–224) had grown to rival `fecRepaired` (161–478): a third
of all successful RS decodes were being thrown away because the playhead had
already passed. Parity cannot be computed until its group CLOSES, so the frame
at position 0 waits `RS_K × 8` = **80 ms** before its repair exists, while
position 9 waits 8 ms. That predicts a monotonic gradient, and there is one —
both directions, 10% loss, % of repairs discarded as late:

| position | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| A | 63 | 69 | 58 | 47 | 48 | 29 | 26 | 13 | 4 | **0** |
| B | 69 | 59 | 55 | 48 | 39 | 33 | 23 | 18 | 3 | **0** |

Mean deficit 29 ms, max 72 ms. Halving the span (K=5, n≤2) halves the waste:

| | K=5, 40 ms span | K=10, 80 ms span |
|---|---:|---:|
| repairs discarded as late | **15%** | 34% |
| worst position | 32% | 69% |
| mean / max late | 16 / 32 ms | 29 / 72 ms |
| **jitter buffer depth** | **56–58 ms** | 104–109 ms |
| conceal | 4.1–4.2% | 5.5–6.1% |
| lane | 1.010 Mbps | 0.925 Mbps |

**The buffer depth is the interesting number, not the concealment.** The
measured jitter target sizes itself from observed arrival spread, and repaired
frames are part of that spread — so an 80 ms RS span was inflating our own
playout latency by ~48 ms under loss. The span is not only a repair-deadline
term, it is a *latency* term, which was not how it was designed.

#### The span appears one-for-one in the measured arrival spread

The per-5 s columns of `fatigue.mjs` show the mechanism directly, and it is
almost exactly the span. Settled values during the 30 s burst:

| during 10% loss | K=5 (40 ms span) | K=10 (80 ms span) |
|---|---:|---:|
| **jitter p99 arrival spread** | **~49 ms** | ~91 ms |
| target the estimator asks for | 7–8 frames (56–64 ms) | 12–14 frames (96–112 ms) |
| depth actually achieved by t=50 | 68 / 65 ms | 66 / 72 ms |
| concealment events, whole burst | **324** | 547 |
| late frames, whole burst | **117** | 370 |

The spread is `span + ~10 ms` in both arms — the estimator is measuring the RS
span and nothing else is that size. The target follows the spread exactly.

**Why the gap proxy could not see it.** `gapAdded = 2 × (ageP50 + depth)` uses
*achieved* depth, and under loss depth is set by the ratchet, not by the target
— it climbed 20→68 (K=5) and 16→66 (K=10) over the same 30 s, two curves within
a few ms of each other. Neither arm reached its target inside a 30 s burst: K=10
asks for 104 ms and gets 66, so it pays for latency it never receives *and*
conceals 68% more late frames anyway. The 40 s sustained-loss `competitor.mjs`
runs do reach steady state, which is why depth there differs 56 vs 104 ms while
here it differs by ~2. **The 12 ms gap movement was correct, not anomalous** —
it is what a 2 ms depth difference produces. The effect lives in the quality
columns, not in the depth column.

Two details the summary line hides:

- **K=10's real peak is 249 ms at t=55 — five seconds *after* the loss stops.**
  The harness reports 227 ms because its peak window closes at the loss
  boundary. K=5 peaks at 218 ms at t=50 and is already down to 190 by t=55. The
  deeper-target arm keeps inflating past the end of its own cause, which is
  precisely the shape in `latency-that-does-not-come-back`.
- **The clean-baseline "regression" is one frame.** K=5's clean depth alternates
  22 / 13 / 20 / 12 / 20 ms — an 8 ms flip, exactly `FRAME_MS`, doubled to ~17 ms
  by the 2× in the proxy. It is the buffer quantising between holding 2 and 3
  frames, which is the floor of what this buffer can express, not a latency
  cost. K=10 happened to sit steadily on one side of the same boundary.

**Why it is still not shipped.** One endpoint remains unresolved and one
blocker is structural:

- concealment −1.41 pp but **t = −1.80** over 4+4 interleaved reps — the
  quality columns above say the effect is real and large, but the A/B has not
  yet resolved it at the 2.5 bar.
- K=5 costs **+9% lane** under loss (1.010 vs 0.925 Mbps) for its 40 ms span.
  K=6 n=2 is the better trade — binomial group failure 3.8% vs K=10 n=3's 3.4%,
  so equal correction strength, at a 48 ms span for only +3 pp redundancy.
- Unlike the code rate, **both peers must agree on RS_K** — the receiver derives
  groups from `seq % RS_K`, so a mismatch does not degrade, it groups different
  frames together. That needs a migration story before it can be a default.

`setRsK()` rebuilds the Cauchy matrix and is verified bit-exact at K=5, 8, 10
and 16 over 800 groups, with junk inputs leaving RS_K at its default.

#### K=5 n=3: the audio win is real and it is paid for in video

The model's optimum, measured at n=8/arm, 10% loss, **uncapped link**:

| | K=5 n=3 (40 ms) | K=10 n=3 (shipped) | |
|---|---:|---:|---|
| audio conceal | **2.97 ± 0.79%** | 5.61 ± 0.91% | −2.64 pp, **t = −6.21** |
| video delivered | 89.8 ± 1.1% | **91.3 ± 1.1%** | −1.54 pp, **t = −2.73** |
| latency p50 | 66.2 ± 4.6 ms | 64.8 ± 4.9 | t = 0.57, nothing |
| audio lane | 1.140 Mbps | **0.925** | +23%, exact |

Concealment beat its prediction (−2.64 against −2.26 = span −1.41 + coding
−0.85), which is the strongest confirmation the span mechanism has. **But
delivery moved significantly the other way, and delivery is video** — `cov` is
the fraction of sent video timecode units seen at the far end. This is the
`latency-needs-a-delivery-column` trap in a new costume: the audio lane looks
excellent precisely while it is taking something from the other lane.

**The dose-response is clean.** At n=2 (+9% lane) delivery was *better*, +1.48
pp at t = 1.55; at n=3 (+23% lane) it is −1.54 pp at t = −2.73. More audio
parity, less video delivered.

**What the mechanism is NOT.** There was no `--bw` cap in this run, so the
video loss is not link-bandwidth competition — the extra audio bytes were free.
Encode cost is identical too: 3 parity accumulations per frame at either K
(3 rows × 5 members per 5 frames == 3 rows × 10 members per 10 frames). What
does differ is the **parity packet rate**: 0.6 per frame at K=5 n=3 against 0.3
at K=10 n=3. Per-packet send overhead, or the emulator's own per-packet cost,
are both live candidates and neither is established. Until it is, the honest
statement is that the audio win costs video delivery for a reason we have not
yet isolated — and an uncapped link *understates* it, because a shaped one adds
real competition on top (`loopback-hides-what-the-lanes-are-for`).

#### K=5 n=2 on a shaped link, and the span effect doubles

The candidate operating point — span win at +9% lane instead of +23% — at
n=8/arm, 10% loss with `--bw=2.5`. (That cap binds only on bursts, max 30 ms of
queue and no drops; it is much lighter than the flag implies — see the
correction below.)

| | K=5 n=2 (40 ms) | K=10 n=3 (shipped) | |
|---|---:|---:|---|
| audio conceal | **3.26 ± 0.73%** | 6.53 ± 0.38% | −3.27 pp, **t = −11.03** |
| video delivered | **91.4 ± 1.1%** | 90.6 ± 1.7% | +0.76 pp, t = 1.01 |
| latency p50 | 65.2 ± 2.4 ms | 64.2 ± 4.8 | t = 0.48, nothing |
| audio lane | 1.010 Mbps | **0.925** | +9%, exact |

**Every K=5 rep (2.35–4.60%) beat every K=10 rep (5.90–7.05%)** across 15 runs —
the distributions do not overlap at all, which is a stronger statement than the
t. Delivery does not regress; its sign favours K=5. (One K=10 rep was dropped as
`NO RESULT`, so that arm is n=7. Welch handles the unequal n.)

**Correction: the shaping was far lighter than "`--bw=2.5`" suggests.**
`bwDropped` counts only queue *overflow*, so it reads 0 both on a link that
queues constantly and on one that never shaped — it cannot tell them apart.
Queue delay can. Measured at `--bw=2.5`: 31,883 packets took the queue path but
**p50 0 ms, p95 0 ms, max 30.2 ms**, zero drops. The cap binds on occasional
bursts; the *sustained* rate never approaches it, at any cap tried (`--bw=1.0`
gives max 97.9 ms and 11 drops; `--bw=0.8` gives max 97.8 ms and 28 drops, still
p95 0).

So the earlier claim that "the span effect doubles once the link has a queue"
is **withdrawn**. The two runs differ in more than one way — the second added
light burst shaping *and* its control arm drifted — so the doubling cannot be
attributed to either. The pacing hypothesis (K=10 bursts 3 parity packets every
80 ms; K=5 sends 2 every 40 ms) remains untested, not supported.

`competitor.mjs` now prints `bwQueue: queued N pkts / p50 / p95 / max` on every
run, warns `shaper NEVER BOUND` when max < 5 ms, and otherwise says explicitly
when the cap binds in bursts only — because "I passed `--bw`" is a claim about
the knob, not about the condition under test.

**What actually differs between the two runs is the CONTROL arm.** K=5 n=2
measured 3.45% then 3.26% — stable. K=10 n=3 measured 4.86% then 6.53%. The
control drifts 4.9–6.5% at nominally identical settings, which is the whole
gap. Interleaving makes each run's *comparison* valid; it does not make the
absolute levels comparable across sessions. Read the ratio rather than the
difference: K=5's concealment is 0.71, 0.50 and 0.53 of K=10's across the three
runs — consistently about half, with a difference that looks like it moved.

**At K=5, the third parity buys nothing measurable.** K=5 n=3 vs K=5 n=2,
n=8/arm, same conditions: concealment 3.31 ± 0.87 vs 3.67 ± 1.17, difference
−0.36 pp at **t = −0.69 — not distinguishable**, though the model predicted
−0.88. Delivery came out +1.37 pp in n=3's favour at t = 2.72. Rig clean in
both arms (`bwDropped 0.00%`, `sendErrors 0.00%`).

**Do not act on that delivery number.** `cov` has now produced two significant
results in opposite directions for changes of the same sign: K=5 n=3 delivered
*worse* than K=10 n=3 (−1.54, t = −2.73) and *better* than K=5 n=2 (+1.37,
t = 2.72) — the latter meaning more audio parity delivered more video, which has
no mechanism. Its per-rep spread is 1.1–1.7 pp, the same size as the effects
being claimed. Treat ~1 pp `cov` differences as noise until the metric earns
back its credibility.

So the honest reading is that **n=2 and n=3 are indistinguishable at K=5**, and
n=2 is preferable for costing 0.13 Mbps less. The derived ladder picks n=3 at
10% loss; on this evidence that costs bytes for no gain, which is a second
reason the ladder needs a cost term and not only a concealment target.

**The shippable operating point is K=5 n=2, and it is gated on peer agreement**
rather than further measurement: the receiver derives groups from `seq % RS_K`,
so a rolling deploy putting a K=5 sender against a K=10 receiver would corrupt
grouping outright rather than degrade.

#### On a genuinely constrained link the win reverses, and K=5 is dead

`--bw=0.3` is what actually constrains this app (p95 58.7 ms of queue, 0.68%
overflow) — see the per-source-port caveat below for why the number is so small.
n=8/arm, 10% loss:

| | K=5 n=2 | K=10 n=3 (shipped) | |
|---|---:|---:|---|
| latency p50 | 99.0 ± 6.5 ms | **83.1 ± 6.6** | **+15.9 ms, t = 4.83 WORSE** |
| video delivered | 68.1 ± 6.6% | **74.6 ± 5.6** | −6.49 pp, t = −2.13 |
| audio conceal | 11.96 ± 3.43% | 12.17 ± 3.22% | −0.21, **t = −0.12, gone** |
| audio lane | 1.008 Mbps | **0.925** | +9%, exact |
| rig `bwDropped` | 0.83 ± 0.06% | **0.55 ± 0.17%** | K=5 overflows more |

**The concealment advantage is an artifact of free bandwidth.** Where the link
has slack, K=5's shorter span halves concealment; where it does not, the same
configuration returns nothing and charges 16 ms of latency for it. The rig
counters name the mechanism directly: K=5 offers 9% more and drives 50% more
queue overflow (0.83% vs 0.55%), so its own parity is what pushes the shaper
past its limit — and everything behind that queue, video included, waits.

**K=5 is therefore not shippable at any n**, and the block-size line of work is
closed. This is not a null result: it says the span mechanism is real but cannot
be bought with redundancy, because redundancy is exactly what a constrained link
has none of. The way to get a short repair delay *without* spending rate is to
stop tying repair delay to block size at all — a sliding-window streaming code
emits parity every frame covering the last W, so the first repair for a frame
arrives ~1 frame later instead of up to K, at whatever rate you choose. That is
now the only remaining path, not a nice-to-have.

**Why every earlier run flattered K=5.** The netsim's bucket is keyed on
`address:port`, i.e. one bucket per SOURCE PORT rather than per client. That was
the same thing when the app had one peer connection; Lane A now stripes across 6
data-channel PCs plus the media PC, so each browser draws ~7 buckets and the
effective ceiling is ~7× the flag. Three A/Bs ran at `--bw=2.5` believing the
lanes competed for 2.5 Mbps — they competed for ~17. The defect appeared
silently when `pcmpairs` went 3 → 6.

### Two instruments that lied, both caught by their own counters

**The dispatcher ate every loss report.** `onMessage` opened with
`data.byteLength < 9` — correct when the smallest type was a 9-B ping, fatal for
a 2-B report. The first deployed build printed `fecN 3/3, up 0, down 0`, which
is *exactly* what a link that never needed to adapt looks like. It was caught
only because `lossPct` (what this side measured) and `peerLossPct` (what the far
end told us) are separate counters: `lossPct 0` with `peerLossPct null` says the
send side worked and nothing arrived. One combined counter would have shipped a
dead ladder that measured as a healthy one.

**`ab.mjs` scored the strongest possible result as no result.** Welch's t is
`diff / se`, and the harness computed `se > 0 ? diff/se : 0` — so a 0.195 Mbps
difference with *zero* variance in both arms printed `t = 0.00, not
distinguishable — do not claim a winner`. Zero pooled error is not absence of
signal; it is a quantity that is derived rather than sampled, and every rep of
each arm returning the identical number is the most repeatable finding the rig
can produce. It now says so instead.

## The 1-in-8 collapse was a shed the peer was never told to end

Fixed and deployed. This is the intermittent whole-call failure that had been
open all session: roughly one run in eight, one direction of the call would
mostly stop — one side's presenter starving (`avPresents 787` against 2348,
`avHolds 5331`), or the far side encoding 776 frames instead of 2900 — and never
recover. Two captures described it; neither could attribute it.

**Cause.** §13's VIDEO HELD is a two-party state: the RECEIVER detects a
sustained deficit and sends `shed`, the SENDER stops admitting captures, and the
hold ends when the receiver sends `resume` and the sender's fresh keyframe
arrives. The exit test at `tape.js:1621` was

```js
if (m.key && m.id > shedMaxId) setRegime('nominal', 'resume keyframe');
```

`shedMaxId` is the receiver's own `lastDecoded`, so *every frame the sender had
already put on the wire when the shed landed* has a larger id and passes. At a
bandwidth ceiling that is up to a second's worth of queued frames. If any of
them was a keyframe, the receiver declared itself nominal **without ever having
sent a resume** — and since `classify()` only calls `exitProbe()` while held, it
would never send one afterwards either. The sender stayed `shedded` for the rest
of the call. Neither side reported an error: the receiver believed it was
nominal, and the sender was doing exactly what it had been asked to do.

The comment above that line already said the exit was "the fresh **post-resume**
keyframe". Post-resume was never checked.

**Why one in eight.** The bug needs a keyframe to be in flight at the instant the
shed lands. Most sheds coincide with deltas only — across the four verification
runs `shedStaleKey` stayed 0 while sheds fired seven times.

**Reproduction.** Not loss — a capacity ceiling. `--bw=4` and `--bw=2.5 --rtt=80`
with `--fixture=camcode720`, which reproduced it twice in one batch, in both
directions:

| | before |
|---|---|
| bw=4 | A `shedSent 1 / resumeSent 0`, held→nominal in 1.2 s on a stale key; B ends `shedded true`, `skipShed 2155`, `framesEncoded 808` |
| bw=2.5 | B `shedSent 1 / resumeSent 0`, exits held in 0.1 s; A shed for the remaining 77 s; `B framesOut 35`; harness got **9 matched samples** in 90 s |

**Fix**, both in `tape.js`:

1. The held-exit now requires `resumeSentAt >= shedAt` — a resume actually sent
   this episode. An in-flight keyframe is counted (`shedStaleKey`) and skipped.
   If we have resumed and only deltas arrive, the post-resume keyframe was lost,
   so `requestKey('post-resume')` asks again (rate-limited by `keyReqMs + RTT`).
2. A sender-side dead-man switch: being shed means our video is off and the only
   thing that turns it back on is a peer message, with no timeout on it. Past
   `stallShedMaxMs` (8 s) the sender resumes itself and lets the classifier
   re-shed if the congestion was real — its 3 s dwell is what stops that
   flapping.

**After**, four runs, both sides on the fix — `shedSent` now always has a
matching `resume`, no side ends `shedded`, and every hold is the 4 s minimum
dwell rather than the 60 s `stallMaxHoldMs` hatch:

| run | A shed/resume | B shed/resume | held | glass-to-glass p50 | cov |
|---|---|---|---|---|---|
| bw=4 | 3 / 5 | 1 / 1 | 4.7 / 4.4 s | 98.0 ms | 80.6% |
| bw=4 | 1 / 1 | 1 / 1 | 4.2 / 4.5 s | 102.7 ms | 77.2% |
| bw=2.5 | 1 / 1 | 3 / 6 | 4.7 s | 166.1 ms | 47.5% |
| bw=2.5 | 0 / 0 | 0 / 0 | — | 120.4 ms | 83.2% |

The bw=2.5 row at 47.5% coverage is a genuinely capacity-limited call, not a
collapse: 1276 matched frames where the same condition previously produced 9.

**The dead-man was demonstrated by accident.** One verification run had A on a
cached pre-fix bundle and B on the fix — the real-world mixed-version case. A
performed the old stale-key exit and stranded B shedded; B recovered itself
(`shedDeadman 1`, `skipShed 240` instead of 2155, `framesEncoded 2619` instead of
808). The interop failure mode is survivable from one side.

**No regression on the normal path**, measured after the fix with the full dump
(loss applied per the `netsim:` line, avsync engaged, PCM lane live):

| | p50 | p95 | delivered | thirds |
|---|---|---|---|---|
| 5% loss, RTT 80 | 72.0 ms | 89.3 ms | 97.1% | 71.4 → 72.4 → 72.0, flat |
| clean | 26.9 ms | 45.0 ms | 98.0% | 26.9 → 27.3 → 26.5, flat |

> These are better than the figures this file previously carried for the same
> conditions (5% loss 79.5/89.9 ms at 81.7–85.0% delivered; clean 59.7 ms), and
> **the improvement is not attributed to the shed fix** — the stall machine never
> engaged in any of these runs (`shedSent 0` on both sides), so it cannot have
> moved the clean path by 33 ms. The likely cause is machine state: glass-to-glass
> carries a CPU-bound presentation term, and here transport `ageP50` was 17.7 ms
> against 26.9 ms end to end (~9 ms of presentation) where the earlier figure
> implies ~40 ms. Run-to-run spread on a quiet machine is ±1.7 ms, so a 33 ms
> gap is a different machine state, not noise. Treat absolute latency as
> comparable only within one quiet session; use the interleaved A/B harness for
> any comparison that matters. The claim being made here is the shed fix, and it
> rests on the shed/resume invariant and the bw=2.5 recovery, not on these.

### A capacity ceiling had never actually been tested

Two instrument faults hid this, and both made a constrained link look healthy:

- `--bw` is in **Mbps**. `--bw=1500` asked for 1500 Mbps. The harness printed
  `bw 1500 Mbps` honestly; the grep that read the result dropped that line.
- With the units right, `--bw=1.5` *still* returned 67.3 ms at 98% coverage —
  because `timecode720` compresses to under 1100 B/frame, so the video lane is
  ~0.26 Mbps and never touches the ceiling. The ceiling was applied and the
  stimulus was too small to feel it.

Nothing in §12/§13 — the stall classifier, lane P, the AIMD governor, all of it
built for constrained links — had ever run under a real constraint. **Any
bandwidth-ceiling run needs `--fixture=camcode720`**, for the same reason loss
and FEC runs do.

Incidental, now measured rather than assumed: lane-P stills are `lpKBmean` ~32 KB
and their arrival age runs 104–229 ms at these ceilings, so the 250 ms resume bar
is reachable. An earlier reading of this file assumed stills were ~80 KB and that
the bar was unsatisfiable under loss; measured, that was wrong, and the forced
shed (`?stallforce=15`) recovers in 4.6–6.1 s at 5% loss and 4.1 s clean.

## The fallback lane is faster than the shipping default

Not acted on. Recorded because it is large, reproducible, and points at the
biggest remaining latency item — and because the deciding variable is one I have
not measured.

Same instrument, same fixtures, same audio, both browsers on one machine, with
`--rtt`/`--loss` putting a real UDP delay line on the media path
(`testbed/competitor.mjs --rtt= --loss=`, mechanism lifted from `call.mjs`):

| condition | lane 2 (default) p50 | lane 1 p50 |
|---|---|---|
| loopback | 24.6 ms | **3.3 ms** |
| RTT 80 ms, 1% loss | 62.6 ms | **45.4 ms** |
| RTT 80 ms, 5% loss | 86.2 ms | 58.4 ms |

Interleaved A/B, n=4 loopback: 22.5 ± 0.9 vs 4.2 ± 1.4 ms, t = 22. n=3 at
RTT 80/1%: 62.8 ± 0.9 vs 47.2 ± 1.5, t = 15.7. Both far outside the ±1.7 ms
run-to-run spread, so this is not noise.

On a clean path lane 2 spends ~21 ms on machinery with no delivery benefit to
show for it there. That is the largest single latency item found so far.

#### Resolved: the fixture was wrong, and the answer is the opposite

The table above is loopback-only and stays. Everything I first wrote about
**delivery under loss** was measured on a fixture that could not support it, and
the corrected measurement reverses the conclusion completely.

`timecode720.y4m` is a near-black field with one small moving bar. It compresses
to a **single 1100-byte fragment per frame** — `fragsSent` equals
`framesEncoded` exactly, 839 and 839, 845 and 845, unchanged when forced to
`qp=10`. Lane 1 gates its XOR parity on `count > 1`, so `paritySent` was 0 in
every run and its loss protection was structurally dead. Delivered fractions
swung 57.8%–87.1% across repeats of one configuration.

`testbed/mktimecode.mjs` rebuilds the pair over real camera footage: same 11-cell
bar, same geometry, same 256 frames, byte-identical file size — only the
background entropy differs. That moves frames to **13.7 fragments each** and
`paritySent` to 1591. Same instrument, same delay line, realistic frames:

| condition | lane 2 (default) | lane 1 |
|---|---|---|
| loopback | 26.1 ms / 100% | **5.6 ms** / 100% |
| RTT 80 ms, 1% loss | **65.3 ms / 100%** | 1638 ms / **12.9%** |
| RTT 80 ms, 5% loss | **114.8 ms / 98.4%** | **no picture at all** |

At 1% loss lane 1 does not degrade, it **collapses**: 160 frames encoded against
lane 2's 904, `skipBuffered` **747** — admission control shedding because the
datachannel is backed up — p95 5.2 seconds. At 5% the rig found no element on the
receiving page carrying the sender's tag; there was no video to measure. This is
SCTP's congestion control doing exactly what `DESIGN.md` §17.6 said it would, and
it is invisible on 1 KB frames because 1 KB frames never fill the buffer.

**So the lane question is closed.** Lane 1's ~20 ms advantage exists only at
*exactly* zero loss — not at Microsoft's "optimal" 0.5% average, let alone their
5% burst. The 17 ms carrier hop is not overhead to be shaved; it is the price of
a transport that still delivers 98.4% at 5% loss, and the alternative at 1% is a
1.6-second slideshow. The shipping default is right, and the earlier "should we
switch?" question was an artifact of a fixture that let one lane cheat.

Two things I got wrong in sequence, both worth keeping: latency-only ranking
made the lossy lane look better, and then a delivery column measured on a fixture
that disabled the other lane's protection made it look better *again*, for a
second and different reason.

#### Under loss, the noise floor is ~10× the loopback one

The ±1.7 ms run-to-run spread that governs every clean-path claim here does not
apply once loss is on. Measured on the realistic fixture at RTT 80 / 5% loss,
n=4 interleaved, unchanged build:

| | p50 | p95 | delivered |
|---|---|---|---|
| default | 66.9 ± 5.7 ms (59–72) | 109.2 ± 30.5 | 98.8 ± 0.8% |
| `l2retx=0` | 71.0 ± 4.9 ms (65.5–77) | 166.5 ± 118.7 | 98.6 ± 1.5% |

t = −1.07: **not distinguishable.** Single runs of the *same* default arm landed
at 98.8 and 114.8 ms in the lever scan and 59–72 ms here. So the loss-condition
spread is roughly **±6 ms on p50 and ±30–120 ms on p95** — an order of magnitude
above loopback, and enough that a one-run-per-arm scan under loss resolves almost
nothing.

That retires a scan I ran across `l2hold`, `l2retxwait`, `l2fec`, `l2retx` at 5%
loss. One arm appeared to beat the default on both latency and delivery at once
(`l2retx=0`: p95 3× better, delivery up); at n=4 it is noise, and its p95 spread
is the widest of any arm measured. **No lever claim under loss from n=1.**

One result does survive, because it is far outside that band: **`l2fec=0` drops
delivery to 76.6% against ~98.8 ± 0.8%.** The FEC is load-bearing at 5% loss —
about 22 points of delivered frames — and that is the clearest evidence yet that
the carrier lane's redundancy is doing real work rather than costing latency for
nothing.

#### Resolved: at p50 there is no loss latency to find

The question "where does lane 2's loss latency go" had a false premise, and the
cheapest possible test found it. `--rtt=80` puts a 40 ms one-way delay line on
the path *without* loss. Three arms, interleaved, n=4 each, realistic fixture,
unchanged build:

| | p50 | p95 | delivered |
|---|---|---|---|
| loopback | 22.0 ± 6.1 ms | 46.0 ± 5.0 | 100.0 ± 0.0% |
| RTT 80, no loss | 66.8 ± 2.7 ms | 84.8 ± 2.9 | 100.0 ± 0.0% |
| RTT 80 + 5% loss | 72.8 ± 8.7 ms (n=3) | 173.4 ± 125.3 | 96.9 ± 1.1% |

Loopback → RTT 80 is **+44.8 ms** against a delay line configured for 40 ms one
way. Adding 5% packet loss on top of that costs **6.0 ± 5.2 ms, t = −1.15 — not
distinguishable from zero.**

So the 67 ms was never a lane cost. It is 22 ms of application plus the
simulated distance, and every lever tried against it was being asked to remove
propagation delay. That is also why the scan looked like noise: it was noise
around a quantity the levers cannot move.

> **Half of this was measured on a truncated sample — corrected below.** The
> propagation finding holds: loopback 21.4 → RTT 80 clean 69.3 ms against a
> 40 ms one-way delay line, and both are flat across a run. But the conclusion
> that *"at the median, 5% loss is free on this lane"* was an artifact. The rig
> was only seeing the first 8.5 s of each run, before the ratchet builds. On the
> full run, loss costs **+12.4 ms** at the median and rising (69.3 → 81.7), and
> delivery is **84.3%**, not 96.9%. See "Latency ratchets under loss".

One loss arm run failed outright and is excluded, so that row is n=3. The
loopback spread here (±6.1 ms) is wider than the ±1.7 ms measured with two arms;
three interleaved arms mean more machine churn, and the means agree (22.0 vs
23.0).

The tail is the only place loss still lands: 101.7 / 318.1 / 100.4 ms against
84.8 ± 2.9 clean — typically ~17 ms of extra p95, with one excursion 233 ms
above clean. `l2FecHoldMs` is 250, which turned out to be the right thread to
pull, though not for the tail.

#### The hold deadline is the frame-loss mechanism, and p50 cannot see it

Going after that tail meant printing the lane's own repair counters next to the
pixel measurement. Six runs at RTT 80 / 5% loss (counters added after rep 2, so
four rows carry them):

| rep | `fecHoldExpired` | `fragReqSent` | `retxSent` | `framesLost` | g2g p50 | g2g p95 |
|---|---|---|---|---|---|---|
| 3 | 7 | 100 | 36 | **58** | 117.8 | 134.2 |
| 4 | 0 | 33 | 35 | 2 | 99.9 | 149 |
| 5 | 0 | 72 | 20 | 0 | 115.1 | 282.1 |
| 6 | **13** | 130 | 48 | **127** | 66.4 | 163.9 |

`fecHoldExpired > 0` coincides with heavy `framesLost` in every row, at ~8–10
frames per expiry — which is precisely what `armHoldDeadline()` does: it adds the
whole outstanding span to `framesLost`, calls `hold.clear()`, and asks for a
keyframe. It fired in two runs of four.

**The latency number is blind to this.** The run that lost 127 frames had the
*best* p50 of the four (66.4 ms). Anyone tuning this lane on p50 would have
picked the worst-delivering build. This is the delivery-column lesson one step
further along: even with a delivery column beside it, the latency column is
survivorship-biased, because a frame the lane never delivered cannot be late.

`fecUnrepairable` is 0 in all six runs, so these gaps are recoverable in
principle — the repair simply runs out of clock. The budget the code sets for
itself is `l2RetxWaitMs + 1 RTT ≤ l2FecHoldMs`: 120 + 80 = 200 against 250, and
the re-splice must still wait for a carrier tick on top of that. Fifty
milliseconds of margin.

One caveat on the "1–3 re-splices per run" design point quoted in that comment:
it predates the realistic fixture, so it may be a low-entropy-fixture artifact
in the same way the first lane-1 delivery numbers were. Treat 33–130 as measured
and the 1–3 as unverified, not as a 40× regression.

#### Every latency number this rig produced covered the first 8.5 seconds

Both fixtures are **256 frames**. Chrome loops them, so the timecode repeats
every ~8.5 s at 30 fps — the wrap period is the fixture loop length, nothing to
do with the 9 bits the stamp reserves for the index. `stats()` keyed its
duplicate check on the raw index, so from the first repeat onward every frame
was discarded as already-seen. Runs asked for 20 or 30 seconds and reported the
first 8.5 of them.

`cov` had the same root: a ratio of two Sets that each saturate at 256, so it
drifted toward 100% however many frames were lost. It reported **99.0%
delivered** on a condition where the lane's own counter said 127 frames were
dumped, and **98%** where the true figure is 84.3%.

Fixed by unwrapping to a monotonic id, with the wrap period derived from the
data rather than assumed — the first version of this fix hardcoded 512 and was
silently inert, because a 255 → 0 step is not a backward jump of more than 256,
and inert looked exactly like working. The rig now prints `timecode: 256-frame
fixture loop, N wraps unwrapped` and flags `wraps 0` on a run longer than the
loop.

What changed on one run at RTT 80 / 5% loss:

| | truncated | corrected |
|---|---|---|
| matched frames | 220 | 528 |
| sampled fps | 12.6 | 26.6 |
| delivered | 98% | 88.9% |
| p50 | 62.3 ms | 144.2 ms |

**Scope.** Only `competitor.mjs` is affected — every glass-to-glass and
`cov` figure it produced. The flip harnesses sample 2–3 s windows (60–90 frames,
far under the 256 cap), so the camera-flip results stand unchanged.

**The clean-path numbers survive.** Loopback measures 21.4 ms corrected against
23.0 ± 1.7 recorded, and is flat across the run, so truncating it to the first
third biased nothing. A/B *comparisons* also survive, because both arms were
truncated identically. What does not survive is any absolute latency or delivery
figure taken **under loss**, for the reason in the next section.

#### Latency ratchets under loss, and does not come back

The corrected rig prints p50 by third of the run. Thirty seconds each:

| condition | first | second | third | delivered |
|---|---|---|---|---|
| loopback | 21.0 | 21.4 | 21.8 ms | 98.2% |
| RTT 80, no loss | 69.7 | 69.4 | 68.8 ms | 97.4% |
| RTT 80 + 5% loss | 66.1 | 81.1 | **97.5 ms** | **84.3%** |

Clean paths are flat — including the 80 ms one, which rules out propagation
delay and the rig itself. Under loss the median climbs **+31.4 ms over 30
seconds**, roughly a millisecond per second, and never recovers within the run.

That is why the truncated sample read 62 ms where the full run reads 144: it was
only ever measuring the freshest part of a call, before the ratchet had built.
The instrument was structurally incapable of seeing the one behaviour the
product most needs to not have.

**It plateaus, and it plateaus high.** A 4-minute run at the same condition
reads 133.9 → 134.1 → 134.2 ms across 80-second thirds: dead flat at ~134 ms.
So the climb completes somewhere between 30 and 80 seconds and then holds. It is
bounded, not runaway — but the steady state is **double the 69 ms clean path**,
and it never returns.

That run was otherwise healthy: `fecHoldExpired 0`, `framesLost 2` out of 7114,
`cov 94%`. So the ratchet is not the hold-deadline failure; it survives runs
where the repair machinery never gives up once.

#### 85% of the loss penalty is presentation, not network

`ageP50` spans post-encode → ready-to-decode, so glass-to-glass minus `ageP50`
is what happens after a frame is decodable. Same condition, same build:

| | transport `ageP50` | glass-to-glass p50 | presentation |
|---|---|---|---|
| RTT 80, clean | 59.3 | 67.6 | **8.3 ms** |
| RTT 80 + 5% loss | 69.2 | 134.1 | **64.9 ms** |

Loss costs the transport +9.9 ms. It costs presentation **+56.6 ms** — 85% of
the whole degradation. Note the clean path's transport age (59.3 ms) is already
almost the entire clean glass-to-glass: the network is doing its job in both
cases.

**Not the v-presenter.** The first suspect was #33's phase anchor: `VP_D_SLOTS =
2` is 66.7 ms, the only thing that removes it is the overflow servo, and
`vpEnqueue()` sets `vpShift = 0` on every late re-anchor — which a FEC hold
produces. The servo state even matched the prediction (clean `shift -3`, loss
`shift 0`).

It is still the wrong path. The same dump says `presents: 16` on the clean run
and `presents: 2` under loss, over **90 seconds** — where 30 fps would be ~2700.
`vpTick()` returns immediately on `avEngaged`, so once A/V sync engages the
v-presenter is dormant and its counters describe a few startup frames. A servo
reading taken from it is a reading of nothing.

Worth keeping as a method note: the `shift` numbers were *consistent with the
hypothesis* and would have justified a change to code that presents 16 frames a
minute. What killed it was a counter nobody was interested in — `presents` —
sitting in the same line. Print the volume next to the ratio.

#### It is the audio playout buffer, and video is being towed by it

There is no browser jitter buffer involved: audio rides our own PCM lane over
SCTP, and `getStats()` cannot see it. The buffer that grows is ours. Same
condition, 90 s, from `window.__tape.pcm`:

| | `targetFrames` | `depthMs` | `painEvents` | `concealedMs` | `avOffP50` | g2g p50 |
|---|---|---|---|---|---|---|
| RTT 80, clean | 15 (120 ms) | **12.4** | 16 | 8 | **−33.1** | 65.2 |
| RTT 80 + 5% loss | 15 (120 ms) | **135.2** | 5067 | **37344** | **+25.1** | 120.1 |

The *target* is pinned at its 120 ms ceiling in both, so the target is not the
variable — the **actual depth** is, 12.4 → 135.2 ms. The applied A/V offset
swings 58 ms across the same interval, tracking the video ratchet closely. Video
is paced to that playhead, so it is towed.

The growth is earned. `concealedMs 37344` over a 90-second call means **41% of
the audio is concealed** at 5% loss, and a deep buffer is the correct response to
that. The defect is not the audio buffer; it is video following it down.

Two things worth separating out. First, `painEvents 16` and a target pinned at
the 120 ms ceiling on a **zero-loss** link says the pain detector fires
spuriously — harmless today because actual depth stays at 12.4 ms, but it means
the target carries no information. Second, 41% concealment on its own
disqualifies any "lossless audio" claim under loss, independently of latency.

`?avsync=0` is not the answer: it removes 17.6 ms and about a third of the
ratchet (+51.7 → +33.4), but p95 gets worse (149.7 → 181) and the inter-frame
spread more than triples (18.8 → 67.7). Unhooking video from audio buys freshness
by paying in cadence, and cadence is what the #33 work existed to protect.

The lever that does work is the **asymmetry of lip-sync perception**. ITU-R
BT.1359 puts the detectability threshold at roughly 45 ms for audio *ahead* of
video but ~125 ms for audio *behind* it. The offset budget is clamped to [0, 45]
in both directions, so a large band the eye cannot see is going unspent.
Measured at `?avoff=45`, one run: the ratchet disappears entirely (110.2 → 111 →
110.9), steady state improves 24.6 ms, p95 improves to 126.7, spread halves to
15.9, and delivery rises to 93.6%.

At n=3 per arm the win is real but smaller than that one run implied. Settled
latency — the last third, which is what a call feels like after the first minute:

| | rep1 | rep2 | rep3 | mean |
|---|---|---|---|---|
| default (avoff 20) | 131.1 | 141.6 | 127.7 | **133.5 ± 7.2** |
| `avoff=45` | 116.6 | 105.3 | 102.9 | **108.3 ± 7.3** |

Difference 25.2 ms, **t = 4.26 — distinguishable.**

Three things from the single run did not survive the repeat, and the discipline
that caught them is the same one as everywhere else in this file:

- **The reverse-direction collapse was a bad run.** All six runs show 2400–2650
  presents on both sides. Retired.
- **The ratchet is reduced, not eliminated.** `avoff=45` still climbs +15 to
  +33 ms. The flat 110.2 → 111 → 110.9 was luck.
- **Delivery is unchanged**, 89.3% vs 88.9%. The 93.6% was noise. So is the
  p95/smoothness improvement — both arms are high-variance there.

The sign works out in the direction that matters. At `avoff=45` video leads
audio by 50–60 ms (applied p50 49.2–55.3), well inside BT.1359's ~125 ms
threshold for audio *behind* video. Meanwhile the clean path at today's default
sits at **−33 ms** — audio *ahead* of video, against a much tighter ~45 ms
threshold in that direction. So the current default is the one closer to a
perceptible error, on the sensitive side, and raising the offset should improve
clean-path sync as well as lossy latency. Clean-path regression check pending
before this becomes the default.

#### The ratchet is the clamp, and spending the band removes it entirely

Raising the offset ceiling (default still 45; `?avoff=` reaches 110 as of
`7a2e379d`) settles it. n=3 per arm, RTT 80 / 5% loss, 90 s runs:

| | settled p50 | thirds | delivered | p95 |
|---|---|---|---|---|
| `avoff=45` | 110.8 | ratchets +17 to +33 | 89.4% | 120 |
| **`avoff=90`** | **68.6 ± 4.4** | 66.4→67.1→66.8 · 64.7→64.8→65.3 · 73.3→73.4→73.6 | 85.6% | 113 |

All three runs dead flat. **68.6 ms at 5% loss against ~65 ms on a clean link:
packet loss costs about 3 ms.** The ratchet does not exist at this setting.

That confirms the mechanism end to end. The audio playhead deepens ~123 ms under
loss, video is paced to it, and the [0, 45] clamp forbade covering more than a
third of the tow. The residual +33 ms measured so consistently because it was
simply the uncovered remainder — which is also why `l2hold=400` could eliminate
hold expiries and move nothing.

**But 90 overshoots.** A head-to-head at n=3 puts the optimum at **70**:

| | settled p50 | delivered | p95 | fps |
|---|---|---|---|---|
| `avoff=45` | 110.8 | 89.4% | 120 | 26.8 |
| **`avoff=70` (shipped, `8d4812c0`)** | **77.2 ± 0.7** | **87.6%** | **115** | 26.2 |
| `avoff=90` | 68.6 ± 1.1 | 82.1% | 135 | 24.5 |

70 takes **33.6 ms off the old default for 1.8 points of delivery, and improves
p95**. Going on to 90 buys 8.6 ms more at a cost of 5.5 further points and 20 ms
of p95 — presenting that early makes marginally-late frames miss their slot and
`avSkips` climbs. Both 70 and 90 remove the ratchet completely; 70's settled
numbers (76.6 / 77.1 / 78.0, sd 0.7) are the tightest measured in this file.

Applied offset at 70 lands ~70–80 ms, comfortably inside BT.1359's ~125 ms
threshold for audio behind video.

**Unexplained, and independent of this change:** one `avoff=45` run collapsed
outright — 25.4% delivered, 787 presents against ~2700, p95 600 ms. That is the
second such collapse observed today, about one run in eight, on different arms
each time. It is excluded from the table above and is its own open defect.

#### Our loss stack beats the browser's, measured

The app still contains the stock path (`?tape=0`, plain WebRTC video), so the
architecture bet is directly testable on the identical rig. RTT 80 / 5% loss,
90 s runs, n=2 per arm:

| | settled p50 | p95 | fps | delivered | ratchet |
|---|---|---|---|---|---|
| ours (live, `21e42360`) | **108.1 ms** | 112.5 / 223.3 | **24.9** | **83.2%** | +45.5 / flat |
| stock WebRTC (`tape=0`) | 132.5 ms | 166.4 / 166.9 | 18.7 | 62.4% | flat |

**24 ms faster, a third more frames per second, and 21 points more frames
delivered.** Stock falls to 57.2% delivery in one run. This is the clearest
evidence yet that replacing the browser's media pipeline was the right call: the
custom lane is not merely competitive with libwebrtc's loss handling, it is
substantially ahead of it on the condition it was built for.

It also corrects a judgement recorded earlier in this session. Faced with the
ratchet, the recommendation was to prune back and hand loss handling to WebRTC
on the grounds that it carries fifteen years of tuning. That was reasoning from
plausibility, not measurement, and the measurement says the opposite.

**The one axis stock wins is predictability.** Its numbers are dead flat —
133.6/133.1/133.5 and 131.7/131.3/131.4 — with a p95 of 166 ms in both runs.
Ours is better on level and worse on variance: still ratcheting in one run of
two, p95 swinging 112 to 223. Stock buys its stability by simply being slow
enough that jitter never threatens the schedule. Closing the variance gap
without giving back the 24 ms is the remaining work.

#### ageP95 was measuring clock skew, not latency

The instrument built for the attribution above was wrong, and said so loudly:
rep 1 reported `ageP95 637.3` on a call whose glass-to-glass p95 was `79.7`. A
part cannot exceed the whole.

Cause: both lanes computed `now() - (wall + (stats.clockOffsetMs ?? 0))`.
`clockOffsetMs` starts `null`, so until the first ctl ping lands the `?? 0`
subtracted the *peer's* `performance.now()` origin from ours — two unrelated
zero points — and pushed the result into the same 900-deep window the percentile
runs over. At ~30 fps a 900-sample window is ~30 s, i.e. the entire run, so the
startup garbage never aged out. It sat just above the 95th percentile and left
`ageP50` looking perfectly reasonable.

A third age site in the same file already had the guard (`if
(stats.clockOffsetMs != null)`), so the codebase disagreed with itself. Fixed in
both lanes; the AIMD rate controller was being fed the same skew-derived samples
and now waits for a clock too. `delTs` is pure cadence and still takes every
frame.

Every `ageP50`/`ageP95` figure recorded before version `81e57018` is void.
`ageP50` was approximately right by luck — the corruption was under 5% of
samples, so it landed above the median and below the tail.

The original withdrawal notice follows, because the reasoning is the useful part.

#### Why the first delivery numbers were void

They read: 100% vs 98.8% at 1% loss, 100% vs 87.1% at 5%, and concluded the
crossover sat between the two. **The fixture could not support that comparison.**

Lane 1 emits XOR parity only for frames longer than one 1100-byte fragment
(`gs > 0 && count > 1`). On the timecode fixture `fragsSent` equals
`framesEncoded` exactly — 839 and 839, 845 and 845 — so **every frame is a
single fragment and lane 1's FEC can never fire**. `paritySent` was 0 in every
run. Forcing `qp=10` to inflate the frames did not change it: a near-black field
with one small moving bar compresses under 1100 bytes at any quality.

So the loss arm measured lane 1 with its protection structurally disabled, in a
regime where one lost packet destroys a whole frame. Recovery fell back to
keyframe requests — 29 to 40 of them in 18 s, against **zero** for lane 2 — and
the delivered fraction swung between **57.8% and 87.1% across five runs of the
identical configuration**. That spread alone disqualifies the single 87.1% I
quoted.

Lane 2 was unaffected because its FEC protects whole substituted carrier frames
rather than fragments, so frame size does not gate it: `fecRepaired 20`, zero
keyframe requests. The two schemes have genuinely different granularity — but
how much that is worth is **not measured**, and nothing here says what a real
27 KB, 25-fragment camera frame would do.

**What it took.** `testbed/mktimecode.mjs` — the same 11-cell bar over
`cam720.mjpeg`, both source tags from one decode pass. Built and measured; see
above. Use `--fixture=camcode720` for anything touching fragmentation, FEC or
loss, and the default `timecode720` for clean-path latency, where frame size does
not matter.

This is the same trap as the starved-camera fixture: the stimulus, not the code
under test, set the result.

**What the real loss envelope is, since it decides the question.** Not mine to
measure from one machine, but Microsoft publishes thresholds for Teams/Skype
real-time media, assessed at the 90th percentile of samples taken every 10
minutes for at least a week: **average packet loss < 0.5% optimal, > 10% poor;
maximum packet loss < 5% optimal, > 25% poor** (RTT < 60 ms optimal, jitter
< 3 ms). PingER corroborates the average — 0.5% within the US, Asia and Europe,
1.4% between continents. So the regime that matters is roughly 0.5% sustained
with bursts to 5%, which is exactly the range the withdrawn table straddled.
That is the target for the re-measurement, not a result.

**Delivery had to be added to the instrument at all.** Latency alone ranks a lane
that drops an eighth of the frames and shows the rest promptly *above* one that
shows all of them. Coverage is distinct received frame indices over distinct sent
indices across the window the receiver was up for; both sides are sampled by the
same rAF-limited loop, so the absolute counts are sampler-capped and meaningless
but their ratio is not. It is what exposed the fixture problem two runs later.

### Where the 17 ms goes: the carrier trick itself

Nine optional components were switched off one at a time against the same
default. Not one of them is where the time goes:

| lever | p50 | vs default 21.6 |
|---|---:|---:|
| `avoff=0` (drop the 20 ms A/V offset) | 24.9 | — |
| `avsync=0` | 62.9 | **+41** |
| `vprev=0` (presentation scheduler) | 23.6 | — |
| `sendnow=1` | 20.4 | — |
| `l2fec=0` | 22.6 | — |
| `l2retx=0` | 24.4 | — |
| `l2pace=0` | 23.7 | — |
| `l2rc=0` | 22.4 | — |
| `l2canvas=0` | 21.9 | — |

The scan is n=1 per arm against a ±1.7 ms spread, so it resolves nothing below
about 4 ms — it cannot rule out several small costs, only one large one. I was
looking for ~17 ms and nothing came close. `sendnow=1`, the one arm that pointed
the right way, was then run properly and is a null: 22.0 vs 22.2 ms, t = 0.16
(n=4 interleaved).

**A hypothesis that died on contact.** `AV_OFFSET` defaults to 20 ms and applies
only when `wantTape === 2`, so it looked like the whole gap. Setting it to zero
does not help, and turning A/V sync off entirely costs **41 ms** — so the sync
machinery is pulling video *forward* to meet audio, not delaying it. Whatever
else it is, it is not a latency tax.

**Where the time actually is.** Both lanes stamp `wall` in `onEncoded` and
compute frame age against the synced clock at reassembly, so `ageP50` spans
post-encode → ready-to-decode: the transport stage, excluding capture, encode
and decode, which are common to both.

| | transport age p50 | glass-to-glass |
|---|---:|---:|
| lane 2 | **17.2 ms** | 21.6 ms |
| lane 1 | **−0.1 ms** | 3.3 ms |

Clock RTT 0.2 / 1.19 ms, offsets ~0.25 ms, so the sync bias here is well under a
millisecond. The transport difference is 17.3 ms and the glass-to-glass
difference is 18.3 ms — two independent instruments agreeing within ~1 ms.

So the entire disadvantage is the hop between the encoder's output and a frame
being ready to decode: main→worker, wait for a carrier tick, splice, libwebrtc's
pacer, the wire, the depacketizer, the receive transform, worker→main. That hop
is not a setting on lane 2. It **is** lane 2 — the price of the carrier trick,
and the reason the trick buys real RTP pacing and FEC in the first place.

Which means the honest statement of the latency floor is architectural, not
physical: on a clean path lane 2's floor is ~17 ms of carrier and worker hops,
not the speed of light. Three ways out, none of them free:

1. **Raise the tick rate above 60/s.** The mean wait is half a tick, so ~8 ms
   would become ~4 ms. Probably blocked: `captureStream` is driven by the
   compositor, the dirty-marking flicker runs on a 16 ms interval, and a 60 Hz
   display is unlikely to emit more than 60 frames/s however many are asked for.
   Untested — listed so the next person tests it rather than assumes it.
2. **Drop the carrier**, and accept lane 1's delivery under loss.
3. **Pick the lane from measured loss.**

All three need the real-world loss rate that is still unmeasured, and 1 needs a
display that can prove it.

A fifth instrument-vs-app bug, caught before it produced a number: passing
`--rtt=80 --loss=5` through an unquoted **zsh** variable arrives as one argv
entry, `Number("80 --loss=5")` is NaN, `NaN > 0` is false, and the simulator
silently does not start. The first matrix run reported clean loopback latencies
under headings that said 80 ms and 5% loss. The flags are now NaN-hostile — an
unparseable one exits rather than defaulting to zero — and every simulated run
prints its rewritten-candidate count and aborts if either side is zero.

## Audio

| | measured | method |
|---|---:|---|
| format | 48 kHz / 24-bit linear PCM, losslessly compressed, no lossy codec | by construction |
| wire size, one frame | **709–714 B** data / 1160 B parity | sender byte counters (`bPerFrame`) |
| lane rate | **1.06 Mbps** (was 1.50) | `mbpsSent`, both sides |
| compression, speech | **0.56** of raw, bit-exact | 6,851 frames compared sample by sample |
| delivery at `pcmpairs=3`, RTT 80 / 1% loss | **99.3%** of frames | lane counters |
| concealed | 4.4% | worklet counters |
| transit age, p50 | 40.5 ms | stamped at arrival |
| queue depth, steady state | ~17 ms | worklet playhead |
| **mouth-to-ear ≈ transit + queue** | **~57 ms** | the two are additive; reading either alone understates it |
| recovery after a 30 s burst at 3% loss | **59 s** to baseline (previously: not within 160 s) | mid-call `setLoss()`, three-phase run |

Under **loss**, the figures above are governed by the three fixes of 2026-08-03 —
compact framing, stripe width, and lossless compression. Shipped defaults:
5% loss concealed **2.1%**, 10% loss concealed **3.5–5.7%**, clean path **0.0%**
and bit-exact. Before any of them, at `pcmpairs=3` with the 1176 B frame, those
were 36–41% and 60–76%. See "Audio under loss" above for the method and the grid.

**Lossless compression** (`core/pcmpack.js`, `?pcmz=0` is the control arm) is
FLAC's core: fixed-order linear prediction, partitioned Rice, warm-up literals,
and a verbatim escape bounding the payload at 1153 B so the worst frame stays
inside the datagram budget. Measured against its own control, 60 s per arm:

| | zip off | zip on |
|---|---:|---:|
| bytes per data frame | 1157 | **709–714** |
| lane rate | 1.50 Mbps | **1.06 Mbps** |
| conceal, 0% loss | 0.0% | 0.0% |
| conceal, 5% loss | 3.2 / 1.5% | 2.1 / 2.1% |
| conceal, 10% loss | 8.2 / 8.1% | **5.7 / 3.5%** |
| `fecFailed`, 10% loss | 939 / 1035 | 672 / 373 |

Ratios by content: speech 0.557, natural sound 0.675, tonal 0.620, white noise
0.957. White noise is incompressible by construction (lag-1 autocorrelation
0.001) and is the floor, not a failure. The ratio does **not** depend on the
source being genuinely 24-bit — dithering the low 8 bits moves it <0.3%, because
Rice already spends its low k bits verbatim. Encode costs 25 µs/frame, 0.32% of
one core at 125 fps. Computed LPC was measured and rejected: at 384 samples the
coefficients cost more than they save, so the simpler codec is also the better
one. `avDrops 0` in every arm and glass-to-glass 64–67 ms throughout.

**Group-sized RS symbols** (live `45b344fe`, `?pcmrsfixed=1` is the control arm)
close the gap that compression opened. Parity had become the lane's largest
single term — 32% of all bytes — because the RS symbol stayed a fixed 1152 B
while data frames fell to ~714 B, so ~38% of every parity message was zero
padding. Sizing the symbol to the group's own longest frame:

| | fixed 1152 | group-sized |
|---|---:|---:|
| bytes per parity message | 1160 | **725–736** |
| lane rate | 1.06 Mbps | **0.92–0.94 Mbps** |
| conceal, clean path | 0.0% | 0.0% |
| conceal, 10% loss (n=4 / n=5, interleaved) | 9.71 ± 2.90% | 9.78 ± 1.99% |

**The rate fell 12%; concealment did not move** — difference 0.07%, t = 0.04.
A second A/B under a 2 Mbps cap agreed (t = 0.06). That is the expected result
and it is recorded as a null, not buried: at `pcmpairs=6` the lane offers
~0.18 Mbps per association against a ~0.28 Mbps ceiling at 10% loss, so it was
already under the wall and the saved rate had nothing to buy. The change is a
COST and HEADROOM win — 12% less egress per call-minute, and room on links worse
than any tested here — not a quality win at the shipped operating point. Anyone
quoting it should quote it that way.

Correctness is where the risk was, and it is measured rather than argued. The
symbol length is on the wire only as the LENGTH OF THE PARITY MESSAGE; data
frames arrive at their natural size and the receiver pads them to match. Offline
(`testbed/pcmrs-group.mjs`, real audio): 769 groups, 1,355 frames repaired from
parity, **0 decoded wrong**, including 185 groups that lost their longest member
— the case where no surviving data frame is symbol-length and only the parity
knows the size — and 963 exact-fit members that decoded with no padding at all.
Live: `fecSymMismatch 0`, `rsOversize 0`, `avDrops 0`.

The ceiling is 1152 B, which is `1160 − 8` for the parity header, so parity still
never leaves one datagram. The codec's verbatim escape is 1153 B and cannot fit;
such a frame is excluded from its group rather than allowed to fragment all
three parity messages in it. It fired on **0 of 6,827** real frames — the escape
only triggers on white noise.

## Cost

| | measured / published |
|---|---|
| transport per peer | 9.80 Mbps up, 10.04 Mbps down |
| signalling, whole session | 38.5 KB |
| relayed call | **$0.0075 / minute** (both peers, $0.05/GB) |
| direct call | **~$0.0001 / minute** — media never enters our network |
| blended | `r × $0.0075`, where `r` = fraction of calls that need TURN |
| below ~5,000 calls/month | **$0** — inside Cloudflare's free tiers |

`r` is **assumed, not measured** — it needs real users behind real NATs, and it
is the single biggest open variable. Full working in `COST-MODEL.md`, including
the correction that we are ~1.6× cheaper than an SFU, **not 100×**.

The transport row **predates the adaptive code rate** and has not been
re-measured end to end. The audio lane alone fell 0.925 → 0.730 Mbps per
direction on a clean link (−21%), so the true figure is now about 0.2 Mbps per
peer per direction lower than shown — roughly 2% of the total, since video
dominates. It is left uncorrected rather than arithmetically adjusted, because
every other number in this file is something the rig actually read.

## Security

| | measured |
|---|---|
| DTLS | 1.2, `TLS_AES_128_GCM_SHA256` |
| SRTP | `SRTP_AES128_CM_HMAC_SHA1_80` |
| media path | peer-to-peer, `host` candidates — no media server |
| room ids | 128 bits from `crypto.getRandomValues` |
| encryption code | 8 chars, identical on both peers, covers **all four** DTLS associations |
| cost of that code | 0.1 ms keygen, no change to join time |

The honest limit, stated in full in `SECURITY.md`: the code makes a substituted
key **detectable by the two users**, not prevented. Two people who never compare
it get no protection. "Most secure ever" is not earned.

## The one competitor we could measure — and why the honest reading is smaller

`meet.ffmuc.net`, a community-run Jitsi, is the only account-free SFU left
standing. Same rig, same 720p fixture, same day, both browsers on one machine:

| | glass-to-glass p50 | resolution |
|---|---:|---|
| Jitsi @ meet.ffmuc.net | 179.2 ms (n=1) | 1280×720 |
| room.tokkah.com | 23.0 ± 1.7 ms (n=10) | 1280×720 |

That is ~7.8×, and quoting it bare would be dishonest. **That bridge is in Munich
and both my browsers are on one desk in one city.** ICMP to `anycast.ffmuc.net`:
159.6 ms mean over 8 packets (min 157.4, max 161.1). The media goes to Munich
and comes back, so distance alone accounts for essentially the whole gap:

```
Jitsi total          179.2 ms
  round trip to bridge  ~159.6 ms   (distance — no software can remove it)
  everything else        ~19.6 ms   (their capture→encode→forward→decode→paint)

ours  total           23.0 ms
  network                 ~0 ms     (loopback, same machine)
  everything else        ~23.0 ms
```

**The two pipelines are not distinguishable with this data** — ~19.6 ms against
our 23.0 ± 1.7 ms, where their figure is a single run with no spread and rests
on an ICMP estimate of a path we cannot see. A ~3 ms difference is not a finding
at that resolution. What *is* solid is that the entire 156 ms gap is *routing*,
not efficiency. The defensible claim is architectural and it survives:

> An SFU's latency floor is the round trip to its bridge, however good its code
> is. Ours is the distance between the two people, which is the physical
> minimum. Nobody can write software that beats geography.

That is true as a *mechanism*. Its **magnitude** is what the next section
measures, and for Google Meet and Zoom it turns out to be about 6–8 ms, not 156.

Caveats that stay attached to this number:

- **One community-run Jitsi instance in Munich.** Not "Jitsi the product", not a
  proxy for Zoom or Meet, and not a claim about a well-sited commercial SFU with
  a bridge near its users. A Zoom bridge one city away would show far less.
- ICMP to an anycast address is an *estimate* of the media path, not the media
  path itself. The 19.6 ms residual carries that error bar.
- Our 23.0 ms has near-zero network in it. It is a **floor**, not a real call.

### How big is the detour for the giants? Much smaller. Measured.

The Munich number is the friendliest example available and it would be
dishonest to leave it standing alone. The detour an SFU adds to a *same-city*
call is one round trip to its bridge, so it can be bounded without an account:
TCP connect to 443, 12 samples, minimum (the sample least polluted by queueing).

| service | nearest edge, from here | detour it adds that P2P does not pay |
|---|---:|---:|
| Google Meet | **6.4 ms** | ~6 ms |
| Zoom | **8.4 ms** | ~8 ms |
| Microsoft Teams | 36.5 ms | ~37 ms |
| Jitsi @ ffmuc (Munich) | 159.0 ms | ~159 ms |

**So the routing advantage over Google Meet or Zoom is single-digit
milliseconds, not 156.** Their edges are effectively next door. Any blog
sentence of the form "we are 150 ms faster than an SFU" is false for the two
competitors anyone actually cares about, and the Munich figure must never be
presented as a stand-in for them.

This is a *lower bound* — the front door is the nearest anycast POP, and a media
server may sit further back — so the real detour is ≥ these numbers, not ≤.

Three honest consequences:

1. The mechanism is real, the magnitude is situational. It is large where a
   bridge is far (Munich here, or any region a provider has no POP in) and small
   where the provider has local presence.
2. Against a well-sited SFU, **any real advantage has to come from the pipeline,
   not the route** — and we have not measured Meet's or Zoom's pipeline, because
   that needs an account. Against the one pipeline we could measure, ours is
   indistinguishable.
3. **P2P can lose.** For two people on opposite sides of the world, a provider's
   private backbone can beat public-internet routing, and their bridge becomes a
   shortcut rather than a detour. Nothing measured here contradicts that, and the
   blog should say so.

**The canvas hypothesis was tested and is dead.** Their far end is a plain
`<video>`; ours decodes in WebCodecs and paints to a canvas, and that extra copy
looked like the obvious place to find the difference. The app ships both
renderers (`?l2canvas=0` uses `MediaStreamTrackGenerator` → `<video>`), so it
was directly measurable — five runs each, interleaved:

| renderer | p50 | p95 |
|---|---:|---:|
| canvas (default) | 23.2 ± 2.2 ms | 44.7 ± 5.7 ms |
| `<video>` (`?l2canvas=0`) | 23.9 ± 1.1 ms | 43.2 ± 5.2 ms |

t = −0.63: no difference. The canvas paint costs nothing measurable and the
default stays. Recorded because a plausible mechanism that turns out to be
worth 0 ms is exactly the kind of thing this project keeps re-learning.

## What is blocked

Three of the eight product claims — cheapest, lowest-latency, most secure — are
**comparative**, and every comparison is account-gated:

- **Google Meet: bot detection, re-tested 2026-08-06 with a live Workspace host.**
  The account was never the constraint — anonymous "Ask to join" exists — but the
  automated browser is refused before the prejoin screen ("You can't join this
  video call"). Four arms isolate it: headless and headful both fail on the
  default UA; the prejoin appears only once the browser stops declaring itself
  automated. That is bot-detection evasion, so the route is closed and no number
  was taken. Full experiment in `BENCHMARK.md`.
- Zoom, WhatsApp, FaceTime: account required.
- meet.jit.si: re-tested 2026-08-02, now moderator-gated
  (`conference.connectionError.membersOnly`). It was the last account-free option.

The measuring instrument is built, validated and waiting. One join link from a
signed-in account turns each of those into a number:

```bash
node testbed/competitor.mjs --url="<join link>" --label=Meet --sec=25
```

## Claims withdrawn as untrue

Kept here deliberately, because a document that only lists wins is marketing.

- **"2.4× better than same-city Zoom."** Was our *model* divided by their
  *measurement* from a different experimental task. Removed from `DESIGN.md`.
- **"Zoom loses 179 ms beyond its own latency."** Rested on an unsourced 500 ms
  Zoom round trip; Boland measured ~30–70 ms, which makes the real unexplained
  residual ~609 ms. The old figure understated our own argument.
- **"Face to face = 297 ms."** That is the *local control of a Q&A task* in
  Boland et al. **2022** (the document also had the year wrong). The
  face-to-face conversational figure is 135 ms; the cross-linguistic baseline is
  ~208 ms (Stivers 2009).
- **"~100× cheaper than an SFU."** Real figure ~1.6× at `r` = 15%.
- **Jitsi at 836.7 ms.** Pure fixture phase — the rig had decoded a self-view.
- **"1920×1080 delivered."** True of the surface, false of the picture. The
  encoder upscaled a 720p camera to fill a hard-coded 1080p config, and the
  canvas reported the envelope. Fixed; the row now states the camera's own size.
- **"6.6× lower latency than an SFU."** Arithmetically right, materially
  misleading: 159.6 of the 179.2 ms is the round trip to a bridge in Munich.
  Decomposed above — the two pipelines are indistinguishable; only routing
  differs.
- **"Removing the upscale was a bandwidth win, not a latency one."** Written
  here from a single run per arm. Five runs per arm show 3.8 ms p50 / 7.2 ms p95
  (t = 4.0). The lesson is the method, not the number: **no claim from n=1 on a
  path whose run-to-run spread is ±1.7 ms.**
- **"~7.6 ms of pipeline headroom vs the SFU."** Same n=1 error, plus it named a
  cause (canvas painting) that a proper A/B then measured at zero.
- **"Lane 1 delivers 87.1% of frames at 5% loss; the crossover is between 1% and
  5%."** Written from one run, on a fixture that makes the comparison
  meaningless: every timecode frame is a single 1100 B fragment
  (`fragsSent == framesEncoded`, twice, and unchanged at `qp=10`), so lane 1's
  parity never fires — `paritySent 0` in every run. Repeats of the identical
  configuration ranged 57.8% to 87.1%. Re-measured on a high-entropy fixture
  (`mktimecode.mjs`, 13.7 fragments/frame): lane 1 **collapses** at 1% loss —
  1638 ms p50, 12.9% delivered, `skipBuffered` 747 — and shows no picture at all
  at 5%. The conclusion inverts: the shipping default is right, and lane 1's
  advantage exists only at exactly zero loss. The **latency** rows were
  unaffected throughout; they are clean-path and do not depend on frame size.
- **"The 22 fps after a camera flip cannot be attributed."** It could. The
  carrier canvas was being overwritten with the camera, dropping the tick rate
  60 → 30 and the throughput ceiling to 22.5 fps. Explained and fixed above.
- **"`AV_OFFSET` (20 ms, lane 2 only) is where the latency gap comes from."** My
  hypothesis, not a claim I published, but it was wrong and worth recording:
  zeroing it does not help and disabling A/V sync costs **+41 ms**.
- **"Zoom/Meet measure 130–250 ms glass-to-glass."** Had **no source anywhere**,
  and nobody here has measured Zoom's glass-to-glass — it is account-gated. Now
  removed from all three places it appeared (`DESIGN.md` ×2 and the
  `HUMAN-VALIDATION.md` threshold); only the withdrawal notes remain.
- **"We are ~156 ms faster than an SFU."** True only of a volunteer bridge in
  Munich. Google Meet's edge is 6.4 ms from here and Zoom's is 8.4 ms, so
  against the SFUs that matter the routing advantage is **single-digit
  milliseconds**. Measured above.
- **Any ZEF-scale fatigue improvement.** No published study links that scale to
  measured latency. `FATIGUE.md` uses a delay-literature proxy and says so.

## Session 2026-08-03m — scarcity without loss

The 2x2 cell nobody had run. `--bw=0.3 --rtt=80 --sec=35 --self`, production
`b7691689`, netsim dropping **nothing**:

| | `--bw=0.3 --loss=0` | unconstrained `--loss=0` |
|---|---|---|
| audio conceal A / B | **4.5% / 3.6%** | **0.0% / 0.0%** |
| lateFrames A / B | 371 / 238 | 0 / 0 |
| extrapMs A / B | 2120 / 1672 | 0 / 8 |
| video cov | 97.3% | 96.3% |
| video p50 | 63.1 ms | 66.2 ms |
| lossPct | 0/0 | 0/0 |
| final fecN | 0/3 | 0/3 |

`bwQueue: 36976 pkts, p50 0, p95 64.5 ms, max 98.4 ms`.

**Video does not care. Audio loses 4% of its frames to a link that dropped
none of them.** Every one is a late arrival, not a loss.

**FEC is correctly disengaged and could not have helped.** On side A, **100 of
215 successful RS decodes arrived too late to play** — parity rides the same
queue as the data it protects. `FAST_LAG` is 16 frames (128 ms) against a 98 ms
queue max, so queueing never registers as loss and the ladder is right to sit at
`fecN 0`. The 770/520 parity frames observed are the startup ramp-down from the
`fecN = RS_P` initial value, not a congestion response.

**Ruled out, with the evidence, so they are not re-litigated:** a blind
estimator (`noteArrival` at pcm.js:338 precedes the late check at :347, so late
arrivals *are* in the window); a clamp (`want == target` on both sides in every
run); a ladder feedback loop (above); long dropouts (`heldMs 0` — the
extrapolator never hit its 24 ms ceiling).

**What is left is that the estimator is causal.** Target comes from
second-largest-minus-min over 320 frames, so it learns of a burst by suffering
one. Run-scoped counters added this session:

| | jitSpreadMaxRun | aboveFloor | final-window `max` |
|---|---|---|---|
| A | 169.7 ms | 41.2 s of ~47 s | 12.9 ms |
| B | 319.9 ms | 33.5 s of ~47 s | 18.7 ms |

The last column is why this took two runs to see — see instrument notes below.
It pays twice per burst: dropouts going in, then ~13 s of held depth coming out
(UP jumps straight to `want`, DOWN is one frame per second). It is above its
floor for most of the call and still concealed 4%. Task #18.

### Instrument fixes (both shipped)

- **Run-scoped jitter stats.** `jitSpreadMaxRun`, `jitAboveFloorMs` in pcm.js,
  printed as `pcmjit(run):`. The existing `jitMaxMs` is a trailing-320-frame
  window; on a 47 s run it reported 12.9 ms where the true worst was 169.7 ms,
  13x low, because the bursts had rolled out of the window. First printed
  `aboveFloor` as a percentage of `SEC` and got "118% of call" — the stream
  outlives the measure window; it is quoted in seconds against the frame count
  now.
- **Unknown flags are fatal in competitor.mjs.** The duration flag is `--sec=`,
  so every `--secs=35` this session matched nothing and silently took the 20 s
  default. No A/B is invalidated (both arms shared the wrong duration) but the
  labels were wrong. Valid keys are scanned from the file's own source so the
  list cannot drift; note `num('rtt')` reaches `arg()` via a variable, and
  `--rtt/--loss/--bw` are parsed here, not in netsim.mjs.

### Corrections to the section above (same session, after n=8)

Two things in "Session 2026-08-03m" were wrong and are corrected here rather
than edited away, because both are the kind of error worth being able to find
again.

1. **The link was never zero-loss.** `--loss=0` suppresses injected random loss;
   the shaper's queue still overflows. `bwDropped` ran **0.22–1.12%** in every
   run. I read the `bwQueue` line and never read `bwDropped` beside it. The
   finding survives — ~0.3% of ~5900 frames is ~20 frames against 265 concealed,
   so lateness is ~90% of the concealment, not 100% — but "a link that dropped
   nothing" was false.
2. **Concealment at `--bw=0.3` is 2.16 ± 0.60%, not 3.6–4.5%.** Those were
   single runs; n=8 interleaved is tighter and lower.

### D term on the jitter estimator — built, deployed, REVERTED

Hypothesis: `spread` is proportional-only and cannot grow until lateness has
been suffered, but a filling queue moves the delay FLOOR, and that climb is
visible in on-time frames first. Added a derivative term (difference of two
adjacent 32-frame means of arrival delay, projected forward one reaction time,
one-sided) behind `?pcmjitd=0`.

`REPS=8 SEC=35 NET="--rtt=80 --loss=0 --bw=0.3"`:

| | D on | D off |
|---|---:|---:|
| audio conceal | 2.99 ± **2.08**% (1.1–7.2) | 2.16 ± **0.60**% (1.15–2.8) |
| latency p50 | 65.8 ± 4.1 ms | 64.6 ± 6.5 ms |
| latency p95 | 95.4 ± **21.0** | 91.7 ± **8.6** |
| delivered | 97.0 ± 0.8% | 97.4 ± 1.0% |
| lane | 0.759 Mbps | 0.749 Mbps |

conceal t = 1.09 — not distinguishable, mean the WRONG way, variance **3.5x**.
Reverted; served `pcm.js` hash returned to `0d758f58…`, byte-identical to the
pre-experiment deploy.

**Why it failed, in the line chosen most deliberately:** `if (rise > 0)`.
One-sidedness was reasoned (a falling floor needs no buffer) but the difference
of two means is nonzero by chance on a stable link, and rectifying it means
chance only ever pushes UP — `E[max(0, X)] > 0` for zero-mean X. The term's
output scales with the noise it is fed. A single readback run had shown
4.5% → 1.5% and was pure luck: that run's `spreadMax` was 98 ms against the
control's 169.7 ms, i.e. a gentler network, and the control's own range is
1.15–2.8%.

**Still open (task #18):** the estimator remains causal. A threshold-gated
derivative — one that must exceed a noise floor measured from the quiet case
before it acts — is the obvious next attempt and is NOT yet tested. Do not
retry the unrectified or the ungated form.

### The buffer is not the lever — two A/Bs, both negative, both same shape

`REPS=8 SEC=35 NET="--rtt=80 --loss=0 --bw=0.3"`, interleaved.

**1. Derivative term on the estimator** (reverted, see above): conceal
2.99 ± 2.08 vs 2.16 ± 0.60, t = 1.09 the wrong way, variance **3.5x**.

**2. Raising the target ceiling** `pcmjbmax=40` (320 ms) vs shipped 15 (120 ms):

| | cap40 | cap15 (shipped) |
|---|---:|---:|
| audio conceal | 2.33 ± 0.95% | **1.53 ± 0.62%** |
| latency p95 | 104.8 ± **30.9** | **84.8 ± 3.4** |
| delivered | 96.6 ± **3.0**% | **97.6 ± 0.5%** |
| latency p50 | 65.5 ± 3.7 | 66.6 ± 3.5 |

conceal t = 2.00 the WRONG way; p95 variance **9x**, delivered variance 6x.

Give this control law more authority and variance explodes while the mean drifts
the wrong way — twice, by two unrelated mechanisms. **The 120 ms cap is not
starving the buffer, it is refusing to chase a contaminated input.** Direction
closed: the buffer is doing about as well as possible with the arrivals it gets.

**But the ceiling DOES bind**, which an earlier note wrongly denied. Run-scoped
`wantMax` reads 28-101 frames (224-808 ms) against the cap of 15, with 16-92
clamped ticks (250 ms each). The earlier "not a clamp" ruling came from
`want == target` in the trailing-window snapshot, which only ever shows the
quiet tail — the same blind spot that hid `spreadMax`, made twice.

### Where the arrival spread does NOT come from

A 215-793 ms arrival spread cannot come from a ~98 ms network queue. Ruled out
this session, with evidence:

 - **Sender-side SCTP queueing.** `buffered 0`, `overflowSkips 0`, and
   `skipBuffered 0` on all 6 associations, `sent ~= recv` (984 vs 959-982).
 - **A capture/send shortfall.** `captureFrames 7192` vs `framesSent 5902` on
   side A looks like 1290 lost frames; it is the 6 s stagger plus setup, and
   side B (no stagger) shows a gap of 44. Not a defect.
 - **Sender clock drift inflating `d`.** `d = now() - seq*FRAME_MS` ramps at the
   drift rate; 320 ms inside a 2.56 s window would need 125,000 ppm.

**Leading hypothesis, NOT yet tested: the instrument is causing it.**
`driftPpm` reads **1980 and 2000 on both sides** — `maxDrift` is exactly
2000 ppm (pcm-worklet.js:140), so the playout resampler is pinned at its rail
for the whole call. Two Chrome instances on one machine share a crystal, so
genuine drift should be ~0. Meanwhile competitor.mjs's DECODER runs a rAF loop
doing drawImage + getImageData over every video and canvas element in the same
page as the audio lane. Main-thread stalls of that size would batch datachannel
message delivery and appear as exactly this: arrivals bunched hundreds of ms off
schedule, with the clock-recovery loop railed trying to track it.
**Test before anything else is built on top of this number:** measure conceal at
`--bw=0.3` with the decoder rAF loop disabled. If it collapses, part of the
"scarcity" finding is rig-induced and the baselines above need restating.

### Rig hypothesis REFUTED — the spread is real

The decoder rAF loop does identical work with and without the cap, so the
unconstrained run is a clean control for it. `--rtt=80 --loss=0 --sec=35`, no
`--bw`:

| | `--bw=0.3` | unconstrained |
|---|---|---|
| jitSpreadMaxRun | 215-793 ms | **13.9 / 13.6 ms** |
| jitWantMaxRun | 28-101 frames | **3 frames** |
| jitClampedTicks | 16-92 | **0** |
| driftPpm | **1980 / 2000** (rail is 2000) | -210 / +425 |
| conceal | 1.53-2.16% | **0.0% / 0.0%** |
| lateFrames | 117-492 | **4 / 4** |

Main-thread stalls from the instrument would appear in both. They appear in
neither the unconstrained spread (13.9 ms) nor its drift. **The arrival spread
and the railed resampler are both caused by the bandwidth constraint.** Every
baseline above stands as measured; nothing needs restating.

### The next thread: two instruments that disagree by 8x

netsim reports its own queue delay as `bwQueue ... max 98.4 ms`, and the app
measures audio arrival spreads of **320-793 ms** on the same runs. If the shaper
were the only delay source those would match. They differ by up to 8x, so one of
them is wrong, and which one changes what the fix is:

 - If the app's `d` is right, there is delay in the path that netsim does not
   model or does not sample, and the 98 ms figure has been understating every
   constrained result this session.
 - If netsim is right, `d = now() - seq*FRAME_MS` is picking up something that
   is not transit time.

Note the per-source-port bucket (see the netsim caveat comment): with ~7 peer
connections each flow gets its OWN `--bw` bucket, so `bwQueue` aggregates across
buckets that are individually far less loaded than the audio lane's arrival
pattern suggests. Resolve this BEFORE attributing the concealment to any
mechanism — it is the same "instrument the instrument" step that turned up the
snapshot-vs-run error and the silent `--secs=` flag.

### Resolved: the instruments agree, and the lever is the estimator's MEMORY

`rigLate` (netsim's own scheduler lateness, now printed next to bwQueue):
**n 542, p50 0, p95 0.9, p99 1.9, max 10.5 ms.** The delay line is punctual, so
the rig adds no unmodeled delay. Second rig hypothesis refuted; both cleared it.

And on the same run: `spreadMax 96.3 / 95.7 ms` against `bwQueue max 98.4 ms`.
**The two instruments agree.** The audio arrival spread simply IS the shaper's
queue depth. The earlier 320-793 ms readings were outlier runs, not a systematic
8x gap, and nothing in the rig explains them.

**Why raising the ceiling could not have helped.** A ~96 ms spread wants
`ceil(96/8)+1 = 13` frames, under the cap of 15. In a typical run the ceiling
does not bind at all, so `pcmjbmax=40` was buying headroom that was never
reached — and only added variance.

**The actual mechanism, and it is neither the rise nor the cap.** Between bursts
the 320-frame (2.56 s) window goes quiet, `spread` collapses, and the target
decays to ~3 frames (`depthMs 23.9 / 24.5`). The next burst is ~98 ms deep, so
~74 ms of it lands outside a 24 ms buffer and conceals. The estimator is not too
slow to rise and not capped too low — **it forgets too fast.** `aboveFloor` is
25-35 s of 46 s, but "above floor" here means 3 frames, not 13.

Next lever (direction 2 in task #18, untested): window memory and decay rate,
NOT the rise and NOT the ceiling. Decay is 1 frame/s, so 13 -> 3 frames takes
10 s while bursts recur far more often than that. Candidates: lengthen D_WIN
past 320 frames, or hold the target at the window's recent maximum rather than
letting a quiet 2.56 s reset it. Both cost latency between bursts and must be
judged on conceal AND p50 together, n>=8 interleaved.

### SHIPPED: peak-hold on the jitter estimator's input (37df85e2)

`spreadHold = max(spread, spreadHold - 2)` per 250 ms tick -- an 8 ms/s release,
deliberately the same rate as the existing 1 frame/s output decay so no second
time constant enters. Held on the INPUT, so the output law is untouched.
`?pcmjithold=0` is the control arm.

`REPS=8 SEC=35 NET="--rtt=80 --loss=0 --bw=0.3"`:

| | hold (shipped) | nohold |
|---|---:|---:|
| audio conceal | 1.73 ± **0.73**% | 1.94 ± **1.25**% |
| latency p50 | 65.0 ± 4.9 ms | 66.8 ± 5.2 |
| latency p95 | 88.2 ± **4.3** | 93.1 ± **20.7** |
| delivered | 97.6 ± **1.0**% | 97.2 ± **2.3**% |
| lane | 0.740 ± 0.009 Mbps | 0.746 ± 0.019 |

**Every mean moved the right way and not one is distinguishable** (best t is
-0.73). The result is in the VARIANCE, which ab.mjs does not test. F-test, 7/7 df:

| | F | p |
|---|---:|---|
| latency p95 | 23.17 | **0.00049** |
| delivered | 5.29 | **0.043** |
| conceal | 2.93 | 0.179 |
| lane rate | 4.46 | 0.067 |

**Tail latency is 4.8x more consistent and video delivery 2.3x**, at no cost in
mean latency, mean concealment, or rate. Claim consistency, NOT a concealment
win -- 1.94 -> 1.73% is t = -0.41 and is not evidence.

This is the exact inverse of the two failures that preceded it (the D term and
the raised ceiling), which both INFLATED variance 3.5-9x while drifting the mean
the wrong way. Three attempts at the same subsystem, and the variance column
called all three correctly before the mean column said anything at all.

### SHIPPED: release rate 8 ms/s -> 1 ms/s (42119460)

The peak-hold above under-delivered because its RELEASE was set by reasoning
("match the existing output decay, so no second time constant") and not by
measurement. Measurement: `bwQueue p95 5.6 ms, max 97.6 ms` -- bursts are RARE
and brief, and an 8 ms/s release empties the memory in 12 s, before the next one
arrives. Diagnostic confirmed it: `targetFrames 2 (16 ms)`, `depthMs 17.1`,
`decays 15` against `bumps 4`. The hold was not holding.

`REPS=8 SEC=35 NET="--rtt=80 --loss=0 --bw=0.3"`, `pcmjitrel=0.25` vs shipped 2:

| | slow (1 ms/s) | ship (8 ms/s) |
|---|---:|---:|
| latency p50 | **64.2 ± 3.8** ms | 69.3 ± **15.1** |
| latency p95 | **86.2 ± 7.2** | 99.0 ± **29.4** |
| delivered | **97.4 ± 0.7**% | 95.8 ± **3.6**% |
| audio conceal | **2.20 ± 1.23**% | 2.63 ± **2.54**% |
| lane | **0.747 ± 0.018** Mbps | 0.766 ± **0.060** |
| rig bwDropped | **0.32 ± 0.18**% | 0.47 ± **0.53**% |

Every mean better; no t distinguishable (best -0.92). F-test, 7/7 df:
p50 **p=0.0017**, p95 **p=0.0014**, delivered **p=0.0003**, lane **p=0.005**,
bwDropped **p=0.011**, conceal p=0.075. Five of six significant.

**The predicted latency cost did not exist.** I expected ~+80 ms to hold a
~100 ms buffer permanently, and called it the physics limit of the link. p50
FELL, 69.3 -> 64.2 ms. A buffer deep enough not to conceal also stops the
extrapolator perturbing the playout clock, so the depth pays for itself. The
"lossless vs latency" tradeoff I was about to declare irreducible was not real
at this operating point -- do not quote it.

Note the `ship` arm here (conceal 2.63, p50 69.3) against the same config as the
`hold` arm one A/B earlier (1.73, 65.0): session-to-session drift at this
setting is larger than most effects being chased. Only interleaved comparisons
mean anything.

### State after 42119460, and one earlier ruling REOPENED

Diagnostic at `--bw=0.3 --loss=0`, release 1 ms/s shipped:

| | A | B |
|---|---|---|
| targetFrames | 10 (80 ms) | 6 (48 ms) |
| depthMs | 84.2 | 56.3 |
| aboveFloor | 46.3 s of 46.5 | 46.5 s of 46.6 |
| conceal | 2.6% | 1.3% |
| lateFrames | 181 | 68 |
| spreadMax | 104.4 ms | 84.0 ms |

The hold now works: the buffer is above its floor for essentially the whole
call, against 54% before. Concealment persists because bursts (spreadMax 104 ms)
still exceed even the held depth. Note the two sides differ 2x in both depth and
conceal on the same run -- the shaping is asymmetric, so never read one side.

**REOPENED: "FEC cannot help here."** That ruling rested on 100 of 215
successful RS decodes arriving too late to play -- measured when the playhead
sat 24 ms back. It now sits 56-84 ms back and the RS span is 80 ms, so the
precondition is gone. This run still shows `fecRepairedLate 59` vs
`fecRepaired 22` on side A, but with `fecN 0` those parity symbols are only the
startup ramp-down, not a ladder decision.

**The gap in the control law:** the ladder raises parity on measured LOSS, and
at `--bw=0.3` there is none (`lossPct 0/0`) -- the damage is lateness. But a
frame that arrives too late is exactly a frame parity could have reconstructed
early from frames that DID arrive on time. Candidate: feed the receiver's own
`lateFrames` rate into the ladder alongside loss, so the code rate responds to
"frames I could not play" rather than "packets that never came".

CAUTION before building it: added parity is added rate on a link that is already
queueing, and rate is what drives the shaper into overflow (K=5's +9% raised
bwDropped 50%). The win has to survive that. Judge at --bw=0.3, n>=8
interleaved, and F-test the variances -- five of six significant results this
session were variance, not mean.

### FAILED and reverted: lateness-driven FEC ladder (061f4e9d, default OFF)

Fed the receiver's own late-frame rate into the code-rate ladder alongside loss,
so it would protect against "frames I could not play" instead of "packets that
never came" -- redefining the existing T_LOSS bytes, no wire change. Only viable
because peak-hold had moved the playhead from 24 ms to 56-120 ms back, past the
80 ms RS span, which voided the earlier "repairs always arrive too late" ruling.

The mechanism worked: `parityRecv` 572-710 against a ~215 baseline, ladder
stepping up where it never had. The OUTCOME lost, decisively.

`REPS=8 SEC=35 NET="--rtt=80 --loss=0 --bw=0.3"`:

| | late (new) | noLate (shipped) | |
|---|---:|---:|---|
| audio conceal | 3.96 ± 1.24% | **2.42 ± 1.13%** | +1.53, **t = 2.57** |
| latency p50 | 71.8 ± 5.2 ms | **65.4 ± 4.4** | +6.41, **t = 2.66** |
| latency p95 | 125.6 ± 17.3 | **99.4 ± 22.4** | |
| delivered | 94.9 ± 1.5% | **96.4 ± 1.7%** | −1.47, t = −1.84 |
| lane | 0.816 ± 0.033 Mbps | **0.754 ± 0.019** | +8%, **t = 4.55** |
| rig bwDropped | 0.48% | **0.34%** | |

Three metrics distinguishable, all three worse. This is the risk written into
task #19 before the build, and it is worth stating as a rule:
**redundancy cannot fix a congestion symptom, because redundancy IS congestion.**
The parity bought repairs by putting +8% more bytes into the very queue causing
the lateness, so it made more frames late than it rescued.

Note this is the FIRST result this session where the MEANS were significant and
the variance told nothing new (1.24 vs 1.13). The three preceding results were
the reverse. Run both tests, always.

## SHIPPED but INERT: wasted bits, and why the 2x was not there (2026-08-03)

Task #20's premise was that over half the audio lane's bytes are int24 conversion
noise. Offline that was exactly right. On the wire it is false, and the reason is
worth more than the feature.

### The offline result, which was correct arithmetic on the wrong input

`core/pcmpack.js` codes int24 with Rice, which spends its k low bits VERBATIM. If
the capture chain is effectively 16-bit, every sample is a multiple of 256 and the
bottom 8 bits are known zeros that still cost 8 bits per sample — 384 B per frame.
FLAC's "wasted bits" field removes them: shift the common trailing zeros out, put
the count in the header. Measured against the then-live coder, `testbed/pcmwasted.mjs`:

  src16  (16-bit content in a 24-bit container)  768 -> 386 B/frame, 0.768 -> 0.386 Mbps
  dither (a genuine 24-bit noise floor)          769 -> 769 B, byte-identical, shift 0

Half the lane, bit-exact by construction, and free when it does not apply. Zero
header bytes: the header was `order << 5` with 5 bits spare, and a shift of 0..24
needs exactly 5. It also settled a contradiction between two docstrings in this
repo — `pcmpack.mjs` said "Rice coding eats them for free" (FALSE, corrected in
place); `pcmpack.js` said dithering the low 8 bits moves the ratio <0.3% (TRUE,
and the same fact from the other side: zeros and noise are both paid full price).

### What the wire said

Shipped, hash-verified live, then measured. `wastedShift 0`, `shift8 0%` — not one
frame in ~3000. The interleaved n=8 A/B at `--bw=0.3` moved nothing: p50 64.5 vs
63.7 (t=1.26), conceal 2.29 vs 1.58 (t=1.21), lane 0.750 vs 0.741 Mbps (t=1.13),
delivered 97.7 vs 98.1% (t=-0.93).

The rig feeds `media/conv/A.wav`, the same 16-bit file that measured shift 8.0
offline. So the fixture was right and the PIPELINE is what differs. Two hypotheses
for where the low bits come from, both probed live and both refuted:

  fit32768  0%   the chain is bit-transparent (samples are multiples of 256)
  fit32767  0%   the chain converted int16 with /32767, giving round(k*256.0078)

Then a direct search over constant gains on eight captured samples
(`-414758,-395894,-375062,...`): no scale above s=1 makes them integer multiples.

**Chrome's WebRTC capture path is not bit-transparent.** With
echoCancellation/noiseSuppression/autoGainControl all false, it still hands us
values that use the full 24-bit range from a 16-bit source — resampling and
filtering in float, below the source's real depth. The low 8 bits are neither
zeros nor microphone signal; they are arithmetic residue that varies per sample,
so no integer rescaling recovers anything and lossless coding must pay for them.

The audio lane is therefore NOT 2.4x too expensive. Premise refuted.

### Kept anyway, and honestly labelled

Not a shipped win. A correct mechanism this capture chain does not trigger,
retained because it is provably free: with shift 0 on every frame the encoder
emits byte-identical output, verified as the dither control arm. It pays off on
any bit-transparent chain, and `wastedShift` / `shift8Pct` now report each call's
effective bit depth instead of leaving it a guess. `?pcmwaste=0` is the off switch.

Tested harder than the rest of that file: 13,690 frames bit-exact, including a new
case that reaches the VERBATIM escape with a NONZERO shift. The first cut of this
change stored unshifted samples on that path while the header said otherwise —
audio that decodes to plausible garbage rather than failing. The first round-trip
test missed it because it checked against the shift held in a variable instead of
reading it back from the header; in-band is the only honest round-trip.

### The calibration that fell out, and a warning about this session's method

Both A/B arms emit IDENTICAL BYTES here, so every difference above is null by
construction. That makes the run a direct measure of the rig's own spread — and
on conceal it produced sd 1.57 vs 0.56, **F = 7.86 on df 7,7, two-tailed
p = 0.0143**. A significant variance difference between a configuration and itself.

Three of this session's four experiments were decided by exactly that hand-run
F-test. This does not overturn them — the release-rate result carried p=0.0003 to
0.0017 across FIVE metrics at once, and it is the simultaneous agreement that
made it credible, not any single F. But a LONE F-test near p=0.01-0.05 on this rig
is not evidence. Require either multi-metric agreement or a mechanism.

### The escape hatch closed: a real 48 kHz mic, no resample, still shift 0 (2026-08-03)

The refutation above left one loophole, and it was the whole reason the feature was
kept as "inert, not dead": every measurement had come from Chrome's fake capture
device, which reports **44100 Hz against our 48000 Hz AudioContext**. A 44.1 -> 48
resample done in float is a perfectly good explanation for dirty low bits, and it
is an artefact of the rig, not of the product. A real microphone running natively
at 48 kHz would have no resample at all.

That was testable only on a real device, so the probe was moved to the RECEIVE side
(`decodeZip`, deployed `cdb2f586`): measure the shift of the peer's audio as it
arrives here, from bytes on the wire. This deliberately does not depend on the
peer running a current client — and that mattered, because the far side's own
`pcm-stats` came back `wastedShift undefined` the whole run (their tab was on an
older bundle). The receive-side probe answered anyway.

Live call, real MacBook mic behind Proton VPN (Seattle exit), `testbed/livecall.mjs`:

| | |
|---|---|
| far-side capture | `sampleRate 48000`, `channelCount 1`, AEC/NS/AGC all false, `latency 0.002666` |
| `rxWastedShift` | **0 on 50/50 samples**, ~750 probed frames |
| `rxShift8` | 0% |
| `rxFit32767` | 0% |

**The resample was never the cause.** A native 48 kHz capture with no rate
conversion and all processing disabled still delivers int24 samples with no common
trailing zeros and no /32767 structure. Chrome's capture graph is float end to end;
gain and filtering alone are enough to fill the low bits with entropy. The earlier
attribution ("resamples and filters in float") was half right and the wrong half
was doing the explanatory work.

**Consequence for the roadmap.** ~0.75 Mbps is the floor for bit-exact 48 kHz mono
PCM in a browser. There is no bit-exact coder that halves lane A — that is now
measured on both a fake and a real device, on the send side and the receive side.
The only remaining lever is DEPTH, and it is not a coding decision:

- Chrome reports `sampleSize: 16` for the fake device, and `getCapabilities()`
  returns `{max:16,min:16}` (`testbed/bitdepth.mjs`). Real hardware was never
  logged, because the `pick()` at `app.js:2133` omitted the field. Now added and
  deployed (version `e6c5781a`); it lands on the next reload.
- If a real device declares 16, then the low 8 bits provably carry no microphone
  information, and a 16-bit lane is lossless **with respect to the device**.
- But it is NOT lossless with respect to the bitstream we send today. `fit32767 0%`
  and `fit32768 0%` mean truncating to 16 bits does not recover the device's
  original 16-bit values — it is a fresh quantization of an already-processed float
  signal. Halving the lane this way changes what "lossless" is a claim ABOUT.

That is a product decision, not an optimisation, so it is not being taken here.

### Incidentally confirmed on the same run

Real network, real device, 47,956 audio frames received: `late 0`, `dup 0`,
`fecRepaired 0`. Jitter estimator flat at `depthMs 14.7`, `target 2f`,
`spreadMaxRun 10.3` == `holdMaxRun 10.3` (the peak-hold is tracking real arrival
spread, not refusing to release), `clampedTicks 0`. Video decoded at 1920x1080 —
the rig only ever produces 720p, so the 1080p path had never been exercised
end to end before.

One gap, and the cause was mine: concealment was NOT captured on this run, and not
because the data was unavailable. `livecall.mjs` printed `q.concealPct ?? '-'`, and
the pcm snapshot has never had a `concealPct` field — it exposes `playedFrames`,
`lostFrames` and `concealedMs`, from which `competitor.mjs` computes
`100*lost/(played+lost)`. So the rig asked for a name that does not exist and
printed a dash, which reads exactly like "measured, and it was nothing", for 400
seconds. Nothing about concealment is claimed for this run.

Fixed by making an absent snapshot field THROW rather than default (and, on the
far-side path where an older peer bundle legitimately may not carry the field,
by printing `ABSENT` instead of a dash). This is the same defect as `--secs=`
silently not matching `--sec=`: the harness reported success while the headline
number was never read. A metric this project quotes in almost every conclusion
should not be reachable by optional-chaining into nothing.

### The cross-engine penalty, measured on a calibrated rig (2026-08-03)

Built `testbed/rig.mjs` — a harness whose contract is that every number is either
measured or says why it is not. Preflight ABORTS on a blind instrument (frozen
camera fixture, flat remote surface, deaf audio tap, stale deploy, saturated host);
a 4 ms in-page timer calibrates whether this machine can time anything at all; the
report carries provenance per row and a LIMITS list. It refused to run three times
in one session at 83-92% host load, correctly, while a real Safari call held a core.

With the calibration passing (scheduler p95 1.1-1.3 ms — this host CAN time), the
same host and fixtures give two very different calls:

| | Chromium<->Chromium | Chromium<->WebKit |
|---|---|---|
| `jitSpreadMaxRun` | 45-56 ms | **157-189 ms** |
| `jitSpreadMaxAtMs` | ~11 s | **39-41 s (past warm-up)** |
| buffer / target | 13 ms / 2f | **121.6 ms / 15f = the ceiling** |
| `jitWantMaxRun` | 7-8f | **21-25f** |
| `jitClampedTicks` | 0 | **157-159 (~40 s of 60)** |
| concealment | 0.14% | **0.64-1.13%** |
| `late` | 8-9 | **47-61** |
| main-thread cost | 1.7-11% | 0% Cr / 8.2% WK |

**~9x the audio buffer, and the ceiling is BINDING.** The estimator asked for 21-25
frames and `maxTargetFrames` is 15, so the call pays maximum latency AND 5-8x the
concealment simultaneously. That is two defects, not one: a bursty cross-engine
path, and a ceiling that cannot express what the estimator measures.

**Three candidate causes ruled out, which is the point of the calibration:**
- NOT a startup transient. The new `jitSpreadMaxAtMs` (shipped this session,
  observability only) puts the max at 39-41 s, and `jitSpreadMaxLate` equals the run
  max. The 1 ms/s release ratchet is real but is not this.
- NOT main-thread CPU: 0% and 8.2% occupied by the call, measured against a pre-join
  baseline on the same page.
- NOT host contention: the scheduler calibration cleared it. An earlier UNCALIBRATED
  run of the same pairing read 314 ms; that one was partly host load. Quote 157-189.

Remaining suspect: SCTP/datachannel pacing on the WebKit side.

**Limits, stated rather than left to be forgotten.** Playwright WebKit is not Safari,
so this PREDICTS a Safari problem and does not prove one. n=1. Both endpoints share a
laptop, so absolute values are not internet-representative — but the cc-vs-cw
comparison is same-host and same-fixture, which is where its strength is.

### Two instrument errors found and fixed in the same session

**A new metric fired on its first run and was wrong.** A compositor-based cadence
probe reported 35-50% "hitching" on a clean local call. Headless Chromium has no
panel: rAF ran at 68-72 Hz, and 68/30 = 2.27 is not an integer, so a PERFECT
pipeline must alternate 2- and 3-refresh holds with frac(2.27) = 27% off the mode.
Rescored as holds outside `[floor(r), ceil(r)]` — zero for a perfect pipeline at any
ratio — and validated on synthetic cadences first (`[2,2,2,3]` must score 0; one 5
in 100 must score 0.01). Then added the discriminator that settles it: rAF's own
interval p95 vs mean. Headless measures p95 26 ms against a 13.9 ms mean, so the
compositor skips every other beat and the probe declares itself CONTAMINATED rather
than publishing a judder figure.

**And the metric already existed.** `stats.presentAt` and `ipiP50/P95/P99` have been
in `tape.js` since task #33, measured off our own clock and therefore immune to the
compositor — with a recorded before/after (bimodal 31/62 ms and 56-58% on-cadence,
versus p95 33.3 ms and 96-100% after the v-presenter). I built a worse instrument
for a question that was already answered because I did not grep first. The rig now
reads the product's IPI numbers and keeps the compositor probe only as a secondary,
explicitly contaminated in headless.

### The cross-engine penalty is RARE STALLS, not pacing (2026-08-03)

Shipped inter-arrival gap stats (`gapP50/P95/P99`, `gapClumpPct`, `gapMaxRun`;
observability only) because `spread` cannot distinguish two mechanisms that need
opposite fixes — a sender that BATCHES versus gaps uniformly STRETCHED. Measured:

| | gap p50 / p95 / p99 | gap MAX | max/p99 | spread | buffer | conceal |
|---|---|---|---|---|---|---|
| Chromium<->Chromium | 8.32 / 10.85 / 11.53 | 18.7-19.2 | **1.6x** | 12.9-15.1 | 15 ms | 0% |
| Chromium<->WebKit | 7.99 / 8.61 / 9.82 | **75.4-87** | **7.7x** | 66.5-73.6 | 35-51 ms | 0.14-0.22% |

Neither hypothesis was right. **The bulk of the cross-engine distribution is
indistinguishable from clean** — p50/p95/p99 all match, clumping is 0.4% against 0%.
The entire difference is in the tail: isolated 75-87 ms holes where same-engine tops
out at 18.7.

**Why that pins the buffer.** `spread` is second-largest-minus-min over a 2.56 s
window, so ONE 87 ms hole sets it outright; the peak-hold then releases at 1 ms/s and
remembers it for ~87 s. A stall every ~90 seconds keeps the buffer permanently
elevated. A path that is clean 99% of the time therefore reads as badly jittery, and
the estimator is behaving exactly as designed while doing it. Fix the stalls — do not
retune the control law (task #19 and the two prior buffer tunings all made it worse).

**Run-to-run variance is large and must be quoted as such:** one cw run measured
spread 157-189 ms with the ceiling clamped for 157 ticks; another measured 66-74 ms
with `clampedTicks 0`. The MECHANISM reproduced in both (max/p99 ~8x); the magnitude
did not. n=1 on magnitude.

### Three more instrument faults found by running the clean baseline first

Each was caught because a KNOWN-GOOD configuration was measured before a suspect one:

1. **The camera-liveness preflight rejected a live camera.** It compared global luma
   mean/sd across 600 ms; a person sitting still moved it by less than 0.05, so a
   perfectly live fixture read as "FROZEN". Replaced with a per-pixel FNV hash of the
   downscale — any single changed pixel now counts. A liveness test built on a
   statistic that is invariant to the thing it is testing for is not a test.
2. **The gap verdict called a perfect lane "STRETCHED".** It compared p95 against
   8 ms flat, but the nominal gap IS 8 ms, so p95 necessarily exceeds it. Thresholds
   are now relative to nominal (p95 > 2x) with the clean baseline printed alongside.
3. **The gap verdict then pronounced "even arrival" on the run with 87 ms holes,**
   because it read p95 and clumping and never looked at the tail. Added the
   `max/p99` test, which is what actually names the mechanism.

All three produced a confident sentence about a configuration whose true state was
the opposite. The pattern to keep: measure the known-good arm first and require the
instrument to agree that it is good, before believing anything it says about the
suspect arm.

## The cross-engine stalls are real, and they are host contention

Two questions were open: are the stalls reproducible, or was one run unlucky; and
does a WebKit peer stall its own receive path, or a shared resource.

### The stalls are simultaneous on both ends

`pcm.js` stamps every gap over `3 * FRAME_MS` with `now()` = `performance.timeOrigin +
performance.now()`. That is a wall-clock epoch, so on one host the two browsers' stall
lists are DIRECTLY COMPARABLE across processes — the single fact that makes this
measurable at all. `testbed/rig.mjs` pairs them against an explicit chance null model
(`a*b*2*tol/W`), because "about half of them line up" is what a coincidence rate looks
like when you do not compute one.

Chromium <-> WebKit, 90 s: A 16 stalls (max 3824.9 ms), B 19 stalls (max 3824.5 ms).

    coincident within +/-25 ms: 15 of 16      expected by chance: 0.2

A 75x excess over chance, and the multi-second freeze matched **to 0.4 ms**. The cause
is SHARED. It is not one sender's pacing, and it is not clock drift — a clock problem
would not produce simultaneous holes.

The same-engine control: 1 stall each side, 3582.3 / 3585.3 ms, also simultaneous, and
**zero in the 24-60 ms band**. So there are two populations, not one:

| population | cc | cw | simultaneous? |
|---|---|---|---|
| 24-60 ms holes | **absent** | present, ~4 per minute | yes |
| one 3.5-3.8 s freeze | present | present | yes, to 0.4 ms |

The freeze is in BOTH arms, so it is not about the pairing. The 24-60 ms holes are
cross-engine-only.

### Interleaved, so the host cannot be the explanation

n=1 per arm cannot separate "WebKit causes stalls" from "the host was in a bad mood
during that run". `testbed/stallab.mjs` alternates arms — cc, cw, cc, cw — counting
only the 24-200 ms band, because the multi-second freeze belongs to the other
population and would swamp it.

| rep | cc stalls | cw stalls |
|---|---|---|
| 0 | **0** | **5** |
| 1 | **0** | **3** |

Zero overlap between arms, so no t-test is required or meaningful here (a derived
count with no variance overlap is not a sampling question). The effect is real.

### The mechanism, from the calibration column

The reason to carry scheduler lateness in every report is this line:

| | scheduler p95 lateness |
|---|---|
| cc | 1.4, 1.7 ms |
| cw | **4.4, 4.8 ms** |

**Adding a WebKit peer triples host scheduler lateness**, in the same interleaved runs
that show the stalls. Both figures are far below the 20 ms untrusted threshold, so the
timing above stands — but the direction is unambiguous, and it names the mechanism:
host contention, which is also why the stalls are simultaneous on both ends.

The main-thread cost probe missed this entirely — it read 0% (Chromium) and 8.2%
(WebKit). WebKit does its media work in separate processes (`WebKit.GPU`,
`WebKit.WebContent`, measured at 86-103% of a core during a real Safari call), and a
probe that runs on the main thread cannot see any of it. The probe was already labelled
"main thread ONLY, so a low number does not mean the call is cheap"; this is that
caveat being load-bearing rather than decorative.

### Why one hole costs a minute of latency

`spread` is second-largest-minus-min over a 2.56 s window, so a single 87 ms hole sets
it, and the peak-hold releases at 1 ms/s. One stall therefore keeps the buffer elevated
for ~87 s. At ~4 stalls a minute the buffer never comes back down. The defect is not
the control law — it is that the release rate was tuned against RECURRING bursts, and
isolated stalls are a regime it was never measured in.

### Was it the rig? Now a measurement, not an argument

The rig runs probes inside the live call — `spareCapacity` saturates the main thread on
purpose, `cadence` runs an rAF + canvas-readback loop, and each sample does a canvas
grab. `pcm.js` timestamps arrivals on that same main thread. So the rig is a candidate
cause of every stall it reports, and the tempting argument was numerological: "the
freeze is 3.5 s and `cadence` runs 3.0 s, suspicious."

That is the class of reasoning that has been wrong repeatedly here, so it was replaced
with an instrument. `report.activity` now records `{name, t0, t1}` in wall clock for
every operation the rig performs on a live page. Stalls already carry wall-clock stamps,
so each stall's window `[t-g, t]` is intersected with that list. **The null model is the
rig's own duty cycle**: at D% duty, D% of unrelated stalls overlap by chance.

Chromium <-> WebKit, 90 s, rig busy 12.5 s of an 81 s stall window (15% duty):

    stalls overlapping rig activity: 3 of 20      expected at 15% duty: 3.1

Exactly chance. **The rig is not causing the stalls.** `--noprobe` was added to ablate
the two in-call probes for cases where overlap is non-trivial, since overlap is evidence
but absence of overlap at low duty is weak.

Same run, incidentally: **no multi-second freeze at all** — the largest stall was
60.3 ms. So that population is intermittent, not once-per-run, and one run's absence
must not be read as its resolution. The 24-60 ms cross-engine population reproduced for
a third time (A 8 stalls max 48 ms, B 12 max 60.3 ms, 8 of 8 coincident against 0.1
expected), and the magnitude spread stayed wide: this run's `spreadMax` was 45.5 ms with
`clampedTicks 0`, against 157-189 ms and 157 clamped ticks in the worst one.

### A 1000x units error in the report itself

The same run printed:

    one hole sets spread, and the peak-hold keeps it for 0+ s at the measured 1 ms/s release

for a 60.3 ms hole whose true hold is ~60 s. The expression was `(gapMaxRun /
1000).toFixed(0)` — a ms-to-seconds conversion applied to a quantity that does not need
one. Because the release rate is **1 ms of spread per second**, the hold time in seconds
is numerically the spread in milliseconds; there is no factor of 1000 anywhere. Wrong by
three orders of magnitude, and it rendered as a rounded zero rather than as an error, so
it read as "this decays instantly" — the exact opposite of the finding it accompanied.
Now a named `holdSecs()` with the identity written down beside it.

### What one hiccup costs, measured

The cross-engine work exposed a property of our own estimator that has nothing to do
with which browser is on the other end. `spread` is second-largest-minus-min over a
2.56 s window and the peak-hold releases at 1 ms/s, so one hole should raise the buffer
and keep it raised for about ninety seconds. That is a reading of the source, and this
project's readings have a poor record, so `testbed/onehole.mjs` measures it: clean
same-engine call, settle to the floor, then block ONE receiver's main thread once.

The block is the faithful stimulus rather than a convenient one — arrivals are
timestamped on the main thread, so nothing is dispatched for the duration and the
backlog then lands in a clump, which is the measured signature of the real stalls. The
run VOIDS itself unless a stall of roughly the injected size appears in the receiver's
own stall list.

One 99.9 ms hole, baseline target 2f / depth 14.7 ms:

| | value |
|---|---|
| target | snapped **2f -> 12f immediately** |
| depth | ramped in over 30 s to **68.7 ms** |
| target back to 2f | **t+80 s** |
| depth back to baseline | ~t+94 s |

So **one hiccup costs ~54 ms of added audio latency, arriving half a minute after the
event and lasting a minute and a half.** Video is paced to that playhead, so it drags
video with it. Predicted ~100 s from the release rate alone, measured 80 s: the
mechanism is understood, not merely correlated.

The outlier rejection does not protect against this, and it is worth being precise why.
Second-largest-minus-min discards one anomalous ARRIVAL. A stall is inherently a
multi-sample event: `D = arrival - seq * FRAME_MS`, so every frame in the post-stall
clump carries its own elevated D, spanning roughly 0 to the hole size. The estimator's
robustness is defeated by exactly the event it most needs to handle.

### The 2x2 that answered nothing, and why that is the useful part

The obvious follow-up — {1 hole, 6 holes} x {1 ms/s, 8 ms/s} as four sequential runs —
produced four result tables and zero information. `?pcmjitrel=` already existed as a
query param, so no deploy was needed, which made it cheap enough to get wrong quickly:

- Run 1 ended with target at its 2-frame floor. Runs 2, 3 and 4 **all ended pinned at
  the 15-frame ceiling.** Monotone in run order. That is not the shape of a
  release-rate effect; it is the shape of accumulated host state, and it moved the
  metric further than the variable did.
- Run 3's BASELINE, before any injection, read **depth -22935 ms with 2867 frames
  concealed.** 2867 / 125 fps = 22.9 s, matching the negative depth exactly: that
  call's playhead was running 23 s ahead of its audio. The arm was dead on arrival and
  still printed a tidy table. (Filed separately — a lane that reports connected and
  full-rate while concealing continuously is a product defect, not a rig defect.)
- One arm reported a NEGATIVE excursion area beside a positive peak.

Two faults, both structural rather than careless. `onehole.mjs` inherited the honesty
primitives but **not the preflight discipline** — it never required its own baseline to
be healthy, and a baseline is a measurement like any other. And sequential arms on one
laptop cannot resolve this effect at all.

`testbed/relpair.mjs` fixes both by running the two release rates as **the two sides of
one call**. `?pcmjitrel=` is receive-side only, so A can hold slowly while B holds fast,
in the same call, on the same host, with the hole injected into both receive paths at
the same instant. Run order and host state cancel by construction. Baseline preflight
now ABORTS on non-positive depth, depth above 300 ms, fewer than 1000 frames received,
concealment above 0.5%, scheduler p95 at or above 20 ms, and — the one that would have
saved the whole afternoon — **on the page disagreeing with the release rate it was
asked for**, since a mistyped param would give both sides the default and read as a
beautifully clean null result.

It also has a free null arm: with `--relA` equal to `--relB` both sides are identical
software, so every difference the report prints is the instrument's own side-to-side
spread. That is the threshold a real effect has to clear, and it is not optional here —
an F-test on this project once returned p=0.0143 on two arms that were byte-identical.

### The noise floor, measured

Null arm, both sides at 1 ms/s, one 90 ms hole into both receive paths at once:

| | A | B | spread |
|---|---|---|---|
| added latency | 54.8 ms | 54.8 ms | **0.0 ms** |
| excursion area | 2606 ms*s | 2587 ms*s | **0.7%** |
| recovered at | 82.2 s | 80.2 s | **2.0 s** |
| frames concealed | 11 | 10 | **1** |
| peak / final target | 12f / 2f | 12f / 2f | none |

Far tighter than any sequential comparison on this host, where between-run spread on p50
alone is about +/-1.7 ms and where run order moved the final target from 2f to the 15f
ceiling. One fixed asymmetry showed up and is worth carrying: side A ran a consistently
higher baseline depth (17.5 vs 14.7 ms), so a real comparison also needs the sides
swapped, or a side bias could be read as an effect.

A useful incidental number: depth fills toward its target at ~2 ms/s (17.5 -> 72.3 ms
over 30 s), i.e. the playout slews about 0.2% off realtime to accumulate buffer, which
is inaudible. So the target's HEIGHT matters much less than how long it stays high —
which is precisely what the release rate controls.

### The result, paired and swapped

One 90-100 ms hole injected into both receive paths at the same instant. `real` runs the
slow release on side A, `swap` exchanges the sides.

| isolated hole | slow (1 ms/s) | fast (8 ms/s) |
|---|---|---|
| added buffer latency | 52.4 / 49.5 ms | **19.7 / 23.8 ms** |
| excursion area (ms*s) | 2330 / 1959 | **775 / 317** |
| recovered at | 76.2 / 62.2 s | **14 / 12 s** |
| frames concealed | 9 / 9 | 10 / 10 |

The effect **reverses exactly with the sides**, so it is the parameter and not the side
asymmetry the null arm found. Predicted holds from the release rate alone were 90 s and
11 s; measured 76/62 and 14/12. The cost is **+1 concealed frame — precisely the null
arm's noise floor**, i.e. no measurable delivery cost in this regime.

Recurring, 6 holes 10 s apart — the regime the slow release was introduced to protect,
where it was supposed to win:

| recurring | slow | fast |
|---|---|---|
| excursion, buffer | 5683 ms*s | **2995** |
| excursion, e2e | 5676 ms*s | **2986** |
| recovered at | 126.8 s | **64.6 s** |
| frames concealed | 28 | 35 |

Fast wins here too. 7 extra concealed frames out of ~18,000 received is 0.04%.

**Depth is a valid latency proxy on this rig, and the report now proves it rather than
assuming it.** The two excursion integrals — one on buffer depth, one on end-to-end
`ageP50 + depth` — agree to **0.1%** (5683 vs 5676), because capture-to-arrival transit
is 2.8 ms and constant on a local path. On a real WAN path age dominates and this
identity would not hold, which is exactly why both columns are printed.

### Which does NOT overturn the n=8 result, and the reason matters

pcm.js records an A/B at n=8 under `--bw=0.3` where the **slow** release won on every
mean, with significantly lower variance on five of six metrics (p50 sd 15.1 -> 3.8 ms,
p=0.0017; p95 29.4 -> 7.2, p=0.0014; delivered 3.6 -> 0.7 pp, p=0.0003) and no latency
cost at all (p50 *fell* 69.3 -> 64.2 ms). That has better statistics than anything here.

Both results stand, because they are different regimes. Under bandwidth shaping the
buffer prevents concealment that is actually happening, and concealment is the binding
cost. On a clean link with stalls it prevents 0.2% either way — a buffer that prevents
nothing is pure latency.

So **recurrence is not the discriminator** (fast won the recurring arm). The
discriminator is whether the buffer is EARNING its depth. That is a materially better
control signal than the one this investigation set out to build, and it is already
measured inside pcm.js as the concealment rate.

### Driving concealment pressure until the buffer has to earn it

Rather than add bandwidth shaping and its queueing as a second variable, the pressure
was raised directly: holes at and beyond the buffer's own depth, 12 of them, 5 s apart.
The prediction, recorded before the runs, was that the slow release's deeper buffer
would start covering holes the shallow one missed, concealment would separate by more
than the null arm's 1 frame, and the ranking would flip.

| | slow | fast |
|---|---|---|
| **12 x 150 ms every 5 s** | | |
| excursion, e2e | 11160 ms*s | **6308** |
| recovered at | **never** | 80.4 s |
| final target | 8f | **2f** |
| frames concealed | 126 | **126** |
| **12 x 250 ms every 5 s** | | |
| excursion, e2e | 7544 ms*s | 7412 |
| frames concealed | 723 | 727 |
| final target | **15f (ceiling)** | **15f (ceiling)** |

The prediction was wrong in both arms. At moderate pressure fast still wins 1.8x while
slow never recovers at all, and concealment is **identical to the frame** — 126 and 126.

At heavy pressure **the release rate becomes inert.** The estimator asks for more than
`maxTargetFrames = 15` continuously, so `spreadHold` never falls into the range where
the release acts, and the two arms are indistinguishable (723 vs 727 concealed, neither
recovering). Any release tuning is invisible above the ceiling — the same "check which
side of the wall you are on" lesson that a rate-cut experiment already learned here.

So across every regime measured on this rig, the slow release never wins. The one place
it does win is the `--bw=0.3` shaped link, and the mechanism separating them is now
clear: **loss versus lateness.** Under shaping packets are genuinely tail-dropped and
depth buys RS/FEC time to repair them. Against stalls every packet arrives, merely late,
so depth prevents nothing. pcm.js already separates `lostFrames`, `late` and
`fecRepaired`, so a loss-gated release could get both regimes right — which is a
different law from the recurrence-gated one this investigation set out to build.

That is a hypothesis with a measured basis, not a change to ship. The n=8 shaped result
has better statistics than anything above, and two previous buffer tunings on this
project exploded in variance. The missing measurement is the shaped regime on the paired
rig, via `testbed/netsim.mjs`.

### The shaped regimes, on the paired rig

`relpair.mjs` now drives `startP2PSim` from netsim.mjs, rewriting every ICE candidate —
trickled and SDP-embedded — through a UDP delay proxy. That rewrite is PROVEN per run
rather than assumed: the preflight requires `window.__rewrites` to show candidates
actually rewritten, because a shaped run that quietly went unshaped would show the slow
release losing in the one regime it is supposed to win, and the number would look
entirely reasonable.

**0.3 Mbps bandwidth ceiling** (matching the condition named in pcm.js):

| | slow | fast |
|---|---|---|
| mean mouth-to-ear | **114.5 ms** | **25.9 ms** |
| last third | 106.9 ms | 17.1 ms |
| frames concealed in window | 0 | 1 |

88.6 ms of mean latency for one concealed frame. **But this is not the n=8 condition.**
Baseline concealment was 4.19% at settle and then essentially zero for the whole 138 s
window: the video lane's congestion control backed off and freed the link. So it is a
lossy START followed by a clean steady state — which makes it a sharper finding than the
one being chased. **A bad first few seconds costs the entire call.** At 1 ms/s the buffer
sized by that startup transient never came back down, and the fast release shed it in
seconds. The same startup-transient mechanism was flagged in the cross-engine work; this
measures its price.

**5% sustained datagram loss**, which congestion control cannot back away from. Shaper
counters confirm it bound: 29,436 dropped of 501,743 sent = **5.87% actual**.

| | slow | fast |
|---|---|---|
| mean mouth-to-ear | 99.4 ms | 96.5 ms |
| last third | 124.8 ms | 120.9 ms |
| concealment rate | 1.734% | **1.578%** |
| final target | 15f (ceiling) | 15f (ceiling) |

Fast is equal-or-better on BOTH axes — it conceals slightly LESS, not more. Whether those
margins mean anything needed a null arm AT THIS LOSS LEVEL, since the clean-link null
bounded noise at ~1 frame out of ~10, not out of ~300. Run (both sides 1 ms/s, 5% loss,
shaper 27,426 of 466,609 = 5.88%):

| | A | B | noise floor |
|---|---|---|---|
| mean mouth-to-ear | 112.0 ms | 107.7 ms | **4.3 ms** |
| last third | 119.3 ms | 119.0 ms | **0.3 ms** |
| frames concealed | 201 | 199 | **2** |

Against that: the 27-frame concealment difference (273 vs 300) is **13x the floor**, and
the 3.9 ms last-third latency difference is **13x** its floor. Both are real. The mean-e2e
difference (2.9 ms) is NOT — it sits inside the 4.3 ms floor and must not be quoted.

**The null arm also quantifies why the pairing was necessary.** Side A at 1 ms/s concealed
**201 frames in one call and 300 in another**, under identical shaping — a 50% between-call
swing, against 2 frames of within-call spread. Any sequential A/B at this loss level would
be reading call-to-call luck; the paired comparison is unaffected because both arms share
the call.

### What is and is not established

Across seven regimes on this rig the slow release never wins. On a clean link it costs
30-90 ms of mouth-to-ear latency for no measurable concealment benefit. Under sustained 5%
loss — the regime it exists for — it conceals **more**, not less, by 13x the measured noise
floor, while carrying 3.9 ms more latency. Above the 15-frame ceiling it makes no
difference either way, because the release cannot act there at all.

**The n=8 result is still not reproduced, and that is stated rather than explained away.**
It measured different quantities (rig p50/p95, delivered pp, lane rate) at `--bw=0.3`,
where the paired rig now shows the link going clean after settle. Overturning it needs an
interleaved n>=8 at matched metrics, not six paired n=1 runs, however consistent they are.
Nothing about the shipped release rate should change until that exists.

### A reproducer for the multi-second freeze

Incidental, and possibly the most useful thing in the sweep: the 250 ms arm recorded a
**3795.1 ms stall on side A and 3798.4 ms on side B** — the mysterious 3.5-3.8 s
simultaneous freeze from the cross-engine runs, now produced on demand from a 250 ms
main-thread block. A 15x amplification, simultaneous on both ends to ~3 ms.

That points at something in the send path turning a moderate main-thread block into a
multi-second outage — SCTP send-buffer buildup and congestion-window collapse are the
obvious suspects, and this project already has a finding about the SCTP window being
per-association. It is now cheap to investigate, which it was not when the freeze only
showed up unbidden once per cross-engine run.

### The caveat that changes the conclusion

Both browsers share one host, so WebKit's contention stalls the Chromium peer too. On
two real machines that coupling does not exist. So the honest claim is: **a Safari user
likely pays this from their own machine's load, not their peer's** — and the rig, being
co-located, cannot tell those apart. Playwright WebKit is also not Safari. This
predicts a Safari problem; it does not prove one.

## The 23-second playhead: a lane that reports connected, full-rate, and hears nothing

The defect filed above — run 3's baseline reading **depth -22935 ms with 2867 frames
concealed** — is reproduced on demand and explained. It is not a stale playhead origin,
and it is not a transport fault. `framesRecv` was 125.0-125.1 fps and `lateFrames` was 0
in every dead arm.

### The mechanism

`ringWrite()` seeds `startSeq` from the FIRST frame ever received, which is correct. The
fault is one line down, in the accept window:

```js
const lo = Math.max(startSeq, playSeqNow());   // pcm.js:401
if (seq >= lo + RING_F) { stats.farFuture++; return false; }
```

`playSeqNow()` reads `SAB_PLAY`, which `pcm.js:308` initialises to **0**. So for the
entire time the playout worklet does not yet exist, `lo` is pinned to `startSeq`, and the
ring — 64 frames, **512 ms** — accepts `startSeq..startSeq+63` and rejects every later
frame as far-future. `hiSeq1` freezes at `startSeq+64`.

Then the audio graph comes up. The playhead primes on the two frames it finds at
`startSeq`, which is correct and useless: that audio is now D seconds old. From there
`lo` advances at 125 frames/s — **exactly the rate the sender's seq advances** — so the
gap never closes. The drift controller widens it: `err` is hugely negative, `ratio`
clamps at `1-maxDrift`, and the playhead falls a further 0.2% behind every second. Every
subsequent frame is rejected far-future for the rest of the call, and the playhead
conceals continuously against a ring holding 512 ms of ancient audio.

The signature is an identity, and it holds in every arm: **deficit in frames ==
lostFrames.** `22935.4/8 = 2867` filed; `22927.4/8 = 2866` reproduced.

`targetFrames` staying at its 2-frame floor is the second tell. `pcm-conceal` only posts
when `consec === 1`, and `consec` only resets on a present frame — so one unbroken
23-second concealment run bumps the target **once**. A floor-value target beside
thousands of concealed frames is not a calm lane; it is one continuous hole.

### The cliff, in closed form

The worklet's one existing re-anchor is the ring-overflow skip, and it fires (`ovfSkips
1`) — it moves the playhead to `hiSeq1-target`, the head of the **stale** ring. That is
worth 512 ms of relief and no more. There is no lower bound anywhere: the overflow test
is `occupancy > (RING_F-4)*FRAME`, and nothing tests occupancy for being absurdly
negative. So a live frame lands iff `125D < 2*RING_F - target = 126`:

    D < 1.008 s      D = first PCM frame arriving -> await addModule() resolving

`testbed/pcm-origin.mjs` drives the real `PcmPlayout` against a line-for-line copy of the
writer gate and straddles it exactly: **D=0.95 s recovers (lost 56), D=1.0 s does not
(depth -24931 ms, lost 3117, farFuture 3186).** `testbed/pcm-graphdelay.mjs` reproduces
it on two real Chromium peers against room.tokkah.com by delaying only B's
`addModule('/pcm-worklet.js')`:

| measured D | depthMs | lostFrames | played | framesRecv | fps | negative samples |
|---|---|---|---|---|---|---|
| -0.095 s | +20.0 | 1 | 3738 | 3753 | 125.0 | 0/1164 |
| 0.291 s | +33.9 | 0 | 3660 | 3755 | 125.1 | 0/1149 |
| 0.865 s | +41.5 | 48 | 2997 | 3130 | 125.1 | 0/926 |
| 1.173 s | **-22927.4** | 2866 | 4 | 3130 | 125.0 | **915/915** |
| 1.408 s | **-22887.4** | 2861 | 9 | 3130 | 125.0 | **905/905** |
| 2.904 s | **-26911.4** | 3364 | 5 | 3754 | 125.1 | **1043/1043** |

`page.route()` does **not** intercept an AudioWorklet module fetch — a first attempt
injected 3 s and moved measured D by 0 ms. The harness caught its own failed injection
rather than reporting the control as a result; the delay had to be installed where the
await is, on `AudioWorklet.prototype.addModule`.

### Yes, in production, and the margin is about a second

The pre-graph path is `await audioContext()` — which itself awaits a first
`addModule(onset-worklet.js)` plus `ctx.resume()` — and then a second
`addModule('/pcm-worklet.js')`, which imports `core/onset.js` and `core/turnend.js`. Three
module fetches and a context resume, all of which must finish within 1.008 s of the
peer's first frame. Frames start the moment our datachannel opens, so **the second joiner
is the exposed one**: the peer is already capturing, and our graph is racing DTLS/SCTP.

On the control arm the graph won that race by **95 ms**, on an unloaded 10-core laptop
with a warm cache. Measured `addModule` alone ranged 108-333 ms depending on host load.
The total margin is that 95 ms plus the 1.008 s window — which a cold cache, a slow
mobile link, or a loaded device consumes without anything unusual happening. Four browser
pairs launched back-to-back with no cooldown consumed it, which is how run 3 died.

A user hears ~23 s of concealment while `pc` state, `framesRecv`, `fps` and `lateFrames`
all report a healthy full-rate call. `stats.farFuture` — incremented on **every** rejected
frame, thousands of them — is never exposed in `snapshot()` at all. In port mode the same
drop in `takeFrame()` has no counter of any kind.

### Which layer owns it, and the trap on the way

`--anchor` in `pcm-origin.mjs` answers this, and the answer is worth the run:

| arm | depthMs | lostFrames | played | farFuture |
|---|---|---|---|---|
| `none` (shipped) | -24931.4 | 3117 | 3 | 3186 |
| `worklet` re-anchor | **-39.9** | **3060** | 97 | 3436 |
| `writer` re-seed | **+13.3** | **0** | 3126 | 0 |

The worklet-side re-anchor — the obvious fix, and the one this codebase would reach for,
since the overflow skip already lives there — drags `depthMs` from -24931 ms to a
perfectly plausible **-39.9 ms** and leaves 3060 frames concealed and the audio just as
broken. It cannot work: `hiSeq1` is frozen by the *writer*, so moving the playhead back
to `hiSeq1-target` moves it back into the same stale 512 ms. **It converts an alarming
number into a plausible one and fixes nothing**, which is this project's recurring defect
class arriving as the proposed cure.

Only the writer can fix it, and the fix is that the ring should hold the newest 512 ms
rather than the first 512 ms: on a far-future frame arriving while the playhead has not
started, re-seed `startSeq` and drop the stale ring. That reads 0 lost frames and positive
depth at every delay out to 23.4 s. It needs one thing the SAB layout cannot currently
express — `SAB_PLAY` is initialised to 0, so "playhead at frame 0" and "playhead does not
exist yet" are the same 32 bits. The sentinel is already right one field over: the f64
publish uses `pub[1] = -1` for exactly this, and port mode uses `?? -1`. **The SAB
integer is the only one of the three that lies.** Nothing is changed in the shipped path
yet; this is the diagnosis.

## A self-invalidation guard that voided seven of eight runs, using my own exhaust

The n=8 that the shipped release rate deserves was launched as eight paired calls. It
produced **one result and seven aborts**, every one of them reading:

```
  host load 78% of 10 cores
  ABORT: host at 78% — this would measure the laptop
```

and every one of them within a second of the previous run exiting. The gate was
`os.loadavg()[0] / os.cpus().length > 0.7`, and `loadavg()[0]` is the **one-minute**
average — so at the instant run N+1 started, the number it read still contained run N's
two Chromium browsers. **A back-to-back sequence could never pass it.** The guard was not
reporting a hostile laptop; it was reporting its own exhaust, already decaying.

Measured, so the fix is not a guess:

| | |
|---|---|
| idle baseline, desktop apps running | **30-40%** of 10 cores |
| what is actually consuming it | WindowServer 27%, Camo Studio 17%, VLC 10%, coreaudiod 7% |
| load immediately after a run exits | 74-79% |
| orphaned browsers from the failed runs | **0** — nothing leaked, it was purely the average |

Two consequences, both structural rather than local:

1. **The gate now WAITS instead of voiding.** It polls for up to 240 s and aborts only
   if the load is *persistent*, which is a genuinely different fact from "my last run is
   still decaying" and gets its own message. `hostLoadStart`, `hostLoadWaitedS` and
   `hostLoadEnd` are recorded in every report, because a run that started at 68% is
   evidence about itself, and the start gate is blind to load that arrives at t+60 s.
2. **`reln8.sh` is now RESUMABLE**, keyed on the JSON carrying a `result` block rather
   than on the file existing — relpair.mjs writes its JSON from a `finally`, so an
   aborted run leaves a file behind. That exact trap has already made an
   `until [ -f ... ]` wait exit instantly here. The one surviving run was kept and the
   seven were topped up, which is 35 minutes of laptop time not spent twice.

The lesson generalises past this gate: a self-invalidation guard whose input is a lagging
average of its own previous invocation will fire on itself forever, and the failure is
invisible because **every individual abort message is true**. Compare the deployment
watchdog that only counted rather than keeping the errno: a guard that cries wolf
correctly is still a guard that stops the work.

### And it changed what the run measures

The one survivor showed `baseTarget: 15` on **both** sides — the `maxTargetFrames` ceiling
already bound at settle under 5% loss — with `finalTarget` 13 on the slow side and 11 on
the fast one. The second run showed 12 and 11 at settle, rising to 14 and 12. So the
ceiling binds in some runs and not others, and what the 5%-loss regime actually compares
is **the descent off the opening transient**, not the height reached. `reln8-score.mjs`
prints that as a labelled DESCRIPTIVE column with no p-value and counts how many runs
began pinned, because the metric list was fixed before the data precisely so a quantity
noticed afterwards could not be promoted into the test.

## The ring held the OLDEST 512 ms, and one second of graph startup cost the whole call

Diagnosed in a separate session (`sab-play-zero-pins-the-ring`), left unshipped as a
diagnosis. Now fixed in `tape-app/public/pcm.js` and `pcm-worklet.js`.

`SAB_PLAY` was initialised to **0**, so `playSeqNow()` could not tell "playhead on frame
0" from "no playhead yet". The writer's accept window `lo = max(startSeq, playSeqNow())`
therefore stayed pinned to the FIRST frame ever received for the whole of audio-graph
startup: the 64-slot (512 ms) ring filled with `startSeq..startSeq+63` and rejected every
later frame as far-future, `hiSeq1` froze, and when the playhead finally started it seeded
at `startSeq` — correct and useless, because `lo` then advanced at exactly the sender's
125 frames/s and the gap never closed.

Reproduced against the REAL `pcm-worklet.js` (`testbed/pcm-origin.mjs`), sweeping D = first
frame arriving -> `await addModule()` resolving:

| D | depthMs | lostFrames | arrivals rejected |
|---|---|---|---|
| 0.95 s | 43 | 56 | 56 / 3244 |
| **1.0 s** | **-24931.4** | **3117** | **3186 / 3250** |
| 1.5 s | -24931.4 | 3117 | 3249 / 3313 |
| 3 s | -24931.4 | 3117 | 3436 / 3500 |

Closed-form cliff, which the sweep straddles: the one existing re-anchor (the ring overflow
skip) fires once and buys 512 ms, so a live frame lands iff `125D < 2*RING_F - target = 126`,
i.e. **D < 1.008 s**. One second of AudioWorklet startup on a cold or loaded machine is
ordinary, so this was not a corner case — and **every transport counter read perfect
throughout**: 125 fps, `lateFrames` 0, `pc` connected.

### The fix, and the fix that was rejected

**Rejected — worklet-side re-anchor** (where the overflow skip already lives). At D=1.5 s it
moves `depthMs` from -24931.4 to a *plausible* **-39.9 ms** and still loses **3060 frames**,
with 3249/3313 arrivals still rejected. `hiSeq1` is frozen by the WRITER, so re-anchoring the
playhead only returns it to the same stale 512 ms. **Converting an alarming number into a
believable one while the audio stays broken is this project's recurring defect class arriving
as the proposed cure.**

**Shipped — the writer re-seeds.** While `playSeqNow() < 0` (now a true sentinel), a frame
beyond `startSeq + RING_F` drops the stale window and re-anchors on itself: clear the tags,
`startSeq = seq`, republish `SAB_START`. The ring then holds the NEWEST 512 ms, which is the
only audio worth keeping when nothing is playing yet.

| D | 0.95 s | 1.0 s | 1.5 s | 3 s | 10 s | 23.4 s |
|---|---|---|---|---|---|---|
| depthMs | 40.4 | 13.3 | 16 | 40.4 | 23.2 | 31.9 |
| lostFrames | **0** | **0** | **0** | **0** | **0** | **0** |
| farFuture | 0 | 0 | 0 | 0 | 0 | 0 |

Zero lost frames and positive depth out to a 23.4 s graph delay, and even the D=0.95 s case
that already "passed" improves from 56 lost frames to 0.

Three supporting changes, all of them about the failure having been INVISIBLE:

- **`farFuture` is now published.** It counted every one of those 3186 rejected frames and
  was never exposed in `snapshot()`, so the outage could only be found by reading the source.
  A counter that exists but cannot be read is not observability.
- **`ringReseeds` is a new counter**, deliberately NOT folded into `farFuture`: the frames a
  re-seed discards were *accepted* into the ring, and calling them rejections would merge two
  different events into one number. Frames discarded is `reseeds x 64`.
- **Port mode had the identical bug in two places** and no counter at all: the worklet's
  `takeFrame` pinned to `startSeqP`, and `pendingPort` dropped silently once full. Both now
  keep the newest frames, and both are counted (`ringReseeds`, `farFutureP`, `portDropped`).

`hiSeq1` is deliberately not reset on re-seed, unlike the model: a write can only land inside
the window, so the highest seq ever written is below `startSeq + RING_F <= seq`, and the
normal `if (seq + 1 > hiSeq1)` store advances it correctly.

**What this does NOT yet establish.** `pcm-origin.mjs` drives the real worklet but a
line-for-line COPY of the writer gate, so the table above validates the DESIGN, not the
shipped implementation. The control is clean — with `--anchor=none` the edited worklet
reproduces -24931.4 / 3117 / 3249 exactly as before, confirming the worklet edits are inert
on the SAB path — but two live browsers (`testbed/pcm-graphdelay.mjs`, which must patch
`AudioWorklet.prototype.addModule` because `page.route()` does not intercept a worklet module
fetch) is the test that closes it, and it runs against the deployed page.

### The re-seed's own guard, fired rather than asserted

The re-seed hands a far-future frame the power to move the accept window, so it needed a
bound: elapsed time at the nominal 125 frames/s is the furthest a sender can legitimately
have advanced. `testbed/pcm-origin.mjs --bogus=N --bound=0|1` injects ONE frame at
`newest + N` halfway through graph startup, through the same `ringWrite`, and fires it:

| D = 1.5 s | startSeq | playSeq | depthMs | lostFrames | **frames played** |
|---|---|---|---|---|---|
| clean, bound on | 128 | 3311 | 16 | 0 | **3125** |
| one bogus seq (+1e6), **bound OFF** | **1000095** | **-1** | null | 0 | **0** |
| one bogus seq (+1e6), bound ON | 128 | 3311 | 16 | 0 | **3125** |

Unbounded, a single bogus header moves the window to seq 1000095 and **the playhead never
starts at all** — permanent, unrecoverable silence, strictly worse than the startup-only
failure the re-seed exists to fix. Bounded, it is one frame rejected as far-future and the
call is otherwise identical to clean.

Note that `lostFrames` reads **0** in the broken arm, because nothing ever played to
conceal against. `played 0` is the only column that tells the truth there — the same
one-column trap as the worklet re-anchor's plausible `-39.9 ms`.

The bound never binds on a legitimate stream: the writer sweep above is byte-identical with
it on and off at every delay from 0.95 s to 23.4 s. The model's copy of the gate was updated
to match the shipped rule, since a model that drifts from the code will vindicate the wrong
code later.

## The n=8 the release rate deserved, at 5% sustained loss

Eight paired calls, sides alternating (4 with the slow release on A, 4 on B), scored by
`testbed/reln8-score.mjs` — written BEFORE the data, metrics and sign convention fixed in
advance, arms identified by release rate read out of each report rather than by side, and
its p-value routine self-tested against 5 textbook critical values (it aborts on mismatch).
Shaper drop 5.88-5.89% in all eight runs, so the condition held throughout.

Statistic: PAIRED t-test on the within-call difference, fast minus slow. Negative favours
fast. Paired because the two arms share a call by construction and the between-call variance
a two-sample test would have to absorb is enormous here (201 vs 300 concealed frames for the
same setting).

| metric | per-run diffs | mean | p | sign |
|---|---|---|---|---|
| mean mouth-to-ear (ms) | -14.6 -9.6 -3.7 -3.4 -26.8 -1.8 -2.9 -2.1 | **-8.11** | **0.0346** | **8/8 fast** |
| last-third m2e (ms) | -7.5 -22.2 -5.3 -4.5 -29.2 -2.8 -1.3 -1.5 | **-9.29** | **0.0409** | **8/8 fast** |
| frames concealed | -9 -32 -13 **+26** -11 -7 -28 -15 | -11.13 | 0.1149 | 7/8 fast |

So the fast release wins on latency with a unanimous sign and p<0.05 on both latency
metrics, and concealment leans the same way but **does not clear significance** — one run
reversed by +26 frames. The concealment claim from the earlier n=1 runs is therefore
withdrawn at this sample size; the latency claim is not.

**Only 2 of 8 runs began with both sides pinned at the 15-frame ceiling.** The "ceiling is
bound at settle" observation from the first run was not general, which is precisely why it
was printed as a labelled descriptive column with no p-value rather than promoted into the
test after the fact.

### This still does not license changing JIT_RELEASE, and the reason is not caution

There are now TWO honest n=8 results that disagree, in different regimes and on different
instruments:

| | regime | metrics | winner |
|---|---|---|---|
| pcm.js:1313 | `--bw=0.3` bandwidth ceiling | rig p50/p95, delivered pp, lane rate | **slow** |
| this run | 5% sustained datagram loss | mouth-to-ear from `ageP50 + depth` | **fast** |

Neither overturns the other, because they are not measuring the same thing under the same
constraint. The mechanism already recorded explains the split: under a bandwidth ceiling
packets are genuinely DROPPED and buffer depth buys RS/FEC the time to repair them, so depth
prevents something; against lateness every packet arrives and depth prevents ~0.2% either
way, so it is pure latency. A single global constant cannot be right in both.

What the pair of results actually licenses is a **loss/repair-gated release** — fast when
concealment is lateness-driven, slow when frames are genuinely lost and FEC is repairing —
and pcm.js already separates the inputs (`lostFrames` vs `late` vs `fecRepaired`). That is a
control-law change, not a constant change, and this project has two buffer tunings whose
variance exploded when given more authority, plus a lateness-driven FEC ladder that was
built, measured, failed and reverted. So it needs its own paired measurement before it goes
anywhere near the shipped path. `JIT_RELEASE` is unchanged.

### Confirmed in real browsers, on the deployed code

Deployed as Version ID `27e341fb-1ba0-4225-82b1-1d5021f3afec`; `pcm.js` and `pcm-worklet.js`
verified byte-identical to local via cache-busted `curl` + `cmp`, with each part of the fix
grepped out of the SERVED bytes rather than assumed present. (The first verification attempt
read the previous file and looked like a failed asset upload; it was CDN propagation lag, and
the same check passed moments later.)

`testbed/pcm-graphdelay.mjs`, two live browsers, delay injected by patching
`AudioWorklet.prototype.addModule` — `page.route()` does NOT intercept a worklet module fetch
and injects nothing while looking exactly like a clean control:

| injected D | measured D | addModule took | depthMs | lostFrames | played | recv | fps | negative-depth samples |
|---|---|---|---|---|---|---|---|---|
| 0 s | -0.186 s | 128.4 ms | 14.7 | **0** | 3726 | 3754 | 125 | **0 / 1169** |
| **3 s** | **2.922 s** | **3125.5 ms** | **35.5** | **0** | 3418 | 3752 | 125 | **0 / 1044** |

The 3 s arm sits nearly 3x past the 1.008 s cliff. On the code deployed BEFORE this change
the same condition measured depth -22927 ms, 2866 frames concealed and 915 of 915 depth
samples negative. It now reports positive depth, zero lost frames and zero negative samples,
and the injection is PROVEN to have landed rather than assumed: measured D 2.922 s against
3 s asked for, with `addModule` itself taking 3125.5 ms.

Provenance, stated precisely: the pre-fix numbers come from the prior session's measurement
against deployment `4acefa93`, not from an arm I re-ran on this deployment. The model control
(`--anchor=none`, which still reproduces -24931.4 / 3117 / 3249 with the edited worklet) is
what ties the two together.

## The estimator does NOT learn its buffer size from the handshake (clean link)

A hypothesis of mine, tested and **refuted**, which is worth recording because it was
plausible and it pointed at the wrong lever. pcm.js:1395 says the estimator must not learn
from a call's opening because "ICE is still settling", but its guard is `dN < 64` = 512 ms,
and six SCTP associations plainly do not finish settling in 512 ms. Since `spreadHold`
releases at 1 ms/s, hold time in SECONDS equals spread in MILLISECONDS — so a 100 ms opening
transient would hold the buffer up for 100 s, and that would make the release rate a
distraction from the real fault.

pcm.js already published the instrument for this and even the reading instruction —
`jitSpreadMaxAtMs`, `jitWarmMs`, `jitSpreadMaxLate`, `jitSpreadMaxLateAtMs`, marked
"OBSERVABILITY ONLY", with "maxAt near 0 with maxLate far below the max means a startup
transient sized the whole call's buffer." It had been built and never read. `testbed/startup.mjs`
takes the reading: both sides stock (no A/B — two independent observations of one call),
sampling from JOIN, and the health gates run at the END because the opening is the subject
rather than a precondition.

Clean local link, 120 s, both sides:

| | side A | side B |
|---|---|---|
| peak spread | 46.7 ms **at t+99.7 s** | 41.9 ms **at t+99.7 s** |
| worst after the 10 s warm boundary | 46.7 ms (**100%** of the peak) | 41.9 ms (**100%**) |
| implied hold, opening vs everything after | ~47 s vs ~47 s | ~42 s vs ~42 s |
| ceiling | want peaked 7f of 15f, clamped 0 ticks | same |
| verdict | **NOT startup-sized** | **NOT startup-sized** |

The opening's spread is 4-9 ms; the worst spread arrives at t+99.7 s. Both sides agree, so the
hypothesis is refuted rather than merely unsupported on this link.

Two things worth keeping from the run. **The published running max is trustworthy**: the
harness's own observed max matched `jitSpreadMaxRun` to 0.1 ms on both sides (46.7/46.7 and
41.9/41.9) over 235 samples each — worth checking, because a published estimator max here once
read 12.9 ms on a run whose true worst was 169.7. And **both sides peaked at the same instant**,
t+99.7 s, which is the same simultaneity signature that identified the cross-engine stalls as
host contention rather than anything on the wire.

What this does NOT cover: a loopback path has no real handshake jitter to learn from, so the
clean arm is the weakest possible test of the idea. The shaped arms are the ones that matter.

### The shaped arms: refuted there too, and one of my own caveats measured false

| regime | side A peak spread | side B peak spread | ceiling clamped | verdict |
|---|---|---|---|---|
| clean loopback | 46.7 ms @ t+99.7s | 41.9 ms @ t+99.7s | 0 / 0 ticks | not startup |
| `--bw=0.3` | 214.5 ms @ **t+15.6s** | **9594.6 ms** @ **t+14.9s** | **419 / 490** ticks | see below |
| `--loss=5` | 91 ms @ t+66.0s | 113.2 ms @ t+122.5s | 0 / 3 ticks | not startup |

Under sustained loss the buffer is sized by ONGOING loss at t+66s and t+122s, not by the
opening — which is consistent with the n=8 finding that what the release rate governs is the
DESCENT from events, not their height.

**`--bw=0.3` needs care in both directions.** The peaks are at t+15.6s and t+14.9s, i.e. the
first 13% of a 120 s call — substantively an opening transient — but they sit just past
`JIT_WARM = 10 s`, so the boolean verdict called them "not startup-sized". **That boundary is
pcm.js's constant, not a measured settling time**, and this link takes ~25 s to settle because
video's congestion control has to back off first. The report now prints the peak's position as
a percentage of the call beside its position relative to the boundary, and the boolean is to be
read as "inside JIT_WARM", not as "not an opening transient".

Also from that arm: **side B measured 9594.6 ms of arrival spread**, implying `want` = 1201
frames against the 15f cap — a 45x asymmetry against side A's 214.5 ms on the same call, with
the shaper reporting 24320 of 65634 packets bw-dropped (37%). Above the cap the release rate is
inert by construction, so a release-rate A/B at `--bw=0.3` is measuring almost nothing about
the release rate.

**A caveat I pre-registered and have now measured FALSE.** `reln8-score.mjs` printed, as a
stated limit on its own result: "the 15-frame ceiling binds under 5% loss, and the release rate
cannot act above it, so any effect here is measured in a regime that partly suppresses it."
Measured: `jitClampedTicks` of **0 and 3 out of ~480**, with `want` peaking at 13f and 16f
against the 15f cap. The ceiling barely binds at 5% loss, so the n=8 effect was **not**
suppressed — the result is stronger than its own caveat allowed. The scorer has been corrected;
the pessimistic version is kept in the text there so the correction is visible rather than
silently swapped. The ceiling does bind hard at `--bw=0.3`, which is the opposite regime from
the one the caveat was attached to.

`jitSpreadMaxRun` passed its cross-check in all three regimes (harness-observed max equal to
the published max, or below it on one side at 5% loss — the expected direction, since sampling
at 500 ms sees under half the 250 ms ticks; the check is deliberately one-directional).

## A call between two real, shipping browsers — and what the test binary had been hiding

Every measurement in this project's history was made with Playwright's bundled Chromium on
BOTH ends. `testbed/realpair.mjs` drives the **real Brave** installed on this machine over
CDP, and optionally a second real Brave, so both ends of the call are browsers a user could
actually have. Deployment `32b9ca3a`, `room.tokkah.com`, 40 s calls, fake camera
`cam1080.mjpeg`, host at 22-54% of 10 cores.

Real Brave x real Brave, warm cache, unthrottled — **zero console errors, zero page errors**:

| | side A | side B |
|---|---|---|
| video lane 2 | running, no fallback | running, no fallback |
| peer clock | 197/197 pongs, offset -0.272 ms, rttMin 4.11 ms | 197/197, -0.32 ms, 3.98 ms |
| concealment | 0.712% (35/4915) | 0.671% (33/4917) |
| playout depth | 84.5 ms | 84.7 ms |
| ringReseeds / farFuture | 0 / 0 | 0 / 0 |

### The first four runs were all harness, and they looked exactly like product defects

The initial runs reported, on both ends: the custom video lane falling back to plain RTP,
the peer clock stuck at `pings 200, pongs 0`, and **182 and 199 unhandled exceptions in
40 s** — a steady 5.0/s. The chain was real but it started at the test binary:

1. `chromium.launch()` with no `executablePath` gets Playwright's **headless shell**, which
   ships no usable video encoder. Lane 2 died at t+1.14 s with
   `tape-fallback {why:"encoder-setup"}` on **every** run. `rig.mjs` has always named
   `Google Chrome for Testing` explicitly; this harness defaulted and paid for it.
2. The peer's fallback took Brave's lane down with it 4 s later —
   `lane-watchdog {framesOut:0}` -> `tape-fallback {why:"no-frames"}`.
3. `fallbackToRtp` sets `tape = null`, and TIME_SYNC's send was
   `send: (o) => tape.sendCtl?.(o)`. **The optional call guarded the METHOD, not the null
   object**, so it threw on every 5 Hz tick for the rest of the call.

Naming the full Chrome binary fixed all three symptoms at once: lane 2 `running true,
fellBack false` on both sides, peer clock `pings 200 pongs 200 offset -0.387 ms`, and the
error count fell from 182+199 to **1 each** (an unrelated 429). Concealment also halved,
0.985%/0.643% against 2.905%/2.863%, because a full RTP video stream was no longer
competing with the PCM datachannels for the same path.

**Two fixes shipped anyway, and the reason is not tidiness.** The trigger here was my own
binary, but `fallbackToRtp` exists because lanes *do* fail in the field, and when they do,
this build threw 5 unhandled exceptions per second for the remainder of the call:
- `send: (o) => tape?.sendCtl?.(o)` — app.js:3350.
- `tsync?.stop()` in `fallbackToRtp` — app.js:1872. Without it the estimator kept pinging a
  channel that no longer existed and published `pings 200, pongs 0` with a null `offsetMs`:
  a clock that looks maintained while carrying no information. A null offset has already
  produced a 637 ms "age" on an 80 ms call once, so this is the failure mode with history.

No harness in this testbed had ever listened for `pageerror`. That is the only reason a
5 Hz exception storm on the deployed site survived to be found by accident.

### D is immune to device speed, because both racers share a thread

The ring-origin defect fixed earlier needs D — first PCM frame arriving minus
`await addModule()` resolving — above **1.008 s**. On real browsers:

| condition | D, side A | D, side B | addModule took |
|---|---|---|---|
| Brave x Brave, warm | **-0.820 s** | -0.830 s | 163.1 / 163.7 ms |
| Brave x Brave, cold cache | -0.804 s | -0.765 s | 126.9 / 149.6 ms |
| Brave x Brave, **1/4 CPU** | -0.790 s | -0.779 s | 147.3 / 158.3 ms |
| Brave x Brave, **1/8 CPU** | **-0.931 s** | -0.938 s | 151.9 / 146.9 ms |

Negative means the graph wins. **Nothing erodes the margin**: an empty HTTP cache costs
nothing (the worklet module is tiny next to ~3 s of connection setup), and throttling the
device to 1/8 speed *widens* the margin rather than narrowing it. The reason is structural
and worth keeping: connection setup and audio-graph startup both run on the same main
thread, so slowing the device scales both racers together. D is a ratio, not a duration.

So the honest limit on that fix's reach: **it removes a catastrophic silent failure mode,
and I could not reach the cliff with any natural condition available here** — not engine
choice, not a cold cache, not an 8x slower device. The prior session reached it only with
an injected `addModule` delay. It stays in as robustness, not as a rescue.

### Two n=1 mechanisms withdrawn

Along the way this harness produced a 33.2% concealment run and a 7.36%/5.61% run at 1/8
CPU, and I began building a "CPU cliff between 1/4 and 1/8" story around the second. Neither
reproduced — four subsequent runs peaked at 4.38%, and a later 1/8 CPU pair with equal
settings on both ends read **0.282%/0.241% with `jitClampedTicks` 0 and target 7f**. Both are
recorded as outliers, not findings. The 15-frame ceiling was **not** binding in the regime I
had been about to A/B, which would have measured a cap that never binds for the third time
in this project's history.

The probe itself was cleared by an explicit control (`--probe=0`, four interleaved runs):
1.814% mean with it on, 1.695% with it off, against a within-arm spread of 0.46-4.38%. It
was still worth switching off, because the first version left a **100 Hz `setInterval`
calling `pcm.snapshot()` on the main thread for the whole call** and never cleared it.

## A first-time visitor on a slow device costs 6 ms of arrival spread and nothing else

`testbed/cold-score.mjs`, 6 paired calls at 1/8 CPU on both ends, **one cold side per call,
alternating which**. Per-side cold is what makes this measurable: cold-vs-warm as separate
calls has to absorb a between-call concealment spread measured at 0.24%-4.38%, which is
larger than the effect. Within one call the noise floor is **0.021 pp concealment, 3.6 ms
depth, 2.13 ms gap p99** — two orders of magnitude tighter.

Sign is COLD minus WARM, so positive means the first-time visitor paid.

| row | mean | p | sign |
|---|---|---|---|
| conceal % | -0.081 pp | 0.105 | cold **lower** 4/6 |
| frames concealed | -4.00 | 0.106 | cold lower 4/6 |
| late frames | -2.33 | 0.185 | 3/6 |
| arrival gap p99 | +0.24 ms | 0.814 | below the noise floor |
| arrival clumped % | +0.47 pp | 0.806 | 3/6 |
| **jitter spread** | **+6.23 ms** | **0.025** | **cold higher 6/6** |
| playout depth | -6.33 ms | 0.100 | cold lower 4/6 |
| graph race D | +0.002 s | 0.801 | 4/6, no effect |

So: one row moves, unanimously and significantly — the cold side measures ~6 ms more
worst-case arrival spread — and **it reaches nothing**. Concealment, lateness and gap p99 all
fail to clear their floors, and concealment's sign points the wrong way for the hypothesis.
`gapP99` not moving while `jitSpreadMs` moves 6/6 is the informative pair: both are
receiver-side arrival statistics, but spread is a near-max over a 320-sample window and gap
p99 is a percentile of consecutive spacing, so a few long stalls widen one without touching
the other. The likeliest cause is the cold page's own busier main thread timestamping
arrivals more raggedly — a receiver-clock effect, not a path effect.

Also settled here: at 1/8 CPU with equal settings, concealment is **0.02%-0.38%**. The
7.36%/5.61% run reported earlier is an outlier across ten-plus runs and is withdrawn.

## The verdict is the picture, and the picture had never been checked on a real browser

Every "clean call" claim above rested on audio counters and lane status — the exact mistake
this project has already made once, when `connectionState` read "connected" and
`framesDecoded` climbed 148 -> 208 while the remote element was 0x0 and frozen. `realpair.mjs`
now grabs the live remote surface to a 64x36 canvas and computes luma mean/sd plus a
**per-pixel FNV hash** (a global mean is nearly invariant to real motion; any single changed
pixel changes the hash).

Real Brave x real Brave, unthrottled, deployment `32b9ca3a`:

| | side A | side B |
|---|---|---|
| surface | `remoteCanvas` (custom lane) | `remoteCanvas` |
| resolution | **1920x1080** | 1920x1080 |
| distinct frames | **20 of 20 samples** | 20 of 20 |
| luma sd | 63.1-65.5 after t+2s | 65.2-67.1 |
| concealment | 0.04% (2/4939) | 0.061% (3/4941) |
| depth | 33.5 ms | 39.7 ms |

The one flat sample (sd 0.1) is at **t+0 only**, before the first frame is painted; the gate
now stores the whole series and flags flat frames after t+3s separately, because
`sd 0.1..67` as a range cannot distinguish "black for one frame at startup" from "went black
mid-call".

## Cross-engine: one call, two send configurations, both wrong in opposite directions

Real Brave x Playwright WebKit. WebKit declares lane 0, so both ends fall back
(`lane-mismatch {ours:2, theirs:0}` -> `tape-fallback {why:"peer-lane-0"}` at t+1.36 s), and
the picture survives on both ends — no black screen. But the two directions were nothing
alike:

| | Brave's sender | WebKit's sender |
|---|---|---|
| degradationPreference | **null** | maintain-framerate |
| maxBitrate | **null** | 12000000 |
| maxFramerate | **null** | 30 |
| outbound | **640x360@30**, limitedBy "bandwidth" | 1920x1080@9, limitedBy "bandwidth" |
| what the peer SAW | WebKit saw **640x360** | Brave saw 1920x1080@10 |

The Brave user got a juddery 10 fps and the WebKit user got a soft 360p. **Cause:** app.js
applied sender parameters once, inside `join()`, iterating `pc.getSenders()` — and
deliberately skipping the video sender while lane 2 was alive (`if (wantTape === 2 &&
!tapeFellBack) continue`, because setParameters rebuilds Chrome's send pipeline and starves an
attached transform). The `!tapeFellBack` half of that guard was **unreachable in the state it
describes**: the loop runs at join, the fallback happens later, and the sender that
`fallbackToRtp` creates was therefore never tuned at all. WebKit's sender had its camera on
the pc from the start, so it *was* tuned — hence the asymmetry inside one call.

**Fixed and deployed** (`587a0468`): the video branch is extracted to `tuneVideoSender(s, why)`
and re-run from `fallbackToRtp` over every video sender. Safe there for exactly the reason the
original guard gives — the pipeline rebuild only starves a *live* transform, and `tape.stop()`
has already flipped that worker to bypass.

Measured after, three consecutive runs:

| | before | after |
|---|---|---|
| Brave's sender params | all null | maintain-framerate / 12 Mbps / 30 fps / scale 1 |
| Brave outbound | 640x360@30 | **960x540@30-31** |
| what WebKit saw | 640x360 | **960x540** (2.25x the pixels) |
| WebKit's own limit | "bandwidth" | **"none"** |

Not solved, stated plainly: Brave->WebKit still reports `limitedBy "bandwidth"` at 540p, so
GCC still believes the link is tight, and Brave still receives 1080p at 10 fps.

### The dead lane keeps streaming, and it is a likely cause of that "bandwidth"

Reproducible in all three post-fix runs and both pre-fix ones: after the fallback, Brave sends
**two** video streams for the whole call — the real camera at 960x540 *and* the lane-2
carrier's flicker canvas at **320x180@30, ~1195 frames per 40 s call, libvpx,
`limitedBy "none"`** — and the WebKit peer decodes all 1195 frames of it. The carrier exists
only to give the dead lane a clock. It is competing for the bandwidth that the real picture is
being told it cannot have.

### Silencing it took the cross-engine picture from 640x360 to 1920x1080

Deployment `8740989e` adds `cs.replaceTrack(null)` on the branch that hands the camera to a
new sender, which stops the carrier sending without touching its m-line (so no extra
renegotiation). Two consecutive Brave x WebKit runs after:

| | before both fixes | after sender-params | after silencing the carrier |
|---|---|---|---|
| Brave outbound | 640x360@30 | 960x540@30 | **1920x1080@30** |
| Brave's `limitedBy` | bandwidth | bandwidth | **none** |
| what WebKit SAW | 640x360 | 960x540 | **1920x1080** |
| carrier stream | 320x180@30, ~1195 fr | 320x180@30, ~1195 fr | **gone (0 frames)** |
| concealment | 0.182% / 0.323% | — | 0.061-0.181% |

**9x the pixels for the WebKit user**, and the sender stopped claiming it was bandwidth
limited. The "bandwidth" reading was true and was caused by us: a 320x180 flicker canvas for a
dead lane was taking the room that the real picture was being denied.

Still true and worth not overstating: Brave *receives* 1080p at **9-10 fps** because that is
what the WebKit peer's encoder sends, and the two runs disagree about whether WebKit calls
itself bandwidth-limited there ("none" and "bandwidth"). That is the far end's send side, not
our configuration, and Playwright's WebKit is not Safari — so this bounds what the finding can
claim. The cross-engine jitter ceiling also still binds: `want 15 (max run 33-35)` against the
15-frame cap with ~150 clamped ticks, matching the earlier cross-engine result, now confirmed
against a *real* browser on one end rather than two Playwright builds.

## The 10 fps was never the encoder — it was our own capture ask

Task #26 opened on a wrong premise, in my own words: *"That's the far end's encoder, not our
settings."* Both halves of that were false.

`media-source` stats — upstream of the encoder — settled it in one run:

```
webkit CAPTURE  1920x1080@10   401 frames produced   <-- upstream of the encoder
webkit outbound 1920x1080@9    398 sent / 398 encoded
```

The encoder faithfully sent 398 of the 401 frames it was handed. The **camera** ran at 10 fps.

### Our constraint set caused it

Isolated with no app, no WebRTC and no encoder involved (`getUserMedia` plus a
`requestVideoFrameCallback` frame counter, on a blank https page):

| ask | WebKit gave | Chrome gave |
|---|---|---|
| **`1920x1080` + `frameRate ideal 30`** | **1920x1080 @ 10.4 fps** | 1920x1080 @ 30.1 |
| `1600x900` + ideal 30 | 1600x900 @ 10.5 | — |
| `1280x720` + ideal 30 | 1280x720 @ 30.4 | — |
| bare `video: true` | 640x480 @ 30.3 | 1920x1080 @ 30.0 |
| `frameRate exact 30` | 640x480 @ 30.2 | 1920x1080 @ 29.9 |

WebKit reported `frameRate` capability `{min:1, max:30}` throughout — the device could always
do 30. `width:{ideal:1920}` and `frameRate:{ideal:30}` are both *ideals*, and WebKit's solver
satisfies resolution first, then settles for 10 fps. Chrome's solver satisfies both.

### Only one repair formulation works

Each candidate on a **fresh** 1080p@10 track, so none inherits a previous repair:

| repair via `applyConstraints` | WebKit | Chrome |
|---|---|---|
| the same constraints again | 10.6 → 10.6 | no-op |
| **`{frameRate:{ideal:30}}` alone** | **10.6 → 30.5, resolution kept** | no-op, resolution kept |
| `{width:{exact:1920},height:{exact:1080},frameRate:{ideal:30}}` | 10.6 → 10.6 | no-op |
| `{width:{exact:1920},...,frameRate:{min:24}}` | 10.5 — **no OverconstrainedError** | no-op |

The set must contain **only** the frame rate. Naming width or height re-breaks the solve *even
when the value named is the one already being delivered*. `resizeMode:'none'` may ride along
(measured; WebKit does not implement it and reports `(unset)`), so the no-crop policy survives.

Two things worth keeping: a hard `frameRate:{min:24}` was **silently violated** rather than
rejected, so a hard constraint buys nothing and can still kill a real call. And the repair
recovered **full resolution** — this is not a 1080p-vs-30fps trade, the device could do both.

### Shipped

`repairFrameRate(track, want, full)` in app.js, called from both capture paths. Gated on the
**measured** frame rate, not the browser: a real webcam that hands Chrome 1080p15 has the same
problem. Omitting width/height lets the device legally re-solve resolution, so the outcome is
checked and reverted rather than trusted.

Deployment `bb8e2436`, verified byte-identical, real Brave x WebKit call:

| | before | after |
|---|---|---|
| WebKit camera | 1920x1080@10 | **1920x1080@29**, 1209 frames |
| WebKit outbound | 293x165@10, 231 sent, `limitedBy bandwidth` 40.1s | **1920x1080@30, 1199 sent, `limitedBy none`** |
| what the Brave user decodes | 293x165 | **1920x1080@30, 1198 frames** |
| target bitrate | 0.03 Mbps | 5.24 Mbps |

Brave x Brave regression: the repair correctly does **not** fire (camera already 30), remote
picture `1920x1080`, 20 distinct frames in 20 samples.

### Two instrument fixes this needed

`media-source` was missing entirely — without it a slow camera and a choking encoder are the
same number. And it was first stored as a single field, which made the healthy lane-2 path
print `CAMERA 320x180@60`: that is the **carrier's flicker canvas**, not the camera. Now an
array, relabelled `CAPTURE`. The harness also records every `applyConstraints` the app makes
with before/after settings, so a frame rate that was repaired and then re-broken by a later
re-solve can no longer look identical to one that was never repaired.

## Hz-compatible video, and the 30 fps cap that was never justified

The user asked for this months ago — *"if my screen allows 120hz display than that is what
i should be receiving from the my other friend on the other end"* — and a grep found **zero**
refresh-rate awareness anywhere in app.js, with everything pinned to `V_MAXFPS = 30`.

### The four ceilings, measured separately

A single end-to-end fps number cannot say which ceiling bound it, so each was measured
alone (`testbed/hzceiling.mjs`):

| ceiling | reading |
|---|---|
| this machine's display | LG UltraGear, driven at **1920x1080 @ 60.00 Hz** (`system_profiler`) |
| Chrome + `cam1080.mjpeg` | capability `max: 30` — and the file declares **25/1** |
| Chrome + built-in synthetic camera | capability `max: 20` |
| Chrome + new `motion1080_60.y4m` (`F60:1`) | capability `max: 60`, **delivered 58.9 fps at 1080p** |
| WebKit mock device, asked 60 | 15.4 fps, and **60.3 fps after `repairFrameRate`** |
| encode cost at 1080p30 | 5.24 ms/frame, so 60 fps needs ~31% of one core |

**Chrome ignores MJPEG container frame rate entirely** and honors a Y4M `F60:1` header. So
every 60 fps test against the old fixture would have measured the fixture.

`requestAnimationFrame`-derived refresh rate is **junk in headless**: 80.6 Hz and 76.9 Hz on
a 60 Hz panel, frame intervals swinging 7.1-26.2 ms. Headless WebKit gave a clean 58.8 Hz
(15-18 ms), so the method works wherever there is a real vsync.

### Shipped

`measureDisplayHz()` (median rAF interval), the rate sent to the peer over the signaling
socket exactly as face geometry already is, and `targetFps()` = min(ceiling, **peer's**
display Hz, what our camera actually delivers). The signaling relay is a blind broadcast, so
no worker change was needed.

Verified on a real call, Brave x Chromium with the 60 fps fixture:

```
chromium  apply t+1920ms {ideal 60}   1280x720@60 -> 1920x1080@60
chromium  send target 60 fps, bound by "ceiling"  (ceiling 60, peerHz 60, camera 60)
brave     inbound 1920x1080@60   2276 decoded   dec VideoToolboxVideoDecoder
```

**1080p60 end to end**, 57 fps sustained over 40 s, with the rate chosen by the receiver.

### Three of my own bugs on the way, all found by measurement

**The lobby's ask caps the whole call.** `openPreview()` hardcoded `frameRate:{ideal:30}`,
and because the lobby track is deliberately reused at join (one open per device), Chrome
**will not raise an existing track's frame rate via `applyConstraints`** — 30 stayed 30
against a 60 fps source, and `repairFrameRate` could not lift it either. Only the initial
`getUserMedia` decides. This was the whole blocker.

**Success as an absolute reverted a real improvement.** `repairFrameRate` judged itself with
`after.frameRate >= want * 0.8`. With the ceiling raised to 60 that means 48, so a camera
improving 10 -> 30 was scored a failure and **reverted to 10** — visible as a third
`applyConstraints` in the harness log. Now the test is `now > got * 1.2`: an improvement.

**I validated a robust statistic with a fragile one.** I chose the median deliberately, then
gated trust on max-minus-min and threw away every real reading: a true 60 Hz panel measured
a perfect 16.665 ms median and a 51 ms spread, because call startup drops a couple of
frames. Replaced with `lockedPct`, the fraction of intervals within 10% of the median —
100% on real vsync, **15%** on headless Chrome's fake rAF. The guard then worked on live
data: Brave printed `peer's 78.2 Hz BUT REJECTED as untrustworthy` instead of raising its
send rate on a fabricated number.

## Safari can run the good lane after all — one absent API was the whole reason it could not

Lane 2 measures **VMAF 99.7**; the plain-RTP path every Safari-family call falls back to
measured **77.6** (2026-08-01). So the entire visually-lossless picture turned on
`tapeRtpSupported()`, and it was **stricter than the code it guarded**.

WebKit 26.5 capability audit (`testbed/wkcaps.mjs`):

| lane 2 requirement | WebKit |
|---|---|
| `VideoEncoder` / `VideoDecoder` | **yes** |
| `RTCRtpScriptTransform` | **yes** (Safari shipped it first) |
| `MediaStreamTrackProcessor` | no |
| `MediaStreamTrackGenerator` | no |
| `new VideoFrame(<video>)` on a live camera | **yes** — 1280x720 NV12 |
| `requestVideoFrameCallback` | **yes** |
| `avc1.640028` (H.264 High) at 1080p | **yes** |

The generator was never needed on this lane: the receive path paints into a canvas and only
builds one `if (!ctx2d)`. And the processor has a substitute — a hidden `<video>` plus
`requestVideoFrameCallback`, one callback per presented frame, which is the cadence the
breakout box delivers anyway. `frameReader()` provides the same `read()`/`cancel()` contract
so the pump cannot tell which it got.

### The second blocker was fixed-QP, and it is a genuine downgrade

With the gate relaxed, WebKit declared lane 2 and then failed at `encoder-setup`. Cause
(`testbed/wkenc.mjs`), by testing the option combination rather than the bare codec:

| config | WebKit | Chrome |
|---|---|---|
| bare `avc1.640028` | ok | ok |
| `+ latencyMode: realtime` | ok | ok |
| `+ avc: {format:'annexb'}` | ok | ok |
| **`+ bitrateMode: 'quantizer'`** | **`TypeError: Type error`** | ok, echoes `quantizer` |
| `+ bitrateMode: 'constant'` + bitrate | ok | ok |
| `+ bitrateMode: 'variable'` + bitrate | ok | ok |

`'quantizer'` is not in WebKit's enum, so **`isConfigSupported` throws** rather than
returning false — which is why this surfaced as a bare `encoder-setup` with no detail. The
lane falls back to `variable` at the same 12 Mbps ceiling the RTP sender already carries,
and the per-frame quantizer is omitted there because WebKit **accepts the option and
ignores it** — passing it would leave the rate controller looking in charge while doing
nothing. `rateControl: 'quantizer' | 'vbr'` is in the telemetry so a VBR call can never be
read as a fixed-QP one.

### Result

Brave x WebKit, 40 s, deployment `9b6cc7f8`:

```
brave     video lane: wanted 2, running true, fellBack false
webkit    video lane: wanted 2, running true, fellBack false
webkit    tape-framesource {how: "video-rvfc"}
webkit    tape-encoder     {bitrateMode: "variable", bitrate: 12000000, rateControl: "vbr"}
brave     surface remoteCanvas 1920x1080  20 distinct frames in 20 samples
webkit    surface remoteCanvas 1920x1080  20 distinct frames in 20 samples
```

Both ends on the lane, both painting 1080p into `remoteCanvas`, zero errors and zero
pageerrors. The 320x180 outbound streams are the carrier clock, which is correct.

**MEASUREMENT DEBT, stated plainly:** the 99.7 VMAF figure was measured on the fixed-QP
arm. WebKit runs the VBR arm, and its quality is **unmeasured**. It is very likely far above
the 77.6 fallback and it is not entitled to the 99.7 number until `vmaf-call.mjs` scores it.

### Two harness fixes this needed

`tape-fallback` names the stage that failed; `tape-fail` carries the exception. The harness
collected only the first, which cost an extra deploy-and-run cycle. And the event list was a
`slice(-16)`, which let `lane0-yield` — once a second, all call — push the one-shot startup
failure out of the window entirely, so a dead lane's event list looked healthy. Now deduped
by kind, keeping the first occurrence with a count: causes precede symptoms.

---

## The carrier tick was the frame rate all along (2026-08-03)

Ritesh set his LG UltraGear to 144 Hz and asked whether a higher refresh rate increases latency.
It does not — it strictly reduces it, and the arithmetic is the whole answer: a frame that
arrives mid-interval waits for the next vsync, so the average wait is half a refresh interval.
60 Hz gives 16.67 ms intervals and an 8.3 ms average wait; 144 Hz gives 6.94 ms and 3.5 ms. That
is ~5 ms of average and ~10 ms of worst-case latency removed for no bandwidth, and it applies
even when only 30 fps is being sent, because it is the *presentation* wait not the frame rate.
Confirmed on the real display: `144 Hz (median 6.945 ms, locked 98.3%, iqr 0.02 ms, n=300)`.

The interesting part was the follow-on question. 144/60 = 2.40, so 60 fps on a 144 Hz panel is
held for an uneven 2,2,3 refresh intervals — judder with zero frames lost, the mechanism that
once made a metric report 27% judder on a healthy stream. Chasing an even cadence uncovered four
defects, three of them in the code and one in the instrument.

### 1. The good lane was pinned at 30 fps and nobody could see it

`TAPE_CFG.fps` was a hardcoded `30`, built at module load — before the camera or the peer is
known. Task #27's Hz-matching work set `encodings[0].maxFramerate`, which only the plain-RTP
FALLBACK reads. Lane 2 — the path that measures VMAF 99.7 — encodes on its own clock and never
looked at it. Fixed with `syncTapeFps()`, called before the carrier is built, when the peer's
refresh arrives, and when our own measurement lands.

### 2. Raising the ask changed nothing, because the carrier is the transport

Lane 2 substitutes its encoded frames into a carrier track's RTP packets, so **one carrier tick
carries one tape frame**. Measured on the real display at 144.9 Hz (`testbed/carriertick.mjs`,
counting frames the wire would see via rVFC on a `<video>` fed by the stream):

| configuration | ticks/s | data fps |
|---|---|---|
| `setInterval(16)` + `captureStream(60)` — **what shipped** | 59.7 | 44.8 |
| `setInterval(16)` + `captureStream(120)` | **61.9** | 46.4 |
| `setInterval(4)` + `captureStream(120)` | 119.6 | 89.7 |
| rAF flicker + `captureStream(120)` | 119.7 | 89.8 |
| rAF flicker + `captureStream()` | 143.6 | 107.7 |
| **no flicker** + `captureStream(120)` | **0** | 0 |

Row 2 is the finding: **asking for double the rate bought 2.2 ticks.** `captureStream` emits only
when the canvas CHANGES, and a 16 ms flicker can dirty it just 62.5 times a second. Two ceilings
were stacked and the one being tuned was not the binding one. Row 6 shows the 1 px flicker is
load-bearing rather than decorative. The flicker now runs on `requestAnimationFrame`; the timer
stays as a floor because rAF does not fire in a hidden tab.

### 3. Our own tuning was the tighter of the two limits

`tuneVideoSender` applied `maxFramerate = targetFps().fps` to every video sender it was handed,
including the carrier. Measured: `outbound 320x180@30` on the tuned side against `@49` on the
untuned one. None of the picture's sender parameters mean anything on a carrier whose pixels the
transform discards — same shape as the dead-carrier defect of 2026-08-03 earlier the same day.

### 4. Paired result, both sides equal per arm

`?ctick=0` is the control. WebKit peer, 72 fps fixture:

| | control | fast carrier |
|---|---|---|
| encoded | 35.9 fps | **56.9 fps** |
| peer PAINTED | 35.9/s | **56.7/s** |

Mainstream Chromium path with all three fixes: **encodes 64 fps, real Brave paints 64/s** at
1920x1080, 20 distinct frames in 20 samples, audio conceal 0.08%/0.14%.

### What this cost, and what is NOT established

Identical content, only the rate changed: `fpsmax=30` gave 5.89 Mbps at rcQp 28.5; `fpsmax=72`
gave 6.33 Mbps at rcQp 36.4. 2.16x the frames for +7.5% bandwidth, paid for in quality — the
budget is GCC-derived and roughly fixed, so more frames means fewer bits each.

**That exchange rate is NOT established.** A third run at `fpsmax=36` returned rcQp 37.9 at only
2.52 Mbps — worse QP on *less* bandwidth — which proves the GCC budget varies enough between
runs that n=1 per arm cannot measure this. The QP cost of 72 fps is real in direction and
unquantified in size. VMAF on identical content at 30 / 48 / 72 is the outstanding gate.

### The instrument lied twice, in the flattering direction

- `mbpsAtFps` multiplied bytes-per-frame by `cfg.fps`, the **asked** rate. The moment the ask
  became settable, a lane delivering 45 fps against an ask of 72 would have reported its
  bandwidth 60% high. Now built from a measured 240-sample window.
- The skip breakdown printed 3 of 5 causes, so a run showed `skipped 10.7/s` over
  `buffered 0, encQueue 0, decodeStalled 0` — a cause column summing to zero against a non-zero
  total, which reads as a broken counter rather than an incomplete report. `skipPaced` was the
  answer. The harness now reconciles the sum and prints the unattributed remainder.

### Cadence, and what it deliberately declines to decide

`targetFps()` steps down to the largest whole divisor of the peer's refresh rate, with two
budgets: 15% of the frames when the ratio is >= 2 (a 2-vs-3 hold is a 50% duration error), and
50% when the ratio is under 2 (some frames get one refresh and some get two — a 100% error, and
unfixable above hz/2). Six of seven representative cases now land on an even cadence.

The seventh is left alone on purpose: a 30 fps camera facing a 144 Hz display would have to drop
to 24 to divide evenly, and **whether 24-even beats 30-uneven is unmeasured**. The budgets are
chosen so that question only arises where the cost of guessing wrong is small.

A send-side ceiling nobody expected: a canvas cannot be captured faster than the compositor
paints it, so **our own** refresh rate caps what we can deliver — measured 1.66 ticks per data
frame, hence ~60% of own refresh. A 60 Hz sender tops out near 36 fps regardless of camera and
peer. That lands on 144/36 = 4 exactly, so the limitation produces an even cadence for free.

## The contradiction was a disconnected knob (2026-08-03)

Two honest n=8 results disagreed about the audio jitter buffer's release rate. Fast release
(8 ms/s) won 8/8 on latency at 5% loss; slow release (1 ms/s) won an earlier n=8 at
`--bw=0.3`. The standing conclusion was that a single constant could not be right and the
buffer needed a **gate** between the loss regime and the bandwidth-starved regime.

There is no contradiction. In the bandwidth-starved regime the release rate **cannot reach
the output at all.**

```js
spreadHold = Math.max(spread, spreadHold - JIT_RELEASE);   // the only line JIT_RELEASE touches
const raw  = Math.max(cfg.targetFrames, Math.ceil(spreadHold / FRAME_MS) + D_MARGIN_FRAMES);
const want = Math.min(cfg.maxTargetFrames, raw);           // raw > cap  =>  spreadHold DISCARDED
```

`want` is the clamp whenever `raw > cap`, no matter what `spreadHold` is. So on a clamped
tick both arms of a release-rate A/B run the identical control law.

`testbed/relsweep.sh`, four bandwidths, both arms paired inside one call, 48 samples each:

| link | target over the run | release rate |
|---|---|---|
| 0.3 Mbps | `15f x46, 14f x2` | **disconnected** |
| 0.8 Mbps | `15f x48` | **disconnected** |
| 1.5 Mbps | `15f x48` | **disconnected** |
| 2.5 Mbps | `8f..15f`, spread | connected |
| 5% loss (the other n=8) | `10f..15f`, mostly 11-13f | connected |

At 1.5 Mbps the two arms' depth curves are superimposable — 122.6 ms and 122.7 ms at
t=44.1 s — which is what a null test looks like. **The pro-slow n=8 was a noise-floor
measurement of a knob with no authority.** A single constant is right and it is the fast one.
No gate. And contrary to what this entry first said, the fast value did NOT already ship —
`pcm.js` defaulted to 0.25 (1 ms/s, the slow one), held there by exactly the void result.
Shipped 2026-08-03: `JIT_RELEASE` default 0.25 → 2 (8 ms/s), Version 36e26723.

### The noise floor it accidentally measured

Three bandwidths, lever provably inert, mean-depth difference between arms: 6.1 ms, 8.9 ms,
3.0 ms. So **~9 ms of mean depth is this rig's n=1 noise floor** in a shaped regime. The one
connected point (2.5 Mbps) showed fast ahead by 9.4 ms at equal concealment (0.290% vs
0.236%) — the right direction, and it does *not* clear the floor at n=1. Direction only.

### What the starved regime is actually costing

`maxTargetFrames = 15` at 8 ms per frame is a 120 ms ceiling, and under shaping the depth
ratchets straight up to it: 45 ms at t=0 to ~123 ms at t=44. **The cap is the latency in
this regime, and it is the only knob with authority here.** At 0.3 and 0.8 Mbps both arms
concealed **zero** frames while carrying 94-100 ms of buffer, so the buffer is
over-provisioned by an unknown margin — unknown because [[a-deeper-buffer-cost-nothing]]
records a predicted +80 ms that measured as a *fall*, and this project does not publish
reasoned exchange rates. `--jbmaxA/--jbmaxB` now pair the cap inside one call to measure it.

### The guard, so this class of error announces itself

`relpair.mjs` now prints **LEVER AUTHORITY**: the cap, `want` at its peak, and what
percentage of estimator ticks were clamped. Over 90% clamped with equal caps and it refuses
the verdict in both directions instead of reporting a winner. The check inverts when the
caps themselves differ — there, clamping is the mechanism under test, and an *unclamped* run
is the same mistake with the roles swapped, so under 50% clamped is the refusal.

## The VBR arm is not a downgrade — the 12 Mbps default is (2026-08-03)

Every quality figure lane 2 has ever produced was measured on the **fixed-QP** arm. Safari
cannot run that arm at all: `bitrateMode: 'quantizer'` is not in WebKit's enum, so
`isConfigSupported()` **throws** rather than returning `{supported: false}`. Safari-family
calls therefore run a VBR arm whose quality had never been scored, and the file already
described it as "a real downgrade" on no evidence.

Scoring it needed WebKit as the *sender*, which is impossible: Playwright's WebKit ships its
own built-in mock camera and takes no fixture file, so there is no reference frame to score
against. The unmeasured thing was never WebKit though — it was **VBR**. `?l2rcmode=vbr`
forces the fallback arm on Chromium, which measures the actual unknown against the real
1080p fixture through the existing capture rig, without confounding engine with rate control.

Three arms, one machine, back to back, `cam1080.mjpeg`, 54-55 stills each:

| arm | rate control | Mbps | VMAF | sd | p5 | worst | SSIM | PSNR | ageP50 | fEnc |
|---|---|---|---|---|---|---|---|---|---|---|
| `qp=24` | fixed QP | 6.41 | 98.338 | 1.305 | 96.29 | 93.89 | 0.984 | 37.171 | 19.4 | 842 |
| `l2rcmode=vbr&l2vbrbps=6400000` | VBR, cost-matched | 6.37 | 98.669 | 1.156 | 96.69 | 96.48 | 0.984 | 37.170 | 20.5 | 841 |
| `l2rcmode=vbr` (ships) | VBR, 12 Mbps default | 11.96 | 99.730 | 0.649 | 98.65 | 96.12 | 0.986 | 37.717 | 30.0 | 780 |

**On this fixture, at matched cost, the two rate controls are indistinguishable.** VMAF 98.34
vs 98.67 is t=1.40, p≈0.17 on unpaired frames; PSNR agrees to 0.001 dB and SSIM to three
decimals. The blanket "real downgrade" claim was wrong.

**One fixture was not enough, and running the second one changed the verdict.** Repeating all
three arms on `motion1080.mjpeg`:

| arm | Mbps | framesIn | framesEncoded | **missing** | ageP50 recv | VMAF* | p5* |
|---|---|---|---|---|---|---|---|
| `qp=24` | 6.33 | 846 | 828 | 18 | 23.2 ms | 99.799 | 100.0 |
| VBR cost-matched | 6.36 | 842 | 703 | 139 | 28.2 ms | 97.797 | 80.4 |
| VBR 12 Mbps (ships) | 12.01 | 830 | **365** | **465** | **128.1 ms** | 88.150 | 57.4 |

\* **The VMAF column on this fixture is not trustworthy** and is shown only for shape.
Content alignment degrades badly here — median match MSE is 27-31 for *every* arm, including
the one scoring 99.8, against 0.40 on `cam1080`. Worse, it degrades WITH the frame loss
(p95 MSE 30.2 / 34.0 / 53.1), so an arm that drops frames is also scored against
worse-matched source frames. Part of that 11.6-point gap is real artifacts and part is
misalignment, and this run cannot separate them.

**What survives the confound is enough on its own.** `framesIn`, `framesEncoded`, `ageP50`
and the bitrate are direct counters that owe nothing to alignment, and they condemn the
12 Mbps default outright: **double the bitrate, 44% of the frames, and 5.5x the receiver-side
frame age.** The missing-frame count scales with the bitrate *ask* (18 -> 139 -> 465), which
is backwards for a link story and points at the encoder — but the cause counters were not
being captured, so that mechanism was a guess and `vmaf-call.mjs` now records all five skip
causes plus `encQueuePeak` and `rcQp`. This is the arm every Safari-family call runs.

### Two things the harness had to be taught first

- `--out` is a flat directory and `dist_NNN.png` / `run.json` are fixed names, so pointing
  two arms at one `--out` **replaced the first arm's captures with the second's** and left a
  directory that looked like a complete run. It happened on the first attempt. `vmaf-call.mjs`
  now reads any existing `run.json`, and exits 2 if its `tag` differs from this arm's.
- The 99.7 on file for fixed QP was measured at **30 fps**; today's fixed QP at the new
  72 fps default scores **98.34** on the same fixture and script. Suggestive that the frame
  rate costs ~1.4 VMAF at constant QP, but it is a different-day comparison and this project
  does not accept those — the interleaved 30/48/72 run is still the gate.

### The fix: VBR now tracks the GCC budget (shipped 2026-08-03)

The pacer reconciliation named the mechanism exactly: on hard content at a fixed 12 Mbps,
`skipPaced` was 348 of 352 missing frames. In fixed-QP mode the rate controller fits the
encoder to the link by moving QP; in VBR mode the encoder ignores the quantizer, so nothing
fit the encoder to the link and the pacer inherited the whole mismatch. `rcVbrRetune()` now
reconfigures the encoder's bitrate whenever the polled GCC budget moves >15%, parity share
deducted — the same budget the QP loop would have used. An explicit `?l2vbrbps=` pins the
rate (the measurement hook stays a measurement hook).

| | before (12 Mbps fixed) | after (budget-tracked) | fixed-QP reference |
|---|---|---|---|
| hard: delivered | 365/830 (44%) | 577/735 (79%) | 828/846 (98%) |
| hard: recv ageP50 | 128.1 ms | 26.9 ms | 23.2 ms |
| easy: delivered | 780/860 (91%) | 666/675 (98.7%) | 841/860 (98%) |
| easy: ageP50 | 30.0 ms | 19.2 ms | 19.4 ms |
| bitrate | 12.0 Mbps | 5.8 Mbps | 6.3-6.4 Mbps |

Residual: hard content still loses 21% to pacing against fixed QP's 2% — the 1 s budget poll
plus 15% hysteresis cannot follow per-frame size bursts the way the QP integrator does. That
is the real, now-measured cost of WebKit's missing quantizer mode, and it is a fraction of
what the placeholder was costing.

## The 120 ms ceiling is a dial, not a defect (2026-08-04)

`testbed/capn.sh`, n=8 paired (4 per ordering, sides alternating), `--bw=0.8`, release rate
pinned equal (2) on both sides, LEVER AUTHORITY confirmed on every run (the lower cap
clamped ~100% of ticks; both clamped when equal).

| | 8f / 64 ms cap | 15f / 120 ms cap |
|---|---|---|
| depth, last third | 62.7-67.1 ms | 113.6-119.8 ms |
| lo-minus-hi depth | −50.2 … −55.6 ms, **8/8** | |
| concealment, mean of 8 | **2.93%** | **1.33%** |
| lo-minus-hi lost | −163, +347, +132, +80, +108, +132, −6, +76 (6/8 positive) | |
| null floor (8f/8f) | dDepth 0.9 ms, dLost 1 | |

**The hypothesis this experiment was built on is refuted.** The sweep had shown zero
concealment at 0.3/0.8 Mbps under the 15f cap and I read the 94-100 ms carried as free
latency. With the caps actually contrasted inside one call, the 64 ms cap gives back ~52 ms
of latency 8/8 — and pays ~+1.6 pp of concealment for it, 6/8, high variance. The ceiling's
extra 50 ms was buying real protection on a starved link. (The sweep's zero-concealment
reading also did not survive: its arms ran asymmetric release rates and a different build —
at matched fast release even the 15f sides conceal 0.27-3.32% here.)

**Disposition: default stays 15f.** A 2.9% concealment rate is 36x the clean-link figure and
audible; 52 ms is large but not worth that. What this buys the project is a PRICED dial:
64 ms of ceiling = ~52 ms of latency = ~1.6 pp of concealment at 0.8 Mbps. If a gate is ever
built (starved-link detection freeing the cap when FEC has headroom), this is the number it
has to beat. Not building it now — the residual variance (sign flipped in 2 of 8) says the
mechanism has another input this design did not hold.

## The frame-rate/quality exchange, finally on one fixture (2026-08-04)

`testbed/fpsquality.sh`, 3 reps per rate interleaved and rotated, fixed QP 24, 72 fps
fixture, alignment MSE ≤ 1.7 (trustworthy, unlike the motion1080 VBR scores). The first
attempt used the 30 fps camera fixture and all three arms measured identical — the fourth
occurrence of the stimulus being the bottleneck. GCC settled every arm at ~5.7 Mbps, so this
is the exchange AT A ~5.7 Mbps BUDGET:

| ask | VMAF (3 reps) | p5 worst | delivered fps | recv age |
|---|---|---|---|---|
| 30 | 90.01, 89.94, 89.82 | 86.2 | ~21.6 | 42-53 ms |
| 48 | 88.66, 87.59, 87.96 | 85.7 | ~34.5 | 48-69 ms |
| 72 | 85.36, 85.95, 86.18 | 80.3 | ~44 | **114-127 ms** |

Within-rate spread is ≤1.1 VMAF; the between-rate steps (−1.9, −2.3) clear it. At a fixed
budget, more frames = fewer bytes per frame = softer picture, plus a congestion cost the
fixed QP exposes brutally: the 72 ask delivered only 82% of captures and carried 2.4x the
frame age. Production runs adaptive QP, which converts that congestion into a QP rise
(28.5 → 36.4 measured earlier) instead of lateness — same exchange, different currency.

**Disposition: the 72 ceiling stays, and stays a CEILING.** It only binds when camera,
displays and link all allow; on a ~6 Mbps budget the rc already pays for it in QP. The open
question worth a future task is a budget-aware ask — dropping the requested fps when
rcBudget is low would buy 4+ VMAF and half the age on constrained links. Not shipped: the
threshold would be a reasoned constant, and those get measured first here.

## Eight cores of synthetic load do not reproduce the Safari 8× (2026-08-04)

`testbed/loadn.sh`: Chrome-to-Chrome, unshaped, a burner spawned by the script itself for
t=35..65 of each 90 s call — before/during/after within one call, each call its own
control. First pass used ONE spinner and moved concealment by at most 6 frames; escalated
to EIGHT spinners on this 10-core host (the all-cores pressure a busy laptop actually has):

    h-b1  before 0   during 6   after 7    (depth peak 23.3)
    h-b2  before 0   during 0   after 0    (16.8)
    h-b3  before 0   during 0   after 0    (20.0)
    h-n1  before 0   during 0   after 0    (17.3)  null
    h-n2  before 0   during 2   after 0    (21.0)  null

Burner arms are indistinguishable from nulls. The cross-engine hypothesis — WebKit media
processes at 86-103% of a core, scheduler lateness tripled, 15/16 stalls coincident — is
NOT explained by generic CPU pressure: whatever the WebKit peer does to this pipeline, it
is something about HOW its media work is scheduled (QoS class, priority inversion against
our worklet), not how much of it there is. Verdict for the 8×: engine-specific, and the
next honest step needs a real Safari, which cannot be automated from here (Allow Remote
Automation is a browser security setting and stays where the user set it).

## The sliding window is wired in, behind a sender-side flag (2026-08-04)

core/pcmsw.js is now imported by pcm.js. `?pcmsw=1` switches that SENDER's parity from
RS(10,10+n) to the window code (T_PAR_SW, 8 B header: type | s mod 256 | u16 bitmap |
u32 end); every receiver decodes BOTH types unconditionally, so one call can carry one
arm per direction and testbed/relpair.mjs (--swA/--swB) pairs the codes inside a single
call — judged at the OPPOSITE side's receiver, which the harness's attribution block
spells out per run. Stride is the code-rate knob, sender-local like fecN, driven by the
same T_LOSS ladder through overhead equivalence (stride = K/n, floor 2, n=0 = off) or
pinned by `?pcmswstride=`. Repairs take exactly the RS repair path (same ringWrite, same
repaired/late counters), so every existing readout prices both codes on one scale.

One corruption class was closed before deploy rather than after: the wire bitmap is u16,
and skipped oversize frames stretch the encoder ring's seq span, so a member could land
at offset ≥16 — folded into the symbol but unnameable in the bitmap, which the receiver
would solve into confident garbage. The encoder now folds only members the bitmap can
name. Self-test (variable-length frames, 20k frames per law): 5% iid 0.00% unrecovered,
repair delay p50 1 frame p95 7; 10% iid 0.54%; 3-bursts 0.00%. Block RS is still the
default; the swn8.sh paired A/B decides whether that changes, and redundancy-is-
congestion says the --bw=0.8 scarcity run must pass too before any default moves.

## The window sweeps block RS at 5% loss — 8/8, both metrics, full authority (2026-08-04)

`testbed/swn8.sh`: paired inside one call (sender-side flag, arms judged at opposite
receivers), sides alternated across 4 reps, null first. 5% iid both directions, both arms
on their shipped adaptive ladders, 60 s steady window per call:

    null (both RS)   A 44f / 97.7 ms     B 62f / 95.6 ms
    r1a  WINDOW 11f / 56.2 ms   RS 59f / 101.0 ms      r1b  14f / 64.6   50f / 94.6
    r2a         10f / 48.0      58f /  96.8            r2b  14f / 54.2   66f / 98.2
    r3a         16f / 53.3      67f / 109.7            r3b  11f / 64.6   56f / 97.4
    r4a          6f / 52.6      72f /  98.6            r4b  11f / 48.6   55f / 99.4

    window better on concealment 8/8, on e2e 8/8. Mean deltas: −48.8 frames (≈5× less
    concealed speech), −44.2 ms end-to-end.

The null call's RS numbers sit exactly among the paired RS arms, so the deltas are the
code, not the sides; the win holds with the window on either side; and the direction has
zero variance across 16 opportunities — a derived quantity this repeatable needs no
t-test (see "Zero variance is the strongest signal"). WHY both metrics move together:
with block RS the buffer must hold audio while an 80 ms group span closes before a
position-0 repair even exists; the window's repairs arrive p50 one stride (8 ms) after
the loss, so the jitter estimator sees less spread AND more repairs beat the playhead
(late repairs 9-24 vs RS's shape). One gate remains before the default moves: --bw=0.8
scarcity (swbw.sh), where parity feeds the queue and the window pays 3pp more overhead.

## The window passes the scarcity gate — and the gate itself needed fixing twice (2026-08-04)

The regime that killed the lateness-driven ladder (redundancy-is-congestion) does not
kill the window. Paired inside one call at 0.8 and 0.7 Mbps, full-authority runs only:

    0.8  r1a  WINDOW   5f   RS 119f      0.7  r1b  WINDOW  6f   RS 18f
    0.8  r1b  WINDOW  16f   RS  16f (tie) 0.7  r2a  WINDOW  9f   RS 13f
    0.8  r2a  WINDOW  11f   RS  71f      0.7  r2b  WINDOW  0f   RS 17f
    0.8  r3b  WINDOW   7f   RS  81f

    6 wins, 1 tie, 0 losses. e2e flat at the cap in BOTH arms (~120 ms) — the window's
    3pp extra top-rung overhead does not feed the queue, because its stride ladder sheds
    parity under the same T_LOSS signal fecN does.

The harness fought this measurement twice, both times by measuring the wrong thing:
 1. The shaped-baseline gate read CONCEALMENT to ask "is the shaper binding?" — but
    concealment is a post-repair number and the repair was the thing under test. The
    window side read 0.000% under a shaper dropping 39,682 packets, and the gate aborted
    the run as "not binding". Fixed: for swfec runs, ask with raw pre-repair loss.
 2. Raw loss ALSO read 0% at 0.7 Mbps — a rate the lane cannot fit under — because at
    hard scarcity the queue absorbs the constraint as LATENESS: frames arrive 100+ ms
    late but arrive, and the seen-ring counts an arrival, however late. Binding shows up
    in loss OR depth; the gate now accepts either, and settle must reach steady state
    (a 15 s baseline caught the queue mid-fill at 41.6 ms depth; 30 s reads it bound).
Also caught by the guards, not by luck: one run with e2e −189.8 ms (broken clock)
refused itself with authority none. A refusal is not a loss; it is the instrument
declining to lie.

Separately: --bw=0.8 turns out to sit ON the compressed lane's ~0.75 Mbps floor
(chrome-capture-is-not-bit-transparent), so whether it binds flaps per direction and
run. For future scarcity work use 0.7 or lower, or expect the binding gate to cull.

## SHIPPED: the sliding window is the audio FEC default (2026-08-04)

app.js: `pcmSw: QS.get('pcmsw') !== '0'`. Both gates passed (8/8 at 5% loss with
−48.8f / −44.2 ms means; 6/1/0 under scarcity). `?pcmsw=0` is the block-RS control arm
and interoperates (measured post-flip: 49-55f at ~94 ms — RS's historical numbers).
relpair.mjs appends pcmsw to the URL only when --swA/--swB was actually passed, so a
flagless run measures the deployed default rather than silently rewriting it into an arm.

## The window at 10% loss: 4.4× less concealment, +10 ms e2e (2026-08-04, n=1)

One paired call, full authority: WINDOW 47f / 112.7 ms vs RS 205f / 102.2 ms over 60 s.
The concealment ratio holds from 5% (5x there, 4.4x here — the self-test's 0.54%
unrecovered at 10% iid was honest). The e2e sign FLIPS at this rate: the window holds
~10 ms more buffer than RS at 10% loss, worth watching if this regime ever matters, but
delivery-weighted it is not close — 1.26 s/min of speech saved against 10 ms of latency
(the delivery column decides, latency-needs-a-delivery-column). n=1; enough for today.

## Live-only session: five features, three instruments, two honest retreats (2026-08-11)

Ground rule for the whole session (operator directive): every verdict from live calls
on the production edge — no local servers, no shaped links, no synthetic rigs. What a
loopback-through-prod call CAN judge: plumbing end-to-end, off-arm inertness, connect
timing, latency decomposition, engage/disengage logic. What it CANNOT: behaviour under
real loss (no loss to have) — those features ship default-on with control flags and the
verdict deferred to real-call telemetry (dupSent/dupRecv, rc-duress).

**Presence renderer** (`presence-core.js`, default ON): six early reflections,
interaurally asymmetric, direct path untouched at unity. Live: both sides render, off
arm null, 0 ms concealed. **Burst shield** (frame twins 24 ms apart on opposite
stripes above the ladder's top rung): the LIVE arms found the auto-trigger firing on a
pristine path TWICE — first the fast loss window alone (stripe reordering at open
reads as loss; now needs slow-window corroboration at half-cap), then the slow window
too (the sender's own skipped seqs while associations open are honest loss for
~2.5 s; auto-engage now deaf for the first 6 s). Force arm: 1098 twins sent, 1098
accounted, 0 ms concealed. **Video duress coupling**: pcm.duress() (2=shield, 1=upper
ladder) quarters/halves the video budget in rcPollBudget — live: 4.77 → 1.10 Mbps
under a forced shield, control arm unmoved. **WS pre-dial**: the second joiner's
472 ms click→connected decomposed (room log) as 241 dial+welcome / 75 offer-gen / 12
ICE / 144 DTLS-stripes; the lobby now dials in hold state (accepted, not admitted —
no slot, no relay, no registry stamp, 120 s timeout) and the click sends
{type:'join'}. Live A/B, 5 calls/arm: median 565 → 347 ms, −39%, zero overlap.
Full-room probe: third joiner gets the honest message, no recovery storm, the
standing call untouched.

**Instruments**: mouthToEarMs (8 + age p50 + depth + outputLatency) and
glassToGlassMs (fullAge p50 + present p50) in every snapshot, both on the anonymous
health beat with humanGapMs. Getting glassToGlass honest found the #14 present probe
fed only from the legacy paint-on-arrival path — the v-presenter and the avsync
scheduler (the paths that actually present) never stamped, so presentLag had read
null or warmup-bias on every default call since they shipped. Both stamp now; live:
present p50 8–9 ms, glassToGlass ~36 ms.

**Retreats, recorded**: (1) latencyHint-0 fix for the Lane-A default-on mismatch
REVERTED unproven — the A/B confounded when the Mac's audio sink went Bluetooth
mid-experiment (~300 ms in BOTH arms); retry condition pinned in onset-monitor.js
(control must read ~34 ms). The instrument's first decomposition made the lesson
plain anyway: 340 ms mouth-to-ear was 305 ms Bluetooth + 36 ms pipeline — the device,
not the network, owns the latency on that setup. (2) The first health-beat probe
watched only the send and missed the server 400 (allowlist knew the new fields,
HB_FIELDS had no validators) — beacons are judged by response status now.

Addendum, same day: the whole stack verified on WEBKIT live (Playwright WebKit —
real Safari needs "Allow remote automation" enabled on this new Mac, still pending).
Cross-engine call WebKit<->Chromium on prod: connected, real picture both ways,
conceal 0.11-0.29%. WebKit-side posture probe: mode sab (crossOriginIsolated true),
presence rendering (576k samples), aec2 adapting, mouthToEar 54.7 ms, zero page
errors. Today's features are not Chromium-only.

Same day, later: REAL Safari (safaridriver, remote automation enabled) <-> Chromium
live on prod: PASS - connected, tape lane running (no fallback), conceal 0.091%,
lossless lane 1.09 Mbps, real picture both ways.

Same day: the latency-floor A/B re-ran clean (BT sink gone, control 26 ms) and WON:
floor hint outputLatency 26->20 ms, age p95 8.2->4.6 (device buffer sets arrival
spread), jitter target 3f->2f, mouthToEar 62.6->45.6 ms median, 0 concealment in all
6 calls. Default flipped; ?lat=int is the control arm.

## First iOS call: mobile Safari (simulator) <-> desktop, live on prod (2026-08-11)

iPhone 17 Pro simulator (iOS 26.5), mobile Safari, ?synthmedia=1; desktop Chromium
peer; room ios-sim-first. CONNECTED: desktop received the sim's lossless lane (4067
PCM frames, mode sab — SharedArrayBuffer WORKS on mobile Safari) and 1280x720 video;
the lobby pre-dial adopted an open socket on iOS (predial-adopt {open:1}, welcome at
1.6 s). Two real defects found, filed:
- UX: the first joiner waiting ALONE >12 s is told "couldn't join: signaling
  timeout" while still actually joined — the call formed fine when the peer arrived
  at t=33 s. Likely the same experience behind the Aug 7 fleet give-ups.
- AEC2 on iOS froze at erleDb -13.16 (adapting:false, value identical across
  ticks) vs the desktop's healthy -0.28 adapting; desktop concealed 4.9 s of sim
  audio in the same call. Sim audio clocks are shaky — needs reproduction before
  judgement, but it gates real-iPhone speakerphone validation.

Correction to the iOS-call entry: the \"signaling timeout\" was NOT a pre-existing
UX flaw - it was the pre-dial commit's own regression (adopted-OPEN sockets never
fire onopen; the join gate awaited it). Fixed and verified live on both surfaces.
Lesson recorded: rigs must read the words on the screen, not only pc state.

AEC2 do-no-harm gate shipped same day: filter learns always, delivers only at
ERLE >=3 dB (hysteresis at 1). Live iOS retest: gate 0, erle ~-0.8 shadow (was -13
frozen), desktop concealment of iOS audio 4912 -> 32 ms. Gate-open awaits real air.

iOS soak, 2 min live: conceal 80 ms / 14976 frames (0.067%), depth 27-36 ms, gate
closed throughout - mobile Safari is a healthy surface post-gate (was 15% conceal).
Also: humanGapMs proven end-to-end on a 90 s conversation call (20 transitions,
median 800 ms = the fixture's scripted pauses; beat accepted 200/200).

P0 found and fixed same day: the one-line embed NEVER worked - frame-ancestors
'none' refused every embedding site since embed.js shipped. Now '*' (deliberate;
see worker.ts comment), X-Frame-Options dropped, and embed-call.mjs holds the line:
embedded iframe <-> app peer live on prod, 1503 frames, port mode, 32 ms conceal.

10-min live soak on the latency-floor default: NO RATCHET. Depth held 13-21 ms
(2-3f target) for the full 600 s, mouthToEar 43.7-51.5 ms, conceal 48-56 ms total
(0.008%). The 2f posture is stable over long calls, not just 30 s rigs.

Connect-time, the remaining slices, CLOSED as dead ends: the 75 ms welcome->offer
gap is ~2 ws RTTs of DO relay (A's own peer-joined->offer-tx gap is 5 ms), and the
144 ms DTLS/stripe phase is handshake RTTs on 7 already-parallel connections.
Neither is client work; shaving them means moving signaling off the DO round-trip
path, which is not a low-hanging fruit. Recorded so nobody re-chases them.

Away presence shipped: iOS backgrounding now NAMES itself at the peer (status +
telemetry) instead of mystery silence. Verified live: sim HOME press -> desktop
status flip <1 s -> clear on return. iOS-only find; desktop Safari never suspends.
