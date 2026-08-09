# Work order: wire the AEC2 core into the Lane-A worklets, behind ?aec2=1

Phase 2 of the in-house echo canceller. The math core
(`tape-app/public/core/aec-core.js`, `createAec`) is DONE and proven — do not
modify it, and do not modify `core/onset.js` (hardlinked). Do NOT run any
shell commands or tests. Edit exactly the three files below.

## Architecture

Both Lane-A worklets live in ONE AudioWorkletGlobalScope on ONE AudioContext
(`tape-app/public/pcm-worklet.js`, loaded by `pcm.js` line ~1881), so they
share the sample clock and `currentFrame`. The playout processor's `fill(out)`
produces the exact 128-sample block the speaker will emit (post-concealment,
post-resample) — the perfect far-end reference. A new SharedArrayBuffer ring
carries those blocks to the capture processor, which runs `createAec` on each
mic block before frames are built. The core's internal bulk-delay tracker
absorbs the output latency + acoustic delay, so alignment here only has to be
CONSISTENT, not exact.

## File 1: `tape-app/public/pcm.js`

- In `initPcmAudio`, next to the existing `capSab` allocation (~line 356):
  when `cfg.aec2 === true && sabOk`, allocate
  `aecSab = new SharedArrayBuffer(64 + 512 * 128 * 4)` (header Int32 at byte 0
  = highest block index written; 512 slots of Float32Array(128) from byte 64).
  Null otherwise.
- Pass `aecSab` in `processorOptions` to BOTH worklet nodes where they are
  constructed (capture and playout).
- Stats plumbing: the capture worklet will post `{ type: 'aec2', erleDb,
  delayBlocks, adapting, converged }` on its port every ~2048 blocks. Handle
  it where other capture port messages are handled: store the latest object
  on `stats.aec2` (initialize `stats.aec2 = null` with the other stats
  fields) and `L('aec2-stats', msg)` each time (the existing safe log
  wrapper).

## File 2: `tape-app/public/pcm-worklet.js`

- Add `import { createAec } from './core/aec-core.js';` beside the existing
  core imports.
- `PcmPlayout`: in the constructor read `o.aecSab`; if present create
  `this.aecHi = new Int32Array(o.aecSab, 0, 1)` and
  `this.aecRing = new Float32Array(o.aecSab, 64, 512 * 128)`. At the END of
  `fill(out)` (after the drift-control section, unconditionally on the same
  `out` that was just produced — including the silent early-return paths:
  put the write in `process()` right after `this.fill(out)` instead, so every
  rendered block is captured even when fill returns early with zeros): when
  `this.aecRing` exists and `out.length === 128`, compute
  `const k = (currentFrame / 128) | 0`, copy `out` into
  `this.aecRing.subarray((k % 512) * 128, (k % 512) * 128 + 128)`, then
  `Atomics.store(this.aecHi, 0, k)`.
- `PcmCapture`: in the constructor read `o.aecSab`; if present create the same
  two views plus `this.aec = createAec()` and `this.aecStatBlocks = 0`.
  In `process(inputs)`, right after the `if (!ch) return true;` guard and
  BEFORE the turn-end predictor push (the predictor should see the cleaned
  signal — echo in the local monitor would fake voice activity):
  - if `this.aec` exists and `ch.length === 128`:
    - `const k = ((currentFrame / 128) | 0) - 1;` — the PREVIOUS quantum's
      block is guaranteed written no matter which processor ran first inside
      the current quantum; the constant one-block offset is absorbed by the
      core's bulk-delay tracking.
    - if `k >= 0 && Atomics.load(this.aecHi, 0) >= k`, the ref block is
      `this.aecRing.subarray((k % 512) * 128, (k % 512) * 128 + 128)`; else a
      preallocated zero Float32Array(128) (zeros → the core's silent-far
      bypass keeps the mic bit-exact).
    - `const cleaned = this.aec.process(ch, ref);` and use `cleaned` in place
      of `ch` for EVERYTHING downstream in this method (predictor push and
      the frame accumulation loop). Do not write into `ch`.
    - every 2048 processed blocks post
      `this.port.postMessage({ type: 'aec2', ...this.aec.stats() })`.
  - if `this.aec` is absent, behaviour must be byte-for-byte unchanged.
- Note `createAec().process` returns an internal preallocated buffer — copy
  is unnecessary, it is stable until the next `process` call.

## File 3: `tape-app/public/app.js`

- Add to `PCM_CFG`: `aec2: QS.get('aec2') === '1',` (opt-in flag; default off).
- In the `onEchoDetected` handler: when `PCM_CFG.aec2` is true, log the event
  (`tel?.log('echo-detected', { corr, lagMs, aec2: true })`) and return WITHOUT
  latching Chrome AEC or re-acquiring the mic — two cancellers on one path
  fight each other. The detector then serves as independent residual-echo
  telemetry for AEC2.

## File 4 (new): `testbed/aec2-call.mjs`

Playwright two-browser call test, copy the launch/join scaffolding style of
testbed/aec-call.mjs (CHROME path, fake devices, unknown-flags-fatal, default
URL http://127.0.0.1:8794). Two arms:

- `on` — both pages `?aec2=1`. Wait for A `window.__tape?.pcm?.framesSent >
  100`, then wait up to 20 s for A's `window.__tape.pcm.stats().aec2` to be
  non-null. Assertions: no pageerrors on A or B; B `framesRecv > 100`;
  `stats().aec2.delayBlocks >= 0`; `stats().aec2.erleDb === null ||
  stats().aec2.erleDb > -5` (fake devices have no acoustic coupling, so
  there is nothing to cancel — the assertion is that the canceller does not
  ADD energy or crash the pipeline).
- `off` — no flag. Same join, then assert `stats().aec2` is null/undefined
  (the SAB, the core, and the per-block work must not exist by default) and
  the lane flows (B `framesRecv > 100`, no pageerrors).

Print one line per arm, verdict line, exit 0 only if both pass.

## Style

Match each file's conventions. Comments only for constraints the code cannot
show (the one-block ref offset, the cleaned-signal predictor ordering, the
zero-ref bypass linkage).
