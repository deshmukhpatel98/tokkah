// Will RTP carry bytes it did not encode?  (task #22, candidate lane 1)
//
// §17.6 left the fixed-QP encoder proven and its transport condemned: SCTP collapses
// to ~Mathis(RTT, p) under random loss, while the RTP path carried 8.85 Mbps through
// the identical 1%. The cheapest possible fix keeps everything about tape.js and swaps
// only the pipe: an RTCRtpScriptTransform between libwebrtc's encoder and the RTP
// packetizer, replacing each encoded frame's payload with our own bytes.
//
// That plan rests on exactly one unknown, so this probe tests exactly one thing:
// does a payload of a *different size* than the encoder produced arrive intact at the
// receiver's transform? Everything else (GCC, NACK, jitter buffer) is stock behaviour
// we have already measured.
//
// Probe design: one page, two loopback RTCPeerConnections, canvas.captureStream as
// the carrier video. The sender transform swaps every frame's data for a seeded PRNG
// pattern whose length steps through sizes from 60 B to 60 KB; the receiver transform
// verifies every byte and never enqueues (a receiver-side drop, so the decoder never
// sees our garbage — the probe is about the pipe, not the decoder).
import { chromium } from 'playwright-core';

const CHROME =
  process.env.CHROME_PATH ||
  process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');

const CODEC = process.argv[2] || 'video/VP8'; // try H264 with: node rtplane.mjs video/H264
// --applike layers on the conditions the real app adds over this minimal probe:
// an audio transceiver, bundlePolicy max-bundle, and carrier setParameters
// (scaleResolutionDownBy + maxBitrate). Bisecting which one breaks the transform.
const arg = process.argv.find((a) => a.startsWith('--applike'));
// --applike            all three factors
// --applike=params     just that one — bisection mode
const APPLIKE = arg ? (arg.includes('=') ? arg.split('=')[1].split(',') : ['audio', 'bundle', 'params']) : [];

const browser = await chromium.launch({ executablePath: CHROME, headless: true });
const page = await browser.newPage();
// Same secure-context trap as wcprobe: probe on the real origin, not about:blank.
await page.goto(process.env.PROBE_URL || 'https://tape-app.deshmukh.workers.dev/');

const out = await page.evaluate(async ({ CODEC, APPLIKE }) => {
  const res = { codec: CODEC, applike: APPLIKE, hasTransform: 'RTCRtpScriptTransform' in window };
  if (!res.hasTransform) return res;

  // The worker runs both transforms; role comes from the transform's options.
  // Sender: xorshift32 pattern of a stepped length replaces every frame.
  // Receiver: regenerate the same pattern from the seed in the first 8 bytes and
  // compare every byte. One mismatch is a verdict, not a statistic.
  const workerSrc = `
    const prng = (seed) => () => {
      seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5;
      return (seed >>> 0) & 0xff;
    };
    const fill = (buf, seed) => { const r = prng(seed); for (let i = 8; i < buf.length; i++) buf[i] = r(); };
    const check = (buf, seed) => { const r = prng(seed); for (let i = 8; i < buf.length; i++) if (buf[i] !== r()) return i; return -1; };
    // Sizes to sweep: tiny, typical delta, larger than the carrier ever produces,
    // and a keyframe-sized 60 KB that must span many RTP packets.
    const SIZES = [60, 1200, 4800, 12000, 30000, 60000];
    let n = 0;
    const st = { sent: 0, sentBytes: 0, recv: 0, ok: 0, badAt: [], sizesSeen: {}, origSizes: [], hooked: [], workerErr: [] };
    self.onerror = (m) => { st.workerErr.push(String(m).slice(0, 200)); };
    onrtctransform = (e) => {
      // Spec says e.transform; Chrome (through at least 149) ships e.transformer.
      const tf = e.transform ?? e.transformer;
      const role = tf.options.role;
      st.hooked.push(role);
      const reader = tf.readable.getReader();
      const writer = tf.writable.getWriter();
      (async () => {
        for (;;) {
          const { done, value: frame } = await reader.read();
          if (done) return;
          try {
          // The receiver's depacketizer parses the head of the payload as a codec
          // header before it will assemble a frame — with fully foreign bytes it
          // assembled nothing (measured: sender put 4.22 MB on the wire, receiver
          // transform saw 0 frames). This is the same constraint that shaped SFrame:
          // leave the codec's unencrypted header region intact and put your bytes
          // after it. VP8: 10 bytes on a keyframe, 3 on a delta.
          const H = frame.type === 'key' ? 10 : 3;
          if (role === 'send') {
            const orig = new Uint8Array(frame.data);
            if (st.origSizes.length < 200) st.origSizes.push(orig.length);
            if (orig.length < H) { await writer.write(frame); continue; }
            const size = SIZES[n % SIZES.length];
            const seed = 0x9e3779b1 ^ n;
            const buf = new Uint8Array(H + 8 + size);
            buf.set(orig.subarray(0, H));
            const dv = new DataView(buf.buffer);
            dv.setUint32(H, seed);
            dv.setUint32(H + 4, size);
            { const r = prng(seed); for (let i = H + 8; i < buf.length; i++) buf[i] = r(); }
            frame.data = buf.buffer;
            n++;
            st.sent++; st.sentBytes += buf.length;
            await writer.write(frame);
          } else {
            const buf = new Uint8Array(frame.data);
            st.recv++;
            if (buf.length >= H + 8) {
              const dv = new DataView(frame.data);
              const seed = dv.getUint32(H);
              const claimed = dv.getUint32(H + 4);
              let bad = -2;
              if (H + 8 + claimed === buf.length) {
                bad = -1;
                const r = prng(seed);
                for (let i = H + 8; i < buf.length; i++) if (buf[i] !== r()) { bad = i; break; }
              }
              if (bad === -1) { st.ok++; st.sizesSeen[claimed] = (st.sizesSeen[claimed] || 0) + 1; }
              else st.badAt.push({ len: buf.length, claimed, bad });
            } else st.badAt.push({ len: buf.length, claimed: null, bad: -3 });
            // Deliberately NOT written: the decoder must never see the pattern.
          }
          } catch (err) { st.workerErr.push('loop: ' + String(err).slice(0, 200)); }
        }
      })();
    };
    onmessage = () => postMessage(st);
  `;
  const worker = new Worker(URL.createObjectURL(new Blob([workerSrc], { type: 'text/javascript' })));

  // Carrier: an animated canvas so the encoder produces real, varying frames.
  const cv = document.createElement('canvas');
  cv.width = 640; cv.height = 360;
  const ctx = cv.getContext('2d');
  let t0 = 0;
  const draw = (t) => {
    ctx.fillStyle = `hsl(${(t / 20) % 360},60%,40%)`;
    ctx.fillRect(0, 0, 640, 360);
    ctx.fillStyle = '#fff';
    ctx.fillRect(100 + 100 * Math.sin(t / 300), 100, 120, 120);
    t0 = requestAnimationFrame(draw);
  };
  draw(0);
  const stream = cv.captureStream(30);

  const pcCfg = APPLIKE.includes('bundle') ? { bundlePolicy: 'max-bundle' } : {};
  const pc1 = new RTCPeerConnection(pcCfg);
  const pc2 = new RTCPeerConnection(pcCfg);
  pc1.onicecandidate = (e) => e.candidate && pc2.addIceCandidate(e.candidate);
  pc2.onicecandidate = (e) => e.candidate && pc1.addIceCandidate(e.candidate);

  if (APPLIKE.includes('bidir')) {
    // Both directions on ONE m-line, like the app's sendrecv transceiver: pc2 sends a
    // canvas track back, and both sides carry a send AND a recv transform on the same
    // transceiver. Isolates whether sendrecv is what starves the receive transform.
    const cv2 = document.createElement('canvas');
    cv2.width = 640; cv2.height = 360;
    const cx2 = cv2.getContext('2d');
    setInterval(() => { cx2.fillStyle = '#345'; cx2.fillRect(0, 0, 640, 360); cx2.fillStyle = '#fff'; cx2.fillRect(Math.random() * 500, 100, 80, 80); }, 33);
    const s2 = cv2.captureStream(30);
    const snd2 = pc2.addTrack(s2.getVideoTracks()[0], s2);
    snd2.transform = new RTCRtpScriptTransform(worker, { role: 'send' });
    pc1.ontrack = (e) => {
      if (e.track.kind !== 'video') return;
      e.receiver.transform = new RTCRtpScriptTransform(worker, { role: 'recv' });
    };
  }
  if (APPLIKE.includes('audio')) {
    // An audio transceiver like the real call has (oscillator, so no gUM flags needed),
    // added FIRST so the m-line order matches the app's addTrack loop.
    const ac = new AudioContext();
    const osc = ac.createOscillator();
    const dst = ac.createMediaStreamDestination();
    osc.connect(dst); osc.start();
    pc1.addTrack(dst.stream.getAudioTracks()[0], dst.stream);
  }
  const sender = pc1.addTrack(stream.getVideoTracks()[0], stream);
  const setCarrierParams = async (which) => {
    const p = sender.getParameters();
    p.encodings = p.encodings?.length ? p.encodings : [{}];
    if (which.includes('scale')) p.encodings[0].scaleResolutionDownBy = 4;
    if (which.includes('bitrate')) p.encodings[0].maxBitrate = 12_000_000;
    await sender.setParameters(p).catch((e) => { res.paramsErr = String(e).slice(0, 120); });
  };
  // 'params' = both, pre-negotiation (what the app does). 'scale'/'bitrate' isolate.
  // 'late' applies both only after the connection is up.
  if (APPLIKE.includes('params')) await setCarrierParams(['scale', 'bitrate']);
  if (APPLIKE.includes('scale')) await setCarrierParams(['scale']);
  if (APPLIKE.includes('bitrate')) await setCarrierParams(['bitrate']);
  // The receive transform must be installed synchronously in ontrack. Attached later
  // (even before ICE completed, long before media flowed), Chrome routed every frame
  // around it: 238 assembled, 0 through the transform. The pipeline is evidently
  // frozen at track-fire time, not at first-frame time.
  const recvP = new Promise((r) => {
    pc2.ontrack = (e) => {
      if (e.track.kind !== 'video') return;
      e.receiver.transform = new RTCRtpScriptTransform(worker, { role: 'recv' });
      r(e.receiver);
    };
  });

  // Pin the carrier codec. The packetizer is codec-specific, and whether it tolerates
  // foreign bytes may be too — so the codec is this probe's one parameter.
  const tx = pc1.getTransceivers().find((t) => t.sender === sender);
  const caps = RTCRtpSender.getCapabilities('video');
  const want = caps.codecs.filter((c) => c.mimeType.toLowerCase() === CODEC.toLowerCase());
  if (!want.length) { res.error = `codec ${CODEC} not in capabilities`; return res; }
  tx.setCodecPreferences([...want, ...caps.codecs.filter((c) => !want.includes(c))]);

  sender.transform = new RTCRtpScriptTransform(worker, { role: 'send' });

  await pc1.setLocalDescription(await pc1.createOffer());
  await pc2.setRemoteDescription(pc1.localDescription);
  await pc2.setLocalDescription(await pc2.createAnswer());
  await pc1.setRemoteDescription(pc2.localDescription);

  await recvP;
  if (APPLIKE.includes('late')) {
    await new Promise((r) => setTimeout(r, 1500)); // let media start first
    await setCarrierParams(['scale', 'bitrate']);
  }
  await new Promise((r) => setTimeout(r, 8000));
  cancelAnimationFrame(t0);

  const st = await new Promise((r) => { worker.onmessage = (e) => r(e.data); worker.postMessage(0); });
  const stats = await pc1.getStats();
  let rtp = null;
  stats.forEach((s) => { if (s.type === 'outbound-rtp' && s.kind === 'video') rtp = s; });
  // The receive pipeline in stages, so a dead probe says WHERE frames die:
  // packetsReceived (RTP arrived) → framesReceived (assembled) → the transform (ours).
  const stats2 = await pc2.getStats();
  let inb = null;
  stats2.forEach((s) => { if (s.type === 'inbound-rtp' && s.kind === 'video') inb = s; });
  res.inb = inb && {
    packetsReceived: inb.packetsReceived, packetsLost: inb.packetsLost,
    framesReceived: inb.framesReceived ?? null, framesDecoded: inb.framesDecoded ?? null,
    framesDropped: inb.framesDropped ?? null, keyFramesDecoded: inb.keyFramesDecoded ?? null,
    pliCount: inb.pliCount ?? null, firCount: inb.firCount ?? null, nackCount: inb.nackCount ?? null,
  };
  res.st = st;
  res.rtp = rtp && {
    packetsSent: rtp.packetsSent, bytesSent: rtp.bytesSent,
    framesEncoded: rtp.framesEncoded, targetBitrate: rtp.targetBitrate ?? null,
    qualityLimitationReason: rtp.qualityLimitationReason ?? null,
  };
  pc1.close(); pc2.close();
  return res;
}, { CODEC, APPLIKE });

await browser.close();

console.log(`carrier codec: ${out.codec}   RTCRtpScriptTransform: ${out.hasTransform}`);
if (out.error) { console.log('ERROR:', out.error); process.exit(1); }
const st = out.st;
console.log(`transforms hooked: [${st.hooked.join(', ')}]  worker errors: ${JSON.stringify(st.workerErr.slice(0, 3))}`);
console.log(`sender transform: replaced ${st.sent} frames (${(st.sentBytes / 1e6).toFixed(2)} MB of our bytes)`);
console.log(`  carrier's own frame sizes (first few): ${st.origSizes.slice(0, 6).join(', ')} B`);
console.log(`receiver transform: got ${st.recv} frames, byte-perfect ${st.ok}, corrupt ${st.badAt.length}`);
console.log(`  sizes verified: ${Object.entries(st.sizesSeen).map(([k, v]) => `${k}B×${v}`).join('  ')}`);
if (st.badAt.length) console.log('  first corruptions:', JSON.stringify(st.badAt.slice(0, 5)));
console.log(`RTP under it: ${JSON.stringify(out.rtp)}`);
console.log(`receive pipeline: ${JSON.stringify(out.inb)}`);
const delivered = st.sent ? ((st.ok / st.sent) * 100).toFixed(1) : '0';
console.log(`\nVERDICT: ${delivered}% of substituted frames arrived byte-perfect` +
  (st.ok === st.sent && st.sent > 0 ? ' — the lane carries foreign bytes.' :
   st.ok > 0 ? ' — partial; look at which sizes failed.' : ' — the packetizer rejects foreign bytes.'));
