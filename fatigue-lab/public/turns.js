/**
 * Turn-taking gate — the falsification test for DESIGN.md §1.1c and §3.1.
 *
 * Boland et al. (2021) measured 297 ms face-to-face and 976 ms over Zoom for the
 * same task. About 179 ms of that gap is not explained by Zoom's latency, and §1.1c
 * attributes it to destroyed turn-end cues. That attribution is an *inference*, and
 * two of the design's three biggest levers rest on it (§17 risk table). This page
 * exists to try to kill it early, before anyone writes an encoder.
 *
 * ── How the measurement works ────────────────────────────────────────────────
 *
 * Everything is timed on ONE clock — the asker's. Two detectors run per machine:
 * one on the local mic, one on the *received* remote audio. So on the asker's side:
 *
 *     t0  = my own speech ends            (local detector, 'end')
 *     t1  = their breath reaches me       (remote detector, 'onset' → 'breath')
 *     t2  = their first word reaches me   (remote detector, 'voiced' or voice onset)
 *
 *     time to first evidence = t1 − t0     ← the honest perceived gap (§1.1c-2)
 *     time to first word     = t2 − t0     ← the metric everyone else reports
 *     breath head start      = t2 − t1
 *
 * No clock synchronisation is involved and none is needed, which removes the single
 * largest source of error a two-machine timing experiment normally has. Network
 * latency is *inside* these numbers rather than added to them, which is correct:
 * we want what the human perceived, not a model of it.
 *
 * The one thing this design cannot see directly is how much of the gap was the
 * human and how much was the wire. So we subtract a continuously measured RTT to
 * get a `human-only` column — that is the number comparable to Boland's 297 ms
 * face-to-face control.
 */

import { attachDetector, audioConstraints, median } from './onset-monitor.js';

const $ = (id) => document.getElementById(id);

// Yes/no questions: fast to comprehend, fast to answer, no thinking time to
// confound the measurement. This is the point of Boland's paradigm — a question
// that requires deliberation measures deliberation, not turn-taking.
const QUESTIONS = [
  'Have you eaten today?',
  'Is it raining where you are?',
  'Do you like coffee?',
  'Are you sitting down?',
  'Have you been to Japan?',
  'Do you have any pets?',
  'Is your phone charged?',
  'Did you sleep well?',
  'Can you drive?',
  'Do you play any instrument?',
  'Are you wearing shoes?',
  'Have you seen the sea this year?',
  'Do you cook?',
  'Is today Tuesday?',
  'Do you have a window near you?',
  'Have you flown recently?',
  'Do you drink tea?',
  'Are the lights on?',
  'Have you read a book this month?',
  'Do you own a bicycle?',
];

const MIN_TURNS = 8;
// Pass band: within 120 ms of Boland's 297 ms face-to-face control, on the
// human-only figure. Stated in §19 phase 3.
const CONTROL_MS = 297;
const PASS_WINDOW_MS = 120;

const state = {
  role: null, // 'a' | 'b'
  turn: null, // 'asker' | 'answerer'
  qIndex: 0,
  phase: 'idle', // idle | prompting | asking | armed | scored
  raw: true,
  peerRaw: null, // the other machine's mode — a mismatched pair produces garbage
  runLabel: '',
  rows: [],
  rttMs: null,
  ctxRate: 48000, // onset-monitor forces 48 kHz; read back from the context at join
  // Armed measurement, asker side only.
  t0: null,
  t1: null,
  t1kind: null,
  t2: null,
};

let pc = null;
let ws = null;
let localStream = null;
let localMon = null;
let remoteMon = null;

function log(...a) {
  const el = $('log');
  el.textContent = `${new Date().toLocaleTimeString()}  ${a.join(' ')}\n${el.textContent}`.slice(0, 6000);
}

const now = () => performance.now();
const send = (m) => ws?.readyState === WebSocket.OPEN && ws.send(JSON.stringify(m));

// ── Event timestamps: ctxTime, never delivery time ───────────────────────────
//
// The worklet posts each event with `ctxTime` — the detector's sample index
// converted onto the AudioContext clock, and both detectors here share ONE
// AudioContext (onset-monitor.js), so local and remote events sit on a common
// origin with sample accuracy. Timestamping on message delivery instead would
// be quietly wrong in the direction that flatters fast turns: an 'end' is only
// *emitted* after HANG_MS (350 ms) of quiet has accumulated, so its delivery is
// ~350 ms after the moment it describes, while a 'classified' lands ~35 ms after
// its onset. Stamping both at receipt would shift t0 ~315 ms later than t1,
// shrinking every measured gap by that much — and pushing genuine ~300 ms
// transitions below zero, where the discard rule would throw away exactly the
// fast turns this experiment exists to collect. (tape-app's live analyser hit
// precisely this bug on a real call; see the long comment in app.js.)
//
// `end` and `voiced` events already carry their sample index backdated to the
// moment they describe, so ctxTime is the right stamp as-is. `classified` is
// emitted at classify time (35 ms after the onset), but carries `onsetAt`, so
// the true onset is recoverable.
const evMs = (ev) => (ev.ctxTime != null ? ev.ctxTime * 1000 : now());
const onsetMs = (ev) =>
  ev.ctxTime != null && ev.onsetAt != null && ev.at != null
    ? ev.ctxTime * 1000 - ((ev.at - ev.onsetAt) / state.ctxRate) * 1000
    : evMs(ev);

// ── Detector events ──────────────────────────────────────────────────────────
function onLocal(ev) {
  if (ev.type === 'level') return;
  const dot = $('dotLocal');
  if (ev.type === 'classified') dot.className = `dot ${ev.kind === 'transient' ? '' : ev.kind}`;
  if (ev.type === 'end') dot.className = 'dot';

  // The asker's own speech ending is what starts the clock.
  if (ev.type === 'end' && state.phase === 'asking') {
    // A forced end means the detector's noise floor was wrong, not that the
    // question ended. Anchoring t0 to it would poison the row.
    if (ev.forced) {
      log(`local end forced (${ev.reason ?? '?'}) — detector floor rebuilt; still listening for the real end`);
      return;
    }
    state.t0 = evMs(ev);
    state.t1 = state.t2 = state.t1kind = null;
    state.phase = 'armed';
    $('prompt').className = 'asking';
    $('hint').textContent = 'question sent — waiting for their reply…';
    log(`t0 — question ended, measuring`);
  }
}

function onRemote(ev) {
  if (ev.type === 'level') return;
  const dot = $('dotRemote');
  if (ev.type === 'classified') dot.className = `dot ${ev.kind === 'transient' ? '' : ev.kind}`;
  if (ev.type === 'end') dot.className = 'dot';

  if (state.phase !== 'armed') return;

  // First evidence: the earliest non-transient thing we hear from them.
  if (ev.type === 'classified' && ev.kind !== 'transient' && state.t1 === null) {
    state.t1 = onsetMs(ev);
    state.t1kind = ev.kind;
    // A turn that opens straight into phonation has no breath lead — t2 is t1.
    if (ev.kind === 'voice') state.t2 = state.t1;
    $('hint').textContent = `first evidence: ${ev.kind}`;
  }

  // First word. `voiced` only fires on a breath-opened turn, which is exactly the
  // case where t1 and t2 differ — i.e. where there is a head start to record.
  if (ev.type === 'voiced' && state.t2 === null) state.t2 = evMs(ev);

  if (state.t1 !== null && state.t2 !== null) score();
}

// ── Scoring ──────────────────────────────────────────────────────────────────
function score() {
  const ttfe = state.t1 - state.t0;
  const voice = state.t2 - state.t0;

  // Discard implausible turns rather than letting them pollute a median. A reply
  // "before" the question ended means they interrupted; over 4 s means they were
  // distracted. Both are real conversational events and neither is a turn
  // transition, which is what we are measuring.
  if (ttfe < 0 || voice > 4000) {
    log(`discarded — ttfe ${ttfe.toFixed(0)} ms, voice ${voice.toFixed(0)} ms (out of range)`);
    nextQuestion();
    return;
  }

  state.rows.push({
    n: state.rows.length + 1,
    q: QUESTIONS[(state.qIndex - 1 + QUESTIONS.length) % QUESTIONS.length],
    ttfe,
    voice,
    credit: state.t2 - state.t1,
    kind: state.t1kind,
    // The human-only figure: strip one round trip. Their reply had to travel to me,
    // and my question had to travel to them, so the full RTT sits inside `voice`.
    human: state.rttMs === null ? null : voice - state.rttMs,
    rtt: state.rttMs,
    raw: state.raw,
    peerRaw: state.peerRaw,
    run: state.runLabel,
  });
  state.phase = 'scored';
  log(`scored #${state.rows.length}: evidence ${ttfe.toFixed(0)} ms, word ${voice.toFixed(0)} ms, opened with ${state.t1kind}`);
  paint();
  setTimeout(nextQuestion, 700);
}

function paint() {
  const R = state.rows;
  $('rows').innerHTML = R.slice()
    .reverse()
    .map(
      (r) => `<tr>
        <td>${r.n}</td>
        <td style="text-align:left;color:#9ca3af">${r.q}</td>
        <td class="ttfe">${r.ttfe.toFixed(0)}</td>
        <td class="voice">${r.voice.toFixed(0)}</td>
        <td>${r.credit > 1 ? r.credit.toFixed(0) : '—'}</td>
        <td>${r.kind}</td>
        <td>${r.human === null ? '—' : r.human.toFixed(0)}</td>
      </tr>`,
    )
    .join('');

  const mt = median(R.map((r) => r.ttfe));
  const mv = median(R.map((r) => r.voice));
  const mc = median(R.filter((r) => r.credit > 1).map((r) => r.credit));
  $('mTtfe').textContent = mt === null ? '—' : `${mt.toFixed(0)} ms`;
  $('mVoice').textContent = mv === null ? '—' : `${mv.toFixed(0)} ms`;
  $('mCredit').textContent = mc === null ? '—' : `${mc.toFixed(0)} ms`;
  $('mRtt').textContent = state.rttMs === null ? '—' : `${state.rttMs.toFixed(0)} ms`;
  $('progress').textContent = `${R.length} scored`;
  $('csv').disabled = R.length === 0;

  verdict(R, mt, mv, mc);
}

function verdict(R, mt, mv, mc) {
  const el = $('verdict');
  if (R.length < MIN_TURNS) {
    el.className = 'verdict pending';
    el.textContent = `Need at least ${MIN_TURNS} scored turns for a verdict — ${R.length} so far.`;
    return;
  }

  const humans = R.map((r) => r.human).filter((h) => h !== null);
  const mh = median(humans);
  const breathRate = (R.filter((r) => r.kind === 'breath').length / R.length) * 100;

  const checks = [
    {
      name: `human-only transition within ${PASS_WINDOW_MS} ms of the ${CONTROL_MS} ms face-to-face control`,
      val: mh === null ? '— (no RTT)' : `${mh.toFixed(0)} ms`,
      ok: mh !== null && Math.abs(mh - CONTROL_MS) <= PASS_WINDOW_MS,
    },
    {
      name: 'majority of turns open with an audible breath',
      val: `${breathRate.toFixed(0)}%`,
      ok: breathRate > 50,
    },
    {
      name: 'breath head start ≥ 100 ms',
      val: mc === null ? '— (none measured)' : `${mc.toFixed(0)} ms`,
      ok: mc !== null && mc >= 100,
    },
    {
      name: 'first evidence beats Zoom’s measured 976 ms',
      val: `${mt.toFixed(0)} ms`,
      ok: mt < 976,
    },
  ];

  const allOk = checks.every((c) => c.ok);
  el.className = `verdict ${allOk ? 'pass' : 'fail'}`;
  el.innerHTML =
    `<b>${allOk ? 'PASS' : 'FAIL'}</b> — ${state.raw ? 'raw' : 'processed'} audio, ${R.length} turns` +
    `<div class="kv" style="margin-top:10px">` +
    checks
      .map(
        (c) =>
          `<span style="color:${c.ok ? 'var(--ok)' : 'var(--bad)'}">${c.ok ? '✓' : '✗'} ${c.name}</span><span>${c.val}</span>`,
      )
      .join('') +
    `</div>` +
    (allOk
      ? ''
      : `<p style="margin:10px 0 0">A FAIL here is information, not a bug. If the human-only figure sits far above 297 ms with raw audio on, §1.1c's attribution of the 179 ms to cue damage is wrong, and §3.1 levers 1–2 need rewriting before anything else gets built.</p>`);
}

// ── Turn sequencing ──────────────────────────────────────────────────────────
function nextQuestion() {
  // Roles alternate so both people are measured as answerer, and so neither
  // learns to anticipate. The asker drives; the answerer just replies.
  const iAsk = state.turn === 'asker';
  state.phase = iAsk ? 'prompting' : 'idle';
  const q = QUESTIONS[state.qIndex % QUESTIONS.length];

  if (iAsk) {
    $('prompt').textContent = q;
    $('prompt').className = 'asking';
    $('hint').textContent = 'read it out loud, then stop';
    state.phase = 'asking';
    send({ type: 'q', index: state.qIndex });
  } else {
    $('prompt').textContent = 'Listen, and answer yes or no.';
    $('prompt').className = 'answering';
    $('hint').textContent = 'answer as soon as you know — do not wait to be polite';
  }
  state.qIndex++;
  $('role').textContent = iAsk ? 'you ask' : 'you answer';
  $('role').className = iAsk ? 'asker' : 'answerer';
  // Discarding only makes sense on the asking side — the asker owns the clock.
  // An answerer-side skip used to re-prompt locally while the asker kept
  // measuring the old question, desyncing the pair.
  $('skip').disabled = !iAsk;
}

function swapRoles() {
  state.turn = state.turn === 'asker' ? 'answerer' : 'asker';
  send({ type: 'swap' });
  nextQuestion();
}

// ── RTT, measured continuously ───────────────────────────────────────────────
// From WebRTC's own candidate-pair stats rather than a ping we build ourselves:
// it's the real media path, and it keeps updating as the route changes.
async function pollRtt() {
  if (!pc) return;
  try {
    const stats = await pc.getStats();
    let best = null;
    stats.forEach((r) => {
      if (r.type === 'candidate-pair' && r.state === 'succeeded' && r.currentRoundTripTime != null) {
        const v = r.currentRoundTripTime * 1000;
        if (best === null || v < best) best = v;
      }
    });
    if (best !== null) {
      state.rttMs = best;
      $('mRtt').textContent = `${best.toFixed(0)} ms`;
    }
  } catch {
    /* transient */
  }
}

// ── Mode handshake ───────────────────────────────────────────────────────────
// A run is only comparable if BOTH machines are in the same audio mode. The raw
// flag is a per-browser checkbox, so nothing structural enforces that — a pair
// where one side forgot to re-tick the box produces data that looks fine and
// means nothing. Exchange the mode over the signaling channel and say so loudly
// on a mismatch.
function sendMode() {
  send({ type: 'mode', raw: state.raw });
}
function notePeerMode(raw) {
  const first = state.peerRaw === null;
  state.peerRaw = raw;
  const el = $('peermode');
  if (raw === state.raw) {
    el.textContent = `peer: ${raw ? 'raw' : 'processed'} — match`;
    el.style.color = 'var(--ok)';
  } else {
    el.textContent = `peer: ${raw ? 'raw' : 'processed'} — MISMATCH, this run will not be comparable`;
    el.style.color = 'var(--bad)';
    log(`MODE MISMATCH — you are ${state.raw ? 'raw' : 'processed'}, peer is ${raw ? 'raw' : 'processed'}. Rejoin with matching modes.`);
  }
  if (first) sendMode(); // answer their announcement with ours, so both sides learn both modes
}

// ── Join ─────────────────────────────────────────────────────────────────────
async function join(code) {
  state.raw = $('raw').checked;
  state.runLabel = $('runlabel').value.trim();
  const ice = await fetch('/api/ice').then((r) => r.json());

  localStream = await navigator.mediaDevices.getUserMedia({
    audio: audioConstraints(state.raw),
  });
  localMon = await attachDetector(localStream, 'local', onLocal);
  state.ctxRate = localMon.ctx.sampleRate;
  $('raw').disabled = true; // the mode is baked into the captured stream; changing it mid-run would silently mix arms
  log(`local detector up · ${localMon.ctx.sampleRate} Hz · ${state.raw ? 'raw' : 'processed'}`);

  pc = new RTCPeerConnection({ iceServers: ice.iceServers || [], bundlePolicy: 'max-bundle' });
  for (const t of localStream.getTracks()) pc.addTrack(t, localStream);

  pc.ontrack = async (e) => {
    if (remoteMon) return;
    // `audible: true` — see onset-monitor.js. A remote stream that isn't sunk to an
    // element never flows, and the failure looks exactly like the peer being silent.
    remoteMon = await attachDetector(e.streams[0], 'remote', onRemote, { audible: true });
    log('remote detector up — measuring incoming audio');
    $('status').textContent = 'measuring';
    $('next').disabled = false;
    $('skip').disabled = false;
    // Whoever is peer 'a' asks first.
    state.turn = state.role === 'a' ? 'asker' : 'answerer';
    nextQuestion();
  };
  pc.onicecandidate = (e) => e.candidate && send({ type: 'ice', candidate: e.candidate });

  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(`${proto}//${location.host}/api/room/${code}/ws`);
  ws.onmessage = async (ev) => {
    const m = JSON.parse(ev.data);
    if (m.type === 'welcome') {
      state.role = m.role;
      $('status').textContent = m.peerPresent ? 'peer here — connecting' : 'waiting for peer…';
      sendMode();
      if (m.peerPresent && state.role === 'a') await offer();
    } else if (m.type === 'peer-joined') {
      sendMode();
      if (state.role === 'a') await offer();
    } else if (m.type === 'mode') {
      notePeerMode(m.raw);
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
    } else if (m.type === 'q') {
      // The peer is asking. Nothing to time on this side — the asker owns the clock.
      state.turn = 'answerer';
      state.phase = 'idle';
      $('prompt').textContent = 'Listen, and answer yes or no.';
      $('prompt').className = 'answering';
      $('role').textContent = 'you answer';
      $('role').className = 'answerer';
      $('hint').textContent = 'answer as soon as you know';
    } else if (m.type === 'swap') {
      state.turn = state.turn === 'asker' ? 'answerer' : 'asker';
      nextQuestion();
    } else if (m.type === 'peer-left') {
      $('status').textContent = 'peer left';
    }
  };
  await new Promise((res) => (ws.onopen = res));
  sendMode();
  setInterval(pollRtt, 1000);
}

async function offer() {
  await pc.setLocalDescription(await pc.createOffer());
  send({ type: 'offer', sdp: pc.localDescription });
}

// ── Controls ─────────────────────────────────────────────────────────────────
$('join').onclick = async () => {
  $('join').disabled = true;
  try {
    await join($('room').value.trim() || 'turns1');
  } catch (e) {
    $('status').textContent = `failed: ${e.message}`;
    $('join').disabled = false;
    log(`join failed: ${e.message}`);
  }
};

$('next').onclick = () => swapRoles();
$('skip').onclick = () => {
  if (state.turn !== 'asker') {
    log('skip is asker-only — the asker owns the measurement clock');
    return;
  }
  state.phase = 'idle';
  nextQuestion();
};

$('csv').onclick = () => {
  const head = 'run,n,question,ttfe_ms,first_word_ms,head_start_ms,opened_with,human_only_ms,rtt_ms,raw_local,raw_peer\n';
  const body = state.rows
    .map((r) =>
      [
        r.run,
        r.n,
        `"${r.q}"`,
        r.ttfe.toFixed(1),
        r.voice.toFixed(1),
        r.credit.toFixed(1),
        r.kind,
        r.human === null ? '' : r.human.toFixed(1),
        r.rtt === null ? '' : r.rtt.toFixed(1),
        r.raw ? 1 : 0,
        r.peerRaw === null ? '' : r.peerRaw ? 1 : 0,
      ].join(','),
    )
    .join('\n');
  const url = URL.createObjectURL(new Blob([head + body], { type: 'text/csv' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = `turns-${state.runLabel ? `${state.runLabel}-` : ''}${state.raw ? 'raw' : 'processed'}-${Date.now()}.csv`;
  a.click();
  URL.revokeObjectURL(url);
};

$('reset').onclick = () => {
  state.rows = [];
  state.phase = state.turn === 'asker' ? 'asking' : 'idle';
  paint();
  log('reset');
};

// Exposed so the scoring path can be driven with synthetic events on a machine
// without two mics — the same trick the geometry in lab.js is verified with.
window.__turns = { state, onLocal, onRemote, paint, score, QUESTIONS };

paint();
