# The picture's own evidence

Why one end of a call looks perfect and the other looks like a mosaic, and what
to do about it. Two separate faults produce that symptom. They are not the same
bug and only one of them needs new code.

## S1 — the shipped quality ladder has a rung that is a broken picture

`git show HEAD:mac/Sources/tk/VQuality.swift` →
`LEVELS = [0.3, 0.5, 0.6, 0.7]`. Released 0.46.0 carries the `0.3` rung:
**35.6 dB at 0.089 Mbps of 1280×720**. That is not a degraded picture, it is a
mosaic, and it is exactly what "one app is highly pixelated while the other is
perfect" looks like — the retreat is per-direction by design, so the end whose
uplink is congested drops to the floor and its peer, sending over a fine uplink,
does not.

**This is almost certainly what the user saw, and the fix is already written.**
The working tree is `LEVELS = [0.5, 0.6, 0.7]`. It ships on the next release; no
new work, and the ladder reads `level N/2` with no other change because
`VQuality.swift:151` already prints against `ceiling`.

Consequence for sequencing: **release before investigating further.** A second
report of pixelation after that release is evidence for S2; a report gathered
before it is evidence for nothing.

## S2 — video receive loss never reaches the sender. Not one byte of it.

Confirmed in the code, not inferred. `Net.swift:763-770`, the whole of
`Wire.appendRxReport`, reports `reportRing.concealLost` and
`reportRing.recovered` — a `RecvRing`, and both counters are audio-only
(`Net.swift:179`, `:184`). `TPKTX = TPKT + 8` (`TimeSync.swift:55`), so the wire
has room for nothing else. `vasm`, the `VideoAssembler`, is a **local variable**
of `recvLoop` (`Net.swift:879`) and is not reachable from `appendRxReport` at
all.

Every video decision currently made on **audio** loss:

| site | decision | actually steered by |
|---|---|---|
| `main.swift:2556` | `wire.videoParity` — video FEC on/off | peer's audio ring |
| `main.swift:2572-2575` | retreat above a 2% harm rate | peer's audio ring |
| `main.swift:2582-2585` | `vq.tick(framesLost:)` — the picture ladder | peer's audio ring |
| `main.swift:1495` | keyframe repair — the one video-driven path, and it acts on **inbound** only | local `vasm.missing` |

### Why this is a bug and not merely a gap

Audio packets are `HDR + FPP*2` ≈ 84 bytes. Video fragments are MTU-sized. Any
byte-based policer, any AQM, any MTU or fragmentation fault drops the large ones
and spares the small ones. On such a path `outboundHarm == 0`, and the sender's
response to zero harm is:

- `videoParity = false` — parity **off**, so one lost fragment kills a whole
  frame;
- `vq.tick(framesLost: 0)` — fifteen quiet seconds and it steps **up**, to
  q0.7 ≈ 1.185 Mbps, 6-7 fragments per frame.

Measured, in this repo, at `VideoNet.swift:281-283`: at 1% loss, q0.7 loses
**7.8%** of frames to the void versus **0.9%** at q0.3. So the blind controller
climbs into the failure and disarms the one mechanism that would have survived
it. Positive feedback, per-direction, invisible at the only end that can act.

The receiving end sees all of it perfectly — `vasm.missing` and `vasm.dropped`
are already in the beat as `v_frames_lost` and `v_partial_drops`
(`main.swift:2396-2397`) — and throws it away rather than telling the sender.

This is a new variant of `directional-property-measured-at-wrong-end`: the
previous three instances acted on a one-way resource while reading their own
end. Here the property was **never measured at all**, and a symmetric rig can
never show it.

### Two adjacent defects on the same lines

**A missing negative clamp** at `main.swift:2537`. A peer restart zeroes its
counters, `outboundHarm` goes negative, and `wire.videoParity` is set **false** —
parity disarmed at the exact moment the far end is rebuilding its decoder state.
The audio FEC controller has guarded this since `main.swift:1780`; this consumer
never did.

**The wrong denominator** at `main.swift:2572`. `harmRate = outboundHarm / d.sent`,
but `Net.swift:595` increments `sent` for audio, video, probes and control alike.
An audio-only numerator over an all-traffic denominator is not a loss rate — and
it has the perverse sign: **raising the picture quality adds video packets,
lowers the measured harm rate, and makes retreat less likely.** `d.cap` is the
matching population. Same family as
`control-loops-steer-on-flattering-signals`.

## H1, for the record: real mechanism, self-limiting, rank it below S2

`Net.swift:1119-1128` — a one-slot reorder leaves `present(rSeq) == false`, the
redundant copy fills it, `recovered += 1`, and the original arrives later as a
dup. Zero packets lost, one unit of "harm" manufactured, and `outboundHarm`
includes it.

Three bounds keep it small: it needs `audio.redundancy == true`; redundancy only
arms after real loss (`main.swift:1782`); and the 30 s disarm timer
(`main.swift:1806-1811`) reads `concealLost`, **not** `recovered`, so H1 cannot
latch it. The audio FEC controller is immune. Only the VQuality consumer is
exposed, and only while redundancy is live.

Also settled while looking: `lost + recovered` is **not** double-counting a
repaired loss — a recovered packet never reaches `concealLost`
(`Audio.swift:1555` fires at playout). The comment at `main.swift:2515-2518` is
correct.

## The patch

New wire constant beside the existing ones, **not** in `Net.swift:35` (that is
the handshake constants' home and a different lane's file):

`TimeSync.swift:55` — `TPKTY = TPKTX + 12`, tested third after `TPKT` and
`TPKTX`. An old build receives 52 bytes, passes both of its own length checks,
parses bytes 0-39 identically and never looks at 40-51. A new build receiving an
old 40-byte probe fails `plainN >= TPKTY` and leaves `peerReportsVideo == false`.
Unaffected in both directions.

Three counters, all already `private(set) Int` on `VideoAssembler`, all computed
by the **receiver** so numerator and denominator come from the same end and the
same frames — no differencing against the sender's count, which at 30 fps carries
a ±1 frame edge error of 3.3% against a 2% line:

| offset | field | source | role |
|---|---|---|---|
| `TPKTX+0` | `vSpan` | `complete + missing` | frames the sender emitted over the span — the denominator |
| `TPKTX+4` | `vHarm` | `missing` | frames never displayed |
| `TPKTX+8` | `vRepaired` | `parityRecovered` | frames rebuilt from parity — arrived, but not whole |

Not `dropped`: `missing` (`VideoNet.swift:265`) is computed from sequence gaps at
delivery and already includes everything `dropped` abandoned. Adding it
double-counts.

Consumer side, in `reportLoop`: hold two cumulative **bases**, not a moving
average — a 30 s average read after a 12 s arm has inverted an A/B in this
project. A 1-tick base arms parity (cheap, wants to be fast); a **5-second**
window sets the retreat rate, because at 30 fps one second is 30 frames and one
frame is 3.3%, coarser than the 2% line it is compared against. Five seconds is
150 frames, 0.67% per frame, three frames of resolution at the line. Require
`ds >= 60` before grading so a mid-call camera restart cannot cross the line on
one frame. A negative delta means the peer restarted: invalidate the window,
never divide.

Threshold is 2% **of frames** — deliberately a different unit from the audio
line. Parity recovers one lost fragment of seven, so it fails on two: 0.2% of
frames at 1% loss, 1.7% at 3%, 4.5% at 5% (`VideoNet.swift:290-294`). 2% of
frames is therefore the same place as roughly 3% packet loss — where holding the
sharp picture stops being safe.

Additive, not a replacement: `harmed || vHarmed`. The audio path has 1500
packets/s of resolution and spots a congested uplink faster than 30 frames/s can,
so it stays. What is new is that a video-only fault is no longer invisible.

And when the far end is an older build, **say so on stderr** rather than
silently steering from audio alone.

### The riskiest hunk is the dullest one

Three separate `[UInt8](repeating: 0, count: TPKTX)` sizings must all become
`TPKTY`: `Net.swift:646` (`probeAllCandidates`), `Net.swift:824`
(`sendTimeProbe`), `Net.swift:1037` (the reply inside `recvLoop`). Miss one and
`storeBytes` writes past the end — Swift traps, so the loud version is a crash.
The quiet version is worse and likelier: miss the **reply** path and the report
flows at half rate in one direction only, looking like an intermittently
reporting peer rather than a missing hunk.

Gate: `grep -n 'count: TPKT' Net.swift` must return exactly three lines, all
`TPKTY`, none `TPKTX`.

One character to check by eye: the receive guard must read `plainN >= TPKTY`. With
`>= TPKTX` and reads at `TPKTX+8` it is a 12-byte overread of a
network-influenced length. As written the last byte touched is `TPKTY - 1`;
`plainN` is the **decrypted** length from `Crypto.open`, so it cannot be inflated
without the key.

## Proving it, and what will lie to you

The rig **cannot reproduce S2**. `Impair` sits inside `rawSend`
(`Net.swift:544-556`) and drops by probability, blind to `TxCls` — it treats an
84-byte audio packet and a 1200-byte video fragment identically. That is
precisely why this survived every measurement taken so far. Proof is a live call
over the far-away lab path, where a real policer or MTU boundary does this by
itself.

What moves if the fix works, at the **receiving** end of the previously
pixelated direction: `v_frames_lost` rate falls, and `v_parity_repaired` rises
from zero. Fragments per delivered frame fall if a retreat happened.
`v_glass_cov` and the shown-frame rate rise.

What will lie: **`v_mbps`** — rate control absorbs the change, and parity even
pushes it *up* by 1/nfrag while the picture gets better; measuring Mbps once made
a 65% win read as 2% (`rate-control-hides-quality-wins`). **`v_quality`** and
**`v_q_level`** — a correct fix may not move them at all, because parity alone
being enough *is* the designed outcome. **`dec_fails`/`no_fmt`** — both stay 0
through this entire failure, which `VideoNet.swift:148-153` says outright.

Null A/B first, in the same session: `--no-vparity` / default / `--no-vparity` /
default, ≥5 min arms, arm order rotated between runs. Compare only against the
spread measured in that session.

The distinguishing observation: **before**, the sender's stderr shows no
`picture:` retreat line and `parity sent 0` while the receiver shows a non-zero
frames-lost rate. **After**, `picture: the far end lost X% of the frames this end
sent` appears on the *sending* end, with parity non-zero, and the receiver's
frames-lost rate drops.

What would mean this is wrong: `peer_reports_video == 1` with `peer_v_harm` flat
at zero *while the far end's own beat shows a non-zero `v_frames_lost` rate over
the same wall seconds*. That is a report that arrived and said "no damage" about
damage that happened — the fault would be in the assembler's accounting, not the
wire. Also disconfirming: the fix lands and the picture stays pixelated with
`v_q_level` at floor and `peer_rx_lost` non-zero — that is S1, and S2 was never
the user's problem.

## `probes` was never missing

Recorded because it cost a lane a wrong lead. `"probes": tsync.samples` is at
`main.swift:2097` and has been in every beat since `5676f9f` (0.20.1); the
current release is 0.46.0. The server's `no_probe_count` came from windows
containing only `pre_connect` beats — `audioBeat`'s early return
(`main.swift:2068-2078`) emits seven fields and no `probes`, `rtt_ms` or rings,
correctly, because none of them exist yet.

Fixed on the server, not the client: `pre_connect` beats are now excluded from
the window and an all-`pre_connect` window grades `pre_connect_only`, which
points at rendezvous/ICE/TURN instead of at audio. Zero client releases. See
`diagnose.test.mjs` case (k), and its control (k3) proving the real
`no_probe_count` rule still fires.

## Beat size: a landmine, now disarmed

The cap that mattered was never the 16 KB request limit. It was
`JSON.stringify(rest).slice(0, 8000)` at the beat insert: slicing valid JSON cuts
mid-token, `safeParse` turns invalid JSON into `{}`, and so one oversized beat did
not lose its longest field — it lost **every** field and read as a completely
blind end. Replaced with `packFields`, which drops whole keys largest-first and
records `fields_dropped`. Measured headroom today: a representative 73-key beat
is 1282 chars, ~4.5× under the limit.

Round doubles before adding more fields. Swift's `JSONSerialization` emits
`1.1840000000000002` — 26 characters for one number, and doubles are the only
thing in this schema that can grow without a new key.

## Minimum subset that would have settled this

1. `peer_q_level` — one byte of wire, and from either end it reads "the picture
   coming at me is at the floor". The only single number that separates S1 from
   S2. The server rule for it is already deployed and dark.
2. `peer_v_harm` + `peer_v_span` — the sender learns the frames it sent are
   dying. Without these S2 is unobservable at the only end that can act.
3. `peer_reports`, `peer_rx_lost`, `peer_rx_recovered` — **zero new wire bytes**;
   all three are parsed today and thrown away. Unblocks `one_way_out` and
   `audio_dropouts_out`, both currently `no_peer_report`.
4. `route` (0/1/2) — separates "the TURN relay is dropping fragments" from "the
   home uplink is", which is the likeliest physical cause of a fragment-selective
   drop.
