// The NEAR end of a cross-planet call: a real browser on this laptop in Delhi,
// joining the same production room the container peer joins from Seattle.
//
// This is the half that makes the measurement a measurement. The far end runs
// in a Cloudflare container (testbed/peer); both ends drive the real join UI on
// room.tokkah.com, and both carry REAL talking-head media -- side A here
// against side B there, so the call has two different speakers on it the way an
// actual conversation does.
import { chromium } from 'playwright-core';

const ROOM = process.env.ROOM, HOLD = Number(process.env.HOLD_S || 75);
const QS = process.env.EXTRA_QS || '';
const CHROME = process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const media = (f) => decodeURIComponent(new URL(`./media/real/${f}`, import.meta.url).pathname);

const b = await chromium.launch({ executablePath: CHROME, args: [
  '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
  // A REAL talking head and REAL speech, not Chromium's rolling pattern and
  // beep -- those compress to almost nothing, so a call carrying them measures
  // an empty pipe and reports it as a video call. Same flags and same files the
  // rest of the suite uses, so this number is comparable to every other number
  // the project owns.
  `--use-file-for-fake-video-capture=${media('realA.mjpeg')}`,
  `--use-file-for-fake-audio-capture=${media('realA.wav')}`,
  '--autoplay-policy=no-user-gesture-required',
  '--disable-features=WebRtcHideLocalIpsWithMdns',
] });

const p = await b.newPage();
await p.goto(`https://room.tokkah.com/${ROOM}?hb=1${QS ? '&' + QS : ''}`,
  { waitUntil: 'domcontentloaded', timeout: 60000 });
await p.click('#join', { timeout: 30000 }).catch(() => {});
await p.waitForTimeout(HOLD * 1000);

// Read the page EXACTLY the way call.mjs does: window.__tape.pcm and
// window.__tape.video are plain properties, not snapshot() calls. Reading them
// any other way is how the first cross-planet runs reported nulls and left the
// question of whether audio survives 305 ms completely unanswered.
const snap = await p.evaluate(() => {
  const t = window.__tape;
  if (!t) return { noTape: true };
  const s = t.pcm, v = t.video;
  return {
    tapeMode: t.tapeMode ?? null,
    // The lossless audio lane. Concealment is the number that matters most:
    // it is the audio the listener did NOT get, and the whole design is built
    // on never producing any.
    mouthToEarMs: s?.mouthToEarMs ?? null, concealedMs: s?.concealedMs ?? null,
    depthMs: s?.depthMs ?? null, targetFrames: s?.targetFrames ?? null,
    framesRecv: s?.framesRecv ?? null, lostFrames: s?.lostFrames ?? null,
    lateFrames: s?.lateFrames ?? null, fecRepaired: s?.fecRepaired ?? null,
    agePcmP50: s?.ageP50 ?? null, agePcmP95: s?.ageP95 ?? null,
    driftPpm: s?.driftPpm ?? null,
    assocRtt: (s?.perAssoc ?? []).map((a) => a.rttMs),
    // The video lane, same shape the rig prints.
    glassToGlassMs: v?.glassToGlassMs ?? null, fullAgeP50: v?.fullAgeP50 ?? null,
    presentLagP50: v?.presentLagP50 ?? null, ipiP50: v?.ipiP50 ?? null,
    framesOut: v?.framesOut ?? null, framesLost: v?.framesLost ?? null,
    mbpsAtFps: v?.mbpsAtFps ?? null,
  };
});

// WHICH ROUTE CARRIED IT. On a long path this is the difference between a
// direct peer-to-peer hop and a relay through Cloudflare, and the two have
// different physics -- reporting latency without it says nothing about why.
const ice = await p.evaluate(async () => {
  // window.__tape.pc -- NOT window.__tapePc, which does not exist and quietly
  // returned null on every run, making a call that never connected
  // indistinguishable from one that connected and measured nothing.
  const pc = window.__tape?.pc ?? null;
  if (!pc || !pc.getStats) return { pc: false };
  const st = await pc.getStats(); let pair = null, inb = null;
  st.forEach((r) => {
    if (r.type === 'candidate-pair' && r.state === 'succeeded' && (r.nominated || !pair)) pair = r;
    if (r.type === 'inbound-rtp' && r.kind === 'audio') inb = r;
  });
  // Connection state travels WITH the numbers. Latency from a call that never
  // connected is not a small number, it is not a number at all.
  const out = { conn: pc.connectionState, iceState: pc.iceConnectionState,
                pktsRecv: inb?.packetsReceived ?? null, jitter: inb?.jitter ?? null };
  if (!pair) return out;
  const L = st.get(pair.localCandidateId), R = st.get(pair.remoteCandidateId);
  return { ...out, local: L?.candidateType, remote: R?.candidateType, proto: L?.protocol,
           rttMs: pair.currentRoundTripTime != null ? Math.round(pair.currentRoundTripTime * 1000) : null };
}).catch((e) => ({ err: String(e).slice(0, 120) }));

console.log('LOCAL(Delhi):', JSON.stringify({ ...snap, ice }));
await b.close();
