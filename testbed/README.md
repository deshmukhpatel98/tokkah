# testbed — running real conversations through the real app, with no humans

The app measures turn-taking. To trust the measurements you have to know what the right
answer was, and for that you need a conversation you built yourself. This directory
builds one out of real recorded human speech, plays it into two real browsers as if it
were their microphones, and scores what comes out against what went in.

Nothing here is a mock. Real speech goes through real `getUserMedia`, real Opus, a real
peer connection, a real jitter buffer, and the app's real detectors. The only thing that
isn't real is that nobody is in the room.

## Why this exists

The alternative was to wait for a live call and hope. Two things made that a bad plan:

- **Synthetic tones can't test a breath detector.** The whole design rests on hearing a
  pre-speech inhale. A sine wave doesn't have one. Neither does white noise. You need a
  real person's real intake of air, and you need to know exactly where it is.
- **A live call happens once.** Anything you get wrong, you get wrong permanently. Five
  real bugs turned up here, two of which would have turned a live call into garbage that
  looked like a quiet room.

The unlock is one Chrome flag:

```
--use-file-for-fake-audio-capture=file.wav
```

Chrome treats the file *as the microphone*. Everything downstream is the real path.

## The pieces

| File | What it does |
|---|---|
| `probe.mjs` | Confirms the fake-mic flag actually reaches `getUserMedia`, and reports what Chrome's fake device claims about sample rate and channel count. Run this first on a new machine. |
| `corpus.mjs` | Finds real breaths and real utterances in LibriSpeech. Writes `media/corpus.json`. |
| `mkconv.mjs` | Assembles `media/conv/{A,B}.wav` plus `truth.json` — a two-sided conversation with every turn boundary, breath, and gap recorded. |
| `call.mjs` | Runs two headless browsers through a real call using those WAVs, and saves everything to `runs/`. |
| `score.mjs` | Scores a run against `truth.json`. This is the file that can say the design doesn't work. |
| `floor.mjs` | Diagnostic: runs the *shipping* detector on a fake-mic stream and prints its noise floor, SNR and state over time. For when a detector misbehaves and the code doesn't explain why. |
| `netsim.mjs` | Emulates distance: a UDP delay line in front of a TURN relay we run ourselves, with delay, jitter, loss and reordering. Run it directly to check the relay path carries UDP before trusting it in a call. |
| `sweep.mjs` | Reads several runs side by side as a function of emulated distance. Answers the one question a single run cannot: does our own cost stay put as the network gets longer? |

## Running it

Requires the tape-app dev server on `:8794` (`preview_start` with the `tape-app` config,
or `npx wrangler dev` in `../tape-app`).

```bash
node probe.mjs                       # sanity: does the fake mic work at all
LIMIT=60 node corpus.mjs             # find breaths — 22 breaths, 54 utterances from 60 clips
node mkconv.mjs                      # build the fixture + ground truth
node call.mjs --tag=baseline         # our config: AEC, NS, AGC all off
node score.mjs runs/baseline-<room> --verbose
```

The comparison arms:

```bash
node call.mjs --ns                   # AEC + NS + AGC forced on — what everyone else ships
node call.mjs --relay                # force media through a TURN relay
node call.mjs --url=https://…workers.dev   # against real Cloudflare instead of localhost
```

And with an emulated network:

```bash
node call.mjs --tag=d160 --rtt=160                       # 160 ms RTT, otherwise clean
node call.mjs --tag=jl --rtt=160 --jitter=30 --loss=1    # and a bad link
node call.mjs --tag=jl --rtt=160 --loss=1 --trace        # …with the full 20 Hz level trace
node sweep.mjs                                           # read them all side by side
```

`--rtt` is the round trip you want ICE to measure. `netsim.mjs` halves it, because a packet
crosses the delay line twice on its way from one browser to the other, and reports what ICE
*should* therefore see — if the measurement disagrees, the emulator is wrong rather than the
app. Measured agreement across the sweep: 20 → 22, 80 → 82, 160 → 163, 240 → 244 ms.

`--trace` raises the level trace from the default 4 Hz to the worklet's full 20 Hz. Worth
knowing about: at 4 Hz a jitter-buffer underrun falls between samples, so a floor that is
briefly wrong looks like a floor that was never wrong. That decimation hid the cause of the
worst bug this harness has found.

`--ns` and `--relay` work by overriding `getUserMedia` / the ICE policy in an init script,
*not* by editing the app. Both arms run byte-identical application code, so a difference
in result can't be a difference in the app.

## What the fixture guarantees

`truth.json` records, for every turn: which side speaks, whether a real inhale was planted
in front of it, the sample-exact time of the inhale and of the first word, the lead between
them, and where the turn ends. `expected[]` records what a listener should measure —
time-to-first-evidence and time-to-first-word for each transition.

Two things keep this honest:

- **The fixture checks itself.** `mkconv.mjs` measures the audio it just rendered and
  verifies the planted markers land where it says they do. A fixture that quietly drifts
  would make every downstream number wrong in a way that looks like success.
- **The breath finder is independent of the detector.** `corpus.mjs` locates inhales using
  absolute dBFS windows, zero-crossing rate, spectral centroid and plain autocorrelation —
  deliberately *not* the app's algorithm. Otherwise "the detector finds the breaths" would
  be confirmed by "the detector found the breaths."

## What the score means

`score.mjs` asks five questions, each with a known correct answer:

1. **Turns detected** — every planted turn, on the right side, no misses.
2. **Onset timing error** — how far off the detector was about when speech began.
3. **Real inhale kept, local vs remote** — the one the design lives on. The same inhale is
   observed twice: at the mic that produced it, and at the far machine after Opus, the
   network, the jitter buffer and decode. A high local rate with a low remote rate means
   the breath is captured and then destroyed on the wire, which is a transport finding and
   cannot be hidden by local success.
4. **Breath lead error** — the reported head start versus the planted one. Negative is the
   safe direction: under-reporting a head start costs accuracy, over-reporting flatters the
   design.
5. **Gap accuracy, cross-checked between machines** — see below.

### The mouth-to-ear number

Both gap measurements are taken entirely on one machine, so neither needs clock sync:

- **human gap** = *I* see their turn end → *I* start speaking. Their transit time is
  already inside "their turn end", so what's left is pure human response time. This is the
  number that compares to Boland's 297 ms face-to-face control.
- **perceived gap** = *I* stop speaking → *I* hear them start. This one contains a full
  round trip, correctly, because that is what I actually sat through. Compares to 976 ms.

Subtracting them *across the two machines* cancels the humans — same person, same turn —
and leaves only transit:

```
my perceived − their human = delay(me→them) + delay(them→me)
```

Two independent estimates fall out, one per direction, and they have to agree. Doing this
across machines rather than within one is what makes it valid: the within-machine version
compares my response time to theirs and only reconciles if two different people answer at
the same speed. Across machines, nothing about the humans is assumed.

This also measures something ICE does not. ICE times a STUN ping; this times audio through
encode, packetisation, the jitter buffer, decode and playout. On a loopback link ICE reads
zero and this does not, and the difference is what the stack costs on its own.

## Results on the baseline fixture

14 turns, 11 with a real inhale, four detectors observing (local + remote on each side):

- **28/28 turns detected**, zero misses
- **onset timing error median 0 ms**, spread −6 to +6 ms
- **real inhale kept: 100% at the mic and 100% at the far end** — §3.1 lever 1 survives
  capture, Opus, the network, the jitter buffer and decode
- **lead error always negative** (−5.7 to −11.7 ms) — under-reports, the safe direction
- **mouth-to-ear round trip 117 ms on a zero-RTT link** — two independent estimates
  agreeing to 0.0 ms. All 117 ms is self-inflicted: 58 ms each way through our own stack,
  before any network. The 31 ms playout buffer is the largest single piece.

## Results across emulated distance

| emulated RTT | ICE RTT | mouth-to-ear | our cost each way | head start at far end |
|---|---|---|---|---|
| 0 | 0 | 117 | 58 | 216 |
| 20 | 22 | 109 | 44 | 191 |
| 80 | 82 | 169 | 43 | 206 |
| 160 | 163 | 263 | 50 | 186 |
| 240 | 244 | 383 | 70 | 196 |

The head start is **flat across a quarter second of added path** — 186 to 216 ms at every
distance, against 229 ms planted, with zero freezes and zero lost packets. That is the property
the design needs from §3.1 lever 1, and it is the strongest result here.

Adding 30 ms of jitter and 1% loss to the 160 ms link is a different story, and it produced the
worst bug the harness has found: the received-side head start went to a 2076 ms maximum with
38% of values larger than anything the fixture plants. The cause was a noise floor chasing
jitter-buffer underruns 6 dB below the room; after the fix, the same call reports zero
impossible values and a 286 ms maximum. DESIGN.md §17.1 has the full derivation, including the
first mechanism I proposed for it, which the data refuted.

### What the emulator can and cannot claim

Real UDP datagrams, real ICE relay candidates, real TURN allocation, and delay/jitter/loss
applied to the actual media path. Not a real internet path: no cross-traffic, no bufferbloat,
no route changes, no MTU discovery, no NAT rebinding. **It emulates distance, not the
internet.**

Two deliberate choices. Interface shaping (`tc`, `dnctl`, `pfctl`) all need root, and asking
for a password to run a test is a worse trade than fifty lines of UDP forwarding. And the
relay is local because a public TURN server would put real conversation audio through a third
party — the point of a harness is that nothing leaves the machine.

## What it still can't tell you
- **No acoustics.** The fake mic is a file, so there is no room, no echo path, and no
  reason for echo cancellation to have anything to do. A real call has all three.
- **One run per distance.** The sweep's own-cost estimate ranges 43–70 ms with a single run
  at each point, which is enough to establish a floor and not enough to establish a trend.
  `sweep.mjs` says so rather than drawing a line through it.
- **Read speech, not conversation.** LibriSpeech is someone reading a book. Real turn-ends
  have creaky voice, trailing pitch and hesitation that read speech mostly lacks — which
  makes this a *conservative* test of turn-end prediction, but not a representative one.
- **Planted gaps are constant.** Real response times vary from 0 to 2 seconds and overlap
  constantly. The fixture's regularity is what makes scoring possible and is also why the
  gap medians here shouldn't be read as human behaviour.

## Known characteristics that are not bugs

- **A turn can split at a long internal pause.** Read speech has sentence pauses longer
  than the detector's 350 ms hang time. Splitting is the correct response to 400 ms of
  silence; it just means one planted turn shows up as two detected ones.
- **Roughly 1 in 3 turns planted *without* a breath still gets called a breath.** The
  classifier is biased that way on purpose: a false positive costs one 60 kbps datagram, a
  false negative costs 200 ms.
- **404s in the console are benign.** A favicon and a source map. `netFails` is the field
  that matters, and it's empty.
