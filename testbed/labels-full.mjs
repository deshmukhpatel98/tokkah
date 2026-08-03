/**
 * labels-full.mjs — complete per-file ground truth for the onset-detector
 * measurement-debt task.
 *
 * media/corpus.json keeps only the top 60 breaths / 80 utterances across the whole
 * corpus, which is unusable for false-alarm accounting: a detector onset at an
 * *unlabelled* real breath would be scored as a false alarm. So this rescans every
 * LibriSpeech file and writes EVERY breath candidate and EVERY speech segment it
 * finds, per file, using exactly the acceptance criteria in corpus.mjs — which are
 * deliberately independent of the app's detector (absolute dBFS windows, ZCR,
 * spectral tilt, plain autocorrelation periodicity). Same philosophy: if the app
 * disagrees with these labels, that is information, not a fixture bug.
 *
 * Additional context stored per breath so the scorer can decide *detectability*:
 * a breath that starts while the detector would still be inside the previous turn's
 * hang time cannot produce an onset, and must not be counted as a miss.
 *
 * Writes media/labels-full.json. Reads nothing but the flacs. Edits nothing.
 */

import { execFileSync } from 'node:child_process';
import { readdirSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const MEDIA = join(HERE, 'media');
const LIBRI = join(MEDIA, 'LibriSpeech/dev-clean');
const SR = 48000;

// ── Criteria identical to corpus.mjs (independent of the app's detector) ─────
const BREATH_MIN_DBFS = -52;
const BREATH_MAX_DBFS = -26;
const BREATH_MIN_MS = 150;
const BREATH_MAX_MS = 700;
const BREATH_MIN_ZCR = 0.10;
const BREATH_MAX_PERIODICITY = 0.30;
const SPEECH_DBFS = -22;
const WIN = 480; // 10 ms
const F0_MIN = 70, F0_MAX = 400;

// Speech segmentation (not in corpus.mjs — it only took whole-file extents).
// Bridge pauses shorter than this inside one segment; a scored utterance onset
// must be preceded by enough quiet that the detector is certainly idle.
const BRIDGE_MS = 250;
const MASK_MIN_MS = 100;   // anything this long counts as speech for FA masking
const SCORE_MIN_MS = 700;  // only substantial segments are scored for misses
const QUIET_BEFORE_MS = 700; // required preceding quiet for a scored speech onset
const BREATH_QUIET_BEFORE_MS = 600; // same, for a scored breath onset

function decode(flac) {
  const buf = execFileSync(
    'ffmpeg',
    ['-v', 'error', '-i', flac, '-ac', '1', '-ar', String(SR), '-f', 'f32le', '-'],
    { maxBuffer: 1 << 28 },
  );
  return new Float32Array(buf.buffer, buf.byteOffset, buf.length / 4);
}

function frames(x) {
  const out = [];
  for (let i = 0; i + WIN <= x.length; i += WIN) {
    let sumSq = 0, zc = 0, prev = x[i];
    for (let j = 0; j < WIN; j++) {
      const v = x[i + j];
      sumSq += v * v;
      if ((v >= 0) !== (prev >= 0)) zc++;
      prev = v;
    }
    const rms = Math.sqrt(sumSq / WIN);
    out.push({ i, dbfs: 20 * Math.log10(rms + 1e-12), zcr: zc / WIN, rms });
  }
  return out;
}

function periodicity(x, at, n = 1024) {
  const end = Math.min(x.length, at + n);
  const len = end - at;
  if (len < 400) return 0;
  let e0 = 0;
  for (let i = at; i < end; i++) e0 += x[i] * x[i];
  if (e0 < 1e-10) return 0;
  let best = 0;
  const lagMin = Math.floor(SR / F0_MAX), lagMax = Math.min(Math.floor(SR / F0_MIN), len - 1);
  for (let lag = lagMin; lag <= lagMax; lag++) {
    let num = 0, e1 = 0;
    for (let i = at; i < end - lag; i++) {
      num += x[i] * x[i + lag];
      e1 += x[i + lag] * x[i + lag];
    }
    const r = num / (Math.sqrt(e0 * e1) + 1e-12);
    if (r > best) best = r;
  }
  return best;
}

function highRatio(x, at, n = 1024) {
  const end = Math.min(x.length, at + n);
  let lo = 0, hi = 0, prev = 0;
  const a = Math.exp((-2 * Math.PI * 2000) / SR);
  for (let i = at; i < end; i++) {
    prev = a * prev + (1 - a) * x[i];
    lo += prev * prev;
    const h = x[i] - prev;
    hi += h * h;
  }
  return hi / (lo + hi + 1e-12);
}

const ms = (s) => (s / SR) * 1000;

// ── Scan ─────────────────────────────────────────────────────────────────────
const flacs = [];
for (const spk of readdirSync(LIBRI)) {
  const sd = join(LIBRI, spk);
  for (const ch of readdirSync(sd)) {
    for (const f of readdirSync(join(sd, ch))) {
      if (f.endsWith('.flac')) flacs.push({ spk, path: join(sd, ch, f), name: f.replace('.flac', '') });
    }
  }
}
flacs.sort((a, b) => a.name.localeCompare(b.name));
console.log(`scanning ${flacs.length} files`);

const files = [];
let nBreath = 0, nSeg = 0;
for (const f of flacs) {
  let x;
  try {
    x = decode(f.path);
  } catch {
    continue;
  }
  const fr = frames(x);

  // Speech segments: runs of frames above SPEECH_DBFS, bridging short pauses.
  const loudIdx = fr.map((q) => q.dbfs > SPEECH_DBFS);
  const bridgeFrames = Math.round(BRIDGE_MS / 10);
  const segs = [];
  let cur = null, gap = 0;
  for (let k = 0; k < fr.length; k++) {
    if (loudIdx[k]) {
      if (!cur) cur = { startSamp: fr[k].i, endSamp: fr[k].i + WIN };
      else cur.endSamp = fr[k].i + WIN;
      gap = 0;
    } else if (cur) {
      if (++gap > bridgeFrames) {
        segs.push(cur);
        cur = null;
        gap = 0;
      }
    }
  }
  if (cur) segs.push(cur);

  const speech = [];
  for (const s of segs) {
    const durMs = ms(s.endSamp - s.startSamp);
    if (durMs < MASK_MIN_MS) continue;
    // Peak dBFS over the segment's first 400 ms (for SNR bookkeeping).
    let peak = -Infinity;
    for (const q of fr) {
      if (q.i >= s.startSamp && q.i < s.startSamp + SR * 0.4 && q.dbfs > peak) peak = q.dbfs;
    }
    // Actual audio level in the 500 ms before this segment — "quiet" for the
    // detector means low LEVEL, not merely "no frame above -22 dBFS": real gaps
    // are full of exhales and mouth noise that keep a sensitive detector active.
    const before = fr.filter((q) => q.i >= s.startSamp - SR * 0.5 && q.i < s.startSamp).map((q) => q.dbfs).sort((a, b) => a - b);
    speech.push({
      startMs: +ms(s.startSamp).toFixed(1),
      endMs: +ms(s.endSamp).toFixed(1),
      ms: +durMs.toFixed(1),
      peakDbfs: +peak.toFixed(1),
      floorBeforeDbfs: before.length ? +before[Math.floor(before.length / 2)].toFixed(1) : null,
      scored: durMs >= SCORE_MIN_MS, // preceding-quiet filter applied at score time
    });
  }
  nSeg += speech.length;

  // File noise floor: median level of frames outside every speech segment.
  const inSpeech = (i) => segs.some((s) => i >= s.startSamp - SR * 0.3 && i <= s.endSamp + SR * 0.3);
  const quietFrames = fr.filter((q) => !inSpeech(q.i)).map((q) => q.dbfs).sort((a, b) => a - b);
  const fileFloorDbfs = quietFrames.length ? +quietFrames[Math.floor(quietFrames.length / 2)].toFixed(1) : null;

  // Breath candidates: corpus.mjs criteria, all kept.
  const breaths = [];
  let run = null;
  for (const q of fr) {
    const inBand = q.dbfs > BREATH_MIN_DBFS && q.dbfs < BREATH_MAX_DBFS && q.zcr > BREATH_MIN_ZCR;
    if (inBand) {
      if (!run) run = { from: q.i, to: q.i + WIN, peak: q.dbfs, zcr: q.zcr, n: 1 };
      else {
        run.to = q.i + WIN;
        run.peak = Math.max(run.peak, q.dbfs);
        run.zcr += q.zcr;
        run.n++;
      }
    } else if (run) {
      const durMs = ms(run.to - run.from);
      if (durMs >= BREATH_MIN_MS && durMs <= BREATH_MAX_MS) {
        const mid = run.from + Math.floor((run.to - run.from) / 2) - 512;
        const p = periodicity(x, Math.max(0, mid));
        const hr = highRatio(x, Math.max(0, mid));
        if (p < BREATH_MAX_PERIODICITY && hr > 0.35) {
          const startMs = ms(run.from), endMs = ms(run.to);
          // Context: quiet before, distance to surrounding speech.
          let prevEnd = 0, nextStart = Infinity;
          for (const s of speech) {
            if (s.endMs <= startMs && s.endMs > prevEnd) prevEnd = s.endMs;
            if (s.startMs >= endMs && s.startMs < nextStart) nextStart = s.startMs;
          }
          // Local floor: median frame dBFS in the 500 ms before the breath.
          const before = fr.filter((q) => q.i >= run.from - SR * 0.5 && q.i < run.from).map((q) => q.dbfs).sort((a, b) => a - b);
          breaths.push({
            startMs: +startMs.toFixed(1),
            endMs: +endMs.toFixed(1),
            ms: +durMs.toFixed(1),
            peakDbfs: +run.peak.toFixed(1),
            zcr: +(run.zcr / run.n).toFixed(3),
            periodicity: +p.toFixed(3),
            highRatio: +hr.toFixed(3),
            quietBeforeMs: +(startMs - prevEnd).toFixed(1),
            toNextSpeechMs: nextStart === Infinity ? null : +(nextStart - endMs).toFixed(1),
            floorBeforeDbfs: before.length ? +before[Math.floor(before.length / 2)].toFixed(1) : null,
          });
        }
      }
      run = null;
    }
  }
  nBreath += breaths.length;

  files.push({
    name: f.name, spk: f.spk, path: f.path,
    durMs: +ms(x.length).toFixed(1),
    fileFloorDbfs,
    speech, breaths,
  });
}

const out = {
  sr: SR,
  criteria: {
    BREATH_MIN_DBFS, BREATH_MAX_DBFS, BREATH_MIN_MS, BREATH_MAX_MS, BREATH_MIN_ZCR,
    BREATH_MAX_PERIODICITY, SPEECH_DBFS, BRIDGE_MS, MASK_MIN_MS, SCORE_MIN_MS,
    QUIET_BEFORE_MS, BREATH_QUIET_BEFORE_MS,
  },
  files,
};
writeFileSync(join(MEDIA, 'labels-full.json'), JSON.stringify(out));
console.log(`wrote media/labels-full.json: ${files.length} files, ${nSeg} speech segments, ${nBreath} breath candidates`);
const detectable = files.flatMap((f) => f.breaths).filter((b) => b.quietBeforeMs >= BREATH_QUIET_BEFORE_MS);
const scoredSpeech = files.flatMap((f) => f.speech).filter((s) => s.scored);
console.log(`  breaths with >= ${BREATH_QUIET_BEFORE_MS} ms quiet before: ${detectable.length}`);
console.log(`  speech segments >= ${SCORE_MIN_MS} ms: ${scoredSpeech.length}`);
