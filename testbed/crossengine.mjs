/**
 * A real cross-engine call where the HARNESS holds both ends and reads everything.
 *
 * WHY THIS EXISTS. Every long real-device session so far has depended on a human
 * looking at a screen and reporting what they saw, and the numbers came back thin:
 * the far side's telemetry was on an older bundle (`wastedShift undefined`), the
 * room's 2-occupant cap left no slot for an observer, and concealment was never
 * captured at all because the rig asked for a field that does not exist. Asking a
 * person "does it look smooth?" cannot answer any of that.
 *
 * So this drives BOTH browsers, in a fresh room, and reads both sides directly out
 * of the pages — no telemetry round-trip, no version skew, no cap contention, and
 * nothing that depends on anyone watching.
 *
 * WHAT IT IS NOT. Playwright's WebKit is not Safari. It lacks
 * MediaStreamTrackProcessor, so `tapeSupported()` is false and the video lane falls
 * back to stock RTP — which IS the answer real Safari 27 gave in a room log, so the
 * negotiation under test gets an identical input. But WebKit's codecs, audio stack
 * and pacing are its own, and a pass here is not a claim about Safari. It also
 * rejects `?transport=` ICE URLs that shipping Safari accepts (build strictness,
 * see app.js ice-tier-fallback). Read this as "cross-engine negotiation and both
 * lanes under a harness I control", not as "Safari verified".
 *
 *   node testbed/crossengine.mjs [--sec=90] [--query=tape=2] [--base=https://...]
 *                               [--every=5] [--shots]
 *
 * Gates on LUMA VARIANCE of the remote surface, not on connection state: the bug
 * this file exists to catch rendered a valid picture that was one black pixel while
 * every counter read healthy.
 */
import { webkit, chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';

const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const CAM = '/Users/earningsgpt/video calling/testbed/media/cam1080.mjpeg';
const AUD = '/Users/earningsgpt/video calling/testbed/media/conv/A.wav';
const SHOTS = '/Users/earningsgpt/video calling/testbed/out';

// Unknown flags must be FATAL: `--secs=` silently never matched `--sec=` on this
// project and every run took the default while reporting success.
const KNOWN = new Set(['sec', 'query', 'base', 'every', 'shots']);
for (const a of process.argv.slice(2)) {
  const m = /^--([a-z]+)(=|$)/.exec(a);
  if (!m || !KNOWN.has(m[1])) { console.error(`unknown flag: ${a}\nknown: ${[...KNOWN].map((k) => '--' + k).join(' ')}`); process.exit(2); }
}
const arg = (k, d) => {
  const m = process.argv.find((a) => a.startsWith(`--${k}=`));
  return m ? m.slice(k.length + 3) : d;
};
const SEC = Number(arg('sec', 90));
const EVERY = Number(arg('every', 5));
const QUERY = arg('query', 'tape=2');
const BASE = arg('base', 'https://room.tokkah.com');
const WANT_SHOTS = process.argv.includes('--shots');

const mkChromium = async () => {
  const ctx = await chromium.launchPersistentContext('', {
    executablePath: CHROME, headless: true,
    args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
      `--use-file-for-fake-video-capture=${CAM}`, `--use-file-for-fake-audio-capture=${AUD}`,
      '--autoplay-policy=no-user-gesture-required'],
    viewport: { width: 1000, height: 700 },
  });
  return { ctx, page: await ctx.newPage(), engine: 'Chromium' };
};
const mkWebKit = async () => {
  const browser = await webkit.launch({ headless: true });
  const ctx = await browser.newContext({ permissions: ['camera', 'microphone'], viewport: { width: 1000, height: 700 } });
  return { ctx, browser, page: await ctx.newPage(), engine: 'WebKit' };
};

/** Does the remote surface carry a real picture? sd ~0 is black; a face is > 8. */
const luma = (p) => p.evaluate(() => {
  const grab = (el, w, h) => {
    const c = document.createElement('canvas'); c.width = 64; c.height = 36;
    const g = c.getContext('2d', { willReadFrequently: true });
    try { g.drawImage(el, 0, 0, 64, 36); } catch { return null; } // tainted or not ready
    const d = g.getImageData(0, 0, 64, 36).data;
    let s = 0, s2 = 0, n = 0;
    for (let i = 0; i < d.length; i += 4) { const y = 0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2]; s += y; s2 += y * y; n++; }
    const m = s / n;
    return { src: el.id, w, h, mean: +m.toFixed(1), sd: +Math.sqrt(Math.max(0, s2 / n - m * m)).toFixed(1) };
  };
  const rc = document.getElementById('remoteCanvas');
  if (rc && rc.width > 1) return grab(rc, rc.width, rc.height);
  const v = document.getElementById('remote');
  if (v && v.videoWidth > 0) return grab(v, v.videoWidth, v.videoHeight);
  return { src: rc ? 'remoteCanvas' : 'remote', w: v?.videoWidth ?? 0, h: v?.videoHeight ?? 0, mean: null, sd: null };
});

/**
 * Both sides' own numbers, read straight from the page. Concealment is COMPUTED
 * from playedFrames/lostFrames rather than read from a `concealPct` field, because
 * no such field exists — reading it printed a dash for a whole 400 s run and looked
 * like a measured zero. Anything missing here is reported as the string 'MISSING',
 * never as a dash or a zero.
 */
const stats = (p) => p.evaluate(() => {
  const t = window.__tape ?? {};
  const q = t.pcm ?? null, v = t.video ?? null;
  const need = (o, k) => (o && o[k] !== undefined ? o[k] : 'MISSING');
  let pcm = null;
  if (q) {
    const played = q.playedFrames, lost = q.lostFrames;
    pcm = {
      conceal: typeof played === 'number' && typeof lost === 'number' && played + lost > 0
        ? +((100 * lost) / (played + lost)).toFixed(3) : 'MISSING',
      played: need(q, 'playedFrames'), lost: need(q, 'lostFrames'),
      framesRecv: need(q, 'framesRecv'), late: need(q, 'late'), dup: need(q, 'dup'),
      fecRepaired: need(q, 'fecRepaired'), depthMs: need(q, 'depthMs'),
      target: need(q, 'targetFrames'), driftPpm: need(q, 'driftPpm'),
      bPerFrame: need(q, 'bPerFrame'), mbpsSent: need(q, 'mbpsSent'),
      rxWastedShift: need(q, 'rxWastedShift'), rxFit32767: need(q, 'rxFit32767Pct'),
      spreadMaxRun: need(q, 'jitSpreadMaxRun'), holdMaxRun: need(q, 'jitHoldMaxRun'),
      outLatMs: need(q, 'outputLatencyMs'),
    };
  }
  return {
    pcm, tapeMode: t.tapeMode ?? null,
    video: v ? { fps: need(v, 'fps'), w: need(v, 'w'), h: need(v, 'h'), qp: need(v, 'qp'), kbps: need(v, 'kbps') } : null,
    status: document.getElementById('status')?.textContent ?? null,
  };
});

const fmt = (s) => {
  if (!s) return '    (no stats object)';
  const L = [`    status ${s.status}  tapeMode ${JSON.stringify(s.tapeMode)}`];
  if (s.video) L.push(`    video out  ${s.video.w}x${s.video.h} @${s.video.fps}fps qp ${s.video.qp} ${s.video.kbps}kbps`);
  if (s.pcm) {
    const q = s.pcm;
    L.push(`    audio in   conceal ${q.conceal}%  played ${q.played} lost ${q.lost}  recv ${q.framesRecv}  late ${q.late} dup ${q.dup} fec ${q.fecRepaired}`);
    L.push(`    buffer     depthMs ${q.depthMs}  target ${q.target}f  drift ${q.driftPpm}ppm  outLat ${q.outLatMs}ms  spreadMax ${q.spreadMaxRun} holdMax ${q.holdMaxRun}`);
    L.push(`    audio out  ${q.bPerFrame} B/frame  ${q.mbpsSent} Mbps  |  peer chain rxWastedShift ${q.rxWastedShift} rxFit32767 ${q.rxFit32767}%`);
  } else L.push('    audio      PCM lane not running on this engine');
  return L.join('\n');
};

for (const [label, first, second] of [['WebKit joins first', mkWebKit, mkChromium],
                                      ['Chromium joins first', mkChromium, mkWebKit]]) {
  const room = 'xe' + Math.random().toString(36).slice(2, 8);
  const A = await first(); const B = await second();
  console.log(`\n${'='.repeat(78)}\n${label}   room=${room}   ${QUERY}   ${SEC}s\n${'='.repeat(78)}`);
  const seen = [];
  try {
    for (const e of [A, B]) {
      await e.page.goto(`${BASE}/?r=${room}&${QUERY}`, { waitUntil: 'domcontentloaded' });
      await e.page.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
    }
    await A.page.click('#join');
    await A.page.waitForTimeout(700); // let the first occupant register before the second
    await B.page.click('#join');
    for (const e of [A, B]) {
      await e.page.waitForFunction(() => document.querySelector('#status')?.textContent === 'connected', null, { timeout: 40000 });
    }
    const t0 = Date.now();
    while (Date.now() - t0 < SEC * 1000) {
      await new Promise((r) => setTimeout(r, EVERY * 1000));
      const el = ((Date.now() - t0) / 1000).toFixed(0);
      console.log(`\n[t+${el}s]`);
      for (const e of [A, B]) {
        const [l, s] = await Promise.all([luma(e.page), stats(e.page)]);
        seen.push({ engine: e.engine, l, s });
        console.log(`  ${e.engine.padEnd(9)} sees ${l.src} ${l.w}x${l.h} luma mean=${l.mean} sd=${l.sd}` +
          ` ${l.sd > 8 ? '(real picture)' : '<-- BLACK/FLAT'}`);
        console.log(fmt(s));
      }
    }
    if (WANT_SHOTS) {
      for (const e of [A, B]) {
        const f = `${SHOTS}/xe-${room}-${e.engine}.png`;
        await e.page.screenshot({ path: f });
        console.log(`  shot ${f}`);
      }
    }
  } catch (err) {
    console.log(`  ERROR ${String(err).slice(0, 200)}`);
  }
  // The verdict uses the LAST sample from each engine, not the best one: a picture
  // that arrives and then freezes is the failure mode worth catching.
  const lastOf = (eng) => [...seen].reverse().find((x) => x.engine === eng);
  const fin = [lastOf('WebKit'), lastOf('Chromium')].filter(Boolean);
  const ok = fin.length === 2 && fin.every((x) => x.l?.sd > 8 && x.l.w > 1);
  console.log(`\n  ${ok ? 'PASS' : 'FAIL'}  ${label}: ${fin.map((x) => `${x.engine} sd=${x.l?.sd}`).join('  ')}`);
  await A.ctx.close(); if (A.browser) await A.browser.close();
  await B.ctx.close(); if (B.browser) await B.browser.close();
}
