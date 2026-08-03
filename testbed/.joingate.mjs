// Join gate: every way two people actually get into a room, plus the ways it
// used to die. Each scenario ends with a hard LIVE/DEAD verdict read off the
// picture, never off the status text.
import { chromium } from 'playwright-core';

const CHROME =
  '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const BASE = process.argv[2] ?? 'http://127.0.0.1:8795';
const results = [];

async function launch() {
  const browser = await chromium.launch({
    executablePath: CHROME,
    headless: true,
    args: [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      '--autoplay-policy=no-user-gesture-required',
      '--alsa-output-device=null',
      '--disable-features=WebRtcHideLocalIpsWithMdns',
    ],
  });
  return browser;
}
async function newPage(browser, tag, errs) {
  const page = await browser.newPage();
  page.on('console', (m) => { if (m.type() === 'error' && !/Content Security Policy|cloudflareinsights/.test(m.text())) errs.push(`[${tag}] ${m.text().slice(0, 160)}`); });
  page.on('pageerror', (e) => errs.push(`[${tag}] pageerror: ${String(e.message).slice(0, 160)}`));
  return page;
}
async function ready(page, url) {
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page
    .waitForFunction(() => /ready|blocked|no camera/.test(document.getElementById('previewBadge')?.textContent ?? ''), { timeout: 25000 })
    .catch(() => {});
}
const probe = (p) =>
  p.evaluate(async () => {
    const v = document.getElementById('remote');
    let decoded = null;
    try { (await window.__tape?.pc?.getStats())?.forEach((r) => { if (r.type === 'inbound-rtp' && r.kind === 'video') decoded = r.framesDecoded ?? null; }); } catch {}
    return {
      status: document.getElementById('status')?.textContent?.trim() ?? null,
      joinStatus: document.getElementById('joinStatus')?.textContent?.trim() ?? null,
      lobby: getComputedStyle(document.getElementById('lobby')).display !== 'none',
      size: v ? `${v.videoWidth}x${v.videoHeight}` : null,
      t: v ? +v.currentTime.toFixed(2) : null,
      decoded,
      role: window.__tape?.tel?.role ?? null,
      url: location.href,
    };
  });
// "Live" means the picture moved between two samples 2.5 s apart AND the
// element has real dimensions. Either alone has lied here before.
async function live(p) {
  const a = await probe(p);
  await p.waitForTimeout(2500);
  const b = await probe(p);
  return { ok: (b.t ?? 0) > (a.t ?? 0) && /^[1-9]/.test(b.size ?? ''), s: b, moved: `${a.t}→${b.t}`, dec: `${a.decoded}→${b.decoded}` };
}
function record(name, pass, detail) {
  results.push({ name, pass, detail });
  console.log(`  ${pass ? 'PASS' : 'FAIL'}  ${name}\n        ${detail}`);
}

const errs = [];
const bA = await launch();
const bB = await launch();
const bC = await launch();
try {
  // ── 1. Cold start: A mints a room, B follows the link ─────────────────────
  let A = await newPage(bA, 'A', errs);
  await ready(A, BASE);
  await A.click('#join');
  await A.waitForTimeout(2500);
  const link = await A.evaluate(() => document.getElementById('shareUrl').value);
  let B = await newPage(bB, 'B', errs);
  await ready(B, link);
  await B.click('#join');
  await A.waitForTimeout(9000);
  let la = await live(A), lb = await live(B);
  record('cold start — A mints, B follows the link', la.ok && lb.ok,
    `A ${la.s.role} ${la.s.size} ${la.moved} | B ${lb.s.role} ${lb.s.size} ${lb.moved}`);

  // ── 2. A third person on a full room gets a sentence, not a hang ──────────
  const C = await newPage(bC, 'C', errs);
  await ready(C, link);
  await C.click('#join');
  await C.waitForTimeout(6000);
  const pc3 = await probe(C);
  record('full room — third person is told, and stays in the lobby',
    pc3.lobby === true && /already two people|couldn’t join|couldn't join/i.test(pc3.joinStatus ?? ''),
    `lobby:${pc3.lobby} joinStatus:"${pc3.joinStatus}"`);
  await C.close();

  // ── 3. The reported bug: one side reloads mid-call ────────────────────────
  await ready(A, A.url());
  await A.click('#join');
  await A.waitForTimeout(14000);
  la = await live(A); lb = await live(B);
  record('reload mid-call — both sides come back',
    la.ok && lb.ok, `A ${la.s.role} ${la.s.size} ${la.moved} | B ${lb.s.role} ${lb.s.size} ${lb.moved}`);

  // ── 4. Drop and come back: B closes the tab entirely ──────────────────────
  await B.close();
  await A.waitForTimeout(3000);
  B = await newPage(bB, 'B2', errs);
  await ready(B, link);
  await B.click('#join');
  await A.waitForTimeout(16000);
  la = await live(A); lb = await live(B);
  record('drop and return — B closes the tab, reopens the link',
    la.ok && lb.ok, `A ${la.s.role} ${la.s.size} ${la.moved} | B ${lb.s.role} ${lb.s.size} ${lb.moved}`);

  // ── 5. Do it again immediately: the re-arm must not ping-pong ─────────────
  await B.close();
  await A.waitForTimeout(2000);
  B = await newPage(bB, 'B3', errs);
  await ready(B, link);
  await B.click('#join');
  await A.waitForTimeout(18000);
  la = await live(A); lb = await live(B);
  record('second return inside the cooldown — still connects, no reload loop',
    la.ok && lb.ok, `A ${la.s.role} ${la.s.size} ${la.moved} | B ${lb.s.role} ${lb.s.size} ${lb.moved}`);
} catch (e) {
  record('harness', false, e.message);
} finally {
  console.log('\n=== page errors ===');
  const u = [...new Set(errs)];
  console.log(u.length ? u.slice(0, 15).map((e) => '  ' + e).join('\n') : '  none');
  const failed = results.filter((r) => !r.pass).length;
  console.log(`\n=== ${results.length - failed}/${results.length} scenarios pass ===`);
  await bA.close(); await bB.close(); await bC.close();
  process.exit(failed ? 1 : 0);
}
