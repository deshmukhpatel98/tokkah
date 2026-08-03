/**
 * What bit depth does the capture chain actually deliver, and will Chrome say?
 *
 * WHY THIS EXISTS. `core/pcmpack.js` can strip the trailing zero bits a 16-bit
 * capture leaves in the int24 container — half the audio lane — but measured
 * live it never fires: `wastedShift 0`, `fit32768 0%`, `fit32767 0%`, and no
 * constant gain fits the samples (MEASURED.md, "SHIPPED but INERT"). Chrome
 * resamples and filters in float below the source's real depth, so a 16-bit WAV
 * arrives using the full 24-bit range. The low 8 bits are arithmetic residue,
 * not microphone signal, and we transmit them with perfect fidelity.
 *
 * That makes "cheapest" and "bit-exact" pull in opposite directions, and the
 * decision needs data rather than a preference. This asks the only questions
 * that can be answered without touching production:
 *
 *   1. Does Chrome report `sampleSize` in getSettings/getCapabilities? If it
 *      says 16, a 16-bit lane is lossless WITH RESPECT TO THE DEVICE and the
 *      claim can stay honest while the lane halves.
 *   2. Is the AudioContext running at the device's rate, i.e. is a resample
 *      happening at all?
 * Question 3 — is the residue compressible? — is ALREADY ANSWERED and is not
 * re-measured here. Live `bPerFrame` is 708 B against 701 B for the same audio
 * with UNIFORM RANDOM low bytes offline (testbed/pcmwasted.mjs, dither arm).
 * The real residue codes slightly WORSE than maximum-entropy noise, so it is
 * white: no predictor or entropy coder recovers it while staying bit-exact. That
 * leaves depth itself as the only remaining lever, which is what this probes.
 *
 * It deliberately does NOT load our app: fewer moving parts between the question
 * and the answer, and the app has already been measured.
 *
 *   node testbed/bitdepth.mjs
 */
import { chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';

const CHROME = '/Users/earningsgpt/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing';
const AUD = '/Users/earningsgpt/video calling/testbed/media/conv/A.wav';

const c = await chromium.launchPersistentContext('', {
  executablePath: CHROME, headless: true,
  args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
    `--use-file-for-fake-audio-capture=${AUD}`,
    '--autoplay-policy=no-user-gesture-required'],
});
const p = await c.newPage();
// A secure origin is required for getUserMedia; about:blank is not one.
await p.goto('https://room.tokkah.com/', { waitUntil: 'domcontentloaded' });

const r = await p.evaluate(async () => {
  // The SAME constraints production requests (onset-monitor.js audioConstraints).
  const st = await navigator.mediaDevices.getUserMedia({
    audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false,
             channelCount: 1, sampleRate: 48000 },
  });
  const t = st.getAudioTracks()[0];
  const settings = t.getSettings();
  const caps = t.getCapabilities ? t.getCapabilities() : null;
  const supported = navigator.mediaDevices.getSupportedConstraints();

  // An AudioContext only to read the rate the graph actually runs at. No
  // worklet: this page's CSP refuses a blob: module, and the sample-level
  // question it would have answered is already settled (see the header).
  const ac = new AudioContext({ sampleRate: 48000 });
  const devices = (await navigator.mediaDevices.enumerateDevices())
    .filter((d) => d.kind === 'audioinput').map((d) => d.label);
  return {
    settings, caps, sampleSizeSupported: 'sampleSize' in supported,
    ctxRate: ac.sampleRate, baseLatency: ac.baseLatency, devices,
  };
});
await c.close();

console.log('\ngetSettings():', JSON.stringify(r.settings));
console.log('sampleSize in getSupportedConstraints():', r.sampleSizeSupported);
console.log('sampleSize in getSettings():', 'sampleSize' in r.settings ? r.settings.sampleSize : 'ABSENT');
console.log('getCapabilities():', JSON.stringify(r.caps));
console.log('audio inputs:', JSON.stringify(r.devices));
console.log(`\nAudioContext rate ${r.ctxRate} Hz, baseLatency ${r.baseLatency}`);
console.log('\nIf sampleSize is ABSENT and unsupported, the platform will not tell us the');
console.log('capture depth, so a 16-bit lane could not be justified per-device -- it would');
console.log('be an assumption about hardware, which is what this whole line of work exists');
console.log('to avoid. See MEASURED.md "SHIPPED but INERT: wasted bits".');
