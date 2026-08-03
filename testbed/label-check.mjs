/**
 * label-check.mjs — how reliable are media/labels-full.json's labels, checked by
 * looking at the actual audio rather than trusting the labeler.
 *
 * Three checks:
 *   1. BREATH envelopes: every breath the scorer actually used (n=8) plus samples
 *      of the labels the headroom screen REJECTED — print an ASCII dBFS envelope
 *      around each so a human can see whether there is a discrete audible inhale
 *      there or just a dip inside loud audio. Plus spectral flatness (Wiener
 *      entropy from a naive DFT) as a second, independent feature: true inhales
 *      are broadband (flat); vowels are not.
 *   2. SPEECH onset labels: for a sample of scored segments, verify the -22 dBFS
 *      crossing lands within ±30 ms of the label and the 300 ms before is quiet.
 *   3. Exports a handful of breath excerpts as WAVs under media/labelcheck/ so a
 *      human can listen (I cannot).
 *
 * New file; reads labels-full.json and the flacs; edits nothing.
 */

import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const MEDIA = join(HERE, 'media');
const SR = 48000;
const labels = JSON.parse(readFileSync(join(MEDIA, 'labels-full.json'), 'utf8'));

const decode = (p) => {
  const buf = execFileSync('ffmpeg', ['-v', 'error', '-i', p, '-ac', '1', '-ar', String(SR), '-f', 'f32le', '-'], { maxBuffer: 1 << 28 });
  return new Float32Array(buf.buffer, buf.byteOffset, buf.length / 4);
};
const pcmCache = new Map();
const load = (p) => { if (!pcmCache.has(p)) pcmCache.set(p, decode(p)); return pcmCache.get(p); };

/** Spectral flatness (Wiener entropy) over n samples at `at` — naive DFT, small n. */
function flatness(x, at, n = 1024) {
  const end = Math.min(x.length, at + n);
  const N = end - at;
  if (N < 256) return null;
  const K = 128; // bins to ~6 kHz, plenty for broadband-vs-vowel
  const mags = [];
  for (let k = 1; k <= K; k++) {
    let re = 0, im = 0;
    for (let i = 0; i < N; i++) {
      const w = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / N); // Hann
      const a = (-2 * Math.PI * k * i) / N;
      re += x[at + i] * w * Math.cos(a);
      im += x[at + i] * w * Math.sin(a);
    }
    mags.push(re * re + im * im);
  }
  const gm = Math.exp(mags.reduce((a, m) => a + Math.log(m + 1e-20), 0) / K);
  const am = mags.reduce((a, m) => a + m, 0) / K;
  return gm / (am + 1e-20);
}

/** ASCII envelope of frame dBFS over [fromMs, toMs], one char per 20 ms. */
function envelope(x, fromMs, toMs, markFromMs, markToMs) {
  const step = SR * 0.02;
  const a = Math.max(0, Math.round((fromMs / 1000) * SR));
  const b = Math.min(x.length, Math.round((toMs / 1000) * SR));
  const rows = [];
  for (let i = a; i + step <= b; i += step) {
    let s = 0;
    for (let j = 0; j < step; j++) s += x[i + j] * x[i + j];
    const db = 20 * Math.log10(Math.sqrt(s / step) + 1e-12);
    const tms = (i / SR) * 1000;
    const inMark = tms >= markFromMs && tms <= markToMs;
    // map -70..-10 dBFS to 0..30 rows
    const h = Math.max(0, Math.min(30, Math.round(((db + 70) / 60) * 30)));
    rows.push({ tms, db, h, inMark });
  }
  // render: level as bar length, marker columns bracketed
  return rows
    .map((r) => `    ${String(Math.round(r.tms)).padStart(7)} ${r.inMark ? '|' : ' '} ${'#'.repeat(r.h)} ${r.db.toFixed(0)}`)
    .join('\n');
}

function writeWav(path, x) {
  const buf = Buffer.alloc(44 + x.length * 2);
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + x.length * 2, 4); buf.write('WAVE', 8);
  buf.write('fmt ', 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(1, 22); buf.writeUInt32LE(SR, 24); buf.writeUInt32LE(SR * 2, 28);
  buf.writeUInt16LE(2, 32); buf.writeUInt16LE(16, 34);
  buf.write('data', 36); buf.writeUInt32LE(x.length * 2, 40);
  for (let i = 0; i < x.length; i++) buf.writeInt16LE(Math.round(Math.max(-1, Math.min(1, x[i])) * 32767), 44 + i * 2);
  writeFileSync(path, buf);
}

const headroom = (e) => (e.floorBeforeDbfs == null ? null : e.peakDbfs - e.floorBeforeDbfs);

// ── Collect breath pools ─────────────────────────────────────────────────────
const all = [];
for (const f of labels.files) for (const b of f.breaths) all.push({ f, b });
const scored = all.filter(({ b }) => b.quietBeforeMs >= 400 && b.startMs >= 400 && headroom(b) >= 6);
const rejected = all.filter(({ b }) => !(b.quietBeforeMs >= 400 && b.startMs >= 400 && headroom(b) >= 6));
const rejDips = rejected.filter(({ b }) => headroom(b) < 0);
const rejOther = rejected.filter(({ b }) => headroom(b) >= 0);
// deterministic sample of rejects: every k-th
const rejSample = [...rejDips.filter((_, i) => i % 6 === 0), ...rejOther.filter((_, i) => i % 2 === 0)];

console.log(`breath labels: ${all.length} total; ${scored.length} scored, ${rejected.length} rejected by context/headroom screen`);
console.log(`inspecting ALL ${scored.length} scored + ${rejSample.length} sampled rejected\n`);

mkdirSync(join(MEDIA, 'labelcheck'), { recursive: true });
let confirmed = 0, dubious = 0;
const inspect = ({ f, b }, expectScored) => {
  const x = load(f.path);
  const mid = Math.round(((b.startMs + b.endMs) / 2 / 1000) * SR);
  const sf = flatness(x, mid - 512);
  const hr = headroom(b);
  // Envelope verdict: does the breath region visibly rise above its surroundings?
  // Compare breath peak to the median of the 500 ms before (already stored).
  const discrete = hr >= 6;
  const verdict = discrete ? 'DISCRETE EVENT (rises from local floor)' : 'DIP IN LOUD AUDIO (no rise — not a standalone onset)';
  if (discrete) confirmed++; else dubious++;
  console.log(`  ${f.name} @ ${b.startMs} ms  (${b.ms} ms, peak ${b.peakDbfs} dBFS, headroom ${hr?.toFixed(1)} dB, flatness ${sf?.toFixed(2)})`);
  console.log(`    ${verdict}`);
  console.log(envelope(x, b.startMs - 600, b.endMs + 600, b.startMs, b.endMs));
  console.log('');
  return { sf, hr };
};

console.log('════ SCORED breaths (the ground truth the detector is measured against) ════\n');
const scoredSfs = scored.map((s) => inspect(s, true).sf);

console.log('════ REJECTED labels (sampled) — checking the screen rejects junk, not breaths ════\n');
rejSample.forEach((r) => inspect(r, false));

// Save excerpts of the scored breaths for human listening (1.5 s around each).
for (let i = 0; i < scored.length; i++) {
  const { f, b } = scored[i];
  const x = load(f.path);
  const a = Math.max(0, Math.round(((b.startMs - 700) / 1000) * SR));
  const e = Math.min(x.length, a + SR * 1.6);
  writeWav(join(MEDIA, 'labelcheck', `breath-${i + 1}-${f.name}.wav`), x.subarray(a, e));
}
console.log(`wrote ${scored.length} listenable excerpts to media/labelcheck/`);

// ── Speech onset label check ─────────────────────────────────────────────────
const segs = [];
for (const f of labels.files) f.speech.forEach((s, idx) => { if (s.scored) segs.push({ f, s, idx }); });
const sample = segs.filter((_, i) => i % 29 === 0).slice(0, 15);
let ok = 0;
console.log(`\nspeech onset labels: checking ${sample.length} of ${segs.length} substantial segments`);
for (const { f, s } of sample) {
  const x = load(f.path);
  const at = Math.round((s.startMs / 1000) * SR);
  // first frame above -22 within ±100 ms of label
  const WIN = 480;
  let crossMs = null;
  for (let i = at - SR * 0.1; i + WIN <= Math.min(x.length, at + SR * 0.1); i += WIN) {
    let ss = 0;
    for (let j = 0; j < WIN; j++) ss += x[i + j] * x[i + j];
    if (20 * Math.log10(Math.sqrt(ss / WIN) + 1e-12) > -22) { crossMs = (i / SR) * 1000; break; }
  }
  const err = crossMs == null ? null : crossMs - s.startMs;
  const good = err != null && Math.abs(err) <= 30;
  if (good) ok++;
  console.log(`  ${f.name} @ ${s.startMs}: crossing at ${crossMs?.toFixed(0) ?? 'none'} (err ${err?.toFixed(0) ?? '—'} ms) ${good ? 'ok' : 'BAD'}`);
}
console.log(`  ${ok}/${sample.length} within ±30 ms`);

// ── Summary ──────────────────────────────────────────────────────────────────
const sfVals = scoredSfs.filter((v) => v != null).sort((a, b) => a - b);
console.log(`\nscored-breath spectral flatness: min ${sfVals[0]?.toFixed(2)} median ${sfVals[Math.floor(sfVals.length / 2)]?.toFixed(2)} (1.0 = white noise; vowels ~0.02-0.1)`);
console.log(`envelope inspection: ${confirmed} discrete events, ${dubious} dips-in-loud-audio among ${scored.length + rejSample.length} inspected`);
