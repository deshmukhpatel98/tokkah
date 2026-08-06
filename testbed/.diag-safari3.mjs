// Round 3: Safari-side only. Hook WebSocket + fetch BEFORE clicking join,
// then watch what the join flow actually does. Brave joins too (same shape
// as the failing runs) so the conditions match.
import { spawn } from 'node:child_process';
import { chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';

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

const room = 'diag' + Math.random().toString(36).slice(2, 8);
console.log(`room=${room}`);
await wd('POST', `/session/${sid}/url`, { url: `https://room.tokkah.com/?r=${room}&tape=2&synthmedia=1` });
await sev(`
  window.__net = [];
  const OF = window.fetch;
  window.fetch = function (...a) {
    const u = String(a[0]);
    const p = OF.apply(this, a);
    if (!/telemetry|\\/log/.test(u)) {
      p.then((r) => window.__net.push('fetch ' + u.slice(-40) + ' -> ' + r.status),
             (e) => window.__net.push('fetch ' + u.slice(-40) + ' -> THREW ' + String(e).slice(0, 80)));
    }
    return p;
  };
  const OW = window.WebSocket;
  window.WebSocket = function (url, proto) {
    const w = proto === undefined ? new OW(url) : new OW(url, proto);
    window.__net.push('ws new ' + String(url).slice(-60));
    w.addEventListener('open', () => window.__net.push('ws OPEN'));
    w.addEventListener('close', (e) => window.__net.push('ws CLOSE code=' + e.code + ' reason=' + (e.reason || '').slice(0, 80)));
    w.addEventListener('error', () => window.__net.push('ws ERROR'));
    return w;
  };
  window.WebSocket.prototype = OW.prototype;
  Object.assign(window.WebSocket, OW);
  window.__errs = [];
  window.addEventListener('error', (e) => window.__errs.push('ERR ' + e.message + ' @ ' + (e.filename||'').split('/').pop() + ':' + (e.lineno||'')));
  window.addEventListener('unhandledrejection', (e) => window.__errs.push('REJ ' + String(e.reason && e.reason.message || e.reason).slice(0, 150)));
  return 1;`);
await page.goto(`https://room.tokkah.com/?r=${room}&tape=2`, { waitUntil: 'domcontentloaded' });
for (let i = 0; i < 40; i++) {
  if (await sev(`return (document.querySelector('#preview')?.videoWidth ?? 0) > 0;`)) break;
  await new Promise((r) => setTimeout(r, 500));
}
await page.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
await sclick('#join');
await new Promise((r) => setTimeout(r, 2000));
await page.click('#join');

for (let i = 0; i < 8; i++) {
  await new Promise((r) => setTimeout(r, 4000));
  const s = await sev(`
    const t = window.__tape ?? {};
    return {
      status: document.getElementById('status')?.textContent ?? null,
      net: (window.__net ?? []).slice(-12),
      errs: (window.__errs ?? []).slice(-8),
      telExists: !!t.tel, mirrorLen: t.tel?.mirror?.length ?? null,
      pcNull: !t.pc,
    };`);
  const b = await page.evaluate(() => document.getElementById('status')?.textContent);
  console.log(`\n— t=${(i + 1) * 4}s —  brave status: ${b}`);
  console.log('SAFARI', JSON.stringify(s, null, 1));
  if (s.status === 'connected') break;
}
try { await wd('DELETE', `/session/${sid}`); } catch {}
driver.kill();
await ctx.close();
