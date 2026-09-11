window.__AD_MODULES__ = {};
__AD_MODULES__["S1"] = (function(){ function shot(c) {
  const { scene, light, lib } = c;
  const A = "#E6A777";
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const time = clamp(c.tl, 0, 6);
  function ease(v) {
    if (v <= 0 || v >= 1) return clamp(v, 0, 1);
    let lo = 0, hi = 1;
    for (let i = 0; i < 16; i++) {
      const s = (lo + hi) / 2, r = 1 - s;
      const x = 1.2 * r * r * s + 0.6 * r * s * s + s * s * s;
      if (x < v) lo = s; else hi = s;
    }
    const s = (lo + hi) / 2;
    return s * s * (3 - 2 * s);
  }
  function cubic(points, x1, y1, x2, y2, x3, y3, count) {
    const a = points[points.length - 1];
    for (let j = 1; j <= count; j++) {
      const t = j / count, r = 1 - t;
      points.push([
        r * r * r * a[0] + 3 * r * r * t * x1 + 3 * r * t * t * x2 + t * t * t * x3,
        r * r * r * a[1] + 3 * r * r * t * y1 + 3 * r * t * t * y2 + t * t * t * y3
      ]);
    }
  }

  scene.save();
  scene.fillStyle = "#05060a";
  scene.fillRect(0, 0, 1920, 1080);
  scene.restore();

  // A single closed silhouette, authored in its 900px square asset box.
  const curves = [
    [626,502,690,539,769,566],
    [803,578,849,582,886,611],
    [919,635,936,666,934,694],
    [933,715,911,733,879,741],
    [810,752,721,751,650,748],
    [579,746,514,745,453,741],
    [359,737,300,722,249,728],
    [211,732,157,734,128,718],
    [113,706,113,681,116,653],
    [119,592,148,536,140,470],
    [136,422,133,381,155,356],
    [177,345,216,402,257,423],
    [279,434,310,435,333,422],
    [363,404,386,364,411,314],
    [420,296,443,302,460,321],
    [495,365,527,420,566,452]
  ];
  const base = [[566, 452]];
  for (const v of curves) cubic(base, ...v, 18);
  for (const p of base) {
    p[0] = 510 + p[0] * 0.9;
    p[1] = 90 + p[1] * 0.9;
  }

  const n = base.length - 1;
  const strand = [];
  // Wear is geometric, not flickering: at most two pixels off the contour.
  for (let i = 0; i <= n; i++) {
    const k = (n - i) % n;
    const p = base[k], a = base[(k + 1) % n], b = base[(k + n - 1) % n];
    const dx = b[0] - a[0], dy = b[1] - a[1];
    const length = Math.hypot(dx, dy) || 1;
    const q = i / n;
    const wear = 2 * (0.68 * Math.sin(q * Math.PI * 74) +
                      0.32 * Math.sin(q * Math.PI * 122));
    strand.push([p[0] - dy / length * wear, p[1] + dx / length * wear]);
  }
  const oldEnd = strand.length - 1;

  // The transfer is part of the same strand, never a detached graphic.
  cubic(strand, 944, 434, 760, 530, 610, 530, 24);
  for (let i = 1; i <= 40; i++) {
    const angle = -Math.PI / 2 - Math.PI * i / 40;
    strand.push([610 + 80 * Math.cos(angle), 610 + 80 * Math.sin(angle)]);
  }
  const seam = 90, renewedStart = base[seam];
  cubic(strand, 780, 690, 930, renewedStart[1],
        renewedStart[0], renewedStart[1], 24);
  const bendEnd = strand.length - 1;
  for (let i = 1; i <= n; i++) strand.push(base[(seam - i + n) % n]);

  const distance = [0];
  for (let i = 1; i < strand.length; i++) {
    distance.push(distance[i - 1] + Math.hypot(
      strand[i][0] - strand[i - 1][0],
      strand[i][1] - strand[i - 1][1]
    ));
  }
  const oldLength = distance[oldEnd];
  const transferLength = distance[bendEnd] - oldLength;
  const newLength = distance[distance.length - 1] - distance[bendEnd];
  const progress = ease(clamp((time - 1) / 4.2, 0, 1));
  let tail, head;
  if (progress <= 0.5) {
    tail = progress * 2 * oldLength;
    head = oldLength + progress * 2 * transferLength;
  } else {
    const p = progress * 2 - 1;
    tail = oldLength + p * transferLength;
    head = oldLength + transferLength + p * newLength;
  }

  function trace(from, to) {
    light.beginPath();
    let started = false;
    for (let i = 1; i < strand.length; i++) {
      const a = distance[i - 1], b = distance[i];
      if (b <= from || a >= to || b === a) continue;
      const p = strand[i - 1], q = strand[i];
      const lo = clamp((from - a) / (b - a), 0, 1);
      const hi = clamp((to - a) / (b - a), 0, 1);
      if (!started) {
        light.moveTo(p[0] + (q[0] - p[0]) * lo, p[1] + (q[1] - p[1]) * lo);
        started = true;
      }
      light.lineTo(p[0] + (q[0] - p[0]) * hi, p[1] + (q[1] - p[1]) * hi);
    }
  }

  light.save();
  light.lineCap = "round";
  light.lineJoin = "round";
  trace(tail, head);
  // Nested translucent strokes give a restrained 100px-radius light falloff.
  for (const [width, alpha] of [[200,.004],[130,.006],[80,.01],[40,.018],[16,.035],[6,.075],[2,.98]]) {
    light.lineWidth = width;
    light.strokeStyle = lib.rgba(A, alpha);
    light.stroke();
  }
  const highlight = clamp((time - 1) / 0.12, 0, 1) * clamp((5.2 - time) / 0.22, 0, 1);
  if (highlight > 0) {
    trace(Math.max(tail, head - 120), head);
    light.lineWidth = 2;
    light.strokeStyle = lib.rgba("ink", highlight);
    light.stroke();
  }
  light.restore();
}
 return shot; })();

__AD_MODULES__["S2"] = (function(){ function shot(c) {
  const { scene, light, lib } = c;
  const t = Math.max(0, c.tl);
  const amber = "#E6A777";
  const blue = "#7194B2";

  function returnEase(p) {
    if (p <= 0) return 0;
    if (p >= 1) return 1;
    let lo = 0, hi = 1;
    for (let i = 0; i < 20; i++) {
      const q = (lo + hi) / 2;
      const x = 1.2 * q - 1.8 * q * q + 1.6 * q * q * q;
      if (x < p) lo = q;
      else hi = q;
    }
    const q = (lo + hi) / 2;
    return q * q * (3 - 2 * q);
  }

  const move = returnEase(Math.min(1, t / 0.9));
  const reveal = Math.min(1, t / 1.4);
  const size = 900 - 280 * move;
  const cy = 540 - 120 * move;

  // One continuous, smooth running-shoe contour in a square SVG coordinate box.
  const start = [120, 580];
  const curves = [
    [110, 532, 125, 449, 142, 377],
    [146, 358, 158, 348, 174, 357],
    [208, 375, 231, 416, 282, 428],
    [316, 438, 347, 426, 371, 399],
    [388, 380, 403, 350, 421, 331],
    [433, 318, 449, 321, 461, 339],
    [497, 389, 530, 433, 586, 465],
    [634, 493, 673, 508, 724, 525],
    [781, 544, 846, 548, 874, 578],
    [890, 594, 900, 618, 894, 640],
    [891, 657, 873, 671, 845, 676],
    [689, 692, 515, 690, 361, 688],
    [271, 687, 184, 688, 137, 672],
    [118, 665, 108, 652, 108, 633],
    [107, 612, 113, 598, 120, 580]
  ];
  const contour = new Path2D();
  contour.moveTo(start[0], start[1]);
  let length = 0;
  let ax = start[0], ay = start[1];

  for (const b of curves) {
    contour.bezierCurveTo(...b);
    let px = ax, py = ay;
    for (let j = 1; j <= 20; j++) {
      const q = j / 20, r = 1 - q;
      const x = r * r * r * ax + 3 * r * r * q * b[0]
        + 3 * r * q * q * b[2] + q * q * q * b[4];
      const y = r * r * r * ay + 3 * r * r * q * b[1]
        + 3 * r * q * q * b[3] + q * q * q * b[5];
      length += Math.hypot(x - px, y - py);
      px = x;
      py = y;
    }
    ax = b[4];
    ay = b[5];
  }
  contour.closePath();

  scene.save();
  scene.setTransform(1, 0, 0, 1, 0, 0);
  scene.globalAlpha = 1;
  scene.globalCompositeOperation = "source-over";
  scene.fillStyle = "#05060a";
  scene.fillRect(0, 0, 1920, 1080);
  scene.restore();

  light.save();
  light.setTransform(1, 0, 0, 1, 0, 0);
  light.globalCompositeOperation = "source-over";
  light.globalAlpha = 1;
  light.shadowBlur = 0;
  light.lineCap = "round";
  light.lineJoin = "round";
  light.setLineDash([]);

  // Screen-space halo reaches 100px from the contour without shadowBlur.
  light.save();
  const scale = size / 1000;
  light.translate(960, cy);
  light.scale(scale, scale);
  light.translate(-500, -500);
  const widths = [200, 150, 106, 70, 44, 24, 12, 6];
  const alphas = [.002, .003, .004, .006, .010, .016, .024, .035];
  for (let i = 0; i < widths.length; i++) {
    light.lineWidth = widths[i] / scale;
    light.strokeStyle = lib.rgba(amber, alphas[i]);
    light.stroke(contour);
  }
  light.lineWidth = 2 / scale;
  light.strokeStyle = amber;
  light.stroke(contour);
  light.restore();

  // The three inert copies trace simultaneously at constant contour speed.
  if (reveal > 0) {
    for (const x of [480, 960, 1440]) {
      light.save();
      light.translate(x, 790);
      light.scale(0.42, 0.42);
      light.translate(-500, -500);
      light.strokeStyle = blue;
      light.lineWidth = 1.5 / 0.42;
      if (reveal < 1) {
        light.setLineDash([length * reveal, length + 10]);
        light.lineDashOffset = 0;
      } else {
        light.setLineDash([]);
      }
      light.stroke(contour);
      light.restore();
    }
  }
  light.restore();
}
 return shot; })();

__AD_MODULES__["S3"] = (function(){ function shot(c) {
  const { scene, light, lib, tl } = c;
  const start = c.shot.start;
  const end = c.shot.end;

  function returnEase(v) {
    if (v <= 0) return 0;
    if (v >= 1) return 1;
    let lo = 0, hi = 1;
    for (let i = 0; i < 22; i++) {
      const s = (lo + hi) * 0.5;
      const x = 1.2 * s - 1.8 * s * s + 1.6 * s * s * s;
      if (x < v) lo = s;
      else hi = s;
    }
    const s = (lo + hi) * 0.5;
    return s * s * (3 - 2 * s);
  }

  const p = returnEase(tl / 1.8);
  const heroY = 420 + 120 * p;
  const heroSize = 620 + 280 * p;
  const poolRadius = 100 + 260 * p;
  const displacement = 1700 * p;

  const contour = new Path2D(
    "M 160 340 " +
    "C 180 342 212 374 256 394 " +
    "C 283 407 316 411 340 397 " +
    "L 398 322 Q 410 307 425 320 " +
    "C 452 349 476 374 503 395 " +
    "C 560 440 622 467 704 486 " +
    "C 760 499 824 512 864 542 " +
    "C 884 557 897 579 898 602 " +
    "L 901 625 " +
    "C 904 653 880 674 847 680 " +
    "C 691 704 480 706 297 694 " +
    "L 159 681 " +
    "C 127 677 107 657 108 631 " +
    "L 118 491 " +
    "C 120 455 122 385 139 350 " +
    "Q 147 336 160 340 Z"
  );

  function position(ctx, x, y, size) {
    ctx.translate(x, y);
    ctx.scale(size / 1000, size / 1000);
    ctx.translate(-500, -500);
  }

  function outline(x, y, size, color, width) {
    light.save();
    position(light, x, y, size);
    light.lineJoin = "round";
    light.lineCap = "round";
    light.lineWidth = width * 1000 / size;
    light.strokeStyle = lib.rgba(color, 1);
    light.stroke(contour);
    light.restore();
  }

  scene.save();
  scene.fillStyle = lib.rgba("ground", 1);
  scene.fillRect(0, 0, 1920, 1080);
  scene.save();
  position(scene, 960, heroY, heroSize);
  scene.fillStyle = lib.rgba("A", 0.025);
  scene.fill(contour);
  scene.restore();
  scene.restore();

  light.save();
  light.beginPath();
  light.rect(0, 0, 1920, 1080);
  light.clip();

  lib.glow(light, 960, heroY, poolRadius, "A", 0.105);

  for (let i = 0; i < 3; i++) {
    outline(480 + 480 * i - displacement, 790, 420, "B", 1.8);
  }

  outline(960, heroY, heroSize, "A", 2.6 + 1.1 * p);
  light.restore();

  const filmTime = start + tl;
  const copyAlpha =
    lib.clamp((tl - 1.8) / 0.48, 0, 1) *
    lib.clamp((end - filmTime) / 0.28, 0, 1);

  if (copyAlpha > 0 && filmTime < end) {
    scene.save();
    scene.font = '500 64px sans-serif';
    scene.textAlign = "center";
    scene.textBaseline = "alphabetic";
    scene.fillStyle = lib.rgba("ink", copyAlpha);
    scene.fillText("One material.", 960, 880);
    scene.restore();
  }
}
 return shot; })();

__AD_MODULES__["S4"] = (function(){ function shot(c) {
  const { scene, light, lib } = c;
  const tl = Math.max(0, Math.min(8, c.tl));
  const clamp = v => Math.max(0, Math.min(1, v));
  const ease = v => {
    v = clamp(v);
    if (v === 0 || v === 1) return v;
    let lo = 0, hi = 1, s = 0.5;
    for (let i = 0; i < 16; i++) {
      s = (lo + hi) / 2;
      const x = 1.2 * (1 - s) * (1 - s) * s +
                0.6 * (1 - s) * s * s + s * s * s;
      if (x < v) lo = s; else hi = s;
    }
    return s * s * (3 - 2 * s);
  };
  const p = ease((tl - 2) / 4.2);
  const wear = 2 * ease(tl / 1.4);
  const rgba = (color, alpha) => lib.rgba(color, alpha);

  scene.save();
  scene.fillStyle = rgba("ground", 1);
  scene.fillRect(0, 0, 1920, 1080);
  scene.restore();

  light.save();
  const radius = 360 + (60 - 360) * p;
  const cy = 540 + 70 * p;
  const pool = light.createRadialGradient(960, cy, 0, 960, cy, radius);
  pool.addColorStop(0, rgba("A", 0.125));
  pool.addColorStop(0.36, rgba("A", 0.062));
  pool.addColorStop(0.72, rgba("A", 0.019));
  pool.addColorStop(1, rgba("A", 0));
  light.fillStyle = pool;
  light.fillRect(960 - radius, cy - radius, radius * 2, radius * 2);

  // One silhouette, inside the stationary 900px product box.
  const raw = [[610, 530]];
  const cubic = (out, x1, y1, x2, y2, x3, y3, n) => {
    const a = out[out.length - 1];
    const x0 = a[0], y0 = a[1];
    for (let i = 1; i <= n; i++) {
      const t = i / n, s = 1 - t;
      out.push([
        s * s * s * x0 + 3 * s * s * t * x1 + 3 * s * t * t * x2 + t * t * t * x3,
        s * s * s * y0 + 3 * s * s * t * y1 + 3 * s * t * t * y2 + t * t * t * y3
      ]);
    }
  };
  const curves = [
    [580,530,568,553,568,590],
    [568,629,580,665,631,679],
    [738,694,1034,689,1233,677],
    [1316,671,1387,650,1390,620],
    [1390,590,1365,572,1325,558],
    [1265,540,1208,544,1154,526],
    [1108,511,1060,473,1026,445],
    [991,414,957,381,925,376],
    [907,373,893,397,881,419],
    [869,439,858,465,847,477],
    [812,488,773,461,751,445],
    [723,429,691,409,661,414],
    [643,417,638,436,639,454],
    [641,477,650,530,610,530]
  ];
  for (const v of curves) cubic(raw, ...v, 18);

  const baseLengths = [0];
  for (let i = 1; i < raw.length; i++)
    baseLengths.push(baseLengths[i - 1] +
      Math.hypot(raw[i][0] - raw[i - 1][0], raw[i][1] - raw[i - 1][1]));
  const perimeter = baseLengths[baseLengths.length - 1];
  const route = raw.map((pt, i) => {
    if (i === 0 || i === raw.length - 1) return pt.slice();
    const a = raw[i - 1], b = raw[i + 1];
    const dx = b[0] - a[0], dy = b[1] - a[1];
    const len = Math.hypot(dx, dy) || 1;
    const distance = baseLengths[i];
    const pin = Math.sin(Math.PI * distance / perimeter) ** 2;
    const wobble = wear * pin * Math.sin(distance * Math.PI * 2 / 58);
    return [pt[0] - dy / len * wobble, pt[1] + dx / len * wobble];
  });
  const shoeEnd = route.length - 1;

  // The departing end follows the exact left-facing, 80px return.
  for (let i = 1; i <= 48; i++) {
    const angle = -Math.PI / 2 - Math.PI * i / 48;
    route.push([610 + 80 * Math.cos(angle), 610 + 80 * Math.sin(angle)]);
  }
  cubic(route, 690, 690, 695, 610, 760, 610, 28);
  const strandStart = route.length - 1;
  route.push([1160, 610]);

  const lengths = [0];
  for (let i = 1; i < route.length; i++)
    lengths.push(lengths[i - 1] +
      Math.hypot(route[i][0] - route[i - 1][0], route[i][1] - route[i - 1][1]));
  const L = lengths[shoeEnd], total = lengths[lengths.length - 1];
  const start = lengths[strandStart] * p;
  const end = L + (total - L) * p;
  const section = (from, to) => {
    const points = [];
    for (let i = 1; i < route.length; i++) {
      const a = lengths[i - 1], b = lengths[i];
      if (b <= from || a >= to) continue;
      const point = d => {
        const f = (d - a) / (b - a);
        return [route[i - 1][0] + (route[i][0] - route[i - 1][0]) * f,
                route[i - 1][1] + (route[i][1] - route[i - 1][1]) * f];
      };
      if (!points.length) points.push(point(Math.max(from, a)));
      points.push(point(Math.min(to, b)));
    }
    return points;
  };
  const trace = points => {
    light.beginPath();
    light.moveTo(points[0][0], points[0][1]);
    for (let i = 1; i < points.length; i++) light.lineTo(points[i][0], points[i][1]);
  };
  light.lineCap = "round";
  light.lineJoin = "round";
  trace(p === 1 ? [[760,610],[1160,610]] : section(start, end));
  if (p === 0) light.closePath();
  for (const [width, alpha] of [[14,0.035],[7,0.12],[3.2,0.96]]) {
    light.lineWidth = width;
    light.strokeStyle = rgba("A", alpha);
    light.stroke();
  }
  const highlight = ease((tl - 2) / 0.18) * (1 - ease((tl - 5.92) / 0.28));
  if (highlight > 0 && p < 1) {
    trace(section(Math.max(start, end - 120), end));
    light.lineWidth = 2.8;
    light.strokeStyle = rgba("ink", highlight * 0.96);
    light.stroke();
  }
  light.restore();
}
 return shot; })();

__AD_MODULES__["S5"] = (function(){ function shot(c) {
  const { scene, light, lib } = c;
  const p = Math.max(0, Math.min(1, c.tl / 3.2));
  const A = "#E6A777";

  // Invert cubic-bezier(0.4, 0, 0.2, 1).
  let lo = 0, hi = 1;
  for (let i = 0; i < 18; i++) {
    const s = (lo + hi) * 0.5;
    const x = 1.2 * (1 - s) * (1 - s) * s +
              0.6 * (1 - s) * s * s + s * s * s;
    if (x < p) lo = s;
    else hi = s;
  }
  const b = (lo + hi) * 0.5;
  const eased = p === 0 ? 0 : p === 1 ? 1 : b * b * (3 - 2 * b);

  scene.save();
  scene.fillStyle = lib.rgba("ground", 1);
  scene.fillRect(0, 0, 1920, 1080);
  scene.restore();

  light.save();
  const radius = 60 + 160 * eased;
  const halo = light.createRadialGradient(960, 540, 0, 960, 540, radius);
  halo.addColorStop(0, lib.rgba(A, 0.15));
  halo.addColorStop(0.32, lib.rgba(A, 0.095));
  halo.addColorStop(0.7, lib.rgba(A, 0.029));
  halo.addColorStop(1, lib.rgba(A, 0));
  light.fillStyle = halo;
  light.fillRect(960 - radius, 540 - radius, radius * 2, radius * 2);

  // One closed contour in a 1000-unit SVG-style box, displayed at 900px.
  // Its first 400 screen pixels are the inherited strand.
  const points = [];
  let length = 0;
  function add(x, y) {
    if (points.length) {
      const last = points[points.length - 1];
      length += Math.hypot(x - last[0], y - last[1]);
    }
    points.push([x, y, length]);
  }
  function cubic(x1, y1, x2, y2, x3, y3) {
    const start = points[points.length - 1];
    const x0 = start[0], y0 = start[1];
    for (let i = 1; i <= 24; i++) {
      const t = i / 24, s = 1 - t;
      add(
        s * s * s * x0 + 3 * s * s * t * x1 +
        3 * s * t * t * x2 + t * t * t * x3,
        s * s * s * y0 + 3 * s * s * t * y1 +
        3 * s * t * t * y2 + t * t * t * y3
      );
    }
  }

  add(2500 / 9, 710);
  add(6500 / 9, 710);
  const inheritedLength = length;
  cubic(845, 710, 947, 694, 957, 650);
  cubic(964, 617, 953, 586, 917, 566);
  cubic(879, 544, 795, 535, 731, 504);
  cubic(668, 473, 616, 416, 574, 357);
  cubic(559, 336, 548, 296, 522, 288);
  cubic(501, 281, 487, 305, 473, 331);
  cubic(449, 368, 430, 407, 388, 416);
  cubic(345, 425, 297, 377, 268, 352);
  cubic(235, 325, 209, 291, 179, 290);
  cubic(142, 287, 126, 316, 124, 350);
  cubic(122, 399, 113, 486, 91, 553);
  cubic(76, 595, 64, 634, 87, 664);
  cubic(109, 695, 173, 710, 2500 / 9, 710);

  // Reveal by arc length, not by Bezier parameter: a linear 3200ms draw.
  const visibleLength = inheritedLength + (length - inheritedLength) * p;
  const settling = 119 * (1 - eased);
  light.translate(510, 90 - settling);
  light.scale(0.9, 0.9);
  light.beginPath();
  light.moveTo(points[0][0], points[0][1]);
  for (let i = 1; i < points.length; i++) {
    const a = points[i - 1], z = points[i];
    if (z[2] <= visibleLength) {
      light.lineTo(z[0], z[1]);
    } else {
      const f = (visibleLength - a[2]) / (z[2] - a[2]);
      light.lineTo(a[0] + (z[0] - a[0]) * f,
                   a[1] + (z[1] - a[1]) * f);
      break;
    }
  }
  if (p === 1) light.closePath();

  light.lineCap = "round";
  light.lineJoin = "round";
  // Small stacked strokes retain the strand's light without a large blur.
  light.strokeStyle = lib.rgba(A, 0.035);
  light.lineWidth = 14 / 0.9;
  light.stroke();
  light.strokeStyle = lib.rgba(A, 0.085);
  light.lineWidth = 8 / 0.9;
  light.stroke();
  light.strokeStyle = lib.rgba(A, 0.98);
  light.lineWidth = 3.8 / 0.9;
  light.stroke();
  light.strokeStyle = lib.rgba(lib.mix(A, "ink", 0.22), 0.52);
  light.lineWidth = 1.2 / 0.9;
  light.stroke();
  light.restore();
}
 return shot; })();

__AD_MODULES__["S6"] = (function(){ function shot(c) {
  const { scene, light, lib } = c;
  const clamp = x => Math.max(0, Math.min(1, x));
  const smooth = x => { x = clamp(x); return x * x * (3 - 2 * x); };
  const rgba = (color, alpha) => lib.rgba(color, alpha);
  function ease(x) {
    x = clamp(x);
    if (x === 0 || x === 1) return x;
    let lo = 0, hi = 1, s = x;
    for (let i = 0; i < 20; i++) {
      s = (lo + hi) / 2;
      const v = 1.2 * (1 - s) * (1 - s) * s + 0.6 * (1 - s) * s * s + s * s * s;
      if (v < x) lo = s; else hi = s;
    }
    return 3 * (1 - s) * s * s + s * s * s;
  }
  const q = ease((c.tl - 0.6) / 4.2);
  const gather = ease((c.tl - 4.2) / 1.8);
  scene.save();
  scene.fillStyle = rgba("ground", 1);
  scene.fillRect(0, 0, 1920, 1080);
  scene.restore();
  light.save();
  light.globalCompositeOperation = "source-over";
  const haloY = 540 - 70 * q, haloR = 220 - 60 * q;
  const halo = light.createRadialGradient(960, haloY, 0, 960, haloY, haloR);
  halo.addColorStop(0, rgba("A", 0.17));
  halo.addColorStop(0.3, rgba("A", 0.09));
  halo.addColorStop(0.68, rgba("A", 0.027));
  halo.addColorStop(1, rgba("A", 0));
  light.fillStyle = halo;
  light.fillRect(960 - haloR, haloY - haloR, haloR * 2, haloR * 2);
  function mark(fade) {
    if (fade <= 0) return;
    light.save();
    // Reflect the helper so amber is left and cream is right.
    light.translate(1920, 0);
    light.scale(-1, 1);
    lib.mark(light, 960, 470, 110, 70, 0.88, 0.74, 0.14, fade);
    light.restore();
  }
  if (gather === 1) {
    mark(1);
    light.restore();
    return;
  }
  function cubic(out, a, b, d, e, steps) {
    for (let i = 1; i <= steps; i++) {
      const t = i / steps, v = 1 - t;
      out.push([
        v * v * v * a[0] + 3 * v * v * t * b[0] + 3 * v * t * t * d[0] + t * t * t * e[0],
        v * v * v * a[1] + 3 * v * v * t * b[1] + 3 * v * t * t * d[1] + t * t * t * e[1]
      ]);
    }
  }
  const segments = [
    [208,351,219,418,289,420], [332,422,354,363,398,337],
    [418,325,438,335,451,360], [500,425,548,465,622,493],
    [705,529,819,527,880,563], [916,584,932,622,900,647],
    [868,670,814,674,743,679], [580,691,432,699,284,692],
    [209,689,155,676,126,650], [105,630,108,589,119,541],
    [128,500,134,437,145,391], [150,371,158,365,170,365]
  ];
  const shoe = [[170, 365]];
  for (const s of segments)
    cubic(shoe, shoe[shoe.length - 1], s.slice(0, 2), s.slice(2, 4), s.slice(4, 6), 16);
  for (const p of shoe) { p[0] = 510 + p[0] * 0.9; p[1] = 90 + p[1] * 0.9; }
  const route = [[1180, 530], [610, 530]];
  for (let i = 1; i <= 64; i++) {
    const a = -Math.PI / 2 - Math.PI * i / 64;
    route.push([610 + 80 * Math.cos(a), 610 + 80 * Math.sin(a)]);
  }
  const bendIndex = route.length - 1;
  const intersectionY = 470 + Math.sqrt(110 * 110 - 70 * 70);
  route.push([792, 690]);
  cubic(route, [792,690], [888,690], [916,603], [960,intersectionY], 32);
  const loopIndex = route.length - 1, angle = Math.atan2(intersectionY - 470, 70);
  for (let i = 1; i <= 64; i++) {
    const a = angle - Math.PI * 2 * i / 64;
    route.push([890 + 110 * Math.cos(a), 470 + 110 * Math.sin(a)]);
  }
  const leftEndIndex = route.length - 1;
  for (let i = 1; i <= 64; i++) {
    const a = Math.PI - angle + Math.PI * 2 * i / 64;
    route.push([1030 + 110 * Math.cos(a), 470 + 110 * Math.sin(a)]);
  }
  function measure(points) {
    const lengths = [0];
    for (let i = 1; i < points.length; i++)
      lengths.push(lengths[i - 1] + Math.hypot(points[i][0] - points[i - 1][0], points[i][1] - points[i - 1][1]));
    return lengths;
  }
  const sl = measure(shoe), rl = measure(route);
  const entry = rl[1], bendEnd = rl[bendIndex], base = rl[loopIndex];
  const leftEnd = rl[leftEndIndex], total = rl[rl.length - 1];
  const travellingHead = q < 0.20 ? entry * q / 0.20
    : q < 0.56 ? entry + (bendEnd - entry) * (q - 0.20) / 0.36
    : q < 0.84 ? bendEnd + (base - bendEnd) * (q - 0.56) / 0.28
    : q < 0.92 ? base + (leftEnd - base) * (q - 0.84) / 0.08
    : leftEnd + (total - leftEnd) * (q - 0.92) / 0.08;
  const tail = leftEnd * gather;
  const head = travellingHead + (leftEnd - travellingHead) * gather;
  const morph = smooth(q / 0.20), strandAlpha = 1 - smooth((gather - 0.62) / 0.38);
  function sampler(points, lengths) {
    let j = 1;
    return d => {
      while (j < lengths.length - 1 && lengths[j] < d) j++;
      const f = clamp((d - lengths[j - 1]) / (lengths[j] - lengths[j - 1] || 1));
      return [points[j - 1][0] + (points[j][0] - points[j - 1][0]) * f,
              points[j - 1][1] + (points[j][1] - points[j - 1][1]) * f];
    };
  }
  const ss = sampler(shoe, sl), rs = sampler(route, rl), points = [];
  for (let i = 0; i <= 300; i++) {
    const f = i / 300, a = ss(sl[sl.length - 1] * f), b = rs(tail + (head - tail) * f);
    points.push([a[0] + (b[0] - a[0]) * morph, a[1] + (b[1] - a[1]) * morph]);
  }
  light.lineCap = "round";
  light.lineJoin = "round";
  light.beginPath();
  points.forEach((p, i) => i ? light.lineTo(p[0], p[1]) : light.moveTo(p[0], p[1]));
  for (const [width, alpha] of [[14, 0.045], [8, 0.12], [3.6, 0.98]]) {
    light.lineWidth = width;
    light.strokeStyle = rgba("A", alpha * strandAlpha);
    light.stroke();
  }
  light.beginPath();
  let remaining = 120, p = points[points.length - 1];
  light.moveTo(p[0], p[1]);
  for (let i = points.length - 2; i >= 0 && remaining > 0; i--) {
    const b = points[i], d = Math.hypot(b[0] - p[0], b[1] - p[1]);
    const f = Math.min(1, remaining / (d || 1));
    light.lineTo(p[0] + (b[0] - p[0]) * f, p[1] + (b[1] - p[1]) * f);
    remaining -= d; p = b;
  }
  light.lineWidth = 3.8;
  light.strokeStyle = rgba("ink", smooth((c.tl - 0.6) / 0.16) * strandAlpha);
  light.stroke();
  mark(smooth(gather));
  light.restore();
}
 return shot; })();

__AD_MODULES__["S7"] = (function(){ function shot(c) {
  const { scene, light, dom, lib } = c;
  const tl = Math.max(0, c.tl);

  function settle(u) {
    u = Math.max(0, Math.min(1, u));
    if (u === 0 || u === 1) return u;
    let lo = 0, hi = 1;
    for (let i = 0; i < 22; i++) {
      const s = (lo + hi) * 0.5;
      const x = 1.2 * s - 1.8 * s * s + 1.6 * s * s * s;
      if (x < u) lo = s;
      else hi = s;
    }
    const s = (lo + hi) * 0.5;
    return s * s * (3 - 2 * s);
  }

  scene.save();
  scene.globalAlpha = 1;
  scene.globalCompositeOperation = "source-over";
  scene.fillStyle = lib.rgba("ground", 1);
  scene.fillRect(0, 0, 1920, 1080);
  scene.restore();

  const haloRadius = 120 - 50 * settle(tl / 0.6);

  light.save();
  light.globalAlpha = 1;
  light.globalCompositeOperation = "source-over";

  const halo = light.createRadialGradient(
    960, 470, 0, 960, 470, haloRadius
  );
  halo.addColorStop(0, lib.rgba("A", 0.20));
  halo.addColorStop(0.35, lib.rgba("A", 0.13));
  halo.addColorStop(0.7, lib.rgba("A", 0.045));
  halo.addColorStop(1, lib.rgba("A", 0));
  light.fillStyle = halo;
  light.beginPath();
  light.arc(960, 470, haloRadius, 0, Math.PI * 2);
  light.fill();

  lib.mark(light, 960, 470, 110, 70, 0.88, 0.74, 0.14, 1);
  light.restore();

  const wordTime = c.t - (c.shot.start + 0.4);
  const alpha = Math.max(0, Math.min(1, wordTime / 0.48));

  dom.wordmark("Onefold", {
    size: 152,
    top: 618 + 8 * (1 - settle(wordTime / 0.8)),
    alpha
  });
}
 return shot; })();

__AD_MODULES__["S8"] = (function(){ function shot(c) {
  const { scene, light, dom, lib } = c;
  const fade = 1 - lib.span(c.t, c.D - 0.8, c.D, lib.linear);
  const taglineAlpha = lib.span(
    c.t,
    c.shot.start + 0.3,
    c.shot.start + 0.9,
    lib.linear
  );

  scene.save();
  scene.globalCompositeOperation = "source-over";
  scene.globalAlpha = 1;
  scene.fillStyle = lib.hex("ground");
  scene.fillRect(0, 0, 1920, 1080);
  scene.restore();

  light.save();
  light.globalCompositeOperation = "source-over";
  light.globalAlpha = 1;
  lib.mark(light, 960, 470, 110, 70, 1, 1, 1, fade);
  light.restore();

  dom.wordmark("Onefold", {
    size: 152,
    top: 618,
    alpha: fade
  });

  dom.tagline("Send back. Run again.", {
    size: 56,
    top: 800,
    alpha: taglineAlpha * fade
  });
}
 return shot; })();

__AD_MODULES__["score"] = (function(){ function score(h, D, SHOTS, SPEC) {
  const c = h.ctx, N = h.N;
  const warmth = c.createBiquadFilter();
  const room = c.createGain();
  warmth.type = "lowpass";
  warmth.frequency.value = 850;
  warmth.Q.value = 0.45;
  warmth.connect(room);
  room.connect(h.dry);

  // Thin the sustained harmony around Lily, without rearticulating it.
  room.gain.setValueAtTime(1, 0);
  room.gain.setValueAtTime(1, 25.4);
  room.gain.linearRampToValueAtTime(0.48, 25.95);
  room.gain.setValueAtTime(0.48, 29.5);
  room.gain.linearRampToValueAtTime(1, 31);

  function bowed(freq, from, to, level, rise, fall) {
    const o = c.createOscillator(), g = c.createGain();
    o.type = "sine";
    o.frequency.value = freq;
    g.gain.setValueAtTime(0, from);
    g.gain.linearRampToValueAtTime(level, from + rise);
    g.gain.setValueAtTime(level, to - fall);
    g.gain.linearRampToValueAtTime(0, to);
    o.connect(g);
    g.connect(warmth);
    o.start(from);
    o.stop(to);
  }

  function felt(freq, at, level, dur, rel, pan) {
    h.tone(freq, at, {
      dur, level, atk: 0.025, dec: 0.85, sus: 0.06, rel,
      lp: 1150, pan,
      partials: [[1, 1, "sine"], [2, 0.13, "sine"], [3, 0.025, "sine"]]
    });
  }

  // One continuous idea; harmonic colors disappear at the picture cuts.
  bowed(N.D3, 1, 43.5, 0.009, 2.8, 5.5);
  bowed(N.A3, 1, 43.5, 0.008, 3.2, 5.5);
  bowed(N.E4, 1, 38, 0.008, 3.5, 0.8);
  bowed(N.F3, 6, 17, 0.008, 1.6, 0.45);
  bowed(N.B3, 25, 38, 0.008, 0.9, 0.8);

  felt(N.D3, 1, 0.022, 2.6, 1.8, -0.12);
  felt(N.A3, 1, 0.015, 2.4, 1.8, 0.06);
  felt(N.E4, 1, 0.011, 2.2, 1.8, 0.14);

  felt(N.F3, 6, 0.010, 1.8, 1.6, -0.06);
  h.burst(6, {
    dur: 2.1, level: 0.005, f: 950, fTo: 950,
    q: 0.5, type: "lowpass", atk: 0.55, pan: -0.1
  });

  bowed(N.A3, 19, 24.3, 0.010, 1.9, 3.2);
  felt(N.B3, 25, 0.010, 0.5, 0.4, 0.08);

  h.burst(32.6, {
    dur: 0.85, level: 0.005, f: 700, fTo: 700,
    q: 0.5, type: "lowpass", atk: 0.22, pan: 0.08
  });

  felt(N.D3, 38, 0.014, 2, 2.8, -0.08);
  felt(N.A3, 38, 0.010, 2, 2.8, 0.08);
  // Bowed D/A reaches zero at 43.5; nothing is scheduled afterward.
}
 return score; })();
