/**
 * breath-autopsy.mjs — what does the classifier actually sit on at 35 ms?
 *
 * For the failing breaths identified by classify-debug, print a 5 ms-hop trace
 * of rms / zcr / tilt / detector-style periodicity from 300 ms before the
 * detector's onset to 300 ms after the breath label end.
 * Read-only.
 */
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const MEDIA = join(HERE, 'media');
const SR = 48000, HOP = 240, DECIM = 6;

function decode(flac) {
  const buf = execFileSync('ffmpeg', ['-v', 'error', '-i', flac, '-ac', '1', '-ar', String(SR), '-f', 'f32le', '-'], { maxBuffer: 1 << 28 });
  return new Float32Array(buf.buffer, buf.byteOffset, buf.length / 4);
}

const labels = JSON.parse(readFileSync(join(MEDIA, 'labels-full.json'), 'utf8'));

// (file, breath start, detector onset rel) from classify-debug output
const CASES = [
  { name: '1272-128104-0004', breathStart: 10870, onsetRel: -215 },
  { name: '1673-143396-0005', breathStart: null, onsetRel: -70 }, // find from labels
];

const LAG_MIN = 20, LAG_MAX = 115, PITCH_WIN = 230;

function trace(x, t0ms, t1ms) {
  // decimate the whole region once
  const t0 = Math.max(0, Math.floor((t0ms / 1000) * SR));
  const t1 = Math.min(x.length, Math.ceil((t1ms / 1000) * SR));
  const rows = [];
  // high-pass state for tilt
  const rc = (2 * Math.PI * 2000) / SR;
  const hpA = 1 / (1 + rc);
  let hpPrevIn = 0, hpPrevOut = 0;
  // warm up hp filter on preceding 200ms
  for (let i = Math.max(0, t0 - 9600); i < t0; i++) {
    const hp = hpA * (hpPrevOut + x[i] - hpPrevIn);
    hpPrevOut = hp; hpPrevIn = x[i];
  }
  const dec = [];
  for (let i = Math.max(0, t0 - 9600); i < t1; i += DECIM) {
    let a = 0; for (let j = i; j < Math.min(i + DECIM, t1); j++) a += x[j];
    dec.push(a / DECIM);
  }
  const decOffset = Math.max(0, t0 - 9600) / DECIM;
  for (let i = t0; i + HOP <= t1; i += HOP) {
    let sumSq = 0, zc = 0, hpSumSq = 0, prev = x[i - 1] ?? 0;
    for (let j = i; j < i + HOP; j++) {
      const s = x[j];
      sumSq += s * s;
      if ((s >= 0) !== (prev >= 0)) zc++;
      prev = s;
      const hp = hpA * (hpPrevOut + s - hpPrevIn);
      hpPrevOut = hp; hpPrevIn = s;
      hpSumSq += hp * hp;
    }
    const rms = Math.sqrt(sumSq / HOP);
    const hpRms = Math.sqrt(hpSumSq / HOP);
    const tilt = 20 * Math.log10(Math.max(hpRms, 1e-10)) - 20 * Math.log10(Math.max(rms - hpRms, 1e-10));
    // detector periodicity over the most recent PITCH_WIN+LAG_MAX decimated samples
    const endD = Math.floor((i + HOP) / DECIM) - decOffset;
    const startD = endD - (PITCH_WIN + LAG_MAX);
    let per = 0;
    if (startD >= 0) {
      let e0 = 0;
      for (let k = 0; k < PITCH_WIN; k++) e0 += dec[startD + k] * dec[startD + k];
      if (e0 > 1e-10) {
        let best = 0;
        for (let lag = LAG_MIN; lag <= LAG_MAX; lag++) {
          let num = 0, eL = 0;
          for (let k = 0; k < PITCH_WIN; k++) {
            const b = dec[startD + k + lag];
            num += dec[startD + k] * b; eL += b * b;
          }
          if (eL < 1e-10) continue;
          const r = num / Math.sqrt(e0 * eL);
          if (r > best) best = r;
        }
        per = best;
      }
    }
    rows.push({ t: +((i / SR) * 1000).toFixed(0), db: +(20 * Math.log10(rms + 1e-12)).toFixed(1), zcr: +(zc / HOP).toFixed(3), tilt: +tilt.toFixed(1), per: +per.toFixed(3) });
  }
  return rows;
}

for (const c of CASES) {
  const f = labels.files.find((f2) => f2.name === c.name);
  const x = decode(f.path);
  const b = f.breaths.find((b2) => Math.abs(b2.startMs - (c.breathStart ?? 0)) < 1) ??
    f.breaths.filter((b2) => b2.quietBeforeMs >= 400 && b2.peakDbfs - (b2.floorBeforeDbfs ?? -999) >= 6)[0];
  const onsetMs = b.startMs + c.onsetRel;
  console.log(`\n═══ ${c.name}: breath ${b.startMs}–${b.endMs} (peak ${b.peakDbfs}), onset at ${onsetMs.toFixed(0)} ═══`);
  const rows = trace(x, onsetMs - 200, b.endMs + 500);
  for (const r of rows) {
    const mark = r.t < b.startMs ? ' ' : r.t <= b.endMs ? 'B' : '.';
    const cls = r.t >= onsetMs + 30 && r.t <= onsetMs + 40 ? '<== classifier sits here (35ms)' : '';
    console.log(`${mark} ${r.t}  ${r.db} dB  zcr ${r.zcr}  tilt ${r.tilt}  per ${r.per} ${cls}`);
  }
}
