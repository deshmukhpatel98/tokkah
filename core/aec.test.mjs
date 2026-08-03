/**
 * Offline test suite for the AEC v2 kernel (task #27; design note
 * aec-v2-design.md §4.1). THE GATE: if the canceller cannot hit ERLE ≥ 20 dB
 * on synthetic delayed echo, no downstream worklet integration may start.
 *
 * Fixtures are synthetic and deterministic (testbed/aec-fixtures.mjs): delays
 * 5/15/30/60 ms, echo levels −6/−12/−20 dB relative to the reference, two-tap
 * and reverb-tail paths, double-talk stretches, and silence. The last section
 * is the load-bearing one for Lane 0: the POST-AEC signal is fed through the
 * shipping OnsetDetector and TurnEndPredictor — an echo-induced local onset
 * is a video stall bug (tape.yieldLaneB(40,'onset') hangs off onset honesty).
 *
 * Run: node core/aec.test.mjs
 */

import { Aec } from './aec.js';
import { OnsetDetector } from './onset.js';
import { TurnEndPredictor } from './turnend.js';
import {
  SR, ms, reseed, silence, roomTone, speech, breath, voiced, utterance,
  singleTapIR, twoTapIR, reverbIR, applyEcho, driveAec, Tracker,
  erleSeries, meanErle, timeToErle,
} from '../testbed/aec-fixtures.mjs';

// ── Harness ──────────────────────────────────────────────────────────────────
let pass = 0;
let fail = 0;
const report = []; // gate numbers, collected for the summary at the end

function check(name, cond, detail = '') {
  if (cond) {
    pass++;
    console.log(`  ok    ${name}${detail ? `  — ${detail}` : ''}`);
  } else {
    fail++;
    console.log(`  FAIL  ${name}${detail ? `  — ${detail}` : ''}`);
  }
}
function rec(key, value) {
  report.push(`${key}: ${value}`);
}

const CONV_BAR_MS = 1500; // design bar (task gate: 2000)
const ERLE_BAR_DB = 20;

console.log('\naec v2 kernel — synthetic echo fixtures\n');

// ── 1. Convergence matrix: delay × level, single-tap path ───────────────────
console.log('1. convergence matrix (single-tap echo path)');
for (const delayMs of [5, 15, 30, 60]) {
  for (const echoDb of [-6, -12, -20]) {
    reseed();
    const ref = speech(3000);
    const mic = applyEcho(ref, singleTapIR(delayMs), echoDb);
    const aec = new Aec();
    const out = driveAec(aec, ref, mic, { delaySamples: ms(delayMs) });
    const series = erleSeries(mic, out);
    const conv = timeToErle(series, ERLE_BAR_DB);
    const steady = meanErle(series, 2000, 3000);
    rec(`conv ${delayMs}ms/${echoDb}dB`, `conv ${conv?.toFixed(0) ?? 'never'} ms, steady ${steady?.toFixed(1)} dB`);
    check(
      `${delayMs} ms / ${echoDb} dB: ERLE ≥ ${ERLE_BAR_DB} dB by ${CONV_BAR_MS} ms and steady-state`,
      conv !== null && conv <= CONV_BAR_MS && steady >= ERLE_BAR_DB,
      `conv ${conv?.toFixed(0) ?? '—'} ms, steady ${steady?.toFixed(1)} dB`,
    );
  }
}

// ── 2. Echo-path models: two-tap and reverb tail ─────────────────────────────
// The reverb tail gets the task's 2000 ms convergence gate, not the design's
// 1500 ms matrix bar: the direct tap cancels in ~400 ms, but the stochastic
// tail (~3600 taps inside the filter) is excitation-limited — speech excites
// a few bins per syllable and the tail taps only average out over many
// syllables. Measured steady-state 22–26 dB for ANY tail length 60–90 ms:
// that is the honest speech-driven limit, 3–6 dB over the 20 dB gate.
console.log('\n2. structured echo paths (15 ms / −12 dB)');
for (const [name, h, convBar] of [['two-tap', twoTapIR(15), CONV_BAR_MS], ['reverb RT60≈150ms', reverbIR(15), 2000]]) {
  reseed();
  const ref = speech(3000);
  const mic = applyEcho(ref, h, -12);
  const aec = new Aec();
  const out = driveAec(aec, ref, mic, { delaySamples: ms(15) });
  const series = erleSeries(mic, out);
  const conv = timeToErle(series, ERLE_BAR_DB);
  const steady = meanErle(series, 2000, 3000);
  rec(`path ${name}`, `conv ${conv?.toFixed(0) ?? 'never'} ms, steady ${steady?.toFixed(1)} dB`);
  check(
    `${name}: ERLE ≥ ${ERLE_BAR_DB} dB by ${convBar} ms and steady-state`,
    conv !== null && conv <= convBar && steady >= ERLE_BAR_DB,
    `conv ${conv?.toFixed(0) ?? '—'} ms, steady ${steady?.toFixed(1)} dB`,
  );
}

// ── 3. Re-convergence: echo path steps mid-stream ────────────────────────────
console.log('\n3. re-convergence after a mid-stream path step (bar: ≥15 dB within 400 ms)');
{
  // Gain ×0.5, hint fixed: pure adaptation test.
  reseed();
  const ref = speech(5000);
  const g = Math.pow(10, -12 / 20);
  const D = ms(15);
  const mic = new Float32Array(ref.length);
  for (let i = 0; i < ref.length; i++) {
    const gg = i < SR * 3 ? g : g * 0.5;
    mic[i] = i >= D ? gg * ref[i - D] : 0;
  }
  const aec = new Aec();
  const out = driveAec(aec, ref, mic, { delaySamples: D });
  const post = erleSeries(mic.subarray(SR * 3), out.subarray(SR * 3));
  const recMs = timeToErle(post, 15);
  rec('reconv gain×0.5', `${recMs?.toFixed(0) ?? 'never'} ms`);
  check('gain ×0.5 (hint fixed): ≥15 dB within 400 ms', recMs !== null && recMs <= 400, `${recMs?.toFixed(0) ?? '—'} ms`);
}
{
  // Delay +8 ms, tracker in the loop: the design's tracker+adaptation test.
  reseed();
  const ref = speech(8000);
  const g = Math.pow(10, -12 / 20);
  const D = ms(15);
  const D2 = D + ms(8);
  const mic = new Float32Array(ref.length);
  for (let i = 0; i < ref.length; i++) {
    const d = i < SR * 3 ? D : D2;
    mic[i] = i >= d ? g * ref[i - d] : 0;
  }
  const aec = new Aec();
  const tracker = new Tracker(aec);
  tracker.hint = D; // calibrated pre-step
  tracker.locked = true; // narrow tracking; bootstrap covered in §7
  const out = driveAec(aec, ref, mic, { tracker });
  const post = erleSeries(mic.subarray(SR * 3), out.subarray(SR * 3));
  const recMs = timeToErle(post, 15);
  const steady = meanErle(post, 1000, 2000);
  const moveMs = tracker.moves.length ? (tracker.moves[0].block * 128) / 48 - 3000 : null;
  rec('reconv delay+8ms', `recovered ${recMs?.toFixed(0) ?? 'never'} ms, tracker moved at ${moveMs?.toFixed(0) ?? '—'} ms to ${tracker.moves[0]?.to ?? '—'} (true ${D2}), steady ${steady?.toFixed(1)} dB`);
  check('delay +8 ms (tracker in loop): ≥15 dB within 400 ms', recMs !== null && recMs <= 400, `${recMs?.toFixed(0) ?? '—'} ms (tracker move at ${moveMs?.toFixed(0) ?? '—'} ms, steady ${steady?.toFixed(1)} dB)`);
}

// ── 4. Double-talk honesty ───────────────────────────────────────────────────
// The linearity bar: near-end in the output attenuated by ≤1 dB (no ducking,
// ever — tell 8), and adaptation must not diverge (ERLE after the overlap
// within 3 dB of before). Honest residual per design §5.2: the residual echo
// RISES during the overlap (filter frozen while the room may change) — that
// is the stated price of never ducking, and it is reported, not gated.
console.log('\n4. double-talk (near-end speech t=3–5 s over continuing echo)');
for (const echoDb of [-6, -12, -20]) {
  reseed();
  const ref = speech(6000);
  const near = new Float32Array(ref.length);
  near.set(speech(2000), SR * 3);
  const mic = applyEcho(ref, singleTapIR(15), echoDb, near);
  const aec = new Aec();
  let dtBlocks = 0;
  let nearBlocks = 0;
  const out = driveAec(aec, ref, mic, {
    delaySamples: ms(15),
    onBlock: (a, b) => {
      const t = (b * 128) / SR;
      if (t >= 3 && t < 5) {
        nearBlocks++;
        if (a.dtFlag) dtBlocks++;
      }
    },
  });
  let pn = 0;
  let po = 0;
  for (let i = SR * 3 + ms(50); i < SR * 5 - ms(50); i++) {
    pn += near[i] * near[i];
    po += out[i] * out[i];
  }
  const dmg = 10 * Math.log10(po / pn);
  const series = erleSeries(mic, out);
  const pre = meanErle(series, 2000, 2950);
  const post = meanErle(series, 5050, 5950);
  rec(`double-talk ${echoDb}dB`, `damage ${dmg.toFixed(2)} dB, ERLE ${pre.toFixed(1)} → ${post.toFixed(1)} dB, dtFrac in overlap ${(dtBlocks / nearBlocks).toFixed(2)}`);
  check(
    `${echoDb} dB: near-end damage ≤ 1 dB`,
    Math.abs(dmg) <= 1,
    `${dmg.toFixed(2)} dB (DTD held ${(100 * dtBlocks / nearBlocks).toFixed(0)}% of the overlap)`,
  );
  check(
    `${echoDb} dB: no divergence (post-ERLE within 3 dB of pre)`,
    post >= pre - 3,
    `${pre.toFixed(1)} → ${post.toFixed(1)} dB`,
  );
}

// ── 5. Silence discipline ────────────────────────────────────────────────────
console.log('\n5. silence discipline');
{
  reseed();
  const aec = new Aec();
  const ref = silence(500);
  const mic = roomTone(500);
  const out = driveAec(aec, ref, mic, { delaySamples: 0 });
  // driveAec processes full 128-sample blocks; the sub-block tail of `out`
  // is untouched zeros, so compare only the processed region.
  const nProc = mic.length - (mic.length % 128);
  let exact = true;
  for (let i = 0; i < nProc; i++) if (out[i] !== mic[i]) exact = false;
  check('reference silent from cold start: output === mic, bit-exact', exact);
}
{
  reseed();
  const ref = speech(4000);
  const mic = applyEcho(ref, singleTapIR(15), -12);
  for (let i = SR * 3; i < mic.length; i++) mic[i] = 0; // mic dies at t=3 s
  const aec = new Aec();
  const out = driveAec(aec, ref, mic, { delaySamples: ms(15) });
  let r = 0;
  let n = 0;
  for (let i = SR * 3 + ms(100); i < out.length; i++) {
    r += out[i] * out[i];
    n++;
  }
  const resDb = 10 * Math.log10(r / n);
  rec('mic-silent residual', `${resDb.toFixed(1)} dBFS`);
  check('mic silent after convergence: residual ≤ −40 dBFS', resDb <= -40, `${resDb.toFixed(1)} dBFS`);
}

// ── 6. Alignment scan: recover a planted D ───────────────────────────────────
// The tracker bootstrap mechanism (design §2.2): correlation accumulates over
// 1 s of far-end single-talk with room tone in the mic. Bar: ±8 samples.
console.log('\n6. alignment scan (bar: planted D recovered to ±8 samples)');
for (const delayMs of [5, 15, 30, 60]) {
  for (const echoDb of [-6, -12, -20]) {
    reseed();
    const ref = speech(1000);
    const mic = applyEcho(ref, singleTapIR(delayMs), echoDb, roomTone(1000));
    const aec = new Aec();
    const blk = new Float32Array(128);
    let s = null;
    for (let i = 0; i + 128 <= mic.length; i += 128) {
      aec.pushReference(ref.subarray(i, i + 128));
      aec.process(mic.subarray(i, i + 128), blk, { delaySamples: 0 });
      s = aec.alignmentScan(mic.subarray(i, i + 128), { center: ms(delayMs), halfWidth: 480 });
    }
    const err = s.lag - ms(delayMs);
    rec(`scan ${delayMs}ms/${echoDb}dB`, `err ${err} samples, score ${s.score.toFixed(2)}`);
    check(`${delayMs} ms / ${echoDb} dB: |err| ≤ 8 samples`, Math.abs(err) <= 8, `err ${err}, score ${s.score.toFixed(2)}`);
  }
}

// ── 7. Bootstrap: no calibration, tracker finds D from speech alone ──────────
// This fixture is about ONLINE DELAY ACQUISITION, so it carries no near-end
// noise: with −63 dBFS room tone the μ=1 misadjustment floor caps steady ERLE
// at ≈19 dB for ANY delay (measured; pure echo reaches 40–80 dB) — that floor
// is a separate axis, reported in the results note, and would make a 20 dB
// bar here unpassable no matter how well the tracker locks.
console.log('\n7. online bootstrap (no calibration; hint starts at 0, true D = 30 ms)');
{
  reseed();
  const ref = speech(4000);
  const mic = applyEcho(ref, singleTapIR(30), -12);
  const aec = new Aec();
  const tracker = new Tracker(aec);
  const out = driveAec(aec, ref, mic, { tracker });
  const series = erleSeries(mic, out);
  const conv = timeToErle(series, ERLE_BAR_DB);
  const steady = meanErle(series, 3000, 4000);
  const lockErr = tracker.moves.length ? tracker.moves[tracker.moves.length - 1].to - ms(30) : null;
  rec('bootstrap', `locked at ${tracker.moves[0]?.to ?? '—'} (err ${lockErr}), conv ${conv?.toFixed(0) ?? 'never'} ms, steady ${steady?.toFixed(1)} dB, moves ${tracker.moves.length}`);
  check('tracker locks onto D (±8 samples)', lockErr !== null && Math.abs(lockErr) <= 8, `err ${lockErr ?? '—'}`);
  check('converged ≥20 dB within 2000 ms of cold start', conv !== null && conv <= 2000, `${conv?.toFixed(0) ?? '—'} ms`);
}

// ── 8. Onset honesty through the canceller (the Lane 0 gate) ─────────────────
// The Lane 0 video preemption — tape.yieldLaneB(40,'onset') — hangs off the
// local detector. If loudspeaker echo reaches it as a local onset, every
// far-end utterance yields Lane B and stalls video. Bars: ZERO echo-induced
// local onsets and predicts after convergence, and a genuine near-end onset
// survives with its head start intact.
console.log('\n8. onset honesty (post-AEC signal through the shipping detectors)');
{
  // 8a/8b: far-end speech echoed into a quiet room — no near-end talker.
  reseed();
  const ref = speech(6000);
  const mic = applyEcho(ref, singleTapIR(15), -12, roomTone(6000));
  const aec = new Aec();
  const out = driveAec(aec, ref, mic, { delaySamples: ms(15) });
  const det = new OnsetDetector();
  const pred = new TurnEndPredictor();
  let preOnsets = 0;
  let postOnsets = 0;
  let postPredicts = 0;
  for (let i = 0; i + 128 <= out.length; i += 128) {
    for (const e of det.push(out.subarray(i, i + 128))) {
      if (e.type === 'onset') {
        if (e.at / SR > 2) postOnsets++;
        else preOnsets++;
      }
    }
    for (const e of pred.push(out.subarray(i, i + 128))) {
      if (e.type === 'predict' && e.at / SR > 2) postPredicts++;
    }
  }
  rec('onset-honesty echo-only', `pre-convergence onsets ${preOnsets} (accepted: app suppresses yields while !adapted), post-convergence onsets ${postOnsets}, predicts ${postPredicts}`);
  check('echo-only: ZERO local onsets after convergence', postOnsets === 0, `${postOnsets} (pre-convergence: ${preOnsets})`);
  check('echo-only: ZERO turn-end predicts after convergence', postPredicts === 0, `${postPredicts}`);
}
{
  // 8c/8d: a genuine near-end onset over continuing echo, vs a no-echo
  // control. Onset must land within ±10 ms (one hop) and the breath's head
  // start must survive.
  reseed();
  const ref = speech(6000);
  const nearLead = ms(4000);
  const near = new Float32Array(ref.length);
  near.set(roomTone(6000), 0);
  near.set(breath(280), nearLead);
  const v = voiced(400);
  near.set(v, nearLead + ms(280));
  const mic = applyEcho(ref, singleTapIR(15), -12, near);
  const aec = new Aec();
  const out = driveAec(aec, ref, mic, { delaySamples: ms(15) });

  const runDet = (sig) => {
    const d = new OnsetDetector();
    const ev = [];
    for (let i = 0; i + 128 <= sig.length; i += 128) ev.push(...d.push(sig.subarray(i, i + 128)));
    return ev;
  };
  const evAec = runDet(out);
  const evCtl = runDet(near);
  const onA = evAec.find((e) => e.type === 'onset' && e.at / SR > 3.5);
  const onC = evCtl.find((e) => e.type === 'onset' && e.at / SR > 3.5);
  const voA = evAec.find((e) => e.type === 'voiced' && e.at / SR > 3.5);
  const voC = evCtl.find((e) => e.type === 'voiced' && e.at / SR > 3.5);
  check('near-end onset survives the canceller', !!onA, onA ? `at ${(onA.at / SR * 1000).toFixed(0)} ms` : 'MISSED');
  if (onA && onC) {
    const dt = (onA.at - onC.at) / (SR / 1000);
    rec('onset timing vs control', `${dt.toFixed(1)} ms (lead ${voA?.leadMs?.toFixed(0) ?? '—'} ms vs control ${voC?.leadMs?.toFixed(0) ?? '—'} ms)`);
    check('onset timing within ±10 ms of no-echo control', Math.abs(dt) <= 10, `${dt.toFixed(1)} ms`);
  } else {
    check('onset timing within ±10 ms of no-echo control', false, `control ${onC ? 'fired' : 'MISSED'}, aec ${onA ? 'fired' : 'MISSED'}`);
  }
  check(
    'breath head start intact (leadMs within ±10%)',
    !!(voA && voC) && Math.abs(voA.leadMs - voC.leadMs) <= 0.1 * voC.leadMs,
    voA && voC ? `${voA.leadMs.toFixed(0)} ms vs ${voC.leadMs.toFixed(0)} ms` : `voiced aec=${!!voA} ctl=${!!voC}`,
  );
}
{
  // 8e/8f: turn-end predictor transparency on a near-end utterance. The
  // shipped model does not fire on synthetic falls (max prob ≈ 0.59 < 0.65,
  // measured), so the bar is on the score STREAM: gated frames must score
  // within 0.1 of the no-echo control, and predict counts must match.
  reseed();
  const ref = speech(6500);
  const near = new Float32Array(ref.length);
  near.set(roomTone(6500), 0);
  near.set(utterance(4000), ms(1500));
  const mic = applyEcho(ref, singleTapIR(15), -12, near);
  const aec = new Aec();
  const out = driveAec(aec, ref, mic, { delaySamples: ms(15) });

  const runPred = (sig) => {
    const p = new TurnEndPredictor({ debug: true });
    const scores = new Map();
    let predicts = 0;
    for (let i = 0; i + 128 <= sig.length; i += 128) {
      for (const e of p.push(sig.subarray(i, i + 128))) {
        if (e.type === 'score') scores.set(e.at, e.prob);
        if (e.type === 'predict') predicts++;
      }
    }
    return { scores, predicts };
  };
  const A = runPred(out);
  const B = runPred(near);
  let maxD = 0;
  let n = 0;
  for (const [at, p] of B.scores) {
    if (A.scores.has(at)) {
      maxD = Math.max(maxD, Math.abs(A.scores.get(at) - p));
      n++;
    }
  }
  const maxProb = (m) => Math.max(0, ...m.values());
  rec('turnend transparency', `${n} scored frames in common, max |Δprob| ${maxD.toFixed(3)}, max prob ${maxProb(A.scores).toFixed(2)}/${maxProb(B.scores).toFixed(2)}, predicts ${A.predicts}/${B.predicts}`);
  check('turn-end score stream transparent (max |Δprob| ≤ 0.1)', n > 0 && maxD <= 0.1, `${n} frames, max Δ ${maxD.toFixed(3)}`);
  check('turn-end predict count unchanged', A.predicts === B.predicts, `${A.predicts} vs ${B.predicts} (model does not fire on synthetic falls — see header)`);
}

// ── Summary ──────────────────────────────────────────────────────────────────
console.log('\n── gate numbers ──');
for (const r of report) console.log(`  · ${r}`);
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
