/**
 * Telemetry that cannot break the call.
 *
 * This runs during a real conversation between two people that happens once. So the
 * governing rule is not "collect everything" — it is **never be the reason the call
 * degraded, and never lose the data.** Those pull in opposite directions, and every
 * decision below resolves in favour of the conversation.
 *
 * ── Never break the call ─────────────────────────────────────────────────────
 * Every public function is wrapped. `log()` cannot throw, cannot await, and cannot
 * block. Flushes are fire-and-forget. If the network is gone, events accumulate in a
 * bounded buffer and get dropped oldest-first rather than growing without limit — a
 * telemetry system that OOMs the tab has failed at its only job.
 *
 * ── Never lose the data ──────────────────────────────────────────────────────
 * Three independent paths, because the call happens once:
 *   1. Batched POST every 5 s to the Durable Object (primary)
 *   2. `sendBeacon` on pagehide — closing the tab otherwise loses the tail, which
 *      is where the end of the conversation is
 *   3. An in-memory mirror behind tel.download(), because the cheapest recovery
 *      path during a debugging session is a file. Nothing is ever persisted on
 *      the participant's device (a localStorage mirror lived here during the
 *      measurement campaign and was removed 2026-08-04, user directive).
 *
 * ── What is never recorded ───────────────────────────────────────────────────
 * No audio. No video. No frames. No transcript. No text the participants typed or
 * said. Only event timings and WebRTC counters. The onset detector reports *that* a
 * breath happened and when — never what was said. This is a hard boundary, not a
 * default: `log()` takes numbers and short enums, and the server sanitizes again on
 * ingest.
 */

const FLUSH_MS = 5000;
const MAX_BUFFER = 6000; // ~10 min of dense telemetry; beyond this, drop oldest
// Must not exceed the worker's MAX_EVENTS_PER_BATCH. The server silently truncates a larger
// batch and still answers 200, so sending more than this loses the overflow while looking like
// a clean send. A normal 5 s flush is a couple of hundred events; this only binds after the
// buffer has grown from earlier failures, which is precisely when the log is worth having.
const MAX_BATCH = 2000;
const MAX_MIRROR = 4000; // in-memory cap for tel.download()

export class Telemetry {
  constructor({ room, role, session }) {
    this.room = room;
    this.role = role;
    this.session = session;
    this.buffer = [];
    this.mirror = [];
    this.t0 = performance.now();
    this.sent = 0;
    this.dropped = 0;
    this.truncated = 0; // events the server refused to take but did not report as an error
    this.failures = 0;
    this.lastError = null;
    this.enabled = true;

    // A flush in flight must not overlap with the next one, or events can be
    // stored twice — a duplicate turn event would corrupt a median.
    this.flushing = false;

    this.timer = setInterval(() => this.flush(), FLUSH_MS);

    // The tail matters most: it's the end of the conversation, and it's exactly
    // what a normal unload loses. `pagehide` is the reliable one on Safari/iOS;
    // `visibilitychange` catches backgrounding on Android.
    this.onHide = () => this.flushSync();
    addEventListener('pagehide', this.onHide);
    addEventListener('beforeunload', this.onHide);
    addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') this.flushSync();
    });
  }

  /**
   * Record an event. Never throws, never blocks, never awaits.
   * `data` must be numbers, booleans, or short strings — see the header.
   */
  log(kind, data = {}) {
    if (!this.enabled) return;
    try {
      const ev = {
        kind,
        t: +(performance.now() - this.t0).toFixed(3),
        wall: Date.now(),
        data,
      };
      this.buffer.push(ev);
      this.mirror.push(ev);
      if (this.buffer.length > MAX_BUFFER) {
        this.buffer.splice(0, this.buffer.length - MAX_BUFFER);
        this.dropped++;
      }
      if (this.mirror.length > MAX_MIRROR) this.mirror.splice(0, this.mirror.length - MAX_MIRROR);
    } catch {
      /* telemetry must never surface an error into the call path */
    }
  }

  async flush() {
    if (!this.enabled || this.flushing || !this.buffer.length) return;
    this.flushing = true;
    // Take the batch out before the request, so `log()` during the flight lands in
    // the next batch rather than being lost or duplicated.
    const batch = this.buffer.slice(0, MAX_BATCH);
    this.buffer = this.buffer.slice(MAX_BATCH);
    try {
      const res = await fetch(`/api/room/${encodeURIComponent(this.room)}/log`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ session: this.session, role: this.role, events: batch }),
        keepalive: false,
      });
      if (!res.ok) {
        // Read the body before throwing. `HTTP 503` on its own is unactionable — it does
        // not say whether the worker refused us, the Durable Object was unreachable, or the
        // local runtime shed the request, and those have completely different fixes. This
        // is the only place that information exists.
        const why = await res.text().catch(() => '');
        throw new Error(`HTTP ${res.status}${why ? ` — ${why.slice(0, 80).replace(/\s+/g, ' ')}` : ''}`);
      }
      const body = await res.json().catch(() => ({}));
      const stored = body.stored ?? batch.length;
      this.sent += stored;
      // If the server took fewer than we offered, the remainder is not sent and must go back.
      // Believing `stored` without checking it against what we handed over is how a log ends
      // up short in exactly the way that cannot be noticed afterwards.
      if (body.offered != null && stored < body.offered) {
        this.buffer = batch.slice(stored).concat(this.buffer);
        this.truncated += body.offered - stored;
      }
      this.failures = 0;
    } catch (e) {
      // Put it back at the front — order is preserved and nothing is lost unless
      // the buffer overflows, which is itself recorded.
      this.buffer = batch.concat(this.buffer);
      if (this.buffer.length > MAX_BUFFER) {
        this.buffer.splice(0, this.buffer.length - MAX_BUFFER);
        this.dropped++;
      }
      this.failures++;
      this.lastError = String(e.message ?? e).slice(0, 120);
    } finally {
      this.flushing = false;
    }
  }

  /**
   * Synchronous-ish flush for page teardown. `sendBeacon` is the only thing the
   * browser guarantees will still be delivered after the page is gone.
   */
  flushSync() {
    try {
      if (!this.buffer.length) return;
      const body = JSON.stringify({
        session: this.session,
        role: this.role,
        events: this.buffer,
      });
      const ok = navigator.sendBeacon?.(
        `/api/room/${encodeURIComponent(this.room)}/log`,
        new Blob([body], { type: 'application/json' }),
      );
      if (ok) this.buffer = [];
    } catch {
      /* nothing useful to do at teardown */
    }
  }

  /** Everything held locally, as NDJSON — the cheapest recovery path. */
  toNdjson() {
    return (
      this.mirror
        .map((e) =>
          JSON.stringify({ session: this.session, role: this.role, t: e.t, wall: e.wall, kind: e.kind, data: e.data }),
        )
        .join('\n') + '\n'
    );
  }

  download() {
    try {
      const url = URL.createObjectURL(new Blob([this.toNdjson()], { type: 'application/x-ndjson' }));
      const a = document.createElement('a');
      a.href = url;
      a.download = `tape-${this.room}-${this.role}-${new Date().toISOString().slice(0, 19).replace(/:/g, '')}.ndjson`;
      a.click();
      URL.revokeObjectURL(url);
    } catch {
      /* ignore */
    }
  }

  get health() {
    return {
      buffered: this.buffer.length,
      sent: this.sent,
      dropped: this.dropped,
      truncated: this.truncated,
      failures: this.failures,
      lastError: this.lastError,
      mirrored: this.mirror.length,
    };
  }

  stop() {
    clearInterval(this.timer);
    removeEventListener('pagehide', this.onHide);
    removeEventListener('beforeunload', this.onHide);
    this.flushSync();
  }
}

/**
 * WebRTC stats sampling.
 *
 * Deliberately narrow: these specific fields are the ones that let a turn-taking
 * number be trusted afterwards. `jitterBufferDelay / jitterBufferEmittedCount` gives
 * the *actual* playout delay, which is the difference between "the human was slow"
 * and "the receiver was holding audio" — and without it a gap measurement can't tell
 * those apart, which would make the whole exercise unfalsifiable.
 */
export async function sampleStats(pc) {
  const out = { audio: {}, video: {}, pair: {} };
  if (!pc) return out;
  try {
    const stats = await pc.getStats();
    stats.forEach((r) => {
      if (r.type === 'inbound-rtp' && r.kind === 'audio') {
        out.audio = {
          jitter: num(r.jitter, 5),
          packetsLost: r.packetsLost,
          packetsReceived: r.packetsReceived,
          // The number that separates human latency from receiver buffering.
          playoutMs: r.jitterBufferEmittedCount
            ? num((r.jitterBufferDelay / r.jitterBufferEmittedCount) * 1000, 2)
            : null,
          concealed: r.concealedSamples,
          concealmentEvents: r.concealmentEvents,
          removedForOverrun: r.removedSamplesForAcceleration,
          insertedForUnderrun: r.insertedSamplesForDeceleration,
          audioLevel: num(r.audioLevel, 4),
          totalAudioEnergy: num(r.totalAudioEnergy, 4),
        };
      }
      if (r.type === 'inbound-rtp' && r.kind === 'video') {
        out.video = {
          w: r.frameWidth,
          h: r.frameHeight,
          fps: num(r.framesPerSecond, 1),
          framesDecoded: r.framesDecoded,
          framesDropped: r.framesDropped,
          // Tell #4 in §1: this is Zoom's "green smears" made countable.
          freezeCount: r.freezeCount,
          freezeMs: num(r.totalFreezesDuration * 1000, 0),
          pauseCount: r.pauseCount,
          keyFramesDecoded: r.keyFramesDecoded,
          pliCount: r.pliCount,
          nackCount: r.nackCount,
          jitter: num(r.jitter, 5),
          packetsLost: r.packetsLost,
          bytesReceived: r.bytesReceived,
          playoutMs: r.jitterBufferEmittedCount
            ? num((r.jitterBufferDelay / r.jitterBufferEmittedCount) * 1000, 2)
            : null,
          // ── Is forward error correction doing anything? ──────────────────────
          // Loss recovery by retransmission needs a round trip, so at 80 ms RTT a replacement
          // packet often arrives after the frame was due and the picture freezes instead —
          // measured at 3-6 freezes per 75 s under 1% loss. FEC is the alternative: send
          // redundancy so a lost packet can be reconstructed without asking. Chrome decides
          // for itself whether to use it, and nothing here could see that decision, so
          // "should we enable FEC" was unanswerable — including the possibility that it is
          // already on and simply not enough.
          //
          // `fecPacketsDiscarded` matters as much as `received`: redundancy that arrives too
          // late to use is pure cost, spending bitrate that would otherwise be picture.
          fecReceived: r.fecPacketsReceived ?? null,
          fecDiscarded: r.fecPacketsDiscarded ?? null,
          // What retransmission actually recovered, for comparison against FEC.
          retransReceived: r.retransmittedPacketsReceived ?? null,
        };
      }
      // ── What OUR encoder is actually doing ──────────────────────────────────
      // Only inbound was sampled before, which shows what arrived but never why. The design
      // promises constant quality, and `qualityLimitationReason` is the encoder's own
      // statement about it: 'none' means it hit the bitrate we asked for, while 'bandwidth' or
      // 'cpu' means something else won and the picture is worse than requested. Without it a
      // call can look fine in the HUD — right resolution, right frame rate — while every frame
      // is being quantised harder than we asked, which is invisible by eye until you compare
      // against a recording.
      //
      // It is necessary and *not* sufficient, which is worth stating here because the field
      // reads like a verdict. Behind a 3 Mbps ceiling this reported 'none' for 100% of a run
      // whose frame rate had fallen from 30 to 17, with `bandwidth` at 0.00 s — truthfully,
      // because `maintain-resolution` spends frame rate before it spends quality, so the
      // encoder got exactly what it asked for (DESIGN.md §17.5). Read it together with `fps`
      // here and `source.fps` below; neither one alone can tell a healthy call from a starved
      // one.
      if (r.type === 'outbound-rtp' && r.kind === 'video') {
        out.send = {
          bytesSent: r.bytesSent,
          // What the encoder was aiming at, vs the cap we set. A gap is the rate controller
          // overriding us.
          targetBitrate: r.targetBitrate,
          qualityLimitationReason: r.qualityLimitationReason,
          // Cumulative seconds spent in each limitation state — a call that spent 40% of its
          // life bandwidth-limited says so here even if it recovered by the time you looked.
          qualityLimitationDurations: r.qualityLimitationDurations
            ? Object.fromEntries(
                Object.entries(r.qualityLimitationDurations).map(([k, v]) => [k, num(v, 2)]),
              )
            : null,
          w: r.frameWidth,
          h: r.frameHeight,
          fps: num(r.framesPerSecond, 1),
          framesEncoded: r.framesEncoded,
          keyFramesEncoded: r.keyFramesEncoded,
          // Rises when the encoder is asked for more than the CPU can give.
          totalEncodeTimeMs: num(r.totalEncodeTime * 1000, 0),
          encoder: r.encoderImplementation,
          // Non-null means simulcast or scaling is on, which silently defeats life-size.
          scalability: r.scalabilityMode ?? null,
          nackCount: r.nackCount,
          pliCount: r.pliCount,
          retransmittedBytes: r.retransmittedBytesSent,
          // The send side of the FEC question. Non-zero means Chrome chose to spend bitrate on
          // redundancy; zero under loss means it did not, and the freezes are the consequence.
          fecPacketsSent: r.fecPacketsSent ?? null,
          fecBytesSent: r.fecBytesSent ?? null,
        };
      }
      // ── What the CAMERA actually handed us ──────────────────────────────────
      // `outbound-rtp` reports the encoded frame rate, which is silently the *minimum* of what
      // the camera produced and what the encoder managed. When those two are conflated a
      // 7 fps call has three unrelated causes — a camera that never delivered 30, an encoder
      // starved of CPU, or a network that forced frames to be dropped — and they need three
      // different fixes. `media-source` is upstream of the encoder, so comparing its fps to
      // the outbound fps splits the blame: equal and low means the camera, outbound lower
      // means us. Worth its own block because the first real diagnosis of a bad call will
      // hinge on exactly this comparison, and guessing costs more than sampling.
      if (r.type === 'media-source' && r.kind === 'video') {
        out.source = {
          w: r.width,
          h: r.height,
          fps: num(r.framesPerSecond, 1),
          frames: r.frames,
        };
      }
      // ── What our AUDIO encoder is actually doing ────────────────────────────
      // Only inbound audio was sampled before, which is enough to see damage arriving but
      // says nothing about what we sent. The design asks for audio that feels lossless and
      // the app was shipping Chrome's Opus default — about 32 kbps mono — without ever
      // measuring it. That default is unremarkable for a video call and nowhere near
      // transparent, and there was no field anywhere that would have revealed it.
      //
      // `bytesSent` here is the only honest check that an SDP bitrate request was actually
      // honoured: a `maxaveragebitrate` the far end ignores looks identical to one it obeyed
      // until you difference the bytes. `channels` matters for its own reason — libwebrtc
      // picks Opus's application mode from the channel count, so it is the observable proxy
      // for whether we got waveform-preserving CELT or parametric SILK.
      if (r.type === 'outbound-rtp' && r.kind === 'audio') {
        out.asend = {
          bytesSent: r.bytesSent,
          packetsSent: r.packetsSent,
          targetBitrate: r.targetBitrate ?? null,
          retransmittedBytes: r.retransmittedBytesSent,
          nackCount: r.nackCount,
        };
      }
      if (r.type === 'media-source' && r.kind === 'audio') {
        out.asource = { level: num(r.audioLevel, 4), energy: num(r.totalAudioEnergy, 4) };
      }
      // The negotiated codec, per direction. `sdpFmtpLine` is what the two ends actually
      // agreed on rather than what we asked for, which is the difference between a knob
      // that works and a knob that is merely present in our own offer.
      if (r.type === 'codec' && /opus/i.test(r.mimeType || '')) {
        out.acodec = {
          clockRate: r.clockRate,
          channels: r.channels ?? null,
          fmtp: (r.sdpFmtpLine || '').slice(0, 160) || null,
        };
      }
      if (r.type === 'candidate-pair' && r.state === 'succeeded' && r.currentRoundTripTime != null) {
        const rtt = r.currentRoundTripTime * 1000;
        if (out.pair.rttMs == null || rtt < out.pair.rttMs) {
          // WHICH ROAD THE CALL TOOK. Without this a latency number is not
          // interpretable: 366 ms means one thing over a relay and something
          // very different peer-to-peer, and until 2026-08-14 nothing in the
          // room log recorded it — the ICE path was computed only for the
          // health beacon, which is flag-gated, so ordinary calls left no trace
          // of their own route. `relay/relay` is Cloudflare's TURN carrying the
          // media; `srflx`/`host` are direct. Two cheap fields that turn "is
          // direct faster than the relay?" from an argument into a query.
          const L = stats.get(r.localCandidateId);
          const R = stats.get(r.remoteCandidateId);
          out.pair = {
            rttMs: num(rtt, 2),
            availableOutgoingBitrate: r.availableOutgoingBitrate,
            availableIncomingBitrate: r.availableIncomingBitrate,
            bytesSent: r.bytesSent,
            bytesReceived: r.bytesReceived,
            path: L?.candidateType && R?.candidateType ? `${L.candidateType}/${R.candidateType}` : null,
            proto: L?.protocol ?? null,
            // The relay's own location, when the media rides one. A relay in the
            // wrong region is a hidden distance limit of exactly the kind this
            // codebase has already paid for three times today.
            relayProto: L?.relayProtocol ?? null,
          };
        }
      }
      if (r.type === 'outbound-rtp' && r.kind === 'video') {
        out.video.outW = r.frameWidth;
        out.video.outH = r.frameHeight;
        out.video.outFps = num(r.framesPerSecond, 1);
        out.video.outBitrateHint = r.targetBitrate;
        out.video.qualityLimitation = r.qualityLimitationReason;
        out.video.encodeMsPerFrame =
          r.framesEncoded && r.totalEncodeTime ? num((r.totalEncodeTime / r.framesEncoded) * 1000, 2) : null;
      }
    });
  } catch {
    /* transient — a failed sample is not worth surfacing */
  }
  return out;
}

const num = (v, digits) => (typeof v === 'number' && Number.isFinite(v) ? +v.toFixed(digits) : null);
