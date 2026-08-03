// §15 lobby: device pickers, real level meter, capacity badge, headphone check.
// Run on the phone — the only place with a real camera, a real mic and a speaker.
import { chromium } from 'playwright-core';
const BASE = process.argv[2] ?? 'http://127.0.0.1:8794';
const b = await chromium.connectOverCDP('http://127.0.0.1:9222');
const ctx = b.contexts()[0];
for (const p of ctx.pages()) if (!p.isClosed() && p.url().startsWith(BASE)) await p.close().catch(() => {});
await ctx.grantPermissions(['camera', 'microphone'], { origin: BASE });
await new Promise((r) => setTimeout(r, 5000));
const page = await ctx.newPage();
const errs = [];
page.on('pageerror', (e) => errs.push(String(e).slice(0, 160)));
page.on('console', (m) => { if (m.type() === 'error' && !/503|Failed to load resource/.test(m.text())) errs.push(m.text().slice(0, 160)); });

await page.goto(BASE, { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => /ready|blocked/.test(document.getElementById('previewBadge')?.textContent ?? ''), { timeout: 20000 });
await page.waitForTimeout(2500);

const snap = await page.evaluate(() => {
  const t = (id) => document.getElementById(id)?.textContent?.trim() ?? null;
  const sel = (id) => { const e = document.getElementById(id); return e ? { n: e.options.length, val: e.selectedOptions[0]?.textContent ?? null, shown: e.style.display !== 'none' } : null; };
  return { badge: t('previewBadge'), cap: t('capBadge'), capLocked: document.getElementById('capBadge')?.classList.contains('locked'),
           cam: sel('camSel'), mic: sel('micSel'), hp: t('hpOut'),
           barRight: document.getElementById('levelBar')?.style.right ?? null };
});
console.log('  badge      ', snap.badge);
console.log('  capBadge   ', snap.cap, '| locked:', snap.capLocked);
console.log('  camera sel ', JSON.stringify(snap.cam));
console.log('  mic sel    ', JSON.stringify(snap.mic));

// Level meter: sample the bar over 3 s. A REAL meter moves; a broken one is pinned.
const vals = [];
for (let i = 0; i < 15; i++) { await page.waitForTimeout(200); vals.push(await page.evaluate(() => document.getElementById('levelBar').style.right)); }
const uniq = [...new Set(vals)];
console.log('  level bar  ', uniq.length > 1 ? `MOVING (${uniq.length} distinct of 15)` : `STUCK at ${vals[0]}`);
console.log('             ', vals.slice(0, 8).join(' '));

// Headphone check — the phone has a loudspeaker and no headphones, so it should say "speakers".
await page.click('#hpCheck');
await page.waitForFunction(() => !/listening|not checked/.test(document.getElementById('hpOut').textContent), { timeout: 20000 }).catch(() => {});
console.log('  hp check   ', await page.evaluate(() => document.getElementById('hpOut').textContent.trim()));
console.log('  page errors', errs.length ? errs : 'none');
await page.close().catch(() => {});
await b.close();
