/**
 * Is the peer-reflexive pair a WORSE ROAD, or just a differently-labelled one?
 *
 * icequeue.mjs established the shape: on the offerer, stripes 1-5 nominate
 * `host/prflx` while the main pc nominates `host/host`; on the answerer all six
 * are `host/host`. The obvious next move is to make the stripes look like the
 * main pc — but "looks wrong" is not "costs something", and a prflx candidate
 * is only a remote address we learned from an inbound STUN probe instead of
 * from signalling. If the probe came from the same address signalling would
 * have named, the 5-tuple is identical and the label is cosmetic.
 *
 * So this rig does not assume. For every association it dumps EVERY succeeded
 * candidate pair with its address and RTT, not just the nominated one. Three
 * outcomes, and they call for three different responses:
 *
 *   a) the stripe has a host/host pair too, at a LOWER rtt than the nominated
 *      host/prflx  → nomination is choosing badly. Worth fixing, and the fix is
 *      to get the signalled candidate in before the probe lands.
 *   b) the stripe has a host/host pair at the SAME rtt and the same address
 *      → the label is cosmetic; the 25-30 ms on the real call is something
 *      else and this whole lead is a dead end. Say so.
 *   c) no host/host pair exists at all → the signalled candidate never arrived,
 *      which is a signalling bug and points back at the delivery path.
 *
 *   URL=https://room.tokkah.com node testbed/icepairs.mjs
 */
import { chromium } from 'playwright-core';

const URL_BASE = process.env.URL ?? 'https://room.tokkah.com';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);

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

// Expose every stripe pc to the page so getStats can be run against all six
// from one place. __tape.uplinkMbps already walks this exact set internally;
// this asks the page to hand the set over instead of summarising it.
const ALL_PCS = `(() => {
  const T = window.__tape; const out = [];
  if (T?.pc) out.push(['0(main)', T.pc]);
  return out;
})()`;

const dump = (page) => page.evaluate(async () => {
  const T = window.__tape;
  const rows = [];
  const scan = async (label, c) => {
    try {
      const st = await c.getStats();
      const pairs = [];
      st.forEach((r) => {
        if (r.type !== 'candidate-pair' || r.state !== 'succeeded') return;
        const L = st.get(r.localCandidateId), R = st.get(r.remoteCandidateId);
        pairs.push({
          path: `${L?.candidateType ?? '?'}/${R?.candidateType ?? '?'}`,
          remote: `${R?.address ?? '?'}:${R?.port ?? '?'}`,
          local: `${L?.address ?? '?'}:${L?.port ?? '?'}`,
          rttMs: r.currentRoundTripTime != null ? +(r.currentRoundTripTime * 1000).toFixed(2) : null,
          nominated: !!r.nominated,
        });
      });
      rows.push({ assoc: label, pairs });
    } catch { /* closing */ }
  };
  if (T?.pc) await scan('0(main)', T.pc);
  // The stripes: __tape does not hand out the ladder, but uplinkMbps proves the
  // pcs are reachable from module scope. Ask for them through the debug hook
  // added for exactly this measurement.
  const ladder = T?.pcmStripePcs?.() ?? [];
  for (let i = 0; i < ladder.length; i++) if (ladder[i]) await scan(String(i), ladder[i]);
  return rows;
});

const room = `pair-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
const A = await launch('A'), B = await launch('B');
const a = await A.newPage(), b = await B.newPage();
for (const [p, who] of [[a, 'A'], [b, 'B']]) {
  await p.goto(URL_BASE, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await p.waitForSelector('#join', { timeout: 20000 });
  await p.click('#more');
  await p.fill('#room', room);
  await p.keyboard.press('Escape');
  await p.click('#join', { timeout: 30000 }).catch(() => {});
  if (who === 'A') await p.waitForTimeout(1200);
}
await a.waitForTimeout(15000);

let verdictLines = [];
for (const [p, who] of [[a, 'A (offerer)'], [b, 'B (answerer)']]) {
  const rows = await dump(p);
  console.log(`\n═══ ${who} ═══`);
  for (const r of rows) {
    console.log(`  assoc ${r.assoc}:`);
    for (const q of r.pairs) {
      console.log(`    ${q.nominated ? '►' : ' '} ${q.path.padEnd(12)} ` +
        `${q.local} → ${q.remote}  rtt=${q.rttMs ?? '-'}ms`);
    }
    if (!r.pairs.length) console.log('     (no succeeded pairs)');
    // The comparison the whole rig exists for.
    const nom = r.pairs.find((q) => q.nominated) ?? r.pairs[0];
    const hostHost = r.pairs.find((q) => q.path === 'host/host');
    if (nom && nom.path.includes('prflx')) {
      if (!hostHost) verdictLines.push(`${who} assoc ${r.assoc}: prflx nominated, NO host/host pair exists (c: signalling)`);
      else if (hostHost.remote === nom.remote) verdictLines.push(`${who} assoc ${r.assoc}: prflx and host/host are the SAME address (b: cosmetic)`);
      else verdictLines.push(`${who} assoc ${r.assoc}: prflx ${nom.rttMs}ms vs host/host ${hostHost.rttMs}ms, different addresses (a: real)`);
    }
  }
}

console.log('\n════════════════════════════════════════════════════════════');
if (!verdictLines.length) console.log('No prflx pair was nominated anywhere this run.');
else for (const l of verdictLines) console.log('  ' + l);

await A.close(); await B.close();
