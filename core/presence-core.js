/**
 * presence-core — the room, added back. (?presence=1, default off)
 *
 * A dry mono voice played diotically (same signal, both ears) localizes
 * INSIDE the head on headphones and "flat, from the grille" on speakers.
 * A person actually in the room in front of you arrives with something a
 * call strips away: a handful of quiet, direction-scrambled early wall
 * reflections in the first ~25 ms. Those reflections are what the ear uses
 * to externalize a source — to decide the sound is out THERE, at a distance,
 * in a space — and their interaural dissimilarity (IACC well below 1) is the
 * single strongest known correlate of "spaciousness" in room acoustics.
 *
 * So this module renders exactly that, and nothing else:
 *
 *   outL[n] = x[n] + Σk gk · x̃[n − dLk]      x̃ = x through a one-pole
 *   outR[n] = x[n] + Σk gk · x̃[n − dRk]          lowpass (walls absorb highs)
 *
 * The law of the direct path: the voice itself is the INPUT SAMPLE, at unity,
 * added untouched to both ears — never filtered, never panned, never delayed.
 * Everything this module contributes is strictly additive room, at −20 dB and
 * below. Until the first reflection's delay has elapsed, the output is
 * bit-identical to the input; a silent input yields a bit-exact silent output
 * once the delay line has drained (the lowpass state is flushed to true zero
 * below 1e-30, which also keeps denormals off the audio thread).
 *
 * Tap plan (delay ms → dB), chosen like a small treated room, not a hall:
 *     left ear: 7.9 → −20   13.1 → −23   21.7 → −26
 *    right ear: 9.7 → −20   15.9 → −23   24.9 → −26
 * Delays are mutually non-harmonic (no comb coloration), all within the
 * ~30 ms Haas window (they fuse with the voice rather than reading as echo),
 * and deliberately asymmetric between ears — that asymmetry is the
 * decorrelation that buys externalization. Worst-case coherent peak gain is
 * +1.9 dB (Σgk = 0.25); speech at sane capture levels does not clip, and the
 * mono downmix (L+R)/2 stays within ±0.6 dB of flat.
 *
 * Where it sits in the lane: AFTER the playout worklet's fill() — which means
 * after concealment and drift resampling, and after the block is published to
 * the AEC2 far-end reference ring and the remote onset detector. The canceller
 * and every detector keep seeing the pristine mono lane; the room exists only
 * in the last metres before the DAC. With the flag off this module is never
 * constructed and the playout path is byte-identical to before it existed.
 */

// One shared reflection tap table — {ms, db, ear} with ear 0=L, 1=R.
const TAPS = [
  { ms: 7.9, db: -20, ear: 0 },
  { ms: 9.7, db: -20, ear: 1 },
  { ms: 13.1, db: -23, ear: 0 },
  { ms: 15.9, db: -23, ear: 1 },
  { ms: 21.7, db: -26, ear: 0 },
  { ms: 24.9, db: -26, ear: 1 },
];

// Wall-absorption lowpass corner. High enough to keep the room "present",
// low enough that reflections never read as a second, crisp voice.
const LPF_HZ = 3800;

export function createPresence({ sampleRate = 48000 } = {}) {
  // Delay ring sized to the longest tap (24.9 ms = 1196 samples @48k) plus a
  // render quantum of slack; power of two so the mask replaces a modulo.
  const RING = 2048;
  const MASK = RING - 1;
  const ring = new Float32Array(RING); // holds x̃ (lowpassed input)
  let w = 0; // write index (next sample position)

  // One-pole lowpass: y[n] = (1−a)·x[n] + a·y[n−1], a = e^(−2π·fc/fs).
  const a = Math.exp((-2 * Math.PI * LPF_HZ) / sampleRate);
  const b = 1 - a;
  let lp = 0;

  const taps = TAPS.map((t) => ({
    d: Math.round((t.ms / 1000) * sampleRate),
    g: Math.pow(10, t.db / 20),
    ear: t.ear,
  }));

  let samples = 0;

  return {
    /**
     * Render one block. `mono` is the pristine fill() output; `outL`/`outR`
     * are the two device channels (outL MAY alias mono — it is read before
     * being written at each index). All three must share a length.
     */
    render(mono, outL, outR) {
      for (let n = 0; n < mono.length; n++) {
        const x = mono[n];
        lp = b * x + a * lp;
        if (lp < 1e-30 && lp > -1e-30) lp = 0; // silence → true zero, no denormals
        ring[w & MASK] = lp;
        let rl = 0;
        let rr = 0;
        for (let k = 0; k < taps.length; k++) {
          const t = taps[k];
          const s = ring[(w - t.d) & MASK] * t.g;
          if (t.ear === 0) rl += s;
          else rr += s;
        }
        w++;
        outL[n] = x + rl;
        outR[n] = x + rr;
      }
      samples += mono.length;
    },

    stats() {
      return { type: 'presence', samples, taps: taps.length, lpfHz: LPF_HZ };
    },
  };
}
