#!/usr/bin/env node
/**
 * labhold.mjs — park two fake-camera peers in the lab room and hold the call.
 *
 * The lab channel is only useful if something is in the room to answer. This
 * puts a call there and keeps it there, so lab drivers (lab.mjs, pfreal.mjs)
 * can be exercised end to end without waiting for a human with a phone. It
 * proves the PLUMBING; it proves nothing about a sensor, which is the whole
 * point of the real-sensor lane and is why this file says so out loud.
 *
 *   node testbed/labhold.mjs [--room=lab] [--minutes=10]
 */
import { chromium } from 'playwright-core';

const BASE = process.env.URL ?? 'https://room.tokkah.com';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
const arg = (k, d) => { const m = process.argv.find((a) => a.startsWith(`--${k}=`)); return m ? m.slice(k.length + 3) : d; };
const ROOM = arg('room', 'lab');
const MINUTES = Number(arg('minutes', 10));

const launch = (side) => chromium.launch({
  executablePath: CHROME, headless: true,
  args: [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    `--use-file-for-fake-video-capture=${media(`real${side}.mjpeg`)}`,
    `--use-file-for-fake-audio-capture=${media(`real${side}.wav`)}`,
    '--autoplay-policy=no-user-gesture-required',
    '--disable-features=WebRtcHideLocalIpsWithMdns', '--use-gl=angle', '--enable-gpu',
  ],
});

const A = await launch('A'), B = await launch('B');
try {
  const a = await A.newPage(), b = await B.newPage();
  const url = `${BASE}/?r=${ROOM}&pfilter=1&rcres=0&qp=24&l2rcqpmin=24&l2rcqpmax=24`;
  for (const [p, who] of [[a, 'A'], [b, 'B']]) {
    await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await p.waitForSelector('#join', { timeout: 20000 });
    await p.click('#join').catch(() => {});
    if (who === 'A') await p.waitForTimeout(1200);
  }
  for (const p of [a, b]) {
    await p.waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 60000 });
  }
  console.log(`two peers connected in room "${ROOM}" — holding ${MINUTES} min`);
  console.log(`(fake cameras: this validates the lab path, NOT a sensor)`);
  await a.waitForTimeout(MINUTES * 60 * 1000);
} finally {
  await A.close(); await B.close();
}
