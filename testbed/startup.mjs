/**
 * DOES THE FIRST TEN SECONDS OF A CALL SIZE THE WHOLE CALL'S AUDIO BUFFER?
 *
 * ─── WHY THIS RUN EXISTS ──────────────────────────────────────────────────────
 * Two separate results pointed the same way without either being about startup:
 *
 *   - the `--bw=0.3` paired run concealed 4.19% at settle and then ~zero for 138 s,
 *     because video's congestion control backed off and freed the link. The damage
 *     was done in the first seconds and the buffer never came back down.
 *   - the first valid run of the 5%-loss n=8 began with `baseTarget: 15` on BOTH
 *     sides — the `maxTargetFrames` ceiling already bound at settle — and what
 *     differed by the end was only the DESCENT (finalTarget 13 slow vs 11 fast).
 *
 * So the release rate may not be the defect at all. pcm.js:1395 says the estimator
 * must not learn from a call's opening because "ICE is still settling" — but its
 * guard is `dN < 64`, which at FRAME_MS=8 is 512 ms. Six SCTP associations do not
 * finish settling in 512 ms. Whatever arrival spread the handshake leaves behind is
 * latched by `spreadHold` and then released at 1 ms/s, i.e. one second per
 * millisecond of spread. A 100 ms opening transient holds the buffer up for 100 s.
 *
 * ─── WHY IT NEEDS NO NEW INSTRUMENT ───────────────────────────────────────────
 * pcm.js ALREADY publishes exactly this, and even says how to read it:
 *
 *     jitSpreadMaxAtMs, jitWarmMs, jitSpreadMaxLate, jitSpreadMaxLateAtMs
 *     "Read these TOGETHER with jitSpreadMaxRun. maxAt near 0 with maxLate far
 *      below the max means a startup transient sized the whole call's buffer."
 *
 * and marks them "OBSERVABILITY ONLY -- the control law does not read these."
 * The instrument was built and the reading was never taken. This takes it.
 *
 * ─── WHAT MAKES IT A MEASUREMENT AND NOT A LOOK ───────────────────────────────
 *   - BOTH SIDES RUN STOCK. There is no A/B here; the two ends are two independent
 *     observations of one call, which is the strongest form this question has.
 *   - SAMPLING STARTS AT JOIN, and the health gates run at the END. Every other rig
 *     here gates its baseline before measuring, which is right when the baseline is
 *     a reference — but here the opening IS the subject, so gating on a settled call
 *     first would discard the evidence. A run whose call turns out to have been
 *     broken is voided retroactively instead.
 *   - THE PAGE'S RUNNING MAX IS CHECKED AGAINST THIS HARNESS'S OWN. `jitSpreadMaxRun`
 *     is a running max and should dominate anything sampled from outside; if a sample
 *     ever EXCEEDS it, the published max is broken and no verdict may be drawn from
 *     it. (This project has already had a published estimator max read 12.9 ms on a
 *     run whose true worst was 169.7.) The check is deliberately one-directional:
 *     sampling at 500 ms sees only half the estimator's 250 ms ticks, so observing
 *     LESS than the page is expected and means nothing.
 *
 *   node testbed/startup.mjs [--secs=120] [--loss=0] [--bw=0] [--json=PATH]
 */
import { chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';
import { startP2PSim } from '/Users/earningsgpt/video calling/testbed/netsim.mjs';
import os from 'node:os';
import fs from 'node:fs';

const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const CAM = '/Users/earningsgpt/video calling/testbed/media/cam1080.mjpeg';
const AUD = '/Users/earningsgpt/video calling/testbed/media/conv/A.wav';

// Unknown flags are FATAL. `--secs=` once silently failed to match `--sec=` here and
// every run quietly took the default while the log claimed otherwise.
const KNOWN = new Set(['secs', 'loss', 'bw', 'rtt', 'jitter', 'query', 'base', 'json', 'every']);
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
const SECS = Number(arg('secs', 120));
const EVERY = Number(arg('every', 500));   // ms between samples
const LOSS = Number(arg('loss', 0));
const BW = Number(arg('bw', 0));
const RTT = Number(arg('rtt', 0));
const JIT = Number(arg('jitter', 0));
const QUERY = arg('query', 'tape=2');
const BASE = arg('base', 'https://room.tokkah.com');
const JSON_OUT = arg('json', null);
const SHAPED = BW > 0 || LOSS > 0 || RTT > 0 || JIT > 0;
for (const [k, v, min] of [['secs', SECS, 30], ['every', EVERY, 100]]) {
  if (!Number.isFinite(v) || v < min) { console.error(`--${k} must be a number >= ${min}`); process.exit(2); }
}

function need(o, k, where) {
  if (o == null) throw new Error(`${where}: object is ${o}, cannot read "${k}"`);
  if (o[k] === undefined) throw new Error(`${where}: field "${k}" does not exist. Available: ${Object.keys(o).slice(0, 40).join(', ')}`);
  return o[k];
}

// Lifted verbatim from relpair.mjs / call.mjs. Rewrites every ICE candidate, trickled
// AND embedded in SDP, so the media path actually crosses the shaper.
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
    constructor(...a) {
      super(...a);
      const origAdd = this.addIceCandidate.bind(this);
      this.addIceCandidate = async (c) => {
        if (c && c.candidate) {
          const nl = await rewrite(c.candidate);
          if (nl) c = { ...c.toJSON ? c.toJSON() : c, candidate: nl };
        }
        return origAdd(c);
      };
    }
    async setRemoteDescription(desc) {
      if (desc && desc.sdp) {
        const lines = String(desc.sdp).split(/\\r?\\n/);
        for (let i = 0; i < lines.length; i++) {
          const m = /^a=candidate:(.*)$/.exec(lines[i]);
          if (m) { const nl = await rewrite(m[1]); if (nl) lines[i] = 'a=candidate:' + nl; }
        }
        desc = { type: desc.type, sdp: lines.join('\\r\\n') };
      }
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
  return { ctx, page, tag };
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

const room = 'sta' + Math.random().toString(36).slice(2, 7);
const report = {
  meta: { room, secs: SECS, everyMs: EVERY, query: QUERY, base: BASE, at: new Date().toISOString(),
          shaped: SHAPED, bwMbps: BW, lossPct: LOSS, rttMs: RTT, jitterMs: JIT,
          host: `${os.cpus().length} cores, ${os.platform()} ${os.release()}` },
  series: { A: [], B: [] }, sides: {}, calibration: {}, verdict: {}, limits: [],
};

console.log(`\n${'━'.repeat(80)}`);
console.log(`STARTUP TRANSIENT  room=${room}  ${SECS}s  sample every ${EVERY}ms  ` +
  `${SHAPED ? `${BW || '-'} Mbps / ${LOSS}% loss` : 'clean'}`);
console.log('━'.repeat(80));
console.log(`  Both sides run STOCK. No A/B, no injected stimulus — the question is what the`);
console.log(`  estimator learns from the call's own opening, so the opening must not be disturbed.\n`);

{
  const cores = os.cpus().length;
  const load = () => os.loadavg()[0] / cores;
  const CEIL = 0.7, WAIT_MAX_S = 240, POLL_S = 5;
  const t0 = Date.now();
  let l = load();
  if (l > CEIL) {
    console.log(`  host load ${(100 * l).toFixed(0)}% — waiting to settle below ${100 * CEIL}%`);
    while (l > CEIL && (Date.now() - t0) / 1000 < WAIT_MAX_S) {
      await new Promise((r) => setTimeout(r, POLL_S * 1000));
      l = load();
    }
  }
  const waitedS = Math.round((Date.now() - t0) / 1000);
  report.meta.hostLoadStart = +l.toFixed(3);
  report.meta.hostLoadWaitedS = waitedS;
  if (l > CEIL) {
    console.error(`  ABORT: host still at ${(100 * l).toFixed(0)}% after ${waitedS}s of waiting`);
    process.exit(3);
  }
  console.log(`  host load ${(100 * l).toFixed(0)}% of ${cores} cores${waitedS >= POLL_S ? ` (settled after ${waitedS}s)` : ''}`);
}

const sim = SHAPED
  ? await startP2PSim({ oneWayMs: RTT / 2, jitterMs: JIT, lossPct: LOSS, bwMbps: BW, seed: 7 })
  : null;
console.log(`  ${SHAPED ? `SHAPED: ${BW || '-'} Mbps, ${LOSS}% loss, ${RTT} ms RTT, ${JIT} ms jitter` : 'UNSHAPED loopback'}`);

const A = await mk('A', sim), B = await mk('B', sim);
try {
  for (const e of [A, B]) {
    await e.page.goto(`${BASE}/?r=${room}&${QUERY}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await e.page.waitForSelector('#join', { timeout: 30000 });
  }
  await A.page.click('#join');
  await A.page.waitForTimeout(700);
  await B.page.click('#join');

  // ── SAMPLE FROM JOIN. Not from "connected": the frames that arrive while the lane
  // is still coming up are precisely the ones under suspicion, and waiting for a
  // settled call would throw them away. `t0` is the instant both sides were told to
  // join, so every timestamp below is measured from the same origin on both sides.
  const t0 = Date.now();
  const deadline = t0 + SECS * 1000;
  let connectedAt = null;
  // WHICH SAMPLED FIELDS ARE ACTUALLY LIVE, because sampling at 500 ms does not make a
  // 1 Hz field 2 Hz and reading the trajectory as though it did would invent detail:
  //   LIVE      `spread`/`hold`/`spreadMax*` (estimator's own 250 ms tick, main thread)
  //             `target` (Atomics.load of SAB_TARGET)
  //   ~1 Hz     `depth`, `recv`, `lost` — pushed by the worklet's stats tick, so
  //             consecutive samples repeat and nothing finer than a second is visible.
  // The verdict below rests only on the live fields.
  console.log(`\n  sampling ${SECS}s from join  (spread/target live; depth/recv/lost are ~1 Hz)\n`);
  console.log(`      t(s)  ┃ A: tgt depth spread  hold  ┃ B: tgt depth spread  hold  ┃ status`);

  while (Date.now() < deadline) {
    const el = (Date.now() - t0) / 1000;
    const [sa, sb] = await Promise.all([snap(A.page), snap(B.page)]);
    if (connectedAt === null && sa.status === 'connected' && sb.status === 'connected') connectedAt = el;
    for (const [e, s] of [[A, sa], [B, sb]]) {
      if (!s.pcm) continue;
      report.series[e.tag].push({
        t: +el.toFixed(2),
        target: s.pcm.targetFrames ?? null,
        depth: s.pcm.depthMs ?? null,
        spread: s.pcm.jitSpreadMs ?? null,
        hold: s.pcm.jitHoldMaxRun ?? null,
        spreadMax: s.pcm.jitSpreadMaxRun ?? null,
        spreadMaxAt: s.pcm.jitSpreadMaxAtMs ?? null,
        spreadMaxLate: s.pcm.jitSpreadMaxLate ?? null,
        clamped: s.pcm.jitClampedTicks ?? null,
        recv: s.pcm.framesRecv ?? null,
        lost: s.pcm.lostFrames ?? null,
        jitN: s.pcm.jitN ?? null,
      });
    }
    const f = (s) => (s.pcm
      ? `${String(s.pcm.targetFrames ?? '-').padStart(3)} ${String(s.pcm.depthMs ?? '-').padStart(5)} ` +
        `${String(s.pcm.jitSpreadMs ?? '-').padStart(6)} ${String(s.pcm.jitHoldMaxRun ?? '-').padStart(5)}`
      : '   (lane not up)      ');
    // One line per second at most, so a 120 s run stays readable while the SERIES
    // keeps every sample.
    if (Math.abs(el - Math.round(el)) < EVERY / 2000) {
      console.log(`    ${el.toFixed(1).padStart(6)}  ┃ ${f(sa)}  ┃ ${f(sb)}  ┃ ${sa.status ?? '-'}/${sb.status ?? '-'}`);
    }
    await A.page.waitForTimeout(EVERY);
  }
  report.meta.connectedAtS = connectedAt;

  // ── HEALTH, CHECKED AFTERWARDS ────────────────────────────────────────────────
  // Deliberately last. If the call was broken the run is void and no verdict is
  // printed, but the gates must not be allowed to discard the opening they would
  // have had to skip past in order to run.
  console.log(`\nHEALTH (checked after the fact — the opening is the subject, not a precondition)\n`);
  for (const e of [A, B]) {
    const L = await schedLag(e.page);
    report.calibration[e.tag] = L;
    console.log(`  ${e.tag} scheduler lateness p50 ${L.p50} p95 ${L.p95} max ${L.max} ms -> ${L.p95 < 20 ? 'TRUSTED' : 'UNTRUSTED'}`);
    if (L.p95 >= 20) throw new Error(`${e.tag}: scheduler p95 ${L.p95} ms — arrival "spread" here would be this laptop, and this run is entirely about arrival spread`);

    const s = await snap(e.page);
    if (!s.hasTape) throw new Error(`${e.tag}: window.__tape absent`);
    if (!s.pcm) throw new Error(`${e.tag}: PCM lane never came up — nothing was measured`);
    const recv = need(s.pcm, 'framesRecv', 'pcm'), lost = need(s.pcm, 'lostFrames', 'pcm');
    const depth = need(s.pcm, 'depthMs', 'pcm');
    if (!(depth > 0)) throw new Error(`${e.tag}: final depthMs ${depth} — the playhead ran ahead of the lane, so every depth above is describing a broken call`);
    if (recv < 1000) throw new Error(`${e.tag}: only ${recv} frames received in ${SECS}s — the lane never reached rate`);
    const cf = lost / Math.max(1, recv);
    if (!SHAPED && cf > 0.005) throw new Error(`${e.tag}: concealment ${(100 * cf).toFixed(2)}% on an UNSHAPED link — this call was unhealthy for reasons other than its opening`);
    if (SHAPED && cf < 0.001) throw new Error(`${e.tag}: concealment only ${(100 * cf).toFixed(3)}% under ${BW} Mbps / ${LOSS}% — the shaper never bound, so this is secretly the clean case`);

    // Every field the verdict rests on, read to THROW. An `?? '-'` here once hid an
    // absent concealment field for an entire 400 s live run.
    report.sides[e.tag] = {
      spreadMaxRun: need(s.pcm, 'jitSpreadMaxRun', 'pcm'),
      spreadMaxAtMs: need(s.pcm, 'jitSpreadMaxAtMs', 'pcm'),
      spreadMaxLate: need(s.pcm, 'jitSpreadMaxLate', 'pcm'),
      spreadMaxLateAtMs: need(s.pcm, 'jitSpreadMaxLateAtMs', 'pcm'),
      warmMs: need(s.pcm, 'jitWarmMs', 'pcm'),
      holdMaxRun: need(s.pcm, 'jitHoldMaxRun', 'pcm'),
      wantMaxRun: need(s.pcm, 'jitWantMaxRun', 'pcm'),
      clampedTicks: need(s.pcm, 'jitClampedTicks', 'pcm'),
      maxTarget: need(s.pcm, 'jitMaxTarget', 'pcm'),
      jitRelease: need(s.pcm, 'jitRelease', 'pcm'),
      finalTarget: need(s.pcm, 'targetFrames', 'pcm'),
      finalDepth: depth, recv, lost, concealPct: +(100 * cf).toFixed(3),
      gapP95: s.pcm.gapP95 ?? null, gapMaxRun: s.pcm.gapMaxRun ?? null,
    };
    console.log(`  ${e.tag} final  target ${report.sides[e.tag].finalTarget}f  depth ${depth} ms  ` +
      `conceal ${(100 * cf).toFixed(3)}% (${lost}/${recv})  PASS`);
  }

  // ── INSTRUMENT THE INSTRUMENT ────────────────────────────────────────────────
  // `jitSpreadMaxRun` is a running max updated on every 250 ms tick, so it must
  // dominate anything this harness sampled from outside at 500 ms. The reverse would
  // mean the published max is not tracking what it claims to track, and every verdict
  // below would be resting on it.
  console.log(`\nINSTRUMENT CHECK — is the page's own running max trustworthy?\n`);
  for (const e of [A, B]) {
    const ser = report.series[e.tag];
    const obs = ser.map((x) => x.spread).filter((x) => typeof x === 'number');
    const mine = obs.length ? Math.max(...obs) : null;
    const theirs = report.sides[e.tag].spreadMaxRun;
    report.sides[e.tag].harnessObservedMaxSpread = mine;
    if (mine === null) throw new Error(`${e.tag}: not one sample carried jitSpreadMs across ${ser.length} samples — the field this run is about was never populated`);
    console.log(`  ${e.tag} harness saw max spread ${mine} ms over ${obs.length} samples; page publishes ${theirs} ms`);
    if (mine > theirs + 0.6) {
      throw new Error(`${e.tag}: this harness observed ${mine} ms of spread but the page's running max is only ${theirs} ms. ` +
        `A running max cannot be below a value that was live when sampled, so jitSpreadMaxRun is BROKEN and no ` +
        `conclusion about startup may be drawn from it. (One published estimator max here already read 12.9 ms on a run whose true worst was 169.7.)`);
    }
    console.log(`    consistent. (Sampling at ${EVERY}ms sees under half the 250ms ticks, so seeing LESS is expected and means nothing.)`);
  }

  // ── THE VERDICT ──────────────────────────────────────────────────────────────
  console.log(`\nWAS THE WHOLE CALL SIZED BY ITS OPENING?\n`);
  const REL_MS_PER_S = 1; // shipped JIT_RELEASE = 0.25/tick x 4 ticks/s
  for (const e of [A, B]) {
    const d = report.sides[e.tag];
    // `jitSpreadMaxAtMs` starts null and is only written once the estimator has run a
    // tick (dN >= 64, i.e. 512 ms of arrivals). Null therefore means the estimator
    // NEVER EVALUATED, which is not a verdict of "no transient" — it is a void run,
    // and it must say so rather than falling through to a tidy negative answer.
    if (d.spreadMaxAtMs === null) {
      throw new Error(`${e.tag}: jitSpreadMaxAtMs is null after ${SECS}s, so the estimator never completed a single ` +
        `evaluation and there is no transient to find either way. This is a void run, not a negative result.`);
    }
    const inWarm = d.spreadMaxAtMs < d.warmMs;
    const lateRatio = d.spreadMaxRun > 0 ? d.spreadMaxLate / d.spreadMaxRun : null;
    // Hold time in SECONDS is numerically the spread in MILLISECONDS, because the
    // release is 1 ms of spread per second. No factor of 1000 anywhere — a rig here
    // once divided by 1000 and printed "kept for 0 s" for a 60 s hold.
    const holdS = d.spreadMaxRun / REL_MS_PER_S;
    const verdict = inWarm && lateRatio !== null && lateRatio < 0.5;
    report.verdict[e.tag] = { inWarm, lateRatio: lateRatio === null ? null : +lateRatio.toFixed(3),
                              impliedHoldS: +holdS.toFixed(0), startupSized: verdict };
    // THE BOUNDARY IS INHERITED, NOT MEASURED, and it mislabels one known regime. `warmMs`
    // is pcm.js's JIT_WARM = 10 s. At --bw=0.3 the link needs ~25 s to settle (video's
    // congestion control backs off and frees it), so the peak lands at t+15s — the first
    // 13% of a 120 s call, plainly an opening transient — and a 10 s boundary still calls
    // it "late". So the peak's position in the CALL is printed beside its position relative
    // to the boundary, and the boolean verdict below is read as "inside JIT_WARM", not as
    // "not an opening transient".
    const pctOfCall = (100 * d.spreadMaxAtMs) / (SECS * 1000);
    console.log(`  ${e.tag}  peak spread ${d.spreadMaxRun} ms at t+${(d.spreadMaxAtMs / 1000).toFixed(1)}s` +
      `   (${pctOfCall.toFixed(0)}% into the call; warm boundary ${d.warmMs / 1000}s, which is` +
      ` pcm.js's constant and not a measured settling time)`);
    console.log(`      worst AFTER the warm boundary: ${d.spreadMaxLate} ms` +
      `${d.spreadMaxLateAtMs === null ? ' (never)' : ` at t+${(d.spreadMaxLateAtMs / 1000).toFixed(1)}s`}` +
      `${lateRatio === null ? '' : `  = ${(100 * lateRatio).toFixed(0)}% of the peak`}`);
    // Both hold times, not just a ratio. Hold in SECONDS is numerically the spread in
    // MILLISECONDS at 1 ms/s, so these are the two directly comparable physical numbers:
    // "the opening would hold the buffer up for X s, everything after it for Y s". A bare
    // ratio hides that a 45 ms late peak is still 45 s of held latency all by itself.
    const holdLateS = d.spreadMaxLate / REL_MS_PER_S;
    report.verdict[e.tag].impliedHoldFromLateS = +holdLateS.toFixed(0);
    console.log(`      implied hold: ~${holdS.toFixed(0)}s from the opening peak, ` +
      `~${holdLateS.toFixed(0)}s from everything after it (hold seconds = spread ms at ${REL_MS_PER_S} ms/s)`);
    console.log(`      ceiling: want peaked at ${d.wantMaxRun}f against a ${d.maxTarget}f cap, clamped on ${d.clampedTicks} ticks`);
    console.log(`      -> ${verdict
      ? 'STARTUP-SIZED: the peak is inside the opening and nothing later comes close.'
      : inWarm ? 'peak is in the opening, but LATER spread is comparable — the link is genuinely this variable.'
               : 'NOT startup-sized: the worst spread happened after the opening.'}`);
  }
  const both = ['A', 'B'].every((t) => report.verdict[t].startupSized);
  const neither = ['A', 'B'].every((t) => !report.verdict[t].startupSized);
  console.log(`\n  ${both ? 'BOTH sides agree the opening sized the call.'
    : neither ? 'NEITHER side is startup-sized.'
    : 'THE TWO SIDES DISAGREE — one call cannot settle this; treat as inconclusive and repeat.'}`);
  if (both) {
    console.log(`  Which makes the release rate the wrong lever to argue about: it governs how fast a`);
    console.log(`  measurement taken during the handshake is forgotten, when the real fault is that the`);
    console.log(`  handshake was measured at all. pcm.js:1398 guards this with dN<64 = 512 ms.`);
  }
} finally {
  if (sim) {
    try {
      const st = sim.stats;
      report.shaper = st;
      console.log(`\nSHAPER  sent ${st.sent}  bwDropped ${st.bwDropped}  lossDropped ${st.dropped}  bytes ${(st.bytes / 1e6).toFixed(2)} MB`);
    } catch (e) { console.log(`  shaper counters unavailable: ${e.message}`); }
  }
  report.meta.hostLoadEnd = +(os.loadavg()[0] / os.cpus().length).toFixed(3);
  if (JSON_OUT) { fs.writeFileSync(JSON_OUT, JSON.stringify(report, null, 2)); console.log(`\n  json -> ${JSON_OUT}`); }
  for (const e of [A, B]) { try { await e.ctx.close(); } catch {} }
  // Without this the UDP proxies keep the event loop alive and node NEVER EXITS.
  if (sim) { try { await sim.stop(); } catch {} }
}
