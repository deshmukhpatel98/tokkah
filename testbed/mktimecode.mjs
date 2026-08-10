#!/usr/bin/env node
/**
 * Build timecode fixtures whose frames are the size real video frames are.
 *
 * WHY THIS EXISTS. `timecode720.y4m` is a near-black field with one small moving
 * bar. It compresses to a SINGLE 1100-byte fragment per frame — measured, twice,
 * `fragsSent == framesEncoded` exactly, and unchanged when forced to `qp=10`.
 * Lane 1 gates its XOR parity on `count > 1` fragments, so on that fixture
 * `paritySent` is always 0 and the lane's loss protection is structurally dead.
 * Every loss-condition number taken on it measured a lane with its FEC switched
 * off, and repeats of one configuration ranged 57.8%-87.1% delivered.
 *
 * So: same 11-cell bar, same 256 frames, same geometry — over REAL camera
 * footage. The shipping config puts a 720p camera at ~6.43 Mbps / 30 fps, so
 * ~27 KB per frame, ~25 fragments. That is the regime FEC and loss recovery
 * actually run in.
 *
 * Both outputs come from one decode pass and differ ONLY in the source-tag bit,
 * which is what makes a self-view identifiable rather than merely improbable.
 *
 *   node mktimecode.mjs [--frames=256] [--src=cam720.mjpeg] [--out=camcode720]
 *
 * Bar geometry, read off competitor.mjs's decoder so the two cannot drift:
 *   region x=40 y=24, 11 cells of 96x120, scaled to 11x1 by the decoder
 *   cell 0      sync, must be bright or the sample is rejected
 *   cell 1      source tag  (bit 9)
 *   cells 2..10 frame index (bits 8..0, MSB first)
 */
import { spawn } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import { once } from 'node:events';

const arg = (k, d) => {
  const m = process.argv.find((a) => a.startsWith(`--${k}=`));
  return m ? m.slice(k.length + 3) : d;
};
const HERE = '/Users/deveshpatel/Downloads/video calling/testbed/media';
const FRAMES = Number(arg('frames', 256));
const SRC = arg('src', `${HERE}/cam720.mjpeg`);
const OUT = arg('out', `${HERE}/camcode720`);
const W = 1280, H = 720;
const YSZ = W * H, CSZ = (W / 2) * (H / 2), FSZ = YSZ + 2 * CSZ;

// Even on every edge, so the 4:2:0 chroma region maps without rounding.
const X0 = 40, Y0 = 24, CW = 96, CH = 120, CELLS = 11;
const WHITE = 235, BLACK = 16;

/** Paint the 10-bit bar for `idx` with source tag `src` into an I420 frame. */
function stamp(buf, idx, src) {
  const v = ((src & 1) << 9) | (idx & 511);
  for (let c = 0; c < CELLS; c++) {
    // cell 0 is the sync cell; cell c>=1 carries bit (10 - c) of v.
    const on = c === 0 ? 1 : (v >> (CELLS - 1 - c)) & 1;
    const y = on ? WHITE : BLACK;
    const xs = X0 + c * CW;
    for (let row = Y0; row < Y0 + CH; row++) buf.fill(y, row * W + xs, row * W + xs + CW);
    // Neutral chroma so the cell is pure grey — the decoder averages RGB, and a
    // colour cast would move the luma across the 125 threshold.
    const cxs = xs >> 1, cw = CW >> 1;
    for (let row = Y0 >> 1; row < (Y0 + CH) >> 1; row++) {
      const off = row * (W / 2) + cxs;
      buf.fill(128, YSZ + off, YSZ + off + cw);
      buf.fill(128, YSZ + CSZ + off, YSZ + CSZ + off + cw);
    }
  }
}

// -vsync cfr + fps=30 because the source is 25 fps: without it ffmpeg passes 25
// frames through and the fixture silently runs slow against a 30 fps capture.
const ff = spawn('ffmpeg', ['-v', 'error', '-stream_loop', '-1', '-i', SRC,
  '-vf', `fps=30,scale=${W}:${H}`, '-pix_fmt', 'yuv420p',
  '-frames:v', String(FRAMES), '-f', 'yuv4mpegpipe', '-'], { stdio: ['ignore', 'pipe', 'inherit'] });

const outs = [0, 1].map((s) => createWriteStream(`${OUT}${s ? 'b' : ''}.y4m`));
const HDR = Buffer.from(`YUV4MPEG2 W${W} H${H} F30:1 Ip A1:1 C420\n`);
for (const o of outs) o.write(HDR);

const write = async (o, b) => { if (!o.write(b)) await once(o, 'drain'); };

let pending = Buffer.alloc(0);
let header = false;
let n = 0;
const FRAMETAG = Buffer.from('FRAME\n');

ff.stdout.pause();
for await (const chunk of ff.stdout) {
  pending = pending.length ? Buffer.concat([pending, chunk]) : chunk;
  if (!header) {
    const i = pending.indexOf(0x0a);
    if (i < 0) continue;
    pending = pending.subarray(i + 1);
    header = true;
  }
  // Each record is "FRAME\n" + I420 payload. Fixed size, so no scanning needed
  // beyond confirming the tag is where it should be.
  while (pending.length >= FRAMETAG.length + FSZ) {
    if (!pending.subarray(0, FRAMETAG.length).equals(FRAMETAG)) {
      console.error(`frame ${n}: expected FRAME tag, got ${JSON.stringify(pending.subarray(0, 6).toString('latin1'))}`);
      process.exit(1);
    }
    const body = Buffer.from(pending.subarray(FRAMETAG.length, FRAMETAG.length + FSZ));
    pending = pending.subarray(FRAMETAG.length + FSZ);
    for (let s = 0; s < 2; s++) {
      stamp(body, n, s);          // rewrite the tag cell only; index cells are identical
      await write(outs[s], FRAMETAG);
      await write(outs[s], body);
    }
    n++;
  }
}
for (const o of outs) { o.end(); await once(o, 'finish'); }
console.log(`wrote ${n} frames to ${OUT}.y4m (src=0) and ${OUT}b.y4m (src=1)`);
if (n !== FRAMES) console.log(`WARNING: wanted ${FRAMES} frames, got ${n}`);
