#!/usr/bin/env node
/**
 * Ad engine — one command from a product brief to a finished MP4, built for
 * wall-clock speed: every stage that can run at once does.
 *
 *   EXPLABS_API_KEY=... ELEVENLABS_API_KEY=... node ad/engine/produce.mjs \
 *     --product "..." --audience "..." [--duration 40] [--variants 3] [--slug x]
 *     [--spec path/to/spec.json]   # skip authoring, render an existing spec
 *     [--fps 30] [--chunks 6]      # parallel render workers
 *     [--no-voice]
 *
 * Stages and what overlaps:
 *   1. author      one Astra call per variant, all concurrent (+ a tiny judge)
 *   2. build       inline spec + library into one ad.html
 *   3. render      K headless browsers each render a slice of the timeline
 *                  (video only) ... while a K+1th renders the score, and the
 *                  voice lines synthesise in parallel with all of it
 *   4. assemble    concat slices -> mux score -> duck under voice -> final.mp4
 *   5. stills      a contact sheet for review
 * Prints a per-stage timing table at the end.
 */
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..", "..");
const RENDER = path.join(ROOT, "ad", "render.mjs");
const FFMPEG = fs.existsSync(path.join(os.homedir(), ".local/bin/ffmpeg")) ? path.join(os.homedir(), ".local/bin/ffmpeg") : "ffmpeg";

const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };
const has = n => argv.includes(n);
const o = {
  product: opt("--product", null), audience: opt("--audience", "people"), duration: +opt("--duration", 40),
  variants: +opt("--variants", 1), slug: opt("--slug", null), spec: opt("--spec", null),
  fps: +opt("--fps", 30), chunks: +opt("--chunks", Math.max(2, Math.min(6, Math.floor(os.cpus().length / 2)))), voice: !has("--no-voice"), effort: opt("--effort", "high"),
  capture: opt("--capture", "jpeg")                    // frame capture: jpeg (4.6x faster) | png
};
if (!o.product && !o.spec) { console.error("need --product or --spec"); process.exit(2); }

const timings = [];
const now = () => Date.now();
async function stage(name, fn) { const t = now(); const r = await fn(); timings.push([name, (now() - t) / 1000]); console.error(`# ${name}: ${((now() - t) / 1000).toFixed(1)}s`); return r; }
function run(cmd, args, opts = {}) {
  return new Promise((res, rej) => {
    const p = spawn(cmd, args, { stdio: ["ignore", "pipe", "pipe"], env: process.env, ...opts });
    let out = "", err = "";
    p.stdout.on("data", d => out += d); p.stderr.on("data", d => { err += d; if (opts.echo) process.stderr.write(d); });
    p.on("close", code => code === 0 ? res({ out, err }) : rej(new Error(`${path.basename(cmd)} ${args.slice(0, 3).join(" ")} exited ${code}\n${err.slice(-800)}`)));
  });
}

const tAll = now();
// ---- 1. author
let specPath = o.spec;
if (!specPath) {
  const r = await stage("author", () => run(process.execPath, [path.join(HERE, "generate.mjs"), "--product", o.product, "--audience", o.audience, "--duration", String(o.duration), "--variants", String(o.variants), "--effort", o.effort, ...(o.slug ? ["--slug", o.slug] : [])], { echo: true }));
  specPath = path.join(JSON.parse(r.out.trim().split("\n").pop()).dir, "spec.json");
}
specPath = path.resolve(specPath); // everything downstream is absolute: ffmpeg's concat list resolves relative paths against itself
const spec = JSON.parse(fs.readFileSync(specPath, "utf8"));
const outDir = path.dirname(specPath);
const reuse = has("--reuse"); // keep finished slices / score / voice from a previous run
const D = +spec.duration;

// ---- 2. build
await stage("build", () => run(process.execPath, [path.join(HERE, "build-ad.mjs"), specPath]));
const page = path.join(outDir, "ad.html");

// ---- 3. render slices + score + voice, all at once
const work = path.join(outDir, "work");
if (!reuse) fs.rmSync(work, { recursive: true, force: true });
fs.mkdirSync(work, { recursive: true });
const done = p => reuse && fs.existsSync(p) && fs.statSync(p).size > 0;
// slice boundaries land on the frame grid, so the concatenation has neither a
// duplicated nor a missing frame at any seam
const K = Math.max(1, Math.min(o.chunks, Math.floor(D / 4)));
const totalFrames = Math.round(D * o.fps);
const bounds = Array.from({ length: K + 1 }, (_, i) => Math.round(totalFrames * i / K) / o.fps);
const sliceJobs = Array.from({ length: K }, (_, i) => {
  const dir = path.join(work, `slice${i}`), mp4 = path.join(dir, "kin-ad.mp4");
  if (done(mp4)) return Promise.resolve(mp4);
  // JPEG capture at quality 95: 4.6x faster per frame than PNG (88 ms vs 403 ms measured), invisible after H.264
  return run(process.execPath, [RENDER, "--page", page, "--fps", String(o.fps), "--from", String(bounds[i]), "--to", String(bounds[i + 1]), "--out", dir, "--no-score", "--capture", o.capture]).then(() => mp4);
});
const scoreWavPath = path.join(work, "score", "score.wav");
const scoreJob = done(scoreWavPath) ? Promise.resolve(scoreWavPath) : run(process.execPath, [RENDER, "--page", page, "--score-only", "--out", path.join(work, "score")]).then(() => scoreWavPath);
const voWavPath = path.join(outDir, "voice", "vo.wav");
const voiceJob = (o.voice && (spec.voiceover || []).length && (done(voWavPath) || process.env.ELEVENLABS_API_KEY))
  ? (done(voWavPath) ? Promise.resolve(voWavPath) : run(process.execPath, [path.join(HERE, "voice.mjs"), specPath, "--score", "/nonexistent", "--video", "/nonexistent"], { echo: true }).then(() => voWavPath).catch(e => { console.error("# voice failed: " + e.message.split("\n")[0]); return null; }))
  : Promise.resolve(null);
const [slices, scoreWav, voWav] = await stage(`render x${K} + score + voice`, () => Promise.all([Promise.all(sliceJobs), scoreJob, voiceJob]));

// ---- 4. assemble
const finalPath = path.join(outDir, "final.mp4");
await stage("assemble", async () => {
  const list = path.join(work, "concat.txt");
  fs.writeFileSync(list, slices.map(p => `file '${path.resolve(p).replace(/'/g, "'\\''")}'`).join("\n") + "\n");
  const video = path.join(work, "video.mp4");
  const c = spawnSync(FFMPEG, ["-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", list, "-c", "copy", video], { encoding: "utf8" });
  if (c.status !== 0) throw new Error("concat failed: " + c.stderr);
  // Mastering. ebur128 prints a per-frame "I:" as it goes; only the block
  // after "Summary:" is the whole-file figure.
  const measure = f => { const raw = spawnSync(FFMPEG, ["-nostats", "-i", f, "-af", "ebur128=peak=true", "-f", "null", "-"], { encoding: "utf8" }).stderr; const m = raw.slice(raw.lastIndexOf("Summary:")); return { I: parseFloat((m.match(/I:\s+(-?[\d.]+) LUFS/) || [])[1]), P: parseFloat((m.match(/Peak:\s+(-?[\d.]+) dBFS/) || [])[1]) }; };
  const toward = (meas, targetI, peakCap) => { if (!isFinite(meas.I) || !isFinite(meas.P)) return 0; let g = targetI - meas.I; if (meas.P + g > peakCap) g = peakCap - meas.P; return g; };
  let audio = scoreWav;
  if (voWav && fs.existsSync(voWav)) {
    // level each stem first: the voice to -18 LUFS (peaks under -4), the bed to -28 LUFS, then duck the bed under the voice
    const gS = toward(measure(scoreWav), -26, -8), gV = toward(measure(voWav), -18, -4);
    console.error(`# stems: score ${gS >= 0 ? "+" : ""}${gS.toFixed(1)} dB, voice ${gV >= 0 ? "+" : ""}${gV.toFixed(1)} dB`);
    audio = path.join(work, "mixed.wav");
    const r = spawnSync(FFMPEG, ["-loglevel", "error", "-y", "-i", scoreWav, "-i", voWav, "-filter_complex",
      // the leveled voice feeds both the ducker's sidechain and the mix, so it must be split
      `[0:a]volume=${gS.toFixed(2)}dB[s];[1:a]volume=${gV.toFixed(2)}dB,asplit[v1][v2];[s][v1]sidechaincompress=threshold=0.02:ratio=4:attack=30:release=600:makeup=1[duck];[duck][v2]amix=inputs=2:normalize=0:duration=first,apad=whole_dur=${D}[out]`,
      "-map", "[out]", "-t", String(D), "-ar", "48000", "-ac", "2", audio], { encoding: "utf8" });
    if (r.status !== 0) throw new Error("voice mix failed: " + r.stderr);
  }
  // the mix to -21 LUFS integrated; a true-peak limiter holds -3 dBTP instead of a bare gain cap
  const mix = measure(audio);
  const gainDb = isFinite(mix.I) ? -21 - mix.I : 0;
  console.error(`# mix: ${isFinite(mix.I) ? mix.I.toFixed(1) : "?"} LUFS, peak ${isFinite(mix.P) ? mix.P.toFixed(1) : "?"} dBFS -> ${gainDb >= 0 ? "+" : ""}${gainDb.toFixed(1)} dB, limiter at -3 dBTP`);
  const r = spawnSync(FFMPEG, ["-loglevel", "error", "-y", "-i", video, "-i", audio, "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-af", `volume=${gainDb.toFixed(2)}dB,alimiter=limit=0.7079:attack=5:release=60:level=false`, "-c:a", "aac", "-b:a", "192k", "-t", String(D), "-movflags", "+faststart", finalPath], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(r.stderr);
  const fin = measure(finalPath);
  console.error(`# final: ${isFinite(fin.I) ? fin.I.toFixed(1) : "?"} LUFS, true peak ${isFinite(fin.P) ? fin.P.toFixed(1) : "?"} dBTP`);
});

// ---- 5. stills
await stage("stills", async () => {
  const dir = path.join(work, "stills");
  await run(process.execPath, [RENDER, "--page", page, "--stills", "8", "--fps", "30", "--out", dir]);
  spawnSync(FFMPEG, ["-loglevel", "error", "-y", "-i", path.join(dir, "stills", "still_%02d.png"), "-vf", "scale=640:-1,tile=4x2", path.join(outDir, "contact.png")]);
});

const probe = spawnSync(FFMPEG, ["-i", finalPath], { encoding: "utf8" }).stderr;
const dur = (probe.match(/Duration: ([\d:.]+)/) || [])[1];
const total = (now() - tAll) / 1000;
console.error("\n# stage                       seconds");
for (const [n, s] of timings) console.error(`# ${n.padEnd(28)} ${s.toFixed(1).padStart(7)}`);
console.error(`# ${"TOTAL".padEnd(28)} ${total.toFixed(1).padStart(7)}   (${K} render workers, ${o.fps} fps)`);
console.log(JSON.stringify({ final: finalPath, duration: dur, contact: path.join(outDir, "contact.png"), seconds: +total.toFixed(1), workers: K }));
