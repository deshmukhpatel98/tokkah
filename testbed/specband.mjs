/**
 * #21 analyzer: decode the worklet PCM taps from two run dirs and compare
 * band energy.
 *
 *   node specband.mjs runs/<arm1> runs/<arm2> [side]
 *
 * `side` defaults to B (B's tap = A's full-band stimulus after encode, the
 * network, the jitter buffer and decode). Hann-windowed 16384-point FFT,
 * hop 8192, magnitudes averaged linearly per bin across the capture (first
 * 2 s and last 1 s dropped), then band means in dB. The QUESTION is band
 * presence/absence — is there energy above 8 kHz — not precise response.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const [d1, d2, side = 'B'] = process.argv.slice(2);
if (!d1 || !d2) { console.error('usage: node specband.mjs runs/<a> runs/<b> [side]'); process.exit(2); }

const BANDS = [[0, 1000], [1000, 4000], [4000, 6000], [6000, 8000], [8000, 10000], [10000, 12000], [12000, 16000], [16000, 20000]];
const N = 16384, HOP = 8192;

// In-place iterative radix-2 FFT.
function fft(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      let t = re[i]; re[i] = re[j]; re[j] = t;
      t = im[i]; im[i] = im[j]; im[j] = t;
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (-2 * Math.PI) / len, wr = Math.cos(ang), wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cwr = 1, cwi = 0;
      for (let j = 0; j < len / 2; j++) {
        const k = i + j, k2 = k + len / 2;
        const vr = re[k2] * cwr - im[k2] * cwi, vi = re[k2] * cwi + im[k2] * cwr;
        re[k2] = re[k] - vr; im[k2] = im[k] - vi;
        re[k] += vr; im[k] += vi;
        const nwr = cwr * wr - cwi * wi;
        cwi = cwr * wi + cwi * wr; cwr = nwr;
      }
    }
  }
}

function bands(dir) {
  const j = JSON.parse(readFileSync(join(dir, `${side}.json`), 'utf8'));
  const tap = j.specTap;
  if (!tap?.b64) return { err: `no specTap PCM (blocks=${tap?.blocks ?? 'n/a'})` };
  const pcm = new Float32Array(Buffer.from(tap.b64, 'base64').buffer.slice(0));
  const sr = tap.sampleRate;
  const hz = sr / N; // bin width
  const hann = new Float64Array(N);
  for (let i = 0; i < N; i++) hann[i] = 0.5 * (1 - Math.cos((2 * Math.PI * i) / (N - 1)));
  const acc = new Float64Array(N / 2);
  let frames = 0;
  const t0 = 2 * sr, t1 = pcm.length - sr; // skip 2 s warmup, 1 s tail
  for (let off = t0; off + N <= t1; off += HOP) {
    const re = new Float64Array(N), im = new Float64Array(N);
    for (let i = 0; i < N; i++) re[i] = pcm[off + i] * hann[i];
    fft(re, im);
    for (let i = 0; i < N / 2; i++) acc[i] += Math.hypot(re[i], im[i]);
    frames++;
  }
  if (!frames) return { err: 'too little PCM' };
  const level = BANDS.map(([lo, hi]) => {
    const a = Math.max(1, Math.floor(lo / hz)), b = Math.min(N / 2 - 1, Math.ceil(hi / hz));
    let sum = 0;
    for (let i = a; i <= b; i++) sum += acc[i];
    return 20 * Math.log10(sum / ((b - a + 1) * frames * (N / 2)) + 1e-12);
  });
  return { level, seconds: +(pcm.length / sr).toFixed(1), frames, blocks: tap.blocks, diag: tap.diag };
}

const r1 = bands(d1), r2 = bands(d2);
for (const [d, r] of [[d1, r1], [d2, r2]]) {
  if (r.err) { console.error(`${d}: ${r.err}`); process.exit(1); }
  console.error(`${d}: ${r.seconds}s pcm, ${r.frames} frames, blocks=${r.blocks}, diag=${JSON.stringify(r.diag)}`);
}

console.log(`side ${side}, mean dBFS per band:`);
console.log('band (Hz)         arm1     arm2     Δ (arm2−arm1)');
BANDS.forEach(([lo, hi], i) => {
  const a = r1.level[i].toFixed(1).padStart(7), b = r2.level[i].toFixed(1).padStart(7);
  const d = (r2.level[i] - r1.level[i]).toFixed(1).padStart(7);
  console.log(`${String(lo).padStart(5)}–${String(hi).padEnd(6)} ${a}  ${b}  ${d}`);
});
