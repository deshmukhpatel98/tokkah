// Why did the control arm keep the dark lock? Read the app's own telemetry off
// the wire — the /log POSTs carry every camlock and luma event.
import { chromium } from 'playwright-core';

const BASE = 'http://127.0.0.1:8794';
const ARM = process.argv[2] ?? 'ladder=0&lowlight=0&revive=0';
const b = await chromium.connectOverCDP('http://127.0.0.1:9222');
const ctx = b.contexts()[0];
for (const p of ctx.pages()) if (!p.isClosed() && p.url().startsWith(BASE)) await p.close().catch(() => {});
await ctx.grantPermissions(['camera', 'microphone'], { origin: BASE });

const page = await ctx.newPage();
const events = [];
page.on('request', (r) => {
  if (!/\/log$/.test(r.url()) || r.method() !== 'POST') return;
  try {
    const body = JSON.parse(r.postData() ?? '{}');
    for (const e of body.events ?? body ?? []) events.push(e);
  } catch {}
});

let ready = false;
for (let i = 0; i < 8 && !ready; i++) {
  await page.goto(`${BASE}/?room=camlock&${ARM}`, { waitUntil: 'domcontentloaded' });
  ready = await page
    .waitForFunction(() => /ready/.test(document.getElementById('previewBadge')?.textContent ?? ''), { timeout: 8000 })
    .then(() => true)
    .catch(() => false);
  if (!ready) await page.waitForTimeout(2500);
}
if (!ready) throw new Error('lobby camera never became ready');

await page.click('#join');
await page.waitForFunction(() => window.__tape?.srcprobe != null, { timeout: 20000 }).catch(() => {});

const marks = [];
for (let i = 0; i < 14; i++) {
  await page.waitForTimeout(1000);
  marks.push(await page.evaluate(() => ({ t: Math.round(performance.now()), luma: window.__tape?.luma?.y ?? null, low: window.__tape?.lowlight?.on ?? null, lk: window.__tape?.camlock?.locked ?? null })));
}

console.log(`  arm  ${ARM}`);
console.log('  luma:  ', marks.map((m) => (m.luma == null ? '—' : m.luma)).join(' '));
console.log('  locked:', marks.map((m) => (m.lk == null ? '?' : m.lk ? 'Y' : 'n')).join('     '));
const interesting = events.filter((e) => /camlock|lowlight|luma/.test(e.t ?? e.type ?? ''));
for (const e of interesting) console.log('  ev ', JSON.stringify(e).slice(0, 220));
if (!interesting.length) console.log('  (no camlock/luma events reached the wire — sample keys:', JSON.stringify([...new Set(events.map((e) => e.t ?? e.type))].slice(0, 25)), ')');
await page.close().catch(() => {});
await b.close();
