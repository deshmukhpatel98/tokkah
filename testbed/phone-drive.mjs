/**
 * phone-drive — drives the real Android phone's Chrome over CDP and measures
 * what the camera actually delivers. Invoked by ../phone-test.sh, which owns
 * every pre-flight check; by the time this runs, the device, the reverse
 * tunnel, the permissions and the DevTools socket are all known good.
 *
 * It measures the ONE thing the fake camera can never show: capture-side
 * delivery on real silicon. Everything here is read off the device — delivered
 * fps from the app's own source probe, exposure/iso/size from the track's
 * getSettings(), scene brightness from the luma watchdog. No model, no fixture.
 *
 * A peer is deliberately not required: task #37's starvation happens at
 * capture, before an encoder or a network exists, so a solo join measures it
 * cleanly. (`call.mjs` is still the harness for the two-ended path.)
 */
import { chromium } from 'playwright-core';

const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const b = a.replace(/^--/, '');
    const i = b.indexOf('=');
    return i === -1 ? [b, true] : [b.slice(0, i), b.slice(i + 1)];
  }),
);
const CDP = args.cdp ?? 'http://127.0.0.1:9222';
const BASE = (args.url ?? 'http://127.0.0.1:8794').replace(/\/$/, '');
const SECS = Number(args.secs ?? 75);
const SAMPLE_MS = 2000;

const ARMS = {
  // The shipped defaults: ladder + measured stepper + low-light + revival.
  // `rig=1` is not read by the app — any non-`r` query key marks the page as
  // a harness and silences the fleet health beacon. The real phone drives
  // Chrome over CDP with NO automation flag, so navigator.webdriver is false
  // and, without this, every driven run would land in fleet stats as a real
  // user's call (measured: the emulator lane put its 400-1000 ms m2e there).
  default: 'rig=1',
  // Everything off. The control arm exists so a "fix" that changed nothing is
  // visible as changing nothing (measure-before-claiming).
  control: 'ladder=0&lowlight=0&revive=0',
  // Low-light only, no resolution stepping — isolates the exposure lever.
  lowlight: 'stepper=0',
  // Resolution only, no exposure lever — the round-1 ladder, for comparison.
  stepper: 'lowlight=0',
};
// Exposure sweep, in the device's 100-microsecond units. 0 = the shipped
// default (1000/fps ≈ 42 units ≈ 4.2 ms). The rest walk the trade: a longer
// exposure is a brighter picture and a lower fps ceiling. The best value is
// the largest one that still clears ~20 fps.
const SWEEP_UNITS = [0, 100, 200, 333, 500];

const pad = (s, n) => String(s).padEnd(n);
const num = (v, n = 1) => (v == null || Number.isNaN(v) ? '—' : (+v).toFixed(n));

async function connect() {
  const browser = await chromium.connectOverCDP(CDP);
  const ctx = browser.contexts()[0];
  if (!ctx) throw new Error('no browser context on the device');
  // TWO permissions are needed and they are not the same thing. `pm grant`
  // (in phone-test.sh) gives the Chrome APP the Android camera permission;
  // this gives the SITE Chrome's own per-origin permission. Without the
  // second, getUserMedia does not fail — it HANGS on a prompt nobody taps,
  // and the join sits at "starting…" forever with srcprobe null.
  await ctx.grantPermissions(['camera', 'microphone'], { origin: BASE }).catch((e) => {
    console.log(`      [warn] could not pre-grant site permissions: ${e.message}`);
  });
  // Close OUR OWN leftover tabs first (never the owner's — only this origin).
  // A previous arm's tab still holds its camera stream, and the M13's HAL will
  // not hand the same camera to a second tab: the app then falls back to its
  // audio-only degraded path and every video number comes back null.
  for (const p of ctx.pages()) {
    if (!p.isClosed() && p.url().startsWith(BASE)) await p.close().catch(() => {});
  }
  return { browser, ctx, page: await freshPage(ctx) };
}

/**
 * A brand-new tab per arm, with the old one CLOSED and a real pause after.
 *
 * Navigating one tab from arm to arm looks equivalent and is not: the M13 then
 * delivers a single frame and stalls for ~8 s, so everything the app times from
 * join — the exposure lock above all — runs against a frozen picture, and the
 * second arm of every run measured something the first arm never did. Rested on
 * a fresh tab, the same arm is correct 3 runs out of 3.
 */
async function freshPage(ctx, settleMs = 0) {
  for (const p of ctx.pages()) {
    if (!p.isClosed() && p.url().startsWith(BASE)) await p.close().catch(() => {});
  }
  if (settleMs) await new Promise((r) => setTimeout(r, settleMs));
  const page = await ctx.newPage();
  page.on('pageerror', (e) => console.log(`      [page error] ${e.message}`));
  page.on('console', (m) => {
    if (m.type() === 'error') console.log(`      [console] ${m.text().slice(0, 160)}`);
  });
  // A bare "503" in the console names no URL, which is the difference between
  // a diagnosis and an afternoon. Always say WHICH request failed.
  page.on('response', (r) => {
    if (r.status() >= 400) console.log(`      [http ${r.status()}] ${r.request().method()} ${r.url().slice(0, 120)}`);
  });
  page.on('requestfailed', (r) => console.log(`      [req failed] ${r.url().slice(0, 120)} — ${r.failure()?.errorText ?? '?'}`));
  return page;
}

/**
 * The camera is a single-holder resource on this phone and the previous arm's
 * page does not hand it back the instant the tab closes. Joining against a busy
 * HAL makes the app take its audio-only fallback, which reports every video
 * number as null and reads exactly like "the feature did nothing" — three runs
 * of this harness were lost to that before it was understood.
 *
 * The app's own lobby badge is the signal: it says 'camera ready' or
 * 'camera blocked (NotReadableError)'. Reload until it's ready.
 */
async function loadWithCamera(page, url, tries = 8) {
  for (let i = 0; i < tries; i++) {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForSelector('#join', { timeout: 20000 });
    const badge = await page
      .waitForFunction(() => /ready|blocked/.test(document.getElementById('previewBadge')?.textContent ?? ''), { timeout: 15000 })
      .then((h) => h.jsonValue().then(() => page.evaluate(() => document.getElementById('previewBadge').textContent)))
      .catch(() => 'timeout');
    if (/ready/.test(badge)) return true;
    if (i === 0) process.stdout.write(`[cam ${badge.trim()}] `);
    await page.waitForTimeout(1500);
  }
  return false;
}

/** Navigate, join, and sample the camera for `secs`. Returns the run record. */
async function runArm(ctx, label, query, attempt = 1) {
  // 6 s of no camera holder at all — measured as the gap the M13's HAL needs.
  const page = await freshPage(ctx, 6000);
  try {
    return await armBody(page, ctx, label, query, attempt);
  } finally {
    await page.close().catch(() => {});
  }
}

async function armBody(page, ctx, label, query, attempt = 1) {
  const url = query ? `${BASE}/?${query}` : `${BASE}/`;
  process.stdout.write(`  ${pad(attempt > 1 ? `${label} (retry)` : label, 22)} `);
  const camOk = await loadWithCamera(page, url);
  if (!camOk) console.log(`\n      [camera busy] ${label}: lobby never reported 'camera ready'`);
  await page.click('#join');
  // The lobby's "starting…" text never clears after a successful join — it is
  // cosmetic and it is NOT a join signal. The call container becoming visible
  // is the real one.
  try {
    await page.waitForFunction(
      () => {
        const el = document.getElementById('call');
        return el && getComputedStyle(el).display !== 'none';
      },
      { timeout: 30000 },
    );
  } catch (e) {
    // Dump the state the app itself can see before giving up — a join timeout
    // with no context costs the next session the same twenty minutes.
    const st = await page
      .evaluate(() => ({
        joinStatus: document.getElementById('joinStatus')?.textContent ?? null,
        status: document.getElementById('status')?.textContent ?? null,
        lobbyShown: getComputedStyle(document.getElementById('lobby')).display,
        callShown: getComputedStyle(document.getElementById('call')).display,
        tape: window.__tape ? { devTier: window.__tape.devTier, srcprobe: window.__tape.srcprobe } : null,
      }))
      .catch(() => null);
    console.log(`      [join timeout] ${JSON.stringify(st)}`);
    throw e;
  }

  // Joined — but did it join WITH a camera? `srcprobe` is armed inside join()
  // the moment the stream has a video track, so a null here after 8 s means the
  // app went down its audio-only path and there is nothing to measure. Retry the
  // whole arm once rather than reporting a row of dashes that reads like a
  // negative result.
  // Frames FLOWING, not merely a probe object: an armed probe stuck at 1 frame
  // is the stalled-HAL case above, and sampling it measures a frozen picture.
  const gotVideo = await page
    .waitForFunction(() => (window.__tape?.srcprobe?.frames ?? 0) > 5, { timeout: 12000 })
    .then(() => true)
    .catch(() => false);
  if (!gotVideo) {
    const why = await page.evaluate(() => document.getElementById('previewBadge')?.textContent ?? null).catch(() => null);
    console.log(`\n      [no video] ${label}: joined audio-only — badge "${String(why).trim()}"`);
    if (attempt < 2) {
      return runArm(ctx, label, query, attempt + 1);
    }
    throw new Error(`${label}: no camera after 2 attempts`);
  }

  const samples = [];
  let lastFrames = null;
  let lastT = null;
  const t0 = Date.now();
  while (Date.now() - t0 < secsToMs(SECS)) {
    await page.waitForTimeout(SAMPLE_MS);
    const s = await page.evaluate(() => {
      const t = window.__tape;
      if (!t) return null;
      const sp = t.srcprobe;
      return {
        now: performance.now(),
        frames: sp?.frames ?? null,
        settings: sp?.settings ?? null,
        readyState: sp?.readyState ?? null,
        luma: t.luma?.y ?? null,
        lowlight: t.lowlight ?? null,
        devTier: t.devTier ?? null,
      };
    });
    if (!s) continue;
    let fps = null;
    if (lastFrames != null && s.frames != null && s.now > lastT) {
      fps = ((s.frames - lastFrames) / (s.now - lastT)) * 1000;
    }
    lastFrames = s.frames;
    lastT = s.now;
    samples.push({ ...s, fps });
    process.stdout.write('.');
  }
  process.stdout.write('\n');

  const withFps = samples.filter((x) => x.fps != null);
  const early = withFps.slice(0, 3);
  const late = withFps.slice(-5);
  const mean = (xs, f) => (xs.length ? xs.reduce((a, b) => a + (f(b) ?? 0), 0) / xs.length : null);
  const last = samples[samples.length - 1] ?? {};
  return {
    label,
    query,
    fpsEarly: mean(early, (x) => x.fps),
    fpsLate: mean(late, (x) => x.fps),
    lumaEarly: mean(early, (x) => x.luma),
    lumaLate: mean(late, (x) => x.luma),
    expEarly: early[0]?.settings?.exposureTime ?? null,
    expLate: last?.settings?.exposureTime ?? null,
    iso: last?.settings?.iso ?? null,
    size: last?.settings ? `${last.settings.width}x${last.settings.height}` : '—',
    lowlightOn: !!last?.lowlight?.on,
    tier: last?.devTier?.stepTier ?? last?.devTier?.tier ?? '—',
    tierWhy: last?.devTier?.why ?? '—',
    caps: samples[0]?.settings ? null : null,
    zeroSamples: withFps.filter((x) => x.fps === 0).length,
    samples: withFps.length,
  };
}
const secsToMs = (s) => s * 1000;

function table(rows) {
  console.log('');
  console.log(`  ${pad('arm', 22)}${pad('fps early', 11)}${pad('fps late', 10)}${pad('luma', 8)}${pad('exposure', 10)}${pad('iso', 6)}${pad('size', 11)}${pad('low-light', 11)}tier`);
  console.log(`  ${'-'.repeat(101)}`);
  for (const r of rows) {
    const exp = r.expLate != null ? `${num(r.expLate, 0)}u/${num(r.expLate / 10, 1)}ms` : '—';
    console.log(
      `  ${pad(r.label, 22)}${pad(num(r.fpsEarly), 11)}${pad(num(r.fpsLate), 10)}${pad(num(r.lumaLate, 0), 8)}${pad(exp, 10)}${pad(num(r.iso, 0), 6)}${pad(r.size, 11)}${pad(r.lowlightOn ? 'ENGAGED' : 'no', 11)}${r.tier}`,
    );
  }
}

function verdict(rows) {
  console.log('');
  const def = rows.find((r) => r.label === 'default');
  const ctl = rows.find((r) => r.label === 'control');
  const say = (s) => console.log(`  ${s}`);
  if (def?.zeroSamples) say(`⚠ ${def.zeroSamples}/${def.samples} samples delivered ZERO frames — the stall path should have fired; check the revive log.`);
  if (def && ctl) {
    const d = def.fpsLate - ctl.fpsLate;
    const pct = ctl.fpsLate > 0 ? (d / ctl.fpsLate) * 100 : 0;
    if (Math.abs(pct) < 10) {
      say(`NO EFFECT: default ${num(def.fpsLate)} fps vs control ${num(ctl.fpsLate)} fps (${num(pct, 0)}%).`);
      say(`  If the room was bright this is CORRECT — nothing should have engaged. If it was dark, the fix did not fire:`);
      say(`  low-light needs luma < 20 AND delivered fps < 60% of the ask. Measured luma was ${num(def.lumaLate, 0)}.`);
    } else if (d > 0) {
      say(`✓ IMPROVEMENT: ${num(ctl.fpsLate)} → ${num(def.fpsLate)} fps (+${num(pct, 0)}%), low-light ${def.lowlightOn ? 'engaged' : 'did NOT engage'}.`);
      say(`  Cost: luma ${num(ctl.lumaLate, 0)} → ${num(def.lumaLate, 0)} of 255 (a darker but smoother picture).`);
    } else {
      say(`✗ REGRESSION: ${num(ctl.fpsLate)} → ${num(def.fpsLate)} fps (${num(pct, 0)}%). The ladder made it worse — do not ship.`);
    }
  }
  const sweep = rows.filter((r) => r.label.startsWith('llexp='));
  if (sweep.length) {
    const good = sweep.filter((r) => r.fpsLate >= 20);
    const best = good.sort((a, b) => b.expLate - a.expLate)[0];
    if (best) {
      say(`Sweep: brightest exposure still holding 20 fps is ${num(best.expLate, 0)} units (${num(best.expLate / 10, 1)} ms) → luma ${num(best.lumaLate, 0)}, ${num(best.fpsLate)} fps.`);
      const shipped = sweep.find((r) => r.label === 'llexp=0');
      if (shipped) say(`  Shipped default sits at ${num(shipped.expLate, 0)} units → luma ${num(shipped.lumaLate, 0)}, ${num(shipped.fpsLate)} fps.`);
    } else {
      say(`Sweep: no exposure setting held 20 fps — the ceiling is not exposure here. Look at the encoder, not the camera.`);
    }
  }
}

// ── main ─────────────────────────────────────────────────────────────────────
let browser;
try {
  const c = await connect();
  browser = c.browser;
  const page = c.page;
  const info = await page.evaluate(() => ({ ua: navigator.userAgent, w: screen.width, h: screen.height }));
  await page.close().catch(() => {}); // each arm opens its own; don't leave this one holding a slot
  const { ctx } = c;
  console.log(`  ua        ${info.ua.slice(0, 110)}`);
  console.log('');

  const rows = [];
  if (args.sweep) {
    console.log(`  exposure sweep — ${SWEEP_UNITS.length} arms × ${SECS}s (100-microsecond units; 0 = shipped default)`);
    for (const u of SWEEP_UNITS) {
      rows.push(await runArm(ctx, `llexp=${u}`, u === 0 ? 'devtier=weak' : `devtier=weak&llexp=${u}`));
    }
  } else if (args.arm && args.arm !== 'default') {
    rows.push(await runArm(ctx, args.arm, ARMS[args.arm] ?? String(args.arm)));
  } else {
    console.log(`  2 arms × ${SECS}s — default, then the everything-off control`);
    rows.push(await runArm(ctx, 'default', ARMS.default));
    rows.push(await runArm(ctx, 'control', ARMS.control));
  }

  table(rows);
  verdict(rows);
  console.log('');
} catch (e) {
  console.error(`\n  ✗ the drive failed: ${e?.message ?? e}`);
  console.error(`    → the device was reachable (pre-flight passed), so this is the page or the app, not the cable.`);
  process.exitCode = 40;
} finally {
  // Disconnect, never close: closing the target prints a non-JSON "Target is
  // closing" and takes the user's Chrome down with it.
  try {
    await browser?.close();
  } catch {}
}
