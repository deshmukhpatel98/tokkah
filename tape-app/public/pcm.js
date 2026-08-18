/**
 * Lane A — lossless PCM audio (DESIGN.md §4, §9–§11).
 *
 * The single biggest remaining gap to the goal: today audio is Opus 128 kbps
 * (measured fullband-flat, but still a codec); this lane is 48 kHz / 24-bit
 * linear PCM, no encoder, no decoder, no PLC, over the wire.
 *
 *   mic → pcm-capture worklet → 8 ms frames (384 samples, 1,152 B int24)
 *       → one unreliable/unordered datagram each, 125 pps, ~1.5 Mbps with FEC
 *       → sliding-window FEC (core/pcmsw.js, DEFAULT since 2026-08-04: repair
 *         delay bounded by the 3-frame stride instead of the group span;
 *         `?pcmsw=0` restores block RS(10,13) (core/pcmrs.js) as the control
 *         arm — parity paced one packet per tick either way, never clumped)
 *       → pcm-playout worklet on a SharedArrayBuffer ring → destination.
 *
 * Laws this lane lives under (all from HANDOFF.md / DESIGN.md):
 *   · The mic is taken OFF the peer connection at page load, before addTrack,
 *     so no renegotiation can ever involve it (same as lane-1 video). This
 *     module never calls setParameters, never renegotiates.
 *   · Media datagrams never touch a reliable channel: `pcm-audio` is
 *     unordered, maxRetransmits 0 — ctl's SCTP reliability is a delay line
 *     under congestion (law 16).
 *   · No <audio> element, no MediaStreamAudioSourceNode on the playout path.
 *     The remote onset detector runs inside the playout worklet, on the exact
 *     samples the ear hears, so the detector event stream (onset/breath/
 *     turn/floorDb) keeps its shape and its shared-context clock origin.
 *   · AnalyserNode is deaf on this graph — everything here is worklets.
 *   · Quality is a constant; time is the only shock absorber. Never
 *     downsampled, never ducked, never compressed. Gap concealment is
 *     waveform-similarity extrapolation for at most 24 ms, then HOLD.
 *
 * The capture→send port hop and the playout ring are the only queueing the
 * lane has; both are measured and reported in snapshot().
 *
 * Striping (DESIGN.md §17.12, cfg.pairs = `?pcmpairs=`): SCTP's RFC 4960 AIMD
 * ceiling is per ASSOCIATION (1.22·MTU/(RTT·√p) ≈ 1.5 Mbps at RTT 80 / 1% loss;
 * Lane A needs ~1.8 on the wire), so at pairs=N the exact same byte stream is
 * striped round-robin across N data-channel-only peer connections — seq k rides
 * association k mod N, frames still leave at their capture tick, no bundling
 * (measured: buys nothing, costs 8–24 ms). The receiver needs no changes of
 * principle: the SAB ring is seq-tagged per slot and RS groups key off seq, so
 * any arrival order was already tolerated. What striping changes here is
 * accounting: ping/baseRtt/bufferedAmount/backpressure are per-association
 * (§17.12's caveat), and a frame whose home association is over its gate budget
 * tries the NEXT association before being spent as a gap — the stripe exists to
 * absorb exactly this. pairs=1 is byte-for-byte today's behaviour.
 */

import { createEchoDetector } from './echo-detect.js';
import { audioContext, addWorkletModule } from './onset-monitor.js';
import { RsEncoder, rsDecode, RS_K, RS_P, setRsK } from './core/pcmrs.js';
import { SwEncoder, SwDecoder, SW_STRIDE } from './core/pcmsw.js';
import { packFrame, unpackFrame } from './core/pcmpack.js';

const FRAME_BYTES = 1152; // 384 samples × int24
const FRAME_MS = 8;       // 384 samples at 48 kHz — the seq→time constant
// 24-byte header: u8 type | u8 parity-idx | u16 bitmap | u32 seq/base |
// f64 wall | f64 capUs (sender audio-clock µs of the frame's first sample —
// §10's A-V sync anchor; spare in parity messages). capUs was added with
// A-V sync; this lane only exists under ?pcmaudio=1, so flag-off wire
// behaviour is untouched.
const HDR = 24;
const T_DATA = 0x01, T_PARITY = 0x02, T_PING = 0x50, T_PONG = 0x51;
// ── Compact framing (the 16 bytes that were costing 2.4× the loss) ──────────
// A datachannel message that exceeds one datagram is lost if EITHER piece is
// lost, so its effective loss rate is 1-(1-p)^k. `testbed/mtuprobe.mjs` measures
// the boundary directly off the emulator's packet histogram: one datagram up to
// 1160 B, two from 1162 B (~77 B of DTLS/SCTP overhead). The 24 B header put a
// data frame at 1176 B — over by 16 — and measured 13.4% frame loss on a link
// dropping 5.56%, which is what RS(10,13) could not absorb (3 erasures in 13
// covers 5.6% with ~0.3% of groups failing; at 13.4% it is ~8%).
//
// The 16 bytes are the two f64s, and neither needs to be on every frame:
//   capUs  advances by exactly 8000 µs per seq — the receiver ALREADY
//          extrapolates it in capUsFor(), because an FEC-repaired frame has no
//          header to read it from. It only ever needed an anchor, not a copy.
//   wall   is read on the data path for exactly one thing, the ageMs stat.
//          Derived from the anchor it becomes time-since-ideal-capture rather
//          than time-since-send, which is the better anchor for A-V sync
//          anyway: it excludes our own send jitter from the peer's latency.
// So both move to a 21 B anchor sent 4×/s (84 B/s) and the per-frame header
// drops to the fields the receiver actually reads. Data: 5 B -> 1157 B. Parity
// reads idx/bitmap/base and never its wall, so 8 B -> 1160 B. Both fit one
// datagram; the old 1176 B did not.
//
// RS is untouched: parity covers payload only, so header size never entered it.
const T_DATA_C = 0x03; // u8 type | u32 seq
const T_PAR_C = 0x04;  // u8 type | u8 idx | u16 bitmap | u32 base
const T_ANCH = 0x05;   // u8 type | u32 seq | f64 wall | f64 capUs
// Same header as T_DATA_C, but the payload is losslessly compressed and
// VARIABLE length (see core/pcmpack.js). Speech measures 0.56 of raw, and the
// point is the RATE, not the bytes: the SCTP window is per association and
// carries only ~0.4 Mbps at 5% loss, so a lane offering 1.95 Mbps was over the
// ceiling on 3 stripes and is still tight on 6. The codec's verbatim escape
// bounds the payload at 1153 B, so the worst frame is 5 + 1153 = 1158 B and
// still inside the 1160 B single-datagram budget.
const T_DATA_Z = 0x06;
// Loss report, 2 B, 4×/s on every open association: `u8 type | u8 lossQ`,
// lossQ = round(loss% × 4), saturating at 63.75%. It travels the OPPOSITE way
// to the audio it describes — a receiver reports what it is missing so the
// PEER can set its own code rate (see the parity ladder). Unknown types fall
// off the end of onMessage(), so a peer running an older build simply ignores
// it and stays at the fixed rate; nothing has to be negotiated.
const T_LOSS = 0x07;
// Skew report, 8 B at pairs=6, 4×/s: `u8 type | u8 warmMask | u8 skewQ[lanes]`,
// lanes = min(PAIRS, byteLength - 2) — the PAIRS clamp is what makes the same
// parse read both the 8 B and 9 B forms. skewQ = min(255, round(skew_ms*2)); 255 means
// "saturated at ≥127.5 ms", still a valid (and alarming) reading. warmMask bit
// k says lane k's estimate is warm; a cold lane's 0 is "unknown", not "aligned",
// and the mask is what keeps a striping policy from ever acting on it. Assumes
// PAIRS ≤ 8 (it is 6). Receiver reports per-lane skew so the sender can make
// skew-aware striping decisions (lane-skew Stage 1).
const T_SKEW = 0x09;
const HDR_DATA_C = 5, HDR_PAR_C = 8, HDR_ANCH = 21;
// The largest RS symbol that still leaves parity inside one datagram:
// 1160 - HDR_PAR_C. It is also exactly FRAME_BYTES, so uncompressed groups are
// unaffected. A compressed frame CAN exceed it by one byte — the verbatim
// escape is 1153 — and such a frame is excluded from its group rather than
// allowed to fragment every parity message in it (measured: 0 of 6,827 real
// frames, testbed/pcmpack-test.mjs; the escape only fires on white noise).
const RS_SYM_MAX = 1160 - HDR_PAR_C;
// §3.1 levers 3+4 / §4 Lane 0 (gated by cfg.lane0 — with it off these types
// never exist on the wire and the lane is byte-identical to before):
//   T_PRED  a turn-end prediction, a few bytes of scheduling metadata, sent
//           DUPLICATED (two copies back to back — at this size redundancy is
//           free and a retransmit round trip would defeat the point, §4).
//           Never FEC'd, never in an RS group, never in the member bitmap.
//   T_PAD   pre-warm padding. The receiver discards it ON SIGHT: it never
//           enters a group, the ring, the playhead, or the detector. It exists
//           only to re-open the sender's decayed SCTP cwnd after a listening
//           stretch (cwnd is per association — all N stripes are padded).
const T_PRED = 0x60, T_PAD = 0x61;
// Sliding-window parity (core/pcmsw.js, `?pcmsw=1`). SENDER-side flag: it
// switches what parity THIS sender emits (T_PAR_SW instead of T_PAR_C), while
// every receiver understands both types unconditionally — so one side of a
// call can run the window against the other side's block RS, and a paired
// A/B lives inside ONE call instead of across sessions. A peer on an older
// build simply ignores the unknown type (falls off onMessage) and conceals at
// raw loss; nothing else breaks.
//   u8 type | u8 s (parity seq mod 256 — coeff() only needs s mod 128, and two
//   live parities 128 apart would be 128×stride ≥ 256 frames apart, far past
//   the decode horizon, so 8 bits cannot collide) | u16 bitmap | u32 end.
const T_PAR_SW = 0x08;
const HDR_PAR_SW = 8;
const SW_SYM_MAX = 1160 - HDR_PAR_SW; // same one-datagram ceiling as RS parity
const SAB_HI = 0, SAB_PLAY = 1, SAB_START = 2, SAB_TARGET = 3, SAB_LOCK = 4;
const RING_F = 64;

const now = () => performance.timeOrigin + performance.now();

/**
 * @param {object} o
 * @param {MediaStream} o.stream        local mic stream (audio track 0)
 * @param {object} o.cfg                { fec, targetFrames, maxTargetFrames, driftPpm, queueBytes }
 * @param {(tag: string, d: object) => void} o.log
 * @param {(ev: object) => void} o.onEvent   remote-detector events (onset/end/level/…)
 * @param {(n: number) => void} o.onConceal  concealment-run start, for onset stamping
 * @param {(ev: object) => void} o.onTurnEnd  Lane 0: local-mic turn-end predictor events
 * @param {(ev: object) => void} o.onPredict  Lane 0: a peer's T_PRED arrived (deduped)
 */
export function initPcmAudio({ stream, cfg, log, onEvent, onConceal, onTurnEnd, onPredict, onEchoDetected }) {
  const L = (tag, d) => { try { log?.(tag, d); } catch { /* telemetry must never break the call */ } };

  const det = cfg?.echoDetect !== false ? createEchoDetector() : null;
  let echoTimer = null;
  if (det) {
    echoTimer = setInterval(() => {
      if (closed) return;
      const res = det.poll(now());
      if (res) {
        L('echo-detected', res);
        try { onEchoDetected?.(res); } catch { /* the latch must not kill the timer */ }
        clearInterval(echoTimer); // one-way latch: nothing left to poll for
      }
    }, 500);
  }

  // FIRST, before anything reads RS_K — stats below sizes arrays from it, and so
  // do the group staging buffers. `?pcmrsk=` must be set identically on both
  // peers (see setRsK): the receiver derives its groups from `seq % RS_K`, so a
  // mismatch groups different frames together rather than degrading gracefully.
  if (cfg?.rsK != null) setRsK(cfg.rsK);

  // ── The split (§5.1): one capture half, N receive halves ──────────────────
  // Everything from here to `createPeerHalf` belongs to the PAGE and is built
  // exactly once per call: the mic's capture worklet and its ring, the frame
  // sequence space, the compressor, the turn-end predictor, the echo detector's
  // mic tap, and the AEC2 far-end reference ring. Everything inside
  // `createPeerHalf` belongs to ONE peer: its associations, its receive ring and
  // playout worklet, its FEC decode, its parity ladder, its ping/pong, its
  // snapshot. The send path offers each captured frame to every half.
  //
  // The seam is the one the file already drew: every congestion-flavoured
  // counter was documented as per ASSOCIATION (`newAssoc` below), and "per peer"
  // is a coarser grouping of the same thing. Two whole instances would mean two
  // capture worklets on one track, two frame-sequence spaces, two compressors
  // doing identical work — and two playout worklets fighting over one far-end
  // reference, which is echo with every counter green.
  //
  // With ONE half — which is all app.js builds today — this is the same code in
  // the same order it ran before: same graph, same SABs, same wire, same fields.
  const sabOk = typeof SharedArrayBuffer !== 'undefined' && globalThis.crossOriginIsolated === true;
  // The ring mode is a property of the PAGE (cross-origin isolation), not of a
  // peer: every half allocates its ring under the same test, so one answer
  // covers the call and each half reports it.
  const mode = sabOk ? 'sab' : 'port';

  // Compact framing on by default; `?pcmc=0` keeps the 24 B header so the two
  // can be A/B'd through the identical measurement path. The RECEIVER always
  // understands both, so a compact sender talking to a legacy receiver is the
  // only unsupported pairing — a call already in progress across a deploy.
  const COMPACT = cfg.compact !== false;
  // 4×/s. Short enough that extrapolation error is one frame's jitter refreshed
  // constantly, cheap enough (84 B/s) not to be worth tuning.
  const ANCHOR_MS = cfg.anchorMs || 250;
  // Lossless frame compression. Gated on COMPACT because the legacy 24 B header
  // exists only as a control arm and the cross product is not worth carrying.
  // `?pcmz=0` turns it off; the receiver understands both regardless, since the
  // wire type says which one arrived.
  const ZIP = COMPACT && cfg.zip !== false;
  // Wasted-bits (see core/pcmpack.js). ENCODER ONLY: the decoder always honours
  // the shift in the header, so an A/B with one arm off still interoperates in
  // both directions. `?pcmwaste=0` is the control arm — carried because a
  // comparison against a baseline recorded in an earlier session is worth much
  // less on this project than an interleaved one, and because a change that
  // halves the lane deserves an off switch that does not need a deploy.
  const WASTED = cfg.wastedBits !== false;
  const RS_FIXED = cfg.rsFixed === true;          // control arm, see rsClose()
  // `?pcmfecadapt=0` pins the old fixed RS(10,13). `?pcmfecmax=` caps how far
  // the ladder may climb; it cannot exceed RS_P, because the Cauchy matrix in
  // core/pcmrs.js only has that many rows.
  const FEC_ADAPT = cfg.fecAdapt !== false;
  // NaN-hostile: `?pcmfecmax=abc` must fall back to the full ladder, not poison
  // it. A NaN cap makes every `want > fecN` and `want < fecN` false, which pins
  // the rate silently at its initial value — a probe that looks like it ran.
  const FEC_N_MAX = Number.isFinite(cfg.fecNMax)
    ? Math.max(0, Math.min(RS_P, cfg.fecNMax)) : RS_P;
  // The rung the ladder may never descend below. n=0 is the cheapest possible
  // link but it is the only rung with a REACTION TIME: no parity is in flight,
  // so the first burst on a quiet link is unprotected until a report crosses
  // and takes effect. n=1 repairs any single erasure in its group instantly and
  // for 10% redundancy, which is the common case (isolated datagram loss).
  const FEC_N_MIN = Number.isFinite(cfg.fecNMin)
    ? Math.max(0, Math.min(FEC_N_MAX, cfg.fecNMin)) : 0;
  const zipIn = new Int32Array(384);              // samples in, for the encoder
  const zipOut = new Uint8Array(1 + 384 * 3);     // packed bytes out

  // rungTop[n] = the highest loss %, in percent, that n parity symbols still
  // hold under CONCEAL_TARGET. Built once per call from RS_K; ~40 binomial
  // evaluations per rung, at stream start only.
  const CONCEAL_TARGET = 0.1;
  const rungTop = (() => {
    const binom = (n, k) => { let r = 1; for (let i = 0; i < k; i++) r = (r * (n - i)) / (i + 1); return r; };
    // Expected concealed data frames per 100 sent, for RS(RS_K, RS_K+n) at loss
    // p. A group survives iff erasures <= n; when it fails only the ERASED data
    // symbols are concealed, and K/N of the erasures are data on average.
    const conceal = (n, p) => {
      const N = RS_K + n;
      let f = 0;
      for (let e = n + 1; e <= N; e++) f += binom(N, e) * p ** e * (1 - p) ** (N - e) * e * (RS_K / N);
      return (f / RS_K) * 100;
    };
    const tops = [];
    for (let n = 0; n <= RS_P; n++) {
      let lo = 0, hi = 0.5;
      for (let i = 0; i < 40; i++) {
        const mid = (lo + hi) / 2;
        if (conceal(n, mid) <= CONCEAL_TARGET) lo = mid; else hi = mid;
      }
      tops.push(lo * 100);
    }
    return tops;
  })();
  function ladderFor(pct) {
    for (let n = 0; n < RS_P; n++) if (pct <= rungTop[n]) return n;
    return RS_P;
  }

  // Backpressure is spent as a gap, never as queue: audio that arrives late
  // is worse than audio the concealer covers (lane-1 admission philosophy).
  // But bufferedAmount counts *in-flight unacked* bytes, and at RTT 80 ms a
  // healthy 1.5 Mbps stream holds ~16 KB in flight permanently — a fixed 6 KB
  // gate drops half of capture on any non-loopback path (measured: pcm-loss,
  // 46% of frames dropped on a clean wire). Budget against the lane's DESIGN
  // rate, not the measured one — measuring the throttled rate locks the
  // throttle in (measured: pcm-loss2, same collapse at a self-limiting
  // equilibrium). Throughput ≤ offered by definition, so RTT × offered bounds
  // healthy in-flight bytes; anything beyond it (×1.5 for SACK/abandon lag,
  // plus two frames) is a true congestion queue, and that is what gets dropped.
  const OFFER_BPS = (1000 / 8) * (HDR + FRAME_BYTES) * 1.3; // 125 pps × 1168 B, +30% FEC
  // The budget is per-association: each stripe carries ~1/N of the bytes, but
  // its gate is the FULL design-rate budget — an association absorbing spilled
  // frames from a congested sibling needs headroom for exactly that, and a
  // gate shrunk by 1/N would re-create the wall the stripe exists to remove.
  function backlogLimit(a) {
    const rtt = a.baseRttMs ?? 0;
    if (rtt <= 0) return cfg.queueBytes;
    return Math.max(cfg.queueBytes, (rtt / 1000) * OFFER_BPS * 1.5 + 2 * (HDR + FRAME_BYTES));
  }

  // ── Stage timing diagnostics (?pcmdiag=1, task #37) ────────────────────────
  // The WebKit peer costs 9x the buffer and we have never known WHICH STAGE
  // owns the spread: worklet capture emission, datachannel departure, or wire
  // arrival. Three interval recorders, one per stage, kept as coarse
  // percentile-ready reservoirs. Off by default: two Date.now()s per frame is
  // cheap but this lane has a rule against unconditional instrumentation.
  const DIAG = !!cfg.pcmDiag;
  function intervalRec() {
    let last = 0;
    const N = 4096; const buf = new Float32Array(N); let n = 0, i = 0;
    return {
      hit(t) { if (last) { buf[i] = t - last; i = (i + 1) % N; if (n < N) n++; } last = t; },
      stats() {
        if (n < 32) return null;
        const a = [...buf.slice(0, n)].sort((x, y) => x - y);
        const q = (f) => +a[Math.min(n - 1, Math.floor(f * n))].toFixed(2);
        return { n, p50: q(0.5), p90: q(0.9), p99: q(0.99), max: +a[n - 1].toFixed(2) };
      },
    };
  }
  const diagCap = DIAG ? intervalRec() : null;  // worklet frame handed to main thread

  let closed = false;
  let ctx = null, capNode = null, source = null;

  // ── Capture ring (task #37) ────────────────────────────────────────────
  // WebKit hands worklet port messages to the main thread on the rendering
  // tick (~16.7 ms, stalling to ~60 ms under load) — measured as the entire
  // WebKit-peer buffer cost: departure cadence == capture-delivery cadence,
  // wire adds nothing. So capture mirrors playout: frames go into shared
  // memory on the audio thread and the main thread PULLS on its own timer
  // chain (a 0 ms setTimeout chain clamps to ~4 ms — half a frame) instead of
  // waiting to be scheduled. ?pcmcap=0 keeps the old push path as the control.
  const CAP_RING_F = 32;
  const capSab = (sabOk && cfg.pcmCapSab !== false)
    ? new SharedArrayBuffer(320 + CAP_RING_F * FRAME_BYTES) : null;
  const aecSab = (cfg.aec2 === true && sabOk)
    ? new SharedArrayBuffer(64 + 512 * 128 * 4) : null;
  // The far-end ring's slot epoch, in the header beside `hi` (pcm-worklet.js
  // §5.2). -1 so the first quantum a playout worklet touches is unambiguously a
  // claim rather than a match against a zeroed header. The ring itself is
  // unmoved and unresized, so its bytes are what they always were.
  if (aecSab) Atomics.store(new Int32Array(aecSab, 4, 1), 0, -1);
  const capHi = capSab ? new Int32Array(capSab, 0, 1) : null;
  const capTsRing = capSab ? new Float64Array(capSab, 64, CAP_RING_F) : null;
  const capRingU8 = capSab ? new Uint8Array(capSab, 320, CAP_RING_F * FRAME_BYTES) : null;
  let capRd = 0;
  let capPumpT = null;
  function drainCap() {
    if (!capRingU8 || closed) return;
    let hi = Atomics.load(capHi, 0);
    if (hi - capRd > CAP_RING_F) {
      // Main thread stalled past the whole ring: those frames are gone. Land
      // on the oldest survivor and say so — a silent skip here would read as
      // wire loss and send FEC chasing a local scheduling problem.
      capStats.capSabOverruns += hi - CAP_RING_F - capRd;
      capRd = hi - CAP_RING_F;
    }
    while (capRd < hi) {
      const slot = capRd % CAP_RING_F;
      const buf = capRingU8.slice(slot * FRAME_BYTES, (slot + 1) * FRAME_BYTES).buffer;
      onCaptureFrame(capRd, buf, capTsRing[slot]);
      capRd++;
      if (capRd === hi) hi = Atomics.load(capHi, 0); // frames landed while draining
    }
  }

  // ── What the capture half counts, and how every peer's snapshot sees it ────
  // captureFrames, the compressor's counters and the bit-depth probe describe
  // the MIC, not a peer, so they are counted ONCE here and folded into every
  // half's `stats` — which still lets a per-peer snapshot report the call's real
  // capture chain rather than a per-peer fraction of it.
  //
  // FOLDED AT READ TIME, NEVER PER FRAME. The first cut of this mirrored on
  // every capture frame, which put two Object.assign calls — ~20 property
  // writes into a 70-field object, 2,500 a second — BETWEEN the capture drain
  // and `dc.send()`, on the one path this lane's whole §17 effort is about. A
  // drain loop can carry 32 frames, so that landed as added departure latency
  // exactly when a burst was being drained, which is the moment the peer's
  // arrival-spread estimator is most sensitive to. Nothing reads these fields
  // between snapshots, so the fold belongs where the read is: `syncCapStats()`
  // at the top of the half's snapshot(), 0.5 times a second instead of 250.
  // Object.assign only writes keys the stats literal already declares, so the
  // snapshot's field order and every derived expression below are untouched.
  const halves = [];
  // Test-only slow sender clock (?pcmslowclock=0.43) — see onCaptureFrame.
  const SLOW_CLOCK = +cfg.slowClock > 0 && +cfg.slowClock < 1 ? +cfg.slowClock : 0;
  let slowLastTx = -1;
  const capStats = {
    captureFrames: 0,
    zipFrames: 0, shiftSum: 0, shift8: 0,
    probeTick: 0, probeFrames: 0, fit32767: 0, fit32768: 0,
    // The main thread stalling past the CAPTURE ring is a local scheduling
    // fault, one per page — never a peer's.
    capSabOverruns: 0,
    aec2: null,
  };

  /**
   * One peer's receive half, plus the send state that is genuinely per peer:
   * associations, anchors, parity, code rate. Each peer runs its OWN ladder
   * because each peer reports its own loss — that is `onPeerLoss`'s whole
   * design, and collapsing it to a shared rate would make the good path pay the
   * bad path's parity.
   */
  function createPeerHalf({ azimuthDeg = 0 } = {}) {
    const stats = {
      // send
      captureFrames: 0, framesSent: 0, bytesSent: 0, paritySent: 0, parityBytes: 0,
      skipBuffered: 0,
      // Frames too large for an RS symbol (the codec's verbatim escape), so left
      // out of their group. Expected to be 0 on speech; a nonzero rate here means
      // the input is noise-like and part of the lane is unprotected.
      rsOversize: 0,
      // Effective capture bit depth, measured per frame by the codec rather than
      // negotiated or assumed. See the packFrame call site.
      zipFrames: 0, shiftSum: 0, shift8: 0,
      probeTick: 0, probeFrames: 0, fit32767: 0, fit32768: 0,
      // The same, for the PEER's chain, off the decoded receive path.
      rxProbeTick: 0, rxProbeFrames: 0, rxShiftSum: 0, rxShift8: 0, rxFit32767: 0,
      // recv
      framesRecv: 0, bytesRecv: 0, parityRecv: 0, dup: 0, late: 0, farFuture: 0,
      // How many times the pre-playout ring re-anchored on a newer frame (ringWrite).
      // Nonzero means the audio graph took longer than ~512 ms to come up; before the
      // re-seed existed, that condition silently cost the WHOLE CALL's audio while every
      // transport counter read perfect. Both this and `farFuture` are published, because
      // `farFuture` counted every dropped frame of that outage and was never exposed.
      ringReseeds: 0,
      // Post-start re-anchors: the playhead outran the stream (a starved sender's
      // seq clock runs slower than wall time, or the sender restarted its seq)
      // and the ring was re-seeded on the live stream instead of concealing
      // forever. Distinct from ringReseeds, which can only happen pre-playout.
      reAnchors: 0,
      portDropped: 0,
      fecRepaired: 0, fecRepairedLate: 0, fecFailed: 0, parityUnused: 0,
      // Adaptive code rate. lossPct is what WE measure on the inbound stream;
      // peerLossPct is what the far end reports about ours, and it is the one the
      // ladder acts on. They differ whenever the path is asymmetric.
      lossPct: null, peerLossPct: null, fecNUp: 0, fecNDown: 0, latePctEma: 0,
      // The fast (512 ms) read of the same two streams. It drives raises only,
      // so it is expected to be noisier than its slow counterpart, not equal.
      lossFastPct: null, peerLossFastPct: null,
      // Repairs by POSITION in the group, split by whether they beat the playhead.
      // The whole question of whether the RS span is too long is answered by the
      // SHAPE of these two, which an aggregate fecRepaired/fecRepairedLate pair
      // cannot show: the same totals arise from "buffer slightly too shallow
      // everywhere" and from "the first half of every group is unreachable".
      fecOkPos: new Array(RS_K).fill(0), fecLatePos: new Array(RS_K).fill(0),
      fecLateMsSum: 0, fecLateMsMax: 0,
      // A contributing data frame longer than the group's symbol — impossible by
      // construction, so this counts disagreements about the group, not losses.
      fecSymMismatch: 0,
      // Jitter estimator internals; see the decayTimer.
      jitSpreadMs: null, jitP99Ms: null, jitP90Ms: null, jitMaxMs: null, jitWant: null, jitN: 0,
      capSabOverruns: 0,
      jitSpreadMaxRun: 0, jitAboveFloorMs: 0, jitWantMaxRun: 0, jitClampedTicks: 0, jitHoldMaxRun: 0,
      // Arrivals turned away as unplayable-at-any-depth, and which lane they
      // came from. Cumulative counters, not gauges — a fault that is over by
      // snapshot time still has to be visible in the snapshot.
      jitFarSkipped: 0, jitFarRelearn: 0, jitFarByLane: [0, 0, 0, 0, 0, 0],
      m2eRefused: 0, // impossible mouth-to-ear readings the instrument refused to publish
      // WHEN the run-max spread happened, and the same max ignoring the first
      // JIT_WARM ms. OBSERVABILITY ONLY — the control law does not read these.
      // A single 314 ms spread pins the target at its 15-frame ceiling and, at the
      // measured 1 ms/s release, holds it there for over three minutes: whether a
      // call runs at a 16 ms or a 120 ms buffer can therefore be decided by one
      // instant. `jitSpreadMaxRun` alone cannot distinguish "the link is genuinely
      // this bursty" from "connection setup was", which are opposite diagnoses with
      // opposite fixes. These two fields separate them without touching behaviour.
      jitSpreadMaxAtMs: null, jitSpreadMaxLate: 0, jitSpreadMaxLateAtMs: null,
      // Inter-arrival gap shape. `gapClump` counts arrivals under 1 ms after the
      // previous one — batching, not a network property. Nominal gap is FRAME_MS/PAIRS
      // striped, so a clean lane sits well under 8 ms with a narrow spread.
      gapClump: 0, gapN: 0, gapMaxRun: 0,
      // STALL EVENTS with wall-clock timestamps. The cross-engine penalty is isolated
      // 75-87 ms holes, and the next question is decisive about where to look: do both
      // ends stall at the SAME instant (a shared cause — the host, or the transport
      // both directions ride) or independently (each sender's own path)? Magnitude
      // alone cannot answer that; timestamps can. `now()` is
      // performance.timeOrigin + performance.now(), a wall-clock epoch, so the two
      // browsers' stamps are directly comparable on one machine.
      stalls: [],
      // timing
      rttMs: null, baseRttMs: null, clockOffsetMs: null, lastPongT: 0, ageMs: [],
      t0: null,
      // Jitter-target control. painEvents counts every conceal that asked for a
      // bigger buffer; bumps counts the ones that got it (a call at the ceiling
      // returns early and does NOT refresh lastPain, so the two diverge exactly
      // when the target is pinned at max). decays counts the giving-back.
      painEvents: 0, bumps: 0, decays: 0,
      // Latency governor (task #47). govTrim/govFloor are the last tick's values;
      // govTrimTicks is lever authority (how often the trim actually bound).
      govTrim: 0, govFloor: null, govPops: 0, govTrimTicks: 0, govTrimMaxRun: 0,
      elMax: 0, elMaxRun: 0, elUps: 0, // elastic ceiling: current, run peak, raises
      // Lane 0 (§3.1 levers 3+4) — all zero with cfg.lane0 off.
      predSent: 0, predRecv: 0, predDup: 0,
      padBytesSent: 0, padMsgsSent: 0, padBytesRecv: 0, padMsgsRecv: 0,
      aec2: null,
      dupOn: 0, dupSent: 0, dupBytes: 0, dupRecv: 0, dupSkipped: 0,
    };
    // Filled by the playout worklet's 1 Hz port tick.
    const wl = {
      mode: null, started: false, playedFrames: 0, concealedFrames: 0, heldFrames: 0,
      lateFrames: 0, overflowSkips: 0, driftPpm: 0, depthMs: null, targetFrames: cfg.targetFrames,
    };

    // ── Associations (the §17.12 stripe) ──────────────────────────────────────
    // cwnd is per SCTP association, so everything congestion-flavoured is kept
    // SEPARATE per association: its own ping/pong, its own baseRtt (the gate
    // budgets against it), its own bufferedAmount, its own counters. The top
    // level of `stats` stays the summed/aggregate view — at pairs=1 there is
    // exactly one association and the two views coincide.
    const PAIRS = Math.max(1, cfg.pairs || 1);
    const newAssoc = () => ({
      dc: null,
      framesSent: 0, bytesSent: 0, paritySent: 0, parityBytes: 0, skipBuffered: 0,
      framesRecv: 0, bytesRecv: 0, parityRecv: 0,
      rttMs: null, baseRttMs: null, clockOffsetMs: null, lastPongT: 0,
      padBytesSent: 0, padBytesRecv: 0, // Lane 0: pre-warm padding per association
    });
    const assocs = Array.from({ length: PAIRS }, newAssoc);

    // ── Per-lane arrival DE-SKEW (latency-geo.md §4.3 fix 2) ──────────────────
    // Audio frames stripe over `PAIRS` SCTP associations (six independent ECMP
    // paths). On long/intercontinental routes, lanes have STRUCTURALLY different
    // base delays (10–25 ms apart). The arrival-spread estimator (noteArrival →
    // dRing) feeds ALL lanes into one window, reading constant lane offset as
    // jitter and charging 16–32 ms of playout buffer for nothing.
    //
    // SAFETY INVARIANT: On a path where all lanes share one route (same-machine,
    // same-city), laneBase values converge within noise, skew ≈ 0, and behavior
    // is bit-identical to today. The change is a strict no-op absent real divergence.
    const laneBase = new Float64Array(PAIRS).fill(Infinity);
    const laneSamples = new Uint32Array(PAIRS);
    const laneLastT = new Float64Array(PAIRS);
    const lastFrameT = new Float64Array(PAIRS);
    let laneEpoch = 0;

    // ── The third lane-health signal: frames that arrive too late to play ──────
    //
    // Skew and liveness together have a hole big enough to drive the whole stall
    // failure through, and it is not a threshold that wants nudging.
    //
    // Liveness asks "did a pong come back". A route delayed by five seconds is
    // not a blackhole — the pongs DO come back, five seconds later — so `dead`
    // stays 0 and the lane reads healthy.
    //
    // Skew asks "how far behind the fastest lane did this lane's frames land",
    // measured as each lane's running MINIMUM delay, deliberately re-learned
    // after a 2 s silence so a resuming lane cannot poison the reference. Both
    // of those are right on their own terms and both are blind here: the lane
    // re-learns the five-second delay as its own new normal and then reports
    // being perfectly on time relative to it. Measured on the stall rig: peer
    // skew 0.5-1 ms on lanes whose frames were arriving far too late to use.
    //
    // So a lane useless enough to quadruple concealment was invisible to BOTH
    // detectors simultaneously, and the sender kept feeding it. This is the
    // signal that cannot be fooled that way, because it is not relative to
    // anything the lane itself controls: a frame is late when the playhead has
    // already passed it. `ringWrite` has always known that (`seq < lo`) and has
    // always thrown away WHICH LANE it came from. It stops throwing that away.
    //
    // Decayed rather than cumulative, so a lane is judged on the last ~10 s and
    // can be forgiven when its route heals.
    const laneLate = new Float64Array(PAIRS);
    const laneOnTime = new Float64Array(PAIRS);
    const LATE_DECAY = 0.975; // per 250 ms report tick — ~10 s of memory
    const laneLatePct = (k) => {
      const n = laneLate[k] + laneOnTime[k];
      // Under 20 frames of evidence (160 ms of audio) a lane has not said
      // enough to be condemned. Reported as 0 = healthy, never as "unknown",
      // for the same reason liveness reports a never-heard-from lane as live:
      // absence of evidence must not cause a demotion.
      return n < 20 ? 0 : Math.round((100 * laneLate[k]) / n);
    };

    // Sender-side mirror of the peer's measured arrival skew (lane-skew Stage 1).
    // Advisory telemetry sent on T_SKEW every 250 ms so the sender can see what
    // the receiver is measuring without making routing changes yet.
    const peerSkewMs = new Float64Array(PAIRS);
    let peerSkewWarm = 0;
    let peerLiveMask = 0xff;
    let peerSkewAt = 0;
    // What the peer says about OUR sending: percent of the frames we put down
    // each lane that reached it too late to play. Zero on a peer too old to
    // report it, which is the value that can never cause a demotion.
    const peerLatePct = new Uint8Array(PAIRS);

    // Skew-aware striping (lane-skew Stage 2, opt-in ?pcmskewstripe=1).
    // Sender demotes slow lanes based on receiver skew feedback (spec §2.1).
    const fastOrder = new Int8Array(PAIRS);
    for (let k = 0; k < PAIRS; k++) fastOrder[k] = k;
    let nFast = PAIRS;
    const laneState = new Uint8Array(PAIRS); // 0 = FAST, 1 = DEMOTED
    const laneStateSince = new Float64Array(PAIRS);
    // Consecutive recompute ticks a DEMOTED lane's round trip has matched the
    // working lanes. Reset by any tick that does not — see recomputeLaneOrder.
    const laneRttOkStreak = new Uint16Array(PAIRS);
    // Consecutive recompute ticks a FAST lane has looked slow. The mirror of
    // laneRttOkStreak, and it exists for the same reason: one tick is a sample,
    // a streak is a route. See the demote rule in recomputeLaneOrder.
    const laneSkewHighStreak = new Uint16Array(PAIRS);
    // The same, for the peer's late-fraction report. Separate counter because it
    // is a separate claim: skew says "this lane is behind the others", lateness
    // says "this lane's frames were unusable when they got here", and a route
    // can do the second without ever doing the first.
    const laneLateHighStreak = new Uint16Array(PAIRS);
    // Was this lane demoted for LATENESS rather than for skew? It decides which
    // evidence is allowed to promote it back, and without it the new rule was
    // self-defeating: warmth persists for 2 s after a lane stops carrying audio,
    // and during that window a uniformly-delayed lane still reports the ~1 ms of
    // skew that made it invisible in the first place — so the skew clause
    // promoted it straight back. Measured as the churn it is: 18 demotions and
    // 15 promotions on one side of a 60 s stall run.
    //
    // A lane condemned by the signal that skew cannot see must not be released
    // by skew. Only the RTT probe can, because the ping reaches demoted lanes
    // and so is the one piece of evidence that does not depend on the traffic we
    // just took away.
    const laneLateDemoted = new Uint8Array(PAIRS);
    // Percent of frames arriving too late to play that condemns a lane.
    //
    // Set from the measurement, not from taste. On the stall rig at the moment
    // of sampling, healthy lanes read 0-3% and the stalled routes read 16-17%
    // — not the ~100% the injected 5 s delay suggests, because a lane that gets
    // demoted stops carrying audio, its reading decays toward zero, and the
    // number is therefore a time-average over demote/probe-promote cycles
    // rather than an instantaneous verdict. The first version of this used 25
    // and sat ABOVE both populations, so it almost never fired: a threshold has
    // to be placed against what the signal actually reads, not against what the
    // fault theoretically produces.
    //
    // 10 leaves 3x headroom over the worst healthy reading and 1.6x margin
    // below the worst bad one.
    const LATE_DEMOTE_PCT = 10;
    // Decaying-min round trip per lane, kept alive by the ping on every open
    // association. Reset to Infinity whenever a lane changes state so each
    // epoch is judged on its own evidence.
    const laneRttBase = new Float64Array(PAIRS).fill(Infinity);
    const laneDead = new Uint8Array(PAIRS);
    // ONE definition, used by both the ping timer and the silence threshold that
    // reads it. Written apart, they drift: the threshold started at a flat
    // 2000 ms, which is exactly one ping period, so a lane sat "silent" for the
    // instant before every ping and a recompute tick landing in that window
    // condemned whichever lanes it caught. Measured on a clean same-route call
    // with no stall and 1 ms of skew: 3 lanes demoted out of nowhere. Declared
    // here, above every use, rather than beside the timer it feeds.
    // A LIVE KNOB, and it should have been one when the value moved. Dropping
    // this 2000 -> 400 put 5x the message rate on the same associations the
    // audio rides, and it shipped with no way to A/B it — so when the clean
    // path drifted 43.6 -> 47.6 ms of mouth-to-ear (ring 13.5 -> 17.5) the same
    // day, the prime suspect was the one change that could not be tested. The
    // far-arrival bound WAS testable and was cleared in minutes by its control
    // arm; this one had to be argued about. Every knob that touches the audio
    // path gets a control arm, including the ones that look too small to matter.
    const PING_MS = Math.max(50, cfg.pingMs ?? 400);
    /**
     * How long silence has to last before it means death — in MILLISECONDS,
     * and relative to the lane's own round trip.
     *
     * It used to be `PING_MS * 2.5`, which tied the verdict to the cadence. So
     * when the ping period was raised to 2000 the deadline silently moved to
     * 5 s, and the rule below still says "a lane whose pong has not come back
     * for 2 s is not slow, it is gone" — the comment describing an intent the
     * arithmetic stopped implementing. A constant expressed in units of another
     * constant is a constant that changes when nobody is looking at it.
     *
     * Three ping periods, so losing two probes back to back is survivable: one
     * dropped pong must never condemn a healthy lane, and DEAD skips the dwell,
     * the hysteresis and the MIN_FAST floor, so a false positive here is the
     * expensive kind. Plus three of THIS LANE's own round trips, because a flat
     * allowance is a hidden distance limit — the bug class already found three
     * times in this repo, invisible every time on a short path. At 5 ms of RTT
     * that is 1.35 s; at the 150 ms of a Delhi-Amsterdam leg it stretches to
     * 1.65 s on its own, rather than eating a fixed budget for being far away.
     */
    const FAST_DEAD = cfg.fastDead !== false;
    const muteAfterMs = (a) => (FAST_DEAD
      ? 3 * PING_MS + 3 * Math.max(a?.baseRttMs ?? 0, 50)
      // The control arm restores the old DEADLINE only — both arms ping at the
      // new cadence, which isolates the thing under test. The faster ping is
      // not part of the experiment: it costs 135 B/s across six lanes and
      // strictly sharpens laneRttBase, which is a running minimum.
      : 5000);
    let lastOrderRecompute = 0;
    let stripeDemotions = 0;
    let stripePromotions = 0;
    let stripeStaleFailopen = 0;
    let stripeProbePromotions = 0;
    // RISING EDGES, not the instantaneous `dead` gauge beside it. The gauge
    // reads laneDead at snapshot time, and laneDead is recomputed from scratch
    // every tick — so a blackhole correctly caught at t+2 s reads 0 by t+25 s
    // and the snapshot says the rule never fired. That is a birth certificate
    // being read as a health record, and it made the first A/B of muteAfterMs
    // unattributable: the scenario passed and the evidence for WHY was gone.
    let stripeDeadEvents = 0;
    const deadCause = { mute: 0, peer: 0, hopeless: 0 };
    let stripeDeadFirstMs = null;   // ms from first ping to the first death seen
    const laneDeadPrev = new Uint8Array(PAIRS);
    let deadGraceUntil = 0;
    let isStaleFailopen = false;

    /**
     * Skew-aware striping recompute (spec §2.1, §2.2, §2.5).
     * Recomputes `fastOrder` and `nFast` from peerSkewMs/peerSkewWarm.
     * Dwell guard: at most once per 1000 ms, and 5 s dwell per lane state change.
     * Demote when warm & skew >= 8 ms; re-promote when warm & skew <= 4 ms.
     * MIN_FAST = 3 (keep fastest demoted lanes in fast set if demotions exceed capacity).
     * Fail-open: if peerSkewAt is > 2000 ms old (or 0), restore all lanes to fast.
     */
    function recomputeLaneOrder(tn = now()) {
      if (!SKEWSTRIPE) return;
      // OUR OWN PUNCTUALITY, FIRST. Every "this lane is dead" signal below is
      // really "we have not processed anything from it lately", and a frozen
      // main thread produces that for ALL SIX AT ONCE while the network is
      // perfectly fine. Measured on a same-route call with peer-reported skew of
      // 1 ms on every lane: 6 demotions and 6 promotions, +20 ms of ring and
      // ~1 s of concealment, entirely manufactured by this machine's own 1-2 s
      // stalls. netsim learned the same lesson and reports its own lateness for
      // exactly this reason: a ruler that cannot say "I was jostled" will report
      // the jostling as a measurement.
      const tickGap = lastOrderRecompute ? tn - lastOrderRecompute : 1000;
      if (tickGap > 1500) deadGraceUntil = tn + 2000;
      if (tn - lastOrderRecompute < 1000) return;
      lastOrderRecompute = tn;

      const isStale = peerSkewAt === 0 || (tn - peerSkewAt > 2000);
      if (isStale) {
        if (!isStaleFailopen && nFast < PAIRS) {
          stripeStaleFailopen++;
        }
        isStaleFailopen = true;
        for (let k = 0; k < PAIRS; k++) {
          if (laneState[k] === 1) { // 1 = DEMOTED
            laneState[k] = 0; // FAST
            laneStateSince[k] = tn;
            stripePromotions++;
          }
          fastOrder[k] = k;
        }
        nFast = PAIRS;
        return;
      }
      isStaleFailopen = false;

      // A FLOOR per lane, not the latest sample. Instantaneous rttMs swings tens
      // of milliseconds under a heavy tail, so comparing samples promoted lanes
      // that were genuinely slow and let skew re-demote them a second later:
      // measured 11 demotions and 10 promotions in one 100 s run, nFast cycling
      // 3-4-5-3. A decaying minimum over the lane's own pings is stable enough
      // to compare, and it is reset on every state change (below) so a lane
      // cannot be resurrected by how fast it used to be.
      for (let k = 0; k < PAIRS; k++) {
        const r = assocs[k]?.rttMs;
        if (r != null && r < laneRttBase[k]) laneRttBase[k] = r;
      }
      let minFastRtt = Infinity;
      for (let k = 0; k < PAIRS; k++) {
        if (laneState[k] === 0 && laneRttBase[k] < minFastRtt) minFastRtt = laneRttBase[k];
      }

      // UNUSABLE, which is not the same as slow. Two ways a lane can carry no
      // audio while looking healthy to every other check:
      //
      //   · the pong stops entirely — a true blackhole;
      //   · the pong still comes back, but hundreds of milliseconds late. Then
      //     every AUDIO frame on that lane misses the playout deadline and is
      //     discarded on arrival, so the receiver logs no samples for it and its
      //     SKEW FREEZES at whatever it was when the route was fine. The lane is
      //     dead to audio and alive to the ping, and skew will never say so.
      //
      // The second is what the stall rig actually injects (+5 s of route delay,
      // not a close), and it is why the first version of this check never fired.
      // The bound is RELATIVE to the working lanes, so a genuinely long path —
      // where every lane sits at 250 ms — reads as healthy; only a lane 300 ms
      // worse than its own peers, far beyond any jitter and beyond the ring's
      // deepest setting, counts as hopeless.
      // THE FRESHEST PONG ON ANY LANE, which is what turns the silence test
      // below from an absolute one into a relative one. An absolute deadline
      // cannot tell a dead route from OUR OWN main thread stalling: a renderer
      // that freezes for 1.5 s stops answering on all six lanes at once, and
      // every one of them then reads as blackholed. Measured, on the very first
      // A/B of the shortened deadline: 3 dead events on side A and 1 on side B
      // BEFORE the fault was injected, on lanes that were entirely healthy, and
      // 1696 ms of pre-stall concealment against the control's 1032 — a change
      // that helped during the stall and made the ordinary call worse, which is
      // the trade this file has refused three times already.
      //
      // Relative, it is immune: a local freeze moves every lane's lastPongT
      // together, so the DIFFERENCE stays near zero and nothing is condemned.
      // A genuine blackhole leaves its siblings answering every 400 ms, so the
      // difference is exactly the silence. (When every lane really is gone the
      // difference is zero and nothing is marked — which is correct, and is the
      // same verdict the global-outage guard below reaches by its own route.)
      let newestPong = 0;
      for (let k = 0; k < PAIRS; k++) {
        const a = assocs[k];
        if (a?.dc?.readyState === 'open' && (a.lastPongT ?? 0) > newestPong) newestPong = a.lastPongT;
      }
      for (let k = 0; k < PAIRS; k++) {
        const a = assocs[k];
        const open = a?.dc?.readyState === 'open';
        const lp = a?.lastPongT ?? 0;
        // The fast, one-way signal: the peer stopped receiving on a lane we are
        // actively sending. Only meaningful for lanes we SEND on — a demoted
        // lane is silent by design, and reading that as death would re-create
        // the permanent-demotion trap the RTT probe exists to escape.
        // The 2 s grace is load-bearing, not caution. A just-promoted lane has
        // by definition delivered nothing yet, so the peer still reports it as
        // not-live for up to a second, plus the report interval and transit.
        // Without the grace that reads as death, the RTT probe revives it, and
        // the two signals drive each other: measured on a SAME-ROUTE call,
        // 6 demotions and 6 promotions in 45 s, frames 1016/832 across lanes,
        // +26 ms of mouth-to-ear and 1224 ms of concealment against a control
        // with zero. The feature was about to make every ordinary call worse.
        const peerSaysGone = laneState[k] === 0
          && (tn - laneStateSince[k]) > 2000
          && (peerLiveMask & (1 << k)) === 0
          && peerSkewAt > 0 && (tn - peerSkewAt) < 2000;
        // See muteAfterMs. Was 2.5 ping periods = 5 s, which is not "notice a
        // silent route" — it is five seconds of speech posted into a hole while
        // every other signal waits for this one.
        const mute = open && lp > 0
          && (tn - lp) > muteAfterMs(a)             // silent for longer than it should ever be
          && (newestPong - lp) > muteAfterMs(a);    // AND silent while its siblings are answering
        const hopeless = open && a?.rttMs != null && minFastRtt !== Infinity
          && (a.rttMs - minFastRtt) > 300;
        // Nothing is declared dead while we are still recovering from a local
        // freeze: the evidence for death and the evidence of our own stall are
        // the same observation.
        laneDead[k] = (tn >= deadGraceUntil && (peerSaysGone || mute || hopeless)) ? 1 : 0;
        if (laneDead[k] && !laneDeadPrev[k]) {
          stripeDeadEvents++;
          if (mute) deadCause.mute++;
          else if (peerSaysGone) deadCause.peer++;
          else if (hopeless) deadCause.hopeless++;
          if (stripeDeadFirstMs == null) stripeDeadFirstMs = +tn.toFixed(0);
        }
        laneDeadPrev[k] = laneDead[k];
      }

      // GLOBAL OUTAGE IS NOT A ROUTE PROBLEM. The peer freezing sends neither
      // pongs nor frames, which from this side is indistinguishable from the
      // network dying — by signal. Not by SCOPE: a frozen peer silences all six
      // lanes at once, while a real route failure takes a subset. Measured on a
      // same-route call where the FAR side stalled: every lane read dead, all
      // six were demoted, and since a dead lane is never rescued by MIN_FAST the
      // stripe collapsed and churned (11 demotions, 8 promotions, 1240 ms of
      // concealment) — all of it reshuffling that could not have helped, because
      // there was no healthy lane to move to. The local-stall grace above cannot
      // catch this: our own clock was perfectly punctual throughout.
      let deadCount = 0;
      for (let k = 0; k < PAIRS; k++) deadCount += laneDead[k];
      if (deadCount >= PAIRS - 1) {
        for (let k = 0; k < PAIRS; k++) laneDead[k] = 0;
      }

      // Evaluate desired states with 5 s dwell and hysteresis (spec §2.1)
      const desiredState = new Uint8Array(PAIRS);
      for (let k = 0; k < PAIRS; k++) {
        desiredState[k] = laneState[k];
        const isWarm = (peerSkewWarm & (1 << k)) !== 0;
        const skew = peerSkewMs[k];
        const dwellOk = (tn - laneStateSince[k]) >= 5000;

        // DEAD trumps everything, dwell included: a lane whose pong has not
        // come back for 2 s is not slow, it is gone, and waiting out a dwell
        // means 2 more seconds of audio posted into it. No dwell, no hysteresis,
        // no MIN_FAST protection (see below) — the floor exists to keep capacity,
        // and a floor made of dead lanes has none.
        if (laneDead[k]) { desiredState[k] = 1; continue; }

        // LATENESS DOES NOT WAIT OUT THE DWELL EITHER, and for the same reason
        // DEAD does not: this is not "slow", it is "the audio we put here did
        // not arrive in time to be heard", and five seconds of dwell is five
        // more seconds of speech posted into it. It keeps MIN_FAST protection
        // (unlike DEAD) — a floor of merely-late lanes still carries audio, and
        // under a problem that hits every route at once the right answer is to
        // keep striping, not to collapse onto nothing.
        //
        // The streak is updated for FAST lanes only. A demoted lane sends
        // nothing, so the peer measures nothing on it and reports 0, which
        // resets the streak on its own — the signal cannot pin a lane down the
        // way a cumulative counter would.
        if (LATE_DEMOTE && laneState[k] === 0) {
          laneLateHighStreak[k] = (peerLatePct[k] >= LATE_DEMOTE_PCT) ? laneLateHighStreak[k] + 1 : 0;
          if (laneLateHighStreak[k] >= 2) { desiredState[k] = 1; laneLateDemoted[k] = 1; continue; }
        }

        if (dwellOk) {
          if (laneState[k] === 0) { // FAST
            // Skew has to HOLD, not just happen. laneBase is a running minimum
            // per lane and skew is measured against the smallest of them, so
            // early in a call the gap between two lanes is mostly a question of
            // which one has already sampled its own floor: a lane is warm at 50
            // samples (~2.4 s) but the dwell opens demotion at 5 s, and in that
            // window minima are still converging. The gap that opens there is
            // noise and it SHRINKS as samples accumulate — the opposite of a
            // real route difference, which holds or grows.
            //
            // Measured on a clean same-route call: 1 run in 3 demoted 3 lanes
            // to nothing but this, then probe-promoted all 3 back once the
            // epoch reset relearned the bases. Zero concealment, but ~8 ms of
            // buffer paid for a divergence that did not exist, on the ordinary
            // network that most calls run over.
            //
            // Three consecutive ticks (~3 s) is the same bar the promote side
            // already uses, and it costs a genuinely slow lane ~3 s of extra
            // patience inside a window whose settle budget is 10 s.
            laneSkewHighStreak[k] = (isWarm && skew >= 8.0) ? laneSkewHighStreak[k] + 1 : 0;
            if (laneSkewHighStreak[k] >= 3) desiredState[k] = 1; // DEMOTED

            // THE THIRD SIGNAL. Not gated on `isWarm`, and that is the whole
            // point: warmth is a property of the SKEW estimator (50 samples and
            // still delivering), and the case this exists for is a lane that is
            // warm, live, and reporting ~1 ms of skew while every frame it
            // carries lands after the playhead has gone past. Its own guard is
            // the 20-frame floor inside laneLatePct, which reports "not enough
            // evidence" as 0 rather than as a verdict.
            //
            // Two ticks, not three. A skew gap early in a call is genuinely
            // ambiguous — minima are still converging and the gap shrinks as
            // they do — so that rule buys patience. A frame that arrived after
            // its own deadline is not ambiguous and does not get better with
            // more samples; it is already lost audio, and every extra tick of
            // patience is another 250 ms of audio posted into a lane that
            // cannot deliver it.
            //
            // (The rule itself is applied above the dwell — see the block after
            // the DEAD check. Only the comment lives here, beside the skew rule
            // it should be read against.)
          } else { // DEMOTED
            // A demoted lane carries no audio (measured: exactly 0 frames after
            // demotion), so its SKEW can never fall — the evidence needed to
            // promote it only travels on the lane we stopped using. Left there,
            // demotion is permanent, and a route that recovers is never
            // forgiven: the flap rig measured promotions=0 and nFast stuck at 3
            // for the rest of a call after the route was restored.
            //
            // The ping is the way out. It goes to EVERY open association,
            // demoted included, so rttMs keeps arriving for lanes that carry
            // nothing. Require the round trip to sit within a frame and a half
            // of the fastest working lane for 3 consecutive ticks (~3 s) before
            // promoting: one sample is jitter, a streak is a route. If the lane
            // is in fact still slow, it warms up and skew re-demotes it after
            // the dwell — a bounded, self-correcting probe rather than a
            // permanent verdict.
            //
            // Cadence, which this comment twice had wrong. The streak counts
            // RECOMPUTE TICKS (rate-limited to 1/s), not pings, so its length
            // in seconds does not move with PING_MS — what moves is how much
            // independent evidence each tick carries. At the old 2000 ms period
            // RTT refreshed every 2 s, so three ticks spanned roughly ONE AND A
            // HALF fresh round trips and the streak bought less than it looked
            // like it did. At 400 ms each tick sees a sample of its own and
            // "one sample is jitter, a streak is a route" is finally true.
            // Promotion timing is unchanged: still ~3 s, still the safe
            // direction to be slow about.
            // 8 ms of round trip is the 4 ms one-way promote hysteresis seen
            // from the sender's side, so the probe and the skew rule agree on
            // where "fast again" begins.
            const rttOk = laneRttBase[k] < Infinity && minFastRtt !== Infinity
              && (laneRttBase[k] - minFastRtt) <= 8;
            laneRttOkStreak[k] = rttOk ? laneRttOkStreak[k] + 1 : 0;
            // Positive evidence only. `!isWarm` used to count as "fine again",
            // but a demoted lane is silent and therefore never warm — so that
            // clause promoted every demoted lane on every dwell expiry, which is
            // the other half of the same-route cycling. Either the peer measures
            // it fast, or the ping says the route came back.
            // `!laneLateDemoted[k]` on the skew clause: a lane taken out for
            // lateness is exactly a lane whose skew reads fine, so letting skew
            // release it is letting the blind signal overrule the one that saw.
            // The probe still frees it the moment the route genuinely recovers,
            // so this is a narrower door, not a locked one.
            if ((!laneLateDemoted[k] && isWarm && skew <= 4.0) || laneRttOkStreak[k] >= 3) {
              desiredState[k] = 0; // FAST
            }
          }
        }
      }

      // Count desired fast lanes and enforce MIN_FAST = 3 (spec §2.1)
      let fastCount = 0;
      for (let k = 0; k < PAIRS; k++) {
        if (desiredState[k] === 0) fastCount++;
      }

      const MIN_FAST = 3;
      if (fastCount < MIN_FAST) {
        // Find demoted candidates and sort by skew ascending (keep fastest in fast set)
        const demotedCandidates = [];
        for (let k = 0; k < PAIRS; k++) {
          // Never rescue a dead lane to satisfy the floor: it would restore the
          // COUNT while restoring none of the capacity the count stands for, and
          // audio would be posted straight back into the blackhole. If that
          // leaves fewer than MIN_FAST lanes, fewer is the truth — fall-forward
          // still reaches every open association as the last resort.
          if (desiredState[k] === 1 && !laneDead[k]) {
            demotedCandidates.push({
              k, skew: peerSkewMs[k], late: peerLatePct[k],
              // WHY it was demoted, not what it currently reports. See below.
              wasLate: laneLateDemoted[k] ? 1 : 0,
            });
          }
        }
        // Ranked by WHY THE LANE WAS DEMOTED first, then by what it currently
        // reports.
        //
        // Ranking on the current reading alone looks right and is the same trap
        // this sort was already rewritten once to escape, one level deeper. A
        // demoted lane carries no audio, so the peer measures no frames on it,
        // so peerLatePct decays to ZERO within seconds — the lane's own
        // condemnation erases the evidence for it. A route stalled by five
        // seconds therefore sorts to the FRONT of the rescue list, tied at
        // late 0 with lanes that are merely slow, and the floor drafts back
        // precisely the lane it just proved cannot deliver.
        //
        // Measured on the 3-of-6-stalled scenario (testbed/skewstripe-stall.mjs,
        // --on='&pcmskewstripe=1&pcmlatedemote=1'): the sending side logged 8
        // demotions against 5 promotions in one 25 s window and settled only at
        // the end, while the RECEIVING side concealed 1624 ms against the
        // control's 448. Every one of those promotions posted speech back into a
        // five-second hole.
        //
        // laneLateDemoted already records the verdict and is already trusted to
        // block the skew release path, for exactly this reason: a lane condemned
        // by the signal skew cannot see must not be released by skew. The floor
        // needs the same rule. It is cleared the moment the lane is genuinely
        // promoted, so this is an ordering preference, not a life sentence — and
        // the RTT probe, which reaches demoted lanes and does not depend on the
        // traffic we took away, remains the way back.
        demotedCandidates.sort((a, b) => a.wasLate - b.wasLate || a.late - b.late
          || a.skew - b.skew || a.k - b.k);
        const needed = MIN_FAST - fastCount;
        for (let i = 0; i < needed && i < demotedCandidates.length; i++) {
          desiredState[demotedCandidates[i].k] = 0; // force FAST
        }
      }

      // Apply state changes
      for (let k = 0; k < PAIRS; k++) {
        if (desiredState[k] !== laneState[k]) {
          if (desiredState[k] === 1) {
            stripeDemotions++;
          } else {
            stripePromotions++;
            // Distinguish "the peer says it is fine again" from "we probed it
            // back": only the latter is the escape from permanent demotion, and
            // if it turns out to oscillate, this is the counter that shows it.
            if (laneRttOkStreak[k] >= 3) stripeProbePromotions++;
          }
          laneState[k] = desiredState[k];
          laneStateSince[k] = tn;
          laneRttOkStreak[k] = 0;
          laneSkewHighStreak[k] = 0; // a new epoch re-earns its own evidence
          laneLateHighStreak[k] = 0;
          if (desiredState[k] === 0) laneLateDemoted[k] = 0; // promoted: verdict spent
          laneRttBase[k] = Infinity; // re-learn this epoch's floor from fresh pings
        }
      }

      // Rebuild fastOrder permutation (fast lanes first, demoted lanes after)
      let fIdx = 0;
      for (let k = 0; k < PAIRS; k++) {
        if (laneState[k] === 0) {
          fastOrder[fIdx++] = k;
        }
      }
      nFast = fIdx;
      for (let k = 0; k < PAIRS; k++) {
        if (laneState[k] === 1) {
          fastOrder[fIdx++] = k;
        }
      }
    }

    /**
     * Maps an ordinal/sequence number to a home POSITION IN `fastOrder`, not to
     * a lane index (spec §2.1, §2.5). The pickers walk fastOrder-space from
     * here, which is what makes fall-forward prefer the remaining FAST lanes
     * and reach demoted ones only as a last resort — walking lane-index space
     * instead would try lane 3 before lane 4 given fastOrder [0,2,4|1,3,5],
     * spilling audio onto a structurally-slow lane under the exact budget
     * pressure the stripe exists to absorb.
     *
     * `fastOrder` is a full permutation of all PAIRS lanes (fast first, then
     * demoted), and it is the identity whenever striping is off or no lane is
     * demoted — so `fastOrder[(lanePos(seq) + k) % PAIRS]` reduces to today's
     * `(seq % PAIRS + k) % PAIRS` exactly, by construction rather than by test.
     */
    function lanePos(ordinal, isTwin = false) {
      const N = (SKEWSTRIPE && nFast < PAIRS) ? nFast : PAIRS;
      const off = isTwin ? Math.max(1, N >> 1) : 0;
      return ((ordinal + off) % N + N) % N;
    }

    // Deduplicated arrival-skew estimator (lane-skew Stage 1a/1b).
    // Decaying minima drift upward at +1 ms/s so link recovery is detected.
    // Spec §2.2 fix: drift is FROZEN when a lane has received no frames in
    // 2 s (lastFrameT) so a quiet/demoted lane's base does not rot upward
    // and make demotion permanent by accident.
    function updateDrift(tn) {
      for (let k = 0; k < PAIRS; k++) {
        if (laneSamples[k] > 0 && laneLastT[k] > 0) {
          if (lastFrameT[k] > 0 && (tn - lastFrameT[k]) <= 2000) {
            laneBase[k] += (tn - laneLastT[k]) / 1000;
          }
          laneLastT[k] = tn;
        }
      }
    }

    // Warm = enough samples AND still delivering. The recency half is not a
    // refinement, it is a correctness fix: a demoted lane goes silent, its base
    // freezes (drift is frozen for quiet lanes on purpose), and within seconds
    // every ACTIVE lane has drifted +1 ms/s past it. The frozen lane then wins
    // min() and becomes the reference the others are judged against, so the
    // working lanes read as 10 ms+ slow and get demoted in turn — measured on a
    // same-route call as 12 demotions and 9 promotions in 45 s, with the ring
    // 24 ms deeper than control. A lane that is not delivering has no opinion.
    const laneWarmAt = (k, tn) => laneSamples[k] >= 50 && lastFrameT[k] > 0 && (tn - lastFrameT[k]) < 2000;

    function laneSkewNow(laneIdx, seq) {
      const tn = now();
      if (!laneEpoch) laneEpoch = tn - seq * FRAME_MS;
      const idx = (typeof laneIdx === 'number' && laneIdx >= 0 && laneIdx < PAIRS) ? laneIdx : 0;
      // A lane resuming after a silence must RE-LEARN, not carry its old base
      // across the gap. It already has its 50 samples banked, so without this it
      // re-enters the reference set the instant it delivers one frame, holding a
      // value that is stale by however much the two clocks drifted while it was
      // quiet (up to 2 ms/s) — and a reference that is wrong-LOW makes every
      // healthy lane read as slow. Same epoch-reset rule as laneRttBase.
      if (lastFrameT[idx] > 0 && (tn - lastFrameT[idx]) > 2000) {
        laneBase[idx] = Infinity;
        laneSamples[idx] = 0;
        laneLastT[idx] = 0;
      }
      lastFrameT[idx] = tn;
      updateDrift(tn);

      const d_i = tn - laneEpoch - seq * FRAME_MS;
      if (laneSamples[idx] === 0 || d_i < laneBase[idx]) {
        laneBase[idx] = d_i;
      }
      if (laneSamples[idx] === 0) laneLastT[idx] = tn; // seed drift origin
      laneSamples[idx]++;

      let numWarm = 0;
      let minWarmBase = Infinity;
      for (let k = 0; k < PAIRS; k++) {
        if (laneWarmAt(k, tn)) {
          numWarm++;
          if (laneBase[k] < minWarmBase) {
            minWarmBase = laneBase[k];
          }
        }
      }
      if (numWarm >= 2 && laneWarmAt(idx, tn)) {
        return Math.max(0, laneBase[idx] - minWarmBase);
      }
      return 0;
    }

    function laneSkewAll() {
      const tn = now();
      updateDrift(tn);

      let numWarm = 0;
      let minWarmBase = Infinity;
      let warmMask = 0;
      for (let k = 0; k < PAIRS; k++) {
        if (laneWarmAt(k, tn)) {
          numWarm++;
          warmMask |= (1 << k);
          if (laneBase[k] < minWarmBase) {
            minWarmBase = laneBase[k];
          }
        }
      }

      const perLane = [];
      let maxWarmSkew = 0;
      for (let k = 0; k < PAIRS; k++) {
        let sk = 0;
        if (numWarm >= 2 && laneWarmAt(k, tn)) {
          sk = Math.max(0, laneBase[k] - minWarmBase);
        }
        const skVal = +sk.toFixed(1);
        perLane.push(skVal);
        if (laneWarmAt(k, tn) && skVal > maxWarmSkew) {
          maxWarmSkew = skVal;
        }
      }
      return {
        perLane,
        max: +maxWarmSkew.toFixed(1),
        numWarm,
        warmMask,
      };
    }

    // Sender-side mirror of the anchor: the least-delayed frame of the current
    // window (see onCaptureFrame). anchBestK is that frame's `wall - seq*8`.
    let lastCapSeqTx = -1, lastCapUsTx = 0, lastCapWallTx = 0;
    let anchBestK = Infinity, anchSentAt = 0;
    // Receiver-side anchor, from T_ANCH. One per peer, not per association — it
    // describes the capture stream, which the stripe does not split.
    let anchSeq = -1, anchWall = 0, anchUs = 0;
    let playNode = null;
    let pinger = null;
    let lossTimer = null;
    // Lane 0 sender state (§3.1 lever 4). The pad pacer is a timer, not a
    // clump: 25 KB in one burst would trip exactly the wall it exists to
    // pre-warm. Padding bytes are counted SEPARATELY from bytesSent — they are
    // not media and must not inflate the lane's throughput counters.
    let predSeq = 0, lastPredSeq = -1;
    let padSeq = 0, padLeft = 0, padTimer = null, padRr = 0;

    // ── Shared ring (or the port fallback) ────────────────────────────────────
    // Layout (see pcm-worklet.js for the same map): 8×i32 ctl | 64×i32 tags |
    // 64×f64 capTs (sender-audio-clock µs per slot — the A-V sync anchor) |
    // 2×f64 playhead publish (seqlocked) | f32 ring.
    const sab = sabOk ? new SharedArrayBuffer(816 + RING_F * 384 * 4) : null;
    let ctl = null, tags = null, ring = null, capTs = null, pub = null;
    if (sab) {
      ctl = new Int32Array(sab, 0, 8);
      tags = new Int32Array(sab, 32, RING_F);
      capTs = new Float64Array(sab, 288, RING_F);
      pub = new Float64Array(sab, 800, 2);
      ring = new Float32Array(sab, 816, RING_F * 384);
      Atomics.store(ctl, SAB_START, -1);
      Atomics.store(ctl, SAB_HI, 0);
      // -1, NOT 0. At 0 this field cannot distinguish "the playhead is on frame 0" from
      // "the playhead does not exist yet", and that ambiguity was a whole-call audio
      // outage: see the re-seed in ringWrite below. The other two fields that mean the
      // same thing already use -1 (SAB_START on the line above, pub[1] two lines down),
      // so this integer was the only one of the three that lied.
      Atomics.store(ctl, SAB_PLAY, -1);
      Atomics.store(ctl, SAB_TARGET, cfg.targetFrames);
      Atomics.store(ctl, SAB_LOCK, 0);
      tags.fill(-1);
      pub[0] = 0; // apUs
      pub[1] = -1; // playhead frame seq (-1 = playout not started)
    }
    let startSeq = -1;
    let hiSeq1 = 0;
    // The FIRST frame ever seen and when. `startSeq` moves when the pre-playout ring
    // re-seeds; these two never do, and they exist to bound that re-seed: elapsed time at
    // the nominal 125 frames/s says how far the sequence can legitimately have advanced.
    // Without that bound one bogus header could walk the accept window arbitrarily far
    // forward and silence the lane permanently — a strictly WORSE failure than the one the
    // re-seed fixes, since before it a nonsense seq was simply ignored as far-future.
    let firstSeq = -1, firstSeqAt = 0;
    // Post-start starvation re-anchor state (see the late branch in ringWrite).
    // `lastRingWriteAt` is the wall time of the last frame that actually LANDED;
    // `lastRejSeq` is the last rejected seq, for the two-coherent-frames guard;
    // `reprime` is true between telling the worklet to re-prime and seeing its
    // playhead actually reset — while it is set, SAB_PLAY is stale and must not
    // define the accept window.
    let lastRingWriteAt = 0, lastRejSeq = -1, reprime = false;
    const RE_ANCHOR = cfg.reAnchor !== false; // ?reanchor=0 is the control arm
    const pendingPort = []; // frames arrived before the playout node existed (port mode)

    // int24 → float32 scratch
    const f32 = new Float32Array(384);
    function decodeFrame(payload) {
      for (let s = 0; s < 384; s++) {
        const o = s * 3;
        let v = payload[o] | (payload[o + 1] << 8) | (payload[o + 2] << 16);
        if (v & 0x800000) v |= ~0xffffff;
        f32[s] = v / 8388608;
      }
      return f32;
    }
    // Compressed payload straight to float, without materialising the int24 bytes
    // in between — the ring only ever wanted samples.
    const zipInts = new Int32Array(384);
    function decodeZip(payload) {
      unpackFrame(payload, zipInts);
      // ── the PEER's capture depth, measured here ─────────────────────────────
      // Same probe as the send path, pointed at the far end. It belongs here
      // because the lane is bit-exact: these are literally the peer's microphone
      // samples, so this reads THEIR capture chain without depending on THEIR
      // client being up to date — which a cached pcm.js otherwise makes
      // unmeasurable, as it did on the first real-device call.
      if ((stats.rxProbeTick++ & 63) === 0) {
        stats.rxProbeFrames++;
        let m = 0, fit67 = 1;
        for (let s = 0; s < 384; s++) {
          m |= zipInts[s];
          const v = zipInts[s];
          if (fit67 && Math.round(Math.round((v * 32767) / 8388608) * (8388608 / 32767)) !== v) fit67 = 0;
        }
        let sh = 0;
        if (m !== 0) while (((m >> sh) & 1) === 0) sh++;
        stats.rxShiftSum += sh > 24 ? 24 : sh;
        if (sh >= 8) stats.rxShift8++;
        stats.rxFit32767 += fit67;
      }
      for (let s = 0; s < 384; s++) f32[s] = zipInts[s] / 8388608;
      return f32;
    }

    const playSeqNow = () => {
      if (sab) return Atomics.load(ctl, SAB_PLAY);
      return wl.playSeq ?? -1; // 1 Hz-stale in port mode; the worklet guards itself
    };

    // A-V sync anchor bookkeeping (main-thread side): capUs is exact on the
    // wire for data frames, but a FEC-REPAIRED frame has no header to recover
    // it from — parity covers payload only. capUs advances by exactly 8000 µs
    // per seq (both are the same render-quantum stream), so the last exact
    // anchor extrapolates drift-free.
    let lastCapSeq = -1, lastCapUs = 0;
    const capUsFor = (seq, capUs) => {
      if (typeof capUs === 'number' && capUs > 0) {
        lastCapSeq = seq;
        lastCapUs = capUs;
        return capUs;
      }
      return lastCapSeq >= 0 ? lastCapUs + (seq - lastCapSeq) * 8000 : 0;
    };

    // Returns true when the frame actually landed in the ring — the FEC path
    // uses this to separate "repaired in time" from "repaired but the playhead
    // had already passed" (both are honest; only the first one was audible).
    // `laneIdx` is which association delivered this frame, or -1 when nothing
    // did — FEC repairs and window-decoder reconstructions come through here
    // too, and a frame this side INVENTED must not be credited to, or held
    // against, any lane's punctuality.
    function ringWrite(seq, payload, capUs, zip, skewMs = 0, laneIdx = -1) {
      if (startSeq < 0) {
        startSeq = seq;
        firstSeq = seq;
        firstSeqAt = now();
        lastRingWriteAt = firstSeqAt;
        if (sab) Atomics.store(ctl, SAB_START, seq);
      }
      const cap = capUsFor(seq, capUs);
      // Availability time, for the jitter estimator. Called for FEC repairs too,
      // and that is deliberate: a frame that only existed once its RS group closed
      // was genuinely available that late, and pretending otherwise would size the
      // buffer too small for exactly the frames FEC is there to save.
      noteArrival(seq, skewMs, laneIdx);
      const samples = zip ? decodeZip(payload) : decodeFrame(payload);
      if (det) {
        let sumSq = 0;
        for (let i = 0; i < samples.length; i++) {
          const s = samples[i];
          sumSq += s * s;
        }
        det.play(now(), Math.sqrt(sumSq / samples.length));
      }
      if (!sab) {
        const copy = samples.slice(0);
        if (playNode) playNode.port.postMessage({ type: 'frame', seq, samples: copy, capUs: cap }, [copy.buffer]);
        // The pre-worklet holding queue. It is bounded, and it used to drop SILENTLY with
        // no counter anywhere — the same class of invisible loss as the unpublished
        // `farFuture` on the SAB path, and it happens under exactly the same condition:
        // an audio graph that takes more than ~512 ms to come up. Keeping the NEWEST
        // frames rather than the first, for the same reason the ring re-seeds: nothing is
        // playing yet, so the oldest queued audio is the audio least worth keeping.
        else if (pendingPort.length < RING_F) pendingPort.push({ seq, samples: copy, capUs: cap });
        else { pendingPort.shift(); pendingPort.push({ seq, samples: copy, capUs: cap }); stats.portDropped++; }
        return true;
      }
      const play = playSeqNow();
      // ── THE RING MUST HOLD THE NEWEST 512 ms, NOT THE FIRST ─────────────────────
      // `lo` is the oldest frame the ring will accept. Once the playhead exists that is
      // the playhead itself — writing behind it would corrupt a slot about to be read.
      // But BEFORE it exists there is no playhead to protect, and `lo` used to stay
      // pinned at `startSeq` for the entire audio-graph startup. So the 64-slot ring
      // filled with startSeq..startSeq+63 and then rejected every later frame as
      // far-future, `hiSeq1` froze, and when the playhead finally started it seeded at
      // `startSeq` — correct and useless, because `lo` then advanced at exactly the
      // sender's 125 frames/s and the gap NEVER closed.
      //
      // MEASURED CLIFF: 125*D < 2*RING_F - target, i.e. D < 1.008 s, where D is first
      // frame arriving -> `await addModule()` resolving. At D=0.865 s the call is
      // healthy; at D=1.173 s it is dead — depth -22927 ms, 2866 frames concealed,
      // 915 of 915 depth samples negative, i.e. ~23 s of audio the user never hears.
      // Every transport counter reads perfect throughout: 125 fps, lateFrames 0, pc
      // connected. One second of audio-graph startup is entirely ordinary on a cold or
      // loaded machine, so this was not a corner case.
      //
      // The fix has to be HERE, in the writer. A worklet-side re-anchor was tried and is
      // a trap: `hiSeq1` is frozen by the writer, so re-anchoring the playhead only
      // returns it to the same stale 512 ms — it moves depthMs from -24931 ms to a
      // plausible -39.9 ms and still concealed 3060 frames. Making the number look
      // reasonable while fixing nothing is this project's recurring failure mode.
      // The re-seed is BOUNDED by elapsed time at the nominal frame rate. A sender cannot
      // legitimately have advanced further than that, so a seq beyond it is a bogus header
      // and falls through to the far-future rejection exactly as it did before this fix
      // existed. Unbounded, a single nonsense sequence number would move the accept window
      // past every real frame and silence the lane for good — trading a startup-only
      // failure for a permanent one. The slack is a whole ring plus a second: legitimate
      // arrivals sit ~0 frames past the estimate, so this never binds on a real stream.
      const plausibleMax = firstSeq + Math.ceil((now() - firstSeqAt) / FRAME_MS) + RING_F + 125;
      if (play < 0 && seq >= startSeq + RING_F && seq <= plausibleMax) {
        // Nothing is reading the ring yet (play < 0 is exact, not the 1 Hz-stale port
        // value — the port path returned above and never reaches here). Drop the stale
        // window and re-anchor on this frame. Tags are cleared BEFORE republishing
        // SAB_START so the worklet's priming loop can never see a new start against old
        // tags; presence is `tag === seq`, and every stale tag is below the new startSeq,
        // so it could not have matched anyway. Worst case the worklet waits one 2.7 ms
        // render block.
        // Counted as its own event, NOT folded into farFuture: the frames this discards
        // were ACCEPTED into the ring, and calling them rejections would conflate two
        // different things in one counter. Frames discarded is reseeds x RING_F.
        stats.ringReseeds++;
        tags.fill(-1);
        startSeq = seq;
        Atomics.store(ctl, SAB_START, seq);
        // `hiSeq1` is deliberately NOT reset, unlike the model in testbed/pcm-origin.mjs.
        // A write can only land inside the window, so the highest seq ever written is
        // below `startSeq + RING_F` <= this `seq`; hiSeq1 is therefore already <= seq+1
        // and the store below advances it correctly. Zeroing it first would publish a
        // momentary hiSeq1 of 0 for no gain.
      }
      // The re-prime handshake: after a re-anchor the worklet is told to reset its
      // playhead over the port, but SAB_PLAY is written from the audio thread and
      // stays stale-huge for a message round-trip. Until it reads as reset (or as
      // inside the new window), the accept window is defined by startSeq alone —
      // otherwise the very frames the re-anchor exists to accept would still be late.
      if (reprime && (play < 0 || (play >= startSeq && play - startSeq < RING_F))) reprime = false;
      const lo = reprime ? startSeq : Math.max(startSeq, play);
      // ── Post-start starvation re-anchor ────────────────────────────────────────
      // MEASURED LIVE (room ver-kbqe-zzs, 2026-08-16): a phone whose CPU was crushed
      // by video encode captured audio at 54 of 125 frames/s — its seq clock ran at
      // 0.43x wall time. The receiver's playhead runs at wall time, so within a
      // second every arriving frame was behind it: late 6178 of 6150 recv, hiSeq
      // frozen from priming, depth -111 s by call end, 13k+ frames concealed —
      // 100% silence for the entire call while every transport counter read healthy.
      // The one existing re-seed is gated on `play < 0` and can never fire again
      // after playout starts. So: when nothing has landed in the ring for >1 s while
      // coherent, advancing, wire-delivered frames keep arriving outside the window,
      // the stream is real and the window is wrong — re-anchor the window on the
      // stream and re-prime the playhead. This plays the audio that actually exists
      // (intermittently, if the sender is slow — that is the honest best) instead of
      // concealing forever.
      //
      // Guards, each against a real failure mode:
      //   · laneIdx >= 0 — only a frame the WIRE delivered may move the window; an
      //     FEC repair of an old seq during a drought would re-anchor into the past.
      //   · two coherent frames — `seq` within 8 of the previous rejection, still
      //     advancing; a single corrupt header cannot move the window (the same
      //     reasoning as plausibleMax on the pre-playout re-seed above).
      //   · far-future re-anchors additionally respect plausibleMax: a seq beyond
      //     what wall time allows is a bogus header, exactly as before.
      //   · the 1 s drought itself rate-limits: each re-anchor resets the clock.
      const coherentAdvance = lastRejSeq >= 0 && seq > lastRejSeq && seq - lastRejSeq <= 8;
      const starving = RE_ANCHOR && play >= 0 && !reprime && laneIdx >= 0 && coherentAdvance
        && now() - lastRingWriteAt > 1000;
      const reAnchor = () => {
        stats.reAnchors++;
        L('pcm-reanchor', { seq, play, startSeq, sinceWriteMs: +(now() - lastRingWriteAt).toFixed(0) });
        tags.fill(-1);
        startSeq = seq;
        Atomics.store(ctl, SAB_START, seq);
        // hiSeq1 must follow the window in BOTH directions here — frozen high it
        // would keep depthMs lying, and on a sender seq restart it sits above the
        // whole new stream. The write below advances it to seq + 1.
        hiSeq1 = seq;
        Atomics.store(ctl, SAB_HI, seq);
        reprime = true;
        lastRingWriteAt = now();
        if (playNode) playNode.port.postMessage({ type: 'reprime' });
      };
      if (seq < lo) {
        lastRejSeq = seq;
        if (starving) reAnchor();
        else {
          stats.late++;
          // The playhead has already passed this frame's slot, so it will never be
          // heard however healthy the lane that carried it looked. Attributed, at
          // last, to the lane that was too slow to make the deadline.
          if (laneIdx >= 0) laneLate[laneIdx]++;
          bumpTarget('late');
          return false;
        }
      } else if (seq >= lo + RING_F) {
        lastRejSeq = seq;
        if (starving && seq <= plausibleMax) reAnchor();
        else { stats.farFuture++; return false; }
      }
      if (Atomics.load(tags, seq % RING_F) === seq) { stats.dup++; return false; }
      // Made the deadline. Counted here rather than at the top of the function so
      // a lane cannot look punctual by delivering duplicates of frames another
      // lane already landed — burst-shield twins are common and prove nothing
      // about the twin's route.
      if (laneIdx >= 0) laneOnTime[laneIdx]++;
      // Governor input (task #47): this frame's SLACK — how many frames ahead of
      // the playhead it landed. Exact counterfactual, not a model: had the buffer
      // been (lead − 1) frames shallower, this frame would still have played.
      // FEC repairs pass through here too, deliberately — a repair that landed
      // with 2 frames of slack is 2 frames of slack, and trimming past it would
      // turn the repair inaudible-late. `play >= 0` because before the playhead
      // exists there is no deadline to have slack against.
      if (JIT_GOV && play >= 0 && !reprime) {
        const lead = seq - play;
        if (lead < govTickMin) govTickMin = lead;
      }
      lastRingWriteAt = now();
      ring.set(samples, (seq % RING_F) * 384);
      capTs[seq % RING_F] = cap;
      // Release-publish: the tag store is seq_cst, so a reader that sees the tag
      // is guaranteed to see the samples (and vice versa on the acquire load).
      Atomics.store(tags, seq % RING_F, seq);
      if (seq + 1 > hiSeq1) {
        hiSeq1 = seq + 1;
        Atomics.store(ctl, SAB_HI, hiSeq1);
      }
      return true;
    }

    // ── Sender: RS accumulator + paced parity ─────────────────────────────────
    // Parity is computed over SENT frames only — a capture dropped to
    // backpressure never enters the XOR, and the member bitmap in the parity
    // header says so, so the receiver never "repairs" a drop into zeros.
    //
    // The symbol is the GROUP'S longest frame, not a fixed 1152 B. Compression
    // made the fixed symbol the lane's single largest waste: at ~714 B per data
    // frame, parity was 32% of all bytes sent and ~38% of each parity message was
    // zero padding. Sizing per group takes the mean symbol to 686 B on real audio
    // (padding 6.3% instead of 38%, testbed/pcmpack-test.mjs).
    //
    // The price is that RS can no longer fold each frame in as it goes out: the
    // max is not known until the group closes. That costs nothing in LATENCY —
    // parity was already emitted at close, on the first frame of the next group —
    // only ~30 µs of concentrated field work once per 80 ms. So the frames are
    // staged and rsClose() does the arithmetic.
    let rsBase = -1, rsBitmap = 0;
    const parityQ = [];
    const popcount = (x) => { let n = 0; while (x) { x &= x - 1; n++; } return n; };
    const rsLen = new Int32Array(RS_K);
    const rsStage = [];
    for (let i = 0; i < RS_K; i++) rsStage.push(new Uint8Array(RS_SYM_MAX));
    const rsSym = new Uint8Array(RS_SYM_MAX);

    // ── Adaptive code rate ────────────────────────────────────────────────────
    // RS(10,10+n) corrects n erasures in 10+n — a tolerance of n/(10+n). One
    // FIXED n is wrong at both ends of the range, and both ends were measured:
    // on a clean link n=3 spent 1577 parity packets (~0.30 Mbps, a third of the
    // lane) to repair exactly ZERO frames, while at 20% loss the 23.1% tolerance
    // of n=3 is exhausted anyway (conceal 26.1%, fecFailed 1415). Rate that buys
    // nothing at one end and cannot save the other end is not a code rate, it is
    // a constant.
    //
    // The rungs are DERIVED from RS_K, not hand-tuned. They used to be, and the
    // criterion was wrong: "smallest n with group-failure P(Bin(K+n, p) > n) near
    // 1%" counts a failed group of 5 the same as a failed group of 10, when the
    // first conceals half as much speech. Weighted by group size the right
    // criterion is expected concealed FRAMES per frame, and it moves the K=10
    // rungs from 1.5/4.0 to 1.0/2.8 — the hand-tuned pair turns out to be correct
    // for K=5 and 2.1x / 2.8x over budget at the K we actually ship, costing an
    // avoidable 0.19 pp at p=1.5% and 0.23 pp at p=4%. Deriving it also means the
    // ladder stays right if RS_K ever moves, which hand-tuned constants would not.
    // testbed/kchoice.mjs prints the same table and is where the target comes
    // from: 0.1 concealed frames per 100, one 8 ms frame per 10 s, below
    // audibility for PCM concealment.
    //
    // n=0 falls out of the same rule rather than being special-cased: with no
    // parity concealment equals raw loss, so the 0.1-per-100 target puts its
    // ceiling at 0.1% loss all by itself.
    //
    // Sender-local by construction. rsDecode() collects whatever parity slots
    // arrived and needs only pr.length >= erasures, so a lower n is
    // indistinguishable at the receiver from parity that was lost in flight.
    // Nothing is negotiated, no wire format changes, and n may move mid-call
    // between one group and the next at zero cost.
    // Starts fully protected and descends only once a link has PROVEN itself.
    // The first loss report cannot arrive until ~2.6 s of audio has been seen
    // (LOSS_LAG + LOSS_WIN frames), and starting low would spend that opening on
    // a link we know nothing about — the one moment we have no evidence at all.
    // Descending costs bytes we were already spending; starting low costs speech.
    let fecN = RS_P;
    let fecWantLowSince = 0;
    // ── Sliding-window arm (task #16) ─────────────────────────────────────────
    // SW switches this SENDER's parity from RS(K,K+n) to the window code. The
    // decoder side below is unconditional. Stride is the code-rate knob: pinned
    // by `?pcmswstride=`, else driven off the same loss ladder as fecN, mapped
    // through overhead equivalence (n parity per K data ≈ stride K/n).
    // The per-peer halves of the stage timing diagnostics (?pcmdiag=1): the
    // capture recorder is one per page (above), because there is one capture
    // cadence however many peers are listening to it.
    const diagSend = DIAG ? intervalRec() : null; // dc.send() actually called
    const diagRecv = DIAG ? intervalRec() : null; // T_DATA arrival off the wire

    const SW = !!cfg.pcmSw;

    // ── Burst shield (temporal duplication) ────────────────────────────────────
    // Above the parity ladder's top rung, parity math stops paying: at 20%+ loss
    // the odds of >n losses in a K-window exceed CONCEAL_TARGET for every n this
    // lane can afford. Duplication does not care about loss patterns: the twin
    // rides DUP_DELAY_F frames (24 ms) behind the original on a different
    // association, so only a burst longer than 24 ms that spans both stripes
    // kills a frame twice. Costs one extra audio lane (~0.75 Mbps) ONLY while
    // engaged; `?pcmdup=0` never engages it, `?pcmdup=1` engages from the first
    // frame, absent = auto on the same loss reads that drive the ladder.
    const DUP_MODE = cfg.pcmDup; // '0' | '1' | undefined
    let dupOn = DUP_MODE === '1';
    stats.dupOn = dupOn ? 1 : 0; // forced-on must be visible from the first snapshot
    let dupLowSince = 0;
    // duress() latch (see the method): worst recent level + when the raw read
    // last went below it. Flap fix from the first real marginal-link call.
    let dLevel = 0;
    let dLowSince = 0;
    // Auto-engage is deaf for the lane's first seconds: the sender SKIPS seqs
    // while associations open (pickDataAssoc undefined / over-budget), and the
    // peer's loss windows honestly read those holes as loss until they roll out
    // (LOSS_LAG + LOSS_WIN ≈ 2.5 s). Measured live 2026-08-11: both engage
    // variants fired on a pristine path at startup. The ladder owns the first
    // seconds — it was built to eat exactly this ambiguity cheaply.
    const DUP_WARMUP_MS = 6000;
    const dupT0 = now();
    const DUP_DELAY_F = 3;
    const dupQ = []; // [{seq, msg}] — twin ArrayBuffers awaiting their send turn
    const SW_STRIDE_PIN = Number.isFinite(cfg.pcmSwStride) && cfg.pcmSwStride >= 0
      ? cfg.pcmSwStride : null;
    const swEnc = SW ? SwEncoder() : null;
    // Same opening posture as fecN = RS_P: start fully protected, descend on proof.
    if (swEnc) swEnc.setStride(SW_STRIDE_PIN ?? SW_STRIDE);
    const swDec = SwDecoder();
    let swZip = false; // latest observed compression flag on the peer's data frames
    // The ladder speaks in n-parities-per-K; the window speaks in stride. Map by
    // overhead: n/K ≈ 1/stride, so stride = K/n (floor 2 — 50% overhead is the
    // most this code can spend). n=0 = parity off, exactly like rsClose's skip.
    function swSyncStride() {
      if (!swEnc || SW_STRIDE_PIN != null) return;
      swEnc.setStride(fecN === 0 ? 0 : Math.max(2, Math.round(RS_K / fecN)));
    }
    function onPeerLoss(pct, fastPct) {
      stats.peerLossPct = +pct.toFixed(2);
      stats.peerLossFastPct = +fastPct.toFixed(2);
      if (!FEC_ADAPT) return;
      // Raise on the fast read, lower on the slow one. Using one window for both
      // forces a single reaction time onto two decisions with opposite costs.
      const rung = (p) => Math.max(FEC_N_MIN, Math.min(FEC_N_MAX, ladderFor(p)));
      const wantUp = rung(fastPct);
      const want = rung(pct);
      // Up immediately, on WHICHEVER window is more alarmed — the fast one when a
      // burst is starting, the slow one for loss too thin to show in 512 ms. Down
      // only after the slow window has asked for less for a continuous 3 s. The
      // asymmetry is safe HERE in a way it was not for the jitter target: over-
      // protection costs bytes and nothing else, whereas the same shape applied
      // to buffer depth ratcheted LATENCY and had to be torn out. Bytes are
      // recoverable; a second of concealed speech is not.
      const up = Math.max(wantUp, want);
      if (up > fecN) { fecN = up; fecWantLowSince = 0; stats.fecNUp++; swSyncStride(); return; }
      if (want < fecN) {
        if (!fecWantLowSince) fecWantLowSince = now();
        // Straight to the rung the ladder asked for, not one step per dwell:
        // stepping would take ~12 s to reach n=0 on a link that was clean the
        // whole time, and each rung's dwell already re-reads a window covering
        // 2 s of history, so three dwells is not three independent confirmations.
        else if (now() - fecWantLowSince > 3000) { fecN = want; fecWantLowSince = 0; stats.fecNDown++; swSyncStride(); }
      } else fecWantLowSince = 0;

      // Burst shield engage/disengage. Same asymmetry as the ladder — engaging
      // early costs bytes, disengaging early costs speech — but NOT the same
      // trigger: the fast window alone is too jumpy for a 0.75 Mbps decision
      // (measured live 2026-08-11: stripe reordering at call start read as loss
      // and engaged the shield for ~4 s on a pristine path). So the fast read
      // may only engage when the slow, reorder-lagged window corroborates at
      // half the cap; the slow window alone engages unconditionally. Disengage
      // only after the slow window has read less than half cap for 3 s.
      if (DUP_MODE === undefined && now() - dupT0 > DUP_WARMUP_MS) {
        const cap = rungTop[Math.min(FEC_N_MAX, rungTop.length - 1)];
        if (!dupOn && (pct > cap || (fastPct > cap && pct > cap / 2))) {
          dupOn = true; dupLowSince = 0; stats.dupOn = 1;
        } else if (dupOn) {
          if (pct < cap / 2) {
            if (!dupLowSince) dupLowSince = now();
            else if (now() - dupLowSince > 3000) {
              dupOn = false; dupLowSince = 0; stats.dupOn = 0; dupQ.length = 0;
            }
          } else dupLowSince = 0;
        }
      }
    }

    function rsClose() {
      // n=0 skips the whole group: no field arithmetic, no parity on the wire.
      if (rsBase < 0 || fecN === 0 || popcount(rsBitmap) < 2) return;
      // `?pcmrsfixed=1` pins the symbol at the old fixed 1152 B. It exists so the
      // group-sized symbol has a control arm that differs in exactly one thing —
      // a claim about concealment cannot be read off two runs from two sessions,
      // because concealment at a given loss rate has a wide run-to-run spread.
      let symLen = RS_FIXED ? RS_SYM_MAX : 0;
      for (let i = 0; i < RS_K; i++) if (((rsBitmap >> i) & 1) && rsLen[i] > symLen) symLen = rsLen[i];
      // Read the rate ONCE for the whole group: the encoder's accumulators and
      // the emit loop below must agree, or the group would carry a parity index
      // whose symbol was never accumulated.
      const n = fecN;
      const enc = new RsEncoder(symLen, n);
      for (let i = 0; i < RS_K; i++) {
        if (!((rsBitmap >> i) & 1)) continue;
        // Safe to reuse one scratch: add() folds the bytes into its accumulator
        // immediately and keeps no reference. The tail must be cleared each time —
        // it holds the previous member's bytes, and a stale tail is parity that
        // repairs a frame into something plausible rather than something right.
        const sym = rsSym.subarray(0, symLen);
        sym.fill(0);
        sym.set(rsStage[i].subarray(0, rsLen[i]));
        enc.add(i, sym);
      }
      for (let j = 0; j < n; j++) {
        parityQ.push({ base: rsBase, idx: j, bitmap: rsBitmap, bytes: enc.parity(j).slice(0) });
      }
    }

    function rsAccumulate(seq, payload, len) {
      const base = seq - (seq % RS_K);
      if (base !== rsBase) { rsClose(); rsBase = base; rsBitmap = 0; }
      // Over the symbol ceiling (the codec's verbatim escape, 1153 B): this frame
      // simply does not join the group. Its bitmap bit stays clear, which the
      // receiver already reads as "never contributed" — a gap the concealer owns,
      // never an erasure it would repair into zeros. The alternative, a 1161 B
      // parity message, would fragment all three parity packets of the group to
      // protect the one frame least worth protecting.
      if (len > RS_SYM_MAX) { stats.rsOversize++; return; }
      const pos = seq - base;
      rsStage[pos].set(payload.subarray(0, len));
      rsLen[pos] = len;
      rsBitmap |= 1 << pos;
    }

    // Association pickers. Data home = seq mod N; parity home = group ordinal
    // mod N (base % N degenerates when N divides RS_K — see pickParityAssoc).
    // A closed or over-budget home hands the parcel to the NEXT association in
    // the round-robin before anything is dropped — the stripe exists to absorb
    // exactly this (§17.12).
    function pickDataAssoc(seq) {
      const home = lanePos(seq);
      let anyOpen = false;
      for (let k = 0; k < PAIRS; k++) {
        const a = assocs[fastOrder[(home + k) % PAIRS]];
        if (a.dc?.readyState !== 'open') continue;
        anyOpen = true;
        if (a.dc.bufferedAmount <= backlogLimit(a)) return a;
      }
      return anyOpen ? null : undefined; // undefined: channel not up yet (silent, as today)
    }

    // The twin's home is offset half the stripe from the original's: on 6
    // associations seq's data rides (seq % 6), its twin (seq+3) % 6 — maximally
    // far in the round-robin, so one association's queue trouble cannot hold
    // both copies. Falls forward like pickDataAssoc; over-budget everywhere
    // drops the TWIN only (the original already went out — the shield is best-
    // effort extra, never backpressure).
    function pickTwinAssoc(seq) {
      const home = lanePos(seq, true);
      for (let k = 0; k < PAIRS; k++) {
        const a = assocs[fastOrder[(home + k) % PAIRS]];
        if (a.dc?.readyState !== 'open') continue;
        if (a.dc.bufferedAmount <= backlogLimit(a)) return a;
      }
      return null;
    }

    function pickParityAssoc(base) {
      // Home by GROUP ORDINAL, not base: bases stride by RS_K (10), so
      // base % N degenerates to 0 for every group whenever N divides RS_K —
      // measured at pairs=2: 100% of parity piled onto association 0, which
      // tipped it into the wall while association 1 idled. (base/RS_K) % N
      // stripes evenly for every N; at N=1 and N=3 it is the identical mapping.
      const home = lanePos(Math.floor(base / RS_K));
      for (let k = 0; k < PAIRS; k++) {
        const a = assocs[fastOrder[(home + k) % PAIRS]];
        if (a.dc?.readyState === 'open') return a;
      }
      return null;
    }

    function sendParity(p) {
      if (p.sw) return sendSwParity(p);
      // Its receiver reads idx/bitmap/base and never the wall at offset 8, so the
      // compact form is those fields exactly: 8 B. The payload is the group's
      // symbol, ≤ RS_SYM_MAX, so the message is ≤ 1160 B — one datagram, always.
      // Its length IS the symbol length; that is how the receiver learns it, and
      // why no length field is on the wire.
      const hdr = COMPACT ? HDR_PAR_C : HDR;
      const msg = new ArrayBuffer(hdr + p.bytes.length);
      const dv = new DataView(msg);
      dv.setUint8(0, COMPACT ? T_PAR_C : T_PARITY);
      dv.setUint8(1, p.idx);
      dv.setUint16(2, p.bitmap);
      dv.setUint32(4, p.base);
      if (!COMPACT) dv.setFloat64(8, now());
      new Uint8Array(msg, hdr).set(p.bytes);
      // Parity stripes like the data: group g rides association (g mod N).
      // Ungated, exactly as on one association — a gate drop here would gut the
      // group it repairs. Falls to the next association only while its own is
      // not yet open.
      const a = pickParityAssoc(p.base);
      if (!a) return;
      try { a.dc.send(msg); } catch { return; }
      a.paritySent++;
      a.parityBytes += msg.byteLength;
      a.bytesSent += msg.byteLength;
      stats.paritySent++;
      stats.parityBytes += msg.byteLength;
      stats.bytesSent += msg.byteLength;
    }

    function sendSwParity(p) {
      const msg = new ArrayBuffer(HDR_PAR_SW + p.sym.length);
      const dv = new DataView(msg);
      dv.setUint8(0, T_PAR_SW);
      dv.setUint8(1, p.s & 0xff);
      dv.setUint16(2, p.bitmap);
      dv.setUint32(4, p.end);
      new Uint8Array(msg, HDR_PAR_SW).set(p.sym);
      // Stripe by parity ordinal — the same even mapping RS gets from
      // (base/RS_K) % N, without the degenerate base % N trap.
      const home = lanePos(p.s);
      let a = null;
      for (let k = 0; k < PAIRS; k++) {
        const c = assocs[fastOrder[(home + k) % PAIRS]];
        if (c.dc?.readyState === 'open') { a = c; break; }
      }
      if (!a) return;
      try { a.dc.send(msg); } catch { return; }
      a.paritySent++;
      a.parityBytes += msg.byteLength;
      a.bytesSent += msg.byteLength;
      stats.paritySent++;
      stats.parityBytes += msg.byteLength;
      stats.bytesSent += msg.byteLength;
    }

    /**
     * Offer one captured frame to THIS peer. §5.1's one line of fan-out lives
     * at the call site: the capture half hands the same frame to every half,
     * and each decides on its own associations, its own header, its own parity
     * and its own code rate. The compressed bytes come from `packOnce`, which
     * is keyed on the frame's seq, so the second peer to ask for them pays
     * nothing and the first pays exactly what it paid before the split.
     */
    function offerFrame(seq, buf, capUs) {
      const a = pickDataAssoc(seq);
      if (a === undefined) return; // channel not up yet — silently skipped, as before
      if (a === null) {
        // Every association over budget: the frame is spent as a gap, counted on
        // its home association.
        assocs[seq % PAIRS].skipBuffered++;
        stats.skipBuffered++;
        return;
      }
      if (stats.t0 == null) stats.t0 = now();
      // The anchor carries what the compact header drops, so it is kept current
      // from the same place the frames come from — but it anchors on the
      // LEAST-DELAYED frame of the window, not the latest. The receiver derives
      // every wall in the window as anchWall + 8 ms/seq, so whatever main-thread
      // scheduling jitter the anchoring frame happened to suffer gets injected
      // into all ~31 samples behind it. `wall - seq*8` is a constant for a
      // perfectly paced sender, so its minimum over the window picks the frame
      // posted soonest after capture. The window resets on every send, so the
      // extrapolation never spans more than anchorMs and clock drift between the
      // audio clock and performance.now() (ppm × 250 ms) cannot accumulate.
      if (COMPACT) {
        const w = now();
        const k = w - seq * FRAME_MS;
        if (k < anchBestK) { anchBestK = k; lastCapSeqTx = seq; lastCapUsTx = capUs ?? 0; lastCapWallTx = w; }
        // Sent from the capture path rather than on a timer: the first frame gets
        // an anchor immediately (no window of NaN ageMs at call start), and a
        // stream that is not producing does not emit anchors for audio nobody
        // will hear. Ahead of this frame's own send, so it can never trail the
        // frames it anchors.
        if (w - anchSentAt >= ANCHOR_MS) { anchSentAt = w; sendAnchor(); anchBestK = Infinity; }
      }
      const hdr = COMPACT ? HDR_DATA_C : HDR;
      // Compress before sizing the message: the payload is variable length now.
      let payLen = FRAME_BYTES;
      if (ZIP) payLen = packOnce(seq, buf);
      const msg = new ArrayBuffer(hdr + payLen);
      const dv = new DataView(msg);
      if (ZIP) {
        dv.setUint8(0, T_DATA_Z);
        dv.setUint32(1, seq);
      } else if (COMPACT) {
        dv.setUint8(0, T_DATA_C);
        dv.setUint32(1, seq);
      } else {
        dv.setUint8(0, T_DATA);
        dv.setUint16(2, 0);
        dv.setUint32(4, seq);
        // Absolute wall clock, same convention as lane 1's sendWallMs: with the
        // ping/pong offset this makes one-way audio delay measurable.
        dv.setFloat64(8, now());
        // §10: the frame's capture time on the sender's AUDIO clock — the A-V
        // sync anchor. From the capture worklet's currentTime, never the wall.
        dv.setFloat64(16, capUs ?? 0);
      }
      new Uint8Array(msg, hdr).set(ZIP ? zipOut.subarray(0, payLen) : new Uint8Array(buf));
      try { a.dc.send(msg); } catch { return; }
      diagSend?.hit(performance.now());
      a.framesSent++;
      a.bytesSent += msg.byteLength;
      stats.framesSent++;
      stats.bytesSent += msg.byteLength;
      // Burst shield: queue this frame's twin, and send the twin whose turn has
      // come (DUP_DELAY_F frames of temporal diversity). Draining here — on the
      // next frames' sends — needs no timer and dies with the lane.
      if (dupOn) dupQ.push({ seq, msg });
      while (dupQ.length && seq - dupQ[0].seq >= DUP_DELAY_F) {
        const tw = dupQ.shift();
        const ta = pickTwinAssoc(tw.seq);
        if (!ta) { stats.dupSkipped++; continue; }
        try { ta.dc.send(tw.msg); } catch { continue; }
        ta.bytesSent += tw.msg.byteLength;
        stats.dupSent++;
        stats.dupBytes += tw.msg.byteLength;
      }
      // Staged at its natural length; the group is padded to its own longest
      // frame when it closes. Rice decoding stops after 384 samples on its own,
      // so whatever padding remains is never read back and a repaired frame still
      // needs no length field.
      if (cfg.fec && !SW) rsAccumulate(seq, ZIP ? zipOut : new Uint8Array(msg, hdr), payLen);
      if (cfg.fec && SW) {
        // The window holds a VIEW into this frame's own message buffer (msg is
        // per-frame, never reused — unlike zipOut, which is scratch), so add()
        // costs no copy. Oversize frames (codec's verbatim escape) skip the
        // window exactly as they skip an RS group: absent from the bitmap, the
        // receiver gaps them, never repairs them into padding.
        if (payLen <= SW_SYM_MAX) swEnc.add(seq, new Uint8Array(msg, hdr));
        else stats.rsOversize++;
        if (swEnc.due()) parityQ.push({ sw: 1, ...swEnc.parity() });
      }
      // Paced parity: at most one parity packet per capture tick, riding the
      // ticks right after a group closes. Never three in a clump.
      if (parityQ.length) sendParity(parityQ.shift());
    }


    // ── Raw one-way loss, measured on the data sequence itself ────────────────
    // This is what T_LOSS reports to the peer, so it has to keep working when
    // parity is OFF. That rules out the obvious source — the group bitmap — which
    // is only ever set by an arriving PARITY message (see the T_PAR_C handler).
    // At n=0 no parity exists, the bitmap stays 0 forever, every FEC counter
    // reads zero, and a ladder built on them would report "no loss" on a link
    // that had collapsed and could never climb back out. The data sequence is the
    // one signal that is present at every rung.
    const SEEN_N = 1024;
    const seen = new Uint8Array(SEEN_N);
    let seenHi = -1;
    function noteSeen(seq) {
      if (seq > seenHi) {
        // Clear what we advance over. Without this a wrapped ring reports an
        // arrival from 8 s ago as this frame's, and loss reads 0 forever.
        if (seenHi < 0 || seq - seenHi >= SEEN_N) seen.fill(0);
        else for (let s = seenHi + 1; s <= seq; s++) seen[s % SEEN_N] = 0;
        seenHi = seq;
      } else if (seenHi - seq >= SEEN_N) return; // older than the ring: not ours to mark
      seen[seq % SEEN_N] = 1;
    }
    // Lagged, so reordering across the PAIRS associations is not counted as loss:
    // the stripe deliberately sends consecutive seqs down different SCTP
    // associations, whose queues differ. At 125 fps a 64-frame lag is 512 ms of
    // grace, far past any stripe skew measured, and the 256-frame window is ~2 s.
    const LOSS_LAG = 64, LOSS_WIN = 256;
    // A second, much faster read used ONLY to raise the code rate. Measured: with
    // the slow window alone, a burst arriving on a link that had descended to n=0
    // took ~1.5 s to be believed, and cost 3.19% concealment against the fixed
    // rate's 2.98% over a clean→10%→clean run. The two directions do not deserve
    // the same evidence: raising early costs a few hundred ms of parity bytes,
    // lowering early costs speech. So the fast window may be jumpy — reordering
    // across the PAIRS associations can briefly read as loss here, and a spurious
    // rung is the cheapest possible mistake — while the slow window, which alone
    // governs coming back down, stays deliberate.
    const FAST_LAG = 16, FAST_WIN = 64;
    function lossOver(lag, win) {
      if (seenHi < lag + win) return null; // not enough history to divide by
      const hi = seenHi - lag;
      let miss = 0;
      for (let s = hi - win + 1; s <= hi; s++) if (!seen[s % SEEN_N]) miss++;
      return (100 * miss) / win;
    }

    // ── Receiver: groups, repair, expiry ──────────────────────────────────────
    // Group lifecycle: open → resolved (complete or repaired) → expired
    // (playhead passed; counted exactly once) → evicted (writer-head horizon,
    // when every parcel for the group — 10 data + 3 paced parity — has been
    // sent). Expired and resolved groups are kept as husks, never deleted on
    // the spot: with a 2-frame jitter target the parity tail lands *around*
    // playhead passage, and a deleted group gets re-created by that trailing
    // parity as a bitmap-only phantom, which the next expiry counts as RS_K
    // failed frames that were never lost (measured: ~10 phantom failures per
    // group on a clean loopback run).
    const groups = new Map(); // base -> { bitmap, data[], par[], nPar, resolved, expired }

    function getGroup(base) {
      let g = groups.get(base);
      if (!g) {
        g = { bitmap: 0, data: new Array(RS_K).fill(null), par: new Array(RS_P).fill(null), nPar: 0, resolved: false, expired: false, zip: false };
        groups.set(base, g);
        // Retention in TIME, not in groups: at RS_K=5 a fixed 16 would hold only
        // 0.64 s, inside the window where trailing parity still arrives, and the
        // eviction would recreate phantom groups. ~1.3 s at any span. Expiry
        // below is the real bound; this is the backstop.
        const keep = Math.max(16, Math.ceil(1300 / (RS_K * FRAME_MS)));
        if (groups.size > keep) groups.delete(groups.keys().next().value);
      }
      return g;
    }

    function maybeResolve(g, base) {
      if (g.resolved || g.expired || !g.bitmap) return;
      const missing = [];
      for (let i = 0; i < RS_K; i++) if (((g.bitmap >> i) & 1) && !g.data[i]) missing.push(i);
      if (!missing.length) { g.resolved = true; g.data.fill(null); return; }
      if (missing.length > g.nPar) return; // parity still in flight
      // The symbol length arrives implicitly, as the length of the parity message
      // itself — the sender sized it to the longest frame in this group. Data
      // frames were stored at their natural length, so pad them to match here.
      let symLen = 0;
      for (let j = 0; j < RS_P; j++) if (g.par[j]) { symLen = g.par[j].length; break; }
      const padded = new Array(RS_K).fill(null);
      for (let i = 0; i < RS_K; i++) {
        const d = g.data[i];
        if (!d) continue;
        if (d.length === symLen) { padded[i] = d; continue; }
        if (d.length < symLen) { const c = new Uint8Array(symLen); c.set(d); padded[i] = c; continue; }
        // Longer than the symbol. A contributing member cannot be — the sender
        // took the max over exactly these positions — so this is a disagreement
        // about what the group IS, and solving anyway would XOR the wrong bytes
        // out and hand the concealer confident garbage. Refuse the decode; the
        // frames that did arrive still play, the missing ones are concealed.
        if ((g.bitmap >> i) & 1) { stats.fecSymMismatch++; return; }
      }
      const rec = rsDecode(g.bitmap, padded, g.par);
      if (!rec) return;
      const playAt = playSeqNow();
      for (const [pos, bytes] of rec) {
        // WHERE in the group a repair lands decides whether it is usable at all.
        // Parity cannot be computed until the group CLOSES, so position 0 waits
        // the full 80 ms span plus parity pacing before its repair even exists,
        // while position 9 waits ~8 ms. If the late repairs cluster at LOW
        // positions the cure is a shorter span, not a deeper buffer — and a
        // deeper buffer is latency we are trying to spend nowhere else.
        if (ringWrite(base + pos, bytes, undefined, g.zip)) { stats.fecRepaired++; stats.fecOkPos[pos]++; }
        else {
          stats.fecRepairedLate++;
          stats.fecLatePos[pos]++;
          if (playAt >= 0) {
            const by = (playAt - (base + pos)) * FRAME_MS;
            stats.fecLateMsSum += by;
            if (by > stats.fecLateMsMax) stats.fecLateMsMax = by;
          }
        }
      }
      g.resolved = true;
      g.data.fill(null);
    }

    function expireGroups() {
      const play = playSeqNow();
      for (const [base, g] of groups) {
        if (!g.expired && play >= 0 && base + RS_K <= play) {
          // The playhead has passed: whatever was missing was concealed. Count
          // once, keep the husk.
          let miss = 0;
          if (!g.resolved) {
            for (let i = 0; i < RS_K; i++) if (((g.bitmap >> i) & 1) && !g.data[i]) miss++;
          }
          stats.fecFailed += miss;
          g.expired = true;
          g.data.fill(null);
          g.par.fill(null);
        }
        // Final eviction: all 13 parcels were sent by base+13 (parity is paced
        // one per capture tick), plus slack for the sender's backpressure drops.
        if (base + RS_K + RS_P + 8 <= hiSeq1) groups.delete(base);
      }
    }

    // ── Sliding-window repair (peer sent T_PAR_SW) ────────────────────────────
    // Recovered frames take EXACTLY the path an RS repair takes: ringWrite with
    // no capUs (capUsFor extrapolates, same as any repaired frame), zip flag from
    // the peer's own data frames, and the same repaired/late counters — so
    // relpair, the ladder, and every existing readout price both codes on one
    // scale without knowing which one ran.
    function swRepairTry() {
      if (seenHi < 0) return;
      const got = swDec.repair(seenHi);
      if (!got.size) return;
      const playAt = playSeqNow();
      for (const [q, bytes] of got) {
        if (ringWrite(q, bytes, undefined, swZip)) stats.fecRepaired++;
        else {
          stats.fecRepairedLate++;
          if (playAt >= 0) {
            const by = (playAt - q) * FRAME_MS;
            stats.fecLateMsSum += by;
            if (by > stats.fecLateMsMax) stats.fecLateMsMax = by;
          }
        }
      }
    }

    // ── Clock: ping/pong on every media channel (control this tiny tolerates
    // unreliable — a lost ping costs nothing, the next one is 2 s away). Each
    // association keeps its OWN rtt/baseRtt/offset: the gate budgets against the
    // association's own floor, and a frame's age is read through the offset of
    // the association that carried it (§17.12's per-association caveat).
    // The anchor: 21 B, 4×/s, on every open association so any one arriving is
    // enough. It replaces 16 B on each of 125 frames/s with 84 B/s — and unlike
    // the per-frame copy it cannot be lost in a way that costs audio, because a
    // missing anchor only degrades a statistic and a stale one still extrapolates
    // exactly (capUs advances 8000 µs per seq by construction).
    function sendAnchor() {
      if (closed || !COMPACT || lastCapSeqTx < 0) return;
      const msg = new ArrayBuffer(HDR_ANCH);
      const dv = new DataView(msg);
      dv.setUint8(0, T_ANCH);
      dv.setUint32(1, lastCapSeqTx);
      dv.setFloat64(5, lastCapWallTx);
      dv.setFloat64(13, lastCapUsTx);
      for (const a of assocs) {
        if (a.dc?.readyState !== 'open') continue;
        try { a.dc.send(msg); } catch { /* an anchor is never worth throwing for */ }
      }
    }

    function sendPing() {
      const msg = new ArrayBuffer(9);
      const dv = new DataView(msg);
      dv.setUint8(0, T_PING);
      dv.setFloat64(1, now());
      for (const a of assocs) {
        if (a.dc?.readyState !== 'open') continue;
        try { a.dc.send(msg); } catch { /* ignore */ }
      }
    }

    // 2 B on every open association, 4×/s: 8 B/s per association against a
    // ~0.92 Mbps lane. Sent on ALL of them rather than one, because the report
    // that matters most is the one from the link that is losing packets, and
    // that is precisely the link most likely to drop it.
    // ── Unplayable rate, not loss rate (`?pcmfeclate=0` to disable) ───────────
    // The ladder used to be fed `lossOver()`, i.e. packets that never arrived. On
    // a bandwidth-constrained link that reads 0/0 while the lane conceals 2.2%,
    // because the damage is LATENESS: the frames arrive, just after the playhead.
    // So the lane ran completely unprotected exactly where it was being hurt.
    //
    // A late frame is precisely what parity could have rebuilt early from the
    // frames that DID arrive on time, so what the code rate should track is
    // "frames I could not play", and loss is only one of its two terms. The two
    // are disjoint by construction: a late frame was `seen`, so it never enters
    // lossOver().
    //
    // This redefines the meaning of the existing T_LOSS bytes rather than adding
    // one. No wire change, no capability handshake -- and safe against a peer
    // that predates it, because the byte is advisory in exactly the same way it
    // already was (a missing report costs one rung, never audio).
    //
    // Only viable since the peak-hold change put the playhead 56-84 ms back: at
    // the old 24 ms depth, 100 of 215 successful RS decodes arrived too late to
    // use, and more parity would have bought nothing.
    // MEASURED AND LOST -- default OFF, `?pcmfeclate=1` to re-enable for testing.
    // n=8 interleaved at --bw=0.3: conceal 3.96 vs 2.42% (t = 2.57), p50 71.8 vs
    // 65.4 ms (t = 2.66), lane 0.816 vs 0.754 Mbps (t = 4.55) -- all three
    // DISTINGUISHABLE and all three WORSE. The reasoning above is sound and the
    // mechanism engaged (parityRecv 572-710 against a ~215 baseline); it is
    // simply self-defeating on a rate-limited link. More parity is +8% bytes into
    // the very queue that is causing the lateness, so it buys repairs by making
    // more frames late (bwDropped 0.34 -> 0.48%). Redundancy cannot fix a
    // congestion symptom, because redundancy IS congestion.
    const FEC_LATE = cfg.fecLate === true;
    let lateSeen = 0, latePctEma = 0;
    function unplayableExtra() {
      if (!FEC_LATE) return 0;
      const now = stats.late + (wl.lateFrames ?? 0);
      const d = Math.max(0, now - lateSeen);
      lateSeen = now;
      // 250 ms per report / 8 ms per frame = 31.25 frames. Far too few to read a
      // percentage off directly, so smooth it -- 0.2 gives a ~1.25 s constant,
      // comfortably shorter than the ladder's own hysteresis.
      latePctEma = 0.8 * latePctEma + 0.2 * ((100 * d) / (250 / FRAME_MS));
      return latePctEma;
    }

    function sendLossReport() {
      if (closed) return;
      const raw = lossOver(LOSS_LAG, LOSS_WIN);
      const late = unplayableExtra();
      const pct = raw == null ? null : raw + late;
      if (pct == null) return; // no history yet — say nothing rather than say zero
      // The fast window fills first, so it is always available by the time the
      // slow one is; the ?? is for the impossible case, not the normal one.
      const fast = (lossOver(FAST_LAG, FAST_WIN) ?? raw) + late;
      stats.lossPct = +pct.toFixed(2);
      stats.lossFastPct = +fast.toFixed(2);
      const msg = new ArrayBuffer(3);
      const dv = new DataView(msg);
      dv.setUint8(0, T_LOSS);
      dv.setUint8(1, Math.min(255, Math.round(pct * 4)));
      dv.setUint8(2, Math.min(255, Math.round(fast * 4)));
      for (const a of assocs) {
        if (a.dc?.readyState !== 'open') continue;
        try { a.dc.send(msg); } catch { /* a lost report costs one rung of latency, never audio */ }
      }
    }

    function sendSkewReport() {
      if (closed || !SKEWFB) return;
      const all = laneSkewAll();
      if (all.numWarm < 2) return;
      const msg = new ArrayBuffer(3 + 2 * PAIRS);
      const dv = new DataView(msg);
      dv.setUint8(0, T_SKEW);
      dv.setUint8(1, all.warmMask & 0xff);
      for (let k = 0; k < PAIRS; k++) {
        const skewVal = all.perLane[k] ?? 0;
        dv.setUint8(2 + k, Math.min(255, Math.round(skewVal * 2)));
      }
      // Liveness: has this lane delivered a frame in the last second? A lane
      // that has NEVER delivered reads as live — at call start nothing has
      // arrived yet, and "unknown" must never be reported as "dead".
      const tnow = now();
      let liveMask = 0;
      for (let k = 0; k < PAIRS; k++) {
        if (lastFrameT[k] === 0 || (tnow - lastFrameT[k]) < 1000) liveMask |= (1 << k);
      }
      dv.setUint8(2 + PAIRS, liveMask & 0xff);
      // Per-lane percentage of frames that arrived too late to play, then decay.
      // Written AFTER the reading is taken so the number sent is the one just
      // measured; the decay is what makes the next report a fresh ~10 s window
      // rather than a cumulative verdict a healed lane can never live down.
      for (let k = 0; k < PAIRS; k++) {
        dv.setUint8(3 + PAIRS + k, Math.min(255, laneLatePct(k)));
        laneLate[k] *= LATE_DECAY;
        laneOnTime[k] *= LATE_DECAY;
      }
      // ON EVERY OPEN ASSOCIATION, not on lane 0. This is the same rule the
      // ping and the loss report already follow, for the same reason their
      // comments give — the report that matters most is the one from the link
      // that is in trouble, and that is precisely the link most likely to eat
      // it. The skew report was the one control message that did not get it,
      // and it is the one carrying the lane-health verdict.
      //
      // What that cost, traced second by second on the 3-of-6-stalled scenario
      // (testbed/skewstripe-stall.mjs): lane 0 is one of the stalled routes, so
      // the instant the fault landed the CONTROL PLANE went down a five-second
      // hole with it. The peer's peerSkewAt went stale after 2 s, it correctly
      // fail-opened to all six lanes — and fail-open means posting audio
      // straight back into the routes that had just been demoted for being
      // unusable. The trace shows it exactly: t+2s the peer has moved off the
      // bad lanes, t+3s `n6[012345] STALE1`, all six back in service.
      //
      // A lane-health signal that cannot be delivered by an unhealthy lane
      // reports on every lane except the ones worth reporting on.
      //
      // Cost: 15 B at 4/s per association — 360 B/s across six lanes against a
      // ~0.92 Mbps lane. The receiver overwrites from whichever copy lands, and
      // the copies within a tick are identical, so duplicates are idempotent.
      let sent = 0;
      for (const a of assocs) {
        if (a.dc?.readyState !== 'open') continue;
        try { a.dc.send(msg); sent++; } catch { /* advisory telemetry report */ }
      }
      stats.skewReportFanout = sent;
    }

    // ── Lane 0 wire senders (§3.1 lever 4, §4) ────────────────────────────────
    // Both ride the EXISTING unreliable/unordered pcm-audio channel(s) — no new
    // channels, no renegotiation. Both are small, rare, and ungated (like
    // parity: a gate drop here would defeat their entire purpose).
    function firstOpenAssoc() {
      for (const a of assocs) if (a.dc?.readyState === 'open') return a;
      return null;
    }

    // A turn-end prediction: 13 bytes, sent twice back to back on the first
    // open association. The duplicate is against LOSS (at 1% loss the pair
    // delivers with p ≈ 0.9999); congestion is not the failure mode at 13 B.
    function sendTurnEnd() {
      if (closed || !cfg.lane0) return 0; // kill switch: the type never exists on the wire
      const a = firstOpenAssoc();
      if (!a) return 0;
      const msg = new ArrayBuffer(13);
      const dv = new DataView(msg);
      dv.setUint8(0, T_PRED);
      dv.setUint32(1, predSeq);
      dv.setFloat64(5, now());
      predSeq++;
      let sent = 0;
      for (let c = 0; c < 2; c++) {
        try { a.dc.send(msg); sent++; } catch { break; }
      }
      if (sent) stats.predSent++;
      return sent;
    }

    // Pre-warm padding (~25 KB total, §3.1's budget): ~1 KB throwaway datagrams
    // paced at the lane's own 125 pps tick, round-robin across ALL open
    // associations — each stripe's cwnd decays independently on a listening
    // stretch, so each gets its share. Channels not yet open: drop the pad
    // rather than queue it (a pad that arrives after the reply started is
    // wasted bytes).
    const PAD_MSG = 1000;
    function sendPad(totalBytes = 25000) {
      if (closed || !cfg.lane0) return;
      padLeft += totalBytes;
      if (padTimer) return; // a pad is already running; it absorbs the addition
      padTimer = setInterval(() => {
        if (closed || padLeft <= 0) { clearInterval(padTimer); padTimer = null; padLeft = 0; return; }
        const n = Math.min(PAD_MSG, padLeft);
        const msg = new ArrayBuffer(5 + n);
        const dv = new DataView(msg);
        dv.setUint8(0, T_PAD);
        dv.setUint32(1, padSeq++);
        let sent = false;
        for (let k = 0; k < PAIRS; k++) {
          padRr = (padRr + 1) % PAIRS;
          const a = assocs[padRr];
          if (a.dc?.readyState !== 'open') continue;
          try { a.dc.send(msg); sent = true; } catch { continue; }
          a.padBytesSent += msg.byteLength;
          break;
        }
        if (!sent) { padLeft = 0; clearInterval(padTimer); padTimer = null; return; }
        stats.padBytesSent += msg.byteLength;
        stats.padMsgsSent++;
        padLeft -= n;
      }, 8);
    }

    function onMessage(data, ai) {
      if (closed || !(data instanceof ArrayBuffer) || data.byteLength < 2) return;
      const a = assocs[ai] ?? assocs[0];
      const dv = new DataView(data);
      const t = dv.getUint8(0);
      // T_LOSS is the only 2-byte type; every branch below reads at least 9 B, so
      // the original blanket guard stays in force for all of them. It is checked
      // HERE rather than beside T_ANCH because that blanket `< 9` silently ate
      // every loss report on the first deployed build — the ladder read a clean
      // `fecN 3/3` and looked exactly like a link that never needed to adapt.
      if (t === T_LOSS) {
        // Byte 2 (the fast window) is additive: a peer on the 2-byte build sends
        // only the slow read, and using it for both directions is exactly that
        // build's behaviour rather than a broken one.
        const slow = dv.getUint8(1) / 4;
        onPeerLoss(slow, data.byteLength >= 3 ? dv.getUint8(2) / 4 : slow);
        return;
      }
      if (t === T_SKEW) {
        // Handled above the < 9 guard: at pairs=6 T_SKEW is 8 bytes.
        if (data.byteLength >= 3) {
          const mask = dv.getUint8(1);
          const laneCount = Math.min(PAIRS, data.byteLength - 2);
          for (let k = 0; k < laneCount; k++) {
            // The value is kept even for saturated readings (255 → 127.5 ms:
            // "at least this much"); the mask, not the value, says whether the
            // reading is warm enough to act on.
            peerSkewMs[k] = (mask & (1 << k)) ? dv.getUint8(2 + k) / 2 : 0;
          }
          peerSkewWarm = mask;
          // Absent on an older peer's 8-byte report: assume every lane live, so
          // a missing field can never cause a demotion.
          peerLiveMask = data.byteLength >= 3 + PAIRS ? dv.getUint8(2 + PAIRS) : 0xff;
          // Per-lane late percentage. Absent on any peer older than 2026-08-14,
          // and absent must read as 0 (perfectly punctual) for the same reason
          // liveness defaults to all-live: a field the peer cannot send is not
          // evidence against it.
          const haveLate = data.byteLength >= 3 + 2 * PAIRS;
          for (let k = 0; k < PAIRS; k++) {
            peerLatePct[k] = haveLate ? dv.getUint8(3 + PAIRS + k) : 0;
          }
          peerSkewAt = now();
          if (SKEWSTRIPE) recomputeLaneOrder();
        }
        return;
      }
      if (data.byteLength < 9) return;
      if (t === T_PAD) {
        // Throwaway pre-warm bytes: count and discard ON SIGHT. This branch is
        // deliberately above every other — T_PAD must never reach a group, the
        // ring, the playhead, or the detector.
        stats.padBytesRecv += data.byteLength;
        stats.padMsgsRecv++;
        a.padBytesRecv += data.byteLength;
        return;
      }
      if (t === T_PRED) {
        const seq = dv.getUint32(1);
        // The pair's second copy: counted (it proves the duplication works),
        // never re-fired — one prediction schedules the network once.
        if (seq === lastPredSeq) { stats.predDup++; return; }
        lastPredSeq = seq;
        stats.predRecv++;
        try { onPredict?.({ seq, wall: dv.getFloat64(5), recvAt: now() }); }
        catch { /* scheduling metadata must never break the lane */ }
        return;
      }
      if (t === T_PING) {
        const ts = dv.getFloat64(1);
        const msg = new ArrayBuffer(17);
        const rdv = new DataView(msg);
        rdv.setUint8(0, T_PONG);
        rdv.setFloat64(1, ts);
        rdv.setFloat64(9, now());
        try { a.dc.send(msg); } catch { /* ignore */ }
        return;
      }
      if (t === T_PONG) {
        const ts = dv.getFloat64(1);
        const b = dv.getFloat64(9);
        const nowMs = now();
        a.rttMs = +(nowMs - ts).toFixed(2);
        // When the pong last came back. A lane can be OPEN, empty-buffered and
        // completely dead: unreliable SCTP never waits for an ack, so a
        // blackholed route looks perfectly healthy from the send side, and skew
        // cannot see it either because skew is computed only from frames that
        // ARRIVE — a lane delivering nothing emits no signal at all. The pong is
        // the one thing that stops coming back. Measured cost of not using it:
        // with three of six routes blackholed, striping concealed 2.6x the
        // control (1168 vs 452 ms over 25 s, n=3) by concentrating audio into
        // lanes it believed were fast.
        a.lastPongT = nowMs;
        // Running minimum — the path's floor. Queueing inflates the latest
        // sample; only the floor is safe to budget in-flight bytes against.
        if (a.baseRttMs == null || a.rttMs < a.baseRttMs) a.baseRttMs = a.rttMs;
        // Same symmetric-path caveat as lane 1's ctl ping: an offset estimate,
        // reported as such, not ground truth.
        a.clockOffsetMs = +(b - (ts + (nowMs - ts) / 2)).toFixed(2);
        // The aggregate view reports association 0 (at pairs=1 it is the only
        // one — same numbers as before striping existed).
        if (a === assocs[0]) {
          stats.rttMs = a.rttMs;
          stats.baseRttMs = a.baseRttMs;
          stats.clockOffsetMs = a.clockOffsetMs;
        }
        return;
      }
      if (t === T_ANCH) {
        // Later anchors win; an out-of-order one must not drag the reference
        // backwards, since extrapolation is signed and would then read the future.
        const s = dv.getUint32(1);
        if (s > anchSeq) { anchSeq = s; anchWall = dv.getFloat64(5); anchUs = dv.getFloat64(13); }
        return;
      }
      if (t === T_DATA || t === T_DATA_C || t === T_DATA_Z) {
        diagRecv?.hit(performance.now());
        const zipped = t === T_DATA_Z;
        const compact = zipped || t === T_DATA_C;
        const hdr = compact ? HDR_DATA_C : HDR;
        const seq = compact ? dv.getUint32(1) : dv.getUint32(4);
        // Both timestamps come from the anchor under compact framing. capUs is
        // exact (8000 µs/seq by construction); wall becomes the frame's ideal
        // capture instant rather than its send instant, which is what ageMs
        // should have been measuring. With no anchor yet, capUs 0 lets capUsFor
        // fall back exactly as it does for an FEC-repaired frame.
        const wall = compact
          ? (anchSeq >= 0 ? anchWall + (seq - anchSeq) * 8 : NaN)
          : dv.getFloat64(8);
        const capUs = compact
          ? (anchSeq >= 0 && anchUs > 0 ? anchUs + (seq - anchSeq) * 8000 : 0)
          : (data.byteLength >= HDR ? dv.getFloat64(16) : 0);
        stats.framesRecv++;
        a.framesRecv++;
        stats.bytesRecv += data.byteLength;
        a.bytesRecv += data.byteLength;
        if (a.clockOffsetMs != null && Number.isFinite(wall)) {
          // Peer wall clock is only comparable to ours through the ping offset —
          // same symmetric-path caveat as lane 1's age. NaN before the first
          // anchor: a sample with no shared zero point is not a latency, and
          // pushing one poisons the percentile for the rest of the call.
          stats.ageMs.push(+(now() - wall - a.clockOffsetMs).toFixed(1));
          if (stats.ageMs.length > 900) stats.ageMs.shift();
        }
        const payload = new Uint8Array(data, hdr);
        // A seq already marked seen is a shield twin whose original made it (or the
        // reverse) — counted so telemetry can say how much of the dup spend was
        // redundant vs. how much silently replaced a loss.
        if (seq <= seenHi && seenHi - seq < SEEN_N && seen[seq % SEEN_N] === 1) stats.dupRecv++;
        noteSeen(seq);
        // Skew is MEASURED unconditionally — the fleet needs to know how much
        // real-world route divergence exists — but APPLIED only behind the flag.
        // Measured (deskew-divergence rig, 24/12/24 ms offsets, heavy tail):
        // estimator de-skew cannot make slow-lane frames arrive earlier, so the
        // shallower ring it buys (27.6 ms) is paid for in concealment (+1 s/min).
        // Buffering for the slowest lane is the price of playing its frames;
        // the real win needs skew-aware striping or FEC-side recovery first.
        const laneIdx = (typeof ai === 'number' && ai >= 0 && ai < PAIRS) ? ai : 0;
        const skewMs = laneSkewNow(laneIdx, seq);
        ringWrite(seq, payload, capUs, zipped, DESKEW ? skewMs : 0, laneIdx);
        // The window decoder runs UNCONDITIONALLY (the flag is the sender's):
        // whether the peer protects its stream with RS or the window is its
        // choice, and this side must be able to decode either. frame() keeps a
        // view into this message's own buffer — no copy — and repair() early-
        // exits (after evicting) when no parity implicates a missing frame, so
        // against an RS peer this costs a map insert and an eviction sweep.
        swZip = zipped;
        swDec.frame(seq, payload);
        swRepairTry();
        if (cfg.fec) {
          const g = getGroup(seq - (seq % RS_K));
          const pos = seq % RS_K;
          // Per GROUP, not per module: a repaired frame carries no wire type, so
          // the only honest record of how to read it is what its own group's
          // members looked like. A global flag would decode the first group of a
          // call wrongly if the peer's setting differed from ours.
          if (zipped) g.zip = true;
          // Kept at its NATURAL length. The group's symbol length is the longest
          // frame in it, which is not knowable when the first frames arrive — so
          // the padding happens in maybeResolve(), where the parity's own length
          // has told us what it is.
          if (!g.resolved && !g.expired && !g.data[pos]) g.data[pos] = payload.slice(0);
          maybeResolve(g, seq - (seq % RS_K));
          expireGroups();
        }
        return;
      }
      if (t === T_PAR_SW) {
        stats.parityRecv++;
        a.parityRecv++;
        // s arrives mod 256 and is used as-is: coeff() reads it mod 128 and two
        // live parities can never be 128 apart (see the wire-format comment).
        swDec.parity({
          s: dv.getUint8(1),
          bitmap: dv.getUint16(2),
          end: dv.getUint32(4),
          sym: new Uint8Array(data, HDR_PAR_SW),
        });
        swRepairTry();
        return;
      }
      if (t === T_PARITY || t === T_PAR_C) {
        const hdr = t === T_PAR_C ? HDR_PAR_C : HDR;
        const idx = dv.getUint8(1);
        const bitmap = dv.getUint16(2);
        const base = dv.getUint32(4);
        stats.parityRecv++;
        a.parityRecv++;
        if (!cfg.fec) return;
        const g = getGroup(base);
        // Parity arriving for an already-complete (or already-repaired) group
        // is the normal paced-parity tail, not waste worth alarming about — but
        // count it, because a healthy lossless run should show exactly 2×groups.
        if (g.resolved || g.expired) { stats.parityUnused++; return; }
        g.bitmap |= bitmap;
        if (!g.par[idx]) {
          g.par[idx] = new Uint8Array(data, hdr).slice(0);
          g.nPar++;
        } else {
          stats.parityUnused++;
        }
        maybeResolve(g, base);
        return;
      }
    }

    // ── Jitter target ─────────────────────────────────────────────────────────
    // Measured (default) or the legacy pain counter (`?pcmjit=0`).
    //
    // WHY THIS WAS REPLACED. The old law grew the target by one frame per
    // CONCEALMENT and shrank it by one frame per 4 s. Measured on production at
    // 5% loss (testbed/fatigue.mjs): the target went 2 → 15 frames in about five
    // seconds and took ~55 s to come back — growth ~24 ms/s against decay 2 ms/s,
    // a 12:1 ratchet — and the turn-gap proxy PEAKED TEN SECONDS AFTER the
    // network had already healed. That is the Schoenenberg failure mode exactly:
    // nothing looks broken, the other person just seems slow.
    //
    // The deeper error is conceptual. A concealment has two causes and buffering
    // only cures one. A frame that arrived LATE says "you needed this many more
    // ms"; a frame that was LOST says nothing at all about buffer size — no
    // amount of waiting produces a packet that is not coming. In the same run
    // roughly half of each were mixed together, so half the latency the old law
    // added was pure cost with no benefit available to it.
    //
    // What a jitter buffer actually needs to cover is the SPREAD OF ARRIVAL
    // TIMES, which is directly measurable and needs no clock sync: for each frame
    // that becomes available, d = now() - seq*8ms, and the buffer must cover
    // p99(d) - min(d) over a recent window. Losses contribute no sample and so
    // cannot inflate it. FEC repairs DO contribute, at their repair time, which is
    // correct — waiting out an 80 ms RS span is a real reason to hold audio.
    //
    // It also decays for free: a quiet window simply stops containing the big
    // values. No hand-tuned shrink rate, and no ratchet, because rise and fall are
    // the same estimator read at different times.
    const JITTER_MEASURED = cfg.jitterMeasured !== false;
    // Opt-IN (=== true), unlike the flags around it: applying the correction was
    // measured harmful on divergent routes (see the frame-path comment), so an
    // embedder that says nothing gets the safe behavior. Skew is still measured
    // and reported either way.
    const DESKEW = cfg.deskew === true;
    // Gated default ON: telemetry weight (8 bytes / 250 ms) for per-lane skew
    // feedback from receiver back to sender (lane-skew Stage 1).
    const SKEWFB = cfg.skewfb !== false;
    // Opt-IN (=== true): Skew-aware striping (lane-skew Stage 2). Sender demotes
    // slow lanes based on skew feedback.
    const SKEWSTRIPE = cfg.skewStripe === true;
    // The late-fraction signal is always MEASURED and always REPORTED; this
    // gates only whether it may demote a lane. See cfg.lateDemote in app.js.
    const LATE_DEMOTE = cfg.lateDemote === true;
    // Window length is a tradeoff against SENDER CLOCK DRIFT, not just noise. d is
    // measured against our own clock, so a drifting sender makes d ramp steadily,
    // and a ramp inside the window reads as spread that no buffer needs to cover.
    // driftPpm rails at the 0.2% clamp under stress, which over 5 s would be 10 ms
    // — a whole phantom frame of target. 320 frames (~2.6 s) holds that under
    // 5 ms, still puts ~16 repaired frames inside the window at 5% loss (so p99
    // sizes to cover an RS span, which is correct), and decays faster as a bonus.
    const D_WIN = 320;
    // Float64, NOT Float32, and this is load-bearing. d is now() - seq*8, which is
    // a wall-clock epoch value around 1.75e12. Float32 carries ~7 decimal digits
    // and its spacing up there is ~131072, so every sample rounds to the IDENTICAL
    // float and the spread comes out as exactly 0.0 — the estimator ran for a whole
    // deploy reporting p90/p99/max = 0/0/0, held the target at its floor, and
    // looked like the pleasing result "latency is flat under loss". It was blind.
    // Exactly 0 across 320 samples is the tell; the jit* stats exist so that tell
    // is visible from outside instead of needing a code change to find.
    const dRing = new Float64Array(D_WIN);
    const dSort = new Float64Array(D_WIN);
    let dN = 0, dI = 0;
    // Inter-arrival gap ring. Same window length as dRing so the two describe the same
    // 2.56 s and can be read against each other. Float64 for the same reason dRing is:
    // Float32 up at wall-clock magnitudes collapses every sample to one value, which
    // is how the estimator once reported a spread of exactly 0.0 for a whole deploy.
    const G_WIN = 320;
    const gRing = new Float64Array(G_WIN);
    let gN = 0, gI = 0, gLast = 0;
    // The estimator's own clock origin: first arrival, not first send. Used ONLY to
    // timestamp the spread extremes above, so a startup transient is separable from
    // a genuinely bursty link.
    let dT0 = 0;
    // Observability threshold, deliberately NOT a control-law input: anything the
    // law consumed would need the same measured justification as D_WIN and
    // JIT_RELEASE, and this ships before that evidence exists.
    const JIT_WARM = cfg.jitterWarmMs ?? 10000;
    // One frame of margin over the measured p99. Not tunable on purpose: the
    // estimator is supposed to be the answer, and a knob here is how a measured
    // control law quietly becomes a hand-tuned one again.
    const D_MARGIN_FRAMES = 1;
    const JIT_HOLD = cfg.jitterHold !== false;
    // 0.25 ms per 250 ms tick = 1 ms/s: a ~98 ms burst stays remembered for most
    // of a call. Was 2 (8 ms/s, chosen to match the output decay by reasoning
    // rather than measurement); that emptied the memory in 12 s while bursts
    // recur less often than that, and the target ended back at its 16 ms floor.
    // MEASURED n=8 at --bw=0.3: slow release is better on every mean and its
    // variance is significantly lower on five of six metrics -- p50 sd 15.1 ->
    // 3.8 ms (p=0.0017), p95 29.4 -> 7.2 (p=0.0014), delivered 3.6 -> 0.7 pp
    // (p=0.0003), lane rate (p=0.005), rig bwDropped (p=0.011).
    // The predicted latency COST did not appear -- p50 fell 69.3 -> 64.2 ms. A
    // buffer deep enough not to conceal also stops the extrapolator perturbing
    // the playout clock, so the depth pays for itself instead of being charged.
    // 2 = 8 ms of held spread released per 250 ms tick. The slow value (0.25 = 1 ms/s)
    // shipped while its only supporting evidence was an n=8 at --bw=0.3 — later shown to be
    // a null: under bandwidth shaping the target pins at maxTargetFrames and the clamp
    // discards the release term entirely, so that A/B compared two identical control laws.
    // Where the knob is CONNECTED, fast wins everything measured: post-stall excursion
    // 1.8-6x smaller, 8/8 paired calls at 5% loss (p=0.0346), and direction at 2.5 Mbps.
    const JIT_RELEASE = cfg.jitterRelease ?? 2;
    // Where the target saturates: ceil(spreadHold/FRAME_MS) + D_MARGIN_FRAMES
    // reaches maxTargetFrames here, so held spread above this is invisible to
    // the output and costs only recovery time. Derived, not a constant, so it
    // follows ?pcmjbmax instead of silently disagreeing with it.
    const HOLD_CEIL = Math.max(FRAME_MS, (cfg.maxTargetFrames - D_MARGIN_FRAMES) * FRAME_MS);
    const HOLD_CAP = cfg.holdCap !== false;
    let spreadHold = 0;
    // ── Elastic ceiling (`?pcmelastic=0` control) ─────────────────────────────
    // The ceiling above is a POLICY number (256 ms); the ring is a STRUCTURAL one
    // (512 ms). On tcu-eopa-dop (2026-08-16) a bursty 28 ms-RTT path put 53% of
    // frames behind the playhead while half the ring sat empty above the clamp —
    // the estimator asked, the ceiling refused, the user heard concealment. So
    // the ceiling itself now yields, but only on the governor's standard of
    // evidence: demand alone (spread says "grow") is not enough, because spread
    // can be a startup transient or one clump; the ceiling rises 8 frames per
    // 2 s ONLY while concealment/lateness is ACTIVELY advancing at the current
    // ceiling — i.e. the clamp is provably costing audio right now. It falls
    // back stepwise after 30 s of demand fitting under the configured max, so a
    // one-burst call is not taxed forever. Hard cap 48 of the ring's 64: the 16
    // frames (128 ms) above it are write headroom for early arrivals, and a
    // buffer past 384 ms is a latency defect to fix in the path, not to hide.
    // ── ARRIVALS THE BUFFER COULD NEVER HAVE CAUGHT (`?pcmjitfar=0`) ────────
    // The estimator is LANE-BLIND: noteArrival records (arrival - skew) minus
    // seq*FRAME_MS and never learns which of the six associations delivered it.
    // Under a 3-of-6 blackhole that is how a 5-SECOND-late frame ends up sizing
    // the buffer. `spread` rejects exactly one outlier (s[dN-2] - s[0]) and this
    // file's own comment says why that is not enough: a stall is a multi-sample
    // event, so second-largest "discards one anomalous ARRIVAL; it cannot
    // discard a hole". Measured jitSpreadMaxRun 1515 ms, ring 220 ms, m2e 310.
    //
    // THE BOUND IS NOT A TUNING KNOB, it is derived. The deepest this ring can
    // ever be is ELASTIC_MAX_F frames. A frame that arrives later than that
    // past the window's floor is unplayable AT ANY BUFFER DEPTH WE WOULD EVER
    // BUILD — so it cannot be "caught" by growing, and letting it set the
    // target buys nothing while costing the whole excursion, paid back at
    // JIT_RELEASE's 8 ms/s for ~20 s afterwards.
    //
    // It is inert on a healthy call by construction: clean-path spread is under
    // 10 ms against a 384 ms bound, so nothing is ever excluded and the sample
    // set is bit-identical. This is deliberately NOT the de-skew experiment
    // recorded at the ringWrite call site — that one moved ordinary 24 ms lane
    // offsets and paid for a 27.6 ms shallower ring with +1 s/min of
    // concealment. Frames 24 ms late are worth buffering for; frames 5 s late
    // are not, and the bound is what separates the two cases.
    const FAR_SKIP = cfg.jitterFarSkip !== false;
    let dFloor = null;        // window minimum, refreshed by the decay tick below
    let farRejected = 0;      // consecutive samples turned away
    const ELASTIC = cfg.jitterElastic !== false;
    const ELASTIC_MAX_F = 48;
    // DERIVED FROM THE GOAL, and the first version of this was derived from the
    // wrong thing. It was ELASTIC_MAX_F * FRAME_MS = 384 ms, on the argument
    // that a frame later than the deepest reachable target could never be
    // played. True about PLAYABILITY, irrelevant to the TARGET: `holdCeil`
    // already clamps spreadHold at (maxEff - D_MARGIN_FRAMES) * FRAME_MS —
    // 248 ms at the base maxTargetFrames of 32, 376 ms fully elastic — so a
    // bound of 384 sat ABOVE the clamp and discarded only what was already
    // being discarded. Measured exactly that way: the rule fired 100-180 times
    // per side and collapsed jitSpreadMaxRun from 1200-2536 ms to 114-375, and
    // the ring did not move, because 1500 ms and 370 ms of spread produce the
    // same clamped target.
    //
    // So the bound now comes from the 150 ms mouth-to-ear budget instead. The
    // fixed pipeline is measured, not guessed: outputMs 20 (the OS device
    // buffer, already at the API floor under latencyHint 0), frameMs 8,
    // netAgeP50 ~2 — about 30 ms before the ring gets anything. That leaves
    // ~120 ms of ring for a zero-propagation call, and less for a real one.
    // An arrival further past the window floor than that cannot be waited for
    // without spending the entire budget the project exists to defend.
    //
    // A LIVE KNOB (`?pcmjitfarms=`), because the honest value is a trade this
    // rig has to find rather than one this comment can assert: buffering less
    // means concealing frames that a deeper ring would have caught, and the
    // de-skew experiment at the ringWrite call site paid +1 s/min of
    // concealment for 27.6 ms of ring. Sweeping it without a redeploy is the
    // difference between measuring that curve and guessing a point on it.
    const FAR_BOUND_MS = Math.max(FRAME_MS * 2, cfg.jitterFarMs ?? 120);
    const ELASTIC_STEP_F = 8;
    let maxEff = cfg.maxTargetFrames;
    let elPainSeen = 0, elLastUp = 0, elCalmMs = 0;
    // ── Latency governor (task #47, `?pcmgov=` ) ──────────────────────────────
    // The estimator sizes the buffer from arrival SPREAD; the governor audits the
    // OUTCOME. Every accepted frame reports its slack (ringWrite above); the
    // rolling MINIMUM of that slack is depth the call has been carrying that
    // provably prevented nothing — every frame would have played from a buffer
    // that much shallower. Trim it, keep GOV_SAFETY_F frames in place, and hand
    // the depth back as mouth-to-ear latency.
    //
    // The floor is a TRUE ROLLING MINIMUM over the last GOV_WIN_TICKS (20 s),
    // not a held peak with a re-rise. Measured (2026-08-04, paired n=8 on real
    // Brave at 70 ms recurring stalls): the re-rise variant let the trim climb
    // back between stalls and bite just before the next one — +11 concealed
    // frames per call, 7/8 runs worse. A rolling min cannot do that: any dip in
    // the last 20 s IS the floor, so in a recurring-stall regime the governor
    // stands down entirely, and only depth that stayed free through the worst
    // recent dip is handed back. Pain (a late frame or a conceal) zeroes the
    // current tick's entry outright — a frame that missed is a slack of zero
    // however deep the buffer was.
    //
    // SAB path only: the port path's playhead is 1 Hz stale, and a governor fed
    // a stale playhead would be a watchdog that cannot see.
    const JIT_GOV = cfg.jitterGov === true && !!sab;
    const GOV_SAFETY_F = 2; // frames of measured slack never trimmed (16 ms)
    const GOV_WIN_TICKS = 80; // 20 s of 250 ms ticks the floor must survive
    const govRing = new Float64Array(GOV_WIN_TICKS).fill(Infinity);
    let govRingI = 0, govRingN = 0;
    let govTickMin = Infinity; // min slack seen since the last estimator tick
    let govPainSeen = 0; // late+conceal watermark; any advance zeroes this tick
    function noteArrival(seq, skewMs = 0, laneIdx = -1) {
      if (!dT0) dT0 = now();
      // ── inter-arrival GAPS, which answer a different question from spread ──
      // `spread` is (second-largest - min) of delay across the window: it says HOW
      // FAR apart the earliest and latest arrivals were, not what the arrival pattern
      // looked like. Two opposite mechanisms produce the same 189 ms spread:
      //   CLUMPING  - the sender batches, so frames land in bursts with ~0 ms between
      //               them and a long hole after. Fix: send pacing.
      //   STRETCHING - gaps are uniformly wider than the 8 ms nominal, i.e. a rate or
      //               clock problem. Fix: nothing to do with pacing.
      // A cross-engine call measures 157-189 ms spread against 45-56 same-engine, and
      // the control law must not be touched before knowing which of these it is (two
      // previous buffer tunings on this project made things worse). `gapClumpPct`
      // versus `gapP95` separates them: high clump AND high p95 is batching.
      const tn = now();
      if (gLast) {
        const gap = tn - gLast;
        gRing[gI] = gap;
        gI = (gI + 1) % G_WIN;
        if (gN < G_WIN) gN++;
        if (gap < 1) stats.gapClump++;
        stats.gapN++;
        if (gap > stats.gapMaxRun) stats.gapMaxRun = +gap.toFixed(1);
        // 3x nominal. Same-engine tops out at 1.6x p99 (~19 ms) so this never fires on
        // a clean lane; cross-engine holes are 75-87 ms so it catches all of them.
        // Capped at 128 and kept OLDEST-first: a run's first stalls are the ones whose
        // simultaneity is being tested, and dropping them to make room for later ones
        // would silently change what the comparison is about.
        if (gap > 3 * FRAME_MS && stats.stalls.length < 128) {
          stats.stalls.push({ t: Math.round(tn), g: +gap.toFixed(1) });
        }
      }
      gLast = tn;
      const d = (tn - skewMs) - seq * FRAME_MS;
      // The gap statistics above are recorded unconditionally — they answer a
      // different question (clumping vs stretching) and a rejected frame still
      // ARRIVED. Only the spread's sample set is gated.
      if (FAR_SKIP && dFloor != null && (d - dFloor) > FAR_BOUND_MS) {
        farRejected++;
        stats.jitFarSkipped++;
        if (laneIdx >= 0) stats.jitFarByLane[laneIdx]++;
        // UNLESS IT IS NOT AN OUTLIER ANY MORE. If the whole path steps later —
        // a route change, not one bad lane — every sample is beyond the floor
        // and rejecting them all would freeze the estimator on a floor that no
        // longer exists, which is the "acting on a signal erases the signal"
        // trap this codebase has already hit three times in one file. So a run
        // of rejections longer than a quarter of the window means the floor is
        // wrong, not the arrivals: drop it and re-learn from what is arriving.
        if (farRejected > (D_WIN >> 2)) { dFloor = null; farRejected = 0; stats.jitFarRelearn++; }
        return;
      }
      farRejected = 0;
      dRing[dI] = d;
      dI = (dI + 1) % D_WIN;
      if (dN < D_WIN) dN++;
    }

    let target = cfg.targetFrames;
    let lastPain = 0;
    function bumpTarget() {
      if (JITTER_MEASURED) { stats.painEvents++; return; } // the estimator owns the target
      // Counted separately from `bumps` because a call that finds the target already
      // at its ceiling returns without touching lastPain — so pain at the cap and
      // pain below it have opposite effects on how fast the target can decay, and
      // one counter cannot tell you which you are looking at.
      stats.painEvents++;
      if (target >= cfg.maxTargetFrames) return;
      setTarget(target + 1);
      lastPain = now();
    }
    function setTarget(n) {
      if (n === target) return;
      if (n > target) stats.bumps++; else stats.decays++;
      target = n;
      if (sab) Atomics.store(ctl, SAB_TARGET, target);
      else playNode?.port.postMessage({ type: 'target', n: target });
    }

    let lastDrop = 0;
    const decayTimer = setInterval(() => {
      if (closed) return;
      if (!JITTER_MEASURED) {
        // Legacy arm (`?pcmjit=0`). §12's shrink bound is ≤2 ms/s and this is
        // exactly it: one 8 ms frame per 4 s. Kept as the control the measured
        // law is compared against, not as a fallback anyone should choose.
        if (target > cfg.targetFrames && now() - lastPain > 4000) { setTarget(target - 1); lastPain = now(); }
        return;
      }
      // Need a full window before trusting a p99 — early in a call the sample is
      // both small and unrepresentative (ICE is still settling), and a target set
      // from it would be a guess wearing a measurement's clothes.
      if (dN < 64) return;
      dSort.set(dRing.subarray(0, dN));
      const s = dSort.subarray(0, dN).sort();
      // SECOND-LARGEST, not p99. p99 lets the top 1% of arrivals be late, and on a
      // clean path that measured 0.2% concealment where the old law reached 0.0% —
      // trading a headline claim ("lossless by default") for a win that only
      // applies to lossy paths. The guarantee we actually want is "no concealment
      // the buffer could have prevented", which is the window's MAX. Second-largest
      // rather than max so one pathological arrival cannot pin the buffer for a
      // whole window; in effect, at most one frame in 320 may be late.
      const spread = s[Math.max(0, dN - 2)] - s[0];
      // The floor the next interval's arrivals are judged against. Taken here
      // because this tick already paid for the sort; recomputing it per frame
      // would put an O(n log n) on the receive path to save nothing.
      dFloor = s[0];
      // RAW is what the estimator actually asked for; `want` is what the ceiling
      // allowed. Keeping the raw run-max is the only way to know the ceiling ever
      // bound: `jitWant` is a snapshot of the trailing window, so on a run whose
      // bursts demanded 23-41 frames it reported want == target == 2 from the
      // quiet tail, and the cap looked like it was never reached.
      // ── Peak-hold on the INPUT (`?pcmjithold=0` to disable) ─────────────────
      // The window is 2.56 s. Between bursts it goes quiet, `spread` collapses,
      // and the target falls back to ~3 frames -- then the next ~98 ms burst
      // lands 74 ms outside a 24 ms buffer. Measured: spread tracks the shaper's
      // queue depth exactly (96.3 vs 98.4 ms), so the burst size is known, and it
      // is only ever forgotten because the window rolled.
      //
      // A burst 8 s ago is evidence about the next 8 s: on a shaped link they
      // recur far faster than the 10 s it takes the target to decay 13 -> 3
      // frames. So hold the peak and release it slowly, the standard audio
      // limiter shape. Held on the INPUT rather than the output on purpose --
      // the existing 1 frame/s output decay stays exactly as it is, and this
      // makes the estimator's memory an explicit number instead of an accident
      // of how long D_WIN happens to be.
      //
      // SHIPPED RELEASE IS 2 ms/tick = 8 ms/s (JIT_RELEASE below, `?pcmjitrel=`
      // to override). This comment has now been wrong in BOTH directions: it once
      // said 8 ms/s while 0.25 shipped, was corrected, and then went stale again
      // when the constant moved back to 2 on 2026-08-03 -- so the numbers below,
      // taken under the 0.25 law, describe a decay 8x slower than anything that
      // ships today. They are kept because the SHAPE of the failure is what
      // matters and it is unchanged; only the timescale is now ~8x shorter. The
      // lesson is that a measured constant and the prose describing it drift
      // apart silently, which is why the ceiling below is derived rather than
      // written down.
      //
      // MEASURED COST OF THAT MEMORY (testbed/onehole.mjs, clean same-engine call,
      // one 99.9 ms arrival hole injected by blocking the receiver's main thread):
      //   target snapped 2f -> 12f immediately; depth ramped in over 30 s to a peak
      //   of 68.7 ms against a 14.7 ms baseline; target returned at t+80 s, depth by
      //   ~t+94 s. So ONE hiccup costs ~54 ms of added audio latency, arriving half a
      //   minute after the event and lasting a minute and a half. Predicted ~100 s
      //   from the release rate alone; measured 80 s, so the mechanism is understood.
      //
      // Note the outlier rejection above does NOT protect against this. A stall is
      // inherently a multi-sample event: no packets are dispatched, then the backlog
      // arrives in a clump, and since D = arrival - seq*FRAME_MS every frame in that
      // clump gets its own elevated D. Second-largest discards one anomalous ARRIVAL;
      // it cannot discard a hole.
      //
      // Release per 250 ms tick. Bursts on a shaped link are rare and brief
      // (bwQueue p95 5.6 ms against a max of 97.6), which is the argument for
      // holding the peak at all; how long to hold it is the open question.
      // CEILING. Above the hold ceiling the target is already pinned at
      // the max — `ceil(spreadHold/FRAME_MS) + D_MARGIN_FRAMES` has
      // saturated — so every further millisecond of hold is memory the
      // estimator CANNOT ACT ON, and can only pay back at JIT_RELEASE on the
      // way down. That makes recovery time proportional to the size of the
      // event rather than to the buffer: a 1.3 s stall (measured in this
      // project's own rigs, twice) holds the buffer at maximum depth for
      // ~165 s, and a 9.6 s shaped-link opening for about twenty minutes,
      // both producing the exact same 15-frame target as a 112 ms excursion.
      //
      // The clamp is bit-identical on every tick where the unclamped hold is
      // >= the ceiling, because both sides saturate to the same target. It
      // cannot change the RESPONSE to an event, only when the estimator stops
      // responding to one that is over: any excursion now decays in <= 14 s.
      // Raw magnitude is still observable — jitSpreadMaxRun records unclamped
      // `spread`, which is what a stall's size should be read from anyway.
      //
      // The elastic ceiling moves BEFORE the clamps read it, and its trigger is
      // the UNCLAMPED spread — spreadHold is capped at the ceiling, so a demand
      // read from it can never exceed the ceiling it is asking to raise.
      if (ELASTIC) {
        const demandF = Math.ceil(spread / FRAME_MS) + D_MARGIN_FRAMES;
        const elPain = stats.late + (wl.lateFrames ?? 0) + (wl.concealedFrames ?? 0);
        const painAdvanced = elPain > elPainSeen;
        elPainSeen = elPain;
        const tn = now();
        if (demandF > maxEff && painAdvanced && maxEff < ELASTIC_MAX_F && tn - elLastUp >= 2000) {
          maxEff = Math.min(ELASTIC_MAX_F, maxEff + ELASTIC_STEP_F);
          elLastUp = tn;
          stats.elUps++;
          stats.elMaxRun = Math.max(stats.elMaxRun, maxEff);
        } else if (maxEff > cfg.maxTargetFrames) {
          if (demandF <= cfg.maxTargetFrames && !painAdvanced) {
            elCalmMs += 250;
            if (elCalmMs >= 30000) { maxEff -= ELASTIC_STEP_F; elCalmMs = 0; }
          } else elCalmMs = 0;
        }
        stats.elMax = maxEff;
      }
      const holdCeil = ELASTIC
        ? Math.max(FRAME_MS, (maxEff - D_MARGIN_FRAMES) * FRAME_MS)
        : HOLD_CEIL;
      if (JIT_HOLD) {
        spreadHold = Math.max(spread, spreadHold - JIT_RELEASE);
        if (HOLD_CAP && spreadHold > holdCeil) spreadHold = holdCeil;
        if (spreadHold > stats.jitHoldMaxRun) stats.jitHoldMaxRun = +spreadHold.toFixed(1);
      } else spreadHold = spread;
      const raw = Math.max(cfg.targetFrames, Math.ceil(spreadHold / FRAME_MS) + D_MARGIN_FRAMES);
      const want = Math.min(maxEff, raw);
      if (raw > stats.jitWantMaxRun) stats.jitWantMaxRun = raw;
      if (raw > cfg.maxTargetFrames) stats.jitClampedTicks++;
      // Published so the estimator can be audited from outside. A control law whose
      // input is invisible can only be debugged by changing it and re-running,
      // which is how a plausible-but-wrong mechanism survives three sessions.
      // Run-scoped, not window-scoped. Everything else here describes the LAST
      // 320 frames (2.56 s), which on a 35 s run is the quiet tail: a run that
      // concealed 70 frames to queue bursts reported `max 6.5 ms` because every
      // burst had already rolled out of the window. A snapshot of a decaying
      // control law cannot tell you what it reacted to, so keep the extremes and
      // keep the time spent above the floor -- that last one is the LATENCY COST
      // of the reaction, which is the half of the tradeoff nothing else records.
      // Timestamped extremes. `jitSpreadMaxRun` on its own says the buffer was sized
      // by a 314 ms event but not WHEN, and the two answers ("the link is bursty" vs
      // "ICE/DTLS/SCTP setup was") have opposite fixes. Recorded, never consumed.
      const sinceT0 = dT0 ? now() - dT0 : 0;
      if (spread > stats.jitSpreadMaxRun) {
        stats.jitSpreadMaxRun = +spread.toFixed(1);
        stats.jitSpreadMaxAtMs = Math.round(sinceT0);
      }
      if (sinceT0 >= JIT_WARM && spread > stats.jitSpreadMaxLate) {
        stats.jitSpreadMaxLate = +spread.toFixed(1);
        stats.jitSpreadMaxLateAtMs = Math.round(sinceT0);
      }
      if (target > cfg.targetFrames) stats.jitAboveFloorMs += 250;
      stats.jitSpreadMs = +spread.toFixed(1);
      stats.jitP99Ms = +(s[Math.min(dN - 1, Math.floor(0.99 * dN))] - s[0]).toFixed(1);
      stats.jitP90Ms = +(s[Math.floor(0.90 * dN)] - s[0]).toFixed(1);
      stats.jitMaxMs = +(s[dN - 1] - s[0]).toFixed(1);
      stats.jitWant = want;
      stats.jitN = dN;
      // ── Governor: subtract the measured-free depth from `want` ──────────────
      // `eff` is `want` minus the trim; on a clean shallow call the slack floor
      // sits near the target itself so the trim is ~0 and nothing changes. Pain
      // pops the floor to zero FIRST, so the same tick that saw a conceal already
      // restores the untrimmed target ("UP immediately" applies to the pop too).
      let eff = want;
      if (JIT_GOV) {
        const pain = stats.late + (wl.lateFrames ?? 0) + (wl.concealedFrames ?? 0);
        let entry = govTickMin; // Infinity when nothing arrived this tick: no evidence, no entry
        if (pain > govPainSeen) {
          govPainSeen = pain;
          entry = 0; // something missed — this tick's slack is zero by definition
          stats.govPops++;
        }
        govTickMin = Infinity;
        if (entry < Infinity) {
          govRing[govRingI] = entry;
          govRingI = (govRingI + 1) % GOV_WIN_TICKS;
          if (govRingN < GOV_WIN_TICKS) govRingN++;
        }
        // Trim only once a FULL window of evidence exists: a young window's min
        // is an optimist, and the cost of waiting 20 s is nothing against the
        // cost of a trim that a longer memory would have refused.
        if (govRingN === GOV_WIN_TICKS) {
          let floor = Infinity;
          for (let i = 0; i < GOV_WIN_TICKS; i++) if (govRing[i] < floor) floor = govRing[i];
          const trim = Math.max(0, Math.floor(floor) - GOV_SAFETY_F);
          eff = Math.max(cfg.targetFrames, want - trim);
          stats.govTrim = want - eff; // the trim that ACTUALLY bound, not the ask
          stats.govFloor = floor === Infinity ? null : +floor.toFixed(1);
          if (stats.govTrim > 0) stats.govTrimTicks++;
          if (stats.govTrim > stats.govTrimMaxRun) stats.govTrimMaxRun = stats.govTrim;
        }
      }
      // UP immediately: the evidence that more buffer is needed has already cost
      // someone a dropout, and hesitating costs another.
      if (eff > target) { setTarget(eff); return; }
      // DOWN at one frame per second — 8 ms/s, four times the old rate but still
      // bounded. The bound is not about audibility (the worklet's drift clamp owns
      // that, and it can drain 100 ms in ~5 s) but about not chasing a p99 that
      // dips for one window and comes back.
      if (eff < target && now() - lastDrop > 1000) { setTarget(target - 1); lastDrop = now(); }
    }, 250);

    // ── This peer's playout node ────────────────────────────────────────────
    // Built by the capture half the moment the shared context and the worklet
    // module exist, in exactly the position the graph IIFE built it before: on
    // the same context, after the capture node, before the graph is logged. A
    // half created later (`addPeer`) calls this itself. Two playout nodes both
    // `connect(ctx.destination)` and the Web Audio graph sums them there — no
    // mixer, no gain staging, and each peer keeps its own concealment, drift,
    // playhead and presence render.
    function attachGraph() {
      if (!ctx || playNode) return;
      playNode = new AudioWorkletNode(ctx, 'pcm-playout', {
        numberOfInputs: 0,
        numberOfOutputs: 1,
        // ?presence=1 renders a stereo room image (presence-core.js) — two
        // device channels. Off-arm keeps the original mono node untouched.
        outputChannelCount: [cfg.presence ? 2 : 1],
        processorOptions: {
          sab: sab ?? undefined,
          targetFrames: cfg.targetFrames,
          driftPpm: cfg.driftPpm,
          buildFast: cfg.jitterBuildFast !== false,
          aecSab: aecSab ?? undefined,
          presence: cfg.presence ? true : undefined,
          // Spatial placement: the FIRST voice is always centered (0 — the
          // presence render loop is then bit-identical to the pre-placement
          // build, so 1:1 is untouched). A later half (addPeer) sits to the
          // right; ?spatial=0 pins every voice to center.
          azimuthDeg: azimuthDeg || undefined,
        },
      });
      playNode.port.onmessage = (e) => {
        const m = e.data;
        if (!m || typeof m.type !== 'string') return;
        if (m.type === 'pcm-stats') {
          Object.assign(wl, m, { type: undefined });
          wl.playSeq = m.playSeq;
          return;
        }
        if (m.type === 'pcm-playhead') {
          // Port-mode playhead publish (throttled ~50 ms by the worklet) —
          // the A-V sync probe reads this where SAB mode reads the seqlocked
          // pair, so port mode's sync target is that much staler.
          wl.playheadUs = m.apUs;
          wl.playheadSeq = m.seq;
          return;
        }
        if (m.type === 'pcm-conceal') {
          bumpTarget();
          try { onConceal?.(1); } catch { /* stamping must never break the lane */ }
          return;
        }
        // Anything else is a detector event — hand it to the app's remote
        // detector stream exactly as onset-monitor.js would have.
        try { onEvent?.(m); } catch { /* detector plumbing must never break the lane */ }
      };
      playNode.connect(ctx.destination);
      for (const f of pendingPort.splice(0)) playNode.port.postMessage({ type: 'frame', seq: f.seq, samples: f.samples, capUs: f.capUs }, [f.samples.buffer]);
    }

    return {
      stats,
      mode,
      offerFrame,
      attachGraph,
      // The one-word answer to "how bad is my network right now", for consumers
      // that must react faster than their own signals allow (the video lane's GCC
      // estimate froze solid on the Aug 7 call while this lane's ladder read the
      // loss within 250 ms). 2 = burst shield engaged (loss beyond the ladder's
      // top rung); 1 = loss in the ladder's upper half; 0 = fine. Reads live
      // state, never computes — safe at any call rate.
      duress() {
        // Latched, not instantaneous. The raw read flapped in the wild
        // (room xow-offc-apz, 2026-08-11: 35 level transitions in 219 s on a
        // marginal link — loss windows breathing around cap/2 whipsawed the
        // video budget 2↔8 Mbps at up to 1 Hz, encoder-configure churn of
        // exactly the class the VBR lesson forbids). Same asymmetry as the
        // shield and the ladder: RISE instantly — under-reacting to real
        // trouble costs speech-adjacent video — but FALL only after the raw
        // read has held lower for a continuous 4 s. A marginal link now sits
        // at its worst recent level instead of strobing through all three.
        const cap = rungTop[Math.min(FEC_N_MAX, rungTop.length - 1)];
        const raw = stats.dupOn ? 2
          : (stats.peerLossPct > cap / 2 || stats.peerLossFastPct > cap) ? 1 : 0;
        if (raw >= dLevel) { dLevel = raw; dLowSince = 0; return dLevel; }
        const t = now();
        if (!dLowSince) dLowSince = t;
        else if (t - dLowSince > 4000) { dLevel = raw; dLowSince = 0; }
        return dLevel;
      },
      // Lane 0 (§3.1 levers 3+4): policy lives in app.js (it owns the detector
      // state these decisions gate on); the wire mechanics live here.
      sendTurnEnd,
      sendPad,
      // idx = association index: 0 is the main pc's 'pcm-audio' channel, 1..N-1
      // are the stripe pcs' channels (app.js `?pcmpairs=`). At pairs=1 only idx 0
      // ever attaches and everything behaves exactly as before.
      attachChannel(channel, idx = 0) {
        const a = assocs[idx] ?? assocs[0];
        if (a.dc) return;
        a.dc = channel;
        channel.binaryType = 'arraybuffer';
        channel.onmessage = (e) => { try { onMessage(e.data, idx); } catch { /* one bad datagram is not a call-ending event */ } };
        channel.onopen = () => {
          L('pcm-dc-open', PAIRS > 1 ? { mode, assoc: idx, pairs: PAIRS } : { mode });
          if (!pinger) pinger = setInterval(sendPing, PING_MS);
          // 250 ms, not the ping's 2 s: 2 s of under-protection after a burst
          // begins is 250 frames of audio, and the whole point of the ladder is
          // to have the parity already in flight when the loss arrives.
          if (!lossTimer) {
            lossTimer = setInterval(() => {
              sendLossReport();
              sendSkewReport();
              if (SKEWSTRIPE) recomputeLaneOrder();
            }, 250);
          }
          sendPing();
        };
        channel.onerror = (e) => L('pcm-dc-error', { assoc: idx, e: String(e?.error || e).slice(0, 120) });
      },
      // Where the remote audio's playhead is, in the SENDER's audio clock (µs):
      // the "audio_playout_time" the video presentation loop syncs to. Null
      // until playout starts (no master clock yet — video paints on arrival
      // until then, exactly as before). Includes the render-side outputLatency
      // so the target can be taken at the ear, not the ring.
      playheadInfo() {
        if (sab) {
          // Seqlocked read of the worklet's per-block publish.
          for (let tries = 0; tries < 4; tries++) {
            const l1 = Atomics.load(ctl, SAB_LOCK);
            if (l1 & 1) continue;
            const us = pub[0];
            const seq = pub[1];
            if (Atomics.load(ctl, SAB_LOCK) !== l1) continue;
            if (seq < 0) return null; // playout not started
            return { us, seq, outLatUs: (ctx?.outputLatency ?? 0) * 1e6 };
          }
          return null; // publish in flight — caller holds this vsync
        }
        if (wl.playheadSeq == null || wl.playheadSeq < 0) return null;
        return { us: wl.playheadUs, seq: wl.playheadSeq, outLatUs: (ctx?.outputLatency ?? 0) * 1e6 };
      },
      snapshot() {
        // Fold the capture half's counters in HERE, where they are read, not on
        // every frame where they are written. See capStats above for why.
        Object.assign(stats, capStats);
        const pct = (arr, p) => {
          if (!arr.length) return null;
          const s = [...arr].sort((x, y) => x - y);
          return +s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))].toFixed(1);
        };
        const elapsed = stats.t0 ? (now() - stats.t0) / 1000 : 0;
        return {
          ...stats,
          ageMs: undefined,
          ageP50: pct(stats.ageMs, 50), ageP95: pct(stats.ageMs, 95),
          mode, capMode: capSab ? 'sab' : 'port', fec: cfg.fec,
          // Stage cadence diagnostics (?pcmdiag=1, task #37): inter-event
          // intervals at capture, departure and arrival — null when off.
          diag: DIAG ? { cap: diagCap.stats(), send: diagSend.stats(), recv: diagRecv.stats() } : undefined,
          mbpsSent: elapsed > 1 ? +((stats.bytesSent * 8) / elapsed / 1e6).toFixed(2) : null,
          // The wire size of one data frame, reported rather than assumed. The
          // single-datagram budget is a byte count, so the one number that says
          // whether we are inside it has to come off the sender's own counters —
          // "compact framing is deployed" is not the same claim as "the frames on
          // this call are 1157 B".
          bPerFrame: stats.framesSent
            ? Math.round((stats.bytesSent - stats.parityBytes) / stats.framesSent) : null,
          bPerParity: stats.paritySent ? Math.round(stats.parityBytes / stats.paritySent) : null,
          rsOversize: stats.rsOversize,
          // Mean wasted-bits shift over the call, and the share of frames where it
          // reached 8. 8.0 / 100% says this device's audio is 16-bit content in a
          // 24-bit container and the lane is half the size it used to be; 0.0 / 0%
          // says the low bits carry something and the codec correctly left them
          // alone. Anything in between is a chain that changes mid-call.
          wastedShift: stats.zipFrames ? +(stats.shiftSum / stats.zipFrames).toFixed(2) : null,
          shift8Pct: stats.zipFrames ? +((100 * stats.shift8) / stats.zipFrames).toFixed(1) : null,
          // Share of probed frames where EVERY sample fits 16-bit content under
          // that scale factor. fit32767 high means the low bits are arithmetic
          // residue and the lane is still carrying only 16 bits of information.
          fit32767Pct: stats.probeFrames ? +((100 * stats.fit32767) / stats.probeFrames).toFixed(1) : null,
          fit32768Pct: stats.probeFrames ? +((100 * stats.fit32768) / stats.probeFrames).toFixed(1) : null,
          // The PEER's capture depth, read off audio we received. rxWastedShift 8
          // means the far end's chain IS bit-transparent and its lane could halve.
          rxWastedShift: stats.rxProbeFrames ? +(stats.rxShiftSum / stats.rxProbeFrames).toFixed(2) : null,
          rxShift8Pct: stats.rxProbeFrames ? +((100 * stats.rxShift8) / stats.rxProbeFrames).toFixed(1) : null,
          rxFit32767Pct: stats.rxProbeFrames ? +((100 * stats.rxFit32767) / stats.rxProbeFrames).toFixed(1) : null,
          // The code rate actually in force right now, and the redundancy it
          // implies. A run that reports fecN 3 throughout on a clean link means
          // the ladder never engaged — read this before believing any byte count.
          fecN, fecAdapt: FEC_ADAPT, fecRedundancyPct: Math.round((100 * fecN) / RS_K),
          rsK: RS_K, rsSpanMs: RS_K * FRAME_MS,
          // Which parity code THIS sender is emitting, and the window's live
          // stride. swFec 0 with swStride null = block RS (today's default).
          swFec: SW ? 1 : 0, swStride: SW ? swEnc.stride() : null,
          latePctEma: +latePctEma.toFixed(2), fecLate: FEC_LATE,
          fecRungTop: rungTop.map((v) => +v.toFixed(2)),
          // ── THE PRE-PLAYOUT RING, WHICH USED TO FAIL INVISIBLY ──────────────────
          // `farFuture` counts frames the writer refused because they sat beyond the
          // ring's 512 ms window. It has always been COUNTED and was never PUBLISHED,
          // so the failure it describes — a slow audio graph costing every remaining
          // second of the call's audio — could only be found by reading the source.
          // A counter that exists but cannot be read is not observability.
          // `ringReseeds` > 0 means the graph took over ~512 ms to come up and the ring
          // correctly re-anchored; frames discarded by that is reseeds x 64.
          // `portDropped` is the same class of silence on the non-SAB path.
          farFuture: stats.farFuture, ringReseeds: stats.ringReseeds, portDropped: stats.portDropped,
          jitSpreadMaxRun: stats.jitSpreadMaxRun, jitAboveFloorMs: stats.jitAboveFloorMs,
          jitFarSkipped: stats.jitFarSkipped, jitFarRelearn: stats.jitFarRelearn,
          jitFarByLane: [...stats.jitFarByLane],
          jitWantMaxRun: stats.jitWantMaxRun, jitClampedTicks: stats.jitClampedTicks,
          jitHoldMaxRun: stats.jitHoldMaxRun, jitHold: JIT_HOLD, jitRelease: JIT_RELEASE,
          holdCap: HOLD_CAP ? HOLD_CEIL : 0,
          // Read these TOGETHER with jitSpreadMaxRun. maxAt near 0 with maxLate far
          // below the max means a startup transient sized the whole call's buffer.
          // Arrival PATTERN, which spread cannot express. Read gapClumpPct together
          // with gapP95: both high means the sender batches (fix pacing); low clump
          // with high p95 means gaps are uniformly stretched (not a pacing problem).
          ...(() => {
            if (gN < 8) return { gapP50: null, gapP95: null, gapP99: null, gapClumpPct: null, gapMaxRun: stats.gapMaxRun };
            const g = Array.from(gRing.subarray(0, gN)).sort((a, b) => a - b);
            const q = (f) => +g[Math.min(gN - 1, Math.floor(f * gN))].toFixed(2);
            return {
              gapP50: q(0.5), gapP95: q(0.95), gapP99: q(0.99),
              gapClumpPct: stats.gapN ? +((100 * stats.gapClump) / stats.gapN).toFixed(1) : null,
              gapMaxRun: stats.gapMaxRun,
            };
          })(),
          // Wall-clock stall list, for cross-side simultaneity. Deliberately raw: the
          // comparison lives in the harness, because "were these the same event" is a
          // question about two pages and cannot be answered from inside one of them.
          stalls: stats.stalls,
          jitSpreadMaxAtMs: stats.jitSpreadMaxAtMs, jitWarmMs: JIT_WARM,
          jitSpreadMaxLate: stats.jitSpreadMaxLate, jitSpreadMaxLateAtMs: stats.jitSpreadMaxLateAtMs,
          // The LIVE ceiling (elastic), not the configured one — plus the run
          // peak and raise count, so a call that stretched and came back is
          // distinguishable from one that never needed to.
          jitMaxTarget: maxEff, elMaxRun: stats.elMaxRun, elUps: stats.elUps,
          // Latency governor (task #47). govOn distinguishes "off" from "on but
          // never trimmed"; govTrimTicks is the authority check demanded by
          // [[the-contradiction-was-a-dead-knob]] — an A/B where this reads 0 in
          // the governed arm compared two identical control laws.
          govOn: JIT_GOV ? 1 : 0, govTrim: stats.govTrim, govFloor: stats.govFloor,
          govPops: stats.govPops, govTrimTicks: stats.govTrimTicks, govTrimMaxRun: stats.govTrimMaxRun,
          jitSpreadMs: stats.jitSpreadMs, jitP99Ms: stats.jitP99Ms, jitP90Ms: stats.jitP90Ms,
          jitMaxMs: stats.jitMaxMs, jitWant: stats.jitWant, jitN: stats.jitN,
          fecSymMismatch: stats.fecSymMismatch,
          // playout side, from the worklet's own counters
          started: wl.started,
          playedFrames: wl.playedFrames,
          lostFrames: wl.concealedFrames, // frames the playhead found missing
          concealedMs: wl.concealedFrames * 8,
          extrapolatedMs: (wl.concealedFrames - wl.heldFrames) * 8,
          heldMs: wl.heldFrames * 8,
          lateFrames: wl.lateFrames + stats.late,
          overflowSkips: wl.overflowSkips,
          depthMs: wl.depthMs,
          targetFrames: sab ? Atomics.load(ctl, SAB_TARGET) : target,
          driftPpm: wl.driftPpm,
          presence: wl.presence ?? null, // ?presence=1 room renderer, null when off

          outputLatencyMs: ctx?.outputLatency != null ? +(ctx.outputLatency * 1000).toFixed(1) : null,
          // One-way mouth-to-ear estimate, the number the latency campaign must
          // move (ITU-T G.114: 0–150 ms transparent). Composed, not measured
          // end-to-end: 8 ms frame assembly + age p50 (capture→arrival, needs
          // the ping clock offset, so null until it exists) + buffer depth +
          // device output latency. Each term is itself measured; the sum's
          // honesty is bounded by the ping offset's symmetric-path assumption.
          mouthToEarMs: (() => {
            const age = pct(stats.ageMs, 50);
            const outL = ctx?.outputLatency != null ? ctx.outputLatency * 1000 : null;
            if (age == null || wl.depthMs == null || outL == null) return null;
            const v = 8 + age + wl.depthMs + outL;
            // An impossible reading is the CLOCK lying, not the pipe: a peer
            // whose clock jumps (QEMU guest catchup, NTP steps, suspend-resume)
            // drives the ping offset wrong and the composed sum negative —
            // measured -324 to -16797 ms against emulator Android. Publishing
            // it poisons every consumer, so the instrument REFUSES: null, plus
            // a counter so "refused" is distinguishable from "not ready yet".
            if (!(v >= 0) || v > 60000) { stats.m2eRefused++; return null; }
            return +v.toFixed(1);
          })(),
          m2eRefused: stats.m2eRefused,
          reAnchors: stats.reAnchors,
          // Note: baseLatency is the AudioContext's processing latency (capture-side
          // ADC latency is not exposed by browsers, so inputMs is a lower bound and
          // is NOT added into mouthToEarMs, which stays exactly as it is).
          m2eParts: {
            frameMs: 8,
            netAgeP50Ms: pct(stats.ageMs, 50),
            netAgeP90Ms: pct(stats.ageMs, 90),
            ringDepthMs: wl.depthMs ?? null,
            outputMs: ctx?.outputLatency != null ? ctx.outputLatency * 1000 : null,
            inputMs: ctx?.baseLatency != null ? ctx.baseLatency * 1000 : null,
          },
          buffered: assocs[0].dc?.bufferedAmount ?? null,
          groupsHeld: groups.size,
          // §17.12 striping: per-association counters (ping/buffered/backpressure
          // are per-association — the caveat). At pairs=1 this is one row whose
          // numbers equal the aggregate above.
          pairs: PAIRS,
          laneSkew: (() => {
            // Reported whether or not the correction is applied: `applied` says
            // what the ring did, `max`/`perLane` say what the routes did. The
            // fleet's divergence prevalence is what decides whether skew-aware
            // striping is worth building.
            const all = laneSkewAll();
            return {
              max: all.max,
              applied: DESKEW ? 1 : 0,
              perLane: all.perLane,
            };
          })(),
          peerSkew: peerSkewAt > 0 ? {
            perLane: Array.from(peerSkewMs).map(v => +v.toFixed(1)),
            max: (() => {
              let m = 0;
              for (let k = 0; k < PAIRS; k++) {
                if ((peerSkewWarm & (1 << k)) && peerSkewMs[k] > m) {
                  m = peerSkewMs[k];
                }
              }
              return +m.toFixed(1);
            })(),
            warmMask: peerSkewWarm,
            ageMs: +(now() - peerSkewAt).toFixed(1),
          } : null,
          // What the peer says about OUR sending: percent of frames per lane that
          // reached it too late to play, and what we say about ITS sending. Both
          // directions, because the stall regression was one-sided and a
          // single-ended reading would have hidden which end was misrouting.
          // Reported whether or not striping is on — the fleet needs to know how
          // much of this exists before the flag can be trusted.
          latePct: {
            weSend: Array.from(peerLatePct),
            weRecv: Array.from({ length: PAIRS }, (_, k) => laneLatePct(k)),
          },
          stripe: SKEWSTRIPE ? {
            nFast,
            fastOrder: Array.from(fastOrder.subarray(0, nFast)),
            demotions: stripeDemotions,
            promotions: stripePromotions,
            probePromotions: stripeProbePromotions,
            dead: Array.from(laneDead).reduce((n, v) => n + v, 0),
            deadEvents: stripeDeadEvents,
            deadCause: { ...deadCause },
            deadFirstMs: stripeDeadFirstMs,
            muteAfterMs: +muteAfterMs(assocs[0]).toFixed(0),
            staleFailopen: stripeStaleFailopen,
          } : null,
          perAssoc: assocs.map((s, i) => ({
            i,
            open: s.dc?.readyState === 'open',
            framesSent: s.framesSent,
            framesRecv: s.framesRecv,
            bytesSent: s.bytesSent,
            paritySent: s.paritySent,
            skipBuffered: s.skipBuffered,
            rttMs: s.rttMs,
            baseRttMs: s.baseRttMs,
            clockOffsetMs: s.clockOffsetMs,
            buffered: s.dc?.bufferedAmount ?? null,
            padBytesSent: s.padBytesSent,
            padBytesRecv: s.padBytesRecv,
          })),
        };
      },
      // Tear down ONE peer. The capture half — worklet, capture ring, echo
      // detector, mic source — belongs to the call and outlives any peer in it.
      stop() {
        clearInterval(pinger);
        clearInterval(lossTimer);
        clearInterval(decayTimer);
        clearInterval(padTimer);
        try { playNode?.disconnect(); } catch { /* ignore */ }
        for (const a of assocs) { try { a.dc?.close(); } catch { /* ignore */ } }
      },
    };
  }

  // ── The compressor, once per frame however many peers ask for it ──────────
  // The packed bytes are identical for every peer, so a second peer must never
  // pay for a second pass (§5.1: "the compression and packing cost doubles for
  // zero benefit"). MEMOISED rather than hoisted into onCaptureFrame, because
  // at one peer it has to run at exactly the moment it ran before — after that
  // peer's association pick — or a frame spent as a gap would still turn up in
  // the bit-depth probe.
  //
  // The memo is TWO SCALARS keyed on the frame's own seq, not a per-frame
  // object handed down the call. `zipOut` is already the shared scratch these
  // bytes live in, so a per-frame allocation here bought nothing and put 125
  // objects a second into the one loop that must not pause: the memo's job is
  // to make the SECOND peer free, not to make the first peer allocate.
  let packSeq = -1, packLen = FRAME_BYTES;
  function packOnce(seq, buf) {
    if (packSeq === seq) return packLen;
    packSeq = seq;
    const src = new Uint8Array(buf);
    for (let i = 0, o = 0; i < 384; i++, o += 3) {
      const v = src[o] | (src[o + 1] << 8) | (src[o + 2] << 16);
      zipIn[i] = (v & 0x800000) ? (v | ~0xffffff) : v;
    }
    // ── bit-depth probe, 1 frame in 64 ───────────────────────────────────
    // wastedShift reports that the low 8 bits are NOT zero. This says whether
    // they are information or arithmetic residue, which is a different
    // question and the one that decides whether anything can be done about it.
    // A capture chain that converts int16 with /32767 instead of /32768 hands
    // us round(k * 8388608/32767) = round(k * 256.0078) — still only 16 bits
    // of content, but no longer a multiple of 256, so wasted-bits finds
    // nothing. The /32768 arm is the control and should track wastedShift.
    // Sampled rather than continuous: 384 samples x 2 candidates every 64
    // frames is ~1500 ops per half second, which is free, and a stream that
    // changes character mid-call will still show up over a 35 s run.
    if ((capStats.probeTick++ & 63) === 0) {
      capStats.probeFrames++;
      let fit67 = 1, fit68 = 1;
      for (let i = 0; i < 384; i++) {
        const v = zipIn[i];
        if (fit67 && Math.round(Math.round((v * 32767) / 8388608) * (8388608 / 32767)) !== v) fit67 = 0;
        if (fit68 && ((v & 0xff) !== 0)) fit68 = 0;
        if (!fit67 && !fit68) break;
      }
      capStats.fit32767 += fit67;
      capStats.fit32768 += fit68;
    }
    // A `rawSample` field carrying eight verbatim capture samples lived here
    // while the two hypotheses above were being refuted, and is deliberately
    // gone. app.js logs this snapshot to telemetry, which POSTs to the room
    // every 5 s, so anything left in it is raw microphone data leaving the
    // device on every call. The counters above are aggregates and carry no
    // audio; keep it that way. Diagnostics that need real samples belong in a
    // local run, printed, not in a structure designed to be uploaded.
    const payLen = packFrame(zipIn, zipOut, WASTED);
    // The wasted-bits shift the packer found, reported because it is a LIVE
    // MEASUREMENT of the capture chain's effective bit depth and nothing else
    // here can see it. 8 means the browser handed us 16-bit content in a
    // 24-bit container and the codec just saved 384 B on this frame; 0 means
    // the low bits carry something and we paid full price. Offline fixtures
    // cannot answer this — they are all 16-bit by construction — so the only
    // honest source for it is a real call.
    capStats.zipFrames++;
    capStats.shiftSum += zipOut[0] & 31;
    if ((zipOut[0] & 31) >= 8) capStats.shift8++;
    packLen = payLen;
    return payLen;
  }

  /**
   * A frame off the capture ring. Everything the MIC owns happens here, once:
   * the cadence probe, the frame counter and the echo detector's near-end tap.
   * Then the frame is offered to every peer's half — today, exactly one.
   */
  function onCaptureFrame(seq, buf, capUs) {
    if (closed) return;
    // TEST INSTRUMENTATION (?pcmslowclock=0.43, default off): reproduce a
    // CPU-starved sender whose seq clock runs slower than wall time — the live
    // phone defect of 2026-08-16 — by decimating capture frames and renumbering
    // the survivors contiguously on the slow clock. Faithful to the real
    // signature: contiguous seqs, seq+capUs in lockstep, advance rate < 1x wall.
    if (SLOW_CLOCK) {
      const tx = Math.floor(seq * SLOW_CLOCK);
      if (tx === slowLastTx) return;
      slowLastTx = tx;
      seq = tx;
      capUs = tx * 8000;
    }
    diagCap?.hit(performance.now());
    capStats.captureFrames++;
    if (det) {
      const u8 = new Uint8Array(buf);
      let sumSq = 0;
      for (let i = 0, o = 0; i < 384; i++, o += 3) {
        const v = u8[o] | (u8[o + 1] << 8) | (u8[o + 2] << 16);
        const s = (v & 0x800000) ? (v | ~0xffffff) : v;
        const norm = s / 8388608;
        sumSq += norm * norm;
      }
      det.mic(now(), Math.sqrt(sumSq / 384));
    }
    // Indexed, not `for…of`: this runs 125 times a second between the capture
    // drain and `dc.send()`, and an iterator object per frame is exactly the
    // kind of allocation that has no business on the departure path.
    for (let i = 0; i < halves.length; i++) halves[i].offerFrame(seq, buf, capUs);
  }

  halves.push(createPeerHalf());

  // ── Audio graph ───────────────────────────────────────────────────────────
  (async () => {
    try {
      ctx = await audioContext(); // the shared 48 kHz context — one clock origin for both detectors
      await addWorkletModule(ctx, '/pcm-worklet.js');
      if (closed) return;

      capNode = new AudioWorkletNode(ctx, 'pcm-capture', {
        numberOfOutputs: 0,
        // §3.1 lever 4: run the turn-end predictor on the mic at zero latency
        // (Lane 0 only — with cfg.lane0 off the worklet never constructs it).
        processorOptions: { turnend: !!cfg.lane0, capSab: capSab ?? undefined, aecSab: aecSab ?? undefined },
      });
      capNode.port.onmessage = (e) => {
        const m = e.data;
        if (m === 1) drainCap(); // capture-ring drain hint
        else if (m && m.buf) onCaptureFrame(m.seq, m.buf, m.capUs);
        else if (m && m.type === 'turnend') {
          try { onTurnEnd?.(m); } catch { /* predictor plumbing must never break the lane */ }
        } else if (m && m.type === 'aec2') {
          capStats.aec2 = m;
          L('aec2-stats', m);
        }
      };
      if (capSab) {
        // The pump. Measured 2026-08-04: WebKit quantizes setTimeout to the
        // same ~16.7 ms rendering tick as port delivery (a 0 ms chain drained
        // at p90 16.4 ms), but it did cut the stall tail (send max 43 → 28 ms).
        // ?pcmpump=mc tries the one scheduler left that is not the timer
        // system: a MessageChannel self-ping loop, which runs at event-loop
        // speed. It is a hot loop, so it is an experiment arm, not a default.
        // Either way the port hint above still drains when the page is hidden
        // and timers are throttled — the worst case degrades to exactly the
        // old behaviour, never below it.
        if (cfg.pcmPump === 'mc') {
          const ch = new MessageChannel();
          ch.port1.onmessage = () => { if (closed) return; drainCap(); ch.port2.postMessage(0); };
          ch.port2.postMessage(0);
          capPumpT = { close: () => { ch.port1.onmessage = null; ch.port1.close(); ch.port2.close(); } };
        } else {
          const pump = () => { if (closed) return; drainCap(); capPumpT = setTimeout(pump, 0); };
          capPumpT = setTimeout(pump, 0);
        }
      }
      source = ctx.createMediaStreamSource(stream);
      source.connect(capNode); // no destination: the pull pattern proven by attachDetector

      // Each peer's playout node, in the position the single one held before.
      for (const h of halves) h.attachGraph();
      L('pcm-graph', { mode, sampleRate: ctx.sampleRate, outputLatencyMs: +((ctx.outputLatency ?? 0) * 1000).toFixed(1) });
    } catch (e) {
      L('pcm-fail', { why: 'graph', error: String(e).slice(0, 160) });
    }
  })();

  return {
    stats: halves[0].stats,
    mode,
    // The call's duress, which is the WORST of its peers': the video lane reads
    // one number and shares one uplink, so a peer in trouble is the call in
    // trouble. At one peer this is that peer's own answer.
    // Indexed for the same reason the fan-out is: the video lane polls this
    // once per encoded frame, and it must stay the "reads live state, never
    // computes" call its own comment promises.
    duress() {
      let d = 0;
      for (let i = 0; i < halves.length; i++) { const v = halves[i].duress(); if (v > d) d = v; }
      return d;
    },
    // Lane 0 (§3.1 levers 3+4): policy lives in app.js (it owns the detector
    // state these decisions gate on); the wire mechanics live here. Both fan
    // out — a prediction and a pre-warm are about OUR next turn, which every
    // peer in the room is waiting through.
    sendTurnEnd() {
      let sent = 0;
      for (const h of halves) sent += h.sendTurnEnd();
      return sent;
    },
    sendPad(totalBytes) {
      for (const h of halves) h.sendPad(totalBytes);
    },
    // idx = association index within ONE peer's stripe: 0 is that pair's main
    // pc 'pcm-audio' channel, 1..N-1 are its stripe pcs (app.js `?pcmpairs=`).
    // peer = which receive half; app.js passes nothing while media is
    // single-pair, so every channel lands on half 0 exactly as before.
    attachChannel(channel, idx = 0, peer = 0) {
      halves[peer]?.attachChannel(channel, idx);
    },
    // §5.1's second receive half. NOTHING calls this today: media is still
    // single-pair, so a half built here would sit with no associations attached
    // and a silent playout node. Phase 4/6 calls it once per extra peer and
    // then attaches that peer's channels with `attachChannel(dc, idx, n)`.
    addPeer() {
      // Spatial law: voice 0 (the media pair) is centered; each ADDED voice
      // sits at a distinct seat so a 3-way call reads as sitting between two
      // people. One extra voice is the only case today: +28° (right). cfg
      // gates it (?spatial=0 pins center; presence off = no renderer at all).
      const az = cfg.presence && cfg.spatial !== false && halves.length >= 1 ? 28 : 0;
      const h = createPeerHalf({ azimuthDeg: az });
      halves.push(h);
      h.attachGraph();
      return halves.length - 1;
    },
    // Mid-call mic switch (§15): point the capture worklet at the new stream.
    // Only the source node is rebuilt — the worklet, the ring, and the seq
    // continue untouched — because MediaStreamAudioSourceNode latches its
    // track at construction and never follows the stream's track list.
    retap(stream) {
      if (!ctx || !capNode) return false;
      try { source?.disconnect(); } catch { /* already gone */ }
      source = ctx.createMediaStreamSource(stream);
      source.connect(capNode);
      L('pcm-retap', { track: (stream.getAudioTracks?.()[0]?.label ?? '').slice(0, 64) });
      return true;
    },
    // ── §10 A-V sync probes ─────────────────────────────────────────────────
    // The LOCAL audio clock, in µs: the sender maps its VideoFrame clock onto
    // it (tape.js ships the delta over ctl), because the two capture clocks on
    // one device drift apart. ctx.currentTime is the audio hardware's clock —
    // never performance.now(), which drifts against it (§10).
    audioClockUs() {
      return ctx ? ctx.currentTime * 1e6 : null;
    },
    // Both of these read ONE peer's receive half. The A-V sync loop syncs to
    // the peer whose video it is presenting; today there is one of each.
    playheadInfo(peer = 0) {
      return halves[peer]?.playheadInfo() ?? null;
    },
    snapshot(peer = 0) {
      return halves[peer]?.snapshot() ?? null;
    },
    stop() {
      closed = true;
      clearInterval(echoTimer);
      if (capPumpT?.close) capPumpT.close(); else clearTimeout(capPumpT);
      try { source?.disconnect(); } catch { /* ignore */ }
      try { capNode?.disconnect(); } catch { /* ignore */ }
      for (const h of halves.splice(0)) h.stop();
    },
  };
}
