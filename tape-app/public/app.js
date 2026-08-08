/**
 * TAPE — the call.
 *
 * Ordinary WebRTC transport, deliberately. The custom pipeline (fixed-QP WebCodecs
 * over a datagram lane model) is gated behind `phase1-transport`, which has not been
 * run on two real machines yet. So this ships the parts that do not depend on it:
 *
 *   · raw audio — §5's four flags, which restore the pre-turn inhale (§3.1 lever 1)
 *   · 128 kbps Opus instead of Chrome's ~28 kbps default, measured at zero extra
 *     packet-loss exposure because Opus's packet rate is set by frame duration and
 *     not by bitrate (§17.3)
 *   · 1080p30 H.264 through the hardware encoder — 26 VMAF points over the 720p VP8
 *     that shipped before, while sending fewer bits (§17.2)
 *   · minimal playout delay — `playoutDelayHint = 0` and `jitterBufferTarget = 0`,
 *     the second measured to cost nothing in concealment under 1% loss (§17.4)
 *   · life-size rendering and gaze-aligned layout (§1.1a, §1.1b)
 *   · no self view (§1.1)
 *   · locked white balance / focus; exposure stays AE (root fix 2026-08-04)
 *   · dual onset detectors driving passive turn-taking measurement (turntaking.js)
 *
 * What that means honestly: **latency here is Zoom-class, but turn-taking should not
 * be.** §3.1 argues the two are separable — that most of what makes a call feel laggy
 * is destroyed cues rather than transport — and this app is the experiment that says
 * whether that's true. If the human gap comes out near Boland's 297 ms face-to-face
 * control on an ordinary WebRTC call, the design's central claim is supported before
 * a single custom byte is on the wire.
 *
 * Robustness rule throughout: this runs during a real conversation that happens once.
 * Nothing instrumental is allowed to break the call. Telemetry, layout, and metrics
 * are all wrapped; a failure in any of them degrades to a plain video call.
 */

import { attachDetector, audioConstraints, audioContext } from './onset-monitor.js';
import { Telemetry, sampleStats } from './telemetry.js';
import { TurnTaking, median } from './turntaking.js';
import { startTapeVideo, startTapeRtp, prepareTapeRtp, tapeSupported, tapeRtpSupported } from './tape.js';
import { initPcmAudio } from './pcm.js';
import { initTimeSync } from './timesync.js';

const $ = (id) => document.getElementById(id);
const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);
// Fullscreen is the only view (2026-08-04, user directive: the life-size /
// eye-line experiment and the self-view PiP are removed). layout() applies
// fill + contain and nothing else.
// Stats HUD (task #28, user directive 2026-08-02: "do not show me stats in the
// UI"): a debug affordance gated behind ?stats=1 — chip hidden and HUD off
// unless the flag is passed. Default call UI is a face and nothing else (the
// stall machine's honest state badges and the speaking dots are status, not
// stats, and stay). Telemetry logging is untouched — measurement never
// depended on the HUD being visible.
const STATS_UI = new URLSearchParams(location.search).get('stats') === '1';
const view = { hud: STATS_UI };

let pc = null;
let ws = null;
let localStream = null;
let previewStream = null;
let videoDegraded = null; // null | 'busy' | 'none' — set by getMedia when video couldn't open
let wsPreOpenFail = null; // rejects the join promise when the upgrade dies before open (§7)
// What the PEER's display can present, in Hz, once they have told us. Null until then.
// This is the number that decides how many frames per second are worth encoding: frames
// beyond the receiver's refresh rate cannot be seen by anyone and cost real bandwidth.
let peerHz = null;
let localHz = null; // our own, measured from rAF spacing; sent to the peer
// What the peer REPORTED, kept even when it was not trusted enough to act on — so a
// harness can tell "they never told us" apart from "they told us and we rejected it".
let peerHzRaw = null;
let role = null;
let tel = null;
let turns = null;
let localMon = null;
let remoteMon = null;
// Claimed synchronously in `ontrack` so the audio and video firings cannot both start
// attaching a detector. See the comment there.
let remoteAttaching = false;
let joined = false;
let statsTimer = null;
let lastStats = {};
// Send-bitrate differencing state. bytesSent is cumulative, so only the delta means anything.
let lastSend = { bytes: null, t: 0 };
let sendMbps = null;
// Packet-loss concealment invents audio, and invented audio is broadband and aperiodic —
// which is the detector's own signature for a breath. Measured under 1% loss and 30 ms
// jitter at 160 ms RTT: the received-side head start inflated from a 186 ms median to
// 436 ms, with a worst case of 4506 ms, while the own-mic side was untouched. Fifty-seven
// short concealment events did that; two long ones on the clean run at the same distance
// did not, so it is the *number* of concealment onsets that matters, not the total.
//
// The direction is what makes this dangerous rather than merely noisy: it *over*-reports
// the head start, so the instrument becomes optimistic exactly when the network is bad.
// Every remote-side event is therefore stamped with when concealment last happened, so
// analysis can exclude them instead of averaging in a flattering fiction.
//
// The stamp needs its own fast timer. Reading it off the 2-second stats interval was tried
// first and is useless: under 1% loss concealment happens roughly once a second, so 8 of 10
// events came back flagged — including the ones whose head start was perfectly plausible.
// A flag that is almost always true is not evidence. At 250 ms the question becomes
// answerable, because a concealment burst either did or did not overlap the onset.
//
// Cheap enough to run at 4 Hz because it asks the audio *receiver* for its stats rather
// than the whole peer connection: one inbound-rtp report instead of every transport,
// candidate pair and codec on the call.
const CONCEAL_POLL_MS = 250;
// A concealment burst within a quarter second either side of an onset is close enough to be
// the thing the detector heard. Wider than the poll so a burst that lands just before the
// window closes still counts.
const CONCEAL_NEAR_MS = 400;
let concealSeen = 0; // cumulative concealmentEvents, for differencing
let concealBurstAt = 0; // performance.now() of the newest window that had any
let concealBurstN = 0; // how many that window had
let concealProbe = null;
let concealReceiver = null;

/**
 * Watch the audio receiver's concealment counter at 4 Hz.
 *
 * Deliberately silent about failure: this is a metric, and the governing rule is that a
 * metric may never disturb the call. If the counter is missing — a browser that doesn't
 * implement it — `concealBurstAt` simply stays 0 and events go out unstamped, which reads
 * downstream as "unknown", not as "clean".
 */
function startConcealProbe() {
  if (concealProbe) return;
  concealReceiver = pc.getReceivers().find((r) => r.track?.kind === 'audio') ?? null;
  if (!concealReceiver) return;
  concealProbe = setInterval(async () => {
    let n = null;
    try {
      (await concealReceiver.getStats()).forEach((s) => {
        if (s.type === 'inbound-rtp' && s.concealmentEvents != null) n = s.concealmentEvents;
      });
    } catch {
      return; // receiver torn down mid-poll
    }
    if (n == null) return;
    const d = n - concealSeen;
    concealSeen = n;
    if (d > 0) {
      concealBurstAt = performance.now();
      concealBurstN = d;
    }
  }, CONCEAL_POLL_MS);
}

/** Age in ms of the most recent concealment burst, or null if there has never been one. */
function concealAge() {
  return concealBurstAt ? Math.round(performance.now() - concealBurstAt) : null;
}

// ── Guarded helpers ──────────────────────────────────────────────────────────
// `safe` exists because of the governing rule: an exception in a metric, a layout
// pass, or a log write must never propagate into the media path.
function safe(fn, label) {
  try {
    return fn();
  } catch (e) {
    tel?.log('error', { where: label, name: e?.name ?? '?', msg: String(e?.message ?? e).slice(0, 160) });
    return undefined;
  }
}
async function safeAsync(fn, label) {
  try {
    return await fn();
  } catch (e) {
    tel?.log('error', { where: label, name: e?.name ?? '?', msg: String(e?.message ?? e).slice(0, 160) });
    return undefined;
  }
}

// ── One certificate for the whole call (§security) ───────────────────────────
// Every RTCPeerConnection normally mints its OWN certificate, which would mean a
// call at pcmpairs=6 has seven independent DTLS identities and a code derived from
// the main pc's fingerprints would say nothing about the six audio stripes — a
// machine-in-the-middle could sit on those alone and the code would still match.
// Reusing one certificate everywhere makes a single code cover the entire call.
// Generation is started here, at parse time, and only awaited just before the pc
// is built: getUserMedia runs in between and takes far longer, so this is off the
// join path in practice, and it is raced against a deadline in case it is not.
const localCert = (async () => {
  try {
    return await RTCPeerConnection.generateCertificate({ name: 'ECDSA', namedCurve: 'P-256' });
  } catch {
    return null; // let each pc mint its own; the code then covers the main pc only
  }
})();
let sharedCert = null;
const certArg = () => (sharedCert ? { certificates: [sharedCert] } : {});

// ── Re-arming for a second peer ──────────────────────────────────────────────
// A page that has already carried a call cannot carry a second one. `ontrack`
// has a once-guard (`remoteAttaching || remoteMon`) that will not attach a
// second remote stream, the receiver's track ended with the peer who left, and
// with the lane flags on the datachannels and transforms belong to the dead
// connection too. Renegotiating over that wreckage does not fail cleanly — it
// HALF works, which is worse: measured on the rejoin arm, the returning peer's
// video decoded (framesDecoded 148 → 208) while `#remote` stayed 0×0 with the
// "waiting for the other person" overlay still up. So the incumbent re-arms
// from a clean page the moment someone arrives.
//
// Only a page that actually connected does this. The normal flow — one person
// opens a room and waits, the other joins — arrives here with `hadPeer` false
// and nothing reloads.
let hadPeer = false;
const REARM_KEY = 'tape.rearmAt';
const REARM_COOLDOWN_MS = 20_000;
// `force` is for the one caller that has no other move left: the in-place reset
// failed, so this reload IS the recovery rather than a duplicate of it. Without
// it the cooldown below could swallow the only path back and leave a spent page
// sitting there forever — which is exactly how "refresh used to work" turned
// into "refresh stopped working" once the in-place path went in front of it.
// A forced reload cannot loop: the fresh page starts with `hadPeer` false.
function reArmForNewPeer(room, { force = false } = {}) {
  if (!hadPeer) return false;
  // Per-tab cooldown, in sessionStorage so it survives the reload it guards.
  // Two people reconnecting in the same second can otherwise each re-arm on
  // the other's arrival forever; this caps each side at one reset per window,
  // so the pathological case costs a few seconds and then settles.
  const last = safe(() => Number(sessionStorage.getItem(REARM_KEY)) || 0, 'rearm.read') ?? 0;
  if (!force && Date.now() - last < REARM_COOLDOWN_MS) return false;
  safe(() => sessionStorage.setItem(REARM_KEY, String(Date.now())), 'rearm.mark');
  tel?.log('rearm', { room });
  setStatus('reconnecting…');
  safe(() => {
    const u = new URL(location.href);
    u.searchParams.set('r', room);
    u.searchParams.set('rejoin', '1'); // read at boot — walks straight back in
    location.replace(u.toString());
  }, 'rearm.go');
  return true;
}

// ── Own-side connection recovery (task #50) ──────────────────────────────────
// reArmForNewPeer covers the PEER vanishing. This covers US: walk out of wifi
// range mid-call and every transport dies at once — the signaling socket
// closes, ICE on 7 peer connections goes disconnected→failed — and until now
// the app's entire response was a status string telling the user to leave and
// rejoin by hand. The recovery IS that rejoin, done for them: reload into the
// same room and let the resume machinery (task #36) walk back in. The peer's
// side needs nothing new — our rejoin arrives as peer-joined and its own
// reArmForNewPeer resets it to match. In-place ICE restart (no reload, no
// black frame) is the planned refinement; this ships the difference between
// "call comes back by itself" and "call is dead forever".
let leavingDeliberately = false; // teardown's own closes must not read as death
let recoverTimer = null; // pending 'disconnected' escalation
let activeRoom = null; // the joined room; join() owns `room` locally
const RECOVER_KEY = 'tape.recoverAt';
const RECOVER_COOLDOWN_MS = 10_000; // per-tab, survives the reload it causes
const RECOVER_MAX = 4; // within RECOVER_WINDOW_MS — then stop trying: this
const RECOVER_WINDOW_MS = 3 * 60_000; // network is not coming back on its own
function recoverCall(why) {
  if (leavingDeliberately || !hadPeer || !joined || !activeRoom) return;
  const now = Date.now();
  const past = (safe(() => JSON.parse(sessionStorage.getItem(RECOVER_KEY) ?? '[]'), 'recover.read') ?? [])
    .filter((t) => now - t < RECOVER_WINDOW_MS);
  if (past.length && now - past[past.length - 1] < RECOVER_COOLDOWN_MS) return;
  if (past.length >= RECOVER_MAX) {
    setStatus('connection lost — will reconnect when the network returns');
    return;
  }
  past.push(now);
  safe(() => sessionStorage.setItem(RECOVER_KEY, JSON.stringify(past)), 'recover.mark');
  tel?.log('recover', { why, attempt: past.length });
  window.__hbEnd?.('recover'); // field data: how often real calls hit this
  setStatus('connection lost — reconnecting…');
  // The same proven route as reArmForNewPeer: boot with ?rejoin=1 presses join
  // itself. 300 ms lets the telemetry flush attempt and the beacon leave first.
  //
  // NEVER navigate while offline (measured on the M13, 2026-08-05: cutting
  // WiFi mid-call fired this reload ~3 s later, straight into
  // chrome-error://chromewebdata — and an error page has none of our code, so
  // the call stayed dead even after the network returned). If the browser says
  // offline, hold the reload until the 'online' event, then give the new
  // network a beat to validate before navigating.
  const go = () => safe(() => {
    const u = new URL(location.href);
    u.searchParams.set('r', activeRoom);
    u.searchParams.set('rejoin', '1');
    location.replace(u.toString());
  }, 'recover.go');
  setTimeout(() => {
    if (navigator.onLine) return go();
    setStatus('connection lost — will reconnect when the network returns');
    tel?.log('recover', { why: 'awaiting-online' });
    window.addEventListener('online', () => setTimeout(go, 1500), { once: true });
  }, 300);
}

// ── Self-view lobby (task #28, user directive 2026-08-02) ────────────────────
// From join until the peer's first track lands, the user's own camera fills the
// screen — the same fullscreen preserve-aspect treatment as the remote view
// (#selfFull: inset 0 + object-fit: cover, mirrored). On peer arrival the
// remote view takes the screen and self view shrinks to the conventional
// static corner PiP (toggleable via the c-selfview chip).
function peerArrived() {
  hadPeer = true;
  safe(() => {
    $('waiting').classList.add('gone');
    // §D.17 crossfade: their first frame fades the full-screen self view out
    // over 250 ms instead of cutting to it. The cheapest premium-feel win in
    // the app, and it costs one class.
    const sf = $('selfFull');
    if (sf.classList.contains('on')) {
      sf.classList.add('fading');
      setTimeout(() => safe(() => sf.classList.remove('on', 'fading'), 'peer.crossfade'), 260);
    }
    startElapsed();
    window.__hbConnect?.(); // health beacon: the call counts as connected here
    // Self view stays OFF (task #38 §B.9). This is the line that used to force
    // the PiP on, and removing it is the single most evidence-backed change in
    // the redesign: the all-day mirror is Bailenson's second mechanism (2021),
    // and Fauville et al. (2021, N=10,322) found mirror anxiety a significant
    // predictor of videoconference fatigue. It is one hold away on the
    // self-view button and pinnable from the more sheet — it just never
    // arrives uninvited.
    startRemoteFill();
    applyChips();
  }, 'peer.arrived');
}

// ── Encryption code (§security) ──────────────────────────────────────────────
// DTLS-SRTP authenticates the peer against a certificate fingerprint that we
// exchange over OUR OWN signalling server. That server is therefore trusted: if
// it substituted its own fingerprints it could sit in the middle of the call and
// neither side would see anything wrong. This is the standard WebRTC trust model,
// and the standard answer is to let the two humans check the keys out of band.
//
// So: hash both fingerprints into eight characters and show them. If both people
// see the same code, no key was substituted. The fingerprints are already in
// getStats(), the hash is a few hundred bytes of SHA-256 once per call, and
// nothing here touches the media path — this costs zero latency.
//
// Sorted before hashing because each side sees the pair in the opposite order
// (my local certificate is your remote one). Sorting is what makes the two
// independently-computed codes equal.
const CODE_ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'; // 32 chars, no 0/O/1/I
async function computeSafetyCode() {
  if (!pc) return null;
  const stats = await pc.getStats();
  let transport = null;
  stats.forEach((s) => {
    if (s.type === 'transport' && s.localCertificateId && s.remoteCertificateId) transport = s;
  });
  if (!transport) return null;
  const fp = (id) => {
    const c = stats.get(id);
    if (!c?.fingerprint) return null;
    return `${c.fingerprintAlgorithm ?? 'sha-256'} ${c.fingerprint}`.toLowerCase();
  };
  const local = fp(transport.localCertificateId);
  const remote = fp(transport.remoteCertificateId);
  if (!local || !remote) return null;
  const digest = new Uint8Array(
    await crypto.subtle.digest('SHA-256', new TextEncoder().encode([local, remote].sort().join('|'))),
  );
  // 8 chars x 5 bits = 40 bits. An attacker cannot grind a colliding certificate
  // pair inside a live handshake, and 8 characters is short enough to read aloud.
  let out = '';
  for (let i = 0; i < 8; i++) out += CODE_ALPHABET[digest[i] & 31];
  return `${out.slice(0, 4)} ${out.slice(4)}`;
}

let safetyCode = null;
function refreshSafetyCode() {
  safeAsync(async () => {
    const el = $('safetyCode');
    if (!el) return;
    const code = await computeSafetyCode();
    if (!code) return; // keep the last good value; a blank code reads as "broken"
    if (code !== safetyCode) tel?.log('safety-code', { code, shared: !!sharedCert });
    safetyCode = code;
    el.textContent = code;
    el.dataset.pending = '0';
  }, 'safety-code');
}

/** Status pill: shown on every change, fades a few seconds after "connected"
 * so the default call UI ends as a face and nothing else. Text is kept in the
 * DOM (tests read it); only the pill's opacity goes. */
// Statuses that describe a MOMENT fade after 3 s. Statuses that describe a
// state you are still in ("waiting…", "reconnecting…", "connection failed")
// stay up, because hiding one would leave the screen claiming nothing is wrong
// while something still is. "they left" used to stay forever purely because the
// fade was hard-coded to the literal string 'connected'.
const TRANSIENT_STATUS = new Set(['connected', 'they left']);
function setStatus(t) {
  safe(() => {
    const s = $('status');
    s.textContent = t;
    s.classList.remove('gone');
    if (TRANSIENT_STATUS.has(t)) setTimeout(() => {
      if (s.textContent === t) s.classList.add('gone');
    }, 3000);
  }, 'status');
}

// ── Layout ───────────────────────────────────────────────────────────────────
// One mode: fill the viewport, CONTAIN the picture (§5, user directive: no crop
// on either device). The §1.1a life-size + gaze experiment that used to live
// here was removed 2026-08-04 (user directive) along with its calibration UI.
function layout() {
  safe(() => {
    $('call').classList.add('fill');
    $('call').classList.add('contain');
  }, 'layout');
}

// ── The letterbox wash (§5 item 22) ──────────────────────────────────────────
// Contain-fit means no crop, which means empty space beside a portrait caller
// on a landscape screen. Black bars are the honest-but-cheap answer; a blurred
// wash of the same picture keeps edge luminance continuous so the face reads as
// the subject instead of as a slide.
//
// The spec called for a second <video> sharing the srcObject. That is wrong
// here for a reason the spec could not see from index.html: on the lane-2
// canvas display path (?l2canvas=1, the default) #remote's srcObject is the
// CARRIER, not the presented picture — a second video would show the wrong
// thing. Sampling whatever element is actually on screen into a 32×18 canvas at
// 2 Hz works on both paths, costs one drawImage instead of a decode, and the
// compositor's upscale does most of the blurring for free.
let fillTimer = null;
let fillW = 0;
let fillH = 0;
function startRemoteFill() {
  if (fillTimer) return;
  safe(() => {
    // Weak devices get a flat panel: no sampler, no filter, no second surface.
    // The ladder already decided this machine cannot spare the work (§17.25).
    // The TIMER still runs on them, because it is also the sender-rotation
    // watch below and reading two integers costs nothing.
    if (resolveDevTier() !== 'strong') $('call').classList.add('flat');
    const c = $('remoteFill');
    const ctx = c?.getContext?.('2d', { alpha: false });
    if (!ctx) return;
    fillTimer = setInterval(
      () => safe(() => {
        const call = $('call');
        const src = $('remoteCanvas') ?? $('remote');
        // videoWidth is 0 until a frame lands and undefined on a canvas, where
        // .width is the real one — `??` keeps the 0 so we bail before painting
        // a blank wash over the first frame.
        const w = src.videoWidth ?? src.width;
        const h = src.videoHeight ?? src.height;
        if (!w) return;
        // §5 item 24: when the SENDER rotates, their track dimensions flip and
        // ours do not — no window resize fires, and on the canvas path there is
        // no element resize event either, because the tape renderer owns the
        // canvas. This 2 Hz read is the only thing that sees both paths, so it
        // is what re-decides cover vs contain. Cheap: two integers per tick.
        if (w !== fillW || h !== fillH) {
          fillW = w;
          fillH = h;
          layout();
        }
        if (!call.classList.contains('contain') || call.classList.contains('flat')) return;
        ctx.drawImage(src, 0, 0, c.width, c.height);
      }, 'fill.sample'),
      500,
    );
  }, 'fill.start');
}

// ── What picture to ask for, and in what codec ────────────────────────────────
// Both are overridable from the query string so the two can be measured against each other
// rather than argued about — `?res=720&codec=vp8` reproduces the previously measured config.
// The defaults are the ones that won on this machine; see §17.2.
const QS = new URLSearchParams(location.search);

// ── Synthetic media (test hook, ?synthmedia=1) ───────────────────────────────
// Real Safari has no fake-device flags (Chromium's --use-fake-device... has no
// WebKit equivalent) and a WebDriver session cannot answer the camera/mic
// permission prompt. This shim replaces getUserMedia wholesale with a canvas
// capture + noise audio graph so the REAL engine's scheduling, worklets and
// datachannel path can be measured end-to-end (task #42). It fakes the
// stimulus, never the pipeline — everything downstream of the tracks is the
// shipping code. Off unless the flag is present, so it cannot affect users.
if (QS.get('synthmedia') === '1') {
  const cv = document.createElement('canvas');
  cv.width = 1280; cv.height = 720;
  const g = cv.getContext('2d');
  let fr = 0;
  const draw = () => {
    fr++;
    // Moving gradient + per-frame noise blocks: sd well above the harness's
    // "black/flat" threshold, and it never repeats a frame exactly.
    const grad = g.createLinearGradient((fr * 7) % cv.width, 0, ((fr * 7) % cv.width) + 640, cv.height);
    grad.addColorStop(0, '#204060'); grad.addColorStop(1, '#c0a040');
    g.fillStyle = grad; g.fillRect(0, 0, cv.width, cv.height);
    for (let i = 0; i < 64; i++) {
      g.fillStyle = `rgb(${(i * 53 + fr * 11) % 256},${(i * 97 + fr * 5) % 256},${(i * 31 + fr * 17) % 256})`;
      g.fillRect((i * 149 + fr * 3) % (cv.width - 40), (i * 211) % (cv.height - 40), 40, 40);
    }
  };
  // setInterval, NOT requestAnimationFrame. Safari stops rAF entirely while
  // the window is occluded (another window on top is enough — no tab switch
  // needed), so an rAF-driven source dies the moment the harness's own peer
  // browser opens over it: preview never lights, joins wedge with no error.
  // Measured 2026-08-05: 8/8 batch failures with the user's window in front,
  // and window-stacking races made single runs fail ~half the time. Interval
  // timers keep firing at full rate while the page is visible-but-occluded.
  setInterval(draw, 33);
  let synthCtx = null;
  navigator.mediaDevices.getUserMedia = async (c = {}) => {
    const out = new MediaStream();
    if (c.video) for (const t of cv.captureStream(30).getVideoTracks()) out.addTrack(t);
    if (c.audio) {
      synthCtx ??= new (window.AudioContext ?? window.webkitAudioContext)({ sampleRate: 48000 });
      const dst = synthCtx.createMediaStreamDestination();
      // Speech-band noise, not silence: the PCM lane's lossless coder would
      // shrink silence to nothing and understate the real send rate.
      const buf = synthCtx.createBuffer(1, synthCtx.sampleRate * 2, synthCtx.sampleRate);
      const d = buf.getChannelData(0);
      let s = 22222;
      for (let i = 0; i < d.length; i++) { s = (s * 1103515245 + 12345) & 0x7fffffff; d[i] = (s / 0x3fffffff - 1) * 0.08; }
      const src = synthCtx.createBufferSource();
      src.buffer = buf; src.loop = true; src.connect(dst); src.start();
      // Safari suspends a context created without a user gesture; the join
      // click (a trusted WebDriver click counts) resumes it.
      if (synthCtx.state === 'suspended') addEventListener('click', () => synthCtx.resume(), { once: true });
      for (const t of dst.stream.getAudioTracks()) out.addTrack(t);
    }
    return out;
  };
}

// Phones get hard ceilings the desktop path does not (task #13, room log
// 2026-08-06): receiver-driven resolution made an Android encode 1080p60 while
// decoding ~1080p — the device melted (2–5 fps out, 30 s of freezes per
// session). A phone's panel is small and close; 720p is visually transparent
// there, and half the pixels each way is the whole difference between a call
// and a slideshow. `?res=`/`?fpsmax=` still override for experiments.
const IS_MOBILE = /Android|iPhone|iPad|Mobi/i.test(navigator.userAgent);
const WANT_H = Number(QS.get('res')) || (IS_MOBILE ? 720 : 1080);
const WANT_W = WANT_H >= 1080 ? 1920 : 1280;
// H.264 by default, which is not the obvious choice and was not a guess. Measured with VMAF
// against a 1080p master, at the bitrate each codec actually achieves in Chrome on this machine:
// VP8 720p (the previous default) 68.9, VP9 1080p 70.6, H.264 1080p 91.3, AV1 1080p 96.7.
// H.264 gains 22 VMAF points over what was shipping while sending *fewer* bits, because Chrome
// hands it to VideoToolbox — a hardware encoder — and because VP9's realtime rate control leaves
// nearly half the 12 Mbps budget unspent (6.2 of 12 measured).
//
// AV1 scores higher still and is the eventual answer, but it has no hardware encoder here: on an
// unknown machine it risks a CPU-limited, stuttering call, and the gap from 91 to 97 is a far
// smaller loss than that. Reachable with ?codec=av1 for anyone who knows their hardware.
const WANT_CODEC = (QS.get('codec') || 'h264').toLowerCase();

// ── Encoder adaptation policy, overridable for measurement ───────────────────
// The levers that decide WHAT the encoder gives up when the scene demands more bits
// than the cap allows: sharpness, resolution, or frame rate. They are the same kind of
// knob as ?res= and ?codec= above and exist for the same reason — so the arms can be
// measured against each other on one machine instead of argued about.
//
// ALL FOUR DEFAULT TO THE SHIPPED VALUES: with no query string the resulting
// parameters are identical to what shipped before these constants existed.
//   ?hint=motion|detail|text|none  contentHint on the capture track   (default motion)
//   ?degrade=maintain-framerate|maintain-resolution|balanced          (default maintain-framerate)
//   ?maxfps=N                      encodings[0].maxFramerate          (default 30)
//   ?scaledown=N                   encodings[0].scaleResolutionDownBy (default 1)
//
// DEFAULTS FLIPPED 2026-08-02 (task #44). `maintain-resolution` was measured
// doing exactly what it promises, which turns out to be a disaster at the bottom
// of the ladder. Matched pairs, same fixture, same machine:
//
//   loopback 12 Mbps   resolution 29.98 fps   framerate 30.04 fps   (tie, inside noise)
//   3 Mbps / 60 ms     resolution 29.03 fps   framerate 29.98 fps   (QP 42.5 vs 31.9)
//   1.2 Mbps / 80 ms   resolution  2.99 fps   framerate 30.03 fps   (10x)
//
// At 1.2 Mbps the resolution-preserving arm pinned 1080p, ran out of QP at 42.7,
// and paid the rest in frames — 3 fps, inter-frame p50 274 ms, p99 993 ms. Worse,
// it could not even spend the bandwidth it had (621 vs 919 kbps): a 1080p frame
// at max QP is the smallest thing it was willing to send. `qualityLimitationReason`
// read "none" for the entire 48 s, so the standard WebRTC diagnostic is blind to
// this failure — which is why it survived this long.
//
// The framerate arm dropped to 640x360 instead and held 30 fps. That is the right
// trade and it is not close: on a 1:1 call the remote is sized from the peer's
// physical head geometry, so a downscale costs sharpness and not apparent size
// (verified — `layout()` reads peerGeom millimetres, and the pixel dims enter only
// as an aspect ratio, which uniform scaling leaves invariant).
//
// `?degrade=maintain-resolution&hint=detail` restores the old arm exactly.
const HINT_Q = QS.get('hint');
const V_HINT = HINT_Q == null ? 'motion' : HINT_Q === 'none' ? '' : HINT_Q;
const V_DEGRADE = QS.get('degrade') || 'maintain-framerate';
// `?maxfps=N` now FORCES the sender cap; unset means "decide it from the receiver".
// The old default of a flat 30 was the single largest gap between this app and the
// stated goal: a peer on a 60 Hz display was being sent half the frames their screen
// could present, and no code anywhere asked what their screen could do.
const V_MAXFPS = Number(QS.get('maxfps')) || null;
// The most we will ever ASK the camera for, and the most we will ever send. 60 because
// that is what ordinary hardware presents today (the display on this machine is a
// high-refresh panel currently driven at 60.00 Hz) and because 1080p30 measured 5.24 ms
// of encode per frame — 60 fps needs about 31% of one core, which is affordable.
// `?fpsmax=` raises or lowers the ceiling for measurement.
// 72, not 60, because of CADENCE. On a 144 Hz display 60 fps is a ratio of 2.40, so every
// frame is held for 2 or 3 refresh intervals in an uneven 2,2,3 pattern — visible judder
// with zero frames lost. 72 divides 144 exactly and is therefore both faster AND smoother
// than 60 there. Measured affordable: 1080p fixed-QP costs 4.97 ms/frame, so 72 fps is 35.8%
// of one core (60 fps is 29.9%, 120 fps is 58.8%). Not higher than 72: fixed-QP encoding
// FAILS outright at framerate 144 on this machine ("Unsupported bitrate mode"), and real
// camera content at constant QP24 already runs ~9.5-12 Mbps at 30 fps, so the bandwidth
// ceiling binds long before the CPU one does.
// On phones the ceiling is 30: the fps-repair pass was pushing a budget Android
// camera to 1080p60 (capture-fps-repair 'repaired' in the 2026-08-06 room log),
// and the sensor + ISP at 60 fps is a large slice of both the CPU melt and the
// battery bill (#48: the phone bill is mostly camera and radio).
const FPS_CEILING = Number(QS.get('fpsmax')) || (IS_MOBILE ? 30 : 72);
// `?cadence=0` disables snapping the send rate to a whole divisor of the peer's refresh.
const CADENCE_SNAP = QS.get('cadence') !== '0';
// How much of the frame rate we are willing to give up to buy an even cadence. Two budgets,
// because the two cases are not the same size of defect:
//
//   ratio >= 2 (e.g. 60 fps on 144 Hz = 2.40): frames alternate between 2 and 3 refresh
//   intervals. A 50% duration error, and cheap to leave alone. Small drops only — a 30 fps
//   camera should NOT fall to 24 to square itself with a 144 Hz panel.
//
//   ratio < 2 and not exactly 1 (e.g. 72 fps on 120 Hz = 1.67): some frames get ONE refresh
//   and some get TWO. A 100% duration error, the worst cadence available, and it cannot be
//   fixed by any rate above hz/2. Worth a real frame-rate cut, and hz/2 always exists.
//
// Whether an even rate actually looks better than a faster uneven one is UNMEASURED. These
// budgets are chosen so the answer only matters in cases where the cost is small.
const CADENCE_MIN_KEEP = 0.85;
// A refresh-rate reading is only usable if the rAF intervals were tightly grouped. ONE
// CONSTANT FOR BOTH DIRECTIONS: the gate was applied to the peer's reading and not to our
// own, and headless Chromium's junk 81.8 Hz then capped our send rate at 48 fps through
// `carrierCap` — the untrusted number took effect by a second route that had no gate on it.
//
// The test is the IQR AS A FRACTION OF THE MEDIAN, not `lockedPct`. lockedPct counts
// intervals within 10% of the median, and 10% of a SHORTER interval is a TIGHTER absolute
// window — so it grew stricter exactly as displays got faster, which is backwards. Scored
// against every reading taken on 2026-08-03:
//
//   real 144 Hz panel, 5 readings   relIQR 0.003 - 0.091   lockedPct 69.2% - 98.3%
//   headless Chromium, 2 readings   relIQR 0.349 - 0.368   lockedPct 30.8% - 34.2%
//
// relIQR accepts all five real readings with 2.2x headroom and rejects both junk ones;
// lockedPct wrongly rejected two of the five real ones. Kept in telemetry, not in the gate.
const HZ_TRUST_MAX_REL_IQR = 0.20;
const hzTrusted = (hz, medianMs, iqrMs, lockedPct) => {
  if (!(hz > 0)) return false;
  // Older peers send lockedPct but no median, so fall back rather than reject them.
  if (medianMs > 0 && iqrMs != null) return iqrMs / medianMs <= HZ_TRUST_MAX_REL_IQR;
  return lockedPct == null ? true : lockedPct >= 80;
};
const CADENCE_MIN_KEEP_SUB2 = 0.5;
const V_SCALEDOWN = Number(QS.get('scaledown')) || 1;

// ── Weak-device ladder (task #37) ────────────────────────────────────────────
// Samsung M13, Chrome 147 Android (m13-diagnosis.md, two live prod sessions): no
// H.264 in the device's sender capabilities at all — available=[VP8, VP9, H265] —
// so the negotiated codec (VP9 by first-fit) encodes in SOFTWARE: measured 323
// ms/frame at 1080×1920, 10× the realtime budget, Chrome cpu-throttling the
// camera to 2–9 fps with qualityLimitationReason=cpu climbing monotonically. On
// that device class the shock absorber is RESOLUTION AT CAPTURE, never per-pixel
// quality (same spine, smaller frame): clamp the capture ask to a ceiling the
// software encoder can carry, and prefer software VP8 (2–3× cheaper per frame
// than software VP9). Devices WITH H.264 are never touched — tier 'strong' keeps
// every constraint, codec preference, and sender parameter byte-identical.
//
// Data-driven tiers: `?devtier=weak|weaker|strong` forces a tier for testing,
// `?ladder=0` kills the whole ladder (ceiling + codec preference).
const DEV_LADDER = QS.get('ladder') !== '0';
const DEV_TIER_FORCE = QS.get('devtier');
const DEV_TIERS = {
  strong: null, // no ceiling — hardware encode, byte-identical behaviour
  weak: { w: 960, h: 540, fps: 24 }, // default software-encode ceiling
  weaker: { w: 640, h: 360, fps: 24 }, // the 323 ms/frame → ~35 ms math in the note
};
const hasH264 = (codecs) => !!codecs?.some((c) => /h264|avc/i.test(c?.mimeType || ''));
const videoCaps = () => {
  try {
    return RTCRtpSender.getCapabilities?.('video')?.codecs ?? null;
  } catch {
    return null;
  }
};
let devTier = null;
let devTierWhy = null;
function resolveDevTier() {
  if (devTier) return devTier;
  const codecs = videoCaps();
  if (DEV_TIER_FORCE && DEV_TIER_FORCE in DEV_TIERS) {
    devTier = DEV_TIER_FORCE;
    devTierWhy = `forced:${DEV_TIER_FORCE}`;
  } else if (!DEV_LADDER) {
    devTier = 'strong';
    devTierWhy = 'ladder-off';
  } else if (codecs && !hasH264(codecs)) {
    devTier = 'weak';
    devTierWhy = 'no-h264';
  } else {
    devTier = 'strong';
    devTierWhy = codecs ? 'h264-present' : 'caps-unknown';
  }
  return devTier;
}
const devCeiling = () => DEV_TIERS[resolveDevTier()] ?? null;

// ── Measured step-down (task #37, round 2) ───────────────────────────────────
// The static capability trigger was falsified by prod (session x-msaxl3a4-q4bs):
// an M13 on Chrome 150 HAS H.264 — devtier correctly read strong/h264-present —
// yet its RAW camera track delivered a steady 5 fps at 1080×1920 for 47 s
// (srcprobe). Capture-side starvation, before any encoder exists; no codec list
// can see it. So the ladder also MEASURES: the join-armed srcprobe's delivered
// fps is compared against what the current tier asked for. Delivery under 60%
// of the ask, sustained for 5 s (after a warmup that lets the camera and the
// 2.5 s camlock settle), steps capture down one tier via re-applyConstraints —
// repeating until delivery recovers (≥80% of the tier target is the healthy
// bar; the 60–80% band is a dead zone so the boundary can't flap) or the floor
// tier is reached. Steps are ONE-WAY: capture never steps up automatically.
//
// The codec ladder stays static in this round: an H.264-present device that
// starves at capture may still encode VP9 in software and be better off on VP8,
// but that choice needs the same measured treatment (encode-ms-per-frame is in
// the stats already) and is deliberately not this change.
const DEV_MEASURE = DEV_LADDER && QS.get('stepper') !== '0' && DEV_TIER_FORCE !== 'strong';
const DEV_STEP_ORDER = ['strong', 'weak', 'weaker']; // one-way, left to right; last is the floor
const DEV_STEP_WARMUP_MS = 6000; // camera start + camlock settle before any judgement
const DEV_STEP_LOW_MS = 5000; // sustained-low proof before a step
const DEV_STEP_LOW_FRAC = 0.6; // delivered under this fraction of the ask = starving
let devStepTier = null; // the tier in effect NOW; starts at resolveDevTier(), only walks down
let devStepLowMs = 0; // consecutive accumulated low-delivery time

// Judge delivery against what the camera AGREED to, never against what we
// asked for. Measured (two-browser regression, ladder-on arm): a healthy
// camera delivered 19.4–20.5 fps while the trip point sat at 18.0 — 60% of a
// hard-coded 30 the camera had never accepted. That is an 8% margin from
// throwing away half the pixels of a camera with nothing wrong with it, and a
// 15 fps webcam (ladder-sim: honest-camera-below-30fps) crosses it outright and
// is stepped 1920×1080 → 960×540 for nothing.
//
// `getSettings().frameRate` is the camera's answer to our constraint, so
// delivering all of it means healthy by definition. The starvation this ladder
// exists for still trips: the M13 ACCEPTS 30 and then delivers 5.
//
// RESIDUAL, needs the device to settle: this assumes getSettings() reports the
// NEGOTIATED rate. A HAL that reports the achieved rate instead would read
// 5 fps as both target and delivery and look healthy — which would silence the
// low-light path too. `?fpsagree=0` restores the old constant-target behaviour,
// and phone-test.sh prints the M13's own settings.frameRate so this can be
// confirmed rather than assumed.
const FPS_AGREE = QS.get('fpsagree') !== '0';
function devTargetFps() {
  const t = DEV_TIERS[devStepTier ?? resolveDevTier()];
  const tierFps = t ? t.fps : 30; // tier 'strong' asks 30
  if (!FPS_AGREE) return tierFps;
  const agreed = safe(() => srcProbe?.track?.getSettings?.().frameRate, 'devtarget.agreed');
  return Number.isFinite(agreed) && agreed > 0 ? Math.min(tierFps, agreed) : tierFps;
}

function devStepEval(fps, dtMs) {
  if (!DEV_MEASURE || fps == null || !srcProbe) return;
  // Zero delivery is the revival path's problem — a stalled camera is not a
  // resolution problem. And while low-light mode owns the exposure, delivered
  // fps is capped by the manual exposureTime, not by the tier: stepping on
  // that signal would chase an artefact. Its fps AFTER the exposure fix is
  // the stepper's next honest input.
  if (fps === 0 || lowlightOn) {
    devStepLowMs = 0;
    return;
  }
  if (performance.now() - srcProbe.t0 < DEV_STEP_WARMUP_MS) return;
  const target = devTargetFps();
  devStepLowMs = fps < target * DEV_STEP_LOW_FRAC ? devStepLowMs + dtMs : 0;
  if (devStepLowMs >= DEV_STEP_LOW_MS) devStepDown(srcProbe.track, `delivered ${fps} fps < 60% of asked ${target}`);
}

async function devStepDown(track, why) {
  const i = DEV_STEP_ORDER.indexOf(devStepTier ?? resolveDevTier());
  if (i < 0 || i >= DEV_STEP_ORDER.length - 1) {
    devStepLowMs = 0; // floor tier reached: stop judging, stop accumulating
    return;
  }
  const from = DEV_STEP_ORDER[i];
  const to = DEV_STEP_ORDER[i + 1];
  const t = DEV_TIERS[to];
  devStepTier = to; // committed synchronously: a step is never re-attempted and never reversed
  devStepLowMs = 0;
  const asked = { w: Math.min(WANT_W, t.w), h: Math.min(WANT_H, t.h), fps: t.fps };
  let applied = null;
  await safeAsync(async () => {
    await track.applyConstraints({
      width: { ideal: asked.w },
      height: { ideal: asked.h },
      frameRate: { ideal: asked.fps },
      resizeMode: 'none',
    });
    applied = pick(track.getSettings(), ['width', 'height', 'frameRate']);
  }, 'devstep.apply');
  tel?.log('devstep', { from, to, why, asked, applied, ok: applied ? 1 : 0 });
  if (applied) relockCamera(track); // interaction rule: never fight camlock
}

// ── Low-light motion priority + stall revival (task #37, session 4) ─────────
// Proven on the real M13 over USB (m13-diagnosis session 4, pitch-dark room):
//
//   · The fps starvation is EXPOSURE-bound, not resolution-bound: AE stretches
//     exposureTime to ~1200 ms in the dark, capping delivered fps at
//     1000/exposureTime regardless of tier (5 fps @1080×1920, 8 fps @720×960).
//   · Sequential applyConstraints — {frameRate:24} THEN {exposureMode:'manual',
//     exposureTime:33, iso:2500} — lifted delivered fps 8 → 20.4 in the SAME
//     dark room. A tier step cannot do that; this can.
//   · Chrome-Android throws OverconstrainedError ("Mixing ImageCapture and
//     non-ImageCapture constraints") when exposureTime/iso ride in the SAME
//     applyConstraints as width/height/frameRate — always sequential calls.
//   · Frame delivery can stall to 0 while track.readyState stays 'live';
//     re-applying the current constraints REVIVES it.
//
// Evaluation order per tick is revive → lowlight → devstep: a dead camera has
// no fps to judge, and a tier step while exposure-capped buys nothing — each
// stage only sees the signal the earlier stages couldn't fix.
// OPT-IN as of 2026-08-05 (?lowlight=1). Measured on the SAME real M13 that
// proved the recipe in session 4: in a LIT room (luma 53.5) the manual-exposure
// recipe now drives luma to 0 — a black picture, not a brighter one — flips the
// sensor into its 1088×1088 square mode, and leaves exposureMode reading
// 'none'; in a live prod call it stalled delivery to 0 fps, all 4 revives
// failed, and the re-acquire returned no video — a dead camera for the rest of
// the call. This is the user-visible "Android dimming". The recipe's fps win
// was real once, but a mode that can black out or kill the camera cannot be a
// default; brightness belongs to AE (see the camlock block comment).
const LOWLIGHT_ON = QS.get('lowlight') === '1'; // needs the luma watchdog (?luma=0 blinds it)
const REVIVE_ON = QS.get('revive') !== '0';
const LOWLIGHT_LUMA = 20; // below: dark enough that AE is stretching exposure
const LOWLIGHT_LUMA_HI = 60; // above, sustained: light returned — restore AE
// The shutter-entry exit is a different threshold on purpose. A lamp-lit room
// engages via slow shutter with a WELL-EXPOSED picture (~110 luma), and the
// brightness-preserving recipe below keeps it there — luma > 60 would fire
// immediately and flap forever (engage 4 s, exit 10 s, repeat). Under a fixed
// short exposure, luma rises in proportion to room light, so "near clipping"
// is the honest signal that AE could now hold the target fps on its own.
const LOWLIGHT_SLOW_EXIT = 180; // shutter entries exit only this bright, sustained
const LOWLIGHT_HOLD_MS = 4000; // dark AND starving, sustained, to engage
const LOWLIGHT_HI_MS = 10000; // bright, sustained, to disengage (hysteresis)
const REVIVE_STALL_MS = 3000; // delivered == 0 this long with a live track
const REVIVE_MAX = 3; // this many failed revivals inside REVIVE_WIN_MS → re-acquire
const REVIVE_WIN_MS = 60000;
let lowlightOn = false;
let lowlightWhy = null; // 'dark' | 'shutter' — decides recipe and exit threshold
let lowDarkMs = 0; // accumulated dark-and-starving time
let lowLightMs = 0; // accumulated bright-again time while engaged
let lowlightResultTimer = null;
let reviveTimes = []; // attempt timestamps inside the 60 s window
let reviveStallMs = 0; // accumulated zero-delivery time
let reviveBusy = false; // one revival/re-acquire in flight at a time

/** The constraint ask of the tier currently in effect (post any devstep). */
function currentCaptureAsk() {
  const t = DEV_TIERS[devStepTier ?? resolveDevTier()];
  return t ? { w: Math.min(WANT_W, t.w), h: Math.min(WANT_H, t.h), fps: t.fps } : { w: WANT_W, h: WANT_H, fps: 30 };
}

/**
 * The manual-exposure half of low-light mode, as its own call (sequencing rule).
 *
 * UNIT WARNING — `exposureTime` is NOT milliseconds. W3C Image Capture defines
 * it in 100-MICROSECOND units, and the M13's own numbers prove it: AE in the
 * dark reported exposureTime ~1200 while still delivering ~8 fps, and 8 fps
 * allows at most 125 ms per frame, so 1200 can only be 120 ms. The `1000/fps`
 * below therefore asks for a tenth of the frame period, not a frame period —
 * at fps 24 that is 4.2 ms, which is why session 4's hand-set 33 (3.3 ms)
 * behaved the same. It is kept because 20.4 fps was MEASURED with it; the
 * value is proven, its derivation is a coincidence. `?llexp=<units>` overrides
 * it so the trade can be swept on the device: a longer exposure is a brighter
 * picture, and the ceiling it costs is 1000/(expMs + sensor readout) fps.
 */
const LOWLIGHT_EXP = Number(QS.get('llexp')) || 0; // 100 us units; 0 = the proven default
async function applyLowlightExposure(track, why = 'dark', prev = null) {
  const caps = safe(() => track.getCapabilities?.(), 'lowlight.caps') ?? {};
  const fps = devTargetFps();
  // Two entries, two recipes (task #46). 'dark': the proven M13 numbers — a
  // tenth of the frame period plus max ISO, because there is no light to
  // spare. 'shutter': the room HAS light (the picture was well exposed at a
  // slow shutter), so ask 0.35 of the frame period — still clears the fps
  // ceiling after sensor readout, 3.5× brighter per unit ISO — and pick the
  // ISO that preserves AE's exposure product (prevExp × prevIso), so the
  // picture keeps its brightness instead of jumping to a max-ISO glare.
  const want = LOWLIGHT_EXP > 0 ? LOWLIGHT_EXP : why === 'shutter' ? 3500 / fps : 1000 / fps;
  const expUnits = Math.min(Math.max(want, caps.exposureTime?.min ?? 0), caps.exposureTime?.max ?? 1000);
  let iso = Math.min(2500, caps.iso?.max ?? 2500);
  if (why === 'shutter' && prev?.expUnits > 0 && prev?.iso > 0) {
    const keep = Math.round((prev.expUnits * prev.iso) / expUnits);
    iso = Math.min(iso, Math.max(caps.iso?.min ?? 40, keep));
  }
  await safeAsync(async () => {
    await track.applyConstraints({ exposureMode: 'manual', exposureTime: expUnits, iso });
  }, 'lowlight.exposure');
  return { expUnits: +expUnits.toFixed(1), iso };
}

function lowlightEval(fps, dtMs) {
  if (!LOWLIGHT_ON || !srcProbe || fps == null) return;
  const track = srcProbe.track;
  if (track.readyState !== 'live' || !track.enabled) {
    lowDarkMs = 0;
    lowLightMs = 0;
    return;
  }
  // Zero delivery is the revival path's problem, not an exposure judgement.
  if (fps === 0) {
    lowDarkMs = 0;
    return;
  }
  const lastLuma = lumaWin.length ? lumaWin[lumaWin.length - 1] : null;
  if (!lastLuma || performance.now() - lastLuma.t > 3000) {
    lowDarkMs = 0; // no fresh luma: cannot judge, must not guess
    return;
  }
  if (!lowlightOn) {
    const starving = fps < devTargetFps() * DEV_STEP_LOW_FRAC;
    // Two ways in (task #46). Dark: the image itself says AE is stretching.
    // Shutter: the camera's own reported exposureTime (100-µs units) exceeds
    // the target frame period — the shutter ALONE makes the target fps
    // physically impossible, however bright the picture looks. A lamp-lit
    // room sits at luma ~110 with a 50 ms exposure; the old luma-only gate
    // could never see it (dimRoomDiagnostic, measured in ladder-sim).
    const sett = safe(() => track.getSettings?.(), 'lowlight.settings') ?? {};
    const expUnits = sett.exposureTime > 0 ? sett.exposureTime : null;
    const slowShutter = expUnits != null && expUnits / 10 > 1000 / devTargetFps();
    const dark = lastLuma.y < LOWLIGHT_LUMA;
    lowDarkMs = starving && (dark || slowShutter) ? lowDarkMs + dtMs : 0;
    if (lowDarkMs >= LOWLIGHT_HOLD_MS) {
      lowDarkMs = 0;
      lowlightEnter(track, lastLuma.y, fps, dark ? 'dark' : 'shutter', { expUnits, iso: sett.iso });
    }
  } else {
    const exitAt = lowlightWhy === 'shutter' ? LOWLIGHT_SLOW_EXIT : LOWLIGHT_LUMA_HI;
    lowLightMs = lastLuma.y > exitAt ? lowLightMs + dtMs : 0;
    if (lowLightMs >= LOWLIGHT_HI_MS) {
      lowLightMs = 0;
      lowlightExit(track, lastLuma.y, fps);
    }
  }
}

async function lowlightEnter(track, luma, fpsBefore, why = 'dark', prev = null) {
  // Capability gate: only where manual exposure actually exists. Read off the
  // M13 itself (session 5): exposureMode ['continuous','manual'], exposureTime
  // {min 0.6546, max 1420, step 0.1}, iso {min 40, max 2500}. Those exposure
  // numbers are 100-us units per the warning above `applyLowlightExposure`, so
  // the real range is 0.065-142 ms — NOT 0.65-1420 ms, which is what an earlier
  // version of this comment claimed and which would make the 33 we ask for look
  // like a 33 ms frame-length exposure instead of the 3.3 ms it is.
  // Elsewhere the honest state is the telemetry, not a pretend fix.
  const caps = safe(() => track.getCapabilities?.(), 'lowlight.caps') ?? {};
  if (!caps.exposureMode?.includes?.('manual')) {
    tel?.log('lowlight', { on: 0, luma: +luma.toFixed(1), fpsBefore, why, capable: 0 });
    return;
  }
  lowlightOn = true;
  lowlightWhy = why;
  const ask = currentCaptureAsk();
  // Sequencing rule: stream constraints first, ImageCapture constraints second.
  await safeAsync(() => track.applyConstraints({ frameRate: { ideal: ask.fps } }), 'lowlight.fps');
  const { expUnits, iso } = await applyLowlightExposure(track, why, prev);
  tel?.log('lowlight', { on: 1, luma: +luma.toFixed(1), fpsBefore, why, expUnits, iso });
  clearTimeout(lowlightResultTimer);
  lowlightResultTimer = setTimeout(() => {
    safe(() => {
      const dt = (performance.now() - (srcProbe?.lastT ?? 0)) / 1000;
      const fpsAfter = srcProbe && dt > 0 ? +((srcProbe.frames - srcProbe.lastF) / dt).toFixed(1) : null;
      const lumaAfter = lumaWin.length ? +lumaWin[lumaWin.length - 1].y.toFixed(1) : null;
      tel?.log('lowlight-result', { fpsAfter, luma: lumaAfter });
      // Verify-and-revert: the recipe exists to buy frame rate, so a stalled
      // camera or a blacked-out picture after it is proof it failed on this
      // device (measured on the M13, 2026-08-05: luma 53.5 → 0, then 0 fps →
      // dead camera). Restore AE before the stall-revive chain can kill it.
      if (lowlightOn && (fpsAfter === 0 || (lumaAfter != null && lumaAfter < 3))) {
        tel?.log('lowlight', { on: 0, reverted: 1, fpsAfter, luma: lumaAfter });
        lowlightExit(track, lumaAfter ?? 0, fpsAfter ?? 0);
      }
    }, 'lowlight.result');
  }, 8000);
}

async function lowlightExit(track, luma, fpsBefore) {
  lowlightOn = false;
  lowlightWhy = null;
  clearTimeout(lowlightResultTimer);
  await safeAsync(() => track.applyConstraints({ exposureMode: 'continuous' }), 'lowlight.exit');
  tel?.log('lowlight', { on: 0, luma: +luma.toFixed(1), fpsBefore, restored: 'continuous' });
  // AE needs its settle time before the §5 lock goes back on — the same 2.5 s
  // lockCamera gives it at join. Relocking immediately would freeze whatever
  // mid-transition exposure the AE happened to be holding.
  setTimeout(() => relockCamera(track), 2500);
}

function reviveEval(fps, dtMs) {
  if (!REVIVE_ON || !srcProbe || reviveBusy || fps == null) return;
  const track = srcProbe.track;
  // A user-disabled track (cam OFF) delivers nothing ON PURPOSE — never fight
  // the toggle. Same warmup as the stepper: a slow-starting camera at join is
  // not a stalled one.
  if (track.readyState !== 'live' || !track.enabled || performance.now() - srcProbe.t0 < DEV_STEP_WARMUP_MS) {
    reviveStallMs = 0;
    return;
  }
  if (fps > 0) {
    if (reviveTimes.length) tel?.log('stall-revive', { recovered: 1 });
    reviveTimes = [];
    reviveStallMs = 0;
    return;
  }
  reviveStallMs += dtMs;
  if (reviveStallMs >= REVIVE_STALL_MS) {
    reviveStallMs = 0;
    stallRevive(track);
  }
}

async function stallRevive(track) {
  if (reviveBusy) return;
  reviveBusy = true;
  try {
    const now = performance.now();
    reviveTimes = reviveTimes.filter((t) => now - t < REVIVE_WIN_MS);
    const n = reviveTimes.length + 1;
    if (n > REVIVE_MAX) {
      tel?.log('stall-revive', { n, gaveUp: 1 });
      await reacquireCamera();
      return;
    }
    reviveTimes.push(now);
    // No tier step — re-apply what the camera already has. Session 4 measured
    // exactly this reviving a zero-delivery track on the M13's HAL.
    const c = currentCaptureAsk();
    await safeAsync(
      () =>
        track.applyConstraints({
          width: { ideal: c.w },
          height: { ideal: c.h },
          frameRate: { ideal: c.fps },
          resizeMode: 'none',
        }),
      'revive.apply',
    );
    // If low-light mode owns the exposure, its manual state must ride along —
    // a stream-constraint re-apply can drop it (same sequencing rule).
    if (lowlightOn) await applyLowlightExposure(track);
    tel?.log('stall-revive', { n, asked: c });
  } finally {
    reviveBusy = false;
  }
}

/**
 * Last resort after REVIVE_MAX failed revivals: stop the video track and
 * re-acquire through the same getMedia() join used — preview reuse, tier
 * clamp, capture telemetry all apply again. If the camera won't come back the
 * call continues audio-only, exactly the join-time degraded path.
 */
async function reacquireCamera() {
  await safeAsync(async () => {
    const old = srcProbe?.track ?? localStream?.getVideoTracks()[0];
    if (old) {
      localStream?.removeTrack(old);
      old.stop(); // free the device first — the M13's HAL refuses a second open
    }
    const fresh = await getMedia({ requireVideo: false });
    // getMedia's stream carries a mic we already have — never double-open it.
    for (const t of fresh.getAudioTracks()) t.stop();
    const nv = fresh.getVideoTracks()[0];
    if (!nv) {
      tel?.log('stall-reacquire', { ok: 0, degraded: videoDegraded ?? 'none' });
      return; // audio-only fallback, as-is
    }
    await adoptVideoTrack(nv);
    tel?.log('stall-reacquire', { ok: 1, settings: pick(nv.getSettings(), ['width', 'height', 'frameRate']) });
  }, 'revive.reacquire');
}

/**
 * Put a freshly opened camera track in place of whatever was there: on the
 * wire, on every watcher, and on the ladder's books. Shared by the stall
 * machine's re-acquire and by the user-facing camera flip (§8) — a flipped
 * sensor is a new sensor in exactly the ways that matter here, so it must not
 * inherit the old one's exposure lock, luma history or step-down state.
 */
async function adoptVideoTrack(nv) {
  localStream.addTrack(nv);
  // Lane 2's carrier sender must keep its carrier. That sender does not hold the
  // camera — it holds a 320x180 canvas ticking at 60/s whose only job is to be a
  // clock, because the transform substitutes our own encoded frames for its payload
  // (tape.js §carrier). Replacing it with the camera halves the tick rate to 30/s,
  // and one tick carries one frame, so throughput drops to the 30 x G/(G+1) = 22.5
  // fps ceiling the carrier exists to lift — measured after a flip at 22.3 fps — and
  // libwebrtc starts encoding a full 720p frame per tick that is then thrown away.
  // Every OTHER video sender still takes the new track: that is the plain-RTP path
  // the call falls back to, and it does carry the camera.
  const carrier = safe(() => tapePre?.getCarrierSender?.(), 'tape.carrierSender') ?? null;
  for (const s of pc?.getSenders() ?? []) {
    if (carrier && s === carrier) continue;
    if (s.track?.kind === 'video') await s.replaceTrack(nv).catch(() => {});
  }
  // Everything bound to the old track re-arms on the new one.
  // The custom video lane included: its capture pump reads the camera through a
  // MediaStreamTrackProcessor made once at lane start-up, so without this the
  // flip's `old.stop()` ends the pump and the far end drops to lane P stills for
  // the rest of the call (measured: 29.4 fps -> 0.4 fps, no recovery, no RTP
  // fallback). Must run BEFORE the caller stops the old track.
  safe(() => tape?.adoptTrack?.(nv), 'tape.adoptTrack');
  srcProbe?.reader?.cancel().catch(() => {});
  srcProbe = null;
  startSourceProbe(localStream);
  if (lumaVideo) {
    lumaVideo.srcObject = new MediaStream([nv]);
    safeAsync(() => lumaVideo.play().catch((e) => { if (e?.name !== 'AbortError') throw e; }), 'luma.play.reacquire'); // a re-pointed element is paused again
  }
  lumaBlindTicks = 0;
  lowlightOn = false;
  lowDarkMs = 0;
  lowLightMs = 0;
  reviveTimes = [];
  reviveStallMs = 0;
  devStepTier = resolveDevTier(); // a fresh camera is a fresh measurement, not a step-up
  devStepLowMs = 0;
  camLocked = false;
  // The new sensor powers up in full auto and WILL hunt — tell 9 applies to the
  // rear camera exactly as it does to the front, and skipping this is how a
  // flip turns into the darkening bug all over again.
  if (QS.get('nolock') !== '1') lockCamera(localStream); // not awaited — same as join
}

// ── What to ask Opus for ─────────────────────────────────────────────────────
// The app shipped Chrome's Opus default, which is roughly 32 kbps mono. That is a perfectly
// ordinary video call and it is not what §1 promises: audio meant to feel like a recording is
// a waveform-fidelity goal, and 32 kbps is not close. It also went unnoticed because nothing
// sampled outbound audio — the fix and the instrument landed together.
//
// Measured on the real conversation speech (task #8) with libopus, segmental SNR against the
// reference, at 20 ms frames:
//
//   mode \ rate    32 kbps   64 kbps   128 kbps
//   voip            2.85      3.92       5.50   dB   <- what libwebrtc uses for mono
//   audio           7.79     10.81      15.81   dB
//
// Two things follow. Bitrate helps monotonically and 128 kbps costs about 1% of the video
// budget, so there is no reason to be stingy. And the *mode* matters more than the rate:
// `audio` at 32 kbps beats `voip` at 128. The caveat that keeps that honest is that `voip`
// mode is parametric — SILK deliberately discards waveform to preserve speech features, so
// segSNR understates it for intelligibility. For "lossless" it is measuring the right thing.
//
// There is no SDP parameter for Opus's application mode, but libwebrtc derives it from the
// channel count, so `stereo=1` is the lever that reaches it. That is a reading of libwebrtc's
// internals rather than a measurement, which is why it is a flag with a measured default
// rather than a hardcoded choice — see §17.3.
const A_KBPS = Number(QS.get('abr')) || 128;
// #21 measured: a NO-OP at 128 kbps — far-end spectra identical with and without
// (Δ ≤ 0.4 dB per band, 0–20 kHz, opus7 arms, §17.3). Kept only as the control arm.
const A_STEREO = QS.get('astereo') === '1';
const A_FEC = QS.get('afec') !== '0';
// Opus packetises at 20 ms by default; 10 ms removes half of that from one-way delay at the
// cost of doubling packet rate. A real §14 lever, off until it is measured against loss.
const A_PTIME = Number(QS.get('aptime')) || 0;
// Receiver jitter-buffer target in ms. Empty string (`?jbt=`) leaves Chrome alone entirely,
// which is the arm the default was measured against. See the receiver loop.
const JBT = QS.has('jbt') ? (QS.get('jbt') === '' ? null : Number(QS.get('jbt'))) : 0;

// ── The custom video lane (tape.js) ──────────────────────────────────────────
// `?tape=1` moves video off RTP onto a fixed-quantizer WebCodecs pipeline over
// datachannels — measured 1.5 ms of pipeline on a clean path and condemned under loss
// by SCTP's own congestion control (§17.6). `?tape=2` keeps the same encoder and swaps
// the pipe: payload substitution over a real RTP sender, keeping GCC/NACK underneath.
// DEFAULT ON (lane 2) as of 2026-08-02, user directive: "they should be on by default
// and no option to change". It had been default-OFF since it was built, which meant every
// number this project has ever quoted for the custom lane — fixed QP 24, the FEC, the
// governor, ~75 ms glass-to-glass — described a query string no user ever typed. A real
// visitor to room.tokkah.com was getting stock WebRTC. Measured on the live site before
// the flip: `lane: null`, H.264 1080p30, Opus 128 kbps.
//
// Safe to default because failure is handled: `onFail` → `fallbackToRtp()` puts the call
// back on the stock path rather than dropping it, and the weak-device ladder (#37) still
// governs capture. `?tape=0` remains the control arm — it is a measurement override, not
// a user-facing setting, and nothing in the UI exposes it.
//
// QP 24 is a starting point, not a result. The whole question fixed-QP raises is what a
// given quality costs on the wire, and that is a sweep to be run, not a constant to be
// asserted — see `tape.snapshot().mbpsAtFps`.
// REVERTED TO 0 on 2026-08-02, minutes after the flip above, because it broke a real
// call on production: Brave <-> Safari, both ends black for the whole call. The flip
// assumed the lane's own support check was enough, and it is not — `tapeRtpSupported()`
// answers "can THIS browser run the lane", never "can the PEER". A Chromium end that
// passes its own check builds the carrier (a 1x1 flicker canvas whose RTP payload the
// transform overwrites) and sends its real picture inside it; a Safari end that fails
// the check has no transform, so it renders the carrier literally — one black pixel —
// and sends ordinary video back into a `#remote` that the Chromium end has already
// pointed at its lane canvas. Black in both directions, no error on either side.
//
// BACK TO 2 on 2026-08-02, once the condition that sentence set was actually met:
// the two ends now agree over signalling before the first offer. Each declares what
// it can run on the ws upgrade URL (`?lane=`), the room hands each the other's answer
// (`peerLane` on welcome / peer-joined), and `laneAgree` steps a lone lane end down to
// stock RTP before any SDP is built. `armLaneWatchdog` covers agreed-but-broken — both
// ends said yes and nothing decoded — because that also renders as a black rectangle
// with no error.
//
// Verified on production against a REAL non-Chromium engine, not a simulation of one:
// WebKit 26.5 <-> Chromium, both join orders, gated on luma variance rather than
// connection state (the bug rendered a perfectly valid picture that happened to be one
// black pixel, and every counter read healthy). Both ends showed sd ~62. WebKit lacks
// MediaStreamTrackProcessor, so `tapeSupported()` is false there — the same answer
// Safari 27 gave in a real room log — which makes it a faithful stand-in for the one
// thing Safari has to do here: say "lane 0". All the logic under test is on the
// Chromium side, and that is the side both orders exercised.
// Parenthesised deliberately: `Number('0') || 2` is 2, so the obvious spelling would
// make `?tape=0` mean "lane 2" and quietly turn every mismatch test into a no-op.
const TAPE = QS.has('tape') ? (Number(QS.get('tape')) || 0) : 2; // 0 = stock RTP, 1 = datachannel lane, 2 = RTP-transform lane
const TAPE_CFG = {
  qp: Number(QS.get('qp')) || 24,
  codec: QS.get('tcodec') || 'avc1.640028',
  width: WANT_W,
  height: WANT_H,
  // A STARTING VALUE, not the rate. `syncTapeFps()` overwrites this from `targetFps()`
  // before the lane starts and again whenever the peer's refresh rate arrives — this
  // object is built at module load, when neither the camera nor the peer is known yet.
  // It was a hardcoded 30 until 2026-08-03, which meant the GOOD lane (the one that
  // measures VMAF 99.7) encoded at 30 fps no matter what the display could show; the
  // Hz-matching work reached only the plain-RTP fallback's `maxFramerate`.
  fps: 30,
  // Zero retransmits makes the media channel a pure datagram lane. A retransmitted
  // delta frame arrives after the frame it belonged to was due, so it costs bandwidth
  // during congestion to deliver something already stale. Whether keyframes deserve
  // different treatment is the open question this dial exists to answer.
  maxRetransmits: Number(QS.get('trtx')) || 0,
  // Skip capture once SCTP is holding more than this. A floor, not the whole rule —
  // tape.js scales it against recent frame size, because a threshold below one keyframe
  // trips on the frame it just admitted (measured: 93% of captures skipped on a link
  // with no ceiling).
  queueBytes: Number(QS.get('tq')) || 196608,
  maxEncQueue: Number(QS.get('teq')) || 4,
  // Capture-admission depth: how many encoded frames may be awaiting the carrier's
  // pickup confirmation before we skip at capture. 5, not 3: 3 broke the
  // phase-lock at equal camera/carrier rates (admit/skip alternation, measured
  // exactly 50% on B), 5 keeps one frame encoding while others wait (v15 sweep).
  maxInFlight: Number(QS.get('tif')) || 5,
  keyMs: Number(QS.get('tkey')) || 5000,
  // How long to hold a partial frame before declaring it lost, *plus* the measured RTT.
  // 100 KB on an 8 Mbps link is 100 ms of pure serialization, so a flat 120 ms declared
  // keyframes lost while their own fragments were still arriving.
  reassembleMs: Number(QS.get('tasm')) || 250,
  // Minimum spacing between keyframe requests, plus RTT. See tape.js: too short and a
  // loss burst turns into a keyframe storm that makes the loss worse.
  keyReqMs: Number(QS.get('tkreq')) || 400,
  // XOR parity group size: one redundant fragment per N data fragments. 10 -> 10%
  // overhead, repairs any single loss per group with no round trip. Keyframes get a
  // tighter group because losing one costs every frame until the next.
  // `?fec=0` disables, which is the arm the FEC numbers are measured against.
  fecGroup: QS.has('fec') ? Number(QS.get('fec')) : 10,
  fecGroupKey: QS.has('fkey') ? Number(QS.get('fkey')) : 5,
  // Lane-2 FEC: one XOR-parity carrier frame per group of N substituted carrier
  // frames (tape.js, worker-side). At 1% packet loss a ~45-packet frame is lost
  // ~36% of the time, so N trades overhead against single-loss repair: 3 = 33%
  // overhead, ~20% residual frame loss; 2 = 50% overhead, ~15% residual.
  // `?l2fec=0` disables, which is the arm the lane-2 FEC numbers are measured
  // against. Keys are protected by duplication instead (l2FecKey >= 1): a
  // keyframe is 60-84% likely to lose a packet and costs every frame until the
  // next one, and a second copy is ~0.24 Mbps at keyMs=5000.
  l2FecGroup: QS.has('l2fec') ? Number(QS.get('l2fec')) : 3,
  l2FecKey: QS.has('l2fkey') ? Number(QS.get('l2fkey')) : 1,
  // How long the receiver holds frames past a gap waiting for parity before
  // falling back to a keyframe request. Must exceed one group window (N/30 s)
  // plus jitter; 250 ms covers G=3 at 30 fps with ~2x margin.
  l2FecHoldMs: Number(QS.get('l2hold')) || 250,
  // Second line of defense after parity (#23): on a gap the receiver asks the
  // sender to re-splice the missing frames from a retention ring — heals a
  // doubly-struck group (data + its parity lost together) in ~1 RTT, inside
  // the hold window, so the cascade (hold expiry → mass gap → keyframe) never
  // starts. Measured hole before this: 11-14 frames lost per run per unlucky
  // direction at 1% loss (fec-loss-rerun1/2). `?l2retx=0` is the control arm.
  l2Retx: QS.get('l2retx') !== '0',
  // How long parity gets to heal a gap before a fragreq is spent on it. Must
  // exceed one group window at the running admission rate (G/30 s ≈ 100 ms at
  // full rate) or every single loss draws a redundant re-splice (measured).
  l2RetxWaitMs: Number(QS.get('l2retxwait')) || 120,
  // Pacer-following admission (AIMD on receiver-reported capture→decode age).
  // The inFlight gate throttles to the carrier's TICK rate (30 fps), not the
  // pacer's DRAIN rate; the difference accumulates inside Chrome's pacer queue,
  // invisible locally — measured 1.44-1.6 s of queue age and a contiguous
  // sender-side startup hole at the queue's drop ceiling. The receiver's frame
  // age is the only signal that sees the backlog, so it reports it over ctl and
  // the sender paces capture admission to it. `?l2pace=0` is the control arm.
  l2Pace: QS.get('l2pace') !== '0',
  l2PaceStart: Number(QS.get('l2pstart')) || 5, // frames/s before the first report
  l2PaceAi: Number(QS.get('l2pai')) || 3, // additive increase, frames/s per 1 s tick
  // ---- Rate control (#44). Read the measurement before changing any of these.
  //
  // Fixed QP means constant quality, and constant quality means the bitrate is
  // whatever the picture demands. Measured on this lane at QP 24, 1080p30,
  // loopback, pacer disabled so nothing rationed the encoder:
  //
  //     static test pattern   50 KB/frame    20.3 Mbps on the wire
  //     real motion          283 KB/frame   115.5 Mbps on the wire
  //
  // 5.7x, from the content alone. No consumer uplink carries 115 Mbps, so during
  // motion the demand simply cannot be met — and until now the ONLY actuator
  // downstream of the encoder was the AIMD pacer, which pays for overshoot in
  // frames per second. That is the whole of "high motion feels like the frame
  // rate is low": it was not a bug in the pacer, it was the pacer correctly
  // rationing an encoder that had no rate target at all.
  //
  // So give it one. QP is settable per `encode()` call (no reconfigure), so the
  // controller below trades sharpness for continuity, which is the right trade
  // during motion in both directions: fast movement is where the eye can least
  // resolve detail, and where dropped frames are most obvious. Frame rate
  // becomes the last thing to give, not the first.
  l2Rc: QS.get('l2rc') !== '0',
  // Budget in Mbps. Seeded from the carrier's own GCC estimate when getStats
  // offers one — Chrome has already probed this path, so that is a measurement
  // rather than a guess — and clamped into this band. The ceiling is not a
  // quality cap: it is the point past which more bits buy nothing a viewer can
  // see on a 1:1 call, and beyond which we are just building queue.
  l2RcMinMbps: Number(QS.get('l2rcmin')) || 0.6,
  l2RcMaxMbps: Number(QS.get('l2rcmax')) || 8,
  // QP band. 24 stays the floor, so nothing gets WORSE than today's picture on a
  // link that can afford today's bitrate; 42 is the ceiling, soft but never
  // blocky at 1080p, and reached only when the alternative is a slideshow.
  l2RcQpMin: Number(QS.get('l2rcqpmin')) || 24,
  l2RcQpMax: Number(QS.get('l2rcqpmax')) || 42,
  // #14: paint decoded frames straight onto a <canvas> instead of feeding a
  // MediaStreamTrackGenerator into <video>. Measured (cap2 vs cap3): the
  // element is an uncontrollable adaptive jitter buffer — 280 ms clean,
  // 740-875 ms under 1% loss (it reads our FEC-hold delivery as jitter and
  // grows) — while the canvas presents in 0.3-0.4 ms at both loss levels.
  // DEFAULT ON since cap3; `?l2canvas=0` is the control arm.
  l2Canvas: QS.get('l2canvas') !== '0',
  // ?ctick=0 reverts the carrier to setInterval(16) + captureStream(60), which measured
  // 59.7 ticks/s and therefore capped the lane at ~45 fps. The control arm for the
  // carrier-tick A/B; see the measurement table in tape.js at the carrier canvas.
  l2FastCarrier: QS.get('ctick') !== '0',
  // ?l2rcmode=vbr forces the VBR rate-control arm even where fixed QP is available, so the
  // arm every Safari-family call actually runs can be scored with VMAF against the real
  // fixture. Unset means 'use fixed QP if the engine has it', which is the shipping path.
  l2RcMode: QS.get('l2rcmode') || null,
  // The VBR arm's target bitrate. Exposed so the arm can be measured at a bitrate MATCHED
  // to what the fixed-QP arm actually delivers: comparing VBR-at-12-Mbps against
  // QP24-at-6.4-Mbps would score rate control and rate together and settle neither.
  l2VbrBps: Number(QS.get('l2vbrbps')) || 0,
  // ?l2vbradmit=0 — control arm for the VBR admit-share coupling (room
  // uol-jdmh-omn, 2026-08-07): on the VBR arm the encoder bitrate follows the
  // pacer's admitted share so per-frame size cannot balloon when the link is
  // scarce. 0 reverts to the fixed full-budget target.
  l2VbrAdmit: QS.get('l2vbradmit') !== '0',
  // Task #48 A/B knob: WebCodecs hardwareAcceleration preference for the lane-2
  // encoder/decoder. Unset means the browser decides (the shipping default,
  // logged as `hw` in tape-encoder telemetry). `?l2hw=hw` asks for the
  // dedicated silicon, `?l2hw=sw` forces software — the arm exists to measure
  // energy per call-minute, not to be guessed at.
  l2Hw: { hw: 'prefer-hardware', sw: 'prefer-software' }[QS.get('l2hw')] ?? null,
  // #33: cadence-locked presentation for the default (non-avsync) canvas path.
  // §17.8 removed the element's adaptive jitter buffer; the measured cost was
  // arrival jitter on screen (remote IPI bimodal ~31/62 ms, on-cadence ~56%,
  // p99 1.6–2.3× the self-view's 33.3 ms metronome). The v-presenter puts back
  // a BOUNDED schedule: 3-slot queue on the sender's capture-timestamp grid,
  // constant disclosed D = 2 frame intervals, under-run holds the previous
  // frame one interval, over-run closes+counts the oldest, healed holes
  // re-anchor the metronome — never adaptive, never growing. DEFAULT ON;
  // `?vprev=0` restores §17.8's paint-on-arrival exactly (the control arm).
  vprev: QS.get('vprev') !== '0',
  // Lane 2 carrier: resolution divisor sets the wasted CPU, maxBitrate sets GCC's
  // pacing budget. The carrier's bytes are a clock, not a payload (tape.js).
  // The pacer's budget, not a spend target: it must comfortably exceed what the QP
  // actually costs (~12 Mbps at QP 24) or the pacer queue can never drain a backlog —
  // measured as a permanent 2 s frame age when budget ≈ spend.
  carrierKbps: Number(QS.get('tck')) || 24000,
  // Floor for the carrier's target bitrate (x-google-min-bitrate): keeps the pacer's
  // drain rate above the tape lane's spend from frame one, no GCC ramp wait. Must be
  // >= the QP24 spend (~12 Mbps): at 6000, v14 measured a 1.4 s pacer queue built in
  // the first 8 s of ramp that took 20 s to drain, plus all 21 of the run's losses.
  carrierMinKbps: Number(QS.get('tcm')) || 14000,
  // Diagnostic: skip tape.js's own setCodecPreferences (a second call after the app's)
  // and rely on ?codec=vp8 selecting the carrier instead.
  skipCodecPrefs: QS.get('tscp') === '1',
  // ── §12–13 stall machine (lane 2 only; set live after PCM_CFG below) ──────
  // The regime classifier runs receiver-side on per-delivered-frame age — the
  // law-10 signal, fresher than any ctl report. The SENDER sheds on the peer's
  // LANE_SHED (rule 1); resume discards the queue and cuts to a fresh keyframe
  // (rule 2). Lane P (crisp JPEG stills, own reliable 'tape-lanep' channel)
  // keeps presence while held and doubles as the resume capacity probe.
  // Default ON under ?pcmaudio=1 (the machine's audio-side inputs and its
  // whole reason to exist — audio headroom — presume the PCM lane); `?stall=0`
  // kills it and the wire stays byte-identical to before it existed.
  stall: false, // set to STALL once PCM_CFG exists
  stallShedAgeMs: Number(QS.get('stallage')) || 400, // the AIMD halving bound: above it a backlog exists
  stallShedDwellMs: Number(QS.get('stalldwell')) || 3000, // sustained-C<R proof: this long at the floor
  stallShedFps: Number(QS.get('stallfps')) || 3, // delivery at/below the governor's floor
  stallResumeCleanMs: 2000, // §13: "2 s clean" of lane-P probe before LANE_RESUME
  stallMinHoldMs: Number(QS.get('stallminhold')) || 4000, // no flapping: shortest VIDEO HELD dwell
  stallMaxHoldMs: 60000, // escape hatch: one resume probe per this while held
  // SENDER-side dead-man: longest we stay shed on the peer's say-so with no
  // resume. A shed answers congestion, which is transient; past this it is a
  // fault, and an uplink that is off with nobody watching is a dead call.
  stallShedMaxMs: Number(QS.get('stallshedmax')) || 8000,
  lpFps: Number(QS.get('lpfps')) || 1, // §4: crisp stills, ~1 fps
  lpWidth: Number(QS.get('lpw')) || 960, // still width (height keeps the camera's aspect)
  lpQ: QS.has('lpq') ? Number(QS.get('lpq')) : 0.85, // JPEG quality — §4 says 0.9; 0.85 ≈ halves the bytes
  stallForceAt: Number(QS.get('stallforce')) || 0, // test hook: force one shed N s after arm
};
let tape = null;
let tapePre = null; // lane 2 phase A handle: worker + attached sender transform
let wantTape = 0; // 0 off, 1 datachannel lane, 2 RTP-transform lane
let tapeFellBack = false;
let rtpStream = null;
let rtpVideoTrack = null; // lane 2: the carrier's decoded track, held for fallback

// ── Lane A: lossless PCM audio (pcm.js) ──────────────────────────────────────
// `?pcmaudio=1` takes the mic OFF the peer connection entirely — no Opus, no
// RTP audio, no NetEq, no <audio> element: 48 kHz/24-bit linear PCM in 8 ms
// frames, one unreliable/unordered datagram each (125 pps, ~1.5 Mbps), RS(10,13)
// FEC, worklet+SharedArrayBuffer playout (DESIGN.md §4/§9/§10). The decision is
// made HERE, at page load, before addTrack — so no renegotiation can ever
// involve the mic (same law as lane-1 video). Both video lanes keep working
// with it; with the flag off nothing in this block runs at all.
// ON by default as of 2026-08-02, with `?pcmaudio=0` as the escape hatch. Three
// things had to be true first, and now are: the two ends negotiate the lane
// through the room (`pcmAgree`) instead of each checking only itself; a failure
// recovers onto a negotiated hot-spare Opus sender with no renegotiation; and the
// striped configuration actually carries the lane on a real link.
//
// That last one is why `pairs` moved to 3. Measured on production at RTT 80 ms /
// 1% loss: at pairs=1 the lane delivered 63% of frames, concealed 29.2 s of a 45 s
// call, and inflated RTT to 250-307 ms — SCTP's AIMD ceiling is ~1.5 Mbps per
// ASSOCIATION at that shape and the lane needs ~1.8. At pairs=3 the same link gave
// 99.3% delivery, 0 sender drops, 4.4% concealed, age p50 40.5 ms, and no RTT
// inflation at all. Join got no slower (1465 ms vs 1794 for the video lane alone).
const PCM_AUDIO = QS.get('pcmaudio') !== '0';
// Interpreter (TRANSLATE-SPEC.md). One button, no setup: the speaker's
// language is auto-detected server-side per phrase; each listener hears
// translations in their own browser language. `?xlate=<lang>` overrides the
// listening language (the rig uses it) and auto-starts at welcome.
const XLATE_LANG = QS.get('xlate') || null;
const xlateListenLang = () => XLATE_LANG || (navigator.language || 'en');
let xlateApi = null;    // { stop } once running
let xlateBusy = false;  // guards the async import against double-click
const xlateBtn = () => document.getElementById('xlate');
async function xlateStart(fromPeer) {
  if (xlateApi || xlateBusy || !role || !localStream) return;
  xlateBusy = true;
  try {
    const x = await import('./xlate.js');
    xlateApi = await x.start({ stream: localStream, room: activeRoom, role, lang: xlateListenLang(), tel });
    xlateBtn()?.setAttribute('data-off', '0');
    tel.log('xlate-start', { fromPeer: fromPeer ? 1 : 0, lang: xlateListenLang() });
    // One click turns the interpreter on for the CALL, not for one side — a
    // translator that only one person has is half a translator.
    if (!fromPeer) send({ type: 'xlate-on' });
  } catch (e) {
    tel.log('xlate-load-err', { e: String(e) });
  } finally {
    xlateBusy = false;
  }
}
function xlateStop(fromPeer) {
  if (!xlateApi) return;
  try { xlateApi.stop(); } catch { /* partial */ }
  xlateApi = null;
  xlateBtn()?.setAttribute('data-off', '1');
  tel.log('xlate-stop', { fromPeer: fromPeer ? 1 : 0 });
  if (!fromPeer) send({ type: 'xlate-off' });
}
const PCM_CFG = {
  fec: QS.get('pcmfec') !== '0', // RS(10,13); `?pcmfec=0` is the control arm
  targetFrames: Number(QS.get('pcmjb')) || 2, // starting jitter target, 16 ms
  // D_max for audio. 15 frames = 120 ms, and it is a HAND-SET constant, not a
  // measured one -- on a bandwidth-constrained link the estimator asked for
  // 23-41 frames and was capped here without saying so. `?pcmjbmax=` makes
  // the ceiling A/B-able against the concealment it is causing.
  maxTargetFrames: Number(QS.get('pcmjbmax')) || 15,
  driftPpm: Number(QS.get('pcmdrift')) || 2000, // §10's ±0.2% resample bound
  // Backpressure is spent as a gap, never as queue: ~5 frames (~40 ms) of
  // bufferedAmount and a capture is dropped for the concealer to cover.
  queueBytes: Number(QS.get('pcmq')) || 6144,
  // §17.12's lever: stripe Lane A's exact byte stream round-robin across N
  // data-channel-only peer connections (SCTP's AIMD ceiling is per
  // ASSOCIATION — cwnd is — so N associations carry N ceilings). 1 = today's
  // exact behaviour: no extra pcs, the single 'pcm-audio' channel on the main
  // pc. Both sides must pass the same N (flag asymmetry is unsupported, same
  // as pcmaudio).
  //
  // 6, not 3, as of 2026-08-03. 3 was chosen at 1% loss, where it measured
  // 98.2% delivery; at 5% loss it is a different question, because a Reno-like
  // window carries only MSS×1.22/(RTT×√p) — ~0.67 Mbps at MSS 1234 / RTT 80 /
  // p=0.05 — and the lane offers 1.5 Mbps + 30% FEC ≈ 0.65 Mbps per stripe at
  // N=3. Sitting exactly on the ceiling, it queued without bound: measured
  // concealment 27% at 5% loss and 60–76% at 10%, where at 10% the sender
  // could not even drain itself (framesSent 8143 of 10327 captured). At N=6
  // those are 2.7–3.1% and 4.1–9.6%. The clean path is 0.0% concealed at both
  // and the video latency difference was not resolvable (62.2±2.1 vs 64.3±1.2
  // ms, t=1.80, n=4 interleaved). No clean-path cost is measurable: a first
  // reading of jitter depth 12.9 → 17.8 ms did not replicate (12.3/12.2 at
  // N=6 on the shipped default), so it was run noise.
  pairs: Math.max(1, Math.min(8, Number(QS.get('pcmpairs')) || 6)),
  // Lane 0 (§3.1 levers 3+4, §4): with this false the predictor is never
  // constructed, no T_PRED/T_PAD byte ever exists on the wire, and Lane B is
  // never yielded — behaviour byte-identical to before Lane 0 existed.
  lane0: PCM_AUDIO && QS.get('lane0') !== '0',
  // Compact framing: 5 B data / 8 B parity headers so a frame is 1157 B and a
  // parity 1160 B — both inside the measured 1160 B single-datagram budget,
  // where the old 1176 B cost ~2.4 datagrams and turned 5.6% link loss into
  // 13.4% frame loss. `?pcmc=0` restores the 24 B header as the control arm;
  // the receiver reads both either way.
  compact: QS.get('pcmc') !== '0',
  // Lossless frame compression (core/pcmpack.js): fixed-order linear prediction
  // plus partitioned Rice, measured 0.56 of raw on speech and bit-exact on
  // 6,851 adversarial and real frames. The target is the lane's RATE, not its
  // byte count — the SCTP window is per association and carries ~0.4 Mbps at
  // 5% loss, so cutting 1.95 Mbps of offered load is worth more than cutting
  // any single frame. `?pcmz=0` is the control arm.
  zip: QS.get('pcmz') !== '0',
  // Control arm for the group-sized RS symbol: pins it back to a fixed 1152 B.
  rsFixed: QS.get('pcmrsfixed') === '1',
  // Jitter target from measured arrival spread. `?pcmjit=0` restores the old
  // pain-counter law as the control arm — see the block above bumpTarget() in
  // pcm.js for what that law measured and why it was wrong.
  jitterMeasured: QS.get('pcmjit') !== '0',
  // Peak-hold on the measured spread, so a burst is not forgotten the moment
  // the 2.56 s window rolls past it. `?pcmjithold=0` is the control arm.
  jitterHold: QS.get('pcmjithold') !== '0',
  // Ladder tracks unplayable frames (loss + lateness) instead of loss alone.
  fecLate: QS.get('pcmfeclate') === '1',
  // ms of hold released per 250 ms tick. 2 = 8 ms/s.
  jitterRelease: Number(QS.get('pcmjitrel')) || undefined,
  // Latency governor (task #47): trims buffer depth the measured per-frame
  // slack proves the call never needed. STAYS OPT-IN — the gates ran and were
  // NOT met (2026-08-05, all on real shipping browsers): under injected
  // stalls (Brave x Brave, 70/120 ms) it correctly never trims; in natural
  // Safari x Brave calls the ~1.2% background concealment floors its 20 s
  // safety window every time, so it never trims there either; and in clean
  // calls (paired n=8) it DOES engage (19-161 trim ticks/run) but buys only
  // -0.6 ms last-third / -3.1 ms whole-call, far under the -5 ms ship gate —
  // because the estimator's fast release (jitterRelease=2, shipped) already
  // drains what this law was built to drain. Conceal parity held everywhere,
  // so `?pcmgov=1` is safe insurance for future regimes, not a win today.
  jitterGov: QS.get('pcmgov') === '1',
  // Strip the trailing zero bits a 16-bit capture chain leaves in the int24
  // container — half the audio lane on every device measured. Encoder only; the
  // decoder always honours the header, so `?pcmwaste=0` is a safe control arm
  // that still interoperates with a peer running the default.
  wastedBits: QS.get('pcmwaste') !== '0',
  // Adaptive RS code rate, driven by the loss the PEER reports (T_LOSS).
  // `?pcmfecadapt=0` is the control arm: the old fixed RS(10,13) on every link.
  // `?pcmfecmax=N` caps the ladder (0..3) — mainly to pin a rung for a probe.
  fecAdapt: QS.get('pcmfecadapt') !== '0',
  fecNMax: QS.get('pcmfecmax') != null ? Number(QS.get('pcmfecmax')) : undefined,
  // `?pcmfecmin=N` floors the ladder. n=0 is cheapest but is the only rung with
  // a reaction time; n=1 repairs isolated loss instantly for 10% redundancy.
  fecNMin: QS.get('pcmfecmin') != null ? Number(QS.get('pcmfecmin')) : undefined,
  // `?pcmrsk=` shortens the RS group, which is a LATENCY knob: parity cannot
  // exist until the group closes, so position 0 waits RS_K x 8 ms for a repair
  // that may then miss the playhead. Measured at K=10: 67% of position-0
  // repairs arrived too late, 0% at position 9. MUST match on both peers.
  rsK: QS.get('pcmrsk') != null ? Number(QS.get('pcmrsk')) : undefined,
  // Sliding-window FEC (core/pcmsw.js, task #16) — THE DEFAULT since the
  // paired A/Bs of 2026-08-04: 8/8 at 5% loss (concealment 5x lower AND e2e
  // −44 ms) and 6 wins/1 tie/0 losses under 0.7-0.8 Mbps scarcity. SENDER-side
  // switch: this side emits T_PAR_SW instead of RS parity; every receiver
  // decodes both unconditionally, so `?pcmsw=0` (the block-RS control arm)
  // still interoperates and one call can carry one arm per direction.
  pcmSw: QS.get('pcmsw') !== '0',
  pcmDiag: QS.get('pcmdiag') === '1',
  pcmCapSab: QS.get('pcmcap') !== '0',
  pcmPump: QS.get('pcmpump') ?? 'timer',
  // Pins the stride (data frames per parity; 0 = parity off). Unset = adaptive,
  // driven off the same T_LOSS ladder as fecN.
  pcmSwStride: QS.get('pcmswstride') != null ? Number(QS.get('pcmswstride')) : undefined,
};
let pcm = null;
let pcmPcs = []; // stripe pcs for associations 1..N-1 (association 0 rides the main pc)
let pcmIceServers = []; // the join-time /api/ice config, stashed by the welcome handler
// Lane A's safety net. The mic is added to the pc even under ?pcmaudio=1 and then
// immediately nulled: an audio m-line that is negotiated, costs nothing (measured
// 0 bytesSent over 3 s), and revives with one replaceTrack — no renegotiation, no
// glare, signalingState never leaves stable. Before this, a lane A failure was a
// call with no sound at all and no way back, because the mic was never on the pc.
let pcmSpareSender = null;
let pcmFellBack = false;
let pcmFellBackWhy = null;
let pcmWatchdog = null;

// ── §12–13 stall machine: the HOLD state and the honest UI ──────────────────
// The video half (regime classify → LANE_SHED → VIDEO HELD → lane P → resume
// cut) lives in tape.js, where the per-frame signal is. What lives HERE is the
// one state tape.js cannot see: HOLD — C < R_audio, "cannot carry even audio"
// (§12). Its input is the PCM lane's own concealment stream, polled off
// pcm.snapshot() (pcm.js is another workstream's file — nothing in it
// changes). HOLD does NOT shed our video: the collapse it sees is on the
// RECEIVE direction, and the peer's video classifier is already the correct
// sender-side actor for the reverse direction (rule 1). HOLD is what §13
// says it is: an explicit paused state with an honest UI.
const STALL = PCM_AUDIO && QS.get('stall') !== '0';
TAPE_CFG.stall = STALL;
const HOLD_ENTER_FRAC = 0.25; // concealed fraction of wall time: audio is not being carried
const HOLD_EXIT_FRAC = 0.05; // back to carried
const stallHoldWin = []; // { t, concealedMs } samples, ~8 s sliding
let audioHold = false;
let videoHeld = false; // the remote video is held (tape.js onStall)

function stallUi() {
  if (!STALL) return;
  let el = document.getElementById('stallBadge');
  if (!el) {
    el = document.createElement('div');
    el.id = 'stallBadge';
    el.className = 'mono';
    // Same glass recipe as every other floating surface (task #38 §A.1) — an
    // honest state badge should look like it belongs to the app that is telling
    // the truth, not like a debug overlay someone forgot to remove.
    el.style.cssText =
      'position:absolute;top:44px;left:50%;transform:translateX(-50%);' +
      'padding:6px 14px;background:var(--glass-bg);border:1px solid var(--glass-line);' +
      '-webkit-backdrop-filter:var(--glass-blur);backdrop-filter:var(--glass-blur);' +
      'border-radius:999px;font-size:12px;color:#fff;display:none;z-index:6';
    document.getElementById('call')?.appendChild(el);
  }
  if (audioHold) {
    el.textContent = 'connection paused — reconnecting';
    el.style.display = 'block';
  } else if (videoHeld) {
    el.textContent = 'holding · audio live';
    el.style.display = 'block';
  } else {
    el.style.display = 'none';
  }
  // §15: the WORDS were here, the treatment was not. Desaturation is what makes
  // a held frame read as intentional rather than broken, and the hairline says
  // the app is still trying. CSS owns both; this only names the state.
  const call = document.getElementById('call');
  call?.classList.toggle('paused', !!audioHold);
  call?.classList.toggle('held', !audioHold && !!videoHeld);
}

// ── Elapsed time (§15: "Elapsed time, small, top center") ────────────────────
// Deliberately understated, and deliberately NOT hidden with the control bar:
// the one thing you should be able to check without summoning chrome over
// someone's face is how long you have been talking.
let elapsedTimer = null;
let callStartedAt = 0;
function startElapsed() {
  // Counts the CONVERSATION, not the tab. It starts when the other person
  // arrives and it does not reset if they drop and come back — one call.
  callStartedAt ||= Date.now();
  if (elapsedTimer) return;
  const el = document.getElementById('elapsed');
  if (!el) return;
  const tick = () => {
    const s = Math.floor((Date.now() - callStartedAt) / 1000);
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    // h:mm:ss past the hour, m:ss before it — a leading "0:" on an hour-long
    // call is noise, and a zero-padded minute before ten minutes is worse.
    el.textContent = h ? `${h}:${String(m).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}` : `${m}:${String(s % 60).padStart(2, '0')}`;
    el.classList.remove('gone');
  };
  tick();
  elapsedTimer = setInterval(tick, 1000);
}
function stopElapsed() {
  clearInterval(elapsedTimer);
  elapsedTimer = null;
  document.getElementById('elapsed')?.classList.add('gone');
}

function stallPcmSample() {
  if (!STALL || !pcm) return;
  const s = safe(() => pcm.snapshot(), 'stall.pcm-snap');
  if (!s?.started) return;
  const t = performance.now();
  stallHoldWin.push({ t, c: s.concealedMs });
  while (stallHoldWin.length > 1 && t - stallHoldWin[0].t > 8000) stallHoldWin.shift();
  const w = stallHoldWin;
  if (w.length < 3) return; // need a real window before judging
  const frac = (w[w.length - 1].c - w[0].c) / (w[w.length - 1].t - w[0].t);
  if (!audioHold && frac > HOLD_ENTER_FRAC) {
    audioHold = true;
    tel?.log('stall-hold', { enter: 1, frac: +frac.toFixed(3) });
  } else if (audioHold && frac < HOLD_EXIT_FRAC) {
    audioHold = false;
    tel?.log('stall-hold', { enter: 0, frac: +frac.toFixed(3) });
  }
  stallUi();
}

// ── Lane 0 (DESIGN.md §3.1 levers 3+4, §4) ───────────────────────────────────
// Two cooperating features, both metadata used to SCHEDULE the network — never
// mixed into media, never shown to the user (invariant 4):
//
//   Lever 3 — onset preemption. A LOCAL voice/breath onset yields Lane B for
//   ~40 ms so the onset's first PCM frames meet an empty pipe. One yield per
//   onset, duration hard-capped (tape.js clamps), every window counted.
//
//   Lever 4 — turn-end predictive pre-warm. core/turnend.js runs on OUR mic in
//   the capture worklet (zero latency). On a fall-in-progress detection the
//   peer gets a duplicated T_PRED pair; the RECEIVER spends the ~290–400 ms
//   window padding all N pcm-audio associations (~25 KB — the doc's budget for
//   a false pre-warm) and pre-stalling its own Lane B uplink (~400 ms).
//
// The coalescing IS the design: turnend.js fires ~7×/utterance at its
// operating point, so the wire message goes out at most once per
// L0_PRED_COOLDOWN_MS, and the receiver acts ONLY in a genuine listening
// stretch (no local onset for L0_LISTEN_MS and the local detector not active)
// — a false pre-warm during our own speech costs ~25 KB (budgeted), but a
// 400 ms video stall mid-sentence would be a bug, not a feature.
const LANE0 = PCM_CFG.lane0;
const L0_ONSET_YIELD_MS = 40; // lever 3: covers the onset's first PCM frames
const L0_PRESTALL_MS = 400;   // lever 4b: the reply's first audio meets an empty pipe
const L0_LISTEN_MS = 2000;    // a listening stretch: no local onset for this long
const L0_PRED_COOLDOWN_MS = 2000; // one wire message per detected fall
const L0_PAD_BYTES = 25000;   // §3.1's budget for one pre-warm
const lane0Stats = {
  turnendFires: 0,       // predictor 'predict' events seen (pre-coalesce)
  predSuppressed: 0,     // fires eaten by the per-fall cooldown
  predWireSent: 0,       // T_PRED pairs actually put on the wire
  predWireRecv: 0,       // deduped T_PREDs received (pcm.js counts the dups)
  predSkippedSpeaking: 0,// received while NOT in a listening stretch — correctly ignored
  preWarms: 0,           // listening-stretch pre-warms executed (pad + pre-stall)
  onsetYields: 0,        // lever-3 Lane B yields at local onsets
};
let lastLocalOnsetAt = -Infinity; // performance.now() of the last local onset
let localDetState = 'idle';       // the local detector's own state, from its level events
let lastPredSentAt = -Infinity;

function lane0Listening() {
  return localDetState !== 'active' && (performance.now() - lastLocalOnsetAt) >= L0_LISTEN_MS;
}

// Lever 4, send side: one wire message per detected fall.
function onTurnEnd(ev) {
  safe(() => {
    if (ev.kind !== 'predict') return; // 'reset' just re-arms the predictor
    lane0Stats.turnendFires++;
    const t = performance.now();
    if (t - lastPredSentAt < L0_PRED_COOLDOWN_MS) { lane0Stats.predSuppressed++; return; }
    lastPredSentAt = t;
    const n = pcm?.sendTurnEnd?.() ?? 0;
    if (n) {
      lane0Stats.predWireSent++;
      tel?.log('lane0-pred', { dir: 'sent', prob: ev.prob, leadMs: ev.leadMs, copies: n });
    }
  }, 'lane0.turnend');
}

// Lever 4, receive side: spend the window only in a genuine listening stretch.
function onPredict(_ev) {
  safe(() => {
    lane0Stats.predWireRecv++;
    if (!lane0Listening()) {
      lane0Stats.predSkippedSpeaking++;
      tel?.log('lane0-pred', { dir: 'recv', listening: 0 });
      return;
    }
    lane0Stats.preWarms++;
    pcm?.sendPad?.(L0_PAD_BYTES);
    const d = tape?.yieldLaneB?.(L0_PRESTALL_MS, 'pred') ?? 0;
    tel?.log('lane0-pred', { dir: 'recv', listening: 1, preStallMs: d });
  }, 'lane0.predict');
}

// ── §10: session clock + A-V sync bundle ─────────────────────────────────────
// Only meaningful with the PCM lane: the sample clock is the audio master, and
// Opus/NetEq's clock is not sample-accessible — with `?pcmaudio=1` absent this
// whole bundle is inert and the page behaves byte-for-byte as before. TIME_SYNC
// rides the EXISTING lane-2 ctl channel (no new channels, no renegotiation).
// `?avsync=0` is the kill switch: paint-on-arrival exactly as §17.8, timesync
// off too. `?avoff=` tunes the audio lead within §3's [0, 45] ms budget.
const AV_SYNC = PCM_AUDIO && QS.get('avsync') !== '0';
// Default 45, not 20. Lip-sync perception is ASYMMETRIC (ITU-R BT.1359-1):
// audio ahead of video is detectable at ~45 ms, audio BEHIND video only at
// ~125 ms. The old default left most of that second band unspent, and under
// loss it costs real latency — video is paced to the PCM audio playhead, and
// that playhead's depth goes 12 -> 135 ms at 5% loss (§MEASURED, "audio buffer
// tows video"), dragging video out with it. Measured n=3/arm at RTT 80 / 5%
// loss: settled latency (last third of a 90 s call) 133.5 +/- 7.2 -> 108.3 +/-
// 7.3 ms, t = 4.26. Video then leads audio by 50-60 ms, inside the 125 ms
// threshold on the tolerant side.
//
// Self-gating, which is why it is safe as a default: on a clean link the
// applied offset does not move (-33 ms at either setting, n=2) because a frame
// cannot be presented before it arrives — there is no slack to spend until the
// audio buffer has grown. It does nothing on good networks and pays out on bad
// ones. Note the clean path's -33 ms sits on the SENSITIVE side of the budget,
// nearer the 45 ms threshold than this change ever puts us.
// Ceiling raised 45 -> 110 so the band BT.1359 actually allows is TESTABLE. The
// default is unchanged at 45, so this is inert without an explicit ?avoff=.
// Rationale: the audio playhead deepens ~123 ms under 5% loss and tows video;
// spending 45 recovers 25 ms and leaves a ratchet measured at +33.1 to +34.2 ms
// in 5 of 6 runs — remarkably stable, and NOT the FEC hold (l2hold=400
// eliminates hold expiries and moves neither latency nor delivery, t = 0.36).
// The residual is the part of the tow the clamp forbids us to cover. 110 keeps
// a margin under the ~125 ms detectability threshold for audio behind video.
// 70 is the measured optimum, not a round number. n=3/arm at RTT 80 / 5% loss,
// settled latency (last third of a 90 s call) / delivered / p95:
//   avoff=45  110.8 ms / 89.4% / 120   and still ratcheting +17..+33
//   avoff=70   77.2 ms / 87.6% / 115   flat, sd 0.7
//   avoff=90   68.6 ms / 82.1% / 135   flat
// 70 buys 33.6 ms over 45 for 1.8 points of delivery and a BETTER p95. Going on
// to 90 buys 8.6 ms more but costs 5.5 further points and 20 ms of p95 —
// presenting that early makes marginally-late frames miss their slot (avSkips
// climbs). Applied offset lands ~70-80 ms, well inside BT.1359's ~125 ms
// detectability threshold for audio behind video.
const AV_OFFSET = Math.max(0, Math.min(110, Number(QS.get('avoff') ?? 70) || 0));
let tsync = null;
let sessionEpochUs = null;
let welcomeAtMs = 0; // local wall ms when the welcome (and its epoch) arrived

/**
 * Start Lane A. The datachannel is created SYNCHRONOUSLY (the offer built a
 * few lines later must already contain it — a channel created after the first
 * offer would need a renegotiation, and lane 2 never renegotiates). The audio
 * graph (worklets, SAB ring) initializes asynchronously inside pcm.js; the
 * channel simply stays quiet until both it and the graph are ready.
 */
function startPcm(initiator) {
  safe(() => {
    pcm = initPcmAudio({
      stream: localStream,
      cfg: PCM_CFG,
      // pcm.js swallows its own graph failure — `catch { L('pcm-fail', …) }` with
      // nothing downstream — so its log line is the recovery trigger. Seconds
      // faster than waiting for the watchdog to notice the silence.
      log: (t, d) => {
        tel?.log(t, d);
        if (t === 'pcm-fail') fallbackToOpus(`pcm-fail-${d?.why ?? '?'}`);
      },
      // The remote detector lives in the playout worklet now; its events are
      // the same shape onset-monitor.js produces, on the same shared context's
      // clock — the turn-taking stream cannot tell the difference.
      onEvent: (ev) => onDetector('remote', ev),
      // The lane's own concealment is the remote detector's false-breath
      // hazard exactly as NetEq's was (§17.1): stamp it through the same
      // machinery so analysis can exclude events near a concealed gap.
      onConceal: (n) => { concealBurstAt = performance.now(); concealBurstN = n; },
      // Lane 0 (§3.1 levers 3+4): the local turn-end predictor's events and
      // the peer's T_PRED arrivals. Null with Lane 0 off — no predictor, no
      // wire type, no behaviour change.
      onTurnEnd: LANE0 ? onTurnEnd : null,
      onPredict: LANE0 ? onPredict : null,
    });
    if (initiator) {
      const dc = pc.createDataChannel('pcm-audio', { ordered: false, maxRetransmits: 0 });
      pcm.attachChannel(dc, 0);
    } else {
      const prev = pc.ondatachannel;
      pc.ondatachannel = (e) => {
        try { prev?.call(pc, e); } catch { /* ignore */ }
        if (e.channel.label === 'pcm-audio') pcm?.attachChannel(e.channel, 0);
      };
    }
    // §17.12 striping: associations 1..N-1 ride their own data-channel-only
    // pcs, created HERE — synchronously, channels before any offer they make
    // (the no-renegotiation law applies to them exactly as to the main pc).
    if (PCM_CFG.pairs > 1) startPcmStripes(initiator);
    tel?.log('pcm-start', { initiator, cfg: PCM_CFG });
  }, 'pcm.start');
}

/**
 * The stripe pcs (§17.12). Boring on purpose: N−1 permanent data-channel-only
 * peer connections, set up once at join, never renegotiated, sharing the
 * join-time /api/ice config. Signalling is a namespaced parallel of the main
 * pc's: 'pcm-offer' / 'pcm-answer' / 'pcm-ice', each carrying the stripe idx.
 * Role 'a' offers (pcmStripeOfferAll is called from the same welcome /
 * peer-joined points as the main offer), role 'b' answers.
 */
function startPcmStripes(initiator) {
  for (let idx = 1; idx < PCM_CFG.pairs; idx++) {
    const spc = new RTCPeerConnection({ iceServers: pcmIceServers, ...certArg() });
    spc.onnegotiationneeded = () =>
      tel?.log('pcm-stripe-neg', { idx, sig: spc.signalingState }); // observed, never acted on
    spc.onicecandidate = (e) => e.candidate && send({ type: 'pcm-ice', idx, candidate: e.candidate });
    spc.oniceconnectionstatechange = () => tel?.log('pcm-stripe-ice', { idx, state: spc.iceConnectionState });
    spc.onconnectionstatechange = () => tel?.log('pcm-stripe-state', { idx, state: spc.connectionState });
    if (initiator) {
      const dc = spc.createDataChannel(`pcm-audio-${idx}`, { ordered: false, maxRetransmits: 0 });
      pcm.attachChannel(dc, idx);
    } else {
      spc.ondatachannel = (e) => {
        if (e.channel.label === `pcm-audio-${idx}`) pcm?.attachChannel(e.channel, idx);
      };
    }
    pcmPcs[idx] = spc;
  }
}

async function pcmStripeOfferAll() {
  for (let idx = 1; idx < PCM_CFG.pairs; idx++) {
    const spc = pcmPcs[idx];
    if (!spc || spc.localDescription) continue; // set up once, never renegotiated
    await safeAsync(async () => {
      const o = await spc.createOffer();
      await spc.setLocalDescription(o);
      send({ type: 'pcm-offer', idx, sdp: spc.localDescription });
    }, 'pcm.stripe-offer');
  }
}

/**
 * Start the custom video lane, with a fallback that must always work.
 *
 * The fallback is the part that earns its place. Fixed-QP WebCodecs is new code on a new
 * path, and this runs during a conversation that happens once — so any failure at all,
 * at any stage, puts the ordinary RTP video track back on the peer connection and
 * renegotiates. The user loses the custom pipeline and keeps the call.
 */
function startTape(initiator) {
  // Before `common` is built: the encoder's framerate and the pacer's opening rate are
  // read once from cfg, so this is the only moment they can be got right for free.
  syncTapeFps('tape-start');
  // #14 canvas display: created eagerly so the decoder's first output already
  // has somewhere to land. Lives next to the <video> in #remoteWrap; the CSS
  // rule for it mirrors the video's (object-fit: cover works on canvas).
  const displayCanvas = (wantTape === 2 && TAPE_CFG.l2Canvas)
    ? (() => {
        let c = $('remoteCanvas');
        if (!c) {
          c = document.createElement('canvas');
          c.id = 'remoteCanvas';
          $('remoteWrap').appendChild(c);
        }
        return c;
      })()
    : null;
  const common = {
    pc,
    track: localStream.getVideoTracks()[0],
    initiator,
    pre: tapePre,
    cfg: TAPE_CFG,
    displayCanvas,
    log: (t, d) => tel?.log(t, d),
    onRemote: (stream) => {
      $('remote').srcObject = stream;
      tape?.observeDisplay?.($('remote')); // #14 decode→present probe
      tel?.log('tape-render', { attached: true, lane: wantTape });
    },
    onFail: (why) => fallbackToRtp(why),
    // §12–13: the video regime machine reports its state for the honest UI.
    // "held" → the remote video is VIDEO HELD (last frame + 1 fps stills);
    // anything else clears the badge unless HOLD owns it.
    onStall: STALL
      ? (state, info) => {
          videoHeld = state === 'held';
          stallUi();
          tel?.log('stall-state', { state, ...info });
        }
      : null,
    // §10 bundle: audio master clock probes + ctl hooks for TIME_SYNC. Null
    // unless lane 2 + PCM audio are both live — lane 1/stock RTP never sees it.
    avsync: AV_SYNC && wantTape === 2
      ? {
          offsetMs: AV_OFFSET,
          audioClockUs: () => pcm?.audioClockUs?.() ?? null,
          audioPlayoutUs: () => pcm?.playheadInfo?.() ?? null,
          onCtlUnknown: (m) => tsync?.onMessage(m),
          onCtlOpen: () => tsync?.start(),
        }
      : null,
  };
  tape = safe(() => (wantTape === 2 ? startTapeRtp(common) : startTapeVideo(common)), 'tape.start') ?? null;
  if (!tape) fallbackToRtp('start-threw');
  // Lane 2's answering side receives the ctl channel rather than creating it.
  if (tape && wantTape === 2 && !initiator) {
    const prev = pc.ondatachannel;
    pc.ondatachannel = (e) => {
      try { prev?.call(pc, e); } catch { /* ignore */ }
      if (e.channel.label === 'tape-ctl-rtp') tape?.adoptCtl(e.channel);
      if (e.channel.label === 'tape-lanep') tape?.adoptLaneP?.(e.channel);
    };
  }
  tel?.log('tape-start', { initiator, lane: wantTape, up: !!tape, cfg: TAPE_CFG });
}

/**
 * Agree a video transport with the peer, or give it up.
 *
 * The custom lane is symmetric and was never negotiated: each end asked only
 * `tapeRtpSupported()`, which answers for the browser it is running in. Ship the
 * lane on by default and the first Chromium/Safari pair gets a black screen in
 * both directions — the Chromium end substitutes its picture into the RTP payload
 * of a 1x1 carrier canvas, the Safari end has no transform and renders that
 * carrier exactly as sent, and neither end raises anything. Reproduced headless
 * with one side pinned `?tape=2` and the other `?tape=0`: luma mean 0, sd 0, on
 * both. Nothing downstream can recover from this, because nothing downstream can
 * tell a black picture from a dark room.
 *
 * `peerLane` is null when we are alone in the room — that is not a mismatch, it
 * is an unanswered question, and `peer-joined` answers it later.
 */
function attachRemoteMedia() {
  const parts = [];
  for (const t of rtpStream?.getTracks?.() ?? []) parts.push(t);
  // The streamless carrier track, when the stream did not bring a picture of its
  // own. Order matters only in that a real stream's video always wins.
  if (rtpVideoTrack && !parts.some((t) => t.kind === 'video')) parts.push(rtpVideoTrack);
  if (!parts.length) return;
  $('remote').srcObject = new MediaStream(parts);
  layout();
}

function laneAgree(peerLane, when) {
  if (!wantTape || peerLane == null) return;
  if (peerLane === wantTape) return;
  tel?.log('lane-mismatch', { when, ours: wantTape, theirs: peerLane });
  // Before the offer this is nearly free: the carrier sender simply gets the
  // camera instead of the flicker canvas, which is a replaceTrack on a track of
  // the same kind and needs no renegotiation.
  fallbackToRtp(`peer-lane-${peerLane}`, true); // quiet: a peer with no lane has nothing to stop
}

/**
 * Last resort for the mismatches negotiation cannot see: a peer that agreed on
 * the lane and then failed to drive it. `laneAgree` handles the case where the
 * two ends disagree about what they CAN do; this handles the case where they
 * agreed and it still did not work — a transform that attached but was routed
 * around, a decoder that never configured, a carrier that never got a tick. All
 * of those present identically to the user, as a black rectangle, and none of
 * them raise an error.
 *
 * The test is frames DECODED, not bytes received: the failure this exists for is
 * a lane that is busy and producing nothing.
 */
let laneWatchdog = null;
function armLaneWatchdog() {
  clearTimeout(laneWatchdog);
  if (wantTape !== 2 || tapeFellBack) return;
  laneWatchdog = setTimeout(() => {
    if (tapeFellBack || wantTape !== 2) return;
    const out = tape?.snapshot?.()?.framesOut ?? 0;
    if (out > 0) return;
    tel?.log('lane-watchdog', { framesOut: out });
    fallbackToRtp('no-frames');
  }, 4000);
}

/**
 * Lane A's recovery. Video's failure mode is a black rectangle; audio's is
 * silence, which is worse — a muted call looks completely normal and the two
 * people just start saying "hello? can you hear me?".
 *
 * Recovery is one replaceTrack onto the hot spare (see pcmSpareSender), so it
 * costs no renegotiation and cannot glare. Bilateral by design: lane A is a
 * SINGLE shared audio graph — the same worklet both captures our mic and plays
 * the peer's frames — so a failure here kills both directions at once. Telling
 * the peer is not politeness, it is the only way the peer's voice reaches us.
 */
function fallbackToOpus(why, quiet) {
  if (!PCM_AUDIO || pcmFellBack) return;
  pcmFellBack = true;
  pcmFellBackWhy = why;
  clearTimeout(pcmWatchdog);
  tel?.log('pcm-fallback', { why, quiet: !!quiet });
  safe(() => {
    pcm?.stop();
    pcm = null;
    // pcmPcs is indexed from 1 (association 0 rides the main pc), so slot 0 is
    // always a hole — close only what exists, same as the teardown at leave.
    for (const spc of pcmPcs) if (spc) safe(() => spc.close(), 'pcm.stripe-close');
    pcmPcs = [];
    const mic = localStream?.getAudioTracks()[0];
    if (pcmSpareSender && mic) pcmSpareSender.replaceTrack(mic).catch(() => {});
    attachRemoteMedia();
    // `quiet` is for the cases where the peer needs no telling: it never had a
    // lane (capability mismatch), or it is the one that told us.
    if (!quiet) send({ type: 'audio-fallback', why });
  }, 'pcm.fallback');
}

/**
 * The audio twin of `laneAgree`, and it exists for the same reason: a symmetric
 * lane whose two ends each only ever checked themselves. Under ?pcmaudio=1 the
 * mic used to be absent from the peer connection entirely, so a peer without the
 * flag heard NOTHING from us for the whole call while its own audio arrived
 * fine — a one-way call, with no error on either side. Same bug as the video
 * lane's black screen, one sense over.
 */
function pcmAgree(peerPcm, when) {
  if (!PCM_AUDIO || peerPcm == null || peerPcm) return;
  tel?.log('pcm-mismatch', { when, ours: 1, theirs: peerPcm });
  fallbackToOpus('peer-no-pcm', true);
}

/**
 * And the twin of `armLaneWatchdog`, for agreed-but-broken. pcm.js's own failure
 * path is `catch { L('pcm-fail', {why:'graph'}) }` with no recovery, and the
 * quieter failures — a datachannel that never opens, a worklet that never gets
 * its SAB — do not even log that much. The honest test is frames the playout
 * worklet has actually PLAYED, because every one of these presents as a lane
 * that is running and silent.
 *
 * 6 s, not video's 4: the audio graph waits on worklet module fetch plus SAB
 * setup, and cutting over early would drop a working lane.
 */
function armPcmWatchdog() {
  clearTimeout(pcmWatchdog);
  if (!PCM_AUDIO || pcmFellBack) return;
  pcmWatchdog = setTimeout(() => {
    if (pcmFellBack) return;
    const s = safe(() => pcm?.snapshot(), 'pcm.watchdog-snap');
    const played = s?.playedFrames ?? 0;
    if (s?.started && played > 0) return;
    tel?.log('pcm-watchdog', { started: !!s?.started, playedFrames: played, mode: s?.mode ?? null });
    fallbackToOpus('no-audio');
  }, 6000);
}

function fallbackToRtp(why, quiet) {
  if (tapeFellBack) return; // failures arrive in bursts; renegotiating per failure would thrash
  tapeFellBack = true;
  tel?.log('tape-fallback', { why, quiet: !!quiet });
  // Tell the peer, exactly as the audio lane does (`audio-fallback`): a lane
  // fallback that stays private leaves the OTHER end running the lane, and its
  // negotiated video m-line keeps carrying the flicker-canvas carrier — which
  // we, now on plain RTP, render literally. Measured on real Safari x Chromium
  // (task #42, 2026-08-04): Safari fell back at t+5 s on no-frames and watched
  // a black 320x180 carrier for the rest of the call while Chromium reported
  // itself healthy. `quiet` is for the cases where the peer needs no telling:
  // it never had a lane, or it is the one that told us.
  if (!quiet) send({ type: 'video-fallback', why });
  // TIME_SYNC rides lane 2's ctl channel, so the channel it pings over is about to
  // stop existing. Stopping it here is not tidiness: measured on the deployed build,
  // a Brave x Chromium call that fell back kept pinging at 5 Hz for the whole call
  // and reached `pings 200, pongs 0`. That published a clock that looks like it is
  // being maintained while `offsetMs` is null, and null offsets have already produced
  // a 637 ms "age" on an 80 ms call once. A stopped estimator reports `running:
  // false`, which is the truth.
  tsync?.stop();
  safe(() => {
    tape?.stop(); // lane 2's stop() also flips the transform worker to bypass
    tape = null;
    $('remoteCanvas')?.remove(); // #14: the RTP fallback paints the <video> again
    const vt = localStream?.getVideoTracks()[0];
    // Lane 1 fallback: the video track was never on the pc, so add it and renegotiate.
    // Only `a` renegotiates. Both sides offering at once is the glare case, and the
    // recovery path is not the place to be resolving it.
    if (vt && pc && !pc.getSenders().some((s) => s.track?.kind === 'video')) {
      pc.addTrack(vt, localStream);
      if (role === 'a') offer();
    } else if (wantTape === 2 && pc) {
      // Lane 2 fallback: the carrier IS a real video sender — give it the camera.
      // The carrier clock runs on a tiny canvas track (tape.js), so "un-crippling"
      // means replacing that track with the camera's, on whichever sender the claim
      // left active. The pipeline rebuild this causes doesn't matter — the
      // transform is already dead by definition here.
      const cs = tapePre?.getCarrierSender?.();
      const cam = localStream?.getVideoTracks()[0];
      const carrierTx = cs ? pc.getTransceivers().find((t) => t.sender === cs) : null;
      // A carrier with a mid is a negotiated m-line, and replaceTrack puts the
      // camera on a section the peer already has. A carrier WITHOUT one is a
      // sender wired to nothing, which is the ANSWERER's normal state whenever
      // the offerer is not itself on the lane: the slot an answerer's carrier
      // claims (`tape.slot`) is only ever offered by a lane offerer, so with a
      // stock-RTP offerer the answerer's carrier never appears in any SDP.
      // Measured — the answerer fell back, replaced the carrier's track with the
      // camera, reported itself healthy, and the offerer still showed a 0x0
      // element, because the track was being sent into an m-line that did not
      // exist. Adding the camera the ordinary way is the fix, and at the moment
      // this actually fires — `welcome`, before the answer is built — it costs no
      // renegotiation at all: createAnswer matches it into the offer's own video
      // section.
      if (cam && carrierTx && carrierTx.mid == null) {
        pc.addTrack(cam, localStream);
        // SILENCE THE CARRIER. Its only job was to give lane 2 a clock, and lane 2 is dead.
        // It has no mid *now*, which is why the camera is being added as its own sender —
        // but the transceiver stays on the pc, so the renegotiation two lines down hands it
        // an m-line and it starts sending its flicker canvas for real. Measured on every
        // Brave x WebKit run: a second outbound video stream, 320x180@30, ~1195 frames per
        // 40 s call, `limitedBy "none"`, with the peer dutifully decoding all of them —
        // while the actual picture next to it sat at 540p reporting `limitedBy "bandwidth"`.
        // replaceTrack(null) stops the sending without touching the m-line, so it costs no
        // further renegotiation.
        if (cs) cs.replaceTrack(null).catch(() => {});
        // Mid-call (the watchdog path) the mids are already assigned, so this
        // branch means a carrier that never negotiated and a call that is past
        // its first exchange. That needs a new offer, and only `a` may make one.
        if (pc.remoteDescription) { if (role === 'a') offer(); else send({ type: 'reoffer' }); }
      } else if (cs && cam) {
        cs.replaceTrack(cam).catch(() => {});
      }
      attachRemoteMedia();
    }
    // TUNE WHATEVER SENDER NOW CARRIES THE CAMERA. join()'s sender loop ran once, before
    // this function existed in the call's history, and it deliberately skipped the video
    // sender while lane 2 was alive. Every branch above either adds a sender or gives an
    // existing one the camera, and until this line none of them were ever tuned: measured
    // on a real Brave x WebKit call, the Brave side ran `degradationPreference null,
    // maxBitrate null, maxFramerate null` and sent 640x360 while its peer sent 1080p.
    // Both sends were worse than intended, in opposite directions.
    for (const s of pc?.getSenders() ?? []) {
      if (s.track?.kind === 'video') tuneVideoSender(s, 'fallback');
    }
    $('status').textContent = '';
    $('status').classList.remove('gone');
  }, 'tape.fallback');
}

/**
 * Rewrite the Opus fmtp line in an SDP we are about to set as our LOCAL description.
 *
 * Opus's fmtp parameters are receiver declarations (RFC 7587 §6.1): `maxaveragebitrate` in our
 * SDP constrains what the far end sends *to us*, not what we send. Both ends run this same
 * code, so munging each side's own local description is what configures both directions —
 * which is also why this has to run on the answer as well as the offer.
 *
 * Never throws. A codec preference must not be able to prevent a call (§17.2), and neither
 * must an audio one: on any surprise this returns the SDP untouched and the call proceeds at
 * Chrome's default.
 */
function tuneAudio(sdp) {
  try {
    const pts = [...sdp.matchAll(/^a=rtpmap:(\d+) opus\/48000(?:\/\d+)?/gim)].map((m) => m[1]);
    if (!pts.length) return sdp;
    let out = sdp;
    for (const pt of pts) {
      // Merge rather than replace. Chrome already emits `minptime` and `useinbandfec`, and
      // clobbering parameters we do not manage is how a working call becomes a silent one.
      const re = new RegExp(`^a=fmtp:${pt} (.*)$`, 'im');
      const cur = out.match(re);
      const kv = new Map();
      if (cur) {
        for (const p of cur[1].split(';')) {
          const i = p.indexOf('=');
          if (i > 0) kv.set(p.slice(0, i).trim(), p.slice(i + 1).trim());
        }
      }
      kv.set('maxaveragebitrate', String(Math.round(A_KBPS * 1000)));
      kv.set('stereo', A_STEREO ? '1' : '0');
      kv.set('sprop-stereo', A_STEREO ? '1' : '0');
      kv.set('useinbandfec', A_FEC ? '1' : '0');
      // DTX stops sending during silence, which saves bandwidth we are not short of and
      // hands the far end's concealment a job to do. Concealed audio is broadband and
      // aperiodic, which is the onset detector's own signature for a breath — so DTX would
      // manufacture false breaths in the one measurement this project exists to make.
      kv.set('usedtx', '0');
      if (A_PTIME) kv.set('minptime', String(A_PTIME));
      const line = `a=fmtp:${pt} ${[...kv].map(([k, v]) => `${k}=${v}`).join(';')}`;
      out = cur ? out.replace(re, line) : out.replace(new RegExp(`^(a=rtpmap:${pt} opus.*)$`, 'im'), `$1\r\n${line}`);
      if (A_PTIME) {
        out = /^a=ptime:/im.test(out)
          ? out.replace(/^a=ptime:\d+$/im, `a=ptime:${A_PTIME}`)
          : out.replace(re, `${line}\r\na=ptime:${A_PTIME}`);
      }
    }
    tel?.log('audio-sdp', { pts, kbps: A_KBPS, stereo: A_STEREO, fec: A_FEC, ptime: A_PTIME || null });
    return out;
  } catch (e) {
    tel?.log('audio-sdp', { error: String(e).slice(0, 80) });
    return sdp;
  }
}

/**
 * Give the tape-RTP carrier its pacer budget through the SDP instead of setParameters.
 *
 * Every runtime `setParameters` on the carrier sender rebuilds Chrome's send pipeline
 * WITHOUT the attached encoded transform — measured with three different trigger timings
 * (pre-negotiation, clock-delayed, first-substitution + 800 ms), all fatal. So the sender
 * is never mutated after creation; the budget rides in as negotiated state instead:
 *
 *  - `b=AS` on the video m-line raises the bandwidth cap (a receiver declaration, like
 *    Opus's maxaveragebitrate — munging our LOCAL sdp configures what the far end may
 *    send us; both sides run this, so both senders get the budget).
 *  - `x-google-min-bitrate` on the VP8 fmtp keeps the target — and with it the pacer's
 *    drain rate (~2.5×) — above the tape lane's ~12 Mbps spend from the first frame,
 *    instead of waiting for GCC's ramp. Budget must exceed spend or the pacer queue
 *    never drains (v7: permanent 2 s queue age when budget ≈ spend).
 *
 * Never throws; returns the SDP untouched on any surprise (§17.2 discipline).
 */
function tuneVideoCarrier(sdp) {
  try {
    if (wantTape !== 2) return sdp;
    // b=AS on the video section (insert after its c= line).
    const kbps = TAPE_CFG.carrierKbps;
    let out = sdp.replace(/(m=video [^\r\n]*\r?\n(?:[^m]|m(?!=))*?c=IN [^\r\n]*\r?\n)(b=AS:\d+\r?\n)?/, `$1b=AS:${kbps}\r\n`);
    // x-google bitrate hints on every VP8 payload type (merge into any existing fmtp).
    const pts = [...out.matchAll(/^a=rtpmap:(\d+) VP8\/90000/gim)].map((m) => m[1]);
    for (const pt of pts) {
      const re = new RegExp(`^a=fmtp:${pt} (.*)$`, 'im');
      const cur = out.match(re);
      const kv = new Map();
      if (cur) {
        for (const p of cur[1].split(';')) {
          const i = p.indexOf('=');
          if (i > 0) kv.set(p.slice(0, i).trim(), p.slice(i + 1).trim());
        }
      }
      kv.set('x-google-min-bitrate', String(TAPE_CFG.carrierMinKbps));
      kv.set('x-google-start-bitrate', String(TAPE_CFG.carrierMinKbps));
      kv.set('x-google-max-bitrate', String(kbps));
      const line = `a=fmtp:${pt} ${[...kv].map(([k, v]) => `${k}=${v}`).join(';')}`;
      out = cur ? out.replace(re, line) : out.replace(new RegExp(`^(a=rtpmap:${pt} VP8.*)$`, 'im'), `$1\r\n${line}`);
    }
    tel?.log('carrier-sdp', { pts, kbps, minKbps: TAPE_CFG.carrierMinKbps, bas: /b=AS:/.test(out) });
    return out;
  } catch (e) {
    tel?.log('carrier-sdp', { error: String(e).slice(0, 80) });
    return sdp;
  }
}

// ── Capture ──────────────────────────────────────────────────────────────────
/**
 * The capture ask, in one place, because the camera flip (§8) has to make the
 * SAME one — a rear camera opened with different constraints would change the
 * send resolution behind the AIMD governor's back. `resizeMode:'none'` forbids
 * the browser cropping or scaling the sensor output, which is also what makes
 * the receiver-side no-crop policy (§5) honest: nothing is thrown away before
 * the wire, so a contain fit really does show every pixel that was captured.
 */
function captureConstraints() {
  const cap = devCeiling();
  return cap
    ? {
        width: { ideal: Math.min(WANT_W, cap.w) },
        height: { ideal: Math.min(WANT_H, cap.h) },
        frameRate: { ideal: cap.fps },
        resizeMode: 'none',
      }
    : {
        width: { ideal: WANT_W },
        height: { ideal: WANT_H },
        // Ask for the ceiling, not a flat 30. `ideal` degrades to whatever the camera
        // has, so a 30 fps webcam still answers 30 and nothing is risked; a camera that
        // can do 60 is no longer told not to. repairFrameRate() below recovers the
        // resolution if a constraint solver decides to trade it away for the rate.
        frameRate: { ideal: FPS_CEILING },
        resizeMode: 'none',
      };
}

// ── Display refresh rate ─────────────────────────────────────────────────────
/**
 * How many frames per second can this screen actually show?
 *
 * There is no web API for it. `screen` has no refreshRate, and there is no media query
 * for it either, so it has to be timed from `requestAnimationFrame` spacing.
 *
 * MEDIAN, not mean: one long frame from a garbage collection or a layout drags a mean
 * down and would under-report a 120 Hz panel as 90. The median of ~120 intervals is
 * unmoved by a handful of outliers.
 *
 * This measurement is only trustworthy where there is a real vsync to lock to. Measured
 * 2026-08-03: headless Chrome returned 80.6 Hz and 76.9 Hz on a 60 Hz panel, with frame
 * intervals swinging 7.1 to 26.2 ms — rAF there is a timer, not a display. Headless
 * WebKit returned 58.8 Hz with a 15-18 ms range, which is a real 60. So `spreadMs` is
 * reported alongside the answer, and a wide spread means "do not trust this".
 */
function measureDisplayHz(frames = 120) {
  return new Promise((resolve) => {
    const ts = [];
    const tick = (t) => {
      ts.push(t);
      if (ts.length <= frames) requestAnimationFrame(tick);
      else {
        const d = [];
        for (let i = 1; i < ts.length; i++) d.push(ts[i] - ts[i - 1]);
        d.sort((a, b) => a - b);
        const med = d[d.length >> 1];
        // HOW MANY intervals sit near the median, not how far the worst one strayed.
        // The first version reported max-minus-min and gated trust on it, which threw
        // away every real reading: a genuine 60 Hz panel measured a perfect 16.665 ms
        // median and a 51 ms spread, because call startup drops a couple of frames.
        // Validating a deliberately outlier-resistant statistic with a maximally
        // outlier-sensitive one is self-defeating. `lockedPct` is the fraction within
        // 10% of the median — 96%+ on a real vsync, far lower when rAF is just a timer
        // (headless Chrome: 77-81 Hz reported on a 60 Hz panel, intervals 7-26 ms).
        const near = d.filter((x) => Math.abs(x - med) <= med * 0.1).length;
        // A rAF that never fires (backgrounded tab) resolves with null rather than a
        // fabricated number: an absent measurement must not look like a slow display.
        resolve(
          !(med > 0)
            ? null
            : {
                hz: +(1000 / med).toFixed(1),
                medianMs: +med.toFixed(3),
                lockedPct: +((100 * near) / d.length).toFixed(1),
                iqrMs: +(d[Math.floor(d.length * 0.75)] - d[Math.floor(d.length * 0.25)]).toFixed(3),
                spreadMs: +(d[d.length - 1] - d[0]).toFixed(2),
                n: d.length,
              },
        );
      }
    };
    requestAnimationFrame(tick);
  });
}

/**
 * The frame rate to encode at: no more than the ceiling, no more than the receiver's
 * display can present, and no more than our camera is actually delivering.
 *
 * Sending above the receiver's refresh rate spends bandwidth on frames that are
 * physically unviewable. Sending above what the camera delivers just tells the encoder
 * a lie. `?maxfps=` overrides the whole calculation for measurement.
 */
/**
 * Is `f` a rate whose frames land on whole multiples of the peer's refresh interval?
 *
 * `hz % f` is the wrong test in floating point, and a ratio-rounding test with a relative
 * tolerance wrongly accepts f=143 on a 144 Hz display (144/143 = 1.007, within 1%). Compare
 * in Hz instead: the nearest whole number of refreshes per frame, times f, must land within
 * half a hertz of the real refresh rate.
 */
const cadenceEven = (hz, f) => {
  if (!(hz > 0) || !(f > 0) || f > hz + 0.5) return false;
  return Math.abs(hz - Math.round(hz / f) * f) < 0.5;
};

function targetFps() {
  if (V_MAXFPS) return { fps: V_MAXFPS, why: 'forced' };
  const camFps = localStream?.getVideoTracks?.()[0]?.getSettings?.().frameRate ?? null;
  let fps = FPS_CEILING;
  let why = 'ceiling';
  // `peerHz` is only applied when the peer's own measurement looked trustworthy; they send
  // `lockedPct` with it, and a low one means their rAF was not locked to a real vsync.
  if (peerHz && peerHz < fps) { fps = peerHz; why = 'peer-display'; }
  if (camFps && camFps < fps) { fps = Math.round(camFps); why = 'camera'; }
  // OUR OWN DISPLAY IS A SEND-SIDE CEILING on lane 2, which is not obvious and cost a
  // measurement to find. Lane 2 rides a canvas carrier and ONE TICK CARRIES ONE FRAME; a
  // canvas can only be captured as fast as the compositor paints it, i.e. our refresh rate.
  // MEASURED 2026-08-03: a 59.7 ticks/s carrier delivered 35.9 fps of data — 1.66 ticks per
  // frame, the rest spent on parity and idle ticks. So the deliverable rate is about 60% of
  // our own refresh, whatever the camera and the peer can do.
  //
  // A pleasant consequence rather than a limitation: a 60 Hz sender is capped at ~36, and 36
  // divides 144 exactly, so the cadence snap below finds an even rate instead of a fast
  // uneven one. Not applied on the plain-RTP fallback, which has no carrier.
  // Same trust gate as the peer's reading — see hzTrusted().
  const ourHzOk = !!localHz
    && hzTrusted(localHz.hz, localHz.medianMs, localHz.iqrMs, localHz.lockedPct);
  const carrierCap = ourHzOk && wantTape === 2 && !tapeFellBack
    ? Math.floor(localHz.hz * 0.6) : null;
  if (carrierCap && carrierCap < fps) { fps = carrierCap; why = 'our-carrier'; }
  // CADENCE: step down to the largest whole divisor of the peer's refresh rate, but only
  // if it keeps most of the frames. Uneven presentation is judder even when nothing is
  // dropped, and it is the mechanism that once made a metric report 27% judder on a
  // perfectly healthy stream.
  let cadence = null;
  if (CADENCE_SNAP && peerHz && !cadenceEven(peerHz, fps)) {
    const ratio = peerHz / fps;
    const keep = ratio < 2 ? CADENCE_MIN_KEEP_SUB2 : CADENCE_MIN_KEEP;
    let best = null;
    for (let f = Math.floor(fps); f >= Math.max(1, Math.ceil(fps * keep)); f--) {
      if (cadenceEven(peerHz, f)) { best = f; break; }
    }
    cadence = { from: fps, to: best, ratio: +ratio.toFixed(3), keep };
    if (best) { fps = best; why = `${why}+cadence`; }
  }
  return { fps, why, camFps, peerHz, ceiling: FPS_CEILING, cadence, carrierCap,
    // Kept even when unused, so a harness can tell "we had no reading" from
    // "we had one and refused it" — the distinction that hid this defect for one run.
    ourHz: localHz?.hz ?? null, ourHzLocked: localHz?.lockedPct ?? null, ourHzOk,
    evenOnPeer: peerHz ? cadenceEven(peerHz, fps) : null };
}

/**
 * Push the chosen rate into the lane-2 config.
 *
 * tape.js reads `cfg.fps` LIVE in two places that matter — the rate controller's per-frame
 * byte budget (`budget / 8 / fps`) and the pacer's climb ceiling (`cfg.fps + 4`) — so a late
 * update still takes effect on a running call. Two things capture it once, at lane start:
 * `enc.configure({framerate})` and the pacer's opening `admitRate`. That is why this runs
 * from `startTape` as well as from the `display` handler; arriving after the lane is up
 * costs a slow ramp, not a wrong ceiling.
 */
function syncTapeFps(why) {
  const tf = targetFps();
  if (TAPE_CFG.fps === tf.fps) return tf;
  const from = TAPE_CFG.fps;
  TAPE_CFG.fps = tf.fps;
  tel?.log('tape-fps', { why, from, to: tf.fps, reason: tf.why,
    inputs: { ceiling: tf.ceiling, peerHz: tf.peerHz ?? null, camFps: tf.camFps ?? null },
    cadence: tf.cadence, evenOnPeer: tf.evenOnPeer, laneUp: !!tape });
  return tf;
}

/**
 * A SECOND constraint solve, containing nothing but the frame rate.
 *
 * Measured 2026-08-03 on a real cross-engine call (`testbed/realpair.mjs`, real Brave
 * x WebKit): the WebKit side captured 1920x1080 at 10 fps, and its encoder faithfully
 * sent 398 of the 401 frames it was handed. The 10 fps was never the encoder. It was
 * the CAMERA, and it was OUR OWN ASK that caused it — `width:{ideal:1920}` and
 * `frameRate:{ideal:30}` are both ideals, and WebKit's solver satisfies resolution
 * first, then settles for 10 fps. Asked a second time with the frame rate ALONE, the
 * same device returns 1920x1080 at 30 fps. It could do both the whole time.
 *
 * The set must contain ONLY the frame rate (resizeMode was measured to be harmless and
 * stays, because the no-crop policy in §5 depends on it). Every formulation that also
 * named width or height stayed at 10 fps — including `width:{exact: <the width already
 * being delivered>}`. A hard `frameRate:{min:24}` was *silently violated* rather than
 * rejected, so a hard constraint buys nothing here and can still reject a real call.
 *
 * Omitting width/height means the device may legally re-solve resolution, so the
 * outcome is checked and reverted, never assumed. Gated on the MEASURED frame rate and
 * not on the browser: a real webcam that hands Chrome 1080p15 has the identical problem
 * and deserves the identical second chance.
 */
async function repairFrameRate(track, want, full) {
  if (!track || track.readyState !== 'live' || !(want > 0)) return;
  const before = track.getSettings();
  const got = before.frameRate;
  // An engine that does not report frameRate gives nothing to compare against, and a
  // repair decided from a missing number is the failure mode in `absent-field-must-throw`.
  if (typeof got !== 'number' || !(got > 0)) return;
  // 0.8 leaves a camera that answers 25 to a 30 ask alone: that is a real device format,
  // not a solver artefact, and re-solving it would risk the resolution for 5 fps.
  if (got >= want * 0.8) return;
  const px = (s) => (s.width ?? 0) * (s.height ?? 0);
  await safeAsync(async () => {
    await track.applyConstraints({ frameRate: { ideal: want }, resizeMode: 'none' });
    const after = track.getSettings();
    const now = typeof after.frameRate === 'number' ? after.frameRate : 0;
    // SUCCESS IS AN IMPROVEMENT, NOT AN ABSOLUTE. `want` is an aspirational ceiling
    // (60), and a camera whose real maximum is 30 answers 30. Judging that against
    // 0.8 * 60 = 48 calls it a failure and reverts — which measured on a real
    // cross-engine call as WebKit going 10 -> 30 -> back to 10, a regression caused
    // entirely by this test. 1.2x because a solver re-run can jitter the reported
    // rate by a frame or two without having actually changed anything.
    const fixed = now > got * 1.2;
    // Accept a resolution loss only if it actually bought the frame rate: for a
    // conversation 720p30 beats 1080p10, which is the same preference the encoder
    // already declares with degradationPreference 'maintain-framerate'. A re-solve
    // that lost pixels and gained nothing is reverted.
    const outcome = fixed ? (px(after) < px(before) ? 'traded' : 'repaired') : 'reverted';
    if (outcome === 'reverted') await track.applyConstraints(full);
    tel?.log('capture-fps-repair', {
      want, outcome,
      before: pick(before, ['width', 'height', 'frameRate']),
      after: pick(track.getSettings(), ['width', 'height', 'frameRate']),
    });
  }, 'capture.fpsrepair');
}

// `requireVideo` (default): STARTING a call requires both devices — a call may
// not begin without the camera (user directive 2026-08-04). The mid-call
// re-acquire passes false: a camera that dies during a conversation degrades
// gracefully instead of ending it, which is a different promise than joining.
async function getMedia({ requireVideo = true } = {}) {
  // `ideal` not `exact` on frameRate: an `exact` constraint that the camera can't
  // satisfy throws OverconstrainedError and there is no call at all. During a real
  // conversation, a wobbling frame rate beats no conversation. Same reasoning applies to
  // resolution: `ideal` degrades to whatever the camera has rather than failing the call.
  // Weak-device ceiling (task #37): on a software-encode device the capture ask
  // is clamped BEFORE getUserMedia — and in the preview-track re-apply below,
  // which is the same constraint set. The encoder cannot give back capture
  // resolution the camera already burned CPU delivering. Everything stays
  // `ideal`, so the clamp degrades gracefully and can never reject the call,
  // exactly like the stock ask. On hardware-H.264 devices `cap` is null and the
  // constraint object is literally what it was before.
  const videoConstraints = captureConstraints();
  // The ceiling itself, for the telemetry below. captureConstraints() reads it
  // too; resolveDevTier() memoises on devTier, so asking twice costs nothing.
  const cap = devCeiling();

  // Reuse the lobby preview's camera track when it's live: opening the SAME camera
  // twice (once for preview, once for join) is exactly what makes finicky drivers —
  // Windows especially — throw NotReadableError ("Could not start video source") at
  // join time. One open per device, per page.
  const previewV = previewStream?.getVideoTracks?.()[0];
  const previewA = previewStream?.getAudioTracks?.()[0];
  const reuseV = previewV && previewV.readyState === 'live' ? previewV : null;
  // The lobby now holds the mic too (it needs one for the level meter and the
  // headphone check), so reuse it rather than opening a second one — asking a
  // device for a microphone it has already given out is the same NotReadableError
  // trap as the camera, just less often noticed.
  const reuseA = previewA && previewA.readyState === 'live' ? previewA : null;
  // The lobby's level meter owns an AudioWorkletNode on that same mic. Hand the
  // track over cleanly before the call's own detectors attach to it.
  lobbyMon?.disconnect();
  lobbyMon = null;

  const askAudioOnly = () => navigator.mediaDevices.getUserMedia({ audio: audioConstraints(true) });
  const askBoth = () => navigator.mediaDevices.getUserMedia({ video: videoConstraints, audio: audioConstraints(true) });
  const denied = (e) =>
    new Error('Camera and microphone permission was denied. Allow both in the browser address bar, then rejoin.', { cause: e });

  let stream;
  let degradedVideo = null; // null | 'busy' | 'none'
  if (reuseV) {
    // Both from the lobby: no getUserMedia at join at all, which is the whole
    // point of one-open-per-device. Only fetch a mic if the lobby somehow lacks one.
    stream = reuseA ? new MediaStream([reuseA]) : await askAudioOnly();
    stream.addTrack(reuseV);
    safeAsync(async () => {
      await reuseV.applyConstraints(videoConstraints);
      // Inside this block, not after it: this safeAsync is deliberately not awaited, so
      // a repair queued outside would race the applyConstraints above and re-solve
      // against settings that are about to be replaced.
      await repairFrameRate(reuseV, videoConstraints.frameRate.ideal, videoConstraints);
      // The clamp landing on a REUSED lobby-preview track is invisible to the
      // `capture` event below (it read settings before this resolved), so say
      // what was asked and what the camera actually gave, separately.
      if (cap) {
        tel?.log('capture-clamp', {
          asked: { w: videoConstraints.width.ideal, h: videoConstraints.height.ideal, fps: videoConstraints.frameRate.ideal },
          applied: pick(reuseV.getSettings(), ['width', 'height', 'frameRate']),
        });
      }
    }, 'capture.reapply');
  } else {
    try {
      stream = await askBoth();
    } catch (e) {
      if (e.name === 'NotAllowedError' || e.name === 'SecurityError') throw denied(e);
      // Camera busy or missing (NotReadableError / NotFoundError / OverconstrainedError).
      // One retry in case it's a transient driver hiccup. At JOIN there is no
      // audio-only door anymore: a call may not start without the camera (user
      // directive 2026-08-04), so the failure is said honestly instead. The
      // mid-call re-acquire (requireVideo: false) keeps the graceful path — a
      // camera dying DURING a call must not end it.
      try {
        await new Promise((r) => setTimeout(r, 700));
        stream = await askBoth();
      } catch (e2) {
        if (e2.name === 'NotAllowedError' || e2.name === 'SecurityError') throw denied(e2);
        if (requireVideo) {
          throw new Error(
            e2.name === 'NotFoundError'
              ? 'No camera was found. Connect one, then rejoin — calls here need both camera and microphone.'
              : 'The camera could not be started (another app may be using it). Close it, then rejoin.',
            { cause: e2 },
          );
        }
        stream = await askAudioOnly(); // if the mic also fails, this fails honestly
        degradedVideo = e2.name === 'NotFoundError' ? 'none' : 'busy';
      }
    }
  }
  videoDegraded = degradedVideo;

  // Awaited, unlike the reuse path's: the sender parameters and the encoder are
  // configured from these settings moments later in join(), and a repair that landed
  // after them would be invisible to both. `!== reuseV` because the reuse branch above
  // owns its own repair.
  const freshV = stream.getVideoTracks()[0];
  if (freshV && freshV !== reuseV) {
    await repairFrameRate(freshV, videoConstraints.frameRate.ideal, videoConstraints);
  }

  safe(() => {
    const vt = stream.getVideoTracks()[0];
    const at = stream.getAudioTracks()[0];
    tel?.log('capture', {
      video: vt ? pick(vt.getSettings(), ['width', 'height', 'frameRate', 'deviceId', 'resizeMode']) : null,
      audio: at
        // sampleSize is here because it is the ONLY remaining argument for a
        // 16-bit lane. Task #20 measured a real 48 kHz mic with no resample and
        // still found rxWastedShift 0: the low 8 bits of our int24 are real
        // entropy, so no bit-exact coder can drop them. If the device declares
        // sampleSize 16, that entropy is Chrome's float processing rather than
        // microphone signal — which would make a 16-bit lane lossless with
        // respect to the DEVICE while halving the lane. Chrome reports 16 for
        // the fake device (testbed/bitdepth.mjs); real hardware is unmeasured.
        ? pick(at.getSettings(), ['sampleRate', 'sampleSize', 'channelCount', 'echoCancellation', 'noiseSuppression', 'autoGainControl', 'latency'])
        : null,
      degradedVideo,
      // Task #37: the ladder's decision is part of the capture record, so a
      // clamped session can never be mistaken for an unclamped one.
      asked: { w: videoConstraints.width.ideal, h: videoConstraints.height.ideal, fps: videoConstraints.frameRate.ideal },
      tier: devTier,
    });
    tel?.log('devtier', { tier: devTier, why: devTierWhy, ladder: DEV_LADDER ? 1 : 0, ceiling: cap ?? null, measure: DEV_MEASURE ? 1 : 0 });
  }, 'capture.log');

  return stream;
}

const pick = (o, keys) => Object.fromEntries(keys.filter((k) => k in o).map((k) => [k, o[k]]));

// Whether the WB/focus lock has been applied. EXPOSURE IS NEVER LOCKED — this
// is the root fix for the Android dimming reports (2026-08-04, user directive
// "fixed from root, not a patch"). History: to hide auto-exposure hunting
// (tell 9) the app used to set exposureMode:'manual', and on lock-hostile
// Androids manual mode collapses to a dark gain default (measured on the M13:
// luma 101 with AE, 16 locked — gain, not exposure length). Three generations
// of defensive machinery grew around that decision (an 8 s verify-and-revert,
// verified relocks, watchdog unlock cures) and every gap in it was a dark
// call. The root cause was the decision itself: brightness belongs to the
// camera's AE for the whole call. White balance and focus stay locked —
// their hunting is a tell too, and neither can dim a picture. The only
// deliberate exception is low-light mode, which sets manual exposure IN THE
// DARK to buy frame rate (measured, m13-diagnosis session 4) and always
// restores continuous on exit.
let camLocked = false;
/** Newest luma-watchdog reading, or null if the watchdog has nothing yet. */
const lumaNow = () => (lumaWin.length ? lumaWin[lumaWin.length - 1].y : null);

async function lockCamera(stream) {
  // Let AWB/AF settle on the real scene first, then freeze them. (AE keeps
  // running forever — see the block comment above.)
  await new Promise((r) => setTimeout(r, 2500));
  await safeAsync(async () => {
    const t = stream.getVideoTracks()[0];
    if (!t) return;
    await t.applyConstraints({ whiteBalanceMode: 'manual', focusMode: 'manual' });
    camLocked = true;
    tel?.log('camlock', { ok: 1, exposure: 0, luma: lumaNow() != null ? +lumaNow().toFixed(1) : null });
  }, 'camlock');
}

/** Re-assert the WB/focus lock after any later constraint re-application —
 *  a constraint write can silently flip these back to continuous. Exposure is
 *  never touched here (root fix above), so there is nothing to verify. */
function relockCamera(track) {
  if (!camLocked || QS.get('nolock') === '1') return;
  safeAsync(async () => {
    await track.applyConstraints({ whiteBalanceMode: 'manual', focusMode: 'manual' });
    tel?.log('camlock', { ok: true, relock: 1 });
  }, 'camlock.relock');
}

// ── Luma / exposure watchdog (task #37) ──────────────────────────────────────
// On the M13 the camera's auto-exposure collapses seconds into use — the image
// goes DARK, not frozen, solo and in-call (m13-diagnosis, user-confirmed). Prime
// suspect is an AE feedback loop with the fullscreen bright self view. This
// watchdog reads a 64×36 downscale of the local camera at 1 Hz; when mean luma
// falls more than 40% below its own 5 s-ago baseline and stays there for 3 s
// while the camera is live, it tries an exposureCompensation nudge where the
// platform exposes one (feature-detected via getCapabilities), then re-asserts
// the WB/focus lock. The `lumadrop` event is logged either way — on platforms without
// the knob, the honest state IS the data. Kill switch: `?luma=0`.
const LUMA_ON = QS.get('luma') !== '0';
const lumaWin = []; // { t, y } — ~12 s ring of 1 Hz readings
let lumaTimer = null;
let lumaVideo = null;
let lumaCtx = null;
let lumaSustained = 0;
let lumaLastFire = -Infinity;
let lumaBlindTicks = 0; // ticks where no frame could be read at all (never a 0 reading)

function startLumaWatchdog(stream) {
  if (!LUMA_ON || lumaTimer) return;
  const track = stream?.getVideoTracks?.()[0];
  if (!track) return;
  safe(() => {
    lumaVideo = document.createElement('video');
    lumaVideo.muted = true;
    lumaVideo.playsInline = true;
    lumaVideo.autoplay = true;
    lumaVideo.style.cssText = 'position:absolute;left:-9999px;top:-9999px;width:2px;height:2px';
    document.body.appendChild(lumaVideo);
    lumaVideo.srcObject = new MediaStream([track]);
    // `autoplay` does NOT start a 2 px off-screen element on Chrome-Android, and
    // a paused element still reports readyState 4 and a real videoWidth — so the
    // old guard passed and drawImage copied a never-painted (black) element.
    // Measured: hidden element 0.0, visible element 96.2, VideoFrame 97.4, same
    // track and same second. Ask for play explicitly; the frame path below is
    // what actually carries this on Chromium, this is the fallback.
    // AbortError is play() interrupted by a newer load/srcObject swap — routine
    // on Safari, not a defect; it logged as an error 3× in room vjj-spil-qli.
    safeAsync(() => lumaVideo.play().catch((e) => { if (e?.name !== 'AbortError') throw e; }), 'luma.play');
    const c = document.createElement('canvas');
    c.width = 64;
    c.height = 36;
    lumaCtx = c.getContext('2d', { willReadFrequently: true });
    lumaTimer = setInterval(() => lumaTick(track), 1000);
  }, 'luma.init');
}

/**
 * Put a frame on the 64x36 canvas, or report that no frame could be had.
 *
 * Preference order matters and is not cosmetic. The source probe is already
 * pulling every camera frame for its fps count, so its newest VideoFrame is
 * free, always painted, and immune to autoplay policy. The <video> element is
 * the fallback for engines without MediaStreamTrackProcessor (Safari/Firefox).
 *
 * Returning false — rather than leaving a stale or black canvas — is the whole
 * point: a watchdog that cannot see must not vote. Reading 0 off a paused
 * element is what made low-light engage on a perfectly exposed picture.
 */
function lumaDraw() {
  const frame = srcProbe?.lastFrame;
  if (frame) {
    const ok = safe(() => {
      lumaCtx.drawImage(frame, 0, 0, 64, 36); // Chromium: VideoFrame is a CanvasImageSource
      return true;
    }, 'luma.draw.frame');
    if (ok) return true;
  }
  if (lumaVideo && !lumaVideo.paused && lumaVideo.readyState >= 2 && lumaVideo.videoWidth) {
    return safe(() => {
      lumaCtx.drawImage(lumaVideo, 0, 0, 64, 36);
      return true;
    }, 'luma.draw.el') ?? false;
  }
  return false;
}

function lumaTick(track) {
  safe(() => {
    if (!lumaCtx) return;
    if (track.readyState !== 'live' || !track.enabled) return;
    if (!lumaDraw()) {
      lumaBlindTicks++;
      // Say it once, loudly. Silence here previously looked identical to a dark room.
      if (lumaBlindTicks === 3) tel?.log('luma', { blind: 1, hasFrame: !!srcProbe?.lastFrame, paused: lumaVideo?.paused ?? null, rs: lumaVideo?.readyState ?? null });
      return;
    }
    const d = lumaCtx.getImageData(0, 0, 64, 36).data;
    let sum = 0;
    for (let i = 0; i < d.length; i += 4) sum += 0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2];
    const y = sum / (d.length / 4);
    const t = performance.now();
    lumaWin.push({ t, y });
    while (lumaWin.length && t - lumaWin[0].t > 12000) lumaWin.shift();
    // The baseline is this probe's own reading ~5 s ago — a self-referenced
    // drop, so slow scene changes (lights off at dusk) don't trip it, and a
    // collapse that started 3 s ago is compared against pre-collapse luma.
    let base = null;
    for (const s of lumaWin) {
      if (t - s.t >= 5000) base = s;
      else break;
    }
    if (!base || base.y < 8) { // no baseline yet, or already near-black (a 40% drop from 6 is noise)
      lumaSustained = 0;
      return;
    }
    lumaSustained = y < base.y * 0.6 ? lumaSustained + 1 : 0;
    if (lumaSustained >= 3 && t - lumaLastFire > 20000) {
      lumaLastFire = t;
      lumaSustained = 0;
      lumaNudge(track, y, base.y);
    }
  }, 'luma.tick');
}

async function lumaNudge(track, y, baseY) {
  await safeAsync(async () => {
    const caps = safe(() => track.getCapabilities?.(), 'luma.caps') ?? {};
    const ec = caps.exposureCompensation;
    // While low-light mode owns the exposure (manual exposureTime/iso), an
    // exposureCompensation nudge is meaningless — it only acts in continuous
    // mode. The drop is still logged; the nudge is the part that's suppressed.
    if (lowlightOn) {
      tel?.log('lumadrop', {
        luma: +y.toFixed(1),
        base: +baseY.toFixed(1),
        dropPct: Math.round((1 - y / baseY) * 100),
        expComp: ec ? 1 : 0,
        nudged: 0,
        suppressed: 'lowlight',
      });
      return;
    }
    let nudged = 0;
    let val = null;
    if (ec && Number.isFinite(ec.step)) {
      const cur = track.getSettings?.().exposureCompensation ?? 0;
      val = Math.min(ec.max ?? Infinity, cur + 2 * (ec.step || 0.5));
      if (val > cur) {
        await track.applyConstraints({ advanced: [{ exposureCompensation: val }] });
        nudged = 1;
      }
    }
    tel?.log('lumadrop', {
      luma: +y.toFixed(1),
      base: +baseY.toFixed(1),
      dropPct: Math.round((1 - y / baseY) * 100),
      expComp: ec ? 1 : 0,
      nudged,
      val,
    });
    if (nudged) relockCamera(track);
  }, 'luma.nudge');
}

// ── Source-frame probe, armed at JOIN (task #37) ─────────────────────────────
// telemetry.js's media-source block only exists once a negotiated sender is
// pulling from the track — on a solo session (or before the peer arrives) it
// reports nothing at all, which is exactly when the camera question needs
// answering: the M13 diagnosis was slowed because the probe armed at a phantom
// peer-join (t≈71 s) and the pre-call camera history was invisible. This probe
// counts the frames the camera actually hands us, from join, via a track
// processor — read-and-close costs no copies. `?srcprobe=0` disables.
const SRCPROBE_ON = QS.get('srcprobe') !== '0';
let srcProbe = null; // { track, reader, frames, t0, lastT, lastF }

function startSourceProbe(stream) {
  if (!SRCPROBE_ON || srcProbe || !('MediaStreamTrackProcessor' in window)) return;
  const track = stream?.getVideoTracks?.()[0];
  if (!track) return;
  safe(() => {
    const reader = new MediaStreamTrackProcessor({ track }).readable.getReader();
    // `mine`, not the `srcProbe` global: on camera re-acquire the global is
    // reassigned before this loop notices, and closing through it would either
    // throw or free the NEW probe's frame. The loop owns what it opened.
    const mine = { track, reader, frames: 0, t0: performance.now(), lastT: 0, lastF: 0, lastFrame: null };
    srcProbe = mine;
    (async () => {
      try {
        for (;;) {
          const { done, value } = await reader.read();
          if (done) return;
          mine.frames++;
          // Hold exactly ONE frame so the luma watchdog has something real to
          // read (see lumaDraw). Exactly one: the previous is closed on the same
          // tick, so this is a fixed cost, not a growing queue.
          mine.lastFrame?.close();
          mine.lastFrame = value;
        }
      } finally {
        mine.lastFrame?.close(); // cancel(), track end, or throw — the frame still gets freed
        mine.lastFrame = null;
      }
    })().catch(() => {});
    tel?.log('srcprobe', { armed: 1, at: 'join' });
  }, 'srcprobe.arm');
}

/** 2 s cadence from the stats loop: camera-delivered fps/frames, from join onward. */
function srcProbeSample() {
  if (!srcProbe) return;
  safe(() => {
    const now = performance.now();
    const dtMs = now - (srcProbe.lastT || srcProbe.t0);
    const df = srcProbe.frames - srcProbe.lastF;
    srcProbe.lastT = now;
    srcProbe.lastF = srcProbe.frames;
    const s = srcProbe.track.getSettings?.() ?? {};
    const fps = dtMs > 0 ? +((df / dtMs) * 1000).toFixed(1) : null;
    tel?.log('srcprobe', {
      fps,
      frames: srcProbe.frames,
      w: s.width ?? null,
      h: s.height ?? null,
      // The DENOMINATOR of the stepper's own decision. Without it a downstep in
      // prod cannot be judged: 15 delivered is starvation against an accepted
      // 30 and perfect health against an accepted 15.
      fr: s.frameRate ?? null,
      exp: s.exposureTime ?? null,
    });
    // The measured-ladder pipeline, in the only correct order (session 4):
    // a dead camera is revived first (it has no fps to judge), then low light
    // gets its exposure fix (a tier step while exposure-capped buys nothing),
    // and only then may the tier stepper judge what delivery remains.
    reviveEval(fps, dtMs);
    lowlightEval(fps, dtMs);
    devStepEval(fps, dtMs); // measured ladder: step capture down if delivery starves
  }, 'srcprobe.sample');
}

// ── Display refresh, told to the peer ────────────────────────────────────────
// Sent exactly the way face geometry is — at welcome and again at peer-joined — because
// it answers the same kind of question: something only the far end knows, that only this
// end can act on. They cannot see more frames per second than their screen draws.
const sendDisplayHz = () =>
  localHz
    // medianMs is what makes iqrMs interpretable: the gate is a RATIO, and an absolute
    // IQR cannot be judged without the interval it is a fraction of.
    ? send({ type: 'display', hz: localHz.hz, lockedPct: localHz.lockedPct,
             iqrMs: localHz.iqrMs, medianMs: localHz.medianMs,
             // Task #52, resolution half: the peer cannot present more pixels than
             // this panel has, so their SEND resolution is our display's business —
             // the same law as the refresh rate, one axis over. Physical px, not CSS.
             // Task #13: a phone lies here by telling the truth — its PANEL is
             // 1080×2410 but its DECODER cannot run that next to its own encode
             // (measured: 1089 dropped frames, 74 freezes in one session). A
             // phone asks for at most 720p-class pixels.
             ...(() => {
               let w = Math.round(screen.width * devicePixelRatio);
               let h = Math.round(screen.height * devicePixelRatio);
               if (IS_MOBILE) {
                 const k = Math.min(1, 1280 / Math.max(w, h), 720 / Math.min(w, h));
                 w = Math.round(w * k); h = Math.round(h * k);
               }
               return { w, h };
             })() })
    : false;
// Started at load. It needs ~2 s of animation frames and the lobby is at least that
// long, so by join time the answer is usually already in hand. The three sends cover
// every order these can complete in: `send()` no-ops until the socket is open, and this
// one covers the case where the measurement lands after both signaling hooks fired.
// ── Peer display SIZE, acted on (task #52, resolution half) ─────────────────
// Two consumers, different reliability classes:
//   1. The ENCODE ceiling (TAPE_CFG.width/height, mutated in place — tape.js's
//      fitSize reads cfg live and reconfigures within RESIZE_HOLD frames).
//      Deterministic: works on every engine, needs nothing from the camera.
//      Pixels above the peer's panel are bandwidth spent on detail nobody sees.
//   2. The CAMERA, moved toward the ceiling — attempt-and-verify, never assumed,
//      because the first getUserMedia may or may not be a hard cap depending on
//      engine and device (the fps analog IS a hard cap — lobby-ask-caps-the-call
//      — and the fake device ignores applyConstraints entirely, so this can only
//      be judged from the `capture-res` telemetry on real hardware).
let peerPxLong = null;
let peerPxShort = null;
// The sensor-moving half of the receiver-driven ceiling. Opt-in: see the long
// note at its guard below — it restarts Android's auto-exposure.
const CAM_RES = QS.get('camres') === '1';

// Absent peer info → the historical default. Known → never encode above their
// panel, never above 4K (encoder/decoder budget), never below 640×360 (a junk
// or tiny display must not turn the call to soup).
function sendResCeiling() {
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  // Task #13: whatever the peer's panel wants, a phone never ENCODES above
  // 720p-class — its own encode budget binds before the peer's display does.
  const hiW = IS_MOBILE ? 1280 : 3840;
  const hiH = IS_MOBILE ? 720 : 2160;
  if (!peerPxLong) return { w: Math.min(WANT_W, hiW), h: Math.min(WANT_H, hiH) };
  return { w: clamp(peerPxLong, 640, hiW), h: clamp(peerPxShort, 360, hiH) };
}

async function syncSendRes(why) {
  const ceil = sendResCeiling();
  const from = { w: TAPE_CFG.width, h: TAPE_CFG.height };
  TAPE_CFG.width = ceil.w;
  TAPE_CFG.height = ceil.h;
  if (from.w !== ceil.w || from.h !== ceil.h) {
    tel?.log('send-res', { why, from, to: ceil, peerPx: [peerPxLong, peerPxShort] });
  }
  // The fallback RTP lane reads the ceiling through tuneVideoSender (scale-down);
  // re-tune so a fallback already in progress picks it up too.
  for (const s of pc?.getSenders() ?? []) {
    if (s.track?.kind === 'video') tuneVideoSender(s, 'send-res');
  }
  // Camera, opportunistically — OFF BY DEFAULT (`?camres=1` opts in).
  //
  // Reported from a real Android device 2026-08-05, hours after this shipped: the
  // screen dimming of tasks #40/#41 was back. A mid-call `applyConstraints` naming
  // width/height makes the camera re-solve its format, and re-solving restarts
  // auto-exposure — the same mechanism both dimming fixes were about, reached from
  // a new direction. The encode ceiling above already collects essentially the whole
  // bandwidth win and cannot touch the sensor, so the sensor-moving half stays
  // behind a flag until it is measured on a real phone. Never re-enable it by
  // default on lab evidence: the fake camera has no auto-exposure to disturb, so
  // the lab cannot see this failure at all.
  if (!CAM_RES) return;
  // Skipped while the starvation ladder or low-light mode owns the capture ask —
  // their constraint is delivery, not presentation, and a re-solve here would fight
  // machinery that steps exactly once.
  const track = localStream?.getVideoTracks?.()[0];
  // "The ladder owns the ask" means it has STEPPED — devStepTier is seeded to the
  // STATIC tier at every join (line ~3370), so truthiness alone would disable this
  // path on every phone forever.
  const ladderStepped = devStepTier != null && devStepTier !== resolveDevTier();
  if (!track || track.readyState !== 'live' || ladderStepped || lowlightOn) return;
  const s0 = safe(() => track.getSettings(), 'sendres.settings') ?? {};
  const caps = safe(() => track.getCapabilities?.(), 'sendres.caps') ?? {};
  const tier = devCeiling();
  let wantW = Math.min(ceil.w, caps.width?.max ?? s0.width ?? ceil.w, tier?.w ?? Infinity);
  let wantH = Math.min(ceil.h, caps.height?.max ?? s0.height ?? ceil.h, tier?.h ?? Infinity);
  // Preserve the CAMERA's aspect inside that box. Asking the panel's box verbatim
  // invites the solver onto a different-aspect format (measured: an 800x600 ask
  // re-solved a 16:9 fake camera to 640x480) — fewer pixels than the box allows
  // and a shape change nobody asked for.
  const aspect = s0.width > 0 && s0.height > 0 ? s0.width / s0.height : 16 / 9;
  const even = (n) => Math.max(2, Math.round(n / 2) * 2);
  if (wantW / wantH > aspect) wantW = even(wantH * aspect);
  else wantH = even(wantW / aspect);
  wantW = even(wantW); wantH = even(wantH);
  // Within 10% on the long edge: leave it alone. Device formats are coarse and a
  // re-solve costs a keyframe and an AE settle; chasing exact pixels buys nothing.
  const longNow = Math.max(s0.width ?? 0, s0.height ?? 0);
  if (longNow > 0 && Math.abs(longNow - wantW) / wantW < 0.1) return;
  let applied = null;
  await safeAsync(async () => {
    await track.applyConstraints({
      width: { ideal: wantW },
      height: { ideal: wantH },
      frameRate: { ideal: s0.frameRate || 30 }, // keep the rate we have; never re-open that solve
      resizeMode: 'none',
    });
    applied = pick(track.getSettings(), ['width', 'height', 'frameRate']);
  }, 'sendres.apply');
  tel?.log('capture-res', { why, asked: { w: wantW, h: wantH }, before: pick(s0, ['width', 'height', 'frameRate']), applied, ok: applied ? 1 : 0 });
  if (applied) {
    relockCamera(track); // interaction rule: never fight camlock
    // WebKit's solver satisfies resolution first and will pay for it in frame
    // rate (measured: 1080p at 10 fps). The shipped remedy already exists.
    await repairFrameRate(track, s0.frameRate || 30);
  }
}

measureDisplayHz().then((r) => {
  localHz = r;
  tel?.log('display-hz', r ?? { hz: null, why: 'rAF never fired — backgrounded tab?' });
  sendDisplayHz();
  // AND RE-DECIDE THE RATE. This measurement takes ~120 animation frames — 0.8 s at 144 Hz,
  // 2.2 s at 54 — and `localHz` feeds `carrierCap`, our own send-side ceiling. The peer's
  // `display` message routinely arrives first, so the sync it triggers ran with localHz
  // still null and left the lane asking 72 while `targetFps()` had since settled on 32.
  // Measured as exactly that disagreement: `asked 72 fps` beside `send target 32 fps`.
  if (typeof syncTapeFps === 'function') syncTapeFps('our-display-hz');
  for (const sn of pc?.getSenders() ?? []) {
    if (sn.track?.kind === 'video') tuneVideoSender(sn, 'our-display-hz');
  }
});

// ── Detector wiring ──────────────────────────────────────────────────────────
// Decimation counters for the level trace — see the `level` branch below.
const levelTick = { local: 0, remote: 0 };
// 5 → ~4 Hz, which is enough to see a room but not enough to see a jitter-buffer underrun:
// a dip that lasts 100 ms falls between samples, and a floor that is briefly wrong looks
// like a floor that was never wrong. `?trace=1` drops it to 1 (the full 20 Hz) for a
// diagnostic run. Not the default because it is 20× the log volume.
const LEVEL_EVERY = new URLSearchParams(location.search).get('trace') ? 1 : 5;

// ── Room-noise-ceiling honesty (DESIGN.md §17.1) ─────────────────────────────
// The ~200 ms breath head start (§3.1 lever 1) only exists if the room is quiet enough
// for a breath to clear it. §17.1 measured the window shutting at "around -45 dBFS of
// broadband room noise" — stated on the fixture labels. The fixtures' labels run ~4 dB
// hot (their roomTone() gain, not the detector: ffmpeg astats reads the -48 fixture at
// -51.9, the -40 at -43.9), and the detector's tracked floor matches the true RMS within
// 0.3 dB (-52.2 and -44.3 respectively, floor.mjs). In the units the app actually sees,
// the threshold is therefore -49 dBFS: 2.8 dB above the still-usable quiet room's floor,
// 4.7 dB below the not-usable office's, both margins ~10× the floor's own wobble (±0.3 dB).
const FLOOR_HI_DB = Number(new URLSearchParams(location.search).get('floorhi') ?? -49);
const FLOOR_HI_HYST_DB = 3; // clear 3 dB under the set point so a borderline room can't flap
const FLOOR_HI_HOLD = 40; // consecutive level events (≈2 s at the ~20 Hz cadence) before a change
let floorHigh = false;
let floorHighN = 0;

// Task #38 §6: the loud-room condition is STATE, so it shows as an ambient icon
// at the edge of the frame. The sentence still exists, verbatim — it is just the
// icon's EXPANDED state now instead of a permanent amber banner. The banner sat
// on the other person's forehead in cover fit and demanded reading mid-sentence,
// which is precisely the cognitive-load channel this redesign is emptying.
let floorPulsed = false;
let floorCollapse = null;

function setFloorHigh(on, floorDb) {
  floorHigh = on;
  safe(() => {
    const icon = $('floorIcon');
    icon.classList.toggle('on', on);
    if (on) {
      // One pulse on first fire, then it settles to static. A thing that
      // pulses forever is spending attention it did not earn.
      if (!floorPulsed) {
        floorPulsed = true;
        icon.classList.add('pulse');
        haptic();
      }
    } else {
      icon.classList.remove('pulse');
      clearTimeout(floorCollapse);
      $('floorHint').classList.remove('on'); // condition gone, explanation goes with it
    }
  }, 'floor.ui');
  tel?.log('floor-high', {
    on: on ? 1 : 0,
    floorDb: floorDb == null ? null : +floorDb.toFixed(1),
    thresholdDb: FLOOR_HI_DB,
  });
}

/** Put the loud-room explanation away, from wherever it was dismissed. */
function collapseFloorHint() {
  safe(() => {
    clearTimeout(floorCollapse);
    $('floorHint').classList.remove('on');
  }, 'floor.collapse');
}

// Tap the icon to find out why it is there; it collapses itself after 6 s, on a
// second tap, on a tap on the card, or on any tap out in the picture.
safe(() => {
  const expand = () => {
    const el = $('floorHint');
    const open = !el.classList.contains('on');
    if (!open) return collapseFloorHint();
    el.classList.add('on');
    clearTimeout(floorCollapse);
    floorCollapse = setTimeout(() => safe(() => el.classList.remove('on'), 'floor.auto'), 6000);
    tel?.log('gesture', { what: 'floor-explain', on: 1 });
  };
  $('floorIcon').addEventListener('click', expand);
  $('floorIcon').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); expand(); }
  });
  $('floorHint').addEventListener('click', collapseFloorHint);
}, 'floor.bind');

function floorHighCheck(floorDb) {
  if (floorDb == null) {
    // The detector discarded its floor (a forced end) or hasn't calibrated yet. A claim
    // based on a floor that no longer exists is not defensible, so the hint goes with it.
    floorHighN = 0;
    if (floorHigh) setFloorHigh(false, null);
    return;
  }
  const trip = floorHigh ? floorDb < FLOOR_HI_DB - FLOOR_HI_HYST_DB : floorDb > FLOOR_HI_DB;
  floorHighN = trip ? floorHighN + 1 : 0;
  if (floorHighN >= FLOOR_HI_HOLD) {
    floorHighN = 0;
    setFloorHigh(!floorHigh, floorDb);
  }
}

function onDetector(side, ev) {
  safe(() => {
    if (ev.type === 'level') {
      // Decimated to ~4/s per detector rather than the worklet's 20/s. Logged at all
      // because §17.1's room-noise finding makes the noise floor a first-class result:
      // above roughly -45 dBFS the breath credit does not exist, and without a floor
      // trace a bad call is indistinguishable from a bad room. The `state` and hop
      // counters are here so a turn that never ends is visible as itself.
      const c = side === 'local' ? ++levelTick.local : ++levelTick.remote;
      if (c % LEVEL_EVERY === 0) {
        tel?.log('floor', {
          side,
          db: +ev.rmsDb.toFixed(1),
          floorDb: ev.floorDb == null ? null : +ev.floorDb.toFixed(1),
          state: ev.state ?? null,
          quiet: ev.quietHops ?? null,
          active: ev.activeHops ?? null,
        });
      }
      // The local floor is the one whose loudness buries OUR breaths — the remote
      // side's room is their problem to see, not ours to announce.
      if (side === 'local') {
        floorHighCheck(ev.floorDb);
        // Lane 0 lever 4's listening-stretch gate: the detector's own state is
        // the "are we mid-sentence" bit (it stays 'active' through the 350 ms
        // end-hang, so the gate cannot open while a turn is still closing).
        localDetState = ev.state ?? localDetState;
      }
      return;
    }
    // The speaking-dots indicator that consumed these events was removed
    // (2026-08-04, user directive); the events still feed the measurements below.

    // Use the detector's own sample-accurate time, not the time this handler ran.
    //
    // This is the difference between a usable measurement and an unusable one. An
    // `end` is only emitted once HANG_MS of quiet has accumulated, so it is *delivered*
    // ~350 ms after the moment it describes, while an `onset` is delivered within about
    // 5 ms. Timestamping on delivery therefore reorders them: the reply's onset lands
    // before the previous turn's end, `them.endAt` is still stale, and the transition is
    // recorded against the wrong reference. Measured on a real call this produced one
    // usable human gap out of seven, at 2229 ms, with twelve transitions thrown out as
    // lulls — all of it an artefact of `performance.now()`.
    //
    // `ctxTime` comes from the worklet, which converts the detector's sample index
    // against `AudioContext.currentTime`. Both detectors share one AudioContext, so the
    // local and remote timelines already have a common origin.
    const t = ev.ctxTime != null ? ev.ctxTime * 1000 : performance.now();
    tel?.log('onset', {
      side,
      type: ev.type,
      kind: ev.kind ?? null,
      // Logged so offline analysis can rebuild on the same timeline the live analyser
      // used. Without it, `analyze.mjs` would fall back to delivery order and
      // faithfully reproduce the bug described above.
      ctxMs: ev.ctxTime != null ? +(ev.ctxTime * 1000).toFixed(1) : null,
      leadMs: ev.leadMs != null ? +ev.leadMs.toFixed(1) : null,
      snrDb: ev.snrDb != null ? +ev.snrDb.toFixed(1) : null,
      floorDb: ev.floorDb != null ? +ev.floorDb.toFixed(1) : null,
      periodicity: ev.periodicity != null ? +ev.periodicity.toFixed(3) : null,
      durationMs: ev.durationMs != null ? +ev.durationMs.toFixed(1) : null,
      forced: ev.forced ? 1 : undefined,
      // Concealment near this event, on remote events only — the local mic cannot be
      // affected by it. `concealed` is the burst size when one landed within
      // CONCEAL_NEAR_MS; `concealAgeMs` is always stamped so analysis can pick its own
      // threshold rather than inheriting mine. Absent means no concealment has ever
      // happened, or the browser does not report it — unknown, not clean.
      concealed:
        side === 'remote' && concealAge() != null && concealAge() <= CONCEAL_NEAR_MS
          ? concealBurstN
          : undefined,
      concealAgeMs: side === 'remote' ? (concealAge() ?? undefined) : undefined,
      // Which defence fired. Without it a forced end reads as an anonymous 30-second turn
      // and the fix it points to is unguessable — measured, that was exactly the gap.
      reason: ev.reason ?? undefined,
    });

    if (side === 'local') {
      turns?.local_(ev, t);
      // Lane 0 lever 3: a LOCAL onset (breath or voice — the detector's event
      // is already one-per-activation, which is the "max one yield per onset"
      // bound) preempts Lane B for ~40 ms so this turn's first PCM frames
      // meet an empty pipe. Tracked for lever 4's listening gate either way.
      if (ev.type === 'onset') {
        lastLocalOnsetAt = performance.now();
        if (LANE0) {
          const d = tape?.yieldLaneB?.(L0_ONSET_YIELD_MS, 'onset') ?? 0;
          if (d) {
            lane0Stats.onsetYields++;
            tel?.log('lane0-yield', { why: 'onset', ms: d });
          }
        }
      }
    } else {
      turns?.remote_(ev, t);
    }
  }, `detector.${side}`);
}

function onTransition(tr, phase) {
  safe(() => {
    if (phase === 'new') tel?.log('transition', tr);
    else tel?.log('transition-update', { n: tr.n, openedWith: tr.openedWith, breathLeadMs: tr.breathLeadMs, gapToWordMs: tr.gapToWordMs });
    paintHud();
  }, 'transition');
}

// ── HUD ──────────────────────────────────────────────────────────────────────
function paintHud() {
  safe(() => {
    const s = turns?.summary();
    if (!s) return;
    const fmt = (v, unit = ' ms') => (v == null ? '—' : `${Math.round(v)}${unit}`);
    $('hPerceived').textContent = fmt(s.perceivedMedian);
    $('hHuman').textContent = fmt(s.humanMedian);
    // leadMedian / breathRate / breathRateLocal / usable-vs-total are no longer
    // ON SCREEN (they are rig instrumentation, not call UI) but are still
    // computed and still published through window.__tape.turns.summary().

    const a = lastStats.audio ?? {};
    const v = lastStats.video ?? {};
    const p = lastStats.pair ?? {};
    $('hRtt').textContent = fmt(p.rttMs);
    $('hPlayout').textContent = fmt(a.playoutMs);
    $('hVideo').textContent = v.w ? `${v.w}×${v.h} @ ${v.fps ?? '?'}` : '—';

    // Send bitrate and whether anything is capping our quality. Differenced here rather
    // than in sampleStats because bytesSent is cumulative and only the rate is meaningful.
    const s2 = lastStats.send ?? {};
    if (s2.bytesSent != null) {
      const now = performance.now();
      if (lastSend.bytes != null && now > lastSend.t) {
        const mbps = ((s2.bytesSent - lastSend.bytes) * 8) / ((now - lastSend.t) / 1000) / 1e6;
        if (mbps >= 0) sendMbps = mbps;
      }
      lastSend = { bytes: s2.bytesSent, t: now };
    }
    const why = s2.qualityLimitationReason;
    // `qualityLimitationReason` alone is not enough to call a call healthy, and this HUD used
    // to assume it was. This watchdog matters MORE now, not less, than when it was written for
    // the `maintain-resolution` default (#44 flipped that): the A/B caught an arm encoding 3 fps
    // for 48 s straight with `qualityLimitationReason` reading 'none' the whole time, so frame
    // rate against the camera's own rate is the only signal that sees the failure at all.
    // The original case: `maintain-resolution` spent frame rate *before* quality, so
    // behind a 3 Mbps ceiling the encoder truthfully reports 'none' — it got the bitrate it
    // asked for — while frame rate has fallen from 30 to 17 (§17.5). Green on a call running at
    // half rate is the exact failure this HUD exists to prevent.
    //
    // Comparing against the camera's own rate rather than a fixed 30 is what makes this usable:
    // Chrome's built-in fake camera runs at 20 fps and some real cameras drop to 24 in low
    // light, and neither is a fault worth colouring red.
    //
    // The threshold is 0.75 rather than 0.8 because the measured cases sat awkwardly around it:
    // behind a 3 Mbps ceiling one side ran 24 of 30 fps and the other 19 of 29. At 0.8 the first
    // lands exactly on the boundary, so a call hovering there would toggle the warning every
    // two seconds — and 24 fps is cinema rate, not a fault. 0.75 clears 24 fps and still catches
    // 19, which is where motion starts to read as broken.
    const src = lastStats.source ?? {};
    const starved = src.fps > 0 && s2.fps != null && s2.fps < src.fps * 0.75;
    const el2 = $('hSend');
    if (el2) {
      el2.textContent =
        sendMbps == null
          ? '—'
          : `${sendMbps.toFixed(1)} Mbps${why && why !== 'none' ? ` · limited: ${why}` : ''}` +
            (starved ? ` · ${Math.round(s2.fps)} of ${Math.round(src.fps)} fps` : '');
      el2.className = (why && why !== 'none') || starved ? 'bad' : '';
    }
    $('hFreeze').textContent = v.freezeCount != null ? `${v.freezeCount} (${Math.round((v.freezeMs ?? 0) / 100) / 10}s)` : '—';
    $('hConceal').textContent = a.concealmentEvents != null ? String(a.concealmentEvents) : '—';

    // The log-health line is gone from the call screen: a person on a call has
    // no use for "3 sent, 1 queued", and it was the last thing making telemetry
    // feel like a feature. It remains readable at window.__tape.tel.health.
  }, 'hud');
}

// ── Signaling ────────────────────────────────────────────────────────────────
const send = (m) => safe(() => {
  // Logged on both sides: a signaling message that vanishes between tx and rx is
  // indistinguishable from a peer that never answered, and that cost a week's hunting.
  tel?.log('ws-tx', { type: m?.type, rs: ws?.readyState });
  return ws?.readyState === WebSocket.OPEN && ws.send(JSON.stringify(m));
}, 'send');

/**
 * Apply the video sender's encoding parameters. Extracted from join()'s one-shot loop
 * because that loop iterates `pc.getSenders()` a single time, and the RTP video sender
 * that `fallbackToRtp` creates does not exist yet when it runs.
 *
 * MEASURED on deployment 32b9ca3a, real Brave x Playwright WebKit: the Brave side's
 * fallback sender reported `degradationPreference null, maxBitrate null, maxFramerate
 * null, scaleResolutionDownBy null` and sent 640x360@30, while the WebKit peer — whose
 * camera track was on the pc from the start and so WAS tuned — sent 1920x1080@9. One
 * call, two completely different send configurations, both ends worse than intended and
 * in opposite directions: one soft, one juddery.
 *
 * Safe to call after a fallback for exactly the reason the `!tapeFellBack` guard gives:
 * the setParameters pipeline rebuild only starves a LIVE lane-2 transform, and by then
 * `tape.stop()` has flipped that worker to bypass.
 */
function tuneVideoSender(s, why) {
  const vt = localStream?.getVideoTracks?.()[0] ?? null;
  // NOT THE LANE-2 CARRIER. Its track is a 320x180 canvas, not the camera, and it is a
  // CLOCK: one carrier tick carries one tape frame, so `maxFramerate = 30` on it caps the
  // delivered picture at 30 ticks minus what parity spends — measured 2026-08-03 as
  // `outbound 320x180@30` on the Brave side against `@49` on the untuned WebKit side, i.e.
  // our own tuning was the tighter of the two limits. Nothing else here applies to it
  // either: its pixels are discarded by the transform, so bitrate and degradation
  // preference are meaningless, and a runtime setParameters on this sender has killed the
  // transform outright in every timing previously measured.
  if (vt && s.track && s.track !== vt) {
    tel?.log('senderparams-skip', { why, reason: 'not-the-camera-track',
      kind: s.track.kind, label: String(s.track.label).slice(0, 40) });
    return;
  }
  safe(() => {
    const p = s.getParameters();
    // This held `maintain-resolution` on two arguments, and the A/B killed both.
    // The life-size argument — that a downscale would shrink the remote — is
    // MEASURED FALSE: `layout()` sizes from `peerGeom` millimetres, and the pixel
    // dimensions enter only as an aspect ratio, which uniform scaling leaves
    // invariant. The sharpness argument (§1: quality constant, time the shock
    // absorber) is real but points the wrong way once the link is tight, because
    // the shock is absorbed in the one dimension a human cannot help noticing.
    // Behind 1.2 Mbps: 3 fps held sharp, versus 30 fps at 640x360. See the
    // V_DEGRADE block near the top for the full matrix.
    p.degradationPreference = V_DEGRADE; // `?degrade=`; unset === 'maintain-framerate'
    p.encodings = p.encodings?.length ? p.encodings : [{}];
    // 12 Mbps, matching the §19 gate target rather than the 6 Mbps that was here.
    // 720p30 at 6 Mbps is roughly 0.22 bits per pixel, which is a good videoconference
    // and visibly not a recording; 12 Mbps doubles the headroom for the high-detail
    // frames that actually carry the "lossless" impression — hair, fabric, eyes.
    // The phase-1 gate measured 12 Mbps sustained at 150 ms RTT, so this is a rate the
    // transport has been shown to carry rather than a hopeful number.
    p.encodings[0].maxBitrate = 12_000_000;
    // A cap at the capture rate, not a floor — there is no floor API, and that is a real
    // gap rather than an oversight. `maintain-resolution` will trade frame rate away
    // without limit under pressure, and a 10 fps call reads as broken even at perfect
    // sharpness, so the shock absorber has no bottom that WebRTC will enforce for us.
    // Watching for it is the only option here: `framesPerSecond` is already in the stats
    // poll, and enforcing a bottom is the encoder's job in the custom path (§9).
    // No longer a constant. `targetFps()` takes the lowest of the ceiling, what the
    // PEER's display can present, and what our camera is actually delivering — so the
    // number here changes when the peer tells us their refresh rate, which is why
    // tuneVideoSender() is re-run from the 'display' signaling handler.
    const tf = targetFps();
    p.encodings[0].maxFramerate = tf.fps;
    // No scaling, ever. Any value but 1 silently defeats life-size rendering.
    //
    // MEASURED FALSE (high-motion A/B, 2026-08-02). `layout()` computes the life-size width at line ~293 as
    // `W = (peerGeom.headMm * cal.distMm/D_TARGET_MM * cal.pxPerMm) / peerGeom.headWidthFrac`
    // — physical millimetres and dimensionless fractions only. The decoded pixel
    // dimensions enter `layout()` in exactly two places: a `!vw || !vh` arm-the-mode
    // guard, and `H = W * (vh/vw)`, an ASPECT ratio that `scaleResolutionDownBy` leaves
    // invariant because it divides both dimensions equally. `peerGeom` carries
    // {eyeLineY, headWidthFrac, headMm} off the sender's `cal` — never a capture or
    // encode resolution. So downscaling changes sharpness, not rendered physical size.
    //
    // Task #52 (resolution half): no longer always 1. When the peer's display is
    // smaller than our capture, this lane — the plain-RTP fallback, where WebRTC owns
    // the encoder and TAPE_CFG's ceiling cannot reach — downscales to their panel.
    // `?scaledown=` (≠1) still forces a value for A/B work; the dynamic path only
    // ever DOWNscales (clamped ≥1: raising it above 1 on a matched display would
    // shrink below the panel, and <1 throws on some engines).
    const rc = sendResCeiling();
    const vs = vt?.getSettings?.() ?? {};
    const vShort = Math.min(vs.width ?? 0, vs.height ?? 0);
    const dynScale = vShort > 0 && rc.h > 0 ? Math.max(1, +(vShort / rc.h).toFixed(3)) : 1;
    const scaleDown = V_SCALEDOWN !== 1 ? V_SCALEDOWN : dynScale;
    p.encodings[0].scaleResolutionDownBy = scaleDown;
    s.setParameters(p)
      .then(() => tel?.log('senderparams', {
        maxBitrate: 12_000_000,
        contentHint: vt?.contentHint ?? null,
        degradationPreference: V_DEGRADE,
        maxFramerate: tf.fps,
        // The DECISION, not just its result: 'ceiling' / 'peer-display' / 'camera' /
        // 'forced', with the three inputs. A frame rate reported without saying which
        // of the three bound it cannot be diagnosed from telemetry alone.
        fpsWhy: tf.why,
        fpsInputs: { ceiling: tf.ceiling ?? null, peerHz: tf.peerHz ?? null, camFps: tf.camFps ?? null },
        // Whether the frames we send land evenly on the peer's refresh boundaries. A rate
        // that is fast and uneven looks worse than a slower even one, so a frame-rate
        // figure without this beside it cannot be judged.
        cadence: tf.cadence, evenOnPeer: tf.evenOnPeer,
        scaleResolutionDownBy: scaleDown,
        sendResCeil: [rc.w, rc.h],
      }))
      .catch((e) => tel?.log('senderparams', { error: String(e).slice(0, 80) }));
  }, `video-params-${why}`);
}

async function join(room) {
  const session = `${role ?? 'x'}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
  tel = new Telemetry({ room, role: 'pending', session });
  tel.log('session-start', {
    ua: navigator.userAgent.slice(0, 200),
    screen: [screen.width, screen.height],
    dpr: devicePixelRatio,
    viewport: [innerWidth, innerHeight],
    lang: navigator.language,
    cores: navigator.hardwareConcurrency ?? null,
  });

  // Task #51: the lobby already fetched this — reuse it instead of spending a
  // serial round trip here. 120 s freshness: TURN credentials are minted with
  // hours of TTL, the cap is just paranoia about a lobby left open overnight.
  const ice = await safeAsync(() => {
    const fresh = iceCache && Date.now() - iceCache.at < 120_000;
    if (!fresh) iceCache = { at: Date.now(), promise: fetch('/api/ice').then((r) => r.json()) };
    return iceCache.promise;
  }, 'ice');
  tel.log('ice-config', { p2pOnly: ice?.p2pOnly ?? true, servers: ice?.iceServers?.length ?? 0, cached: iceCache ? 1 : 0 });

  localStream = await getMedia();
  // Task #37: the camera probes arm at JOIN, not peer-join — the pre-call
  // camera history is where the M13's exposure collapse starts, and a probe
  // gated on the call being up was blind to exactly that window.
  devStepTier = resolveDevTier(); // the measured ladder starts where the static one landed
  startSourceProbe(localStream);
  startLumaWatchdog(localStream);
  // Task #52: the peer's display size can arrive BEFORE the camera exists (their
  // 'display' rides the welcome round; getMedia takes ~1 s — measured, sendres-diag
  // 2026-08-05: display at t=546 ms against a not-yet-assigned localStream, and it
  // is sent only once per socket). The ceiling half needs no camera; the camera
  // half re-runs here now that there is a track to move.
  if (peerPxLong) safe(() => syncSendRes('media-ready'), 'sendres.media-ready');

  $('preview').srcObject = localStream;
  syncArmState(); // whatever you armed on the first screen is how you arrive
  if (videoDegraded) {
    $('previewBadge').textContent =
      videoDegraded === 'none'
        ? "no camera found — you're in with audio only"
        : "camera is busy in another app (Zoom/Teams/another tab?) — you're in with audio only";
    tel?.log('join-novideo', { why: videoDegraded });
  }
  if (QS.get('nolock') !== '1') lockCamera(localStream); // not awaited — 2.5 s must not delay the call

  localMon = await safeAsync(() => attachDetector(localStream, 'local', (ev) => onDetector('local', ev)), 'mon.local');
  tel.log('detector', { side: 'local', up: !!localMon, sampleRate: localMon?.ctx?.sampleRate ?? null });

  // The RTCPeerConnection constructor is ALL-OR-NOTHING about iceServers: one URL
  // the engine dislikes and it throws, so the user gets "this browser blocked the
  // call engine" and no call at all — over a relay they never needed. Measured on
  // WebKit 26.5: it rejects every `?transport=` query we are handed, including
  // `turn:…?transport=udp`, which RFC 7065 explicitly allows. (Shipping Safari 27
  // accepts them — this is engine-parser strictness, not a bad config.) One fussy
  // parser anywhere should cost relay candidates, never the call, so try
  // progressively plainer configs and take the first that constructs.
  const iceTiers = [
    ['full', ice?.iceServers ?? []],
    // Same servers, query strings stripped — this is the tier WebKit accepts.
    ['no-query', (ice?.iceServers ?? []).map((s) => ({
      ...s,
      urls: [].concat(s.urls ?? s.url ?? []).map((u) => String(u).split('?')[0]),
    }))],
    // STUN only: no relay, but direct and reflexive candidates still work, which
    // is the overwhelming majority of calls.
    ['stun-only', (ice?.iceServers ?? [])
      .map((s) => ({ urls: [].concat(s.urls ?? s.url ?? []).filter((u) => String(u).startsWith('stun:')) }))
      .filter((s) => s.urls.length)],
    // Host candidates only. Same LAN still connects; better than a dead button.
    ['none', []],
  ];
  // Deadline, not a plain await: a browser that is slow to generate a key must
  // cost the call nothing. Losing the race only costs the stripes' coverage.
  sharedCert = await Promise.race([localCert, new Promise((r) => setTimeout(() => r(null), 800))]);
  tel.log('cert', { shared: !!sharedCert });

  let iceTier = null;
  let lastErr = null;
  for (const [name, servers] of iceTiers) {
    try {
      pc = new RTCPeerConnection({ iceServers: servers, bundlePolicy: 'max-bundle', ...certArg() });
      iceTier = name;
      break;
    } catch (e) {
      lastErr = e;
    }
  }
  if (!pc) {
    // Every tier failed, so this is not the ICE config — it is an insecure context
    // (http://) or an in-app browser (Telegram/WhatsApp/…) with WebRTC removed.
    // Say so in words, not a raw exception.
    throw new Error(
      'This browser blocked the call engine (WebRTC). ' +
        (isSecureContext
          ? 'If you opened this link inside another app, open it in Chrome or Safari directly.'
          : 'Open the https:// address, not http://.'),
      { cause: lastErr },
    );
  }
  if (iceTier !== 'full') {
    tel.log('ice-tier-fallback', { tier: iceTier, why: String(lastErr).slice(0, 120) });
  }

  // Lane 1 keeps the video track OFF the peer connection (video rides datachannels).
  // Lane 2 needs it ON — the RTP sender is the carrier whose payloads we replace.
  // No camera (busy/missing) → no carrier either: fall to a plain RTP audio call.
  const hasVideo = localStream.getVideoTracks().length > 0;
  const useTape = hasVideo ? (TAPE === 1 ? tapeSupported() && 1 : TAPE === 2 ? tapeRtpSupported() && 2 : 0) : 0;
  if (TAPE && !useTape) tel.log('tape-unsupported', { want: TAPE, secure: isSecureContext, hasVideo });
  for (const t of localStream.getTracks()) {
    if (useTape && t.kind === 'video') continue; // both lanes own the video path
    const sender = pc.addTrack(t, localStream);
    // Lane A owns the mic, but its Opus sender is kept as a negotiated HOT SPARE
    // rather than skipped. Nulling the track means no encoder and no RTP (0 bytes
    // measured), while the m-line still appears in the first offer as sendrecv —
    // so the fallback is a single replaceTrack on an m-line the peer already has.
    // The previous code did `continue` here, which is why a lane A failure of any
    // kind produced a silent call that could never recover.
    if (PCM_AUDIO && t.kind === 'audio') {
      pcmSpareSender = sender;
      sender.replaceTrack(null).catch(() => {});
    }
  }
  wantTape = useTape;
  // Lane 2 phase A: the carrier transceiver and its sender transform must be created
  // HERE — immediately after addTrack, before signaling setup. Bisected: the same
  // attach at 'welcome' left the transform hooked but starved; this timing flows at
  // full rate (?tapemin=1).
  if (useTape === 2) {
    // BEFORE prepareTapeRtp, not after: the carrier's tick ceiling is fixed at
    // captureStream() time and one tick carries one frame, so a cfg.fps that is still 30
    // here would cap the whole call at ~45 fps no matter what the lane asks for later.
    syncTapeFps('pre-carrier');
    tapePre = prepareTapeRtp(pc, localStream.getVideoTracks()[0], (t, d) => tel?.log(t, d), TAPE_CFG);
    if (!tapePre) wantTape = 0; // never got a transform: plain RTP call, say so once
  }
  // Lane 2's answerer normally needs no renegotiation at all now: the offerer's first
  // offer carries a recvonly slot that the answerer's pre-created carrier transceiver
  // matches (see 'tape.slot' in the welcome handler). This stays as the fallback for the
  // day that matching changes: renegotiate the carrier in as soon as an exchange
  // settles. Guarded to renegotiation only (remoteDescription set): the initial
  // addTrack/addTransceiver burst also fires negotiationneeded, and the first offer
  // belongs to the signaling flow, not to us.
  if (useTape === 2) {
    pc.onnegotiationneeded = () => {
      // Snapshot the transceiver table at every firing: a negotiationneeded loop
      // names its own driver this way (claim4 stormed ~1000 offers; the snapshot
      // showed which transceiver never settles).
      tel?.log('neg-needed', {
        sig: pc.signalingState,
        txs: pc.getTransceivers().map((t) => [t.mid, t.direction, t.currentDirection, t.stopped ? 1 : 0]),
      });
      // Lane 2 NEVER renegotiates. The claim leaves nothing to negotiate — the only
      // pending change is the neutralized orphan, which is harmless unassociated —
      // and processing a reoffer REBUILDS the answerer's receive pipeline without
      // the transform (measured, claim5: A's lane-2 receive died the moment B's
      // reoffer landed, 2 ms after the attach inside ontrack). The lane-2 fallback
      // needs no renegotiation either: it un-cripples the already-negotiated carrier.
      if (wantTape === 2) return;
      if (pc.remoteDescription && pc.signalingState === 'stable') safeAsync(() => offer(), 'renegotiate');
    };
  }

  // ?tapemin=1 — diagnostic, not a mode. The smallest possible transform attach (no
  // encoder, no ctl, no substitution: count frames and pass them through), inside the
  // real app environment. Splits "the app environment breaks transforms" from "tape.js
  // machinery breaks transforms" in one run.
  if (QS.get('tapemin') === '1') {
    safe(() => {
      const src = `
        postMessage({ type: 'boot' });
        onrtctransform = (e) => {
          const tf = e.transform ?? e.transformer;
          postMessage({ type: 'hooked', role: tf.options.role });
          const rd = tf.readable.getReader(), wr = tf.writable.getWriter();
          let n = 0;
          (async () => { for (;;) {
            const { done, value } = await rd.read();
            if (done) return;
            n++;
            if (n % 60 === 1) postMessage({ type: 'tick', role: tf.options.role, n });
            await wr.write(value);
          } })();
        };
      `;
      const w = new Worker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })));
      w.onmessage = (e) => tel?.log('tapemin', e.data);
      w.onerror = (e) => tel?.log('tapemin', { err: String(e.message || e).slice(0, 120) });
      const vs = pc.getSenders().find((s) => s.track?.kind === 'video');
      if (vs) vs.transform = new RTCRtpScriptTransform(w, { role: 'send' });
      // +tmdc=1: also create a datachannel pre-offer, as tape.js does for ctl.
      if (QS.get('tmdc') === '1') pc.createDataChannel('tapemin-dc', { ordered: true });
      // +tmenc=1: also consume the camera track with MSTP + a fixed-QP VideoEncoder,
      // as tape.js does — output discarded; testing whether the encoder or the track
      // processor is what starves the transform.
      if (QS.get('tmenc') === '1') {
        (async () => {
          const enc = new VideoEncoder({ output: () => {}, error: () => {} });
          enc.configure({ codec: 'avc1.640028', width: WANT_W, height: WANT_H, framerate: 30,
            latencyMode: 'realtime', bitrateMode: 'quantizer', avc: { format: 'annexb' } });
          const rd = new MediaStreamTrackProcessor({ track: localStream.getVideoTracks()[0] }).readable.getReader();
          let first = true;
          for (;;) {
            const { done, value: f } = await rd.read();
            if (done) return;
            if (enc.encodeQueueSize <= 4) { enc.encode(f, { keyFrame: first, avc: { quantizer: 24 } }); first = false; }
            f.close();
          }
        })().catch((e) => tel?.log('tapemin', { encErr: String(e).slice(0, 100) }));
      }
      // Deferred a tick: the app assigns its own pc.ontrack later in this same
      // function, and wrapping now would just get clobbered. ontrack cannot fire
      // before signaling round-trips, so a 0 ms defer is safe.
      setTimeout(() => {
        const prevTrack = pc.ontrack;
        pc.ontrack = (e) => {
          if (e.track.kind === 'video') {
            safe(() => { e.receiver.transform = new RTCRtpScriptTransform(w, { role: 'recv' }); }, 'tapemin.recv');
          }
          prevTrack?.call(pc, e);
        };
      }, 0);
    }, 'tapemin');
  }

  safe(() => {
    // ── Choose the codec instead of accepting the default ───────────────────────────────
    // Chrome negotiates VP8 first, which is a 2008 codec kept for universal compatibility.
    // At a fixed bitrate the newer codecs simply carry more picture: VP9 buys roughly 30-50%
    // over VP8 at the same quality, which at 12 Mbps is the difference between a very good
    // video call and something that reads as a recording. Nothing about the design needs VP8 —
    // this is 1:1 between two browsers we control, not a broadcast to unknown receivers.
    //
    // `setCodecPreferences` reorders rather than restricts: every codec the browser had is
    // still offered, just in our order, so a peer that cannot do VP9 still connects on VP8.
    // That matters more than the quality win — a codec preference must never be able to
    // prevent a call.
    const tr = pc.getTransceivers().find((t) => t.sender?.track?.kind === 'video');
    const caps = RTCRtpSender.getCapabilities?.('video');
    if (tr?.setCodecPreferences && caps?.codecs) {
      // The wanted codec sorts to the front; everything else keeps a sane fallback order behind
      // it. Matching is by substring on the mime type, and `h265` is checked before `h264`
      // because 'video/H265'.includes('h26') would otherwise be ambiguous to a careless test.
      const NAMES = ['av1', 'vp9', 'vp8', 'h265', 'h264'];
      // Lane 2's carrier must be VP8 regardless of the quality preference: VP8's
      // packetizer treats the payload as opaque bytes, H264's parses NAL units and
      // mangles foreign payloads to nothing (measured, testbed/rtplane.mjs). The
      // carrier codec costs no quality — its bytes are replaced with our fixed-QP
      // H.264 anyway. This must be THE one setCodecPreferences call: a second call,
      // like every other sender mutation near negotiation, risks rebuilding the send
      // pipeline without the attached transform in it.
      // Task #37: a device with no H.264 in its sender capabilities encodes in
      // software whatever is picked, and software VP9 measured 10× the realtime
      // budget on the M13 (323 ms/frame, m13-diagnosis). Software VP8 is 2–3×
      // cheaper per frame, so it is the preference there. H.264 stays first
      // whenever it exists, and an explicit ?codec= always wins — it is the
      // measurement override.
      const noH264 = !hasH264(caps.codecs);
      const wantHere = useTape === 2 ? 'vp8' : QS.get('codec') ? WANT_CODEC : DEV_LADDER && noH264 ? 'vp8' : WANT_CODEC;
      const rank = (c) => {
        const n = (c.mimeType || '').toLowerCase();
        const which = NAMES.find((k) => n.includes(k));
        if (!which) return 9; // rtx, red, ulpfec — must stay present or retransmission breaks
        if (which === wantHere) return 0;
        return 1 + NAMES.indexOf(which);
      };
      const ordered = [...caps.codecs].sort((a, b) => rank(a) - rank(b));
      tr.setCodecPreferences(ordered);
      tel?.log('codec-pref', {
        want: wantHere,
        first: ordered[0]?.mimeType ?? null,
        available: caps.codecs.map((c) => c.mimeType).filter((m) => !/rtx|red|ulpfec|flexfec/i.test(m)),
        noH264: noH264 ? 1 : 0,
        tier: devTier,
      });
    }
  }, 'codecpref');

  safe(() => {
    // `contentHint` is set on the track, not the sender, and it is the single cheapest
    // quality lever available. It works one layer below degradationPreference, on the
    // encoder's own rate-distortion choices rather than on WebRTC's adaptation logic,
    // so the two want to agree; they are flipped together.
    //
    // This was 'detail' — "quality is the constant, time is the shock absorber" (§1).
    // That bargain was made for a still face and it does not survive contact with a
    // moving one: measured, the detail/maintain-resolution pair collapses to 3 fps
    // behind a 1.2 Mbps ceiling while the framerate pair holds 30. Time is a terrible
    // shock absorber, because absorbing a shock in time is precisely what a human
    // being sees. Sharpness is the one that can give quietly.
    // `?hint=` overrides for measurement; unset === 'motion' (was 'detail').
    const vt = localStream.getVideoTracks()[0];
    if (vt) vt.contentHint = V_HINT;

    for (const s of pc.getSenders()) {
      // WebRTC's own per-encoding cap, which sits above the codec — distinct from the
      // `maxaveragebitrate` that `tuneAudio` puts in the fmtp line. A mixed-version
      // deployment accidentally ablated the two: one peer ran without the SDP munge, so its
      // offer carried no `maxaveragebitrate` at all, and the far end still reached 125 kbps
      // on the strength of this cap alone. So the two are redundant rather than jointly
      // required, and this is the one that actually moves Chrome.
      //
      // Both are still set. The fmtp parameter is the standards-defined way to ask (RFC 7587)
      // and is what a non-Chrome peer would honour, while this is the one measured to work
      // here; keeping both costs a line and covers an endpoint we have not tested.
      if (s.track?.kind === 'audio') {
        safe(() => {
          const p = s.getParameters();
          p.encodings = p.encodings?.length ? p.encodings : [{}];
          p.encodings[0].maxBitrate = A_KBPS * 1000;
          s.setParameters(p)
            .then(() => tel?.log('audioparams', { maxBitrate: A_KBPS * 1000 }))
            .catch((e) => tel?.log('audioparams', { error: String(e).slice(0, 80) }));
        }, 'audio-params');
        continue;
      }
      if (s.track?.kind !== 'video') continue;
      // Lane 2's carrier sender belongs to tape.js, which needs the opposite settings
      // (scaled-down clock, deferred). Worse than the conflict: ANY setParameters near
      // negotiation rebuilds Chrome's send pipeline without the attached transform in
      // it — hooked but starved forever (measured, rtplane.mjs --applike bisection).
      // This loop was the third pipeline-rebuilder found on this sender; skip it.
      //
      // `!tapeFellBack` was unreachable in the state it describes: this loop runs once,
      // inside join(), and a fallback happens later — measured at t+1.36 s for a WebKit
      // peer. So the RTP sender that fallbackToRtp creates was NEVER tuned. It now
      // re-runs from there via tuneVideoSender(), which is safe at that point precisely
      // because the lane is dead and its transform has been flipped to bypass.
      if (wantTape === 2 && !tapeFellBack) continue;
      tuneVideoSender(s, 'join');
    }
  }, 'sender-params');

  pc.ontrack = async (e) => {
    // `ontrack` fires once per track — audio, then video — and the two land in the
    // same tick. Guarding on `remoteMon` alone does not work, because it is only
    // assigned *after* the await below: both invocations get past the check before
    // either assignment happens, two detectors end up on one stream, and every remote
    // event is reported twice. A doubled event stream is worse than a missing one,
    // because it still looks like data. So claim the slot synchronously, before any
    // await can yield.
    // Lane 2's receive transform must be installed HERE, synchronously, before the
    // guard and before any await — measured (rtplane.mjs): attached even a few
    // microtasks after ontrack, Chrome routes every frame around it. This runs on
    // every ontrack because audio and video arrive as separate track events and the
    // once-guard below belongs to the detector, not to us.
    if (tape && wantTape === 2 && e.track.kind === 'video') {
      safe(() => tape.attachReceiver(e.receiver), 'tape.attach-receiver');
    }
    // A transceiver added with addTransceiver(track) — which is how the lane's
    // carrier is created — is sendonly and carries NO stream, so its track lands
    // here with `e.streams` empty. That is fine while the lane is up, because the
    // carrier's decoded output is never shown. It stops being fine the moment the
    // SENDER falls back to RTP: the camera then rides that same carrier sender,
    // and a receiver that only ever reads `e.streams[0]` has a live video track it
    // will never find. Measured on the mismatched pair — B's `#remote` held one
    // audio track while B's own getReceivers() listed a live video receiver.
    //
    // Hoisted above the once-guard on purpose: audio and video arrive as separate
    // events, and by the time the video one lands the guard has already returned.
    if (e.track.kind === 'video' && !e.streams.length) {
      rtpVideoTrack = e.track;
      if (!tape) safe(() => attachRemoteMedia(), 'rtp.streamless-video');
    }
    if (remoteAttaching || remoteMon) return;
    remoteAttaching = true;
    const stream = e.streams[0];
    rtpStream = stream; // kept for lane-2 fallback: the carrier becomes the picture
    // Lane A: there IS no remote audio track — the pc carries video (and the
    // carrier) only. No <audio> sink, no MediaStreamAudioSourceNode: the
    // playout worklet IS the far end's detector and its own sink (pcm.js).
    // What remains here is the picture and the connected-state UI.
    if (PCM_AUDIO) {
      if (!tape) attachRemoteMedia();
      peerArrived();
      setStatus('connected');
      armLaneWatchdog();
      armPcmWatchdog();
      layout();
      return;
    }
    // In tape mode the RTP stream carries audio only and `#remote` is already showing
    // the decoded video from the custom lane. Assigning here would replace a stream that
    // has picture with one that does not. The audio still plays: it is attached below
    // via the detector's own graph, and an <audio> sink keeps the element's behaviour.
    if (tape) {
      let sink = $('remoteAudio');
      if (!sink) {
        sink = document.createElement('audio');
        sink.id = 'remoteAudio';
        sink.autoplay = true;
        document.body.appendChild(sink);
      }
      sink.srcObject = stream;
    } else {
      attachRemoteMedia();
    }

    safe(() => {
      for (const r of pc.getReceivers()) {
        // Lane 2's carrier receiver carries our transform; ANY property write on it
        // rebuilds the receive pipeline around the transform (same measured behaviour
        // as setParameters on the sender — hooked but starved). The carrier's jitter
        // buffer settings are also irrelevant: its decoded output is never rendered.
        if (wantTape === 2 && r.track?.kind === 'video') continue;
        // The cheapest real latency win available on stock WebRTC: tell the receiver
        // to hold as little as it can get away with. Chromium honours this; others
        // ignore it harmlessly.
        if ('playoutDelayHint' in r) r.playoutDelayHint = 0;
        // `playoutDelayHint` is Chrome's legacy non-standard hint; `jitterBufferTarget` is the
        // standards-track request for the same thing, in milliseconds. Measured playout was
        // still holding 26-36 ms of audio with only the legacy hint set, so the hint is not
        // getting everything that is available.
        //
        // The reason to check rather than just set it is that it trades against §17.1: a
        // shorter buffer means more concealment under loss, concealed audio is broadband and
        // aperiodic, and that is the onset detector's own signature for a breath. Buying
        // latency here could have cost the measurement this project exists to make.
        //
        // Measured at 1% loss / 80 ms RTT / 15 ms jitter, three runs each side (§17.4):
        // concealed samples per lost packet 961 without it, 924 with, over 142 lost packets.
        // Flat. The risk does not materialise. Latency moved 56.4 -> 51.9 ms mean but the
        // ranges overlap heavily, so that part is within noise and is not the reason this is
        // on — the reason is that it costs nothing and it is the standards-track way to
        // express an intent the line above already declares.
        //
        // `?jbt=` (empty) restores Chrome's own default, which is the arm this was measured
        // against; `?jbt=50` or any other value sets it explicitly.
        if (JBT !== null && 'jitterBufferTarget' in r) r.jitterBufferTarget = JBT;
      }
      tel.log('playout-hint', { applied: true, jitterBufferTarget: JBT });
    }, 'playout');

    // `audible: true` — a remote MediaStream that isn't also sunk to an element
    // never flows in Chromium, and the detector would sit silent forever. That
    // failure is indistinguishable from the peer not speaking.
    remoteMon = await safeAsync(
      () => attachDetector(stream, 'remote', (ev) => onDetector('remote', ev), { audible: true }),
      'mon.remote',
    );
    tel.log('detector', { side: 'remote', up: !!remoteMon });
    safe(() => startConcealProbe(), 'conceal.start');

    peerArrived();
    setStatus('connected');
    // Media is flowing at the RTP level as of now; if the lane has nothing to
    // show a few seconds from here, it never will.
    armLaneWatchdog();
    armPcmWatchdog();
    layout();
  };

  pc.onicecandidate = (e) => e.candidate && send({ type: 'ice', candidate: e.candidate });
  pc.oniceconnectionstatechange = () => {
    tel.log('ice-state', { state: pc.iceConnectionState });
    if (pc.iceConnectionState === 'failed') {
      setStatus('connection lost — reconnecting…');
      recoverCall('ice-failed'); // task #50: was a status string telling the user to do this
    }
    if (pc.iceConnectionState === 'disconnected') {
      setStatus('reconnecting…');
      // 'disconnected' recovers by itself after a blip; 'failed' can take 15 s+
      // to be declared. A sustained disconnect IS the walk-out-the-door case —
      // escalate after 5 s instead of waiting for the browser's verdict.
      clearTimeout(recoverTimer);
      recoverTimer = setTimeout(() => recoverCall('ice-disconnected'), 5000);
    }
    if (pc.iceConnectionState === 'connected' || pc.iceConnectionState === 'completed') {
      clearTimeout(recoverTimer);
      recoverTimer = null;
      setStatus('connected');
    }
  };
  pc.onconnectionstatechange = () => {
    tel.log('pc-state', { state: pc.connectionState });
    // DTLS is up exactly here, so this is the first moment the certificates exist.
    if (pc.connectionState === 'connected') refreshSafetyCode();
  };

  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  // Declare which video transport this end came up on, so the room can tell each
  // side what the other can do. It goes on the URL rather than in a message
  // because the answer is needed at `welcome`, which is the first thing the
  // socket delivers. `wantTape` is already final by here: the lane's own support
  // check ran during pc setup, so this is what we ARE running, not what we hope.
  // `sid` is this TAB's stable identity (survives the recovery reload —
  // sessionStorage is per-tab). Its one job is ghost eviction: a phone that
  // loses its network mid-call leaves a socket the room still counts as OPEN
  // (nothing ever closed it), and the phone's own rejoin then 409s against its
  // own corpse. Measured on the M13 WiFi-cut, 2026-08-05: the rejoin's upgrade
  // failed once and the call was dead forever. The room evicts the old socket
  // with the same sid before counting occupants.
  const sid = safe(() => {
    let s = sessionStorage.getItem('tape.sid');
    if (!s) { s = crypto.randomUUID(); sessionStorage.setItem('tape.sid', s); }
    return s;
  }, 'join.sid') ?? '';
  ws = new WebSocket(
    `${proto}//${location.host}/api/room/${encodeURIComponent(room)}/ws?lane=${wantTape}&pcm=${PCM_AUDIO ? 1 : 0}&sid=${encodeURIComponent(sid)}`,
  );
  // A room already holding two people rejects the upgrade with 409 — the room
  // DO caps at 2 by design, which IS the admission model (§7 item 32): the link
  // is the key, and the only gate is that a 1:1 call holds one pair. The
  // browser exposes no status code for a failed upgrade, only an error event,
  // so we cannot assert the reason — but failing in a second beats stalling for
  // the full twelve, and naming the likeliest cause beats "signaling timeout".
  let wsOpened = false;
  ws.addEventListener('open', () => { wsOpened = true; });
  // A pre-open failure has two very different causes the browser won't
  // distinguish: the room's 409 (full) and no network at all. Room vjj-spil-qli
  // (2026-08-06): a phone whose radio had just died was told the call "may
  // already have two people in it" — wrong, and it points the user at the
  // other person instead of their own connection. navigator.onLine is the one
  // signal we have; false is trustworthy (true is not).
  const preOpenErr = () => new Error(navigator.onLine === false
    ? 'no internet connection — check WiFi or mobile data'
    : 'this call may already have two people in it');
  ws.onclose = () => {
    tel.log('ws-close', { opened: wsOpened ? 1 : 0 });
    if (!wsOpened) wsPreOpenFail?.(preOpenErr());
    // Task #50: a mid-call socket close is the first symptom of a network flip
    // (it dies faster than ICE notices). recoverCall's own guards keep lobby
    // closes, deliberate leaves, and rejected joins out of here.
    if (wsOpened) recoverCall('ws-close');
  };
  ws.onerror = () => {
    tel.log('ws-error', { opened: wsOpened ? 1 : 0 });
    if (!wsOpened) wsPreOpenFail?.(preOpenErr());
  };
  ws.onmessage = async (ev) => {
    await safeAsync(async () => {
      const m = JSON.parse(ev.data);
      tel?.log('ws-rx', { type: m?.type, sig: pc?.signalingState });
      if (m.type === 'welcome') {
        role = m.role;
        tel.role = role;
        tel.log('role', { role, peerPresent: m.peerPresent });
        // §10: the room Durable Object is the sole time authority. Its epoch
        // arrives in the welcome as an additive field (older clients ignore
        // it); local wall at arrival gives each peer a coarse mapping, biased
        // by the one-way ws delay — reported as an estimate, not truth.
        welcomeAtMs = performance.timeOrigin + performance.now();
        sessionEpochUs = m.session_epoch_us ?? null;
        if (PCM_AUDIO) tel.log('session-epoch', { epochUs: sessionEpochUs, welcomeAtMs: +welcomeAtMs.toFixed(1) });
        setStatus(m.peerPresent ? 'connecting…' : 'waiting for the other person');
        sendDisplayHz();
        laneAgree(m.peerLane, 'welcome');
        pcmAgree(m.peerPcm, 'welcome');
        // Interpreter rides beside the call, never inside it (Law 0): a
        // failure here logs and vanishes, the call proceeds untouched.
        // ?xlate= auto-starts (the rig's path); people use the 🌐 button.
        if (XLATE_LANG) void xlateStart(false);
        // Before any offer: `a` creates the tape channels so they are in the first SDP,
        // `b` only arms its listener. Creating a channel after the offer would need a
        // renegotiation round trip before video could start.
        //
        // `!tapeFellBack` is load-bearing. When the second peer to join is the lane
        // end, its own `welcome` is the message that tells it the incumbent cannot
        // run the lane, so `laneAgree` above has already torn the lane down — and
        // this line would build a brand new one two statements later. Measured: the
        // second joiner came up `fellBack: true, running: true`, re-created
        // `#remoteCanvas`, and both ends went black again. `wantTape` deliberately
        // stays 2 through all of this; it still means "this pc has a carrier
        // transceiver", which the SDP munge and the setParameters skip both rely on.
        if (wantTape && !tapeFellBack) startTape(role === 'a');
        // Lane A's channel rides the same first offer (synchronously created above
        // the offer call — see startPcm). The stripe pcs (pairs > 1) share the
        // join-time /api/ice config.
        // `!pcmFellBack` for the same reason `!tapeFellBack` guards startTape above:
        // for the second joiner, `welcome` is the message that reveals the mismatch,
        // so pcmAgree has already fallen back three lines up and this would build the
        // lane right back.
        if (PCM_AUDIO && !pcmFellBack) {
          pcmIceServers = ice?.iceServers ?? [];
          startPcm(role === 'a');
        }
        // TIME_SYNC starts when the ctl channel opens (avsync.onCtlOpen above);
        // it is constructed here so both roles share one instance.
        if (AV_SYNC && wantTape === 2 && tape) {
          tsync = initTimeSync({
            epochUs: sessionEpochUs,
            welcomeAtMs,
            // `tape?.` not `tape.` — the optional call guarded the METHOD and not the
            // null object, so once the lane fell back this threw on every 5 Hz tick for
            // the rest of the call. Measured on the deployed build: 182 and 199
            // unhandled exceptions in 40 s, on both ends of a real Brave x Chromium
            // call, invisible because no harness here had ever listened for `pageerror`.
            send: (o) => tape?.sendCtl?.(o),
            log: (t, d) => tel?.log(t, d),
          });
        }
        // Lane 2, offerer only: a recvonly video slot for the ANSWERER's carrier, so the
        // first offer already has an m-line for it and the reoffer that used to carry it
        // never needs to happen. That second negotiation lost the answerer's carrier at
        // real RTTs — measured 6/7 dead answerer carriers at RTT 80 vs 0/6 on loopback,
        // silently, no error event on either side; the answerer's tape encoder then pins
        // at its inFlight cap for the rest of the call. Chrome's m-section matching never
        // matched the answerer's pre-created sendonly carrier transceiver to an offered
        // *sendonly* section (probe3), but a recvonly one is its direction's complement,
        // so the answer carries the carrier sendonly and the race window — and one RTT of
        // answerer-picture startup — is gone. If the match ever fails, the answerer's
        // guarded reoffer below still adds the carrier exactly as before: this removes a
        // need, it adds no risk. A recvonly transceiver with no track costs nothing.
        if (wantTape === 2 && role === 'a') {
          safe(() => {
            const slotTx = pc.addTransceiver('video', { direction: 'recvonly' });
            // The slot must negotiate VP8 — the lane's payloads ride the carrier
            // opaquely and only VP8's packetizer leaves them intact (tape.js).
            // The app's codec-pref pass keys on sender.track and the slot has
            // none, so without this the OFFER leads with the engine's default
            // codec, and the negotiated codec follows the offer: Chromium's
            // default is VP8 (worked by luck), Safari's is H264 — measured
            // 2026-08-04 (task #44): Safari-first calls negotiated the slot as
            // H264, the answerer's frames arrived mangled, zero delivered, and
            // the whole lane fell back within 5 s. The answerer's own
            // setCodecPreferences in claimSlot does not override the offer's
            // ordering, so the offerer is the only place this can be pinned.
            const caps = RTCRtpReceiver.getCapabilities?.('video');
            if (slotTx.setCodecPreferences && caps?.codecs) {
              const rank = (c) => {
                const n = (c.mimeType || '').toLowerCase();
                if (n.includes('vp8')) return 0;
                if (/rtx|red|ulpfec|flexfec/i.test(n)) return 9;
                return 5;
              };
              slotTx.setCodecPreferences([...caps.codecs].sort((a, b) => rank(a) - rank(b)));
            }
            // Attach the receive transform NOW, at transceiver creation. The answer
            // builds this receiver's pipeline inside setRemoteDescription(answer) —
            // BEFORE ontrack fires — and an attach that lands after the build is
            // routed around forever (measured, claim6: hooked at ontrack, 0 recv
            // ticks, 0 lane frames, while the RTP level carried 22 MB). Same law as
            // the sender side: the pipeline reads .transform at build time only.
            tape?.attachReceiver(slotTx.receiver);
          }, 'tape.slot');
        }
        // Lane A stripes (§17.12): the offerer's N−1 extra pcs offer at exactly
        // the same moments the main pc does — gated on a peer being PRESENT,
        // exactly like the main offer. An ungated stripe offer fires into an
        // empty room and the once-guard (localDescription set) then starves the
        // real peer-joined round (measured, stripe3-loop: stripes never opened).
        if (m.peerPresent && role === 'a') {
          await offer();
          if (PCM_AUDIO && PCM_CFG.pairs > 1) await pcmStripeOfferAll();
        }
      } else if (m.type === 'peer-joined') {
        // Before anything else: an incumbent whose call is already spent must
        // become clean BEFORE negotiating — negotiating on a spent page is
        // what turned this into a ping-pong (the arriving peer reached
        // `peerArrived`, inherited a spent page of its own, and re-armed on
        // the NEXT arrival). It used to reload the whole page for that clean
        // slate, so one person's refresh flashed both screens. Now the reset
        // happens in place — same clean slate, no reload — and the NEW
        // socket's welcome drives negotiation from there. The reload re-arm
        // stays as the fallback if the in-place path ever fails.
        if (hadPeer) {
          if (!(await resetForNextPeer(room))) {
            hadPeer = true; // reset cleared it, but a failed reset IS a spent page — reArm's precondition
            // Forced: a failed reset has no second recovery behind it, so the
            // cooldown must not be allowed to turn this into silence.
            reArmForNewPeer(room, { force: true });
          }
          return;
        }
        sendDisplayHz();
        // The incumbent's own `welcome` reached an empty room, so this is the
        // first moment it can know what the arriving peer runs. Before the offer,
        // so a mismatched lane is already torn down when the SDP goes out.
        laneAgree(m.peerLane, 'peer-joined');
        pcmAgree(m.peerPcm, 'peer-joined');
        // A peer who joins after we turned translation on was not there for
        // the original xlate-on — repeat it so they come up translated too.
        if (xlateApi) send({ type: 'xlate-on' });
        if (role === 'a') {
          await offer();
          if (PCM_AUDIO && PCM_CFG.pairs > 1) await pcmStripeOfferAll();
        }
      } else if (m.type === 'offer') {
        sdpProbe('offer.recv', m.sdp?.sdp ?? m.sdp);
        await pc.setRemoteDescription(m.sdp);
        // Lane 2 answerer: put our carrier INTO this answer by claiming the offer's
        // carrier slot (tape.js claimSlot). This replaces the reoffer path, whose
        // answer was measured to vanish between relay and delivery at real RTTs.
        if (wantTape === 2 && role === 'b' && tapePre?.claimSlot) {
          await safeAsync(() => tapePre.claimSlot(m.sdp?.sdp ?? m.sdp), 'tape.slot-claim');
        }
        // The answer needs the same treatment as the offer, not because of symmetry for its
        // own sake but because these parameters describe what each end wants to *receive*:
        // the offer configures B's encoder and only the answer configures A's.
        const a = await pc.createAnswer();
        sdpProbe('answer.raw', a.sdp);
        a.sdp = tuneVideoCarrier(tuneAudio(a.sdp));
        sdpProbe('answer.munged', a.sdp);
        await pc.setLocalDescription(a);
        send({ type: 'answer', sdp: pc.localDescription });
      } else if (m.type === 'answer') {
        sdpProbe('answer.recv', m.sdp?.sdp ?? m.sdp);
        await pc.setRemoteDescription(m.sdp);
        sdpProbe('answer.applied', pc.localDescription?.sdp);
      } else if (m.type === 'ice') {
        await pc.addIceCandidate(m.candidate).catch(() => {});
      } else if (m.type === 'audio-fallback') {
        // The peer's lane A died. Its graph is both our playout and its capture,
        // so its failure is ours too — switch to Opus without re-broadcasting.
        fallbackToOpus(`peer-${m.why || 'fallback'}`, true);
      } else if (m.type === 'video-fallback') {
        // The peer's lane 2 died and it is now on plain RTP. Our carrier is a
        // clock to a decoder that no longer exists — worse, the peer RENDERS it
        // (a black 320x180 canvas). Fall back too; our fallbackToRtp puts the
        // camera on the carrier's negotiated m-line, which is exactly the track
        // the peer's fallback display is watching. Guarded on wantTape: a side
        // that never ran the lane has no carrier to un-cripple.
        if (wantTape) fallbackToRtp(`peer-${m.why || 'fallback'}`, true);
      } else if (m.type === 'reoffer') {
        // The answerer added a sender mid-call and cannot offer for it. Only 'a'
        // ever offers — that invariant is what keeps glare out of this codebase —
        // so the answerer asks instead of racing.
        if (role === 'a') await offer();
      } else if (m.type === 'pcm-offer') {
        // Lane A stripe answer (§17.12): one offer/answer round per stripe pc,
        // no munging (data-only), never renegotiated.
        const spc = pcmPcs[m.idx];
        if (spc && !spc.remoteDescription) {
          await spc.setRemoteDescription(m.sdp);
          const ans = await spc.createAnswer();
          await spc.setLocalDescription(ans);
          send({ type: 'pcm-answer', idx: m.idx, sdp: spc.localDescription });
        }
      } else if (m.type === 'pcm-answer') {
        const spc = pcmPcs[m.idx];
        if (spc && !spc.remoteDescription) await spc.setRemoteDescription(m.sdp);
      } else if (m.type === 'pcm-ice') {
        await pcmPcs[m.idx]?.addIceCandidate(m.candidate).catch(() => {});
      } else if (m.type === 'geom') {
        // Legacy peers still send face geometry; the life-size renderer that
        // consumed it is gone (2026-08-04).
      } else if (m.type === 'display') {
        // What the peer's screen can present. Their frames are OUR send problem, so
        // this arrives and immediately re-tunes our sender: anything above their
        // refresh rate is bandwidth spent on frames nobody can see.
        //
        // A wide rAF spread means their measurement was not locked to a real vsync
        // (measured: headless Chrome reports 77-81 Hz on a 60 Hz panel with intervals
        // swinging 7-26 ms). Trusting that number could RAISE our send rate on no
        // evidence, so a spread over 8 ms is recorded and then ignored.
        // Trust the median when most intervals agree with it. `lockedPct` is absent
        // from peers running the older build, and an absent field must not read as a
        // failing one, so those fall back to accepting the median.
        const trust = hzTrusted(m.hz, m.medianMs, m.iqrMs, m.lockedPct);
        peerHzRaw = m.hz ?? null;
        if (trust && m.hz > 0) peerHz = m.hz;
        // Task #52, resolution half. Orientation-agnostic (long/short edge) because a
        // portrait phone presenting a landscape stream contain-fits INSIDE its panel —
        // the long-edge box is the generous bound that is safe for both orientations.
        // Sanity bounds, not trust scoring: a display size needs no vsync to be real,
        // but a junk value must not become our encode ceiling (absent-field law: a
        // legacy peer without w/h changes nothing).
        if (Number.isFinite(m.w) && Number.isFinite(m.h) &&
            Math.min(m.w, m.h) >= 320 && Math.max(m.w, m.h) <= 16384) {
          peerPxLong = Math.round(Math.max(m.w, m.h));
          peerPxShort = Math.round(Math.min(m.w, m.h));
          syncSendRes('peer-display');
        }
        tel.log('peer-display', { hz: m.hz ?? null, lockedPct: m.lockedPct ?? null,
          iqrMs: m.iqrMs ?? null, medianMs: m.medianMs ?? null,
          relIqr: m.medianMs > 0 && m.iqrMs != null ? +(m.iqrMs / m.medianMs).toFixed(3) : null,
          trusted: trust ? 1 : 0 });
        for (const s of pc?.getSenders() ?? []) {
          if (s.track?.kind === 'video') tuneVideoSender(s, 'peer-display');
        }
        // The fallback sender is no longer the only consumer: lane 2 encodes on its own
        // clock and never looked at `maxFramerate` at all.
        syncTapeFps('peer-display');
      } else if (m.type === 'xlate-on') {
        // The other side pressed 🌐 — the interpreter is a property of the
        // call, so this side comes up too, listening in its own language.
        void xlateStart(true);
      } else if (m.type === 'xlate-off') {
        xlateStop(true);
      } else if (m.type === 'peer-left') {
        setStatus('they left');
        tel.log('peer-left', {});
        // Back to the self-view lobby while we wait for them (or someone
        // else): own camera fills the screen again, waiting overlay returns.
        safe(() => {
          $('waiting').classList.remove('gone');
          if (!videoDegraded) {
            $('selfFull').classList.remove('fading'); // undo a crossfade left mid-flight
            $('selfFull').classList.add('on');
          }
          stopElapsed(); // a clock still running over an empty room is a lie
          // §E.18: the bar re-pins for 10 s so "leave" is findable at the
          // moment someone is most likely to want it.
          showBar(true);
        }, 'peer.left');
      }
    }, 'ws.message');
  };
  await new Promise((res, rej) => {
    ws.onopen = res;
    wsPreOpenFail = rej; // the 409 "room full" path, wired at the handlers above
    setTimeout(() => rej(new Error('signaling timeout')), 12000);
  }).finally(() => { wsPreOpenFail = null; });

  turns = new TurnTaking(onTransition);
  joined = true;
  // A call survives anything except an explicit hang-up (user directive
  // 2026-08-04): refresh, crash, closed window — this record walks you back
  // in. Heartbeaten on the stats cadence so a record can be told apart from a
  // stale one left by a machine that died weeks ago; cleared in exactly one
  // place, the leave button.
  markLive(room);
  activeRoom = room; // recoverCall (task #50) reloads back into this room
  // THE transition: one class. No screen is shown or hidden, no element moves —
  // the button in the middle goes away, #waiting takes its place, and the two
  // call-only circles appear in the bar that was already there.
  $('call').classList.remove('pre');
  // The address bar becomes the shareable link, so a reload rejoins the same
  // room and the link is copyable from where people look for links. Existing
  // params (tape, pcmaudio, …) survive — a reload must not silently change the
  // configuration the call is being measured under.
  safe(() => {
    const u = new URL(location.href);
    if (MEET_RE.test(room)) {
      // Short form: the path is the room. Flags in the query string survive —
      // a reload must not silently change the configuration the call is
      // being measured under.
      u.pathname = `/${room}`;
      u.searchParams.delete('r');
    } else if (u.searchParams.get('r') !== room) {
      u.searchParams.set('r', room);
    }
    if (u.href !== location.href) history.replaceState(null, '', u);
  }, 'join.url');
  // Controls pinned for the first 10 s (§A.3): the icon vocabulary gets learned
  // once, at the only moment the user is looking for it, and then the screen
  // becomes a face.
  showBar(true);
  safe(() => applyMirror(localStream?.getVideoTracks?.()[0]), 'join.mirror');
  refreshFlipAffordance(); // videoDegraded is known by now, and it hides the control
  // Self-view lobby: until the peer's first track lands (peerArrived), the
  // user's own camera fills the screen. Skipped when video is degraded (no
  // camera) — the waiting overlay over black is the honest state then.
  safe(() => {
    if (!videoDegraded) {
      const sf = $('selfFull');
      sf.srcObject = localStream;
      sf.classList.add('on');
    }
  }, 'selffull');
  $('shareUrl').value = roomUrl(room);
  $('hud').classList.toggle('on', view.hud);
  applyChips();

  statsTimer = setInterval(async () => {
    markLive(room); // heartbeat: "this tab was in this call as of now"
    lastStats = await sampleStats(pc);
    tel?.log('stats', lastStats);
    srcProbeSample(); // task #37: camera-delivered fps, armed at join
    if (tape) tel?.log('tape-stats', tape.snapshot());
    if (pcm) tel?.log('pcm-stats', pcm.snapshot());
    if (tsync) tel?.log('timesync-stats', tsync.snapshot());
    stallPcmSample(); // §12–13: the HOLD classifier rides the 2 s stats cadence
    paintHud();
  }, 2000);
}

async function offer() {
  const o = await pc.createOffer();
  sdpProbe('offer.raw', o.sdp);
  o.sdp = tuneVideoCarrier(tuneAudio(o.sdp));
  sdpProbe('offer.munged', o.sdp);
  await pc.setLocalDescription(o);
  send({ type: 'offer', sdp: pc.localDescription });
}

// ?sprobe=1 — per-m-section direction/port dump at every signaling stage, for the
// answerer-carrier race. Separate from ?cprobe=1 (the 2 s getStats intervals): the
// regex pass is a few hundred microseconds at six moments, light enough to leave the
// race's timing untouched where the intervals were not.
function sdpProbe(stage, sdp) {
  if (QS.get('sprobe') !== '1' || !sdp) return;
  const secs = sdp.split(/^m=/m).slice(1).map((s) => {
    const port = s.split(' ')[1];
    const dir = ['sendrecv', 'sendonly', 'recvonly', 'inactive'].find((d) => new RegExp(`^a=${d}$`, 'm').test(s)) ?? '?';
    return `${s.split(' ')[0]}:${port}:${dir}`;
  });
  tel?.log('sdp-probe', { stage, secs, sig: pc?.signalingState });
}

// ── Controls (task #38) ──────────────────────────────────────────────────────
// Every in-call control is an icon on a dark-glass circle and nothing else is
// on the screen. The rules the rest of this section enforces:
//   · chrome hides, STATE does not (the mute badge outlives the bar);
//   · one filled element per screen (leave, and only leave);
//   · no destructive action without a second, deliberate tap;
//   · nothing appears under a finger that is already moving (no layout shift).
// The stats HUD is a debug affordance gated behind ?stats=1 (task #28): with
// the flag off there is no way to surface stats in the UI at all.
if (!STATS_UI) $('c-hud').style.display = 'none';

/** Short vibration on state changes the user caused. Never on auto-hide/show —
 *  the phone buzzing at something you did not do is noise, not feedback. iOS
 *  Safari has no vibrate at all; the visual state change stands alone there. */
const haptic = (ms = 8) => safe(() => navigator.vibrate?.(ms), 'haptic');

function applyChips() {
  for (const [k, id] of [['hud', 'c-hud']]) {
    $(id).dataset.on = view[k] ? '1' : '0';
    $(id).setAttribute('aria-checked', view[k] ? 'true' : 'false');
  }
  // A control with no track behind it must LOOK dead, not just act dead. An
  // audio-only join left the camera button looking live and silently doing
  // nothing, which reads as a broken app rather than a missing camera.
  // Before a call the stream underneath these controls is the preview's; after
  // it, the call's. Same buttons, same rule, one source of truth.
  $('mic').disabled = !armStream()?.getAudioTracks?.().length;
  $('cam').disabled = !armStream()?.getVideoTracks?.().length;
  $('hud').classList.toggle('on', view.hud);
  layout();
}
for (const [k, id] of [['hud', 'c-hud']]) {
  $(id).onclick = () => {
    view[k] = !view[k];
    applyChips();
    haptic();
    tel?.log('toggle', { what: k, on: view[k] });
  };
}

// ── More sheet (§B.12) ───────────────────────────────────────────────────────
// The four toggles that used to be always-visible chips. Off the face, one tap
// away, and closed by every gesture a person would try: the scrim, a swipe
// down, or Escape.
function setSheet(on) {
  safe(() => {
    $('moreSheet').classList.toggle('on', on);
    $('moreScrim').classList.toggle('on', on);
    if (on) {
      showBar(true);
      if (joined) refreshSafetyCode();
      // Devices come and go mid-call (a headset plugged in IS the reason the
      // sheet was opened); the pickers must say what is true right now.
      safeAsync(fillDevicePickers, 'sheet.devs');
    } else scheduleHide();
    tel?.log('gesture', { what: 'more-sheet', on: on ? 1 : 0 });
  }, 'sheet');
}
$('more').onclick = () => { haptic(); setSheet(!$('moreSheet').classList.contains('on')); };
$('moreScrim').onclick = () => setSheet(false);
addEventListener('keydown', (e) => { if (e.key === 'Escape') { setSheet(false); cancelLeaveConfirm(); } });
safe(() => {
  let y0 = null;
  const s = $('moreSheet');
  s.addEventListener('pointerdown', (e) => { y0 = e.clientY; });
  s.addEventListener('pointerup', (e) => {
    if (y0 != null && e.clientY - y0 > 40) setSheet(false);
    y0 = null;
  });
}, 'sheet.swipe');

// ── One bar, two phases ──────────────────────────────────────────────────────
// There is no second set of controls. The same mic / camera / flip / ••• circles
// serve the pre-join screen and the call; `#call.pre` only hides the two that
// need a call to act on (self view, leave). So the transition into a call moves
// nothing: the class comes off, the button in the middle is replaced by the
// waiting block, and every other pixel stays where it was.
//
// Which stream a control acts on is the ONLY thing that differs, and it is
// derived rather than remembered — `joined` is the single source of truth, so a
// pre-join mute cannot drift out of sync with the call's own state.
const armStream = () => (joined ? localStream : previewStream);
/**
 * Re-assert mic/camera state on a FRESH stream, and make a control with no
 * device behind it look dead rather than act dead. Called whenever the stream
 * underneath the buttons changes: switching camera or mic opens new tracks, and
 * new tracks are born enabled — without this, muting yourself and then changing
 * microphone quietly un-mutes you.
 */
function syncArmState() {
  safe(() => {
    const st = armStream();
    const a = st?.getAudioTracks?.() ?? [];
    const v = st?.getVideoTracks?.() ?? [];
    for (const t of a) t.enabled = $('mic').dataset.off !== '1';
    for (const t of v) t.enabled = $('cam').dataset.off !== '1';
    $('mic').disabled = !a.length;
    $('cam').disabled = !v.length;
  }, 'arm.sync');
}
// Pre-join camera switch: the setup sheet already owns a device picker, so
// flipping before the call is "advance the picker and re-open" rather than a
// second code path that could disagree with it. In-call it is the real track
// swap (see below).
function flipPreJoin() {
  return safeAsync(async () => {
    const sel = $('camSel');
    if (sel.options.length < 2) return;
    sel.selectedIndex = (sel.selectedIndex + 1) % sel.options.length;
    await sel.onchange?.();
  }, 'pre.flip');
}

// ── Mic / camera ─────────────────────────────────────────────────────────────
// State is colour and a slash, never a word. Red means "you are silent or dark
// to them" — parseable without reading. (The persistent mute badge was removed
// 2026-08-04, user directive — the mic circle itself is the only mute state.)

$('mic').onclick = () => {
  const t = armStream()?.getAudioTracks()[0];
  if (!t) return;
  t.enabled = !t.enabled;
  $('mic').dataset.off = t.enabled ? '0' : '1';
  haptic();
  tel?.log('toggle', { what: 'mic', on: t.enabled, pre: joined ? 0 : 1 });
};
$('xlate').onclick = () => {
  haptic();
  if (xlateApi) xlateStop(false);
  else void xlateStart(false); // no-op until in a call (needs role + mic)
};
$('cam').onclick = () => {
  const t = armStream()?.getVideoTracks()[0];
  if (!t) return;
  t.enabled = !t.enabled;
  $('cam').dataset.off = t.enabled ? '0' : '1';
  haptic();
  tel?.log('toggle', { what: 'cam', on: t.enabled, pre: joined ? 0 : 1 });
};
// ── Rear camera (§8) ─────────────────────────────────────────────────────────
// The control only exists where it can do something: two or more cameras, and a
// camera that opened at all. A flip button on a single-camera laptop is a lie
// about the hardware, and finding out by tapping it is worse than not having it.
async function refreshFlipAffordance() {
  await safeAsync(async () => {
    const cams = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === 'videoinput');
    $('flip').style.display = cams.length >= 2 && !videoDegraded ? '' : 'none';
  }, 'flip.affordance');
}

/**
 * Front cameras mirror, rear cameras never do — universal across every phone
 * app, and inverting it makes every sign and shirt logo in the scene read
 * backwards. facingMode is authoritative where the platform reports it; the
 * label is the fallback; and where neither says anything we keep whatever was
 * already true rather than guessing and flipping the picture for no reason.
 */
function applyMirror(track) {
  safe(() => {
    const s = track?.getSettings?.() ?? {};
    const label = track?.label ?? '';
    let rear;
    if (s.facingMode) rear = s.facingMode !== 'user';
    else if (/back|rear|environment/i.test(label)) rear = true;
    else if (/front|user|facetime/i.test(label)) rear = false;
    else rear = $('selfFull').classList.contains('rear');
    $('selfFull').classList.toggle('rear', rear);
    $('previewWrap').classList.toggle('rear', rear);
  }, 'mirror');
}

// The one mid-call camera-move path, shared by the flip button (which picks
// the NEXT camera) and the in-call picker (which picks a PARTICULAR one —
// user directive 2026-08-06). One path, or the two controls drift apart.
async function switchCameraTo(deviceId) {
  const old = localStream?.getVideoTracks()[0];
  const want = { ...captureConstraints(), deviceId: { exact: deviceId } };

  let nv = null;
  let fallbackUsed = 0;
  try {
    // Open the new sensor BEFORE closing the old one, so a refusal leaves
    // the call with a working camera instead of a black rectangle.
    nv = (await navigator.mediaDevices.getUserMedia({ video: want })).getVideoTracks()[0];
    // Take the old track OUT of the stream now (so the source probe below
    // cannot latch onto it) but leave the sensor RUNNING until replaceTrack
    // has actually landed — stopping it first parks an ended track on the
    // sender and the other person sees a frozen frame during the swap.
    if (old) localStream.removeTrack(old);
  } catch (e) {
    // Plenty of Android HALs refuse a second open while the first is live
    // (NotReadableError). Take the ~0.5 s black gap rather than lose the
    // flip — and log which path ran, because the gap is visible and a
    // silent difference between devices is the thing that wastes an hour.
    fallbackUsed = 1;
    tel?.log('camera-flip-retry', { name: e?.name ?? 'unknown' });
    if (old) { localStream.removeTrack(old); old.stop(); }
    nv = (await navigator.mediaDevices.getUserMedia({ video: want })).getVideoTracks()[0];
  }
  const fromId = old?.getSettings?.().deviceId ?? null;
  await adoptVideoTrack(nv);
  old?.stop(); // the wire is on the new sensor now; retire the old one
  applyMirror(nv);
  $('selfFull').srcObject = localStream;
  safe(() => localStorage.setItem('tape.cam', deviceId), 'flip.remember');
  haptic();
  tel?.log('camera-flip', {
    // from/to, or a flip log cannot say which camera it moved between —
    // which is the one question you ask it when a device misbehaves.
    from: fromId,
    to: deviceId,
    facingMode: nv?.getSettings?.().facingMode ?? null,
    fallbackUsed,
    settings: pick(nv?.getSettings?.() ?? {}, ['width', 'height', 'frameRate']),
  });
}

let flipBusy = false;
$('flip').onclick = () =>
  safeAsync(async () => {
    if (flipBusy) return;
    // Before the call there is no sender to renegotiate — flipping is re-opening
    // the preview on the next camera, which is what the picker already does.
    if (!joined) { haptic(); return void (await flipPreJoin()); }
    flipBusy = true;
    $('flip').disabled = true;
    try {
      const cams = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === 'videoinput');
      if (cams.length < 2) return;
      const cur = localStream?.getVideoTracks()[0]?.getSettings?.().deviceId;
      const i = Math.max(0, cams.findIndex((d) => d.deviceId === cur));
      await switchCameraTo(cams[(i + 1) % cams.length].deviceId);
      await fillDevicePickers(); // the in-call picker must say where the flip landed
    } finally {
      flipBusy = false;
      $('flip').disabled = false;
      showBar(true); // a flip is a state change; the bar earns its 10 s again
    }
  }, 'flip');

// ── Mid-call microphone switch (§15) ────────────────────────────────────────
// The mic has more consumers than the camera, and none of them follow a
// track swap on their own: the Opus-mode sender and the Lane-A hot spare
// (RTCRtpSenders — replaceTrack), Lane A's capture worklet (pcm.retap — its
// source node latches the track at construction), the local onset detector
// (re-attach), and the interpreter's tap (restart, signaling-silent). Each is
// retargeted explicitly; missing one is a silent one-way failure in that one
// subsystem, which is exactly why the switch is logged per consumer.
let micSwitchBusy = false;
async function switchMicTo(deviceId) {
  if (micSwitchBusy || !localStream) return;
  micSwitchBusy = true;
  try {
    const old = localStream.getAudioTracks()[0];
    const want = { ...audioConstraints(true), deviceId: { exact: deviceId } };
    const nt = (await navigator.mediaDevices.getUserMedia({ audio: want })).getAudioTracks()[0];
    // Mute survives the switch: a red mic must stay red on the new device.
    if (old) nt.enabled = old.enabled;
    const fromId = old?.getSettings?.().deviceId ?? null;
    if (old) localStream.removeTrack(old);
    localStream.addTrack(nt);
    // Every sender currently holding an audio track moves over — Opus mode's
    // live sender, or the hot spare after a Lane-A fallback. A spare that is
    // parked on null stays null: giving it the mic here would START a second
    // audio path alongside Lane A.
    for (const s of pc?.getSenders?.() ?? []) {
      if (s.track?.kind === 'audio') await s.replaceTrack(nt).catch(() => { /* sender torn down */ });
    }
    const retapped = pcm ? safe(() => pcm.retap?.(localStream) ?? false, 'micswitch.retap') : null;
    // The local onset detector (turn-taking's ears) follows the new track.
    localMon?.disconnect();
    localMon = await safeAsync(() => attachDetector(localStream, 'local', (ev) => onDetector('local', ev)), 'micswitch.mon');
    // Interpreter: its tap worklet latched the old track too. fromPeer=true on
    // both calls keeps the restart signaling-silent — the peer never toggles.
    if (xlateApi) { xlateStop(true); await xlateStart(true); }
    old?.stop();
    safe(() => localStorage.setItem('tape.mic', deviceId), 'micswitch.remember');
    $('mic').dataset.off = nt.enabled ? '0' : '1';
    haptic();
    tel?.log('mic-switch', {
      from: fromId,
      to: deviceId,
      label: (nt.label ?? '').slice(0, 64),
      retapped,
      settings: pick(nt.getSettings?.() ?? {}, ['sampleRate', 'channelCount', 'echoCancellation']),
    });
  } finally {
    micSwitchBusy = false;
  }
}

// In-call pickers (§15, user directive 2026-08-06): a particular device,
// not just "the next one". Busy-guard via disabled — a second change while
// the first is mid-swap would race two getUserMedia calls on one sensor.
$('camSelCall').onchange = () =>
  safeAsync(async () => {
    if (!joined || !$('camSelCall').value) return;
    $('camSelCall').disabled = true;
    try { await switchCameraTo($('camSelCall').value); } finally { $('camSelCall').disabled = false; }
  }, 'call.switch.cam');
$('micSelCall').onchange = () =>
  safeAsync(async () => {
    if (!joined || !$('micSelCall').value) return;
    $('micSelCall').disabled = true;
    try { await switchMicTo($('micSelCall').value); } finally { $('micSelCall').disabled = false; }
  }, 'call.switch.mic');

// The "Save call log" control is gone from the more sheet — downloading a
// counter dump is not something a person in a conversation wants, and offering
// it made the log look like part of the product. tel.download() still exists
// and the testbed calls it directly; nothing in the collection path changed.
// Sharing the link is THE task of the waiting screen, so it gets three routes
// that all end the same way: the native share sheet where one exists (phones —
// the gesture people actually use to send a link), the copy button, and
// tapping the link itself. Copy always confirms — silence after a copy is why
// people paste into the wrong chat to check.
function copiedFlash(btn) {
  safe(() => {
    const was = btn.textContent;
    btn.textContent = 'copied ✓';
    btn.disabled = true;
    setTimeout(() => { btn.textContent = was; btn.disabled = false; }, 1400);
  }, 'copy.flash');
}
$('copy').onclick = () =>
  safeAsync(async () => {
    // Flash first: confirmation must land inside the perceptual "instant"
    // window, and the write resolves in microtasks anyway. The rare failure
    // overwrites the flash with the truth.
    copiedFlash($('copy'));
    await navigator.clipboard.writeText($('shareUrl').value).catch(() => { $('copy').textContent = 'copy failed'; });
    tel?.log('share', { via: 'copy' });
  }, 'copy');
$('shareUrl').onclick = () =>
  safeAsync(async () => {
    $('shareUrl').select();
    await navigator.clipboard.writeText($('shareUrl').value);
    copiedFlash($('copy'));
    tel?.log('share', { via: 'url-tap' });
  }, 'copy.url');
safe(() => {
  if (!navigator.share) return; // desktop: copy IS the native gesture
  const b = document.createElement('button');
  b.id = 'shareBtn';
  b.textContent = 'share';
  $('copy').before(b);
  b.onclick = () =>
    safeAsync(
      () => navigator.share({ url: $('shareUrl').value }).then(() => tel?.log('share', { via: 'sheet' })),
      'share.sheet',
    );
}, 'share.btn');

// ── Leave: two taps, no modal (§B.11) ────────────────────────────────────────
// A dropped 1:1 call is unrecoverable — you cannot un-hang-up. The circle
// morphs in place into a labelled pill for 3 s; this is the one control allowed
// a word, because "are you sure" is not a thing an icon can say. A modal over a
// live face would be worse than the mistake it prevents.
let leaveArmed = false;
let leaveTimer = null;
function cancelLeaveConfirm() {
  if (!leaveArmed) return;
  leaveArmed = false;
  clearTimeout(leaveTimer);
  safe(() => {
    $('leave').classList.remove('confirming');
    $('bar').classList.remove('confirming');
  }, 'leave.cancel');
}
// Everything a call session owns, stopped. Shared by the deliberate leave and
// by the in-place reset (task #50 follow-up) — one list, so a resource added to
// one path cannot leak on the other. Elapsed-time is NOT here: a peer that
// drops and returns is one conversation, and the reset keeps its clock running.
// `keepMedia` is the in-place reset's whole safety story. The deliberate leave
// stops the camera because the page is navigating away; the RESET must not,
// because this file's own law (getMedia, "one open per device, per page") says
// stopping a camera and reopening it moments later is what makes real drivers
// throw NotReadableError. The fake device used in the e2e never does, so the
// first version of this passed 8/8 in the lab and broke real calls — including
// re-running Android's auto-exposure from scratch, which is the dimming bug
// coming back by another door (tasks #40/#41).
function stopCallMachinery({ keepMedia = false } = {}) {
  safe(() => {
    turns?.flush();
    tel?.stop();
    // Watchdog timers armed by the OLD call must die with it: a stale
    // armPcmWatchdog timer fired 0.7 s into the reset call, read the NEW
    // pcm's playedFrames=0 and killed the lane with 'no-audio' (measured,
    // refresh-trace 2026-08-05). Same hazard for the video lane's timer.
    clearTimeout(pcmWatchdog);
    clearTimeout(laneWatchdog);
    clearTimeout(recoverTimer);
    clearInterval(statsTimer);
    clearInterval(concealProbe);
    clearInterval(lumaTimer);
    clearInterval(fillTimer);
    lumaTimer = null;
    fillTimer = null;
    srcProbe?.reader?.cancel().catch(() => {});
    srcProbe = null;
    localMon?.disconnect();
    remoteMon?.disconnect();
    // NULLED, not just disconnected — ontrack's claim guard is
    // `if (remoteAttaching || remoteMon) return`, and it runs before everything
    // that makes a peer count as arrived (peerArrived → hadPeer, the lane
    // watchdogs, the 'connected' status). A disconnected-but-non-null monitor
    // surviving into the next call makes that call LOOK healthy while hadPeer
    // stays false — so the reset after it skips, renegotiates on a spent page,
    // and the audio lane dies. Found via callFlags polling, slowclose-diag
    // 2026-08-05: gen2's whole second call ran with hadPeer:false.
    localMon = null;
    remoteMon = null;
    remoteAttaching = false;
    pcm?.stop();
    tsync?.stop();
    for (const spc of pcmPcs) spc?.close();
    pc?.close();
    ws?.close();
    if (!keepMedia) for (const t of localStream?.getTracks() ?? []) t.stop();
  }, 'call.stop');
}

function teardownCall() {
  leavingDeliberately = true; // the closes below must not trigger recovery
  clearTimeout(recoverTimer);
  window.__hbEnd?.('leave'); // before teardown, while pcm stats still exist
  tel?.log('session-end', turns?.summary() ?? {});
  stopCallMachinery();
  stopElapsed();
  clearLive(); // the ONE place the call actually ends for this side
  location.href = '/'; // the path may BE the room now — home is /, not pathname
}

// ── In-place reset (the "more flawless" refresh, user directive 2026-08-05) ──
// When the PEER refreshes, this side used to reload its whole page to get a
// clean slate (reArmForNewPeer) — so one person's refresh flashed BOTH
// screens. This resets the call without the page: stop every per-call
// resource, then run join() again on the same page. join() was audited for
// re-entry: every per-call binding it touches it reassigns (pc, ws, tel,
// localStream, tapePre, stripes by index, timers), `joined` is set inside it,
// and the elapsed clock deliberately survives (one conversation). The reload
// re-arm remains as the fallback if this ever throws — flawless when it
// works, never worse than before when it does not.
// Resolves when `s` has finished closing, or after `ms` — bounded because a
// socket that never completes its handshake must not strand the reset; the
// timeout path simply falls through to the room's own ghost sweep.
function waitSocketClosed(s, ms) {
  if (!s || s.readyState === WebSocket.CLOSED) return Promise.resolve();
  return new Promise((res) => {
    const done = () => res();
    s.addEventListener('close', done, { once: true });
    s.addEventListener('error', done, { once: true });
    setTimeout(done, ms);
  });
}

let resettingInPlace = false;
async function resetForNextPeer(room) {
  if (resettingInPlace) return true; // a second peer-joined mid-reset is the new socket's business
  resettingInPlace = true;
  leavingDeliberately = true; // recoverCall must ignore our own closes
  tel?.log('reset-in-place', { room });
  setStatus('reconnecting…');
  const oldWs = ws;
  stopCallMachinery({ keepMedia: true });
  // WAIT FOR THE OLD SOCKET TO ACTUALLY BE GONE before opening the new one.
  // `ws.close()` only STARTS a close handshake. The room counts occupants by
  // socket readyState and answers a third upgrade with 409 "room full", so
  // racing our own closing socket means the reset's join() is rejected with
  // "this call may already have two people in it" — and the closer the peer's
  // arrival is to our close, the likelier it is. On loopback the handshake
  // finishes in well under a millisecond, which is why every lab run passed;
  // over cellular it is tens to hundreds of milliseconds, which is where real
  // refreshes stopped coming back.
  await waitSocketClosed(oldWs, 2500);
  // Hand the still-live tracks back to the lobby slot getMedia() reuses. That
  // path is the proven one — it re-applies the capture constraints and repairs
  // the frame rate on a reused track — so the reset opens NO camera and NO mic,
  // and Android's exposure is never restarted.
  previewStream = localStream;
  hadPeer = false; // the next peerArrived is a fresh arrival, not a spent page
  joined = false;
  // The fallback latches are per-call verdicts, not page state: a fresh page
  // starts with them clear, so the reset call must too — otherwise one old
  // fallback silently downgrades every call this page ever hosts.
  pcm = null;
  pcmFellBack = false;
  pcmFellBackWhy = null;
  pcmSpareSender = null; // belonged to the closed pc; join() re-creates it
  tapeFellBack = false;
  try {
    await join(room);
    return true;
  } catch (e) {
    tel?.log('reset-in-place-failed', { e: String(e).slice(0, 120) });
    return false; // caller falls back to the reload re-arm
  } finally {
    leavingDeliberately = false;
    resettingInPlace = false;
  }
}
$('leave').onclick = () => {
  if (leaveArmed) {
    haptic(18);
    tel?.log('gesture', { what: 'leave', step: 'confirm' });
    teardownCall();
    return;
  }
  leaveArmed = true;
  haptic();
  safe(() => {
    $('leave').classList.add('confirming');
    // The row itself contracts too — see the #bar.confirming rule. Six circles
    // plus a 150 px pill does not fit a phone, and the overflow put a live
    // mute button under the finger travelling toward "leave".
    $('bar').classList.add('confirming');
  }, 'leave.arm');
  showBar(true);
  tel?.log('gesture', { what: 'leave', step: 'arm' });
  leaveTimer = setTimeout(() => { cancelLeaveConfirm(); scheduleHide(); }, 3000);
};

// ── Chrome visibility (§A.3, §A.4) ───────────────────────────────────────────
// Controls are visible on entry, on any interaction, and on any state change,
// then get out of the way after 2.6 s. The first 10 s of a call they stay
// pinned so the vocabulary is learned once. They never hide while the sheet is
// open or the leave confirm is armed — hiding a control mid-decision is how you
// get a hang-up nobody meant.
let hideTimer = null;
let barPinnedUntil = 0;
function showBar(pin = false) {
  safe(() => {
    $('bar').classList.add('show');
    $('call').classList.add('barShown');
    if (pin) barPinnedUntil = Math.max(barPinnedUntil, performance.now() + 10000);
    scheduleHide();
  }, 'bar.show');
}
function scheduleHide() {
  clearTimeout(hideTimer);
  // Auto-hide exists to get chrome off a FACE mid-conversation (§A.3). Before
  // the call the screen is your own mirror and one button, and hiding the
  // controls there just makes the app look broken.
  if (!joined) return;
  // Wait out whichever ends later: 2.6 s of stillness, or the intro pin. An
  // earlier version re-armed on a flat 2.6 s tick whenever it found itself
  // still pinned, which meant the bar could outlive the pin by up to another
  // 2.6 s depending on where the ticks happened to land — measured at 12.5 s
  // for a 10 s pin. Sizing the timeout to the actual remaining time makes the
  // disappearance land exactly where the rule says it should.
  const wait = Math.max(2600, barPinnedUntil - performance.now());
  hideTimer = setTimeout(() => {
    // A sheet open or a leave half-confirmed is a decision in progress; taking
    // the controls away mid-decision is how you get a hang-up nobody meant.
    if ($('moreSheet').classList.contains('on') || leaveArmed) return scheduleHide();
    safe(() => {
      $('bar').classList.remove('show');
      $('call').classList.remove('barShown');
    }, 'bar.hide');
  }, wait);
}
// Mouse movement reveals; a touch TAP toggles. Kept separate because a tap
// emits a stray pointermove on most touch stacks, and a reveal-then-toggle race
// makes the bar feel broken on exactly the devices that need it most.
addEventListener('pointermove', (e) => { if (e.pointerType !== 'touch') showBar(); });
// Using a control counts as interaction. Without this the 2.6 s timer keeps
// running while you are actually using the bar, so muting at t=2.5 s makes the
// row vanish a tenth of a second later — the control you just touched
// disappearing under your finger. Touch never sees the pointermove above, so
// this is the only thing re-arming the timer on a phone.
$('bar').addEventListener('pointerdown', () => showBar());
$('more').addEventListener('pointerdown', () => showBar());
$('call').addEventListener('pointerdown', (e) => {
  // Only empty video toggles. A tap that lands on chrome is that control's.
  if (e.target.closest('#bar, #more, #moreSheet, #moreScrim, #floorIcon, #floorHint, #hud, #shareBox')) return;
  cancelLeaveConfirm();
  // Any tap out in the picture also puts the loud-room explanation away — it is
  // an answer to a question you asked, not a notice that needs dismissing.
  if ($('floorHint').classList.contains('on')) collapseFloorHint();
  if (joined && $('bar').classList.contains('show') && performance.now() >= barPinnedUntil) {
    safe(() => {
      $('bar').classList.remove('show');
      $('call').classList.remove('barShown');
    }, 'bar.tap.hide');
    clearTimeout(hideTimer);
  } else {
    showBar();
  }
});
$('remote').addEventListener('loadedmetadata', layout);
// Fires when the track's intrinsic size changes mid-stream — the sender
// rotating their phone. Instant on the <video> path; the canvas path is covered
// by the 2 Hz dimension watch in startRemoteFill().
$('remote').addEventListener('resize', layout);
addEventListener('resize', layout);
// No event exists for "the user moved the window", and gaze alignment depends on
// where the window sits relative to the lens.
let lastPos = '';
setInterval(() => {
  const p = `${window.screenX},${window.screenY}`;
  if (p !== lastPos) {
    lastPos = p;
    layout();
  }
}, 500);

// ── Room identity (§7) ───────────────────────────────────────────────────────
// Possessing the link IS the credential — Meet-link and FaceTime-link
// semantics. Meet can afford ~47 bits because Google rate-limits guessing;
// nothing rate-limits the room DO, so this takes the full 128 and brute force
// stops being a threat model rather than being merely expensive. Nothing on the
// server changes: the DO already keys on an arbitrary string, and the hard cap
// of two occupants is the admission control (a knock-and-admit flow would buy a
// 1:1 product nothing but a second waiting room).
// ── A call outlives its tab (user directive 2026-08-04) ─────────────────────
// "A call should persist even on a refresh or window close until both parties
// explicitly cut it." The room DO already has that lifetime — a room is just a
// name, and the waiting screen holds it open. What was missing is the CLIENT
// remembering it was mid-call: this record is written at join, heartbeaten
// every 2 s, and deleted in exactly one place — the leave button. A refresh or
// a closed-and-reopened window finds it and walks straight back in.
// RESUME_MAX_MS bounds the surprise: a record whose last heartbeat is older
// than 30 min means the call is long over on the other side too, and yanking
// next week's fresh visit into last week's empty room would be worse than the
// forgetting. localStorage (not sessionStorage) on purpose: sessionStorage
// dies with the window, and the directive says a closed window is not a cut.
const LIVE_KEY = 'tape.live';
const RESUME_MAX_MS = 30 * 60_000;
function markLive(room) {
  safe(() => localStorage.setItem(LIVE_KEY, JSON.stringify({ room, at: Date.now() })), 'live.mark');
}
function clearLive() {
  safe(() => localStorage.removeItem(LIVE_KEY), 'live.clear');
}
/** The room to walk back into, or null. An explicit invite in the URL always
 *  wins — clicking a NEW link is as clear a statement as pressing leave. */
function resumeRoom(urlRoom) {
  return safe(() => {
    const rec = JSON.parse(localStorage.getItem(LIVE_KEY) ?? 'null');
    if (!rec?.room || Date.now() - rec.at > RESUME_MAX_MS) return null;
    if (urlRoom && urlRoom !== rec.room) return null; // new invite beats old call
    return rec.room;
  }, 'live.read') ?? null;
}

// Meet-shaped: xxx-xxxx-xxx, lowercase letters (user directive 2026-08-04 —
// "link should not be longer or complex than meet.google.com/etm-bkmb-iev").
// That is 26^10 ≈ 47 bits, the same budget Meet spends. The old 128-bit mint
// assumed brute force must be impossible rather than merely expensive; 47 bits
// against a Worker that has to complete a WebSocket upgrade per guess is 4
// billion years at 1k guesses/s — the human trade (a link you can read aloud)
// wins. Old 22-char ?r= links still resolve; nothing breaks.
const MEET_RE = /^[a-z]{3}-[a-z]{4}-[a-z]{3}$/;
function mintRoom() {
  const b = new Uint8Array(10);
  crypto.getRandomValues(b);
  // Rejection-free and unbiased enough: 256 % 26 = 22, a 0.3% skew toward the
  // first 22 letters — irrelevant at this entropy, and branchless.
  const c = [...b].map((x) => String.fromCharCode(97 + (x % 26))).join('');
  return `${c.slice(0, 3)}-${c.slice(3, 7)}-${c.slice(7)}`;
}
/** The canonical shareable URL for a room: the short path form for minted
 *  codes, the ?r= form for legacy/named rooms. One function so the address
 *  bar, the waiting screen and the clipboard can never disagree. */
function roomUrl(room) {
  return MEET_RE.test(room)
    ? `${location.origin}/${room}`
    : `${location.origin}/?r=${encodeURIComponent(room)}`;
}

/** The button says what it is about to do — mint a new room, or join a named
 *  one. One button, because two buttons is a decision nobody asked for. */
function paintJoinLabel() {
  safe(() => {
    $('join').textContent = $('room').value.trim() ? 'Join call' : 'Start a call';
  }, 'join.label');
}
$('room').addEventListener('input', paintJoinLabel);

/**
 * What people actually put in this box is not always a room name. The two
 * common ones are the whole invite link ("paste this to join") and a name with
 * a space in it. Both fail the server's `[A-Za-z0-9_-]{1,64}` room regex, the
 * ws upgrade 400s, and the browser exposes no status code for a failed upgrade
 * — so a simple paste came back as "this call may already have two people in
 * it", which is confident, unhelpful and wrong. Read the intent instead.
 *
 * Returns the room, '' to mint a fresh one, or null when there is nothing
 * sensible to read (the caller says so in words rather than guessing).
 */
function roomFromInput(raw) {
  const s = String(raw ?? '').trim();
  if (!s) return '';
  const link = s.match(/[?&#]r=([A-Za-z0-9_-]{1,64})/); // a pasted legacy invite link
  if (link) return link[1];
  const short = s.match(/(?:^|\/)([a-z]{3}-[a-z]{4}-[a-z]{3})(?:[/?#]|$)/); // pasted short link or bare code
  if (short) return short[1];
  const cleaned = s.replace(/\s+/g, '-'); // "morning call" is a room name, not a mistake
  return /^[A-Za-z0-9_-]{1,64}$/.test(cleaned) ? cleaned : null;
}

// Recovery-boot retry budget (see the catch below). 15 tries × 4 s ≈ one
// minute of walking back toward a call whose room is already in the URL.
const REJOIN_RETRY_MAX = 15;
let rejoinRetries = 0;
// Task #51: the /api/ice response the lobby fetched, reused by join() so the
// click pays no serial round trip. { at, promise }.
let iceCache = null;
// Task #51: the FIRST joiner's ws-open was ~1.1 s against ~0.3 s for the
// second (measured, ttc-measure, prod medians) — the difference is the room
// Durable Object's cold start, paid by whoever CREATES the room. The lobby
// knows the room name long before the click (deep link, typed name, or the
// pre-minted one below), so warm the DO while the human is still looking at
// the preview. /summary without a token is a 401 — but the DO is constructed
// and its storage read to answer it, which is the entire point.
let pendingMint = null; // minted at lobby load so its DO can be warmed too
function prewarmRoom(room) {
  if (!room) return;
  safe(() => { fetch(`/api/room/${encodeURIComponent(room)}/summary`).catch(() => {}); }, 'prewarm');
}
$('join').onclick = async () => {
  const wanted = roomFromInput($('room').value);
  if (wanted === null) {
    $('joinStatus').textContent =
      'That room name has characters we can’t use — letters, numbers, - and _ only. Or paste the invite link.';
    return;
  }
  $('join').disabled = true;
  $('joinStatus').textContent = 'starting…';
  try {
    await join(wanted || pendingMint || mintRoom());
  } catch (e) {
    $('joinStatus').textContent = `couldn't join: ${e.message}`;
    $('join').disabled = false;
    // A resume that cannot land (room refilled, second tab already in it) must
    // not chase the user across every future visit — one failure spends it.
    if (resumePending) { resumePending = false; clearLive(); }
    tel?.log('join-failed', { msg: String(e.message).slice(0, 160) });
    // A RECOVERY boot must not die on its first try. Measured on the M13
    // (WiFi cut → cellular, 2026-08-05): the rejoin's ws upgrade failed once
    // right at the network transition and the page then sat at "connecting…"
    // forever with the call one button-press away. Only ?rejoin=1 retries —
    // a human's own failed join stays a human's decision.
    if (QS.get('rejoin') === '1' && !joined && rejoinRetries < REJOIN_RETRY_MAX) {
      rejoinRetries++;
      tel?.log('rejoin-retry', { n: rejoinRetries });
      // First retry comes fast: in room vjj-spil-qli the user out-raced the 4 s
      // timer with a manual reload (~5 s), which mints a fresh session and a
      // fresh ghost. A 1.2 s first probe beats the human reflex; later retries
      // keep the 4 s spacing so a genuinely full room isn't hammered.
      setTimeout(() => safe(() => { if (!joined) $('join').click(); }, 'rejoin.retry'), rejoinRetries === 1 ? 1200 : 4000);
    }
  }
};

// ── Lobby: preview, device pickers, level meter, capacity badge (§15) ────────
// The mic is acquired HERE, not at join. The old comment said video-only "so the
// permission prompt for both arrives in one go" — but asking for video+audio in
// ONE getUserMedia is also one prompt, and it is what makes the rest of §15
// possible: you cannot show a real level meter, name the microphones, or check
// for headphones without the mic. `getMedia()` reuses both tracks at join, so
// the camera and mic are still opened exactly once per page.
let lobbyMon = null; // level-meter detector, torn down at join
let lobbyPeak = { db: -100, at: 0 };

async function openPreview(camId, micId) {
  // Release the old one first: this device hands out one camera at a time, and
  // a switch that opens before it closes fails with NotReadableError.
  previewStream?.getTracks?.().forEach((t) => t.stop());
  previewStream = null;
  // The frame rate here caps the WHOLE CALL, not just the lobby. We deliberately reuse
  // this track at join (one open per device, because opening the same camera twice is
  // what makes finicky drivers throw NotReadableError), and measured 2026-08-03: Chrome
  // will NOT raise an existing track's frame rate via applyConstraints — a lobby opened
  // at 30 stayed at 30 for the rest of the call even against a 60 fps source, and
  // repairFrameRate could not lift it either. Only the initial getUserMedia decides.
  // Resolution stays at 1280 on purpose (join re-applies the full ask); the rate cannot.
  const video = { width: { ideal: 1280 }, frameRate: { ideal: FPS_CEILING } };
  if (camId) video.deviceId = { exact: camId };
  const audio = { ...audioConstraints(true) };
  if (micId) audio.deviceId = { exact: micId };
  let s;
  try {
    s = await navigator.mediaDevices.getUserMedia({ video, audio });
  } catch (e) {
    // A remembered camera or mic (§8 item 38) that has since been unplugged
    // fails with OverconstrainedError. Remembering a preference must never be
    // able to cost someone their devices, so an exact ask degrades to "any".
    if (!video.deviceId && !audio.deviceId) throw e;
    tel?.log('preview-device-fallback', { name: e?.name ?? 'unknown' });
    delete video.deviceId;
    delete audio.deviceId;
    s = await navigator.mediaDevices.getUserMedia({ video, audio });
  }
  previewStream = s;
  $('preview').srcObject = s;
  // The corner PiP is the same element in both states, so it gets the same
  // picture in both states — otherwise the self-view circle in the bar is a
  // control that looks alive before a call and does nothing.

  const pb = $('previewBadge');
  pb.textContent = 'camera ready';
  // Same manner as #status ("connected" fades): good news is said once. Bad
  // news — the blocked-camera paths below — stays up, because it needs acting on.
  pb.classList.remove('gone');
  setTimeout(() => safe(() => {
    if (pb.textContent === 'camera ready') {
      pb.classList.add('gone');
      $('capBadge').classList.add('gone');
    }
  }, 'badge.fade'), 2600);
  return s;
}

/** Fill the pickers. Labels are blank until permission is granted, hence after. */
async function fillDevicePickers() {
  const devs = await navigator.mediaDevices.enumerateDevices();
  // Both phases fill from the stream that is actually live: the lobby's
  // preview before join, the call's own stream after.
  const cur = armStream()?.getTracks?.() ?? [];
  const curOf = (kind) => cur.find((t) => t.kind === kind)?.getSettings?.().deviceId;
  for (const [sel, kind, noun] of [
    ['camSel', 'videoinput', 'camera'],
    ['micSel', 'audioinput', 'microphone'],
    ['camSelCall', 'videoinput', 'camera'],
    ['micSelCall', 'audioinput', 'microphone'],
  ]) {
    const el = $(sel);
    if (!el) continue;
    const list = devs.filter((d) => d.kind === kind);
    el.innerHTML = '';
    for (const [i, d] of list.entries()) {
      const o = document.createElement('option');
      o.value = d.deviceId;
      o.textContent = d.label || `${noun} ${i + 1}`;
      el.appendChild(o);
    }
    const now = curOf(kind === 'videoinput' ? 'video' : 'audio');
    if (now) el.value = now;
    // Always shown (user directive 2026-08-06: selecting a particular device
    // must always be possible in-app). A single-device list still NAMES the
    // device in use — that is information, not clutter — and only an empty
    // list deadens the control.
    el.disabled = list.length < 1;
  }
}

/** Real mic level off the onset worklet's own RMS — no second DSP path. */
async function startLevelMeter(stream) {
  lobbyMon?.disconnect();
  lobbyMon = await safeAsync(
    () =>
      attachDetector(stream, 'lobby', (ev) => {
        if (ev.type !== 'level' || !Number.isFinite(ev.rmsDb)) return;
        // -60 dB floor, -6 dB top: the range a voice actually occupies. Below
        // -60 is a muted or dead mic and should read as nothing, not as a sliver.
        const frac = Math.max(0, Math.min(1, (ev.rmsDb + 60) / 54));
        const bar = $('levelBar');
        if (bar) bar.style.right = `${(1 - frac) * 100}%`;
        const now = performance.now();
        if (frac * 100 >= lobbyPeak.db || now - lobbyPeak.at > 1200) {
          lobbyPeak = { db: frac * 100, at: now };
          const pk = $('levelPeak');
          if (pk) {
            pk.style.left = `${frac * 100}%`;
            pk.style.opacity = frac > 0.02 ? '1' : '0';
          }
        }
      }),
    'lobby.meter',
  );
}

/**
 * The capacity badge (§15): ONE line saying what you are actually going to get.
 * Read off the real track and the real codec support — never asserted. Video
 * says the capture the camera agreed to; audio says "lossless" only where Lane A
 * (uncompressed PCM) is actually going to run.
 */
function paintCapBadge() {
  const el = $('capBadge');
  if (!el) return;
  const t = previewStream?.getVideoTracks?.()[0];
  const s = safe(() => t?.getSettings?.(), 'cap.settings');
  if (!s?.width) {
    el.textContent = 'measuring…';
    el.classList.remove('locked');
    return;
  }
  // Portrait phone sensors report width < height; name the long edge, which is
  // what "1080p" means to a person.
  const lines = Math.min(s.width, s.height);
  const fps = Math.round(s.frameRate ?? 30);
  const audio = PCM_AUDIO ? 'lossless audio' : 'compressed audio';
  el.textContent = `${lines}p · ${fps} · ${audio}`;
  el.classList.add('locked');
}

/**
 * A headphone check that CHECKS (§15), instead of a paragraph asking nicely.
 *
 * Echo cancellation is off by design here, so the test is direct: play a short
 * quiet tone and watch the mic. Through headphones the mic hears essentially
 * nothing; through speakers it hears the tone plainly. The verdict is the
 * measured rise in dB, and it is reported with its reason — one line, per spec.
 */
async function headphoneCheck() {
  const out = $('hpOut');
  const btn = $('hpCheck');
  const track = previewStream?.getAudioTracks?.()[0];
  if (!track) return void (out.textContent = 'no microphone');
  btn.disabled = true;
  out.textContent = 'listening…';
  const res = await safeAsync(async () => {
    const ctx = await audioContext();
    const src = ctx.createMediaStreamSource(new MediaStream([track]));
    const an = new AudioWorkletNode(ctx, 'onset-detector', { numberOfOutputs: 0 });
    let cur = -100;
    an.port.onmessage = (e) => {
      if (e.data?.type === 'level' && Number.isFinite(e.data.rmsDb)) cur = e.data.rmsDb;
    };
    src.connect(an);
    const wait = (ms) => new Promise((r) => setTimeout(r, ms));
    const peakOver = async (ms) => {
      let mx = -100;
      const end = performance.now() + ms;
      while (performance.now() < end) {
        await wait(50);
        if (cur > mx) mx = cur;
      }
      return mx;
    };
    await wait(250);
    const quiet = await peakOver(700); // the room, before we make any noise

    const osc = ctx.createOscillator();
    const g = ctx.createGain();
    osc.frequency.value = 660; // mid-voice band, where a speaker couples best
    g.gain.value = 0.09; // audible, not startling
    osc.connect(g).connect(ctx.destination);
    osc.start();
    const loud = await peakOver(900);
    osc.stop();
    osc.disconnect();
    g.disconnect();
    src.disconnect();
    an.port.postMessage('stop');
    return { quiet, loud, rise: loud - quiet };
  }, 'hp.check');

  btn.disabled = false;
  if (!res) return void (out.textContent = "couldn't run the check");
  const { rise, quiet } = res;
  tel?.log('hpcheck', { rise: +rise.toFixed(1), quiet: +quiet.toFixed(1) });
  // 6 dB is a doubling of level — comfortably past room drift, well under what
  // a speaker in the same room produces (typically 15-30 dB here).
  const dB = `${rise >= 0 ? '+' : ''}${rise.toFixed(0)} dB`; // never render "+-2 dB"
  if (rise >= 6) {
    out.style.color = 'var(--warn)';
    out.textContent = `speakers — your mic heard the tone (${dB}). You'll echo.`;
  } else {
    out.style.color = 'var(--ok)';
    out.textContent = `headphones — mic barely heard it (${dB}). You're good.`;
  }
}

// The bar is up from the first paint: it is the same bar the call uses, and
// before a call there is nothing for it to get out of the way of.
showBar();
// The whole preview boot is a named, re-runnable function because its failure
// mode is the single worst moment in the product: a first-time visitor who
// clicked "Block" (or whose browser remembered a block) used to get "reload the
// page" as their only door back in. Now the same sentence is a button that
// re-asks, and the Permissions API re-runs it AUTOMATICALLY the moment the
// toggle flips — the user fixes the setting and the mirror just appears,
// no reload, no instructions.
function bootPreview() {
  return openPreview(
    safe(() => localStorage.getItem('tape.cam'), 'flip.recall') || null,
    safe(() => localStorage.getItem('tape.mic'), 'mic.recall') || null,
  )
  .then(async () => {
    // The door opens only with both devices in hand (user directive 2026-08-04:
    // nobody starts a call without allowing microphone AND camera). openPreview
    // resolving means one getUserMedia granted both, so the gate lifts here and
    // only here; the catch below is every other state, and it keeps it shut.
    $('join').disabled = false;
    await fillDevicePickers();
    paintCapBadge();
    applyMirror(previewStream?.getVideoTracks?.()[0]);
    await refreshFlipAffordance();
    await startLevelMeter(previewStream);
    syncArmState();
    // A recovery must erase the failure it recovered from: the blocked-state
    // sentence and the deadened controls both un-happen here.
    safe(() => { if ($('joinStatus').textContent.startsWith('Camera and microphone')) $('joinStatus').textContent = ''; }, 'perm.clear');
    // Labels and the device list can both change when something is plugged in.
    navigator.mediaDevices.addEventListener?.('devicechange', () =>
      safeAsync(async () => {
        await fillDevicePickers();
        await refreshFlipAffordance();
      }, 'devchange'));
    // ?rejoin=1 — set by reArmForNewPeer and by nothing else. The camera is
    // ready and the room is in the URL, so the only thing left between the user
    // and the call they never meant to leave is a button press. Skip it.
    if ((QS.get('rejoin') === '1' || resumePending) && !joined) safe(() => $('join').click(), 'rejoin.auto');
    for (const [sel, kind] of [
      ['camSel', 'cam'],
      ['micSel', 'mic'],
    ]) {
      $(sel).onchange = () =>
        safeAsync(async () => {
          $('previewBadge').classList.remove('gone');
          $('capBadge').classList.remove('gone');
          $('previewBadge').textContent = `switching ${kind}…`;
          await openPreview($('camSel').value || null, $('micSel').value || null);
          paintCapBadge();
          applyMirror(previewStream?.getVideoTracks?.()[0]);
          await startLevelMeter(previewStream);
          syncArmState();
          // A choice made in the lobby is a preference, same as the flip's:
          // next visit opens on the devices this person actually picked.
          safe(() => {
            if ($('camSel').value) localStorage.setItem('tape.cam', $('camSel').value);
            if ($('micSel').value) localStorage.setItem('tape.mic', $('micSel').value);
          }, 'lobby.remember');
        }, `lobby.switch.${kind}`);
    }
  })
  .catch((e) => {
    // No devices, no call: the join button is dead until a re-ask succeeds.
    $('join').disabled = true;
    $('previewBadge').classList.remove('gone');
    $('previewBadge').textContent = `camera blocked (${e.name})`;
    safe(() => {
      const st = $('joinStatus');
      st.textContent = e.name === 'NotFoundError'
        ? 'A camera and microphone are required to join, and none was found. '
        : 'Camera and microphone are blocked. ';
      const retry = document.createElement('button');
      retry.className = 'linkbtn';
      retry.textContent = 'allow and try again';
      retry.onclick = () => { st.textContent = 'asking…'; bootPreview(); };
      st.appendChild(retry);
    }, 'perm.retry');
    $('capBadge').textContent = 'no camera';
    // Controls with no device behind them must LOOK dead, not just act dead.
    for (const id of ['mic', 'cam', 'flip']) safe(() => { $(id).disabled = true; }, `dead.${id}`);
    tel?.log('preview-blocked', { name: e?.name ?? 'unknown' });
  });
}
bootPreview();
// The self-healing half: when the user flips the browser's permission toggle,
// the mirror appears by itself. Chrome fires onchange on both grant and deny;
// re-boot only on grant, and only while not joined.
safeAsync(async () => {
  for (const name of ['camera', 'microphone']) {
    const st = await navigator.permissions.query({ name });
    st.onchange = () => {
      if (st.state === 'granted' && !joined && !previewStream) {
        $('joinStatus').textContent = '';
        bootPreview();
      }
    };
  }
}, 'perm.watch');

$('hpCheck').onclick = () => safeAsync(headphoneCheck, 'hp.click');

// ── Say out loud whether a relay is available ────────────────────────────────
// Without TURN credentials the call still works, but only between devices that can reach each
// other directly — same wifi, usually fine; two different networks, usually not. That was
// recorded in telemetry and nowhere else, so the one person who needs to know (whoever is about
// to call someone on another network) had no way to find out except by watching it fail with no
// explanation. Checked in the lobby rather than at join time so it is read before the call, and
// it never blocks: a failed probe leaves the lobby exactly as it was.
safe(() => {
  // Task #51: this same response is what join() needs — cache it so joining
  // costs no serial /api/ice round trip. One fetch, two customers.
  iceCache = { at: Date.now(), promise: fetch('/api/ice').then((r) => r.json()) };
  iceCache.promise
    .then((ice) => {
      if (!ice?.p2pOnly) return;
      const el = $('joinStatus');
      if (el && !el.textContent) {
        el.textContent = 'No relay configured — works on the same network. Across two networks it may not connect.';
      }
    })
    .catch(() => {
      /* the lobby is not the place to report a failed probe */
    });
});

// Task #51: warm the room DO from the lobby (see prewarmRoom). Three ways a
// room name is known before the click: the URL, the pre-minted "Start a call"
// name, and whatever the user is typing (debounced — every keystroke would
// construct a DO per prefix).
safe(() => {
  pendingMint = mintRoom();
  // This runs BEFORE the deep-link block fills the input, so read the URL the
  // same way it does.
  const urlRoom = location.pathname.match(/^\/([a-z]{3}-[a-z]{4}-[a-z]{3})$/)?.[1]
    ?? new URLSearchParams(location.search).get('r');
  prewarmRoom(urlRoom || pendingMint);
  let warmT = null;
  $('room').addEventListener('input', () => {
    clearTimeout(warmT);
    warmT = setTimeout(() => {
      const r = roomFromInput($('room').value);
      if (r) prewarmRoom(r);
    }, 800);
  });
}, 'prewarm.lobby');

// Deep link: /?r=<id> — the whole join flow for the second person. Named rooms
// from before the mint (?r=morning) still resolve; nothing about old links breaks.
let resumePending = false; // set at boot, consumed once the camera is ready
safe(() => {
  const pathRoom = location.pathname.match(/^\/([a-z]{3}-[a-z]{4}-[a-z]{3})$/)?.[1];
  const urlRoom = pathRoom ?? new URLSearchParams(location.search).get('r');
  // Mid-call refresh / closed window: the live record walks back in without a
  // press. An explicit new invite in the URL outranks it (resumeRoom decides).
  const back = resumeRoom(urlRoom);
  if (back) { resumePending = true; tel?.log('resume', { room: back, viaUrl: back === urlRoom ? 1 : 0 }); }
  const r = urlRoom ?? back;
  if (r) {
    $('room').value = r;
    // Arriving by link means the room is already decided. Leaving its raw
    // 128-bit key sitting in an editable box invites the one thing that breaks
    // it — editing it — and a single changed character puts you alone in a
    // different room, waiting for someone who is standing in the first one.
    $('namedRow').style.display = 'none';
  }
  paintJoinLabel();
}, 'deeplink');

// The telemetry localStorage mirror and the life-size calibration are gone
// (2026-08-04, user directive) — clear what earlier builds left on devices.
safe(() => { localStorage.removeItem('tape.log.mirror'); localStorage.removeItem('tape.cal'); }, 'legacy.clear');

window.__tape = {
  get pc() { return pc; },
  // The live video lane. Exposed so the camera-swap regression (testbed/
  // flip-lane.mjs) can drive adoptTrack the way adoptVideoTrack does — the flip
  // button itself needs two cameras, which a fake-device browser does not have.
  get lane() { return tape; },
  // The real camera-swap path, so the regression test drives the shipped function
  // instead of re-implementing it. Re-implementing it is how the first version of
  // that test replaced the lane 2 carrier and called the result a mystery.
  adopt: (nv) => adoptVideoTrack(nv),
  // The shipped device-switch paths (§15 pickers), for the same reason as
  // `adopt`: the rig must drive what users get, not a re-implementation. A
  // fake-device browser has one mic, so the mic test switches to ITSELF —
  // which still exercises every consumer handoff the real switch performs.
  switchMic: (id) => switchMicTo(id),
  switchCam: (id) => switchCameraTo(id),
  get tel() { return tel; },
  get turns() { return turns; },
  // Task #50 test hook: the recovery harness kills this socket to simulate the
  // network dying under a live call. Read-only access; the app owns lifecycle.
  get ws() { return ws; },
  get stats() { return lastStats; },
  // The custom video lane's own counters. getStats() cannot see this path at all —
  // it is datachannel bytes as far as WebRTC is concerned — so this is the only
  // instrument that exists for it.
  get video() { return tape?.snapshot() ?? null; },
  get tapeMode() { return { wanted: TAPE, running: !!tape, fellBack: tapeFellBack }; },
  // Lane A's own counters — getStats() sees no audio at all on this path.
  get pcm() { return pcm?.snapshot() ?? null; },
  // Lane A's transport decision, the audio twin of tapeMode. `spare` is the one
  // that matters: the Opus sender's track is null while lane A carries the call
  // and non-null once the fallback has revived it, so a test can tell "silent
  // because PCM is working" from "silent because everything failed".
  safetyCode: () => computeSafetyCode(),
  // The code is derived from the MAIN pc, so it only means something if every
  // other association shares that identity. Auditable rather than asserted.
  certAudit: async () => {
    const one = async (c) => {
      const s = await c.getStats();
      let t = null;
      s.forEach((x) => { if (x.type === 'transport' && x.localCertificateId) t = x; });
      return t ? { local: s.get(t.localCertificateId)?.fingerprint ?? null, dtls: t.dtlsState } : null;
    };
    const main = pc ? await one(pc) : null;
    const stripes = [];
    for (const spc of pcmPcs) {
      if (!spc) continue;
      const s = await one(spc);
      // "Not handshaked yet" and "different identity" are opposite findings and
      // must not collapse into one false. Only the second is a security problem.
      stripes.push({ ...(s ?? {}), state: spc.connectionState, seen: !!s?.local, match: !!s?.local && s.local === main?.local });
    }
    return {
      main, stripes,
      pending: stripes.filter((s) => !s.seen).length,
      mismatch: stripes.filter((s) => s.seen && !s.match).length,
      allShare: !!main && stripes.every((s) => s.match),
    };
  },
  get security() {
    // filter, not .length: pcmPcs is indexed from 1 (association 0 rides the main
    // pc), so index 0 is a hole and .length overcounts the stripes by one.
    return { code: safetyCode, sharedCert: !!sharedCert, stripes: pcmPcs.filter(Boolean).length };
  },
  // The reset/recovery state machine's inputs, readable from a live page. Added
  // while diagnosing the second-reset failure (2026-08-05): every one of these
  // has now been the hidden variable in at least one wrong theory, and none of
  // them was observable without a rebuild.
  get callFlags() {
    return { hadPeer, joined, resettingInPlace, leavingDeliberately, activeRoom };
  },
  get pcmMode() {
    return {
      wanted: PCM_AUDIO, running: !!pcm, fellBack: pcmFellBack,
      why: pcmFellBackWhy, spareLive: !!pcmSpareSender?.track,
    };
  },
  // Lane 0 (§3.1 levers 3+4): policy counters; wire counters are in pcm's
  // snapshot (predSent/predRecv/predDup, padBytes*), yield counters in tape's.
  get lane0() { return { enabled: LANE0, ...lane0Stats, listening: lane0Listening() }; },
  // §12–13 stall machine: app-side HOLD state; the video regime and all
  // shed/resume/lane-P counters ride in tape's snapshot (video.stall).
  get stall() { return { enabled: STALL, audioHold, videoHeld }; },
  // §10 session-clock sync: peer offset (min-RTT, 10 s window), drift fit, epoch map.
  get timesync() { return tsync?.snapshot() ?? null; },
  get floorHigh() { return floorHigh; },
  // Task #38: the UI's own state, exposed because a control that CLAIMS muted
  // while the track is live is the exact lie the persistent badge exists to
  // prevent — and under ?pcmaudio=1 the mic is off the peer connection
  // entirely, so getStats and getSenders cannot see it from outside.
  get micEnabled() { return localStream?.getAudioTracks?.()[0]?.enabled ?? null; },
  get chrome() {
    return {
      barShown: $('bar').classList.contains('show'),
      pinnedForMs: Math.max(0, Math.round(barPinnedUntil - performance.now())),
      sheetOpen: $('moreSheet').classList.contains('on'),
      leaveArmed,

    };
  },
  // Task #37: the weak-device ladder's decision (tier, why, ceiling) and the
  // join-armed source probe's counters — both exist so a testbed arm can assert
  // the clamp landed without parsing telemetry.
  get devTier() { return { tier: resolveDevTier(), why: devTierWhy, ceiling: devCeiling(), ladder: DEV_LADDER, measure: DEV_MEASURE, stepTier: devStepTier ?? resolveDevTier() }; },
  // The whole frame-rate decision, readable from a harness: our display, theirs, and
  // which of the three inputs actually bound the send rate.
  get hz() { return { local: localHz, peerHz, peerHzRaw, target: targetFps() }; },
  get srcprobe() {
    if (!srcProbe) return null;
    // `settings` and `caps` ride here so `phone-test.sh` can read the camera's
    // ACTUAL exposure/iso/size off the device without parsing telemetry — the
    // exposure numbers are the whole task #37 measurement.
    return {
      frames: srcProbe.frames,
      armedAt: srcProbe.t0,
      settings: safe(() => srcProbe.track.getSettings?.(), 'dbg.srcprobe.settings') ?? null,
      caps: safe(() => srcProbe.track.getCapabilities?.(), 'dbg.srcprobe.caps') ?? null,
      readyState: srcProbe.track.readyState,
      enabled: srcProbe.track.enabled,
    };
  },
  get lowlight() { return { on: lowlightOn, enabled: LOWLIGHT_ON, expOverride: LOWLIGHT_EXP || null, revive: REVIVE_ON }; },
  // High-motion A/B: the encoder's adaptation policy as ASKED (the four constants) and as
  // Chrome actually ACCEPTED it (getParameters read back off the live sender). The two
  // differ in practice — Chrome silently drops a degradationPreference it will not
  // honour — so an A/B arm must assert the accepted side, not the asked side.
  get encpolicy() {
    const asked = { contentHint: V_HINT, degradationPreference: V_DEGRADE, maxFramerate: targetFps().fps, scaleResolutionDownBy: V_SCALEDOWN };
    const s = pc?.getSenders?.().find((x) => x.track?.kind === 'video');
    const p = safe(() => s?.getParameters?.(), 'dbg.encpolicy') ?? null;
    return {
      asked,
      trackHint: safe(() => localStream?.getVideoTracks?.()[0]?.contentHint, 'dbg.encpolicy.hint') ?? null,
      accepted: p ? { degradationPreference: p.degradationPreference ?? null, maxFramerate: p.encodings?.[0]?.maxFramerate ?? null, scaleResolutionDownBy: p.encodings?.[0]?.scaleResolutionDownBy ?? null, maxBitrate: p.encodings?.[0]?.maxBitrate ?? null } : null,
    };
  },
  // camLocked = WB/focus lock applied. exposureLocked is a constant false and
  // exists as a tripwire: exposure is never locked (root fix 2026-08-04).
  get camlock() { return { locked: camLocked, exposureLocked: false, blindTicks: lumaBlindTicks }; },
  get luma() { return lumaWin.length ? { y: +lumaWin[lumaWin.length - 1].y.toFixed(1), n: lumaWin.length } : null; },
  view,
  layout,
  paintHud,
  onDetector,
  median,
  // Testbed probes (spectap): a new AudioContext created from CDP has no user
  // gesture and stays suspended (measured: -100 dB analyser floor) — probes
  // must hang off the app's gesture-created, guaranteed-running context.
  get audioCtx() { return audioContext(); },
};

// ── Call-health beacon (task #49) ─────────────────────────────────────────────
// The one number the lab cannot produce: how often REAL calls connect, how
// fast, how long they run, how much audio got concealed. At most two tiny
// same-origin POSTs per call. Everything sent is listed right here — engine
// family (not the UA string), coarse network type, and the call's outcome
// numbers. Never a room code, never an identifier of any kind; the server
// stores nothing about who sent it and rejects any field not on its allowlist.
//
// The lab must not pollute the field: automation (navigator.webdriver) and any
// flagged URL (every harness run carries query params; real users carry none —
// their room ids live in the PATH) are silent. `?hb=1` forces the beacon on so
// the pipe itself stays testable end to end.
safe(() => {
  const hbQs = new URLSearchParams(location.search);
  const forced = hbQs.get('hb') === '1';
  if (!forced && (navigator.webdriver || [...hbQs.keys()].some((k) => k !== 'r'))) return;
  const ua = navigator.userAgent;
  const engine = /Firefox\//.test(ua) ? 'gecko'
    : (/Chrome\/|Chromium\/|CriOS\//.test(ua) ? 'chromium'
      : (/Safari\//.test(ua) ? 'webkit' : 'other'));
  const beat = (o) => {
    const body = JSON.stringify({ v: 1, engine, net: navigator.connection?.effectiveType ?? null, ...o });
    try {
      if (!navigator.sendBeacon('/api/health', new Blob([body], { type: 'application/json' }))) {
        fetch('/api/health', { method: 'POST', body, keepalive: true }).catch(() => {});
      }
    } catch { /* a beacon must never break the call */ }
  };
  let joinAt = 0, connectedAt = 0, hbDone = false;
  // Capture-phase listener: observes the same click the join handler consumes,
  // without touching that handler.
  $('join').addEventListener('click', () => { joinAt ||= performance.now(); }, true);
  window.__hbConnect = () => {
    if (connectedAt) return;
    connectedAt = performance.now();
    beat({ evt: 'connect', ttcMs: joinAt ? Math.round(connectedAt - joinAt) : null });
  };
  window.__hbEnd = (reason) => {
    if (hbDone) return;
    hbDone = true;
    if (!connectedAt) {
      // Joined but the other side never appeared, or it never connected: only
      // a real attempt counts as a failure — an idle lobby close is not one.
      if (joinAt) beat({ evt: 'fail', reason, waitMs: Math.round(performance.now() - joinAt) });
      return;
    }
    const p = window.__tape?.pcm;
    const played = p?.playedFrames, lost = p?.lostFrames;
    beat({
      evt: 'end', reason,
      durS: Math.round((performance.now() - connectedAt) / 1000),
      concealPct: played > 0 && lost != null ? +((100 * lost) / played).toFixed(2) : null,
      tape: window.__tape?.tapeMode?.running ? 1 : 0,
    });
  };
  addEventListener('pagehide', () => window.__hbEnd?.('pagehide'));
}, 'health.beacon');
