// Skew-aware striping (stall & fall-forward hardening) Stage 3 verification rig (Rig B).
//
// What it proves: when fast lanes die mid-call (spec §5 assert 10), the fall-forward path
// in pcm.js (pickDataAssoc walking all associations) keeps audio flowing on whatever lanes remain.
//
// Why RTCDataChannels are not closed directly via DOM/API:
// RTCDataChannel handles inside pcm.js are stored in private module closures and are not exposed on
// window.__tape (window.__tape.pcm returns plain telemetry snapshot objects without dc handles).
// Emulating channel death by route blackhole (+5000 ms proxy flap via sim.flap on three fast proxies)
// is transport-equivalent to channel death by close(), making data channels effectively unreachable.
//
// Divergence profile used: base delay 40 ms, heavy-tailed jitter 6 ms, zero loss, and per-lane
// offsets [0, 24, 0, 12, 0, 24, 0, 0] ms across proxy creation order.
//
// Network is emulated locally via delayProxy candidate rewriting; application logic is NOT emulated —
// verdicts come directly from DEPLOYED production code running on room.tokkah.com.
//
// Arms: ON (?pcmskewstripe=1) vs OFF (bare control).

import { chromium } from 'playwright-core';
import { startP2PSim } from './netsim.mjs';

const CHROME = process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const A = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
const mk = (v, w) => ([
  '--use-fake-ui-for-media-stream',
  '--use-fake-device-for-media-stream',
  `--use-file-for-fake-video-capture=${A(v)}`,
  `--use-file-for-fake-audio-capture=${A(w)}`,
  '--autoplay-policy=no-user-gesture-required',
]);

// Copied verbatim from testbed/skewstripe-stage2.mjs to patch RTCPeerConnection candidate routing
const P2P_REWRITE = `
  const OrigPC = window.RTCPeerConnection;
  window.__rewrites = [];
  const rewrite = async (line) => {
    const f = String(line).split(' ');
    if (f.length < 7 || !/^udp$/i.test(f[2])) return null;
    const ip = f[4], port = Number(f[5]);
    if (!ip || !Number.isFinite(port) || port <= 0) return null;
    const np = await window.__simProxy(ip, port);
    if (!np) return null;
    f[5] = String(np);
    window.__rewrites.push({ from: ip + ':' + port, to: ip + ':' + np, typ: f[7] || '?' });
    return f.join(' ');
  };
  class SimPC extends OrigPC {
    async addIceCandidate(cand) {
      try {
        const line = typeof cand === 'string' ? cand : cand && cand.candidate;
        if (line) {
          const out = await rewrite(line);
          if (out) {
            const init = typeof cand === 'string'
              ? out
              : { candidate: out, sdpMid: cand.sdpMid, sdpMLineIndex: cand.sdpMLineIndex,
                  usernameFragment: cand.usernameFragment };
            return super.addIceCandidate(init);
          }
        }
      } catch (e) { window.__rewrites.push({ error: String(e).slice(0, 120) }); }
      return super.addIceCandidate(cand);
    }
    async setRemoteDescription(desc) {
      try {
        const sdp = desc && desc.sdp;
        if (sdp && /^a=candidate:/m.test(sdp)) {
          const lines = sdp.split(/\\r?\\n/);
          for (let i = 0; i < lines.length; i++) {
            if (!lines[i].startsWith('a=candidate:')) continue;
            const out = await rewrite(lines[i].slice(2));
            if (out) lines[i] = 'a=' + out;
          }
          return super.setRemoteDescription({ type: desc.type, sdp: lines.join('\\r\\n') });
        }
      } catch (e) { window.__rewrites.push({ error: 'sdp ' + String(e).slice(0, 100) }); }
      return super.setRemoteDescription(desc);
    }
  }
  window.RTCPeerConnection = SimPC;
`;

async function getSample(p) {
  return p.evaluate(() => {
    const pc = window.__tape?.pcm;
    const snap = (typeof pc?.snapshot === 'function' ? pc.snapshot() : pc) ?? {};
    return {
      mouthToEarMs: snap.mouthToEarMs ?? null,
      ringDepthMs: snap.m2eParts?.ringDepthMs ?? null,
      framesRecv: window.__tape?.pcm?.framesRecv ?? snap.framesRecv ?? null,
      concealedMs: window.__tape?.pcm?.concealedMs ?? snap.concealedMs ?? null,
      laneSkew: snap.laneSkew ?? null,
      peerSkew: snap.peerSkew ?? null,
      // The third lane-health signal (2026-08-14). `weRecv[k]` is the percent of
      // frames arriving on lane k that missed the playhead; `weSend[k]` is what
      // the peer reports about the lane we send on. This scenario exists because
      // skew and liveness are both blind to a uniformly-delayed route, so the
      // rig has to be able to see the signal that is not.
      latePct: snap.latePct ?? null,
      // Repair accounting, to settle WHY the control arm survives this scenario.
      // Hypothesis under test: with striping off, the six lanes carry equal
      // shares, so three bad routes lose an even 50% that RS(10,13) plus the
      // burst shield can largely rebuild. Demotion concentrates the survivors
      // onto three lanes and changes the loss from evenly-spread to bursty,
      // which is the shape erasure coding is worst at. If that is right,
      // `fecRepaired` is far higher in the OFF arm and the fix is not "demote
      // harder" but "stop demoting once the loss is repairable".
      fecRepaired: snap.fecRepaired ?? null,
      fecRepairedLate: snap.fecRepairedLate ?? null,
      fecFailed: snap.fecFailed ?? null,
      dupRecv: snap.dupRecv ?? null,
      stripe: snap.stripe ?? null,
      jitSpreadMaxRun: snap.jitSpreadMaxRun ?? null,
      jitSpreadMaxLate: snap.jitSpreadMaxLate ?? null,
      perAssoc: snap.perAssoc ? snap.perAssoc.map(a => ({
        i: a.i,
        framesSent: a.framesSent ?? 0,
        bytesSent: a.bytesSent ?? 0,
        framesRecv: a.framesRecv ?? 0,
      })) : [],
      bytesSent: window.__tape?.pcm?.bytesSent ?? snap.bytesSent ?? 0,
      rewrites: window.__rewrites?.length ?? 0,
    };
  });
}

async function armStall(qs) {
  const sim = await startP2PSim({
    oneWayMs: 40,
    jitterMs: 6,
    jitterModel: 'heavy',
    lossPct: 0,
    laneOffsetsMs: process.argv.includes('--offsets=0') ? [] : [0, 24, 0, 12, 0, 24, 0, 0],
    seed: Number(process.argv.find((a) => a.startsWith('--seed='))?.slice(7) ?? 1),
  });
  const bA = await chromium.launch({ executablePath: CHROME, headless: true, args: mk('realA.mjpeg', 'realA.wav') });
  const bB = await chromium.launch({ executablePath: CHROME, headless: true, args: mk('realB.mjpeg', 'realB.wav') });
  try {
    const R = `skewstripe-stall${qs ? 'on' : 'off'}-${Date.now().toString(36)}`;
    const pA = await bA.newPage(), pB = await bB.newPage();
    for (const p of [pA, pB]) {
      await p.exposeFunction('__simProxy', async (h, port) => sim.portFor(h, port));
      await p.addInitScript(P2P_REWRITE);
    }
    await pA.goto(`https://room.tokkah.com/?r=${R}${qs}`); await pA.click('#join');
    await pB.goto(`https://room.tokkah.com/?r=${R}${qs}`); await pB.click('#join');
    for (const p of [pA, pB]) await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });

    // Step 1: Connect and run 30 s, sample
    await pA.waitForTimeout(30000);
    const t30A = await getSample(pA);
    const t30B = await getSample(pB);

    // Step 2: Blackhole three fast proxies via sim.flap(idx, +5000)
    const delays = sim.laneDelays();
    const fastProxyIndices = [];
    for (let i = 0; i < delays.length; i++) {
      if (Math.abs(delays[i] - 40) < 0.1) {
        fastProxyIndices.push(i);
        if (fastProxyIndices.length === 3) break;
      }
    }
    // Fallback if fewer than 3 base delay proxies exist
    while (fastProxyIndices.length < 3 && fastProxyIndices.length < delays.length) {
      for (let i = 0; i < delays.length; i++) {
        if (!fastProxyIndices.includes(i)) {
          fastProxyIndices.push(i);
          if (fastProxyIndices.length === 3) break;
        }
      }
    }

    console.log(`[stall] Blackholing 3 proxies [${fastProxyIndices.join(', ')}] with +5000 ms delay at t=30s (${qs || 'control'})`);
    for (const idx of fastProxyIndices) {
      sim.flap(idx, 5000);
    }

    // Step 3: Run 25 s more (to t=55s total), TRACING once a second.
    //
    // Two samples 25 s apart say the ON arm concealed 2.3x the control and say
    // nothing whatever about why, and one hypothesis has already been built and
    // disproved on that basis (ranking the MIN_FAST rescue by why-a-lane-was-
    // demoted rather than by its now-meaningless current reading — correct in
    // itself, worth nothing here). The failure is a SEQUENCE: who demoted what,
    // when, how often it changed its mind, and where the concealment landed
    // relative to those decisions. A per-second trace is the cheapest thing that
    // can show a sequence, and guessing again without one is not a method.
    const trace = [];
    for (let t = 0; t < 25; t++) {
      await pA.waitForTimeout(1000);
      const [ta, tb] = await Promise.all([pA, pB].map((p) => p.evaluate(() => {
        // `__tape.pcm` is a GETTER that already returns the snapshot object, not
        // the module — so `.snapshot()` on it is undefined and every field comes
        // back null. getSample() above handles both spellings; this did not, and
        // it silently traced 25 seconds of nulls through a full two-arm run.
        const pc = window.__tape?.pcm;
        const s = (typeof pc?.snapshot === 'function' ? pc.snapshot() : pc) ?? {};
        return {
          conceal: s.concealedMs ?? null, depth: s.m2eParts?.ringDepthMs ?? null,
          nFast: s.stripe?.nFast ?? null, order: s.stripe?.fastOrder ?? null,
          dem: s.stripe?.demotions ?? null, pro: s.stripe?.promotions ?? null,
          probe: s.stripe?.probePromotions ?? null, dead: s.stripe?.dead ?? null,
          stale: s.stripe?.staleFailopen ?? null,
          lateRecv: s.latePct?.weRecv ?? null, lateSend: s.latePct?.weSend ?? null,
        };
      }).catch(() => null)));
      trace.push({ t: t + 1, a: ta, b: tb });
      // Refuse to keep going if the very first sample is empty. A trace of
      // nulls costs a full two-arm run (nearly four minutes) to discover, and
      // it looks exactly like a trace of a call that is not doing anything.
      if (t === 0) {
        // The real check is "does the snapshot answer at all", and it was
        // written as "does it carry stripe state" — which made it fire on any
        // arm without `&pcmskewstripe=1`, including the SHIPPING DEFAULT, where
        // stripe is legitimately null. It crashed a full 3-round run of an
        // unrelated A/B. Split into the two questions it was conflating.
        if (ta?.conceal == null && tb?.conceal == null) {
          throw new Error('trace read no snapshot on either side — the snapshot spelling is wrong');
        }
        if (qs.includes('pcmskewstripe=1') && ta?.nFast == null && tb?.nFast == null) {
          throw new Error('striping was requested but no lane state came back — the stripe spelling is wrong');
        }
      }
    }
    const fmt = (x) => x ? `n${x.nFast}[${(x.order ?? []).join('')}] d${x.dem}/p${x.pro}/pp${x.probe}`
      + `${x.dead ? ` DEAD${x.dead}` : ''}${x.stale ? ` STALE${x.stale}` : ''} cc${x.conceal} dep${Math.round(x.depth ?? 0)}` : '—';
    console.log(`[trace ${qs || 'control'}] second-by-second from the moment of the stall`);
    for (const r of trace) console.log(`  t+${String(r.t).padStart(2)}s  A ${fmt(r.a)}   |   B ${fmt(r.b)}`);
    const t55A = await getSample(pA);
    const t55B = await getSample(pB);

    const latenessMax = sim.lateness()?.max ?? 0;
    const loopLagMax = sim.loopLag()?.max ?? 0;

    return {
      t30: { pA: t30A, pB: t30B },
      t55: { pA: t55A, pB: t55B },
      stalledIndices: fastProxyIndices,
      latenessMax,
      loopLagMax,
    };
  } finally {
    await bA.close().catch(() => {});
    await bB.close().catch(() => {});
    sim.stop();
  }
}

async function armRetryStall(qs) {
  let s = await armStall(qs);
  if (s.t55.pA.framesRecv == null || s.t55.pB.framesRecv == null) {
    console.log(`[retry] arm '${qs || 'control'}' returned null pcm; retrying once`);
    s = await armStall(qs);
  }
  return s;
}

// The stage-2 gate does NOT transfer to this rig, and inheriting it made every
// run unmeasurable: there, a >300 ms arrival spread means a host stall poisoned
// the comparison; HERE it is the stimulus — blackholing three lanes for 5 s is
// supposed to produce seconds of spread. Measured: four straight INVALIDs at
// 837-2599 ms, all of them the injection working correctly.
//
// So spread is judged only BEFORE the injection (t=30, where a stall really is
// contamination), and everything after is judged on what the rig does not
// control: the emulator's own punctuality.
function checkValidity(on, off) {
  const reasons = [];
  const checkArm = (label, armData) => {
    const maxSpreadA = armData.t30.pA.jitSpreadMaxRun ?? 0;
    const maxSpreadB = armData.t30.pB.jitSpreadMaxRun ?? 0;

    if (maxSpreadA > 300) {
      reasons.push(`${label} side A pre-injection jitSpreadMaxRun ${maxSpreadA} ms > 300 ms`);
    }
    if (maxSpreadB > 300) {
      reasons.push(`${label} side B pre-injection jitSpreadMaxRun ${maxSpreadB} ms > 300 ms`);
    }
    if (armData.latenessMax > 50) {
      reasons.push(`${label} sim lateness max ${armData.latenessMax} ms > 50 ms`);
    }
    if (armData.loopLagMax > 50) {
      reasons.push(`${label} sim loopLag max ${armData.loopLagMax} ms > 50 ms`);
    }
  };

  checkArm('ON', on);
  checkArm('OFF', off);
  return reasons;
}

// ── REPEATS, PAIRED, WITH THE ARM ORDER ROTATED ──────────────────────────────
// One pair of calls cannot grade anything on this path, and for a while this
// rig pretended otherwise. A NULL A/B — both arms given byte-identical flags —
// returned a 452 ms gap in stall concealment and 1192 ms across the whole call,
// from no difference whatsoever. Measured effects of 200 ms were being read off
// a single pair and believed, in both directions: a change was credited with a
// 20% improvement and, on the next run, suspected of a pre-stall regression.
// Neither survived contact with the noise floor.
//
// So: N rounds, and the ARM ORDER ALTERNATES between them. Order matters
// because the two calls in a pair are not exchangeable — the first pays for a
// cold page, a cold encoder and a cold host, and whichever arm always goes
// first always eats that. Rotating cancels it instead of hoping it is small.
//
// The verdict is the MEDIAN of the per-round deltas, and a delta whose rounds
// straddle zero is reported as UNRESOLVED rather than as a number. That is the
// honest output when the effect is smaller than the instrument: not a PASS, not
// a FAIL, but "this rig cannot see it".
const REPEAT = Math.max(1, Number(process.argv.find((a) => a.startsWith('--repeat='))?.slice(9)) || 1);
const ON_FLAGS = process.argv.find((a) => a.startsWith('--on='))?.slice(5) ?? '&pcmskewstripe=1';
// Default '' is NO STRIPING AT ALL, which makes this a stripe-on/stripe-off
// test — useless for grading a change INSIDE the stripe, whose control needs a
// lane order to compare against. For that, give both arms striping:
//   --on='&pcmskewstripe=1' --off='&pcmskewstripe=1&pcmfastdead=0'
const OFF_FLAGS = process.argv.find((a) => a.startsWith('--off='))?.slice(6) ?? '';

const rounds = [];
const dropped = [];
for (let r = 0; r < REPEAT; r++) {
  let got = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    // Alternate which arm is measured first; see above.
    const onFirst = r % 2 === 0;
    const a = await armRetryStall(onFirst ? ON_FLAGS : OFF_FLAGS);
    const b = await armRetryStall(onFirst ? OFF_FLAGS : ON_FLAGS);
    const [rOn, rOff] = onFirst ? [a, b] : [b, a];
    const invalidReasons = checkValidity(rOn, rOff);
    if (invalidReasons.length === 0) { got = { on: rOn, off: rOff, onFirst }; break; }
    console.log(`INVALID (round ${r + 1}/${REPEAT}): ${invalidReasons.join('; ')}`);
    if (attempt < 2) console.log(`[retry] round ${r + 1}, attempt ${attempt + 2}/3`);
  }
  if (got) {
    rounds.push(got);
    console.log(`[round ${r + 1}/${REPEAT}] valid (${got.onFirst ? 'ON first' : 'OFF first'})`);
  } else {
    dropped.push(r + 1);
    console.log(`[round ${r + 1}/${REPEAT}] DROPPED after 3 attempts`);
  }
}

if (rounds.length === 0) {
  console.log('VERDICT: UNMEASURABLE (host too noisy)');
  process.exit(2);
}
// NEVER SILENTLY. A rig that bounds its own coverage has to say so, or the
// reader takes "3 rounds requested" as "3 rounds measured".
if (dropped.length) console.log(`NOTE: ${dropped.length} of ${REPEAT} rounds dropped as invalid (rounds ${dropped.join(', ')})`);

const median = (xs) => {
  const s = [...xs].sort((x, y) => x - y);
  return s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2;
};
const concealDelta = (arm) => (((arm.t55.pA.concealedMs ?? 0) - (arm.t30.pA.concealedMs ?? 0))
  + ((arm.t55.pB.concealedMs ?? 0) - (arm.t30.pB.concealedMs ?? 0))) / 2;
const wholeCall = (arm) => (arm.t55.pA.concealedMs ?? 0) + (arm.t55.pB.concealedMs ?? 0);
const m2eDuring = (arm) => ((arm.t55.pA.mouthToEarMs ?? NaN) + (arm.t55.pB.mouthToEarMs ?? NaN)) / 2;
const ringDuring = (arm) => ((arm.t55.pA.ringDepthMs ?? NaN) + (arm.t55.pB.ringDepthMs ?? NaN)) / 2;

// The last round's raw snapshots, so a reader can still inspect one call in full.
const last = rounds[rounds.length - 1];
console.log('skewstripe stall ON  t=30:', JSON.stringify(last.on.t30));
console.log('skewstripe stall ON  t=55:', JSON.stringify(last.on.t55));
console.log('skewstripe stall OFF t=30:', JSON.stringify(last.off.t30));
console.log('skewstripe stall OFF t=55:', JSON.stringify(last.off.t55));

console.log(`\n── ${rounds.length} valid round(s), ON=[${ON_FLAGS}] OFF=[${OFF_FLAGS}] ──`);
const report = [];
for (const [name, fn, unit] of [
  ['conceal during stall', concealDelta, 'ms'],
  ['conceal whole call  ', wholeCall, 'ms'],
  ['mouth-to-ear during ', m2eDuring, 'ms'],
  ['ring depth during   ', ringDuring, 'ms'],
]) {
  const perRound = rounds.map((r) => fn(r.on) - fn(r.off));
  const med = median(perRound);
  const straddles = Math.min(...perRound) < 0 && Math.max(...perRound) > 0;
  const onMed = median(rounds.map((r) => fn(r.on)));
  const offMed = median(rounds.map((r) => fn(r.off)));
  report.push({ name, med, straddles, perRound });
  console.log(`${name}: ON ${onMed.toFixed(0)} ${unit} vs OFF ${offMed.toFixed(0)} ${unit}`
    + `  ->  median delta ${med > 0 ? '+' : ''}${med.toFixed(0)} ${unit}`
    + `  [per-round ${perRound.map((d) => (d > 0 ? '+' : '') + d.toFixed(0)).join(', ')}]`
    + (rounds.length < 2 ? '  (1 round: NOT RESOLVABLE, see the null A/B note above)'
      : straddles ? '  (UNRESOLVED: rounds straddle zero)' : ''));
}

// Asserts (spec assert 10)
const livePass = rounds.every((r) => r.on.t55.pA.framesRecv != null && r.on.t55.pB.framesRecv != null
  && r.off.t55.pA.framesRecv != null && r.off.t55.pB.framesRecv != null);
console.log(`\nassert live snapshot reported in both arms: ${livePass ? 'PASS' : 'FAIL'}`);

const framesDelta = (arm, side) => (arm.t55[side].framesRecv ?? 0) - (arm.t30[side].framesRecv ?? 0);
const framesPass = rounds.every((r) => ['pA', 'pB'].every((s) => framesDelta(r.on, s) > 1000 && framesDelta(r.off, s) > 1000));
console.log(`assert framesRecv advanced by > 1000 in BOTH arms, every round: ${framesPass ? 'PASS' : 'FAIL'}`
  + ` (${rounds.map((r) => `ON ${framesDelta(r.on, 'pA')}/${framesDelta(r.on, 'pB')} OFF ${framesDelta(r.off, 'pA')}/${framesDelta(r.off, 'pB')}`).join(' | ')})`);

// Judged on the MEDIAN across rounds, not on one pair. The 500 ms allowance was
// set when a single pair was the whole sample; it is roughly the null A/B's own
// 452 ms gap, which is the right order for a tolerance and pure luck that it is.
const medConceal = median(rounds.map((r) => concealDelta(r.on) - concealDelta(r.off)));
const concealPass = medConceal <= 500;
console.log(`assert median ON-OFF conceal delta <= +500 ms: ${concealPass ? 'PASS' : 'FAIL'} (${medConceal > 0 ? '+' : ''}${medConceal.toFixed(1)} ms)`);

const floorPass = rounds.every((r) => (r.on.t55.pA.stripe?.nFast ?? 0) >= 3 && (r.on.t55.pB.stripe?.nFast ?? 0) >= 3);
console.log(`assert ON nFast >= 3 at end, every round: ${floorPass ? 'PASS' : 'FAIL'}`
  + ` (${rounds.map((r) => `${r.on.t55.pA.stripe?.nFast}/${r.on.t55.pB.stripe?.nFast}`).join(' | ')})`);

const pass = livePass && framesPass && concealPass && floorPass;
console.log(`\nVERDICT: ${pass ? 'PASS' : 'FAIL'}`);
process.exitCode = pass ? 0 : 1;
