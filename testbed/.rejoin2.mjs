// Does the REMAINING peer's call actually come back to life when someone
// rejoins? Status text is not evidence — measure the remote picture on both
// sides before and after.
import { chromium } from 'playwright-core';

const CHROME =
  '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const BASE = process.argv[2] ?? 'http://127.0.0.1:8795';

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

// The remote picture, three ways: the <video> element, the tape lane's own
// frame counter, and inbound RTP. Any one of them alone can lie.
const probe = (p) =>
  p.evaluate(async () => {
    const v = document.getElementById('remote');
    const t = (id) => document.getElementById(id)?.textContent?.trim() ?? null;
    const vis = (id) => {
      const e = document.getElementById(id);
      return e ? getComputedStyle(e).display !== 'none' && getComputedStyle(e).visibility !== 'hidden' : null;
    };
    let inboundFrames = null;
    try {
      const s = await window.__tape?.pc?.getStats();
      s?.forEach((r) => {
        if (r.type === 'inbound-rtp' && r.kind === 'video') inboundFrames = r.framesDecoded ?? null;
      });
    } catch {}
    return {
      status: t('status'),
      waitingShown: vis('waiting'),
      remoteSize: v ? `${v.videoWidth}x${v.videoHeight}` : null,
      remoteTime: v ? +v.currentTime.toFixed(2) : null,
      tapeFrames: window.__tape?.video?.recv?.frames ?? window.__tape?.video?.rxFrames ?? null,
      inboundFrames,
      pc: window.__tape?.pc?.connectionState ?? null,
      role: window.__tape?.tel?.role ?? null,
    };
  });

const show = async (tag, p) => {
  const a = await probe(p);
  await p.waitForTimeout(3000);
  const b = await probe(p);
  const moving =
    (b.remoteTime ?? 0) > (a.remoteTime ?? 0) ||
    (b.inboundFrames ?? 0) > (a.inboundFrames ?? 0) ||
    (b.tapeFrames ?? 0) > (a.tapeFrames ?? 0);
  console.log(
    `  ${tag.padEnd(9)} status:${String(b.status).padEnd(22)} role:${b.role} waiting:${String(b.waitingShown).padEnd(5)} ` +
      `size:${String(b.remoteSize).padEnd(9)} vidTime:${a.remoteTime}→${b.remoteTime} decoded:${a.inboundFrames}→${b.inboundFrames} ` +
      `tape:${a.tapeFrames}→${b.tapeFrames}  PICTURE ${moving ? 'LIVE' : '*** FROZEN ***'}`,
  );
  return moving;
};

async function ready(page, url) {
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page
    .waitForFunction(() => /ready|blocked|no camera/.test(document.getElementById('previewBadge')?.textContent ?? ''), { timeout: 25000 })
    .catch(() => {});
}

const A = await launch('A');
const B = await launch('B');
try {
  await ready(A.page, BASE);
  await A.page.click('#join');
  await A.page.waitForTimeout(3000);
  const link = await A.page.evaluate(() => document.getElementById('shareUrl').value);
  await ready(B.page, link);
  await B.page.click('#join');
  await A.page.waitForTimeout(12000);

  console.log('\n--- baseline: first call up ---');
  await show('A', A.page);
  await show('B', B.page);

  console.log('\n--- A reloads and rejoins the same room ---');
  const roomUrl = A.page.url();
  await ready(A.page, roomUrl);
  await A.page.click('#join');
  await A.page.waitForTimeout(14000);
  const aLive = await show('A(new)', A.page);
  const bLive = await show('B(stay)', B.page);

  console.log(`\n  VERDICT: rejoin ${aLive && bLive ? 'RECOVERS both sides' : 'DOES NOT recover'}` +
    `${aLive ? '' : ' — new joiner has no picture'}${bLive ? '' : ' — the one who stayed has no picture'}`);
} catch (e) {
  console.log('  HARNESS ERROR:', e.message);
} finally {
  const errs = [...new Set([...A.errors, ...B.errors])];
  console.log('\n=== page errors ===');
  console.log(errs.length ? errs.slice(0, 20).map((e) => '  ' + e).join('\n') : '  none');
  await A.browser.close();
  await B.browser.close();
}
