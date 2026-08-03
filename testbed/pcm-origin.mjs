/**
 * Deterministic model of the negative-depth PCM startup defect (MEASURED.md,
 * "Run 3's BASELINE ... depth -22935 ms with 2867 frames concealed").
 *
 * Drives the REAL tape-app/public/pcm-worklet.js PcmPlayout — imported, not
 * re-implemented — plus a line-for-line copy of the SAB writer gate from
 * pcm.js ringWrite(), and varies ONE thing: D, the delay between the first PCM
 * frame landing in the ring and the playout worklet's first process() call
 * (i.e. `await addModule()` resolving). Everything else is held fixed: the
 * sender emits seq 0,1,2,... at 125 fps from its own capture clock and never
 * stops, exactly as PcmCapture does.
 *
 * THE MECHANISM. The ring is RING_F=64 frames (512 ms). The writer's accept
 * window is `lo = max(startSeq, playSeqNow())`, and SAB_PLAY is initialised to
 * 0, so playSeqNow() reads 0 for the whole time the playhead does not yet
 * exist. So `lo` is pinned to startSeq — the FIRST frame ever received — and
 * the ring accepts startSeq..startSeq+63 and rejects every later frame as
 * farFuture. When the graph finally comes up the playhead seeds at startSeq,
 * which is correct and useless: that audio is now D seconds old, and the live
 * stream sits outside the window permanently, because `lo` thereafter advances
 * at 125 frames/s — exactly the rate the sender's seq advances. The gap never
 * closes. The drift controller makes it worse, not better: err is hugely
 * negative so ratio clamps at 1-maxDrift, and the playhead falls 0.2% further
 * behind every second.
 *
 * THE CLIFF, in closed form. The worklet's one existing re-anchor (the ring
 * overflow skip) fires exactly once and moves the playhead to hiSeq1-target,
 * the head of the STALE ring — worth 512 ms of relief and no more. A live frame
 * at seq startSeq+125D then lands iff 125D < 2*RING_F - target = 126, i.e.
 *
 *     D < 1.008 s
 *
 * Above that the lane conceals for the rest of the call while every counter
 * reports connected and full-rate. The sweep below straddles it: 0.95 s
 * recovers, 1.0 s does not.
 *
 * --anchor asks WHICH LAYER owns the bug, and the answer matters: a re-anchor
 * in the worklet drags depthMs back to a plausible -39.9 ms while lostFrames
 * stays at 3060 and the audio stays broken. Only the writer can fix it.
 *
 * Usage: node pcm-origin.mjs [--secs=25] [--delays=0.95,1,3] [--anchor=none|worklet|writer]
 * See also: testbed/pcm-graphdelay.mjs, the same defect on two real browsers.
 */


// A repo path with a space in it: keep it a URL all the way to the import, or
// `%20` reaches the resolver as a literal and the module is "not found".
const WORKLET_URL = new URL('../tape-app/public/pcm-worklet.js', import.meta.url).href;
const SR = 48000;
const FRAME = 384;          // 8 ms
const RING_F = 64;          // pcm-worklet.js RING_F — 512 ms of ring
const BLOCK = 128;          // render quantum
const FRAME_MS = 8;
const TARGET_FRAMES = 2;    // cfg.targetFrames on the observed run
const SAB_HI = 0, SAB_PLAY = 1, SAB_START = 2, SAB_TARGET = 3, SAB_LOCK = 4;

// ── argv, fatal on unknown (project lesson: unknown flags must be fatal) ────
const KNOWN = new Set(['secs', 'delays', 'anchor', 'bogus', 'bound']);
for (const a of process.argv.slice(2)) {
  const m = /^--([^=]+)=/.exec(a);
  if (!m || !KNOWN.has(m[1])) throw new Error(`unknown flag ${a} — known: ${[...KNOWN].join(', ')}`);
}
const arg = (k, d) => {
  const hit = process.argv.slice(2).find((a) => a.startsWith(`--${k}=`));
  return hit === undefined ? d : hit.slice(k.length + 3);
};
const SECS = Number(arg('secs', 25));
const DELAYS = arg('delays', '0.1,0.3,0.5,0.52,0.6,1,5,23.4').split(',').map(Number);
// WHICH LAYER OWNS THE BUG. Not a proposed patch — a probe to find out whether a
// re-anchor in the worklet could even reach this state, or whether only the writer can.
//   none    = shipped behaviour
//   worklet = playhead re-anchors forward when the deficit is absurd
//   writer  = ringWrite re-seeds startSeq when a far-future frame arrives and the
//             playhead has not started yet (needs a real "not started" signal)
const ANCHOR = arg('anchor', 'none');
if (!['none', 'worklet', 'writer'].includes(ANCHOR)) throw new Error(`--anchor must be none|worklet|writer, got ${ANCHOR}`);
// ── IS THE RE-SEED'S OWN GUARD REAL? ───────────────────────────────────────
// The writer re-seed hands a far-future frame the power to move the accept window, so a
// single bogus sequence number could move it past every real frame and silence the lane
// PERMANENTLY — trading a startup-only failure for an unrecoverable one. The shipped code
// bounds the jump by elapsed time at the nominal frame rate. A guard that has never been
// fired is a guard that has only been asserted, so these two flags fire it:
//   --bogus=N  inject ONE frame at seq (newest + N) midway through graph startup
//   --bound=0  disable the plausibility bound, to show what it is preventing
const BOGUS = Number(arg('bogus', 0));
const BOUND = arg('bound', '1') !== '0';
if (!Number.isFinite(BOGUS) || BOGUS < 0) throw new Error(`--bogus must be a number >= 0`);

// ── AudioWorkletGlobalScope shim ───────────────────────────────────────────
let CURRENT_TIME = 0;
const registered = new Map();
globalThis.sampleRate = SR;
Object.defineProperty(globalThis, 'currentTime', { get: () => CURRENT_TIME, configurable: true });
globalThis.AudioWorkletProcessor = class {
  constructor() {
    const self = this;
    this.port = {
      _handler: null,
      postMessage: (m) => self._sent.push(m),
      set onmessage(fn) { this._handler = fn; },
      get onmessage() { return this._handler; },
    };
    this._sent = [];
  }
};
globalThis.registerProcessor = (name, cls) => registered.set(name, cls);

await import(WORKLET_URL);
const PcmPlayout = registered.get('pcm-playout');
if (!PcmPlayout) throw new Error('pcm-playout did not register — worklet shim is wrong');

// ── one arm ────────────────────────────────────────────────────────────────
// D = seconds between the first frame landing in the ring and the worklet's
// first process() call.
function run(D) {
  const sab = new SharedArrayBuffer(816 + RING_F * FRAME * 4);
  const ctl = new Int32Array(sab, 0, 8);
  const tags = new Int32Array(sab, 32, RING_F);
  const capTs = new Float64Array(sab, 288, RING_F);
  const ring = new Float32Array(sab, 816, RING_F * FRAME);
  Atomics.store(ctl, SAB_START, -1);
  Atomics.store(ctl, SAB_HI, 0);
  Atomics.store(ctl, SAB_PLAY, 0);
  Atomics.store(ctl, SAB_TARGET, TARGET_FRAMES);
  Atomics.store(ctl, SAB_LOCK, 0);
  tags.fill(-1);

  // ── main-thread writer: pcm.js ringWrite(), SAB branch, verbatim gate ────
  let startSeq = -1, hiSeq1 = 0;
  const stats = { framesRecv: 0, late: 0, farFuture: 0, dup: 0, reseeds: 0, implausible: 0 };
  // The signal the shipped SAB layout cannot give: SAB_PLAY is initialised to 0, so
  // "playhead at frame 0" and "playhead does not exist yet" are the same 32 bits.
  // The probe cheats by asking the object directly; production would need a sentinel.
  let wlRef = null;
  const wlStarted = () => !!wlRef?.started;
  const samples = new Float32Array(FRAME); // audible, non-silent payload
  for (let i = 0; i < FRAME; i++) samples[i] = 0.25 * Math.sin((2 * Math.PI * 440 * i) / SR);
  const playSeqNow = () => Atomics.load(ctl, SAB_PLAY);
  let firstSeq = -1, firstSeqAt = 0;
  function ringWrite(seq) {
    stats.framesRecv++;                              // counted in onMessage, before the gate
    if (startSeq < 0) {
      startSeq = seq; firstSeq = seq; firstSeqAt = (CURRENT_TIME * 1000);
      Atomics.store(ctl, SAB_START, seq);
    }
    const lo = Math.max(startSeq, playSeqNow());
    if (seq < lo) { stats.late++; return false; }
    if (seq >= lo + RING_F) {
      // ANCHOR=writer: the ring should hold the NEWEST 512 ms, not the FIRST 512 ms.
      // Only legal while the playhead has not started — after that, dropping the ring
      // under a live playhead is the corruption the guard exists to prevent.
      //
      // BOUNDED, matching the shipped pcm.js: elapsed time at the nominal frame rate is
      // the furthest a sender can legitimately have advanced, so anything past it is a
      // bogus header and is rejected exactly as it was before the re-seed existed.
      // Unbounded, one nonsense seq would walk the accept window past every real frame
      // and silence the lane permanently — a worse failure than the startup-only one
      // being fixed. This bound MUST stay in step with pcm.js: a model that drifts from
      // the shipped rule is a model that will vindicate the wrong code later.
      const plausibleMax = firstSeq + Math.ceil(((CURRENT_TIME * 1000) - firstSeqAt) / 8) + RING_F + 125;
      if (seq > plausibleMax) stats.implausible++;
      if (ANCHOR === 'writer' && !wlStarted() && (!BOUND || seq <= plausibleMax)) {
        startSeq = seq; Atomics.store(ctl, SAB_START, seq);
        tags.fill(-1); hiSeq1 = 0; Atomics.store(ctl, SAB_HI, 0);
        stats.reseeds++;
      } else { stats.farFuture++; return false; }
    }
    if (Atomics.load(tags, seq % RING_F) === seq) { stats.dup++; return false; }
    ring.set(samples, (seq % RING_F) * FRAME);
    capTs[seq % RING_F] = seq * 8000;
    Atomics.store(tags, seq % RING_F, seq);
    if (seq + 1 > hiSeq1) { hiSeq1 = seq + 1; Atomics.store(ctl, SAB_HI, hiSeq1); }
    return true;
  }

  const wl = new PcmPlayout({ processorOptions: { sab, targetFrames: TARGET_FRAMES, driftPpm: 2000 } });
  wlRef = wl;
  // ANCHOR=worklet: the playhead notices an absurd deficit and jumps to the ring head.
  // Wrapped around the real process() rather than edited into it, so the shipped
  // arithmetic is untouched and only the re-anchor is added.
  let wlReanchors = 0;
  const rawProcess = wl.process.bind(wl);
  const proc = ANCHOR !== 'worklet' ? rawProcess : (inp, outp) => {
    const r = rawProcess(inp, outp);
    if (wl.started) {
      const occ = Atomics.load(ctl, SAB_HI) * FRAME - wl.pos;
      if (occ < -RING_F * FRAME) { // more than a ring behind: not jitter, a bad origin
        wl.pos = Atomics.load(ctl, SAB_HI) * FRAME - Atomics.load(ctl, SAB_TARGET) * FRAME;
        wl.curFrame = -1;
        wlReanchors++;
      }
    }
    return r;
  };

  // ── clocked simulation ──────────────────────────────────────────────────
  // The sender's capture clock and our render clock are the same 48 kHz.
  // Frame seq k is emitted (and, being a clean loopback, arrives) at
  // t = k * 8 ms. The worklet's first process() is at t = D.
  const out = new Float32Array(BLOCK);
  const totalBlocks = Math.ceil(((D + SECS) * SR) / BLOCK);
  let nextSeq = 0;
  let firstArrivalT = null, startedAtT = null, bogusSent = false;
  for (let b = 0; b < totalBlocks; b++) {
    const t = (b * BLOCK) / SR;
    CURRENT_TIME = t;
    // deliver every frame whose capture instant has passed
    while (nextSeq * FRAME_MS <= t * 1000) {
      ringWrite(nextSeq);
      if (firstArrivalT === null) firstArrivalT = nextSeq * FRAME_MS / 1000;
      nextSeq++;
    }
    // ONE bogus header, halfway through graph startup — while the playhead does not yet
    // exist, which is the only window in which the re-seed can act at all. Delivered
    // through the SAME ringWrite as everything else; nothing about the gate is bypassed.
    if (BOGUS > 0 && !bogusSent && t >= D / 2) {
      bogusSent = true;
      ringWrite(nextSeq + BOGUS);
    }
    if (t >= D) {
      proc([[]], [[out]]);
      if (startedAtT === null && wl.started) startedAtT = t;
    }
  }

  const depthMs = wl.started ? +((Atomics.load(ctl, SAB_HI) * FRAME - wl.pos) / (SR / 1000)).toFixed(1) : null;
  return {
    D,
    startSeq,
    hiSeq1: Atomics.load(ctl, SAB_HI),
    playSeq: wl.started ? Math.floor(wl.pos / FRAME) : -1,
    started: wl.started,
    startedAtT: startedAtT === null ? null : +startedAtT.toFixed(2),
    depthMs,
    lostFrames: wl.concealedFrames,
    playedFrames: wl.playedFrames,
    heldFrames: wl.heldFrames,
    framesRecv: stats.framesRecv,
    late: stats.late,
    farFuture: stats.farFuture,
    overflowSkips: wl.overflowSkips,
    reseeds: stats.reseeds,
    implausible: stats.implausible,
    wlReanchors,
    targetFrames: Atomics.load(ctl, SAB_TARGET),
    driftPpm: Math.round((wl.ratio - 1) * 1e6),
  };
}

// ── report ─────────────────────────────────────────────────────────────────
console.log(`\n  PCM playhead origin vs. audio-graph delay — ${SECS}s of playout per arm`);
console.log(`  ring ${RING_F} frames = ${RING_F * FRAME_MS} ms | target ${TARGET_FRAMES} frames | real pcm-worklet.js PcmPlayout\n`);
const head = ['graphDelay', 'startSeq', 'hiSeq1', 'playSeq', 'depthMs', 'lostFrames', 'played', 'framesRecv', 'farFuture', 'ovfSkip', 'reseed', 'reanch'];
const rows = DELAYS.map(run);
const w = head.map((h, i) => Math.max(h.length, ...rows.map((r) => String(Object.values(pick(r))[i]).length)));
function pick(r) {
  return {
    graphDelay: `${r.D}s`, startSeq: r.startSeq, hiSeq1: r.hiSeq1,
    playSeq: r.playSeq, depthMs: r.depthMs, lostFrames: r.lostFrames, played: r.playedFrames,
    framesRecv: r.framesRecv, farFuture: r.farFuture, ovfSkip: r.overflowSkips,
    reseed: r.reseeds, reanch: r.wlReanchors,
  };
}
console.log('  ' + head.map((h, i) => h.padStart(w[i])).join('  '));
for (const r of rows) {
  console.log('  ' + Object.values(pick(r)).map((v, i) => String(v).padStart(w[i])).join('  '));
}
console.log('');
for (const r of rows) {
  if (r.depthMs !== null && r.depthMs < 0) {
    const deficitFrames = Math.round((-r.depthMs / 1000) * 125);
    console.log(`  D=${r.D}s  depth ${r.depthMs} ms  deficit ${deficitFrames} frames  lostFrames ${r.lostFrames}  ` +
      `(deficit-lost ${deficitFrames - r.lostFrames})  farFuture ${r.farFuture}/${r.framesRecv} of arrivals rejected`);
  }
}
console.log('');
