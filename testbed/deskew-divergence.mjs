// De-skew A/B rig under per-lane route divergence.
//
// What it proves: on long geographic paths with 16-32 ms of route divergence across SCTP lanes,
// per-lane de-skew detects the arrival offset skew, applies compensation, and reclaims playout
// buffer depth (ringDepthMs) without increasing audio concealment (concealedMs).
//
// Divergence profile used: base delay 40 ms, heavy-tailed jitter 6 ms, zero loss, and per-lane
// offsets [0, 24, 0, 12, 0, 24, 0, 0] ms across creation order.
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

// Copied verbatim from testbed/call.mjs (where it is a private, non-exported const)
// to patch RTCPeerConnection.prototype.addIceCandidate & setRemoteDescription so remote
// candidates are transparently routed through local delayProxy instances.
const P2P_REWRITE = `
  const OrigPC = window.RTCPeerConnection;
  window.__rewrites = [];
  // candidate:FOUND COMPONENT udp PRIORITY IP PORT typ host ...
  //   fields:  0             1         2   3        4  5
  const rewrite = async (line) => {
    const f = String(line).split(' ');
    if (f.length < 7 || !/^udp$/i.test(f[2])) return null;   // TCP candidates carry no media here
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
        // An empty candidate is the end-of-candidates signal and must pass through untouched.
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
      // Chrome sometimes ships candidates inside the SDP rather than trickling them. Those
      // would be a direct path around the delay line, so they need the same treatment — and
      // missing them would show up as a run that reports 80 ms while measuring 0.
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

async function arm(qs) {
  // Fresh sim per arm so proxies accumulate per-arm candidates independently.
  const sim = await startP2PSim({
    oneWayMs: 40,
    jitterMs: 6,
    jitterModel: 'heavy',
    lossPct: 0,
    // --offsets=0 runs the discriminating control: same heavy tail, no divergence.
    // If conceal there matches the divergent ON arm, de-skew merely restored
    // correct provisioning and the OFF arm's lower conceal was accidental
    // over-buffering, not correctness.
    laneOffsetsMs: process.argv.includes('--offsets=0') ? [] : [0, 24, 0, 12, 0, 24, 0, 0],
    // Concealment varies run to run (heavy tail + real prod network); a repeat
    // with a different seed separates a stable regression from one draw.
    seed: Number(process.argv.find((a) => a.startsWith('--seed='))?.slice(7) ?? 1),
  });
  const bA = await chromium.launch({ executablePath: CHROME, headless: true, args: mk('realA.mjpeg', 'realA.wav') });
  const bB = await chromium.launch({ executablePath: CHROME, headless: true, args: mk('realB.mjpeg', 'realB.wav') });
  try {
    const R = `deskew-div${qs ? 'off' : 'on'}-${Date.now().toString(36)}`;
    const pA = await bA.newPage(), pB = await bB.newPage();
    for (const p of [pA, pB]) {
      await p.exposeFunction('__simProxy', async (h, port) => sim.portFor(h, port));
      await p.addInitScript(P2P_REWRITE);
    }
    await pA.goto(`https://room.tokkah.com/?r=${R}${qs}`); await pA.click('#join');
    await pB.goto(`https://room.tokkah.com/?r=${R}${qs}`); await pB.click('#join');
    for (const p of [pA, pB]) await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });
    await pA.waitForTimeout(60000);
    const s = await pA.evaluate(() => {
      const pc = window.__tape?.pcm;
      const snap = (typeof pc?.snapshot === 'function' ? pc.snapshot() : pc) ?? {};
      return {
        laneSkew: snap.laneSkew ?? null,
        mouthToEarMs: snap.mouthToEarMs ?? null,
        ringDepthMs: snap.m2eParts?.ringDepthMs ?? null,
        framesRecv: window.__tape?.pcm?.framesRecv ?? null,
        concealedMs: window.__tape?.pcm?.concealedMs ?? null,
        rewrites: window.__rewrites?.length ?? 0,
      };
    });
    return s;
  } finally {
    await bA.close().catch(() => {});
    await bB.close().catch(() => {});
    sim.stop();
  }
}

// PCM occasionally fails to start under stacked headless Chromes (seen live
// 2026-08-13: one arm returned all nulls, re-run alone was clean). One retry
// on a null-pcm arm keeps the rig from crying wolf.
async function armRetry(qs) {
  let s = await arm(qs);
  if (s.framesRecv == null) { console.log(`[retry] arm '${qs || 'on'}' returned null pcm; retrying once`); s = await arm(qs); }
  return s;
}

// Flag flipped to opt-in 2026-08-13 (this rig's own verdict): ON is now
// ?deskew=1, bare URL is the control. Skew is MEASURED in both arms.
const on = await armRetry('&deskew=1');
const off = await armRetry('');
console.log('deskew ON :', JSON.stringify(on));
console.log('deskew OFF:', JSON.stringify(off));

const rewritesPass = (on.rewrites > 0) && (off.rewrites > 0);
console.log('assert rewrites > 0 both arms:', rewritesPass ? 'PASS' : `FAIL (ON:${on.rewrites}, OFF:${off.rewrites})`);

const skewMax = on.laneSkew?.max ?? null;
const skewDetectedPass = skewMax != null && skewMax >= 10;
console.log('assert ON arm laneSkew.max >= 10:', skewDetectedPass ? 'PASS' : `FAIL (${skewMax})`);

const appliedPass = on.laneSkew?.applied === 1;
console.log('assert ON arm laneSkew.applied === 1:', appliedPass ? 'PASS' : `FAIL (${on.laneSkew?.applied})`);

const framesPass = (on.framesRecv > 1000) && (off.framesRecv > 1000);
console.log('assert both arms framesRecv > 1000:', framesPass ? 'PASS' : `FAIL (ON:${on.framesRecv}, OFF:${off.framesRecv})`);

const depthWinPass = (on.ringDepthMs != null && off.ringDepthMs != null) && (on.ringDepthMs <= off.ringDepthMs - 6);
console.log('assert ON ringDepthMs <= OFF ringDepthMs - 6:', depthWinPass ? 'PASS' : `FAIL (ON:${on.ringDepthMs}, OFF:${off.ringDepthMs})`);

const noHarmPass = (on.concealedMs != null && off.concealedMs != null) && (on.concealedMs <= off.concealedMs + 200);
console.log('assert ON concealedMs <= OFF concealedMs + 200:', noHarmPass ? 'PASS' : `FAIL (ON:${on.concealedMs}, OFF:${off.concealedMs})`);

const pass = rewritesPass && skewDetectedPass && appliedPass && framesPass && depthWinPass && noHarmPass;
process.exitCode = pass ? 0 : 1;
