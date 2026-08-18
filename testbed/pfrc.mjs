/**
 * pfrc.mjs — the presence filter and the resolution actuator, together, the way
 * production actually runs them.
 *
 * EVERY filter measurement so far was taken with `rcres=0`. That was correct
 * for measuring the filter — the actuator reacts to bitrate, so it fires in
 * whichever arm is most expensive and quarters its pixels, which would credit
 * the filter with the actuator's work. But it means the shipping combination is
 * the one combination never tested, and the two are coupled in a way that could
 * go badly: the filter's lock lives in a feedback texture sized to the frame, so
 * a resolution change throws the lock away and rebuilds it, and the actuator's
 * whole job is changing resolution. A filter that keeps getting reset and an
 * actuator that keeps resetting it can oscillate.
 *
 * IT ALSO REFRAMES THE BENEFIT. "62% fewer bits" is an abstraction. What a
 * person on a squeezed link actually gets is PIXELS: the actuator throws
 * resolution away to fit a budget, so spending fewer bits on the same picture
 * means it has to throw away less. This measures that directly — same budget,
 * same content, filter on versus off, and the question is how much resolution
 * survives.
 *
 * Budget is clamped hard (l2rcmin=l2rcmax) so the actuator is under real
 * pressure rather than idling — but the quantizer keeps a BAND, because the
 * actuator only restores resolution when it has quantizer headroom, and pinning
 * QP silently removes the recovery it is being asked about.
 *
 *   node testbed/pfrc.mjs [--budget=1.5] [--qpmin=20] [--qpmax=34] [--period=20] [--cycles=3]
 */
import { chromium } from 'playwright-core';
import { writeFileSync, mkdirSync } from 'node:fs';

const BASE = process.env.URL ?? 'https://room.tokkah.com';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
const arg = (k, d) => { const m = process.argv.find((a) => a.startsWith(`--${k}=`)); return m ? m.slice(k.length + 3) : d; };
const BUDGET = Number(arg('budget', 1.5));
// A BAND, not a pin. The actuator only restores resolution when the controller
// has quantizer headroom (`rcQp <= l2RcQpMax - 6`), so pinning qpmin == qpmax
// makes that branch unreachable and the divisor can shrink but never come back.
// The first run of this rig pinned at 20, watched the divisor stick at 4, and
// would have reported "the filter buys back no resolution" — a result entirely
// manufactured by the rig's own setup. The band is what production runs.
const QPMIN = Number(arg('qpmin', 20));
const QPMAX = Number(arg('qpmax', 34));
const PERIOD = Number(arg('period', 20));
const CYCLES = Number(arg('cycles', 3));
const OUT = arg('out', '/tmp/pfrc');
mkdirSync(OUT, { recursive: true });

const ARMS = [
  { name: 'off', on: false, p: null },
  { name: 'on', on: true, p: { denoise: 0.85, soften: 0, motionGain: 14, hold: 1 } },
];

const launch = (side) => chromium.launch({
  executablePath: CHROME, headless: true,
  args: [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    `--use-file-for-fake-video-capture=${media(`real${side}.mjpeg`)}`,
    `--use-file-for-fake-audio-capture=${media(`real${side}.wav`)}`,
    '--autoplay-policy=no-user-gesture-required',
    '--disable-features=WebRtcHideLocalIpsWithMdns', '--use-gl=angle', '--enable-gpu',
  ],
});

const read = (p) => p.evaluate(() => {
  const v = window.__tape?.video ?? {};
  return {
    t: performance.now(), bytes: v.encBytesTotal ?? null, frames: v.encFramesTotal ?? null,
    shrink: v.rcResShrink ?? 1, w: v.encW ?? v.width ?? null, h: v.encH ?? v.height ?? null,
    g2g: v.glassToGlassMs ?? null, still: v.pfStillMean ?? null,
    pfFallbacks: v.pfFallbacks ?? 0, rcQp: v.rcQp ?? null, budget: v.rcBudgetMbps ?? null,
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

const room = `pfrc-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 5)}`;
const A = await launch('A'), B = await launch('B');
const samples = new Map(ARMS.map((a) => [a.name, []]));
try {
  const a = await A.newPage(), b = await B.newPage();
  // rcres NOT disabled — that is the entire point. Budget clamped so the
  // actuator is under real pressure, quantizer left as a band so it can both
  // shrink AND restore, which is the coupling being tested.
  const qs = `l2rcqpmin=${QPMIN}&l2rcqpmax=${QPMAX}&qp=${QPMIN}&l2rcmin=${BUDGET}&l2rcmax=${BUDGET}`;
  for (const [p, who] of [[a, 'A'], [b, 'B']]) {
    await p.goto(`${BASE}/?r=${room}&${qs}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await p.waitForSelector('#join', { timeout: 20000 });
    await p.click('#join').catch(() => {});
    if (who === 'A') await p.waitForTimeout(1200);
  }
  for (const p of [a, b]) {
    await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });
  }
  console.log(`filter x resolution actuator — budget ${BUDGET} Mbps, qp band ${QPMIN}-${QPMAX}, actuator LIVE`);
  console.log(`${CYCLES} cycles x ${ARMS.length} arms x ${PERIOD}s, room ${room}\n`);
  await a.waitForTimeout(25000); // the actuator needs time to find its level

  for (let c = 0; c < CYCLES; c++) {
    for (const arm of (c % 2 ? [...ARMS].reverse() : ARMS)) {
      for (const p of [a, b]) {
        await p.evaluate(([on, params]) => window.__tape?.setPresenceFilter?.(on, params), [arm.on, arm.p]);
      }
      // Long settle: the actuator moves in steps and has to re-converge after
      // the bitrate changes under it. Measuring before it settles would record
      // the transient and call it the level.
      await a.waitForTimeout(8000);
      const a0 = await read(a), b0 = await read(b);
      const trail = [];
      for (let k = 0; k < 8; k++) { await a.waitForTimeout(PERIOD * 1000 / 8); trail.push((await read(a)).shrink); }
      const a1 = await read(a), b1 = await read(b);
      const mk = (s0, s1, side) => ({
        side, cyc: c,
        mbps: +((s1.bytes - s0.bytes) * 8 / ((s1.t - s0.t) / 1000) / 1e6).toFixed(3),
        fps: +((s1.frames - s0.frames) / ((s1.t - s0.t) / 1000)).toFixed(1),
        shrink: s1.shrink, g2g: s1.g2g, still: s1.still, rcQp: s1.rcQp,
        fallbacks: s1.pfFallbacks,
        // How many times the divisor changed while we watched: the actuator
        // hunting is a defect the average would hide completely.
        flaps: trail.filter((v, i) => i > 0 && v !== trail[i - 1]).length,
      });
      samples.get(arm.name).push(mk(a0, a1, 'A'), mk(b0, b1, 'B'));
      const last = samples.get(arm.name).slice(-2);
      console.log(`  c${c + 1} ${arm.name.padEnd(3)} ` +
        last.map((x) => `${x.side} ${x.mbps.toFixed(2)}Mbps /${x.shrink} @${x.fps}fps`).join('  ') +
        `  flaps ${last[0].flaps}`);
      if (c === CYCLES - 1) { await shot(a, `${arm.name}-A`); await shot(b, `${arm.name}-B`); }
    }
  }
} finally {
  await A.close(); await B.close();
}

const med = (v) => {
  const s = v.filter((x) => Number.isFinite(x)).sort((x, y) => x - y);
  if (!s.length) return null;
  return s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2;
};
const g = (n, k) => med(samples.get(n).map((r) => r[k]));
let fails = 0, incon = 0;
const check = (n, ok, d) => {
  if (ok === null) { incon++; console.log(`  INCONCLUSIVE  ${n}${d ? ` — ${d}` : ''}`); return; }
  if (!ok) fails++;
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${n}${d ? ` — ${d}` : ''}`);
};

console.log('\n══════ verdict ══════');
const sOff = g('off', 'shrink'), sOn = g('on', 'shrink');
check('both arms hold the budget', (g('off', 'mbps') ?? 9) <= BUDGET * 1.5 && (g('on', 'mbps') ?? 9) <= BUDGET * 1.5,
  `${g('off', 'mbps')?.toFixed(2)} / ${g('on', 'mbps')?.toFixed(2)} Mbps vs ${BUDGET}`);
// NOT a PASS when neither arm ever shrank. The first run of this rig printed
// "PASS — no change" at a 1.5 Mbps clamp where both arms sat at /1 the whole
// time, which reads as "the filter was tested against the actuator and did
// well" and actually means the actuator never woke up. A question the run did
// not put to the system has no answer, and a rig that grades it green is the
// blind rig this project has already shipped a defect through.
check('the filter buys back resolution',
  (sOff === 1 && sOn === 1) ? null : sOn <= sOff,
  (sOff === 1 && sOn === 1)
    ? `neither arm left /1 at ${BUDGET} Mbps — the actuator never fired, so this run cannot say. `
      + 'testbed/pffloor.mjs walks the budget down until it does'
    : `divisor ${sOff} with the filter off, ${sOn} with it on` +
      (sOn < sOff ? ` — ${((sOff / sOn) ** 2).toFixed(1)}x the pixels for the same budget` : ' — no change'));
// The currency under LIVE rate control is the quantizer, not the bitrate. The
// controller targets a bitrate, so a cheaper picture cannot show up as fewer
// bits — it shows up as a lower QP for the same bits. Reporting only Mbps here
// is how a working filter reads as a no-op.
const qOff = g('off', 'rcQp'), qOn = g('on', 'rcQp');
check('the filter buys quality at equal bits', qOn == null || qOff == null ? null : qOn <= qOff + 0.3,
  qOn == null || qOff == null ? 'no quantizer reading'
    : `qp ${qOff.toFixed(1)} -> ${qOn.toFixed(1)} at ${g('off', 'mbps')?.toFixed(2)} -> ${g('on', 'mbps')?.toFixed(2)} Mbps`
      + (qOn < qOff - 0.3 ? ` — ${(qOff - qOn).toFixed(1)} QP is roughly ${((1 - 2 ** (-(qOff - qOn) / 6)) * 100).toFixed(0)}% of the bits, taken as quality instead` : ''));
check('the actuator does not hunt', (g('on', 'flaps') ?? 9) <= 1,
  `${g('on', 'flaps')} divisor changes per ${PERIOD}s window (off arm: ${g('off', 'flaps')})`);
check('the filter never declined a frame', (g('on', 'fallbacks') ?? 1) === 0,
  `${g('on', 'fallbacks')} declines across resolution changes`);
check('frame rate held', Math.abs((g('on', 'fps') ?? 0) - (g('off', 'fps') ?? 0)) < 2,
  `${g('off', 'fps')?.toFixed(1)} -> ${g('on', 'fps')?.toFixed(1)} fps`);
check('the lock survives the actuator', (g('on', 'still') ?? 0) > 0.10,
  `${((g('on', 'still') ?? 0) * 100).toFixed(0)}% of the picture locked with resolution moving`);
console.log(`\n  stills: ${OUT}`);
console.log(`VERDICT: ${fails ? `FAIL (${fails})` : incon ? `INCONCLUSIVE (${incon})` : 'PASS'}`);
process.exit(fails ? 1 : incon ? 2 : 0);
