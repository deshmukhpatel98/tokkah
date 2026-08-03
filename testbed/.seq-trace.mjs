// The gate runs default, THEN control, on the same tab — and only the second
// arm stays dark. Reproduce that sequence exactly and watch luma + lock state.
import { chromium } from 'playwright-core';

const BASE = 'http://127.0.0.1:8794';
const b = await chromium.connectOverCDP('http://127.0.0.1:9222');
const ctx = b.contexts()[0];
for (const p of ctx.pages()) if (!p.isClosed() && p.url().startsWith(BASE)) await p.close().catch(() => {});
await ctx.grantPermissions(['camera', 'microphone'], { origin: BASE });
const page = await ctx.newPage();

async function arm(label, query, secs) {
  let ready = false;
  for (let i = 0; i < 8 && !ready; i++) {
    await page.goto(`${BASE}/?${query}`, { waitUntil: 'domcontentloaded' });
    ready = await page
      .waitForFunction(() => /ready|blocked/.test(document.getElementById('previewBadge')?.textContent ?? ''), { timeout: 10000 })
      .then(() => page.evaluate(() => /ready/.test(document.getElementById('previewBadge').textContent)))
      .catch(() => false);
    if (!ready) await page.waitForTimeout(2000);
  }
  const badge = await page.evaluate(() => document.getElementById('previewBadge').textContent);
  await page.click('#join');
  const marks = [];
  for (let i = 0; i < secs; i++) {
    await page.waitForTimeout(1000);
    marks.push(
      await page.evaluate(() => ({
        luma: window.__tape?.luma?.y ?? null,
        lk: window.__tape?.camlock ?? null,
        f: window.__tape?.srcprobe?.frames ?? null,
      })),
    );
  }
  const last = marks[marks.length - 1];
  console.log(`\n  ${label}  (lobby: ${badge.trim()})`);
  console.log('    luma  ', marks.map((m) => (m.luma == null ? '—' : Math.round(m.luma))).join(' '));
  console.log('    frames', marks.map((m) => (m.f == null ? '—' : m.f)).join(' '));
  console.log('    final camlock', JSON.stringify(last.lk));
}

await arm('ARM 1 — default', '', 14);
await arm('ARM 2 — control (same tab, straight after)', 'ladder=0&lowlight=0&revive=0', 14);

await page.close().catch(() => {});
await b.close();
