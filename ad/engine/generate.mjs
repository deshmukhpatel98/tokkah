#!/usr/bin/env node
/**
 * Ad engine — authoring. Built for speed and token economy:
 *
 *   ONE Astra call returns the whole ad as strict JSON: tension, idea, tone,
 *   tagline, palette, voice casting, shots, narration. No staged pipeline, no
 *   context re-sent. Parallelism is spent on VARIANTS: --variants N runs N
 *   independent candidates concurrently (different creative angles) and a
 *   small judge call picks one. --variants 1 (default) is the fastest path.
 *
 *   EXPLABS_API_KEY=... node ad/engine/generate.mjs \
 *     --product "Halcyon, a bedside sunrise lamp" --audience "people who hate their alarm" \
 *     --duration 40 [--variants 3] [--effort high] [--slug halcyon]
 *
 * Output: ad/engine/out/<slug>/spec.json (+ candidates/*.json when N > 1).
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { callAstra, extractJson } from "./gateway.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));

function args(argv) {
  const o = { product: "Halcyon, a bedside sunrise lamp that wakes you without an alarm", audience: "people who hate their phone alarm", duration: 40, effort: "high", slug: null, variants: 1 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--product") o.product = argv[++i];
    else if (a === "--audience") o.audience = argv[++i];
    else if (a === "--duration") o.duration = parseFloat(argv[++i]);
    else if (a === "--effort") o.effort = argv[++i];
    else if (a === "--slug") o.slug = argv[++i];
    else if (a === "--variants") o.variants = Math.max(1, parseInt(argv[++i], 10) || 1);
    else throw new Error("unknown option: " + a);
  }
  o.slug = o.slug || o.product.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 40);
  return o;
}

// The renderer's primitive library. This text IS the contract Astra writes to.
const PRIMITIVES = `- title {copy (<=6 words), size 56..120, sub?}  a full-frame type card
- glow {color "A"|"B"|"ink", from 0..1, to 0..1, x 0..1, y 0..1, radius px (200..1400), curve "ease"|"linear"}  a light field whose intensity ramps across the shot
- shape {path: SVG path in a 0..1000 box using M L C Q Z only, fill "A"|"B"|"ink"|"none", stroke "A"|"B"|"ink"|"none", strokeWidth px, size px (box height, 200..900), x 0..1, y 0..1, motion "still"|"shudder"|"rise"|"breathe"|"drift"|"fadein", glow 0..1}  an object you draw as a clean designer's silhouette or outline
- portrait {who "them"|"you", edge "A"|"B"|"none"}  a person on a video call (ONLY for products about people talking)
- duo {}  two call windows (same caveat)
- planet {from CITY, to CITY, number?}  a lit planet with one light route (ONLY for distance or global products)
- mark {wordmark, tagline?}  the brand mark and wordmark
- cta {lines [1..3 short strings]}  the end card`;

// Voice roster for casting (ElevenLabs premade voices).
const ROSTER = `JBFqnCBsd6RMkjVDRZzb George: warm storyteller, British, middle-aged
nPczCjzI2devNBz1zQrb Brian: deep, resonant, comforting, American
pFZP5JQG7iQjIQuC4Bku Lily: velvety, British, middle-aged
onwK4e9ZLuTAKqWW03F9 Daniel: steady broadcaster, British
cjVigY5qzO86Huf0OWal Eric: smooth, trustworthy, American
EXAVITQu4vr4xnSDxMaL Sarah: mature, reassuring, confident, American
SAz9YHcvj6GT2YYXdXww River: relaxed, neutral, informative
XrExE9yKIg1WjnnlVkGX Matilda: knowledgeable, professional, American
auq43ws1oslv0tO4BDa7 Adam Stone: smooth and relaxed, British
pqHfZKP75CvOlQylNhV4 Bill: wise, mature, balanced, American`;

const ANGLES = [
  "lead with the tension the audience already feels, then one quiet move",
  "lead with the product's single move as an image, let the tension be implied",
  "an unexpected metaphor for the problem; the product resolves the metaphor",
  "almost wordless: light and one object carry it; two lines of copy total",
  "the day-after: what life is like once the problem is gone"
];

function prompt(o, angle) {
  return `You are a world-class brand-film director, copywriter and editor. In ONE pass, design a ${o.duration}-second animated brand film and return it as STRICT JSON only: no prose, no code fence.

PRODUCT: ${o.product}
AUDIENCE: ${o.audience}
ANGLE: ${angle}

Grammar: near-black ground, cream type, two accent colours (A = the product's own warmth/primary; B = the cold, the "other", the problem). Pure code animation. Apple-quiet, not startup-loud. One idea, felt not explained; most shots wordless; copy spare (<=1 short line per shot, several shots none); plain words, no jargon; numbers only if they ARE the point. Arc: tension -> the product's single move -> why it matters -> the name.

The renderer implements ONLY these shot primitives (params exactly as shown):
${PRIMITIVES}

Rules: 6-9 contiguous shots; first start 0; last end ${o.duration}; each shot >= 2.5 s; end with mark then cta. Draw objects with shape: 1-3 clean paths per shot, each <= 400 characters, designed not clip-art. Prefer glow and shape over portrait/duo/planet unless the product is literally about calls or distance.

Voice: cast ONE voice from this roster for the tone, and write 0-4 narration lines (<= 12 words each, timed in seconds, not repeating on-screen copy; silence is welcome):
${ROSTER}

Return exactly this shape:
{"product":"${o.product.replace(/"/g, "'")}","tension":"one sentence","idea":"one line","tone":"a, b, c","tagline":"<=6 words","palette":{"ground":"#05060a","ink":"#f3f1ec","accentA":"#RRGGBB","accentB":"#RRGGBB"},"voice":{"voice_id":"...","voice_name":"...","stability":0.5,"direction":"one line of read direction"},"duration":${o.duration},"shots":[{"id":"S1","start":0,"end":3.5,"primitive":"title","params":{"copy":"..."},"copy":"optional"}],"voiceover":[{"t":9,"text":"..."}]}`;
}

function judgePrompt(o, cands) {
  const brief = cands.map((c, i) => `#${i}: tension="${c.tension}" idea="${c.idea}" tagline="${c.tagline}" shots=${(c.shots || []).map(s => s.primitive).join(">")} vo=${(c.voiceover || []).length}`).join("\n");
  return `Pick the strongest brand-film concept for "${o.product}" (audience: ${o.audience}). Judge on: one clear idea, emotional truth, restraint, a payoff that earns the name, and renderability (glow/shape over stock devices). Return STRICT JSON only: {"pick": <index>, "why": "<= 20 words"}.\n${brief}`;
}

// ---- validate and repair a candidate into a renderable spec
const PRIMS = ["title", "glow", "shape", "portrait", "duo", "planet", "mark", "cta"];
const HEX = /^#[0-9a-fA-F]{6}$/;
function repair(spec, o) {
  const notes = [];
  spec.duration = o.duration;
  spec.palette = Object.assign({ ground: "#05060a", ink: "#f3f1ec", accentA: "#EDB580", accentB: "#7F91A3" }, spec.palette || {});
  for (const k of ["ground", "ink", "accentA", "accentB"]) if (!HEX.test(spec.palette[k] || "")) { notes.push(`palette.${k} invalid`); delete spec.palette[k]; }
  spec.palette = Object.assign({ ground: "#05060a", ink: "#f3f1ec", accentA: "#EDB580", accentB: "#7F91A3" }, spec.palette);
  if (!Array.isArray(spec.shots) || !spec.shots.length) throw new Error("candidate has no shots");
  spec.shots.sort((a, b) => (+a.start || 0) - (+b.start || 0));
  let t = 0;
  for (const s of spec.shots) {
    if (!PRIMS.includes(s.primitive)) { notes.push(`${s.id}: ${s.primitive} -> title`); s.primitive = "title"; s.params = { copy: s.copy || "" }; }
    s.params = s.params || {};
    if (s.primitive === "shape" && typeof s.params.path === "string") s.params.path = s.params.path.replace(/[^MLCQZmlcqz0-9.,\-\s]/g, "").slice(0, 1200);
    const dur = Math.max(2.5, (+s.end || t + 4) - (+s.start || t) || 4);
    s.start = t; s.end = t = +(t + dur).toFixed(3);
  }
  const scale = o.duration / spec.shots[spec.shots.length - 1].end;
  for (const s of spec.shots) { s.start = +(s.start * scale).toFixed(3); s.end = +(s.end * scale).toFixed(3); }
  spec.shots[0].start = 0; spec.shots[spec.shots.length - 1].end = o.duration;
  spec.voiceover = (Array.isArray(spec.voiceover) ? spec.voiceover : []).filter(v => v && v.text && isFinite(+v.t)).map(v => ({ t: +v.t, text: String(v.text).slice(0, 140) }));
  if (spec.voice && !ROSTER.includes(spec.voice.voice_id || "")) { notes.push("voice not in roster -> George"); spec.voice = { voice_id: "JBFqnCBsd6RMkjVDRZzb", voice_name: "George", stability: 0.5 }; }
  if (spec.voice) spec.voice.stability = [0, 0.5, 1].includes(+spec.voice.stability) ? +spec.voice.stability : 0.5;
  return notes;
}

async function main() {
  const o = args(process.argv.slice(2));
  const outDir = path.join(HERE, "out", o.slug);
  fs.mkdirSync(outDir, { recursive: true });
  const t0 = Date.now();
  console.error(`# ad engine: "${o.product}" -> ${o.slug} (${o.duration}s, ${o.variants} variant${o.variants > 1 ? "s" : ""}, effort=${o.effort})`);

  // all candidates at once
  const angles = Array.from({ length: o.variants }, (_, i) => ANGLES[i % ANGLES.length]);
  const results = await Promise.allSettled(angles.map((angle, i) => callAstra(prompt(o, angle), { effort: o.effort, label: `cand${i}` })));
  const cands = [];
  results.forEach((r, i) => {
    if (r.status !== "fulfilled") { console.error(`# cand${i} failed: ${r.reason.message}`); return; }
    try { const spec = extractJson(r.value.text); const notes = repair(spec, o); spec._angle = angles[i]; spec._effort = r.value.effort; cands.push(spec); if (notes.length) console.error(`# cand${i} repaired: ${notes.join("; ")}`); }
    catch (e) { console.error(`# cand${i} unusable: ${e.message}`); }
  });
  if (!cands.length) throw new Error("no usable candidate");

  let pick = 0, why = "only candidate";
  if (cands.length > 1) {
    fs.mkdirSync(path.join(outDir, "candidates"), { recursive: true });
    cands.forEach((c, i) => fs.writeFileSync(path.join(outDir, "candidates", `${i}.json`), JSON.stringify(c, null, 2)));
    try { const j = extractJson((await callAstra(judgePrompt(o, cands), { effort: "low", label: "judge", timeoutMs: 120000 })).text); pick = Math.min(cands.length - 1, Math.max(0, +j.pick || 0)); why = j.why || ""; }
    catch (e) { console.error(`# judge failed (${e.message}); taking #0`); }
  }
  const spec = cands[pick];
  fs.writeFileSync(path.join(outDir, "spec.json"), JSON.stringify(spec, null, 2));
  const secs = ((Date.now() - t0) / 1000).toFixed(0);
  console.error(`# picked #${pick} (${why}); spec written in ${secs}s: ${outDir}/spec.json`);
  console.log(JSON.stringify({ slug: o.slug, dir: outDir, seconds: +secs, candidates: cands.length, pick, tagline: spec.tagline, shots: spec.shots.map(s => s.primitive).join(">"), vo: spec.voiceover.length, voice: spec.voice?.voice_name }));
}

main().catch(e => { console.error("FAILED:", e.message); process.exit(1); });
