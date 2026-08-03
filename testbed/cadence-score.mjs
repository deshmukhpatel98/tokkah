/**
 * Cadence scorer (task #33). Reads a cadence-call.mjs run dir (A.json/B.json with
 * window.__cad streams) and computes inter-present-interval (IPI) distributions:
 *
 *   remote  — presented remote frames (drawImage of VideoFrame on #remoteCanvas)
 *   decode  — true decode-output arrivals (painted or not)
 *   self    — self-view presented frames (rVFC on #preview)
 *
 * For each: p50 / p95 / p99 / max IPI, mean fps, on-cadence share
 * (33.3 ± 5 ms), and cadence breaks (IPI > 1.5 × 33.3 ms = 50 ms), after the
 * warmup trim (the governor's 5→34 fps ramp is law-10 physics, not cadence).
 *
 * Also: admission accounting (captured → admitted/encoded → arrived → presented)
 * so the 2–4% clean-path loss can be assigned to pacing tokens / inFlight /
 * FEC holds rather than guessed at.
 *
 * CLI:   node cadence-score.mjs runs/<dir>
 * Lib:   import { scoreCadenceRun } from './cadence-score.mjs'
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const FRAME_MS = 1000 / 30; // the lane's design cadence

const pct = (sorted, p) =>
  sorted.length ? +sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))].toFixed(2) : null;

function ipiStats(entries, warmupFrom, warmupMs) {
  if (!entries || entries.length < 3) return null;
  const t0 = entries[0].t;
  const cut = Math.max(warmupFrom ?? t0, t0) + warmupMs;
  const kept = entries.filter((e) => e.t >= cut);
  if (kept.length < 3) return null;
  const ipis = [];
  for (let i = 1; i < kept.length; i++) ipis.push(kept[i].t - kept[i - 1].t);
  ipis.sort((a, b) => a - b);
  const breaks = ipis.filter((x) => x > 1.5 * FRAME_MS).length;
  const onCad = ipis.filter((x) => Math.abs(x - FRAME_MS) <= 5).length;
  const spanS = (kept[kept.length - 1].t - kept[0].t) / 1000;
  return {
    frames: kept.length,
    spanS: +spanS.toFixed(1),
    fps: +(kept.length / spanS).toFixed(1),
    p50: pct(ipis, 50),
    p95: pct(ipis, 95),
    p99: pct(ipis, 99),
    max: +ipis[ipis.length - 1].toFixed(1),
    breaks,
    breakPct: +((100 * breaks) / ipis.length).toFixed(2),
    onCadencePct: +((100 * onCad) / ipis.length).toFixed(1),
  };
}

// totalVideoFrames diffs at 4 Hz: quantized, but exact counts — the in-call
// self-view truth when rVFC is occlusion-starved.
function selfQStats(selfQ, joinAt, warm) {
  if (!selfQ || selfQ.length < 4) return null;
  const post = selfQ.filter((e) => e.t >= joinAt + warm);
  if (post.length < 4) return null;
  const frames = post[post.length - 1].total - post[0].total;
  const dropped = post[post.length - 1].dropped - post[0].dropped;
  const spanS = (post[post.length - 1].t - post[0].t) / 1000;
  return { frames, dropped, spanS: +spanS.toFixed(1), fps: +(frames / spanS).toFixed(1) };
}

function admission(tv) {
  if (!tv) return null;
  const captured = tv.framesIn;
  const encoded = tv.framesEncoded;
  const arrived = tv.framesOut;
  const presented = tv.avEngaged ? tv.avPresents : null; // paint-on-arrival: drawn == out (probe counts separately)
  return {
    captured,
    encoded,
    skippedTotal: tv.framesSkipped,
    skipPaced: tv.skipPaced,
    skipBuffered: tv.skipBuffered,
    skipEncQueue: tv.skipEncQueue,
    skipDecodeStalled: tv.skipDecodeStalled,
    arrived,
    presented,
    framesLost: tv.framesLost,
    admittedPct: captured ? +((100 * encoded) / captured).toFixed(2) : null,
    arrivalVsEncodedPct: encoded ? +((100 * arrived) / encoded).toFixed(2) : null,
    admitFps: tv.admitFps,
    keyReqs: tv.keyReqSent,
    fecRepaired: tv.fecRepaired,
    fecHoldExpired: tv.fecHoldExpired,
    ageP50: tv.ageP50, ageP95: tv.ageP95,
    fullAgeP50: tv.fullAgeP50, fullAgeP95: tv.fullAgeP95,
    presentLagP50: tv.presentLagP50, presentLagP95: tv.presentLagP95,
    avEngaged: tv.avEngaged ?? false,
    avPresents: tv.avPresents ?? null,
    avHolds: tv.avHolds ?? null,
    avDrops: tv.avDrops ?? null,
    avSkips: tv.avSkips ?? null,
    avqDepth: tv.avqDepth ?? null,
    avOffP50: tv.avOffP50 ?? null,
    stall: tv.stall ? { regime: tv.stall.regime, shedded: tv.stall.shedded } : null,
  };
}

export function scoreCadenceRun(dir, { print = false, warmupMs = null } = {}) {
  const meta = JSON.parse(readFileSync(join(dir, 'meta.json'), 'utf8'));
  const warm = warmupMs ?? meta.warmupMs ?? 15000;
  const sides = {};
  for (const s of ['A', 'B']) {
    const p = join(dir, `${s}.json`);
    if (!existsSync(p)) continue;
    const d = JSON.parse(readFileSync(p, 'utf8'));
    const cad = d.cad ?? {};
    // Self-view reference = the pre-join lobby (#preview; on the post-#28 tree
    // the in-call self-view is #selfFull, tagged 'f'). Entries carry w: 'p' |
    // 'f' from the probe; older runs are untagged and all lobby-class.
    const joinAt = cad.joinAt ?? Infinity;
    const lobbySelf = (cad.self ?? []).filter((e) => e.t < joinAt);
    const inCallSelf = (cad.self ?? []).filter((e) => e.t >= joinAt && e.w !== 'p');
    sides[s] = {
      remote: ipiStats(cad.remote, null, warm),
      decode: ipiStats(cad.decode, null, warm),
      self: ipiStats(lobbySelf, null, 0),
      selfInCall: ipiStats(inCallSelf, null, warm),
      selfQ: selfQStats(cad.selfQ, joinAt, warm),
      lanePaints: (cad.laneP ?? []).length,
      probeNotes: (cad.notes ?? []).slice(0, 5),
      admission: admission(d.tapeVideo),
    };
  }
  const out = { dir, tag: meta.tag, q: meta.q, netsim: meta.netsim, warmupMs: warm, sides };

  if (print) {
    const f = (x, w = 7) => (x == null ? '—' : String(x)).padStart(w);
    console.log(`\n  ┌─ cadence: ${meta.tag}  (q=${meta.q || 'default'}${meta.netsim ? `  rtt=${meta.netsim.rttMs} loss=${meta.netsim.lossPct}%` : ''})`);
    for (const s of Object.keys(sides)) {
      const r = sides[s];
      console.log(`  │ side ${s}`);
      for (const k of ['self', 'remote', 'decode']) {
        const st = r[k];
        if (!st) { console.log(`  │   ${k.padEnd(6)} (no data)`); continue; }
        console.log(
          `  │   ${k.padEnd(6)} n=${String(st.frames).padStart(5)}  fps=${f(st.fps, 5)}  ` +
            `IPI p50=${f(st.p50)} p95=${f(st.p95)} p99=${f(st.p99)} max=${f(st.max)}  ` +
            `breaks=${f(st.breaks, 4)} (${st.breakPct}%)  on-cadence=${st.onCadencePct}%`,
        );
      }
      if (r.selfQ) {
        console.log(
          `  │   selfQ   in-call presented=${r.selfQ.frames} dropped=${r.selfQ.dropped} fps=${r.selfQ.fps} over ${r.selfQ.spanS}s`,
        );
      }
      if (r.selfInCall) {
        console.log(
          `  │   self-in-call rVFC n=${r.selfInCall.frames} fps=${r.selfInCall.fps} p50=${r.selfInCall.p50} p99=${r.selfInCall.p99} (occlusion-culled if ≪ remote n)`,
        );
      }
      const a = r.admission;
      if (a) {
        console.log(
          `  │   admission: captured=${a.captured} encoded=${a.encoded} (${a.admittedPct}%) ` +
            `arrived=${a.arrived} presented=${a.presented ?? 'draw=remote'} lost=${a.framesLost} ` +
            `skipPaced=${a.skipPaced} admitFps=${a.admitFps}`,
        );
        console.log(
          `  │   avsync=${a.avEngaged} presents=${a.avPresents ?? '—'} holds=${a.avHolds ?? '—'} ` +
            `drops=${a.avDrops ?? '—'} skips=${a.avSkips ?? '—'} avq=${a.avqDepth ?? '—'} offP50=${a.avOffP50 ?? '—'}` +
            `  fullAge p50=${a.fullAgeP50} p95=${a.fullAgeP95}  laneP=${r.lanePaints}`,
        );
      }
      if (r.probeNotes.length) console.log(`  │   probe notes: ${r.probeNotes.join(' | ')}`);
    }
    console.log(`  └${'─'.repeat(67)}`);
  }
  writeFileSync(join(dir, 'cadence.json'), JSON.stringify(out, null, 1));
  return out;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const dir = process.argv[2];
  if (!dir) {
    console.error('usage: node cadence-score.mjs runs/<dir>');
    process.exit(1);
  }
  scoreCadenceRun(dir, { print: true });
}
