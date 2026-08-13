// Skew-aware striping (demotion) Stage 2 verification rig.
//
// What it proves: under 16-32 ms per-lane route divergence across SCTP associations,
// skew-aware striping (?pcmskewstripe=1) demotes slow lanes, concentrating data traffic
// on fast lanes (nFast 3-5), reclaiming playout buffer depth (ringDepthMs <= OFF - 6)
// without increasing concealment (concealedMs <= OFF + 200) or inflating total bytes
// sent (within 2% of control).
//
// Divergence profile used: base delay 40 ms, heavy-tailed jitter 6 ms, zero loss, and per-lane
// offsets [0, 24, 0, 12, 0, 24, 0, 0] ms across creation order.
//
// Network is emulated locally via delayProxy candidate rewriting; application logic is NOT emulated —
// verdicts come directly from DEPLOYED production code running on room.tokkah.com.
//
// Why the 2026-08-13 assert rewrite:
// 1. Delta leakage vs cumulative share: The v1 assert "demoted lanes framesSent share <= 2%"
//    failed at 1.83%/2.83%. Timeline diagnostics proved demoted lanes' framesSent FREEZES
//    after demotion (side A lanes 0,4 stuck at 66/85 from t=10s through t=60s; side B
//    lanes 1,3,5 stuck at 63/65/71 from t=5s on). The residual was entirely the ~4-5 s
//    warm-up BEFORE demotion (50 samples to warm + T_SKEW report transit). Cumulative share
//    measured warm-up rather than post-demotion leakage. Sampling at t=30s and t=60s and
//    measuring the DELTA isolates post-demotion leakage (must be <= 0.5%).
// 2. Validity gating: A single 1.3 s host arrival hole (jitSpreadMaxRun 1329 ms vs normal ~50 ms)
//    contaminated ring-depth and conceal comparisons because pcm.js's peak-hold estimator
//    has ~90 s memory by design. One host stall inflates buffers for the rest of the call.
//    Clean runs measure real effect: ring 45-46 ms ON vs 64-75 ms OFF, m2e 114-115 vs 149-150 ms.
//    The rig gates validity (jitSpreadMaxRun > 300 ms, sim lateness > 50 ms, or loopLag > 50 ms)
//    and retries up to 2 times. If still invalid, it reports UNMEASURABLE (exit code 2),
//    refusing to report host noise as code failure.

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

// Copied verbatim from testbed/call.mjs to patch RTCPeerConnection candidate routing
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

async function arm(qs) {
  const sim = await startP2PSim({
    oneWayMs: 40,
    jitterMs: 6,
    jitterModel: 'heavy',
    lossPct: 0,
    laneOffsetsMs: process.argv.includes('--offsets=0') ? [] : [0, 24, 0, 12, 0, 24, 0, 0],
    seed: Number(process.argv.find((a) => a.startsWith('--seed='))?.slice(7) ?? 1),
  });
  const bA = await chromium.launch({ executablePath: CHROME, headless: true, args: mk('realA.mjpeg', 'realA.wav') });
  const bB = await chromium.launch({ executablePath: CHROME, headless: true, args: mk('realB.mjpeg', 'realB.wav') });
  try {
    const R = `skewstripe-div${qs ? 'on' : 'off'}-${Date.now().toString(36)}`;
    const pA = await bA.newPage(), pB = await bB.newPage();
    for (const p of [pA, pB]) {
      await p.exposeFunction('__simProxy', async (h, port) => sim.portFor(h, port));
      await p.addInitScript(P2P_REWRITE);
    }
    await pA.goto(`https://room.tokkah.com/?r=${R}${qs}`); await pA.click('#join');
    await pB.goto(`https://room.tokkah.com/?r=${R}${qs}`); await pB.click('#join');
    for (const p of [pA, pB]) await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });

    await pA.waitForTimeout(30000);
    const t30A = await getSample(pA);
    const t30B = await getSample(pB);

    await pA.waitForTimeout(30000);
    const t60A = await getSample(pA);
    const t60B = await getSample(pB);

    const latenessMax = sim.lateness()?.max ?? 0;
    const loopLagMax = sim.loopLag()?.max ?? 0;

    return {
      t30: { pA: t30A, pB: t30B },
      t60: { pA: t60A, pB: t60B },
      latenessMax,
      loopLagMax,
    };
  } finally {
    await bA.close().catch(() => {});
    await bB.close().catch(() => {});
    sim.stop();
  }
}

async function armRetry(qs) {
  let s = await arm(qs);
  if (s.t60.pA.framesRecv == null || s.t60.pB.framesRecv == null) {
    console.log(`[retry] arm '${qs || 'control'}' returned null pcm; retrying once`);
    s = await arm(qs);
  }
  return s;
}

function checkValidity(on, off) {
  const reasons = [];

  const checkArm = (label, armData) => {
    const spreadA30 = armData.t30.pA.jitSpreadMaxRun ?? 0;
    const spreadA60 = armData.t60.pA.jitSpreadMaxRun ?? 0;
    const spreadB30 = armData.t30.pB.jitSpreadMaxRun ?? 0;
    const spreadB60 = armData.t60.pB.jitSpreadMaxRun ?? 0;
    const maxSpreadA = Math.max(spreadA30, spreadA60);
    const maxSpreadB = Math.max(spreadB30, spreadB60);

    if (maxSpreadA > 300) {
      reasons.push(`${label} side A jitSpreadMaxRun ${maxSpreadA} ms > 300 ms`);
    }
    if (maxSpreadB > 300) {
      reasons.push(`${label} side B jitSpreadMaxRun ${maxSpreadB} ms > 300 ms`);
    }
    if (armData.latenessMax > 50) {
      reasons.push(`${label} sim lateness max ${armData.latenessMax} ms > 50 ms`);
    }
    if (armData.loopLagMax > 50) {
      reasons.push(`${label} sim loopLag max ${armData.loopLagMax} ms > 50 ms`);
    }
  };

  checkArm('ON', on);
  checkArm('OFF', off);
  return reasons;
}

function calcDeltaLeakage(s30, s60) {
  if (!s60?.stripe?.fastOrder || !s30?.perAssoc || !s60?.perAssoc) {
    return { pass: false, share: 1.0, pctStr: 'N/A', deltas: [], demotedLanes: [] };
  }
  const fastSet = new Set(s60.stripe.fastOrder);
  const map30 = new Map(s30.perAssoc.map(a => [a.i, a.framesSent ?? 0]));
  const map60 = new Map(s60.perAssoc.map(a => [a.i, a.framesSent ?? 0]));
  const allLanes = Array.from(new Set([...map30.keys(), ...map60.keys()])).sort((a, b) => a - b);

  const deltas = [];
  const demotedLanes = [];
  let totalDelta = 0;
  let demotedDelta = 0;

  for (const laneIdx of allLanes) {
    const s30Sent = map30.get(laneIdx) ?? 0;
    const s60Sent = map60.get(laneIdx) ?? 0;
    const d = Math.max(0, s60Sent - s30Sent);
    deltas.push(d);
    totalDelta += d;
    if (!fastSet.has(laneIdx)) {
      demotedLanes.push(laneIdx);
      demotedDelta += d;
    }
  }

  const share = totalDelta > 0 ? demotedDelta / totalDelta : 0;
  return {
    share,
    pctStr: (share * 100).toFixed(2) + '%',
    deltas,
    demotedLanes,
    totalDelta,
    demotedDelta,
  };
}

let on = null;
let off = null;
let valid = false;

for (let attempt = 0; attempt < 3; attempt++) {
  on = await armRetry('&pcmskewstripe=1');
  off = await armRetry('');

  const invalidReasons = checkValidity(on, off);
  if (invalidReasons.length > 0) {
    console.log(`INVALID: ${invalidReasons.join('; ')}`);
    if (attempt < 2) {
      console.log(`[retry] retrying two-arm comparison (attempt ${attempt + 2}/3)`);
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

console.log('skewstripe ON :', JSON.stringify(on.t60));
console.log('skewstripe OFF:', JSON.stringify(off.t60));

// Assert 1: rewrites > 0 both arms
const rewritesPass = (on.t60.pA.rewrites > 0) && (on.t60.pB.rewrites > 0) && (off.t60.pA.rewrites > 0) && (off.t60.pB.rewrites > 0);
console.log(`assert rewrites > 0 both arms: ${rewritesPass ? 'PASS' : 'FAIL'} (ON A:${on.t60.pA.rewrites} B:${on.t60.pB.rewrites}, OFF A:${off.t60.pA.rewrites} B:${off.t60.pB.rewrites})`);

// Assert 2: framesRecv > 1000 both arms both sides
const framesPass = (on.t60.pA.framesRecv > 1000) && (on.t60.pB.framesRecv > 1000) && (off.t60.pA.framesRecv > 1000) && (off.t60.pB.framesRecv > 1000);
console.log(`assert framesRecv > 1000 both arms: ${framesPass ? 'PASS' : 'FAIL'} (ON A:${on.t60.pA.framesRecv} B:${on.t60.pB.framesRecv}, OFF A:${off.t60.pA.framesRecv} B:${off.t60.pB.framesRecv})`);

// Assert 3: ON: stripe non-null both sides, nFast in [3,5], peerSkew.max >= 10
const stripeNonNullPass = (on.t60.pA.stripe != null) && (on.t60.pB.stripe != null);
console.log(`assert ON stripe non-null on both sides: ${stripeNonNullPass ? 'PASS' : 'FAIL'}`);

const nFastPass = (on.t60.pA.stripe?.nFast >= 3 && on.t60.pA.stripe?.nFast <= 5) && (on.t60.pB.stripe?.nFast >= 3 && on.t60.pB.stripe?.nFast <= 5);
console.log(`assert ON nFast between 3 and 5: ${nFastPass ? 'PASS' : 'FAIL'} (A:${on.t60.pA.stripe?.nFast}, B:${on.t60.pB.stripe?.nFast})`);

// BOTH sides, not either: the profile diverges every direction's proxies, so a
// side that reports no skew is a detection failure, not an asymmetric network.
const peerSkewMaxPass = (on.t60.pA.peerSkew?.max >= 10) && (on.t60.pB.peerSkew?.max >= 10);
console.log(`assert ON peerSkew.max >= 10: ${peerSkewMaxPass ? 'PASS' : 'FAIL'} (A:${on.t60.pA.peerSkew?.max}, B:${on.t60.pB.peerSkew?.max})`);

// Assert 4: POST-DEMOTION LEAKAGE <= 0.5%
const leakageA = calcDeltaLeakage(on.t30.pA, on.t60.pA);
const leakageB = calcDeltaLeakage(on.t30.pB, on.t60.pB);
const leakagePass = leakageA.share <= 0.005 && leakageB.share <= 0.005;
console.log(`assert post-demotion leakage <= 0.5%: ${leakagePass ? 'PASS' : 'FAIL'} (A: ${leakageA.pctStr} deltas [${leakageA.deltas.join(',')}], B: ${leakageB.pctStr} deltas [${leakageB.deltas.join(',')}])`);

// Assert 5: DEPTH WIN: mean of ON ringDepthMs (both sides, t=60) <= mean of OFF ringDepthMs - 6
const onDepthA = on.t60.pA.ringDepthMs, onDepthB = on.t60.pB.ringDepthMs;
const offDepthA = off.t60.pA.ringDepthMs, offDepthB = off.t60.pB.ringDepthMs;
const meanOnDepth = (onDepthA != null && onDepthB != null) ? (onDepthA + onDepthB) / 2 : null;
const meanOffDepth = (offDepthA != null && offDepthB != null) ? (offDepthA + offDepthB) / 2 : null;
const depthWinPass = (meanOnDepth != null && meanOffDepth != null) && (meanOnDepth <= meanOffDepth - 6);
console.log(`assert ON receiver ringDepthMs <= OFF ringDepthMs - 6: ${depthWinPass ? 'PASS' : 'FAIL'} (ON mean:${meanOnDepth?.toFixed(1) ?? 'null'} ms, OFF mean:${meanOffDepth?.toFixed(1) ?? 'null'} ms)`);

// Assert 6: NO HARM: mean ON concealedMs <= mean OFF concealedMs + 200
const onConcealA = on.t60.pA.concealedMs, onConcealB = on.t60.pB.concealedMs;
const offConcealA = off.t60.pA.concealedMs, offConcealB = off.t60.pB.concealedMs;
const meanOnConceal = (onConcealA != null && onConcealB != null) ? (onConcealA + onConcealB) / 2 : null;
const meanOffConceal = (offConcealA != null && offConcealB != null) ? (offConcealA + offConcealB) / 2 : null;
const noHarmPass = (meanOnConceal != null && meanOffConceal != null) && (meanOnConceal <= meanOffConceal + 200);
console.log(`assert ON concealedMs <= OFF concealedMs + 200: ${noHarmPass ? 'PASS' : 'FAIL'} (ON mean:${meanOnConceal?.toFixed(1) ?? 'null'} ms, OFF mean:${meanOffConceal?.toFixed(1) ?? 'null'} ms)`);

// Assert 7: BYTES: total bytesSent ON within 2% of OFF
const onTotalBytes = (on.t60.pA.bytesSent ?? 0) + (on.t60.pB.bytesSent ?? 0);
const offTotalBytes = (off.t60.pA.bytesSent ?? 0) + (off.t60.pB.bytesSent ?? 0);
const bytesDiffRatio = offTotalBytes > 0 ? Math.abs(onTotalBytes - offTotalBytes) / offTotalBytes : 0;
const bytesSentPass = bytesDiffRatio <= 0.02;
console.log(`assert total bytesSent ON within 2% of OFF: ${bytesSentPass ? 'PASS' : 'FAIL'} (ON:${onTotalBytes}, OFF:${offTotalBytes}, diff:${(bytesDiffRatio * 100).toFixed(2)}%)`);

// Compact summary table line
console.log(`Summary: ON A [ring:${on.t60.pA.ringDepthMs}ms m2e:${on.t60.pA.mouthToEarMs}ms conceal:${on.t60.pA.concealedMs}ms] B [ring:${on.t60.pB.ringDepthMs}ms m2e:${on.t60.pB.mouthToEarMs}ms conceal:${on.t60.pB.concealedMs}ms] vs OFF A [ring:${off.t60.pA.ringDepthMs}ms m2e:${off.t60.pA.mouthToEarMs}ms conceal:${off.t60.pA.concealedMs}ms] B [ring:${off.t60.pB.ringDepthMs}ms m2e:${off.t60.pB.mouthToEarMs}ms conceal:${off.t60.pB.concealedMs}ms]`);

const pass = rewritesPass && framesPass && stripeNonNullPass && nFastPass && peerSkewMaxPass && leakagePass && depthWinPass && noHarmPass && bytesSentPass;
process.exitCode = pass ? 0 : 1;
