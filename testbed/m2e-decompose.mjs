#!/usr/bin/env node
/**
 * Mouth-to-ear latency decomposition rig for Tokkah.
 * Turns aggregate mouthToEarMs into named, blame-assignable components:
 *   - frameMs (8ms frame assembly)
 *   - netAgeP50Ms / netAgeP90Ms (network + queueing age)
 *   - ringDepthMs (playout ring depth)
 *   - outputMs (device output path latency)
 *   - inputMs (AudioContext base processing latency, lower bound)
 *
 * Runs two headless Chrome peers in a room on https://room.tokkah.com (?r=m2e-<ts>).
 * Waits for WebRTC connection, runs 30s, samples window.__tape.pcm.snapshot() every 5s
 * for 30s more, prints median component tables for each side, names the largest component,
 * and asserts that mouthToEarMs is present and matches the decomposition sum within 1ms.
 */

import { chromium } from 'playwright-core';

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const LOCAL_PCM_JS = join(HERE, '../tape-app/public/pcm.js');

const CHROME = process.env.TESTBED_CHROME ??
  (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');

const fixture = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);

const argsFor = (who) => ([
  '--use-fake-ui-for-media-stream',
  '--use-fake-device-for-media-stream',
  `--use-file-for-fake-audio-capture=${fixture(who === 'a' ? 'realA.wav' : 'realB.wav')}`,
  `--use-file-for-fake-video-capture=${fixture(who === 'a' ? 'realA.mjpeg' : 'realB.mjpeg')}`,
  '--autoplay-policy=no-user-gesture-required',
  '--alsa-output-device=null',
]);

const median = (arr) => {
  const nums = arr.filter((x) => typeof x === 'number' && !isNaN(x)).sort((a, b) => a - b);
  if (!nums.length) return null;
  const mid = Math.floor(nums.length / 2);
  return nums.length % 2 === 1 ? nums[mid] : +((nums[mid - 1] + nums[mid]) / 2).toFixed(1);
};

async function main() {
  const room = `m2e-${Date.now().toString(36)}`;
  // Flags, so this can be an A/B rather than a single reading. It measures the
  // budget the whole project is graded on and could only ever report one arm,
  // which is how a suspected clean-path regression had no way to be tested.
  //   node testbed/m2e-decompose.mjs --qs='&pcmjitfar=0'
  const extraQs = process.argv.find((a) => a.startsWith('--qs='))?.slice(5) ?? '';
  const url = `https://room.tokkah.com/?r=${room}${extraQs}`;
  console.log(`[m2e-decompose] Launching 2 peers into room: ${room}`);

  const bA = await chromium.launch({ executablePath: CHROME, headless: true, args: argsFor('a') });
  const bB = await chromium.launch({ executablePath: CHROME, headless: true, args: argsFor('b') });

  try {
    const pA = await bA.newPage();
    const pB = await bB.newPage();

    // Testing law: verdicts come from the DEPLOYED code. --local intercepts
    // pcm.js with the working-tree copy for pre-deploy smoke only.
    if (process.argv.includes('--local')) {
      const localPcmJs = readFileSync(LOCAL_PCM_JS, 'utf8');
      await pA.route('**/pcm.js*', (route) => route.fulfill({ status: 200, contentType: 'application/javascript', body: localPcmJs }));
      await pB.route('**/pcm.js*', (route) => route.fulfill({ status: 200, contentType: 'application/javascript', body: localPcmJs }));
      console.log('[m2e-decompose] --local: working-tree pcm.js intercepted (pre-deploy smoke, not a verdict)');
    }

    console.log('[m2e-decompose] Navigating to room...');
    await pA.goto(url);
    await pA.click('#join');

    await pB.goto(url);
    await pB.click('#join');

    console.log('[m2e-decompose] Waiting for WebRTC connection...');
    await Promise.all([
      pA.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 }),
      pB.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 }),
    ]);
    console.log('[m2e-decompose] Connected. Running call for 30s before sampling...');
    await Promise.all([pA.waitForTimeout(30000), pB.waitForTimeout(30000)]);

    console.log('[m2e-decompose] Sampling snapshots every 5s for 30s...');
    const samplesA = [];
    const samplesB = [];
    const sampleCount = 7;

    for (let i = 0; i < sampleCount; i++) {
      if (i > 0) {
        await Promise.all([pA.waitForTimeout(5000), pB.waitForTimeout(5000)]);
      }
      const snapA = await pA.evaluate(() => {
        const p = window.__tape?.pcm;
        return typeof p?.snapshot === 'function' ? p.snapshot() : (p ?? null);
      });
      const snapB = await pB.evaluate(() => {
        const p = window.__tape?.pcm;
        return typeof p?.snapshot === 'function' ? p.snapshot() : (p ?? null);
      });
      if (snapA) samplesA.push(snapA);
      if (snapB) samplesB.push(snapB);
      console.log(`  Sample ${i + 1}/${sampleCount}: sideA m2e=${snapA?.mouthToEarMs ?? 'null'}, sideB m2e=${snapB?.mouthToEarMs ?? 'null'}`);
    }

    const m2eA = median(samplesA.map((s) => s?.mouthToEarMs));
    const frameMsA = median(samplesA.map((s) => s?.m2eParts?.frameMs));
    const netAgeP50A = median(samplesA.map((s) => s?.m2eParts?.netAgeP50Ms));
    const netAgeP90A = median(samplesA.map((s) => s?.m2eParts?.netAgeP90Ms));
    const ringDepthA = median(samplesA.map((s) => s?.m2eParts?.ringDepthMs));
    const outputA = median(samplesA.map((s) => s?.m2eParts?.outputMs));
    const inputA = median(samplesA.map((s) => s?.m2eParts?.inputMs));
    const framesRecvA = median(samplesA.map((s) => s?.framesRecv));
    const fecRepairedA = median(samplesA.map((s) => s?.fecRepaired));

    const m2eB = median(samplesB.map((s) => s?.mouthToEarMs));
    const frameMsB = median(samplesB.map((s) => s?.m2eParts?.frameMs));
    const netAgeP50B = median(samplesB.map((s) => s?.m2eParts?.netAgeP50Ms));
    const netAgeP90B = median(samplesB.map((s) => s?.m2eParts?.netAgeP90Ms));
    const ringDepthB = median(samplesB.map((s) => s?.m2eParts?.ringDepthMs));
    const outputB = median(samplesB.map((s) => s?.m2eParts?.outputMs));
    const inputB = median(samplesB.map((s) => s?.m2eParts?.inputMs));
    const framesRecvB = median(samplesB.map((s) => s?.framesRecv));
    const fecRepairedB = median(samplesB.map((s) => s?.fecRepaired));

    console.log('\n--- Peer A Mouth-to-Ear Breakdown (Medians) ---');
    console.table({
      mouthToEarMs: m2eA,
      frameMs: frameMsA,
      netAgeP50Ms: netAgeP50A,
      netAgeP90Ms: netAgeP90A,
      ringDepthMs: ringDepthA,
      outputMs: outputA,
      inputMs: inputA,
      framesRecv: framesRecvA,
      fecRepaired: fecRepairedA,
    });

    console.log('\n--- Peer B Mouth-to-Ear Breakdown (Medians) ---');
    console.table({
      mouthToEarMs: m2eB,
      frameMs: frameMsB,
      netAgeP50Ms: netAgeP50B,
      netAgeP90Ms: netAgeP90B,
      ringDepthMs: ringDepthB,
      outputMs: outputB,
      inputMs: inputB,
      framesRecv: framesRecvB,
      fecRepaired: fecRepairedB,
    });

    console.log('\n--- Side-by-Side Comparison ---');
    console.table({
      mouthToEarMs: { 'Peer A': m2eA, 'Peer B': m2eB },
      frameMs: { 'Peer A': frameMsA, 'Peer B': frameMsB },
      netAgeP50Ms: { 'Peer A': netAgeP50A, 'Peer B': netAgeP50B },
      netAgeP90Ms: { 'Peer A': netAgeP90A, 'Peer B': netAgeP90B },
      ringDepthMs: { 'Peer A': ringDepthA, 'Peer B': ringDepthB },
      outputMs: { 'Peer A': outputA, 'Peer B': outputB },
      inputMs: { 'Peer A': inputA, 'Peer B': inputB },
      framesRecv: { 'Peer A': framesRecvA, 'Peer B': framesRecvB },
      fecRepaired: { 'Peer A': fecRepairedA, 'Peer B': fecRepairedB },
    });

    // MACHINE-READABLE, so this can be driven in paired rounds from outside
    // (testbed/m2e-ab.mjs). The tables above are for a human reading one call;
    // they cannot be aggregated, and a single call cannot resolve the ~7 ms of
    // run-to-run spread this metric actually has (42.4-49.2 ms observed in one
    // day). Reading one of them as a result is how a 4 ms "regression" got
    // diagnosed, acted on, and then contradicted by the very next run.
    console.log('M2ERESULT ' + JSON.stringify({
      m2eA, m2eB, ringA: ringDepthA, ringB: ringDepthB,
      outA: outputA, outB: outputB, netA: netAgeP50A, netB: netAgeP50B,
    }));

    // Determine largest component of mouthToEarMs breakdown
    const partsAvg = [
      { name: 'frameMs', val: ((frameMsA ?? 0) + (frameMsB ?? 0)) / 2 },
      { name: 'netAgeP50Ms', val: ((netAgeP50A ?? 0) + (netAgeP50B ?? 0)) / 2 },
      { name: 'ringDepthMs', val: ((ringDepthA ?? 0) + (ringDepthB ?? 0)) / 2 },
      { name: 'outputMs', val: ((outputA ?? 0) + (outputB ?? 0)) / 2 },
    ];
    partsAvg.sort((a, b) => b.val - a.val);
    const largest = partsAvg[0];

    console.log(`Verdict: Largest mouth-to-ear latency component is ${largest.name} (${largest.val.toFixed(1)} ms).`);

    // Assertions
    let pass = true;
    if (m2eA == null || m2eB == null) {
      console.error(`FAIL: mouthToEarMs missing — Peer A: ${m2eA}, Peer B: ${m2eB}`);
      pass = false;
    }

    const sumA = (frameMsA ?? 0) + (netAgeP50A ?? 0) + (ringDepthA ?? 0) + (outputA ?? 0);
    const diffA = Math.abs(sumA - (m2eA ?? 0));
    if (diffA > 1.0) {
      console.error(`FAIL: Peer A sum ${sumA.toFixed(1)}ms does not reconcile with mouthToEarMs ${m2eA}ms (diff ${diffA.toFixed(2)}ms)`);
      pass = false;
    }

    const sumB = (frameMsB ?? 0) + (netAgeP50B ?? 0) + (ringDepthB ?? 0) + (outputB ?? 0);
    const diffB = Math.abs(sumB - (m2eB ?? 0));
    if (diffB > 1.0) {
      console.error(`FAIL: Peer B sum ${sumB.toFixed(1)}ms does not reconcile with mouthToEarMs ${m2eB}ms (diff ${diffB.toFixed(2)}ms)`);
      pass = false;
    }

    if (!pass) {
      process.exit(1);
    }
  } finally {
    await bA.close();
    await bB.close();
  }
}

main().catch((err) => {
  console.error('Fatal error in m2e-decompose rig:', err);
  process.exit(1);
});
