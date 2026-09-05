#!/usr/bin/env node
/**
 * Ad engine — voice. Synthesises the spec's voiceover lines with ElevenLabs
 * (all lines in parallel), places them on the timeline, and mixes them under
 * the score with ducking. The key comes from ELEVENLABS_API_KEY; it is never
 * written anywhere.
 *
 *   node ad/engine/voice.mjs <spec.json> [--score ad/out/score.wav] [--video ad/out/kin-ad.mp4]
 *
 * Model: eleven_v3 (the most expressive model on the account), lossless PCM at
 * 44.1 kHz (falls back to 192 kbps MP3 if the plan refuses PCM). The voice and
 * stability come from spec.voice (cast by Astra) or default to George, 0.5.
 */
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import os from "node:os";

const FFMPEG = fs.existsSync(path.join(os.homedir(), ".local/bin/ffmpeg")) ? path.join(os.homedir(), ".local/bin/ffmpeg") : "ffmpeg";
const args = process.argv.slice(2);
const specPath = args.find(a => !a.startsWith("--"));
if (!specPath) { console.error("usage: voice.mjs <spec.json> [--score wav] [--video mp4]"); process.exit(2); }
const opt = (name, dflt) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : dflt; };
const scorePath = opt("--score", "ad/out/score.wav"), videoPath = opt("--video", "ad/out/kin-ad.mp4");

const KEY = process.env.ELEVENLABS_API_KEY;
if (!KEY) { console.error("ELEVENLABS_API_KEY is not set"); process.exit(1); }

const spec = JSON.parse(fs.readFileSync(specPath, "utf8"));
const outDir = path.join(path.dirname(specPath), "voice");
fs.mkdirSync(outDir, { recursive: true });
const lines = (spec.voiceover || []).filter(l => l && l.text && isFinite(+l.t)).sort((a, b) => a.t - b.t);
if (!lines.length) { console.log("no voiceover lines in spec; nothing to do"); process.exit(0); }

const voice = spec.voice || {};
const VOICE_ID = voice.voice_id || "JBFqnCBsd6RMkjVDRZzb"; // George — warm storyteller
const MODEL = voice.model_id || "eleven_v3";
const STABILITY = [0, 0.5, 1].includes(+voice.stability) ? +voice.stability : 0.5;

function wavFromPcm16(pcm, rate) {
  const h = Buffer.alloc(44);
  h.write("RIFF", 0); h.writeUInt32LE(36 + pcm.length, 4); h.write("WAVE", 8); h.write("fmt ", 12);
  h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write("data", 36); h.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([h, pcm]);
}

async function tts(text, idx) {
  const body = { text, model_id: MODEL, voice_settings: { stability: STABILITY, similarity_boost: 0.8, use_speaker_boost: true } };
  for (const fmt of ["pcm_44100", "mp3_44100_192", "mp3_44100_128"]) {
    const r = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${VOICE_ID}?output_format=${fmt}`, {
      method: "POST", headers: { "xi-api-key": KEY, "Content-Type": "application/json", "Accept": "*/*" }, body: JSON.stringify(body)
    });
    if (!r.ok) { const e = await r.text().catch(() => ""); console.error(`  line ${idx} ${fmt}: HTTP ${r.status} ${e.slice(0, 160)}`); if (r.status === 401 || r.status === 402) throw new Error("ElevenLabs auth/quota"); continue; }
    const buf = Buffer.from(await r.arrayBuffer());
    const raw = path.join(outDir, `line_${idx}.${fmt.startsWith("pcm") ? "wav" : "mp3"}`);
    fs.writeFileSync(raw, fmt.startsWith("pcm") ? wavFromPcm16(buf, 44100) : buf);
    // normalise every line to 48 kHz stereo WAV and measure it
    const wav = path.join(outDir, `line_${idx}.48k.wav`);
    spawnSync(FFMPEG, ["-loglevel", "error", "-y", "-i", raw, "-ar", "48000", "-ac", "2", wav]);
    const probe = spawnSync(FFMPEG, ["-i", wav], { encoding: "utf8" }).stderr.match(/Duration: (\d+):(\d+):([\d.]+)/);
    const dur = probe ? (+probe[1]) * 3600 + (+probe[2]) * 60 + (+probe[3]) : 0;
    return { wav, dur, fmt, chars: text.length };
  }
  throw new Error(`line ${idx}: every output format refused`);
}

const t0 = Date.now();
console.error(`# voice: ${lines.length} lines, model ${MODEL}, voice ${voice.voice_name || VOICE_ID}, stability ${STABILITY}`);
const results = await Promise.all(lines.map((l, i) => tts(l.text, i)));
const manifest = lines.map((l, i) => ({ t: l.t, text: l.text, ...results[i] }));
for (let i = 0; i < manifest.length; i++) {
  const m = manifest[i], next = manifest[i + 1];
  const end = m.t + m.dur;
  console.error(`  ${String(m.t).padStart(5)}s  ${m.dur.toFixed(2)}s  "${m.text}"` + (next && end > next.t ? `  OVERRUNS into next line by ${(end - next.t).toFixed(2)}s` : "") + (end > spec.duration ? "  RUNS PAST THE END" : ""));
}
fs.writeFileSync(path.join(outDir, "manifest.json"), JSON.stringify({ model: MODEL, voice_id: VOICE_ID, stability: STABILITY, lines: manifest }, null, 2));

// one timed voice track: each line delayed to its t, mixed, padded to the film's length
const voTrack = path.join(outDir, "vo.wav");
const inputs = manifest.flatMap(m => ["-i", m.wav]);
const delays = manifest.map((m, i) => `[${i}:a]adelay=${Math.round(m.t * 1000)}|${Math.round(m.t * 1000)}[d${i}]`).join(";");
const mixIn = manifest.map((_, i) => `[d${i}]`).join("");
const filter = `${delays};${mixIn}amix=inputs=${manifest.length}:normalize=0,apad=whole_dur=${spec.duration}[vo]`;
let r = spawnSync(FFMPEG, ["-loglevel", "error", "-y", ...inputs, "-filter_complex", filter, "-map", "[vo]", "-t", String(spec.duration), "-ar", "48000", "-ac", "2", voTrack]);
if (r.status !== 0) { console.error(r.stderr.toString()); process.exit(1); }
console.error(`# voice track: ${voTrack}`);

// mix under the score with ducking, then remux into the video if both exist
if (fs.existsSync(scorePath)) {
  const mixed = path.join(outDir, "mixed.wav");
  r = spawnSync(FFMPEG, ["-loglevel", "error", "-y", "-i", scorePath, "-i", voTrack, "-filter_complex",
    "[0:a][1:a]sidechaincompress=threshold=0.015:ratio=5:attack=30:release=500:makeup=1[duck];[duck][1:a]amix=inputs=2:normalize=0:duration=first[out]",
    "-map", "[out]", "-ar", "48000", "-ac", "2", mixed]);
  if (r.status !== 0) { console.error(r.stderr.toString()); process.exit(1); }
  console.error(`# mixed: ${mixed}`);
  if (fs.existsSync(videoPath)) {
    const final = path.join(path.dirname(specPath), "final.mp4");
    r = spawnSync(FFMPEG, ["-loglevel", "error", "-y", "-i", videoPath, "-i", mixed, "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", final]);
    if (r.status !== 0) { console.error(r.stderr.toString()); process.exit(1); }
    console.error(`# final: ${final}`);
  }
}
console.log(JSON.stringify({ lines: manifest.length, model: MODEL, voice: VOICE_ID, seconds: ((Date.now() - t0) / 1000).toFixed(1), chars: manifest.reduce((a, m) => a + m.chars, 0) }));
