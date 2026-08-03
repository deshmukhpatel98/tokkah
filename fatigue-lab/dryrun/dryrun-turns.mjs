/**
 * Dry-run of the fatigue-lab turn-taking gate (/turns), no humans.
 *
 * Two headless Chromes, real WebRTC between them, each with a WAV file as its
 * microphone (testbed/media/conv). The fixture is a scripted conversation with
 * ground truth to the sample: every A turn ends exactly 620 ms before the B
 * reply begins (turnGapMs), and B's breath-opened replies carry known leads.
 *
 * What this validates:
 *   1. The page loads, joins, detectors attach, RTT polls.
 *   2. Scored rows land near the fixture's truth (~620 ms evidence / ~878 ms
 *      voice for breath-opened replies, plus real transit) — and NOT ~315 ms
 *      lower, which is what delivery-time stamping of t0 would produce.
 *   3. The verdict path reaches PASS on a synthetic Boland-shaped run.
 */

import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';

const require = createRequire('/Users/earningsgpt/video calling/testbed/package.json');
const { chromium } = require('playwright-core');

const CHROME =
  '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1228/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const BASE = 'http://127.0.0.1:8793';
const ROOM = `dry-${Date.now().toString(36)}`;
const MEDIA = '/Users/earningsgpt/video calling/testbed/media/conv';

async function launch(side, wav) {
  const browser = await chromium.launch({
    executablePath: CHROME,
    headless: true,
    args: [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      `--use-file-for-fake-audio-capture=${wav}`,
      '--autoplay-policy=no-user-gesture-required',
      '--alsa-output-device=null',
      '--disable-features=WebRtcHideLocalIpsWithMdns',
      `--unsafely-treat-insecure-origin-as-secure=${BASE}`,
      '--allow-running-insecure-content',
    ],
  });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + String(e.message).slice(0, 300)));
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push(m.text().slice(0, 200));
  });
  await page.goto(`${BASE}/turns`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#join', { timeout: 20000 });
  await page.fill('#room', ROOM);
  await page.fill('#runlabel', 'dry');
  return { side, browser, page, errors };
}

const A = await launch('A', `${MEDIA}/A.wav`);
await A.page.click('#join');
await new Promise((r) => setTimeout(r, 600)); // A must be role 'a' (asks first)
const B = await launch('B', `${MEDIA}/B.wav`);
await B.page.click('#join');

// Wait for scored rows on A (the asker). First reply lands ~26 s in (22 s lead-in
// + first question); allow 90 s total to collect several.
let rows = [];
const deadline = Date.now() + 95000;
while (Date.now() < deadline) {
  rows = await A.page.evaluate(() => window.__turns?.state.rows ?? []);
  if (rows.length >= 5) break;
  await new Promise((r) => setTimeout(r, 2000));
}
// Let the in-flight turn finish scoring, then take the final state.
await new Promise((r) => setTimeout(r, 4000));
rows = await A.page.evaluate(() => window.__turns.state.rows);
const meta = await A.page.evaluate(() => ({
  rttMs: window.__turns.state.rttMs,
  peerRaw: window.__turns.state.peerRaw,
  raw: window.__turns.state.raw,
  verdict: document.getElementById('verdict').textContent,
  log: document.getElementById('log').textContent.slice(0, 1200),
}));

const bMode = await B.page.evaluate(() => ({
  peerRaw: window.__turns.state.peerRaw,
  status: document.getElementById('peermode').textContent,
}));

console.log('=== real-media run ===');
console.log('A rttMs:', meta.rttMs?.toFixed(1), ' A mode:', meta.raw, ' A sees peer:', meta.peerRaw, ' B sees peer:', bMode.peerRaw, `(${bMode.status})`);
for (const r of rows) {
  console.log(
    `row ${r.n}: ttfe=${r.ttfe.toFixed(0)} voice=${r.voice.toFixed(0)} credit=${r.credit.toFixed(0)} kind=${r.kind} human=${r.human?.toFixed(0)}`,
  );
}

// Ground truth: every B reply starts exactly 620 ms (fixture turnGap) after the
// A turn ends; breath-opened replies speak ~200-260 ms after the breath.
// Real transit (network + jitter buffer) legitimately sits on top of 620.
const ttfeOk = rows.length > 0 && rows.every((r) => r.ttfe > 500 && r.ttfe < 900);
const noBrokenBias = rows.length > 0 && rows.every((r) => r.ttfe > 500); // delivery-stamped t0 would read ~300
console.log(`rows: ${rows.length}  ttfe-in-[500,900]: ${ttfeOk}  no ~315ms delivery bias: ${noBrokenBias}`);

console.log('\n=== synthetic verdict drive (Boland-shaped: 300 ms human, 200 ms lead, 40 ms rtt) ===');
const verdict = await A.page.evaluate(async () => {
  const T = window.__turns;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  T.state.rttMs = 40;
  T.state.rows = [];
  for (let i = 0; i < 8; i++) {
    const T0 = 2000 + i * 10; // seconds, arbitrary monotonic ctx-time base
    T.state.phase = 'asking';
    T.onLocal({ type: 'end', ctxTime: T0 });
    // breath onset at T0+140 ms, delivered (classified) 35 ms later
    T.onRemote({
      type: 'classified',
      kind: 'breath',
      ctxTime: T0 + 0.175,
      at: (T0 + 0.175) * 48000,
      onsetAt: (T0 + 0.14) * 48000,
    });
    T.onRemote({ type: 'voiced', ctxTime: T0 + 0.34 });
    await sleep(30);
  }
  return {
    rows: T.state.rows.map((r) => ({
      ttfe: +r.ttfe.toFixed(1),
      voice: +r.voice.toFixed(1),
      credit: +r.credit.toFixed(1),
      human: +r.human.toFixed(1),
      kind: r.kind,
    })),
    verdict: document.getElementById('verdict').textContent,
  };
});
console.log(JSON.stringify(verdict.rows, null, 1));
console.log('verdict:', verdict.verdict.split('\n')[0]);

console.log('\npage errors A:', A.errors.length ? A.errors : 'none');
console.log('page errors B:', B.errors.length ? B.errors : 'none');
console.log('\nA log tail:\n' + meta.log);

await A.browser.close();
await B.browser.close();
