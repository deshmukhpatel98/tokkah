// Skew-aware striping (stall & fall-forward hardening) Stage 3 verification rig (Rig B).
//
// What it proves: when fast lanes die mid-call (spec §5 assert 10), the fall-forward path
// in pcm.js (pickDataAssoc walking all associations) keeps audio flowing on whatever lanes remain.
//
// Why RTCDataChannels are not closed directly via DOM/API:
// RTCDataChannel handles inside pcm.js are stored in private module closures and are not exposed on
// window.__tape (window.__tape.pcm returns plain telemetry snapshot objects without dc handles).
// Emulating channel death by route blackhole (+5000 ms proxy flap via sim.flap on three fast proxies)
// is transport-equivalent to channel death by close(), making data channels effectively unreachable.
//
// Divergence profile used: base delay 40 ms, heavy-tailed jitter 6 ms, zero loss, and per-lane
// offsets [0, 24, 0, 12, 0, 24, 0, 0] ms across proxy creation order.
//
// Network is emulated locally via delayProxy candidate rewriting; application logic is NOT emulated —
// verdicts come directly from DEPLOYED production code running on room.tokkah.com.
//
// Arms: ON (?pcmskewstripe=1) vs OFF (bare control).

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

async function armStall(qs) {
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
    const R = `skewstripe-stall${qs ? 'on' : 'off'}-${Date.now().toString(36)}`;
    const pA = await bA.newPage(), pB = await bB.newPage();
    for (const p of [pA, pB]) {
      await p.exposeFunction('__simProxy', async (h, port) => sim.portFor(h, port));
      await p.addInitScript(P2P_REWRITE);
    }
    await pA.goto(`https://room.tokkah.com/?r=${R}${qs}`); await pA.click('#join');
    await pB.goto(`https://room.tokkah.com/?r=${R}${qs}`); await pB.click('#join');
    for (const p of [pA, pB]) await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });

    // Step 1: Connect and run 30 s, sample
    await pA.waitForTimeout(30000);
    const t30A = await getSample(pA);
    const t30B = await getSample(pB);

    // Step 2: Blackhole three fast proxies via sim.flap(idx, +5000)
    const delays = sim.laneDelays();
    const fastProxyIndices = [];
    for (let i = 0; i < delays.length; i++) {
      if (Math.abs(delays[i] - 40) < 0.1) {
        fastProxyIndices.push(i);
        if (fastProxyIndices.length === 3) break;
      }
    }
    // Fallback if fewer than 3 base delay proxies exist
    while (fastProxyIndices.length < 3 && fastProxyIndices.length < delays.length) {
      for (let i = 0; i < delays.length; i++) {
        if (!fastProxyIndices.includes(i)) {
          fastProxyIndices.push(i);
          if (fastProxyIndices.length === 3) break;
        }
      }
    }

    console.log(`[stall] Blackholing 3 proxies [${fastProxyIndices.join(', ')}] with +5000 ms delay at t=30s (${qs || 'control'})`);
    for (const idx of fastProxyIndices) {
      sim.flap(idx, 5000);
    }

    // Step 3: Run 25 s more (to t=55s total) and sample
    await pA.waitForTimeout(25000);
    const t55A = await getSample(pA);
    const t55B = await getSample(pB);

    const latenessMax = sim.lateness()?.max ?? 0;
    const loopLagMax = sim.loopLag()?.max ?? 0;

    return {
      t30: { pA: t30A, pB: t30B },
      t55: { pA: t55A, pB: t55B },
      stalledIndices: fastProxyIndices,
      latenessMax,
      loopLagMax,
    };
  } finally {
    await bA.close().catch(() => {});
    await bB.close().catch(() => {});
    sim.stop();
  }
}

async function armRetryStall(qs) {
  let s = await armStall(qs);
  if (s.t55.pA.framesRecv == null || s.t55.pB.framesRecv == null) {
    console.log(`[retry] arm '${qs || 'control'}' returned null pcm; retrying once`);
    s = await armStall(qs);
  }
  return s;
}

// The stage-2 gate does NOT transfer to this rig, and inheriting it made every
// run unmeasurable: there, a >300 ms arrival spread means a host stall poisoned
// the comparison; HERE it is the stimulus — blackholing three lanes for 5 s is
// supposed to produce seconds of spread. Measured: four straight INVALIDs at
// 837-2599 ms, all of them the injection working correctly.
//
// So spread is judged only BEFORE the injection (t=30, where a stall really is
// contamination), and everything after is judged on what the rig does not
// control: the emulator's own punctuality.
function checkValidity(on, off) {
  const reasons = [];
  const checkArm = (label, armData) => {
    const maxSpreadA = armData.t30.pA.jitSpreadMaxRun ?? 0;
    const maxSpreadB = armData.t30.pB.jitSpreadMaxRun ?? 0;

    if (maxSpreadA > 300) {
      reasons.push(`${label} side A pre-injection jitSpreadMaxRun ${maxSpreadA} ms > 300 ms`);
    }
    if (maxSpreadB > 300) {
      reasons.push(`${label} side B pre-injection jitSpreadMaxRun ${maxSpreadB} ms > 300 ms`);
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

let on = null;
let off = null;
let valid = false;

for (let attempt = 0; attempt < 3; attempt++) {
  on = await armRetryStall('&pcmskewstripe=1');
  off = await armRetryStall('');

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

console.log('skewstripe stall ON  t=55:', JSON.stringify(on.t55));
console.log('skewstripe stall OFF t=55:', JSON.stringify(off.t55));

// Asserts (spec assert 10)

// Assert 1: Live snapshot in both arms (no crash)
const livePass = (on.t55.pA.framesRecv != null) && (on.t55.pB.framesRecv != null) &&
                 (off.t55.pA.framesRecv != null) && (off.t55.pB.framesRecv != null);
console.log(`assert live snapshot reported in both arms: ${livePass ? 'PASS' : 'FAIL'}`);

// Assert 2: framesRecv advanced by > 1000 between t=30 and t=55 in BOTH arms (audio kept flowing on survivors)
const onFramesDeltaA = (on.t55.pA.framesRecv ?? 0) - (on.t30.pA.framesRecv ?? 0);
const onFramesDeltaB = (on.t55.pB.framesRecv ?? 0) - (on.t30.pB.framesRecv ?? 0);
const offFramesDeltaA = (off.t55.pA.framesRecv ?? 0) - (off.t30.pA.framesRecv ?? 0);
const offFramesDeltaB = (off.t55.pB.framesRecv ?? 0) - (off.t30.pB.framesRecv ?? 0);

const framesPass = (onFramesDeltaA > 1000 && onFramesDeltaB > 1000) &&
                   (offFramesDeltaA > 1000 && offFramesDeltaB > 1000);
console.log(`assert framesRecv advanced by > 1000 in BOTH arms: ${framesPass ? 'PASS' : 'FAIL'} (ON A:${onFramesDeltaA} B:${onFramesDeltaB}, OFF A:${offFramesDeltaA} B:${offFramesDeltaB})`);

// Assert 3: ON concealedMs delta <= OFF concealedMs delta + 500
const onConcealDeltaA = (on.t55.pA.concealedMs ?? 0) - (on.t30.pA.concealedMs ?? 0);
const onConcealDeltaB = (on.t55.pB.concealedMs ?? 0) - (on.t30.pB.concealedMs ?? 0);
const offConcealDeltaA = (off.t55.pA.concealedMs ?? 0) - (off.t30.pA.concealedMs ?? 0);
const offConcealDeltaB = (off.t55.pB.concealedMs ?? 0) - (off.t30.pB.concealedMs ?? 0);

const meanOnConcealDelta = (onConcealDeltaA + onConcealDeltaB) / 2;
const meanOffConcealDelta = (offConcealDeltaA + offConcealDeltaB) / 2;
const concealPass = meanOnConcealDelta <= meanOffConcealDelta + 500;
console.log(`assert ON concealedMs delta <= OFF concealedMs delta + 500: ${concealPass ? 'PASS' : 'FAIL'} (ON mean delta:${meanOnConcealDelta.toFixed(1)} ms [A:${onConcealDeltaA}, B:${onConcealDeltaB}], OFF mean delta:${meanOffConcealDelta.toFixed(1)} ms [A:${offConcealDeltaA}, B:${offConcealDeltaB}])`);

// Assert 4: ON nFast >= 3 at the end (floor holds)
const floorPass = (on.t55.pA.stripe?.nFast >= 3) && (on.t55.pB.stripe?.nFast >= 3);
console.log(`assert ON nFast >= 3 at end: ${floorPass ? 'PASS' : 'FAIL'} (ON nFast A:${on.t55.pA.stripe?.nFast}, B:${on.t55.pB.stripe?.nFast})`);

const pass = livePass && framesPass && concealPass && floorPass;
process.exitCode = pass ? 0 : 1;
