// Phase 1 transport harness.
//
// Question under test: can an unordered/unreliable RTCDataChannel sustain
// 12 Mbps at realistic RTT, with our pacer — not usrsctp's congestion window —
// as the binding controller?
//
// Nothing here touches a camera. If this fails, no amount of media pipeline
// saves it, which is why it's phase 1.

import { Collector, Chart, BUCKET_MS } from './stats.js';

// Sized so one datagram is one SCTP message with no fragmentation:
// ~1200 B path MTU minus DTLS and SCTP overhead. DESIGN.md §9.
// ── Message size and the MTU cliff ──────────────────────────────────────────────────────────
// Settable from the URL because it is not a free parameter: it decides whether one application
// message becomes one datagram or two.
//
// 1150 bytes of payload plus a 16-byte SCTP DATA header, DTLS record and auth overhead, TURN
// ChannelData framing and IP/UDP lands within a few dozen bytes of the ~1200-byte SCTP path MTU.
// Over that line SCTP fragments the message, and under `maxRetransmits: 0` losing *either*
// fragment discards the whole reassembled message — so message loss becomes roughly twice
// datagram loss. That is not a subtle effect: measured app-level loss came to about 4.3 delay-line
// crossings' worth when the delay model says a one-way trip crosses twice, and ICE agreed with
// the delay model to 0.1 ms. The factor of two had to be somewhere, and this is it.
//
// Keep real payloads under one datagram for the same reason (§9): in unreliable mode, fragmenting
// a frame multiplies its loss probability by the fragment count.
const PKT_BYTES = Number(new URLSearchParams(location.search).get('pkt')) || 1150;
const HDR_BYTES = 16;

// usrsctp only grows its path MTU — and therefore its congestion window — if it
// sees reasonably large packets early. Open with a burst of full-size datagrams
// BEFORE any small control message touches the association, or PMTUD stalls and
// throughput is quietly capped for the whole session. This is the single easiest
// way to get a false FAIL out of this harness.
const WARMUP_MS = 1500;

const MAX_BUFFERED = 256 * 1024; // high on purpose: we want to observe pinning, not prevent it

const el = (id) => document.getElementById(id);
const log = (msg) => {
  const t = el('log');
  const line = `${new Date().toISOString().slice(11, 23)}  ${msg}\n`;
  t.textContent += line;
  t.scrollTop = t.scrollHeight;
};

// ── Pacer ────────────────────────────────────────────────────────────────────
// Token bucket driven by a MessageChannel loop rather than setTimeout, because
// setTimeout clamps to 4 ms once nested and we need ~1300 packets/sec. When we
// are ahead of schedule we hand time back with a real timer so this doesn't peg
// a core and distort the very measurements it exists to produce.
class Pacer {
  constructor(dc, onSent, onError) {
    this.dc = dc;
    this.onSent = onSent;
    this.onError = onError;
    this.seq = 0;
    this.bps = 0;
    this.running = false;
    this.tokens = 0;
    this.sendErrors = 0;

    this.buf = new ArrayBuffer(PKT_BYTES);
    this.dv = new DataView(this.buf);
    // Fill the payload once. SCTP doesn't compress, so contents are irrelevant
    // to throughput — but a fixed buffer keeps allocation out of the hot loop.
    const bytes = new Uint8Array(this.buf);
    for (let i = HDR_BYTES; i < PKT_BYTES; i++) bytes[i] = i & 0xff;

    const ch = new MessageChannel();
    ch.port1.onmessage = () => this.tick();
    this.wake = () => ch.port2.postMessage(0);
  }

  setRate(bps) {
    this.bps = bps;
  }

  start(bps) {
    this.bps = bps;
    this.tokens = 0;
    this.last = performance.now();
    this.running = true;
    this.wake();
  }

  stop() {
    this.running = false;
  }

  tick() {
    if (!this.running) return;
    const now = performance.now();
    const dt = now - this.last;
    this.last = now;

    const bytesPerSec = this.bps / 8;
    this.tokens += bytesPerSec * (dt / 1000);
    // Cap the burst so a scheduling hiccup doesn't turn into a 64-packet spike.
    const cap = PKT_BYTES * 64;
    if (this.tokens > cap) this.tokens = cap;

    let blocked = false;
    while (this.tokens >= PKT_BYTES) {
      if (this.dc.bufferedAmount > MAX_BUFFERED) {
        blocked = true;
        break;
      }
      this.dv.setUint32(0, this.seq++);
      this.dv.setFloat64(4, performance.now());
      this.dv.setUint32(12, (this.bps / 1000) | 0);
      try {
        this.dc.send(this.buf);
        this.onSent(PKT_BYTES);
      } catch (e) {
        this.sendErrors++;
        if (this.sendErrors < 5) this.onError(e);
        blocked = true;
        break;
      }
      this.tokens -= PKT_BYTES;
    }

    if (!this.running) return;
    if (blocked) {
      setTimeout(this.wake, 2);
      return;
    }
    // Ahead of schedule → sleep the exact deficit rather than spinning.
    const need = PKT_BYTES - this.tokens;
    const waitMs = need > 0 ? (need / bytesPerSec) * 1000 : 0;
    if (waitMs > 1.5) setTimeout(this.wake, Math.floor(waitMs));
    else this.wake();
  }
}

// ── Harness ──────────────────────────────────────────────────────────────────
class Harness {
  constructor() {
    this.ws = null;
    this.pc = null;
    this.bulk = null;
    this.ctrl = null;
    this.role = null;
    this.pacer = null;
    this.collector = new Collector();
    this.chart = new Chart(el('chart'));
    this.chart.legend(el('legend'));

    // Clock sync state
    this.clockOffset = 0;
    this.rttSamples = [];
    this.pingTimer = null;

    this.running = false;
    this.testMeta = null;
    this.peerReport = null;
    this.recvBytesTotal = 0;

    // A hidden tab has its timers clamped to ~1 s and rAF stopped, which breaks
    // the pacer and the bucket sampler alike. Two side-by-side browser WINDOWS
    // are fine; two tabs in one window are not, because only one is visible.
    this.hiddenDuringTest = false;
    document.addEventListener('visibilitychange', () => {
      if (document.hidden && this.running) {
        this.hiddenDuringTest = true;
        log('WARNING: tab hidden mid-test — timers throttled, these numbers are invalid');
      }
    });
    if (document.hidden) log('WARNING: this tab is hidden — bring it to the front before testing');
  }

  // ── Signaling ──────────────────────────────────────────────────────────────
  async join(code, policy) {
    const iceRes = await fetch('/api/ice').then((r) => r.json());
    this.iceInfo = iceRes;
    if (iceRes.p2pOnly) {
      log(`TURN unavailable (${iceRes.reason}) — P2P/STUN only`);
      if (policy === 'relay') {
        log('WARNING: relay policy requested but no TURN configured; ICE will fail');
      }
    } else {
      log(`TURN credentials minted (${(iceRes.iceServers || []).length} servers)`);
    }

    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    this.ws = new WebSocket(`${proto}//${location.host}/api/room/${code}/ws`);

    this.ws.onmessage = (ev) => this.onSignal(JSON.parse(ev.data));
    this.ws.onclose = () => log('signaling closed');
    this.ws.onerror = () => log('signaling error');
    await new Promise((res, rej) => {
      this.ws.onopen = res;
      this.ws.addEventListener('error', rej, { once: true });
    });

    this.policy = policy;
    log(`joined room "${code}" (iceTransportPolicy=${policy})`);
  }

  send(msg) {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(msg));
  }

  async onSignal(msg) {
    switch (msg.type) {
      case 'welcome':
        this.role = msg.role;
        el('role').value = this.role === 'a' ? 'A (offerer)' : 'B (answerer)';
        log(`role = ${this.role}${msg.peerPresent ? ', peer already here' : ', waiting for peer'}`);
        this.setupPc();
        // Covers the reload case: if the peer was already waiting when we
        // arrived, no 'peer-joined' is coming and 'a' must offer immediately.
        if (msg.peerPresent && this.role === 'a') await this.makeOffer();
        break;

      case 'peer-joined':
        log('peer joined');
        if (this.role === 'a') await this.makeOffer();
        break;

      case 'offer': {
        await this.pc.setRemoteDescription(msg.sdp);
        const answer = await this.pc.createAnswer();
        await this.pc.setLocalDescription(answer);
        this.send({ type: 'answer', sdp: this.pc.localDescription });
        log('sent answer');
        break;
      }

      case 'answer':
        await this.pc.setRemoteDescription(msg.sdp);
        log('got answer');
        break;

      case 'ice':
        try {
          await this.pc.addIceCandidate(msg.candidate);
        } catch (e) {
          log(`addIceCandidate failed: ${e.message}`);
        }
        break;

      case 'peer-left':
        log('peer left');
        this.setStatus('peer left');
        break;
    }
  }

  async makeOffer() {
    const offer = await this.pc.createOffer();
    await this.pc.setLocalDescription(offer);
    this.send({ type: 'offer', sdp: this.pc.localDescription });
    log('sent offer');
  }

  // ── PeerConnection ─────────────────────────────────────────────────────────
  setupPc() {
    this.pc = new RTCPeerConnection({
      iceServers: this.iceInfo.iceServers || [],
      iceTransportPolicy: this.policy,
      bundlePolicy: 'max-bundle',
    });

    this.pc.onicecandidate = (e) => {
      if (e.candidate) this.send({ type: 'ice', candidate: e.candidate });
    };
    this.pc.oniceconnectionstatechange = () => {
      log(`ICE: ${this.pc.iceConnectionState}`);
      this.setStatus(this.pc.iceConnectionState);
    };

    if (this.role === 'a') {
      // The channel under test. `ordered:false, maxRetransmits:0` is the whole
      // point: we want raw datagrams, and we do our own ARQ with our own
      // deadlines (DESIGN.md §11). SCTP still runs its own congestion control,
      // which is exactly the risk this harness measures.
      this.bulk = this.pc.createDataChannel('bulk', {
        ordered: false,
        maxRetransmits: 0,
      });
      this.ctrl = this.pc.createDataChannel('ctrl', { ordered: true });
      this.wireChannels();
    } else {
      this.pc.ondatachannel = (e) => {
        if (e.channel.label === 'bulk') this.bulk = e.channel;
        else this.ctrl = e.channel;
        if (this.bulk && this.ctrl) this.wireChannels();
      };
    }
  }

  wireChannels() {
    this.bulk.binaryType = 'arraybuffer';
    this.bulk.bufferedAmountLowThreshold = 64 * 1024;
    this.bulk.onmessage = (e) => this.onBulk(e.data);
    this.bulk.onopen = () => {
      log('bulk channel open');
      this.maybeReady();
    };
    this.ctrl.onmessage = (e) => this.onCtrl(JSON.parse(e.data));
    this.ctrl.onopen = () => {
      log('ctrl channel open');
      this.maybeReady();
    };
    if (this.bulk.readyState === 'open' && this.ctrl.readyState === 'open') this.maybeReady();
  }

  async maybeReady() {
    if (this.bulk?.readyState !== 'open' || this.ctrl?.readyState !== 'open') return;
    if (this.ready) return;
    this.ready = true;

    await this.pollIce();
    log(`path = ${this.collector.pathType}, ICE RTT = ${this.collector.iceRtt ?? '?'} ms`);
    this.setStatus(`connected via ${this.collector.pathType}`);

    // PMTUD warm-up must precede clock-sync pings — see WARMUP_MS above.
    await this.warmup();
    this.startClockSync();

    el('start').disabled = this.role !== 'a';
    if (this.role === 'a') log('ready — press Start');
    else log('ready — waiting for A to start');
  }

  async warmup() {
    log(`PMTUD warm-up: ${WARMUP_MS} ms of full-size datagrams`);
    const buf = new ArrayBuffer(PKT_BYTES);
    const t0 = performance.now();
    let n = 0;
    while (performance.now() - t0 < WARMUP_MS) {
      // Fill the send buffer in a burst each tick rather than one datagram per
      // tick. A hidden tab clamps setTimeout to ~1 s, so a per-tick-per-packet
      // loop sends single-digit datagrams and silently fails to move PMTUD —
      // which is the entire purpose of this function.
      while (this.bulk.bufferedAmount < 192 * 1024) {
        try {
          this.bulk.send(buf);
          n++;
        } catch {
          break;
        }
      }
      await new Promise((r) => setTimeout(r, 4));
    }
    log(`warm-up sent ${n} datagrams (${((n * PKT_BYTES) / 1e6).toFixed(1)} MB)`);
    if (n < 500) {
      log('WARNING: warm-up was throttled — PMTUD may not have advanced. Is this tab hidden?');
    }
  }

  // ── Clock sync ─────────────────────────────────────────────────────────────
  // NTP-style four-timestamp exchange, offset taken from the minimum-RTT sample
  // in a sliding window. Min-filtering rejects queueing delay far better than
  // averaging, which matters here because we are deliberately inducing queues.
  startClockSync() {
    const ping = () => {
      if (this.ctrl?.readyState === 'open') {
        this.ctrl.send(JSON.stringify({ type: 'ping', t1: performance.now() }));
      }
    };
    ping();
    this.pingTimer = setInterval(ping, 200);
  }

  onCtrl(msg) {
    switch (msg.type) {
      case 'ping':
        this.ctrl.send(JSON.stringify({ type: 'pong', t1: msg.t1, t2: performance.now() }));
        break;

      case 'pong': {
        const t3 = performance.now();
        const rtt = t3 - msg.t1;
        const offset = msg.t2 - (msg.t1 + t3) / 2;
        this.rttSamples.push({ rtt, offset });
        if (this.rttSamples.length > 25) this.rttSamples.shift();
        let best = this.rttSamples[0];
        for (const s of this.rttSamples) if (s.rtt < best.rtt) best = s;
        this.clockOffset = best.offset;
        el('ctrlRtt').textContent = `${best.rtt.toFixed(1)} ms`;
        break;
      }

      case 'start':
        this.beginLocal(msg.plan, msg.bidirectional, false);
        break;

      case 'stop':
        this.endLocal(false);
        break;

      case 'report':
        this.peerReport = msg.payload;
        log('received peer report');
        this.renderVerdict();
        break;
    }
  }

  // ── Receive path ───────────────────────────────────────────────────────────
  onBulk(data) {
    if (!this.running) return;
    const dv = new DataView(data);
    const seq = dv.getUint32(0);
    const sendTs = dv.getFloat64(4);
    // offset = peerClock - myClock, so the send instant in my clock is
    // sendTs - offset, and one-way delay is now - sendTs + offset.
    const owd = performance.now() - sendTs + this.clockOffset;
    this.recvBytesTotal += data.byteLength;
    this.collector.onRecv(seq, owd, data.byteLength);
  }

  // ── ICE stats ──────────────────────────────────────────────────────────────
  async pollIce() {
    if (!this.pc) return;
    const stats = await this.pc.getStats();
    let transport = null;
    const byId = new Map();
    stats.forEach((r) => {
      byId.set(r.id, r);
      if (r.type === 'transport') transport = r;
    });

    let pair = transport?.selectedCandidatePairId
      ? byId.get(transport.selectedCandidatePairId)
      : null;
    if (!pair) {
      stats.forEach((r) => {
        if (r.type === 'candidate-pair' && r.state === 'succeeded' && (r.selected || r.nominated)) {
          pair = r;
        }
      });
    }
    if (!pair) return;

    const local = byId.get(pair.localCandidateId);
    const remote = byId.get(pair.remoteCandidateId);
    const types = [local?.candidateType, remote?.candidateType];
    this.collector.pathType = types.includes('relay')
      ? 'RELAY (TURN)'
      : types.includes('srflx') || types.includes('prflx')
        ? 'P2P (srflx)'
        : 'P2P (host)';
    if (pair.currentRoundTripTime != null) {
      this.collector.iceRtt = +(pair.currentRoundTripTime * 1000).toFixed(1);
    }
    if (pair.availableOutgoingBitrate != null) {
      this.collector.availOutBps = pair.availableOutgoingBitrate;
    }

    el('path').textContent = this.collector.pathType;
    el('iceRtt').textContent = this.collector.iceRtt == null ? '—' : `${this.collector.iceRtt} ms`;
  }

  // ── Test driver ────────────────────────────────────────────────────────────
  buildPlan() {
    const mode = el('mode').value;
    const stepSec = +el('stepSec').value;
    if (mode === 'ramp') {
      // A ramp tells you *where* it breaks, which is far more useful than a
      // pass/fail at one rate. The gate is judged on the 12 Mbps step.
      return [4, 8, 12, 16, 20].map((mbps) => ({ mbps, ms: stepSec * 1000 }));
    }
    return [{ mbps: +el('targetMbps').value, ms: stepSec * 1000 }];
  }

  async start() {
    const plan = this.buildPlan();
    // Tell the collector how long this is meant to last, so the verdict can tell a finished run
    // from a connection that died mid-soak.
    this.collector.setPlan(plan.reduce((a, st) => a + st.ms, 0));
    const bidirectional = el('bidir').checked;
    this.ctrl.send(JSON.stringify({ type: 'start', plan, bidirectional }));
    this.beginLocal(plan, bidirectional, true);
  }

  beginLocal(plan, bidirectional, isDriver) {
    // In unidirectional mode only A transmits; both sides still measure receive.
    const shouldSend = bidirectional || this.role === 'a';

    this.collector.reset();
    this.collector.start();
    this.recvBytesTotal = 0;
    this.peerReport = null;
    this.running = true;
    this.isDriver = isDriver;
    this.testMeta = {
      plan,
      bidirectional,
      role: this.role,
      policy: this.policy,
      pktBytes: PKT_BYTES,
      startedAt: new Date().toISOString(),
      ua: navigator.userAgent,
      wasHidden: false, // filled in at endLocal
    };

    el('start').disabled = true;
    el('stop').disabled = false;
    el('verdict').innerHTML = '';
    log(`START ${bidirectional ? 'bidirectional' : 'A→B'} — plan: ${plan.map((s) => `${s.mbps}M/${s.ms / 1000}s`).join(' ')}`);

    if (shouldSend) {
      this.pacer = new Pacer(
        this.bulk,
        (b) => this.collector.onSent(b),
        (e) => log(`send error: ${e.message}`),
      );
      this.pacer.start(plan[0].mbps * 1e6);
    }

    this.sampleTimer = setInterval(() => this.sample(), 50);
    this.iceTimer = setInterval(() => this.pollIce(), 1000);
    this.renderTimer = setInterval(() => this.render(), 200);

    // Walk the plan.
    let i = 0;
    const advance = () => {
      if (!this.running) return;
      const step = plan[i];
      this.collector.markStep(`${step.mbps} Mbps`, step.mbps * 1e6);
      if (this.pacer) this.pacer.setRate(step.mbps * 1e6);
      el('curTarget').textContent = `${step.mbps} Mbps`;
      log(`step → ${step.mbps} Mbps for ${step.ms / 1000}s`);
      i++;
      if (i < plan.length) this.stepTimer = setTimeout(advance, step.ms);
      else this.stepTimer = setTimeout(() => this.finish(), step.ms);
    };
    advance();
  }

  sample() {
    this.collector.tick(performance.now(), this.bulk?.bufferedAmount ?? 0);
  }

  finish() {
    if (this.isDriver) {
      this.ctrl.send(JSON.stringify({ type: 'stop' }));
    }
    this.endLocal(this.isDriver);
  }

  stop() {
    this.finish();
  }

  endLocal(isDriver) {
    if (!this.running) return;
    this.running = false;
    this.pacer?.stop();
    clearInterval(this.sampleTimer);
    clearInterval(this.iceTimer);
    clearInterval(this.renderTimer);
    clearTimeout(this.stepTimer);
    this.collector.stop();

    el('start').disabled = this.role !== 'a';
    el('stop').disabled = true;
    log('STOP');

    this.render();

    this.testMeta.wasHidden = this.hiddenDuringTest || document.hidden;
    if (this.testMeta.wasHidden) {
      log('RESULTS INVALID: this tab was hidden during the test');
    }
    const payload = this.collector.toJSON(this.testMeta);
    if (!isDriver) {
      // Non-driver ships its receive-side view to the driver so one screen holds
      // both directions. The receiver's numbers are the ones that matter.
      this.ctrl.send(JSON.stringify({ type: 'report', payload }));
      log('sent report to A');
    }
    this.lastReport = payload;
    this.renderVerdict();
  }

  // ── Render ─────────────────────────────────────────────────────────────────
  render() {
    const rows = this.collector.rows();
    this.chart.draw(rows);
    const last = rows[rows.length - 1];
    if (last) {
      el('sentMbps').textContent = `${last.sentMbps.toFixed(2)}`;
      el('recvMbps').textContent = `${last.recvMbps.toFixed(2)}`;
      el('owd').textContent = last.owdP95 == null ? '—' : `${last.owdP95.toFixed(1)} ms`;
      el('buffered').textContent = last.bufP95KB == null ? '—' : `${last.bufP95KB.toFixed(0)} KB`;
    }
    el('loss').textContent = `${(this.collector.loss.lossRate * 100).toFixed(3)}%`;
    el('reordered').textContent = `${this.collector.loss.reordered}`;
  }

  renderVerdict() {
    const gateTarget = 12;
    const mine = this.collector.verdict(gateTarget, this.collector.iceRtt);
    const parts = [];

    const hidden = this.testMeta?.wasHidden || this.peerReport?.meta?.wasHidden;
    if (hidden) {
      parts.push(
        `<p class="bad"><b>RESULTS INVALID</b> — a tab was hidden during the test, so its timers were ` +
          `throttled to ~1 s. Put both peers in visible windows (or on two machines) and rerun.</p>`,
      );
    }

    const block = (title, v) => {
      if (v.ok === null) return `<div class="vblock"><h4>${title}</h4><p class="muted">${v.reason}</p></div>`;
      const rows = v.checks
        .map(
          (c) =>
            `<li class="${c.ok ? 'ok' : 'bad'}"><span>${c.ok ? 'PASS' : 'FAIL'}</span> ${c.name} <em>${c.got}</em></li>`,
        )
        .join('');
      return `<div class="vblock"><h4>${title} — <b class="${v.ok ? 'ok' : 'bad'}">${v.ok ? 'PASS' : 'FAIL'}</b></h4><ul>${rows}</ul></div>`;
    };

    parts.push(block(`This peer receiving (${this.role})`, mine));

    if (this.peerReport) {
      // Recompute the gate over the peer's rows using the same logic.
      const c = new Collector();
      c.buckets = [];
      c.rows = () => this.peerReport.rows;
      c.loss = {
        lossRate: this.peerReport.totals.lossRate,
        received: this.peerReport.totals.received,
        lost: this.peerReport.totals.lost,
      };
      c.iceRtt = this.peerReport.meta.iceRttMs;
      c.pathType = this.peerReport.meta.pathType;
      parts.push(block(`Peer receiving (${this.peerReport.meta.role})`, c.verdict(gateTarget, c.iceRtt)));
    }

    parts.push(
      `<p class="muted">Gate per DESIGN.md §19: sustained 12 Mbps at ~80 ms RTT with bufferedAmount stable near zero. ` +
        `Measured path: <b>${this.collector.pathType ?? '?'}</b>, ICE RTT <b>${this.collector.iceRtt ?? '?'} ms</b>. ` +
        `Queue-delay figures are relative to the session floor — absolute one-way delay carries an unknown clock-asymmetry offset.</p>`,
    );

    el('verdict').innerHTML = parts.join('');
  }

  exportJSON() {
    const blob = {
      gate: this.collector.verdict(12, this.collector.iceRtt),
      local: this.lastReport ?? this.collector.toJSON(this.testMeta),
      peer: this.peerReport,
    };
    download(`tape-phase1-${Date.now()}.json`, JSON.stringify(blob, null, 2), 'application/json');
  }

  exportCSV() {
    download(`tape-phase1-${Date.now()}.csv`, this.collector.toCSV(), 'text/csv');
  }

  setStatus(s) {
    el('status').value = s;
  }
}

function download(name, text, mime) {
  const url = URL.createObjectURL(new Blob([text], { type: mime }));
  const a = document.createElement('a');
  a.href = url;
  a.download = name;
  a.click();
  URL.revokeObjectURL(url);
}

// ── Wire up ──────────────────────────────────────────────────────────────────
const h = new Harness();
window.__h = h; // handy from devtools

el('join').onclick = async () => {
  const code = el('room').value.trim();
  if (!code) return alert('room code required');
  el('join').disabled = true;
  el('room').disabled = true;
  el('policy').disabled = true;
  try {
    await h.join(code, el('policy').value);
  } catch (e) {
    log(`join failed: ${e.message}`);
    el('join').disabled = false;
  }
};
el('start').onclick = () => h.start();
el('stop').onclick = () => h.stop();
el('exportJson').onclick = () => h.exportJSON();
el('exportCsv').onclick = () => h.exportCSV();
el('mode').onchange = () => {
  el('targetWrap').style.display = el('mode').value === 'ramp' ? 'none' : '';
};

const params = new URLSearchParams(location.search);
if (params.get('room')) el('room').value = params.get('room');
if (params.get('policy')) el('policy').value = params.get('policy');
log(`harness ready — packet ${PKT_BYTES} B, bucket ${BUCKET_MS} ms`);
