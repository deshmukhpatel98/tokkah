/**
 * speech-kinds.mjs — do real SPEECH onsets ever end up classified 'breath'?
 *
 * corpus-score.mjs tracks matched kinds only for breath trials. The detector's
 * second look (reclassify voice→breath at RECLASSIFY_MS) could in principle flip
 * a real speech onset — fricative-heavy openings can look aperiodic — which would
 * delay that turn's head-start event until `voiced` fires. This harness mirrors
 * corpus-score's speech matching exactly (same levels, same noise, same windows,
 * same nearest-onset rule) and tallies the FINAL kind of every speech-matched
 * onset. Run with the same env knobs as corpus-sweep.mjs.
 *
 *   node speech-kinds.mjs                  # detector defaults
 *   TURN_DROP_DB=20 node speech-kinds.mjs  # candidate config
 */
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const { OnsetDetector, SAMPLE_RATE } = await import(process.env.ONSET_PATH ?? '../tape-app/public/core/onset.js');

const HERE = dirname(fileURLToPath(import.meta.url));
const MEDIA = join(HERE, 'media');
const SR = SAMPLE_RATE;

const LEVELS = [null, -55, -50, -45, -40, -35, -30];
const CAL_GUARD_MS = 400;
const SPEECH_DET_WIN = [-700, 500];
const HEADROOM_MIN_DB = 6;

const DET_OPTS = {};
if (process.env.TURN_DROP_DB) DET_OPTS.turnDropDb = +process.env.TURN_DROP_DB;
if (process.env.RECLASSIFY_MS) DET_OPTS.reclassifyMs = +process.env.RECLASSIFY_MS;
if (process.env.AWAIT_HANG_MS) DET_OPTS.awaitVoiceHangMs = +process.env.AWAIT_HANG_MS;
console.log('detector opts:', JSON.stringify(DET_OPTS));

const labels = JSON.parse(readFileSync(join(MEDIA, 'labels-full.json'), 'utf8'));

function decode(flac) {
  const buf = execFileSync('ffmpeg', ['-v', 'error', '-i', flac, '-ac', '1', '-ar', String(SR), '-f', 'f32le', '-'], { maxBuffer: 1 << 28 });
  return new Float32Array(buf.buffer, buf.byteOffset, buf.length / 4);
}
const noiseBuf = (() => {
  const buf = execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'anoisesrc=color=pink:amplitude=1:sample_rate=48000:duration=70:seed=42', '-ac', '1', '-f', 'f32le', '-'], { maxBuffer: 1 << 28 });
  return new Float32Array(buf.buffer, buf.byteOffset, buf.length / 4);
})();
let noiseRms = 0;
for (let i = 0; i < noiseBuf.length; i++) noiseRms += noiseBuf[i] * noiseBuf[i];
noiseRms = Math.sqrt(noiseRms / noiseBuf.length);

function runDetector(x) {
  const det = new OnsetDetector(DET_OPTS);
  const events = det.push(x);
  const onsets = [];
  const byAt = new Map();
  for (const e of events) {
    if (e.type === 'onset') {
      const rec = { atMs: (e.at / SR) * 1000, kind: null, revised: false, leadMs: null };
      onsets.push(rec);
      byAt.set(e.at, rec);
    } else if (e.type === 'classified') {
      const rec = byAt.get(e.onsetAt);
      if (rec) { rec.kind = e.kind; if (e.revised) rec.revised = true; }
    } else if (e.type === 'voiced') {
      const rec = byAt.get(e.onsetAt);
      if (rec) rec.leadMs = e.leadMs;
    }
  }
  return onsets;
}

const headroom = (ev) => ev.floorBeforeDbfs != null && ev.peakDbfs - ev.floorBeforeDbfs >= HEADROOM_MIN_DB;

// Split by timing error like corpus-score does: err < -250 ms means the nearest
// onset is the preceding breath (breath-caught — the head-start mechanism);
// err >= -250 ms is the speech segment's own onset, and THAT is where a
// breath label would be a misclassification.
const SPEECH_TIMING_WIN = 250;
const perLevel = LEVELS.map(() => ({
  own: { matched: 0, kinds: {}, revised: 0, voicedAfterBreath: 0 },
  caught: { matched: 0, kinds: {}, revised: 0, voicedAfterBreath: 0 },
}));

for (let fi = 0; fi < labels.files.length; fi++) {
  const f = labels.files[fi];
  const scoredSpeech = f.speech.filter((s, idx) => {
    if (!s.scored || s.startMs < CAL_GUARD_MS) return false;
    const prevEnd = idx > 0 ? f.speech[idx - 1].endMs : 0;
    return s.startMs - prevEnd >= labels.criteria.QUIET_BEFORE_MS && headroom(s);
  });
  if (!scoredSpeech.length) continue;
  const clean = decode(f.path);
  for (let li = 0; li < LEVELS.length; li++) {
    const level = LEVELS[li];
    const gain = level === null ? 0 : 10 ** (level / 20) / noiseRms;
    let x = clean;
    if (gain > 0) {
      x = new Float32Array(clean.length);
      const off = (fi * 7919 + li * 104729) % Math.max(1, noiseBuf.length - clean.length - 1);
      for (let i = 0; i < clean.length; i++) x[i] = clean[i] + noiseBuf[off + i] * gain;
    }
    const onsets = runDetector(x);
    const R = perLevel[li];
    for (const s of scoredSpeech) {
      const cand = onsets.filter((o) => o.atMs >= s.startMs + SPEECH_DET_WIN[0] && o.atMs <= s.startMs + SPEECH_DET_WIN[1]);
      if (!cand.length) continue;
      const nearest = cand.reduce((a, b) => (Math.abs(b.atMs - s.startMs) < Math.abs(a.atMs - s.startMs) ? b : a));
      const err = nearest.atMs - s.startMs;
      const T = err < -SPEECH_TIMING_WIN ? R.caught : R.own;
      T.matched++;
      const k = nearest.kind ?? 'unclassified';
      T.kinds[k] = (T.kinds[k] ?? 0) + 1;
      if (nearest.revised) T.revised++;
      if (k === 'breath' && nearest.leadMs != null) T.voicedAfterBreath++;
    }
  }
  if (fi % 25 === 0) console.log(`  ${fi}/${labels.files.length}`);
}

console.log('\nfinal kind of speech-matched onsets, split by timing error:');
perLevel.forEach((R, i) => {
  const fmt = (T) =>
    `n=${String(T.matched).padStart(3)} ${JSON.stringify(T.kinds).padEnd(50)} revised→breath ${T.revised}, voiced-after-breath ${T.voicedAfterBreath}`;
  console.log(String(LEVELS[i] ?? 'clean').padEnd(9), 'OWN-ONSET  ', fmt(R.own));
  console.log(''.padEnd(9), 'BREATH-CAUGHT', fmt(R.caught));
});
