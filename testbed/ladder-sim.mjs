#!/usr/bin/env node
/**
 * ladder-sim — the weak-device ladder state machine (task #37) under a Samsung
 * M13 hardware model, on a virtual clock.
 *
 * WHAT THIS PROVES AND WHAT IT DOES NOT
 * -------------------------------------
 * It runs the REAL source. The ladder, the guarded helpers, `relockCamera` and
 * the source-frame probe are SLICED OUT OF `tape-app/public/app.js` at run time
 * (by comment marker) and evaluated as-is — no copy is kept here, so this test
 * cannot drift from the shipped code. If a marker moves, the sim fails loudly
 * rather than testing a stale duplicate.
 *
 * It proves the DECISION LOGIC: trigger conditions, evaluation order, the
 * hysteresis, the one-way tier walk, the revive→re-acquire escalation, and the
 * constraint SEQUENCING rule (Chrome-Android throws OverconstrainedError when
 * ImageCapture constraints ride with stream constraints — the model throws it
 * too, so any regression here is a test failure, not a field bug report).
 *
 * It does NOT prove the physics. The camera model is phenomenological,
 * calibrated to three points measured live on the real M13 over USB in
 * session 4 (see CALIBRATION below). Any fps or luma number this sim prints is
 * a MODEL number. Device numbers come from `phone-test.sh`.
 *
 * Usage: node testbed/ladder-sim.mjs [--verbose] [--only=<scenario>]
 */
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const APP = join(HERE, '..', 'tape-app', 'public', 'app.js');
const ARGV = process.argv.slice(2);
const VERBOSE = ARGV.includes('--verbose');
const DUMP = ARGV.includes('--dump');
const ONLY = (ARGV.find((a) => a.startsWith('--only=')) || '').slice(7);

// ── Slicing the real source ──────────────────────────────────────────────────
const SRC = readFileSync(APP, 'utf8');
function slice(startMarker, endMarker, label) {
  const a = SRC.indexOf(startMarker);
  if (a < 0) throw new Error(`ladder-sim: slice start missing for ${label}: ${JSON.stringify(startMarker)}`);
  const b = SRC.indexOf(endMarker, a + startMarker.length);
  if (b < 0) throw new Error(`ladder-sim: slice end missing for ${label}: ${JSON.stringify(endMarker)}`);
  return SRC.slice(a, b);
}
const S_HELPERS = slice('function safe(fn, label) {', '// ── Calibration (persisted, optional)', 'helpers');
const S_LADDER = slice('// ── Weak-device ladder (task #37)', '// ── What to ask Opus for', 'ladder');
const S_RELOCK = slice('/** Re-assert the manual lock after any later constraint', '// ── Luma / exposure watchdog', 'relock');
const S_PROBE = slice('// ── Source-frame probe, armed at JOIN (task #37)', '// ── Face geometry', 'srcprobe');

// ── The generated module: prelude + real slices + export hooks ───────────────
const MODULE = `
const ENV = globalThis.__LADDER_SIM_ENV__;
const performance = ENV.performance;
const setTimeout = ENV.setTimeout;
const clearTimeout = ENV.clearTimeout;
const QS = ENV.QS;
const window = ENV.window;
const MediaStream = ENV.MediaStream;
const MediaStreamTrackProcessor = ENV.window.MediaStreamTrackProcessor;
const RTCRtpSender = ENV.RTCRtpSender;
const WANT_H = ENV.WANT_H;
const WANT_W = ENV.WANT_W;
const pick = ENV.pick;
const getMedia = ENV.getMedia;
const lockCamera = ENV.lockCamera;
const lumaWin = ENV.lumaWin;
let tel = ENV.tel;
let pc = ENV.pc;
let localStream = ENV.localStream;
let videoDegraded = null;
let camLocked = ENV.camLocked;
let lumaVideo = ENV.lumaVideo;

${S_HELPERS}
${S_LADDER}
${S_RELOCK}
${S_PROBE}

export const H = {
  srcProbeSample,
  startSourceProbe,
  resolveDevTier,
  currentCaptureAsk,
  devTargetFps,
  get srcProbe() { return srcProbe; },
  set srcProbe(v) { srcProbe = v; },
  get lowlightOn() { return lowlightOn; },
  get devStepTier() { return devStepTier; },
  get camLocked() { return camLocked; },
  get devTierWhy() { return devTierWhy; },
  consts: { LOWLIGHT_LUMA, LOWLIGHT_LUMA_HI, LOWLIGHT_HOLD_MS, LOWLIGHT_HI_MS, REVIVE_STALL_MS, REVIVE_MAX, DEV_STEP_WARMUP_MS, DEV_STEP_LOW_MS, DEV_STEP_LOW_FRAC, DEV_TIERS },
};
`;

// ── The Samsung M13 model ────────────────────────────────────────────────────
// CALIBRATION — three points measured live on the device (session 4, USB+CDP):
//   1. Pitch-dark room, continuous AE, 1080x1920 ...............  5 fps
//   2. Pitch-dark room, continuous AE, 720x960 .................  8 fps
//   3. Same dark room, manual exposureTime=33 iso=2500, ask 24 .. 20.4 fps
//
// UNIT NOTE (derived from those numbers, not from a spec reading): the device
// reports exposureTime in 100-MICROSECOND units, per W3C Image Capture. The
// proof is internal to the measurements — AE in the dark reported exposureTime
// ~1200 while still delivering ~8 fps. 8 fps allows at most 125 ms per frame,
// so 1200 cannot be milliseconds; 1200 x 100 us = 120 ms fits exactly.
//
// Frame-time model, one efficiency factor fitted to all three points:
//   perFrameMs = max(expMs + readoutMs(area), 1000 / askedFps)
//   readoutMs  = 8 + 12 * (area / full-frame area)
//   delivered  = 0.85 * 1000 / perFrameMs
// Check: (1) 120+20=140 -> 6.1 (measured 5)  (2) 120+12=132 -> 6.4 (measured 8)
//        (3) max(3.3+20, 41.67)=41.67 -> 20.4 (measured 20.4, exact)
const FULL_AREA = 1920 * 1080;
const EFF = 0.85;
const AE_MAX_EXP_UNITS = 1420; // capability max, 142 ms
const AE_VIDEO_ISO_CEIL = 400; // video-mode AE is conservative with gain (fitted)
const LUMA_TARGET = 110; // what AE aims for when it can reach it

class M13Camera {
  constructor(opts = {}) {
    this.kind = 'video';
    this.readyState = 'live';
    this.enabled = true;
    this.hasManualExposure = opts.hasManualExposure !== false;
    this.scene = opts.scene ?? 0.2; // >0; 0.2 = lit room, 0.0002 = pitch dark
    this.stalled = false;
    this.reviveOnApply = opts.reviveOnApply !== false; // the measured HAL behaviour
    this.aeTau = opts.aeTau ?? 0; // ms; 0 = instant convergence (calibrated regime)
    this.settings = {
      width: 1080,
      height: 1920,
      frameRate: 30,
      exposureMode: 'continuous',
      exposureTime: opts.exposureTime0 ?? 100,
      iso: 100,
      whiteBalanceMode: 'continuous',
      focusMode: 'continuous',
    };
    this.applyLog = [];
    this.overconstrained = 0;
  }
  get area() {
    return this.settings.width * this.settings.height;
  }
  get expMs() {
    return this.settings.exposureTime / 10; // 100 us units -> ms
  }
  getCapabilities() {
    const c = {
      width: { min: 96, max: 1920 },
      height: { min: 96, max: 1920 },
      frameRate: { min: 1, max: 30 },
      exposureMode: this.hasManualExposure ? ['continuous', 'manual'] : ['continuous'],
      whiteBalanceMode: ['continuous', 'manual'],
      focusMode: ['continuous', 'manual'],
      exposureCompensation: { min: -2, max: 2, step: 0.1 },
    };
    if (this.hasManualExposure) {
      c.exposureTime = { min: 0.65, max: AE_MAX_EXP_UNITS, step: 0.65 };
      c.iso = { min: 40, max: 2500, step: 1 };
    }
    return c;
  }
  getSettings() {
    return { ...this.settings };
  }
  stop() {
    this.readyState = 'ended';
  }
  /** The measured Chrome-Android rule: ImageCapture keys may not ride with stream keys. */
  async applyConstraints(c = {}) {
    const keys = Object.keys(c);
    const imageCapture = keys.filter((k) => k === 'exposureTime' || k === 'iso');
    const stream = keys.filter((k) => k === 'width' || k === 'height' || k === 'frameRate' || k === 'resizeMode');
    this.applyLog.push({ keys, c: JSON.parse(JSON.stringify(c)) });
    if (imageCapture.length && stream.length) {
      this.overconstrained++;
      const e = new Error('Mixing ImageCapture and non-ImageCapture constraints is not supported');
      e.name = 'OverconstrainedError';
      throw e;
    }
    if (this.readyState !== 'live') {
      const e = new Error('Track ended');
      e.name = 'InvalidStateError';
      throw e;
    }
    const ideal = (v) => (v && typeof v === 'object' ? (v.ideal ?? v.exact ?? v.max) : v);
    if (c.width != null) this.settings.width = Math.min(1920, ideal(c.width));
    if (c.height != null) this.settings.height = Math.min(1920, ideal(c.height));
    if (c.frameRate != null) this.settings.frameRate = Math.min(30, ideal(c.frameRate));
    if (c.exposureMode != null) {
      if (ideal(c.exposureMode) === 'manual' && !this.hasManualExposure) {
        const e = new Error('exposureMode manual unsupported');
        e.name = 'OverconstrainedError';
        throw e;
      }
      this.settings.exposureMode = ideal(c.exposureMode);
    }
    if (c.exposureTime != null) this.settings.exposureTime = ideal(c.exposureTime);
    if (c.iso != null) this.settings.iso = ideal(c.iso);
    if (c.whiteBalanceMode != null) this.settings.whiteBalanceMode = ideal(c.whiteBalanceMode);
    if (c.focusMode != null) this.settings.focusMode = ideal(c.focusMode);
    // Session 4: re-applying constraints revives a track that stalled while 'live'.
    if (this.reviveOnApply) this.stalled = false;
  }
  /**
   * Auto-exposure: reach LUMA_TARGET if it can, otherwise sit at the ceiling.
   * `aeTau` > 0 models a real AE loop's convergence time instead of snapping
   * instantly. Default 0 (instant) — that is the regime the three calibration
   * points were measured in, so every calibrated scenario is unaffected.
   */
  aeTick(dtMs = 0) {
    if (this.settings.exposureMode !== 'continuous') return;
    const required = 1 / this.scene; // "exposure product" (expMs x isoGain) for target luma
    let expMs = Math.min(required, AE_MAX_EXP_UNITS / 10);
    let isoGain = 1;
    if (expMs * isoGain < required) isoGain = Math.min(AE_VIDEO_ISO_CEIL / 100, required / expMs);
    const targetUnits = Math.max(0.65, Math.min(AE_MAX_EXP_UNITS, expMs * 10));
    if (this.aeTau > 0 && dtMs > 0) {
      const k = 1 - Math.exp(-dtMs / this.aeTau);
      this.settings.exposureTime += (targetUnits - this.settings.exposureTime) * k;
      this.settings.iso += (isoGain * 100 - this.settings.iso) * k;
    } else {
      this.settings.exposureTime = targetUnits;
      this.settings.iso = Math.round(isoGain * 100);
    }
  }
  get luma() {
    const product = this.expMs * (this.settings.iso / 100);
    const required = 1 / this.scene;
    return Math.max(0, Math.min(255, LUMA_TARGET * (product / required)));
  }
  get deliveredFps() {
    if (this.stalled || this.readyState !== 'live' || !this.enabled) return 0;
    const readout = 8 + 12 * (this.area / FULL_AREA);
    const perFrame = Math.max(this.expMs + readout, 1000 / Math.max(1, this.settings.frameRate));
    return (EFF * 1000) / perFrame;
  }
}

// ── Virtual clock ────────────────────────────────────────────────────────────
function makeClock() {
  let now = 0;
  let seq = 0;
  const timers = new Map();
  return {
    get now() {
      return now;
    },
    performance: { now: () => now },
    setTimeout(fn, ms) {
      const id = ++seq;
      timers.set(id, { at: now + (ms || 0), fn });
      return id;
    },
    clearTimeout(id) {
      timers.delete(id);
    },
    /** Advance, firing timers in order. */
    advance(ms) {
      const end = now + ms;
      for (;;) {
        let next = null;
        for (const [id, t] of timers) if (t.at <= end && (!next || t.at < next[1].at)) next = [id, t];
        if (!next) break;
        now = Math.max(now, next[1].at);
        timers.delete(next[0]);
        next[1].fn();
      }
      now = end;
    },
  };
}

// ── Harness ──────────────────────────────────────────────────────────────────
const tmp = mkdtempSync(join(tmpdir(), 'ladder-sim-'));
const MODPATH = join(tmp, 'ladder-slice.mjs');
writeFileSync(MODPATH, MODULE);

async function build(opts = {}) {
  const clock = makeClock();
  const cam = new M13Camera(opts.cam);
  const events = [];
  const qs = new Map(Object.entries(opts.qs || {}));
  const lumaWin = [];
  const env = {
    performance: clock.performance,
    setTimeout: (fn, ms) => clock.setTimeout(fn, ms),
    clearTimeout: (id) => clock.clearTimeout(id),
    QS: { get: (k) => (qs.has(k) ? qs.get(k) : null) },
    window: {
      MediaStreamTrackProcessor: function () {
        this.readable = { getReader: () => ({ read: () => new Promise(() => {}), cancel: async () => {} }) };
      },
    },
    MediaStream: class {
      constructor(tracks) {
        this.tracks = tracks;
      }
    },
    RTCRtpSender: {
      getCapabilities: () => ({
        codecs: opts.h264 === false ? [{ mimeType: 'video/VP8' }, { mimeType: 'video/VP9' }] : [{ mimeType: 'video/H264' }, { mimeType: 'video/VP8' }],
      }),
    },
    WANT_W: 1920,
    WANT_H: 1080,
    pick: (o, ks) => Object.fromEntries(ks.map((k) => [k, o?.[k]])),
    lumaWin,
    camLocked: true,
    lumaVideo: { srcObject: null },
    tel: { log: (ev, o) => events.push({ t: Math.round(clock.now), ev, ...o }) },
    pc: { getSenders: () => [] },
    localStream: {
      _tracks: [cam],
      addTrack(t) {
        this._tracks.push(t);
      },
      removeTrack(t) {
        this._tracks = this._tracks.filter((x) => x !== t);
      },
      getVideoTracks() {
        return this._tracks;
      },
    },
    getMedia: async () => {
      const fresh = new M13Camera(opts.cam);
      fresh.scene = cam.scene;
      env.__fresh = fresh;
      return { getAudioTracks: () => [], getVideoTracks: () => [fresh] };
    },
    lockCamera: () => {},
  };
  globalThis.__LADDER_SIM_ENV__ = env;
  const mod = await import(pathToFileURL(MODPATH).href + `?t=${Math.random()}`);
  const H = mod.H;

  // The probe shape the real startSourceProbe builds, with a parked reader.
  let track = cam;
  H.srcProbe = {
    track,
    reader: { read: () => new Promise(() => {}), cancel: async () => {} },
    frames: 0,
    t0: 0,
    lastT: 0,
    lastF: 0,
  };

  let frameAcc = 0;
  const STEP = 250; // sub-step: AE, frame accrual, timers
  const SAMPLE = 2000; // the real stats cadence that calls srcProbeSample
  const LUMA = 1000; // the real luma watchdog cadence
  let sinceSample = 0;
  let sinceLuma = 0;
  const trace = [];

  // Async on purpose: the ladder is full of `await`s (applyConstraints,
  // safeAsync, the re-acquire chain). A synchronous advance loop would never
  // drain the microtask queue, so every continuation after an `await` would be
  // parked forever and the sim would "prove" that nothing fires — the fixture
  // starving the code under test. One macrotask turn per sub-step drains it.
  async function run(ms, onStep) {
    const until = clock.now + ms;
    while (clock.now < until) {
      const live = H.srcProbe?.track ?? track;
      if (onStep) onStep(live, clock.now);
      live.aeTick?.(STEP);
      frameAcc += ((live.deliveredFps ?? 0) * STEP) / 1000;
      const whole = Math.floor(frameAcc);
      if (whole > 0 && H.srcProbe) {
        H.srcProbe.frames += whole;
        frameAcc -= whole;
      }
      clock.advance(STEP);
      sinceLuma += STEP;
      if (sinceLuma >= LUMA) {
        sinceLuma = 0;
        if (live.readyState === 'live' && live.enabled) lumaWin.push({ t: clock.now, y: live.luma });
        while (lumaWin.length && clock.now - lumaWin[0].t > 12000) lumaWin.shift();
      }
      sinceSample += STEP;
      if (sinceSample >= SAMPLE) {
        sinceSample = 0;
        H.srcProbeSample();
        trace.push({
          t: Math.round(clock.now),
          fps: +(live.deliveredFps ?? 0).toFixed(1),
          luma: +(live.luma ?? 0).toFixed(1),
          exp: live.settings?.exposureTime,
          iso: live.settings?.iso,
          mode: live.settings?.exposureMode,
          ll: H.lowlightOn ? 1 : 0,
          tier: H.devStepTier,
        });
      }
      await new Promise((r) => setImmediate(r)); // drain awaits inside the ladder
    }
  }
  const handle = { H, cam, env, events, trace, run, clock, get track() { return H.srcProbe?.track ?? cam; } };
  BUILT.push(handle);
  return handle;
}
const BUILT = [];

// ── Assertions ───────────────────────────────────────────────────────────────
let pass = 0;
let fail = 0;
const failures = [];
function ok(cond, msg, detail) {
  if (cond) {
    pass++;
    if (VERBOSE) console.log(`    ok    ${msg}`);
  } else {
    fail++;
    failures.push(msg);
    console.log(`    FAIL  ${msg}${detail ? `\n          ${detail}` : ''}`);
  }
}
const evs = (events, name) => events.filter((e) => e.ev === name);

const SCENARIOS = [];
const scenario = (name, fn) => SCENARIOS.push({ name, fn });

// 1 ─ A healthy device in a lit room must be left completely alone.
scenario('strong-bright-untouched', async () => {
  const s = await build({ cam: { scene: 0.2 } });
  await s.run(60000);
  ok(s.H.devTierWhy === 'h264-present', `tier reason h264-present (got ${s.H.devTierWhy})`);
  ok(!s.H.lowlightOn, 'low-light never engages in a lit room');
  ok(evs(s.events, 'devstep').length === 0, 'no tier step on a healthy camera');
  ok(evs(s.events, 'stall-revive').length === 0, 'no revival on a healthy camera');
  ok(s.cam.settings.exposureMode === 'continuous', 'auto-exposure left in continuous');
  ok(s.cam.applyLog.length === 0, `camera never touched (${s.cam.applyLog.length} applyConstraints)`);
  const fps = s.trace[s.trace.length - 1].fps;
  ok(fps > 24, `delivers full rate (${fps.toFixed?.(1) ?? fps} fps)`);
});

// 2 ─ The M13 in the dark: the whole point of the change.
scenario('m13-dark-lowlight-engages', async () => {
  const s = await build({ cam: { scene: 0.0002 } });
  // Baseline must be read BEFORE the 4 s dark-and-starving hold elapses —
  // sample at t=2 s, the first stats tick, while AE still owns the exposure.
  await s.run(3000);
  const before = s.trace[s.trace.length - 1].fps;
  ok(before < 8, `starved before the fix (${before} fps)`);
  ok(!s.H.lowlightOn, 'has not engaged yet at the baseline sample');
  ok(s.cam.luma < 20, `dark enough to trigger (luma ${s.cam.luma.toFixed(1)})`);
  await s.run(57000);
  const after = s.trace[s.trace.length - 1].fps;
  ok(s.H.lowlightOn, 'low-light mode engaged');
  ok(s.cam.settings.exposureMode === 'manual', 'exposure taken off AE');
  ok(after > before * 2.5, `motion restored: ${before} -> ${after} fps`);
  const ll = evs(s.events, 'lowlight').find((e) => e.on === 1);
  ok(!!ll, 'entry logged with the numbers');
  ok(evs(s.events, 'lowlight-result').length > 0, 'the 8 s after-measurement fired');
  ok(evs(s.events, 'devstep').length === 0, 'no tier step: the stepper stood down while exposure-capped');
});

// 3 ─ The sequencing rule. This is the trap that cost session 4 real time.
scenario('never-mixes-imagecapture-and-stream-constraints', async () => {
  for (const scene of [0.0002, 0.2]) {
    const s = await build({ cam: { scene } });
    await s.run(90000, (t, now) => {
      if (now === 30000) t.stalled = true; // force the revive path through the same rule
    });
    ok(s.cam.overconstrained === 0, `scene ${scene}: zero OverconstrainedError (${s.cam.overconstrained})`);
    const bad = s.cam.applyLog.filter(
      (a) => a.keys.some((k) => k === 'exposureTime' || k === 'iso') && a.keys.some((k) => ['width', 'height', 'frameRate', 'resizeMode'].includes(k)),
    );
    ok(bad.length === 0, `scene ${scene}: no mixed applyConstraints call`, bad.length ? JSON.stringify(bad[0]) : '');
    const errs = evs(s.events, 'error').filter((e) => e.name === 'OverconstrainedError');
    ok(errs.length === 0, `scene ${scene}: no OverconstrainedError reached telemetry`);
  }
});

// 4 ─ Light comes back: release the camera, with hysteresis, then re-lock.
scenario('light-returns-releases-exposure', async () => {
  const s = await build({ cam: { scene: 0.0002 } });
  await s.run(40000);
  ok(s.H.lowlightOn, 'engaged in the dark first');
  s.cam.scene = 0.2; // lights on
  await s.run(6000);
  ok(s.H.lowlightOn, 'does not release on a brief flash (hysteresis holds)');
  await s.run(30000);
  ok(!s.H.lowlightOn, 'released after sustained light');
  // The end state is exposureMode 'manual' AGAIN, and that is correct: the §5
  // camlock owns exposure between low-light episodes. What low-light must give
  // back is its emergency PIN — AE gets the 2.5 s settle window to choose a
  // real exposure, and the lock then freezes that. So the assertion is about
  // the picture, not the mode string.
  ok(s.cam.luma > 60, `image properly exposed after release (luma ${s.cam.luma.toFixed(1)})`);
  ok(s.trace[s.trace.length - 1].fps > 24, `full rate after release (${s.trace[s.trace.length - 1].fps} fps)`);
  const exit = evs(s.events, 'lowlight').filter((e) => e.restored === 'continuous');
  ok(exit.length === 1, `exactly one release logged (${exit.length})`);
  const relocks = evs(s.events, 'camlock').filter((e) => e.relock === 1);
  ok(relocks.length >= 1, 'camlock re-asserted after the release settle');
});

// 5 ─ A camera that stops delivering while claiming to be alive.
scenario('stall-revives', async () => {
  const s = await build({ cam: { scene: 0.2 } });
  await s.run(20000, (t, now) => {
    if (now === 10000) t.stalled = true;
  });
  ok(s.cam.stalled === false, 'the constraint re-apply un-stalled the HAL');
  const r = evs(s.events, 'stall-revive');
  ok(r.length >= 1, `revival attempted (${r.length})`);
  ok(r.some((e) => e.recovered === 1), 'recovery confirmed and logged');
  ok(evs(s.events, 'stall-reacquire').length === 0, 'no re-acquire needed for a single stall');
  ok(s.trace[s.trace.length - 1].fps > 24, 'frames flowing again');
});

// 6 ─ A camera that will not come back: escalate to a full re-acquire.
scenario('dead-camera-escalates-to-reacquire', async () => {
  const s = await build({ cam: { scene: 0.2, reviveOnApply: false } });
  // Only the ORIGINAL camera is unrecoverable. The replacement works — that is
  // the case re-acquire exists for, and the one that must end in recovery.
  await s.run(90000, (t, now) => {
    if (now >= 10000 && t === s.cam) t.stalled = true;
  });
  const r = evs(s.events, 'stall-revive');
  ok(r.filter((e) => e.n).length >= 3, `escalation ladder walked (${r.filter((e) => e.n).length} attempts)`);
  ok(r.some((e) => e.gaveUp === 1), 'gave up after the cap instead of looping forever');
  const re = evs(s.events, 'stall-reacquire');
  ok(re.length === 1, `camera re-acquired exactly once (${re.length})`);
  ok(re[0]?.ok === 1, 're-acquire reported success');
  ok(s.H.srcProbe?.track === s.env.__fresh, 'the probe re-armed on the NEW track');
  ok(s.H.lowlightOn === false, 'low-light state reset for the fresh camera');
  ok(s.trace[s.trace.length - 1].fps > 24, `frames flowing from the replacement (${s.trace[s.trace.length - 1].fps} fps)`);
});

// 11 ─ Hardware that is simply gone: retry, but never spin.
scenario('permanently-dead-camera-retries-slowly', async () => {
  const s = await build({ cam: { scene: 0.2, reviveOnApply: false } });
  await s.run(180000, (t, now) => {
    if (now >= 10000) t.stalled = true; // every camera, including replacements
  });
  const re = evs(s.events, 'stall-reacquire');
  ok(re.length >= 2, `keeps trying to recover (${re.length} re-acquires in 3 min)`);
  ok(re.length <= 10, `bounded, not a spin (${re.length} re-acquires in 3 min)`);
  const gaps = re.slice(1).map((e, i) => e.t - re[i].t);
  ok(
    gaps.every((g) => g >= 15000),
    `every retry cycle costs at least 15 s (min gap ${Math.min(...gaps)} ms)`,
  );
  ok(
    evs(s.events, 'stall-revive').filter((e) => e.gaveUp === 1).length === re.length,
    'each re-acquire is preceded by a full revive ladder',
  );
});

// 7 ─ The user switched their camera off. Never fight the toggle.
scenario('camera-off-is-not-a-stall', async () => {
  const s = await build({ cam: { scene: 0.2 } });
  await s.run(60000, (t, now) => {
    if (now >= 10000) t.enabled = false;
  });
  ok(evs(s.events, 'stall-revive').length === 0, 'no revival attempts while the user has video off');
  ok(evs(s.events, 'stall-reacquire').length === 0, 'no re-acquire while the user has video off');
  ok(s.cam.applyLog.length === 0, 'camera never touched while off');
});

// 8 ─ Resolution-bound starvation on a device with no H.264: the original ladder.
scenario('weak-device-steps-down-one-way', async () => {
  const s = await build({ h264: false, cam: { scene: 0.2 } });
  ok(s.H.resolveDevTier() === 'weak', `no-H264 device starts at weak (${s.H.resolveDevTier()})`);
  // A software encoder that cannot keep up: model it as a frame-rate ceiling
  // that only a smaller frame relieves.
  const s2 = await build({ h264: false, cam: { scene: 0.2 } });
  const cam = s2.cam;
  Object.defineProperty(cam, 'deliveredFps', {
    get() {
      if (this.stalled || !this.enabled || this.readyState !== 'live') return 0;
      return this.area > 640 * 360 ? 6 : 22; // only the floor tier is affordable
    },
  });
  await s2.run(60000);
  ok(s2.H.devStepTier === 'weaker', `walked to the floor tier (${s2.H.devStepTier})`);
  const steps = evs(s2.events, 'devstep');
  ok(steps.length === 1, `one step recorded (${steps.length})`);
  ok(steps[0]?.from === 'weak' && steps[0]?.to === 'weaker', `weak -> weaker (${steps[0]?.from} -> ${steps[0]?.to})`);
  await s2.run(60000);
  ok(evs(s2.events, 'devstep').length === 1, 'never steps back up, never re-steps at the floor');
  ok(cam.settings.width <= 640 || cam.settings.height <= 640, 'capture actually shrank');
});

// 9 ─ A device with no manual exposure must degrade honestly, not pretend.
scenario('no-manual-exposure-degrades-honestly', async () => {
  const s = await build({ cam: { scene: 0.0002, hasManualExposure: false } });
  await s.run(60000);
  ok(!s.H.lowlightOn, 'low-light not claimed on a device that cannot do it');
  const ll = evs(s.events, 'lowlight').filter((e) => e.capable === 0);
  ok(ll.length >= 1, 'incapability logged as telemetry (the honest state IS the data)');
  ok(s.cam.settings.exposureMode === 'continuous', 'AE left alone');
  const ladderErrs = evs(s.events, 'error').filter((e) => /^(lowlight|revive|devstep|srcprobe)/.test(e.where || ''));
  ok(ladderErrs.length === 0, `no exceptions escaped the ladder (${ladderErrs.length})`, JSON.stringify(ladderErrs[0] || {}));
  // The camlock DOES throw here (it asks for manual exposure on a camera that
  // has none) — pre-existing, guarded, logged. Assert it stayed contained.
  const lockErrs = evs(s.events, 'error').filter((e) => (e.where || '').startsWith('camlock'));
  ok(lockErrs.length > 0 && lockErrs.every((e) => e.name === 'OverconstrainedError'), 'camlock failure contained and logged, not thrown');
  // And the fallback that matters: no manual exposure means the RESOLUTION
  // ladder is the only lever left, so it must be the one that acts.
  ok(evs(s.events, 'devstep').length >= 1, `fell back to the resolution ladder (${evs(s.events, 'devstep').length} steps)`);
});

// 10 ─ Kill switches: ?lowlight=0 / ?revive=0 / ?ladder=0 must be inert.
scenario('kill-switches-are-inert', async () => {
  const off = await build({ cam: { scene: 0.0002 }, qs: { lowlight: '0', revive: '0', ladder: '0' } });
  await off.run(90000, (t, now) => {
    if (now >= 30000) t.stalled = true;
  });
  ok(!off.H.lowlightOn, '?lowlight=0 keeps low-light off');
  ok(evs(off.events, 'stall-revive').length === 0, '?revive=0 keeps revival off');
  ok(evs(off.events, 'devstep').length === 0, '?ladder=0 keeps the stepper off');
  ok(off.cam.applyLog.length === 0, 'all three off = camera never touched');
});

// 12 ─ A healthy camera that simply caps below 30 fps must not be punished.
// Measured motivation: in the two-browser regression the fake camera delivered
// 19.4-20.5 fps against a trip point of 18.0 (60% of a hard-coded 30) — an 8%
// margin from a spurious downgrade on a camera with nothing wrong with it.
scenario('honest-camera-below-30fps-is-not-starving', async () => {
  for (const cap of [24, 20, 15]) {
    const s = await build({ cam: { scene: 0.2 } });
    // A camera that negotiated `cap` fps and delivers exactly that: healthy.
    s.cam.settings.frameRate = cap;
    Object.defineProperty(s.cam, 'deliveredFps', {
      get() {
        return this.stalled || !this.enabled || this.readyState !== 'live' ? 0 : this.settings.frameRate;
      },
    });
    await s.run(60000);
    const steps = evs(s.events, 'devstep');
    ok(
      steps.length === 0,
      `${cap} fps camera delivering its full ${cap} fps is left alone (${steps.length} step(s) to ${s.H.devStepTier ?? 'strong'})`,
      steps.length ? `stepped because ${steps[0].why}` : '',
    );
  }
});

// ── Diagnostic (does NOT gate the suite) ─────────────────────────────────────
// The user's report has three phases: "the video goes dark, not completely,
// after a few seconds / opens up pretty good / but then sucks". Session 4
// explained phase 3 (AE stretches exposure, fps starves) and the low-light
// mode fixes it. Phases 1 and 2 were never explained. This runs the mechanism
// that fits them: a real AE loop needs a second or two to converge, and the §5
// camlock freezes exposure at 2.5 s — so a camera that opens dark and is still
// climbing gets FROZEN mid-climb. It is a HYPOTHESIS reproduced in a model,
// not a measurement; `phone-test.sh --arm=camlock` is what would settle it.
async function camlockDiagnostic() {
  console.log('\n  camlock-freeze (diagnostic, not a gate)');
  const out = [];
  for (const [label, aeTau] of [['instant AE (calibrated regime)', 0], ['AE converges over ~1.5 s (real loop)', 1500]]) {
    const s = await build({ cam: { scene: 0.02, aeTau, exposureTime0: 20 } }); // dim room, camera opens dark
    // Reproduce lockCamera(): the §5 lock, fired at 2.5 s exactly as at join.
    await s.run(2500);
    const atLock = s.cam.luma;
    await s.cam.applyConstraints({ exposureMode: 'manual', whiteBalanceMode: 'manual', focusMode: 'manual' });
    await s.run(57500);
    const end = s.trace[s.trace.length - 1];
    out.push({ label, lumaAtLock: +atLock.toFixed(1), lumaEnd: +s.cam.luma.toFixed(1), fpsEnd: end.fps, lowlight: s.H.lowlightOn ? 'engaged' : 'never', nudges: evs(s.events, 'lumadrop').length });
  }
  for (const r of out) {
    console.log(`    ${r.label}`);
    console.log(`      luma at camlock ${r.lumaAtLock} -> luma at 60 s ${r.lumaEnd} (0-255), fps ${r.fpsEnd}, low-light ${r.lowlight}`);
  }
  const [instant, real] = out;
  const reproduced = real.lumaEnd < 20 && real.fpsEnd > 20 && real.lowlight === 'never';
  console.log(
    reproduced
      ? `    OBSERVED: the lock freezes a dark exposure and nothing in the ladder reacts.`
      : `    NOT REPRODUCED — at 2.5 s the AE has already climbed most of the way (luma ${real.lumaEnd}/255),\n      so the lock does not freeze a dark frame. This mechanism is FALSIFIED in the model.`,
  );
  console.log(`    control (instant AE): luma ${instant.lumaEnd}, fps ${instant.fpsEnd}, low-light ${instant.lowlight}`);
}

// The run above surfaced something the dark-room work never covered: BOTH arms
// sat at 14-16 fps in a merely dim room with a perfectly well-exposed picture.
// That is the starvation the user calls "sucks", in the lighting a real call
// actually happens in — and the low-light fix cannot reach it, because its
// trigger asks whether the IMAGE IS DARK (luma < 20) when the mechanism is
// whether the EXPOSURE IS LONG. A well-exposed 90-luma frame at a 50 ms
// exposure is the same physics as a black one at 120 ms.
async function dimRoomDiagnostic() {
  console.log('\n  dim-room gap (diagnostic, not a gate)');
  const s = await build({ cam: { scene: 0.02 } }); // dim: a lamp-lit room at night
  await s.run(90000);
  const end = s.trace[s.trace.length - 1];
  const steps = evs(s.events, 'devstep');
  console.log(`    luma ${s.cam.luma.toFixed(1)}/255 (well exposed), exposure ${(s.cam.expMs).toFixed(0)} ms, delivered ${end.fps} fps`);
  console.log(`    low-light: ${s.H.lowlightOn ? 'engaged' : 'NEVER (luma gate: image is not dark)'}`);
  console.log(`    resolution ladder: ${steps.length} step(s) -> ${s.H.devStepTier ?? 'strong'} (${s.cam.settings.width}x${s.cam.settings.height})`);
  if (steps.length && end.fps < 20) {
    console.log(
      `    OBSERVED: the stepper spent ${steps.length} tier(s) of resolution and delivery is still ${end.fps} fps.\n` +
        `      Resolution was never the lever here either — the ${s.cam.expMs.toFixed(0)} ms exposure sets a ${(1000 / s.cam.expMs).toFixed(0)} fps\n` +
        `      ceiling that no frame size can lift. The exposure lever that WOULD fix it is gated off\n` +
        `      by "is the image dark", so the app trades away pixels and gains nothing.\n` +
        `      SUGGESTED (needs device confirmation): trigger on measured exposureTime, not luma.`,
    );
  } else {
    console.log(`    not reproduced: fps ${end.fps}, steps ${steps.length}`);
  }
}

// ── Run ──────────────────────────────────────────────────────────────────────
console.log('ladder-sim — real app.js source, modelled Samsung M13, virtual clock\n');
for (const sc of SCENARIOS) {
  if (ONLY && sc.name !== ONLY) continue;
  console.log(`  ${sc.name}`);
  const before = fail;
  BUILT.length = 0;
  try {
    await sc.fn();
    if (DUMP) {
      for (const h of BUILT) {
        for (const e of h.events) console.log(`      [${String(e.t).padStart(6)}] ${e.ev} ${JSON.stringify({ ...e, t: undefined, ev: undefined })}`);
        for (const r of h.trace) console.log(`      trace ${JSON.stringify(r)}`);
      }
    }
  } catch (e) {
    fail++;
    failures.push(`${sc.name}: threw ${e?.name}: ${e?.message}`);
    console.log(`    FAIL  threw ${e?.stack?.split('\n').slice(0, 3).join('\n          ')}`);
  }
  if (fail === before) console.log(`    ✓ ${sc.name}`);
}
if (!ONLY) { await camlockDiagnostic(); await dimRoomDiagnostic(); }
console.log(`\n${pass} passed, ${fail} failed`);
if (fail) {
  console.log('\nfailures:');
  for (const f of failures) console.log(`  · ${f}`);
}
process.exit(fail ? 1 : 0);
