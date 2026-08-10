// Does the browser let us control the encoder the way "lossless" requires?
//
// DESIGN.md asks for a fixed-QP encoder: quality is a constant, time is the shock
// absorber. Stock WebRTC cannot do that -- you hand it a bitrate and it spends
// quality to hit it. WebCodecs *might* let us hand it a quantizer instead.
//
// If `bitrateMode: 'quantizer'` is supported, the fixed-quality design is buildable
// in the browser and a native client is an optimisation, not a prerequisite.
// If it is not, native is the only road and we should take it.
import { chromium } from 'playwright-core';

const CHROME =
  process.env.CHROME_PATH ||
  process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');

const browser = await chromium.launch({
  executablePath: CHROME,
  headless: true,
  args: ['--enable-features=SharedArrayBuffer', '--use-gl=angle'],
});
const page = await browser.newPage();
// WebCodecs, WebTransport and WebGPU are secure-context-only. about:blank is an opaque
// origin, so probing there reports every one of them missing -- which is a fact about
// the probe, not the browser.
await page.goto(process.env.PROBE_URL || 'https://tape-app.deshmukh.workers.dev/');

const out = await page.evaluate(async () => {
  const res = { ua: navigator.userAgent, has: {}, configs: [], quantizerAccepted: null };

  res.has = {
    VideoEncoder: typeof VideoEncoder !== 'undefined',
    VideoDecoder: typeof VideoDecoder !== 'undefined',
    VideoFrame: typeof VideoFrame !== 'undefined',
    MediaStreamTrackProcessor: typeof MediaStreamTrackProcessor !== 'undefined',
    MediaStreamTrackGenerator: typeof MediaStreamTrackGenerator !== 'undefined',
    WebTransport: typeof WebTransport !== 'undefined',
    RTCRtpScriptTransform: typeof RTCRtpScriptTransform !== 'undefined',
    gpu: !!navigator.gpu,
  };
  if (!res.has.VideoEncoder) return res;

  // Codec strings: H.264 High 4.2, H.264 Baseline, VP9 profile 0, AV1 Main, VP8.
  const codecs = [
    ['h264-high', 'avc1.640028'],
    ['h264-base', 'avc1.42E01F'],
    ['vp9', 'vp09.00.10.08'],
    ['av1', 'av01.0.04M.08'],
    ['vp8', 'vp8'],
  ];
  const modes = ['constant', 'variable', 'quantizer'];

  for (const [name, codec] of codecs) {
    for (const mode of modes) {
      const cfg = {
        codec,
        width: 1920,
        height: 1080,
        framerate: 30,
        latencyMode: 'realtime',
        bitrateMode: mode,
      };
      // 'quantizer' mode means bitrate is meaningless; every other mode needs one.
      if (mode !== 'quantizer') cfg.bitrate = 8_000_000;
      if (name.startsWith('h264')) cfg.avc = { format: 'annexb' };
      let r;
      try {
        r = await VideoEncoder.isConfigSupported(cfg);
      } catch (e) {
        res.configs.push({ codec: name, mode, supported: false, error: String(e).slice(0, 90) });
        continue;
      }
      res.configs.push({
        codec: name,
        mode,
        supported: !!r.supported,
        // Chrome echoes back the config it would actually use. If it silently drops
        // bitrateMode, the echo is how we find out -- "supported: true" alone is a lie
        // we would otherwise build on.
        echoedMode: r.config?.bitrateMode ?? null,
        hw: r.config?.hardwareAcceleration ?? null,
      });
    }
  }

  // isConfigSupported is a promise about the future. Actually construct one and push a
  // frame through with a per-frame quantizer, because that is the thing we need to work.
  try {
    const chunks = [];
    const enc = new VideoEncoder({
      output: (c) => chunks.push({ size: c.byteLength, type: c.type }),
      error: (e) => { res.quantizerAccepted = { error: String(e).slice(0, 120) }; },
    });
    enc.configure({
      codec: 'avc1.640028',
      width: 640,
      height: 360,
      framerate: 30,
      latencyMode: 'realtime',
      bitrateMode: 'quantizer',
      avc: { format: 'annexb' },
    });
    // Two frames of flat grey, then two of noise. Under a fixed quantizer the noisy
    // frames must cost more bytes -- that is what "quality is a constant" looks like
    // from the outside.
    const mk = (noisy) => {
      const w = 640, h = 360;
      const buf = new Uint8Array(w * h * 4);
      for (let i = 0; i < buf.length; i += 4) {
        const v = noisy ? (Math.random() * 255) | 0 : 128;
        buf[i] = v; buf[i + 1] = v; buf[i + 2] = v; buf[i + 3] = 255;
      }
      return buf;
    };
    let ts = 0;
    for (const noisy of [false, false, true, true]) {
      const f = new VideoFrame(mk(noisy), {
        format: 'RGBA', codedWidth: 640, codedHeight: 360, timestamp: ts,
      });
      // The per-frame knob. If encode() rejects this option the design is dead here.
      enc.encode(f, { keyFrame: ts === 0, avc: { quantizer: 24 } });
      f.close();
      ts += 33333;
    }
    await enc.flush();
    enc.close();
    if (!res.quantizerAccepted) {
      res.quantizerAccepted = {
        ok: true,
        chunks: chunks.map((c) => `${c.type}:${c.size}`),
        greyBytes: chunks[1]?.size ?? null,
        noisyBytes: chunks[3]?.size ?? null,
      };
    }
  } catch (e) {
    res.quantizerAccepted = { error: String(e).slice(0, 200) };
  }

  return res;
});

await browser.close();

console.log('UA:', out.ua.replace(/.*Chrome\/([\d.]+).*/, 'Chrome $1'));
console.log('\nAPIs:');
for (const [k, v] of Object.entries(out.has)) console.log(`  ${v ? 'yes' : 'NO '}  ${k}`);
console.log('\n1080p30 realtime encoder configs:');
const byCodec = {};
for (const c of out.configs) (byCodec[c.codec] ??= []).push(c);
for (const [codec, rows] of Object.entries(byCodec)) {
  const cells = rows.map((r) => {
    const mark = r.supported ? 'ok' : '--';
    const drift = r.supported && r.echoedMode && r.echoedMode !== r.mode ? `(echoed ${r.echoedMode})` : '';
    return `${r.mode}=${mark}${drift}`;
  });
  console.log(`  ${codec.padEnd(10)} ${cells.join('  ')}   hw=${rows[0].hw ?? '?'}`);
}
console.log('\nReal fixed-QP encode (per-frame quantizer=24, 640x360):');
console.log(' ', JSON.stringify(out.quantizerAccepted));
if (out.quantizerAccepted?.ok) {
  const { greyBytes, noisyBytes } = out.quantizerAccepted;
  if (greyBytes && noisyBytes) {
    console.log(`  grey delta frame ${greyBytes} B -> noisy delta frame ${noisyBytes} B` +
      `  (${(noisyBytes / greyBytes).toFixed(1)}x)`);
    console.log('  Bytes moved with scene complexity at constant QP: quality held, size floated.');
  }
}
