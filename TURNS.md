# Turn-taking: one voice at a time, and nobody lost

The whole design in one paragraph. On speakers, two open microphones is two
microphones each recording the other's loudspeaker. Every product that has tried
to fix that afterwards has done it by processing the voice until it survives being
cancelled, and that processing is the underwater, robotic sound of a video call.
Kin does not process the voice ([[pure-mic-is-the-product]]). It decides whose
turn it is.

A rule like that is only kind if the other person is never **lost** while it is in
force. Most of this file is about that half.

Verified on live two-process calls with real recorded speech, 2026-08-25. Every
number below was measured, not intended.

---

## 1. The gate: what actually happens to the audio

`Audio.DuplexGate.process`, `Audio.swift`. Runs in the capture callback, per
block, and touches nothing else.

It compares the near microphone's peak envelope against the echo it EXPECTS from
what the speaker is currently playing (`coupling × farEnv`), with a margin that
relaxes as the room couples harder — because in a room where the microphone sits
inches from the speaker, a generous margin sits above an ordinary speaking voice
and gates the person mid-sentence. Leaking some echo is a worse call; being cut
off is an unusable one.

    while only they are talking, the microphone is 19.3 dB quieter
    while you are talking, the worst sample differs by 0.0001% — untouched

The second line is the product. Your voice is bit-for-bit what the microphone
heard, at every block size, in every room the rig simulates.

**The gate opens on VOICE, not on the verdict.** Waiting for the classifier to
decide between a continuer and a bid means holding the microphone down through the
first 700 ms of somebody's sentence — a test that asserts the near voice is
untouched catches that immediately: 92% of the worst sample, gone.

### Every constant is a time

`nearEnv * 0.93`, `floor += … * 0.002`, `coupling * 1.00002`, `run >= 2` — all of
them were per BLOCK, tuned at the rig's 128 samples. CoreAudio hands this app
**16**. Every one ran eight times too fast; the noise floor reached the level of
the speech in 170 ms and the classifier could not physically produce a bid.
`dt = n / SR` at the top of `process`, and everything derives from it
([[per-block-constants-hide-block-size]]).

The floor also rises **only while nobody is talking** — a noise tracker that
follows speech is not a noise tracker — with a 60 s creep during voice so a
genuinely loud room can still lift it instead of latching the detector on forever.

---

## 2. The classifier: a listening noise, or a bid

    quiet ──(4 ms of continuous voice)──▶ backchannel ──(700 ms)──▶ claim
      ▲                                                              │
      └──────────────(450 ms of CONSECUTIVE silence)─────────────────┘

The difference between a continuer and a bid is duration and nothing cleverer. A
continuer is over before a word would be; wanting the floor takes longer, because
you have to start saying something. The threshold is generous on purpose:
mistaking a bid for a continuer costs a person their turn, mistaking a continuer
for a bid costs a cue that was going to disappear anyway.

Two things that were wrong and are load-bearing:

- **Wall clock, not voiced-block counts.** A bid is "you have been talking for
  700 ms", not "700 ms worth of blocks were above the bar". Ordinary speech is
  voiced maybe half the time at a third of a millisecond's resolution, and the
  other half was being counted as silence — so the silence threshold was reached
  before the voice threshold, every time.
- **Silence has to be CONSECUTIVE.** Accumulating every quiet block since the
  vocalisation began adds up the gaps between syllables and ends a turn in the
  middle of a sentence.

A listening noise is counted on the way **out**, not the way in: every
vocalisation begins as a continuer, so counting at `promote(.backchannel)` scored
one "listening noise" for every sentence anybody ever said.

---

## 3. Three ways to reach the quiet side

`Cues.swift`. Three channels at three speeds, and the speeds are the reason all
three exist. A cue with no words leaves you guessing what they want; words with no
cue arrive after you have already talked over them.

| | what | how fast |
|---|---|---|
| **floor cue** | three breathing dots → one lit bar | one hop, then 100 ms to be unmistakable |
| **rim** | the window's edge glows, bids only | same |
| **caption** | their words, running, revised | ~260 ms of speech + recogniser + hop |
| **bloom** | the listening noise itself, as a word | with the caption |

**Nothing in the cue layer uses a word to tell you what to do.** Reading competes
with listening — same language machinery, already busy parsing the sentence
somebody is saying to you — so a badge reading "wants to speak" would spend the
attention it was trying to protect, which is the mechanism behind call fatigue
this app exists to remove. Size, motion and colour are not language.

The rim exists because the pill above the caption is a LOCAL marker and you have
to be looking near it; the moment somebody starts to speak is the moment your eyes
are on their face. The edge of the visual field is the one place always in view,
and peripheral vision is poor at detail and excellent at change.

### The carrier, which was the whole latency

The floor state rides the status byte at `TPKTX + 6`, and the only packet with a
TPKTY payload is the **time probe** — which settles to once a second. A cue whose
entire claim is that it lands inside a syllable was arriving up to a second late,
and on a live call it drew a listening noise through six seconds of somebody
talking. The comment above it said *"read at packet time, not once a video
frame"*: true about the read, silent about the delivery
([[fast-signal-on-a-slow-carrier]]).

The probe thread's sleep is sliced at 20 ms and ends the instant the
classification moves. Edge-triggered for speed, 1 Hz level-triggered for repair,
so a dropped edge costs a second of staleness rather than a state that is wrong
for the rest of the call. **Measured on loopback with both ends stamping wall
clock: every transition crosses in 0–1 ms.**

---

## 4. Words, from the machine that heard them

`Subtitles.swift`. The audio never travels. The quiet side's own machine still
holds their microphone at full quality — the gate turns it down on the way to the
wire, it does not stop capturing — so recognition happens there and only the TEXT
crosses. A few dozen bytes against a few dozen kilobytes, and no round trip inside
the loop that has to keep up with a person talking.

Two engines behind one surface. **The system recogniser is the default**, because
it is on every Mac running macOS 26, needs no daemon, no 2 GB download and — this
was the surprise — no permission prompt: `SpeechAnalyzer` with
`.volatileResults + .fastResults` runs on-device and never moves
`SFSpeechRecognizer.authorizationStatus()` off `notDetermined`. `--asr qwen`
selects local Qwen3-ASR at `127.0.0.1:8789`, which also returns smart-turn's
completion probability in the same response: ~85 ms for the words, ~13 for the
prosody.

### The models were never the problem

Measured against LibriSpeech ground truth, same audio, same machine:

| | word error |
|---|---|
| Apple, on-device | **3.0%**  (4 runs: 3.0, 27.8, 3.0, 3.0) |
| Qwen3-ASR, as Kin was streaming it | 39.6%  50.3%  (and 46.2, 50.9 on an earlier source) |
| Qwen3-ASR, handed whole utterances | **3.0%** |

**Read the spread, not the best run.** Four IDENTICAL Apple arms scored 3.0,
27.8, 3.0, 3.0 — so this rig's own noise is 25 points, and any comparison worth
less than that cannot be made here at all
([[measure-the-rigs-noise-first]]). The engine gap is far larger than the noise,
which is the only reason the conclusion below is safe. A smaller question — what
the cleaner costs, say — has to be asked of the signal instead.

**The two models are identical and the whole 47-point gap was this app's
streaming of the daemon.** Which is worth saying plainly, because for weeks the
transcript was bad and the model was the obvious suspect. Three defects were
hiding in the plumbing:

- **The resampler was eating the consonants.** Four cascaded one-poles is
  24 dB/octave from 3.5 kHz — −8.7 dB at 6 kHz, and only −15 dB at 9 kHz, so what
  it failed to remove folded back on top of the speech. `s`, `sh`, `f` and `t` are
  told apart in exactly that band. Now a 95-tap windowed sinc, and
  `--decimator-test` measures the filter against a swept tone instead of trusting
  the transcript. ([[validate-the-ruler-against-known-inputs]] — the old filter was
  run through the new ruler first, to prove the ruler could see the difference.)
- **Smart-turn was thresholded against a continuous stream**, so it chopped read
  speech into fragments every 1.2 s: *"Mr. Quilter is the." / "Cool." / "Matter."*
  — 85.8% word error out of a recogniser that scores 3.0%.
- **`/health` returns 200 while the daemon is still importing.** `ready` decides
  now, and an engine that answers six times with nothing is deserted mid-call
  whatever it claimed at startup.

**A sentence ends when it lands, and only at a pause.** Waiting for the 450 ms of
silence that ends a vocalisation made a long turn grow into a paragraph — the
recogniser handed a longer window every time and the caption never committed.
Smart-turn hears the difference between a sentence that landed and one that
trailed off, which no transcript can recover — but it has to be ASKED AT A PAUSE:
a 220 ms breath, shorter than the 450 that ends a turn and longer than a plosive,
with 1.5 s of material behind it, and a 12 s cap so a monologue still commits.

The microphone on the quiet side also hears the far end off the speaker, so the
chunk is cleaned before recognition (`Audio.SubtitleCleaner`, spectral
over-subtraction). That is acceptable HERE and nowhere else in this app: the
output is text, and nobody listens to it.

**This now works on any Mac that installs Kin**, which was not true a day ago and
was the single largest gap in the feature ([[feature-behind-a-flag-nobody-runs]]).
The Qwen daemon stays a LaunchAgent on the developer's Mac, opt-in, and is still
the only way to get smart-turn; on a Mac older than 26 with no daemon the app says
so once and everything else works unchanged — the gate, the cues, the rim, the
deadlock rule.

---

## 5. The deadlock rule

`Audio.Yield.shouldYield`. The one place in this app that acts on a person's audio
because of a judgement about a conversation.

    under 450 ms of overlap ─────────────────────────────▶ nothing happens
    past it, they started >150 ms earlier ───────────────▶ this end gives way
    past it, this end started >150 ms earlier ───────────▶ this end does not
    past it, within 150 ms ──────────▶ ledger owed > 0.35 decides
    ledger owed > 0.6 ──────────────────────────────────▶ gives way regardless

The 150 ms band is a refusal, not a gap. This end sees its own start the instant
it happens and the far end's a hop later, so inside that window the ordering is
the network's opinion and not a fact — the same undecidability that stopped yield
attribution ever being reported from one end
([[directional-property-measured-at-wrong-end]]).

An even conversation with two simultaneous starts is genuinely undecided, and
inventing a winner there would be the app talking over somebody on a coin toss.

Both ends run this against **mirrored ledgers** (`--ledger-test` asserts they sum
to zero), so a deadlock resolves with no negotiation and no round trip. When the
network makes them briefly disagree the failure is symmetric and self-clearing:
both duck for a moment, or neither does.

### A duck, not a mute

    the duck settles at        -9.0 dB
    ... and it is never a mute  0.355 gain
    it lets go after            172 ms

Nine decibels is unmistakable to the person listening and still leaves you audible
if you carry on. A mute costs somebody their sentence when the decision is wrong,
and it will sometimes be wrong.

It is also the only thing that stops a sustained collision leaking echo: during
one, this end's microphone is carrying the far end's own voice off the speaker and
the gate is wide open, because you ARE talking.

**Live proof.** Two processes, two real recorded voices. A talks from the start
and never stops; B interrupts at three seconds and never stops.

    A: gave way 0 times
    B: gave way 1 time, 49.9% of the call

Exactly one side, and the one that interrupted.

### And the person who gives way is told

Their own words appear in the caption band, right-aligned, going out as text.
`audible` multiplies the gate by the duck — the gate is wide open during a
deadlock, so reading it alone said "you are being heard" at the exact moment
somebody most needs to know they are not.

---

## 6. What a call reports

Nothing here carries audio or words. Counts and durations only.

    floor_held_pct   turn_claims      turn_granted     turn_to_floor_p50
    turn_collisions  turn_collision_ms turn_yields     turn_yielded_pct
    turn_backchannels turn_escalated  turn_flaps
    turn_yielded     turn_peer_yielded turn_yield_unclear

The headline is **time to floor**: from the moment somebody wants to speak to the
moment they are actually audible. It is the "does this feel automatic" number and
it is the one to drive down.

`turn_yields` and `turn_yielded_pct` are published from BOTH ends so the server can
see whether the rule is splitting them evenly or picking on the same person every
call. `turn_yielded` / `turn_peer_yielded` stay **raw and one-sided** — who backed
down cannot be decided at one end, and nothing on screen claims to know.

---

## 7. The tests, and what each can and cannot see

| | asserts | blind to |
|---|---|---|
| `--gate-test` | 19.3 dB suppression, near voice bit-for-bit, a bid seen at 16 / 128 / 512 samples | anything on screen |
| `--ledger-test` | corrects a lopsided conversation, leaves an even one alone, two ends mirror | live timing |
| `--yield-test` | every clause and both refusals, −9.0 dB, 172 ms release, untouched before | the decision on real speech |
| `--cue-test` | bid unmistakable in 100 ms, ledger moves it, 900 ms fade, no clipped caption line, the 30 Hz layer stops | how any of it looks |
| `--subtitle-test` | the far end pushed far enough down to read past | the recogniser |
| `--headphone-test` | the bid IS seen over a talking far end, silence is NOT a bid, audio bit-for-bit untouched, a coupling learned on speakers cannot deafen it | how any of it looks |
| `--decimator-test` | ±1.5 dB from 300 Hz to 6 kHz, <−40 dB above 9 kHz, a chunk boundary is not a discontinuity | whether the recogniser agrees |
| WER vs LibriSpeech | which engine, and what the plumbing costs | anything conversational — it is read speech |
| `shoot.sh` | how it looks over a real face | anything that moves |
| two live processes | all of it | nothing — this is the one that found every defect above |

**The rig chose a parameter the product does not choose.** `--gate-test` ran at
128 samples because that is what somebody typed, and it stayed green through the
entire time the shipped classifier was dead
([[rig-picks-a-parameter-the-product-does-not]]). It sweeps now.

`KIN_GATE_DEBUG=1` prints the classifier's innards once a second;
`KIN_CUE_DEBUG=1` stamps every floor transition at both ends. A detector that will
not fire is not debuggable from its output.

---

## 8. Open

- **Smart-turn on a stock Mac.** §4. The system recogniser gives words to everyone
  but no completion probability, so on a Mac without the daemon a sentence commits
  on the 12 s cap or on the 450 ms that ends a vocalisation, never on prosody.
- **Non-English.** The system recogniser is locked to `en-US` here. It supports
  more; nothing has asked it to.
- **The retroactive buffer.** A continuer is audible today. Withholding one needs
  the samples held and released into the gap if it turns out to be a bid, or an
  interruption loses its first syllable.
- **Text-level echo dedup.** The cleaner is spectral; words from the far end can
  still survive it and land in this person's transcript under their name.
- ~~**Headphones.**~~ Fixed. The gate is off there and the whole feature was off
  with it; the classifier now always runs and only the two lines that touch
  samples ask about the route. See §1.
