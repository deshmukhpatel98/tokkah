#!/usr/bin/env node
/**
 * g2g-probe — the glass-to-glass scoreboard (task #29).
 *
 * Measures BOTH legs side by side, telemetry/testbed only — nothing here touches
 * the call UI, the app, or the wire:
 *
 *   REMOTE-VIEW  camera(A) → pixels(B): computed from EXISTING telemetry fields
 *     only (the 2 s `tape-stats` / `pcm-stats` / `timesync-stats` events call.mjs
 *     already harvests). The estimator is the §10 audio-clock identity
 *         G2G = L_audio − applied
 *             = (pcm.ageP50 rebased onto TIME_SYNC + pcm.depthMs
 *                + pcm.outputLatencyMs) − tape.avOffP50
 *     with a fullAge-based cross-check and a per-run decomposition
 *     (capture → encode → transport → hold/decode → render queue → compositor).
 *     Every number ships with its clock bound (TIME_SYNC minRtt/2) and the
 *     [0, 1 vsync] compositor bracket. See g2g-design.md for the derivation.
 *
 *   SELF-VIEW  camera → local preview pixels: NO existing app telemetry touches
 *     the preview path ($('self').srcObject = localStream, uninstrumented; the
 *     app defaults selfview OFF per §1.1). The interim answer is the platform
 *     pipeline measured STANDALONE (g2g-selfprobe.html — getUserMedia → <video>
 *     → requestVideoFrameCallback, captureTimestamp → expectedDisplayTime, one
 *     clock, no mapping). The in-app hook (one rVFC loop behind ?selfprobe=1)
 *     is specified in g2g-design.md and QUEUED, not applied.
 *
 * Mutex: before EVERY browser run this script waits for the heavy-run mutex —
 * no other call.mjs / sctpwall.mjs / corpus-score.mjs / g2g-probe.mjs in flight.
 *
 * Usage:
 *   node g2g-probe.mjs                     loopback run + RTT 80/1% run + self-probe, full report
 *   node g2g-probe.mjs --only=loop|80|self
 *   node g2g-probe.mjs --score=runs/<dir> [--score=runs/<dir2> …]   score existing runs, no browsers
 */

import { spawn, execSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:http';

const HERE = dirname(fileURLToPath(import.meta.url));
const CHROME =
  '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const VSYNC_MS = 1000 / 60;
const log = (s) => console.log(s);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── heavy-run mutex ──────────────────────────────────────────────────────────
// Counts ACTUAL heavy node processes (call.mjs and its cadence-call.mjs sibling,
// sctpwall, corpus-score, other g2g-probes) — matched by executable + script
// argument, NOT by `pgrep -f "call\.mjs"`: the loose form matches any wrapper
// shell whose command TEXT merely mentions the script (measured 2026-08-02: a
// heredoc-writing wrapper deadlocked its own mutex loop and every other
// agent's). A staging shell is not a heavy run; a running node is.
const HEAVY_SCRIPT = /(?:^|\/)(?:[\w-]*call|sctpwall|corpus-score|g2g-probe)\.mjs$/;
function heavyRunning() {
  let out = '';
  try {
    out = execSync('ps -axo pid=,args=', { encoding: 'utf8' });
  } catch {
    return [];
  }
  return out
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean)
    .filter((l) => {
      const sp = l.indexOf(' ');
      const pid = Number(l.slice(0, sp));
      if (pid === process.pid || pid === process.ppid) return false; // never mutex on ourselves
      const args = l.slice(sp + 1).split(/\s+/);
      const exe = args[0] ?? '';
      const script = args[1] ?? '';
      return /(?:^|\/)node$/.test(exe) && HEAVY_SCRIPT.test(script);
    });
}
async function waitMutex() {
  for (;;) {
    const h = heavyRunning();
    if (!h.length) return;
    log(`  [mutex] heavy run in flight: ${h[0]} — waiting 5 s`);
    await sleep(5000);
  }
}

// ── small stats ──────────────────────────────────────────────────────────────
const pct = (arr, p) => {
  const a = arr.filter((x) => x != null && Number.isFinite(x));
  if (!a.length) return null;
  const s = [...a].sort((x, y) => x - y);
  return +s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))].toFixed(1);
};
const med = (a) => pct(a, 50);
const f = (v, u = '') => (v == null ? '—' : `${v}${u}`);

// ── run call.mjs as a subprocess, return its output dir ──────────────────────
function runCall(extraArgs) {
  return new Promise((resolve, reject) => {
    const child = spawn('node', ['call.mjs', ...extraArgs], { cwd: HERE, stdio: ['ignore', 'pipe', 'inherit'] });
    let out = '';
    child.stdout.on('data', (d) => {
      const s = d.toString();
      out += s;
      process.stdout.write(s);
    });
    child.on('exit', (code) => {
      const m = out.match(/wrote (.+)/); // the project path contains a space — \S+ truncates it
      if (code === 0 && m) return resolve(m[1].trim());
      reject(new Error(`call.mjs exited ${code}; dir ${m?.[1] ?? 'not found'}`));
    });
  });
}

// ── score a run dir ──────────────────────────────────────────────────────────
function scoreRun(dir) {
  const sides = {};
  for (const s of ['A', 'B']) {
    const p = join(dir, `${s}.json`);
    if (existsSync(p)) sides[s] = JSON.parse(readFileSync(p, 'utf8'));
  }
  if (!sides.A || !sides.B) throw new Error(`${dir}: need A.json and B.json`);
  const meta = existsSync(join(dir, 'meta.json')) ? JSON.parse(readFileSync(join(dir, 'meta.json'), 'utf8')) : {};

  const byKind = (evs, k) => evs.filter((e) => e.kind === k).sort((a, b) => a.t - b.t);
  const nearest = (arr, t, maxMs) => {
    let best = null;
    for (const e of arr) {
      if (Math.abs(e.t - t) < Math.abs((best?.t ?? Infinity) - t)) best = e;
    }
    return best && Math.abs(best.t - t) <= maxMs ? best : null;
  };

  // Per receiver side: aligned 2 s ticks {tape, pcm, tsy} over the engaged span.
  const sideSeries = (S) => {
    const evs = S.events ?? [];
    const tape = byKind(evs, 'tape-stats');
    const pcm = byKind(evs, 'pcm-stats');
    const tsy = byKind(evs, 'timesync-stats');
    const eng = evs.find((e) => e.kind === 'tape-avsync-engaged');
    const engagedAt = eng?.t ?? null;
    const offsetMs = eng?.data?.offsetMs ?? 20;
    const ticks = [];
    for (const te of tape) {
      const pe = nearest(pcm, te.t, 1200);
      const se = nearest(tsy, te.t, 1200);
      const T = te.data ?? {};
      const P = pe?.data ?? null;
      const Y = se?.data ?? null;
      if (T.avEngaged !== true) continue;
      if (P?.ageP50 == null || P?.depthMs == null || P?.outputLatencyMs == null) continue;
      if (T.avOffP50 == null || Y?.offsetMs == null) continue;
      // Rebase every wall↔wall quantity onto TIME_SYNC's min-filtered offset.
      // pcm's per-assoc ping offset is queueing-contaminated under loss (design
      // doc §1.6): measured −7.6/+10.2 ms vs TIME_SYNC's −0.1/−0.5 at 80/1.
      const corrPcm = P.clockOffsetMs != null ? P.clockOffsetMs - Y.offsetMs : 0;
      const corrTape = T.clockOffsetMs != null ? T.clockOffsetMs - Y.offsetMs : 0;
      const ageAudio = P.ageP50 + corrPcm; // capture→arrival, re-based
      const L_audio = ageAudio + P.depthMs + P.outputLatencyMs;
      const g2g = L_audio - T.avOffP50; // capture→canvas-draw, sender-audio-clock identity
      const fullAge = T.fullAgeP50 != null ? T.fullAgeP50 + corrTape : null;
      const transport = T.ageP50 != null ? T.ageP50 + corrTape : null; // encode-out→arrival
      ticks.push({
        t: te.t,
        g2g: +g2g.toFixed(1),
        L_audio: +L_audio.toFixed(1),
        applied: T.avOffP50,
        fullAge,
        renderWait: fullAge != null ? +(g2g - fullAge).toFixed(1) : null,
        transport,
        depthMs: P.depthMs,
        outLatMs: P.outputLatencyMs,
        ageAudio: +ageAudio.toFixed(1),
        corrPcm: +corrPcm.toFixed(2),
        corrTape: +corrTape.toFixed(2),
        rttMinMs: Y.rttMinMs ?? null,
        offSpreadMs: Y.offSpreadMs ?? null,
      });
    }
    return { ticks, engagedAt, offsetMs, engaged: engagedAt != null };
  };

  // Sender-side terms are machine-local: median over the peer's own tape-stats.
  const senderTerms = (S) => {
    const tape = byKind(S.events ?? [], 'tape-stats');
    return {
      capLag: med(tape.map((e) => e.data?.capLagP50).filter((v) => v != null)),
      encLat: med(tape.map((e) => e.data?.encLatP50).filter((v) => v != null)),
    };
  };

  const result = { dir, tag: meta.tag ?? dir.split('/').pop(), netsim: meta.netsim ?? null, directions: {} };
  for (const [from, to] of [['A', 'B'], ['B', 'A']]) {
    const R = sideSeries(sides[to]); // receiver series
    const S = senderTerms(sides[from]); // sender terms
    const settled = R.ticks.filter((k) => R.engagedAt == null || k.t >= R.engagedAt + 15000);
    const use = settled.length >= 5 ? settled : R.ticks;
    const g = (k) => use.map((x) => x[k]).filter((v) => v != null);
    const clockBound = med(g('rttMinMs')) != null ? +(med(g('rttMinMs')) / 2).toFixed(2) : null;
    const fullAge50 = med(g('fullAge'));
    const decomp = {
      capture: S.capLag,
      encode: S.encLat,
      transport: med(g('transport')),
      holdDecode:
        fullAge50 != null && med(g('transport')) != null && S.capLag != null && S.encLat != null
          ? Math.max(0, +(fullAge50 - med(g('transport')) - S.capLag - S.encLat).toFixed(1))
          : null,
      renderQueue: med(g('renderWait')),
      compositorBracket: [0, +VSYNC_MS.toFixed(1)],
    };
    // Cross-check through the video lane: queue-binding regime collapses to
    // L_audio − offset + half a vsync; degenerate regime to fullAge + [0, 2 vsync].
    const La50 = med(g('L_audio'));
    const g2gx =
      La50 != null && fullAge50 != null
        ? +(fullAge50 + Math.max(0, La50 - fullAge50 - R.offsetMs) + VSYNC_MS / 2).toFixed(1)
        : null;
    result.directions[`${from}→${to}`] = {
      engaged: R.engaged,
      nTicks: use.length,
      settled: settled.length >= 5,
      g2g: { p50: med(g('g2g')), p95: pct(g('g2g'), 95) },
      g2gCrossCheck: g2gx,
      L_audio: { p50: La50, p95: pct(g('L_audio'), 95) },
      appliedOffset: { p50: med(g('applied')), p95: pct(g('applied'), 95) },
      fullAge: { p50: fullAge50, p95: pct(g('fullAge'), 95) },
      decomp,
      uncertainty: {
        clockBoundMs: clockBound != null ? `±${clockBound}` : null, // TIME_SYNC minRtt/2 — the NTP bound
        pcmOffsetCorrMs: med(g('corrPcm')), // queueing contamination removed from pcm's ping offset
        tapeVsTimesyncMs: med(g('corrTape')), // consistency cross-check (should be ~0)
        offSpreadMs: med(g('offSpreadMs')),
        outLatMs: med(g('outLatMs')), // Chrome's estimate, stated ±10 systematic
        compositorMs: `+[0, ${VSYNC_MS.toFixed(1)}]`, // draw → pixels, unmeasured, bounded by a vsync
      },
    };
  }
  return result;
}

function printRun(r) {
  log(`\n${'─'.repeat(74)}`);
  log(`  RUN ${r.tag}   ${r.dir.split('/').pop()}${r.netsim ? `   (sim rtt ${r.netsim.rttMs} ms, loss ${r.netsim.lossPct}%)` : '   (loopback)'}`);
  for (const [dirn, d] of Object.entries(r.directions)) {
    if (!d.engaged) {
      log(`  ${dirn}: A-V sync never engaged — remote G2G not computable from telemetry (paint-on-arrival run).`);
      continue;
    }
    const u = d.uncertainty;
    log(`  ${dirn}  (${d.nTicks} ticks, ${d.settled ? 'settled' : 'ALL engaged — warm-up included, <5 settled'})`);
    log(
      `    REMOTE G2G   p50 ${f(d.g2g.p50, ' ms')}   p95 ${f(d.g2g.p95, ' ms')}` +
        `   ${u.compositorMs} compositor   clock ${u.clockBoundMs} (TIME_SYNC minRtt/2)`,
    );
    log(`    cross-check (video-lane route): ${f(d.g2gCrossCheck, ' ms')}   L_audio p50 ${f(d.L_audio.p50, ' ms')}`);
    const c = d.decomp;
    log(
      `    where it sits: capture ${f(c.capture)} | encode ${f(c.encode)} | transport ${f(c.transport)}` +
        ` | hold+decode ${f(c.holdDecode)} | render queue ${f(c.renderQueue)} | compositor [0, ${VSYNC_MS.toFixed(1)}]   (ms)`,
    );
    const terms = Object.entries(c).filter(([k, v]) => typeof v === 'number');
    terms.sort((a, b) => b[1] - a[1]);
    if (terms.length) log(`    biggest term: ${terms[0][0]} ${terms[0][1]} ms`);
    log(
      `    uncertainty: pcm offset corr ${f(u.pcmOffsetCorrMs, ' ms')} removed, tape↔TIME_SYNC ${f(u.tapeVsTimesyncMs, ' ms')},` +
        ` outLat ${f(u.outLatMs, ' ms')} (Chrome estimate, ±10 stated), offSpread ${f(u.offSpreadMs, ' ms')}`,
    );
  }
}

// ── standalone self-view platform probe ──────────────────────────────────────
async function selfProbe(realcam) {
  const server = createServer((req, res) => {
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end(readFileSync(join(HERE, 'g2g-selfprobe.html')));
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { chromium } = await import('playwright-core');
  const browser = await chromium.launch({
    executablePath: CHROME,
    headless: true,
    args: [
      '--use-fake-ui-for-media-stream',
      ...(realcam ? [] : ['--use-fake-device-for-media-stream']),
      '--autoplay-policy=no-user-gesture-required',
      `--unsafely-treat-insecure-origin-as-secure=http://127.0.0.1:${server.address().port}`,
    ],
  });
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.waitForFunction(() => window.__selfprobe?.done, null, { timeout: 40000 });
  const r = await page.evaluate(() => window.__selfprobe);
  await browser.close();
  server.close();
  return r;
}

function printSelf(tag, r) {
  log(`\n  SELF-VIEW platform probe (${tag})`);
  if (r.err) {
    log(`    failed: ${r.err}`);
    return null;
  }
  log(`    rVFC metadata keys: ${(r.rvfcKeys ?? []).join(', ')}`);
  if (!r.capStamped) {
    log(`    captureTime/captureTimestamp ABSENT on this source — absolute self-view G2G needs the queued ?selfprobe=1 hook`);
    log(`    AND a camera that stamps capture times. track-reader lag: ${JSON.stringify(r.trackLag)}`);
    return null;
  }
  log(
    `    SELF-VIEW G2G (captureTimestamp → expectedDisplayTime): p50 ${f(r.g2gExpected?.p50, ' ms')}   p95 ${f(r.g2gExpected?.p95, ' ms')}` +
      `   [min ${f(r.g2gExpected?.min)}, max ${f(r.g2gExpected?.max)}]  n=${r.n}`,
  );
  log(`    at rVFC callback instead of expected display: p50 ${f(r.g2gCallback?.p50, ' ms')}   vsync p50 ${f(r.vsyncMs?.p50, ' ms')}`);
  log(`    settings: ${JSON.stringify(r.settings)}   track-reader: ${JSON.stringify(r.trackLag)}`);
  return r.g2gExpected?.p50 ?? null;
}

// ── main ─────────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
const scoreDirs = argv.filter((a) => a.startsWith('--score=')).map((a) => a.slice(8));
const only = argv.find((a) => a.startsWith('--only='))?.slice(7) ?? null;

if (scoreDirs.length) {
  for (const d of scoreDirs) {
    const r = scoreRun(d);
    writeFileSync(join(d, 'g2g.json'), JSON.stringify(r, null, 1));
    printRun(r);
  }
  process.exit(0);
}

const wantLoop = !only || only === 'loop';
const want80 = !only || only === '80';
const wantSelf = !only || only === 'self';

log(`\n${'═'.repeat(74)}\n  g2g-probe — glass-to-glass scoreboard (telemetry only, never the call UI)\n${'═'.repeat(74)}`);

let loopRes = null, r80Res = null, selfFake = null, selfReal = null;

if (wantLoop) {
  await waitMutex();
  log('\n▶ loopback run (tape=2&pcmaudio=1)…');
  const dir = await runCall(['--tag=g2g-loop', '--q=tape=2&pcmaudio=1']);
  loopRes = scoreRun(dir);
  writeFileSync(join(dir, 'g2g.json'), JSON.stringify(loopRes, null, 1));
  printRun(loopRes);
}

if (want80) {
  await waitMutex();
  log('\n▶ RTT 80 ms / 1% loss run (--p2psim, tape=2&pcmaudio=1)…');
  const dir = await runCall(['--p2psim', '--rtt=80', '--loss=1', '--tag=g2g-80-1', '--q=tape=2&pcmaudio=1']);
  r80Res = scoreRun(dir);
  writeFileSync(join(dir, 'g2g.json'), JSON.stringify(r80Res, null, 1));
  printRun(r80Res);
}

if (wantSelf) {
  await waitMutex();
  log('\n▶ self-view platform probe (fake camera)…');
  selfFake = await selfProbe(false);
  writeFileSync(join(HERE, 'runs', 'g2g-selfprobe-fake.json'), JSON.stringify(selfFake, null, 1));
  printSelf('fake camera — the fixture source', selfFake);
  await waitMutex();
  log('\n▶ self-view platform probe (real camera)…');
  try {
    selfReal = await selfProbe(true);
    writeFileSync(join(HERE, 'runs', 'g2g-selfprobe-real.json'), JSON.stringify(selfReal, null, 1));
    printSelf('real camera', selfReal);
  } catch (e) {
    log(`    real-camera probe failed: ${e.message} (no TCC grant in this shell — fake-camera result stands)`);
  }
}

// ── the scoreboard ───────────────────────────────────────────────────────────
log(`\n${'═'.repeat(74)}\n  SCOREBOARD — the gap the user wants closed\n${'═'.repeat(74)}`);
// Reuse the last saved self-probe when this invocation didn't re-measure it.
const loadSelf = (n) => {
  try { return JSON.parse(readFileSync(join(HERE, 'runs', n), 'utf8')); } catch { return null; }
};
selfFake ??= loadSelf('g2g-selfprobe-fake.json');
selfReal ??= loadSelf('g2g-selfprobe-real.json');
const selfP50 = selfFake?.capStamped ? selfFake.g2gExpected?.p50 : selfReal?.g2gExpected?.p50 ?? null;
for (const [name, r] of [['loopback', loopRes], ['RTT 80/1%', r80Res]]) {
  if (!r) continue;
  for (const [dirn, d] of Object.entries(r.directions)) {
    if (!d.engaged) continue;
    const gap = selfP50 != null && d.g2g.p50 != null ? +(d.g2g.p50 - selfP50).toFixed(1) : null;
    log(
      `  ${name} ${dirn}:  remote G2G p50 ${f(d.g2g.p50, ' ms')} (p95 ${f(d.g2g.p95, ' ms')})` +
        `   clock ${d.uncertainty.clockBoundMs}   ${d.uncertainty.compositorMs} compositor` +
        (gap != null ? `   → gap over self-view: ${gap} ms` : ''),
    );
  }
}
if (selfP50 != null) log(`  self-view (platform, ${selfFake?.capStamped ? 'fake' : 'real'} camera): p50 ${selfP50} ms`);
else log(`  self-view: NEEDS ONE HOOK (?selfprobe=1 rVFC loop — specified in g2g-design.md §2, queued, not applied)`);
log('');
