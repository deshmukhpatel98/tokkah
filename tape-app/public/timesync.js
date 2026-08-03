/**
 * TIME_SYNC — §10's session clock, riding the EXISTING lane-2 ctl DataChannel
 * (no new channels: the no-renegotiation law). Started only when the A-V sync
 * bundle is on (`?pcmaudio=1` + lane 2 + not `?avsync=0`); otherwise this
 * module is never constructed and the ctl wire is byte-identical to before.
 *
 * Two concerns, kept separate from pcm.js's per-association ping/pong:
 *
 *   1. Peer-to-peer clock offset, NTP-style four-timestamp at 5 Hz:
 *        t1 = our wall at send        (tsy.a)
 *        t2 = peer wall at receive    (tsyr.b)
 *        t3 = peer wall at reply      (tsyr.c)
 *        t4 = our wall at reply-recv  (local)
 *      rtt    = (t4 − t1) − (t3 − t2)
 *      offset = ((t2 − t1) + (t3 − t4)) / 2     [peer wall − our wall]
 *      The offset is taken from the MINIMUM-RTT sample in a sliding 10 s
 *      window — min-filtering rejects queueing delay far better than
 *      averaging (§10). ctl is SCTP over the same path as media, so queueing
 *      is the common case, not the exception (law 16).
 *
 *   2. Crystal drift: 10–50 ppm between two machines is 36–180 ms/hour —
 *      enough to break sync on a long call. A slow least-squares fit over the
 *      min-filtered offset stream gives the slope in ppm; the corrected
 *      offset is offset(t) = offsetMin + slope·(t − tMin).
 *
 * The DO's session_epoch_us is the session epoch (sole time authority). A
 * peer's mapping to it is estimated once from the welcome exchange
 * (epochUs − local wall at welcome arrival; biased by one-way ws delay,
 * reported as an estimate, not ground truth). sessionUs() expresses any local
 * instant on that epoch so cross-peer telemetry shares one timeline.
 */
const now = () => performance.timeOrigin + performance.now();

export function initTimeSync({ epochUs, welcomeAtMs, send, log }) {
  const L = (tag, d) => { try { log?.(tag, d); } catch { /* telemetry must never break the call */ } };

  const S = {
    epochUs: epochUs ?? null,
    welcomeAtMs: welcomeAtMs ?? null,
    pings: 0, pongs: 0,
    rttMinMs: null, offsetMs: null, driftPpm: 0, fitN: 0,
  };
  let samples = []; // {t, rtt, off} — sliding 10 s window
  let fits = [];    // {t, off} — the min-filtered stream, for the drift fit
  let timer = null;
  let lastLog = 0;

  function sendPing() {
    S.pings++;
    send({ t: 'tsy', a: now() });
  }

  // Returns true when the message was ours.
  function onMessage(m) {
    if (m.t === 'tsy') {
      // Reply immediately with both receive and send stamps — they differ by
      // microseconds here, but the four-stamp shape keeps the exchange honest
      // if that ever stops being true.
      const t2 = now();
      send({ t: 'tsyr', a: m.a, b: t2, c: now() });
      return true;
    }
    if (m.t !== 'tsyr') return false;
    S.pongs++;
    const t4 = now();
    const rtt = t4 - m.a - (m.c - m.b);
    if (!(rtt >= 0)) return true; // a malformed stamp poisons every estimate after it
    const off = (m.b - m.a + (m.c - t4)) / 2;
    samples.push({ t: t4, rtt, off });
    const cutoff = t4 - 10_000;
    samples = samples.filter((s) => s.t >= cutoff);
    let best = samples[0];
    for (const s of samples) if (s.rtt < best.rtt) best = s;
    if (!best) return true;
    S.rttMinMs = +best.rtt.toFixed(2);
    S.offsetMs = +best.off.toFixed(3);
    fits.push({ t: t4, off: best.off });
    if (fits.length > 1800) fits.shift(); // ~6 min at 5 Hz
    S.fitN = fits.length;
    // Least-squares slope over the min-filtered stream. Meaningful only once
    // the window spans enough time for ppm-scale movement; gated at 30 s.
    if (fits.length > 150 && t4 - fits[0].t > 30_000) {
      const t0 = fits[0].t;
      let sx = 0, sy = 0, sxx = 0, sxy = 0;
      for (const p of fits) {
        const x = (p.t - t0) / 1000;
        sx += x; sy += p.off; sxx += x * x; sxy += x * p.off;
      }
      const n = fits.length;
      const den = n * sxx - sx * sx;
      // slope in ms/s ×1000 = ppm (0.05 ms/s = 50 ppm)
      if (den > 0) S.driftPpm = +(((n * sxy - sx * sy) / den) * 1000).toFixed(1);
    }
    if (t4 - lastLog > 10_000) {
      lastLog = t4;
      L('timesync', snapshot());
    }
    return true;
  }

  function snapshot() {
    // Stability of the min-filtered offset over the fit window: the spread a
    // consumer of this clock would have seen.
    let lo = Infinity, hi = -Infinity;
    for (const p of fits) { if (p.off < lo) lo = p.off; if (p.off > hi) hi = p.off; }
    return {
      ...S,
      offSpreadMs: fits.length > 1 ? +(hi - lo).toFixed(3) : null,
      // ms to ADD to local wall to reach the DO's clock (estimate; the
      // welcome's one-way ws delay rides in it, unmeasured — noted in §17.14).
      epochOffsetMs:
        S.epochUs != null && S.welcomeAtMs != null ? +(S.epochUs / 1000 - S.welcomeAtMs).toFixed(1) : null,
      running: !!timer,
    };
  }

  return {
    onMessage,
    start() {
      if (timer) return;
      timer = setInterval(sendPing, 200); // 5 Hz — control-plane volume, ~60 B per message
      sendPing();
      L('timesync-start', { epochUs: S.epochUs });
    },
    stop() { clearInterval(timer); timer = null; },
    snapshot,
    /** Local instant (default now) expressed in the session epoch, drift-corrected. */
    sessionUs(atMs) {
      const w = atMs ?? now();
      if (S.epochUs == null || S.welcomeAtMs == null) return null;
      const driftMs = S.driftPpm ? (S.driftPpm / 1000) * ((w - S.welcomeAtMs) / 1000) : 0;
      return Math.round(S.epochUs + (w - S.welcomeAtMs) * 1000 + driftMs * 1000);
    },
  };
}
