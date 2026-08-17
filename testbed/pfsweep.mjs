/**
 * pfsweep.mjs — which lever of the presence filter earns the bits, measured
 * without lying to itself.
 *
 * The filter has three levers with very different risk profiles:
 *   TEMPORAL (denoise) — blend with the previous output where nothing moved.
 *     Averaging repeated samples of a static scene removes the random part
 *     (grain) and leaves the repeated part (detail). Fails as ghosting, not
 *     softness.
 *   HOLD — where a region has been still for ~0.5s, emit the previous output
 *     EXACTLY, so the encoder codes it as a skip block. Invents nothing; the
 *     held picture can never be further from the truth than its own threshold.
 *   SPATIAL (soften) — blur in proportion to local motion. The only lever that
 *     can actually cost the picture, because it removes real detail and trusts
 *     a claim about human vision to make that acceptable.
 *
 * TWO WAYS THIS RIG PREVIOUSLY LIED, both fixed here:
 *
 * 1. THE WINDOW. `mbpsAtFps` averages the last 900 encoded frames — thirty
 *    seconds at 30fps. Read after a twelve-second arm, every value was a blend
 *    of the current arm and the two before it. That produced results that could
 *    not all be true at once: hold measured as COSTING 31% on its own and
 *    SAVING 28% in combination. The window, not the lever, was what varied.
 *    So this reads cumulative encoded-byte and frame counters and differences
 *    them across the slot — exact bytes, that slot, nothing smeared in.
 *
 * 2. THE LOOP. The fixture is a ~44s clip that Chrome loops forever, and seven
 *    twelve-second arms made a cycle almost exactly two loops long. Every arm
 *    landed on the SAME footage every time — which is why the numbers repeated
 *    to two decimals across cycles and read as beautiful precision rather than
 *    as the confound it was. Arms are rotated each round so each one is scored
 *    across different parts of the clip.
 *
 * Being inside one call was necessary and was never sufficient.
 *
 *   node testbed/pfsweep.mjs [--qp=24] [--rounds=4] [--measure=6] [--settle=2]
 */
import { chromium } from 'playwright-core';
import { writeFileSync, mkdirSync } from 'node:fs';

const BASE = process.env.URL ?? 'https://room.tokkah.com';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
const arg = (k, d) => { const m = process.argv.find((a) => a.startsWith(`--${k}=`)); return m ? m.slice(k.length + 3) : d; };
const QP = Number(arg('qp', 24));
const ROUNDS = Number(arg('rounds', 4));
const MEASURE = Number(arg('measure', 6));
const SETTLE = Number(arg('settle', 2));
const OUT = arg('out', '/private/tmp/claude-501/-Users-deveshpatel-Downloads-video-calling/2cd64fea-5ae0-424e-909a-cfec3fc12a22/scratchpad/pfsweep');
mkdirSync(OUT, { recursive: true });

// Every filter arm names `hold` explicitly — it defaults ON, so an arm that
// omitted it would silently carry the newest lever and quietly turn every older
// comparison into a comparison of something else.
const ARMS = [
  { name: 'off',      on: false, p: null },
  { name: 'denoise',  on: true,  p: { denoise: 0.6, soften: 0.0, motionGain: 14, hold: 0 } },
  { name: 'soften',   on: true,  p: { denoise: 0.0, soften: 0.7, motionGain: 14, hold: 0 } },
  { name: 'hold',     on: true,  p: { denoise: 0.0, soften: 0.0, motionGain: 14, hold: 1 } },
  { name: 'dn+hold',  on: true,  p: { denoise: 0.6, soften: 0.0, motionGain: 14, hold: 1 } },
  { name: 'dnmax+h',  on: true,  p: { denoise: 0.85, soften: 0.0, motionGain: 14, hold: 1 } },
  { name: 'all',      on: true,  p: { denoise: 0.6, soften: 0.7, motionGain: 14, hold: 1 } },
];

const launch = (side) => chromium.launch({
  executablePath: CHROME, headless: true,
  args: [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    `--use-file-for-fake-video-capture=${media(`real${side}.mjpeg`)}`,
    `--use-file-for-fake-audio-capture=${media(`real${side}.wav`)}`,
    '--autoplay-policy=no-user-gesture-required',
    '--disable-features=WebRtcHideLocalIpsWithMdns',
    '--use-gl=angle', '--enable-gpu',
  ],
});

/** Cumulative counters plus a clock, all read in one page turn so they agree. */
const counters = (p) => p.evaluate(() => {
  const v = window.__tape?.video ?? {};
  return {
    t: performance.now(),
    bytes: v.encBytesTotal ?? null, frames: v.encFramesTotal ?? null,
    g2g: v.glassToGlassMs ?? null, shrink: v.rcResShrink ?? 1,
    still: v.pfStillMean ?? null, pfMs: v.pfMs ?? null, pfFallbacks: v.pfFallbacks ?? 0,
  };
});

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

const room = `pfs-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 5)}`;
const A = await launch('A'), B = await launch('B');
const samples = new Map(ARMS.map((a) => [a.name, []]));
try {
  const a = await A.newPage(), b = await B.newPage();
  for (const [p, who] of [[a, 'A'], [b, 'B']]) {
    // rcres=0 disables the resolution actuator. It reacts to bitrate, so it
    // fires in whichever arm happens to be most expensive and then quarters
    // that arm's pixels — a confound pointing the same direction as the effect
    // being measured, which would credit the filter with the actuator's work.
    await p.goto(`${BASE}/?r=${room}&l2rcqpmin=${QP}&l2rcqpmax=${QP}&qp=${QP}&rcres=0`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await p.waitForSelector('#join', { timeout: 20000 });
    await p.click('#join').catch(() => {});
    if (who === 'A') await p.waitForTimeout(1200);
  }
  for (const p of [a, b]) {
    await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });
  }
  const probe = await counters(a);
  if (probe.bytes == null) {
    console.log('FAIL: this build has no encBytesTotal — deploy first, or the numbers will be windowed.');
    process.exit(1);
  }
  console.log(`presence-filter sweep — quantizer pinned at ${QP}, one call, exact per-slot bytes`);
  console.log(`${ROUNDS} rounds x ${ARMS.length} arms, ${SETTLE}s settle + ${MEASURE}s measured, room ${room}\n`);
  await a.waitForTimeout(20000);

  for (let r = 0; r < ROUNDS; r++) {
    // Rotate so no arm keeps landing on the same part of the looping clip.
    const order = ARMS.map((_, i) => ARMS[(i + r) % ARMS.length]);
    for (const arm of order) {
      for (const p of [a, b]) {
        await p.evaluate(([on, params]) => window.__tape?.setPresenceFilter?.(on, params), [arm.on, arm.p]);
      }
      await a.waitForTimeout(SETTLE * 1000);
      const a0 = await counters(a), b0 = await counters(b);
      await a.waitForTimeout(MEASURE * 1000);
      const a1 = await counters(a), b1 = await counters(b);
      const rate = (s0, s1) => (s1.bytes - s0.bytes) * 8 / ((s1.t - s0.t) / 1000) / 1e6;
      const fps = (s0, s1) => (s1.frames - s0.frames) / ((s1.t - s0.t) / 1000);
      const mk = (s0, s1, side) => ({
        side, round: r, mbps: +rate(s0, s1).toFixed(3), fps: +fps(s0, s1).toFixed(1),
        g2g: s1.g2g, shrink: s1.shrink, still: s1.still, pfMs: s1.pfMs, pfFallbacks: s1.pfFallbacks,
      });
      const sA = mk(a0, a1, 'A'), sB = mk(b0, b1, 'B');
      samples.get(arm.name).push(sA, sB);
      console.log(`  r${r + 1} ${arm.name.padEnd(8)} A ${sA.mbps.toFixed(2).padStart(5)}Mbps @${sA.fps}fps  ` +
        `B ${sB.mbps.toFixed(2).padStart(5)}Mbps @${sB.fps}fps  still ${sA.still ?? '—'}`);
      if (r === ROUNDS - 1) { await shot(a, `${arm.name}-A`); await shot(b, `${arm.name}-B`); }
    }
  }
} finally {
  await A.close(); await B.close();
}

const med = (v) => {
  const s = v.filter((x) => typeof x === 'number' && Number.isFinite(x)).sort((x, y) => x - y);
  if (!s.length) return null;
  return s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2;
};
const pick = (rs, k) => med(rs.map((r) => r[k]));
// Scored against the `off` slot from the SAME round and the SAME side: the only
// comparison in which the filter setting is the one thing that differs.
const offBy = new Map(samples.get('off').map((r) => [`${r.side}${r.round}`, r.mbps]));
const cutOf = (rs) => med(rs.map((r) => {
  const o = offBy.get(`${r.side}${r.round}`);
  return o > 0 && r.mbps > 0 ? (1 - r.mbps / o) * 100 : null;
}));

console.log(`\n══════ ${ROUNDS} rounds x 2 sides, quantizer pinned at ${QP} ══════`);
console.log(`  ${'arm'.padEnd(9)} ${'A Mbps'.padStart(7)} ${'B Mbps'.padStart(7)} ${'cut'.padStart(7)} ` +
  `${'spread'.padStart(9)} ${'fps'.padStart(5)} ${'g2g'.padStart(6)} ${'still'.padStart(6)}  gpu`);
for (const arm of ARMS) {
  const rs = samples.get(arm.name);
  const cuts = rs.map((r) => {
    const o = offBy.get(`${r.side}${r.round}`);
    return o > 0 && r.mbps > 0 ? (1 - r.mbps / o) * 100 : null;
  }).filter((x) => x != null);
  // Spread across rounds is the honesty check: a lever whose per-round cuts
  // disagree wildly has not been measured, however clean its median looks.
  const spread = cuts.length ? `${Math.min(...cuts).toFixed(0)}..${Math.max(...cuts).toFixed(0)}%` : '—';
  console.log(`  ${arm.name.padEnd(9)} ${pick(rs.filter((r) => r.side === 'A'), 'mbps')?.toFixed(2).padStart(7)} ` +
    `${pick(rs.filter((r) => r.side === 'B'), 'mbps')?.toFixed(2).padStart(7)} ` +
    `${(arm.name === 'off' ? '0.0%' : `${cutOf(rs)?.toFixed(1)}%`).padStart(7)} ${spread.padStart(9)} ` +
    `${pick(rs, 'fps')?.toFixed(1).padStart(5)} ${pick(rs, 'g2g')?.toFixed(1).padStart(6)} ` +
    `${(pick(rs, 'still') ?? 0).toFixed(2).padStart(6)}  ${arm.on ? `${pick(rs, 'pfMs')?.toFixed(2)}ms` : '—'}`);
}
const shrinks = [...new Set(ARMS.flatMap((a) => samples.get(a.name).map((r) => r.shrink)))];
const ok = shrinks.length === 1;
console.log(`\n  resolution divisor across every arm: ${shrinks.join(', ')}` +
  (ok ? '  (equal — the cuts are the filter, not pixels)' : '  UNEQUAL'));
console.log(`  stills: ${OUT}`);
// Not a footnote. Unequal resolution means the table above is measuring pixels
// somewhere and the filter elsewhere, and every cut in it is uninterpretable.
console.log(`VERDICT: ${ok ? 'MEASURED' : 'VOID — resolution differed across arms, the cuts above mean nothing'}`);
process.exit(ok ? 0 : 1);
