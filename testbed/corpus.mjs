/**
 * Corpus preparation: find real human breaths and clean speech in real recordings.
 *
 * The design's largest lever (§3.1 lever 1) claims that a pre-speech inhalation gives
 * ~200 ms of warning that a reply is coming, and that this survives the pipeline. To
 * test that honestly I need three things:
 *
 *   1. real speech, not synthesis      — synthesis has no breath and idealised prosody
 *   2. real breaths, not synthesis     — a synthesised hiss is much easier to detect
 *   3. exact ground-truth positions    — so "detected at 205 ms" can be scored
 *
 * (1) and (2) come from LibriSpeech (CC BY 4.0), read audiobook speech, where readers
 * audibly inhale between sentences. (3) comes from cutting the real breaths out and
 * splicing them back at positions I choose.
 *
 * ── Why the breath finder does not use the app's own detector ────────────────
 * Using `core/onset.js` to locate breaths and then testing whether `core/onset.js`
 * finds breaths would be circular — it would confirm the detector agrees with itself.
 * So the criteria below are deliberately independent: absolute dBFS windows, zero
 * crossing rate, spectral centroid, and a periodicity measure computed by plain
 * autocorrelation. If the app's detector later disagrees with these labels, that is
 * information rather than a bug in the fixture.
 */

import { execFileSync } from 'node:child_process';
import { readdirSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const MEDIA = join(HERE, 'media');
const LIBRI = join(MEDIA, 'LibriSpeech/dev-clean');
const OUT = join(MEDIA, 'clips');
const SR = 48000;

// ── Breath acceptance criteria, all independent of the app's detector ────────
// Chosen from the phonetics rather than from what the detector happens to like.
const BREATH_MIN_DBFS = -52; // quieter than this is room tone, not an inhale
const BREATH_MAX_DBFS = -26; // louder than this is speech
const BREATH_MIN_MS = 150;   // Włodarczak & Heldner: pre-turn inhalations run long
const BREATH_MAX_MS = 700;
const BREATH_MIN_ZCR = 0.10; // turbulent airflow is noisy → many zero crossings
const BREATH_MAX_PERIODICITY = 0.30; // and aperiodic, unlike a vowel
const SPEECH_DBFS = -22;     // frames at least this loud count as speech
const WIN = 480;             // 10 ms analysis frame
const F0_MIN = 70, F0_MAX = 400;

function decode(flac) {
  // f32le mono at 48k, straight from ffmpeg's stdout — no temp files.
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

/** Plain normalised autocorrelation peak in the pitch range — a voicing measure. */
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

/** Fraction of energy above 2 kHz — breath is broadband, vowels are not. */
function highRatio(x, at, n = 1024) {
  const end = Math.min(x.length, at + n);
  let lo = 0, hi = 0, prev = 0;
  // One-pole split at ~2 kHz is enough to separate turbulence from a vowel.
  const a = Math.exp((-2 * Math.PI * 2000) / SR);
  for (let i = at; i < end; i++) {
    prev = a * prev + (1 - a) * x[i];
    lo += prev * prev;
    const h = x[i] - prev;
    hi += h * h;
  }
  return hi / (lo + hi + 1e-12);
}

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
console.log(`scanning ${flacs.length} real recordings from ${new Set(flacs.map((f) => f.spk)).size} speakers\n`);

const breaths = [];
const utterances = [];
const limit = Number(process.env.LIMIT ?? flacs.length);

for (const f of flacs.slice(0, limit)) {
  let x;
  try {
    x = decode(f.path);
  } catch {
    continue;
  }
  const fr = frames(x);

  // Speech extent, for cutting a clean utterance.
  const loud = fr.filter((q) => q.dbfs > SPEECH_DBFS);
  if (loud.length > 40) {
    const s = loud[0].i, e = Math.min(x.length, loud[loud.length - 1].i + WIN);
    if (e - s > SR * 0.7) {
      utterances.push({ ...f, startSamp: s, endSamp: e, ms: ((e - s) / SR) * 1000 });
    }
  }

  // Breath candidates: runs of frames inside the quiet-but-not-silent band.
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
      const ms = ((run.to - run.from) / SR) * 1000;
      if (ms >= BREATH_MIN_MS && ms <= BREATH_MAX_MS) {
        const mid = run.from + Math.floor((run.to - run.from) / 2) - 512;
        const p = periodicity(x, Math.max(0, mid));
        const hr = highRatio(x, Math.max(0, mid));
        // Aperiodic and broadband → turbulent airflow, not phonation.
        if (p < BREATH_MAX_PERIODICITY && hr > 0.35) {
          breaths.push({
            src: f.name, spk: f.spk, path: f.path,
            startSamp: run.from, endSamp: run.to, ms: +ms.toFixed(1),
            peakDbfs: +run.peak.toFixed(1), zcr: +(run.zcr / run.n).toFixed(3),
            periodicity: +p.toFixed(3), highRatio: +hr.toFixed(3),
          });
        }
      }
      run = null;
    }
  }
}

// Prefer long, clearly aperiodic, clearly broadband breaths — the least ambiguous
// examples, so a detection failure downstream is unambiguous too.
breaths.sort((a, b) => b.ms * b.highRatio * (1 - b.periodicity) - a.ms * a.highRatio * (1 - a.periodicity));
utterances.sort((a, b) => b.ms - a.ms);

console.log(`found ${breaths.length} breath candidates, ${utterances.length} usable utterances\n`);
console.log('top 12 breaths (independent criteria — no app code involved):');
console.log('  src                    spk   ms    peak dBFS  zcr    periodicity  hi-band');
for (const b of breaths.slice(0, 12)) {
  console.log(
    `  ${b.src.padEnd(22)} ${b.spk.padEnd(5)} ${String(b.ms).padStart(5)}  ` +
      `${String(b.peakDbfs).padStart(8)}  ${b.zcr.toFixed(3)}  ${b.periodicity.toFixed(3).padStart(11)}  ${b.highRatio.toFixed(3)}`,
  );
}

mkdirSync(OUT, { recursive: true });
writeFileSync(join(MEDIA, 'corpus.json'), JSON.stringify({ sr: SR, breaths: breaths.slice(0, 60), utterances: utterances.slice(0, 80) }, null, 1));
console.log(`\nwrote media/corpus.json`);
