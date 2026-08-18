/**
 * pffloor.mjs — how few bits does this picture need before it has to get worse?
 *
 * WHY THE EXISTING NUMBER DOES NOT ANSWER THAT. The presence filter's headline
 * is "61.5% fewer bits", measured with the quantizer PINNED. Pinning is the
 * right way to price a filter — it holds quality fixed so the bits are free to
 * move — but it is not how the product runs. With rate control live the
 * controller targets a BITRATE, so removing detail cannot lower the bitrate;
 * it lowers the quantizer instead, and the saving comes back as quality.
 * Measured on prod at a clamped 1.5 Mbps (testbed/pfrc.mjs, 3 cycles, arms
 * rotated): 1.23 Mbps with the filter off, 1.21 with it on. Under two percent.
 * Anyone reading that as "the filter does nothing" would be reading the wrong
 * instrument — but the instrument that says so has to exist.
 *
 * WHAT THIS MEASURES INSTEAD. Squeeze the budget until the picture is forced to
 * get worse, and find the budget where that happens. Under rate control the
 * degradation arrives in two stages, and both are recorded:
 *
 *   · the QP floor — the lowest budget at which the controller still has
 *     quantizer headroom. Below it the picture is softening every frame.
 *   · the PIXEL floor — the lowest budget at which the resolution actuator is
 *     still at /1. Below it the picture is literally smaller.
 *
 * The filter's value under rate control is the DISTANCE between those floors
 * with it on and with it off: how much less link the same picture needs.
 *
 * ONE CALL, NOT ONE CALL PER RUNG. `?l2rcmin/max` are query-string only, so a
 * ladder used to mean a page load per rung, which means a fresh call, fresh
 * ICE and a fresh point in the fixture loop per rung — and the quantity being
 * measured is a difference of a few percent, smaller than the spread between
 * two calls. The budget band is now a live lab knob, so the whole ladder walks
 * inside one connection and every rung is compared against the same path.
 *
 * WHAT WOULD MAKE THIS RIG WORTHLESS, guarded explicitly: a ladder whose bottom
 * rung never forces a shrink measures nothing and must not print PASS. If an
 * arm walks the whole ladder without ever pinning QP, or without ever losing
 * /1, the rig says INCONCLUSIVE and names the rung it ran out at.
 *
 *   node testbed/pffloor.mjs [--rungs=3,2,1.4,1,0.7,0.5,0.35,0.25] [--dwell=14] [--cycles=2]
 */
import { chromium } from 'playwright-core';
import { writeFileSync, mkdirSync } from 'node:fs';

const BASE = process.env.URL ?? 'https://room.tokkah.com';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
const arg = (k, d) => { const m = process.argv.find((a) => a.startsWith(`--${k}=`)); return m ? m.slice(k.length + 3) : d; };

const RUNGS = String(arg('rungs', '3,2,1.4,1,0.7,0.5,0.35,0.25')).split(',').map(Number);
const DWELL = Number(arg('dwell', 14));      // s per rung
const CYCLES = Number(arg('cycles', 2));     // arm-order rotations
const QPMIN = Number(arg('qpmin', 24));      // production band, deliberately
const QPMAX = Number(arg('qpmax', 42));
const TOP = RUNGS[0];
const OUT = arg('out', '/tmp/pffloor');
mkdirSync(OUT, { recursive: true });

// The filter's shipping parameters: soften OFF (it is the only lever that
// removes detail the camera saw, and it was worth 4 points against two that do
// not), denoise and hold at the values pfhold.mjs measured.
// `--soften=1` is the CALIBRATION arm, not a shipping configuration. The edge
// check below needs a bar, and a bar nobody has measured is a guess. Soften is
// the one lever that provably removes detail the camera saw — DESIGN.md 17.25
// records that at 1.0 the face texture and the nameplate lettering both visibly
// go — so running it deliberately is how to learn what real softening costs the
// statistic, and therefore where to put the line.
const PF = { denoise: 0.85, soften: Number(arg('soften', 0)), motionGain: 14, hold: 1 };
const ARMS = [{ name: 'off', on: false }, { name: 'on', on: true }];

// `--media=grain` swaps in the sensor-like fixture (testbed/media/real/grain.sh:
// temporal grain plus a hunting auto-exposure). Not a sensor and it does not
// satisfy the real-sensor law — but measured on the filter's OWN motion
// statistic it moves the lockable fraction of the picture from 92.7% to 61.5%,
// so it is a real stress test of the half of this filter that a clean fixture
// cannot test at all.
const SUFFIX = arg('media', '') === 'grain' ? '-grain' : '';
const launch = (side) => chromium.launch({
  executablePath: CHROME, headless: true,
  args: [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    `--use-file-for-fake-video-capture=${media(`real${side}${SUFFIX}.mjpeg`)}`,
    `--use-file-for-fake-audio-capture=${media(`real${side}${SUFFIX}.wav`)}`,
    '--autoplay-policy=no-user-gesture-required',
    '--disable-features=WebRtcHideLocalIpsWithMdns', '--use-gl=angle', '--enable-gpu',
  ],
});

const read = (p) => p.evaluate(() => {
  const v = window.__tape?.video ?? {};
  // Lane A's cumulative bytes alongside the encoder's. The budget knob steers
  // VIDEO, but the thing the goal is denominated in is a CALL, and audio here
  // is uncompressed PCM — at a filtered video rate near 1 Mbps it stops being
  // a rounding error and becomes something like half the bill. Reporting only
  // the video number would make the call look cheaper than it is.
  const a = window.__tape?.pcm ?? {};
  return {
    t: performance.now(),
    abytes: a.bytesSent ?? null,
    bytes: v.encBytesTotal ?? null, frames: v.encFramesTotal ?? null,
    shrink: v.rcResShrink ?? 1, qp: v.rcQp ?? null, budget: v.rcBudgetMbps ?? null,
    duress: v.rcDuress ?? 0, still: v.pfStillMean ?? null, fallbacks: v.pfFallbacks ?? 0,
    holdThresh: v.pfHoldThresh ?? null,
    g2g: v.glassToGlassMs ?? null,
  };
});

// ── What the DECODED picture actually looks like ─────────────────────────────
// QP is the encoder's own opinion and it is the honest headline, but it is
// still a setting rather than an observation. This reads the frame the far side
// is showing.
//
// TWO numbers, because one would repeat the mistake VMAF makes here. Total
// high-frequency energy falls when grain is removed, and grain removal is the
// whole point — scoring on it alone marks the filter down for working. So:
//
//   hf        mean |Laplacian| over the whole picture. Grain lives here.
//             Expected to FALL with the filter on, and that is not damage.
//   edgeFrac  the FRACTION of pixels above a fixed |Laplacian| > 48 — the
//             actual edges: the eyes, the lettering, the jacket seam. A blur
//             destroys these. Fixed, not a percentile: a top-decile threshold
//             is set by the distribution itself, so removing a broadband noise
//             floor moves the threshold and drags the number down by itself.
//
// AND THE HONEST LIMIT OF BOTH, because two attempts to get past it failed and
// the next person should not spend the same hours. Neither statistic can
// CLASSIFY what it detects. Grain sits on top of real edges and pushes
// borderline ones over any cut, so grain removal lowers edgeFrac too — at the
// 8 Mbps rung it reads about -5% while the stills at that rung show identical
// nameplate lettering and identical badge stitching beside visibly smoother
// fabric.
//
// The obvious fix does not work either. Structure persists across frames and
// grain does not, so the edge count of the time-AVERAGED picture should be
// structure alone — built, measured, removed: on moving footage its own
// cycle-to-cycle spread is 40-105%, because what it actually measures is how
// much the subject happened to move during that particular window. A statistic
// noisier than the effect is worse than no statistic, because it will either be
// ignored or believed.
//
// So this rig DETECTS a change and refuses to classify it, and the bar is the
// arm's own measured cycle-to-cycle spread rather than a number anyone chose.
// The instrument that classifies it is testbed/pfhold.mjs, which derives where
// the PERSON is from the control arm and asserts those cells still change with
// the lock engaged — the question "did the face soften" asked directly, on the
// only region where the answer matters.
//
// AND IT MUST NOT COST THE THING IT IS WATCHING. The first version read back
// the whole 1280x720 frame and sorted 920k magnitudes, eight times per rung, on
// the same main thread that decodes and paints — and the run's own fps column
// showed it: 26.6 and 28.0 where every other run of this call reads 30.0. An
// instrument that drops frames is measuring itself. So:
//   · a CROP at native scale, not a downscale — a bilinear shrink is itself a
//     low-pass filter and would hide exactly the blur this is looking for;
//   · a 256-bin histogram instead of a sort, so the decile is O(n);
//   · `cost` returned, so the rig can assert the instrument stayed cheap
//     rather than trusting that it did.
const GRAB_PX = 512;
const grab = (p) => p.evaluate((SZ) => {
  const t0 = performance.now();
  const c = document.getElementById('remoteCanvas');
  const v = document.getElementById('remote');
  const sw = c?.width || v?.videoWidth || 0, sh = c?.height || v?.videoHeight || 0;
  if (!sw || !sh) return null;
  const w = Math.min(SZ, sw), h = Math.min(SZ, sh);
  const sx = Math.floor((sw - w) / 2), sy = Math.floor((sh - h) / 2);
  let t = window.__pfGrabCanvas;
  if (!t || t.width !== w || t.height !== h) {
    t = window.__pfGrabCanvas = document.createElement('canvas');
    t.width = w; t.height = h;
    window.__pfGrabCtx = t.getContext('2d', { willReadFrequently: true });
  }
  const g = window.__pfGrabCtx;
  g.drawImage(c?.width ? c : v, sx, sy, w, h, 0, 0, w, h);
  const d = g.getImageData(0, 0, w, h).data;
  const lum = new Float32Array(w * h);
  for (let i = 0, j = 0; j < lum.length; i += 4, j++) lum[j] = 0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2];
  // |Laplacian| tops out at 4*255; 256 bins of 4 is finer than the metric's
  // own noise and keeps the histogram in L1.
  const hist = new Int32Array(256);
  let n = 0, sum = 0, lsum = 0;
  for (let y = 1; y < h - 1; y++) {
    const r = y * w;
    for (let x = 1; x < w - 1; x++) {
      const i = r + x;
      const m = Math.abs(4 * lum[i] - lum[i - 1] - lum[i + 1] - lum[i - w] - lum[i + w]);
      sum += m; lsum += lum[i]; n++;
      hist[Math.min(255, m >> 2)]++;
    }
  }
  if (!n) return null;
  // Walk the histogram down until the top decile is covered, then take the mean
  // of that tail using bin centres. Bin width 4 on a metric that ranges to 1020
  // makes the quantisation error under half a percent of the values in play.
  const want = Math.max(1, Math.floor(n * 0.1));
  let got = 0, topSum = 0;
  for (let b = 255; b >= 0 && got < want; b--) {
    const take = Math.min(hist[b], want - got);
    topSum += take * (b * 4 + 2); got += take;
  }
  // AND THE SAME THING AT A FIXED CUT, because the decile is not the clean
  // separator it looks like. Its threshold is set by the distribution, so
  // removing a broadband noise floor lowers the threshold, changes WHICH
  // pixels are in the top tenth, and drags hfTop down by itself. Measured: at
  // the 8 Mbps rung hfTop read -4.3% with the filter on, and the stills at
  // that rung show identical nameplate lettering, identical badge stitching
  // and smoother fabric — grain removal, scored as damage.
  //
  // A fixed cut does not move when the floor does. 48 sits far above grain
  // (whole-picture mean |Laplacian| here is ~6) and well inside real edges, so
  // `edgeN` — the FRACTION of pixels that are strong edges — is the statistic
  // that separates the two failure modes: a blur destroys strong edges and
  // takes edgeN with it; removing grain leaves them where they were.
  const CUT = 48;
  let edgeN = 0, edgeSum = 0;
  for (let b = CUT >> 2; b < 256; b++) { edgeN += hist[b]; edgeSum += hist[b] * (b * 4 + 2); }
  return {
    hf: sum / n, hfTop: got ? topSum / got : 0,
    edgeFrac: edgeN / n, edgeMean: edgeN ? edgeSum / edgeN : 0,
    lum: lsum / n, w, h, cost: performance.now() - t0,
  };
}, GRAB_PX);

// Both knobs through the SHIPPED lab whitelist, and the reply is checked. A
// refused knob that reads as a null result is the failure this project has
// already paid for twice.
const setBudget = async (p, mbps) => {
  const r = await p.evaluate((m) => window.__tape?.lab?.({ op: 'set', rcMin: m, rcMax: m }), mbps);
  if (!r || r.applied?.rcMax !== mbps) throw new Error(`budget ${mbps} refused: ${JSON.stringify(r)}`);
};
const setFilter = async (p, on) => {
  const r = await p.evaluate(([o, pp]) => window.__tape?.lab?.({ op: 'set', pfilter: o ? 1 : 0, ...pp }),
    [on, PF]);
  if (!r || r.applied?.pfilter !== (on ? 1 : 0)) throw new Error(`pfilter ${on} refused: ${JSON.stringify(r)}`);
};

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

const room = `pff-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 5)}`;
const A = await launch('A'), B = await launch('B');
/** rows: {arm, cyc, rung, side, mbps, fps, shrink, qp, pinned} */
const rows = [];
try {
  const a = await A.newPage(), b = await B.newPage();
  const qs = `l2rcqpmin=${QPMIN}&l2rcqpmax=${QPMAX}&l2rcmin=${TOP}&l2rcmax=${TOP}`;
  for (const [p, who] of [[a, 'A'], [b, 'B']]) {
    await p.goto(`${BASE}/?r=${room}&${qs}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await p.waitForSelector('#join', { timeout: 20000 });
    await p.click('#join').catch(() => {});
    if (who === 'A') await p.waitForTimeout(1200);
  }
  for (const p of [a, b]) {
    await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });
  }
  console.log(`budget ladder inside ONE call — qp band ${QPMIN}-${QPMAX}, actuator LIVE`
    + (SUFFIX ? '  [SENSOR-LIKE FIXTURE: grain + hunting auto-exposure]' : '')
    + (PF.soften ? `  [CALIBRATION: soften=${PF.soften}, deliberately damaging the picture]` : ''));
  console.log(`rungs ${RUNGS.join(' / ')} Mbps, ${DWELL}s each, ${CYCLES} cycles, room ${room}\n`);
  await a.waitForTimeout(20000); // let the controller find its level at the top rung

  for (let c = 0; c < CYCLES; c++) {
    for (const arm of (c % 2 ? [...ARMS].reverse() : ARMS)) {
      // Reset to the top rung and WAIT FOR /1 TO COME BACK before descending.
      // Promotion needs 10 s of quantizer headroom, so a ladder that starts
      // while the previous arm's divisor is still 4 measures the last arm.
      for (const p of [a, b]) { await setBudget(p, TOP); await setFilter(p, arm.on); }
      let restored = false;
      for (let i = 0; i < 40 && !restored; i++) {
        await a.waitForTimeout(1000);
        restored = (await read(a)).shrink === 1 && (await read(b)).shrink === 1;
      }
      if (!restored) throw new Error(`resolution never came back to /1 before arm ${arm.name} c${c + 1}`);

      console.log(`  c${c + 1} ${arm.name}:`);
      for (const rung of RUNGS) {
        for (const p of [a, b]) await setBudget(p, rung);
        // Half the dwell settling, half measuring: the controller steps QP by
        // at most 1.5 per frame and the actuator needs 2 s of pinned-and-over,
        // so a reading taken immediately records the transit, not the level.
        await a.waitForTimeout(DWELL * 500);
        const a0 = await read(a), b0 = await read(b);
        // Sample the decoded picture across the measurement half, not once.
        // Two arms of a sequential A/B never see the same fixture frame, so a
        // single grab compares two different moments and says nothing; a mean
        // over the dwell is a property of the arm.
        const ga = [], gb = [];
        for (let k = 0; k < 6; k++) {
          await a.waitForTimeout(DWELL * 500 / 6);
          const [x, y] = await Promise.all([grab(a), grab(b)]);
          if (x) ga.push(x); if (y) gb.push(y);
        }
        const a1 = await read(a), b1 = await read(b);
        const avg = (v, k) => (v.length ? v.reduce((s, x) => s + x[k], 0) / v.length : null);
        const mk = (s0, s1, side) => ({
          arm: arm.name, cyc: c, rung, side,
          mbps: +((s1.bytes - s0.bytes) * 8 / ((s1.t - s0.t) / 1000) / 1e6).toFixed(3),
          ambps: s1.abytes != null && s0.abytes != null
            ? +((s1.abytes - s0.abytes) * 8 / ((s1.t - s0.t) / 1000) / 1e6).toFixed(3) : null,
          fps: +((s1.frames - s0.frames) / ((s1.t - s0.t) / 1000)).toFixed(1),
          shrink: s1.shrink, qp: s1.qp, budget: s1.budget, duress: s1.duress,
          still: s1.still, fallbacks: s1.fallbacks, holdThresh: s1.holdThresh,
          pinned: s1.qp != null && s1.qp >= QPMAX - 0.5,
        });
        // The grab is of what THIS page is SHOWING, which is the far side's
        // encode — so A's picture is B's arm and vice versa. Both ends carry
        // the same arm here, so the attribution is unambiguous either way, but
        // recording it the wrong way round would matter the moment an arm is
        // ever set on one side only.
        const pic = (v) => ({
          hf: avg(v, 'hf'), hfTop: avg(v, 'hfTop'), edgeFrac: avg(v, 'edgeFrac'),
          edgeMean: avg(v, 'edgeMean'), cost: avg(v, 'cost'), grabs: v.length,
        });
        const ra = { ...mk(a0, a1, 'A'), ...pic(ga) };
        const rb = { ...mk(b0, b1, 'B'), ...pic(gb) };
        rows.push(ra, rb);
        const fmt = (r) => `${r.side} ${r.mbps.toFixed(2)}Mbps qp${r.qp?.toFixed(1)} /${r.shrink} @${r.fps}fps`;
        console.log(`    ${String(rung).padStart(4)} Mbps  ${fmt(ra)}  ${fmt(rb)}`);
        if (ra.duress || rb.duress) console.log(`      note: audio duress ${ra.duress}/${rb.duress} — budget was cut below the rung`);
        if (c === CYCLES - 1) { await shot(a, `${arm.name}-${rung}-A`); await shot(b, `${arm.name}-${rung}-B`); }
      }
    }
  }
} finally {
  await A.close(); await B.close();
}

writeFileSync(`${OUT}/rows.json`, JSON.stringify(rows, null, 1));

// ── verdict ──────────────────────────────────────────────────────────────────
// A floor is the LOWEST rung that was still clean, and it is taken per side and
// per cycle and then medianed, so one noisy rung on one side cannot set it.
const sides = ['A', 'B'];
const floorOf = (arm, ok) => {
  const per = [];
  for (let c = 0; c < CYCLES; c++) for (const side of sides) {
    const mine = rows.filter((r) => r.arm === arm && r.cyc === c && r.side === side);
    if (!mine.length) continue;
    // Walk down; the floor is the last rung before the first failure. `null`
    // means it never failed — the ladder did not go low enough to find out.
    let last = null, found = false;
    for (const r of [...mine].sort((x, y) => y.rung - x.rung)) {
      if (!ok(r)) { found = true; break; }
      last = r.rung;
    }
    per.push(found ? last : null);
  }
  return per;
};
const med = (v) => {
  const s = v.filter((x) => Number.isFinite(x)).sort((x, y) => x - y);
  if (!s.length) return null;
  return s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2;
};
const summarise = (arm, ok) => { const p = floorOf(arm, ok); return { per: p, med: med(p), never: p.some((x) => x === null) }; };

const okPix = (r) => r.shrink === 1;
const okQp = (r) => !r.pinned;
const pixOff = summarise('off', okPix), pixOn = summarise('on', okPix);
const qpOff = summarise('off', okQp), qpOn = summarise('on', okQp);

let fails = 0, incon = 0;
const check = (n, v, d) => {
  if (v === null) { incon++; console.log(`  INCONCLUSIVE  ${n}${d ? ` — ${d}` : ''}`); return; }
  if (!v) fails++;
  console.log(`  ${v ? 'PASS' : 'FAIL'}  ${n}${d ? ` — ${d}` : ''}`);
};
const bottom = RUNGS[RUNGS.length - 1];

console.log('\n══════ floors ══════');
console.log(`  pixel floor (last rung still at /1)     off ${pixOff.med ?? '—'}   on ${pixOn.med ?? '—'}  Mbps`);
console.log(`  quantizer floor (last rung not pinned)  off ${qpOff.med ?? '—'}   on ${qpOn.med ?? '—'}  Mbps`);

console.log('\n══════ verdict ══════');
check('the ladder reached the pixel floor',
  pixOff.never ? null : true,
  pixOff.never
    ? `the filter-off arm held /1 at the bottom rung (${bottom} Mbps) — the ladder never squeezed hard enough to find its floor`
    : `off arm lost /1 below ${pixOff.med} Mbps`);
check('the ladder reached the quantizer floor',
  qpOff.never ? null : true,
  qpOff.never
    ? `the filter-off arm never pinned QP down to ${bottom} Mbps`
    : `off arm pinned below ${qpOff.med} Mbps`);
check('the filter lowers the pixel floor',
  pixOff.never || pixOn.never ? null : pixOn.med <= pixOff.med,
  pixOff.med && pixOn.med
    ? `${pixOff.med} -> ${pixOn.med} Mbps` +
      (pixOn.med < pixOff.med ? ` — full resolution survives on ${(100 * (1 - pixOn.med / pixOff.med)).toFixed(0)}% less link` : ' — no change')
    : 'not reached');
check('the filter lowers the quantizer floor',
  qpOff.never || qpOn.never ? null : qpOn.med <= qpOff.med,
  qpOff.med && qpOn.med
    ? `${qpOff.med} -> ${qpOn.med} Mbps` +
      (qpOn.med < qpOff.med ? ` — the picture stops softening on ${(100 * (1 - qpOn.med / qpOff.med)).toFixed(0)}% less link` : ' — no change')
    : 'not reached');

// At every rung both arms saw, the filter must not cost quality. This is the
// check that would catch the filter making things WORSE under pressure, which
// the floors alone would hide if both arms crossed at the same rung.
const at = (arm, rung, k) => med(rows.filter((r) => r.arm === arm && r.rung === rung).map((r) => r[k]));
// A rung where the samples did not all sit at the SAME divisor is not a
// comparison and must not be scored as one. Near the bottom of the ladder the
// actuator is right on its own edge and different sides land differently
// within a single rung — the first run of this compared a /1 median against a
// /2 median and duly reported the filter "costing quality", which is a
// quarter-resolution picture being averaged in, not a filter doing anything.
// Reported rather than silently dropped: a rung the ladder could not resolve
// is a fact about the ladder.
const divisorsAt = (g) => new Set(rows.filter((r) => r.rung === g).map((r) => r.shrink));
const both = RUNGS.filter((g) => rows.some((r) => r.arm === 'off' && r.rung === g) && rows.some((r) => r.arm === 'on' && r.rung === g));
const mixed = both.filter((g) => divisorsAt(g).size > 1);
const shared = both.filter((g) => divisorsAt(g).size === 1);
// The same arm, the same rung, two different cycles: whatever this moves by is
// the fixture and the network, not the filter. It is the only honest bar for
// the between-arm difference below.
const nullSpread = (g) => {
  const per = [];
  for (const arm of ['off', 'on']) {
    const c = [];
    for (let k = 0; k < CYCLES; k++) {
      const v = med(rows.filter((r) => r.arm === arm && r.rung === g && r.cyc === k).map((r) => r.edgeFrac));
      if (v != null) c.push(v);
    }
    if (c.length >= 2) per.push(Math.abs(c[0] - c[1]) / ((c[0] + c[1]) / 2));
  }
  return per.length ? Math.max(...per) : null;
};

console.log('\n  per rung (median of both sides, all cycles, same divisor across every sample):');
console.log('    rung   Mbps off->on    qp off->on   /div  fps     grain hf      strong edges');
let qpWins = 0, qpLoses = 0, edgeLoses = 0, edgeSeen = 0;
const edgeRatios = [];
const pct = (o, n) => (o && n != null ? `${n > o ? '+' : ''}${(100 * (n / o - 1)).toFixed(1)}%` : '  —  ');
for (const g of shared) {
  const qo = at('off', g, 'qp'), qn = at('on', g, 'qp');
  const so = at('off', g, 'shrink'), sn = at('on', g, 'shrink');
  const fo = at('off', g, 'fps'), fn = at('on', g, 'fps');
  const mo = at('off', g, 'mbps'), mn = at('on', g, 'mbps');
  const ho = at('off', g, 'hf'), hn = at('on', g, 'hf');
  const eo = at('off', g, 'edgeFrac'), en = at('on', g, 'edgeFrac');
  if (qn != null && qo != null) { if (qn < qo - 0.3) qpWins++; else if (qn > qo + 0.3) qpLoses++; }
  // THE BAR IS CALIBRATED AGAINST A REAL BLUR, not guessed and not set to the
  // noise floor. `--soften=1` turns on the one lever that provably destroys
  // detail the camera saw, and run deliberately it costs this statistic
  // -69.0% and -70.1% at two rungs. The shipping configuration costs 5-9%.
  // An order of magnitude apart, so 25% is a line neither can be near by
  // accident: it certifies "nothing was grossly softened", which is what this
  // rig can honestly issue, and it would catch soften being left on.
  //
  // It deliberately does NOT try to adjudicate the 5-9%. Three attempts failed
  // and the reason is structural: everything the filter removes — sensor grain,
  // coding noise, held-block residual — is broadband and lives in the same
  // statistic as fine detail. See the header.
  const nul = nullSpread(g);
  if (eo != null && en != null) {
    edgeSeen++;
    if (en < eo * 0.75) edgeLoses++;
    // The one thing the pair of numbers CAN say, calibrated on both sides:
    // blur drags edges down FASTER than it drags total energy (soften=1 reads
    // -32.7% hf against -69% edges, a ratio of 0.5), while removing noise does
    // the opposite (grain fixture: -27.2% hf against -5.2% edges, ratio 5.2).
    //
    // GATED ON THERE BEING SOMETHING TO DIVIDE. Ungated, this called BLUR on
    // the clean fixture's shipping arm at a ratio of 0.7 — where hf had moved
    // 6% and edges 5%, two small numbers whose quotient means nothing, and
    // where the stills beside it show crisp nameplate lettering next to a
    // soften=1 arm that has visibly lost it. 15% of total energy is the bar:
    // above it something substantial was removed and the ratio can speak to
    // what; below it the honest answer is silence. All three calibration
    // points sit cleanly on one side or the other.
    if (ho && hn && eo && en && en < eo && (1 - hn / ho) >= 0.15) {
      const rat = (1 - hn / ho) / (1 - en / eo);
      if (Number.isFinite(rat)) edgeRatios.push({ g, rat });
    }
  }
  console.log(`    ${String(g).padStart(4)}   ${mo?.toFixed(2)}->${mn?.toFixed(2)}    `
    + `${qo?.toFixed(1)}->${qn?.toFixed(1)}   /${so}   ${fo?.toFixed(0)}/${fn?.toFixed(0)}   `
    + `${ho?.toFixed(2)}->${hn?.toFixed(2)} ${pct(ho, hn)}   `
    + `${pct(eo, en)} (its own null +-${((nul ?? 0) * 100).toFixed(1)}%)`);
}
if (mixed.length) {
  console.log(`    (${mixed.join(', ')} Mbps not scored — the actuator sat on its own edge there and`
    + ' samples within the rung disagreed on the divisor)');
}
check('the filter never costs quality at a shared rung', qpLoses === 0,
  `${qpWins} rungs better, ${qpLoses} worse (0.3 QP deadband)`);
// The check that stops "fewer bits" from being bought with a softer picture.
// The strong EDGES have to survive; the grain is allowed — expected — to go.
check('nothing was grossly softened', edgeSeen === 0 ? null : edgeLoses === 0,
  edgeSeen === 0 ? 'no decoded frames were grabbed'
    : `strong-edge fraction inside 25% on ${edgeSeen - edgeLoses}/${edgeSeen} rungs `
      + '(a real blur, measured with --soften=1, costs 69%)');
if (edgeRatios.length) {
  const r = med(edgeRatios.map((x) => x.rat));
  console.log(`  ....  on ${edgeRatios.length} rung(s) something substantial was removed: total energy fell `
    + `${r?.toFixed(1)}x as fast as the edges — `
    + `${r > 2 ? 'the signature of NOISE REMOVAL' : r < 0.8 ? 'the signature of BLUR — look at the stills' : 'ambiguous'}`
    + ' (blur calibrates at 0.5, grain removal at 5.2)');
} else {
  console.log('  ....  no rung removed enough total energy (15%) for the noise-vs-blur ratio to mean anything');
}
check('frame rate held everywhere', shared.every((g) => Math.abs((at('on', g, 'fps') ?? 0) - (at('off', g, 'fps') ?? 0)) < 2),
  shared.map((g) => `${at('off', g, 'fps')?.toFixed(0)}/${at('on', g, 'fps')?.toFixed(0)}`).join(' '));
check('the filter never declined a frame', (med(rows.filter((r) => r.arm === 'on').map((r) => r.fallbacks)) ?? 1) === 0,
  `${med(rows.filter((r) => r.arm === 'on').map((r) => r.fallbacks))} declines across the whole ladder`);
// Did the lock engage at all, and did its threshold have to climb to get
// there? On a clean fixture it should not move off 0.012. On a noisy sensor it
// ratchets upward and saturates at 0.02 — and a saturated threshold beside a
// near-zero stillMean is the filter's silent failure mode, where the bitrate
// win evaporates and every other number still looks fine.
const stillOn = med(rows.filter((r) => r.arm === 'on').map((r) => r.still));
const thrOn = med(rows.filter((r) => r.arm === 'on').map((r) => r.holdThresh));
check('the lock engaged', stillOn == null ? null : stillOn > 0.10,
  `${((stillOn ?? 0) * 100).toFixed(0)}% of the picture held, threshold at ${thrOn ?? '—'}`
  + (thrOn != null && thrOn >= 0.02 ? ' — SATURATED: this content is noisier than the lock can follow' : ''));
// The instrument has to be cheap enough not to be part of the result. 30 fps is
// a 33 ms budget on the thread this runs on; a grab over ~15 ms would be
// stealing a visible slice of it six times a rung.
const cost = med(rows.map((r) => r.cost));
check('the picture probe stayed off the critical path', cost == null ? null : cost < 15,
  `${cost?.toFixed(1)} ms per grab, 6 grabs per rung`);

// Two separate questions that one check used to conflate, and it blamed the
// wrong thing: the OFF arm has no filter, so its worst reading is the PROBE's
// cost, and only the gap between the arms can be the filter's.
const worstOff = Math.min(...rows.filter((r) => r.arm === 'off').map((r) => r.fps).filter(Number.isFinite));
const worstOn = Math.min(...rows.filter((r) => r.arm === 'on').map((r) => r.fps).filter(Number.isFinite));
check('the probe left the frame rate alone', worstOff >= 29.5, `filter-off arm never below ${worstOff.toFixed(1)} fps`);
check('the filter left the frame rate alone', worstOn >= 28.5,
  `filter-on arm worst rung ${worstOn.toFixed(1)} fps against the off arm's ${worstOff.toFixed(1)}`
  + (worstOn < worstOff - 0.5 ? ' — the GPU pass costs a visible fraction of a frame at the top of the ladder' : ''));

// What the CALL costs, which is the number the goal is written in. Taken at
// the top rung, where neither arm is squeezed and both sit at the quantizer
// floor — the only rung where the two arms are at equal quality by
// construction and the bits are therefore directly comparable.
const aud = med(rows.filter((r) => r.rung === TOP).map((r) => r.ambps));
const vOff = at('off', TOP, 'mbps'), vOn = at('on', TOP, 'mbps');
if (aud != null && vOff != null && vOn != null) {
  console.log(`\n  the whole call at the top rung, both arms at the quantizer floor (qp ${QPMIN}):`);
  console.log(`    filter off   video ${vOff.toFixed(2)} + audio ${aud.toFixed(2)} = ${(vOff + aud).toFixed(2)} Mbps`);
  console.log(`    filter on    video ${vOn.toFixed(2)} + audio ${aud.toFixed(2)} = ${(vOn + aud).toFixed(2)} Mbps`
    + `   (video ${(100 * (1 - vOn / vOff)).toFixed(0)}% cheaper at the same quantizer)`);
}

console.log(`\n  stills + rows.json: ${OUT}`);
console.log(`VERDICT: ${fails ? `FAIL (${fails})` : incon ? `INCONCLUSIVE (${incon})` : 'PASS'}`);
process.exit(fails ? 1 : incon ? 2 : 0);
