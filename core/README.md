# core

Shared media-core modules. Plain ESM, zero dependencies, and no browser or node APIs
in the hot paths — so the same file runs under an AudioWorklet and under `node`,
which is how it gets tested. Slated for port to Rust (`DESIGN.md` §19.3); kept
allocation-free per hop for that reason.

```bash
node core/onset.test.mjs
```

---

## onset.js — voice-onset and breath detection

The implementation of `DESIGN.md` §3.1 lever 1: **the most valuable 200 ms in the
design.**

A speaker inhales ~200 ms before phonation, and inhalations before a *new turn* are
longer and deeper than within-turn ones. So the breath — not the first word — is the
earliest honest evidence that a reply is coming. Every commercial call product deletes
it as noise. We transmit it, and we transmit it first (Lane 0, §4).

### Two decisions worth understanding before changing anything

**1. Onset fires on energy alone.** Telling breath from voice needs at least two pitch
periods — up to ~28 ms — and waiting for that would spend a seventh of the head start
we're trying to win. So the state machine fires in one or two hops (5–10 ms) and labels
the turn afterwards. The label is telemetry and predictor input; it never gates the
send.

**2. The bias is asymmetric on purpose.** A false positive costs one ~60 kbps datagram.
A false negative costs the entire 200 ms. Every threshold is tuned to fire early and
apologise later — which is the *opposite* of how a bandwidth-saving VAD is tuned. Do
not "improve" this module's precision without re-reading that sentence.

### Events

| Event | When | Carries |
|---|---|---|
| `onset` | 5–10 ms after energy rises above the tracked floor | `at`, `snrDb` |
| `classified` | ~35 ms after onset | `kind: 'breath'｜'voice'｜'transient'`, `zcr`, `tiltDb`, `periodicity` |
| `voiced` | phonation begins in a breath-opened turn | `leadMs` ← **the measurement** |
| `end` | after 350 ms below the floor | `durationMs` |

`at` is an absolute sample index since construction, so callers can convert to a
session timestamp without guessing at buffering.

**`voiced` is the point of this module.** It makes the largest claim in the design
falsifiable by one person with one microphone: talk, and read the number.

### Measured behaviour

All from `onset.test.mjs`, 22 assertions, synthetic signals with known ground truth:

| | Result |
|---|---|
| Onset latency, voiced | **0 ms** |
| Onset latency, breath | **10–15 ms** |
| Steady room tone | never fires |
| Keyboard click | labelled `transient`, never `voice`/`breath` |
| Noisy room (20× tone) | still fires, 5 ms late |
| Cost | **0.03% of real time** |

**Sensitivity** — the expensive failure is a *missed* breath, so this is the number
that matters:

| Breath level over room tone | Detected | Latency |
|---:|:---:|---:|
| 32 dB | yes | 10 ms |
| 24 dB | yes | 15 ms |
| 20 dB | yes | 20 ms |
| 12 dB | yes | 25 ms |
| **4 dB** | **yes** | 30 ms |

Detection holds to 4 dB above room tone, well below any real inhale, with latency
degrading gracefully rather than falling off a cliff.

**Reported-lead accuracy** — this module is an instrument, and an instrument that
flatters itself is worse than none:

| Ground truth | Reported | Error |
|---:|---:|---:|
| 200 ms | 186 ms | −14 |
| 260 ms | 236 ms | −24 |
| 340 ms | 316 ms | −24 |
| 440 ms | 416 ms | −24 |
| 570 ms | 536 ms | −34 |

**Mean bias is −24 ms — it under-reports.** That's deliberate: `voiced` is attributed
to the *start* of the periodicity analysis window rather than its end, because erring
late would inflate the very number the design is being judged on. A test asserts the
bias stays non-positive, so this cannot silently regress into self-flattery.

### node and browser agree exactly

The same module was driven through a real AudioWorklet with an identical synthetic
buffer:

| | node | browser (AudioWorklet) |
|---|---:|---:|
| Onset (truth 700 ms) | 715 ms | **715 ms** |
| Classification | breath | **breath** |
| Reported lead (truth 340 ms) | 316 ms | **316 ms** |

Which also confirms that a static `import` inside an `AudioWorkletGlobalScope` works
in Chromium — the thing that makes a shared, testable core possible at all.

### Tuning

| Constant | Value | Why |
|---|---:|---|
| `HOP` | 240 (5 ms) | Sets the detection-latency floor |
| `ONSET_SNR_DB` | 7 | Fire threshold, dB over tracked floor |
| `END_SNR_DB` | 3 | Hysteresis, so a fading tail doesn't chatter |
| `HANG_MS` | 350 | Longer than a within-sentence pause, shorter than a turn gap |
| `RISE_DB` | 2.5 | Must be *rising*, not just loud — rejects a fan spinning up |
| `FLOOR_DOWN` / `FLOOR_UP` | 0.25 / 0.0015 | Floor chases silence fast, is nearly immovable by speech |

Thresholds are relative to a tracked noise floor rather than absolute, because an
absolute gate fails in either a quiet studio or a noisy office depending on which one
you tuned it in. The floor is **frozen while a turn is active** — otherwise a long
utterance drags it upward and swallows the *next* onset, which is a nasty bug because
it only appears in long conversations.

---

## Consumers

| Path | Uses it for |
|---|---|
| `fatigue-lab/public/onset-worklet.js` | AudioWorklet wrapper — adapts block sizes, posts events with `AudioContext` timestamps |
| `fatigue-lab/public/onset-monitor.js` | Creates detectors over a MediaStream; one shared `AudioContext` |
| `fatigue-lab/public/lab.js` | Step 4 of the lobby — live breath-lead measurement, solo, no peer needed |
| `fatigue-lab/public/turns.js` | The §1.1c falsification gate |

`fatigue-lab/public/core` is a symlink to this directory, so `wrangler dev` serves it
directly with no build step. Verified serving at `/core/onset.js`.
