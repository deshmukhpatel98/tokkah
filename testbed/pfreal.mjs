#!/usr/bin/env node
/**
 * pfreal.mjs — the presence filter, measured on a REAL CAMERA SENSOR.
 *
 * Every bitrate number the filter has (DESIGN.md §17.25: 61.5% fewer bits) came
 * from already-compressed fixture video. That footage has been through an
 * encoder before it reaches us, so most of its sensor grain is already gone —
 * which cuts both ways, and neither way is knowable from a fixture:
 *
 *   · A real sensor has MORE grain, so the denoise half should earn more.
 *   · A real sensor's auto-exposure never stops drifting, so the hold half may
 *     earn LESS — a picture that is never quite identical twice never locks —
 *     until the upward-adapting threshold finds that camera's noise floor.
 *
 * The three lanes that were supposed to supply a sensor are all shut here: the
 * Android emulator's webcam passthrough is dead on Darwin 27, no phone is
 * tethered, and the Browser pane blocks camera access. This one needs none of
 * them. Someone opens a room on a phone or a laptop; this drives the arms over
 * the lab channel and reads that device's own encoder.
 *
 *   1. On the device:  https://room.tokkah.com/?r=lab&pfilter=1&rcres=0&qp=24
 *   2. Here:           node testbed/pfreal.mjs --rounds=4
 *
 * Arms are swapped inside ONE call in front of ONE camera, so the comparison is
 * a path against itself seconds apart. Bytes come from cumulative counters
 * differenced across the slot, never from `mbps` — that field averages the last
 * 900 encoded frames (30 s at 30fps) and reading it after a shorter arm blends
 * the arms together, which has already inverted one result outright.
 */
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';

const ROOM = process.env.LAB_ROOM ?? 'lab';
const BASE = process.env.URL ?? 'https://room.tokkah.com';
const arg = (k, d) => { const m = process.argv.find((a) => a.startsWith(`--${k}=`)); return m ? m.slice(k.length + 3) : d; };
const ROUNDS = Number(arg('rounds', 4));
const MEASURE = Number(arg('measure', 8));
const SETTLE = Number(arg('settle', 3));

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
  const text = await r.text();
  if (!r.ok) throw new Error(`${r.status} ${text.slice(0, 200)}`);
  return JSON.parse(text);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function ask(body, waitMs = 1800) {
  await post({ op: 'drain' }); // clear stale replies so an answer is THIS answer
  await post(body);
  await sleep(waitMs);
  const { replies } = await post({ op: 'drain' });
  return replies ?? [];
}
const snap = async () => (await ask({ op: 'snap' })).map((r) => r.video).filter(Boolean);

// The candidate shipping configuration against its own control. Soften stays at
// zero in both: it is the one lever that removes detail the camera really saw,
// and it was worth 4 points on top of the two that do not.
const ARMS = [
  { name: 'off', p: { pfilter: '0' } },
  { name: 'on', p: { pfilter: '1', denoise: 0.85, soften: 0, hold: 1 } },
];

console.log(`presence filter on a REAL SENSOR — room "${ROOM}", ${ROUNDS} rounds x ${ARMS.length} arms`);
console.log(`${SETTLE}s settle + ${MEASURE}s measured per arm\n`);

const first = await snap();
if (!first.length) {
  console.log('No one is in the room. Open this on the device whose camera you want measured:');
  console.log(`  ${BASE}/?r=${ROOM}&pfilter=1&rcres=0&qp=24&l2rcqpmin=24&l2rcqpmax=24`);
  console.log('\nThen run this again. Two devices give two sensors; one is enough.');
  process.exit(3);
}
if (first[0].encBytesTotal == null) {
  console.log('The device is on a build without encBytesTotal — reload it after deploying, or the');
  console.log('bitrates will be 30-second averages and the arms will blend together.');
  process.exit(1);
}
console.log(`${first.length} device(s) in the room, ${first[0].w}x${first[0].h} at qp ${first[0].qp}\n`);

const samples = new Map(ARMS.map((a) => [a.name, []]));
for (let r = 0; r < ROUNDS; r++) {
  // Rotate so neither arm keeps landing on the same part of whatever the person
  // happens to be doing — talking, pausing, leaning back.
  for (const arm of (r % 2 ? [...ARMS].reverse() : ARMS)) {
    await ask({ op: 'set', ...arm.p }, 800);
    await sleep(SETTLE * 1000);
    const s0 = await snap();
    await sleep(MEASURE * 1000);
    const s1 = await snap();
    for (let i = 0; i < Math.min(s0.length, s1.length); i++) {
      const dt = (s1[i].t - s0[i].t) / 1000;
      if (!(dt > 1)) continue;
      samples.get(arm.name).push({
        dev: i, round: r,
        mbps: (s1[i].encBytesTotal - s0[i].encBytesTotal) * 8 / dt / 1e6,
        fps: (s1[i].encFramesTotal - s0[i].encFramesTotal) / dt,
        still: s1[i].pfStillMean, shrink: s1[i].rcResShrink,
        g2g: s1[i].glassToGlassMs, fallbacks: s1[i].pfFallbacks,
      });
    }
    const last = samples.get(arm.name).slice(-Math.max(1, first.length));
    console.log(`  r${r + 1} ${arm.name.padEnd(3)} ` +
      last.map((x) => `dev${x.dev} ${x.mbps.toFixed(2)}Mbps @${x.fps.toFixed(0)}fps`).join('  ') +
      `  still ${last[0]?.still ?? '—'}`);
  }
}
await ask({ op: 'set', pfilter: '0' }, 500); // leave the call as we found it

const med = (v) => {
  const s = v.filter((x) => Number.isFinite(x)).sort((a, b) => a - b);
  if (!s.length) return null;
  return s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2;
};
const offBy = new Map(samples.get('off').map((x) => [`${x.dev}:${x.round}`, x.mbps]));
const cuts = samples.get('on').map((x) => {
  const o = offBy.get(`${x.dev}:${x.round}`);
  return o > 0 ? (1 - x.mbps / o) * 100 : null;
}).filter((x) => x != null);

let fails = 0;
const check = (name, ok, detail) => { if (!ok) fails++; console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`); };
const mOff = med(samples.get('off').map((x) => x.mbps));
const mOn = med(samples.get('on').map((x) => x.mbps));

console.log('\n══════ real sensor ══════');
check('the filter ran clean', med(samples.get('on').map((x) => x.fallbacks)) === 0,
  `${med(samples.get('on').map((x) => x.fallbacks))} declines`);
check('the lock found this sensor', (med(samples.get('on').map((x) => x.still)) ?? 0) > 0.10,
  `${((med(samples.get('on').map((x) => x.still)) ?? 0) * 100).toFixed(0)}% of the picture below the motion threshold`);
check('bits went down', cuts.length > 0 && med(cuts) > 10,
  `${mOff?.toFixed(2)} -> ${mOn?.toFixed(2)} Mbps, ${med(cuts)?.toFixed(1)}% ` +
  `(per-round ${Math.min(...cuts).toFixed(0)}..${Math.max(...cuts).toFixed(0)}%)`);
check('frame rate held', Math.abs((med(samples.get('on').map((x) => x.fps)) ?? 0) - (med(samples.get('off').map((x) => x.fps)) ?? 0)) < 2,
  `${med(samples.get('off').map((x) => x.fps))?.toFixed(1)} -> ${med(samples.get('on').map((x) => x.fps))?.toFixed(1)} fps`);
const shr = [...new Set([...samples.get('off'), ...samples.get('on')].map((x) => x.shrink))];
check('same resolution both arms', shr.length === 1, `divisor ${shr.join(', ')}`);
console.log(`\nVERDICT: ${fails ? `FAIL (${fails})` : 'PASS'}`);
console.log('The picture still has to be looked at — ask the person on camera whether anything');
console.log('froze, smeared or went soft. No number in this rig can answer that.');
process.exit(fails ? 1 : 0);
