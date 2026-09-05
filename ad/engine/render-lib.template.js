/**
 * Ad engine — the render library. Data-driven: reads the ad spec from
 * <script type="application/json" id="ad-spec"> and renders it as a pure
 * function of time. Same contract as the flagship film (window.kinAd with
 * seek / play / pause / renderScoreOffline), so ad/render.mjs renders it.
 *
 * Primitives: title, glow, shape, portrait, duo, planet, mark, cta.
 * Three canvases (scene, light, grain); DOM owns type and window chrome.
 */
(function() {
  "use strict";

  // ---------------------------------------------------------------- spec
  const SPEC = JSON.parse(document.getElementById("ad-spec").textContent);
  const DURATION = +SPEC.duration || 40;
  const W = 1920, H = 1080;
  const hexToRgb = h => { const s = (h || "").replace("#", ""); return s.length === 6 ? [parseInt(s.slice(0, 2), 16), parseInt(s.slice(2, 4), 16), parseInt(s.slice(4, 6), 16)] : null; };
  const PAL = SPEC.palette || {};
  const GROUND = hexToRgb(PAL.ground) || [5, 6, 10];
  const INK = hexToRgb(PAL.ink) || [243, 241, 236];
  const ACCENT_A = hexToRgb(PAL.accentA) || [74, 222, 128];
  const ACCENT_B = hexToRgb(PAL.accentB) || [96, 165, 250];
  const MUTED = [154, 163, 178];
  const colorOf = name => name === "A" || name === "green" ? ACCENT_A : name === "B" || name === "blue" ? ACCENT_B : name === "muted" ? MUTED : INK;

  // ---------------------------------------------------------------- helpers
  const rgba = (c, a) => `rgba(${Math.round(c[0])},${Math.round(c[1])},${Math.round(c[2])},${a})`;
  const mix = (a, b, u) => [a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u, a[2] + (b[2] - a[2]) * u];
  const hex = c => `rgb(${Math.round(c[0])},${Math.round(c[1])},${Math.round(c[2])})`;
  const clamp = (v, lo, hi) => v < lo ? lo : (v > hi ? hi : v);
  const lerp = (a, b, u) => a + (b - a) * u;
  function cubicBezier(p1x, p1y, p2x, p2y) {
    const cx = 3 * p1x, bx = 3 * (p2x - p1x) - cx, ax = 1 - cx - bx;
    const cy = 3 * p1y, by = 3 * (p2y - p1y) - cy, ay = 1 - cy - by;
    const X = t => ((ax * t + bx) * t + cx) * t, Y = t => ((ay * t + by) * t + cy) * t, DX = t => (3 * ax * t + 2 * bx) * t + cx;
    return x => { if (x <= 0) return 0; if (x >= 1) return 1; let t = x; for (let i = 0; i < 8; i++) { const e = X(t) - x; if (Math.abs(e) < 1e-5) return Y(t); const d = DX(t); if (Math.abs(d) < 1e-6) break; t -= e / d; } return Y(clamp(t, 0, 1)); };
  }
  const easeIn = cubicBezier(0.2, 0.7, 0.2, 1.0);
  const easeMark = cubicBezier(0.16, 0.75, 0.18, 1.0);
  const easeSine = u => 0.5 - 0.5 * Math.cos(Math.PI * u);
  const linear = u => u;
  const span = (t, a, b, ease = easeIn) => ease(clamp((t - a) / (b - a), 0, 1));
  function kf(t, pts, ease = linear) {
    if (t <= pts[0][0]) return pts[0][1];
    const n = pts.length; if (t >= pts[n - 1][0]) return pts[n - 1][1];
    for (let i = 0; i < n - 1; i++) { const [t0, v0] = pts[i], [t1, v1] = pts[i + 1]; if (t >= t0 && t <= t1) return v0 + (v1 - v0) * ease(t1 === t0 ? 0 : (t - t0) / (t1 - t0)); }
    return pts[n - 1][1];
  }
  function mulberry32(a) { return function() { let t = a += 0x6D2B79F5; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
  function offscreen(w, h) { const c = document.createElement("canvas"); c.width = w; c.height = h; return c; }

  // ---------------------------------------------------------------- flags / DOM
  const Q = new URLSearchParams(window.location.search);
  const isRender = Q.has("render"), isAutoplay = Q.get("autoplay") === "1", isMutedFlag = Q.get("muted") === "1", isLoop = Q.get("loop") === "1";
  const targetT = Q.has("t") ? parseFloat(Q.get("t")) : NaN;
  const reducedMotion = !isRender && window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const CANVAS_SCALE = (() => { if (isRender) return 1; const s = Math.min(window.screen.width || W, window.screen.height || H); return (s < 700 || /Mobi|Android/i.test(navigator.userAgent)) ? 0.5 : 1; })();
  const el = {};
  const $ = id => document.getElementById(id);
  function fitCanvas(c) { c.width = Math.round(W * CANVAS_SCALE); c.height = Math.round(H * CANVAS_SCALE); const ctx = c.getContext("2d"); ctx.setTransform(CANVAS_SCALE, 0, 0, CANVAS_SCALE, 0, 0); return ctx; }
  function cacheElements() {
    el.stage = $("stage"); el.scene = fitCanvas($("c-scene")); el.light = fitCanvas($("c-light"));
    el.grainCanvas = $("c-grain"); el.grain = el.grainCanvas.getContext("2d");
    el.winA = $("win-a"); el.winB = $("win-b");
    el.copy = { center: $("copy-center"), side: $("copy-side"), left: $("copy-left"), below: $("copy-below") };
    el.number = $("copy-number");
    el.markWrap = $("mark-wrap"); el.wordmark = $("mark-wordmark"); el.tagline = $("mark-tagline");
    el.cta = $("cta"); el.ctaLines = [$("cta-1"), $("cta-2"), $("cta-3")];
    el.controls = $("player-controls"); el.playBtn = $("play-button"); el.progress = $("progress-hairline"); el.progressFill = $("progress-fill");
    el.mute = $("mute-toggle"); el.volumeWaves = $("volume-waves"); el.replay = $("replay-button");
  }
  function fitStage() { if (!el.stage) return; const s = Math.min(window.innerWidth / W, window.innerHeight / H); el.stage.style.transform = `translate(-50%, -50%) scale(${s})`; }
  window.addEventListener("resize", fitStage);

  // ---------------------------------------------------------------- atlas (drawn once)
  const PW = 1024, PH = 768;
  const atlas = {};
  function buildGlow(color, size) {
    const c = offscreen(size, size), g = c.getContext("2d"), r = size / 2;
    const gr = g.createRadialGradient(r, r, 0, r, r, r);
    gr.addColorStop(0, rgba(color, 1)); gr.addColorStop(0.25, rgba(color, 0.55)); gr.addColorStop(0.6, rgba(color, 0.12)); gr.addColorStop(1, rgba(color, 0));
    g.fillStyle = gr; g.fillRect(0, 0, size, size); return c;
  }

  /*@@PORTRAIT@@*/

  /*@@MARK@@*/

  function buildAtlas() {
    atlas.them = buildPortrait("them"); atlas.you = buildPortrait("you");
    atlas.glowA = buildGlow(ACCENT_A, 256); atlas.glowB = buildGlow(ACCENT_B, 256); atlas.glowInk = buildGlow(INK, 256);
  }
  const glowSprite = c => c === ACCENT_A ? atlas.glowA : c === ACCENT_B ? atlas.glowB : atlas.glowInk;
  function drawGlow(ctx, sprite, x, y, size, alpha) { if (alpha <= 0.002) return; ctx.save(); ctx.globalAlpha = alpha; ctx.drawImage(sprite, x - size / 2, y - size / 2, size, size); ctx.restore(); }

  // Window content: square top corners under the title strip, 12 px bottom corners.
  let clipRadius = 0;
  function clipRect(ctx, x, y, w, h) { const r = clipRadius; if (r > 0 && ctx.roundRect) ctx.roundRect(x, y, w, h, [0, 0, r, r]); else ctx.rect(x, y, w, h); }
  function drawTile(ctx, tile, x, y, w, h, zoom = 1, dx = 0, dy = 0, alpha = 1) {
    const scale = Math.max(w / PW, h / PH) * zoom, dw = PW * scale, dh = PH * scale;
    const ox = x + (w - dw) / 2 + dx, oy = y + (h - dh) * 0.35 + dy;
    ctx.save(); ctx.globalAlpha = alpha; ctx.beginPath(); clipRect(ctx, x, y, w, h); ctx.clip(); ctx.drawImage(tile, ox, oy, dw, dh); ctx.restore();
  }

  // The edge band: mitred strips from distance-to-edge, clipped to content.
  function edgeBand(ctx, x, y, w, h, color, opacity, depth) {
    if (opacity <= 0) return;
    const stops = []; for (let i = 0; i <= 8; i++) { const u = i / 8; stops.push([u, 0.72 * Math.pow(1 - u, 2.2)]); }
    const grad = (x0, y0, x1, y1) => { const g = ctx.createLinearGradient(x0, y0, x1, y1); for (const [u, a] of stops) g.addColorStop(u, rgba(color, a)); return g; };
    const d = Math.min(depth, w / 2, h / 2);
    ctx.save(); ctx.globalAlpha = opacity; ctx.beginPath(); clipRect(ctx, x, y, w, h); ctx.clip();
    ctx.fillStyle = grad(0, y, 0, y + d); ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x + w, y); ctx.lineTo(x + w - d, y + d); ctx.lineTo(x + d, y + d); ctx.closePath(); ctx.fill();
    ctx.fillStyle = grad(0, y + h, 0, y + h - d); ctx.beginPath(); ctx.moveTo(x, y + h); ctx.lineTo(x + w, y + h); ctx.lineTo(x + w - d, y + h - d); ctx.lineTo(x + d, y + h - d); ctx.closePath(); ctx.fill();
    ctx.fillStyle = grad(x, 0, x + d, 0); ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x + d, y + d); ctx.lineTo(x + d, y + h - d); ctx.lineTo(x, y + h); ctx.closePath(); ctx.fill();
    ctx.fillStyle = grad(x + w, 0, x + w - d, 0); ctx.beginPath(); ctx.moveTo(x + w, y); ctx.lineTo(x + w - d, y + d); ctx.lineTo(x + w - d, y + h - d); ctx.lineTo(x + w, y + h); ctx.closePath(); ctx.fill();
    ctx.strokeStyle = rgba(color, 0.95); ctx.lineWidth = 1.5; ctx.beginPath(); clipRect(ctx, x + 0.75, y + 0.75, w - 1.5, h - 1.5); ctx.stroke();
    ctx.restore();
  }

  // Voice envelope from authored syllable events [onset, peak]: 90 ms attack, 260 ms release.
  const SYL = [[0.00, 0.45], [0.30, 0.70], [0.61, 0.52], [0.91, 0.84], [1.29, 0.60], [1.64, 0.42], [1.99, 0.67], [2.32, 0.34]];
  function voiceEnv(tl, at) { let e = 0; for (const [o, pk] of SYL) { const dt = tl - (at + o); if (dt < 0 || dt > 1.2) continue; const v = dt < 0.09 ? dt / 0.09 : Math.exp(-(dt - 0.09) / 0.26); if (v * pk > e) e = v * pk; } return e; }
  function thickEnv(tl, at) { let e = 0; for (const [o, pk] of SYL) { const dt = tl - (at + o); if (dt < 0 || dt > 4) continue; const v = dt < 0.45 ? dt / 0.45 : Math.exp(-(dt - 0.45) / 1.2); if (v * pk > e) e = v * pk; } return e; }

  // ---------------------------------------------------------------- planet
  function unit(lat, lon) { const p = lat * Math.PI / 180, l = lon * Math.PI / 180; return [Math.cos(p) * Math.sin(l), Math.sin(p), Math.cos(p) * Math.cos(l)]; }
  function slerp(a, b, s) { const d = clamp(a[0] * b[0] + a[1] * b[1] + a[2] * b[2], -1, 1), om = Math.acos(d); if (om < 1e-5) return a; const so = Math.sin(om), c1 = Math.sin((1 - s) * om) / so, c2 = Math.sin(s * om) / so; return [c1 * a[0] + c2 * b[0], c1 * a[1] + c2 * b[1], c1 * a[2] + c2 * b[2]]; }
  function makeCamera(lat0, lon0) { const L = lon0 * Math.PI / 180, A = lat0 * Math.PI / 180, cL = Math.cos(L), sL = Math.sin(L), cA = Math.cos(A), sA = Math.sin(A); return v => { const x = v[0] * cL - v[2] * sL, z0 = v[0] * sL + v[2] * cL, y = v[1]; return { x, y: y * cA - z0 * sA, z: y * sA + z0 * cA }; }; }
  const LAND = [
    [[-168,66],[-162,70],[-140,70],[-125,72],[-110,73],[-95,72],[-85,70],[-80,66],[-70,62],[-64,60],[-60,55],[-56,52],[-65,48],[-70,44],[-75,38],[-80,32],[-81,25],[-83,29],[-90,30],[-97,27],[-97,22],[-92,18],[-87,16],[-83,10],[-79,8],[-84,10],[-88,14],[-95,16],[-105,20],[-110,24],[-113,30],[-118,34],[-124,40],[-124,48],[-130,54],[-140,60],[-150,60],[-158,58],[-165,62]],
    [[-45,60],[-40,65],[-22,70],[-20,76],[-30,82],[-55,82],[-70,78],[-60,72],[-52,66]],
    [[-79,8],[-72,12],[-62,10],[-52,5],[-50,0],[-44,-2],[-35,-6],[-35,-10],[-39,-15],[-41,-22],[-48,-26],[-53,-33],[-58,-38],[-65,-42],[-68,-50],[-68,-55],[-72,-52],[-75,-45],[-73,-38],[-71,-30],[-70,-20],[-76,-14],[-81,-6],[-80,0],[-78,5]],
    [[-17,15],[-17,21],[-10,30],[-5,36],[10,37],[20,32],[32,31],[35,25],[38,18],[43,12],[51,11],[48,5],[41,-2],[40,-10],[36,-18],[35,-25],[32,-29],[27,-34],[19,-35],[15,-28],[12,-18],[13,-10],[9,-1],[9,4],[3,6],[-8,5],[-14,8],[-17,12]],
    [[44,-25],[50,-16],[49,-12],[44,-20]],
    [[-9,37],[-9,43],[-2,44],[-5,48],[0,50],[8,54],[8,57],[12,56],[10,59],[5,62],[13,66],[20,70],[30,70],[45,68],[60,70],[75,73],[90,76],[110,77],[130,72],[150,70],[170,69],[180,66],[176,62],[163,59],[160,55],[157,50],[142,52],[140,46],[135,44],[128,40],[121,38],[122,30],[117,23],[109,20],[106,10],[104,2],[101,6],[99,14],[94,17],[88,22],[80,15],[77,8],[73,20],[67,24],[57,25],[60,22],[53,24],[44,12],[38,18],[35,25],[32,31],[27,36],[29,41],[40,41],[42,45],[35,45],[30,45],[28,42],[20,40],[14,44],[12,38],[8,44],[3,43],[-1,37]],
    [[-5,50],[1,51],[2,53],[-2,56],[-5,58],[-6,56],[-3,54],[-5,52]],
    [[130,32],[135,34],[140,36],[142,40],[141,45],[144,44],[142,42],[140,38],[137,35],[132,33]],
    [[95,5],[104,-4],[106,-6],[102,-2],[98,2]], [[109,1],[117,7],[119,1],[116,-4],[110,-3]], [[131,-1],[141,-2],[150,-10],[141,-9],[135,-4]],
    [[114,-22],[114,-34],[118,-35],[124,-33],[131,-31],[138,-35],[141,-38],[147,-39],[150,-37],[153,-30],[153,-25],[146,-19],[142,-11],[136,-12],[131,-12],[126,-14],[122,-18]],
    [[166,-46],[171,-42],[174,-36],[178,-38],[174,-41],[169,-46]]
  ];
  { const cap = []; for (let lon = -180; lon <= 180; lon += 10) cap.push([lon, -71 + 2 * Math.sin(lon / 30)]); LAND.push(cap); }
  const LAND_V = LAND.map(poly => { const out = []; for (let i = 0; i < poly.length; i++) { const a = unit(poly[i][1], poly[i][0]), bp = poly[(i + 1) % poly.length], b = unit(bp[1], bp[0]); const ang = Math.acos(clamp(a[0] * b[0] + a[1] * b[1] + a[2] * b[2], -1, 1)); const n = Math.max(1, Math.ceil(ang / (3 * Math.PI / 180))); for (let k = 0; k < n; k++) out.push(slerp(a, b, k / n)); } return out; });
  const GAZETTEER = { DELHI: [28.6139, 77.2090], AMSTERDAM: [52.3676, 4.9041], TOKYO: [35.6762, 139.6503], SYDNEY: [-33.8688, 151.2093], "SÃO PAULO": [-23.5505, -46.6333], "SAO PAULO": [-23.5505, -46.6333], LAGOS: [6.5244, 3.3792], NAIROBI: [-1.2921, 36.8219], LONDON: [51.5074, -0.1278], "NEW YORK": [40.7128, -74.0060], "SAN FRANCISCO": [37.7749, -122.4194], SEATTLE: [47.6062, -122.3321], TORONTO: [43.6532, -79.3832], "MEXICO CITY": [19.4326, -99.1332], "BUENOS AIRES": [-34.6037, -58.3816], "CAPE TOWN": [-33.9249, 18.4241], CAIRO: [30.0444, 31.2357], DUBAI: [25.2048, 55.2708], MUMBAI: [19.0760, 72.8777], SINGAPORE: [1.3521, 103.8198], JAKARTA: [-6.2088, 106.8456], SEOUL: [37.5665, 126.9780], BERLIN: [52.5200, 13.4050], PARIS: [48.8566, 2.3522], LOS_ANGELES: [34.0522, -118.2437], "LOS ANGELES": [34.0522, -118.2437], BANGALORE: [12.9716, 77.5946], BENGALURU: [12.9716, 77.5946], "HONG KONG": [22.3193, 114.1694], SHANGHAI: [31.2304, 121.4737], MADRID: [40.4168, -3.7038], ROME: [41.9028, 12.4964], STOCKHOLM: [59.3293, 18.0686], AUCKLAND: [-36.8485, 174.7633], JOHANNESBURG: [-26.2041, 28.0473], CHICAGO: [41.8781, -87.6298], VANCOUVER: [49.2827, -123.1207], LISBON: [38.7223, -9.1393], ISTANBUL: [41.0082, 28.9784] };
  const city = name => { const k = String(name || "").toUpperCase().trim(); const c = GAZETTEER[k]; return { name: k || "DELHI", v: unit(...(c || GAZETTEER.DELHI)), lat: (c || GAZETTEER.DELHI)[0], lon: (c || GAZETTEER.DELHI)[1] }; };
  function makeRoute(a, b, lift) { const s = []; for (let i = 0; i <= 96; i++) { const u = i / 96, v = slerp(a, b, u), l = 1 + lift * Math.sin(Math.PI * u); s.push([v[0] * l, v[1] * l, v[2] * l]); } return s; }
  let plate = null;
  function buildPlate() {
    const N = 1024, c = offscreen(N, N), g = c.getContext("2d"), img = g.createImageData(N, N), d = img.data;
    const L = [-0.62, -0.30, 0.72], ll = Math.hypot(...L); L[0] /= ll; L[1] /= ll; L[2] /= ll;
    for (let j = 0; j < N; j++) for (let i = 0; i < N; i++) {
      const x = (i + 0.5) / (N / 2) - 1, y = (j + 0.5) / (N / 2) - 1, r2 = x * x + y * y, o = (j * N + i) * 4;
      if (r2 > 1) { d[o] = d[o + 1] = d[o + 2] = 0; d[o + 3] = 255; continue; }
      const z = Math.sqrt(1 - r2), nd = x * L[0] + (-y) * L[1] + z * L[2], term = 0.5 + 0.5 * Math.tanh(nd * 3.2);
      const v = Math.round(255 * clamp(0.16 + 0.84 * Math.pow(term, 1.1) * (0.55 + 0.45 * Math.max(0, nd)), 0, 1));
      d[o] = d[o + 1] = d[o + 2] = v; d[o + 3] = 255;
    }
    g.putImageData(img, 0, 0); plate = c;
  }
  function drawPlanet(ctx, cam, cx, cy, R, alpha) {
    if (alpha <= 0.002) return;
    const ocean = mix(GROUND, MUTED, 0.12), land = mix(GROUND, MUTED, 0.24);
    ctx.save(); ctx.globalAlpha = alpha; ctx.beginPath(); ctx.arc(cx, cy, R, 0, Math.PI * 2); ctx.clip();
    ctx.fillStyle = hex(ocean); ctx.fillRect(cx - R, cy - R, 2 * R, 2 * R);
    ctx.fillStyle = hex(land);
    for (const poly of LAND_V) { ctx.beginPath(); let st = false; for (const v of poly) { const p = cam(v); let x = p.x, y = p.y; if (p.z < 0) { const m = Math.hypot(x, y) || 1; x /= m; y /= m; } const sx = cx + R * x, sy = cy - R * y; if (!st) { ctx.moveTo(sx, sy); st = true; } else ctx.lineTo(sx, sy); } ctx.closePath(); ctx.fill(); }
    if (plate) { ctx.globalCompositeOperation = "multiply"; ctx.drawImage(plate, cx - R, cy - R, 2 * R, 2 * R); ctx.globalCompositeOperation = "source-over"; }
    ctx.restore();
    ctx.save(); ctx.globalAlpha = alpha;
    const lg = ctx.createLinearGradient(cx - R, cy - R, cx + R * 0.8, cy + R * 0.8); lg.addColorStop(0, rgba(INK, 0.38)); lg.addColorStop(0.6, rgba(INK, 0.16)); lg.addColorStop(1, rgba(INK, 0.08));
    ctx.strokeStyle = lg; ctx.lineWidth = 1.25; ctx.beginPath(); ctx.arc(cx, cy, R, 0, Math.PI * 2); ctx.stroke();
    const og = ctx.createRadialGradient(cx, cy, R, cx, cy, R + 10); og.addColorStop(0, rgba(INK, 0.09)); og.addColorStop(1, rgba(INK, 0));
    ctx.fillStyle = og; ctx.beginPath(); ctx.arc(cx, cy, R + 10, 0, Math.PI * 2); ctx.arc(cx, cy, R, 0, Math.PI * 2, true); ctx.fill();
    ctx.restore();
  }
  function projectSample(cam, s, cx, cy, R) { const p = cam(s); return { x: cx + R * p.x, y: cy - R * p.y, z: p.z, vis: p.z > 0 || Math.hypot(p.x, p.y) > 1.0 }; }
  function drawRoute(ctx, cam, samples, u0, u1, cx, cy, R, color, alpha, width) {
    if (alpha <= 0.002 || u1 <= u0) return;
    const i0 = Math.floor(u0 * 96), i1 = Math.ceil(u1 * 96);
    ctx.save(); ctx.lineCap = "round";
    for (const [w, a] of [[width + 3.25, 0.07], [width, 1]]) {
      ctx.strokeStyle = rgba(color, alpha * a); ctx.lineWidth = w; ctx.beginPath(); let pen = false;
      for (let i = Math.max(0, i0); i <= Math.min(96, i1); i++) { const p = projectSample(cam, samples[i], cx, cy, R); if (!p.vis) { pen = false; continue; } if (!pen) { ctx.moveTo(p.x, p.y); pen = true; } else ctx.lineTo(p.x, p.y); }
      ctx.stroke();
    }
    ctx.restore();
  }

  // ---------------------------------------------------------------- geometry
  const TITLE = 44;
  const WIN = { x: 120, y: 156, w: 1008, h: 744 };        // window left, copy right
  const WINC = { x: 456, y: 156, w: 1008, h: 744 };       // window centred (no copy)
  const D_L = { x: 120, y: 204, w: 804, h: 594 }, D_R = { x: 996, y: 204, w: 804, h: 594 };
  const content = r => { const s = r.w / WIN.w; return { x: r.x, y: r.y + TITLE * s, w: r.w, h: r.h - TITLE * s, s }; };
  function placeWin(node, r, alpha) { if (alpha <= 0.002) { node.style.display = "none"; return; } node.style.display = "block"; node.style.transform = `translate(${r.x.toFixed(2)}px, ${r.y.toFixed(2)}px) scale(${(r.w / WIN.w).toFixed(4)})`; node.style.opacity = alpha.toFixed(3); }
  const breathe = (t, period = 4.6, phase = 0) => 1 + 0.004 * (0.5 + 0.5 * Math.sin(2 * Math.PI * (t / period) + phase));

  // ---------------------------------------------------------------- shots
  const SHOTS = (SPEC.shots || []).slice().sort((a, b) => a.start - b.start);
  function activeShot(t) { for (let i = 0; i < SHOTS.length; i++) { const s = SHOTS[i]; if (t >= s.start && (t < s.end || i === SHOTS.length - 1)) return { s, i }; } return { s: SHOTS[0], i: 0 }; }
  // enter/exit fades at shot boundaries (skipped when the neighbour is the same primitive)
  function shotAlpha(i, t) {
    const s = SHOTS[i], prev = SHOTS[i - 1], next = SHOTS[i + 1];
    let a = 1;
    if (!prev || prev.primitive !== s.primitive) a *= span(t, s.start, s.start + 0.5, linear);
    if (next && next.primitive !== s.primitive) a *= 1 - span(t, s.end - 0.4, s.end, linear);
    if (!next) a *= 1 - span(t, DURATION - 0.8, DURATION, linear);
    return a;
  }

  // per-frame DOM state, reset each frame then set by primitives
  let dom;
  function resetDom() {
    dom = { winA: null, winB: null, copy: {}, number: null, mark: null, cta: null };
  }

  // ---- title: kinetic type only
  function pTitle(s, tl, t, a) {
    const size = clamp(+s.params.size || 88, 40, 140);
    dom.copy.center = { text: s.params.copy || s.copy || "", size, y: 540 - size * 0.55, tIn: s.start + 0.2, tOut: s.end - 0.3, sub: s.params.sub };
  }
  // ---- glow: a light field whose intensity ramps across the shot
  function pGlow(s, tl, t, a) {
    const p = s.params, col = colorOf(p.color || "A");
    const u = span(t, s.start, s.end, p.curve === "linear" ? linear : easeSine);
    const from = clamp(+p.from ?? 0, 0, 1), to = clamp(+p.to ?? 1, 0, 1);
    const k = lerp(from, to, u);
    const x = W * clamp(+p.x ?? 0.5, 0, 1), y = H * clamp(+p.y ?? 0.5, 0, 1), r = clamp(+p.radius || 520, 80, 1600);
    const ctx = el.scene;
    ctx.save(); ctx.globalAlpha = a;
    const g = ctx.createRadialGradient(x, y, 0, x, y, r);
    g.addColorStop(0, rgba(col, 0.85 * k)); g.addColorStop(0.35, rgba(col, 0.42 * k)); g.addColorStop(0.75, rgba(col, 0.08 * k)); g.addColorStop(1, rgba(col, 0));
    ctx.fillStyle = g; ctx.fillRect(x - r, y - r, 2 * r, 2 * r);
    const h = ctx.createRadialGradient(x, y, r * 0.6, x, y, r * 1.8);
    h.addColorStop(0, rgba(col, 0.06 * k)); h.addColorStop(1, rgba(col, 0));
    ctx.fillStyle = h; ctx.fillRect(x - r * 1.8, y - r * 1.8, 3.6 * r, 3.6 * r);
    ctx.restore();
    if (s.copy) dom.copy.center = { text: s.copy, size: 72, y: 864, tIn: s.start + 0.4, tOut: s.end - 0.3 };
  }
  // ---- shape: an SVG path Astra wrote, in a 0..1000 box, with a motion preset
  const pathCache = new Map();
  function pShape(s, tl, t, a) {
    const p = s.params; if (!p.path) return;
    let P = pathCache.get(p.path); if (!P) { try { P = new Path2D(p.path); } catch (e) { P = new Path2D(); } pathCache.set(p.path, P); }
    const size = clamp(+p.size || 520, 60, 1000), sc = size / 1000;
    let x = W * clamp(+p.x ?? 0.5, 0, 1), y = H * clamp(+p.y ?? 0.5, 0, 1), alpha = 1, scale = 1;
    const motion = p.motion || "still";
    if (motion === "shudder") { const env = Math.exp(-Math.max(0, tl - 0.5) / 0.35) * span(tl, 0.5, 0.56, linear); x += Math.sin(tl * 95) * 7 * env; }
    else if (motion === "rise") { y += 40 * (1 - span(tl, 0, 1.2)); alpha = span(tl, 0, 0.9, linear); }
    else if (motion === "breathe") scale = 1 + 0.012 * Math.sin(2 * Math.PI * tl / 4.6);
    else if (motion === "drift") { x += Math.sin(tl * 0.5) * 12; y += Math.cos(tl * 0.37) * 8; }
    else if (motion === "fadein") alpha = span(tl, 0, 1.5, linear);
    const fill = p.fill && p.fill !== "none" ? colorOf(p.fill) : null;
    const stroke = p.stroke && p.stroke !== "none" ? colorOf(p.stroke) : null;
    const glow = clamp(+p.glow || 0, 0, 1);
    const ctx = el.scene;
    ctx.save(); ctx.globalAlpha = a * alpha;
    ctx.translate(x, y); ctx.scale(sc * scale, sc * scale); ctx.translate(-500, -500);
    if (glow > 0 && (fill || stroke)) { ctx.save(); ctx.shadowColor = rgba(fill || stroke, 0.9 * glow); ctx.shadowBlur = 90 * glow / sc; ctx.fillStyle = rgba(fill || stroke, 0.35 * glow); ctx.fill(P); ctx.restore(); }
    if (fill) { ctx.fillStyle = hex(fill); ctx.fill(P); }
    if (stroke) { ctx.strokeStyle = hex(stroke); ctx.lineWidth = (+p.strokeWidth || 6) / sc; ctx.lineJoin = "round"; ctx.lineCap = "round"; ctx.stroke(P); }
    ctx.restore();
    if (s.copy) dom.copy.center = { text: s.copy, size: 72, y: 864, tIn: s.start + 0.4, tOut: s.end - 0.3 };
  }
  // ---- portrait: one person in a window, edge light at the frame
  function pPortrait(s, tl, t, a) {
    const p = s.params, who = p.who === "you" ? "you" : "them";
    const r0 = s.copy ? WIN : WINC;
    const rise = span(tl, 0, 0.9);
    const r = { x: r0.x, y: r0.y + 24 * (1 - rise), w: r0.w, h: r0.h };
    const c = content(r);
    clipRadius = 12;
    drawTile(el.scene, atlas[who], c.x, c.y, c.w, c.h, breathe(t), Math.sin(2 * Math.PI * t / 9.1) * 2, Math.cos(2 * Math.PI * t / 7.3) * 1.5, a);
    const edge = p.edge && p.edge !== "none" ? colorOf(p.edge) : null;
    if (edge) {
      const at = 1.0 + 6.0 * Math.floor(Math.max(0, tl - 1.0) / 6.0);
      const env = voiceEnv(tl, at), th = thickEnv(tl, at);
      edgeBand(el.light, c.x, c.y, c.w, c.h, edge, (0.55 + 0.45 * env) * a * span(tl, 0.3, 0.8), 48 + 48 * th);
    }
    clipRadius = 0;
    dom.winA = { r, alpha: a };
    if (s.copy) dom.copy.side = { text: s.copy, size: 64, y: 410, tIn: s.start + 0.6, tOut: s.end - 0.3 };
  }
  // ---- duo: two windows, the floor passing back and forth
  function pDuo(s, tl, t, a) {
    const u = span(tl, 0, 1.2);
    const rL = { x: D_L.x - 36 * (1 - u), y: D_L.y, w: D_L.w, h: D_L.h }, rR = { x: D_R.x + 36 * (1 - u), y: D_R.y, w: D_R.w, h: D_R.h };
    const period = 2.4, k = Math.floor(Math.max(0, tl - 1.2) / period), hand = 1.2 + k * period, hu = span(tl, hand, hand + 0.4);
    const leftA = k % 2 === 0; // left holds the floor (accent A) on even turns
    const from = leftA ? ACCENT_B : ACCENT_A, to = leftA ? ACCENT_A : ACCENT_B;
    const cL = tl < 1.2 ? ACCENT_B : mix(from, to, hu), cR = tl < 1.2 ? ACCENT_A : mix(to, from, hu);
    const env = voiceEnv(tl, hand + 0.2), th = thickEnv(tl, hand + 0.2);
    for (const [r, who, col] of [[rL, "them", cL], [rR, "you", cR]]) {
      const c = content(r); clipRadius = 12 * c.s;
      drawTile(el.scene, atlas[who], c.x, c.y, c.w, c.h, breathe(t, who === "you" ? 5.1 : 4.6), 0, 0, a * u);
      edgeBand(el.light, c.x, c.y, c.w, c.h, col, (0.55 + 0.45 * env) * a * u, (48 + 48 * th) * c.s);
      clipRadius = 0;
    }
    dom.winA = { r: rL, alpha: a * u }; dom.winB = { r: rR, alpha: a * u };
    if (s.copy) dom.copy.center = { text: s.copy, size: 64, y: 864, tIn: s.start + 1.4, tOut: s.end - 0.3 };
  }
  // ---- planet: a lit planet, one route of light there and back, a number
  const routeCache = new Map();
  function pPlanet(s, tl, t, a) {
    const p = s.params, A = city(p.from || "DELHI"), B = city(p.to || "AMSTERDAM");
    const key = A.name + "|" + B.name; let route = routeCache.get(key); if (!route) { route = makeRoute(A.v, B.v, 0.04); routeCache.set(key, route); }
    let midLon = (A.lon + B.lon) / 2; if (Math.abs(A.lon - B.lon) > 180) midLon += 180;
    const cam = makeCamera(clamp((A.lat + B.lat) / 2, -40, 40), midLon - 3 * tl + 8);
    const cx = 1320, cy = 555, R = 480;
    const ctx = el.scene, lx = el.light;
    drawPlanet(ctx, cam, cx, cy, R, a * span(tl, 0.15, 0.9, linear));
    lx.save(); lx.globalAlpha = a;
    drawRoute(lx, cam, route, 0, 1, cx, cy, R, INK, 0.45 * span(tl, 0.9, 1.6, linear), 2);
    // the photon: there over 1 s from tl=2.0, back over 1 s
    if (tl >= 2.0 && tl < 4.05) {
      const there = tl < 3.0, u = there ? (tl - 2.0) : 1 - (tl - 3.0), head = clamp(u, 0, 1), trail = 0.093;
      for (let k = 0; k < 3; k++) { const f = (k + 1) / 3; drawRoute(lx, cam, route, there ? head - trail * f : head, there ? head : head + trail * f, cx, cy, R, INK, 0.28, 2.5 - k * 0.6); }
      const hp = projectSample(cam, route[Math.round(head * 96)], cx, cy, R);
      if (hp.vis) { drawGlow(lx, atlas.glowInk, hp.x, hp.y, 28, 0.9); lx.fillStyle = rgba(INK, 1); lx.beginPath(); lx.arc(hp.x, hp.y, 2, 0, Math.PI * 2); lx.fill(); }
    }
    const arrB = voiceEnv(tl, 3.0 - 0.0) , arrA = voiceEnv(tl, 4.0);
    lx.font = "20px ui-monospace, Menlo, monospace"; lx.textBaseline = "middle";
    const pa = projectSample(cam, A.v, cx, cy, R), pb = projectSample(cam, B.v, cx, cy, R);
    if (pa.vis) { drawGlow(lx, atlas.glowInk, pa.x, pa.y, 44, 0.18 + 0.4 * arrA); lx.fillStyle = rgba(INK, 1); lx.beginPath(); lx.arc(pa.x, pa.y, 4, 0, Math.PI * 2); lx.fill(); lx.textAlign = "left"; lx.fillStyle = rgba(MUTED, 0.9); lx.fillText(A.name, pa.x + 20, pa.y + 28); }
    if (pb.vis) { drawGlow(lx, atlas.glowB, pb.x, pb.y, 44, 0.18 + 0.4 * arrB); lx.fillStyle = rgba(ACCENT_B, 1); lx.beginPath(); lx.arc(pb.x, pb.y, 4, 0, Math.PI * 2); lx.fill(); lx.textAlign = "right"; lx.fillStyle = rgba(MUTED, 0.9); lx.fillText(B.name, pb.x - 24, pb.y - 30); }
    lx.restore();
    if (s.copy) dom.copy.left = { text: s.copy, size: 64, y: 380, tIn: s.start + 0.5, tOut: s.end - 0.3 };
    if (p.number) dom.number = { text: String(p.number), alpha: span(tl, 4.0, 4.6) * a };
  }
  // ---- mark: two lights become the brand mark; the wordmark lands
  function pMark(s, tl, t, a) {
    const grow = span(tl, 0, 0.85, easeMark);
    const r = 280 * lerp(0.08, 1, grow), sep = 180;
    const overlap = span(tl, 0.16, 0.9, easeMark), hi = kf(tl, [[0.2, 0.22], [1.6, 0.10]]);
    drawMark(el.light, 960, 340, r, sep, 0.88, 0.74, (0.14 + hi) * overlap, a);
    dom.mark = { scale: 1, wm: s.params.wordmark || SPEC.product?.split(/[,:]/)[0] || "", wmAlpha: span(tl, 1.0, 1.6), tagline: s.params.tagline || SPEC.tagline || "", tlAlpha: span(tl, 2.2, 2.8, linear), alpha: a };
  }
  // ---- cta: the end card, mark small above
  function pCta(s, tl, t, a) {
    const u = span(tl, 0, 1.15);
    const scale = lerp(1, 0.65, u), cy = lerp(340, 285, u);
    drawMark(el.light, 960, cy, 280 * scale, 180 * scale, 0.88, 0.74, 0.12, a);
    const prev = SHOTS[SHOTS.indexOf(s) - 1];
    const wm = s.params.wordmark || (prev && prev.params && prev.params.wordmark) || SPEC.product?.split(/[,:]/)[0] || "";
    dom.mark = { scale, cy, wm, wmAlpha: 1, tagline: SPEC.tagline || "", tlAlpha: 1, alpha: a, s15: u };
    const lines = Array.isArray(s.params.lines) ? s.params.lines.slice(0, 3) : [];
    dom.cta = { lines, alpha: span(tl, 0.85, 1.35, linear) * a };
  }
  const PRIMS = { title: pTitle, glow: pGlow, shape: pShape, portrait: pPortrait, duo: pDuo, planet: pPlanet, mark: pMark, cta: pCta };

  // ---------------------------------------------------------------- DOM commit
  function copyNode(node, c, t) {
    if (!c || !c.text) { node.style.opacity = "0"; return; }
    const ein = span(t, c.tIn, c.tIn + 0.48), eout = 1 - span(t, c.tOut, c.tOut + 0.28, linear);
    node.innerHTML = String(c.text).split("\n").map(x => x.replace(/&/g, "&amp;").replace(/</g, "&lt;")).join("<br>") + (c.sub ? `<div class="sub">${String(c.sub).replace(/</g, "&lt;")}</div>` : "");
    node.style.fontSize = `${c.size}px`; node.style.top = `${c.y}px`;
    node.style.opacity = (ein * eout).toFixed(3); node.style.transform = `translateY(${(8 * (1 - ein)).toFixed(2)}px)`;
  }
  function commitDom(t) {
    placeWin(el.winA, dom.winA ? dom.winA.r : WIN, dom.winA ? dom.winA.alpha : 0);
    placeWin(el.winB, dom.winB ? dom.winB.r : WIN, dom.winB ? dom.winB.alpha : 0);
    for (const k of ["center", "side", "left", "below"]) copyNode(el.copy[k], dom.copy[k], t);
    el.number.style.opacity = dom.number ? dom.number.alpha.toFixed(3) : "0"; if (dom.number) el.number.textContent = dom.number.text;
    if (dom.mark) {
      const m = dom.mark, s15 = m.s15 || 0;
      el.markWrap.style.display = "block"; el.markWrap.style.opacity = m.alpha.toFixed(3);
      el.wordmark.textContent = m.wm; el.wordmark.style.opacity = m.wmAlpha.toFixed(3);
      const wmSize = lerp(204, 152, s15); el.wordmark.style.fontSize = `${wmSize.toFixed(1)}px`; el.wordmark.style.top = `${(lerp(790, 635, s15) - wmSize * 0.72 + 8 * (1 - m.wmAlpha)).toFixed(1)}px`;
      el.tagline.textContent = m.tagline; el.tagline.style.opacity = m.tlAlpha.toFixed(3);
      const tlSize = lerp(46, 42, s15); el.tagline.style.fontSize = `${tlSize.toFixed(1)}px`; el.tagline.style.top = `${(lerp(895, 710, s15) - tlSize * 0.78).toFixed(1)}px`;
    } else el.markWrap.style.display = "none";
    if (dom.cta) { el.cta.style.display = "block"; el.cta.style.opacity = dom.cta.alpha.toFixed(3); dom.cta.lines.forEach((l, i) => { el.ctaLines[i].textContent = l; el.ctaLines[i].style.display = "block"; }); for (let i = dom.cta.lines.length; i < 3; i++) el.ctaLines[i].style.display = "none"; }
    else el.cta.style.display = "none";
    el.progressFill.style.width = `${(clamp(t / DURATION, 0, 1) * 100).toFixed(2)}%`;
  }

  // ---------------------------------------------------------------- grain
  const GW = 480, GH = 270; let grainOff, grainImg, grain32, lastGrain = -1;
  function initGrain() { grainOff = offscreen(GW, GH); grainImg = grainOff.getContext("2d").createImageData(GW, GH); grain32 = new Uint32Array(grainImg.data.buffer); }
  function renderGrain(t) {
    const g = el.grain; if (reducedMotion) { g.clearRect(0, 0, el.grainCanvas.width, el.grainCanvas.height); return; }
    const frame = Math.floor(t * 30); if (frame === lastGrain) return; lastGrain = frame;
    let seed = (frame * 1664525 + 1013904223) | 0;
    for (let i = 0; i < grain32.length; i++) { seed = (seed * 1664525 + 1013904223) | 0; const v = seed & 0xFF; grain32[i] = (255 << 24) | (v << 16) | (v << 8) | v; }
    grainOff.getContext("2d").putImageData(grainImg, 0, 0); g.clearRect(0, 0, el.grainCanvas.width, el.grainCanvas.height); g.drawImage(grainOff, 0, 0, el.grainCanvas.width, el.grainCanvas.height);
  }

  // ---------------------------------------------------------------- render(t)
  let _t = 0;
  function render(t) {
    _t = clamp(t, 0, DURATION);
    el.scene.clearRect(0, 0, W, H); el.light.clearRect(0, 0, W, H);
    resetDom();
    const { s, i } = activeShot(_t);
    const a = shotAlpha(i, _t), tl = _t - s.start;
    (PRIMS[s.primitive] || pTitle)(s, tl, _t, a);
    commitDom(_t);
    renderGrain(_t);
  }

  // ---------------------------------------------------------------- score
  // A quiet deterministic bed that leaves room for a voice: two low sines and a
  // breath at each shot boundary; a felt chord under the mark.
  function buildScoreGraph(ctx) {
    const out = ctx.createGain(); out.gain.value = 3.2; out.connect(ctx.destination);
    const comp = ctx.createDynamicsCompressor(); comp.threshold.value = -18; comp.ratio.value = 1.5; comp.attack.value = 0.03; comp.release.value = 0.18; comp.connect(out);
    const lp = ctx.createBiquadFilter(); lp.type = "lowpass"; lp.frequency.value = 700; lp.connect(comp);
    const body = ctx.createGain(); body.gain.setValueAtTime(0.0001, 0); body.gain.linearRampToValueAtTime(0.016, 2.0); body.gain.setValueAtTime(0.016, DURATION - 1.6); body.gain.linearRampToValueAtTime(0.0001, DURATION - 0.1); body.connect(lp);
    for (const [f, type, amp] of [[73.416, "sine", 0.6], [110, "sine", 0.45], [146.832, "triangle", 0.14]]) { const o = ctx.createOscillator(); o.type = type; o.frequency.value = f; const g = ctx.createGain(); g.gain.value = amp; o.connect(g); g.connect(body); o.start(0); o.stop(DURATION); }
    const noiseLen = Math.floor(ctx.sampleRate * 2), noise = ctx.createBuffer(1, noiseLen, ctx.sampleRate); { const d = noise.getChannelData(0), rng = mulberry32(4242); for (let i = 0; i < noiseLen; i++) d[i] = rng() * 2 - 1; }
    for (const s of SHOTS) {
      if (s.start <= 0) continue;
      const src = ctx.createBufferSource(); src.buffer = noise; const bp = ctx.createBiquadFilter(); bp.type = "bandpass"; bp.frequency.value = 420; bp.Q.value = 1.4;
      const g = ctx.createGain(); g.gain.setValueAtTime(0.0001, s.start); g.gain.linearRampToValueAtTime(0.014, s.start + 0.25); g.gain.exponentialRampToValueAtTime(0.0001, s.start + 0.9);
      src.connect(bp); bp.connect(g); g.connect(comp); src.start(s.start, (s.start * 1.3) % 1.5); src.stop(s.start + 1.0);
    }
    const markShot = SHOTS.find(x => x.primitive === "mark");
    if (markShot) for (const [f, amp] of [[184.997, 0.05], [293.665, 0.02], [220, 0.03]]) {
      const o = ctx.createOscillator(); o.type = "sine"; o.frequency.value = f; const g = ctx.createGain(); const at = markShot.start + 1.0;
      g.gain.setValueAtTime(0.0001, at); g.gain.linearRampToValueAtTime(amp, at + 0.06); g.gain.exponentialRampToValueAtTime(0.0001, at + 5.0);
      const f2 = ctx.createBiquadFilter(); f2.type = "lowpass"; f2.frequency.value = 1200; o.connect(f2); f2.connect(g); g.connect(comp); o.start(at); o.stop(at + 5.1);
    }
  }
  async function renderScoreBuffer(sampleRate = 48000) { const off = new OfflineAudioContext(2, Math.ceil(DURATION * sampleRate), sampleRate); buildScoreGraph(off); return off.startRendering(); }

  // ---------------------------------------------------------------- player
  let _playing = false, _muted = false, _atRest = false, _audio = null, _src = null, _scoreBuf = null, _scoreP = null, _raf = null, _lastNow = 0, _srcStartedAt = 0;
  const ensureScore = () => _scoreP || (_scoreP = renderScoreBuffer(48000).then(b => (_scoreBuf = b)).catch(() => null));
  function stopSource() { if (_src) { try { _src.stop(); } catch (e) {} _src.disconnect(); _src = null; } }
  function startLiveAudio() {
    if (_muted || !_playing) return;
    try {
      if (!_audio) { const AC = window.AudioContext || window.webkitAudioContext; if (!AC) return; _audio = new AC({ sampleRate: 48000 }); }
      if (_audio.state === "suspended") _audio.resume().catch(() => {});
      const startAt = buf => { if (!_playing || _muted || !buf) return; stopSource(); _src = _audio.createBufferSource(); _src.buffer = buf; _src.connect(_audio.destination); _src.start(0, clamp(_t, 0, DURATION - 0.01)); _srcStartedAt = _audio.currentTime - _t; };
      if (_scoreBuf) startAt(_scoreBuf); else ensureScore().then(startAt);
    } catch (e) {}
  }
  function showPoster(withReplay) { _atRest = true; render(0); el.playBtn.style.display = withReplay ? "none" : "flex"; el.replay.style.display = withReplay ? "block" : "none"; }
  function play() {
    if (_playing) return;
    if (_atRest) { _atRest = false; _t = 0; render(0); }
    _playing = true; el.playBtn.style.display = "none"; el.replay.style.display = "none"; _lastNow = performance.now(); startLiveAudio();
    const loop = now => {
      if (!_playing) return;
      const dt = (now - _lastNow) / 1000; _lastNow = now;
      let next = _t + dt; if (_src && _audio && _audio.state === "running") next = _audio.currentTime - _srcStartedAt;
      if (next >= DURATION) { if (isLoop) { _t = 0; render(0); stopSource(); startLiveAudio(); } else { pause(); _t = DURATION; showPoster(true); return; } }
      else render(next);
      _raf = requestAnimationFrame(loop);
    };
    _raf = requestAnimationFrame(loop);
  }
  function pause() { _playing = false; if (_raf) { cancelAnimationFrame(_raf); _raf = null; } stopSource(); }
  function toggle() { if (_playing) pause(); else play(); }
  function setMuted(m) { _muted = !!m; el.volumeWaves.style.display = _muted ? "none" : "block"; if (_muted) stopSource(); else if (_playing) startLiveAudio(); }

  window.kinAd = {
    duration: DURATION, get time() { return _t; }, play, pause, toggle, setMuted,
    transcript: SHOTS.filter(s => s.copy || (s.params && s.params.copy)).map(s => ({ t: s.start, text: s.copy || s.params.copy })).concat((SPEC.voiceover || []).map(v => ({ t: v.t, text: "[voice] " + v.text }))),
    seek(t) { pause(); _atRest = false; el.replay.style.display = "none"; render(t); return new Promise(res => requestAnimationFrame(() => requestAnimationFrame(res))); },
    async renderScoreOffline(sampleRate = 48000) { const buf = (sampleRate === 48000 && _scoreBuf) ? _scoreBuf : await renderScoreBuffer(sampleRate); return [buf.getChannelData(0), buf.getChannelData(1)]; }
  };

  window.addEventListener("DOMContentLoaded", () => {
    cacheElements(); buildAtlas(); buildPlate(); initGrain(); fitStage();
    if (isMutedFlag) setMuted(true);
    if (!isRender) ensureScore();
    if (isRender) el.controls.style.display = "none";
    else {
      el.playBtn.addEventListener("click", e => { e.stopPropagation(); play(); });
      el.stage.addEventListener("click", e => { if (e.target.closest("#mute-toggle, #replay-button, #progress-hairline")) return; if (_atRest) { play(); return; } toggle(); });
      el.progress.addEventListener("click", e => { e.stopPropagation(); const r = el.progress.getBoundingClientRect(); const wasPlaying = _playing; window.kinAd.seek(clamp((e.clientX - r.left) / r.width, 0, 1) * DURATION).then(() => { if (wasPlaying) play(); }); });
      el.mute.addEventListener("click", e => { e.stopPropagation(); setMuted(!_muted); });
      el.replay.addEventListener("click", e => { e.stopPropagation(); _atRest = false; window.kinAd.seek(0).then(() => play()); });
    }
    if (!isNaN(targetT)) render(clamp(targetT, 0, DURATION));
    else if (isRender) render(0);
    else if (isAutoplay) { render(0); play(); }
    else showPoster(false);
  });
})();
