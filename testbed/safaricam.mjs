/**
 * safaricam.mjs — can REAL Safari reach the REAL camera on this Mac?
 *
 * The one question standing between this project and the real-sensor law, asked
 * on its own rather than inside a 90-second call. Both other routes are closed
 * and measured: Chrome for Testing never gets an answer (camprobe: HUNG at 45 s,
 * with 1 video input present, so the sensor exists and is unreachable), and the
 * in-app browser refuses by policy (NotAllowedError). Safari is the last one,
 * and it is the only browser here that a human has ever granted anything to.
 *
 * Every step writes to the log FILE synchronously. The full call rig hung three
 * times with zero output, and all three times the reason was that Node
 * block-buffers stdout through a pipe — the run was probably telling me exactly
 * where it stopped and none of it reached disk. A probe whose diagnosis dies
 * with it is not a probe.
 *
 *   node testbed/safaricam.mjs [--url=https://room.tokkah.com]
 */
import { spawn } from 'node:child_process';
import { appendFileSync, writeFileSync } from 'node:fs';

const LOG = '/private/tmp/claude-501/-Users-deveshpatel-Downloads-video-calling/e4d4da4b-64e3-42ee-a711-20694932240a/scratchpad/safaricam.log';
writeFileSync(LOG, '');
const say = (s) => { appendFileSync(LOG, s + '\n'); console.log(s); };

const URL_ = (process.argv.find((a) => a.startsWith('--url=')) ?? '--url=https://room.tokkah.com').slice(6);
const PORT = 4749;
const base = `http://127.0.0.1:${PORT}`;

// Every network call gets a deadline. The camera prompt is a MODAL SHEET, and a
// modal sheet does not merely delay a WebDriver command, it holds it forever —
// which is exactly the shape of the three hangs that led here.
const wd = async (method, path, body, ms = 20000) => {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), ms);
  try {
    const r = await fetch(base + path, {
      method, signal: ctl.signal,
      headers: { 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const j = await r.json().catch(() => ({}));
    return j.value;
  } finally { clearTimeout(t); }
};

say(`safaricam: starting safaridriver on ${PORT}`);
const driver = spawn('safaridriver', ['-p', String(PORT)], { stdio: 'ignore' });
await new Promise((r) => setTimeout(r, 1500));

let sid = null;
try {
  say('safaricam: creating session');
  const v = await wd('POST', '/session', {
    capabilities: { alwaysMatch: { browserName: 'safari', 'webkit:alwaysAllowAutoplay': true } },
  }, 30000);
  sid = v?.sessionId;
  say(`safaricam: session ${sid ? 'created ' + sid.slice(0, 8) : 'FAILED — is "Allow remote automation" on in Safari > Develop?'}`);
  if (!sid) process.exit(2);

  // NAVIGATE TO A PAGE THAT ASKS FOR NOTHING. Loading the app itself would
  // trigger its lobby preview's getUserMedia during navigation, so the prompt
  // and the page load would block each other and the probe would learn nothing
  // beyond "it hung" — which is what the call rig already told me three times.
  say(`safaricam: navigating to ${URL_}/?nomedia=1`);
  await wd('POST', `/session/${sid}/url`, { url: `${URL_}/?nomedia=1` }, 30000);
  say('safaricam: navigated');

  // Ask what the OS admits exists, before asking for it. Needs no permission.
  const devs = await wd('POST', `/session/${sid}/execute/sync`, {
    script: 'const cb = arguments[arguments.length - 1]; return 0;', args: [],
  }, 10000).catch(() => null);

  say('safaricam: enumerating devices');
  const enumr = await wd('POST', `/session/${sid}/execute/async`, {
    script: `const cb = arguments[arguments.length - 1];
      navigator.mediaDevices.enumerateDevices()
        .then(ds => cb(JSON.stringify({ n: ds.filter(d => d.kind === 'videoinput').length,
                                        labelled: ds.filter(d => d.kind === 'videoinput' && d.label).length })))
        .catch(e => cb(JSON.stringify({ err: String(e) })));`,
    args: [],
  }, 15000).catch((e) => `{"err":"${String(e.message).slice(0, 60)}"}`);
  say(`safaricam: devices ${enumr}`);

  // THE ACTUAL QUESTION. Raced in-page as well as out here, because a granted
  // camera answers in well under a second and an ungranted one may never answer
  // at all. A LABELLED device above already implies a standing grant.
  say('safaricam: calling getUserMedia (20 s deadline)');
  const got = await wd('POST', `/session/${sid}/execute/async`, {
    script: `const cb = arguments[arguments.length - 1];
      let done = false;
      const fin = (o) => { if (!done) { done = true; cb(JSON.stringify(o)); } };
      setTimeout(() => fin({ hung: true }), 12000);
      navigator.mediaDevices.getUserMedia({ video: { width: 1280, height: 720 } }).then(async (st) => {
        const t = st.getVideoTracks()[0];
        const v = document.createElement('video');
        v.srcObject = st; v.muted = true; v.playsInline = true;
        try { await v.play(); } catch (e) {}
        await new Promise(r => setTimeout(r, 1200));   // auto-exposure
        const c = document.createElement('canvas'); c.width = 160; c.height = 90;
        const x = c.getContext('2d');
        const luma = () => { x.drawImage(v, 0, 0, 160, 90);
          const d = x.getImageData(0, 0, 160, 90).data, a = new Float64Array(14400);
          for (let i = 0; i < 14400; i++) a[i] = 0.299*d[i*4] + 0.587*d[i*4+1] + 0.114*d[i*4+2];
          return a; };
        const f0 = luma();
        await new Promise(r => setTimeout(r, 400));
        const f1 = luma();
        let m = 0; for (const q of f0) m += q; m /= 14400;
        let vv = 0; for (const q of f0) vv += (q - m) * (q - m); vv /= 14400;
        let ch = 0; for (let i = 0; i < 14400; i++) ch += Math.abs(f1[i] - f0[i]); ch /= 14400;
        t.stop();
        fin({ label: t.label, w: v.videoWidth, h: v.videoHeight,
              mean: +m.toFixed(1), variance: +vv.toFixed(1), change: +ch.toFixed(3) });
      }).catch(e => fin({ err: e.name + ': ' + e.message }));`,
    args: [],
  }, 20000).catch((e) => JSON.stringify({ err: 'OUTER ' + String(e.message).slice(0, 60) }));
  say(`safaricam: getUserMedia -> ${got}`);

  const r = JSON.parse(got);
  // A SYNTHETIC SOURCE CAN BE BRIGHT AND BUSY. The variance-and-motion test was
  // built to catch a DENIED camera, which macOS serves as uniform black — and it
  // does catch that. It does not catch a source that is fake but lively, and
  // Safari's mock capture device is exactly that: measured variance 4663 and
  // motion 5.175/px, i.e. it sails through a bar a real dim room would struggle
  // with, and the probe printed "REAL SENSOR IN SAFARI" over a test pattern.
  // The label is the only thing that actually distinguishes them, so the label is
  // now checked FIRST and no amount of detail can override it.
  const FAKE = /mock|fake|virtual|synthetic|dummy|obs |camo|test pattern/i;
  const fake = !r.label || FAKE.test(r.label);
  // A denied camera on macOS does not throw: it resolves, reads "live", and
  // every frame is uniformly black. Detail AND life, or it is not a sensor.
  const real = !fake && r.variance > 25 && r.change > 0.2;
  say(real
    ? `\nREAL SENSOR IN SAFARI: "${r.label}" ${r.w}x${r.h}, detail ${r.variance}, motion ${r.change}/px`
    : fake && r.label
      ? `\nNOT A REAL SENSOR — Safari handed over "${r.label}". That is a SYNTHETIC source, and it`
        + ` passes every picture test (variance ${r.variance}, motion ${r.change}/px) because a test`
        + ` pattern is livelier than a real room.\n  Turn it off: Safari > Develop > WebRTC >`
        + ` uncheck "Use Mock Capture Devices", then re-run.`
      : `\nNO REAL SENSOR IN SAFARI — ${r.err ?? (r.hung ? 'getUserMedia never settled (prompt sitting unanswered)'
        : `flat/frozen picture (variance ${r.variance}, change ${r.change})`)}`);
  process.exitCode = real ? 0 : 1;
} finally {
  if (sid) await wd('DELETE', `/session/${sid}`, undefined, 5000).catch(() => {});
  driver.kill();
}
