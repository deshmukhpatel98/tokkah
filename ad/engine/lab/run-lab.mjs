#!/usr/bin/env node
/**
 * Lab driver: open a page in headless Brave, evaluate an expression, print
 * its JSON result; optionally save a base64 file the page returns.
 *
 *   node ad/engine/lab/run-lab.mjs <page.html> "<expression>" [--gpu] [--save out.bin] [--timeout 120000]
 * The expression may be async (it is awaited). If it resolves to
 * {result, fileB64} the file is written to --save and `result` printed.
 */
import { spawn } from "node:child_process";
import net from "node:net";
import os from "node:os";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const BRAVE = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser";
const argv = process.argv.slice(2);
const [page, expr] = argv.filter(a => !a.startsWith("--"));
const opt = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };
const gpu = argv.includes("--gpu"), save = opt("--save", null), timeout = +opt("--timeout", 120000);
if (!page || !expr) { console.error("usage: run-lab.mjs <page.html> <expression> [--gpu] [--save file]"); process.exit(2); }

const freePort = () => new Promise((res, rej) => { const s = net.createServer(); s.unref(); s.on("error", rej); s.listen(0, () => { const p = s.address().port; s.close(() => res(p)); }); });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const port = await freePort();
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "kin-lab-"));
const flags = ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check", "--hide-scrollbars", "--disable-component-update", "--disable-background-networking", "--window-size=1920,1080", "--autoplay-policy=no-user-gesture-required", "--enable-unsafe-webgpu"];
if (gpu) flags.push("--use-angle=metal", "--enable-gpu-rasterization", "--ignore-gpu-blocklist", "--enable-features=Vulkan,CanvasOopRasterization");
else flags.push("--disable-gpu", "--use-gl=angle", "--use-angle=swiftshader");
const brave = spawn(BRAVE, [...flags, "about:blank"], { stdio: "ignore" });
const kill = () => { try { brave.kill("SIGKILL"); } catch (e) {} try { fs.rmSync(profile, { recursive: true, force: true }); } catch (e) {} };
process.on("exit", kill);
let ws;
for (let i = 0; i < 40 && !ws; i++) { try { const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); const p = pages.find(p => p.type === "page"); if (p) ws = new WebSocket(p.webSocketDebuggerUrl); } catch (e) {} if (!ws) await sleep(250); }
if (!ws) { console.error("no CDP page"); process.exit(1); }
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let id = 0; const pending = new Map();
ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { const { res, rej } = pending.get(m.id); pending.delete(m.id); m.error ? rej(new Error(m.error.message)) : res(m.result); } else if (m.method === "Runtime.consoleAPICalled") { const a = m.params.args.map(x => x.value ?? x.description).join(" "); console.error("  [page]", a); } else if (m.method === "Runtime.exceptionThrown") { console.error("  [page exception]", m.params.exceptionDetails.text, m.params.exceptionDetails.exception?.description || ""); } };
const send = (method, params = {}) => new Promise((res, rej) => { const i = ++id; pending.set(i, { res, rej }); ws.send(JSON.stringify({ id: i, method, params })); });
await send("Page.enable"); await send("Runtime.enable");
await send("Emulation.setDeviceMetricsOverride", { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
await send("Page.navigate", { url: pathToFileURL(path.resolve(page)).href });
await sleep(800);
const t0 = Date.now();
const r = await Promise.race([
  send("Runtime.evaluate", { expression: `(async () => { const __r = await (${expr}); return JSON.stringify(__r); })()`, awaitPromise: true, returnByValue: true }),
  sleep(timeout).then(() => { throw new Error("lab timeout"); })
]);
if (r.exceptionDetails) { console.error("EXCEPTION:", r.exceptionDetails.text, r.exceptionDetails.exception?.description || ""); kill(); process.exit(1); }
let val = JSON.parse(r.result.value);
if (val && typeof val === "object" && val.fileB64) { if (save) { fs.writeFileSync(save, Buffer.from(val.fileB64, "base64")); console.error(`# saved ${save} (${(val.fileB64.length * 3 / 4 / 1024).toFixed(0)} KB)`); } delete val.fileB64; }
console.log(JSON.stringify(val));
console.error(`# ${((Date.now() - t0) / 1000).toFixed(1)}s ${gpu ? "gpu" : "software"}`);
ws.close(); kill(); process.exit(0);
