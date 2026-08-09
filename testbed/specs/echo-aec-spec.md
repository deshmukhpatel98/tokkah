# Work order: situational echo detection + one-way AEC latch

You are implementing an approved design in this repo. Follow it exactly. Do NOT
run any shell commands, dev servers, or tests — the orchestrator runs all
verification. Only create/edit the files named below.

## Background (why)

This app's audio lane is a lossless PCM path: the mic is captured by an
AudioWorklet into 8 ms frames (384 samples @48 kHz, int24), and received peer
frames are decoded and written into a playout ring — both on the main thread in
`tape-app/public/pcm.js`. The mic is deliberately opened with
`echoCancellation:false, noiseSuppression:false, autoGainControl:false`
(see `audioConstraints(raw)` in `tape-app/public/onset-monitor.js:103`) because
pristine audio is a product feature. Most users wear earphones, so AEC would be
pure quality loss. But a user on speakerphone produces real acoustic echo. The
approved design: DETECT actual echo by correlating the two PCM envelopes we
already have on the main thread, and only then re-open the mic with
`echoCancellation:true` (NS and AGC stay off, forever). One-way latch: AEC never
auto-disables within a call.

## Hard constraints

- Do NOT touch `tape-app/public/pcm-worklet.js`, any other worklet file, or
  `tape-app/public/core/onset.js` / `core/onset.js` (those two are hardlinked —
  one inode).
- Match the existing code style: this codebase writes long "why" comments only
  where the code can't show a constraint; no chatty per-line comments; no
  semicolon/format churn on lines you don't otherwise change.
- Keep every change minimal and local. No refactors.

## File 1 (new): `tape-app/public/echo-detect.js`

Pure ES module, no DOM/browser APIs — it must be importable from Node for unit
tests. Export one factory:

```js
export function createEchoDetector() → {
  mic(t, rms),    // t = performance.now()-style ms, rms = linear RMS of one 8 ms mic frame
  play(t, rms),   // same, for one decoded peer playout frame
  poll(tNow),     // call ~every 500 ms; returns null, or ONCE {corr, lagMs} when echo latches
}
```

Internals:
- Two rings of (t, rms) pairs, each holding the last ~3 s (cap 512 entries,
  overwrite oldest). Use preallocated Float64Arrays, not object arrays.
- `poll(tNow)`:
  - Gates (return null if any fail): both rings hold ≥2 s of span; mean playout
    RMS over the last 2 s ≥ 1e-3 (remote is actually talking); mean mic RMS over
    the last 2 s ≥ 1e-4 (mic not dead).
  - Resample both rings onto a common 8 ms grid covering [tNow−3000, tNow]
    (375 points): nearest sample within 12 ms, else 0.
  - Subtract each grid's mean. For each lag L = 0, 8, 16, … 600 ms (mic delayed
    relative to playout), compute normalized cross-correlation between
    play[i] and mic[i + L/8] over the overlapping region; skip lags where either
    side's variance is ~0.
  - Track the peak correlation and its lag. Echo criterion: peak ≥ 0.55 AND the
    peak lag agrees within ±24 ms across 3 CONSECUTIVE polls.
  - When it fires, latch (all later polls return null) and return
    `{ corr: <peak, 2 decimals>, lagMs: <lag> }`.
- Everything O(gridPoints × lags) per poll (~28k multiply-adds) — no FFT.

## File 2: `tape-app/public/pcm.js` integration

- Import `createEchoDetector` at the top with the existing imports.
- Inside `initPcmAudio` create the detector once (respect a config gate:
  `cfg.echoDetect !== false`; when gated off, no detector, zero work).
- Mic tap — in `onCaptureFrame(seq, buf, capUs)` (line ~883), before the
  compression branch: decode RMS directly from the int24 buffer
  (`new Uint8Array(buf)`, 384 samples × 3 bytes LE, sign-extend bit 23, divide
  by 8388608; accumulate sum of squares, `Math.sqrt(sum/384)`) and call
  `det.mic(now(), rms)`. Do not allocate per frame beyond the one Uint8Array
  view.
- Playout tap — in `ringWrite` immediately after
  `const samples = zip ? decodeZip(payload) : decodeFrame(payload);`
  (line ~469): compute RMS from `samples` (Float32Array, 384 entries — note it
  is a shared scratch buffer, so compute RMS synchronously right there) and call
  `det.play(now(), rms)`.
- Polling: piggyback on an existing ~1 s timer if one exists in scope, else a
  dedicated `setInterval(…, 500)` cleared on close. When `poll()` returns a
  result: `log?.('echo-detected', { corr, lagMs })` and invoke a new optional
  callback `onEchoDetected?.({ corr, lagMs })` — add `onEchoDetected` to the
  `initPcmAudio({ … })` destructured params.

## File 3: `tape-app/public/app.js` integration

- QS flag `aec`: `'1'` = force AEC on from the start, `'0'` = never enable.
  Default (absent) = auto (enable only when the detector fires). Follow how
  other QS flags are read into `cfg` in this file.
- App-level state `let aecOn = <true if ?aec=1>`.
- Add ONE helper near the constraint sites:
  `const micConstraints = () => ({ ...audioConstraints(true), ...(aecOn ? { echoCancellation: true } : {}) });`
  and use it in place of `audioConstraints(true)` at ALL FOUR sites:
  lines ~2570, ~2571 (`askAudioOnly` / `askBoth`), ~4662 (`switchMicTo`'s
  `want`), ~5187. Do not change `audioConstraints` itself in onset-monitor.js.
- Wire `onEchoDetected` where `initPcmAudio` is called: if `aecOn` already, or
  the QS flag is `'0'`, just log. Otherwise:
  1. set `aecOn = true`
  2. telemetry log `aec-on` with `{ corr, lagMs }` via the same `tel?.log`
     pattern used by `camera-flip`
  3. re-acquire the mic through the EXISTING `switchMicTo(deviceId)` path with
     the CURRENT mic's deviceId
     (`localStream.getAudioTracks()[0]?.getSettings?.().deviceId`); if no
     deviceId is readable, skip the re-acquire and log that in the same event.
  4. guard so this whole reaction runs at most once per call.
- `switchMicTo` currently builds
  `const want = { ...audioConstraints(true), deviceId: { exact: deviceId } };` —
  after the helper swap it must become `{ ...micConstraints(), deviceId: { exact: deviceId } }`
  so the re-acquire actually picks up `echoCancellation:true`.

## File 4 (new): `testbed/echo-detect.test.mjs`

Node unit test, no browser. `#!/usr/bin/env node`, imports
`../tape-app/public/echo-detect.js`. Two arms:
- echo arm: synthesize 10 s of speech-like playout RMS at 8 ms steps (e.g. a
  slowly varying random envelope: sum of a random walk clamped ≥0 plus bursts
  and silences), feed `play(t, rms)`; feed `mic(t, 0.4·play(t−120ms) + small
  noise)`. Call `poll` every 500 ms. MUST detect, with lagMs within 120±24.
- clean arm: mic is an independent envelope of similar level. Over 30 s of
  simulated time MUST NOT detect.
Print one line per arm and exit 0 only if both pass; exit 1 otherwise. Fail on
unknown CLI flags if you accept any (this repo treats unknown flags as fatal).

## Deliverable

The four file changes only. No commits, no test runs, no servers.
