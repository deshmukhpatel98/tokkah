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
  duration: +opt("--duration", 45), treatments: +opt("--treatments", 2), rounds: +opt("--rounds", 1), effort: opt("--effort", "high"), slug: opt("--slug", null),
  tempo: opt("--tempo", "fast"),                       // fast (default) | measured
  words: +opt("--words", 0),                           // narration budget; 0 = duration x 2.2
  productNotes: opt("--product-notes", "")             // optional: how the product looks
};
o.words = o.words || Math.round(o.duration * 2.2);
const FAST = o.tempo !== "measured";
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
  shape(ctx,path,{x,y,size,fill,stroke,strokeWidth,alpha,rotate,scaleX,scaleY,glow,dash}) one SVG path in a 0..1000 box, centred at x,y, box height = size px
  shapes(ctx,layers,{x,y,size,alpha,rotate,scaleX,scaleY,only:[tags],skip:[tags]}) several layers {tag,path,fill,stroke,strokeWidth,alpha,glow} under one transform
  product(ctx,{x,y,size,alpha,rotate,scaleX,scaleY,only,skip}) THE PRODUCT, drawn from the plan's product illustration, identical in every shot; size = box height px; only/skip select layer tags (e.g. only:["outline"]). Prefer this over drawing the product yourself.
  fills may be a colour, or a gradient in box coordinates: {linear:[x0,y0,x1,y1],stops:[[0,"A"],[1,"#2a1a10"]]} or {radial:[cx,cy,r0,r1],stops:[...]}
  camera moves: wrap drawing in ctx.save(); ctx.translate(cx,cy); ctx.scale(k,k); ctx.translate(-cx,-cy); ... ctx.restore() for push-ins and pans of the whole scene (both canvases)
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

const ROSTER = `JBFqnCBsd6RMkjVDRZzb George: warm storyteller, British | nPczCjzI2devNBz1zQrb Brian: deep, resonant, comforting, American | pFZP5JQG7iQjIQuC4Bku Lily: velvety, British | onwK4e9ZLuTAKqWW03F9 Daniel: steady broadcaster, British | cjVigY5qzO86Huf0OWal Eric: smooth, trustworthy, American | EXAVITQu4vr4xnSDxMaL Sarah: mature, reassuring, confident, American | IKne3meq5aSn9XLyUdCD Charlie: deep, confident, energetic, Australian | TX3LPaxmHKxFdv7VOQHJ Liam: energetic, young, American | CwhRBWXzGAHq8TQ4Fs17 Roger: laid-back, resonant, American | bIHbv24MWmeRgasZH58o Will: relaxed optimist, American | cgSgspJ2msm6clMCkdW9 Jessica: playful, bright, warm, American | iP95p4xoKVk53GoZ742B Chris: charming, down-to-earth, American | pNInz6obpgDQGcFmaJgB Adam: dominant, firm, American | XrExE9yKIg1WjnnlVkGX Matilda: knowledgeable, professional, American`;
const ANGLES = ["lead with the feeling the audience already has, then one quiet move", "lead with the product's single move as an image; let the tension be implied", "an unexpected metaphor; the product resolves it", "almost wordless: light and one object carry it", "the day after: life once the problem is gone"];

// ---------------------------------------------------------------- prompts
function treatmentPrompt(angle) {
  const pace = FAST
    ? `PACE: fast and immersive. ${Math.round(o.duration / 3.2)}-${Math.round(o.duration / 2.4)} shots for ${o.duration} s: most 2-3.5 s, a few 1.2-2 s beats; something new must enter or change every 2-3 s; motion durations 240-700 ms; whole-scene camera moves (push-ins, pans, a snap zoom) are welcome; cut on the beats of the score; the film never sits still and never fades to black except at the very end.`
    : `PACE: measured. 6-9 shots; slow, confident motion (600-1400 ms); silence used as a beat.`;
  const narration = `NARRATION LEADS. Write the narrator's script FIRST: about ${o.words} words in ${Math.round(o.words / 11)}-${Math.round(o.words / 7)} lines, timed in seconds, covering the whole film with gaps under 1.5 s (the first line starts by 0.6 s; the last line lands the tagline or the offer). The script sells the product concretely: what it is, what it does, why it matters, the offer, the name. Spoken, direct, present tense, no jargon. The picture serves the words: every line has a visual event on or just before its onset. On-screen copy is separate and sparer (short lines that punctuate, never the same words as the narration). Cast the voice for this energy from the roster.`;
  const productRule = `THE PRODUCT IS THE STAR. First describe how it looks in 4-6 concrete visual traits (form, material, colour, distinguishing details${o.productNotes ? `; the maker says: ${o.productNotes}` : ""}). The product itself must be on screen for at least 40% of the film, including one HERO shot where it fills at least 60% of the frame height, lit, with material and detail, and one shot of it in use or in its world. Every shot draws it through lib.product (one shared illustration), so it is identical everywhere; the motif should live IN the product (a detail of it, its silhouette, its light), not beside it.`;
  return `You are a world-class commercial director and creative technologist. Write the director's treatment for a ${o.duration}-second animated brand film, then the plan as strict JSON.

PRODUCT: ${o.product}
AUDIENCE: ${o.audience}
ANGLE: ${angle}

The film is pure code animation: a near-black ground, cream type, two accent colours (A = the product's own colour/warmth; B = the cold, the other, the problem), light, drawn objects as layered SVG with gradients, no footage. Confident and modern, not startup-loud; one governing idea, but SHOWN through the product, not implied around it.
${pace}
${narration}
${productRule}
The renderer draws: the product (lib.product), light fields and glows, layered SVG objects with gradient fills, strokes and dots, camera moves, small labels, out-of-focus people in call windows (only for products about people talking), a lit planet (only for distance), the brand mark and an end card.

Write, in this order:
TREATMENT (prose, 400-700 words): 1) the tension in one sentence; 2) the idea in one line; 3) the product's appearance (the 4-6 traits); 4) ONE recurring visual motif and exactly where it returns; 5) the narration script, line by line with times; 6) shot-by-shot direction, contiguous shots: for each, id, times, what we see (say when the product is on screen and how large), how it MOVES (easing, durations in ms, positions in px on a 1920x1080 stage, camera moves), the light, which narration line it carries, and how it hands off to the next shot; 7) the score: tempo, pulse, harmonic plan, timbres, and a beat list synced to cuts; 8) type: which on-screen lines, sizes from 88/72/64/56; 9) the voice: cast ONE from the roster: ${ROSTER}

Then, on its own line, the word PLAN, then STRICT JSON only:
{"product":"...","tension":"...","idea":"...","tagline":"<=6 words","wordmark":"the brand name as shown","tempo":"${o.tempo}",
 "palette":{"ground":"#05060a","ink":"#f3f1ec","accentA":"#RRGGBB","accentB":"#RRGGBB"},
 "productDescription":{"form":"...","material":"...","colour":"...","details":["...","..."]},
 "motif":{"name":"...","description":"how it is drawn and moves","returns":["S1","S5","S9"]},
 "voice":{"voice_id":"...","voice_name":"...","stability":0.5,"direction":"one line of read direction"},
 "voiceover":[{"t":0.6,"text":"..."}],
 "score":{"bpm":<number or null>,"harmony":"...","timbres":"...","beats":[{"t":2.0,"what":"..."}]},
 "duration":${o.duration},
 "shots":[{"id":"S1","start":0,"end":2.6,"title":"3 words","direction":"the full direction for this shot from the treatment, with numbers","handoffIn":"what is on screen as this shot begins","handoffOut":"what this shot leaves on screen for the next","copy":"optional verbatim on-screen line or null","primitive":"title|glow|shape|portrait|duo|planet|mark|cta","params":{}}]}
Rules for shots: contiguous (each start = previous end), first start 0, last end ${o.duration}, each >= ${FAST ? 1.2 : 2.5} s, the last two are "mark" then "cta". Voiceover lines must not overlap: allow at least 0.35 s per word plus 0.3 s between lines. "primitive"/"params" are only a fallback; keep them simple and valid.`;
}
function judgePrompt(cands) {
  const brief = cands.map((c, i) => `#${i}: idea="${c.plan.idea}" motif="${c.plan.motif?.name}: ${c.plan.motif?.description}" tagline="${c.plan.tagline}" shots=${c.plan.shots.map(s => s.title).join(" > ")}`).join("\n");
  return `Pick the strongest treatment for "${o.product}" (audience: ${o.audience}). Judge: one clear idea SHOWN through the product (is the product itself on screen, large, recognisable?), a narration that sells concretely and covers the film, pace (does something change every 2-3 s?), a motif that can carry the film, transitions that mean something, a payoff that earns the name. STRICT JSON only: {"pick": <index>, "why": "<= 20 words"}\n${brief}`;
}
function shotPrompt(plan, i, treatment) {
  const s = plan.shots[i], prev = plan.shots[i - 1], next = plan.shots[i + 1];
  const vo = (plan.voiceover || []).filter(v => v.t < s.end && v.t >= s.start - 1.5).map(v => `  ${v.t}s "${v.text}"`).join("\n");
  const pd = plan.productDescription ? `${plan.productDescription.form}; ${plan.productDescription.material}; ${plan.productDescription.colour}; ${(plan.productDescription.details || []).join(", ")}` : "";
  return `You are a senior creative technologist implementing ONE shot of a brand film from the director's treatment, as production Canvas 2D code. Output ONLY one JavaScript function in a single \`\`\`js fence: function shot(c) { ... }. No prose.

FILM: ${plan.idea}  TAGLINE: ${plan.tagline}  WORDMARK: ${plan.wordmark}  TEMPO: ${plan.tempo || o.tempo}
PALETTE: A=${plan.palette.accentA} (the product's own colour), B=${plan.palette.accentB} (the cold / the problem), ink cream, ground near-black.
THE PRODUCT: ${pd || o.product}. Draw it ONLY with lib.product(ctx, {x, y, size, alpha, rotate, only, skip}) — never your own approximation; size is the box height in px (the hero shot: 650-800). Layer tags available in the illustration: ${(plan.productDrawing?.layers || []).map(l => l.tag).filter(Boolean).join(", ") || "outline, body, sole, detail, highlight, shadow (typical)"}.
MOTIF: ${plan.motif?.name}: ${plan.motif?.description} (returns in ${(plan.motif?.returns || []).join(", ")})
TYPE: sizes 88/72/64/56; copy fades in 480 ms, out 280 ms; safe area 120 px.
${FAST ? "PACE: fast. Something must change every 2-3 s inside this shot; motion 240-700 ms with lib.ease; camera push-ins/pans via ctx.save/translate/scale; no dead frames; no fade to black." : "PACE: measured; slow confident motion."}

THIS SHOT ${s.id} "${s.title}" — film time ${s.start}s to ${s.end}s (dur ${(s.end - s.start).toFixed(2)}s)
DIRECTION: ${s.direction}
NARRATION heard during this shot (the picture must serve these words; put a visual event on each line's onset):
${vo || "  (none in this window)"}
ON-SCREEN COPY (verbatim, or none): ${s.copy ? JSON.stringify(s.copy) : "none"}
HAND-OFF IN (continue from it): ${s.handoffIn || (prev ? prev.handoffOut : "black")}
HAND-OFF OUT (leave this for the next shot): ${s.handoffOut || "as directed"}
PREVIOUS SHOT: ${prev ? `${prev.id} "${prev.title}": ${prev.direction}` : "none (film start)"}
NEXT SHOT: ${next ? `${next.id} "${next.title}": ${next.direction}` : "none (film end: fade everything to ground over the last 0.8 s)"}
${s.primitive === "mark" ? "This is the MARK shot: lib.mark for the two discs (grow r from ~20 to ~110 over 850 ms with lib.easeMark; sep 70 at (960,470)), dom.wordmark for the name (152 px, top ~618, in from +0.4s), dom.tagline (46 px, top ~800, in from +1.2s). The product may sit beside or above the mark at 260-320 px." : ""}
${s.primitive === "cta" ? "This is the END CARD: keep the mark (r 110, sep 70 at (960,470)), dom.wordmark 152 px top 618, dom.tagline 56 px top 800, dom.cta([...lines]) fading in; the product small at the side is welcome; hold; fade all to ground over the last 0.8 s." : ""}

THE API
${API}

Timing tip: express every motion as a function of c.tl or c.t with lib.span/lib.kf; use c.tl for beats inside the shot. Use dom.copy with tIn/tOut in FILM time (c.shot.start + offset).`;
}
function scorePrompt(plan) {
  const beats = (plan.score?.beats || []).map(b => `${b.t}s ${b.what}`).join("; ");
  const shots = plan.shots.map(s => `${s.id} ${s.start}-${s.end} ${s.title}`).join("; ");
  const pulse = FAST ? `TEMPO: fast. A steady pulse is welcome${plan.score?.bpm ? ` at ${plan.score.bpm} BPM` : " (96-124 BPM)"}: soft low thuds and ticks via h.burst in a loop (deterministic), building in layers; hits on every cut; energy rises to the mark, then a clean stop or a short tail.` : "TEMPO: measured; no drums; silence as a beat.";
  return `You are a film composer and sound designer writing a synthesized score in WebAudio for a ${o.duration}-second brand film with continuous narration. Output ONLY one JavaScript function in a single \`\`\`js fence: function score(h, D, SHOTS, SPEC) { ... }. No prose.

FILM: ${plan.idea}. ${pulse} HARMONY: ${plan.score?.harmony || "a low open fifth resolving at the name"}. TIMBRES: ${plan.score?.timbres || "sines, a soft triangle, filtered noise"}.
SHOTS: ${shots}
BEATS (sync hits to these): ${beats || "the shot boundaries, and the name at the mark shot"}
NARRATION (the bed sits under it; keep the 200-3000 Hz band light while lines play): ${(plan.voiceover || []).map(v => `${v.t}s "${v.text}"`).join("; ") || "none"}

THE API
${SCORE_API}`;
}
function critiquePrompt(plan, treatment, round) {
  return `You wrote this treatment and are now at the rough-cut screening of round ${round}. Attached is a contact sheet of 10 stills, left to right, top to bottom, at evenly spaced times across the ${o.duration}s film (${plan.shots.map(s => `${s.id} ${s.start}-${s.end}`).join(", ")}).

TREATMENT (yours):
${treatment.slice(0, 5000)}

Judge the stills against your own treatment AND against these standards: 1) THE PRODUCT: is it on screen, recognisable as ${plan.productDescription?.form || "the product"}, large enough (a hero at >= 60% frame height), lit with material and detail? 2) PACE: does each still differ clearly from its neighbours (something new every 2-3 s)? Do any two stills look the same? 3) LEGIBILITY at phone size: copy, the mark, the wordmark. 4) Composition, safe areas, palette discipline, anything broken or blank. Return STRICT JSON only:
{"notes":[{"shot":"S3","severity":3,"note":"what is wrong","fix":"the exact change in numbers"}], "rewrite":["S3","S5"], "keep":["S1"], "verdict":"<= 25 words"}
At most 6 notes; "rewrite" lists only shots whose code must change (max 4); severity 3 = must fix.`;
}
// The product illustration: drawn once, used by every shot through lib.product.
function productPrompt(plan) {
  const pd = plan.productDescription || {};
  return `You are a senior product illustrator working in vector. Draw THE PRODUCT as layered SVG for a Canvas 2D renderer. Output STRICT JSON only, no prose, no fence.

PRODUCT: ${o.product}
APPEARANCE: form: ${pd.form || "?"}; material: ${pd.material || "?"}; colour: ${pd.colour || "?"}; details: ${(pd.details || []).join(", ") || "?"}${o.productNotes ? `; the maker says: ${o.productNotes}` : ""}
PALETTE: A=${plan.palette.accentA} is the product's own colour; ink=${plan.palette.ink}; ground=${plan.palette.ground}; B=${plan.palette.accentB} only for a cold detail if the product has one. You may also use hex colours mixed from these.

Rules: a 0..1000 box, the product filling about 900 of it, seen in a clean three-quarter or profile view that reads instantly at 200 px tall; 8-16 layers drawn back to front: a soft shadow under it, the body with a LINEAR or RADIAL gradient (light from upper-left), the material's detail (seams, panels, texture lines, a sole, a lens, a rim: whatever this product has), a highlight rim, and a final crisp outline of 6-10 px at 60-80% alpha. Every path uses only M L H V C S Q T A Z. Each path <= 500 characters. Tag layers ("shadow","body","sole","detail","seam","highlight","outline", ...) so shots can reveal them separately. No text, no logo.

Return exactly:
{"view":"three-quarter","layers":[{"tag":"shadow","path":"M...Z","fill":{"radial":[500,860,0,420],"stops":[[0,"#000000",0.55],[1,"#000000",0]]}},{"tag":"body","path":"M...Z","fill":{"linear":[200,150,800,850],"stops":[[0,"A"],[1,"#3a2415"]]}},{"tag":"outline","path":"M...Z","fill":"none","stroke":"ink","strokeWidth":8,"alpha":0.7}]}`;
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
  plan.shots.forEach((s, i) => { s.id = s.id || `S${i + 1}`; if (!P.includes(s.primitive)) s.primitive = "title"; s.params = s.params || {}; const d = Math.max(FAST ? 1.2 : 2.5, (+s.end || t + 4) - (+s.start || t) || 4); s.start = t; s.end = t = +(t + d).toFixed(3); if (s.copy === "null" || s.copy === "") s.copy = null; });
  const k = o.duration / plan.shots[plan.shots.length - 1].end;
  for (const s of plan.shots) { s.start = +(s.start * k).toFixed(3); s.end = +(s.end * k).toFixed(3); }
  plan.shots[0].start = 0; plan.shots[plan.shots.length - 1].end = o.duration;
  plan.voiceover = (Array.isArray(plan.voiceover) ? plan.voiceover : []).filter(v => v && v.text && isFinite(+v.t)).map(v => ({ t: +v.t, text: String(v.text).slice(0, 140) }));
  if (!plan.voice || !ROSTER.includes(plan.voice.voice_id || "")) plan.voice = { voice_id: "JBFqnCBsd6RMkjVDRZzb", voice_name: "George", stability: 0.5 };
  plan.voice.stability = [0, 0.5, 1].includes(+plan.voice.stability) ? +plan.voice.stability : 0.5;
  plan.wordmark = plan.wordmark || o.product.split(/[,:]/)[0].trim();
  return plan;
}
function validateDrawing(pd) {
  if (!pd || !Array.isArray(pd.layers) || pd.layers.length < 3) throw new Error("product drawing has too few layers");
  pd.layers = pd.layers.slice(0, 20).map((L, i) => ({
    tag: String(L.tag || `layer${i}`).slice(0, 24),
    path: String(L.path || "").replace(/[^MLHVCSQTAZmlhvcsqtaz0-9.,\-\s]/g, "").slice(0, 1600),
    fill: L.fill ?? "none", stroke: L.stroke ?? "none", strokeWidth: +L.strokeWidth || 0, alpha: L.alpha == null ? 1 : +L.alpha, glow: +L.glow || 0
  })).filter(L => L.path.length > 8);
  if (pd.layers.length < 3) throw new Error("product drawing paths unusable");
  return pd;
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
await stage(`code x${plan.shots.length + 2}`, async () => {
  const jobs = plan.shots.map((s, i) => callAstra(shotPrompt(plan, i, treatment), { effort: o.effort, label: s.id }).then(r => [s.id, fenced(r.text), i]));
  jobs.push(callAstra(scorePrompt(plan), { effort: o.effort, label: "score" }).then(r => ["score", fenced(r.text), -1]));
  // the product illustration, in parallel with the shot code (shots call lib.product without needing it yet)
  jobs.push((async () => {
    for (let attempt = 0; attempt < 2; attempt++) {
      try { const pd = validateDrawing(extractJson((await callAstra(productPrompt(plan), { effort: o.effort, label: `product${attempt ? "-retry" : ""}` })).text)); return ["product", pd, -2]; }
      catch (e) { log(`# product illustration attempt ${attempt + 1}: ${e.message}`); }
    }
    return ["product", null, -2];
  })());
  const rs = await Promise.allSettled(jobs);
  const bad = [];
  for (const r of rs) {
    if (r.status !== "fulfilled") { log(`# code call failed: ${r.reason.message}`); continue; }
    const [id, code, i] = r.value;
    if (id === "product") { if (code) { plan.productDrawing = code; fs.writeFileSync(path.join(OUT, "spec.json"), JSON.stringify(plan, null, 2)); log(`# product illustration: ${code.layers.length} layers (${code.layers.map(l => l.tag).join(", ")})`); } else log("# product illustration FAILED; shots calling lib.product will draw nothing"); continue; }
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
