// Reproduce the join flow the way a person actually does it, against whatever
// base URL is given. Arm 1: A starts a call, B opens the link. Arm 2: A reloads
// mid-call and rejoins the same room (the thing everyone does when it looks stuck).
import { chromium } from 'playwright-core';

const CHROME =
  '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const BASE = process.argv[2] ?? 'https://room.tokkah.com';
const QS = process.argv[3] ?? '';

async function launch(tag) {
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
  const page = await browser.newPage();
  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(`[${tag}] ${m.text().slice(0, 200)}`); });
  page.on('pageerror', (e) => errors.push(`[${tag}] pageerror: ${String(e.message).slice(0, 200)}`));
  return { browser, page, errors, tag };
}

const snap = (p) =>
  p.evaluate(() => {
    const t = (id) => document.getElementById(id)?.textContent?.trim() ?? null;
    const vis = (id) => {
      const e = document.getElementById(id);
      if (!e) return null;
      return getComputedStyle(e).display !== 'none' && getComputedStyle(e).visibility !== 'hidden';
    };
    return {
      lobbyShown: vis('lobby'),
      callShown: vis('call'),
      status: t('status'),
      joinStatus: t('joinStatus'),
      previewBadge: t('previewBadge'),
      joinDisabled: document.getElementById('join')?.disabled ?? null,
      waitingShown: vis('waiting'),
      shareUrl: document.getElementById('shareUrl')?.value ?? null,
      role: window.__tape?.tel?.role ?? null,
      pcState: window.__tape?.pc?.connectionState ?? null,
      iceState: window.__tape?.pc?.iceConnectionState ?? null,
      url: location.href,
    };
  });

async function waitReady(page, url) {
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page
    .waitForFunction(() => /ready|blocked|no camera/.test(document.getElementById('previewBadge')?.textContent ?? ''), { timeout: 25000 })
    .catch(() => {});
}

const line = (tag, s) =>
  console.log(
    `  ${tag.padEnd(8)} lobby:${String(s.lobbyShown).padEnd(5)} call:${String(s.callShown).padEnd(5)} ` +
      `status:${String(s.status).padEnd(34)} role:${String(s.role).padEnd(4)} pc:${String(s.pcState).padEnd(12)} ice:${s.iceState}` +
      (s.joinStatus ? `\n           joinStatus: ${s.joinStatus}` : ''),
  );

const A = await launch('A');
const B = await launch('B');
const allErrs = [];

try {
  console.log(`\n=== ARM 1: A starts a call, B opens the link  (${BASE}${QS}) ===`);
  await waitReady(A.page, BASE + QS);
  console.log('  A lobby:', (await snap(A.page)).previewBadge);
  await A.page.click('#join');
  await A.page.waitForTimeout(6000);
  let a = await snap(A.page);
  line('A(join)', a);

  const link = a.shareUrl;
  console.log('  share link:', link);
  if (!link) throw new Error('A never produced a share link — join did not reach the call screen');

  const bUrl = QS ? link + (link.includes('?') ? '&' : '?') + QS.replace(/^\?/, '') : link;
  await waitReady(B.page, bUrl);
  await B.page.click('#join');

  // Watch both sides for 25 s.
  for (let i = 1; i <= 5; i++) {
    await A.page.waitForTimeout(5000);
    const sa = await snap(A.page);
    const sb = await snap(B.page);
    console.log(`  --- t+${i * 5}s`);
    line('A', sa);
    line('B', sb);
  }

  console.log(`\n=== ARM 2: A reloads and rejoins the same room ===`);
  const roomUrl = A.page.url();
  await waitReady(A.page, roomUrl);
  await A.page.click('#join');
  await A.page.waitForTimeout(8000);
  line('A(re)', await snap(A.page));
  line('B', await snap(B.page));
} catch (e) {
  console.log('  HARNESS ERROR:', e.message);
} finally {
  allErrs.push(...A.errors, ...B.errors);
  console.log('\n=== page errors ===');
  if (!allErrs.length) console.log('  none');
  for (const e of [...new Set(allErrs)].slice(0, 25)) console.log('  ' + e);
  await A.browser.close();
  await B.browser.close();
}
