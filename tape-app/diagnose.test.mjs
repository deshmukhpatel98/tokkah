/**
 * Tests for the self-diagnosing telemetry verdict layer (`diagnoseEnd`,
 * `diagnoseAgreement` in src/worker.ts).
 *
 * The thing this layer is for is naming a fault on a live call without the user
 * describing it. That makes its most dangerous possible bug not a wrong verdict
 * but a *confident* one: reporting `healthy` for a direction whose rule could not
 * run. A verdict layer that says "fine" when it means "I couldn't see" is worse
 * than no verdict layer, because it ends the investigation.
 *
 * So the assertions below are weighted towards blindness, not towards faults:
 *
 *   - every direction with a skipped rule must read `unknown`, never `healthy` (e, f, h)
 *   - today's real production beat shape must grade `unknown` (h) — the client does
 *     not ship these fields yet, and this test is what stops the layer from
 *     quietly inventing health in the gap between the two halves shipping
 *   - a latency rule must subtract propagation, so an antipodal call with a
 *     genuinely good overhead is NOT flagged (g1) — an absolute-ms threshold
 *     containing propagation is a hidden distance limit, and this codebase has
 *     shipped that bug four times
 *   - and (g3) is the control that proves `high_latency` can still fire at all.
 *     g1 and g3 are the same rule given two inputs it MUST rank differently;
 *     without g3, "not flagged" is indistinguishable from a rule that is dead.
 *
 * The module is bundled from src/worker.ts on every run, deliberately. An earlier
 * version of this harness imported a pre-built worker.mjs sitting beside it, which
 * would have gone on passing against a frozen copy of the code forever.
 *
 * Run: node diagnose.test.mjs
 */
import { build } from 'esbuild';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { unlinkSync } from 'node:fs';

const here = dirname(fileURLToPath(import.meta.url));
const bundle = join(tmpdir(), `worker-diagnose-${process.pid}.mjs`);
await build({
  entryPoints: [join(here, 'src/worker.ts')],
  bundle: true, format: 'esm', platform: 'neutral', outfile: bundle,
  logLevel: 'silent',
});
const { diagnoseEnd, diagnoseAgreement, packFields } = await import(bundle);
process.on('exit', () => { try { unlinkSync(bundle); } catch {} });

let failures = 0;
const ok = (cond, what) => {
  if (!cond) { failures++; console.log('  FAIL  ' + what); }
};
const eq = (got, want, what) => ok(got === want, `${what}: expected ${JSON.stringify(want)}, got ${JSON.stringify(got)}`);
const hasFault = (dir, name) => dir.faults.some((f) => f.name === name);

const T0 = 1_700_000_000;   // wall seconds
const NOW = T0 + 17;        // 2 s after the last of three 5 s beats

// A beat with every instrument the design asks for, all healthy.
const full = (i, over = {}) => ({
  wall: T0 + i * 5,
  rtt_ms: 24, probes: 60, m2e_p50: 26, m2e_p99: 29, g2g_p50: 40,
  conceal_ps: 0, recv: 1500 * i * 5, late: 0, snaps: 0, jit: 4,
  cap_ps: 1500, peer_reports: 4 * i, peer_played: 1500 * i * 5,
  peer_rx_lost: 0, peer_rx_recovered: 0,
  sig_rms: 0.03, cap_callbacks: 200 * i * 5, mic_muted: 0, mic_access: 1,
  v_encodes: 30 * i * 5, v_frags: 90 * i * 5, v_shown: 30 * i * 5, v_dec_ps: 30,
  v_glass_cov: 0.9, v_glass_ms_p50: 3.2, v_bytes_frame: 9000, v_rx_w: 1280,
  dec_luma: 120, peer_q_level: 3,
  route: 1, turn_ok: 1, crypt: 1, crypt_bad: 0, fmt_mismatch: 0,
  relocks: 0, peer_restarts: 0, render_errs: 0, audit_delta: 0, v_enq_fail: 0,
  in_rate: 48000, out_rate: 48000,
  echo_corr: 0.05, erle_db: 18, mute: 0, aec_freezes: 0, aec_on: 1,
  peer_status: 0,
  ...over,
});
const drop = (b, ...keys) => { const c = { ...b }; for (const k of keys) delete c[k]; return c; };

// Today's PRODUCTION beat: everything the mac client actually sends, and none of
// the fields the verdict layer wants. This case must never grade `healthy`.
const today = (i, over = {}) => ({
  wall: T0 + i * 5,
  rtt_ms: 24, m2e_p50: 26, m2e_p99: 29, g2g_p50: 40,
  conceal_ps: 0, conceal_total: 0, conceal_lost: 0, late: 0, jit: 4, snaps: 0,
  up_mbps: 0.9, down_mbps: 0.9, lp_in: 100, lp_out: 60,
  v_dec_ps: 30, v_enc_ps: 30, v_mbps: 2.1, v_bytes_frame: 9000,
  v_frames_lost: 0, v_glass_cov: 0.9, v_glass_ms_p50: 3.2,
  stalls: 0, rate_events: 0, render_errs: 0, fmt_mismatch: 0,
  peer_restarts: 0, relocks: 0, lp_bad: 0, v_dec_fails: 0, v_partial_drops: 0,
  v_no_fmt: 0, v_enq_fail: 0, crypt_bad: 0, crypt: 1, audit_delta: 0,
  uptime_s: i * 5,
  ...over,
});

const show = (label, end) => {
  const L = end.latency;
  console.log('\n──── ' + label);
  console.log('  verdict   : ' + end.verdict + '  [' + end.severity + ']' + (end.reason ? '  reason=' + end.reason : ''));
  console.log('  latency   : graded=' + L.graded + (L.why ? ' why=' + L.why : '')
    + ' rtt=' + L.rtt_ms + ' prop=' + L.prop_ms + ' m2e=' + L.m2e_p50 + ' overhead=' + L.overhead_ms
    + ' probes=' + L.probes);
  for (const [k, v] of Object.entries(end.directions)) {
    console.log('  ' + k.padEnd(10) + ': ' + v.verdict + (v.reason ? ' (' + v.reason + ')' : ''));
    for (const f of v.faults) console.log('      FAULT  ' + f.name + ' [' + f.severity + '/' + f.source + '] ' + f.evidence);
    for (const s of v.skipped) console.log('      skip   ' + s.rule + ': ' + s.why);
  }
  for (const s of end.skipped) console.log('      skip   ' + s.rule + ': ' + s.why);
  return end;
};
const run = (label, beats, opts = {}) =>
  show(label, diagnoseEnd({ call: 'c1', beats, now: NOW, endedCleanly: true, ...opts }));

const rep = (n, over) => [full(1, over), full(2, over), full(3, over)];

// ── (a) a single beat is not evidence ────────────────────────────────────────
{
  const e = run('(a) 1 beat -> insufficient_beats', [full(1)]);
  eq(e.verdict, 'unknown', '(a) verdict');
  eq(e.reason, 'insufficient_beats', '(a) reason');
}

// ── (b) fully instrumented and actually fine ─────────────────────────────────
{
  const e = run('(b) 3 healthy beats WITH rtt+probes+peer_reports -> healthy', [full(1), full(2), full(3)]);
  eq(e.verdict, 'healthy', '(b) verdict');
  eq(e.latency.graded, true, '(b) latency graded');
  eq(e.latency.prop_ms, 12, '(b) prop = rtt/2');
  for (const [k, d] of Object.entries(e.directions)) eq(d.verdict, 'healthy', `(b) ${k}`);
}

// ── (c) concealment as a FRACTION of expected packets, not an absolute count ──
{
  const e = run('(c) conceal_ps 15/s = 1% of 1500 -> audio_dropouts_in', rep(3, { conceal_ps: 15 }));
  ok(hasFault(e.directions.audio_in, 'audio_dropouts_in'), '(c) audio_in flags audio_dropouts_in');
  eq(e.severity, 'major', '(c) severity');
  eq(e.directions.audio_out.verdict, 'healthy', '(c) outbound unaffected');
}

// ── (d) one-way audio: sending hard, peer playing nothing ────────────────────
{
  const e = run('(d) cap_ps 1500, peer_played flat 0 -> one_way_out', rep(3, { peer_played: 0 }));
  ok(hasFault(e.directions.audio_out, 'one_way_out'), '(d) audio_out flags one_way_out');
  eq(e.severity, 'critical', '(d) severity');
  eq(e.directions.audio_in.verdict, 'healthy', '(d) inbound unaffected');
}

// ── (e) no RTT: propagation unknown, so latency must not be graded at all ────
{
  const e = run('(e) no rtt_ms -> latency SKIPPED, prop null', [drop(full(1), 'rtt_ms'), drop(full(2), 'rtt_ms'), drop(full(3), 'rtt_ms')]);
  eq(e.latency.graded, false, '(e) latency not graded');
  eq(e.latency.prop_ms, null, '(e) prop null');
  eq(e.verdict, 'unknown', '(e) verdict unknown, not healthy');
  for (const [k, d] of Object.entries(e.directions)) ok(d.verdict !== 'healthy' || d.skipped.length === 0, `(e) ${k} may not be healthy with a skipped rule`);
}

// ── (f) the far end never reported: outbound is unknowable, never healthy ─────
{
  const e = run('(f) peer_reports absent -> audio_out unknown:no_peer_report', [drop(full(1), 'peer_reports'), drop(full(2), 'peer_reports'), drop(full(3), 'peer_reports')]);
  eq(e.directions.audio_out.verdict, 'unknown', '(f) audio_out unknown');
  eq(e.directions.audio_out.reason, 'no_peer_report', '(f) audio_out reason');
  eq(e.directions.audio_in.verdict, 'healthy', '(f) inbound still gradeable');
}

// ── (g) the rtt-blind law: the rule must subtract propagation ────────────────
// g1 and g3 are the same rule on two inputs it MUST rank differently. g1 alone
// would also pass against a rule that never fires; g3 is what excludes that.
{
  const e = run('(g1) rtt 300 ms, m2e 131 ms -> NOT high_latency',
    rep(3, { rtt_ms: 300, m2e_p50: 131, m2e_p99: 138, g2g_p50: 190 }));
  eq(e.verdict, 'healthy', '(g1) antipodal call with good overhead is healthy');
  ok(!hasFault(e.directions.audio_in, 'high_latency'), '(g1) no high_latency at rtt 300');
}
{
  const e = run('(g2) rtt 254 ms, m2e 131 ms -> overhead +4 ms, NOT high_latency',
    rep(3, { rtt_ms: 254, m2e_p50: 131, g2g_p50: 150 }));
  eq(e.latency.overhead_ms, 4, '(g2) overhead = m2e - rtt/2');
  ok(!hasFault(e.directions.audio_in, 'high_latency'), '(g2) +4 ms overhead is not a fault');
}
{
  const e = run('(g3) CONTROL: rtt 254 ms, m2e 200 ms -> overhead +73 ms IS high_latency',
    rep(3, { rtt_ms: 254, m2e_p50: 200 }));
  ok(hasFault(e.directions.audio_in, 'high_latency'), '(g3) the rule can still fire');
  eq(e.latency.overhead_ms, 73, '(g3) overhead');
}

// ── (h) today's production data must grade unknown, never healthy ────────────
{
  const e = run("(h) TODAY'S production beat shape (no new fields) -> unknown", [today(1), today(2), today(3)]);
  eq(e.verdict, 'unknown', '(h) verdict unknown');
  ok(e.severity === 'unknown', '(h) severity unknown');
  ok(e.reason?.includes('no_peer_report'), '(h) reason names the missing peer report');
  ok(e.skipped.length > 0, '(h) names the instruments it lacks');
  for (const [k, d] of Object.entries(e.directions)) eq(d.verdict === 'healthy', false, `(h) ${k} must not read healthy`);
}

// ── (i) the two ends must agree, and "cannot see" is not disagreement ────────
{
  const A = diagnoseEnd({ call: 'A', beats: rep(3, { peer_played: 0 }), now: NOW });
  const Bsilent = diagnoseEnd({ call: 'B', beats: rep(3, { recv: 0 }), now: NOW });
  const Bfine = diagnoseEnd({ call: 'B', beats: [full(1), full(2), full(3)], now: NOW });
  const Bblind = diagnoseEnd({ call: 'B', beats: [1, 2, 3].map((i) => drop(full(i), 'conceal_ps', 'recv', 'm2e_p50')), now: NOW });
  console.log('\n──────── (i) agreement between the two ends');
  const matched = diagnoseAgreement([A, Bsilent]);
  const contra = diagnoseAgreement([A, Bfine]);
  const blind = diagnoseAgreement([A, Bblind]);
  const single = diagnoseAgreement([A]);
  for (const [k, v] of Object.entries({ matched, contra, blind, single })) console.log('  ' + k.padEnd(8) + ' agree=' + v.agree + '  ' + JSON.stringify(v.notes));
  eq(A.verdict, 'one_way_out', '(i) A sees one_way_out');
  eq(Bsilent.verdict, 'one_way_in', '(i) B sees the mirror');
  eq(matched.agree, true, '(i) mirrored verdicts agree');
  eq(contra.agree, false, '(i) a far end that is fine is a contradiction');
  eq(blind.agree, null, '(i) a blind far end is not disagreement');
  eq(single.agree, null, '(i) one end alone cannot agree with itself');
}

// ── (j) an oversized beat must stay readable ────────────────────────────────
// The bug this replaced: slice() cuts valid JSON mid-token, safeParse turns
// invalid JSON into {}, so one big beat lost EVERY field and read as a blind
// end. The first assertion here is that the OLD approach really was broken --
// without it, "the new one parses" proves nothing about what it fixed.
{
  console.log('\n──── (j) packFields never emits invalid JSON');
  const small = { a: 1, b: 'two', c: [3, 4] };
  eq(packFields(small), JSON.stringify(small), '(j) small object passes through untouched');

  const big = { keep: 1 };
  for (let i = 0; i < 40; i++) big['blob' + i] = 'x'.repeat(300);   // ~12 KB
  const sliced = JSON.stringify(big).slice(0, 8000);
  let slicedParses = true;
  try { JSON.parse(sliced); } catch { slicedParses = false; }
  ok(!slicedParses, '(j) the OLD slice() approach produced unparseable JSON');

  const packed = packFields(big);
  let parsed = null;
  try { parsed = JSON.parse(packed); } catch { /* stays null */ }
  ok(parsed !== null, '(j) packFields output parses');
  ok(packed.length <= 8000, '(j) packFields respects the limit');
  ok((parsed?.fields_dropped ?? 0) > 0, '(j) packFields records how many it dropped');
  ok('keep' in (parsed ?? {}), '(j) the smallest field survives (largest dropped first)');

  const monster = { one: 'y'.repeat(20000) };
  let mParsed = null;
  try { mParsed = JSON.parse(packFields(monster)); } catch { /* stays null */ }
  ok(mParsed !== null, '(j) a single oversized field still yields valid JSON');
  eq(mParsed?.fields_dropped, 1, '(j) and says it dropped it');
}

// ── (k) pre_connect is a state, not a missing instrument ────────────────────
// These beats are what the client emits before its time-sync exists: seven
// fields, no rtt, no probes. Grading them as "no_probe_count" pointed at a
// client field that has shipped since 0.20.1 and cost a lane a wrong lead.
{
  const pre = (i) => ({ wall: T0 + i * 5, pre_connect: 1, uptime_s: i * 5 });
  const e = run('(k) only pre_connect beats -> pre_connect_only, NOT no_probe_count',
    [pre(1), pre(2), pre(3)]);
  eq(e.verdict, 'unknown', '(k) verdict unknown');
  eq(e.reason, 'pre_connect_only', '(k) reason names the call state, not a field');
  eq(e.beatsInWindow, 0, '(k) no connected beats in the window');

  // Mixed: setup beats must not poison a call that then connected.
  const mixed = run('(k2) pre_connect beats + healthy beats -> graded on the healthy ones',
    [pre(0), pre(1), full(1), full(2), full(3)]);
  eq(mixed.verdict, 'healthy', '(k2) setup beats do not drag a good call to unknown');
  eq(mixed.latency.graded, true, '(k2) latency still graded');
  eq(mixed.beatsInWindow, 3, '(k2) window holds only connected beats');

  // And the real no_probe_count rule must still fire when probes are genuinely absent.
  const noProbe = run('(k3) CONTROL: connected beats with no probes -> no_probe_count still fires',
    [drop(full(1), 'probes'), drop(full(2), 'probes'), drop(full(3), 'probes')]);
  eq(noProbe.latency.why, 'no_probe_count', '(k3) the rule is not disabled, only unconfused');
}

console.log(failures === 0
  ? '\nAll diagnose cases passed.'
  : `\n${failures} assertion(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
