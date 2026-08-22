// A/B the §10 A-V synchroniser on a REAL long path.
//
// Why: on a live Delhi <-> US call the rig measured glass-to-glass 7337 ms with
// presentLagP50 6828 ms, while the encoder took 4 ms, every queue was empty and
// the network was 308 ms. The presenter had HELD 3931 frames and presented 12,
// its media-clock offset had re-anchored 830 times, and its estimate of the
// peer's audio-video delta was +908 SECONDS. So the picture was not late
// because of the path, the codec or the queues. It was late because the thing
// that decides when to paint had computed a target in the wrong units of
// reality and was waiting for it.
//
// `?avsync=0` is the documented kill switch (paint on arrival). This measures
// what it is worth on the path where the defect lives.
//
// ARMS ARE ROTATED and every reading is a CUMULATIVE counter read once at the
// end of the arm, never a moving average: a 30 s window read after a 12 s arm
// has previously INVERTED an A/B result in this project.
//
//   ROOM=zzz-avsy-nca ARM_S=100 node testbed/avsync-ab.mjs
import { chromium } from 'playwright-core';

const ROOM = process.env.ROOM ?? 'zzz-avsy-nca';
const ARM_S = Number(process.env.ARM_S || 100);
const BASE = process.env.URL ?? 'https://room.tokkah.com';
const SIDE = (process.env.SIDE ?? 'A').toUpperCase() === 'B' ? 'B' : 'A';
// Rotated, and the OFF arm goes first: if warm-up favours whatever runs later,
// putting the hypothesis' favoured arm first means a win cannot be warm-up.
const ARMS = (process.env.ARMS ?? 'avsync=0,,avsync=0,').split(',');
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);

const READ = async (page) => page.evaluate(async () => {
  const t = window.__tape || {};
  const l = t.lane && t.lane.snapshot ? t.lane.snapshot() : null;
  const p = t.pcm;
  let rtt = null;
  if (t.pc && t.pc.getStats) {
    const st = await t.pc.getStats();
    st.forEach((r) => { if (r.type === 'candidate-pair' && r.state === 'succeeded' && r.currentRoundTripTime != null)
      rtt = Math.round(r.currentRoundTripTime * 1000); });
  }
  if (!l) return { dead: true, conn: t.pc ? t.pc.connectionState : null, pcmUp: !!p };
  return {
    conn: t.pc ? t.pc.connectionState : null, pcmUp: !!p, lane: l.lane, rttMs: rtt,
    g2g: l.glassToGlassMs, presentLagP50: l.presentLagP50, presentLagP95: l.presentLagP95,
    fullAgeP50: l.fullAgeP50, ageP50: l.ageP50, capLagP50: l.capLagP50, encLatP50: l.encLatP50,
    ipiP50: l.ipiP50, achievedFps: l.achievedFps, framesIn: l.framesIn, framesOut: l.framesOut,
    avEngaged: l.avEngaged, avGaveUp: l.avGaveUp, avPresents: l.avPresents, avHolds: l.avHolds, avDrops: l.avDrops,
    avSkips: l.avSkips, avOffP50: l.avOffP50, avqDepth: l.avqDepth,
    peerAvDeltaMs: l.peerAvDeltaUs != null ? Math.round(l.peerAvDeltaUs / 1000) : null,
    mcoReanchors: l.mcoReanchors, rcQp: l.rcQp, encW: l.encW, encH: l.encH, rcDuress: l.rcDuress,
    avMapRejects: l.avMapRejects, avMapErrMs: l.avMapErrMs,
    m2e: p && p.mouthToEarMs ? Math.round(p.mouthToEarMs) : null,
    concealedMs: p && p.concealedMs ? Math.round(p.concealedMs) : null,
  };
});

const runArm = async (qs, n) => {
  const b = await chromium.launch({ executablePath: CHROME, args: [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    `--use-file-for-fake-video-capture=${media(`real${SIDE}.mjpeg`)}`,
    `--use-file-for-fake-audio-capture=${media(`real${SIDE}.wav`)}`,
    '--autoplay-policy=no-user-gesture-required',
    '--disable-features=WebRtcHideLocalIpsWithMdns', '--use-gl=angle', '--enable-gpu',
  ] });
  try {
    const page = await b.newPage();
    const url = `${BASE}/${ROOM}?hb=1${qs ? '&' + qs : ''}`;
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForSelector('#join', { timeout: 30000 }).catch(() => {});
    await page.click('#join', { timeout: 30000 }).catch(() => {});
    // Wait for the lane to be ALIVE before the clock starts. A number from an
    // arm whose lane never came up is a measurement of the fallback path.
    const up = await page.waitForFunction(
      () => window.__tape?.pc?.connectionState === 'connected' && !!window.__tape?.lane?.snapshot?.(),
      null, { timeout: 90000 },
    ).then(() => true, () => false);
    if (!up) { console.log(`arm ${n} [${qs || 'default'}]  LANE NEVER CAME UP — discarded`); return null; }
    // Let the estimators converge before the window opens. Sampling before the
    // inputs settle is how a wrong value gets learned and then peak-held.
    await page.waitForTimeout(20000);
    await page.waitForTimeout(ARM_S * 1000);
    const r = await READ(page);
    console.log(`arm ${n} [${(qs || 'default').padEnd(9)}] g2g ${String(Math.round(r.g2g ?? -1)).padStart(5)}` +
      `  presentLag ${String(Math.round(r.presentLagP50 ?? -1)).padStart(5)}` +
      `  fullAge ${String(Math.round(r.fullAgeP50 ?? -1)).padStart(4)}` +
      `  ipi ${String(Math.round(r.ipiP50 ?? -1)).padStart(3)}` +
      `  fps ${String(Math.round(r.achievedFps ?? -1)).padStart(3)}` +
      `  holds ${String(r.avHolds).padStart(5)}/${r.avPresents}` +
      `  eng ${r.avEngaged ? 'Y' : 'n'} gaveUp ${r.avGaveUp ? 'Y' : 'n'}` +
      `  reanch ${String(r.mcoReanchors).padStart(4)}` +
      `  mapRej ${String(r.avMapRejects).padStart(4)} mapErr ${String(r.avMapErrMs).padStart(8)}ms` +
      `  peerAvDelta ${String(r.peerAvDeltaMs).padStart(8)}ms` +
      `  rtt ${r.rttMs}  qp ${Math.round(r.rcQp ?? -1)}  ${r.encW}x${r.encH}`);
    return { qs: qs || 'default', ...r };
  } finally { await b.close().catch(() => {}); }
};

console.log(`A/B on ${BASE}/${ROOM} — ${ARMS.length} arms x ${ARM_S}s (after 20s warmup each)\n`);
const out = [];
for (let i = 0; i < ARMS.length; i++) {
  const r = await runArm(ARMS[i], i + 1);
  if (r) out.push(r);
  await new Promise((r2) => setTimeout(r2, 4000));
}

const group = (name) => out.filter((r) => r.qs === name);
const med = (a) => { if (!a.length) return null; const s = [...a].sort((x, y) => x - y); return s[Math.floor(s.length / 2)]; };
console.log('\n--- medians per arm ---');
for (const name of ['avsync=0', 'default']) {
  const g = group(name);
  if (!g.length) continue;
  const f = (k) => { const v = med(g.map((r) => r[k]).filter((x) => typeof x === 'number')); return v == null ? '-' : Math.round(v); };
  console.log(`${name.padEnd(9)} n=${g.length}  g2g ${String(f('g2g')).padStart(5)}  presentLag ${String(f('presentLagP50')).padStart(5)}` +
    `  fullAge ${String(f('fullAgeP50')).padStart(4)}  ipi ${String(f('ipiP50')).padStart(3)}  fps ${String(f('achievedFps')).padStart(3)}` +
    `  m2e ${f('m2e')}  rtt ${f('rttMs')}`);
}
