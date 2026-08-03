/**
 * Build a two-sided conversation out of real speech, with ground truth to the sample.
 *
 * Output: two WAV files — one per participant — that Chrome will use as its
 * microphone. Side A's track carries A's turns and room tone everywhere else; side B's
 * is the complement. Plus `truth.json`, holding the exact sample position of every
 * breath, every speech onset, and every turn end.
 *
 * ── What is deliberately real ────────────────────────────────────────────────
 *   speech     real recorded human speech (LibriSpeech, CC BY 4.0)
 *   breaths    real recorded human inhalations, cut from the same recordings
 *   room tone  a shaped noise floor at ~-58 dBFS, because digital silence is
 *              unrealistically easy — the detector calibrates against a noise floor,
 *              and a floor of exactly zero would flatter it enormously
 *
 * ── What the two files are NOT ───────────────────────────────────────────────
 * Synchronised. Chrome starts the file when capture starts, and the two browsers start
 * capture a few tens of milliseconds apart, so the two timelines have an unknown
 * offset. That offset is measured rather than assumed, via the marker train below, and
 * it does not affect the measurements that matter most:
 *
 *   · whether a breath survives the pipeline and is still classified as a breath
 *   · whether noise suppression destroys it
 *   · whether the reported breath lead matches the lead that was baked in
 *
 * All three are measured from a single received stream — onset and voiced events on the
 * same audio — so a constant offset between the two files cancels out entirely.
 *
 * ── The marker train ─────────────────────────────────────────────────────────
 * A pair of 4 ms clicks 60 ms apart, at a fixed grid in both files, placed in stretches
 * where both sides are silent. Nothing in speech looks like two isolated 4 ms
 * transients 60 ms apart, so they are unambiguous, and comparing when each side's
 * marker arrives measures the file offset instead of assuming it away.
 */

import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const MEDIA = join(HERE, 'media');
const SR = 48000;

const LEAD_IN_S = 22;        // room tone while the browsers launch and connect
const TURN_GAP_MS = 620;     // silence between one side ending and the next beginning
const MARKER_EVERY_S = 12;
// Default is a very quiet studio. Overridable, because the level turns out to decide
// whether the noise-suppression experiment can produce a result at all: at -58 dBFS there
// is nothing for a noise suppressor to remove, so it behaves like a pass-through and the
// A/B comes back flat. A real quiet room is nearer -48, an office with a fan -40, and a
// café -33. Sweeping the level is what turns one inconclusive A/B into a dose-response
// curve — and a curve can falsify the claim in a way a single comparison cannot.
const ROOM_TONE_DBFS = Number(process.env.ROOM_TONE_DBFS ?? -58);
const SPEECH_PEAK = 0.28;    // normalise every utterance to the same peak, like AGC would

const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const [k, v] = a.replace(/^--/, '').split('=');
    return [k, v ?? true];
  }),
);
const TURNS = Number(args.turns ?? 14);
const SEED = Number(args.seed ?? 7);
const OUTDIR = join(MEDIA, args.out ?? 'conv');

// Deterministic PRNG, so a fixture can be regenerated exactly.
let seed = SEED;
const rnd = () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
const pick = (arr) => arr[Math.floor(rnd() * arr.length)];

const corpus = JSON.parse(readFileSync(join(MEDIA, 'corpus.json'), 'utf8'));

function decode(path) {
  const buf = execFileSync('ffmpeg', ['-v', 'error', '-i', path, '-ac', '1', '-ar', String(SR), '-f', 'f32le', '-'], {
    maxBuffer: 1 << 28,
  });
  return new Float32Array(buf.buffer, buf.byteOffset, buf.length / 4);
}

const cache = new Map();
const load = (p) => {
  if (!cache.has(p)) cache.set(p, decode(p));
  return cache.get(p);
};

function slice(path, a, b, peak) {
  const x = load(path).subarray(a, b);
  const y = Float32Array.from(x);
  if (peak) {
    let m = 0;
    for (const v of y) m = Math.max(m, Math.abs(v));
    if (m > 1e-6) {
      const g = peak / m;
      for (let i = 0; i < y.length; i++) y[i] *= g;
    }
  }
  // 5 ms raised-cosine edges, so a splice never creates a click the detector would
  // read as a transient onset.
  const f = Math.min(240, y.length >> 1);
  for (let i = 0; i < f; i++) {
    const w = 0.5 - 0.5 * Math.cos((Math.PI * i) / f);
    y[i] *= w;
    y[y.length - 1 - i] *= w;
  }
  return y;
}

/** Shaped noise at a target level — a plausible quiet room, not digital silence. */
function roomTone(n) {
  const amp = 10 ** (ROOM_TONE_DBFS / 20);
  const y = new Float32Array(n);
  let b0 = 0, b1 = 0;
  for (let i = 0; i < n; i++) {
    const w = rnd() * 2 - 1;
    b0 = 0.99 * b0 + 0.01 * w; // low rumble
    b1 = 0.7 * b1 + 0.3 * w;   // broadband hiss
    y[i] = (b0 * 3 + b1 * 0.6) * amp * 3;
  }
  return y;
}

// ── Build the turn plan ──────────────────────────────────────────────────────
// Alternating, with three quarters of turns opening on an audible inhale. The rest
// open straight into voice, which gives the breath classifier a false-positive rate to
// be measured against rather than assumed to be zero.
// A quiet inhale in a noisy room is inaudible — that is physics, not a codec problem, and
// the fixture self-check below refuses to build a fixture where it happens. So a noisier
// room needs a louder set of breaths, or the experiment measures the room instead of the
// thing under test. Both arms of an A/B use the same fixture, so restricting the set
// narrows the population without biasing the comparison.
const MIN_BREATH_DBFS = Number(process.env.MIN_BREATH_DBFS ?? -Infinity);
const breaths = corpus.breaths.filter(
  (b) => b.ms >= 180 && b.ms <= 400 && b.peakDbfs >= MIN_BREATH_DBFS,
);
const utts = corpus.utterances.filter((u) => u.ms > 2500 && u.ms < 7000);
if (!breaths.length || !utts.length) throw new Error('corpus too small — run corpus.mjs first');

// Give the two sides different speakers where the corpus allows it. This matters: each
// machine's remote detector then hears a voice it has never heard on its local mic,
// which is the real situation. A single speaker on both sides would let a detector that
// only works on one voice look like a detector that works.
const speakers = [...new Set(utts.map((u) => u.spk))];
const voiceFor = { A: speakers[0], B: speakers[1] ?? speakers[0] };
const uttsFor = (side) => {
  const own = utts.filter((u) => u.spk === voiceFor[side]);
  return own.length >= 3 ? own : utts;
};
const breathsFor = (side) => {
  const own = breaths.filter((b) => b.spk === voiceFor[side]);
  return own.length >= 2 ? own : breaths;
};

const plan = [];
let t = LEAD_IN_S * 1000;
for (let i = 0; i < TURNS; i++) {
  const side = i % 2 === 0 ? 'A' : 'B';
  const withBreath = rnd() < 0.75;
  const b = pick(breathsFor(side));
  // Time from inhale onset to first phonation. Włodarczak & Heldner put pre-turn
  // inhalations in this range; drawing from it rather than fixing one value means the
  // measured lead distribution can be compared to the planted one.
  const leadMs = withBreath ? Math.round(180 + rnd() * 90) : 0;
  const u = pick(uttsFor(side));
  const speechMs = Math.min(u.ms, 5200);

  plan.push({
    n: i + 1, side, withBreath,
    breathAtMs: withBreath ? t : null,
    breathMs: withBreath ? b.ms : 0,
    breathSrc: withBreath ? b.src : null,
    breath: withBreath ? b : null,
    speechAtMs: t + leadMs,
    leadMs,
    endAtMs: t + leadMs + speechMs,
    speechMs: +speechMs.toFixed(1),
    utt: u,
  });
  t = t + leadMs + speechMs + TURN_GAP_MS;
}
const totalMs = t + 4000;
const total = Math.ceil((totalMs / 1000) * SR);

// ── Render ───────────────────────────────────────────────────────────────────
const tracks = { A: roomTone(total), B: roomTone(total) };

const add = (dst, src, atMs) => {
  const at = Math.round((atMs / 1000) * SR);
  for (let i = 0; i < src.length && at + i < dst.length; i++) dst[at + i] += src[i];
};

for (const p of plan) {
  const dst = tracks[p.side];
  if (p.withBreath) {
    add(dst, slice(p.breath.path, p.breath.startSamp, p.breath.endSamp, null), p.breathAtMs);
  }
  add(dst, slice(p.utt.path, p.utt.startSamp, p.utt.endSamp, SPEECH_PEAK), p.speechAtMs);
}

// Markers, only where both sides are quiet, so they never land on speech.
const busy = (ms, span) =>
  plan.some((p) => ms + span > (p.breathAtMs ?? p.speechAtMs) - 250 && ms < p.endAtMs + 250);
const markers = [];
const click = (freq, ms) => {
  const n = Math.round((ms / 1000) * SR);
  const y = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const w = Math.sin((Math.PI * i) / n) ** 2;
    y[i] = Math.sin((2 * Math.PI * freq * i) / SR) * 0.22 * w;
  }
  return y;
};
const c1 = click(3000, 4), c2 = click(3000, 4);
for (let ms = MARKER_EVERY_S * 1000; ms < totalMs - 1000; ms += MARKER_EVERY_S * 1000) {
  if (busy(ms, 100)) continue;
  add(tracks.A, c1, ms); add(tracks.A, c2, ms + 60);
  add(tracks.B, c1, ms); add(tracks.B, c2, ms + 60);
  markers.push(ms);
}

function writeWav(path, x) {
  const n = x.length;
  const buf = Buffer.alloc(44 + n * 2);
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + n * 2, 4); buf.write('WAVE', 8);
  buf.write('fmt ', 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(1, 22); buf.writeUInt32LE(SR, 24); buf.writeUInt32LE(SR * 2, 28);
  buf.writeUInt16LE(2, 32); buf.writeUInt16LE(16, 34);
  buf.write('data', 36); buf.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) {
    const v = Math.max(-1, Math.min(1, x[i]));
    buf.writeInt16LE(Math.round(v * 32767), 44 + i * 2);
  }
  writeFileSync(path, buf);
}

mkdirSync(OUTDIR, { recursive: true });
writeWav(join(OUTDIR, 'A.wav'), tracks.A);
writeWav(join(OUTDIR, 'B.wav'), tracks.B);

// Ground truth: what a perfect instrument would report.
const truth = {
  sr: SR, seed: SEED, leadInMs: LEAD_IN_S * 1000, totalMs: +totalMs.toFixed(0),
  turnGapMs: TURN_GAP_MS, roomToneDbfs: ROOM_TONE_DBFS, markers,
  turns: plan.map((p) => ({
    n: p.n, side: p.side, withBreath: p.withBreath,
    breathAtMs: p.breathAtMs == null ? null : +p.breathAtMs.toFixed(1),
    breathMs: p.breathMs, breathSrc: p.breathSrc,
    speechAtMs: +p.speechAtMs.toFixed(1), leadMs: p.leadMs,
    endAtMs: +p.endAtMs.toFixed(1), speechMs: p.speechMs, speechSrc: p.utt.name,
  })),
  // The gaps a perfect instrument would report. `toEvidence` is the gap to the inhale
  // — what §1.1c-2 argues is the honest number. `toWord` is what everyone else reports.
  expected: plan.slice(1).map((p, i) => {
    const prev = plan[i];
    return {
      responder: p.side,
      toEvidenceMs: +((p.breathAtMs ?? p.speechAtMs) - prev.endAtMs).toFixed(1),
      toWordMs: +(p.speechAtMs - prev.endAtMs).toFixed(1),
      leadMs: p.leadMs,
    };
  }),
};
writeFileSync(join(OUTDIR, 'truth.json'), JSON.stringify(truth, null, 1));

// ── Validate the fixture before trusting any result computed from it ─────────
// If a breath were buried under the room tone, every downstream "the breath did not
// survive" conclusion would be an artefact of the fixture rather than a finding about
// the pipeline — and it would look exactly like a real result. So measure the rendered
// audio, not the plan.
function dbfsAt(x, atMs, spanMs) {
  const a = Math.round((atMs / 1000) * SR);
  const b = Math.min(x.length, a + Math.round((spanMs / 1000) * SR));
  let s = 0;
  for (let i = a; i < b; i++) s += x[i] * x[i];
  return 20 * Math.log10(Math.sqrt(s / Math.max(1, b - a)) + 1e-12);
}

const checks = [];
for (const p of plan) {
  if (!p.withBreath) continue;
  const x = tracks[p.side];
  const breathDb = dbfsAt(x, p.breathAtMs, Math.min(p.breathMs, p.leadMs));
  const floorDb = dbfsAt(x, p.breathAtMs - 900, 500); // quiet stretch just before
  const speechDb = dbfsAt(x, p.speechAtMs + 200, 400);
  checks.push({ n: p.n, breathDb, floorDb, speechDb, snr: breathDb - floorDb, below: speechDb - breathDb });
}
const minSnr = Math.min(...checks.map((c) => c.snr));
const minBelow = Math.min(...checks.map((c) => c.below));
const floorAvg = checks.reduce((a, c) => a + c.floorDb, 0) / checks.length;

console.log(`\nfixture self-check (measured on the rendered audio, not the plan)`);
console.log(`  room tone floor          ${floorAvg.toFixed(1)} dBFS`);
console.log(`  quietest breath is       ${minSnr.toFixed(1)} dB above the floor   ${minSnr >= 6 ? '✓ audible' : '✗ TOO QUIET — fixture invalid'}`);
console.log(`  breaths sit at least     ${minBelow.toFixed(1)} dB below speech     ${minBelow >= 6 ? '✓ distinct from speech' : '✗ TOO LOUD — indistinguishable from speech'}`);
if (minSnr < 6 || minBelow < 6) {
  console.error('\n  The fixture is unusable. Any "breath was lost" result from it would be an');
  console.error('  artefact of the fixture, not a finding about the pipeline. Fix before running.\n');
  process.exit(1);
}

const withB = plan.filter((p) => p.withBreath).length;
console.log(`\nwrote ${OUTDIR}/{A,B}.wav + truth.json`);
console.log(`  ${(totalMs / 1000).toFixed(1)} s · ${TURNS} turns · ${withB} with a real inhale, ${TURNS - withB} without`);
console.log(`  lead-in ${LEAD_IN_S} s · ${markers.length} sync markers · room tone ${ROOM_TONE_DBFS} dBFS`);
console.log(`  planted breath leads: ${plan.filter((p) => p.leadMs).map((p) => p.leadMs).join(', ')} ms`);
console.log(`  speakers: ${[...new Set(plan.map((p) => p.utt.spk))].join(', ')}\n`);
for (const p of plan.slice(0, 6)) {
  console.log(
    `  turn ${String(p.n).padStart(2)} ${p.side}  ` +
      (p.withBreath ? `inhale ${String(Math.round(p.breathAtMs)).padStart(6)} ms (${p.breathMs} ms) → ` : `${' '.repeat(30)}`) +
      `speech ${String(Math.round(p.speechAtMs)).padStart(6)} ms  lead ${String(p.leadMs).padStart(3)} ms  ${(p.speechMs / 1000).toFixed(1)} s`,
  );
}
console.log('  …\n');
