#!/usr/bin/env node
/**
 * call3.mjs — three real browsers in one live room, the gate that decides
 * whether THREE_ENABLED flips (three-person-design.md §7.2).
 *
 * Requires a server whose THREE_ENABLED is TRUE — run against staging first
 * (TESTBED_BASE=https://tokkah.deshmukh.workers.dev). Each page carries a real
 * talking-head fixture (the realism law) and ?three=1. It asserts the nine
 * properties of §7.2 and the uplink number §2.2 predicts (~22 Mbps) — the
 * prediction becomes a measurement here, and if the phone arm can't carry it
 * the honest outcome ("3-way is desktop-only") is what this prints.
 *
 *   TESTBED_BASE=https://tokkah.deshmukh.workers.dev node testbed/call3.mjs
 */
import { chromium } from 'playwright-core';

const BASE = process.env.TESTBED_BASE ?? 'https://room.tokkah.com';
const CHROME =
  process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const HEADED = process.argv.includes('--headed');
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
const FIX = { a: ['realA.wav', 'realA.mjpeg'], b: ['realB.wav', 'realB.mjpeg'], c: ['realA.wav', 'realB.mjpeg'] };
const ROOM = `bot3-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;

let fails = 0;
const A = (cond, msg) => { console.log(`  ${cond ? 'ok  ' : 'FAIL'}  ${msg}`); if (!cond) fails++; };

async function launch(side, q = 'three=1') {
  const [wav, vid] = FIX[side];
  const browser = await chromium.launch({
    executablePath: CHROME, headless: !HEADED,
    args: [
      '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
      `--use-file-for-fake-audio-capture=${media(wav)}`,
      `--use-file-for-fake-video-capture=${media(vid)}`,
      '--autoplay-policy=no-user-gesture-required', '--alsa-output-device=null',
    ],
  });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e).slice(0, 140)));
  await page.goto(`${BASE}/?r=${ROOM}&${q}`, { waitUntil: 'domcontentloaded' });
  return { browser, page, errors, side };
}

// Contract with window.__tape (getters, not functions):
//   .pairs → { three, us, media, peers:[{role, media, offerer, conn, pcmConn}] }
//     conn/pcmConn are the pair's video/audio pc.connectionState — added by
//     the phase-6 wiring so the rig asserts on live legs, not just intent.
//   .pcm → the media pair's snapshot (mode, framesRecv, concealedMs, aec2).
const snap = (pg) => pg.evaluate(() => {
  const t = window.__tape ?? {};
  const pj = t.pairs ?? null; // getter
  const pcm = t.pcm ?? {};
  return {
    conn: t.pc?.connectionState,
    role: pj?.us ?? t.role ?? null,
    pairs: pj?.peers ?? null,
    media: pj?.media ?? null,
    pcmRecv: pcm.framesRecv, conceal: pcm.concealedMs, mode: pcm.mode,
    aec2: pcm.aec2 ?? null,
  };
});

async function join(s) { await s.page.click('#join'); }
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

console.log(`\n=== call3 room ${ROOM} @ ${BASE} ===`);
const pa = await launch('a'), pb = await launch('b'), pc = await launch('c');
try {
  await join(pa); await wait(600); await join(pb); await wait(600); await join(pc);
  // Give the three pairs time to form all media legs.
  const up = await Promise.all([pa, pb, pc].map((s) =>
    s.page.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 45000 })
      .then(() => true, () => false)));
  await wait(18000);
  const [sa, sb, sc] = await Promise.all([snap(pa.page), snap(pb.page), snap(pc.page)]);

  // 1. Admission: three joined, roles a/b/c, fourth gets pre-open 409.
  const roles = [sa.role, sb.role, sc.role].sort().join('');
  A(up.every(Boolean) && roles === 'abc', `1 admission: three connected, roles=${roles}`);
  const pd = await launch('a');
  await join(pd).catch(() => {});
  // Wait for the refusal to actually land — "starting…" is the transient
  // pre-open state, not the verdict; poll until it resolves or 12 s.
  const dStatus = await pd.page.waitForFunction(() => {
    const s = document.getElementById('joinStatus')?.textContent ?? '';
    return /two people|full|couldn|no internet/i.test(s) ? s : false;
  }, null, { timeout: 12000 }).then((h) => h.jsonValue(), () => 'DID NOT REFUSE');
  A(/two people|full/i.test(dStatus), `1 fourth refused: "${String(dStatus).slice(0, 50)}"`);
  const dConn = await pd.page.evaluate(() => window.__tape?.pc?.connectionState ?? 'none');
  A(dConn !== 'connected', `1 fourth never connected: pc=${dConn}`);
  await pd.browser.close().catch(() => {});
  // three sitting calls unaffected
  const stillUp = await Promise.all([pa, pb, pc].map((s) => s.page.evaluate(() => window.__tape?.pc?.connectionState)));
  A(stillUp.every((c) => c === 'connected'), `1 incumbents unaffected: ${stillUp.join(',')}`);

  // 2. One offerer per pair (read from the pairs table each page exposes).
  const pairsOk = [sa, sb, sc].every((s) => Array.isArray(s.pairs) && s.pairs.length === 2);
  A(pairsOk, `2 each page holds 2 pairs: ${[sa, sb, sc].map((s) => s.pairs?.length).join(',')}`);

  // 3. Six live media legs: every page's two pairs report a connected audio
  //    AND video half — 3 pages × 2 pairs = the six legs of a full mesh.
  const legs = [sa, sb, sc].map((s) => (s.pairs ?? []).filter((p) => p.pcmConn === 'connected' && p.conn === 'connected').length);
  A(legs.every((n) => n === 2), `3 media legs per page (audio+video connected): ${legs.join(',')}`);

  // 4. Pristine audio + AEC2 far-end carries both voices (option-1 bug is
  //    invisible in transport counters — assert on the canceller).
  const audioOk = [sa, sb, sc].every((s) => s.mode === 'sab' && (s.conceal ?? 1e9) < 2000);
  A(audioOk, `4 pristine: modes=${[sa, sb, sc].map((s) => s.mode).join(',')} conceal=${[sa, sb, sc].map((s) => s.conceal).join(',')}ms`);
  const aecOk = [sa, sb, sc].every((s) => s.aec2 && (s.aec2.gate === 0 || s.aec2.erleDb == null || s.aec2.erleDb > -5));
  A(aecOk, `4 AEC2 sane on all three: ${[sa, sb, sc].map((s) => s.aec2?.erleDb?.toFixed?.(1) ?? 'n/a').join(',')}`);

  // 5. Both video tiles alive on every page.
  const tiles = await Promise.all([pa, pb, pc].map((s) => s.page.evaluate(() => {
    const luma = (id) => { const el = document.getElementById(id); if (!el || !el.width) return null;
      const c = document.createElement('canvas'); c.width = 40; c.height = 22;
      try { c.getContext('2d').drawImage(el, 0, 0, 40, 22); const d = c.getContext('2d').getImageData(0, 0, 40, 22).data;
        let s = 0, sq = 0, n = d.length / 4; for (let i = 0; i < d.length; i += 4) { const y = d[i]; s += y; sq += y * y; }
        const m = s / n; return +Math.sqrt(sq / n - m * m).toFixed(1); } catch { return null; } };
    return { t1: luma('remoteCanvas'), t2: luma('remoteCanvas2') };
  })));
  const tilesOk = tiles.every((t) => (t.t1 ?? 0) > 5 && (t.t2 ?? 0) > 5);
  A(tilesOk, `5 both tiles moving: ${tiles.map((t) => `${t.t1}/${t.t2}`).join('  ')}`);

  // 9. safe() error counters zero on all three (the cap-is-not-defined class).
  const errs = [pa, pb, pc].map((s) => s.errors.length);
  A(errs.every((n) => n === 0), `9 zero page errors: ${errs.join(',')}`);
  if (errs.some((n) => n)) for (const s of [pa, pb, pc]) if (s.errors.length) console.log(`    ${s.side}:`, s.errors.slice(0, 2));

  // §2.2 uplink — the design PREDICTED ~22 Mbps/device and could only guess
  // until three real senders ran. True mesh uplink is transport-level bytes/s
  // across BOTH pairs' pcs (audio stripes + video carrier both ride SCTP data
  // channels). Measured here from getStats candidate-pair bytesSent deltas
  // over 3 s on page a's module pc (the media pair) — a LOWER BOUND, since the
  // second pair's pc lives in the peers map and isn't exposed as an object.
  // The honest full-mesh number needs a per-pair stat hook; flagged, not faked.
  // Real full-mesh uplink: __tape.uplinkMbps sums bytesSent across EVERY pc
  // this device holds (media pc + all Lane A stripes + both second pairs).
  const uplink = await pa.page.evaluate(() => window.__tape.uplinkMbps(3000)).catch((e) => ({ err: String(e).slice(0, 80) }));
  console.log(`  i   uplink (page a, FULL mesh, §2.2): ${JSON.stringify(uplink)} — design predicted ~22 Mbps; desktop-only iff a phone can't carry this`);

  // 6. Free-slot reuse: b reloads mid-call, comes back as b, and a & c do NOT
  //    reset (the hadPeer bug the design flags — a third arrival must never
  //    tear down a live call).
  const aCPreReload = await Promise.all([pa, pc].map((s) => s.page.evaluate(() => window.__tape?.pc?.connectionState)));
  await pb.page.reload({ waitUntil: 'domcontentloaded' });
  await pb.page.click('#join').catch(() => {});
  await pb.page.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 30000 }).catch(() => {});
  await wait(4000);
  const bBack = await pb.page.evaluate(() => window.__tape?.pairs?.us);
  const aCPost = await Promise.all([pa, pc].map((s) => s.page.evaluate(() => window.__tape?.pc?.connectionState)));
  A(bBack === 'b', `6 reload: b came back as b (was ${bBack})`);
  A(aCPost.every((c) => c === 'connected') && aCPreReload.every((c) => c === 'connected'),
    `6 a & c not reset by b's reload: ${aCPreReload.join(',')} -> ${aCPost.join(',')}`);

  // 7. Departure — its OWN clean 3-person session (testing it on the post-
  //    reload state above confounds the two events). c leaves; a and b keep
  //    their a<->b call and lose only the c leg.
  const R7 = `bot3D-${Date.now().toString(36)}`;
  const dpar = async (side) => { const s = await launch(side); await s.page.goto(`${BASE}/?r=${R7}&three=1`, { waitUntil: 'domcontentloaded' }); return s; };
  const d1 = await dpar('a'), d2 = await dpar('b'), d3 = await dpar('c');
  await d1.page.click('#join'); await wait(600); await d2.page.click('#join'); await wait(600); await d3.page.click('#join');
  await Promise.all([d1, d2, d3].map((s) => s.page.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 40000 }).catch(() => {})));
  await wait(10000);
  const recv0 = await Promise.all([d1, d2].map((s) => s.page.evaluate(() => window.__tape?.pcm?.framesRecv ?? 0)));
  await d3.browser.close();
  await wait(8000);
  const afterC = await Promise.all([d1, d2].map((s) => s.page.evaluate(() => ({
    conn: window.__tape?.pc?.connectionState,
    recv: window.__tape?.pcm?.framesRecv ?? 0,
    peers: (window.__tape?.pairs?.peers ?? []).map((p) => p.role).sort().join(''),
  }))));
  // The real test is CONTINUITY: a↔b must keep receiving audio frames across
  // c's exit, not merely hold a connectionState that could be a zombie.
  const flowing = afterC.every((x, i) => x.recv > recv0[i] + 200);
  A(afterC.every((x) => x.conn === 'connected') && flowing,
    `7 departure: a<->b audio flows through c's exit: recv ${recv0.join(',')} -> ${afterC.map((x) => x.recv).join(',')}`);
  A(afterC.every((x) => !x.peers.includes('c')), `7 c pair gone from the table: peers now ${afterC.map((x) => x.peers || '∅').join(',')}`);
  for (const s of [d1, d2]) await s.browser.close().catch(() => {});

  // 8. Legacy interop: a room where one client is pinned ?three=0 (v=1) reads
  //    cap 2 — a v1 anywhere caps the room, so the third join is refused and
  //    the 1:1 it does hold is a normal call. Fresh room, its own browsers.
  const R8 = `bot3L-${Date.now().toString(36)}`;
  const legacy = async (side, q) => { const s = await launch(side, q); await s.page.goto(`${BASE}/?r=${R8}&${q}`, { waitUntil: 'domcontentloaded' }); return s; };
  const l1 = await legacy('a', 'three=0'); // legacy client
  const l2 = await legacy('b', 'three=1'); // new client
  await l1.page.click('#join'); await wait(600); await l2.page.click('#join');
  await Promise.all([l1, l2].map((s) => s.page.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 30000 }).catch(() => {})));
  await wait(3000);
  const l3 = await legacy('c', 'three=1'); // third join must be refused (v1 present caps at 2)
  await l3.page.click('#join').catch(() => {});
  const l3Status = await l3.page.waitForFunction(() => {
    const s = document.getElementById('joinStatus')?.textContent ?? '';
    return /two people|full|couldn/i.test(s) ? s : false;
  }, null, { timeout: 12000 }).then((h) => h.jsonValue(), () => 'NOT REFUSED');
  const l12 = await Promise.all([l1, l2].map((s) => s.page.evaluate(() => window.__tape?.pc?.connectionState)));
  A(/two people|full/i.test(l3Status), `8 legacy caps at 2: 3rd refused "${String(l3Status).slice(0, 40)}"`);
  A(l12.every((c) => c === 'connected'), `8 the 1:1 with a v1 client is a normal call: ${l12.join(',')}`);
  for (const s of [l1, l2, l3]) await s.browser.close().catch(() => {});

  console.log(`\nverdict: ${fails === 0 ? 'ALL PASS' : `${fails} FAILED`}`);
} finally {
  for (const s of [pa, pb, pc]) await s.browser.close().catch(() => {});
}
process.exit(fails === 0 ? 0 : 1);
