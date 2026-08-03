// Where does lane 2's extra ~18 ms live: inside our lane, or under it?
//
// Ten optional components measured at zero (avoff, avsync, vprev, sendnow, l2fec,
// l2retx, l2pace, l2rc, l2canvas) — so the cost is structural to the path, not a
// setting. The two candidate structures are ours (worker hops, carrier tick
// quantisation) and libwebrtc's (send pacer, depacketizer, jitter buffer).
//
// Each lane already timestamps frames against a synced clock and reports the age of
// a frame when it reaches the lane's own output: `ageP50`. That splits the question
// without any new instrument:
//
//   ageP50 ~= glass-to-glass   -> the time is inside our lane, and is ours to fix
//   ageP50 << glass-to-glass   -> the time is under us, between the wire and the
//                                 pixels, which on lane 2 means libwebrtc's RTP path
//
// The clock bound is TIME_SYNC's minRtt/2 and the offset is a symmetric-path
// assumption, so treat ageP50 as a measurement with a known bias, not ground truth.
// It is being used here only to tell tens of ms from single-digit ms.
import { chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';
const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const TB = '/Users/earningsgpt/video calling/testbed';

const mk = async (fix) => {
  const c = await chromium.launchPersistentContext('', {
    executablePath: CHROME, headless: true,
    args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
      `--use-file-for-fake-video-capture=${fix}`,
      `--use-file-for-fake-audio-capture=${TB}/media/conv/A.wav`,
      '--autoplay-policy=no-user-gesture-required'],
    viewport: { width: 1280, height: 800 },
  });
  return { c, p: await c.newPage() };
};

for (const [name, qs] of [['lane2 (default)', ''], ['lane1 (datachannel)', '&tape=1']]) {
  const A = await mk(`${TB}/media/timecode720.y4m`), B = await mk(`${TB}/media/timecode720b.y4m`);
  const boot = async (e, url) => {
    await e.p.goto(url, { waitUntil: 'domcontentloaded' });
    await e.p.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 30000 });
    await e.p.click('#join');
  };
  await boot(A, `https://room.tokkah.com/?r=age${Math.random().toString(36).slice(2, 7)}${qs}`);
  await A.p.waitForFunction(() => /waiting|connected/i.test(document.querySelector('#status')?.textContent ?? ''), null, { timeout: 20000 });
  await boot(B, await A.p.evaluate(() => location.href));
  await B.p.waitForFunction(() => {
    const c = document.getElementById('remoteCanvas'), v = document.getElementById('remote');
    return (c && c.width > 1) || (v && v.videoWidth > 0);
  }, null, { timeout: 45000 });
  await B.p.waitForTimeout(14000); // let ageMs fill and the clock sync settle

  const s = await B.p.evaluate(() => {
    const v = window.__tape?.video ?? {};
    return { ageP50: v.ageP50, ageP95: v.ageP95, rttMs: v.rttMs, offset: v.clockOffsetMs,
             framesOut: v.framesOut, framesLost: v.framesLost, mode: window.__tape?.tapeMode };
  });
  for (const e of [A, B]) await e.c.close();
  console.log(`${name.padEnd(20)} ageP50 ${String(s.ageP50).padStart(6)} ms   ageP95 ${String(s.ageP95).padStart(6)} ms` +
              `   rtt ${s.rttMs}   offset ${s.offset}   out ${s.framesOut} lost ${s.framesLost}` +
              `   ${JSON.stringify(s.mode)}`);
}
