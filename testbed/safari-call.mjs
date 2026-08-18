/**
 * safari-call.mjs — REAL Safari <-> Chromium cross-engine call (task #42).
 *
 * crossengine.mjs measures Playwright's WebKit build; every "Safari" number on
 * this project so far came from that stand-in. This drives the user's actual
 * Safari over safaridriver (WebDriver REST, no extra deps) against the same
 * Chromium peer, on prod. Requires Safari > Develop > Developer settings >
 * "Allow remote automation" (user enabled 2026-08-04).
 *
 * Real Safari has no fake-media flags and WebDriver cannot answer the camera
 * permission prompt, so the page runs with ?synthmedia=1 (app.js test hook:
 * getUserMedia replaced by canvas + noise-graph tracks; the pipeline under
 * test — worklets, coder, datachannel, buffer — is the shipping code).
 *
 * Usage: node testbed/safari-call.mjs [--sec=90] [--every=5] [--query=...] [--base=...]
 */
import { spawn } from 'node:child_process';
import { chromium } from '/Users/deveshpatel/Downloads/video calling/testbed/node_modules/playwright-core/index.mjs';

const CHROME = process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const CAM = '/Users/deveshpatel/Downloads/video calling/testbed/media/cam1080.mjpeg';
const AUD = '/Users/deveshpatel/Downloads/video calling/testbed/media/conv/A.wav';

// Unknown flags must be FATAL (see crossengine.mjs for the incident).
const KNOWN = new Set(['sec', 'query', 'base', 'every', 'port', 'order', 'peer', 'queryA', 'queryB', 'stall', 'stallms', 'stallevery', 'stallfrom', 'json', 'realcam']);
for (const a of process.argv.slice(2)) {
  const m = /^--([a-zA-Z]+)(=|$)/.exec(a);
  if (!m || !KNOWN.has(m[1])) { console.error(`unknown flag: ${a}\nknown: ${[...KNOWN].map((k) => '--' + k).join(' ')}`); process.exit(2); }
}
const arg = (k, d) => {
  const m = process.argv.find((a) => a.startsWith(`--${k}=`));
  return m ? m.slice(k.length + 3) : d;
};
const SEC = Number(arg('sec', 90));
const EVERY = Number(arg('every', 5));
const QUERY = arg('query', 'tape=2&pcmdiag=1');
// Per-side queries (task #47): A is the SAFARI side, B the peer. A per-side
// parameter belongs on the two ends of ONE call (relpair precedent).
const QUERY_A = arg('queryA', QUERY);
const QUERY_B = arg('queryB', QUERY);
const BASE = arg('base', 'https://room.tokkah.com');
// --realcam drops the synthmedia hook and lets Safari open the ACTUAL sensor.
// The header above says WebDriver cannot answer a camera prompt, and that is
// true — but it is only a blocker the FIRST time. Safari persists camera
// permission per site, so if room.tokkah.com has been granted once by hand,
// getUserMedia resolves with no prompt and the run is on a real sensor. That
// is the one route to satisfying the real-sensor law from this machine:
// Chrome for Testing gets no answer at all (camprobe: "HUNG", 1 video input
// present) and the in-app browser refuses by policy (NotAllowedError).
const REALCAM = process.argv.includes('--realcam');
const PORT = Number(arg('port', 4747));
// --peer=brave runs the REAL installed Brave (its own binary, throwaway
// profile) so the pair is two shipping browsers — the configuration the
// governor verdict is required to hold in.
const PEER = arg('peer', 'chromium');
if (!['chromium', 'brave'].includes(PEER)) { console.error('--peer must be chromium|brave'); process.exit(2); }
const BRAVE = '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser';
// Stall stimulus, same shape and defaults as realpair.mjs: a main-thread block
// is the faithful clump generator. a = Safari, b = peer, both = same instant.
const STALL = arg('stall', '0');
if (!['0', 'both', 'a', 'b'].includes(STALL)) { console.error('--stall must be 0|both|a|b'); process.exit(2); }
const STALL_MS = Number(arg('stallms', 120));
const STALL_EVERY = Number(arg('stallevery', 10));
const STALL_FROM = Number(arg('stallfrom', 15));
const JSON_OUT = arg('json', null);

// ── Minimal WebDriver client over safaridriver ───────────────────────────────
const wd = async (method, path, body) => {
  const res = await fetch(`http://127.0.0.1:${PORT}${path}`, {
    method, headers: { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(90_000), // pairing can take ~25 s; a hang must not be silent
  });
  const j = await res.json();
  if (!res.ok) throw new Error(`webdriver ${method} ${path}: ${JSON.stringify(j.value ?? j).slice(0, 300)}`);
  return j.value;
};

const driver = spawn('safaridriver', ['-p', String(PORT)], { stdio: ['ignore', 'pipe', 'pipe'] });
let driverErr = '';
driver.stderr.on('data', (d) => { driverErr += d; });
driver.on('exit', (c) => { if (c) console.error(`safaridriver exited ${c}: ${driverErr.slice(0, 400)}`); });
// Wait for the port to accept sessions.
let sid = null;
for (let i = 0; i < 40 && !sid; i++) {
  try {
    // First pairing after enabling "Allow remote automation" can fail once with
    // "instance terminated while trying to pair" — the loop absorbs it.
    const v = await wd('POST', '/session', { capabilities: { alwaysMatch: { browserName: 'safari', 'webkit:alwaysAllowAutoplay': true } } });
    sid = v.sessionId;
  } catch { await new Promise((r) => setTimeout(r, 500)); }
}
if (!sid) { console.error(`could not open a Safari session on :${PORT} — is "Allow remote automation" on? driver said: ${driverErr.slice(0, 400)}`); process.exit(1); }

const S = {
  engine: 'Safari',
  goto: (url) => wd('POST', `/session/${sid}/url`, { url }),
  // execute/sync wraps the body in a function; `return` works as in Playwright's evaluate.
  eval: (script, ...args) => wd('POST', `/session/${sid}/execute/sync`, { script, args }),
  click: async (css) => {
    const el = await wd('POST', `/session/${sid}/element`, { using: 'css selector', value: css });
    const id = Object.values(el)[0];
    await wd('POST', `/session/${sid}/element/${id}/click`, {});
  },
  close: async () => { try { await wd('DELETE', `/session/${sid}`); } catch {} driver.kill(); },
};

const ctx = await chromium.launchPersistentContext('', {
  executablePath: PEER === 'brave' ? BRAVE : CHROME,
  headless: PEER !== 'brave', // real Brave runs headed; headless would change its scheduling class
  args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
    `--use-file-for-fake-video-capture=${CAM}`, `--use-file-for-fake-audio-capture=${AUD}`,
    '--autoplay-policy=no-user-gesture-required', '--no-first-run', '--mute-audio'],
  viewport: { width: 1000, height: 700 },
});
const C = { engine: PEER === 'brave' ? 'Brave' : 'Chromium', page: await ctx.newPage() };

// ── Shared in-page probes (source of truth: crossengine.mjs) ─────────────────
const LUMA_SRC = `
  const grab = (el) => {
    const c = document.createElement('canvas'); c.width = 64; c.height = 36;
    const g = c.getContext('2d', { willReadFrequently: true });
    try { g.drawImage(el, 0, 0, 64, 36); } catch { return null; }
    const d = g.getImageData(0, 0, 64, 36).data;
    let s = 0, s2 = 0, n = 0;
    for (let i = 0; i < d.length; i += 4) { const y = 0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2]; s += y; s2 += y * y; n++; }
    const m = s / n;
    // videoWidth FIRST: a <video> el.width is 0 (no attribute), and 0 ?? x never falls through.
    return { src: el.id, w: el.videoWidth || el.width, h: el.videoHeight || el.height, mean: +m.toFixed(1), sd: +Math.sqrt(Math.max(0, s2 / n - m * m)).toFixed(1) };
  };
  const rc = document.getElementById('remoteCanvas');
  if (rc && rc.width > 1) return grab(rc);
  const v = document.getElementById('remote');
  if (v && v.videoWidth > 0) return grab(v);
  return { src: rc ? 'remoteCanvas' : 'remote', w: v?.videoWidth ?? 0, h: v?.videoHeight ?? 0, mean: null, sd: null };
`;
const STATS_SRC = `
  const t = window.__tape ?? {};
  const q = t.pcm ?? null;
  const need = (o, k) => (o && o[k] !== undefined ? o[k] : 'MISSING');
  let pcm = null;
  if (q) {
    const played = q.playedFrames, lost = q.lostFrames;
    pcm = {
      conceal: typeof played === 'number' && typeof lost === 'number' && played + lost > 0
        ? +((100 * lost) / (played + lost)).toFixed(3) : 'MISSING',
      played: need(q, 'playedFrames'), lost: need(q, 'lostFrames'), framesRecv: need(q, 'framesRecv'),
      late: need(q, 'late'), depthMs: need(q, 'depthMs'), target: need(q, 'targetFrames'),
      bPerFrame: need(q, 'bPerFrame'), mbpsSent: need(q, 'mbpsSent'), outLatMs: need(q, 'outputLatencyMs'),
      spreadMaxRun: need(q, 'jitSpreadMaxRun'), holdMaxRun: need(q, 'jitHoldMaxRun'),
      lateFrames: need(q, 'lateFrames'), want: need(q, 'jitWant'),
      govOn: need(q, 'govOn'), govTrim: need(q, 'govTrim'), govFloor: need(q, 'govFloor'),
      govPops: need(q, 'govPops'), govTrimTicks: need(q, 'govTrimTicks'),
      diag: q.diag ?? null,
    };
  }
  const why = (t.tel?.mirror ?? []).filter((e) => /^(tape-fallback|tapemin|error)$/.test(e.kind)).slice(-6)
    .map((e) => e.kind + ' ' + JSON.stringify(e.data).slice(0, 140));
  return { pcm, tapeMode: t.tapeMode ?? null, why, status: document.getElementById('status')?.textContent ?? null };
`;
const probe = async (e) => {
  if (e.page) {
    return {
      l: await e.page.evaluate(new Function(LUMA_SRC)),
      s: await e.page.evaluate(new Function(STATS_SRC)),
    };
  }
  return { l: await e.eval(LUMA_SRC), s: await e.eval(STATS_SRC) };
};
const fmt = (s) => {
  if (!s?.pcm) return `    status ${s?.status}  (PCM lane not running)`;
  const q = s.pcm;
  const L = [`    status ${s.status}  tapeMode ${JSON.stringify(s.tapeMode)}${s.why?.length ? '\n    why        ' + s.why.join(' | ') : ''}`,
    `    audio in   conceal ${q.conceal}%  played ${q.played} lost ${q.lost}  recv ${q.framesRecv}  late ${q.late}`,
    `    buffer     depthMs ${q.depthMs}  target ${q.target}f  outLat ${q.outLatMs}ms  spreadMax ${q.spreadMaxRun} holdMax ${q.holdMaxRun}`,
    `    audio out  ${q.bPerFrame} B/frame  ${q.mbpsSent} Mbps`];
  if (q.diag) {
    const d = (r) => (r ? `p50 ${r.p50} p90 ${r.p90} p99 ${r.p99} max ${r.max} (n=${r.n})` : '(warming)');
    L.push(`    diag cap   ${d(q.diag.cap)}`, `    diag send  ${d(q.diag.send)}`, `    diag recv  ${d(q.diag.recv)}`);
  }
  return L.join('\n');
};

const room = 'sf' + Math.random().toString(36).slice(2, 8);
console.log(`\nREAL Safari <-> ${C.engine}   room=${room}   A=${QUERY_A} B=${QUERY_B}   ${SEC}s${STALL !== '0' ? `  stall=${STALL} ${STALL_MS}ms/${STALL_EVERY}s from ${STALL_FROM}s` : ''}\n${'='.repeat(78)}`);
try {
  await S.goto(`${BASE}/?r=${room}&${QUERY_A}${REALCAM ? '' : '&synthmedia=1'}`);
  // Wedge tracer. Batch of 2026-08-05: runs died at "never connected" with
  // Safari's #status reading "connecting…" — which is that div's DEFAULT text,
  // visible call screen or not, so the error line said nothing. These hooks
  // record what the join flow actually did (fetches, WS lifecycle, page
  // errors) so a failing run carries its own diagnosis out.
  await S.eval(`
    window.__net = []; window.__errs = [];
    const OF = window.fetch;
    window.fetch = function (...a) {
      const u = String(a[0]);
      const p = OF.apply(this, a);
      if (!/telemetry|\\/log/.test(u)) {
        p.then((r) => window.__net.push('fetch ' + u.slice(-40) + ' -> ' + r.status),
               (e) => window.__net.push('fetch ' + u.slice(-40) + ' -> THREW ' + String(e).slice(0, 80)));
      }
      return p;
    };
    const OW = window.WebSocket;
    window.WebSocket = function (url, proto) {
      const w = proto === undefined ? new OW(url) : new OW(url, proto);
      window.__net.push('ws new ' + String(url).slice(-60));
      w.addEventListener('open', () => window.__net.push('ws OPEN'));
      w.addEventListener('close', (e) => window.__net.push('ws CLOSE ' + e.code + ' ' + (e.reason || '').slice(0, 60)));
      w.addEventListener('error', () => window.__net.push('ws ERROR'));
      return w;
    };
    window.WebSocket.prototype = OW.prototype;
    Object.assign(window.WebSocket, OW);
    window.addEventListener('error', (e) => window.__errs.push('ERR ' + e.message + ' @ ' + (e.filename || '').split('/').pop() + ':' + (e.lineno || 0)));
    window.addEventListener('unhandledrejection', (e) => window.__errs.push('REJ ' + String((e.reason && e.reason.message) || e.reason).slice(0, 150)));
    return 1;
  `);
  await C.page.goto(`${BASE}/?r=${room}&${QUERY_B}`, { waitUntil: 'domcontentloaded' });
  // Preview up on both (Safari's is the synthetic canvas).
  for (let i = 0; i < 60; i++) {
    const ok = await S.eval(`return (document.querySelector('#preview')?.videoWidth ?? 0) > 0;`);
    if (ok) break;
    if (i === 59) {
      throw new Error(REALCAM
        ? 'Safari preview never lit — the camera prompt is probably sitting unanswered. '
          + 'WebDriver cannot click it. Open Safari by hand once, load '
          + `${BASE}, allow the camera, then re-run with --realcam.`
        : 'Safari preview never lit (synthmedia hook not live?)');
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  // IS IT ACTUALLY A SENSOR? A camera macOS has denied does not throw: the
  // promise resolves, the track reads "live", videoWidth is non-zero, and every
  // frame is uniformly black. Waiting for videoWidth would report a real-sensor
  // run while measuring a black rectangle — a rig blind to the defect it exists
  // to catch. A real room is never uniform and never twice identical, so this
  // demands spatial variance AND frame-to-frame change before the numbers from
  // this run are allowed to be called real-sensor numbers.
  if (REALCAM) {
    const cam = await S.eval(`
      const v = document.querySelector('#preview');
      const t = (v.srcObject && v.srcObject.getVideoTracks && v.srcObject.getVideoTracks()[0]) || null;
      const c = document.createElement('canvas'); c.width = 160; c.height = 90;
      const x = c.getContext('2d');
      const luma = () => { x.drawImage(v, 0, 0, 160, 90);
        const d = x.getImageData(0, 0, 160, 90).data, a = new Float64Array(14400);
        for (let i = 0; i < 14400; i++) a[i] = 0.299*d[i*4] + 0.587*d[i*4+1] + 0.114*d[i*4+2];
        return a; };
      const f0 = luma();
      const t0 = Date.now(); while (Date.now() - t0 < 250) {}
      const f1 = luma();
      let m = 0; for (const q of f0) m += q; m /= 14400;
      let vv = 0; for (const q of f0) vv += (q - m) * (q - m); vv /= 14400;
      let ch = 0; for (let i = 0; i < 14400; i++) ch += Math.abs(f1[i] - f0[i]); ch /= 14400;
      return JSON.stringify({ label: t && t.label, w: v.videoWidth, h: v.videoHeight,
        mean: +m.toFixed(1), variance: +vv.toFixed(1), change: +ch.toFixed(3) });
    `);
    const r = JSON.parse(cam);
    const real = r.variance > 25 && r.change > 0.2;
    console.log(`  REAL SENSOR CHECK: "${r.label}" ${r.w}x${r.h}  mean ${r.mean} `
      + `variance ${r.variance} change ${r.change}/px  -> ${real ? 'REAL' : 'NOT REAL'}`);
    if (!real) {
      throw new Error(`--realcam asked for a sensor and got a ${r.variance <= 25 ? 'flat' : 'frozen'} picture `
        + `(variance ${r.variance}, change ${r.change}). macOS is denying the camera to Safari, or it is `
        + 'covered. Refusing to report these as real-sensor numbers.');
    }
  }
  await C.page.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
  // --order=c puts Chromium in first (role a). The Playwright pair runs the
  // lane in that order and falls back in the other — join order is a variable,
  // not a constant (task #44).
  // Safari's WebDriver click is intermittently SWALLOWED: the command succeeds
  // but the handler never fires (measured 2026-08-05: joinStatus empty, button
  // still enabled, no telemetry object, page healthy — three batches died on
  // it). The handler disables the button synchronously, so "did the click
  // land" is checkable; retry the trusted click until it does. A JS click()
  // is NOT an acceptable fallback — the audio graph needs the user gesture.
  // Three ways in, tried in order of trustworthiness. The element click wedges
  // DETERMINISTICALLY in a long-lived Safari process (measured 2026-08-05:
  // 15/15 swallowed across three runs, lobby pixel-perfect in the screenshot,
  // handler never fired) and Safari cannot be restarted here — it may hold the
  // user's own windows. The Actions API is a separate input path; the JS
  // click() is untrusted but sufficient in THIS session because
  // webkit:alwaysAllowAutoplay removes the user-gesture requirement the
  // trusted click existed for — and the run's own playedFrames counters
  // verify audio actually flows, so a silent-audio regression cannot hide.
  const landedQ = `return document.getElementById('join')?.disabled === true
    || document.getElementById('status')?.textContent !== 'connecting…'
    || !!(window.__tape ?? {}).tel;`;
  const safariJoin = async () => {
    const attempts = [
      ['element click', () => S.click('#join')],
      ['actions api', async () => {
        const el = await wd('POST', `/session/${sid}/element`, { using: 'css selector', value: '#join' });
        const id = Object.values(el)[0];
        const rect = await wd('GET', `/session/${sid}/element/${id}/rect`);
        const x = Math.round(rect.x + rect.width / 2), y = Math.round(rect.y + rect.height / 2);
        await wd('POST', `/session/${sid}/actions`, { actions: [{
          type: 'pointer', id: 'mouse', parameters: { pointerType: 'mouse' },
          actions: [
            { type: 'pointerMove', duration: 50, x, y, origin: 'viewport' },
            { type: 'pointerDown', button: 0 }, { type: 'pause', duration: 60 },
            { type: 'pointerUp', button: 0 },
          ],
        }] });
      }],
      ['js click', () => S.eval(`document.getElementById('join').click(); return 1;`)],
    ];
    for (const [name, go] of attempts) {
      try { await go(); } catch (e) { console.log(`  safari join via ${name} threw: ${String(e.message).slice(0, 100)}`); continue; }
      await new Promise((r) => setTimeout(r, 800));
      if (await S.eval(landedQ)) { if (name !== 'element click') console.log(`  safari join landed via ${name}`); return; }
      console.log(`  safari join via ${name} swallowed`);
    }
    throw new Error('safari join never landed (element click, actions api, js click all swallowed)');
  };
  if (arg('order', 's') === 'c') {
    await C.page.click('#join');
    await new Promise((r) => setTimeout(r, 700));
    await safariJoin(); // trusted click: user gesture for the audio graph
  } else {
    await safariJoin();
    await new Promise((r) => setTimeout(r, 700));
    await C.page.click('#join');
  }
  for (let i = 0; i < 80; i++) {
    const [a, b] = await Promise.all([
      S.eval(`return document.getElementById('status')?.textContent;`),
      C.page.evaluate(() => document.getElementById('status')?.textContent),
    ]);
    if (a === 'connected' && b === 'connected') break;
    if (i === 79) {
      const sd = await S.eval(`
        const t = window.__tape ?? {};
        return JSON.stringify({
          joinStatus: document.getElementById('joinStatus')?.textContent ?? null,
          joinDisabled: document.getElementById('join')?.disabled ?? null,
          tel: !!t.tel, pc: !!t.pc,
          net: (window.__net ?? []).slice(-10),
          errs: (window.__errs ?? []).slice(-6),
        });`).catch((e) => `safari probe failed: ${e.message.slice(0, 100)}`);
      const bd = await C.page.evaluate(() => {
        const t = window.__tape ?? {};
        const sig = (t.tel?.mirror ?? []).filter((e) => /^(ws-rx|role|ice-config)/.test(e.kind))
          .slice(-6).map((e) => e.kind + ':' + JSON.stringify(e.data).slice(0, 60));
        return JSON.stringify({ tel: !!t.tel, pc: !!t.pc, sig });
      }).catch((e) => `peer probe failed: ${String(e).slice(0, 100)}`);
      throw new Error(`never connected (Safari="${a}" Chromium="${b}")\n  SAFARI ${sd}\n  PEER   ${bd}`);
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  const seen = [];
  const series = { safari: [], peer: [] };
  const stallsFired = [];
  const t0 = Date.now();
  // Stall targets: a = Safari, b = peer. `execute/sync` runs in Safari's page
  // and blocks its main thread exactly as evaluate does in the peer.
  const stallOne = (e) => (e.page
    ? e.page.evaluate((ms) => { const t = performance.now(); while (performance.now() - t < ms); }, STALL_MS)
    : e.eval(`const t = performance.now(); while (performance.now() - t < ${STALL_MS});`));
  const stallTargets = STALL === 'both' ? [S, C] : STALL === 'a' ? [S] : STALL === 'b' ? [C] : [];
  let nextStallAt = STALL === '0' ? Infinity : STALL_FROM;
  let nextProbeAt = EVERY;
  while (Date.now() - t0 < SEC * 1000) {
    const el = (Date.now() - t0) / 1000;
    if (el >= nextStallAt) {
      nextStallAt += STALL_EVERY;
      stallsFired.push(+el.toFixed(1));
      await Promise.all(stallTargets.map(stallOne));
      continue;
    }
    if (el >= nextProbeAt) {
      nextProbeAt += EVERY;
      console.log(`\n[t+${el.toFixed(0)}s]`);
      for (const e of [S, C]) {
        const { l, s } = await probe(e);
        seen.push({ engine: e.engine, l, s });
        const q = s?.pcm;
        if (q) {
          series[e === S ? 'safari' : 'peer'].push({ t: +el.toFixed(1), depth: q.depthMs, target: q.target,
            want: q.want, lost: q.lost, late: q.lateFrames, govOn: q.govOn, govTrim: q.govTrim,
            govFloor: q.govFloor, govPops: q.govPops, govTrimTicks: q.govTrimTicks });
        }
        console.log(`  ${e.engine.padEnd(9)} sees ${l?.src} ${l?.w}x${l?.h} luma mean=${l?.mean} sd=${l?.sd}` +
          ` ${l?.sd > 8 ? '(real picture)' : '<-- BLACK/FLAT'}`);
        console.log(fmt(s));
      }
      continue;
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  // Interpreter readout (only meaningful when queryA/queryB carry xlate=…).
  // __xlateStats is the client's debug surface, readable over safaridriver's
  // executeScript where no init-script tap can be installed.
  const XL_SRC = `
    const x = window.__xlateStats;
    if (!x) return null;
    return { open: x.open, ready: x.ready, capsPeer: x.capsPeer, capsMe: x.capsMe,
      partials: x.partials, binChunks: x.binChunks, binBytes: x.binBytes,
      flushes: x.flushes, voiceOnsets: (x.voiceOnsets ?? []).length,
      errs: (x.errs ?? []).slice(-4), lastCap: x.lastCap,
      capShown: document.querySelector('#xlateCaps')?.textContent?.slice(0, 120) ?? null };
  `;
  if (/xlate=/.test(QUERY_A + QUERY_B)) {
    console.log('\n── interpreter (window.__xlateStats) ──');
    for (const e of [S, C]) {
      const x = e.page
        ? await e.page.evaluate(new Function(XL_SRC)).catch(() => null)
        : await e.eval(XL_SRC).catch(() => null);
      if (!x) { console.log(`  ${e.engine.padEnd(9)} xlate not running`); continue; }
      console.log(`  ${e.engine.padEnd(9)} open ${x.open} ready ${x.ready}  capsPeer ${x.capsPeer} capsMe ${x.capsMe} partials ${x.partials}` +
        `\n            audio in ${x.binChunks} chunks ${(x.binBytes / 96000).toFixed(1)}s@48k  voiceOnsets ${x.voiceOnsets}  flushes ${x.flushes}` +
        `\n            lastCap "${x.lastCap}"  overlay "${x.capShown}"` +
        (x.errs?.length ? `\n            errs ${JSON.stringify(x.errs)}` : ''));
    }
  }
  if (JSON_OUT) {
    const { writeFileSync } = await import('node:fs');
    writeFileSync(JSON_OUT, JSON.stringify({ meta: { room, peer: C.engine, sec: SEC, queryA: QUERY_A, queryB: QUERY_B,
      stall: STALL, stallMs: STALL_MS, stallEvery: STALL_EVERY, stallFrom: STALL_FROM, at: new Date().toISOString() },
      stalls: stallsFired, series }, null, 1));
    console.log(`\n  json -> ${JSON_OUT}`);
  }
  const lastOf = (eng) => [...seen].reverse().find((x) => x.engine === eng);
  const fin = [lastOf('Safari'), lastOf('Chromium')].filter(Boolean);
  const ok = fin.length === 2 && fin.every((x) => x.l?.sd > 8 && x.l.w > 1);
  console.log(`\n  ${ok ? 'PASS' : 'FAIL'}  ${fin.map((x) => `${x.engine} sd=${x.l?.sd}`).join('  ')}`);
} catch (err) {
  console.log(`  ERROR ${String(err).slice(0, 400)}`);
  process.exitCode = 1;
} finally {
  await S.close();
  await ctx.close();
}
