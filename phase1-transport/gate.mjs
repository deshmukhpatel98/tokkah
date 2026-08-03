/**
 * Run the Phase 1 transport gate without two machines.
 *
 * DESIGN.md §19 is blunt about this one: "Nothing else gets built until this number exists."
 * The harness in `public/` was written for two humans on two continents, which is the honest
 * way to get RTT and also the reason the gate sat unrun. `testbed/netsim.mjs` removes the
 * excuse — a UDP delay line in front of a TURN relay we own gives real relay candidates and
 * settable distance, so the whole matrix can run here, unattended, in an afternoon.
 *
 * What this driver has to get right, and what it would silently get wrong:
 *
 *   1. **Throttling.** A backgrounded renderer has its timers clamped to ~1 s and rAF
 *      stopped. The pacer is a MessageChannel token bucket and the sampler is a 200 ms
 *      bucket, so a throttled tab does not fail — it reports a plausible, wrong number.
 *      The harness detects it and stamps `wasHidden`; this driver additionally passes the
 *      flags that stop it happening and refuses to print a verdict for a run that tripped it.
 *   2. **Relay policy.** With the simulator up, a host candidate over loopback bypasses the
 *      delay line completely. Media must be forced through the relay or the run measures
 *      nothing while looking like a pass.
 *   3. **PMTUD warm-up.** usrsctp only grows its path MTU, and therefore its congestion
 *      window, if it sees full-size datagrams early. The harness already does this; the
 *      driver must not shorten a run below it.
 *
 * Usage:
 *   node gate.mjs                                  ramp at 80 ms RTT (the gate cell)
 *   node gate.mjs --rtt=80 --loss=1 --mode=soak --target=12 --sec=60
 *   node gate.mjs --matrix                         the whole §19 table, sequentially
 *   node gate.mjs --headed                         watch it
 */

import { chromium } from '../testbed/node_modules/playwright-core/index.mjs';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import { startNetsim } from '../testbed/netsim.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const RUNS = join(HERE, 'runs');
// Full Chrome for Testing, not chrome-headless-shell. The shell has no WebRTC media stack
// worth the name, and this gate is entirely about what usrsctp does under load.
const CHROME =
  process.env.CHROME ??
  '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1228/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';

const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const [k, v] = a.replace(/^--/, '').split('=');
    return [k, v ?? true];
  }),
);

const URL_BASE = args.url ?? 'http://127.0.0.1:8791';
const HEADED = !!args.headed;

const log = (s) => console.log(s);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Force every peer connection through the simulator's relay.
 *
 * Identical in intent to `testbed/call.mjs`, and duplicated rather than shared because the
 * two harnesses have no common module and a shared file between them would couple the
 * transport gate to the media app for no benefit.
 */
const forceRelay = (servers) => `
  const OrigPC = window.RTCPeerConnection;
  const SIM_SERVERS = ${JSON.stringify(servers)};
  window.RTCPeerConnection = function (cfg, ...rest) {
    const c = { ...(cfg || {}), iceTransportPolicy: 'relay', iceServers: SIM_SERVERS };
    window.__forcedRelay = true;
    return new OrigPC(c, ...rest);
  };
  window.RTCPeerConnection.prototype = OrigPC.prototype;
`;

async function launch(room) {
  const browser = await chromium.launch({
    executablePath: CHROME,
    headless: !HEADED,
    args: [
      // The three that matter. Without them a headless renderer is treated as
      // backgroundable, the pacer's MessageChannel loop is clamped, and the run produces a
      // number that is wrong in the flattering direction — low throughput reads as the
      // transport's fault rather than the harness's.
      '--disable-background-timer-throttling',
      '--disable-renderer-backgrounding',
      '--disable-backgrounding-occluded-windows',
      '--disable-features=WebRtcHideLocalIpsWithMdns,CalculateNativeWinOcclusion',
      `--unsafely-treat-insecure-origin-as-secure=${URL_BASE}`,
      '--allow-running-insecure-content',
    ],
  });
  const page = await browser.newPage();
  const errors = [];
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push(m.text().slice(0, 200));
  });
  page.on('pageerror', (e) => errors.push('pageerror: ' + String(e.message).slice(0, 200)));
  return { browser, page, errors };
}

/** One cell of the matrix. Returns the two verdicts plus enough context to distrust them. */
let cellSeq = 0;

async function runCell({ rttMs, lossPct, jitterMs, mode, target, sec, bidir, nosim, pktBytes }) {
  const room = `gate-${Date.now().toString(36)}`;
  cellSeq++;
  // `--nosim` is the control arm, and it exists because of a real ambiguity rather than for
  // completeness. netsim's TURN relay and delay proxy are both Node, in one process, and every
  // datagram crosses the proxy twice per direction — so at 12 Mbps bidirectional the emulator
  // is handling ~5000 timers a second, and more as the ramp climbs. When a ramp collapses, the
  // question "was that the transport or my emulator?" has to be answerable, and the only way to
  // answer it is to run the same ramp with the emulator removed.
  const sim = nosim
    ? null
    : await startNetsim({
        oneWayMs: rttMs / 2,
        jitterMs,
        lossPct,
        // A distinct port per cell, not per process. Every cell in `--matrix` used to share
        // one port: cell 2's relay then tried to bind a port cell 1 had only just released,
        // and a TURN server that half-binds produces a run that looks like a transport
        // failure. `cellSeq` is what makes the matrix's cells independent of each other.
        turnPort: 3478 + (Number(process.pid) % 400) + cellSeq * 7,
      });
  log(
    `\n  ── ${nosim ? 'NO SIMULATOR (control arm)' : `${rttMs} ms RTT, ${lossPct}% loss, ${jitterMs} ms jitter`} — ${mode}` +
      `${mode === 'soak' ? ` @ ${target} Mbps` : ''}, ${sec} s/step`,
  );
  if (sim) log(`     relay 127.0.0.1:${sim.proxyPort} → TURN ${sim.turnPort}, ICE should read ~${sim.expectedRttMs} ms`);
  else log(`     direct over loopback, no delay line — measures the ceiling of the harness alone`);

  const A = await launch(room);
  const B = await launch(room);
  const init = sim ? forceRelay(sim.iceServers) : null;
  for (const side of [A, B]) {
    if (init) await side.page.addInitScript(init);
    await side.page.goto(
      `${URL_BASE}/?room=${room}&policy=${sim ? 'relay' : 'all'}${pktBytes ? `&pkt=${pktBytes}` : ''}`,
      { waitUntil: 'domcontentloaded' },
    );
    await side.page.waitForSelector('#join', { timeout: 20000 });
  }

  // A joins first so it takes the driver role, exactly as two humans would do it.
  await A.page.click('#join');
  await sleep(600);
  await B.page.click('#join');

  // Wait for the data channel, not for a timer. `#start` is only enabled once the harness
  // considers the channel usable, which is the condition that actually matters.
  await A.page.waitForFunction(() => !document.getElementById('start').disabled, { timeout: 45000 });

  await A.page.selectOption('#mode', mode);
  if (mode === 'soak') await A.page.fill('#targetMbps', String(target));
  await A.page.fill('#stepSec', String(sec));
  if (!bidir) await A.page.uncheck('#bidir');

  const proxyTrace = [];
  const steps = mode === 'ramp' ? 5 : 1;
  const budgetMs = steps * sec * 1000 + 25000; // + warm-up, settle and report exchange
  const t0 = Date.now();
  await A.page.click('#start');

  // Poll rather than sleep the whole budget, so a run that dies early says so early.
  let done = false;
  while (Date.now() - t0 < budgetMs) {
    await sleep(2000);
    done = await A.page.evaluate(() => !window.__h.running);
    if (done) break;
    if (sim)
      proxyTrace.push({
        t: Date.now() - t0,
        sent: sim.stats.sent,
        dropped: sim.stats.dropped,
        sendErrors: sim.stats.sendErrors,
        // The 1-minute load average, recorded per sample rather than once at the end, because
        // what matters is whether the machine was busy *during the ramp* — a run can start on
        // an idle host and finish on a saturated one.
        load1: os.loadavg()[0],
      });
    const now = await A.page.evaluate(() => ({
      target: document.getElementById('curTarget').textContent,
      recv: document.getElementById('recvMbps').textContent,
      buf: document.getElementById('buffered').textContent,
      loss: document.getElementById('loss').textContent,
      rtt: document.getElementById('iceRtt').textContent,
    }));
    process.stdout.write(
      `\r     ${String(Math.round((Date.now() - t0) / 1000)).padStart(4)}s  ` +
        `target ${now.target}  recv ${now.recv}  buffered ${now.buf}  loss ${now.loss}  ice ${now.rtt}   `,
    );
  }
  process.stdout.write('\n');
  if (!done) await A.page.click('#stop');
  await sleep(3000); // let the peer report cross and the verdict render

  const harvest = (p) =>
    p.evaluate(() => {
      const h = window.__h;
      const c = h.collector;
      return {
        verdict: c.verdict(12, c.iceRtt),
        wasHidden: h.hiddenDuringTest,
        forcedRelay: !!window.__forcedRelay,
        pathType: c.pathType,
        iceRttMs: c.iceRtt,
        rows: c.rows(),
        peer: h.peerReport ? { role: h.peerReport.meta?.role, meta: h.peerReport.meta } : null,
      };
    });

  const out = { a: await harvest(A.page), b: await harvest(B.page) };
  await A.browser.close();
  await B.browser.close();
  sim?.stop();

  return {
    setting: { rttMs, lossPct, jitterMs, mode, target, sec, bidir, nosim: !!nosim },
    expectedRttMs: sim?.expectedRttMs ?? 0,
    pktBytes: pktBytes ?? 1150,
    proxyStats: sim
      ? { sent: sim.stats.sent, dropped: sim.stats.dropped, sendErrors: sim.stats.sendErrors, bytes: sim.stats.bytes }
      : null,
    proxyLag: sim ? sim.loopLag() : null,
    hostLoad: os.loadavg().map((v) => +v.toFixed(2)),
    cores: os.cpus().length,
    proxyTrace,
    errors: { A: A.errors.slice(0, 6), B: B.errors.slice(0, 6) },
    ...out,
  };
}

function report(cell) {
  const { a, b } = cell;
  // Anything that invalidates the measurement is printed before the numbers, never after.
  // A verdict the reader has already believed is hard to retract with a footnote.
  const invalid = [];
  if (a.wasHidden || b.wasHidden) invalid.push('a renderer was backgrounded mid-test — timers throttled');
  // A starved delay line is a broken ruler, and a broken ruler cannot fail the thing it is
  // measuring. 20 ms is the threshold because the proxy holds each datagram on a timer: lag of
  // that size is already comparable to the 30 ms of jitter we inject deliberately, so past it
  // the emulated distance is no longer the distance we set and no verdict about the transport
  // can be drawn from it. See the note in netsim.mjs for the run this guard was written after.
  if (cell.proxyLag && cell.proxyLag.p95 > 20)
    invalid.push(
      `delay line was starved — loop lag p95 ${cell.proxyLag.p95} ms (max ${cell.proxyLag.max} ms), ` +
        `host load ${cell.hostLoad?.[0]} on ${cell.cores} cores: the emulator, not the transport`,
    );
  // Loss the emulator caused itself. Unlike a starved timer this needs no threshold: the delay
  // line is supposed to drop exactly the packets it was told to drop, so a single accidental
  // drop means the injected loss rate is not the loss rate the transport saw, and the whole
  // Mathis fit that §19 rests on is being fed the wrong x-axis. Cheap to detect, and invisible
  // until it was counted — the earlier version passed an empty callback to every `send` and so
  // reported `dropped: 0` while losing packets.
  if (cell.proxyStats?.sendErrors)
    invalid.push(
      `delay line failed ${cell.proxyStats.sendErrors} of its own sends (ENOBUFS) — ` +
        `it lost packets it was not asked to lose, so the injected loss rate is not what was measured`,
    );
  if (!cell.setting.nosim) {
    if (!a.forcedRelay || !b.forcedRelay) invalid.push('media did not go through the relay, so distance was not applied');
    if (a.pathType && !/relay/i.test(a.pathType)) invalid.push(`path type is ${a.pathType}, not relay`);
  }
  if (invalid.length) {
    log(`     RESULTS INVALID: ${invalid.join('; ')}`);
    return null;
  }

  const v = a.verdict;
  if (v.ok == null) {
    log(`     no verdict: ${v.reason}`);
    return null;
  }
  log(`     ICE measured ${a.iceRttMs?.toFixed?.(1) ?? '—'} ms against ${cell.expectedRttMs} ms set`);
  for (const c of v.checks) log(`     ${c.ok ? 'PASS' : 'FAIL'}  ${c.name}  —  ${c.got}`);
  log(`     ${v.ok ? '✓ GATE PASSES' : '✗ GATE FAILS'} at ${v.context.targetMbps} Mbps`);
  return v.ok;
}

// ── Main ─────────────────────────────────────────────────────────────────────
mkdirSync(RUNS, { recursive: true });

const cells = args.matrix
  ? // §19's table. Ramp first at the gate RTT, because knowing *where* it breaks is worth
    // more than pass/fail at one rate, then soak the cells the table actually names.
    [
      { rttMs: 80, lossPct: 0, jitterMs: 0, mode: 'ramp', target: 12, sec: 20 },
      { rttMs: 20, lossPct: 0, jitterMs: 0, mode: 'soak', target: 12, sec: 45 },
      { rttMs: 80, lossPct: 0, jitterMs: 0, mode: 'soak', target: 12, sec: 45 },
      { rttMs: 150, lossPct: 0, jitterMs: 0, mode: 'soak', target: 12, sec: 45 },
      { rttMs: 80, lossPct: 1, jitterMs: 0, mode: 'soak', target: 12, sec: 45 },
      { rttMs: 80, lossPct: 3, jitterMs: 0, mode: 'soak', target: 12, sec: 45 },
    ]
  : [
      {
        nosim: !!args.nosim,
        rttMs: Number(args.rtt ?? 80),
        lossPct: Number(args.loss ?? 0),
        jitterMs: Number(args.jitter ?? 0),
        mode: args.mode ?? 'ramp',
        target: Number(args.target ?? 12),
        pktBytes: args.pkt ? Number(args.pkt) : undefined,
        sec: Number(args.sec ?? 20),
        bidir: args.bidir !== 'false',
      },
    ];

log(`\n  PHASE 1 TRANSPORT GATE — ${cells.length} cell(s) against ${URL_BASE}`);
const results = [];
for (const c of cells) {
  const cell = await runCell({ bidir: true, ...c });
  cell.pass = report(cell);
  results.push(cell);
  // Let sockets actually close before the next cell binds. Without this the matrix measures
  // its own teardown as often as it measures the transport.
  await sleep(4000);
}

const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const path = join(RUNS, `gate-${stamp}.json`);
writeFileSync(path, JSON.stringify(results, null, 1));
log(`\n  wrote ${path}`);

const judged = results.filter((r) => r.pass != null);
if (judged.length) {
  log(`  ${judged.filter((r) => r.pass).length}/${judged.length} cell(s) passed`);
}
if (judged.length < results.length) {
  log(`  ${results.length - judged.length} cell(s) produced no usable verdict — see above`);
}
log('');
// Exit explicitly. Left to itself the process survived 16 minutes past its final line, still
// holding the emulator's UDP ports; netsim's teardown now unrefs them, and this is the belt to
// that braces — a driver whose answer is already printed has no business staying resident.
process.exit(0);
