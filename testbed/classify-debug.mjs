/**
 * classify-debug.mjs — why do real breaths classify as 'voice'?
 *
 * Runs the shipping detector over the corpus at selected noise levels, and for
 * every scored breath with a matched onset, dumps the classifier's own features
 * at classification time (zcr, tilt, periodicity) plus the context the fixture
 * doesn't have: the detector's turn peak, the level of the audio preceding the
 * onset, and how much pre-onset audio sits inside the periodicity window.
 *
 * Also dumps the same features for a sample of matched speech onsets, so the
 * separation (or lack of it) is measured on the same footing.
 *
 * Read-only: writes nothing but stdout.
 */

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { OnsetDetector, SAMPLE_RATE } from '../tape-app/public/core/onset.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const MEDIA = join(HERE, 'media');
const SR = SAMPLE_RATE;
const LEVELS = [null, -45, -30];
const CAL_GUARD_MS = 400;
const HEADROOM_MIN_DB = 6;
const BREATH_DET_WIN = [-250, 200];
const SPEECH_DET_WIN = [-700, 500];

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

// Instrumented detector: capture internals at classification time.
function runDebug(x) {
  const det = new OnsetDetector();
  const clsInfo = [];
  const origClassify = det._classify.bind(det);
  det._classify = (at) => {
    const ev = origClassify(at);
    clsInfo.push({
      onsetAt: ev.onsetAt, at: ev.at, kind: ev.kind, zcr: ev.zcr, tiltDb: ev.tiltDb, periodicity: ev.periodicity,
      floorDb: det.floorDb, peakSnr: det.feat ? det.feat.peak : null, hops: det.feat ? det.feat.hops : null,
    });
    return ev;
  };
  const events = det.push(x);
  const onsets = [];
  for (const e of events) if (e.type === 'onset') onsets.push({ at: e.at, atMs: (e.at / SR) * 1000, snrDb: e.snrDb, floorDb: e.floorDb });
  for (const c of clsInfo) {
    const o = onsets.find((o2) => o2.at === c.onsetAt);
    if (o) { o.kind = c.kind; o.zcr = c.zcr; o.tiltDb = c.tiltDb; o.periodicity = c.periodicity; o.peakSnr = c.peakSnr; o.clsHops = c.hops; }
  }
  return onsets;
}

// Pre-onset audio level: median 10ms-frame dBFS in the 300 ms before the onset.
function preLevel(x, atSamp) {
  const WIN = 480;
  const vals = [];
  for (let i = Math.max(0, atSamp - 0.3 * SR); i + WIN <= atSamp; i += WIN) {
    let s = 0;
    for (let j = 0; j < WIN; j++) s += x[i + j] * x[i + j];
    vals.push(20 * Math.log10(Math.sqrt(s / WIN) + 1e-12));
  }
  vals.sort((a, b) => a - b);
  return vals.length ? vals[Math.floor(vals.length / 2)] : null;
}

const headroom = (ev) => ev.floorBeforeDbfs != null && ev.peakDbfs - ev.floorBeforeDbfs >= HEADROOM_MIN_DB;

for (let li = 0; li < LEVELS.length; li++) {
  const level = LEVELS[li];
  const gain = level === null ? 0 : 10 ** (level / 20) / noiseRms;
  console.log(`\n════════ level ${level === null ? 'clean' : level + ' dBFS'} ════════`);
  const rows = [];
  for (let fi = 0; fi < labels.files.length; fi++) {
    const f = labels.files[fi];
    const clean = decode(f.path);
    let x = clean;
    if (gain > 0) {
      x = new Float32Array(clean.length);
      const off = (fi * 7919 + li * 104729) % Math.max(1, noiseBuf.length - clean.length - 1);
      for (let i = 0; i < clean.length; i++) x[i] = clean[i] + noiseBuf[off + i] * gain;
    }
    const scoredBreaths = f.breaths.filter((b) => b.quietBeforeMs >= 400 && b.startMs >= CAL_GUARD_MS && headroom(b));
    const scoredSpeech = f.speech.filter((s, idx) => {
      if (!s.scored || s.startMs < CAL_GUARD_MS) return false;
      const prevEnd = idx > 0 ? f.speech[idx - 1].endMs : 0;
      return s.startMs - prevEnd >= labels.criteria.QUIET_BEFORE_MS && headroom(s);
    });
    if (!scoredBreaths.length && !scoredSpeech.length) continue;
    const onsets = runDebug(x);
    for (const b of scoredBreaths) {
      const cand = onsets.filter((o) => o.atMs >= b.startMs + BREATH_DET_WIN[0] && o.atMs <= b.endMs + BREATH_DET_WIN[1]);
      if (!cand.length) continue;
      const o = cand.reduce((a, b2) => (Math.abs(b2.atMs - b.startMs) < Math.abs(a.atMs - b.startMs) ? b2 : a));
      rows.push({
        type: 'BREATH', file: f.name, relMs: +(o.atMs - b.startMs).toFixed(0),
        kind: o.kind ?? 'uncls', zcr: o.zcr?.toFixed(3), tilt: o.tiltDb?.toFixed(1), per: o.periodicity?.toFixed(3),
        onsetSnr: o.snrDb?.toFixed(1), floor: o.floorDb?.toFixed(1),
        preDb: preLevel(x, o.at)?.toFixed(1), peakDb: b.peakDbfs,
      });
    }
    for (const s of scoredSpeech) {
      const cand = onsets.filter((o) => o.atMs >= s.startMs + SPEECH_DET_WIN[0] && o.atMs <= s.startMs + SPEECH_DET_WIN[1]);
      if (!cand.length) continue;
      const o = cand.reduce((a, b2) => (Math.abs(b2.atMs - s.startMs) < Math.abs(a.atMs - s.startMs) ? b2 : a));
      rows.push({
        type: 'speech', file: f.name, relMs: +(o.atMs - s.startMs).toFixed(0),
        kind: o.kind ?? 'uncls', zcr: o.zcr?.toFixed(3), tilt: o.tiltDb?.toFixed(1), per: o.periodicity?.toFixed(3),
        onsetSnr: o.snrDb?.toFixed(1), floor: o.floorDb?.toFixed(1),
        preDb: preLevel(x, o.at)?.toFixed(1), peakDb: s.peakDbfs,
      });
    }
  }
  for (const r of rows) console.log(JSON.stringify(r));
}
