// The NEAR end of a cross-planet call: a real browser on this laptop, joining
// the same production room the container peer joins from the other side of the
// world.
//
// It stands in for the human while the rig is being proved. It is NOT a
// substitute for the human: the camera here is a recorded talking head, so this
// measures the PATH and the app, and says nothing about a sensor. The real run
// is a person on room.tokkah.com/far-away-lab with a webcam.
//
// Prints every tick rather than once at the end. A rig that only speaks when it
// finishes is indistinguishable from a rig that died, and the whole point of
// watching the keeper summon a far peer is seeing WHEN it happens.
//
//   ROOM=far-away-lab HOLD_S=600 node testbed/nearside.mjs
//   ROOM=far-away-lab HOLD_S=600 SIDE=A EXTRA_QS=ice=relay node testbed/nearside.mjs
import { chromium } from 'playwright-core';

const ROOM = process.env.ROOM ?? 'far-away-lab';
const HOLD = Number(process.env.HOLD_S || 600);
const TICK = Number(process.env.TICK_S || 15);
const SIDE = (process.env.SIDE ?? 'A').toUpperCase() === 'B' ? 'B' : 'A';
const QS = process.env.EXTRA_QS || '';
const BASE = process.env.URL ?? 'https://room.tokkah.com';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);

const b = await chromium.launch({ executablePath: CHROME, args: [
  '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
  // A REAL talking head and REAL speech, not Chromium's rolling pattern and
  // beep -- those compress to almost nothing, so a call carrying them measures
  // an empty pipe and reports it as a video call.
  `--use-file-for-fake-video-capture=${media(`real${SIDE}.mjpeg`)}`,
  `--use-file-for-fake-audio-capture=${media(`real${SIDE}.wav`)}`,
  '--autoplay-policy=no-user-gesture-required',
  '--disable-features=WebRtcHideLocalIpsWithMdns', '--use-gl=angle', '--enable-gpu',
] });

const page = await b.newPage();
const url = `${BASE}/${ROOM}?hb=1${QS ? '&' + QS : ''}`;
console.log(`near side (${SIDE}) -> ${url}`);
await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
await page.waitForSelector('#join', { timeout: 30000 }).catch(() => {});
await page.click('#join', { timeout: 30000 }).catch(() => {});

// Read the page through window.__tape only -- the surface the app publishes. A
// rig that re-implements what it measures measures the rig.
const READ = async () => page.evaluate(async () => {
  const t = window.__tape || {};
  const s = t.pcm && typeof t.pcm.snapshot === 'function' ? t.pcm.snapshot() : t.pcm;
  const l = t.lane && typeof t.lane.snapshot === 'function' ? t.lane.snapshot() : null;
  let ice = null;
  if (t.pc && t.pc.getStats) {
    const st = await t.pc.getStats(); let pair = null;
    st.forEach((r) => { if (r.type === 'candidate-pair' && r.state === 'succeeded' && (r.nominated || !pair)) pair = r; });
    if (pair) {
      const L = st.get(pair.localCandidateId), R = st.get(pair.remoteCandidateId);
      ice = { local: L && L.candidateType, remote: R && R.candidateType, proto: L && L.protocol,
              rttMs: pair.currentRoundTripTime != null ? Math.round(pair.currentRoundTripTime * 1000) : null };
    }
  }
  // WHY, not just WHETHER. A null m2e means either "not measured yet" or "the
  // lane is dead on this path", and an instrument that returns the same value
  // for both sends you looking in the wrong place — which is exactly what
  // happened on this rig's first cross-planet call.
  const mirror = (t.tel && t.tel.mirror) || [];
  return {
    conn: t.pc ? t.pc.connectionState : null,
    m2e: s && s.mouthToEarMs ? Math.round(s.mouthToEarMs) : null,
    g2g: l && l.glassToGlassMs ? Math.round(l.glassToGlassMs) : null,
    conceal: s && s.concealedMs ? Math.round(s.concealedMs) : null,
    framesRecv: (s && s.framesRecv) || null,
    laneIn: (l && l.framesIn) || null,
    pcmUp: !!s,
    tapeMode: t.tapeMode || null,
    fellBack: mirror.filter((e) => e && typeof e.kind === 'string' && e.kind.indexOf('fallback') >= 0)
                    .slice(-4).map((e) => e.kind + (e.why ? ':' + e.why : (e.data && e.data.why ? ':' + e.data.why : ''))),
    ice,
  };
});

const t0 = Date.now();
while (Date.now() - t0 < HOLD * 1000) {
  await page.waitForTimeout(TICK * 1000);
  const r = await READ().catch((e) => ({ err: String(e).slice(0, 90) }));
  const el = Math.round((Date.now() - t0) / 1000);
  console.log(`t+${String(el).padStart(4)}s  conn=${r.conn ?? '-'}  m2e=${r.m2e ?? '-'}  g2g=${r.g2g ?? '-'}` +
    `  conceal=${r.conceal ?? '-'}  frames=${r.framesRecv ?? '-'}  laneIn=${r.laneIn ?? '-'}` +
    `  pcm=${r.pcmUp ? 'up' : 'DOWN'}  tape=${r.tapeMode ? (r.tapeMode.running ? 'run' : (r.tapeMode.fellBack ? 'FELLBACK' : 'off')) : '-'}` +
    `  ice=${r.ice ? `${r.ice.local}/${r.ice.remote} ${r.ice.proto} rtt=${r.ice.rttMs}` : '-'}` +
    (r.fellBack && r.fellBack.length ? `  why=${r.fellBack.join(',')}` : '') +
    (r.err ? `  ERR ${r.err}` : ''));
}
console.log('final', JSON.stringify(await READ().catch(() => null)));
await b.close();
