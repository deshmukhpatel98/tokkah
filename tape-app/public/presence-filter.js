/**
 * presence-filter.js — spend bits where the eye can see, before the encoder.
 *
 * THE INVERSION THIS EXISTS FOR. At a fixed quantizer the encoder charges the
 * most for fast motion (nothing predicts well, every block carries residual)
 * and re-charges every frame for sensor grain (temporally random, so motion
 * compensation can never predict it). Human vision does the opposite: detail
 * on a fast-moving object is blurred away in the eye before it reaches the
 * brain, and grain carries no information at any speed. Measured on this
 * project's own fixture (DESIGN.md §17.24 Probe C): the SAME encoder at the
 * SAME quantizer spends 1.74 Mbps on a still noisy scene and 12.00 Mbps on a
 * moving one. Most of that delta is bought detail nobody can see.
 *
 * WHY A PRE-FILTER AND NOT AN ENCODER CHANGE. WebCodecs exposes one quantizer
 * for the whole frame — there is no per-block QP to steer. But steering QP was
 * never the only way to move bits: an encoder spends bits on DETAIL THAT IS
 * THERE. Remove detail the eye cannot resolve before the frame arrives and the
 * same encoder, at the same setting, spends less on it by itself. Nothing to
 * standardise, no decoder change, hardware decode intact on every phone.
 *
 * WHAT IT DOES, in one GPU pass:
 *   · TEMPORAL, where nothing moved — blend with the previous OUTPUT (an IIR).
 *     Grain is random and averages toward zero; static detail is identical
 *     frame to frame and survives untouched. This is the half that is free:
 *     it removes what the sensor invented, not what the camera saw.
 *   · SPATIAL, in proportion to local motion — soften only where the eye is
 *     already blurring. A hand crossing frame at speed cannot be resolved at
 *     1080p by the person watching; the encoder should not be paying 1080p
 *     prices for it.
 *   · PROTECT the face box (when the app supplies one) — the eyes and mouth
 *     are where presence actually lives and where humans hold foveal acuity.
 *     They are excluded from softening at any motion.
 *
 * WHAT IT NEVER DOES: invent. Every pixel out is made of pixels the camera
 * really saw, this frame or the last. There is no model and nothing generated.
 *
 * HONESTY NOTE ON SCORING. VMAF will mark this DOWN, because it compares
 * against an original that contains the grain we removed — faithfully
 * reproducing noise scores well there. That is a property of the ruler, not of
 * the picture (task #1 builds the presence-weighted one). Bitrate at fixed QP
 * is unambiguous and is what this file's rig measures first.
 */

const VERT = `#version 300 es
in vec2 p;
out vec2 uv;
void main() {
  uv = p * 0.5 + 0.5;
  gl_Position = vec4(p, 0.0, 1.0);
}`;

const FRAG = `#version 300 es
precision highp float;
in vec2 uv;
out vec4 outColor;

uniform sampler2D uCur;    // this frame, straight off the camera
uniform sampler2D uPrev;   // our OWN previous output — the IIR's memory.
                           // .rgb = last output, .a = stillness accumulator
uniform vec2  uTexel;      // 1 / resolution
uniform vec4  uFace;       // x, y, w, h in 0..1; w <= 0 means "no face known"
uniform float uHasPrev;
uniform float uDenoise;    // max temporal blend toward uPrev (0..0.85)
uniform float uSoften;     // max spatial blur weight at full motion (0..1)
uniform float uMotionGain; // how fast motion ramps the effects
uniform float uHold;       // strength of the exact-repeat lock (0..1)
uniform float uHoldThresh; // local difference below which a pixel counts as still
uniform float uHoldRate;   // stillness gained per still frame (1/frames to lock)

float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

void main() {
  vec3 cur = texture(uCur, uv).rgb;

  // ── local motion ──────────────────────────────────────────────────────────
  // Measured on a LOCALLY AVERAGED difference, never a single pixel: grain is
  // itself a per-pixel difference, so a naive |cur - prev| reads pure noise as
  // motion, switches the denoiser off exactly where it was needed, and the
  // filter does nothing on the noisiest content — the failure that looks like
  // "the idea does not work".
  float m = 0.0;
  if (uHasPrev > 0.5) {
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        vec2 o = vec2(float(dx), float(dy)) * uTexel * 2.0;
        m += abs(luma(texture(uCur, uv + o).rgb) - luma(texture(uPrev, uv + o).rgb));
      }
    }
    m /= 9.0;
  } else {
    m = 1.0; // no history: treat as full motion, i.e. apply nothing temporal
  }
  float motion = clamp(m * uMotionGain, 0.0, 1.0);

  // ── stillness, carried in the feedback texture's alpha ────────────────────
  // How many consecutive frames this pixel has sat below the hold threshold,
  // normalised to 0..1. Gained slowly, lost INSTANTLY — a lock that releases
  // gradually is a smear, and a smear on a face is the one thing this filter
  // must never produce.
  float prevStill = uHasPrev > 0.5 ? texture(uPrev, uv).a : 0.0;
  float still = (uHasPrev > 0.5 && m < uHoldThresh)
    ? min(1.0, prevStill + uHoldRate)
    : 0.0;

  // ── face protection ───────────────────────────────────────────────────────
  // Distance-based falloff, not a hard rectangle: a step change in sharpness
  // draws a visible box around the head, which is more damaging to presence
  // than the softening it was protecting against.
  float protect = 0.0;
  if (uFace.z > 0.0) {
    vec2 c = uFace.xy + uFace.zw * 0.5;
    vec2 r = uFace.zw * 0.5;
    vec2 d = abs(uv - c) / max(r, vec2(1e-4));
    float t = max(d.x, d.y);            // 0 at centre, 1 at the box edge
    protect = 1.0 - smoothstep(1.0, 1.9, t); // full inside, gone by ~2x the box
  }

  // ── temporal: kill grain where nothing moved ──────────────────────────────
  vec3 prevRgb = uHasPrev > 0.5 ? texture(uPrev, uv).rgb : cur;
  vec3 outc = cur;
  if (uHasPrev > 0.5) {
    // Blend falls to zero as motion rises — an IIR that follows a moving edge
    // is a ghost trailing behind it, and a ghost is worse than grain.
    float a = uDenoise * (1.0 - motion);
    outc = mix(outc, prevRgb, a);
  }

  // ── spatial: soften only what the eye cannot resolve anyway ───────────────
  float blur = uSoften * motion * (1.0 - protect);
  if (blur > 0.001) {
    vec3 s = vec3(0.0);
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        s += texture(uCur, uv + vec2(float(dx), float(dy)) * uTexel).rgb;
      }
    }
    outc = mix(outc, s / 9.0, blur);
  }

  // ── hold: make a still region BIT-IDENTICAL, not merely similar ───────────
  // This is the step change the IIR above cannot reach. An 0.85 blend still
  // leaves 15% of fresh grain in every pixel, so every block of a motionless
  // wall keeps a nonzero residual and the encoder keeps paying for it, frame
  // after frame, for the whole call. Repeat the previous output EXACTLY and
  // that residual is zero — the block codes as skip, which is the cheapest
  // thing a video codec can emit.
  //
  // In a call the camera does not move, so this is most of the picture.
  //
  // Staleness is self-bounding and needs no timer: the difference is measured
  // against the HELD value, so a slow drift (auto-exposure creeping, light)
  // accumulates until it crosses uHoldThresh and releases that pixel on its
  // own. The held image can therefore never be further from the truth than the
  // threshold itself.
  //
  // Deliberately NOT excluded from the face box. Holding does not soften or
  // invent anything — it repeats a pixel the camera really saw ~0.4s ago, and
  // only where nothing has changed since. The instant a lash moves, that pixel
  // is released the same frame.
  float hold = uHold * smoothstep(0.55, 1.0, still);
  outc = mix(outc, prevRgb, hold);

  outColor = vec4(outc, still);
}`;

/**
 * Build the filter. Returns null if WebGL2 is unavailable — the caller then
 * encodes the camera frame unchanged, exactly as before this file existed.
 * The rule this file lives under: a bitrate experiment must never be able to
 * cost the picture (the same rule as the `l2Hw` hint in tape.js).
 */
export function createPresenceFilter(opts = {}) {
  // Live, not frozen at construction: the two halves of this filter (temporal
  // denoise, spatial softening) have very different risk profiles, and the only
  // honest way to learn which one earns the bits is to swap between them INSIDE
  // one call rather than across runs that differ in scene and network.
  // Defaults are the measured operating point (DESIGN.md §17.25), not a guess.
  // SOFTEN DEFAULTS TO ZERO and that is the whole point: it is the only lever
  // here that removes detail the camera really saw, and measured against the
  // other two it was worth 4 percentage points on top of their 61.5% while
  // visibly costing face texture and lettering. A 4% saving is not worth being
  // the reason someone looks less present. It stays available as a knob for a
  // congested link, where a softer picture beats a stalling one.
  let denoise = 0.85, soften = 0, motionGain = 14;
  // hold: 1.0 means a locked pixel is repeated EXACTLY. Anything less than 1
  // leaves a residual and forfeits the skip-block saving entirely, so this is
  // effectively on or off — the knob exists to run the control arm.
  // holdThresh is in luma units on a 3x3-averaged difference; 0.012 is ~3/255,
  // comfortably above sensor grain and below any change a person can see.
  // holdRate 0.07 locks in ~14 frames (~0.45s at 30fps), slow enough that a
  // slow pan is never mistaken for stillness.
  let hold = 1.0, holdThresh = 0.012, holdRate = 0.07;
  // The threshold above is the grain floor of a CLEAN camera in good light. A
  // phone sensor in a dim room is several times noisier, and there the lock
  // would simply never engage — the saving would quietly evaporate on exactly
  // the devices that need it most, while every rig on a bright fixture kept
  // reporting the win. So it adapts UPWARD only, toward whatever this camera's
  // real noise floor turns out to be.
  //
  // Upward only, and capped, on purpose. The held picture can never be further
  // from the truth than the threshold itself, so a small cap IS the safety
  // argument — 0.02 is ~5/255, below the visible step on any display. Adapting
  // downward would need to distinguish "the lock is over-reaching" from "this
  // person is sitting still", which the mean cannot do, and guessing wrong
  // there costs the picture rather than the bitrate.
  const HOLD_THRESH_MAX = 0.02;
  let holdAdapt = opts.holdAdapt !== false;
  const setParams = (o = {}) => {
    if (Number.isFinite(o.denoise)) denoise = Math.min(0.85, Math.max(0, o.denoise));
    if (Number.isFinite(o.soften)) soften = Math.min(1, Math.max(0, o.soften));
    if (Number.isFinite(o.motionGain)) motionGain = Math.min(60, Math.max(1, o.motionGain));
    if (Number.isFinite(o.hold)) hold = Math.min(1, Math.max(0, o.hold));
    if (Number.isFinite(o.holdThresh)) {
      holdThresh = Math.min(0.1, Math.max(0, o.holdThresh));
      holdAdapt = false; // an explicitly set threshold is an instruction, not a hint
    }
    if (Number.isFinite(o.holdRate)) holdRate = Math.min(1, Math.max(0.005, o.holdRate));
    if (typeof o.holdAdapt === 'boolean') holdAdapt = o.holdAdapt;
  };
  setParams(opts);

  let cv = null, gl = null, prog = null, curTex = null, prevTex = null;
  let fboA = null, fboB = null, texA = null, texB = null, useA = true;
  let mipFbo = null, mipLevel = 0, pbo = null, fence = null;
  const px = new Uint8Array(4);
  let w = 0, h = 0, hasPrev = false;
  let face = null; // {x,y,w,h} normalised, or null
  const u = {};
  const stats = { framesIn: 0, framesOut: 0, fallbacks: 0, lastMs: 0, stillMean: 0, holdThresh: 0 };

  // How much of the picture is sitting locked. Without this the hold is an
  // unfalsifiable claim: a bitrate drop alone cannot distinguish "the wall
  // locked and went free" from "the whole filter softened everything".
  //
  // Two tricks keep a diagnostic from costing a frame. The GPU does the
  // reduction — the alpha channel's top mip level is one pixel holding the mean
  // stillness of the whole picture. And the read is ASYNCHRONOUS: a plain
  // readPixels blocks the CPU until the GPU drains, which inside an encode pump
  // is a stall on the one thread that must not stall. Instead the pixel goes to
  // a buffer, a fence is planted, and the result is collected on some later
  // frame when it is already there. A measurement that perturbs the thing it
  // measures is not a measurement.
  function pollStillness() {
    if (!fence) return;
    if (gl.clientWaitSync(fence, 0, 0) === gl.TIMEOUT_EXPIRED) return; // not ready; ask again later
    gl.deleteSync(fence); fence = null;
    gl.bindBuffer(gl.PIXEL_PACK_BUFFER, pbo);
    gl.getBufferSubData(gl.PIXEL_PACK_BUFFER, 0, px);
    gl.bindBuffer(gl.PIXEL_PACK_BUFFER, null);
    stats.stillMean = +(px[3] / 255).toFixed(3);
    // A real call always contains something motionless — a wall, a chair, the
    // top corners of the room. If NOTHING has locked after seconds of trying,
    // the threshold is under this sensor's grain, not the scene's.
    if (holdAdapt && hold > 0 && stats.stillMean < 0.05 && holdThresh < HOLD_THRESH_MAX) {
      holdThresh = Math.min(HOLD_THRESH_MAX, holdThresh * 1.25);
    }
    stats.holdThresh = +holdThresh.toFixed(4);
  }

  function sampleStillness(dstTex) {
    if (fence) return; // one read in flight at a time
    try {
      gl.bindTexture(gl.TEXTURE_2D, dstTex);
      gl.generateMipmap(gl.TEXTURE_2D);
      gl.bindFramebuffer(gl.FRAMEBUFFER, mipFbo);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, dstTex, mipLevel);
      if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE) {
        gl.bindBuffer(gl.PIXEL_PACK_BUFFER, pbo);
        gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, 0); // offset, not array: async
        gl.bindBuffer(gl.PIXEL_PACK_BUFFER, null);
        fence = gl.fenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0);
      }
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    } catch { /* a stat is never worth a dropped frame */ }
  }

  function mkTex(width, height) {
    const t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return t;
  }

  function mkFbo(tex) {
    const f = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, f);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    return f;
  }

  function init(width, height) {
    cv = new OffscreenCanvas(width, height);
    gl = cv.getContext('webgl2', { alpha: false, antialias: false, depth: false,
      premultipliedAlpha: false, preserveDrawingBuffer: false, desynchronized: true });
    if (!gl) return false;

    const sh = (type, src) => {
      const s = gl.createShader(type);
      gl.shaderSource(s, src);
      gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
        throw new Error(`shader: ${gl.getShaderInfoLog(s)}`);
      }
      return s;
    };
    prog = gl.createProgram();
    gl.attachShader(prog, sh(gl.VERTEX_SHADER, VERT));
    gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FRAG));
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
      throw new Error(`link: ${gl.getProgramInfoLog(prog)}`);
    }
    gl.useProgram(prog);

    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, 'p');
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

    for (const n of ['uCur', 'uPrev', 'uTexel', 'uFace', 'uHasPrev', 'uDenoise', 'uSoften',
      'uMotionGain', 'uHold', 'uHoldThresh', 'uHoldRate']) {
      u[n] = gl.getUniformLocation(prog, n);
    }
    curTex = mkTex(width, height);
    texA = mkTex(width, height); texB = mkTex(width, height);
    fboA = mkFbo(texA); fboB = mkFbo(texB);
    mipFbo = gl.createFramebuffer();
    mipLevel = Math.floor(Math.log2(Math.max(width, height)));
    pbo = gl.createBuffer();
    gl.bindBuffer(gl.PIXEL_PACK_BUFFER, pbo);
    gl.bufferData(gl.PIXEL_PACK_BUFFER, 4, gl.STREAM_READ);
    gl.bindBuffer(gl.PIXEL_PACK_BUFFER, null);
    // Any in-flight fence belonged to the context we just replaced and died
    // with it; deleting it through the NEW context would be a cross-context
    // handle, so drop the reference instead.
    fence = null;
    w = width; h = height; hasPrev = false; useA = true;
    return true;
  }

  return {
    /** Face box in NORMALISED coords, or null. Cheap; call as often as you like. */
    setFace(box) {
      face = (box && box.w > 0 && box.h > 0)
        ? { x: box.x, y: box.y, w: box.w, h: box.h } : null;
    },
    setParams,
    params: () => ({ denoise, soften, motionGain, hold, holdThresh, holdRate }),
    stats,
    /**
     * Filter one frame. Returns a NEW VideoFrame the caller owns and must
     * close, or null meaning "use the original" — every failure path returns
     * null rather than throwing, because the lane must outlive this file.
     * The timestamp is carried through EXACTLY: every latency and A/V-sync
     * number downstream is derived from it.
     */
    process(frame) {
      const t0 = performance.now();
      stats.framesIn++;
      try {
        const fw = frame.displayWidth, fh = frame.displayHeight;
        if (!fw || !fh) return null;
        if (!gl || fw !== w || fh !== h) {
          // A resize invalidates the IIR's memory: blending the new frame with
          // a differently-sized past is a smear, not a denoise.
          if (gl) { try { gl.getExtension('WEBGL_lose_context')?.loseContext(); } catch { /* best effort */ } }
          gl = null;
          if (!init(fw, fh)) { stats.fallbacks++; return null; }
        }
        gl.bindTexture(gl.TEXTURE_2D, curTex);
        // FLIP_Y IS LOAD-BEARING, and it is not a detail. WebGL's texture origin
        // is BOTTOM-left; a VideoFrame's first row is its TOP. Uploaded raw, the
        // camera image samples inverted and the peer sees the caller upside
        // down — which the first run of testbed/pfilter.mjs shipped while every
        // number went green (bitrate -16.5%, fps held, latency held), because
        // an inverted frame costs the same bits as an upright one. Flipping HERE
        // rather than in the vertex shader also keeps this texture in the same
        // vertical convention as the feedback textures, which are written by the
        // shader: mismatch them and the temporal blend mixes each frame with a
        // mirror of itself.
        gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, frame);
        gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);

        const dstFbo = useA ? fboA : fboB;
        const prevSrc = useA ? texB : texA;

        gl.bindFramebuffer(gl.FRAMEBUFFER, dstFbo);
        gl.viewport(0, 0, w, h);
        gl.useProgram(prog);
        gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, curTex);
        gl.uniform1i(u.uCur, 0);
        gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, prevSrc);
        gl.uniform1i(u.uPrev, 1);
        gl.uniform2f(u.uTexel, 1 / w, 1 / h);
        gl.uniform4f(u.uFace, face?.x ?? 0, face?.y ?? 0, face?.w ?? 0, face?.h ?? 0);
        gl.uniform1f(u.uHasPrev, hasPrev ? 1 : 0);
        gl.uniform1f(u.uDenoise, denoise);
        gl.uniform1f(u.uSoften, soften);
        gl.uniform1f(u.uMotionGain, motionGain);
        gl.uniform1f(u.uHold, hold);
        gl.uniform1f(u.uHoldThresh, holdThresh);
        gl.uniform1f(u.uHoldRate, holdRate);
        gl.drawArrays(gl.TRIANGLES, 0, 3);

        // Blit the result to the canvas — VideoFrame reads the drawing buffer,
        // not our FBO.
        gl.bindFramebuffer(gl.READ_FRAMEBUFFER, dstFbo);
        gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, null);
        gl.blitFramebuffer(0, 0, w, h, 0, 0, w, h, gl.COLOR_BUFFER_BIT, gl.NEAREST);
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);

        pollStillness();
        if (stats.framesIn % 60 === 0) sampleStillness(useA ? texA : texB);

        useA = !useA;
        hasPrev = true;

        const out = new VideoFrame(cv, {
          timestamp: frame.timestamp,
          duration: frame.duration ?? undefined,
          alpha: 'discard',
        });
        stats.framesOut++;
        stats.lastMs = +(performance.now() - t0).toFixed(2);
        return out;
      } catch {
        stats.fallbacks++;
        hasPrev = false;
        return null; // caller encodes the camera frame, unchanged
      }
    },
    close() {
      try { if (fence) gl?.deleteSync(fence); } catch { /* best effort */ }
      fence = null;
      try { gl?.getExtension('WEBGL_lose_context')?.loseContext(); } catch { /* best effort */ }
      gl = null; cv = null; hasPrev = false;
    },
  };
}
