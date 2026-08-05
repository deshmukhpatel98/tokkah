/**
 * Interpreter worklets (TRANSLATE-SPEC.md) — deliberately NOT part of Lane A.
 *
 *   xlate-tap   mic 48 kHz float → 16 kHz s16le, posted in 100 ms chunks for
 *               the STT uplink. Also a small energy VAD: after ≥350 ms of
 *               quiet following voiced audio it posts {flush:true}, which the
 *               Worker turns into a Scribe commit — our own ears end the
 *               phrase, not the vendor's timeout (T_tail lever, spec §5).
 *
 *   xlate-play  translated 48 kHz speech from the Worker. Prebuffers 150 ms,
 *               plays, and on underrun goes silent until the NEXT segment
 *               boundary — translated speech is not the call, a gap in it is
 *               a pause, never a repeat or a stretch.
 *
 * Decimation is mean-of-3 (48→16 kHz). That is a first-order anti-alias filter
 * only; fine for ASR speech, revisit if Scribe WER on sibilants looks off.
 */

class XlateTap extends AudioWorkletProcessor {
  constructor() {
    super();
    this.CHUNK = 1600;                 // 100 ms at 16 kHz
    this.buf = new Int16Array(this.CHUNK);
    this.n = 0;
    this.carry = [];                   // <3 leftover 48k samples between calls
    this.quietMs = 0;
    this.voiced = false;
    this.THRESH = 0.006;               // rms floor for "someone is talking"
    this.FLUSH_MS = 350;
  }
  process(inputs) {
    const ch = inputs[0]?.[0];
    if (!ch) return true;
    let sum = 0;
    const s = this.carry.concat(); // cheap: carry is 0–2 samples
    this.carry = [];
    for (let i = 0; i < ch.length; i++) sum += ch[i] * ch[i];
    const rms = Math.sqrt(sum / ch.length);
    const all = s.length ? Float32Array.from([...s, ...ch]) : ch;
    const whole = Math.floor(all.length / 3) * 3;
    for (let i = 0; i < whole; i += 3) {
      const v = (all[i] + all[i + 1] + all[i + 2]) / 3;
      this.buf[this.n++] = Math.max(-32768, Math.min(32767, Math.round(v * 32767)));
      if (this.n === this.CHUNK) {
        const out = this.buf.slice();
        this.port.postMessage(out.buffer, [out.buffer]);
        this.n = 0;
      }
    }
    for (let i = whole; i < all.length; i++) this.carry.push(all[i]);

    const frameMs = (ch.length / sampleRate) * 1000;
    if (rms > this.THRESH) { this.voiced = true; this.quietMs = 0; }
    else if (this.voiced) {
      this.quietMs += frameMs;
      if (this.quietMs >= this.FLUSH_MS) { this.voiced = false; this.port.postMessage({ flush: true }); }
    }
    return true;
  }
}

class XlatePlay extends AudioWorkletProcessor {
  constructor() {
    super();
    this.q = [];            // Float32Array chunks, 48 kHz mono
    this.qSamples = 0;
    this.off = 0;           // read offset into q[0]
    this.PREBUF = 7200;     // 150 ms before a segment starts speaking
    this.playing = false;
    this.played = 0;
    this.port.onmessage = (e) => {
      if (e.data?.reset) { this.q = []; this.qSamples = 0; this.off = 0; this.playing = false; return; }
      const f = new Float32Array(e.data);
      this.q.push(f);
      this.qSamples += f.length;
    };
  }
  process(_in, outputs) {
    const out = outputs[0][0];
    if (!out) return true;
    if (!this.playing && this.qSamples >= this.PREBUF) this.playing = true;
    if (!this.playing) { out.fill(0); return true; }
    let w = 0;
    while (w < out.length && this.q.length) {
      const head = this.q[0];
      const take = Math.min(out.length - w, head.length - this.off);
      out.set(head.subarray(this.off, this.off + take), w);
      w += take; this.off += take; this.qSamples -= take; this.played += take;
      if (this.off === head.length) { this.q.shift(); this.off = 0; }
    }
    if (w < out.length) { out.fill(0, w); this.playing = false; } // drained: wait for next prebuffer
    return true;
  }
}

registerProcessor('xlate-tap', XlateTap);
registerProcessor('xlate-play', XlatePlay);
