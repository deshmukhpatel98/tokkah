/**
 * slowclock.mjs — when a sender's seq clock runs slower than wall time, does
 * the receiver play the audio that exists, or conceal the entire call?
 *
 * Born from a LIVE call (ver-kbqe-zzs, 2026-08-16): an Android phone whose CPU
 * was crushed by video encode captured audio at 54 of 125 frames/s. The
 * receiver's playhead runs at wall time, outran the stream within a second,
 * and then EVERY frame was late — hiSeq frozen since priming, depth −111 s by
 * call end, 100% concealment while every transport counter read healthy. The
 * one pre-existing re-seed is gated on `play < 0`, unreachable after playout
 * starts.
 *
 * STIMULUS: the sender carries ?pcmslowclock=0.43 — capture frames decimated
 * and renumbered contiguously on a 0.43x clock, the live defect's exact
 * signature (contiguous seqs, seq/capUs lockstep, advance < wall rate).
 *
 * Arms (sequential; the RECEIVER is the system under test):
 *   control (&reanchor=0)  the defect must REPRODUCE: reAnchors 0, late ≈ recv,
 *                          depth diving unbounded, conceal ≈ 100% of playout.
 *   fix (default)          reAnchors > 0, a meaningful share of received frames
 *                          actually lands (recv − late), depth bounded, played
 *                          frames advancing — the audio that exists is heard.
 *
 *   node testbed/slowclock.mjs
 */
import { chromium } from 'playwright-core';
import os from 'node:os';

const BASE = process.env.URL ?? 'https://room.tokkah.com';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);

const RATE = 0.43;      // the live phone's measured capture rate
const RUN_S = 45;       // enough for several re-anchor cycles at 1 s drought each

const launch = (side) => chromium.launch({
  executablePath: CHROME, headless: true,
  args: [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    `--use-file-for-fake-video-capture=${media(`real${side}.mjpeg`)}`,
    `--use-file-for-fake-audio-capture=${media(`real${side}.wav`)}`,
    '--autoplay-policy=no-user-gesture-required',
    '--disable-features=WebRtcHideLocalIpsWithMdns',
  ],
});

const snap = (p) => p.evaluate(() => {
  const q = window.__tape?.pcm ?? null;
  return q && {
    recv: q.framesRecv, late: q.lateFrames, conceal: q.lostFrames,
    depth: q.depthMs, reAnchors: q.reAnchors ?? null, played: q.playedFrames ?? null,
  };
});

async function arm(label, recvExtra) {
  const room = `sc-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 5)}`;
  const S = await launch('A'), R = await launch('B');
  try {
    const s = await S.newPage(), r = await R.newPage();
    // Receiver joins FIRST and sits primed; the slow sender joins second — the
    // live call's shape (a waited, the phone arrived).
    await r.goto(`${BASE}/?r=${room}${recvExtra}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await r.waitForSelector('#join', { timeout: 20000 });
    await r.click('#join').catch(() => {});
    await r.waitForTimeout(1200);
    await s.goto(`${BASE}/?r=${room}&pcmslowclock=${RATE}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await s.waitForSelector('#join', { timeout: 20000 });
    await s.click('#join').catch(() => {});
    for (const p of [s, r]) {
      await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });
    }
    await r.waitForTimeout(RUN_S * 1000);
    const end = await snap(r);
    if (!end) throw new Error(`${label}: PCM lane not running on receiver`);
    // Stimulus confirmation from the receiver's own counters: the sender's
    // clock must actually be slow — received frames per wall second well below
    // the 125/s a healthy sender delivers. Without this, an unstimulated call
    // and a fixed one are indistinguishable.
    const recvRate = end.recv / RUN_S;
    const landed = end.recv - end.late;
    const rr = { ...end, recvRate: +recvRate.toFixed(1), landed };
    console.log(`  [${label}] recv=${end.recv} (${rr.recvRate}/s) late=${end.late} landed=${landed} ` +
      `conceal=${end.conceal} depth=${end.depth}ms reAnchors=${end.reAnchors}`);
    return rr;
  } finally {
    await S.close(); await R.close();
  }
}

{
  const load = os.loadavg()[0] / os.cpus().length;
  console.log(`host load ${(100 * load).toFixed(0)}% of ${os.cpus().length} cores`);
  if (load > 0.7) { console.error('ABORT: host too busy for timing-sensitive arms'); process.exit(3); }
}

const control = await arm('control', '&reanchor=0');
const fix = await arm('fix', '');

let fails = 0;
const check = (name, ok, detail) => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  (${detail})`);
  if (!ok) fails++;
};

// VOID beats a false verdict: both arms must have genuinely received a slow
// stream (well under the healthy 125/s, and enough frames to judge).
for (const [n, r] of [['control', control], ['fix', fix]]) {
  if (r.recvRate > 90 || r.recv < 500) {
    console.error(`VOID: ${n} arm received ${r.recv} frames at ${r.recvRate}/s — the slow-clock stimulus did not land`);
    process.exit(3);
  }
}

check('the defect reproduces without the fix (control arm)',
  control.reAnchors === 0 && control.late >= 0.9 * control.recv && control.depth != null && control.depth < -5000,
  `control reAnchors=${control.reAnchors} late=${control.late}/${control.recv} depth=${control.depth}ms`);
check('the fix re-anchors under the same stream', fix.reAnchors >= 3,
  `fix reAnchors=${fix.reAnchors} over ${RUN_S}s`);
check('received audio actually LANDS in the ring (not all late)',
  fix.landed >= 0.4 * fix.recv,
  `fix landed=${fix.landed} of ${fix.recv} recv (control landed ${control.landed})`);
check('depth stays bounded instead of diving',
  fix.depth != null && fix.depth > -2000,
  `fix depth=${fix.depth}ms vs control ${control.depth}ms`);
console.log(fails === 0 ? '\nVERDICT: PASS' : `\nVERDICT: FAIL (${fails})`);
process.exit(fails ? 1 : 0);
