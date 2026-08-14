#!/usr/bin/env node
/**
 * lab-verify.mjs — does the live laboratory actually work on a real call?
 *
 * Four claims, each with the arm that could genuinely fail:
 *
 *   1. read      `snap` returns real pipeline numbers from BOTH occupants.
 *   2. steer     `set qp=` changes the encoder mid-call AND the bitrate moves
 *                in the right direction. Checking only that the field echoed
 *                back would prove the message arrived, not that anything
 *                happened — the knob has to be shown doing work.
 *   3. ask       `say` reaches the human's screen.
 *   4. SHIP      `reload` replaces the code on one side WITHOUT the other side
 *                seeing a departure. This is the one the whole idea rests on,
 *                and it is the one most likely to be wrong, so it is asserted
 *                from the PEER's point of view: B must never leave the call
 *                while A is being reloaded.
 *
 *   node testbed/lab-verify.mjs
 */
import { chromium } from 'playwright-core';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';

const BASE = process.env.URL ?? 'https://room.tokkah.com';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
const ROOM = `labv-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 5)}`;

const key = process.env.TOKKAH_LAB_KEY
  ?? readFileSync(`${homedir()}/.config/tokkah/cf.env`, 'utf8').match(/^export TOKKAH_LAB_KEY=(.+)$/m)?.[1]?.trim();
if (!key) { console.error('no TOKKAH_LAB_KEY'); process.exit(2); }

const post = async (body) => {
  const r = await fetch(`${BASE}/api/room/${ROOM}/lab`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-lab-key': key },
    body: JSON.stringify(body),
  });
  return { status: r.status, body: JSON.parse(await r.text()) };
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ask = async (body, waitMs = 2000) => {
  await post({ op: 'drain' });
  await post(body);
  await sleep(waitMs);
  return (await post({ op: 'drain' })).body.replies ?? [];
};

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

let fails = 0;
const arm = (name, ok, detail) => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  (${detail})`);
  if (!ok) fails++;
};

const A = await launch('A'), B = await launch('B');
try {
  const a = await A.newPage(), b = await B.newPage();
  for (const [p, who] of [[a, 'A'], [b, 'B']]) {
    await p.goto(`${BASE}/?r=${ROOM}`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await p.waitForSelector('#join', { timeout: 20000 });
    await p.click('#join').catch(() => {});
    if (who === 'A') await p.waitForTimeout(1200);
  }
  for (const p of [a, b]) {
    await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });
  }
  await a.waitForTimeout(20000); // let the lane settle and the numbers fill in

  // ── 1. read ───────────────────────────────────────────────────────────────
  const snaps = await ask({ op: 'snap' });
  const withVideo = snaps.filter((r) => r.video && typeof r.video.mbps === 'number');
  arm('snap reads both ends', snaps.length >= 2 && withVideo.length >= 1,
    `${snaps.length} replies, ${withVideo.length} carrying video numbers`);
  for (const r of snaps) {
    console.log(`      ${r.role}: qp=${r.video?.qp} ${r.video?.mbps}Mbps g2g=${r.video?.glassToGlassMs}ms ` +
      `m2e=${r.audio?.mouthToEarMs}ms path=${r.pair?.path}`);
  }

  // ── 2. steer: the knob must MOVE BITS, not just echo ──────────────────────
  const mbpsOf = (rs) => {
    const v = rs.map((r) => r.video?.mbps).filter((x) => typeof x === 'number');
    return v.length ? v.reduce((s, x) => s + x, 0) / v.length : null;
  };
  const before = mbpsOf(await ask({ op: 'snap' }));
  const setRes = await ask({ op: 'set', qp: 38 });
  await sleep(15000); // the rate is a windowed average; give it a window
  const after = mbpsOf(await ask({ op: 'snap' }));
  const echoed = setRes.every((r) => r.applied?.qp === 38);
  const dropped = before != null && after != null && after < before * 0.85;
  arm('set qp moves the encoder', echoed && dropped,
    `qp echoed=${echoed}, ${before?.toFixed(2)} -> ${after?.toFixed(2)} Mbps`);
  // Refusal is part of the contract: anything not on the whitelist must bounce.
  const refuse = await ask({ op: 'set', qp: 24, nonsense: 1, h: 99999 });
  arm('set refuses what it does not own', refuse.every((r) => (r.refused ?? []).includes('nonsense')),
    `refused=${JSON.stringify(refuse[0]?.refused ?? null)}`);

  // ── 3. ask the human ──────────────────────────────────────────────────────
  await ask({ op: 'say', text: 'lab-verify probe' });
  const shown = await a.evaluate(() => document.getElementById('status')?.textContent ?? '');
  arm('say reaches the screen', shown.includes('lab-verify'), `status="${shown}"`);

  // ── 4. SHIP: reload A, and B must not notice ──────────────────────────────
  // Sampled continuously rather than once at the end: a peer that bounced out
  // and recovered inside the sampling gap would otherwise read as never having
  // left, which is exactly the failure this arm exists to catch.
  const watch = [];
  const poll = setInterval(async () => {
    try {
      watch.push(await b.evaluate(() => ({
        conn: window.__tape?.pc?.connectionState ?? null,
        lobby: !!document.getElementById('join')?.offsetParent,
        status: document.getElementById('status')?.textContent ?? '',
      })));
    } catch { /* page busy */ }
  }, 500);
  await post({ op: 'reload', only: 'a', delayMs: 0 });
  await sleep(20000);
  clearInterval(poll);
  const bWentToLobby = watch.some((w) => w.lobby);
  const bSawThemLeave = watch.some((w) => /they left/i.test(w.status));
  arm('reloading A never drops B', !bWentToLobby && !bSawThemLeave,
    `${watch.length} samples, lobby=${bWentToLobby}, "they left"=${bSawThemLeave}`);

  // And A has to come back by itself, or "ship without dropping" is a call that
  // is up on one side only.
  const aBack = await a.evaluate(() => window.__tape?.pc?.connectionState ?? null)
    .catch(() => null);
  arm('A returns to the call after reloading', aBack === 'connected' || aBack === 'connecting',
    `A pc=${aBack}`);
} finally {
  await A.close().catch(() => {});
  await B.close().catch(() => {});
}
console.log(fails === 0 ? '\nVERDICT: PASS' : `\nVERDICT: FAIL (${fails})`);
process.exit(fails === 0 ? 0 : 1);
