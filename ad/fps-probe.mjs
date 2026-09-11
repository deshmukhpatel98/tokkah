#!/usr/bin/env node
/**
 * Frame-rate probe for the film. Launches Brave (headless, GPU on), plays the
 * page muted from several start times, and reports frames per second over a
 * 3 s window for each. Node 22, zero dependencies. Exit non-zero if any
 * window falls under --min (default 55).
 *
 *   node ad/fps-probe.mjs [--min 55] [--at 5,20,30,42,50,55,65]
 */
import { spawn, spawnSync } from 'node:child_process';
import net from 'node:net';
import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const BRAVE = '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser';
const args = process.argv.slice(2);
let min = 55, at = [5, 20, 30, 42, 50, 55, 65];
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--min') min = parseFloat(args[++i]);
  else if (args[i] === '--at') at = args[++i].split(',').map(Number);
  else { console.error('Unknown option: ' + args[i]); process.exit(2); }
}

const freePort = () => new Promise((res, rej) => { const s = net.createServer(); s.unref(); s.on('error', rej); s.listen(0, () => { const p = s.address().port; s.close(() => res(p)); }); });
const sleep = ms => new Promise(r => setTimeout(r, ms));

const port = await freePort();
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'kin-fps-'));
const brave = spawn(BRAVE, [
  '--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--no-first-run',
  '--no-default-browser-check', '--hide-scrollbars', '--disable-component-update', '--disable-background-networking',
  '--window-size=1920,1080', '--autoplay-policy=no-user-gesture-required', 'about:blank'
], { stdio: 'ignore' });
const kill = () => { try { brave.kill('SIGKILL'); } catch (e) {} try { fs.rmSync(profile, { recursive: true, force: true }); } catch (e) {} };
process.on('exit', kill); process.on('SIGINT', () => { kill(); process.exit(130); });

let ws;
for (let i = 0; i < 40; i++) {
  try {
    const r = await fetch(`http://127.0.0.1:${port}/json/list`);
    const pages = await r.json();
    const page = pages.find(p => p.type === 'page');
    if (page) { ws = new WebSocket(page.webSocketDebuggerUrl); break; }
  } catch (e) {}
  await sleep(250);
}
if (!ws) { console.error('FAILED: no CDP page'); process.exit(1); }
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let id = 0; const pending = new Map();
ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { const { res, rej } = pending.get(m.id); pending.delete(m.id); m.error ? rej(new Error(m.error.message)) : res(m.result); } };
const send = (method, params = {}) => new Promise((res, rej) => { const i = ++id; pending.set(i, { res, rej }); ws.send(JSON.stringify({ id: i, method, params })); });
const evaluate = async expr => { const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }); if (r.exceptionDetails) throw new Error(r.exceptionDetails.text + ' ' + (r.exceptionDetails.exception?.description || '')); return r.result.value; };

await send('Page.enable'); await send('Runtime.enable');
await send('Emulation.setDeviceMetricsOverride', { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
const url = pathToFileURL(path.resolve('ad/kin-ad.html')).href + '?muted=1&t=0.01';
await send('Page.navigate', { url });
for (let i = 0; i < 40 && !(await evaluate('!!window.kinAd')); i++) await sleep(250);
await evaluate('document.fonts.ready.then(() => true)');

let worst = Infinity;
for (const t of at) {
  const fps = await evaluate(`(async () => {
    await kinAd.seek(${t}); kinAd.play();
    await new Promise(r => setTimeout(r, 400));
    const t0 = performance.now(); let n = 0;
    await new Promise(r => { function f() { n++; if (performance.now() - t0 < 3000) requestAnimationFrame(f); else r(); } requestAnimationFrame(f); });
    kinAd.pause();
    return n / ((performance.now() - t0) / 1000);
  })()`);
  worst = Math.min(worst, fps);
  console.log(`t=${String(t).padStart(4)}s  ${fps.toFixed(1)} fps`);
}
ws.close(); kill();
if (worst < min) { console.error(`FAILED: worst window ${worst.toFixed(1)} fps < ${min}`); process.exit(1); }
console.log(`OK: worst window ${worst.toFixed(1)} fps`);
process.exit(0);
