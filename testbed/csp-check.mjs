// Tightening connect-src can kill the signalling socket, and the failure mode is
// a call that just never connects — so read the header AND make a real call AND
// listen for securitypolicyviolation, which is the only thing that names the
// directive that blocked something. A silent pass on any one of the three is not
// evidence.
import { chromium } from './node_modules/playwright-core/index.mjs';
const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';

const h = await fetch('https://room.tokkah.com/', { headers: { accept: 'text/html' } });
const csp = h.headers.get('content-security-policy');
console.log('CSP:', csp, '\n');
const pinned = /connect-src [^;]*wss:\/\/room\.tokkah\.com/.test(csp ?? '');
const wildcard = /connect-src [^;]*(\bws:(?!\/\/)|\bwss:(?!\/\/))/.test(csp ?? '');

const mk = async () => {
  const c = await chromium.launchPersistentContext('', {
    executablePath: CHROME, headless: true,
    args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
      '--use-file-for-fake-video-capture=/Users/earningsgpt/video calling/testbed/media/cam1080.mjpeg',
      '--use-file-for-fake-audio-capture=/Users/earningsgpt/video calling/testbed/media/conv/A.wav',
      '--autoplay-policy=no-user-gesture-required'], viewport: { width: 1280, height: 720 },
  });
  const p = await c.newPage();
  await p.addInitScript(() => {
    window.__csp = [];
    addEventListener('securitypolicyviolation', (e) =>
      window.__csp.push(`${e.violatedDirective} <- ${String(e.blockedURI).slice(0, 80)}`));
  });
  return { c, p };
};

const room = 'csp' + Math.random().toString(36).slice(2, 7);
const A = await mk(), B = await mk();
for (const e of [A, B]) {
  await e.p.goto(`https://room.tokkah.com/?r=${room}`, { waitUntil: 'domcontentloaded' });
  await e.p.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 25000 });
}
await A.p.click('#join'); await A.p.waitForTimeout(700); await B.p.click('#join');
let connected = true;
for (const e of [A, B]) {
  await e.p.waitForFunction(() => document.querySelector('#status')?.textContent === 'connected', null, { timeout: 30000 })
    .catch(() => { connected = false; });
}
await A.p.waitForTimeout(5000);

const report = [];
for (const [n, e] of [['A', A], ['B', B]]) {
  report.push({
    who: n,
    viol: await e.p.evaluate(() => window.__csp),
    code: await e.p.evaluate(() => window.__tape?.security?.code ?? null),
    // A picture, because "connected" has lied before.
    pic: await e.p.evaluate(() => {
      const rc = document.getElementById('remoteCanvas');
      const el = rc && rc.width > 1 ? rc : document.getElementById('remote');
      const c = document.createElement('canvas'); c.width = 64; c.height = 36;
      const g = c.getContext('2d', { willReadFrequently: true });
      try { g.drawImage(el, 0, 0, 64, 36); } catch { return null; }
      const d = g.getImageData(0, 0, 64, 36).data;
      let s = 0, s2 = 0, n2 = 0;
      for (let i = 0; i < d.length; i += 4) { const y = 0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2]; s += y; s2 += y * y; n2++; }
      const m = s / n2;
      return +Math.sqrt(Math.max(0, s2 / n2 - m * m)).toFixed(1);
    }),
  });
}
for (const e of [A, B]) await e.c.close();

for (const r of report) console.log(`${r.who}: violations=${JSON.stringify(r.viol)}  code=${r.code}  lumaSd=${r.pic}`);
// Split the verdict: a connect-src violation means I broke signalling. Anything
// else here is the CSP stopping a script that is not ours — the point of it.
const isConn = (v) => v.startsWith('connect-src');
const clean = report.every((r) => r.viol.filter(isConn).length === 0);
const foreign = [...new Set(report.flatMap((r) => r.viol.filter((v) => !isConn(v))))];
const pics = report.every((r) => r.pic > 8);
console.log(`\npinned to host      ${pinned}`);
console.log(`wildcard ws removed ${!wildcard}`);
console.log(`no connect-src block ${clean}`);
console.log(`blocked (not ours)  ${foreign.length ? foreign.join(' | ') : 'none'}`);
console.log(`call connected      ${connected}`);
console.log(`real picture both   ${pics}`);
console.log(pinned && !wildcard && clean && connected && pics ? '\nPASS' : '\nFAIL');
