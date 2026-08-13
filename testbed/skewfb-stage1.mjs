// Stage 1 lane-skew feedback rig.
//
// What it proves: T_SKEW feedback reports flow from receiver to sender,
// peerSkew is reported in snapshot on both sides with ageMs < 1000 and
// peerSkew.max matching peer's measured laneSkew.max within 2 ms, while
// striping distribution remains unchanged (max lane share within 1% of 1/6).

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

async function arm(qs) {
  const sim = await startP2PSim({
    oneWayMs: 40,
    jitterMs: 6,
    jitterModel: 'heavy',
    lossPct: 0,
    laneOffsetsMs: [0, 24, 0, 12, 0, 24, 0, 0],
    seed: Number(process.argv.find((a) => a.startsWith('--seed='))?.slice(7) ?? 1),
  });
  const bA = await chromium.launch({ executablePath: CHROME, headless: true, args: mk('realA.mjpeg', 'realA.wav') });
  const bB = await chromium.launch({ executablePath: CHROME, headless: true, args: mk('realB.mjpeg', 'realB.wav') });
  try {
    const R = `skewfb-stage1-${Date.now().toString(36)}`;
    const pA = await bA.newPage(), pB = await bB.newPage();
    for (const p of [pA, pB]) {
      await p.exposeFunction('__simProxy', async (h, port) => sim.portFor(h, port));
      await p.addInitScript(P2P_REWRITE);
    }
    await pA.goto(`https://room.tokkah.com/?r=${R}${qs}`); await pA.click('#join');
    await pB.goto(`https://room.tokkah.com/?r=${R}${qs}`); await pB.click('#join');
    for (const p of [pA, pB]) await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });
    await pA.waitForTimeout(60000);
    const samplePage = async (p) => {
      return await p.evaluate(() => {
        const pc = window.__tape?.pcm;
        const snap = (typeof pc?.snapshot === 'function' ? pc.snapshot() : pc) ?? {};
        return {
          laneSkew: snap.laneSkew ?? null,
          peerSkew: snap.peerSkew ?? null,
          perAssoc: snap.perAssoc ?? [],
          framesRecv: window.__tape?.pcm?.framesRecv ?? null,
          rewrites: window.__rewrites?.length ?? 0,
        };
      });
    };
    const sA = await samplePage(pA);
    const sB = await samplePage(pB);
    return { sA, sB };
  } finally {
    await bA.close().catch(() => {});
    await bB.close().catch(() => {});
    sim.stop();
  }
}

async function armRetry(qs) {
  let res = await arm(qs);
  if (res.sA.framesRecv == null || res.sB.framesRecv == null) {
    console.log(`[retry] arm returned null pcm; retrying once`);
    res = await arm(qs);
  }
  return res;
}

const { sA, sB } = await armRetry('');
console.log('Side A snapshot sample:', JSON.stringify(sA));
console.log('Side B snapshot sample:', JSON.stringify(sB));

const rewritesPass = (sA.rewrites > 0) && (sB.rewrites > 0);
console.log('assert rewrites > 0 both sides:', rewritesPass ? 'PASS' : `FAIL (A:${sA.rewrites}, B:${sB.rewrites})`);

const peerSkewFlowingA = sA.peerSkew != null && sA.peerSkew.ageMs != null && sA.peerSkew.ageMs < 1000;
const peerSkewFlowingB = sB.peerSkew != null && sB.peerSkew.ageMs != null && sB.peerSkew.ageMs < 1000;
const peerSkewFlowingPass = peerSkewFlowingA && peerSkewFlowingB;
console.log('assert peerSkew non-null and ageMs < 1000 both sides:', peerSkewFlowingPass ? 'PASS' : `FAIL (A:${JSON.stringify(sA.peerSkew)}, B:${JSON.stringify(sB.peerSkew)})`);

const diffA = (sA.peerSkew?.max != null && sB.laneSkew?.max != null) ? Math.abs(sA.peerSkew.max - sB.laneSkew.max) : Infinity;
const diffB = (sB.peerSkew?.max != null && sA.laneSkew?.max != null) ? Math.abs(sB.peerSkew.max - sA.laneSkew.max) : Infinity;
const peerSkewMatchPass = diffA <= 2 && diffB <= 2;
console.log('assert peerSkew.max matches peer laneSkew.max within 2 ms:', peerSkewMatchPass ? 'PASS' : `FAIL (A peerSkew.max ${sA.peerSkew?.max} vs B laneSkew.max ${sB.laneSkew?.max} diff ${diffA.toFixed(1)}; B peerSkew.max ${sB.peerSkew?.max} vs A laneSkew.max ${sA.laneSkew?.max} diff ${diffB.toFixed(1)})`);

function checkMaxLaneShare(perAssoc) {
  if (!perAssoc || perAssoc.length === 0) return { pass: false, maxShare: 0, target: 1/6 };
  const total = perAssoc.reduce((acc, a) => acc + (a.framesSent || 0), 0);
  if (total === 0) return { pass: false, maxShare: 0, target: 1/6 };
  const maxSent = Math.max(...perAssoc.map(a => a.framesSent || 0));
  const maxShare = maxSent / total;
  const target = 1 / perAssoc.length;
  const pass = Math.abs(maxShare - target) <= 0.01;
  return { pass, maxShare, target };
}

const shareA = checkMaxLaneShare(sA.perAssoc);
const shareB = checkMaxLaneShare(sB.perAssoc);
const sharePass = shareA.pass && shareB.pass;
console.log('assert perAssoc framesSent max lane share within 1% of 1/6 both sides:', sharePass ? 'PASS' : `FAIL (A maxShare: ${shareA.maxShare?.toFixed(4)}, B maxShare: ${shareB.maxShare?.toFixed(4)})`);

const framesRecvPass = (sA.framesRecv > 1000) && (sB.framesRecv > 1000);
console.log('assert framesRecv > 1000 both sides:', framesRecvPass ? 'PASS' : `FAIL (A:${sA.framesRecv}, B:${sB.framesRecv})`);

const pass = rewritesPass && peerSkewFlowingPass && peerSkewMatchPass && sharePass && framesRecvPass;
process.exitCode = pass ? 0 : 1;
