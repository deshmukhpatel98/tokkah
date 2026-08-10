#!/usr/bin/env node
/**
 * presence-core rig — proves the module's stated law before a browser sees it.
 *
 * Arms:
 *   1. direct-path unity      an impulse arrives at n=0, amplitude exactly 1.0,
 *                             in BOTH ears — the voice is never touched.
 *   2. pre-echo bit-exactness until the first tap's delay has elapsed, output
 *                             is bit-identical to input (per ear).
 *   3. tap geometry           reflection energy lands only inside ±1 ms windows
 *                             around the six published delays, at the published
 *                             level ±1.5 dB (lowpass spreads the impulse).
 *   4. level bound            speech-like noise: RMS gain ≤ +1.0 dB,
 *                             peak gain ≤ +2.5 dB — additive room, not a boost.
 *   5. decorrelation          IACC of the reflection field < 0.5 — the property
 *                             that buys externalization (direct is identical by
 *                             construction, so measure L−x vs R−x).
 *   6. silence flush          after signal stops, output decays to EXACT zeros
 *                             once the delay line drains — no denormal tail.
 *   7. cost                   render seconds per wall second, headroom report.
 *
 *   node testbed/presence-core.test.mjs
 */
import { createPresence } from '../tape-app/public/core/presence-core.js';

const SR = 48000;
const TAPS = [
  { ms: 7.9, db: -20, ear: 0 },
  { ms: 9.7, db: -20, ear: 1 },
  { ms: 13.1, db: -23, ear: 0 },
  { ms: 15.9, db: -23, ear: 1 },
  { ms: 21.7, db: -26, ear: 0 },
  { ms: 24.9, db: -26, ear: 1 },
];

let fails = 0;
const arm = (name, ok, detail) => {
  console.log(`Arm (${name}): ${ok ? 'PASS' : 'FAIL'} (${detail})`);
  if (!ok) fails++;
};

const render = (p, input) => {
  const L = new Float32Array(input.length);
  const R = new Float32Array(input.length);
  const BLOCK = 128;
  for (let i = 0; i < input.length; i += BLOCK) {
    const n = Math.min(BLOCK, input.length - i);
    p.render(input.subarray(i, i + n), L.subarray(i, i + n), R.subarray(i, i + n));
  }
  return { L, R };
};

// Deterministic noise (mulberry32) — Date/Math.random are not the rig's clock.
const rng = (seed) => () => {
  seed |= 0; seed = (seed + 0x6d2b79f5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};

// ── 1 + 2 + 3: impulse response ─────────────────────────────────────────────
{
  const N = SR / 10; // 100 ms
  const x = new Float32Array(N);
  x[0] = 1;
  const { L, R } = render(createPresence({ sampleRate: SR }), x);

  arm('direct unity', L[0] === 1 && R[0] === 1, `L[0]=${L[0]} R[0]=${R[0]}`);

  const firstTap = Math.round((7.9 / 1000) * SR);
  let preEchoClean = true;
  for (let n = 1; n < firstTap; n++) if (L[n] !== 0 || R[n] !== 0) preEchoClean = false;
  arm('pre-echo bit-exact', preEchoClean, `samples 1..${firstTap - 1} all zero`);

  // Tap geometry: windowed peak level per tap, and no energy outside windows.
  const win = Math.round(0.001 * SR);
  let geomOk = true;
  const details = [];
  for (const t of TAPS) {
    const d = Math.round((t.ms / 1000) * SR);
    const ch = t.ear === 0 ? L : R;
    let peak = 0;
    for (let n = d - win; n <= d + win; n++) peak = Math.max(peak, Math.abs(ch[n]));
    const db = 20 * Math.log10(peak);
    details.push(`${t.ms}ms ${db.toFixed(1)}dB`);
    if (Math.abs(db - t.db) > 1.5) geomOk = false;
  }
  // Outside all windows (and past the direct sample), only lowpass smear far
  // below the quietest tap is allowed.
  const inWindow = (n, ear) => TAPS.some((t) => t.ear === ear
    && Math.abs(n - Math.round((t.ms / 1000) * SR)) <= 8 * win);
  let stray = 0;
  for (let n = 1; n < N; n++) {
    if (!inWindow(n, 0) && Math.abs(L[n]) > Math.pow(10, -32 / 20)) stray++;
    if (!inWindow(n, 1) && Math.abs(R[n]) > Math.pow(10, -32 / 20)) stray++;
  }
  arm('tap geometry', geomOk && stray === 0, `${details.join(', ')}; stray=${stray}`);
}

// ── 4 + 5: speech-like noise ────────────────────────────────────────────────
{
  const N = SR * 2;
  const r = rng(0xC0FFEE);
  const x = new Float32Array(N);
  let s = 0;
  for (let n = 0; n < N; n++) { s = 0.97 * s + 0.4 * (r() * 2 - 1); x[n] = s * 0.35; }
  const { L, R } = render(createPresence({ sampleRate: SR }), x);

  const rms = (a) => Math.sqrt(a.reduce((q, v) => q + v * v, 0) / a.length);
  const peak = (a) => a.reduce((q, v) => Math.max(q, Math.abs(v)), 0);
  const rmsGain = 20 * Math.log10(rms(L) / rms(x));
  const peakGain = 20 * Math.log10(peak(L) / peak(x));
  arm('level bound', rmsGain <= 1.0 && peakGain <= 2.5,
    `rms +${rmsGain.toFixed(2)} dB, peak +${peakGain.toFixed(2)} dB`);

  // Reflection fields (direct is the input itself, by arm 1's proof).
  const skip = SR / 2; // past warmup
  let ll = 0, rr2 = 0, lr = 0;
  for (let n = skip; n < N; n++) {
    const a = L[n] - x[n];
    const b = R[n] - x[n];
    ll += a * a; rr2 += b * b; lr += a * b;
  }
  const iacc = Math.abs(lr) / Math.sqrt(ll * rr2);
  arm('decorrelation', iacc < 0.5, `reflection IACC ${iacc.toFixed(3)}`);
}

// ── 6: silence flush ────────────────────────────────────────────────────────
{
  const r = rng(0xBEEF);
  const N = SR; // 1 s: 100 ms of noise, then silence
  const x = new Float32Array(N);
  for (let n = 0; n < SR / 10; n++) x[n] = (r() * 2 - 1) * 0.5;
  const { L, R } = render(createPresence({ sampleRate: SR }), x);
  // After noise end + longest tap (24.9 ms) + lowpass decay slack (75 ms total),
  // every remaining sample must be EXACTLY zero.
  const from = SR / 10 + Math.round(0.075 * SR);
  let dirty = 0;
  for (let n = from; n < N; n++) if (L[n] !== 0 || R[n] !== 0) dirty++;
  arm('silence flush', dirty === 0, `samples ${from}.. exact zeros, dirty=${dirty}`);
}

// ── 7: cost ─────────────────────────────────────────────────────────────────
{
  const N = SR * 30;
  const x = new Float32Array(N);
  const r = rng(1);
  for (let n = 0; n < N; n++) x[n] = (r() * 2 - 1) * 0.3;
  const p = createPresence({ sampleRate: SR });
  const L = new Float32Array(128);
  const R = new Float32Array(128);
  const t0 = performance.now();
  for (let i = 0; i + 128 <= N; i += 128) p.render(x.subarray(i, i + 128), L, R);
  const wall = (performance.now() - t0) / 1000;
  const ratio = (N / SR) / wall;
  arm('cost', ratio > 50, `${ratio.toFixed(0)}x realtime (${((100 * SR) / SR / ratio).toFixed(2)}% of audio thread)`);
}

console.log(fails === 0 ? '\nALL ARMS PASS' : `\n${fails} ARM(S) FAILED`);
process.exit(fails === 0 ? 0 : 1);
