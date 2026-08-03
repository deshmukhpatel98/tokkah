/**
 * Bit-exactness of the PCM frame codec. "Lossless" is the entire claim, so this
 * asserts every sample of every frame, not sizes.
 *
 * Adversarial cases are the point. Real speech exercises the predictors; the
 * synthetic cases exercise the paths a fixture will never reach — full-scale
 * ±2^23 (where an order-4 residual can reach 16x the sample range), alternating
 * extremes, white noise (incompressible, must take the verbatim escape and must
 * not expand past the bound), DC, silence, and a single impulse.
 *
 *   node testbed/pcmpack-test.mjs
 */
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
import { packFrame, unpackFrame, PACK_SAMPLES as N } from '../tape-app/public/core/pcmpack.js';

// Fixtures resolve from THIS FILE, never from cwd. Run from the repo root the
// paths missed, every real-audio case was skipped by a bare `catch {}`, and the
// run still printed "0 failures" — a test that cannot fail. The empty-corpus
// guard at the bottom is the other half of that fix.
const HERE = dirname(fileURLToPath(import.meta.url));

const MAXB = 1 + N * 3;
const out = new Uint8Array(MAXB + 16);
const back = new Int32Array(N);
let fail = 0, frames = 0, totalIn = 0, totalOut = 0;

function check(name, s, { pad = false } = {}) {
  frames++;
  const n = packFrame(s, out);
  if (n > MAXB) { console.log(`  FAIL ${name}: ${n} B exceeds the ${MAXB} B bound`); fail++; return n; }
  // Zero-pad to 1152+1 the way the RS group will, to prove the decoder stops on
  // its own and never reads the padding as data.
  const buf = pad ? new Uint8Array(MAXB) : out.subarray(0, n);
  if (pad) buf.set(out.subarray(0, n));
  back.fill(0);
  unpackFrame(buf, back);
  for (let i = 0; i < N; i++) {
    if (back[i] !== s[i]) {
      // The header's low 5 bits are the WASTED-BITS SHIFT, not k — k is 5 bits
      // per partition inside the bitstream. They read 0 on every frame before
      // the shift existed, which is why the old label went unnoticed.
      console.log(`  FAIL ${name}${pad ? ' (padded)' : ''}: sample ${i} ${s[i]} -> ${back[i]} (order ${out[0] >>> 5} sh ${out[0] & 31}, ${n} B)`);
      fail++; return n;
    }
  }
  totalIn += N * 3; totalOut += n;
  return n;
}

// ── synthetic adversarial frames ────────────────────────────────────────────
const mk = (f) => { const s = new Int32Array(N); for (let i = 0; i < N; i++) s[i] = f(i); return s; };
let rng = 987654321;
const rnd = () => { rng ^= rng << 13; rng |= 0; rng ^= rng >>> 17; rng ^= rng << 5; rng |= 0; return (rng >>> 0) / 4294967296; };

const cases = [
  ['silence', mk(() => 0)],
  ['dc-max', mk(() => 8388607)],
  ['dc-min', mk(() => -8388608)],
  ['alternating-extremes', mk((i) => (i & 1 ? 8388607 : -8388608))],
  ['impulse', mk((i) => (i === 200 ? 8388607 : 0))],
  ['impulse-negative', mk((i) => (i === 0 ? -8388608 : 0))],
  ['ramp', mk((i) => Math.round((i / N) * 16777215) - 8388608)],
  ['sine-full-scale', mk((i) => Math.round(8388607 * Math.sin((i * 2 * Math.PI) / 37)))],
  ['sine-tiny', mk((i) => Math.round(3 * Math.sin((i * 2 * Math.PI) / 37)))],
  ['white-noise-full', mk(() => Math.round((rnd() - 0.5) * 16777214))],
  ['white-noise-lsb', mk(() => Math.round((rnd() - 0.5) * 4))],
  ['step', mk((i) => (i < N / 2 ? -8388608 : 8388607))],
  // ── wasted-bits cases ─────────────────────────────────────────────────────
  // Frames whose samples share trailing zeros, which is what a 16-bit capture
  // chain in a 24-bit container looks like. The shift must appear in the header
  // and the samples must come back exactly, including through the padded arm.
  ['sine-16b-in-24b', mk((i) => Math.round(32767 * Math.sin((i * 2 * Math.PI) / 37)) << 8)],
  ['sine-12b-in-24b', mk((i) => Math.round(2047 * Math.sin((i * 2 * Math.PI) / 37)) << 12)],
  ['noise-16b-in-24b', mk(() => Math.round((rnd() - 0.5) * 65534) << 8)],
  ['tiny-shifted', mk((i) => (i & 1 ? 1 : -1) << 22)],
  ['one-odd-sample', mk((i) => (i === 123 ? 12345 : Math.round(32767 * Math.sin(i / 5)) << 8))],
  // Deliberately reaches the VERBATIM escape with a NONZERO shift — the one
  // combination where storing `s` instead of the shifted samples decodes to
  // plausible garbage rather than erroring. It was written wrong first.
  ['verbatim-with-shift', mk((i) => (i & 1 ? 4194303 : -4194304) * 2)],
];

console.log('adversarial frames (1152 B raw):');
let sawVerbatimShift = false;
for (const [name, s] of cases) {
  const n = check(name, s);
  check(name, s, { pad: true });
  const order = out[0] >>> 5, sh = out[0] & 31;
  if (order === 7 && sh > 0) sawVerbatimShift = true;
  console.log(`  ${name.padEnd(22)} ${String(n).padStart(5)} B  order ${order} sh ${String(sh).padStart(2)}`);
}
// A case that silently stops exercising the path it was written for is worse
// than no case at all, so this asserts the combination was actually reached.
if (!sawVerbatimShift) {
  console.log('  FAIL: no case reached the verbatim escape with a nonzero shift.');
  console.log('  That combination is the codec\'s one silent-corruption path; a test');
  console.log('  suite that no longer covers it must fail, not quietly pass.');
  fail++;
}

// ── real audio ──────────────────────────────────────────────────────────────
function wav(path) {
  const b = readFileSync(path);
  let off = 12, ch = 1, data = null;
  while (off + 8 <= b.length) {
    const id = b.toString('ascii', off, off + 4), sz = b.readUInt32LE(off + 4);
    if (id === 'fmt ') ch = b.readUInt16LE(off + 10);
    if (id === 'data') data = b.subarray(off + 8, off + 8 + sz);
    off += 8 + sz + (sz & 1);
  }
  const n = Math.floor(data.length / 2 / ch), s = new Int32Array(n);
  for (let i = 0; i < n; i++) s[i] = data.readInt16LE(i * 2 * ch);
  return s;
}

const reals = [];
for (const f of ['fullband.wav', 'floor-fall.wav', 'probe.wav']) {
  try { reals.push([f, wav(`${HERE}/media/${f}`)]); } catch (e) { console.log(`  (skipped ${f}: ${e.code || e.message})`); }
}
try {
  const flac = execFileSync('find', [`${HERE}/media/LibriSpeech`, '-name', '*.flac']).toString().split('\n')[0];
  const raw = execFileSync('ffmpeg', ['-v', 'quiet', '-i', flac, '-ar', '48000', '-ac', '1', '-f', 's16le', '-'], { maxBuffer: 1 << 28 });
  const n = raw.length / 2, s = new Int32Array(n);
  for (let i = 0; i < n; i++) s[i] = raw.readInt16LE(i * 2);
  reals.push(['LibriSpeech', s]);
} catch { }

console.log('\nreal audio, every frame round-tripped and compared sample by sample:');
// `over` counts frames above 1152 B — the verbatim escape. Those cannot enter an
// RS group once the symbol is sized to the group (parity carries an 8 B header,
// so 1152 B of payload is the last size that still fits one 1160 B datagram).
// TWO arms per source, because the two differ by 384 B and the codec takes a
// different path through each:
//   dither  low 8 bits filled with noise — a genuine 24-bit noise floor, shift 0
//   src16   16-bit content in a 24-bit container, shift 8
// The old suite ran only the dithered arm, which meant every real-audio frame
// took shift 0 and the wasted-bits path was covered by synthetic cases alone.
let realFrames = 0, realOver = 0;
for (const [name, sig] of reals) {
  for (const arm of ['dither', 'src16']) {
    const nf = Math.min(3000, Math.floor(sig.length / N));
    let sum = 0, worst = 0, over = 0, shSum = 0, before = fail;
    const s = new Int32Array(N);
    for (let f = 0; f < nf; f++) {
      for (let i = 0; i < N; i++) {
        const v = sig[f * N + i] << 8;
        s[i] = arm === 'dither' ? v + ((rnd() * 256) | 0) : v;
      }
      const n = check(`${name}/${arm}#${f}`, s);
      shSum += out[0] & 31;
      sum += n; if (n > worst) worst = n; if (n > 1152) over++;
    }
    realFrames += nf; realOver += over;
    console.log(`  ${name.padEnd(14)} ${arm.padEnd(7)} ${nf} frames  mean ${(sum / nf).toFixed(0)} B  ratio ${(sum / nf / 1152).toFixed(3)}` +
      `  sh ${(shSum / nf).toFixed(1)}  worst ${worst} B  over-1152 ${over}  ${fail === before ? 'all bit-exact' : 'FAILURES'}`);
  }
}

if (!realFrames) {
  console.log('\nFAIL: no real-audio corpus was found. The synthetic cases alone cannot');
  console.log('fail this test in the ways that matter, so an empty corpus is a failure,');
  console.log(`not a pass. Expected fixtures under ${HERE}/media.`);
  process.exit(1);
}
console.log(`\nverbatim escape on real audio: ${realOver} / ${realFrames} frames (${(100 * realOver / realFrames).toFixed(3)}%)`);
console.log(`\n${frames} frames, ${fail} failures.`);
console.log(`overall ${(100 * (1 - totalOut / totalIn)).toFixed(1)}% smaller; hard bound ${MAXB} B never exceeded.`);

// ── The RS path: repaired frames arrive zero-padded, with no length field ─────
// This is the integration's real risk. The sender pads every compressed payload
// in a group to the GROUP'S symbol length — the longest frame in it — so a
// repaired frame comes back as symLen bytes of which only the first L are
// meaningful, and NOTHING on the wire says what L was. It works only because
// Rice decoding self-terminates after exactly 384 samples. If that ever stopped
// being true, audio would decode to plausible garbage rather than error.
//
// Sizing per group (rather than a fixed 1152) is what this asserts: the padding
// is now usually a handful of bytes instead of ~440, and one frame in the group
// gets NO padding at all — the exact-fit case, where a decoder that relied on
// having slack would run off the end.
{
  const K = 10;
  let padFail = 0, groupsRun = 0, exactFit = 0, symSum = 0, paySum = 0, excluded = 0;
  const sig = reals[reals.length - 1][1];
  const s = new Int32Array(N), got = new Int32Array(N);
  const nf = Math.min(1500, Math.floor(sig.length / N));
  const pay = [], lens = [], srcs = [];
  for (let f = 0; f < nf; f++) {
    for (let i = 0; i < N; i++) s[i] = (sig[f * N + i] << 8) + ((rnd() * 256) | 0);
    const n = packFrame(s, out);
    if (n > 1152) { excluded++; continue; } // verbatim: excluded from the group
    pay.push(out.slice(0, n)); lens.push(n); srcs.push(Int32Array.from(s));
    if (pay.length < K) continue;

    const symLen = Math.max(...lens);
    groupsRun++; symSum += symLen;
    for (let m = 0; m < K; m++) {
      paySum += lens[m];
      if (lens[m] === symLen) exactFit++;
      const sym = new Uint8Array(symLen);
      sym.set(pay[m]);
      got.fill(0);
      unpackFrame(sym, got);
      for (let i = 0; i < N; i++) if (got[i] !== srcs[m][i]) { padFail++; break; }
    }
    pay.length = 0; lens.length = 0; srcs.length = 0;
  }
  const waste = 100 * (1 - paySum / (symSum * K));
  console.log(`RS symbol path: ${groupsRun} groups x ${K}, ${padFail} mismatches, ${excluded} frames excluded (verbatim).`);
  console.log(`  mean symbol ${(symSum / groupsRun).toFixed(0)} B vs a fixed 1152 B; padding ${waste.toFixed(1)}% of the group, ${exactFit} exact-fit frames decoded with zero slack.`);
  if (padFail || !groupsRun || !exactFit) process.exitCode = 1;
}

process.exit(fail || process.exitCode ? 1 : 0);
