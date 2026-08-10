/**
 * Shared plumbing for running the onset detector over a MediaStream.
 *
 * Two monitors get created per participant: one on the local mic, one on the
 * *received* remote audio. That second one is the important design decision in the
 * whole harness, so it's worth stating plainly:
 *
 *   Measuring a conversational gap across two machines normally needs clock sync —
 *   the question ends on my clock and the answer begins on yours, and comparing
 *   them means trusting an offset estimate. But if I run a detector on the audio
 *   *arriving* at my machine, then "when I stopped talking" and "when their breath
 *   reached me" are both events on my own clock. No sync, no offset, no estimate.
 *   And the number that falls out is exactly the one that matters: the gap the
 *   human actually perceived, network latency included, because the network
 *   latency is physically inside the measurement rather than added to it.
 *
 * A single AudioContext hosts both nodes so their timestamps share an origin.
 */

const WORKLET_URL = '/onset-worklet.js';

/**
 * addModule with one cache-busted retry. A live Android call (room log
 * 2026-08-06) had EVERY worklet load fail with AbortError for 16 straight
 * minutes — lobby meter, PCM lane, translation — after a reload interrupted a
 * fetch: the signature of a poisoned HTTP cache entry, which a plain retry
 * re-reads forever. A `?cb=` query is a different cache key, so the second
 * attempt goes to the network.
 */
export async function addWorkletModule(context, url) {
  try {
    await context.audioWorklet.addModule(url);
  } catch (e) {
    await context.audioWorklet.addModule(url + (url.includes('?') ? '&' : '?') + 'cb=' + Date.now());
  }
}

let ctx = null;
let moduleLoaded = null;

/** Lazily create the one shared AudioContext. */
export async function audioContext() {
  if (!ctx) {
    // Lane A (?pcmaudio=1) plays PCM straight out of a worklet on this context:
    // ask for the floor. With the flag off the hint is exactly what it was.
    // KNOWN MISMATCH, deliberately unresolved: app.js made Lane A default ON
    // (`!== '0'`, 2026-08-02) while this still wants an explicit =1, so
    // default calls run at 'interactive' (~34 ms output latency measured)
    // rather than the floor. A fix was tried live 2026-08-11 and the A/B was
    // CONFOUNDED: outputLatency read ~300 ms in both arms because the Mac's
    // output device changed mid-experiment (~300 ms is a Bluetooth sink, and
    // the revert read the same). Re-run the A/B when the control arm reads
    // ~34 ms again before touching this line.
    const pcm = new URLSearchParams(location.search).get('pcmaudio') === '1';
    ctx = new AudioContext({ sampleRate: 48000, latencyHint: pcm ? 0 : 'interactive' });
    moduleLoaded = addWorkletModule(ctx, WORKLET_URL);
  }
  await moduleLoaded;
  if (ctx.state === 'suspended') await ctx.resume();
  return ctx;
}

/**
 * Attach a detector to `stream`. `onEvent(ev)` receives the detector's events with
 * `label` added. Returns { node, source, disconnect }.
 *
 * `audible` must be true for a remote WebRTC stream: Chromium will not pull audio
 * from a remote MediaStream that isn't also sunk to an element, so the detector
 * would sit silent forever. It's a real bug that presents as "the far side never
 * speaks", which is indistinguishable from a signalling failure — hence the
 * dedicated flag rather than a comment on the call site.
 */
export async function attachDetector(stream, label, onEvent, { audible = false } = {}) {
  const c = await audioContext();

  let sink = null;
  if (audible) {
    sink = new Audio();
    sink.srcObject = stream;
    sink.autoplay = true;
    await sink.play().catch(() => {
      /* autoplay policy — the caller already has a user gesture, so this is rare */
    });
  }

  const source = c.createMediaStreamSource(stream);
  const node = new AudioWorkletNode(c, 'onset-detector', { numberOfOutputs: 0 });
  node.port.onmessage = (e) => onEvent({ ...e.data, label });
  source.connect(node);

  return {
    node,
    source,
    ctx: c,
    disconnect() {
      try {
        source.disconnect();
        node.port.postMessage('stop');
      } catch {
        /* already gone */
      }
      if (sink) {
        sink.pause();
        sink.srcObject = null;
      }
    },
  };
}

/** Raw-capture constraints. The four flags of DESIGN.md §5, plus the processed A/B. */
export function audioConstraints(raw) {
  return raw
    ? {
        echoCancellation: false,
        noiseSuppression: false,
        autoGainControl: false,
        channelCount: 1,
        sampleRate: 48000,
      }
    : { echoCancellation: true, noiseSuppression: true, autoGainControl: true };
}

/** Median of a numeric array. Returns null for empty. */
export function median(xs) {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}
