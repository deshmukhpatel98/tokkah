/**
 * Browser reproduction of the negative-depth PCM lane, against real production.
 *
 * MECHANISM UNDER TEST: the playout ring is 64 frames (512 ms). The main-thread
 * writer gates on `lo = max(startSeq, playSeqNow())`, and playSeqNow() is 0
 * until the playout worklet's first process() call. So while the audio graph is
 * still coming up, the ring accepts startSeq..startSeq+63 and rejects every
 * later frame as farFuture. If the graph takes longer than ~1 s to come up, the
 * live stream is permanently outside the accept window and the playhead, seeded
 * at startSeq, conceals for the rest of the call.
 *
 * THE KNOB: D, the delay between the first arriving PCM frame and the playout
 * worklet running. Injected WITHOUT touching app code, by delaying only peer B's
 * fetch of /pcm-worklet.js — which is exactly what `await addModule()` waits on.
 *
 * The instrument is checked: D is MEASURED from the page (framesRecv>0 -> started),
 * never assumed from the injected value, and an arm whose measured D did not move
 * is reported as a failed injection rather than as a result.
 *
 * MEASURED (room.tokkah.com, 10-core mac, host under 50%):
 *   measured D  -0.095s -> depth   +20.0 ms, lost    1, 0/1164 samples negative
 *   measured D   0.291s -> depth   +33.9 ms, lost    0, 0/1149 samples negative
 *   measured D   0.865s -> depth   +41.5 ms, lost   48, 0/926  samples negative
 *   measured D   1.173s -> depth -22927.4 ms, lost 2866, 915/915 samples negative
 *   measured D   1.408s -> depth -22887.4 ms, lost 2861, 905/905 samples negative
 *   measured D   2.904s -> depth -26911.4 ms, lost 3364, 1043/1043 negative
 * framesRecv was 125.0-125.1 fps and lateFrames 0 in EVERY arm, including the dead
 * ones — delivery is untouched, which is why no transport counter shows this.
 * The 1.173s arm reproduces the filed observation (-22935.4 ms, 2867 frames, target
 * 2) to within one frame. The cliff brackets the closed-form 1.008 s in
 * testbed/pcm-origin.mjs.
 *
 * NOTE ON THE CONTROL ARM: measured D was -0.095 s — the audio graph wins the race
 * by 95 ms on an unloaded laptop with a warm cache. The whole margin against this
 * defect is that 95 ms plus the 1.008 s window.
 *
 * Usage: node pcm-graphdelay.mjs [--delays=0,3] [--secs=30] [--base=URL] [--query=tape=2]
 * See also: testbed/pcm-origin.mjs, the deterministic model and the layer question.
 */
import { chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';
import os from 'node:os';

const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const CAM = '/Users/earningsgpt/video calling/testbed/media/cam1080.mjpeg';
const AUD = '/Users/earningsgpt/video calling/testbed/media/conv/A.wav';

const KNOWN = new Set(['delays', 'secs', 'base', 'query']);
for (const a of process.argv.slice(2)) {
  const m = /^--([^=]+)=/.exec(a);
  if (!m || !KNOWN.has(m[1])) { console.error(`unknown flag: ${a}\nknown: ${[...KNOWN].map((k) => '--' + k + '=').join(' ')}`); process.exit(2); }
}
const arg = (k, d) => { const m = process.argv.find((a) => a.startsWith(`--${k}=`)); return m ? m.slice(k.length + 3) : d; };
const DELAYS = arg('delays', '0,3').split(',').map(Number);
const SECS = Number(arg('secs', 30));
const BASE = arg('base', 'https://room.tokkah.com');
const QUERY = arg('query', 'tape=2');
if (!DELAYS.every(Number.isFinite) || !Number.isFinite(SECS)) { console.error('--delays and --secs must be numbers'); process.exit(2); }

function need(o, k, where) {
  if (o == null) throw new Error(`${where}: object is ${o}, cannot read "${k}"`);
  if (o[k] === undefined) throw new Error(`${where}: field "${k}" does not exist. Available: ${Object.keys(o).join(', ')}`);
  return o[k];
}

const mk = async () => {
  const ctx = await chromium.launchPersistentContext('', {
    executablePath: CHROME, headless: true,
    args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
      `--use-file-for-fake-video-capture=${CAM}`, `--use-file-for-fake-audio-capture=${AUD}`,
      '--autoplay-policy=no-user-gesture-required'],
    viewport: { width: 1000, height: 700 },
  });
  return { ctx, page: await ctx.newPage() };
};

// D is measured at the ONE place it is defined: when `await addModule()` resolves,
// which is what the audio-graph IIFE blocks on before the playout node exists.
// The SAME patch injects the delay — page.route() does NOT intercept an AudioWorklet
// module fetch (measured: an injected 3 s moved measured D by 0 ms), so the delay has
// to live where the await does.
//
// `started`/`depthMs` reach the page only on the worklet's ~1 s stats push, so they
// cannot time D to better than a second. framesRecv is a main-thread counter read
// through a live getter, so it is good to the poll interval.
const installProbe = (p, D) => p.addInitScript((delayS) => {
  window.__gdMod = [];
  const orig = AudioWorklet.prototype.addModule;
  AudioWorklet.prototype.addModule = async function (url, ...rest) {
    const t0 = performance.now();
    if (delayS > 0 && String(url).includes('pcm-worklet.js')) {
      await new Promise((r) => setTimeout(r, delayS * 1000));
    }
    const out = await orig.call(this, url, ...rest);
    window.__gdMod.push({ url: String(url), t0, t1: performance.now() });
    return out;
  };
}, D);

// In-page poller: the ONLY way to see when the ring started taking frames and when
// the playhead started, since neither instant is logged and farFuture is not exposed.
const startPoller = (p) => p.evaluate(() => {
  window.__gd = { rows: [], t0: performance.now() };
  window.__gdTimer = setInterval(() => {
    const s = window.__tape?.pcm;
    if (!s) return;
    window.__gd.rows.push({
      t: +((performance.now() - window.__gd.t0) / 1000).toFixed(3),
      framesRecv: s.framesRecv ?? null,
      started: s.started ?? null,
      depthMs: s.depthMs ?? null,
      lostFrames: s.lostFrames ?? null,
      playedFrames: s.playedFrames ?? null,
      targetFrames: s.targetFrames ?? null,
    });
  }, 25);
});

const readPoller = (p) => p.evaluate(() => {
  clearInterval(window.__gdTimer);
  return {
    rows: window.__gd?.rows ?? [],
    pcm: window.__tape?.pcm ?? null,
    mods: (window.__gdMod ?? []).map((m) => ({ url: m.url, t0: m.t0, t1: m.t1 })),
    pollT0: window.__gd?.t0 ?? null,
  };
});

async function arm(D) {
  const room = 'gd' + Math.random().toString(36).slice(2, 7);
  const url = `${BASE}/?r=${room}&${QUERY}`;
  const A = await mk(), B = await mk();
  try {
    // Delay ONLY B's playout/capture worklet module — this is precisely what the
    // audio-graph IIFE awaits, so it moves D and nothing else.
    await installProbe(B.page, D);
    for (const e of [A, B]) {
      await e.page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
      await e.page.waitForSelector('#join', { timeout: 30000 });
    }
    await A.page.click('#join');
    await A.page.waitForTimeout(700);
    await startPoller(B.page);
    await B.page.click('#join');
    for (const e of [A, B]) {
      await e.page.waitForFunction(() => document.querySelector('#status')?.textContent === 'connected', null, { timeout: 40000 });
    }
    await B.page.waitForTimeout(SECS * 1000);
    const { rows, pcm, mods, pollT0 } = await readPoller(B.page);
    if (!pcm) throw new Error('B: PCM lane not running');
    const firstRecv = rows.find((r) => r.framesRecv > 0);
    const firstStart = rows.find((r) => r.started === true);
    // Coarse (±1 s, the worklet stats push) — kept only as a cross-check.
    const coarseD = firstRecv && firstStart ? +(firstStart.t - firstRecv.t).toFixed(3) : null;
    // Precise: addModule resolve is when the graph can first exist. Both timestamps
    // are performance.now() on the same page, so they subtract cleanly.
    const wm = mods.find((m) => m.url.includes('pcm-worklet.js'));
    if (!wm) throw new Error('B: addModule probe never fired for pcm-worklet.js — the probe did not install');
    const tGraph = pollT0 === null ? null : +((wm.t1 - pollT0) / 1000).toFixed(3);
    const measuredD = tGraph !== null && firstRecv ? +(tGraph - firstRecv.t).toFixed(3) : null;
    const addModuleMs = +(wm.t1 - wm.t0).toFixed(1);
    // Delivery health: full rate is 125 fps. If this is low, the arm measured a
    // broken transport, not a playhead origin.
    const span = rows.length ? rows[rows.length - 1].t - (firstRecv?.t ?? 0) : 0;
    const fps = span > 1 ? +((need(pcm, 'framesRecv', 'pcm') - (firstRecv?.framesRecv ?? 0)) / span).toFixed(1) : null;
    return {
      D, room, measuredD, coarseD, addModuleMs, tGraph,
      tFirstRecv: firstRecv?.t ?? null,
      tStarted: firstStart?.t ?? null,
      depthMs: need(pcm, 'depthMs', 'pcm'),
      lostFrames: need(pcm, 'lostFrames', 'pcm'),
      playedFrames: need(pcm, 'playedFrames', 'pcm'),
      framesRecv: need(pcm, 'framesRecv', 'pcm'),
      targetFrames: need(pcm, 'targetFrames', 'pcm'),
      overflowSkips: need(pcm, 'overflowSkips', 'pcm'),
      lateFrames: need(pcm, 'lateFrames', 'pcm'),
      fps,
      negSamples: rows.filter((r) => r.depthMs !== null && r.depthMs < 0).length,
      depthSamples: rows.filter((r) => r.depthMs !== null).length,
      firstNegAt: rows.find((r) => r.depthMs !== null && r.depthMs < 0)?.t ?? null,
      rows,
    };
  } finally {
    await A.ctx.close().catch(() => {});
    await B.ctx.close().catch(() => {});
  }
}

const load = os.loadavg()[0] / os.cpus().length;
console.log(`\n${'━'.repeat(78)}\nPCM GRAPH DELAY  base=${BASE}  query=${QUERY}  ${SECS}s per arm\n${'━'.repeat(78)}`);
console.log(`  host load ${(100 * load).toFixed(0)}% of ${os.cpus().length} cores`);
if (load > 0.7) { console.error(`  ABORT: host at ${(100 * load).toFixed(0)}% — startup timing here would be this laptop`); process.exit(3); }

const out = [];
for (const D of DELAYS) {
  process.stdout.write(`\n  arm D=${D}s ... `);
  const r = await arm(D);
  out.push(r);
  console.log(`done (room ${r.room})`);
  console.log(`    measured D (firstRecv -> addModule resolved)  ${r.measuredD} s   [injected ${r.D} s]`);
  console.log(`    addModule('/pcm-worklet.js') took ${r.addModuleMs} ms, resolved at t+${r.tGraph}s; coarse D (±1s) ${r.coarseD} s`);
  console.log(`    depthMs ${r.depthMs}   lostFrames ${r.lostFrames}   played ${r.playedFrames}   target ${r.targetFrames}   ovfSkips ${r.overflowSkips}`);
  console.log(`    framesRecv ${r.framesRecv} at ${r.fps} fps   lateFrames ${r.lateFrames}`);
  console.log(`    negative-depth samples ${r.negSamples}/${r.depthSamples}` + (r.firstNegAt !== null ? `, first at t+${r.firstNegAt}s` : ''));
  if (D > 0 && r.measuredD !== null && r.measuredD < D * 0.5) {
    console.log(`    !! INJECTION FAILED: asked for ${D}s, measured ${r.measuredD}s — route did not delay addModule. Result is not evidence.`);
  }
}

console.log(`\n${'─'.repeat(78)}\n  SUMMARY\n${'─'.repeat(78)}`);
console.log('  ' + ['D', 'measD', 'depthMs', 'lost', 'played', 'recv', 'fps', 'neg/tot'].map((h) => h.padStart(9)).join(''));
for (const r of out) {
  console.log('  ' + [`${r.D}s`, `${r.measuredD}s`, r.depthMs, r.lostFrames, r.playedFrames, r.framesRecv, r.fps, `${r.negSamples}/${r.depthSamples}`]
    .map((v) => String(v).padStart(9)).join(''));
}
console.log('');
