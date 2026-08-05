/**
 * A CALL BETWEEN REAL, SHIPPING BROWSERS.
 *
 * ─── WHY ──────────────────────────────────────────────────────────────────────
 * Every measurement on this project has been made with Playwright's bundled
 * "Google Chrome for Testing" on BOTH ends. That is one build, one audio stack, one
 * set of codecs, and it has already shipped a capability-dependent default that gave
 * Safari a black screen. This drives a REAL Brave (the browser actually installed on
 * this machine) over CDP, optionally against Playwright's WebKit for a genuine
 * cross-engine pair.
 *
 * ─── WHAT IT MEASURES ─────────────────────────────────────────────────────────
 * Primarily D — the delay from the first PCM frame arriving to `await addModule()`
 * resolving, i.e. how long the audio graph takes to come up. That number decides
 * whether the ring-origin defect fixed today was a corner case or a routine one:
 * below ~1.008 s a pre-fix build survived, above it the call lost ALL its audio for
 * the rest of its life while every transport counter read perfect. D has only ever
 * been measured on Chrome for Testing, where it is about -0.19 s (the graph wins the
 * race). A slower engine has less margin, or none.
 *
 * Also reports the ring-health counters that were invisible until today —
 * `farFuture`, `ringReseeds`, `portDropped` — plus depth, concealment and whether any
 * depth sample went negative, which is the signature of the defect.
 *
 * ─── HONESTY ──────────────────────────────────────────────────────────────────
 *   - Brave is a real shipping browser, so its Shields/fingerprinting defences are
 *     in play. If they break the lane that is a REAL finding about real users, not a
 *     harness fault, and it is reported as such rather than worked around.
 *   - Playwright's WebKit is NOT Safari: no MediaStreamTrackProcessor, its own codecs
 *     and audio stack, and it rejects `?transport=` ICE URLs that shipping Safari
 *     accepts. Read a WebKit arm as "cross-engine under a harness I control".
 *   - Real Safari cannot be driven here at all: safaridriver requires "Allow remote
 *     automation" in Safari's Developer settings, which is a browser security setting
 *     this harness will not change on someone's machine.
 *   - Brave runs on a THROWAWAY profile in the scratchpad, never the user's own.
 *
 *   node testbed/realpair.mjs [--peer=webkit|chromium] [--secs=45] [--port=9333]
 *                             [--base=URL] [--query=tape=2] [--json=PATH]
 */
import { chromium, webkit } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';
import os from 'node:os';
import fs from 'node:fs';

const AUD = '/Users/earningsgpt/video calling/testbed/media/conv/A.wav';
// The FULL Chrome for Testing, not Playwright's headless shell. Measured: with the
// shell, lane 2 died at t+1.14s with `tape-fallback {why:"encoder-setup"}` on every
// run, because the shell ships no usable video encoder. That is a property of the
// test binary and it was silently being attributed to the product. rig.mjs has always
// named this path explicitly; this harness defaulted and paid for it.
const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const BRAVE = '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser';

const KNOWN = new Set(['peer', 'secs', 'port', 'peerport', 'base', 'query', 'json', 'probe', 'cold', 'cpu', 'queryA', 'queryB', 'cam', 'stall', 'stallms', 'stallevery', 'stallfrom']);
for (const a of process.argv.slice(2)) {
  const m = /^--([a-zA-Z]+)(=|$)/.exec(a);
  if (!m || !KNOWN.has(m[1])) {
    console.error(`unknown flag: ${a}\nknown: ${[...KNOWN].map((k) => '--' + k).join(' ')}`);
    process.exit(2);
  }
}
const arg = (k, d) => {
  const m = process.argv.find((a) => a.startsWith(`--${k}=`));
  return m ? m.slice(k.length + 3) : d;
};
const PEER = arg('peer', 'webkit');
if (!['webkit', 'chromium', 'brave'].includes(PEER)) { console.error(`--peer must be webkit|chromium|brave`); process.exit(2); }
const SECS = Number(arg('secs', 45));
const PORT = Number(arg('port', 9333));
// --peer=brave attaches to a SECOND real Brave, so BOTH ends of the call are shipping
// browsers with real codecs. That is the only configuration here in which a lane-2
// failure can be blamed on the product rather than on a test binary.
const PEER_PORT = Number(arg('peerport', 9334));
const BASE = arg('base', 'https://room.tokkah.com');
const QUERY = arg('query', 'tape=2');
// Per-side queries. `maxTargetFrames` (?pcmjbmax=) is a RECEIVER-side parameter, so the
// two arms of an A/B on it belong on the two ends of ONE call: the call is then its own
// control for network, host and fixture, and running the arms in separate calls would
// have to absorb a between-call spread that is larger than the effect.
const QUERY_A = arg('queryA', QUERY);
const QUERY_B = arg('queryB', QUERY);
const JSON_OUT = arg('json', null);
// --probe=0 installs NOTHING in the page. D becomes unmeasurable, and that is the
// point: it is the control that says whether the probe itself is costing the call
// anything. A harness that cannot be switched off cannot be exonerated.
const PROBE_ON = arg('probe', '1') !== '0';
// --cold=1 empties each browser's HTTP cache before navigating, i.e. a FIRST-TIME
// VISITOR. That is the realistic worst case for D: `addModule('pcm-worklet.js')` has
// to cross the network before the audio graph exists, while the peer connection races
// ahead. Every D ever measured on this project has been on a warm cache, which is the
// condition a returning user has and a new one does not. Only the throwaway scratchpad
// profiles are touched.
// 0 = neither, 1 = both, a|b = THAT SIDE ONLY. The per-side form is the one that
// measures anything: cold-vs-warm as separate calls has to absorb a between-call spread
// measured at 0.24%-4.38% concealment, which is larger than the effect being looked for.
// Clearing one side makes the single call its own control — same host, same fixture, same
// network, same 40 s — exactly as the release-rate n=8 did with a per-side parameter.
// ── Stall stimulus (task #47) ────────────────────────────────────────────────
// `--stall=both|a|b` blocks the chosen page's MAIN THREAD for --stallms every
// --stallevery seconds starting at --stallfrom. This is the faithful stimulus
// for the jitter/governor work (relpair.mjs precedent): nothing is dispatched,
// then the backlog arrives in a clump — the shape a tab switch or notification
// produces on a real machine. `both` fires the two sides in the same instant so
// a per-side A/B sees ONE stimulus, not two.
const STALL = arg('stall', '0');
if (!['0', 'both', 'a', 'b'].includes(STALL)) { console.error('--stall must be 0|both|a|b'); process.exit(2); }
const STALL_MS = Number(arg('stallms', 120));
const STALL_EVERY = Number(arg('stallevery', 10));
const STALL_FROM = Number(arg('stallfrom', 15));
const COLD = arg('cold', '0');
if (!['0', '1', 'a', 'b'].includes(COLD)) { console.error('--cold must be 0|1|a|b'); process.exit(2); }
const coldFor = (key) => COLD === '1' || (COLD === 'a' && key === 'brave') || (COLD === 'b' && key === 'peer');
// --cpu=N throttles BOTH ends to 1/N of this machine's speed via CDP, i.e. a budget
// phone instead of an M-series laptop. This is the honest realistic case for D: a cold
// cache turned out not to move it (measured -0.80 s vs -0.82 s warm, because the
// worklet module is tiny next to ~3 s of connection setup), so if anything erodes the
// margin before the ring cliff it is main-thread contention during startup, not the
// network. Nothing in this testbed has ever tested a slow device.
const CPU = Number(arg('cpu', '1'));
if (!Number.isFinite(CPU) || CPU < 1 || CPU > 20) { console.error('--cpu must be 1..20'); process.exit(2); }
if (!Number.isFinite(SECS) || SECS < 20) { console.error('--secs must be >= 20'); process.exit(2); }

// `--cam=` because the FIXTURE sets the frame-rate ceiling, not the code. Chrome ignores
// MJPEG container frame rate entirely (cam1080.mjpeg declares 25/1 and Chrome delivers 30,
// capability max 30) but honors a Y4M `F60:1` header. Testing 60 fps against a 30 fps
// fixture measures the fixture — the trap that once capped every frame-rate figure here.
const CAMS = {
  '1080p30': '/Users/earningsgpt/video calling/testbed/media/cam1080.mjpeg',
  '1080p60': '/Users/earningsgpt/video calling/testbed/media/motion1080_60.y4m',
  // 72 is the whole divisor of 144 Hz just below our ceiling, so this is the fixture that
  // lets a 144 Hz peer actually be served an even cadence instead of 60-on-144 at 2.40.
  '1080p72': '/Users/earningsgpt/video calling/testbed/media/motion1080_72.y4m',
};
const CAM = CAMS[arg('cam', '1080p30')] ?? (() => {
  console.error(`--cam must be one of: ${Object.keys(CAMS).join(', ')}`); process.exit(2);
})();

function need(o, k, where) {
  if (o == null) throw new Error(`${where}: object is ${o}, cannot read "${k}"`);
  if (o[k] === undefined) throw new Error(`${where}: field "${k}" does not exist. Available: ${Object.keys(o).slice(0, 50).join(', ')}`);
  return o[k];
}

// D is measured at the ONE place it is defined: when `await addModule()` resolves,
// which is what the audio-graph setup blocks on before the playout node exists.
// page.route() does NOT intercept an AudioWorklet module fetch, so this has to be a
// prototype patch and not a network interception.
const PROBE = `
  // THE CAPTURE HISTORY. A media-source reading of 1920x1080@10 says the camera ran
  // slow; it does not say who asked it to. Every applyConstraints the app makes is
  // recorded with the settings before and after, so a frame rate that was repaired and
  // then re-broken by a later re-solve cannot look the same as one never repaired.
  window.__ac = [];
  const origAC = MediaStreamTrack.prototype.applyConstraints;
  MediaStreamTrack.prototype.applyConstraints = function (c) {
    const b = this.getSettings();
    const rec = { kind: this.kind, at: +performance.now().toFixed(0),
      asked: JSON.parse(JSON.stringify(c === undefined ? null : c)),
      before: { w: b.width, h: b.height, fps: b.frameRate } };
    window.__ac.push(rec);
    return origAC.call(this, c).then((r) => {
      const a = this.getSettings();
      rec.after = { w: a.width, h: a.height, fps: a.frameRate };
      return r;
    }, (e) => { rec.err = String(e && e.name); throw e; });
  };
  window.__gum = [];
  const origGUM = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
  navigator.mediaDevices.getUserMedia = function (c) {
    const rec = { at: +performance.now().toFixed(0), asked: JSON.parse(JSON.stringify(c === undefined ? null : c)) };
    window.__gum.push(rec);
    return origGUM(c).then((st) => {
      const v = st.getVideoTracks()[0];
      const g = v && v.getSettings();
      rec.got = g ? { w: g.width, h: g.height, fps: g.frameRate } : 'no video track';
      return st;
    }, (e) => { rec.err = String(e && e.name); throw e; });
  };
  window.__gdMod = [];
  const orig = AudioWorklet.prototype.addModule;
  AudioWorklet.prototype.addModule = async function (url, ...rest) {
    const t0 = performance.now();
    const out = await orig.call(this, url, ...rest);
    window.__gdMod.push({ url: String(url), t0, t1: performance.now() });
    return out;
  };
  // First PCM frame arrival, so D is a difference of two in-page instants rather
  // than one in-page instant against a harness clock.
  // 100 Hz is fine for a few seconds and NOT fine for a whole call: each tick calls
  // pcm.snapshot() on the main thread, which is the thread the audio lane's sends run
  // on. The first version never cleared this, so the instrument competed with the
  // subject for 40 s. It stops the moment it has its one answer.
  window.__firstRecvAt = null;
  window.__gdTimer = setInterval(() => {
    const p = window.__tape && window.__tape.pcm;
    if (p && p.framesRecv > 0) {
      window.__firstRecvAt = performance.now();
      clearInterval(window.__gdTimer);
      window.__gdTimer = null;
    }
  }, 10);
`;

/**
 * THE VERDICT IS THE PICTURE. Every "clean call" claim above this line rested on audio
 * counters and lane status, which is precisely the mistake this project has already made:
 * `pc.connectionState` "connected" with `framesDecoded` climbing 148 -> 208, while the
 * remote element was 0x0 and frozen. So gate on pixels and on motion.
 *
 * `hash` is PER-PIXEL (FNV over the red channel), not a mean or an sd. A global mean is
 * nearly invariant to real motion — a talking head measured 128.9 -> 128.9 across 600 ms
 * and a "camera is FROZEN" check fired on a perfectly live fixture. Any single changed
 * pixel changes this hash.
 */
const luma = (p) => p.evaluate(() => {
  const grab = (el, w, h) => {
    const c = document.createElement('canvas'); c.width = 64; c.height = 36;
    const g = c.getContext('2d', { willReadFrequently: true });
    try { g.drawImage(el, 0, 0, 64, 36); } catch { return { err: 'drawImage threw (tainted or not ready)' }; }
    const d = g.getImageData(0, 0, 64, 36).data;
    let sum = 0, sum2 = 0, n = 0, fnv = 2166136261;
    for (let i = 0; i < d.length; i += 4) {
      const y = 0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2];
      sum += y; sum2 += y * y; n++;
      fnv ^= d[i]; fnv = (fnv * 16777619) >>> 0;
    }
    const m = sum / n;
    return { src: el.id, w, h, hash: fnv, mean: +m.toFixed(1),
      sd: +Math.sqrt(Math.max(0, sum2 / n - m * m)).toFixed(1) };
  };
  // The custom lane paints a canvas; the RTP fallback paints the <video>. Check whichever
  // is actually live, and say which one it was — "which surface" is itself a finding.
  const rc = document.getElementById('remoteCanvas');
  if (rc && rc.width > 1) return grab(rc, rc.width, rc.height);
  const v = document.getElementById('remote');
  if (v && v.videoWidth > 0) return { ...grab(v, v.videoWidth, v.videoHeight), currentTime: v.currentTime };
  return { src: rc ? 'remoteCanvas' : 'remote', w: v?.videoWidth ?? 0, h: v?.videoHeight ?? 0, mean: null, sd: null };
});

/**
 * The RTP video sender's actual parameters and what the encoder says is limiting it.
 * `qualityLimitationReason` is the decisive field: 'bandwidth' or 'cpu' means the encoder
 * chose to shrink, 'none' means nobody asked it to and the resolution is what was offered.
 *
 * This exists because app.js applies sender parameters once, inside `join()`, by iterating
 * `pc.getSenders()`. On the lane-2 path there is no camera video sender at that moment —
 * `fallbackToRtp` adds one later with `pc.addTrack`. So the question "does the fallback
 * sender ever get its parameters" has an answer in the page, and guessing it from the
 * source is what this replaces.
 */
const videoSend = (p) => p.evaluate(async () => {
  const pc = window.__tape?.pc;
  if (!pc) return { err: 'no pc' };
  const out = { senders: [], outbound: [], sources: [] };
  for (const s of pc.getSenders()) {
    if (s.track?.kind !== 'video') continue;
    const pr = s.getParameters();
    const e0 = pr.encodings?.[0] ?? {};
    out.senders.push({
      trackId: s.track.id.slice(0, 8), label: (s.track.label || '').slice(0, 30),
      enabled: s.track.enabled, muted: s.track.muted,
      degradationPreference: pr.degradationPreference ?? null,
      maxBitrate: e0.maxBitrate ?? null, maxFramerate: e0.maxFramerate ?? null,
      scaleResolutionDownBy: e0.scaleResolutionDownBy ?? null,
      settings: (() => { try { const st = s.track.getSettings(); return { w: st.width, h: st.height, fps: st.frameRate }; } catch { return null; } })(),
    });
  }
  const st = await pc.getStats();
  st.forEach((r) => {
    if (r.type === 'outbound-rtp' && r.kind === 'video') {
      out.outbound.push({ w: r.frameWidth ?? null, h: r.frameHeight ?? null, fps: r.framesPerSecond ?? null,
        sent: r.framesSent ?? null, bytes: r.bytesSent ?? null,
        limitedBy: r.qualityLimitationReason ?? null, encoder: r.encoderImplementation ?? null,
        // Where the encoder says the time went, cumulative seconds per reason.
        limitDur: r.qualityLimitationDurations ?? null,
        targetBitrate: r.targetBitrate ?? null, encodeMs: r.totalEncodeTime ?? null,
        keyFrames: r.keyFramesEncoded ?? null, framesEncoded: r.framesEncoded ?? null });
    }
    // media-source is UPSTREAM of the encoder: it is what the camera actually produced.
    // Without it, a camera running slow and an encoder choking are the same number, and
    // this project has already had every frame-rate figure in its history silently capped
    // by a fake camera that ran at 20 fps instead of 30.
    if (r.type === 'media-source' && r.kind === 'video') {
      // An ARRAY, not a field. On the healthy lane-2 path there are TWO video sources —
      // the camera and the carrier's flicker canvas — and keeping only the last one made
      // this print `320x180@60` under a heading that says CAMERA. A label that confidently
      // names the wrong source is worse than no label.
      out.sources.push({ id: r.trackIdentifier ?? null, w: r.width ?? null, h: r.height ?? null,
        fps: r.framesPerSecond ?? null, frames: r.frames ?? null });
    }
    if (r.type === 'inbound-rtp' && r.kind === 'video') {
      out.inbound = out.inbound ?? [];
      out.inbound.push({ w: r.frameWidth ?? null, h: r.frameHeight ?? null, fps: r.framesPerSecond ?? null,
        decoded: r.framesDecoded ?? null, decoder: r.decoderImplementation ?? null });
    }
  });
  return out;
});

const snap = (p) => p.evaluate(() => ({
  hasTape: !!window.__tape,
  pcm: window.__tape?.pcm ?? null,
  status: document.getElementById('status')?.textContent ?? null,
  mods: window.__gdMod ?? null,
  firstRecvAt: window.__firstRecvAt ?? null,
  ac: window.__ac ?? null,
  gum: window.__gum ?? null,
  // The video lane's own verdict on itself. `fellBack: true` means the custom lane
  // died and plain RTP is carrying the picture — a silent downgrade that no counter
  // in the PCM block can see, and the condition under which app.js:3337 throws at
  // 5 Hz forever because `tape.sendCtl?.()` guards the method and not the null object.
  tapeMode: window.__tape?.tapeMode ?? null,
  video: window.__tape?.video ?? null,
  // Was the peer-to-peer clock ever established? If time-sync's send throws, this
  // stays null and every A-V decision downstream runs against an unset clock.
  tsync: window.__tape?.timesync ?? null,
  // The app's own account of why a lane died, straight out of the telemetry mirror.
  // `tape-fallback` carries a `why`, and that string is the whole finding: without it
  // "fellBack true" is a symptom with no cause attached.
  fallbacks: (window.__tape?.tel?.mirror ?? [])
    // `fail` and `encoder` are in here because they were NOT, and that cost a whole
    // extra deploy-and-run cycle: `tape-fallback {why:'encoder-setup'}` names the stage
    // that failed while `tape-fail` carries the exception, and only the second one says
    // what actually went wrong.
    .filter((x) => /fallback|watchdog|lane|claim|fail|encoder|framesource|tape-fps|fps-repair/.test(x.kind))
    // DEDUPE BY KIND, keeping the FIRST of each with a count. A plain slice(-16) let
    // `lane0-yield` — which fires once a second all call — push the one-shot startup
    // failure out of the window entirely, so the list looked healthy while the lane was
    // dead. First occurrence is also the right one to keep: causes precede symptoms.
    .reduce((acc, x) => {
      const hit = acc.find((y) => y.kind === x.kind);
      if (hit) { hit.n++; return acc; }
      acc.push({ kind: x.kind, t: x.t, data: x.data, n: 1 });
      return acc;
    }, []),
}));

const room = 'rp' + Math.random().toString(36).slice(2, 7);
const report = {
  meta: { room, peer: PEER, secs: SECS, base: BASE, query: QUERY, queryA: QUERY_A, queryB: QUERY_B, probe: PROBE_ON, cold: COLD, cpuThrottle: CPU,
          stall: STALL, stallMs: STALL_MS, stallEvery: STALL_EVERY, stallFrom: STALL_FROM, at: new Date().toISOString(),
          host: `${os.cpus().length} cores, ${os.platform()} ${os.release()}` },
  sides: {}, series: { brave: [], peer: [] }, limits: [], console: { brave: [], peer: [] },
};

const T_START = Date.now();
console.log(`\n${'━'.repeat(80)}`);
console.log(`REAL BROWSER PAIR  room=${room}   Brave (real, over CDP)  x  Playwright ${PEER}   ${SECS}s   probe=${PROBE_ON ? 'on' : 'OFF (control)'}${COLD !== '0' ? `  COLD=${COLD}` : ''}${CPU > 1 ? `  CPU 1/${CPU}` : ''}`);
console.log('━'.repeat(80));

{
  const cores = os.cpus().length;
  const load = () => os.loadavg()[0] / cores;
  const t0 = Date.now();
  let l = load();
  if (l > 0.7) {
    console.log(`  host load ${(100 * l).toFixed(0)}% — waiting to settle`);
    while (l > 0.7 && (Date.now() - t0) / 1000 < 240) {
      await new Promise((r) => setTimeout(r, 5000));
      l = load();
    }
  }
  report.meta.hostLoadStart = +l.toFixed(3);
  if (l > 0.7) { console.error(`  ABORT: host still at ${(100 * l).toFixed(0)}% after waiting`); process.exit(3); }
  console.log(`  host load ${(100 * l).toFixed(0)}% of ${cores} cores`);
}

// ── attach to the REAL Brave already running with --remote-debugging-port ──
let braveBrowser;
try {
  braveBrowser = await chromium.connectOverCDP(`http://127.0.0.1:${PORT}`);
} catch (e) {
  console.error(`\n  Could not attach to Brave on port ${PORT}: ${e.message}`);
  console.error(`  Start it with --remote-debugging-port=${PORT} and a throwaway --user-data-dir first.`);
  process.exit(4);
}
const bv = braveBrowser.version();
console.log(`  attached to real Brave, CDP reports Chrome/${bv}`);
report.meta.braveVersion = bv;

const braveCtx = braveBrowser.contexts()[0] ?? (await braveBrowser.newContext());
await braveCtx.grantPermissions(['camera', 'microphone'], { origin: BASE }).catch(() => {});
if (PROBE_ON) await braveCtx.addInitScript(PROBE);
const bravePage = await braveCtx.newPage();
// The site serves `script-src 'self'` and Brave enforces it against the injected
// init script, so without this the probe silently does not exist. Disclosed rather
// than hidden: this relaxes CSP for the PROBE only, and the app's own code is
// served from 'self' either way — index.html carries a single `<script src>` and no
// inline script, so nothing the app does changes. The alternative is no D
// measurement at all, which is the entire point of the run.
{
  const cdp = await braveCtx.newCDPSession(bravePage);
  await cdp.send('Page.setBypassCSP', { enabled: true });
  report.meta.bypassCSP = 'probe only; page has no inline script of its own';
}

// Chromium needs command-line flags to get a fake camera; Playwright's WebKit ships
// its own mock capture device and takes permissions instead. Same split as rig.mjs.
let peerBrowser = null, peerCtx, peerNeedsCdpBypass = false;
if (PEER === 'brave') {
  try {
    peerBrowser = await chromium.connectOverCDP(`http://127.0.0.1:${PEER_PORT}`);
  } catch (e) {
    console.error(`\n  Could not attach to the second Brave on port ${PEER_PORT}: ${e.message}`);
    console.error(`  Launch it with --remote-debugging-port=${PEER_PORT} and its own throwaway --user-data-dir.`);
    process.exit(4);
  }
  report.meta.peerBraveVersion = peerBrowser.version();
  console.log(`  attached to second real Brave, CDP reports Chrome/${peerBrowser.version()}`);
  peerCtx = peerBrowser.contexts()[0] ?? (await peerBrowser.newContext());
  await peerCtx.grantPermissions(['camera', 'microphone'], { origin: BASE }).catch(() => {});
  peerNeedsCdpBypass = true; // a live browser's default context cannot be given bypassCSP
} else if (PEER === 'chromium') {
  if (!fs.existsSync(CHROME)) {
    console.error(`  Chrome for Testing not at ${CHROME} — check ~/Library/Caches/ms-playwright`);
    process.exit(5);
  }
  peerCtx = await chromium.launchPersistentContext('', {
    executablePath: CHROME, headless: true,
    args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
      `--use-file-for-fake-video-capture=${CAM}`, `--use-file-for-fake-audio-capture=${AUD}`,
      '--autoplay-policy=no-user-gesture-required'],
    viewport: { width: 1000, height: 700 },
    bypassCSP: true, // same reason as Brave, kept symmetric so the arms differ only by engine
  });
} else {
  peerBrowser = await webkit.launch({ headless: true });
  peerCtx = await peerBrowser.newContext({
    permissions: ['camera', 'microphone'], viewport: { width: 1000, height: 700 }, bypassCSP: true,
  });
}
if (PROBE_ON) await peerCtx.addInitScript(PROBE);
const peerPage = await peerCtx.newPage();
if (peerNeedsCdpBypass && PROBE_ON) {
  const cdp = await peerCtx.newCDPSession(peerPage);
  await cdp.send('Page.setBypassCSP', { enabled: true });
}

const A = { tag: 'brave', page: bravePage, key: 'brave', query: QUERY_A, pics: [] };
const B = { tag: PEER, page: peerPage, key: 'peer', query: QUERY_B, pics: [] };
if (QUERY_A !== QUERY_B) console.log(`  side A: ?${QUERY_A}\n  side B: ?${QUERY_B}`);
for (const e of [A, B]) {
  e.errs = new Map(); // message -> {n, firstAt, lastAt}
  const bump = (msg) => {
    const k = String(msg).slice(0, 160);
    const at = +((Date.now() - T_START) / 1000).toFixed(2);
    const r = e.errs.get(k) ?? { n: 0, firstAt: at, lastAt: at };
    r.n++; r.lastAt = at;
    e.errs.set(k, r);
  };
  e.page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') bump(`${m.type()}: ${m.text()}`); });
  // pageerror is an UNHANDLED exception, not a log line. No previous harness in this
  // testbed listened for it, which is how 5-per-second of them survived to production.
  e.page.on('pageerror', (err) => bump(`pageerror: ${err && err.message ? err.message : String(err)}`));
}

try {
  // Throttle BEFORE navigating, so the whole page lifecycle — parse, module fetch,
  // getUserMedia, addModule — runs at the slow speed. Throttling after load would
  // measure a fast startup followed by a slow call, which is not any real device.
  if (CPU > 1) {
    for (const e of [A, B]) {
      const cdp = await e.page.context().newCDPSession(e.page);
      await cdp.send('Emulation.setCPUThrottlingRate', { rate: CPU });
      e.cdpThrottle = cdp; // held open: detaching would drop the emulation override
    }
    console.log(`  both ends throttled to 1/${CPU} CPU speed`);
  }
  if (COLD !== '0') {
    for (const e of [A, B]) {
      if (!coldFor(e.key)) continue;
      const cdp = await e.page.context().newCDPSession(e.page);
      await cdp.send('Network.enable');
      await cdp.send('Network.clearBrowserCache');
      await cdp.detach().catch(() => {});
      e.cold = true;
    }
    const which = [A, B].filter((e) => e.cold).map((e) => e.key).join(' + ');
    console.log(`  HTTP cache cleared on: ${which}  (first-time visitor; the other side is a returning one)`);
  }
  for (const e of [A, B]) {
    await e.page.goto(`${BASE}/?r=${room}&${e.query}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await e.page.waitForSelector('#join', { timeout: 30000 });
    // WAIT FOR THE LOCAL CAMERA BEFORE JOINING. Clicking #join while getUserMedia is
    // still resolving is how the first version of this harness "found" that Brave
    // cannot connect: both sides joined without media and sat in the lobby. rig.mjs
    // has always done this; leaving it out manufactured an engine finding out of a
    // race in the test.
    try {
      await e.page.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
    } catch {
      throw new Error(`${e.tag}: local camera never produced a frame (#preview stayed 0 wide) after 30s. ` +
        `console: ${JSON.stringify(report.console[e.key].slice(0, 3))}`);
    }
    console.log(`  ${e.tag}: loaded, camera live`);
  }
  await A.page.click('#join');
  await A.page.waitForTimeout(700);
  await B.page.click('#join');
  for (const e of [A, B]) {
    try {
      await e.page.waitForFunction(() => document.querySelector('#status')?.textContent === 'connected', null, { timeout: 45000 });
    } catch {
      const d = await e.page.evaluate(() => ({
        status: document.querySelector('#status')?.textContent ?? '(no #status)',
        pc: window.__tape?.pc ? { conn: window.__tape.pc.connectionState, ice: window.__tape.pc.iceConnectionState,
          sig: window.__tape.pc.signalingState } : null,
        turns: window.__tape?.turns ?? null,
      }));
      throw new Error(`${e.tag}: never reached "connected" — status "${d.status}", pc ${JSON.stringify(d.pc)}. ` +
        `On a REAL browser this may be a finding rather than a harness fault. ` +
        `console: ${JSON.stringify(report.console[e.key].slice(0, 3))}`);
    }
  }
  // WHICH BUILD IS EACH PAGE ACTUALLY RUNNING? Three separate findings this session were
  // wasted on a page that had served app.js from its own HTTP cache — the edge was fresh,
  // `curl` and `cmp` both matched, and the browser still ran yesterday's code. A stale
  // asset is indistinguishable from a fix that did not work, so the harness has to say so
  // rather than leave it to be inferred from a surprising number.
  {
    const hash = (p) => p.evaluate(async () => {
      const t = await (await fetch('/app.js', { cache: 'no-store' })).text();
      const live = await (await fetch('/app.js')).text();
      const h = (x) => { let n = 5381; for (let i = 0; i < x.length; i++) n = ((n * 33) ^ x.charCodeAt(i)) >>> 0; return n.toString(16); };
      return { edge: h(t), page: h(live), bytes: live.length };
    });
    const [ha, hb] = await Promise.all([hash(A.page), hash(B.page)]);
    console.log(`  BUILD  brave app.js ${ha.page} (${ha.bytes} B)   ${PEER} ${hb.page} (${hb.bytes} B)`);
    for (const [tag, h] of [['brave', ha], [PEER, hb]]) {
      if (h.page !== h.edge) {
        console.log(`  !! ${tag} IS RUNNING A STALE app.js — cached ${h.page}, edge serves ${h.edge}.`);
        console.log(`     Every result below is from the OLD build. Re-run before believing any of it.`);
      }
    }
    if (ha.page !== hb.page) console.log(`  !! THE TWO SIDES ARE RUNNING DIFFERENT BUILDS — no comparison between them is valid.`);
  }
  console.log(`  both connected. sampling ${SECS}s\n`);
  console.log(`      t(s)  ┃ brave: depth  lost  tgt  ┃ ${PEER.padEnd(7)}: depth  lost  tgt`);

  const t0 = Date.now();
  let negBrave = 0, negPeer = 0, nBrave = 0, nPeer = 0;
  // Stall stimulus scheduling. Fired from the harness (not a page timer) so the
  // two sides' blocks are issued in the same instant, and recorded with their
  // actual wall time so the series can be aligned to them.
  let nextStallAt = STALL === '0' ? Infinity : STALL_FROM;
  report.stalls = [];
  const stallPages = STALL === 'both' ? [A.page, B.page] : STALL === 'a' ? [A.page] : STALL === 'b' ? [B.page] : [];
  const mainBlock = (p) => p.evaluate((ms) => { const t = performance.now(); while (performance.now() - t < ms); }, STALL_MS);
  while (Date.now() - t0 < SECS * 1000) {
    const el = (Date.now() - t0) / 1000;
    if (el >= nextStallAt) {
      nextStallAt += STALL_EVERY;
      report.stalls.push(+el.toFixed(2));
      await Promise.all(stallPages.map(mainBlock));
      continue;
    }
    const [sa, sb] = await Promise.all([snap(A.page), snap(B.page)]);
    if (report.series.brave.length % 4 === 0) {
      const [la, lb] = await Promise.all([luma(A.page), luma(B.page)]);
      A.pics.push({ t: +el.toFixed(2), ...la });
      B.pics.push({ t: +el.toFixed(2), ...lb });
    }
    for (const [e, s, cnt] of [[A, sa, 'a'], [B, sb, 'b']]) {
      if (!s.pcm) continue;
      const d = s.pcm.depthMs;
      report.series[e.key].push({ t: +el.toFixed(2), depth: d, lost: s.pcm.lostFrames ?? null,
        target: s.pcm.targetFrames ?? null, recv: s.pcm.framesRecv ?? null,
        // Latency governor (task #47). Arm identity is read out of the PAGE
        // (govOn), never inferred from which side carried which query.
        late: s.pcm.lateFrames ?? null, want: s.pcm.jitWant ?? null,
        govOn: s.pcm.govOn ?? null, govTrim: s.pcm.govTrim ?? null, govFloor: s.pcm.govFloor ?? null,
        govPops: s.pcm.govPops ?? null, govTrimTicks: s.pcm.govTrimTicks ?? null,
        farFuture: s.pcm.farFuture ?? null, reseeds: s.pcm.ringReseeds ?? null,
        // THE VIDEO DELIVERY COLUMN. Cumulative counters, sampled: the rate is computed
        // from a DIFF over the last third of the call, because the pacer ramps at the
        // start and a call average would credit the ramp against the steady state.
        vEnc: s.video?.framesEncoded ?? null, vOut: s.video?.framesOut ?? null,
        vIn: s.video?.framesIn ?? null, vSkip: s.video?.framesSkipped ?? null,
        vLost: s.video?.framesLost ?? null,
        vAchieved: s.video?.achievedFps ?? null, vAsked: s.video?.askedFps ?? null,
        vTicks: s.video?.carrierTicksAsked ?? null, vMbps: s.video?.mbpsAtFps ?? null,
        vQp: s.video?.rcQp ?? null,
        // WHY a frame was skipped. Three different causes with three different fixes, and
        // the aggregate `framesSkipped` cannot tell them apart.
        vSkipBuf: s.video?.skipBuffered ?? null, vSkipEnc: s.video?.skipEncQueue ?? null,
        vSkipDec: s.video?.skipDecodeStalled ?? null, vAdmit: s.video?.admitFps ?? null,
        // skipPaced and skipShed were MISSING here, and the omission printed
        // "skipped 10.7/s" over "buffered 0, encQueue 0, decodeStalled 0" — a cause column
        // that summed to zero against a non-zero total, which reads as a broken counter
        // rather than as an incomplete report. The pacer's token bucket was the answer.
        vSkipPace: s.video?.skipPaced ?? null, vSkipShed: s.video?.skipShed ?? null,
        vCarrDrop: s.video?.carrierDropped ?? null, vEncQPeak: s.video?.encQueuePeak ?? null });
      // NEGATIVE DEPTH IS THE DEFECT'S SIGNATURE. Counted, not just extremed.
      if (typeof d === 'number') {
        if (cnt === 'a') { nBrave++; if (d < 0) negBrave++; } else { nPeer++; if (d < 0) negPeer++; }
      }
    }
    const f = (s) => (s.pcm
      ? `${String(s.pcm.depthMs ?? '-').padStart(7)} ${String(s.pcm.lostFrames ?? '-').padStart(5)} ${String(s.pcm.targetFrames ?? '-').padStart(4)}`
      : '   (lane not up)   ');
    if (Math.abs(el - Math.round(el)) < 0.25 && Math.round(el) % 5 === 0) {
      console.log(`    ${el.toFixed(1).padStart(6)}  ┃ ${f(sa)}      ┃ ${f(sb)}`);
    }
    await A.page.waitForTimeout(500);
  }

  console.log(`\nAUDIO-GRAPH STARTUP — the margin against today's ring-origin defect\n`);
  // Verdicts are COLLECTED and thrown at the very end, never mid-loop. An earlier
  // version threw on side A's negative-depth check, which destroyed side B's entire
  // observation — half the call went unmeasured to report a fault on the other half.
  const verdicts = [];
  for (const [e, negs, tot] of [[A, negBrave, nBrave], [B, negPeer, nPeer]]) {
    const s = await snap(e.page);
    if (!s.hasTape) throw new Error(`${e.tag}: window.__tape absent`);
    if (!s.pcm) throw new Error(`${e.tag}: PCM lane never ran — nothing measured`);
    const mods = s.mods ?? [];
    const wl = mods.find((m) => m.url.includes('pcm-worklet'));
    const first = s.firstRecvAt;
    // D = addModule resolving MINUS first frame arriving. Both in-page instants.
    const D = wl && first !== null ? (wl.t1 - first) / 1000 : null;
    const recv = need(s.pcm, 'framesRecv', 'pcm'), lost = need(s.pcm, 'lostFrames', 'pcm');
    const depth = need(s.pcm, 'depthMs', 'pcm');
    // These three exist only because they were published today. On a peer still
    // serving the old bundle they would be undefined, and `need` would say so
    // rather than defaulting them to a reassuring zero.
    const farFuture = need(s.pcm, 'farFuture', 'pcm');
    const reseeds = need(s.pcm, 'ringReseeds', 'pcm');
    const portDropped = need(s.pcm, 'portDropped', 'pcm');
    report.sides[e.key] = {
      engine: e.tag, addModuleMs: wl ? +(wl.t1 - wl.t0).toFixed(1) : null,
      addModuleResolvedAtMs: wl ? +wl.t1.toFixed(1) : null, firstRecvAtMs: first === null ? null : +first.toFixed(1),
      graphDelayS: D === null ? null : +D.toFixed(3),
      depthMs: depth, lostFrames: lost, framesRecv: recv,
      concealPct: +((100 * lost) / Math.max(1, recv)).toFixed(3),
      targetFrames: s.pcm.targetFrames ?? null, farFuture, ringReseeds: reseeds, portDropped,
      negativeDepthSamples: negs, depthSamples: tot,
      tapeMode: s.tapeMode, tsync: s.tsync, fallbacks: s.fallbacks,
      query: e.query, cold: !!e.cold,
      // LATENESS vs LOSS. With no network impairment nothing can be lost, so any
      // concealment here must be arrival timing, and these separate the two.
      lateFrames: s.pcm.lateFrames ?? null, playedFrames: s.pcm.playedFrames ?? null,
      heldMs: s.pcm.heldMs ?? null, extrapolatedMs: s.pcm.extrapolatedMs ?? null,
      overflowSkips: s.pcm.overflowSkips ?? null,
      // Is the 15-frame ceiling ACTUALLY binding? `jitClampedTicks` counts the ticks
      // where the estimator wanted more than it was allowed. Reading a cap's effect off
      // the target alone has gone wrong here twice, in opposite directions.
      jitClampedTicks: s.pcm.jitClampedTicks ?? null, jitWantMaxRun: s.pcm.jitWantMaxRun ?? null,
      jitWant: s.pcm.jitWant ?? null, jitSpreadMs: s.pcm.jitSpreadMs ?? null,
      jitMaxTarget: s.pcm.jitMaxTarget ?? null,
      // Arrival burstiness. If a slow device makes frames arrive in clumps rather than
      // at 125/s, the gap distribution is where it shows and the buffer depth is what
      // has to cover it. These are SPREAD into the snapshot by pcm.js, not nested under
      // a `gap` key — reading `pcm.gap` returned undefined and printed nothing at all,
      // which is why the first slow-device runs had no burstiness data.
      gapP50: need(s.pcm, 'gapP50', 'pcm'), gapP95: need(s.pcm, 'gapP95', 'pcm'),
      gapP99: need(s.pcm, 'gapP99', 'pcm'), gapClumpPct: need(s.pcm, 'gapClumpPct', 'pcm'),
      gapMaxRun: need(s.pcm, 'gapMaxRun', 'pcm'),
      modules: mods.map((m) => ({ url: m.url.split('/').pop(), tookMs: +(m.t1 - m.t0).toFixed(1) })),
    };
    const r = report.sides[e.key];
    console.log(`  ${e.tag.padEnd(9)} addModule('pcm-worklet.js') took ${r.addModuleMs ?? '?'} ms, resolved at t+${((r.addModuleResolvedAtMs ?? 0) / 1000).toFixed(3)}s`);
    console.log(`            first PCM frame at t+${((r.firstRecvAtMs ?? 0) / 1000).toFixed(3)}s  ->  D = ${D === null ? 'unmeasurable' : `${D.toFixed(3)}s`}` +
      `${D === null ? '' : `   ${D < 0 ? `graph wins the race by ${(-1000 * D).toFixed(0)} ms` : `graph LOSES by ${(1000 * D).toFixed(0)} ms`}`}`);
    console.log(`            depth ${depth} ms   conceal ${r.concealPct}% (${lost}/${recv})   target ${r.targetFrames}f`);
    console.log(`            farFuture ${farFuture}   ringReseeds ${reseeds}   portDropped ${portDropped}` +
      `   negative-depth samples ${negs}/${tot}`);
    if (D !== null && D > 1.008) {
      console.log(`            *** D EXCEEDS THE 1.008 s CLIFF. On the pre-fix build this call would have`);
      console.log(`                lost ALL of its audio for the rest of its life. ringReseeds ${reseeds} is the fix acting. ***`);
    }
    // ── the video lane's own verdict on itself, and the peer clock ──
    const tm = s.tapeMode;
    console.log(`            video lane: ${tm ? `wanted ${tm.wanted}, running ${tm.running}, fellBack ${tm.fellBack}` : '(no tapeMode)'}` +
      `${tm && tm.fellBack ? '   <<< FELL BACK TO PLAIN RTP' : ''}`);
    for (const fb of s.fallbacks ?? []) {
      console.log(`            tel t+${(fb.t / 1000).toFixed(2)}s  ${fb.kind}  ${JSON.stringify(fb.data)}`.slice(0, 150));
    }
    console.log(`            late ${s.pcm.lateFrames}  held ${s.pcm.heldMs}ms  extrap ${s.pcm.extrapolatedMs}ms  overflowSkips ${s.pcm.overflowSkips}`);
    console.log(`            jitter: want ${s.pcm.jitWant} (max run ${s.pcm.jitWantMaxRun}) vs cap ${s.pcm.jitMaxTarget}f  ` +
      `clampedTicks ${s.pcm.jitClampedTicks}  spread ${s.pcm.jitSpreadMs}ms` +
      `${s.pcm.jitClampedTicks > 0 ? '   <<< THE CEILING IS BINDING' : ''}`);
    console.log(`            cache at load: ${e.cold ? 'COLD (first-time visitor)' : 'warm (returning visitor)'}`);
    console.log(`            arrival gaps: p50 ${s.pcm.gapP50} p95 ${s.pcm.gapP95} p99 ${s.pcm.gapP99} ms  ` +
      `clumped ${s.pcm.gapClumpPct}%  longest run ${s.pcm.gapMaxRun}`);
    const ts = s.tsync;
    console.log(`            peer clock: ${ts ? `pings ${ts.pings} pongs ${ts.pongs} offset ${ts.offsetMs} ms rttMin ${ts.rttMinMs} ms` : '(time-sync never constructed)'}` +
      `${ts && ts.pings > 0 && ts.pongs === 0 ? '   <<< SENDING BUT NEVER ANSWERED' : ''}`);

    // ── NEGATIVE DEPTH, CLASSIFIED BY MAGNITUDE. Two different faults share this sign. ──
    // The ring-origin defect drives depth to about -22900 ms and NEVER recovers, with
    // ringReseeds/farFuture nonzero and `played` stuck at 0. A brief starvation drives it
    // a couple of frames negative and recovers within a second. An earlier version of
    // this gate called any negative sample "exactly the defect the ring re-seed was meant
    // to remove", which was wrong by three orders of magnitude and would have reported a
    // shipped fix as broken.
    if (negs > 0) {
      const worst = report.series[e.key].reduce((m, x) => (typeof x.depth === 'number' && x.depth < m ? x.depth : m), 0);
      const ring = reseeds > 0 || farFuture > 0 || worst < -1000;
      const label = ring ? 'RING-ORIGIN' : 'transient starvation';
      console.log(`            ${negs}/${tot} depth samples negative, worst ${worst} ms — ${label}`);
      if (ring) {
        verdicts.push(`${e.tag}: worst depth ${worst} ms with ringReseeds ${reseeds} / farFuture ${farFuture} — ` +
          `this is the RING-ORIGIN signature and the shipped fix did not hold on this engine.`);
      } else {
        console.log(`            i.e. the playhead briefly outran the lane by ${(-worst / 8).toFixed(1)} frames and recovered.`);
        console.log(`            NOT the ring defect (that one reads about -22900 ms and never recovers); this is`);
        console.log(`            an underrun, and the concealment counter above is the audible cost of it.`);
      }
    }
  }

  console.log(`\nERRORS — grouped, with the rate and the window they fired in`);
  for (const e of [A, B]) {
    const rows = [...e.errs.entries()].sort((x, y) => y[1].n - x[1].n);
    report.console[e.key] = rows.map(([msg, r]) => ({ msg, ...r }));
    if (!rows.length) { console.log(`  ${e.tag.padEnd(9)} none`); continue; }
    for (const [msg, r] of rows.slice(0, 5)) {
      const span = Math.max(0.01, r.lastAt - r.firstAt);
      console.log(`  ${e.tag.padEnd(9)} x${String(r.n).padStart(4)}  ${(r.n / span).toFixed(1)}/s  t+${r.firstAt}s..${r.lastAt}s  ${msg.slice(0, 90)}`);
    }
  }
  // ── THE RTP VIDEO SENDER, when the custom lane is not carrying ──────────────────
  console.log(`\nLANE 2 DELIVERY — what the custom lane actually put on the wire`);
console.log(`  ONE CARRIER TICK CARRIES ONE TAPE FRAME, so the carrier's tick rate is a hard`);
console.log(`  ceiling on the picture. Rates below are diffed over the LAST THIRD of the call.`);
for (const e of [A, B]) {
  const ser = report.series[e.key].filter((x) => x.vEnc != null);
  if (ser.length < 6) { console.log(`  ${e.tag.padEnd(9)} no lane-2 counters — lane not running`); continue; }
  const cut = ser[Math.floor(ser.length * 2 / 3)];
  const end = ser[ser.length - 1];
  const secs = end.t - cut.t;
  const rate = (k) => (secs > 0 && end[k] != null && cut[k] != null ? +((end[k] - cut[k]) / secs).toFixed(1) : null);
  const encFps = rate('vEnc');
  const asked = end.vAsked;
  const ticks = end.vTicks;
  console.log(`  ${e.tag.padEnd(9)} asked ${String(asked ?? '-').padStart(3)} fps   carrier ticks asked ${String(ticks ?? '-').padStart(3)}/s   ` +
    `ENCODED ${String(encFps ?? '-').padStart(5)} fps   in-lane achieved ${String(end.vAchieved ?? '-').padStart(5)} fps`);
  console.log(`            captured ${String(rate('vIn') ?? '-').padStart(5)}/s   skipped-at-capture ${String(rate('vSkip') ?? '-').padStart(5)}/s   ` +
    `painted ${String(rate('vOut') ?? '-').padStart(5)}/s   lost ${String(rate('vLost') ?? '-').padStart(5)}/s`);
  // The verdict has to name the binding constraint, not just print a number: an encoded
  // rate short of the ask is either a starved camera, a pacer skipping, or the tick
  // ceiling, and those have three different fixes.
  if (encFps != null && asked) {
    const pct = Math.round((100 * encFps) / asked);
    const cap = rate('vIn');
    // ORDER MATTERS. Asking about the camera first reported "CAMERA-BOUND (only 61.2/s
    // captured)" on a camera that delivered 71.7/s in the other arm of the same A/B —
    // capture is DOWNSTREAM-THROTTLED here, so a low capture rate is as often an effect as
    // a cause. A non-zero skip rate proves frames were available to skip, which is the
    // stronger evidence, so it is consulted first.
    const why = pct >= 90 ? 'meeting the ask'
      // 5% of the ask, not an absolute: 1.5 skips/s against a 72 fps ask is 2% and was
      // being reported as PACER-BOUND while the pacer sat at its ceiling of 76.
      : rate('vSkip') > asked * 0.05 ? `PACER-BOUND (${rate('vSkip')}/s skipped at capture)`
      : ticks != null && encFps > ticks * 0.7 ? `TICK-BOUND (near the ${ticks}/s carrier ceiling)`
      : cap != null && cap < asked * 0.9 ? `CAPTURE-BOUND (only ${cap}/s reached the pump)`
      : 'short of the ask, cause not identified by these counters';
    console.log(`            -> ${pct}% of the ask: ${why}`);
  }
  if (rate('vSkip') > 0.5) {
    const causes = [['paced', 'vSkipPace'], ['buffered', 'vSkipBuf'], ['encQueue', 'vSkipEnc'],
                    ['decodeStalled', 'vSkipDec'], ['shed', 'vSkipShed']];
    console.log(`            skip cause: ${causes.map(([n, k]) => `${n} ${rate(k) ?? '-'}/s`).join('   ')}`);
    console.log(`                        (pacer admitRate ${end.vAdmit ?? '-'} fps, encQ peak ${end.vEncQPeak ?? '-'})`);
    // THE CAUSES MUST ADD UP. An incomplete breakdown is worse than none: it reads as a
    // broken counter and sends the next hour after the wrong defect.
    const sum = causes.reduce((a, [, k]) => a + (rate(k) ?? 0), 0);
    const tot = rate('vSkip') ?? 0;
    if (Math.abs(sum - tot) > Math.max(0.5, tot * 0.1)) {
      console.log(`            !! ${(tot - sum).toFixed(1)}/s of skips are UNATTRIBUTED ` +
        `(total ${tot}, causes sum to ${sum.toFixed(1)}) — a skip path with no counter on it`);
    }
  }
  if (end.vMbps != null) console.log(`            wire cost at the achieved rate: ${end.vMbps} Mbps   rcQp ${end.vQp ?? '-'}`);
}

console.log(`\nRTP VIDEO PATH — parameters actually in force, and what limits them`);
  for (const e of [A, B]) {
    const vs = await videoSend(e.page);
    report.sides[e.key].videoSend = vs;
    if (vs.err) { console.log(`  ${e.tag.padEnd(9)} ${vs.err}`); continue; }
    if (!vs.senders.length) { console.log(`  ${e.tag.padEnd(9)} no video sender on the pc (custom lane is carrying)`); }
    for (const sd of vs.senders) {
      console.log(`  ${e.tag.padEnd(9)} sender ${sd.settings ? `${sd.settings.w}x${sd.settings.h}@${sd.settings.fps}` : '?'}  ` +
        `degradation ${sd.degradationPreference}  maxBitrate ${sd.maxBitrate}  maxFps ${sd.maxFramerate}  scaleDown ${sd.scaleResolutionDownBy}`);
      if (sd.maxBitrate === null && sd.maxFramerate === null) {
        console.log(`  ${' '.repeat(9)} ^ NO PARAMETERS SET on this sender. app.js applies them once inside join(),`);
        console.log(`  ${' '.repeat(9)}   iterating pc.getSenders(); a sender added later by fallbackToRtp is never visited.`);
      }
    }
    const hz = await e.page.evaluate(() => window.__tape?.hz ?? null);
    report.sides[e.key].hz = hz;
    if (hz) {
      const L = hz.local, T = hz.target;
      // "never received" and "received but rejected" are different failures and used to
      // print identically here, which sent me looking at the signaling relay for a bug
      // that was actually in the trust gate.
      const peerStr = hz.peerHz != null ? `${hz.peerHz} Hz`
        : hz.peerHzRaw != null ? `${hz.peerHzRaw} Hz BUT REJECTED as untrustworthy`
        : 'never received';
      console.log(`  ${e.tag.padEnd(9)} DISPLAY  ours ${L ? `${L.hz} Hz (median ${L.medianMs} ms, locked ${L.lockedPct}%, iqr ${L.iqrMs} ms)` : 'not measured'}`);
      console.log(`  ${' '.repeat(9)}          peer's ${peerStr}`);
      console.log(`  ${' '.repeat(9)}          send target ${T?.fps} fps, bound by "${T?.why}"` +
        `  (ceiling ${T?.ceiling ?? '-'}, peerHz ${T?.peerHz ?? '-'}, camera ${T?.camFps ?? '-'})`);
    }
    // Read straight off the page: snap() ran earlier for the audio block, and the
    // capture history belongs next to the sender parameters it explains.
    const hist = await e.page.evaluate(() => ({ ac: window.__ac ?? [], gum: window.__gum ?? [] }));
    report.sides[e.key].capture = hist;
    const cap = hist.ac;
    if (hist.gum.length) {
      for (const g of hist.gum) {
        console.log(`  ${e.tag.padEnd(9)} gUM  t+${String(g.at).padStart(5)}ms  ask ${JSON.stringify((g.asked && g.asked.video) ?? g.asked)}`);
        console.log(`  ${' '.repeat(9)}      got ${JSON.stringify(g.got ?? g.err)}`);
      }
    }
    for (const a of cap.filter((x) => x.kind === 'video')) {
      const b = a.before, af = a.after;
      console.log(`  ${e.tag.padEnd(9)} apply t+${String(a.at).padStart(5)}ms  ${JSON.stringify(a.asked)}`);
      console.log(`  ${' '.repeat(9)}      ${b.w}x${b.h}@${b.fps} -> ${a.err ? 'ERR ' + a.err : af ? `${af.w}x${af.h}@${af.fps}` : 'pending'}`);
    }
    for (const src of vs.sources ?? []) {
      // Named CAPTURE, not CAMERA: on the healthy lane-2 path one of these is the
      // carrier's 320x180 flicker canvas, and only the resolution tells them apart.
      console.log(`  ${e.tag.padEnd(9)} CAPTURE  ${src.w}x${src.h}@${src.fps}  ${src.frames} frames produced` +
        `   <-- upstream of the encoder`);
    }
    for (const o of vs.outbound) {
      console.log(`  ${e.tag.padEnd(9)} outbound ${o.w}x${o.h}@${o.fps}  ${o.sent} sent / ${o.framesEncoded} encoded  ` +
        `limitedBy "${o.limitedBy}"  enc ${o.encoder}`);
      if (o.limitDur) {
        const parts = Object.entries(o.limitDur).filter(([, v]) => v > 0.05).map(([k, v]) => `${k} ${(+v).toFixed(1)}s`);
        console.log(`  ${' '.repeat(9)} limitation time: ${parts.length ? parts.join(', ') : '(none over 0.05s)'}` +
          `   target ${o.targetBitrate ? (o.targetBitrate / 1e6).toFixed(2) + ' Mbps' : '?'}` +
          `   encode ${o.encodeMs != null && o.framesEncoded ? (1000 * o.encodeMs / o.framesEncoded).toFixed(2) + ' ms/frame' : '?'}`);
      }
    }
    for (const o of vs.inbound ?? []) {
      console.log(`  ${e.tag.padEnd(9)} inbound  ${o.w}x${o.h}@${o.fps}  ${o.decoded} decoded  dec ${o.decoder}`);
    }
  }

  // ── PICTURE VERDICT ───────────────────────────────────────────────────────────
  console.log(`\nTHE PICTURE — not the counters`);
  for (const e of [A, B]) {
    const pics = e.pics.filter((x) => !x.err);
    const withPix = pics.filter((x) => x.w > 1 && x.h > 1);
    const uniq = new Set(withPix.map((x) => x.hash)).size;
    const sds = withPix.map((x) => x.sd);
    const surf = [...new Set(pics.map((x) => x.src))].join('/');
    report.sides[e.key].picture = {
      surface: surf, samples: pics.length, withPixels: withPix.length,
      distinctFrames: uniq, w: withPix.at(-1)?.w ?? null, h: withPix.at(-1)?.h ?? null,
      sdMin: sds.length ? Math.min(...sds) : null, sdMax: sds.length ? Math.max(...sds) : null,
      errs: pics.length - withPix.length,
      // The SERIES, not just the extremes. The first version stored only sdMin/sdMax and
      // reported `sd 0.1..67`, which cannot distinguish "black for one frame at startup"
      // from "went black in the middle of the call" — and those are a non-event and a
      // visible glitch respectively.
      series: e.pics.map((x) => ({ t: x.t, w: x.w, h: x.h, sd: x.sd ?? null, err: x.err ?? undefined })),
    };
    // Flat frames after the opening are the ones a person would see. 3 s is the startup
    // allowance, and it is stated rather than folded into a single min.
    const lateFlat = withPix.filter((x) => x.t > 3 && x.sd <= 8);
    if (lateFlat.length) {
      console.log(`  ${' '.repeat(9)} ${lateFlat.length} flat frame(s) AFTER t+3s: ` +
        lateFlat.slice(0, 6).map((x) => `t+${x.t}s sd ${x.sd}`).join(', '));
    }
    const pi = report.sides[e.key].picture;
    console.log(`  ${e.tag.padEnd(9)} surface ${surf}  ${pi.w}x${pi.h}  ` +
      `${pi.distinctFrames} distinct frames in ${pi.withPixels} samples  sd ${pi.sdMin}..${pi.sdMax}`);
    // Three independent ways for this to be a lie, so three checks.
    if (lateFlat.length) {
      verdicts.push(`${e.tag}: ${lateFlat.length} of ${withPix.length} picture samples were FLAT (luma sd <= 8) ` +
        `after t+3s, at ${lateFlat.slice(0, 4).map((x) => 't+' + x.t + 's').join(', ')} — the remote picture ` +
        `went blank mid-call, which the aggregate sd range hid.`);
    }
    if (!withPix.length) {
      verdicts.push(`${e.tag}: the remote surface never had non-zero dimensions in ${pics.length} samples — ` +
        `there was no picture at all, whatever the audio counters said.`);
    } else if (pi.sdMax !== null && pi.sdMax <= 8) {
      verdicts.push(`${e.tag}: remote surface is ${pi.w}x${pi.h} but luma sd peaked at ${pi.sdMax} (<= 8) — ` +
        `a flat or black rectangle, not a picture.`);
    } else if (uniq <= 1) {
      verdicts.push(`${e.tag}: ${pi.withPixels} picture samples over the call produced only ${uniq} distinct ` +
        `per-pixel hash — the remote picture is FROZEN. A frozen element keeps its dimensions, so the ` +
        `size check above cannot catch this.`);
    }
  }

  report.verdicts = verdicts;
  if (verdicts.length) throw new Error(`\n  ${verdicts.join('\n  ')}`);
} finally {
  report.meta.hostLoadEnd = +(os.loadavg()[0] / os.cpus().length).toFixed(3);
  if (JSON_OUT) { fs.writeFileSync(JSON_OUT, JSON.stringify(report, null, 2)); console.log(`\n  json -> ${JSON_OUT}`); }
  // Close only what THIS process created. Brave was already running and is left
  // alone; closing the browser out from under the user would be rude and would also
  // destroy the CDP endpoint the next run wants.
  try { await bravePage.close(); } catch {}
  try { await braveBrowser.close(); } catch {}
  // For --peer=brave the browser was already running and must survive, exactly as the
  // first Brave does; only the page this run opened is closed.
  if (PEER === 'brave') { try { await peerPage.close(); } catch {} }
  else { try { await peerCtx.close(); } catch {} }
  try { if (peerBrowser) await peerBrowser.close(); } catch {}
}
