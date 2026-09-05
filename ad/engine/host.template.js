/**
 * Ad engine v2 — the host. Runs model-written shot modules safely, as a pure
 * function of time, and gives them a documented drawing library (`lib`) and a
 * type layer (`dom`). Falls back to the v1 primitives when a module is
 * missing or throws. Same window.kinAd contract as the flagship, so
 * ad/render.mjs, smoke.mjs and fps-probe.mjs all work on it.
 *
 * Inputs (inlined by build-ad.mjs before this script):
 *   <script type="application/json" id="ad-spec">  the plan
 *   window.__AD_MODULES__ = { S1: function shot(c){...}, ..., score: function(ctx, D, lib){...} }
 */
(function() {
  "use strict";

  // ---------------------------------------------------------------- spec + palette
  const SPEC = JSON.parse(document.getElementById("ad-spec").textContent);
  const MODULES = window.__AD_MODULES__ || {};
  const DURATION = +SPEC.duration || 40;
  const W = 1920, H = 1080;
  const hexToRgb = h => { const s = (h || "").replace("#", ""); return s.length === 6 ? [parseInt(s.slice(0, 2), 16), parseInt(s.slice(2, 4), 16), parseInt(s.slice(4, 6), 16)] : null; };
  const PAL = SPEC.palette || {};
  const GROUND = hexToRgb(PAL.ground) || [5, 6, 10];
  const INK = hexToRgb(PAL.ink) || [243, 241, 236];
  const ACCENT_A = hexToRgb(PAL.accentA) || [74, 222, 128];
  const ACCENT_B = hexToRgb(PAL.accentB) || [96, 165, 250];
  const MUTED = [154, 163, 178];
  const COL = { A: ACCENT_A, B: ACCENT_B, ink: INK, muted: MUTED, ground: GROUND };
  const colorOf = c => Array.isArray(c) ? c : (COL[c] || (typeof c === "string" && c[0] === "#" ? hexToRgb(c) : null) || INK);

  // ---------------------------------------------------------------- math
  const rgba = (c, a) => { c = colorOf(c); return `rgba(${Math.round(c[0])},${Math.round(c[1])},${Math.round(c[2])},${Math.max(0, Math.min(1, a))})`; };
  const mix = (a, b, u) => { a = colorOf(a); b = colorOf(b); return [a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u, a[2] + (b[2] - a[2]) * u]; };
  const hex = c => { c = colorOf(c); return `rgb(${Math.round(c[0])},${Math.round(c[1])},${Math.round(c[2])})`; };
  const clamp = (v, lo, hi) => v < lo ? lo : (v > hi ? hi : v);
  const lerp = (a, b, u) => a + (b - a) * u;
  function cubicBezier(p1x, p1y, p2x, p2y) {
    const cx = 3 * p1x, bx = 3 * (p2x - p1x) - cx, ax = 1 - cx - bx, cy = 3 * p1y, by = 3 * (p2y - p1y) - cy, ay = 1 - cy - by;
    const X = t => ((ax * t + bx) * t + cx) * t, Y = t => ((ay * t + by) * t + cy) * t, DX = t => (3 * ax * t + 2 * bx) * t + cx;
    return x => { if (x <= 0) return 0; if (x >= 1) return 1; let t = x; for (let i = 0; i < 8; i++) { const e = X(t) - x; if (Math.abs(e) < 1e-5) return Y(t); const d = DX(t); if (Math.abs(d) < 1e-6) break; t -= e / d; } return Y(clamp(t, 0, 1)); };
  }
  const ease = cubicBezier(0.2, 0.7, 0.2, 1.0), easeMark = cubicBezier(0.16, 0.75, 0.18, 1.0);
  const sine = u => 0.5 - 0.5 * Math.cos(Math.PI * u), linear = u => u;
  const span = (t, a, b, e = ease) => e(clamp((t - a) / (b - a), 0, 1));
  function kf(t, pts, e = linear) { if (t <= pts[0][0]) return pts[0][1]; const n = pts.length; if (t >= pts[n - 1][0]) return pts[n - 1][1]; for (let i = 0; i < n - 1; i++) { const [t0, v0] = pts[i], [t1, v1] = pts[i + 1]; if (t >= t0 && t <= t1) return v0 + (v1 - v0) * e(t1 === t0 ? 0 : (t - t0) / (t1 - t0)); } return pts[n - 1][1]; }
  function mulberry32(a) { return function() { let t = a += 0x6D2B79F5; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
  function offscreen(w, h) { const c = document.createElement("canvas"); c.width = w; c.height = h; return c; }
  // events: [[onset, peak], ...]; attack/release in seconds
  function envelope(tl, events, atk = 0.09, rel = 0.26) { let e = 0; for (const [o, pk] of events) { const dt = tl - o; if (dt < 0 || dt > rel * 5 + atk) continue; const v = dt < atk ? dt / atk : Math.exp(-(dt - atk) / rel); if (v * (pk ?? 1) > e) e = v * (pk ?? 1); } return e; }

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
  function buildGlowSprite(color, size) {
    const c = offscreen(size, size), g = c.getContext("2d"), r = size / 2;
    const gr = g.createRadialGradient(r, r, 0, r, r, r);
    gr.addColorStop(0, rgba(color, 1)); gr.addColorStop(0.25, rgba(color, 0.55)); gr.addColorStop(0.6, rgba(color, 0.12)); gr.addColorStop(1, rgba(color, 0));
    g.fillStyle = gr; g.fillRect(0, 0, size, size); return c;
  }

  /*@@PORTRAIT@@*/

  /*@@MARK@@*/

  const spriteCache = new Map();
  function sprite(color) { const c = colorOf(color), k = c.join(","); if (!spriteCache.has(k)) spriteCache.set(k, buildGlowSprite(c, 256)); return spriteCache.get(k); }
  function buildAtlas() { atlas.them = buildPortrait("them"); atlas.you = buildPortrait("you"); }

  // ---------------------------------------------------------------- lib: drawing
  const errors = [];
  let clipRadius = 0;
  function clipRect(ctx, x, y, w, h) { const r = clipRadius; if (r > 0 && ctx.roundRect) ctx.roundRect(x, y, w, h, [0, 0, r, r]); else ctx.rect(x, y, w, h); }
  function glow(ctx, x, y, r, color, alpha) { if (alpha <= 0.002 || r <= 0) return; ctx.save(); ctx.globalAlpha = clamp(alpha, 0, 1); ctx.drawImage(sprite(color), x - r, y - r, 2 * r, 2 * r); ctx.restore(); }
  function field(ctx, x, y, r, color, alpha) {
    if (alpha <= 0.002 || r <= 0) return; const col = colorOf(color);
    ctx.save();
    const g = ctx.createRadialGradient(x, y, 0, x, y, r);
    g.addColorStop(0, rgba(col, 0.85 * alpha)); g.addColorStop(0.35, rgba(col, 0.42 * alpha)); g.addColorStop(0.75, rgba(col, 0.08 * alpha)); g.addColorStop(1, rgba(col, 0));
    ctx.fillStyle = g; ctx.fillRect(x - r, y - r, 2 * r, 2 * r);
    const h = ctx.createRadialGradient(x, y, r * 0.6, x, y, r * 1.8);
    h.addColorStop(0, rgba(col, 0.06 * alpha)); h.addColorStop(1, rgba(col, 0));
    ctx.fillStyle = h; ctx.fillRect(x - r * 1.8, y - r * 1.8, 3.6 * r, 3.6 * r);
    ctx.restore();
  }
  const pathCache = new Map();
  function path2d(d) { let P = pathCache.get(d); if (!P) { try { P = new Path2D(d); } catch (e) { P = new Path2D(); } pathCache.set(d, P); } return P; }
  // Paint for a layer: a colour name/array/hex, or a gradient in 0..1000 box
  // coordinates: {linear:[x0,y0,x1,y1], stops:[[pos,color],...]} or
  // {radial:[cx,cy,r0,r1], stops:[...]} (stops may carry a 3rd alpha entry).
  function paintFor(ctx, f) {
    if (!f || f === "none") return null;
    if (typeof f === "object" && !Array.isArray(f) && (f.linear || f.radial)) {
      const g = f.linear ? ctx.createLinearGradient(...f.linear.slice(0, 4)) : ctx.createRadialGradient(f.radial[0], f.radial[1], f.radial[2] ?? 0, f.radial[0], f.radial[1], f.radial[3] ?? 500);
      for (const st of (f.stops || [[0, "ink"], [1, "ground"]])) g.addColorStop(clamp(+st[0], 0, 1), rgba(st[1], st[2] ?? 1));
      return g;
    }
    return hex(f);
  }
  // draw one layer {path, fill, stroke, strokeWidth, alpha, glow, dash} inside an already-applied 0..1000 box transform (sc = px per box unit)
  function drawLayer(ctx, L, sc) {
    const P = path2d(L.path), a = L.alpha ?? 1; if (a <= 0.002 || !L.path) return;
    const prev = ctx.globalAlpha; ctx.globalAlpha = prev * clamp(a, 0, 1);
    const fillP = paintFor(ctx, L.fill), strokeP = L.stroke && L.stroke !== "none" ? colorOf(L.stroke) : null;
    const glowCol = typeof L.fill === "string" || Array.isArray(L.fill) ? (L.fill !== "none" ? colorOf(L.fill) : null) : (strokeP || INK);
    if (L.glow > 0 && glowCol) { ctx.save(); ctx.shadowColor = rgba(glowCol, 0.9 * L.glow); ctx.shadowBlur = 90 * L.glow / sc; ctx.fillStyle = rgba(glowCol, 0.35 * L.glow); ctx.fill(P); ctx.restore(); }
    if (fillP) { ctx.fillStyle = fillP; ctx.fill(P); }
    if (strokeP) { ctx.strokeStyle = hex(strokeP); ctx.lineWidth = (L.strokeWidth || 6) / sc; ctx.lineJoin = "round"; ctx.lineCap = "round"; if (L.dash) ctx.setLineDash(L.dash.map(v => v / sc)); ctx.stroke(P); if (L.dash) ctx.setLineDash([]); }
    ctx.globalAlpha = prev;
  }
  // shapes: several layers under ONE transform. o: {x,y (centre px), size (box height px), alpha, rotate, scaleX, scaleY, only:[tags], skip:[tags]}
  function shapes(ctx, layers, o = {}) {
    if (!layers || !layers.length || (o.alpha ?? 1) <= 0.002) return;
    const size = o.size || 500, sc = size / 1000;
    ctx.save(); ctx.globalAlpha = clamp(o.alpha ?? 1, 0, 1);
    ctx.translate(o.x ?? W / 2, o.y ?? H / 2); if (o.rotate) ctx.rotate(o.rotate); ctx.scale(sc * (o.scaleX ?? 1), sc * (o.scaleY ?? 1)); ctx.translate(-500, -500);
    for (const L of layers) { if (o.only && !(o.only.includes(L.tag))) continue; if (o.skip && o.skip.includes(L.tag)) continue; drawLayer(ctx, L, sc); }
    ctx.restore();
  }
  // shape: one SVG path in a 0..1000 box. o: {x,y,size,fill,stroke,strokeWidth,alpha,rotate,scaleX,scaleY,glow,dash}
  function shape(ctx, d, o = {}) { shapes(ctx, [{ path: d, fill: o.fill, stroke: o.stroke, strokeWidth: o.strokeWidth, glow: o.glow, dash: o.dash }], o); }
  // product: THE product, drawn once by the plan (spec.productDrawing.layers) and identical in every shot.
  // o as in shapes(); use only/skip with layer tags (e.g. only:["outline"]) for partial reveals.
  const PRODUCT = (SPEC.productDrawing && Array.isArray(SPEC.productDrawing.layers)) ? SPEC.productDrawing.layers : null;
  function product(ctx, o = {}) { if (!PRODUCT) { if (!product.warned) { product.warned = true; errors.push({ shot: "product", error: "spec.productDrawing missing; lib.product drew nothing" }); } return; } shapes(ctx, PRODUCT, o); }
  // line: polyline of [x,y] points. o: {color, width, alpha, glow (0..1), cap, close}
  function line(ctx, pts, o = {}) {
    if (!pts || pts.length < 2 || (o.alpha ?? 1) <= 0.002) return;
    const col = colorOf(o.color || "ink"), w = o.width || 2, a = o.alpha ?? 1;
    ctx.save(); ctx.lineCap = o.cap || "round"; ctx.lineJoin = "round";
    const draw = () => { ctx.beginPath(); ctx.moveTo(pts[0][0], pts[0][1]); for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1]); if (o.close) ctx.closePath(); ctx.stroke(); };
    if (o.glow > 0) { ctx.strokeStyle = rgba(col, 0.12 * a * o.glow); ctx.lineWidth = w + 18 * o.glow; draw(); }
    ctx.strokeStyle = rgba(col, a); ctx.lineWidth = w; draw();
    ctx.restore();
  }
  function dot(ctx, x, y, r, color, alpha = 1, glowAmt = 0) { if (alpha <= 0.002) return; if (glowAmt > 0) glow(ctx, x, y, r * (4 + 8 * glowAmt), color, alpha * 0.6 * glowAmt); ctx.save(); ctx.fillStyle = rgba(color, alpha); ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.fill(); ctx.restore(); }
  const FONTS = { serif: 'Baskerville, "Iowan Old Style", Georgia, serif', sans: '-apple-system, BlinkMacSystemFont, system-ui, sans-serif', mono: 'ui-monospace, Menlo, monospace' };
  // text on canvas: for small labels only; story copy goes through dom.copy
  function text(ctx, str, o = {}) {
    if (!str || (o.alpha ?? 1) <= 0.002) return;
    ctx.save(); ctx.globalAlpha = clamp(o.alpha ?? 1, 0, 1);
    ctx.font = `${o.italic ? "italic " : ""}${o.size || 20}px ${FONTS[o.font] || FONTS.mono}`; ctx.textAlign = o.align || "left"; ctx.textBaseline = o.baseline || "middle";
    if ("letterSpacing" in ctx) ctx.letterSpacing = `${o.tracking ?? (o.font === "mono" || !o.font ? 1.6 : 0)}px`;
    ctx.fillStyle = rgba(o.color || "ink", 1); ctx.fillText(String(str), o.x ?? W / 2, o.y ?? H / 2);
    ctx.restore();
  }
  function drawTile(ctx, tile, x, y, w, h, zoom = 1, dx = 0, dy = 0, alpha = 1) {
    const scale = Math.max(w / PW, h / PH) * zoom, dw = PW * scale, dh = PH * scale, ox = x + (w - dw) / 2 + dx, oy = y + (h - dh) * 0.35 + dy;
    ctx.save(); ctx.globalAlpha = alpha; ctx.beginPath(); clipRect(ctx, x, y, w, h); ctx.clip(); ctx.drawImage(tile, ox, oy, dw, dh); ctx.restore();
  }
  // portrait: a person out of focus filling rect. o: {alpha, zoom, dx, dy, rounded}
  function portrait(ctx, who, rect, o = {}) { clipRadius = o.rounded ?? 12; drawTile(ctx, atlas[who === "you" ? "you" : "them"], rect.x, rect.y, rect.w, rect.h, o.zoom ?? 1, o.dx ?? 0, o.dy ?? 0, o.alpha ?? 1); clipRadius = 0; }
  // edge: the edge band inside rect: distance-to-edge ramp, mitred corners, 1.5 px hairline
  function edge(ctx, rect, color, opacity, depth = 48) {
    if (opacity <= 0.002) return; const { x, y, w, h } = rect, col = colorOf(color);
    const stops = []; for (let i = 0; i <= 8; i++) { const u = i / 8; stops.push([u, 0.72 * Math.pow(1 - u, 2.2)]); }
    const grad = (x0, y0, x1, y1) => { const g = ctx.createLinearGradient(x0, y0, x1, y1); for (const [u, a] of stops) g.addColorStop(u, rgba(col, a)); return g; };
    const d = Math.min(depth, w / 2, h / 2);
    ctx.save(); ctx.globalAlpha = clamp(opacity, 0, 1); ctx.beginPath(); clipRadius = 12; clipRect(ctx, x, y, w, h); clipRadius = 0; ctx.clip();
    ctx.fillStyle = grad(0, y, 0, y + d); ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x + w, y); ctx.lineTo(x + w - d, y + d); ctx.lineTo(x + d, y + d); ctx.closePath(); ctx.fill();
    ctx.fillStyle = grad(0, y + h, 0, y + h - d); ctx.beginPath(); ctx.moveTo(x, y + h); ctx.lineTo(x + w, y + h); ctx.lineTo(x + w - d, y + h - d); ctx.lineTo(x + d, y + h - d); ctx.closePath(); ctx.fill();
    ctx.fillStyle = grad(x, 0, x + d, 0); ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x + d, y + d); ctx.lineTo(x + d, y + h - d); ctx.lineTo(x, y + h); ctx.closePath(); ctx.fill();
    ctx.fillStyle = grad(x + w, 0, x + w - d, 0); ctx.beginPath(); ctx.moveTo(x + w, y); ctx.lineTo(x + w - d, y + d); ctx.lineTo(x + w - d, y + h - d); ctx.lineTo(x + w, y + h); ctx.closePath(); ctx.fill();
    ctx.strokeStyle = rgba(col, 0.95); ctx.lineWidth = 1.5; ctx.beginPath(); clipRadius = 12; clipRect(ctx, x + 0.75, y + 0.75, w - 1.5, h - 1.5); clipRadius = 0; ctx.stroke();
    ctx.restore();
  }

  // ---------------------------------------------------------------- lib: planet
  function unit(lat, lon) { const p = lat * Math.PI / 180, l = lon * Math.PI / 180; return [Math.cos(p) * Math.sin(l), Math.sin(p), Math.cos(p) * Math.cos(l)]; }
  function slerp(a, b, s) { const d = clamp(a[0] * b[0] + a[1] * b[1] + a[2] * b[2], -1, 1), om = Math.acos(d); if (om < 1e-5) return a; const so = Math.sin(om), c1 = Math.sin((1 - s) * om) / so, c2 = Math.sin(s * om) / so; return [c1 * a[0] + c2 * b[0], c1 * a[1] + c2 * b[1], c1 * a[2] + c2 * b[2]]; }
  function camera(lat0, lon0) { const L = lon0 * Math.PI / 180, A = lat0 * Math.PI / 180, cL = Math.cos(L), sL = Math.sin(L), cA = Math.cos(A), sA = Math.sin(A); return v => { const x = v[0] * cL - v[2] * sL, z0 = v[0] * sL + v[2] * cL, y = v[1]; return { x, y: y * cA - z0 * sA, z: y * sA + z0 * cA }; }; }
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
  const GAZ = { DELHI: [28.6139, 77.2090], AMSTERDAM: [52.3676, 4.9041], TOKYO: [35.6762, 139.6503], SYDNEY: [-33.8688, 151.2093], "SAO PAULO": [-23.5505, -46.6333], LAGOS: [6.5244, 3.3792], NAIROBI: [-1.2921, 36.8219], LONDON: [51.5074, -0.1278], "NEW YORK": [40.7128, -74.0060], "SAN FRANCISCO": [37.7749, -122.4194], SEATTLE: [47.6062, -122.3321], TORONTO: [43.6532, -79.3832], "MEXICO CITY": [19.4326, -99.1332], "BUENOS AIRES": [-34.6037, -58.3816], "CAPE TOWN": [-33.9249, 18.4241], CAIRO: [30.0444, 31.2357], DUBAI: [25.2048, 55.2708], MUMBAI: [19.0760, 72.8777], SINGAPORE: [1.3521, 103.8198], JAKARTA: [-6.2088, 106.8456], SEOUL: [37.5665, 126.9780], BERLIN: [52.5200, 13.4050], PARIS: [48.8566, 2.3522], "LOS ANGELES": [34.0522, -118.2437], BENGALURU: [12.9716, 77.5946], "HONG KONG": [22.3193, 114.1694], SHANGHAI: [31.2304, 121.4737], MADRID: [40.4168, -3.7038], ROME: [41.9028, 12.4964], STOCKHOLM: [59.3293, 18.0686], AUCKLAND: [-36.8485, 174.7633], JOHANNESBURG: [-26.2041, 28.0473], CHICAGO: [41.8781, -87.6298], VANCOUVER: [49.2827, -123.1207], LISBON: [38.7223, -9.1393], ISTANBUL: [41.0082, 28.9784], PORTLAND: [45.5152, -122.6784], COPENHAGEN: [55.6761, 12.5683] };
  function city(name) { const k = String(name || "").toUpperCase().replace("Ã", "A").trim(); const c = GAZ[k] || GAZ.DELHI; return { name: k || "DELHI", v: unit(c[0], c[1]), lat: c[0], lon: c[1] }; }
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
  // planet: {cx, cy, R, lat, lon, alpha}; returns the camera for routes/project
  function planet(ctx, o) {
    const cam = camera(o.lat ?? 25, o.lon ?? 45), cx = o.cx ?? 1320, cy = o.cy ?? 555, R = o.R ?? 480, alpha = o.alpha ?? 1;
    if (alpha <= 0.002) return cam;
    const ocean = mix(GROUND, MUTED, 0.12), land = mix(GROUND, MUTED, 0.24);
    ctx.save(); ctx.globalAlpha = alpha; ctx.beginPath(); ctx.arc(cx, cy, R, 0, Math.PI * 2); ctx.clip();
    ctx.fillStyle = hex(ocean); ctx.fillRect(cx - R, cy - R, 2 * R, 2 * R); ctx.fillStyle = hex(land);
    for (const poly of LAND_V) { ctx.beginPath(); let st = false; for (const v of poly) { const p = cam(v); let x = p.x, y = p.y; if (p.z < 0) { const m = Math.hypot(x, y) || 1; x /= m; y /= m; } const sx = cx + R * x, sy = cy - R * y; if (!st) { ctx.moveTo(sx, sy); st = true; } else ctx.lineTo(sx, sy); } ctx.closePath(); ctx.fill(); }
    if (plate) { ctx.globalCompositeOperation = "multiply"; ctx.drawImage(plate, cx - R, cy - R, 2 * R, 2 * R); ctx.globalCompositeOperation = "source-over"; }
    ctx.restore();
    ctx.save(); ctx.globalAlpha = alpha;
    const lg = ctx.createLinearGradient(cx - R, cy - R, cx + R * 0.8, cy + R * 0.8); lg.addColorStop(0, rgba(INK, 0.38)); lg.addColorStop(0.6, rgba(INK, 0.16)); lg.addColorStop(1, rgba(INK, 0.08));
    ctx.strokeStyle = lg; ctx.lineWidth = 1.25; ctx.beginPath(); ctx.arc(cx, cy, R, 0, Math.PI * 2); ctx.stroke();
    ctx.restore();
    return cam;
  }
  function project(cam, v, cx, cy, R) { const p = cam(v); return { x: cx + R * p.x, y: cy - R * p.y, z: p.z, vis: p.z > 0 || Math.hypot(p.x, p.y) > 1.0 }; }
  const routeCache = new Map();
  function routeSamples(a, b, lift) { const k = a.join() + "|" + b.join() + "|" + lift; let s = routeCache.get(k); if (!s) { s = []; for (let i = 0; i <= 96; i++) { const u = i / 96, v = slerp(a, b, u), l = 1 + lift * Math.sin(Math.PI * u); s.push([v[0] * l, v[1] * l, v[2] * l]); } routeCache.set(k, s); } return s; }
  // route: draw part [u0,u1] of the great-circle route between two city vectors. o: {cx,cy,R,color,alpha,width,lift}
  function route(ctx, cam, fromV, toV, u0, u1, o = {}) {
    const s = routeSamples(fromV, toV, o.lift ?? 0.04), cx = o.cx ?? 1320, cy = o.cy ?? 555, R = o.R ?? 480, col = colorOf(o.color || "ink"), alpha = o.alpha ?? 0.5, width = o.width || 2;
    if (alpha <= 0.002 || u1 <= u0) return null;
    const i0 = Math.max(0, Math.floor(u0 * 96)), i1 = Math.min(96, Math.ceil(u1 * 96));
    ctx.save(); ctx.lineCap = "round";
    for (const [w, a] of [[width + 3.25, 0.07], [width, 1]]) { ctx.strokeStyle = rgba(col, alpha * a); ctx.lineWidth = w; ctx.beginPath(); let pen = false; for (let i = i0; i <= i1; i++) { const p = project(cam, s[i], cx, cy, R); if (!p.vis) { pen = false; continue; } if (!pen) { ctx.moveTo(p.x, p.y); pen = true; } else ctx.lineTo(p.x, p.y); } ctx.stroke(); }
    ctx.restore();
    return project(cam, s[Math.round(clamp(u1, 0, 1) * 96)], cx, cy, R); // the head
  }

  // ---------------------------------------------------------------- lib: mark
  function mark(ctx, cx, cy, r, sep, aInk, aAccent, overlap, fade) { drawMark(ctx, cx, cy, r, sep, aInk, aAccent, overlap, fade); }

  // ---------------------------------------------------------------- dom layer (declared per frame, committed once)
  const TITLE = 44, WIN = { x: 120, y: 156, w: 1008, h: 744 };
  let D;
  function resetDom() { D = { winA: null, winB: null, copy: {}, number: null, mark: null, cta: null }; }
  const dom = {
    // story copy through the type system. pos: center|side|left|below. o: {size, y, tIn, tOut, sub, color}
    copy(pos, txt, o = {}) { D.copy[pos] = { text: txt, size: o.size || 72, y: o.y ?? (pos === "side" || pos === "left" ? 410 : 864), tIn: o.tIn ?? 0, tOut: o.tOut ?? 1e9, sub: o.sub, color: o.color }; },
    // window chrome around rect (title strip 44 px at scale 1). which: "a"|"b"
    window(rect, alpha = 1, which = "a") { D[which === "b" ? "winB" : "winA"] = { r: rect, alpha }; },
    wordmark(txt, o = {}) { D.mark = Object.assign(D.mark || {}, { wm: txt, wmSize: o.size || 204, wmTop: o.top ?? 640, wmAlpha: o.alpha ?? 1, alpha: 1 }); },
    tagline(txt, o = {}) { D.mark = Object.assign(D.mark || {}, { tagline: txt, tlSize: o.size || 46, tlTop: o.top ?? 860, tlAlpha: o.alpha ?? 1, alpha: 1 }); },
    cta(lines, alpha = 1) { D.cta = { lines: (lines || []).slice(0, 3), alpha }; },
    number(txt, alpha = 1) { D.number = { text: txt, alpha }; },
    // content rect of a window at rect (below its title strip)
    content(r) { const s = r.w / WIN.w; return { x: r.x, y: r.y + TITLE * s, w: r.w, h: r.h - TITLE * s, s }; }
  };
  function placeWin(node, r, alpha) { if (!r || alpha <= 0.002) { node.style.display = "none"; return; } node.style.display = "block"; node.style.transform = `translate(${r.x.toFixed(2)}px, ${r.y.toFixed(2)}px) scale(${(r.w / WIN.w).toFixed(4)})`; node.style.opacity = alpha.toFixed(3); }
  function copyNode(node, c, t) {
    if (!c || !c.text) { node.style.opacity = "0"; return; }
    const ein = span(t, c.tIn, c.tIn + 0.48), eout = 1 - span(t, c.tOut, c.tOut + 0.28, linear);
    node.innerHTML = String(c.text).split("\n").map(x => x.replace(/&/g, "&amp;").replace(/</g, "&lt;")).join("<br>") + (c.sub ? `<div class="sub">${String(c.sub).replace(/</g, "&lt;")}</div>` : "");
    node.style.fontSize = `${c.size}px`; node.style.top = `${c.y}px`; node.style.color = c.color ? hex(c.color) : "";
    node.style.opacity = (ein * eout).toFixed(3); node.style.transform = `translateY(${(8 * (1 - ein)).toFixed(2)}px)`;
  }
  function commitDom(t) {
    placeWin(el.winA, D.winA && D.winA.r, D.winA ? D.winA.alpha : 0);
    placeWin(el.winB, D.winB && D.winB.r, D.winB ? D.winB.alpha : 0);
    for (const k of ["center", "side", "left", "below"]) copyNode(el.copy[k], D.copy[k], t);
    el.number.style.opacity = D.number ? clamp(D.number.alpha, 0, 1).toFixed(3) : "0"; if (D.number) el.number.textContent = D.number.text;
    if (D.mark) {
      const m = D.mark; el.markWrap.style.display = "block"; el.markWrap.style.opacity = "1";
      el.wordmark.textContent = m.wm || ""; el.wordmark.style.opacity = clamp(m.wmAlpha ?? 0, 0, 1).toFixed(3); el.wordmark.style.fontSize = `${m.wmSize || 204}px`; el.wordmark.style.top = `${(m.wmTop ?? 640) + 8 * (1 - (m.wmAlpha ?? 1))}px`;
      el.tagline.textContent = m.tagline || ""; el.tagline.style.opacity = clamp(m.tlAlpha ?? 0, 0, 1).toFixed(3); el.tagline.style.fontSize = `${m.tlSize || 46}px`; el.tagline.style.top = `${m.tlTop ?? 860}px`;
    } else el.markWrap.style.display = "none";
    if (D.cta) { el.cta.style.display = "block"; el.cta.style.opacity = clamp(D.cta.alpha, 0, 1).toFixed(3); D.cta.lines.forEach((l, i) => { el.ctaLines[i].textContent = l; el.ctaLines[i].style.display = "block"; }); for (let i = D.cta.lines.length; i < 3; i++) el.ctaLines[i].style.display = "none"; }
    else el.cta.style.display = "none";
    el.progressFill.style.width = `${(clamp(t / DURATION, 0, 1) * 100).toFixed(2)}%`;
  }

  // ---------------------------------------------------------------- the lib object handed to modules
  const lib = Object.freeze({
    W, H, col: COL, rgba, mix, hex, clamp, lerp, ease, easeMark, sine, linear, span, kf, envelope, rng: mulberry32,
    glow, field, shape, shapes, product, line, dot, text, portrait, edge, planet, project, route, city, mark, WIN, hasProduct: !!PRODUCT
  });

  // ---------------------------------------------------------------- shots
  const SHOTS = (SPEC.shots || []).slice().sort((a, b) => a.start - b.start);
  const broken = {}; const frameMs = [];
  window.__adErrors = errors;
  function activeShot(t) { for (let i = 0; i < SHOTS.length; i++) { const s = SHOTS[i]; if (t >= s.start && (t < s.end || i === SHOTS.length - 1)) return i; } return 0; }
  // host-level fades only for fallbacks; modules own their transitions
  function fallbackAlpha(i, t) { const s = SHOTS[i]; let a = span(t, s.start, s.start + 0.5, linear) * (1 - span(t, s.end - 0.4, s.end, linear)); if (i === SHOTS.length - 1) a = Math.min(a, 1 - span(t, DURATION - 0.8, DURATION, linear)); return a; }
  // v1 primitives as the safety net
  function fallback(s, tl, t, a) {
    const p = s.params || {};
    switch (s.primitive) {
      case "glow": { const u = span(t, s.start, s.end, sine); field(el.scene, W * (p.x ?? 0.5), H * (p.y ?? 0.5), p.radius || 520, p.color || "A", lerp(p.from ?? 0, p.to ?? 1, u) * a); break; }
      case "shape": if (p.path) shape(el.scene, p.path, { x: W * (p.x ?? 0.5), y: H * (p.y ?? 0.5), size: p.size || 520, fill: p.fill, stroke: p.stroke, strokeWidth: p.strokeWidth, alpha: a, glow: p.glow }); break;
      case "portrait": { const r = WIN, c = dom.content(r); portrait(el.scene, p.who, c, { alpha: a }); if (p.edge && p.edge !== "none") edge(el.light, c, p.edge, 0.7 * a, 48); dom.window(r, a); break; }
      case "mark": mark(el.light, 960, 340, 280 * lerp(0.08, 1, span(tl, 0, 0.85, easeMark)), 180, 0.88, 0.74, 0.14 * span(tl, 0.2, 0.9), a); dom.wordmark(p.wordmark || "", { alpha: span(tl, 1.0, 1.6) }); dom.tagline(p.tagline || SPEC.tagline || "", { alpha: span(tl, 2.2, 2.8, linear) }); break;
      case "cta": mark(el.light, 960, 285, 182, 117, 0.88, 0.74, 0.12, a); dom.wordmark(p.wordmark || SPEC.wordmark || "", { size: 152, top: 525, alpha: 1 }); dom.tagline(SPEC.tagline || "", { size: 42, top: 677, alpha: 1 }); dom.cta(p.lines || [], span(tl, 0.85, 1.35, linear) * a); break;
      default: dom.copy("center", p.copy || s.copy || "", { size: p.size || 88, y: 540 - (p.size || 88) * 0.55, tIn: s.start + 0.2, tOut: s.end - 0.3, sub: p.sub });
    }
    if (s.copy && s.primitive !== "title") dom.copy(s.primitive === "portrait" ? "side" : "center", s.copy, { size: 64, tIn: s.start + 0.4, tOut: s.end - 0.3 });
  }

  let _t = 0;
  function render(t) {
    _t = clamp(t, 0, DURATION);
    const t0 = performance.now();
    el.scene.clearRect(0, 0, W, H); el.light.clearRect(0, 0, W, H);
    resetDom();
    const i = activeShot(_t), s = SHOTS[i], tl = _t - s.start, dur = s.end - s.start;
    const mod = MODULES[s.id];
    if (mod && !broken[s.id]) {
      try {
        mod({ scene: el.scene, light: el.light, dom, lib, t: _t, tl, u: clamp(tl / dur, 0, 1), dur, a: 1, shot: s, prev: SHOTS[i - 1] || null, next: SHOTS[i + 1] || null, spec: SPEC, D: DURATION });
      } catch (e) {
        broken[s.id] = true; errors.push({ shot: s.id, error: String(e && e.stack || e).slice(0, 600), t: _t });
        el.scene.clearRect(0, 0, W, H); el.light.clearRect(0, 0, W, H); resetDom();
        fallback(s, tl, _t, fallbackAlpha(i, _t));
      }
    } else fallback(s, tl, _t, fallbackAlpha(i, _t));
    commitDom(_t);
    renderGrain(_t);
    const ms = performance.now() - t0; if (frameMs.length < 4000) frameMs.push([+_t.toFixed(2), +ms.toFixed(2)]);
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

  // ---------------------------------------------------------------- score
  // MODULES.score(ctx, D, helpers) builds the graph; the fallback is a quiet bed.
  function scoreHelpers(ctx) {
    const out = ctx.createGain(); out.gain.value = 1; out.connect(ctx.destination);
    const comp = ctx.createDynamicsCompressor(); comp.threshold.value = -18; comp.ratio.value = 1.5; comp.attack.value = 0.03; comp.release.value = 0.18; comp.connect(out);
    const noiseLen = Math.floor(ctx.sampleRate * 4), noise = ctx.createBuffer(1, noiseLen, ctx.sampleRate); { const d = noise.getChannelData(0), rng = mulberry32(4242); for (let i = 0; i < noiseLen; i++) d[i] = rng() * 2 - 1; }
    // room: 650 ms, dark, 12% wet
    const room = ctx.createConvolver(); { const len = Math.floor(ctx.sampleRate * 0.65), buf = ctx.createBuffer(2, len, ctx.sampleRate); for (let ch = 0; ch < 2; ch++) { const d = buf.getChannelData(ch), rng = mulberry32(777 + ch); for (let i = 0; i < len; i++) { const tt = i / ctx.sampleRate; d[i] = (rng() * 2 - 1) * Math.exp(-tt / 0.16) * 0.6 + (Math.abs(tt - 0.043) < 0.0015 ? (rng() * 2 - 1) * 0.5 : 0); } } room.buffer = buf; }
    const roomLP = ctx.createBiquadFilter(); roomLP.type = "lowpass"; roomLP.frequency.value = 2400; const wet = ctx.createGain(); wet.gain.value = 0.12; room.connect(roomLP); roomLP.connect(wet); wet.connect(comp);
    const dry = ctx.createGain(); dry.connect(comp); dry.connect(room);
    // tone(freq, at, {dur, level, atk, dec, rel, sus, type, lp, pan, partials:[[mult,amp]]}) — an ADSR note
    function tone(freq, at, o = {}) {
      const atk = o.atk ?? 0.02, dec = o.dec ?? 0.2, rel = o.rel ?? 0.2, sus = o.sus ?? 0.35, dur = o.dur ?? 0, level = o.level ?? 0.05;
      const lp = ctx.createBiquadFilter(); lp.type = "lowpass"; lp.frequency.value = o.lp ?? 1500;
      const pan = ctx.createStereoPanner(); pan.pan.value = o.pan ?? 0;
      const g = ctx.createGain(); const tEnd = at + atk + dec + dur + rel;
      g.gain.setValueAtTime(0.0001, at); g.gain.linearRampToValueAtTime(level, at + atk); g.gain.exponentialRampToValueAtTime(Math.max(0.0001, level * sus), at + atk + dec);
      if (dur > 0) g.gain.setValueAtTime(Math.max(0.0001, level * sus), at + atk + dec + dur); g.gain.exponentialRampToValueAtTime(0.0001, tEnd);
      for (const [mult, amp, type] of (o.partials || [[1, 1, o.type || "sine"], [1, 0.1, "triangle"], [2, 0.063, "sine"]])) { const osc = ctx.createOscillator(); osc.type = type || "sine"; osc.frequency.value = freq * mult; const pg = ctx.createGain(); pg.gain.value = amp; osc.connect(pg); pg.connect(lp); osc.start(at); osc.stop(tEnd + 0.03); }
      lp.connect(g); g.connect(pan); pan.connect(dry);
    }
    // burst(at, {dur, level, f, q, type:"bandpass"|"lowpass"}) — a filtered-noise event (tick, breath, whoosh)
    function burst(at, o = {}) {
      const s = ctx.createBufferSource(); s.buffer = noise; const f = ctx.createBiquadFilter(); f.type = o.type || "bandpass"; f.frequency.setValueAtTime(o.f ?? 420, at); if (o.fTo) f.frequency.exponentialRampToValueAtTime(o.fTo, at + (o.dur ?? 0.3)); f.Q.value = o.q ?? 1.4;
      const g = ctx.createGain(); const atk = o.atk ?? 0.02, dur = o.dur ?? 0.3, level = o.level ?? 0.012;
      g.gain.setValueAtTime(0.0001, at); g.gain.linearRampToValueAtTime(level, at + atk); g.gain.exponentialRampToValueAtTime(0.0001, at + dur);
      const pan = ctx.createStereoPanner(); pan.pan.value = o.pan ?? 0;
      s.connect(f); f.connect(g); g.connect(pan); pan.connect(dry); s.start(at, (at * 1.37) % 3.5); s.stop(at + dur + 0.05);
    }
    // pad(freqs[], from, to, {level, lp, type, fadeIn, fadeOut}) — a sustained bed of sines
    function pad(freqs, from, to, o = {}) {
      const lp = ctx.createBiquadFilter(); lp.type = "lowpass"; lp.frequency.value = o.lp ?? 700; const g = ctx.createGain(); const level = o.level ?? 0.016, fi = o.fadeIn ?? 2, fo = o.fadeOut ?? 1.5;
      g.gain.setValueAtTime(0.0001, from); g.gain.linearRampToValueAtTime(level, from + fi); g.gain.setValueAtTime(level, Math.max(from + fi, to - fo)); g.gain.linearRampToValueAtTime(0.0001, to);
      lp.connect(g); g.connect(dry);
      freqs.forEach((f, i) => { const osc = ctx.createOscillator(); osc.type = o.type || "sine"; osc.frequency.value = f; const pg = ctx.createGain(); pg.gain.value = i === 0 ? 0.6 : 0.4 / i; osc.connect(pg); pg.connect(lp); osc.start(from); osc.stop(to + 0.05); });
      return g;
    }
    return { ctx, tone, burst, pad, dry, comp, out, noise, N: { C2: 65.406, D2: 73.416, E2: 82.407, F2: 87.307, G2: 97.999, A2: 110, B2: 123.47, C3: 130.81, D3: 146.83, E3: 164.81, F3: 174.61, Fs3: 185, G3: 196, A3: 220, B3: 246.94, C4: 261.63, D4: 293.66, E4: 329.63, F4: 349.23, Fs4: 369.99, G4: 392, A4: 440, B4: 493.88, C5: 523.25, D5: 587.33, E5: 659.26, G5: 783.99, A5: 880 } };
  }
  function fallbackScore(h) {
    h.pad([h.N.D2, h.N.A2, h.N.D3], 0, DURATION, { level: 0.016 });
    for (const s of SHOTS) if (s.start > 0) h.burst(s.start, { dur: 0.9, level: 0.012 });
    const m = SHOTS.find(x => x.primitive === "mark"); if (m) { h.tone(h.N.Fs3, m.start + 1, { dec: 4, rel: 3, level: 0.05, lp: 1200 }); h.tone(h.N.D4, m.start + 1, { dec: 4, rel: 3, level: 0.02, lp: 1200 }); }
  }
  function buildScoreGraph(ctx) {
    const h = scoreHelpers(ctx);
    if (typeof MODULES.score === "function") { try { MODULES.score(h, DURATION, SHOTS, SPEC); return; } catch (e) { errors.push({ shot: "score", error: String(e && e.stack || e).slice(0, 600) }); } }
    fallbackScore(h);
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
    get errors() { return errors.slice(); }, get frameMs() { return frameMs.slice(); }, get broken() { return Object.keys(broken); },
    transcript: SHOTS.filter(s => s.copy).map(s => ({ t: s.start, text: s.copy })).concat((SPEC.voiceover || []).map(v => ({ t: v.t, text: "[voice] " + v.text }))),
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
