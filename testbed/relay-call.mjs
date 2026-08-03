/**
 * relay-call.mjs — the §17.12 relayed-path check, owed since the stripe shipped.
 *
 * Two real browsers, the full conversation fixture, against PROD
 * (https://room.tokkah.com) with ALL media forced through Cloudflare TURN:
 * every RTCPeerConnection the page constructs (the main pc AND the §17.13
 * stripe pcs, which app.js builds internally) gets iceTransportPolicy:'relay'
 * merged into its config by a constructor wrapper injected with
 * page.addInitScript. No app file is touched. No --p2psim, no netsim: the
 * path is the real one — browser → residential uplink → CF TURN → back.
 *
 * The measurement is void unless relaying is PROVEN: every pc's selected
 * candidate pair is read out of getStats() (polled every 5 s, kept as a
 * series) and the local candidate type must be 'relay'. The proof, the TURN
 * server address (our own relay), and per-pair throughput are printed per pc.
 *
 * Usage:
 *   node relay-call.mjs --pairs=1            baseline arm
 *   node relay-call.mjs --pairs=3            stripe arm
 *   node relay-call.mjs --pairs=3 --tag=relay-p3-rerun
 */

import { chromium } from 'playwright-core';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const CHROME =
  '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';

const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const body = a.replace(/^--/, '');
    const i = body.indexOf('=');
    return i === -1 ? [body, true] : [body.slice(0, i), body.slice(i + 1)];
  }),
);

const PAIRS = Math.max(1, Math.min(8, Number(args.pairs ?? 1)));
const URL_BASE = 'https://room.tokkah.com';
const ROOM = args.room ?? `rel-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
const TAG = args.tag ?? `relay-p${PAIRS}`;
const OUTDIR = join(HERE, 'runs', `${TAG}-${ROOM}`);
const HEADED = !!args.headed;
const CONV = join(HERE, 'media', 'conv');
const VIDEO = join(HERE, 'media', 'cam1080.mjpeg');
// tape=2 (the fixed-QP video lane, ~12 Mbps on the VP8 carrier under GCC) and
// pcmaudio=1 (Lane A, ~1.8 Mbps on SCTP) ride together, exactly as in the
// §17.13 gates — the shared-bottleneck question is about the whole load.
const PAGE_URL = `${URL_BASE}/?r=${ROOM}&tape=2&pcmaudio=1&pcmpairs=${PAIRS}`;

const truth = JSON.parse(readFileSync(join(CONV, 'truth.json'), 'utf8'));
const RUN_MS = Number(args.ms ?? truth.totalMs + 12000);

const log = (s) => console.log(s);

// Force relay on EVERY peer connection the page constructs, and record them
// all. The stripe pcs are built inside app.js (not reachable from the test),
// so the constructor wrapper is the only injection point that covers both the
// main pc and the stripes without editing the app.
const FORCE_RELAY_AND_RECORD = `
  const OrigPC = window.RTCPeerConnection;
  window.__allPcs = [];
  window.RTCPeerConnection = function (cfg, ...rest) {
    const c = { ...(cfg || {}), iceTransportPolicy: 'relay' };
    const pc = new OrigPC(c, ...rest);
    window.__allPcs.push(pc);
    window.__forcedRelay = true;
    return pc;
  };
  window.RTCPeerConnection.prototype = OrigPC.prototype;
`;

async function launch(side, wav) {
  const browser = await chromium.launch({
    executablePath: CHROME,
    headless: !HEADED,
    args: [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      `--use-file-for-fake-video-capture=${VIDEO}`,
      `--use-file-for-fake-audio-capture=${resolve(HERE, wav)}`,
      '--autoplay-policy=no-user-gesture-required',
      '--alsa-output-device=null',
      // Relay candidate stats must carry real addresses, not mDNS names.
      '--disable-features=WebRtcHideLocalIpsWithMdns',
    ],
  });
  const page = await browser.newPage();
  const errors = [];
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push(m.text().slice(0, 300));
  });
  page.on('pageerror', (e) => errors.push('pageerror: ' + String(e.message).slice(0, 300)));
  await page.addInitScript(FORCE_RELAY_AND_RECORD);
  await page.goto(PAGE_URL, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#join', { timeout: 20000 });
  await page.fill('#room', ROOM);
  return { side, browser, page, errors };
}

// Per-pc getStats read: the selected candidate pair with both ends' candidate
// types/addresses (the relay proof), plus pair byte counters (throughput).
const POLL_JS = async () => {
  const out = [];
  const pcs = window.__allPcs ?? [];
  for (let i = 0; i < pcs.length; i++) {
    const pc = pcs[i];
    const rec = { i, conn: pc.connectionState, ice: pc.iceConnectionState, isMain: pc === window.__tape?.pc };
    try {
      const stats = await pc.getStats();
      let pair = null;
      stats.forEach((r) => {
        if (r.type === 'transport' && r.selectedCandidatePairId) pair = stats.get(r.selectedCandidatePairId);
      });
      if (!pair) stats.forEach((r) => {
        if (!pair && r.type === 'candidate-pair' && r.state === 'succeeded') pair = r;
      });
      const local = pair ? stats.get(pair.localCandidateId) : null;
      const remote = pair ? stats.get(pair.remoteCandidateId) : null;
      rec.pair = pair
        ? {
            state: pair.state, nominated: !!pair.nominated,
            rttMs: pair.currentRoundTripTime != null ? +(pair.currentRoundTripTime * 1000).toFixed(1) : null,
            bytesSent: pair.bytesSent ?? 0, bytesRecv: pair.bytesReceived ?? 0,
          }
        : null;
      rec.local = local
        ? { type: local.candidateType, addr: local.address ?? local.ip ?? null, port: local.port ?? null,
            proto: local.protocol ?? null, url: local.url ?? null, relayProto: local.relayProtocol ?? null }
        : null;
      rec.remote = remote
        ? { type: remote.candidateType, addr: remote.address ?? remote.ip ?? null, port: remote.port ?? null,
            proto: remote.protocol ?? null }
        : null;
    } catch (e) {
      rec.err = String(e).slice(0, 120);
    }
    out.push(rec);
  }
  const v = window.__tape?.video ?? null;
  const p = window.__tape?.pcm ?? null;
  return {
    t: performance.now(), pcs: out,
    tapeBytes: v?.bytesSent ?? null, tapeFrames: v?.framesEncoded ?? null,
    pcmSent: p?.framesSent ?? null, pcmCapture: p?.captureFrames ?? null,
  };
};

log(`\n${'═'.repeat(68)}`);
log(`  ${TAG}   room ${ROOM}   pcmpairs=${PAIRS}`);
log(`  ${PAGE_URL}`);
log(`  RELAY FORCED on every RTCPeerConnection (constructor wrapper, iceTransportPolicy:'relay')`);
log(`  fixture: ${truth.turns.length} turns, ${(truth.totalMs / 1000).toFixed(0)} s + slack`);
log(`${'═'.repeat(68)}\n`);

const A = await launch('A', join(CONV, 'A.wav'));
const B = await launch('B', join(CONV, 'B.wav'));
log('  both browsers up, lobby loaded (room pre-filled by ?r=)');

const t0 = Date.now();
await Promise.all([A.page.click('#join'), B.page.click('#join')]);
log('  join clicked on both');

const connected = async (p, ms) => {
  try {
    await p.page.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: ms });
    return true;
  } catch {
    return false;
  }
};
const [ca, cb] = await Promise.all([connected(A, 60000), connected(B, 60000)]);
const tConn = Date.now() - t0;
log(`  main pc connected: A=${ca} B=${cb} after ${tConn} ms`);
if (!ca || !cb) {
  for (const s of [A, B]) {
    const st = await s.page.evaluate(() => ({
      status: document.getElementById('status')?.textContent,
      joinStatus: document.getElementById('joinStatus')?.textContent,
      ice: window.__tape?.pc?.iceConnectionState,
    })).catch(() => null);
    log(`  ${s.side}: ${JSON.stringify(st)}`);
    if (s.errors.length) log(`  ${s.side} errors: ${s.errors.slice(0, 4).join(' | ')}`);
  }
}

// ── Run: poll every 5 s ──────────────────────────────────────────────────────
const seriesA = [];
const seriesB = [];
const started = Date.now();
while (Date.now() - started < RUN_MS) {
  await new Promise((r) => setTimeout(r, 5000));
  const el = Math.round((Date.now() - started) / 1000);
  const [pa, pb] = await Promise.all([
    A.page.evaluate(POLL_JS).catch(() => null),
    B.page.evaluate(POLL_JS).catch(() => null),
  ]);
  if (pa) seriesA.push({ el, ...pa });
  if (pb) seriesB.push({ el, ...pb });
  if (pa && pb) {
    const pct = (p) => (p.pcmCapture ? ((100 * p.pcmSent) / p.pcmCapture).toFixed(1) : '—');
    const pcLine = (p) =>
      p.pcs.map((c) => `${c.isMain ? 'M' : 's' + c.i}:${c.pair ? c.pair.rttMs + 'ms' : c.conn}`).join(' ');
    log(`  ${String(el).padStart(3)}s  pcm sent A ${pct(pa)}% / B ${pct(pb)}%   [A ${pcLine(pa)}]  [B ${pcLine(pb)}]`);
  }
}

// ── Final grab ───────────────────────────────────────────────────────────────
const grab = async (s) =>
  s.page.evaluate(async () => {
    const t = window.__tape;
    t?.turns?.flush?.();
    return {
      video: t?.video ?? null,
      pcm: t?.pcm ?? null,
      tapeMode: t?.tapeMode ?? null,
      forcedRelay: !!window.__forcedRelay,
      nPcs: window.__allPcs?.length ?? 0,
      turns: t?.turns?.summary?.() ?? null,
    };
  });
const [ra, rb] = await Promise.all([grab(A), grab(B)]);
const [finA, finB] = await Promise.all([
  A.page.evaluate(POLL_JS).catch(() => null),
  B.page.evaluate(POLL_JS).catch(() => null),
]);
if (finA) seriesA.push({ el: Math.round((Date.now() - started) / 1000), ...finA });
if (finB) seriesB.push({ el: Math.round((Date.now() - started) / 1000), ...finB });

mkdirSync(OUTDIR, { recursive: true });
writeFileSync(join(OUTDIR, 'meta.json'), JSON.stringify({
  tag: TAG, room: ROOM, url: PAGE_URL, pairs: PAIRS, at: new Date().toISOString(),
  connectMs: tConn, connected: { A: ca, B: cb }, runMs: RUN_MS,
  forcedRelay: { A: ra.forcedRelay, B: rb.forcedRelay },
  errors: { A: A.errors, B: B.errors },
}, null, 1));
writeFileSync(join(OUTDIR, 'A.json'), JSON.stringify({ grab: ra, series: seriesA }, null, 1));
writeFileSync(join(OUTDIR, 'B.json'), JSON.stringify({ grab: rb, series: seriesB }, null, 1));
writeFileSync(join(OUTDIR, 'truth.json'), JSON.stringify(truth, null, 1));

await Promise.all([A.browser.close(), B.browser.close()]);

// ── Report ───────────────────────────────────────────────────────────────────
log(`\n  wrote ${OUTDIR}`);

// The relay proof: every pc, both browsers, last sample of the series.
log('\n  RELAY PROOF (selected candidate pair, final sample):');
let void_ = false;
const turnAddrs = new Set();
for (const [name, series] of [['A', seriesA], ['B', seriesB]]) {
  const last = series[series.length - 1];
  if (!last) { log(`  ${name}: NO SAMPLES — VOID`); void_ = true; continue; }
  for (const c of last.pcs) {
    const label = c.isMain ? 'main ' : `stripe${c.i}`;
    const lt = c.local?.type ?? '—';
    const rt = c.remote?.type ?? '—';
    const ok = lt === 'relay';
    if (!ok) void_ = true;
    if (c.local?.addr) turnAddrs.add(`${c.local.addr}:${c.local.port} (${c.local.relayProto ?? c.local.proto ?? '?'})`);
    log(
      `  ${name} ${label.padEnd(7)} conn=${String(c.conn).padEnd(10)} local=${lt}` +
      ` ${c.local?.addr ?? '?'}:${c.local?.port ?? '?'} [${c.local?.relayProto ?? c.local?.proto ?? '?'}]` +
      `  remote=${rt} ${c.remote?.addr ?? '?'}:${c.remote?.port ?? '?'}` +
      `  pair-rtt=${c.pair?.rttMs ?? '—'} ms${ok ? '' : '   ← NOT RELAYED'}`,
    );
  }
}
log(`  TURN server address(es) observed: ${[...turnAddrs].join(', ') || 'none'}`);
if (void_) log('\n  *** RUN VOID — at least one pc did not negotiate a relay pair ***');
else log('\n  RELAYED PATH CONFIRMED on every pc.');

// Per-pc wire throughput from the pair byte series (avg + last-10 s).
log('\n  per-pc wire throughput (selected-pair bytes, send direction):');
for (const [name, series] of [['A', seriesA], ['B', seriesB]]) {
  const nPcs = Math.max(...series.map((s) => s.pcs.length));
  for (let i = 0; i < nPcs; i++) {
    const pts = series
      .map((s) => { const c = s.pcs.find((x) => x.i === i); return c?.pair ? { el: s.el, b: c.pair.bytesSent, main: c.isMain } : null; })
      .filter(Boolean);
    if (pts.length < 2) continue;
    const span = pts[pts.length - 1].el - pts[0].el;
    const avg = span > 0 ? (8 * (pts[pts.length - 1].b - pts[0].b)) / span / 1e6 : 0;
    const tail = pts.filter((p) => p.el >= pts[pts.length - 1].el - 10);
    const tspan = tail[tail.length - 1].el - tail[0].el;
    const last10 = tspan > 0 ? (8 * (tail[tail.length - 1].b - tail[0].b)) / tspan / 1e6 : null;
    log(`  ${name} ${pts[0].main ? 'main ' : 'stripe' + i}  avg ${avg.toFixed(2)} Mbps${last10 != null ? `  last-10s ${last10.toFixed(2)} Mbps` : ''}`);
  }
}

// Lane A bars, per side (send side + receive side live in the same snapshot).
log('\n  PCM audio lane (48 kHz/24-bit linear, no codec):');
for (const [side, r] of [['A', ra], ['B', rb]]) {
  const p = r.pcm;
  if (!p) { log(`  ${side}: lane not running`); continue; }
  const sentPct = p.captureFrames ? ((100 * p.framesSent) / p.captureFrames).toFixed(1) : '—';
  log(
    `  ${side}: sent ${p.framesSent}/${p.captureFrames} (${sentPct}%)  ${p.mbpsSent} Mbps` +
      `  drop(link) ${p.skipBuffered}  parity ${p.paritySent}` +
      `  | recv ${p.framesRecv}  lost ${p.lostFrames}  late ${p.lateFrames}  dup ${p.dup}`,
  );
  log(
    `      concealed ${p.concealedMs} ms (extrap ${p.extrapolatedMs}, held ${p.heldMs})` +
      `  fecRepaired ${p.fecRepaired}  fecFailed ${p.fecFailed}` +
      `  depth ${p.depthMs} ms  target ${p.targetFrames}f  drift ${p.driftPpm} ppm`,
  );
  log(
    `      age p50 ${p.ageP50} ms  p95 ${p.ageP95} ms  (rtt ${p.rttMs}, baseRtt ${p.baseRttMs}, offset ${p.clockOffsetMs})`,
  );
  if (p.perAssoc?.length) {
    const total = p.perAssoc.reduce((s, a) => s + a.framesSent, 0);
    for (const a of p.perAssoc) {
      const share = total ? ((100 * a.framesSent) / total).toFixed(1) : '—';
      log(
        `      [${a.i}] ${a.open ? 'open' : 'CLOSED'}  sent ${a.framesSent} (${share}%)  recv ${a.framesRecv}` +
          `  drop(link) ${a.skipBuffered}  parity ${a.paritySent}` +
          `  rtt ${a.rttMs}  baseRtt ${a.baseRttMs}  buffered ${a.buffered}`,
      );
    }
  }
}

// Video lane, briefly: it shares the relayed main pc and is the cross-traffic.
log('\n  custom video lane (the cross-traffic on the same relayed path):');
for (const [side, r] of [['A', ra], ['B', rb]]) {
  const v = r.video;
  if (!v) { log(`  ${side}: not running${r.tapeMode?.fellBack ? ' — FELL BACK to RTP' : ''}`); continue; }
  log(
    `  ${side}: sent ${v.framesEncoded}/${v.framesIn} frames  ${(v.bytesSent / 1e6).toFixed(1)} MB` +
      `  recv ${v.framesOut}  lost ${v.framesLost}  keyReq ${v.keyReqSent}/${v.keyReqRecv}` +
      `  age p50 ${v.ageP50} ms  p95 ${v.ageP95} ms`,
  );
}

if (ra.turns || rb.turns) {
  const t = ra.turns ?? rb.turns;
  log(`\n  turns: usable ${t?.usable}/${t?.total}  human ${t?.humanMedian}  perceived ${t?.perceivedMedian}`);
}
const errs = [...A.errors, ...B.errors];
if (errs.length) {
  log(`\n  ${errs.length} console error(s):`);
  for (const e of [...new Set(errs)].slice(0, 6)) log(`    ${e}`);
}
log('');
process.exit(void_ ? 2 : 0);
