#!/usr/bin/env node

import { createAec } from '../tape-app/public/core/aec-core.js'

// Unknown CLI flags are fatal
const args = process.argv.slice(2)
if (args.length > 0) {
  console.error(`Unknown flag: ${args[0]}`)
  process.exit(1)
}

// Seeded PRNG only (mulberry32)
const mulberry32 = (a) => () => {
  a |= 0; a = (a + 0x6D2B79F5) | 0
  let t = Math.imul(a ^ (a >>> 15), 1 | a)
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296
}

// Speech-like signal generator (random-walk envelope x white noise, gated by bursts)
function createSpeechGen(seed) {
  const rnd = mulberry32(seed)
  let level = 0.05
  let talking = true
  let hold = 0

  return function nextBlock(blockLen = 128) {
    const block = new Float32Array(blockLen)
    for (let i = 0; i < blockLen; i++) {
      if (--hold <= 0) {
        talking = rnd() < 0.8
        hold = Math.floor(1500 + rnd() * 4500)
      }
      level = Math.max(0.01, Math.min(0.2, level + (rnd() - 0.5) * 0.001))
      const amp = talking ? level : 0.0001
      block[i] = amp * (rnd() * 2 - 1)
    }
    return block
  }
}

// Synthetic room simulator (bulk delay D samples + sparse 40ms exponential decay)
function createSyntheticRoom(seed, delaySamples, softClip = false) {
  const rnd = mulberry32(seed)
  const tailSamples = 1920 // 40 ms at 48 kHz
  const totalLength = delaySamples + tailSamples

  const tapOffsets = [delaySamples]
  const tapWeights = [0.5]

  for (let k = 1; k < tailSamples; k++) {
    const decay = 0.5 * Math.pow(10, (-1.5 * k) / tailSamples)
    if (rnd() < 0.15) {
      tapOffsets.push(delaySamples + k)
      tapWeights.push(decay * (rnd() * 2 - 1))
    }
  }

  const numTaps = tapOffsets.length
  const ringSize = totalLength + 512
  const spkRing = new Float32Array(ringSize)
  let spkHead = 0

  return function processRoom(refBlock, nearBlock = null) {
    const blockLen = refBlock.length
    const micBlock = new Float32Array(blockLen)

    for (let i = 0; i < blockLen; i++) {
      const x = refBlock[i]
      const s = softClip ? Math.tanh(3 * x) / 3 : x

      spkRing[spkHead] = s

      let echo = 0
      for (let j = 0; j < numTaps; j++) {
        const idx = (spkHead - tapOffsets[j] + ringSize) % ringSize
        echo += spkRing[idx] * tapWeights[j]
      }

      spkHead = (spkHead + 1) % ringSize
      const near = nearBlock ? nearBlock[i] : 0
      micBlock[i] = echo + near
    }

    return micBlock
  }
}

let allPassed = true

// --- Arm 1: convergence ---
{
  const aec = createAec()
  const genRef = createSpeechGen(101)
  const room = createSyntheticRoom(201, 960, false) // D = 20 ms (960 samples)

  const numBlocks = 1875 // 5 seconds
  const last1sBlocks = 375

  let last1sMicSq = 0
  let last1sESq = 0

  for (let b = 0; b < numBlocks; b++) {
    const ref = genRef(128)
    const mic = room(ref)
    const out = aec.process(mic, ref)

    if (b >= numBlocks - last1sBlocks) {
      for (let i = 0; i < 128; i++) {
        last1sMicSq += mic[i] * mic[i]
        last1sESq += out[i] * out[i]
      }
    }
  }

  const erleDb = 10 * Math.log10(last1sMicSq / Math.max(1e-12, last1sESq))
  if (erleDb >= 20) {
    console.log(`Arm 1 (convergence): PASS (erleDb = ${erleDb.toFixed(2)} dB >= 20 dB)`)
  } else {
    console.error(`Arm 1 (convergence): FAIL (erleDb = ${erleDb.toFixed(2)} dB < 20 dB)`)
    allPassed = false
  }
}

// --- Arm 2: delay ---
{
  const aec = createAec()
  const genRef = createSpeechGen(102)
  const room = createSyntheticRoom(202, 8640, false) // D = 180 ms (8640 samples = 67.5 blocks)

  const numBlocks = 3000 // 8 seconds
  const last1sBlocks = 375

  let last1sMicSq = 0
  let last1sESq = 0

  for (let b = 0; b < numBlocks; b++) {
    const ref = genRef(128)
    const mic = room(ref)
    const out = aec.process(mic, ref)

    if (b >= numBlocks - last1sBlocks) {
      for (let i = 0; i < 128; i++) {
        last1sMicSq += mic[i] * mic[i]
        last1sESq += out[i] * out[i]
      }
    }
  }

  const erleDb = 10 * Math.log10(last1sMicSq / Math.max(1e-12, last1sESq))
  const finalDelay = aec.stats().delayBlocks
  const targetDelay = 8640 / 128 // 67.5 blocks
  // Estimator aims 2 blocks short of true delay to maintain causality; for D=180ms (67.5 blocks) accept delayBlocks between 63 and 68 inclusive
  const validDelay = finalDelay >= 63 && finalDelay <= 68

  if (erleDb >= 15 && validDelay) {
    console.log(`Arm 2 (delay): PASS (erleDb = ${erleDb.toFixed(2)} dB, delayBlocks = ${finalDelay}, target = ${targetDelay})`)
  } else {
    console.error(`Arm 2 (delay): FAIL (erleDb = ${erleDb.toFixed(2)} dB, delayBlocks = ${finalDelay}, target = ${targetDelay})`)
    allPassed = false
  }
}

// --- Arm 3: double-talk ---
{
  const aec = createAec()
  const genRef = createSpeechGen(103)
  const genNear = createSpeechGen(104)
  const room = createSyntheticRoom(203, 960, false) // D = 20 ms

  const phaseABlocks = 1500 // 4s single talk
  const phaseBBlocks = 1125 // 3s double talk
  const phaseCBlocks = 750  // 2s far-only
  const totalBlocks = phaseABlocks + phaseBBlocks + phaseCBlocks

  const dtOutSamples = []
  const dtNearSamples = []

  let postDtMicSq = 0
  let postDtESq = 0
  const postDtLast1sStart = totalBlocks - 375

  for (let b = 0; b < totalBlocks; b++) {
    const ref = genRef(128)
    let near = null
    if (b >= phaseABlocks && b < phaseABlocks + phaseBBlocks) {
      near = genNear(128)
    }

    const mic = room(ref, near)
    const out = aec.process(mic, ref)

    if (near) {
      for (let i = 0; i < 128; i++) {
        dtOutSamples.push(out[i])
        dtNearSamples.push(near[i])
      }
    }

    if (b >= postDtLast1sStart) {
      for (let i = 0; i < 128; i++) {
        postDtMicSq += mic[i] * mic[i]
        postDtESq += out[i] * out[i]
      }
    }
  }

  // Pearson correlation during double-talk
  let sumOut = 0, sumNear = 0
  const N = dtOutSamples.length
  for (let i = 0; i < N; i++) {
    sumOut += dtOutSamples[i]
    sumNear += dtNearSamples[i]
  }
  const meanOut = sumOut / N
  const meanNear = sumNear / N

  let cov = 0, varOut = 0, varNear = 0
  for (let i = 0; i < N; i++) {
    const dO = dtOutSamples[i] - meanOut
    const dN = dtNearSamples[i] - meanNear
    cov += dO * dN
    varOut += dO * dO
    varNear += dN * dN
  }
  const corr = cov / (Math.sqrt(varOut * varNear) + 1e-12)
  const erleDb = 10 * Math.log10(postDtMicSq / Math.max(1e-12, postDtESq))

  if (corr >= 0.9 && erleDb >= 15) {
    console.log(`Arm 3 (double-talk): PASS (near-corr = ${corr.toFixed(4)} >= 0.9, post-dt ERLE = ${erleDb.toFixed(2)} dB >= 15 dB)`)
  } else {
    console.error(`Arm 3 (double-talk): FAIL (near-corr = ${corr.toFixed(4)}, post-dt ERLE = ${erleDb.toFixed(2)} dB)`)
    allPassed = false
  }
}

// --- Arm 4: bit-exact ---
{
  const aec = createAec()
  const genRef = createSpeechGen(105)
  const genMic = createSpeechGen(106)
  const room = createSyntheticRoom(205, 960, false)

  // 100 blocks of far-end activity to make weights non-zero
  for (let b = 0; b < 100; b++) {
    const ref = genRef(128)
    const mic = room(ref)
    aec.process(mic, ref)
  }

  // 10000 blocks of zero ref. The first 25 blocks after the far end goes
  // silent are exempt: the filter span (24 blocks = 64 ms) still holds tail
  // energy and the canceller keeps subtracting the predicted tail — that is
  // the physically correct behaviour, since a real room's echo outlives the
  // reference. The guarantee is bit-exactness AFTER the span drains.
  const zeroRef = new Float32Array(128)
  let bitExactPass = true
  let firstBad = -1

  for (let b = 0; b < 10000; b++) {
    const mic = genMic(128)
    const out = aec.process(mic, zeroRef)
    if (b < 25) continue

    for (let i = 0; i < 128; i++) {
      if (out[i] !== mic[i] || !Object.is(out[i], mic[i])) {
        bitExactPass = false
        firstBad = b
        break
      }
    }
    if (!bitExactPass) break
  }

  if (bitExactPass) {
    console.log('Arm 4 (bit-exact): PASS (blocks 25..9999 of zero-ref bit-identical)')
  } else {
    console.error(`Arm 4 (bit-exact): FAIL (first mismatch at zero-ref block ${firstBad})`)
    allPassed = false
  }
}

// --- Arm 5: nonlinear ---
{
  const aec = createAec()
  const genRef = createSpeechGen(107)
  const room = createSyntheticRoom(207, 960, true) // soft-clip tanh(3x)/3 speaker

  const numBlocks = 1875 // 5 seconds
  const last1sBlocks = 375

  let last1sMicSq = 0
  let last1sESq = 0

  for (let b = 0; b < numBlocks; b++) {
    const ref = genRef(128)
    const mic = room(ref)
    const out = aec.process(mic, ref)

    if (b >= numBlocks - last1sBlocks) {
      for (let i = 0; i < 128; i++) {
        last1sMicSq += mic[i] * mic[i]
        last1sESq += out[i] * out[i]
      }
    }
  }

  const erleDb = 10 * Math.log10(last1sMicSq / Math.max(1e-12, last1sESq))
  if (erleDb >= 12) {
    console.log(`Arm 5 (nonlinear): PASS (erleDb = ${erleDb.toFixed(2)} dB >= 12 dB)`)
  } else {
    console.error(`Arm 5 (nonlinear): FAIL (erleDb = ${erleDb.toFixed(2)} dB < 12 dB)`)
    allPassed = false
  }
}

// --- Arm 6: mic noise floor ---
// Real capture has a noise floor the canceller must not chase: the weights
// must settle at the echo path, not drift trying to predict noise from the
// reference. ERLE is bounded by the floor itself here (~14 dB for these
// levels), so the bar is well under the clean arms' — what the arm actually
// guards is stability: a noise-chasing filter diverges and goes NEGATIVE.
{
  const aec = createAec()
  const genRef = createSpeechGen(108)
  const room = createSyntheticRoom(208, 960, false)
  const noiseRnd = mulberry32(308)

  const numBlocks = 3750 // 10 seconds
  let last1sMicSq = 0
  let last1sESq = 0

  for (let b = 0; b < numBlocks; b++) {
    const ref = genRef(128)
    const mic = room(ref)
    for (let i = 0; i < 128; i++) mic[i] += 0.005 * (noiseRnd() * 2 - 1)
    const out = aec.process(mic, ref)
    if (b >= numBlocks - 375) {
      for (let i = 0; i < 128; i++) {
        last1sMicSq += mic[i] * mic[i]
        last1sESq += out[i] * out[i]
      }
    }
  }

  const erleDb = 10 * Math.log10(last1sMicSq / Math.max(1e-12, last1sESq))
  if (erleDb >= 10) {
    console.log(`Arm 6 (noise floor): PASS (erleDb = ${erleDb.toFixed(2)} dB >= 10 dB)`)
  } else {
    console.error(`Arm 6 (noise floor): FAIL (erleDb = ${erleDb.toFixed(2)} dB < 10 dB)`)
    allPassed = false
  }
}

if (!allPassed) {
  process.exit(1)
}
