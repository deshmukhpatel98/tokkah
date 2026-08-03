/**
 * AudioWorklet wrapper around the shared onset detector.
 *
 * Runs on the audio render thread, which is the only place it can run: onset
 * detection is worth ~200 ms (DESIGN.md §3.1 lever 1) and the main thread will
 * happily hand us a 50 ms hitch during a layout, spending a quarter of the head
 * start on nothing. The detector itself allocates nothing per hop for the same
 * reason.
 *
 * All this file does is adapt block sizes and post events out. Keep the real logic
 * in core/onset.js so it stays testable under node.
 */

import { OnsetDetector } from './core/onset.js';

class OnsetProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.det = new OnsetDetector({
      sampleRate,
      ...(options?.processorOptions ?? {}),
    });
    this.startTime = currentTime;
    this.alive = true;
    this.blocks = 0;
    this.port.onmessage = (e) => {
      if (e.data === 'stop') this.alive = false;
    };
  }

  process(inputs) {
    const ch = inputs[0]?.[0];
    if (!ch) return this.alive; // no input connected yet — stay alive, don't die

    const events = this.det.push(ch);

    // Level readout, ~every 50 ms. Deliberately sourced from the detector's own
    // state rather than a parallel AnalyserNode: a meter that disagrees with the
    // thing making decisions is worse than no meter, because it makes a real
    // threshold problem look like a display bug.
    if (++this.blocks % 19 === 0) {
      let sum = 0;
      for (let i = 0; i < ch.length; i++) sum += ch[i] * ch[i];
      this.port.postMessage({
        type: 'level',
        rmsDb: 20 * Math.log10(Math.max(Math.sqrt(sum / ch.length), 1e-10)),
        floorDb: this.det.noiseFloorDb,
        // Included because a wedged turn — one that never ends — is invisible in the
        // level alone, and a wedge is what a room too noisy for the end threshold
        // actually looks like. Measured on a -48 dBFS fixture, two received turns ran
        // to the 30-second backstop while the level readout looked unremarkable.
        state: this.det.state,
        quietHops: this.det.quietHops,
        activeHops: this.det.activeHops,
      });
    }

    for (const ev of events) {
      // Convert the detector's sample index into an AudioContext timestamp. This
      // is the number that matters downstream: it is on the same clock as
      // `AudioContext.currentTime`, so the turn-taking harness can compare an
      // onset here against an onset on the far side without guessing at buffering.
      this.port.postMessage({
        ...ev,
        ctxTime: this.startTime + ev.at / sampleRate,
        atMs: (ev.at / sampleRate) * 1000,
      });
    }
    return this.alive;
  }
}

registerProcessor('onset-detector', OnsetProcessor);
