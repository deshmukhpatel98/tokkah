// spec-capture: taps a stream and ships raw PCM to the main thread.
// Used by testbed/call.mjs --spectap because AnalyserNode is deaf on this
// graph (measured: worklet hears -18 dB where an analyser on the same
// context+stream reads -58 dB). The worklet is the node type that works.
class SpecCapture extends AudioWorkletProcessor {
  process(inputs) {
    const ch = inputs[0] && inputs[0][0];
    if (ch && ch.length) this.port.postMessage(ch.slice(0));
    return true;
  }
}
registerProcessor('spec-capture', SpecCapture);
