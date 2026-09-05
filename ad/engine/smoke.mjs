#!/usr/bin/env node
/**
 * Ad engine — smoke test. Loads a built ad.html in headless Brave, seeks every
 * shot at three times, and reports: thrown errors (window.kinAd.errors), ms per
 * frame per shot, and shots whose mid frame is blank. Prints one JSON line.
 *
 *   node ad/engine/smoke.mjs out/<slug>/ad.html
 */
import { spawn } from "node:child_process";
import net from "node:net";
import os from "node:os";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const BRAVE = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser";
const page = process.argv[2];
if (!page) { console.error("usage: smoke.mjs <ad.html>"); process.exit(2); }

const freePort = () => new Promise((res, rej) => { const s = net.createServer(); s.unref(); s.on("error", rej); s.listen(0, () => { const p = s.address().port; s.close(() => res(p)); }); });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const port = await freePort();
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "kin-smoke-"));
const brave = spawn(BRAVE, ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check", "--use-angle=metal", "--ignore-gpu-blocklist", "--hide-scrollbars", "--disable-component-update", "--disable-background-networking", "--window-size=1920,1080", "about:blank"], { stdio: "ignore" });
const kill = () => { try { brave.kill("SIGKILL"); } catch (e) {} try { fs.rmSync(profile, { recursive: true, force: true }); } catch (e) {} };
process.on("exit", kill);

let ws;
for (let i = 0; i < 40 && !ws; i++) { try { const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); const p = pages.find(p => p.type === "page"); if (p) ws = new WebSocket(p.webSocketDebuggerUrl); } catch (e) {} if (!ws) await sleep(250); }
if (!ws) { console.error("no CDP page"); process.exit(1); }
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let id = 0; const pending = new Map();
ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { const { res, rej } = pending.get(m.id); pending.delete(m.id); m.error ? rej(new Error(m.error.message)) : res(m.result); } };
const send = (method, params = {}) => new Promise((res, rej) => { const i = ++id; pending.set(i, { res, rej }); ws.send(JSON.stringify({ id: i, method, params })); });
const evaluate = async expr => { const r = await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true }); if (r.exceptionDetails) throw new Error(r.exceptionDetails.text + " " + (r.exceptionDetails.exception?.description || "")); return r.result.value; };

await send("Page.enable"); await send("Runtime.enable");
await send("Emulation.setDeviceMetricsOverride", { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
await send("Page.navigate", { url: pathToFileURL(path.resolve(page)).href + "?render=1" });
for (let i = 0; i < 60 && !(await evaluate("!!window.kinAd")); i++) await sleep(200);
await evaluate("document.fonts.ready.then(() => true)");

const shots = await evaluate("JSON.parse(document.getElementById('ad-spec').textContent).shots.map(s => ({id: s.id, start: s.start, end: s.end}))");
const msByShot = {}, blank = [];
for (const s of shots) {
  const d = s.end - s.start, times = [s.start + Math.min(0.15, d / 4), s.start + d / 2, s.end - Math.min(0.15, d / 4)];
  let worst = 0;
  for (const t of times) {
    // the host times its own render(t); seek() also waits two animation frames,
    // so wall time would read ~33 ms for everything. Render 3 times, keep the best.
    const ms = await evaluate(`(async () => { let best = 1e9; for (let k = 0; k < 3; k++) { await kinAd.seek(${t}); const f = kinAd.frameMs; best = Math.min(best, f.length ? f[f.length - 1][1] : 0); } return best; })()`);
    worst = Math.max(worst, ms);
  }
  msByShot[s.id] = +worst.toFixed(1);
  // blank check at the mid frame: sample the composited canvases for any lit pixel
  await evaluate(`kinAd.seek(${s.start + d / 2})`);
  const lit = await evaluate(`(() => { let lit = 0; for (const id of ["c-scene", "c-light"]) { const c = document.getElementById(id), g = c.getContext("2d"); const w = c.width, h = c.height; const img = g.getImageData(0, 0, w, h).data; for (let i = 3; i < img.length; i += 4 * 97) if (img[i] > 12) lit++; } const copy = [...document.querySelectorAll(".copy, #mark-wrap, #cta")].some(n => n.style.display !== "none" && parseFloat(n.style.opacity || "0") > 0.05 && n.textContent.trim()); return { lit, copy }; })()`);
  if (lit.lit < 8 && !lit.copy) blank.push(s.id);
}
const errors = await evaluate("kinAd.errors");
const worstShot = Object.entries(msByShot).sort((a, b) => b[1] - a[1])[0] || ["-", 0];
ws.close(); kill();
console.log(JSON.stringify({ errors, msByShot, worstMs: worstShot[1], worstShot: worstShot[0], blank }));
process.exit(0);
