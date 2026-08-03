// Fatigue lab — DESIGN.md §1.1
//
// Five fixes, each independently switchable so you can feel what each one does:
//   1. raw audio        — the turn-taking cue channel, restored
//   2. life size        — faces at conversational distance, not intimate distance
//   3. gaze aligned     — their eyes placed at the camera, so eye contact is real
//   4. no self view     — remove the inescapable mirror
//   5. locked exposure  — stop the webcam hunting
//
// Transport is ordinary WebRTC. That is deliberate: none of the above depends on
// the custom pipeline, so all of it can be tested before the pipeline exists.

const CARD_MM = 85.6;      // ISO/IEC 7810 ID-1 width — a credit card
const D_TARGET_MM = 1100;  // Hall's *personal* distance: where conversation happens.
                           // Not 400mm, which is what filling a laptop screen simulates,
                           // and which the body reads as intimacy or threat.
const EYE_MIN_PX = 24;     // Highest we'll put the eye line. The lens is usually *above*
                           // the viewport entirely, so this bound is what we actually hit.

const $ = (id) => document.getElementById(id);
const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);

const state = { audio: true, lifesize: true, gaze: true, selfview: false, lockcam: true };
const cal = { pxPerMm: null, distMm: 600, eyeLineY: 0.42, headWidthFrac: 0.34, headMm: 150 };
let peerGeom = null;
let pc = null;
let ws = null;
let localStream = null;
let role = null;
let camLockSupported = null;

// ── Calibration: physical screen scale ───────────────────────────────────────
// A browser cannot know its display's real size. CSS pixels are nominally 1/96",
// which is fiction on nearly every modern panel. Matching a known physical object
// is the only reliable way, so we ask for ten seconds of the user's time.
(function cardCalibration() {
  const card = $('card');
  const saved = localStorage.getItem('tape.cal');
  if (saved) Object.assign(cal, JSON.parse(saved));

  const apply = (w) => {
    card.style.width = w + 'px';
    cal.pxPerMm = w / CARD_MM;
    const inches = (w / cal.pxPerMm / 25.4).toFixed(2);
    $('scaleOut').textContent =
      `${cal.pxPerMm.toFixed(3)} px/mm · screen ≈ ${(screen.width / cal.pxPerMm / 25.4).toFixed(1)}" wide`;
    $('cardLabel').textContent = `${inches}" — match your card`;
    persist();
  };

  apply(cal.pxPerMm ? cal.pxPerMm * CARD_MM : 320);

  let dragging = false;
  card.addEventListener('pointerdown', (e) => {
    dragging = true;
    card.setPointerCapture(e.pointerId);
  });
  card.addEventListener('pointermove', (e) => {
    if (!dragging) return;
    apply(clamp(e.clientX - card.getBoundingClientRect().left, 120, 900));
  });
  card.addEventListener('pointerup', () => (dragging = false));
  $('cardReset').onclick = () => apply(320);
})();

function persist() {
  localStorage.setItem('tape.cal', JSON.stringify(cal));
}

// ── Calibration: viewing distance ────────────────────────────────────────────
$('dist').value = cal.distMm;
$('distOut').textContent = `${cal.distMm} mm`;
$('dist').oninput = (e) => {
  cal.distMm = +e.target.value;
  $('distOut').textContent = `${cal.distMm} mm`;
  persist();
  layout();
};

$('headMm').value = cal.headMm;
$('headMm').oninput = (e) => {
  cal.headMm = +e.target.value || 150;
  persist();
  sendGeom();
};

// ── Calibration: face geometry ───────────────────────────────────────────────
// Mirroring the preview doesn't matter here: we only extract an eye-line height
// and a width fraction, both mirror-invariant.
(function faceGeometry() {
  const wrap = $('geomWrap');
  const eye = $('eyeLine');
  const box = $('headBox');

  const paint = () => {
    eye.style.top = cal.eyeLineY * 100 + '%';
    box.style.left = (0.5 - cal.headWidthFrac / 2) * 100 + '%';
    box.style.width = cal.headWidthFrac * 100 + '%';
  };
  paint();

  let mode = null;
  const start = (m) => (e) => {
    mode = m;
    wrap.setPointerCapture(e.pointerId);
    e.preventDefault();
  };
  eye.addEventListener('pointerdown', start('eye'));
  box.addEventListener('pointerdown', start('head'));

  wrap.addEventListener('pointermove', (e) => {
    if (!mode) return;
    const r = wrap.getBoundingClientRect();
    if (mode === 'eye') {
      cal.eyeLineY = clamp((e.clientY - r.top) / r.height, 0.05, 0.9);
    } else {
      // Symmetric about centre — drag either edge.
      const dx = Math.abs((e.clientX - r.left) / r.width - 0.5);
      cal.headWidthFrac = clamp(dx * 2, 0.08, 0.98);
    }
    paint();
    persist();
    sendGeom();
  });
  wrap.addEventListener('pointerup', () => (mode = null));
})();

// ── Capture ──────────────────────────────────────────────────────────────────
async function getVideo() {
  // `exact` frame rate, not `ideal`: recorded video is always precisely 30 fps,
  // and constancy reads as more real than a wobbling 24–60. resizeMode 'none'
  // stops the browser silently rescaling, which would break life-size rendering.
  const s = await navigator.mediaDevices.getUserMedia({
    video: {
      width: { ideal: 1280 },
      height: { ideal: 720 },
      frameRate: { exact: 30 },
      resizeMode: 'none',
    },
  });
  return s.getVideoTracks()[0];
}

async function getAudio(raw) {
  // The four flags. This single object is the difference between "Zoom voice" and
  // a real voice — and more importantly, it restores the audible inhale and room
  // tone that people use to know when it's their turn to speak.
  return (
    await navigator.mediaDevices.getUserMedia({
      audio: raw
        ? {
            echoCancellation: false,
            noiseSuppression: false,
            autoGainControl: false,
            channelCount: 1,
            sampleRate: 48000,
          }
        : { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    })
  ).getAudioTracks()[0];
}

async function setCamLock(on) {
  const t = localStream?.getVideoTracks()[0];
  if (!t) return;
  try {
    await t.applyConstraints(
      on
        ? { exposureMode: 'manual', whiteBalanceMode: 'manual', focusMode: 'manual' }
        : { exposureMode: 'continuous', whiteBalanceMode: 'continuous', focusMode: 'continuous' },
    );
    camLockSupported = true;
  } catch {
    // Constraint support is uneven — best on macOS/Chrome and Android. Degrade
    // quietly rather than blocking, but say so in the readout.
    camLockSupported = false;
  }
  readout();
}

// ── Layout: the two geometric fixes ──────────────────────────────────────────
function layout() {
  const call = $('call');
  const rw = $('remoteWrap');
  const v = $('remote');
  const vw = v.videoWidth;
  const vh = v.videoHeight;

  if (!state.lifesize || !cal.pxPerMm || !peerGeom || !vw || !vh) {
    call.classList.add('fill');
    readout();
    return;
  }
  call.classList.remove('fill');

  // Angular-size match: a head of real width H at distance D subtends H/D. To make
  // it subtend the same angle from the viewer's actual seat, render it at
  // H × D_viewer / D_target.
  const wantHeadMm = peerGeom.headMm * (cal.distMm / D_TARGET_MM);
  const W = (wantHeadMm * cal.pxPerMm) / peerGeom.headWidthFrac;
  const H = W * (vh / vw);
  const headW = W * peerGeom.headWidthFrac;

  // Where the lens sits, in viewport coordinates. camY is almost always *negative*:
  // the lens is above the top of the page, behind the browser's own chrome.
  const chromeH = Math.max(0, window.outerHeight - window.innerHeight);
  const camX = screen.width / 2 - window.screenX; // laptop lens: top-centre of display
  const camY = -(window.screenY + chromeH);

  // Position by the *face*, not by the frame. Hair, ceiling and room are croppable;
  // the head is not. Clamping the frame's top-left is what silently defeated gaze
  // alignment in the first cut of this file: to put an eye line at the top of the
  // viewport, `top` must be about −0.4 H, which no sane frame-based bound allows —
  // so the clamp won every single time and the fix never actually ran.
  let cx = state.gaze ? camX : window.innerWidth / 2;
  let eyeY = state.gaze ? camY : (window.innerHeight - H) / 2 + peerGeom.eyeLineY * H;

  cx = headW >= window.innerWidth
    ? window.innerWidth / 2
    : clamp(cx, headW / 2, window.innerWidth - headW / 2);
  eyeY = clamp(eyeY, EYE_MIN_PX, window.innerHeight * 0.55);

  const left = cx - W / 2;
  const top = eyeY - peerGeom.eyeLineY * H;

  // The number that says whether gaze alignment actually worked: the angle, from the
  // viewer's seat, between "looking at their eyes" and "looking at the lens". Report
  // it rather than claiming success — the browser cannot put pixels behind its own
  // toolbar, so on a windowed page there is always a residual, and fullscreen is
  // what closes it. A measurement the user can act on beats a checkbox.
  const dx = cx - camX;
  const dy = eyeY - camY;
  const offPx = Math.hypot(dx, dy);
  const gazeErrDeg = (Math.atan2(offPx / cal.pxPerMm, cal.distMm) * 180) / Math.PI;

  rw.style.cssText = `left:${left}px;top:${top}px;width:${W}px;height:${H}px`;
  layout.info = { W, H, wantHeadMm, gazeErrDeg, dx, dy, cropped: W > window.innerWidth };
  readout();
}

function readout() {
  const i = layout.info;
  const lines = [];
  if (state.lifesize && i) {
    lines.push(`their head on screen: ${i.wantHeadMm.toFixed(0)} mm`);
    lines.push(`feels like they're at: ${(D_TARGET_MM / 10).toFixed(0)} cm`);
    lines.push(`video: ${i.W.toFixed(0)}×${i.H.toFixed(0)} px${i.cropped ? '  (sides cropped — correct)' : ''}`);
    if (state.gaze) {
      lines.push(`eye contact off by: ${i.gazeErrDeg.toFixed(1)}°`);
      // Name the axis that dominates. Both are cured by fullscreen, but a windowed
      // page usually fails horizontally — the window simply isn't under the lens —
      // and "go fullscreen" alone doesn't tell you why.
      if (i.gazeErrDeg > 2) {
        lines.push(
          Math.abs(i.dx) > Math.abs(i.dy)
            ? `  → ${i.dx < 0 ? 'window sits left of the lens' : 'window sits right of the lens'} — fullscreen fixes it`
            : '  → browser chrome is in the way — fullscreen fixes it',
        );
      }
    }
  } else {
    lines.push('life size: OFF — face fills the screen');
    lines.push(`feels like they're at: ~40 cm (intimate distance)`);
  }
  if (camLockSupported === false) lines.push('exposure lock: not supported here');
  $('readout').textContent = lines.join('\n');
}

// ── Onset monitor: measuring the 200 ms (§3.1 lever 1) ───────────────────────
// Runs on the local mic, so it needs no peer and no network — which is the point.
// The largest claim in the design is that a pre-turn inhale arrives well before the
// first word, and this makes it falsifiable by one person with a microphone.
const turns = { leads: [], count: 0, breaths: 0 };
let onsetCtx = null;
let onsetNode = null;
let pendingOnset = null;

async function startOnsetMonitor(stream) {
  if (onsetCtx) return; // one monitor per page; re-acquiring the mic doesn't restart it

  // `latencyHint: 'interactive'` asks for the smallest render quantum the platform
  // will give. We are measuring latency, so we should not be adding any.
  onsetCtx = new AudioContext({ sampleRate: 48000, latencyHint: 'interactive' });
  await onsetCtx.audioWorklet.addModule('/onset-worklet.js');
  onsetNode = new AudioWorkletNode(onsetCtx, 'onset-detector', { numberOfOutputs: 0 });

  onsetCtx.createMediaStreamSource(stream).connect(onsetNode);
  onsetNode.port.onmessage = (e) => handleOnset(e.data);

  // A gesture-less AudioContext starts suspended in Chrome.
  if (onsetCtx.state === 'suspended') await onsetCtx.resume();
  $('turnState').textContent = `listening · ${onsetCtx.sampleRate} Hz`;
}

function handleOnset(ev) {
  const dot = $('turnDot');
  if (ev.type === 'level') {
    showLevel(ev);
    return;
  }
  if (ev.type === 'onset') {
    pendingOnset = ev;
    dot.className = '';
    $('turnState').textContent = `onset · ${ev.snrDb.toFixed(0)} dB over floor`;
  } else if (ev.type === 'classified') {
    dot.className = ev.kind === 'transient' ? '' : ev.kind;
    $('turnState').textContent =
      ev.kind === 'breath'
        ? 'breath — waiting for words…'
        : ev.kind === 'voice'
          ? 'speaking'
          : 'transient (ignored)';
    if (ev.kind !== 'transient') turns.count++;
    if (ev.kind === 'breath') {
      turns.breaths++;
      logTurn({ kind: 'breath', lead: null });
    } else if (ev.kind === 'voice') {
      // A turn that started straight into phonation. Honest zero: no credit.
      logTurn({ kind: 'no breath', lead: 0 });
    }
  } else if (ev.type === 'voiced') {
    dot.className = 'voice';
    turns.leads.push(ev.leadMs);
    updateTurnLog(ev.leadMs);
    $('turnState').textContent = `speaking · breath led by ${ev.leadMs.toFixed(0)} ms`;
  } else if (ev.type === 'end') {
    dot.className = '';
    $('turnState').textContent = 'listening';
  }
  stats();
}

let logRows = [];
function logTurn(row) {
  logRows.unshift(row);
  logRows = logRows.slice(0, 40);
  paintLog();
}
function updateTurnLog(lead) {
  const row = logRows.find((r) => r.kind === 'breath' && r.lead === null);
  if (row) row.lead = lead;
  paintLog();
}
function paintLog() {
  $('turnLog').innerHTML = logRows
    .slice(0, 12)
    .map((r) => {
      const lead = r.lead === null ? '…' : `${r.lead.toFixed(0)} ms`;
      const w = r.lead ? Math.min(100, (r.lead / 400) * 100) : 0;
      return `<div><span class="kind">${r.kind}</span><span class="lead">${lead.padStart(7)}</span><span class="bar" style="max-width:${w}%"></span></div>`;
    })
    .join('');
}

function stats() {
  const L = turns.leads;
  if (!L.length) {
    $('turnStats').textContent = `${turns.count} turn(s), none opened with a detected breath yet`;
    return;
  }
  const s = [...L].sort((a, b) => a - b);
  const med = s[Math.floor(s.length / 2)];
  const pct = ((turns.breaths / Math.max(turns.count, 1)) * 100).toFixed(0);
  $('turnStats').textContent =
    `${turns.count} turns · ${pct}% opened with a breath · ` +
    `median lead ${med.toFixed(0)} ms (min ${s[0].toFixed(0)}, max ${s[s.length - 1].toFixed(0)}) · ` +
    `→ that is how much earlier your peer knows you're replying`;
}

// Map −70..0 dBFS onto the meter width.
const dbToPct = (dbfs) => clamp(((dbfs + 70) / 70) * 100, 0, 100);

function showLevel(ev) {
  $('meter').style.right = `${100 - dbToPct(ev.rmsDb)}%`;
  if (ev.floorDb !== null) $('meterFloor').style.left = `${dbToPct(ev.floorDb)}%`;
}

$('onsetReset').onclick = () => {
  turns.leads = [];
  turns.count = 0;
  turns.breaths = 0;
  logRows = [];
  paintLog();
  stats();
};

// ── Signaling + WebRTC ───────────────────────────────────────────────────────
function send(m) {
  if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(m));
}

function sendGeom() {
  send({
    type: 'geom',
    geom: { eyeLineY: cal.eyeLineY, headWidthFrac: cal.headWidthFrac, headMm: cal.headMm },
  });
}

async function join(code) {
  const ice = await fetch('/api/ice').then((r) => r.json());

  const vTrack = await getVideo();
  const aTrack = await getAudio(state.audio);
  localStream = new MediaStream([vTrack, aTrack]);
  $('preview').srcObject = localStream;
  $('self').srcObject = localStream;

  // Let auto-exposure settle on the real scene, then freeze it.
  setTimeout(() => setCamLock(state.lockcam), 2500);

  pc = new RTCPeerConnection({ iceServers: ice.iceServers || [], bundlePolicy: 'max-bundle' });
  for (const t of localStream.getTracks()) pc.addTrack(t, localStream);

  // Stop WebRTC shrinking the picture — resolution adaptation would silently
  // destroy life-size rendering. (The real fix is §6; this is the lab's stopgap.)
  for (const s of pc.getSenders()) {
    if (s.track?.kind !== 'video') continue;
    const p = s.getParameters();
    p.degradationPreference = 'maintain-resolution';
    p.encodings = p.encodings?.length ? p.encodings : [{}];
    p.encodings[0].maxBitrate = 6_000_000;
    try {
      await s.setParameters(p);
    } catch {
      /* not fatal */
    }
  }

  pc.ontrack = (e) => {
    $('remote').srcObject = e.streams[0];
  };
  pc.onicecandidate = (e) => e.candidate && send({ type: 'ice', candidate: e.candidate });

  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(`${proto}//${location.host}/api/room/${code}/ws`);
  ws.onmessage = async (ev) => {
    const m = JSON.parse(ev.data);
    if (m.type === 'welcome') {
      role = m.role;
      $('joinStatus').textContent = m.peerPresent ? 'peer here' : 'waiting for peer…';
      if (m.peerPresent && role === 'a') await offer();
      sendGeom();
    } else if (m.type === 'peer-joined') {
      sendGeom();
      if (role === 'a') await offer();
    } else if (m.type === 'offer') {
      await pc.setRemoteDescription(m.sdp);
      await pc.setLocalDescription(await pc.createAnswer());
      send({ type: 'answer', sdp: pc.localDescription });
    } else if (m.type === 'answer') {
      await pc.setRemoteDescription(m.sdp);
    } else if (m.type === 'ice') {
      try {
        await pc.addIceCandidate(m.candidate);
      } catch {
        /* ignore */
      }
    } else if (m.type === 'geom') {
      peerGeom = m.geom;
      layout();
    } else if (m.type === 'peer-left') {
      $('hint').textContent = 'peer left';
    }
  };
  await new Promise((res) => (ws.onopen = res));

  $('lobby').style.display = 'none';
  $('call').style.display = 'block';
  applyToggles();
}

async function offer() {
  await pc.setLocalDescription(await pc.createOffer());
  send({ type: 'offer', sdp: pc.localDescription });
}

// ── Toggles ──────────────────────────────────────────────────────────────────
function applyToggles() {
  for (const k of Object.keys(state)) {
    const el = $(`t-${k}`);
    if (el) el.dataset.on = state[k] ? '1' : '0';
  }
  $('selfWrap').classList.toggle('on', state.selfview);
  layout();
}

for (const k of ['lifesize', 'gaze', 'selfview']) {
  $(`t-${k}`).onclick = () => {
    state[k] = !state[k];
    applyToggles();
  };
}

$('t-lockcam').onclick = async () => {
  state.lockcam = !state.lockcam;
  applyToggles();
  await setCamLock(state.lockcam);
};

$('t-audio').onclick = async () => {
  state.audio = !state.audio;
  applyToggles();
  const t = await getAudio(state.audio);
  const sender = pc?.getSenders().find((s) => s.track?.kind === 'audio');
  if (sender) await sender.replaceTrack(t);
  for (const old of localStream.getAudioTracks()) {
    old.stop();
    localStream.removeTrack(old);
  }
  localStream.addTrack(t);
};

// Hold SPACE to flip every *visual* fix off at once — the fastest way to feel
// what they're worth. Audio is excluded because re-acquiring the mic takes long
// enough to be its own distraction; toggle that one deliberately.
let held = null;
addEventListener('keydown', (e) => {
  if (e.code !== 'Space' || held || $('call').style.display !== 'block') return;
  e.preventDefault();
  held = { ...state };
  Object.assign(state, { lifesize: false, gaze: false, selfview: true, lockcam: false });
  applyToggles();
  setCamLock(false);
});
addEventListener('keyup', (e) => {
  if (e.code !== 'Space' || !held) return;
  Object.assign(state, held);
  held = null;
  applyToggles();
  setCamLock(state.lockcam);
});

// ── Chrome-free UI: controls appear on intent, then leave ─────────────────────
let hideTimer;
addEventListener('pointermove', () => {
  $('panel').classList.add('show');
  clearTimeout(hideTimer);
  hideTimer = setTimeout(() => $('panel').classList.remove('show'), 2200);
});

$('fs').onclick = () => document.documentElement.requestFullscreen?.();
$('leave').onclick = () => location.reload();
$('remote').addEventListener('loadedmetadata', layout);
addEventListener('resize', layout);

// There is no event for "the user moved the window", but gaze alignment depends
// on where the window sits relative to the lens, so poll for it.
let lastPos = '';
setInterval(() => {
  const p = `${window.screenX},${window.screenY}`;
  if (p !== lastPos) {
    lastPos = p;
    layout();
  }
}, 500);

// Exposed for devtools poking — the geometry and the turn measurements are the two
// parts worth inspecting. `startOnsetMonitor` is exposed so the detector can be
// driven from a synthetic AudioBufferSource on machines where the mic is
// unavailable, which is how the UI path gets verified.
window.__lab = {
  state,
  cal,
  layout,
  get peerGeom() { return peerGeom; },
  set peerGeom(g) { peerGeom = g; },
  turns,
  handleOnset,
  startOnsetMonitor,
  get onsetCtx() { return onsetCtx; },
};

$('join').onclick = async () => {
  $('join').disabled = true;
  try {
    await join($('room').value.trim() || 'lab1');
  } catch (e) {
    $('joinStatus').textContent = `failed: ${e.message}`;
    $('join').disabled = false;
  }
};

// Live preview during calibration, before joining.
//
// The mic here is acquired separately from the call's audio track and is *always*
// raw, whatever the `raw audio` toggle is set to. That's deliberate: the onset
// monitor is an instrument, and an instrument whose sensitivity changes when you
// flip the thing you're measuring is useless. It also means you can A/B processed
// vs raw call audio while the measurement stays comparable.
navigator.mediaDevices
  .getUserMedia({ video: { width: { ideal: 1280 }, frameRate: { ideal: 30 } } })
  .then((s) => ($('preview').srcObject = s))
  .catch(() => ($('joinStatus').textContent = 'camera unavailable'));

navigator.mediaDevices
  .getUserMedia({
    audio: {
      echoCancellation: false,
      noiseSuppression: false,
      autoGainControl: false,
      channelCount: 1,
      sampleRate: 48000,
    },
  })
  .then((s) => startOnsetMonitor(s))
  .catch((e) => ($('turnState').textContent = `mic unavailable — ${e.name}`));
