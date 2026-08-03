/**
 * WebKit declares lane 2 now but fails at 'encoder-setup'. Which part of the ACTUAL
 * config does it reject? The lane's quality comes from fixed-QP encoding
 * (bitrateMode:'quantizer' + avc.quantizer), which is the prime suspect: it is the one
 * option in the set that is not universally implemented.
 *
 * isConfigSupported on the bare codec already returned true (testbed/wkcaps.mjs), so the
 * bare codec is not the answer — this tests the option combination and then actually
 * CONFIGURES and encodes, because isConfigSupported is allowed to lie by omission
 * (tape.js:285 already guards against a silently downgraded bitrateMode).
 */
import { webkit, chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';
const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';

const run = async (name, ctx) => {
  const p = await ctx.newPage();
  await ctx.route('https://enc.test/**', (r) => r.fulfill({ contentType: 'text/html', body: '<html><body></body></html>' }));
  await p.goto('https://enc.test/');
  const rows = await p.evaluate(async () => {
    const base = { codec: 'avc1.640028', width: 1920, height: 1080, framerate: 30 };
    const CASES = [
      ['bare codec', { ...base }],
      ['+ latencyMode realtime', { ...base, latencyMode: 'realtime' }],
      ['+ avc annexb', { ...base, latencyMode: 'realtime', avc: { format: 'annexb' } }],
      ['+ bitrateMode quantizer  <-- the lane', { ...base, latencyMode: 'realtime', bitrateMode: 'quantizer', avc: { format: 'annexb' } }],
      ['bitrateMode constant + bitrate', { ...base, latencyMode: 'realtime', bitrateMode: 'constant', bitrate: 12_000_000, avc: { format: 'annexb' } }],
      ['bitrateMode variable + bitrate', { ...base, latencyMode: 'realtime', bitrateMode: 'variable', bitrate: 12_000_000, avc: { format: 'annexb' } }],
    ];
    const out = [];
    for (const [label, config] of CASES) {
      const row = { label };
      try {
        const sup = await VideoEncoder.isConfigSupported(config);
        row.supported = !!sup.supported;
        row.echoedBitrateMode = sup.config?.bitrateMode ?? '(absent from echo)';
      } catch (e) { row.supErr = `${e.name}: ${e.message}`; }
      // Then actually configure and push one frame through: isConfigSupported can
      // report true and configure() can still throw.
      try {
        let chunks = 0, err = null;
        const enc = new VideoEncoder({ output: () => { chunks++; }, error: (e) => { err = String(e); } });
        enc.configure(config);
        const c = new OffscreenCanvas(config.width, config.height);
        const g = c.getContext('2d');
        g.fillStyle = '#3a7'; g.fillRect(0, 0, config.width, config.height);
        const f = new VideoFrame(c, { timestamp: 0 });
        // The per-frame quantizer the lane actually uses on every encode() call.
        try { enc.encode(f, { keyFrame: true, avc: { quantizer: 24 } }); row.perFrameQp = 'accepted'; }
        catch (e) { row.perFrameQp = `${e.name}: ${e.message}`.slice(0, 70); }
        f.close();
        await enc.flush().catch((e) => { err = String(e); });
        row.encoded = chunks; row.runtimeErr = err;
        enc.close();
      } catch (e) { row.cfgErr = `${e.name}: ${e.message}`.slice(0, 90); }
      out.push(row);
    }
    return out;
  });
  console.log(`\n=== ${name} ===`);
  for (const r of rows) {
    console.log(`  ${r.label.padEnd(38)} isConfigSupported ${String(r.supported ?? r.supErr).padEnd(6)}` +
      `  echo bitrateMode ${String(r.echoedBitrateMode).padEnd(20)}`);
    console.log(`  ${' '.repeat(38)} configure: ${r.cfgErr ?? 'ok'}   perFrameQp: ${r.perFrameQp ?? '-'}` +
      `   chunks: ${r.encoded ?? 0}${r.runtimeErr ? '   runtime: ' + r.runtimeErr.slice(0, 60) : ''}`);
  }
  await p.close();
};
const wb = await webkit.launch();
await run('WebKit 26.5', await wb.newContext({ ignoreHTTPSErrors: true }));
await wb.close();
const cb = await chromium.launch({ executablePath: CHROME });
await run('Chrome for Testing (the reference)', await cb.newContext({ ignoreHTTPSErrors: true }));
await cb.close();
