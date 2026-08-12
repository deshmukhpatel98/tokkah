#!/usr/bin/env node
/**
 * The fork test: can a stranger clone this repo, deploy it, and carry a real
 * call on their own deployment — then embed that deployment in someone else's
 * product?
 *
 * Nothing here is simulated. It clones the PUBLIC repo, installs from the
 * lockfile, deploys a throwaway Worker under a different name (exactly what a
 * fork gets), and then runs real browsers with real talking-head media through
 * it: first a direct two-party call, then the same call embedded by a page on
 * a DIFFERENT origin via the one-line script tag.
 *
 *   node testbed/forkdeploy-call.mjs                # clone the public repo
 *   node testbed/forkdeploy-call.mjs --local        # use the working tree instead
 *   node testbed/forkdeploy-call.mjs --keep         # don't delete the fork worker
 *
 * Requires a Cloudflare login (wrangler OAuth). The deployed Worker is
 * deleted at the end unless --keep.
 */
import { chromium } from 'playwright-core';
import { execFileSync, execSync } from 'node:child_process';
import { mkdtempSync, rmSync, cpSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = 'https://github.com/deshmukhpatel98/tokkah.git';
const NAME = `tokkah-forktest-${Date.now().toString(36)}`;
const args = new Set(process.argv.slice(2));
const LOCAL = args.has('--local');
const KEEP = args.has('--keep');
const CHROME = process.env.TESTBED_CHROME ??
  (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const fixture = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);

const results = [];
const check = (name, pass, detail = '') => {
  results.push({ name, pass });
  console.log(`  ${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
};
const sh = (cmd, cmdArgs, cwd) => execFileSync(cmd, cmdArgs, {
  cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
  env: { ...process.env, CLOUDFLARE_API_TOKEN: undefined },
});

// ── 1. what a stranger gets ───────────────────────────────────────────────
const work = mkdtempSync(join(tmpdir(), 'tokkah-fork-'));
const root = join(work, 'tokkah');
console.log(`\n[1/5] ${LOCAL ? 'copying working tree' : 'cloning the public repo'} → ${root}`);
if (LOCAL) {
  cpSync(join(HERE, '..'), root, {
    recursive: true, dereference: false,
    filter: (s) => !/node_modules|\.git\/|testbed\/media|\.wrangler/.test(s),
  });
} else {
  sh('git', ['clone', '--depth', '1', REPO, root]);
}
const app = join(root, 'tape-app');

console.log('[2/5] npm ci (exact versions from the lockfile)');
let installed = false;
try { sh('npm', ['ci'], app); installed = true; } catch (e) { console.log((e.stdout || '').slice(-800)); }
check('clean clone installs with npm ci', installed);
if (!installed) process.exit(1);

// ── 2. deploy it as a fork ────────────────────────────────────────────────
console.log(`[3/5] deploying as "${NAME}" (a fork's own Worker)`);
let base = null;
try {
  const out = sh('npx', ['wrangler', 'deploy', '--name', NAME], app);
  base = (out.match(/https:\/\/[a-z0-9.-]*workers\.dev/i) || [])[0] ?? null;
  console.log(out.split('\n').filter((l) => /Uploaded|Deployed|workers\.dev|Version ID/.test(l)).join('\n'));
} catch (e) { console.log((e.stdout || e.message || '').slice(-1200)); }
check('fork deploys to its own workers.dev URL', !!base, base ?? 'no URL returned');
if (!base) process.exit(1);

// Edge propagation. A BRAND-NEW workers.dev hostname needs DNS to propagate,
// which takes appreciably longer than the deploy itself — measured here rather
// than assumed, because "I deployed it and the URL 404s" is the first thing a
// forker hits and the docs should tell them how long to wait.
let served = false;
const t0 = Date.now();
for (let i = 0; i < 90 && !served; i++) {
  try {
    const r = await fetch(base, { redirect: 'follow' });
    served = r.ok && (await r.text()).includes('<title>Tokkah</title>');
  } catch { /* DNS not resolving yet */ }
  if (!served) await new Promise((r) => setTimeout(r, 2000));
}
const httpS = ((Date.now() - t0) / 1000).toFixed(0);
check('fork URL becomes reachable', served, served ? `${httpS}s after deploy` : 'still not serving after 180s');

// Serving HTML is NOT the same as being able to carry a call: the signalling
// socket and its Durable Object take longer to come up on a brand-new Worker.
// Measured 2026-08-12: the app shell answered in 3 s while a call attempted at
// that moment still failed. So the readiness gate is a real WebSocket that
// reaches the Room DO — which is also the number a forker actually needs.
let wsReady = false;
const t1 = Date.now();
for (let i = 0; i < 60 && !wsReady; i++) {
  wsReady = await new Promise((resolve) => {
    let ws;
    const done = (v) => { try { ws?.close(); } catch { /* closing */ } resolve(v); };
    const timer = setTimeout(() => done(false), 5000);
    try {
      ws = new WebSocket(`${base.replace('https://', 'wss://')}/api/room/warmup-${i}/ws`);
      ws.onmessage = () => { clearTimeout(timer); done(true); };
      ws.onerror = () => { clearTimeout(timer); done(false); };
      ws.onclose = () => { clearTimeout(timer); done(false); };
    } catch { clearTimeout(timer); done(false); }
  });
  if (!wsReady) await new Promise((r) => setTimeout(r, 2000));
}
const wsS = ((Date.now() - t1) / 1000).toFixed(0);
check('fork signalling is live (Durable Object reachable)', wsReady,
  wsReady ? `${wsS}s after the URL resolved (${(+httpS + +wsS)}s total from deploy)` : 'no welcome from the Room DO after 300s');

const cleanup = () => {
  if (KEEP) { console.log(`\n(kept: ${base} — delete with: npx wrangler delete --name ${NAME})`); return; }
  try {
    execSync(`printf 'y\\n' | npx wrangler delete --name ${NAME}`, { cwd: app, stdio: 'pipe', env: { ...process.env, CLOUDFLARE_API_TOKEN: undefined } });
    console.log(`\ntore down ${NAME}`);
  } catch { console.log(`\ncould not auto-delete ${NAME} — remove it with: npx wrangler delete --name ${NAME}`); }
  try { rmSync(work, { recursive: true, force: true }); } catch { /* temp dir */ }
};

// ── 3. a real call on the fork ────────────────────────────────────────────
const launch = (who) => chromium.launch({
  executablePath: CHROME, headless: true,
  args: [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    // Testing-realism law: real talking-head media, never synthetic tones.
    `--use-file-for-fake-audio-capture=${fixture(who === 'a' ? 'realA.wav' : 'realB.wav')}`,
    `--use-file-for-fake-video-capture=${fixture(who === 'a' ? 'realA.mjpeg' : 'realB.mjpeg')}`,
    '--autoplay-policy=no-user-gesture-required',
  ],
});

console.log('\n[4/5] real two-party call on the fork');
const room = `fork-${Date.now().toString(36)}`;
const bA = await launch('a'), bB = await launch('b');
try {
  const pA = await bA.newPage(), pB = await bB.newPage();
  for (const [p, b] of [[pA, bA], [pB, bB]]) {
    await p.goto(`${base}/?r=${room}`, { waitUntil: 'load', timeout: 60000 });
    await p.click('#join');
  }
  let connected = true;
  for (const p of [pA, pB]) {
    try { await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 90000 }); }
    catch { connected = false; }
  }
  check('both peers connect on the fork', connected);

  await pA.waitForTimeout(8000);
  // Accessors verified by introspection against a live call: audio counters
  // live on __tape.pcm directly (not a snapshot()), and video is displayed on
  // the paint-on-arrival canvas #remoteCanvas — #remote stays 0x0 on that
  // path, so asserting on it would report a false failure.
  const media = await pA.evaluate(() => {
    const p = window.__tape?.pcm ?? {};
    const lane = window.__tape?.lane?.snapshot?.() ?? {};
    const canvas = document.getElementById('remoteCanvas');
    const v = document.getElementById('remote');
    return {
      framesRecv: p.framesRecv ?? 0,
      fecRepaired: p.fecRepaired ?? 0,
      mouthToEarMs: p.mouthToEarMs ?? null,
      framesOut: lane.framesOut ?? 0,
      bytesRecv: lane.bytesRecv ?? 0,
      videoW: canvas?.width || v?.videoWidth || 0,
      surface: canvas?.width ? 'canvas' : (v?.videoWidth ? 'video' : 'none'),
    };
  });
  check('lossless audio arrives on the fork', media.framesRecv > 0, `${media.framesRecv} PCM frames received`);
  check('remote video decodes on the fork', media.framesOut > 0 && media.videoW > 0,
    `${media.framesOut} frames out, ${(media.bytesRecv / 1024).toFixed(0)} KiB, ${media.videoW}px on <${media.surface}>`);

  // ── 4. embedded in a *different* product, on a different origin ─────────
  console.log('\n[5/5] one-line embed from a third-party origin');
  const eRoom = `forkembed-${Date.now().toString(36)}`;
  const page = `<!doctype html><meta charset=utf-8><title>Someone else's product</title>
<h1>A totally unrelated website</h1>
<script src="${base}/embed.js" data-room="${eRoom}"></script>`;
  const srv = createServer((_q, res) => { res.writeHead(200, { 'content-type': 'text/html' }); res.end(page); });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const origin = `http://127.0.0.1:${srv.address().port}`;

  const host = await bA.newPage();
  await host.goto(origin, { waitUntil: 'load', timeout: 60000 });
  const frameEl = await host.waitForSelector('iframe', { timeout: 20000 }).catch(() => null);
  check('script tag replaces itself with the call iframe', !!frameEl);
  const src = frameEl ? await frameEl.getAttribute('src') : '';
  check('iframe points at the fork, not the origin repo', !!src && src.startsWith(base), src || '(none)');
  const allow = frameEl ? await frameEl.getAttribute('allow') : '';
  check('iframe delegates camera and microphone', /camera/.test(allow || '') && /microphone/.test(allow || ''));

  // A normal app tab joins the same room and the embedded call must connect.
  const peer = await bB.newPage();
  await peer.goto(`${base}/?r=${eRoom}`, { waitUntil: 'load', timeout: 60000 });
  await peer.click('#join');
  const inner = await frameEl.contentFrame();
  let embedJoined = false;
  try {
    await inner.click('#join', { timeout: 20000 }).catch(() => {});
    await inner.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 90000 });
    embedJoined = true;
  } catch { /* reported below */ }
  check('embedded call connects across origins', embedJoined);

  if (embedJoined) {
    await host.waitForTimeout(6000);
    const em = await inner.evaluate(() => {
      const p = window.__tape?.pcm ?? {};
      const lane = window.__tape?.lane?.snapshot?.() ?? {};
      const canvas = document.getElementById('remoteCanvas');
      return {
        framesRecv: p.framesRecv ?? 0,
        framesOut: lane.framesOut ?? 0,
        videoW: canvas?.width || document.getElementById('remote')?.videoWidth || 0,
      };
    });
    check('embedded call carries audio', em.framesRecv > 0, `${em.framesRecv} PCM frames`);
    check('embedded call carries video', em.framesOut > 0 && em.videoW > 0, `${em.framesOut} frames, ${em.videoW}px`);
  }

  // Programmatic API — the other half of the integration promise.
  const api = await host.evaluate(() => {
    const el = document.createElement('div');
    document.body.appendChild(el);
    const call = window.Tokkah?.join?.({ room: 'api-check', container: el });
    const out = { hasApi: !!window.Tokkah?.join, url: call?.url ?? null, frames: el.querySelectorAll('iframe').length };
    call?.leave?.();
    out.afterLeave = el.querySelectorAll('iframe').length;
    return out;
  });
  check('Tokkah.join() mounts a call', api.hasApi && api.frames === 1, api.url ?? '');
  check('call.leave() removes it', api.afterLeave === 0);

  srv.close();
} finally {
  await bA.close(); await bB.close();
  cleanup();
}

const failed = results.filter((r) => !r.pass);
console.log(`\n${failed.length ? `FORK TEST FAILED — ${failed.length}/${results.length} checks failed` : `FORK TEST PASSES — ${results.length}/${results.length} checks`}`);
process.exit(failed.length ? 1 : 0);
