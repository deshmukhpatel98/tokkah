// Measure glass-to-glass latency, resolution and displayed frame rate on ANY
// calling service, from a join link. Reads only pixels, so it needs no
// cooperation from the service and works identically on ours and theirs.
//
//   node competitor.mjs --url="<join link>" --label=Meet [--sec=20] [--stagger=6]
//   node competitor.mjs --self                     # validate against our own app
//
// The hard part is not the timing, it is knowing WHICH video element on the
// receiving page is the far end. Getting that wrong is not a small error: an
// earlier run of this rig decoded meet.jit.si's `#largeVideo`, which was the
// page's own self-view, and produced a confident "836.7 ms, p95 852.7" that was
// nothing but the phase difference between two readers of the same looped
// fixture file. So this driver does not take a selector. It records EVERY video
// element and identifies the far end by behaviour:
//
// The first attempt at a fix used a timing heuristic (phase is constant, real
// latency jitters). It does not work: two independent in-page rAF samplers show
// 12-14 ms of spread on a pure phase offset, which passes for network jitter.
//
// So the discriminator is structural instead. The two browsers are given
// DIFFERENT fixtures, identical but for a source tag in the top bit of the bar
// code. An element showing this page's own camera carries this page's own tag.
// The far end is the element carrying the OTHER tag. No threshold to tune.
//
// Validated against room.tokkah.com, where the answer is independently known:
// reports p50 28.5 ms / p95 47.2 ms / 1920x1080 against a known 27.3 / 46.9 / 1080p,
// and rejects all four self-view elements.
import { readFileSync } from 'node:fs';
import { chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';
import { startP2PSim } from './netsim.mjs';
import { P2P_REWRITE } from './p2p-rewrite.mjs';

const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
// --fixture=camcode720 selects the high-entropy pair built by mktimecode.mjs.
// The default `timecode720` pair compresses to ONE 1100 B fragment per frame, so
// lane 1's parity (gated on `count > 1`) can never fire and every loss result on
// it is void. Use the default for latency, `camcode720` for anything touching
// fragmentation, FEC or loss. `--dump` prints fragsSent next to framesEncoded so
// the ratio is visible in the run that used it.
const FIXBASE = '/Users/earningsgpt/video calling/testbed/media';
const AUD = '/Users/earningsgpt/video calling/testbed/media/conv/A.wav';

const arg = (k, d) => {
  const m = process.argv.find((a) => a.startsWith(`--${k}=`));
  return m ? m.slice(k.length + 3) : d;
};
// A MISSPELLED FLAG USED TO BE SILENT, and silent is the worst possible failure
// for a measurement harness: the duration flag here is `--sec=`, so every
// `--secs=35` I passed matched nothing, took the 20 s default, and reported a
// perfectly plausible run. Same shape as the zsh word-split trap -- the
// simulated condition never applied and nothing said so.
//
// The valid keys are scanned out of THIS FILE's own source rather than kept in
// a hand-written list, because a hand-written list is one more thing that can
// drift out of date and re-open the hole it was added to close.
{
  const src = readFileSync(new URL(import.meta.url), 'utf8');
  // Both wrappers, because `num('rtt')` reaches arg() through a variable and a
  // scan for arg('...') alone would reject every network flag this harness has.
  const keys = new Set([...src.matchAll(/\b(?:arg|num)\(\s*'([a-zA-Z0-9_]+)'/g)].map((m) => m[1]));
  const bools = new Set([...src.matchAll(/argv\.includes\('--([a-zA-Z0-9_]+)'\)/g)].map((m) => m[1]));
  const bad = process.argv.slice(2).filter((a) => {
    if (!a.startsWith('--')) return false;
    const k = a.slice(2).split('=')[0];
    return !keys.has(k) && !bools.has(k);
  });
  if (bad.length) {
    const near = (k) => [...keys, ...bools].filter((v) => v.startsWith(k.slice(0, 3))).join(', ');
    console.error(`unknown flag(s): ${bad.join(' ')}`);
    for (const b of bad) {
      const n = near(b.slice(2).split('=')[0]);
      if (n) console.error(`  ${b}  -> did you mean: ${n}`);
    }
    process.exit(2);
  }
}
const SELF = process.argv.includes('--self');
const FIXNAME = arg('fixture', 'timecode720');
const FIX_A = `${FIXBASE}/${FIXNAME}.y4m`;    // src=0
const FIX_B = `${FIXBASE}/${FIXNAME}b.y4m`;   // src=1
const SEC = Number(arg('sec', 20));
const STAGGER = Number(arg('stagger', 6));
// A candidate is the far end if and only if it carries the OTHER browser's source
// tag. No threshold, no heuristic, nothing to tune.

// Decoder: reads the 10-bit bar code out of whatever element it is pointed at.
const DECODER = `
// Cost matters: this runs inside the rAF loop being timed. A first version drew
// each candidate at full 1280x720 and made ten getImageData calls per element per
// frame; with six candidates that was slow enough to LAG ITS OWN TIMESTAMPS and it
// reported 404 ms for a path independently known to run at 27 ms. The instrument
// was measuring itself. This version scales the bar strip straight down to 11x1
// pixels — one drawImage, one getImageData of eleven pixels.
window.__tc = function (el) {
  // Canvas as well as video: our remote tile is painted to #remoteCanvas, and a
  // version that queried only <video> found NO remote tile and happily reported a
  // self-view as glass-to-glass latency.
  if (!el) return null;
  const vw = el.videoWidth || el.width, vh = el.videoHeight || el.height;
  if (!vw || !vh) return null;
  const BITS = 10;
  // Bar geometry as FRACTIONS of the fixture frame, so any display size works.
  const fx = 40 / 1280, fy = 24 / 720, fw = (11 * 96) / 1280, fh = 120 / 720;
  const c = window.__tcC || (window.__tcC = document.createElement('canvas'));
  c.width = BITS + 1; c.height = 1;
  const g = window.__tcG || (window.__tcG = c.getContext('2d', { willReadFrequently: true }));
  try {
    g.drawImage(el, fx * vw, fy * vh, fw * vw, fh * vh, 0, 0, BITS + 1, 1);
  } catch { return null; }
  const d = g.getImageData(0, 0, BITS + 1, 1).data;
  const lum = (i) => (d[i * 4] + d[i * 4 + 1] + d[i * 4 + 2]) / 3;
  if (lum(0) < 125) return null;   // sync cell dark => not our fixture
  let v = 0;
  for (let b = 1; b <= BITS; b++) v = (v << 1) | (lum(b) > 125 ? 1 : 0);
  // Top bit is the SOURCE tag, low 9 the frame index. This is what makes a
  // self-view identifiable rather than merely improbable.
  return { src: (v >> (BITS - 1)) & 1, idx: v & 511, w: vw, h: vh };
};
window.__recAll = function (ms, only) {
  const out = {};
  window.__recOut = out;
  const stop = performance.now() + ms;
  const last = {};
  const tick = () => {
    const els = [...document.querySelectorAll('video, canvas')];
    for (let i = 0; i < els.length; i++) {
      const el = els[i];
      if (!(el.videoWidth || el.width)) continue;
      const key = (el.id || el.className || 'v') + '#' + i;
      if (only && only.length && only.indexOf(key) < 0) continue;
      const r = window.__tc(el);
      if (!r) continue;
      if (last[key] === r.idx) continue;
      last[key] = r.idx;
      (out[key] ||= []).push({ idx: r.idx, src: r.src, t: performance.timeOrigin + performance.now(), w: r.w, h: r.h });
    }
    if (performance.now() < stop) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
  return true;
};`;

// ── Emulated distance ────────────────────────────────────────────────────────
// Loopback measures the pipeline's own cost and nothing else: ICE reads 0 ms, so a
// lane that wins by removing a buffer wins unconditionally, and a lane that wins by
// surviving loss cannot show it. --rtt/--loss/--jitter/--bw put a real delay line on
// the media path so both kinds of advantage are visible in one instrument.
//
// Mechanism lifted verbatim from call.mjs: rewrite every REMOTE candidate to point at
// a UDP delay proxy fronting the peer, so the peer's real address is never learned.
// Candidate rewriting rather than a TURN relay because the relay is a ~40 s cliff and
// would contaminate any run longer than that with harness loss (netsim.mjs).
// NaN-hostile. A flag that arrives unparseable must stop the run, not quietly leave
// the network condition off: `--rtt=80 --loss=5` passed through an unquoted zsh
// variable arrives as ONE argv entry, "80 --loss=5" parses to NaN, NaN > 0 is false,
// and the run reports a clean loopback number under a heading that says 80 ms.
const num = (k) => {
  const raw = arg(k, null);
  if (raw == null) return 0;
  const v = Number(raw);
  if (!Number.isFinite(v)) {
    console.log(`--${k}=${raw} is not a number. Refusing to run: the network condition would silently be off.`);
    process.exit(2);
  }
  return v;
};
const SIM_RTT = num('rtt');
const SIM_JITTER = num('jitter');
const SIM_LOSS = num('loss');
const SIM_BW = num('bw');
const SIM_QUEUE = Number(arg('queue', 100));
// --burst=15,45 --burstLoss=5 : loss only between those seconds of the recording.
const BURST = arg('burst', null) ? arg('burst', '').split(',').map(Number) : null;
const BURST_LOSS = Number(arg('burstLoss', 5));
if (BURST && (BURST.length !== 2 || BURST.some((x) => !Number.isFinite(x)))) {
  console.log('--burst wants two numbers, e.g. --burst=15,45'); process.exit(2);
}
const SIMULATED = SIM_RTT > 0 || SIM_JITTER > 0 || SIM_LOSS > 0 || SIM_BW > 0 || !!BURST;

// Shared with the other link-shaping harnesses; see p2p-rewrite.mjs for why.

// One crossing per direction, so the full one-way delay goes here and loss is not
// compounded — both corrections the TURN path needs and this one does not.
const sim = SIMULATED
  ? await startP2PSim({ oneWayMs: SIM_RTT / 2, jitterMs: SIM_JITTER, lossPct: SIM_LOSS,
                        bwMbps: SIM_BW, queueMs: SIM_QUEUE })
  : null;

const mk = async (fixture) => {
  const c = await chromium.launchPersistentContext('', {
    executablePath: CHROME, headless: true,
    args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
      `--use-file-for-fake-video-capture=${fixture}`, `--use-file-for-fake-audio-capture=${AUD}`,
      '--autoplay-policy=no-user-gesture-required'],
    viewport: { width: 1400, height: 900 },
  });
  const p = await c.newPage();
  await p.addInitScript(DECODER);
  if (sim) {
    // exposeFunction must precede the init script that calls it.
    await p.exposeFunction('__simProxy', async (h, port) => sim.portFor(h, port));
    await p.addInitScript(P2P_REWRITE);
  }
  return { c, p };
};

// Click through whatever the service puts between a link and the call. Ordered
// most-specific first; a service that needs none of these is unaffected.
const JOIN_LABELS = ['Join meeting', 'Join now', 'Ask to join', 'Join call', 'Join audio',
                     'Continue', 'Join', 'Start meeting', 'Enter'];
async function clickThrough(page, tag) {
  // Many prejoin screens gate the join button behind a display name.
  for (const sel of ['input[placeholder*="ame" i]:visible', 'input[type="text"]:visible']) {
    try {
      const i = page.locator(sel).first();
      if ((await i.count()) && (await i.isVisible({ timeout: 500 }))) {
        await i.fill(`probe-${tag}`, { timeout: 2000 });
        console.log(`  [${tag}] filled display name`);
        break;
      }
    } catch { /* no such field on this page */ }
  }
  for (let pass = 0; pass < 3; pass++) {
    let hit = false;
    for (const label of JOIN_LABELS) {
      for (const sel of [`[data-testid="prejoin.joinMeeting"]`, `button:has-text("${label}")`,
                         `div[role="button"]:has-text("${label}")`, `[aria-label="${label}"]`]) {
        try {
          const el = page.locator(sel).first();
          if ((await el.count()) && (await el.isVisible({ timeout: 400 }))) {
            await el.click({ timeout: 3000 });
            console.log(`  [${tag}] clicked "${label}"`);
            hit = true;
            await page.waitForTimeout(2500);
            break;
          }
        } catch { /* selector unsupported on this page; try the next */ }
      }
      if (hit) break;
    }
    if (!hit) break;
  }
}

// The timecode carries a 9-bit index, so it WRAPS every 512 frames — about 17 s
// at 30 fps, which is inside every run this rig does. Keyed on the raw index that
// broke both numbers: `seen` treated every post-wrap frame as a duplicate and
// dropped it, so the latency sample silently covered only the first 17 s; and
// `cov` was a ratio of two Sets that each saturate at 512, so it drifted toward
// 100% however many frames were lost. It reported 99.0% delivered on a condition
// where the lane's own counter said 127 frames were dumped.
//
// Unwrap to a monotonic id first. A backward jump of more than half the range is
// a wrap, not reordering.
// The wrap period is the FIXTURE LOOP LENGTH, not the index's bit width. The stamp
// reserves 9 bits, but camcode720 is 256 frames and Chrome loops it, so idx only
// ever runs 0-255 and repeats every ~8.5 s at 30 fps. Derive it from the data:
// hardcoding 512 made this function silently inert, because a 255 -> 0 step is not
// a backward jump of more than 256, and "inert" looked exactly like "working".
function rangeOf(...streams) {
  let mx = 0;
  for (const s of streams) for (const r of s) if (r.idx > mx) mx = r.idx;
  return mx + 1;
}
function unwrap(rows, range) {
  let epoch = 0, prev = null;
  return rows.map((r) => {
    if (prev != null && r.idx < prev - range / 2) epoch++;
    prev = r.idx;
    return { ...r, u: epoch * range + r.idx };
  });
}

// Both record loops start together, so the sender sample nearest in time is the
// epoch reference. Without this the two streams can unwrap into different epochs
// when a run happens to straddle a wrap at its start, and then no frame matches.
function alignEpochs(su, ru, range) {
  if (!su.length || !ru.length) return ru;
  const r0 = ru[0];
  let near = su[0];
  for (const s of su) if (Math.abs(s.t - r0.t) < Math.abs(near.t - r0.t)) near = s;
  const shift = r0.idx - near.idx > range / 2 ? -range
    : near.idx - r0.idx > range / 2 ? range : 0;
  return shift ? ru.map((r) => ({ ...r, u: r.u + shift })) : ru;
}

function stats(senderRaw, recvRaw) {
  const range = rangeOf(senderRaw, recvRaw);
  const sender = unwrap(senderRaw, range);
  const recv = alignEpochs(sender, unwrap(recvRaw, range), range);
  const first = new Map();
  for (const s of sender) if (!first.has(s.u)) first.set(s.u, s.t);
  const lat = [];
  // (arrival time, latency) pairs, so the run can be split into thirds. A lane
  // whose buffer ratchets shows a rising p50 across a single call, and one
  // whole-run percentile hides that completely — which is what the truncated
  // sample was doing: it only ever saw the first loop, i.e. the freshest part.
  const pairs = [];
  const seen = new Set();
  for (const r of recv) {
    if (seen.has(r.u)) continue;
    seen.add(r.u);
    const st = first.get(r.u);
    if (st == null) continue;
    const d = r.t - st;
    if (d > -200 && d < 8000) { lat.push(d); pairs.push({ t: r.t, d }); }
  }
  if (lat.length < 8) return null;
  lat.sort((a, b) => a - b);
  const pct = (p) => +lat[Math.min(lat.length - 1, Math.floor((p / 100) * lat.length))].toFixed(1);
  const span = (recv.at(-1).t - recv[0].t) / 1000;
  // Delivery, not just the latency of whatever survived. Both sides are sampled by
  // the same rAF-limited loop, so the ABSOLUTE index counts are sampler-capped and
  // meaningless — but their RATIO is not, because the cap applies equally. Counted
  // only over the window the receiver was actually up for, so a late start does not
  // read as loss. Latency alone would rank a lane that drops half the frames and
  // shows the rest promptly above one that shows all of them.
  const lo = recv[0].t, hi = recv.at(-1).t;
  const sIdx = new Set(sender.filter((s) => s.t >= lo && s.t <= hi).map((s) => s.u));
  const rIdx = new Set(recv.map((r) => r.u));
  return {
    // range/wraps are printed so an inert unwrap is visible instead of silent. A
    // 20 s run at 30 fps over a 256-frame fixture must show wraps >= 2; wraps 0 on
    // a run longer than the loop means the dedupe is eating everything after it.
    range, wraps: Math.floor((recv.at(-1).u - recv[0].u) / range),
    // 10 s windows. Thirds cannot see a burst that starts and ends inside the
    // run — the whole point of a burst — and a recovery that takes ~27 s is
    // invisible when the run is sliced into three.
    windows: (() => {
      const w = [], W = 10000;
      for (let t = lo; t < hi; t += W) {
        const xs = pairs.filter((p) => p.t >= t && p.t < t + W).map((p) => p.d).sort((x, y) => x - y);
        w.push({ t: Math.round((t - lo) / 1000), n: xs.length,
                 p50: xs.length ? +xs[Math.floor(0.5 * xs.length)].toFixed(1) : null });
      }
      return w;
    })(),
    thirds: [0, 1, 2].map((k) => {
      const t0 = lo + ((hi - lo) * k) / 3, t1 = lo + ((hi - lo) * (k + 1)) / 3;
      const xs = pairs.filter((p) => p.t >= t0 && (k === 2 ? p.t <= t1 : p.t < t1))
        .map((p) => p.d).sort((x, y) => x - y);
      return xs.length ? +xs[Math.floor(0.5 * xs.length)].toFixed(1) : null;
    }),
    n: lat.length, p50: pct(50), p95: pct(95), min: pct(0),
    spread: +(pct(95) - pct(50)).toFixed(1),
    res: `${recv.at(-1).w}x${recv.at(-1).h}`,
    fps: span > 0 ? +(rIdx.size / span).toFixed(1) : null,
    cov: sIdx.size ? +((100 * rIdx.size) / sIdx.size).toFixed(1) : null,
  };
}

const label = arg('label', SELF ? 'room.tokkah.com' : 'service');
// --qs=a=1&b=2 rides along on --self, so A/B arms of our own app (renderer,
// codec, lane) go through the identical measurement code rather than a second
// instrument. Both browsers navigate to this same string, so one flag arms both.
const QS_EXTRA = arg('qs', '');
const url = SELF
  ? `https://room.tokkah.com/?r=cmp${Math.random().toString(36).slice(2, 7)}${QS_EXTRA ? '&' + QS_EXTRA : ''}`
  : arg('url', null);
if (!url) { console.log('need --url="<join link>" (or --self)'); process.exit(1); }

const A = await mk(FIX_A), B = await mk(FIX_B);
console.log(`\n${label}\n${url}\n`);
// A waiting room turns "joined" into a human act with no fixed duration: Meet's
// "Ask to join" sits until the host clicks Admit, and the old fixed 8 s wait
// timed out long before any human could admit two knockers. Joined-ness is
// observable from the page itself — a decodable timecode means the fixture is
// live on screen, which only happens once the call is actually entered — so
// poll for that instead of guessing a duration. SELF keeps a short bound; the
// join there is a button, not a doorman.
async function waitInCall(page, tag, maxMs) {
  const t0 = Date.now();
  let told = false;
  while (Date.now() - t0 < maxMs) {
    const ok = await page.evaluate(() =>
      [...document.querySelectorAll('video, canvas')].some((el) => window.__tc(el))).catch(() => false);
    if (ok) { console.log(`  [${tag}] in call (${((Date.now() - t0) / 1000).toFixed(0)}s)`); return true; }
    if (!told && Date.now() - t0 > 10000) {
      told = true;
      console.log(`  [${tag}] not in the call yet — if there is a waiting room, admit "probe-${tag}" now`);
    }
    await page.waitForTimeout(1000);
  }
  console.log(`  [${tag}] gave up after ${maxMs / 1000}s — never saw its own fixture on screen`);
  return false;
}
const ADMIT_MS = SELF ? 20000 : 180000;
await A.p.goto(url, { waitUntil: 'domcontentloaded' });
await A.p.waitForTimeout(4000);
if (SELF) { await A.p.click('#join').catch(() => {}); } else { await clickThrough(A.p, 'A'); }
await waitInCall(A.p, 'A', ADMIT_MS);
// Stagger so the two fixtures are demonstrably out of phase — that phase gap is
// what makes a self-view identifiable instead of a plausible latency.
await A.p.waitForTimeout(STAGGER * 1000);
await B.p.goto(url, { waitUntil: 'domcontentloaded' });
await B.p.waitForTimeout(4000);
if (SELF) { await B.p.click('#join').catch(() => {}); } else { await clickThrough(B.p, 'B'); }
await waitInCall(B.p, 'B', ADMIT_MS);
await B.p.waitForTimeout(8000);

// Pass 1: a 3 s sweep of everything, purely to learn which elements exist and
// what each one carries. Pass 2 then records only the two that matter, so the
// timed loop stays cheap enough not to distort the timings.
await Promise.all([A.p.evaluate(() => window.__recAll(3000, null)),
                   B.p.evaluate(() => window.__recAll(3000, null))]);
await new Promise((r) => setTimeout(r, 3600));
const [da, db] = await Promise.all([A.p.evaluate(() => window.__recOut),
                                    B.p.evaluate(() => window.__recOut)]);
const pickA = Object.entries(da).filter(([, v]) => v.some((r) => r.src === 0))
  .sort((x, y) => y[1].length - x[1].length)[0]?.[0];
const pickB = Object.entries(db).filter(([, v]) => v.some((r) => r.src === 0))
  .sort((x, y) => (y[1].at(-1).w * y[1].at(-1).h) - (x[1].at(-1).w * x[1].at(-1).h))[0]?.[0];
// Prove the delay line is actually carrying the media. A rewrite count of zero means
// every candidate went around the proxy, and the run would report a real-looking
// latency for a path with no simulated distance on it at all.
if (sim) {
  const rw = await Promise.all([A, B].map((e) => e.p.evaluate(() => window.__rewrites ?? [])));
  const n = rw.map((r) => r.filter((x) => !x.error).length);
  console.log(`netsim: rtt ${SIM_RTT} ms, loss ${SIM_LOSS}%, jitter ${SIM_JITTER} ms, bw ${SIM_BW || '∞'} Mbps` +
              `  |  candidates rewritten A=${n[0]} B=${n[1]}`);
  if (!n[0] || !n[1]) {
    console.log('ABORT: a side rewrote no candidates, so its media never crossed the delay line.');
    console.log('Do not report a number from this run.');
    for (const e of [A, B]) await e.c.close();
    await sim.stop?.();
    process.exit(4);
  }
}
console.log(`discovery: sender element "${pickA}", far-end element "${pickB}"`);
console.log(`  A had ${Object.keys(da).join(', ')}`);
console.log(`  B had ${Object.entries(db).map(([k, v]) => k + '(src=' + [...new Set(v.map((r) => r.src))].join('/') + ')').join(', ')}`);
if (!pickA || !pickB) {
  console.log('\n=== result ===');
  console.log(`${label}: NO element on the receiving page carries the sender's source tag.`);
  console.log('The two browsers were not in one call. Do not report a number from this run.');
  for (const e of [A, B]) await e.c.close();
  process.exit(3);
}
await Promise.all([A.p.evaluate(([m, k]) => window.__recAll(m, [k]), [SEC * 1000, pickA]),
                   B.p.evaluate(([m, k]) => window.__recAll(m, [k]), [SEC * 1000, pickB])]);
// --burst=on,off injects loss for a window INSIDE the recording, so video
// latency can be read as a trajectory through a bad patch and out the other
// side rather than as one number over a call that was uniformly bad. The audio
// equivalent is testbed/fatigue.mjs; this is the video half FATIGUE.md lists as
// missing. A run without --burst sleeps exactly as before.
if (BURST && sim) {
  const [on, off] = BURST;
  await new Promise((r) => setTimeout(r, on * 1000));
  sim.setLoss(BURST_LOSS);
  console.log(`  burst: ${BURST_LOSS}% loss ON at ${on}s`);
  await new Promise((r) => setTimeout(r, (off - on) * 1000));
  sim.setLoss(SIM_LOSS);
  console.log(`  burst: back to ${SIM_LOSS}% at ${off}s`);
  await new Promise((r) => setTimeout(r, (SEC - off) * 1000 + 1200));
} else {
  await new Promise((r) => setTimeout(r, SEC * 1000 + 1200));
}
const [ra, rb] = await Promise.all([A.p.evaluate(() => window.__recOut),
                                    B.p.evaluate(() => window.__recOut)]);
await A.p.screenshot({ path: `cmp-${label.replace(/\W+/g, '_')}-A.png` }).catch(() => {});
// --dump: the lane's own send/receive counters. getStats() cannot see this path at
// all — it is datachannel bytes, or a carrier's RTP — so when a lane loses frames
// this is the only instrument that can say WHERE: raw loss the FEC could not repair,
// or admission control shedding because the transport is backed up.
if ((arg('dump', null) !== null || process.argv.includes('--dump')) && SELF) {
  for (const [side, e] of [['A (sender)', A], ['B (receiver)', B]]) {
    const v = await e.p.evaluate(() => window.__tape?.video ?? null).catch(() => null);
    if (!v) { console.log(`  ${side}: no lane counters`); continue; }
    const pick = (ks) => ks.map((k) => `${k} ${v[k]}`).join('  ');
    // The audio lane's adaptive playout target, in 8 ms frames. This is the clock
    // the avsync scheduler paces VIDEO against, so when it ratchets up under
    // sustained loss the video goes with it. bumps/decays/painEvents say whether
    // it is pinned by continuous pain or merely slow to give the latency back.
    const a = await e.p.evaluate(() => window.__tape?.pcm ?? null).catch(() => null);
    if (a) console.log(`  ${side.padEnd(12)} pcm: targetFrames ${a.targetFrames} (${a.targetFrames * 8} ms)` +
      `  painEvents ${a.painEvents}  bumps ${a.bumps}  decays ${a.decays}  depthMs ${a.depthMs}` +
      `  concealedMs ${a.concealedMs}  outputLatencyMs ${a.outputLatencyMs}`);
    // The measured-jitter estimator's own inputs. It sizes the target off
    // SECOND-LARGEST minus MIN of arrival delay over a 320-frame window, and it
    // publishes those so a target that looks wrong can be diagnosed without a
    // code change -- which is the whole point, so print them. `want` vs
    // `targetFrames` separates "the estimator asked for more and was refused"
    // (a clamp) from "the estimator never saw the lateness" (a blind window).
    if (a) console.log(`  ${side.padEnd(12)} pcmjit: spread ${a.jitSpreadMs} ms  p90 ${a.jitP90Ms}  p99 ${a.jitP99Ms}` +
      `  max ${a.jitMaxMs}  want ${a.jitWant}  n ${a.jitN}  target ${a.targetFrames}` +
      (a.jitWant > a.targetFrames ? '   <-- CLAMPED: estimator asked for more' : '') +
      // aboveFloor is deliberately NOT a percentage: the audio stream starts
      // before the measure window and outlives it, so dividing by SEC printed
      // "118% of call" -- a part exceeding its whole, the same tell as the
      // 637 ms age on an 80 ms call. Seconds against the frame count, which is
      // the only duration here that is actually measured.
      `\n  ${''.padEnd(12)} pcmjit(run): spreadMax ${a.jitSpreadMaxRun} ms  aboveFloor ${(a.jitAboveFloorMs / 1000).toFixed(1)} s` +
      ` of ${((a.playedFrames + a.lostFrames) * 8 / 1000).toFixed(1)} s streamed` +
      `\n  ${''.padEnd(12)} pcmjit(cap): wantMax ${a.jitWantMaxRun} frames (${a.jitWantMaxRun * 8} ms)  cap ${a.jitMaxTarget} (${a.jitMaxTarget * 8} ms)` +
      `  clampedTicks ${a.jitClampedTicks}` +
      (a.jitWantMaxRun > a.jitMaxTarget ? `   <-- CEILING BOUND: estimator wanted ${a.jitWantMaxRun}, allowed ${a.jitMaxTarget}` : ''));

    // Where concealment actually comes from. RS(10,13) survives 3 erasures in 13,
    // so at 5% INDEPENDENT loss only ~0.3% of groups should be unrepairable --
    // any concealment far above that is not "FEC could not fix it" but one of:
    // `fecRepairedLate` (fixed, but the playhead had already passed -- the RS
    // group spans 80 ms and RTT is 80, against a ~120 ms playout target), plain
    // `late` arrivals, or `fecFailed` (genuinely too many erasures, i.e. the loss
    // is bursty rather than independent). These three want completely different
    // fixes, and concealedMs alone cannot tell them apart.
    if (a) console.log(`  ${side.padEnd(12)} pcmfec: framesRecv ${a.framesRecv}  parityRecv ${a.parityRecv}` +
      `  fecRepaired ${a.fecRepaired}  fecRepairedLate ${a.fecRepairedLate}  fecFailed ${a.fecFailed}` +
      `  parityUnused ${a.parityUnused}  lateFrames ${a.lateFrames}  dup ${a.dup}  farFuture ${a.farFuture}` +
      // Must be 0. The RS symbol is the group's longest COMPRESSED frame, so a
      // contributing member longer than it means the two ends disagree about
      // what the group is; the decode is refused rather than guessed at.
      `  fecSymMismatch ${a.fecSymMismatch}` +
      `  played ${a.playedFrames}  lost ${a.lostFrames}  heldMs ${a.heldMs}  extrapMs ${a.extrapolatedMs}` +
      (a.playedFrames + a.lostFrames > 0
        ? `  -> conceal ${((100 * a.lostFrames) / (a.playedFrames + a.lostFrames)).toFixed(1)}%`
        : ''));
    // The adaptive code rate. fecN is the rate in force at the END of the run,
    // so read it with fecNUp/fecNDown: a run that ends at 3 having never moved
    // is a ladder that did not engage, and looks identical in the byte counts
    // to one that engaged and came back. lossPct is what THIS side measured on
    // its inbound stream; peerLossPct is what the far end told us about ours,
    // and it is the one this side's rate is set from.
    if (a) console.log(`  ${side.padEnd(12)} pcmrate: fecN ${a.fecN}/${3} (${a.fecRedundancyPct}% redundancy)` +
      `  latePct ${a.latePctEma} (${a.fecLate ? 'in ladder' : 'IGNORED'})  adapt ${a.fecAdapt}  up ${a.fecNUp}  down ${a.fecNDown}` +
      `  lossPct ${a.lossPct}/${a.lossFastPct} slow/fast  peerLossPct ${a.peerLossPct}/${a.peerLossFastPct}`);
    // The rungs are derived from RS_K at stream start, not hand-tuned, so print
    // them: a ladder that silently kept stale constants would look identical in
    // fecN alone. Expect [0.1, 1.02, 2.78, 5.03] at K=10 and [0.1, 1.43, 4.21,
    // 7.76] at K=5 — see testbed/kchoice.mjs.
    if (a) console.log(`  ${side.padEnd(12)} pcmrsk:  K ${a.rsK}  span ${a.rsSpanMs}ms` +
      `  rungTop [${(a.fecRungTop ?? []).join(', ')}]  (n=0/1/2/3 ceilings, % loss)`);
    // Repairs by position in the RS group, ok vs too-late. Parity cannot exist
    // until the group closes, so position 0 waits the whole 80 ms span while
    // position 9 waits ~8 ms. A late column that is heavy on the LEFT means the
    // span is too long for the buffer; evenly spread means the buffer is simply
    // shallow. The two want opposite fixes and the totals cannot tell them apart.
    if (a?.fecOkPos) {
      const ok = a.fecOkPos, lt = a.fecLatePos;
      const pct = (i) => (ok[i] + lt[i] ? Math.round((100 * lt[i]) / (ok[i] + lt[i])) : 0);
      // Every row carries the `pcmpos` tag: these lines are always read through
      // a grep, and a header-only tag means the numbers get filtered away from
      // the label that explains them.
      console.log(`  ${side.padEnd(12)} pcmpos pos      ` + ok.map((_, i) => String(i).padStart(5)).join(''));
      console.log(`  ${side.padEnd(12)} pcmpos in-time  ` + ok.map((v) => String(v).padStart(5)).join(''));
      console.log(`  ${side.padEnd(12)} pcmpos TOO-LATE ` + lt.map((v) => String(v).padStart(5)).join(''));
      console.log(`  ${side.padEnd(12)} pcmpos late-pct ` + ok.map((_, i) => String(pct(i)).padStart(5)).join('') +
        `   |  mean late ${a.fecRepairedLate ? Math.round(a.fecLateMsSum / a.fecRepairedLate) : 0} ms, max ${a.fecLateMsMax} ms`);
    }
    // The send side, so "missing at the receiver" can be split between the
    // network and our own sender. captureFrames is what the mic produced;
    // framesSent is what actually left; skipBuffered is what the backpressure
    // gate refused because the association was already behind. A gap between
    // capture and sent is OUR loss, and no amount of FEC on the wire repairs a
    // frame that was never put on it.
    if (a) console.log(`  ${side.padEnd(12)} pcmsend: captureFrames ${a.captureFrames}  framesSent ${a.framesSent}` +
      `  paritySent ${a.paritySent}  bPerFrame ${a.bPerFrame}  bPerParity ${a.bPerParity}` +
      // Frames the codec could not compress below the symbol ceiling, so they
      // carry no FEC. 0 on speech; nonzero means noise-like input.
      `  rsOversize ${a.rsOversize}` +
      // The capture chain's effective bit depth, as the codec found it. 8.0 means
      // 16-bit content in a 24-bit container, so bPerFrame just dropped by ~384 B.
      // Read this BEFORE believing any byte count: a fake-audio-capture fixture is
      // 16-bit by construction, so 8.0 here is expected on the rig and says
      // nothing about a real microphone.
      `  wastedShift ${a.wastedShift}  shift8 ${a.shift8Pct}%` +
      `  fit32767 ${a.fit32767Pct}%  fit32768 ${a.fit32768Pct}%` +
      `  mbpsSent ${a.mbpsSent}  buffered ${a.buffered}  groupsHeld ${a.groupsHeld}` +
      `  overflowSkips ${a.overflowSkips}  driftPpm ${a.driftPpm}  depthMs ${a.depthMs}` +
      (a.perAssoc ?? []).map((s) => `\n  ${' '.repeat(12)} assoc${s.i} open ${s.open} sent ${s.framesSent} recv ${s.framesRecv} skipBuffered ${s.skipBuffered}`).join(''));
    // fragsSent/framesEncoded is the fragments-per-frame ratio. It has to be printed
    // next to paritySent, because lane 1 only emits parity for frames longer than one
    // 1100 B fragment — so a low-entropy fixture with tiny delta frames shows
    // paritySent 0 for reasons that have nothing to do with the product.
    console.log(`  ${side}: ${pick(['framesEncoded', 'fragsSent', 'framesOut', 'paritySent', 'fecRepaired',
      'fecUnrepairable', 'framesGapped', 'parityUnused', 'framesLost', 'fragsLate',
    // ageP50/ageP95 span post-encode -> ready-to-decode only, so they are the
    // TRANSPORT half of the glass-to-glass number. Subtracting ageP95 from the
    // reported p95 says whether a tail is the network (retransmit, FEC hold) or
    // everything else (capture, encode, decode, paint) — the attribution that a
    // lever scan under loss kept failing to make.
    // fecHoldExpired / fragReqSent name the two mechanisms that can put a
    // several-hundred-ms step in the tail: the hold deadline giving up at
    // l2FecHoldMs (250), and the two-phase re-splice costing l2RetxWaitMs + 1 RTT
    // (120 + 80 = 200 here). Without them a p95 excursion is only a number.
      'keyReqSent', 'skipBuffered', 'fecHoldExpired', 'fragReqSent', 'retxSent',
      'ageP50', 'ageP95'])}`);
    // The v-presenter's own schedule state. `shift` is the servo's accumulated
    // phase pull in slots (<= 0, bounded at -30): it is the ONLY mechanism that
    // removes the VP_D_SLOTS anchor latency, and every late-frame resync sets it
    // back to 0. glass-to-glass minus ageP50 is the presentation cost this
    // explains, so print them together.
    if (v.vp) console.log(`  ${side.padEnd(12)} vp: ${JSON.stringify(v.vp)}`);
    // The ACTUAL presentation path whenever avsync engages — vpTick() bails on
    // `avEngaged`, so the v-presenter above can read 16 presents in 90 s and tell
    // you nothing. avOffP50 is the applied audio-lead: video is paced to the audio
    // playhead, so if the audio jitter buffer grows under loss, video is dragged
    // out with it and inherits a ratchet that is not ours.
    console.log(`  ${side.padEnd(12)} av: ${pick(['avPresents', 'avHolds', 'avDrops',
      'avSkips', 'avOffP50', 'avOffP95'])}`);
    // §12-13. The stall classifier can take video off the wire entirely: on a
    // sustained deficit the RECEIVER sends LANE_SHED, the SENDER stops admitting
    // captures, and lane P's 1 fps stills carry presence until a resume probe
    // succeeds. A call that spends 40 s in `held` looks, to every counter above,
    // like a call whose presenter starved -- avHolds high, avPresents low, no
    // drops -- with nothing naming the cause. `transitions` is that name: each
    // entry is { t: ms since arm, from, to, why }, so a collapse either has a
    // `to: "held"` in it or the stall machine is innocent. It has been in the
    // snapshot since the classifier shipped and was never printed, which is why
    // two captured collapses could be described but not attributed.
    if (v.stall) {
      const tr = v.stall.transitions ?? [];
      const heldMs = tr.reduce((acc, x, i) => acc + (x.to === 'held' ? ((tr[i + 1]?.t ?? SEC * 1000) - x.t) : 0), 0);
      console.log(`  ${side.padEnd(12)} stall: regime ${v.stall.regime}  shedded ${v.stall.shedded}` +
        `  lpAgeP50 ${v.stall.lpAgeP50}  ${pick(['shedSent', 'resumeSent', 'skipShed', 'shedSkipped',
          'shedPurged', 'shedDroppedEnc', 'shedStaleKey', 'shedDeadman',
          'lpSent', 'lpRecv', 'lpPainted', 'skipPaced', 'admitFps'])}` +
        // Still size decides the FLOOR on lane-P age, and lane-P age is the resume
        // gate. A 70 KB still on a link with 1 Mbps spare cannot arrive in under
        // 560 ms, so a fixed 250 ms bar is unreachable by arithmetic -- print the
        // bytes next to the age so the two are never compared by eye alone.
        (v.lpSent ? `  lpKBmean ${(v.lpBytes / v.lpSent / 1024).toFixed(1)}` : '') +
        (heldMs > 0 ? `\n  ${' '.repeat(12)} stall: HELD ${(heldMs / 1000).toFixed(1)} s of the call` : '') +
        (tr.length ? `\n  ${' '.repeat(12)} stall: ${tr.map((x) => `${(x.t / 1000).toFixed(1)}s ${x.from}->${x.to} (${x.why})`).join('  |  ')}` : ''));
    }
  }
}
for (const e of [A, B]) await e.c.close();

// A's own preview is the sender reference: the element on A carrying the most
// decoded samples is whichever tile is showing A's camera at full rate.
for (const k of Object.keys(ra)) ra[k] = ra[k].filter((r) => r.src === 0);
const aKeys = Object.keys(ra).filter((k) => ra[k].length).sort((x, y) => ra[y].length - ra[x].length);
if (!aKeys.length) { console.log('No timecode decoded on the sender at all — the fixture never reached the page.'); process.exit(1); }
const sender = ra[aKeys[0]];
console.log(`sender reference: "${aKeys[0]}" (${sender.length} samples)\n`);

console.log('candidates on the receiving page:');
const rows = [];
for (const [key, arrAll] of Object.entries(rb)) {
  const arr = arrAll.filter((r) => r.src === 0).length ? arrAll.filter((r) => r.src === 0) : arrAll;
  const s = stats(sender, arr);
  if (!s) { console.log(`  ${key.padEnd(30)} too few matched samples (${arr.length})`); continue; }
  const srcs = [...new Set(arr.map((r) => r.src))];
  const phase = !srcs.includes(0); // sender A is src=0; anything else is B's own camera
  rows.push({ key, ...s, phase });
  console.log(`  ${key.padEnd(30)} src=${srcs.join('/')}  p50 ${String(s.p50).padStart(7)}  p95 ${String(s.p95).padStart(7)}` +
              `  spread ${String(s.spread).padStart(6)}  ${s.res}  ${s.fps} fps  cov ${s.cov}%` +
              `  ${phase ? '<-- REJECTED: carries B\'s own source tag, this is the self-view' : ''}`);
}
const real = rows.filter((r) => !r.phase).sort((a, b) => b.n - a.n)[0];
console.log('\n=== result ===');
if (!real) {
  console.log(`${label}: NO valid remote tile found.`);
  console.log('Every candidate was either undecodable or a constant offset with no jitter.');
  console.log('That means the two browsers were not in one call. Do not report a number from this run.');
  process.exit(3);
}
console.log(`${label}: glass-to-glass p50 ${real.p50} ms, p95 ${real.p95} ms, ${real.res}`);
console.log(`(from ${real.n} matched frames on "${real.key}"; spread ${real.spread} ms is a real network path, not fixture phase)`);
// The ratchet test. Flat thirds mean the number above is a latency; a rising set
// means it is an average over a call that was getting worse, and the honest figure
// to quote is the last third, not the median.
const [t1, t2, t3] = real.thirds;
console.log(`p50 by third of run: ${t1} -> ${t2} -> ${t3} ms` +
  (t1 != null && t3 != null && t3 - t1 > 25 ? `   <-- RATCHET: +${(t3 - t1).toFixed(1)} ms across the call` : ''));
// Frames decoded travel with the latency: a window that dropped nearly
// everything shows a flattering p50 off whatever survived.
console.log('video glass-to-glass by 10 s window (p50 ms / frames decoded):');
console.log('  ' + (real.windows ?? []).map((w) => `${String(w.t).padStart(3)}s ${String(w.p50 ?? '-').padStart(6)}/${String(w.n).padStart(4)}`).join('\n  '));
console.log(`timecode: ${real.range}-frame fixture loop, ${real.wraps} wraps unwrapped` +
  (real.wraps === 0 && SEC > real.range / 30
    ? '  <-- SUSPECT: run is longer than the loop but nothing wrapped; the sample is truncated at the first repeat'
    : ''));
// Say what this number is NOT. The rig decodes one frame per rAF tick, so its
// frame rate is the SAMPLER's ceiling, not the video's — the sender's own preview
// decodes at the same rate. Useful to compare between services, useless as an
// absolute fps claim, and quotable as a floor only.
console.log(`distinct frames decoded/s: ${real.fps} (rig sampling floor — the sender's own preview decodes at the same rate; not the video's frame rate)`);
// What the emulator ACTUALLY did, as opposed to what it was asked to do. The
// injected loss is `dropped`; `sendErrors` (ENOBUFS and friends) and
// `unreachable` are the emulator failing to carry traffic it was built to carry,
// and they land in the results as if the network had lost the packets. Printing
// the realised rate next to the requested one is the only way a run can say "you
// asked for 5% and the path delivered 13%". Never inferred from application
// counters -- those cannot tell an injected drop from a harness one.
if (sim) {
  const s = sim.stats;
  const offered = s.sent + s.dropped + s.bwDropped + s.sendErrors + s.unreachable;
  const rate = (n) => (offered ? ((100 * n) / offered).toFixed(2) : '0.00');
  console.log(`netsim actual: offered ${offered}  delivered ${s.sent}` +
    `  dropped ${s.dropped} (${rate(s.dropped)}%, asked ${SIM_LOSS}%)` +
    `  bwDropped ${s.bwDropped} (${rate(s.bwDropped)}%)` +
    `  sendErrors ${s.sendErrors} (${rate(s.sendErrors)}%)` +
    `  unreachable ${s.unreachable}` +
    // Was the shaper ACTUALLY binding? bwDropped only counts queue OVERFLOW, so
    // it reads 0 on a link that is queueing heavily but never spilling — and a
    // `--bw` run that never shaped is an unverified claim about the condition
    // under test, not a shaped run. Queue delay is the honest witness.
    (() => {
      const q = sim.queueDelay?.();
      if (!q) return '';
      // onQueueMs fires only for packets that actually went through the queue,
      // so `n` is how many ever waited. The shaper here binds in BURSTS -- at
      // --bw=1.0 the median and p95 are both 0 while max is ~98 ms -- so p50/p95
      // are the wrong test for "did it shape". Judge on n and max. (n saturates
      // at 8000 samples per proxy, so read it as a floor on a long run.)
      // Scheduler lateness, printed NEXT TO the queue because the two together
      // are the only honest statement of what the rig actually delivered.
      // bwQueue cannot exceed --queue by construction (packets past it are
      // dropped, not held), so a 98 ms max there is not evidence the path was
      // only 98 ms slow. `lateness` is how much longer than promised the delay
      // line actually held real datagrams -- unmodeled delay, all of it charged
      // to the app under the heading of network conditions. At --bw=0.3 the
      // token bucket adds ~37k extra timers, which is exactly when a
      // setTimeout-based delay line stops being punctual.
      return ((l) => l ? `\n  rigLate: n ${l.n}  p50 ${l.p50} ms  p95 ${l.p95} ms  p99 ${l.p99} ms  max ${l.max} ms` +
        (l.p99 > 20 ? '   <-- THE RIG IS ADDING DELAY IT DOES NOT REPORT AS NETWORK' : '') : '')(sim.lateness?.()) +
      `\n  bwQueue: queued ${q.n} pkts  p50 ${q.p50} ms  p95 ${q.p95} ms  max ${q.max} ms` +
        (q.max < 5
          ? '   <-- shaper NEVER BOUND: treat this run as uncapped'
          : q.p95 < 1 ? '   (binds in bursts only — sustained rate is under the cap)' : '');
    })() +
    (s.sizes ? `\n  sizes: tiny<120B ${s.sizes.tiny}  small<600B ${s.sizes.small}  mid<1100B ${s.sizes.mid}  full>=1100B ${s.sizes.full}` +
      `  meanB ${(s.bytes / Math.max(1, s.sent)).toFixed(0)}` : '') +
    (Object.keys(s.errCodes ?? {}).length ? `  errCodes ${JSON.stringify(s.errCodes)}` : '') +
    (s.sendErrors + s.unreachable > 0.005 * offered
      ? `\n  <-- HARNESS LOSS: the emulator failed to carry ${rate(s.sendErrors + s.unreachable)}% of the` +
        ` offered packets. The condition under test was harsher than the label; treat this run's loss figures as void.`
      : ''));
}
await sim?.stop?.();
