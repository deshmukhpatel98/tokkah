/**
 * Partitioned-Block Frequency-Domain Adaptive Filter (PBFDAF) Acoustic Echo Canceller
 * 48 kHz voice lane linear DSP core.
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

  // Adaptive filter complex weights W (size P x N)
  const W_re = Array.from({ length: P }, () => new Float32Array(N))
  const W_im = Array.from({ length: P }, () => new Float32Array(N))

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
  const e = new Float32Array(L)
  const out = new Float32Array(L)

  // State variables
  let delayBlocks = 0
  let lastBestLag = 0
  let hasDecisiveEstimate = false
  let blockCount = 0
  let erleDbEma = null
  let lastAdapting = false
  let dtCount = 0
  let wasConverged = false
  let dtHangover = 0
  let dtFrozenBlocks = 0
  let refSilentBlocks = 0

  function resetWeights() {
    for (let p = 0; p < P; p++) {
      W_re[p].fill(0)
      W_im[p].fill(0)
    }
    prevDelayedRef.fill(0)
    Px_hat.fill(0)
    dtCount = 0
    dtHangover = 0
    dtFrozenBlocks = 0
    wasConverged = false
    // The ERLE EMA describes the weights that were just wiped. Left standing,
    // it re-latches wasConverged against a zeroed filter on the very next
    // block (e ≈ mic), and the double-talk freeze then starves adaptation for
    // seconds — measured: 1300 blocks frozen after a delay re-alignment.
    erleDbEma = null
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
    resetWeights()
    delayBlocks = 0
    lastBestLag = 0
    hasDecisiveEstimate = false
    blockCount = 0
    erleDbEma = null
    lastAdapting = false
    wasConverged = false
    dtHangover = 0
    refSilentBlocks = 0
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

    // 4. Synthesize echo estimate Y = sum_p X[p] * W[p]
    fftInRe.fill(0)
    fftInIm.fill(0)
    for (let p = 0; p < P; p++) {
      const pIdx = (xHead + p) % P
      const xR = X_re[pIdx]
      const xI = X_im[pIdx]
      const wR = W_re[p]
      const wI = W_im[p]
      for (let k = 0; k < N; k++) {
        fftInRe[k] += xR[k] * wR[k] - xI[k] * wI[k]
        fftInIm[k] += xR[k] * wI[k] + xI[k] * wR[k]
      }
    }

    // IFFT to get time-domain echo estimate (y is last L samples)
    ifft(fftInRe, fftInIm, fftOutRe, fftOutIm)

    // Compute error e = mic - y
    let micSumSq = 0
    let refSumSq = 0
    let eSumSq = 0
    let ySumSq = 0
    for (let i = 0; i < L; i++) {
      const micVal = mic[i]
      const yVal = fftOutRe[L + i]
      const eVal = micVal - yVal
      e[i] = eVal

      micSumSq += micVal * micVal
      refSumSq += delayedRef[i] * delayedRef[i]
      eSumSq += eVal * eVal
      ySumSq += yVal * yVal
    }

    const micPow = micSumSq / L
    const refPow = refSumSq / L
    const ePow = eSumSq / L
    const yPow = ySumSq / L

    // 5. Track block RMS history for bulk-delay estimation (raw ref)
    let rawRefSumSq = 0
    for (let i = 0; i < L; i++) rawRefSumSq += ref[i] * ref[i]
    micRmsHist[rmsHistHead] = Math.sqrt(micPow)
    refRmsHist[rmsHistHead] = Math.sqrt(rawRefSumSq / L)
    rmsHistHead = (rmsHistHead + 1) % maxRmsHist
    if (rmsHistCount < maxRmsHist) rmsHistCount++
    blockCount++

    // 6. Double-talk protection & Far-end silence check
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
      if (ePow > 0.5 * micPow) {
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

      if (dtCount >= 3) {
        // Double talk: freeze adaptation but keep subtracting
        lastAdapting = false
        for (let i = 0; i < L; i++) out[i] = e[i]
        // Escape valve: a freeze that outlives any plausible unbroken
        // double-talk (6 s) is really a CHANGED echo path — the frozen filter
        // mispredicts, e stays large, and without this the freeze is
        // permanent because release requires the very convergence it blocks.
        if (++dtFrozenBlocks > 2250) resetWeights()
      } else {
        dtFrozenBlocks = 0
        // Single talk: adapt filter weights
        lastAdapting = true
        for (let i = 0; i < L; i++) out[i] = e[i]

        // Echo-to-error step scaling: once converged, an error block the echo
        // estimate cannot explain is near-end speech the binary DTD hasn't
        // caught yet (it needs 3 blocks), and a full-rate update on it
        // corrupts the filter. μ shrinks with yPow/ePow, so those first
        // blocks barely adapt. Never applied before convergence — y is still
        // small then and the scale would starve the initial adaptation.
        const muScale = wasConverged ? Math.min(1, yPow / Math.max(ePow, 1e-12)) : 1

        // Zero-padded error FFT: E = FFT([0, ..., 0, e])
        ePaddedRe.fill(0)
        for (let i = 0; i < L; i++) ePaddedRe[L + i] = e[i]
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

          const wR = W_re[p]
          const wI = W_im[p]
          for (let k = 0; k < N; k++) {
            wR[k] += dW_re[k]
            wI[k] += dW_im[k]
          }
        }
      }
    }

    // 7. Update ERLE statistic
    if (refPow >= 1e-8 && micPow > 1e-8) {
      const instErleDb = 10 * Math.log10(micPow / Math.max(1e-12, ePow))
      if (erleDbEma === null) {
        erleDbEma = instErleDb
      } else {
        erleDbEma = 0.95 * erleDbEma + 0.05 * instErleDb
      }
      if (erleDbEma >= 6) {
        wasConverged = true
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
            resetWeights()
          }
        } else {
          if (Math.abs(bestLag - lastBestLag) > 1 && maxCorr >= 1.5 * Math.max(0.1, currCorr) && maxCorr >= 0.25) {
            // Aim 2 blocks short to maintain causality against RMS block quantization and reverb tails
            lastBestLag = bestLag
            delayBlocks = Math.max(0, bestLag - 2)
            resetWeights()
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
      converged: erleDbEma !== null && erleDbEma >= 12
    }
  }

  return {
    process,
    stats,
    reset
  }
}
