/**
 * TAPE — the custom video lane.
 *
 * This is the path §1 actually asks for and that stock WebRTC cannot express:
 * **a fixed quantizer.** You do not hand this encoder a bitrate. You hand it a
 * quality, and the bitrate is whatever that quality costs this second.
 *
 * Why that is the whole design, in one measurement (testbed/wcprobe.mjs, Chrome 149):
 * at a constant QP of 24, a flat grey delta frame cost 40 bytes and a frame of noise
 * cost 170,019 bytes — 4250x — because nothing about the picture was allowed to give.
 * Stock WebRTC inverts this: you name a bitrate and it spends detail to hit it, which
 * is precisely the "video call" texture §1 is trying to escape.
 *
 * So when the link cannot carry this second's cost, we do not lower the quantizer.
 * We drop the frame **at capture, before it is encoded**. That matters mechanically,
 * not just philosophically: the encoder's reference chain only ever contains frames we
 * actually sent, so a skipped capture is invisible to the decoder — it sees a lower
 * frame rate and nothing else. No corruption, no keyframe storm, no green blocks.
 * Time absorbs the shock. Quality is a constant.
 *
 * Structure:
 *   camera track -> MediaStreamTrackProcessor -> admission control -> VideoEncoder(QP)
 *     -> fragment -> RTCDataChannel(unordered) -> reassemble -> VideoDecoder
 *     -> MediaStreamTrackGenerator -> the same <video id="remote"> as before
 *
 * Rendering through a track generator rather than a canvas is deliberate: every
 * life-size / gaze-alignment / no-self-view decision in app.js and index.html keeps
 * working untouched, because from the DOM's point of view this is still just a video
 * track in a video element.
 *
 * Audio deliberately stays on RTP. It is already 128 kbps Opus at measured zero extra
 * loss exposure (§17.3), Chrome's echo canceller is wired to the RTP path, and audio
 * is the one stream where a glitch is not recoverable by waiting. There is no gain
 * here worth that risk.
 *
 * Robustness rule inherited from app.js: this runs during a real conversation that
 * happens once. Every entry point is wrapped, and any failure calls `onFail` so the
 * caller can fall back to an ordinary WebRTC video track.
 */
import { tickInterval } from './core/tick.js';

// ── Wire format ──────────────────────────────────────────────────────────────
// 28-byte header per fragment. Fragments are independent datagrams, which is the
// point: one lost fragment costs one frame, and we can say so, rather than a lost
// SCTP fragment silently voiding a 170 KB message we cannot reason about.
//
//   0  u8   version
//   1  u8   flags        bit0 = keyframe, bit1 = parity
//   2  u16  fragIdx      for parity fragments: the group index instead
//   4  u16  fragCount    number of *data* fragments in this frame
//   6  u8   groupSize    data fragments per parity group; 0 = no FEC on this frame
//   7  u8   (reserved, keeps the f64s 8-byte aligned)
//   8  u32  frameId
//  12  f64  timestampUs  media timestamp, passed through to the decoder
//  20  f64  sendWallMs   sender wall clock; with the ctl-channel clock offset this
//                        makes true one-way video delay measurable for the first time
const HDR = 28;
const VERSION = 2;
const FLAG_KEY = 1;
const FLAG_PARITY = 2;

// ── Why there is FEC here at all ─────────────────────────────────────────────
// Measured, not assumed. The first version of this file shipped with zero retransmits
// and no redundancy, on the reasoning that a retransmitted delta frame arrives after it
// was due. That reasoning is correct and the conclusion was still wrong, because it
// ignored fragment-count amplification:
//
//   a 49 KB delta frame is 45 fragments  ->  1% packet loss = 36% frame loss (0.99^45)
//   a 100 KB keyframe is 90 fragments    ->  1% packet loss = 60% keyframe loss
//
// and since a lost frame's only repair is a keyframe, every loss asks for the most
// expensive thing on the wire, which is itself more likely to be lost than not. The
// measured result at 1% loss with *unlimited bandwidth* was zero frames decoded in
// 30 seconds, 55 of 72 sent frames being keyframes. A death spiral needing no
// congestion to sustain it.
//
// One XOR parity fragment per group of G repairs any single loss in that group with no
// round trip. At G=10 that is 10% overhead and turns 36% frame loss into roughly 1.7%:
//   P(group of 9 loses 2+) = 1 - 0.99^9 - 9(0.01)(0.99^8) = 0.0035, over 5 groups.
//
// Keyframes get a smaller group — unequal error protection — because a lost delta frame
// costs one frame and a lost keyframe costs every frame until the next one.
//
// This is also the one place we are strictly ahead of stock WebRTC rather than merely
// different: the fecprobe run (telemetry.js FEC counters, all null at 1% loss) showed
// Chrome's RTP video path doing no FEC at all, recovering purely by retransmission.
//
// Sobering coda, measured after this was built: under random loss the FEC barely
// matters *on this transport*, because SCTP's loss-based congestion control collapses
// throughput to ~1.22·MSS/(RTT·√p) first (§17.6). The parity earns its keep only on a
// lane whose congestion controller ignores random loss; it is kept because the lane is
// right and the transport under it is what has to change.
const PARITY_LEN_HDR = 2; // parity payload is u16 length XOR, then the payload XOR

// 1100 B of payload keeps a fragment inside one MTU after SCTP + DTLS + UDP + IP
// overhead, so SCTP never re-fragments underneath us and our "one fragment is one
// datagram" reasoning stays true. 28/1128 = 2.5% header overhead.
const PAYLOAD = 1100;

const now = () => performance.timeOrigin + performance.now();

const UPSCALE =
  typeof location !== 'undefined' && new URLSearchParams(location.search).get('upscale') === '1';

// Consecutive frames a new camera size must hold before the encoder follows it.
// 5 at 30 fps is ~167 ms: long enough that a single odd frame cannot trigger a
// reconfigure (which costs a keyframe), short enough to be imperceptible.
const RESIZE_HOLD = 5;

/**
 * The size to actually encode: what the camera produces, capped by what we asked
 * for. `cfg.width/height` is a CEILING, not a target.
 *
 * This was a target, and it was wrong in the expensive direction. Feed a 1280x720
 * VideoFrame to an encoder configured 1920x1080 and WebCodecs upscales it — 2.25x
 * the pixels carrying not one extra bit of information, paid for twice on the wire
 * and twice in encode+decode time. Measured against production with a 720p source:
 * the far end's canvas came back 1920x1080, and because the canvas faithfully
 * tracks `frame.displayWidth`, every instrument downstream reported "1080p
 * delivered". It was 720p in a 1080p envelope.
 *
 * Downscale still happens when the sensor genuinely exceeds the ceiling — a 4K
 * webcam is not shipped at 4K. Only the upscale is removed.
 *
 * Even dimensions because H.264 chroma is subsampled 4:2:0; an odd width is a
 * config some encoders reject and others silently round.
 */
function fitSize(w, h, cfg) {
  const even = (n) => Math.max(2, Math.round(n / 2) * 2);
  if (!w || !h) return { width: cfg.width, height: cfg.height };
  if (w > cfg.width || h > cfg.height) {
    const k = Math.min(cfg.width / w, cfg.height / h); // fit inside, keep aspect
    w *= k;
    h *= k;
  }
  return { width: even(w), height: even(h) };
}

function encodeSize(track, cfg) {
  // ?upscale=1 restores the old always-encode-at-the-ceiling behaviour. Kept as a
  // control arm, not as an option: pricing what the upscale cost needs the same
  // camera and the same content encoded both ways, and every other way of
  // arranging that changes a second variable. Never on by default.
  if (UPSCALE) return { width: cfg.width, height: cfg.height };
  const s = track?.getSettings?.() ?? {};
  return fitSize(s.width, s.height, cfg);
}

// ?sendnow=1 — task #41 lever 1: send-on-encode-output. The carrier ticks on
// the canvas auto-capture cadence (§17.20: the tick's phase against the 30 fps
// encode output is the entire loopback "transport" term, ~⅔ tick mean wait).
// CanvasCaptureMediaStreamTrack.requestFrame() pulls an EXTRA carrier tick to
// ~5 ms after the call (measured, testbed/reqframe-probe.mjs: request→
// send-transform p50 5.4 / p95 15.8 ms), so an encoded frame splices into a
// tick pulled for it instead of waiting out the phase. Chrome coalesces
// requests into the BeginFrame budget (~60/s cap, measured), so this changes
// tick PHASE, never the wire format: substituted frames are byte-identical,
// receivers never assumed carrier cadence (the v-presenter anchors on capture
// timestamps; FEC groups are id windows), so mixed fleets (one side flagged,
// one not) interwork. Flag OFF: not one call is made — byte- and
// timing-identical to before the flag existed.
const SENDNOW =
  typeof location !== 'undefined' && new URLSearchParams(location.search).get('sendnow') === '1';

/**
 * @param {object} o
 * @param {RTCPeerConnection} o.pc
 * @param {MediaStreamTrack} o.track      local camera track
 * @param {boolean} o.initiator           one side must create the channels
 * @param {object} o.cfg                  { qp, codec, width, height, fps, maxRetransmits, queueMs, keyMs }
 * @param {(s: MediaStream) => void} o.onRemote  called once with the decoded stream
 * @param {(tag: string, d: object) => void} o.log
 * @param {(why: string) => void} o.onFail
 */
export function startTapeVideo({ pc, track, initiator, cfg, onRemote, log, onFail }) {
  const L = (tag, d) => { try { log?.(tag, d); } catch { /* telemetry must never break the call */ } };
  const fail = (why, e) => {
    L('tape-fail', { why, error: e ? String(e).slice(0, 160) : null });
    try { onFail?.(why); } catch { /* the fallback itself must not throw */ }
  };

  const encMeter = fpsMeter();
  const stats = {
    // send
    framesIn: 0, framesEncoded: 0, framesSkipped: 0,
    skipBuffered: 0, skipEncQueue: 0, skipDecodeStalled: 0,
    bytesSent: 0, fragsSent: 0, keyframesSent: 0, keyReqRecv: 0,
    encQueuePeak: 0, bufferedPeak: 0,
    paritySent: 0, parityBytes: 0,
    // Camera changed under us. `trackSwaps` counts pump re-attachments (a flip);
    // `reconfigs` counts encoder re-configures because the camera's own size moved.
    // Both were silent failures before: the pump used to end for good on a swap.
    reconfigs: 0, reconfigFails: 0, trackSwaps: 0,
    // recv
    framesOut: 0, fragsRecv: 0, bytesRecv: 0,
    framesLost: 0, fragsLate: 0, keyReqSent: 0, decodeErrors: 0,
    // FEC outcome. `fecRepaired` is the whole justification for the overhead; if it
    // stays near zero on a lossy path the redundancy is being wasted, and if
    // `fecUnrepairable` dominates the group size is too large for this loss rate.
    fecRepaired: 0, fecUnrepairable: 0, framesGapped: 0, parityUnused: 0,
    // timing
    rttMs: null, clockOffsetMs: null, ageMs: [],
    qpBytes: [], // bytes per encoded frame, for the cost-of-quality question
    // Cumulative, never windowed. `mbpsAtFps` above averages the last 900
    // encoded frames — THIRTY SECONDS at 30fps — which makes it useless for any
    // experiment that changes a setting and reads back sooner than that: the
    // reading is a blend of the new arm and the two before it. A within-call
    // A/B sweep read that way produced flatly contradictory results (one lever
    // measured as costing 31% alone and saving 28% in combination) before the
    // window, not the lever, turned out to be the thing being measured.
    // Difference these across a slot for the exact bytes that slot cost.
    encBytesTotal: 0, encFramesTotal: 0,
  };

  let closed = false;
  let enc = null, dec = null, gen = null, writer = null;
  let encConfig = null;      // last config handed to enc.configure(); a resize re-issues it
  let resizeHold = 0;        // consecutive frames the new camera size has held
  let curTrack = track;      // camera the pump is reading; moves on a flip or re-acquire
  let dcMedia = null, dcCtl = null;
  let procReader = null;
  let remoteReady = false;   // peer has told us its decoder is configured
  let wantKey = true;        // send a keyframe on the next admitted frame
  let lastKeyAt = 0;
  let frameId = 0;
  let pinger = null;

  // ── Control channel ────────────────────────────────────────────────────────
  // Ordered and reliable, JSON, tiny. Keeping control off the media channel means a
  // keyframe request can never be dropped by the media channel's zero-retransmit
  // policy — which would deadlock recovery exactly when it is needed.
  const ctlSend = (o) => {
    try { if (dcCtl?.readyState === 'open') dcCtl.send(JSON.stringify(o)); } catch { /* ignore */ }
  };

  const onCtl = (raw) => {
    let m;
    try { m = JSON.parse(raw); } catch { return; }
    if (!m || typeof m.t !== 'string') return; // unrecognised shapes are dropped, not guessed at
    switch (m.t) {
      case 'cfg':
        // The peer described its encoder; configure our decoder to match.
        setupDecoder(m).catch((e) => fail('decoder-configure', e));
        break;
      case 'ready':
        remoteReady = true;
        L('tape-remote-ready', {});
        break;
      case 'key':
        stats.keyReqRecv++;
        wantKey = true;
        break;
      case 'ping':
        ctlSend({ t: 'pong', a: m.a, b: now() });
        break;
      case 'pong': {
        // Standard two-timestamp exchange. `b` is the peer's clock when it replied;
        // assuming a symmetric path, our clock at that instant was a + rtt/2, so the
        // offset is what makes the peer's timestamps comparable to ours. Symmetry is
        // an assumption, and it is the reason frame age is reported as a measurement
        // with a known bias rather than as ground truth.
        const t = now();
        const rtt = t - m.a;
        stats.rttMs = +rtt.toFixed(2);
        stats.clockOffsetMs = +(m.b - (m.a + rtt / 2)).toFixed(2);
        break;
      }
      case 'stall':
        // Peer's decoder is behind. Treat exactly like link backpressure: give it time.
        stats.skipDecodeStalled++;
        break;
    }
  };

  // ── Encoder ────────────────────────────────────────────────────────────────
  async function setupEncoder() {
    const size = encodeSize(curTrack, cfg);
    const config = {
      codec: cfg.codec,
      width: size.width,
      height: size.height,
      framerate: cfg.fps,
      latencyMode: 'realtime',
      // The lever. Everything above depends on this one string being honoured.
      bitrateMode: 'quantizer',
      // annexb carries parameter sets inline, so the receiver needs no out-of-band
      // extradata and a mid-call keyframe is self-describing. With `avc` format we
      // would have to ship a description and keep it in sync across recovery.
      avc: { format: 'annexb' },
    };
    const sup = await VideoEncoder.isConfigSupported(config);
    // Chrome echoes the config it would really use. `supported: true` alone is not
    // enough — if it silently dropped bitrateMode we would be shipping VBR and calling
    // it fixed quality.
    if (!sup?.supported) throw new Error(`config unsupported: ${cfg.codec}`);
    if (sup.config?.bitrateMode && sup.config.bitrateMode !== 'quantizer') {
      throw new Error(`bitrateMode downgraded to ${sup.config.bitrateMode}`);
    }

    enc = new VideoEncoder({
      output: (chunk, meta) => { try { onEncoded(chunk, meta); } catch (e) { fail('send-path', e); } },
      error: (e) => fail('encoder', e),
    });
    enc.configure(config);
    encConfig = config; // kept so a mid-call resize can re-issue it with new dims
    stats.encW = config.width; stats.encH = config.height;
    L('tape-encoder', { ...config, hw: sup.config?.hardwareAcceleration ?? null });
    // The receiver configures its decoder from this, so it must be the size we
    // really encoded, not the size we asked for.
    ctlSend({ t: 'cfg', codec: cfg.codec, width: config.width, height: config.height, qp: cfg.qp });
  }

  const scratch = new Uint8Array(1 << 20); // reused chunk buffer; keyframes can be ~200 KB

  function onEncoded(chunk, meta) {
    if (closed || dcMedia?.readyState !== 'open') return;
    const n = chunk.byteLength;
    const buf = n <= scratch.length ? scratch.subarray(0, n) : new Uint8Array(n);
    chunk.copyTo(buf);

    const isKey = chunk.type === 'key';
    if (isKey) stats.keyframesSent++;
    stats.qpBytes.push(n);
    if (stats.qpBytes.length > 900) stats.qpBytes.shift();
    stats.encBytesTotal += n; stats.encFramesTotal++;

    const count = Math.max(1, Math.ceil(n / PAYLOAD));
    // 65535 fragments at 1100 B is 72 MB; a single frame that large means something is
    // badly wrong upstream, and truncating would ship a corrupt frame that looks like a
    // network problem. Drop it and ask for a fresh keyframe instead.
    if (count > 0xffff) { wantKey = true; return; }

    const id = frameId++;
    const wall = now();
    // Unequal error protection: a lost delta frame costs one frame, a lost keyframe
    // costs every frame until the next one, so keyframes buy more redundancy.
    const gs = isKey ? cfg.fecGroupKey : cfg.fecGroup;

    const hdr = (flags, idx, bodyLen) => {
      const msg = new ArrayBuffer(HDR + bodyLen);
      const dv = new DataView(msg);
      dv.setUint8(0, VERSION);
      dv.setUint8(1, flags);
      dv.setUint16(2, idx);
      dv.setUint16(4, count);
      dv.setUint8(6, gs > 0 && count > 1 ? Math.min(255, gs) : 0);
      dv.setUint32(8, id);
      dv.setFloat64(12, chunk.timestamp);
      dv.setFloat64(20, wall);
      return { msg, dv };
    };

    for (let i = 0; i < count; i++) {
      const off = i * PAYLOAD;
      const len = Math.min(PAYLOAD, n - off);
      const { msg } = hdr(isKey ? FLAG_KEY : 0, i, len);
      new Uint8Array(msg, HDR).set(buf.subarray(off, off + len));
      try { dcMedia.send(msg); } catch (e) { fail('dc-send', e); return; }
      stats.fragsSent++;
      stats.bytesSent += msg.byteLength;
    }

    // Parity. One fragment per group, XOR of `u16 length || payload` over the group's
    // members, zero-padded to PAYLOAD. XOR-ing the length too is what lets the receiver
    // recover a short final fragment — without it a repaired last fragment would be
    // padded with zeroes and corrupt the frame in a way the decoder cannot detect.
    if (gs > 0 && count > 1) {
      const groups = Math.ceil(count / gs);
      for (let g = 0; g < groups; g++) {
        const lo = g * gs;
        const hi = Math.min(count, lo + gs);
        // Parity over a single fragment is a byte-for-byte duplicate. That is a
        // legitimate strategy but it is 100% overhead, so it is not what this is for.
        if (hi - lo < 2) continue;
        const { msg } = hdr((isKey ? FLAG_KEY : 0) | FLAG_PARITY, g, PAYLOAD + PARITY_LEN_HDR);
        const par = new Uint8Array(msg, HDR);
        for (let i = lo; i < hi; i++) {
          const off = i * PAYLOAD;
          const len = Math.min(PAYLOAD, n - off);
          par[0] ^= len & 0xff;
          par[1] ^= (len >> 8) & 0xff;
          const seg = buf.subarray(off, off + len);
          for (let k = 0; k < len; k++) par[PARITY_LEN_HDR + k] ^= seg[k];
        }
        try { dcMedia.send(msg); } catch (e) { fail('dc-send-parity', e); return; }
        stats.paritySent++;
        stats.parityBytes += msg.byteLength;
        stats.bytesSent += msg.byteLength;
      }
    }
    if (meta?.decoderConfig) L('tape-meta', { desc: !!meta.decoderConfig.description });
  }

  // ── Admission control: the shock absorber ──────────────────────────────────
  // Three independent reasons to spend time instead of quality. Each is counted
  // separately because they call for different fixes and conflating them is how a
  // CPU problem gets diagnosed as a network problem.
  function admit() {
    if (!remoteReady) return 'not-ready';
    // 1. The link is behind. bufferedAmount is bytes SCTP has accepted but not yet put
    //    on the wire, so it is backpressure measured where it actually happens.
    const buffered = dcMedia.bufferedAmount;
    if (buffered > stats.bufferedPeak) stats.bufferedPeak = buffered;
    // The threshold has to be larger than one frame, or admission control trips on the
    // frame it just admitted and never recovers. The first version used a flat 64 KB
    // against ~100 KB keyframes, and skipped 93% of captures on a link with no ceiling
    // at all. Scaling to recent frame size keeps the *time* meaning of the threshold
    // roughly constant as the picture gets more or less expensive.
    const big = stats.qpBytes.length ? Math.max(...stats.qpBytes.slice(-30)) : 0;
    const limit = Math.max(cfg.queueBytes, big * 2);
    if (buffered > limit) { stats.skipBuffered++; return 'buffered'; }
    // 2. The encoder is behind. Queueing more frames onto a saturated hardware encoder
    //    only adds latency to frames that are already late.
    const q = enc.encodeQueueSize;
    if (q > stats.encQueuePeak) stats.encQueuePeak = q;
    if (q > cfg.maxEncQueue) { stats.skipEncQueue++; return 'encq'; }
    return null;
  }

  // True while a pumpCapture() loop is live. adoptTrack() reads it to decide between
  // nudging the running pump and starting one: two pumps feeding one encoder would
  // double the frame rate and interleave keyframe state.
  let pumping = false;

  async function pumpCapture() {
    if (pumping) return;
    pumping = true;
    try {
     // Outer loop: one MediaStreamTrackProcessor per camera. A flip ends the old track,
     // which closes its reader. Before this loop the pump returned on `done` and the
     // lane stayed dead for the rest of the call — measured on lane 2 as the far end
     // falling to 0.4 fps with no recovery and no fallback (MEASURED.md, camera flip).
     for (;;) {
      const mine = curTrack;
      if (!mine || closed) return;
      const proc = new MediaStreamTrackProcessor({ track: mine });
      procReader = proc.readable.getReader();
      let swapped = false;
      for (;;) {
        const { done, value: frame } = await procReader.read();
        // Distinguish "the camera we were told to read has changed" from "capture is
        // over". Only the first is worth re-attaching for.
        if (done) { swapped = !closed && curTrack !== mine && !!curTrack; break; }
        if (closed) { frame.close(); return; }
        stats.framesIn++;
        const why = admit();
        if (why) {
          stats.framesSkipped++;
          // Closing is not optional. Chrome hands out frames from a small pool and a
          // leaked VideoFrame stalls capture entirely a few frames later — a skip path
          // that leaks looks exactly like a camera that died.
          frame.close();
          continue;
        }
        // The camera's own size can move mid-call: a flip to a rear sensor, or the
        // capture ladder stepping down under a starved source. The encoder config is a
        // ceiling, so without this the lane would upscale every frame back to it and
        // pay for pixels the sensor never produced. Held for RESIZE_HOLD frames so a
        // single odd frame cannot cost a keyframe.
        stats.camW = frame.displayWidth; stats.camH = frame.displayHeight;
        if (!UPSCALE && encConfig && enc?.state === 'configured') {
          const want = fitSize(frame.displayWidth, frame.displayHeight, cfg);
          if (want.width !== encConfig.width || want.height !== encConfig.height) {
            if (++resizeHold >= RESIZE_HOLD) {
              resizeHold = 0;
              const from = `${encConfig.width}x${encConfig.height}`;
              encConfig = { ...encConfig, width: want.width, height: want.height };
              stats.encW = want.width; stats.encH = want.height;
              try {
                enc.configure(encConfig);
                // annexb carries SPS/PPS inline, so this keyframe re-describes the
                // stream by itself. The peer needs no new `cfg` and no new decoder.
                wantKey = true;
                stats.reconfigs++;
                L('tape-resize', { lane: 'dc', from, to: `${want.width}x${want.height}` });
              } catch (e) {
                stats.reconfigFails++;
                L('tape-resize', { lane: 'dc', from, err: String(e).slice(0, 80) });
              }
            }
          } else if (resizeHold) { resizeHold = 0; }
        }
        const t = now();
        const key = wantKey || t - lastKeyAt > cfg.keyMs;
        if (key) { wantKey = false; lastKeyAt = t; }
        try {
          // The per-frame quantizer. `avc.quantizer` is the H.264 spelling; VP9/AV1 use
          // `vp9`/`av1`. Passing all three is harmless — the encoder reads its own.
          enc.encode(frame, {
            keyFrame: key,
            avc: { quantizer: cfg.qp },
            vp9: { quantizer: cfg.qp },
            av1: { quantizer: cfg.qp },
          });
          stats.framesEncoded++;
          encMeter.note();
        } catch (e) {
          fail('encode', e);
          frame.close();
          return;
        }
        frame.close();
      }
      if (!swapped) return;
      // A new sensor starts a new picture: the peer's reference frames are all of the
      // old one, so the first frame off the new camera has to be a keyframe.
      wantKey = true;
      stats.trackSwaps++;
      L('tape-track-swap', { lane: 'dc', to: `${curTrack.label || 'camera'}`.slice(0, 40) });
     }
    } finally {
      pumping = false;
    }
  }

  /**
   * The camera changed (a flip, or a re-acquire after the OS took the device).
   * app.js calls this from adoptVideoTrack BEFORE it stops the old track.
   *
   * Cancelling the reader makes the running pump's read() resolve done; it then sees
   * curTrack has moved and re-attaches. If no pump is running we start one — but only
   * once the media channel is open, because that is the pump's own start condition
   * (bind → dcMedia.onopen) and starting earlier would encode into a null encoder.
   */
  function adoptTrack(nv) {
    if (!nv || closed || nv === curTrack) return;
    curTrack = nv;
    try { procReader?.cancel(); } catch { /* ignore */ }
    if (!pumping && dcMedia?.readyState === 'open') {
      pumpCapture().catch((e) => fail('capture-readopt', e));
    }
  }

  // ── Decoder + reassembly ───────────────────────────────────────────────────
  const asm = new Map(); // frameId -> { parts, have, count, key, ts, wall, at }
  let lastDecoded = -1;
  let haveKey = false;

  async function setupDecoder(m) {
    if (dec) return;
    const config = { codec: m.codec, codedWidth: m.width, codedHeight: m.height, optimizeForLatency: true };
    const sup = await VideoDecoder.isConfigSupported(config);
    if (!sup?.supported) throw new Error(`decoder unsupported: ${m.codec}`);

    gen = new MediaStreamTrackGenerator({ kind: 'video' });
    writer = gen.writable.getWriter();
    dec = new VideoDecoder({
      output: (frame) => { void onDecoded(frame); },
      error: (e) => {
        // A decode error is recoverable: drop state and ask for a keyframe. It must not
        // tear the call down, because the usual cause is a frame we already know we lost.
        stats.decodeErrors++;
        haveKey = false;
        requestKey('decode-error');
      },
    });
    dec.configure(config);
    L('tape-decoder', { ...config });
    try { onRemote(new MediaStream([gen])); } catch (e) { fail('attach-remote', e); return; }
    ctlSend({ t: 'ready' });
  }

  async function onDecoded(frame) {
    stats.framesOut++;
    try {
      // Awaiting the writer is the backpressure signal from the renderer. If we do not
      // await, frames pile up in the generator and every one of them is stale by the
      // time it is shown — latency grows silently instead of frames being dropped.
      await writer.write(frame);
    } catch {
      frame.close();
      return;
    }
  }

  let keyReqAt = 0;
  function requestKey(why) {
    const t = now();
    // Rate-limit: a burst of losses would otherwise produce a burst of keyframe
    // requests, and keyframes are the most expensive thing on the wire. Asking twenty
    // times makes the congestion that caused the loss worse.
    //
    // The floor must exceed the time for a request to reach the peer and a keyframe to
    // come back — RTT plus the keyframe's own serialization — or we ask again while the
    // answer is still in flight. Measured at 250 ms flat: 55 of 72 frames sent were
    // keyframes, which is the storm this now prevents.
    if (t - keyReqAt < cfg.keyReqMs + (stats.rttMs ?? 0)) return;
    keyReqAt = t;
    stats.keyReqSent++;
    ctlSend({ t: 'key', why });
  }

  // Repair any group that is missing exactly one data fragment and has its parity.
  // Returns true if anything was recovered.
  function tryRepair(e) {
    if (!e.gs || e.par.size === 0) return false;
    let did = 0;
    const groups = Math.ceil(e.count / e.gs);
    for (let g = 0; g < groups; g++) {
      const p = e.par.get(g);
      if (!p) continue;
      const lo = g * e.gs;
      const hi = Math.min(e.count, lo + e.gs);
      let missing = -1;
      let n = 0;
      for (let i = lo; i < hi; i++) if (!e.parts[i]) { missing = i; n++; }
      if (n === 0) { e.par.delete(g); continue; }
      // Two or more gone in one group is beyond single-parity XOR. Counting it is how we
      // learn whether the group size is wrong for the loss rate actually on the path.
      if (n > 1) continue;
      const rec = new Uint8Array(p); // copy: parity may be needed again if a member is late
      for (let i = lo; i < hi; i++) {
        if (i === missing) continue;
        const seg = e.parts[i];
        const len = seg.byteLength;
        rec[0] ^= len & 0xff;
        rec[1] ^= (len >> 8) & 0xff;
        for (let k = 0; k < len; k++) rec[PARITY_LEN_HDR + k] ^= seg[k];
      }
      const len = rec[0] | (rec[1] << 8);
      // A length outside the possible range means the parity or a member was corrupt.
      // Splicing it in would produce a frame the decoder accepts and renders as garbage,
      // which is far worse than a dropped frame, so refuse it.
      if (len <= 0 || len > PAYLOAD) { stats.fecUnrepairable++; continue; }
      e.parts[missing] = rec.subarray(PARITY_LEN_HDR, PARITY_LEN_HDR + len);
      e.have++;
      e.par.delete(g);
      did++;
    }
    if (did) stats.fecRepaired += did;
    return did > 0;
  }

  function onMedia(data) {
    const dv = new DataView(data);
    if (dv.getUint8(0) !== VERSION) return;
    const flags = dv.getUint8(1);
    const idx = dv.getUint16(2);
    const count = dv.getUint16(4);
    const gs = dv.getUint8(6);
    const id = dv.getUint32(8);
    const ts = dv.getFloat64(12);
    const wall = dv.getFloat64(20);
    stats.fragsRecv++;
    stats.bytesRecv += data.byteLength;

    // Already decoded or already given up on. Arriving late is not an error — with
    // ordered:false it is the expected case — but it is worth counting, because a high
    // late count with low loss means our give-up deadline is too tight. Parity for a
    // frame that completed without it is excluded: it is redundant by design, not late,
    // and on a clean path it would otherwise bury the signal (measured: 4313 "late" on
    // a run with zero loss, every one of them a parity fragment).
    if (id <= lastDecoded) {
      if (flags & FLAG_PARITY) stats.parityUnused++; else stats.fragsLate++;
      return;
    }

    let e = asm.get(id);
    if (!e) {
      e = {
        parts: new Array(count), par: new Map(), have: 0, count, gs,
        key: !!(flags & FLAG_KEY), ts, wall, at: now(),
      };
      asm.set(id, e);
    }

    if (flags & FLAG_PARITY) {
      if (e.par.has(idx)) return; // duplicate parity
      e.par.set(idx, new Uint8Array(data, HDR));
    } else {
      if (e.parts[idx]) return; // duplicate
      e.parts[idx] = new Uint8Array(data, HDR);
      e.have++;
    }

    if (e.have !== e.count) {
      // Try the parity before giving anything up. This is the whole point of the
      // redundancy: repair costs no round trip, so it happens on arrival.
      if (!tryRepair(e) || e.have !== e.count) { sweep(); return; }
    }

    // Complete. Assemble and decode.
    let total = 0;
    for (const p of e.parts) total += p.byteLength;
    const buf = new Uint8Array(total);
    let o = 0;
    for (const p of e.parts) { buf.set(p, o); o += p.byteLength; }
    asm.delete(id);

    // ── Reference-chain continuity ────────────────────────────────────────────
    // A delta frame is only decodable if the frame it references actually arrived.
    // `frameId` increments once per *encoded* frame, so a skipped capture leaves no gap
    // and any gap here is a genuine loss. Decoding across one produces a picture the
    // decoder reports no error for and a human reads as smeared colour blocks — worse
    // than a held frame, and invisible to every counter. So hold and repair.
    if (e.key) {
      haveKey = true;
    } else if (!haveKey || (lastDecoded >= 0 && id !== lastDecoded + 1)) {
      if (haveKey) stats.framesGapped++;
      haveKey = false;
      requestKey(lastDecoded < 0 ? 'no-reference' : 'gap');
      sweep();
      return;
    }
    lastDecoded = id;

    // Same guard as lane 2's deliver(): with no clock offset yet there is no shared
    // zero point, and `?? 0` made the peer's clock origin look like a several-
    // hundred-ms age that then lived in the p95 for the rest of the call.
    const off = stats.clockOffsetMs;
    if (off != null) {
      const age = now() - (e.wall + off);
      stats.ageMs.push(+age.toFixed(1));
      if (stats.ageMs.length > 900) stats.ageMs.shift();
    }

    try {
      dec.decode(new EncodedVideoChunk({
        type: e.key ? 'key' : 'delta',
        timestamp: ts,
        data: buf,
      }));
      // Tell the sender to ease off if our decoder is the bottleneck. This is the CPU
      // half of the same shock absorber, running on the receiver where it is visible.
      if (dec.decodeQueueSize > 6) ctlSend({ t: 'stall', q: dec.decodeQueueSize });
    } catch (e2) {
      stats.decodeErrors++;
      haveKey = false;
      requestKey('decode-throw');
    }
    sweep();
  }

  // Give up on partial frames. A frame missing a fragment is never going to complete —
  // the media channel does not retransmit — so holding it only costs memory and delays
  // the keyframe request that actually fixes the picture.
  function sweep() {
    if (asm.size === 0) return;
    const t = now();
    // The deadline has to cover the time between a frame's first and last fragment
    // arriving, which is dominated by serialization, not by our patience: a 100 KB
    // keyframe on an 8 Mbps link is 100 ms on the wire alone. The first version used a
    // flat 120 ms and consequently declared keyframes lost that were still arriving.
    // Adding the measured RTT covers a retransmit when `maxRetransmits > 0`.
    const budget = cfg.reassembleMs + (stats.rttMs ?? 0);
    for (const [id, e] of asm) {
      if (t - e.at < budget) continue;
      asm.delete(id);
      stats.framesLost++;
      if (id > lastDecoded) lastDecoded = id;
      // Losing a delta frame breaks every frame that references it, so the only real
      // repair is a keyframe. Losing one is cheap to ask about; losing many is why
      // requestKey is rate-limited.
      requestKey('incomplete');
    }
  }

  // ── Wiring ─────────────────────────────────────────────────────────────────
  function bind(dc) {
    if (dc.label === 'tape-ctl') {
      dcCtl = dc;
      dc.onmessage = (e) => { try { onCtl(e.data); } catch { /* ignore */ } };
      dc.onopen = () => {
        L('tape-ctl-open', {});
        setupEncoder().catch((e) => fail('encoder-setup', e));
        pinger = tickInterval(() => ctlSend({ t: 'ping', a: now() }), 2000);
        ctlSend({ t: 'ping', a: now() });
      };
      dc.onerror = (e) => L('tape-ctl-error', { e: String(e?.error || e).slice(0, 120) });
    } else if (dc.label === 'tape-media') {
      dcMedia = dc;
      dc.binaryType = 'arraybuffer';
      // Frames are only worth sending while they are current, so backpressure has to
      // be visible to admission control rather than absorbed by a growing queue.
      dc.bufferedAmountLowThreshold = cfg.queueBytes;
      dc.onmessage = (e) => { try { onMedia(e.data); } catch { /* one bad datagram is not a call-ending event */ } };
      dc.onopen = () => { L('tape-media-open', {}); pumpCapture().catch((e) => fail('capture', e)); };
      dc.onerror = (e) => L('tape-media-error', { e: String(e?.error || e).slice(0, 120) });
    }
  }

  try {
    if (initiator) {
      // ordered:false + maxRetransmits gives us a datagram lane with a reliability dial.
      // Which setting is right is an open question (a keyframe's value does not expire in
      // 33 ms, a delta frame's does), so it is a parameter to be measured, not guessed.
      bind(pc.createDataChannel('tape-media', {
        ordered: false,
        maxRetransmits: cfg.maxRetransmits,
      }));
      bind(pc.createDataChannel('tape-ctl', { ordered: true }));
    } else {
      const prev = pc.ondatachannel;
      pc.ondatachannel = (e) => {
        try { prev?.call(pc, e); } catch { /* ignore */ }
        if (e.channel.label.startsWith('tape-')) bind(e.channel);
      };
    }
  } catch (e) {
    fail('channels', e);
  }

  return {
    stats,
    adoptTrack,
    snapshot() {
      const a = stats.ageMs, b = stats.qpBytes;
      const pct = (arr, p) => {
        if (!arr.length) return null;
        const s = [...arr].sort((x, y) => x - y);
        return +s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))].toFixed(1);
      };
      const mean = (arr) => (arr.length ? +(arr.reduce((x, y) => x + y, 0) / arr.length).toFixed(1) : null);
      return {
        ...stats,
        ageMs: undefined, qpBytes: undefined,
        ageP50: pct(a, 50), ageP95: pct(a, 95),
        frameBytesMean: mean(b), frameBytesP95: pct(b, 95),
        // Bytes per frame times the frame rate we actually achieved: the honest answer
        // to "what does this quality cost on the wire", which is the question that
        // decides whether fixed-QP is shippable across the globe.
        //
        // `cfg.fps` USED TO BE THE MULTIPLIER, which made this a claim about the ASK rather
        // than a measurement. The moment cfg.fps became settable (72 for a 144 Hz peer), a
        // lane delivering 45 would have reported its bandwidth 60% high — flattering,
        // self-confirming, and wrong in the direction that hides the defect.
        achievedFps: encMeter.fps(),
        askedFps: cfg.fps,
        mbpsAtFps: mean(b) != null && encMeter.fps() != null
          ? +((mean(b) * 8 * encMeter.fps()) / 1e6).toFixed(2) : null,
        buffered: dcMedia?.bufferedAmount ?? null,
        decQueue: dec?.decodeQueueSize ?? null,
        encQueue: enc?.encodeQueueSize ?? null,
        pending: asm.size,
      };
    },
    stop() {
      closed = true;
      pinger?.clear?.();
      try { procReader?.cancel(); } catch { /* ignore */ }
      for (const c of [enc, dec]) { try { c?.state !== 'closed' && c?.close(); } catch { /* ignore */ } }
      try { writer?.close(); } catch { /* ignore */ }
      for (const d of [dcMedia, dcCtl]) { try { d?.close(); } catch { /* ignore */ } }
    },
  };
}

// Feature gate. Called before any of the above so the caller can choose an ordinary
// video track instead — including on the secure-context trap that made the first probe
// of this report every API missing (testbed/wcprobe.mjs).
export function tapeSupported() {
  return typeof VideoEncoder !== 'undefined'
    && typeof VideoDecoder !== 'undefined'
    && typeof MediaStreamTrackProcessor !== 'undefined'
    && typeof MediaStreamTrackGenerator !== 'undefined';
}

// Can we get VideoFrames out of a camera track WITHOUT the breakout box?
// Measured 2026-08-03 in WebKit 26.5 (testbed/wkcaps.mjs): `new VideoFrame(<video>)` on
// a live camera track yields a real 1280x720 NV12 frame, and requestVideoFrameCallback
// is present. Those two together are a complete substitute for the read side of
// MediaStreamTrackProcessor.
export const canShimFrames = () =>
  typeof VideoFrame !== 'undefined'
  && typeof HTMLVideoElement !== 'undefined'
  && 'requestVideoFrameCallback' in HTMLVideoElement.prototype;

/**
 * A frame reader for a camera track, with the same `read()`/`cancel()` contract as
 * MediaStreamTrackProcessor's reader — so the pump loop below does not care which it got.
 *
 * WHY THIS EXISTS: the missing breakout box was the ONLY reason `tapeRtpSupported()` was
 * false in WebKit, and therefore the reason every Safari-family call falls back to plain
 * RTP. That fallback was measured at VMAF 77.6 against this lane's 99.7 (2026-08-01), so
 * one absent API was costing Safari users the entire visually-lossless picture.
 * Everything else the lane needs is present in WebKit 26.5: VideoEncoder, VideoDecoder,
 * RTCRtpScriptTransform (Safari shipped it first), and H.264 High at 1080p.
 *
 * The queue is bounded at 2 and drops the OLDEST. This is a realtime lane: a backlog is
 * staleness, not throughput, and the newest frame is the one worth sending. Dropped
 * frames are CLOSED — an unclosed VideoFrame holds a GPU buffer.
 */
export function frameReader(track) {
  if (typeof MediaStreamTrackProcessor !== 'undefined') {
    return { reader: new MediaStreamTrackProcessor({ track }).readable.getReader(), how: 'mstp' };
  }
  if (!canShimFrames()) throw new Error('no frame source: neither MediaStreamTrackProcessor nor VideoFrame+rVFC');
  const v = document.createElement('video');
  v.srcObject = new MediaStream([track]);
  v.muted = true;
  v.autoplay = true;
  v.playsInline = true;
  // Off-screen but IN the document: a detached element does not present frames, and
  // requestVideoFrameCallback only fires for frames that are presented.
  v.style.cssText = 'position:fixed;left:-9999px;top:0;width:2px;height:2px;opacity:0;pointer-events:none';
  document.body.appendChild(v);
  v.play().catch(() => {});

  const q = [];
  let waiter = null;
  let done = false;
  const MAXQ = 2;
  const finish = () => {
    done = true;
    while (q.length) q.shift().close();
    if (waiter) { const w = waiter; waiter = null; w({ done: true, value: undefined }); }
    try { v.srcObject = null; v.remove(); } catch { /* already gone */ }
  };
  const tick = (_ts, meta) => {
    if (done) return;
    if (track.readyState !== 'live') { finish(); return; }
    let f = null;
    try {
      // `mediaTime` is the capture clock in SECONDS. The pump reads `frame.timestamp`
      // in microseconds to derive capture lag, so the unit has to be preserved or that
      // measurement silently becomes nonsense.
      f = new VideoFrame(v, { timestamp: Math.round((meta?.mediaTime ?? v.currentTime) * 1e6) });
    } catch { /* dimensions not ready yet; the next callback will do */ }
    if (f) {
      if (waiter) { const w = waiter; waiter = null; w({ done: false, value: f }); }
      else { q.push(f); while (q.length > MAXQ) q.shift().close(); }
    }
    v.requestVideoFrameCallback(tick);
  };
  v.requestVideoFrameCallback(tick);

  return {
    how: 'video-rvfc',
    reader: {
      read: () => {
        if (q.length) return Promise.resolve({ done: false, value: q.shift() });
        if (done) return Promise.resolve({ done: true, value: undefined });
        return new Promise((res) => { waiter = res; });
      },
      cancel: async () => finish(),
    },
  };
}

export function tapeRtpSupported() {
  // MediaStreamTrackProcessor is NOT required — frameReader() substitutes for it.
  // MediaStreamTrackGenerator is not required on this lane either: the receive path
  // paints into a canvas and only builds a generator when there is no canvas (see the
  // `if (!ctx2d)` arm below), which is why the old gate was stricter than the code.
  return typeof VideoEncoder !== 'undefined'
    && typeof VideoDecoder !== 'undefined'
    && 'RTCRtpScriptTransform' in window
    && (typeof MediaStreamTrackProcessor !== 'undefined' || canShimFrames());
}

// ── Lane 2: the same encoder over RTP ────────────────────────────────────────
//
// §17.6 ended with the fixed-QP encoder proven and its SCTP lane condemned: loss-based
// congestion control collapses to ~Mathis(RTT, √p) under random loss, and no
// application-layer cleverness can out-run a governor below it. This lane keeps every
// decision of lane 1 — the quantizer, the admission philosophy, the telemetry — and
// swaps the pipe: an RTCRtpScriptTransform on a real video sender replaces libwebrtc's
// encoded payloads with our fixed-QP bytes, so GCC (delay-based, loss-tolerant),
// NACK/RTX, and the pacer all keep working underneath us. rtplane.mjs measured the
// load-bearing unknown first: 238/239 foreign payloads of 60 B–60 KB arrived
// byte-perfect.
//
// The carrier trick: the libwebrtc encoder still runs, because frames only leave when
// it produces one — but its output is discarded on every substitution. So it is scaled
// to low resolution (cheap CPU) at high maxBitrate (GCC probes up and the pacer budget
// fits our real rate). Its bytes are a clock, not a payload.
//
// Three facts rtplane.mjs paid for, honored here:
//   · Chrome ships `e.transformer`, not the spec's `e.transform`.
//   · The depacketizer parses the head of the payload as a codec header: the first
//     10 (key) / 3 (delta) bytes of the carrier frame must survive (VP8's SFrame rule).
//   · The receive transform must be installed synchronously inside ontrack; a few
//     microtasks later and every frame routes around it.
const MAGIC = 0x54415045; // 'TAPE'

// Payload layout after the preserved carrier header (H bytes):
//   u32 MAGIC | u32 frameId | u8 flags (bit0 key, bit1 parity) | u8 groupCount |
//   2B pad | f64 timestampUs | f64 sendWallMs | data
// For parity frames: frameId carries the GROUP BASE (first id of the id-window the
// parity covers), groupCount carries the number of data frames actually covered (the
// first N ids of the window, contiguously), and `data` is
//   u32 lenXOR | u8 flagsXOR | f64 tsXOR | f64 wallXOR | payloadXOR (zero-padded)
// i.e. 21 bytes of XORed scalar fields then the column-XOR of member payloads padded
// to the longest member. XORing ts/wall in lets a recovered frame keep its exact
// media timestamp instead of an interpolation. Keyframes are protected by plain
// duplication (same id sent twice on consecutive carrier ticks) rather than parity:
// the second copy needs no receive-side logic at all.
const L2 = 28;

const l2WorkerSrc = `
  postMessage({ type: 'boot' });
  self.onerror = (m) => postMessage({ type: 'err', e: 'worker: ' + String(m).slice(0, 150) });
  const MAGIC = ${MAGIC};
  // FIFO, never newest-wins: frames the main thread hands over are already encoded,
  // so every one of them is in the decoder's reference chain and must be sent in
  // order. Depth is enforced by the main thread's inFlight gate; the drop counter
  // exists to catch that invariant breaking, not to implement policy.
  let q = [];
  let dropped = 0;
  let bypass = false;    // fallback: pass carrier video through untouched
  let nFromMain = 0, nCarrier = 0, nRecvCarrier = 0;
  // ── FEC (send role) ──────────────────────────────────────────────────────
  // One rolling column-XOR over the tape payloads of a window of fecG consecutive
  // frame ids, emitted as one extra substituted carrier frame when the window
  // closes. Groups are id windows (base = id - id % fecG) so sender and receiver
  // agree on membership without signaling. A frame the FIFO dropped never entered
  // the XOR, so a receiver "repair" of it reconstructs zeroes, fails the length
  // check, and falls back to a keyframe — fail-safe. Keyframes get duplication
  // instead (fecDupKey): the same frame spliced again on the next carrier tick.
  let fecG = 0;            // 0 = disabled until {type:'fec'} arrives
  let fecDupKey = false;
  let fecAcc = new Uint8Array(1 << 18); // 256 KB column-XOR scratch, above the largest fixed-QP frame
  let fecLen = 0;          // longest member payload in the current window
  let fecLenX = 0, fecFlagsX = 0;       // XOR of member lengths / flag bytes
  const fecTsX = new Uint8Array(16);    // XOR of member f64 ts || f64 wall bytes
  const fecTsTmp = new Uint8Array(16);  // per-member scratch (never write fecTsX directly)
  const fecTsDv = new DataView(fecTsTmp.buffer);
  let fecCount = 0, fecBase = 0, fecEmittedBase = -1;
  let fecParityPending = false, fecIdleTicks = 0, fecSent = 0;
  let keyDup = null;       // tape frame message to splice once more (key duplication)
  // §13 stall machine: a shed (or its resume) purges the encoded FIFO and the
  // FEC accumulators. Frames in the FIFO are already encoded, so dropping them
  // would normally be a reference-chain hole — but the RECEIVER asked for this
  // and has already reset its own chain state (it decodes nothing until the
  // post-resume keyframe), so the purge is the spec's "discard every queued
  // frame" executed literally. The purge count goes back so the main thread's
  // inFlight gate can release exactly the slots the FIFO was holding.
  const purgeForShed = () => {
    const n = q.length;
    q = [];
    keyDup = null;
    respliceQ.length = 0;
    fecAcc.fill(0, 0, fecLen);
    fecCount = 0; fecLen = 0; fecLenX = 0; fecFlagsX = 0; fecTsX.fill(0);
    fecParityPending = false; fecEmittedBase = -1; fecIdleTicks = 0;
    postMessage({ type: 'shed-purged', n });
  };
  // §3.1 levers 3+4 (Lane 0): a yield window holds ALL tape bytes off the
  // wire — data, key duplicates, re-splices and pending parity alike — so a
  // voice onset's first PCM frames (lever 3, ~40 ms) or a predicted reply's
  // (lever 4, ~400 ms) meet an empty pipe. Lane B "stalls entirely, never
  // degrades" (§4): carrier ticks pass through untouched (exactly the idle-tick
  // case that already exists), the encoded FIFO absorbs the pause, and the
  // main thread's inFlight gate stops admitting captures within one frame.
  // The deadline is computed on the WORKER's own clock from a duration —
  // worker and main-thread performance.now() bases differ.
  let yieldUntil = 0, yieldTicks = 0;
  // How long a data frame sits in q waiting for a carrier tick it is allowed to
  // ride. This is the probe that decides where the 18.9 ms transport term lives:
  // encode, decode and present are all at their floors, so transport is the only
  // reducible part of glass-to-glass, and two guesses about it have already been
  // wrong (?sendnow=1 changed nothing, a 120 Hz carrier made it worse). Ticks are
  // not simply available -- keyDup, re-splice and parity all outrank q above, so
  // a frame can be bumped past several of them.
  let qWaitSum = 0, qWaitN = 0, qWaitMax = 0;
  let xferSum = 0, xferN = 0, tickSum = 0, tickN = 0;
  // A MEAN hides its own shape. qWaitMax reached 417 ms, so a handful of long
  // stalls can carry an average that no frame actually experiences. Keep a
  // bounded sample of tick waits and report percentiles, so 'reduce the wait'
  // aims at the typical frame or the tail knowingly, not by accident.
  const tickSamp = [];
  // Receive side: sender stamp -> this transform. With age p50 at 12 ms and the
  // tick wait only 2.8 ms, about 9 ms sits after the send transform on a rig
  // with no network at all. This says how much of that is pacer plus wire,
  // and by subtraction how much is worker reassembly and the hop to main.
  const recvSamp = [];
  const pctOf = (arr) => { if (!arr.length) return null; const v = arr.slice().sort((x, y) => x - y);
    const at = (q) => +v[Math.min(v.length - 1, Math.floor(v.length * q))].toFixed(2);
    return { p50: at(0.5), p90: at(0.9), p99: at(0.99) }; };
  // Ticks a pending parity has already yielded to fresh media. Bounds the
  // deferral so redundancy is delayed, never starved.
  let parityHeld = 0, parityDeferred = 0;
  // NOTE for anyone tempted to time the carrier from inside this transform:
  // frame.timestamp here is an RTCEncodedVideoFrame's RTP stamp in 90 kHz units,
  // NOT the wall microseconds written on the VideoFrame. Subtracting it from a
  // wall clock yields nonsense; that probe was tried and removed.
  // #23 retention ring + re-splice queue: the receiver asks for specific lost
  // ids (fragreq) when parity alone cannot close a gap (the parity packet died
  // with its data). Re-spliced frames keep their original id and wire format;
  // they must NOT re-enter the parity XOR (already accumulated on first send).
  // 90 frames ≈ 3 s ≈ 4.5 MB at 50 KB — far past the 250 ms hold window.
  const sentRing = new Map(); // id -> frame message, insertion order = id order
  const respliceQ = [];       // frame messages awaiting a carrier tick
  onmessage = (e) => {
    const m = e.data;
    // The cap must EXCEED the capture gate's inFlight depth plus the encoder
    // queue it can drain during a Lane 0 stall (inFlight 5 + encoder queue
    // ~4, plus margin): the gate drops at capture, before encode, which the
    // reference chain never sees — a drop HERE is an already-encoded frame
    // going missing, a hole the receiver can only repair with a keyframe.
    // 12 keeps the gate the only drop point through a 400 ms pre-stall
    // (~12 frames at 30 fps), which is exactly the case that stressed 6.
    // Stamp ARRIVAL. qWait alone cannot say whether a frame is waiting for a
    // carrier tick or simply waiting to reach this worker at all -- and 31% of
    // ticks go spare, so scarcity does not explain a 17.65 ms wait. Splitting it
    // here separates the postMessage hop (main -> worker, across a thread that
    // is also doing parity XOR and re-splice bookkeeping) from the tick wait.
    if (m.type === 'frame') { m.at = performance.timeOrigin + performance.now(); q.push(m); nFromMain++; if (q.length > 12) { q.shift(); dropped++; } }
    else if (m.type === 'bypass') bypass = true;
    else if (m.type === 'yield') {
      // A new window starts only when the previous one has fully elapsed —
      // overlapping requests (onset during a pre-stall) extend, never stack.
      const t = performance.now();
      yieldUntil = Math.max(yieldUntil, t + Math.max(0, m.ms | 0));
    }
    else if (m.type === 'fec') { fecG = m.group | 0; fecDupKey = (m.keyGroup | 0) >= 1; }
    else if (m.type === 'shed' || m.type === 'resume') purgeForShed();
    else if (m.type === 'resplice') {
      for (const id of m.ids || []) {
        const r = sentRing.get(id);
        if (r && respliceQ.length < 8) respliceQ.push(r);
      }
    }
  };
  onrtctransform = (e) => {
    const tf = e.transform ?? e.transformer;
    const role = tf.options.role;
    postMessage({ type: 'hooked', role });
    const reader = tf.readable.getReader();
    const writer = tf.writable.getWriter();
    (async () => {
      for (;;) {
        const { done, value: frame } = await reader.read();
        if (done) return;
        try {
          if (bypass) { await writer.write(frame); continue; }
          const H = frame.type === 'key' ? 10 : 3;
          if (role === 'send') {
            nCarrier++;
            if (nCarrier % 90 === 1) postMessage({ type: 'tick', carrier: nCarrier, fromMain: nFromMain, hasQ: !!q, fecSent, yieldTicks,
              qWaitAvg: qWaitN ? +(qWaitSum / qWaitN).toFixed(2) : null, qWaitMax: +qWaitMax.toFixed(1), qWaitN,
              xferAvg: xferN ? +(xferSum / xferN).toFixed(2) : null, tickAvg: tickN ? +(tickSum / tickN).toFixed(2) : null,
              tickPct: pctOf(tickSamp),
              parityDeferred });
            const car = new Uint8Array(frame.data);
            if (performance.now() < yieldUntil) {
              // Lane 0 yield: this carrier tick goes out EMPTY (the same
              // no-MAGIC passthrough as an idle tick — the receiver already
              // ignores those). Held frames stay queued in order; the
              // reference chain has no hole, quality is untouched, time is
              // the shock absorber — the lane model's exact contract.
              yieldTicks++;
              await writer.write(frame);
              continue;
            }
            if (car.length >= H && keyDup) {
              // Keyframe duplication. The second copy rides the next carrier tick
              // with the same id; the receiver drops whichever copy arrives second
              // as fragsLate, so no receive-side logic is needed. It must NOT enter
              // the parity XOR (the key is already in there once).
              const m = keyDup;
              keyDup = null;
              const out = new Uint8Array(H + ${L2} + m.buf.byteLength);
              out.set(car.subarray(0, H));
              const dv = new DataView(out.buffer);
              dv.setUint32(H, MAGIC);
              dv.setUint32(H + 4, m.id);
              dv.setUint8(H + 8, m.key ? 1 : 0);
              dv.setUint8(H + 9, 0);
              dv.setFloat64(H + 12, m.ts);
              dv.setFloat64(H + 20, m.wall);
              out.set(new Uint8Array(m.buf), H + ${L2});
              frame.data = out.buffer;
              postMessage({ type: 'sent', dup: true, id: m.id, bytes: out.length });
            } else if (car.length >= H && respliceQ.length) {
              // Receiver-requested re-splice. Outranks parity: it heals a KNOWN
              // hole one RTT old, parity only speculates about the newest group.
              const m = respliceQ.shift();
              const out = new Uint8Array(H + ${L2} + m.buf.byteLength);
              out.set(car.subarray(0, H));
              const dv = new DataView(out.buffer);
              dv.setUint32(H, MAGIC);
              dv.setUint32(H + 4, m.id);
              dv.setUint8(H + 8, m.key ? 1 : 0);
              dv.setUint8(H + 9, 0);
              dv.setFloat64(H + 12, m.ts);
              dv.setFloat64(H + 20, m.wall);
              out.set(new Uint8Array(m.buf), H + ${L2});
              frame.data = out.buffer;
              postMessage({ type: 'sent', retx: true, id: m.id, bytes: out.length });
            } else if (car.length >= H && fecParityPending && (!q.length || parityHeld >= 2)) {
              // MEDIA BEFORE REDUNDANCY -- but never redundancy starved.
              //
              // Parity used to outrank the data queue unconditionally, on the
              // reasoning that it repairs a loss a full RTT sooner than the
              // NACK/RTX underneath. True, and it costs a frame interval of
              // latency to every frame it displaces, which was never measured.
              // It has been now: a carrier tick is 16.7 ms (real rate 59.7/s,
              // capped by display refresh), an unobstructed frame should wait
              // half of one -- 8.3 ms -- and frames were measured waiting
              // 13.8-19.0 ms. That gap IS this branch, and it is the whole
              // reducible part of a 32 ms glass-to-glass, since capture,
              // encode, decode and present are all at their floors.
              //
              // So a fresh frame now goes first. Parity is not dropped, only
              // deferred: 31% of carrier ticks go spare, which is where
              // redundancy belongs. The parityHeld >= 2 test bounds it at two
              // (NOTE: no backticks in this worker source -- it is itself a
              // template literal, and a stray one ends it mid-function. That
              // shipped a syntax error to production for one deploy.)
              // ticks (~33 ms) so a burst of frames cannot starve it -- the
              // repair still lands well inside the RTT it is racing.
              fecParityPending = false;
              parityHeld = 0;
              const out = new Uint8Array(H + ${L2} + 21 + fecLen);
              out.set(car.subarray(0, H));
              const dv = new DataView(out.buffer);
              dv.setUint32(H, MAGIC);
              dv.setUint32(H + 4, fecBase); // group base rides the frameId field
              dv.setUint8(H + 8, 2);        // bit1 = parity
              dv.setUint8(H + 9, fecCount); // members actually covered
              dv.setFloat64(H + 20, performance.timeOrigin + performance.now());
              const pp = H + ${L2};
              out[pp] = (fecLenX >>> 24) & 0xff;
              out[pp + 1] = (fecLenX >>> 16) & 0xff;
              out[pp + 2] = (fecLenX >>> 8) & 0xff;
              out[pp + 3] = fecLenX & 0xff;
              out[pp + 4] = fecFlagsX;
              out.set(fecTsX, pp + 5);
              out.set(fecAcc.subarray(0, fecLen), pp + 21);
              frame.data = out.buffer;
              fecSent++;
              postMessage({ type: 'sent', parity: true, id: fecBase, bytes: out.length });
              fecAcc.fill(0, 0, fecLen);
              fecCount = 0; fecLen = 0; fecLenX = 0; fecFlagsX = 0; fecTsX.fill(0);
              fecEmittedBase = fecBase;
            } else if (q.length && car.length >= H) {
              const m = q.shift();
              // Same wall base main used for m.wall, so this subtraction is a
              // real duration and not two unrelated zeros.
              // A fresh frame just took a tick parity wanted; remember that, so the
              // bound above can force parity through if it happens twice running.
              if (fecParityPending) { parityHeld++; parityDeferred++; }
              const nowW = performance.timeOrigin + performance.now();
              const qw = nowW - m.wall;
              if (qw >= 0 && qw < 1000) { qWaitSum += qw; qWaitN++; if (qw > qWaitMax) qWaitMax = qw; }
              // xfer = main -> worker hop; tick = waiting here for a rideable tick.
              const xf = m.at != null ? m.at - m.wall : null;
              if (xf != null && xf >= 0 && xf < 1000) { xferSum += xf; xferN++; }
              const tw = m.at != null ? nowW - m.at : null;
              if (tw != null && tw >= 0 && tw < 1000) { tickSum += tw; tickN++; }
              if (tw != null && tw >= 0 && tw < 1000) { tickSamp.push(tw); if (tickSamp.length > 600) tickSamp.shift(); }
              fecIdleTicks = 0;
              const out = new Uint8Array(H + ${L2} + m.buf.byteLength);
              out.set(car.subarray(0, H));
              const dv = new DataView(out.buffer);
              dv.setUint32(H, MAGIC);
              dv.setUint32(H + 4, m.id);
              dv.setUint8(H + 8, m.key ? 1 : 0);
              dv.setUint8(H + 9, 0);
              dv.setFloat64(H + 12, m.ts);
              dv.setFloat64(H + 20, m.wall);
              out.set(new Uint8Array(m.buf), H + ${L2});
              frame.data = out.buffer;
              postMessage({ type: 'sent', id: m.id, bytes: out.length, dropped });
              dropped = 0;
              sentRing.set(m.id, m);
              if (sentRing.size > 90) sentRing.delete(sentRing.keys().next().value);
              if (fecDupKey && m.key) keyDup = m;
              // Parity accumulation over the payload bytes just spliced.
              if (fecG > 0) {
                const base = m.id - (m.id % fecG);
                if (base !== fecBase) {
                  // Window boundary crossed: close the previous window. Zero only
                  // what the old window touched before its length is reset.
                  if (fecCount > 1 && fecEmittedBase !== fecBase) fecParityPending = true;
                  fecAcc.fill(0, 0, fecLen);
                  fecCount = 0; fecLen = 0; fecLenX = 0; fecFlagsX = 0; fecTsX.fill(0);
                  fecBase = base;
                }
                const b = new Uint8Array(m.buf);
                if (b.length > fecLen) fecLen = b.length;
                fecLenX ^= b.length;
                fecFlagsX ^= m.key ? 1 : 0;
                fecTsDv.setFloat64(0, m.ts);
                fecTsDv.setFloat64(8, m.wall);
                for (let k = 0; k < 16; k++) fecTsX[k] ^= fecTsTmp[k];
                for (let k = 0; k < b.length; k++) fecAcc[k] ^= b[k];
                fecCount++;
                if (fecCount >= fecG && fecEmittedBase !== fecBase) fecParityPending = true;
              }
            } else if (fecG > 0 && fecCount > 1 && fecEmittedBase !== fecBase) {
              // Idle carrier tick: flush a partial group after two ticks so a pause
              // in captures cannot strand the tail of a group.
              if (++fecIdleTicks >= 2) fecParityPending = true;
            }
            // No pending tape frame: the carrier frame goes as-is. The receiver sees
            // no MAGIC and ignores it — a tick with no payload, not a corruption.
            await writer.write(frame);
          } else {
            nRecvCarrier++;
            if (nRecvCarrier % 90 === 1) postMessage({ type: 'tick', side: 'recv', carrier: nRecvCarrier, recvPct: pctOf(recvSamp) });
            const buf = new Uint8Array(frame.data);
            if (buf.length >= H + ${L2}) {
              const dv = new DataView(frame.data);
              if (dv.getUint32(H) === MAGIC) {
                const wallSent = dv.getFloat64(H + 20);
                const rl = (performance.timeOrigin + performance.now()) - wallSent;
                if (rl >= 0 && rl < 1000) { recvSamp.push(rl); if (recvSamp.length > 600) recvSamp.shift(); }
                const data = frame.data.slice(H + ${L2});
                postMessage({
                  type: 'recv', id: dv.getUint32(H + 4), flags: dv.getUint8(H + 8),
                  n: dv.getUint8(H + 9), key: !!(dv.getUint8(H + 8) & 1),
                  ts: dv.getFloat64(H + 12), wall: dv.getFloat64(H + 20), buf: data,
                }, [data]);
              }
            }
            // Written through regardless: the carrier decoder must keep receiving
            // *something* or the jitter buffer stalls and takes RTCP feedback quality
            // with it. Its garbage output is never rendered.
            await writer.write(frame);
          }
        } catch (err) { postMessage({ type: 'err', e: String(err).slice(0, 160) }); }
      }
    })();
  };
`;

/**
 * Phase A: create the transform worker and attach the sender transform, immediately
 * after addTrack, before anything else touches the pc. Bisected to matter: the same
 * attach a few hundred ms later — after signaling setup — left the transform hooked
 * but starved, while this timing (validated as `?tapemin=1`) flows at full rate.
 * Everything here must be inert until phase B arms it: with no pending frames the
 * worker passes carrier frames through untouched.
 */
// `cfg` is here for ONE value: the carrier's tick ceiling has to be decided at
// captureStream() time and cannot be raised afterwards, and it is a function of the frame
// rate the lane intends to send. Defaulted so an older caller still gets the old behaviour.
/**
 * Rate over a RECENT WINDOW, not over the whole call.
 *
 * A call average folds in the pacer's opening ramp — the part that is least representative —
 * and it cannot show a lane that kept up for thirty seconds and then stopped. Both lanes use
 * this for the one number that decides whether a frame-rate change did anything at all.
 */
function fpsMeter(cap = 240) {
  const at = [];
  return {
    note: () => { at.push(performance.now()); if (at.length > cap) at.shift(); },
    fps: () => {
      if (at.length < 8) return null;
      const span = (at[at.length - 1] - at[0]) / 1000;
      return span > 0.5 ? +((at.length - 1) / span).toFixed(1) : null;
    },
  };
}

export function prepareTapeRtp(pc, track, log, cfg = {}) {
  const L = (tag, d) => { try { log?.(tag, d); } catch { /* never break the call */ } };
  try {
    const worker = new Worker(URL.createObjectURL(new Blob([l2WorkerSrc], { type: 'text/javascript' })));
    worker.onerror = (e) => L('tape-worker-err', { e: 'spawn: ' + String(e.message || e).slice(0, 150) });
    // The carrier rides its OWN sendonly transceiver, so the peer's video arrives on a
    // separate recvonly one. Measured (rtplane.mjs --applike=bidir): put both transforms
    // on one sendrecv transceiver and the receive transform hooks but never sees a
    // frame, while the send side substitutes happily. One direction per m-line.
    // The answerer's sendonly transceiver matches the recvonly slot the offerer puts in
    // the first offer (app.js 'tape.slot'), so its video starts with the first answer —
    // no renegotiation round trip, and no race window at real RTTs. The guarded
    // reoffer in app.js remains as the fallback if that matching ever changes.
    // The carrier runs on a CLONE of the camera track, constrained down to thumbnail
    // resolution — the clone keeps the tape encoder's own input at full 1080p while
    // the carrier encodes something cheap. This replaces setParameters entirely:
    // scaleResolutionDownBy and maxBitrate both required a runtime setParameters, and
    // a runtime setParameters on this sender kills the transform in every timing we
    // measured (pre-negotiation, post-media on a timer, post-first-substitution). The
    // pacer budget that maxBitrate used to raise comes from SDP instead (b=AS, munged
    // in app.js) — negotiated state, so nothing is mutated after the pipeline exists.
    // The carrier's pixels are irrelevant — it is a clock. ONE TICK CARRIES ONE TAPE
    // FRAME, so the tick rate is a hard ceiling on the delivered frame rate, and the
    // former `setInterval(16)` + `captureStream(60)` pair put that ceiling at ~45 fps.
    //
    // MEASURED 2026-08-03 on the real display at 144.9 Hz (`testbed/carriertick.mjs`),
    // counting frames the wire would actually see (rVFC on a <video> fed by the stream):
    //
    //   setInterval(16) + captureStream(60)    59.7 ticks/s   <- what shipped
    //   setInterval(16) + captureStream(120)   61.9 ticks/s   <- the FLICKER was binding
    //   setInterval(4)  + captureStream(120)  119.6 ticks/s
    //   rAF flicker     + captureStream(120)  119.7 ticks/s
    //   rAF flicker     + captureStream()     143.6 ticks/s   <- follows the refresh rate
    //   no flicker      + captureStream(120)    0   ticks/s   <- the flicker is load-bearing
    //
    // So there were two ceilings stacked, and asking for a higher rate alone did nothing:
    // captureStream only emits when the canvas CHANGES, and a 16 ms timer can only dirty it
    // 62.5 times a second. The flicker now runs on requestAnimationFrame, which is the
    // compositor's own clock and therefore the fastest a canvas can possibly be captured.
    //
    // A CONSEQUENCE WORTH KNOWING: that clock is the SENDER's display refresh, so a sender
    // on a 60 Hz panel cannot carry more than ~60 fps to a 144 Hz peer through a canvas
    // carrier, whatever the camera can do. `targetFps()` in app.js accounts for it.
    //
    // rAF does not fire in a hidden tab, so the timer stays as a floor — a backgrounded
    // sender keeps ticking (throttled) instead of going to zero. Both call the same paint;
    // double-dirtying is free because captureStream cannot emit faster than the compositor.
    //
    // Idle ticks pass the raw thumbnail through: static-content P-frames are tens of bytes,
    // so ~144 empty ticks/s is roughly 57 kbps and 4.6% of a core at the measured
    // 0.32 ms/frame — the reason a generous ceiling is affordable rather than tuned.
    const canvas = document.createElement('canvas');
    // ?ccw=N sizes the carrier's dummy picture. Its CONTENT is irrelevant -- the
    // payload is replaced in the transform -- so the only thing this width buys
    // is the cost of encoding it, which sits directly in the send path. 320 was
    // chosen when the carrier was compositor-bound and its encode cost was
    // hidden behind a 16.7 ms tick; now that the tick is gone, that cost is
    // exposed and worth measuring.
    const ccw = Number(cfg.l2CarrierW);
    const cw = Number.isFinite(ccw) && ccw >= 16 && ccw <= 640 ? Math.round(ccw / 16) * 16 : 320;
    canvas.width = cw; canvas.height = Math.round(cw * 9 / 16);
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    let flick = false;
    const dirty = () => {
      flick = !flick;
      ctx.fillStyle = flick ? '#000' : '#101010';
      ctx.fillRect(0, 0, 1, 1);
    };
    tickInterval(dirty, 16); // worker clock (#65): the hidden-tab floor must not itself be clamped
    // Twice the data rate covers the tick that each parity fragment spends. Asked, not
    // guaranteed: the compositor caps it at the display refresh regardless.
    // ?ctickhz=N overrides the tick rate. It exists because the carrier tick is
    // the largest remaining term in glass-to-glass and nothing else can test it.
    //
    // The decomposition (live prod, 2026-08-14): capture 0.1 + encode 3.2 +
    // TRANSPORT 18.9 + decode 1.3 + present 8.8 = 32.3 ms. Encode, decode and
    // present are at their floors (present 8.8 ms is half a 60 Hz refresh), so
    // transport is the whole reducible budget -- and on a rig where the audio
    // lane shows 2.2 ms on the same wire, 18.9 ms is not the wire.
    //
    // Its DISTRIBUTION names it: age p50 18.0, p95 33.5, against a 33.3 ms
    // frame interval. A uniform wait on a periodic tick predicts p50 = half the
    // period and p95 = 0.95 of it -- 16.7 and 31.6 for 30 Hz. That is a frame
    // sitting until the carrier next ticks. (?sendnow=1 does NOT fix it:
    // 3072 requestFrame calls moved age 18.9 -> 18.0, i.e. nothing.)
    //
    // If the wait is the tick, halving the period halves the wait. This is the
    // lever that tests that claim and, if it holds, is also the fix.
    // ?ctickhz=0 is MANUAL CARRIER, and it is the one that matters.
    //
    // Every auto-tick rate loses the same way: captureStream(N) emits on the
    // compositor's clock, so a frame that finishes encoding must wait for the
    // next tick -- 8.35 ms if its phase were random, 13.8-19.0 ms as measured,
    // because encode and compositor are driven by the same clock and their
    // phases are correlated. Raising N does not help: the display caps emission
    // near 60/s, so ?ctickhz=120 only burned CPU and made it WORSE (21.1 ms).
    //
    // captureStream(0) emits NOTHING on its own -- a frame appears only when
    // requestFrame() asks. So the tick stops being something to wait for and
    // becomes something the encoder triggers, and the wait is not shortened but
    // DELETED. Ordering is safe: main->worker postMessage measured 0.03 ms
    // against a requested tick reaching the transform ~5 ms later, so the queue
    // is always populated first.
    // Number(null) is 0, not NaN -- so reading the flag naively made an ABSENT
    // ctickhz look exactly like ctickhz=0 and put every default call into manual
    // carrier mode by accident. Guard the null before coercing.
    const askedHz = cfg.l2CarrierHz == null ? NaN : Number(cfg.l2CarrierHz);
    const manualCarrier = askedHz === 0;
    const carrierTicksAsked = cfg.l2FastCarrier === false
      ? 60
      : manualCarrier
        ? 0
        : Number.isFinite(askedHz) && askedHz >= 60 && askedHz <= 240
          ? Math.round(askedHz)
          : Math.min(240, Math.max(60, (cfg.fps || 30) * 2));
    // The rAF spin exists to lift ticks past the interval floor (~59.7/s measured
    // above) — needed only when the lane wants MORE than 60. When the negotiated
    // fps fits under the floor, spinning at display refresh buys zero extra ticks
    // (captureStream caps emission at `carrierTicksAsked` anyway) and costs real
    // energy: ~3% of total call CPU on a 144 Hz display (energy.mjs A/B,
    // 2026-08-05, `?ctick=0` arm). The lobby's getUserMedia fixes the camera fps
    // for the whole call, so this decision cannot go stale mid-call.
    if (cfg.l2FastCarrier !== false && carrierTicksAsked > 60) {
      const spin = () => { dirty(); requestAnimationFrame(spin); };
      requestAnimationFrame(spin);
    }
    // ── the carrier track ───────────────────────────────────────────────────
    // ?ctrack=gen replaces canvas capture with a MediaStreamTrackGenerator.
    //
    // THE REASON, measured rather than assumed. A canvas carrier cannot emit
    // faster than the compositor, and no setting escapes that:
    //   auto 60 Hz          tick wait 13.8-19.0 ms
    //   ?ctickhz=120        WORSE (21.1 ms) -- display caps emission near 60/s
    //   ?ctickhz=0 + requestFrame per frame   16.3/10.9 ms, i.e. no better
    // The last one is the proof. In manual mode the carrier ran at 67.8 ticks/s
    // against ~62 from the service interval alone, even though 30 extra frames
    // per second were requested: the compositor COALESCES requestFrame calls
    // into its own frame boundary. Canvas capture is compositor-bound, full
    // stop, and roughly half a refresh of latency is the price of admission.
    //
    // A track generator has no compositor in it. Writing a VideoFrame delivers
    // it to the sink immediately, so the encoder drives the wire directly and
    // the tick wait is not shortened but removed. Feature-detected, because the
    // fallback is simply today's behaviour.
    const genMode = cfg.l2CarrierTrack === 'gen' && typeof MediaStreamTrackGenerator === 'function';
    let carrierTrack, emitCarrier;
    if (genMode) {
      const gen = new MediaStreamTrackGenerator({ kind: 'video' });
      const gw = gen.writable.getWriter();
      carrierTrack = gen;
      emitCarrier = () => {
        try {
          // ABSOLUTE wall microseconds, not performance.now(). The carrier's own
          // timestamps are never read as media time -- the receiver anchors on
          // the capture timestamp carried INSIDE the payload -- which frees them
          // to carry a measurement instead: the send transform subtracts this
          // from its own wall clock to get the carrier's encode+delivery
          // latency, the last unnamed term in glass-to-glass. Main and worker
          // have different performance origins, so only an absolute stamp is
          // subtractable across that boundary.
          gw.write(new VideoFrame(canvas, {
            timestamp: Math.round((performance.timeOrigin + performance.now()) * 1000),
          }));
        } catch { /* a carrier hiccup must never take the call down */ }
      };
      // Parity, keyframe duplicates and re-splices are not triggered by an
      // encode, so they still need ticks of their own. Same ~60 Hz the auto
      // carrier ran at, so redundancy and GCC's view of the stream are
      // unchanged; the only difference is that a DATA frame no longer waits.
      // ?csvc=N sets that period. At 16 ms this puts ~62 idle carrier frames a
      // second into the same encoder the data frames use, so every data frame
      // may queue behind one. Redundancy needs far fewer ticks than that -- the
      // question is whether the contention is what is left of the wait.
      const svc = Number(cfg.l2CarrierSvcMs);
      const svcMs = Number.isFinite(svc) && svc >= 8 && svc <= 200 ? Math.round(svc) : 16;
      tickInterval(() => { dirty(); emitCarrier(); }, svcMs);
    } else {
      carrierTrack = canvas.captureStream(carrierTicksAsked).getVideoTracks()[0];
      emitCarrier = () => {
        try { carrierTrack.requestFrame?.(); } catch { /* older Chrome: auto cadence carries on */ }
      };
      if (manualCarrier) tickInterval(() => { dirty(); emitCarrier(); }, 16);
    }
    L('carrier-ticks', { asked: carrierTicksAsked, manual: manualCarrier,
      fastFlicker: cfg.l2FastCarrier !== false && carrierTicksAsked > 60,
      cfgFps: cfg.fps, settings: carrierTrack.getSettings?.() ?? null });
    const tx = pc.addTransceiver(carrierTrack, { direction: 'sendonly' });
    // ?maxbr=N (kbps) lifts the sender's ceiling so the PACER can run faster.
    //
    // The last big term in glass-to-glass is 9.0 ms between the send transform
    // and the receive transform -- on a rig where both browsers are on one
    // machine and the audio lane's RTT is 0.24 ms, so it is not the wire. It is
    // serialization: availableOutgoingBitrate measured 5.5-6.3 Mbps, and a
    // 14.7 KB frame paced at roughly that rate takes about 9 ms.
    //
    // The estimate is low for a reason worth stating: congestion control can
    // only estimate from what it has seen sent, and we send 3.5 Mbps, so it
    // settles just above that. Raising the ceiling is what makes Chrome probe
    // upward. It cannot invent capacity -- GCC still backs off on a link that
    // cannot carry it -- so this buys speed on a fat link and changes nothing
    // on a thin one.
    const maxbrKbps = Number(cfg.l2MaxBitrateKbps);
    if (Number.isFinite(maxbrKbps) && maxbrKbps > 0) {
      try {
        const prm = tx.sender.getParameters();
        prm.encodings = prm.encodings && prm.encodings.length ? prm.encodings : [{}];
        prm.encodings[0].maxBitrate = Math.round(maxbrKbps * 1000);
        tx.sender.setParameters(prm).catch(() => { /* a ceiling is a hint, never a requirement */ });
      } catch { /* older stacks: the pacer keeps its own counsel */ }
    }
    tx.sender.transform = new RTCRtpScriptTransform(worker, { role: 'send' });
    // ?cprobe=1 — diagnostic: name the stage that can starve the carrier encoder
    // (clone dead vs pacer starvation vs transform backpressure). Read-only.
    if (new URLSearchParams(location.search).get('cprobe') === '1') {
      carrierTrack.addEventListener('mute', () => L('carrier-probe', { ev: 'mute' }));
      carrierTrack.addEventListener('unmute', () => L('carrier-probe', { ev: 'unmute' }));
      carrierTrack.addEventListener('ended', () => L('carrier-probe', { ev: 'ended' }));
      setInterval(() => {
        L('carrier-dir', {
          dir: tx.direction, cur: tx.currentDirection, mid: tx.mid, stopped: tx.stopped,
          track: tx.sender.track === carrierTrack ? 'clone' : String(tx.sender.track),
          rs: carrierTrack.readyState, muted: carrierTrack.muted,
        });
        tx.sender.getStats().then((rs) => {
          let any = false;
          rs.forEach((s) => {
            if (s.type === 'outbound-rtp') {
              any = true;
              L('carrier-probe', {
                kind: s.kind ?? s.mediaType, ssrc: s.ssrc, active: s.active,
                fe: s.framesEncoded, fs: s.framesSent, ql: s.qualityLimitationReason, b: s.bytesSent,
              });
            }
          });
          if (!any) L('carrier-probe', { none: true });
        }).catch(() => {});
      }, 2000);
    }
    // The answerer's sendonly transceiver matches NOTHING in the offer — measured
    // (lane2-slot5): Chrome gave both offered video sections FRESH transceivers and
    // left this one unassociated no matter the offered direction, so the carrier
    // missed the first answer and had to ride a reoffer, whose answer then vanished
    // between relay and delivery — silently, killing the answerer's carrier for the
    // whole call. So the answerer claims the offer's carrier slot by hand: move the
    // carrier track and the send transform onto the slot's transceiver before
    // createAnswer, and stop the orphan before it can negotiate a second video
    // stream. The attach still precedes the transceiver's first negotiation, so the
    // pipeline is never built without the transform (the law the setup-time attach
    // above exists for). Returns true when the first answer will carry the carrier.
    let claimed = false;
    let claimedSlot = null;
    const claimSlot = async (offerSdp) => {
      if (claimed) return true;
      const text = String(offerSdp ?? '');
      const videoSecs = [...text.matchAll(/^m=video [^\r\n]*$/gm)];
      if (videoSecs.length < 2) return false; // no slot offered — the reoffer fallback stays
      const tail = text.slice(text.lastIndexOf(videoSecs.at(-1)[0]));
      const mid = tail.match(/^a=mid:(.*)$/m)?.[1]?.trim();
      const slot = pc.getTransceivers().find((t) => t.mid === mid);
      if (!slot || slot.sender.track) return false;
      slot.direction = 'sendonly';
      // The transform goes on BEFORE the track: replaceTrack is what builds the
      // sender's pipeline, and it reads sender.transform at build time — attach
      // after and every frame routes around the transform forever (measured,
      // lane2-claim3: hooked yet bypassed, 447 raw carrier frames sent, 0 ticks).
      slot.sender.transform = new RTCRtpScriptTransform(worker, { role: 'send' });
      await slot.sender.replaceTrack(carrierTrack);
      // Neutralize the orphan WITHOUT stopping it. tx.stop() did two measured harms
      // (lane2-claim2): it starved the slot's encoder — the clone feeds both senders,
      // and stopping one killed the frame flow to the other — and its negotiationneeded
      // was never settled by any offer, looping the reoffer ~1000x in 15 s. Emptying
      // the orphan instead (no track, receive-only) lets the one guarded reoffer
      // negotiate it as a medialess section and settle for good.
      try {
        await tx.sender.replaceTrack(null);
        tx.direction = 'recvonly';
      } catch { /* neutralization is hygiene, not correctness */ }
      // The carrier must be VP8 (its packetizer treats payloads as opaque; H264's
      // mangles them — rtplane.mjs). The slot's transceiver never saw app.js's
      // codec-pref pass, which keys on sender.track at setup. Setting preferences
      // is safe here: the transceiver has never been negotiated, so no pipeline
      // exists to rebuild.
      const caps = RTCRtpSender.getCapabilities?.('video');
      if (slot.setCodecPreferences && caps?.codecs) {
        const rank = (c) => {
          const n = (c.mimeType || '').toLowerCase();
          if (n.includes('vp8')) return 0;
          if (/rtx|red|ulpfec|flexfec/i.test(n)) return 9;
          return 5;
        };
        slot.setCodecPreferences([...caps.codecs].sort((a, b) => rank(a) - rank(b)));
      }
      try { tx.stop(); } catch { /* never negotiated; stopping is bookkeeping */ }
      claimed = true;
      claimedSlot = slot;
      L('tape-slot-claimed', { mid });
      return true;
    };
    return {
      worker, carrierTrack, claimSlot, carrierTicksAsked,
      // The encoder calls this to put a frame on the wire. With a track
      // generator it IS the transport; with a canvas it is a requestFrame hint
      // the compositor may coalesce away.
      emitCarrier, genMode,
      // The sender the carrier actually flows through: the claimed slot after a
      // claim, the original transceiver before it. The fallback needs it to put
      // the camera track where the carrier clock used to be.
      getCarrierSender: () => claimedSlot?.sender ?? tx.sender,
    };
  } catch (e) {
    L('tape-fail', { lane: 'rtp', why: 'prepare', error: String(e).slice(0, 160) });
    return null;
  }
}

/**
 * ── §6.1 phase 4: ONE encoder, N transport halves ────────────────────────────
 *
 * A naive mesh runs one whole `startTapeRtp` per peer: two encoders, two
 * carriers, two governors. That is 2x encode CPU on a device where the encoder
 * is already the next ceiling behind capture, and it doubles the `configure()`
 * churn #44's rate control is careful about. The shipped shape instead keeps ONE
 * capture->admission->encode chain and hands every encoded chunk to both peers'
 * transport halves — each with its own carrier substitution, its own FEC window,
 * its own re-splice ring, its own ctl channel and its own AIMD governor.
 *
 * What that costs, stated in the product's own voice rather than hidden: in a
 * 3-person call **the person on the worst connection sets the video quality
 * everyone sends**. The reference chain is shared, so a frame skipped for one
 * peer is skipped for both — there is no such thing as a per-peer drop once one
 * bitstream feeds two decoders. Hence:
 *
 *   · admission is the MIN over the peers' governors (`admitRate`), and a frame
 *     is admitted only when EVERY half has an in-flight slot for it,
 *   · rate control spends the MIN budget across the peers' paths,
 *   · duress is the MAX across the audio lanes (app.js's callback already fans;
 *     `rcPollBudget` consumes whatever it returns, unchanged),
 *   · a keyframe request from EITHER peer arms the one encoder,
 *   · a shed from EITHER peer stops admission for both.
 *
 * `?l23enc=2` is the control arm and needs nothing here: it simply builds two
 * whole `startTapeRtp` instances with `link` null, which is today's code.
 *
 * THE FLAG-OFF PROPERTY, which is the reason this is a separate object rather
 * than a rewrite of the instance: with `link` null every aggregate reader in
 * `startTapeRtp` returns that instance's own value, so a 1:1 call runs the same
 * encoder config, the same governor, the same wire bytes. Nothing branches on
 * "are we three" inside the hot path; it branches on whether a link exists.
 */
export function createTapeLink() {
  const halves = new Set();
  let owner = null;
  // The encoder's own self-description (`cfg`, `rot`). One encoder means one
  // description, and a half whose ctl channel opens AFTER the encoder started
  // would otherwise never hear it — its peer would sit with no decoder for the
  // rest of the call. Replayed at that half's arm.
  const desc = { cfg: null, rot: null };
  return {
    size: () => halves.size,
    join(h) { halves.add(h); return halves.size; },
    leave(h) {
      halves.delete(h);
      if (owner !== h) return;
      owner = null;
      // The encode half went with the pair that left. Hand it to a survivor
      // rather than leaving the room's remaining leg with no picture.
      for (const o of halves) { owner = o; o.startEncodeHalf(); break; }
    },
    /** First half to arm owns the encode chain; the rest are transport-only. */
    claimEncoder(h) { if (!owner) owner = h; return owner === h; },
    isOwner: (h) => owner === h,
    /** §6.1: min over the peers' governors. `fallback` is used with no halves. */
    admitRate(fallback) {
      let v = Infinity;
      for (const h of halves) v = Math.min(v, h.admitRate());
      return Number.isFinite(v) ? v : fallback;
    },
    /** Admit only when every half has a slot: max of the per-peer depths. */
    inFlight(fallback) {
      let v = -1;
      for (const h of halves) v = Math.max(v, h.inFlight());
      return v < 0 ? fallback : v;
    },
    remoteReady(fallback) {
      if (!halves.size) return fallback;
      for (const h of halves) if (!h.remoteReady()) return false;
      return true;
    },
    shedded(fallback) {
      if (!halves.size) return fallback;
      for (const h of halves) if (h.shedded()) return true;
      return false;
    },
    /** Rate control follows the worst peer, for the shared-chain reason above. */
    budgetMbps(fallback) {
      let v = Infinity;
      for (const h of halves) { const b = h.budgetMbps(); if (b != null) v = Math.min(v, b); }
      return Number.isFinite(v) ? v : fallback;
    },
    /** A keyframe request from any peer arms the one encoder. */
    wantKey() { owner?.setWantKey(); },
    /**
     * One encoded frame, N transports. Each worker gets its OWN copy: the buffer
     * is transferred to the owner's worker (detached on arrival), and each half
     * keeps its own FEC accumulator and retention ring over it.
     */
    fanEncoded(from, msg) {
      for (const h of halves) {
        if (h === from) continue;
        try { h.acceptEncoded({ ...msg, buf: msg.buf.slice(0) }); } catch { /* one peer's transport is not the other's */ }
      }
    },
    fanDesc(from, o) {
      if (o?.t === 'cfg' || o?.t === 'rot') desc[o.t] = o;
      for (const h of halves) { if (h !== from) h.ctlSend(o); }
    },
    replayDesc(h) { for (const k of ['cfg', 'rot']) { if (desc[k]) h.ctlSend(desc[k]); } },
  };
}

/**
 * Phase B — same contract as startTapeVideo, but the caller must:
 *   · have added the video track to the pc (the carrier),
 *   · pass the `pre` handle from prepareTapeRtp (phase A),
 *   · call .attachReceiver(receiver) SYNCHRONOUSLY inside ontrack for the video track,
 *     and mutate no receiver property on that video receiver afterwards,
 *   · and on the non-initiating side, route the 'tape-ctl-rtp' datachannel from
 *     ondatachannel into .adoptCtl(channel).
 */
export function startTapeRtp({ pc, track, initiator, pre, cfg, onRemote, log, onFail, displayCanvas, avsync = null, onStall = null, duress = null, audioBps = null, link = null }) {
  const L = (tag, d) => { try { log?.(tag, d); } catch { /* never break the call */ } };
  const fail = (why, e) => {
    L('tape-fail', { lane: 'rtp', why, error: e ? String(e).slice(0, 160) : null });
    try { onFail?.(why); } catch { /* ignore */ }
  };

  const encMeter = fpsMeter();
  const stats = {
    framesIn: 0, framesEncoded: 0, framesSkipped: 0,
    skipBuffered: 0, skipEncQueue: 0, skipDecodeStalled: 0,
    bytesSent: 0, fragsSent: 0, keyframesSent: 0, keyReqRecv: 0,
    encQueuePeak: 0, bufferedPeak: 0,
    reconfigs: 0, reconfigFails: 0, // encoder followed / failed to follow a camera resize
    trackSwaps: 0,                  // pump re-attached to a new camera (flip / re-acquire)
    paritySent: 0, parityBytes: 0,
    framesOut: 0, fragsRecv: 0, bytesRecv: 0,
    framesLost: 0, fragsLate: 0, keyReqSent: 0, decodeErrors: 0,
    fecRepaired: 0, fecUnrepairable: 0, framesGapped: 0, parityUnused: 0,
    fecHoldExpired: 0, // gaps the parity window could not close before l2FecHoldMs
    keyDupsSent: 0, // protective second copies of keyframes (l2FecKey >= 1)
    retxSent: 0, // frames re-spliced from the retention ring on a peer's fragreq
    fragReqSent: 0, // missing-frame ids this side asked the peer to re-splice
    fragReqRecv: 0, // fragreq messages received from the peer
    carrierDropped: 0, // encoded tape frames superseded before a carrier tick arrived
    skipPaced: 0, // captures the AIMD pacer withheld (invisible to the reference chain)
    skipBytePaced: 0, // captures the byte brake withheld (QP pinned AND over budget)
    rcResShrink: 1, // encode-resolution divisor the rc actuator is applying now
    linkScale: 1, // #61 proactive budget-derived resolution scale (1 = untouched)
    // #61 resolution truth. The ENCODE size is recomputed every frame and was
    // kept only in a closure, so every instrument reported TAPE_CFG — the
    // CEILING — instead. camW/camH is the sensor; encW/encH is what the encoder
    // was actually configured to, i.e. min(camera, ceiling) after rcResShrink.
    // Without both, a CEILING of 3420x2136 is indistinguishable from an ENCODE
    // of 3420x2136, and those two call for opposite fixes.
    camW: null, camH: null, // camera frame size, per encode loop
    encW: null, encH: null, // encoder config size — the real pixels on the wire
    pfMs: null, pfFrames: 0, pfFallbacks: 0, // presence filter: cost, output, declines
    pfStillMean: null, // 0..1 mean stillness — how much of the picture is held
    pfHoldThresh: null, // the lock threshold in luma, after upward adaptation

    sendNowReqs: 0, // ?sendnow=1: carrier ticks requested at encode output (task #41)
    admitFps: null, // last AIMD admission rate, frames/s — the pacer-following signal
    // #44 rate control. rcEstMbps is the raw GCC estimate, rcBudgetMbps what the
    // controller was allowed to spend after headroom and clamping, rcQp the live
    // quantizer, rcTargetBytes the per-frame budget it is steering toward. All
    // null on ?l2rc=0.
    rcQp: null, rcBudgetMbps: null, rcEstMbps: null, rcDuress: 0, rcTargetBytes: null, rcVbrBps: null,
    rateControl: null, // 'quantizer' | 'vbr' — a VBR call must never be read as fixed-QP
    // Lane 0 (§3.1 levers 3+4): onset yields (lever 3) and prediction
    // pre-stalls (lever 4b) — window counts and total requested ms, plus the
    // worker-side count of carrier ticks that went out empty because of them.
    l0Yields: 0, l0YieldMs: 0, l0PreStalls: 0, l0PreStallMs: 0, l0YieldTicks: 0,
    // §12–13 stall machine. Receiver side: shedSent/resumeSent (ctl out),
    // shedSkipped (frames dropped while VIDEO HELD), lp* (lane P stills in).
    // Sender side: shedRecv/resumeRecv (ctl in), skipShed (captures passed
    // over while shed), shedDroppedEnc (frames encoded through the shed
    // transition, dropped unsent), shedPurged (worker FIFO discards).
    skipShed: 0, shedSkipped: 0, shedPurged: 0, shedDroppedEnc: 0,
    // in-flight keyframes that arrived while held before any resume was sent —
    // the ones that used to end the hold early and strand the peer shedded.
    shedStaleKey: 0, shedDeadman: 0,
    shedSent: 0, shedRecv: 0, resumeSent: 0, resumeRecv: 0,
    lpSent: 0, lpBytes: 0, lpRecv: 0, lpPainted: 0, lpAgeMs: [],
    rttMs: null, clockOffsetMs: null, ageMs: [], qpBytes: [],
    encBytesTotal: 0, encFramesTotal: 0, // cumulative; see the lossless lane's note
    // ── #14 glass-to-glass decomposition probes ─────────────────────────────
    // The age clock above starts at ENCODE OUTPUT. The slices outside it:
    //   capLagMs    sender: capture timestamp → our code reads the frame
    //   encLatMs    sender: encode() call → encoded chunk out
    //   fullAgeMs   receiver: capture timestamp (sender clock, offset-corrected)
    //               → decode output — the whole pipeline except display
    //   presentLagMs receiver: decode output → <video> presents the frame
    // VideoFrame.timestamp flows capture→encoder→chunk→packet→decoder→frame
    // untouched, so the receiver sees the sender's capture clock directly.
    capLagMs: [], encLatMs: [], fullAgeMs: [], presentLagMs: [],
    presentAt: [], // #33: now() at every presented frame — the IPI stream the gate reads
  };
  const encCallAt = []; // FIFO of encode() call times, drained by onEncoded
  const decOutAt = [];  // FIFO of decode-output times, drained by the rVFC probe
  // #14 clock bases, measured not assumed (cap1: the camera's VideoFrame
  // timestamp is a small media-pipeline clock, NOT now()'s base — raw
  // subtraction read 1.785e12 ms). The sender measures its own media-clock
  // offset once and ships it on the 1 s age report; the receiver needs it to
  // turn a frame's capture timestamp into wall age.
  let mco = null;     // now() - captureTimestamp/1000, captured at first frame
  // #75 the bound past which a capture "lag" is a stalled media clock rather than
  // a deep pipeline. See the re-anchor in pumpCapture for the measurement that
  // set it: real pipelines here read 0.1-0.5 ms, the broken one read 42,933.
  const MCO_MAX_LAG = cfg.mcoMaxLagMs ?? 150;
  let peerMco = null; // the same quantity for the peer's camera, via ctl

  let closed = false;
  let enc = null, dec = null, gen = null, writer = null;
  // Presence filter (presence-filter.js): one GPU pass that removes grain where
  // nothing moved and softens only what the eye cannot resolve, so the SAME
  // encoder at the SAME quantizer spends fewer bits. Loaded lazily and
  // dynamically on purpose — a bitrate experiment must not be able to keep the
  // lane's module from loading at all.
  // pfWanted is a live knob, not a start-up constant, so the filter can be A/B'd
  // INSIDE one call. Sequential arms carry the difference between two networks,
  // two CPU states and two positions in the fixture — the first run of
  // testbed/pfilter.mjs showed an arm's bitrate moving 0.67 -> 1.56 Mbps in a
  // direction the filter cannot cause, which is that noise, not a result.
  let pFilter = null, pFilterArmed = false, pfWanted = cfg.presenceFilter === true;
  let pfParams = {
    denoise: cfg.pfDenoise, soften: cfg.pfSoften, motionGain: cfg.pfMotionGain,
    hold: cfg.pfHold, holdThresh: cfg.pfHoldThresh,
  };
  // Codec capability negotiation (Android, 2026-08-16): what the PEER told us
  // it can decode (cfg-nak), and the receiver-side timer that bounds how long
  // we wait for a re-laddered cfg before conceding the lane.
  let peerDecCan = null, decNakTimer = null;
  // Mid-call resize: the config last handed to the encoder, and how many
  // consecutive frames have disagreed with its dimensions.
  let encConfig = null;
  // 'quantizer' (constant quality, the design) or 'vbr' (an engine without fixed-QP).
  // Every quality number this lane has ever produced was measured on the former.
  let rateControl = 'quantizer';
  let resizeHold = 0;
  // Orientation (task #12). Android hands MediaStreamTrackProcessor frames in
  // SENSOR orientation with the true orientation as metadata (VideoFrame.rotation,
  // Chrome 137+). Standard WebRTC applies it on the wire (CVO); this lane encodes
  // the raw pixels, so the metadata must ride the control channel or a portrait
  // phone renders sideways on the peer (measured: room vjj-spil-qli, 2026-08-06,
  // capture 1080x1920 while frames and encode ran 1920x1080).
  let sentRot = null;  // sender: last rotation told to the peer
  let remoteRot = 0;   // receiver: degrees CW to apply at paint
  let rotWarned = false;
  // The camera the pump is currently reading. Moves on a flip or a re-acquire.
  let curTrack = track;
  let dcCtl = null;
  let dcLaneP = null; // §13 lane P: crisp stills while VIDEO HELD (own channel, reliable+ordered)
  let procReader = null;
  // Which frame source the pump got. Logged on change only — the pump re-attaches on
  // every camera flip and a per-attach log would bury the one transition that matters.
  let lastFrameHow = null;
  let remoteReady = false;
  let wantKey = true;
  let lastKeyAt = 0;
  let frameId = 0;
  let pinger = null;
  let worker = null;
  let lastDecoded = -1;
  let haveKey = false;
  let keyReqAt = 0;
  // ── FEC receive state ─────────────────────────────────────────────────────
  // recent: payloads retained until their parity group is retired — repairing a
  //   lost member requires XOR-ing every other member, delivered ones included.
  // hold: data frames past a gap, released strictly in id order. The hold is what
  //   turns "parity arrives one group later" into in-sequence decode.
  const recent = new Map();  // id -> { buf, flags, ts, wall }
  const hold = new Map();    // id -> recv message awaiting the gap ahead of it
  const groups = new Map();  // group base -> { par: Uint8Array|null, n }
  let holdTimer = 0;
  // Ids already asked for via fragreq this gap episode — one request per id;
  // if the re-splice itself dies, the hold deadline's keyframe is the fallback.
  const fragReqIds = new Set();
  // Lane pacing: how many encoded frames the carrier has not yet consumed. The
  // encoder must never run ahead of the carrier, because a frame that is encoded and
  // then superseded is a hole in the decoder's reference chain — the receiver sees a
  // frameId gap it can only repair with a keyframe. Measured before this gate:
  // carrier at ~5 fps during GCC ramp-up versus our 30 fps encode meant 5428 "lost"
  // frames and 20-47 keyframes in 30 s, all self-inflicted. Skipping at capture
  // instead (frame never encoded) is invisible to the reference chain — lane 1's
  // admission philosophy, applied to a new backpressure signal.
  //
  // Depth 2, not 1: a single slot serializes encode→consume→encode and halves the
  // frame rate (measured: 49% admitted, 15 fps). Two keeps one frame encoding while
  // one waits for the carrier, and the worker's FIFO preserves order.
  let inFlight = 0;

  // ── Pacer-following admission (AIMD on receiver-reported frame age) ─────────
  // The inFlight gate above throttles to the carrier's TICK rate — the encoder
  // feeds the transform at 30 fps no matter what the pacer is doing — not the
  // pacer's DRAIN rate. The difference accumulates inside Chrome's pacer queue,
  // invisible to every local signal: measured 1.44-1.6 s of queue age at
  // 12-15 Mbps injected into a ~2.6-3M starting GCC grant, plus a contiguous
  // sender-side hole when the queue hits its drop ceiling. The receiver's frame
  // age is the ONLY quantity that sees the backlog, so the receiver reports its
  // age window over ctl every 2 s and the SENDER paces capture admission with
  // it: additive increase while the pipe is empty, multiplicative decrease when
  // a backlog shows, hysteresis between. Skipped captures never reach the
  // encoder, so the reference chain has no holes — quality is a constant, time
  // is the shock absorber. ?l2pace=0 restores the old behavior (control arm).
  // #44: with rate control holding the bitrate, the frame-rate slow-start has
  // nothing left to protect. It existed because admitting 30 fps of fixed-QP
  // 1080p meant a 68-115 Mbps blast at a link nobody had measured yet, so the
  // pacer crept up from 5 fps and let the age report find the ceiling. Under a
  // budget the blast cannot happen — 30 frames each sized budget/30 IS the
  // budget, whatever the content — so the safe opening rate is the camera rate.
  // What that removes, measured on an idle loopback link with the old default:
  // 10.6 fps averaged over the first five seconds of every call, and 15 seconds
  // before the picture first reached 24 fps. Every user paid that on every call.
  let admitRate = cfg.l2Rc ? cfg.fps : cfg.l2PaceStart; // frames/s
  let paceTokens = 1; // admit the first capture immediately
  let paceLastAt = 0;
  // The highest rate that was carrying before the last cut. Rates below it have
  // already been proven on this link, so climbing back through them at the
  // additive-increase rate is lost motion — the recovery below crosses that
  // region fast and only crawls above it, which is TCP's slow-start/ssthresh
  // split for the same reason. Without it a single bad second cost 8 s of ramp.
  let paceRef = admitRate;

  // ── §6.1 phase 4: this instance's TRANSPORT HALF, and the aggregate readers ─
  //
  // `link` null — every 1:1 call today, `?three=0`, and the `?l23enc=2` control
  // arm — makes every reader below return this instance's own variable, so the
  // hot path is the code that shipped rather than a special case of a new one.
  // With a link the SAME readers answer for the room: min governor, max
  // in-flight depth, all-ready, any-shed, min budget.
  //
  // Everything a transport half owns stays local and per-peer: `worker` (its own
  // carrier substitution, FEC group state and 90-frame re-splice ring live
  // inside it), `dcCtl`, the AIMD governor, the receive/decode/display chain and
  // the stall machine. Only the encode chain is shared, and only one instance
  // runs it (`link.claimEncoder`).
  const half = link ? {
    admitRate: () => admitRate,
    inFlight: () => inFlight,
    remoteReady: () => remoteReady,
    shedded: () => shedded,
    budgetMbps: () => rcBudgetMbps,
    setWantKey: () => { wantKey = true; },
    startEncodeHalf: () => startEncodeHalf(),
    ctlSend: (o) => ctlSend(o),
    // An encoded frame from the shared encoder, already copied for us. Counted
    // into OUR in-flight depth: it is this peer's carrier that has to spend a
    // tick on it, and the gate that stops the encoder running ahead of the
    // carrier is per carrier.
    acceptEncoded: (msg) => {
      if (closed || !worker) return;
      inFlight++;
      worker.postMessage({ type: 'frame', ...msg }, [msg.buf]);
    },
  } : null;
  const gAdmitRate = () => (link ? link.admitRate(admitRate) : admitRate);
  const gInFlight = () => (link ? link.inFlight(inFlight) : inFlight);
  const gRemoteReady = () => (link ? link.remoteReady(remoteReady) : remoteReady);
  const gShedded = () => (link ? link.shedded(shedded) : shedded);
  const gBudgetMbps = () => (link ? link.budgetMbps(rcBudgetMbps) : rcBudgetMbps);
  // A keyframe request, a resume, or the dead-man switch arms THE encoder, which
  // with a link may be another half's. Flag-off this is `wantKey = true`.
  const armKey = () => { if (link) link.wantKey(); else wantKey = true; };
  // The encoder's self-description. One encoder, one description, every peer.
  const descSend = (o) => { ctlSend(o); if (link) link.fanDesc(half, o); };

  // ── #44 rate control: hold a bitrate budget with QP, not with frame rate ────
  //
  // `bitrateMode: 'quantizer'` gives constant QUALITY, so the bitrate is set by
  // the content. Measured at QP 24 / 1080p30 with the pacer disabled: a static
  // pattern costs 20.3 Mbps on the wire, real motion costs 115.5 Mbps. The link
  // does not change between those two; only the picture does. Without a rate
  // target the excess had exactly one place to go — the AIMD pacer, whose only
  // actuator is frames per second — so motion arrived as a slideshow.
  //
  // The loop below is a plain integral controller in the domain where the plant
  // is roughly linear: for H.264, bitrate halves about every +6 QP, so working
  // in log2(bytes) makes the response to error scale-free and one constant (6)
  // covers the whole band. Per-frame, because QP is a per-`encode()` argument
  // and there is no reconfigure to pay for; smoothed, because per-frame byte
  // counts are noisy and a controller that chases noise oscillates.
  // Open mid-band, not at the floor. Starting at cfg.qp is a bet that the first
  // frames are cheap, and on moving content that bet loses expensively: the
  // opening frames come out at ~283 KB, the age spikes past a second, and the
  // pacer cuts four times before the controller has climbed out — measured, the
  // picture took 5 s to recover from its own first frame. Opening in the middle
  // costs nothing on cheap content, because the controller walks down to the
  // floor within about six frames once it sees the bytes.
  let rcQp = cfg.l2Rc ? (cfg.l2RcQpMin + cfg.l2RcQpMax) / 2 : cfg.qp;
  let rcBudgetMbps = null;        // null until the first estimate lands
  let rcBytesEwma = null;         // smoothed encoded bytes/frame
  let rcTargetBytes = null;       // budget expressed per frame, for the log
  const rcClamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

  // ── The brake for when the QP lever runs out (2026-08-16) ───────────────────
  //
  // The rate controller has exactly one actuator, QP, and it is bounded at
  // l2RcQpMax. Measured on all three of the real Sunday-morning calls (rooms
  // mza-aabt-hmk / syg-didh-xcv / ilx-swig-xox, Mac ↔ Android): a phone camera
  // in a dark room delivers 2-7 fps of enormous frames — low-light noise plus
  // whole-scene deltas, ~150 KB each even at QP 42 — so the controller slams to
  // its ceiling and STAYS over budget, 2.2-4.8 Mbps against a duress budget of
  // 0.6. Nothing anywhere dropped a frame in response: the AIMD pacer bites on
  // receiver age (too late, the flood is already in the network), the SCTP
  // bufferedAmount gate sees only the local queue, and rcOnEncoded can only ask
  // for a QP it already has. The flood put ~1000 ms of queue under BOTH
  // directions of the call and the audio spent the whole call in duress.
  //
  // So: a token bucket denominated in BYTES, refilled at the video budget,
  // spent by actual encoder output. It gates ADMISSION, but only when the QP
  // controller is pinned at its ceiling — while QP has room, the integral loop
  // is the right actuator and a second one would fight it (that spiral was
  // measured; see the divisor note in rcOnEncoded). Skipped captures never
  // reach the encoder, so the reference chain stays hole-free — same law as
  // every other skip in this file.
  //
  // Two deliberate reliefs:
  //   · a keyframe request always passes — recovery must not queue behind the
  //     brake that exists to make recovery possible;
  //   · at most 2 s between admitted frames — a slideshow that MOVES is the
  //     product working as intended on a starved sensor; a frozen tile is a
  //     failure. 1 frame / 2 s at 150 KB is 0.6 Mbps, i.e. even the relief
  //     valve respects the duress floor.
  // ?bytepace=0 is the control arm.
  let bpTokens = 0;               // bytes available to spend; deficit = over budget
  let bpLastAt = 0;
  let bpLastAdmitAt = 0;
  const bpRefill = () => {
    const b = gBudgetMbps();
    if (b == null) return null;
    const parityShare = stats.bytesSent > 0 ? stats.parityBytes / stats.bytesSent : 0.25;
    return (b * 1e6) / 8 / (1 + parityShare); // bytes/s the encoder may emit
  };
  // Deficit floor: one worst-case frame beyond the budget, so a single huge
  // frame costs a bounded pause (~one frame's refill time) rather than an
  // unbounded debt that freezes video long after the flood stopped.
  const bpFloor = () => -(rcBytesEwma ?? 50_000);
  const bpCeil = () => 2 * (rcBytesEwma ?? 50_000);

  // ── The actuator with real authority: RESOLUTION (task #40) ────────────────
  //
  // When QP pins at its ceiling and the encoder is still over budget, the brake
  // above was the obvious response and testbed/bytepace.mjs disproved it in an
  // hour: at constant quality, dropping frames does not drop bytes on moving
  // content — every surviving frame pays for the dropped motion (measured
  // 15.7 Mbps at 1.8 fps braked vs 8.3 at 30 fps unbraked). Pixels are the
  // lever that actually moves bytes at fixed QP: quarter the pixels, roughly
  // quarter the bytes, and the CADENCE — the thing frame-dropping destroyed —
  // is untouched.
  //
  // So: a shrink factor applied where the encoder fits the camera into the
  // configured ceiling. Demote fast (2 s of pinned-and-over is already 2 s of
  // flood), promote slowly and only on real evidence (QP has come well off the
  // ceiling, meaning bytes have genuine headroom at the current size — 6 QP is
  // one halving of bitrate, so promotion roughly pays for itself). The resize
  // itself rides the existing RESIZE_HOLD + reconfigure + keyframe machinery,
  // which the mid-call `set w/h` lab op already proved live.
  // ?rcres=0 is the control arm.
  let rcResShrink = 1;            // 1 | 2 | 4 — divisor on the encode size
  let rcResBadMs = 0;             // pinned AND over budget, accumulated
  let rcResGoodMs = 0;            // QP slack at this size, accumulated
  let rcResLastT = 0;
  function rcResEval(tn) {
    if (!cfg.l2RcRes) return;
    const dt = rcResLastT ? Math.min(500, tn - rcResLastT) : 0;
    rcResLastT = tn;
    const pinned = rcQp >= cfg.l2RcQpMax - 0.5;
    const over = rcTargetBytes != null && rcBytesEwma != null && rcBytesEwma > rcTargetBytes * 1.5;
    if (pinned && over) {
      rcResGoodMs = 0;
      rcResBadMs += dt;
      if (rcResBadMs >= 2000 && rcResShrink < 4) {
        rcResShrink *= 2;
        rcResBadMs = 0;
        stats.rcResShrink = rcResShrink;
        L('rc-res', { shrink: rcResShrink, why: 'pinned-over', qp: +rcQp.toFixed(1), ewma: Math.round(rcBytesEwma), target: Math.round(rcTargetBytes) });
      }
    } else {
      rcResBadMs = 0;
      // QP well off the ceiling = bitrate headroom of at least one halving,
      // which is what stepping back up will cost. 10 s, so one quiet moment
      // in the content cannot pump the resolution up and down.
      if (rcResShrink > 1 && rcQp <= cfg.l2RcQpMax - 6) {
        rcResGoodMs += dt;
        if (rcResGoodMs >= 10000) {
          rcResShrink /= 2;
          rcResGoodMs = 0;
          stats.rcResShrink = rcResShrink;
          L('rc-res', { shrink: rcResShrink, why: 'headroom', qp: +rcQp.toFixed(1) });
        }
      } else {
        rcResGoodMs = 0;
      }
    }
  }

  // ── #61 The LINK term on encode resolution ─────────────────────────────────
  // The ceiling implements min(camera, peer panel): it answers "what is worth
  // sending" — never more pixels than the sensor made, never more than the far
  // panel can show. It does NOT answer "what FITS". Measured on a live call
  // 2026-08-19: a 3420x2136 ceiling (the peer's Retina panel) against a 4.3 Mbps
  // budget is 0.019 bits/pixel. The encoder cannot make that sharp. It pins QP
  // and spreads the same bytes over 3.5x more pixels, so the picture comes out
  // SOFTER, and the frame rate falls paying for the pixels it did encode — that
  // call ran 14 fps on one side against the peer's 30. Above the link's carrying
  // capacity, more pixels is not a quality trade: it is worse on both axes at
  // once. So the budget sets a third ceiling beside the other two.
  //
  // This is `l2RcRes`'s job done BEFORE the damage instead of after. That
  // actuator waits for 2 s of pinned-and-over and then halves; it is the right
  // lever (pixels move bytes at fixed QP, frame rate does not) reached too late
  // and only in powers of two. This one is continuous and arrives first;
  // rcResShrink stays underneath it as the backstop for what the budget did not
  // predict.
  //
  // DENOMINATOR IS cfg.fps, THE TARGET — never the achieved rate. Achieved fps
  // is positive feedback here: fps falls -> cap rises -> more pixels -> fps
  // falls further. The target is the intent and it does not move.
  //
  // Shrink-only, applied to the CAMERA size exactly like rcResShrink, so it
  // composes with fitSize rather than fighting it: a 720p camera still encodes
  // 720p, min(camera, panel) still holds, and every demotion flows through the
  // one resize path (RESIZE_HOLD debounce, self-describing keyframe). Order is
  // irrelevant because all three bounds are minima.
  // #75 trust-floor calm clock: when duress last became 0 with no standing shed.
  // Seeded -Infinity, not 0, and the distinction is the whole startup behaviour:
  // a call that has never seen duress and has never been shed has given no
  // contrary evidence at all, so the floor applies from the first poll exactly as
  // it did before. 0 would have meant "the clock has not started" and cost every
  // call its first 5 s at the 0.6 Mbps clamp floor — a regression bought for
  // nothing, since the thing being guarded against has not happened yet.
  let rcCalmSince = -Infinity;
  let linkScale = 1;          // 1 .. 0.25 — linear divisor the budget is asking for
  // #75 dwell state. Two clocks, one per direction, and the extreme candidate
  // seen while each was armed. See the comment at the apply site below.
  let lsDownSince = 0, lsDownWant = 0, lsUpSince = 0, lsUpWant = 0;
  function linkScaleEval() {
    if (!cfg.l2ResLink) return;
    const cw = stats.camW, ch = stats.camH;
    if (!(rcBudgetMbps > 0) || !(cw > 0) || !(ch > 0) || !(cfg.fps > 0)) return;
    const maxPx = (rcBudgetMbps * 1e6) / (cfg.l2ResBpp * cfg.fps);
    const want = Math.min(1, Math.sqrt(maxPx / (cw * ch)));
    // Quantised to 1/16ths and floored at 1/4 (the same total authority
    // rcResShrink has).
    const q = Math.max(0.25, Math.round(want * 16) / 16);
    const apply = (to, why) => {
      const from = linkScale;
      linkScale = to;
      stats.linkScale = to;
      stats.linkScaleMoves = (stats.linkScaleMoves | 0) + 1;
      lsDownSince = 0; lsDownWant = 0; lsUpSince = 0; lsUpWant = 0;
      L('rc-res-link', { from, to, why, budgetMbps: +rcBudgetMbps.toFixed(2),
                         cam: `${cw}x${ch}`, bpp: cfg.l2ResBpp, fps: cfg.fps });
    };
    // ── The 10% guard was a no-op exactly where it was needed ────────────────
    // `Math.abs(q - linkScale) / linkScale >= 0.1` was written as "hysteresis of
    // 10%", but the rung is a FIXED 1/16 while the test is RELATIVE: one rung is
    // 0.0625/0.625 = 10.0% at 0.625 and 16.7% at 0.375. So from 0.625 downward —
    // the whole regime a struggling link lives in — a single rung always cleared
    // the guard and there was no hysteresis at all. It only ever suppressed
    // movement near 1.0, where movement is cheap.
    //
    // Measured on a live Safari<->Brave call (2026-08-20, room msc-vmfs-una,
    // both sides): 37 and 40 link-scale changes in a ~400 s call — one encoder
    // reconfigure and one keyframe every ~10 s — and **64% of them were
    // immediate reversals** (the new rung was the one we had just left). The
    // scale spent the call bouncing 0.375 <-> 0.625, a 2.8x swing in pixels,
    // because the budget itself is bistable: the trust floor pins it at 1.5
    // whenever duress dips to 0 and the duress multiplier drops it to the 0.6
    // clamp floor the moment it does not. A keyframe at 720x406 is ~250 ms of a
    // 0.6 Mbps link, so the ladder was manufacturing the very backlog that made
    // the peer shed the video lane.
    //
    // The replacement is a DWELL, not a wider deadband — the input is a square
    // wave, and no deadband narrower than the square is safe against one. Both
    // directions must survive a window before they move, and the two windows are
    // deliberately unequal:
    //
    //   DOWN is protective and cheap to be wrong about: a picture one rung too
    //   small still arrives. 1 s — two budget polls, so one bad poll cannot move it.
    //   UP re-floods the pipe it just drained, and being wrong about it costs a
    //   keyframe AND the queue that keyframe builds. It needs sustained proof.
    //   8 s, and it grows only to the LEAST optimistic rung seen across the whole
    //   window — the level the link held throughout, never the peak it touched.
    //
    // A budget that never settles therefore leaves the resolution ALONE, which is
    // the correct answer: pixels are the slow, expensive knob and QP is the fast
    // one. rcQp keeps adapting per frame underneath this, so the picture still
    // tracks the link every frame; only the pixel count stops chasing noise.
    // `?ressteady=0` restores the old guard as the control arm.
    if (!cfg.l2ResSteady) {
      if (Math.abs(q - linkScale) / linkScale >= 0.1) apply(q, 'raw');
      return;
    }
    const t = now();
    if (q < linkScale) {
      lsUpSince = 0; lsUpWant = 0;
      lsDownWant = lsDownWant ? Math.min(lsDownWant, q) : q;
      if (!lsDownSince) lsDownSince = t;
      else if (t - lsDownSince >= cfg.l2ResDownMs) apply(lsDownWant, 'down');
    } else if (q > linkScale) {
      lsDownSince = 0; lsDownWant = 0;
      lsUpWant = lsUpWant ? Math.min(lsUpWant, q) : q;
      if (!lsUpSince) lsUpSince = t;
      else if (t - lsUpSince >= cfg.l2ResUpMs) apply(lsUpWant, 'up');
    } else {
      // Back at the rung we are already on: whatever the excursion was, it did
      // not last. Both clocks disarm, so a dwell only ever counts CONTINUOUS
      // evidence and a square wave accumulates nothing.
      lsDownSince = 0; lsDownWant = 0; lsUpSince = 0; lsUpWant = 0;
    }
  }

  // The budget. `availableOutgoingBitrate` is Chrome's own GCC estimate for this
  // path — it has been probing since the call connected, which is strictly more
  // than we know — so use it and clamp into the configured band. Falling back to
  // the band's midpoint (not its ceiling) matters: an unknown link should be
  // assumed ordinary, and the controller converges from there within a second
  // either way.
  async function rcPollBudget() {
    if (closed || !cfg.l2Rc) return;
    let est = null;
    try {
      const rs = await pc.getStats();
      rs.forEach((s) => {
        if (s.type === 'candidate-pair' && s.state === 'succeeded' && s.availableOutgoingBitrate != null) {
          est = Math.max(est ?? 0, s.availableOutgoingBitrate);
        }
      });
    } catch { /* a failed poll holds the previous budget; it never invents one */ }
    // Lane A (uncompressed audio) and the carrier's own overhead share this pipe.
    // Taking the whole estimate for video would starve them and then read the
    // resulting audio pain as video congestion.
    //
    // `?l2res=1` (17.55): reserve the audio lane's MEASURED bytes instead of a
    // percentage. The 15% headroom below is a proportional allowance for a cost
    // that is very nearly ABSOLUTE — the PCM lane runs ~870 kbps with parity
    // whatever the link is doing — so at a 12 Mbps estimate it over-reserves
    // 1.8 Mbps and at 3 Mbps it reserves 450 kbps against an 870 kbps need. The
    // allowance is at its worst exactly where it matters. That is the same
    // shape as the `bdp x 1.5` backlog gate fixed in §17.49, in a different
    // costume, and it is the leading suspect for the 3 Mbps collapse (§17.51),
    // where video was measured pushing 2.7-3.2 Mbps into a 3 Mbps ceiling while
    // audio was already spending 0.87 of it.
    //
    // `audioBps()` is measured and returns 0 before the first frame, so the arm
    // degrades to "reserve nothing" at call start rather than to a guess. The
    // 1.10 multiplier is SCTP/DTLS per-message overhead on top of the payload
    // bytes pcm.js counts, not a safety fudge.
    const headroom = 0.85;
    const aBps = cfg.l2Reserve ? (audioBps?.() ?? 0) : 0;
    const raw = est == null ? null
      : cfg.l2Reserve && aBps > 0
        ? Math.max(cfg.l2RcMinMbps, (est - aBps * 1.10) / 1e6)
        : (est / 1e6) * headroom;
    if (cfg.l2Reserve) stats.rcAudioMbps = +(aBps / 1e6).toFixed(3);
    rcBudgetMbps = raw == null
      ? (rcBudgetMbps ?? (cfg.l2RcMinMbps + cfg.l2RcMaxMbps) / 2)
      : rcClamp(raw, cfg.l2RcMinMbps, cfg.l2RcMaxMbps);
    stats.rcBudgetMbps = +rcBudgetMbps.toFixed(2);
    stats.rcEstMbps = est != null ? +(est / 1e6).toFixed(2) : null;
    // Audio-lane duress overrides the estimate: GCC is exactly the instrument
    // that failed on the Aug 7 call (froze at 37 Mbps on a drowning 4G link),
    // while the audio ladder read the loss within 250 ms. Duress 2 (burst
    // shield engaged) quarters the budget, 1 halves it — smaller frames that
    // MOVE beat pristine frames that never arrive. The clamp floor keeps the
    // encoder alive; recovery is automatic the moment duress reads 0.
    const dd = duress?.() ?? 0;
    if (dd) rcBudgetMbps = rcClamp(rcBudgetMbps * (dd === 2 ? 0.25 : 0.5), cfg.l2RcMinMbps, cfg.l2RcMaxMbps);
    // GCC ON A SYNTHETIC CARRIER IS NOT A MEASUREMENT OF THE LINK. The carrier is
    // a 320x180 placeholder and its declared size has nothing to do with the bytes
    // spliced through it, so libwebrtc allocates from the picture it believes it is
    // sending. Measured on a live Delhi <-> Netherlands call (2026-08-14), the two
    // ends of the SAME call disagreed by 8x:
    //   Safari/WebKit  targetBitrate  72 kbps, estimate below the clamp floor
    //                  -> admitFps 4.8, achievedFps 2.7, and 1279 of 1533
    //                     captured frames discarded at admission
    //   Chromium       targetBitrate 573 kbps, availableOutgoingBitrate 1.73 Mbps
    //                  -> 22.7 fps
    // Same path, same second, no loss on either side.
    //
    // This is not "trust GCC less" in general — it is that we have a BETTER
    // instrument on this exact 5-tuple. Lane A was carrying 0.74 Mbps of
    // uncompressed audio with lossPct 0 and peerLossPct 0 at the moment GCC said
    // 0.6. Audio duress is what caught real congestion on the Aug 7 call when GCC
    // froze at 37 Mbps on a drowning 4G link; the inverse holds equally — with
    // duress 0 and the audio ladder clean, an estimate collapsed to the floor is
    // the instrument failing, not the link closing. And if that judgement is ever
    // wrong, the duress branch directly above corrects it within 250 ms and halves
    // or quarters the budget: the same feedback loop that already protects Lane B.
    // `?l2rctrust=0` disables, any number sets the floor in Mbps.
    //
    // ── #75: the floor is a claim about the INSTRUMENT, so the LINK outranks it ──
    // Everything above is an argument that a collapsed estimate is GCC failing on
    // a synthetic carrier. That argument is sound and the floor stays. What it
    // cannot survive is contrary evidence from the link itself, and the old gate
    // — `!dd` alone — could not see any.
    //
    // Measured on a live Safari<->Brave call (2026-08-20, room msc-vmfs-una):
    // the sender's own GCC read 0.25-0.64 Mbps for six minutes and the floor
    // overrode it to 1.5 on every dip duress took through 0 (`rcTrusted` 107 on
    // one side, 31 on the other). The receiver spent that call in `held` with the
    // video lane SHED — it had asked us to stop sending entirely — while we kept
    // sizing the encoder for a 1.5 Mbps pipe. Its glass-to-glass never recovered
    // and it received 882 frames in 366 s.
    //
    // Two pieces of evidence, both already in this scope and neither previously
    // consulted:
    //
    //   `gShedded()` — the PEER has asked us to stop sending video. That is the
    //     receiver's own verdict on our uplink, arrived at from arrival ages we
    //     cannot see, and it is strictly better information than any local
    //     estimate. While it stands, a floor that RAISES the budget is arguing
    //     with the only party that can actually observe the outcome.
    //
    //   duress-0 must be SUSTAINED. Duress rises immediately and decays smoothed
    //     (pcm.js, by design, so one clean tick cannot un-duck the video lane
    //     mid-burst) — but this gate read the instantaneous value, so a single
    //     zero between two bursts bought a full 2.5x budget rise. `l2RcTrustCalmMs`
    //     of quiet is the same "is this actually calm" question the rest of the
    //     stack asks with dwells. `?l2rctrustcalm=0` restores the instant gate.
    if (dd || gShedded()) rcCalmSince = 0;
    else if (!rcCalmSince) rcCalmSince = now();
    // `?l2rctrustcalm=0` must restore the ORIGINAL gate exactly — `!dd` and
    // nothing else — or the control arm is not a control. Both new conditions
    // therefore hang off the one flag rather than only the dwell.
    const calm = !cfg.l2RcTrustCalmMs
      || (rcCalmSince && now() - rcCalmSince >= cfg.l2RcTrustCalmMs && !gShedded());
    if (!dd && calm && cfg.l2RcTrustMbps && rcBudgetMbps < cfg.l2RcTrustMbps) {
      rcBudgetMbps = rcClamp(cfg.l2RcTrustMbps, cfg.l2RcMinMbps, cfg.l2RcMaxMbps);
      stats.rcTrusted = (stats.rcTrusted | 0) + 1;
    } else if (!dd && cfg.l2RcTrustMbps && rcBudgetMbps < cfg.l2RcTrustMbps) {
      // Counted, because "the floor stood down" is the whole point of the change
      // and an arm that cannot be seen firing cannot be scored.
      stats.rcTrustHeld = (stats.rcTrustHeld | 0) + 1;
    }
    if (dd !== stats.rcDuress) log?.('rc-duress', { level: dd, budgetMbps: +rcBudgetMbps.toFixed(2) });
    stats.rcDuress = dd;
    stats.rcBudgetMbps = +rcBudgetMbps.toFixed(2);
    rcVbrRetune();
  }
  // VBR is a fallback arm, not a lawless one. In fixed-QP mode the controller fits the
  // encoder to the link by moving QP; in VBR mode the encoder ignores the per-frame
  // quantizer, so a fixed `bitrate` leaves NOTHING fitting the encoder to the link — and
  // the pacer inherits the mismatch. Measured on motion1080: at a fixed 12 Mbps the
  // pacer withheld 348 of 644 captured frames (54%) and receiver frame age hit 128 ms,
  // beside a fixed-QP arm delivering 828/846 at 23 ms from the SAME link budget. The
  // encoder must track the same budget the QP loop would have used; reconfigure is
  // cheap, but 15% hysteresis keeps it off the per-frame path.
  // An explicit ?l2vbrbps= pins the bitrate and disables tracking — that is the
  // measurement hook, and a pinned arm must stay pinned.
  let rcVbrLastConfigAt = -Infinity;
  function rcVbrRetune() {
    // §6.1: the budget and the admitted share are both the ROOM's, not this
    // peer's — one encoder cannot track two links. With no link both readers
    // return this instance's own values and the arithmetic below is unchanged.
    const budgetMbps = gBudgetMbps();
    if (rateControl !== 'vbr' || cfg.l2VbrBps || !enc || enc.state !== 'configured'
        || !encConfig || budgetMbps == null) return;
    const parityShare = stats.bytesSent > 0 ? stats.parityBytes / stats.bytesSent : 0.25;
    // The budget must follow the frames the pacer actually admits. A VBR encoder
    // budgets bits per unit TIME: hand it the full budget while the pacer admits
    // 2 of 30 captures and every admitted frame balloons to ~budget/admitted —
    // which takes longer to send, raises the peer's age, cuts admitRate further,
    // and the loop closes. Measured live (room uol-jdmh-omn, 2026-08-07, Android
    // on 4G): rcVbrBps pinned at 6.4 Mbps against a GCC estimate frozen at
    // 37 Mbps, admitRate at the 2 fps floor, 43 KB mean frames, 84% of captures
    // skipped, both sides cycling stall-HOLD for the whole call. Scaling by the
    // admitted share keeps per-frame size ≈ budget/cameraFps — the same
    // per-frame invariant the fixed-QP loop holds — so congested frames stay
    // small and the AIMD's own recovery can climb back out. The quantizer arm
    // needs none of this: rcOnEncoded targets budget/cfg.fps per frame already.
    // Quantized to power-of-two steps with a cooldown, because configure() is
    // NOT free here the way the 15% hysteresis assumed: tracking admitRate
    // continuously reconfigured ~1/s and the hardware encoder stalled on each
    // one (measured on the shaped 2 Mbps rig: encode p50 went 3.2 ms → 501 ms
    // and delivery got WORSE than the spiral this replaces). Steps land on
    // 1, ½, ¼, ⅛ of the budget, so the encoder is touched only when the pacer
    // regime genuinely moved, and at most once per 3 s.
    const rawShare = cfg.l2VbrAdmit === false ? 1 : Math.min(1, gAdmitRate() / cfg.fps);
    const admitShare = rawShare >= 0.75 ? 1 : rawShare >= 0.375 ? 0.5 : rawShare >= 0.1875 ? 0.25 : 0.125;
    const want = Math.max(250_000, Math.round((budgetMbps * 1e6 * admitShare) / (1 + parityShare)));
    const cur = encConfig.bitrate || 0;
    // 35%, not the 15% the original tracker used: the GCC budget estimate
    // swings past 15% on nearly every 1 s poll, which put configure() back on
    // a ~3 s cadence even with the cooldown. A retune should mark a regime
    // change (the admit ladder moved, or the budget really collapsed), and the
    // spiral this exists for is an 8× move — a wide deadband cannot miss it.
    if (cur && Math.abs(want - cur) / cur < 0.35) return;
    const tNow = now();
    if (tNow - rcVbrLastConfigAt < 5000) return;
    rcVbrLastConfigAt = tNow;
    try {
      encConfig = { ...encConfig, bitrate: want };
      enc.configure(encConfig);
      stats.rcVbrBps = want;
      L('vbr-retune', { fromBps: cur, toBps: want, budgetMbps, admitFps: +gAdmitRate().toFixed(1) });
    } catch (e) {
      L('vbr-retune-failed', { want, err: String(e).slice(0, 120) });
    }
  }
  const rcTimer = cfg.l2Rc ? tickInterval(() => { rcPollBudget().catch(() => {}); }, 1000) : null;
  if (cfg.l2Rc) rcPollBudget().catch(() => {});

  // Called once per encoded frame with its size. Keyframes are excluded: they are
  // 5-10x a delta frame by nature, arrive every 5 s, and letting them drive the
  // controller would ratchet QP up on a schedule rather than on evidence.
  function rcOnEncoded(bytes, isKey) {
    if (!cfg.l2Rc) return;
    // Every encoded byte spends from the bucket, keyframes included — the
    // network carries keyframes too. (The QP integrator below still skips
    // keyframes: their size says "keyframe", not "wrong QP".)
    bpTokens = Math.max(bpFloor(), bpTokens - bytes);
    if (isKey) return;
    rcBytesEwma = rcBytesEwma == null ? bytes : 0.85 * rcBytesEwma + 0.15 * bytes;
    rcResEval(now());
    linkScaleEval();
    // §6.1: the worst peer's budget, because one bitstream feeds both decoders.
    const budgetMbps = gBudgetMbps();
    if (budgetMbps == null) return;
    // The divisor is the frame rate we WANT, never the one the pacer has been
    // forced down to. Dividing by the live admitRate was tried and measured
    // catastrophic: the pacer cuts fps, the smaller divisor hands the encoder a
    // bigger per-frame budget, QP falls back to 24, frames get bigger, the age
    // stays high, and the pacer cuts again — the two controllers drive each
    // other into a corner. Pinned at 2 fps for 13 s with 1.1-1.7 s frame ages on
    // a loopback link, which is worse than having no rate control at all.
    // Pinning the divisor makes the coupling helpful instead: a throttled pacer
    // now means cheaper frames, which is exactly what lets it climb back.
    const fps = cfg.fps;
    // FEC parity is real traffic on this link (measured ~25% of payload), so the
    // budget the encoder gets is the link budget minus what redundancy will cost.
    const parityShare = stats.bytesSent > 0 ? stats.parityBytes / stats.bytesSent : 0.25;
    rcTargetBytes = ((budgetMbps * 1e6) / 8 / fps) / (1 + parityShare);
    // +6 QP ~ half the bits (H.264). Step-limited to +/-1.5 QP per frame so a
    // single large frame cannot visibly pump the picture; at 30 fps the
    // controller still crosses the whole 24-42 band in well under a second.
    const err = Math.log2(rcBytesEwma / rcTargetBytes);
    rcQp = rcClamp(rcQp + rcClamp(6 * err, -1.5, 1.5), cfg.l2RcQpMin, cfg.l2RcQpMax);
    stats.rcQp = +rcQp.toFixed(1);
    stats.rcTargetBytes = Math.round(rcTargetBytes);
  }
  // Integer, because the encoder takes an integer and rounding at the call site
  // keeps the controller's own state continuous — quantising rcQp itself would
  // stick the loop on a QP boundary and stall the integrator.
  const rcQpNow = () => (cfg.l2Rc ? Math.round(rcQp) : cfg.qp);
  const ageWindow = []; // this side's receive ages, drained by the reporter below
  // #75 ctl round trips, for the clean-pong gate on the clock offset above.
  // 30 samples at one ping per 2 s is a minute — the same horizon the age floor's
  // ring uses, and for the same reason: long enough that a queue cannot fill it,
  // short enough that a route change is re-learned rather than never.
  const CTL_RTT_WIN = 30;
  const CTL_CLEAN_MS = 30; // floor on the margin, for short paths where 15% is nothing
  const ctlRttRing = [];
  let ageFloorMs = Infinity; // #63 the path floor; #71 min over a 60 s ring
  const ageFloorRing = []; // #71 per-report window minima -- poison ages out
  const ageReporter = tickInterval(() => {
    if (closed) return;
    const w = ageWindow.splice(0);
    let p50 = null, p95 = null;
    if (w.length) {
      const s = [...w].sort((a, b) => a - b);
      p50 = +s[Math.min(s.length - 1, Math.floor(0.5 * s.length))].toFixed(1);
      p95 = +s[Math.min(s.length - 1, Math.floor(0.95 * s.length))].toFixed(1);
    }
    // #63 THE PATH'S AGE FLOOR. Frame age CONTAINS one-way propagation, so any
    // absolute threshold on it is a hidden distance limit (rtt-blind-timeouts,
    // third instance found). On a 337 ms RTT path no frame can ever be younger
    // than ~200 ms, so "increase when p50 < 250" almost never fired and the
    // AIMD pacer sat at its 2 fps floor for the whole call while the budget
    // read 3.8 Mbps — measured live 2026-08-19. The floor is the min age seen,
    // decaying upward at ~2 ms/s so a route change (VPN reconnect) is
    // re-learned within a minute rather than never (#71: via a 60 s rolling min). Additive field: an old
    // sender ignores pmin and keeps the absolute law.
    // #71 The all-time min latch was poisonable: one bogus-low sample (a
    // clock-offset transient around a rejoin) set the floor for ~10 minutes
    // at the 2 ms/s decay -- measured live 2026-08-20, a floor of -24.7 ms
    // held the pacer in its dead zone. A rolling min over the last 60
    // reports ages poison out in a minute and needs no decay constant.
    // #72 The ring must age by TIME, not by sample count: an empty window
    // pushes Infinity, or a poisoned floor that itself stops the frame flow
    // (held-exit demanded stills younger than -133 ms, live 2026-08-20)
    // freezes its own ring and never heals. All-Infinity ring -> floor
    // Infinity -> pmin null -> both ends fall back to the absolute law.
    ageFloorRing.push(w.length ? Math.min(...w) : Infinity);
    if (ageFloorRing.length > 60) ageFloorRing.shift();
    ageFloorMs = Math.min(...ageFloorRing);
    // mco: our camera clock's offset — the peer's fullAge correction.
    // avd (§10): the delta between OUR two capture clocks, video and audio,
    // read at the same instant — the two drift apart on one device, so the
    // peer cannot assume them common. videoClock(now) = (now() − mco)·1000 µs
    // (law 14's running-min base); audioClock = ctx.currentTime. The peer
    // subtracts avd from a frame's VideoFrame.timestamp to land it on our
    // audio-sample clock, which its playhead speaks natively (capUs chain).
    // Only present under the avsync bundle: the flag-off ctl wire is
    // byte-identical.
    stats.ageFloorMs = Number.isFinite(ageFloorMs) ? +ageFloorMs.toFixed(1) : null;
    // ?agefloor=0 control: withhold pmin and every consumer reverts to the
    // absolute law — one flag silences the whole #63 change on this side's
    // receive direction.
    const msg = { t: 'age', p50, p95, mco,
                  pmin: cfg.l2AgeFloor !== false && Number.isFinite(ageFloorMs) ? +ageFloorMs.toFixed(1) : null };
    if (avsync && mco != null && Number.isFinite(mco)) {
      const ac = avsync.audioClockUs?.();
      if (ac != null) msg.avd = Math.round((now() - mco) * 1000 - ac);
    }
    ctlSend(msg);
  }, 1000);

  const ctlSend = (o) => {
    try { if (dcCtl?.readyState === 'open') dcCtl.send(JSON.stringify(o)); } catch { /* ignore */ }
  };

  function requestKey(why) {
    const t = now();
    if (t - keyReqAt < cfg.keyReqMs + (stats.rttMs ?? 0)) return;
    keyReqAt = t;
    stats.keyReqSent++;
    ctlSend({ t: 'key', why });
  }

  function onWorkerMsg(m) {
    if (m.type === 'sent') {
      // Parity and key-duplicate frames consume a carrier tick but no encoded
      // frame, so inFlight — encoded frames awaiting carrier pickup — must not
      // move for them. Decrementing here would let the capture loop over-admit
      // and eventually trip the worker FIFO drop, which poisons a parity group.
      if (m.parity) {
        stats.paritySent++;
        stats.parityBytes += m.bytes;
        stats.bytesSent += m.bytes;
      } else if (m.dup) {
        stats.keyDupsSent++;
        stats.bytesSent += m.bytes;
      } else if (m.retx) {
        // Re-splice on a peer's fragreq: a carrier tick, not an encoded frame.
        stats.retxSent++;
        stats.bytesSent += m.bytes;
      } else {
        inFlight = Math.max(0, inFlight - 1);
        stats.fragsSent++;
        stats.bytesSent += m.bytes;
        stats.carrierDropped += m.dropped;
      }
    } else if (m.type === 'recv') {
      onLaneFrame(m);
    } else if (m.type === 'shed-purged') {
      // The worker discarded m.n encoded frames on our shed/resume order —
      // release exactly those inFlight slots or the gate locks shut.
      inFlight = Math.max(0, inFlight - m.n);
      stats.shedPurged += m.n;
    } else if (m.type === 'err') {
      L('tape-worker-err', { e: m.e });
    } else if (m.type === 'tick') {
      if (typeof m.yieldTicks === 'number') stats.l0YieldTicks = m.yieldTicks;
      // The send-queue wait, straight from the worker: how much of `age` is a
      // frame waiting for a carrier tick it may ride, rather than time on wire.
      if (typeof m.qWaitAvg === 'number') stats.qWaitAvgMs = m.qWaitAvg;
      if (typeof m.qWaitMax === 'number') stats.qWaitMaxMs = m.qWaitMax;
      if (typeof m.xferAvg === 'number') stats.xferAvgMs = m.xferAvg;
      if (typeof m.tickAvg === 'number') stats.tickAvgMs = m.tickAvg;
      if (m.tickPct) stats.tickPct = m.tickPct;
      if (m.recvPct) stats.recvPct = m.recvPct;
      L('tape-worker', m);
    } else if (m.type === 'boot' || m.type === 'hooked') {
      L('tape-worker', m);
    }
  }

  function onLaneFrame(m) {
    stats.fragsRecv++;
    stats.bytesRecv += m.buf.byteLength;
    if (m.flags & 2) { onParityFrame(m); return; }
    if (m.id <= lastDecoded) { stats.fragsLate++; return; }
    // VIDEO HELD (§13): we asked the sender to shed. Everything from before
    // the cut is dropped on sight (frames in flight when the shed landed are
    // stale by construction); the one thing that ends the hold is the fresh
    // post-resume keyframe — "capacity restored + keyframe decoded". The last
    // complete frame stays on the canvas the whole time: nothing repaints it,
    // which is exactly what "held" means.
    if (stallRegime === 'held') {
      // "the fresh POST-RESUME keyframe" — and post-resume is a thing that must be
      // checked, not assumed. shedMaxId is our own lastDecoded, so every frame the
      // sender had already put on the wire when the shed landed has a larger id and
      // passes `m.id > shedMaxId`. At a bandwidth ceiling that is a full queue of
      // them, often over a second's worth. Accepting one as the exit ends `held`
      // WITHOUT us ever sending a resume — and since classify() only calls
      // exitProbe() while held, no resume is ever sent afterwards either. The peer
      // stays shedded for the rest of the call: it has stopped admitting captures
      // and the only message that would restart it is one we've now guaranteed
      // never to send. Measured at bw=4 (A shedSent 1 / resumeSent 0, peer ends
      // with skipShed 2155) and again at bw=2.5 in the other direction (peer
      // framesOut 35 across 90 s). This was the intermittent whole-call collapse.
      const resumed = resumeSentAt >= shedAt;
      if (m.key && m.id > shedMaxId && resumed) {
        lpAge.length = 0;
        setRegime('nominal', 'resume keyframe');
        deliver(m);
        trimGroups();
      } else {
        stats.shedSkipped++;
        if (m.key && !resumed) stats.shedStaleKey++;
        // We asked to resume and the sender is sending again, but what is arriving
        // is deltas — its one post-resume keyframe was lost. `wantKey` is already
        // spent, so nothing will produce another unless we ask; repeat resumes are
        // no-ops now that the sender has cleared `shedded`. requestKey is rate
        // limited by keyReqMs + RTT, so this cannot become a keyframe storm.
        else if (resumed && !m.key) requestKey('post-resume');
      }
      return;
    }
    // RTP delivered whole frames (NACK/RTX handled loss below us), so there is no
    // reassembly here — but reference-chain continuity is still ours to enforce.
    if (cfg.l2FecGroup > 0) {
      if (lastDecoded < 0 && !m.key) {
        // Pre-first-frame: no group can close this hole, so skip the hold window
        // and ask for a key now rather than after l2FecHoldMs of black screen.
        requestKey('no-reference');
        return;
      }
      recent.set(m.id, { buf: new Uint8Array(m.buf), flags: m.flags, ts: m.ts, wall: m.wall });
      if (m.key) {
        // Keys restart the reference chain: never hold a key behind a gap. Any held
        // deltas precede the key and are undecodable by definition — flush them.
        if (m.id !== lastDecoded + 1) {
          stats.framesLost += Math.max(0, m.id - lastDecoded - 1);
          if (haveKey) stats.framesGapped++;
          hold.clear();
          fragReqIds.clear();
          if (holdTimer) { clearTimeout(holdTimer); holdTimer = 0; }
        }
        deliver(m);
        trimGroups();
        return;
      }
      if (m.id === lastDecoded + 1 && hold.size === 0) {
        deliver(m);
        trimGroups();
        return;
      }
      // Gap: hold and try to fill the hole from parity before spending a keyframe.
      hold.set(m.id, m);
      tryRepairGroup(baseOf(lastDecoded + 1));
      releaseHeld();
      armHoldTimer();
      return;
    }
    // ── FEC disabled (?l2fec=0): the measured baseline, unchanged ──
    if (m.key) {
      haveKey = true;
    } else if (!haveKey || m.id !== lastDecoded + 1) {
      if (m.id !== lastDecoded + 1) stats.framesLost += Math.max(0, m.id - lastDecoded - 1);
      if (haveKey) stats.framesGapped++;
      haveKey = false;
      requestKey(lastDecoded < 0 ? 'no-reference' : 'gap');
      return;
    }
    deliver(m);
  }

  function baseOf(id) { return id - (id % cfg.l2FecGroup); }

  function deliver(m) {
    if (m.key) haveKey = true;
    lastDecoded = m.id;
    // A sample is only a latency once the clock offset exists. Before the first ctl
    // ping lands there is no shared zero point, and `?? 0` was subtracting the
    // PEER's performance.now() origin from ours — two unrelated zeros — then
    // pushing the difference as a transport age. Those samples stayed in the 900-
    // deep window for the rest of a short call, so ageP95 could read 637 ms on a
    // call whose glass-to-glass p95 was 80 ms, and the AIMD controller was handed
    // a rate signal built out of clock skew. §lane-P's age site already guarded
    // this; this one and lane 1's did not.
    const off = stats.clockOffsetMs;
    const age = off == null ? null : now() - (m.wall + off);
    if (age != null) {
      stats.ageMs.push(+age.toFixed(1));
      if (stats.ageMs.length > 900) stats.ageMs.shift();
      ageWindow.push(+age.toFixed(1)); // the AIMD reporter drains this every 2 s
    }
    if (cfg.stall) { // the stall classifier's per-frame input (§12's freshest signal)
      const t = now();
      // delTs is pure cadence and needs no offset, so it keeps every frame; only
      // the age-bearing sample waits for a clock.
      if (age != null) clsWin.push({ t, age });
      delTs.push(t);
    }
    try {
      dec.decode(new EncodedVideoChunk({ type: m.key ? 'key' : 'delta', timestamp: m.ts, data: m.buf }));
      stats.framesOut++;
      if (dec.decodeQueueSize > 6) ctlSend({ t: 'stall', q: dec.decodeQueueSize });
    } catch {
      stats.decodeErrors++;
      haveKey = false;
      requestKey('decode-throw');
    }
  }

  function onParityFrame(m) {
    if (stallRegime === 'held') return; // groups were reset at the shed; pre-cut parity is noise
    const base = m.id; // the sender wrote the group base into the frameId field
    if (base + cfg.l2FecGroup <= lastDecoded + 1) { stats.parityUnused++; return; }
    let g = groups.get(base);
    if (!g) { g = { par: null, n: 0 }; groups.set(base, g); }
    if (g.par) { stats.parityUnused++; return; } // duplicate parity for this group
    g.par = new Uint8Array(m.buf); // 21-byte XOR header + column-XOR payload
    g.n = m.n;
    tryRepairGroup(base);
    releaseHeld();
  }

  // Repair a group iff exactly one covered member is missing and every other
  // covered member's payload is in hand — lane 1's tryRepair rule, transposed to
  // whole frames. Coverage is the first g.n ids of the window (the sender's own
  // count), so a partial group flushed early can never XOR against members the
  // parity does not cover.
  function tryRepairGroup(base) {
    const g = groups.get(base);
    if (!g?.par || !g.n) return;
    const hi = base + g.n;
    let missing = -1, missingCount = 0;
    for (let i = base; i < hi; i++) {
      if (i <= lastDecoded) continue; // delivered; payload retained in recent
      if (recent.has(i) || hold.has(i)) continue;
      missing = i;
      missingCount++;
    }
    if (missingCount !== 1) return; // 0: nothing to do; >=2: beyond single XOR
    for (let i = base; i < hi; i++) {
      if (i === missing) continue;
      if (!recent.has(i) && !hold.has(i)) return; // a covered member still in flight
    }
    const rec = new Uint8Array(g.par); // copy: parity may be needed again
    // recent stores Uint8Array, hold stores the worker message (buf: ArrayBuffer).
    const get = (i) => {
      const e = recent.get(i) ?? hold.get(i);
      return { flags: e.flags, ts: e.ts, wall: e.wall, buf: e.buf instanceof Uint8Array ? e.buf : new Uint8Array(e.buf) };
    };
    let lenX = (rec[0] << 24) | (rec[1] << 16) | (rec[2] << 8) | rec[3];
    let flX = rec[4];
    const tsScratch = new Uint8Array(16);
    const tsDv = new DataView(tsScratch.buffer);
    for (let i = base; i < hi; i++) {
      if (i === missing) continue;
      const e = get(i);
      lenX ^= e.buf.byteLength;
      flX ^= e.flags & 1;
      tsDv.setFloat64(0, e.ts);
      tsDv.setFloat64(8, e.wall);
      for (let k = 0; k < 16; k++) rec[5 + k] ^= tsScratch[k];
      for (let k = 0; k < e.buf.byteLength; k++) rec[21 + k] ^= e.buf[k];
    }
    // Same refusal rule as lane 1: a length outside the possible range means
    // corrupt parity or a sender-side FIFO drop — splice nothing. (A sender drop
    // with no network loss XORs to exactly zero, which this check catches.)
    if (lenX <= 0 || lenX > rec.length - 21) { stats.fecUnrepairable++; return; }
    // Annex-B sanity: a fixed-QP H.264 frame starts with a start code.
    if (!(rec[21] === 0 && rec[22] === 0 && (rec[23] === 1 || (rec[23] === 0 && rec[24] === 1)))) {
      stats.fecUnrepairable++;
      return;
    }
    const tsDv2 = new DataView(rec.buffer, 5);
    hold.set(missing, {
      id: missing, flags: flX, key: !!(flX & 1),
      ts: tsDv2.getFloat64(0), wall: tsDv2.getFloat64(8),
      buf: rec.slice(21, 21 + lenX).buffer,
    });
    stats.fecRepaired++;
    L('tape-fec-repair', { id: missing, base });
  }

  // Strictly in-sequence release: the ordering invariant the whole lane depends
  // on — the worker FIFO's q.shift() on send, lastDecoded + 1 here on receive. A
  // repaired frame enters hold and can only leave through this loop, so it always
  // decodes before every later frame.
  function releaseHeld() {
    while (hold.has(lastDecoded + 1)) {
      const m = hold.get(lastDecoded + 1);
      hold.delete(m.id);
      deliver(m);
    }
    if (hold.size === 0 && holdTimer) { clearTimeout(holdTimer); holdTimer = 0; }
    if (hold.size === 0) fragReqIds.clear();
    trimGroups();
  }

  // The parity window is bounded: if repair has not closed the gap by the
  // deadline (parity itself lost, two losses in the group, or the sender paused),
  // fall back to exactly the pre-FEC gap behavior — count, drop, keyframe request.
  //
  // #23 two phases when l2Retx is on: parity gets the first l2RetxWaitMs to heal
  // the gap unaided (it lands within ~one group window of the loss — measured
  // holdExp 0-2 per run without help). Only gaps parity CANNOT close survive to
  // phase 1's fragreq: the group whose parity packet died with its data. That is
  // 1-3 re-splices per run — NOT the 100+ that fire-on-every-gap sends, each of
  // which steals a carrier tick from data (measured death spiral in retx1/retx-s1:
  // tick starvation → sender FIFO drops → more holes → more requests; admission
  // collapsed to 43-74%, losses rose to 33-63). The re-splice lands ~1 RTT after
  // the request; the total window is unchanged, so l2RetxWaitMs + 1 RTT must fit
  // inside l2FecHoldMs — at RTT above ~120 ms raise ?l2hold= or lower ?l2retxwait=.
  function armHoldTimer() {
    if (holdTimer) return;
    if (cfg.l2Retx && cfg.l2RetxWaitMs < cfg.l2FecHoldMs) {
      holdTimer = setTimeout(() => {
        holdTimer = 0;
        if (closed || hold.size === 0) return;
        const ids = [];
        const hi = Math.max(...hold.keys());
        for (let i = lastDecoded + 1; i <= hi; i++) {
          if (!fragReqIds.has(i)) { fragReqIds.add(i); ids.push(i); }
        }
        if (ids.length) { stats.fragReqSent += ids.length; ctlSend({ t: 'fragreq', ids }); }
        armHoldDeadline();
      }, cfg.l2RetxWaitMs);
      return;
    }
    armHoldDeadline();
  }
  function armHoldDeadline() {
    if (holdTimer) return;
    holdTimer = setTimeout(() => {
      holdTimer = 0;
      if (closed || hold.size === 0) return;
      stats.framesLost += Math.max(0, Math.min(...hold.keys()) - lastDecoded - 1);
      stats.fecHoldExpired++;
      if (haveKey) stats.framesGapped++;
      hold.clear();
      fragReqIds.clear();
      haveKey = false;
      requestKey('gap');
    }, cfg.l2Retx && cfg.l2RetxWaitMs < cfg.l2FecHoldMs ? cfg.l2FecHoldMs - cfg.l2RetxWaitMs : cfg.l2FecHoldMs);
  }

  // Retire groups the in-order stream has moved past (delivery is strictly
  // ordered, so a group whose whole window is behind lastDecoded is complete and
  // its retained payloads can never be needed again). Groups with a hole are
  // retired by the hold deadline above, never here.
  function trimGroups() {
    if (cfg.l2FecGroup <= 0) return;
    const cur = baseOf(lastDecoded);
    for (const [base] of groups) {
      if (base < cur) {
        for (let i = base; i < base + cfg.l2FecGroup; i++) recent.delete(i);
        groups.delete(base);
      }
    }
  }

  const onCtl = (raw) => {
    let m;
    try { m = JSON.parse(raw); } catch { return; }
    if (!m || typeof m.t !== 'string') return;
    switch (m.t) {
      case 'cfg': setupDecoder(m).catch((e) => fail('decoder-configure', e)); break;
      case 'cfg-nak': {
        // The peer cannot decode what we picked. Re-run the encoder ladder
        // constrained to what it CAN, and open the new stream on a keyframe.
        if (!Array.isArray(m.can) || !m.can.length) break;
        peerDecCan = m.can.map(String);
        L('tape-cfg-renegotiate', { peerCan: peerDecCan, had: encConfig?.codec ?? null });
        if (encConfig && !peerDecCan.includes(encConfig.codec)) {
          try { enc?.close(); } catch { /* already closed */ }
          enc = null;
          encConfig = null;
          setupEncoder().then(() => armKey()).catch((e) => fail('encoder-setup', e));
        }
        break;
      }
      case 'rot': remoteRot = ((m.rot | 0) % 360 + 360) % 360; L('tape-rot', { lane: 'rtp', dir: 'recv', rot: remoteRot }); break;
      case 'ready': remoteReady = true; L('tape-remote-ready', { lane: 'rtp' }); break;
      // §6.1: either peer may ask, and there is one encoder to ask.
      case 'key': stats.keyReqRecv++; armKey(); break;
      case 'fragreq': stats.fragReqRecv++; worker?.postMessage({ type: 'resplice', ids: m.ids }); break;
      case 'ping': ctlSend({ t: 'pong', a: m.a, b: now() }); break;
      case 'pong': {
        const t = now();
        const rtt = t - m.a;
        stats.rttMs = +rtt.toFixed(2);
        // ── #75 A CLOCK MAY ONLY BE MOVED BY A CLEAN PONG ────────────────────
        // `off = b - (a + rtt/2)` assumes the two halves of the round trip are
        // equal. A pong that waited in a queue violates that by exactly the queue,
        // and this channel queues — which makes the error largest precisely when
        // the ages it poisons are being used to decide whether the link is in
        // trouble. EWMA does not save it: a sustained one-sided queue biases every
        // sample the same way, so the average converges ON the error.
        //
        // Measured 2026-08-20, both ends, simulated 440 ms RTT: the frame-age
        // floor came out at -2176 ms and -939 ms. #72's clamp turned that into 0,
        // and a zero floor selects the DISTANCE-BLIND band in the stall
        // classifier (see pathFloorMs), which held the video lane for the rest of
        // the call. pcm.js learned this in 17.71 and got `pongClean`; this channel
        // never did, and it is the one the video lane's own ages ride on.
        //
        // Clean = within CTL_CLEAN_MS of the least-queued round trip in the recent
        // window. A ROLLING min, not an all-time latch: an all-time latch set by
        // one lucky early sample would mark every later pong dirty and freeze the
        // clock forever, and it could not follow a route change. rttMs itself is
        // always updated — the queue IS the reading there, and reporting it is the
        // point. `?ctlpongclean=0` restores the unconditional update.
        ctlRttRing.push(rtt);
        if (ctlRttRing.length > CTL_RTT_WIN) ctlRttRing.shift();
        const minRtt = Math.min(...ctlRttRing);
        const clean = stats.clockOffsetMs == null // the first one has to be taken
          || cfg.l2CtlPongClean === false
          || rtt <= minRtt + Math.max(CTL_CLEAN_MS, minRtt * 0.15);
        if (clean) {
          // EWMA the clock offset: a single ping's asymmetric RTT makes a noisy
          // offset, and the offset feeds every age estimate — noisy ages were
          // measured to trip false AIMD halvings at startup (lane2-pace1).
          const off = m.b - (m.a + rtt / 2);
          stats.clockOffsetMs = +(stats.clockOffsetMs == null ? off : 0.7 * stats.clockOffsetMs + 0.3 * off).toFixed(2);
        } else {
          stats.ctlPongDirty = (stats.ctlPongDirty | 0) + 1;
        }
        break;
      }
      case 'stall': stats.skipDecodeStalled++; break;
      case 'shed': {
        // LANE_SHED (§13 rule 1): the peer's receiver detected C < R sustained
        // and WE act on it — stop admitting captures, purge the worker FIFO.
        // Shedding at the source is what gives the audio lane its headroom.
        stats.shedRecv++;
        // #75 The peer is HELD until it says otherwise, and that is NOT the same
        // fact as "our uplink is shed". The dead-man below clears `shedded` on our
        // own authority after 8 s; the peer's `held` lasts up to stallMaxHoldMs =
        // 60 s. Conflating the two switched off the peer's only way out — see the
        // still-probe guard in the capture pump.
        peerHeldAt = now();
        if (!shedded) {
          shedded = true;
          sheddedAt = now();
          L('stall-shed', { dir: 'uplink' });
          try { worker?.postMessage({ type: 'shed' }); } catch { /* purge is best-effort; admission is already stopped */ }
        }
        break;
      }
      case 'resume': {
        // LANE_RESUME (§13 rule 2): never replay the backlog. The worker
        // purges what little it holds, the AIMD governor re-probes from its
        // start rate, and the next admitted capture is a FRESH KEYFRAME at the
        // current instant — one clean cut, no fast-forward, no ramp.
        stats.resumeRecv++;
        peerHeldAt = 0; // the only authority that can clear it: the peer itself
        if (shedded) {
          shedded = false;
          sheddedAt = 0;
          armKey();
          admitRate = cfg.l2PaceStart;
          paceTokens = 1;
          paceLastAt = now();
          lastStillAt = 0;
          try { worker?.postMessage({ type: 'resume' }); } catch { /* see above */ }
        }
        break;
      }
      case 'age': {
        // The peer's camera-clock offset, for our fullAge of its frames.
        if (m.mco != null) peerMco = m.mco;
        // §10: the peer's video-clock − audio-clock delta. Light EWMA — the
        // 1 Hz reads jitter a little against each other, and this delta feeds
        // every presentation decision. The slow drift it tracks is exactly
        // what the refresh is for; the EWMA does not hide it (τ ≈ 3 s).
        if (m.avd != null) peerAvDeltaUs = peerAvDeltaUs == null ? m.avd : 0.7 * peerAvDeltaUs + 0.3 * m.avd;
        // The peer's receive-side age window — the only signal that sees our
        // pacer backlog. p50 null means the peer decoded nothing this window
        // (startup, or a hole already healing): hold the rate, don't guess.
        if (!cfg.l2Pace || m.p50 == null) break;
        // #63: judge the QUEUE, not the trip. `pmin` is the peer's measured
        // path floor; subtracting it makes these thresholds distance-invariant
        // (queue-tolerance-in-ms — the same law as the audio queue cap; the
        // old absolute bands double-counted propagation exactly like the BDP
        // multiplier did). Queue bands: cut above 250 ms of queue, climb below
        // 100 ms, hold between. On a short path pmin≈age floor≈small and the
        // behaviour is the shipped one; an old peer sends no pmin and gets the
        // absolute law byte-for-byte.
        const base = Math.max(0, Number.isFinite(m.pmin) ? m.pmin : 0); // #72 a poisoned (negative) peer floor reverts to the absolute law rather than an impossible band
        const q50 = m.p50 - base, q95 = (m.p95 ?? 0) - base;
        if (q50 > (base ? 250 : 400) || q95 > (base ? 700 : 900)) {
          // 0.75x, not 1.0x, of the rate that broke: recovering all the way back
          // to it at speed just re-breaks the link. Successive cuts drag the
          // reference down with them, which is the correct reading of a link
          // that really is degrading.
          paceRef = admitRate * 0.75;
          admitRate = Math.max(2, admitRate * 0.6);
        } else if (q50 < (base ? 100 : 250)) {
          // Fast below the last proven rate, additive above it. The old law was
          // additive everywhere, so recovering from one x0.6 cut took ~8 s at
          // +3 fps/s — long enough that ordinary motion, which spikes the age
          // repeatedly, could re-trigger before the previous recovery finished
          // and hold the picture below camera rate indefinitely.
          const ai = admitRate < paceRef ? Math.max(cfg.l2PaceAi, 8) : cfg.l2PaceAi;
          admitRate = Math.min(cfg.fps + 4, admitRate + ai);
        }
        stats.admitFps = +admitRate.toFixed(2);
        break;
      }
      default:
        // §10 TIME_SYNC (tsy/tsyr) and anything else the avsync bundle owns.
        // Null when the bundle is off — unknown ctl messages are then ignored
        // exactly as before.
        avsync?.onCtlUnknown?.(m);
        break;
    }
  };

  // #14 canvas display state: set up in setupDecoder when the app handed us a
  // canvas — paint-on-arrival, no TrackGenerator, no <video>, no buffer.
  let ctx2d = null;
  let lastDrawAt = 0;
  let rafPending = false;

  // ── §10 A-V sync: audio is master ─────────────────────────────────────────
  // Paint-on-arrival (above) is replaced ONLY when the bundle is on and both
  // mappings exist: the peer's avd (its two capture clocks' delta, via 'age')
  // and the playhead of the remote audio in the peer's audio clock (pcm.js).
  // Until both are true the path is byte-for-byte the old one; once engaged it
  // never falls back (a mid-stream switch would paint out of order against
  // the queue). Decoded frames queue briefly; at each vsync the frame whose
  // audio-clock time is nearest audio_playout_time + offset is presented —
  // offset ∈ [0, 45 ms], audio leads (§3, BT.1359-1). No qualifying frame →
  // hold the current one. Timestamps are media clocks end to end: never
  // performance.now(), never the wall.
  let peerAvDeltaUs = null; // peer video-clock − peer audio-clock, µs (ctl 'age'.avd)
  const avq = []; // { frame, avUs } — decoded, awaiting their vsync
  const AVQ_MAX = 12; // ~400 ms at 30 fps; deeper means the lane is broken, not sync
  let avEngaged = false;
  // ── ENGAGEMENT IS NO LONGER A ONE-WAY DOOR ──────────────────────────────────
  // It used to be "sticky by design": set once on the first frame where both
  // clock mappings existed, never cleared. Below this block sit TWO working
  // presenters (the #33 cadence-locked v-presenter, and §17.8 paint-on-arrival)
  // and engagement made both unreachable for the rest of the call — so a single
  // wrong clock mapping could stop the picture permanently, with every other
  // number in the lane reading healthy.
  //
  // That is exactly what it did. `avUs = frame.timestamp - peerAvDeltaUs`, and
  // `avd` is derived from `mco`, a running MINIMUM — a one-way ratchet whose own
  // comment already records it applying -38 s on a WebKit sender. With the
  // mapping off by seconds every frame fails the "not newer than target" test,
  // `best` stays -1, and the presenter holds. Forever. Measured: 6178 holds
  // against 8 presents; on a live call, 3931 against 12 with 830 mco reanchors.
  //
  // So the door opens both ways now, and it is judged on OUTCOME rather than on
  // any bound for what the clocks may plausibly say: frames are queued and
  // nothing is being presented, therefore the mapping is wrong, whatever the
  // reason. Giving up is permanent for the call, the same shape as
  // `pcmFellBack` and `tapeFellBack` — a gate that can re-arm flaps, and a
  // flapping presenter is worse than either presenter.
  let avGaveUp = false;
  let avEngagedAt = 0;
  let avLastPresentAt = 0;
  const AV_STARVE_MS = cfg.avStarveMs ?? 1200;
  const AV_GRACE_MS = 1500; // engagement to first judgement: let it try
  const avStats = { presents: 0, holds: 0, drops: 0, skips: 0, offMs: [] };

  // Judge only once there is something to judge: an empty queue is not a
  // starving presenter, it is a quiet lane, and condemning sync for that would
  // disengage on every gap in the video.
  function avStarving() {
    if (!avEngaged || avGaveUp || !AV_STARVE_MS) return false;
    const t = now();
    if (t - avEngagedAt < AV_GRACE_MS) return false;
    if (!avq.length) return false;
    return t - (avLastPresentAt || avEngagedAt) > AV_STARVE_MS;
  }

  function avDisengage(why) {
    avGaveUp = true;
    avEngaged = false;
    const held = avq.length;
    // Hand nothing forward: these frames are mapped onto a clock we have just
    // declared wrong, and the next presenter would paint them out of order.
    for (const q of avq.splice(0)) { q.frame.close(); avStats.drops++; }
    L('tape-avsync-starved', {
      why, holds: avStats.holds, presents: avStats.presents, held,
      // The whole chain, in one line, so the ROOT cause stays visible after the
      // symptom is gone. A fallback that hides its reason buys silence, not a fix.
      peerAvDeltaUs: peerAvDeltaUs != null ? Math.round(peerAvDeltaUs) : null,
      offsetMs: avsync?.offsetMs ?? null,
      playoutUs: (() => { const ph = avsync?.audioPlayoutUs?.(); return ph ? Math.round(ph.us) : null; })(),
      engagedMs: Math.round(now() - avEngagedAt),
    });
  }

  function avEngageable() {
    return !!(avsync && peerAvDeltaUs != null && avsync.audioPlayoutUs?.() != null);
  }

  // Does the mapping describe a POSSIBLE call? `avEngageable` above asks only
  // whether the two numbers exist, and they always do -- including when
  // `peerAvDeltaUs` is -27 MINUTES. Measured on the long path across four
  // consecutive arms: -633053, -994270, -1300330, -1636066 ms, drifting one way
  // and never recovering. The sender builds `avd` as
  // `(now() - mco) * 1000 - ctx.currentTime * 1e6`: the left half reconstructs a
  // VideoFrame.timestamp (Chromium's capture clock) and the right half is an
  // AudioContext clock that is ZERO at construction. Two origins with nothing in
  // common, subtracted. So presence was never evidence of validity, and the
  // presenter inherited a target hundreds of seconds in the past and dutifully
  // waited for it -- 5870 frames held against 16 presented.
  //
  // The presenter's whole contract is that `frame.timestamp - avd` lands on the
  // peer's audio timeline near its playhead. Test exactly that, on the real
  // frame we are about to take ownership of.
  //
  // The bound is deliberately ENORMOUS: 2 s, against a real A/V skew of at most
  // a couple of hundred ms. This gate rejects the physically impossible, it does
  // not police tuning -- a tight bound would quietly switch sync off on a merely
  // mediocre estimate, which is a regression wearing a fix's clothes. Anything
  // inside 2 s still engages and is still judged on outcome by avStarving().
  const AV_MAP_MAX_US = (cfg.avMapMaxMs ?? 2000) * 1000;
  let avMapRejects = 0;
  let avMapErrUs = null;
  function avMapSane(tsUs) {
    if (!AV_MAP_MAX_US) return true;
    const ph = avsync.audioPlayoutUs?.();
    if (!ph) return false;
    avMapErrUs = Math.round((tsUs - peerAvDeltaUs) - (ph.us + ph.outLatUs));
    if (Math.abs(avMapErrUs) <= AV_MAP_MAX_US) return true;
    // Logged on the first rejection and then sparsely: a call whose peer clock
    // is broken produces one of these per decoded frame, and a log that floods
    // is a log nobody reads.
    if (avMapRejects === 0 || avMapRejects % 300 === 0) {
      L('tape-avsync-implausible', { errMs: Math.round(avMapErrUs / 1000),
        boundMs: AV_MAP_MAX_US / 1000, rejects: avMapRejects,
        peerAvDeltaMs: Math.round(peerAvDeltaUs / 1000), tsUs: Math.round(tsUs) });
    }
    avMapRejects++;
    return false;
  }

  // The one paint path for remote frames: sizes the backing store to the
  // UPRIGHT dimensions and applies the peer-signaled rotation (see `remoteRot`).
  // Decoder-output frames always carry rotation 0 (we never configure the
  // decoder with one), so this cannot double-rotate.
  function paintRemote(frame) {
    const swap = remoteRot === 90 || remoteRot === 270;
    const w = swap ? frame.displayHeight : frame.displayWidth;
    const h = swap ? frame.displayWidth : frame.displayHeight;
    if (displayCanvas.width !== w || displayCanvas.height !== h) {
      displayCanvas.width = w;
      displayCanvas.height = h;
    }
    try {
      if (remoteRot) {
        ctx2d.save();
        ctx2d.translate(w / 2, h / 2);
        ctx2d.rotate((remoteRot * Math.PI) / 180);
        ctx2d.drawImage(frame, -frame.displayWidth / 2, -frame.displayHeight / 2);
        ctx2d.restore();
      } else {
        ctx2d.drawImage(frame, 0, 0);
      }
    } catch { /* frame closing raced us */ }
  }

  function avEnqueue(frame) {
    // `at` = decode output (this is the decoder's frame callback path), for
    // the #14 present probe — the avsync path is the DEFAULT presenter once
    // engaged, and without this stamp presentLagMs went silent the moment
    // avsync took over, leaving glassToGlass composed from warmup samples.
    avq.push({ frame, avUs: frame.timestamp - peerAvDeltaUs, at: now() });
    if (avq.length > AVQ_MAX) {
      avq.shift().frame.close(); // oldest: the lane, not the sync, is behind
      avStats.drops++;
    }
  }

  function avTick() {
    if (closed || !avEngaged) return;
    requestAnimationFrame(avTick);
    // Checked BEFORE the work, so the tick that condemns the mapping does not
    // also add one more hold to the count it is being judged on.
    if (avStarving()) { avDisengage('no-present'); return; }
    const ph = avsync.audioPlayoutUs?.();
    if (!ph || avq.length === 0) { avStats.holds++; return; }
    // audio_playout_time at the EAR: the ring playhead plus the output
    // latency the worklet cannot see, plus the configured lead for audio.
    const target = ph.us + ph.outLatUs + avsync.offsetMs * 1000;
    const halfFrame = 1e6 / (2 * cfg.fps);
    // Nearest frame not newer than target + half a frame interval. "Not newer"
    // keeps the rule from ever presenting early: the residual is bounded by
    // the frame cadence, not by network jitter.
    let best = -1, bestDist = Infinity;
    for (let i = 0; i < avq.length; i++) {
      const d = target - avq[i].avUs;
      if (d < -halfFrame) continue; // too early — a later vsync owns it
      const dist = Math.abs(d);
      if (dist < bestDist) { bestDist = dist; best = i; }
    }
    if (best < 0) { avStats.holds++; return; }
    const { frame, avUs, at } = avq[best];
    // Everything older is superseded — closed, counted, never painted.
    for (let i = 0; i < best; i++) { avq[i].frame.close(); avStats.skips++; }
    avq.splice(0, best + 1);
    paintRemote(frame);
    frame.close();
    lastDrawAt = now();
    avLastPresentAt = lastDrawAt;
    avStats.presents++;
    stats.presentAt.push(+lastDrawAt.toFixed(1));
    if (stats.presentAt.length > 1800) stats.presentAt.shift();
    // #14 present probe: decode output → this draw. NOTE this path WAITS on
    // purpose (frames present when the audio playhead reaches them), so its
    // presentLag includes the A-V sync hold — that wait is real glass-to-
    // glass the viewer experiences, not probe overhead.
    if (at != null) {
      stats.presentLagMs.push(+(lastDrawAt - at).toFixed(1));
      if (stats.presentLagMs.length > 900) stats.presentLagMs.shift();
    }
    // The applied offset: presented frame's audio-clock time minus the
    // playhead-at-the-ear. This is the number §3's 45 ms budget judges.
    const applied = (avUs - (ph.us + ph.outLatUs)) / 1000;
    avStats.offMs.push(+applied.toFixed(1));
    if (avStats.offMs.length > 900) avStats.offMs.shift();
  }

  // ── #33 v-presenter: cadence-locked presentation for the non-avsync path ──
  // §17.8 removed the <video> element's adaptive jitter buffer; the measured
  // cost was arrival jitter painted straight on screen (task #33 baseline:
  // remote IPI bimodal ~31/62 ms, on-cadence 56–58%, p99 1.6–2.3× the
  // self-view's 33.3 ms metronome). The avsync scheduler above buys cadence
  // back, but only inside the bundle. This puts a BOUNDED schedule on the
  // default path: the sender's capture timestamps are the intended fps grid
  // (admission is pre-encode, so decoded frames are exactly the intended
  // slots), and slot idx presents at wall T0 + idx·I.
  //
  // The mechanics below are the THIRD revision — the first two failed in
  // measured arms and their failure modes define the design:
  //
  // 1. Late-only re-anchor wedged for minutes: admission catch-up bursts
  //    deliver ramp-skipped slots back-to-back, so idx gains on the wall slot
  //    counter — a one-way ratchet (54 presents, then 2066 cap-drops, queue
  //    pinned at depth 3, holds every rAF). => symmetric resync in vpTick.
  // 2. Drop-oldest at cap + queue saturated with FUTURE frames starved the
  //    schedule: the cap kept dropping the due-soonest frame before its slot,
  //    and each drop became a hold later (99.5% of steady-state holds were
  //    slots whose frame had been cap-dropped earlier; IPI p50 66.7, side B
  //    presented 203 of 2162 decoded). => on overflow, PRESENT the head
  //    (≤1 slot early — a blip, not a hole; nothing is ever dropped for
  //    queue pressure) and pull the metronome one slot earlier, so overflow
  //    converges to rare. This phase servo only ever REDUCES added latency
  //    from the anchored D; it is bounded (VP_SHIFT_LO slots), counted, and
  //    self-limiting (cushion < cap stops overflow, which stops the shift).
  //
  // Constants: queue cap 3, anchor D = 2 intervals (66.7 ms @ 30 fps). Added
  // latency = D pulled earlier by the servo: ~1–2 intervals steady, ≤ ~3
  // intervals worst. The cap never grows: §17.8's anti-jitter-buffer
  // property holds by construction — this is the disclosed-cost queue the
  // design spine licenses (time is the shock absorber; the cost is stated).
  // Sim replay of the recorded arrival streams (15 s warmup trim): loopback
  // IPI p50 33.3 / p95 33.3 / p99 33.3–66.7, on-cadence 96–100%.
  const vpq = [];                          // { frame, idx } — decoded, awaiting their slot
  const VPQ_MAX = 3;                       // measured: covers p99 arrival lateness + 1 hole slot
  // Anchor added latency, in frame intervals. This is the single largest
  // CONTROLLABLE term in glass-to-glass: at 30 fps two slots is 66.7 ms of
  // deliberate hold, spent to keep the remote view's cadence as smooth as the
  // self view (directive: "remote rendering very far off self-view smoothness").
  //
  // The 150 ms budget (LATENCY-150.md) makes that trade worth re-pricing. Every
  // route on earth clears 150 ms once the video pipeline drops from 57 ms to
  // under 54 ms — 3 ms — and ONE slot here is worth far more than 3 ms. So the
  // anchor becomes measurable instead of assumed: `?vpd=1` runs a one-slot
  // anchor against the shipped two, and the cadence gate (remote IPI p99 within
  // 1.5x self-view) says whether the smoothness it was bought with survives.
  // Unset = 2, exactly as shipped.
  const VP_D_SLOTS = (() => {
    const v = Number(new URLSearchParams(location.search).get('vpd'));
    return Number.isFinite(v) && v >= 0 && v <= 4 ? v : 2;
  })();
  const VP_SHIFT_LO = -30;                 // servo bound: ≤ 1 s of phase pull per anchor
  let vpT0 = 0;                            // wall ms at which slot 0 presents
  let vpTs0 = null;                        // frame.timestamp of slot 0 (sender capture clock, µs)
  let vpLastK = -1;                        // slot of the last presented frame
  let vpShift = 0;                         // servo phase pull so far, in slots (≤ 0)
  let vpRunning = false;

  // THE PEER'S CADENCE, NOT OURS.
  //
  // Everything below used to derive its slot interval from `cfg.fps` -- OUR
  // configured capture rate -- while the frames being scheduled are the PEER's.
  // The comment above states the premise plainly: "the sender's capture
  // timestamps are the intended fps grid". They are, but the grid is the
  // SENDER's, and nothing guaranteed it matched ours.
  //
  // Measured on the long path: a peer capturing 25 fps into our 30 fps grid
  // leaves five slots a second empty, resyncs the metronome ~1.5 times a
  // second, and stretches inter-present p99 to 831 ms against a p50 of 67. That
  // is not a subtle regression, it is the difference between "smooth" and
  // visibly stuttering, and it was reported as exactly that.
  //
  // 25 fps is not exotic. PAL-region webcams do it by default, and phone
  // sensors drop to 24/20/15 in anything short of bright light -- so this fired
  // on a large share of real calls and could only ever be seen from the far
  // end. The rig only found it because its own media happens to be 25 fps.
  //
  // The estimator is the MEDIAN of recent inter-capture deltas, which is the
  // capture period even when frames are missing: a hole doubles one delta
  // rather than shifting all of them, so the median is unmoved until more than
  // half the intervals have holes. A mean would be dragged by every drop.
  const VP_CAD = cfg.vpCadence !== false;  // ?vpcad=0 restores the cfg.fps grid
  const VP_CAD_MIN = 12;                   // samples before the estimate is trusted
  const VP_CAD_BAND = 0.08;                // re-anchor only on a real regime change
  const vpDeltas = [];
  let vpLastTs = null;
  let vpIus = null;                        // learned peer capture interval, µs
  // Slot interval in µs: the learned one once it exists, else the old behaviour
  // exactly. With ?vpcad=0 this is the shipped line for line.
  const vpI = () => (VP_CAD && vpIus != null ? vpIus : 1e6 / cfg.fps);
  function vpNoteCadence(tsUs) {
    if (!VP_CAD) return false;
    if (vpLastTs != null) {
      const d = tsUs - vpLastTs;
      // 4 ms..500 ms == 250..2 fps. Anything outside is a reorder, a capture
      // reset or a loop point in a file, and must not enter the estimate --
      // a timestamp reset is precisely what poisons `mco` elsewhere in this
      // file, and the same trap is available here.
      if (d > 4000 && d < 500000) {
        vpDeltas.push(d);
        if (vpDeltas.length > 60) vpDeltas.shift();
      }
    }
    vpLastTs = tsUs;
    if (vpDeltas.length < VP_CAD_MIN) return false;
    const sorted = [...vpDeltas].sort((a, b) => a - b);
    const est = sorted[sorted.length >> 1];
    if (vpIus != null && Math.abs(est - vpIus) / vpIus <= VP_CAD_BAND) return false;
    vpIus = est;
    vpStats.recadence = (vpStats.recadence | 0) + 1;
    return true;                           // caller re-anchors the metronome
  }
  const vpStats = { presents: 0, holds: 0, drops: 0, skips: 0, resyncs: 0, early: 0 };

  function vpPresent(frame, idx, at) {
    vpLastK = idx;
    paintRemote(frame);
    frame.close();
    lastDrawAt = now();
    vpStats.presents++;
    stats.presentAt.push(+lastDrawAt.toFixed(1));
    if (stats.presentAt.length > 1800) stats.presentAt.shift();
    // Present probe (#14): decode output → this draw. The v-presenter is the
    // shipped present path, and until this line only the paint-on-arrival
    // path fed presentLagMs — so the probe read null on every default call
    // and glassToGlass could not be composed. `at` is stamped at enqueue,
    // which is decode output by construction (vpEnqueue is called from the
    // decoder's frame callback).
    if (at != null) {
      stats.presentLagMs.push(+(lastDrawAt - at).toFixed(1));
      if (stats.presentLagMs.length > 900) stats.presentLagMs.shift();
    }
  }

  function vpEnqueue(frame) {
    // A changed cadence changes the UNIT every queued idx is expressed in, so
    // the metronome must be re-anchored rather than reinterpreted. Rare by
    // construction (an 8% deadband on a 60-sample median), and the queue is at
    // most VPQ_MAX=3 frames, so the cost is bounded and counted.
    const recad = vpNoteCadence(frame.timestamp);
    const I_us = vpI();
    const I_ms = I_us / 1000;
    if (recad || vpTs0 == null) {
      for (const q of vpq.splice(0)) { q.frame.close(); vpStats.drops++; }
      vpTs0 = frame.timestamp; vpT0 = now() + VP_D_SLOTS * I_ms;
      vpLastK = -1; vpShift = 0;
    }
    const idx = Math.round((frame.timestamp - vpTs0) / I_us);
    if (idx <= vpLastK) { frame.close(); vpStats.skips++; return; } // stale: never present backwards in time
    if (now() > vpT0 + idx * I_ms + VPQ_MAX * I_ms) {
      // Missed its slot by more than the queue covers (FEC-hold heal, resume
      // keyframe): jump the metronome so THIS frame presents one interval
      // from now; future slots shift with it. The only place frames are
      // dropped for timing.
      vpT0 = now() + I_ms - idx * I_ms;
      vpShift = 0;
      vpStats.resyncs++;
      for (const q of vpq.splice(0)) { q.frame.close(); vpStats.drops++; }
    }
    if (vpq.length >= VPQ_MAX) {
      // Full: present the due-soonest NOW (≤1 slot early) instead of dropping
      // anything, and pull the phase one slot earlier (bounded servo) so the
      // queue stops refilling — drop-oldest here was failure mode 2 above.
      const q = vpq.shift();
      vpStats.early++;
      vpPresent(q.frame, q.idx, q.at);
      if (vpShift > VP_SHIFT_LO) { vpT0 -= I_ms; vpShift--; vpStats.resyncs++; }
    }
    vpq.push({ frame, idx, at: now() });
    if (!vpRunning) { vpRunning = true; requestAnimationFrame(vpTick); }
  }

  function vpTick() {
    if (closed || avEngaged || !cfg.vprev) { vpRunning = false; return; }
    requestAnimationFrame(vpTick);
    const I_ms = vpI() / 1000;
    const k = Math.floor((now() - vpT0) / I_ms);
    if (k === vpLastK) return;             // one present per slot (60 Hz rAF, 30 fps supply)
    let best = -1;
    for (let i = 0; i < vpq.length; i++) if (vpq[i].idx <= k) best = i;
    if (best < 0) {
      // Nothing due. Under-run holds the previous frame (canvas untouched,
      // never tears) — UNLESS the head sits further in the future than the
      // queue covers: then supply has outrun the metronome phase (failure
      // mode 1 above). Pull the phase forward so the head is due now —
      // counted, no drops, never queue growth.
      if (vpq.length && vpq[0].idx > k + VPQ_MAX) {
        vpT0 = now() - vpq[0].idx * I_ms;
        vpStats.resyncs++;
      } else vpStats.holds++;
      return;
    }
    for (let i = 0; i < best; i++) { vpq[i].frame.close(); vpStats.skips++; }
    const { frame, idx, at } = vpq[best];
    vpq.splice(0, best + 1);
    vpPresent(frame, idx, at);
  }

  // ── §12–13: the stall machine ─────────────────────────────────────────────
  // §12's controller outputs a REGIME, never a bitrate — and it has no wire to
  // the encoder (quality is a constant). The mild regimes are named readings of
  // machinery that already exists: the AIMD governor paces admission on the
  // receiver's reported age (squeeze), and time — buffer depth, not quality —
  // absorbs transient deficits (absorb). This classifier names those regimes
  // from the freshest signal there is (per-delivered-frame age, receiver-side)
  // and owns the two states that need new behaviour:
  //
  //   VIDEO HELD (§13): C < R sustained — age over the AIMD halving bound AND
  //     delivery railed at the pacer's floor for a dwell. The RECEIVER detects
  //     the deficit but the SENDER sheds (rule 1: a receiver-side drop would
  //     leave the sender pushing 11 Mbps into a pipe that cannot take it —
  //     shedding at the source is what gives audio its headroom). So detection
  //     sends LANE_SHED over ctl; the sender stops admitting captures, the
  //     worker purges its FIFO, and lane P (1 fps crisp JPEG stills on their
  //     own reliable channel) takes over presence: a frozen frame reads as
  //     broken, a still updating once a second reads as deliberate (§4).
  //     Exit: lane P's own arrival age is the capacity probe — stills are the
  //     same size class as video frames, so "2 s clean" of them (the state
  //     diagram's own words) means the pipe has room; LANE_RESUME follows.
  //
  //   Resume never replays the backlog (rule 2): the sender discards every
  //   queued frame and emits a FRESH KEYFRAME at the current instant — a hard
  //   cut between two pristine images, which the eye reads as an edit rather
  //   than a failure (rule 3). That only works because no bad frame was ever
  //   shown: the held image is the last COMPLETE frame, and the canvas keeps
  //   it on screen by doing nothing.
  let stallRegime = 'nominal'; // nominal | squeeze | absorb | held
  let armedAt = 0;             // now() at arm — transition timestamps are relative
  let cleanSince = 0;          // continuous-clean start (2 s clean → nominal)
  let badSince = 0;            // continuous-terrible start (dwell → shed)
  let shedded = false;         // SENDER side: our uplink is shed (peer asked)
  // #75 RECEIVER side, as seen from here: when the peer last told us it is held.
  // Cleared only by the peer's LANE_RESUME — never by our own dead-man.
  let peerHeldAt = 0;
  const STILL_HOLD_MAX_MS = 90000; // > stallMaxHoldMs (60 s): past this the peer is out by some other route
  let sheddedAt = 0;           // when — the dead-man switch's zero point
  let shedAt = 0;              // RECEIVER side: when we entered held
  let shedMaxId = -1;          // ids ≤ this predate the shed: stale, drop on sight
  let resumeSentAt = 0;
  let stallForced = false;     // ?stallforce= test hook fired
  let stallTimer = 0;
  const clsWin = [];           // { t, age } of delivered frames, 1 s sliding
  const delTs = [];            // delivery timestamps, 1 s sliding (delivery rate)
  const lpAge = [];            // lane-P arrival ages — the held-exit probe
  const stallLog = [];         // recent transitions, for the snapshot

  function setRegime(to, why) {
    if (stallRegime === to) return;
    const tr = { t: Math.round(now() - armedAt), from: stallRegime, to, why };
    stallLog.push(tr);
    if (stallLog.length > 12) stallLog.shift();
    stallRegime = to;
    L('stall-state', tr);
    try { onStall?.(to, tr); } catch { /* the UI must never break the lane */ }
  }

  // Receiver-side detection, sender-side action (§13 rule 1). Resetting our
  // reassembly state is half the message: the sender's purge means pre-shed
  // frames may never arrive, so nothing before the post-resume keyframe is
  // worth waiting for.
  function enterHeld(why) {
    badSince = 0; cleanSince = 0;
    shedAt = now();
    shedMaxId = lastDecoded;
    hold.clear(); recent.clear(); groups.clear(); fragReqIds.clear();
    if (holdTimer) { clearTimeout(holdTimer); holdTimer = 0; }
    haveKey = false; lastDecoded = -1;
    // Stale queued frames must not paint after the cut — the held image is the
    // last COMPLETE frame, and only the fresh keyframe replaces it.
    for (const q of avq.splice(0)) { try { q.frame.close(); } catch { /* already closed */ } }
    lpAge.length = 0;
    stats.shedSent++;
    ctlSend({ t: 'shed' });
    setRegime('held', why);
  }

  function sendResume(why) {
    resumeSentAt = now();
    stats.resumeSent++;
    ctlSend({ t: 'resume' });
    L('stall-resume-sent', { why });
  }

  // The held-exit probe. Lane P stills ride the same path the video would
  // return to; their age (sender wall + the ctl ping offset — the same
  // construction as video frame age) is a direct capacity sample. "Capacity
  // restored + keyframe decoded" per the diagram: this sends the request, the
  // keyframe completes it (onLaneFrame's held branch).
  function exitProbe() {
    const t = now();
    if (t - shedAt < cfg.stallMinHoldMs) return;
    // The escape hatch: if lane P itself never arrives (channel dead, path
    // dead), held must not be forever. One resume probe per stallMaxHoldMs —
    // if capacity is not back the classifier re-sheds inside its dwell.
    if (t - shedAt > cfg.stallMaxHoldMs && t - resumeSentAt > cfg.stallMaxHoldMs) {
      sendResume('maxhold');
      return;
    }
    while (lpAge.length && t - lpAge[0].t > cfg.stallResumeCleanMs) lpAge.shift();
    if (!lpAge.length) return;
    // #63's law applied to the EXIT, which the first pass missed: lane-P ages
    // contain the same one-way propagation the video ages do, so an absolute
    // 250 ms gate left ~80 ms of headroom on a 170 ms-floor path and the clean
    // resume almost never fired — measured live 2026-08-19 23:26: "holding"
    // stood for minutes while the stills were arriving fine. Judge the QUEUE:
    // stills within 100 ms of the path floor mean the pipe is clear.
    const lpBase = pathFloorMs(); // #72 a negative floor is measurement error; it must never tighten a gate — and #75, nor may it make this gate distance-blind
    if (lpAge.every((s) => s.age - lpBase < (lpBase ? 100 : 250))) sendResume('clean');
  }

  // #75 THE FALLBACK BEHIND #72's CLAMP WAS DISTANCE-BLIND.
  // A negative floor is a broken measurement, and clamping it to zero is right —
  // a negative must never tighten a gate. But every consumer below then reads
  // that zero as "this path has no propagation in it" and switches to its
  // ABSOLUTE band, which is the distance-blind branch. So a floor estimator that
  // fails on a long path does not merely lose precision: it silently selects the
  // exact behaviour the whole #63/#64/#68/#72 line of work exists to remove.
  //
  // Measured 2026-08-20 at a simulated 440 ms RTT, both ends: ageFloorMs read
  // -2176 ms and -939 ms, so clsBase was 0, so a 531 ms age was judged against
  // the 250 ms absolute band and the lane went to `held` for the rest of the call.
  //
  // The ctl channel's round trip measures the same distance and cannot go
  // negative. Half of it is a WORSE floor — it carries the return path and any
  // queue standing on it — but it is the right kind of number, and on a long path
  // an overestimate of propagation only makes a gate too patient. Zero makes it
  // blind. `?agefloorrtt=0` restores the plain clamp.
  const pathFloorMs = () => {
    const f = Number.isFinite(ageFloorMs) ? ageFloorMs : NaN;
    if (f > 0) return f;
    if (cfg.l2AgeFloorRtt === false) return 0;
    const rtt = stats.rttMs;
    return Number.isFinite(rtt) && rtt > 0 ? rtt / 2 : 0;
  };
  function classify() {
    const t = now();
    if (stallRegime === 'held') { exitProbe(); return; }
    while (clsWin.length && t - clsWin[0].t > 1000) clsWin.shift();
    while (delTs.length && t - delTs[0].t > 1000) delTs.shift();
    if (!clsWin.length) { cleanSince = 0; badSince = 0; return; } // no deliveries, no evidence
    const ages = [...clsWin].sort((a, b) => a.age - b.age);
    const p50 = +ages[Math.min(ages.length - 1, Math.floor(0.5 * ages.length))].age.toFixed(1);
    const fps = delTs.length;
    // #63: the same distance correction as the AIMD pacer — these bands
    // contained one-way propagation, so on a 337 ms RTT path `nominal` was
    // unreachable and the regime oscillated absorb/held forever (measured live
    // 2026-08-19: held -> resume -> 303 ms of nominal -> back to absorb).
    // Judged on queue = age - path floor when the floor is known.
    const clsBase = pathFloorMs(); // #72 clamp + #75 rtt/2 fallback: see pathFloorMs
    const q50 = p50 - clsBase;
    // Regime naming. The bands are the AIMD governor's own thresholds: under
    // its increase bound is nominal (D at D_min), the hysteresis band is
    // squeeze (D growing to cover jitter), above its halving bound is absorb
    // (the shock absorber spending time). Worse moves apply immediately;
    // nominal re-entry needs the diagram's 2 s clean.
    const want = q50 < (clsBase ? 100 : 250) ? 'nominal' : q50 < (clsBase ? 250 : cfg.stallShedAgeMs) ? 'squeeze' : 'absorb';
    if (want === 'nominal') {
      if (stallRegime !== 'nominal') {
        if (!cleanSince) cleanSince = t;
        if (t - cleanSince >= cfg.stallResumeCleanMs) { cleanSince = 0; setRegime('nominal', '2 s clean'); }
      }
    } else {
      cleanSince = 0;
      setRegime(want, `age p50 ${p50}`);
    }
    // SHED (§12: "C < R, sustained — backlog will exceed budget. Drop lane B
    // entirely."): age p50 over D_max (400 ms) *is* the backlog-over-budget
    // condition — half of delivered frames are already older than the maximum
    // playout delay the spec allows, so the shock absorber is spent. Delivery
    // at/below the pacer's floor counts too (starvation even at bounded age).
    // Either, for the whole dwell — and only after startup, where the GCC ramp
    // legitimately looks like this.
    if (t - armedAt > 10000 && (q50 > (clsBase ? 250 : cfg.stallShedAgeMs) || fps <= cfg.stallShedFps)) {
      if (!badSince) badSince = t;
      if (t - badSince >= cfg.stallShedDwellMs) enterHeld('capacity');
    } else badSince = 0;
  }

  // ── Lane P (§4/§13): crisp stills while held ──────────────────────────────
  // Off a captured VideoFrame via OffscreenCanvas.convertToBlob at q0.9-ish —
  // no second video encoder needed (§4). A sharp JPEG is not a degraded video
  // frame: it is a different, honest representation, and the UI labels it.
  let stillCv = null, stillCtx = null, stillBusy = false, lastStillAt = 0;
  // #75 The still is also the HELD-EXIT PROBE, so its size is a latency budget.
  //
  // `exitProbe` asks whether stills are arriving within 100 ms of the path floor
  // and resumes video when they are. `lpAge` is `now - sendWall`, so it contains
  // the still's OWN serialisation time — and a 960 px q0.85 JPEG of a real face
  // is 34-73 KB (measured, both ends of the live call 2026-08-20). On the 0.6
  // Mbps budget a shed link is sitting at, 34 KB is 453 ms of bytes and 73 KB is
  // 970 ms. **The probe cannot satisfy a 100 ms gate on a slow link no matter how
  // clear the pipe is, because the probe IS most of the delay it measures.**
  // Measured consequence on that call: the Chromium peer sat in `held` for 60 s
  // at a time, escaping only via the `maxhold` hatch, never once via `clean`, with
  // lpAgeP50 672 ms against a 200 ms floor. Its video was off for the whole call.
  //
  // That is `control-plane-rides-its-own-resource` in its self-poisoning form: a
  // health probe sent over the resource it reports on, sized without reference to
  // that resource, so it reports congestion it created itself.
  //
  // So the still is sized to ARRIVE, not to look good: at most `lpMs` worth of
  // the current budget. 100 ms of 0.6 Mbps is 7.5 KB; 100 ms of 8 Mbps is 100 KB,
  // so a healthy link still gets the crisp still §4 asks for and only a starved
  // one gets a smaller one — which is the correct trade, because on a starved
  // link the alternative to a small still is no video at all for a minute.
  //
  // Converged by feedback on the LAST still's actual bytes rather than by a
  // model of JPEG: content decides compressibility and no formula here can.
  // Multiplicative on area, damped, and clamped to [lpMinWidth, lpWidth].
  // `?lpms=0` restores the fixed width.
  let stillW = cfg.lpWidth;
  function stillTargetBytes() {
    if (!cfg.lpMs) return 0;
    const mbps = rcBudgetMbps > 0 ? rcBudgetMbps : cfg.l2RcMinMbps;
    return (cfg.lpMs / 1000) * (mbps * 1e6) / 8;
  }
  function stillFit(bytes) {
    const target = stillTargetBytes();
    if (!target || !(bytes > 0)) return;
    // Area scales roughly with bytes, so width scales with the square root — and
    // the response is ASYMMETRIC for the same reason everything else here is.
    // Shrinking is urgent: while the peer is held this probe is the only way out
    // and every still that does not fit is another second frozen, so one step is
    // allowed to take the width to 30% and land on the answer immediately.
    // Growing costs nothing to defer, so it is capped at +15% per still.
    const k = Math.min(1.15, Math.max(0.3, Math.sqrt(target / bytes)));
    stillW = Math.round(Math.min(cfg.lpWidth, Math.max(cfg.lpMinWidth, stillW * k)));
  }
  function maybeStill(frame) {
    if (dcLaneP?.readyState !== 'open') return;
    const t = now();
    if (t - lastStillAt < 1000 / cfg.lpFps || stillBusy) return;
    lastStillAt = t;
    const w = Math.min(cfg.lpMs ? stillW : cfg.lpWidth, frame.displayWidth);
    const h = Math.round((w * frame.displayHeight) / frame.displayWidth);
    if (!stillCv) { stillCv = new OffscreenCanvas(w, h); stillCtx = stillCv.getContext('2d'); }
    if (stillCv.width !== w || stillCv.height !== h) { stillCv.width = w; stillCv.height = h; }
    try { stillCtx.drawImage(frame, 0, 0, w, h); } catch { return; }
    stillBusy = true;
    stillCv.convertToBlob({ type: 'image/jpeg', quality: cfg.lpQ })
      .then(async (blob) => {
        const jb = await blob.arrayBuffer();
        const out = new ArrayBuffer(8 + jb.byteLength);
        new DataView(out).setFloat64(0, now()); // f64 sendWallMs — same age construction as video
        new Uint8Array(out, 8).set(new Uint8Array(jb));
        if (!closed && dcLaneP?.readyState === 'open') {
          dcLaneP.send(out);
          stats.lpSent++;
          stats.lpBytes += out.byteLength;
          stillFit(out.byteLength);
          stats.lpW = stillW;
        }
      })
      .catch(() => { /* a still that failed to encode is skipped, not repaired */ })
      .finally(() => { stillBusy = false; });
  }

  function onLaneP(data) {
    if (!(data instanceof ArrayBuffer) || data.byteLength < 9) return;
    const wall = new DataView(data).getFloat64(0);
    stats.lpRecv++;
    const t = now();
    if (stats.clockOffsetMs != null) {
      const age = t - (wall + stats.clockOffsetMs);
      if (age >= 0 && age < 30000) {
        lpAge.push({ t, age });
        stats.lpAgeMs.push(+age.toFixed(1));
        if (stats.lpAgeMs.length > 900) stats.lpAgeMs.shift();
      }
    }
    if (stallRegime !== 'held') return; // a late still must never overwrite live video
    exitProbe();
    if (!ctx2d) return; // l2canvas=0 arm: the probe counts, the paint is skipped
    createImageBitmap(new Blob([data.slice(8)], { type: 'image/jpeg' }))
      .then((bmp) => {
        if (closed || !ctx2d) { bmp.close(); return; }
        try {
          ctx2d.drawImage(bmp, 0, 0, displayCanvas.width, displayCanvas.height);
          stats.lpPainted++;
          stats.presentAt.push(+now().toFixed(1)); // stills paint immediately — no scheduling (§13)
          if (stats.presentAt.length > 1800) stats.presentAt.shift();
        } catch { /* paint raced a close */ }
        bmp.close();
      })
      .catch(() => { /* one bad still is not an event */ });
  }

  async function setupDecoder(m) {
    if (dec) return;
    const config = { codec: m.codec, codedWidth: m.width, codedHeight: m.height, optimizeForLatency: true };
    // Task #48: same hardware preference as the encoder, same rule — the hint
    // is dropped before the lane ever is.
    if (cfg.l2Hw) config.hardwareAcceleration = cfg.l2Hw;
    let sup = await VideoDecoder.isConfigSupported(config);
    if (!sup?.supported && config.hardwareAcceleration) {
      delete config.hardwareAcceleration;
      sup = await VideoDecoder.isConfigSupported(config);
    }
    if (!sup?.supported) {
      // CAPABILITY ANSWER-BACK (found on Android, 2026-08-16: a build whose
      // WebCodecs decodes VP9/AV1/VP8 but NO H.264 profile at all). The sender
      // cannot know what we decode, so a bare failure here killed the whole
      // lossless lane over one codec string. Instead: probe what we CAN
      // decode, tell the sender over the same ctl channel, and give it 5 s to
      // re-ladder before conceding the lane the old way.
      const probe = [m.codec, 'vp09.00.10.08', 'av01.0.04M.08',
        'avc1.4d0028', 'avc1.42e028', 'vp8'];
      const can = [];
      for (const c of [...new Set(probe)]) {
        try {
          const s = await VideoDecoder.isConfigSupported({ codec: c, codedWidth: 1920, codedHeight: 1080, optimizeForLatency: true });
          if (s?.supported) can.push(c);
        } catch { /* not this one */ }
      }
      if (can.length && !decNakTimer) {
        L('tape-cfg-nak', { asked: m.codec, can });
        ctlSend({ t: 'cfg-nak', can });
        decNakTimer = setTimeout(() => {
          if (!dec) fail('decoder-configure', new Error(`decoder unsupported: ${m.codec} (nak sent, no usable cfg followed)`));
        }, 5000);
        return;
      }
      throw new Error(`decoder unsupported: ${m.codec}`);
    }
    if (decNakTimer) { clearTimeout(decNakTimer); decNakTimer = null; }
    ctx2d = displayCanvas
      ? displayCanvas.getContext('2d', { alpha: false, desynchronized: true })
      : null;
    if (!ctx2d) {
      // No canvas AND no generator is unreachable on the shipped default (l2Canvas is
      // on unless `?l2canvas=0`), but on an engine without the breakout box this is the
      // one place the lane still needs it. Say so instead of throwing ReferenceError
      // three frames into the call, where it reads as a decoder failure.
      if (typeof MediaStreamTrackGenerator === 'undefined') {
        throw new Error('no display canvas and no MediaStreamTrackGenerator: use l2canvas=1 on this engine');
      }
      gen = new MediaStreamTrackGenerator({ kind: 'video' });
      writer = gen.writable.getWriter();
    }
    dec = new VideoDecoder({
      output: (frame) => {
        const t = now();
        decOutAt.push(t);
        if (decOutAt.length > 64) decOutAt.splice(0, decOutAt.length - 64);
        if (stats.clockOffsetMs != null && peerMco != null) {
          // frame.timestamp is the sender's CAPTURE clock: mapped to the
          // sender's wall clock by its reported mco, then into ours by the
          // ping offset (µs → ms). Capture → decode-out, the whole lane
          // except the display.
          const full = t - (frame.timestamp / 1000 + peerMco + stats.clockOffsetMs);
          if (full >= 0 && full < 30000) {
            stats.fullAgeMs.push(+full.toFixed(1));
            if (stats.fullAgeMs.length > 900) stats.fullAgeMs.shift();
          }
        }
        if (ctx2d) {
          // §10 engagement check: both mappings ready → queue for vsync
          // presentation from here on. Sticky by design (see avEngaged).
          if (!avEngaged && !avGaveUp && avEngageable() && avMapSane(frame.timestamp)) {
            avEngaged = true;
            avEngagedAt = now();
            avLastPresentAt = 0;
            L('tape-avsync-engaged', { lane: 'rtp', peerAvDeltaUs: Math.round(peerAvDeltaUs), offsetMs: avsync.offsetMs });
            // #33 handoff: frames queued to the v-presenter must not strand.
            for (const q of vpq.splice(0)) { q.frame.close(); vpStats.drops++; }
            requestAnimationFrame(avTick);
          }
          if (avEngaged) {
            avEnqueue(frame);
            return; // the vsync loop owns presentation — and closing — now
          }
          // #33: cadence-locked presentation (default). The metronome owns
          // presentation — and closing — from here. `?vprev=0` falls through
          // to §17.8's paint-on-arrival, line for line (the control arm).
          if (cfg.vprev) {
            vpEnqueue(frame);
            return;
          }
          // Paint-on-arrival. Backing store tracks the stream's upright size so
          // the CSS object-fit: cover crop matches the old <video> exactly.
          paintRemote(frame);
          frame.close();
          lastDrawAt = t;
          stats.presentAt.push(+t.toFixed(1));
          if (stats.presentAt.length > 1800) stats.presentAt.shift();
          // Present probe: draw → next composite. rAF fires once per vsync;
          // one pending at a time, stamped from the latest draw.
          if (!rafPending) {
            rafPending = true;
            requestAnimationFrame(() => {
              rafPending = false;
              if (closed) return;
              stats.presentLagMs.push(+(now() - lastDrawAt).toFixed(1));
              if (stats.presentLagMs.length > 900) stats.presentLagMs.shift();
            });
          }
        } else {
          writer.write(frame).catch(() => frame.close());
        }
      },
      error: () => { stats.decodeErrors++; haveKey = false; requestKey('decode-error'); },
    });
    dec.configure(config);
    L('tape-decoder', { lane: 'rtp', ...config, canvas: !!ctx2d });
    if (!ctx2d) {
      try { onRemote(new MediaStream([gen])); } catch (e) { fail('attach-remote', e); return; }
    }
    ctlSend({ t: 'ready' });
  }

  async function setupEncoder() {
    const size = encodeSize(curTrack, cfg);
    const config = {
      codec: cfg.codec, width: size.width, height: size.height, framerate: cfg.fps,
      latencyMode: 'realtime', bitrateMode: 'quantizer', avc: { format: 'annexb' },
    };
    // Task #48 energy A/B (`?l2hw=hw|sw`). A preference, not a demand: if the
    // engine rejects the config WITH the hint, the hint is dropped rather than
    // the lane — an energy experiment must never be able to cost the picture.
    if (cfg.l2Hw) config.hardwareAcceleration = cfg.l2Hw;
    // FIXED QP IS NOT UNIVERSAL. Measured 2026-08-03 (testbed/wkenc.mjs): WebKit 26.5
    // throws `TypeError: Type error` for `bitrateMode:'quantizer'` — the value is not in
    // its enum, so even isConfigSupported THROWS rather than returning false, which is
    // why this surfaced as a bare 'encoder-setup' failure with no detail. WebKit accepts
    // 'constant' and 'variable' at 1080p, and every other option in this set.
    //
    // So constant-quality encoding is unavailable there and rate control has to become a
    // bitrate rather than a quantizer. That is a REAL downgrade of the mechanism this
    // lane's quality comes from, and it is recorded as one: `rateControl` below is the
    // field that keeps a VBR call from ever being read as a fixed-QP one.
    let sup = null;
    // `?l2rcmode=vbr` FORCES the fallback arm on an engine that supports fixed QP.
    //
    // This exists to make the arm MEASURABLE. WebKit is the only engine that runs VBR in
    // production (isConfigSupported THROWS there for bitrateMode:'quantizer'), but Playwright's
    // WebKit ships its own built-in mock camera and takes no fake-capture file — so there is no
    // known reference frame to score a received picture against, and VMAF is impossible on that
    // side. Forcing the same rate-control path on Chromium scores the thing that is actually
    // unmeasured, against the real 1080p fixture, through the existing capture rig.
    //
    // It deliberately does NOT confound engine with rate control: this measures what VBR costs,
    // not what WebKit costs. Those are two questions and answering them together would leave
    // neither answered.
    let quantizerOk = cfg.l2RcMode !== 'vbr';
    // PROFILE LADDER (found on the Android emulator lane, 2026-08-16, and real
    // for any device whose encoder tops out below High): the configured codec
    // is avc1.640028 — H.264 High — and some MediaCodec encoders only offer
    // Main or Constrained Baseline. Before this ladder, that single string
    // rejection killed the ENTIRE lossless lane ("config unsupported even as
    // VBR") and the call dropped to the plain-RTP picture (VMAF 77 vs 99.7).
    // A lower profile costs some compression efficiency; losing the lane costs
    // the picture. The receiver is told the NEGOTIATED codec (descSend below),
    // so nothing downstream assumes High.
    // Tier 1 is the configured codec — the proven default path stays
    // byte-identical for every engine that supports it. Tier 2 exists for the
    // engines that don't (or whose PEER said cfg-nak): VP9/AV1 come BEFORE the
    // lower H.264 profiles because they were measured carrying quantizer mode
    // where H.264 only offered VBR (Android, 2026-08-16) — and fixed QP is the
    // mechanism this lane's quality comes from. The per-frame quantizer call
    // already speaks all three codec dialects (see enc.encode below).
    let codecLadder = [cfg.codec, 'vp09.00.10.08', 'av01.0.04M.08'];
    if (/^avc1\./.test(cfg.codec)) {
      const level = cfg.codec.slice(-2); // keep the configured level
      codecLadder.push(`avc1.4d00${level}`, `avc1.42e0${level}`);
    }
    codecLadder.push('vp8');
    codecLadder = [...new Set(codecLadder)];
    // A cfg-nak from the peer constrains the ladder to what it can decode.
    if (peerDecCan) {
      const allowed = codecLadder.filter((c) => peerDecCan.includes(c));
      if (allowed.length) codecLadder = allowed;
    }
    const negotiate = async () => {
      // Try fixed QP (with, then without, the hw hint), then VBR the same way.
      let qOk = cfg.l2RcMode !== 'vbr';
      try {
        if (!qOk) throw new Error('forced vbr');
        sup = await VideoEncoder.isConfigSupported(config);
        if (!sup?.supported) qOk = false;
        else if (sup.config?.bitrateMode && sup.config.bitrateMode !== 'quantizer') qOk = false;
      } catch { qOk = false; }
      if (!qOk && config.hardwareAcceleration && cfg.l2RcMode !== 'vbr') {
        // Retry fixed QP without the hw hint before downgrading rate control:
        // a hint the engine dislikes must not silently buy the VBR arm.
        delete config.hardwareAcceleration;
        try {
          sup = await VideoEncoder.isConfigSupported(config);
          qOk = !!sup?.supported && (!sup.config?.bitrateMode || sup.config.bitrateMode === 'quantizer');
        } catch { qOk = false; }
      }
      if (qOk) return true;
      config.bitrateMode = 'variable';
      // Not a tuned number. It is the same 12 Mbps ceiling the RTP sender already
      // carries, so this arm is not quietly given a different budget than the one the
      // fixed-QP arm competes for. What it actually BUYS is unmeasured until scored.
      config.bitrate = cfg.l2VbrBps || 12_000_000;
      sup = await VideoEncoder.isConfigSupported(config);
      if (!sup?.supported && config.hardwareAcceleration) {
        delete config.hardwareAcceleration;
        sup = await VideoEncoder.isConfigSupported(config);
      }
      return sup?.supported ? false : null; // false = vbr, null = this codec is out
    };
    let verdict = null;
    for (const codec of codecLadder) {
      // Each candidate starts from a clean slate — a prior VBR attempt must not
      // leak its bitrateMode into the next codec's quantizer try.
      config.codec = codec;
      config.bitrateMode = 'quantizer';
      delete config.bitrate;
      if (cfg.l2Hw) config.hardwareAcceleration = cfg.l2Hw; else delete config.hardwareAcceleration;
      verdict = await negotiate();
      if (verdict !== null) {
        if (codec !== cfg.codec) L('tape-codec-ladder', { asked: cfg.codec, using: codec });
        break;
      }
    }
    if (verdict === null) throw new Error(`config unsupported even as VBR: ${codecLadder.join(', ')}`);
    quantizerOk = verdict === true;
    rateControl = quantizerOk ? 'quantizer' : 'vbr';
    stats.rateControl = rateControl;
    enc = new VideoEncoder({
      output: (chunk) => { try { onEncoded(chunk); } catch (e) { fail('send-path', e); } },
      error: (e) => fail('encoder', e),
    });
    enc.configure(config);
    // Set only once the encoder really holds it. Setting it before the await above
    // let the pump see a config `enc` had not been given yet, on a null `enc`.
    encConfig = config; // kept so a mid-call resize can re-issue it with new dims
    stats.encW = config.width; stats.encH = config.height;
    L('tape-encoder', { lane: 'rtp', ...config, rateControl,
      rcForced: cfg.l2RcMode === 'vbr' ? 1 : 0,
      hw: sup.config?.hardwareAcceleration ?? null });
    // See lane 1: announce what we encoded, not what we wanted. `descSend` (not
    // `ctlSend`) because with §6.1's shared encoder this one description is what
    // EVERY peer's decoder is configured from — including one whose ctl channel
    // opens after this line ran (the link replays it at that half's arm).
    // config.codec, NOT cfg.codec: the ladder may have negotiated a lower
    // profile, and the receiver must configure its decoder for what will
    // actually arrive.
    descSend({ t: 'cfg', codec: config.codec, width: config.width, height: config.height, qp: cfg.qp });
  }

  function onEncoded(chunk) {
    if (closed) return;
    // A frame encoded through the shed transition is dropped unsent: the
    // receiver asked for the shed and has reset its chain, so nothing it
    // references will be waited for — the chain restarts at the resume
    // keyframe. Counted separately: an encoded frame dropped is never free.
    if (shedded) { stats.shedDroppedEnc++; return; }
    const t0 = encCallAt.shift();
    if (t0 != null) {
      stats.encLatMs.push(+(now() - t0).toFixed(1));
      if (stats.encLatMs.length > 900) stats.encLatMs.shift();
    }
    const buf = new ArrayBuffer(chunk.byteLength);
    chunk.copyTo(buf);
    const isKey = chunk.type === 'key';
    if (isKey) stats.keyframesSent++;
    stats.qpBytes.push(chunk.byteLength);
    if (stats.qpBytes.length > 900) stats.qpBytes.shift();
    stats.encBytesTotal += chunk.byteLength; stats.encFramesTotal++;
    rcOnEncoded(chunk.byteLength, isKey); // #44
    stats.framesEncoded++;
    encMeter.note();
    inFlight++; // counted before the round trip so the capture loop cannot slip one in
    // §6.1: one encoded bitstream, N transport halves. The fan runs FIRST because
    // the postMessage below transfers `buf` — each peer's worker needs its own
    // copy to XOR into its own parity window and hold in its own re-splice ring.
    // With no link there is no fan and this is the single postMessage that
    // shipped, byte for byte.
    const msg = { type: 'frame', id: frameId++, key: isKey, ts: chunk.timestamp, wall: now(), buf };
    if (link) link.fanEncoded(half, msg);
    worker.postMessage(msg, [buf]);
    // ?sendnow=1 (task #41 lever 1): pull a carrier tick for the frame just
    // queued instead of waiting for the auto-capture phase. The postMessage
    // lands in the worker FIFO in <1 ms; the requested tick reaches the
    // transform ~5 ms later (probe-measured), so the FIFO is populated first
    // in the common case. If a slow postMessage ever loses the race, the
    // requested tick goes out empty (the already-existing idle-tick case) and
    // the frame rides the next auto tick — today's behaviour, never worse.
    // Key-dup/parity/re-splice latency is redundancy, not media — those keep
    // riding ordinary ticks.
    // In MANUAL carrier mode (?ctickhz=0) this is not an optimisation, it is the
    // only thing that emits a frame at all: captureStream(0) produces nothing on
    // its own. That is also, in hindsight, why ?sendnow=1 measured as a complete
    // no-op -- 3072 requestFrame calls against an auto-cadence track, where the
    // compositor was already going to tick anyway and the request bought nothing.
    // The same call against a zero-rate track is the whole transport.
    if (SENDNOW || cfg.l2CarrierHz === 0 || pre.genMode) {
      stats.sendNowReqs++;
      try { pre.emitCarrier?.(); } catch { /* the carrier must never take the call down */ }
    }
  }

  async function pumpCapture() {
   // Outer loop so the pump survives its source being replaced. A camera flip
   // stops the old track, which ends this reader; before this loop existed the
   // pump simply returned and the lane stayed silent for the rest of the call.
   // Measured on production: the far end fell from 29.4 fps to 0.4 fps — lane P
   // stills, not video — and never recovered, with no RTP fallback either.
   // adoptTrack() points curTrack at the new sensor and cancels the reader; the
   // re-attach happens here.
   for (;;) {
    const mine = curTrack;
    if (!mine || closed) return;
    // frameReader() rather than MediaStreamTrackProcessor directly: WebKit has no
    // breakout box, and that single gap is what kept this lane — and its VMAF 99.7
    // picture — off every Safari-family call.
    const fr = frameReader(mine);
    procReader = fr.reader;
    if (fr.how !== lastFrameHow) { lastFrameHow = fr.how; log?.('tape-framesource', { how: fr.how }); }
    let swapped = false;
    for (;;) {
      const { done, value: frame } = await procReader.read();
      if (done) { swapped = !closed && curTrack !== mine && !!curTrack; break; }
      if (closed) { frame.close(); return; }
      stats.framesIn++;
      // #14 probe: how long the frame sat inside Chrome between the capture
      // timestamp and our code. The capture clock's base differs from now()'s
      // (measured, cap1), so the offset is a running MINIMUM of raw lag — the
      // least-queued frame is the truer base — and every reading is relative
      // to it. On a real camera this is pipeline depth; on the fake one it's
      // delivery jitter around the ideal cadence.
      const rawLag = now() - frame.timestamp / 1000;
      mco = Math.min(mco ?? Infinity, rawLag);
      // ── #75 A RUNNING MIN ASSUMES THE MEDIA CLOCK TRACKS THE WALL ────────────
      // `mco` exists so the peer can map our frame timestamps onto our wall clock:
      // it is the least-queued frame's lag, and `rawLag - mco` is therefore the
      // capture pipeline's depth. That reasoning holds only while the media clock
      // ADVANCES with real time. On the WebKit path it does not — there is no
      // MediaStreamTrackProcessor, so frames come from a <video> element whose
      // clock advances as fast as frames are RENDERED, and under admission
      // throttling that is a fraction of wall time. `rawLag` then grows without
      // bound while a min latched in the first second never moves.
      //
      // Measured on a live Safari<->Brave call, 2026-08-20: the Safari sender's
      // capLagP50 read **42,933 ms** on a call minutes old (and 175,665 ms on an
      // earlier one), while the Chromium sender on the same call read 0.2 ms. Both
      // consumers of `mco` are downstream of that: the peer's `fullAge` came out
      // 18.1 s against a real frame age of 216 ms, and the A-V presenter — which
      // maps frames onto the sender's audio clock through `avd`, also computed from
      // `mco` — applied **-38 s**. The Chromium RECEIVER wore the whole error,
      // which is a large part of why the same code feels broken in Brave and fine
      // in Safari: WebKit is the engine that emits the bad clock, and Chromium is
      // the one that has to believe it.
      //
      // A capture pipeline is a physical depth, tens of milliseconds. Anything past
      // MCO_MAX_LAG is not a deep pipeline, it is a stale anchor — so let the anchor
      // RISE, bounded. The min still takes any lower reading immediately, so a clock
      // that recovers heals at once and one that stalls is wrong by at most the
      // bound instead of by the whole call. On an engine whose clock tracks (every
      // Chromium path measured here: 0.1-0.5 ms) this branch never runs and the
      // behaviour is byte-identical. `?mcomax=0` restores the pure latch.
      if (MCO_MAX_LAG && rawLag - mco > MCO_MAX_LAG) {
        mco = rawLag - MCO_MAX_LAG;
        stats.mcoReanchors = (stats.mcoReanchors | 0) + 1;
      }
      stats.capLagMs.push(+(rawLag - mco).toFixed(1));
      if (stats.capLagMs.length > 900) stats.capLagMs.shift();
      // VIDEO SHED (§13): the peer asked us to drop lane B entirely. No
      // capture is admitted, no pacing token is spent — the wire goes quiet so
      // audio gets the pipe. Lane P keeps presence: one captured frame a
      // second becomes a crisp JPEG on the stills channel.
      // §6.1: a shed from EITHER peer stops admission, because the reference
      // chain is shared — a capture skipped for one is skipped for both. The
      // dead-man switch below stays OUR OWN (`shedded &&`): a half that is not
      // itself shed has `sheddedAt` 0, and firing its dead-man on someone else's
      // shed would resume a peer that never asked. With no link `gShedded()` is
      // `shedded` and `shedded &&` is true inside this branch — unchanged.
      if (gShedded()) {
        // Dead-man switch. Being shed means we have stopped sending video and the
        // ONLY thing that starts us again is a ctl message from the peer. That is
        // a single point of failure with no timeout on it: if the peer decides it
        // is nominal without sending a resume, or reloads, or its classifier is
        // wrong, our video is off permanently and neither side reports an error.
        // A shed is a response to congestion, and congestion is transient by
        // definition, so a shed that has outlived any plausible congestion event
        // is a bug somewhere — resume and let the classifier re-shed if it was
        // real (its 3 s dwell is what stops that from flapping). Belt and braces
        // for the stale-key exit fixed above: that bug is closed, this makes the
        // whole class of it survivable.
        if (shedded && now() - sheddedAt > cfg.stallShedMaxMs) {
          shedded = false;
          sheddedAt = 0;
          stats.shedDeadman++;
          armKey();
          admitRate = cfg.l2PaceStart;
          paceTokens = 1;
          paceLastAt = now();
          lastStillAt = 0;
          L('stall-deadman', { afterMs: Math.round(cfg.stallShedMaxMs) });
          try { worker?.postMessage({ type: 'resume' }); } catch { /* best-effort, as at the resume ctl */ }
        } else {
          stats.framesSkipped++;
          stats.skipShed++;
          maybeStill(frame);
          frame.close();
          continue;
        }
      }
      // ── #75 HELD WAS A ONE-WAY DOOR, AND THIS IS WHY ─────────────────────────
      // `maybeStill` used to live ONLY inside the shed branch above, so lane-P
      // stills stopped the instant our dead-man switch un-shed us — 8 s
      // (stallShedMaxMs) after the peer asked us to stop. The peer's `held` lasts
      // up to 60 s (stallMaxHoldMs) and its ONLY clean way out is `exitProbe`,
      // which needs stills to judge. So for 52 of those 60 seconds the peer was
      // waiting on a probe stream this side had already switched off, and every
      // recovery on a bad link came from the 60 s `maxhold` hatch instead.
      //
      // Measured 2026-08-20, both ends, simulated 440 ms RTT: lpSent froze at 8
      // and never moved again; the receiver's lpAge ring emptied, exitProbe
      // returned early on every tick, and the lane sat held for 52-77% of the
      // call. Two constants that had to agree — one on each side of the link, in
      // different objects — and nothing made them.
      //
      // Now the probe follows the PEER's state: keep sending stills while the peer
      // is held, whether or not our own uplink is still shed. Bounded so a peer
      // that vanishes mid-hold cannot leave this running forever — past its own
      // maxhold the peer has resumed by some other route and no longer needs us.
      // `?lphold=0` is the control arm: stills only while our own uplink is shed,
      // which is the behaviour that made held a one-way door.
      if (cfg.lpHold !== false
          && !gShedded() && peerHeldAt && now() - peerHeldAt < STILL_HOLD_MAX_MS) maybeStill(frame);
      // A cfg-nak renegotiation closes the encoder for a few microtasks; a
      // frame arriving in that window is dropped, not a crash — the keyframe
      // that reopens the stream makes the gap invisible.
      if (!enc) { stats.framesSkipped++; frame.close(); continue; }
      // Admission: the carrier's consumption is the link signal on this lane (SCTP
      // bufferedAmount does not exist here). A capture is only admitted when the
      // carrier has already picked up the previous encoded frame, so every encoded
      // frame is sent and the reference chain never has holes. The encoder queue
      // remains guarded as before.
      const q = enc.encodeQueueSize;
      if (q > stats.encQueuePeak) stats.encQueuePeak = q;
      // Depth 3, not 2: with the camera and the carrier phase-locked at the same rate,
      // depth 2 alternated (admit, skip, admit, skip — B side measured exactly 50%).
      // One extra slot of slack breaks the lock; the worker FIFO still bounds staleness.
      // Paced admission: one token per captured frame, refilled at the AIMD rate
      // the peer's age reports converged on. A skip here never reaches the
      // encoder, so the reference chain has no holes — this is the ramp that
      // replaces the pacer's 1.44 s drop-ceiling queue.
      if (cfg.l2Pace) {
        const tNow = now();
        // §6.1: MIN over the peers' governors. The worst link sets the rate,
        // which is the honest price of one encoder (the alternative charges the
        // sender's CPU instead). One half: this is `admitRate`.
        paceTokens = Math.min(2, paceTokens + ((tNow - paceLastAt) / 1000) * gAdmitRate());
        paceLastAt = tNow;
        if (paceTokens < 1) {
          stats.skipPaced++;
          stats.framesSkipped++;
          frame.close();
          continue;
        }
        paceTokens--;
      }
      // The byte brake (see the block above rcPollBudget). Engages ONLY when
      // the QP controller is pinned at its ceiling and the bucket is in
      // deficit — while QP has room, QP is the actuator. wantKey passes so
      // recovery never queues behind the brake, and the 2 s relief keeps a
      // starved sensor's picture moving rather than frozen.
      if (cfg.l2BytePace && cfg.l2Rc && rcQp >= cfg.l2RcQpMax - 0.5) {
        const tNow = now();
        const refill = bpRefill();
        if (refill != null) {
          if (bpLastAt) bpTokens = Math.min(bpCeil(), bpTokens + ((tNow - bpLastAt) / 1000) * refill);
          bpLastAt = tNow;
          if (bpTokens < 0 && !wantKey && bpLastAdmitAt && tNow - bpLastAdmitAt < 2000) {
            stats.skipBytePaced++;
            stats.framesSkipped++;
            frame.close();
            continue;
          }
          bpLastAdmitAt = tNow;
        }
      } else {
        // Not pinned: keep the refill clock warm so a pin that starts mid-call
        // opens with a current bucket, not a stale one plus a huge time delta.
        bpLastAt = now();
      }
      const maxInFlight = cfg.maxInFlight || 3;
      // §6.1: admit only when EVERY peer's carrier has a slot (max depth) and
      // every peer's decoder is up. A frame encoded for one peer and not the
      // other would be a hole in the shared reference chain.
      const nInFlight = gInFlight();
      if (nInFlight >= maxInFlight || q > cfg.maxEncQueue || !gRemoteReady()) {
        if (gRemoteReady()) { if (nInFlight >= maxInFlight) stats.skipBuffered++; else stats.skipEncQueue++; }
        stats.framesSkipped++;
        frame.close();
        continue;
      }
      // The camera can change size mid-call: the capture ladder steps down a
      // tier when the source-fps probe finds the sensor starving (app.js §
      // "the ladder also MEASURES"). The encoder is configured once at lane
      // start-up, so without this the smaller frames are scaled back UP to the
      // original config — reinstating exactly the upscale encodeSize() removed
      // at join, and forfeiting the 19% of bitrate and ~3.8 ms of p50 it saved
      // (measured, MEASURED.md). The ladder fires in bad conditions, which is
      // precisely when that waste can least be afforded.
      //
      // Held for RESIZE_HOLD consecutive frames so one odd frame cannot start a
      // reconfigure storm, and skipped entirely under ?upscale=1 so the control
      // arm stays a true copy of the old behaviour.
      stats.camW = frame.displayWidth; stats.camH = frame.displayHeight;
      if (!UPSCALE && encConfig) {
        // rcResShrink divides the CAMERA size before it is fitted to the
        // ceiling, so a demotion flows through the exact resize machinery a
        // camera change would use — RESIZE_HOLD debounce, reconfigure,
        // self-describing keyframe — rather than through a second path.
        const rDiv = rcResShrink / linkScale;
        const want = fitSize(frame.displayWidth / rDiv, frame.displayHeight / rDiv, cfg);
        if (want.width !== encConfig.width || want.height !== encConfig.height) {
          if (++resizeHold >= RESIZE_HOLD) {
            resizeHold = 0;
            const from = `${encConfig.width}x${encConfig.height}`;
            encConfig = { ...encConfig, width: want.width, height: want.height };
            stats.encW = want.width; stats.encH = want.height;
            try {
              // configure() on a live encoder applies to subsequent frames and
              // resets the reference chain, so the next frame must be a key
              // frame. annexb carries SPS/PPS inline, so that keyframe is
              // self-describing: the receiver needs no new `cfg` message (one
              // would rebuild its decoder for nothing) and its canvas already
              // tracks frame.displayWidth.
              enc.configure(encConfig);
              wantKey = true;
              stats.reconfigs++;
              L('tape-resize', { lane: 'rtp', from, to: `${want.width}x${want.height}` });
            } catch (e) {
              // A rejected reconfigure must not kill the lane: keep encoding at
              // the old size, which is what we were doing anyway.
              stats.reconfigFails++;
              L('tape-resize', { lane: 'rtp', from, err: String(e).slice(0, 80) });
            }
          }
        } else if (resizeHold) {
          resizeHold = 0;
        }
      }
      {
        // Forward the frame's orientation so the peer can paint it upright.
        // The ctl channel is open here (remoteReady gated above). Rotation only
        // moves on a device flip/rotate, so this sends once per change.
        const rot = (((frame.rotation ?? 0) | 0) % 360 + 360) % 360;
        if (rot !== sentRot) {
          sentRot = rot;
          // Same reasoning as the `cfg` above: one camera, one orientation,
          // every peer — and replayed to a half that arms later.
          descSend({ t: 'rot', rot });
          L('tape-rot', { lane: 'rtp', dir: 'send', rot });
        }
        if (rot === 0 && !rotWarned) {
          // The one case the metadata cannot cover: frames landscape, camera
          // portrait, no rotation attribute (engine too old). Log it — guessing
          // 90 vs 270 blind would flip half of phones upside down.
          const s = curTrack?.getSettings?.() ?? {};
          if (s.width && s.height && (s.width < s.height) !== (frame.displayWidth < frame.displayHeight)) {
            rotWarned = true;
            L('tape-rot-mismatch', { settings: `${s.width}x${s.height}`, frame: `${frame.displayWidth}x${frame.displayHeight}`, rotAttr: frame.rotation ?? null });
          }
        }
      }
      const t = now();
      const key = wantKey || t - lastKeyAt > cfg.keyMs;
      if (key) { wantKey = false; lastKeyAt = t; }
      // ── presence filter ─────────────────────────────────────────────────────
      // Runs on the frame the encoder is about to see, never on what we store
      // or show locally. `filtered` is ours to close; a null means the filter
      // declined (unsupported, resized, threw) and the camera frame goes in
      // unchanged — the pre-filter path can lose, but the picture cannot.
      if (pfWanted && !pFilterArmed) {
        pFilterArmed = true;
        import('./presence-filter.js')
          .then((m) => {
            pFilter = m.createPresenceFilter(pfParams);
            L('presence-filter', { on: 1, ...pFilter.params() });
          })
          .catch((e) => L('presence-filter', { on: 0, err: String(e).slice(0, 80) }));
      }
      if (!pfWanted && pFilter) { // toggled off mid-call: drop the GPU context
        try { pFilter.close(); } catch { /* teardown is never load-bearing */ }
        pFilter = null; pFilterArmed = false;
        stats.pfStillMean = null; // a stale lock reading would outlive the lock
      }
      const filtered = pFilter ? pFilter.process(frame) : null;
      if (pFilter) {
        stats.pfMs = pFilter.stats.lastMs;
        stats.pfFallbacks = pFilter.stats.fallbacks;
        stats.pfFrames = pFilter.stats.framesOut;
        stats.pfStillMean = pFilter.stats.stillMean;
        // The threshold the lock is actually using, not the one it was built
        // with. It adapts UPWARD toward this sensor's grain floor and saturates
        // at 0.02 — and if it saturates while stillMean stays near zero, the
        // lock never engaged and the whole saving quietly evaporated on exactly
        // the noisy devices that need it most. That is a silent failure unless
        // the number is on the wire, so it is on the wire.
        stats.pfHoldThresh = pFilter.stats.holdThresh;
      }
      try {
        encCallAt.push(t); // drained FIFO-order by onEncoded (#14 encode-latency probe)
        if (encCallAt.length > 64) encCallAt.splice(0, encCallAt.length - 64);
        // #44: the quantizer is now a control output, not a constant. With
        // ?l2rc=0 this is cfg.qp on every frame and the wire is byte-identical.
        const qpNow = rcQpNow();
        // On the VBR arm the per-frame quantizer is silently IGNORED rather than
        // rejected (measured: WebKit accepts the option and does nothing with it), so
        // passing it would leave the rate controller looking like it was in charge while
        // having no effect at all. Omit it and let the encoder's own control loop run.
        enc.encode(filtered ?? frame, rateControl === 'vbr'
          ? { keyFrame: key }
          : { keyFrame: key, avc: { quantizer: qpNow }, vp9: { quantizer: qpNow }, av1: { quantizer: qpNow } });
      } catch (e) { fail('encode', e); filtered?.close(); frame.close(); return; }
      // Both are closed on every path: a VideoFrame holds a GPU buffer, and the
      // filter doubles how many are in flight.
      filtered?.close();
      frame.close();
    }
    // Reader ended. If nothing replaced the track it is genuinely gone and the
    // lane is over; if adoptTrack() swapped it, re-attach to the new sensor.
    if (!swapped) return;
    wantKey = true; // new sensor, new reference chain
    stats.trackSwaps++;
    L('tape-track-swap', { lane: 'rtp', to: `${curTrack.label || 'camera'}`.slice(0, 40) });
   }
  }

  /**
   * Point the capture pump at a different camera (§8 flip, and the stall
   * machine's re-acquire). Cancelling the reader is what wakes the pump: its
   * read() resolves done, it sees curTrack has moved, and it re-attaches.
   * Safe to call when the pump has already exited — it is restarted here.
   */
  function adoptTrack(nv) {
    if (!nv || closed || nv === curTrack) return;
    const wasLive = curTrack && curTrack.readyState === 'live';
    curTrack = nv;
    try { procReader?.cancel(); } catch { /* already ended: the restart below covers it */ }
    // If the old track had already ended, the pump has returned and nothing is
    // left to wake — start a fresh one.
    if (!wasLive) pumpCapture().catch((e) => fail('capture-readopt', e));
  }

  /**
   * The ENCODE half (§6.1): capture -> admission -> encode. Extracted from
   * `arm()` unchanged so that exactly one instance can own it under a link, and
   * so the link can hand it to a surviving half when the owner's pair leaves.
   * With no link `arm()` calls it directly and these are the two statements that
   * stood there.
   */
  function startEncodeHalf() {
    setupEncoder().then(() => pumpCapture().catch((e) => fail('capture', e)))
      .catch((e) => fail('encoder-setup', e));
  }

  if (!pre?.worker) { fail('rtp-lane-setup', new Error('no prepared sender transform')); return null; }
  worker = pre.worker;
  worker.onmessage = (e) => { try { onWorkerMsg(e.data); } catch { /* ignore */ } };
  // Arm the worker's send-side FEC (group of l2FecGroup carrier frames, one XOR
  // parity frame per group; keyframes duplicated when l2FecKey >= 1).
  try { worker.postMessage({ type: 'fec', group: cfg.l2FecGroup, keyGroup: cfg.l2FecKey }); }
  catch { /* FEC is an enhancement; the lane still works without it */ }

  // One ctl channel per call, created by the initiator, adopted by the answerer —
  // two channels with one listener each is how half the control messages vanish.
  let armed = false;
  const arm = (adopted) => {
    if (armed) return;
    armed = true;
    armedAt = now();
    L('tape-ctl-open', { lane: 'rtp', adopted });
    // §12–13: the regime classifier runs receiver-side at 2 Hz on per-frame
    // data — fresher than any ctl report could be (law 16). `?stallforce=N`
    // is the test hook: force one shed N seconds after arm so the transition
    // mechanics (shed → held → lane P → resume → keyframe cut) are exercisable
    // on a healthy path; the classifier's own trigger is exercised by the
    // bandwidth-ceiling runs.
    if (cfg.stall) {
      stallTimer = tickInterval(() => {
        if (closed) return;
        try {
          if (cfg.stallForceAt && !stallForced && stallRegime === 'nominal' && now() - armedAt >= cfg.stallForceAt * 1000) {
            stallForced = true;
            enterHeld('forced');
          }
          classify();
        } catch (e) { L('stall-err', { e: String(e).slice(0, 120) }); }
      }, 500);
    }
    // §6.1: a half joins the shared encoder when its TRANSPORT is live, not when
    // it is constructed — joining at construction would make an armed peer wait
    // on an unarmed one's `remoteReady` and stall a running call. The first half
    // to arm owns the encode chain; later halves are transport-only and get the
    // encoder's `cfg`/`rot` replayed, because the encoder described itself
    // before their ctl channel existed.
    if (link) {
      link.join(half);
      link.replayDesc(half);
      if (link.claimEncoder(half)) startEncodeHalf();
      else L('tape-link-transport-half', { halves: link.size() });
    } else {
      startEncodeHalf();
    }
    pinger = tickInterval(() => ctlSend({ t: 'ping', a: now() }), 2000);
    ctlSend({ t: 'ping', a: now() });
    try { avsync?.onCtlOpen?.(); } catch { /* TIME_SYNC must never break the lane */ }
  };

  if (initiator) {
    const dc = pc.createDataChannel('tape-ctl-rtp', { ordered: true });
    dcCtl = dc;
    dc.onmessage = (e) => { try { onCtl(e.data); } catch { /* ignore */ } };
    dc.onopen = () => arm(false);
    // §13 lane P: created HERE, before any offer — a channel created later
    // would need a renegotiation, and lane 2 never renegotiates. Reliable and
    // ordered (§11): latency-insensitive, and it must never turn into a
    // datagram lane to chase a still that is one second fresher.
    if (cfg.stall) {
      dcLaneP = pc.createDataChannel('tape-lanep', { ordered: true });
      dcLaneP.binaryType = 'arraybuffer';
      dcLaneP.onmessage = (e) => { try { onLaneP(e.data); } catch { /* one bad still is not an event */ } };
      dcLaneP.onopen = () => L('tape-lanep-open', {});
      dcLaneP.onerror = (e) => L('tape-lanep-error', { e: String(e?.error || e).slice(0, 120) });
    }
  }

  return {
    stats,
    // THE WATCHDOG'S GATE. "No frames yet" is only evidence of a broken lane
    // once both ends actually HAVE a lane to produce frames with: our ctl
    // channel open (so we could hear the peer) and the peer's 'ready' received
    // (so it has an encoder). Before that, zero frames is evidence of a
    // handshake still in flight -- and on a long path the handshake is seconds.
    //
    // Measured on a real Delhi <-> Netherlands call (room ilx-swig-xox,
    // 2026-08-14, Safari <-> Brave, RTT 394 ms): ICE + DTLS + SCTP + channel
    // open took 3.6 s on the Brave side and 3.8 s on the Safari side, because
    // that sequence is ~9 round trips and every one of them costs 394 ms.
    // app.js armed a flat 4000 ms watchdog at pc.ontrack -- which in Chromium
    // fires when the REMOTE DESCRIPTION is set, not when media flows -- so the
    // whole budget was spent on the handshake and the lane was killed 390 ms
    // after its own encoder configured. See armLaneWatchdog in app.js.
    laneReady: () => !!(dcCtl && dcCtl.readyState === 'open' && gRemoteReady()),
    // §8: the camera changed under us (flip, or the stall machine's
    // re-acquire). Without this the pump dies with the old track.
    adoptTrack,
    // ctl access for the §10 bundle (TIME_SYNC rides this channel — no new
    // channels, the no-renegotiation law). Null-safe before arm.
    sendCtl: (o) => ctlSend(o),
    // §3.1 levers 3+4 (Lane 0): hold Lane B's bytes off the wire for `ms` so
    // a voice onset's first PCM frames (why 'onset', ~40 ms) or a predicted
    // reply's (why 'pred', ~400 ms) meet an empty pipe. The browser cannot
    // preempt bytes already in the socket, so the honest implementation is
    // this gate: the worker passes carrier ticks through untouched for the
    // window. Hard caps make a caller bug a bounded stall, not a dead lane;
    // every window is counted in stats. Returns the clamped duration, 0 if
    // nothing was armed.
    yieldLaneB(ms, why = 'onset') {
      const cap = why === 'pred' ? 600 : 60;
      const d = Math.max(0, Math.min(cap, ms | 0));
      if (!d || !worker) return 0;
      if (why === 'pred') { stats.l0PreStalls++; stats.l0PreStallMs += d; }
      else { stats.l0Yields++; stats.l0YieldMs += d; }
      try { worker.postMessage({ type: 'yield', ms: d }); } catch { return 0; }
      return d;
    },
    // MUST be called synchronously inside ontrack — measured: a few microtasks later
    // and Chrome routes every frame around the transform (rtplane.mjs). Exception:
    // the OFFERER's slot receiver is pre-attached at transceiver creation (app.js
    // 'tape.slot'), because the answer builds that pipeline at SRD(answer), before
    // ontrack fires (measured, claim6: hooked yet bypassed, 0 recv ticks). If a
    // transform is already on the receiver, attaching another post-build would be
    // routed around just the same — leave the working one in place.
    attachReceiver(receiver) {
      if (receiver.transform) return;
      // ASK THE JITTER BUFFER FOR NOTHING. ?jbt=N overrides; 0 is the default.
      //
      // The receive transform fires only once a frame is COMPLETE, so anything
      // WebRTC's video jitter buffer holds is inside the measured 9.0 ms between
      // the send transform and the receive transform -- 9 ms on a rig where the
      // two browsers are on one machine and the audio lane's RTT is 0.24 ms, so
      // essentially none of it is the wire.
      //
      // We do not need that buffer: this lane runs its own reordering, its own
      // FEC and its own presenter, and it anchors on capture timestamps carried
      // inside the payload rather than on RTP arrival. Smoothing the same
      // stream twice only costs latency.
      const jbt = Number(cfg.l2JitterTargetMs);
      if (Number.isFinite(jbt) && jbt >= 0 && jbt <= 500) {
        try { receiver.jitterBufferTarget = jbt; }
        catch { /* pre-114 Chrome and non-Chromium: the buffer keeps its own mind */ }
      }
      try { receiver.transform = new RTCRtpScriptTransform(worker, { role: 'recv' }); }
      catch (e) { fail('attach-receiver', e); }
    },
    // #14 probe: watch the <video> actually presenting our decoded frames and
    // measure decode-output → presentation, the TrackGenerator + element +
    // compositor tax that no counter sees. Each presented frame drains one
    // decode-output timestamp FIFO-style; if the element drops a frame the
    // alignment slips by one and the median absorbs it.
    observeDisplay(videoEl) {
      if (!videoEl?.requestVideoFrameCallback) return;
      const onFrame = () => {
        if (closed) return;
        // NOTE: rVFC's timestamp argument is on a different base than now()
        // (measured, cap1: raw subtraction read −1.785e12 ms) — stamp inside.
        const t = now();
        const d = decOutAt.shift();
        if (d != null) {
          stats.presentLagMs.push(+(t - d).toFixed(1));
          if (stats.presentLagMs.length > 900) stats.presentLagMs.shift();
        }
        videoEl.requestVideoFrameCallback(onFrame);
      };
      try { videoEl.requestVideoFrameCallback(onFrame); } catch { /* probe only */ }
    },
    // The answering side receives the ctl channel instead of creating it.
    adoptCtl(channel) {
      dcCtl = channel;
      channel.onmessage = (e) => { try { onCtl(e.data); } catch { /* ignore */ } };
      if (channel.readyState === 'open') arm(true); else channel.onopen = () => arm(true);
    },
    // §13 lane P: the answering side adopts the initiator's stills channel.
    adoptLaneP(channel) {
      dcLaneP = channel;
      channel.binaryType = 'arraybuffer';
      channel.onmessage = (e) => { try { onLaneP(e.data); } catch { /* one bad still is not an event */ } };
      channel.onerror = (e) => L('tape-lanep-error', { e: String(e?.error || e).slice(0, 120) });
      if (channel.readyState === 'open') L('tape-lanep-open', { adopted: true });
      else channel.onopen = () => L('tape-lanep-open', { adopted: true });
    },
    // Local shed — identical execution to a peer's LANE_SHED. Exists for the
    // app's HOLD state and for tests; the video classifier's shed is always
    // the peer-driven one (rule 1).
    shedNow(why = 'local') {
      if (!cfg.stall || shedded) return false;
      shedded = true;
      L('stall-shed', { dir: 'uplink', why });
      try { worker?.postMessage({ type: 'shed' }); } catch { /* admission is stopped; purge best-effort */ }
      return true;
    },
    snapshot() {
      const a = stats.ageMs, b = stats.qpBytes;
      const pct = (arr, p) => {
        if (!arr.length) return null;
        const s = [...arr].sort((x, y) => x - y);
        return +s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))].toFixed(1);
      };
      const mean = (arr) => (arr.length ? +(arr.reduce((x, y) => x + y, 0) / arr.length).toFixed(1) : null);
      return {
        ...stats, lane: 'rtp',
        // THE DELIVERY COLUMN. Everything else here is a counter that reads healthy while
        // the picture is capped: the carrier ticks at a rate fixed when captureStream() was
        // called, ONE TICK CARRIES ONE FRAME, and until this field existed there was no way
        // to tell an ask of 72 fps that worked from one that changed nothing.
        achievedFps: encMeter.fps(),
        askedFps: cfg.fps,
        carrierTicksAsked: pre?.carrierTicksAsked ?? null,
        ageMs: undefined, qpBytes: undefined, lpAgeMs: undefined,
        capLagMs: undefined, encLatMs: undefined, fullAgeMs: undefined, presentLagMs: undefined,
        presentAt: undefined,
        ageP50: pct(a, 50), ageP95: pct(a, 95),
        capLagP50: pct(stats.capLagMs, 50), capLagP95: pct(stats.capLagMs, 95),
        encLatP50: pct(stats.encLatMs, 50), encLatP95: pct(stats.encLatMs, 95),
        fullAgeP50: pct(stats.fullAgeMs, 50), fullAgeP95: pct(stats.fullAgeMs, 95),
        // Splits `age` into the part spent waiting for a carrier tick and the
        // part actually on the wire. Without this the transport term is one
        // opaque 18.9 ms and every attempt to shrink it is a guess.
        qWaitAvgMs: stats.qWaitAvgMs ?? null, qWaitMaxMs: stats.qWaitMaxMs ?? null,
        xferAvgMs: stats.xferAvgMs ?? null, tickAvgMs: stats.tickAvgMs ?? null,
        tickPct: stats.tickPct ?? null,
        recvPct: stats.recvPct ?? null,
        presentLagP50: pct(stats.presentLagMs, 50), presentLagP95: pct(stats.presentLagMs, 95),
        // Glass-to-glass, the vision twin of the audio lane's mouthToEarMs:
        // peer camera capture → this display presents, one number for the
        // latency campaign. fullAge already spans capture→decode on the
        // sender's own clock (offset-corrected), so + present lag completes
        // the pipe. Null until both probe streams have data.
        glassToGlassMs: (() => {
          const f = pct(stats.fullAgeMs, 50);
          const pl = pct(stats.presentLagMs, 50);
          return f != null && pl != null ? +(f + pl).toFixed(1) : null;
        })(),
        // #33: inter-present-interval distribution, from the presentAt stream
        // (every present site feeds it: v-presenter, avTick, paint-on-arrival,
        // lane-P stills). The cadence gate's number.
        ...(() => {
          const d = [];
          for (let i = 1; i < stats.presentAt.length; i++) d.push(+(stats.presentAt[i] - stats.presentAt[i - 1]).toFixed(1));
          return { ipiP50: pct(d, 50), ipiP95: pct(d, 95), ipiP99: pct(d, 99) };
        })(),
        // #33 v-presenter counters (all zero on the ?vprev=0 control arm).
        // `fps` is the PEER's measured capture rate and `dMs` the anchor cost in
        // its units -- both were previously quoted in ours, so a 25 fps peer
        // was reported as a 30 fps grid and the mismatch was unreadable.
        vp: { ...vpStats, depth: vpq.length, shift: vpShift,
              fps: vpIus != null ? +(1e6 / vpIus).toFixed(1) : null,
              dMs: +(VP_D_SLOTS * (vpI() / 1000)).toFixed(1) },
        frameBytesMean: mean(b), frameBytesP95: pct(b, 95),
        mbpsAtFps: mean(b) != null ? +((mean(b) * 8 * cfg.fps) / 1e6).toFixed(2) : null,
        buffered: null, decQueue: dec?.decodeQueueSize ?? null, encQueue: enc?.encodeQueueSize ?? null,
        pending: hold.size,
        // §6.1 shared encoder. Null on every 1:1 call and on the ?l23enc=2
        // control arm, so a snapshot from today's path is the same object it
        // was. `encoder` says which half owns the one encode chain; `admitFps`
        // beside it is this PEER's governor, and `admitShared` what the shared
        // admission actually used — the pair the rig needs to see the min rule.
        l23: link
          ? { halves: link.size(), encoder: link.isOwner(half) ? 1 : 0,
              admitShared: +gAdmitRate().toFixed(2), inFlightShared: gInFlight(),
              budgetShared: gBudgetMbps() }
          : null,
        // §10 A-V sync telemetry (null/absent when the bundle never engaged —
        // the paint-on-arrival path is then exactly §17.8's).
        avEngaged,
        // Visible in every snapshot, because "sync gave up" is the difference
        // between a lane that is fine and a lane that is fine BECAUSE it stopped
        // trying to be clever. A rig cannot see that from g2g alone.
        avGaveUp,
        avPresents: avStats.presents, avHolds: avStats.holds,
        avDrops: avStats.drops, avSkips: avStats.skips,
        avOffP50: pct(avStats.offMs, 50), avOffP95: pct(avStats.offMs, 95),
        avqDepth: avq.length,
        peerAvDeltaUs: peerAvDeltaUs != null ? Math.round(peerAvDeltaUs) : null,
        // How wrong the mapping was, and how often it was refused. Without
        // these a rig sees "sync never engaged" and cannot tell a healthy call
        // that had no need of it from one whose peer clock is nonsense.
        avMapErrMs: avMapErrUs != null ? Math.round(avMapErrUs / 1000) : null,
        avMapRejects,
        // Counted since #14 and never reported until now: every rig run read
        // `reanch undefined` while this was the direct diagnostic for the
        // ratcheting anchor that poisons `avd` in the first place.
        mcoReanchors: stats.mcoReanchors | 0,
        // §12–13 stall machine (null with ?stall=0 — the classifier never ran,
        // no lane-P channel exists, and no shed/resume byte was ever sent).
        stall: cfg.stall
          ? {
              regime: stallRegime, shedded,
              // #75 the two facts that used to be one. `shedded` is our uplink;
              // `peerHeldMs` is how long the PEER has been waiting for the probe
              // stream that keeps it alive. A held peer with no still flowing is
              // the exact state that made `held` a one-way door.
              peerHeldMs: peerHeldAt ? Math.round(now() - peerHeldAt) : 0,
              lpAgeP50: pct(stats.lpAgeMs, 50),
              lpW: stats.lpW ?? null,
              pathFloorMs: +pathFloorMs().toFixed(1),
              transitions: [...stallLog],
            }
          : null,
      };
    },
    /**
     * Turn the presence filter on/off mid-call. The knob exists so the filter
     * can be compared against ITSELF seconds apart on one call, one network,
     * one position in the scene — the only way this comparison is worth
     * anything (see pfWanted above). Takes effect on the next captured frame.
     */
    setPresenceFilter(on, params) {
      pfWanted = !!on;
      if (params) { pfParams = { ...pfParams, ...params }; pFilter?.setParams(pfParams); }
      return pfWanted;
    },
    stop() {
      closed = true;
      // Leave the shared encoder first: if this half owned the encode chain the
      // link hands it to a survivor, so the room's other leg keeps its picture.
      try { if (link) link.leave(half); } catch { /* teardown is never load-bearing */ }
      try { pFilter?.close(); pFilter = null; } catch { /* teardown is never load-bearing */ }
      pinger?.clear?.();
      ageReporter?.clear?.();
      rcTimer?.clear?.(); // #44 — a live getStats poll on a closed pc throws every second
      stallTimer?.clear?.();
      clearTimeout(holdTimer);
      for (const q of avq.splice(0)) { try { q.frame.close(); } catch { /* already closed */ } }
      for (const q of vpq.splice(0)) { try { q.frame.close(); } catch { /* already closed */ } }
      try { worker?.postMessage({ type: 'bypass' }); } catch { /* ignore */ }
      try { procReader?.cancel(); } catch { /* ignore */ }
      for (const c of [enc, dec]) { try { c?.state !== 'closed' && c?.close(); } catch { /* ignore */ } }
      try { writer?.close(); } catch { /* ignore */ }
      for (const d of [dcCtl, dcLaneP]) { try { d?.close(); } catch { /* ignore */ } }
    },
  };
}
