// lobby-probe.mjs — lobby/room capacity probe against prod (task #25).
//
// What it measures against https://room.tokkah.com (Cloudflare Workers + one
// Durable Object per room, media never transits the DO — §14):
//
//   Phase 0  preflight: page + /api/ice health (credentials are NEVER printed).
//   Phase 1  admission: time to ws-open and time to `welcome` for peer A and
//            peer B across fresh (cold-DO) rooms; a concurrent-join burst.
//   Phase 2  occupancy cap: third joiner must get HTTP 409 "room full"
//            (worker.ts enforces peers.size >= 2 → 409) and the two occupants
//            must be unaffected.
//   Phase 3  relay latency under ctl load: 2 occupants, echo pings ride the
//            same websocket as offered background load, tiers from idle past
//            the §14 design point (~1 KB/s control per direction) to a knee
//            watch at ~100 KB/s aggregate. Aborts the tier at the first sign
//            of degradation (unexpected close/error, echo loss, p95 > 3x base).
//   Phase 4  room-count scaling: N rooms x 2 occupants at design-point load
//            simultaneously — the design's real scaling axis is rooms (one DO
//            each), not occupants.
//   Phase 5  session_epoch_us persistence after idle eviction, sentinel
//            long-lived socket aliveness, clean teardown.
//
// Good-citizen contract: throwaway room names (capacity-probe-<ts>-N), every
// socket closed at the end, gradual ramp, stop at the first knee sign. Peak
// concurrency is 14 websockets; peak offered relay load ~100 msg/s aggregate.
//
// Heavy-run mutex (machine-wide, HANDOFF law): refuses to start while
// call.mjs / sctpwall.mjs / corpus-score.mjs are running; re-checks before
// the parallel-room phase.
//
// Run: node testbed/lobby-probe.mjs   (auto re-execs with
// --experimental-websocket on Node 20, where undici's WebSocket is gated)

import { spawnSync, execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { writeFileSync, mkdirSync } from 'node:fs';
import { promisify } from 'node:util';
import https from 'node:https';
import { randomBytes } from 'node:crypto';

if (typeof WebSocket === 'undefined') {
  const r = spawnSync(
    process.execPath,
    ['--experimental-websocket', fileURLToPath(import.meta.url), ...process.argv.slice(2)],
    { stdio: 'inherit' },
  );
  process.exit(r.status ?? 1);
}

const execFileP = promisify(execFile);
const BASE = process.env.PROBE_BASE || 'https://room.tokkah.com';
const RUN = Date.now().toString(36);
const room = (n) => `capacity-probe-${RUN}-${n}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const now = () => performance.now();

const results = { base: BASE, run: RUN, startedAt: new Date().toISOString(), phases: {} };

// ── helpers ─────────────────────────────────────────────────────────────────

function percentile(sorted, q) {
  if (!sorted.length) return null;
  return sorted[Math.min(sorted.length - 1, Math.floor((q / 100) * sorted.length))];
}

function stats(arr) {
  if (!arr.length) return { n: 0 };
  const s = [...arr].sort((a, b) => a - b);
  return {
    n: s.length,
    min: +s[0].toFixed(2),
    p50: +percentile(s, 50).toFixed(2),
    p95: +percentile(s, 95).toFixed(2),
    p99: +percentile(s, 99).toFixed(2),
    max: +s[s.length - 1].toFixed(2),
    mean: +(s.reduce((a, b) => a + b, 0) / s.length).toFixed(2),
  };
}

async function mutexClear() {
  // pgrep exits 1 when nothing matches. execFile without a shell so our own
  // cmdline (which contains the pattern as an argument) is not matched —
  // pgrep also always excludes itself.
  try {
    await execFileP('pgrep', ['-f', 'call\\.mjs|sctpwall\\.mjs|corpus-score\\.mjs']);
    return false;
  } catch (e) {
    if (e.code === 1) return true;
    return true; // pgrep itself failed; don't block measurement on that
  }
}

async function waitMutex(what) {
  process.stdout.write(`[mutex] checking before ${what}... `);
  while (!(await mutexClear())) {
    process.stdout.write(`busy, waiting 5s\n`);
    await sleep(5000);
  }
  process.stdout.write('clear\n');
}

// Connect one probe client. Records welcome + every inbound message timing.
function connect(code, label) {
  return new Promise((resolve, reject) => {
    const t0 = now();
    const ws = new WebSocket(`${BASE}/api/room/${code}/ws`);
    const c = {
      ws,
      label,
      openMs: null,
      welcomeMs: null,
      welcome: null,
      closed: null,
      error: null,
      messages: [],
      maxBuffered: 0,
      onMessage: null, // (parsed, raw, arrivalMs) => void
    };
    const fail = (err) => {
      c.error = String(err?.message || err);
      reject(new Error(`${label}: ${c.error}`));
    };
    ws.addEventListener('open', () => {
      c.openMs = now() - t0;
    });
    ws.addEventListener('message', (e) => {
      const at = now();
      let parsed = null;
      try {
        parsed = JSON.parse(e.data);
      } catch {
        /* non-JSON relay payload */
      }
      c.messages.push({ at, parsed });
      if (!c.welcome && parsed?.type === 'welcome') {
        c.welcome = parsed;
        c.welcomeMs = at - t0;
        resolve(c);
      }
      if (c.onMessage) c.onMessage(parsed, e.data, at);
    });
    ws.addEventListener('error', (e) => {
      if (!c.welcome) fail(e.message || 'ws error');
      else c.error = c.error || String(e.message || 'ws error');
    });
    ws.addEventListener('close', (e) => {
      c.closed = { code: e.code, reason: e.reason, at: now() };
      if (!c.welcome) fail(`closed before welcome (${e.code})`);
    });
    setTimeout(() => {
      if (!c.welcome) fail('welcome timeout (10s)');
    }, 10_000);
  });
}

function send(c, obj) {
  const s = typeof obj === 'string' ? obj : JSON.stringify(obj);
  c.ws.send(s);
  if (c.ws.bufferedAmount > c.maxBuffered) c.maxBuffered = c.ws.bufferedAmount;
  return s.length;
}

function closeAll(clients) {
  for (const c of clients) {
    try {
      if (c.ws.readyState === WebSocket.OPEN || c.ws.readyState === WebSocket.CONNECTING)
        c.ws.close(1000, 'probe done');
    } catch {
      /* already gone */
    }
  }
}

// Raw HTTP(S) GET, no upgrade. Used for preflight and for the 409-cap check
// (a rejected upgrade is a plain HTTP response; undici's WebSocket API does
// not expose the failure status, so we read it at the HTTP layer).
function httpGet(url, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, { headers }, (res) => {
      let body = '';
      res.on('data', (d) => (body += d));
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });
    req.on('error', reject);
    req.setTimeout(10_000, () => {
      req.destroy(new Error('timeout'));
    });
  });
}

// ── phase 0: preflight ──────────────────────────────────────────────────────

async function phase0() {
  const page = await httpGet(`${BASE}/`);
  let ice = null;
  try {
    // /api/ice now requires browser fetch metadata (worker hardening, task
    // #32): no Sec-Fetch-Site / same-origin Referer → 403. Send what Chrome
    // sends so the preflight measures the real minting path.
    ice = await httpGet(`${BASE}/api/ice`, { 'sec-fetch-site': 'same-origin' });
    const j = JSON.parse(ice.body);
    // TURN credentials are server-minted secrets: record shape only, never values.
    ice = {
      status: ice.status,
      p2pOnly: j.p2pOnly,
      iceServerCount: Array.isArray(j.iceServers) ? j.iceServers.length : 0,
      hasCredentials: Array.isArray(j.iceServers) && j.iceServers.some((s) => s.credential),
    };
  } catch (e) {
    ice = { error: String(e.message || e) };
  }
  results.phases.preflight = { pageStatus: page.status, ice };
  console.log(`[p0] page=${page.status} ice=${JSON.stringify(ice)}`);
}

// ── phase 1: admission timing ───────────────────────────────────────────────

async function phase1() {
  const rooms = [];
  for (let i = 0; i < 8; i++) {
    const code = room(i);
    const a = await connect(code, `p1-${i}-a`);
    const b = await connect(code, `p1-${i}-b`);
    // A should have been told about B's arrival. The DO sends peer-joined to A
    // in the same handler as B's welcome, but it still has a network hop to
    // cross — give it a moment before judging.
    await sleep(500);
    const joined = a.messages.find((m) => m.parsed?.type === 'peer-joined');
    rooms.push({
      code,
      a: { openMs: +a.openMs.toFixed(1), welcomeMs: +a.welcomeMs.toFixed(1), role: a.welcome.role, peerPresentAtWelcome: a.welcome.peerPresent, epoch: a.welcome.session_epoch_us },
      b: { openMs: +b.openMs.toFixed(1), welcomeMs: +b.welcomeMs.toFixed(1), role: b.welcome.role, peerPresentAtWelcome: b.welcome.peerPresent, epoch: b.welcome.session_epoch_us },
      aSawPeerJoined: !!joined,
      epochMatch: a.welcome.session_epoch_us === b.welcome.session_epoch_us,
    });
    closeAll([a, b]);
    await sleep(400); // gentle pacing between cold-DO creations
  }

  // Concurrent burst: 4 rooms x 2 peers admitted at the same instant.
  await sleep(1000);
  const burstRooms = [room('b0'), room('b1'), room('b2'), room('b3')];
  const burst = await Promise.all(
    burstRooms.flatMap((code) => [connect(code, `burst-${code}-a`), connect(code, `burst-${code}-b`)]),
  );
  const burstOpen = burst.map((c) => +c.openMs.toFixed(1));
  const burstWelcome = burst.map((c) => +c.welcomeMs.toFixed(1));
  closeAll(burst);

  results.phases.admission = {
    sequential: rooms,
    aWelcomeMs: stats(rooms.map((r) => r.a.welcomeMs)),
    bWelcomeMs: stats(rooms.map((r) => r.b.welcomeMs)),
    aOpenMs: stats(rooms.map((r) => r.a.openMs)),
    bOpenMs: stats(rooms.map((r) => r.b.openMs)),
    allEpochsMatch: rooms.every((r) => r.epochMatch),
    allSawPeerJoined: rooms.every((r) => r.aSawPeerJoined),
    burst: { openMs: stats(burstOpen), welcomeMs: stats(burstWelcome), n: burst.length },
  };
  const p = results.phases.admission;
  console.log(
    `[p1] cold-DO admission over 8 rooms: A welcome ${JSON.stringify(p.aWelcomeMs)}, B welcome ${JSON.stringify(p.bWelcomeMs)}`,
  );
  console.log(
    `[p1] burst(8 sockets at once): open p50=${p.burst.openMs.p50} p95=${p.burst.openMs.p95}; epochs match=${p.allEpochsMatch}, peer-joined seen=${p.allSawPeerJoined}`,
  );
  return rooms[0].code; // reused in phase 5 for the epoch-persistence check
}

// ── phase 2: occupancy cap (the designed knee: 2 occupants) ────────────────

async function phase2() {
  const code = room('cap');
  const a = await connect(code, 'cap-a');
  const b = await connect(code, 'cap-b');

  // Third joiner at the HTTP layer, where the rejection status is readable.
  // The key must be a real 16-byte Sec-WebSocket-Key: Cloudflare's edge 400s
  // a malformed handshake before the request ever reaches the DO, which would
  // masquerade as a rejection from the room (it did, in the rehearsal run).
  const key = randomBytes(16).toString('base64');
  const third = await httpGet(`${BASE}/api/room/${code}/ws`, {
    connection: 'Upgrade',
    upgrade: 'websocket',
    'sec-websocket-key': key,
    'sec-websocket-version': '13',
  });

  // The occupants must be untouched: one echo round-trip through the relay.
  const rtt = await echoOnce(a, b, 'cap-check');
  closeAll([a, b]);

  results.phases.occupancyCap = {
    thirdJoinStatus: third.status,
    thirdJoinBody: third.body.slice(0, 64),
    relayAliveAfterRejection: Number.isFinite(rtt),
    echoRttMs: Number.isFinite(rtt) ? +rtt.toFixed(1) : null,
  };
  console.log(`[p2] third join -> HTTP ${third.status} "${third.body.trim()}"; relay alive after: ${Number.isFinite(rtt)} (rtt ${rtt?.toFixed?.(1)} ms)`);
}

// One tagged ping A->B, echoed B->A. Returns RTT ms or NaN on timeout.
function echoOnce(a, b, tag, timeoutMs = 5000) {
  return new Promise((resolve) => {
    const id = `${tag}-${Math.random().toString(36).slice(2, 8)}`;
    const t0 = now();
    const timer = setTimeout(() => {
      b.onMessage = null;
      resolve(NaN);
    }, timeoutMs);
    b.onMessage = (p) => {
      if (p?.type === 'probe-ping' && p.id === id) send(b, { type: 'probe-echo', id, t0: p.t0 });
    };
    const prevA = a.onMessage;
    a.onMessage = (p) => {
      if (prevA) prevA(p);
      if (p?.type === 'probe-echo' && p.id === id) {
        clearTimeout(timer);
        b.onMessage = null;
        a.onMessage = prevA;
        resolve(now() - t0);
      }
    };
    send(a, { type: 'probe-ping', id, t0 });
  });
}

// ── phase 3: relay latency under ctl load, ramped tiers ────────────────────

const pad1k = 'x'.repeat(980); // ~1 KB once wrapped in JSON

async function phase3() {
  const code = room('relay');
  const a = await connect(code, 'relay-a');
  const b = await connect(code, 'relay-b');

  // B echoes every probe-ping; everything else (probe-load) is just relayed.
  b.onMessage = (p) => {
    if (p?.type === 'probe-ping') send(b, { type: 'probe-echo', id: p.id, t0: p.t0 });
  };

  const pending = new Map();
  const rtts = [];
  let echoLost = 0;
  a.onMessage = (p) => {
    if (p?.type === 'probe-echo' && pending.has(p.id)) {
      rtts.push(now() - pending.get(p.id));
      pending.delete(p.id);
    }
  };

  // 1 Hz ping prober, always on.
  let pingSeq = 0;
  const pingTimer = setInterval(() => {
    const id = `p${pingSeq++}`;
    pending.set(id, now());
    send(a, { type: 'probe-ping', id, t0: now() });
    // expire stale pings as lost after 3 s
    setTimeout(() => {
      if (pending.delete(id)) echoLost++;
    }, 3000);
  }, 1000);

  // Background load from BOTH directions (each peer's load is relayed to the
  // other, so the DO forwards 2x the per-peer rate).
  let loadTimer = null;
  let loadSentA = 0;
  let loadSentB = 0;
  const setLoad = (perPeerPerSec, bytes) => {
    if (loadTimer) clearInterval(loadTimer);
    loadTimer = null;
    if (!perPeerPerSec) return;
    const interval = 1000 / perPeerPerSec;
    const payload = { type: 'probe-load', pad: pad1k.slice(0, Math.max(0, bytes - 40)) };
    loadTimer = setInterval(() => {
      loadSentA += send(a, { ...payload, seq: loadSentA }) ? 1 : 0;
      loadSentB += send(b, { ...payload, seq: loadSentB }) ? 1 : 0;
    }, interval);
  };

  const tiers = [
    { name: 'T0-idle', rate: 0, bytes: 0, durS: 15 },
    { name: 'T1-design-1x1KB', rate: 1, bytes: 1024, durS: 20 }, // §14 design point: ~1 KB/s control per direction
    { name: 'T2-5x1KB', rate: 5, bytes: 1024, durS: 20 },
    { name: 'T3-20x1KB', rate: 20, bytes: 1024, durS: 20 },
    { name: 'T4-50x1KB', rate: 50, bytes: 1024, durS: 20 }, // knee watch: ~100 KB/s aggregate relay
    { name: 'T5-2x8KB-sdp', rate: 2, bytes: 8192, durS: 12 }, // SDP-sized signaling burst
  ];

  const out = [];
  let baseP95 = null;
  let knee = null;

  for (const t of tiers) {
    const rttStart = rtts.length;
    const lostStart = echoLost;
    const a0 = loadSentA;
    const b0 = loadSentB;
    setLoad(t.rate, t.bytes);
    const tStart = now();
    let abort = null;

    while (now() - tStart < t.durS * 1000) {
      await sleep(250);
      if (a.closed || b.closed || a.error || b.error) {
        abort = `socket failure: a.closed=${!!a.closed} b.closed=${!!b.closed} a.err=${a.error} b.err=${b.error}`;
        break;
      }
    }

    const tierRtts = rtts.slice(rttStart);
    const s = stats(tierRtts);
    const rec = {
      tier: t.name,
      offeredPerPeerMsgS: t.rate,
      msgBytes: t.bytes,
      pings: tierRtts.length,
      echoesLost: echoLost - lostStart,
      loadSentA: loadSentA - a0,
      loadSentB: loadSentB - b0,
      rttMs: s,
      maxBufferedA: a.maxBuffered,
      maxBufferedB: b.maxBuffered,
      aborted: abort,
    };
    if (t.name === 'T0-idle') baseP95 = s.p95;
    if (!abort && baseP95 && s.p95 > 3 * baseP95) {
      rec.kneeSign = `p95 ${s.p95} > 3x baseline ${baseP95}`;
      knee = rec.kneeSign;
    }
    if (rec.echoesLost > 0 && !knee) {
      knee = `${rec.echoesLost} echoes lost in ${t.name}`;
      rec.kneeSign = knee;
    }
    out.push(rec);
    console.log(
      `[p3] ${t.name}: n=${s.n} rtt p50=${s.p50} p95=${s.p95} p99=${s.p99} max=${s.max} lost=${rec.echoesLost} bufA=${a.maxBuffered} bufB=${b.maxBuffered}${abort ? ' ABORT: ' + abort : ''}${rec.kneeSign ? ' KNEE: ' + rec.kneeSign : ''}`,
    );
    if (abort || rec.kneeSign) {
      knee = knee || abort;
      break; // stop at the FIRST sign of degradation
    }
    setLoad(0, 0);
    await sleep(3000); // recovery gap between tiers
  }

  clearInterval(pingTimer);
  setLoad(0, 0);
  const alive = !a.closed && !b.closed;
  closeAll([a, b]);

  results.phases.relayTiers = { tiers: out, baselineP95Ms: baseP95, knee, socketsAliveAtEnd: alive };
  console.log(`[p3] knee: ${knee || `none up to ${out[out.length - 1].tier}`}; sockets alive at end: ${alive}`);
}

// ── phase 4: room-count scaling (the design's real axis: one DO per room) ──

async function phase4() {
  await waitMutex('parallel-room phase');
  const N = 6;
  const pairs = [];
  for (let i = 0; i < N; i++) {
    const code = room(`par${i}`);
    const a = await connect(code, `par${i}-a`);
    const b = await connect(code, `par${i}-b`);
    pairs.push({ code, a, b });
  }

  // Every pair: 1 Hz echo ping (i->peer->back) + design-point load 1/s x 1 KB each way.
  const perRoom = pairs.map(() => ({ rtts: [], lost: 0 }));
  pairs.forEach(({ a, b }, i) => {
    const pending = new Map();
    b.onMessage = (p) => {
      if (p?.type === 'probe-ping') send(b, { type: 'probe-echo', id: p.id });
    };
    a.onMessage = (p) => {
      if (p?.type === 'probe-echo' && pending.has(p.id)) {
        perRoom[i].rtts.push(now() - pending.get(p.id));
        pending.delete(p.id);
      }
    };
    let seq = 0;
    pairs[i].timers = [
      setInterval(() => {
        const id = `par${i}-${seq++}`;
        pending.set(id, now());
        send(a, { type: 'probe-ping', id });
        setTimeout(() => {
          if (pending.delete(id)) perRoom[i].lost++;
        }, 3000);
      }, 1000),
      setInterval(() => {
        send(a, { type: 'probe-load', pad: pad1k });
        send(b, { type: 'probe-load', pad: pad1k });
      }, 1000),
    ];
  });

  await sleep(20_000);
  const roomsOut = pairs.map((p, i) => {
    p.timers.forEach(clearInterval);
    return { code: p.code, rttMs: stats(perRoom[i].rtts), echoesLost: perRoom[i].lost, closed: !!(p.a.closed || p.b.closed) };
  });
  closeAll(pairs.flatMap((p) => [p.a, p.b]));

  const all = perRoom.flatMap((r) => r.rtts);
  results.phases.roomScaling = {
    rooms: N,
    perRoom: roomsOut,
    aggregate: stats(all),
    totalEchoesLost: perRoom.reduce((s, r) => s + r.lost, 0),
  };
  const agg = results.phases.roomScaling.aggregate;
  console.log(
    `[p4] ${N} rooms x 2 occupants at design load: aggregate echo RTT p50=${agg.p50} p95=${agg.p95} max=${agg.max}, lost=${results.phases.roomScaling.totalEchoesLost}, any closed=${roomsOut.some((r) => r.closed)}`,
  );
}

// ── phase 5: epoch persistence + sentinel aliveness ────────────────────────

async function phase5(firstRoomCode, firstEpoch, sentinel) {
  // The phase-1 room has sat idle (no sockets) for the whole run — the DO has
  // very likely been evicted from memory. Reconnect and check the epoch.
  const re = await connect(firstRoomCode, 'epoch-recheck');
  const epochPersisted = re.welcome.session_epoch_us === firstEpoch;
  closeAll([re]);

  const sentinelAlive = sentinel ? !sentinel.a.closed && !sentinel.b.closed && !sentinel.a.error && !sentinel.b.error : null;
  let sentinelRtt = null;
  if (sentinel && sentinelAlive) {
    sentinelRtt = await echoOnce(sentinel.a, sentinel.b, 'sentinel-final');
    closeAll([sentinel.a, sentinel.b]);
  }

  results.phases.persistence = {
    room: firstRoomCode,
    epochAtFirstJoin: firstEpoch,
    epochAfterIdleEviction: re.welcome.session_epoch_us,
    persisted: epochPersisted,
    sentinelAliveAfterWholeRun: sentinelAlive,
    sentinelFinalEchoRttMs: Number.isFinite(sentinelRtt) ? +sentinelRtt.toFixed(1) : null,
  };
  console.log(
    `[p5] epoch persisted across idle eviction: ${epochPersisted} (${firstEpoch}); sentinel alive: ${sentinelAlive}, final echo rtt=${sentinelRtt?.toFixed?.(1)} ms`,
  );
}

// Sentinel: one quiet room (1 Hz ping only) held open across the whole run,
// proving the DO does not idle-timeout open websockets.
async function openSentinel() {
  const code = room('sentinel');
  const a = await connect(code, 'sentinel-a');
  const b = await connect(code, 'sentinel-b');
  const timer = setInterval(() => {
    try {
      send(a, { type: 'probe-ping', id: 'sentinel', t0: now() });
    } catch {
      /* recorded via close/error */
    }
  }, 1000);
  b.onMessage = () => {};
  a.onMessage = () => {};
  return { a, b, timer };
}

// ── main ────────────────────────────────────────────────────────────────────

async function main() {
  await waitMutex('probe start');
  await phase0();

  const firstCode = await phase1();
  // Look up the epoch phase 1 recorded for that room.
  const firstEpoch = results.phases.admission.sequential.find((r) => r.code === firstCode)?.a.epoch;

  const sentinel = await openSentinel();

  await phase2();
  await phase3();
  await phase4();

  clearInterval(sentinel.timer);
  await phase5(firstCode, firstEpoch, sentinel);

  results.finishedAt = new Date().toISOString();
  const dir = fileURLToPath(new URL('./runs/', import.meta.url));
  mkdirSync(dir, { recursive: true });
  const out = `${dir}lobby-probe-${RUN}.json`;
  writeFileSync(out, JSON.stringify(results, null, 2));
  console.log(`\n[done] full results: ${out}`);
}

main().catch((e) => {
  console.error('[fatal]', e);
  results.fatal = String(e.stack || e);
  process.exitCode = 1;
});
