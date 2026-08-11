/**
 * Partitioned-Block Frequency-Domain Adaptive Filter (PBFDAF) Acoustic Echo Canceller
 * 48 kHz voice lane linear DSP core.
 *
 * FOREGROUND / BACKGROUND (shadow) filter architecture.
 *
 * One adaptive filter cannot serve both masters on a real room. Measured, both
 * failure modes on the same code: with a double-talk FREEZE it starves (room
 * xow-offc-apz, cross-room bleed reads as permanent double-talk, ERLE never
 * leaves ~0 dB); with the freeze relaxed to a 3% leak it ERODES (synthetic bleed
 * pre-flight at equal near/echo level: ERLE 7 dB early, decaying to ~0–1.6 dB by
 * 60 s as an independent near voice contaminates the gradient). Both are the same
 * root cause — the weights that are DELIVERED are the weights being CORRUPTED.
 *
 * So split those two jobs onto two weight sets:
 *
 *   BACKGROUND (shadow): adapts EVERY block at FULL μ. No freeze, no leak, no
 *     double-talk gating on its updates at all. Its corruption is harmless
 *     because its output is never delivered — it is a hypothesis, not a product.
 *   FOREGROUND: never adapted in place. It only ever receives the background's
 *     weights, and only when the background PROVES itself better on the same
 *     signal (ERLE comparison, below). Its error is what delivery uses.
 *
 * Comparison gating replaces double-talk gating: instead of guessing when an
 * update would be harmful, we let the shadow take every update and then measure
 * which weight set actually cancels this room. Corruption is detected by its
 * effect, not predicted from a detector. The do-no-harm delivery gate is
 * unchanged and still sits on the FOREGROUND — a filter must still earn its
 * place in the audio path, now with proven-better weights behind it.
 *
 * The DTD machinery still runs, driven by the background (the direct successor
 * of the old single filter), purely to keep the dtPct diagnostic comparable
 * across builds. It no longer influences a single sample of audio.
 */

export function createAec({ sampleRate = 48000, block = 128, partitions = 24 } = {}) {
  const L = block
  const N = 2 * L
  const P = partitions

  // In-place Radix-2 Complex FFT helper
  const log2N = Math.round(Math.log2(N))
  const bitRev = new Uint16Array(N)
  for (let i = 0; i < N; i++) {
    let rev = 0
    for (let b = 0; b < log2N; b++) {
      if ((i >> b) & 1) rev |= (1 << (log2N - 1 - b))
    }
    bitRev[i] = rev
  }

  const cosTable = new Float32Array(N / 2)
  const sinTable = new Float32Array(N / 2)
  for (let i = 0; i < N / 2; i++) {
    cosTable[i] = Math.cos((2 * Math.PI * i) / N)
    sinTable[i] = Math.sin((2 * Math.PI * i) / N)
  }

  function transform(inRe, inIm, outRe, outIm, inverse) {
    for (let i = 0; i < N; i++) {
      const rev = bitRev[i]
      outRe[rev] = inRe[i]
      outIm[rev] = inIm[i]
    }

    for (let len = 2; len <= N; len <<= 1) {
      const half = len >> 1
      const step = N / len
      for (let i = 0; i < N; i += len) {
        for (let k = 0; k < half; k++) {
          const tabIdx = k * step
          const c = cosTable[tabIdx]
          const s = sinTable[tabIdx]

          const re2 = outRe[i + k + half]
          const im2 = outIm[i + k + half]

          let tRe, tIm
          if (inverse) {
            tRe = re2 * c - im2 * s
            tIm = im2 * c + re2 * s
          } else {
            tRe = re2 * c + im2 * s
            tIm = im2 * c - re2 * s
          }

          const uRe = outRe[i + k]
          const uIm = outIm[i + k]

          outRe[i + k] = uRe + tRe
          outIm[i + k] = uIm + tIm

          outRe[i + k + half] = uRe - tRe
          outIm[i + k + half] = uIm - tIm
        }
      }
    }

    if (inverse) {
      const invN = 1 / N
      for (let i = 0; i < N; i++) {
        outRe[i] *= invN
        outIm[i] *= invN
      }
    }
  }

  function fft(inRe, inIm, outRe, outIm) {
    transform(inRe, inIm, outRe, outIm, false)
  }

  function ifft(inRe, inIm, outRe, outIm) {
    transform(inRe, inIm, outRe, outIm, true)
  }

  // Ring buffer for raw reference history (1 second = 48000 samples)
  const refHistLen = sampleRate
  const refHistory = new Float32Array(refHistLen)
  let refHistHead = 0

  // RMS history ring buffers for bulk-delay estimation
  const maxRmsHist = 512
  const micRmsHist = new Float32Array(maxRmsHist)
  const refRmsHist = new Float32Array(maxRmsHist)
  const scratchMicRms = new Float32Array(maxRmsHist)
  let rmsHistHead = 0
  let rmsHistCount = 0

  // Overlap-save reference delay buffer
  const prevDelayedRef = new Float32Array(L)

  // Circular partition history X (size P x N)
  const X_re = Array.from({ length: P }, () => new Float32Array(N))
  const X_im = Array.from({ length: P }, () => new Float32Array(N))
  let xHead = 0

  // BACKGROUND (shadow) filter weights — always adapting, never delivered.
  const bgW_re = Array.from({ length: P }, () => new Float32Array(N))
  const bgW_im = Array.from({ length: P }, () => new Float32Array(N))
  // FOREGROUND filter weights — never adapted, only copied into from the
  // background once the background has proven better. This is the weight set
  // whose error reaches the far end.
  const fgW_re = Array.from({ length: P }, () => new Float32Array(N))
  const fgW_im = Array.from({ length: P }, () => new Float32Array(N))

  // Exponential moving average of reference power per bin Px_hat
  const Px_hat = new Float32Array(N)

  // Working scratch buffers (preallocated to avoid thread allocations)
  const fftInRe = new Float32Array(N)
  const fftInIm = new Float32Array(N)
  const fftOutRe = new Float32Array(N)
  const fftOutIm = new Float32Array(N)
  const ePaddedRe = new Float32Array(N)
  const ePaddedIm = new Float32Array(N)
  const norm = new Float32Array(N)
  const dW_re = new Float32Array(N)
  const dW_im = new Float32Array(N)
  const scratchRe = new Float32Array(N)
  const scratchIm = new Float32Array(N)
  const delayedRef = new Float32Array(L)
  const e = new Float32Array(L)     // FOREGROUND error — the delivered signal
  const bgE = new Float32Array(L)   // BACKGROUND error — drives adaptation only
  const out = new Float32Array(L)

  // State variables
  let delayBlocks = 0
  let lastBestLag = 0
  let hasDecisiveEstimate = false
  let blockCount = 0
  // One ERLE EMA per filter. erleDbEma is the FOREGROUND's — the delivered
  // filter — so every consumer of stats().erleDb keeps its original meaning
  // (how much help the audio path is actually getting). bgErleDbEma is the
  // shadow's, and the pair of them is the copy decision.
  let erleDbEma = null
  let bgErleDbEma = null
  let lastAdapting = false
  let dtCount = 0
  let wasConverged = false
  let dtHangover = 0
  // Copy bookkeeping: bg -> fg promotions and the cooldown between them.
  let copies = 0
  let lastCopyBlock = -1e9
  const COPY_COOLDOWN = 375 // ~1 s at 48 kHz / 128
  // Escape-valve counter: consecutive blocks in which the foreground is NOT
  // helping and the background has failed to beat it (see the valve below).
  let stallBlocks = 0
  // Do-no-harm gate. A canceller with nothing to cancel can only do harm:
  // on a path with zero acoustic coupling the filter adapts to spurious
  // correlations, the DTD freezes the junk weights, and "cancellation" ADDS
  // energy — measured live on iOS 2026-08-11 at −13 dB ERLE, output 20×
  // the mic power. So subtraction must EARN its place: the filter always
  // learns at full fidelity, but its output is only delivered while ERLE
  // proves ≥3 dB of real help (closing again below 1 dB — hysteresis, no
  // flapping). While closed, the mic passes through bit-exact; the moment
  // real echo appears and ERLE climbs, delivery engages within the EMA's
  // time constant.
  // UNCHANGED by the shadow rework, and now measuring the FOREGROUND only:
  // the gate is the second of two independent proofs an audio path must
  // survive (the copy rule proves better-than-what-we-have, the gate proves
  // better-than-nothing). Same thresholds, same two-tier close, same dwell.
  let gateOpen = false
  let gateLowBlocks = 0
  // Diagnostic counters: the fraction of active blocks the DTD reads as
  // double-talk. Meaning is unchanged from the build where this number gated
  // adaptation — it is still the bleed discriminator (room xow-offc-apz:
  // cross-room voices reading as permanent double-talk would put dtPct near
  // 100) — but under the shadow architecture it is now purely an observation:
  // the DTD's verdict no longer changes what the canceller does.
  let dtBlocks = 0
  let activeBlocks = 0
  let refSilentBlocks = 0

  // Wipe the shadow. Called by the escape valve (background only: the
  // foreground keeps its last PROVEN weights, which is the whole point of
  // having a foreground) and by a bulk-delay re-alignment via
  // resetWeightsBoth() below.
  function resetWeights() {
    for (let p = 0; p < P; p++) {
      bgW_re[p].fill(0)
      bgW_im[p].fill(0)
    }
    prevDelayedRef.fill(0)
    Px_hat.fill(0)
    dtCount = 0
    dtHangover = 0
    stallBlocks = 0
    wasConverged = false
    // The ERLE EMA describes the weights that were just wiped. Left standing,
    // it re-latches wasConverged against a zeroed filter on the very next
    // block (e ≈ mic), and the shadow's own convergence bookkeeping starts
    // from a lie — measured on the pre-shadow build as 1300 frozen blocks
    // after a delay re-alignment.
    bgErleDbEma = null
  }

  // A bulk-delay re-alignment invalidates BOTH weight sets: every tap in each
  // filter is indexed against the old delay, so the foreground's "proven"
  // weights are proven against a reference history that no longer exists.
  // Keeping them would deliver a confident misprediction until the ERLE EMA
  // caught up. Zeroed foreground weights make the subtraction a literal no-op
  // (mic − 0), so the audio path is safe while the shadow re-learns.
  function resetWeightsBoth() {
    resetWeights()
    for (let p = 0; p < P; p++) {
      fgW_re[p].fill(0)
      fgW_im[p].fill(0)
    }
    erleDbEma = null
  }

  // bg -> fg promotion. The foreground inherits the shadow's ERLE EMA along
  // with its weights, because that EMA is the measurement that earned the
  // copy: restarting it from the foreground's stale value would make the
  // delivery gate wait out a time constant for news it already has.
  function promote() {
    for (let p = 0; p < P; p++) {
      fgW_re[p].set(bgW_re[p])
      fgW_im[p].set(bgW_im[p])
    }
    erleDbEma = bgErleDbEma
    lastCopyBlock = blockCount
    stallBlocks = 0
    copies++
  }

  function reset() {
    refHistory.fill(0)
    refHistHead = 0
    micRmsHist.fill(0)
    refRmsHist.fill(0)
    rmsHistHead = 0
    rmsHistCount = 0
    for (let p = 0; p < P; p++) {
      X_re[p].fill(0)
      X_im[p].fill(0)
    }
    xHead = 0
    resetWeightsBoth()
    delayBlocks = 0
    lastBestLag = 0
    hasDecisiveEstimate = false
    blockCount = 0
    erleDbEma = null
    bgErleDbEma = null
    lastAdapting = false
    wasConverged = false
    dtHangover = 0
    refSilentBlocks = 0
    copies = 0
    lastCopyBlock = -1e9
    stallBlocks = 0
  }

  // Synthesize one filter's echo estimate from the shared partition history.
  // Result lands in fftOutRe: the time-domain estimate is its last L samples
  // (overlap-save). Allocation-free; clobbers fftInRe/fftInIm/fftOutRe/fftOutIm.
  function synthesize(wRe, wIm) {
    fftInRe.fill(0)
    fftInIm.fill(0)
    for (let p = 0; p < P; p++) {
      const pIdx = (xHead + p) % P
      const xR = X_re[pIdx]
      const xI = X_im[pIdx]
      const wR = wRe[p]
      const wI = wIm[p]
      for (let k = 0; k < N; k++) {
        fftInRe[k] += xR[k] * wR[k] - xI[k] * wI[k]
        fftInIm[k] += xR[k] * wI[k] + xI[k] * wR[k]
      }
    }
    ifft(fftInRe, fftInIm, fftOutRe, fftOutIm)
  }

  function process(mic, ref) {
    // 1. Write reference block to ring history
    for (let i = 0; i < L; i++) {
      refHistory[(refHistHead + i) % refHistLen] = ref[i]
    }
    refHistHead = (refHistHead + L) % refHistLen

    // 2. Read delayed reference block from history based on delayBlocks
    const dSamples = delayBlocks * L
    const readStart = (refHistHead - dSamples - L + refHistLen * 2) % refHistLen
    for (let i = 0; i < L; i++) {
      delayedRef[i] = refHistory[(readStart + i) % refHistLen]
    }

    // 3. Overlap-save FFT of reference: [prevDelayedRef, delayedRef]
    for (let i = 0; i < L; i++) {
      fftInRe[i] = prevDelayedRef[i]
      fftInRe[L + i] = delayedRef[i]
    }
    fftInIm.fill(0)
    for (let i = 0; i < L; i++) {
      prevDelayedRef[i] = delayedRef[i]
    }

    fft(fftInRe, fftInIm, fftOutRe, fftOutIm)

    // Push into circular partition history X
    xHead = (xHead - 1 + P) % P
    X_re[xHead].set(fftOutRe)
    X_im[xHead].set(fftOutIm)

    // 4. Synthesize BOTH echo estimates from the SAME partition history:
    //    Y = sum_p X[p] * W[p], once with the foreground weights (this is the
    //    estimate that can reach the far end) and once with the background's
    //    (this drives the shadow's own error and therefore its adaptation).
    //    Both share every scratch buffer; the only per-block cost is the
    //    second MAC sweep plus one extra IFFT.
    synthesize(fgW_re, fgW_im)

    // Foreground error e = mic - fgY  (the delivered residual)
    let micSumSq = 0
    let refSumSq = 0
    let eSumSq = 0
    for (let i = 0; i < L; i++) {
      const micVal = mic[i]
      const yVal = fftOutRe[L + i]
      const eVal = micVal - yVal
      e[i] = eVal

      micSumSq += micVal * micVal
      refSumSq += delayedRef[i] * delayedRef[i]
      eSumSq += eVal * eVal
    }

    synthesize(bgW_re, bgW_im)

    // Background error bgE = mic - bgY  (never delivered)
    let bgESumSq = 0
    let bgYSumSq = 0
    for (let i = 0; i < L; i++) {
      const yVal = fftOutRe[L + i]
      const eVal = mic[i] - yVal
      bgE[i] = eVal
      bgESumSq += eVal * eVal
      bgYSumSq += yVal * yVal
    }

    const micPow = micSumSq / L
    const refPow = refSumSq / L
    const ePow = eSumSq / L
    const bgEPow = bgESumSq / L
    const bgYPow = bgYSumSq / L

    // 5. Track block RMS history for bulk-delay estimation (raw ref)
    let rawRefSumSq = 0
    for (let i = 0; i < L; i++) rawRefSumSq += ref[i] * ref[i]
    micRmsHist[rmsHistHead] = Math.sqrt(micPow)
    refRmsHist[rmsHistHead] = Math.sqrt(rawRefSumSq / L)
    rmsHistHead = (rmsHistHead + 1) % maxRmsHist
    if (rmsHistCount < maxRmsHist) rmsHistCount++
    blockCount++

    // 6. Far-end silence check, shadow adaptation, and delivery
    //    (double-talk detection survives here as a diagnostic only)
    // The bit-exact bypass gates on the whole FILTER SPAN being silent, not
    // the current block: the room's echo tail outlives the reference by tens
    // of ms, and a current-block gate leaked real echo unsubtracted at every
    // far-end pause (measured: windowed ERLE collapsing 90 → 14 dB at each
    // pause). The mic is guaranteed untouched after P blocks (64 ms) of far
    // silence — the physically honest form of the guarantee.
    if (refPow < 1e-8) refSilentBlocks++
    else refSilentBlocks = 0
    if (refSilentBlocks > P) {
      lastAdapting = false
      dtCount = 0
      dtHangover = 0
      for (let i = 0; i < L; i++) out[i] = mic[i]
    } else {
      // Double-talk DETECTION, retained verbatim but now DIAGNOSTIC ONLY. It
      // reads the BACKGROUND's residual, because the background is the direct
      // successor of the old single filter (always adapting, converging on the
      // same signal), which is what keeps dtPct comparable to every dtPct this
      // project has logged. Nothing downstream of dtActive touches audio or
      // adaptation any more — comparison gating replaced it.
      if (bgEPow > 0.5 * micPow) {
        dtHangover = 0
        if (wasConverged) {
          dtCount++
        }
      } else {
        if (dtCount >= 3) {
          dtHangover++
          if (dtHangover >= 25) {
            dtCount = 0
            dtHangover = 0
          }
        } else {
          dtCount = 0
          dtHangover = 0
        }
      }

      const dtActive = dtCount >= 3
      activeBlocks++
      if (dtActive) dtBlocks++

      // Delivery is the foreground's error under the gate, unchanged, and now
      // unconditional on double-talk: there is no longer a state in which the
      // canceller behaves differently because a detector fired.
      for (let i = 0; i < L; i++) out[i] = gateOpen ? e[i] : mic[i]
      // The shadow adapts on every active block, so "adapting" is now simply
      // "the far end is not silent".
      lastAdapting = true

      {
        // BACKGROUND UPDATE at FULL μ. No double-talk leak, no freeze: the
        // shadow is allowed to be wrong, and being wrong costs nothing because
        // it is never delivered and never promoted while it measures worse than
        // what is already in the path.
        //
        // The echo-to-error step scaling stays, and it is NOT double-talk
        // gating — it is the NLMS normalization that keeps a single
        // unexplainable block from throwing the whole weight set (μ shrinks
        // with y/e once there is a real echo estimate to compare against, and
        // is inert before convergence when y is still small). It reads the
        // BACKGROUND's own y and e, since these are the background's updates.
        const muScale = wasConverged ? Math.min(1, bgYPow / Math.max(bgEPow, 1e-12)) : 1

        // Zero-padded error FFT: E = FFT([0, ..., 0, bgE])
        ePaddedRe.fill(0)
        for (let i = 0; i < L; i++) ePaddedRe[L + i] = bgE[i]
        ePaddedIm.fill(0)
        fft(ePaddedRe, ePaddedIm, fftOutRe, fftOutIm)

        // Exponential moving average of reference power Px_hat (smoothing ~0.9)
        for (let k = 0; k < N; k++) {
          let sumPx = 0
          for (let p = 0; p < P; p++) {
            const pIdx = (xHead + p) % P
            const xR = X_re[pIdx][k]
            const xI = X_im[pIdx][k]
            sumPx += xR * xR + xI * xI
          }
          Px_hat[k] = 0.9 * Px_hat[k] + 0.1 * sumPx
          norm[k] = muScale * 0.5 / (Math.max(Px_hat[k], sumPx) + 1e-10)
        }

        // Applying gradient constraint (IFFT, zero second half, FFT back)
        // to each updated partition every block for fastest convergence.
        for (let p = 0; p < P; p++) {
          const pIdx = (xHead + p) % P
          const xR = X_re[pIdx]
          const xI = X_im[pIdx]
          const eR = fftOutRe
          const eI = fftOutIm

          for (let k = 0; k < N; k++) {
            dW_re[k] = norm[k] * (xR[k] * eR[k] + xI[k] * eI[k])
            dW_im[k] = norm[k] * (xR[k] * eI[k] - xI[k] * eR[k])
          }

          ifft(dW_re, dW_im, scratchRe, scratchIm)
          for (let n = L; n < N; n++) {
            scratchRe[n] = 0
            scratchIm[n] = 0
          }
          fft(scratchRe, scratchIm, dW_re, dW_im)

          const wR = bgW_re[p]
          const wI = bgW_im[p]
          for (let k = 0; k < N; k++) {
            wR[k] += dW_re[k]
            wI[k] += dW_im[k]
          }
        }
      }
    }

    // 7. Update ERLE statistics — one EMA per filter, same signal, same
    //    update gating, so the two numbers are directly comparable. This
    //    comparison IS the architecture: it is how a hypothesis becomes the
    //    delivered filter.
    if (refPow >= 1e-8 && micPow > 1e-8) {
      const instErleDb = 10 * Math.log10(micPow / Math.max(1e-12, ePow))
      if (erleDbEma === null) {
        erleDbEma = instErleDb
      } else {
        erleDbEma = 0.95 * erleDbEma + 0.05 * instErleDb
      }
      const bgInstErleDb = 10 * Math.log10(micPow / Math.max(1e-12, bgEPow))
      if (bgErleDbEma === null) {
        bgErleDbEma = bgInstErleDb
      } else {
        bgErleDbEma = 0.95 * bgErleDbEma + 0.05 * bgInstErleDb
      }
      // Convergence is a property of the ADAPTING filter (it scales the
      // shadow's own step size and arms the DTD diagnostic).
      if (bgErleDbEma >= 6) {
        wasConverged = true
      }

      // COPY RULE (bg -> fg). Two ways in:
      //
      //  1. PROVEN BETTER: the shadow beats the delivered filter by >= 3 dB
      //     AND clears 3 dB of real help on its own, no sooner than ~1 s after
      //     the last copy. The margin is what makes erosion impossible to
      //     deliver — a contaminated shadow measures WORSE and simply never
      //     arrives — and the cooldown stops two similar weight sets from
      //     trading places every few blocks while EMAs jitter.
      //  2. PROVEN HARM, immediate, no cooldown: the foreground is ADDING
      //     energy (< -2 dB, an echo path that moved or vanished under an open
      //     gate) and the shadow is at least not harmful (>= 0 dB). Waiting out
      //     a cooldown here would mean knowingly delivering harm; the gate's
      //     own instant harm-close has the same rationale.
      const fgErle = erleDbEma
      const bgErle = bgErleDbEma
      const provenBetter = bgErle >= 3 && (bgErle - fgErle) >= 3 &&
        (blockCount - lastCopyBlock) >= COPY_COOLDOWN
      const rescue = fgErle < -2 && bgErle >= 0
      if (provenBetter || rescue) {
        promote()
      } else if (copies > 0 && fgErle < 1) {
        // ESCAPE VALVE, rewired for the shadow. The old trigger counted blocks
        // of frozen adaptation — a state that no longer exists, since the
        // shadow never freezes. What CAN still deadlock is this: the foreground
        // holds weights that were genuinely proven once, the echo path has since
        // moved, so the foreground mispredicts (< 1 dB of help), and yet the
        // shadow cannot muster the 3 dB margin needed to replace it. That means
        // the shadow is stuck too — poisoned by sustained corruption, or aimed
        // at a bulk delay that no longer holds — and no amount of further
        // gradient on the same wrong point of departure will fix it. After 6 s
        // (the same limit, and still longer than any plausible unbroken
        // double-talk) the shadow gets a clean restart from zero, which is the
        // one state guaranteed not to be poisoned. The foreground is left
        // alone: its weights are the best measurement we ever had, and the
        // do-no-harm gate is already what protects the listener from them.
        if (++stallBlocks > 2250) resetWeights()
      } else {
        stallBlocks = 0
      }
      // The harm gate's only inputs: proven help opens it, proven none
      // closes it. Both thresholds live on the EMA — and the CLOSE now has a
      // dwell on top: the first long real call (room xow-offc-apz, two Macs
      // one room apart, 2026-08-11) sat with ERLE breathing around the 1–3 dB
      // band and flipped the gate 12 times — echo pumping in and out is worse
      // to a listener than either steady state. Open stays instant (help
      // proven = deliver now); close waits for the EMA to hold under 1 dB for
      // 750 consecutive blocks (~2 s at 48 kHz/128) so one breath of
      // near-threshold ERLE no longer toggles the ear.
      if (!gateOpen && erleDbEma >= 3) { gateOpen = true; gateLowBlocks = 0 }
      else if (gateOpen) {
        // Two-tier close. PROVEN HARM (< -2 dB: the filter is adding energy —
        // an echo path that vanished under an open gate, e.g. speaker muted
        // or a spurious correlation collapsing) exits IMMEDIATELY: the live
        // rig caught the dwell delivering -6.6 dB for its full 2 s, which is
        // worse than the flip it prevents. AMBIGUITY (between -2 and 1 dB)
        // keeps the dwell, because that band is where xow-offc-apz pumped.
        if (erleDbEma < -2) { gateOpen = false; gateLowBlocks = 0 }
        else if (erleDbEma < 1) { if (++gateLowBlocks > 750) { gateOpen = false; gateLowBlocks = 0 } }
        else gateLowBlocks = 0
      }
    }

    // 8. Bulk-delay estimation (~every 250 blocks)
    if (blockCount % 250 === 0 && rmsHistCount >= 150) {
      const M = 100
      const maxLag = Math.min(280, rmsHistCount - M)

      if (maxLag > 0) {
        let micSum = 0, micSqSum = 0
        for (let i = 0; i < M; i++) {
          const histIdx = (rmsHistHead - M + i + maxRmsHist) % maxRmsHist
          const v = micRmsHist[histIdx]
          scratchMicRms[i] = v
          micSum += v
          micSqSum += v * v
        }
        const micMean = micSum / M
        const micVar = Math.max(1e-12, micSqSum / M - micMean * micMean)
        const micStd = Math.sqrt(micVar)

        let maxCorr = -1
        let bestLag = 0
        let currCorr = -1

        for (let d = 0; d <= maxLag; d++) {
          let refSum = 0, refSqSum = 0, crossSum = 0
          for (let i = 0; i < M; i++) {
            const histIdx = (rmsHistHead - M + i - d + maxRmsHist * 2) % maxRmsHist
            const rVal = refRmsHist[histIdx]
            refSum += rVal
            refSqSum += rVal * rVal
            crossSum += scratchMicRms[i] * rVal
          }
          const refMean = refSum / M
          const refVar = Math.max(1e-12, refSqSum / M - refMean * refMean)
          const refStd = Math.sqrt(refVar)
          const cov = (crossSum / M) - (micMean * refMean)
          const corr = cov / (micStd * refStd)

          if (d === delayBlocks) {
            currCorr = corr
          }
          if (corr > maxCorr) {
            maxCorr = corr
            bestLag = d
          }
        }

        if (!hasDecisiveEstimate) {
          if (maxCorr >= 0.25) {
            // Aim 2 blocks short to maintain causality against RMS block quantization and reverb tails
            lastBestLag = bestLag
            delayBlocks = Math.max(0, bestLag - 2)
            hasDecisiveEstimate = true
            resetWeightsBoth()
          }
        } else {
          if (Math.abs(bestLag - lastBestLag) > 1 && maxCorr >= 1.5 * Math.max(0.1, currCorr) && maxCorr >= 0.25) {
            // Aim 2 blocks short to maintain causality against RMS block quantization and reverb tails
            lastBestLag = bestLag
            delayBlocks = Math.max(0, bestLag - 2)
            resetWeightsBoth()
          }
        }
      }
    }

    return out
  }

  function stats() {
    return {
      erleDb: erleDbEma,
      delayBlocks: delayBlocks,
      adapting: lastAdapting,
      converged: erleDbEma !== null && erleDbEma >= 12,
      gate: gateOpen ? 1 : 0,
      dtPct: activeBlocks ? +((100 * dtBlocks) / activeBlocks).toFixed(1) : null,
      // Shadow-filter observability: what the always-adapting hypothesis is
      // achieving right now, and how many times it has won the comparison.
      // bgErleDb >> erleDb means a promotion is pending or being blocked;
      // copies climbing means the room is changing under the filter.
      bgErleDb: bgErleDbEma,
      copies: copies
    }
  }

  return {
    process,
    stats,
    reset
  }
}
