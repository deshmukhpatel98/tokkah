/**
 * Join a real room as the second occupant and report BOTH sides live.
 *
 * WHY: every audio measurement on this project so far has come from Chrome's
 * fake capture device, which reports `sampleRate 44100` while our AudioContext
 * runs at 48000 — so every sample passes through a 44.1 -> 48 resample done in
 * float. That resample is very likely why the int24 low bits are never zero
 * (`wastedShift 0`) and why the wasted-bits codec field, which halves the audio
 * lane offline, never fires on the rig. A real microphone that natively runs at
 * 48 kHz would have no resample at all.
 *
 * The rig cannot answer that. A real device can, and this reads it: the far
 * side's own telemetry, fetched from the room's log with the token the welcome
 * message hands every occupant.
 *
 *   node testbed/livecall.mjs --room=<code> [--sec=60]
 *
 * Prints, every 5 s:
 *   MY SIDE    what this fake-device browser sees (control)
 *   FAR SIDE   the real device's capture settings and wasted-bits telemetry
 */
import { chromium } from '/Users/deveshpatel/Downloads/video calling/testbed/node_modules/playwright-core/index.mjs';

const CHROME = process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const FIX = '/Users/deveshpatel/Downloads/video calling/testbed/media/timecode720.y4m';
const AUD = '/Users/deveshpatel/Downloads/video calling/testbed/media/conv/A.wav';

const arg = (k, d) => {
  const m = process.argv.find((a) => a.startsWith(`--${k}=`));
  return m ? m.slice(k.length + 3) : d;
};
const ROOM = arg('room');
const SEC = Number(arg('sec', 60));
if (!ROOM) { console.error('need --room=<code>'); process.exit(2); }

const c = await chromium.launchPersistentContext('', {
  executablePath: CHROME, headless: true,
  args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
    `--use-file-for-fake-video-capture=${FIX}`, `--use-file-for-fake-audio-capture=${AUD}`,
    '--autoplay-policy=no-user-gesture-required'],
  viewport: { width: 1280, height: 800 },
});
const p = await c.newPage();

// The welcome frame carries logToken. Capturing it here rather than reaching into
// app internals keeps this working across client refactors.
let token = null;
// My own session id, lifted from my telemetry POST body. Needed because the room
// log holds BOTH occupants and "the far side" has to be identified, not assumed:
// role a/b depends on join order, and reading my own numbers back as if they were
// the real device's is exactly the self-view mistake this repo has made before.
let mySession = null;
p.on('request', (req) => {
  if (mySession || !req.url().includes('/log') || req.method() !== 'POST') return;
  try {
    const b = JSON.parse(req.postData() ?? '{}');
    mySession = b.session ?? b.sessionId ?? (Array.isArray(b.events) ? b.events[0]?.session : null);
  } catch { /* not JSON */ }
});
p.on('websocket', (ws) => {
  ws.on('framereceived', (f) => {
    if (token) return;
    try {
      const m = JSON.parse(typeof f.payload === 'string' ? f.payload : f.payload.toString());
      if (m.logToken) token = m.logToken;
    } catch { /* binary media frames are not JSON; ignore */ }
  });
});

const url = `https://room.tokkah.com/?r=${encodeURIComponent(ROOM)}&rejoin=1`;
console.log(`joining ${url}`);
await p.goto(url, { waitUntil: 'domcontentloaded' });

const t0 = Date.now();
let sawPeer = false;
while (Date.now() - t0 < SEC * 1000) {
  await new Promise((r) => setTimeout(r, 5000));
  const mine = await p.evaluate(() => {
    const s = window.__tape?.pcm ?? null;
    const v = window.__tape?.video ?? null;
    const vids = [...document.querySelectorAll('video, canvas')]
      .map((e) => ({ id: e.id || e.className, w: e.videoWidth || e.width, h: e.videoHeight || e.height }))
      .filter((v) => v.w);
    return { s, v, vids };
  }).catch(() => null);

  let far = null;
  if (token) {
    // Both occupants POST into the same room log, so the far side's own
    // pcm-stats and capture entries are readable here. This is the only path to
    // a REAL device's capture settings from this process.
    try {
      // NDJSON, one event per line — not a JSON array.
      const txt = await (await fetch(
        `https://room.tokkah.com/api/room/${encodeURIComponent(ROOM)}/log?token=${token}`)).text();
      const rows = txt.split('\n').filter(Boolean).map((l) => JSON.parse(l));
      // "Not my current session" is NOT enough: every restart of this script and
      // every page reload mints a new session, and this room's log already holds
      // nine. My OWN earlier sessions would otherwise be read back as the far
      // side — the same self-view error competitor.mjs was built to avoid.
      // The fake capture device is identifiable: it reports 44100 Hz, while a real
      // device here reports 48000. So exclude every session that ever announced a
      // 44100 capture, plus my current one.
      const fake = new Set(rows
        .filter((e) => e.kind === 'capture' && e.data?.audio?.sampleRate === 44100)
        .map((e) => e.session));
      const others = rows.filter((e) => e.session && e.session !== mySession && !fake.has(e.session));
      const last = (k) => [...others].reverse().find((e) => e.kind === k)?.data ?? null;
      far = {
        rows: rows.length, mine: rows.length - others.length, theirs: others.length,
        sessions: [...new Set(rows.map((e) => e.session))].length,
        cap: last('capture'), pcm: last('pcm-stats'),
      };
    } catch (e) { far = { err: String(e.message).slice(0, 60) }; }
  }

  const el = ((Date.now() - t0) / 1000).toFixed(0);
  if (far?.cap?.audio) sawPeer = true;
  console.log(`\n[t+${el}s] token ${token ? 'yes' : 'no'}  logRows ${far?.rows ?? '-'}` +
    `  sessions ${far?.sessions ?? '-'}  farRows ${far?.theirs ?? '-'}`);
  if (mine?.vids?.length) console.log(`  MY SIDE   elements: ${mine.vids.map((v) => `${v.id} ${v.w}x${v.h}`).join(' | ')}`);
  if (mine?.s) {
    const q = mine.s;
    // `q.concealPct ?? '-'` printed a dash for a WHOLE 400 s run: the snapshot has
    // never had that field (it exposes playedFrames/lostFrames/concealedMs), so the
    // rig asked for a name that never existed and reported "no data" instead of
    // failing. Concealment is the metric this project quotes most often. Same class
    // of bug as `--secs=` never matching `--sec=`: a missing key must be fatal, not
    // defaulted, or the run looks complete while the headline number is absent.
    const req = (k) => {
      if (q[k] === undefined) throw new Error(`pcm snapshot has no field "${k}" — the rig is reading a name that does not exist`);
      return q[k];
    };
    const played = req('playedFrames'), lost = req('lostFrames');
    const conceal = played + lost > 0 ? ((100 * lost) / (played + lost)).toFixed(2) : 'n/a';
    console.log(`  MY SIDE   inbound conceal ${conceal}%  (played ${played} lost ${lost} concealedMs ${req('concealedMs')})` +
      `  framesRecv ${req('framesRecv')}  late ${req('late')}  dup ${req('dup')}  fecRepaired ${req('fecRepaired')}`);
    // The jitter estimator's own internals. depthMs climbing on a real network is
    // either justified by real arrival spread, or it is the peak-hold refusing to
    // release: 1 ms/s was tuned on an emulated link and takes 100 s to give back
    // 100 ms. jitHoldMaxRun >> jitSpreadMaxRun would mean the hold is the cause.
    console.log(`  MY SIDE   depthMs ${q.depthMs}  target ${q.targetFrames}f  spreadMaxRun ${q.jitSpreadMaxRun}  holdMaxRun ${q.jitHoldMaxRun}` +
      `  wantMaxRun ${q.jitWantMaxRun}  clampedTicks ${q.jitClampedTicks}  aboveFloor ${q.jitAboveFloorMs}ms`);
    // THE ANSWER: read off the peer's audio as it arrives here, so it does not
    // depend on the peer's client being current.
    console.log(`  PEER CHAIN (from received audio)  rxWastedShift ${q.rxWastedShift}  rxShift8 ${q.rxShift8Pct}%  rxFit32767 ${q.rxFit32767Pct}%  frames ${q.rxProbeFrames ?? '-'}`);
  }
  if (far?.cap) console.log(`  FAR SIDE  capture: ${JSON.stringify(far.cap.audio ?? far.cap)}`);
  if (far?.pcm) {
    const q = far.pcm;
    console.log(`  FAR SIDE  wastedShift ${q.wastedShift}  shift8 ${q.shift8Pct}%  fit32767 ${q.fit32767Pct}%  fit32768 ${q.fit32768Pct}%`);
    // Here a missing field is genuinely possible — this arrives from the PEER's
    // telemetry and their tab may be on an older bundle (it was: wastedShift came
    // back undefined all run). So say WHICH state it is rather than printing a dash
    // that reads identically to "measured zero".
    const fc = q.playedFrames === undefined || q.lostFrames === undefined
      ? 'ABSENT (peer on older bundle?)'
      : q.playedFrames + q.lostFrames > 0
        ? `${((100 * q.lostFrames) / (q.playedFrames + q.lostFrames)).toFixed(2)}%`
        : 'n/a (no frames)';
    console.log(`  FAR SIDE  bPerFrame ${q.bPerFrame}  mbpsSent ${q.mbpsSent}  conceal ${fc}  depthMs ${q.depthMs}`);
  }
  if (far?.err) console.log(`  FAR SIDE  log read failed: ${far.err}`);
}
await c.close();
console.log(sawPeer
  ? '\nFar-side capture settings were read. sampleRate 48000 with sampleSize 16 and\nwastedShift 8 would mean a real device IS bit-transparent and the lane halves.'
  : '\nNo far-side telemetry seen — nobody else was in the room, or the log token\nnever arrived. Nothing is concluded from an empty run.');
