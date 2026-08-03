/* SCTP wall probe — standalone, one page, loopback pc pair.
 *
 * Why this exists (DESIGN.md §17.11): Lane A's 125 pps of 1.2 KB unreliable/
 * unordered datagrams collapses at RTT 80 / 1% loss (~1.2 Mbps carried) on a
 * path that carried ~14.5 Mbps when the bytes rode as ~37 KB video units. The
 * wall is shape-dependent and nobody has opened the SCTP stack. This probe
 * sends synthetic traffic of configurable shape across a REAL pc pair whose
 * candidates the driver (testbed/sctpwall.mjs) rewrites onto delay/loss
 * proxies, exactly the way call.mjs --p2psim does. No app code is touched;
 * nothing here ships.
 *
 * One page holds both ends. That is deliberate: the delay/loss lives in the
 * proxies (one per direction, one crossing each way), so the transport physics
 * is identical to two browsers, and the send/receive clocks are the same
 * clock — age = recvTs - sendTs with zero clock-offset estimation.
 *
 * Query params (all optional):
 *   size    payload bytes per message, INCLUDING the 16 B header (def 1168)
 *   pps     messages per second, float ok (def 200)
 *   pace    'even' (def) | 'burst' — burst sends `burstn` back-to-back then waits
 *   burstn  clump size for pace=burst (def 4)
 *   dur     measurement window ms (def 12000)
 *   warmup  ms of traffic before the window opens (def 2500)
 *   gate    bufferedAmount gate in bytes; 0 = no gate (def 0). Messages that
 *           would exceed the gate are dropped at the sender and counted —
 *           Lane A's gate semantics (drop, never queue).
 *   slack   ms after window close to wait for stragglers (def 2500)
 *
 * Result: window.__result (object) and window.__done = true when finished.
 */
(async () => {
  const out = (s) => {
    const el = document.getElementById('out');
    if (el) el.textContent += '\n' + s;
    console.log('[probe]', s);
  };
  const P = new URLSearchParams(location.search);
  const num = (k, d) => (P.has(k) ? Number(P.get(k)) : d);
  const SIZE = Math.max(16, num('size', 1168));
  const PPS = num('pps', 200);
  const PACE = P.get('pace') || 'even';
  const BURSTN = Math.max(1, num('burstn', 4));
  const DUR = num('dur', 12000);
  const WARM = num('warmup', 2500);
  const GATE = num('gate', 0);
  const SLACK = num('slack', 2500);
  // pairs=N: N independent loopback pc pairs (= N SCTP associations, each with
  // its own cwnd). Messages round-robin across associations, seq global — the
  // striping lever. N=1 is the baseline.
  const PAIRS = Math.max(1, num('pairs', 1));

  const MAGIC = 0x53435050; // 'SCPP'
  const PING_MAGIC = 0x50494e47; // 'PING'

  const t0 = performance.now();
  const result = {
    params: { size: SIZE, pps: PPS, pace: PACE, burstn: BURSTN, dur: DUR, warmup: WARM, gate: GATE, pairs: PAIRS },
    rewrites: null,
  };
  const fail = (why) => {
    result.error = why;
    window.__result = result;
    window.__done = true;
    out('FAILED: ' + why);
  };

  try {
    // ── The loopback pair(s) ─────────────────────────────────────────────────
    // No iceServers: host candidates only, which is all the driver's proxies
    // front. The init script (P2P_REWRITE, same string call.mjs injects) has
    // already patched RTCPeerConnection so every remote candidate is swapped
    // for a delay-proxy port before the stack ever sees the real one.
    //
    // Each pair is a full SCTP association with its OWN congestion window —
    // that independence is the whole point of the pairs=N striping arm.
    const rx = { msgs: 0, bytes: 0, ages: [], seqs: new Set(), perSec: new Map(), maxSeq: -1 };
    const pairs = [];
    for (let i = 0; i < PAIRS; i++) {
      const pcA = new RTCPeerConnection({ iceServers: [] });
      const pcB = new RTCPeerConnection({ iceServers: [] });
      pcA.onicecandidate = (e) => { if (e.candidate) pcB.addIceCandidate(e.candidate); };
      pcB.onicecandidate = (e) => { if (e.candidate) pcA.addIceCandidate(e.candidate); };

      // Bulk: the lane under test. Unreliable + unordered, maxRetransmits 0 —
      // the law's datagram semantics, identical to Lane A's pcm-audio channel.
      const dc = pcA.createDataChannel('bulk', { ordered: false, maxRetransmits: 0 });
      dc.binaryType = 'arraybuffer';
      // Ping: same association (SCTP has one cwnd per association — the ping
      // shares the bulk stream's fate, which is exactly what pcm-loss4's ping
      // measured), tiny, echoed by the far end. Its RTT reads the SCTP-level
      // queue that bufferedAmount cannot see.
      const dcPing = pcA.createDataChannel('ping', { ordered: false, maxRetransmits: 0 });
      dcPing.binaryType = 'arraybuffer';

      pcB.ondatachannel = (e) => {
        const c = e.channel;
        c.binaryType = 'arraybuffer';
        if (c.label === 'ping') {
          c.onmessage = (m) => { c.send(m.data); }; // echo, same association
          return;
        }
        c.onmessage = (m) => {
          const now = performance.now();
          const dv = new DataView(m.data);
          if (dv.getUint32(0) !== MAGIC) return;
          const seq = dv.getUint32(4);
          const ts = dv.getFloat64(8);
          rx.msgs++;
          rx.bytes += m.data.byteLength;
          rx.ages.push(now - ts);
          rx.seqs.add(seq);
          if (seq > rx.maxSeq) rx.maxSeq = seq;
          const sec = Math.floor((now - t0) / 1000);
          rx.perSec.set(sec, (rx.perSec.get(sec) || 0) + m.data.byteLength);
        };
      };
      pairs.push({ pcA, pcB, dc, dcPing });
    }

    // ── Connect all pairs ────────────────────────────────────────────────────
    for (const { pcA, pcB } of pairs) {
      const offer = await pcA.createOffer();
      await pcA.setLocalDescription(offer);
      await pcB.setRemoteDescription(offer);
      const answer = await pcB.createAnswer();
      await pcB.setLocalDescription(answer);
      await pcA.setRemoteDescription(answer);
    }

    const opened = await Promise.race([
      Promise.all(
        pairs.flatMap(({ dc, dcPing }) => [
          new Promise((r) => (dc.onopen = () => r(true))),
          new Promise((r) => (dcPing.onopen = () => r(true))),
        ]),
      ).then(() => true),
      new Promise((r) => setTimeout(() => r(false), 30000)),
    ]);
    if (!opened) return fail('datachannels never opened (30 s)');
    result.connectedMs = +(performance.now() - t0).toFixed(0);
    out(`connected in ${result.connectedMs} ms; size=${SIZE} pps=${PPS} pace=${PACE}` +
        ` offered=${((SIZE * PPS * 8) / 1e6).toFixed(2)} Mbps payload`);

    // ── getStats sampler (sender side of every pair) ─────────────────────────
    // candidate-pair bytes are the wire: SCTP+DTLS wrapped, at the ICE layer.
    // That is the number to hold against §17.11's 1.98 Mbps. Keyed by stats
    // object id so an ICE re-nomination (bytes reset on the new pair) cannot
    // produce a negative delta.
    const statByPair = new Map(); // `${pairIdx}:${statId}` → [{t, bytesSent, rtt}]
    const statTimer = setInterval(async () => {
      for (let pi = 0; pi < pairs.length; pi++) {
        try {
          const st = await pairs[pi].pcA.getStats();
          for (const r of st.values()) {
            if (r.type === 'candidate-pair' && r.nominated) {
              const key = `${pi}:${r.id}`;
              const arr = statByPair.get(key) || [];
              arr.push({ t: performance.now() - t0, bytesSent: r.bytesSent || 0, rtt: (r.currentRoundTripTime || 0) * 1000 });
              statByPair.set(key, arr);
            }
          }
        } catch { /* pc closing */ }
      }
    }, 1000);

    // ── Sender ───────────────────────────────────────────────────────────────
    const buf = new Uint8Array(SIZE);
    for (let i = 16; i < SIZE; i++) buf[i] = (i * 2654435761) >>> 24; // stable filler
    const dv = new DataView(buf.buffer);
    dv.setUint32(0, MAGIC);

    const interval = 1000 / PPS; // ms per message, float
    const sendTs = [];           // actual send time per seq (pacing fidelity + windowing)
    const bufAmt = [];           // bufferedAmount samples
    let sent = 0, gated = 0, sendErr = 0;
    const sendStart = performance.now();
    const sendEnd = sendStart + WARM + DUR;

    // Round-robin across associations: frame k rides pair k % PAIRS. Every
    // frame still leaves at its own capture tick — striping adds zero delay.
    const sendOne = (seq, now) => {
      const { dc } = pairs[seq % PAIRS];
      dv.setUint32(4, seq);
      dv.setFloat64(8, now);
      if (GATE && dc.bufferedAmount > GATE) { gated++; return; }
      try {
        dc.send(buf);
        sendTs[seq] = now;
        sent++;
      } catch { sendErr++; }
      bufAmt.push(dc.bufferedAmount);
    };

    await new Promise((done) => {
      if (PACE === 'burst') {
        // burstn messages back-to-back, then silence until the next clump's
        // deadline — the shape a capture tick produces when frames clump.
        let clump = 0;
        let next = sendStart;
        const tick = () => {
          const now = performance.now();
          if (now >= sendEnd) return done();
          if (now >= next) {
            for (let k = 0; k < BURSTN; k++) sendOne(clump * BURSTN + k, performance.now());
            clump++;
            next = sendStart + clump * BURSTN * interval;
          }
          setTimeout(tick, Math.max(0.25, Math.min(4, next - performance.now() - 1)));
        };
        tick();
      } else {
        // even: deadline scheduler, catch-up inside a tick, no drift
        let seq = 0;
        let next = sendStart;
        const tick = () => {
          let now = performance.now();
          if (now >= sendEnd) return done();
          let n = 0;
          while (now >= next && n < 2000) { // 2000 = runaway guard only
            sendOne(seq++, now);
            next = sendStart + seq * interval;
            n++;
            now = performance.now();
          }
          setTimeout(tick, Math.max(0.25, Math.min(4, next - now - 1)));
        };
        tick();
      }
    });

    // ── Ping loop on pair 0 (runs through warmup+window+slack) ───────────────
    const pings = []; // rtt ms
    const dcPing0 = pairs[0].dcPing;
    const pingTimer = setInterval(() => {
      if (dcPing0.readyState !== 'open') return;
      const b = new ArrayBuffer(16);
      const d = new DataView(b);
      d.setUint32(0, PING_MAGIC);
      d.setFloat64(8, performance.now());
      try { dcPing0.send(b); } catch { /* closing */ }
    }, 250);
    dcPing0.onmessage = (m) => {
      const d = new DataView(m.data);
      if (d.getUint32(0) === PING_MAGIC) pings.push(performance.now() - d.getFloat64(8));
    };

    // ── Settle, then account ─────────────────────────────────────────────────
    await new Promise((r) => setTimeout(r, SLACK));
    clearInterval(pingTimer);
    clearInterval(statTimer);

    const w0 = sendStart + WARM, w1 = w0 + DUR;
    let sentWin = 0, sentWinBytes = 0;
    const gaps = [];
    for (let i = 0; i < sendTs.length; i++) {
      const t = sendTs[i];
      if (t === undefined) continue;
      if (t >= w0 && t < w1) { sentWin++; sentWinBytes += SIZE; }
      if (i > 0 && sendTs[i - 1] !== undefined) gaps.push(t - sendTs[i - 1]);
    }
    // Received messages whose sendTs falls in the window: ages and seqs are
    // parallel arrays of every arrival, so re-walk them with the send clock.
    let recvWin = 0, recvWinBytes = 0, lateWin = 0;
    const agesWin = [];
    // rx.ages/rx.seqs don't carry sendTs; recompute from what we kept. We kept
    // only (age, seq) — age + recv order is not enough, so recompute window
    // membership from seq: seqs in window = seq whose sendTs in [w0,w1).
    const seqInWin = (s) => sendTs[s] !== undefined && sendTs[s] >= w0 && sendTs[s] < w1;
    for (const s of rx.seqs) if (seqInWin(s)) recvWin++;
    recvWinBytes = recvWin * SIZE;
    // ages: we stored arrival ages in arrival order; for windowed percentiles
    // we accept all arrivals — at 80 ms RTT the window edges move the
    // percentile by <1%.
    for (const a of rx.ages) agesWin.push(a);
    const lost = Math.max(0, sentWin - recvWin);

    const pct = (xs, q) => {
      if (!xs.length) return null;
      const s = [...xs].sort((a, b) => a - b);
      return +s[Math.min(s.length - 1, Math.floor((q / 100) * s.length))].toFixed(1);
    };

    // Wire rate: per candidate-pair stat object (re-nomination-safe), summed
    // across striped pairs, over the measurement window.
    let wireSentMbps = null, iceRttLast = null;
    {
      let bytes = 0, dtMax = 0;
      const rtls = [];
      for (const arr of statByPair.values()) {
        const inWin = arr.filter((s) => s.t >= WARM && s.t <= WARM + DUR);
        if (inWin.length >= 2) {
          bytes += inWin[inWin.length - 1].bytesSent - inWin[0].bytesSent;
          dtMax = Math.max(dtMax, (inWin[inWin.length - 1].t - inWin[0].t) / 1000);
          rtls.push(inWin[inWin.length - 1].rtt);
        }
      }
      if (dtMax > 0) wireSentMbps = +(((bytes * 8) / dtMax) / 1e6).toFixed(3);
      if (rtls.length) iceRttLast = +rtls[0].toFixed(1);
    }

    // Per-second carried payload Mbps over the window (collapse dynamics).
    const perSecond = [];
    for (let sec = Math.floor((w0 - t0) / 1000); sec < Math.floor((w1 - t0) / 1000); sec++) {
      perSecond.push(+(((rx.perSec.get(sec) || 0) * 8) / 1e6).toFixed(3));
    }

    Object.assign(result, {
      rewrites: (window.__rewrites || []).length,
      sentWin, recvWin, lost, gated, sendErr,
      lostPct: sentWin ? +((100 * lost) / sentWin).toFixed(2) : null,
      offeredPayloadMbps: +((SIZE * PPS * 8) / 1e6).toFixed(3),
      carriedPayloadMbps: +((recvWinBytes * 8) / (DUR / 1000) / 1e6).toFixed(3),
      sentPayloadMbps: +((sentWinBytes * 8) / (DUR / 1000) / 1e6).toFixed(3),
      wireSentMbps, iceRttLast,
      ageP50: pct(agesWin, 50), ageP95: pct(agesWin, 95),
      ageP99: pct(agesWin, 99), ageMax: agesWin.length ? +Math.max(...agesWin).toFixed(1) : null,
      pingP50: pct(pings, 50), pingP95: pct(pings, 95),
      pingMax: pings.length ? +Math.max(...pings).toFixed(1) : null, pingN: pings.length,
      bufP50: pct(bufAmt, 50), bufP95: pct(bufAmt, 95),
      bufMax: bufAmt.length ? Math.max(...bufAmt) : null,
      gapP50: pct(gaps, 50), gapP95: pct(gaps, 95),
      perSecond,
    });
    window.__result = result;
    window.__done = true;
    out(`done: sent ${sentWin} recv ${recvWin} lost ${lost} gated ${gated} | carried ` +
        `${result.carriedPayloadMbps} Mbps payload, wire ${wireSentMbps} | age p50 ${result.ageP50} ` +
        `p95 ${result.ageP95} | ping p50 ${result.pingP50} max ${result.pingMax} | buf p95 ${result.bufP95}`);
    for (const { pcA, pcB } of pairs) { pcA.close(); pcB.close(); }
  } catch (e) {
    fail(String(e && e.stack || e).slice(0, 400));
  }
})();
