/**
 * Regression check for the codec's wasted-bits field, and the record of what it
 * was worth.
 *
 * THE ORIGINAL QUESTION. The capture worklet converts float32 to int24 with
 * `x * 8388608`. When the capture chain is effectively 16-bit — every consumer
 * microphone, and every fixture in this repo — each sample is an exact multiple
 * of 256, so the bottom 8 bits of all 384 samples are zero. Rice coding cannot
 * exploit that: it spends its k low bits VERBATIM, so 8 known-zero bits per
 * sample cost 384 B per frame of literal zeros.
 *
 * MEASURED, against the coder that was live before the field existed:
 *
 *   arm      mean B   ->  after     lane Mbps
 *   src16      768        386       0.768 -> 0.386   (49.7% of the payload)
 *   dither     769        769       0.769 -> 0.769   (byte-identical, shift 0)
 *
 * Two docstrings in this repo had disagreed about this. pcmpack.mjs said "the
 * bottom 8 bits are ZERO, and Rice coding eats them for free" — wrong, and the
 * table above is what it cost. pcmpack.js said dithering the low 8 bits changes
 * the ratio by <0.3% — right, and the SAME fact from the other side: zeros and
 * noise cost the same, because both are paid at full price.
 *
 * WHY THIS FILE STILL RUNS. The before-arm cannot be re-measured now that the
 * field is shipped, so the two checks below are the ones that can actually fail:
 *   1. src16 must cost the SAME as coding the 16-bit signal directly. That is
 *      the mechanism working — the container is costing nothing.
 *   2. dither must cost ~384 B MORE. That is the mechanism staying honest: it
 *      must be content-dependent, not an unconditional truncation. If this ever
 *      collapsed to "src16 == dither" the codec would be discarding real bits and
 *      still reporting success.
 * Both are asserted, and bit-exactness is asserted on every frame of every arm.
 *
 * Header cost is zero bytes: the frame header is `order << 5` and had 5 bits
 * spare, which is exactly enough for a shift of 0..24.
 *
 *   node testbed/pcmwasted.mjs
 */
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
import { packFrame, unpackFrame, PACK_SAMPLES as N } from '../tape-app/public/core/pcmpack.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const MAXB = 1 + N * 3;

function wav(path) {
  const b = readFileSync(path);
  let off = 12, fmt = null, data = null;
  while (off + 8 <= b.length) {
    const id = b.toString('ascii', off, off + 4), sz = b.readUInt32LE(off + 4);
    if (id === 'fmt ') fmt = { ch: b.readUInt16LE(off + 10), rate: b.readUInt32LE(off + 12), bits: b.readUInt16LE(off + 22) };
    if (id === 'data') data = b.subarray(off + 8, off + 8 + sz);
    off += 8 + sz + (sz & 1);
  }
  if (!fmt || !data) throw new Error('no fmt/data chunk');
  if (fmt.bits !== 16) throw new Error(`${fmt.bits}-bit, expected 16`);
  const n = Math.floor(data.length / 2 / fmt.ch);
  const s = new Int32Array(n);
  for (let i = 0; i < n; i++) s[i] = data.readInt16LE(i * 2 * fmt.ch);
  return { ...fmt, s };
}

const sources = [];
for (const f of ['conv/A.wav', 'conv/B.wav', 'fullband.wav', 'floor-fall.wav', 'probe.wav']) {
  try { sources.push({ name: f, s: wav(`${HERE}/media/${f}`).s }); }
  catch (e) { console.log(`skip ${f}: ${e.message}`); }
}
try {
  const flac = execFileSync('find', [`${HERE}/media/LibriSpeech`, '-name', '*.flac']).toString().split('\n')[0];
  if (flac) {
    const raw = execFileSync('ffmpeg', ['-v', 'quiet', '-i', flac, '-ar', '48000', '-ac', '1', '-f', 's16le', '-'], { maxBuffer: 1 << 28 });
    const n = raw.length / 2, s = new Int32Array(n);
    for (let i = 0; i < n; i++) s[i] = raw.readInt16LE(i * 2);
    sources.push({ name: 'LibriSpeech (16k->48k)', s });
  }
} catch (e) { console.log(`skip LibriSpeech: ${String(e.message).slice(0, 80)}`); }

if (!sources.length) { console.log('NO FIXTURES — refusing to print a result'); process.exit(2); }

// xorshift32. An LCG written in doubles silently returns zeros here (see
// pcmpack.mjs), and a zero dither would make two arms identical — the exact
// false pass this file exists to catch.
let rng = 12345;
const rnd = () => {
  rng ^= rng << 13; rng |= 0; rng ^= rng >>> 17; rng ^= rng << 5; rng |= 0;
  return (rng >>> 0) / 4294967296;
};

//   sig16   the 16-bit signal coded directly. The information content, shift 0.
//   src16   the same signal in a 24-bit container. Must MATCH sig16.
//   dither  a genuine 24-bit noise floor. Must cost ~384 B MORE.
const ARMS = ['sig16', 'src16', 'dither'];
const out = new Uint8Array(MAXB + 16);
const back = new Int32Array(N);
let failures = 0;
const mean = {};

console.log('\n384 samples per frame, 1152 B raw at int24, 125 frames/s.\n');
console.log('  source                        sig16 B   src16 B   dither B    shift(src16/dither)');

for (const src of sources) {
  const m = {};
  for (const arm of ARMS) {
    let sum = 0, shSum = 0, nf = 0;
    const lim = Math.min(4000, Math.floor(src.s.length / N));
    const s = new Int32Array(N);
    for (let f = 0; f < lim; f++) {
      for (let i = 0; i < N; i++) {
        const v = src.s[f * N + i];
        s[i] = arm === 'sig16' ? v : arm === 'dither' ? (v << 8) + ((rnd() * 256) | 0) : v << 8;
      }
      const n = packFrame(s, out);
      if (n > MAXB) { console.log(`  BOUND BROKEN ${src.name} ${arm} frame ${f}: ${n} B`); failures++; }
      // In-band: the shift is read back from the header by unpackFrame, never
      // passed alongside it. An out-of-band round-trip would have hidden the
      // verbatim-escape bug this codec shipped with for one edit.
      back.fill(0);
      unpackFrame(out.subarray(0, n), back);
      for (let i = 0; i < N; i++) {
        if (back[i] !== s[i]) {
          if (failures < 5) console.log(`  MISMATCH ${src.name} ${arm} frame ${f} sample ${i}: ${back[i]} != ${s[i]}`);
          failures++; break;
        }
      }
      shSum += out[0] & 31; sum += n; nf++;
    }
    m[arm] = { b: sum / nf, sh: shSum / nf };
    mean[arm] = (mean[arm] || 0) + sum / nf / sources.length;
  }
  console.log(`  ${src.name.padEnd(28)}  ${m.sig16.b.toFixed(0).padStart(7)}  ${m.src16.b.toFixed(0).padStart(8)}` +
    `  ${m.dither.b.toFixed(0).padStart(9)}     ${m.src16.sh.toFixed(1)} / ${m.dither.sh.toFixed(1)}`);
}

console.log(`\n  mean over sources:  sig16 ${mean.sig16.toFixed(0)} B   src16 ${mean.src16.toFixed(0)} B   dither ${mean.dither.toFixed(0)} B`);
console.log(`  lane rate:          ${((mean.src16 * 8 * 125) / 1e6).toFixed(3)} Mbps on a 16-bit chain, ` +
  `${((mean.dither * 8 * 125) / 1e6).toFixed(3)} Mbps on a true 24-bit one`);

// ── the two assertions ──────────────────────────────────────────────────────
const containerCost = mean.src16 - mean.sig16;
if (Math.abs(containerCost) > 1) {
  console.log(`\n  FAIL: the 24-bit container costs ${containerCost.toFixed(1)} B/frame; it must cost 0.`);
  console.log('  The wasted-bits shift is not recovering the container, so the lane is');
  console.log('  paying ~384 B/frame for bits that carry nothing.');
  failures++;
}
const ditherCost = mean.dither - mean.src16;
if (ditherCost < 380) {
  console.log(`\n  FAIL: a 24-bit noise floor costs only ${ditherCost.toFixed(1)} B/frame more; expected ~384.`);
  console.log('  That means the codec is DISCARDING low bits rather than detecting that');
  console.log('  they are absent — a lossy truncation reporting itself as lossless.');
  failures++;
}

console.log(`\n  bit-exactness: ${failures === 0 ? 'PASS' : 'FAILURES'} — every sample of every frame, shift read from the header`);
if (!failures) {
  console.log(`  container costs ${containerCost.toFixed(1)} B/frame (must be 0)`);
  console.log(`  real 24-bit content costs ${ditherCost.toFixed(0)} B/frame more (must be ~384, proving nothing is discarded)`);
}
process.exit(failures ? 1 : 0);
