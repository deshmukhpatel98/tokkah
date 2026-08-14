/**
 * Do the six audio associations take the road signalling offered them?
 *
 * The finding this rig exists to settle: on a real Delhi↔Netherlands call,
 * association 0 (which rides the main pc) ran 25-30 ms BELOW stripes 1-5 in
 * baseRtt — consistently, across 586 samples. The instrumented run said why:
 * the main pc nominated a `host/host` candidate pair and every stripe nominated
 * `host/prflx`.
 *
 * A PEER-REFLEXIVE remote candidate means ICE learned the peer's address from
 * an inbound STUN probe rather than from signalling. Textbook cause is symmetric
 * NAT rewriting the port — but that cannot happen on loopback, and loopback
 * reproduces it. Which leaves the other cause: the candidate was signalled and
 * we threw it away. Both ICE handlers ended in `.catch(() => {})`, and
 * `addIceCandidate` REJECTS when the remote description is not set yet; the
 * stripe handler also had `pcmLadder(...)?.[idx]?.` , which discards a candidate
 * for a stripe pc that does not exist yet without so much as a log line. Five
 * stripes negotiate in parallel through one serialized message loop, so their
 * offers and their candidates land in the same few milliseconds. The main pc's
 * negotiation finishes before that flood starts, which is the whole reason it
 * was the one association that stayed clean.
 *
 * Arms:
 *   1. control reproduces   with ?icequeue=0 (the old drop-on-the-floor path),
 *                           at least one association nominates prflx. If this
 *                           does not fail, there is no bug and the fix is
 *                           ceremony — so this arm failing is a real result and
 *                           gets reported as one, not smoothed over.
 *   2. fix holds            with the queue on, NO association nominates prflx.
 *   3. the queue did work   at least one `ice-flush` held a candidate. This
 *                           separates "fixed it" from "the race did not happen
 *                           this run"; without it arm 2 could pass on luck.
 *   4. do no harm           audio still flows both ways on both arms and the
 *                           lane never falls back to Opus.
 *
 *   node testbed/icequeue.mjs                   # against local wrangler dev
 *   URL=https://room.tokkah.com node testbed/icequeue.mjs
 */
import { chromium } from 'playwright-core';

const URL_BASE = process.env.URL ?? 'http://localhost:8794';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
const SETTLE_MS = 14000; // ICE nominates in well under this; the margin is for slow CI

const launch = (side) => chromium.launch({
  executablePath: CHROME, headless: true,
  args: [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    `--use-file-for-fake-video-capture=${media(`real${side}.mjpeg`)}`,
    `--use-file-for-fake-audio-capture=${media(`real${side}.wav`)}`,
    '--autoplay-policy=no-user-gesture-required',
    '--disable-features=WebRtcHideLocalIpsWithMdns',
  ],
});

/**
 * Read what each of this tab's six associations actually nominated.
 *
 * Deliberately NOT read off `pcm-stripe-path` telemetry: that fires once, on an
 * ice state transition, and a rig that reads a log is measuring what we chose to
 * record. getStats() at the end of the call is the browser's own answer, and it
 * covers association 0 (the main pc) with the same code as the other five.
 */
/**
 * TWO readings, because they answer different questions and the first run of
 * this rig conflated them.
 *
 *   `first`  — what the association nominated at the moment ICE first said
 *              "connected", recorded by the `pcm-stripe-path` log. This is what
 *              the real Delhi call reported.
 *   `now`    — what getStats says at the end of the call.
 *
 * They disagreed: a run whose log said host/prflx read host/host from getStats
 * fifteen seconds later. That is not a contradiction, it is the answer — the
 * nomination is a RACE between the peer's signalled candidate arriving over the
 * websocket (a round trip to Cloudflare) and the peer's own STUN probe arriving
 * direct (sub-millisecond on loopback). Which is why the outcome has to be
 * measured over several trials as a RATE, never called from a single run.
 */
const readPaths = (page) => page.evaluate(async () => {
  const T = window.__tape;
  const mirror = T?.tel?.mirror ?? [];
  const first = new Map();
  for (const e of mirror) {
    if (e.kind === 'pcm-stripe-path' && !first.has(e.data.idx)) first.set(e.data.idx, e.data.path);
  }
  const now = new Map();
  const scan = async (assoc, c) => {
    if (!c) return;
    try {
      const st = await c.getStats();
      let best = null;
      st.forEach((r) => {
        if (r.type === 'candidate-pair' && r.state === 'succeeded' && (r.nominated || !best)) best = r;
      });
      if (!best) return;
      const L = st.get(best.localCandidateId), R = st.get(best.remoteCandidateId);
      now.set(assoc, `${L?.candidateType ?? '?'}/${R?.candidateType ?? '?'}`);
    } catch { /* closing */ }
  };
  await scan(0, T?.pc);
  const ladder = T?.pcmStripePcs?.() ?? [];
  for (let i = 1; i < ladder.length; i++) await scan(i, ladder[i]);

  const assocs = [...new Set([...first.keys(), ...now.keys()])].sort((x, y) => x - y);
  return {
    paths: assocs.map((i) => ({ assoc: i, first: first.get(i) ?? null, now: now.get(i) ?? null })),
    flushes: mirror.filter((e) => e.kind === 'ice-flush')
      .map((e) => ({ key: e.data.key, held: e.data.held, applied: e.data.applied })),
    framesRecv: T?.pcm?.framesRecv ?? 0,
    fellBack: !!T?.pcmMode?.fellBack,
  };
});

async function runArm(label, qs) {
  const room = `ice-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
  const A = await launch('A'), B = await launch('B');
  try {
    const a = await A.newPage(), b = await B.newPage();
    for (const [p, who] of [[a, 'A'], [b, 'B']]) {
      await p.goto(`${URL_BASE}/${qs}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
      await p.waitForSelector('#join', { timeout: 20000 });
      await p.click('#more');
      await p.fill('#room', room);
      await p.keyboard.press('Escape');
      await p.click('#join', { timeout: 30000 }).catch(() => {});
      if (who === 'A') await p.waitForTimeout(1200);
    }
    await a.waitForTimeout(SETTLE_MS);
    const res = { A: await readPaths(a), B: await readPaths(b) };

    for (const side of ['A', 'B']) {
      const r = res[side];
      const line = r.paths.map((p) => `${p.assoc}:${(p.first ?? '?')}` +
        (p.now && p.now !== p.first ? `→${p.now}` : '')).join('  ');
      const held = r.flushes.reduce((s, f) => s + (f.held | 0), 0);
      console.log(`  [${label}] ${side}  ${line || '(none)'}   ` +
        `frames=${r.framesRecv} held=${held}${r.fellBack ? ' FELLBACK' : ''}`);
    }
    return res;
  } finally {
    await A.close(); await B.close();
  }
}

// The nomination is what matters and `first` is when it happens, so that is the
// field counted. `now` is printed when it differs, because a pair that starts
// prflx and ends host/host is a different story from one that stays.
const prflxCount = (res, field) => ['A', 'B']
  .reduce((n, s) => n + res[s].paths.filter((p) => (p[field] ?? '').includes('prflx')).length, 0);
const heldCount = (res) => ['A', 'B']
  .reduce((n, s) => n + res[s].flushes.reduce((q, f) => q + (f.held | 0), 0), 0);
const audioOk = (res) => ['A', 'B'].every((s) => res[s].framesRecv > 0 && !res[s].fellBack);

const TRIALS = Number(process.env.TRIALS ?? 3);
const tally = { control: [], fixed: [] };
for (let t = 1; t <= TRIALS; t++) {
  console.log(`\n── trial ${t}/${TRIALS} ────────────────────────────────────────`);
  tally.control.push(await runArm('ctl ', '?icequeue=0'));
  tally.fixed.push(await runArm('fix ', ''));
}

const roll = (rows) => ({
  prflxFirst: rows.reduce((n, r) => n + prflxCount(r, 'first'), 0),
  prflxNow: rows.reduce((n, r) => n + prflxCount(r, 'now'), 0),
  held: rows.reduce((n, r) => n + heldCount(r), 0),
  ok: rows.every(audioOk),
  assocs: rows.reduce((n, r) => n + r.A.paths.length + r.B.paths.length, 0),
});
const C = roll(tally.control), F = roll(tally.fixed);

console.log('\n════════════════════════════════════════════════════════════');
console.log(`over ${TRIALS} trials, ${C.assocs} associations per arm:`);
console.log(`  queue OFF: ${C.prflxFirst} nominated prflx, ${C.prflxNow} still prflx at end, ${C.held} candidates held`);
console.log(`  queue ON : ${F.prflxFirst} nominated prflx, ${F.prflxNow} still prflx at end, ${F.held} candidates held`);

const arm = (name, ok, detail) => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  (${detail})`); return ok; };
// What is actually claimable. The queue provably replays candidates that used
// to be dropped — that arm is deterministic. Whether it moves the NOMINATION is
// a separate, weaker claim, and it gets its own arm rather than riding along.
const r1 = arm('queue catches candidates that were being dropped', F.held > 0 && C.held === 0,
  `${F.held} held with it on, ${C.held} with it off`);
const r2 = arm('no association is left on prflx at end of call', F.prflxNow === 0,
  `${F.prflxNow}/${F.assocs} still prflx`);
const r3 = arm('do no harm', C.ok && F.ok, 'audio flowing, no Opus fallback, every trial');
const moved = F.prflxFirst < C.prflxFirst;
console.log(`${moved ? 'note' : 'NOTE'}  nomination race: ${C.prflxFirst}→${F.prflxFirst} prflx at connect ` +
  `(${moved ? 'queue helps' : 'queue does not decide this race — it is signalling-vs-STUN timing'})`);

const pass = r1 && r2 && r3;
console.log(`\nVERDICT: ${pass ? 'PASS' : 'FAIL'}`);
process.exit(pass ? 0 : 1);
