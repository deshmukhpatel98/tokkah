// Split out of calls.html because the site's Content-Security-Policy is
// `script-src 'self'`: an inline <script> is blocked outright, which showed up
// as a page that rendered its static fallback text and never loaded anything.
// ── What "good" means lives HERE, not in the app ─────────────────────────────
//
// The app posts raw numbers only. Thresholds change as the target moves, and
// changing an opinion should not require every installed copy to update first.
//
// The hard target is 150 ms mouth-to-ear anywhere on earth. Distance is not a
// defect, so latency is judged as OVERHEAD ABOVE PROPAGATION: half the measured
// round trip is the part physics charges for, and everything else is ours.
const num = (v) => (typeof v === 'number' && isFinite(v) ? v : null);

function grade(v, goodBelow, badAbove) {
  if (v === null) return '';
  if (v <= goodBelow) return 'good';
  if (v >= badAbove) return 'bad';
  return 'warn';
}

function analyse(c) {
  const rtt = num(c.rtt_ms);
  const m2e = num(c.m2e_p50);
  const prop = rtt !== null ? rtt / 2 : null;
  const over = m2e !== null && prop !== null ? m2e - prop : null;
  const g2g = num(c.g2g_p50);
  const gOver = g2g !== null && prop !== null ? g2g - prop : null;

  const cards = [];
  const push = (k, v, note, cls) => cards.push({ k, v, note, cls });

  if (m2e !== null) {
    push('voice, ear to ear', m2e.toFixed(1) + ' ms',
         over !== null ? (over >= 0 ? '+' : '') + over.toFixed(1) + ' ms over distance' : 'no round trip yet',
         over !== null ? grade(over, 15, 40) : grade(m2e, 30, 80));
  }
  if (num(c.m2e_p99) !== null) {
    push('worst 1% of voice', num(c.m2e_p99).toFixed(1) + ' ms',
         m2e !== null ? '+' + (num(c.m2e_p99) - m2e).toFixed(1) + ' vs typical' : '',
         grade(num(c.m2e_p99) - (m2e ?? 0), 3, 15));
  }
  if (g2g !== null) push('picture', g2g.toFixed(0) + ' ms',
      gOver !== null ? '+' + gOver.toFixed(0) + ' over distance' : '',
      gOver !== null ? grade(gOver, 25, 90) : grade(g2g, 60, 150));
  if (rtt !== null) push('round trip', rtt.toFixed(1) + ' ms',
      num(c.rtt_jit_ms) !== null ? '±' + num(c.rtt_jit_ms).toFixed(1) + ' jitter' : '', '');

  // Gaps in the sound are what people actually notice, so this is graded hard.
  const cps = num(c.conceal_ps);
  if (cps !== null) push('gaps in sound', cps === 0 ? 'none' : cps + '/s',
      num(c.conceal_total) ? num(c.conceal_total) + ' total' : 'clean', grade(cps, 0, 5));

  const lost = num(c.conceal_lost), late = num(c.late);
  if (lost !== null) push('packets lost', String(lost),
      late !== null ? late + ' arrived late' : '', grade(lost, 0, 50));

  if (num(c.jit) !== null) push('safety buffer', num(c.jit) + ' pkt',
      (num(c.jit) * 0.67).toFixed(1) + ' ms held back', grade(num(c.jit), 4, 10));

  const up = num(c.up_mbps), down = num(c.down_mbps);
  if (up !== null) push('bandwidth', up.toFixed(2) + ' / ' + (down ?? 0).toFixed(2),
      'Mbps up / down', grade(Math.max(up, down ?? 0), 1.4, 3));

  const lin = num(c.lp_in), lout = num(c.lp_out);
  if (lin && lout) push('compression', (lin / lout).toFixed(2) + '×', 'lossless', 'good');

  // ── Picture ────────────────────────────────────────────────────────────────
  const fpsOut = num(c.v_dec_ps), fpsIn = num(c.v_enc_ps);
  if (fpsIn !== null || fpsOut !== null) {
    push('frame rate', (fpsOut ?? fpsIn) + '/s',
         fpsIn !== null && fpsOut !== null && fpsIn !== fpsOut ? 'sending ' + fpsIn + '/s' : 'received',
         grade(30 - (fpsOut ?? 0), 6, 15));
  }
  if (num(c.v_mbps) !== null) {
    push('picture data', num(c.v_mbps).toFixed(2) + ' Mbps',
         num(c.v_bytes_frame) ? num(c.v_bytes_frame) + ' B/frame' : '', '');
  }
  if (num(c.v_frames_lost) !== null) {
    push('frames lost', String(num(c.v_frames_lost)),
         num(c.v_repair_keys) ? num(c.v_repair_keys) + ' repairs asked' : 'none needed',
         grade(num(c.v_frames_lost), 0, 60));
  }
  // A percentile over a tenth of the frames is not a latency, so below half
  // coverage this refuses to show a number rather than showing a flattering one.
  const cov = num(c.v_glass_cov), glass = num(c.v_glass_ms_p50);
  if (glass !== null && cov !== null) {
    if (cov >= 0.5) push('decode to screen', glass.toFixed(2) + ' ms',
                         Math.round(cov * 100) + '% of frames', grade(glass, 8, 25));
    else push('decode to screen', 'withheld',
              'only ' + Math.round(cov * 100) + '% of frames were shown', 'warn');
  }

  // ── THE PICTURE'S OWN QUALITY, WHICH NOTHING HERE USED TO MENTION ──────────
  //
  // "It goes pixelated when the person moves" is the single most common thing
  // anyone says about a video call, and every number needed to explain it was
  // being collected and thrown away: which rung of the quality ladder the
  // encoder settled on, how many times it stepped down, and how much motion it
  // was carrying when it did.
  //
  // Bitrate alone cannot answer it. Under live rate control a cheaper picture
  // shows up as a LOWER QUALITY at the same Mbps, not as fewer bits -- so a call
  // that looks terrible and a call that looks perfect can be the same 3 Mbps.
  const q = num(c.v_quality), qdown = num(c.v_q_downs), motion = num(c.v_motion);
  if (q !== null) {
    // 0.7 is the top rung, 0.5 the bottom one this version will use. A call
    // pinned to the bottom rung IS the pixelation complaint.
    push('picture quality', q.toFixed(2),
         q <= 0.5 ? 'lowest it will go' : (q >= 0.7 ? 'full' : 'reduced'),
         q >= 0.7 ? 'good' : (q > 0.5 ? 'warn' : 'bad'));
  }
  if (qdown !== null && (qdown || num(c.v_q_ups))) {
    push('quality changes', qdown + ' down / ' + (num(c.v_q_ups) ?? 0) + ' up',
         'the encoder giving in and recovering', qdown > 6 ? 'warn' : '');
  }
  if (motion !== null) {
    push('motion', String(motion),
         'how much the picture was changing', '');
  }
  // Direct or relayed. A relayed call goes through a third machine and gets the
  // bandwidth that machine feels like giving it -- which looks exactly like a
  // camera problem from the sofa.
  if (num(c.route)) {
    push('route', num(c.route) === 2 ? 'relayed' : 'direct',
         num(c.route) === 2 ? 'through a relay, not peer to peer' : 'peer to peer',
         num(c.route) === 2 ? 'warn' : 'good');
  }

  // Things the person on the call cannot see, and would never think to mention.
  const faults = [];
  const fault = (n, label) => { if (num(n)) faults.push(num(n) + ' ' + label); };
  fault(c.stalls, 'audio stall(s)');
  fault(c.rate_events, 'device sample-rate change(s)');
  fault(c.render_errs, 'render error(s)');
  fault(c.fmt_mismatch, 'packets refused for version mismatch');
  fault(c.peer_restarts, 'peer restart(s)');
  fault(c.relocks, 're-found the peer');
  fault(c.snaps, 'cursor jump(s)');
  fault(c.lp_bad, 'undecodable payload(s)');
  fault(c.v_dec_fails, 'video frame(s) failed to decode');
  fault(c.v_partial_drops, 'part-arrived video frame(s) dropped');
  fault(c.v_no_fmt, 'video frame(s) arrived before the format did');
  fault(c.v_enq_fail, 'frame(s) the window refused');
  fault(c.crypt_bad, 'packets failed to decrypt');
  if (num(c.audit_delta)) faults.push('SAMPLE AUDIT OFF BY ' + num(c.audit_delta));
  if (num(c.crypt) === 0) faults.push('NOT ENCRYPTED');

  // ── FAULTS NOBODY WOULD EVER REPORT ─────────────────────────────────────────
  //
  // A call that rang underneath the window someone was working in is a MISSED
  // call from their side, and it leaves no trace in any audio or video number on
  // this page. Same for a Mac whose login item failed to install: it is not
  // callable while Kin is closed, and it will never say so.
  // Said in the words somebody would actually use to complain about it.
  if (q !== null && q <= 0.5) {
    faults.push('the picture ran at its LOWEST quality' +
      (motion ? ' while the scene was moving (motion ' + motion + ')' : ''));
  }
  if (qdown !== null && qdown > 6) faults.push(qdown + ' quality drops -- the picture kept giving in');
  if (num(c.route) === 2) faults.push('relayed, not peer to peer');
  // The one cause of blockiness that no amount of bitrate on our side can fix.
  const pf = (c.facts || {}).cam_pixfmt;
  if (pf === 'dmb1' || pf === 'jpeg') {
    faults.push('the CAMERA hands us already-compressed frames (' + pf +
      ') -- blockiness on movement is baked in before our encoder sees it');
  }

  const ev = c.events || {}, tapf = c.tap_fails || {};
  // ── THE APP FELL OVER, AND THIS CALL IS THE ONE THAT SAW IT ────────────────
  //
  // A crash is reported by the launch AFTER the one that died, so it arrives on
  // a different row from the call it ended. These counters are on the row that
  // did the reporting, and they are here so that somebody reading one call
  // cannot miss the fact that this Mac has been falling over -- the Crashes
  // panel at the top of the page is where the detail is.
  if (ev.crash_found) {
    faults.push('THIS MAC CRASHED ' + ev.crash_found + '× -- see Crashes at the top of this page');
  }
  if (ev.died_without_ending) {
    faults.push('the app DIED WITHOUT SAYING GOODBYE ' + ev.died_without_ending
      + '× -- no crash report, so a hang, a force quit or a kill');
  }
  if (ev.crash_send_fail) faults.push('a crash report could not be delivered and is still waiting');
  if (ev.ring_front_fail) faults.push(ev.ring_front_fail + ' ring(s) stayed BEHIND other windows');
  if (ev.ring_no_window) faults.push(ev.ring_no_window + ' ring(s) had no window to show');
  if (ev.watch_install_fail) faults.push('this Mac CANNOT be rung while Kin is closed');
  if (ev.ring_sent_fail) faults.push(ev.ring_sent_fail + ' dialled call(s) never reached the server');
  // The ring preview failing leaves no trace anywhere else on this page: the
  // card still appears and both buttons still work, so a black rectangle where
  // a face should be is a fault nobody on either end would ever report.
  if (ev.ring_preview_off) faults.push('the ring card could NOT show who was calling');
  if (ev.ring_preview_open && num(c.v_frags) > 0 && !num(c.v_decoded)) {
    faults.push('their video reached the ring card and NOT ONE frame was decoded');
  }
  if (ev.ring_preview_open && num(c.v_decoded) > 0 && num(c.v_shown) === 0) {
    faults.push('the caller\u2019s picture was decoded and NEVER DRAWN on the ring card');
  }
  // The whole feature in one line: a preview that opened, their video arriving,
  // and the app never once announcing a picture. The two rules above name the
  // stage that failed; this one fires even when both of them are satisfied and
  // the face still never appeared.
  if (ev.ring_preview_open && num(c.v_frags) > 0 && !ev.ring_preview_picture) {
    faults.push('the ring card never showed the caller\u2019s face');
  }
  if (ev.ring_preview && (num(c.cap_callbacks) || num((c.marks || {}).cam_first_frame_ms) !== null)) {
    faults.push('a RING NOBODY ANSWERED opened the microphone or the camera');
  }
  // A button that was pressed and did nothing. The user asked for exactly this.
  Object.keys(tapf).forEach((k) => faults.push(
    tapf[k] + '× "' + k + '" was pressed and did NOT work'));

  // A red metric IS something that needs fixing, so it has to appear in the list
  // underneath. The first version listed only `faults`, so a call could be
  // labelled "Needs fixing" over a red card and then say "nothing broken to
  // report" one line below it -- which is the report contradicting itself.
  const badCards = cards.filter((x) => x.cls === 'bad');
  const warnCards = cards.filter((x) => x.cls === 'warn');
  const reasons = badCards.map((x) => x.k + ' is ' + x.v + (x.note ? ' (' + x.note + ')' : ''))
    .concat(faults);
  let verdict = 'Good', vcls = 'good';
  if (reasons.length) { verdict = 'Needs fixing'; vcls = 'bad'; }
  else if (warnCards.length) { verdict = 'Usable, not ideal'; vcls = 'warn'; }
  // A beat with nothing in it is not a good call, it is no information. Grading it
  // "Good" is a verdict that cannot fail, which is the same as no verdict at all.
  else if (!cards.length) { verdict = 'No data'; vcls = 'dim'; }
  return { cards, faults, reasons, verdict, vcls, over, m2e,
           ledger: ledgerOf(c), todo: verdicts(c) };
}

// ── WHAT HAPPENED, IN WORDS ──────────────────────────────────────────────────
//
// Every counter the app keeps was already being stored and none of it was ever
// shown: buttons pressed, rings arriving, how long the camera took. A number
// collected and never displayed is not analytics, it is disk usage.
//
// Names, not keys. `ring_recv_watch` is meaningless to read at speed; "rung
// while Kin was closed" is the actual finding, and it is the one thing nobody
// could previously answer about this app.
const EVENT_WORDS = {
  ring_recv_watch: 'rung while Kin was CLOSED',
  ring_recv: 'rung while Kin was open',
  ring_ui_shown: 'the ring was shown',
  ring_front_ok: 'the ring came to the front',
  ring_front_fail: 'the ring stayed behind other windows',
  ring_no_window: 'the ring had no window',
  // ── SEEING WHO IS CALLING, BEFORE ANSWERING ───────────────────────────────
  //
  // A Mac that is being rung now joins the room and takes the caller's picture
  // while the card is still asking, so somebody can see who it is before
  // deciding. It sends nothing back -- no microphone, no camera, no sound
  // played -- and it tells the caller it is only RINGING, so that packets
  // arriving are not read as somebody having said yes.
  ring_offered: 'somebody was asked here whether to take a call',
  ring_preview: 'the card could show who was calling',
  ring_preview_off: 'the card could NOT show who was calling -- a name and nothing else',
  ring_preview_picture: 'the caller\u2019s video reached the ring card',
  ring_preview_open: 'the ring card joined the call to fetch their picture',
  peer_ringing_seen: 'the far end said it was still RINGING, not answered',
  ring_tone_apple: 'rang with Apple\u2019s own ringtone',
  ring_tone_fallback: 'no ringtone on this Mac -- a system alert instead',
  ring_tone_muted: 'the ring made NO SOUND -- this copy was muted',
  ring_answered: 'answered',
  ring_declined: 'declined',
  ring_key_changed: 'the caller rang with a DIFFERENT key',
  ring_known: 'a caller this Mac has spoken to before',
  ring_sent_try: 'dialled a handle',
  ring_sent_ok: 'the dialled ring was accepted',
  ring_sent_fail: 'the dialled ring FAILED',
  watch_installed: 'the login item was (re)installed',
  watch_present: 'the login item was already healthy',
  watch_install_fail: 'the login item FAILED to install',
  connects: 'connected to the other person',
  video_pause: 'OUR video stopped -- our link could not carry it',
  video_resume: 'our video came back',
  peer_video_pause: 'THEIR video stopped -- their link could not carry it',
  peer_video_resume: 'their video came back',
  peer_cam_off: 'they turned their camera off',
  peer_cam_on: 'they turned their camera back on',
  peer_muted: 'they muted their microphone',
  peer_unmuted: 'they unmuted',
  peer_left: 'the other person left',
  rediscoveries: 'they went quiet and had to be found again at a new address',
  // ── Hanging up, which used to be something nobody could see ───────────────
  bye_sent_try: 'told them the call was off',
  bye_sent_ok: 'and they were told',
  bye_sent_fail: 'and telling them FAILED -- they waited out the timeout',
  bye_recv_calling: 'they hung up on us before we gave up',
  bye_recv_ringing: 'the caller stopped calling while this Mac was ringing',
  bye_recv_stale: 'a hang-up arrived for a call this Mac was not on',
  ring_kind_unknown: 'a message this version does not understand was dropped',
  ring_timed_out: 'we rang for 45 seconds and nobody answered',
  ring_to_self: 'tried to call THEMSELVES',
  call_again: 'tried the same person again',
  // ── The doorbell's own health ─────────────────────────────────────────────
  ring_malformed: 'a malformed ring was dropped',
  ring_unverified: 'a ring FAILED VERIFICATION and was never shown',
  poll_ok: 'checked for calls',
  poll_refused: 'the doorbell REFUSED this Mac (401/403) -- it cannot be called',
  poll_rate: 'the doorbell rate-limited this Mac',
  poll_no_answer: 'the doorbell could not be reached at all',
  poll_error: 'the doorbell answered with an error',
  // ── Clicks nobody aimed ───────────────────────────────────────────────────
  card_click_unaimed: 'a click nobody aimed was refused (the window took somebody\u2019s tap)',
  card_first_mouse_refused: 'a click that only brought Kin forward was refused',
  // ── Permissions, which are the difference between silence and a call ──────
  mic_denied: 'MICROPHONE DENIED -- they hear nothing from this end',
  mic_granted: 'microphone allowed',
  cam_denied: 'CAMERA DENIED -- audio only from this end',
  // ── How loud the microphone was set, which nothing on the call reveals ────
  mic_gain_low: 'the microphone input was set BELOW A THIRD -- quiet, and it distorts',
  mic_gain_moved: 'the input level was moved to stop it clipping',
  // ── Being reachable with Kin closed ───────────────────────────────────────
  watch_turned_on: 'switched ON calls-when-closed from the panel',
  watch_turned_off: 'switched OFF calls-when-closed from the panel',
  watch_turn_on_fail: 'switching calls-when-closed on FAILED',
  watch_fix_move: 'asked to move Kin to Applications',
  watch_fix_loginitems: 'sent to Login Items to switch Kin back on',
  // ── Crashes, reported by the launch that came after the one that died ─────
  crash_found: 'THIS MAC HAD CRASHED, and this launch found the report',
  crash_sent: 'and the crash was delivered',
  crash_send_fail: 'a crash report could NOT be delivered -- it is still waiting',
  died_without_ending: 'a previous run DIED WITH NO CRASH REPORT -- a hang, a force quit or a kill',
  died_at_restart: 'a previous run was still open when the Mac restarted',
};
const MARK_WORDS = {
  cam_first_frame_ms: 'camera first frame',
  connected_ms: 'connected',
  link_copyable_ms: 'link ready',
  identity_ready: 'handle ready',
  handle_claimed: 'handle claimed',
  ring_front_ms: 'ring reached the front',
  ring_recv_ms: 'ring arrived',
  ring_sent_ms: 'ring sent',
  ring_preview_ms: 'the ring card reached the caller',
  ring_preview_picture_ms: 'the caller\u2019s face appeared',
  answered_ms: 'answered',
  bye_recv_ms: 'heard they had hung up',
  cancelled_ms: 'cancelled',
  declined_ms: 'declined',
};
// The camera, its pixel format, the encoder, the audio devices. Names, because
// "dmb1" is Motion JPEG and nobody reading a dashboard at speed knows that.
const PIXFMT_WORDS = {
  '420v': 'raw video (420v)',
  '420f': 'raw video, full range (420f)',
  dmb1: 'MOTION JPEG -- already compressed before we re-encode it',
  jpeg: 'JPEG -- already compressed before we re-encode it',
  '2vuy': 'raw video (2vuy)',
};
// `mic_mode_wanted` is a raw AVCaptureDevice.MicrophoneMode, and a bare 0/1/2
// on a dashboard is not a finding. It is only written when the wanted mode and
// the active one disagree, so this row always means "they asked for something
// and did not get it".
const MIC_MODE_WANTED = {
  '0': 'standard',
  '1': 'wide spectrum',
  '2': 'Voice Isolation',
};
// One line for "how did this call go", built from the facts the app now writes
// at each ending. Kept as words rather than a code: this row is the first thing
// read and the only one somebody skimming will read at all.
const OUTCOME_WORDS = {
  talked: 'they talked',
  calling: 'still ringing when this ended -- nobody picked up',
  'no answer': 'rang for 45 seconds, nobody answered',
  cancelled: 'the caller cancelled',
  declined: 'declined',
  'they said no': 'the other end hung up before it connected',
  'could not ring them': 'THE RING NEVER GOT THROUGH',
  'being asked': 'somebody was rung here and never answered or declined',
  answered: 'answered -- see the row this one continues',
  'they hung up before this Mac answered': 'the caller gave up while this Mac was ringing',
};
function ledgerOf(c) {
  const rows = [];
  const fx = c.facts || {};
  if (fx.outcome) rows.push(['how it went', OUTCOME_WORDS[fx.outcome] || fx.outcome]);
  if (fx.path) rows.push(['route', fx.path === 'relay' ? 'through a RELAY (a detour on every packet)' : 'straight to them']);
  if (fx.reachable_closed) {
    rows.push(['reachable with Kin closed',
      fx.reachable_closed === 'yes' ? 'yes' : 'NO -- ' + (fx.reachable_why || 'unknown')]);
  }
  if (fx.mic_access === 'denied' || fx.cam_access) {
    rows.push(['permissions',
      (fx.mic_access === 'denied' ? 'microphone DENIED' : 'microphone ok')
      + (fx.cam_access ? ' · camera ' + fx.cam_access : '')]);
  }
  if (fx.cam) {
    rows.push(['camera', fx.cam + (fx.cam_kind ? ' (' + fx.cam_kind + ')' : '') +
      (fx.cam_mode ? ' · ' + fx.cam_mode : '') +
      (fx.cam_pixfmt ? ' · ' + (PIXFMT_WORDS[fx.cam_pixfmt] || fx.cam_pixfmt) : '')]);
  }
  if (fx.venc) rows.push(['encoder', fx.venc + (fx.venc_bps ? ' · ' + fx.venc_bps + ' bps' : '')]);
  if (fx.mic_dev || fx.spk_dev) {
    rows.push(['audio devices', (fx.mic_dev || '?') + ' → ' + (fx.spk_dev || '?')
      + (fx.mic_mode ? ' · mic mode ' + fx.mic_mode : '')]);
  }
  // Written only when the mode the person picked in Control Center is NOT the
  // one the audio was recorded under -- the header says the active mode differs
  // when the route cannot honour the preference. So the key existing IS the
  // finding, and it explains two calls on one Mac sounding nothing alike.
  if (fx.mic_mode_wanted) {
    rows.push(['mic mode they asked for',
      (MIC_MODE_WANTED[fx.mic_mode_wanted] || fx.mic_mode_wanted)
      + ' -- the route would not give it, so this call ran '
      + (fx.mic_mode || 'something else')]);
  }
  // SPEAKERS OR HEADPHONES, and it is not a detail: on speakers the sound goes
  // into the room and back into the microphone, which is the whole reason the
  // duplex gate exists. Every echo and turn-taking number in this record means
  // something different depending on this one word, and it was never shown.
  if (fx.output_route) {
    rows.push(['they were listening on', fx.output_route === 'speakers'
      ? 'SPEAKERS -- sound went into the room and back into the microphone'
      : 'headphones -- nothing leaked back into the microphone']);
  }
  // "It sounds quiet" and "it sounds distorted" are the same fault below about a
  // third: the gain control makes up the difference and overshoots into clipping.
  if (fx.mic_gain || fx.mic_gain_end || fx.agc) {
    rows.push(['microphone level',
      (fx.mic_gain ? 'set to ' + fx.mic_gain : 'unreadable')
      + (fx.mic_gain_end && fx.mic_gain_end !== fx.mic_gain
          ? ' → moved to ' + fx.mic_gain_end : '')
      + (fx.agc ? ' · automatic gain ' + fx.agc : '')]);
  }
  if (fx.presence) {
    rows.push(['how close they sounded', fx.presence
      + (fx.presence_tail_ms
          ? ' · reflections out to ' + fx.presence_tail_ms + ' ms, which lengthens the echo path'
          : '')]);
  }
  const taps = c.taps || {}, fails = c.tap_fails || {};
  const pressed = Object.keys(taps).sort();
  if (pressed.length) {
    rows.push(['buttons pressed', pressed.map((k) =>
      k + ' ×' + taps[k] + (fails[k] ? ' (' + fails[k] + ' did nothing)' : '')).join(' · ')]);
  }
  // A failure with no successes still has to appear -- it is the whole point.
  Object.keys(fails).filter((k) => !taps[k]).forEach((k) => {
    rows.push(['a button that did nothing', k + ' ×' + fails[k]]);
  });
  // The picture stopping, as a duration rather than an event count: two one-second
  // pauses and one forty-second pause are the same count and a different call.
  const ps = num(c.v_paused_s), pp = num(c.v_peer_paused_s);
  if (ps || pp) {
    const bits = [];
    if (ps) bits.push('ours ' + ps + 's over ' + (num(c.v_pauses) || 0));
    if (pp) bits.push('theirs ' + pp + 's over ' + (num(c.v_peer_pauses) || 0));
    rows.push(['video paused', bits.join(' · ') + ' (audio kept running)']);
  }
  if (num(c.v_peer_cam_off) === 1) rows.push(['their camera', 'off at the end']);
  const sb = num(c.snaps_behind), sp = num(c.snaps_past);
  if (sb || sp) {
    rows.push(['audio cursor repairs',
      (sb || 0) + ' backlog (this Mac fell behind) · ' + (sp || 0)
        + ' starved (ran off the end of the stream)']);
  }
  const ev = c.events || {};
  const evs = Object.keys(ev).sort().map((k) =>
    (EVENT_WORDS[k] || k) + (ev[k] > 1 ? ' ×' + ev[k] : ''));
  if (evs.length) rows.push(['what happened', evs.join(' · ')]);
  const mk = c.marks || {};
  const mks = Object.keys(mk).sort().map((k) => (MARK_WORDS[k] || k) + ' ' + mk[k] + ' ms');
  if (mks.length) rows.push(['timings from launch', mks.join(' · ')]);
  if (c.ended) rows.push(['how it ended', c.ended]);
  // A call answered from a ring is TWO rows in the table, because answering
  // restarts the app. Saying which row this one continues is the only way to
  // read them as one call.
  if (c.prev_call) rows.push(['continues', c.prev_call]);
  return rows;
}

// ── WHAT TO FIX, WORST FIRST ─────────────────────────────────────────────────
//
// The point of a page like this is not to hold numbers, it is to end a
// thirty-second call with a short ordered list of what to work on. Every rule
// below names three things: what went wrong in the words somebody would use to
// complain about it, the evidence, and where the fix lives. A finding with no
// third part is a fact, not a task.
//
// Severity 3 breaks the call, 2 is felt, 1 is worth fixing. Rules stay silent
// when their evidence is missing -- an absent field must never read as a pass.
function verdicts(c) {
  const v = [];
  const add = (sev, what, why, fix) => v.push({ sev, what, why, fix });
  const f = c.facts || {};
  const n = (k) => num(c[k]);
  const ev = c.events || {};
  const e = (k) => ev[k] || 0;

  // ── CAN THIS PERSON BE CALLED AT ALL ─────────────────────────────────────
  //
  // First, above everything about how a call sounded, because a call that never
  // happens has no audio to judge. Every rule here is about the doorbell rather
  // than the media, and each one is a way somebody is quietly unreachable.
  if (f.reachable_closed === 'no') {
    add(2, 'this Mac cannot be rung when Kin is closed',
        f.reachable_why || 'the login item is not running',
        'the panel now offers the fix in one tap -- Calls when Kin is closed.'
          + ' If it says Applications, the copy is somewhere Watch.install refuses.');
  }
  if (e('poll_refused')) {
    add(3, 'the doorbell refused this Mac',
        e('poll_refused') + ' polls came back 401/403 -- nobody can ring this handle',
        'Identity: the registration credential. A handle whose poll is refused is'
          + ' a person who has silently stopped receiving calls.');
  }
  if (e('poll_no_answer') >= 3) {
    add(2, 'the doorbell could not be reached',
        e('poll_no_answer') + ' polls got no answer at all',
        'network, or room.tokkah.com. Calls placed to this Mac land in a mailbox'
          + ' nobody is draining.');
  }
  if (e('ring_unverified')) {
    add(3, 'a ring failed verification and was never shown',
        e('ring_unverified') + ' rings arrived signed by a key that did not check out',
        'Identity.ringMessage -- either somebody is forging rings, or the two ends'
          + ' disagree about what is signed. A version skew here looks exactly'
          + ' like "they called and my Mac never rang".');
  }
  if (e('ring_kind_unknown')) {
    add(1, 'a newer Kin sent something this one does not understand',
        e('ring_kind_unknown') + ' messages were dropped unread',
        'expected while a new message kind is rolling out; it means this copy is'
          + ' the older half of the pair.');
  }

  // ── SEEING WHO IS CALLING ────────────────────────────────────────────────
  //
  // A Mac that is being rung now joins the room and takes the caller's picture
  // while the card is still asking. Every way that fails is SILENT: the card
  // still appears, both buttons still work, and nobody who missed the face ever
  // thinks to report it -- so it has to be found here or not at all.
  const frags = n('v_frags'), decoded = n('v_decoded'), shown = n('v_shown');
  if (e('ring_preview_open') && frags !== null && frags > 0) {
    if ((decoded ?? 0) === 0) {
      add(3, 'the ring never showed who was calling',
          frags + ' pieces of their video arrived while this Mac was ringing and'
            + ' not one frame was decoded',
          'the decode path a ring runs -- the assembler in Net.swift and'
            + ' DecodeQueue. A ring receives and does nothing else, so a preview'
            + ' with no picture has very few places left to be wrong.');
    } else if (shown !== null && shown === 0) {
      add(3, 'the caller\u2019s picture was decoded and never drawn',
          decoded + ' frames were decoded and none of them reached the screen',
          'Display -- the ring card is drawn OVER the picture, and a decode with'
            + ' no draw is the card covering the one thing it exists to show.');
    } else if (!e('ring_preview_picture')) {
      // Every counter above is healthy and the app still never said a picture
      // arrived. Kept as its own branch because it is the case where the parts
      // all report success and the person saw nothing.
      add(3, 'the ring card never announced a picture',
          'their video arrived, decoded and drew, and the app never reached the'
            + ' line that says a frame is on screen',
          'the first-frame block in vdec.onDecoded -- the counters are collected'
            + ' by the video path, this is stamped by the ring itself, and only'
            + ' one of them has ever been wrong.');
    }
  }
  if (e('ring_preview_off')) {
    add(2, 'somebody was rung with no way to see who it was',
        'the ring came up with the preview off -- a name on a card and nothing else',
        'the ring bring-up in main.swift: either no --room arrived with the ring'
          + ' (an older caller, or the watcher dropping it), or TK_RING_PREVIEW=0,'
          + ' or --no-ring-preview. Only the last two are somebody choosing it.');
  }
  // ── AND IT MUST SEND NOTHING ─────────────────────────────────────────────
  //
  // No microphone, no camera, no sound played, until a person says yes. That is
  // the half of this feature nobody on the call can check for themselves, and
  // the half where being wrong is not a defect but a broken promise.
  if (e('ring_preview')) {
    const leaked = [];
    if (n('cap_callbacks')) {
      leaked.push('the microphone was capturing (' + n('cap_callbacks') + ' callbacks)');
    }
    if (num((c.marks || {}).cam_first_frame_ms) !== null) {
      leaked.push('the camera produced a frame at '
        + (c.marks || {}).cam_first_frame_ms + ' ms');
    }
    if (n('played')) {
      leaked.push(n('played') + ' samples of the caller\u2019s voice were played into the room');
    }
    if (leaked.length) {
      add(3, 'a ring nobody had answered opened this Mac up anyway',
          leaked.join(' · '),
          'main.swift: audio.start() is skipped while a ring is only being offered'
            + ' and the camera bring-up is gated on the same thing. One of those'
            + ' two gates did not hold, and they are the whole of what makes the'
            + ' card\u2019s promise true.');
    }
  }
  // The bit that stops a ring answering itself. A Mac that is only being ASKED
  // still punches a hole and still sends packets, and packets arriving is what
  // this app has always read as "they are here" -- which is exactly how a ring
  // answered itself once already.
  if (e('ring_sent_ok') && e('connects') && n('peer_state_reports') === 0) {
    add(3, 'we called it connected without ever being told they had answered',
        'this Mac dialled, the far end joined the room, and no status word ever'
          + ' came back from it -- connected was declared on the two-second'
          + ' deadline alone',
        'the RINGING bit in Net.swift. Either the far end predates the bit, or it'
          + ' stopped being sent -- and the second one is the ring answering'
          + ' itself again, with a card that comes down before anybody agrees.');
  }
  if (e('ring_tone_muted') && !e('ring_tone_apple') && !e('ring_tone_fallback')) {
    add(1, 'the ring made no sound',
        'the card was drawn and this copy was muted, so nothing was heard',
        '--mute, TK_MUTE=1 or TK_NO_RAISE=1. Every test rig passes one of those,'
          + ' so this is expected on a rig and a missed call on anybody else\u2019s Mac.');
  }

  // ── HANGING UP ───────────────────────────────────────────────────────────
  if (e('bye_sent_fail')) {
    add(2, 'the other end was never told the call was off',
        e('bye_sent_fail') + ' hang-ups failed to send',
        'they sat watching a card that said Calling until the 45 s timeout --'
          + ' which is the exact complaint the bye was built to fix.');
  }
  if (e('ring_timed_out')) {
    add(1, 'nobody answered',
        'rang for 45 seconds',
        'not a defect on its own. It is one if it pairs with the callee never'
          + ' recording ring_recv -- then the ring never arrived.');
  }
  if (e('bye_recv_stale')) {
    add(1, 'a hang-up arrived for a call this Mac was not on',
        e('bye_recv_stale') + ' of them',
        'ordinary for a message that outlived its call. Worth looking at if it'
          + ' happens while a call IS in flight -- the two ends would then'
          + ' disagree about which room they are in.');
  }

  // ── CLICKS NOBODY AIMED ──────────────────────────────────────────────────
  if (e('card_click_unaimed') || e('card_first_mouse_refused')) {
    add(1, 'the ring window took somebody\u2019s click',
        (e('card_click_unaimed') + e('card_first_mouse_refused'))
          + ' clicks were refused because nothing suggested anybody aimed them',
        'these were REFUSED, so nothing bad happened -- but each one is a person'
          + ' whose tap went somewhere they did not expect, because Kin threw a'
          + ' window in front of what they were doing.');
  }

  // ── PERMISSIONS ──────────────────────────────────────────────────────────
  if (f.mic_access === 'denied') {
    add(3, 'the microphone was never allowed',
        'macOS denied it, so the far end heard silence for the whole call',
        'System Settings > Privacy & Security > Microphone. Nothing in the audio'
          + ' path can fix this and every audio number below is meaningless.');
  }
  if (f.cam_access && f.cam_access !== 'authorized') {
    add(2, 'the camera was never allowed',
        'macOS said ' + f.cam_access + ' -- this end was audio only',
        'System Settings > Privacy & Security > Camera.');
  }
  if (f.outcome === 'could not ring them') {
    add(3, 'the ring never got through',
        'the doorbell would not take it',
        'Identity.ring -- the status is in the app log. A person who dials a name'
          + ' and gets nothing has no other way to reach that person.');
  }

  // ── Audio ────────────────────────────────────────────────────────────────
  //
  // THE HEADLINE AUDIO NUMBER, because "lossless" is the whole promise and this
  // is the only field that says whether it was kept. Everything the receiver
  // played was either a real sample from the far end's microphone or something
  // this app invented to cover a hole, and this is the ratio between them.
  const cTot = n('conceal_total'), cPlay = n('played');
  if (cTot !== null && cPlay !== null && cPlay + cTot > 0) {
    const pct = (100 * cTot) / (cPlay + cTot);
    // Attribution in the same breath, because the two causes have different fixes
    // and are indistinguishable to the ear. LOST means packets never arrived --
    // loss recovery's problem. STARVED means they arrived too late to be played,
    // which is the jitter buffer being smaller than the path is bumpy.
    const lost = n('conceal_lost') || 0, starv = n('conceal_starved') || 0;
    const why = starv > lost ? 'they arrived too late to play (starvation)'
                             : 'they never arrived (loss)';
    const fixWhere = starv > lost
      ? 'the jitter buffer -- and note it deliberately refuses to grow on some'
        + ' evidence; snaps_behind vs snaps_past says whether the ring was'
        + ' starving or backlogged'
      : 'loss recovery and FEC -- packets are actually going missing';
    if (pct >= 1) {
      add(pct >= 8 ? 3 : pct >= 3 ? 2 : 1, 'the audio was not lossless',
          pct.toFixed(2) + '% of everything played was invented to cover a hole ('
            + lost + ' lost, ' + starv + ' starved) -- ' + why,
          fixWhere);
    }
  }
  // Apple's on-device voice model, and whether this call got it. It is a Control
  // Center toggle the app is not allowed to set, so this is the one finding here
  // whose fix is a person flipping a switch rather than a change to the code.
  if (f.mic_mode && f.mic_mode !== 'voice-isolation') {
    add(1, 'Apple\u2019s Voice Isolation was off',
        'the microphone ran in ' + f.mic_mode + ' mode',
        'menu bar \u2192 Mic Mode \u2192 Voice Isolation. It is an on-device model that'
          + ' strips the room out of a voice, and it is strictly better than the'
          + ' canceller underneath it. Compare echo_corr and erle_db across calls'
          + ' with it on and off before deciding it matters.');
  }
  const hole = n('a_conceal_ms_max');
  if (hole !== null && hole >= 120) {
    add(hole >= 250 ? 3 : 2, 'a word could have been lost',
        'the longest single gap the fill had to cover was ' + Math.round(hole) + ' ms',
        'loss recovery and the jitter buffer floor -- a gap this long is not texture');
  }
  const clip = n('a_clip_pct');
  if (clip !== null && clip > 0.02) {
    add(clip > 0.5 ? 3 : 2, 'the microphone was overloaded',
        clip.toFixed(2) + '% of captured samples were pinned at full scale' +
        (n('a_mic_peak') !== null ? ', peak ' + n('a_mic_peak').toFixed(3) : ''),
        'input gain -- distortion here is destroyed information and nothing downstream can undo it');
  }
  // Correlation ALONE says nothing: it is the delay estimator's confidence, and
  // it goes UP when the canceller is working (measured: 0.10 with cancellation
  // off, 0.76 with it on). Echo is "the path was clearly visible AND almost
  // nothing was removed from it".
  const corr = n('echo_corr'), erle = n('erle_db');
  if (corr !== null && erle !== null && corr > 0.5 && erle < 6) {
    add(erle < 2 ? 3 : 2, 'echo was not being removed',
        'the echo path was tracked confidently (' + corr.toFixed(2) +
        ') and only ' + erle.toFixed(1) + ' dB of it was cancelled',
        'echo cancellation -- a tracked path with no ERLE is a canceller that sees the echo and leaves it in');
  }
  if (n('peer_played') === 0 && n('cap_ps')) {
    add(3, 'the other person heard nothing',
        'we were capturing but their playout counter never moved',
        'one-way audio -- the send path, not the microphone');
  }

  // ── Picture ──────────────────────────────────────────────────────────────
  //
  // Their rung, not our image analysis. Three no-reference quality metrics were
  // tried on the decoded picture and two failed their own calibration (one ranked
  // backwards); the one thing that is unarguable is what the SENDER says about
  // its own encode, which the protocol already carries per direction.
  const theirQ = n('peer_q_level');
  if (theirQ === 0) {
    add(2, 'their picture ran at its lowest quality',
        'the far end reported the bottom rung of its quality ladder',
        f.cam_pixfmt === 'dmb1' || f.cam_pixfmt === 'jpeg'
          ? 'their camera hands over already-compressed frames -- start there'
          : 'their uplink, or the ladder floor itself: the bottom rung is a product decision');
  }
  const ourQ = n('v_quality');
  if (ourQ !== null && ourQ <= 0.5) {
    add(2, 'our picture ran at its lowest quality',
        'the encoder settled on ' + ourQ.toFixed(2) + ', the floor of the ladder',
        'our uplink or the ladder floor -- and note the bitrate cap is inert (see notes)');
  }
  // ── The picture stopped on purpose ───────────────────────────────────────
  //
  // Both directions, ranked differently, because they mean different things to
  // whoever reads this. Our own pause is a fact about this machine's uplink and
  // is actionable; theirs is a fact about somebody else's and is not. A single
  // merged number would be neither.
  const up = num(c.uptime_s) || 0;
  const ourP = n('v_paused_s'), ourN = n('v_pauses');
  if (ourP !== null && ourP > 0) {
    const pct = up > 0 ? Math.round((ourP / up) * 100) : 0;
    add(pct >= 25 ? 3 : 2, 'we stopped sending video',
        ourP + 's of ' + Math.round(up) + 's (' + pct + '%) over ' + ourN
          + ' pause(s) -- audio kept running',
        'OUR uplink could not carry the picture even at the floor. This is the'
          + ' one end of it we can actually fix: look at up Mbps and the loss the'
          + ' far end reported.');
  }
  const theirP = n('v_peer_paused_s'), theirN = n('v_peer_pauses');
  if (theirP !== null && theirP > 0) {
    const pct = up > 0 ? Math.round((theirP / up) * 100) : 0;
    add(pct >= 25 ? 2 : 1, 'they stopped sending video',
        theirP + 's of ' + Math.round(up) + 's (' + pct + '%) over ' + theirN
          + ' pause(s) -- we showed the blur and the warning',
        'THEIR uplink. Nothing at this end to fix, but it is the difference'
          + ' between "the app froze" and "their wifi went".');
  }
  if (n('v_paused_now') === 1 || n('v_peer_paused_now') === 1) {
    add(2, 'the call ended with the video still paused',
        (n('v_paused_now') === 1 ? 'ours' : 'theirs') + ' had not come back',
        'a pause that outlives the call is the case where giving the picture up'
          + ' was the wrong trade -- check whether the link ever recovered');
  }
  if (n('v_pause_armed') === 0) {
    add(0, 'video pausing was switched off for this call',
        '--no-vpause, the control arm',
        'the picture stayed on a link that may not have carried it');
  }

  const fmax = n('v_freeze_ms_max'), f400 = n('v_freezes_400'), f150 = n('v_freezes_150');
  if (f400 !== null && f400 > 0) {
    add(3, 'their face stopped moving',
        f400 + ' freeze(s) over 400 ms, longest ' + fmax + ' ms',
        'frame pacing and loss recovery -- a held frame is the thing people call "you froze"');
  } else if (f150 !== null && c.uptime_s > 10 && f150 / (c.uptime_s / 60) > 30) {
    add(2, 'the picture juddered',
        Math.round(f150 / (c.uptime_s / 60)) + ' visible hitches a minute, longest ' + fmax + ' ms',
        'frame pacing -- this is the fatigue, and every rate stays healthy through it');
  }

  // ── The feel of it ───────────────────────────────────────────────────────
  const p50 = n('m2e_p50'), p95 = n('m2e_p95');
  if (p50 !== null && p50 > 150) {
    add(p50 > 250 ? 3 : 2, 'the delay was noticeable',
        'mouth to ear ' + p50.toFixed(1) + ' ms',
        'over the 150 ms target -- check route and jitter buffer before blaming distance');
  }
  if (p50 !== null && p95 !== null && p95 - p50 > 30) {
    add(2, 'the delay kept moving',
        'p50 ' + p50.toFixed(1) + ' ms but p95 ' + p95.toFixed(1) + ' ms',
        'a delay that wanders is harder to talk over than a bigger steady one -- jitter buffer');
  }
  if (num(c.route) === 2) {
    add(2, 'the call went through a relay',
        'not peer to peer',
        'NAT traversal -- a relay adds a detour to every packet and caps the bandwidth');
  }
  return v.sort((a, b) => b.sev - a.sev);
}

function callCard(c, live) {
  const a = analyse(c);
  const el = document.createElement('div');
  el.className = 'call' + (live ? ' live' : '');
  const mins = c.durationS !== undefined ? Math.round(c.durationS / 60) : Math.round((c.uptime_s ?? 0) / 60);
  el.innerHTML =
    '<div class="top">' +
      '<span class="badge ' + (live ? 'live' : 'done') + '">' + (live ? 'LIVE' : 'ended') + '</span>' +
      '<span class="id">' + (c.call || '') + '</span>' +
      '<span class="id">' + (c.version ? 'v' + c.version : '') + (c.model ? ' · ' + c.model : '') + '</span>' +
      '<span class="id">' + (mins >= 1 ? mins + ' min' : Math.round(c.uptime_s ?? c.durationS ?? 0) + ' s') + '</span>' +
      '<span class="verdict" style="color:var(--' + a.vcls + ')">' + a.verdict + '</span>' +
    '</div>' +
    '<div class="metrics">' + a.cards.map((m) =>
      '<div class="m ' + m.cls + '"><div class="k">' + m.k + '</div>' +
      '<div class="v">' + m.v + '</div><div class="n">' + (m.note || '') + '</div></div>').join('') +
    '</div>' +
    (a.todo.length
      ? '<div class="todo">' + a.todo.map((t) =>
          '<div class="t s' + t.sev + '"><span class="tw">' + t.what + '</span>' +
          '<span class="ty">' + t.why + '</span>' +
          '<span class="tf">→ ' + t.fix + '</span></div>').join('') + '</div>'
      : '') +
    (a.ledger.length
      ? '<div class="ledger">' + a.ledger.map((r) =>
          '<div class="lrow"><span class="lk">' + r[0] + '</span>' +
          '<span class="lv">' + r[1] + '</span></div>').join('') + '</div>'
      : '') +
    (a.reasons.length
      ? '<div class="fix"><b>Needs fixing:</b> ' + a.reasons.join(' · ') + '</div>'
      : '<div class="fix"><i>Nothing broken to report.</i></div>');
  return el;
}

// ── WHEN THE APP FELL OVER ───────────────────────────────────────────────────
//
// Every crash on somebody else's Mac used to be invisible. macOS wrote an .ips
// file into a folder they will never open, the app came back, and nothing on
// this page changed -- a call that ends in a crash and a call that ends in a
// hang-up looked identical here, because both of them are just "the beats
// stopped".
//
// It matters more now than it did: the always-on watcher updates itself with
// nobody watching, so a build that crashes reaches every Mac on its own. This
// panel is the only thing that would say so, which is why it sits at the top of
// the page and why it says nothing at all when there is nothing to say. An empty
// crash panel is the normal state and should be easy to skip; a full one should
// be impossible to.
//
// Three kinds, and the difference between them IS the finding:
const CRASH_WORDS = {
  crash: 'crashed',
  vanished: 'disappeared with no crash report',
  restart: 'was still running when the Mac restarted',
};
// A signal is a cause of death, and nobody reading a dashboard at speed should
// have to remember which. Said the way somebody would describe what happened.
const SIGNAL_WORDS = {
  SIGSEGV: 'it read memory that was not there',
  SIGBUS: 'it read memory the wrong way',
  SIGABRT: 'it gave up on purpose -- an assertion, or the system refusing it something',
  SIGTRAP: 'it hit a check in our own code that should never fail',
  SIGILL: 'it ran an instruction that is not one',
  SIGKILL: 'something killed it outright',
  SIGFPE: 'a divide by zero or similar',
};
// "340 ms in" and "40 minutes in" are the difference between a release that
// cannot start and a call that went wrong, which is the first thing anybody
// needs to know. Silent when there is no number rather than saying "0 ms",
// because a report with no lifetime in it should not be dressed up as one that
// died instantly.
function howLong(ms) {
  if (typeof ms !== 'number' || !isFinite(ms) || ms <= 0) return '';
  if (ms < 1000) return Math.round(ms) + ' ms in';
  if (ms < 90_000) return Math.round(ms / 1000) + ' s in';
  if (ms < 5_400_000) return Math.round(ms / 60_000) + ' min in';
  return (ms / 3_600_000).toFixed(1) + ' hours in';
}
function crashCard(c) {
  const el = document.createElement('div');
  el.className = 'call crash';
  // The headline is a sentence, not a metric name. "0.61.0 crashed after 340 ms
  // -- it read memory that was not there, in reportLoop()" is the whole report
  // for most crashes, and everything below it is for the one that is not.
  const what = CRASH_WORDS[c.kind] || c.kind || 'stopped';
  const bits = [];
  if (c.sig && SIGNAL_WORDS[c.sig]) bits.push(SIGNAL_WORDS[c.sig]);
  else if (c.why) bits.push(c.why);
  if (c.where) bits.push('in <code>' + esc(String(c.where).slice(0, 70)) + '</code>');
  const rows = [];
  const row = (k, v) => { if (v) rows.push([k, v]); };
  row('what it was doing', c.crashedCall
    ? 'call <code>' + esc(c.crashedCall) + '</code> -- its beats stop where this begins'
    : (c.kind === 'crash' ? 'no call was running, so this happened during launch' : ''));
  row('the fault', [c.exc, c.sig].filter(Boolean).map(esc).join(' / '));
  row('what the system said', c.term_details ? esc(c.term_details) : esc(c.term || ''));
  row('and libsystem', esc(c.asi || ''));
  row('killed by', esc(c.killed_by || ''));
  row('running as', [esc(c.proc || ''), esc(c.path || '')].filter(Boolean).join(' at '));
  row('on', [esc(c.model || ''), esc(c.os || '')].filter(Boolean).join(' · '));
  row('reported by', c.reporterVersion
    ? 'a later launch running ' + esc(c.reporterVersion) : '');
  row('fields dropped to fit', (c.dropped || []).map(esc).join(', '));
  el.innerHTML =
    '<div class="top">' +
      '<span class="badge bad">' + (c.kind === 'crash' ? 'CRASH' : 'DIED') + '</span>' +
      '<span class="id">' + esc(c.appVersion ? 'v' + c.appVersion : 'unknown version') + '</span>' +
      '<span class="id">' + esc(c.install || '') + '</span>' +
      '<span class="id">' + (c.at ? new Date(c.at * 1000).toLocaleString() : '') + '</span>' +
    '</div>' +
    '<div class="headline">' +
      esc(c.appVersion ? 'Kin ' + c.appVersion : 'Kin') + ' ' + what + ' ' +
      howLong(c.ranMs) + (bits.length ? ' &mdash; ' + bits.join(', ') : '') +
    '</div>' +
    (rows.length
      ? '<div class="ledger">' + rows.map((r) =>
          '<div class="lrow"><span class="lk">' + r[0] + '</span>' +
          '<span class="lv">' + r[1] + '</span></div>').join('') + '</div>'
      : '') +
    ((c.frames || []).length
      ? '<div class="stack">' + c.frames.map((f) => esc(f)).join('\n') +
        (c.frames_total > c.frames.length
          ? '\n… ' + (c.frames_total - c.frames.length) + ' more frames not sent' : '') +
        '</div>'
      : '');
  return el;
}
// Everything below comes off a machine we do not control and is put into HTML,
// so it is escaped. A symbol name legitimately contains < and >.
function esc(s) {
  return String(s === null || s === undefined ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

async function loadCrashes() {
  const box = document.getElementById('crashes');
  try {
    const r = await fetch('/api/mac/crashes?n=25&cb=' + Date.now()).then((x) => x.json());
    const list = r.crashes || [];
    if (!list.length) {
      // Said plainly, and kept small. "No crashes" is the normal state of this
      // page and it should not look like a finding.
      box.innerHTML = '<div class="empty">No Mac has reported a crash. '
        + 'Every copy checks its own crash folder at launch, so this is a real'
        + ' answer rather than a missing one.</div>';
      return;
    }
    // THE HEADLINE FIRST, because a count with no denominator is decoration:
    // five crashes over five weeks and five this afternoon are the same number
    // and completely different news.
    // A crash and a run that vanished are not the same news, so they are not
    // added together: one has a stack and a cause, the other has neither, and a
    // headline that called eleven force-quits "crashes" would teach whoever
    // reads this page to stop believing the number.
    const t = r.today || {};
    let head = '';
    if (t.total) {
      const said = [];
      if (t.crashes) said.push(t.crashes + ' crash' + (t.crashes === 1 ? '' : 'es'));
      if (t.deaths) said.push(t.deaths + ' unexplained death' + (t.deaths === 1 ? '' : 's'));
      head = '<div class="alarm">' + said.join(' and ') + ' in the last 24 hours, on '
        + t.macs + ' Mac' + (t.macs === 1 ? '' : 's') + '.</div>';
    }
    // Which VERSION. This is the question the whole panel exists for now that a
    // release installs itself on machines nobody is watching: if one version's
    // row is long and the others are empty, that release is the bug.
    const bv = (r.byVersion || []).filter((v) => v.n > 0);
    if (bv.length) {
      head += '<div class="byver">last 7 days: ' + bv.map((v) =>
        '<b>' + esc(v.version || 'unknown') + '</b> ' + v.n + '× '
        + (CRASH_WORDS[v.kind] || v.kind) + ' on ' + v.macs + ' Mac'
        + (v.macs === 1 ? '' : 's')).join(' &middot; ') + '</div>';
    }
    box.innerHTML = head;
    list.forEach((c) => box.appendChild(crashCard(c)));
  } catch (e) {
    box.innerHTML = '<div class="empty">Could not load crashes.</div>';
  }
}

async function tick() {
  try {
    const r = await fetch('/api/mac/live?cb=' + Date.now()).then((x) => x.json());
    const box = document.getElementById('live');
    box.innerHTML = '';
    if (!r.calls || !r.calls.length) box.innerHTML = '<div class="empty">No call in progress.</div>';
    else r.calls.forEach((c) => box.appendChild(callCard(c, true)));
  } catch (e) { /* leave the last good view up rather than blanking it */ }
}

async function loadRecent() {
  try {
    const r = await fetch('/api/mac/recent?n=60&cb=' + Date.now()).then((x) => x.json());
    const box = document.getElementById('recent');
    if (!r.calls || !r.calls.length) { box.innerHTML = '<div class="empty">No calls recorded yet.</div>'; return; }
    const cell = (v, cls, digits) => '<td class="' + (cls || '') + '">' +
      (v === null || v === undefined ? '&mdash;' : (typeof v === 'number' ? v.toFixed(digits ?? 1) : v)) + '</td>';
    box.innerHTML = '<table><thead><tr><th>when</th><th>for</th><th>voice</th>' +
      '<th>over distance</th><th>round trip</th><th>gaps</th><th>lost</th>' +
      '<th>Mbps</th><th>version</th><th>verdict</th></tr></thead><tbody>' +
      r.calls.map((c) => {
        const a = analyse(c);
        const cls = { good: 'g', warn: 'w', bad: 'b' }[a.vcls];
        return '<tr>' +
          '<td>' + new Date(c.endedAt * 1000).toLocaleString() + '</td>' +
          '<td>' + (c.durationS >= 60 ? Math.round(c.durationS / 60) + 'm' : c.durationS + 's') + '</td>' +
          cell(num(c.m2e_p50), '', 1) +
          cell(a.over, '', 1) +
          cell(num(c.rtt_ms), '', 1) +
          cell(num(c.conceal_total) || 0, num(c.conceal_total) ? 'w' : 'g', 0) +
          cell(num(c.conceal_lost) || 0, num(c.conceal_lost) ? 'w' : 'g', 0) +
          cell(num(c.up_mbps), '', 2) +
          '<td>' + (c.version || '') + '</td>' +
          '<td class="' + cls + '">' + a.verdict + '</td>' +
        '</tr>';
      }).join('') + '</tbody></table>';
  } catch (e) {
    document.getElementById('recent').innerHTML = '<div class="empty">Could not load recent calls.</div>';
  }
}

tick(); loadRecent(); loadCrashes();
setInterval(tick, 3000);
setInterval(loadRecent, 20000);
// Slower than the calls: a crash arrives from the launch AFTER the one that
// died, so it is never news by the second.
setInterval(loadCrashes, 30000);
