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
uniform sampler2D uPrev;   // our OWN previous output — the IIR's memory
uniform vec2  uTexel;      // 1 / resolution
uniform vec4  uFace;       // x, y, w, h in 0..1; w <= 0 means "no face known"
uniform float uHasPrev;
uniform float uDenoise;    // max temporal blend toward uPrev (0..0.85)
uniform float uSoften;     // max spatial blur weight at full motion (0..1)
uniform float uMotionGain; // how fast motion ramps the effects

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
  vec3 outc = cur;
  if (uHasPrev > 0.5) {
    vec3 prev = texture(uPrev, uv).rgb;
    // Blend falls to zero as motion rises — an IIR that follows a moving edge
    // is a ghost trailing behind it, and a ghost is worse than grain.
    float a = uDenoise * (1.0 - motion);
    outc = mix(outc, prev, a);
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

  outColor = vec4(outc, 1.0);
}`;

/**
 * Build the filter. Returns null if WebGL2 is unavailable — the caller then
 * encodes the camera frame unchanged, exactly as before this file existed.
 * The rule this file lives under: a bitrate experiment must never be able to
 * cost the picture (the same rule as the `l2Hw` hint in tape.js).
 */
export function createPresenceFilter(opts = {}) {
  const denoise = Math.min(0.85, Math.max(0, opts.denoise ?? 0.6));
  const soften = Math.min(1, Math.max(0, opts.soften ?? 0.7));
  const motionGain = opts.motionGain ?? 14;

  let cv = null, gl = null, prog = null, curTex = null, prevTex = null;
  let fboA = null, fboB = null, texA = null, texB = null, useA = true;
  let w = 0, h = 0, hasPrev = false;
  let face = null; // {x,y,w,h} normalised, or null
  const u = {};
  const stats = { framesIn: 0, framesOut: 0, fallbacks: 0, lastMs: 0 };

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

    for (const n of ['uCur', 'uPrev', 'uTexel', 'uFace', 'uHasPrev', 'uDenoise', 'uSoften', 'uMotionGain']) {
      u[n] = gl.getUniformLocation(prog, n);
    }
    curTex = mkTex(width, height);
    texA = mkTex(width, height); texB = mkTex(width, height);
    fboA = mkFbo(texA); fboB = mkFbo(texB);
    w = width; h = height; hasPrev = false; useA = true;
    return true;
  }

  return {
    /** Face box in NORMALISED coords, or null. Cheap; call as often as you like. */
    setFace(box) {
      face = (box && box.w > 0 && box.h > 0)
        ? { x: box.x, y: box.y, w: box.w, h: box.h } : null;
    },
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
        gl.drawArrays(gl.TRIANGLES, 0, 3);

        // Blit the result to the canvas — VideoFrame reads the drawing buffer,
        // not our FBO.
        gl.bindFramebuffer(gl.READ_FRAMEBUFFER, dstFbo);
        gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, null);
        gl.blitFramebuffer(0, 0, w, h, 0, 0, w, h, gl.COLOR_BUFFER_BIT, gl.NEAREST);
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);

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
      try { gl?.getExtension('WEBGL_lose_context')?.loseContext(); } catch { /* best effort */ }
      gl = null; cv = null; hasPrev = false;
    },
  };
}
