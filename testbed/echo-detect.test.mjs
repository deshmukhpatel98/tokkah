#!/usr/bin/env node

import { createEchoDetector } from '../tape-app/public/echo-detect.js';

// Fail on unknown CLI flags
const args = process.argv.slice(2);
if (args.length > 0) {
  console.error(`Unknown flag: ${args[0]}`);
  process.exit(1);
}

let allPassed = true;

// --- Arm 1: Echo Arm ---
{
  const det = createEchoDetector();
  let detected = null;

  // Speech-like playout envelope generator
  const playRmsAt = (t) => {
    const env = 0.05 * (Math.sin(t * 0.005) + 1) * (Math.sin(t * 0.02) + 1) + 0.002;
    return Math.max(0, env);
  };

  // Simulate 10 s at 8 ms steps
  for (let t = 0; t <= 10000; t += 8) {
    const p = playRmsAt(t);
    const m = t >= 120 ? 0.4 * playRmsAt(t - 120) + 0.0002 : 0;
    det.play(t, p);
    det.mic(t, m);

    if (t > 0 && t % 500 === 0) {
      const res = det.poll(t);
      if (res && !detected) {
        detected = res;
      }
    }
  }

  if (detected && Math.abs(detected.lagMs - 120) <= 24) {
    console.log(`echo arm: PASS (corr=${detected.corr}, lagMs=${detected.lagMs})`);
  } else {
    console.error(`echo arm: FAIL (result=${JSON.stringify(detected)})`);
    allPassed = false;
  }
}

// --- Arm 2: Clean Arm ---
{
  const det = createEchoDetector();
  let detectedCount = 0;

  // Independent envelopes for play and mic
  const playRmsAt = (t) => Math.max(0, 0.05 * (Math.sin(t * 0.005) + 1) + 0.002);
  const micRmsAt = (t) => Math.max(0, 0.04 * (Math.cos(t * 0.013) + 1) + 0.002);

  // Simulate 30 s at 8 ms steps
  for (let t = 0; t <= 30000; t += 8) {
    det.play(t, playRmsAt(t));
    det.mic(t, micRmsAt(t));

    if (t > 0 && t % 500 === 0) {
      const res = det.poll(t);
      if (res) {
        detectedCount++;
      }
    }
  }

  if (detectedCount === 0) {
    console.log('clean arm: PASS (no false detections over 30s)');
  } else {
    console.error(`clean arm: FAIL (detected ${detectedCount} times on clean stream)`);
    allPassed = false;
  }
}

// --- Arms 3+4: seeded random-walk envelopes, 4 seeds each ---------------------
// A sinusoid is periodic, which makes both arms above too easy: the echo arm
// gets a perfectly repeating pattern to lock onto, and the clean arm's two
// tones can only collide at one frequency ratio. Speech is neither. A clamped
// random walk with bursts and silences is the shape the detector will actually
// see, and the seeds are fixed so a failure reproduces.
const mulberry32 = (a) => () => {
  a |= 0; a = (a + 0x6D2B79F5) | 0;
  let t = Math.imul(a ^ (a >>> 15), 1 | a);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
const walkEnv = (rnd) => {
  let level = 0.02, talking = 1, hold = 0;
  return () => {
    if (--hold <= 0) { talking = rnd() < 0.7 ? 1 : 0; hold = 40 + Math.floor(rnd() * 150); } // bursts/silences
    level = Math.max(0, Math.min(0.15, level + (rnd() - 0.5) * 0.01));
    return talking ? level + 0.001 : 0.0002;
  };
};
for (const seed of [1, 2, 3, 4]) {
  { // echo: mic = 0.4x play delayed 120 ms, plus noise
    const det = createEchoDetector();
    const env = walkEnv(mulberry32(seed));
    const noise = mulberry32(seed + 100);
    const hist = [];
    let detected = null;
    for (let t = 0; t <= 15000; t += 8) {
      const p = env();
      hist.push(p);
      const echoP = hist.length > 15 ? hist[hist.length - 16] : 0; // 15 frames = 120 ms
      det.play(t, p);
      det.mic(t, 0.4 * echoP + 0.003 * noise());
      if (t > 0 && t % 500 === 0 && !detected) detected = det.poll(t);
    }
    if (detected && Math.abs(detected.lagMs - 120) <= 24) {
      console.log(`walk echo seed=${seed}: PASS (corr=${detected.corr}, lagMs=${detected.lagMs})`);
    } else {
      console.error(`walk echo seed=${seed}: FAIL (result=${JSON.stringify(detected)})`);
      allPassed = false;
    }
  }
  { // clean: independent walks at similar levels
    const det = createEchoDetector();
    const envP = walkEnv(mulberry32(seed + 200));
    const envM = walkEnv(mulberry32(seed + 300));
    let detections = 0;
    for (let t = 0; t <= 30000; t += 8) {
      det.play(t, envP());
      det.mic(t, envM());
      if (t > 0 && t % 500 === 0 && det.poll(t)) detections++;
    }
    if (detections === 0) {
      console.log(`walk clean seed=${seed}: PASS`);
    } else {
      console.error(`walk clean seed=${seed}: FAIL (${detections} false detections)`);
      allPassed = false;
    }
  }
}

if (!allPassed) {
  process.exit(1);
}
