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
  fps: +opt("--fps", 30), chunks: +opt("--chunks", Math.max(2, Math.min(6, Math.floor(os.cpus().length / 2)))), voice: !has("--no-voice"), effort: opt("--effort", "high")
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
  return run(process.execPath, [RENDER, "--page", page, "--fps", String(o.fps), "--from", String(bounds[i]), "--to", String(bounds[i + 1]), "--out", dir, "--no-score"]).then(() => mp4);
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
  let audio = scoreWav;
  if (voWav && fs.existsSync(voWav)) {
    audio = path.join(work, "mixed.wav");
    const r = spawnSync(FFMPEG, ["-loglevel", "error", "-y", "-i", scoreWav, "-i", voWav, "-filter_complex",
      "[0:a][1:a]sidechaincompress=threshold=0.015:ratio=5:attack=30:release=500:makeup=1[duck];[duck][1:a]amix=inputs=2:normalize=0:duration=first[out]", "-map", "[out]", "-ar", "48000", "-ac", "2", audio], { encoding: "utf8" });
    if (r.status !== 0) { console.error(r.stderr); audio = scoreWav; }
  }
  const r = spawnSync(FFMPEG, ["-loglevel", "error", "-y", "-i", video, "-i", audio, "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", finalPath], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(r.stderr);
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
