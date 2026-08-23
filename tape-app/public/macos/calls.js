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
  fault(c.crypt_bad, 'packets failed to decrypt');
  if (num(c.audit_delta)) faults.push('SAMPLE AUDIT OFF BY ' + num(c.audit_delta));
  if (num(c.crypt) === 0) faults.push('NOT ENCRYPTED');

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
  return { cards, faults, reasons, verdict, vcls, over, m2e };
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
    (a.reasons.length
      ? '<div class="fix"><b>Needs fixing:</b> ' + a.reasons.join(' · ') + '</div>'
      : '<div class="fix"><i>Nothing broken to report.</i></div>');
  return el;
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

tick(); loadRecent();
setInterval(tick, 3000);
setInterval(loadRecent, 20000);
