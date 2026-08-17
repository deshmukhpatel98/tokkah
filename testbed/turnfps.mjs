#!/usr/bin/env node
/**
 * turnfps.mjs — does a higher frame rate make people answer each other faster?
 *
 * THE QUESTION, and why it is not the obvious one. "Does 60fps feel more like
 * being there" is usually argued about smoothness, and smoothness is a weak
 * presence claim: a talking face at conversational distance does not move fast
 * enough for 30→60 to matter much. But TURN-TAKING might.
 *
 * You know when to start speaking by reading the other person finishing — the
 * inhale, the mouth opening, the eyebrow, the gaze shift. Those cues last a
 * couple of hundred milliseconds. At 30fps you get six to nine samples of one;
 * at 72fps, fifteen to twenty. If frame rate matters to presence at all, this
 * is the mechanism, and it is measurable.
 *
 * THE INSTRUMENT ALREADY EXISTS and it is unusually honest. `humanMedian` is
 * my local speech onset minus their arrival end — BOTH events observed on one
 * machine, so the network delay sits inside "arrival end" rather than being
 * added to the difference. No RTT correction, therefore no RTT estimation
 * error. It is pure human response time, and our fleet reports ~578 ms against
 * Boland's ~297 ms face-to-face control. That gap is NOT latency. It is
 * hesitation, and hesitation is exactly what a missing turn-taking cue causes.
 *
 * `perceivedMedian` (the same transition with the round trip left in) rides
 * along as the consistency check: perceived ≈ human + RTT, measured
 * independently, so if they stop reconciling the instrument is wrong rather
 * than the conversation.
 *
 * WHAT THIS RIG CANNOT DO: run itself. It needs two people having an actual
 * unscripted conversation — no script, no prompts, nothing to perform. Turn
 * transitions accumulate at maybe one every few seconds, so a usable median
 * wants several minutes per arm. Talk about anything.
 *
 *   1. Both people open:  https://room.tokkah.com/?r=lab
 *   2. Here:              node testbed/turnfps.mjs --lo=30 --hi=72 --period=240
 *
 * The rate is swapped inside ONE conversation so that the two populations are
 * interleaved in time: whoever is tired, whichever network is congested, lands
 * on both arms instead of on whichever ran second.
 */
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';

const ROOM = process.env.LAB_ROOM ?? 'lab';
const BASE = process.env.URL ?? 'https://room.tokkah.com';
const arg = (k, d) => { const m = process.argv.find((a) => a.startsWith(`--${k}=`)); return m ? m.slice(k.length + 3) : d; };
const LO = Number(arg('lo', 30));
const HI = Number(arg('hi', 72));
const PERIOD = Number(arg('period', 240));  // seconds per arm
const CYCLES = Number(arg('cycles', 3));

const key = (() => {
  if (process.env.TOKKAH_LAB_KEY) return process.env.TOKKAH_LAB_KEY;
  try {
    const f = readFileSync(`${homedir()}/.config/tokkah/cf.env`, 'utf8');
    return f.match(/^export TOKKAH_LAB_KEY=(.+)$/m)?.[1]?.trim() ?? null;
  } catch { return null; }
})();
if (!key) { console.error('no TOKKAH_LAB_KEY (env or ~/.config/tokkah/cf.env)'); process.exit(2); }

const post = async (body) => {
  const r = await fetch(`${BASE}/api/room/${encodeURIComponent(ROOM)}/lab`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-lab-key': key },
    body: JSON.stringify(body),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`${r.status} ${t.slice(0, 200)}`);
  return JSON.parse(t);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function ask(body, waitMs = 2000) {
  await post({ op: 'drain' });
  await post(body);
  await sleep(waitMs);
  return (await post({ op: 'drain' })).replies ?? [];
}
const snap = async () => (await ask({ op: 'snap' })).filter((r) => r.turns !== undefined || r.video);

const first = await snap();
if (first.length < 2) {
  console.log(`Need two people talking in room "${ROOM}" — found ${first.length}.`);
  console.log(`Both open:  ${BASE}/?r=${ROOM}`);
  console.log('\nThen talk normally while this runs. No script; the instrument reads a real');
  console.log('conversation. Allow a few minutes per arm — turns arrive every few seconds.');
  process.exit(3);
}

console.log(`turn-taking vs frame rate — room "${ROOM}", ${LO}fps vs ${HI}fps`);
console.log(`${CYCLES} cycles x ${PERIOD}s per arm (~${Math.round(CYCLES * 2 * PERIOD / 60)} min). Talk normally.\n`);

// humanMedian is cumulative over the call, so an arm's contribution has to be
// taken as the DELTA in the underlying samples, not the median read at the end
// — the same windowing trap that inverted the bitrate sweep, wearing a hat.
// `usable` and `humanN` are counters, so a rising median with few new samples
// is a warning that the arm is mostly re-reporting the previous one.
const rows = { [LO]: [], [HI]: [] };
for (let c = 0; c < CYCLES; c++) {
  for (const fps of (c % 2 ? [HI, LO] : [LO, HI])) {
    const applied = await ask({ op: 'set', maxfps: fps }, 1500);
    const got = applied.map((r) => r.applied?.maxfps).filter(Boolean);
    await sleep(8000); // let the rate settle before counting turns against it
    const s0 = await snap();
    await sleep(PERIOD * 1000);
    const s1 = await snap();
    for (let i = 0; i < Math.min(s0.length, s1.length); i++) {
      const t0 = s0[i].turns, t1 = s1[i].turns;
      if (!t0 || !t1) continue;
      rows[fps].push({
        dev: i, cyc: c,
        newHuman: (t1.humanN ?? 0) - (t0.humanN ?? 0),
        humanMedian: t1.humanMedian, perceivedMedian: t1.perceivedMedian,
        breathRate: t1.breathRate, achieved: s1[i].video?.fps ?? null,
        asked: s1[i].askedFps ?? null,
      });
    }
    const last = rows[fps].slice(-2);
    console.log(`  c${c + 1} ${String(fps).padStart(2)}fps  asked ${got.join('/')}  ` +
      `achieved ${last.map((x) => x.achieved).join('/')}  ` +
      `+${last.map((x) => x.newHuman).join('/')} turns  ` +
      `human ${last.map((x) => x.humanMedian ?? '—').join('/')}ms`);
  }
}
await ask({ op: 'set', maxfps: LO }, 800);

const med = (v) => {
  const s = v.filter((x) => Number.isFinite(x)).sort((a, b) => a - b);
  if (!s.length) return null;
  return s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2;
};
const sum = (v) => v.reduce((a, b) => a + (b || 0), 0);

console.log('\n══════ verdict ══════');
let fails = 0;
const check = (n, ok, d) => { if (!ok) fails++; console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${n}${d ? ` — ${d}` : ''}`); };

for (const fps of [LO, HI]) {
  const r = rows[fps];
  console.log(`  ${String(fps).padStart(2)}fps: achieved ${med(r.map((x) => x.achieved))?.toFixed(1)} | ` +
    `${sum(r.map((x) => x.newHuman))} new turns | human ${med(r.map((x) => x.humanMedian))?.toFixed(0)}ms | ` +
    `perceived ${med(r.map((x) => x.perceivedMedian))?.toFixed(0)}ms | breath ${med(r.map((x) => x.breathRate))}%`);
}
// The rate has to have actually changed, or this measured nothing twice.
const aLo = med(rows[LO].map((x) => x.achieved)), aHi = med(rows[HI].map((x) => x.achieved));
check('the frame rate actually moved', aLo != null && aHi != null && aHi > aLo * 1.3,
  `${aLo?.toFixed(1)} vs ${aHi?.toFixed(1)} fps achieved`);
// Enough transitions for a median to mean anything. Boland's effect sizes are
// hundreds of ms; with under ~20 samples per arm the noise is that big too.
const nLo = sum(rows[LO].map((x) => x.newHuman)), nHi = sum(rows[HI].map((x) => x.newHuman));
check('enough turns to have a median', Math.min(nLo, nHi) >= 20,
  `${nLo} vs ${nHi} transitions (want 20+ each; keep talking longer)`);

const hLo = med(rows[LO].map((x) => x.humanMedian)), hHi = med(rows[HI].map((x) => x.humanMedian));
if (hLo != null && hHi != null) {
  const d = hLo - hHi;
  console.log(`\n  human response gap: ${hLo.toFixed(0)}ms at ${LO}fps -> ${hHi.toFixed(0)}ms at ${HI}fps ` +
    `(${d >= 0 ? '-' : '+'}${Math.abs(d).toFixed(0)}ms)`);
  console.log(`  face-to-face control is ~297ms (Boland 2022). Network is excluded from both`);
  console.log(`  numbers by construction, so any difference here is people, not plumbing.`);
}
console.log(`\nVERDICT: ${fails ? `INCONCLUSIVE (${fails})` : 'MEASURED'}`);
process.exit(fails ? 1 : 0);
