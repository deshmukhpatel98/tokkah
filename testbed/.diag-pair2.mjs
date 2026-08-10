// Round 2: what does each page's WS actually receive, and where does the
// handshake stop? Filters telemetry for signaling events and reads pc states.
import { spawn } from 'node:child_process';
import { chromium } from '/Users/deveshpatel/Downloads/video calling/testbed/node_modules/playwright-core/index.mjs';

const PORT = 4757;
const BRAVE = '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser';
const wd = async (method, path, body) => {
  const res = await fetch(`http://127.0.0.1:${PORT}${path}`, {
    method, headers: { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(90_000),
  });
  const j = await res.json();
  if (!res.ok) throw new Error(`webdriver ${method} ${path}: ${JSON.stringify(j.value ?? j).slice(0, 400)}`);
  return j.value;
};
const driver = spawn('safaridriver', ['-p', String(PORT)], { stdio: ['ignore', 'pipe', 'pipe'] });
let sid = null;
for (let i = 0; i < 40 && !sid; i++) {
  try {
    const v = await wd('POST', '/session', { capabilities: { alwaysMatch: { browserName: 'safari', 'webkit:alwaysAllowAutoplay': true } } });
    sid = v.sessionId;
  } catch { await new Promise((r) => setTimeout(r, 500)); }
}
if (!sid) { console.error('no safari session'); process.exit(1); }
const sev = (script) => wd('POST', `/session/${sid}/execute/sync`, { script, args: [] });
const sclick = async (css) => {
  const el = await wd('POST', `/session/${sid}/element`, { using: 'css selector', value: css });
  await wd('POST', `/session/${sid}/element/${Object.values(el)[0]}/click`, {});
};
const ctx = await chromium.launchPersistentContext('', {
  executablePath: BRAVE, headless: false,
  args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
    '--autoplay-policy=no-user-gesture-required', '--no-first-run', '--mute-audio'],
  viewport: { width: 1000, height: 700 },
});
const page = await ctx.newPage();
page.on('pageerror', (e) => console.log('BRAVE pageerror:', String(e).slice(0, 300)));

const room = 'diag' + Math.random().toString(36).slice(2, 8);
console.log(`room=${room}`);
await wd('POST', `/session/${sid}/url`, { url: `https://room.tokkah.com/?r=${room}&tape=2&synthmedia=1` });
await page.goto(`https://room.tokkah.com/?r=${room}&tape=2`, { waitUntil: 'domcontentloaded' });
for (let i = 0; i < 40; i++) {
  if (await sev(`return (document.querySelector('#preview')?.videoWidth ?? 0) > 0;`)) break;
  await new Promise((r) => setTimeout(r, 500));
}
await page.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
await sclick('#join');
await new Promise((r) => setTimeout(r, 2000));
await page.click('#join');

const PROBE = `
  const t = window.__tape ?? {};
  const sig = (t.tel?.mirror ?? []).filter((e) => /^(ws-rx|role|rearm|error|offer|answer|tape-fallback|ice)/.test(e.kind))
    .slice(-14).map((e) => e.kind + ':' + JSON.stringify(e.data).slice(0, 80));
  const pc = t.pc;
  return {
    status: document.getElementById('status')?.textContent ?? null,
    pc: pc ? { sig: pc.signalingState, ice: pc.iceConnectionState, conn: pc.connectionState } : null,
    sig,
  };`;
for (let i = 0; i < 10; i++) {
  await new Promise((r) => setTimeout(r, 4000));
  const b = await page.evaluate(new Function(PROBE));
  let s;
  try { s = await Promise.race([sev(PROBE), new Promise((_, rej) => setTimeout(() => rej(new Error('safari probe stuck')), 10000))]); }
  catch (e) { s = { probeError: e.message }; }
  console.log(`\n— t=${(i + 1) * 4}s —`);
  console.log('SAFARI', JSON.stringify(s, null, 1));
  console.log('BRAVE ', JSON.stringify(b, null, 1));
  if (s.status === 'connected' && b.status === 'connected') { console.log('CONNECTED OK'); break; }
}
try { await wd('DELETE', `/session/${sid}`); } catch {}
driver.kill();
await ctx.close();
