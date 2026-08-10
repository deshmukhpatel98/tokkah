/**
 * A measurement rig that is calibrated, and that says so when it is not.
 *
 * ─── WHY ──────────────────────────────────────────────────────────────────────
 * This project's rigs have not mostly been wrong about the product. They have been
 * wrong about THEMSELVES, and every time the wrong answer looked good:
 *
 *   - `--secs=` never matched `--sec=`; every run silently took the default.
 *   - `q.concealPct ?? '-'` printed a dash for 400 s because that field has never
 *     existed. A dash reads exactly like a measured zero.
 *   - Float32 in the jitter ring made every spread come out 0.0; the estimator ran
 *     blind for a whole deploy and it looked like "latency is flat under loss".
 *   - `?? 0` on a null clock offset produced a 637 ms "age" on an 80 ms call.
 *   - `bwDropped` read 0 both when the shaper never bound and when it bound hard.
 *   - The rig reported 1080p from a 720p camera and nobody checked, because the
 *     number was flattering.
 *   - "connected" was true while the remote surface was 0x0 and frozen.
 *   - Both endpoints share one laptop, so the "network jitter" it measures can be
 *     its own scheduler — and a 314 ms spread pinned the buffer at its ceiling.
 *
 * The common shape: an instrument returned a plausible number instead of an error.
 * So this rig's contract is not "measure well". It is:
 *
 *     EVERY NUMBER IS EITHER MEASURED, OR IT SAYS WHY IT IS NOT.
 *     NO NUMBER MAY BE PLAUSIBLE-BUT-WRONG.
 *
 * Enforced structurally, not by care:
 *   1. Unknown flag -> exit 2.                     (the --secs= class)
 *   2. Missing snapshot field -> throw.            (the concealPct class)
 *   3. Preflight proves each instrument can SEE before anything is measured, and
 *      a failed check ABORTS. There is no "warning, continuing anyway" — that is
 *      how a blind instrument publishes numbers.
 *   4. The rig measures its own starvation (scheduler lag inside each page) and
 *      marks timing metrics UNTRUSTED when it cannot tell network from CPU.
 *   5. Run-scoped extremes and last-third windows are reported separately, never
 *      merged into one "average" that hides a ratchet.
 *   6. Latency is never printed without delivery beside it.
 *   7. Provenance on every row: how it was measured, over what window, what would
 *      confound it.
 *
 *   node testbed/rig.mjs [--sec=90] [--engines=cc|cw|wc] [--every=10]
 *                        [--query=tape=2] [--base=URL] [--shots] [--json=PATH]
 *
 *   --engines  cc = Chromium+Chromium (default), cw = Chromium first then WebKit,
 *              wc = WebKit first then Chromium. Cross-engine costs the custom
 *              video lane (WebKit lacks MediaStreamTrackProcessor) but is the only
 *              way to exercise the fallback that once shipped a black screen.
 *
 * NOT CLAIMED: this is two browsers on one host against production signalling.
 * It is not a real internet path, and Playwright's WebKit is not Safari. Those
 * limits are printed in the report rather than left to be forgotten.
 */
import { webkit, chromium } from '/Users/deveshpatel/Downloads/video calling/testbed/node_modules/playwright-core/index.mjs';
import os from 'node:os';
import fs from 'node:fs';

const CHROME = process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const CAM = '/Users/deveshpatel/Downloads/video calling/testbed/media/cam1080.mjpeg';
const AUD = '/Users/deveshpatel/Downloads/video calling/testbed/media/conv/A.wav';
const OUT = '/Users/deveshpatel/Downloads/video calling/testbed/out';

// ─── flags: unknown is fatal ────────────────────────────────────────────────────
const KNOWN = new Set(['sec', 'engines', 'every', 'query', 'base', 'shots', 'json', 'wait', 'noprobe']);
for (const a of process.argv.slice(2)) {
  const m = /^--([a-z]+)(=|$)/.exec(a);
  if (!m || !KNOWN.has(m[1])) {
    console.error(`unknown flag: ${a}\nknown: ${[...KNOWN].map((k) => '--' + k).join(' ')}`);
    process.exit(2);
  }
}
const arg = (k, d) => {
  const m = process.argv.find((a) => a.startsWith(`--${k}=`));
  return m ? m.slice(k.length + 3) : d;
};
const SEC = Number(arg('sec', 90));
const EVERY = Number(arg('every', 10));
const ENGINES = arg('engines', 'cc');
const QUERY = arg('query', 'tape=2');
const BASE = arg('base', 'https://room.tokkah.com');
const JSON_OUT = arg('json', null);
const WAIT = Number(arg('wait', 240)); // seconds to wait for host headroom before giving up
const WANT_SHOTS = process.argv.includes('--shots');
// --noprobe: the ABLATION arm. Skips the two probes that do real work inside the
// live call (spareCapacity hogs the main thread by design; cadence runs an rAF +
// canvas-readback loop). If a multi-second freeze survives --noprobe, the freeze is
// not those probes. Keeps schedLag, which is a 4 ms timer and costs nothing, because
// without it there is no calibration and nothing below may be quoted.
const NOPROBE = process.argv.includes('--noprobe');
if (!['cc', 'cw', 'wc'].includes(ENGINES)) { console.error(`--engines must be cc|cw|wc`); process.exit(2); }
if (!Number.isFinite(SEC) || SEC < 20) { console.error('--sec must be a number >= 20 (the estimator needs a full window plus warm-up)'); process.exit(2); }

/**
 * How long the estimator's peak-hold remembers a spread of `ms`.
 *
 * The release is 0.25 ms per 250 ms tick = **1 ms of spread per second**, so the hold
 * time in SECONDS is numerically the spread in MILLISECONDS. That identity is a units
 * trap: this line previously read `(ms / 1000).toFixed(0)`, converting ms to s as if
 * the rate were dimensionless, and printed "the peak-hold keeps it for 0+ s" for a
 * 60.3 ms hole whose true hold is ~60 s. Wrong by 1000x, and small enough to look
 * like a rounded zero rather than an error.
 */
const JIT_RELEASE_MS_PER_S = 1;
const holdSecs = (ms) => (ms == null ? 'unknown (spread absent)' : (ms / JIT_RELEASE_MS_PER_S).toFixed(0));

// ─── the honesty primitives ─────────────────────────────────────────────────────
/** Reading a field that does not exist is a BUG, not a missing datum. */
function need(o, k, where) {
  if (o == null) throw new Error(`${where}: object is ${o}, cannot read "${k}"`);
  if (o[k] === undefined) {
    throw new Error(`${where}: field "${k}" does not exist. Available: ${Object.keys(o).slice(0, 40).join(', ')}`);
  }
  return o[k];
}
/** A value that is legitimately absent is labelled, never defaulted to 0 or '-'. */
const ABSENT = Symbol('absent');
const show = (v) => (v === ABSENT ? 'ABSENT' : v === null ? 'null' : String(v));

const checks = [];
function check(name, why, fn) { checks.push({ name, why, fn }); }

// ─── browsers ───────────────────────────────────────────────────────────────────
const mkChromium = async (tag) => {
  const ctx = await chromium.launchPersistentContext('', {
    executablePath: CHROME, headless: true,
    args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
      `--use-file-for-fake-video-capture=${CAM}`, `--use-file-for-fake-audio-capture=${AUD}`,
      '--autoplay-policy=no-user-gesture-required'],
    viewport: { width: 1000, height: 700 },
  });
  return { ctx, page: await ctx.newPage(), engine: 'Chromium', tag };
};
const mkWebKit = async (tag) => {
  const browser = await webkit.launch({ headless: true });
  const ctx = await browser.newContext({ permissions: ['camera', 'microphone'], viewport: { width: 1000, height: 700 } });
  return { ctx, browser, page: await ctx.newPage(), engine: 'WebKit', tag };
};

// ─── instruments ────────────────────────────────────────────────────────────────
/**
 * Luma mean/sd of whichever remote surface is live. sd ~0 is a black or flat
 * frame; a real picture is > 8. Gates on PIXELS because the bug this replaces
 * rendered a valid one-black-pixel frame while every counter read healthy.
 */
const luma = (p, id) => p.evaluate((sel) => {
  const grab = (el, w, h) => {
    const c = document.createElement('canvas'); c.width = 64; c.height = 36;
    const g = c.getContext('2d', { willReadFrequently: true });
    try { g.drawImage(el, 0, 0, 64, 36); } catch { return { err: 'drawImage threw (tainted or not ready)' }; }
    const d = g.getImageData(0, 0, 64, 36).data;
    let s = 0, s2 = 0, n = 0, fnv = 2166136261;
    for (let i = 0; i < d.length; i += 4) {
      const y = 0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2]; s += y; s2 += y * y; n++;
      // PER-PIXEL hash, for the liveness check. A global mean/sd is nearly invariant
      // to real motion: a talking head sitting still measured 128.9 -> 128.9 and
      // 65.4 -> 65.4 across 600 ms, and the "camera is FROZEN" preflight fired on a
      // perfectly live fixture. Any single changed pixel changes this.
      fnv ^= d[i]; fnv = (fnv * 16777619) >>> 0;
    }
    const m = s / n;
    return { src: el.id, w, h, hash: fnv,
      mean: +m.toFixed(1), sd: +Math.sqrt(Math.max(0, s2 / n - m * m)).toFixed(1) };
  };
  if (sel) { const e = document.getElementById(sel); return e ? grab(e, e.videoWidth || e.width, e.videoHeight || e.height) : { err: `#${sel} absent` }; }
  const rc = document.getElementById('remoteCanvas');
  if (rc && rc.width > 1) return grab(rc, rc.width, rc.height);
  const v = document.getElementById('remote');
  if (v && v.videoWidth > 0) return grab(v, v.videoWidth, v.videoHeight);
  return { src: rc ? 'remoteCanvas' : 'remote', w: v?.videoWidth ?? 0, h: v?.videoHeight ?? 0, mean: null, sd: null };
}, id ?? null);

/**
 * THE CALIBRATION THAT MATTERS. Both endpoints share one laptop, so "network
 * jitter" measured here can be this machine's own scheduler. A 314 ms arrival
 * spread pinned the audio buffer at its 15-frame ceiling for an entire run, and
 * there was no way to tell whether the link or the host caused it.
 *
 * So measure the host directly, from inside the page: schedule a timer every 4 ms
 * for `ms`, and record how LATE each firing is. A page that cannot service a 4 ms
 * timer cannot be trusted to timestamp packet arrivals either — its jitter
 * measurement is its own starvation. p95 lateness is the number that decides
 * whether this run's timing metrics mean anything.
 */
const schedLag = (p, ms = 2000) => p.evaluate((dur) => new Promise((res) => {
  const STEP = 4, late = [];
  let prev = performance.now();
  const t0 = prev;
  const id = setInterval(() => {
    const now = performance.now();
    late.push(now - prev - STEP);
    prev = now;
    if (now - t0 >= dur) {
      clearInterval(id);
      const s = late.filter((x) => x > 0).sort((a, b) => a - b);
      const q = (f) => (s.length ? +s[Math.min(s.length - 1, Math.floor(f * s.length))].toFixed(1) : 0);
      res({ n: late.length, p50: q(0.5), p95: q(0.95), max: s.length ? +s[s.length - 1].toFixed(1) : 0 });
    }
  }, STEP);
}), ms);

/**
 * THE FOURTH COLUMN: what the call COSTS the machine.
 *
 * Prompted by a real observation, not a hunch: during a live Safari call this
 * project's app held a WebKit content process at 86-103% of a core, for 1:1 video.
 * That matters three ways and none of them were measurable before:
 *   - "cheapest per minute" is not only bandwidth; a hot CPU is battery and heat
 *   - a fan-loud laptop is the opposite of "feels like being in the room"
 *   - a saturated main thread sends packets at ragged intervals, which is a
 *     candidate cause of the 314 ms arrival spread seen from a WebKit peer while
 *     Chromium-to-Chromium measured 45-56 ms
 *
 * Method: a fixed chunk of arithmetic, re-posted through a MessageChannel so it
 * yields to the event loop between chunks and the app's own tasks interleave.
 * MessageChannel rather than setTimeout on purpose — setTimeout is clamped to a few
 * ms, so its count would be dominated by the clamp instead of by contention. Count
 * chunks completed in a wall-clock window, take a BASELINE before joining, and the
 * shortfall during the call is the app's share of the main thread.
 *
 * Honest limits, both reported: this probe competes for the same thread, so it
 * perturbs slightly what it measures; and it sees the MAIN thread only — the
 * AudioWorklet and any workers are invisible to it, so a low number here does not
 * mean the call is cheap overall.
 */
const spareCapacity = (p, ms = 1200) => p.evaluate((dur) => new Promise((res) => {
  const ch = new MessageChannel();
  let units = 0, sink = 0;
  const t0 = performance.now();
  ch.port1.onmessage = () => {
    let x = 0;
    for (let i = 1; i < 40000; i++) x += Math.sqrt(i);
    sink += x; units++;
    if (performance.now() - t0 < dur) ch.port2.postMessage(0);
    else res({ units, ms: +(performance.now() - t0).toFixed(0), sink: sink > 0 });
  };
  ch.port2.postMessage(0);
}), ms);

/**
 * THE THIRD COLUMN. Latency and delivery have both been measured on this project
 * for months; CADENCE never has. A pipeline can hold a good average latency and
 * deliver every frame, and still hitch once a second — and no existing metric here
 * would show it. Judder is what reads as "a video call" rather than "a person", so
 * it is the metric closest to the actual goal.
 *
 * Measured off the compositor, not off our own counters: count requestAnimationFrame
 * presentations, and for each one ask whether the remote surface CHANGED. Two things
 * come out of that, and they are different questions:
 *
 *   displayHz  - how fast this screen actually repaints (no browser API reports it;
 *                counting rAF is the measurement). Needed before "match the
 *                receiver's refresh rate" can mean anything.
 *   holdRuns   - how many refreshes each delivered frame was held for. On a clean
 *                30-into-120 cadence every run is exactly 4. A mix of 4s and 5s IS
 *                the judder, and the SPREAD of run lengths is its magnitude.
 *
 * Change detection is a cheap hash of a 16x9 downscale. It can miss a frame whose
 * content is identical to its predecessor (a static scene), which would inflate the
 * hold runs — so `changed` is reported alongside, and a scene with no motion is
 * declared UNMEASURABLE rather than scored as perfect.
 */
const cadence = (p, ms = 3000) => p.evaluate((dur) => new Promise((res) => {
  const rc = document.getElementById('remoteCanvas');
  const v = document.getElementById('remote');
  const el = rc && rc.width > 1 ? rc : (v && v.videoWidth > 0 ? v : null);
  if (!el) return res({ err: 'no remote surface' });
  const c = document.createElement('canvas'); c.width = 16; c.height = 9;
  const g = c.getContext('2d', { willReadFrequently: true });
  const stamps = [], runs = [];
  let prevHash = null, run = 0, frames = 0, changed = 0, t0 = null;
  const tick = (ts) => {
    if (t0 === null) t0 = ts;
    stamps.push(ts);
    let h = 0;
    try {
      g.drawImage(el, 0, 0, 16, 9);
      const d = g.getImageData(0, 0, 16, 9).data;
      // FNV-ish over the downscale. Collisions would UNDER-count change, which
      // biases toward reporting judder that is not there — the safe direction.
      h = 2166136261;
      for (let i = 0; i < d.length; i += 4) { h ^= d[i]; h = (h * 16777619) >>> 0; }
    } catch { return res({ err: 'drawImage threw' }); }
    frames++;
    if (prevHash !== null && h !== prevHash) { changed++; runs.push(run); run = 1; } else run++;
    prevHash = h;
    if (ts - t0 < dur) requestAnimationFrame(tick); else {
      const span = (stamps[stamps.length - 1] - stamps[0]) / 1000;
      const hz = span > 0 ? +((stamps.length - 1) / span).toFixed(1) : null;
      const r = runs.slice(1); // first run is a partial
      if (r.length < 4) return res({ displayHz: hz, refreshes: frames, changed, err: 'too few frame changes to score cadence (static scene?)' });
      const mean = r.reduce((a, b) => a + b, 0) / r.length;
      const sd = Math.sqrt(r.reduce((a, b) => a + (b - mean) ** 2, 0) / r.length);
      const sorted = [...r].sort((a, b) => a - b);
      // ── scoring, and the trap this avoids ─────────────────────────────────────
      // The FIRST version of this scored "fraction of runs not equal to the modal
      // run length" and duly reported 35-50% "hitching" on a clean local call. That
      // was the instrument measuring itself: headless Chromium has no panel, rAF
      // came out at 68 and 72 Hz, and 68/30 = 2.27 is not an integer — so even a
      // PERFECT pipeline must alternate 2s and 3s, with frac(2.27) = 27% of frames
      // necessarily off the mode. An alarming number is no more trustworthy than a
      // flattering one.
      //
      // So report the part that the ratio cannot explain. With ratio r, a perfect
      // pipeline emits only floor(r) and ceil(r), and the share of ceil(r) is
      // exactly frac(r). Two honest figures come out of that:
      //   offRatio  - runs OUTSIDE [floor(r), ceil(r)]. Zero for any perfect
      //               pipeline at any ratio, integer or not. This is the clean
      //               judder signal and needs no baseline.
      //   excess    - observed off-mode share minus the unavoidable frac(r).
      // THE DISCRIMINATOR. Frame-hold irregularity has two possible causes and they
      // need opposite fixes: our delivery is bursty, or the COMPOSITOR is hitching
      // and every hold measured through it inherits that. So score rAF's own
      // intervals, which are independent of video content entirely. Clean rAF plus
      // ragged holds = our pipeline. Ragged rAF = this measurement is contaminated
      // and must not be quoted, however alarming it looks.
      const dt = [];
      for (let i = 1; i < stamps.length; i++) dt.push(stamps[i] - stamps[i - 1]);
      const dtMean = dt.reduce((a, b) => a + b, 0) / dt.length;
      const dtSorted = [...dt].sort((a, b) => a - b);
      const dtP95 = dtSorted[Math.floor(0.95 * dtSorted.length)];
      // A frame's worth of overshoot on a single refresh means the compositor
      // skipped a beat; anything above that and hold counts are its artefact.
      const rafRagged = dtP95 > 1.6 * dtMean;
      const lo = Math.floor(mean), hi = Math.ceil(mean), fr = mean - lo;
      const modal = fr < 0.5 ? lo : hi;
      const offMode = r.filter((x) => x !== modal).length / r.length;
      const unavoidable = fr < 0.5 ? fr : 1 - fr;
      const offRatio = r.filter((x) => x < lo || x > hi).length / r.length;
      return res({
        displayHz: hz, refreshes: frames, changed, runs: r.length,
        holdMean: +mean.toFixed(2), holdSd: +sd.toFixed(2),
        holdMin: sorted[0], holdMax: sorted[sorted.length - 1],
        effectiveFps: hz && mean ? +(hz / mean).toFixed(1) : null,
        ratioBand: `${lo}-${hi}`,
        offMode: +offMode.toFixed(3),
        unavoidable: +unavoidable.toFixed(3),
        excess: +Math.max(0, offMode - unavoidable).toFixed(3),
        // THE metric. Any nonzero value is irregularity no refresh ratio can excuse.
        offRatio: +offRatio.toFixed(3),
        // Headless has no panel: rAF is a software compositor at a drifting rate, so
        // displayHz here is NOT a monitor refresh rate and must not be read as one.
        displayHzIsReal: false,
        rafMeanMs: +dtMean.toFixed(2), rafP95Ms: +dtP95.toFixed(2),
        rafMaxMs: +dtSorted[dtSorted.length - 1].toFixed(2), rafRagged,
        // Holds of exactly 1 are unambiguous: two distinct frames presented on
        // consecutive refreshes, i.e. a burst. Unlike long holds, this cannot be
        // produced by change-detection missing a near-identical frame.
        burstFrac: +(r.filter((x) => x === 1).length / r.length).toFixed(3),
      });
    }
  };
  requestAnimationFrame(tick);
}), ms);

/**
 * Both sides' own numbers, read out of the page. Concealment is COMPUTED from
 * playedFrames/lostFrames; there is no concealPct field and asking for one printed
 * a dash for a whole run. `raw` is kept so the report can prove provenance.
 */
const snap = (p) => p.evaluate(() => {
  const t = window.__tape ?? {};
  return {
    hasTape: !!window.__tape,
    pcm: t.pcm ?? null, video: t.video ?? null, tapeMode: t.tapeMode ?? null,
    status: document.getElementById('status')?.textContent ?? null,
    preview: (() => { const v = document.getElementById('preview'); return v ? { w: v.videoWidth, h: v.videoHeight } : null; })(),
  };
});

/** Concealment, from the fields that exist. Throws rather than guessing. */
function conceal(pcm, where) {
  const played = need(pcm, 'playedFrames', where), lost = need(pcm, 'lostFrames', where);
  if (typeof played !== 'number' || typeof lost !== 'number') return ABSENT;
  if (played + lost === 0) return ABSENT; // no frames is NOT zero concealment
  return +((100 * lost) / (played + lost)).toFixed(3);
}

// ─── preflight ──────────────────────────────────────────────────────────────────
check('chrome-binary', 'playwright install once deleted chromium-1228 and moved every hardcoded path', () => {
  if (!fs.existsSync(CHROME)) throw new Error(`Chrome for Testing not at ${CHROME} — check ~/Library/Caches/ms-playwright`);
  return 'present';
});
check('fixtures', 'a fixture that starves the camera looks exactly like a failing encoder', () => {
  for (const f of [CAM, AUD]) if (!fs.existsSync(f)) throw new Error(`fixture missing: ${f}`);
  const cam = fs.statSync(CAM).size;
  // Declared, not discovered later: the timecode fixture repeats every 256 frames
  // (~8.5 s at 30fps), so anything longer than that is re-measuring the same frames.
  return `cam ${(cam / 1e6).toFixed(1)} MB; note timecode-class fixtures loop every 256 frames (~8.5 s)`;
});
check('deploy-fresh', 'a far side on an older bundle reported wastedShift undefined for a whole run', async () => {
  const local = fs.readFileSync('/Users/deveshpatel/Downloads/video calling/tape-app/public/pcm.js', 'utf8');
  const r = await fetch(`${BASE}/pcm.js?cb=${Date.now()}`);
  if (!r.ok) throw new Error(`GET ${BASE}/pcm.js -> ${r.status}`);
  const dep = await r.text();
  if (dep !== local) {
    const dl = dep.length, ll = local.length;
    throw new Error(`deployed pcm.js differs from local (${dl} vs ${ll} bytes). Deploy first, or the run measures old code. Note the edge cache serves stale for a few seconds after deploy — retry once.`);
  }
  return `deployed pcm.js == local (${local.length} B)`;
});
check('host-headroom', 'both endpoints share one CPU; a saturated host manufactures jitter', async () => {
  const cores = os.cpus().length;
  const per = () => os.loadavg()[0] / cores;
  // WAIT rather than refuse. The gate itself is right and is not negotiable — but
  // load average is a 1-minute trailing figure, so it stays high for a while after
  // a previous run's browsers exit even though the CPU is already free, and a hard
  // abort there just means babysitting. Waiting keeps the standard and lets runs be
  // queued back to back. Lowering the threshold to get a run would be the wrong fix.
  const t0 = Date.now();
  let first = per();
  while (per() > 0.7 && Date.now() - t0 < WAIT * 1000) {
    const el = ((Date.now() - t0) / 1000).toFixed(0);
    process.stdout.write(`\r        waiting for host headroom: ${(per() * 100).toFixed(0)}% used, ${el}s/${WAIT}s   `);
    await new Promise((r) => setTimeout(r, 10000));
  }
  process.stdout.write('\r' + ' '.repeat(70) + '\r');
  if (per() > 0.7) {
    throw new Error(`load average still ${os.loadavg()[0].toFixed(2)} on ${cores} cores (${(per() * 100).toFixed(0)}%) after waiting ${WAIT}s. Timing would be unmeasurable; close something, or raise --wait.`);
  }
  const waited = ((Date.now() - t0) / 1000).toFixed(0);
  return `load ${os.loadavg()[0].toFixed(2)} / ${cores} cores = ${(per() * 100).toFixed(0)}%` +
    (waited > 1 ? ` (waited ${waited}s; was ${(first * 100).toFixed(0)}%)` : '');
});

// ─── run ────────────────────────────────────────────────────────────────────────
const plan = { cc: [mkChromium, mkChromium], cw: [mkChromium, mkWebKit], wc: [mkWebKit, mkChromium] }[ENGINES];
const room = 'rig' + Math.random().toString(36).slice(2, 8);
const report = {
  meta: { room, engines: ENGINES, sec: SEC, query: QUERY, base: BASE, at: new Date().toISOString(),
          host: `${os.cpus().length} cores, ${os.platform()} ${os.release()}` },
  preflight: [], calibration: null, samples: [], verdict: null, limits: [],
  // THE INSTRUMENT'S OWN ALIBI. Wall-clock window of every thing the rig does to a
  // live page. Stalls carry absolute wall-clock stamps, so with this the report can
  // answer the question it could not answer before: was the rig busy at that instant?
  // A 3.5 s freeze blamed on the host, when it was the probe, is exactly the failure
  // this file exists to prevent — and the probes are not innocent by construction:
  // spareCapacity deliberately saturates the main thread that pcm.js reads packets on.
  activity: [],
};
/** Run fn, recording the wall-clock window it occupied. */
async function timed(name, fn) {
  const t0 = Date.now();
  try { return await fn(); }
  finally { report.activity.push({ name, t0, t1: Date.now() }); }
}

console.log(`\n${'━'.repeat(80)}\nRIG  room=${room}  engines=${ENGINES}  ${SEC}s  ${QUERY}\n${'━'.repeat(80)}`);
console.log('\nPREFLIGHT — every instrument must prove it can see. A failure aborts.\n');
for (const c of checks) {
  try {
    const detail = await c.fn();
    report.preflight.push({ name: c.name, ok: true, detail });
    console.log(`  PASS  ${c.name.padEnd(16)} ${detail}`);
    console.log(`        why: ${c.why}`);
  } catch (e) {
    report.preflight.push({ name: c.name, ok: false, detail: e.message });
    console.log(`  FAIL  ${c.name.padEnd(16)} ${e.message}`);
    console.log(`        why this check exists: ${c.why}`);
    console.log(`\nABORTED. A blind instrument must not publish numbers.`);
    if (JSON_OUT) fs.writeFileSync(JSON_OUT, JSON.stringify(report, null, 2));
    process.exit(1);
  }
}

const A = await plan[0]('A'); const B = await plan[1]('B');
let trusted = true;
try {
  for (const e of [A, B]) {
    await e.page.goto(`${BASE}/?r=${room}&${QUERY}`, { waitUntil: 'domcontentloaded' });
    await e.page.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
  }

  // ── in-page preflight: the camera must be LIVE, not a frozen first frame ──
  console.log('\nPREFLIGHT (in page)\n');
  for (const e of [A, B]) {
    const a = await luma(e.page, 'preview');
    await e.page.waitForTimeout(600);
    const b = await luma(e.page, 'preview');
    if (a.err || b.err) throw new Error(`${e.engine} preview unreadable: ${a.err ?? b.err}`);
    // Hash, not mean: see the note in grab(). The mean-based version rejected a live
    // camera because the subject was sitting still, which is the normal case.
    const moved = a.hash !== b.hash;
    const detail = `${e.engine} preview ${a.w}x${a.h} luma ${a.mean} sd ${a.sd}, frame hash ${a.hash}->${b.hash}`;
    if (a.sd < 2) throw new Error(`${detail} — preview is FLAT (sd ${a.sd}); the camera fixture is not producing a picture`);
    if (!moved) throw new Error(`${detail} — preview is FROZEN across 600 ms; a stalled fixture reads as a failing encoder`);
    console.log(`  PASS  camera-live      ${detail} (moving)`);
    report.preflight.push({ name: `camera-live-${e.tag}`, ok: true, detail });
  }

  // Cost baseline, taken BEFORE joining: the same probe on the same page with the
  // camera running but no call. Everything the call adds shows up as the shortfall.
  const base = {};
  for (const e of [A, B]) {
    base[e.tag] = await spareCapacity(e.page);
    console.log(`  BASE  cost-baseline   ${e.engine} ${base[e.tag].units} work units in ${base[e.tag].ms} ms (preview only, not in a call)`);
  }

  await A.page.click('#join');
  await A.page.waitForTimeout(700); // first occupant registers before the second
  await B.page.click('#join');
  for (const e of [A, B]) {
    await e.page.waitForFunction(() => document.querySelector('#status')?.textContent === 'connected', null, { timeout: 40000 });
  }

  // "connected" is not a picture, and it is not audio either. Prove both.
  await A.page.waitForTimeout(6000);
  for (const e of [A, B]) {
    const l = await luma(e.page);
    if (!(l.sd > 8) || !(l.w > 1)) throw new Error(`${e.engine} remote surface ${l.w}x${l.h} sd ${l.sd} — connected but no real picture`);
    console.log(`  PASS  remote-picture   ${e.engine} ${l.src} ${l.w}x${l.h} luma sd ${l.sd}`);
    const s = await snap(e.page);
    if (!s.hasTape) throw new Error(`${e.engine}: window.__tape absent — nothing can be read from this page`);
    if (s.pcm) {
      const recv = need(s.pcm, 'framesRecv', `${e.engine} pcm`);
      if (!(recv > 0)) throw new Error(`${e.engine}: framesRecv ${recv} — the audio lane is deaf, and a deaf tap reports plausible silence`);
      console.log(`  PASS  audio-live       ${e.engine} framesRecv ${recv}`);
      // A latency number taken against a null clock offset once produced a 637 ms
      // age on an 80 ms call, because `?? 0` turned "unknown" into "zero".
      const off = need(s.pcm, 'clockOffsetMs', `${e.engine} pcm`);
      console.log(`  ${off === null ? 'NOTE' : 'PASS'}  clock-offset     ${e.engine} ${show(off)}${off === null ? ' — any age/latency figure is UNTRUSTED this run' : ' ms'}`);
      if (off === null) report.limits.push(`${e.engine}: clockOffsetMs null — age/latency untrusted`);
    } else {
      console.log(`  NOTE  audio-live       ${e.engine}: PCM lane not running on this engine`);
      report.limits.push(`${e.engine}: PCM lane not running`);
    }
  }

  // ── calibration: can this host be trusted to time anything? ──
  console.log('\nCALIBRATION — the rig measures its own starvation\n');
  const lag = {};
  for (const e of [A, B]) {
    lag[e.tag] = await timed(`schedLag-${e.tag}`, () => schedLag(e.page));
    const L = lag[e.tag];
    console.log(`  ${e.engine.padEnd(9)} 4 ms timer lateness  p50 ${L.p50}  p95 ${L.p95}  max ${L.max} ms  (n=${L.n})`);
  }
  const worst = Math.max(lag.A.p95, lag.B.p95);
  trusted = worst < 20;
  report.calibration = { lag, worstP95: worst, timingTrusted: trusted };
  console.log(`\n  worst p95 scheduler lateness ${worst} ms -> timing metrics ${trusted ? 'TRUSTED' : 'UNTRUSTED'}`);
  console.log(`  ${trusted
    ? '  a page servicing 4 ms timers within 20 ms can timestamp arrivals credibly'
    : '  this host cannot service its own timers; arrival "jitter" measured here is\n    substantially this machine, not the link. Buffer/latency rows below are\n    reported but MUST NOT be quoted as product behaviour.'}`);
  if (!trusted) report.limits.push(`scheduler p95 lateness ${worst} ms — timing metrics untrusted`);

  // ── cost: what the call takes from the machine ──
  console.log(`\nCOST — the call's share of the main thread (vs the pre-join baseline)\n`);
  const cost = {};
  for (const e of [A, B]) {
    if (NOPROBE) {
      console.log(`  ${e.engine.padEnd(9)} SKIPPED (--noprobe): this probe saturates the main thread on purpose`);
      report.limits.push(`${e.engine}: main-thread cost not measured (--noprobe)`);
      continue;
    }
    const during = await timed(`spareCapacity-${e.tag}`, () => spareCapacity(e.page));
    const b = base[e.tag];
    // Normalise by measured wall time: the two windows are never exactly equal.
    const rBase = b.units / b.ms, rNow = during.units / during.ms;
    const busy = rBase > 0 ? Math.max(0, 1 - rNow / rBase) : null;
    cost[e.tag] = { base: b, during, busyPct: busy === null ? null : +(100 * busy).toFixed(1) };
    console.log(`  ${e.engine.padEnd(9)} ${during.units} units in a call vs ${b.units} idle` +
      `  -> main thread ${busy === null ? 'UNMEASURABLE' : (100 * busy).toFixed(1) + '% occupied by the call'}`);
  }
  report.calibration.cost = cost;
  console.log(`  note: main thread ONLY — the AudioWorklet and any workers are invisible here, so a`);
  console.log(`        low number does not mean the call is cheap. The probe also competes for the`);
  console.log(`        same thread, so it slightly perturbs what it measures.`);

  // ── cadence: the third column, measured off the compositor ──
  console.log(`\nCADENCE — do frames land on an even beat? (judder, not latency)\n`);
  const cad = {};
  for (const e of [A, B]) {
    if (NOPROBE) {
      console.log(`  ${e.engine.padEnd(9)} SKIPPED (--noprobe): rAF + canvas readback loop`);
      report.limits.push(`${e.engine}: cadence not measured (--noprobe)`);
      continue;
    }
    cad[e.tag] = await timed(`cadence-${e.tag}`, () => cadence(e.page));
    const c = cad[e.tag];
    if (c.err) {
      console.log(`  ${e.engine.padEnd(9)} UNMEASURABLE: ${c.err}  (displayHz ${show(c.displayHz)}, refreshes ${show(c.refreshes)}, changed ${show(c.changed)})`);
      report.limits.push(`${e.engine}: cadence unmeasurable — ${c.err}`);
      continue;
    }
    console.log(`  ${e.engine.padEnd(9)} rAF ${c.displayHz} Hz${c.displayHzIsReal ? '' : ' (headless compositor, NOT a panel refresh rate)'}` +
      `  effective ${c.effectiveFps} fps  (${c.changed} new frames / ${c.refreshes} refreshes)`);
    console.log(`            held ${c.holdMean} refreshes/frame  sd ${c.holdSd}  observed range ${c.holdMin}-${c.holdMax}` +
      `  vs ${c.ratioBand} forced by the ${c.holdMean} ratio`);
    console.log(`            off-mode ${(c.offMode * 100).toFixed(1)}%, of which ${(c.unavoidable * 100).toFixed(1)}% is unavoidable` +
      ` at this ratio -> excess ${(c.excess * 100).toFixed(1)}%`);
    console.log(`            OUTSIDE the forced band: ${(c.offRatio * 100).toFixed(1)}%  (bursts, hold==1: ${(c.burstFrac * 100).toFixed(1)}%)`);
    console.log(`            rAF interval mean ${c.rafMeanMs} ms  p95 ${c.rafP95Ms}  max ${c.rafMaxMs}  -> compositor ${c.rafRagged ? 'RAGGED' : 'steady'}`);
    if (c.rafRagged) {
      console.log(`            CONTAMINATED: rAF itself skips beats (p95 ${c.rafP95Ms} vs mean ${c.rafMeanMs} ms), so every`);
      console.log(`            hold count inherits that. The ${(c.offRatio * 100).toFixed(1)}% above is NOT attributable to our delivery.`);
      report.limits.push(`${e.engine}: cadence contaminated — rAF p95 ${c.rafP95Ms} ms vs mean ${c.rafMeanMs} ms`);
    } else if (c.offRatio <= 0.01) {
      console.log(`            even cadence: steady compositor AND every hold within the forced band`);
    } else {
      console.log(`            IRREGULAR, and attributable: the compositor is steady, yet ${(c.offRatio * 100).toFixed(1)}% of frames`);
      console.log(`            were held ${c.holdMin}-${c.holdMax} refreshes where only ${c.ratioBand} is explicable. This is our delivery.`);
    }
  }
  report.calibration.cadence = cad;

  // ── measure ──
  console.log(`\nMEASURE — every ${EVERY}s for ${SEC}s\n`);
  const t0 = Date.now();
  // Wall clock of the measure phase, and of every sample. Stalls carry absolute
  // wall-clock stamps, so without this there is no way to ask whether a 3.5 s freeze
  // landed on one of MY sampling instants — i.e. whether the harness caused it. A
  // multi-second stall attributed to the host, when it was actually the instrument,
  // would be the worst kind of finding this rig exists to prevent.
  report.meta.measureT0 = t0;
  while (Date.now() - t0 < SEC * 1000) {
    await new Promise((r) => setTimeout(r, EVERY * 1000));
    const el = +((Date.now() - t0) / 1000).toFixed(1);
    const row = { t: el, wall: Date.now(), sides: [] };
    for (const e of [A, B]) {
      const [l, s] = await timed(`sample-${e.tag}@${el}s`, () => Promise.all([luma(e.page), snap(e.page)]));
      const side = { tag: e.tag, engine: e.engine, luma: l, status: s.status, tapeMode: s.tapeMode, video: s.video };
      if (s.pcm) {
        const q = s.pcm;
        side.pcm = {
          conceal: conceal(q, `${e.engine} pcm`),
          played: need(q, 'playedFrames', 'pcm'), lost: need(q, 'lostFrames', 'pcm'),
          framesRecv: need(q, 'framesRecv', 'pcm'), late: need(q, 'late', 'pcm'),
          dup: need(q, 'dup', 'pcm'), fecRepaired: need(q, 'fecRepaired', 'pcm'),
          depthMs: need(q, 'depthMs', 'pcm'), target: need(q, 'targetFrames', 'pcm'),
          driftPpm: need(q, 'driftPpm', 'pcm'), bPerFrame: need(q, 'bPerFrame', 'pcm'),
          mbpsSent: need(q, 'mbpsSent', 'pcm'),
          spreadMaxRun: need(q, 'jitSpreadMaxRun', 'pcm'),
          spreadMaxAtMs: need(q, 'jitSpreadMaxAtMs', 'pcm'),
          spreadMaxLate: need(q, 'jitSpreadMaxLate', 'pcm'),
          warmMs: need(q, 'jitWarmMs', 'pcm'),
          wantMaxRun: need(q, 'jitWantMaxRun', 'pcm'),
          clampedTicks: need(q, 'jitClampedTicks', 'pcm'),
          rxWastedShift: need(q, 'rxWastedShift', 'pcm'),
          // Arrival PATTERN. High clump + high p95 = the sender batches.
          gapP50: need(q, 'gapP50', 'pcm'), gapP95: need(q, 'gapP95', 'pcm'),
          gapP99: need(q, 'gapP99', 'pcm'), gapClumpPct: need(q, 'gapClumpPct', 'pcm'),
          gapMaxRun: need(q, 'gapMaxRun', 'pcm'),
          stalls: need(q, 'stalls', 'pcm'),
        };
      }
      // CADENCE, the honest way — and I built the wrong instrument first. A
      // compositor-based probe (rAF holds) is contaminated in headless, where rAF
      // p95 is 2x its mean. But task #33 already put the right one in the product:
      // `presentAt` is stamped at every present site and the snapshot publishes the
      // inter-present-interval distribution. It is measured off OUR clock, which
      // the calibration above proved good to ~1 ms, so it is immune to the
      // compositor entirely. Grep before building: this existed the whole time.
      if (s.video) {
        side.ipi = {
          p50: need(s.video, 'ipiP50', 'video'), p95: need(s.video, 'ipiP95', 'video'),
          p99: need(s.video, 'ipiP99', 'video'),
        };
      }
      row.sides.push(side);
      const pic = l.sd > 8 ? 'real picture' : 'BLACK/FLAT';
      console.log(`  [t+${String(el).padStart(5)}s] ${e.engine.padEnd(9)} remote ${l.w}x${l.h} sd ${l.sd} (${pic})  lane ${JSON.stringify(s.tapeMode)}`);
      if (side.pcm) {
        const q = side.pcm;
        console.log(`             audio  conceal ${show(q.conceal)}%  recv ${q.framesRecv}  late ${q.late} dup ${q.dup} fec ${q.fecRepaired}  ${q.bPerFrame}B ${q.mbpsSent}Mbps`);
        console.log(`             buffer depth ${q.depthMs}ms target ${q.target}f drift ${q.driftPpm}ppm` +
          `  | spreadMax ${q.spreadMaxRun}ms @${show(q.spreadMaxAtMs)}ms  after-warm(${q.warmMs}ms) ${q.spreadMaxLate}ms  want ${q.wantMaxRun}f clamped ${q.clampedTicks}`);
      }
    }
    report.samples.push(row);
  }
  if (WANT_SHOTS) for (const e of [A, B]) {
    const f = `${OUT}/rig-${room}-${e.tag}-${e.engine}.png`;
    await e.page.screenshot({ path: f }); console.log(`  shot ${f}`);
  }
} catch (err) {
  report.verdict = { ok: false, err: String(err.message ?? err) };
  console.log(`\nERROR  ${report.verdict.err}`);
} finally {
  await A.ctx.close().catch(() => {}); if (A.browser) await A.browser.close().catch(() => {});
  await B.ctx.close().catch(() => {}); if (B.browser) await B.browser.close().catch(() => {});
}

// ─── report ─────────────────────────────────────────────────────────────────────
const last = (tag) => [...report.samples].reverse().map((r) => r.sides.find((s) => s.tag === tag)).find(Boolean);
const lastThird = (tag) => {
  const n = report.samples.length, from = Math.floor((2 * n) / 3);
  return report.samples.slice(from).map((r) => r.sides.find((s) => s.tag === tag)).filter(Boolean);
};
if (report.samples.length) {
  console.log(`\n${'━'.repeat(80)}\nREPORT — value, how it was measured, and what would confound it\n${'━'.repeat(80)}`);
  for (const tag of ['A', 'B']) {
    const s = last(tag); if (!s) continue;
    const third = lastThird(tag);
    console.log(`\n${s.engine} (${tag})   lane ${JSON.stringify(s.tapeMode)}   status ${s.status}`);
    console.log(`  picture      ${s.luma.w}x${s.luma.h}  luma sd ${s.luma.sd}   [pixel variance of the remote surface, final sample; a valid all-black frame reads sd~0]`);
    if (!s.pcm) { console.log('  audio        PCM lane not running on this engine  [WebKit: expected]'); continue; }
    const q = s.pcm;
    console.log(`  concealment  ${show(q.conceal)}%   [100*lost/(played+lost), run-cumulative. NOT a field — computed, because concealPct does not exist]`);
    console.log(`  delivery     recv ${q.framesRecv}  late ${q.late}  dup ${q.dup}  fecRepaired ${q.fecRepaired}   [beside latency always: a lane that drops frames wins a latency-only comparison]`);
    const k = report.calibration?.cost?.[tag];
    if (k) console.log(`  cost         main thread ${k.busyPct === null ? 'UNMEASURABLE' : k.busyPct + '% occupied'} by the call   [fixed work units completed in-call vs pre-join, same page. Main thread only — worklets invisible. A hot CPU is battery, heat, and ragged send timing]`);
    // The product's own cadence number, from presentAt. Nominal interval is 1000/fps
    // (33.3 ms at 30). p99 at ~2x nominal means a frame was held for two slots — a
    // visible hitch. Task #33's measured baseline before the v-presenter was bimodal
    // 31/62 ms with only 56-58% on-cadence; after, p95 33.3 and 96-100% on-cadence.
    if (s.ipi) {
      const nom = 1000 / 30;
      const verdict = s.ipi.p95 <= 1.25 * nom
        ? `even (p95 within 25% of the ${nom.toFixed(1)} ms nominal interval)`
        : `HITCHING (p95 is ${(s.ipi.p95 / nom).toFixed(2)}x the nominal interval)`;
      console.log(`  cadence      IPI p50 ${s.ipi.p50} / p95 ${s.ipi.p95} / p99 ${s.ipi.p99} ms -> ${verdict}`);
      console.log(`               [inter-present interval from the product's own presentAt stream, OUR clock not the compositor's. This is task #33's gate; a compositor-based probe is contaminated in headless]`);
    }
    const c = report.calibration?.cadence?.[tag];
    if (c && !c.err) {
      console.log(`  cadence      ${c.effectiveFps} fps effective at rAF ${c.displayHz} Hz; ${(c.offRatio * 100).toFixed(1)}% of frames held outside the ${c.ratioBand}-refresh band the ratio forces`);
      console.log(`               [judder column, independent of latency and delivery. The forced band is subtracted: a non-integer refresh ratio makes SOME variation unavoidable, so only the excess counts. Headless rAF is not a panel rate]`);
    } else {
      console.log(`  cadence      UNMEASURABLE${c?.err ? ` (${c.err})` : ''}   [not scored as perfect: a static scene cannot demonstrate an even beat]`);
    }
    console.log(`  lane rate    ${q.bPerFrame} B/frame  ${q.mbpsSent} Mbps   [send side, run-cumulative]`);
    console.log(`  peer depth   rxWastedShift ${q.rxWastedShift}   [trailing zeros in the PEER's samples, off the wire. 0 = their capture chain is not bit-transparent]`);
    const dep = third.map((x) => x.pcm?.depthMs).filter((v) => v != null);
    const tr = trusted ? '' : '  << UNTRUSTED, see calibration';
    console.log(`  buffer       final ${q.depthMs} ms, target ${q.target}f${tr}`);
    console.log(`               last third ${dep.length ? `${Math.min(...dep)}-${Math.max(...dep)} ms` : 'n/a'}   [quoted separately because this metric RATCHETS: a median over the whole run hides a monotone climb]`);
    // MECHANISM, not magnitude. Spread says how bad; this says which of two opposite
    // causes it was, and they need opposite fixes.
    // Thresholds RELATIVE to nominal. The first cut compared p95 against 8 ms flat
    // and therefore called a perfect lane "STRETCHED" — the nominal gap IS 8 ms
    // (one frame per FRAME_MS, striped across associations but arriving at the frame
    // rate), so p95 necessarily exceeds it. Measured clean baseline: p50 8.32,
    // p95 10.85, p99 11.53, clump 0%. Judge against that, not against zero.
    const NOM = 8;
    const clumpy = q.gapClumpPct != null && q.gapClumpPct > 25;
    const wide = q.gapP95 != null && q.gapP95 > 2 * NOM;
    const ratio = q.gapP95 != null ? (q.gapP95 / NOM).toFixed(2) : '?';
    console.log(`  arrival      gaps p50 ${show(q.gapP50)} / p95 ${show(q.gapP95)} / p99 ${show(q.gapP99)} ms, max ${q.gapMaxRun}, clumped(<1ms) ${show(q.gapClumpPct)}%`);
    // THE TAIL IS THE STORY, and the first version of this verdict missed it
    // entirely: it read p95 and clump only, and so pronounced "even arrival" on a
    // cross-engine run whose max gap was 87 ms against a clean baseline of 18.7.
    // A third mechanism exists that neither batching nor stretching describes —
    // rare isolated STALLS — and it is the one the estimator is most exposed to,
    // because `spread` is second-largest-minus-min over the window, so a single
    // 75 ms hole sets it, and the 1 ms/s peak-hold then remembers that for minutes.
    const holey = q.gapMaxRun != null && q.gapP99 != null && q.gapMaxRun > Math.max(3 * NOM, 3 * q.gapP99);
    console.log(`               p95 ${ratio}x nominal, max ${q.gapMaxRun != null && q.gapP99 ? (q.gapMaxRun / q.gapP99).toFixed(1) : '?'}x p99 -> ${
      clumpy && wide ? 'BATCHED: bursts then a hole, i.e. a SEND PACING problem, not the buffer'
      : holey ? `ISOLATED STALLS: the bulk of arrivals is clean but the tail holds a ${q.gapMaxRun} ms hole.\n               Not pacing and not clock. This is what pins the buffer: one hole sets spread,\n               and the peak-hold keeps it for ~${holdSecs(q.spreadMaxRun)} s at the measured 1 ms/s release.`
      : clumpy ? 'CLUMPED: many sub-ms arrivals but gaps otherwise tight — send-side coalescing'
      : wide ? 'STRETCHED, not clumped: gaps uniformly wide, so a rate/clock problem rather than pacing'
      : 'even arrival: gaps tight, unclumped, and no outlier holes'}`);
    console.log(`               [clean same-engine baseline for comparison: p50 8.3, p95 10.9, p99 11.5, clump 0%. Spread alone cannot separate batching from stretching: same number, opposite fixes]`);
    console.log(`  estimator    spreadMax ${q.spreadMaxRun} ms at t+${show(q.spreadMaxAtMs)} ms; after ${q.warmMs} ms warm-up the max was ${q.spreadMaxLate} ms`);
    console.log(`               wantMax ${q.wantMaxRun}f, clampedTicks ${q.clampedTicks}   [want > 15 means the ceiling bound; the target cannot express what the estimator asked for]`);
    const startupDominated = q.spreadMaxAtMs !== null && q.spreadMaxAtMs < q.warmMs && q.spreadMaxLate < q.spreadMaxRun * 0.6;
    if (startupDominated) {
      console.log(`               ^^ the run-max arrived inside the warm-up window and nothing later came close.`);
      console.log(`                  This call's buffer was sized by a STARTUP TRANSIENT, not by the link.`);
      console.log(`                  At the measured 1 ms/s release, that memory persists for ${(q.spreadMaxRun / 1000).toFixed(0)}+ s.`);
    }
  }
  // ── STALL SIMULTANEITY ────────────────────────────────────────────────────────
  // The decisive question about the cross-engine holes. Both sides stamp stalls with
  // performance.timeOrigin + performance.now(), a wall-clock epoch, so on one host
  // the two lists are directly comparable. If A's holes coincide with B's, the cause
  // is SHARED — the machine, or something both directions ride. If they are
  // independent, each receive path stalls on its own and the sender is implicated.
  // The null model matters: with a stalls on one side, b on the other, over a window
  // of W ms and a tolerance of +/-tol, coincidences expected by CHANCE are roughly
  // a*b*2*tol/W. Reporting the observed count without that is how a coincidence
  // rate of "half of them line up" gets mistaken for a mechanism.
  const sa = last('A')?.pcm?.stalls ?? [], sb = last('B')?.pcm?.stalls ?? [];
  console.log(`\nSTALL SIMULTANEITY — shared cause, or independent per direction?\n`);
  if (!sa.length && !sb.length) {
    console.log(`  no stalls over 3x nominal on either side: nothing to attribute (this is the clean case)`);
  } else {
    const TOL = 25;
    const ts = [...sa.map((x) => x.t), ...sb.map((x) => x.t)];
    const W = Math.max(1, Math.max(...ts) - Math.min(...ts));
    const paired = sa.filter((x) => sb.some((y) => Math.abs(y.t - x.t) <= TOL)).length;
    const expected = (sa.length * sb.length * 2 * TOL) / W;
    console.log(`  A (${last('A').engine}) ${sa.length} stalls, max ${sa.length ? Math.max(...sa.map((x) => x.g)) : 0} ms` +
      `   B (${last('B').engine}) ${sb.length} stalls, max ${sb.length ? Math.max(...sb.map((x) => x.g)) : 0} ms`);
    console.log(`  coincident within +/-${TOL} ms: ${paired} of ${sa.length}   (expected by chance ${expected.toFixed(1)} over a ${(W / 1000).toFixed(0)}s window)`);
    const ratio = expected > 0 ? paired / expected : (paired > 0 ? Infinity : 0);
    console.log(`  ${paired >= 3 && ratio > 3
      ? 'SHARED CAUSE: the two ends stall together far more than chance allows. Look at the host\n    or at whatever both directions ride, NOT at one sender.'
      : sa.length + sb.length >= 6 && ratio < 1.5
      ? 'INDEPENDENT: each side stalls on its own schedule. The cause is per-direction —\n    the sending path, not a shared resource.'
      : 'INCONCLUSIVE at this sample size: too few stalls to beat the chance rate. Run longer.'}`);
    const fmtS = (l) => l.slice(0, 8).map((x) => `${x.g}ms@${x.t % 100000}`).join(' ');
    if (sa.length) console.log(`  A first stalls: ${fmtS(sa)}`);
    if (sb.length) console.log(`  B first stalls: ${fmtS(sb)}`);

    // ── WAS IT ME? the instrument's own alibi ──────────────────────────────────
    // A stall is BLAMED ON THE RIG if its window overlaps a window the rig spent
    // doing something to a live page. The stall spans [t-g, t] — t is the arrival
    // that ENDED the gap, so the silence precedes it. A 25 ms slack each side
    // absorbs dispatch delay.
    const acts = report.activity;
    const SLACK = 25;
    const blame = (s) => acts.find((a) => a.t0 - SLACK <= s.t && a.t1 + SLACK >= s.t - s.g);
    const all = [...sa.map((x) => ({ ...x, side: 'A' })), ...sb.map((x) => ({ ...x, side: 'B' }))];
    const tagged = all.map((s) => ({ ...s, by: blame(s)?.name ?? null }));
    const mine = tagged.filter((s) => s.by);
    const busyMs = acts.reduce((n, a) => n + (a.t1 - a.t0), 0);
    const dutyPct = W > 0 ? (100 * busyMs) / W : 0;
    console.log(`\n  WAS IT ME? the rig was doing something to a live page for ${(busyMs / 1000).toFixed(1)}s of the ${(W / 1000).toFixed(0)}s stall window (${dutyPct.toFixed(0)}% duty)`);
    console.log(`  stalls overlapping rig activity: ${mine.length} of ${all.length}   (expected at this duty if unrelated: ${((dutyPct / 100) * all.length).toFixed(1)})`);
    if (mine.length) {
      for (const s of mine.slice(0, 10)) console.log(`    ${s.side} ${s.g} ms stall  <-  ${s.by}`);
      const big = mine.filter((s) => s.g > 200);
      if (big.length) {
        console.log(`  >>> ${big.length} stall(s) OVER 200 ms are the RIG, not the product: ${big.map((s) => `${s.g}ms/${s.by}`).join(', ')}`);
        report.limits.push(`${big.length} stall(s) >200 ms coincide with rig activity — instrument artifact, not product behaviour`);
      }
    } else if (NOPROBE) {
      console.log(`  none. With the in-call probes ablated (--noprobe) the stalls survive, so they are NOT the probes.`);
    } else {
      console.log(`  none coincide with rig activity, so the probes are not the cause of these stalls.`);
    }
    if (!NOPROBE && all.some((s) => s.g > 200)) {
      console.log(`  NEXT: re-run with --noprobe to ablate spareCapacity and cadence entirely. Overlap is`);
      console.log(`        evidence; absence of overlap at ${dutyPct.toFixed(0)}% duty is weak, and only ablation settles it.`);
    }
    report.stallBlame = { busyMs, dutyPct: +dutyPct.toFixed(1), tagged, minesN: mine.length };
  }
  report.stalls = { A: sa, B: sb };

  const pics = ['A', 'B'].map(last).filter(Boolean);
  const ok = pics.length === 2 && pics.every((s) => s.luma.sd > 8 && s.luma.w > 1);
  report.verdict = { ok, picture: pics.map((s) => ({ engine: s.engine, w: s.luma.w, h: s.luma.h, sd: s.luma.sd })), timingTrusted: trusted };
  console.log(`\n  VERDICT  ${ok ? 'PASS' : 'FAIL'} on picture (both sides show real pixel variance at the final sample)`);
  console.log(`\nLIMITS OF THIS RUN — stated so they are not forgotten:`);
  const limits = [
    'two browsers on ONE host: there is no real distance, no cross-traffic, no bufferbloat, no route change',
    'production signalling, but the media path is local — this emulates a pipeline, not the internet',
    ...(ENGINES !== 'cc' ? ["Playwright WebKit is NOT Safari: different codecs, audio stack and pacing. It shares only the missing MediaStreamTrackProcessor, which is what makes it a fair test of the FALLBACK"] : []),
    ...(trusted ? [] : ['scheduler lateness disqualifies every timing row above']),
    'n=1: this run cannot resolve small effects. For an A/B use testbed/ab.mjs interleaved at n>=8; known between-run spread on p50 here is about +/-1.7 ms',
    ...report.limits,
  ];
  for (const l of limits) console.log(`  - ${l}`);
  report.limits = limits;
}
if (JSON_OUT) { fs.writeFileSync(JSON_OUT, JSON.stringify(report, null, 2)); console.log(`\njson -> ${JSON_OUT}`); }
process.exit(report.verdict?.ok ? 0 : 1);
