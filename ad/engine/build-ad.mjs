#!/usr/bin/env node
/**
 * Ad engine — build a standalone ad.html from a spec: the page shell with the
 * spec and the render library inlined (no external resources), so
 * ad/render.mjs --page can render it and it can be hosted as one file.
 *
 *   node ad/engine/build-ad.mjs ad/engine/out/<slug>/spec.json
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const specPath = process.argv[2];
if (!specPath) { console.error("usage: build-ad.mjs <spec.json>"); process.exit(2); }

const spec = JSON.parse(fs.readFileSync(specPath, "utf8"));
const shell = fs.readFileSync(path.join(HERE, "engine.html"), "utf8");
// v2 ads carry Astra-written shot modules next to the spec; they run on host.js.
const modulesPath = path.join(path.dirname(specPath), "modules.js");
const hasModules = fs.existsSync(modulesPath);
const lib = fs.readFileSync(path.join(HERE, hasModules ? "host.js" : "render-lib.js"), "utf8");
if (lib.includes("/*@@")) { console.error("render library still has unstitched markers"); process.exit(1); }
const modules = hasModules ? fs.readFileSync(modulesPath, "utf8") : "";
// the vendored bundle (three.js + mp4 muxer) gives the page 3D and in-page encoding; one local script, no external resources
const bundlePath = path.join(HERE, "vendor", "three-bundle.js");
const bundle = fs.existsSync(bundlePath) ? `<script>${fs.readFileSync(bundlePath, "utf8").replace(/<\/script/gi, "<\\/script")}</script>` : "";

const esc = s => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;");
const lines = [];
for (const s of spec.shots || []) { const c = s.copy || (s.params && s.params.copy); if (c) lines.push(c); if (s.params && s.params.sub) lines.push(s.params.sub); }
if (spec.tagline) lines.push(spec.tagline);
for (const s of spec.shots || []) if (s.primitive === "cta" && Array.isArray(s.params?.lines)) lines.push(...s.params.lines);
const transcript = lines.map(l => `<li>${esc(l)}</li>`).join("");

const title = `${(spec.product || "Ad").split(/[,:]/)[0].trim()} — ${spec.tagline || ""}`.trim();
// The spec is inlined inside a <script> element: "</script>" inside it must be broken.
const specJson = JSON.stringify(spec).replace(/<\/script/gi, "<\\/script");
const libSafe = (modules ? modules.replace(/<\/script/gi, "<\\/script") + "\n" : "") + lib.replace(/<\/script/gi, "<\\/script");
const html = shell
  .replace(/@@TITLE@@/g, esc(title))
  .replace(/@@GROUND@@/g, spec.palette?.ground || "#05060a")
  .replace(/@@INK@@/g, spec.palette?.ink || "#f3f1ec")
  .replace("@@TRANSCRIPT@@", transcript)
  .replace("@@BUNDLE@@", () => bundle)
  .replace("@@SPEC@@", () => specJson)
  .replace("@@LIB@@", () => libSafe);

const outPath = path.join(path.dirname(specPath), "ad.html");
fs.writeFileSync(outPath, html);
console.log(`${outPath} (${(html.length / 1024).toFixed(1)} KB, ${spec.shots.length} shots, ${spec.duration}s${hasModules ? ", " + (modules.match(/__AD_MODULES__\[/g) || []).length + " modules" : ""})`);
