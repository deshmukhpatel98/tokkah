/**
 * THE RELEASE RATE, MEASURED AS A PAIR.
 *
 * ─── WHAT WENT WRONG WITH THE OBVIOUS DESIGN ──────────────────────────────────
 * The question: `pcm.js` holds the peak of its arrival-spread estimate and releases
 * it at 1 ms/s, so one 90 ms hole costs ~47 ms of buffered latency for ~72 s
 * (measured, testbed/onehole.mjs). Is a faster release better?
 *
 * Four sequential runs — {1 hole, 6 holes} x {1 ms/s, 8 ms/s} — answered nothing,
 * and the way they failed is the reason this file exists:
 *
 *   - Run 1 ended with target back at its 2-frame floor. Runs 2, 3 and 4 all ended
 *     PINNED AT THE 15-FRAME CEILING. Monotone in run order, which is not what a
 *     release-rate effect looks like; it is what accumulated host state looks like.
 *   - Run 3's BASELINE, before any injection, read depth -22935 ms with 2867 frames
 *     concealed. 2867 frames / 125 fps = 22.9 s, matching the negative depth exactly:
 *     that call's playhead ran 23 s ahead of its audio. The arm was dead on arrival
 *     and still printed a tidy result table.
 *   - One arm reported a NEGATIVE excursion area next to a positive peak.
 *
 * Two lessons, both structural:
 *   1. onehole.mjs inherited the honesty primitives but NOT the preflight discipline.
 *      A baseline is a measurement like any other and must prove itself before
 *      anything is compared to it.
 *   2. Sequential arms on one laptop cannot resolve this effect, because run order
 *      moves the metric more than the variable does.
 *
 * ─── THE DESIGN ───────────────────────────────────────────────────────────────
 * Run both release rates as the TWO SIDES OF ONE CALL. `?pcmjitrel=` is receive-side
 * only, so side A can hold slowly while side B holds fast, in the same call, on the
 * same host, at the same instant. Then inject the hole into BOTH receive paths
 * simultaneously and compare their responses.
 *
 * Run order becomes irrelevant. Host state is shared. The stimulus is the same event.
 *
 * And it comes with a free null test: with --relA equal to --relB the two sides are
 * identical software, so any difference the report shows is the instrument's own
 * side-to-side spread. Run that FIRST and you know how big a difference has to be
 * before it means anything. (An F-test on this project once returned p=0.0143 on two
 * arms that were byte-identical, which is why the null arm is not optional.)
 *
 *   node testbed/relpair.mjs [--relA=0.25] [--relB=2] [--hole=90] [--holes=1]
 *                            [--gap=10] [--settle=25] [--recover=150] [--json=PATH]
 *
 * --relA/--relB are ms of spread released per 250 ms tick; x4 for per-second.
 * 0.25 = 1 ms/s is what ships today.
 */
import { chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';
import { startP2PSim } from '/Users/earningsgpt/video calling/testbed/netsim.mjs';
import os from 'node:os';
import fs from 'node:fs';

const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const CAM = '/Users/earningsgpt/video calling/testbed/media/cam1080.mjpeg';
const AUD = '/Users/earningsgpt/video calling/testbed/media/conv/A.wav';

const KNOWN = new Set(['relA', 'relB', 'hole', 'holes', 'gap', 'settle', 'recover', 'query', 'base', 'json',
                       'bw', 'loss', 'rtt', 'jitter', 'jbmaxA', 'jbmaxB', 'swA', 'swB']);
for (const a of process.argv.slice(2)) {
  const m = /^--([a-zA-Z]+)(=|$)/.exec(a);
  if (!m || !KNOWN.has(m[1])) {
    console.error(`unknown flag: ${a}\nknown: ${[...KNOWN].map((k) => '--' + k).join(' ')}`);
    process.exit(2);
  }
}
const arg = (k, d) => {
  const m = process.argv.find((a) => a.startsWith(`--${k}=`));
  return m ? m.slice(k.length + 3) : d;
};
const REL = { A: Number(arg('relA', 0.25)), B: Number(arg('relB', 2)) };
// Per-side buffer CAP (maxTargetFrames, 8 ms per frame). Receive-side like pcmjitrel, so it
// pairs inside one call the same way. 0 = leave the app default.
//
// This exists because the bandwidth-shaped regime turned out to be untestable through the
// release rate: `want = min(cap, raw)` discards the release term whenever raw > cap, and a
// 4-point sweep found the target pinned at the cap for 46-48 of 48 samples at 0.3, 0.8 and
// 1.5 Mbps. In that regime the cap IS the latency, and it is the only knob with authority.
const JB = { A: Number(arg('jbmaxA', 0)), B: Number(arg('jbmaxB', 0)) };
// Per-side FEC code: --swA=1 puts side A's SENDER on the sliding window (T_PAR_SW),
// leaving RS on the other. SENDER-side, unlike pcmjitrel/pcmjbmax — so the arm is
// measured at the OTHER side's receiver: with --swA=1 --swB=0, side B's concealment
// column is the window's result and side A's is block RS's. The swfec attribution
// block after the summary spells this out per run so it cannot be misread.
const SW_PASSED = { A: process.argv.some((a) => a.startsWith('--swA=')),
                    B: process.argv.some((a) => a.startsWith('--swB=')) };
const SWF = { A: arg('swA', '0') === '1', B: arg('swB', '0') === '1' };
const HOLE = Number(arg('hole', 90));
const HOLES = Number(arg('holes', 1));
const GAP = Number(arg('gap', 10));
const SETTLE = Number(arg('settle', 25));
const RECOVER = Number(arg('recover', 150));
const QUERY = arg('query', 'tape=2');
const BASE = arg('base', 'https://room.tokkah.com');
const JSON_OUT = arg('json', null);
for (const [k, v] of [['jbmaxA', JB.A], ['jbmaxB', JB.B]]) {
  if (!Number.isFinite(v) || v < 0 || (v > 0 && (v < 2 || v > 60 || v !== Math.round(v)))) {
    console.error(`--${k} must be 0 (app default) or a whole number of frames in 2..60`); process.exit(2);
  }
}
for (const [k, v, min] of [['relA', REL.A, 0.01], ['relB', REL.B, 0.01], ['hole', HOLE, 0],
                           ['holes', HOLES, 1], ['gap', GAP, 1], ['settle', SETTLE, 15], ['recover', RECOVER, 30]]) {
  if (!Number.isFinite(v) || v < min) { console.error(`--${k} must be a number >= ${min}`); process.exit(2); }
}
const IS_NULL = REL.A === REL.B && JB.A === JB.B && SWF.A === SWF.B;
// Which parameter this invocation is actually testing. It decides how to read a clamped
// run: with the caps EQUAL, clamping means the release rate had no authority and the
// verdict must be refused; with the caps DIFFERENT, clamping is the mechanism under test.
const UNDER_TEST = SWF.A !== SWF.B ? 'swfec'
  : (JB.A !== JB.B ? 'cap' : (REL.A !== REL.B ? 'release' : 'null'));
// Link shaping, so the regime where the SLOW release is claimed to win can be reached.
// Under bandwidth shaping packets are genuinely tail-dropped, and depth buys RS/FEC time
// to repair them; against main-thread stalls every packet arrives merely late and depth
// prevents nothing. Those are different mechanisms and only one of them was ever tested
// against here.
const BW = Number(arg('bw', 0));         // Mbps ceiling, 0 = unshaped
const LOSS = Number(arg('loss', 0));     // % datagram loss
const RTT = Number(arg('rtt', 0));       // ms round trip to emulate
const JIT = Number(arg('jitter', 0));    // ms of delay jitter
const SHAPED = BW > 0 || LOSS > 0 || RTT > 0 || JIT > 0;

function need(o, k, where) {
  if (o == null) throw new Error(`${where}: object is ${o}, cannot read "${k}"`);
  if (o[k] === undefined) throw new Error(`${where}: field "${k}" does not exist. Available: ${Object.keys(o).slice(0, 40).join(', ')}`);
  return o[k];
}

// Lifted verbatim from testbed/call.mjs. Rewrites every ICE candidate — trickled AND
// embedded in SDP — to point at the delay proxy. The SDP-embedded case is not optional:
// Chrome sometimes ships candidates inline, and missing them gives a direct loopback
// path around the shaper, i.e. a run that reports 300 kbps while measuring an unshaped
// link. `window.__rewrites` is what lets the preflight below PROVE it took effect.
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

const mk = async (tag, sim) => {
  const ctx = await chromium.launchPersistentContext('', {
    executablePath: CHROME, headless: true,
    args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
      `--use-file-for-fake-video-capture=${CAM}`, `--use-file-for-fake-audio-capture=${AUD}`,
      '--autoplay-policy=no-user-gesture-required'],
    viewport: { width: 1000, height: 700 },
  });
  const page = await ctx.newPage();
  if (sim) {
    await page.exposeFunction('__simProxy', async (h, p) => sim.portFor(h, p));
    await page.addInitScript(P2P_REWRITE);
  }
  return { ctx, page, tag, rel: REL[tag] };
};

const snap = (p) => p.evaluate(() => ({
  hasTape: !!window.__tape,
  pcm: window.__tape?.pcm ?? null,
  status: document.getElementById('status')?.textContent ?? null,
}));

const schedLag = (p, ms = 2000) => p.evaluate((dur) => new Promise((res) => {
  const STEP = 4, late = [];
  let prev = performance.now(); const t0 = prev;
  const id = setInterval(() => {
    const now = performance.now();
    late.push(now - prev - STEP); prev = now;
    if (now - t0 >= dur) {
      clearInterval(id);
      const s = late.filter((x) => x > 0).sort((a, b) => a - b);
      const q = (f) => (s.length ? +s[Math.min(s.length - 1, Math.floor(f * s.length))].toFixed(1) : 0);
      res({ n: late.length, p50: q(0.5), p95: q(0.95), max: s.length ? +s[s.length - 1].toFixed(1) : 0 });
    }
  }, STEP);
}), ms);

/** Busy-wait on the main thread — where arrivals are timestamped, so nothing is
 *  dispatched for the duration and the backlog then lands in a clump. That clump is
 *  the measured signature of the real stalls, which is why this is the faithful
 *  stimulus rather than merely a convenient one. Returns the ACHIEVED duration. */
const block = (p, ms) => p.evaluate((dur) => {
  const t0 = performance.now();
  while (performance.now() - t0 < dur) { /* deliberately hot */ }
  return +(performance.now() - t0).toFixed(1);
}, ms);

const room = 'rel' + Math.random().toString(36).slice(2, 7);
const report = {
  meta: { room, relA: REL.A, relB: REL.B, relAPerSec: 4 * REL.A, relBPerSec: 4 * REL.B,
          jbmaxA: JB.A || null, jbmaxB: JB.B || null, underTest: UNDER_TEST,
          swA: SWF.A, swB: SWF.B,
          isNullArm: IS_NULL, holeMs: HOLE, holes: HOLES, gapS: GAP, settleS: SETTLE, recoverS: RECOVER,
          query: QUERY, base: BASE, at: new Date().toISOString(),
          shaped: SHAPED, bwMbps: BW, lossPct: LOSS, rttMs: RTT, jitterMs: JIT,
          host: `${os.cpus().length} cores, ${os.platform()} ${os.release()}` },
  calibration: {}, baseline: {}, series: [], sides: {}, limits: [],
};

console.log(`\n${'━'.repeat(80)}`);
console.log(`RELEASE PAIR  room=${room}  A=${4 * REL.A} ms/s  B=${4 * REL.B} ms/s  ` +
  `${HOLES}x${HOLE}ms${HOLES > 1 ? ` every ${GAP}s` : ''}  recover=${RECOVER}s`);
console.log('━'.repeat(80));
if (IS_NULL) {
  console.log(`\n  NULL ARM: both sides run identical software. Every difference below is this`);
  console.log(`  instrument's own side-to-side spread, and is the threshold a real effect must clear.\n`);
}

// HOST LOAD: WAIT, DO NOT VOID.
//
// This gate used to abort instantly above 0.7, which made a back-to-back sequence
// IMPOSSIBLE: `os.loadavg()[0]` is the 1-MINUTE average, so at the moment run N+1
// starts it is still carrying run N's own two browsers. Eight paired calls produced
// one result and seven aborts at 74-79%, all within a second of the previous run
// ending. The gate was reporting real load, but load I had just created myself and
// that was already decaying.
//
// Measured on this laptop: idle-with-desktop-apps baseline is 30-40% of 10 cores
// (WindowServer, Camo Studio, VLC, coreaudiod), and a finished run decays back into
// that band in well under a minute. So the honest behaviour is to WAIT for the decay
// and abort only if the host is PERSISTENTLY loaded, which is a different fact and
// deserves a different message. Both the wait and the load are recorded, because a
// run that started at 68% is evidence about itself.
{
  const cores = os.cpus().length;
  const load = () => os.loadavg()[0] / cores;
  const CEIL = 0.7, WAIT_MAX_S = 240, POLL_S = 5;
  const t0 = Date.now();
  let l = load();
  if (l > CEIL) {
    console.log(`  host load ${(100 * l).toFixed(0)}% of ${cores} cores — waiting for it to settle below ${100 * CEIL}%`);
    while (l > CEIL && (Date.now() - t0) / 1000 < WAIT_MAX_S) {
      await new Promise((r) => setTimeout(r, POLL_S * 1000));
      l = load();
    }
  }
  const waitedS = Math.round((Date.now() - t0) / 1000);
  report.meta.hostLoadStart = +l.toFixed(3);
  report.meta.hostLoadWaitedS = waitedS;
  if (l > CEIL) {
    console.error(`  ABORT: host still at ${(100 * l).toFixed(0)}% after waiting ${waitedS}s — this is ` +
      `persistent load, not my own run decaying, and it would measure the laptop`);
    process.exit(3);
  }
  console.log(`  host load ${(100 * l).toFixed(0)}% of ${cores} cores` +
    (waitedS >= POLL_S ? `  (settled after ${waitedS}s)` : ''));
}

// The simulator must exist before the browsers launch: its proxy ports are handed out
// through an init script.
const sim = SHAPED
  ? await startP2PSim({ oneWayMs: RTT / 2, jitterMs: JIT, lossPct: LOSS, bwMbps: BW, seed: 7 })
  : null;
if (SHAPED) console.log(`  SHAPED: ${BW || '-'} Mbps, ${LOSS}% loss, ${RTT} ms RTT, ${JIT} ms jitter (one crossing per direction)`);
else console.log(`  UNSHAPED: loopback. Every packet arrives; concealment can only come from LATENESS.`);

const A = await mk('A', sim), B = await mk('B', sim);
try {
  for (const e of [A, B]) {
    // Explicit WHEN NAMED: the app default flipped to the window on
    // 2026-08-04, so `--swX=0` must force `pcmsw=0` on the wire or every swfec
    // A/B would silently become window-vs-window. But a flag the caller never
    // passed appends NOTHING — that run measures the app default as deployed,
    // which is its own thing worth measuring and must not be quietly rewritten
    // into either arm.
    const url = `${BASE}/?r=${room}&${QUERY}&pcmjitrel=${e.rel}`
      + (JB[e.tag] ? `&pcmjbmax=${JB[e.tag]}` : '')
      + (SW_PASSED[e.tag] ? `&pcmsw=${SWF[e.tag] ? 1 : 0}` : '');
    await e.page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await e.page.waitForSelector('#join', { timeout: 30000 });
    // The page must AGREE about its own release rate. A typo in the param name would
    // silently give both sides the default and produce a beautifully null result.
    const seen = await e.page.evaluate(() => window.__tape?.pcm?.jitRelease ?? null);
    console.log(`  ${e.tag}: url ...pcmjitrel=${e.rel}${JB[e.tag] ? `&pcmjbmax=${JB[e.tag]}` : ''}   ` +
      `page reports jitRelease ${seen === null ? '(not up yet, checked again after join)' : seen}`);
  }
  await A.page.click('#join');
  await A.page.waitForTimeout(700);
  await B.page.click('#join');
  for (const e of [A, B]) {
    await e.page.waitForFunction(() => document.querySelector('#status')?.textContent === 'connected', null, { timeout: 40000 });
  }
  console.log(`  connected. settling ${SETTLE}s\n`);
  await A.page.waitForTimeout(SETTLE * 1000);

  // ── PREFLIGHT on the baseline itself. This is what onehole.mjs lacked. ──
  console.log(`PREFLIGHT — a baseline is a measurement and must prove itself\n`);
  // A shaped run that quietly went unshaped is the worst outcome available here: it
  // would show the slow release losing in the one regime where it is supposed to win,
  // and the number would look entirely reasonable. So require EVIDENCE that candidates
  // were rewritten, not merely that a shaper was constructed.
  if (SHAPED) {
    for (const e of [A, B]) {
      const rw = await e.page.evaluate(() => window.__rewrites ?? null);
      if (rw === null) throw new Error(`${e.tag}: window.__rewrites absent — the ICE rewrite init script never ran, so this run is UNSHAPED while claiming otherwise`);
      const errs = rw.filter((x) => x.error);
      const done = rw.filter((x) => x.to);
      if (!done.length) throw new Error(`${e.tag}: zero ICE candidates rewritten (${rw.length} entries, ${errs.length} errors: ` +
        `${errs.slice(0, 2).map((x) => x.error).join('; ')}). The media path bypassed the shaper; a run that reports a ` +
        `constrained link while measuring loopback is not a weaker result, it is a false one.`);
      console.log(`  ${e.tag} shaping ACTIVE: ${done.length} candidate(s) rewritten through the delay proxy` +
        `${errs.length ? ` (${errs.length} rewrite errors)` : ''}`);
      report.limits.push(`${e.tag}: ${done.length} candidates rewritten`);
    }
  }
  for (const e of [A, B]) {
    const L = await schedLag(e.page);
    report.calibration[e.tag] = L;
    const ok = L.p95 < 20;
    console.log(`  ${e.tag} scheduler lateness p50 ${L.p50} p95 ${L.p95} max ${L.max} ms -> ${ok ? 'TRUSTED' : 'UNTRUSTED'}`);
    if (!ok) throw new Error(`${e.tag}: scheduler p95 ${L.p95} ms. Arrival "jitter" here would be this laptop; the comparison is void.`);

    const s = await snap(e.page);
    if (!s.hasTape) throw new Error(`${e.tag}: window.__tape absent`);
    if (!s.pcm) throw new Error(`${e.tag}: PCM lane not running`);
    const rel = need(s.pcm, 'jitRelease', `${e.tag} pcm`);
    if (Math.abs(rel - e.rel) > 1e-9) {
      throw new Error(`${e.tag}: asked for jitRelease ${e.rel}, page is running ${rel}. The query param did not take, ` +
        `and a run where neither side got its setting would read as a clean null result.`);
    }
    const depth = need(s.pcm, 'depthMs', 'pcm'), lost = need(s.pcm, 'lostFrames', 'pcm');
    const recv = need(s.pcm, 'framesRecv', 'pcm'), target = need(s.pcm, 'targetFrames', 'pcm');
    // DEPTH IS NOT LATENCY, and conflating them is the trap this whole comparison
    // sits in. `ageMs` = now() - senderCaptureWall - clockOffsetMs, so it is real
    // capture-to-arrival transit; mouth-to-ear is roughly age + time spent in the
    // buffer. Without BOTH columns a change that moves audio from the wire into the
    // buffer looks free. And `ageMs` is meaningless when the offset is null: `?? 0`
    // on a null offset once produced a 637 ms age on an 80 ms call here, so a null
    // offset is fatal rather than defaulted.
    const off = need(s.pcm, 'clockOffsetMs', 'pcm');
    if (off === null) throw new Error(`${e.tag}: clockOffsetMs is null, so every ageMs is uninterpretable. ` +
      `A latency comparison without a transit column cannot distinguish "less latency" from "the same latency, moved".`);
    const ageP50 = need(s.pcm, 'ageP50', 'pcm');
    if (ageP50 === null) throw new Error(`${e.tag}: ageP50 null after ${SETTLE}s — no transit samples, so latency is unmeasurable`);
    // The gates that would have voided three of four arms of the sequential attempt.
    if (!(depth > 0)) throw new Error(`${e.tag}: baseline depthMs ${depth} — a buffer cannot hold negative audio. ` +
      `One earlier run read -22935 ms with 2867 frames concealed (22.9 s at 125 fps, matching exactly): ` +
      `the playhead had run ahead of the lane. Such a run must not produce a result table.`);
    if (depth > 300) throw new Error(`${e.tag}: baseline depthMs ${depth} — already far above the ~15 ms floor before any injection`);
    if (recv < 1000) throw new Error(`${e.tag}: only ${recv} frames received in ${SETTLE}s — the lane is not at rate`);
    // The concealment gate has to be REGIME-AWARE, and the first version was not: it
    // aborted a --bw=0.3 run at 4.19% baseline concealment, which is not a fault but the
    // entire condition under test. Symmetric requirements instead, because each regime's
    // failure is the other's normal:
    //   unshaped -> concealment must be NEAR ZERO, or the call is broken and nothing
    //               measured after an injection is attributable to the injection
    //   shaped   -> concealment must be NON-TRIVIAL, or the shaper is not binding and the
    //               run is secretly the unshaped case. A constraint that reads zero both
    //               when it never engaged and when it engaged hard has caught this project
    //               out before.
    const cf = lost / Math.max(1, recv);
    if (!SHAPED && cf > 0.005) throw new Error(`${e.tag}: baseline concealment ${(100 * cf).toFixed(2)}% (${lost}/${recv}) on an UNSHAPED link — ` +
      `this call is already unhealthy, so nothing measured after an injection could be attributed to it`);
    if (SHAPED && UNDER_TEST === 'swfec') {
      // The concealment gate below is blind here BY DESIGN OF THE ARM: the
      // window side of an swfec run can conceal ~0.000% under a shaper that is
      // dropping tens of thousands of packets (measured: 39,682 tail-drops in
      // a run this gate aborted as "not binding"). Concealment is a POST-
      // repair number and the repair is the thing under test. Ask the shaper
      // question with a signal FEC cannot hide: raw one-way data loss, counted
      // on the seq stream before any repair (pcm.lossPct).
      // ...and raw loss alone is STILL not enough: at hard scarcity the queue
      // absorbs the constraint as LATENESS — frames arrive 100+ ms late but
      // arrive, so the seen-ring reads 0% loss while e2e pins at the cap
      // (measured at 0.7 Mbps, a rate the lane cannot fit under: raw loss 0%,
      // e2e 121 ms). Binding shows up in loss OR depth; accept either.
      const rawLoss = need(s.pcm, 'lossPct', 'pcm');
      if ((rawLoss == null || rawLoss < 0.1) && depth < 60) throw new Error(`${e.tag}: raw pre-repair loss ` +
        `${rawLoss}% AND baseline depth ${depth} ms under ${BW} Mbps / ${LOSS}% shaping — neither loss nor ` +
        `lateness shows a binding constraint, so this swfec run would be secretly unshaped`);
    } else if (SHAPED && cf < 0.001) throw new Error(`${e.tag}: baseline concealment only ${(100 * cf).toFixed(3)}% (${lost}/${recv}) under ` +
      `${BW} Mbps / ${LOSS}% shaping — the constraint is NOT BINDING, so this run would compare the two release rates ` +
      `on an effectively clean link while labelled as a constrained one`);
    report.baseline[e.tag] = { depth, lost, recv, target, jitRelease: rel, ageP50, clockOffsetMs: off,
                               ageP95: need(s.pcm, 'ageP95', 'pcm') };
    console.log(`  ${e.tag} baseline  target ${target}f  depth ${depth} ms  age p50 ${ageP50} ms  ` +
      `conceal ${(100 * cf).toFixed(3)}% (${lost}/${recv})  jitRelease ${rel} (${4 * rel} ms/s)  PASS`);
    console.log(`             mouth-to-ear ~= age + buffer = ${(ageP50 + depth).toFixed(1)} ms  [clockOffset ${off} ms]`);
  }

  // ── inject into BOTH receive paths at once ──
  const fired = [];
  const inject = (async () => {
    for (let i = 0; i < HOLES && HOLE > 0; i++) {
      if (i) await new Promise((r) => setTimeout(r, GAP * 1000));
      const at = Date.now();
      const [a, b] = await Promise.all([block(A.page, HOLE), block(B.page, HOLE)]);
      fired.push({ i, at, A: a, B: b });
      console.log(`  INJECT #${i + 1}/${HOLES}  A ${a} ms  B ${b} ms`);
    }
  })();
  if (HOLES === 1) await inject;

  console.log(`\n   t(s) │  A: tgt  depth    e2e │  B: tgt  depth    e2e     [e2e = age p50 + buffer depth]`);
  const t0 = Date.now();
  const st = { A: { peakT: 0, peakD: 0, atT: 0, atD: 0, back: null }, B: { peakT: 0, peakD: 0, atT: 0, atD: 0, back: null } };
  while (Date.now() - t0 < RECOVER * 1000) {
    const el = +((Date.now() - t0) / 1000).toFixed(1);
    const [sa, sb] = await Promise.all([snap(A.page), snap(B.page)]);
    const row = { t: el };
    for (const [e, s] of [[A, sa], [B, sb]]) {
      if (!s.pcm) throw new Error(`${e.tag}: PCM lane vanished mid-run`);
      const target = need(s.pcm, 'targetFrames', 'pcm'), depth = need(s.pcm, 'depthMs', 'pcm');
      const age = need(s.pcm, 'ageP50', 'pcm');
      row[e.tag] = { target, depth, age, e2e: age === null ? null : +(age + depth).toFixed(1),
                     lost: need(s.pcm, 'lostFrames', 'pcm'), spread: need(s.pcm, 'jitSpreadMaxRun', 'pcm'),
                     // The authority audit. See the LEVER AUTHORITY block below.
                     clamped: need(s.pcm, 'jitClampedTicks', 'pcm'),
                     wantMax: need(s.pcm, 'jitWantMaxRun', 'pcm'),
                     cap: need(s.pcm, 'jitMaxTarget', 'pcm'),
                     // FEC accounting for the swfec A/B: which code this side's
                     // SENDER emits, and what this side's RECEIVER repaired.
                     sw: need(s.pcm, 'swFec', 'pcm'),
                     repaired: need(s.pcm, 'fecRepaired', 'pcm'),
                     rlate: need(s.pcm, 'fecRepairedLate', 'pcm'),
                     pRecv: need(s.pcm, 'parityRecv', 'pcm'),
                     pSent: need(s.pcm, 'paritySent', 'pcm') };
      const k = st[e.tag];
      if (target > k.peakT) { k.peakT = target; k.atT = el; }
      if (depth > k.peakD) { k.peakD = depth; k.atD = el; }
      if (k.back === null && el > 1 && target <= report.baseline[e.tag].target && fired.length >= HOLES) k.back = el;
    }
    report.series.push(row);
    console.log(`  ${String(el).padStart(5)} │ ${String(row.A.target).padStart(6)}f ${String(row.A.depth).padStart(6)} ${String(row.A.e2e).padStart(6)} │ ` +
      `${String(row.B.target).padStart(6)}f ${String(row.B.depth).padStart(6)} ${String(row.B.e2e).padStart(6)}`);
    await new Promise((r) => setTimeout(r, 2000));
  }
  await inject;

  // ── did the stimulus land, on BOTH sides? ──
  for (const e of [A, B]) {
    const s = await snap(e.page);
    const stalls = need(s.pcm, 'stalls', 'pcm');
    const fresh = stalls.filter((x) => x.t >= fired[0]?.at - 1000);
    const big = fresh.filter((x) => x.g >= 0.6 * HOLE);
    if (HOLE > 0 && !big.length) {
      throw new Error(`${e.tag}: no stall >= ${(0.6 * HOLE).toFixed(0)} ms appeared after injection ` +
        `(${stalls.length} stalls total). A stimulus that does not stimulate makes an unaffected system ` +
        `and a broken instrument look identical, so this run is VOID.`);
    }
    report.sides[e.tag] = { stalls: big.length, maxStallMs: big.length ? Math.max(...big.map((x) => x.g)) : 0 };
    console.log(`\n  ${e.tag} stimulus CONFIRMED: ${big.length} stall(s), largest ${report.sides[e.tag].maxStallMs} ms`);
  }

  // ── result ──
  const out = {};
  for (const e of [A, B]) {
    const b = report.baseline[e.tag], k = st[e.tag];
    let area = 0;
    for (let i = 1; i < report.series.length; i++) {
      const p = report.series[i - 1][e.tag], q = report.series[i][e.tag];
      area += ((p.depth - b.depth) + (q.depth - b.depth)) / 2 * (report.series[i].t - report.series[i - 1].t);
    }
    const lostIn = report.series.at(-1)[e.tag].lost - b.lost;
    const fin = report.series.at(-1)[e.tag].target;
    // The same excursion integral, on END-TO-END latency rather than on buffer depth.
    // If these two areas disagree the buffer is not simply adding to transit, and the
    // depth figure alone would be the wrong thing to minimise.
    let areaE = 0;
    const e2eBase = b.ageP50 + b.depth;
    for (let i = 1; i < report.series.length; i++) {
      const p = report.series[i - 1][e.tag], q = report.series[i][e.tag];
      if (p.e2e === null || q.e2e === null) { areaE = null; break; }
      areaE += ((p.e2e - e2eBase) + (q.e2e - e2eBase)) / 2 * (report.series[i].t - report.series[i - 1].t);
    }
    const e2ePeak = report.series.reduce((m, r) => (r[e.tag].e2e ?? -1) > m ? r[e.tag].e2e : m, -1);
    out[e.tag] = { rel: e.rel, relPerSec: 4 * e.rel, baseTarget: b.target, baseDepth: b.depth,
                   peakTarget: k.peakT, peakTargetAt: k.atT, peakDepth: k.peakD, peakDepthAt: k.atD,
                   addedDepthMs: +(k.peakD - b.depth).toFixed(1), areaMsS: +area.toFixed(0),
                   recoveredAtS: k.back, finalTarget: fin, lostInWindow: lostIn,
                   baseAge: b.ageP50, baseE2E: +e2eBase.toFixed(1), peakE2E: e2ePeak,
                   addedE2EMs: +(e2ePeak - e2eBase).toFixed(1), areaE2EMsS: areaE === null ? null : +areaE.toFixed(0),
                   predictedHoldS: +(HOLE / (4 * e.rel)).toFixed(0) };
  }
  report.result = out;

  const F = (v, w = 9) => String(v).padStart(w);
  console.log(`\nRESULT${IS_NULL ? '  (NULL ARM — this is the instrument, not an effect)' : ''}\n`);
  console.log(`                             A            B`);
  console.log(`  release (ms/s)      ${F(out.A.relPerSec)}    ${F(out.B.relPerSec)}`);
  console.log(`  predicted hold (s)  ${F(out.A.predictedHoldS)}    ${F(out.B.predictedHoldS)}   [hole_ms / release_ms_per_s]`);
  console.log(`  ─────────────────────────────────────────────`);
  console.log(`  baseline depth (ms) ${F(out.A.baseDepth)}    ${F(out.B.baseDepth)}`);
  console.log(`  baseline age  (ms)  ${F(out.A.baseAge)}    ${F(out.B.baseAge)}   capture->arrival transit`);
  console.log(`  baseline e2e  (ms)  ${F(out.A.baseE2E)}    ${F(out.B.baseE2E)}   age + buffer`);
  console.log(`  peak target (f)     ${F(out.A.peakTarget)}    ${F(out.B.peakTarget)}   allowance asked for`);
  console.log(`  peak depth (ms)     ${F(out.A.peakDepth)}    ${F(out.B.peakDepth)}   latency actually carried`);
  console.log(`  added latency (ms)  ${F(out.A.addedDepthMs)}    ${F(out.B.addedDepthMs)}`);
  console.log(`  peak e2e (ms)       ${F(out.A.peakE2E)}    ${F(out.B.peakE2E)}   mouth-to-ear at its worst`);
  console.log(`  added e2e (ms)      ${F(out.A.addedE2EMs)}    ${F(out.B.addedE2EMs)}   <- the number a USER feels`);
  console.log(`  excursion, depth    ${F(out.A.areaMsS)}    ${F(out.B.areaMsS)}   ms*s of extra BUFFER`);
  console.log(`  excursion, e2e      ${F(out.A.areaE2EMsS ?? 'n/a')}    ${F(out.B.areaE2EMsS ?? 'n/a')}   ms*s of extra LATENCY <- minimise this`);
  console.log(`                      [if these two disagree, the buffer is not simply adding to transit,`);
  console.log(`                       and depth alone would be the wrong thing to tune on]`);
  console.log(`  recovered at (s)    ${F(out.A.recoveredAtS ?? 'never')}    ${F(out.B.recoveredAtS ?? 'never')}`);
  console.log(`  final target (f)    ${F(out.A.finalTarget)}    ${F(out.B.finalTarget)}`);
  console.log(`  frames concealed    ${F(out.A.lostInWindow)}    ${F(out.B.lostInWindow)}   <- the cost of releasing early`);

  // ── STEADY STATE, which is the only meaningful comparison under shaping ──────
  // With no injection the shaper IS the stimulus, so "excursion above baseline" is ~0
  // by construction and "recovered at" is meaningless — the baseline is already the
  // stressed condition. What matters is the absolute level of each: how much latency is
  // being carried, and how much audio is being concealed, over the same window. Quoted
  // over the LAST THIRD as well, because this metric ratchets and a whole-run mean hides
  // a monotone climb.
  {
    const s = report.series, third = s.slice(Math.floor((2 * s.length) / 3));
    const mean = (a, f) => (a.length ? +(a.reduce((n, r) => n + f(r), 0) / a.length).toFixed(1) : null);
    console.log(`\nSTEADY STATE${SHAPED ? ` under ${BW || '-'} Mbps / ${LOSS}% loss` : ''}  — absolute levels, not excursions\n`);
    console.log(`                             A            B`);
    for (const [label, f, note] of [
      ['mean depth (ms)', (r) => r.depth, 'buffer carried'],
      ['mean e2e (ms)', (r) => r.e2e, 'mouth-to-ear'],
    ]) {
      console.log(`  ${label.padEnd(20)}${F(mean(s, (r) => f(r.A)))}    ${F(mean(s, (r) => f(r.B)))}   ${note}`);
      console.log(`    last third        ${F(mean(third, (r) => f(r.A)))}    ${F(mean(third, (r) => f(r.B)))}`);
    }
    for (const t of ['A', 'B']) {
      const d = s.at(-1)[t].lost - s[0][t].lost;
      out[t].steadyLost = d;
      out[t].steadyMeanE2E = mean(s, (r) => r[t].e2e);
      out[t].steadyLastThirdE2E = mean(third, (r) => r[t].e2e);
    }
    const win = (s.at(-1).t - s[0].t) || 1;
    console.log(`  concealed / window  ${F(out.A.steadyLost)}    ${F(out.B.steadyLost)}   frames over ${win.toFixed(0)}s`);
    console.log(`  concealment rate    ${F((out.A.steadyLost / (125 * win) * 100).toFixed(3) + '%')}    ${F((out.B.steadyLost / (125 * win) * 100).toFixed(3) + '%')}   of a 125 fps lane`);

    // ── LEVER AUTHORITY — does the parameter under test reach the output at all? ─────
    //
    // `want = Math.min(cfg.maxTargetFrames, raw)`. When raw > cap the whole spreadHold
    // term — the ONLY thing JIT_RELEASE moves — is discarded, and want is the cap no
    // matter what the release rate is. So on a clamped tick this A/B is not an A/B: both
    // arms run the same control law and the difference printed above is the noise floor.
    //
    // This project shipped a contradiction on exactly that mistake: an n=8 at --bw=0.3
    // "found" slow release winning, and a sweep later showed the target pinned at the cap
    // for 48 of 48 samples in BOTH arms, with the two depth curves superimposable
    // (122.6 ms vs 122.7 ms at t=44). Two honest results disagreed because one of them
    // was measuring a disconnected knob. A harness that can detect that must, so that
    // the finding is a refusal and not a false winner.
    for (const t of ['A', 'B']) {
      const first = s[0][t], last = s.at(-1)[t];
      out[t].clampedTicks = last.clamped - first.clamped;
      out[t].wantMax = last.wantMax;
      out[t].cap = last.cap;
      // 250 ms per estimator tick, over the observed window.
      out[t].clampedPct = +(100 * out[t].clampedTicks / Math.max(1, win * 4)).toFixed(1);
    }
    if (UNDER_TEST === 'swfec') {
      // ── SWFEC ATTRIBUTION + AUTHORITY ────────────────────────────────────
      // pcmsw is a SENDER-side flag, so the per-side columns above must be
      // read SWAPPED: side A's sender feeds side B's receiver. Authority here
      // is not the jitter clamp (parity emission ignores it) — it is whether
      // each sender actually ran the intended code AND its parity arrived.
      const first = s[0], last = s.at(-1);
      const wantA = SWF.A ? 1 : 0, wantB = SWF.B ? 1 : 0;
      const okCfg = last.A.sw === wantA && last.B.sw === wantB;
      const d = (t, k) => last[t][k] - first[t][k];
      console.log(`\nFEC ARM ATTRIBUTION — sender-side flag, read the columns SWAPPED:`);
      for (const [tx, rx] of [['A', 'B'], ['B', 'A']]) {
        const code = SWF[tx] ? 'WINDOW' : 'RS    ';
        console.log(`  ${tx} sends ${code} → judged at ${rx}: concealed ${out[rx].steadyLost}f, ` +
          `repaired ${d(rx, 'repaired')} (+${d(rx, 'rlate')} late), parityRecv ${d(rx, 'pRecv')}, ` +
          `paritySent by ${tx} ${d(tx, 'pSent')}`);
      }
      if (!okCfg) {
        out.authority = 'none';
        console.log(`\n  *** NO AUTHORITY: page-reported swFec (A=${last.A.sw} B=${last.B.sw}) does not match ` +
          `the flags (A=${wantA} B=${wantB}). Stale build at the edge or a typo'd param — this run is void. ***`);
      } else if (d('A', 'pRecv') <= 0 || d('B', 'pRecv') <= 0) {
        out.authority = 'none';
        console.log(`\n  *** NO AUTHORITY: parity did not flow both directions ` +
          `(A recv +${d('A', 'pRecv')}, B recv +${d('B', 'pRecv')}). One arm ran unprotected; refuse the verdict. ***`);
      } else {
        out.authority = 'full';
        console.log(`\n  AUTHORITY OK: both senders ran their intended code and parity flowed both ways.`);
        console.log(`  WINDOW arm = ${SWF.A ? 'B' : 'A'}'s receiver columns; RS arm = ${SWF.A ? 'A' : 'B'}'s.`);
      }
      out.underTest = UNDER_TEST;
    } else {
    console.log(`\nLEVER AUTHORITY — could ${UNDER_TEST === 'cap' ? 'the cap' : 'the release rate'} reach the output?\n`);
    console.log(`                             A            B`);
    console.log(`  cap (frames)        ${F(out.A.cap)}    ${F(out.B.cap)}   maxTargetFrames`);
    console.log(`  want at its peak (f)${F(out.A.wantMax)}    ${F(out.B.wantMax)}   what the estimator ASKED for`);
    console.log(`  ticks clamped       ${F(out.A.clampedTicks)}    ${F(out.B.clampedTicks)}   want was cut down to the cap`);
    console.log(`  clamped %           ${F(out.A.clampedPct + '%')}    ${F(out.B.clampedPct + '%')}   of ~${Math.round(win * 4)} estimator ticks`);
    const worst = Math.max(out.A.clampedPct, out.B.clampedPct);
    const least = Math.min(out.A.clampedPct, out.B.clampedPct);
    out.clampedPctWorst = worst;
    out.underTest = UNDER_TEST;
    if (UNDER_TEST === 'cap') {
      // Inverted: the cap only binds while the estimator is asking for MORE than the cap.
      // A cap A/B on an unclamped run is the disconnected-lever mistake with the roles
      // swapped — both arms would sit below both caps and the caps would never be consulted.
      if (least >= 50) {
        out.authority = 'full';
        console.log(`\n  AUTHORITY OK: both arms clamped (${out.A.clampedPct}% / ${out.B.clampedPct}%), so each cap was`);
        console.log(`      actually binding and the depth difference below IS the cap difference.`);
      } else if (worst >= 50) {
        out.authority = 'partial';
        console.log(`\n  ASYMMETRIC: clamped ${out.A.clampedPct}% / ${out.B.clampedPct}%. Only one arm's cap bound, which is`);
        console.log(`      the expected shape when the caps straddle what the estimator wants — the LOWER cap`);
        console.log(`      binds and the higher one does not. Read the difference as "cost of the lower cap",`);
        console.log(`      not as a symmetric comparison.`);
      } else {
        out.authority = 'none';
        console.log(`\n  *** NO AUTHORITY: clamped only ${out.A.clampedPct}% / ${out.B.clampedPct}%. Neither cap bound, so this`);
        console.log(`      run compares two knobs that were never consulted. want peaked at`);
        console.log(`      ${Math.max(out.A.wantMax, out.B.wantMax)}f, under both caps (${out.A.cap}f / ${out.B.cap}f). Shape the link harder or lower the caps. ***`);
      }
    } else if (worst >= 90) {
      out.authority = 'none';
      console.log(`\n  *** NO AUTHORITY: clamped ${worst}% of ticks. The release rate was DISCONNECTED ***`);
      console.log(`      for essentially the whole run, so the A/B above is a noise-floor measurement`);
      console.log(`      and must not be read as a release-rate result in either direction. What this`);
      console.log(`      run DOES measure is the cost of the cap itself: want peaked at`);
      console.log(`      ${Math.max(out.A.wantMax, out.B.wantMax)}f against a ${out.A.cap}f cap, and depth sat at the cap. Vary --pcmjbmax`);
      console.log(`      to make this regime testable; varying the release rate cannot.`);
    } else if (worst >= 25) {
      out.authority = 'partial';
      console.log(`\n  PARTIAL AUTHORITY: clamped ${worst}% of ticks. The lever acted for the rest, so a`);
      console.log(`      difference here is real but DILUTED — the effect size understates the free case.`);
    } else {
      out.authority = 'full';
      console.log(`\n  AUTHORITY OK: clamped ${worst}% of ticks, so the estimator was free to move and`);
      console.log(`      the release rate had a path to the output for essentially the whole run.`);
    }
    } // end non-swfec authority
    if (SHAPED) {
      console.log(`\n  Under shaping packets are genuinely TAIL-DROPPED, so depth buys RS/FEC time to`);
      console.log(`  repair them. That is a different mechanism from a stall, where every packet`);
      console.log(`  arrives merely late and depth prevents nothing. Whichever arm carries less`);
      console.log(`  latency AND conceals no more has won; if they split, the trade is the finding.`);
    }
  }

  console.log(`\n  Latency is never quoted without delivery beside it: a faster release that empties`);
  console.log(`  the buffer before the next hole buys its lower excursion with concealment, and the`);
  console.log(`  concealment row is where that shows up.`);
  if (IS_NULL) {
    console.log(`\n  NULL ARM READING: the differences above are the noise floor of this comparison.`);
    console.log(`  A real effect must be larger than these, in the same direction, and repeat.`);
  }
  console.log(`\nLIMITS`);
  for (const l of ['two Chromium peers on one host: no real network, no distance, no cross-traffic',
                   'the stimulus is a main-thread block — one cause of arrival stalls, not all of them',
                   'paired within a call, so run order and host state cancel; between-CALL variance does not',
                   'n=1 call: repeat before quoting any figure to the digit',
                   ...report.limits]) console.log(`  - ${l}`);
} finally {
  // THE SHAPER'S OWN COUNTERS, from the proxy rather than from the browser. `bwDropped`
  // vs `dropped` separates "the bandwidth ceiling tail-dropped this" from "the loss dice
  // dropped this", which is the whole distinction this run exists to make. Reading them
  // here also means they survive a run that throws.
  if (sim) {
    try {
      const st = sim.stats;
      report.shaper = st;
      console.log(`\nSHAPER COUNTERS  sent ${st.sent}  bwDropped ${st.bwDropped}  lossDropped ${st.dropped}  ` +
        `bytes ${(st.bytes / 1e6).toFixed(2)} MB  errors ${st.sendErrors}`);
      console.log(`  [bwDropped is the ceiling tail-dropping; dropped is the loss dice. This project has`);
      console.log(`   read bwDropped 0 for two OPPOSITE conditions — never bound, and bound hard — so a`);
      console.log(`   zero here is not evidence either way without the byte count beside it.]`);
    } catch (e) { console.log(`  shaper counters unavailable: ${e.message}`); }
  }
  // Load at the END too. The start gate only proves the host was quiet when the run
  // began; something that arrived at t+60s is invisible to it. Recorded rather than
  // acted on, so the scorer can check whether the loaded runs are the odd ones out.
  report.meta.hostLoadEnd = +(os.loadavg()[0] / os.cpus().length).toFixed(3);
  if (JSON_OUT) { fs.writeFileSync(JSON_OUT, JSON.stringify(report, null, 2)); console.log(`\n  json -> ${JSON_OUT}`); }
  for (const e of [A, B]) { try { await e.ctx.close(); } catch {} }
  // Without this the UDP proxies keep the event loop alive and node NEVER EXITS. A piped
  // run then buffers its entire output forever and reads as a hung 20-minute test that
  // had in fact already finished.
  if (sim) { try { await sim.stop(); } catch {} }
}
