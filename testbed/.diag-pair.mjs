// Paired Safari x Brave diagnostic: same join flow as safari-call.mjs but
// captures Brave console+pageerror, Safari window errors, both telemetry
// `why` streams, and both pc/ice states. Goal: find where the handshake dies.
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
const bmsgs = [];
page.on('console', (m) => { if (['error', 'warning'].includes(m.type())) bmsgs.push(`console.${m.type()}: ${m.text().slice(0, 200)}`); });
page.on('pageerror', (e) => bmsgs.push(`pageerror: ${String(e).slice(0, 300)}`));

const room = 'diag' + Math.random().toString(36).slice(2, 8);
console.log(`room=${room}`);
// order=s: Safari first
await wd('POST', `/session/${sid}/url`, { url: `https://room.tokkah.com/?r=${room}&tape=2&synthmedia=1` });
await sev(`
  window.__errs = [];
  window.addEventListener('error', (e) => window.__errs.push('ERR ' + e.message + ' @ ' + (e.filename||'').split('/').pop() + ':' + (e.lineno||'')));
  window.addEventListener('unhandledrejection', (e) => window.__errs.push('REJ ' + String(e.reason && e.reason.message || e.reason).slice(0,200)));
  return 1;`);
await page.goto(`https://room.tokkah.com/?r=${room}&tape=2`, { waitUntil: 'domcontentloaded' });
for (let i = 0; i < 40; i++) {
  if (await sev(`return (document.querySelector('#preview')?.videoWidth ?? 0) > 0;`)) break;
  await new Promise((r) => setTimeout(r, 500));
}
await page.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
const clickP = sclick('#join').then(() => console.log('safari join click returned'))
  .catch((e) => console.log('safari join click FAILED:', e.message.slice(0, 120)));
await new Promise((r) => setTimeout(r, 2000));
await page.click('#join');
clickP.catch(() => {});

const PROBE = `
  const t = window.__tape ?? {};
  const pcs = (window.__pcs ?? t.pcs ?? []);
  return {
    status: document.getElementById('status')?.textContent ?? null,
    why: (t.tel?.recent ?? t.tel?.mirror ?? []).slice(-5).map((e) => e.kind + ' ' + JSON.stringify(e.data).slice(0, 100)),
    errs: (window.__errs ?? []).slice(-6),
  };`;
for (let i = 0; i < 20; i++) {
  await new Promise((r) => setTimeout(r, 3000));
  const b = await page.evaluate(new Function(PROBE));
  let s;
  try {
    s = await Promise.race([sev(PROBE), new Promise((_, rej) => setTimeout(() => rej(new Error('probe stuck 8s — safari main thread or webdriver queue blocked')), 8000))]);
  } catch (e) {
    s = { probeError: e.message };
    try {
      const shot = await wd('GET', `/session/${sid}/screenshot`);
      const fs = await import('node:fs');
      fs.writeFileSync('/private/tmp/claude-501/-Users-earningsgpt-video-calling/477cd6ea-c192-43a3-b107-a2011157fa96/scratchpad/safari-stuck.png', Buffer.from(shot, 'base64'));
      console.log('screenshot saved: safari-stuck.png');
    } catch (e2) { console.log('screenshot failed too:', e2.message.slice(0, 100)); }
  }
  console.log(`\n— t=${(i + 1) * 3}s —`);
  console.log('SAFARI', JSON.stringify(s));
  console.log('BRAVE ', JSON.stringify(b));
  if (bmsgs.length) { console.log('BRAVE console:', JSON.stringify(bmsgs.slice(-6))); }
  if (s.status === 'connected' && b.status === 'connected') { console.log('CONNECTED OK'); break; }
}
try { await wd('DELETE', `/session/${sid}`); } catch {}
driver.kill();
await ctx.close();
