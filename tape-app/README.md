# TAPE

A 1:1 video call built to test one specific claim, on a real conversation, without
either person having to do anything unusual.

**The claim** (DESIGN.md §1.1c): the reason video calls feel laggy is not mostly the
network. Boland et al. 2021 measured the same task face-to-face and over Zoom — turn
transitions took **297 ms** in person and **976 ms** on Zoom. Zoom's round trip only
explains about 500 ms of that 679 ms difference. The leftover **179 ms** is the
listener failing to *predict* when the other person is about to finish, because the
cues they'd predict from — the creak at the end of a phrase, the final syllable
stretching, the pitch falling, the inhale before the reply — are exactly what lossy
codecs, noise suppression, and echo cancellation throw away.

If that's right, a call that keeps those cues should show a human response time near
297 ms even though the network is unchanged. If it's wrong, this app will say so.

---

## Before the call

### 1. Deploy it. Localhost will not work.

This is the one thing that can't be worked around. Browsers only give a page camera
and microphone access over **HTTPS** (or on `localhost`, which only helps the person
sitting at that machine). Two people in different places on `http://192.168.x.x` will
both get a permission failure and there will be no call.

```bash
cd "tape-app" && npx wrangler deploy
```

That prints a URL like `https://tape-app.<your-subdomain>.workers.dev`. That's the
link to share.

### 2. Add a TURN relay (recommended)

Without it, the call only connects if both networks allow a direct peer-to-peer path.
Home wifi to home wifi usually works; anything involving mobile data or a corporate
network often doesn't. With Cloudflare Calls credentials the app falls back to a relay
automatically.

```bash
npx wrangler secret put TURN_KEY_ID
npx wrangler secret put TURN_KEY_API_TOKEN
```

Get both from the Cloudflare dashboard under **Calls → TURN**. These are long-term
secrets — the Worker mints short-lived (1 hour) per-call credentials from them and only
those reach the browser. Never put them in `wrangler.jsonc`.

Without them the app still runs and the status line says it's P2P-only, so a failure to
connect is legible rather than mysterious.

### 3. Headphones. Both of you. This is not optional.

Echo cancellation is switched **off** on purpose. It's the single biggest destroyer of
the pre-speech inhale — it treats a breath as noise and gates it out. Without
headphones you will hear yourself echo back, badly, and it will ruin the call.

---

## During the call

Open the deployed URL, pick a room name (both of you type the same one), hit **Join
call**, send the other person the link the app shows you.

Then **just talk normally for ten minutes.** There is no script, nothing to read, no
prompts. Every number comes from ordinary conversation. Talk about anything.

Two things help the measurement without changing how you talk:

- **Let each other finish.** Overlapping speech is recorded but can't be used as a turn
  transition, so a call where you talk over each other constantly yields fewer usable
  data points. Normal conversation is fine; a heated argument is not.
- **Aim for back-and-forth**, not monologues. Thirty short exchanges is much better data
  than three long speeches.

Optional, before joining: open **Screen size** and drag the box to match a credit card
held against the display. That's what makes the other person render at true life size
instead of a guess. Skipping it costs you the life-size effect, nothing else.

### The controls

Bottom bar, appears on mouse move:

| | |
|---|---|
| **life size** | Renders their head at the angular size it would have at 1.1 m — conversation distance. Off = fills the screen, like every other app. |
| **gaze** | Puts their eye line right under your webcam so looking at them ≈ looking at the lens. **Go fullscreen for this to work properly** — it cuts residual gaze error about 6×, from ~3.7° to ~0.6°. |
| **self view** | Off by default. Watching yourself is a documented fatigue driver and has no upside during a call. |
| **stats** | The live panel. |
| **save log** | Downloads the log as a file. Do this before leaving — belt and braces. |

### Reading the live panel

- **their reply, felt** — the silence you actually experienced. Contains the round trip.
  Compare to Zoom's 976 ms.
- **human only** — their speech stopped → you started. Their audio already crossed the
  network to reach you, so this has **no network delay in it at all.** Compare to the
  297 ms face-to-face control.
- **their breath head start** — how long before their first word their inhale reached
  you. The thing every other product deletes.
- **their turns w/ breath** vs **yours (control)** — the most important pair in the
  panel. If yours is high and theirs is near zero, your mic hears your inhale but the
  network is eating theirs, and lever 1 of §3.1 is broken as built.

---

## After the call

Both of you hit **save log**, or pull it from the server:

```bash
curl -s https://tape-app.<your-subdomain>.workers.dev/api/room/morning/log > morning.ndjson
```

Then:

```bash
node analyze.mjs morning.ndjson
```

Which prints the comparison directly:

```
  face to face (Boland 2021)    297 ms  ██████████
  over Zoom    (Boland 2021)    976 ms  ██████████████████████████████████
  ── this call ──
  human only                    230 ms  ████████
  perceived (what you felt)     290 ms  ██████████
  to their first word           495 ms  █████████████████
```

The analyzer re-derives everything from raw events rather than trusting the live
figures, and it flags results *against* the design as loudly as results for it — a high
playout buffer, an RTT that doesn't reconcile, a breath that didn't survive transit.

### Both logs, not one

Each person's log holds their own view: their human gap is *their* response time, and
their perceived gap is what *they* sat through. Two logs give you both people's numbers
and a cross-check — A's perceived gap should be roughly B's human gap plus the round
trip. Collect both.

---

## How the measurement avoids clock sync

Normally, timing anything across two machines means synchronising their clocks, and the
sync error swamps the thing you're measuring. This sidesteps it entirely.

Each machine runs **two** onset detectors: one on its own microphone, one on the audio
**arriving** from the other side. Both timestamps are therefore local, and the direction
of the pair decides which quantity you get:

```
their arrival 'end' → my local 'onset'    = HUMAN gap
    Their audio already crossed the network to reach me, so the transit is
    INSIDE 'arrival end' rather than added to the difference. What's left is
    pure human response time. Directly comparable to 297 ms, no correction.

my local 'end' → their arrival 'onset'    = PERCEIVED gap
    My words had to reach them and their reply had to come back, so this
    contains a full round trip — correctly, because that is what I sat
    through as silence. Comparable to 976 ms.
```

No clock sync anywhere, and `perceived − human ≈ RTT` becomes a **consistency check we
can verify** instead of an assumption we have to make. Verified: 60 ms implied against
60 ms measured, exactly, through the real browser → worker → analyzer path.

## Counting to the breath, not the word

The other measurement everyone gets wrong. Ask "how long until they replied" and the
obvious answer is "until I heard a word." But in a room you know someone is about to
speak before they speak — you hear them inhale. That inhale precedes phonation by
~200 ms, and pre-turn inhalations are measurably longer and deeper than within-turn
ones, so it's genuine information, not noise.

So the detector fires on **first evidence**, not first word. It triggers on energy
alone in 5–10 ms; the classification into breath / voice / transient arrives ~35 ms
later and never gates anything. The bias is asymmetric on purpose: a false positive
costs one small packet, a false negative costs 200 ms.

Both are reported. `gapToWordMs` is the conventional number; the gap to first evidence
is the honest one.

---

## What's recorded

Timings and WebRTC counters. Nothing else.

**No audio. No video. No frames. No transcript. No text.** The detector reports *that* a
breath happened and *when* — never what was said. Payloads are numbers and short enums;
the server sanitizes again on ingest and drops anything it doesn't recognise. The
`Room` Durable Object refuses new events past 400k rather than rolling the window,
because silently dropping the start of a call would make the data look complete when it
isn't.

There are three independent survival paths, because the call happens once: a batched
POST every 5 s, a `sendBeacon` on page hide (a normal tab close otherwise loses the
tail, which is the end of the conversation), and a localStorage mirror recoverable
afterwards even if the server was unreachable the whole time. Plus the download button.

---

## Honest limitations

Read this before drawing conclusions.

**1. Latency here is Zoom-class, and that's fine.** This app uses ordinary WebRTC with
Opus and browser congestion control. The custom four-lane transport from DESIGN.md §4
is *not* in it — that's still gated behind a phase-1 test that needs two real machines.
So this call does **not** test the transport. It tests levers 1 and 2 of §3.1, which are
the two biggest, by asking whether raw audio and a breath detector recover the 179 ms
Zoom loses. The network is a constant here, deliberately.

**2. Real speech has been through this, but no real room has.** Two headless browsers now
run whole conversations through the shipping code, using recorded human speech fed in as
the microphone (Chrome's `--use-file-for-fake-audio-capture`), across an emulated network
of up to 240 ms RTT with jitter and loss. Everything downstream of capture is the real
path: real Opus, real peer connection, real jitter buffer, the app's real detectors. That
found **eight bugs** the synthetic tests all passed, three of which would have turned a
live call into garbage that looked like a quiet room. See `testbed/README.md`.

What it still does not have is a *room*: the fake microphone is a file, so there is no
acoustic path, no echo for cancellation to cancel, and no real background noise. Read
speech also lacks some of the turn-end cues real conversation has. So the first real voice
in a real room is still yours. **Expect something to be wrong**, check the live panel
early, and if the dots at top right never light up while you're talking, that's the thing
to report.

Measured on that harness, for what to expect: 28/28 turns detected, onset timing error a
0 ms median, the planted inhale kept 100% at the microphone and 100% at the far end, and
the reported head start flat at 186–216 ms across every emulated distance.

**3. `bitrateMode: 'quantizer'` — AV1 is unavailable on this Mac.** VP9 and H.264 accept
it; AV1 isn't supported at all, not even plain VBR. §6 assumes AV1 primary, so H.264
fixed-QP is the actual default path here. Doesn't affect this test (WebRTC picks its own
codec) but it changes which fallback is the common case.

**4. A high playout buffer contaminates the human gap.** If the receiver is holding
200 ms of audio, part of what looks like human hesitation is really the jitter buffer.
The app sets `playoutDelayHint = 0` and logs the true value from
`jitterBufferDelay / jitterBufferEmittedCount`; the analyzer warns above 120 ms. Check
that line before believing a human-gap figure.

---

## Files

| | |
|---|---|
| `src/worker.ts` | Signaling + log storage, one SQLite-backed Durable Object per room. Mints TURN credentials at `/api/ice`. |
| `public/app.js` | The call. Raw audio, life-size, gaze, no self view, dual detectors. Every instrumental path wrapped so it can't take the call down. |
| `public/turntaking.js` | Live analyser. Transitions are **flagged, never dropped** — deciding what counts as a turn is an analysis decision, and analysis can be redone. The call can't. |
| `public/telemetry.js` | The logger, and `sampleStats()`. |
| `public/onset-worklet.js` | The detector on the audio thread. |
| `public/onset-monitor.js` | Attaches a detector to a stream. Remote streams need `audible: true` — Chromium won't pull audio from a stream that isn't sunk to an element. |
| `public/core/` | Symlink to `../../core` — the shared DSP. |
| `analyze.mjs` | Offline analysis. Re-derives everything from raw events. |
| `turntaking.test.mjs` | 45 assertions. `npm test` |

```bash
npm test                              # analyser
node ../core/onset.test.mjs           # detector DSP
npm run dev                           # localhost:8794 (single-machine only — see above)
npm run deploy                        # what you actually need
```
