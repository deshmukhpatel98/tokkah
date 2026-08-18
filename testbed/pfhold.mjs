/**
 * pfhold.mjs — does the exact-repeat lock free the background WITHOUT freezing
 * the person?
 *
 * The hold makes a still region bit-identical frame to frame so the encoder
 * codes it as skip. Its saving and its worst failure are the SAME MECHANISM
 * seen from two sides: stop sending a wall and you save most of the picture;
 * stop sending a face and you have shipped a photograph of someone who is
 * talking. No bitrate number can tell those apart — both look like "bits went
 * down" — which is exactly how the first presence-filter run shipped an
 * upside-down picture behind a full green board.
 *
 * So this rig measures MOTION SURVIVAL, and it refuses to assume where the
 * person is. It derives that from the control arm: with the filter off, the
 * cells of the received picture that change the most ARE the person. It then
 * asks whether those same cells still change with the lock engaged. A lock that
 * only frees the wall leaves them untouched; a lock that eats the face collapses
 * them, and the number falls whatever the bitrate did.
 *
 * Reported alongside: high-frequency energy of the received picture, because
 * "we saved bits" must not quietly mean "we sent a softer picture" — the hold
 * repeats real pixels and must cost no sharpness at all.
 *
 *   node testbed/pfhold.mjs [--qp=24] [--period=14] [--cycles=3]
 */
import { chromium } from 'playwright-core';
import { writeFileSync, mkdirSync } from 'node:fs';

const BASE = process.env.URL ?? 'https://room.tokkah.com';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
const arg = (k, d) => { const m = process.argv.find((a) => a.startsWith(`--${k}=`)); return m ? m.slice(k.length + 3) : d; };
const QP = Number(arg('qp', 24));
const PERIOD = Number(arg('period', 14));
const CYCLES = Number(arg('cycles', 3));
const OUT = arg('out', '/tmp/pfhold');
mkdirSync(OUT, { recursive: true });

const GW = 64, GH = 36;          // luminance grid the change map is built on
const CHANGE = 5;                // 0..255 luma delta that counts as "the person moved"
const QUIET = 1;                 // finer: what counts as "the background is not settled"
// The candidate shipping configuration, not a lab isolate: denoise + hold with
// NO spatial blur. testbed/pfsweep.mjs measured that pair at 61.5% fewer bits,
// and the blur lever it leaves out was worth only 4 more points while visibly
// costing detail. So this is the arm whose picture has to survive scrutiny.
const ARMS = [
  { name: 'off',  on: false, p: null },
  { name: 'hold', on: true,  p: { denoise: 0.85, soften: 0, motionGain: 14, hold: 1 } },
];

// `--media=grain` swaps in the sensor-like fixture (testbed/media/real/grain.sh).
// This rig is the one that matters there: the clean fixture leaves 92.7% of the
// picture below the lock's motion threshold and the grain fixture only 61.5%,
// so the grain fixture is where the lock has to work for its living — and this
// is the rig that asks whether it does so without eating the person.
const SUFFIX = arg('media', '') === 'grain' ? '-grain' : '';
const launch = (side) => chromium.launch({
  executablePath: CHROME, headless: true,
  args: [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    `--use-file-for-fake-video-capture=${media(`real${side}${SUFFIX}.mjpeg`)}`,
    `--use-file-for-fake-audio-capture=${media(`real${side}${SUFFIX}.wav`)}`,
    '--autoplay-policy=no-user-gesture-required',
    '--disable-features=WebRtcHideLocalIpsWithMdns',
    '--use-gl=angle', '--enable-gpu',
  ],
});

/**
 * Cumulative counters, never the windowed rate. `mbpsAtFps` is a mean over the
 * last 900 encoded frames — thirty seconds at 30fps — so read after a
 * fourteen-second arm it is mostly the PREVIOUS arm. Differencing these across
 * the arm gives the exact bytes that arm cost.
 */
const read = (p) => p.evaluate(() => {
  const v = window.__tape?.video ?? {};
  return {
    t: performance.now(), bytes: v.encBytesTotal ?? null, frames: v.encFramesTotal ?? null,
    g2g: v.glassToGlassMs ?? null, shrink: v.rcResShrink ?? 1, still: v.pfStillMean ?? null,
    pfFrames: v.pfFrames ?? 0, pfFallbacks: v.pfFallbacks ?? 0,
  };
});

/**
 * One luminance grid of the RECEIVED picture, plus its high-frequency energy.
 * Sharpness is measured on the full-size canvas, not the grid — downscaling is
 * itself a blur, and a blur metric computed after one measures the resampler.
 */
const grab = (p, gw, gh) => p.evaluate(([GW, GH]) => {
  const rc = document.getElementById('remoteCanvas');
  let src = rc;
  if (!rc?.width) {
    const v = document.getElementById('remote');
    if (!v?.videoWidth) return null;
    src = document.createElement('canvas');
    src.width = v.videoWidth; src.height = v.videoHeight;
    src.getContext('2d').drawImage(v, 0, 0);
  }
  const grid = document.createElement('canvas');
  grid.width = GW; grid.height = GH;
  const gc = grid.getContext('2d', { willReadFrequently: true });
  gc.drawImage(src, 0, 0, GW, GH);
  const gd = gc.getImageData(0, 0, GW, GH).data;
  const lum = new Array(GW * GH);
  for (let i = 0; i < GW * GH; i++) {
    lum[i] = 0.299 * gd[i * 4] + 0.587 * gd[i * 4 + 1] + 0.114 * gd[i * 4 + 2];
  }

  // High-frequency energy: mean |Laplacian| over a 256-wide copy of the real
  // picture. Same size in both arms, so it compares like for like.
  const SW = 256, SH = Math.max(1, Math.round(SW * src.height / src.width));
  const sc = document.createElement('canvas');
  sc.width = SW; sc.height = SH;
  const sctx = sc.getContext('2d', { willReadFrequently: true });
  sctx.drawImage(src, 0, 0, SW, SH);
  const sd = sctx.getImageData(0, 0, SW, SH).data;
  const L = (x, y) => {
    const i = (y * SW + x) * 4;
    return 0.299 * sd[i] + 0.587 * sd[i + 1] + 0.114 * sd[i + 2];
  };
  let hf = 0, n = 0;
  for (let y = 1; y < SH - 1; y++) {
    for (let x = 1; x < SW - 1; x++) {
      hf += Math.abs(4 * L(x, y) - L(x - 1, y) - L(x + 1, y) - L(x, y - 1) - L(x, y + 1));
      n++;
    }
  }
  return { lum, hf: n ? hf / n : 0, w: src.width, h: src.height };
}, [gw, gh]);

const shot = async (p, name) => {
  const png = await p.evaluate(() => {
    const c = document.getElementById('remoteCanvas');
    if (c?.width) return c.toDataURL('image/png');
    const v = document.getElementById('remote');
    if (!v?.videoWidth) return null;
    const t = document.createElement('canvas');
    t.width = v.videoWidth; t.height = v.videoHeight;
    t.getContext('2d').drawImage(v, 0, 0);
    return t.toDataURL('image/png');
  }).catch(() => null);
  if (png) writeFileSync(`${OUT}/${name}.png`, Buffer.from(png.split(',')[1], 'base64'));
};

/**
 * Per-cell count of "this cell changed" across a run of consecutive grabs.
 * The threshold is a parameter because the two questions this rig asks need
 * different ones: whether the PERSON still moves is asked at a coarse threshold
 * (real motion is large), while whether the background went quiet has to be
 * asked at a fine one — at 5/255 the decoded background reads as perfectly
 * still in BOTH arms, since the encoder had already quantized those changes
 * away, and the comparison silently becomes 0% versus 0%.
 */
const changeMap = (grabs, thresh) => {
  const n = GW * GH;
  const map = new Array(n).fill(0);
  for (let k = 1; k < grabs.length; k++) {
    for (let i = 0; i < n; i++) {
      if (Math.abs(grabs[k].lum[i] - grabs[k - 1].lum[i]) > thresh) map[i]++;
    }
  }
  const denom = Math.max(1, grabs.length - 1);
  return map.map((c) => c / denom);
};

const room = `pfh-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 5)}`;
const A = await launch('A'), B = await launch('B');
const state = new Map(ARMS.map((a) => [a.name, { rows: [], grabs: [] }]));
try {
  const a = await A.newPage(), b = await B.newPage();
  for (const [p, who] of [[a, 'A'], [b, 'B']]) {
    // rcres=0: the resolution actuator reacts to bitrate, so it fires in the
    // most expensive arm and quarters its pixels — a confound pointing the same
    // way as the effect, which would credit the filter with the actuator's work.
    await p.goto(`${BASE}/?r=${room}&l2rcqpmin=${QP}&l2rcqpmax=${QP}&qp=${QP}&rcres=0`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await p.waitForSelector('#join', { timeout: 20000 });
    await p.click('#join').catch(() => {});
    if (who === 'A') await p.waitForTimeout(1200);
  }
  for (const p of [a, b]) {
    await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });
  }
  if ((await read(a)).bytes == null) {
    console.log('FAIL: this build has no encBytesTotal — deploy first, or the bitrates will be windowed.');
    process.exit(1);
  }
  console.log(`hold rig — quantizer pinned at ${QP}, both arms inside one call, room ${room}`);
  console.log(`${CYCLES} cycles x ${ARMS.length} arms x ${PERIOD}s\n`);
  await a.waitForTimeout(25000);

  for (let c = 0; c < CYCLES; c++) {
    for (const arm of ARMS) {
      for (const p of [a, b]) {
        await p.evaluate(([on, params]) => window.__tape?.setPresenceFilter?.(on, params), [arm.on, arm.p]);
      }
      // Let the lock build (it needs ~0.5s of stillness) before sampling.
      await a.waitForTimeout(4000);
      const r0 = await read(a);
      const grabs = [];
      for (let g = 0; g < 10; g++) {
        const t = await grab(b, GW, GH);
        if (t) grabs.push(t);
        await a.waitForTimeout(Math.max(200, (PERIOD - 4) * 100));
      }
      const r1 = await read(a);
      const dt = (r1.t - r0.t) / 1000;
      const r = {
        ...r1,
        mbps: +((r1.bytes - r0.bytes) * 8 / dt / 1e6).toFixed(3),
        fps: +((r1.frames - r0.frames) / dt).toFixed(1),
      };
      state.get(arm.name).rows.push(r);
      if (grabs.length > 2) state.get(arm.name).grabs.push(grabs);
      console.log(`  c${c + 1} ${arm.name.padEnd(5)} ${String(r.mbps).padStart(5)}Mbps @${r.fps}fps  ` +
        `g2g ${r.g2g}ms  still ${r.still ?? '—'}  grabs ${grabs.length}`);
      if (c === CYCLES - 1) await shot(b, arm.name);
    }
  }
} finally {
  await A.close(); await B.close();
}

// ── verdict ──────────────────────────────────────────────────────────────────
const mean = (v) => (v.length ? v.reduce((s, x) => s + x, 0) / v.length : null);
const stat = (n, k) => mean(state.get(n).rows.map((r) => r[k]).filter((x) => typeof x === 'number'));
let fails = 0;
const check = (name, ok, detail) => {
  if (!ok) fails++;
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
};

const mOff = stat('off', 'mbps'), mOn = stat('hold', 'mbps');
const cut = mOff && mOn ? (1 - mOn / mOff) * 100 : null;
console.log(`\n══════ verdict ══════`);
check('the lock ran', (stat('hold', 'pfFrames') ?? 0) > 0 && (stat('hold', 'pfFallbacks') ?? 1) === 0,
  `${Math.round(stat('hold', 'pfFrames') ?? 0)} frames, ${Math.round(stat('hold', 'pfFallbacks') ?? 0)} declines`);
// Named for what it actually measures. `stillMean` is the share of the picture
// sitting below the motion threshold — a property of the SCENE, which the
// accumulator tracks whether or not the lock is switched on. It bounds how much
// the lock could possibly free; it is not evidence that it did. The evidence
// that it did is the bits, and the thing that matters is what follows it.
check('most of the picture is lockable', (stat('hold', 'still') ?? 0) > 0.10,
  `${((stat('hold', 'still') ?? 0) * 100).toFixed(0)}% of the picture is below the motion threshold`);
check('bits went down', cut != null && cut > 3,
  `${mOff?.toFixed(2)} -> ${mOn?.toFixed(2)} Mbps (${cut?.toFixed(1)}%)`);
check('frame rate held', Math.abs((stat('hold', 'fps') ?? 0) - (stat('off', 'fps') ?? 0)) < 1.5,
  `${stat('off', 'fps')?.toFixed(1)} -> ${stat('hold', 'fps')?.toFixed(1)} fps`);
check('same resolution both arms', stat('off', 'shrink') === stat('hold', 'shrink'),
  `divisor ${stat('off', 'shrink')} vs ${stat('hold', 'shrink')}`);

// THE assertion. The control arm names the moving cells; the hold arm has to
// keep moving them.
const avg = (ms) => ms[0].map((_, i) => mean(ms.map((m) => m[i])));
const at = (m, idx) => mean(idx.map((i) => m[i]));
if (state.get('off').grabs.length && state.get('hold').grabs.length) {
  const coarseOff = avg(state.get('off').grabs.map((g) => changeMap(g, CHANGE)));
  const coarseOn = avg(state.get('hold').grabs.map((g) => changeMap(g, CHANGE)));
  const order = coarseOff.map((v, i) => [v, i]).sort((x, y) => y[0] - x[0]);
  const live = order.slice(0, Math.round(order.length * 0.15)).map(([, i]) => i);
  const dead = order.slice(Math.round(order.length * 0.5)).map(([, i]) => i);
  const liveOff = at(coarseOff, live), liveOn = at(coarseOn, live);
  const survived = liveOff > 0 ? liveOn / liveOff : 0;
  check('the person still moves', survived >= 0.7,
    `busiest 15% of the picture changes ${(liveOn * 100).toFixed(0)}% as often vs ` +
    `${(liveOff * 100).toFixed(0)}% off — ${(survived * 100).toFixed(0)}% survived`);

  const fineOff = avg(state.get('off').grabs.map((g) => changeMap(g, QUIET)));
  const fineOn = avg(state.get('hold').grabs.map((g) => changeMap(g, QUIET)));
  console.log(`  ....  the win: quietest half of the picture settles from ` +
    `${(at(fineOff, dead) * 100).toFixed(0)}% to ${(at(fineOn, dead) * 100).toFixed(0)}% of frames changing`);
} else {
  check('motion survival is measurable', false, 'no receiver grabs captured');
}

// Sharpness: repeating a real pixel must cost nothing. A drop here means the
// saving came from softening the picture, which is a different claim entirely.
const hfOff = mean(state.get('off').grabs.flat().map((g) => g.hf));
const hfOn = mean(state.get('hold').grabs.flat().map((g) => g.hf));
if (hfOff && hfOn) {
  check('picture is no softer', hfOn / hfOff >= 0.92,
    `high-frequency energy ${hfOff.toFixed(2)} -> ${hfOn.toFixed(2)} (${((hfOn / hfOff - 1) * 100).toFixed(1)}%)`);
}

console.log(`\n  stills: ${OUT}`);
console.log(`VERDICT: ${fails ? `FAIL (${fails})` : 'PASS'}`);
process.exit(fails ? 1 : 0);
