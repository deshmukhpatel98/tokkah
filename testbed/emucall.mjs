/**
 * emucall.mjs — a real prod call between ANDROID CHROME (emulator) and desktop
 * Chromium, with every pipeline stage read from the Android side.
 *
 * This is the emulator lane's foundation stone: if this passes, the whole
 * live-call assertion set can be pointed at Android Chrome from this Mac with
 * no cable. What it can prove: Android Chrome's WebCodecs/datachannel/audio
 * pipeline carries a call to the same numbers desktop does. What it CANNOT
 * prove: anything about a real camera sensor — the emulator's camera is a
 * rendered scene (that is why the low-light/exposure suite stays on real
 * silicon over the lab channel).
 *
 * Run ./testbed/emu-boot.sh first (CDP on 127.0.0.1:9223).
 *
 *   node testbed/emucall.mjs
 */
import { chromium } from 'playwright-core';

const BASE = process.env.URL ?? 'https://room.tokkah.com';
const CDP = process.env.EMU_CDP ?? 'http://127.0.0.1:9223';
const CHROME = process.env.TESTBED_CHROME
  ?? `${process.env.HOME}/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);
const ROOM = `emu-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 5)}`;

let fails = 0;
const check = (name, ok, detail) => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  (${detail})`);
  if (!ok) fails++;
};

// ── the Android end, over CDP ────────────────────────────────────────────────
const android = await chromium.connectOverCDP(CDP);
const actx = android.contexts()[0];
if (!actx) throw new Error('no context on the emulator Chrome — did emu-boot.sh run?');
await actx.grantPermissions(['camera', 'microphone'], { origin: BASE }).catch(() => {});
for (const p of actx.pages()) {
  if (!p.isClosed() && p.url().startsWith(BASE)) await p.close().catch(() => {});
}
const a = await actx.newPage();

// ── the desktop end, local Chromium with real talking-head media ─────────────
const D = await chromium.launch({
  executablePath: CHROME, headless: true,
  args: [
    '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    `--use-file-for-fake-video-capture=${media('realB.mjpeg')}`,
    `--use-file-for-fake-audio-capture=${media('realB.wav')}`,
    '--autoplay-policy=no-user-gesture-required',
    '--disable-features=WebRtcHideLocalIpsWithMdns',
  ],
});

try {
  const d = await D.newPage();
  for (const [p, who] of [[a, 'android'], [d, 'desktop']]) {
    await p.goto(`${BASE}/?r=${ROOM}&rig=1`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await p.waitForSelector('#join', { timeout: 30000 });
    // The M13 lesson, and it holds on the emulator too: joining before the
    // lobby badge says 'camera ready' puts the app in audio-only for the whole
    // call, and every video number reads null — indistinguishable from a
    // broken video lane unless this gate exists.
    const camOk = await p
      .waitForFunction(() => /ready/.test(document.getElementById('previewBadge')?.textContent ?? ''), null, { timeout: 25000 })
      .then(() => true).catch(() => false);
    if (!camOk) console.log(`  [warn] ${who}: lobby never said 'camera ready' — joining anyway`);
    await p.click('#join').catch(() => {});
    if (who === 'android') await p.waitForTimeout(2000);
  }
  let connected = true;
  for (const [p, who] of [[a, 'android'], [d, 'desktop']]) {
    const ok = await p
      .waitForFunction(() => window.__tape?.pc?.connectionState === 'connected', null, { timeout: 90000 })
      .then(() => true).catch(() => false);
    if (!ok) { connected = false; console.log(`  ${who} never reached connected`); }
  }
  check('Android Chrome and desktop connect on prod', connected, `room ${ROOM}`);
  if (connected) {
    await a.waitForTimeout(20000); // settle

    const read = (p) => p.evaluate(() => {
      const v = window.__tape?.video ?? {};
      const q = window.__tape?.pcm ?? {};
      return {
        fps: v.achievedFps ?? null, mbps: v.mbpsAtFps ?? null, qp: v.qp ?? null,
        g2g: v.glassToGlassMs ?? null,
        m2e: q.mouthToEarMs ?? null, conceal: q.lostFrames ?? null,
        recv: q.framesRecv ?? null, mode: window.__tape?.pcmMode?.running ?? null,
        ua: navigator.userAgent.includes('Android') ? 'android' : 'desktop',
      };
    });
    const ra = await read(a), rd = await read(d);
    for (const [who, r] of [['android', ra], ['desktop', rd]]) {
      console.log(`  ${who.padEnd(8)} ua=${r.ua} fps=${r.fps} ${r.mbps}Mbps qp=${r.qp} g2g=${r.g2g}ms ` +
        `m2e=${r.m2e}ms conceal=${r.conceal} pcm=${r.mode}`);
    }
    check('the Android side runs the real client (UA + PCM lane)', ra.ua === 'android' && ra.mode === true,
      `ua=${ra.ua}, pcm running=${ra.mode}`);
    const tm = await Promise.all([a, d].map((p) => p.evaluate(() => window.__tape?.tapeMode ?? null)));
    // TWO ARMS, decided by what the Android engine actually supports. Old
    // Android Chrome (no RTCRtpScriptTransform — e.g. the emulator image's
    // preinstalled 124) must take the plain-RTP FALLBACK and still carry
    // video; that path is exactly what un-updated real phones get, so it is
    // asserted, not excused. Modern engines must run the lossless lane.
    const modern = await a.evaluate(() => 'RTCRtpScriptTransform' in window);
    if (modern) {
      check('the LOSSLESS lane runs on both sides (no fallback)',
        tm.every((t) => t?.running === true && !t.fellBack),
        `android=${JSON.stringify(tm[0])} desktop=${JSON.stringify(tm[1])}`);
      check('video flows Android -> desktop at full rate', (rd.fps ?? 0) >= 10, `desktop receives ${rd.fps} fps`);
      // The emulator DECODES + paints in software through QEMU; measured ~5 fps
      // receive there while encoding 30 fps out. The full-rate receive bar
      // belongs to real silicon (phone-test.sh / the lab) — here the assertion
      // is that the direction WORKS, and the number is printed for drift.
      check('video flows desktop -> Android (emulator decode is host-bound)', (ra.fps ?? 0) >= 2,
        `android receives ${ra.fps} fps`);
    } else {
      const rtp = await Promise.all([a, d].map((p) => p.evaluate(() => new Promise((res) => {
        const vids = [...document.querySelectorAll('video')].filter((v) => v.srcObject && v.videoWidth > 0);
        const v = vids.at(-1);
        if (!v) return res({ w: 0, moving: false });
        const t0 = v.currentTime;
        setTimeout(() => res({ w: v.videoWidth, moving: v.currentTime > t0 }), 3000);
      }))));
      check('old-Android arm: the app falls back rather than breaking',
        tm[0] && tm[0].running === false,
        `android tapeMode=${JSON.stringify(tm[0])} (no RTCRtpScriptTransform on this Chrome)`);
      check('old-Android arm: plain-RTP video still flows BOTH ways',
        rtp.every((r) => r.w > 0 && r.moving),
        `android sees ${rtp[0].w}px moving=${rtp[0].moving}, desktop sees ${rtp[1].w}px moving=${rtp[1].moving}`);
    }
    if (modern) {
      // The emulator's audio stack (QEMU + virtual devices) adds ~400 ms of
      // reported output latency that no real phone carries — so the m2e bar
      // here is 800, and the REAL quality signal is concealment staying near
      // zero. Real-silicon m2e keeps its own bar in the phone/lab suites.
      check('audio is live both ways, near-zero concealment',
        (ra.recv ?? 0) > 1000 && (rd.recv ?? 0) > 1000
        && ra.m2e != null && ra.m2e < 800 && rd.m2e != null && rd.m2e < 300
        && (ra.conceal ?? 9e9) < 100,
        `android m2e=${ra.m2e}ms conceal=${ra.conceal}, desktop m2e=${rd.m2e}ms, recv=${ra.recv}/${rd.recv}`);
    } else {
      // The old-arm guest's clock JUMPS under QEMU (measured: desktop m2e
      // −324 to −16797 ms — an impossible number that is the clock, not the
      // pipe; task #47 makes the instrument refuse it). What the emulator can
      // honestly assert here is LIVENESS and bounded concealment; latency is
      // printed above as info only.
      const cRate = (r) => (r.recv ? (r.conceal ?? 0) / r.recv : 1);
      check('old-Android arm: audio live both ways, concealment bounded',
        (ra.recv ?? 0) > 1000 && (rd.recv ?? 0) > 1000 && cRate(ra) < 0.3 && cRate(rd) < 0.3,
        `recv=${ra.recv}/${rd.recv}, conceal ${(100 * cRate(ra)).toFixed(1)}%/${(100 * cRate(rd)).toFixed(1)}% (guest-clock m2e untrustworthy here)`);
    }
    // Not a hard gate — the emulator adds its own latency — but the number
    // must be PRINTED so drift across sessions is visible.
    console.log(`  [info] android glass-to-glass ${ra.g2g}ms, mouth-to-ear ${ra.m2e}ms (emulator overhead included)`);
  }
} finally {
  await a.close().catch(() => {});
  await D.close().catch(() => {});
  // never android.close() — that would kill the user-visible emulator Chrome
}
console.log(fails === 0 ? '\nVERDICT: PASS' : `\nVERDICT: FAIL (${fails})`);
process.exit(fails ? 1 : 0);
