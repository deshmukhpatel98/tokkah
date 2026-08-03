/**
 * gap-levels.mjs — where does an absolute end-gate have to sit?
 *
 * For every scored speech segment (same filter as corpus-score), measure:
 *   - the segment's own peak dBFS (first 400 ms) and p10 of its loud frames
 *   - the max / p95 5 ms-hop dBFS in the gap AFTER the segment
 *     (segment end + 50 ms .. next segment start - 50 ms)
 * The end-gate must sit above the gap-residual distribution and below what
 * sustained speech looks like. Clean level only (the quiet wall lives there).
 * Read-only.
 */
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const MEDIA = join(HERE, 'media');
const SR = 48000, HOP = 240;
const CAL_GUARD_MS = 400;
const HEADROOM_MIN_DB = 6;

const labels = JSON.parse(readFileSync(join(MEDIA, 'labels-full.json'), 'utf8'));
function decode(flac) {
  const buf = execFileSync('ffmpeg', ['-v', 'error', '-i', flac, '-ac', '1', '-ar', String(SR), '-f', 'f32le', '-'], { maxBuffer: 1 << 28 });
  return new Float32Array(buf.buffer, buf.byteOffset, buf.length / 4);
}
const headroom = (ev) => ev.floorBeforeDbfs != null && ev.peakDbfs - ev.floorBeforeDbfs >= HEADROOM_MIN_DB;

function hopDb(x, i) {
  let s = 0;
  for (let j = i; j < i + HOP && j < x.length; j++) s += x[j] * x[j];
  return 20 * Math.log10(Math.sqrt(s / HOP) + 1e-12);
}

const gapMax = [], gapP95 = [], segPeak = [], segSustain = [];
for (const f of labels.files) {
  const scoredSpeech = f.speech.filter((s, idx) => {
    if (!s.scored || s.startMs < CAL_GUARD_MS) return false;
    const prevEnd = idx > 0 ? f.speech[idx - 1].endMs : 0;
    return s.startMs - prevEnd >= labels.criteria.QUIET_BEFORE_MS && headroom(s);
  });
  if (!scoredSpeech.length) continue;
  const x = decode(f.path);
  for (let i = 0; i < scoredSpeech.length; i++) {
    const s = scoredSpeech[i];
    segPeak.push(s.peakDbfs);
    // sustained: p10 of hop dBFS over the segment's first 700 ms
    const segHops = [];
    for (let t = s.startMs; t < Math.min(s.endMs, s.startMs + 700); t += 5) segHops.push(hopDb(x, Math.floor((t / 1000) * SR)));
    segHops.sort((a, b) => a - b);
    segSustain.push(segHops[Math.floor(segHops.length * 0.1)]);
    // gap residual after this segment (to next scored or any next segment)
    const next = f.speech.find((s2) => s2.startMs > s.startMs);
    if (!next) continue;
    const g0 = s.endMs + 50, g1 = next.startMs - 50;
    if (g1 - g0 < 300) continue;
    const hops = [];
    for (let t = g0; t < g1; t += 5) hops.push(hopDb(x, Math.floor((t / 1000) * SR)));
    hops.sort((a, b) => a - b);
    gapP95.push(hops[Math.floor(hops.length * 0.95)]);
    gapMax.push(hops[hops.length - 1]);
  }
}
const stat = (a, name) => {
  a.sort((x, y) => x - y);
  const q = (p) => a[Math.floor((p / 100) * a.length)];
  console.log(`${name}: n=${a.length} p10 ${q(10)?.toFixed(1)} p50 ${q(50)?.toFixed(1)} p90 ${q(90)?.toFixed(1)} p99 ${q(99)?.toFixed(1)} max ${a[a.length - 1]?.toFixed(1)}`);
};
stat(gapMax, 'gap residual MAX hop dBFS   ');
stat(gapP95, 'gap residual p95 hop dBFS   ');
stat(segPeak, 'segment peak dBFS           ');
stat(segSustain, 'segment p10 (sustain) dBFS  ');
