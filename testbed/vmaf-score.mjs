/**
 * vmaf-score.mjs — score a vmaf-call.mjs run directory against the source fixture.
 *
 *   node vmaf-score.mjs --dir=/path/run --src=/path/cam1080.mjpeg [--keep=2]
 *
 * Steps:
 *  1. Decode the source once to 160x90 gray (cached next to this script's output
 *     root) for CONTENT alignment: every captured still is matched to the source
 *     frame that minimises MSE. The fake camera loops the file and its phase vs
 *     the receiver is unknowable from outside, so wall-clock alignment would be
 *     fiction; content alignment is the honest version. Matched indices are
 *     reported per still so a garbage match is visible in the output.
 *  2. Extract exactly the matched source frames at full 1920x1080 (one ffmpeg
 *     select call, in matched order).
 *  3. ffmpeg libvmaf (built-in vmaf_v0.6.1 model) + ssim + psnr on the aligned
 *     sequences. Per-frame scores + mean/p5 written to <dir>/scores.json.
 *  4. Reference PNGs and all but --keep sample distorted PNGs are deleted
 *     (500 MB scratchpad budget).
 */

import { execFileSync, execFile } from 'node:child_process';
import { readFileSync, writeFileSync, readdirSync, unlinkSync, existsSync, mkdirSync } from 'node:fs';
import { join, resolve, basename } from 'node:path';
import { promisify } from 'node:util';
const execFileP = promisify(execFile);

const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const body = a.replace(/^--/, '');
    const i = body.indexOf('=');
    return i === -1 ? [body, true] : [body.slice(0, i), body.slice(i + 1)];
  }),
);

const DIR = resolve(String(args.dir));
const SRC = resolve(String(args.src));
const KEEP = Number(args.keep ?? 2);
const GW = 160, GH = 90;
const GRAY_CACHE = join(DIR, '..', 'src_gray_160x90.raw');

const run = (cmd, argv, opts = {}) => execFileSync(cmd, argv, { maxBuffer: 1 << 28, ...opts });

// ── 1. source gray cache ──────────────────────────────────────────────────────
let srcGray;
if (existsSync(GRAY_CACHE)) {
  srcGray = readFileSync(GRAY_CACHE);
} else {
  srcGray = run('ffmpeg', ['-v', 'error', '-i', SRC, '-vf', `scale=${GW}:${GH}`, '-f', 'rawvideo', '-pix_fmt', 'gray', '-']);
  writeFileSync(GRAY_CACHE, srcGray);
}
const SRC_N = Math.floor(srcGray.length / (GW * GH));
console.log(`  source: ${SRC_N} frames (${GW}x${GH} gray cache ${(srcGray.length / 1e6).toFixed(1)} MB)`);

const mse = (a, aOff, b, bOff, n) => {
  let s = 0;
  for (let i = 0; i < n; i++) { const d = a[aOff + i] - b[bOff + i]; s += d * d; }
  return s / n;
};

// ── 2. align each captured still by content ───────────────────────────────────
const dists = readdirSync(DIR).filter((f) => /^dist_\d+\.png$/.test(f)).sort();
console.log(`  aligning ${dists.length} stills…`);
const matched = [];
for (const f of dists) {
  const g = run('ffmpeg', ['-v', 'error', '-i', join(DIR, f), '-vf', `scale=${GW}:${GH}`, '-f', 'rawvideo', '-pix_fmt', 'gray', '-']);
  let best = -1, bestMse = Infinity;
  for (let i = 0; i < SRC_N; i++) {
    const m = mse(g, 0, srcGray, i * GW * GH, GW * GH);
    if (m < bestMse) { bestMse = m; best = i; }
  }
  matched.push({ file: f, srcIdx: best, mse: +bestMse.toFixed(1) });
}
const idxSeq = matched.map((m) => m.srcIdx).join(',');
console.log(`  matched indices: ${idxSeq}`);

// Periodicity guard: testsrc2's motifs repeat, and a global argmin occasionally
// lands on the wrong occurrence (measured on the VP8 arms: one still per arm
// grabbed src 152/277 from inside the 500s/600s, a wrong-content pair that
// scored ~61-67 and poisoned the p5). Any still whose index breaks the
// monotonic run (step outside 0..60, wrap-aware) is re-matched within ±45 of
// its interpolation, and the rematch is flagged in the output.
for (let i = 1; i < matched.length - 1; i++) {
  let step = matched[i].srcIdx - matched[i - 1].srcIdx;
  if (step < 0) step += SRC_N;
  if (step <= 60) continue;
  let next = matched[i + 1].srcIdx, prev = matched[i - 1].srcIdx;
  if (next < prev) next += SRC_N;
  const exp = (Math.round((prev + next) / 2)) % SRC_N;
  const g = run('ffmpeg', ['-v', 'error', '-i', join(DIR, matched[i].file), '-vf', `scale=${GW}:${GH}`, '-f', 'rawvideo', '-pix_fmt', 'gray', '-']);
  let best = matched[i].srcIdx, bm = Infinity;
  for (let k = exp - 45; k <= exp + 45; k++) {
    const j = ((k % SRC_N) + SRC_N) % SRC_N;
    const m = mse(g, 0, srcGray, j * GW * GH, GW * GH);
    if (m < bm) { bm = m; best = j; }
  }
  console.log(`  rematch: ${matched[i].file} ${matched[i].srcIdx} -> ${best} (interp ${exp}, mse ${bm.toFixed(1)})`);
  matched[i] = { file: matched[i].file, srcIdx: best, mse: +bm.toFixed(1), rematched: true };
}

// ── 3. extract matched reference frames at full res, in MATCHED order ────────
// select emits frames in decode (ascending) order; the matched sequence wraps
// the file's loop point, so a naive one-pass extraction comes out rotated.
// Extract each UNIQUE matched index once (ascending), then hard-link into
// capture order.
const uniq = [...new Set(matched.map((m) => m.srcIdx))].sort((a, b) => a - b);
const sel = uniq.map((i) => `eq(n\\,${i})`).join('+');
run('ffmpeg', ['-v', 'error', '-i', SRC, '-vf', `select='${sel}'`, '-fps_mode', 'passthrough',
  '-start_number', '0', join(DIR, 'refu_%03d.png')]);
const refu = readdirSync(DIR).filter((f) => /^refu_\d+\.png$/.test(f)).sort();
if (refu.length !== uniq.length) {
  console.log(`  RED: extracted ${refu.length} unique refs for ${uniq.length} indices — select mis-counted`);
  process.exit(1);
}
const { linkSync } = await import('node:fs');
for (let i = 0; i < matched.length; i++) {
  const pos = uniq.indexOf(matched[i].srcIdx);
  linkSync(join(DIR, refu[pos]), join(DIR, `ref_${String(i).padStart(3, '0')}.png`));
}
const refs = readdirSync(DIR).filter((f) => /^ref_\d+\.png$/.test(f)).sort();

// ── 4. score ─────────────────────────────────────────────────────────────────
// Reference calibration (colormtx-probe.mjs, 2026-08-01): Chrome's canvas
// YCbCr→RGB conversion matches BT.709, NOT the BT.601 ffmpeg uses by default
// on this mjpeg (local no-encode capture: 38.3 dB PSNR vs 709-converted
// reference, 34.2 vs 601; full-range direct conversion is worse — Chrome's
// path includes the limited-range roundtrip, which the colorspace-filter
// detour reproduces). All refs are therefore passed through
// colorspace=bt709:iall=bt470bg before scoring. Method floor, measured on
// local-capture stills with NO encode: VMAF 99.10, PSNR 38.26, SSIM 0.987 —
// an arm at the floor is transparent to this rig.
const CAL = "[1:v]colorspace=bt709:iall=bt470bg:fast=1[rr];[0:v][rr]";
const N = dists.length;
const vlog = join(DIR, 'vmaf.json');
run('ffmpeg', ['-v', 'error',
  '-framerate', '2', '-start_number', '0', '-i', join(DIR, 'dist_%03d.png'),
  '-framerate', '2', '-start_number', '0', '-i', join(DIR, 'ref_%03d.png'),
  '-lavfi', `${CAL}libvmaf=log_path='${vlog}':log_fmt=json`, '-f', 'null', '-']);
const vj = JSON.parse(readFileSync(vlog, 'utf8'));
const perFrame = (vj.frames ?? []).map((f) => f.metrics?.vmaf ?? f.metrics?.['vmaf'] ?? null);

// psnr/ssim print their per-frame lines to stderr; execFileP resolves with it.
let psnrPer = [];
try {
  const { stderr } = await execFileP('ffmpeg', [
    '-framerate', '2', '-start_number', '0', '-i', join(DIR, 'dist_%03d.png'),
    '-framerate', '2', '-start_number', '0', '-i', join(DIR, 'ref_%03d.png'),
    '-lavfi', CAL + 'psnr', '-f', 'null', '-'], { maxBuffer: 1 << 24 });
  psnrPer = [...String(stderr).matchAll(/average:([\d.]+|inf)/g)].map((m) => (m[1] === 'inf' ? 99 : parseFloat(m[1])));
} catch (e) {
  psnrPer = [...String(e.stderr ?? '').matchAll(/average:([\d.]+|inf)/g)].map((m) => (m[1] === 'inf' ? 99 : parseFloat(m[1])));
}
let ssimPer = [];
try {
  const { stderr } = await execFileP('ffmpeg', [
    '-framerate', '2', '-start_number', '0', '-i', join(DIR, 'dist_%03d.png'),
    '-framerate', '2', '-start_number', '0', '-i', join(DIR, 'ref_%03d.png'),
    '-lavfi', CAL + 'ssim', '-f', 'null', '-'], { maxBuffer: 1 << 24 });
  ssimPer = [...String(stderr).matchAll(/All:([\d.]+)/g)].map((m) => parseFloat(m[1]));
} catch (e) {
  ssimPer = [...String(e.stderr ?? '').matchAll(/All:([\d.]+)/g)].map((m) => parseFloat(m[1]));
}

const pct = (arr, p) => {
  const a = arr.filter((x) => x != null && Number.isFinite(x)).slice().sort((x, y) => x - y);
  if (!a.length) return null;
  const k = Math.max(0, Math.min(a.length - 1, Math.floor((p / 100) * (a.length - 1))));
  return a[k];
};
const mean = (arr) => {
  const a = arr.filter((x) => x != null && Number.isFinite(x));
  return a.length ? +(a.reduce((s, x) => s + x, 0) / a.length).toFixed(3) : null;
};

const scores = {
  dir: DIR, src: SRC, n: N,
  alignment: matched,
  vmaf: { mean: mean(perFrame), p5: pct(perFrame, 5), p50: pct(perFrame, 50), min: pct(perFrame, 0), perFrame },
  ssim: { mean: mean(ssimPer), p5: pct(ssimPer, 5), perFrame: ssimPer },
  psnr: { mean: mean(psnrPer), p5: pct(psnrPer, 5), perFrame: psnrPer },
};
writeFileSync(join(DIR, 'scores.json'), JSON.stringify(scores, null, 1));
console.log(`  VMAF mean ${scores.vmaf.mean}  p5 ${scores.vmaf.p5}  (n=${N})  SSIM ${scores.ssim.mean}  PSNR ${scores.psnr.mean}`);

// ── 5. cleanup: keep run.json, scores.json, vmaf.json, --keep sample stills ───
for (const f of [...refs, ...refu]) { try { unlinkSync(join(DIR, f)); } catch {} }
for (let i = 0; i < dists.length - KEEP; i++) { try { unlinkSync(join(DIR, dists[i])); } catch {} }
console.log(`  cleaned refs + ${dists.length - KEEP} stills (kept ${Math.min(KEEP, dists.length)} samples)`);
