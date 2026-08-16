/**
 * Lane A worklets — the two ends of the lossless audio pipe.
 *
 *   pcm-capture  mic → 384-sample frames → int24 bytes to the main thread.
 *                Runs on the render thread so a main-thread hitch cannot
 *                tear an 8 ms frame (same reason onset-worklet.js lives here).
 *
 *   pcm-playout  the receive ring + the law of the playout path:
 *                  · SharedArrayBuffer ring written by the network side,
 *                    drained here at the render rate (DESIGN.md §10).
 *                  · Fixed small jitter target, grown on concealment up to
 *                    D_max = 120 ms, shrunk slowly in the quiet (§12).
 *                  · Clock drift absorbed by a continuous resample bounded
 *                    to ±0.2% — never by inserting or dropping samples (§10).
 *                  · A missing frame is concealed by waveform-similarity
 *                    extrapolation for at most 24 ms, then HOLD (silence).
 *                    Never stretched beyond, never Opus-PLC hallucination.
 *                  · The remote onset detector runs HERE, on exactly the
 *                    samples the ear hears — no <audio> element, no
 *                    MediaStreamAudioSourceNode anywhere on this path.
 *
 * The ring has two modes. 'sab' is the design point: the main thread writes
 * PCM into shared memory and publishes per-frame seq tags with release
 * ordering; this worklet reads with acquire ordering — no port hop between
 * the network and the DAC. 'port' is the fallback for a document that is not
 * cross-origin-isolated: frames arrive by port message and the same logic
 * runs on local arrays. pcm.js picks and reports the mode.
 */

import { OnsetDetector } from './core/onset.js';
import { TurnEndPredictor } from './core/turnend.js';
import { createAec } from './core/aec-core.js';
import { createPresence } from './core/presence-core.js';

const FRAME = 384;          // 8 ms at 48 kHz — one frame is one datagram
const RING_F = 64;          // 512 ms of ring — 4× the 120 ms D_max plus slack
const RING = FRAME * RING_F;
const HIST = 2048;          // output history for the concealment search (~42 ms)
const MAX_CONCEAL = 3;      // 24 ms of extrapolation, then HOLD — §10, invariant 4

// SAB byte layout (all views 4/8-byte aligned):
//   0   Int32 ×8: [0] hiSeq1 (highest frame seq written + 1, main→worklet)
//                 [1] playSeq (frame under the playhead, worklet→main, -1 until
//                     started — the writer's accept window depends on telling
//                     "playhead on frame 0" apart from "no playhead yet", and when
//                     this was initialised to 0 it could not)
//                 [2] startSeq (first frame ever received, main→worklet, -1 unset)
//                 [3] targetFrames (jitter target, main→worklet)
//                 [4] playhead-publish seqlock (worklet→main, §10 A-V sync)
//   32  Int32 ×64: seq tag per ring slot — presence is tag[f%64] === f, which
//       a bare bitmap cannot say (a stale bit would pass off 512-ms-old audio
//       as fresh; a stale tag names the wrong seq and fails the check).
//   288 Float64 ×64: sender audio-clock µs of frame f's first sample
//       (capUs, from the capture worklet's currentTime stamp, carried in the
//       wire header) — the A-V sync anchor (§10).
//   800 Float64 ×2: playhead publish [0] = apUs (sender-audio-clock µs of the
//       sample under the playhead), [1] = frame seq under the playhead (-1
//       until started). Written every render block behind the seqlock.
//   816 Float32 × 24576: the ring, frame f at (f%64)*384.
const SAB_HI = 0, SAB_PLAY = 1, SAB_START = 2, SAB_TARGET = 3, SAB_LOCK = 4;
const SAB_BYTES = 816 + RING * 4;

// Capture SAB layout (task #37): WebKit delivers worklet port messages on the
// RENDERING tick (~16.7 ms quantum, stalls to ~60 ms), so a frame posted here
// could sit two rendering frames before dc.send() saw it — measured as the
// whole of the WebKit peer's buffer cost. The ring lets the main thread PULL
// at its own cadence instead of waiting to be handed the frame.
//   0    Int32 ×1 : hi — frames written (seq of next frame), release-stored
//   64   Float64 ×32 : capUs per slot
//   320  Uint8 32×1152 : int24 frames, frame f at (f%32)*1152
const CAP_RING_F = 32; // 256 ms — vastly more than the worst 60 ms stall seen
const CAP_FRAME_B = FRAME * 3;
const CAP_SAB_BYTES = 320 + CAP_RING_F * CAP_FRAME_B;

class PcmCapture extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.acc = new Float32Array(FRAME);
    this.n = 0;
    this.seq = 0;
    // §3.1 lever 4 (Lane 0): the turn-end predictor runs HERE, on the raw mic
    // at zero latency — its job is to hand the network a ~290 ms scheduling
    // window, which a main-thread hop would partly spend. The same estimator
    // family as the onset detector (one autocorrelation pitch pass per 10 ms
    // while active), proven cheap on this thread. Only `predict` and `reset`
    // cross the port — `score` events (100/s) would be port traffic for no
    // decision. processorOptions.turnend gates it: with Lane 0 off the
    // predictor is never constructed and nothing about this worklet changes.
    const o = options?.processorOptions ?? {};
    this.pred = o.turnend ? new TurnEndPredictor({ sampleRate }) : null;
    this.predT0 = -1; // ctx time (s) of the predictor's sample 0
    // Pull mode: write frames into shared memory; the port carries only a
    // payload-free drain hint (and turnend events). Absent capSab, the
    // original transfer-per-frame path below is untouched.
    this.cHi = o.capSab ? new Int32Array(o.capSab, 0, 1) : null;
    this.cTs = o.capSab ? new Float64Array(o.capSab, 64, CAP_RING_F) : null;
    this.cRing = o.capSab ? new Uint8Array(o.capSab, 320, CAP_RING_F * CAP_FRAME_B) : null;
    if (o.aecSab) {
      this.aecHi = new Int32Array(o.aecSab, 0, 1);
      this.aecRing = new Float32Array(o.aecSab, 64, 512 * 128);
      this.aec = createAec();
      this.aecStatBlocks = 0;
      // Preallocated zeros trigger silent-far bypass in core to keep mic bit-exact
      this.aecZeroRef = new Float32Array(128);
    }
  }

  process(inputs) {
    let ch = inputs[0]?.[0];
    if (!ch) return true;
    if (this.aec && ch.length === 128) {
      // 1-block ref offset: previous quantum's block is guaranteed written regardless of execution order
      const k = ((currentFrame / 128) | 0) - 1;
      const ref = (k >= 0 && Atomics.load(this.aecHi, 0) >= k)
        ? this.aecRing.subarray((k % 512) * 128, (k % 512) * 128 + 128)
        : this.aecZeroRef;
      ch = this.aec.process(ch, ref);
      if (++this.aecStatBlocks % 2048 === 0) {
        this.port.postMessage({ type: 'aec2', ...this.aec.stats() });
      }
    }
    if (this.pred) {
      // currentTime is the first sample of this block; the predictor counts
      // samples from its first push, so one anchor converts its `at` indices.
      // With aec2 on, `ch` is the CLEANED block — local echo would otherwise
      // read as voice activity and fake turn-taking signals.
      if (this.predT0 < 0) this.predT0 = currentTime;
      const evs = this.pred.push(ch);
      for (const ev of evs) {
        if (ev.type === 'predict' || ev.type === 'reset') {
          this.port.postMessage({
            type: 'turnend',
            kind: ev.type,
            prob: ev.prob ?? null,
            leadMs: ev.leadMs ?? null,
            ctxTime: this.predT0 + ev.at / sampleRate,
            atMs: (ev.at / sampleRate) * 1000,
          });
        }
      }
    }
    let i = 0;
    while (i < ch.length) {
      const k = Math.min(FRAME - this.n, ch.length - i);
      this.acc.set(ch.subarray(i, i + k), this.n);
      this.n += k;
      i += k;
      if (this.n === FRAME) {
        // int24 LE — the ADC's real ceiling; float32 → 24-bit discards nothing
        // physical (§4). Clamped, never scaled: quality is a constant.
        const buf = this.cRing ? null : new ArrayBuffer(FRAME * 3);
        const u8 = this.cRing
          ? this.cRing.subarray((this.seq % CAP_RING_F) * CAP_FRAME_B, (this.seq % CAP_RING_F + 1) * CAP_FRAME_B)
          : new Uint8Array(buf);
        for (let s = 0; s < FRAME; s++) {
          let x = this.acc[s];
          if (x > 1) x = 1;
          else if (x < -1) x = -1;
          let v = Math.round(x * 8388608);
          if (v > 8388607) v = 8388607;
          else if (v < -8388608) v = -8388608;
          const o = s * 3;
          u8[o] = v & 0xff;
          u8[o + 1] = (v >> 8) & 0xff;
          u8[o + 2] = (v >> 16) & 0xff;
        }
        // §10: stamp the frame with the frame's OWN clock time — the audio
        // context's sample clock (currentTime is the first sample of this
        // render block, so the frame that just completed started FRAME
        // samples before index i), never the port message's delivery time.
        // This is the sender's audio-capture timestamp the A-V sync anchors
        // to; it rides the wire header to the far playout worklet.
        const capUs = (currentTime + (i - FRAME) / sampleRate) * 1e6;
        if (this.cRing) {
          this.cTs[this.seq % CAP_RING_F] = capUs;
          Atomics.store(this.cHi, 0, ++this.seq); // release: bytes+ts land first
          this.port.postMessage(1); // drain hint only — late delivery is harmless
        } else {
          this.port.postMessage({ seq: this.seq++, buf, capUs }, [buf]);
        }
        this.n = 0;
      }
    }
    return true;
  }
}

class PcmPlayout extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const o = options?.processorOptions ?? {};
    this.maxDrift = (o.driftPpm ?? 2000) / 1e6;
    // A separate, wider bound for GIVING BACK latency. See the drift block in
    // process() — draining a burst-inflated buffer and tracking a sender's clock
    // are two different jobs that used to share one bound.
    this.maxDrain = (o.drainPpm ?? 20000) / 1e6; // 2%
    this.buildFast = o.buildFast !== false; // graded BUILD widening (see process)
    this.startTarget = o.targetFrames ?? 2;

    if (o.sab) {
      this.mode = 'sab';
      this.ctl = new Int32Array(o.sab, 0, 8);
      this.tags = new Int32Array(o.sab, 32, RING_F);
      this.capTs = new Float64Array(o.sab, 288, RING_F);
      this.pub = new Float64Array(o.sab, 800, 2);
      this.ring = new Float32Array(o.sab, 816, RING);
      this._present = (f) => Atomics.load(this.tags, f % RING_F) === f;
      this._read = (i) => this.ring[i];
      this._startSeq = () => Atomics.load(this.ctl, SAB_START);
      this._hiSeq = () => Atomics.load(this.ctl, SAB_HI);
      this._target = () => Atomics.load(this.ctl, SAB_TARGET);
    } else {
      this.mode = 'port';
      this.ring = new Float32Array(RING);
      this.tags = new Int32Array(RING_F).fill(-1);
      this.capTs = new Float64Array(RING_F); // per-slot capUs, same role as the SAB array
      this.startSeqP = -1;
      this.hiSeq1 = 0;
      this.targetP = this.startTarget;
      this._present = (f) => this.tags[f % RING_F] === f;
      this._read = (i) => this.ring[i];
      this._startSeq = () => this.startSeqP;
      this._hiSeq = () => this.hiSeq1;
      this._target = () => this.targetP;
    }
    // §10 A-V sync anchor: sender-audio-clock µs of a known frame's first
    // sample. capUs advances by exactly FRAME samples per seq (both are the
    // same render-quantum stream), so one anchor extrapolates to any seq;
    // refreshed from every present frame so a concealment run never walks the
    // estimate far. Published to the main thread as apUs (SAB seqlock, or a
    // throttled port message).
    this.capAnchorSeq = -1;
    this.capAnchorUs = 0;

    // ?presence=1: the room renderer (presence-core.js). Constructed only on
    // the flag — off-arm, `this.presence` is null and process() never takes
    // the stereo branch, so playout stays byte-identical to the mono build.
    // pcm.js opens the node with outputChannelCount [2] iff the flag is on.
    // azimuthDeg places THIS voice in the room (presence-core placement law:
    // ITD + broadband ILD only, both lossless; 0 = centered = the original
    // loop bit-exact). pcm.js sends 0 for the first voice always — placement
    // exists only when a second voice does.
    this.presence = o.presence ? createPresence({ sampleRate, azimuthDeg: o.azimuthDeg ?? 0 }) : null;

    // Playout state. `pos` is a fractional absolute sample index — the
    // resample ratio moves it by slightly more or less than 1 per output
    // sample, which is how drift is absorbed without ever dropping one.
    this.started = false;
    this.pos = 0;
    this.ratio = 1;
    this.curFrame = -1;
    this.curPresent = false;

    // Concealment state.
    this.hist = new Float32Array(HIST);
    this.histPos = 0;
    this.consec = 0;
    this.genLag = 0; // >0 periodic repeat, -1 noise hold
    this.concealedFrames = 0;
    this.heldFrames = 0;
    this.playedFrames = 0;
    this.lateFrames = 0;
    this.overflowSkips = 0;
    // Port-mode counterparts of the SAB path's `ringReseeds` / `farFuture`. Both
    // reported through tick() below: this failure was invisible for as long as it was
    // uncounted, and it is not fixed until it is also observable.
    this.ringReseeds = 0;
    this.farFutureP = 0;

    // The remote detector — on the exact output stream, post-concealment,
    // because "what the detector hears" must equal "what the ear hears".
    this.det = new OnsetDetector({ sampleRate });
    this.startTime = currentTime;
    this.blocks = 0;

    this.port.onmessage = (e) => {
      const m = e.data;
      if (this.mode === 'port' && m?.type === 'frame') this.takeFrame(m.seq, m.samples, m.capUs);
      else if (m?.type === 'target') this.targetP = m.n;
    };
    if (o.aecSab) {
      this.aecHi = new Int32Array(o.aecSab, 0, 1);
      // The slot's EPOCH, in the ring header beside `hi` — the block index the
      // ring's current block belongs to. See process(): with more than one
      // playout node alive the far-end reference has to be their SUM, and this
      // word is how the first writer of a quantum is told apart from the rest.
      // The header was 64 B with 15 words spare, so the ring is unmoved and
      // unresized and its bytes are what they always were.
      this.aecEpoch = new Int32Array(o.aecSab, 4, 1);
      this.aecRing = new Float32Array(o.aecSab, 64, 512 * 128);
    }
  }

  // Port-mode frame intake, with the same window guard the SAB writer applies
  // on the main thread: too old is late (counted, never written — writing
  // behind the playhead would corrupt a slot the playhead is about to read),
  // too far ahead cannot be real at any reachable jitter.
  takeFrame(seq, samples, capUs) {
    if (this.startSeqP < 0) this.startSeqP = seq;
    // Before the playhead exists there is nothing to protect, so the window must track
    // the NEWEST frames rather than staying pinned to the first one ever seen. Pinned,
    // this ring filled with startSeqP..+63 and rejected everything after it for the
    // whole of a slow audio-graph startup; the SAB path had the identical bug and it
    // cost ~23 s of a call's audio while every transport counter read perfect (see the
    // re-seed in pcm.js ringWrite for the measured 1.008 s cliff). `this.started` is
    // exact here — same thread as the playhead — so there is no staleness to guard.
    if (!this.started && seq >= this.startSeqP + RING_F) {
      this.ringReseeds++;
      this.tags.fill(-1);
      this.startSeqP = seq;
    }
    const lo = this.started ? Math.floor(this.pos / FRAME) : this.startSeqP;
    if (seq < lo) { this.lateFrames++; return; }
    if (seq >= lo + RING_F) { this.farFutureP++; return; }
    if (this.tags[seq % RING_F] === seq) return;
    this.ring.set(samples, (seq % RING_F) * FRAME);
    this.tags[seq % RING_F] = seq;
    if (typeof capUs === 'number') this.capTs[seq % RING_F] = capUs;
    if (seq + 1 > this.hiSeq1) this.hiSeq1 = seq + 1;
  }

  // Sender-audio-clock µs of the sample under the playhead (§10). The anchor
  // refreshes from every present frame's capTs; between anchors (concealment)
  // it extrapolates at the exact sample rate — capUs and seq are the same
  // clock, so extrapolation is drift-free.
  apUsNow() {
    const f = Math.floor(this.pos / FRAME);
    if (this._present(f)) {
      const c = this.capTs[f % RING_F];
      if (c !== 0) {
        this.capAnchorSeq = f;
        this.capAnchorUs = c;
      }
    }
    if (this.capAnchorSeq < 0) return null;
    return this.capAnchorUs + (this.pos - this.capAnchorSeq * FRAME) * (1e6 / sampleRate);
  }

  process(_inputs, outputs) {
    const out = outputs[0]?.[0];
    if (!out) return true;
    this.fill(out);
    if (this.aecRing && out.length === 128) {
      // ── The far-end reference is a SUM, not last-writer-wins (§5.2) ────────
      // At three people there are two playout nodes and the Web Audio graph
      // sums them at the destination, so what the speakers actually emit — the
      // only signal a canceller can subtract — is that sum. A plain .set() here
      // would leave the reference carrying whichever node the graph happened to
      // run last, and the OTHER remote voice would come back as uncancelled
      // echo with every counter green. That is the single most expensive
      // failure in the three-person design, so the write is epoch-tagged: the
      // block index k tags the slot, the first node to reach it this quantum
      // WRITES, every later one ADDS.
      //
      // One epoch word covers all 512 slots because every playout node in a
      // render quantum sees the same `currentFrame` and therefore the same k —
      // the slot's identity IS k. The compareExchange claims k once; whoever
      // loses the claim is a later writer by definition. These nodes share one
      // audio thread, so this is ordering, not contention. At one node the
      // claim always succeeds and the ring's bytes are what they were.
      //
      // Still BEFORE presence.render(): the canceller's reference must be the
      // pristine mono lane, and the room exists only in the last metres.
      const k = (currentFrame / 128) | 0;
      const base = (k % 512) * 128;
      const prev = Atomics.load(this.aecEpoch, 0);
      const first = prev !== k && Atomics.compareExchange(this.aecEpoch, 0, prev, k) === prev;
      if (first) this.aecRing.subarray(base, base + 128).set(out);
      else for (let i = 0; i < 128; i++) this.aecRing[base + i] += out[i];
      Atomics.store(this.aecHi, 0, k);
    }
    this.detect(out);
    // Presence renders LAST: the AEC2 far-end ref and the remote onset
    // detector above both saw the pristine mono block — the room exists only
    // between here and the DAC. outL aliases `out` (the core reads each index
    // before writing it, so in-place is safe); without a second channel the
    // renderer is skipped even if constructed.
    const outR = outputs[0]?.[1];
    if (this.presence && outR) this.presence.render(out, out, outR);
    this.tick();
    return true;
  }

  fill(out) {
    if (!this.started) {
      const start = this._startSeq();
      if (start < 0) { out.fill(0); return; }
      // Prime: hold playout until `target` frames are buffered. Holes in the
      // priming window are fine — they will be concealed like any other gap.
      //
      // THE SCAN MUST BE AT LEAST AS WIDE AS THE TARGET IT IS TRYING TO SATISFY.
      // This window was a hardcoded 16 while `target` comes from the adaptive
      // controller, so the instant the controller asked for more than 16 frames
      // `have` could not reach `target` and priming could NEVER complete. That
      // was latent for as long as maxTargetFrames was 15 (15 < 16, always
      // satisfiable) and went live the same day the ceiling was raised to 32 to
      // survive a 185 ms-spread Delhi <-> Netherlands call.
      //
      // It does not fail quietly, it fails ESCALATINGLY. Measured live on that
      // call (room ilx-swig-xox, both ends):
      //   targetFrames 32, jitWantMaxRun 32 from the very first sample
      //   playedFrames frozen at 21 (Brave) / 16 (Safari)
      //   concealed climbing 1000 ms per second — 100% of wall time, all held
      //   late climbing at exactly the arrival rate: every frame rejected
      //   depthMs -8537, ringReseeds 0
      // The playhead advances on its own clock while priming stalls, so
      // `lo = max(startSeq, play)` outruns the stream; every arriving frame is
      // then late, and every late frame calls bumpTarget('late'), which pins the
      // target at the ceiling and keeps priming impossible. The one re-anchor
      // path in pcm.js is gated on `play < 0` — unreachable once the playhead
      // has moved — which is why ringReseeds stayed 0 while the lane starved.
      //
      // So the span follows the target, and the target is clamped to what the
      // ring can actually hold: a future ceiling change cannot recreate this.
      const target = Math.min(RING_F - 8, this._target());
      const span = Math.min(RING_F, target + 16);
      let have = 0;
      for (let f = start; f < start + span && have < target; f++) if (this._present(f)) have++;
      if (have < target) { out.fill(0); return; }
      this.pos = start * FRAME;
      this.curFrame = -1;
      // PUBLISH THE PLAYHEAD BEFORE DECLARING IT STARTED. The writer on the main thread
      // re-seeds the ring only while SAB_PLAY < 0, and these are two different threads:
      // if `started` were set first, the writer could still read -1 and clear the tags
      // out from under a playhead that had just begun. The window is a few statements
      // wide and the cost would only be a few concealed frames, but ordering the store
      // first removes it rather than relying on it being narrow. The loop below stores
      // the same value again on its first iteration, which is harmless.
      if (this.mode === 'sab') Atomics.store(this.ctl, SAB_PLAY, start);
      this.started = true;
    }

    for (let i = 0; i < out.length; i++) {
      const f = Math.floor(this.pos / FRAME);
      if (f !== this.curFrame) {
        this.curFrame = f;
        if (this.mode === 'sab') Atomics.store(this.ctl, SAB_PLAY, f);
        if (this._present(f)) {
          this.curPresent = true;
          this.consec = 0;
          this.playedFrames++;
        } else {
          // The one deliberate exception to invariant 4 — bounded, counted,
          // and structurally incapable of inventing speech (§10).
          this.curPresent = false;
          this.consec++;
          this.concealedFrames++;
          if (this.consec === 1) this.port.postMessage({ type: 'pcm-conceal' });
          if (this.consec > MAX_CONCEAL) {
            this.genLag = 0; // HOLD — silence, never stretched beyond 24 ms
            this.heldFrames++;
          } else {
            this.beginGen();
          }
        }
      }

      let s;
      if (this.curPresent) {
        const i0 = Math.floor(this.pos) % RING;
        const i1 = (i0 + 1) % RING;
        const fr = this.pos - Math.floor(this.pos);
        s = this._read(i0) + (this._read(i1) - this._read(i0)) * fr;
      } else {
        s = this.concealSample(Math.floor(this.pos) - f * FRAME);
      }
      out[i] = s;
      this.hist[this.histPos % HIST] = s;
      this.histPos++;
      this.pos += this.ratio;
    }

    // Drift control (§10): occupancy error → continuous resample ratio,
    // bounded to ±0.2% — inaudible on speech, and it never inserts or drops
    // a sample. Full correction over ~4 s so jitter doesn't move the pitch.
    const occupancy = this._hiSeq() * FRAME - this.pos;
    const err = occupancy - this._target() * FRAME;
    const r = 1 + err / (sampleRate * 4);
    // One bound used to serve two jobs with opposite requirements. Tracking a
    // sender's clock is permanent and must be inaudible, so ±0.2% is right for it.
    // Giving back latency after a loss burst inflated the buffer is temporary and
    // one-directional — and at 0.2% it takes ~45 s to return 90 ms, which is why a
    // network that healed a minute ago still felt laggy. Measured on production:
    // a 30 s burst at 3% loss pushed mouth-to-ear from ~55 ms to ~145 ms and it
    // was still elevated 110 s after the loss stopped.
    //
    // So the speed-up side alone gets a wider allowance, and only while the excess
    // is big: below 25 ms of excess this is byte-for-byte the old behaviour, so
    // steady state is untouched and only recovery changes. Speech tolerates a
    // couple of percent far better than it tolerates a stale conversation —
    // Boland et al. 2022 put the cost of inflated gaps at 5-10x the raw delay.
    const excessMs = err / (sampleRate / 1000);
    const up = excessMs <= 25
      ? this.maxDrift
      : Math.min(this.maxDrain, this.maxDrift + ((excessMs - 25) * (this.maxDrain - this.maxDrift)) / 75);
    // The BUILD side gets the same graded widening, for the mirror-image reason.
    // Measured (testbed/elasticring.mjs, 2026-08-16): the elastic ceiling raised
    // the target 32->48f under recurring 320 ms bursts and concealment did not
    // move AT ALL — identical 963 frames in both arms — because depth toward a
    // raised target could only build at 0.2% (2 ms/s), i.e. ~170 s to honor a
    // raise the bursts demanded NOW. A buffer that answers "grow" a scene later
    // is a clamp with extra steps. Below 25 ms of deficit this is byte-for-byte
    // the old behaviour, so steady-state clock tracking is untouched; only the
    // response to a genuinely starved buffer changes, and it heals in seconds
    // instead of minutes. Same graded shape and the same 2% cap as the drain.
    const deficitMs = -excessMs;
    const down = (!this.buildFast || deficitMs <= 25)
      ? this.maxDrift
      : Math.min(this.maxDrain, this.maxDrift + ((deficitMs - 25) * (this.maxDrain - this.maxDrift)) / 75);
    this.ratio = r > 1 + up ? 1 + up : r < 1 - down ? 1 - down : r;

    // Ring overflow: the sender is persistently faster than us past the
    // resample bound. Skipping forward is honest (counted) — letting the
    // playhead drift into the guard window is silent corruption.
    if (occupancy > (RING_F - 4) * FRAME) {
      this.pos = this._hiSeq() * FRAME - this._target() * FRAME;
      this.curFrame = -1;
      this.overflowSkips++;
    }

    // §10 A-V sync: publish where the playhead is, in the SENDER's audio
    // clock, so the main thread can present the video frame whose (mapped)
    // capture time is nearest audio_playout_time + offset. SAB: a seqlocked
    // pair every render block (~2.7 ms). Port: a throttled message (~50 ms)
    // — port mode's A-V sync is that much coarser, and says so downstream.
    if (this.started) {
      const ap = this.apUsNow();
      if (ap != null) {
        if (this.mode === 'sab') {
          const l = Atomics.load(this.ctl, SAB_LOCK);
          Atomics.store(this.ctl, SAB_LOCK, l + 1); // odd = write in flight
          this.pub[0] = ap;
          this.pub[1] = Math.floor(this.pos / FRAME);
          Atomics.store(this.ctl, SAB_LOCK, l + 2); // even = stable
        } else if (this.blocks % 19 === 0) {
          this.port.postMessage({ type: 'pcm-playhead', apUs: ap, seq: Math.floor(this.pos / FRAME) });
        }
      }
    }
  }

  beginGen() {
    // Waveform-similarity: find the period of the last ~20 ms by normalized
    // autocorrelation and repeat it. 8 ms of waveform cannot invent a word —
    // which is the entire difference from codec PLC (§10).
    const H = this.hist, hp = this.histPos;
    let bestCorr = 0, bestLag = 0;
    for (let lag = 40; lag <= 480; lag += 2) {
      let num = 0, aa = 0, bb = 0;
      for (let i = 0; i < 480; i += 2) {
        const a = H[(hp - 480 + i + HIST) % HIST];
        const b = H[(hp - 480 + i - lag + 2 * HIST) % HIST];
        num += a * b; aa += a * a; bb += b * b;
      }
      const c = num / (Math.sqrt(aa * bb) + 1e-9);
      if (c > bestCorr) { bestCorr = c; bestLag = lag; }
    }
    for (let lag = Math.max(40, bestLag - 2); lag <= Math.min(480, bestLag + 2); lag++) {
      let num = 0, aa = 0, bb = 0;
      for (let i = 0; i < 480; i++) {
        const a = H[(hp - 480 + i + HIST) % HIST];
        const b = H[(hp - 480 + i - lag + 2 * HIST) % HIST];
        num += a * b; aa += a * a; bb += b * b;
      }
      const c = num / (Math.sqrt(aa * bb) + 1e-9);
      if (c > bestCorr) { bestCorr = c; bestLag = lag; }
    }
    this.genLag = bestCorr > 0.3 ? bestLag : -1;
  }

  concealSample(i) {
    if (this.genLag === 0) return 0; // HOLD
    if (this.genLag > 0) {
      // Phase-continuous by construction: each generated sample repeats the
      // one exactly genLag before the write head, so the period walks forward
      // through the history and onto the generated tail without a seam.
      return this.hist[(this.histPos - this.genLag + 2 * HIST) % HIST];
    }
    // Noise-like content has no period to repeat; hold a fading tail.
    const fade = 1 - 0.6 * (i / FRAME);
    return this.hist[(this.histPos - 64 + 2 * HIST) % HIST] * fade;
  }

  detect(out) {
    const events = this.det.push(out);
    if (++this.blocks % 19 === 0) {
      let sum = 0;
      for (let i = 0; i < out.length; i++) sum += out[i] * out[i];
      this.port.postMessage({
        type: 'level',
        rmsDb: 20 * Math.log10(Math.max(Math.sqrt(sum / out.length), 1e-10)),
        floorDb: this.det.noiseFloorDb,
        state: this.det.state,
        quietHops: this.det.quietHops,
        activeHops: this.det.activeHops,
      });
    }
    for (const ev of events) {
      this.port.postMessage({
        ...ev,
        ctxTime: this.startTime + ev.at / sampleRate,
        atMs: (ev.at / sampleRate) * 1000,
      });
    }
  }

  tick() {
    if (this.blocks % 375 !== 0) return; // ~1 s
    this.port.postMessage({
      type: 'pcm-stats',
      mode: this.mode,
      started: this.started,
      playedFrames: this.playedFrames,
      concealedFrames: this.concealedFrames,
      heldFrames: this.heldFrames,
      lateFrames: this.lateFrames,
      overflowSkips: this.overflowSkips,
      ringReseeds: this.ringReseeds,
      farFutureP: this.farFutureP,
      driftPpm: Math.round((this.ratio - 1) * 1e6),
      depthMs: this.started ? +((this._hiSeq() * FRAME - this.pos) / (sampleRate / 1000)).toFixed(1) : null,
      targetFrames: this._target(),
      playSeq: this.started ? Math.floor(this.pos / FRAME) : -1,
      presence: this.presence ? this.presence.stats() : null,
    });
  }
}

registerProcessor('pcm-capture', PcmCapture);
registerProcessor('pcm-playout', PcmPlayout);
