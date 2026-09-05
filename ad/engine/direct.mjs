#!/usr/bin/env node
/**
 * Ad engine v2 — direction. Astra runs the process that made the hand-made
 * film good (see PROCESS.md), and everything that can run at once does:
 *
 *   1. TREATMENT   N candidates in parallel: a director's treatment in prose
 *                  (idea, motif, arc, per-shot direction with numbers, score
 *                  plan) followed by the plan as strict JSON. A judge picks one.
 *   2. CODE        one call per shot, all in parallel, plus one for the score:
 *                  Astra writes `function shot(c)` against the host's `lib`/`dom`
 *                  API, including the entrance from the previous shot and the
 *                  exit into the next. Syntax-checked; failures repaired once.
 *   3. SMOKE       a headless browser seeks every shot at three times; thrown
 *                  errors and slow frames go back to Astra for a repair pass.
 *   4. REVIEW      stills -> contact sheet -> Astra critiques WITH the image ->
 *                  flagged shots rewritten in parallel -> stills again. --rounds N.
 *
 *   EXPLABS_API_KEY=... node ad/engine/direct.mjs --product "..." --audience "..."
 *     [--duration 45] [--treatments 2] [--rounds 1] [--effort high] [--slug x]
 *
 * Output: out/<slug>/{treatment.md, spec.json, modules.js, ad.html,
 *   smoke.json, critique-1.md, contact-1.png, ...}. Then: produce.mjs --spec.
 */
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { callAstra, extractJson } from "./gateway.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..", "..");
const RENDER = path.join(ROOT, "ad", "render.mjs");
const FFMPEG = fs.existsSync(path.join(os.homedir(), ".local/bin/ffmpeg")) ? path.join(os.homedir(), ".local/bin/ffmpeg") : "ffmpeg";

const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };
const o = {
  product: opt("--product", "Onefold, a running shoe made from one material; send it back worn out and it becomes the next pair"),
  audience: opt("--audience", "runners with a drawer of dead shoes they feel bad about"),
  duration: +opt("--duration", 45), treatments: +opt("--treatments", 2), rounds: +opt("--rounds", 1), effort: opt("--effort", "high"), slug: opt("--slug", null)
};
o.slug = o.slug || o.product.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 40);
const OUT = path.join(HERE, "out", o.slug);
fs.mkdirSync(OUT, { recursive: true });
const timings = [];
const log = (...a) => console.error(...a);
async function stage(name, fn) { const t = Date.now(); const r = await fn(); timings.push([name, (Date.now() - t) / 1000]); log(`# ${name}: ${((Date.now() - t) / 1000).toFixed(1)}s`); return r; }

// ---------------------------------------------------------------- the contract Astra codes against
const API = `The host calls your function every frame with c = { scene, light, dom, lib, t, tl, u, dur, shot, prev, next, spec, D }.
  scene, light: 2D contexts of 1920x1080 canvases, cleared before every frame. Imagery on scene; glows, strokes, light and the mark on light.
  t: film time (s). tl: seconds since this shot began. u: tl/dur (0..1). dur: shot length. D: film length.
  shot/prev/next: plan entries {id,start,end,direction,handoffIn,handoffOut,copy}. spec: the plan (palette, motif, tagline, wordmark).
lib (all pure and deterministic):
  W H; col.A col.B col.ink col.muted col.ground (rgb arrays). Colours everywhere accept "A"|"B"|"ink"|"muted"|"ground"|"#rrggbb"|[r,g,b].
  rgba(c,a) mix(c1,c2,u) hex(c) clamp(v,lo,hi) lerp(a,b,u)
  ease(u) entrance curve; easeMark(u); sine(u); linear(u); span(t,a,b,ease?) -> progress 0..1 of t across [a,b]; kf(t,[[t0,v0],[t1,v1],...],ease?) keyframes
  envelope(tl,[[onset,peak],...],atk=0.09,rel=0.26) -> 0..1 (syllable/beat envelopes); rng(seed) -> deterministic () => 0..1
  glow(ctx,x,y,r,color,alpha) soft point light; field(ctx,x,y,r,color,alpha) broad light field (r up to 1400)
  shape(ctx,path,{x,y,size,fill,stroke,strokeWidth,alpha,rotate,scaleX,scaleY,glow,dash}) an SVG path (M L C Q Z only) in a 0..1000 box, centred at x,y, box height = size px
  line(ctx,[[x,y],...],{color,width,alpha,glow,close}); dot(ctx,x,y,r,color,alpha,glow)
  text(ctx,str,{x,y,size,color,align,baseline,font:"mono"|"serif"|"sans",italic,alpha}) for small labels only; story copy goes through dom.copy
  portrait(ctx,"them"|"you",{x,y,w,h},{alpha,zoom,dx,dy}) a person out of focus; edge(ctx,rect,color,opacity,depth) the edge light inside a rect
  planet(ctx,{cx,cy,R,lat,lon,alpha}) -> cam; route(ctx,cam,fromV,toV,u0,u1,{cx,cy,R,color,alpha,width}) -> head {x,y,vis}; city("LONDON") -> {v,lat,lon}; project(cam,v,cx,cy,R)
  mark(ctx,cx,cy,r,sep,alphaInk,alphaAccent,overlapAlpha,fade) the brand mark: ink disc left, accent-A disc right; WIN={x:120,y:156,w:1008,h:744}
dom (the type layer; call each frame the element should be visible):
  copy(pos,text,{size,y,tIn,tOut,sub,color}) pos "center"|"side"|"left"|"below"; sizes from the system 88/72/64/56; fades in over 480 ms from film time tIn and out over 280 ms from tOut
  window(rect,alpha,"a"|"b") window chrome; content(rect) -> the rect below its title strip
  wordmark(text,{size,top,alpha}) tagline(text,{size,top,alpha}) cta([lines],alpha) number(text,alpha)
RULES: a pure function of c: no state outside the function, no Math.random, no Date, no timers, no DOM, no network, no images. Draw your own entrance (continue from prev.handoffOut) and exit (prepare next.handoffIn); never a plain fade to black unless directed. Keep the safe area: copy inside 120 px margins. Cost: under 3 ms per frame: no loops over 1500 iterations, no shadowBlur on shapes larger than 300 px, no ctx.filter. Under 140 lines.`;

const SCORE_API = `function score(h, D, SHOTS, SPEC) builds the whole score once on an offline WebAudio graph; every event is scheduled in film seconds.
  h.tone(freq, at, {dur, level, atk, dec, rel, sus, lp, pan, partials:[[mult,amp,type]]}) an ADSR note (level 0.01..0.06)
  h.burst(at, {dur, level, f, fTo, q, type:"bandpass"|"lowpass", atk, pan}) a filtered-noise event: tick, breath, whoosh (level 0.005..0.03)
  h.pad(freqs[], from, to, {level, lp, type, fadeIn, fadeOut}) a sustained bed (level 0.008..0.02)
  h.N: note frequencies C2..A5 (e.g. h.N.D3, h.N.Fs3, h.N.A4). h.ctx is the AudioContext, h.dry the input bus, if you need raw nodes (deterministic only).
RULES: deterministic; no Math.random; leave silence where the treatment says; keep levels in the ranges above (loudness is normalised afterwards, peaks are not); sync hits to the beat list; under 80 lines.`;

const ROSTER = `JBFqnCBsd6RMkjVDRZzb George: warm storyteller, British | nPczCjzI2devNBz1zQrb Brian: deep, comforting, American | pFZP5JQG7iQjIQuC4Bku Lily: velvety, British | onwK4e9ZLuTAKqWW03F9 Daniel: steady broadcaster, British | cjVigY5qzO86Huf0OWal Eric: smooth, trustworthy, American | EXAVITQu4vr4xnSDxMaL Sarah: mature, reassuring, American | SAz9YHcvj6GT2YYXdXww River: relaxed, neutral | XrExE9yKIg1WjnnlVkGX Matilda: knowledgeable, American | auq43ws1oslv0tO4BDa7 Adam Stone: smooth, relaxed, British | pqHfZKP75CvOlQylNhV4 Bill: wise, mature, American`;
const ANGLES = ["lead with the feeling the audience already has, then one quiet move", "lead with the product's single move as an image; let the tension be implied", "an unexpected metaphor; the product resolves it", "almost wordless: light and one object carry it", "the day after: life once the problem is gone"];

// ---------------------------------------------------------------- prompts
function treatmentPrompt(angle) {
  return `You are a world-class brand-film director (the restraint of the quietest Apple product films) and a creative technologist. Write the director's treatment for a ${o.duration}-second animated brand film, then the plan as strict JSON.

PRODUCT: ${o.product}
AUDIENCE: ${o.audience}
ANGLE: ${angle}

The film is pure code animation: near-black ground, cream type, two accent colours (A = the product's own warmth or primary; B = the cold, the other, the problem), light, drawn objects (SVG silhouettes), no footage. Apple-quiet. One governing idea, felt not explained. Most shots wordless; copy spare and verbatim (<= 1 short line per shot, several shots none); plain words; numbers only if they ARE the point. The renderer draws: light fields and glows, SVG-path objects with motion, strokes and dots, small labels, out-of-focus people in call windows (only for products about people talking), a lit planet (only for distance), the brand mark (two light discs) and an end card.

Write, in this order:
TREATMENT (prose, 350-600 words): 1) the tension in one sentence; 2) the idea in one line; 3) ONE recurring visual motif (a light behaviour or drawn gesture) and exactly where it returns; 4) the arc in 4 beats; 5) shot-by-shot direction, 6-9 contiguous shots: for each, id, times, what we see, how it MOVES (easing, durations in ms, positions in px on a 1920x1080 stage), the light, and how it hands off to the next shot (what element carries over, never a fade to black except before the mark if you want silence); 6) the score: harmonic plan, timbres, and a beat list (times of hits synced to the picture); 7) type: which lines, sizes from 88/72/64/56, positions; 8) the voice: cast ONE from the roster and write 0-4 narration lines (<= 12 words, timed, not repeating on-screen copy): ${ROSTER}

Then, on its own line, the word PLAN, then STRICT JSON only:
{"product":"...","tension":"...","idea":"...","tagline":"<=6 words","wordmark":"the brand name as shown","palette":{"ground":"#05060a","ink":"#f3f1ec","accentA":"#RRGGBB","accentB":"#RRGGBB"},
 "motif":{"name":"...","description":"how it is drawn and moves","returns":["S1","S4","S7"]},
 "voice":{"voice_id":"...","voice_name":"...","stability":0.5,"direction":"one line"},"voiceover":[{"t":9,"text":"..."}],
 "score":{"harmony":"...","timbres":"...","beats":[{"t":13.0,"what":"..."}]},
 "duration":${o.duration},
 "shots":[{"id":"S1","start":0,"end":4,"title":"3 words","direction":"the full direction for this shot from the treatment, with numbers","handoffIn":"what is on screen as this shot begins (from the previous)","handoffOut":"what this shot leaves on screen for the next","copy":"optional verbatim line or null","primitive":"title|glow|shape|portrait|duo|planet|mark|cta","params":{}}]}
Rules for shots: contiguous (each start = previous end), first start 0, last end ${o.duration}, each >= 2.5 s, the last two are "mark" then "cta". "primitive"/"params" are only a fallback; keep them simple and valid (shape params: path in a 0..1000 box, fill, stroke, size, x 0..1, y 0..1; glow: color A|B|ink, from, to, x, y, radius; title: copy, size; mark: wordmark; cta: lines[]).`;
}
function judgePrompt(cands) {
  const brief = cands.map((c, i) => `#${i}: idea="${c.plan.idea}" motif="${c.plan.motif?.name}: ${c.plan.motif?.description}" tagline="${c.plan.tagline}" shots=${c.plan.shots.map(s => s.title).join(" > ")}`).join("\n");
  return `Pick the strongest treatment for "${o.product}" (audience: ${o.audience}). Judge: one clear idea, emotional truth, a motif that can carry the film, transitions that mean something, restraint, a payoff that earns the name. STRICT JSON only: {"pick": <index>, "why": "<= 20 words"}\n${brief}`;
}
function shotPrompt(plan, i, treatment) {
  const s = plan.shots[i], prev = plan.shots[i - 1], next = plan.shots[i + 1];
  return `You are a senior creative technologist implementing ONE shot of a brand film from the director's treatment, as production Canvas 2D code. Output ONLY one JavaScript function in a single \`\`\`js fence: function shot(c) { ... }. No prose.

FILM: ${plan.idea}  TAGLINE: ${plan.tagline}  WORDMARK: ${plan.wordmark}
PALETTE: A=${plan.palette.accentA} (${plan.palette.aMeans || "the product's warmth"}), B=${plan.palette.accentB} (${plan.palette.bMeans || "the cold / the problem"}), ink cream, ground near-black.
MOTIF: ${plan.motif?.name}: ${plan.motif?.description} (returns in ${(plan.motif?.returns || []).join(", ")})
TYPE: sizes 88/72/64/56; copy fades in 480 ms, out 280 ms; safe area 120 px.

THIS SHOT ${s.id} "${s.title}" — film time ${s.start}s to ${s.end}s (dur ${(s.end - s.start).toFixed(2)}s)
DIRECTION: ${s.direction}
COPY (verbatim, or none): ${s.copy ? JSON.stringify(s.copy) : "none"}
HAND-OFF IN (what the previous shot leaves on screen; continue from it): ${s.handoffIn || (prev ? prev.handoffOut : "black")}
HAND-OFF OUT (what you must leave on screen for the next shot): ${s.handoffOut || "as directed"}
PREVIOUS SHOT: ${prev ? `${prev.id} "${prev.title}": ${prev.direction}` : "none (film start)"}
NEXT SHOT: ${next ? `${next.id} "${next.title}": ${next.direction}` : "none (film end: fade everything to ground over the last 0.8 s)"}
${s.primitive === "mark" ? "This is the MARK shot: use lib.mark for the two discs (grow r from ~20 to ~280 over 850 ms with lib.easeMark; sep 180 at (960,340)), dom.wordmark for the name (204 px, top ~640, in from +1.0s), dom.tagline (46 px, top ~860, in from +2.2s)." : ""}
${s.primitive === "cta" ? "This is the END CARD: settle the mark small (r 182, sep 117 at (960,285)) with dom.wordmark 152 px top 525, dom.tagline 42 px top 677, and dom.cta([...lines]) fading in; hold still; fade all to ground over the last 0.8 s." : ""}

THE API
${API}

Timing tip: express every motion as a function of c.tl or c.t with lib.span/lib.kf; use c.tl for beats inside the shot. Use dom.copy with tIn/tOut in FILM time (c.shot.start + offset).`;
}
function scorePrompt(plan) {
  const beats = (plan.score?.beats || []).map(b => `${b.t}s ${b.what}`).join("; ");
  const shots = plan.shots.map(s => `${s.id} ${s.start}-${s.end} ${s.title}`).join("; ");
  return `You are a film composer and sound designer writing a synthesized score in WebAudio for a ${o.duration}-second brand film. Output ONLY one JavaScript function in a single \`\`\`js fence: function score(h, D, SHOTS, SPEC) { ... }. No prose.

FILM: ${plan.idea}. Tone: quiet, restrained, one idea. HARMONY: ${plan.score?.harmony || "a low open fifth resolving at the name"}. TIMBRES: ${plan.score?.timbres || "sines, a soft triangle, filtered noise"}.
SHOTS: ${shots}
BEATS (sync hits to these): ${beats || "the shot boundaries, and the name at the mark shot"}
VOICE LINES (leave room under them): ${(plan.voiceover || []).map(v => `${v.t}s "${v.text}"`).join("; ") || "none"}

THE API
${SCORE_API}`;
}
function critiquePrompt(plan, treatment, round) {
  return `You wrote this treatment and are now at the rough-cut screening of round ${round}. Attached is a contact sheet of 10 stills, left to right, top to bottom, at evenly spaced times across the ${o.duration}s film (${plan.shots.map(s => `${s.id} ${s.start}-${s.end}`).join(", ")}).

TREATMENT (yours):
${treatment.slice(0, 5000)}

Judge the stills against your own treatment: composition, scale, legibility of copy, whether the motif reads, whether the object/light reads at contact-sheet size, palette discipline, safe areas, anything broken or blank. Return STRICT JSON only:
{"notes":[{"shot":"S3","severity":3,"note":"what is wrong","fix":"the exact change in numbers"}], "rewrite":["S3","S5"], "keep":["S1"], "verdict":"<= 25 words"}
At most 6 notes; "rewrite" lists only shots whose code must change (max 4); severity 3 = must fix.`;
}
function rewritePrompt(plan, i, code, notes) {
  return `${shotPrompt(plan, i)}

YOUR CURRENT CODE FOR THIS SHOT:
\`\`\`js
${code}
\`\`\`
REVIEW NOTES TO APPLY (the director saw the stills):
${notes.map(n => `- [severity ${n.severity}] ${n.note} -> ${n.fix}`).join("\n")}
Return the complete corrected function only.`;
}
function repairPrompt(plan, i, code, error) {
  return `${shotPrompt(plan, i)}

YOUR CURRENT CODE THREW AT RUNTIME:
${error}
\`\`\`js
${code}
\`\`\`
Return the complete fixed function only.`;
}

// ---------------------------------------------------------------- helpers
const fenced = txt => { const m = txt.match(/```(?:js|javascript)?\s*([\s\S]*?)```/); return (m ? m[1] : txt).trim(); };
function checkFn(code, name) {
  // must be a single function declaration; compile it in isolation
  if (!/^\s*function\s+\w*\s*\(/.test(code)) throw new Error(`${name}: not a function declaration`);
  new Function(`"use strict"; ${code}; return ${code.match(/function\s+(\w+)/)[1]};`)();
  return code;
}
function repairSpec(plan) {
  const HEX = /^#[0-9a-fA-F]{6}$/, P = ["title", "glow", "shape", "portrait", "duo", "planet", "mark", "cta"];
  plan.duration = o.duration;
  plan.palette = Object.assign({ ground: "#05060a", ink: "#f3f1ec", accentA: "#EDB580", accentB: "#7F91A3" }, plan.palette || {});
  for (const k of ["ground", "ink", "accentA", "accentB"]) if (!HEX.test(plan.palette[k] || "")) plan.palette[k] = { ground: "#05060a", ink: "#f3f1ec", accentA: "#EDB580", accentB: "#7F91A3" }[k];
  if (!Array.isArray(plan.shots) || plan.shots.length < 3) throw new Error("plan has too few shots");
  plan.shots.sort((a, b) => (+a.start || 0) - (+b.start || 0));
  let t = 0;
  plan.shots.forEach((s, i) => { s.id = s.id || `S${i + 1}`; if (!P.includes(s.primitive)) s.primitive = "title"; s.params = s.params || {}; const d = Math.max(2.5, (+s.end || t + 4) - (+s.start || t) || 4); s.start = t; s.end = t = +(t + d).toFixed(3); if (s.copy === "null" || s.copy === "") s.copy = null; });
  const k = o.duration / plan.shots[plan.shots.length - 1].end;
  for (const s of plan.shots) { s.start = +(s.start * k).toFixed(3); s.end = +(s.end * k).toFixed(3); }
  plan.shots[0].start = 0; plan.shots[plan.shots.length - 1].end = o.duration;
  plan.voiceover = (Array.isArray(plan.voiceover) ? plan.voiceover : []).filter(v => v && v.text && isFinite(+v.t)).map(v => ({ t: +v.t, text: String(v.text).slice(0, 140) }));
  if (!plan.voice || !ROSTER.includes(plan.voice.voice_id || "")) plan.voice = { voice_id: "JBFqnCBsd6RMkjVDRZzb", voice_name: "George", stability: 0.5 };
  plan.voice.stability = [0, 0.5, 1].includes(+plan.voice.stability) ? +plan.voice.stability : 0.5;
  plan.wordmark = plan.wordmark || o.product.split(/[,:]/)[0].trim();
  return plan;
}
function writeModules(mods) {
  const body = Object.entries(mods).map(([id, code]) => `__AD_MODULES__[${JSON.stringify(id)}] = (function(){ ${code}\n return ${code.match(/function\s+(\w+)/)[1]}; })();`).join("\n\n");
  fs.writeFileSync(path.join(OUT, "modules.js"), `window.__AD_MODULES__ = {};\n${body}\n`);
}
function run(cmd, args, echo = false) {
  return new Promise((res, rej) => { const p = spawn(cmd, args, { stdio: ["ignore", "pipe", "pipe"], env: process.env }); let out = "", err = ""; p.stdout.on("data", d => { out += d; if (echo) process.stderr.write(d); }); p.stderr.on("data", d => { err += d; if (echo) process.stderr.write(d); }); p.on("close", c => c === 0 ? res(out) : rej(new Error(`${path.basename(args[0] || cmd)} exited ${c}\n${(err || out).slice(-600)}`))); });
}
async function build() { await run(process.execPath, [path.join(HERE, "build-ad.mjs"), path.join(OUT, "spec.json")]); return path.join(OUT, "ad.html"); }
async function smoke(page) { const out = await run(process.execPath, [path.join(HERE, "smoke.mjs"), page]); const r = JSON.parse(out.trim().split("\n").pop()); fs.writeFileSync(path.join(OUT, "smoke.json"), JSON.stringify(r, null, 2)); return r; }
async function stills(page, round) {
  const dir = path.join(OUT, "work", `stills-${round}`);
  await run(process.execPath, [RENDER, "--page", page, "--stills", "10", "--fps", "30", "--out", dir]);
  const sheet = path.join(OUT, `contact-${round}.png`);
  const r = spawnSync(FFMPEG, ["-loglevel", "error", "-y", "-i", path.join(dir, "stills", "still_%02d.png"), "-vf", "scale=512:-1,tile=5x2", sheet], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(r.stderr);
  return sheet;
}

// ---------------------------------------------------------------- main
const T0 = Date.now();
// --resume: pick up an existing out/<slug> (treatment, plan, modules) and skip
// straight to review. --notes <file.json>: a human director's notes
// [{shot, severity, note, fix}] applied through the same rewrite path as
// Astra's own critique, instead of a critique round.
const resume = argv.includes("--resume");
const notesPath = opt("--notes", null);
log(`# direct: "${o.product}" -> ${o.slug} (${o.duration}s, ${o.treatments} treatments, ${o.rounds} review round${o.rounds === 1 ? "" : "s"}${resume ? ", resume" : ""}${notesPath ? ", notes" : ""})`);

let treatment, plan;
const mods = {};
if (resume) {
  treatment = fs.readFileSync(path.join(OUT, "treatment.md"), "utf8");
  plan = JSON.parse(fs.readFileSync(path.join(OUT, "spec.json"), "utf8"));
  o.duration = plan.duration;
  const src = fs.readFileSync(path.join(OUT, "modules.js"), "utf8");
  for (const m of src.matchAll(/__AD_MODULES__\["([^"]+)"\] = \(function\(\)\{ ([\s\S]*?)\n return \w+; \}\)\(\);/g)) mods[m[1]] = m[2];
  log(`# resumed: ${plan.shots.length} shots, ${Object.keys(mods).length} modules`);
} else {
// 1. treatments in parallel, judge
({ treatment, plan } = await stage("treatments", async () => {
  const rs = await Promise.allSettled(Array.from({ length: o.treatments }, (_, i) => callAstra(treatmentPrompt(ANGLES[i % ANGLES.length]), { effort: o.effort, label: `treat${i}` })));
  const cands = [];
  rs.forEach((r, i) => {
    if (r.status !== "fulfilled") { log(`# treat${i} failed: ${r.reason.message}`); return; }
    const txt = r.value.text, cut = txt.lastIndexOf("PLAN");
    try { const plan = repairSpec(extractJson(cut >= 0 ? txt.slice(cut) : txt)); cands.push({ treatment: (cut >= 0 ? txt.slice(0, cut) : txt).trim(), plan }); }
    catch (e) { log(`# treat${i} unusable: ${e.message}`); }
  });
  if (!cands.length) throw new Error("no usable treatment");
  let pick = 0;
  if (cands.length > 1) { try { const j = extractJson((await callAstra(judgePrompt(cands), { effort: "low", label: "judge", timeoutMs: 120000 })).text); pick = Math.min(cands.length - 1, Math.max(0, +j.pick || 0)); log(`# judge picked #${pick}: ${j.why}`); } catch (e) { log(`# judge failed: ${e.message}`); } }
  cands.forEach((c, i) => fs.writeFileSync(path.join(OUT, `treatment-${i}.md`), c.treatment + "\n\nPLAN\n" + JSON.stringify(c.plan, null, 2)));
  fs.writeFileSync(path.join(OUT, "treatment.md"), cands[pick].treatment);
  fs.writeFileSync(path.join(OUT, "spec.json"), JSON.stringify(cands[pick].plan, null, 2));
  return cands[pick];
}));
log(`# idea: ${plan.idea}\n# motif: ${plan.motif?.name}\n# shots: ${plan.shots.map(s => `${s.id} ${s.title}`).join(" > ")}`);

// 2. code: every shot + the score, in parallel; syntax-check; repair once
await stage(`code x${plan.shots.length + 1}`, async () => {
  const jobs = plan.shots.map((s, i) => callAstra(shotPrompt(plan, i, treatment), { effort: o.effort, label: s.id }).then(r => [s.id, fenced(r.text), i]));
  jobs.push(callAstra(scorePrompt(plan), { effort: o.effort, label: "score" }).then(r => ["score", fenced(r.text), -1]));
  const rs = await Promise.allSettled(jobs);
  const bad = [];
  for (const r of rs) {
    if (r.status !== "fulfilled") { log(`# code call failed: ${r.reason.message}`); continue; }
    const [id, code, i] = r.value;
    try { mods[id] = checkFn(code, id); } catch (e) { log(`# ${id} syntax: ${e.message}`); bad.push([id, code, i, e.message]); }
  }
  if (bad.length) {
    const fixes = await Promise.allSettled(bad.map(([id, code, i, err]) => callAstra(id === "score" ? `${scorePrompt(plan)}\n\nYOUR CODE FAILED TO COMPILE: ${err}\n\`\`\`js\n${code}\n\`\`\`\nReturn the complete fixed function only.` : repairPrompt(plan, i, code, "SyntaxError: " + err), { effort: "high", label: `${id}-fix` }).then(r => [id, fenced(r.text)])));
    for (const f of fixes) if (f.status === "fulfilled") { const [id, code] = f.value; try { mods[id] = checkFn(code, id); } catch (e) { log(`# ${id} still broken; the fallback primitive will render it`); } }
  }
  writeModules(mods);
});

// 3. smoke test; repair what throws or is slow
var page0 = await build();
await stage("smoke", async () => {
  let page = page0;
  let r = await smoke(page);
  log(`# smoke: ${r.errors.length} errors, worst frame ${r.worstMs} ms (${r.worstShot}), blank shots: ${r.blank.join(",") || "none"}`);
  const toFix = new Map();
  for (const e of r.errors) toFix.set(e.shot, `RuntimeError at t=${e.t}: ${e.error}`);
  for (const [id, ms] of Object.entries(r.msByShot)) if (ms > 12 && mods[id]) toFix.set(id, (toFix.get(id) || "") + ` Too slow: ${ms} ms/frame (budget 3 ms): remove per-frame shadowBlur/filters, cut loop counts, cache nothing across frames.`);
  for (const id of r.blank) if (mods[id] && !toFix.has(id)) toFix.set(id, "The frame renders BLANK (nothing visible) at mid-shot: check alphas, coordinates (0..1920 x 0..1080), colour names, and that you draw on c.scene / c.light.");
  if (toFix.size) {
    const fixes = await Promise.allSettled([...toFix].map(([id, err]) => { const i = plan.shots.findIndex(s => s.id === id); return callAstra(id === "score" ? `${scorePrompt(plan)}\n\nYOUR CODE THREW: ${err}\n\`\`\`js\n${mods[id]}\n\`\`\`\nReturn the complete fixed function only.` : repairPrompt(plan, i, mods[id], err), { effort: "high", label: `${id}-repair` }).then(r => [id, fenced(r.text)]); }));
    for (const f of fixes) if (f.status === "fulfilled") { const [id, code] = f.value; try { mods[id] = checkFn(code, id); } catch (e) { log(`# ${id} repair did not compile`); } }
    writeModules(mods); page = await build(); r = await smoke(page);
    log(`# smoke 2: ${r.errors.length} errors, worst frame ${r.worstMs} ms, blank: ${r.blank.join(",") || "none"}`);
  }
});
} // end of the authoring stages skipped by --resume
let page = resume ? await build() : page0;

// 4. review rounds: stills -> critique with the image -> rewrite flagged shots
// (with --notes, the human's notes replace the critique for round 1)
const humanNotes = notesPath ? JSON.parse(fs.readFileSync(notesPath, "utf8")) : null;
for (let round = 1; round <= o.rounds; round++) {
  await stage(`review ${round}`, async () => {
    let crit;
    if (humanNotes && round === 1) {
      crit = { notes: humanNotes, rewrite: [...new Set(humanNotes.map(n => n.shot))], verdict: "director's notes" };
    } else {
      const sheet = await stills(page, round);
      const img = "data:image/png;base64," + fs.readFileSync(sheet).toString("base64");
      try { crit = extractJson((await callAstra(critiquePrompt(plan, treatment, round), { effort: o.effort, label: `critique${round}`, image: img })).text); }
      catch (e) { log(`# critique failed: ${e.message}`); return; }
    }
    fs.writeFileSync(path.join(OUT, `critique-${round}${humanNotes && round === 1 ? "-notes" : ""}.md`), JSON.stringify(crit, null, 2));
    log(`# critique ${round}: ${crit.verdict || ""}\n` + (crit.notes || []).map(n => `#   ${n.shot} [${n.severity}] ${n.note}`).join("\n"));
    const rewrite = (crit.rewrite || []).filter(id => mods[id]).slice(0, 4);
    if (!rewrite.length) return;
    const fixes = await Promise.allSettled(rewrite.map(id => { const i = plan.shots.findIndex(s => s.id === id); const notes = (crit.notes || []).filter(n => n.shot === id); return callAstra(rewritePrompt(plan, i, mods[id], notes.length ? notes : [{ severity: 2, note: crit.verdict || "improve", fix: "apply the treatment more faithfully" }]), { effort: o.effort, label: `${id}-rw${round}` }).then(r => [id, fenced(r.text)]); }));
    for (const f of fixes) if (f.status === "fulfilled") { const [id, code] = f.value; try { mods[id] = checkFn(code, id); } catch (e) { log(`# ${id} rewrite did not compile; kept the previous version`); } }
    writeModules(mods); page = await build();
    const r = await smoke(page); log(`# smoke after review ${round}: ${r.errors.length} errors, worst ${r.worstMs} ms`);
  });
}
const finalSheet = await stills(page, "final");

const total = (Date.now() - T0) / 1000;
log("\n# stage                       seconds");
for (const [n, s] of timings) log(`# ${n.padEnd(28)} ${s.toFixed(1).padStart(7)}`);
log(`# ${"TOTAL".padEnd(28)} ${total.toFixed(1).padStart(7)}`);
console.log(JSON.stringify({ slug: o.slug, dir: OUT, spec: path.join(OUT, "spec.json"), contact: finalSheet, seconds: +total.toFixed(1), idea: plan.idea, tagline: plan.tagline, shots: plan.shots.length, modules: Object.keys(mods).length }));
