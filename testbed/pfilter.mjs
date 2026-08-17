/**
 * pfilter.mjs — does removing what the eye cannot see actually cost fewer bits?
 *
 * THE CONTROL THAT MAKES THIS HONEST: the quantizer is PINNED to one value in
 * both arms (l2rcqpmin = l2rcqpmax). The encoder is therefore given identical
 * fidelity instructions on both sides, and any bitrate difference cannot be
 * "we asked for lower quality" — it can only be "there was less detail there
 * to encode". Without that pin, a rate controller free to move QP would make
 * every arm converge on the same bitrate and the whole measurement would be
 * a tautology.
 *
 * Real talking-head media, real prod call, both directions.
 *
 * Arms:
 *   off (default)   the shipping path
 *   on  (&pfilter=1) grain removed where nothing moved, softening in
 *                    proportion to local motion
 *
 * What it asserts:
 *   1. bits go DOWN (the point)
 *   2. frame rate does NOT (a filter that costs cadence has bought nothing —
 *      smoothness is presence)
 *   3. glass-to-glass does NOT go up (the GPU pass is on the latency path)
 *   4. the filter actually ran (frames out > 0, no silent fallback) — a filter
 *      that quietly declined would read exactly like "the idea does not work"
 *
 * QUALITY IS DELIBERATELY NOT ASSERTED HERE. VMAF scores against an original
 * that still contains the grain this removes, so it would mark a better
 * picture down; the presence-weighted ruler and the blind test own that
 * question. Receiver stills are written for eyeballing either way.
 *
 * LOOK AT THE STILLS. The first passing run of this rig — bitrate -16.5%, frame
 * rate held, latency held, four clean cycles — was sending the caller UPSIDE
 * DOWN (WebGL texture origin vs VideoFrame row order). An inverted frame costs
 * the same bits as an upright one, so no number here can ever catch it. The
 * geometry assertions below exist because of that run; they are cheap and they
 * are not optional.
 *
 *   node testbed/pfilter.mjs [--qp=24] [--secs=40]
 */
import { chromium } from 'playwright-core';
import { writeFileSync, mkdirSync } from 'node:fs';

const BASE = process.env.URL ?? 'https://room.tokkah.com';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
const arg = (k, d) => { const m = process.argv.find((a) => a.startsWith(`--${k}=`)); return m ? m.slice(k.length + 3) : d; };
const QP = Number(arg('qp', 24));
const SECS = Number(arg('secs', 40));
const OUT = arg('out', '/private/tmp/claude-501/-Users-deveshpatel-Downloads-video-calling/2cd64fea-5ae0-424e-909a-cfec3fc12a22/scratchpad/pfilter');
mkdirSync(OUT, { recursive: true });

// QP pinned identically in both arms — see the header.
const QS = `l2rcqpmin=${QP}&l2rcqpmax=${QP}&qp=${QP}`;

const launch = (side) => chromium.launch({
  executablePath: CHROME, headless: true,
  args: [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    `--use-file-for-fake-video-capture=${media(`real${side}.mjpeg`)}`,
    `--use-file-for-fake-audio-capture=${media(`real${side}.wav`)}`,
    '--autoplay-policy=no-user-gesture-required',
    '--disable-features=WebRtcHideLocalIpsWithMdns',
    '--use-gl=angle', '--enable-gpu', // the filter is a GPU pass; headless needs this
  ],
});

const read = (p) => p.evaluate(() => {
  const v = window.__tape?.video ?? {};
  return {
    mbps: v.mbpsAtFps ?? null, fps: v.achievedFps ?? null, qp: v.rcQp ?? null,
    g2g: v.glassToGlassMs ?? null, encLat: v.encLatP50 ?? null,
    pfMs: v.pfMs ?? null, pfFrames: v.pfFrames ?? 0, pfFallbacks: v.pfFallbacks ?? 0,
    // Encode size, so a resolution actuator that fires in one arm and not the
    // other cannot be read as the filter saving bits. Pixels are the biggest
    // lever in this file's neighbourhood; an unequal comparison here would be
    // measuring rcResShrink and calling it denoising.
    shrink: v.rcResShrink ?? 1, px: (v.w ?? 0) * (v.h ?? 0),
  };
});
/**
 * Row- and column-luminance profiles of the received picture, 64 buckets each.
 * A vertical flip reverses the row profile and a mirror reverses the column
 * profile, so comparing each against the OTHER arm's — forwards versus
 * reversed — catches an inverted or mirrored image without needing to know
 * what the scene is. This is the assertion the upside-down run lacked.
 */
const profile = (p) => p.evaluate(() => {
  const rc = document.getElementById('remoteCanvas');
  let src = rc;
  if (!rc?.width) {
    const v = document.getElementById('remote');
    if (!v?.videoWidth) return null;
    src = document.createElement('canvas');
    src.width = v.videoWidth; src.height = v.videoHeight;
    src.getContext('2d').drawImage(v, 0, 0);
  }
  const N = 64;
  const t = document.createElement('canvas');
  t.width = N; t.height = N;
  const ctx = t.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(src, 0, 0, N, N);
  const d = ctx.getImageData(0, 0, N, N).data;
  const rows = new Array(N).fill(0), cols = new Array(N).fill(0);
  for (let y = 0; y < N; y++) {
    for (let x = 0; x < N; x++) {
      const i = (y * N + x) * 4;
      const L = 0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2];
      rows[y] += L / N; cols[x] += L / N;
    }
  }
  return { rows, cols };
});

const corr = (a, b) => {
  const n = Math.min(a.length, b.length);
  const m = (v) => v.slice(0, n).reduce((s, x) => s + x, 0) / n;
  const ma = m(a), mb = m(b);
  let num = 0, da = 0, db = 0;
  for (let i = 0; i < n; i++) {
    const x = a[i] - ma, y = b[i] - mb;
    num += x * y; da += x * x; db += y * y;
  }
  return num / Math.sqrt((da * db) || 1);
};

/** What the RECEIVER actually shows — the only picture that matters. */
const shot = async (p, name) => {
  const png = await p.evaluate(() => {
    const c = document.getElementById('remoteCanvas');
    if (c?.width) return c.toDataURL('image/png');
    const v = document.getElementById('remote');
    if (!v || !v.videoWidth) return null;
    const t = document.createElement('canvas');
    t.width = v.videoWidth; t.height = v.videoHeight;
    t.getContext('2d').drawImage(v, 0, 0);
    return t.toDataURL('image/png');
  }).catch(() => null);
  if (png) writeFileSync(`${OUT}/${name}.png`, Buffer.from(png.split(',')[1], 'base64'));
};

/**
 * ONE call, the filter flipped on and off inside it, alternating. Slow drift —
 * congestion, thermal throttle, where the fixture happens to be — lands on BOTH
 * arms instead of on whichever ran second. Readings are taken at the END of
 * each period because bitrate is a windowed average: sample it immediately
 * after a flip and you are mostly measuring the previous arm.
 */
const CYCLES = Number(arg('cycles', 4));
const PERIOD = Number(arg('period', 12));
const room = `pf-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 5)}`;
const A = await launch('A'), B = await launch('B');
const rows = { off: [], on: [] };
const prof = { off: null, on: null };
try {
  const a = await A.newPage(), b = await B.newPage();
  for (const [p, who] of [[a, 'A'], [b, 'B']]) {
    await p.goto(`${BASE}/?r=${room}&${QS}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await p.waitForSelector('#join', { timeout: 20000 });
    await p.click('#join').catch(() => {});
    if (who === 'A') await p.waitForTimeout(1200);
  }
  for (const p of [a, b]) {
    await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });
  }
  console.log(`presence filter, quantizer pinned at ${QP}, A/B INSIDE one call`);
  console.log(`${CYCLES} cycles x ${PERIOD}s per arm, room ${room}\n`);
  await a.waitForTimeout(SECS * 1000); // settle before the first reading

  for (let c = 0; c < CYCLES; c++) {
    for (const armName of ['off', 'on']) {
      const want = armName === 'on';
      for (const p of [a, b]) await p.evaluate((o) => window.__tape?.setPresenceFilter?.(o), want);
      await a.waitForTimeout(PERIOD * 1000);
      const rA = await read(a), rB = await read(b);
      rows[armName].push(rA, rB);
      console.log(`  c${c + 1} ${armName.padEnd(3)}  A ${rA.mbps}Mbps @${rA.fps}fps g2g=${rA.g2g}ms enc=${rA.encLat}ms  ` +
        `B ${rB.mbps}Mbps @${rB.fps}fps g2g=${rB.g2g}ms enc=${rB.encLat}ms  filt=${rA.pfFrames}/${rB.pfFrames}`);
      if (c === CYCLES - 1) {
        await shot(a, `${armName}-A`); await shot(b, `${armName}-B`);
        prof[armName] = await profile(b);
      }
    }
  }
} finally {
  await A.close(); await B.close();
}

const off = rows.off, on = rows.on;
// MEDIAN, not mean: one hiccup inside a 12 s window should not decide this.
const mean = (rs, k) => {
  const v = rs.map((r) => r[k]).filter((x) => typeof x === 'number').sort((x, y) => x - y);
  if (!v.length) return null;
  return v.length % 2 ? v[(v.length - 1) / 2] : (v[v.length / 2 - 1] + v[v.length / 2]) / 2;
};
let fails = 0;
const check = (name, ok, detail) => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  (${detail})`);
  if (!ok) fails++;
};

const bOff = mean(off, 'mbps'), bOn = mean(on, 'mbps');
const fOff = mean(off, 'fps'), fOn = mean(on, 'fps');
const gOff = mean(off, 'g2g'), gOn = mean(on, 'g2g');
const cut = bOff && bOn ? (1 - bOn / bOff) * 100 : null;
const ran = Math.max(...on.map((r) => r.pfFrames | 0), 0);
const fell = Math.max(...on.map((r) => r.pfFallbacks | 0), 0);

console.log('');
check('the filter actually ran (no silent decline)', ran > 100 && fell < ran * 0.05,
  `${ran} frames filtered, ${fell} fallbacks`);
check('bits go DOWN at the same quantizer', cut != null && cut > 0,
  `${bOff?.toFixed(2)} -> ${bOn?.toFixed(2)} Mbps = ${cut?.toFixed(1)}% cut`);
check('frame rate is not the price', fOn != null && fOff != null && fOn >= fOff * 0.95,
  `${fOff?.toFixed(1)} -> ${fOn?.toFixed(1)} fps`);
check('latency is not the price', gOn == null || gOff == null || gOn <= gOff + 15,
  `glass-to-glass ${gOff?.toFixed(1)} -> ${gOn?.toFixed(1)} ms`);
const sOff = mean(off, 'shrink'), sOn = mean(on, 'shrink');
check('both arms encoded at the SAME resolution', sOff === sOn,
  `resolution divisor ${sOff} vs ${sOn} (unequal would make this measure pixels, not grain)`);
// GEOMETRY. The picture must arrive the same way up and the same way round as
// the unfiltered one. Cheap, and the one thing every other assertion here is
// structurally blind to.
if (prof.off && prof.on) {
  const vUp = corr(prof.off.rows, prof.on.rows);
  const vFlip = corr(prof.off.rows, [...prof.on.rows].reverse());
  const hUp = corr(prof.off.cols, prof.on.cols);
  const hMirror = corr(prof.off.cols, [...prof.on.cols].reverse());
  check('the filtered picture is the same way UP', vUp > vFlip,
    `row-profile correlation upright ${vUp.toFixed(3)} vs flipped ${vFlip.toFixed(3)}`);
  check('the filtered picture is not MIRRORED', hUp > hMirror,
    `column-profile correlation direct ${hUp.toFixed(3)} vs mirrored ${hMirror.toFixed(3)}`);
} else {
  check('geometry is checkable', false, 'no receiver profile captured — cannot prove the picture is upright');
}
console.log(`\n  filter cost: ${mean(on, 'pfMs')?.toFixed(2)} ms/frame on the GPU`);
console.log(`  stills for eyeballing: ${OUT}`);
console.log(fails === 0 ? '\nVERDICT: PASS' : `\nVERDICT: FAIL (${fails})`);
process.exit(fails ? 1 : 0);
