# Work order: linear AEC core (partitioned-block frequency-domain NLMS) + synthetic room rig

You are implementing phase 1 of an in-house acoustic echo canceller for a
lossless 48 kHz voice lane. Do NOT run any shell commands or tests — the
orchestrator runs all verification. Only create the two files named below.
Do not modify any existing file.

## Background

The app plays the peer's voice through the device speaker; the mic hears it
again after the room's acoustic path (delay + reflections + speaker
distortion). We possess the far-end signal bit-exactly and share one sample
clock between render and capture, so a linear adaptive filter can learn the
speaker→mic impulse response and subtract the predicted echo. This module is
the math core only: pure ES module, no DOM, no AudioWorklet APIs, allocation-
free in the steady state (it will run on the real-time audio thread later).

## File 1 (new): `tape-app/public/core/aec-core.js`

```js
export function createAec({ sampleRate = 48000, block = 128, partitions = 24 } = {}) → {
  process(mic, ref)  // both Float32Array(block); returns Float32Array(block) — the echo-cancelled mic
  stats()            // { erleDb, delayBlocks, adapting, converged }
  reset()
}
```

`process(mic, ref)` is called once per 128-sample block. `ref` is the block of
far-end samples RENDERED to the speaker in the same block interval (the caller
guarantees clock alignment; the ACOUSTIC delay — output buffering + air — is
unknown and handled inside, see delay tracking).

### Algorithm — overlap-save PBFDAF

- FFT size N = 2·block = 256. Implement a radix-2 in-place complex FFT (and
  inverse) as local functions — no dependencies. Preallocate every buffer at
  create time; `process` must not allocate.
- Keep a frequency-domain history of the last `partitions` (default 24 →
  24·128 = 3072 taps = 64 ms of tail) reference blocks: each new ref block is
  concatenated with the previous one (overlap-save), FFT'd, and pushed into a
  circular partition history X[p].
- Adaptive filter: complex weights W[p] per partition (129 usable bins from the
  256-point real FFT; store full complex arrays if simpler — correctness over
  micro-optimisation, but no allocation in process()).
- Echo estimate: Y = Σ_p X[p]·W[p]; y = last 128 samples of IFFT(Y).
- Error (output): e = mic − y.
- NLMS update in the frequency domain: W[p] += μ · conj(X[p]) · E / (P̂x + ε)
  where E = FFT of (zero-padded gradient constraint form of) e, P̂x is a
  per-bin exponential moving average of Σ_p |X[p]|² (smoothing ~0.9), μ = 0.5,
  ε = 1e-10. Apply the gradient constraint (IFFT the weight update, zero the
  second half, FFT back) — an unconstrained update smears circularly and will
  fail the rig; if you know the standard PBFDAF constraint trick, use it on
  each updated partition every block (or round-robin one partition per block —
  acceptable and cheaper; note which you chose in a comment).

### Bulk-delay tracking

The acoustic+output delay is unknown (tens of ms, can exceed the filter tail).
Keep a time-domain ref history ring of 1 s (48000 samples). Every ~250 blocks,
cross-correlate the recent mic signal against the ref history at block-aligned
lags 0..~750 ms (correlate decimated envelopes — e.g. per-block RMS — for
cheapness) and pick the best lag. If the best lag differs from the current
`delayBlocks` by more than 1 block AND its correlation is decisively better
(≥1.5× the current alignment's), re-align: the `ref` stream fed into the FFT
partitions is read from the history ring at `delayBlocks` behind live, and the
filter resets its weights (a bulk-delay jump invalidates the learned response).
Initial delayBlocks = 0 with the first decisive estimate winning.

### Double-talk protection

Freeze adaptation (μ = 0) when near-end speech is likely: maintain per-block
short-term powers of mic, ref (aligned), and e. If ref power < 1e-8 (far end
silent) do not adapt AND bypass subtraction entirely — the output must be
BIT-IDENTICAL to the input mic block (this exact property is tested). If
e-power > 0.5·mic-power while ref is active for ≥3 consecutive blocks, treat as
double-talk: freeze adaptation but keep subtracting.

### stats()

- `erleDb`: 10·log10(mic power / e power) exponentially averaged over blocks
  where ref is active and mic power > 1e-8; null before any such block.
- `delayBlocks`: current bulk alignment. `adapting`: whether the last block
  adapted. `converged`: erleDb ≥ 12 sustained (EMA).

## File 2 (new): `testbed/aec-core.test.mjs`

Node test rig, `#!/usr/bin/env node`, imports the core. Seeded PRNG only
(mulberry32 — copy the one in testbed/echo-detect.test.mjs), no Math.random.
Unknown CLI flags are fatal.

Synthetic room: far-end signal = speech-like noise (random-walk envelope ×
white noise, the envelope gated by on/off bursts). Echo path: bulk delay D
samples, then a sparse impulse response — direct tap 0.5 at D, taps decaying
exponentially to −30 dB over 40 ms after D, generated from the seeded PRNG.
Optional soft-clip nonlinearity `x → tanh(3x)/3` on the speaker signal before
convolution (phone speakers distort).

Arms (each prints one line, all must pass; exit 0 only if all pass):
1. convergence: far-end single-talk, D = 20 ms, linear path. After 5 s, ERLE
   over the last second ≥ 20 dB.
2. delay: same but D = 180 ms (exceeds filter tail; only bulk tracking can
   solve it). ERLE last-second ≥ 15 dB after 8 s, and stats().delayBlocks
   within ±2 blocks of D/128.
3. double-talk: after 4 s of convergence, add near-end speech (independent
   speech-like signal, comparable power) for 3 s, then 2 s far-only. During
   double-talk the near signal must survive: correlation between output and
   the clean near signal ≥ 0.9, and ERLE must recover to ≥ 15 dB within 2 s
   after the near talker stops.
4. bit-exact: far end all zeros for 10000 blocks with active mic speech —
   every output block must be BIT-IDENTICAL to its input (compare with
   Object.is per sample, including signed zero and NaN handling — simply
   `out[i] === mic[i]` is fine, plus assert the output buffer content equals
   input even after previous arms proved the filter nonzero: create a fresh
   AEC, run 100 blocks of far-end activity, then 10000 zero-ref blocks; only
   the zero-ref blocks must be bit-exact).
5. nonlinear: arm 1 with the tanh speaker — ERLE last-second ≥ 12 dB (linear
   filters cannot fully cancel distortion; this bounds the residual phase 2
   will handle).

Print `PASS`/`FAIL` per arm with the measured numbers.

## Style

Match the repo: long comments only where the code cannot show a constraint
(the gradient constraint, the delay re-alignment reset, the bit-exact bypass);
no per-line narration. camelCase, no semicolon churn.
