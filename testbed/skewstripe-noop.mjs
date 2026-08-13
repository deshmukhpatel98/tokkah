// Skew-aware striping, same-route invariant (lane-skew spec §2.5).
//
// The spec's central safety claim is that striping is a no-op when routes do
// NOT diverge — and unlike de-skew, that it holds BY CONSTRUCTION: fastOrder is
// the identity permutation until a lane is demoted, so
// `fastOrder[(lanePos(seq) + k) % PAIRS]` reduces to `(seq % PAIRS + k) % PAIRS`
// exactly. Construction arguments are cheap to believe and cheap to be wrong
// about, so this measures it on a real prod call: six lanes down one path,
// striping ON, nothing may be demoted and the frame distribution must stay even.
//
// No netsim here on purpose — the point is the ORDINARY call, the one every
// real user makes, which must not pay for a feature aimed at divergent routes.
import { chromium } from 'playwright-core';
const CHROME = process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const A = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
const mk = (v, w) => (['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
  `--use-file-for-fake-video-capture=${A(v)}`, `--use-file-for-fake-audio-capture=${A(w)}`,
  '--autoplay-policy=no-user-gesture-required']);

async function arm(qs) {
  const bA = await chromium.launch({ executablePath: CHROME, headless: true, args: mk('realA.mjpeg', 'realA.wav') });
  const bB = await chromium.launch({ executablePath: CHROME, headless: true, args: mk('realB.mjpeg', 'realB.wav') });
  try {
    const R = `stripenoop${qs ? 'on' : 'off'}-${Date.now().toString(36)}`;
    const pA = await bA.newPage(), pB = await bB.newPage();
    await pA.goto(`https://room.tokkah.com/?r=${R}${qs}`); await pA.click('#join');
    await pB.goto(`https://room.tokkah.com/?r=${R}${qs}`); await pB.click('#join');
    for (const p of [pA, pB]) await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });
    await pA.waitForTimeout(45000);
    return await pA.evaluate(() => {
      const pc = window.__tape?.pcm;
      const s = (typeof pc?.snapshot === 'function' ? pc.snapshot() : pc) ?? {};
      const sent = (s.perAssoc ?? []).map((a) => a.framesSent);
      const total = sent.reduce((x, y) => x + y, 0);
      return {
        stripe: s.stripe ?? null,
        laneSkewMax: s.laneSkew?.max ?? null,
        m2e: s.mouthToEarMs ?? null,
        ring: s.m2eParts?.ringDepthMs ?? null,
        framesRecv: window.__tape?.pcm?.framesRecv ?? null,
        conceal: window.__tape?.pcm?.concealedMs ?? null,
        // Even distribution is the observable that a demotion would break.
        maxLaneShare: total ? +(Math.max(...sent) / total).toFixed(4) : null,
        spreadMax: s.jitSpreadMaxRun ?? null,
        sent,
      };
    });
  } finally {
    await bA.close().catch(() => {}); await bB.close().catch(() => {});
  }
}

// PCM occasionally fails to start under stacked headless Chromes; one retry.
async function armRetry(qs) {
  let s = await arm(qs);
  if (s.framesRecv == null) { console.log(`[retry] arm '${qs || 'off'}' null pcm; retrying once`); s = await arm(qs); }
  return s;
}

const on = await armRetry('&pcmskewstripe=1');
const off = await armRetry('');
console.log('stripe ON  (same route):', JSON.stringify(on));
console.log('stripe OFF (control)   :', JSON.stringify(off));

const a1 = on.stripe != null && on.stripe.nFast === 6;
console.log('assert no lane demoted (nFast === 6):', a1 ? 'PASS' : `FAIL (${JSON.stringify(on.stripe)})`);
const a2 = on.stripe?.demotions === 0;
console.log('assert zero demotions:', a2 ? 'PASS' : `FAIL (${on.stripe?.demotions})`);
const a3 = on.laneSkewMax != null && on.laneSkewMax < 8;
console.log('assert same-route skew below the 8ms demote threshold:', a3 ? 'PASS' : `FAIL (${on.laneSkewMax})`);
const a4 = on.maxLaneShare != null && on.maxLaneShare < 0.20;
console.log('assert stripe still even (max lane share < 20%):', a4 ? 'PASS' : `FAIL (${on.maxLaneShare})`);
const dd = (on.ring != null && off.ring != null) ? Math.abs(on.ring - off.ring) : null;
const a5 = dd != null && dd <= 6;
console.log('assert ring depth within 6ms of control:', a5 ? 'PASS' : `FAIL (Δ${dd})`);
const a6 = on.framesRecv > 1000 && off.framesRecv > 1000;
console.log('assert both arms played frames:', a6 ? 'PASS' : `FAIL (ON:${on.framesRecv}, OFF:${off.framesRecv})`);
const a7 = on.conceal != null && off.conceal != null && on.conceal <= off.conceal + 200;
console.log('assert no added concealment:', a7 ? 'PASS' : `FAIL (ON:${on.conceal}, OFF:${off.conceal})`);

process.exitCode = (a1 && a2 && a3 && a4 && a5 && a6 && a7) ? 0 : 1;
