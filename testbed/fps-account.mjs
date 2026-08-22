// WHERE DO 30 fps BECOME 10?
//
// The encoder's own meter reads 30 fps (encMeter.note() sits on the line after
// stats.framesEncoded++, so it counts encodes, not captures). The receiver's
// inter-present interval reads 67 ms on a 2-hop path and 104 ms on the Delhi
// path -- clean multiples of the 33.3 ms slot, i.e. presents landing on every
// 2nd or 3rd slot. Twenty frames a second are being made and never shown, and
// "the network" is not an answer: this rig has been wrong about that before.
//
// So account for every frame at every stage, as a RATE, by differencing the
// cumulative counters over a window. Not a moving average: a 30 s window read
// after a 12 s arm has already inverted one A/B result in this project.
//
//   capture -> admit -> encode -> [wire] -> decode -> enqueue -> present
//   framesIn  framesSkipped  framesEncoded   framesOut   vp.skips   vp.presents
//
// The pair that matters is (framesOut, vp.presents + vp.skips + vp.drops): if
// decode delivers 30 and presents are 10, the presenter is discarding them and
// the index quantisation in vpEnqueue is the suspect. If decode itself delivers
// 10, the loss is upstream of this browser and the sender's admission governor
// or the transport owns it.
//
//   ROOM=far-away-two WIN_S=40 node testbed/fps-account.mjs
import { chromium } from 'playwright-core';

const ROOM = process.env.ROOM ?? 'far-away-two';
const WIN = Number(process.env.WIN_S || 40);
const WAIT = Number(process.env.WAIT_S || 200);
const SIDE = (process.env.SIDE ?? 'A').toUpperCase() === 'B' ? 'B' : 'A';
const BASE = process.env.URL ?? 'https://room.tokkah.com';
const QS = process.env.EXTRA_QS || '';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);

const READ = async (page) => page.evaluate(() => {
  const t = window.__tape || {};
  const l = t.lane?.snapshot?.();
  if (!l) return null;
  // FLATTEN every number the lane publishes. A hand-picked field list cannot
  // see the counter you did not think of -- and the frame that vanishes between
  // encode and decode is, by definition, being eaten by a counter nobody named.
  const flat = { at: performance.now(), conn: t.pc?.connectionState ?? null };
  const walk = (o, pre) => {
    for (const [k, v] of Object.entries(o || {})) {
      if (typeof v === 'number') flat[pre + k] = v;
      else if (typeof v === 'boolean') flat[pre + k] = v ? 1 : 0;
      else if (v && typeof v === 'object' && !Array.isArray(v)) walk(v, pre + k + '.');
    }
  };
  walk(l, '');
  return flat;
});

const b = await chromium.launch({ executablePath: CHROME, args: [
  '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
  `--use-file-for-fake-video-capture=${media(`real${SIDE}.mjpeg`)}`,
  `--use-file-for-fake-audio-capture=${media(`real${SIDE}.wav`)}`,
  '--autoplay-policy=no-user-gesture-required',
  '--disable-features=WebRtcHideLocalIpsWithMdns', '--use-gl=angle', '--enable-gpu',
] });
const page = await b.newPage();
const url = `${BASE}/${ROOM}?hb=1${QS ? '&' + QS : ''}`;
console.log(`fps accounting -> ${url}  (window ${WIN}s)`);
await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
await page.waitForSelector('#join', { timeout: 30000 }).catch(() => {});
await page.click('#join', { timeout: 30000 }).catch(() => {});

const up = await page.waitForFunction(
  () => window.__tape?.pc?.connectionState === 'connected' && !!window.__tape?.lane?.snapshot?.(),
  null, { timeout: WAIT * 1000 },
).then(() => true, () => false);
if (!up) { console.log('no peer arrived within ' + WAIT + 's — nothing to account for'); await b.close(); process.exit(0); }

await page.waitForTimeout(20000);            // let the estimators converge
const a = await READ(page);
await page.waitForTimeout(WIN * 1000);
const z = await READ(page);
await b.close();

const secs = (z.at - a.at) / 1000;
console.log(`\nover ${secs.toFixed(1)}s, conn=${z.conn}`);

// Anything that MOVED, as a per-second rate, biggest first. Cumulative
// counters differenced over one window -- never a moving average, which has
// already inverted an A/B result in this project.
const rows = [];
for (const k of Object.keys(z)) {
  if (k === 'at' || k === 'conn') continue;
  const dz = z[k], da = a[k];
  if (typeof dz !== 'number' || typeof da !== 'number') continue;
  const d = dz - da;
  if (d !== 0) rows.push([k, +(d / secs).toFixed(2), dz]);
}
rows.sort((x, y) => Math.abs(y[1]) - Math.abs(x[1]));
console.log('--- COUNTERS THAT MOVED (per second, then cumulative) ---');
for (const [k, r, tot] of rows) console.log(`  ${k.padEnd(30)} ${String(r).padStart(9)}/s   ${tot}`);

console.log('--- LEVELS (did not move, or are gauges) ---');
for (const k of ['askedFps','achievedFps','ipiP50','ipiP95','glassToGlassMs','presentLagP50','fullAgeP50',
                 'capLagP50','encLatP50','rcQp','encW','encH','avEngaged','avGaveUp','avMapRejects','avMapErrMs',
                 'peerAvDeltaUs','mcoReanchors','decQueue','encQueue','pending','avqDepth','vp.depth','rttMs']) {
  if (z[k] != null) console.log(`  ${k.padEnd(30)} ${z[k]}`);
}
const ipi = z.ipiP50;
if (ipi) console.log(`\n  => presented ${(1000 / ipi).toFixed(1)} fps against an encoder making ${z.achievedFps} fps`);
