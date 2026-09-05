/**
 * Kin — the animated film.
 * Sections §4, §5, §6, §7, §9 of ad/BRIEF.md.
 * Pure function of time: render(t), deterministic, seekable, 60fps.
 */

(function() {
  "use strict";

  // --- Configuration & Constants ---
  const DURATION = 75.0;
  const STAGE_WIDTH = 1920;
  const STAGE_HEIGHT = 1080;

  // City Coordinates for Act III (§5 S11 & S12)
  const CITIES = {
    delhi: { name: "DELHI", lat: 28.6139, lon: 77.2090 },
    amsterdam: { name: "AMSTERDAM", lat: 52.3676, lon: 4.9041 },
    world: [
      { name: "TOKYO", lat: 35.6762, lon: 139.6503 },
      { name: "SYDNEY", lat: -33.8688, lon: 151.2093 },
      { name: "SÃO PAULO", lat: -23.5505, lon: -46.6333 },
      { name: "LAGOS", lat: 6.5244, lon: 3.3792 },
      { name: "NAIROBI", lat: -1.2921, lon: 36.8219 },
      { name: "LONDON", lat: 51.5074, lon: -0.1278 },
      { name: "NEW YORK", lat: 40.7128, lon: -74.0060 },
      { name: "SAN FRANCISCO", lat: 37.7749, lon: -122.4194 },
      { name: "SEATTLE", lat: 47.6062, lon: -122.3321 },
      { name: "TORONTO", lat: 43.6532, lon: -79.3832 },
      { name: "MEXICO CITY", lat: 19.4326, lon: -99.1332 },
      { name: "BUENOS AIRES", lat: -34.6037, lon: -58.3816 },
      { name: "CAPE TOWN", lat: -33.9249, lon: 18.4241 },
      { name: "CAIRO", lat: 30.0444, lon: 31.2357 },
      { name: "DUBAI", lat: 25.2048, lon: 55.2708 },
      { name: "MUMBAI", lat: 19.0760, lon: 72.8777 },
      { name: "SINGAPORE", lat: 1.3521, lon: 103.8198 },
      { name: "JAKARTA", lat: -6.2088, lon: 106.8456 },
      { name: "SEOUL", lat: 37.5665, lon: 126.9780 },
      { name: "BERLIN", lat: 52.5200, lon: 13.4050 }
    ]
  };

  // Full Verbatim Transcript from §5
  const TRANSCRIPT = [
    { t: 0.8, text: "Every call has a gap in it." },
    { t: 3.9, text: "You finish a sentence. Then you wait." },
    { t: 7.0, text: "Then you both talk at once." },
    { t: 9.3, text: "When the line gets thin, the call spends your face." },
    { t: 11.5, text: "And invents your voice." },
    { t: 13.2, text: "It doesn't have to." },
    { t: 17.5, text: "Call a person. Not a room." },
    { t: 23.4, text: "No link. No account. No waiting room." },
    { t: 26.6, text: "Just them. No mirror. No buttons." },
    { t: 29.6, text: "Green means they can hear you." },
    { t: 33.3, text: "Blue while you listen." },
    { t: 35.6, text: "One voice at a time. The way a room works." },
    { t: 38.4, text: "The voice is the recording." },
    { t: 40.6, text: "The picture is the camera's own." },
    { t: 42.8, text: "Nothing in between is allowed to touch either." },
    { t: 45.5, text: "Between two people, one delay is real." },
    { t: 48.5, text: "The time light needs to cross the distance." },
    { t: 50.5, text: "Everything else is a defect." },
    { t: 52.4, text: "Our goal: under 150 milliseconds. Anywhere on Earth." },
    { t: 55.5, text: "Lossless sound. A visually lossless picture. Measured on live calls, every release." },
    { t: 58.3, text: "Every video call in the world still runs on a 2011 design that spends your face when the network dips." },
    { t: 61.0, text: "We rebuilt the call from the microphone up. It's shipping." },
    { t: 65.2, text: "As close as light allows." },
    { t: 68.0, text: "Free on Mac today." },
    { t: 68.0, text: "kin.tokkah.com" },
    { t: 68.0, text: "Not on a Mac yet? Leave your name — you'll be first." }
  ];

  // Copy Display Segments (§4 & §5)
  const COPY_SEGMENTS = [
    { start: 0.8, end: 3.2, pos: "center", size: 64, text: "Every call has a gap in it." },
    { start: 3.9, end: 6.4, pos: "center", size: 64, text: "You finish a sentence. Then you wait." },
    { start: 7.0, end: 8.8, pos: "center", size: 64, text: "Then you both talk at once." },
    { start: 9.3, end: 11.0, pos: "center", size: 64, text: "When the line gets thin, the call spends your face." },
    { start: 11.5, end: 12.8, pos: "center", size: 64, text: "And invents your voice." },
    { start: 13.2, end: 14.8, pos: "center", size: 72, text: "It doesn't have to." },
    { start: 17.5, end: 22.4, pos: "side", size: 56, text: "Call a person. Not a room." },
    { start: 23.4, end: 25.8, pos: "side", size: 56, text: "No link. No account. No waiting room." },
    { start: 26.6, end: 29.0, pos: "side", size: 56, text: "Just them. No mirror. No buttons." },
    { start: 29.6, end: 32.5, pos: "side", size: 56, text: "Green means they can hear you." },
    { start: 33.3, end: 35.1, pos: "side", size: 56, text: "Blue while you listen." },
    { start: 35.6, end: 37.8, pos: "center", size: 56, text: "One voice at a time. The way a room works." },
    { start: 38.4, end: 40.1, pos: "center", size: 64, text: "The voice is the recording." },
    { start: 40.6, end: 42.3, pos: "center", size: 64, text: "The picture is the camera's own." },
    { start: 42.8, end: 44.5, pos: "center", size: 64, text: "Nothing in between is allowed to touch either." },
    { start: 45.5, end: 48.0, pos: "center", size: 64, text: "Between two people, one delay is real." },
    { start: 48.5, end: 50.1, pos: "center", size: 64, text: "The time light needs to cross the distance." },
    { start: 50.5, end: 51.9, pos: "center", size: 64, text: "Everything else is a defect." },
    { start: 52.4, end: 54.9, pos: "center", size: 64, text: "Our goal: under 150 milliseconds. Anywhere on Earth." },
    { start: 55.5, end: 57.8, pos: "center", size: 48, text: "Lossless sound. A visually lossless picture. Measured on live calls, every release." },
    { start: 58.3, end: 60.5, pos: "center", size: 48, color: "#9aa3b2", text: "Every video call in the world still runs on a 2011 design that spends your face when the network dips." },
    { start: 61.0, end: 62.7, pos: "center", size: 64, color: "#f3f1ec", text: "We rebuilt the call from the microphone up. It's shipping." }
  ];

  // Pre-authored syllables for voice envelopes (§4 & §5)
  const SYLLABLES_S8 = [29.05, 29.35, 29.70, 30.05, 30.40, 30.75, 31.10, 31.40];
  const SYLLABLES_S9 = [33.25, 33.60, 33.95, 34.30, 34.65, 35.00];
  const SYLLABLES_H1 = [35.85, 36.15, 36.45];
  const SYLLABLES_H2 = [37.05, 37.35, 37.65];

  // --- Seeded PRNG (Mulberry32) ---
  function mulberry32(a) {
    return function() {
      let t = a += 0x6D2B79F5;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  function clamp(v, min, max) {
    return v < min ? min : (v > max ? max : v);
  }

  // Exact cubic-bezier(.2, .7, .2, 1) solver (§4)
  function solveCubicBezier(p1x, p1y, p2x, p2y) {
    const cx = 3 * p1x;
    const bx = 3 * (p2x - p1x) - cx;
    const ax = 1 - cx - bx;
    const cy = 3 * p1y;
    const by = 3 * (p2y - p1y) - cy;
    const ay = 1 - cy - by;

    function sampleCurveX(t) { return ((ax * t + bx) * t + cx) * t; }
    function sampleCurveY(t) { return ((ay * t + by) * t + cy) * t; }
    function sampleDerivativeX(t) { return (3 * ax * t + 2 * bx) * t + cx; }

    return function(x) {
      if (x <= 0) return 0;
      if (x >= 1) return 1;
      let t = x;
      for (let i = 0; i < 8; i++) {
        const xEst = sampleCurveX(t) - x;
        if (Math.abs(xEst) < 1e-5) return sampleCurveY(t);
        const d = sampleDerivativeX(t);
        if (Math.abs(d) < 1e-5) break;
        t -= xEst / d;
      }
      return sampleCurveY(clamp(t, 0, 1));
    };
  }

  const easeEntrance = solveCubicBezier(0.2, 0.7, 0.2, 1.0);
  const easeSine = u => 0.5 - 0.5 * Math.cos(Math.PI * u);
  const easeLinear = u => u;

  // Keyframe Interpolation Helper (§7: kf(t, [[t0,v0],[t1,v1],...], ease))
  function kf(t, points, ease = easeLinear) {
    if (!points || points.length === 0) return 0;
    if (t <= points[0][0]) return points[0][1];
    if (t >= points[points.length - 1][0]) return points[points.length - 1][1];

    for (let i = 0; i < points.length - 1; i++) {
      const t0 = points[i][0];
      const t1 = points[i + 1][0];
      if (t >= t0 && t <= t1) {
        const span = t1 - t0;
        const u = span === 0 ? 0 : (t - t0) / span;
        const e = ease(u);
        return points[i][1] + (points[i + 1][1] - points[i][1]) * e;
      }
    }
    return points[points.length - 1][1];
  }

  function kfColor(t, points, ease = easeLinear) {
    if (t <= points[0][0]) return points[0][1];
    if (t >= points[points.length - 1][0]) return points[points.length - 1][1];

    for (let i = 0; i < points.length - 1; i++) {
      const t0 = points[i][0];
      const t1 = points[i + 1][0];
      if (t >= t0 && t <= t1) {
        const span = t1 - t0;
        const u = span === 0 ? 0 : (t - t0) / span;
        const e = ease(u);
        const c0 = points[i][1];
        const c1 = points[i + 1][1];
        return [
          Math.round(c0[0] + (c1[0] - c0[0]) * e),
          Math.round(c0[1] + (c1[1] - c0[1]) * e),
          Math.round(c0[2] + (c1[2] - c0[2]) * e)
        ];
      }
    }
    return points[points.length - 1][1];
  }

  // --- Voice Envelope Math (§4 & §5) ---
  // attack 90ms, release 260ms
  function evalVoiceEnvelope(t, syllables) {
    let env = 0;
    for (let i = 0; i < syllables.length; i++) {
      const t0 = syllables[i];
      if (t >= t0 && t < t0 + 0.9) {
        const dt = t - t0;
        let val = 0;
        if (dt < 0.09) {
          val = dt / 0.09;
        } else {
          val = Math.exp(-(dt - 0.09) / 0.26);
        }
        if (val > env) env = val;
      }
    }
    return env;
  }

  // thickness envelope: 450ms attack, 1200ms release
  function evalThicknessEnvelope(t, syllables) {
    let env = 0;
    for (let i = 0; i < syllables.length; i++) {
      const t0 = syllables[i];
      if (t >= t0 && t < t0 + 2.5) {
        const dt = t - t0;
        let val = 0;
        if (dt < 0.45) {
          val = dt / 0.45;
        } else {
          val = Math.exp(-(dt - 0.45) / 1.2);
        }
        if (val > env) env = val;
      }
    }
    return env;
  }

  // --- Cached DOM Elements ---
  const el = {};
  function cacheElements() {
    el.stageContainer = document.getElementById("stage-container");
    el.stage = document.getElementById("stage");
    el.canvasRipples = document.getElementById("canvas-ripples");
    el.ctxRipples = el.canvasRipples.getContext("2d");
    el.canvasGlobe = document.getElementById("canvas-globe");
    el.ctxGlobe = el.canvasGlobe.getContext("2d");
    el.canvasGrain = document.getElementById("canvas-grain");
    el.ctxGrain = el.canvasGrain.getContext("2d");

    el.act2Container = document.getElementById("act2-container");
    el.kinCornerWordmark = document.getElementById("kin-corner-wordmark");
    el.macWindowLeft = document.getElementById("mac-window-left");
    el.macWindowRight = document.getElementById("mac-window-right");
    el.bokehPreviewLeft = document.getElementById("bokeh-preview-left");
    el.glassCard = document.getElementById("glass-card");
    el.inputText = document.getElementById("input-text");
    el.inputCursor = document.getElementById("input-cursor");
    el.rowMeera = document.getElementById("row-meera");
    el.rowArjun = document.getElementById("row-arjun");
    el.rowDad = document.getElementById("row-dad");
    el.glassPill = document.getElementById("glass-pill");
    el.pillText = document.getElementById("pill-text");
    el.portraitLeft = document.getElementById("portrait-left");
    el.portraitRight = document.getElementById("portrait-right");
    el.edgeBandLeft = document.getElementById("edge-band-left");
    el.edgeBandRight = document.getElementById("edge-band-right");

    el.copyCenter = document.getElementById("copy-center");
    el.copySide = document.getElementById("copy-side");
    el.act4Container = document.getElementById("act4-container");
    el.act4Group = document.getElementById("act4-group");
    el.act4Wordmark = document.getElementById("act4-wordmark");
    el.act4Tagline = document.getElementById("act4-tagline");
    el.act4Cta = document.getElementById("act4-cta");

    el.playerControls = document.getElementById("player-controls");
    el.restDimOverlay = document.getElementById("rest-dim-overlay");
    el.playButtonOverlay = document.getElementById("play-button-overlay");
    el.progressHairline = document.getElementById("progress-hairline");
    el.progressFill = document.getElementById("progress-fill");
    el.muteToggle = document.getElementById("mute-toggle");
    el.volumeWaves = document.getElementById("volume-waves");
    el.replayButton = document.getElementById("replay-button");
  }

  // --- Pre-render Templates: Bokeh Discs & Soft Portraits ---
  function createPortraitCanvas(isWarm) {
    const canvasA = document.createElement("canvas");
    canvasA.width = 1280;
    canvasA.height = 800;
    const ctxA = canvasA.getContext("2d");

    const canvasB = document.createElement("canvas");
    canvasB.width = 1280;
    canvasB.height = 800;
    const ctxB = canvasB.getContext("2d");

    if (isWarm) {
      // Ground: vertical gradient warm dark #2a1f1a (top) -> #120d0b (bottom)
      const groundGrad = ctxA.createLinearGradient(0, 0, 0, 800);
      groundGrad.addColorStop(0, "#2a1f1a");
      groundGrad.addColorStop(1, "#120d0b");
      ctxA.fillStyle = groundGrad;
      ctxA.fillRect(0, 0, 1280, 800);

      // Soft window-light patch top-left (radial, cream at 12% alpha, radius 500px)
      const lightGrad = ctxA.createRadialGradient(0, 0, 0, 0, 0, 500);
      lightGrad.addColorStop(0, "rgba(243, 241, 236, 0.12)");
      lightGrad.addColorStop(1, "rgba(243, 241, 236, 0)");
      ctxA.fillStyle = lightGrad;
      ctxA.fillRect(0, 0, 1280, 800);

      // Shoulders/torso: ellipse centered (640, 980), radii (520, 360), fill #3a2a24
      ctxA.beginPath();
      ctxA.ellipse(640, 980, 520, 360, 0, 0, Math.PI * 2);
      ctxA.fillStyle = "#3a2a24";
      ctxA.fill();

      // Neck: ellipse (640, 620), radii (80, 110), fill #8a5a45
      ctxA.beginPath();
      ctxA.ellipse(640, 620, 80, 110, 0, 0, Math.PI * 2);
      ctxA.fillStyle = "#8a5a45";
      ctxA.fill();

      // Head: ellipse (640, 430), radii (150, 195), filled with radial gradient centered at (560, 400):
      // #d9a688 at left/near side -> #b7846a mid -> #6b4032 at right edge
      const headGrad = ctxA.createRadialGradient(560, 400, 0, 560, 400, 240);
      headGrad.addColorStop(0, "#d9a688");
      headGrad.addColorStop(0.5, "#b7846a");
      headGrad.addColorStop(1, "#6b4032");
      ctxA.beginPath();
      ctxA.ellipse(640, 430, 150, 195, 0, 0, Math.PI * 2);
      ctxA.fillStyle = headGrad;
      ctxA.fill();

      // Hair: ellipse (640, 350), radii (170, 150), fill #2b1a14 at 92%
      ctxA.beginPath();
      ctxA.ellipse(640, 350, 170, 150, 0, 0, Math.PI * 2);
      ctxA.fillStyle = "rgba(43, 26, 20, 0.92)";
      ctxA.fill();

      // Two hanging strands: ellipses (505, 530) and (775, 530), radii (58, 185), same fill at 85%
      ctxA.beginPath();
      ctxA.ellipse(505, 530, 58, 185, 0, 0, Math.PI * 2);
      ctxA.ellipse(775, 530, 58, 185, 0, 0, Math.PI * 2);
      ctxA.fillStyle = "rgba(43, 26, 20, 0.85)";
      ctxA.fill();

      // Rim light: crescent along head left edge clipped to left 25% (490 to 565), smoothly faded
      ctxA.save();
      ctxA.beginPath();
      ctxA.rect(0, 0, 565, 800);
      ctxA.clip();
      ctxA.beginPath();
      ctxA.ellipse(640, 430, 150, 195, 0, 0, Math.PI * 2);
      const rimGradW = ctxA.createLinearGradient(490, 0, 565, 0);
      rimGradW.addColorStop(0, "rgba(243, 241, 236, 0.22)");
      rimGradW.addColorStop(0.6, "rgba(243, 241, 236, 0.12)");
      rimGradW.addColorStop(1, "rgba(243, 241, 236, 0)");
      ctxA.fillStyle = rimGradW;
      ctxA.fill();
      ctxA.restore();

    } else {
      // Cool lighting ("You", S9 right window)
      // Ground: #0f1520 -> #090c12
      const groundGrad = ctxA.createLinearGradient(0, 0, 0, 800);
      groundGrad.addColorStop(0, "#0f1520");
      groundGrad.addColorStop(1, "#090c12");
      ctxA.fillStyle = groundGrad;
      ctxA.fillRect(0, 0, 1280, 800);

      // Light patch blue #60a5fa at 10%
      const lightGrad = ctxA.createRadialGradient(0, 0, 0, 0, 0, 500);
      lightGrad.addColorStop(0, "rgba(96, 165, 250, 0.10)");
      lightGrad.addColorStop(1, "rgba(96, 165, 250, 0)");
      ctxA.fillStyle = lightGrad;
      ctxA.fillRect(0, 0, 1280, 800);

      // Shoulders/torso: ellipse centered (640, 980), radii (520, 360), fill #1a2130
      ctxA.beginPath();
      ctxA.ellipse(640, 980, 520, 360, 0, 0, Math.PI * 2);
      ctxA.fillStyle = "#1a2130";
      ctxA.fill();

      // Neck: ellipse (640, 620), radii (80, 110), cool tone #232f42
      ctxA.beginPath();
      ctxA.ellipse(640, 620, 80, 110, 0, 0, Math.PI * 2);
      ctxA.fillStyle = "#3a3038";
      ctxA.fill();

      // Head: radii (158, 185), head gradient #9fb0c8 -> #6f7d94 (warmed toward #a99c94) -> #2e3646 (radial centered at 560, 400)
      const headGrad = ctxA.createRadialGradient(560, 400, 0, 560, 400, 245);
      headGrad.addColorStop(0, "#c4b2a6");
      headGrad.addColorStop(0.5, "#7d6f74"); // warm-neutral skin in cool light, never grey-blue (read as bone)
      headGrad.addColorStop(1, "#2e3646");
      ctxA.beginPath();
      ctxA.ellipse(640, 430, 158, 185, 0, 0, Math.PI * 2);
      ctxA.fillStyle = headGrad;
      ctxA.fill();

      // Hair: ellipse (640, 350), radii (180, 140), fill #141a26 at 92%, no hanging strands
      ctxA.beginPath();
      ctxA.ellipse(640, 350, 180, 140, 0, 0, Math.PI * 2);
      ctxA.fillStyle = "rgba(20, 26, 38, 0.92)";
      ctxA.fill();

      // Rim light: blue-white clipped to left 25% (482 to 561), softer (14% instead of 22%)
      ctxA.save();
      ctxA.beginPath();
      ctxA.rect(0, 0, 561, 800);
      ctxA.clip();
      ctxA.beginPath();
      ctxA.ellipse(640, 430, 158, 185, 0, 0, Math.PI * 2);
      const rimGradC = ctxA.createLinearGradient(482, 0, 561, 0);
      rimGradC.addColorStop(0, "rgba(215, 232, 255, 0.14)");
      rimGradC.addColorStop(0.6, "rgba(215, 232, 255, 0.08)");
      rimGradC.addColorStop(1, "rgba(215, 232, 255, 0)");
      ctxA.fillStyle = rimGradC;
      ctxA.fill();
      ctxA.restore();
    }

    // Blur the WHOLE drawing once: draw canvas A into canvas B with ctx.filter = 'blur(24px)'
    ctxB.filter = "blur(24px)";
    ctxB.drawImage(canvasA, 0, 0);
    ctxB.filter = "none";

    return canvasB;
  }

  function setupDomTemplates() {
    // 5 Bokeh discs inside preview (pre-rendered radial gradients, never blurred per frame)
    const bokehColors = [
      "radial-gradient(circle, rgba(243,241,236,0.32) 0%, rgba(243,241,236,0) 70%)",
      "radial-gradient(circle, rgba(234,179,8,0.28) 0%, rgba(234,179,8,0) 70%)",
      "radial-gradient(circle, rgba(243,241,236,0.25) 0%, rgba(243,241,236,0) 70%)",
      "radial-gradient(circle, rgba(217,119,6,0.26) 0%, rgba(217,119,6,0) 70%)",
      "radial-gradient(circle, rgba(243,241,236,0.2) 0%, rgba(243,241,236,0) 70%)"
    ];
    el.bokehDiscs = [];
    for (let i = 0; i < 5; i++) {
      const disc = document.createElement("div");
      disc.className = "bokeh-disc";
      disc.style.background = bokehColors[i];
      el.bokehPreviewLeft.appendChild(disc);
      el.bokehDiscs.push(disc);
    }

    // Pre-rendered offscreen portraits drawn ONCE and composited with transforms/opacity only
    const warmPortraitCanvas = createPortraitCanvas(true);
    warmPortraitCanvas.style.position = "absolute";
    warmPortraitCanvas.style.left = "0";
    warmPortraitCanvas.style.top = "0";
    warmPortraitCanvas.style.width = "100%";
    warmPortraitCanvas.style.height = "100%";

    el.portraitLeft.innerHTML = `
      <div id="portrait-left-inner" style="position:absolute; inset:0; width:100%; height:100%; transform-origin:640px 430px; pointer-events:none;">
        <div id="portrait-left-overlay" style="position:absolute; inset:0; background:#f3f1ec; opacity:0; pointer-events:none; z-index:2;"></div>
      </div>
    `;
    el.portraitLeftInner = document.getElementById("portrait-left-inner");
    el.portraitLeftOverlay = document.getElementById("portrait-left-overlay");
    el.portraitLeftInner.insertBefore(warmPortraitCanvas, el.portraitLeftOverlay);

    const coolPortraitCanvas = createPortraitCanvas(false);
    coolPortraitCanvas.style.position = "absolute";
    coolPortraitCanvas.style.left = "0";
    coolPortraitCanvas.style.top = "0";
    coolPortraitCanvas.style.width = "100%";
    coolPortraitCanvas.style.height = "100%";

    el.portraitRight.innerHTML = `
      <div id="portrait-right-inner" style="position:absolute; inset:0; width:100%; height:100%; transform-origin:640px 430px; pointer-events:none;"></div>
    `;
    el.portraitRightInner = document.getElementById("portrait-right-inner");
    el.portraitRightInner.appendChild(coolPortraitCanvas);
  }

  // --- Viewport Resize Handler ---
  function updateStageScale() {
    if (!el.stage) return;
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const scale = Math.min(vw / STAGE_WIDTH, vh / STAGE_HEIGHT);
    el.stage.style.transform = `translate(-50%, -50%) scale(${scale})`;
    el.stage.style.left = "50%";
    el.stage.style.top = "50%";
  }

  window.addEventListener("resize", updateStageScale);

  // --- Seeded Particles (S2 Collision Shatter at 7.4s) ---
  const NUM_PARTICLES = 90;
  const PARTICLES = [];
  const rngPart = mulberry32(888123);
  for (let i = 0; i < NUM_PARTICLES; i++) {
    const angle = rngPart() * Math.PI * 2;
    const speed = 120 + rngPart() * 320;
    const size = 1.5 + rngPart() * 3.5;
    const isCream = rngPart() > 0.45;
    PARTICLES.push({ angle, speed, size, isCream });
  }

  // --- Deterministic WebAudio Synthesizer (§6) ---
  // Tuned by measurement (ffmpeg ebur128 on ad/out/score.wav): integrated -18 LUFS,
  // true peak <= -3 dBFS, loudness range <= 14 LU, pad audible from 3 s.
  const SCORE_PRE_GAIN = 3.0;
  const SCORE_CEILING = 0.70;
  function buildScoreGraph(ctx, startOffset = 0, isOffline = false) {
    const T = t => startOffset + t;

    // Master DynamicsCompressor (§6: -12dB threshold, ratio 3, attack 5ms, release 250ms)
    const comp = ctx.createDynamicsCompressor();
    comp.threshold.setValueAtTime(-12, startOffset);
    comp.ratio.setValueAtTime(3, startOffset);
    comp.attack.setValueAtTime(0.005, startOffset);
    comp.release.setValueAtTime(0.25, startOffset);

    // Loudness stage. The compressor alone let both bell chords through at
    // full scale (measured: S4 chord -1.3 dBFS, reveal chord clipping at 0.0),
    // so the chain is now comp -> preGain -> soft limiter -> masterGain.
    // The limiter is a WaveShaper: linear below 0.6, tanh above, ceiling 1.0 --
    // so the output can never exceed masterGain, whatever the mix does.
    const preGain = ctx.createGain();
    preGain.gain.setValueAtTime(SCORE_PRE_GAIN, startOffset);
    const limiter = ctx.createWaveShaper();
    {
      const N = 8192, curve = new Float32Array(N), knee = 0.6;
      for (let i = 0; i < N; i++) {
        const x = (i / (N - 1)) * 2 - 1, a = Math.abs(x);
        const y = a <= knee ? a : knee + (1 - knee) * Math.tanh((a - knee) / (1 - knee));
        curve[i] = Math.sign(x) * y;
      }
      limiter.curve = curve;
      limiter.oversample = "4x";
    }
    const masterGain = ctx.createGain();
    masterGain.gain.setValueAtTime(SCORE_CEILING, startOffset); // -3 dBFS ceiling
    comp.connect(preGain);
    preGain.connect(limiter);
    limiter.connect(masterGain);
    masterGain.connect(ctx.destination);

    // Reverb Convolver (impulse is generated noise with 2.5s exponential decay)
    const convLen = Math.floor(ctx.sampleRate * 2.5);
    const convBuffer = ctx.createBuffer(2, convLen, ctx.sampleRate);
    for (let ch = 0; ch < 2; ch++) {
      const data = convBuffer.getChannelData(ch);
      const prng = mulberry32(54321 + ch * 77);
      for (let i = 0; i < convLen; i++) {
        const t = i / ctx.sampleRate;
        data[i] = (prng() * 2 - 1) * Math.exp(-t / 0.6);
      }
    }
    const convolver = ctx.createConvolver();
    convolver.buffer = convBuffer;
    const reverbGain = ctx.createGain();
    reverbGain.gain.setValueAtTime(0.32, startOffset);
    convolver.connect(reverbGain);
    reverbGain.connect(comp);

    // Feedback Delay (375ms, 0.35 feedback, 2000Hz lowpass)
    const delay = ctx.createDelay(1.0);
    delay.delayTime.setValueAtTime(0.375, startOffset);
    const delayFb = ctx.createGain();
    delayFb.gain.setValueAtTime(0.35, startOffset);
    const delayFilter = ctx.createBiquadFilter();
    delayFilter.type = "lowpass";
    delayFilter.frequency.setValueAtTime(2000, startOffset);

    delay.connect(delayFilter);
    delayFilter.connect(delayFb);
    delayFb.connect(delay);

    const delayOut = ctx.createGain();
    delayOut.gain.setValueAtTime(0.40, startOffset);
    delayFilter.connect(delayOut);
    delayOut.connect(comp);
    delayOut.connect(convolver);

    // Shared Deterministic Noise Buffer
    const noiseLen = Math.floor(ctx.sampleRate * 8.0);
    const noiseBuffer = ctx.createBuffer(1, noiseLen, ctx.sampleRate);
    const nData = noiseBuffer.getChannelData(0);
    const nRng = mulberry32(991122);
    for (let i = 0; i < noiseLen; i++) {
      nData[i] = nRng() * 2 - 1;
    }

    // --- 1. Pad: D drone (D2 73.4Hz + D3 146.8Hz ±3 cents, D4 triangle at -12dB) ---
    const padFilter = ctx.createBiquadFilter();
    padFilter.type = "lowpass";
    padFilter.frequency.setValueAtTime(900, T(0));
    padFilter.frequency.setValueAtTime(900, T(3.5));
    padFilter.frequency.linearRampToValueAtTime(400, T(13.0));
    padFilter.frequency.setValueAtTime(2000, T(13.0));
    padFilter.frequency.setValueAtTime(2000, T(63.0));
    padFilter.frequency.linearRampToValueAtTime(1000, T(73.5));

    const padGain = ctx.createGain();
    padGain.gain.setValueAtTime(0.0001, T(0));
    padGain.gain.linearRampToValueAtTime(0.0501, T(3.0)); // -26 dBFS
    padGain.gain.setValueAtTime(0.0501, T(73.5));
    padGain.gain.linearRampToValueAtTime(0.0001, T(75.0));

    padFilter.connect(padGain);
    padGain.connect(comp);

    const padNotes = [
      { f: 73.416, type: "sine", detune: 3, g: 0.5 },
      { f: 73.416, type: "sine", detune: -3, g: 0.5 },
      { f: 146.832, type: "sine", detune: 3, g: 0.4 },
      { f: 146.832, type: "sine", detune: -3, g: 0.4 },
      { f: 293.665, type: "triangle", detune: 0, g: 0.25 } // D4 at -12 dB
    ];

    padNotes.forEach(p => {
      const osc = ctx.createOscillator();
      osc.type = p.type;
      osc.frequency.setValueAtTime(p.f, T(0));
      osc.detune.setValueAtTime(p.detune, T(0));
      const g = ctx.createGain();
      g.gain.setValueAtTime(p.g, T(0));
      osc.connect(g);
      g.connect(padFilter);
      osc.start(T(0));
      osc.stop(T(75.0));
    });

    // Helper: Bell Note with 2nd and 3rd Partials (-10/-16 dB)
    function playBellChord(chordTime, freqs, duration = 3.0, scaleGain = 1.0) {
      freqs.forEach(freq => {
        const partials = [
          { mult: 1, gain: 0.4 * scaleGain },
          { mult: 2, gain: 0.4 * 0.316 * scaleGain },  // -10 dB
          { mult: 3, gain: 0.4 * 0.158 * scaleGain }   // -16 dB
        ];
        partials.forEach(pt => {
          const osc = ctx.createOscillator();
          osc.type = "sine";
          osc.frequency.setValueAtTime(freq * pt.mult, T(chordTime));
          const g = ctx.createGain();
          g.gain.setValueAtTime(pt.gain, T(chordTime));
          g.gain.exponentialRampToValueAtTime(0.0001, T(chordTime + duration));
          osc.connect(g);
          g.connect(comp);
          g.connect(delay);
          g.connect(convolver);
          osc.start(T(chordTime));
          osc.stop(T(chordTime + duration + 0.05));
        });
      });
    }

    // --- 2. S2 Ripples Whooshes (bandpass 400-1200Hz) & Collision Cluster ---
    const whooshTimes = [3.90, 4.25, 4.60, 6.00, 6.35, 6.70];
    whooshTimes.forEach((wt, idx) => {
      const src = ctx.createBufferSource();
      src.buffer = noiseBuffer;
      const bp = ctx.createBiquadFilter();
      bp.type = "bandpass";
      bp.Q.setValueAtTime(3.0, T(wt));
      if (idx < 3) {
        bp.frequency.setValueAtTime(400, T(wt));
        bp.frequency.exponentialRampToValueAtTime(1200, T(wt + 1.4));
      } else {
        bp.frequency.setValueAtTime(1200, T(wt));
        bp.frequency.exponentialRampToValueAtTime(400, T(wt + 1.4));
      }
      const g = ctx.createGain();
      g.gain.setValueAtTime(0.0001, T(wt));
      g.gain.linearRampToValueAtTime(0.0251, T(wt + 0.3)); // -32 dBFS
      g.gain.exponentialRampToValueAtTime(0.0001, T(wt + 1.4));
      src.connect(bp);
      bp.connect(g);
      g.connect(comp);
      src.start(T(wt));
      src.stop(T(wt + 1.45));
    });

    // Collision Dissonant Cluster at ~7.4s (D4 + Eb4 sines, 300ms, -30 dBFS)
    [293.665, 311.127].forEach(f => {
      const osc = ctx.createOscillator();
      osc.type = "sine";
      osc.frequency.setValueAtTime(f, T(7.4));
      const g = ctx.createGain();
      g.gain.setValueAtTime(0.0001, T(7.4));
      g.gain.linearRampToValueAtTime(0.0316, T(7.42)); // -30 dBFS
      g.gain.exponentialRampToValueAtTime(0.0001, T(7.7));
      osc.connect(g);
      g.connect(comp);
      g.connect(convolver);
      osc.start(T(7.4));
      osc.stop(T(7.75));
    });

    // --- 3. S4 Resolve Bell Chord at 13.0s (D3 F#3 A3 D4) ---
    playBellChord(13.0, [146.832, 184.997, 220.000, 293.665], 3.2, 0.42);

    // --- 4. Typing (S6) Noise Ticks & Connected Chime ---
    const typingTimes = [18.20, 18.27, 18.34, 18.41, 18.48];
    typingTimes.forEach(tt => {
      const src = ctx.createBufferSource();
      src.buffer = noiseBuffer;
      const bp = ctx.createBiquadFilter();
      bp.type = "bandpass";
      bp.frequency.setValueAtTime(1800, T(tt));
      bp.Q.setValueAtTime(4.0, T(tt));
      const g = ctx.createGain();
      g.gain.setValueAtTime(0.0316, T(tt)); // -30 dBFS
      g.gain.exponentialRampToValueAtTime(0.0001, T(tt + 0.008)); // 8 ms
      src.connect(bp);
      bp.connect(g);
      g.connect(comp);
      src.start(T(tt));
      src.stop(T(tt + 0.015));
    });

    // Return key at 23.0s (25ms)
    {
      const src = ctx.createBufferSource();
      src.buffer = noiseBuffer;
      const bp = ctx.createBiquadFilter();
      bp.type = "bandpass";
      bp.frequency.setValueAtTime(1400, T(23.0));
      bp.Q.setValueAtTime(3.0, T(23.0));
      const g = ctx.createGain();
      g.gain.setValueAtTime(0.0398, T(23.0)); // -28 dBFS
      g.gain.exponentialRampToValueAtTime(0.0001, T(23.025));
      src.connect(bp);
      bp.connect(g);
      g.connect(comp);
      src.start(T(23.0));
      src.stop(T(23.035));
    }

    // Connected at 24.4s: A4 -> D5, 120ms apart
    playBellChord(24.40, [440.000], 1.2, 0.45);
    playBellChord(24.52, [587.330], 1.5, 0.50);

    // --- 5. Syllables Murmurs (S8/S9: bandpass 200-600Hz at -34 dBFS) ---
    const allMurmurs = [
      ...SYLLABLES_S8,
      ...SYLLABLES_S9,
      ...SYLLABLES_H1,
      ...SYLLABLES_H2
    ];
    allMurmurs.forEach(mt => {
      const src = ctx.createBufferSource();
      src.buffer = noiseBuffer;
      const bp = ctx.createBiquadFilter();
      bp.type = "bandpass";
      bp.frequency.setValueAtTime(380, T(mt));
      bp.Q.setValueAtTime(1.8, T(mt));
      const g = ctx.createGain();
      g.gain.setValueAtTime(0.0001, T(mt));
      g.gain.linearRampToValueAtTime(0.0200, T(mt + 0.09)); // -34 dBFS
      g.gain.exponentialRampToValueAtTime(0.0001, T(mt + 0.35));
      src.connect(bp);
      bp.connect(g);
      g.connect(comp);
      src.start(T(mt));
      src.stop(T(mt + 0.38));
    });

    // --- 6. Photon at 47.0s (sweep 220->880Hz, sub thump 55Hz) & S12 Pings ---
    {
      // Sub thump at launch
      const sub = ctx.createOscillator();
      sub.type = "sine";
      sub.frequency.setValueAtTime(55, T(47.0));
      const g = ctx.createGain();
      g.gain.setValueAtTime(0.06, T(47.0));
      g.gain.exponentialRampToValueAtTime(0.0001, T(47.2));
      sub.connect(g);
      g.connect(comp);
      sub.start(T(47.0));
      sub.stop(T(47.25));

      // Sine sweep
      const sweep = ctx.createOscillator();
      sweep.type = "sine";
      sweep.frequency.setValueAtTime(220, T(47.0));
      sweep.frequency.exponentialRampToValueAtTime(880, T(48.0));
      const gs = ctx.createGain();
      gs.gain.setValueAtTime(0.0001, T(47.0));
      gs.gain.linearRampToValueAtTime(0.03, T(47.1));
      gs.gain.setValueAtTime(0.03, T(47.9));
      gs.gain.linearRampToValueAtTime(0.0001, T(48.0));
      sweep.connect(gs);
      gs.connect(comp);
      gs.connect(delay);
      sweep.start(T(47.0));
      sweep.stop(T(48.05));
    }

    // S12 small photon pings (2-4 kHz, 60ms, -36 dBFS)
    const pingTimes = [52.3, 52.6, 52.9, 53.2, 53.5, 53.8, 54.1, 54.4];
    const pingFreqs = [2400, 3200, 2800, 3600, 2200, 3400, 3800, 2600];
    pingTimes.forEach((pt, i) => {
      const osc = ctx.createOscillator();
      osc.type = "sine";
      osc.frequency.setValueAtTime(pingFreqs[i % pingFreqs.length], T(pt));
      const g = ctx.createGain();
      g.gain.setValueAtTime(0.0158, T(pt)); // -36 dBFS
      g.gain.exponentialRampToValueAtTime(0.0001, T(pt + 0.06));
      osc.connect(g);
      g.connect(comp);
      osc.start(T(pt));
      osc.stop(T(pt + 0.08));
    });

    // --- 7. Reveal Bell Chord at 63.0s (D3, F#3, A3, D4, D5, D6 ping) ---
    playBellChord(63.0, [146.832, 184.997, 220.000, 293.665, 587.330], 5.5, 0.5);
    {
      const d6 = ctx.createOscillator();
      d6.type = "sine";
      d6.frequency.setValueAtTime(1174.66, T(63.0));
      const g = ctx.createGain();
      g.gain.setValueAtTime(0.045, T(63.0));
      g.gain.exponentialRampToValueAtTime(0.0001, T(67.0));
      d6.connect(g);
      g.connect(comp);
      g.connect(delay);
      g.connect(convolver);
      d6.start(T(63.0));
      d6.stop(T(67.1));
    }

    return { comp, masterGain };
  }

  // --- Film Grain Generator (§4 & §7) ---
  const GRAIN_W = 480;
  const GRAIN_H = 270;
  let grainCanvasOffscreen = null;
  let grainCtxOffscreen = null;
  let grainImageData = null;
  let grainData32 = null;

  function initGrain() {
    grainCanvasOffscreen = document.createElement("canvas");
    grainCanvasOffscreen.width = GRAIN_W;
    grainCanvasOffscreen.height = GRAIN_H;
    grainCtxOffscreen = grainCanvasOffscreen.getContext("2d");
    grainImageData = grainCtxOffscreen.createImageData(GRAIN_W, GRAIN_H);
    grainData32 = new Uint32Array(grainImageData.data.buffer);
  }

  function renderGrain(t) {
    if (!el.ctxGrain || !grainCtxOffscreen) return;
    if (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      el.ctxGrain.clearRect(0, 0, STAGE_WIDTH, STAGE_HEIGHT);
      return;
    }

    const frame = Math.floor(t * 60);
    let seed = (frame * 1664525 + 1013904223) | 0;
    const len = grainData32.length;

    for (let i = 0; i < len; i++) {
      seed = (seed * 1664525 + 1013904223) | 0;
      const v = (seed & 0xFF);
      grainData32[i] = (255 << 24) | (v << 16) | (v << 8) | v;
    }

    grainCtxOffscreen.putImageData(grainImageData, 0, 0);
    el.ctxGrain.clearRect(0, 0, STAGE_WIDTH, STAGE_HEIGHT);
    el.ctxGrain.drawImage(grainCanvasOffscreen, 0, 0, STAGE_WIDTH, STAGE_HEIGHT);
  }

  // --- 3D Globe Projection Math (§5 Act III) ---
  const GLOBE_R = 380;
  const GLOBE_CX = 960;
  const GLOBE_CY = 480;
  const AXIAL_TILT = 22 * (Math.PI / 180);

  function geoToUnitVector(latDeg, lonDeg) {
    const phi = latDeg * (Math.PI / 180);
    const lam = lonDeg * (Math.PI / 180);
    return [
      Math.cos(phi) * Math.sin(lam),
      Math.sin(phi),
      Math.cos(phi) * Math.cos(lam)
    ];
  }

  function projectPoint(latDeg, lonDeg, rotLonDeg, radius = GLOBE_R) {
    const phi = latDeg * (Math.PI / 180);
    const lam = (lonDeg - rotLonDeg) * (Math.PI / 180);

    const x = Math.cos(phi) * Math.sin(lam);
    const y = Math.sin(phi);
    const z = Math.cos(phi) * Math.cos(lam);

    const yt = y * Math.cos(AXIAL_TILT) - z * Math.sin(AXIAL_TILT);
    const zt = y * Math.sin(AXIAL_TILT) + z * Math.cos(AXIAL_TILT);

    return {
      x: GLOBE_CX + radius * x,
      y: GLOBE_CY - radius * yt,
      z: zt,
      front: zt > 0
    };
  }

  function projectVector(uVec, rotLonDeg, radius = GLOBE_R) {
    const theta = rotLonDeg * (Math.PI / 180);
    const cosT = Math.cos(theta);
    const sinT = Math.sin(theta);
    const xr = uVec[0] * cosT - uVec[2] * sinT;
    const zr = uVec[0] * sinT + uVec[2] * cosT;
    const yr = uVec[1];

    const yt = yr * Math.cos(AXIAL_TILT) - zr * Math.sin(AXIAL_TILT);
    const zt = yr * Math.sin(AXIAL_TILT) + zr * Math.cos(AXIAL_TILT);

    return {
      x: GLOBE_CX + radius * xr,
      y: GLOBE_CY - radius * yt,
      z: zt,
      front: zt > 0
    };
  }

  function slerpVector(v1, v2, s) {
    let dot = v1[0] * v2[0] + v1[1] * v2[1] + v1[2] * v2[2];
    dot = clamp(dot, -1, 1);
    const omega = Math.acos(dot);
    if (Math.abs(omega) < 1e-4) return v1;
    const sinOmega = Math.sin(omega);
    const c1 = Math.sin((1 - s) * omega) / sinOmega;
    const c2 = Math.sin(s * omega) / sinOmega;
    return [
      c1 * v1[0] + c2 * v2[0],
      c1 * v1[1] + c2 * v2[1],
      c1 * v1[2] + c2 * v2[2]
    ];
  }

  const U_DELHI = geoToUnitVector(CITIES.delhi.lat, CITIES.delhi.lon);
  const U_AMSTERDAM = geoToUnitVector(CITIES.amsterdam.lat, CITIES.amsterdam.lon);
  const U_WORLD = CITIES.world.map(c => ({
    name: c.name,
    vec: geoToUnitVector(c.lat, c.lon)
  }));

  // --- Rendering Canvas 2: Globe, Arcs, Photons ---
  function renderGlobe(t) {
    const ctx = el.ctxGlobe;
    ctx.clearRect(0, 0, STAGE_WIDTH, STAGE_HEIGHT);

    if (t < 45.0 || t > 63.0) return;

    const globeAlpha = kf(t, [
      [45.0, 0], [46.0, 1], [58.0, 1], [59.5, 0]
    ], easeEntrance);

    // Rotation: 4 deg/s, keeps Delhi (77.2E) and Amsterdam (4.9E) front-facing throughout
    const rotLon = 15.0 + 4.0 * (t - 45.0);

    // S13: Globe fades to two dots that drift toward each other (58.0 to 63.0s)
    if (t >= 58.0) {
      const x1 = kf(t, [[58.0, 720], [63.0, 820]], easeSine);
      const x2 = kf(t, [[58.0, 1200], [63.0, 1100]], easeSine);
      const dotAlpha = kf(t, [[58.0, 0.8], [61.0, 1.0], [63.0, 1.0]]);

      ctx.beginPath();
      ctx.arc(x1, GLOBE_CY, 8, 0, Math.PI * 2);
      ctx.fillStyle = `rgba(243, 241, 236, ${dotAlpha})`;
      ctx.shadowColor = "#f3f1ec";
      ctx.shadowBlur = 18;
      ctx.fill();

      ctx.beginPath();
      ctx.arc(x2, GLOBE_CY, 8, 0, Math.PI * 2);
      ctx.fillStyle = `rgba(96, 165, 250, ${dotAlpha})`;
      ctx.shadowColor = "#60a5fa";
      ctx.shadowBlur = 18;
      ctx.fill();
      ctx.shadowBlur = 0;
    }

    if (globeAlpha <= 0.001) return;

    ctx.save();
    ctx.globalAlpha = globeAlpha;

    // Sphere Outline Circle
    ctx.beginPath();
    ctx.arc(GLOBE_CX, GLOBE_CY, GLOBE_R, 0, Math.PI * 2);
    ctx.strokeStyle = "rgba(243, 241, 236, 0.14)";
    ctx.lineWidth = 1.0;
    ctx.stroke();

    // Meridians every 20 degrees
    for (let lon = -180; lon < 180; lon += 20) {
      let prev = null;
      for (let lat = -80; lat <= 80; lat += 4) {
        const curr = projectPoint(lat, lon, rotLon);
        if (prev) {
          ctx.beginPath();
          ctx.moveTo(prev.x, prev.y);
          ctx.lineTo(curr.x, curr.y);
          ctx.strokeStyle = (prev.front && curr.front) ? "rgba(243, 241, 236, 0.14)" : "rgba(243, 241, 236, 0.04)";
          ctx.lineWidth = 1.0;
          ctx.stroke();
        }
        prev = curr;
      }
    }

    // Parallels every 20 degrees
    for (let lat = -80; lat <= 80; lat += 20) {
      let prev = null;
      for (let lon = -180; lon <= 180; lon += 4) {
        const curr = projectPoint(lat, lon, rotLon);
        if (prev) {
          ctx.beginPath();
          ctx.moveTo(prev.x, prev.y);
          ctx.lineTo(curr.x, curr.y);
          ctx.strokeStyle = (prev.front && curr.front) ? "rgba(243, 241, 236, 0.14)" : "rgba(243, 241, 236, 0.04)";
          ctx.lineWidth = 1.0;
          ctx.stroke();
        }
        prev = curr;
      }
    }

    // Delhi and Amsterdam points
    const pDelhi = projectVector(U_DELHI, rotLon);
    const pAmst = projectVector(U_AMSTERDAM, rotLon);

    // Great-circle Arc between Delhi & Amsterdam (lifted 2%)
    // The Delhi->Amsterdam arc stays lit (alpha 0.5) after the photon arrives, as the one bright thread among the faint ones.
    const arcRadius = GLOBE_R * 1.02;
    const ARC_STEPS = 50;
    ctx.beginPath();
    for (let i = 0; i <= ARC_STEPS; i++) {
      const s = i / ARC_STEPS;
      const v = slerpVector(U_DELHI, U_AMSTERDAM, s);
      const pt = projectVector(v, rotLon, arcRadius);
      if (i === 0) ctx.moveTo(pt.x, pt.y);
      else ctx.lineTo(pt.x, pt.y);
    }
    ctx.strokeStyle = "rgba(243, 241, 236, 0.50)";
    ctx.lineWidth = 1.5;
    ctx.stroke();

    // S11 Photon (47.0 to 48.0s) & 40 ms Counter
    if (t >= 47.0 && t <= 52.0) {
      const sPhoton = clamp((t - 47.0) / 1.0, 0, 1);
      const photonVec = slerpVector(U_DELHI, U_AMSTERDAM, sPhoton);
      const pHead = projectVector(photonVec, rotLon, arcRadius);

      // 60px Fading Trail while moving
      if (sPhoton < 1.0) {
        const trailLength = 0.14;
        const trailSteps = 16;
        for (let j = 0; j < trailSteps; j++) {
          const sj0 = clamp(sPhoton - (j + 1) * (trailLength / trailSteps), 0, 1);
          const sj1 = clamp(sPhoton - j * (trailLength / trailSteps), 0, 1);
          const pt0 = projectVector(slerpVector(U_DELHI, U_AMSTERDAM, sj0), rotLon, arcRadius);
          const pt1 = projectVector(slerpVector(U_DELHI, U_AMSTERDAM, sj1), rotLon, arcRadius);
          const alpha = (1 - j / trailSteps) * 0.75;
          ctx.beginPath();
          ctx.moveTo(pt0.x, pt0.y);
          ctx.lineTo(pt1.x, pt1.y);
          ctx.strokeStyle = `rgba(243, 241, 236, ${alpha})`;
          ctx.lineWidth = 2.0;
          ctx.stroke();
        }
      }

      // Glowing Photon Head
      ctx.beginPath();
      ctx.arc(pHead.x, pHead.y, 4.5, 0, Math.PI * 2);
      ctx.fillStyle = "#f3f1ec";
      ctx.shadowColor = "#f3f1ec";
      ctx.shadowBlur = 14;
      ctx.fill();
      ctx.shadowBlur = 0;

      // Millisecond Counter Beside Photon ("0 ms" -> "40 ms", then holds)
      const msVal = Math.round(40 * sPhoton);
      ctx.font = "18px ui-monospace, Menlo, monospace";
      ctx.textAlign = "left";
      ctx.fillStyle = "#f3f1ec";
      ctx.fillText(`${msVal} ms`, pHead.x + 18, pHead.y - 10);
    }

    // S12 Arcs & Photons to 20 World Cities (52.0 to 58.0s)
    if (t >= 52.0 && t <= 58.0) {
      const bloomFade = kf(t, [[52.0, 0], [52.5, 1], [57.0, 1], [58.0, 0]]);
      U_WORLD.forEach((city, idx) => {
        const sourceVec = (idx % 2 === 0) ? U_DELHI : U_AMSTERDAM;
        const cPt = projectVector(city.vec, rotLon);

        // Staggered across 52.0–55.0, each drawn on over 1.0 s
        const tStart = 52.0 + (idx / 19) * 3.0;
        const arcProg = clamp((t - tStart) / 1.0, 0, 1);

        if (arcProg > 0) {
          const totalSteps = 24;
          const steps = Math.max(2, Math.ceil(totalSteps * arcProg));
          for (let k = 0; k < steps; k++) {
            const s0 = (k / totalSteps) * arcProg;
            const s1 = ((k + 1) / totalSteps) * arcProg;
            const v0 = slerpVector(sourceVec, city.vec, s0);
            const v1 = slerpVector(sourceVec, city.vec, s1);
            const pt0 = projectVector(v0, rotLon, arcRadius);
            const pt1 = projectVector(v1, rotLon, arcRadius);

            const isFront = pt0.front || pt1.front;
            const a = (isFront ? 0.38 : 0.08) * bloomFade;

            ctx.beginPath();
            ctx.moveTo(pt0.x, pt0.y);
            ctx.lineTo(pt1.x, pt1.y);
            ctx.strokeStyle = `rgba(243, 241, 236, ${a.toFixed(3)})`;
            ctx.lineWidth = 1.5;
            ctx.stroke();
          }

          // 3px photon and 40px fading trail while drawing on
          if (arcProg < 1.0) {
            const headVec = slerpVector(sourceVec, city.vec, arcProg);
            const pHead = projectVector(headVec, rotLon, arcRadius);

            const trailSteps = 6;
            const trailDelta = 0.08;
            for (let j = 0; j < trailSteps; j++) {
              const sj0 = clamp(arcProg - (j + 1) * (trailDelta / trailSteps), 0, 1);
              const sj1 = clamp(arcProg - j * (trailDelta / trailSteps), 0, 1);
              const pt0 = projectVector(slerpVector(sourceVec, city.vec, sj0), rotLon, arcRadius);
              const pt1 = projectVector(slerpVector(sourceVec, city.vec, sj1), rotLon, arcRadius);
              const trailAlpha = (1 - j / trailSteps) * 0.70 * bloomFade;
              ctx.beginPath();
              ctx.moveTo(pt0.x, pt0.y);
              ctx.lineTo(pt1.x, pt1.y);
              ctx.strokeStyle = `rgba(243, 241, 236, ${trailAlpha.toFixed(3)})`;
              ctx.lineWidth = 2.0;
              ctx.stroke();
            }

            ctx.beginPath();
            ctx.arc(pHead.x, pHead.y, 3.0, 0, Math.PI * 2);
            ctx.fillStyle = "#f3f1ec";
            ctx.shadowColor = "#f3f1ec";
            ctx.shadowBlur = 10;
            ctx.fill();
            ctx.shadowBlur = 0;
          }
        }

        // Other cities: 3px cream 70%
        if (cPt.front) {
          ctx.beginPath();
          ctx.arc(cPt.x, cPt.y, 3, 0, Math.PI * 2);
          ctx.fillStyle = `rgba(243, 241, 236, ${(0.70 * bloomFade).toFixed(3)})`;
          ctx.fill();
        }
      });
    }

    // Delhi & Amsterdam City Dots & Labels
    // Hero dots 5px cream 100% with 14px soft glow; labels always drawn while front
    if (pDelhi.front) {
      ctx.beginPath();
      ctx.arc(pDelhi.x, pDelhi.y, 5, 0, Math.PI * 2);
      ctx.fillStyle = "#f3f1ec";
      ctx.shadowColor = "#f3f1ec";
      ctx.shadowBlur = 14;
      ctx.fill();
      ctx.shadowBlur = 0;
      ctx.font = "18px ui-monospace, Menlo, monospace";
      ctx.textAlign = "center";
      ctx.fillStyle = "#f3f1ec";
      ctx.fillText("DELHI", pDelhi.x, pDelhi.y - 14);
    }
    if (pAmst.front) {
      ctx.beginPath();
      ctx.arc(pAmst.x, pAmst.y, 5, 0, Math.PI * 2);
      ctx.fillStyle = "#f3f1ec";
      ctx.shadowColor = "#f3f1ec";
      ctx.shadowBlur = 14;
      ctx.fill();
      ctx.shadowBlur = 0;
      ctx.font = "18px ui-monospace, Menlo, monospace";
      ctx.textAlign = "center";
      ctx.fillStyle = "#f3f1ec";
      ctx.fillText("AMSTERDAM", pAmst.x, pAmst.y - 14);
    }

    ctx.restore();
  }

  // --- Rendering Canvas 1: Ripples, Particles, Waveforms, Orbs ---
  function renderRipples(t) {
    const ctx = el.ctxRipples;
    ctx.clearRect(0, 0, STAGE_WIDTH, STAGE_HEIGHT);

    // --- S1: Single Breathing Cream Point (0.0 to 3.5s) ---
    if (t >= 0.0 && t <= 3.5) {
      const radius = 3 + 4 * Math.sin(Math.PI * (t / 3.5));
      const glow = ctx.createRadialGradient(960, 540, 0, 960, 540, radius * 4);
      glow.addColorStop(0, "rgba(243, 241, 236, 1)");
      glow.addColorStop(0.3, "rgba(243, 241, 236, 0.5)");
      glow.addColorStop(1, "rgba(243, 241, 236, 0)");

      ctx.beginPath();
      ctx.arc(960, 540, radius * 4, 0, Math.PI * 2);
      ctx.fillStyle = glow;
      ctx.fill();

      ctx.beginPath();
      ctx.arc(960, 540, radius, 0, Math.PI * 2);
      ctx.fillStyle = "#f3f1ec";
      ctx.fill();
      return;
    }

    // --- S2 & S3 & S4: Two Orbs (3.5 to 15.0s) ---
    if (t > 3.5 && t <= 15.0) {
      const splitProgress = kf(t, [[3.5, 0], [4.2, 1]], easeEntrance);
      const leftX = 960 - 450 * splitProgress;
      const rightX = 960 + 450 * splitProgress;
      const centerY = 540;

      let orbAlpha = 1.0;
      if (t >= 7.5 && t < 13.0) {
        orbAlpha = kf(t, [[7.5, 1.0], [8.5, 0.40], [12.95, 0.40]]);
      } else if (t >= 13.0) {
        orbAlpha = 1.0; // S4 snap back to full brightness
      }

      // Left Orb ("you", cream)
      {
        const gCream = ctx.createRadialGradient(leftX, centerY, 0, leftX, centerY, 120);
        gCream.addColorStop(0, `rgba(243, 241, 236, ${orbAlpha})`);
        gCream.addColorStop(0.5, `rgba(243, 241, 236, ${0.6 * orbAlpha})`);
        gCream.addColorStop(1, "rgba(243, 241, 236, 0)");
        ctx.beginPath();
        ctx.arc(leftX, centerY, 120, 0, Math.PI * 2);
        ctx.fillStyle = gCream;
        ctx.fill();
      }

      // Right Orb ("them", blue)
      if (t >= 9.0 && t < 13.0) {
        // S3 Mosaic Blocks (24px cells, 4 levels)
        const cellSize = 24;
        const orbR = 120;
        for (let x = rightX - orbR; x <= rightX + orbR; x += cellSize) {
          for (let y = centerY - orbR; y <= centerY + orbR; y += cellSize) {
            const dx = (x + cellSize / 2) - rightX;
            const dy = (y + cellSize / 2) - centerY;
            const dist = Math.sqrt(dx * dx + dy * dy);
            if (dist < orbR) {
              const b = clamp(1 - dist / orbR, 0, 1);
              const bQuant = Math.floor(b * 4) / 3;
              ctx.fillStyle = `rgba(96, 165, 250, ${bQuant * orbAlpha * 0.9})`;
              ctx.fillRect(x, y, cellSize - 1, cellSize - 1);
            }
          }
        }
      } else {
        // Smooth circle in S2 and snapped in S4
        const gBlue = ctx.createRadialGradient(rightX, centerY, 0, rightX, centerY, 120);
        gBlue.addColorStop(0, `rgba(96, 165, 250, ${orbAlpha})`);
        gBlue.addColorStop(0.5, `rgba(96, 165, 250, ${0.6 * orbAlpha})`);
        gBlue.addColorStop(1, "rgba(96, 165, 250, 0)");
        ctx.beginPath();
        ctx.arc(rightX, centerY, 120, 0, Math.PI * 2);
        ctx.fillStyle = gBlue;
        ctx.fill();
      }

      // S2 Ripples: Arc Packets (constant radius 70px, spanning ±40° around direction of travel,
      // 2px stroke at 65% with 8px soft glow, 1.4s trip, fading out over last 15%)
      if (t >= 3.8 && t < 7.4) {
        const r = 70;
        const rad40 = 40 * (Math.PI / 180);

        const drawPacket = (tStart, direction, isBlue) => {
          if (t < tStart || t >= tStart + 1.4 || t >= 7.4) return;
          const age = t - tStart;
          const progress = age / 1.4;
          let alpha = 0.9;
          if (progress > 0.85) {
            alpha *= (1.0 - progress) / 0.15;
          }
          if (alpha <= 0) return;

          ctx.save();
          ctx.beginPath();
          if (direction > 0) {
            // Travelling right (+X) from left orb to right orb: arc tip at x, cx = x - r
            const x = leftX + (rightX - leftX) * progress;
            ctx.arc(x - r, centerY, r, -rad40, rad40);
          } else {
            // Travelling left (-X) from right orb to left orb: arc tip at x, cx = x + r
            const x = rightX - (rightX - leftX) * progress;
            ctx.arc(x + r, centerY, r, Math.PI - rad40, Math.PI + rad40);
          }

          if (isBlue) {
            ctx.strokeStyle = `rgba(96, 165, 250, ${alpha.toFixed(3)})`;
            ctx.shadowColor = "#60a5fa";
          } else {
            ctx.strokeStyle = `rgba(243, 241, 236, ${alpha.toFixed(3)})`;
            ctx.shadowColor = "#f3f1ec";
          }
          ctx.lineWidth = 2.5;
          ctx.shadowBlur = 10;
          ctx.stroke();
          ctx.restore();
        };

        // Utterance 1: Three packets leave cream orb 0.35s apart, travelling right
        [3.90, 4.25, 4.60].forEach(tStart => drawPacket(tStart, 1, false));

        // Utterance 2: Blue replies (three packets leaving right orb 0.35s apart, travelling left, in blue)
        [6.00, 6.35, 6.70].forEach(tStart => drawPacket(tStart, -1, true));

        // Utterance 3: Cream speaks again (meeting Blue's 6.70 packet mid-way at 7.4s)
        [6.70, 7.05].forEach(tStart => drawPacket(tStart, 1, false));
      }

      // Collision Particles at ~7.4s
      if (t >= 7.4 && t < 8.8) {
        const dt = t - 7.4;
        const partAlpha = clamp(1 - dt / 1.3, 0, 1);
        const dragDist = 1 - Math.exp(-dt / 0.4);

        PARTICLES.forEach(p => {
          const dist = p.speed * dragDist * 0.9;
          const px = 960 + Math.cos(p.angle) * dist;
          const py = 540 + Math.sin(p.angle) * dist;
          ctx.beginPath();
          ctx.arc(px, py, p.size, 0, Math.PI * 2);
          ctx.fillStyle = p.isCream
            ? `rgba(243, 241, 236, ${partAlpha})`
            : `rgba(96, 165, 250, ${partAlpha})`;
          ctx.fill();
        });
      }

      // S3 Jagged Stepped Waveform with Dropouts
      if (t >= 9.0 && t < 13.0) {
        ctx.save();
        ctx.strokeStyle = "rgba(243, 241, 236, 0.6)";
        ctx.lineWidth = 2.0;
        const startX = leftX + 80;
        const endX = rightX - 80;
        const stepWidth = 18;
        const numSteps = Math.floor((endX - startX) / stepWidth);
        const frameSeed = Math.floor(t * 14);

        ctx.beginPath();
        let curX = startX;
        let curY = centerY;
        ctx.moveTo(curX, curY);

        for (let i = 0; i < numSteps; i++) {
          const rngStep = mulberry32(frameSeed * 1000 + i);
          const hasDropout = rngStep() < 0.28;
          const amp = hasDropout ? 0 : (rngStep() * 2 - 1) * 36;
          const nextY = centerY + amp;
          ctx.lineTo(curX, nextY);
          curX += stepWidth;
          ctx.lineTo(curX, nextY);
        }
        ctx.stroke();
        ctx.restore();
      }

      // S4 Smooth Continuous Sine Waveform
      if (t >= 13.0 && t <= 15.0) {
        ctx.save();
        ctx.strokeStyle = "rgba(243, 241, 236, 0.85)";
        ctx.lineWidth = 2.0;
        const startX = leftX + 80;
        const endX = rightX - 80;
        const len = endX - startX;

        ctx.beginPath();
        for (let x = startX; x <= endX; x += 4) {
          const u = (x - startX) / len;
          const windowFunc = Math.sin(Math.PI * u);
          const y = centerY + Math.sin((x * 0.035) - t * 8.0) * 26 * windowFunc;
          if (x === startX) ctx.moveTo(x, y);
          else ctx.lineTo(x, y);
        }
        ctx.stroke();
        ctx.restore();
      }
      return;
    }

    // S8 Waveform along bottom hairline of left Mac window (29.0 to 33.0s)
    if (t >= 29.0 && t <= 33.0) {
      const env = evalVoiceEnvelope(t, SYLLABLES_S8);
      if (env > 0.05) {
        ctx.save();
        ctx.strokeStyle = `rgba(243, 241, 236, ${env * 0.65})`;
        ctx.lineWidth = 1.5;
        const waveStartX = 240;
        const waveEndX = 1480;
        const waveY = 938;
        ctx.beginPath();
        for (let x = waveStartX; x <= waveEndX; x += 6) {
          const waveAmp = (Math.sin(x * 0.15 + t * 24) * 0.5 + Math.sin(x * 0.32 - t * 18) * 0.5) * 2.2 * env;
          const y = waveY - Math.abs(waveAmp);
          if (x === waveStartX) ctx.moveTo(x, y);
          else ctx.lineTo(x, y);
        }
        ctx.stroke();
        ctx.restore();
      }
    }

    // S10 Connecting Hairline (38.0 to 45.0s)
    if (t >= 38.0 && t <= 45.0) {
      const alpha = kf(t, [[38.0, 0], [38.5, 0.6], [44.5, 0.6], [45.0, 0]]);
      const xA = 636;
      const xB = 1284;
      const yLine = 640;

      ctx.beginPath();
      ctx.moveTo(xA, yLine);
      ctx.lineTo(xB, yLine);
      ctx.strokeStyle = `rgba(243, 241, 236, ${0.25 * alpha})`;
      ctx.lineWidth = 1.0;
      ctx.stroke();

      const pulseT = ((t - 38.0) % 1.2) / 1.2;
      const px = xA + (xB - xA) * pulseT;
      ctx.beginPath();
      ctx.arc(px, yLine, 3.5, 0, Math.PI * 2);
      ctx.fillStyle = "#f3f1ec";
      ctx.shadowColor = "#f3f1ec";
      ctx.shadowBlur = 12;
      ctx.fill();
      ctx.shadowBlur = 0;
    }

    // S14 & S15 Reveal Orbs (63.0 to 75.0s)
    // Orbs centered at (960, 400) — cream center x=820, blue center x=1100, each 420px (radius 210)
    // In S15 the whole group scales to 0.7 around (960, 520) and rises so orbs' center lands at y=300
    if (t >= 63.0) {
      const enterScale = kf(t, [[63.0, 0.05], [64.2, 1.0]], easeEntrance);
      const s15Progress = kf(t, [[68.0, 0], [69.2, 1.0]], easeEntrance);
      const scaleS15 = 1.0 - 0.30 * s15Progress;
      const dy = -136 * s15Progress;

      const breathe = (t >= 68.0) ? (1.0 + 0.012 * Math.sin(2 * Math.PI * (t - 68.0) / 4.0)) : 1.0;
      const orbR = 210 * enterScale * scaleS15 * breathe;

      const orbCenterY = 520 + (400 - 520) * scaleS15 + dy;
      const cxCream = 960 - 140 * scaleS15;
      const cxBlue = 960 + 140 * scaleS15;

      const fadeOut = kf(t, [[74.2, 1.0], [75.0, 0.0]], easeLinear);

      // Left cream orb
      {
        const g1 = ctx.createRadialGradient(cxCream, orbCenterY, 0, cxCream, orbCenterY, orbR);
        g1.addColorStop(0, `rgba(243, 241, 236, ${(fadeOut * 0.95).toFixed(3)})`);
        g1.addColorStop(0.65, `rgba(243, 241, 236, ${(fadeOut * 0.45).toFixed(3)})`);
        g1.addColorStop(1, "rgba(243, 241, 236, 0)");
        ctx.beginPath();
        ctx.arc(cxCream, orbCenterY, orbR, 0, Math.PI * 2);
        ctx.fillStyle = g1;
        ctx.fill();
      }

      // Right blue orb
      {
        const g2 = ctx.createRadialGradient(cxBlue, orbCenterY, 0, cxBlue, orbCenterY, orbR);
        g2.addColorStop(0, `rgba(96, 165, 250, ${(fadeOut * 0.95).toFixed(3)})`);
        g2.addColorStop(0.65, `rgba(96, 165, 250, ${(fadeOut * 0.45).toFixed(3)})`);
        g2.addColorStop(1, "rgba(96, 165, 250, 0)");
        ctx.beginPath();
        ctx.arc(cxBlue, orbCenterY, orbR, 0, Math.PI * 2);
        ctx.fillStyle = g2;
        ctx.fill();
      }
    }
  }

  // --- Edge Band Updater (§4: Glow, (1-t)^2.2 ramp, 1.5px hairline) ---
  function updateEdgeBand(bandEl, colorRgb, env, thickEnv) {
    if (!bandEl) return;
    const thickness = 48 + 48 * thickEnv;
    const opacity = 0.55 + 0.45 * env;

    const [r, g, b] = colorRgb;
    const border = bandEl.querySelector(".edge-band-border");
    const topG = bandEl.querySelector(".edge-glow-top");
    const botG = bandEl.querySelector(".edge-glow-bottom");
    const lftG = bandEl.querySelector(".edge-glow-left");
    const rgtG = bandEl.querySelector(".edge-glow-right");

    bandEl.style.opacity = opacity.toFixed(3);
    border.style.borderColor = `rgba(${r}, ${g}, ${b}, 0.95)`;

    const gradTop = `linear-gradient(to bottom, rgba(${r},${g},${b},1) 0%, rgba(${r},${g},${b},0.79) 10%, rgba(${r},${g},${b},0.61) 20%, rgba(${r},${g},${b},0.39) 35%, rgba(${r},${g},${b},0.22) 50%, rgba(${r},${g},${b},0.07) 70%, rgba(${r},${g},${b},0) 100%)`;
    const gradBot = `linear-gradient(to top, rgba(${r},${g},${b},1) 0%, rgba(${r},${g},${b},0.79) 10%, rgba(${r},${g},${b},0.61) 20%, rgba(${r},${g},${b},0.39) 35%, rgba(${r},${g},${b},0.22) 50%, rgba(${r},${g},${b},0.07) 70%, rgba(${r},${g},${b},0) 100%)`;
    const gradLft = `linear-gradient(to right, rgba(${r},${g},${b},1) 0%, rgba(${r},${g},${b},0.79) 10%, rgba(${r},${g},${b},0.61) 20%, rgba(${r},${g},${b},0.39) 35%, rgba(${r},${g},${b},0.22) 50%, rgba(${r},${g},${b},0.07) 70%, rgba(${r},${g},${b},0) 100%)`;
    const gradRgt = `linear-gradient(to left, rgba(${r},${g},${b},1) 0%, rgba(${r},${g},${b},0.79) 10%, rgba(${r},${g},${b},0.61) 20%, rgba(${r},${g},${b},0.39) 35%, rgba(${r},${g},${b},0.22) 50%, rgba(${r},${g},${b},0.07) 70%, rgba(${r},${g},${b},0) 100%)`;

    topG.style.height = `${thickness}px`;
    topG.style.background = gradTop;

    botG.style.height = `${thickness}px`;
    botG.style.background = gradBot;

    lftG.style.width = `${thickness}px`;
    lftG.style.background = gradLft;

    rgtG.style.width = `${thickness}px`;
    rgtG.style.background = gradRgt;
  }

  // --- Main Scene & DOM Evaluator ---
  function updateDomScenes(t) {
    // --- Act II Container (15.0 to 45.0s) ---
    if (t >= 15.0 && t <= 45.0) {
      el.act2Container.style.display = "block";

      const cornerAlpha = kf(t, [[15.0, 0], [16.0, 0.55], [44.0, 0.55], [45.0, 0]]);
      el.kinCornerWordmark.style.opacity = cornerAlpha.toFixed(3);

      let leftScale = 1.0;
      let leftX = 320;
      let leftY = 140;
      let leftWindowOpacity = 1.0;

      let rightScale = 0.55;
      let rightX = 1000;
      let rightY = 320;
      let rightWindowOpacity = 0.0;

      if (t < 17.0) {
        const riseProgress = kf(t, [[15.0, 0], [16.8, 1]], easeEntrance);
        leftY = 220 - 80 * riseProgress;
        leftWindowOpacity = riseProgress;
      } else if (t >= 17.0 && t < 35.0) {
        const shift = kf(t, [[17.0, 0], [18.2, 1], [33.0, 1]], easeEntrance);
        leftX = 320 - 100 * shift;
        leftY = 140;
      } else if (t >= 35.0 && t < 38.0) {
        leftScale = kf(t, [[35.0, 1.0], [36.0, 0.55]], easeEntrance);
        leftX = kf(t, [[35.0, 220], [36.0, -60]], easeEntrance);
        leftY = kf(t, [[35.0, 140], [36.0, 100]], easeEntrance);

        rightWindowOpacity = kf(t, [[35.0, 0.0], [35.6, 1.0]], easeEntrance);
        rightScale = 0.55;
        rightX = kf(t, [[35.0, 1100], [36.0, 700]], easeEntrance);
        rightY = 100;
      } else if (t >= 38.0 && t <= 45.0) {
        leftScale = kf(t, [[38.0, 0.55], [39.2, 0.40], [44.2, 0.40], [45.0, 0.05]], easeEntrance);
        leftX = kf(t, [[38.0, -60], [39.2, -260]], easeEntrance);
        leftY = kf(t, [[38.0, 100], [39.2, 240]], easeEntrance);

        rightScale = kf(t, [[38.0, 0.55], [39.2, 0.40], [44.2, 0.40], [45.0, 0.05]], easeEntrance);
        rightX = kf(t, [[38.0, 700], [39.2, 900]], easeEntrance);
        rightY = kf(t, [[38.0, 100], [39.2, 240]], easeEntrance);
        rightWindowOpacity = 1.0;

        if (t >= 44.2) {
          const col = kf(t, [[44.2, 1.0], [45.0, 0.0]], easeEntrance);
          leftWindowOpacity = col;
          rightWindowOpacity = col;
        }
      }

      el.macWindowLeft.style.transform = `translate(${leftX - 320}px, ${leftY - 140}px) scale(${leftScale})`;
      el.macWindowLeft.style.opacity = leftWindowOpacity.toFixed(3);

      if (rightWindowOpacity > 0.01) {
        el.macWindowRight.style.display = "block";
        el.macWindowRight.style.transform = `translate(${rightX - 320}px, ${rightY - 140}px) scale(${rightScale})`;
        el.macWindowRight.style.opacity = rightWindowOpacity.toFixed(3);
      } else {
        el.macWindowRight.style.display = "none";
      }

      // Camera Preview Bokeh (S5–S7)
      if (t < 26.0) {
        el.bokehPreviewLeft.style.display = "block";
        el.portraitLeft.style.display = "none";
        const discOffsets = [
          { x: 380 + Math.sin(t * 0.3) * 18, y: 260 + Math.cos(t * 0.25) * 14, r: 180 },
          { x: 860 + Math.cos(t * 0.22) * 16, y: 440 + Math.sin(t * 0.28) * 18, r: 220 },
          { x: 240 + Math.sin(t * 0.35) * 14, y: 560 + Math.cos(t * 0.2) * 16, r: 140 },
          { x: 990 + Math.cos(t * 0.26) * 18, y: 240 + Math.sin(t * 0.3) * 15, r: 160 },
          { x: 620 + Math.sin(t * 0.28) * 15, y: 580 + Math.cos(t * 0.24) * 14, r: 120 }
        ];
        discOffsets.forEach((d, i) => {
          const disc = el.bokehDiscs[i];
          disc.style.width = `${d.r * 2}px`;
          disc.style.height = `${d.r * 2}px`;
          disc.style.left = `${d.x - d.r}px`;
          disc.style.top = `${d.y - d.r}px`;
        });
      } else {
        el.bokehPreviewLeft.style.display = "none";
        el.portraitLeft.style.display = "block";
      }

      // Glass Card & Input Field
      if (t >= 15.0 && t < 26.0) {
        el.glassCard.style.display = "block";
        const cardAlpha = kf(t, [[15.0, 0], [16.5, 1], [25.0, 1], [26.0, 0]]);
        el.glassCard.style.opacity = cardAlpha.toFixed(3);

        const cursorBlink = Math.floor(t * 2.2) % 2 === 0;
        el.inputCursor.style.opacity = cursorBlink ? "1" : "0";

        const typedStr = (t < 18.20) ? "" :
                         (t < 18.27) ? "m" :
                         (t < 18.34) ? "me" :
                         (t < 18.41) ? "mee" :
                         (t < 18.48) ? "meer" : "meera";

        if (typedStr.length === 0) {
          el.inputText.innerHTML = '<span class="input-placeholder">Type a handle, like meera</span>';
        } else {
          el.inputText.textContent = typedStr;
        }

        const isMeeraLit = t >= 18.48;
        if (isMeeraLit) {
          el.rowMeera.style.background = "rgba(74, 222, 128, 0.12)";
          el.rowMeera.style.boxShadow = "inset 0 0 0 1px rgba(74, 222, 128, 0.35)";
        } else {
          el.rowMeera.style.background = "transparent";
          el.rowMeera.style.boxShadow = "none";
        }

        if (t >= 23.0) {
          el.rowArjun.style.opacity = "0.40";
          el.rowDad.style.opacity = "0.40";
        } else {
          el.rowArjun.style.opacity = "1.0";
          el.rowDad.style.opacity = "1.0";
        }

        // Calling Pill
        if (t >= 23.0) {
          el.glassPill.style.display = "flex";
          if (t < 24.4) {
            const dotCycle = Math.floor((t - 23.0) / 0.4) % 3;
            const dots = dotCycle === 0 ? "." : (dotCycle === 1 ? ".." : "...");
            el.pillText.textContent = `Calling Meera${dots}   \u00B7   esc to cancel`;
          } else {
            el.pillText.textContent = "Connected";
          }
        } else {
          el.glassPill.style.display = "none";
        }
      } else {
        el.glassCard.style.display = "none";
      }

      // S8 & S9 Portraits Breathing, 2px Drift & Warmth Overlay
      if (t >= 26.0) {
        const breathe = 1.0 + 0.012 * Math.sin(2 * Math.PI * (t - 26.0) / 4.0);
        const driftX = Math.sin(2 * Math.PI * (t - 26.0) / 5.2) * 2.0;
        const driftY = Math.cos(2 * Math.PI * (t - 26.0) / 6.0) * 2.0;

        el.portraitLeftInner.style.transform = `translate(${driftX.toFixed(2)}px, ${driftY.toFixed(2)}px) scale(${breathe.toFixed(4)})`;

        // Warm overlay for THEIR syllables (cream at 0–6% alpha) following far envelope
        const farEnv = Math.max(evalVoiceEnvelope(t, SYLLABLES_S9), evalVoiceEnvelope(t, SYLLABLES_H2));
        el.portraitLeftOverlay.style.opacity = (farEnv * 0.06).toFixed(4);

        if (el.portraitRightInner) {
          const driftXR = Math.cos(2 * Math.PI * (t - 26.0) / 4.8) * 2.0;
          const driftYR = Math.sin(2 * Math.PI * (t - 26.0) / 5.5) * 2.0;
          el.portraitRightInner.style.transform = `translate(${driftXR.toFixed(2)}px, ${driftYR.toFixed(2)}px) scale(${breathe.toFixed(4)})`;
        }
      }

      // Edge Bands
      const GREEN = [74, 222, 128];
      const BLUE = [96, 165, 250];

      if (t >= 29.0 && t <= 45.0) {
        el.edgeBandLeft.style.display = "block";

        let leftColor = GREEN;
        let rightColor = BLUE;
        let leftEnv = 0;
        let leftThickEnv = 0;
        let rightEnv = 0;
        let rightThickEnv = 0;

        if (t < 33.0) {
          leftColor = GREEN;
          leftEnv = evalVoiceEnvelope(t, SYLLABLES_S8);
          leftThickEnv = evalThicknessEnvelope(t, SYLLABLES_S8);
        } else if (t >= 33.0 && t < 35.8) {
          leftColor = kfColor(t, [[33.0, GREEN], [33.4, BLUE]], easeEntrance);
          leftEnv = evalVoiceEnvelope(t, SYLLABLES_S9);
          leftThickEnv = evalThicknessEnvelope(t, SYLLABLES_S9);
        } else if (t >= 35.8 && t < 37.0) {
          leftColor = BLUE;
          rightColor = kfColor(t, [[35.8, BLUE], [36.2, GREEN]], easeEntrance);
          rightEnv = evalVoiceEnvelope(t, SYLLABLES_H1);
          rightThickEnv = evalThicknessEnvelope(t, SYLLABLES_H1);
        } else if (t >= 37.0) {
          leftColor = kfColor(t, [[37.0, BLUE], [37.4, GREEN]], easeEntrance);
          rightColor = kfColor(t, [[37.0, GREEN], [37.4, BLUE]], easeEntrance);
          leftEnv = evalVoiceEnvelope(t, SYLLABLES_H2);
          leftThickEnv = evalThicknessEnvelope(t, SYLLABLES_H2);
        }

        updateEdgeBand(el.edgeBandLeft, leftColor, leftEnv, leftThickEnv);

        if (rightWindowOpacity > 0.01) {
          el.edgeBandRight.style.display = "block";
          updateEdgeBand(el.edgeBandRight, rightColor, rightEnv, rightThickEnv);
        }
      } else {
        el.edgeBandLeft.style.display = "none";
        el.edgeBandRight.style.display = "none";
      }

    } else {
      el.act2Container.style.display = "none";
    }

    // --- Story Copy Animation (§4 & §5) ---
    let activeCopy = null;
    for (let i = 0; i < COPY_SEGMENTS.length; i++) {
      const seg = COPY_SEGMENTS[i];
      if (t >= seg.start && t < seg.end) {
        activeCopy = seg;
        break;
      }
    }

    if (activeCopy) {
      const targetEl = (activeCopy.pos === "side") ? el.copySide : el.copyCenter;
      const otherEl = (activeCopy.pos === "side") ? el.copyCenter : el.copySide;

      otherEl.style.opacity = "0";

      const tIn = 0.5;
      const tOut = 0.4;
      const dur = activeCopy.end - activeCopy.start;
      const relT = t - activeCopy.start;

      let opacity = 0;
      let yRise = 12;

      if (relT < tIn) {
        const u = relT / tIn;
        const e = easeEntrance(u);
        opacity = e;
        yRise = 12 * (1 - e);
      } else if (relT > dur - tOut) {
        const u = (activeCopy.end - t) / tOut;
        const e = easeEntrance(clamp(u, 0, 1));
        opacity = e;
        yRise = 0;
      } else {
        opacity = 1.0;
        yRise = 0;
      }

      targetEl.textContent = activeCopy.text;
      targetEl.style.fontSize = `${activeCopy.size}px`;
      targetEl.style.color = activeCopy.color || "#f3f1ec";
      targetEl.style.opacity = opacity.toFixed(3);
      targetEl.style.transform = `translateY(calc(-50% + ${yRise.toFixed(1)}px))`;

      if (activeCopy.pos === "center") {
        if (t < 15.0) {
          targetEl.style.top = "720px";
        } else if (t >= 35.5 && t < 38.0) {
          targetEl.style.top = "850px";
        } else if (t >= 38.0 && t < 45.0) {
          targetEl.style.top = "360px";
        } else if (t >= 45.0 && t <= 58.0) {
          targetEl.style.top = "930px";
        } else if (t > 58.0 && t < 63.0) {
          targetEl.style.top = "660px";
        } else {
          targetEl.style.top = "50%";
        }
      } else {
        targetEl.style.top = "50%";
      }
    } else {
      el.copyCenter.style.opacity = "0";
      el.copySide.style.opacity = "0";
    }

    // --- Act IV Reveal & CTA Stack (63.0 to 75.0s) ---
    if (t >= 63.0) {
      el.act4Container.style.display = "block";
      const act4Alpha = kf(t, [[63.0, 0], [64.0, 1], [74.2, 1], [75.0, 0]]);
      el.act4Container.style.opacity = act4Alpha.toFixed(3);

      // "Kin" 140px centered at y=690 (cap top ≈ 590) rises at 64.0
      const wmRise = kf(t, [[64.0, 0], [65.0, 1]], easeEntrance);
      el.act4Wordmark.style.opacity = wmRise.toFixed(3);
      const wmY = 18 * (1 - wmRise);
      el.act4Wordmark.style.transform = `translateY(${wmY.toFixed(1)}px)`;

      // tagline italic 40px at y=770 rises at 65.2
      const tlRise = kf(t, [[65.2, 0], [66.0, 1]], easeEntrance);
      el.act4Tagline.style.opacity = tlRise.toFixed(3);
      const tlY = 14 * (1 - tlRise);
      el.act4Tagline.style.transform = `translateY(${tlY.toFixed(1)}px)`;

      // In S15 the whole group (orbs + wordmark + tagline) scales to 0.7 around (960, 520)
      // and rises so orbs' center lands at y=300 (dy = -136px)
      const s15Progress = kf(t, [[68.0, 0], [69.2, 1.0]], easeEntrance);
      const scaleS15 = 1.0 - 0.30 * s15Progress;
      const dy = -136 * s15Progress;
      el.act4Group.style.transform = `translate(0px, ${dy.toFixed(2)}px) scale(${scaleS15.toFixed(4)})`;

      // CTA lines: "Free on Mac today." at y=700, "kin.tokkah.com" at y=760,
      // "Not on a Mac yet? Leave your name — you'll be first." at y=815.
      const ctaAlpha = kf(t, [[68.0, 0], [68.8, 1]], easeEntrance);
      el.act4Cta.style.opacity = ctaAlpha.toFixed(3);
      const ctaY = 12 * (1 - ctaAlpha);
      el.act4Cta.style.transform = `translateY(${ctaY.toFixed(1)}px)`;
    } else {
      el.act4Container.style.display = "none";
    }

    // --- Progress Bar ---
    const progress = clamp(t / DURATION, 0, 1);
    el.progressFill.style.width = `${(progress * 100).toFixed(2)}%`;
  }

  // --- Master Deterministic render(t) ---
  let _currentT = 0;

  function render(t) {
    _currentT = clamp(t, 0, DURATION);
    renderRipples(_currentT);
    updateDomScenes(_currentT);
    renderGlobe(_currentT);
    renderGrain(_currentT);
  }

  // --- Live Player Controls & Audio State ---
  let _playing = false;
  let _muted = false;
  let _atRestBeforePlay = false;
  let _liveAudioCtx = null;
  let _liveScoreNodes = null;
  let _rafId = null;
  let _lastRafTime = 0;

  function startLiveAudio() {
    if (_muted) return;
    try {
      if (!_liveAudioCtx) {
        const AudioCtx = window.AudioContext || window.webkitAudioContext;
        if (AudioCtx) {
          _liveAudioCtx = new AudioCtx();
        }
      }
      if (_liveAudioCtx && _liveAudioCtx.state === "suspended") {
        _liveAudioCtx.resume();
      }
      if (_liveAudioCtx && !_liveScoreNodes) {
        _liveScoreNodes = buildScoreGraph(_liveAudioCtx, _liveAudioCtx.currentTime - _currentT, false);
      }
    } catch (err) {
      console.warn("Audio start error:", err);
    }
  }

  function stopLiveAudio() {
    if (_liveAudioCtx) {
      try {
        _liveAudioCtx.close();
      } catch (e) {}
      _liveAudioCtx = null;
      _liveScoreNodes = null;
    }
  }

  function play() {
    if (_playing) return;
    if (_atRestBeforePlay) {
      _atRestBeforePlay = false;
      if (el.restDimOverlay) el.restDimOverlay.style.display = "none";
      _currentT = 0;
      render(0);
    }
    _playing = true;
    el.playButtonOverlay.style.display = "none";
    el.replayButton.style.display = "none";
    _lastRafTime = performance.now();
    startLiveAudio();

    function loop(now) {
      if (!_playing) return;
      const dt = (now - _lastRafTime) / 1000.0;
      _lastRafTime = now;

      let nextT = _currentT + dt;
      if (nextT >= DURATION) {
        if (isLoop) {
          nextT = 0;
          stopLiveAudio();
          startLiveAudio();
          render(nextT);
        } else {
          pause();
          // Seek to 73.8 (the CTA still visible) and show replay control instead of ending on black
          render(73.8);
          _currentT = 73.8;
          el.replayButton.style.display = "block";
          return;
        }
      } else {
        render(nextT);
      }
      _rafId = requestAnimationFrame(loop);
    }
    _rafId = requestAnimationFrame(loop);
  }

  function pause() {
    _playing = false;
    if (_rafId) {
      cancelAnimationFrame(_rafId);
      _rafId = null;
    }
    stopLiveAudio();
  }

  function toggle() {
    if (_playing) pause();
    else play();
  }

  function setMuted(m) {
    _muted = !!m;
    if (_muted) {
      stopLiveAudio();
      el.volumeWaves.style.display = "none";
    } else {
      el.volumeWaves.style.display = "block";
      if (_playing) startLiveAudio();
    }
  }

  // --- Query Flags Parsing (§7) ---
  const params = new URLSearchParams(window.location.search);
  const isRender = params.get("render") === "1" || params.has("render");
  const isAutoplay = params.get("autoplay") === "1";
  const isMuted = params.get("muted") === "1";
  const isLoop = params.get("loop") === "1";
  const targetT = params.get("t") ? parseFloat(params.get("t")) : 0;

  // --- Public API Contract on window.kinAd (§7) ---
  window.kinAd = {
    duration: DURATION,
    get time() {
      return _currentT;
    },
    play,
    pause,
    toggle,
    setMuted,
    transcript: TRANSCRIPT,

    // seek(t): renders frame and resolves AFTER double requestAnimationFrame
    seek(t) {
      pause();
      if (_atRestBeforePlay) {
        _atRestBeforePlay = false;
        if (el.restDimOverlay) el.restDimOverlay.style.display = "none";
      }
      el.replayButton.style.display = "none";
      render(t);
      return new Promise(resolve => {
        requestAnimationFrame(() => {
          requestAnimationFrame(() => {
            resolve();
          });
        });
      });
    },

    // renderScoreOffline(sampleRate = 48000): builds score in OfflineAudioContext
    async renderScoreOffline(sampleRate = 48000) {
      const totalSamples = Math.ceil(DURATION * sampleRate);
      const offlineCtx = new OfflineAudioContext(2, totalSamples, sampleRate);
      buildScoreGraph(offlineCtx, 0, true);
      const rendered = await offlineCtx.startRendering();
      return [rendered.getChannelData(0), rendered.getChannelData(1)];
    }
  };

  // --- Initialization on Load ---
  window.addEventListener("DOMContentLoaded", () => {
    cacheElements();
    setupDomTemplates();
    initGrain();
    updateStageScale();

    if (isMuted) {
      setMuted(true);
    }

    if (isRender) {
      el.playerControls.style.display = "none";
    } else {
      el.playButtonOverlay.addEventListener("click", e => {
        e.stopPropagation();
        play();
      });

      el.stage.addEventListener("click", e => {
        if (e.target.closest("#mute-toggle") || e.target.closest("#replay-button")) return;
        toggle();
      });

      el.progressHairline.addEventListener("click", e => {
        e.stopPropagation();
        const rect = el.progressHairline.getBoundingClientRect();
        const frac = clamp((e.clientX - rect.left) / rect.width, 0, 1);
        const seekTime = frac * DURATION;
        window.kinAd.seek(seekTime);
        if (_playing) startLiveAudio();
      });

      el.muteToggle.addEventListener("click", e => {
        e.stopPropagation();
        setMuted(!_muted);
      });

      el.replayButton.addEventListener("click", e => {
        e.stopPropagation();
        el.replayButton.style.display = "none";
        window.kinAd.seek(0).then(() => play());
      });
    }

    const initialT = (targetT > 0 && !isNaN(targetT)) ? targetT : 0;

    if (!isRender && !isAutoplay && initialT === 0) {
      // Live mode at rest before play: render t = 64.8 (the reveal), dim with 45% black overlay, show play control
      _atRestBeforePlay = true;
      render(64.8);
      _currentT = 64.8;
      if (el.restDimOverlay) el.restDimOverlay.style.display = "block";
      el.playButtonOverlay.style.display = "flex";
      el.replayButton.style.display = "none";
    } else {
      render(initialT);
    }

    if (isAutoplay && !isRender) {
      play();
    }
  });

})();
