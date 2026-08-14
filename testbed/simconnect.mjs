/**
 * Does a call under the P2P sim connect at all? N trials, both ICE-queue arms.
 *
 * Built because skewstripe-stage2 timed out twice at its connect gate with the
 * ICE candidate queue on and passed once with it off — which reads like a
 * regression, and a change to ICE handling that stops calls connecting is a P0
 * whatever else it fixes. The full rig takes ~5 minutes a run and measures
 * twenty other things, so it is the wrong instrument for the question "does it
 * connect". This is that question alone, run enough times to tell a real
 * regression from a flaky rig.
 *
 * The diagnostic that made this necessary: at the timeout the offerer sat in
 * `have-local-offer` with no remote description and ZERO rewrites, and its
 * `ice-flush` log was empty — the queue had never engaged. That is an answer
 * that never arrived, upstream of anything ICE does. But "the evidence points
 * elsewhere" is not the same as "measured", so this measures it.
 *
 *   node testbed/simconnect.mjs [--trials=3]
 */
import { chromium } from 'playwright-core';
import { startP2PSim } from './netsim.mjs';

const CHROME = process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const A = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
const mk = (v, w) => ([
  '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
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

const state = (p) => p.evaluate(() => ({
  conn: window.__tape?.pc?.connectionState ?? null,
  sig: window.__tape?.pc?.signalingState ?? null,
  hasRemote: !!window.__tape?.pc?.remoteDescription,
  rewrites: (window.__rewrites || []).length,
  // Signalling frames, in order — the offer/answer handshake either happened
  // or it did not, and this is the only place that distinguishes them.
  tx: (window.__tape?.tel?.mirror || []).filter((e) => e.kind === 'ws-tx').map((e) => e.data?.type ?? '?'),
  rx: (window.__tape?.tel?.mirror || []).filter((e) => e.kind === 'ws-rx').map((e) => e.data?.type ?? '?'),
  held: (window.__tape?.tel?.mirror || []).filter((e) => e.kind === 'ice-flush')
    .reduce((s, e) => s + (e.data?.held | 0), 0),
}));

async function trial(qs) {
  const sim = await startP2PSim({
    oneWayMs: 40, jitterMs: 6, jitterModel: 'heavy', lossPct: 0,
    laneOffsetsMs: [0, 24, 0, 12, 0, 24, 0, 0], seed: 1,
  });
  const bA = await chromium.launch({ executablePath: CHROME, headless: true, args: mk('realA.mjpeg', 'realA.wav') });
  const bB = await chromium.launch({ executablePath: CHROME, headless: true, args: mk('realB.mjpeg', 'realB.wav') });
  try {
    const R = `simconn-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 5)}`;
    const pA = await bA.newPage(), pB = await bB.newPage();
    for (const p of [pA, pB]) {
      await p.exposeFunction('__simProxy', async (h, port) => sim.portFor(h, port));
      await p.addInitScript(P2P_REWRITE);
    }
    await pA.goto(`https://room.tokkah.com/?r=${R}${qs}`); await pA.click('#join');
    await pB.goto(`https://room.tokkah.com/?r=${R}${qs}`); await pB.click('#join');
    let connected = true;
    for (const p of [pA, pB]) {
      try {
        await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 45000 });
      } catch { connected = false; }
    }
    return { connected, A: await state(pA), B: await state(pB) };
  } finally {
    await bA.close().catch(() => {}); await bB.close().catch(() => {}); sim.stop();
  }
}

const TRIALS = Number(process.argv.find((a) => a.startsWith('--trials='))?.slice(9) ?? 3);
const results = { on: [], off: [] };
for (let i = 1; i <= TRIALS; i++) {
  for (const [arm, qs] of [['on', '&pcmskewstripe=1'], ['off', '&pcmskewstripe=1&icequeue=0']]) {
    const r = await trial(qs);
    results[arm].push(r.connected);
    console.log(`trial ${i} queue-${arm.padEnd(3)}: ${r.connected ? 'CONNECTED' : 'TIMED OUT'}  ` +
      `A[sig=${r.A.sig} remote=${r.A.hasRemote} rw=${r.A.rewrites} held=${r.A.held} tx=${r.A.tx.join('/')} rx=${r.A.rx.join('/')}]  ` +
      `B[sig=${r.B.sig} remote=${r.B.hasRemote} rw=${r.B.rewrites} held=${r.B.held}]`);
  }
}
const rate = (a) => `${results[a].filter(Boolean).length}/${results[a].length}`;
console.log(`\nconnected with queue ON : ${rate('on')}`);
console.log(`connected with queue OFF: ${rate('off')}`);
const onOk = results.on.filter(Boolean).length, offOk = results.off.filter(Boolean).length;
if (onOk < offOk) console.log('\nVERDICT: FAIL — the ICE queue is implicated; it connects less often than the control.');
else if (onOk === 0 && offOk === 0) console.log('\nVERDICT: UNMEASURABLE — the sim path is broken for BOTH arms. Fix the rig, not the app.');
else if (onOk === TRIALS && offOk === TRIALS) console.log('\nVERDICT: PASS — every call connected on both arms.');
else console.log(`\nVERDICT: PASS (with noise) — the queue is not implicated, but ${TRIALS * 2 - onOk - offOk} run(s) missed on both arms alike.`);
process.exit(onOk < offOk ? 1 : 0);
