// What can this Android build's WebCodecs actually encode/decode?
import { chromium } from 'playwright-core';
const b = await chromium.connectOverCDP(process.env.EMU_CDP ?? 'http://127.0.0.1:9223');
const ctx = b.contexts()[0];
const p = await ctx.newPage();
await p.goto('https://room.tokkah.com/', { waitUntil: 'domcontentloaded', timeout: 60000 });
const out = await p.evaluate(async () => {
  const codecs = ['avc1.640028', 'avc1.4d0028', 'avc1.42e028', 'avc1.42e01f', 'vp8', 'vp09.00.10.08', 'av01.0.04M.08'];
  const r = { enc: {}, dec: {} };
  for (const c of codecs) {
    try {
      const e = await VideoEncoder.isConfigSupported({ codec: c, width: 1280, height: 720, framerate: 30, latencyMode: 'realtime', bitrateMode: 'quantizer', ...(c.startsWith('avc1') ? { avc: { format: 'annexb' } } : {}) });
      r.enc[c] = e.supported ? 'qp' : 'no-qp';
    } catch { r.enc[c] = 'throw'; }
    if (r.enc[c] !== 'qp') {
      try {
        const e2 = await VideoEncoder.isConfigSupported({ codec: c, width: 1280, height: 720, framerate: 30, latencyMode: 'realtime', bitrateMode: 'variable', bitrate: 12_000_000, ...(c.startsWith('avc1') ? { avc: { format: 'annexb' } } : {}) });
        if (e2.supported) r.enc[c] += '+vbr';
      } catch { /* stays */ }
    }
    try {
      const d = await VideoDecoder.isConfigSupported({ codec: c, codedWidth: 1280, codedHeight: 720, optimizeForLatency: true });
      r.dec[c] = d.supported;
    } catch { r.dec[c] = 'throw'; }
    // And WITHOUT optimizeForLatency, in case the flag is what kills it.
    try {
      const d2 = await VideoDecoder.isConfigSupported({ codec: c, codedWidth: 1280, codedHeight: 720 });
      r.dec[c + ' (plain)'] = d2.supported;
    } catch { r.dec[c + ' (plain)'] = 'throw'; }
  }
  return r;
});
console.log(JSON.stringify(out, null, 1));
await p.close().catch(() => {});
process.exit(0);
