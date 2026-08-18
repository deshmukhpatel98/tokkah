# TAPE — a 1:1 video call that behaves like recorded media

## 0. The vision

A conversation with one other person that feels like being in the room with them.

Five commitments, in priority order:

1. **Lossless picture.** Fixed quality, never adaptive. No blockiness, no blur on motion, no
   resolution drops, no artifacts — ever. When the network can't deliver, we hold a pristine frame
   and say so honestly.
2. **Lossless audio.** 48 kHz linear PCM. No codec, no noise suppression, no gate, no AGC.
3. **The lowest latency physics allows** on the route in question — ~40 ms same-city, and honestly
   bounded by the speed of light everywhere else (§19.2).
4. **Custom app, custom pipeline — without rewriting what's already mature.** We own every line that
   touches a frame. We do not write camera drivers (§19.2).
5. **Zoom fatigue designed out**, not mitigated. The causes are known and specific (§1.1).

**Non-goal for now:** producing a recording file. It's a near-free byproduct (§20), not a driver.

**Platform:** Cloudflare only. No third-party media stack — not even WebRTC's.

### What "across the globe" honestly means

Commitment 3 has a hard ceiling that no amount of engineering moves. Glass-to-glass targets:

| Route | Target | Of which is light in glass |
|---|---:|---:|
| Same city | **~40 ms** | 3 ms |
| Same country | ~60 ms | 20 ms |
| India ↔ Europe | ~100 ms | 55 ms |
| India ↔ US West | ~160 ms | 115 ms |

On long routes the one-way advantage narrows to ~90 ms and then stops, because the remainder is
distance.

A "Zoom at 130–250 ms same-city" comparison used to sit here. It had **no source anywhere in the
repo** and nobody on this project has measured Zoom's glass-to-glass — it is account-gated
(`BENCHMARK.md`). What *is* measured is the routing detour an SFU adds, which needs no account:
Google Meet's nearest edge is 6.4 ms away from our test machine and Zoom's is 8.4 ms, so against
those two the P2P routing advantage is **single-digit milliseconds**, not the 100+ ms a
poorly-sited bridge implies (`MEASURED.md`). Do not reintroduce an unsourced competitor number.

**But one-way latency is not what anyone experiences.** What people feel is the silence after they
finish a sentence, and the research is clear that this silence is inflated by far more than network
delay explains (§1.1c). That is the argument this design rests on, and it survives scrutiny.

What does **not** survive scrutiny is turning it into a headline multiple. This section used to
claim "2.4× better than same-city Zoom." That number was our *model* divided by their *measurement*,
taken from a different experimental task, and it has been removed. Corrected 2026-08-02; see
`FATIGUE.md` for what the literature does and does not support.

The defensible form of the claim: the mechanism that inflates the gap is cue destruction, not
distance — which means **commitments 1 and 2 are how commitment 3 is actually delivered.** Lossless
media is not in tension with low latency here; it is the mechanism. Whether it *measurably* shortens
turn transitions on our stack is untested, and testing it needs two humans in conversation, not a
latency probe.

So the ordering above is not a ranking of importance. A perfect-quality call from Mumbai to London is
a product nobody has. A 30-ms-faster call is a spec sheet. §3.1 is where the real argument lives.

### The one tension in this vision

A custom app is required for commitments 3 and 5 — the browser won't give us the camera, the
scheduler, or the display (§19.3). But **install friction is itself a top-five pain point**, and a
1:1 call needs *both* people. Resolution: one shared Rust core, two shells. The app for people who
have it; a browser fallback so a guest can always join from a link. Never make joining the reason a
conversation doesn't happen.

---

## 1. Thesis: what actually makes a call *feel* like a call

"Video call" is not a bitrate. It's a set of nine perceptual tells. Every one of them is a
consequence of the same architectural decision, made in 2011 and never revisited.

| # | Tell | Real cause |
|---|---|---|
| 1 | Blockiness / mush on motion | Encoder is CBR. When bits run short, quality is the variable that gives. |
| 2 | Soft, low-res image that "sharpens up" | Resolution adaptation + simulcast layer switching. |
| 3 | Jerky, wobbling frame rate | Encoder drops frames under pressure; effective fps swings 12–30. |
| 4 | Green smears, corrupt blocks, sudden "reset" | Decoder is fed incomplete bitstreams and conceals errors, then requests a keyframe. |
| 5 | Micro-stutters, clipped word endings | Jitter buffer is tuned for latency and discards late packets. |
| 6 | Robot voice / warble | Opus PLC inventing audio that was never spoken. |
| 7 | **The "call voice"** — thin, gated, band-limited, pumping | The browser's voice DSP chain: AEC + noise suppression + AGC, 16 kHz mono. |
| 8 | Half-duplex feel, one person ducks the other | Echo canceller gain-ducking on double-talk. |
| 9 | Webcam look — exposure hunting, white balance drifting | Camera auto-exposure/auto-WB left in continuous mode. |

Notice what tells 1–6 have in common. WebRTC treats **quality as the shock absorber** for a variable
network, because in 2011 the alternative was unthinkable. Tells 7–9 aren't even network-related —
they're defaults nobody turned off.

Recorded media has none of these tells, and the reason is structural: **a video file has a fixed
quality and an unlimited delivery deadline.** A video player facing a slow network does not get
blocky. It buffers, and if things get truly bad, it stalls — and a stall is *honest*. You know
exactly what happened, the picture stays pristine, and it recovers cleanly.

### The inversion

> **Quality is a constant. Time is the only shock absorber.**

Everything below follows from that one line. We fix quality at "no visible artifact," run latency as
low as the platform physically permits, and when capacity is insufficient we spend **time** —
first by growing a buffer imperceptibly, then by shedding an entire media lane, then by stalling
with a designed, honest UI state. We never spend quality. There is no code path in this system that
lowers the picture quality, and there is no code path that decodes an incomplete bitstream.

This is why the product needs a from-scratch media stack. Not because WebRTC is badly built — it's
excellent at the job it was given — but because its central premise is the thing we're inverting.
Every adaptive component (GCC bandwidth estimation, the pacer's encoder feedback, simulcast, the
`playoutDelayHint`-bounded jitter buffer, PLC) is load-bearing for *their* thesis and actively
hostile to ours. You cannot configure it out. You can only decline to use it.

---

## 1.1 The second set of tells: why calls are exhausting

§1 explains why calls look wrong. This explains why they're *tiring* — a different failure with
different causes, and the one that actually makes people avoid calls.

Zoom fatigue has been studied properly. Bailenson's Stanford work (2021) identifies four mechanisms,
and the Zoom Exhaustion & Fatigue scale that followed found self-view anxiety correlates strongly
with fatigue, more so for women. These are not vague complaints — each has a specific cause and most
have a specific fix.

| # | Cause | Mechanism | Fix | Falls out of our design? |
|---|---|---|---|---|
| 1 | **Faces too large** | A face filling a laptop screen at 50 cm subtends the angle of a real face at ~30–40 cm — Hall's *intimate* distance, reserved for lovers and threats. The body responds with sustained arousal for the whole call. | Render at **true physical scale** | No — new work (§1.1a) |
| 2 | **Constant self-view** | An inescapable mirror. The strongest single correlate of fatigue in the ZEF data. | Remove it | No — a UI decision |
| 3 | **Immobility** | You must stay centered and still. In person you shift, turn, look away. | Wide framing, room to move | No — a framing decision |
| 4 | **Nonverbal overload** | You over-perform cues (exaggerated nodding) and under-receive them, because artifacts and low frame rate destroy micro-expression. Your brain runs a deficit all call. | Lossless, high-framerate video | **Yes — this is §1's payoff** |
| 5 | **Broken eye contact** | The camera isn't where the eyes are. Everyone reads as subtly avoidant, for hours. | Layout, not synthesis (§1.1b) | No — new work |
| 6 | **Destroyed turn-taking** | See below. The most underrated cause. | Latency + full-band audio | **Yes — §1.1c** |

Note what column five says: **our quality work fixes two of the six, and they're the two nobody else
can fix**, because they require abandoning adaptive quality. The other four are design decisions we
simply have to make deliberately.

### 1.1a Render the person at life size

We know the display's physical dimensions and pixel density. We can estimate viewer distance from
the camera's own face-size measurement. So we can compute the exact pixel dimensions that make the
remote person's head **the angular size it would be if they were sitting across a desk** — roughly
100–120 cm away, Hall's *personal* distance, where conversation actually happens.

Nobody does this. Every call app scales the face to fill the available rectangle, which means the
apparent distance is an accident of your window size. Getting it right converts a call from an
uncomfortably intimate encounter into a normal conversation, and it costs a multiply.

Corollary: **never fill the screen with a face.** A correctly-sized head on a laptop occupies maybe
a third of the display. The empty space is not wasted — it is the reason the call isn't exhausting.

### 1.1b Fix gaze with layout, not with ML

Apple warps your eyes to fake eye contact. That's a synthesis of data that was never captured, and
invariant 4 forbids it — we don't show the viewer something the sender didn't do.

The honest fix is geometric: **put their eyes where the camera is.** On a laptop the camera sits at
top-center, so render the remote face's eye line at the top-center of the display. When you look at
their eyes you are looking within a couple of degrees of the lens, and eye contact becomes real
rather than simulated. It's an unusual layout, it takes ten minutes to implement, and it's the
difference between a call where nobody meets your gaze and one where they do.

This only works if you control the window position and the face position inside it — which is to say,
it's an argument for the custom app.

### 1.1c Turn-taking is a timing channel, and we broke it

The most precise fact in this document, and the one with the best experimental support. Across every
language studied, the gap between conversational turns averages **~200 ms** (Stivers et al., PNAS
2009). Human turn-taking is a tightly-tuned timing mechanism operating at that scale.

Boland, Fonseca, Mermelstein & Williamson (*J. Exp. Psychol. General* 151(6):1272–1282, **2022**)
measured what a video call does to it. Same dyads, two experiments:

| experiment | control | over Zoom |
|---|---:|---:|
| Exp 1, structured Q&A task | **297 ms** (local) | **976 ms** |
| Exp 2, free conversation | **135 ms** (face to face) | **487 ms** |

Earlier revisions of this document labelled the 297 ms as "face to face" and built on it. It is not:
it is the *local* control of a structured Q&A task. The face-to-face conversational figure is 135 ms,
and the cross-linguistic conversational baseline is ~208 ms (Stivers 2009). Corrected 2026-08-02.

**The arithmetic that matters, done with their numbers rather than assumed ones.** This document used
to assert "Zoom's round trip is about 500 ms," conclude that `297 + 500 = 797` left 179 ms
unexplained, and call that the damage. The 500 ms was unsourced. Boland measured the **actual audio
transmission delay in their own Zoom condition at ~30–70 ms**:

```
   976 ms   measured over Zoom
−  297 ms   the same task, locally
─────────
   679 ms   inflation
−   ~70 ms  the most transmission delay can account for
─────────
  ~609 ms   NOT explained by latency
```

So the effect is far larger than the 179 ms previously claimed — the old figure understated our own
argument by assuming a Zoom round trip four times worse than the one that was measured. Boland's
proposed mechanism is disrupted entrainment to syllable-rate timing: the listener stops *predicting*
the turn-end and waits for certainty. It is a cue-quality problem, not a network problem, and it is
invisible to everyone optimising round trips.

Human turn-end prediction runs on a specific, known set of cues:

| Cue | Destroyed by |
|---|---|
| **Creaky voice** at turn end | Lossy codecs — it's low-amplitude high-frequency detail, the first thing a bitrate ladder discards |
| **Final-syllable lengthening** | Time-domain smearing, packet concealment |
| **Terminal pitch contour** | Aggressive band-limiting and AGC |
| **Pre-turn inhale** | Noise suppression, which classifies it as non-speech |
| **Gaze return** to the partner | Low frame rate, latency |
| **Mouth closing** | Low frame rate, compression artifacts around the lips |

Every one of those six is destroyed by a design that treats quality as the shock absorber. Which
means the residual is not a fixed cost of remoteness — **it is the price of lossy media,** and we are
the only design not paying it. (Corrected 2026-08-02: that residual is ~609 ms, not the 179 ms this
document used to claim. See §1.1c — the old figure assumed a 500 ms Zoom round trip that Boland did
not measure.)

This reframes §5 and §6 completely. Lossless audio is not an audiophile indulgence and lossless video
is not vanity: **they are turn-taking infrastructure, and therefore latency features.** The four
boolean flags in §5 buy back more perceived latency than any transport optimisation in this document.

### 1.1c-2 We have also been measuring the wrong thing

"Perceived gap" should not be measured to the first *word*. It should be measured to the first
*evidence* that the other person is responding — because that is the moment the silence stops being
awkward. In a room, that evidence is not speech. It is breath.

Pre-speech inhalation precedes phonation by **~200 ms**, and — critically — inhalations before a *new
turn* are measurably longer and deeper than within-turn inhalations (Włodarczak & Heldner). The
inhale is not a side effect of speaking. **It is the turn-claim signal**, and it arrives 200 ms
before the words.

Noise suppression deletes it. Every commercial call product deletes it, deliberately, as a feature.

So the metric worth designing for is **time-to-first-evidence (TTFE)** — when the listener gets the
first cue that a reply is coming, not when the first word lands.

Read the next table as **a design model, not a result.** Only the Zoom row is measured, and it is
measured in someone else's experiment on a different task. Our rows are our latency budget plus a
200 ms credit for the pre-turn inhale surviving; they are predictions of what should happen, and
**turn-transition time has never been measured on this stack.** Doing so needs two humans in
conversation.

| | Voice onset | Inhale audible? | TTFE |
|---|---:|:---:|---:|
| Zoom, same city (Exp 1, measured) | 976 ms | **no — gated** | 976 ms |
| Ours, same city (modelled) | 377 ms | yes | ~177 ms |
| Ours, India ↔ US West (modelled) | 607 ms | yes | ~407 ms |

The previous revision divided the last row by the first, printed "2.4× better than same-city Zoom
while crossing the Pacific," and dropped the word *modelled*. A model over a measurement from a
different task is not a ratio anyone should publish, so the claim is withdrawn — the launch blog must
not carry it.

What is left is still a strong engineering argument, and it costs one line of code:
`noiseSuppression: false` preserves the inhale that every commercial product deletes deliberately.
The prediction is that this shortens turn transitions. **The experiment to confirm it has not been
run.**

One consequence for the transport: the inhale must **preempt everything**, including a video packet
already being serialised. If a 200 ms head start queues behind Lane B, we have paid for it and thrown
it away. That is why §4 needs a lane above Lane A — see §3.1.

### What this means for the build

Two of these fixes are free — remove self-view, disable the audio DSP. Two are a few hours — life-size
rendering, gaze-aligned layout. Two are the whole rest of the document — low latency and lossless
video.

Ordered by fatigue-reduction per hour of work, the cheap ones come first. That's worth knowing: **a
significant part of the vision is deliverable in week one**, and it is testable independently of the
transport gate.

---

## 2. Invariants

These are testable. Any change that violates one is wrong by construction.

1. **Fixed quantizer.** The encoder's QP is set at session start and never changes in response to
   the network. Bitrate is an output, never an input.
2. **Locked capture.** Frame rate, resolution, exposure, and white balance are locked before the
   call starts and never change during it.
3. **No lossy DSP on audio.** No AEC, no noise suppression, no AGC, no codec. 48 kHz linear PCM,
   end to end.
4. **Never decode incomplete data.** A frame is either complete and correct, or it is not shown.
   No error concealment exists in the video path.
5. **Audio survives everything.** Video is sacrificed to protect audio, in that order, always.
   Audio is ~8% of the bitrate and ~95% of the conversation.
6. **Failure is designed, not glitched.** Insufficient capacity produces a held pristine frame and
   an honest indicator — never an artifact.
7. **No `<video>` element.** (See §7. This one is worth stating as an invariant because violating it
   silently costs 30–100 ms and reintroduces tells 4 and 5.)

---

## 3. Latency budget

Latency is co-primary with quality, so it gets budgeted explicitly rather than hoped for.
Glass-to-glass, P2P, same metro, healthy link:

| Stage | Floor | Typical | Notes |
|---|---:|---:|---|
| Sensor → `VideoFrame` | 8 ms | 15–35 ms | Largest irreducible cost. Built-in cameras beat USB. MJPEG-only cameras add a decode. |
| Encode (HW, realtime, no lookahead, no B-frames) | 3 ms | 5–12 ms | Must be exactly 1 frame in, 1 frame out. |
| Packetize + pace + DTLS/SCTP | 1 ms | 2–5 ms | Only if `bufferedAmount` is kept near zero. |
| Network, one way | 3 ms | 8–25 ms | Cross-continent: 60–90 ms. |
| **Jitter buffer (`D`)** | **8 ms** | **15–40 ms** | The only tunable. This is where §12 spends time. |
| Decode (HW) | 3 ms | 5–12 ms | |
| `VideoFrame` → WebGPU → vsync | 8 ms | 8–25 ms | 8 ms at 120 Hz; up to 16.7 ms + compositor at 60 Hz. |
| **Total** | **~34 ms** | **~60–150 ms** | Budget. Measured on production: **23.0 ± 1.7 ms** p50 (n=10, loopback). No Zoom/Meet figure here — unmeasured, account-gated. |

Audio, separately:

| Stage | Typical |
|---|---:|
| Mic → AudioWorklet (device buffer) | 5–15 ms |
| Framing at 10 ms | 10 ms |
| Network | 8–25 ms |
| Jitter buffer | 10–25 ms |
| Output ring → DAC | 5–20 ms |
| **Total** | **~40–95 ms** |

Audio is naturally *faster* than video. The naive fix is to delay audio to match. Don't.
ITU-R BT.1359-1 puts the detectability threshold for audio *leading* video at ~45 ms. So:

> **Let audio lead video by up to 45 ms. Only pad audio beyond that.**

Free latency, grounded in psychoacoustics. Two design consequences fall out of the table:
the camera pipeline and the display present path are the two biggest non-network costs, and
neither is where anyone normally looks.

---

## 3.1 The turn-taking budget: attacking 607 ms

§3 budgets one-way glass-to-glass. But nobody experiences one-way latency. What people experience is
§1.1c's number: the silence after they stop talking. On our worst route that is **607 ms to voice
onset**, and it is the number that decides whether this project succeeded.

It is not one number. It is three, stacked, and **only one of them is physics:**

| Component | India ↔ US West | Nature | Recoverable |
|---|---:|---|---:|
| Human turn planning | 297 ms | Cognitive — but cue-quality dependent | see below |
| Light in fiber (2 × ~105) | 210 ms | **Physics** | ~0 ms today |
| Routing overhead (2 × ~15) | 30 ms | Engineering | ~20 ms |
| Device time (2 × 35) | 70 ms | Engineering | ~22 ms |
| **Total** | **607 ms** | | **~42 ms** |

Grinding the engineering columns to their floor yields **565 ms**. That is a 7% improvement for months
of work, and it is why the conventional attack on this problem fails: **only 210 of 607 ms is physics,
but 297 ms is a human being, and everyone treats that as fixed.** It is the largest single term and
the least examined.

### The five levers, in order of value

**1 · Count to first evidence, not first word — worth ~200 ms.** Raw audio preserves the pre-turn
inhale, which arrives 200 ms before phonation. This is the largest single win available anywhere in
this document, it costs four booleans, and every competitor deletes it on purpose. §1.1c-2.

> **Built and measured.** `core/onset.js`, 54 assertions in `core/onset.test.mjs`. Onset latency 0 ms
> on voiced speech, 15–20 ms on breath; detection holds to 12 dB above room tone; cost 0.03% of real
> time. Those last two figures were 10–15 ms and 4 dB until the noise floor stopped settling below the
> noise it measures — the old numbers were quoted against a floor 2.4–2.7 dB too low. See §17.1. It reports the per-turn lead with a deliberate **−24 ms bias** — attributing phonation to the
> start of the periodicity window rather than its end — so the instrument cannot flatter the claim it
> exists to test. A test asserts that bias stays non-positive. node and a real AudioWorklet produce
> byte-identical numbers. Live in `fatigue-lab` lobby step 4, which needs no peer: one person, one
> mic, read the median.

**2 · Restore the prediction cues — an inference, size unknown.** Boland's Zoom condition lost
~609 ms beyond what its own transmission delay explains (§1.1c, corrected). Lossless 48 kHz/24-bit
linear PCM preserves creak, final lengthening and terminal pitch exactly; 60 fps with tight A/V sync
preserves gaze return and mouth closure. The inference is that preserving those cues recovers some of
that residual. **How much is unmeasured** — this document previously put it at "up to 179 ms," a
figure derived from arithmetic that was itself wrong. Do not size this lever until the phase-3 gate
has run.

**3 · Lane 0: preemptive voice onset — worth ~10–20 ms, and protects lever 1.** A lane above Lane A.
Breath/voice-onset detection triggers an immediate flush and preempts any in-flight Lane B datagram.
Without this, the 200 ms head start from lever 1 can queue behind a 20 Mbps video burst and be lost.
Cheap insurance on the most valuable lever.

**4 · Predictive path warming — worth ~10–20 ms.** Run turn-end prediction on the **sender**, where
audio is available at zero latency. A turn-end is predictable ~250 ms out; the prediction is a few
bytes, so it reaches the peer ~95 ms *before* the turn actually ends. The receiver uses that window
to:

> **Measured 2026-08-01 (`core/turnend.js`, 204 LibriSpeech utterances, speaker-disjoint): the
> "~250 ms out" claim needs its units stated.** On read speech, final and internal sentence falls
> are acoustically near-identical (fall p50 110 vs 90 ms) and the steep part of a fall is ~110 ms —
> so 250 ms before completion there is literally no readable cue, and *anticipation* fails. What
> works is catching the fall's shoulder: the shipped module is a fall-in-progress detector with a
> **290 ms median useful lead** (p10 110, safely above the 95 ms wire deadline), 17.5% recall at a
> low-waste operating point (6.85 fires/utterance, zero fires after the true end). Read speech is
> the conservative floor — in real conversation turn-final cues are richer (creak, lengthening,
> grammar) and internal falls are genuine exchange opportunities rather than pure waste. The lever
> survives at "~10–20 ms" but its mechanism is *early detection*, not *prediction*, and its recall
> ceiling on held-out speech is ~1 in 5 turns. The integration contract stands: few bytes on Lane 0,
> pre-warm ~400 ms, false pre-warm ≈ 25 KB of padding, a miss costs nothing.

- **pre-warm the return path.** After a listening stretch, the responder has sent almost nothing and
  their congestion window has decayed. Their first burst of speech hits a cold window and pays for
  it. Padding the path on prediction means the reply leaves at full rate immediately.
- **pre-stall Lane B on the responder's uplink**, so their audio meets an empty pipe.

Note carefully what this is: **metadata derived from the sender's own real audio, used only to
schedule the network.** It is never mixed into media and never shown to the user. Invariant 4 holds —
we are predicting when to send, not what to send. This is, as far as I can tell, novel.

**5 · Asymmetric per-direction routing — worth ~5–15 ms.** The fastest Mumbai→California path is not
necessarily the reverse of the fastest California→Mumbai path; submarine routes differ and congestion
is directional and diurnal. Because we run our own datagram protocol over Spectrum UDP (§8.1) with
both endpoints under our control, we can measure each direction independently and choose separately.
Conventional stacks cannot — they inherit one path for both.

### Two levers deliberately not taken

**120 Hz+ displays — worth ~8 ms RTT.** Average wait for scanout is 8.3 ms at 60 Hz, 4.2 ms at 120 Hz,
2.1 ms at 240 Hz — per direction. Real, free where the hardware exists, and folded into §19.1. Not
listed above because it's hardware selection, not innovation.

**Hollow-core fiber — worth ~60 ms RTT, and not ours to take.** Light travels at ~99.7% of *c* in
hollow-core versus ~68% in solid silica. On a 20,000 km route that is 98 ms → 67 ms one way. It is
deployed on some latency-critical financial routes. We will not lay cable, but this is the one thing
that could move the "physics" row, and it is worth knowing it exists — the 210 ms floor is a property
of *current* glass, not of the universe.

### Where this lands

| | Voice onset | TTFE |
|---|---:|---:|
| Face to face | 297 ms | ~97 ms |
| Zoom, same city (measured) | 976 ms | 976 ms |
| **Ours, India ↔ US West** | **607 ms** | **~407 ms** |
| Ours, same city | 377 ms | ~177 ms |
| Ours, worst case, engineering floor | 565 ms | ~365 ms |

The claim this design can actually defend: **most of what makes a video call feel laggy is not the
network, so a design that refuses to destroy turn-end cues should feel better than one that does —
even across an ocean.** We do not beat physics; we decline to spend what everyone else spends on
lossy media and gated breath.

What this paragraph used to say was "better by a factor of 2.4 on the metric that matters." That
ratio divided our model by someone else's measurement of a different task, and it is withdrawn
(2026-08-02). The mechanism stands; the multiple was never measured. Sizing it needs two humans in
conversation on this stack, which has not been done.

---

## 4. Lane model

Four independent lanes over one transport, with **strict priority** — lane N never sends while
lane N−1 has anything queued.

| Lane | Content | Rate | Under pressure |
|---|---|---:|---|
| **0 — onset** | First ~40 ms of a turn, plus turn-end predictions | ~60 kbps, bursty | Preempts everything, including a Lane B datagram mid-serialisation. |
| **A — audio** | 48 kHz mono linear PCM, 24-bit, 10 ms frames | 1.15 Mbps + FEC ≈ 1.5 Mbps | Never yields. Protected by FEC. |
| **B — video** | Fixed-QP AV1/H.264, locked fps | 6–20 Mbps | Stalls entirely. Never degrades. |
| **P — presence** | Crisp JPEG stills, ~1 fps | ~100 kbps | Only sent while B is stalled. |

**Lane 0 exists to protect a 200 ms asset.** §1.1c-2 establishes that the pre-turn inhale reaches the
listener 200 ms before the words and is the single largest latency win in this design. Lane A already
has strict priority over video, but "strict priority" at the scheduler is not the same as "no
queueing" at the wire: a 20 Mbps Lane B burst already handed to the socket still has to drain. On a
long fat path with a warm congestion window that is tens of milliseconds of head-of-line delay —
spent on exactly the 40 ms that mattered most.

So Lane 0 carries two things: the leading edge of a detected voice onset (breath or phonation), and
the turn-end predictions of §3.1 lever 4. It is duplicated across two datagrams rather than
FEC-protected — at 60 kbps the redundancy is free and a retransmit round trip would defeat the point.

The onset detector runs on the raw 48 kHz stream we already have. It only needs to be fast and
generous, not accurate: a false positive costs one wasted small datagram, while a false negative
costs 200 ms of the thing we care most about. **Bias it hard toward firing.**

> **Built:** `core/onset.js` — see §3.1 lever 1 for measured latency and sensitivity. It fires the
> onset on energy alone in 5–10 ms and labels breath-vs-voice ~35 ms later, because waiting for the
> two pitch periods needed to classify would spend a seventh of the head start being won. The label
> is telemetry and predictor input; **it never gates the send.** That split is the whole reason Lane 0
> can be both fast and informative, and it is the first thing to preserve in the Rust port.

**Why mono, not stereo.** One person, one mic. Stereo doubles the cost for zero information and
halves the FEC we can afford. Mono is also what a post-production editor wants.

**Why linear PCM.** Opus at 256 kbps is perceptually transparent, so PCM is not a quality win in
the steady state — it's a **latency and failure-mode** win. No encoder frame buffering (Opus adds
its own 5–20 ms of look-ahead), no decoder state, and critically **no PLC**: a lost PCM frame cannot
turn into robot voice, because there is no model to hallucinate from. 24-bit is the ADC's real
ceiling, so int24 from the browser's Float32 discards nothing physical.

**Lane P is the interesting one.** When video stalls, a truly frozen frame reads as a broken app.
A *crisp still that updates once a second* reads as a deliberate mode. It costs ~1% of the video
budget, so it can run in conditions where nothing else can, and — importantly — it does not violate
invariant 1, because a sharp JPEG is not a degraded video frame. It's a different, honest
representation, and the UI labels it as such. Encode it off a `VideoFrame` via
`OffscreenCanvas.convertToBlob()` at quality 0.9; no second video encoder needed.

Aggregate at the 1080p30 tier: ~13.3 Mbps, ~1,460 packets/sec per direction. Both numbers matter —
see §8 on why.

---

## 5. Capture — where the "recorded look" is actually won

Tells 7, 8, and 9 are free to fix and nobody does it. This section is maybe 40 lines of code and it
does more for the feel of the product than the entire transport layer.

```js
// Audio: refuse the entire voice-call DSP chain.
const audio = await navigator.mediaDevices.getUserMedia({
  audio: {
    echoCancellation:  false,   // tells 7, 8
    noiseSuppression:  false,   // tell 7
    autoGainControl:   false,   // tell 7 (the "pumping")
    channelCount:      1,
    sampleRate:        48000,
    latency:           0,
  }
});
```

That single object is the difference between "Zoom voice" and "podcast voice." It is the highest
quality-per-line-of-code change available anywhere in this design.

**The echo problem it creates, and why we're better positioned than Chrome.** With AEC off, your
speakers feed your mic. Two answers:

- **v1: headphones.** The lobby detects output routing and asks for headphones. This is the podcast
  convention and users accept it instantly when told why.
- **v2: reference-based AEC that beats the browser's.** The browser's AEC is *blind* — it guesses
  the alignment between what it played and what it heard. We don't have to guess. We control the
  playout ring buffer and we know, **sample-accurately**, exactly what we handed the DAC and when
  (§10). A known-reference adaptive filter with zero alignment uncertainty is a fundamentally easier
  problem than blind AEC, and it can be linear-only — no gain ducking, so tell 8 never comes back.
  This capability is a direct dividend of owning the clock, and it is unavailable to anyone building
  on WebRTC.

  *Implementation clarifications (2026-08-02, from the AEC v2 design review — full design:
  `scratchpad/aec-v2-design.md`):* "sample-accurately" holds for what we hand the **render graph**;
  the DAC adds `outputLatency` (exposed) and the mic side adds input latency the platform does NOT
  expose, and Chromium's adaptive input resampler makes the offset slowly time-varying — so
  alignment uncertainty is small and bounded, not zero, and the design carries a lobby-chirp
  calibration plus an online EWMA cross-correlation tracker (§17.14's anchor/min-filter precedent)
  for exactly this. "Linear-only" has a stated price: residual echo RISES during double-talk while
  the filter is frozen (Geigel) — accepted. Headphones remain preferred when present (AEC bypassed);
  AEC is the speakers answer. Port-mode (non-crossOriginIsolated) gets no AEC — v1 headphones
  answer, logged honestly. Onset honesty is structural: wire, TurnEndPredictor, and the local
  OnsetDetector all consume POST-AEC audio via a `cleanedStream`, and local-onset `yieldLaneB` is
  suppressed until filter convergence. Performance bars (§5 stated none): ERLE ≥ 20 dB, zero
  echo-induced local onsets, ≤ 1 dB near-end double-talk damage, convergence ≤ 2 s.

```js
// Video: lock everything. Recorded video never hunts.
const track = videoStream.getVideoTracks()[0];
await track.applyConstraints({
  width:  { exact: 1920 },
  height: { exact: 1080 },
  frameRate: { exact: 30 },        // exact, not ideal/max — see below
  resizeMode: 'none',              // never let the browser rescale
});
// After the lobby's 3-second settle, freeze the camera's own AI:
await track.applyConstraints({
  exposureMode:     'manual',
  whiteBalanceMode: 'manual',
  focusMode:        'manual',
});
```

Three notes on this:

- **`exact` frame rate, not `ideal`.** Recorded video is always precisely 24/30/60. A rock-solid
  30 fps looks more "real" than a wobbling 24–60, because human motion perception is far more
  sensitive to frame-time *variance* than to frame *rate*. Constancy beats magnitude.
- **Lock to a divisor of the display refresh.** 30 fps on a 60 Hz panel is a clean 2:2 cadence.
  30 fps on a 120 Hz panel is 4:4. 30 fps on a 90 Hz panel judders no matter what you do. Read
  `screen.refreshRate` where available and pick the tier accordingly.
- **Manual exposure/WB is the single biggest "cinematic vs. webcam" lever there is.** Constraint
  support is uneven (best on macOS/Chrome and Android); degrade gracefully and don't block on it.

Capture and encode both run in a **DedicatedWorker**, never on the main thread. Main-thread jank
becomes frame-time variance, which is exactly the thing invariant 2 exists to prevent.

---

## 6. Encode

```js
const encoder = new VideoEncoder({ output: onChunk, error: onError });
encoder.configure({
  codec: 'avc1.640028',         // H.264 High — the primary path, not the fallback (measured §17.2)
  ...encodeSize(track, cfg),    // the CAMERA's size, capped at 1920×1080 — never above it
  framerate: 30,
  latencyMode: 'realtime',      // no lookahead, no frame reordering
  bitrateMode: 'quantizer',     // ← the whole thesis, in one line
  hardwareAcceleration: 'prefer-hardware',
});

// Per frame — QP is a session constant, not a network variable.
encoder.encode(frame, {
  keyFrame: needKeyframe,
  avc: { quantizer: needKeyframe ? QP - 6 : QP },   // H.264/HEVC: 0–51, AV1/VP9: 0–63
});
```

**1920×1080 is a ceiling, not a target.** This line said `width: 1920, height: 1080`
literally, and the encoder honoured it whatever the camera produced: a 720p sensor
was upscaled by WebCodecs into 2.25× the pixels with no extra information in them.
It cost **19% of the outbound stream** (measured: 7.89 → 6.43 Mbps, same camera,
same content, same QP) **and ~3.8 ms of p50 latency / ~7.2 ms of p95** (5 runs
per arm, interleaved, t = 4.0 — a first attempt at n=1 per arm wrongly concluded
latency was unaffected, because run-to-run spread on a fixed build is ±1.7 ms).
Because the receiving canvas tracks `frame.displayWidth`
faithfully, every instrument reported "1080p delivered" and the defect read as a
feature — see `MEASURED.md`. A sensor *above* the ceiling is still scaled down;
only the upscale is gone.

**Mid-call resizes are followed too.** The capture ladder steps the camera down
a tier when the source-fps probe finds it starving, which used to leave a
smaller track feeding an encoder still configured at the old size — reinstating
the upscale in exactly the degraded conditions where it costs most. The capture
pump now compares each frame against the live config and reconfigures once a new
size has held for `RESIZE_HOLD` (5) frames, forcing a keyframe at the switch.
The receiver needs nothing: annexb parameter sets are inline, so that keyframe
is self-describing, and the canvas already tracks `frame.displayWidth`. Verified
on production with a forced `applyConstraints` step-down — 1920×1080 → 640×360,
far end followed and kept moving. **Both lanes** carry this now, along with the
`adoptTrack` re-attach that keeps a capture pump alive across a camera flip.

`bitrateMode: 'quantizer'` is shipped in Chromium for AV1, VP9, and H.264. It is the API that makes
this product possible, and its absence is why nobody has built it. WebKit signalled support and
Gecko is neutral, so treat Chromium as the v1 target and see §17 for the fallback.

**H.264 is primary because AV1 is absent, not because H.264 is better** (measured §17.2):
`VideoEncoder.isConfigSupported` rejects every AV1 configuration on current Macs — total absence,
not a fixed-QP or hardware-acceleration gap — while software libaom AV1 actually *won* the quality
shootout (VMAF 96.7 vs 96.5) at only 4.57 ms/frame. But a CPU-limited stuttering call is the one
failure mode the whole design exists to prevent, so the shipping default is hardware H.264 at
~1.4× the bitrate for equal quality, and AV1 is the opportunistic upgrade: start on AV1 where
`isConfigSupported` says real, watch `qualityLimitationReason` for `cpu`, fall back. That runtime
fallback is not yet built (§17.2) — when it lands, this section's default flips machine-by-machine.

**10-bit, once the flag exists.** Encoding 10-bit from an 8-bit source costs ~5% bitrate and kills
gradient banding on skin tones and background walls — the most common *remaining* artifact once
blockiness is gone. Not yet plumbed (§17 small-items); when built, it is High 10 where supported,
not AV1-10-only.

### GOP: infinite, not periodic

Periodic keyframes are conventional, and here they're actively harmful. At fixed QP an I-frame is
5–10× a P-frame. A 2-second keyframe interval therefore injects a 5–10× bitrate spike every two
seconds — a spike large enough to overflow the pacer and *cause the very stall we're engineering
around*. Our own keyframe cadence would become our dominant source of congestion events.

So: **infinite GOP.** Keyframes are emitted only on (a) session start, (b) an unrecoverable loss
that ARQ couldn't repair, (c) resume from a stall. All three are rare and all three are moments
where a brief spike is already expected. The pacer carries a 200 ms burst allowance to absorb them.
Keyframe QP is set 6 steps *better* than delta QP, because a keyframe is the reference for
everything after it and its errors propagate for minutes.

Note that dropping the recording requirement is what unlocks this — periodic keyframes exist to
provide seek points, and with no file to seek there is no reason to pay for them.

### Quality tier, chosen once

Absolute fixed quality across all network conditions is not physically deliverable — a 6 Mbps uplink
cannot carry a 12 Mbps stream, and no amount of architecture changes that. The honest resolution:

> **Quality is constant *within* a session. The tier is measured and locked in the lobby, and never
> revisited mid-call.**

The lobby runs a 3-second capacity probe and picks:

| Tier | Config | Video | Total | Requires |
|---|---|---:|---:|---|
| S | 1080p60, QP 22 | 18 Mbps | 19.5 Mbps | ~25 Mbps up |
| A | 1080p30, QP 22 | 11 Mbps | 12.5 Mbps | ~16 Mbps up |
| B | 1080p30, QP 26 | 7 Mbps | 8.5 Mbps | ~11 Mbps up |
| C | 720p30, QP 24 | 4 Mbps | 5.5 Mbps | ~7 Mbps up |
| D | audio-only + lane P | — | 1.6 Mbps | ~2.5 Mbps up |

Tiers are asymmetric — each direction picks its own from its own uplink. Target VMAF ≥ 97 at every
tier above D; validate with real talking-head footage during tuning, not synthetic clips.

**Position this honestly.** This product requires a decent uplink and its failure mode is stalling.
That makes it right for interviews, remote pair-programming, therapy, high-trust 1:1s — conversations
where presence matters more than convenience — and wrong for a call from a moving train. Tier D
exists so that case degrades into something coherent (perfect audio + slideshow) rather than pretending.

---

## 7. Presentation — the invisible 100 ms

The single most consequential implementation detail in this document:

> **Never render the remote stream with a `<video>` element.**

`<video>` is a *media player*. Hand it a MediaStream and it silently adds its own jitter buffer, its
own A/V sync logic, and its own frame-drop policy — 30–100 ms of latency you cannot measure or
control, plus it reintroduces tells 4 and 5 that we spent the whole transport layer eliminating.
Every browser-based low-latency effort I'm aware of loses tens of milliseconds here without noticing.

Instead:

```
EncodedVideoChunk → VideoDecoder → VideoFrame
                                      ↓
                          our presentation queue (§10)
                                      ↓
              WebGPU external texture, drawn in a rAF loop
                                      ↓
                                   compositor
```

We own the queue, so we decide exactly which frame is on screen at which vsync. `VideoFrame` goes
to WebGPU as an external texture with zero copies. Present in a `requestAnimationFrame` loop
phase-locked to the display: at each vsync, draw the frame whose presentation timestamp is closest
to `now + D`, and hold the previous frame if none qualifies. That "hold" is not a bug — it is
invariants 4 and 6, implemented in three lines.

Audio is symmetric: an **AudioWorklet** reading a `SharedArrayBuffer` ring, filled directly by the
network worker. No `<audio>` element, no `MediaStreamAudioSourceNode`, no `AudioContext` resampling.
`new AudioContext({ latencyHint: 0, sampleRate: 48000 })`.

---

## 8. Transport

### What we need

Unreliable, unordered datagrams; per-lane independence (no head-of-line blocking); ~1,500 pps at
~13 Mbps; our own congestion policy; and the lowest achievable RTT.

### The decision

| Option | Verdict |
|---|---|
| **WebTransport / QUIC datagrams** | Exactly right. Not available on Workers — an open workerd tracking issue, not on the roadmap. **But reachable on Enterprise via Spectrum UDP (§8.1).** Held as the designed fallback, not the v1 primary, because it costs a relay hop. |
| **WebSocket over TCP via a Durable Object** | TCP head-of-line blocking plus TCP's own retransmit and congestion control fighting ours. A single lost packet stalls every lane. **Rejected.** |
| **CF Realtime SFU DataChannels** | Technically viable for 1:1 (publisher + one subscriber with `canReply`), and it would make TURN free. **Rejected for a specific reason:** the SFU terminates DTLS and re-originates, turning one end-to-end SCTP association into two in series, each with its own congestion window. For a 12 Mbps flow that is *strictly worse* than a dumb relay — it doubles the number of controllers that can throttle us. A TURN relay preserves one E2E association and one CC loop. |
| **P2P WebRTC DataChannel, unordered + unreliable** | **Chosen for v1.** |

### Why P2P is not a retreat from "fully on Cloudflare"

For strictly 1:1, the lowest-latency topology contains **no server in the media path at all.** Any
relay — CF's or anyone's — is a strictly additive hop. Cloudflare's job is to make the direct path
*reliable*, not to carry the bytes:

```
  Worker (HTTPS)  ──  room creation, short links, TURN credential minting
  Durable Object  ──  SDP/ICE exchange, session clock authority, control plane
  CF TURN         ──  relay fallback when P2P fails, and A/B raced against it
  D1              ──  rooms, sessions, telemetry
  ─────────────────────────────────────────────────────────────────────
  Media           ──  peer ↔ peer, or peer ↔ CF TURN ↔ peer
```

No third-party vendor appears anywhere. Every hosted component is Cloudflare. The media simply
takes the shortest path physics allows, which for two participants is a straight line.

**Hard architectural line: Durable Objects never touch media.** Control plane only. Relaying
13 Mbps through a DO would add a hop, add jitter, consume CPU against DO limits, and cost more than
TURN. The DO is a coordinator and a clock, nothing else.

### Using WebRTC as a pipe, not a media system

We use exactly one part of WebRTC: DTLS/SCTP over ICE, as a NAT-traversing datagram pipe. In
lane 1 (the datachannel lane) no `getUserMedia` track ever reaches the `PeerConnection` — no
simulcast, no GCC, and the pc carries zero media tracks. Lane 2 (the RTP-transform lane) is the
exception: one video track rides the pc as a *carrier*, and an `RTCRtpScriptTransform` replaces
libwebrtc's encoded payload with our fixed-QP bytes before transmission. The transform sits
between encoder and SRTP on send (and between SRTP decryption and decoder on receive), so the
wire format is still DTLS-SRTP terminating at the two browsers — but "no RTP, no SRTP" is no
longer literally true of the system.

```js
const pc = new RTCPeerConnection({
  iceServers: [{                                  // credentials minted per-session by a Worker
    urls: ['turn:turn.cloudflare.com:3478?transport=udp',
           'turn:turn.cloudflare.com:53?transport=udp'],   // :53 survives hostile firewalls
    username: creds.username, credential: creds.credential,
  }],
  bundlePolicy: 'max-bundle',
});

const dc = pc.createDataChannel('tape', {
  ordered: false,
  maxRetransmits: 0,        // we do our own ARQ, with our own deadlines
  protocol: 'tape/1',
});
dc.binaryType = 'arraybuffer';
dc.bufferedAmountLowThreshold = 64 * 1024;   // primary backpressure signal (§12)
```

Port 53/udp as an alternate TURN port is a genuinely useful detail — UDP/53 is almost never blocked,
because blocking it breaks DNS.

### SCTP's three real hazards

These are the live risks in this design. Each has a concrete mitigation and each must be measured in
phase 1, not assumed.

1. **PMTUD stalls on small packets.** usrsctp only grows its path MTU — and therefore its congestion
   window — if it sees reasonably large packets early. Open with 400–1200 B packets from the very
   first datagram. Never open with a burst of tiny control messages, which is the natural thing to
   do and would quietly cap throughput for the whole session.
2. **Throughput degrades sharply with RTT.** SCTP's cwnd is per-*association*, so multiple
   DataChannels share one window and add nothing. At 100 ms RTT, sustaining 13 Mbps needs ~160 KB in
   flight, which brushes usrsctp's default send buffer. Mitigations, in order: keep `bufferedAmount`
   near zero so our pacer binds before SCTP's cwnd does; if that's insufficient at high RTT, **open
   N parallel `RTCPeerConnection`s** — separate associations, separate cwnds, aggregate throughput —
   and stripe lane B across them. Ugly, effective, well-precedented.
3. **usrsctp still runs congestion control in unreliable mode.** `maxRetransmits: 0` removes
   retransmission, not CC. If SCTP's controller becomes the binding constraint, we lose control of
   our own policy. The defense is to always be the tighter controller: our pacer must back off
   *before* SCTP's does, which we detect via `bufferedAmount` growth (§12).

### Path racing

ICE picks a candidate pair by heuristic priority, which is usually right and sometimes wrong —
for intercontinental peers, CF's anycast backbone can genuinely beat the public internet. So:
establish both a direct pair and a TURN-relayed pair, measure real one-way delay on each for 2
seconds, and keep the winner. Re-race on any sustained degradation. Measurement over heuristics.

CF TURN's documented limits are ~50–100 Mbps and 5–10 kpps per allocation. At 13 Mbps and 1,450 pps
we sit comfortably under both — **but only because our packets stay ~1,150 B.** A design using
300-byte packets would hit the pps ceiling at a quarter of the bitrate and manifest as unexplained
loss. This is why §9 sizes packets the way it does. (On Enterprise these are negotiable rather than
fixed — see §8.1.)

---

## 8.1 What the Enterprise account changes

Enterprise doesn't change the v1 design. It changes the **risk profile**, and it does so precisely
where the design is most exposed. Three things matter.

### 1. Spectrum UDP turns the highest-severity risk into a purchased fallback

**UDP support in Spectrum is Enterprise-only.** Spectrum opens raw UDP listeners on Cloudflare's
anycast edge and forwards L4 payloads to an origin **unmodified, without parsing them**. WebTransport
is QUIC, and QUIC is UDP. So:

```
browser ── WebTransport/QUIC ──► CF anycast edge (Spectrum UDP) ──► our QUIC server
```

This is the transport §8 wanted and couldn't have: real unreliable datagrams, per-stream
independence, and **congestion control that is entirely ours** — no usrsctp, no cwnd we don't
control, none of §8's three hazards. QUIC also happens to be a clean fit for Spectrum's one hard
constraint, that fragmented UDP is dropped at the edge, because QUIC does its own PMTUD and never
fragments.

Two honest costs:

- **It needs a non-Worker origin.** Workers and Containers cannot accept inbound UDP, so the QUIC
  server has to run on real compute (a small fleet of VMs, or CF's own compute if inbound UDP ever
  lands there). This is the one place the "fully hosted on Cloudflare" constraint bends — CF provides
  the anycast edge and DDoS protection, but not the socket.
- **It's a relay hop**, so it is strictly worse than P2P for same-metro peers. It is not a latency
  win; it is a *control* win.

So the right role for it is not the primary path. It is the answer to the question "what if phase 1
shows SCTP can't hold 12 Mbps at realistic RTT?" — which, without Enterprise, would have been
"then this doesn't work on the web." With Enterprise, it's "then we spend a relay hop and some VMs."
**That single fact is worth more than everything else on this list**, because it removes the only
risk in this document capable of killing the project.

It is also the transport the native client (§16) should use from day one, where there's no browser
API constraint at all and Spectrum can front raw UDP directly.

### 2. Negotiable TURN limits, and Argo on the relay path

The 50–100 Mbps / 5–10 kpps per-allocation figures are documented defaults, not contractual ceilings.
On Enterprise they're a conversation with the account team, which matters if we ever want tier S
(19.5 Mbps) over a relay, or if FEC parity bursts push us toward the pps limit. Argo Smart Routing
is also worth measuring on the TURN-relayed path specifically — it optimizes transit across CF's
backbone, which is exactly the leg a relayed call traverses. Neither of these affects P2P calls,
which is still where 80–85% of traffic should land.

### 3. The account team can close §17's open questions directly

The two things I could not verify from public documentation are both answerable by email on an
Enterprise contract, and both are worth asking before phase 2 freezes decisions:

1. **WebTransport in workerd — is it on any roadmap?** If it ships, the Spectrum origin problem
   disappears and the fallback becomes genuinely serverless. Enterprise feature requests carry
   weight; this is worth filing regardless of whether we need it, because it's the single largest
   simplification available to this design.
2. **How are TURN per-allocation limits enforced** — hard drops or shaping — and how do they behave
   under a sustained 13 Mbps flow for an hour? The docs give thresholds but not enforcement behavior,
   and the difference determines whether a relayed tier-A call is reliable or merely usually fine.

Also worth confirming: whether "TURN is free when used with the Realtime SFU" could extend to our
DataChannel-only usage. We rejected the SFU on technical grounds above, so this is a pricing question
with no architectural pull — but it's the only recurring per-call cost in the design (§18), so it's
worth one email.

**What Enterprise does not change:** the media path, the codec strategy, the stall machine, or the
UI. Higher Worker and Durable Object limits are welcome but not binding, because the DO carries
~1 KB/s of control traffic and nothing else. This is deliberate — see §14.

**Implementation clarifications (2026-08-02, from the path-racing design review —
full design: `scratchpad/path-racing-design.md`, build as `?race=1` stage 1):**
"both a direct pair and a TURN-relayed pair" is implemented as two throwaway
data-channel-only probe pcs (a browser holds one selected pair per pc), built on
the §17.13 stripe pattern; "measure one-way delay" is min-filtered RTT floor at
10 Hz for 2 s (law 16, TIME_SYNC precedent — the offset machinery biases under
queueing); relay wins only by a >15 ms margin (sized against the measured
per-TURN-server allocation skew), ties go direct; "re-race on sustained
degradation" is stage 2, deferred until stage-1 telemetry says mid-call switching
earns its complexity — a rebuilt relay pc is a *different* TURN server, so
hysteresis must self-compare per arm, never across allocations. The media pc is
constructed with the winning arm's exact config (deterministic; ICE cannot
re-admit the overruled path) plus a one-shot pre-offer rebuild on ICE failure.

---

## 9. Wire protocol

Everything is sized so one datagram is one SCTP message with no fragmentation: **payload ≤ 1,150 B**
(1,200 B path MTU minus DTLS and SCTP overhead, with headroom).

### Common header — 12 bytes

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|Ver|Lane |Flags|              Sequence (per-lane, u24)          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                  Session timestamp (µs, u48)                  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|         (u48 continued)        |         Lane-specific         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

Ver   2b  = 1
Lane  3b  = 0 CTRL · 1 AUDIO · 2 VIDEO · 3 PRESENCE · 4 FEC
Flags 3b  = keyframe · lane-final-fragment · retransmission
```

The u48 microsecond timestamp is in **session-clock** time (§10), not local time. Every packet
carries it. This is the backbone of sync, one-way-delay estimation, and the congestion controller —
one field doing three jobs.

### Lane A — audio, 4-byte extension

```
+-------------------------------+-------------------------------+
| Samples in frame (u16 = 480)  |  Reserved / channel map (u16) |
+-------------------------------+-------------------------------+
| int24 LE PCM, 480 samples = 1440 B ... (one 10 ms frame)      |
```

1,440 B exceeds our 1,150 B target, so a 10 ms frame is 2 fragments — acceptable, but the cleaner
option is **8 ms frames (384 samples = 1,152 B)**, one datagram each, 125 pps. Prefer 8 ms: single
datagram per frame means a lost datagram is a bounded, independently-FEC-recoverable unit.

FEC: Reed–Solomon RS(10, 13) over rolling groups of 10 — 30% overhead, recovers any 3 of 13 lost.
At 8 ms framing that's 80 ms of protection span, well inside the audio jitter budget. Audio is the
lane that must not fail, so it gets forward correction rather than retransmission; there's no time
to ask twice.

### Lane B — video, 8-byte extension

```
+-------------------------------+---------------+---------------+
|        Frame ID (u16)         | Frag idx (u16)|Frag count(u16)|
+-------------------------------+---------------+---------------+
|      Chain ID (u16)           |  bitstream fragment ...       |
+-------------------------------+-------------------------------+
```

**Chain ID** increments on every keyframe. It's how the receiver reasons about invariant 4: if any
fragment of any frame in chain *k* is unrecoverable, every subsequent frame in chain *k* is
undecodable, and the correct action is to stall and request a keyframe — not to decode and conceal.
Since WebCodecs gives no control over reference structures, this coarse chain model is exactly the
right granularity: it's the most we can actually know, and it's sufficient.

### Lane CTRL

| Message | Payload | Purpose |
|---|---|---|
| `TIME_SYNC` | t1, t2, t3 (u48 ×3) | Offset/drift estimation, 5 Hz |
| `RECV_REPORT` | per-lane recv/lost/jitter, OWD estimate, buffer depth, `bufferedAmount` | Congestion input, 20 Hz |
| `NACK` | frame ID + fragment bitmap | ARQ request |
| `KEY_REQUEST` | reason code | Unrecoverable loss, or stall resume |
| `TIER_PROPOSE` / `TIER_ACCEPT` | tier ID, measured capacity | Lobby negotiation only |
| `LANE_SHED` / `LANE_RESUME` | lane ID | Sender-driven stall (§13) |
| `HOLD_ENTER` / `HOLD_EXIT` | reason, est. duration | Drives the UI state |

`RECV_REPORT` at 20 Hz is 20 pps of pure control traffic — negligible, and it's what makes the
control loop tight enough to react inside a single buffer's worth of time.

---

## 10. Clock and sync

Most implementations are sloppy here and it shows up as slow drift, lip-sync creep, and mystery
stutters an hour in.

**Session epoch.** The Durable Object stamps a `session_epoch_us` at creation and is the sole time
authority. Both peers estimate their offset to it via `TIME_SYNC` over the DataChannel — NTP-style
four-timestamp exchange at 5 Hz, offset taken from the **minimum-RTT sample** in a sliding 10-second
window (min-filtering rejects queueing delay far better than averaging), with a slow linear fit for
crystal drift. Crystals differ by 10–50 ppm, which is 36–180 ms per hour: absolutely enough to break
sync on a long call if untracked.

**Timestamps come from the media, never the wall clock.**

- Audio: an AudioWorklet counting samples. Sample index is the timebase. `currentTime` and
  `performance.now()` both drift relative to the audio hardware and must never be used for framing.
- Video: `VideoFrame.timestamp`, which is capture-time in microseconds.

**Audio is the master.** Video is presented to match audio, never the reverse. Audio playout is an
AudioWorklet draining a `SharedArrayBuffer` ring at a target occupancy of `D_audio`.

**Drift compensation by resampling, never by gaps.** When ring occupancy trends away from target,
correct with a continuous resample ratio bounded to ±0.2% (~±3.5 cents — inaudible on speech).
Never insert silence and never drop samples once locked; both are audible, and both are tell 5.

**Video presentation.** At each vsync, present the frame whose timestamp is nearest
`audio_playout_time + offset`, where `offset ∈ [0, 45 ms]` per §3. Hold the current frame if no
frame qualifies.

**Audio-lane concealment — the one deliberate exception to invariant 4.** If a PCM frame survives
neither FEC nor ARQ, a hard 8 ms gap is worse than a repair. Allow waveform-similarity extrapolation
for up to 24 ms, then enter `HOLD`. This is bounded, honest, and rare — and it is nothing like Opus
PLC, which resynthesizes speech from a model and can invent phonemes. Extrapolating 8 ms of
waveform cannot produce a word that wasn't spoken.

---

## 11. Loss recovery

Different lanes, different physics, different strategy.

| Lane | Strategy | Rationale |
|---|---|---|
| A — audio | **FEC**, RS(10,13), 30% overhead | Cannot afford an RTT. 30% of 1.15 Mbps is 350 kbps — trivial. |
| B — video | **ARQ**, deadline-bounded | FEC on 11 Mbps costs 3.3 Mbps. Video has more delay budget than audio. |
| P — presence | Reliable, ordered, own channel | 100 kbps, latency-insensitive. |

**Video ARQ.** On a fragment gap, `NACK` immediately. Retransmit is worth attempting only while
`deadline − now > RTT × 1.2`. Two attempts maximum. If both fail, the chain is dead: `KEY_REQUEST`,
and stall until a fresh keyframe lands. `NACK` is rate-limited to 200/s to prevent a congestion
collapse spiral where loss generates traffic that generates loss.

**The decoder never sees incomplete data.** Reassemble a frame fully or discard it fully. There is
no error concealment path in the video decoder — not disabled, *absent*. This is the mechanical
reason tell 4 cannot occur, and it's a much stronger guarantee than "we configured it not to."

---

## 12. Congestion control

Standard controllers (GCC, BBR) exist to fill a pipe and instruct an encoder to adapt. We need the
opposite: a controller whose output is **delay and lane-shedding**, and which has no wire to the
encoder at all.

### Inputs, at 20 Hz

- **One-way delay gradient.** Per-packet `send_ts` (session clock) vs. arrival. A rising trendline
  is the earliest capacity signal available — it precedes loss by hundreds of milliseconds.
- **Receive/send rate ratio.** Directly measures the deficit.
- **Loss rate**, per lane.
- **`dc.bufferedAmount`.** Local, zero-latency, and our early warning that SCTP is about to become
  the binding controller (§8, hazard 3).
- **Receiver buffer occupancy**, from `RECV_REPORT`.

### Output: a regime, not a bitrate

Let `C` = estimated capacity, `R` = the locked source rate, `D` = playout delay.

```
C ≥ 1.25·R  ────────  NOMINAL   D → D_min (8–15 ms). Shrink at ≤2 ms/s.
                                No action. This is the steady state.

R ≤ C < 1.25·R  ────  SQUEEZE   Grow D to cover measured jitter.
                                Audio buffer grown by WSOLA time-stretch ≤5%.
                                Imperceptible. Video simply presents later.

C < R, transient  ──  ABSORB    Deficit × elapsed = backlog.
                                While backlog < D_max − D: grow D, keep sending.
                                This is the shock absorber doing its job.

C < R, sustained  ──  SHED      Backlog will exceed budget. Drop lane B entirely.
                                Start lane P. Audio now has 8× headroom.
                                → §13

C < R_audio  ──────── HOLD      Cannot carry even audio. Explicit paused state.
                                Rare: requires <1.6 Mbps.
```

`D_max` is 400 ms for video, 120 ms for audio — asymmetric, because audio latency costs conversation
and video latency mostly doesn't.

**WSOLA time-stretch is the mechanism that makes SQUEEZE invisible.** Growing a buffer normally means
inserting silence, which is audible. Stretching speech by 4% for 800 ms grows the buffer by 32 ms
with no perceptible pitch or tempo change. It is the single technique that lets latency be a
*continuous* variable rather than a stepwise one — which is what "time is the shock absorber"
actually requires in practice.

**The encoder is not connected to this controller.** There is no callback, no bitrate setter, no
resolution hint. That absence is the architecture.

---

## 13. The stall machine

This is the product's defining behavior, so it's specified precisely.

```
                    ┌──────────────────────────────────────┐
                    │              NOMINAL                 │
                    │   video live · audio live · D_min    │
                    └───────┬──────────────────────▲───────┘
                 capacity dip│                     │2 s clean
                            ▼                     │
                    ┌──────────────────────────────┴───────┐
                    │       SQUEEZE / ABSORB               │
                    │   D grows · WSOLA stretch · no        │
                    │   visible or audible change           │
                    └───────┬──────────────────────▲───────┘
              backlog>budget│                      │capacity restored
                            ▼                      │+ keyframe decoded
                    ┌───────────────────────────────┴──────┐
                    │            VIDEO HELD                │
                    │  last complete frame on screen        │
                    │  lane P: crisp still @1 fps           │
                    │  audio: LIVE, full quality            │
                    │  UI: "holding · audio live"           │
                    └───────┬──────────────────────▲───────┘
                 C < R_audio│                      │C > R_audio
                            ▼                      │
                    ┌───────────────────────────────┴──────┐
                    │               HOLD                   │
                    │  both lanes paused · honest UI        │
                    │  reconnecting                         │
                    └──────────────────────────────────────┘
```

Three rules make this feel intentional rather than broken:

**1. Video sheds alone, and it's the *sender* that sheds.** The receiver detects the deficit but the
sender acts on it (`LANE_SHED`). A receiver-side drop would leave the sender pushing 11 Mbps into a
pipe that can't take it, which is what turns a video problem into an audio problem. Shedding at the
source is what gives audio its 8× headroom, and it's why audio effectively never stalls: the moment
video stops, 11 Mbps of capacity frees up for a 1.5 Mbps stream.

**2. Resume never replays the backlog.** On `LANE_RESUME`, the sender **discards every queued frame**
and emits a fresh keyframe at the current instant. Playing the backlog fast would be a visible
fast-forward; playing it at normal speed would mean permanently accumulated latency. Live media is
allowed to skip time. Discard, keyframe, resume — one clean cut.

**3. The transition is a cut, not a glitch.** Held frame → new keyframe is a hard cut between two
pristine images. No blur, no ramp-up, no artifact. Cuts are a normal grammar of recorded video, so
the eye reads it as an edit rather than a failure. This is the difference between "the app broke"
and "the connection paused" — and it's entirely a function of never having shown a bad frame.

---

## 14. Cloudflare topology

```
┌─────────────┐                                        ┌─────────────┐
│  Peer A     │                                        │  Peer B     │
│             │◄────── DTLS/SCTP, unordered ──────────►│             │
│ Worker:     │        (direct, or CF TURN)            │ Worker:     │
│  capture    │                                        │  capture    │
│  encode     │                                        │  encode     │
│  packetize  │                                        │  packetize  │
│  WebGPU out │                                        │  WebGPU out │
└──────┬──────┘                                        └──────┬──────┘
       │ WSS (control only, ~1 KB/s)                          │
       └──────────────────┬───────────────────────────────────┘
                          ▼
          ┌───────────────────────────────────┐
          │   Durable Object: CallRoom        │
          │   · SDP / ICE exchange            │
          │   · session clock authority       │
          │   · tier negotiation              │
          │   · event log, alarms, timeouts   │
          │   · NEVER touches media           │
          └───────────────┬───────────────────┘
                          ▼
            ┌─────────────────────────┐
            │ Worker  · rooms, links, │
            │           TURN creds    │
            │ D1      · sessions,     │
            │           telemetry     │
            └─────────────────────────┘
```

| Product | Role | Explicitly not |
|---|---|---|
| **Workers** | Room creation, short links, per-session TURN credential minting, static assets | Not in the media path |
| **Durable Objects** | One per call. Signaling, session clock, tier negotiation, event log, alarms | **Never a media relay** |
| **CF TURN** | Relay fallback; A/B raced against direct | Not the default path |
| **D1** | Sessions, tier decisions, quality telemetry | — |
| **Realtime SFU** | Not used. Its adaptive media stack is the thing we're replacing. | — |
| **CF Stream** | Not used. Transcodes, therefore lossy, therefore contradicts the thesis. | — |

Place the DO near the first joiner via location hints; with control-plane-only traffic its placement
affects signaling setup and clock-sync RTT, not media latency.

---

## 15. UI/UX

Simplest possible, in service of the thesis. Every element either shows the conversation or tells
the truth about the connection. Nothing else exists.

> **Build status (2026-08-02, version `735afeea`) — this section is now fully implemented.**
> It was written as a spec and for a long time only partly built, with nothing recording which
> half; a reader could not tell design from shipped code. Six items were found missing on audit
> and built the same day: the level meter, the device pickers, the capacity badge, the elapsed
> clock, the VIDEO HELD desaturation + hairline, and a headphone check that actually checks.
> Two deliberate deviations from the prose below, both because the code refuses to claim what it
> is not doing: the capacity badge reads `compressed audio` unless Lane A is actually on
> (`?pcmaudio=1`), and it names the camera's real negotiated capture rather than a fixed
> "1080p · 30". **If you change this section, say which half you changed.**

> **Changed 2026-08-02 (task #38, "the UI is bad") — the CONTROL SURFACE half was rewritten;
> the presentation half was not.** Unchanged and still accurate below: life-size rendering,
> the gaze/fullscreen table, the connection-indicator table, and Ending. Rewritten: the Lobby
> and Call subsections, which now describe icon-only glass controls, hold-to-peek self view, a
> persistent mute badge, a more sheet, a two-step leave, and the cross-device aspect policy.
> The full research basis and the 38-item list live in [`UI-SPEC.md`](UI-SPEC.md); this section
> is the summary, that file is the argument. Two deliberate deviations from that spec, both
> recorded in code comments at the site: the letterbox wash is a 32×18 sampled canvas rather
> than a second `<video>` (on the lane-2 canvas path `#remote`'s srcObject is the carrier, not
> the presented picture), and self view is press-and-hold with a 900 ms minimum reveal rather
> than a 500 ms threshold plus double-tap (a threshold makes a quick tap feel broken, and
> double-tap is undiscoverable).

### Lobby

Your face, large, already exposure-locked so you see the actual look you'll have. Device pickers
overlaid on the preview, not in a panel. A real level meter. The capacity probe resolves into a
single locked badge, naming the camera's real negotiated capture. Headphone check with a one-line
reason. One primary button: **Start a new call**, which mints a 128-bit random room and writes it
to `?r=`. Paste someone else's link and the same button reads **Join call** instead. The room is
the secret: unguessable, not enumerable, and the room object hard-caps at two — a third join gets
HTTP 409 on the socket upgrade and an honest "this link may already have two people in it" in
about a second, rather than a twelve-second stall.

### Call

Their face at **life size**, no border, no name plate, not mirrored. No self view. Elapsed time,
small, top center. The controls are six icon-only circles on dark glass, centred in the bottom
third — mic, camera, flip (only when a second camera exists), self view, more, leave. No control
renders a word; the label exists for screen readers and desktop hover. That's all of it.

Four of those are corrections to the obvious design. The first two come from §1.1, the last two
from the fatigue and touch-target literature digested in `UI-SPEC.md` §1:

- **Not edge to edge.** Filling the screen with a face renders it at roughly 40 cm apparent
  distance, which the body reads as intimacy or threat and responds to for the entire call.
  Life-size rendering targets 1100 mm — Hall's *personal* distance, where conversation actually
  happens — via an angular-size match against a calibrated display scale. The frame is frequently
  *wider* than the viewport as a result, and the sides get cropped. Cropping a 16:9 frame to hold a
  face at true scale is the right trade; scaling the face down to fit the frame is the mistake
  every video call makes.
- **No self view, by default.** It is the one thing no in-person conversation contains, and it is
  the mechanism with the strongest evidence behind it: in Fauville et al.'s ZEF work (N=10,322)
  mirror anxiety is the component that predicts fatigue. So the mirror is off the moment the peer
  arrives — the fullscreen self view crossfades out rather than shrinking into a corner. It comes
  back only while you **hold** the self-view icon, and stays only if you pin it from the more
  sheet. A peek can never latch.
- **State outlives chrome.** The bar hides after 2.6 s idle (pinned for the first 10 s so the
  vocabulary is learned once), but *state* never hides: muting yourself leaves a badge in the
  bottom-left corner that survives the bar going away. "Am I muted?" is the most common anxiety in
  every video app and it is caused entirely by hiding the answer along with the button.
- **When the two ends disagree about aspect, nothing is cropped.** Life-size mode still crops by
  design, above. Fill mode used to crop too, which on a phone-to-desktop call silently deleted the
  sides of the sender's frame — after §5 went to the trouble of forbidding the browser from
  cropping before the wire. So a mismatched aspect now switches to `contain` and paints the
  letterbox with a blurred, darkened wash sampled from the frame itself (a flat wash on a weak
  device, where the blur is not worth the compositor). Every captured pixel reaches the eye.

Two more control-surface rules, both about not making an irreversible thing easy:

- **Leave takes two taps.** A dropped 1:1 call cannot be un-hung-up. The first tap morphs the
  circle in place into a labelled pill — the one control allowed a word, because "are you sure" is
  not a thing an icon can say — and the rest of the row collapses to zero width so a finger already
  travelling toward "leave" cannot land on mute instead. A modal over a live face would be worse
  than the mistake it prevents. Three seconds, or Escape, disarms it.
- **A loud room is an icon, not a banner.** The turn-taking machinery needs a quiet-enough room to
  hear the breath before speech (§1.1c). When it can't, an amber waveform icon appears in the top
  *corner* and pulses once; tapping it expands the explanation. The previous design laid a banner
  across the middle of the other person's face to say so, which is a strange way to improve a
  conversation.

Every circle is 48 px with a 56 px hit area, dropping to 44 px only on phones under 380 px wide and
never below — Apple HIG 44 pt, Material 48 dp and WCAG 2.5.5 AAA at once. The glass is two tints,
not one: a translucent surface has no fixed contrast ratio, and blur does not reduce mean luminance
— only the tint does. Controls that sit over live video use the darker tint so a stroke glyph still
clears 3:1 (WCAG 1.4.11) against a white or yellow frame; surfaces carrying text use a darker one
still, for 4.5:1 (1.4.3). Both have an opaque `@supports not (backdrop-filter)` fallback for
Samsung Internet and older Firefox, where a "glass" panel would otherwise be a transparent one.

**Fullscreen (or a borderless window) is load-bearing, not cosmetic.** Gaze alignment works by
putting their eye line where the lens is, and the browser cannot put pixels behind its own toolbar.
Measured in `fatigue-lab/` at 600 mm on a 1920×1080 display:

| Window | Residual gaze error | Dominated by |
|---|---:|---|
| Fullscreen | **0.6°** | the eye-line floor, nothing else |
| Windowed, centred, 120 px chrome | 3.7° | browser chrome |
| Windowed, off to one side | 6.3° | window not under the lens |
| Gaze fix off, frame centred | 16.6° | — |

Roughly a 6× reduction for free, which is why the client opens fullscreen rather than offering it
as a button. It is also a point *for* the native app in §19.3: a native window can be genuinely
borderless and can sit under the lens by construction, so it starts where the browser's best case
ends. The residual is reported to the user as a number rather than asserted as a feature — the same
reason nothing else in this design claims a quality it hasn't measured.

Gaze is fixed by **layout, not ML**. Warping someone's eyes synthesises data the sender never
produced, which violates invariant 4. Moving a rectangle is honest.

**The connection indicator is the design-critical element.** Not a signal-bars icon. State-specific
and honest:

| State | Presentation |
|---|---|
| NOMINAL | Nothing at all. |
| SQUEEZE | Nothing. It's imperceptible by construction; showing it would invent a problem. |
| VIDEO HELD | Frame holds. Desaturates ~8% over 400 ms. Hairline indeterminate line at the top. Small text: **"holding · audio live"** |
| HOLD | Both held, dimmed. **"paused — reconnecting"** with elapsed time. |

Desaturation is the key move: it makes the held state *legible as intentional* — a deliberate
treatment rather than a stuck frame — without touching sharpness. The user reads "the app is doing
something" instead of "the app is broken."

### Ending

The call ends. Nothing to save, nothing to export, no dialog. It was a conversation.

---

## 16. Where the web platform is the wall

You asked about redesigning from scratch where needed. Here is precisely where the browser is the
binding constraint, ranked by how much it costs.

| # | Wall | Cost | Behind it |
|---|---|---|---|
| 1 | **No server-side WebTransport on Workers** | Forces SCTP, with all of §8's hazards | **Largely resolved by Enterprise:** QUIC/WebTransport behind Spectrum UDP (§8.1), at the cost of a non-Worker origin and a relay hop. Fully resolved if workerd ever ships it. |
| 2 | **Camera pipeline latency is opaque** | 15–35 ms, unmeasurable, uncontrollable | Native capture (AVFoundation / MediaFoundation / V4L2) gets under 10 ms and exposes real sensor control. |
| 3 | **Compositor / vsync present path** | 8–25 ms | Native fullscreen present, or a browser tear-free direct-present path that doesn't exist. |
| 4 | **`bitrateMode:'quantizer'` is Chromium-only** | Excludes Safari/Firefox from tier A+ | WebKit signalled support. Ship Chromium-first, degrade elsewhere (§17). |
| 5 | **No control over encoder reference structures** | No LTR frames, no gradual intra-refresh, so loss recovery is coarse (§9 chain model) | Native encoder APIs expose this. Would make ARQ far cheaper. |
| 6 | **usrsctp's CC is not ours** | Can silently become the binding controller | Raw UDP (native), or QUIC via Spectrum from the browser (§8.1). No longer native-only. |
| 7 | **Manual exposure/WB constraint support is uneven** | Tell 9 returns on some platforms | Native camera control. |

Every one of these resolves the same way: **a native client (Tauri/Rust) with raw UDP or QUIC and
native capture.** That client would run 30–50 ms lower glass-to-glass and would own congestion
control outright.

My recommendation is nonetheless to **build the web version first.** Walls 1, 4, and 6 are the only
ones that threaten the *thesis* rather than the *margins* — and with Enterprise, 1 and 6 now have a
paid-for escape hatch (§8.1), leaving only wall 4, which is a browser-support question rather than a
feasibility one. Walls 2, 3, 5, and 7 cost milliseconds and polish, not correctness.

So: prove the thesis on the web, where distribution is free and a link is the entire onboarding flow;
port to native for the last 40 ms once the design is validated. Building native first would mean
debugging a novel media architecture and a novel distribution problem simultaneously, and the
architecture is the part that's actually uncertain.

---

## 17. Risks and open questions

Ordered by how much of the design they'd invalidate. Each is a phase-1 measurement, not an assumption.

| Risk | Severity | Resolution |
|---|---|---|
| **SCTP can't sustain 12 Mbps at 80–150 ms RTT** | **Highest, but no longer existential** — Enterprise provides a fallback | Measure day one; phase 1 exists solely for this. If it fails: parallel PeerConnections first, then WebTransport-over-Spectrum (§8.1). Before Enterprise this risk had no floor; now it costs a hop and some VMs. |
| **The cue-damage recovery is an inference, not a measurement** | **Highest on the product thesis** | It is Boland's residual — ~609 ms once their own measured ~30–70 ms transmission delay is used instead of the unsourced 500 ms this document assumed (the old "179 ms" figure was wrong, and wrong in the direction of understating it). Attributed to destroyed turn-end cues because those cues are known and known to be codec-fragile. But nobody has shown that *restoring* them recovers the time. §3.1 levers 1–2 — the two largest in the document — both rest on this. The phase 3 gate is designed to falsify it early, and it is the single measurement most worth doing before writing the encoder. |
| Voice-onset detection false-negatives | Medium — silently forfeits lever 1 | A miss costs 200 ms of the most valuable asset in the design; a false positive costs one 60 kbps datagram. Bias hard toward firing, and instrument the miss rate against a hand-labelled corpus rather than trusting it. |
| Safari/Firefox lack `bitrateMode:'quantizer'` | High | Chromium-first. Elsewhere: high-ceiling VBR with `maxBitrate` far above need, which approximates fixed QP. Detect and honestly cap at tier C. |
| CF TURN pps limits under FEC bursts | Medium | 1,450 pps nominal vs. 5–10 kpps limit. Headroom is good, but RS parity bursts must be paced, not emitted in a clump. |
| AEC-off echo makes headphones mandatory in v1 | Medium — a real adoption cost | Ship with headphone detection; build reference-based AEC (§5) as the v2 unlock. |
| Real-world uplinks below tier C | Medium — positioning, not engineering | Tier D. Be explicit about who this is for. |
| Backgrounded tab throttles WebCodecs and rAF | Medium | Run capture/encode in a Worker; `navigator.wakeLock`; detect and enter HOLD honestly. |
| ~~**AV1 via WebCodecs is unavailable on current Macs, not just older devices**~~ | ~~**Medium — §6 has the wrong primary codec**~~ **RESOLVED 2026-08-01** | Measured, not assumed: on this Mac `VideoEncoder.isConfigSupported` rejects every AV1 configuration, including plain VBR — so it is not a fixed-QP gap or a hardware-acceleration gap, it is total absence. VP9 and H.264 both accept `bitrateMode:'quantizer'` on the same machine. §6 rewritten around fixed-QP H.264 High as the primary path (which the code already shipped: `avc1.640028`), AV1 as the opportunistic upgrade pending the runtime cpu-fallback (§17.2). Remaining: the fallback build itself. |
| 1080p60 thermal throttling on laptops | Low | Tier S is opt-in; watch for encode-latency growth and warn rather than silently degrading. |

**Resolved since first draft:** the Realtime SFU *does* support DataChannels with a `canReply`
subscriber, so it would technically work for 1:1 — but it's rejected on the technical ground in §8,
not for lack of capability. Separately, WebTransport turns out to be reachable via Spectrum UDP on
Enterprise (§8.1), which is what demotes risk #1 above.

**Still open, and answerable by the Enterprise account team (see §8.1):** how TURN's per-allocation
limits are actually enforced under a sustained hour-long 13 Mbps flow, and whether WebTransport in
workerd is on any roadmap.

---

## 17.1 What real audio measured

Everything above §17 was reasoning. This section is what happened when real recorded human
speech was played through the real pipeline — and it contains one confirmation, one new
constraint the design did not anticipate, and one number that is worse than the budget.

**The method.** Chrome accepts `--use-file-for-fake-audio-capture=file.wav`, which makes a
file act as the microphone. Everything downstream is real: real `getUserMedia`, real Opus,
a real peer connection, a real jitter buffer, the app's real detectors. Two headless
browsers, a conversation assembled from LibriSpeech inhales and utterances with every
boundary recorded to the sample, and no human in the room. `testbed/README.md` has the
mechanics; what follows is what it found.

### Confirmed: lever 1 survives the pipeline

14 planted turns, 11 opening on a real inhale, four detectors observing (own mic and
received audio on each side):

- **28/28 turns detected**, no misses on either side.
- **Onset timing error median 0 ms**, spread −6 to +6 ms against sample-exact truth.
- **Real inhale still classified as an inhale 100% of the time at the far end** — after
  capture, Opus, the network, the jitter buffer and decode. The local-versus-remote split
  is what makes this a result: the same inhale is scored twice, and a healthy local number
  with a dead remote one would have been a transport finding that no local success could
  hide. Both came back at 100%.
- **Reported head start errs negative** (median −5.7 to −11.7 ms): the detector
  under-reports the credit it has earned, which is the safe direction. Over-reporting would
  flatter the design.

So the mechanism in §3.1 lever 1 works, in a quiet room, on real breath. That is the single
most load-bearing claim in the document and it is no longer an inference.

### New constraint: the breath has a room-noise ceiling, and it is not a codec problem

A breath is only usable if it is **loud enough to clear the room** and **quiet enough not to
be speech**. Those two conditions define a window, and the window closes as the room gets
louder. Measured on rendered audio, with the breath population restricted each time to
inhales loud enough to have a chance:

| Room tone | Quietest breath above the floor | Breath below speech | Usable? |
|---|---|---|---|
| −58 dBFS (studio) | 11.6 dB | 8.3 dB | yes |
| −48 dBFS (quiet room) | 10.3 dB | 7.6 dB | yes, marginally |
| −40 dBFS (office with a fan) | 8.6 dB | **4.6 dB** | no — indistinguishable from speech |
| −33 dBFS (café) | **3.9 dB** | **2.5 dB** | no — fails both tests |

Somewhere around **−45 dBFS of broadband room noise the window shuts**, and it shuts for
reasons that have nothing to do with codecs, noise suppression, or anything this design
controls. It is the physics of a quiet sound in a loud room.

Three consequences, all of them things the document currently gets wrong by omission:

1. **§3.1 lever 1 is conditional, not universal.** The ~200 ms breath credit is available in
   a quiet room and unavailable in a noisy one. Any latency budget that spends it
   unconditionally is overcommitted.
2. **The app can already tell which room it is in.** The detector tracks its own noise floor
   (`floorDb`). A floor above roughly −45 dBFS means lever 1 is off the table, and the
   honest behaviour is to say so — the same discipline §13 applies to stalls — rather than
   silently losing 200 ms and calling it a bad connection.
3. **This is a stronger argument for headphones than the AEC one in §17.** Headphones fix
   echo; a quiet room is what makes the design's largest lever exist at all.

**Corpus-measured 2026-08-01 (209 LibriSpeech files, 88 speech + 8 breath onsets per level ×
7 floors, labels hand-checked; `testbed/corpus-score.mjs`): the window has a second wall, and
it's the quiet one.** The loud wall behaves as the table says, but in the detector's units:
breaths are still *detected* at loud floors (8/8 at −30 dBFS) yet almost never *classified* as
breaths (1/8) — heard, but indistinguishable, exactly the "no" row above. The surprise is the
quiet wall: at a −57 dBFS floor, residual inter-sentence content (exhales, mouth noise at
−50…−40) sits above the detector's fixed end-gate (`END_SNR_DB=3`), turns never close, and
**60% of utterances and 75% of breaths get no fresh onset at all** — the head-start measurement
silently vanishes in exactly the studio-quiet rooms this section calls the good case, falling
monotonically to 3% at −30. There is no high-floor *detection* collapse; the loud-floor cost is
false alarms (32 per quiet-minute at −30 dBFS). And on real read speech only ~16% of scorable
breaths produce the head-start telemetry event, vs 100% on the planted fixture — fixture breaths
follow pure room tone, real ones follow loud exhales, and the classifier was tuned on the
former. The detector's defensible operating band is a floor of **−50…−40 dBFS**; the quiet-wall
fix (an end-gate that tracks the floor, not a fixed 3 dB) and classification-in-context are the
two follow-ups. Caveat on the corpus: only 8 scorable breaths per level (±17% binomial noise) —
54 of 82 automatic breath labels sat in loud contexts where no re-onset is physically possible.

**Both follow-ups landed the same day.** The end-gate is now the *higher* of floor+3 and the
turn's own peak minus `TURN_DROP_DB` — what separates "the talker stopped" from room noise in a
quiet room is distance from the speech, not distance from the floor (gap residual measured at
p95 ≈ −24 dBFS against segment peaks of −14). Swept 8–20 dB on the corpus: **20** is the
smallest value whose peak term falls under floor+3 at the −35 floor, so the loud floors measure
bit-identical false-alarm counts (30/51/93 at −40/−35/−30, before and after) while the
clean-floor merge rate falls **60% → 19.3%** and breath classification at clean floors goes
**~16% → 5/5**; speech hard-miss stays 0.0% at every floor. The second look (voice→breath
reclassification) is now gated on the floor *at the turn's own onset*
(`RECLASS_MAX_FLOOR_DB = −42`): measured, at floors −40…−30 it bought +4 real breaths of 24
trials while flipping 24 speech onsets of ~210 — breath-shaped *speech*, since a real breath
cannot clear a loud room — where quiet floors trade 9 for 9. A breath-opened turn also gets a
longer await-voice hang (1200 ms; measured breath→speech lulls run 10–1700 ms, median ~530, so
the old 350 ms hang closed the turn inside the lull and silently discarded the head-start it had
correctly detected). App-side, full fixture through the PCM lane (run `detfix`): **7/7 turns on
all four detector paths** (every prior PCM run missed one on a remote path — classifier, never
carrier: the samples arrive bit-exact), **inhales 100% at the mic and 100% at the far end**,
onset timing median 0 ms, mouth-to-ear 68 ms round trip with one side's human gap at 296.7 ms
against Boland's 297 face-to-face. Residuals, honestly: clean-floor false alarms are now 62 over
24.1 min of speech (2.6/min — the asymmetric bias made arithmetic; they cost datagrams, not
milliseconds), 19.3% of clean-floor utterances still merge (a quiet mouth-pop is not always
separable from speech-in-progress by any energy gate), and loud-floor classification is
unchanged *by design* — the floor-gate makes the physics explicit rather than trading 6:1
against it.

### Measured and over budget: 58 ms per direction of self-inflicted delay

The two gap measurements (§3.2) can be cross-checked between machines without any clock
sync. On my machine, `perceived` = I stop → I hear them start, which contains a full round
trip. On theirs, `human` = they hear me stop → they start, which contains none. Subtract them
across the two machines and the human response times cancel — same person, same turn —
leaving only transit:

```
A perceived 935.3 ms − B human 818.7 ms  =  116.6 ms
B perceived 416.3 ms − A human 299.7 ms  =  116.6 ms
```

Two independent estimates, one per direction, agreeing to 0.0 ms. Meanwhile ICE reports an
RTT of **0 ms**, because both browsers are on one machine. So all 117 ms is ours:

```
mouth-to-ear round trip   117 ms
network                     0 ms
──────────────────────────────
our own stack             117 ms round trip  =  58 ms each way
```

ICE times a STUN ping; this times audio through encode, packetisation, the jitter buffer,
decode and playout. **58 ms one way, before a single packet crosses a network**, against a
§3 budget that assumes far less for local processing. The reported playout buffer is 31 ms
of it and is the first place to look; the rest is Opus framing and the WebRTC pipeline, which
is exactly the argument §19.1 makes for owning the transport.

This also means the levers in §3.1 are being spent against a larger base than the document
assumes. It does not change their sizes, but it does change what "we beat Zoom by X" means
until this is attacked.

### Across a real distance: the breath survives, and 43 ms of the 58 is unavoidable

A zero-RTT link can measure what the stack costs but not whether anything survives a network.
So the harness grew one: a UDP delay line in front of a TURN relay we run ourselves, with the
media forced through it (`iceTransportPolicy: 'relay'`). It is emulated distance, not the
internet — no cross-traffic, no bufferbloat, no route changes — but the datagrams, the ICE
relay candidates and the TURN allocation are all real, and the emulator lands within 3 ms of
its setting at every point (20 → 22, 80 → 82, 160 → 163, 240 → 244).

| emulated RTT | ICE RTT | mouth-to-ear | our cost each way | playout buf | head start at far end (median) |
|---|---|---|---|---|---|
| 0 | 0 | 117 | 58 | 31 | 216 |
| 20 | 22 | 109 | 44 | 35 | 191 |
| 80 | 82 | 169 | 43 | 32 | 206 |
| 160 | 163 | 263 | 50 | 29 | 186 |
| 240 | 244 | 383 | 70 | 36 | 196 |

Two things to take from it, one good and one that has to be stated carefully.

The good one: **the head start is flat across a quarter-second of added path** — 186 to 216 ms
at every distance, against 229 ms planted. §3.1 lever 1 does not decay with distance, which is
the property that makes it worth building on. Zero freezes and zero lost packets on every
clean row.

The careful one: our own cost reads 43–70 ms with **one run per point**, so the honest summary
is a floor, not a trend. What is certain is that **43 ms each way is self-inflicted at every
distance measured, including zero** — the 58 ms above is not a loopback artefact. Whether the
remaining spread is the jitter buffer growing with RTT or just run-to-run noise needs repeat
runs at each point, and until those exist this document should not claim a slope in either
direction.

### A lossy network broke the measurement, and the cause was not the one that looked obvious

The clean rows above hold. Adding 30 ms of jitter and 1% loss at 160 ms RTT does not:

| 160 ms RTT, received side | n | median | max | head starts over 300 ms |
|---|---|---|---|---|
| clean | 13 | 186 ms | 246 ms | 0 |
| 30 ms jitter + 1% loss | 13 | 246 ms | **2076 ms** | **5 = 38%** |

The fixture never plants a head start above 258 ms, so every value past 300 ms is invented.
The own-microphone side of the same call was untouched, which locates the fault precisely: it
is in the **receive** path, after the network. And the direction is the dangerous one — a bad
network makes the reported head start *larger*, so the instrument flatters the design exactly
when the design is under stress.

**The first explanation was wrong, and how it was wrong is the useful part.** Packet-loss
concealment invents audio that is broadband, aperiodic and low-level, which is precisely the
breath's signature — so the obvious reading is that the detector mistakes concealed audio for
an inhale. The evidence looked strong: 2 concealment events on the clean run against 57 on the
lossy one, and 8 of 10 inflated head starts coincided with concealment in the following second.

That coincidence was an artefact of the window it was measured in. At 1% loss concealment
happens about once a second, so a flag derived from a 2-second stats interval is almost always
true. Rebuilt at 250 ms it stopped discriminating: concealment landed within 400 ms of the
onset for 3 of 11 inflated events and 2 of 5 sound ones — the same rate. A flag that is nearly
always on is not evidence, and the first version of this section should not have been written
from it.

What the data actually says, from the 20 Hz level trace:

| the 2 s before each received onset | floor at onset | SNR at onset | quietest dip |
|---|---|---|---|
| head start over 300 ms (n=5) | **−71.0 dBFS** | **5.6 dB** | −73.2 dBFS |
| head start under 300 ms (n=8) | −64.6 dBFS | 10.2 dB | −67.9 dBFS |

The room tone is −65 dBFS in both windows. So the inflated onsets fire at 5.6 dB SNR against a
floor 6.4 dB *below* the room — they are firing on room tone itself. This is not
misclassification. It is a **wrong noise floor**, and the chain is:

1. A jitter-buffer underrun emits a brief near-silent stretch of received audio.
2. The floor's fast-drop path — 0.25 per hop, there so that a fan switching off is followed
   promptly — reads that as the room getting quieter and chases it down 6 dB in about 20 ms.
3. It recovers at the ordinary rate, 0.02 per hop, taking ~250 ms.
4. For that quarter second the onset threshold sits under the room, and ordinary room tone
   trips it.
5. Real speech arrives later. The interval between the false onset and the real first word is
   then reported as a breath head start — hence a 2076 ms maximum.

Concealment *is* involved, but as the cause of the dip rather than as a false breath. The
distinction matters because it changes the fix entirely: gating on concealment would have
suppressed real onsets during bad patches, which is the worst possible place to lose one.

**The fix: the fast path has to be earned.** What separates a room that got quieter from a
transport hiccup is duration, not depth — a room stays quieter, an underrun reverts. Measured
on the same call at full rate: every idle dip more than 6 dB below the floor lasted a single
50 ms trace sample, and the clean run at the same distance had **none at all**. So a drop is
now chased quickly only after it has persisted for 100 ms — twice the longest transient
observed, and a small fraction of any real acoustic change.

Result on the same call, same fixture, same emulated network:

| 160 ms RTT + 30 ms jitter + 1% loss | n | median | max | impossible | floor at onset | SNR at onset |
|---|---|---|---|---|---|---|
| before | 13 | 246 ms | 2076 ms | 5 = **38%** | −64.9 dBFS | 8.1 dB |
| after | 14 | 216 ms | **286 ms** | **0** | −64.6 dBFS | 12.0 dB |
| clean, same distance | 13 | 186 ms | 246 ms | 0 | −64.6 dBFS | 10.5 dB |

Every impossible head start is gone, the maximum is inside what the fixture plants, and the
floor at onset now matches the clean run to 0.2 dB. Fourteen head starts were reported rather
than thirteen, so nothing was suppressed to achieve it.

It cost about 5 ms of onset latency and, on synthetic signals, the bottom of the sensitivity
range: an inhale 8 dB over room tone used to be detected and is now missed, so the synthetic
detection floor moved from 4 dB to 12 dB. That sounds worse than it is, and the reason is worth
recording. The ungated
fast-drop path had been settling the floor **2.35 dB below the room's true level** — measured
directly on the unit-test fixture, −65.53 dBFS against a true −63.20 — because it chased every
downward fluctuation of the noise and recovered slowly. Every sensitivity number in this
document was quoted against that flattering threshold. This is the *third* appearance of the
same bug: asymmetric tracking rates cost 2.7 dB the first time (see the bug table below), and
the drop path was the same mistake surviving in a second place. Five milliseconds against a
200 ms breath credit, in exchange for a floor that does not collapse under loss, is not a close
call. And the lost sensitivity was never real either: with the floor 2.35 dB low, a 5 dB
threshold is an effective 2.65 dB, which is inside the fluctuation of a realistic room. The
unit-test fixture built for that question settles it — a room whose noise merely wobbles puts
7.8% of its hops above 3 dB — so a threshold low enough to catch an 8 dB inhale would fire on
the room itself. The old sensitivity was borrowed against false positives, and the loan came
due under packet loss.

The decisive check is real audio in the loudest room the harness has, where sensitivity is
scarcest (−48 dBFS room tone, the level the noise-suppression A/B had to be run at):

| −48 dBFS fixture, all four detectors | before the fix | after |
|---|---|---|
| onset timing error, own mic | median −1 ms, spread **−337 … 5 ms** | median 0 ms, spread **−3 … 5 ms** |
| real inhale kept, own mic | 86% | **100%** |
| worst detector of the four | 50%, flagged degraded | **75%** |
| false inhale calls | 1 | **0** |

So the change that costs sensitivity on a synthetic sweep *improves* every real-audio number
including inhale survival, and removes a −337 ms timing outlier. That is what a floor being
right rather than lucky looks like.

Two smaller things kept from the failed hypothesis, because both are useful anyway:

- **The app stamps concealment on received-side events** — `concealmentEvents` differenced at
  4 Hz, with the age of the most recent burst on every event so analysis can pick its own
  window rather than inheriting one. Reading it off the 2-second stats interval is what
  produced the wrong conclusion; the interval is recorded here so the mistake is not repeatable.
- **Analysis excludes impossible head starts rather than averaging them.** `sweep.mjs` reports
  them as their own column with a warning. A median that includes them is not a smaller version
  of the truth, it is a different claim.

Still open: **Lane 0 under loss.** Preemptive voice onset (§3.1 lever 3) sends on the
detector's word. The floor fix removes the false onsets that would have been sent, so the
exposure is much smaller than it looked — but it has not been measured with Lane 0 actually
firing, and a receive path that can invent audio deserves a second check before a send depends
on it.

### The noise-suppression A/B: real, and an order of magnitude smaller than claimed

The design's sharpest claim is that commercial noise suppression destroys the turn-end cues,
and that restoring them recovers part of Boland's unexplained residual (§3.1 lever 2). This is the
experiment that tests the part of it that can be tested. The lever is deliberately **unsized**: the
"179 ms" this document used to attach to it came from arithmetic corrected on 2026-08-02.

Both arms run **byte-identical application code**; one has
`echoCancellation`/`noiseSuppression`/`autoGainControl` forced on by an init script, which is
what every other conferencing product ships. A first attempt at −58 dBFS room tone came back
flat, and that was the experiment's fault rather than the claim's: at −58 dBFS a noise
suppressor has nothing to remove, so it behaves like a pass-through, and it can only damage
the breath while it is working. Which collides with the room-noise ceiling above — the room
must be loud enough for suppression to engage and quiet enough for the breath to exist, and
**−48 dBFS is the only level that satisfies both**.

Run there, with a fixture whose planted head starts span 193–258 ms:

| Head start reaching the detector | n | min | p10 | median | max |
|---|---|---|---|---|---|
| planted in the audio | 11 | 193 | 198 | **229** | 258 |
| all processing off (ours) | 21 | 26 | 166 | **206** | 256 |
| AEC + NS + AGC on (theirs) | 19 | 16 | **16** | **186** | 246 |

And the same thing stated as a failure rate — how often the head start was cut to under half
of what was planted:

| | cut below 100 ms |
|---|---|
| ours | 2/21 = 10% |
| theirs | 3/19 = 16% |

So the effect is real and it is directional, but its size is not what the document assumes:

- **Median cost of noise suppression: about 20 ms** (206 → 186), not 179.
- **Tenth-percentile cost: about 150 ms** (166 → 16). Suppression does not shave the breath
  evenly, it occasionally amputates the front of it. Three of nineteen came through with under
  50 ms of head start left.
- **Inhale survival was identical at 87.5% in both arms**, and turn detection was 28/28 in
  both. Noise suppression does not make the breath *undetectable*; it makes it *late*.

Two honest qualifications, in opposite directions. Against the design: the average call loses
tens of milliseconds here, not hundreds, and §3.1 lever 2 should not be sized at all on this
evidence. In the design's favour: this tests exactly **one** of the cues Boland's unexplained
residual was attributed to. Creaky voice, final-syllable lengthening and terminal pitch
contour are all untested, and all three are damaged by codecs in ways a breath is not. The
residual may still be there; this experiment simply does not reach it.

What would reach it is a real room with real microphones and a real echo path, which this
harness cannot supply — the fake microphone is a file, so there is nothing for echo
cancellation to cancel and no acoustic path at all. That is the next experiment, and it needs
two machines in two rooms rather than more code.

### Eight bugs that only real audio found

Synthetic tests passed on all eight. Three of them would have made a live call produce
garbage that looked like a quiet room, and the last one needed a *degraded* network on top of
real audio — it is invisible on a clean link at any distance.

| Bug | What it did | Why synthetic tests missed it |
|---|---|---|
| **The latch** | Chrome's fake device emits exact zeros at capture start, so the floor tracked to −320 dBFS, room tone read as 262 dB SNR, a turn opened and could never end, and the detector went silent for the rest of the call | No synthetic fixture began with digital silence. Fixed with a floor minimum, silence-excluded floor learning, and a forced-end backstop |
| **The received-audio wedge** | The same failure one layer out, and the floor minimum did not catch it: the received detector calibrates while the peer connection is still filling, when the output is near-silent but not *digitally* silent, so it is accepted as a room. Room tone then arrived 15 dB louder, opened a turn, and the drift clamp — whose entire job is to stop the floor climbing during a turn — is what stopped the floor catching up. Two turns ran to the 30-second cap on a 110-second call, swallowing the opening exchanges | Only reachable through a real peer connection: it is a property of what a jitter buffer emits before the first packet, which no local fixture has. Fixed by measuring modulation — see below |
| **Delivery-order reordering** | An `end` is emitted 350 ms after the moment it describes; an `onset` within 5 ms. Any reply inside that window arrived *before* the previous turn's end, so a clean 620 ms transition was recorded as a 16-second overlap. Every one of A's seven human transitions was destroyed; the surviving median read 2580 ms | Scripted tests fed events in chronological order, which is the one thing the real detector does not do. Fixed with a watermark buffer that holds events until nothing older can arrive, and a counter that reports it when the hold is too short |
| Biased noise floor | Asymmetric tracking rates (167:1) settled the floor in the noise's lower tail rather than at its level, costing 2.7 dB of margin — and flattering every sensitivity number measured against it | The bias only shows against real noise with a real distribution |
| Consecutive-quiet end criterion | Required 70 unbroken sub-threshold hops with a hard reset, so a turn stayed active 11,850 ms and a 4 ms click took 1505 ms to close | Real speech tails wobble across the threshold; synthetic ones stop cleanly |
| Frozen floor during a turn | The floor snapshot went stale mid-turn, leaving 35% of hops above the end threshold | Needs a turn long enough for the room to drift |
| Duplicate remote detectors | `ontrack` fires per track and the guard was checked before an `await`, so both firings attached a detector and every remote event was counted twice | Single-track test streams |
| **Floor collapse under loss** | A jitter-buffer underrun is a level drop of exactly the size the fast-drop path is looking for, so the floor chased it 6 dB below the room and took 250 ms to recover. Room tone then tripped the onset threshold, and the interval until real speech was reported as a breath head start: 38% of received head starts impossible, worst case 2076 ms against a 258 ms maximum planted | Needs loss *and* jitter *and* real audio at once. Every clean run at every emulated distance from 0 to 240 ms RTT passes. Fixed by requiring a drop to persist 100 ms before it is chased — see above |

The pattern is worth naming: **seven of eight were in the boundary between components** —
clock domains, delivery order, initialisation state, what a jitter buffer emits when it runs
dry — not inside any component's logic. Unit tests of the DSP were all passing while the
detector was silently dead.

#### The deeper pattern: every baseline in this system has been broken by its own extreme values

Count the entries above that are the same bug wearing different clothes. The latch: a floor
tracked to −320 dBFS by exact digital zeros. The received-audio wedge: a floor calibrated on a
jitter buffer that had not started. The biased floor: asymmetric rates settling into noise's lower
tail. Floor collapse under loss: a floor chasing an underrun. Four instances, one mechanism — **a
baseline defined by an extreme is defined by its worst sample.**

Then the transport gate, a subsystem sharing no code, no author's-eye view and no signal domain
with any of that, produced the fifth. One-way delay is meaningless in absolute terms because it is
measured across two clocks, so it is reported relative to a session baseline, and that baseline was
the session *minimum*. One packet on one side of one call came in 275 ms below a steady state that
was otherwise flat to within 1 ms for forty seconds. A minimum can be dragged down and has no way
back, so every subsequent packet was repriced against a floor that no other packet ever
approached. The gate then reported 277 ms of queueing delay while `bufferedAmount` read 3.4 KB —
at 12 Mbps that is 2.3 ms of data in flight, so the two numbers could not both be true. It failed
two cells that had in fact passed.

Five for five. The rule this earns:

> **No baseline is ever a minimum, a maximum, or a first sample.** Use a low percentile, keep the
> gap between it and the raw extreme, and export the gap. When they diverge, something happened
> that is worth knowing about — a device emitting zeros, a buffer that has not filled, a clock
> that stepped — and the divergence is the only evidence of it you will get.

The corollary is about direction of error, and it is what makes this a rule rather than a
preference. A poisoned baseline made the audio detector *more* sensitive and the transport gate
*more* strict — one silently loosened a threshold, the other invented a failure. Neither error
announces itself, but they announce themselves differently, so neither can be caught by watching
for one symptom. The robust estimator has a residual bias too (p1 sits at or above the true floor,
so it understates queueing), and the honest response is not to pretend otherwise but to know the
sign of it: a gate must never be lenient by accident, so the gap ships with the data.

Three of the eight were the *same* mistake in different places: a noise floor that settles
below the noise it is measuring. Asymmetric tracking rates (2.7 dB), the received-audio wedge,
and the fast-drop path (2.35 dB). Anything that estimates a floor from a fluctuating signal
wants to sit in its lower tail, and every time it does the effect is to flatter the design —
which is why it kept surviving review.

### The fix worth keeping: modulation separates a wrong floor from a long sentence

The wedge could not be fixed by loosening the drift clamp, because during real speech the
clamp is right — that is what stops a long turn dragging its own floor up and swallowing the
next onset. The two situations had to be told apart on their own terms, and what separates
them is that **speech is modulated and a wrong floor under steady noise is a flat line**.

Two independent measurements put the boundary in the same place. On a recorded call the
quietest real speech varied by **5.9 dB** over a 1.5-second window; the wedge sat at
**0.8 dB**. Separately, the synthetic harmonic-stack fixture in the unit tests varies by
**5.84 dB** over two seconds. So the threshold is set at 3 dB — roughly a factor of two clear
of both — and a turn that stays inside it for two seconds is treated as evidence that the
floor is wrong rather than that someone is talking. The detector then throws the floor away
and recalibrates against the audio actually arriving.

Measured effect: the wedge closes in **2.0 s instead of 30 s**, and a 12-second turn
modulated by only 6 dB is untouched. The 30-second cap stays as the backstop for a wedge that
is *not* flat, which is the case no test can anticipate the shape of.

This generalises past the bug. The detector now has a defensible answer to "is my noise floor
wrong?", which is the same question §17.1's room-noise ceiling needs answered — the app has to
know what room it is in, and this is the mechanism that lets it find out.

---

## 17.2 What real video measured

§13 and §19 treat the video path as unbuilt, and the *custom* path (fixed-QP WebCodecs, WebGPU
render) still is. But the interim path — stock WebRTC media, with the encoder told to stop
protecting us from ourselves — turns out to be much closer to the design's promise than
expected, and it is worth writing down exactly how close, because it changes what Phase 2 is
for.

### Four one-line changes, and 720p30 at 11 Mbps

Stock WebRTC is tuned for the opposite of what this design wants. It assumes bandwidth is
scarce, motion matters more than detail, and a smaller picture is an acceptable price. All
three assumptions are wrong here. Four settings invert them:

| Setting | Stock default | Here | Why |
| --- | --- | --- | --- |
| `contentHint` | `'motion'` | `'detail'` | Tells the encoder to spend bits on sharpness, not smoothness |
| `maxBitrate` | ~2.5 Mbps typical | 12 Mbps | The design's tier-A budget; the old value was 6 |
| `degradationPreference` | `'balanced'` | `'maintain-resolution'` | Under pressure, drop frames — never pixels |
| `scaleResolutionDownBy` | encoder's choice | `1` | Forbid the silent downscale that defeats life-size |

Measured across an emulated 80 ms round trip through a TURN relay, both directions
simultaneously, on high-detail moving content:

| | Side A | Side B |
| --- | --- | --- |
| Resolution | 1280×720, never downscaled | 1280×720, never downscaled |
| Capture → encode frame rate | 30 → 30 | 30 → 30 |
| Send rate, median | 10.37 Mbps | 10.91 Mbps |
| Send rate, peak | 12.80 Mbps | 12.84 Mbps |
| `qualityLimitationReason` | `none` for 29.75 s of 29.75 | `none` for 30.0 s of 30.0 |
| Time bandwidth- or CPU-limited | 0 ms | 0 ms |
| NACKs / PLIs | 0 / 0 | 0 / 0 |
| Encode cost | 3.19 ms/frame | 3.17 ms/frame |
| Scalability mode | `L1T1` — no simulcast, no temporal layers | `L1T1` |

`qualityLimitationReason: none` is the encoder's own statement that it achieved the quality asked
of it — not that the picture looked acceptable, but that nothing overrode the request. Zero NACKs
and zero PLIs say the receiver never had to ask for a lost packet or a fresh keyframe. Encoding
costs 3.2 ms of a 33 ms frame budget, about a 10% duty cycle, so there is real headroom above
this.

**It is not sufficient on its own, and an earlier draft of this section treated it as if it
were.** §17.5 later put the same configuration behind a 3 Mbps ceiling and watched frame rate
fall from 30 to 17 while this field still read `none` for 100% of the run and
`qualityLimitationDurations.bandwidth` stayed at 0.00 s. That is truthful — the encoder got what
it asked for and the frame *rate* gave way upstream of the quality decision, which is the policy
`maintain-resolution` selects — but it means a starved call can report itself unlimited. The pair
of numbers to read together is this field **and** encoded fps against the `media-source` fps.

For scale: mainstream conferencing tools typically deliver 720p at 1–3 Mbps and downgrade to
360p under load. This is the same resolution at roughly 4–10× the bitrate with the downgrade
path explicitly disabled.

### The caveat that keeps this honest

This was a **clean** 80 ms link — the delay line reported 140,716 packets forwarded and zero
dropped. It says nothing yet about loss, and loss is exactly where §19's Phase 1 result bites.

It also reframes §16's transport question in a way worth stating plainly, because it is easy to
carry the wrong conclusion forward: **the media path and the Phase 1 data-channel path are
different transports.** Phase 1 measured SCTP, whose loss-based congestion control collapses as
`p^−0.5` and is unusable above ~0.03% loss. Stock WebRTC video does not use SCTP; it uses RTP
with GCC, which responds to loss by lowering bitrate rather than by halving a congestion window
and stalling. So Phase 1's ceiling is a constraint on *shipping our own encoded frames over a
data channel* — the custom pipeline — and not on the interim path measured here. Those two
numbers must never be quoted against each other.

### The stimulus was the bottleneck, not the system

The first attempt at this measurement produced 5–19 fps, sliding steadily downward on one side
while the other climbed, and it looked exactly like an encoder losing a fight for CPU. It was
not. The fixture was 316 MB of raw Y4M — 41.5 MB/s of disk read per browser, 83 MB/s for the
pair — and Chrome's file-backed fake camera could not keep up. It still *advertised* a 30 fps
track, and `qualityLimitationReason` still read `none`, because from WebRTC's point of view
nothing was wrong: it encoded every frame it was given. There just weren't 30 of them.

Re-encoding the identical content as MJPEG cut the disk traffic tenfold — same resolution, same
frame rate, same visual difficulty — and both sides immediately held 30 fps in lockstep. The
asymmetry was two processes competing for one disk, and the side that lost decayed monotonically.

§17.1 collected five cases of a baseline being poisoned by its own extreme values. This is a
different failure with the same moral, and it deserves naming separately because the fix does
not follow from the earlier rule: **a test's stimulus can be its bottleneck.** An instrument
can be wrong not only in what it measures but in what it feeds the system under test. The
generalisation:

> A synthetic stimulus must be checked for headroom the same way a measurement is checked for
> bias. Ask what resource the *fixture itself* consumes, and confirm it is cheap relative to
> the thing being measured — before believing any number the run produces.

Two corollaries earned here. First, **pure noise is the wrong hard case.** It is incompressible,
so it is not a stress test of a video pipeline but of an arithmetic coder's worst case, which no
real call ever hits. High-detail *structured* motion is demanding and realistic; noise is
demanding and meaningless. Second, when the encoder reports it is not limited while output is
plainly poor, the limiter is upstream of the encoder — believe the counter and look earlier in
the chain.

### Which codec and resolution 12 Mbps actually buys

The four settings above tune *how* the encoder spends its budget. They say nothing about which
encoder, and the default — VP8 at 720p — turned out to be the largest single quality loss in the
pipeline. VP8 is a 2008 codec kept for universal compatibility, which is a constraint this design
does not have: it is 1:1 between two browsers we control, not a broadcast to unknown receivers.

Measured with VMAF against a 1080p master, encoding each candidate at its own resolution and
scaling back to 1080p to score — the upscale is part of what the viewer actually sees, so
including it is what makes a cross-resolution comparison fair. Two masters: one pathologically
detailed (a Mandelbrot zoom), one call-like (large smooth regions with localised moving detail,
which is what a face and torso are).

First pass, all encoders given the full 12 Mbps:

| Config | hard master | call-like master | bits used |
| --- | --- | --- | --- |
| VP8 720p *(previous default)* | 64.5 | 70.4 | 12.0–12.4 Mbps |
| VP9 720p | 64.6 | 70.3 | 8.6–9.3 Mbps |
| VP9 1080p | 70.5 | 74.1 | 9.2–10.2 Mbps |
| H.264 1080p (x264 veryfast) | 88.7 | 96.4 | 11.3–12.4 Mbps |
| AV1 1080p (SVT preset 10) | 88.8 | 94.7 | 13.7–15.8 Mbps |

That is a ~26-point spread, and the mechanism is in the last column: **VP9's realtime rate control
leaves 20–28% of the budget unspent.** Bits withheld are quality forgone.

x264 is not what Chrome uses, so the arms were then re-run in the browser and re-scored with
`h264_videotoolbox` — the same hardware encoder Chrome hands H.264 to — at the bitrate each codec
*actually achieved* in a real call:

| Codec, in Chrome | Encoder | fps | Delivered | ms/frame | VMAF at delivered rate |
| --- | --- | --- | --- | --- | --- |
| VP8 720p *(previous default)* | libvpx (software) | 29 | 8.32 Mbps | 3.14 | 68.9 |
| VP9 1080p | libvpx (software) | 27 | **6.23 Mbps** | 4.46 | 70.6 |
| **H.264 1080p** | **VideoToolbox (hw)** | **30** | 11.00 Mbps | 8.08 | **95.5** |
| AV1 1080p | libaom (software) | 30 | 9.96 Mbps | 4.57 | **96.7** |

Each row is scored at the bitrate that codec *actually delivered in Chrome*, which is the only
basis on which they are comparable — and getting that wrong is easy. `h264_videotoolbox` under
ffmpeg undershoots its target by about 30% (ask 12 Mbps, get 8.4), so scoring an encode that was
merely *asked* for 11 Mbps rates H.264 at 91.3. Chrome does not undershoot: its H.264 arm put 11.0
Mbps on the wire against a 12 Mbps cap, and at a delivered 11.2 Mbps the score is 95.5. The
correction matters because it changes the conclusion's strength — H.264 is not "good but behind
AV1", it is level with it.

The measured curve for delivered bitrate, 1080p, hardware H.264:

| Delivered | 5.6 Mbps | 8.4 | 11.2 | 14.0 | 19.4 |
| --- | --- | --- | --- | --- | --- |
| VMAF | 86.1 | 92.5 | **95.5** | 97.0 | 98.5 |

Returns flatten hard above ~11 Mbps: the last 8 Mbps buys 3 points. That is a useful thing to know
about the §18 cost model — tier A at 12.5 Mbps sits almost exactly at the knee, which is where it
should be, and paying for 20 Mbps would be buying very little.

**So H.264 at 1080p gains ~26 VMAF points over the previous default** while moving the encode off
the CPU onto hardware. VMAF in the mid-90s is where compression stops being the thing you notice;
high 60s is visibly degraded. Three independent observations point the same way: VP9 undershoots
its budget in realtime, 1080p beats 720p at equal bitrate on both masters, and hardware H.264
spends what it is given.

AV1 edges it at 96.7, and in the browser held 30 fps at only 4.57 ms/frame — *better* than H.264's
8.08, because a hardware encoder's `totalEncodeTime` includes the async round trip and so reads
slower while costing almost no CPU. The default is still H.264, deliberately: **AV1 has no hardware
encoder here.** On an unknown machine, software AV1 at 1080p30 risks a CPU-limited stuttering call,
and 1.2 VMAF points is a trivial price for avoiding that. The right resolution is a runtime one —
start on AV1, watch `qualityLimitationReason` for `cpu`, fall back — which needs renegotiation and
is not yet built.

HEVC also has a hardware encoder here and Chrome does offer `video/H265`. At an identical 8.4 Mbps
it scores 95.0 against H.264's 92.5, and 98.2 at 14 Mbps — genuinely better per bit. It is not the
default because H.265 in WebRTC is recent and unevenly available, and a codec choice must never be
the reason a call fails; it is the obvious next thing to try once there is a fallback path.

Two cautions on these numbers. VMAF was trained on natural video and both masters are synthetic,
so the absolute values are softer than the ranking; every arm saw identical content, so the
comparison holds even where the absolute score does not. And `setCodecPreferences` *reorders*
rather than restricts — every codec the browser offered is still offered, just in our order — so a
peer that cannot do H.264 still connects on VP8. A codec preference must never be able to prevent
a call.

### A 20 fps ceiling that had been invisible the whole time

Telemetry sampled `outbound-rtp` but never `media-source`, so it recorded the *encoded* frame
rate and nothing about what the camera actually produced. Those two are not the same number:
the encoded rate is silently the minimum of what was captured and what the encoder managed, and
a low value has three unrelated causes — a camera that never delivered, an encoder starved of
CPU, or a network forcing drops — each with a different fix.

Adding `media-source` immediately surfaced something that had been distorting results
invisibly: **Chrome's built-in fake camera runs at 20 fps, not 30.** Every frame-rate number in
the entire test history carried a 20 fps ceiling that no one had measured, and the default
device also produces only ~0.45 Mbps because its test pattern is trivially compressible — so it
cannot exercise a 12 Mbps ceiling even in principle. Both facts were unknowable until capture
and encode were sampled separately.

This is why the comparison is now part of the standing telemetry rather than a one-off debug
step: the first real diagnosis of a bad call will hinge on splitting camera from encoder, and
guessing costs more than sampling.

---

## 17.3 The audio was never configured at all

§1 asks for audio that feels like a recording, and every measurement in §17.1 was about *timing*
— breaths, gaps, turn-taking. Nobody had looked at audio **fidelity**. The app was shipping
Chrome's Opus default, and nothing in the telemetry sampled outbound audio, so there was no
number anywhere in the project that would have revealed what that default was.

Measured: **28 kbps.** For comparison, the video path beside it was spending 8,300. Audio was
getting 0.3% of the bit budget while carrying most of the conversation.

### What bitrate buys

libopus against the real conversation speech (task #8), segmental SNR — per-20 ms-frame SNR
clipped to [−10, 35] dB then averaged, which is the standard form because unclipped SNR is
dominated by silence where a tiny absolute error is a huge relative one:

| Opus application mode | 32 kbps | 48 | 64 | 96 | 128 |
| --- | --- | --- | --- | --- | --- |
| `voip` — what libwebrtc uses for mono | 2.85 | 3.57 | 3.92 | 5.05 | 5.50 |
| `audio` | 7.79 | 9.65 | 10.81 | 13.91 | **15.81** |

Monotonic in bitrate, with no knee inside the useful range. So the default is now **128 kbps**,
requested two ways: `maxaveragebitrate` in the Opus fmtp line, and a matching `maxBitrate` on the
audio sender.

Which of those actually does the work was settled by accident. A production deploy propagated
unevenly and the two browsers loaded different versions of `app.js` — one with the SDP munge, one
without — which ablated the levers for free. The old-code peer's offer carried no
`maxaveragebitrate` at all, and the far end **still reached 125 kbps with `targetBitrate` at
exactly 128000**, on the strength of the sender cap alone. So the two are redundant, not jointly
required, and the sender cap is the one that moves Chrome. Both are kept: the fmtp parameter is
the standards-defined way to ask (RFC 7587) and is what a non-Chrome peer would honour.

The uneven propagation is worth noting for its own sake, because it is the second time this
session that stale assets looked like a defect. Two peers can run different code for a few
minutes after a deploy, and the only reason that was diagnosable here is that the negotiated
fmtp is now in the telemetry.

### The reason this is nearly free

The obvious objection to quadrupling audio bitrate is that it should quadruple exposure to
packet loss. It does not, and the measurement says so plainly:

| Arm | packets sent | bytes/packet | audio kbps | packets lost |
| --- | --- | --- | --- | --- |
| 32 kbps ask | 1492 | 69 | 28 | 0 |
| 128 kbps ask | 1487 | **321** | 127 | 0 |

**Identical packet count.** Opus's packet rate is set by frame duration — 20 ms, so 50 packets
per second — and is completely independent of bitrate. Raising the rate makes each packet
larger, not more numerous, and a lost packet destroys one 20 ms frame either way. The cost is
128 kbps against a 12 Mbps video budget, about 1%, for no additional loss exposure at all.

### The mode lever, measured: a no-op at 128 kbps

The table above says the application *mode* matters more than the rate: `audio` at 32 kbps beats
`voip` at 128. libwebrtc derives that mode from channel count — 1 channel selects voip, 2
selects audio — which would make `stereo=1` the only lever that reaches it from SDP. The browser
A/B that could settle it needed two things the project did not have: a full-band stimulus (the
conversation WAV is 8.7 kHz wide and cannot distinguish fullband CELT from wideband SILK even
in principle) and a capture path for the decoded remote audio. Both were built for task #21:
a 25 s white-noise WAV (flat to 20 kHz) as A's microphone, and a spectrum tap on the far end —
a capture AudioWorkletNode on the decoded remote stream, PCM shipped out for an offline FFT.
(An AnalyserNode was tried first and is **deaf on this graph**: −58 dB where a worklet on the
same context and stream hears −18 dB, direct and on a cloned track alike. The worklet is the
node type that pulls. Six debugging generations went into that floor before the node type was
isolated as the cause.)

The arms, RTT 80 / 0% loss, `tape=2` both sides, the only difference `astereo=1`:

| band (Hz) | default | `stereo=1` | Δ |
| --- | --- | --- | --- |
| 0–1000 | −58.7 | −58.3 | +0.4 |
| 1000–4000 | −58.2 | −58.2 | 0.0 |
| 4000–6000 | −58.3 | −58.3 | 0.0 |
| 6000–8000 | −58.3 | −58.3 | 0.0 |
| 8000–10000 | −58.2 | −58.2 | 0.0 |
| 10000–12000 | −58.2 | −58.2 | 0.0 |
| 12000–16000 | −58.2 | −58.2 | 0.0 |
| 16000–20000 | −59.9 | −59.9 | 0.0 |

**Identical to the noise floor of the method.** The pre-registered decision rule (≥10 dB more
energy above 8 kHz = lever is real) fails by ten thousand times. The lever is **dropped** —
the `?astereo=1` knob stays in the code as the control arm, annotated as a measured no-op.

And the control arm carried the real finding: the default chain is already **flat to 20 kHz**.
White noise injected at A's microphone arrives at B's decoder with equal energy in every band
including 16–20 kHz. At 128 kbps Opus runs fullband CELT regardless of what the application
hint asks for — the mode decision the offline table measured is a *low-bitrate* decision, and
this project does not operate at low bitrates. The segSNR gap between `voip` and `audio` is
real in libopus and irrelevant here, the same way a winter-tire test is real and irrelevant in
July. The discrimination control: A's tap hears B's speech fixture with the speech shape
(−78 dB at 0–1 kHz rolling to −114 dB at 16–20 kHz), so a flat spectrum is the stimulus, not
a deaf tap.

`codec.channels` remains a trap worth repeating: it reads **2 in every arm** because RFC 7587
mandates `opus/48000/2` in rtpmap unconditionally — it describes the payload format and is not
a proxy for the encoder's mode.

One parameter was set from reasoning rather than measurement, and it is worth naming because the
reasoning is specific to this project: **`usedtx=0`**. Discontinuous transmission saves
bandwidth during silence, which is bandwidth this design is not short of, and it hands the far
end's concealment a job. Concealed audio is broadband and aperiodic — which is precisely the
onset detector's signature for a breath (§17.1). DTX would manufacture false breaths inside the
one measurement this project exists to make.

---

## 17.4 The jitter buffer, and what the fixture will not let us see

§14 targets the 43–58 ms of delay this system inflicts on itself, and the receive-side playout
buffer is the largest single piece of it. The app already asked for the minimum via
`playoutDelayHint = 0`, which is Chrome's legacy non-standard hint; `jitterBufferTarget` is the
standards-track request for the same thing. Measured playout was still holding 30 ms with only
the legacy hint set, so the hint was not getting everything available.

This is not a free knob, which is why it was measured before being turned on. A shorter buffer
means more concealment under loss, and concealed audio is the onset detector's own false-positive
signature (§17.1). The question was never whether the number gets smaller — it was whether
buying latency corrupts the measurement.

At 1% loss, 80 ms RTT, 15 ms jitter, three runs each direction (n=6 sides per arm), 30 s each to
stay inside the §19 relay cliff:

| | audio playout, mean (range) | concealed samples per lost packet | packets lost |
| --- | --- | --- | --- |
| Chrome default | 56.40 ms (46.6–62.1) | 961 | 78 |
| `jitterBufferTarget = 0` | 51.92 ms (43.3–60.2) | **924** | 64 |

**Concealment per lost packet is flat** — 961 against 924 across 142 lost packets. The risk does
not materialise, and that is the finding that decided the default. The latency column is *not*:
4.5 ms of mean difference against a ~16 ms within-arm spread at n=6 is within noise, and a single
run had suggested 15 ms purely by luck of the loss draw. So the knob is on because it costs
nothing and expresses an intent the app already declares, not because 4.5 ms was established.

Normalising concealment per lost packet rather than comparing raw counts is what keeps this
honest: the two arms drew different amounts of loss (78 vs 64), so raw concealment counts would
have shown a flattering 30% "improvement" that is entirely an artifact of having lost less.

### The audio playout floor is not measurable with a file-backed mic

The clean-network arms would not resolve at all, and the reason is worth recording because it
invalidates a measurement anyone would reasonably try next. NetEq reported:

| | samples removed for overrun | inserted for underrun | audio resampled per 30 s |
| --- | --- | --- | --- |
| A | 1745 | 2847 | **96 ms** |
| B | 2730 | 3691 | **134 ms** |

Chrome is stretching and compressing roughly a tenth of a second of audio every 30 seconds to
track a source clock that drifts about 0.4%, because `--use-file-for-fake-audio-capture` feeds
from a file rather than from a sound card locked to a crystal. NetEq holds a defensive buffer
*because of the fixture*. The ~30 ms clean-network floor is therefore an artifact, and no
receiver-side setting will move it in this harness — under real loss the network dominates and
the comparison works, which is why the table above is the lossy one.

That is the fourth time on this project that the stimulus, not the system, set the limit — after
the 316 MB Y4M starving the camera, the 20 fps fake-camera ceiling, and the 8.7 kHz audio fixture
in §17.3. The pattern is consistent enough to be a standing rule: **before believing a floor,
check whether the fixture is the floor.**

---

## 17.5 The central claim, finally under pressure

Everything measured up to this point was on a link with no capacity limit. On loopback GCC probes
upward without finding a ceiling — `availableOutgoingBitrate` reached 39.7 Mbps against a 12 Mbps
cap — so "1080p30, `limit=none`, zero NACKs" was true and untested. §1's claim that **quality is a
constant and time is the only shock absorber** had never actually had to absorb anything.

netsim now has a token-bucket bottleneck per participant per direction that queues and tail-drops
(`testbed/netsim.mjs`, reached with `--bw=<Mbps> --queue=<ms>`). It queues rather than merely
discarding excess because GCC infers congestion mainly from the delay gradient of a filling queue
and only secondarily from loss, so a pure dropper would exercise the wrong signal. Capacity is
*not* divided across the two relay crossings the way loss is — loss compounds, capacity does not,
and halving it would emulate half the link the label claims.

Verified before use, overdriven 4×: delivered rate lands within 0.2% of the
ask at 1, 3, 5, 12 and 25 Mbps, `sendErrors` 0, and queue depth changes delay without touching
rate (17 / 98 / 398 ms measured at 20 / 100 / 400 ms configured).

Four ceilings, 30 s each, no added delay or loss so the capacity variable stands alone:

| Ceiling | Resolution | fps | Delivered | GCC target | Frames dropped | Freezes | Audio | Video playout |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 3 Mbps | **1920×1080** | **17–18** | 1.90–2.29 | 2.07–2.09 | 0 | 0 | 127 kbps | 86–109 ms |
| 5 Mbps | **1920×1080** | 30 | 3.90–4.03 | 4.32–4.43 | 0 | 0–1 | 125 kbps | 123–165 ms |
| 8 Mbps | **1920×1080** | 30 | 4.77–5.00 | 5.84–6.31 | 0 | 0 | 127 kbps | 48–81 ms |
| 12 Mbps | **1920×1080** | 30 | 7.33–7.95 | 8.52–8.69 | 0 | 0–1 | 128 kbps | 47–84 ms |

**The claim holds.** Resolution never moved, at any ceiling, down to a quarter of the design's
budget. At 3 Mbps frame rate took the entire hit — 30 down to 17 — which is precisely what
`maintain-resolution` plus `contentHint = 'detail'` is for, and it degraded *smoothly*: zero
dropped frames and zero freezes, so the result is slow motion rather than stutter. Audio kept its
full 128 kbps at every ceiling, including 3 Mbps, because WebRTC allocates audio first. That is
the right priority and it was worth confirming rather than assuming.

### `qualityLimitationReason` reads `none` through a 40% frame-rate loss

The single most important thing in that table is a column that did *not* move.
`qualityLimitationReason` was `none` for **100% of the duration at every ceiling**, including the
3 Mbps run where frame rate nearly halved. `qualityLimitationDurations.bandwidth` was 0.00
seconds throughout.

It is not lying. The encoder was asked for 1080p at whatever bitrate GCC allocated, and it
delivered exactly that — the frame *rate* gave way upstream of the quality decision, which is the
policy this design chose. But it means the field cannot be used as a health signal on its own,
and §17.2 leaned on it as one. A call can be at 17 fps on a starved link and report itself
unlimited. **Frame rate has to be watched separately, against the `media-source` rate**, which is
the same lesson the 20 fps fake-camera ceiling taught in §17.2 arriving from the opposite
direction. There is no floor API for frame rate, so watching is the only option available on
stock WebRTC.

### GCC leaves a third of the link unused

Delivered rate against the ceiling: 63–76% at 3 Mbps, 78–81% at 5, 60–63% at 8, **61–66% at 12**.
At a 12 Mbps ceiling — exactly the design's budget, on an otherwise idle link — the app sends 7.3
to 8.0 Mbps and leaves 4 Mbps unspent. Bits withheld are quality forgone: from the §17.2 curve
that is roughly 92 VMAF where 95.5 was available.

This is not a bug to fix in the app, and raising `maxBitrate` would not touch it — GCC's estimate,
not our cap, is what binds. It is a straightforward cost of stock WebRTC's loss-and-delay-based
congestion control being deliberately conservative through a relay with 100 ms of buffering, and
it is one of the clearer arguments for §9/§16: a transport that knows its own budget can spend it.

### The trade this exposes, stated rather than resolved

Holding 1080p at 2 Mbps is 0.03 bits per pixel. The §17.2 curve does not extend that low, but at
5.6 Mbps 1080p already scores 86, so 2 Mbps is well below anything measured and 720p30 would
almost certainly look better than 1080p17 there. The design holds resolution anyway, on purpose,
because life-size rendering (§1.1a) breaks if resolution moves — a face that changes physical size
mid-call is a worse artifact than a soft one. But the crossover is real, it has not been located,
and pretending resolution-constancy is free at every bitrate would be dishonest. Locating it needs
VMAF on decoded call output rather than on offline encodes, which is the same missing capture path
that blocks §17.3.

---

## 17.6 The custom video lane exists, and it found the transport's ceiling

*(2026-08-01, testbed runs `tape-first`, `tape-lossonly/bwonly/rttonly`, `ab-fecoff/fecon`,
`mathis*`. Code: `tape-app/public/tape.js`, gated behind `?tape=1`.)*

§13's fixed-QP video path is no longer zero lines. `tape.js` is the pipeline §1 asks for:
camera → `MediaStreamTrackProcessor` → admission control → `VideoEncoder` with
`bitrateMode: 'quantizer'` → fragmentation with XOR-parity FEC → unordered zero-retransmit
datachannel → reassembly/repair → `VideoDecoder` → `MediaStreamTrackGenerator` into the same
`<video>` element. Audio stays on RTP (§17.3's 128 kbps Opus). Any failure falls back to the
ordinary RTP video track and renegotiates — the user loses the experiment, never the call.

### The capability question that gates everything, answered first

`testbed/wcprobe.mjs`, Chrome 149: `bitrateMode: 'quantizer'` is supported for H.264 High, VP9,
and AV1 at 1080p30 realtime, and the per-frame `avc.quantizer` knob works. At constant QP 24 a
flat grey delta frame cost **40 bytes** and a noise frame cost **170,019 bytes** — 4250× — which
is the design's spine ("quality is a constant, time is the only shock absorber") observable in a
single measurement. Nothing about the fixed-quality design requires leaving the browser. (Trap
for later readers: WebCodecs is secure-context-only, and probing on `about:blank` reports every
API missing. That is the probe's origin, not the browser.)

### What the lane does on a clean path

899/899 frames admitted, zero loss, zero decode errors, and **frame age p50 of 0.9 ms** —
sender wall clock to decode, clock-offset corrected. Over an 80 ms RTT emulated path: age p50
41.7 ms ≈ 40.2 ms of propagation + **1.5 ms of pipeline**. QP 24 at 1080p30 on this fixture
costs 11.7 Mbps. These are the first true one-way video latency numbers this project has ever
had, because for the first time both ends of the pipe are ours and every frame carries its own
timestamp.

### What it does under loss, and why that number is a law, not a bug

At 1% random loss with **no bandwidth ceiling at all**, the first version delivered zero frames
in 30 s. Three sizing bugs (admission threshold smaller than one keyframe; reassembly deadline
shorter than a keyframe's own serialization time; keyframe-request interval shorter than the
round trip) amplified it, but fixing them, and adding FEC, moved almost nothing — and the FEC
A/B said why. With 13% parity overhead the lane sent *exactly the same total bytes* as without
(5.1 MB): redundancy displaced payload instead of adding to it. Something upstream holds
throughput fixed.

That something is SCTP's loss-based congestion control, and it follows the Mathis law
(~`1.22·MSS/(RTT·√p)`) almost exactly:

| injected loss | measured | Mathis predicts |
|---|---|---|
| 0.03% | 4.61 Mbps | 7.75 Mbps |
| 0.1% | 3.68 Mbps | 4.24 Mbps |
| 0.3% | 2.24 Mbps | 2.45 Mbps |
| 1.0% | **1.31 Mbps** | 1.34 Mbps |

`maxRetransmits: 0` turns off *reliability*, not *congestion control*. Every datachannel rides
one SCTP association whose window halves on loss it should be ignoring. No application-level FEC
can beat this, because the collapse happens below us: parity packets shrink the window's room
for payload one-for-one.

### The §16 decision, made by measurement

**SCTP is disqualified as the video transport beyond ~0.1% loss.** The same emulated 1% loss
that pinned this lane at 1.3 Mbps carried **8.85 Mbps of RTP video** in §17.5's head-to-head,
because GCC infers congestion from delay gradient and mostly shrugs at random loss. The
fixed-QP *encoder* is proven; the *lane* it needs must have delay-based congestion control.
The candidates, in order of plausibility:

1. **RTP as the carrier for our bytes** — an `RTCRtpScriptTransform` on a video sender replaces
   encoded payloads after libwebrtc's encoder and before the packetizer, keeping GCC, NACK/RTX,
   and the jitter buffer while the QP decisions are ours. **Measured viable**
   (`testbed/rtplane.mjs`, same day): 238/239 substituted frames arrived byte-perfect at the
   receiver's transform, at every size from 60 B to 60 KB (the 239th was in flight at
   shutdown). Three traps, all found by instrument rather than argument: (a) Chrome ships the
   transform event as `e.transformer`, not the spec's `e.transform`; (b) the receiver's
   depacketizer parses the head of the payload as a codec header — fully foreign bytes put
   4.2 MB on the wire and assembled *nothing*, and preserving VP8's SFrame-style clear region
   (10 bytes key / 3 delta) fixed it; (c) the receive transform must be installed synchronously
   inside `ontrack` — attached a few microtasks later, before ICE even completed, Chrome routed
   all 238 frames around it. Still unmeasured: throughput under 1% loss (the number that
   decides), and taming the carrier decoder's PLI chatter (22 PLIs/8 s) once it sees bytes it
   cannot decode.
2. **WebTransport datagrams** — QUIC, but client-server: it needs a relay at the edge and
   reintroduces §19's relay tax that this session's relay-free work just eliminated. Also its
   congestion controller is the browser's choice, not ours, and unmeasured under random loss.
3. **Native (§19.1)** — where the transport is genuinely ours. The Android question resolves to
   this: nothing *above* the transport needs native, and the transport question should be
   settled cheaply in the browser first.

Meanwhile the fixed-QP lane as built remains the right transport for the clean-path case it
measured: 1.5 ms of pipeline is the number every alternative has to beat.

---

## 17.7 Lane 2 under pressure: the carrier becomes the transport, and the pacer gets a governor

*(2026-08-01, testbed runs `lane2-slot5/6`, `lane2-claim2`–`claim7`, `lane2-surv1`–`surv4`,
`lane2-pace1`–`pace4`, `lane2-loss1*`. Code: `tape-app/public/tape.js` + `app.js`, `?tape=2`.)*

§17.6's option 1 — RTP as the carrier for our bytes — is now the lane. The fixed-QP WebCodecs
stream (QP 24, 1080p30, ~50 KB a frame, ~12 Mbps on this fixture) is spliced into a VP8
"carrier" RTP stream by an `RTCRtpScriptTransform`; the carrier exists to be a clock and to
make GCC, NACK/RTX, and the pacer carry bytes they cannot read. The decisive criterion from
the task ledger — **≥ 8 Mbps sustained at 1% random loss, RTT 80 ms** — is met in both
directions, with zero lost frames. Getting there required five more measured laws and one
small congestion controller, because every failure on this path is silent.

### The transceiver laws — all measured, all silent

One direction per m-line, from §17.6, turned out to be the first of five. The rest, in the
order they bit:

1. **Chrome's m-section matching never matches a pre-created transceiver** (`lane2-slot5`).
   The answerer's sendonly carrier transceiver, created before the offer arrived, matched
   *nothing* in the offer — both offered video sections got fresh transceivers regardless of
   direction, and the carrier stayed unassociated until a reoffer assigned it a mid. So the
   offerer adds a **recvonly video slot to the first offer** (a transceiver with no track
   costs nothing), and the answerer **claims it by hand**: parse the offer's last video
   section's mid, find the transceiver Chrome created for it, set it sendonly, move the
   carrier in. The first answer then carries both carriers; the reoffer — whose answer was
   measured to vanish between relay and delivery at real RTTs, silently — no longer exists.
2. **The transform goes on before the track** (`lane2-claim3`/`claim4`). `replaceTrack()`
   builds the sender's pipeline and reads `sender.transform` *at build time*. Attach after
   and the sender is hooked yet bypassed forever: 447 raw carrier frames sent, zero transform
   ticks, no error. Attach before and both carriers flow at ~11.6 Mbps through an 80 ms path.
3. **The answer builds the offerer's receive pipeline before `ontrack` fires**
   (`lane2-claim6`/`claim7`). §17.6's rule — attach the receive transform synchronously
   inside `ontrack` — is necessary but not sufficient: it holds for the answerer (whose
   pipeline is built later, at answer time), but the offerer's slot receiver is built inside
   `setRemoteDescription(answer)`, and the `ontrack` that fires 2 ms later is already too
   late — hooked, zero frames, 22.4 MB carried at the RTP level with the lane decoder seeing
   none of it. The offerer therefore attaches the receive transform **at slot creation**,
   next to `addTransceiver`. General form of laws 2–3: *the pipeline reads `.transform` once,
   at build time; find what builds the pipeline and attach before that.*
4. **Neutralize the orphan; never `tx.stop()` it** (`lane2-claim2`). The claim leaves the
   original carrier transceiver orphaned, sharing the cloned track. Stopping it starved the
   claimed slot's encoder (the clone fed both senders; killing one killed the frame flow to
   the other) *and* queued a `negotiationneeded` that no offer ever settled — a ~1000-cycle
   offer/answer storm in 15 s. `replaceTrack(null)` + `direction='recvonly'` empties it
   without either harm.
5. **Lane 2 never renegotiates** (`lane2-claim5`). With the carrier alive, the guarded
   reoffer still fired — and processing the reoffer *rebuilt the answerer's receive pipeline
   without the transform* (law 3 again, triggered by the peer). A's lane-2 receive died the
   moment B's reoffer landed, 2 ms after the attach. The guard is now hard-gated on
   `wantTape === 2`: the claim leaves nothing to negotiate, the orphan is harmless
   unassociated, and the lane-2 fallback needs no negotiation either (it `replaceTrack`s the
   camera onto the already-negotiated carrier sender). Signaling per call: one offer, one
   answer, single digits of messages — versus 972 offers before the gate.

### The pacer is the real transport, and it needed a governor

With both directions flowing, the remaining failures were all one failure: **Chrome's pacer
queue is invisible to every local signal.** The GCC grant starts at ~2.6–3 Mbps and ramps over
~12 s (the `x-google-min-bitrate`/`start-bitrate` fmtp knobs are confirmed *not honored* —
the autopsy is `scratchpad/v15-autopsy.md`). Inject 12–15 Mbps anyway and the pacer queues it:
a measured **1.44 s queue-age drop ceiling**, a contiguous 36–44-frame *sender-side* hole at
startup (receiver `packetsLost=0` — the frames never reached the network), and a permanent
~1.5 s of latency when the injected rate exceeds the grant's asymptote (15.2 Mbps with parity
vs ~12–14 Mbps granted — the queue never drained in 30 s).

The `inFlight` capture gate cannot see any of this: it throttles to the carrier's *tick* rate
(the encoder feeds the transform at 30/60 fps no matter what the pacer is doing), not the
pacer's *drain* rate. The one quantity that sees the backlog is the receiver's per-frame age
(capture → decode, clock-offset corrected — both ends of the pipe are ours). So the receiver
reports its age window over the ctl channel every second, and the sender paces capture
admission on it — additive increase while p50 < 250 ms, decrease ×0.6 when p50 > 400 ms or
p95 > 900 ms, hysteresis between, 5 fps start, 34 fps cap. Skipped captures never reach the
encoder, so throttling is invisible to the reference chain — the design spine, applied to
congestion: quality stays a constant, the frame *rate* absorbs the shock. (Two supporting
measurements: the clock offset is EWMA-smoothed because a single ping's asymmetric RTT made
ages noisy enough to trip false halvings, `lane2-pace1`; and `outbound-rtp.targetBitrate` is
*not* a usable grant signal — it is the encoder target, polluted by the thumbnail carrier's
resolution cap, measured 1.5 Mbps on a sender simultaneously pumping 12.)

Two more carrier facts fell out of the governor's numbers. One tick carries one tape frame,
and parity frames spend ticks too — so a 30 fps carrier capped data at 30 × G/(G+1) = **22.5
fps** (`lane2-pace2`). And a cloned camera track can never tick faster than the camera
(`lane2-pace3`: a 60 fps ideal on a 30 fps source still ticks 30/s). The carrier clock is now
a 320×180 `canvas.captureStream(60)` — its pixels are irrelevant, static-content P-frames
cost tens of bytes on idle ticks, and 60 ticks/s lifts the data ceiling to 45 fps at G=3,
above the camera's 30: the tick budget never binds admission again.

### The decisive run

`node call.mjs --tag=lane2-loss1 --q='tape=2' --video=cam1080.mjpeg --ms=30000 --p2psim
--rtt=80 --loss=1`, verbatim from the task ledger:

| direction | sustained (last 10 s) | frames lost | keyReqs | age p50 | FEC repairs |
|---|---:|---:|---:|---:|---:|
| A → B | **11.98 Mbps** | 0 | 0 | 132 ms | 26 |
| B → A | **9.07 Mbps** | 0 | 0 | 90 ms | 33 |

Against the same path without the governor and FEC (`lane2-loss1-nofec`): 3,709–5,387 frames
lost, 47–54 keyframe requests, decoders stalled for 20+ seconds at a stretch. With FEC but
without the governor (`lane2-loss1-fec`): 177–412 lost, age p50 1,535 ms — the loss protection
worked and the latency was unusable. All three pieces — FEC, the governor, the 60 fps clock —
were needed for the row above. At loss 0 the same code delivers 30 fps admitted with age p50
**71–73 ms** through an 80 ms path: 40 ms of propagation, ~30 ms of everything else
(`lane2-pace4-l0`). The startup hole is gone not because it was patched but because its cause
is: the pacer is never over-injected, so its queue never reaches the drop ceiling. Survival
across the batch: 4/4 runs, both directions alive, before and after.

What the governor costs: the first ~15–25 s of a call ramp 5 → 30 fps as GCC's grant ramps
underneath (additive probing overshoots and halves, twice on average). This is GCC's own ramp
speed made visible, not an added tax — and it is the honest version of the same seconds the
old path spent dropping frames into a 1.4 s queue.

### What is still unexplained

One mystery survives, bypassed rather than solved (`lane2-slot6`): an answer sent through the
relay was received by the peer's WebSocket (`ws-rx` logged, correct signaling state) and then
`setRemoteDescription` neither applied it nor threw — no event, no error, no state change.
The slot-claim architecture means no answer can ever be load-bearing again, so the bug is
dormant, but it is written down here because a signaling stack that can silently eat one
message can silently eat another.

## 17.8 The display was the network, four times over: paint-on-arrival replaces the `<video>`

Every latency number in §17.6–17.7 stops at the decoder. The lane's `age` is encode-output
to decode-delivery, and the governor drives it to ~65–90 ms through an 80 ms path — but the
user does not watch the decoder, the user watches the screen. §19.1's ladder warns that
"almost all of it is queueing that exists because nobody was holding a stopwatch." #14 put
a stopwatch on the last hop, and the ladder was optimistic.

**The probes.** Four new counters, all on the existing clocks: capture-read lag (sender:
`VideoFrame.timestamp` → our code), encode latency (`encode()` → chunk out), `fullAge`
(receiver: the sender's capture timestamp, carried untouched through chunk → packet →
decoder, → decode output), and present lag (decode output → actually presented, via
`requestVideoFrameCallback`). Two of them needed clock surgery first, because the run said
so (`cap1`): the camera's `VideoFrame.timestamp` is a small media-pipeline clock, not
`performance.now()`'s base — raw subtraction read 1.785e12 ms — and rVFC's timestamp
argument is on a third base. The sender now takes its media-clock offset as a running
minimum of raw capture lag (the least-queued frame is the truer base) and ships it on the
1 s age report; the receiver adds it to the ping-derived clock offset, and `fullAge`
becomes a true capture-to-decode-out number across two browsers. The first sanity check
passed before anything was fixed: `fullAge` p50 76–78 ms ≈ capture lag (0.2) + encode (6.2)
+ the old `age` (68) + decode time. The clocks agree.

**What the stopwatch found (`cap2`, RTT 80, canvas off).** Decode-output → presented:

| path | loss 0 | loss 1% |
|---|---:|---:|
| `MediaStreamTrackGenerator` → `<video>` | p50 **280–297 ms** | p50 **740–875 ms** |

The `<video>` element fed by a TrackGenerator is an *adaptive* jitter buffer, and there is
no knob on it — `jitterBufferTarget`/`playoutDelayHint` belong to the PeerConnection
receiver, which this is not, and touching the pc is law-1-forbidden anyway. Clean, it holds
~9 frames. Under 1% loss it reads our FEC-hold delivery pattern as jitter, grows to ~24
frames, and never shrinks. This one element cost 4–10× the entire network path; the true
glass-to-glass was ~356 ms clean and ~810–950 ms under loss, and no amount of transport
work would ever have shown it. The lane age we had been optimizing was 70 ms of a 360 ms
experience.

**The fix is subtraction (`cap3`, `?l2canvas=1`, now the default; `=0` is the control
arm).** Decode output → `ctx.drawImage(frame)` on a `<canvas>` in `#remoteWrap`, painted on
arrival. No TrackGenerator, no element, no buffer by construction: a frame that arrives
late is simply painted late, which is the design's spine applied to the display — time is
the shock absorber, and jitter shows up as jitter instead of being smoothed into standing
delay. The context is created `desynchronized: true` to skip compositor buffering, and the
backing store tracks the stream size so the existing CSS `object-fit: cover` (it applies
to canvas) crops exactly as the `<video>` did. Present lag is now draw → next composite,
measured by rAF: **p50 0.3–0.4 ms, p95 ~15 ms (one vsync) — identical at loss 0 and loss
1%.** Throughput, admission, FEC repairs and keyframes are unchanged (the display swap
touches nothing upstream of the decoder), and the criterion run was re-passed on the new
default path.

| glass-to-glass, RTT 80 | loss 0 | loss 1% |
|---|---:|---:|
| before (`<video>`) | ~356 ms | ~810–950 ms |
| after (canvas) | **~75 ms** | **~75–92 ms** |

The remaining local slices are now small and honest: capture-read 0.2 ms (fake camera —
real sensor pipelines are 15–35 ms and only Phase 1 can measure them), encode p50 6.2 ms,
decode single-digit ms, present sub-millisecond plus up to one vsync. The capture-side
attack moves to real hardware; the display-side attack is done in the browser for good.

**The lesson generalizes.** A number that stops before the user's senses is a number about
the machine, not the experience. The transport was tuned to 70 ms while the last 30 cm of
the pipeline silently held 280–875. From here on the lane's health number is glass-to-glass
— `fullAge` + present — and the old `age` is demoted to what it always was: the network
slice, useful for governing the pacer, insufficient for claiming latency.

---

## 17.9 The hole parity cannot see: re-splice on request, but only after parity's window

The loss criterion was re-run at the design point after #14 (cam1080, 12 Mbps, RTT 80, 1%
loss) and the answer had moved: not zero lost frames, but **11 and 14** in two runs, always
in one direction per run, always concentrated in 2–3 gap events. The FEC counters said why:
`fecUnrepairable 0`, every arrived parity used, and `fecHoldExpired` 2–3. A parity group
repairs exactly one missing member — but nothing repairs the group whose **parity packet
died with its data**. The receiver never learns that parity exists, so there is nothing to
count: the gap just sits in the hold until the 250 ms deadline, then 11–14 frames fall to
the pre-FEC path (count, drop, keyframe). Expected rate at 1% independent loss: about one
doubly-struck group per direction per 100 s run. Exactly what was measured.

The fix is a second line of defense: the sender retains the last 90 encoded frames in the
worker, and the receiver, on a gap that parity has failed to close, asks for the missing
ids over the ctl channel (`fragreq`); the worker re-splices them on the next carrier ticks
with their original ids and wire format, outside the parity XOR. One RTT later the hole is
filled — well inside the hold window, so the cascade never starts.

**The first version of this was a measured disaster, and the failure is the lesson.** The
natural implementation requests a re-splice the moment any gap appears. At 1% loss that is
every single-loss gap — 227–318 requests per run — and every re-splice **steals a carrier
tick from a new data frame**, because re-splices were given priority over data. 2900 data +
700 parity + 270 re-splices against ~3150 carrier ticks: oversubscribed. The worker's FIFO
overflowed and dropped already-encoded frames — holes the reference chain can only repair
with keyframes — which created more gaps, which created more requests. Admission collapsed
to 43–74%, losses rose to 33–63 frames: the cure ate the budget it was trying to protect
(retx1, retx-s1).

The corrected design is two-phase (`?l2retxwait=`, default 120 ms): parity gets the first
120 ms of the hold window to heal the gap unaided — which it does for all but 1–3 groups
per run — and only the survivors draw a re-splice. The numbers after the fix (retx-s2,
retx-s3): fragreq 5–35 per run, lost frames **2 + 0** and **0 + 60** against the pre-retx
11 + 14, hold-expiry 0 in three of four directions, zero keyframe requests in the clean run.
The 60 in retx-s3 came with a mid-run congestion episode (age p95 815 ms): the ctl channel
that carries fragreq is SCTP — reliable but delayed under loss — so of 83 requests only 15
had crossed by the time the holds expired. Under backlog the 250 ms window is shorter than
the request's own delivery time; the AIMD governor's throttle is what actually ended that
episode. Redundancy heals loss; only pacing heals congestion — the two must not be asked to
do each other's job.

Residual: 2 frames in the clean run, lost when a natural keyframe landed past a hole and
jumped it (by design — keys restart the chain) moments before the re-splice arrived. 0.07%
of frames, self-healing, at the boundary of the design's own invariant. Left alone.

Two carrier-tick rules fall out of this, now written into HANDOFF's laws: **never spend a
carrier tick on a gap parity can heal** — parity's window comes first — and **ctl is not a
real-time channel**: it is SCTP over the same lossy path, fine at 1 Hz reports, too slow to
win a 250 ms race during congestion.

---

## 17.10 Real camera on the lane: the 10 Mbps truth, and the tax this probe cannot see

Every number before this section came from a fake camera: a file, fed through Chrome's
synthetic device, whose pipeline depth is zero by construction. 2026-08-01 the lane ran
on real hardware for the first time (`call.mjs --realcam[=a|b]`: drops the fake-device
flags, keeps fake-ui to auto-accept the prompt; macOS TCC must already trust the binary).
The device was a Logitech C270 — 1280×720@30, `resizeMode: none` honoured, confirmed by
the `__gum` record, not assumed.

Three measured facts:

1. **The real bitrate of the design point.** A real 720p webcam scene at QP24 is
   **10.1 Mbps at-fps** (mean frame 42.2 KB, FEC 24.5% on top) — against 0.43 Mbps for
   the test fixture. This is the first honest bandwidth number the lane has produced,
   and it lands exactly where §6/§18 predicted tier traffic would: the cost model's knee
   is not theoretical.
2. **The lane holds it without breaking a sweat.** One-sided arm (realcam-a1): 95%
   admission, 0 lost frames, age p50 21 ms / p95 40 ms, fullAge p50 29 ms at ~1.4 ms
   RTT — the governor runs the same equilibrium at 23× the fixture bitrate. Two-sided
   realcam on one machine (realcam1) contended CPU as expected (B admission 65%, age
   p95 124–690 ms, still 0 lost): one machine is not two, and the governor's throttle
   is exactly what that sentence means in practice.
3. **`cap→read` cannot see the sensor tax — architecturally.** It read 0.1 ms on the
   real camera, same as the fake. Law 14's clock-base fix ships a *running-min* of raw
   capture lag as the sender's offset; a constant sensor/ISP/driver depth (§19.1's
   15–35 ms) lives inside that minimum and is subtracted away. The probe measures
   capture *jitter* (steady: p95 0.3 ms), never absolute depth. The absolute number
   needs a physical loopback — a device filming a millisecond timer — which one Mac
   whose camera faces its user cannot do alone. Phase 1, two devices.

The glass-to-glass figures quoted throughout §17 are therefore read→present plus
network; the true number adds a constant capture depth per camera, bounded by the
§19.1 ladder, to be measured — not assumed — in Phase 1.

## 17.11 Lane A: lossless PCM audio exists, and the first thing it healed was its own counters

2026-08-01. The audio half of the lane programme (§9's Lane A) now runs behind
`?pcmaudio=1`: 48 kHz/24-bit linear PCM, no codec, 8 ms frames (384 samples,
1152 B), one datagram per frame on its own unreliable-unordered datachannel
(`pcm-audio`, maxRetransmits 0), 125 pps — 1.52 Mbps of audio, 1.98 on the wire
with FEC — against Opus's ~128 kbps. With the flag on, the mic track never touches the peer
connection (decided at page load, before `addTrack`); with it off, every byte of
today's path is unchanged, including the response headers (the worker gates
COOP/COEP — SharedArrayBuffer needs cross-origin isolation — on the flag, and
`run_worker_first` makes the worker see the page request at all: assets-first
serving would have bypassed it silently).

FEC is **RS(10,13) over GF(2⁸)** — a Cauchy-matrix systematic code, ~140 lines
(`core/pcmrs.js`), erasure decode by ≤3×3 GF Gaussian elimination — not the
XOR-parity fallback. Same 30% overhead as lane 2's XOR, but it recovers *any*
three erased symbols per group where XOR recovers one, and the fixed 1152 B
symbol size keeps it simple. Proven before wiring: 300 random groups with sender
drops + network erasures + parity loss, 367 erased symbols recovered byte-exact;
over-erasure fails clean. Parity is paced one packet per capture tick after group
close — never clumped — and the parity header carries a member bitmap so a frame
dropped to sender backpressure is a gap for the concealer, never "repaired" into
zeros.

**What broke: the failure counter failed before the FEC did.** First clean
loopback run (pcm1): 2 lost frames, `fecFailed 5992`. Impossible arithmetic —
375 groups can fail at most 3750 frames — and the cause was structural, not
numerical. When a group resolved complete, it was *deleted*; the paced parity
tail (two packets still in flight, one per tick) then re-created a bitmap-only
phantom that expired as 10 phantom failures. With an unordered channel a
micro-reordered data frame did the same. Fixed by marking groups resolved and
keeping them — whereupon a *second*, tighter race showed through (pcm1b): with
a 2-frame jitter target the playhead passes a group one tick after close, around
the same tick the parity tail lands; expiry deleted the group and each trailing
parity packet resurrected it for another phantom 10. The measured signature was
~10.8 phantom failures per group, every group, on a lossless run. Final fix:
expired groups become husks — counted exactly once, kept as tombstones — and are
evicted only on a writer-head horizon past the last parcel (base + 13 + slack).
After that (pcm1c, pcm-reg): `fecFailed 0`, and `parityUnused` reads exactly
2×groups — the predicted signature of a healthy lossless run. A receiver-logic
simulation (in-order + the expiry race, 1% and 5% network loss) confirms:
61/61 and 272/273 single-group erasures repaired, zero phantom failures.

The lesson generalises and is now written into the lane: **parity is a stream,
not an event** — group state must outlive every parcel that can still arrive,
or every counter downstream of it lies.

**The second thing that broke was the backpressure gate, and it broke only off
loopback.** First loss-arm run (pcm-loss, RTT 80/1%): 46% of capture dropped at
the *sender*, 54% of runtime concealed, drift and target both railed. The wire
was clean — the delay line dropped its 1% on purpose and 0 for bandwidth. Part
of the cause was real: `bufferedAmount` counts *in-flight unacked* bytes, and
at 80 ms RTT a healthy 1.5 Mbps stream holds ~15 KB in flight permanently; the
fixed 6144 B gate (calibrated on loopback, where in-flight is ~2 KB) tripped on
every tick. Parity was ungated and kept flowing; half the RS groups were gutted
before the network ever saw them. The gate now budgets the path's own in-flight
window — baseline RTT (running minimum, lane-1's baseRtt convention) × the
lane's *design* rate (125 pps × 1168 B × 1.3 for FEC; the measured-rate version
self-locks into the throttled equilibrium it measures) × 1.5, plus two frames
of true queue — and drops only what exceeds it. But no gate value made the loss
arm pass, and that was the tell that the gate was not the binding constraint;
the next paragraph is about what was.

Playout is an AudioWorklet on the shared 48 kHz context (latencyHint 0 under
the flag): SAB ring (64 frames, per-slot seq tags — never a bitmap), fractional
playhead, linear interpolation, drift compensation by continuous resample
bounded ±0.2% (§10). The remote onset detector runs *inside* the playout
worklet, post-concealment, on the shared context's clock — what the detector
hears is what the ear hears, and local/remote events keep one time origin.
Concealment follows the law: normalised-autocorrelation waveform extrapolation,
max 3 frames (24 ms), then HOLD silence; never stretched, never ducked. The
jitter target starts at 2 frames (16 ms), bumps +1 per late/concealed frame
(≤15f = 120 ms, §12's D_max), decays 1f per 10 s quiet (0.8 ms/s — inside §12's
2 ms/s shrink bound).

Measured, clean loopback, full fixture (pcm-reg2, 105 s, 13 136 frames per
direction): 1.52 Mbps, **drop(link) 0, lost 0, late 0, dup 0, farFuture 0,
concealed 0 ms, `fecFailed 0`**, `parityUnused` exactly 2×groups, drift settled
+670/+5 ppm inside the ±2000 bound, depth 16–18.7 ms at target 2f — every
sample of the fixture crossed both directions untouched. Onset timing error
median 0 ms on all four detector paths. Far-end inhale survival 100% (4/4 +
7/7), matching the control. Turns: 7/7 on B-hears-A and both own-mics, **6/7 on
A-hears-B** — the miss is not the lane's (the samples arrived bit-exact); the
remote detector's 35 ms classify window landed 400 ms earlier on this path and
read periodicity 0.37 against the 0.42 voice bar → labelled 'transient',
discarded. The same turn reads 'breath' on its own mic and through the Opus
path. Classifier, not carrier — and the classifier is a sibling workstream's
live file. Mouth-to-ear (score.mjs cross-check): control arm 115 ms RTT (57 ms
each way, estimates agree to 5 ms); **PCM arm 46 ms RTT — 22 ms each way** —
the two one-way estimates are 24.3 and 66.8 ms (disagree 43, over the 30 ms
bar, on n=9/7 and 6/3 usable transitions; the asymmetry rides on B's
detector-measured "human" gap of 881 ms against Boland's 297, i.e. turn-end
timing, not on anything the lane did asymmetric — depths 18.7/16 ms, RTT 1 ms).
The defensible number is the round trip: 115 → 46 ms, −69 ms, exactly the
NetEq-plus-codec budget the lane was built to delete.

**The third thing that broke was the design point itself: at RTT 80 / 1% loss,
the path will not carry this traffic shape at any offered rate the lane can
use.** The isolation ladder, all on the same testbed path (delay line, relay,
80 ms, all "0 dropped to the bandwidth ceiling"):

| arm | offered/dir | carried/dir | result |
|---|---:|---:|---|
| pcm-rtt80 (80 ms, 0%) | 2.5 Mbps (PCM+FEC+video) | 2.5 | clean: drop 0, concealed 40/32 ms, `fecFailed 0` |
| pcm-loss3 (80/1, full mix) | 2.5 | ~1.8 | gate dropped 38–49% of capture, 54% concealed |
| pcm-loss4 (80/1, gate opened to 1 MB) | 2.5 | ~2.1 | association queued instead: ping RTT 11.8–12.6 **s**, age p50 5.8–7.2 s, 98% concealed |
| pcm-loss5 (80/1, PCM+FEC alone) | 1.98 | ~1.2 | still collapses: 62% sent, 35–37 s concealed |
| pcm-loss6 (80/0.2, PCM+FEC alone) | 1.98 | ~1.65 | gate shed 9–13%, concealed 8–13 s, RTT clean |
| pcm-loss7 (80/0.05, PCM+FEC alone) | 1.98 | ~1.85 | still sheds 3%: the first 0.05% costs a quarter of the wall |
| retx-s2 (§17.9, 80/1, video alone) | ~14.5 | ~14.5 | sails: age p50 60 ms, 0 lost frames to parity |

So the wall is not the mix and not the gate — PCM's own 1.52 Mbps data rate is
already above it. And it is not the path: the same path at the same RTT and the
same injected 1% carried fourteen times as much when the bytes rode as ~37 KB
video messages. The wall is *shape*-dependent: ~125–165 pps of 1.2 KB messages
stalls where ~1 300 pps of MTU-sized chunks flew. The mechanism lives inside
the SCTP stack (Nagle and delayed-SACK both exempt full-sized messages and tax
small ones; congestion state is the other suspect) — we have not opened it, and
the honest entry is the measurement, not a theory. The wall's loss response is
steep and then flat: the first 0.05% costs a quarter of it (≥2.5 → ~1.85), and
the next twenty-fold increase costs only another third (0.2% → ~1.65, 1% →
~1.2). Per *loss event*, not per percent — at this packet rate 0.05% is one
event per 12 s — the curve reads like a fixed recovery tax per event, which is
congestion-state behaviour, not Nagle's. Where the lane *does* pass a loss
criterion — RTT 20 / 1%, full mix (pcm-loss8): 99.8% sent, drop(link) 16/5,
**RS(10,13) repaired 115 + 108 groups'-worth of frames**, `fecFailed` 0/8,
concealed 480/696 ms of 60 s (1%), age p50 12–13 ms. The FEC earns its 30%
exactly where §9 said it would; what it cannot do is buy back a path the
transport has already taken.

The law has no lawful move at this wall — quality is a constant, and a constant
1.98 Mbps does not fit through a 1.2 Mbps hole. What the lane does there is the
honest failure mode, and it is worth naming: drop at the sender's gate (never
queue seconds — pcm-loss4 shows what queueing buys), conceal at the receiver by
the concealment law (≤24 ms extrapolation, then HOLD), count both, and say so.
§6's floor for the audio tier is a 2.5 Mbps uplink; this stack at 80/1 measures
below it for this shape. The 80/1 criterion stands for the video lane, which
the shape-dependence favours; Lane A's loss criterion has to be set where its
own shape passes — measured above.

**What is residual.**

1. *The startup stall.* At ~t=3 s of a run, both browsers' main threads stall
   ~50–100 ms (encoder/graph spin-up; on this one-machine testbed, contention
   compounds — §17.10's "one machine is not two"). Capture frames queue in the
   worklet→main port, burst onto the wire, and arrive behind the playhead:
   ~10 frames concealed (extrapolated ≤24 ms, then HOLD — the law held) and the
   target bumps to ~9f, which then costs the rest of the run at the 1f/10 s
   decay. pcm-reg (the first full-fixture arm) ate exactly this; pcm-reg2, on a
   quiet machine, did not stall at all — target 2f all run, concealed 0 ms.
   Time is the only shock absorber — but the absorber releases slowly by design.
2. *The turn-#4 'transient' label above.* The carrier is exonerated (bit-exact
   delivery), but the *score* cares: one fixture turn in one direction falls
   under the classifier's periodicity bar on this path. Whether the fix belongs
   in the classify window's placement or the transient rule is the detector
   workstream's call; the lane's contract — deliver exactly what the mic said —
   is met.
3. Port-message fallback ring (non-isolated contexts) is untested — COOP/COEP
   gating was verified at the header level and every test ran in `sab` mode.
4. Flag asymmetry is unsupported: both sides must pass `pcmaudio=1` (the
   harness does). A flag-on caller with a flag-off answerer would send PCM into
   a peer with no playout — the channel negotiates, the audio doesn't flow.
5. The 80/1 transport wall is measured, not explained. If the SCTP stack's
   small-message loss tax is ever opened and fixed, Lane A's loss criterion
   should move back to the design point; until then its envelope is the table
   above.

## 17.12 The 80/1 wall opened: it is SCTP's congestion control, not its message shape — and the lever is a second association

2026-08-01. §17.11 left the RTT 80 / 1% wall measured but unexplained, with two
suspects: Nagle + delayed-SACK (both tax small messages) and congestion state
(cwnd halving per loss event, recovery sample-starved at 125 pps). We built a
standalone probe to open it — `tape-app/public/sctp-probe.js`, a one-page
loopback pc pair (two ends, one clock, so message age needs no offset
estimation) driven by `testbed/sctpwall.mjs`, which applies the *same*
candidate-rewrite delay/loss line `call.mjs --p2psim` uses, verbatim. Traffic
is synthetic and shape-configurable: message size × rate × pacing × offered
load × association count, all unreliable/unordered (`maxRetransmits 0` — the
law's datagrams), with a ping channel on the same association to read the
SCTP-level queue and per-second carried series to see the collapse happen.
The probe reproduces the wall on its first loss arm: 1168 B × 200 pps at 80/1
carries 1.35 of 1.87 Mbps offered with age p50 3.2 s — pcm-loss5's signature
without the app.

**The first suspect died fast: there is no Nagle cliff.** Holding offered load
at ~1.9 Mbps and moving only the message shape, every shape collapses to the
same ~1 Mbps:

| size × pps (≈1.9 Mbps offered) | carried | lost | age p50 |
|---|---:|---:|---:|
| 600 B × 390 pps | 1.48 | 21.0% | 3.4 s |
| 1168 B × 200 pps | 1.35 | 27.6% | 3.2 s |
| 1300 B × 180 pps | 1.21 | 35.7% | 1.3 s |
| 4672 B × 50 pps | 1.07 | 42.7% | 4.5 s |
| 16 384 B × 15 pps | 1.32 | 32.8% | 2.5 s |
| 37 888 B × 7 pps | 0.94 | 56.0% | 1.0 s |

If Nagle or delayed-SACK were the tax, the cliff would sit at ~1 MTU and the
37 KB messages — thirty-one full-sized fragments each, §17.11's flying shape —
would sail. They do the opposite (worst row in the table; coarser cwnd samples
per byte). Pacing is equally innocent: the same 1168 B × 200 pps burst-clumped
4- and 10-deep carries 1.07 and 1.45 against 1.35 even — run-to-run weather,
not a mechanism.

**The second suspect survived, and it is per-byte, not per-shape.** Holding the
message at 1168 B and moving the rate at 80/1: 100 pps (0.93 Mbps offered)
passes — 97% carried, age p50 219 ms; 200 pps carries 1.35; 400 pps (3.7
offered) carries 1.08 with 4 MB queued in `bufferedAmount`; 800 pps (7.5
offered) carries 0.19 with 10.7 MB queued. Over-offering does not climb the
wall, it queues against it — pcm-loss4's 12 s ping RTT, reproduced in
miniature. The ceiling is a property of the association, independent of
message size, message rate, pacing, and offered load.

And with that, §17.11's shape-dependence dissolves into something simpler:
**the 14.5 Mbps video arm was never SCTP.** retx-s2's bytes rode the VP8 media
carrier — tape frames spliced into RTP, governed by GCC, the delay-gradient
controller that is loss-tolerant by design. The PCM bytes rode SCTP, governed
by RFC 4960 AIMD. Same NIC, same proxies, same 80 ms and same 1% — two
different congestion controllers. The wall was never "1.2 KB messages stall
where 37 KB messages fly"; it is "SCTP stalls where GCC flies," and the probe,
which is SCTP-only, shows SCTP stalling in *every* shape.

**The model prices the wall.** On each loss event the association halves cwnd
and regrows at most ~1 MTU per RTT, so the congestion-limited ceiling is the
Reno form, ≈ 1.22 × MTU / (RTT × √p). With a ~1250 B wire packet at 80 ms:

| loss | predicted ceiling | offered (wire) | measured |
|---:|---:|---:|---|
| 0.05% | 6.8 Mbps | ~1.8 | passes: 1.52/1.52 carried, age p50 43 ms |
| 0.2% | 3.4 | ~1.8 | passes: 1.51/1.52, lost 0.31%, age p50 45 ms |
| 1% | 1.5 | ~1.8 | wall: 1.22–1.37/1.52 carried, age p50 2.2–2.9 s |
| 1%, RTT 20 | 6.1 | ~1.8 | passes: 1.49/1.52, age p50 13 ms |

The steep-then-flat loss curve §17.11 measured is this model's signature:
below the ceiling the association is not congestion-limited at all and the
first tenths of a percent cost nothing; the moment offered crosses
1.22·MTU/(RTT·√p) the association flips into the halving regime and the
fixed-per-event recovery tax appears. The RTT-20 pass reproduces pcm-loss8 on
synthetic traffic — ceiling ∝ 1/RTT, so ×4 at 20 ms. The app's own ladder sat
~0.2–0.3 Mbps below the probe's at each loss level; the probe carries no
reliable ctl channel (its retransmissions add loss events) and no media
pipeline on its main thread, and the difference is that, not a different wall.

**The lever: a second association — §19's own fallback (a).** The ceiling is
per SCTP association because the cwnd is. Lane A's exact byte stream — 162.5
pps × 1168 B (125 data + 37.5 RS parity), 1.52 Mbps payload, ~1.8 on the wire —
round-robined frame-by-frame across N data-channel-only peer connections on
the same 80/1 path:

| associations | carried | lost | age p50 | age p95 | ping p50 | bufferedAmount p95 |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 1.22–1.37 | 9.9–19.8% | 2 235–2 902 ms | 3.5–4.3 s | 126 ms | 0.7 MB |
| 2 | 1.48 (97.3%) | 2.6–2.7% | **71–77 ms** | 322–377 ms | 87–91 ms | 104 KB |
| 3 | 1.49 (98.2%) | 1.8% | **43 ms** | 82 ms | 88 ms | 10.5 KB |

At 3.04 Mbps offered the scaling holds: one association carries 1.01, two
carry 2.49, three carry 2.96 (97.4%) — N associations, N ceilings, additive.
The proof bar is met twice over. Two associations: 97% of Lane A's wire
delivered, age p50 under 100 ms, ping at the path's own RTT (no SCTP queue),
no megabyte queue. Three: 98.2% delivered with age p50 43 ms — the clean-path
number; age p95 82 ms means essentially every frame lands inside the jitter
window, which the p95 322–377 ms of the two-association arm cannot promise.
The residual 1.8–2.7% loss is the injected 1% plus halving-transient losses —
precisely the erasure class RS(10,13) already repairs with margin (its
envelope is 3-of-10 per group). **The lever costs zero milliseconds**: frames
still leave at their capture tick, seq k riding association k mod N; there is
no bundling delay because there is no bundling. The channels stay
unreliable/unordered; nothing retransmits; quality is untouched. We measured
the honest alternatives too, and they are not levers: bundling the identical
byte stream N frames per message (N=2: 1.19 carried; N=3: 1.17; N=4: 1.44 —
all still under the wall with multi-second ages) buys nothing, because the
wall counts bytes, and it would have spent 8–24 ms of sender delay for it.

Two caveats, stated plainly. The testbed path has no bandwidth ceiling and no
cross-traffic, so the second association's extra cwnd is taken from no one; on
a congested real access link two AIMD flows claim two loss-tax budgets, which
is ordinary multi-flow behaviour and the right trade on the P2P paths this
design expects (§18), but it deserves one relayed-path measurement before we
call it free. And the ceiling's *flatness* across shapes means the wall's
1.2–1.5 Mbps figure is this stack's per-association constant at 80/1 — every
future datachannel lane inherits it, including ctl's retransmission storms
under loss (§17.9 law 16 already suspects as much).

What a native client could do instead, for the record: it would not need
striping. usrsctp (and any SCTP) can run a loss-tolerant congestion control on
unreliable streams — HTCP is in the tree, and a BBR-style paced controller or
"no cwnd response to abandoned PR-SCTP chunks" is a patch, not a protocol —
or the PCM can ride the media plane it already has: L24 is 48 kHz/24-bit PCM
as a standard RTP payload, and GCC on this exact path demonstrably carries
14.5 Mbps at 80/1. In the browser neither knob exists; the association count
does. Lane A's 80/1 criterion can move back to the design point behind
`pairs=3` — pending the relayed-path check and an app-side stripe (two extra
data-channel-only pcs beside the main one; signalling already knows how to
build them).

---

## 17.13 Lane A v2: the stripe ships — `?pcmpairs=` puts §17.12's lever in the app

2026-08-01. §17.12 proved the lever on a standalone probe — Lane A's exact byte
stream striped round-robin across N data-channel-only peer connections carried
98.2% at RTT 80 / 1% loss on 3 associations with age p50 43 ms and zero added
latency, where 1 association collapses. This section is the app-side landing of
that lever, behind `?pcmpairs=N` (default 1, which is byte-for-byte the
previous behaviour: one `pcm-audio` channel on the main pc, no extra peer
connections created).

**The mechanism is exactly the probe's, no more.** Frames leave at their
capture tick: seq k rides association k mod N. There is no bundling — bundling
was measured in §17.12 and rejected (buys nothing, costs 8–24 ms). Association
0 is the main pc's `pcm-audio` channel, unchanged; associations 1..N−1 ride
N−1 extra data-channel-only peer connections, each created synchronously at
join with its `pcm-audio-i` channel (`{ordered:false, maxRetransmits:0}` —
media never on a reliable channel) before any offer that pc makes, so the
no-renegotiation law holds for them exactly as for the main pc. Signalling is
a namespaced parallel of the main pc's — `pcm-offer` / `pcm-answer` /
`pcm-ice` carrying the stripe index over the same WebSocket — one offer/answer
round per stripe at join, never renegotiated, sharing the /api/ice config.
Both sides must pass the same N; flag asymmetry is unsupported, same as
`?pcmaudio=` itself.

**The receiver needed no changes of principle, and that is the point.** The
SAB ring is seq-tagged per slot, RS groups key off seq, the playhead does not
care which association delivered a frame — out-of-order arrival across
associations was already the tolerated case (the channel was always
unordered). What striping changes is accounting, and §17.12's caveat is the
law here: ping, baseRtt, bufferedAmount and backpressure are *per-association*.
Each stripe runs its own ping/pong and keeps its own running-minimum RTT; the
gate budget is computed per association against its own floor. A frame whose
home association is over budget tries the NEXT association in the round-robin
before being spent as a gap — the stripe exists to absorb exactly this — and
only when all N are over budget is the frame dropped, counted on its home
association. The per-association gate is the FULL design-rate budget, not
1/N of it: an association absorbing spilled frames from a congested sibling
needs headroom for exactly that, and a gate shrunk by 1/N would re-create the
wall the stripe exists to remove. RS parity stripes too — group g's parity
rides association (g mod N), ungated exactly as before (a gate drop there
would gut the group it repairs), falling to the next association only while
its own is not yet open. Home by group ORDINAL, not by base: group bases
stride by RS_K (10), so base mod N is 0 for every group whenever N divides 10
— measured at pairs=2, where 100% of parity piled onto association 0 and
tipped it into the wall while association 1 idled (the postmortem below).
(base/RS_K) mod N stripes evenly for every N, and at N=1 and N=3 it is the
identical mapping, so the gates above the postmortem stand as measured. The
member-bitmap semantics are unchanged; a sender-side drop is still a gap,
never "repaired" into zeros. The sender's RS accumulator, the capture worklet,
the playout worklet and the detector tap are untouched; video lanes are
untouched.

**The gates, measured** (full fixture, both directions, `--q='tape=2&pcmaudio=1&pcmpairs=N'`):

*Gate 1 — pairs=1 control must be today's behaviour, loopback.* Runs
`stripe1-ctrl` / `stripe1-ctrl2` (full fixture, tape=2 alongside): 1.52 Mbps,
drop(link) 0 both directions both runs, fecFailed 0, parityUnused exactly
2×groups (2626/2627 over 1313 groups), age p50 0.2–1.2 ms, mode sab, target 2f,
7/7 turns on all four detector paths via score.mjs in both runs, onset timing
error median 0 ms, mouth-to-ear RTT 24–25 ms. The only blemish anywhere: 2–3
frames concealed on one side per run, each traced to the documented one-machine
weather — a both-browsers main-thread stall at t≈4.7/16.5 s (§17.11 residual
#1's startup signature; pcm-reg ate the same before striping existed, pcm-reg2
on a quiet machine did not) and teardown frames at t≈102 s. A's side of the
rerun is the clean-room number: lost 0, concealed 0 ms. The 25-frame
capture-vs-send gap at startup is the pre-channel-open silent skip, unchanged
from before.

*Gate 2 — pairs=3 loopback, full fixture.* Run `stripe3-loop2`: all three
associations open both directions; the split is even to the frame — A sent
4377/4379/4378, B 4377/4379/4377 (33.3% each; parity 1314/1314/1311, group
ordinal mod 3 as designed). drop(link) 0, fecFailed 0, parityUnused exactly
2×groups (2626), age p50 0.5–0.8 ms, depth 16–18.7 ms at target 2f, drift
+669/+3 ppm (inside the ±2000 bound), concealed 0 ms one side / 8 ms the other
(one startup-stall frame, §17.11 residual #1 weather). 7/7 turns on all four
detector paths, onset timing error median 0 ms everywhere, mouth-to-ear RTT
27 ms against the pairs=1 control's 24–25 ms — the stripe costs no latency on
a path that does not need it, as designed (frames leave at their capture tick;
there is nothing in the mechanism that can add delay, and the measurement says
it doesn't).

*Gate 3 — pairs=3 at RTT 80 / 1% loss, the money run.* Run `stripe3-80-1`
(`--p2psim --rtt=80 --loss=1`, full fixture):

| bar | measured (A / B) | verdict |
|---|---|---|
| ≥97% of capture sent | 99.5% / 99.7% (drop(link) 0 both) | ✓ |
| concealed ≤5% of runtime | 2 256 ms / 2 296 ms of ~105 s ≈ 2.1% | ✓ |
| age p50 <100 ms | 43.3 / 42.9 ms (p95 97 / 74) | ✓ — the probe's 43 ms, reproduced in the app |
| ping p50 ≤1.5× path RTT | per-association 85–109 ms against 80 (baseRtt 82–84) | ✓ |
| fecFailed ~0 | 429 / 318 | ✗ — accounted below |
| 7/7 turns both remote paths | 6/7 + 6/7 (own mics 7/7 both) | ✗ — misses are turns #2 and #3, inside the warm-up |

*The same-tree collapse baseline.* Run `stripe1-80-1` (pairs=1, same build,
same path) reproduces §17.11's wall exactly: 61%/64% of capture sent
(drop(link) 5 083/4 699), concealed 52.7 s/57.0 s of ~105 s (50–54%), fecFailed
3 069/3 195, ping 173/233 ms (queueing), drift railed at −2000 ppm. Against
that, the stripe's numbers above are the lever working: 1.6× more of capture
sent, 25× less concealment, 7–10× fewer FEC failures, age p50 halved, ping back
at the path's own RTT.

One counter needs its sentence: the striped runs show dup ≈ 394/396 where the
single-association runs show 0. Those are not network duplicates — they are
SCTP queue-delay healing through the FEC. On a striped association in a halving
transient a datagram is sometimes *delayed*, not dropped; the group resolves by
parity (the repair writes the ring slot), and the delayed original then arrives
to find the slot already tagged — counted dup, discarded, harmless. It is the
signature of the wall's transient queue meeting the repair machinery, and it
costs nothing.

The stripe itself is exactly the probe's behaviour: even split (A sent
4379/4376/4370), zero gate drops, FEC repaired 656+671 frames (the residual
~2.2% erasure class, repaired with margin), age p50 identical to §17.12's 43 ms
with zero added latency. What the two missed bars share is ONE cause, and it is
not the stripe: the first ~40 s are a playhead warm-up. At 80/1 the arrival
skew across associations during AIMD halving transients is ~50–300 ms; the
jitter target rails 2f→15f within the first 2 s of pain, but §10's drift law
bounds the playhead's depth growth to the ±0.2% resample rate (~2 ms/s), so
depth only reaches its ~120 ms steady state around t≈45 s. Every frame that
arrives behind the still-shallow playhead before then is concealed (≤24 ms
extrapolation, then HOLD — the law held) and counted at group expiry: that is
essentially the whole fecFailed count and both missed turns (fixture turns #2
and #3 land at t≈29–40 s). The steady state after warm-up is clean: t=45–105 s
carries ~64 ms concealed total (0.1%), fecFailed ~30, depth 115–123 ms, age p50
43 ms. The playout worklet is untouched by design (§10's inaudible-drift law is
what makes the convergence slow); the warm-up is that law meeting a path whose
D it had never needed before, not a striping defect.

*The warm-up, confirmed by its flag.* The priming law (hold playout until
`target` frames are buffered) means the initial target IS the initial depth, so
`?pcmjb=15` should start the playhead at the 120 ms this path converges to
anyway. Run `stripe3jb15-80-1` (pairs=3, pcmjb=15, same path): concealed
64/136 ms (0.06–0.13%, 17–35× less than gate 3), fecFailed 30/30 — the
steady-state floor, from t=0 — depth 123–125 ms from the first telemetry tick
(t=2.7 s), age p50 42.9/44.7 unchanged, drop(link) 0, even split
(4371/4374/4377), turns 7/7 own mics, 7/7 + 6/7 remote. The one residual miss
(B's remote turn #3) is NOT the lane: concealment in its window is zero
(B's concealed sits at 24 ms from t=23 s to t=73 s); the far-end detector
heard the breath (onset at the right tick, 5 dB SNR over a −62.5 dB floor)
and classified it a transient — a marginal-SNR classification call, the kind
the detector makes on any path, not a lane loss.
Mouth-to-ear: 343 ms RTT of which 130 ms each way is ours — the 15f depth,
paid from t=0 instead of from t=45. Whether the initial target should follow
expected path D (or adapt at join) is a product decision; the lever is a flag
today, and the measurement says the warm-up is the whole of gate 3's two
missed bars.

*Gate 4 — pairs=2 at 80/1, the middle of the dose-response.* Run
`stripe2b-80-1`: sent 96.7%/96.8% (drop(link) 368/379), concealed 15.4/15.6 s
(14.7%), age p50 56.2/50.9 ms (p95 177/155), fecFailed 3 189/3 033, even split
(6485/6269 data, 1959/1941 parity), turns 7/7 own, 5/7 + 6/7 remote. Two
associations at this path sit permanently near the sawtooth: each direction
shows one stripe at ping 135–240 ms (queueing transient) while the other holds
85–90, and the spill fallback is doing real work all run, not just in
transients. Exactly where §17.12's probe said 2 would land (~97%, warm tail),
and exactly between the collapse baseline (61–64% sent, half the runtime
concealed) and 3 (99.5–99.7%, 2.1%). The dose-response is monotone and
measurable: 1 collapses, 2 survives with a warm tail, 3 is clean.

**What did not work — twice, both measured before they shipped.** The first
wiring offered the stripes at the offerer's welcome without gating on a peer
being present. When 'a' joins an
empty room the main offer correctly waits for `peer-joined`; the ungated stripe
offers fired into the empty room, and the set-up-once guard (localDescription
already set) then skipped the real offer when the peer arrived — the stripes
never opened (measured, `stripe3-loop`: associations 1–2 CLOSED, zero bytes).
The run is also an accidental robustness control: with the stripes dead, every
frame fell through the next-association fallback onto association 0 and the run
stayed fully green (drop 0, lost 0+1, concealed 0+8 ms) — a `pcmpairs=3` page
whose stripes never connect degrades to exactly `pcmpairs=1` behaviour, no
stall, no error. Fixed by offering the stripes only where the main pc offers:
at welcome iff `peerPresent`, and at `peer-joined`.

The second was the parity home. As first written, group g's parity rode
association (g's base mod N) — and group bases stride by RS_K (10), so at
pairs=2 every base is even and 100% of parity landed on association 0
(measured, `stripe2-80-1`: parity 3 909/0, association 0 at rtt 247 ms with
29 KB buffered while association 1 idled at 118 ms; concealed 17.9/15.6 s,
fecFailed 4 573/4 531). The data spill fallback worked as designed — it
re-balanced the DATA (5 273/7 464) — but parity is ungated by law, so the lump
stayed. Fixed by homing on the group ORDINAL: (base/RS_K) mod N stripes evenly
for every N, and is the identical mapping at N=1 and N=3 (bases stride
10 ≡ 1 mod 3), so gates 1–3 stand as measured; only N dividing 10 changes,
and that is exactly the case that was broken. The rerun is gate 4's table
above: parity 1 959/1 941, buffers drained, fecFailed 3 189/3 033 — still the
pairs=2 middle, but an honest one.

**Residual.** Flag asymmetry unsupported (both sides must pass the same N).
Per-association ping also carries per-association CLOCK OFFSET, and the offset
estimate is only as good as the association's own queue: on a congested stripe
the pong's return leg is delayed, the offset biases, and age measured against
it inherits the bias (gate 4's pre-fix run showed offsets of −83/+82 ms on the
two directions' congested stripes; treat tail age on a queueing stripe as
approximate — baseRtt and the even split are the trustworthy counters there).
The testbed path has no bandwidth ceiling and no cross-traffic, so the extra
associations' cwnd is taken from no one — §17.12's relayed-path caveat stands
and still deserves its one measurement before we call the lever free on
congested real access links. Every datachannel lane still inherits the
per-association wall, ctl's retransmission storms included; striping is now
the measured answer when one of them hits it.

**Follow-up, same night — the relayed-path check §17.12 owed (resolves the residual above).**

**2026-08-01 — the measurement §17.12/§17.13 owed.** Every stripe test so far ran on the
local simulator with no bandwidth ceiling and no cross-traffic — the extra associations'
cwnd was taken from no one. This note runs the same two arms against PROD
(`https://room.tokkah.com`) with ALL media forced through Cloudflare TURN, where the
associations genuinely share a relay server path.

## Method

New driver: `testbed/relay-call.mjs` (two-browser pattern from `testbed/call.mjs`).
Page URL: `https://room.tokkah.com/?r=<room>&tape=2&pcmaudio=1&pcmpairs=N` — the full
~105 s conv fixture (cam1080.mjpeg fake camera, conv/A.wav + conv/B.wav fake mics), so
Lane A (~1.8 Mbps SCTP) and the fixed-QP video lane (~12 Mbps offered on the VP8
carrier under GCC) ride the relayed path together, as in the §17.13 gates. No netsim,
no `--p2psim`.

Relaying is forced by injection only (no app file touched): an init script wraps
`RTCPeerConnection` so every constructed pc — the main one AND the stripe pcs app.js
builds internally — gets `iceTransportPolicy:'relay'` merged into its config, and is
recorded in `window.__allPcs`. Every 5 s each pc's selected candidate pair is read out
of `getStats()` (local/remote candidate type + address, pair RTT, pair bytes).

**Relay proof — all four runs, every pc:** local candidate type `relay` on every pc
(main + stripes, both browsers), remote type `relay` too. No run was void. Observed
TURN servers (our own relay, fine to log): eight distinct Cloudflare addresses across
the runs — 104.30.136.{49,45,44}, 104.30.146.{231,254}, 104.30.148.{96,94},
104.30.147.1, all UDP. One detail that turns out to matter: **within a single pairs=3
run, each pc's allocation landed on a DIFFERENT TURN server** (e.g. p3-rerun A side:
main 104.30.146.254, stripe1 104.30.147.1, stripe2 104.30.146.231). The stripes do not
share one relay path; they ride different servers within the POP.

Path character (no injection, just the real world): selected-pair RTT mostly 8–25 ms
to the anycast POP, with transient multi-hundred-ms episodes (spikes to 371–746 ms in
every run; one simultaneous both-browsers main-pc ICE `failed`→recovered at t≈45 s of
p3 run 1). Machine load average 2–4 during the runs — another agent shares this box.

## Runs table (both directions; "sent%" = framesSent/captureFrames)

| run | dir | sent% | drop(link) | lost | concealed ms | fecFailed | late | age p50/p95 ms | per-assoc rtt/baseRtt ms |
|---|---|---:|---:|---:|---:|---:|---:|---|---|
| p1 #1 | A→B | 97.0 | 397 | 517 | 4136 | 122 | 103 | 8.5 / 18.8 | 19.6 / 9.5 |
| p1 #1 | B→A | 97.0 | 395 | 526 | 4208 | 178 | 111 | 7.2 / 20.0 | 20.4 / 10.1 |
| p1 #2 | A→B | 94.3 | 703 | 939 | 7512 | 78 | 165 | 7.3 / 26.2 | 16.2 / 9.2 |
| p1 #2 | B→A | 94.2 | 729 | 909 | 7272 | 99 | 170 | 5.6 / 25.1 | 15.5 / 7.9 |
| p3 #1 † | A→B | 96.8 | 377 | 934 | 7472 | 2042 | 451 | 7.7 / 27.2 | 64/31/31 over 9.5/8.6/10.3 |
| p3 #1 † | B→A | 96.3 | 449 | 946 | 7568 | 1804 | 545 | 7.9 / 20.8 | 60/52/52 over 10.4/7.5/9.1 |
| p3 #2 | A→B | 98.6 | 149 | 518 | 4144 | 550 | 308 | 14.5 / 76.3 | 22.6/19.9/22.8 over 11.3/9.3/11.2 |
| p3 #2 | B→A | 98.5 | 169 | 468 | 3744 | 532 | 307 | 7.1 / 74.9 | 18.6/22.3/20.4 over 13.7/8.9/10.2 |

† p3 #1 carried a weather storm (all three of A's pcs at 746 ms pair-RTT at t=10 s;
both browsers' main pcs ICE-failed at t≈45 s). Kept in the table as the bad-weather
sample, not discarded — p1 #2 had a same-class episode (concealed 7.5 s, drop 703–729).

**Even-split check at pairs=3:** p3 #2 even to the frame (A 4267/4392/4332 = 32.8/33.8/33.3%,
parity 1299/1302/1308; B 33.0/33.8/33.2%). p3 #1's storm shows the spill fallback working
as designed (27/40/33 — association 1 absorbed spilled frames while assoc 0 queued behind
the starving video carrier on the main pc).

**Achieved wire throughput per pc (selected-pair bytes, send side, avg over run):**

| run | main pc | stripe1 | stripe2 | total |
|---|---:|---:|---:|---:|
| p1 #1 | 6.55 / 6.00 Mbps (A/B) | — | — | 6.55 / 6.00 |
| p1 #2 | 4.48 / 4.57 | — | — | 4.48 / 4.57 |
| p3 #1 | 1.73 / 2.15 | 0.65 / 0.66 | 0.57 / 0.56 | 2.95 / 3.37 |
| p3 #2 | 3.37 / 3.98 | 0.58 / 0.58 | 0.58 / 0.58 | 4.53 / 5.14 |

**Video lane (the cross-traffic):** frames admitted 770/661 (p1 #1), 422/450 (p1 #2),
440/446 (p3 #1), 370/451 (p3 #2); age p50 380–441 / 519–735 / 592–611 / 829–921 ms
respectively. **No arm separation** — p1 #2 starved exactly as hard as both p3 runs.
The video spread is path weather (total wire Mbps varies 2× run-to-run within each arm),
not the stripe. The fourth run exists precisely to test this, and it killed the
"3-hurts-video" hypothesis the first three runs suggested.

## Reading

1. **The wall the stripe exists to break does not exist on this path.** SCTP's Reno
   ceiling ∝ 1/RTT: at the measured 8–25 ms pair RTTs the per-association ceiling is
   ~15–25 Mbps against 1.8 Mbps offered, even before loss is considered (and real loss
   here was ~0). The 61–64% collapse of §17.13's 80/1 gate is an RTT×loss product;
   a nearby-POP relay at ~15 ms has 5× the RTT headroom. One association carries the
   lane here — 94–97% sent depending on weather, the missing frames being gate
   backpressure during congestion EPISODES, not the Reno ceiling.

2. **What striping buys on relay is episode absorption.** drop(link): 149–449 across
   the p3 runs vs 395–729 across the p1 runs; the best-case sent% rises (98.6 vs 97.0)
   and, more importantly, the worst case improves. The per-association full-budget gate
   + next-association spill does exactly what §17.13 designed when a transient queues
   one association.

3. **What striping costs on relay is skew, and the mechanism is new information:**
   CF TURN hands each pc a different server, so the three associations' paths differ
   persistently (not just during AIMD transients as on the single-path testbed).
   Late frames ×2–4 (307–545 vs 103–170), fecFailed ×3–7 (532–2042 vs 78–178),
   age p95 ×3 (75 vs 19–26 ms). Groups straddle associations; a frame arriving
   behind the playhead expires its group. The p2psim gates never saw this because
   all associations there shared ONE path.

4. **What the ear hears is unchanged.** Concealed ms ranges overlap exactly:
   p1 {4136, 4208, 7272, 7512}, p3 {3744, 4144, 7472, 7568} — each arm has one
   good-weather run (~4 s, ~4%) and one bad-weather run (~7.5 s, ~7%). The playhead
   (depth railed 13–15f, 108–126 ms, in every run) absorbs the p3 skew about as well
   as it absorbs p1's bursty gate-drop clusters. Concealment character changes
   (p1: HOLD-dominated long gaps; p3: more short extrapolations), total does not.

5. **Video is indifferent to the arm** (see above) — relay-path weather moves it 2×
   run to run regardless of pairs.

## Verdict

**On a relayed path: 3-NEUTRAL.** No wall to break at ~15 ms RTT, so the lever's
premise is absent; the send-side gain (drop 395–729 → 149–449, better worst case)
trades against a real receive-side skew tax (late ×3, fecFailed ×3–7, age p95 ×3)
from stripes landing on different TURN servers; concealment — the number the ear
audits — is identical. Notably 3 does NOT hurt the video lane (the p1 rerun starved
as hard as both p3 runs), and it does not collapse anything either; the p3 #1 storm
run shows the spill fallback degrading gracefully through a genuine multi-second
all-association event.

**Implication for the app:** keep `pcmpairs` default 1 on relay-class paths and treat
the stripe as the 80/1-class medicine it was measured to be — enable it when the path
actually presents the Reno wall (high RTT × loss, i.e. long-haul P2P), not always.
A relayed path short enough to be worth using (CF TURN is anycast to a near POP by
design) has no wall; a relayed path with 80 ms RTT + 1% loss would be the one untested
corner, and these runs say the cross-server skew tax would apply there too — the
benefit on THAT path is unproven, not free. If the app ever wants auto-selection, the
honest inputs are the measured baseRtt and loss on association 0 (both already in
pcm.js's per-assoc counters), not the transport type alone.

## Caveats (honest)

- Same-machine browsers sharing one residential uplink; load average 2–4 (another
  agent's work). Weather episodes hit arms at random — mitigated by running each arm
  twice, which is exactly what exposed the p1 #1 run as the lucky one.
- One TURN POP (this machine's anycast landing), UDP relay only; tcp/turns fallback
  untested. Different POPs may allocate stripes on the same server (less skew) or
  further-apart servers (more).
- n=2 per arm, 105 s each. The concealed-ms equality and the drop(link) separation are
  consistent across all four runs; the fecFailed/late separation is mechanistically
  explained (per-server allocations observed directly). Effect sizes beyond that are
  weather-bound.
- p3 #1's numbers carry a genuine network storm; they are reported, not excluded.
- The turn-taking telemetry (usable 14–17/31–41, perceived ~0.8–1.2 s) reflects the
  108–126 ms playout depth + weather, not the arm; not a bar for this measurement.

Runs on disk: `testbed/runs/relay-p1-*`, `relay-p1-rerun-*`, `relay-p3-*`,
`relay-p3-rerun-*` (meta.json + A/B.json with the full 5 s poll series).
Driver: `testbed/relay-call.mjs`. Nothing deployed, nothing committed, no app file
touched.

**Independently verified and live.** The gate-3 money run was reproduced
end-to-end from scratch after review (run `stripe-verify`, same flags): sent
99.4/99.7%, drop(link) 0 both directions, concealed 2 128/2 328 ms of ~105 s
(~2%), age p50 46.0/43.6 ms, per-association ping 86.9–93.7 ms against the
path's 80, the split even to single frames (4369/4377/4376; parity
1311/1311/1311), and the same warm-up signature as the two accounted misses.
Deployed to room.tokkah.com as version 3fe1876b-d060-4acd-9881-cc221a9f9155,
together with the fullscreen-default view change (§1.1a's life-size stays one
chip away); the flag-off path was re-verified byte/header-identical in prod
before and after.

---

## 17.14 §10 lands: session epoch, TIME_SYNC, and video that follows the audio clock

2026-08-01. §10 asked for three things: a session epoch the room owns, a clock
sync protocol between peers, and a video presentation path slaved to the audio
sample clock. This section is the landing of all three, behind the PCM lane's
flag — with `?pcmaudio=1` absent, nothing here exists and the ctl wire and
render path are byte-for-byte what §17.8–§17.13 shipped. `?avsync=0` kills the
bundle with the PCM lane on (paint-on-arrival exactly as §17.8), and `?avoff=`
tunes the offset inside §3's [0, 45] ms window (default 20).

**Part 1 — the epoch is one line of authority.** The room Durable Object
stamps `session_epoch_us` at creation, persists it (a DO restart mid-call must
not rebase the session), and carries it in the welcome message as an additive
field — older clients ignore it, which is what "additive" means. Each peer
captures its local wall at welcome arrival and holds a coarse mapping
(`epochOffsetMs`), biased by the one-way WebSocket delay, reported as an
estimate and used for nothing load-bearing: it aligns cross-peer telemetry on
one timeline, no more. A's mapping read −5.2 ms, B's −229.5/−245.6 ms across
the runs; the difference is the ws arrival path, not clock error, and we say
so rather than fix it with protocol we don't need.

**Part 2 — TIME_SYNC rides the ctl channel that already exists.** No new
channels (the no-renegotiation law): `tsy`/`tsyr` messages multiplex onto
`tape-ctl-rtp`, 5 Hz, ~60 B per message — control-plane volume on a
control-plane channel. NTP-style four timestamps: rtt = (t4−t1)−(t3−t2),
offset = ((t2−t1)+(t3−t4))/2, offset taken from the **minimum-RTT sample in a
sliding 10 s window** — min-filtering, not averaging, because ctl shares the
media path and queueing delay is the common case (law 16). A slow least-squares
fit over the min-filtered stream gives the crystal-drift slope in ppm once the
window spans 30 s. pcm.js's per-association ping/pong stays exactly where it
was — that one ages Lane A's links, this one builds the session clock; merging
them would couple two things that fail differently.

Measured (both loopback runs, 105 s, 526 exchanges each direction, zero lost):
offset spread — the stability a consumer of this clock would see — 0.14–0.77 ms;
drift fit 0.1–0.3 ppm. One machine, two browsers: the crystals are the same
crystal, so ~0 ppm is the correct answer and the fit finds it. The 10–50 ppm
case the fit exists for needs two machines; the mechanism is least squares over
the same stream either way, and the loopback run proves the estimator, not the
physics.

**Part 3 — video follows the audio clock, and the mapping is the hard part.**
The requirement is a frame presented when its timestamp is nearest
`audio_playout_time + offset` at a vsync. Both quantities must live on one
timeline, and neither side of the pipe can see the other's clocks. The chain,
end to end, media clocks only:

- *Audio capture time* (`capUs`): the capture worklet stamps each completed
  8 ms frame with its own first sample's time on the AudioContext's hardware
  clock — `(currentTime + (i−FRAME)/sampleRate)·1e6`, never a delivery time.
  It rides the PCM frame header (offset 16, f64; the header grew 16→24 bytes
  under the flag only). FEC-repaired frames carry no header — parity covers
  payload — so the receiver extrapolates their capUs from the last exact
  anchor; capUs and seq are the same render-quantum stream, so one anchor
  extrapolates drift-free.
- *Audio playout time* (`apUs`): the playout worklet, which speaks capUs
  natively (its ring is capUs-stamped), publishes the sender-clock time of the
  sample under the playhead every render block — seqlocked pair in the SAB
  (port mode: a throttled port message, ~50 ms staler, noted). Because the
  anchor refreshes from the frame currently being drained, the ±0.2% resample
  that drives drift correction moves apUs exactly as it moves the audio —
  the sync target and the sound can never separate.
- *The sender's two capture clocks drift apart*, and only the sender can see
  both: `videoClock(now) = (now() − mco)·1000` (law 14's running-min capture
  base) and `audioClock(now) = ctx.currentTime·1e6`. Their delta `avd` rides
  the existing 1 Hz `age` ctl message — one added field, present only under
  the bundle, so the flag-off wire is unchanged — and the receiver EWMAs it
  (τ ≈ 3 s) and maps every decoded frame: `avUs = frame.timestamp − avd`.
  The 1 Hz refresh IS the two-clock drift tracking; at 50 ppm the error
  between refreshes is 50 µs, three orders under the budget.
- *Presentation*: decoded frames queue (cap 12 ≈ 400 ms — deeper means the
  lane is broken, not sync). At each rAF: target = apUs + outputLatency +
  offset; present the queued frame nearest target not newer than target +
  half a frame interval (never present early — the residual is bounded by
  the 30 fps cadence, ±16.7 ms, not by jitter); close everything older as
  superseded; hold if nothing qualifies. Engagement requires both mappings
  (peer's avd AND a started playhead) and is sticky — before it, and with
  `?avsync=0`, the path is §17.8's paint-on-arrival, line for line.

**The gates, measured** (full fixture, both directions, `tape=2&pcmaudio=1`):

*Gate 1 — loopback, Lane A must not know any of this happened.* Runs
`avsync-loop` / `avsync-loop2` (the rerun exists for the usual reason: run 1
ate the documented both-browsers startup stall, 24 ms concealed on B, and
missed A-remote turn #2; run 2 on a quiet machine: concealed 0 ms both sides).
Run 2: drop(link) 0, fecFailed 0, parityUnused exactly 2×groups (2626/1313),
age p50 0.5–0.8 ms, mode sab, depth 16–18.7 ms at target 2f, **7/7 turns on
all four detector paths** (7/7, 7/7, 7/7, 7/7), onset timing error median
0/−1 ms, mouth-to-ear RTT 11 ms. The video lane alongside: 98% admitted,
age p50 21–23 ms, decodeErr 0, lost 0 — §17.8's numbers, undisturbed.

*Gate 2 — the A-V telemetry, loopback.* Engaged both directions in both runs
(~2 s after the playhead starts: the avd and the first playhead publish).
presents ≈ 2050, holds ≈ 4200 (60 Hz rAF against a 30 fps supply — the ratio
is the cadence, not a stall), drops 0, skips 2–7 (superseded older frames,
normal when two frames land in one vsync), queue depth 0–1. The applied
offset — presented frame's audio-clock time minus the playhead at the ear —
p50 −22.7/−27.2 ms, p95 −9.2/−19.2 ms. Read the sign honestly: **negative is
audio leading**, 9–28 ms, inside §3's 45 ms permission. On loopback the two
pipelines are nearly evenly matched (video fullAge p50 ~30 ms against audio
delay ~25 ms at the ear), so no frame ever sits in the queue ahead of the
playhead, the offset term never binds, and the presenter degenerates —
correctly — to newest-frame-at-vsync. The regime where the offset and the
queue do their work is a path with real RTT, where audio depth grows and
video must be held back: gate 3.

*Gate 3 — RTT 80 / 1% loss, `pcmpairs=3`, the regime the queue exists for.*
Run `avsync-80-1`: the stripe is §17.13's, unregressed — 99.5%/99.7% of
capture sent (drop(link) 0 both), age p50 42.3/42.1 ms (p95 80.9/92.6), split
even to the frame (4366/4377/4382 and 4373/4375/4372, parity 1311–1314 per
association), per-association baseRtt 82–84 ms against the 80 ms line. The
documented warm-up class stands exactly as §17.13 measured it: concealed
3 160/2 712 ms (2.6–3.0%), fecFailed 527/503 (the still-shallow playhead's
price, HOLD law held — held 40/16 ms of it), dup 438/490 (the queue-delay
healing signature, harmless), B's drift railed at −2000 ppm mid-convergence
with depth 87 ms still growing toward the ~120 ms steady state. Turns for the
record, not a bar here: 7/7, 7/7, 7/7, 6/7 — the miss is B-remote #1, inside
the warm-up, the same cause §17.13 isolated. And the A-V sync, on the path
that finally separates the two pipelines (audio depth ~90–120 ms, video
fullAge p50 71–73 ms): engaged both directions, queue depth 1, drops 0,
skips 1–5, presents ≈ 2053 against holds ≈ 4206 (the 60 Hz cadence), and the
applied offset lands where the formula puts it — **p50 +27.8/+29.7 ms, p95
+34.4/+35.5 ms**, i.e. offset 20 ± half a 30 fps frame ([3.3, 36.7] predicted,
measured inside it, both directions, all run long). The queue holds video
back against the deepened audio, the offset binds, and the presentation is
the spec's sentence executed.

*Gate 4 — TIME_SYNC quality.* Loopback: spread 0.14–0.77 ms over 105 s, drift
0.1–0.3 ppm. At 80/1: minRtt 81.6/81.8 ms — the min-filter finds the path
floor through the queueing, which is its entire design argument — spread
1.15/1.64 ms (two orders under the path's jitter), drift −0.8/−3.6 ppm,
525/525 exchanges both directions. |slope| stays ≪ 100 ppm everywhere; on one
machine it must, and it does.

**What did not work, and the honest residuals.**

1. *The sign convention of "offset" deserves its sentence.* §10's formula
   (`nearest audio_playout_time + offset`, offset ∈ [0,45]) reads as video
   presented ahead of the playhead; §3's law is audio leads. Implemented
   literally, on a path where the video lane is the faster one the formula
   lands applied ≈ +offset — video leading, the direction BT.1359 tolerates
   furthest — and on a path where audio is faster the formula is inert and
   §3's natural lead obtains. Both regimes measured above are inside budget,
   but the knob's name and its direction disagree in one regime, and a
   reader should know that before tuning `?avoff=`.
2. *The epoch mapping is biased by the ws one-way delay* (−5 vs −230/−246 ms
   between the two peers, same room): fine for telemetry alignment, not a
   clock. If a cross-peer wall comparison ever needs better, TIME_SYNC's
   peer offset plus the DO's stamps are the path — not the welcome.
3. *Port-mode playhead publish is ~50 ms stale* (throttled port message vs
   the SAB's per-block seqlock). Both fixture browsers took mode sab; the
   port path is implemented and untested under load — if a browser ever
   falls back to it, the sync target lags by that much and the offset
   budget absorbs it (p95 headroom is 16+ ms), but that is reasoning, not
   measurement.
4. *The capture-vs-render clock assumption*: apUs and capUs are one
   AudioContext's clock on the sender, and the receiver's render clock is a
   different device's — the design assumes the SENDER's capture and the
   RECEIVER's render both track their local audio hardware, with the
   ±0.2% resample closing the difference, exactly as §10 specifies for the
   audio lane alone. The A-V numbers inherit that assumption; nothing in
   this fixture can violate it (one machine) and nothing here proves it on
   two.
5. *No perceptual lip-sync fixture exists*: the fake camera's frames and the
   wav's samples are independent streams with no planted correspondence, so
   there is no ground-truth A-V event to measure against. The gates above
   are telemetry gates — engagement, present/hold accounting, applied
   offset within §3's budget, queue bounded — and that is stated rather
   than smoothed over.
6. *The 503s*: several runs show the telemetry POST to `/api/room/…/log`
   answered 503 (8 console errors on A in run 2, none on B). The lane
   counters above come from the in-page snapshot, so no number here depends
   on that endpoint, but the log stream itself has a hole those seconds.

**Independently verified and live.** Both regimes reproduced end-to-end after
review (`avsync-verify-loop`, `avsync-verify-80`): loopback drop(link) 0,
fecFailed 0, parityUnused exactly 2×groups, A-V engaged with presents ~2050 /
drops 0 / offset p50 −30.0/−31.6 ms; at 80/1 with `pcmpairs=3`, 99.5/99.7%
sent, age p50 43.0/42.2 ms, split even, applied offset p50 +28.5/+27.3 ms
(p95 35.9/36.2) inside §3's budget, TIME_SYNC minRtt 81.7/82.2 ms (the path
floor, found through queueing), 525/525 exchanges, drift −2.0/−0.2 ppm. The
striping bars of §17.13 are unregressed on the same build. Deployed to
room.tokkah.com as version 42323653-8ef9-43e9-8868-3fd6f1d37e55; the flag-off
path re-verified header-identical in prod after the deploy.

---

## 17.15 Lane 0 lands: onset preemption and the turn-end pre-warm, on the wire they already had

2026-08-01. §3.1's levers 3 and 4 are the two Lane 0 mechanisms: lever 3
yields Lane B at a LOCAL voice/breath onset so the turn's first PCM frames
meet an empty pipe; lever 4 runs core/turnend.js on the sender's mic and
spends the ~290 ms prediction window on the receiver pre-warming the return
path and pre-stalling its own Lane B uplink. Both are metadata used to
schedule the network — never mixed into media, never shown to the user
(invariant 4). Everything rides channels that already exist; no
renegotiation; `?lane0=0` removes both features with the wire byte-identical
to 42323653-with-PCM-flag behaviour.

**Lever 3 — the yield is a gate, because preemption is not implementable.**
The browser cannot preempt SCTP mid-serialization (nor recall an RTP packet
already handed to the pacer), so the honest implementation is gating
tape.js's sends at onset time. The local detector's `onset` event (already
one-per-activation — that is the "max one yield per onset" bound) calls
`tape.yieldLaneB(40, 'onset')`. On lane 2 the actual wire send is the
worker's splice of a tape frame into a carrier tick, so the yield lives in
the worker: for the window's duration every carrier tick passes through
EMPTY — byte-for-byte the no-MAGIC idle-tick passthrough that already
existed, which the receiver already ignores. Data frames, key duplicates,
re-splices and pending parity are all held (a yield that let parity through
would be a smaller yield, not a real one). Held frames queue in the worker
FIFO in order; the reference chain has no hole; quality is untouched, time
is the shock absorber — §4's "stalls entirely, never degrades" executed
literally. Bounds: the duration is hard-capped (60 ms onset / 600 ms
pre-stall, clamped in tape.js), overlapping requests extend rather than
stack, and the FIFO cap went 6 → 12 precisely because a 400 ms pre-stall at
30 fps admission must absorb inFlight(5) + encoder-queue(~4) frames without
a drop — a drop there is an already-encoded frame going missing, a hole the
receiver can only repair with a keyframe. Counters: window count + requested
ms per kind (main thread), empty carrier ticks (worker, rides the existing
tick telemetry).

**Lever 4 — one wire message per detected fall, spent only in a listening
stretch.** The predictor runs in the `pcm-capture` worklet on the raw mic
(zero latency — a main-thread hop would spend part of the window it exists
to buy); only `predict`/`reset` cross the port (`score` at 100/s would be
port traffic for no decision). The model fires ~7×/utterance at its
operating point, so the app coalesces: one T_PRED pair per
`L0_PRED_COOLDOWN_MS` (2 s — falls are a sentence apart, ~2–4 s), counted
suppressions. T_PRED is 13 bytes on the EXISTING unreliable/unordered
`pcm-audio` channel, sent DUPLICATED (two copies back to back on the first
open association — §4: duplication, not FEC; a retransmit round trip would
defeat the point; at 1% loss the pair delivers with p ≈ 0.9999). It never
enters the RS machinery, the member bitmap, the ring, the playhead, or the
detector — the receiver's branch returns before any of that code. The
receiver dedupes the pair by sequence (copies counted — the dup count is the
proof the duplication happens) and then applies the listening gate: the
local detector must be `idle` AND no local onset for 2 s. Only then does it
(a) pad ALL N pcm-audio associations with ~25 KB of ~1 KB T_PAD datagrams
paced at the lane's own 125 pps tick, round-robin (cwnd is per association
— each stripe's window decays independently on a listening stretch; a
clumped pad would trip the wall it exists to pre-warm), and (b) pre-stall
its own Lane B uplink for ~400 ms via the same yield gate as lever 3. T_PAD
is discarded on sight by the receiver — counted, never touching groups,
ring, playhead, or detector; the proof it never entered the RS machinery is
that fecFailed/parityUnused do not move when padding runs. A false pre-warm
during our own speech costs ~25 KB (budgeted); the gate makes the 400 ms
video stall mid-sentence impossible-by-construction rather than unlikely.

**Kill switch.** `?lane0=0` (with the PCM flag on): the predictor is never
constructed (capture worklet's `processorOptions.turnend` is false),
sendTurnEnd/sendPad are structurally guarded on cfg.lane0, the yield call
sites are gated on LANE0 — no T_PRED/T_PAD byte can exist on the wire and
Lane B is never yielded. With `?pcmaudio=1` absent, LANE0 is false by
construction and nothing in this section runs at all.

## Gates, measured

**Static.** `npx tsc --noEmit` exit 0. node core/onset.test.mjs 54/54,
tape-app/turntaking.test.mjs 45/45, core/pcmrs.test.mjs "ok — 300 groups".

**Loopback, full 14-turn fixture** (`tape=2&pcmaudio=1`, run
lane0-loop-bot-msankd4c-d9ns). Lane A bars unmoved: drop(link) 0 both
directions, fecFailed 0, parityUnused 2626 = exactly 2× the 1313 RS groups
each way — the padding never entered the RS machinery — concealed 0 ms (A)
/ 8 ms (B), lost 0/1, age p50 0.8/1.1 ms, mode sab, depth 16/19 ms at
target 2f. A-V sync engaged both ends: presents 2027/2009, holds
4215/4246, drops 0, offset p50 −28.1/−28.2 ms (audio leading, inside the
[0,45] budget's sign convention). TIME_SYNC spread 0.573–0.728 ms,
526/526 pings both. Feature telemetry, cross-checked between the two
sides' independent counters: A's predictor fired 11 times (matches the
offline TurnEndPredictor run over conv/A.wav exactly), cooldown suppressed
4, wire sent 7; B received 7 predictions plus 7 dup copies; B fired 17,
suppressed 6, sent 11; A received 11 plus 11 dups. Every received
prediction was spent: A pre-warmed 11× (276,375 pad bytes over 275
messages, ≈25 KB per fire), B pre-warmed 6× (150,750 B over 150 msgs) —
the difference is B's listening gate refusing 5 times, of which 1 was
recv-while-speaking (the gate provably fires). Onset yields: A 12×40 ms,
B 16×40 ms. Empty carrier ticks: A 294 ≈ (12×40 + 11×400) ms × 60 tps =
292.8 expected; B 182 ≈ (16×40 + 6×400) × 60 = 182.4 expected — the pipe
measurably empties for exactly the yield windows.

**Loopback rerun (gate c, turns).** Run lane0-loop2-bot-msanu6xv-4ks8,
same query. score.mjs: 7/7 turns on all four observation paths (A own,
A hears peer, B own, B hears peer), real inhales kept 100%/100%/100%/86%,
breath-survives-transit 92.9%, m2e round trip 27 ms. The run-1 A-remote
miss was one-machine weather, not Lane 0 (see residuals). Lane A bars
unmoved a second time: drop(link) 0, fecFailed 0, parityUnused 2626 =
2×1313 groups, concealed 8 ms, lost 1/1, age p50 0.6/0.9 ms, sab, depth
16/18.7 ms at target 2f. A-V sync engaged (presents 2031/2003, drops 0,
offset p50 −27.8/−23.1 ms). Feature telemetry: A fired 14, suppressed 7,
sent 7, received 12 (+12 dup copies), pre-warmed 12× (300 msgs / 301,500 B
= 12 × 25,125); B fired 18, suppressed 6, sent 12, received 7 (+7 dups),
pre-warmed 5× (125 msgs / 125,625 B), recv-while-speaking 2. Every wire
cross-check balances (A sent 7 = B recv 7; B sent 12 = A recv 12; pad
bytes mirror). B's 5 pre-warms + 2 gate refusals = 7 received: the two
refusals landed in genuine overlap — B was inside its own speaking stretch
when A's turn-fall prediction arrived — which is the listening gate doing
its one job. Empty carrier ticks A 318 ≈ (12×40 + 12×400) × 60 tps =
316.8 expected; B 158 ≈ (16×40 + 5×400) × 60 = 158.4 expected.

**p2psim rtt=80 loss=1 pcmpairs=3 (gate d).** Run
lane0-p2p-bot-msao0l0w-vg4n. §17.13 bars unmoved: A sent 13123/13191
(99.5%) and B 13119/13161 (99.7%) — both ≥97%; age p50 43.3/43.6 ms —
both <100 ms; even split across the three associations (A 4357/4381/4385,
B 4361/4379/4379 — inside 0.7%); drop(link) 0 both. Video 97% admitted
both ways, 0 lost, age p50 66/63.6 ms at measured rtt ≈86 ms. A-V sync
engaged: presents 2030/2009, drops 0, offset p50 +27.6/+26.4 ms. Lane 0
under 1% loss is where the dup pair earns its keep: B sent 10 predictions,
A received all 10 unique plus 9 dup copies — of the 20 wire copies exactly
one was lost and it was a dup, so every prediction still landed (at 1%
independent loss, losing both copies is a 1e-4 event). A sent 7, B
received 7 + 7 dups. Padding round-robined evenly over all three
associations (A 83,415/84,420/83,415 B; B 50,250/50,250/50,250 B) and two
pad messages lost to the simulator were simply gone, as designed — padding
is disposable by definition. Listening gate still exact under loss:
B 6 pre-warms + 1 recv-while-speaking = 7 received. Empty carrier ticks
A 270 ≈ (12×40 + 10×400) × 60 = 268.8; B 180 ≈ (16×40 + 6×400) × 60 =
182.4.

**Kill switch `?lane0=0` (gate f).** Run lane0-off-bot-msao4fid-7uwu.
Both sides report DISABLED with every new counter at exactly zero:
turnend fires 0, suppressed 0, wire sent 0, wire recv 0,
recv-while-speaking 0, pre-warms 0, onset yields 0. No pred/pad line in
the PCM section, no Lane 0 line in the video section (yieldTicks 0 — the
worker's yield check never fires). Lane A behaves as the PCM baseline:
drop(link) 0, fecFailed 0, parityUnused 2627. Video returns to 98%
admitted both ways (2057/2102, 2062/2101) with skipped-link 0 — the
control arm that isolates the 96–97% admission in Lane-0-on runs as the
yield windows' deliberate admission pause (see residuals). A-V sync
engaged, presents 2050/2052, drops 0.

## What did not work / honest residuals

1. **Video admission is 96–97% with Lane 0 on, 98% with it off — and the
   delta is the mechanism, not a bug.** A 400 ms pre-stall holds all tape
   bytes off the wire; the inFlight gate fills within one frame and the
   main thread stops admitting captures for the window. Those frames are
   skipped at admission (skipped-link 43/18 across the two loopback runs
   vs 0 with the switch off) — never lost in flight (0 lost in every run).
   This is §4's "Lane B stalls entirely, never degrades" taken literally:
   the stall is real, bounded, and counted. The gate's 98% number is met
   only with Lane 0 off; with it on, the yield budget (12×40 ms +
   5–12×400 ms over a 70 s fixture ≈ up to 7.5% of wall time) directly
   prices the admission dip. Anyone wanting the old number sets
   `?lane0=0`.
2. **Run 1's A-remote turn #4 miss was weather, confirmed by rerun.** The
   detector onset landed 536 ms after the planted breath (scorer tolerance
   400 ms) with onset SNR 9 dB against 28–38 dB on its neighbours and the
   turn's end detected 1.4 s early — the quiet-head/tail signature of a
   one-machine CPU stall on the playout tap, while the audio path itself
   was byte-lossless (lost 0, concealed 0 on that side). Lane 0 cannot
   touch that signal: T_PAD is discarded before the ring, pre-stalls are
   video-only. The rerun on the same code scored 7/7 on all four paths.
3. **The worker FIFO cap went 6 → 12.** A 400 ms pre-stall would
   otherwise overflow the encoded FIFO (inFlight 5 + encoder queue ≈ 4 +
   margin) and a FIFO drop poisons the receiver's parity group — a hole in
   the reference chain, the one thing worse than a stall. Flag-off this is
   a threshold that is never reached (the inFlight invariant bounds the
   queue near 5–6 without yields; all runs, switch on or off, show zero
   FIFO drops), but it is a genuine diff against 42323653 and is disclosed
   here rather than claimed away.
4. **The predictor's economics on this fixture are visible in the
   counters.** A's 11–14 fires per side against 7 turns (the predictor's
   known multi-fire character, MIN_REFIRE 600 ms) cost 7 wire sends after
   the 2 s cooldown coalesces them, and the receiver's listening gate
   refuses the ones that land in overlap (1–2 per run, always exactly
   accounted: pre-warms + recv-while-speaking = wire recv). The system
   spends ≈25 KB of padding per accepted prediction; on loopback that is
   free, on a real constrained uplink the AIMD ceiling will meter it —
   that interaction is untested here and is the next honest experiment.
5. **Kill-switch run showed concealed 64/72 ms and lost 8/9 frames on
   loopback** — worse than the Lane-0-on runs (8 ms). With Lane 0 off
   there is no mechanism by which this work could cause it; it is the
   documented both-browsers-on-one-machine weather (§17.14's run 1 showed
   the same), noted so the number is on record rather than quietly
   dropped.
6. **Far-end inhale retention is 86–93%** (B hears peer 6/7 in run 1,
   86% in run 2, breath-survives-transit 92.9%) — pre-existing far-end
   detector behaviour on the quietest planted breaths, unchanged from the
   §17.13/§17.14 baselines, not moved by this work in either direction.

**Independently verified and live.** Both gates reproduced end-to-end after
review (`lane0-verify-loop`, `lane0-verify-80`): loopback concealed 0 ms both
sides with parityUnused exactly 2×groups and the wire cross-checks balancing
(sent == received on predictions and pad, both directions); at 80/1 with
`pcmpairs=3`, 99.5/99.7% sent, drop(link) 0, age p50 42.9/42.6 ms, split even,
pad striped evenly across all three associations (~91–92 KB each), the
duplicated pair losing only a copy at 1% loss while every unique prediction
landed, A-V offset +31.6/+31.2 ms inside §3's budget. Deployed to
room.tokkah.com as version 78d917c1-175c-457a-a07d-550438f782db; flag-off
headers re-verified identical in prod.

---

## 17.16 The VMAF courtroom: no crossover — the fixed-QP spine is justified

2026-08-01. Lab notebook. Pays down the measurement debt confessed in §17.11: the
"14.5 Mbps video shape sails" number rode the VP8 carrier under GCC while the PCM
numbers rode SCTP datachannels — a cross-stack comparison. The QUALITY half of that
debt is what this note settles: across a bitrate sweep, where do the custom fixed-QP
lane (`tape=2`, QP fixed, "quality is a constant, time is the only shock absorber")
and the stock fallback (VP8 under GCC on the standard RTP carrier) actually land,
scored the same way against the same source?

**Answer up front: at every operating point that matters, the lane wins outright —
higher VMAF at the same bits AND full frame rate. The only crossing lives at the
extreme bottom (QP ≳ 47, ≤ ~1.5 Mbps), where VP8's per-frame stills score ~8 VMAF
higher while delivering a 2–8 fps slideshow the still-metric cannot see. At the
design point (QP24) the lane sits at the rig's own measurement floor (VMAF 99.7
vs floor 99.1): transparent. The fixed-QP spine is justified on this fixture.**

## The numbers

Source fixture: `testbed/media/cam1080.mjpeg` (1920x1080, 900 frames, testsrc2 +
`noise=alls=3:allf=t`; Chrome's fake-capture device plays it at 30 fps — measured
15 source frames per 500 ms capture tick — regardless of the container's declared
25 fps). Scoring: ffmpeg 8.0.1 `libvmaf` (built-in vmaf_v0.6.1 model) + ssim + psnr
on 1080p PNG stills, 54–55 stills per arm captured at 2 fps from the RECEIVER's
presented surface over ~28.5 s, loopback, two Chrome for Testing browsers, dev
server on :8794. All arms back to back on one machine (serial rule held; the
machine was shared and each arm waited its turn).

### Custom lane (`?tape=2&pcmaudio=1&qp=N`), fixed QP sweep

| QP | delivered Mbps (window) | Mbps-at-fps | admitted | enc fps | VMAF mean | VMAF p5 | SSIM | PSNR |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 18 | 20.11 | 21.7 | 69.5% | 20.9 | 99.90 | 99.44 | 0.987 | 37.90 |
| 24 | 14.65 | **12.04** | 91.0% | 27.3 | 99.73 | 98.53 | 0.986 | 37.71 |
| 30 | 8.72 | 6.59 | 98.5% | 29.5 | 98.69 | 96.65 | 0.985 | 37.25 |
| 36 | 4.32 | 3.25 | 98.2% | 29.5 | 95.14 | 91.71 | 0.980 | 36.19 |
| 42 | 2.35 | 1.75 | 98.1% | 29.4 | 88.12 | 84.50 | 0.973 | 35.00 |
| 51 | 1.76 | 1.3 | 98.2% | 29.5 | 64.04 | 59.87 | 0.965 | 33.58 |
| 63 | 1.75 | 1.3 | 98.1% | 29.4 | 64.49 | 59.58 | 0.965 | 33.58 |

0 frames lost in every lane arm. The design point's real delivered cost on this
content: **12.0 Mbps-at-fps at QP24** (14.65 Mbps measured in the capture window at
27.3/30 fps admission; NOT the ~0.4 Mbps the task brief remembered from an older,
noise-free fixture — HANDOFF's media note has it right: alls=3 ≈ 12 Mbps at QP24).
QP18's 69.5% admission is the one-machine testbed talking (20 Mbps of 1080p
encode+decode on shared CPU), not a transport failure; its Mbps-at-fps column is
the normalized cost.

### VP8 under GCC (`?codec=vp8`, sender maxBitrate cap as the sweep knob)

| cap | delivered Mbps | decoded fps | VMAF mean | VMAF p5 | SSIM | PSNR |
|---:|---:|---:|---:|---:|---:|---:|
| 300k | 0.28 | 2.1 | 70.76 | 65.85 | 0.966 | 29.57 |
| 500k | 0.50 | 3.7 | 72.46 | 68.28 | 0.966 | 29.60 |
| 1M | 1.01 | 7.6 | 71.85 | 68.02 | 0.966 | 29.57 |
| 2M | 2.01 | 15.9 | 72.46 | 68.48 | 0.966 | 29.60 |
| none (app's 12M) | 3.52 | 22.3 | 76.59 | 72.37 | 0.970 | 29.79 |
| 6M | 4.64 | 25.9 | 77.59 | 73.27 | 0.972 | 29.90 |

One wrong-content alignment pair excluded from vp8-300/1000/6000/free each (see
Method honesty). VP8's per-frame quality is nearly FLAT across caps (70.8–77.6):
under pressure it sheds FRAME RATE (25.9 fps at 4.6 Mbps → 2.1 fps at 0.28 Mbps),
which per-frame VMAF does not penalize but a human calls a slideshow. The fps
column is part of the quality verdict.

### The crossover statement

| bitrate neighborhood | lane (fixed QP) | VP8 under GCC | gap |
|---|---|---|---|
| ~1.8 Mbps | QP51: VMAF 64.0, **29.5 fps** | cap 2M: VMAF 72.5, 15.9 fps | **VP8 +8.5 VMAF, lane ~2x fps** |
| ~2.0–2.4 Mbps | QP42: VMAF **88.1**, 29.4 fps | cap 2M: VMAF 72.5, 15.9 fps | **lane +15.7 VMAF, ~2x fps** |
| ~4.3–4.6 Mbps | QP36: VMAF **95.1**, 29.5 fps | cap 6M: VMAF 77.6, 25.9 fps | **lane +17.6 VMAF, +3.6 fps** |
| ~6.6–8.7 Mbps | QP30: VMAF **98.7**, 29.5 fps | (VP8 never delivers here: saturates ~77.6 by 4.6 Mbps) | ≥ +21 |
| 12–14.7 Mbps (design pt) | QP24: VMAF **99.7**, 27.3 fps | — | — |

- **The crossing exists, and it is at QP ≳ 47 / ≤ ~1.5 Mbps.** Fixed-QP means the
  quality knob IS the bitrate knob: past QP42 the curve falls off a cliff (88.1 →
  64.0 between QP42 and QP51 — noisy content keeps costing bits long after the
  quality is gone). At QP51 the lane's per-frame VMAF (64.0) finally drops below
  VP8's flat ~71–72 band at comparable bits — but VP8 there is painting 7.6–15.9
  fps against the lane's 29.5. By the app's own doctrine ("a 10 fps call reads as
  broken even at perfect sharpness", app.js:1291) the lane still wins the
  experience even below the VMAF crossing. (QP63 is a duplicate of QP51, not a
  new point: 8-bit H.264 caps at QP51 and VideoToolbox clamps — identical
  scores, 64.0 vs 64.5, are the signature.)
- **Everywhere at or above ~2 Mbps there is no crossover**: the lane's QP42 floor
  (88.1) sits 10.5 points above VP8's ceiling (77.6), at half the bits and full
  frame rate.
- **VP8's quality saturates**: its unconstrained landing is 3.5 Mbps / VMAF 76.6,
  and giving it a 6 Mbps cap moves it to 4.64 Mbps / 77.6 — call it ~77–78 on this
  content no matter the bits, because Chrome's realtime VP8 spends additional
  budget mostly on holding frame rate. That ceiling is a property of
  Chrome-realtime-VP8-under-GCC (the actual fallback), not of the VP8 bitstream
  format; libvpx offline would do better. The comparison that matters for the
  product is the one measured.
- **The lane's quality is where the design says it lives**: QP24 is at the rig's
  floor (transparent); the spine trades bitrate, never pixels — exactly the
  bargain §1 states, now measured end to end at the receiver's glass. Note the
  design point is not free: QP24 costs 12 Mbps-at-fps on this content, and the
  delivered column includes the lane's ~33% XOR-FEC tax (G=3); VP8's column
  carries no FEC. The comparison is delivered-wire-bits to delivered-wire-bits.

## Method honesty

1. **Scoring floor.** Chrome's canvas YCbCr→RGB conversion matches BT.709, not
   the BT.601 ffmpeg applies to this mjpeg by default (measured with
   `testbed/colormtx-probe.mjs`: local capture, NO encode, matches a
   709-converted reference at 38.3 dB PSNR vs 34.2 dB at 601; a naive
   full-range direct conversion is worse still — Chrome's path includes the
   limited-range roundtrip). Every reference frame was therefore passed through
   `colorspace=bt709:iall=bt470bg:fast=1` before scoring. The residual method
   error, measured on local-capture stills with no encoder anywhere: **floor =
   VMAF 99.10, SSIM 0.987, PSNR 38.26 dB**. Arms at the floor (QP18, QP24) are
   transparent to this rig; differences above it (99.9 vs 99.7) are not
   resolvable. The same conversion and floor apply to every arm, so the
   crossover (a differential question) is unaffected by the constant.
2. **The fixture's own noise caps PSNR/SSIM.** `noise=alls=3` is iid dither any
   encoder low-passes; PSNR ~35–38 and SSIM ~0.97–0.99 at the TOP of the table
   are the fixture's ceiling, not codec damage (floor PSNR is 38.26 with no
   encoder at all). VMAF is the primary metric for exactly this reason.
3. **Stills at 2 fps are blind to temporal starvation.** VP8's sub-2-Mbps arms
   hold per-frame VMAF ~72 while delivering 2–8 fps. Any crossover claim that
   ignored the fps column would be lying; it is reported beside every VMAF.
4. **Alignment is content-based, not clock-based.** The fake camera loops the
   fixture with an unknowable phase, so every still was matched to its source
   frame by 160x90-gray MSE (matched MSE ~0.3–0.4 — near-exact). testsrc2's
   periodic motifs fooled the global match exactly once in each of 4 VP8 arms
   (a wrong-content pair scoring ~61–67, visible as a backward jump in the
   matched-index sequence); those pairs are EXCLUDED from the adjusted means
   above (raw means differ by ≤0.2 VMAF except p5: vp8-free 71.6→72.4,
   vp8-6000 72.9→73.3). Lane arms were scored with a monotonicity-guarded
   matcher (re-search ±45 frames around the interpolation on a break) and had
   zero mismatches. Matched-index sequences are in each arm's scores.json.
5. **First scoring pass had a wrap-rotation bug** (select emits frames in
   decode order; a matched sequence crossing the file's loop point came out
   rotated → every pair wrong → VMAF 27). Caught because QP24 at 12 Mbps
   scoring 27 is implausible on its face, verified by hand on kept samples,
   fixed, and all arms re-run. Never report green on red; the reverse also
   holds.
6. **VP8 cap mechanism**: sender `setParameters` maxBitrate applied from the
   test script post-join — the app's own mechanism (app.js:1289 sets 12 Mbps
   the same way), never on a `tape=2` page (law 1; the script refuses). No app
   files were edited; the lane's QP knob is the app's existing `?qp=` flag.
7. **GCC run-to-run variance is real**: vp8-free delivered LESS than vp8-6000
   (3.52 vs 4.64 Mbps) despite the higher cap — the two are ~1 VMAF point
   apart and should be read as the same landing zone, not an ordering.
   vp8-free also got a longer warmup (20 s vs 10 s) to clear GCC's ramp.
8. **One machine is not two** (§17.10): two Chromes share CPU; QP18's 69.5%
   admission and VP8's 22–26 fps ceiling carry testbed contention. Delivered
   Mbps are measured in-window from tape.snapshot()/getStats deltas, so the
   bitrate axis is honest even where fps sagged.
9. **Observer cost**: the 2 fps canvas→PNG capture runs on the receiver's main
   thread in every arm identically (~10–20 ms per grab); arms are comparable,
   absolute latencies are not this note's question.
10. **What was NOT tested**: loss (this is a clean-path quality comparison;
    the lane's loss story is §17.7/§17.9), AV1/H264 fallback lanes, two-machine
    runs, and human viewers. VMAF is a model; the p5 column is there so a
    single bad frame can't hide in the mean.

## Artifacts

- Runs: `/private/tmp/claude-501/-Users-earningsgpt-a109f52c-5d0e-4a3b-86b5-31ee4739e8ef/scratchpad/vmaf/<arm>/{run.json,scores.json,vmaf.json}` (+2 sample stills per arm; full still sets deleted per the 500 MB budget).
- Harness: `testbed/vmaf-call.mjs` (capture), `testbed/vmaf-score.mjs` (align + score), `testbed/colormtx-probe.mjs` (matrix calibration).
- Sweep logs: `scratchpad/vmaf/sweep*.log`.

---

## 17.17 The quiet wall and the real-breath classifier: root causes, fixes, and every gate re-measured

One-line summary: the two §17.1 addendum defects (60% of utterances never re-onset on quiet floors; 16% real-breath classification) were rooted in a fixed 3 dB end-gate and a single 35 ms look tuned on fixture room tone; the shipped fixes (peak-relative end-gate, floor-gated second look, await-voice hang) are now pinned by 15 new detector tests and re-measured on the 209-file corpus with exact before/after numbers — all gates green.

## Root causes, as actually found

**Defect 1 — the quiet wall.** The end-gate was `END_SNR_DB = 3` above the tracked floor, full stop. On a quiet floor (−57 dBFS) the inter-sentence residual of real read speech — exhales, mouth noise — sits at −50…−40 dBFS, i.e. 7–17 dB *above* the floor. A floor+3 gate is therefore never crossed, the leaky hang counter never fills, the turn never ends, and the next utterance merges into the open turn: no fresh onset, no head-start measurement. The same residual at a −30 dBFS floor falls *under* floor+3, which is why the merge rate fell monotonically with rising floor (60% clean → 3% at −30) — the defect was invisible at loud floors. Root cause in one sentence: the gate measured distance from the floor, when what separates "the talker stopped" from mouth noise in a quiet room is distance from the *speech* (gap residual p95 ≈ −24 dBFS vs segment peaks ≈ −14; `testbed/gap-levels.mjs`).

**Defect 2 — real-breath classification at 16%.** Two stacked causes.
(a) The single classification look at 35 ms was tuned on the fixture, where a breath follows pure synthetic room tone. Real breaths follow loud exhales: the onset fires 70–215 ms early on the sub-threshold ramp (by design — that is the head start), so at 35 ms the features measure the *context* — an exhale tail or real room tone, low-tilted and quasi-periodic (LibriSpeech idle stretches: periodicity 0.3–0.6, tilt −10…−20 dB, vs the fixture's flat noise) — and the classifier says 'voice'. The same breath shows textbook breath features (periodicity ~0.2, tilt +3…+10) 150–250 ms in (`testbed/breath-autopsy.mjs`).
(b) Even when the first look was right, the ordinary 350 ms hang closed breath-opened turns inside the breath→speech lull (measured lulls 10–1700 ms, median ~530), silently discarding the `voiced` head-start event the detector had correctly earned.

## What changed (all pre-existing in `core/onset.js` from the fix session; this session pinned and re-measured them)

- `core/onset.js:69` — `TURN_DROP_DB = 20`; end-gate at `core/onset.js:511` is now `max(END_SNR_DB, turnPeakDb − turnDropDb − floorDb)`. Swept 8–20 on the corpus: 20 is the smallest value whose peak term falls under floor+3 at the −35 floor (peaks ≈ −14 → −14−20 = −34 < −32), so loud floors are bit-identical while quiet floors can close.
- `core/onset.js:243-254` — the second look: a 'voice' turn is re-examined at 150 ms on windowed (70 ms→) features, revision only voice→breath, and only when `floorAtOnsetDb < RECLASS_MAX_FLOOR_DB = −42` (`core/onset.js:546,555`). The floor gate is on the floor *at the turn's own onset* so a turn cannot lose its second look mid-way. Ungated, the look traded 24 flipped speech onsets for +4 breaths at loud floors; quiet floors trade 9 for 9.
- `core/onset.js:78` — `AWAIT_VOICE_HANG_MS = 1200` for breath-opened turns awaiting phonation (`core/onset.js:514`), with the hang counter cleared when phonation is confirmed (`core/onset.js:582`) so the turn does not end the instant the watch clears.

## What this session added

1. **15 new pinned tests** in `core/onset.test.mjs` (hardlinked to `tape-app/public/core/onset.test.mjs`), reproducing each defect in miniature and its fix:
   - Test 15 (quiet wall): speech → wandering residual → speech. Shipping gate: 2 onsets, natural end stamped 1260 ms (speech ended 1100). Old gate (`turnDropDb: 1000`): ONE onset — the second utterance merges, the corpus defect.
   - Test 15b (loud floor invariance): same loud-room signal through both configs → identical end timestamps [1400, 4800], both natural.
   - Test 16 (second look): voiced-mumble → breath → words. Quiet floor: first look 'voice' (periodicity 0.85 — it measured the context), revised to breath at 855 ms (aperiodic frac 1.00), head start recovered at 356 ms (truth ≈365). Old config (`reclassifyMs: 1e9`): stays voice, no `voiced` event. Loud floor: the gate holds — same shape stays speech, one classification, no revision.
   - Test 17 (await-voice hang): breath, 700 ms lull, words. Shipping: ONE turn, `voiced` leadMs 946 (truth 980), end stamped 2000 where words stop. Old hang (`awaitVoiceHangMs: 350`): turn splits in the lull, 2 onsets, lead lost.
2. **`testbed/corpus-score.mjs`: `BEFORE=1` mode** that re-runs the corpus against the exact pre-fix configuration reconstructed from the shipping detector's own options (`{ turnDropDb: 1000, reclassifyMs: 1e9, awaitVoiceHangMs: 350 }`) — identical code, identical labels, apples to apples. Writes `media/corpus-score-results-before.json`; the shipping run's output file is untouched.

## Gate numbers (before → after)

### (a) `node core/onset.test.mjs`
- Before this session: 54/54 pass (fixes were in, but unpinned).
- After: **69/69 pass** (54 + 15 new). Headline instruments unchanged: breath head start 320 ms, cost 0.04% of real time, detection floor 12 dB over room, reported-lead worst error 44 ms, mean bias −30 ms (under-reports — the safe direction).

### (b) `node tape-app/turntaking.test.mjs`
- **45/45 pass**, before and after (no consumer-side change needed).

### (c) corpus re-score (209 LibriSpeech files × 7 floors; BEFORE=1 vs shipping)

Cross-check on the reconstruction: the BEFORE=1 option-reconstructed run matches the archived pre-fix run (media/corpus-score-results.json from 2026-08-01T14:13, actual old code) at every level on every compared row — merge rates 60.2/40.9/26.1/21.6/17.1/11.4/3.4, classified counts 0/2, 2/5, 2/3, 1/5, 1/6, 2/6, 1/8, FA 27/33/32/27/30/51/93. The option triple is the old configuration, not an approximation of it.

Passing bars, pooled across all 7 levels (616 speech trials, 56 breath trials):
- **speech hard-miss: 0/616 = 0.0% before → 0/616 = 0.0% after.** Unmoved.
- **breath hard-miss: 2/56 = 3.6% before → 1/56 = 1.8% after** (bar: ≤3.6%). Improved, not regressed — the one remaining miss is at −35 dBFS, the same level that had one before.

The two target defects:

| floor | speech merged before → after | breath detected before → after | breath classified before → after | voiced (head start) before → after |
|---|---|---|---|---|
| clean (−57.1) | 60.2% → **19.3%** | 2/8 → **5/8** | 0/2 → **5/5 (100%)** | 0/2 → **5/5** |
| −55 | 40.9% → **20.4%** | 5/8 → 6/8 | 2/5 → **4/6** | 2 → **4** |
| −50 | 26.1% → **18.2%** | 3/8 → 4/8 | 2/3 → **3/4** | 2 → **3** |
| −45 | 21.6% → **18.2%** | 5/8 → 5/8 | 1/5 → **2/5** | 1 → **2** |
| −40 | 17.1% → **15.9%** | 6/8 → 6/8 | 1/6 → 1/6 | 1 → 1 |
| −35 | 11.4% → 11.4% | 6/8 → 6/8 | 2/6 → 2/6 | 2 → 2 |
| −30 | 3.4% → 3.4% | 8/8 → 8/8 | 1/8 → 1/8 | 1 → 1 |
| pooled | 159/616 (25.8%) → **94/616 (15.3%)** | 35/56 → **40/56** | **9/56 scored (16%) → 18/56 (32%); of detected: 9/35 (26%) → 18/40 (45%)** | 9 → **18** |

Fresh-onset rate at quiet floors (the defect-1 gate): at the clean −57 dBFS floor, scored utterances getting a fresh onset went **39.8% → 80.7%**; scored breaths **25% → 62.5%**; head-start (`voiced`) measurements **0 → 5 of 5 detected**. The merge rate falls monotonically with floor exactly as before — the fix removes the quiet wall without touching the loud end (3.4% → 3.4% at −30).

False alarms (the regression watch): loud floors bit-identical before and after — **30/51/93 at −40/−35/−30 dBFS**, exactly as the TURN_DROP_DB sweep predicted (20 dB puts the peak term under floor+3 at −35 and up). Clean floor rose 27 → 62 over 24.1 min of speech (1.12 → 2.57/min; 9.43 → 21.65/quiet-min) — the cost of closing turns where residual sits far above the floor: each closed turn re-arms the onset gate for the next residual bump. They cost datagrams, not milliseconds (the asymmetric bias, `onset.js:19-23`).

Forced ends: zero at every level after (one 'never-quiet' at clean before — a turn the fixed gate held open for 8 s until the backstop fired; the defect caught in the act).

Fake-fixture regression check: all 54 pre-existing synthetic tests pass unchanged, including the breath-classification fixture (test 2: breath → 'breath'; test 6: single turn; tests 9–10: sensitivity and lead accuracy — head start 320 ms, worst lead error 44 ms, bias −30 ms).

Note: the −30 dBFS classification row (1/8) is §17.1's already-known loud-floor window physics, unchanged *by design* — the −42 dBFS reclass gate refuses to flip breath-shaped speech. It is not the target of this fix and not a regression.

## Residuals, honestly stated

- Clean-floor false alarms rose 27 → 62 over 24.1 min of speech (1.12 → 2.57/min of audio; 9.43 → 21.65 per quiet-minute) — the asymmetric-bias arithmetic made audible: they cost datagrams, not milliseconds.
- 19.3% of clean-floor utterances still merge: a quiet mouth-pop is not always separable from speech-in-progress by any energy gate.
- Loud-floor breath classification is unchanged *by design* (1/8 at −30 dBFS): the −42 dBFS floor gate makes §17.1's physics explicit rather than trading 6:1 against it.
- Corpus caveat stands: only 8 scorable breaths per level (±17% binomial noise); 54 of 82 automatic breath labels sit in loud contexts where no re-onset is physically possible.
- The detector code itself (`core/onset.js`) was not touched this session — the fixes predated it (DESIGN.md §17.1 addendum) but had no pinned tests and no recorded after-run; this session supplied both. No consumer-side change (app.js/tape.js/pcm.js/worker.ts/pcm-worklet.js) was needed.

---

## 17.19 Lobby and room capacity, measured against prod: the 2-occupant cap is the only knee, and it is a designed constant

Measured 2026-08-02 against production (Cloudflare Workers + one Durable Object per room,
`run_worker_first: true`, worker version 78d917c1). Harness: **`testbed/lobby-probe.mjs`**
(new, owned by this task). Raw data: `testbed/runs/lobby-probe-msarygub.json` (definitive)
and `testbed/runs/lobby-probe-msarszt3-rehearsal.json` (first run; two harness bugs found
and fixed between runs — it also serves as an independent replication). Two full runs,
same conclusions. No deploys, no edits to any file outside `testbed/`.

## 1. What §15 actually asks for (and what it doesn't)

The HANDOFF's "lobby capacity probe/tiers (§15)" pointer resolves to two different
"capacities" in DESIGN.md:

- **§6 / §15-lobby client capacity**: the 3-second *uplink* probe that locks the quality
  tier (S/A/B/C/D = 2.5–25 Mbps uplink). That is a media-path property between two
  browsers — already `testbed/call.mjs` territory, not a server question.
- **Room / control-plane capacity**: §14 puts "control only, ~1 KB/s" of WSS traffic
  through one DO per room ("NEVER touches media"), and §15's UI is strictly 1:1
  ("their face", one Join button — there is no N-way call in the design).

§15 specifies **no occupancy tiers and no N > 2**. The deployed DO
(`tape-app/src/worker.ts:196`) hard-caps a room at **2 occupants**
(`peers.size >= 2 → 409 "room full"`). So the occupancy knee is a designed constant; the
honest measurement questions are: admission latency (cold vs warm DO), relay latency at
and beyond the §14 ~1 KB/s design point, cap-rejection behavior, epoch persistence across
DO eviction (§10), and whether parallel rooms interfere — the design's real scaling axis
is rooms, not occupants. That is what was measured.

## 2. Harness design

`testbed/lobby-probe.mjs` (Node 20, auto re-execs with `--experimental-websocket` for
undici's client). Good-citizen contract: throwaway rooms `capacity-probe-<run>-N`, all
sockets closed at exit, gradual ramp, every tier aborts at the *first* degradation sign
(unexpected close/error, any lost echo, or p95 > 3× idle baseline). Machine-wide heavy-run
mutex (`pgrep -f "call.mjs|sctpwall.mjs|corpus-score.mjs"` must be empty) checked before
start and again before the parallel-room phase — the run queued behind another agent's
stall sweep and started only when it drained. Peak footprint: 14 websockets, ≤100 msg/s
aggregate. `/api/ice` recorded as *shape only* — TURN credentials never printed.

Echo method: probe clients A and B join one room; A sends tagged 1 Hz pings, B echoes over
the relay; RTT = A→DO→B→DO→A. Pings ride the *same* websocket as the offered background
load (both peers send load, each relayed to the other — the DO forwards 2× the per-peer
rate), so client-side head-of-line is included, exactly as the app's ctl channel
experiences it.

## 3. Measured numbers (definitive run `msarygub`; rehearsal in agreement)

### 3.1 Admission (8 fresh rooms, sequential cold DOs)

| Metric | p50 | p95 | min | max |
|---|---:|---:|---:|---:|
| First join (A, cold DO): connect→welcome | **996 ms** | 1203 ms | 966 ms | 1203 ms |
| Second join (B, warm DO): connect→welcome | **175.5 ms** | 182.5 ms | 159 ms | 183 ms |
| Concurrent burst: 4 rooms × 2 joins at once | 1013.5 ms | 1031.9 ms | 950 ms | 1032 ms |

- Cold-start tax ≈ **820 ms** (p50 A − p50 B). The `welcome` message arrives <1 ms after
  the ws `open` event in every case — the DO answers synchronously inside the upgrade, so
  the entire cost is connection establishment (TLS + edge routing + DO cold start), not
  an extra round trip.
- The cold-join tail varies run to run (rehearsal p95 1910 ms vs definitive 1203 ms) —
  DO placement/cold-start variance, not load.
- Correctness 8/8: role `a`/`b` assigned in join order, `peerPresent:false→true`,
  `peer-joined` delivered to A on every B join, A and B epochs agree within each room.

### 3.2 Occupancy cap (the designed knee)

Third joiner with a valid WebSocket handshake → **HTTP 409, body `room full`**, served by
the DO. The two occupants were unaffected: an echo round trip immediately after the
rejection measured 144.5 ms, no close/error frames. (Rehearsal caveat: a malformed probe
handshake was 400-rejected by Cloudflare's *edge* before reaching the DO — an edge-layer
400 and a DO-layer 409 are distinguishable, and the definitive run used a spec-valid key.)

### 3.3 Relay latency vs offered ctl load (single room, echo RTT ms)

| Tier | Offered (per peer) | Aggregate through DO | n | p50 | p95 | max | echoes lost |
|---|---|---:|---:|---:|---:|---:|---:|
| T0 idle | — (1 Hz ping) | ~0.1 KB/s | 14 | 142.0 | 151.1 | 151.1 | 0 |
| T1 **§14 design point** | 1 msg/s × 1 KB | ~2 KB/s | 20 | 140.2 | 152.0 | 152.0 | 0 |
| T2 | 5/s × 1 KB | ~10 KB/s | 21 | 141.5 | 149.1 | 151.0 | 0 |
| T3 | 20/s × 1 KB | ~40 KB/s | 20 | 139.8 | 162.2 | 162.2 | 0 |
| T4 | 50/s × 1 KB | **~100 KB/s** | 20 | 137.8 | 174.9 | 174.9 | 0 |
| T5 SDP-size burst | 2/s × 8 KB | ~32 KB/s | 12 | 142.8 | 156.4 | 156.4 | 0 |

**No knee found** up to ~100 msg/s / ~100 KB/s aggregate relay — 50× the §14 ~1 KB/s
control budget — with zero lost echoes, zero socket closes/errors, and client-side
`bufferedAmount` never exceeding ~1 KB (no send-side backpressure anywhere). p95 moved at
most +24 ms at T4 vs idle, and p50 actually *fell* slightly under load (142→138 ms —
keep-alive effects; not a degradation signal). Rehearsal replication: same flat profile
(T0 155.1 / T1 155.3 / T4 153.9, 0 lost).

The absolute RTT (~140–155 ms) is geography, not load: it is two client↔DO round trips,
putting this probe machine ≈ **70–75 ms one-way from the DO**. §14 already prescribes
"place the DO near the first joiner via location hints" — **worker.ts does not set
location hints yet** (see §5 recommendations).

### 3.4 Room-count scaling (6 rooms × 2 occupants, all at T1 design load, 20 s)

Aggregate 114 echoes: p50 **145.8 ms**, p95 176.8, p99 185.8, max 213.5; 0 lost, 0 closed.
Per-room p50 ranged 140.7–157.8 ms. The two rooms reading ~16 ms higher match run-to-run
placement variance seen elsewhere (each DO is placed independently), not interference:
aggregate p50 is within 4 ms of the single-room T1 baseline. Rooms scale by DO count, as
designed.

### 3.5 Persistence, eviction, idle behavior

- **§10 epoch survives eviction**: phase-1 room rejoined after ~4 min idle (DO certainly
  evicted) returned the identical `session_epoch_us` (1785613206721000) — DO-storage
  persistence verified in prod.
- **No idle timeout on live sockets**: a sentinel room held open for the entire ~5 min run
  with only 1 Hz pings was never closed by the platform; final echo 170.2 ms.
- Rejected joiners cost the room nothing observable (§3.2); no error frames propagated.

## 4. The knee

**Occupancy: exactly 2, by design** — third join 409s cleanly. **Relay: no knee found up
to 100 KB/s aggregate (~50× design point)** within the good-citizen envelope this probe
permitted itself. The first real limit was not reachable at polite load levels; what
limits the *product* today is DO placement latency, not DO throughput.

## 5. Recommended lobby tiers

1. **Keep the 2-occupant room.** It is the §15 design, it is enforced surgically (409,
   occupants untouched), and the control plane has 50× headroom at the §14 budget. There
   is no capacity reason for occupancy tiers.
2. **Lobby admission UX budget**: first joiner pays ~1 s cold-DO admission (p50 996 ms,
   p95 1.2–1.9 s); second joiner ~175 ms. The lobby's Join flow should treat ~1 s
   first-join latency as normal and show progress rather than a frozen button. (Cheapest
   fix, if wanted: warm the DO when the lobby page loads, not at Join — a worker-side
   design note only, not applied.)
3. **Add DO location hints** (worker-side change, *designed here, not applied* per task
   rules): `env.ROOM.idFromName(code)` + `env.ROOM.get(id, { locationHint })` from
   `request.cf.country`/colo of the first joiner, per §14's own prescription. From this
   vantage point the DO sits ~70–75 ms away; a hint would cut signaling/epoch RTT to edge
   distance for the common case and directly improves §10 TIME_SYNC bias.
4. **Control-traffic budget can grow if ever needed**: up to ~50× the current design point
   measured with zero latency cost. No worker change is needed for any plausible ctl
   growth (TIME_SYNC at 5 Hz, age reports at 1 Hz, re-splice requests are all ≪1 KB/s).

## 6. What could not be measured from outside (honest gaps)

- **DO-internal CPU/memory per message** — no client-visible signal; only its absence of
  effect on latency was observable.
- **True one-way relay delay** — no clock sync with the DO; RTT/2 ≈ 70–75 ms is an upper
  bound dominated by geography.
- **Each DO's actual placement** — inferred from latency only; `locationHint` verification
  needs the worker-side change in §5.3.
- **Behavior beyond ~100 msg/s aggregate** — the good-citizen contract stopped the ramp
  before any platform limit (DO CPU billing caps, edge rate limits) presented. The knee,
  wherever it is, is above 50× the design point.
- **The lobby's §6 uplink probe** (tier S/A/B/C/D selection) — a browser media-path
  measurement, out of scope for a websocket probe and already covered by the call harness.

## 7. Reproducibility

```
node testbed/lobby-probe.mjs     # self-gates on the heavy-run mutex; ~5 min
```

Rooms are named `capacity-probe-<run>-N` and every socket is closed at exit; nothing is
written to prod telemetry endpoints. Raw JSON per run lands in `testbed/runs/`.

---

## 17.18 The stall machine lands: regimes, sheds, lane-P stills, and the clean-cut resume

One-line summary: the §12 regime classifier and §13 stall machine (VIDEO HELD / HOLD, sender-side shed, lane-P stills, clean-cut resume) are implemented behind the `pcmaudio` flag with a `?stall=0` kill switch, and every state — nominal, squeeze, absorb, held, hold — was measured live in the testbed, including organic sheds at 1.5/0.8/0.5 Mbps bottlenecks and a forced full-cycle loopback run; all gates pass (PCM 99.40–99.67% ≥ 99.4%, video admission 96–97% ≥ 96%, tsc 0, 45/45 turntaking, pcmrs ok, flag-off path untouched).

## What §12–13 demanded

- §12: a congestion controller whose output is a **regime** (NOMINAL / SQUEEZE / ABSORB / SHED / HOLD), never a bitrate; no wire to the encoder. D_max 400 ms video / 120 ms audio. SHED when "C < R, sustained — backlog will exceed budget": drop lane B entirely, start lane P, audio gets 8× headroom. HOLD when C < R_audio.
- §13: VIDEO HELD keeps the last complete frame on screen, lane P sends crisp stills ~1 fps, audio stays LIVE, UI says "holding · audio live"; HOLD pauses both with an honest "paused — reconnecting" UI. Rule 1: receiver detects, **sender** sheds via LANE_SHED. Rule 2: resume never replays backlog — discard queued frames + fresh keyframe, one clean cut. Rule 3: cut, not glitch.

## What was built (file:line)

**tape-app/public/tape.js**
- Stall machine core: `setRegime` 1773, `enterHeld` 1787 (saves shedMaxId, purges avq/groups/fragReqIds, sends `{t:'shed'}` on ctl), `sendResume` 1803, `exitProbe` 1815 (minHold 4 s, 2 s clean of lane-P age <250 ms → resume, maxHold 60 s escape), `classify` 1830 (1 s sliding windows on delivered-frame age; bands <250 nominal / <400 squeeze / else absorb — the AIMD governor's own thresholds; nominal re-entry needs 2 s clean per the §13 diagram; **SHED = age p50 > 400 ms (backlog over D_max budget) OR delivered fps ≤ 3, sustained 3 s, after 10 s startup grace**).
- Lane P: `maybeStill` 1872 (OffscreenCanvas.convertToBlob JPEG, lpWidth 960, q0.85, 1 fps throttle, 8-byte wallclock header), `onLaneP` 1899 (age from session clock, paints only while held); channel `tape-lanep` created pre-offer by the initiator (2171, no-renegotiation law), answerer adopts via `adoptLaneP` 2241.
- Held receive path: 1344 (only a keyframe with id > shedMaxId ends the hold; everything else counted `shedSkipped` and discarded — no backlog replay, Rule 2), parity ignored while held (1430).
- Sender shed path: pumpCapture drops captured frames at source (`skipShed++` 2070, maybeStill instead), `onEncoded` drops in-flight encodes (2026), worker `purgeForShed` 762/807 clears the encode queue + FEC accumulators on shed/resume and reports the count back (`shed-purged` 1318) so `inFlight` stays exact; on `resume` the sender forces a fresh keyframe and restarts the pacer at l2PaceStart.
- Test hook `?stallforce=N` (forces held at N s) 2137–2143; snapshot exposes `stall` (regime, shedded, lpAgeP50, transitions) and lane-P counters; `shedNow()` 2252 public trigger.

**tape-app/public/app.js**
- `STALL = PCM_AUDIO && QS.get('stall') !== '0'` (476) — flag-off is byte-identical by construction: no lane-P channel, no ctl bytes, no classifier, no timer.
- Knobs 415–424 (`stallage` 400, `stalldwell` 3000, `stallfps` 3, `lpfps` 1, `lpw` 960, `lpq` 0.85, `stallforce`).
- HOLD classifier (478–520): 8 s sliding window over pcm.snapshot() concealedMs; audioHold when concealed fraction > 0.25; `stallUi()` badge ("holding · audio live" / "connection paused — reconnecting"); `onStall` wiring 740; answerer channel adopt 767; `__tapeProbe.stall`.

**testbed/call.mjs** — grabs `tape.stall` snapshot (453), prints stall regime/counters (654), lane-P line (660), transition log, and app-side `audioHold`/`videoHeld` (671).

## Gate numbers

Unit/compile: `npx tsc --noEmit` exit 0; turntaking 45 passed / 0 failed; pcmrs ok.

| run | conditions | result |
|---|---|---|
| stall-loop / stall-loop2 | loopback `tape=2&pcmaudio=1` | regime nominal entire run, shed/resume 0, lpSent 0, video 96–97% admitted, age p50 22–23 ms — zero false sheds |
| stall-80-1b (final code) | RTT 80, 1% loss, pairs=3 | PCM sent A 13122/13201 = **99.40%**, B 13117/13160 = **99.67%** (bar ≥99.4%); video admission **97%/97%** (bar ≥96%); no shed; A-V sync engaged, 0 drops |
| stall-bw15b | RTT 80, bw 1.5 Mbps | organic sheds both directions (A held@41s→45s; B held@70s→75s and @79s→83s, trigger "capacity"); lane P painted 9/18 stills at age p50 ~100 ms; PCM 99.3–99.5% sent, concealed 3.2% — audio fine while video held |
| stall-bw08b | RTT 80, bw 0.8 Mbps | held-dominant from ~70 s (log capped at last 12 transitions); skipShed ~900–1000 frames dropped at source; stills 46–53 painted at p50 ~160 ms; PCM 99.5% sent, concealed 5–6.4%, audioHold false |
| stall-bw05 | RTT 80, bw 0.5 Mbps | **HOLD fired both sides**: stall-hold enter at 6.6/6.9 s (concealed frac 0.98), audioHold + videoHeld true at end; video held (uplink shed), stills flowing at p50 ~330–356 ms |
| stall-force | loopback `&stallforce=30` | both sides held@30s → shed sent/recv 1 → stills painted (13/5) → resume → keyframe cut: A nominal@34s, B@42s; shedSkipped 1 stale frame correctly discarded; purged 1; audio untouched (concealed 112 ms) |
| stall-off | `tape=2` alone (flag off) | no stall snapshot, zero `tape-lanep` occurrences in either event log, video 98% admitted — wire-identical |

## Design decisions worth review

1. **Shed trigger is age-only, not age-and-fps.** First cut required p50 > 400 AND fps ≤ 3; at bw 0.8 video limped at 4 fps / p50 574–783 ms for 50+ s and never shed — but age over D_max *is* "backlog will exceed budget", so the fps requirement was spec-violating. Fixed to p50 > 400 OR fps ≤ 3, sustained 3 s. All runs above are with the fixed trigger.
2. **Regime bands reuse the AIMD thresholds** (250/400) — classify() names what the governor is already doing; C/R is never estimated directly (admitRate/fps embodies it).
3. **Resume probing uses lane P itself**: stills are the same size class and path as video frames, so 2 s of lpAge < 250 ms is the "capacity restored" signal; maxHold 60 s is the escape hatch if lane P dies.
4. **HOLD does not shed our video** — HOLD is the receive direction collapsing; Rule 1 puts the shed decision on the peer's classifier.

## NOT built, and why

- **WSOLA ≤5% stretch (§12 SQUEEZE mechanism)**: lives in pcm.js, owned by another agent concurrently. The existing ±0.2% resample is a stricter bound on the same axis; SQUEEZE currently grows D by jitter-target growth, audibly clean at these depths.
- **RECV_REPORT @20 Hz**: receiver-side per-frame age is already local and fresher than any ctl report (law 16); the classifier runs on it directly.
- **HOLD forcing a local video shed**: deliberate — see decision 4.
- **HOLD_ENTER/HOLD_EXIT ctl messages** (§9 table lists them): implemented as local-only UI; by law 16 the peer's own classifier reaches the same state from fresher data.

## Residuals (honest)

- **Resume-probe granularity**: lane P at 1 fps fits through pipes that full video doesn't, so at bw 0.8 the machine sawtooths (~4 s held → resume → 1–3 s of >400 ms-late live video → re-shed). Bounded by dwell+minHold (~8 s cycle); a staged probe (ramp lpFps before resume) would fix it but is gold-plating for now.
- **HOLD is hard to reach**: striping+FEC audio survived 0.8 Mbps (53% of payload rate) at 6% concealment; HOLD needed 0.5 Mbps. The spec's "rare: requires <1.6 Mbps" assumed un-striped audio — reality is better than spec.
- **PCM sent at 80/1 wobbles** run-to-run (99.40–99.67%); A's final-code run sat exactly on the 99.4 bar.
- **Transition log capped at 12 entries** in the snapshot print; long held-dominant runs lose early history (full data remains in the run JSON events).
- **Repeated LANE_RESUME during a clean probe window** (up to 8 sent for one episode) — idempotent on the sender (wantKey dedupes), but noisy; a send-once latch would tidy it.
- No dependency on the two-human turn-taking gate was found anywhere in §12–13.

---

*Coordinator verification (2026-08-02): suites re-run green (tsc 0, turntaking 45/45, pcmrs ok); agent's run JSONs spot-checked against every claimed number (99.40/99.67 PCM, HOLD at 0.5 Mbps, flag-off zero tape-lanep); independent confirmation run stall-verify2 at RTT 80 / 1% / pairs=3 reproduced the bars — PCM 99.42% (A) / 99.63% (B), video admission 96%/98%, zero sheds, regime nominal both sides. A first confirmation run measured below bars (98.9% PCM, elevated ages) and was diagnosed as CPU contention from an un-gated DSP workload on the shared test machine — the mutex rule was extended to ALL heavy node runs; the contention run doubles as an accidental soak: the machine shed, painted stills, resumed, and held A-V sync with 0 drops while starved.*

---

## 17.20 The glass-to-glass scoreboard: self-view vs remote, with uncertainty bounds, and where the latency physically sits

Telemetry/testbed only. None of these numbers ever appear in the call UI.

## 0. The two legs

- **SELF-VIEW G2G** = (local presentation time of a self-preview frame) − (capture
  time of that same frame), one machine, one clock.
- **REMOTE-VIEW G2G** = (presentation time of a frame on B's screen) − (capture time
  of that frame on A), two machines, needs ONE shared clock.

"100% accuracy" is defined as: every reported number carries its own uncertainty
bound, and every bound is derived from a measured quantity in the same run — no
hand-waving.

## 1. Clock inventory (what exists today)

| clock | domain | who reads it |
|---|---|---|
| sender wall | `performance.timeOrigin + performance.now()` (ms) | tape.js/pcm.js `now()` |
| sender video capture clock | `VideoFrame.timestamp` (µs, media-pipeline base — NOT now()'s base; measured cap1, tape.js comment) | tape.js `pumpCapture` |
| sender audio hardware clock | `AudioContext.currentTime` (s) | pcm worklet, stamps `capUs` per 8 ms frame |
| receiver wall | same construction, other machine | receiver tape.js/pcm.js |
| receiver audio hardware clock | receiver's `AudioContext.currentTime` | playout worklet |
| DO session epoch | `session_epoch_us` (§17.14 part 1) | telemetry alignment only |

Existing mappings (all measured, all shipped):

1. **mco** — sender wall ↔ sender video capture clock: running MIN of
   `now() − frame.timestamp/1000` (tape.js `pumpCapture`). Biased high by `minQ`
   (the least-queued frame's camera-delivery queue depth): true base offset
   `o = mco − minQ`, `minQ ≥ 0` unknown. ~0 on the fake camera, ~1–3 ms on a real one.
2. **avd** — sender video capture clock ↔ sender audio clock: one reading per second
   on the `age` ctl message, EWMA'd at the receiver (τ ≈ 3 s). Error between refreshes
   ≤ 50 µs at 50 ppm drift. Negligible.
3. **TIME_SYNC (tsy/tsyr)** — wall ↔ wall, NTP 4-stamp at 5 Hz on the ctl channel,
   offset from the min-RTT sample in a 10 s window, drift fit in ppm
   (timesync.js). **Irreducible bound: |offset error| ≤ minRtt/2** (true offset lies
   anywhere in `[off − rtt/2, off + rtt/2]` for the min-RTT sample; min-filtering
   removes queueing, not path asymmetry). Loopback: ~±0.5–1 ms. RTT 80/1%: ~±41 ms.
4. **capUs chain** — the sender's audio clock end to end: capture worklet stamps
   `capUs` per frame (header offset 16); the playout worklet's ring is capUs-stamped
   and publishes `apUs` = sender-clock time of the sample under the playhead,
   seqlocked per render block. ±0.2% resample keeps the publish tracking the ear.
5. **outLat** — `AudioContext.outputLatency` at the receiver: playhead → ear.
   A Chrome estimate; treated as ±~10 ms unbounded systematic (stated, not fixed).
6. **pcm per-association ping/pong** — a second wall↔wall offset, NOT min-filtered:
   each sample uses its own rtt/2. Under queueing (80/1) it is contaminated:
   measured −7.6/+10.2 ms against TIME_SYNC's −0.1/−0.5 on the same run
   (stall-80-1b). Any field built on it (pcm `ageP50`) must be re-based onto the
   TIME_SYNC offset before use (§3.2).
7. **tape ctl ping/pong** — a third wall↔wall offset, EWMA'd. Agrees with TIME_SYNC
   to ~0.3 ms measured; used by `fullAgeMs`/`ageMs`.

## 2. SELF-VIEW: the chain and the verdict

### Chain

camera → Chrome capture pipeline → track delivery → `<video>` element (app.js
`$('self').srcObject = localStream`, line ~1256) → compositor → scanout.

### What exists today

Nothing on this path. The only self-track instrumentation is on the SEND side of the
same track (tape.js `pumpCapture`: `capLagMs` = capture-stamp → main-thread read,
relative to the running-min base). The preview element, its compositor path, and its
presentation times are uninstrumented. The app also defaults `view.selfview = false`
(§1.1: "no self view"), so in the shipping default there is no preview on screen at
all — the "self-view leg" is then, by definition, the platform pipeline
getUserMedia → `<video>` → screen, which the testbed can measure standalone without
touching the app (testbed/g2g-selfprobe.html, driven by g2g-probe.mjs).

`requestVideoFrameCallback` metadata on a camera-fed `<video>` provides, in this
Chromium (measured, both the fixture's fake camera and the machine's real camera):
`captureTime`, `expectedDisplayTime`, `presentationTime`, `mediaTime`,
`presentedFrames`, `width`, `height`. NB: the key is **`captureTime`**, not the
other spec spelling `captureTimestamp` — a probe that checks only the latter
reports a false negative (measured). With `captureTime` populated, self-view G2G
is a two-key subtraction on ONE clock — no cross-clock mapping at all:

    G2G_self(frame) = expectedDisplayTime − captureTime    [pixels ≈ ≤1 scanout later]

Measured standalone (g2g-selfprobe.html, same pipeline as the app's preview):
fake camera p50 27.1 / p95 27.9 ms (n=499, tight); real camera p50 44.1 /
p95 111.1 ms (tail is the macOS capture+compositor path; min −4.8 ms shows the
stamp's edge jitter — reported, not smoothed). `presentationTime − captureTime`
reads ~0.3 ms — presentationTime on a live stream tracks the media timeline, not
the display; expectedDisplayTime is the pixels estimate.

Fallback if a source ever omits `captureTime`: pair rVFC order with a
`MediaStreamTrackProcessor` reader on the same track (`VideoFrame.timestamp`,
media-clock base) — but that reintroduces the unknown base `o`, so it yields
excess-over-fastest-frame only, NOT absolute G2G.

### The one additive hook (QUEUED — NOT APPLIED; queues behind the stall machine)

File: `tape-app/public/app.js`, immediately after `$('self').srcObject = localStream;`
(~line 1256), gated on a new flag `?selfprobe=1` (flag off ⇒ byte-identical: no
callback is ever attached):

```js
// ?selfprobe=1 — testbed-only self-view glass-to-glass (task #29). Flag-off: nothing.
if (QS.get('selfprobe') === '1' && $('self')?.requestVideoFrameCallback) {
  const hist = [];
  $('self').requestVideoFrameCallback(function cb(_t, m) {
    const cap = m.captureTime ?? m.captureTimestamp; // Chromium spells it captureTime (measured)
    if (cap != null) hist.push(+(m.expectedDisplayTime - cap).toFixed(2));
    if (hist.length > 900) hist.shift();
    window.__selfG2G = { n: hist.length, capStamped: cap != null,
      p50: pct(hist, 50), p95: pct(hist, 95) };  // pct = the same local helper shape as tape.js
    $('self').requestVideoFrameCallback(cb);
  });
}
```

`window.__selfG2G` is harvested by the testbed's existing `page.evaluate` grab.
No UI surface, no wire bytes, no behaviour change when the flag is absent.

## 3. REMOTE-VIEW: the chain and the identity

### Chain

capture(A) → [capLag] → encode call → [encLat] → encoded chunk → [carrier/pacer +
SCTP + path + FEC/hold: tape `ageMs`] → arrival(B) → [hold/decode-queue residual]
→ decode output → [render queue: avq wait for the vsync nearest
`apUs + outLat + offset`] → canvas draw(B) → [compositor + scanout ≤ 1 vsync] →
pixels.

### The identity that makes it measurable today

At the present instant (receiver wall `t_p`), all on the SENDER's audio clock:

- `E` = `apUs + outLatUs` = capture-time (sender clock) of the audio sample at B's
  ear at `t_p` (the playhead publish — a physical mapping, not a clock estimate).
- `avUs` = capture time (sender clock) of the presented frame (frame.timestamp − avd).
- `applied` = `avUs − E` — logged per present as `avStats.offMs` → snapshot
  `avOffP50/P95` (tape.js `avTick`).
- `N` = sender audio clock's reading at `t_p`; `L_audio = N − E` = mouth-to-ear
  audio latency at the same instant.

Then, exactly:

    G2G_video(t_p) = N − avUs = (N − E) − (avUs − E) = L_audio − applied

`L_audio` composes from pcm.js's own snapshot fields, all existing:

    L_audio = ageP50(corrected) + depthMs + outputLatencyMs
              capture→arrival      ring wait    playhead→ear

so

    G2G_remote = pcm.ageP50(corr) + pcm.depthMs + pcm.outputLatencyMs − tape.avOffP50

The cross-machine clock enters ONCE, inside `ageP50`, via the pcm association's
ping offset — which §1.6 shows is queueing-contaminated under loss. Correction,
using the same tick's TIME_SYNC offset (both are "peer wall − our wall"):

    ageP50(corr) = ageP50 + (pcm.clockOffsetMs − timesync.offsetMs)

After correction the residual clock error is TIME_SYNC's own: **bound = rttMinMs/2
for that run** (±~0.5–1 ms loopback; ±~41 ms at RTT 80/1%). This bound is reported
alongside every remote number. The video lane's own offset agrees with TIME_SYNC to
~0.3 ms and is reported as a consistency cross-check, not used.

`avOffP50` needs no clock at all (both terms on the sender audio clock; avd refresh
error ≤ 50 µs). `depthMs`/`outputLatencyMs` are machine-local.

### What the identity excludes (stated brackets, added to every remote number)

1. **Compositor + scanout after the canvas draw**: the identity ends at draw;
   pixels follow within [0, ~1 vsync] = [0, 16.7] ms at 60 Hz. Reported as
   `+[0, 16.7]` on G2G.
2. **outLat systematic**: `AudioContext.outputLatency` is Chrome's estimate of DAC +
   driver depth. Unverified in this fixture (headless null sink reported 11 ms);
   carried as a stated ±10 ms systematic on L_audio-derived numbers only.
3. **Window slop**: `avOffP50`/`ageP50` are trailing ~900-sample windows sampled at
   the app's 2 s stats cadence; a percentile of windowed percentiles. Fine for a
   scoreboard; per-present exactness is queued hook #2 below.
4. **fullAge minQ bias**: affects only the decomposition's render-wait term
   (overstates render wait by minQ ≈ 0 fake / ~1–3 ms real cam), never G2G itself.

### Cross-check estimator (independent path through the video lane)

    G2G_x = fullAgeP50(corr) + max(0, L_audio − fullAgeP50(corr) − offsetMs) + vsync/2
    bracket: ± (vsync/2 + [0,16.7] compositor)

In the queue-binding regime (audio deeper than video, e.g. 80/1) this collapses to
`L_audio − offset + vsync/2` and must agree with the primary estimator within one
frame interval (it does: applied ≈ offset ± half-frame by construction of the
presenter). In the degenerate loopback regime it collapses to
`fullAge + [0, 2·vsync]`, which must bracket the primary estimator (it does:
measured 29.9 + [0,33.4] vs 60.5 on stall-loop2 — inside).

### Sanity check against existing runs (scorer dry-run on stall-loop2 / stall-80-1b)

- loopback: L_audio = 1.0 + 32.1 + 11 = 44.1; applied p50 −16.4 → G2G ≈ 60.5 ms
  (+[0,16.7] pixels bracket, ±0.5 ms clock).
- 80/1 (side B): age 42.7 + (10.18 − (−0.52)) = 53.4 corr; L_audio = 53.4 + 123.8 +
  11 = 188.2; applied 27.9 → G2G ≈ 160.3 ms (+[0,16.7], ±41 ms clock).
  Render wait (G2G − fullAge 69.8) ≈ 90 ms — the presenter holding video back
  against the §17.13-depth audio ring. The queue, not the network, is the biggest
  term in that regime.

### Decomposition reported per run (where the latency physically sits)

per direction, per tick: capture delivery (sender `capLagP50`) → encode
(sender `encLatP50`) → encode-out→arrival (receiver tape `ageP50`, re-based) →
arrival→decode-out residual (`fullAge(corr) − capLag − encLat − age(corr)`) →
render queue (`G2G − fullAge(corr)`) → compositor bracket. Sender terms are
machine-local p50s over the run; receiver terms from the same-tick series.

## 4. Queued additive hooks (specified, NOT applied — queue behind the stall machine)

1. **Self-view rVFC hook** (§2) — pins self-view G2G in-app. Without it: verdict
   "needs one hook"; the standalone platform number is the interim answer.
2. **Per-present remote G2G stamp** in tape.js `avTick`, flag `?g2gprobe=1`:
   at each present, push
   `((now() + stats.clockOffsetMs − peerMco) * 1000 − peerAvDeltaUs − avUs) / 1000`
   (ms) into a 900-ring surfaced as `g2gP50/P95` in `snapshot()`. This replaces the
   composed identity with a direct per-frame measurement on the lane-ping clock
   (bound: that ping's rtt/2), and removes window-of-percentiles slop. One-line
   sketch; flag-off byte-identical.
3. **presentLag under engagement**: the draw→vsync probe currently only runs on the
   paint-on-arrival branch; extending the same 6-line rAF probe into `avTick` would
   close bracket (1) above from [0,16.7] to a measurement. Flag `?g2gprobe=1`, same
   queue.

## 5. Regimes and honesty notes

- Loopback, one machine: both browsers share a crystal; TIME_SYNC spread measured
  0.14–1.2 ms; the minRtt/2 bound (~±0.5 ms) is nearly tight. outLat (headless null
  sink) is the largest self-view-side unknown.
- RTT 80/1% (p2psim): the ±41 ms clock bound swallows nothing — the signal is
  ~150–190 ms — but it is reported, not hidden. The simulated delay line is
  near-symmetric by construction (same oneWayMs both directions), so the TRUE
  offset error is likely ≪ minRtt/2; the bound stays because the probe must not
  assume the path.
- Composition-of-percentiles: p50(G2G series over 2 s ticks of windowed p50s) is
  reported as "typical G2G"; hook #2 is the per-frame answer.

## 6. Measured results (2026-08-02, this fixture)

Runs: `g2g-loop-bot-msat2wk4-sn3b` (loopback, `tape=2&pcmaudio=1`),
`g2g-80-1-bot-msat5yfd-dgil` (p2psim RTT 80 / 1%, same flags ⇒ pcmpairs=1),
`stall-80-1b-bot-msasemeu-z1ac` (80/1 with `pcmpairs=3`, the documented config,
re-scored from disk). Self-view: `runs/g2g-selfprobe-{fake,real}.json`.

| regime | SELF-VIEW p50 | REMOTE G2G p50 / p95 | clock bound | gap p50 |
|---|---|---|---|---|
| loopback A→B | 27.1 ms (fake cam) | 58.8 / 78.3 ms | ±0.35 ms | +31.7 ms |
| loopback B→A | 27.1 ms | 55.7 / 70.9 ms | ±0.45 ms | +28.6 ms |
| 80/1 pairs=1 A→B | 27.1 ms | 122.4 / 228.6 ms | ±42.3 ms | +95.3 ms |
| 80/1 pairs=1 B→A | 27.1 ms | 144.5 / 319.7 ms | ±43.0 ms | +117.4 ms |
| 80/1 pairs=3 A→B (ref) | 27.1 ms | 143.8 / 182.2 ms | ±40.9 ms | +116.7 ms |
| 80/1 pairs=3 B→A (ref) | 27.1 ms | 139.5 / 162.5 ms | ±40.8 ms | +112.4 ms |

All remote numbers additionally carry `+[0, 16.7] ms` compositor/scanout bracket
and the stated ±10 ms outLat systematic (Chrome's estimate, 11 ms reported).
Self-view real camera: p50 44.1 / p95 111.1 ms.

Decomposition (settled medians, ms):

| regime | capture | encode | transport | hold+decode | render queue | biggest term |
|---|---|---|---|---|---|---|
| loopback A→B | 0.1 | 6.3 | 21.5 | 1.4 | 24.8 | render queue |
| loopback B→A | 0.1 | 6.4 | 21.8 | 2.5 | 20.3 | transport |
| 80/1 p1 A→B | 0.1 | 6.4 | 64.7 | 1.2 | 51.9 | transport |
| 80/1 p1 B→A | 0.1 | 6.6 | 61.1 | 1.2 | 74.5 | render queue |
| 80/1 p3 A→B (ref) | 0.1 | 6.1 | 62.5 | 1.2 | 75.3 | render queue |
| 80/1 p3 B→A (ref) | 0 | 6.2 | 64.2 | 1.3 | 70.4 | render queue |

The 80/1 pairs=1 run is the §17.12 wall live: drop(link) 5472/13199 (41%),
concealed 54–60 s, pcm age p50 85–121 ms (settled median 85–87, run tail
101–121), latest ping rtt 437–563 vs baseRtt 86–93.
The G2G p50s stay ~120–145 anyway (the presenter holds video to the audio
schedule whatever it costs) — the wall shows in the p95 (228–320 vs 162–182
with pairs=3). The pcm-offset contamination the rebase exists for read
−11.8/−5.4 ms median in this run; with pairs=3 it read ~0.

Where the latency physically sits:

- Loopback: transport = the 30 fps carrier tick pacing (~22 ms ≈ ⅔ tick), render
  queue = the degenerate presenter's 1–1.5 vsync wait (~20–25 ms). Encode 6.4,
  capture 0.1, hold+decode ~1.5. The ~30 ms gap over self-view = carrier pacing +
  encode + decode + render excess — the preview path has none of the first three.
- 80/1: the path RTT lives in transport (~62–65 ms of the ~80), and the audio
  ring's §17.13 depth (measured pcm depthMs medians: 70–99 ms with pcmpairs=1,
  119–120 ms with pcmpairs=3) is what the render queue (~52–75 ms) is waiting
  on. Biggest single lever for the gap: the render-queue/audio-depth coupling,
  i.e. how deep Lane A is willing to sit before Lane B need not wait.

Fixture notes: loopback run took the documented both-browsers startup stall
(drop(link) 458, concealed 3768 ms — excluded by the settled-tick filter); one
`/api/ice` 429 (rate-limited under multi-agent load; browsers recovered,
connected in 998 ms). TIME_SYNC at 80/1 found minRtt 86–87 through the queueing
against the 80 ms line. Headless-fixture caveat: the self-probe measured rVFC
cadence of 50 ms (fake cam) / 66 ms (real cam) — headless BeginFrame throttling,
not a 60 Hz scanout. The `+[0,16.7]` compositor bracket is the real-60 Hz-display
statement; on the headless fixture the true post-draw bracket is [0, vsync]
with vsync up to ~66 ms (there is no physical scanout headless; the number is
a draw-schedule statement).

---

## 17.21 AEC v2 kernel: 20 dB gate met — 41.6–79.8 dB ERLE, onset-honest, linear-only

Kernel `core/aec.js`, suite `core/aec.test.mjs`, fixtures `testbed/aec-fixtures.mjs`.
All runs CPU-only under node, heavy runs gated behind the coordinator mutex.
Gate command (corrected after the loose `pgrep -f` form was found to
false-positive on wrapper shells whose command text embeds the pattern):
`ps -eo comm,args | awk '$1=="node" && $2 ~ /(call|cadence-call|sctpwall|corpus-score|g2g-probe)\.mjs/ {found=1} END{exit !found}'`
— loop until it exits non-zero (quiet). Final suite re-validated 45/45 under
this gate.

**Suite: 45/45. Gate: ERLE ≥ 20 dB steady-state on every fixture — MET.
`core/onset.test.mjs` 69/69 and `tape-app/turntaking.test.mjs` 45/45 unchanged
and green. No existing file touched; no .ts touched (no tsc needed).**

## API (as documented in the file header)

```js
import { Aec } from './core/aec.js';          // tape-app/public/core symlinks core/
const aec = new Aec({ sampleRate, block, partitions, maxDelay = 8192, mu });
aec.pushReference(samples);                   // far-end, as played, 128-sample blocks
const { erleDb, dtFlag } = aec.process(mic, out, { delaySamples: D });
aec.alignmentScan(micBlock, { center, halfWidth }) // → { lag, score, samples }
aec.resetAlignmentScan();
aec.stats                                     // { erleDb, dtFrac, delaySamples, adapted, refActive }
```

- Reference and mic are both 48 kHz mono Float32, pushed/processed in 128-sample
  blocks (the AudioWorklet quantum). `pushReference` is decoupled from `process`
  so the worklet can queue render-side audio independently of capture.
- `delaySamples` is the caller's current D estimate (D = outputLatency +
  inputLatency + acoustic delay, design §2.2); changes are accepted at any block
  and handled internally: spectrum ring refill + anchor restore (converged case)
  or clean restart (bootstrap case). The filter tail absorbs ±1 ms of wander;
  the tracker moves the bulk hint.
- `alignmentScan` is the bootstrap/tracker primitive: accumulating
  cross-correlation with per-lag reference energies (true normalized score).
  Callers must accumulate → evaluate → reset in cycles, vote for stability, and
  gate on ERLE (speech pitch self-correlation rivals the echo peak; the only
  robust gate is "don't scan when already aligned"). `testbed/aec-fixtures.mjs`'s
  `Tracker` class is the reference driver the worklet port will be tested
  against.

## Algorithm (all linear — no gain ducking ever, tell-8 law)

- MDF: 32 partitions × 128 = 4096 taps (85 ms tail @ 48 kHz), N=256 FFT,
  overlap-save, per-bin normalized gradient, step μ=1.0, rotating gradient
  constraint (4 partitions/block).
- Attack/release per-bin reference-power normalizer (instant attack, release
  0.05/block). A symmetric smoother lags syllable onsets, overshoots the
  normalized step, and collapses ERLE mid-convergence (measured −9 dB).
- Estimate-referenced double-talk freeze (NOT raw-reference Geigel — structurally
  broken at −6 dB echo, measured dtFrac 0.7–1.0 in pure single-talk):
  `pMic > 4·yPowSm` or `dMax ≥ 2·yPkSm`, both attack/release tracked, armed only
  once `adapted`, 24-block hangover. A residual-ratio third test was tried and
  REMOVED: it deadlocks re-convergence after any echo-path step.
- Two-path: background adapts, foreground produces output; copy bg→fg on a
  proven 6 dB win / revert fg→bg on a proven 6 dB loss over 48-block clean
  windows.
- Anchor: foreground snapshot when erleEwma > 25 (≤1 per 375 blocks); restored
  into both filters on hint moves (taps are hint-relative). Without a valid
  anchor a hint move ZEROES both filters and restarts (measured: keeping
  old-alignment weights drives ERLE negative and the estimate-referenced DTD
  deadlocks adaptation for seconds; a clean restart reconverges in ~400 ms).

### μ = 1.0 — chosen on measurement

μ=0.75 was built first ("misadjustment margin") and rejected: the synthetic
speech f0 wanders ±25 Hz, harmonics cross bins every syllable, and 0.75 cannot
track within a syllable — per-syllable residual sat ~15 dB with pops 6–11 dB
over the room-tone floor that FIRED the onset detector on echo alone. At μ=1.0
(exact per-block projection) pops drop below the floor and steady ERLE gains
12–40 dB. μ=1.25 is oscillatory and worse. Sweep:

| μ | conv 15ms/−12 | steady 15ms/−12 | post-conv echo onsets | max pop |
|---|---|---|---|---|
| 0.75 | 450 ms | 37.6 dB | 3 | −50.7 dBFS |
| 1.00 | 300 ms | 61.6 dB | 0 | −59.0 dBFS |
| 1.25 | 450 ms | 43.5 dB | 2 | −51.3 dBFS |

## Gate numbers per fixture (suite output, verbatim)

Convergence matrix (single-tap path, 3 s speech, hint = planted D;
bars: 20 dB by 1500 ms + steady ≥ 20):

| delay \ echo | −6 dB | −12 dB | −20 dB |
|---|---|---|---|
| 5 ms | 300 ms / 79.8 dB | 300 ms / 77.1 dB | 350 ms / 71.4 dB |
| 15 ms | 200 ms / 59.9 dB | 300 ms / 61.6 dB | 350 ms / 64.9 dB |
| 30 ms | 300 ms / 41.6 dB | 350 ms / 42.7 dB | 350 ms / 45.7 dB |
| 60 ms | 250 ms / 47.9 dB | 350 ms / 48.3 dB | 400 ms / 50.2 dB |

Structured paths (15 ms / −12 dB): two-tap (+8 ms @ −6 dB) conv 450 ms, steady
30.7 dB; reverb RT60≈150 ms conv 1650 ms, steady 22.7 dB (see residuals).

Re-convergence (bar: ≥15 dB within 400 ms): gain ×0.5 with hint fixed — 400 ms;
delay +8 ms with tracker — recovered 400 ms, tracker moved at 325 ms to 1104
(true 1104, exact), steady 63.4 dB.

Double-talk (near speech t=3–5 s over continuing echo; bars: |damage| ≤ 1 dB,
post-ERLE within 3 dB of pre):

| echo | near-end damage | ERLE pre → post | DTD held |
|---|---|---|---|
| −6 dB | −0.00 dB | 59.9 → 67.9 dB | 61% |
| −12 dB | −0.00 dB | 61.6 → 68.9 dB | 75% |
| −20 dB | −0.00 dB | 64.9 → 71.0 dB | 83% |

Silence: reference-silent cold start → output bit-exact = mic; mic-silent
post-convergence residual −55.0 dBFS (bar ≤ −40).

Alignment scan (1 s accumulation, room tone in mic, bar ±8 samples): err 0 at
all 12 delay×level cells; score 1.00 (−6/−12 dB), 0.97 (−20 dB).

Bootstrap (hint 0, true D = 30 ms, no calibration): tracker locks at 192 ms
(block 72, score 0.99, err 0); ERLE ≥ 20 dB by 1800 ms of cold start (bar
2000); steady 38.8 dB.

Onset honesty (post-AEC through the SHIPPING detectors):
- echo-only (far-end speech into quiet room): ZERO local onsets and ZERO
  turn-end predicts after convergence (also zero pre-convergence at μ=1.0).
- genuine near-end breath+voiced at t=4 s over continuing echo: onset survives,
  timing error vs no-echo control 0.0 ms (bar ±10), breath head start 256 ms vs
  control 256 ms (bar ±10%).
- turn-end score stream on a near-end utterance: 434 scored frames in common
  with the no-echo control, max |Δprob| 0.014 (bar 0.1), predict counts 0/0.
  NOTE: the shipped model does not fire on the synthetic fall (max prob 0.61 <
  THRESH 0.65 — measured, real falls differ from the read-speech model), so the
  transparency bar is on the score stream, not on fired events.

## Honest residuals / accepted prices

1. **Near-noise misadjustment floor ≈ 19 dB.** With −63 dBFS room tone as the
   only near-end, steady ERLE caps at ≈19 dB for any delay (5/15/30/60 ms
   measured) — that is the μ=1 NLMS excess-MSE floor for 4096 taps, not a
   tracking failure (|W| grows ~25% past the true filter's norm — noise energy
   in weakly-excited bins). Pure-echo fixtures reach 40–80 dB. The onset-honesty
   fixtures pass because 19 dB ERLE puts the residual (−59 dBFS) under the
   detector's trigger above the room-tone floor. Mitigation if the floor ever
   matters: two-speed μ (drop to ~0.25 once erleEwma > 20, restore on
   anchor-restore / ERLE crash). NOT built — the re-convergence bar (400 ms)
   needs μ=1 and the switching logic adds exactly the kind of statefulness that
   bit us three times this task. Flagged for step 3+.
2. **Residual echo rises during double-talk (design §5.2's accepted price).**
   The DTD holds adaptation 61–83% of the overlap (by echo level); while held,
   a changing room would leak. Measured here: static room → damage −0.00 dB and
   ERLE actually IMPROVES across the overlap (post > pre by 6–8 dB: the
   hangover releases into clean single-talk and the background keeps learning).
   The price is real only when the room changes DURING overlap — accepted, never
   paid for with ducking.
3. **Reverb tail is excitation-limited.** Direct tap cancels in ~400 ms, but
   the stochastic 90 ms tail (~3600 taps inside the filter) learns only as fast
   as speech excites bins: conv 1650 ms (bar: the task's 2000 ms; the design's
   1500 ms matrix bar does not extend to tails), steady 22.7 dB — measured
   22–26 dB for ANY tail length 60–90 ms, i.e. the honest speech-driven limit,
   3–6 dB over the 20 dB gate. White-noise excitation would converge the same
   tail in ~700 ms (μ=1.0 reaches the float32 floor on white noise — the kernel
   is not the limit; speech bandwidth is).
4. **Pre-convergence window.** The first ~200–400 ms carry unconverged echo;
   at μ=1.0 no onsets fired even there on these fixtures, but the app-level
   discipline stands: suppress Lane-B yields while `!aec.stats.adapted`.
5. **Bootstrap convergence 1800 ms** is tracker lock (192 ms) + clean-restart
   convergence through the two-path copy latency (48-block prove-it windows on
   60%-duty speech). Under the 2000 ms gate with 10% margin — watch it if the
   duty cycle of the fixture speech changes.
6. **TurnEnd predictor transparency was measured on the score stream**, not on
   fired predicts — the synthetic terminal fall does not cross the shipped
   model's 0.65 threshold (max 0.61). If the model is ever retrained to fire on
   these fixtures, the suite's predict-count equality check becomes load-bearing
   as written.

## Convergence curves, summarized

Single-tap cells: ERLE crosses 20 dB at 200–400 ms (windowed, 50 ms), rises
steeply to 35–50 dB by ~1 s, then grinds toward the float32/noise floor
(41–80 dB at 3 s, louder echo = deeper absolute floor). Two-tap tracks the
matrix with ~100 ms extra. Reverb: ~400 ms for the direct path, then a long
tail-learning slope to 20 dB at 1650 ms. Path steps: 300–400 ms to ≥15 dB with
the tracker moving the hint at ~250–370 ms after an 8 ms delay jump (anchor
restore makes the first post-move window already ≥15 dB).

---

*Coordinator verification (2026-08-02): suites re-run green — aec 45/45, onset 69/69, turntaking 45/45; kernel 695 lines + 389-line suite; no existing file touched. The μ=1.0 finding is the one that protects Lane 0: at μ=0.75 the residual echo's syllable-rate pops fired the shipping onset detector on echo alone (3 false onsets / 4 s) — the onset-honesty cross-tests caught what an ERLE-only suite would have shipped.*

---

## 17.22 Self-view lobby, zero-stats UI, aspect matrix (#28)

Date: 2026-08-02. Files touched: `tape-app/public/index.html`, `tape-app/public/app.js` only.
**tape.js, pcm.js, worklets, core/, worker untouched** (no stallforce gate needed).
**Deployed 2026-08-02** (tape-app version `0c9563e3`); `index.html` and `app.js` verified
byte-identical to https://room.tokkah.com after the push.

## What changed (file:line)

### index.html
- **Lobby preview is now the full-screen self view** (`#previewWrap` → `position: fixed; inset: 0`,
  `object-fit: cover`, `scaleX(-1)` mirror — the same preserve-aspect fullscreen treatment as the
  remote view). The join panel floats over it on a translucent scrim (`backdrop-filter`).
  Markup moved OUT of `.panel` (panel's backdrop-filter would become the containing block for the
  fixed video) and `.panel` got `position: relative; z-index: 1` (a positioned z-0 video would
  otherwise paint over the in-flow panel).
- **New `<video id="selfFull">`** in `#call` — the post-join waiting-state self view. Same CSS
  treatment: `inset 0`, `object-fit: cover`, mirrored, z-index 1 (above `#remoteWrap` z-0, below
  `#waiting` z-2 / controls).
- `#waiting` overlay: radial scrim + text-shadow so it reads over live video.
- `#bar`: `flex-wrap: wrap` (phone-portrait overflow fix — mic/cam/chips/save/leave exceeded 390 px).
- `#status` pill: fades (`opacity`, text kept in DOM for tests) 3 s after "connected" — the default
  UI ends as a face and nothing else.
- Chip defaults corrected to match app state (`c-lifesize` 0, `c-hud` 0).

### app.js
- `STATS_UI = ?stats=1` (app.js:55ish): `view.hud` defaults to it; when off, the `c-hud` chip is
  `display:none` — no way to surface stats in the default UI at all. Telemetry/logging untouched.
- `peerArrived()` helper: hides `#selfFull` + `#waiting`, enables the corner PiP (`view.selfview =
  true`, skipped when video is degraded). Called from both `ontrack` branches (PCM and stock).
- `setStatus(t)`: one place for the status pill; auto-fades "connected".
- `join()`: on call-screen entry, `#selfFull.srcObject = localStream` + `.on` (skipped when
  videoDegraded) — own camera fills the screen until the peer's first track.
- `peer-left`: back to the self-view lobby (`#waiting` re-shown, `#selfFull` back on).
- Lobby `previewBadge`: "1280×720 @ 30" stat readout removed → "camera ready" (degraded-camera and
  blocked-camera action messages kept — status, not stats).

## Stats audit (what was removed/gated)
- **#hud** (RTT, playout buffer, resolution/fps, send Mbps, freezes, glitches, turn-taking ms,
  log health): previously DEFAULT ON → now gated behind `?stats=1`, chip hidden without the flag.
  Verified: with the flag, chip visible + HUD opens (`STATS FLAG OK` run); without it, DOM scan
  finds nothing.
- **previewBadge** resolution/fps readout: removed (see above).
- Kept (status, not stats — per mission exception): stall badges (`stallUi()` untouched), `#status`
  pill (auto-fading), `#floorHint` loud-room honesty, speaking dots, degraded-camera messages.
- Lobby `?stats=1` has no effect on telemetry — logging identical either way.

## Handoff behavior
pre-join: full-screen mirrored self view behind the join panel → join: same full-screen self view
in-call with waiting overlay + share link → peer's first track: remote takes the screen, self view
becomes a static 132 px corner PiP (chip-toggleable) → peer-left: back to full-screen self view +
waiting overlay. Asserted in the two-browser matrix run (incl. the peer-left return).

## Aspect matrix (testbed/ui-call.mjs, lane 2 + PCM, canvas display path)
Assertions per ratio × state: element rect == viewport, `object-fit: cover`, intrinsic aspect ==
camera aspect (±3–4%), self views mirrored (`matrix(-1`), PiP fully on-screen with camera aspect,
no overflow-x, zero stat-like visible text (DOM scan).

| viewport | lobby self view | waiting selfFull | in-call remote (A+B) | PiP | stats scan |
|---|---|---|---|---|---|
| 1600×900 (16:9) | cover, aspect ok, mirrored | cover, aspect ok, mirrored | canvas covers, aspect ok | 132×75 on-screen | clean |
| 390×844 (9:19.5) | cover, aspect ok, mirrored | cover, aspect ok, mirrored | canvas covers, aspect ok | 132×75 on-screen | clean |
| 2100×900 (21:9) | cover, aspect ok, mirrored | cover, aspect ok, mirrored | canvas covers, aspect ok | 132×75 on-screen | clean |
| 1024×768 (4:3) | cover, aspect ok, mirrored | cover, aspect ok, mirrored | canvas covers, aspect ok | 132×75 on-screen | clean |
| 800×800 (square) | cover, aspect ok, mirrored | cover, aspect ok, mirrored | canvas covers, aspect ok | 132×75 on-screen | clean |

**ALL PASS** (0 failures), plus peer-left return asserted on the square ratio.
Screenshots: `scratchpad/ui-shots/{ratio}-{1-lobby,2-waiting,3-incall-A,3-incall-B}.png` +
`square-4-peerleft-A.png`.

## Gates
- (a) layout matrix: PASS all 5 ratios × {lobby, waiting, in-call} (above)
- (b) zero stats default UI: PASS (DOM scan every state; HUD+chip gated behind `?stats=1`, flag verified working)
- (c) self-view pre-join + handoff on peer-joined: PASS (two-browser run)
- (d) regressions: turntaking 45/45, pcmrs ok, onset 69/69, tsc 0 — all green
- (e) loopback lanes (`call.mjs --q='tape=2&pcmaudio=1'`): PASS — run `ui-lanes90-bot-msatfavb-4zm7`
  (90 s loopback): video admission A 96% (1724/1801) / B 97% (1738/1800), PCM sent A 99.5%
  (11258/11310) / B 99.98% (11257/11259), 0 lost frames, 0 keyReqs, 0 decodeErr, stall regime
  nominal both sides. (A 45 s run first read 94% — the AIMD governor's fixed 5→34 fps startup
  ramp is ~52 skipped frames regardless of run length; the 90 s run dilutes it past the bar.)
- (f) stallforce: N/A — tape.js untouched


---

*Coordinator verification 2026-08-02: suites re-run independently on the merged tree — tsc 0, onset 69/69, turntaking 45/45, pcmrs ok; screenshots inspected (phone waiting = full-screen self view, zero stats; desktop in-call = remote-fullscreen + corner PiP); `STATS_UI` gate confirmed at app.js:58/1848 (chip hidden without `?stats=1`, DOM-scan clean); loopback lane numbers spot-checked against run `ui-lanes90-bot-msatfavb-4zm7`. Deployed in version 35118ff8 (train: #22 stall + #32 hardening + #28 UI), prod headers + served app.js/tape.js verified byte-identical to the working tree post-deploy.*

## 17.27 Skew-aware striping — the control plane rode the lane it was reporting on (2026-08-18)

Skew-aware striping is worth **35 ms of mouth-to-ear** under realistic route divergence (§ the Stage 2
table: m2e 104/115.6 vs 149.3/140.7 at 24 ms divergence) — the largest measured latency lever in the
project, larger than everything in our own 44 ms budget put together. It has stayed behind
`?pcmskewstripe=1` because of one scenario: three of six routes stalled by +5000 ms quadrupled
concealment.

### First, a correction to the obvious reading

Both sides demote lanes roughly 30 s **before** the fault is injected, which looks like the bug and is
not. This scenario's network carries 24 ms of built-in per-lane divergence, the two directions traverse
different proxies, and each side demoted exactly the lanes its peer reported slow. Nothing is wrong at
t=30. I recorded the opposite on first read; the trace is what corrected it.

### A hypothesis, built and disproved

The MIN_FAST floor ranked rescue candidates by their **current** reported lateness — and a demoted lane
carries no audio, so the peer measures no frames on it and reports zero within seconds. A route stalled
by five seconds therefore ties at `late 0` with lanes that are merely slow and gets drafted straight
back: the lane's own condemnation erasing the evidence for it. `laneLateDemoted` already records the
verdict and is already trusted to block the skew release path for exactly this reason, so the floor now
uses it too.

**Measured: no change.** 928 → 956 ms. Kept — the reasoning holds and it is inert unless
`?pcmlatedemote=1` — but it is not the fix, and building it on two samples taken 25 s apart was the
actual mistake. The rig now traces both sides once a second through the whole stall window.

### What the trace found

```
t+1s   A n4[1235]     conceal 1936
t+2s   A n4[1235]     conceal 2616      the peer has moved off the bad lanes
t+3s   A n6[012345] STALE1              peerSkewAt stale >2 s -> FAIL-OPEN
t+4s   A n4[1235]   DEAD2 STALE1        ...and back off them again
```

`sendSkewReport()` sent on **one** association — `assocs[0]`, or the first open one. The ping and the
loss report both already loop over every open association, and `sendPing`'s own comment gives the
reason: *the report that matters most is the one from the link that is losing packets, and that is
precisely the link most likely to drop it.* The skew report is the one control message that never got
that rule, and it is the one carrying the lane-health verdict.

Lane 0 is one of the stalled routes here, so the instant the fault landed **the control plane went into
the five-second hole with it.** The peer's evidence went stale, it fail-opened to all six lanes — correct
behaviour on stale evidence, and also, here, posting audio straight back into routes just demoted for
being unusable.

**A lane-health signal that cannot be delivered by an unhealthy lane reports on every lane except the
ones worth reporting on.**

Fanned out to every open association (15 B at 4/s × 6 = 360 B/s against ~0.92 Mbps lanes; copies within
a tick are identical, so duplicates are idempotent):

| | before | after |
|---|---:|---:|
| fail-opens through the stall window | 23 | **0** |
| ON conceal delta | 956 ms | **748** |
| OFF conceal delta | 416 ms | 444 |
| the scenario's own assertion | FAIL | **PASS** |

### Why that is still not enough to flip the default

The same trace says so. Concealment lands almost entirely in the **first two seconds** and is flat for
the remaining twenty-three, in both arms — before any detector could have reacted. That residual is
structural rather than a tuning problem: with three of six lanes carrying everything, a fault taking two
of them removes **67% of capacity at once**, while the control arm spreads over six, loses 33%, and FEC
repairs most of it. No detection speed recovers audio already in flight down a five-second hole.

**The design answer that follows: stop demoting to ZERO.** A demoted lane keeping a small share stays
measurable — the "acting on the signal erases the signal" trap, which has now bitten this one file three
separate ways (skew after demotion, latePct after demotion, and the MIN_FAST ranking above) — and stays
as capacity insurance against exactly this fault. Its arrivals would need to be excluded from the spread
estimator, or the slow lane it is insuring against would inflate the jitter target it was demoted to
protect. Scoped, not built.

---

## 17.26 The filter under LIVE rate control — the same picture on a third of the link (2026-08-18, task #2)

§17.25 priced the presence filter with the quantizer **pinned**: 61.5% fewer bits at QP 24. Pinning is
the right way to price a filter — it holds quality fixed so the bits are free to move — but it is not
how the product runs, and the shipping combination (filter + live rate controller + resolution
actuator) was the one combination never tested. Testing it produced two results, and the first looks
like a refutation until you notice which instrument is being read.

**Under rate control the saving does not appear as bits.** `testbed/pfrc.mjs`, prod, budget clamped at
1.5 Mbps, three cycles, arms rotated: **1.23 Mbps with the filter off, 1.21 with it on.** Under two
percent. That is correct behaviour, not a null result — the controller targets a *bitrate*, so a
cheaper picture cannot spend fewer bits; it spends the same bits at a **lower quantizer**. The rig
recorded `rcQp` and never compared it, which is exactly how a working filter reads as a no-op. It
compares it now. Its "the filter buys back resolution" check also no longer prints PASS when neither
arm ever left /1: a question the run did not put to the system has no answer, and grading that green
is the blind rig this project has already shipped a defect through.

**So measure where the picture is forced to get worse.** `testbed/pffloor.mjs` walks the video budget
down a ladder **inside one call**, arms rotated, two real browsers on room.tokkah.com. Inside one call
matters: `l2rcmin`/`l2rcmax` were query-string only, so a ladder meant one page load — one whole call,
fresh ICE, a fresh point in the 90 s fixture loop — per rung, and the quantity being compared is a few
percent, which is smaller than the spread between two calls. The budget band is now a live lab knob
(`rcMin`/`rcMax` on `handleLab`'s whitelist; `rcPollBudget` re-reads both bounds every second).

**And on the sensor-like fixture, under the live controller, the same ladder reads:**

| budget 20 Mbps, both arms at QP 24 | video | + audio | = call |
|---|---:|---:|---:|
| filter off | 7.97 Mbps | 0.56 | **8.53 Mbps** |
| filter on | **0.93 Mbps** | 0.56 | **1.49 Mbps** |
| | **−88%** | | −83% |

The filtered arm holds QP 24 all the way down to the 3 Mbps rung and 24.2 at 1.4, where the control is
at 29.9. And below that the sign of the grain column **flips**: at 0.7 and 0.35 Mbps the filtered
picture carries *more* high-frequency energy than the control, because the control is being blurred by
its own quantizer and the filtered one is not.

**At the top rung neither arm is squeezed, both sit at the quantizer floor — identical quality by
construction — and the bits are therefore directly comparable:**

| budget 8 Mbps, both arms at QP 24 | video | + audio | = call |
|---|---:|---:|---:|
| filter off | 3.05 Mbps | 0.59 | **3.64 Mbps** |
| filter on | **1.06 Mbps** | 0.59 | **1.65 Mbps** |
| | **−65%** | | −55% |

That reproduces §17.25's pinned-QP 61.5% by a completely different route — the controller arriving at
the pin by itself — and it is the plain statement of what the filter is worth: **the same picture on a
third of the link.** Note what the audio column now says: at a filtered video rate near 1 Mbps,
uncompressed Lane A is **36% of the call**, and the next Mbps to find is there rather than in the video.

Squeezed, the same saving arrives as quality instead (2 cycles, both sides, arms rotated):

| budget | Mbps off → on | QP off → on |
|---:|---|---|
| 8 | 3.05 → 1.06 | 24.0 → 24.0 (both at the floor) |
| 3 | 2.40 → 0.93 | 26.6 → 24.0 |
| 1.4 | 1.13 → 1.06 | **29.9 → 24.1** |
| 0.7 | 0.59 → 0.61 | 32.5 → 28.0 |
| 0.35 | 0.31 → 0.32 | 35.9 → 32.8 |
| 0.18 | 0.16 → 0.15 | 38.8 → 36.5 |

Six QP is a factor of two in bits, so the 1.4 Mbps row reads: **at 1.4 Mbps the filtered call is already
at the best quality the band allows, and the unfiltered one would need roughly 2.8 Mbps to get there.**
5 rungs better, 0 worse, 30 fps at every rung, 0 frames declined.

**The coupling defect the rig was built to find does not happen.** With the actuator live: 0 divisor
changes per 20 s window in either arm, 0 declines across resolution changes, 87% of the picture still
locked while resolution was moving. The filter's lock lives in a feedback texture sized to the frame
and the actuator's whole job is resizing frames; they do not fight.

**The pipeline holds full resolution and 30 fps down to 0.1 Mbps** on this fixture, losing /1 only at
0.06. Both arms lose it at the same rung — by then both are pinned at QP 42 and there is nothing left
to give — so the filter does not move the *pixel* floor. The floors are not where it earns; the
quantizer column is.

The one honest cost: the filter-on arm's worst rung reads **28.9 fps against the filter-off arm's 29.8**.
The GPU pass costs a visible fraction of a frame at the top of the ladder, where frames are largest.

### Measuring "not paid for with a softer picture" — three metrics, two of them wrong

- **The probe was eating the thing it measured.** Reading back a full 1280×720 frame and sorting 920k
  Laplacian magnitudes, six times a rung, on the same main thread that decodes and paints: fps read
  26.6 and 28.0 where every other run of that call reads 30.0. Now a native-scale 512² crop (not a
  downscale — a bilinear shrink is itself a low-pass filter and would hide exactly the blur being
  looked for) and a 256-bin histogram instead of a sort. 3.6 ms per grab, and the rig asserts the cost
  and the frame rate rather than trusting them.
- **Top-decile edge energy scores grain removal as damage.** Its threshold is set by the distribution
  itself, so removing a broadband noise floor moves the threshold, changes which pixels are in the
  tail, and drags the number down on its own. It read −4.3% at the 8 Mbps rung, where the stills show
  identical nameplate lettering and identical badge stitching beside visibly smoother fabric.
- **A fixed |Laplacian| > 48 cut is better and still not clean** — grain sits on top of real edges and
  pushes borderline ones over any fixed cut. And the deadband was guessed. Measured properly, the
  **same arm** at the **same rung** in two different cycles moves this statistic by 0.2–4.1% at ordinary
  rungs and 20.3% at the bottom. The bar is now that measured spread, not a number I chose.

**The bar is now calibrated against a real blur.** `--soften=1` turns on the one lever that provably
destroys detail the camera saw, and run deliberately it costs the strong-edge fraction **−69.0% and
−70.1%**. The shipping configuration costs 5–9%. An order of magnitude apart, so a 25% line is one
neither can reach by accident — and the rig can honestly certify "nothing was grossly softened" while
declining to adjudicate the 5–9%. Three calibration points, all behaving:

| arm | strong edges | total energy | verdict |
|---|---:|---:|---|
| shipping, clean fixture | −4.8% | −6.1% | PASS, ratio silent — nothing substantial was removed |
| shipping, grain fixture | −5.2% | −27.2% | PASS, **3.2× — the signature of noise removal** |
| `--soften=1` | **−69%** | −32.7% | **FAIL, 0.4× — the signature of blur** |

That last column is the discriminator: blur drags edges down *faster* than total energy, removing noise
does the opposite. It is gated on total energy having moved at least 15%, because ungated it called
BLUR on the clean fixture's shipping arm at a ratio of 0.7 — two small numbers whose quotient means
nothing, beside stills showing crisp nameplate lettering next to a `soften=1` arm that has visibly lost
it.

**Persistence was tried as the adjudicator and does not work.** Structure — lettering, a seam, the edge of a chair —
sits in the same pixels frame after frame; grain does not. The idea was sound — structure sits in the same
pixels frame after frame and grain does not, so averaging the window should leave structure alone.
Built and measured: on moving footage its own cycle-to-cycle spread is **40–105%**, because what it
actually measures is how much the subject happened to move in that window. Removed. A statistic
noisier than its effect is worse than none, because it will either be ignored or believed.

### What this does not license

Every number above is on `realA/realB.mjpeg` — twice-compressed NASA interview footage, and compression
is a denoiser. Measured on the filter's own motion statistic, **92.7% of that fixture's picture already
sits below the lock threshold**: the hold is being handed a picture that is nearly static already.
`testbed/media/real/grain.sh` builds the stress case (temporal grain plus a ±10/255 auto-exposure hunt
on a 25 s period, at MJPEG q2 so the grain survives to the filter), and on the same statistic it takes
the lockable fraction from 92.7% down to **61.5%**.

**It earns more there, not less.** `testbed/pfhold.mjs --media=grain`, prod, quantizer pinned at 24
both arms, 3 cycles inside one call:

| | clean fixture | sensor-like fixture |
|---|---:|---:|
| filter off | 3.42 Mbps | **8.97 Mbps** |
| denoise + hold | 1.12 | **1.25** |
| cut | 61.5% | **86.1%** |

The prediction was that a real sensor gives denoise more to remove, and this is that prediction
surviving a test that could have killed it. The sharpest form of it is the middle row: the *unfiltered*
cost nearly triples with grain while the *filtered* cost barely moves — 1.12 → 1.25 Mbps. **The filter's
output price is close to independent of how noisy the input was**, which is the whole thesis stated as
a measurement: it charges for what the camera saw and not for what the sensor invented.

And it does not buy that by eating the person. The lock ran 423 frames with 0 declines, 30 fps held,
same resolution both arms, and the two checks a bitrate number cannot make: **86% of the person's
motion survives** (the busiest 15% of the picture changes 53% of frames against the control's 61%)
while the quietest half settles from 75% to 59%, and high-frequency energy moves −4.4% — grain, given
that the motion survived. The stills show eyelashes, individual hairline strands, skin texture and the
earring all present at 1.25 Mbps.

Synthetic grain is iid where a sensor's is correlated across the Bayer neighbourhood, stronger in
shadow, and already shaped by the ISP's own denoiser — so passing here licenses nothing. The
**real-sensor law** still gates this and the filter stays behind `?pfilter=1`. What this run does buy is
that the two ways the filter could have died on a real camera — the lock thrashing under grain, or the
hold going stale under a hunting exposure — have both been put to it, and neither happened.

One number now rides every call so the failure cannot be silent: **`pfHoldThresh`**, the lock threshold
after upward adaptation. It starts at 0.012 luma and ratchets toward this sensor's grain floor, capped
at 0.02. A saturated threshold beside a near-zero `pfStillMean` is the filter's quiet failure mode —
the lock never engages, the saving evaporates, and every other number still looks fine.

---

## 17.25 Presence filter — 61.5% fewer bits at the same quantizer, nothing blurred (2026-08-17, task #2)

Question: the spine costs 12 Mbps on motion at QP24. How much of that is detail a person can actually see? **Answer: most of it is not, and removing it needs no new codec, no standard, and no decoder change.** `tape-app/public/presence-filter.js`, one WebGL2 pass in front of `VideoEncoder`, behind `?pfilter=1`.

Three levers, measured separately because they carry completely different risk:

| lever | what it does | can it cost the picture? |
|---|---|---|
| **denoise** | blend with the previous OUTPUT where nothing moved (an IIR) | no — averages the random part away, leaves the repeated part |
| **hold** | where a region has been still ~0.45 s, emit the previous output **EXACTLY** | no — repeats a pixel the camera really saw; error bounded by its own threshold |
| **soften** | 3×3 blur in proportion to local motion | **yes** — removes real detail on a claim about vision |

**Measured (testbed/pfsweep.mjs, 4 rounds × 2 sides, one live call on room.tokkah.com, QP pinned 24 both arms, `rcres=0`, resolution divisor 1 everywhere):**

| arm | A Mbps | B Mbps | cut | per-round spread |
|---|---:|---:|---:|---|
| off | 3.42 | 2.75 | — | — |
| denoise | 1.98 | 1.51 | 43.0% | 27..56% |
| soften | 2.96 | 2.23 | 14.0% | 7..25% |
| hold | 1.99 | 1.52 | 42.5% | 22..53% |
| denoise + hold | 1.30 | 1.12 | 59.3% | 50..69% |
| **denoise 0.85 + hold** | **1.12** | **1.00** | **61.5%** | 59..72% |
| + soften 0.7 | 1.10 | 0.91 | 65.5% | 60..73% |

**The product answer is the second-to-last row.** The one lever that can damage the picture is worth 4 points on top of the two that cannot, and at soften 1.0 the softening is plainly visible in the receiver stills (face texture and nameplate lettering both go). So: **denoise + hold, soften OFF.** 30 fps held, g2g +1.5 ms, 0.14 ms/frame GPU.

**Why the hold works, and why §17.24 Probe C concluded it wouldn't.** Probe C measured a *fully* static scene (1.74 Mbps) against a moving one (12.00) and wrote down "stillness is already cheap". True, and not the case a video call presents. A call is a **still background with a moving person in front of it** — and at fixed QP the still background is NOT cheap, because sensor grain is temporally random, so every block of a motionless wall carries a nonzero residual and gets re-bought thirty times a second for the length of the call. Denoise removes that grain; the hold then makes the region **bit-identical** frame to frame, which is what turns it into skip blocks. An 0.85 IIR alone cannot: it leaves 15% of fresh grain in every pixel, so the residual never reaches zero. Exact repetition is a step change, not a stronger blend — which is why `hold` (42.5%) and `denoise` (43.0%) are each worth about the same alone but 61.5% together.

Staleness needs no timer and no keyframe forcing: the difference is measured against the HELD value, so a slow drift (auto-exposure creeping, room light changing) accumulates until it crosses the threshold and releases that pixel by itself. The held picture can never be further from the truth than the threshold — capped at 0.02 luma ≈ 5/255, below the visible step on any display. That cap IS the safety argument, which is why the threshold adapts upward only (toward a noisy phone sensor's real grain floor) and never downward.

**Instrument corrections this probe forced** (both had been silently corrupting results):
- `video.mbpsAtFps` averages the last 900 encoded frames — **30 s at 30fps**. Read after a 12 s arm it is a blend of three arms, and it produced a table where `hold` cost 31% alone and saved 28% in combination. Added `encBytesTotal` / `encFramesTotal`, cumulative on both lanes; rigs difference them across the slot.
- The fixture is a **90 s** clip (`fetch.sh`: `-t 90`) that Chrome loops forever, and 7 arms × (12 s + ~1 s of tool overhead) made a cycle of ~91 s — one loop, near enough. Every arm landed on the same footage every round. The numbers repeated to two decimals and read as precision rather than as the confound they were. Arms are now rotated each round.
- The rc resolution actuator fires in whichever arm is most expensive and quarters its pixels — a confound pointing the same direction as the effect. Rigs pin `rcres=0` and the sweep now declares itself VOID if the divisor differs across arms.

Being inside one call was necessary and was never sufficient.

**Not yet proven, and it is the part that matters:** every number above is on already-compressed fixture video, whose grain is mostly stripped before it reaches us. A real camera has more grain to remove (so denoise should earn MORE) and a real camera's auto-exposure never stops moving (so the hold may earn LESS until the threshold adapts). Per the real-sensor law the filter stays behind `?pfilter=1` until a sensor confirms it.

The lane for that is now the **lab channel**, which needs no cable and no permission — the other three are all shut on this machine (emulator webcam passthrough dead on Darwin 27, `adb` not installed, and macOS denies the camera to both the Browser pane and the Playwright binary; note a denied camera does not throw, it resolves and returns uniform black, which `testbed/camprobe.mjs` checks for by variance). Instead: any phone or laptop opens `?r=lab&pfilter=1&rcres=0&qp=24`, and `testbed/pfreal.mjs` drives the arms on that device's own sensor over the room's websocket, reading its encoder through the `snap` op's cumulative counters. `pfilter` was added to `handleLab()`'s knob **whitelist** — never a generic setter, since the lab channel is a live control surface on a call between two people. Validated end to end against two parked fake-camera peers (`testbed/labhold.mjs`): 60.9% cut, matching the local rig's 61.5%, which proves the plumbing and nothing about a sensor. `testbed/pfhold.mjs` is the rig that guards the failure mode a bitrate number cannot see — it derives where the person is from the control arm (the cells that change most ARE the person) and asserts those cells still change with the lock engaged, so a lock that eats a face fails even while bits fall.

---

## 17.24 Codec frontier probe — AV1 and ROI measured against the spine, both rejected (2026-08-02, task #34)

Question: can AV1 and/or face-aware ROI bit allocation deliver the spine's measured 99.7 VMAF at meaningfully fewer than its 12.0 Mbps-at-fps? **Answer: no, on both.**

Harness: `testbed/codec-frontier.mjs` (testbed-only) — headless Chrome 149, fake camera from the §17.16 fixture, in-page `MediaStreamTrackProcessor → VideoEncoder (bitrateMode:'quantizer', per-frame quantizer, the tape.js spelling) → VideoDecoder → canvas`, stills scored by the **unmodified** `vmaf-score.mjs`. Numbers are encoder+decoder wire-bits, comparable to §17.16's Mbps-at-fps column; delivered-with-FEC = ×1.33. Encode latency = submit→output wall per frame, queue gated at 4 (the tape.js gate). Every arm preflights that the quantizer knob moves bytes >1.5× between extremes (measured 14.1× H.264, 5.3× AV1). Validation anchor: the harness's h264-qp24 arm reproduces the courtroom numbers — **99.76/12.00 vs §17.16's 99.73/12.04**, enc 6.4 vs 6.2 ms.

**Probe A — AV1 (av01.0.04M.08, quantizer mode): REJECT.** 1080p30, 15 s windows, 100% admission every arm, GOP 150 both codecs:

| arm | VMAF | Mbps-at-fps | +FEC | enc p50 ms | dec p50 ms |
|---|---:|---:|---:|---:|---:|
| h264-qp24 (anchor) | 99.758 | 12.00 | 15.96 | 6.4 | 1.5 |
| av1-q100 (bar crossing) | 99.728 | 12.16 | 16.17 | 5.7 | 1.2 |
| av1-q120 | 99.343 | 9.52 | 12.66 | 5.9 | 1.2 |
| h264-qp26 (iso-bitrate ref) | 99.597 | 9.53 | 12.67 | 6.6 | 1.6 |

AV1 crosses the 99.7 bar at q100 — at **+1.3% more bits than H.264 QP24 for −0.03 VMAF**; the RD curves sit on top of each other at the transparency ceiling. The win bar (≥99.7 at <8 Mbps delivered) extrapolates to ~q150 ≈ 6 Mbps at ≈98.5 VMAF — more than a point short. At iso-bitrate 9.5 Mbps, H.264 leads by 0.25. AV1 genuinely wins latency (enc 5.7–6.6 vs 6.4–6.8, dec 1.2 vs 1.5, software libaom) — but the spine's bottleneck is bits, not encode ms. Caveat logged: cam1080's iid noise gives AV1's better prediction nothing structured to monetize; on real talking-head content at Tier-B/C rates a re-probe may differ (§17.2's call-like master had AV1 ahead at ~10 Mbps). Doesn't change the answer for the 99.7 spine.

**Premise update, bigger than the probe:** the §17 risk-table entry "AV1 is totally absent on this Mac" is **stale** — on Chrome 149 every AV1 mode including `bitrateMode:'quantizer'` configures, echoes, and encodes 1080p30 (real 0–255 qindex; §6's "0–63" comment also wrong). §6's premise flips from "AV1 absent" to "**AV1 present but not better at our operating point**" — a stronger, more durable reason to stay on H.264. Safari AV1 *encode* remains effectively absent, so any AV1 lane would keep the H.264 fallback tape.js already supports structurally.

**Probe B — QP raise / ROI proxy (bounded 2 configs): REJECT.** qp26 = 99.597 @ −20.6% bits; qp28 = 99.266 @ −34.9%. Center-region crop proxy (960×540, no faces in fixture — confessed; absolute scores resolution-confounded, slopes only): region quality falls 0.27 VMAF qp26→qp28 vs global's 0.33 — **the hard region degrades at least as fast as the average; the "faces stay at 99+ while background pays" reserve is absent on this content.** Neither arm clears 99.7. Calibration fallout: **§6 Tier B (QP26, "7 Mbps") actually measures 9.53 Mbps-at-fps / 12.7 with FEC — the tier table's bitrate column is ~27% optimistic; Tier B's real uplink requirement is ~11 Mbps + headroom.**

**Probe C — content-adaptive QP bounds: noted, no action.** Same encoder, same QP24: 12.00 Mbps-at-fps on motion+noise vs **1.74 on static+noise (VMAF 99.15, at the 99.10 rig floor — transparent)**. The spine's delivered-rate dynamic range at constant quality is **~7×** (2.3↔16.0 with FEC), absorbed by the pacer/governor without touching quality. Lane-P stills earn in SQUEEZE/SHED, not as a calm-scene optimization — stillness is already cheap.

Method honesty: two failed runs caught and excluded (yuvj444p fixture → solid green frames, PSNR 9.2 — impossible, fixture regenerated yuvj420p; gray-alignment cache collision on static scoring, re-run in own parent dir). No production files touched; nothing deployed; all arms serial under the heavy-run mutex. Full record: `scratchpad/codec-frontier-note.md`; runs: `scratchpad/codec-frontier/`.

---

## 17.23 v-presenter — remote smoothness = self-view smoothness (2026-08-02, task #33, DEPLOYED-pending)

User complaint (#2 directive): remote video visibly far off self-view smoothness. Root cause class: presentation followed *arrival* (paint-on-arrival), so every network/queue wobble became a visible cadence break. Fix: a receiver-local **cadence-locked presenter** — a metronome on the capture-timestamp grid, disclosed constant D = 66.7 ms, queue depth 3, under-run holds one interval, lane-P stills bypass, avsync engagement sticky-wins, governor untouched. Receiver-local by construction: emits no ctl/worker/datachannel byte (`?vprev=0` kill switch, default ON).

Three revisions, each failure root-caused from probe data: rev 1 wedged (asymmetric re-anchor + admission catch-up bursts = one-way ratchet); rev 2 starved its own schedule (drop-oldest dropped the due-soonest frame; 99.5% of holds were cap-created holes); **rev 3 (shipped): overflow presents the head ≤1 slot early (blip not hole) + bounded self-limiting phase servo (only ever reduces latency; measured pipeline drift 5–10 slots/call). Steady-state added latency ~0–33 ms, worst-case bounded ~100 ms, disclosed.** Verified first by replaying recorded arrival streams through a simulator (vp-sim.py), then live.

**Gates** (75 s arms, cam1080 12 Mbps, 15 s warmup trim; base2 = pre-patch same tree vs vp3 = rev 3):

| arm | remote IPI p50/p95/p99 | on-cadence | ratio vs self p99 | verdict |
|---|---|---|---|---|
| base2 loopback | 31.4–31.5 / 63–70 / 95–110 ms | 58% | 2.1–2.3× | baseline |
| **vp3 loopback** | **33.3 / 34.3 / 49–50 ms** | **96–98%** | **1.11–1.21×** | **PASS (bar ≤1.5×)** |
| base2 80/1 | 125–202 / 500 / 625–674 ms | 0.7–4.3% | 12–13× | baseline |
| vp3 80/1 | 33–34 / 67–117 / 117–167 ms | 50–79% | 2.7–3.5× | 4–5× better; bar missed, cause named |

Loopback remote is now **statistically indistinguishable from the self-view's own metronome** (self: p50 33.3, breaks 0–0.4%; remote: breaks 0.7–1.2%, timing drops 0). The 80/1 tail is **arrival starvation**, not presentation: under p2psim loss the governor throttles admission (skipPaced) and FEC/stall holds create multi-slot arrival gaps — a receiver-local presenter cannot present frames that never arrive, and it dropped **zero** frames for timing while absorbing the churn. The 1.5× bar at 80/1 would require arrival gaps ≤ ~75 ms at p99 — a sender-path/governor problem, queued.

Other gates: (b) avsync |offset| p95 *better* than baseline (loop-av 36→27/14 ms; 801-av 130–160 ms early-baseline → 26–35 ms); (c) decQueue 0, avDrops 0, vp timing drops 0 every arm; (d) turntaking 45/45, pcmrs ok, onset 69/69, tsc 0 (independently re-run by coordinator on the merged tree); (e) stallforce cycle clean (shed → 5 lane-P stills → resume clean cut, presents back at p50 33.4); (f) wire-invisible by construction + control arm indistinguishable from baseline.

**Flag recorded for follow-up (task #40):** the 35118ff8 train regressed the loopback avsync *tail* independent of the presenter (phase-1 on-cadence 76% → tree baseline 57–59%, p99 233–283 ms) — something in stall+hardening+UI costs the avsync path its tail.

Files: tape.js +143 vs 35118ff8, app.js +10 (flag). Full record: `scratchpad/smoothness-p2-note.md` (design, re-baseline, gate tables, 5 incidents incl. contaminated-baseline recovery + API-outage resume protocol).

---

---

## 18. Cost model

Per hour of 1:1 call at tier A (12.5 Mbps each direction):

| Path | Volume | Cost |
|---|---:|---:|
| **P2P (direct)** — expected ~80–85% of calls | 0 bytes through CF | **$0.00** |
| **TURN relayed** — the remainder | 5.6 GB/hr × 2 directions = 11.2 GB | **~$0.56** |
| DO + Worker + D1 (control plane, ~1 KB/s) | ~4 MB | ~$0.00 |

CF TURN includes 1,000 GB free, so roughly the first **89 relayed call-hours per month cost nothing**.
Beyond that, blended cost lands near **$0.08–0.11 per call-hour** at an 85% P2P rate — at list price,
which an Enterprise contract should improve on.

The economics reinforce the architecture: P2P-first is simultaneously the lowest-latency and the
cheapest choice, and the expensive path is the rare one. Cost scales with NAT topology, not usage —
which is an unusually comfortable place to be.

If phase 1 forces the Spectrum fallback (§8.1), the model changes shape: Spectrum bandwidth plus a
small always-on VM fleet, and *every* call becomes relayed, so per-call-hour cost rises and the free
tier stops helping. Worth pricing before phase 1 rather than after, so the decision gate has a
number attached to it.

---

## 19. Build order

Each phase exists to kill one specific risk. Do not proceed past a phase whose risk isn't dead.

**Phase 1 — Transport truth (a few days).** No UI, no media. Two browsers, a DataChannel, synthetic
traffic at 12 Mbps in 1,150 B datagrams. Measure sustained throughput, loss, and one-way delay across
20/80/150 ms RTT and 0/1/3% loss, both P2P and TURN-relayed. Nothing else gets built until this
number exists.

> **Decision gate.** Pass = sustained 12 Mbps at 80 ms RTT with `bufferedAmount` stable near zero.
> On failure, in order: (a) stripe lane B across N parallel `RTCPeerConnection`s and re-measure;
> (b) if that's still short, switch the transport to WebTransport-over-Spectrum (§8.1) and price it
> against §18 before committing. Do not proceed to phase 2 on an unresolved gate — the transport
> choice determines the packetizer, the ARQ deadlines, and the congestion controller's entire input
> set, and retrofitting it later means rewriting §9, §11, and §12.
>
> **Result: distance is free, loss is fatal.** The gate passes at every distance tested and fails
> on any path with meaningful packet loss. Those are two different answers to two different
> questions, and the second one decides the transport.
>
> **Clean link — PASSES, and distance costs nothing.** 12 Mbps bidirectional, forced through a
> real TURN relay, 25 s soak per cell, both directions verdicted independently
> (`phase1-transport/gate.mjs`):
>
> | ICE RTT measured | throughput median | p5 bucket | loss | **`bufferedAmount` p95** | queue delay p95 |
> |---|---|---|---|---|---|
> | 22.0 ms (20 set) | 12.00 Mbps | 11.91 | 0.000% | **1.1 KB** | 3.6 ms |
> | 80.0 ms (80 set) | 12.00 Mbps | 11.90 | 0.000% | **1.1 KB** | 3.7 ms |
> | 151.0 ms (150 set) | 12.00 Mbps | 11.88 | 0.000% | **2.2 KB** | 3.9 ms |
>
> `bufferedAmount` is the figure the gate is really about, and it does not move with distance:
> 1–2 KB against a 64 KB limit at 150 ms RTT. **Our pacer is the binding controller and usrsctp's
> congestion window is not** — §8 hazard 3, the failure mode capable of invalidating the design,
> measured rather than hoped for. Neither renderer was backgrounded and both paths report
> `RELAY (TURN)`, so the distance was really applied.
>
> **But read the duration before believing the row.** Every cell above is a 25 s soak, and there is
> a cliff at about 38.7 s that none of them reaches. In every longer run — all three 45 s matrix
> soaks and every ramp — the *receive* path stops dead while the sender is still writing at full
> rate; `bufferedAmount` then fills 0 → 24 → 218 → 256 KB over roughly 600 ms and the pacer wedges
> at its high-water mark. It is a timeout and not a volume: 8 Mbps stops at 38.6 s and 12 Mbps at
> 38.8 s, the same moment against a 50% difference in bytes. node-turn's allocation lifetime is 600 s
> so that is not it; the leading candidate is ICE consent freshness, which libwebrtc gives up on
> after 30 s, landing near 38.7 s once startup is added — with either the delay line or node-turn
> failing to service STUN consent checks under datagram load.
>
> I first filed this as a rate-transition bug because the ramp appeared to die at its 8→12 Mbps
> step; the per-bucket data shows the step was a coincidence of timing and the cliff is what
> actually truncated all three 45 s soaks, which I had misread as clean teardown.
>
> **Resolved: the cliff is the harness, not the transport.** The bisection was run on the *media*
> path, which is a cheaper way to ask the same question because it exercises the same emulator with
> a different transport on top. Three 75 s calls at 720p30 and ~12 Mbps:
>
> | Arm | Emulator | Result at ~40 s |
> | --- | --- | --- |
> | `--rtt=80` | delay line + node-turn | NACKs start at exactly 40 s from zero and climb for the rest of the run; bitrate dips to ~4 Mbps and takes ~20 s to recover |
> | `--rtt=80`, 8 MB UDP buffers | delay line + node-turn | Same onset, ~36% fewer NACKs (225→144, 169→107), shallower dip — an improvement, not a cure |
> | `--nosim` | none — direct loopback | **Zero NACKs for the full 75 s on both sides**, `targetBitrate` pinned at the 12.00 Mbps cap, 29–31 fps throughout, no dip |
>
> Removing the emulator removes the cliff. So it is neither Chrome's stack nor this machine, and
> the transport result stands — but note what that costs: **every netsim run longer than ~40 s has
> contaminated loss numbers**, because loss begins at 40 s and persists. The loss sweep below is
> unaffected only insofar as its cells are shorter than that; any cell that is not must be re-run.
>
> Three candidate mechanisms have now been excluded, and the delay line is cleared entirely:
>
> - **Not accidental send failure.** A `sendErrors` counter was added (the earlier version passed an
>   empty callback to every `send`, so it could report `dropped: 0` while losing packets). It reads
>   exactly 0 across 400 MB carried.
> - **Not timer or GC pressure from holding datagrams.** At 80 ms and 12 Mbps the proxy has ~208
>   datagrams sitting in `setTimeout` objects at any instant; at `--rtt=1` it has almost none. The
>   cliff is *identical* — first NACK at 42.5 s and 42.7 s in both — and the low-delay arm is
>   actually worse (573 NACKs vs 329).
> - **Not the delay line's punctuality.** Its lateness p99 is 1.9–2.0 ms with a max of 17–25 ms
>   against a promised 80 ms. It delivers the distance it advertises.
> - **Not a timer in node-turn.** Its nonce lifetime is 1 hour, default allocation lifetime 600 s,
>   max 3600 s. Nothing fires near 40 s.
>
> What remains is **load through node-turn**, which forwards every datagram in single-threaded
> JavaScript — roughly 2600 packets/second at the combined ~24 Mbps these runs generate. The onset
> is suspiciously repeatable (42.5, 42.7, 42.5, 42.8 s across four runs at two different delays),
> which argues for a timer, but no timer exists at that value; a GC or heap-growth threshold reached
> at a near-constant *rate* would look the same. The discriminating arm is the same relay path at
> ~0.45 Mbps instead of 12 — a 26× load reduction with every timer unchanged.
>
> That arm has now run, and it splits the question in a way no single number would have: **the onset
> is load-independent, the damage is load-proportional.** At ~0.45 Mbps — 20× less traffic, 20.8 MB
> against 400 MB — the first NACK still lands at 42.7 s, but the run costs 9 and 36 NACKs instead of
> 329 and 573, and the bitrate never visibly dips. So something happens at ~42 s regardless of load;
> what scales is how much is in flight to lose when it does.
>
> The browser's own view rules out the whole class of connection-level explanations. Across a 75 s
> relayed run, `ice-state` reads `connected` at 1.0 s and **neither `ice-state` nor `pc-state` fires
> again** — no disconnect, no re-check, no candidate-pair change, no renegotiation. Whatever happens
> at 42 s is invisible to Chrome's connection state machine: it is plain packet loss. That excludes
> ICE consent freshness, which was the leading candidate for hours.
>
> All three arms were verified to be the configuration they claim: relay forced with 82 ms measured
> ICE and 399.8 MB through the proxy; relay forced at 6 ms with 382.4 MB; `--nosim` with relay off
> and 0 MB through the proxy. The bisection rests on that check rather than on the flag names.
>
> The practical consequence: **node-turn is not a load-bearing part of the measurement, and the
> harness needs distance without it.** It was chosen to avoid putting real conversation audio through
> a third party, which was the right call, but a single-threaded JS forwarder cannot stand in for a
> relay at tier-A bitrates. This does not transfer to production — Cloudflare's TURN is not a Node
> process — but every netsim run longer than ~40 s inherits it, so the fix is a harness change:
> deliver the delay on the P2P path by rewriting candidates, rather than by relaying.
>
> **BUILT, AND IT SETTLES IT.** `--p2psim` (`startP2PSim` in netsim.mjs) rewrites every remote
> candidate so its port belongs to a delay proxy fronting the peer. Neither browser learns the
> other's real address, so there is no direct path to leak onto and no relay to break. Head to head,
> same 75 s, same 80 ms, same fixture, same machine:
>
> | | relay (node-turn) | relay-free |
> | --- | --- | --- |
> | **First NACK** | **42.5 s / 42.7 s** | **never** |
> | NACK total | 330 / 227 | **0 / 0** |
> | Freezes | 1 / 1 | 0 / 0 |
> | Video delivered | 8.85 / 8.73 Mbps | **10.16 / 9.83 Mbps** |
> | ICE RTT measured | 81 / 81 ms | 81 / 82 ms |
> | Datagrams through the proxy | 328,748 (373 MB) | 183,203 (205 MB) |
> | Delay-line lateness p99 | 2.3 ms | 2.5 ms |
>
> The onset reproduces the earlier 42.5–42.8 s to a tenth of a second, and removing the relay
> removes it entirely while measuring the same distance. Three details worth keeping: the relay path
> carries **1.79× the datagrams** for one call, which is the two crossings made visible; it was also
> *costing* 1.3 Mbps of video, so the damage suppressed throughput as well as adding loss; and one
> crossing per direction means the relay path's two corrections — halving `delayMs`, un-compounding
> `lossPct` — are no longer needed, so the knobs mean what they say.
>
> Classifying the emulator's own send failures had to be fixed before this was usable, and getting
> it wrong cost a good run in each direction. Conflated, 36 unreachable ICE checks out of 185,031
> datagrams condemned a 75 s run with zero app-level loss and zero NACKs. Split on a *guess* that
> they were ECONNREFUSED, the count came back 36-by-accident and 0-refused — refuted. They are
> EHOSTUNREACH, from Chrome gathering a host candidate on this machine's `en8` link-local
> 169.254.27.97, which has nothing on the other side. Unreachable destinations are now counted
> apart from ENOBUFS, and the errno histogram is kept, because a bare counter cannot say what it
> caught.
>
> **Consequence for earlier results:** any netsim cell longer than ~40 s should be re-run with
> `--p2psim` before its loss numbers are quoted.
>
> All four emulator features together — 75 s at 80 ms RTT, 15 ms jitter, 1% loss and an 8 Mbps
> ceiling — run with 0 accidental drops, and injected loss lands at **1.02%** against 1% asked
> (982 of 95,795) with no un-compounding correction applied, which independently confirms the
> single-crossing topology. What the call does under that much adversity is worth stating plainly
> rather than filed as a pass: resolution holds at 1080p30 and `limit` stays `none`, but GCC backs
> off to 4.2 Mbps of the 8 available, NACKs run to ~4,800 per side from 2.5 s onward, 207–220 video
> packets are lost outright, and there are **3–6 freezes totalling 0.7–1.4 s**. 1% sustained loss at
> 80 ms is a genuinely bad path, and this is the failure mode §1 promises to avoid — so it is the
> clearest measured target for the custom transport rather than evidence the current one is enough.
>
> **What this clears, and what it does not.** The transport result stands, and the media path is now
> known good for 75 s at 720p30 and ~12 Mbps with zero NACKs when the emulator is out of the way. It
> does *not* clear tier-A bitrates over a real relay across a real distance for minutes at a time —
> that needs two machines in two regions, which is still the one experiment nothing here substitutes
> for.
>
> The loop-lag probe was also not trustworthy here and has been replaced as the primary signal. It
> samples every 200 ms with a 50 ms timer, so it reports *average* punctuality and cannot see a
> stall that falls between samples — it read p95 1.81 ms during a run whose NACK count climbed for
> 30 s straight. The delay line now also measures its own **lateness**: for 1 in 64 real datagrams,
> how much later than promised the packet actually left. That rides on the traffic itself and so
> cannot miss a stall by sampling past it.
>
> **Under loss — FAILS, and the shape of the failure is the finding.** Same cell, 80 ms RTT,
> sweeping loss. Loss is the *measured* application-level rate, which is what the peers
> experienced:
>
> | measured loss | throughput median | `bufferedAmount` p95 | queue delay p95 |
> |---|---|---|---|
> | 0.000% | 12.00 Mbps | 1.1 KB | 3.7 ms |
> | 0.617% | 2.12 Mbps | 257.0 KB | 1218 ms |
> | 1.281% | 1.55 Mbps | 257.1 KB | 1600 ms |
> | 2.169% | 1.11 Mbps | 257.1 KB | 2314 ms |
> | 3.643% | 0.78 Mbps | 257.0 KB | 2091 ms |
>
> Fitting those four points (`phase1-transport/lossfit.mjs`) gives **BW = 0.1253·p^−0.564**, R² =
> 0.987. The exponent is the whole argument: a loss-based AIMD congestion controller predicts
> −0.5, and −0.564 is that law. This is not our pacer failing, not the emulator, and not a bug.
> It is **usrsctp's congestion window reading random loss as congestion and clamping**, with our
> pacer's data piling up behind it — `bufferedAmount` pinned at 257 KB and seconds of standing
> queue are the pile.
>
> Extrapolating the fit to the requirement:
>
> | path loss | ceiling at 80 ms RTT | 12 Mbps? |
> |---|---|---|
> | 0.01% | 22.6 Mbps | yes |
> | 0.05% | 9.1 Mbps | short by 2.9 |
> | 0.10% | 6.2 Mbps | short by 5.8 |
> | 1.00% | 1.7 Mbps | short by 10.3 |
>
> > **To carry 12 Mbps at 80 ms RTT over an SCTP data channel, the path must lose fewer than
> > 0.011%–0.031% of packets — somewhere between 1 in 3,300 and 1 in 9,300.** That is very nearly
> > a lossless path.
>
> The range is a bracket, not sloppiness, and it is worth one paragraph because it is the only
> soft spot in the result. About half of the app-level loss is excess over what the delay line
> injected, and the excess grows with severity — which points at usrsctp shedding from its own
> buffers once the window has collapsed. If some of the loss is *caused by* the collapse, then
> regressing throughput on measured loss is partly circular. So the fit is run twice
> (`lossfit.mjs measured` / `injected`): once against app-level loss, which is physically the right
> variable but partly dependent, and once against the delay line's own drop counters, which we set
> and the transport cannot influence. Exponents −0.564 and −0.524, both the AIMD law; thresholds
> 0.031% and 0.011%. The two axes disagree by 3× on the threshold and not at all on the verdict,
> which is what makes the verdict safe to act on.
>
> **This cannot be fixed above the transport, and that is what makes it decisive.** The obvious
> answer is FEC: send redundancy, recover the lost packets, never retransmit. It does not work
> here. FEC recovers the *payload*, but SCTP still sees the SACK gap and still halves its window,
> so the throughput ceiling is untouched no matter how much redundancy rides on top. Nor is ARQ
> the culprit to remove — the bulk channel already runs `ordered: false, maxRetransmits: 0`, so
> there is no head-of-line blocking and no retransmission in the measurement above. The
> congestion controller is in the way, it is not ours, and the API exposes no way to replace it.
>
> So the remediation ladder above resolves, and it skips a rung. Option (a), striping across N
> parallel `RTCPeerConnection`s, works arithmetically — each association gets its own window — but
> the fit says 1% loss needs about 7 of them, and every one is a separate DTLS handshake, ICE
> negotiation and failure mode for a design whose entire premise is that nothing between the two
> people is allowed to be flaky. Option (b), **WebTransport-over-Spectrum (§8.1) with a
> loss-tolerant controller**, is where this lands. QUIC's controller is pluggable and BBR-class
> controllers estimate bandwidth from delivery rate rather than treating a lost packet as proof of
> congestion, which is precisely the failure measured here. Price it against §18 before
> committing — see the open task.
>
> Note also what this does to the design's spine. "Quality is a constant, time is the only shock
> absorber" is not a slogan the transport can opt out of: offered 12 Mbps on a path that can carry
> 1.7, the shortfall *must* go somewhere, and it went into time — 2.3 s of standing queue. The
> principle behaved exactly as written. It just means a lossy path is a path where the shock
> absorber bottoms out, and §11's deadline logic has to be the thing that notices, not the pacer.
>
> **Two harness bugs were fixed to get here, and both had produced confident wrong answers.**
> A first matrix run reported 0/12 cells passing, which read as total transport collapse:
>
> - **The verdict included the drain after sending stopped.** Bucketing outlives the pacer, so
>   every run's tail is a quiet channel with a stale `bufferedAmount`. Unclipped, three cells that
>   were carrying 12.00 Mbps at 2.2 KB buffered for every second the pacer actually wrote were
>   reported as a throughput floor of 0.00 Mbps and 256 KB pinned. A p5 has no defence against a
>   fifth of its samples being structural zeros. The verdict is now clipped to the send span —
>   first write to last write — with every bucket *inside* it kept, including blocked-sender ones,
>   because dropping those individually would have deleted the evidence of the loss collapse this
>   same run found.
> - **The one-way-delay baseline was a session minimum.** See the pattern note in §17.1: one
>   packet 275 ms below a steady state flat to within 1 ms poisoned every reading after it, and
>   the gate invented 277 ms of queueing while `bufferedAmount` read 3.4 KB. Two false FAILs on a
>   real pass. Now a low percentile, with the gap to the raw minimum exported.
> - **And then the span clip needed a check of its own, because the fix opened a hole.** Clipping to
>   the send span cannot distinguish a run that *finished* from a run that *died* — both end with the
>   pacer no longer writing. The very next matrix passed a 45 s soak whose connection had been dead
>   since 38.6 s, and it passed legitimately: every bucket inside the truncated span was genuinely
>   healthy. The most serious failure this harness can observe was scoring as a clean pass. So the
>   verdict now checks coverage first — the sender must still be writing at 95% of the planned
>   duration — and that check immediately found the cliff in all six cells of the old matrix at
>   84–86% coverage, both directions, at every distance and every loss level. The lesson is narrower
>   than "test your fixes": a filter that removes bad data has to be asked what *else* matches its
>   predicate, because "no data here" and "no data from here on" look identical downstream.
>
> A third fix was defensive rather than corrective: the delay line samples its own event-loop lag
> and a cell whose lag p95 exceeds 20 ms is reported **INVALID** rather than FAIL, because a
> jostled ruler must never be allowed to fail the thing it measures. It has not fired — I suspected
> CPU starvation was behind the bad matrix and tested it directly, running the gate cell while
> macOS Spotlight indexing consumed about three of this machine's four performance cores. It
> passed, with loop lag p95 of 2.3 ms. The hypothesis was wrong and the guard stays.
>
> The gate ran here rather than on two continents because `testbed/netsim.mjs` makes emulated
> distance cheap: a UDP delay line in front of a TURN relay we own. That is real relayed UDP with
> settable delay, jitter and loss, and it is **not** a real internet path — no cross-traffic, no
> bufferbloat, no route changes. One caveat specific to the loss result: the emulator drops
> uniformly at random while real loss is bursty, and bursty loss produces *fewer* congestion events
> for the same average rate, so uniform loss is the pessimistic case — the real ceiling on a real
> path of the same average loss is somewhat higher than the fit says. Two machines in two regions
> remains the honest confirmation of all of it.
>
> One hypothesis is worth recording as refuted, because it was specific and would have mattered.
> The emulator's loss knob delivers about 2.5× its label, while the delay model says a one-way
> relayed trip crosses the delay line twice — and ICE agrees with the delay model to 0.1 ms. A
> factor of two was unaccounted for. The candidate was MTU fragmentation: the harness sent 1150-byte
> messages, which with SCTP, DTLS, TURN and IP overhead lands within a few dozen bytes of the
> ~1200-byte SCTP path MTU, and under `maxRetransmits: 0` losing either fragment of a split message
> discards the whole message — so message loss would be twice datagram loss, exactly the missing
> factor. It made a quantitative prediction: drop the payload to 1000 bytes and measured loss should
> roughly halve. It did not. 2.169% → 1.883%, a 13% change where 50% was predicted, so the
> hypothesis is dead. The residual is most likely usrsctp shedding from its own buffers under
> collapse, which fits the excess growing as the collapse deepens. The rule the hypothesis was
> reaching for is still correct and still belongs in §9 — in unreliable mode a frame split across
> two datagrams carries twice the loss probability, so real payloads stay under one MTU — it simply
> is not what produced this number.

**Phase 2 — Locked pipeline, one direction.** Camera → locked capture → fixed-QP encode → packetize
→ SCTP → reassemble → decode → WebGPU. No congestion control, no FEC, no ARQ. Goal: prove that on a
good link it looks *unmistakably* better than Zoom, and measure real glass-to-glass against §3's
budget. If the difference isn't obvious to a bystander at this stage, the thesis is wrong and nothing
downstream fixes it.

**Phase 3 — Clock and audio.** Session clock, `TIME_SYNC`, PCM lanes, AudioWorklet ring, drift
resampling, RS FEC. Goal: an hour-long call with zero audible defects and no sync creep. Verify the
crystal-drift math holds over 60 minutes.

> **Phase 3 also owns Lane 0 and the onset detector (§3.1, §4)** — voice-onset detection on the raw
> 48 kHz stream, mid-datagram preemption of Lane B, and the turn-end predictor feeding path warming.
> This is out of order by difficulty and in order by value: §3.1 lever 1 is worth ~200 ms, more than
> every other latency optimisation in this document combined, and it cannot be tested without the
> real PCM lane. Ship it the moment audio works, not in phase 4.
>
> **Its own gate, and it needs human subjects — and the gate is already built.**
> `fatigue-lab/public/turns.js`, served at `/turns`. Boland's paradigm: timed yes/no Q&A, two
> machines, headphones, one run raw and one processed. Pass = human-only median within 120 ms of the
> 297 ms face-to-face control, >50% of turns opening with an audible breath, ≥100 ms head start, and
> first evidence under Zoom's measured 976 ms.
>
> It needs **no clock synchronisation**, which is the design decision that makes it trustworthy: a
> detector runs on the *received* audio as well as the local mic, so "when I stopped talking" and
> "when their breath reached me" are both events on one clock. Network latency sits inside the
> measurement rather than being added to it — which is what we want, because we are measuring what
> the human perceived, not modelling it.
>
> If raw audio and Lane 0 do not measurably move turn-taking, §1.1c is wrong — and §1.1c is the reason
> the lossless commitment is affordable. **This gate can run before a line of the encoder exists, and
> it should.**

**Phase 4 — The stall machine.** Congestion controller, WSOLA, lane shedding, lane P, ARQ, the full
state machine of §13. Test under a shaper: gradual squeeze, sudden cliff, flapping, total outage.
Goal: every transition reads as intentional. No frame is ever ugly.

**Phase 5 — Cloudflare + product.** Worker, DO, D1, TURN credentials, path racing, lobby, tiers,
the UI of §15. This is the least uncertain phase; sequence it last deliberately.

---

## 19.1 The latency ladder — web, native, appliance, OS

### First, where the milliseconds actually are

In a 150 ms browser-to-browser call between two people in the same city:

```
network      ~5 ms    ███
the two devices  ~145 ms    ████████████████████████████████████████████████
```

Same metro over fiber is 0.25 ms of actual propagation each way; real routing makes it 2–5 ms. **The
internet is not the problem. The computers are the problem.** Ninety-seven percent of the delay is
sensor pipelines, encoder queues, compositors, and panel refresh — and almost all of it is queueing
that exists because nobody was holding a stopwatch.

This is the argument for leaving the browser. It is *not* an argument about networking, which is
where people usually look.

### The ladder

Same-metro, glass-to-glass, all figures engineering estimates to be measured rather than trusted:

| Stage | Web (tuned) | Native Android/iOS (tuned) | Appliance (chosen HW) | Floor (physics) |
|---|---:|---:|---:|---:|
| Sensor exposure + rolling-shutter readout | 15–35 | 6–10 | 4–6 | ~4 |
| ISP (demosaic, denoise, tone map) | *opaque, bundled above* | 8–12 | 3–5 | ~3 |
| Encode | 5–12 | 3–5 (slice-based) | 1–2 | ~1 |
| Packetize + send | 2–5 | ~1 | ~0.5 | ~0.3 |
| Network, one way | 8–25 | 2–5 | 2–5 | 0.25 |
| Jitter buffer | 15–40 | 5–8 | 2–4 | ~1 |
| Decode | 5–12 | 3–5 (slice-based) | 1–2 | ~1 |
| Display: compositor + panel | 8–25 | 8–12 (120 Hz, overlay) | 4–5 (240 Hz, direct scanout) | ~4 |
| **Total** | **60–150** | **~36–58** | **~18–29** | **~15** |

So: **~40 ms on tuned native. ~20 ms on an appliance. Sub-10 ms is not reachable** — the sensor alone
spends 4 ms integrating and scanning photons, and the panel spends 4 ms lighting them up. Physics,
not engineering.

### The two places the milliseconds hide

Everything above collapses into two costs that nobody optimizes:

**1. The camera pipeline (15–45 ms).** Android's Camera2 with a preview template runs 1–3 frames of
ISP pipeline depth. The gap between `SENSOR_TIMESTAMP` and the buffer actually reaching your code is
routinely 20–40 ms. Fixes: NDK camera, `CONTROL_MODE_OFF`, noise reduction and edge enhancement
disabled, `TEMPLATE_ZERO_SHUTTER_LAG` where available.

**2. The display pipeline (8–50 ms).** SurfaceFlinger normally costs 1–2 vsync periods — 16–33 ms at
60 Hz. Fixes: `SurfaceView` on a dedicated hardware overlay plane so composition is skipped entirely,
`SurfaceControl` transactions with explicit presentation timestamps, and a high-refresh panel. At
240 Hz a vsync period is 4.2 ms instead of 16.7.

Both are reachable on stock Android. Neither requires an OS.

### Two non-obvious levers

**High frame rate is a latency requirement, not a smoothness luxury.** Rolling-shutter readout time is
set by the sensor's configured line rate. A sensor running at 120 fps scans out in ~8 ms; at 30 fps it
takes ~33 ms. Same for display: 240 Hz costs 4.2 ms per frame where 60 Hz costs 16.7.

But 1080p120 at visually lossless quality is 35–45 Mbps, which breaks the bitrate budget. The
resolution: **configure the sensor fast, send slow.** Run the sensor at 120 fps and encode every
other frame — you keep the 8 ms readout and pay only 60 fps of bitrate. Readout latency is a function
of capture rate; bandwidth is a function of send rate. They're independent, and nobody separates them.

**Slice-based encode and decode.** Emit each slice as the encoder finishes it instead of waiting for
the whole frame, and start decoding on the first slice. Worth most of a frame interval at each end —
~10 ms round trip at 60 fps. Standard in broadcast contribution encoders, essentially absent from
consumer video calling.

### What an operating system actually buys

Honestly accounted, against *tuned* native rather than against typical apps:

| OS-level control | Saved vs. tuned native | Reachable on Android? |
|---|---:|---|
| No compositor — direct scanout | 4–8 ms | Mostly, via overlay planes |
| Full camera/ISP control | 4–8 ms | Mostly, via NDK camera |
| Hard real-time scheduling for the media thread | 3–6 ms *of buffer* | Partly, via `SCHED_FIFO` |
| Kernel-bypass networking | 1–3 ms | No |
| No queueing anywhere; one deadline end to end | *the conceptual win* | No |
| **Total** | **~12–25 ms** | **~70–80% of it** |

Real, and smaller than it looks — because the milliseconds live in the camera and the display, and
Android already lets you reach into both.

The scheduling row is worth reading carefully: real-time priority doesn't reduce *average* latency,
it reduces *variance*. But variance is exactly what forces the jitter buffer to be large, so it pays
out indirectly. On a system where the media thread genuinely cannot be preempted, the buffer can be
2 ms instead of 8.

**The honest case for the OS is not latency — it's the ability to promise a number.** On stock
Android you are one OEM's bad camera HAL away from 60 ms, and you cannot ship a consistent product
across a thousand devices. Controlling the hardware means the latency figure becomes a specification
instead of a hope. That is a genuine reason, and it is a *hardware* strategy wearing an OS costume.

### Recommended sequence

1. **Web (weeks).** Proves the perceptual thesis at 60–150 ms. This is the part nobody has done.
2. **Native mobile + desktop (months).** ~40 ms. A real, shippable product, and the natural home of §16.
3. **Appliance (12–18 months).** ~20 ms. Stripped Linux, own compositor and camera stack, chosen
   sensor and 240 Hz panel, known network. *Not* an OS written from scratch — a Linux you control
   completely, which gets the same number for a fraction of the work.
4. **Platform.** A consequence of a beloved appliance, never a starting point.

The load-bearing argument for this order: **the thesis is worth more than the latency, and the thesis
is the unproven part.** Plenty of people have chased milliseconds. Nobody has shipped a call that
refuses to degrade. Reaching 60 ms with genuinely zero artifacts is a product nobody has; reaching
20 ms with artifacts is a faster version of what already exists. Step 1 is also the only step where
being wrong is cheap — and if the thesis doesn't land at 60 ms, no amount of hardware saves it.

A note on sequencing generally: every well-engineered OS of the last twenty years — Windows Phone,
webOS, Sailfish, Firefox OS — died to the application gap rather than to any technical shortcoming.
The path that has actually worked is app → beloved app → appliance → platform. AI compresses the
implementation time at every step, which is real leverage; it does not compress the sensor's readout
time or the panel's refresh interval, and those are what set the floor.

---

## 19.2 The floor, honestly — is 5 ms reachable with software alone?

**No. On commodity hardware the floor is ~30 ms, and software gets you there. 5 ms is a hardware
bill-of-materials plus a LAN, not a software achievement.** Both halves of that matter, so here is
the full accounting.

I also need to correct §19.1: I put the physics floor at ~15 ms. That is the floor for *buyable
consumer hardware*. With machine-vision sensors and 500 Hz panels the device floor is ~5–6 ms — so
the constraint was never physics in the abstract, it was the hardware in the room. That distinction
changes the decision, which is why it's worth stating plainly.

### Commodity hardware, maximally aggressive software

Every row assumes we own the entire stack and are willing to be extreme:

| Stage | Floor | What sets it | Software lever? |
|---|---:|---|---|
| Exposure | 4 ms | Photons must be integrated. 1/250 s = 4 ms, and that needs a bright room. In normal indoor light a consumer sensor wants 1/30–1/60 s. | Partly — we can force a short exposure and accept noise. **This is a lighting problem.** |
| Rolling-shutter readout | 8 ms | Sensor line rate, tied to configured fps. 120 fps ⇒ ~8 ms; 30 fps ⇒ ~33 ms. | **Yes** — select the highest fps mode the sensor exposes. |
| MIPI / USB transfer | 2 ms | USB2 UVC webcams add 5–10 ms; built-in MIPI cameras ~1–2 ms. | No. Prefer built-in cameras. |
| ISP | 2 ms | Demosaic, denoise, tone-map pipeline depth. | **Yes** — disable NR and edge enhancement, minimize stages. |
| Encode | 2 ms | Frame-based HW encoders cost ≥1 frame (16 ms at 60 fps). Slice-based or intra-only costs ~2 ms. | **Yes — biggest single lever.** |
| Network, one way | 3 ms | Same metro. Physics. | No. |
| Jitter buffer | 3 ms | Must cover real network jitter. | **Yes** — RT scheduling shrinks the variance it has to cover. |
| Decode | 2 ms | Same as encode. | **Yes** — slice-based. |
| Compositor + panel | 5 ms | 120 Hz panel with front-buffer present. 60 Hz costs ~10 ms. | **Yes for the compositor** (direct scanout). No for the panel. |
| **Total** | **~31 ms** | | |

On a 60 Hz laptop this lands at ~36 ms. So: **software takes you from today's 60–150 ms to roughly
30 ms — a 2–5× improvement — and then stops.**

### What's actually below 30 ms, and what it costs

| To get | You need | Cost |
|---|---|---|
| 31 → 21 ms | Global-shutter sensor, short exposure without noise | Custom camera module; bright, controlled lighting |
| 21 → 18 ms | 500 Hz+ panel | Exotic display |
| 18 → 13 ms | Dedicated/controlled network — jitter buffer to ~0.5 ms | Not the public internet |
| 13 → **6 ms** | **JPEG XS** or similar line-latency mezzanine codec instead of AV1 | **200–300 Mbps per stream** |

That bottom row is the real answer to "is 5 ms possible." It is — and it already exists. Live
broadcast production runs SMPTE 2110 with JPEG XS over 25 GbE and hits ~5 ms glass-to-glass every
day. It is a genuine, shipping engineering regime.

It is also, definitionally, **an on-premises product.** At 200–300 Mbps per stream on a controlled
network, "video calling" means same building.

### The constraint that ends the discussion

Fiber carries light at ~200,000 km/s. Great-circle Mumbai↔London is 7,200 km, and real routing is
1.5–2× that:

```
Mumbai ↔ London     ≈ 110 ms RTT, minimum, forever
New York ↔ London   ≈  70 ms
San Francisco ↔ NY  ≈  60 ms
same metro          ≈   2–5 ms
```

No operating system, codec, or amount of engineering moves those numbers. **Sub-10 ms video calling
is same-city by definition.** Any product promising 5 ms is either local or lying.

The useful reframing: latency is not one number to minimize, it's two regimes with different physics.
Same-metro is device-bound, so engineering wins. Intercontinental is speed-of-light-bound, so
engineering is irrelevant and the *thesis* — never degrading — is the only thing you can still
compete on. That's an argument for building the thesis first regardless of the latency ambition.

### So: custom software, yes. Custom kernel, no.

Of the ~120 ms software can remove, here's what actually requires owning the OS:

| Lever | Saving | Needs a custom OS? |
|---|---:|---|
| Don't render through `<video>` | 30–100 ms | No — works in the browser today |
| Slice-based encode/decode | 10–25 ms | No — native app |
| Camera: highest-fps mode, minimal ISP | 10–20 ms | No — NDK Camera / V4L2 / AVFoundation |
| Direct scanout, skip the compositor | 8–25 ms | Mostly no — Android overlay planes, `CAMetalLayer`, Linux DRM/KMS |
| Real-time scheduling for the media thread | 3–6 ms *of variance* | Partly |
| Front-buffer / tear-allowed present | 4–8 ms | Linux DRM yes; Android/iOS no |
| Kernel-bypass networking | 1–3 ms | Yes |
| **OS-only total** | **~5–10 ms** | |

**A native app on a normal OS reaches ~35–40 ms. A custom OS reaches ~30 ms. The OS is worth 5–10 ms.**

And the counterintuitive part, which is the most important thing in this section: **for lowest latency
you want the most mature driver stack you can get at the lowest layer, not a new one.** A
from-scratch kernel means writing camera, GPU, and display drivers — and immature drivers *add*
latency and, worse, add jitter, which forces a bigger buffer and costs you more than the compositor
bypass saved. You would spend two years to end up slower.

The right target is **Linux with DRM/KMS direct scanout, V4L2 straight off the sensor, RT-scheduled
media threads, and no compositor** — owning the compositor, the scheduler, and the entire media path
while inheriting a decade of driver work. That is what a game console and a car dashboard are, and it
is genuinely "custom software": you control every line that touches a frame. You just don't write the
part where mature code already beats anything new.

Concretely, ranked by milliseconds-per-unit-of-effort:

1. **Native app, slice-based codec, direct scanout, tuned camera** → ~40 ms. Months. This is 90% of
   the available win.
2. **Linux appliance, own compositor, RT scheduling** → ~30 ms. Adds a year. Worth it only if you
   also control the device.
3. **From-scratch kernel** → slower than #2 until the drivers mature. Not recommended at any point.
4. **JPEG XS on a LAN** → ~6 ms. A different product for a different customer.

---

## 19.3 What if we rewrote every piece of software in the pipeline?

**~31 ms → ~18 ms on commodity hardware.** Two techniques deliver almost all of it, and both cost you
a platform.

The exercise: for every stage, split its latency into software we could replace, firmware/silicon we
can't, and physics. Then rewrite everything in column one.

| Stage | Naive | Rewritten | What we replace | Hard floor |
|---|---:|---:|---|---|
| Exposure | 16 ms | **4 ms** | Force 1/500 s and undo the noise with our own GPU/learned denoiser instead of buying clean pixels with time | ~1 ms of photons + ~2 ms denoise |
| Rolling-shutter readout | 8 ms | **1.5 ms** | **Stripe processing** — CSI-2 delivers lines; stop batching them into a frame | Sensor *line* rate, not frame rate |
| MIPI / USB transfer | 1–2 ms | 1 ms | Nothing — it's a bus | ~1 ms |
| ISP | 2–5 ms | **1 ms** | Bypass the hardware ISP; demosaic on GPU in stripes | ~0.5 ms |
| Encode | 16 ms | **1.5 ms** | Custom GPU intra-only stripe codec | ~0.3 ms/stripe |
| Network stack | 1–2 ms | **0.3 ms** | Kernel bypass (AF_XDP), no syscalls, no copies | syscall-free ≈ 0 |
| Propagation (same city) | 3 ms | 3 ms | Nothing | Physics |
| Jitter buffer | 15 ms | **2 ms** | RT scheduling everywhere, so the buffer covers only *network* jitter, not ours | Network jitter p99 |
| Decode | 12 ms | **1 ms** | Same custom stripe codec | ~0.5 ms |
| Compositor | 8–25 ms | **0 ms** | Delete it. DRM/KMS direct scanout. | 0 |
| Display present | 8 ms | **3 ms** | **Beam racing** — write scanlines just ahead of the beam instead of waiting for vsync | Pixel response ~1 ms |
| **Total** | **~90 ms** | **~18 ms** | | **~10 ms** |

### The two techniques that actually matter

Everything else on that list is worth 1–2 ms. These two are worth ~20 ms between them, and neither is
exotic — both are standard practice in adjacent industries that nobody has brought to video calling.

**1. Stripe processing (worth ~12 ms).** The entire conventional pipeline is frame-shaped: wait for a
whole frame to read out, hand the whole frame to the ISP, hand the whole frame to the encoder, send.
That's four full-frame waits. But a MIPI CSI-2 sensor delivers *lines*, and a codec can work on
16-line stripes. Process in stripes and the frame boundary stops existing as a latency event —
readout, ISP, and encode all collapse from "one frame" to "one stripe." This is how broadcast
contribution encoders hit sub-frame latency, and it's the single biggest software win available.

**2. Beam racing (worth ~5 ms).** A display doesn't show a frame, it paints scanlines top to bottom.
Normally you render into a back buffer and wait for vsync to flip — costing up to a full refresh
period. Instead, race the beam: write pixels into the scanline region just before the hardware reads
it. Emulator and VR developers do this routinely. At 120 Hz it turns 8 ms into ~3 ms.

### What each rung actually costs you

| Target | What it takes | Effort | Where it runs |
|---:|---|---|---|
| 31 ms | Native app, slice-based HW codec, tuned camera, overlay-plane present | Months | Any OS |
| 24 ms | + stripe camera pipeline, beam racing, RT scheduling, kernel bypass | ~1 year | **Linux only** — Android/iOS won't give you pre-frame camera data or the scanout |
| 18 ms | + custom GPU intra-only stripe codec | Multi-year | Linux, **and 100–300 Mbps** |

That bottom row is the catch, and it's the same wall as §19.2: **a sub-millisecond codec means
intra-only, and intra-only means 100–300 Mbps.** Getting low latency *and* a sane bitrate means
implementing inter-frame prediction yourself — which is not "rewriting a component," it's founding a
codec company. Hardware H.264/AV1 encoders represent thousands of engineer-years and they are
genuinely excellent.

### The cost nobody counts

Every rewritten component is one you now maintain, and it starts out **less mature than what it
replaced**. That matters here in a specific way: immature code has worse *variance*, and variance is
what sets the jitter buffer. A custom codec that's 1 ms faster on average but 4 ms jitterier makes the
call **slower**, because the buffer has to grow to cover it.

So the rewrite has to be judged on p99, never on mean. Several of the wins above are real only if the
new code is also *more predictable* than the old — which for a first implementation is a strong claim.

### The verdict

Rewriting everything is a real 13 ms on top of a well-built native app, and the path is legitimate
engineering rather than fantasy. Two caveats decide whether it's worth doing:

**It only matters locally.** At 18 ms same-city you are 15 ms above the speed-of-light floor for that
route. On an India↔Europe call the same total rewrite takes you from 130 ms to 117 ms — 13 ms out of
130, because 55 ms of it is light in glass and most of the rest is unchanged. **The full rewrite is a
same-city product feature.**

**The order doesn't change.** Every technique above sits *behind* the browser build, because none of
them tests the thesis. Stripe processing and beam racing are how you go from good to extraordinary;
they are not how you find out whether a call that refuses to degrade is something people want. Build
§19's phase 1–2 first, then come back here — the techniques will still be sitting there.

---

## 20. Footnote: recording, later

Deprioritized, but worth one paragraph because the architecture makes it nearly free — and it's
useful to know the door is open before decisions foreclose it.

The only difference between live media and recorded media, in this design, is the delivery deadline.
**Decided 2026-08-01 — the tee point is the frames, not the chunks.** The earlier sketch teed the
same `EncodedVideoChunk`s to the archive, but that couples the recording to the wire's infinite GOP
(§6): a one-keyframe archive is a recording you cannot seek, which is barely a recording. So: the
wire keeps its infinite GOP untouched (the §6 congestion argument is load-bearing), and the archive
tees the `VideoFrame`s *before* the encoder into its own low-priority encoder with a conventional
periodic GOP and a cheaper QP. Hardware encoders on target hardware run multiple concurrent 1080p
sessions, and the priority rule is the design's own spine applied one level down: the archive
encoder drops its own frames under CPU pressure — the archive degrades, the call never does. OPFS
write-ahead buffer, resumable multipart upload to R2 at idle priority behind lanes A and B. It's
pristine even when the live path stalled, because the archive path is reliable where the live path
is prompt. Since the two sides' streams share a session clock, stitching is sample-accurate
metadata, not processing, so the file is ready the instant the call ends. And because each
speaker's audio is a separate mono track by construction, **speaker diarization is perfect for
free** — a property no post-hoc transcription pipeline can match.

One decision here is worth noting now: recording would argue for periodic keyframes (seek points),
which §6 rejects on latency grounds. The resolution is to keep infinite GOP on the wire and insert
keyframes only in the archive sink — but this is exactly the kind of coupling that's cheap to build
in and expensive to retrofit. Worth 20 minutes of thought before phase 2 freezes the encoder config.

---

## 21. Load-bearing citations

Every number in this document that a subsystem depends on, with a source. If any of these are wrong,
the sections listed alongside them are wrong too.

| Fact | Used by | Source |
|---|---|---|
| Face-to-face turn transition **297 ms**; over Zoom **976 ms** | §0, §1.1c, §3.1 — the core product argument | Boland, Fonseca, Mermelstein & Williamson, "Zoom disrupts the rhythm of conversation," *J. Exp. Psychol. General* (2021). [PubMed](https://pubmed.ncbi.nlm.nih.gov/34748361/) · [APA](https://psycnet.apa.org/doiLanding?doi=10.1037%2Fxge0001150) |
| Cross-linguistic turn gap **~200 ms** | §1.1c | Stivers et al., "Universals and cultural variation in turn-taking in conversation," *PNAS* 106(26):10587–10592 (2009). [DOI](https://pnas.org/doi/10.1073/pnas.0903616106) — verified 2026-08-01: overall median gap ~200 ms across ten languages (range ~0 ms Japanese to ~470 ms Danish) |
| Pre-speech inhalation leads phonation by **~200 ms**; pre-turn inhalations are longer than within-turn | §1.1c-2, §3.1 lever 1, §4 Lane 0 | Włodarczak & Heldner, "Respiratory turn-taking cues," *Interspeech* (2016). [PDF](https://www.isca-archive.org/interspeech_2016/wodarczak16b_interspeech.pdf) · [Breathing in Conversation, *Front. Psychol.* (2020)](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2020.575566/full) |
| Four fatigue mechanisms; self-view correlates with fatigue | §1.1, §15 | Bailenson, "Nonverbal Overload," *Technology, Mind & Behavior* 2(1) (2021). [DOI](https://doi.org/10.1037/tmb0000030) — verified 2026-08-01: the four mechanisms are close-up gaze, elevated cognitive load, the all-day mirror (self-view), reduced mobility. ZEF scale: Fauville, Luo, Queiroz, Bailenson & Hancock, *Computers in Human Behavior Reports* 4:100119 (2021) |
| Audio-leading-video detectability threshold **~45 ms** | §3 — the free 45 ms | ITU-R BT.1359-1 |
| Credit card width **85.6 mm** | §1.1a, `fatigue-lab` calibration | ISO/IEC 7810 ID-1 |
| Conversational distance **~1100 mm** | §1.1a, §15 | Hall, *The Hidden Dimension* — personal distance |
| Refractive index of silica fiber ≈ **1.468** → 204,000 km/s | §0, §3.1 physics row | Standard |

~~**Two facts in this table have not been independently verified and should be before phase 2:**~~
Both verified 2026-08-01 against the primary sources (table rows updated): the Stivers 200 ms
figure is the paper's actual cross-linguistic median, and the Bailenson mechanism list is the
paper's actual four. Both remain supporting rather than load-bearing — §3.1's argument is
anchored on Boland's measured pair.

**One quantity in this document is derived, not measured, and the design leans on it hardest:** the
cue damage behind Boland's unexplained residual (§1.1c). It is ~609 ms once their own measured
transmission delay is used; how much of it is recoverable is **unknown and unmeasured**. This
document previously stated it as "179 ms," which was both wrong and falsely precise. See the risk
entry in §17.
