/**
 * Is lossless compression of a PCM audio frame worth building?
 *
 * The lane sends 384 samples of int24 (1152 B) every 8 ms = 1.5 Mbps, and the
 * measured SCTP ceiling per association at RTT 80 / 5% loss is ~0.4 Mbps
 * (see MEASURED.md "The second cause"). Cutting the rate is therefore worth more
 * than cutting bytes. FLAC's core — a fixed-order linear predictor plus Rice
 * coding of the residual — is ~100 lines and bit-exact by construction. The
 * question this answers is only whether the ratio justifies the integration,
 * BEFORE any of it touches the app.
 *
 * CORRECTED 2026-08-03. The paragraph below claimed "Rice coding eats them for
 * free". That is FALSE, and believing it left 384 B/frame on the wire for months:
 * Rice spends its k low bits VERBATIM, so eight known-zero bits cost eight bits
 * per sample exactly as if they carried signal. Measured on the shipped coder,
 * removing them took the lane from 0.768 to 0.386 Mbps — half of lane A. The fix
 * is FLAC's wasted-bits field, now in core/pcmpack.js; testbed/pcmwasted.mjs has
 * the numbers and guards the property. The two arms below are still the right
 * arms and their RATIOS are still valid; only the "for free" claim was wrong.
 *
 * The honesty problem, and why this reports two arms:
 *   Every fixture on this machine is 16-bit. Shifted into a 24-bit container the
 *   bottom 8 bits are ZERO, which a coder CAN exploit but this one did not. So
 *   each source is measured twice:
 *     src16   16-bit content in a 24-bit container. Real whenever the capture
 *             chain is effectively 16-bit, and exactly what the test rig feeds.
 *     dither  the same, plus uniform noise across the low 8 bits: a real 24-bit
 *             mic's noise floor, which is incompressible by construction.
 *   The truth for any given device is between them, and quoting only the first
 *   would be the same class of error as measuring 1080p off a 720p camera.
 *
 *   node testbed/pcmpack.mjs
 */
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const FRAME = 384; // samples per frame — the unit that must fit one datagram

// ── FLAC's fixed predictors. No matrix solve, no coefficients on the wire:
// order k predicts s[n] from the k previous samples with binomial weights, and
// the decoder runs the identical recurrence. Order is chosen per frame by
// whichever gives the smallest residual, and costs 3 bits to say.
function residual(s, order) {
  const n = s.length, r = new Int32Array(n);
  for (let i = 0; i < n; i++) {
    const a = i >= 1 ? s[i - 1] : 0, b = i >= 2 ? s[i - 2] : 0;
    const c = i >= 3 ? s[i - 3] : 0, d = i >= 4 ? s[i - 4] : 0;
    r[i] = order === 0 ? s[i]
      : order === 1 ? s[i] - a
      : order === 2 ? s[i] - 2 * a + b
      : order === 3 ? s[i] - 3 * a + 3 * b - c
      : s[i] - 4 * a + 6 * b - 4 * c + d;
  }
  return r;
}

// Rice/Golomb: zigzag the signed residual, then spend k low bits verbatim and
// the rest in unary. Optimal k for a Laplacian residual is ~log2(mean(|r|)),
// found here by direct search over the only 24 values it can take.
const zig = (v) => (v << 1) ^ (v >> 31);
function riceBits(r, k) {
  let bits = 0;
  for (let i = 0; i < r.length; i++) bits += (zig(r[i]) >>> k) + 1 + k;
  return bits;
}
function bestRice(r) {
  let bk = 0, bb = Infinity;
  for (let k = 0; k < 24; k++) {
    const b = riceBits(r, k);
    if (b < bb) { bb = b; bk = k; }
    else if (b > bb * 4) break; // past the minimum, unary length is exploding
  }
  return { k: bk, bits: bb };
}

// One frame -> compressed bit count. 8 bits of frame header (3 order + 5 k).
// Escape to stored-verbatim when prediction loses, which is what keeps the
// WORST case at 1152 B + 1 rather than unbounded — the property the datagram
// budget actually needs.
function packFrame(s) {
  let best = 8 + FRAME * 24; // verbatim
  for (let order = 0; order <= 4; order++) {
    const b = 8 + bestRice(residual(s, order)).bits;
    if (b < best) best = b;
  }
  return best;
}

function wav(path) {
  const b = readFileSync(path);
  let off = 12, fmt = null, data = null;
  while (off + 8 <= b.length) {
    const id = b.toString('ascii', off, off + 4), sz = b.readUInt32LE(off + 4);
    if (id === 'fmt ') fmt = { ch: b.readUInt16LE(off + 10), rate: b.readUInt32LE(off + 12), bits: b.readUInt16LE(off + 22) };
    if (id === 'data') data = b.subarray(off + 8, off + 8 + sz);
    off += 8 + sz + (sz & 1);
  }
  const n = Math.floor(data.length / 2 / fmt.ch);
  const s = new Int32Array(n);
  for (let i = 0; i < n; i++) s[i] = data.readInt16LE(i * 2 * fmt.ch); // channel 0
  return { ...fmt, s };
}

const sources = [];
for (const f of ['fullband.wav', 'floor-fall.wav', 'probe.wav']) {
  try {
    const w = wav(`${process.cwd()}/media/${f}`);
    sources.push({ name: f, rate: w.rate, s: w.s });
  } catch (e) { console.log(`skip ${f}: ${e.message}`); }
}
// LibriSpeech is the only real connected speech here, but it is 16 kHz — decode
// and resample to 48 kHz so the predictor sees the sample-to-sample correlation
// it will actually face. Flagged in the output because upsampling INVENTS
// correlation: an interpolated stream is more predictable than a natively
// captured one, so its ratio is an optimistic bound, not a measurement.
try {
  const flac = execFileSync('find', ['media/LibriSpeech', '-name', '*.flac']).toString().split('\n')[0];
  if (flac) {
    const raw = execFileSync('ffmpeg', ['-v', 'quiet', '-i', flac, '-ar', '48000', '-ac', '1', '-f', 's16le', '-'], { maxBuffer: 1 << 28 });
    const n = raw.length / 2, s = new Int32Array(n);
    for (let i = 0; i < n; i++) s[i] = raw.readInt16LE(i * 2);
    sources.push({ name: 'LibriSpeech (16k->48k, optimistic)', rate: 48000, s });
  }
} catch (e) { console.log(`skip LibriSpeech: ${String(e.message).slice(0, 80)}`); }

console.log('Lossless frame compression, 384 samples of int24 (1152 B raw).');
console.log('Budget is 1160 B on the wire; the lane costs 1.5 Mbps at 125 frames/s.\n');
console.log('  source                                arm      mean B   ratio    p95 B   max B   over1152');

// xorshift32 via Math.imul, NOT an LCG written in doubles: `rng * 1103515245`
// exceeds 2^53, so the low bits of the product are not representable, come out
// as zeros, and `& 0x7fffffff` then collapses the sequence. The first run of
// this file reported the dither arm byte-for-byte identical to the undithered
// one — which is impossible, and was the generator returning 0 every time.
let rng = 12345;
const rnd = () => {
  rng ^= rng << 13; rng |= 0;
  rng ^= rng >>> 17;
  rng ^= rng << 5; rng |= 0;
  return (rng >>> 0) / 4294967296;
};

for (const src of sources) {
  for (const arm of ['src16', 'dither']) {
    const bytes = [];
    let over = 0;
    const nf = Math.min(4000, Math.floor(src.s.length / FRAME));
    for (let f = 0; f < nf; f++) {
      const s = new Int32Array(FRAME);
      for (let i = 0; i < FRAME; i++) {
        const v = src.s[f * FRAME + i] << 8;
        s[i] = arm === 'dither' ? v + ((rnd() * 256) | 0) : v;
      }
      const b = Math.ceil(packFrame(s) / 8);
      bytes.push(b);
      if (b > 1152) over++;
    }
    if (!bytes.length) continue;
    bytes.sort((a, b) => a - b);
    const mean = bytes.reduce((a, b) => a + b, 0) / bytes.length;
    const p95 = bytes[Math.floor(bytes.length * 0.95)];
    console.log(`  ${src.name.padEnd(36)}  ${arm.padEnd(7)}  ${mean.toFixed(0).padStart(6)}` +
      `  ${(mean / 1152).toFixed(3).padStart(6)}  ${String(p95).padStart(6)}  ${String(bytes[bytes.length - 1]).padStart(6)}  ${String(over).padStart(8)}`);
  }
}
console.log('\nratio is compressed/raw: 0.70 means the lane drops 1.5 -> 1.05 Mbps.');
console.log('over1152 counts frames where prediction LOST — those ship verbatim, so');
console.log('the worst case is bounded at 1153 B and the datagram budget always holds.');
