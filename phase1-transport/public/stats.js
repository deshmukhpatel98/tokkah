// Measurement, aggregation, verdict, and export.
// No dependencies — the chart is hand-rolled canvas so there's nothing between
// the numbers and the screen.

export const BUCKET_MS = 200;

export function pct(sorted, p) {
  if (!sorted.length) return null;
  const i = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[i];
}

/**
 * Loss accounting under unordered delivery.
 *
 * The whole point of this channel is `ordered: false`, so arrival order tells
 * you nothing. A sequence number is only declared lost once the high-water mark
 * has advanced far enough past it that reordering can no longer explain the gap.
 * Counting a gap as loss immediately would massively overstate loss and give a
 * false FAIL on the decision gate.
 */
export class LossTracker {
  constructor(reorderWindowPkts = 1500) {
    this.window = reorderWindowPkts;
    this.seen = new Set();
    this.cursor = null;
    this.high = -1;
    this.received = 0;
    this.lost = 0;
    this.reordered = 0;
    this.lastSeq = -1;
  }

  onPacket(seq) {
    this.received++;
    this.seen.add(seq);
    if (this.cursor === null) this.cursor = seq;
    if (seq > this.high) this.high = seq;
    else if (seq < this.lastSeq) this.reordered++;
    this.lastSeq = seq;
  }

  /** Finalize anything now beyond the reorder window. Call once per bucket. */
  finalize() {
    const limit = this.high - this.window;
    let lostNow = 0;
    while (this.cursor !== null && this.cursor < limit) {
      if (this.seen.has(this.cursor)) this.seen.delete(this.cursor);
      else {
        this.lost++;
        lostNow++;
      }
      this.cursor++;
    }
    return lostNow;
  }

  /** Drain the tail once the test stops, so trailing packets aren't lost forever. */
  flush() {
    while (this.cursor !== null && this.cursor <= this.high) {
      if (this.seen.has(this.cursor)) this.seen.delete(this.cursor);
      else this.lost++;
      this.cursor++;
    }
  }

  get lossRate() {
    const total = this.received + this.lost;
    return total ? this.lost / total : 0;
  }
}

/** One ~200 ms slice of truth. */
class Bucket {
  constructor(t, wallStart) {
    this.t = t;
    this.wallStart = wallStart;
    this.wallEnd = wallStart;
    this.bytesRecv = 0;
    this.pktRecv = 0;
    this.lost = 0;
    this.owd = [];
    this.buffered = [];
    this.bytesSent = 0;
    this.targetBps = 0;
  }
  summarize(owdFloor) {
    const s = [...this.owd].sort((a, b) => a - b);
    const b = [...this.buffered].sort((a, b) => a - b);
    // Divide by the span this bucket ACTUALLY covered, not the nominal
    // BUCKET_MS. A late roll — jank, GC, or a throttled timer — stretches the
    // real span, and dividing by the nominal value silently multiplies the
    // reported throughput. That failure mode produces numbers that look
    // entirely plausible, so it has to be structurally impossible.
    const spanSec = Math.max(this.wallEnd - this.wallStart, 1) / 1000;
    return {
      t: this.t,
      spanMs: +(spanSec * 1000).toFixed(1),
      recvMbps: (this.bytesRecv * 8) / spanSec / 1e6,
      sentMbps: (this.bytesSent * 8) / spanSec / 1e6,
      targetMbps: this.targetBps / 1e6,
      pktRecv: this.pktRecv,
      lost: this.lost,
      // OWD carries an unknown constant offset from clock-sync asymmetry, so we
      // report it relative to the session floor. Gradient and spread are the
      // signals that mean anything; the absolute value is not trustworthy.
      owdP50: s.length ? pct(s, 50) - owdFloor : null,
      owdP95: s.length ? pct(s, 95) - owdFloor : null,
      owdMax: s.length ? s[s.length - 1] - owdFloor : null,
      bufP95KB: b.length ? pct(b, 95) / 1024 : null,
      bufMaxKB: b.length ? b[b.length - 1] / 1024 : null,
    };
  }
}

export class Collector {
  constructor() {
    this.reset();
  }

  reset() {
    this.buckets = [];
    this.current = null;
    this.loss = new LossTracker();
    this.owdFloor = Infinity;
    this.allOwd = [];
    this.allBuffered = [];
    this.startedAt = null;
    this.pathType = null;
    this.iceRtt = null;
    this.availOutBps = null;
    this.steps = [];
    // Known state, deliberately NOT derived from the sampling timer. A single
    // missed sample used to leave a bucket at targetBps=0, which quietly
    // excluded it from the verdict — losing data without saying so.
    this.currentTargetBps = 0;
    this.lastBuffered = null;
    // How long the plan said this run would send for. Without it, a send span that ends early
    // because the connection died is indistinguishable from one that ends because the test
    // finished — see the survival check in verdict().
    this.plannedMs = 0;
  }

  setPlan(totalMs) {
    this.plannedMs = totalMs;
  }

  start() {
    this.startedAt = performance.now();
    this.rollBucket(0, this.startedAt);
  }

  rollBucket(t, now) {
    if (this.current) {
      this.current.wallEnd = now;
      this.current.lost = this.loss.finalize();
      this.buckets.push(this.current);
    }
    this.current = new Bucket(t, now);
    // Seed from known state so every bucket is judgeable even if the sampler
    // misses it. bufferedAmount is slowly-varying, so carrying the last reading
    // forward is honest; the nominal rate is exact.
    this.current.targetBps = this.currentTargetBps;
    if (this.lastBuffered !== null) this.current.buffered.push(this.lastBuffered);
  }

  /**
   * Roll on elapsed wall time. Called from both the sampler AND the receive
   * path, so bucket boundaries stay honest even if the sampling timer is
   * throttled — the receive path fires ~1300×/s and can always be trusted.
   */
  maybeRoll(nowMs) {
    if (this.startedAt === null) return;
    const t = nowMs - this.startedAt;
    const want = Math.floor(t / BUCKET_MS) * BUCKET_MS;
    if (!this.current || want > this.current.t) this.rollBucket(want, nowMs);
  }

  /**
   * Sampler for signals that only exist locally: bufferedAmount. The target
   * rate is NOT taken from here — markStep() owns it, because a receive-only
   * peer has no pacer to read it from and would report 0.
   */
  tick(nowMs, bufferedAmount) {
    if (this.startedAt === null) return;
    this.maybeRoll(nowMs);
    this.current.wallEnd = nowMs;
    this.current.buffered.push(bufferedAmount);
    this.allBuffered.push(bufferedAmount);
    this.lastBuffered = bufferedAmount;
  }

  onRecv(seq, owdMs, bytes) {
    if (this.startedAt === null) return;
    const now = performance.now();
    this.maybeRoll(now);
    this.current.wallEnd = now;
    this.loss.onPacket(seq);
    this.current.bytesRecv += bytes;
    this.current.pktRecv++;
    this.current.owd.push(owdMs);
    this.allOwd.push(owdMs);
    if (owdMs < this.owdFloor) this.owdFloor = owdMs;
  }

  onSent(bytes) {
    if (this.startedAt === null) return;
    // Also roll here, so a unidirectional sender (which receives nothing) still
    // gets honest bucket spans without depending on the sampling timer.
    const now = performance.now();
    this.maybeRoll(now);
    this.current.wallEnd = now;
    this.current.bytesSent += bytes;
  }

  markStep(label, targetBps) {
    this.currentTargetBps = targetBps;
    if (this.current) this.current.targetBps = targetBps;
    this.steps.push({ t: performance.now() - this.startedAt, label, targetBps });
  }

  stop() {
    this.loss.flush();
    if (this.current) {
      this.current.wallEnd = Math.max(this.current.wallEnd, performance.now());
      this.buckets.push(this.current);
      this.current = null;
    }
  }

  /**
   * The baseline that gets subtracted from every one-way delay.
   *
   * OWD is computed across two clocks, so it carries an unknown constant offset and only the
   * value *relative to the session's own baseline* means anything. That baseline used to be the
   * session minimum, which is the one estimator a single bad sample can destroy: a minimum can
   * be dragged down and never recovers, so one freak reading silently reprices every packet
   * that follows it.
   *
   * It happened. On one side of an otherwise clean 80 ms cell the floor landed 275 ms below a
   * steady state that was flat to within 1 ms for 40 s, and the gate then reported 277 ms of
   * queueing delay while `bufferedAmount` sat at 3.4 KB — which at 12 Mbps is 2.3 ms of data,
   * so the two readings could not both be true. Same shape at 150 ms: 70.5 ms of phantom queue.
   * Both were false FAILs on a real pass.
   *
   * So the baseline is a low percentile instead. p1 cannot be moved by one sample, and with
   * tens of thousands of packets per session it is still deep in the genuinely-unqueued
   * population. The gap between it and the raw minimum is kept and reported rather than
   * discarded: if a clock did glitch, that is worth seeing, not worth hiding. The direction of
   * the residual error matters too — p1 sits at or above the true floor, so it *understates*
   * queueing, and a gate must never be lenient by accident. Hence `owdFloorGapMs` travels with
   * every export.
   */
  get owdFloorRobust() {
    if (!this.allOwd.length) return 0;
    const s = [...this.allOwd].sort((a, b) => a - b);
    return pct(s, 1);
  }

  get owdFloorGapMs() {
    if (!this.allOwd.length || !Number.isFinite(this.owdFloor)) return null;
    return +(this.owdFloorRobust - this.owdFloor).toFixed(1);
  }

  rows() {
    const floor = this.allOwd.length
      ? this.owdFloorRobust
      : Number.isFinite(this.owdFloor)
        ? this.owdFloor
        : 0;
    return this.buckets.map((b) => b.summarize(floor));
  }

  /**
   * The decision gate from DESIGN.md §19.
   *
   * Judged over the steady-state portion of each step, skipping the first 3 s so
   * SCTP slow-start and PMTUD ramp-up don't pollute the verdict — those are real
   * and expected, they're just not what the gate is asking about.
   *
   * ── The send span, and why the verdict has to be clipped to it ──────────────
   * Bucketing outlives the pacer. When the send phase ends the collector keeps
   * rolling buckets until the driver harvests, so a run's tail is drained
   * channel: zero throughput, and a `bufferedAmount` reading left over from
   * teardown. Those buckets are not measurements of anything.
   *
   * Unclipped, that tail decided a whole matrix. Six cells reported a throughput
   * floor of 0.00 Mbps and `bufferedAmount` p95 of 256 KB, which read as total
   * transport collapse; three of them were in fact carrying 12.00 Mbps at 2.2 KB
   * buffered for every second the pacer was actually writing. A p5 is defenceless
   * against a fifth of its samples being structural zeros.
   *
   * The clip is a *span*, first write to last write, and every bucket inside it
   * is kept — including ones where the sender was blocked and wrote nothing. That
   * distinction is the whole point. Dropping individual zero-send buckets would
   * have been simpler and would have quietly deleted the evidence of the failure
   * this same run found: under packet loss the sender is blocked most of the time,
   * so a per-bucket filter flatters a collapsing transport precisely when it is
   * collapsing. Excluding teardown must not become excusing backpressure.
   */
  verdict(targetMbps, gateRttMs) {
    const rows = this.rows();
    const wrote = rows.map((r, i) => (r.sentMbps >= 0.01 ? i : -1)).filter((i) => i >= 0);
    const span = wrote.length ? rows.slice(wrote[0], wrote[wrote.length - 1] + 1) : [];
    const settled = span.filter(
      (r) => Math.abs(r.targetMbps - targetMbps) < 0.01 && r.t > 3000,
    );
    if (settled.length < 10) {
      return {
        ok: null,
        reason: `not enough settled data at ${targetMbps} Mbps (${settled.length} rows in a ${span.length}-row send span of ${rows.length})`,
      };
    }

    const recv = settled.map((r) => r.recvMbps).sort((a, b) => a - b);
    const bufs = settled.map((r) => r.bufP95KB ?? 0).sort((a, b) => a - b);
    const owds = settled.map((r) => r.owdP95).filter((v) => v != null).sort((a, b) => a - b);

    const medianRecv = pct(recv, 50);
    const p05Recv = pct(recv, 5);
    const bufP95 = pct(bufs, 95);
    const owdP95 = owds.length ? pct(owds, 95) : null;
    const lossRate = this.loss.lossRate;

    // ── Did the sender survive to the end of the plan? ────────────────────────
    // The span clip above exists to stop teardown drain from poisoning a p5. It buys that at the
    // cost of being unable, by itself, to tell a finished run from a dead one: both end with the
    // pacer no longer writing. That gap is not hypothetical — a connection that died at 38.7 s of
    // a 45 s soak passed every other check on this list, because every bucket inside its truncated
    // span was genuinely healthy. The receive path stopping dead mid-run is the most serious
    // failure this harness can observe and it was scoring as a pass.
    const spanEndMs = settled.length ? settled[settled.length - 1].t : 0;
    const coverage = this.plannedMs ? spanEndMs / this.plannedMs : null;

    const checks = [
      {
        // First in the list on purpose: if this fails, the others are describing a shorter run
        // than the one that was asked for, and their numbers are not answers to the question.
        name: 'sender survived to the end of the plan',
        ok: coverage == null || coverage >= 0.95,
        got:
          coverage == null
            ? 'no plan recorded'
            : `sent until ${(spanEndMs / 1000).toFixed(1)}s of ${(this.plannedMs / 1000).toFixed(1)}s (${(coverage * 100).toFixed(0)}%)`,
      },
      {
        name: `throughput ≥ 97% of ${targetMbps} Mbps (median)`,
        ok: medianRecv >= 0.97 * targetMbps,
        got: `${medianRecv.toFixed(2)} Mbps`,
      },
      {
        name: 'throughput floor ≥ 90% (p5 bucket)',
        ok: p05Recv >= 0.9 * targetMbps,
        got: `${p05Recv.toFixed(2)} Mbps`,
      },
      {
        name: 'loss < 0.5%',
        ok: lossRate < 0.005,
        got: `${(lossRate * 100).toFixed(3)}%`,
      },
      {
        // The one that actually decides it. If bufferedAmount is pinned, our
        // pacer is not the binding controller — usrsctp's cwnd is — and we have
        // lost control of the policy the whole design rests on (§8, hazard 3).
        name: 'bufferedAmount p95 < 64 KB (pacer, not SCTP, is binding)',
        ok: bufP95 < 64,
        got: `${bufP95.toFixed(1)} KB`,
      },
      {
        name: 'queueing delay p95 < 30 ms above floor',
        ok: owdP95 != null && owdP95 < 30,
        got: owdP95 == null ? 'no data' : `${owdP95.toFixed(1)} ms`,
      },
    ];

    return {
      ok: checks.every((c) => c.ok),
      checks,
      context: {
        targetMbps,
        gateRttMs,
        measuredIceRttMs: this.iceRtt,
        pathType: this.pathType,
        settledBuckets: settled.length,
      },
    };
  }

  toJSON(meta) {
    return {
      meta: { ...meta, pathType: this.pathType, iceRttMs: this.iceRtt },
      steps: this.steps,
      totals: {
        received: this.loss.received,
        lost: this.loss.lost,
        reordered: this.loss.reordered,
        lossRate: this.loss.lossRate,
        owdFloorMs: Number.isFinite(this.owdFloor) ? this.owdFloor : null,
        // The robust baseline actually used, and how far the raw minimum sat below it. A large
        // gap means a clock glitch produced a sample no later packet came near; see owdFloorRobust.
        owdFloorRobustMs: +this.owdFloorRobust.toFixed(2),
        owdFloorGapMs: this.owdFloorGapMs,
      },
      rows: this.rows(),
    };
  }

  toCSV() {
    const rows = this.rows();
    const cols = [
      't', 'spanMs', 'targetMbps', 'sentMbps', 'recvMbps', 'pktRecv', 'lost',
      'owdP50', 'owdP95', 'owdMax', 'bufP95KB', 'bufMaxKB',
    ];
    const lines = [cols.join(',')];
    for (const r of rows) {
      lines.push(cols.map((c) => (r[c] == null ? '' : Number(r[c]).toFixed(3))).join(','));
    }
    return lines.join('\n');
  }
}

// ── Chart ────────────────────────────────────────────────────────────────────

export class Chart {
  constructor(canvas, windowBuckets = 150) {
    this.canvas = canvas;
    this.window = windowBuckets;
    this.series = [
      { key: 'recvMbps', label: 'recv Mbps', color: '#4ade80', axis: 'mbps' },
      { key: 'targetMbps', label: 'target Mbps', color: '#334155', axis: 'mbps', dash: [4, 4] },
      { key: 'owdP95', label: 'queue delay p95 (ms)', color: '#fbbf24', axis: 'ms' },
      { key: 'bufP95KB', label: 'buffered p95 (KB)', color: '#f87171', axis: 'kb' },
    ];
  }

  draw(rows) {
    const c = this.canvas;
    const dpr = window.devicePixelRatio || 1;
    const w = c.clientWidth;
    const h = c.clientHeight;
    if (c.width !== w * dpr || c.height !== h * dpr) {
      c.width = w * dpr;
      c.height = h * dpr;
    }
    const g = c.getContext('2d');
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, w, h);

    const pad = { l: 44, r: 52, t: 10, b: 20 };
    const pw = w - pad.l - pad.r;
    const ph = h - pad.t - pad.b;

    const data = rows.slice(-this.window);
    if (data.length < 2) {
      g.fillStyle = '#475569';
      g.font = '12px ui-monospace, monospace';
      g.fillText('waiting for data…', pad.l, pad.t + 16);
      return;
    }

    const maxOf = (keys) => {
      let m = 0;
      for (const r of data) for (const k of keys) if (r[k] != null && r[k] > m) m = r[k];
      return m;
    };
    const scales = {
      mbps: Math.max(1, maxOf(['recvMbps', 'targetMbps']) * 1.15),
      ms: Math.max(10, maxOf(['owdP95']) * 1.15),
      kb: Math.max(16, maxOf(['bufP95KB']) * 1.15),
    };

    // grid
    g.strokeStyle = '#1e293b';
    g.lineWidth = 1;
    for (let i = 0; i <= 4; i++) {
      const y = pad.t + (ph * i) / 4;
      g.beginPath();
      g.moveTo(pad.l, y);
      g.lineTo(pad.l + pw, y);
      g.stroke();
    }
    g.fillStyle = '#64748b';
    g.font = '10px ui-monospace, monospace';
    for (let i = 0; i <= 4; i++) {
      const y = pad.t + (ph * i) / 4;
      const v = (scales.mbps * (4 - i)) / 4;
      g.fillText(v.toFixed(0), 6, y + 3);
    }
    g.textAlign = 'left';
    for (let i = 0; i <= 4; i++) {
      const y = pad.t + (ph * i) / 4;
      const v = (scales.ms * (4 - i)) / 4;
      g.fillText(`${v.toFixed(0)}ms`, pad.l + pw + 6, y + 3);
    }

    for (const s of this.series) {
      g.strokeStyle = s.color;
      g.lineWidth = s.dash ? 1 : 1.6;
      g.setLineDash(s.dash || []);
      g.beginPath();
      let started = false;
      data.forEach((r, i) => {
        const v = r[s.key];
        if (v == null) return;
        const x = pad.l + (pw * i) / (data.length - 1);
        const y = pad.t + ph - (ph * Math.min(v, scales[s.axis])) / scales[s.axis];
        if (!started) {
          g.moveTo(x, y);
          started = true;
        } else g.lineTo(x, y);
      });
      g.stroke();
      g.setLineDash([]);
    }
  }

  legend(el) {
    el.innerHTML = this.series
      .map(
        (s) =>
          `<span class="key"><i style="background:${s.color}"></i>${s.label}</span>`,
      )
      .join('');
  }
}
