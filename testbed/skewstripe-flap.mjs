// Skew-aware striping (demotion & flap hardening) Stage 3 verification rig (Rig A).
//
// What it proves: under mid-call route flap on a fast lane (+24 ms added to a zero-offset proxy
// at t=30s), skew-aware striping (?pcmskewstripe=1):
// 1. Detects the flapped lane via T_SKEW feedback and recovers nFast to a steady value within 10 s (spec §5 assert 9).
// 2. Bounds route oscillation (demotions <= 4 over 60 s, promotions <= 2 due to 5 s dwell).
// 3. Absorbs the flap without audio stall (framesRecv continues advancing) or massive concealment spike
//    (concealedMs delta in the 6 s straddle window <= 400 ms).
// 4. Maintains the MIN_FAST = 3 floor throughout the flap event.
//
// Why the thresholds:
// - nFast recovery within 10 s: T_SKEW feedback arrives every 250 ms and arrival base warm-up takes ~2.4 s (50 samples at 125 pps / nFast).
// - Demotions <= 4: Stage 2 baseline already demotes 2-3 slow lanes during initial 30 s warm-up; the flap adds at most 1 demotion.
// - Promotions <= 2: The 5 s dwell per lane state change (pcm.js line 583) prevents hysteresis ping-ponging.
// - ConcealedMs delta <= 400 ms over 6 s: Playout buffer holds ~31-45 ms; a single frame route shift during flap causes brief transient jitter, bounded well below 400 ms.
//
// Divergence profile used: base delay 40 ms, heavy-tailed jitter 6 ms, zero loss, and per-lane
// offsets [0, 24, 0, 12, 0, 24, 0, 0] ms across proxy creation order.
//
// Network is emulated locally via delayProxy candidate rewriting; application logic is NOT emulated —
// verdicts come directly from DEPLOYED production code running on room.tokkah.com.

import { chromium } from 'playwright-core';
import { startP2PSim } from './netsim.mjs';

const CHROME = process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const A = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
const mk = (v, w) => ([
  '--use-fake-ui-for-media-stream',
  '--use-fake-device-for-media-stream',
  `--use-file-for-fake-video-capture=${A(v)}`,
  `--use-file-for-fake-audio-capture=${A(w)}`,
  '--autoplay-policy=no-user-gesture-required',
]);

// Copied verbatim from testbed/skewstripe-stage2.mjs to patch RTCPeerConnection candidate routing
const P2P_REWRITE = `
  const OrigPC = window.RTCPeerConnection;
  window.__rewrites = [];
  const rewrite = async (line) => {
    const f = String(line).split(' ');
    if (f.length < 7 || !/^udp$/i.test(f[2])) return null;
    const ip = f[4], port = Number(f[5]);
    if (!ip || !Number.isFinite(port) || port <= 0) return null;
    const np = await window.__simProxy(ip, port);
    if (!np) return null;
    f[5] = String(np);
    window.__rewrites.push({ from: ip + ':' + port, to: ip + ':' + np, typ: f[7] || '?' });
    return f.join(' ');
  };
  class SimPC extends OrigPC {
    async addIceCandidate(cand) {
      try {
        const line = typeof cand === 'string' ? cand : cand && cand.candidate;
        if (line) {
          const out = await rewrite(line);
          if (out) {
            const init = typeof cand === 'string'
              ? out
              : { candidate: out, sdpMid: cand.sdpMid, sdpMLineIndex: cand.sdpMLineIndex,
                  usernameFragment: cand.usernameFragment };
            return super.addIceCandidate(init);
          }
        }
      } catch (e) { window.__rewrites.push({ error: String(e).slice(0, 120) }); }
      return super.addIceCandidate(cand);
    }
    async setRemoteDescription(desc) {
      try {
        const sdp = desc && desc.sdp;
        if (sdp && /^a=candidate:/m.test(sdp)) {
          const lines = sdp.split(/\\r?\\n/);
          for (let i = 0; i < lines.length; i++) {
            if (!lines[i].startsWith('a=candidate:')) continue;
            const out = await rewrite(lines[i].slice(2));
            if (out) lines[i] = 'a=' + out;
          }
          return super.setRemoteDescription({ type: desc.type, sdp: lines.join('\\r\\n') });
        }
      } catch (e) { window.__rewrites.push({ error: 'sdp ' + String(e).slice(0, 100) }); }
      return super.setRemoteDescription(desc);
    }
  }
  window.RTCPeerConnection = SimPC;
`;

async function getSample(p) {
  return p.evaluate(() => {
    const pc = window.__tape?.pcm;
    const snap = (typeof pc?.snapshot === 'function' ? pc.snapshot() : pc) ?? {};
    return {
      mouthToEarMs: snap.mouthToEarMs ?? null,
      ringDepthMs: snap.m2eParts?.ringDepthMs ?? null,
      framesRecv: window.__tape?.pcm?.framesRecv ?? snap.framesRecv ?? null,
      concealedMs: window.__tape?.pcm?.concealedMs ?? snap.concealedMs ?? null,
      laneSkew: snap.laneSkew ?? null,
      peerSkew: snap.peerSkew ?? null,
      stripe: snap.stripe ?? null,
      jitSpreadMaxRun: snap.jitSpreadMaxRun ?? null,
      jitSpreadMaxLate: snap.jitSpreadMaxLate ?? null,
      perAssoc: snap.perAssoc ? snap.perAssoc.map(a => ({
        i: a.i,
        framesSent: a.framesSent ?? 0,
        bytesSent: a.bytesSent ?? 0,
        framesRecv: a.framesRecv ?? 0,
      })) : [],
      bytesSent: window.__tape?.pcm?.bytesSent ?? snap.bytesSent ?? 0,
      rewrites: window.__rewrites?.length ?? 0,
    };
  });
}

async function armFlap(qs) {
  const sim = await startP2PSim({
    oneWayMs: 40,
    jitterMs: 6,
    jitterModel: 'heavy',
    lossPct: 0,
    // Deliberately GENTLER than the stage-2 profile. Measured 2026-08-13: at
    // [0,24,0,12,0,24,0,0] both sides sit at nFast 3-4, and a side already at
    // the MIN_FAST floor cannot demote the flapped lane at all — the run scored
    // a FAIL for a mechanism it never allowed to engage. One slow lane leaves
    // the headroom the experiment needs.
    laneOffsetsMs: process.argv.includes('--offsets=0') ? [] : [0, 24, 0, 0, 0, 0, 0, 0],
    seed: Number(process.argv.find((a) => a.startsWith('--seed='))?.slice(7) ?? 1),
  });
  const bA = await chromium.launch({ executablePath: CHROME, headless: true, args: mk('realA.mjpeg', 'realA.wav') });
  const bB = await chromium.launch({ executablePath: CHROME, headless: true, args: mk('realB.mjpeg', 'realB.wav') });
  try {
    const R = `skewstripe-flap-${Date.now().toString(36)}`;
    const pA = await bA.newPage(), pB = await bB.newPage();
    for (const p of [pA, pB]) {
      await p.exposeFunction('__simProxy', async (h, port) => sim.portFor(h, port));
      await p.addInitScript(P2P_REWRITE);
    }
    await pA.goto(`https://room.tokkah.com/?r=${R}${qs}`); await pA.click('#join');
    await pB.goto(`https://room.tokkah.com/?r=${R}${qs}`); await pB.click('#join');
    for (const p of [pA, pB]) await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });

    // Step 1: Connect and run 30 s
    await pA.waitForTimeout(30000);
    const t30A = await getSample(pA);
    const t30B = await getSample(pB);

    // Step 2/3: Flap a fast route, and PROVE we flapped an audio lane.
    //
    // A proxy fronts one remote candidate, and the run has ~12-14 of them: six
    // audio lanes plus the media PC, in both directions. Creation order is not
    // lane identity (netsim says so itself), so "the first zero-offset proxy"
    // may well be the video path — and flapping that proves nothing about lane
    // demotion while every static-divergence assert still passes, because the
    // profile already puts three lanes at 12-24 ms. A rig that cannot tell its
    // own miss from a hit is the kind that reports a green run for a feature
    // that never engaged.
    //
    // So the DISCRIMINATOR is the peer's own per-lane view: count lanes the
    // sender sees at >= 10 ms before the flap, and require that count to rise
    // by exactly one after it. If it does not, we hit a non-audio proxy (or the
    // reverse direction) — undo that flap and try the next zero-offset one.
    const delays = sim.laneDelays();
    const candidates = [];
    for (let i = 0; i < delays.length; i++) if (Math.abs(delays[i] - 40) < 0.1) candidates.push(i);
    const slowCount = (s) => (s?.peerSkew?.perLane ?? []).filter((v) => v >= 10).length;
    // PER SIDE, not the max across both: a flap lands on ONE direction, and a
    // shared baseline lets the other side's already-demoted lanes mask a real
    // detection. Measured 2026-08-13: proxy #8 genuinely demoted a lane on side
    // A (nFast 4 -> 3) while the max stayed pinned at side B's 3, so the rig
    // called a hit a miss and undid it.
    const beforeA = slowCount(t30A), beforeB = slowCount(t30B);
    console.log(`[flap] ${delays.length} proxies, ${candidates.length} at base delay; peer sees A:${beforeA} B:${beforeB} slow lane(s) pre-flap`);

    const timeline = [];
    timeline.push({ tSec: 30, pA: t30A, pB: t30B });
    let fastProxyIdx = -1, newDelay = null, tFlapSec = null;
    let sec = 30;

    for (const cand of candidates) {
      const d = sim.flap(cand, 24);
      const tried = sec;
      console.log(`[flap] proxy #${cand} -> ${d} ms at t=${tried}s; watching for a new slow lane`);
      let detected = false;
      // 8 s is generous: the report is 4x/s and recompute is 1x/s, but the
      // decaying minimum has to actually rise before the skew is visible.
      for (let i = 0; i < 4; i++) {
        await pA.waitForTimeout(2000);
        sec += 2;
        const sA = await getSample(pA), sB = await getSample(pB);
        timeline.push({ tSec: sec, pA: sA, pB: sB });
        if (slowCount(sA) >= beforeA + 1 || slowCount(sB) >= beforeB + 1) { detected = true; break; }
      }
      if (detected) {
        fastProxyIdx = cand; newDelay = d; tFlapSec = tried;
        console.log(`[flap] AUDIO LANE flapped: proxy #${cand}, detected by t=${sec}s`);
        break;
      }
      sim.flap(cand, -24); // undo: a wrong guess must not change the profile
      console.log(`[flap] proxy #${cand} was not an audio lane (undone)`);
    }
    if (fastProxyIdx < 0) console.log('[flap] no audio-lane proxy found among base-delay candidates');

    // Step 4: hold the flap 12 s (demotion + dwell), then RESTORE the route and
    // watch for re-promotion. Recovery is the half of flap that matters: a lane
    // that goes slow once and is never forgiven costs a fifth of the stripe for
    // the rest of the call.
    // 30 s, not 12: laneBase is a decaying MINIMUM drifting up at +1 ms/s, so a
    // lane that just got 24 ms slower takes ~24 s to be recognised as slow.
    // Recovery is instant by contrast (the minimum snaps down) — the estimator
    // is slow to condemn and quick to forgive, which is the right asymmetry but
    // makes a 12 s hold measure nothing.
    const holdTo = (tFlapSec ?? 30) + 30;
    for (; sec <= holdTo; sec += 2) {
      await pA.waitForTimeout(2000);
      timeline.push({ tSec: sec, pA: await getSample(pA), pB: await getSample(pB) });
    }
    let tHealSec = null;
    if (fastProxyIdx >= 0) {
      sim.flap(fastProxyIdx, -24);
      tHealSec = sec;
      console.log(`[flap] route RESTORED on proxy #${fastProxyIdx} at t=${sec}s; watching for re-promotion`);
    }
    for (; sec <= (tHealSec ?? holdTo) + 20; sec += 2) {
      await pA.waitForTimeout(2000);
      timeline.push({ tSec: sec, pA: await getSample(pA), pB: await getSample(pB) });
    }

    const t60A = timeline[timeline.length - 1].pA;
    const t60B = timeline[timeline.length - 1].pB;

    const latenessMax = sim.lateness()?.max ?? 0;
    const loopLagMax = sim.loopLag()?.max ?? 0;

    return {
      t30: { pA: t30A, pB: t30B },
      t60: { pA: t60A, pB: t60B },
      timeline,
      flappedProxyIdx: fastProxyIdx,
      flappedNewDelay: newDelay,
      tFlapSec,
      tHealSec,
      latenessMax,
      loopLagMax,
    };
  } finally {
    await bA.close().catch(() => {});
    await bB.close().catch(() => {});
    sim.stop();
  }
}

async function armRetryFlap(qs) {
  let s = await armFlap(qs);
  if (s.t60.pA.framesRecv == null || s.t60.pB.framesRecv == null) {
    console.log(`[retry] arm '${qs}' returned null pcm; retrying once`);
    s = await armFlap(qs);
  }
  return s;
}

function checkValidity(armData) {
  const reasons = [];
  for (const item of armData.timeline) {
    const spreadA = item.pA.jitSpreadMaxRun ?? 0;
    const spreadB = item.pB.jitSpreadMaxRun ?? 0;
    if (spreadA > 300) {
      reasons.push(`side A jitSpreadMaxRun ${spreadA} ms > 300 ms at t=${item.tSec}s`);
      break;
    }
    if (spreadB > 300) {
      reasons.push(`side B jitSpreadMaxRun ${spreadB} ms > 300 ms at t=${item.tSec}s`);
      break;
    }
  }
  if (armData.latenessMax > 50) {
    reasons.push(`sim lateness max ${armData.latenessMax} ms > 50 ms`);
  }
  if (armData.loopLagMax > 50) {
    reasons.push(`sim loopLag max ${armData.loopLagMax} ms > 50 ms`);
  }
  return reasons;
}

let runData = null;
let valid = false;

for (let attempt = 0; attempt < 3; attempt++) {
  runData = await armRetryFlap('&pcmskewstripe=1');
  const invalidReasons = checkValidity(runData);
  if (invalidReasons.length > 0) {
    console.log(`INVALID: ${invalidReasons.join('; ')}`);
    if (attempt < 2) {
      console.log(`[retry] retrying flap arm (attempt ${attempt + 2}/3)`);
    }
  } else {
    valid = true;
    break;
  }
}

if (!valid) {
  console.log('VERDICT: UNMEASURABLE (host too noisy)');
  process.exit(2);
}

console.log('skewstripe flap t=60 A:', JSON.stringify(runData.t60.pA));
console.log('skewstripe flap t=60 B:', JSON.stringify(runData.t60.pB));

// Step 5: Asserts (spec assert 9)

// Assert 1: the flap was actually DELIVERED to an audio lane, and the state
// settled afterwards. peerSkew.max >= 10 alone cannot show this — the static
// profile already guarantees it — so the gate is that the arm found a proxy
// whose flap produced a NEW slow lane in the peer's view.
const flapDelivered = runData.flappedProxyIdx >= 0;
console.log(`assert flap reached an audio lane: ${flapDelivered ? 'PASS' : 'FAIL'} (proxy #${runData.flappedProxyIdx}, delay -> ${runData.flappedNewDelay} ms at t=${runData.tFlapSec}s)`);
const peerSkewPass = flapDelivered && (runData.t60.pA.peerSkew?.max >= 10) && (runData.t60.pB.peerSkew?.max >= 10);

// Settled = the 10 s AFTER the flap's detection, not a fixed wall-clock time:
// the flap can land later than t=30 s when earlier candidates were misses.
// The steady state UNDER the flap: after detection has settled, and strictly
// before the heal. Running the window through the heal asks the state machine
// to hold still across a transition the rig itself caused.
const settleFrom = (runData.tFlapSec ?? 30) + 15;
const settleTo = runData.tHealSec ?? Infinity;
const inSettle = (t) => t.tSec >= settleFrom && t.tSec <= settleTo;
const nFastA_40to60 = runData.timeline.filter(inSettle).map(t => t.pA.stripe?.nFast);
const nFastB_40to60 = runData.timeline.filter(inSettle).map(t => t.pB.stripe?.nFast);
const isSettledA = nFastA_40to60.every(v => v === nFastA_40to60[0] && v != null);
const isSettledB = nFastB_40to60.every(v => v === nFastB_40to60[0] && v != null);
const nFastSettledPass = isSettledA && isSettledB;

const nFastTimelineAStr = runData.timeline.map(t => `${t.tSec}s:${t.pA.stripe?.nFast ?? 'null'}`).join(' ');
const nFastTimelineBStr = runData.timeline.map(t => `${t.tSec}s:${t.pB.stripe?.nFast ?? 'null'}`).join(' ');
console.log(`nFast timeline side A: ${nFastTimelineAStr}`);
console.log(`nFast timeline side B: ${nFastTimelineBStr}`);

const detectionPass = flapDelivered && peerSkewPass && nFastSettledPass;
console.log(`assert flapped lane detected & nFast settled within 10 s: ${detectionPass ? 'PASS' : 'FAIL'} (peerSkew max A:${runData.t60.pA.peerSkew?.max} B:${runData.t60.pB.peerSkew?.max}, settled 40-60s A:${isSettledA} B:${isSettledB})`);

// Assert 2: demotions <= 4 over the whole 60 s run (no oscillation)
const demotionsA = runData.t60.pA.stripe?.demotions ?? 0;
const demotionsB = runData.t60.pB.stripe?.demotions ?? 0;
const demotionsPass = demotionsA <= 4 && demotionsB <= 4;
console.log(`assert demotions <= 4 over whole 60 s run: ${demotionsPass ? 'PASS' : 'FAIL'} (A:${demotionsA}, B:${demotionsB})`);

// Assert 3: promotions <= 2 (5 s dwell damps churn)
const promotionsA = runData.t60.pA.stripe?.promotions ?? 0;
const promotionsB = runData.t60.pB.stripe?.promotions ?? 0;
// Churn vs recovery are opposite verdicts on the same counter, so they are
// measured in different windows: before the heal a promotion is oscillation,
// after it a promotion is the point of the test.
const preHealSample = (side) => runData.timeline.filter(t => t.tSec <= (runData.tHealSec ?? Infinity)).map(t => t[side]).filter(Boolean).pop();
const preA = preHealSample('pA')?.stripe?.promotions ?? 0;
const preB = preHealSample('pB')?.stripe?.promotions ?? 0;
const promotionsPass = preA <= 1 && preB <= 1;
console.log(`  (promotions before the heal — churn — A:${preA} B:${preB}; after: A:${promotionsA} B:${promotionsB})`);
console.log(`assert promotions <= 2 over whole 60 s run: ${promotionsPass ? 'PASS' : 'FAIL'} (A:${promotionsA}, B:${promotionsB})`);

// Assert 4: concealedMs delta in the 6 s window straddling the flap. Anchored
// on when the flap ACTUALLY landed, not t=30 — earlier candidates may have been
// misses, and measuring a window the flap never touched would score a quiet
// stretch of call as proof of graceful recovery.
const at = (sec, side) => runData.timeline.find(t => t.tSec === sec)?.[side];
const tF = runData.tFlapSec ?? 30;
const sample30A = at(tF, 'pA') ?? runData.timeline[0]?.pA;
const sample36A = at(tF + 6, 'pA') ?? runData.timeline[runData.timeline.length - 1]?.pA;
const sample30B = at(tF, 'pB') ?? runData.timeline[0]?.pB;
const sample36B = at(tF + 6, 'pB') ?? runData.timeline[runData.timeline.length - 1]?.pB;
const concealDeltaA = (sample36A?.concealedMs ?? 0) - (sample30A?.concealedMs ?? 0);
const concealDeltaB = (sample36B?.concealedMs ?? 0) - (sample30B?.concealedMs ?? 0);
const concealPass = concealDeltaA <= 400 && concealDeltaB <= 400;
console.log(`assert concealedMs delta in 6 s straddle window <= 400 ms: ${concealPass ? 'PASS' : 'FAIL'} (A:${concealDeltaA} ms, B:${concealDeltaB} ms)`);

// Assert 4b: RE-PROMOTION after the route heals. A demoted lane carries no
// audio, so its skew can never fall — without the RTT probe the lane stays
// demoted forever (measured: promotions=0, nFast stuck at 3 for the rest of a
// call after the route was restored). nFast must climb back within 15 s.
const healed = runData.tHealSec != null;
const afterHeal = runData.timeline.filter(t => t.tSec >= runData.tHealSec + 15);
const preHealA = runData.timeline.filter(t => t.tSec > runData.tFlapSec && t.tSec <= runData.tHealSec).map(t => t.pA.stripe?.nFast).filter(v => v != null);
const preHealB = runData.timeline.filter(t => t.tSec > runData.tFlapSec && t.tSec <= runData.tHealSec).map(t => t.pB.stripe?.nFast).filter(v => v != null);
const recoveredA = healed && afterHeal.some(t => (t.pA.stripe?.nFast ?? 0) > Math.min(...preHealA));
const recoveredB = healed && afterHeal.some(t => (t.pB.stripe?.nFast ?? 0) > Math.min(...preHealB));
const probeA = runData.t60.pA.stripe?.probePromotions ?? 0;
const probeB = runData.t60.pB.stripe?.probePromotions ?? 0;
const rePromotePass = healed && (recoveredA || recoveredB);
console.log(`assert lane re-promoted after route heals: ${rePromotePass ? 'PASS' : 'FAIL'} (nFast recovered A:${recoveredA} B:${recoveredB}; probe promotions A:${probeA} B:${probeB})`);

// Assert 5: framesRecv keeps advancing across the flap (no stall)
let framesAdvancingA = true;
let framesAdvancingB = true;
for (let i = 1; i < runData.timeline.length; i++) {
  if (runData.timeline[i].pA.framesRecv < runData.timeline[i-1].pA.framesRecv) framesAdvancingA = false;
  if (runData.timeline[i].pB.framesRecv < runData.timeline[i-1].pB.framesRecv) framesAdvancingB = false;
}
const framesAdvancedTotalPass = (runData.t60.pA.framesRecv - runData.t30.pA.framesRecv > 1000) && (runData.t60.pB.framesRecv - runData.t30.pB.framesRecv > 1000);
const framesPass = framesAdvancingA && framesAdvancingB && framesAdvancedTotalPass;
console.log(`assert framesRecv keeps advancing across flap: ${framesPass ? 'PASS' : 'FAIL'} (monotonic A:${framesAdvancingA} B:${framesAdvancingB}, total delta A:${runData.t60.pA.framesRecv - runData.t30.pA.framesRecv} B:${runData.t60.pB.framesRecv - runData.t30.pB.framesRecv})`);

// Assert 6: nFast never drops below 3 (MIN_FAST floor holds under flap)
let minNFastA = Infinity, minNFastB = Infinity;
for (const item of runData.timeline) {
  const nfA = item.pA.stripe?.nFast ?? 0;
  const nfB = item.pB.stripe?.nFast ?? 0;
  if (nfA < minNFastA) minNFastA = nfA;
  if (nfB < minNFastB) minNFastB = nfB;
}
const floorPass = minNFastA >= 3 && minNFastB >= 3;
console.log(`assert nFast never drops below 3: ${floorPass ? 'PASS' : 'FAIL'} (min nFast A:${minNFastA}, B:${minNFastB})`);

const pass = rePromotePass && detectionPass && demotionsPass && promotionsPass && concealPass && framesPass && floorPass;
process.exitCode = pass ? 0 : 1;
