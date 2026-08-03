/**
 * The turn-gap proxy, over time, through a bad patch and out the other side.
 *
 * FATIGUE.md adopts this operational definition: fatigue risk is how much the
 * app adds to the natural turn-taking gap, measured as 2 x one-way mouth-to-ear,
 * and — the part that matters — HOW MUCH THAT FIGURE MOVES during a call.
 * Boland et al. 2022 found 30-70 ms of technical delay producing 352 ms of
 * behavioural gap inflation, and their proposed mechanism is disrupted
 * entrainment: what hurts is delay that is UNPREDICTABLE, not delay that is
 * large but steady. So a p50 over a whole call is the wrong summary. This probe
 * reports the trajectory.
 *
 * Mouth-to-ear = transit + queue. `ageP50` is measured at frame arrival and
 * carries transit only; `depthMs` is audio sitting ahead of the playhead. They
 * add, and the round trip before you hear a reply is twice their sum.
 *
 * Phases (default 110 s, one run, no repetition needed — the comparison is
 * against this call's OWN baseline, not against another run):
 *   0-20 s   clean          establish baseline
 *   20-50 s  loss injected  the bad patch
 *   50-110 s clean          RECOVERY: does it come back, and how fast
 *
 * The recovery leg is the whole point and is why the run is not shorter. A
 * buffer that inflates under loss and then stays inflated is the Schoenenberg
 * failure mode exactly: nothing looks broken, the other person just seems slow,
 * and call-quality ratings stay flat while they are rated less attentive.
 *
 *   node testbed/fatigue.mjs [--rtt=80] [--loss=5] [--sec=110] [--qs=...]
 */
import { chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';
import { startP2PSim } from './netsim.mjs';
import { P2P_REWRITE } from './p2p-rewrite.mjs';

const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const FIX = '/Users/earningsgpt/video calling/testbed/media/timecode720.y4m';
const AUD = '/Users/earningsgpt/video calling/testbed/media/conv/A.wav';

const arg = (k, d) => {
  const m = process.argv.find((a) => a.startsWith(`--${k}=`));
  return m ? m.slice(k.length + 3) : d;
};
// NaN-hostile, same reason as competitor.mjs: a network condition that silently
// fails to apply reports clean numbers under a lossy heading.
const num = (k, d) => {
  const raw = arg(k, null);
  if (raw == null) return d;
  const v = Number(raw);
  if (!Number.isFinite(v)) { console.log(`--${k}=${raw} is not a number. Refusing to run.`); process.exit(2); }
  return v;
};
const RTT = num('rtt', 80);
const LOSS = num('loss', 5);
const SEC = num('sec', 110);
const T_LOSS_ON = num('lossAt', 20);
const T_LOSS_OFF = num('lossOff', 50);
const QS = arg('qs', '');

// Literature anchors, for reading the numbers against something. FATIGUE.md
// carries the citations; these are the figures the blog may quote.
const NATURAL_GAP = 208;   // Stivers et al. 2009, PNAS 106(26), 10-language mean
const F2F_GAP = 135;       // Boland et al. 2022, same dyads face-to-face
const ZOOM_GAP = 487;      // Boland et al. 2022, same dyads over Zoom

const sim = await startP2PSim({ oneWayMs: RTT / 2, jitterMs: 0, lossPct: 0, bwMbps: 0, queueMs: 100 });


const mk = async () => {
  const c = await chromium.launchPersistentContext('', {
    executablePath: CHROME, headless: true,
    args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
      `--use-file-for-fake-video-capture=${FIX}`, `--use-file-for-fake-audio-capture=${AUD}`,
      '--autoplay-policy=no-user-gesture-required'],
    viewport: { width: 1000, height: 700 },
  });
  const p = await c.newPage();
  await p.exposeFunction('__simProxy', async (h, port) => sim.portFor(h, port));
  await p.addInitScript(P2P_REWRITE);
  return { c, p };
};

const url = `https://room.tokkah.com/?r=ftg${Math.random().toString(36).slice(2, 7)}${QS ? '&' + QS : ''}`;
console.log(`\nfatigue drift probe — ${url}`);
console.log(`rtt ${RTT} ms   loss ${LOSS}% from ${T_LOSS_ON}s to ${T_LOSS_OFF}s   run ${SEC}s\n`);

const A = await mk(), B = await mk();
await A.p.goto(url, { waitUntil: 'domcontentloaded' });
await A.p.waitForTimeout(4000);
await A.p.click('#join').catch(() => {});
await A.p.waitForTimeout(3000);
await B.p.goto(url, { waitUntil: 'domcontentloaded' });
await B.p.waitForTimeout(4000);
await B.p.click('#join').catch(() => {});
await B.p.waitForTimeout(8000);

// Prove the delay line carries the media. Zero rewrites means every candidate
// went around the proxy and the whole run is a loopback measurement wearing an
// 80 ms label.
const rw = await Promise.all([A, B].map((e) => e.p.evaluate(() => window.__rewrites ?? [])));
const nrw = rw.map((r) => r.filter((x) => !x.error).length);
console.log(`candidates rewritten A=${nrw[0]} B=${nrw[1]}`);
if (!nrw[0] || !nrw[1]) { console.log('FAIL: media is not on the delay line.'); process.exit(2); }

const rows = [];
const t0 = Date.now();
let lossOn = false;
for (;;) {
  const t = (Date.now() - t0) / 1000;
  if (t >= SEC) break;
  if (!lossOn && t >= T_LOSS_ON && t < T_LOSS_OFF) { sim.setLoss(LOSS); lossOn = true; console.log(`  ${t.toFixed(0)}s  --- loss ${LOSS}% ON ---`); }
  if (lossOn && t >= T_LOSS_OFF) { sim.setLoss(0); lossOn = false; console.log(`  ${t.toFixed(0)}s  --- loss OFF ---`); }
  const [pa, pb] = await Promise.all([
    A.p.evaluate(() => window.__tape?.pcm ?? null).catch(() => null),
    B.p.evaluate(() => window.__tape?.pcm ?? null).catch(() => null),
  ]);
  if (pa && pb) {
    // Teardown and warm-up produce impossible rows (FATIGUE.md records a
    // -1779 ms depth becoming a headline). A negative depth or a null age is
    // not a small error to average away, it is a row that means nothing.
    const ok = (p) => p && p.depthMs != null && p.depthMs >= 0 && p.ageP50 != null && Number.isFinite(p.ageP50);
    if (ok(pa) && ok(pb)) {
      rows.push({
        t,
        a: { age: pa.ageP50, depth: pa.depthMs, target: pa.targetFrames, conceal: pa.lostFrames,
             bumps: pa.bumps, pain: pa.painEvents, decays: pa.decays, late: pa.lateFrames,
             played: pa.playedFrames, spread: pa.jitSpreadMs, p90: pa.jitP90Ms, max: pa.jitMaxMs, want: pa.jitWant },
        b: { age: pb.ageP50, depth: pb.depthMs, target: pb.targetFrames, conceal: pb.lostFrames,
             bumps: pb.bumps, pain: pb.painEvents, decays: pb.decays, late: pb.lateFrames,
             played: pb.playedFrames, spread: pb.jitSpreadMs, p90: pb.jitP90Ms, max: pb.jitMaxMs, want: pb.jitWant },
      });
    }
  }
  await new Promise((r) => setTimeout(r, 1000));
}

await Promise.all([A.c.close(), B.c.close()]);
sim.stop?.();

if (rows.length < 30) { console.log(`FAIL: only ${rows.length} usable samples.`); process.exit(1); }

// gapAdded = 2 x (transit + queue), per direction, then the mean of the two —
// a conversation's turn gap is paid in both directions and neither end owns it.
const gap = (r) => ((r.a.age + r.a.depth) + (r.b.age + r.b.depth));
const inWindow = (lo, hi) => rows.filter((r) => r.t >= lo && r.t < hi);
const med = (xs) => { const s = [...xs].sort((x, y) => x - y); return s.length ? s[Math.floor(s.length / 2)] : null; };

const base = med(inWindow(T_LOSS_ON - 10, T_LOSS_ON).map(gap));
const peak = Math.max(...inWindow(T_LOSS_ON, T_LOSS_OFF).map(gap));
const atOff = med(inWindow(T_LOSS_OFF - 5, T_LOSS_OFF).map(gap));
const tail = med(inWindow(SEC - 15, SEC).map(gap));

// Recovery: first sample after loss stops that is back within 10% of baseline
// AND stays there. A single dip that bounces back is not a recovery.
const after = rows.filter((r) => r.t >= T_LOSS_OFF);
let recovered = null;
for (let i = 0; i < after.length; i++) {
  if (gap(after[i]) <= base * 1.1 && after.slice(i).every((r) => gap(r) <= base * 1.25)) {
    recovered = +(after[i].t - T_LOSS_OFF).toFixed(0);
    break;
  }
}

console.log('\n=== turn-gap proxy: 2 x one-way mouth-to-ear, both directions ===');
console.log('   t(s)  gapAdded  A dep  B dep  tgt  d(cnc)  d(late)   A jit p90/p99/max -> want');
let prev = null;
for (const r of rows) {
  if (Math.round(r.t) % 5) continue;
  const d = (k) => (prev ? (r.a[k] - prev.a[k]) + (r.b[k] - prev.b[k]) : 0);
  console.log(`  ${String(Math.round(r.t)).padStart(5)}  ${gap(r).toFixed(0).padStart(6)} ms` +
    `  ${r.a.depth.toFixed(0).padStart(5)}  ${r.b.depth.toFixed(0).padStart(5)}` +
    ` ${String(r.a.target).padStart(2)}/${String(r.b.target).padStart(2)}` +
    ` ${String(d('conceal')).padStart(6)}  ${String(d('late')).padStart(6)}` +
    `      ${String(r.a.p90 ?? '?').padStart(6)}/${String(r.a.spread ?? '?').padStart(6)}/${String(r.a.max ?? '?').padStart(6)} -> ${r.a.want ?? '?'}`);
  prev = r;
}

// Boland's proposed mechanism is disrupted entrainment: turn-taking runs on
// PREDICTION, and a delay that keeps changing is what breaks the lock. So the
// spread within a phase is not a secondary statistic here — it is closer to the
// mechanism than the level is. A steady 200 ms should cost less than a 120 ms
// that wanders by 80.
const spread = (lo, hi) => {
  const xs = inWindow(lo, hi).map(gap).sort((x, y) => x - y);
  if (xs.length < 4) return null;
  return { p10: xs[Math.floor(0.1 * xs.length)], p90: xs[Math.floor(0.9 * xs.length)] };
};
const sClean = spread(T_LOSS_ON - 15, T_LOSS_ON);
const sLoss = spread(T_LOSS_ON, T_LOSS_OFF);
const sTail = spread(SEC - 25, SEC);

const cFirst = rows[0], cLast = rows[rows.length - 1];
const cnc = (cLast.a.conceal - cFirst.a.conceal) + (cLast.b.conceal - cFirst.b.conceal);
const ply = (cLast.a.played - cFirst.a.played) + (cLast.b.played - cFirst.b.played);
console.log('\n=== summary ===');
console.log(`concealment over the whole run          : ${(100 * cnc / Math.max(1, cnc + ply)).toFixed(2)}%  (${cnc} frames)`);
console.log(`baseline (clean, 10 s before the burst) : ${base.toFixed(0)} ms`);
console.log(`peak during ${LOSS}% loss                     : ${peak.toFixed(0)} ms   (+${(peak - base).toFixed(0)})`);
console.log(`at the moment loss stops                : ${atOff.toFixed(0)} ms`);
console.log(`last 15 s of the run                    : ${tail.toFixed(0)} ms   (+${(tail - base).toFixed(0)} vs baseline)`);
console.log(`time to return within 10% of baseline   : ${recovered == null ? 'NEVER, within this run' : recovered + ' s'}`);
// The wander, phase by phase. Boland's mechanism says this is what breaks
// entrainment, so a wide clean-path spread is worse news than a high flat one.
const sp = (s) => (s ? `${(s.p90 - s.p10).toFixed(0)} ms  (p10 ${s.p10.toFixed(0)} .. p90 ${s.p90.toFixed(0)})` : 'too few samples');
console.log(`\nwander (p90-p10 of the gap within a phase) — the entrainment axis:`);
console.log(`  clean, before the burst               : ${sp(sClean)}`);
console.log(`  during ${String(LOSS).padStart(2)}% loss                        : ${sp(sLoss)}`);
console.log(`  clean, after recovery                 : ${sp(sTail)}`);
console.log('\nagainst the literature (FATIGUE.md carries the citations):');
console.log(`  natural inter-turn gap, 10 languages  : ${NATURAL_GAP} ms   (Stivers 2009)`);
console.log(`  same dyads face-to-face               : ${F2F_GAP} ms   (Boland 2022)`);
console.log(`  same dyads over Zoom                  : ${ZOOM_GAP} ms   (Boland 2022)`);
console.log(`  our added gap, clean                  : ${base.toFixed(0)} ms  -> expected turn gap ~${(F2F_GAP + base).toFixed(0)} ms`);
console.log(`  our added gap, during ${String(LOSS).padStart(2)}% loss         : ${peak.toFixed(0)} ms  -> expected turn gap ~${(F2F_GAP + peak).toFixed(0)} ms`);
console.log('\nThis is a delay-literature PROXY, not a validated fatigue score. The ZEF');
console.log('Scale has never been correlated with measured latency; do not claim one.');

// A run where the burst did nothing measured nothing.
if (peak < base * 1.15) { console.log('\nWARNING: the burst barely moved the metric. Check that loss was applied.'); }
process.exit(0);
