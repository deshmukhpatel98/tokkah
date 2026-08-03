/**
 * classify-trace.mjs — how do a turn's classification features evolve after onset?
 *
 * The 35 ms classification was tuned on fixture breaths (pure room tone before
 * them). Real breaths follow voiced exhales / speech tails, so at 35 ms the
 * window is full of periodic audio and the classifier says 'voice'. This script
 * measures the features at several delays after onset, for breath-matched and
 * speech-matched onsets, to find where (and whether) the breath signature
 * separates from speech.
 *
 * Per matched onset, at each checkpoint ms after onset:
 *   per  = periodicity now (last ~43 ms of audio)
 *   zcrW/tiltW = zcr / tilt over the hops SINCE the previous checkpoint
 *   snr  = snrDb now
 *
 * Read-only.
 */

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { OnsetDetector, SAMPLE_RATE } from '../tape-app/public/core/onset.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const MEDIA = join(HERE, 'media');
const SR = SAMPLE_RATE;
const LEVELS = [null, -30];
const CAL_GUARD_MS = 400;
const HEADROOM_MIN_DB = 6;
const BREATH_DET_WIN = [-250, 200];
const SPEECH_DET_WIN = [-700, 500];
const CHECKPOINTS_MS = [35, 70, 105, 140, 175, 210, 245, 280];

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

function runTrace(x) {
  const det = new OnsetDetector();
  const hopsPerMs = SR / 1000 / det.hop;
  const traces = new Map(); // onsetAt -> { snaps: [] }
  let cur = null;
  const origHop = det._hop.bind(det);
  det._hop = (events) => {
    const before = events.length;
    origHop(events);
    // Recompute this hop's rms from the accumulator (still intact after _hop).
    let s = 0;
    for (let j = 0; j < det.hop; j++) s += det.acc[j] * det.acc[j];
    const rmsDb = 20 * Math.log10(Math.sqrt(s / det.hop) + 1e-12);
    const snrDb = det.floorDb === null ? 0 : rmsDb - det.floorDb;
    for (let k = before; k < events.length; k++) {
      if (events[k].type === 'onset') {
        cur = { onsetAt: events[k].at, snaps: [], zcrAcc: 0, tiltAcc: 0, nAcc: 0, snrs: [] };
        traces.set(events[k].at, cur);
      }
    }
    if (det.state === 'active' && cur && det.onsetAt === cur.onsetAt) {
      cur.zcrAcc += det.feat.zcr - (cur.lastZcr ?? 0);
      cur.tiltAcc += det.feat.tilt - (cur.lastTilt ?? 0);
      cur.nAcc++;
      cur.lastZcr = det.feat.zcr;
      cur.lastTilt = det.feat.tilt;
      cur.snrs.push(snrDb);
      const msInto = (det.activeHops / hopsPerMs);
      const nextCp = CHECKPOINTS_MS[cur.snaps.length];
      if (nextCp !== undefined && msInto >= nextCp) {
        const sorted = [...cur.snrs].sort((a, b) => a - b);
        cur.snaps.push({
          ms: nextCp,
          per: +det._periodicity().toFixed(3),
          zcrW: +(cur.zcrAcc / cur.nAcc).toFixed(3),
          tiltW: +(cur.tiltAcc / cur.nAcc).toFixed(1),
          snrMed: +sorted[Math.floor(sorted.length / 2)].toFixed(1),
          peakSnr: +det.feat.peak.toFixed(1),
        });
        cur.zcrAcc = 0; cur.tiltAcc = 0; cur.nAcc = 0; cur.snrs = [];
      }
    } else if (det.state === 'idle') {
      cur = null;
    }
  };
  const events = det.push(x);
  const onsets = [];
  for (const e of events) if (e.type === 'onset') onsets.push({ at: e.at, atMs: (e.at / SR) * 1000, snrDb: e.snrDb, floorDb: e.floorDb });
  for (const o of onsets) {
    const t = traces.get(o.at);
    if (t) o.snaps = t.snaps;
  }
  return onsets;
}

const headroom = (ev) => ev.floorBeforeDbfs != null && ev.peakDbfs - ev.floorBeforeDbfs >= HEADROOM_MIN_DB;

for (let li = 0; li < LEVELS.length; li++) {
  const level = LEVELS[li];
  const gain = level === null ? 0 : 10 ** (level / 20) / noiseRms;
  for (let fi = 0; fi < labels.files.length; fi++) {
    const f = labels.files[fi];
    const scoredBreaths = f.breaths.filter((b) => b.quietBeforeMs >= 400 && b.startMs >= CAL_GUARD_MS && headroom(b));
    const scoredSpeech = f.speech.filter((s, idx) => {
      if (!s.scored || s.startMs < CAL_GUARD_MS) return false;
      const prevEnd = idx > 0 ? f.speech[idx - 1].endMs : 0;
      return s.startMs - prevEnd >= labels.criteria.QUIET_BEFORE_MS && headroom(s);
    });
    if (!scoredBreaths.length && !scoredSpeech.length) continue;
    const clean = decode(f.path);
    let x = clean;
    if (gain > 0) {
      x = new Float32Array(clean.length);
      const off = (fi * 7919 + li * 104729) % Math.max(1, noiseBuf.length - clean.length - 1);
      for (let i = 0; i < clean.length; i++) x[i] = clean[i] + noiseBuf[off + i] * gain;
    }
    const onsets = runTrace(x);
    for (const b of scoredBreaths) {
      const cand = onsets.filter((o) => o.atMs >= b.startMs + BREATH_DET_WIN[0] && o.atMs <= b.endMs + BREATH_DET_WIN[1] && o.snaps?.length >= 4);
      for (const o of cand) {
        console.log(JSON.stringify({ lvl: level ?? 'clean', type: 'BREATH', file: f.name, relMs: +(o.atMs - b.startMs).toFixed(0), snaps: o.snaps }));
        break; // nearest-enough; one row per breath
      }
    }
    for (const s of scoredSpeech) {
      const cand = onsets.filter((o) => o.atMs >= s.startMs + SPEECH_DET_WIN[0] && o.atMs <= s.startMs + SPEECH_DET_WIN[1] && o.snaps?.length >= 4);
      if (cand.length) {
        const o = cand[0];
        console.log(JSON.stringify({ lvl: level ?? 'clean', type: 'speech', file: f.name, relMs: +(o.atMs - s.startMs).toFixed(0), snaps: o.snaps }));
      }
    }
  }
}
