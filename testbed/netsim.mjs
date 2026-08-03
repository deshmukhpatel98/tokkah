/**
 * A network, built rather than borrowed.
 *
 * Every latency number measured so far has been on loopback, where the ICE round trip
 * reads 0 ms. That makes the pipeline's own cost visible — which is how the 58 ms of
 * self-inflicted delay in DESIGN.md §17.1 got found — but it says nothing about whether
 * anything survives a real network. Both browsers are on one machine, so there is no
 * distance to measure and nothing to borrow.
 *
 * The fix is to force the media through a TURN relay that we control, and put a delay in
 * front of it. Two pieces:
 *
 *   Chrome  ⟷  this delay proxy  ⟷  a local TURN server  ⟷  delay proxy  ⟷  Chrome
 *
 * The proxy is a plain UDP forwarder that holds each datagram for a while before passing
 * it on, dropping some and reordering others. Because it sits between each browser and
 * the relay, a packet crosses it twice on its way from one browser to the other — so the
 * configured one-way delay is applied twice per direction, and the numbers below account
 * for that explicitly rather than leaving it to be discovered later.
 *
 * Why not shape the interface instead: `tc`/`dnctl`/`pfctl` all need root, and asking for
 * a password to run a test is a worse trade than fifty lines of UDP forwarding. Why not a
 * public TURN server: it would put real conversation audio through a third party, and the
 * point of a test harness is that nothing leaves the machine.
 *
 * What this can and cannot claim:
 *   ✓ real UDP datagrams, real ICE relay candidates, real TURN allocation and channels
 *   ✓ delay, jitter, loss and reordering applied to the actual media path
 *   ✗ not a real internet path — no cross-traffic, no bufferbloat, no route changes, no
 *     MTU discovery, no NAT rebinding. It emulates distance, not the internet.
 */

import dgram from 'node:dgram';
import { fileURLToPath } from 'node:url';
import TurnServer from 'node-turn';

/** Deterministic PRNG, so a run with the same seed drops the same packets. */
function prng(seed) {
  let s = seed | 0 || 1;
  return () => {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    return s / 0x7fffffff;
  };
}

/**
 * A token-bucket bottleneck: a link of finite capacity that queues, then tail-drops.
 *
 * Delay and loss alone cannot emulate a slow link, and the difference is not a detail. On
 * loopback there is no capacity limit at all, so Google Congestion Control probes upward
 * without ever finding a ceiling — `availableOutgoingBitrate` was measured reaching 39.7 Mbps
 * against a 12 Mbps cap. Every quality number this project has taken was therefore on an
 * effectively infinite link, which means the design's central claim — quality is a constant,
 * time is the shock absorber (§1) — has never actually been under pressure.
 *
 * Why this queues instead of just dropping: GCC infers congestion mainly from the *delay
 * gradient*, the one-way delay creeping up as a queue fills, and only secondarily from loss. A
 * bottleneck that discards excess without ever queueing exercises the loss path and leaves the
 * primary signal untested, so the sender would back off for the wrong reason and at the wrong
 * time. A real access link holds a queue and tail-drops when it is full, so this does too, and
 * the queue is sized in milliseconds rather than bytes because that is the unit that decides
 * how the transport behaves — 100 ms of buffering at 5 Mbps and at 50 Mbps are entirely
 * different links but very nearly the same byte count is meaningless between them.
 *
 * The queue delay it adds is reported, because that number *is* the bufferbloat this design
 * exists to avoid, and it is the one the far end's playout buffer will have to absorb.
 */
function bottleneck({ bps, queueMs, onDrop, onQueueMs }) {
  if (!bps) return (bytes, fn) => fn(); // no ceiling configured — pass straight through
  const queueBytes = Math.max(1500, Math.round((bps / 8) * (queueMs / 1000)));
  // A 5 ms burst allowance. Zero burst would serialise every packet even on an idle link and
  // add delay a real link does not; a large burst would let a sender exceed the rate for long
  // enough to hide the ceiling entirely.
  const burstBytes = Math.max(1500, (bps / 8) * 0.005);
  let tokens = burstBytes;
  let last = performance.now();
  let queued = 0;
  const q = [];
  let timer = null;

  const pump = () => {
    timer = null;
    const now = performance.now();
    tokens = Math.min(burstBytes, tokens + ((now - last) / 1000) * (bps / 8));
    last = now;
    while (q.length && tokens >= q[0].bytes) {
      const it = q.shift();
      tokens -= it.bytes;
      queued -= it.bytes;
      onQueueMs(now - it.at);
      it.fn();
    }
    if (q.length) {
      // Sleep exactly as long as the head of the queue needs, not a fixed tick: a polling
      // interval would quantise the emulated rate to whatever the tick happened to be.
      const ms = Math.max(1, ((q[0].bytes - tokens) / (bps / 8)) * 1000);
      timer = setTimeout(pump, ms);
      timer.unref?.();
    }
  };

  return (bytes, fn) => {
    if (queued + bytes > queueBytes) {
      onDrop();
      return;
    }
    queued += bytes;
    q.push({ bytes, fn, at: performance.now() });
    if (!timer) pump();
  };
}

/**
 * A one-way UDP delay line in front of `upstreamPort`.
 *
 * One socket faces the clients and one socket per client faces upstream, so two browsers
 * sharing the proxy stay distinguishable — without the per-client upstream socket the TURN
 * server would see both allocations arriving from the same address and port.
 *
 * `bwMbps` gives each client its own bottleneck in each direction, rather than one shared
 * ceiling: the thing being emulated is two people on two household links, and a single shared
 * bucket would silently model them as sharing one.
 *
 * CAVEAT, and it bit hard: the bucket is keyed on `address:port`, so it is one bucket per
 * SOURCE PORT, not per client. That was the same thing when the app had one peer connection.
 * It is not now — Lane A stripes across 6 data-channel PCs plus the media PC, so each browser
 * draws ~7 independent buckets and the effective aggregate ceiling is ~7x the flag. Three
 * A/Bs were run at `--bw=2.5` believing the lanes were competing for 2.5 Mbps; they were
 * competing for ~17. Measured: `--bw=2.5` queues 31,883 packets but at p50 0 / p95 0 /
 * max 30 ms with zero drops, whereas `--bw=0.3` gives p95 58.7 ms, max 99.8 ms and 0.68%
 * overflow — THAT is a constrained link for this app. Read `bwQueue` from the run before
 * believing any capped result, and divide the household rate you mean by the PC count.
 */
export async function delayProxy({
  upstreamPort,
  delayMs = 0,
  jitterMs = 0,
  lossPct = 0,
  seed = 1,
  host = '127.0.0.1',
  bwMbps = 0,
  queueMs = 100,
}) {
  const rnd = prng(seed);
  // Loss is held in a cell rather than read from the parameter binding so a test can
  // change conditions DURING a call. A jitter buffer that grows on pain and shrinks
  // slowly can only be caught by a run where the pain stops and you watch what happens
  // next; with loss fixed at construction, that run is impossible to write.
  let loss = lossPct;
  // ── Why the buffers are set explicitly ───────────────────────────────────────────────
  // Node's default UDP buffers are small — tens of kilobytes. At the 12 Mbps this design
  // targets, in both directions, through two userspace hops, a few tens of kilobytes is a few
  // tens of *milliseconds* of headroom: one scheduling hiccup longer than that and the kernel
  // discards datagrams. A delay line that silently drops the traffic it was built to carry
  // reports the host's buffer size as the network's loss rate, and every number downstream
  // inherits the mistake. 8 MB is far more than a correct run needs, which is the point —
  // the emulator should never be the scarce resource.
  const front = dgram.createSocket({ type: 'udp4', recvBufferSize: 1 << 23, sendBufferSize: 1 << 23 });
  const perClient = new Map(); // "ip:port" → { sock, lastSeen }
  // `dropped` is loss this proxy was *told* to inject. `sendErrors` is loss it suffered by
  // accident — a failed sendto, almost always ENOBUFS. Keeping them in separate counters is
  // the whole point: conflated, an overloaded emulator is indistinguishable from a lossy
  // network, and the transport gets blamed for the harness. Reported unconditionally, because
  // the value that matters most is the one nobody thought to ask for.
  // `bwDropped` is a third, separate loss counter, for the same reason `dropped` and
  // `sendErrors` are separate: loss injected on purpose, loss because a modelled link ran out
  // of capacity, and loss because the emulator itself failed are three different findings, and
  // one conflated number would let any of them be reported as the network's behaviour.
  // `sizes` buckets every datagram the emulator carries. A transport whose
  // application messages sit just above the SCTP/DTLS payload limit splits each
  // one into a full packet plus a small tail, and the application then loses a
  // message whenever EITHER half is dropped — an injected 5% becomes an effective
  // ~11% that no application counter can distinguish from network loss. The tail
  // fragments are the visible signature, so count small packets separately.
  const stats = { sent: 0, dropped: 0, bwDropped: 0, sendErrors: 0, unreachable: 0, errCodes: {}, bytes: 0, lagMs: [], lateMs: [], queueMs: [], sizes: { tiny: 0, small: 0, mid: 0, full: 0 } };
  const bucket = (n) => {
    if (n < 120) stats.sizes.tiny++;
    else if (n < 600) stats.sizes.small++;
    else if (n < 1100) stats.sizes.mid++;
    else stats.sizes.full++;
  };
  // ── Why "the destination isn't there" is not counted as emulator failure ───────────────
  // The `sendErrors` guard exists to catch exactly one thing: the emulator discarding packets
  // it was never asked to discard, because it could not keep up. That is ENOBUFS, and it
  // matters enormously — it makes the injected loss rate a fiction and gets the transport
  // blamed for the harness. These three errnos say something entirely different: the address
  // we were asked to forward to cannot be reached.
  //
  // In the relay-free topology that is routine. Chrome gathers a host candidate on every local
  // interface, and this machine has `en8` holding a link-local 169.254.27.97 with nothing on
  // the other side, so every ICE check aimed there fails with EHOSTUNREACH. Ports also close
  // while packets are still in the delay line at teardown, which gives ECONNREFUSED.
  //
  // Getting this classification wrong was expensive in both directions and is worth recording:
  // conflated, 36 unreachable ICE checks out of 185,031 datagrams condemned a 75 s run that was
  // otherwise perfect — zero app-level loss, zero NACKs — and would have condemned every
  // relay-free run after it. But splitting out ECONNREFUSED alone was a *guess* at which errno
  // it was, and the run refuted it: 36 by accident, 0 refused. Hence the errno histogram, so a
  // future surprise here is diagnosable from the run that found it rather than needing another.
  const UNREACHABLE = new Set(['ECONNREFUSED', 'EHOSTUNREACH', 'ENETUNREACH']);
  const onSend = (err) => {
    if (!err) return;
    const code = err.code || err.errno || 'UNKNOWN';
    stats.errCodes[code] = (stats.errCodes[code] || 0) + 1;
    if (UNREACHABLE.has(code)) {
      stats.unreachable++;
      return;
    }
    stats.sendErrors++;
  };
  const onBwDrop = () => {
    stats.bwDropped++;
  };
  const onQueueMs = (ms) => {
    stats.queueMs.push(ms);
    if (stats.queueMs.length > 8000) stats.queueMs.shift();
  };
  const bps = bwMbps * 1e6;
  const newBucket = () => bottleneck({ bps, queueMs, onDrop: onBwDrop, onQueueMs });

  // ── Why the delay line watches its own event loop ────────────────────────────────────
  // Every datagram is held by a setTimeout and forwarded when it fires. That means the
  // emulated distance is not a property of the network — it is a property of this Node event
  // loop's punctuality. At 12 Mbps a datagram crosses the proxy twice per direction, so the
  // loop is servicing something like 5000 timer callbacks a second, and if the loop is late
  // by L then every packet in flight is late by up to L.
  //
  // This is not hypothetical. A run that measured 4.8% loss against 1% injected, with queue
  // delays of 2.6-3.8 s, was taken at a moment when macOS Spotlight indexing was using about
  // three of this machine's four performance cores. Nothing was wrong with the transport; the
  // ruler was being jostled. From inside the browser the two are indistinguishable, so the
  // ruler has to report its own steadiness and the caller has to be able to throw the run
  // away. A harness that cannot say "I could not measure this" will eventually say "your code
  // is broken" instead, which is worse than silence.
  const lagTimer = setInterval(() => {
    const want = 50;
    const t0 = performance.now();
    setTimeout(() => {
      stats.lagMs.push(performance.now() - t0 - want);
      if (stats.lagMs.length > 4000) stats.lagMs.shift();
    }, want);
  }, 200);
  lagTimer.unref?.();

  // ── Measuring the delay line's own fidelity ──────────────────────────────────────────
  // The loop-lag probe above samples every 200 ms with a 50 ms timer, so it reports *average*
  // punctuality and cannot see a pause that falls between two samples. That is not a small
  // gap: a run whose NACK count climbed for 30 s straight reported loop lag p95 of 1.81 ms,
  // because the stalls it suffered never overlapped a probe window.
  //
  // This measures the thing that actually matters instead of a proxy for it — for a sampled
  // fraction of real datagrams, how much later than promised did the packet actually leave?
  // A delay line that promises 80 ms and sometimes delivers 300 ms is not emulating distance,
  // it is adding a burst of jitter and reordering that the transport will read as congestion.
  // Sampled 1 in 64 so it costs nothing at 5000 packets/second.
  let heldSeq = 0;
  // Every delayed send is a live setTimeout holding a reference to a socket that close() is
  // about to shut. When the timer fires afterwards, dgram.send() throws
  // ERR_SOCKET_DGRAM_NOT_RUNNING *synchronously* — it does not route to the send callback —
  // so the error escapes hold() and kills the process. It fired on every rep of a 16-rep A/B,
  // after each result line had printed, which is the only reason no data was lost. Guarding
  // here rather than at the two send sites covers any future one.
  let closed = false;
  const hold = (fn) => {
    if (closed) return;
    // Jitter is symmetric around the mean, and clamped so it can never produce a negative
    // delay — that would reorder in a way no network does and would flatter the result.
    const d = Math.max(0, delayMs + (jitterMs ? (rnd() * 2 - 1) * jitterMs : 0));
    if (d === 0) return fn();
    if ((heldSeq++ & 63) === 0) {
      const t0 = performance.now();
      setTimeout(() => {
        if (closed) return;
        const late = performance.now() - t0 - d;
        stats.lateMs.push(late);
        if (stats.lateMs.length > 4000) stats.lateMs.shift();
        fn();
      }, d);
      return;
    }
    // The guard has to be INSIDE the callback, not only at hold() entry: the packets that
    // crash the process are the ones already in flight when close() runs.
    setTimeout(() => { if (!closed) fn(); }, d);
  };

  front.on('message', (msg, rinfo) => {
    const key = `${rinfo.address}:${rinfo.port}`;
    let c = perClient.get(key);
    if (!c) {
      const sock = dgram.createSocket({ type: 'udp4', recvBufferSize: 1 << 23, sendBufferSize: 1 << 23 });
      // One bucket per direction. Sharing a bucket between up and down would model a
      // half-duplex link, which no modern access network is, and would make a symmetric
      // 12 Mbps conversation look like it needed 24.
      c = { sock, up: newBucket(), down: newBucket() };
      perClient.set(key, c);
      // Anything coming back from upstream goes to this client, delayed the same way.
      sock.on('message', (m) => {
        if (loss && rnd() * 100 < loss) {
          stats.dropped++;
          return;
        }
        // Bottleneck before propagation, in that order, because that is the order a real path
        // imposes them: a packet waits its turn for the narrow link, is serialised onto it,
        // and only then spends time in flight. Reversing them would let queueing delay hide
        // inside the propagation delay instead of adding to it.
        c.down(m.length, () =>
          hold(() => {
            stats.sent++;
            stats.bytes += m.length;
            bucket(m.length);
            front.send(m, rinfo.port, rinfo.address, onSend);
          }),
        );
      });
      sock.on('error', () => {});
    }
    if (loss && rnd() * 100 < loss) {
      stats.dropped++;
      return;
    }
    c.up(msg.length, () =>
      hold(() => {
        stats.sent++;
        stats.bytes += msg.length;
        bucket(msg.length);
        c.sock.send(msg, upstreamPort, host, onSend);
      }),
    );
  });

  await new Promise((r) => front.bind(0, host, r));
  const port = front.address().port;
  return {
    port,
    stats,
    setLoss: (pct) => { loss = pct; },
    get lossPct() { return loss; },
    close: () => {
      closed = true; // before any socket shuts, so in-flight timers become no-ops
      clearInterval(lagTimer);
      // Sockets are closed *and* unref'd. Closing alone left the driver alive for 16 minutes
      // after it had printed its results, still holding its UDP ports — which is how a later
      // run can end up bound next to a corpse.
      for (const c of perClient.values()) {
        try {
          c.sock.unref();
          c.sock.close();
        } catch {
          /* already gone */
        }
      }
      try {
        front.unref();
        front.close();
      } catch {
        /* already gone */
      }
    },
  };
}

/**
 * Emulated distance on the peer-to-peer path, with no TURN server involved.
 *
 * Why this exists: the node-turn relay used by `startNetsim` is itself the ~40 s cliff
 * documented in §19. Four runs at two different delays saw their first NACK at 42.5–42.8 s, the
 * onset was independent of load, and a `--nosim` control ran 75 s with zero NACKs. So every
 * netsim run longer than about 40 s has loss numbers contaminated by the harness, and the fix is
 * to stop needing a relay at all rather than to keep working around one.
 *
 * How it works: each browser is handed a *rewritten* remote candidate whose port belongs to a
 * delay proxy that forwards to the peer's real port. Neither browser ever learns the other's
 * true address, so there is no direct path for ICE to find and no relay to break. The delay
 * proxy is the same one already proven punctual by its own `lateness()` measurement.
 *
 * Two things get simpler as a side effect, and both make the emulator more honest:
 *
 *   · One crossing per direction instead of two. With TURN, a packet traversed the proxy on the
 *     way in and again on the way out, so `delayMs` had to be halved and `lossPct` had to be
 *     un-compounded (1% asked became 1.99% delivered until that was corrected). Here one
 *     crossing means `delayMs` is the one-way delay and `lossPct` is the loss, as written.
 *   · Half the emulator's work for the same emulated conditions, which matters because the
 *     delay line's punctuality is the measurement.
 *
 * Peer-reflexive candidates cannot escape the delay either, which is worth stating because it
 * is the obvious way this could have leaked. When B's check reaches the proxy, the proxy relays
 * it to A from its own upstream socket, so A learns *that* socket as a prflx candidate. If ICE
 * later nominates it, packets sent there arrive at the proxy's upstream socket, which forwards
 * them to B through the same delay line. Every route through this topology is delayed.
 */
export async function startP2PSim({
  oneWayMs = 0,
  jitterMs = 0,
  lossPct = 0,
  bwMbps = 0,
  queueMs = 100,
  seed = 1,
  host = '127.0.0.1',
}) {
  const proxies = new Map(); // "host:port" → proxy fronting that peer
  return {
    /**
     * The proxy port that stands in for `peerHost:peerPort`. Idempotent: ICE offers the same
     * candidate repeatedly and each one must map to the same proxy, or a single peer would end
     * up behind several delay lines with independent loss draws.
     */
    async portFor(peerHost, peerPort) {
      const key = `${peerHost}:${peerPort}`;
      let p = proxies.get(key);
      if (!p) {
        p = await delayProxy({
          upstreamPort: peerPort,
          host: peerHost,
          delayMs: oneWayMs,
          jitterMs,
          lossPct,
          bwMbps,
          queueMs,
          // A distinct seed per direction. Sharing one would make both directions drop the same
          // packet indices, which is a correlated loss pattern no real path produces.
          seed: seed + proxies.size * 977,
        });
        proxies.set(key, p);
      }
      return p.port;
    },
    get count() {
      return proxies.size;
    },
    // ── Deliberately the same shape as startNetsim ────────────────────────────────────────
    // Both emulators are consumed by the same driver and written into the same `meta.json`, so
    // they present one interface: `stats`, `lateness()`, `queueDelay()`, `loopLag()`,
    // `expectedRttMs`, `stop()`. The alternative — branching on which emulator is running
    // everywhere a number is read — is how the two paths would quietly drift into reporting
    // subtly different things under the same field names, which is worse than either.
    get stats() {
      const t = { sent: 0, dropped: 0, bwDropped: 0, sendErrors: 0, unreachable: 0, errCodes: {}, bytes: 0, sizes: { tiny: 0, small: 0, mid: 0, full: 0 } };
      for (const p of proxies.values()) {
        for (const k of Object.keys(t.sizes)) t.sizes[k] += p.stats.sizes?.[k] ?? 0;
        t.sent += p.stats.sent;
        t.dropped += p.stats.dropped;
        t.bwDropped += p.stats.bwDropped;
        t.sendErrors += p.stats.sendErrors;
        t.unreachable += p.stats.unreachable;
        for (const [k, v] of Object.entries(p.stats.errCodes)) t.errCodes[k] = (t.errCodes[k] || 0) + v;
        t.bytes += p.stats.bytes;
      }
      return t;
    },
    /** Pooled percentiles across every direction's proxy. */
    pct(field) {
      const xs = [];
      for (const p of proxies.values()) xs.push(...p.stats[field]);
      if (!xs.length) return null;
      xs.sort((a, b) => a - b);
      const at = (q) => xs[Math.min(xs.length - 1, Math.floor((q / 100) * xs.length))];
      return {
        n: xs.length,
        p50: +at(50).toFixed(1),
        p95: +at(95).toFixed(1),
        p99: +at(99).toFixed(1),
        max: +xs[xs.length - 1].toFixed(1),
      };
    },
    lateness() {
      return this.pct('lateMs');
    },
    queueDelay() {
      return this.pct('queueMs');
    },
    loopLag() {
      return this.pct('lagMs');
    },
    // No relay in this topology. Reported as null rather than omitted so a run log can state
    // plainly that there was no TURN server, instead of printing `undefined`.
    turnPort: null,
    proxyPort: null,
    iceServers: null,
    // One crossing each way, so the round trip is two.
    expectedRttMs: oneWayMs * 2,
    // Change loss mid-call on every live crossing at once.
    setLoss(pct) {
      for (const p of proxies.values()) p.setLoss(pct);
      return proxies.size;
    },
    stop() {
      for (const p of proxies.values()) p.close();
      proxies.clear();
    },
  };
}

/**
 * Start a TURN relay with a delay line in front of it.
 *
 * `oneWayMs` is the delay the caller wants between the two browsers. A packet crosses the
 * proxy twice on its way across (client → relay, relay → client), so the proxy is
 * configured with half of it, and `expectedRttMs` reports what ICE should therefore
 * measure. If the measured RTT disagrees with that number, something is wrong with the
 * emulator rather than with the app — which is the whole reason to state it up front.
 */
export async function startNetsim({
  oneWayMs = 0,
  jitterMs = 0,
  lossPct = 0,
  seed = 1,
  user = 'bot',
  pass = 'botpass',
  // node-turn ignores a request for port 0 and falls back to its default, so an explicit
  // port is the only way to run two simulators side by side.
  turnPort: wantPort = 3478,
  // 0 means no ceiling — the previous behaviour, kept as the default so existing results stay
  // reproducible rather than silently reinterpreted under a constraint they never ran with.
  bwMbps = 0,
  queueMs = 100,
}) {
  const turn = new TurnServer({
    authMech: 'long-term',
    credentials: { [user]: pass },
    listeningIps: ['127.0.0.1'],
    listeningPort: wantPort,
    // Keep the relay on loopback: the delay is supposed to come from the proxy alone, so
    // that the emulated distance is a number we set rather than a number we inherit.
    relayIps: ['127.0.0.1'],
    debugLevel: 'ERROR',
  });
  turn.start();
  // `start()` binds asynchronously and returns immediately, so the socket exists before it
  // has an address. Poll for it rather than sleeping a guessed interval.
  let turnPort = null;
  for (let i = 0; i < 100 && turnPort == null; i++) {
    try {
      turnPort = turn.network?.sockets?.[0]?.address?.().port ?? null;
    } catch {
      turnPort = null; // EBADF until the bind completes
    }
    if (turnPort == null) await new Promise((r) => setTimeout(r, 20));
  }
  if (!turnPort) throw new Error('TURN server never bound a port');

  // ── Loss is requested end-to-end and applied per crossing ──────────────────────────────
  // Forcing `iceTransportPolicy: 'relay'` means a packet from A to B is drawn against the loss
  // dice twice: once when A's datagram reaches the proxy on its way to the TURN server, and
  // again when the relayed copy comes back out of TURN toward B. So a naive `lossPct` of 1
  // delivers 1 - 0.99² = 1.99% end-to-end — the emulator was quietly injecting twice what the
  // caller asked for, which makes every loss result look about twice as bad as the condition
  // being claimed. Invert it, so the number in the run label is the number the peers actually
  // experience.
  //
  // Two crossings is the right number and is confirmed twice over: the delay model derives RTT as
  // four crossings and ICE measured 80.0 ms against 80 ms set. It does *not* fully account for
  // app-level loss, which comes in about 2.5x the label rather than 1x — roughly half the measured
  // loss is excess. MTU fragmentation was the obvious candidate and was tested and refuted
  // (DESIGN.md §19); the residual is most likely usrsctp shedding from its own buffers once its
  // window has collapsed, which is a property of the transport under test rather than of this
  // emulator. So the knob is honest about what it *injects*, and app-level loss is reported
  // separately and is the number any result should be regressed against.
  const crossings = 2;
  const perCrossingPct = lossPct > 0 ? (1 - Math.pow(1 - lossPct / 100, 1 / crossings)) * 100 : 0;

  const proxy = await delayProxy({
    upstreamPort: turnPort,
    delayMs: oneWayMs / 2,
    jitterMs: jitterMs / 2,
    lossPct: perCrossingPct,
    seed,
    // Unlike loss, the bandwidth ceiling is NOT divided across the two crossings. Loss
    // compounds — two independent 1% draws give 1.99% end-to-end — but capacity does not: a
    // packet crossing two 5 Mbps hops in series still experiences a 5 Mbps path, and halving
    // the number here would emulate a 2.5 Mbps link while the run label said 5. The queue,
    // however, is genuinely traversed twice, so the delay it contributes does add up, which is
    // why queueDelay is reported rather than assumed.
    bwMbps,
    queueMs,
  });

  return {
    turnPort,
    proxyPort: proxy.port,
    stats: proxy.stats,
    // What was asked for end-to-end, and what each crossing actually applies to achieve it.
    lossPct,
    perCrossingLossPct: +perCrossingPct.toFixed(4),
    // The delay line's own steadiness, for the caller's validity check. `p95` is the number
    // that matters: it is how far off the emulated distance actually was, in ms, for the
    // worst one packet in twenty.
    loopLag: () => {
      const xs = [...proxy.stats.lagMs].sort((a, b) => a - b);
      if (!xs.length) return null;
      const at = (p) => xs[Math.min(xs.length - 1, Math.floor((p / 100) * xs.length))];
      return { n: xs.length, p50: +at(50).toFixed(1), p95: +at(95).toFixed(1), max: +xs[xs.length - 1].toFixed(1) };
    },
    // How late real datagrams actually left, sampled 1 in 64. Unlike loopLag this cannot miss a
    // stall by falling between samples, because it rides on the traffic itself: if the delay line
    // held a packet 300 ms longer than promised, a p99 here says so.
    lateness: () => {
      const xs = [...proxy.stats.lateMs].sort((a, b) => a - b);
      if (!xs.length) return null;
      const at = (p) => xs[Math.min(xs.length - 1, Math.floor((p / 100) * xs.length))];
      return {
        n: xs.length,
        p50: +at(50).toFixed(1),
        p95: +at(95).toFixed(1),
        p99: +at(99).toFixed(1),
        max: +xs[xs.length - 1].toFixed(1),
      };
    },
    // How long packets actually sat waiting for the narrow link. This is the bufferbloat the
    // bottleneck produced, and it is the output of the experiment rather than a health check:
    // a well-behaved sender keeps this near zero by backing off, and a sender that ignores the
    // ceiling shows up here as hundreds of milliseconds of queue that the far end's playout
    // buffer then has to absorb. `max` matters as much as `p95` — one 400 ms queueing event is
    // a freeze the viewer sees.
    queueDelay: () => {
      const xs = [...proxy.stats.queueMs].sort((a, b) => a - b);
      if (!xs.length) return null;
      const at = (p) => xs[Math.min(xs.length - 1, Math.floor((p / 100) * xs.length))];
      return {
        n: xs.length,
        p50: +at(50).toFixed(1),
        p95: +at(95).toFixed(1),
        p99: +at(99).toFixed(1),
        max: +xs[xs.length - 1].toFixed(1),
      };
    },
    // What ICE should measure: the round trip is four proxy crossings.
    expectedRttMs: oneWayMs * 2,
    iceServers: [{ urls: `turn:127.0.0.1:${proxy.port}?transport=udp`, username: user, credential: pass }],
    stop: () => {
      proxy.close();
      try {
        turn.stop();
      } catch {
        /* node-turn throws if already down; nothing to do about it */
      }
    },
  };
}

// Run directly to check the relay works at all before trusting it in a call.
// Compared through fileURLToPath rather than by string: this repository's path contains a
// space, so `file://${process.argv[1]}` and `import.meta.url` differ by percent-encoding and
// the guard silently never fires — the script exits 0 having done nothing.
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const oneWay = Number(process.argv[2] ?? 40);
  const sim = await startNetsim({ oneWayMs: oneWay, jitterMs: 5, lossPct: 0 });
  console.log(`TURN on 127.0.0.1:${sim.turnPort}, delay proxy on 127.0.0.1:${sim.proxyPort}`);
  console.log(`one-way ${oneWay} ms → ICE should measure about ${sim.expectedRttMs} ms`);
  console.log(JSON.stringify(sim.iceServers, null, 1));
  // A bare STUN Binding request through the proxy is enough to prove the path carries UDP
  // and to time it, without needing a browser.
  const sock = dgram.createSocket('udp4');
  const tid = Buffer.alloc(12);
  for (let i = 0; i < 12; i++) tid[i] = i + 1;
  const req = Buffer.concat([Buffer.from([0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xa4, 0x42]), tid]);
  const t0 = performance.now();
  sock.on('message', (m) => {
    const rtt = performance.now() - t0;
    const type = m.readUInt16BE(0);
    console.log(`\nSTUN reply type 0x${type.toString(16)} in ${rtt.toFixed(1)} ms` +
      `   (expected about ${oneWay} ms for one crossing each way)`);
    sock.close();
    sim.stop();
    process.exit(0);
  });
  sock.send(req, sim.proxyPort, '127.0.0.1');
  setTimeout(() => {
    console.log('\nno STUN reply — the relay path is not carrying UDP');
    sim.stop();
    process.exit(1);
  }, 3000);
}
