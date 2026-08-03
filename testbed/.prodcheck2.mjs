// Is the second-arm darkness the APP or the rig? Run the control arm TWICE with
// a long gap, on a fresh tab each time, and record why the lock did or did not
// get verified. If a well-rested control arm is always bright, the rig starves
// the camera; if it still goes dark, the app has a hole.
import { chromium } from 'playwright-core';
const BASE = 'https://room.tokkah.com';
const b = await chromium.connectOverCDP('http://127.0.0.1:9222');
const ctx = b.contexts()[0];
await ctx.grantPermissions(['camera', 'microphone'], { origin: BASE });

for (let run = 1; run <= 2; run++) {
  for (const p of ctx.pages()) if (!p.isClosed() && p.url().startsWith(BASE)) await p.close().catch(() => {});
  await new Promise((r) => setTimeout(r, 6000)); // let the HAL fully release
  const page = await ctx.newPage();
  let ready = false;
  for (let i = 0; i < 8 && !ready; i++) {
    await page.goto(`${BASE}/?prodcheck=1`, { waitUntil: 'domcontentloaded' });
    ready = await page.waitForFunction(() => /ready/.test(document.getElementById('previewBadge')?.textContent ?? ''), { timeout: 9000 }).then(() => true).catch(() => false);
    if (!ready) await page.waitForTimeout(2500);
  }
  await page.click('#join');
  const m = [];
  for (let i = 0; i < 16; i++) {
    await page.waitForTimeout(1000);
    m.push(await page.evaluate(() => ({ y: window.__tape?.luma?.y ?? null, f: window.__tape?.srcprobe?.frames ?? null, lk: window.__tape?.camlock?.locked ?? null, low: window.__tape?.lowlight?.on ?? null })));
  }
  const tail = m.slice(-6).map((x) => x.y).filter((x) => x != null);
  const meanTail = tail.length ? (tail.reduce((a, c) => a + c, 0) / tail.length).toFixed(0) : '—';
  console.log(`  run ${run}  final luma ${String(meanTail).padStart(4)}  locked=${m[m.length-1].lk} lowlight=${m[m.length-1].low}`);
  console.log(`         luma   ${m.map((x) => (x.y == null ? '—' : Math.round(x.y))).join(' ')}`);
  console.log(`         frames ${m.map((x) => (x.f == null ? '—' : x.f)).join(' ')}`);
  await page.close().catch(() => {});
}
await b.close();
