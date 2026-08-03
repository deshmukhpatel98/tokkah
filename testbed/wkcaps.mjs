/**
 * Exactly which of lane 2's five required APIs does WebKit lack?
 *
 * Lane 2 reaches VMAF 99.7; the plain-RTP fallback every Safari-family call takes was
 * measured at 77.6. So the whole visually-lossless story for Safari users turns on this
 * one gate, and it is worth knowing whether it fails on something with a workaround or
 * something fundamental.
 *
 * BOUND: Playwright's WebKit is not Safari. It is the same engine, built without some
 * Apple-internal pieces, so a MISSING api here is suggestive and a PRESENT one is
 * strong. Confirm anything load-bearing on real Safari before shipping.
 */
import { webkit } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';
const wb = await webkit.launch();
const ctx = await wb.newContext({ permissions: ['camera', 'microphone'], ignoreHTTPSErrors: true });
const p = await ctx.newPage();
await ctx.route('https://caps.test/**', (r) => r.fulfill({ contentType: 'text/html', body: '<html><body></body></html>' }));
await p.goto('https://caps.test/');
const r = await p.evaluate(async () => {
  const has = (n) => typeof window[n] !== 'undefined';
  const out = {
    ua: navigator.userAgent,
    gate: {
      VideoEncoder: has('VideoEncoder'),
      VideoDecoder: has('VideoDecoder'),
      MediaStreamTrackProcessor: has('MediaStreamTrackProcessor'),
      MediaStreamTrackGenerator: has('MediaStreamTrackGenerator'),
      RTCRtpScriptTransform: 'RTCRtpScriptTransform' in window,
    },
    // The workaround candidates, if the breakout box is what is missing.
    alt: {
      VideoFrame: has('VideoFrame'),
      requestVideoFrameCallback: 'requestVideoFrameCallback' in HTMLVideoElement.prototype,
      canvasCaptureStream: 'captureStream' in HTMLCanvasElement.prototype,
      OffscreenCanvas: has('OffscreenCanvas'),
      VideoTrackGenerator: has('VideoTrackGenerator'), // the renamed spec successor to MSTG
    },
  };
  // Can a VideoFrame actually be built from a <video> element carrying a camera track?
  // That is the substitute for MediaStreamTrackProcessor, so test it for real.
  try {
    const st = await navigator.mediaDevices.getUserMedia({ video: { width: { ideal: 1280 } }, audio: false });
    const v = document.createElement('video');
    v.srcObject = st; v.muted = true; v.autoplay = true; v.playsInline = true;
    document.body.appendChild(v);
    await v.play().catch(() => {});
    await new Promise((res) => v.requestVideoFrameCallback ? v.requestVideoFrameCallback(res) : setTimeout(res, 300));
    const f = new VideoFrame(v, { timestamp: 0 });
    out.videoFrameFromVideo = { ok: true, w: f.displayWidth, h: f.displayHeight, format: f.format };
    // And can our fixed-QP encoder consume it?
    const cfgs = [];
    for (const codec of ['avc1.640028', 'avc1.42E01E', 'vp8', 'vp09.00.10.08']) {
      try {
        const s = await VideoEncoder.isConfigSupported({ codec, width: 1920, height: 1080, framerate: 30, latencyMode: 'realtime' });
        cfgs.push({ codec, supported: !!s.supported });
      } catch (e) { cfgs.push({ codec, err: String(e.name) }); }
    }
    out.encoderCodecs = cfgs;
    f.close();
    st.getTracks().forEach((t) => t.stop());
  } catch (e) { out.videoFrameFromVideo = { ok: false, err: `${e.name}: ${e.message}` }; }
  return out;
});
console.log(`\nUA: ${r.ua}\n`);
console.log(`LANE 2 GATE — all five must be true:`);
for (const [k, v] of Object.entries(r.gate)) console.log(`  ${v ? 'YES' : 'NO '}  ${k}`);
console.log(`\nWORKAROUND CANDIDATES:`);
for (const [k, v] of Object.entries(r.alt)) console.log(`  ${v ? 'YES' : 'NO '}  ${k}`);
console.log(`\nVideoFrame from a <video> carrying the camera: ${JSON.stringify(r.videoFrameFromVideo)}`);
console.log(`Encoder configs: ${JSON.stringify(r.encoderCodecs)}`);
await wb.close();
