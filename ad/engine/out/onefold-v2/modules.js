window.__AD_MODULES__ = {};
__AD_MODULES__["S1"] = (function(){ function shot(c) {
  const { scene: s, light: l, lib, tl } = c;
  const W = 1920, H = 1080;
  const ease = (a, b) => lib.span(tl, a, b, lib.ease);
  const rebuild = ease(0, 0.6), separate = ease(2, 2.6);
  const rake = ease(0.3, 0.9);
  const beat = lib.envelope(tl, [[0.3, 1], [2, 0.65]], 0.045, 0.28);

  // Calibrate visible artwork, rather than mistaking its box for its silhouette.
  const left = -0.445, right = 0.445;
  const top = -0.20, bottom = top + 0.22 * H / 560;
  const forefoot = 0.06, collar = -0.07, sole = 0.155;
  const mx = x => x <= forefoot ? x : forefoot + (x - forefoot) * 1.15;
  const my = y => y < collar ? collar + (y - collar) * 0.8 :
    y > sole ? sole + (y - sole) * 0.8 : y;
  const midX = (mx(left) + mx(right)) / 2;
  const midY = (my(top) + my(bottom)) / 2;
  const size = 648 / (my(bottom) - my(top));
  const widthFit = Math.min(1, 1728 / ((mx(right) - mx(left)) * size));
  const hero = { x: 960 + 54 * separate, y: 540 + 62 * separate };
  const partner = { x: 960 - 54 * separate, y: 540 - 62 * separate };

  // One shared, non-mutating revision: retain the actual supplied illustration.
  function product(ctx, p, only, alpha = 1) {
    const xs = [-2, forefoot, 2], ys = [-2, collar, sole, 2];
    ctx.save();
    ctx.translate(p.x, p.y);
    for (let ix = 0; ix < 2; ix++) {
      for (let iy = 0; iy < 3; iy++) {
        const ax = ix ? 1.15 : 1, bx = ix ? -0.15 * forefoot : 0;
        const ay = iy === 1 ? 1 : 0.8;
        const by = iy === 0 ? 0.2 * collar : iy === 2 ? 0.2 * sole : 0;
        const x0 = (mx(xs[ix]) - midX) * size * widthFit;
        const y0 = (my(ys[iy]) - midY) * size;
        ctx.save();
        ctx.beginPath();
        ctx.rect(x0, y0, (mx(xs[ix + 1]) - mx(xs[ix])) * size * widthFit,
          (my(ys[iy + 1]) - my(ys[iy])) * size);
        ctx.clip();
        ctx.translate((bx - midX) * size * widthFit, (by - midY) * size);
        ctx.scale(ax * widthFit, ay);
        lib.product(ctx, { x: 0, y: 0, size, alpha, only, skip: ["shadow"] });
        ctx.restore();
      }
    }
    ctx.restore();
  }
  function point(x, y) {
    return [hero.x + (mx(x) - midX) * size * widthFit,
      hero.y + (my(y) - midY) * size];
  }

  s.save();
  s.fillStyle = lib.rgba("ground", 1);
  s.fillRect(0, 0, W, H);
  const background = s.createRadialGradient(960, 620, 60, 960, 620, 1050);
  background.addColorStop(0, lib.rgba(lib.mix("B", "A", rebuild), 0.065));
  background.addColorStop(1, lib.rgba("ground", 0));
  s.fillStyle = background;
  s.fillRect(0, 0, W, H);
  function contact(p, alpha) {
    s.save();
    s.translate(p.x, p.y + 330);
    s.scale(1, 0.075);
    const g = s.createRadialGradient(0, 0, 20, 0, 0, 760);
    g.addColorStop(0, `rgba(0,0,0,${alpha})`);
    g.addColorStop(1, "rgba(0,0,0,0)");
    s.fillStyle = g;
    s.fillRect(-760, -760, 1520, 1520);
    s.restore();
  }
  if (separate > 0) {
    contact(partner, 0.32 * separate);
    product(s, partner);
  }
  contact(hero, 0.58);
  product(s, hero);
  s.restore();

  l.save();
  product(l, hero, ["outline"], 0.7);
  l.globalCompositeOperation = "source-in";
  l.fillStyle = lib.rgba(lib.mix("B", "A", rebuild), 0.75 - 0.48 * rebuild);
  l.fillRect(0, 0, W, H);
  l.globalCompositeOperation = "source-over";

  const sweep = hero.x + lib.lerp(-760, 470, rake) + 35 * Math.sin(tl * 2);
  const grazing = l.createLinearGradient(sweep - 230, hero.y - 320, sweep + 190, hero.y + 300);
  grazing.addColorStop(0, lib.rgba("A", 0));
  grazing.addColorStop(0.38, lib.rgba("A", 0.035 * rake));
  grazing.addColorStop(0.52, lib.rgba("ink", (0.11 + beat * 0.1) * rake));
  grazing.addColorStop(0.67, lib.rgba("A", 0.12 * rake));
  grazing.addColorStop(1, lib.rgba("A", 0));
  l.fillStyle = grazing;
  l.fillRect(0, 0, W, H);

  l.lineCap = "round";
  l.strokeStyle = lib.rgba("ink", 0.095 * rebuild);
  l.lineWidth = 0.85;
  l.beginPath();
  for (let i = 0; i < 1008; i++) {
    const col = i % 126, row = Math.floor(i / 126);
    const x = hero.x - 630 + col * 10 + (row % 2) * 5;
    const y = hero.y - 122 + row * 10 + 28 * Math.sin(col / 125 * Math.PI);
    l.moveTo(x - 3, y - 2);
    l.quadraticCurveTo(x, y + 4, x + 3, y - 2);
  }
  l.stroke();

  if (tl < 0.6) {
    const random = lib.rng(109);
    for (let i = 0; i < 92; i++) {
      const u = 0.025 + random() * 0.95;
      const fy = 0.145 + 0.035 * Math.sin(Math.PI * u) - 0.025 * u;
      const startY = -0.19 + random() * 0.37;
      const drift = (random() - 0.5) * 0.1;
      const p = point(-0.445 + 0.89 * u + drift * (1 - rebuild), lib.lerp(startY, fy, rebuild));
      const length = 10 + random() * 24, curl = (4 + random() * 12) * (1 - rebuild);
      l.strokeStyle = lib.rgba(lib.mix("B", "A", rebuild), (0.24 + random() * 0.36) * (1 - rebuild));
      l.lineWidth = 1.1;
      l.beginPath();
      l.moveTo(p[0] - length / 2, p[1] + curl);
      l.bezierCurveTo(p[0] - 5, p[1] - curl, p[0] + 4, p[1] + curl, p[0] + length / 2, p[1]);
      l.stroke();
    }
  }
  lib.glow(l, hero.x - 160, hero.y - 90, 180, "A", 0.26 * beat);
  l.globalCompositeOperation = "destination-in";
  product(l, hero, ["body"]);
  l.globalCompositeOperation = "source-over";
  if (tl < 0.6) {
    const start = point(left, 0)[0], end = point(right, 0)[0];
    const head = lib.lerp(start, end + 150, rebuild);
    l.save();
    l.beginPath();
    l.rect(head - 150, hero.y - 350, 150, 700);
    l.clip();
    product(l, hero, ["fold-highlight"]);
    l.globalCompositeOperation = "source-in";
    const trail = l.createLinearGradient(head - 150, 0, head, 0);
    trail.addColorStop(0, lib.rgba("A", 0));
    trail.addColorStop(0.8, lib.rgba("A", 1));
    trail.addColorStop(1, lib.rgba("A", 0));
    l.fillStyle = trail;
    l.fillRect(head - 150, hero.y - 350, 150, 700);
    l.restore();
  }
  l.restore();
}
 return shot; })();

__AD_MODULES__["S2"] = (function(){ function shot(c) {
  const { scene, light, lib, tl } = c;
  const W = 1920, H = 1080;
  const zoom = lib.span(tl, 0, 0.48, lib.ease);
  const spoken = lib.span(tl, 0.10, 0.34, lib.ease);
  const rake = lib.span(tl, 0.10, 0.70, lib.ease);
  const separation = lib.span(tl, 0, 0.70, lib.ease);
  const cream = lib.span(tl, 2.00, 2.48, lib.ease);
  const advance = lib.span(tl, 2.90, 3.50, lib.ease);
  const drift = lib.clamp(tl / 3.5, 0, 1);
  const scale = (560 + 160 * zoom + 40 * advance) / 720;
  const x = 1060, y = 602, size = 720;
  const rotation = -0.008 * zoom - 0.006 * advance;
  const pulse = Math.exp(-Math.pow((tl - 0.19) / 0.15, 2));

  function camera(ctx, draw) {
    ctx.save();
    ctx.translate(x - 18 * drift, y + 8 * drift);
    ctx.scale(scale, scale);
    ctx.translate(-x, -y);
    draw(ctx);
    ctx.restore();
  }

  scene.save();
  scene.fillStyle = lib.rgba("ground", 1);
  scene.fillRect(0, 0, W, H);

  lib.field(
    scene, 1060 + 32 * drift, 655, 860,
    "A", 0.065 + 0.025 * spoken + 0.008 * pulse
  );
  lib.field(scene, 550, 400, 640, "B", 0.025 * (1 - zoom));

  const floor = scene.createRadialGradient(1050, 835, 15, 1050, 835, 690);
  floor.addColorStop(0, lib.rgba("A", 0.045));
  floor.addColorStop(0.6, lib.rgba("A", 0.012));
  floor.addColorStop(1, lib.rgba("A", 0));
  scene.fillStyle = floor;
  scene.fillRect(250, 430, 1500, 650);

  camera(scene, function(ctx) {
    lib.product(ctx, {
      x: x - 255 - 34 * separation,
      y: y - 165 - 20 * separation,
      size: 625 - 24 * separation,
      alpha: 0.56 - 0.31 * separation,
      rotate: -0.045
    });

    lib.product(ctx, {
      x, y, size,
      alpha: 1,
      rotate: rotation
    });
  });
  scene.restore();

  camera(light, function(ctx) {
    ctx.save();

    // The illustration itself supplies every illuminated knit and edge.
    lib.product(ctx, {
      x, y, size,
      alpha: 1,
      rotate: rotation,
      only: ["detail", "highlight", "outline"]
    });

    ctx.globalCompositeOperation = "source-in";

    const p = 0.27 + 0.32 * rake + 0.025 * drift;
    const grazing = ctx.createLinearGradient(
      x - size * 0.70, y + size * 0.25,
      x + size * 0.70, y - size * 0.25
    );
    grazing.addColorStop(0, lib.rgba("A", 0.015));
    grazing.addColorStop(p - 0.22, lib.rgba("A", 0.035));
    grazing.addColorStop(
      p - 0.08,
      lib.rgba("A", 0.14 + 0.30 * spoken + 0.08 * pulse)
    );
    grazing.addColorStop(p + 0.025, lib.rgba("A", 0.11));
    grazing.addColorStop(
      p + 0.105,
      lib.rgba(lib.mix("A", "ink", cream), 0.08 + 0.72 * cream)
    );
    grazing.addColorStop(
      p + 0.145,
      lib.rgba(lib.mix("A", "ink", cream), 0.025 + 0.32 * cream)
    );
    grazing.addColorStop(p + 0.22, lib.rgba("A", 0.025));
    grazing.addColorStop(1, lib.rgba("A", 0.01));

    ctx.fillStyle = grazing;
    ctx.fillRect(-1920, -1080, 5760, 3240);
    ctx.restore();
  });
}
 return shot; })();

__AD_MODULES__["S3"] = (function(){ function shot(c) {
  const { scene, light, lib, tl } = c;
  const W = lib.W, H = lib.H;
  const pan = lib.span(tl, 0.10, 0.70, lib.ease);
  const reveal = lib.span(tl, 0.10, 0.34, lib.ease);
  const toe = lib.span(tl, 2.00, 2.36, lib.ease);
  const depart = lib.span(tl, 3.32, 3.96, lib.ease);
  const drift = lib.span(tl, 0.70, 3.32, lib.linear);

  const dx = -96 * pan - 14 * drift + 138 * depart;
  const dy = -66 * pan - 5 * drift - 18 * depart;
  const rotation = -0.038 * depart;
  const x = 1000, y = 550;
  const warmCream = lib.mix("A", "ink", 0.34);
  const grazing = 0.24 + 0.22 * reveal;
  const breath = 1 + 0.025 * Math.sin(tl * 2.6);

  scene.save();
  scene.fillStyle = lib.rgba("ground", 1);
  scene.fillRect(0, 0, W, H);

  // Follow the uninterrupted material down into the sole.
  scene.translate(dx, dy);
  lib.product(scene, {
    x, y, size: 760, alpha: 1, rotate: rotation
  });
  scene.restore();

  light.save();
  light.translate(dx, dy);

  // The illustration itself supplies the exact illumination mask.
  lib.product(light, {
    x, y, size: 760, alpha: 1,
    rotate: rotation, skip: ["shadow"]
  });

  light.globalCompositeOperation = "source-in";
  const travel = 12 * pan + 5 * drift;
  const graze = light.createLinearGradient(
    590 + travel, 440,
    1390 + travel, 610
  );

  // A narrow, nearly vertical grazing plane crosses upper and sole together.
  graze.addColorStop(0.000, lib.rgba("A", 0));
  graze.addColorStop(0.315, lib.rgba("A", 0));
  graze.addColorStop(0.355, lib.rgba("A", grazing * 0.12));
  graze.addColorStop(0.386, lib.rgba("A", grazing * 0.62 * breath));
  graze.addColorStop(0.405, lib.rgba(warmCream, grazing * breath));
  graze.addColorStop(0.419, lib.rgba("A", grazing * 0.48));
  graze.addColorStop(0.460, lib.rgba("A", 0));

  // At film time 9s, a second light catches the toe's existing texture.
  graze.addColorStop(0.710, lib.rgba("A", 0));
  graze.addColorStop(0.762, lib.rgba("A", toe * 0.055));
  graze.addColorStop(0.799, lib.rgba("A", toe * 0.21));
  graze.addColorStop(0.825, lib.rgba(warmCream, toe * 0.43 * breath));
  graze.addColorStop(0.840, lib.rgba("A", toe * 0.18));
  graze.addColorStop(0.885, lib.rgba("A", 0));
  graze.addColorStop(1.000, lib.rgba("A", 0));

  light.fillStyle = graze;
  light.fillRect(-400, -400, W + 800, H + 800);
  light.restore();

  // Warm studio spill remains alive as the toe lifts into forward motion.
  light.save();
  light.globalCompositeOperation = "destination-over";
  lib.field(light, 1240 + dx, 610 + dy, 650, "A", 0.035);
  lib.field(
    light, 1390 + 90 * depart, 720 - 25 * depart,
    380, "A", 0.018 + 0.016 * toe
  );
  light.restore();
}
 return shot; })();

__AD_MODULES__["S4"] = (function(){ function shot(c) {
  const { scene: s, light: l, lib, dom, tl, shot } = c;
  const T = lib.clamp(tl, 0, 4);
  const ease = (a, b) => lib.ease(lib.clamp((T - a) / (b - a), 0, 1));
  const key = points => lib.kf(T, points, lib.ease);
  const forward = ease(2, 2.58);
  const finish = ease(3.4, 4);
  const contact = (at, release) => {
    const attack = lib.ease(lib.clamp((T - at) / 0.06, 0, 1));
    const decay = lib.ease(lib.clamp((T - at - 0.06) / release, 0, 1));
    return attack * (1 - decay);
  };
  const beatA = contact(0.1, 0.42);
  const beatB = contact(2, 0.42);
  const leadLift = key([
    [0, -29], [0.1, 0], [0.18, 2], [0.58, -65],
    [1.22, -54], [1.9, -54], [2.48, -77], [3.4, -66], [4, -7]
  ]);
  const rearLift = key([
    [0, -43], [0.58, -65], [1.36, -65], [1.76, -33],
    [2, 0], [2.08, 2], [2.48, -64], [3.12, -72], [4, -72]
  ]);
  const lead = {
    x: 1370 + 22 * ease(0.1, 0.58) + 24 * finish,
    y: 667 + leadLift,
    floor: 793,
    lift: leadLift,
    rotate: key([[0, -0.08], [0.1, 0.025], [0.58, -0.12],
      [1.9, -0.07], [2.48, -0.11], [3.4, -0.09], [4, 0.035]])
  };
  const rear = {
    x: 927 + 42 * ease(1.76, 2.24),
    y: 566 + rearLift,
    floor: 692,
    lift: rearLift,
    rotate: key([[0, -0.11], [0.58, -0.06], [1.76, 0.065],
      [2, 0.012], [2.48, -0.14], [4, -0.08]])
  };

  s.save();
  const background = s.createLinearGradient(0, 0, 0, 1080);
  background.addColorStop(0, "#0c0d0f");
  background.addColorStop(0.5, "#131313");
  background.addColorStop(1, "#201b16");
  s.fillStyle = background;
  s.fillRect(0, 0, 1920, 1080);
  s.restore();

  const zoom = 1 + 0.018 * ease(0, 0.7) + 0.015 * forward;
  for (const ctx of [s, l]) {
    ctx.save();
    ctx.translate(1150 - 16 * forward, 690);
    ctx.scale(zoom, zoom);
    ctx.translate(-1150, -690);
  }

  lib.field(l, 1790, 520, 660, "A", 0.16 + 0.065 * beatA);
  lib.field(l, 140, 750, 580, "B", 0.045);
  const wash = s.createLinearGradient(350, 920, 1780, 420);
  wash.addColorStop(0, lib.rgba("A", 0));
  wash.addColorStop(0.68, lib.rgba("A", 0.045));
  wash.addColorStop(1, lib.rgba("A", 0.105));
  s.fillStyle = wash;
  s.beginPath();
  s.moveTo(1920, 380);
  s.lineTo(1920, 710);
  s.lineTo(560, 1080);
  s.lineTo(0, 1080);
  s.closePath();
  s.fill();

  const vpX = 1880 - 115 * forward;
  const vpY = 314 + 27 * forward;
  const travel = T * 0.205 + forward * 0.13 + finish * 0.045;
  const project = (x, depth) => ({
    x: vpX + (x - vpX) * depth,
    y: vpY + (1150 - vpY) * Math.pow(depth, 1.22)
  });
  const rng = lib.rng(404);
  for (let i = 0; i < 92; i++) {
    const lane = -2550 + rng() * 5550;
    const seed = rng();
    const length = 0.012 + rng() * 0.036;
    const depth = 0.19 + ((seed + travel) % 1) * 0.98;
    const p = project(lane, depth);
    const q = project(lane, depth + length * depth);
    lib.line(s, [[p.x, p.y], [q.x, q.y]], {
      color: i % 7 === 0 ? "A" : i % 4 === 0 ? "B" : "ink",
      width: 0.7 + depth * 1.3,
      alpha: (0.018 + depth * 0.065) * Math.min(1, (depth - 0.19) * 9)
    });
  }
  for (const edge of [-1850, 2270]) {
    for (let j = 0; j < 7; j++) {
      const depth = 0.22 + ((j / 7 + travel * 0.8) % 1) * 1.04;
      const p = project(edge, depth);
      const q = project(edge, depth + 0.055);
      lib.line(s, [[p.x, p.y], [q.x, q.y]], {
        color: "ink", width: 1 + depth * 4, alpha: 0.035 + depth * 0.075
      });
    }
  }

  for (const shoe of [rear, lead]) {
    const proximity = 1 - lib.clamp(-shoe.lift / 90, 0, 1);
    s.save();
    s.translate(shoe.x + 12, shoe.floor);
    s.scale(174 + (1 - proximity) * 30, 14 + (1 - proximity) * 9);
    const shadow = s.createRadialGradient(0, 0, 0, 0, 0, 1);
    shadow.addColorStop(0, "rgba(0,0,0," + (0.25 + proximity * 0.45) + ")");
    shadow.addColorStop(1, "rgba(0,0,0,0)");
    s.fillStyle = shadow;
    s.beginPath();
    s.arc(0, 0, 1, 0, Math.PI * 2);
    s.fill();
    s.restore();
    lib.product(s, { x: shoe.x, y: shoe.y, size: 430, alpha: 1, rotate: shoe.rotate });
  }

  for (const [shoe, pulse] of [[lead, beatA], [rear, beatB]]) {
    lib.glow(l, shoe.x + 85, shoe.floor - 4, 100, "A", pulse * 0.13);
    lib.line(l, [[shoe.x - 110, shoe.floor + 4], [shoe.x + 150, shoe.floor - 3]], {
      color: "A", width: 2, alpha: pulse * 0.44
    });
  }
  s.restore();
  l.restore();

  dom.copy("left", "Out there.", {
    size: 88, y: 215, tIn: shot.start + 0.1, tOut: shot.start + 3.6, color: "ink"
  });
}
 return shot; })();

__AD_MODULES__["S5"] = (function(){ function shot(c) {
  const { scene: s, light: l, lib, tl } = c;
  const W = 1920, H = 1080, size = 648;
  const angle = -12 * Math.PI / 180;
  const p = (a, b) => lib.span(tl, a, b, lib.ease);
  const wear = p(0.42, 0.74);
  const turn = p(2, 2.65);
  const cameraX = 128 * turn + 8 * p(0.8, 1.45);
  const impact = lib.envelope(tl, [[0.1, 1]], 0.055, 0.25);
  const px = 950;
  const py = lib.kf(tl, [
    [0, 534], [0.1, 569], [0.28, 565], [0.54, 569], [3.5, 569]
  ], lib.ease);
  const q = size / 580;
  const pose = ctx => {
    ctx.translate(px, py);
    ctx.rotate(angle);
  };
  const clearLight = () => {
    l.save();
    l.setTransform(1, 0, 0, 1, 0, 0);
    l.clearRect(0, 0, W, H);
    l.restore();
  };

  s.save();
  l.save();
  s.translate(cameraX, 0);
  l.translate(cameraX, 0);

  // Rigid placement: the illustration retains its original silhouette.
  s.save();
  pose(s);
  lib.product(s, { x: 0, y: 0, size, skip: ["shadow"] });
  s.restore();

  // Material abrasion, masked by the illustration's actual upper and sole.
  if (wear > 0) {
    const left = -0.47 * size, width = 0.94 * size;
    for (let zone = 0; zone < 2; zone++) {
      l.save();
      pose(l);
      lib.product(l, {
        x: 0, y: 0, size,
        only: zone ? ["sole"] : ["body", "instep", "knit-upper", "knit-forefoot"]
      });
      if (!zone) {
        l.globalCompositeOperation = "destination-out";
        lib.product(l, { x: 0, y: 0, size, only: ["sole", "opening"] });
      }
      l.globalCompositeOperation = "source-in";
      const tint = lib.mix("A", "ground", zone ? 0.64 : 0.48);
      const opacity = zone ? 0.57 : 0.43;
      const g = l.createLinearGradient(left, 0, left + width, 0);
      // Upper: 23% heel + 12% forefoot. Outsole: 25% heel contact zone.
      const stops = zone
        ? [[0, 0], [0.02, 1], [0.23, 1], [0.25, 0], [1, 0]]
        : [[0, 0], [0.02, 1], [0.21, 1], [0.23, 0],
           [0.78, 0], [0.8, 1], [0.88, 1], [0.9, 0], [1, 0]];
      for (const [at, strength] of stops)
        g.addColorStop(at, lib.rgba(tint, opacity * strength));
      l.fillStyle = g;
      l.fillRect(-size, -size, size * 2, size * 2);
      l.globalCompositeOperation = "source-atop";
      l.lineCap = "round";
      const random = lib.rng(515 + zone * 93);
      for (let i = 0; i < 96; i++) {
        const band = !zone && i % 3 === 0 ? 1 : 0;
        const fraction = zone ? random() * 0.25 :
          band ? 0.78 + random() * 0.12 : random() * 0.23;
        const x = left + width * fraction;
        const y = zone ? (121 + random() * 53) * q :
          (-103 + random() * 256) * q;
        const length = 3 + random() * 15;
        l.strokeStyle = lib.rgba(
          i % 4 ? lib.mix("A", "ink", 0.64) : "ground",
          0.38 + random() * 0.38
        );
        l.lineWidth = 0.7 + random() * 1.3;
        l.beginPath();
        l.moveTo(x, y);
        l.lineTo(x + length, y - 1.5 + random() * 3);
        l.stroke();
      }
      l.restore();
      s.save();
      s.setTransform(1, 0, 0, 1, 0, 0);
      s.globalAlpha = wear;
      s.drawImage(l.canvas, 0, 0);
      s.restore();
      clearLight();
    }
  }

  // The heel comes forward through a rigid camera pan and raking light.
  s.save();
  pose(s);
  s.globalCompositeOperation = "source-atop";
  const rake = s.createLinearGradient(-315, 0, 15, 0);
  rake.addColorStop(0, lib.rgba("ink", 0.17 * turn));
  rake.addColorStop(0.43, lib.rgba("A", 0.12 * turn));
  rake.addColorStop(1, lib.rgba("A", 0));
  s.fillStyle = rake;
  s.fillRect(-size, -size, size * 2, size * 2);
  s.restore();

  // Sweep only the existing fold-highlight: a six-pixel amber leading edge.
  const lateSweep = tl >= 2.2 && tl <= 2.52;
  if (tl <= 0.6 || lateSweep) {
    const a = lateSweep ? 2.2 : 0, b = lateSweep ? 2.52 : 0.6;
    const head = lib.lerp(-size * 0.5, size * 0.5, p(a, b));
    const alpha = p(a, a + 0.025) * (1 - p(b - 0.035, b));
    l.save();
    pose(l);
    lib.product(l, { x: 0, y: 0, size, only: ["fold-highlight"] });
    l.globalCompositeOperation = "source-in";
    const g = l.createLinearGradient(head - 48, 0, head + 3, 0);
    g.addColorStop(0, lib.rgba("A", 0));
    g.addColorStop(42 / 51, lib.rgba("A", alpha * 0.28));
    g.addColorStop(45 / 51, lib.rgba("A", alpha));
    g.addColorStop(48 / 51, lib.rgba("ink", alpha * 0.92));
    g.addColorStop(1, lib.rgba("A", 0));
    l.fillStyle = g;
    l.fillRect(-size, -size, size * 2, size * 2);
    l.restore();
  }

  s.save();
  s.globalCompositeOperation = "destination-over";
  s.fillStyle = lib.rgba("ground", 0.88);
  s.beginPath();
  s.ellipse(738, 805, 78, 8, 0, 0, Math.PI * 2);
  s.fill();
  s.fillStyle = lib.rgba("ground", 0.4);
  s.beginPath();
  s.ellipse(924, 813, 274, 17, 0, 0, Math.PI * 2);
  s.fill();
  for (let i = 0; i < 5; i++)
    lib.line(s, [[140 - tl * 12, 807 + i * 38], [1750, 805 + i * 34]], {
      color: i ? "muted" : "A", width: i ? 0.8 : 1.2,
      alpha: (i ? 0.065 : 0.16) * (1 - 0.45 * turn)
    });
  const bg = s.createRadialGradient(920, 510, 80, 960, 570, 1080);
  bg.addColorStop(0, "#292119");
  bg.addColorStop(0.55, "#141514");
  bg.addColorStop(1, lib.hex("ground"));
  s.fillStyle = bg;
  s.fillRect(-cameraX, 0, W, H);
  s.restore();
  lib.field(l, 690 + tl * 12, 405, 490, "A", 0.045 + 0.035 * turn);
  lib.field(l, 1470, 650, 490, "B", 0.025 + 0.04 * turn);
  lib.glow(l, 738, 798, 92, "A", 0.24 * impact);
  lib.line(l, [[676, 805], [840, 805]], {
    color: "A", width: 1.5, alpha: 0.34 * impact
  });
  l.restore();
  s.restore();
}
 return shot; })();

__AD_MODULES__["S6"] = (function(){ function shot(c) {
  const { scene: s, light: l, lib, dom, tl, shot } = c;
  const pull = lib.span(tl, 0, 0.6, lib.ease);
  const voice = lib.span(tl, 0.3, 0.78, lib.ease);
  const warm = lib.span(tl, 2, 2.6, lib.ease);
  const settle = lib.span(tl, 2.65, 4, lib.ease);
  const zoom = lib.lerp(1.3, 1, pull);
  const sx = 1325, sy = 778;
  const camera = ctx => {
    ctx.save();
    ctx.translate(sx - 12 * settle, sy - 5 * settle);
    ctx.scale(zoom, zoom);
    ctx.translate(-sx, -sy);
  };
  camera(s);
  camera(l);

  const shoes = [
    { x: 585, y: 464, r: -0.055, a: 0.77 },
    { x: 1325, y: 464, r: -0.025, a: 0.72 },
    { x: 585, y: 778, r: -0.07, a: 0.79 },
    { x: sx, y: sy, r: lib.lerp(-0.17, -0.045, pull), a: 1 }
  ];

  // Build the product silhouettes first; source-atop keeps wear in their material.
  shoes.forEach((p, i) => {
    lib.product(s, { x: p.x, y: p.y, size: 280, rotate: p.r, alpha: p.a });
    s.save();
    s.globalCompositeOperation = "source-atop";
    const cold = s.createLinearGradient(p.x, p.y - 140, p.x, p.y + 140);
    cold.addColorStop(0, lib.rgba("B", i === 3 ? 0.18 * (1 - warm) : 0.25));
    cold.addColorStop(1, lib.rgba("ground", i === 3 ? 0.22 - warm * 0.12 : 0.38));
    s.fillStyle = cold;
    s.fillRect(p.x - 300, p.y - 140, 600, 280);
    const rand = lib.rng(610 + i);
    for (let j = 0; j < 19; j++) {
      const x = p.x - 112 + rand() * 221;
      const y = p.y + 8 + rand() * 63;
      const n = 3 + rand() * 12;
      lib.line(s, [[x, y], [x + n * 0.45, y - 1.5], [x + n, y - 0.6]], {
        color: j % 3 ? "ink" : "ground",
        width: 0.65 + rand() * 0.65,
        alpha: j % 3 ? 0.15 : 0.27
      });
    }
    if (i === 3) {
      const amber = s.createRadialGradient(p.x - 65, p.y - 18, 8, p.x - 65, p.y - 18, 235);
      amber.addColorStop(0, lib.rgba("A", 0.48 * warm));
      amber.addColorStop(0.5, lib.rgba("A", 0.23 * warm));
      amber.addColorStop(1, lib.rgba("A", 0));
      s.fillStyle = amber;
      s.fillRect(p.x - 300, p.y - 140, 600, 280);
    }
    s.restore();
  });

  const box = { x: 960, y: 632, size: 1000, scaleX: 1.56, scaleY: 0.68 };
  const cavity = {
    linear: [0, 60, 0, 950],
    stops: [[0, "#111b27"], [0.7, "#101820"], [1, "#182332"]]
  };
  const layers = [
    { tag: "case", path: "M0 30L965 0L1000 40L1000 948L974 990L26 990L0 946Z",
      fill: "#182638", stroke: "#36506d", strokeWidth: 1.4 },
    { tag: "bed", path: "M18 51L980 51L980 936L18 936Z", fill: "#24364a" },
    { tag: "upperLeft", path: "M30 73L483 73L483 476L30 476Z",
      fill: cavity, stroke: "#36506b", strokeWidth: 1 },
    { tag: "upperRight", path: "M517 73L970 73L970 476L517 476Z",
      fill: cavity, stroke: "#36506b", strokeWidth: 1 },
    { tag: "lowerLeft", path: "M30 526L483 526L483 924L30 924Z",
      fill: cavity, stroke: "#36506b", strokeWidth: 1 },
    { tag: "lowerRight", path: "M517 526L970 526L970 924L517 924Z",
      fill: cavity, stroke: "#36506b", strokeWidth: 1 },
    { tag: "vertical", path: "M483 58L500 48L517 58L517 927L500 940L483 927Z",
      fill: "#263e57", stroke: "#456687", strokeWidth: 1.1 },
    { tag: "horizontal", path: "M20 476L980 476L980 526L20 526Z",
      fill: { linear: [0, 476, 0, 526], stops: [[0, "#456381"], [0.2, "#29425c"], [1, "#152331"]] } },
    { tag: "rearRail", path: "M0 30L965 0L1000 40L980 73L18 73Z",
      fill: "#2b4056", stroke: "#53718e", strokeWidth: 1 }
  ];
  s.save();
  s.globalCompositeOperation = "destination-over";
  lib.shapes(s, layers.reverse(), box);
  s.restore();

  lib.shape(s, "M0 924L1000 924L974 990L26 990Z", {
    ...box,
    fill: { linear: [0, 924, 0, 990], stops: [[0, "#354c64"], [0.12, "#1b2b3c"], [1, "#111923"]] },
    stroke: "#3e5670", strokeWidth: 1
  });
  lib.shape(s, "M395 951L605 951L605 961L395 961Z", {
    ...box, fill: "#0c121a", alpha: 0.9
  });

  lib.field(l, 875 - 35 * pull, 350, 680, "B", 0.075);
  lib.line(l, [[960, 326], [960, lib.lerp(326, 920, voice)]], {
    color: "B", width: 1.6, alpha: 0.32 * voice * (1 - 0.45 * warm), glow: 3
  });
  lib.line(l, [[lib.lerp(960, 212, voice), 616], [lib.lerp(960, 1709, voice), 616]], {
    color: "B", width: 1.2, alpha: 0.24 * voice, glow: 2
  });
  lib.field(l, sx - 90 + 24 * settle, sy - 105, 330, "A", 0.17 * warm);
  lib.product(l, {
    x: sx, y: sy, size: 280, rotate: shoes[3].r,
    only: ["highlight"], alpha: 0.44 * warm
  });
  lib.line(l, [[1042, 923], [lib.lerp(1042, 1685, warm), 923]], {
    color: "A", width: 1.7, alpha: 0.5 * warm, glow: 4
  });

  s.restore();
  l.restore();
  s.save();
  s.globalCompositeOperation = "destination-over";
  const ground = s.createLinearGradient(0, 0, 1920, 1080);
  ground.addColorStop(0, "#11151c");
  ground.addColorStop(0.55, "#0b1017");
  ground.addColorStop(1, "#080b10");
  s.fillStyle = ground;
  s.fillRect(0, 0, 1920, 1080);
  s.restore();

  dom.copy("left", "Not a collection.", {
    size: 72, y: 158, color: "ink",
    tIn: shot.start + 0.3, tOut: shot.start + 3.48
  });
}
 return shot; })();

__AD_MODULES__["S7"] = (function(){ function shot(c) {
  const { scene: s, light: l, lib, tl } = c;
  const p = lib.span(tl, 0, 0.48, lib.ease);
  const warm = lib.span(tl, 0, 0.48, lib.ease);
  const settle = lib.span(tl, 0.48, 1.15, lib.ease);
  const carry = lib.span(tl, 1.25, 2, lib.ease);
  const x = lib.lerp(435, 1250, p), y = 554;
  const rgba = (col, a) => lib.rgba(col, a);

  function plane(ctx, points, fill, stroke) {
    ctx.beginPath();
    points.forEach((v, i) => i ? ctx.lineTo(v[0], v[1]) : ctx.moveTo(v[0], v[1]));
    ctx.closePath();
    ctx.fillStyle = fill;
    ctx.fill();
    if (stroke) {
      ctx.strokeStyle = stroke;
      ctx.lineWidth = 1.2;
      ctx.stroke();
    }
  }

  s.save();
  s.fillStyle = rgba("ground", 1);
  s.fillRect(0, 0, 1920, 1080);

  const ambient = s.createRadialGradient(1290, 495, 40, 1230, 590, 880);
  ambient.addColorStop(0, rgba("A", 0.055 + warm * 0.055));
  ambient.addColorStop(1, rgba("ground", 0));
  s.fillStyle = ambient;
  s.fillRect(0, 0, 1920, 1080);

  // The singled-out shoe begins in the last cold compartment.
  s.save();
  s.globalAlpha = 1 - 0.58 * settle;
  const drawer = s.createLinearGradient(0, 344, 0, 800);
  drawer.addColorStop(0, "#233345");
  drawer.addColorStop(0.4, "#111d2b");
  drawer.addColorStop(1, "#10151c");
  plane(s, [[-80, 346], [753, 346], [813, 752], [-80, 752]], drawer);
  plane(s, [[-80, 346], [753, 346], [753, 377], [-80, 377]], "#2a3c50");
  plane(s, [[753, 346], [781, 365], [833, 779], [813, 752]], "#192838");
  const recess = s.createLinearGradient(0, 402, 0, 752);
  recess.addColorStop(0, "#0b1119");
  recess.addColorStop(1, "#1b2837");
  plane(s, [[65, 398], [715, 398], [765, 741], [28, 741]], recess);
  lib.line(s, [[65, 398], [715, 398], [765, 741]], {
    color: "B", width: 1.5, alpha: 0.3
  });
  plane(s, [[-80, 752], [813, 752], [833, 779], [-80, 779]], "#263748");
  plane(s, [[-80, 779], [833, 779], [833, 818], [-80, 818]], "#101820");
  lib.line(s, [[-80, 876], [757, 876], [776, 902]], {
    color: "B", width: 2, alpha: 0.11
  });
  s.restore();

  // A plain, open shipping tray: floor, raised back, and folded sides.
  const back = s.createLinearGradient(0, 413, 0, 494);
  back.addColorStop(0, lib.hex(lib.mix("#514333", "A", 0.14 + warm * 0.2)));
  back.addColorStop(1, "#30281f");
  plane(s, [[943, 413], [1585, 413], [1610, 487], [912, 487]], back);

  const floor = s.createLinearGradient(1090, 467, 1300, 786);
  floor.addColorStop(0, lib.hex(lib.mix("#473b2d", "A", 0.12 + warm * 0.23)));
  floor.addColorStop(0.62, "#66503a");
  floor.addColorStop(1, "#30271f");
  plane(s, [[912, 487], [1610, 487], [1716, 777], [816, 777]], floor);

  const side = s.createLinearGradient(830, 440, 1690, 760);
  side.addColorStop(0, "#6d573e");
  side.addColorStop(1, "#322a22");
  plane(s, [[943, 413], [912, 487], [816, 777], [849, 721]], side);
  plane(s, [[1585, 413], [1610, 487], [1716, 777], [1675, 716]], side);
  lib.line(s, [[943, 413], [1585, 413], [1675, 716]], {
    color: "A", width: 1.3, alpha: 0.16 + warm * 0.2
  });

  // Constant 420px product box; the entire transfer is lateral.
  lib.product(s, { x, y, size: 420, alpha: 1, rotate: 0 });

  const lip = s.createLinearGradient(0, 758, 0, 813);
  lip.addColorStop(0, "#826447");
  lip.addColorStop(0.15, "#51402f");
  lip.addColorStop(1, "#231d18");
  plane(s, [[816, 777], [1716, 777], [1687, 815], [843, 815]], lip);
  lib.line(s, [[816, 777], [1716, 777]], {
    color: "A", width: 1.4, alpha: 0.18 + warm * 0.22
  });
  s.restore();

  // Small wear marks use the actual product layers as their alpha mask.
  l.save();
  lib.product(l, { x, y, size: 420, alpha: 1, only: ["body", "sole"] });
  l.globalCompositeOperation = "source-in";
  const rand = lib.rng(707);
  l.beginPath();
  for (let i = 0; i < 34; i++) {
    const fx = x - 174 + rand() * 348;
    const fy = y + 24 + rand() * 110;
    l.moveTo(fx, fy);
    l.lineTo(fx + 1.5 + rand() * 4, fy - rand() * 1.8);
  }
  l.strokeStyle = rgba("ink", 0.2);
  l.lineWidth = 1.2;
  l.stroke();
  l.restore();

  // L7 onset: cold yields to overhead amber as the shoe crosses.
  l.save();
  l.globalCompositeOperation = "screen";
  lib.field(l, 330, 426, 510, "B", 0.07 * (1 - 0.8 * settle));
  const beam = l.createLinearGradient(0, 118, 0, 820);
  beam.addColorStop(0, rgba("A", 0));
  beam.addColorStop(0.35, rgba("A", 0.015 * warm));
  beam.addColorStop(0.78, rgba("A", (0.075 + carry * 0.018) * warm));
  beam.addColorStop(1, rgba("A", 0));
  plane(l, [[1090, 118], [1350, 118], [1670, 820], [831, 820]], beam);
  lib.field(l, 1250, 455 - 36 * carry, 425, "A", warm * (0.07 + carry * 0.045));
  lib.line(l, [[952, 415], [1577, 415]], {
    color: "A", width: 1.6, alpha: warm * (0.32 + 0.1 * carry), glow: 5
  });
  l.restore();
}
 return shot; })();

__AD_MODULES__["S8"] = (function(){ function shot(c) {
  const { scene: s, light: l, lib, tl } = c;
  const W = 1920, H = 1080, x = 960, y = 500, size = 560;
  const gather = lib.span(tl, 0.10, 0.70, lib.ease);
  const release = lib.span(tl, 0.10, 0.80, lib.ease);
  const reclaim = lib.span(tl, 2.00, 2.60, lib.ease);
  const settle = lib.span(tl, 3.15, 3.80, lib.ease);
  const breathe = Math.sin(tl * 2.1) * 0.012;
  const shoe = { x, y, size, alpha: 1, rotate: 0 };

  // The actual illustration supplies both the product and its alpha boundary.
  s.save();
  lib.product(s, shoe);
  s.globalCompositeOperation = "source-atop";

  // Worn fragments remain on the material, then draw into its knit lattice.
  const random = lib.rng(808);
  for (let i = 0; i < 112; i++) {
    const px = x - 270 + random() * 540;
    const py = y - 255 + random() * 510;
    const length = 2 + random() * 6;
    const angle = random() * 2.2 - 1.1;
    const row = 185 + Math.round((py - 185) / 9.2) * 9.2;
    const dx = lib.lerp(px, px + 16 + 14 * Math.sin(i), reclaim);
    const dy = lib.lerp(py, row, reclaim);
    s.save();
    s.translate(dx, dy);
    s.rotate(angle * (1 - reclaim));
    s.fillStyle = lib.rgba(
      lib.mix(i % 4 === 0 ? "B" : "#45382d", "A", reclaim),
      (0.38 + random() * 0.28) * (1 - reclaim)
    );
    s.beginPath();
    s.ellipse(0, 0, length * (1 + reclaim), 0.65 + random(), 0, 0, Math.PI * 2);
    s.fill();
    s.restore();
  }

  // Construct everything behind the unchanged, 560px product.
  s.globalCompositeOperation = "destination-over";
  const trayY = 682 + 560 * release;
  const trayAlpha = 1 - lib.span(tl, 0.48, 0.80, lib.ease);
  s.globalAlpha = trayAlpha;

  let g = s.createLinearGradient(0, trayY + 44, 0, trayY + 100);
  g.addColorStop(0, "#625040");
  g.addColorStop(1, "#201c19");
  s.fillStyle = g;
  s.beginPath();
  s.moveTo(552, trayY + 44);
  s.lineTo(1368, trayY + 44);
  s.lineTo(1350, trayY + 94);
  s.lineTo(570, trayY + 94);
  s.closePath();
  s.fill();

  g = s.createLinearGradient(680, trayY - 52, 1160, trayY + 50);
  g.addColorStop(0, "#242a30");
  g.addColorStop(0.52, "#64513d");
  g.addColorStop(1, "#34302b");
  s.fillStyle = g;
  s.beginPath();
  s.moveTo(636, trayY - 66);
  s.lineTo(1284, trayY - 66);
  s.lineTo(1368, trayY + 44);
  s.lineTo(552, trayY + 44);
  s.closePath();
  s.fill();
  s.globalAlpha = 1;

  g = s.createRadialGradient(960, 755, 12, 960, 755, 460);
  g.addColorStop(0, lib.rgba("A", 0.045 + gather * 0.085));
  g.addColorStop(1, lib.rgba("A", 0));
  s.fillStyle = g;
  s.fillRect(450, 280, 1020, 800);

  g = s.createLinearGradient(0, 0, 0, H);
  g.addColorStop(0, "#080b10");
  g.addColorStop(0.57, "#100f0e");
  g.addColorStop(1, "#18130e");
  s.fillStyle = g;
  s.fillRect(0, 0, W, H);
  s.restore();

  // One compound stroke is source-in masked by the supplied illustration.
  l.save();
  lib.product(l, shoe);
  l.globalCompositeOperation = "source-in";
  l.beginPath();
  for (let row = 0; row < 70; row++) {
    const targetY = 185 + row * 9.2;
    const looseY = 152 + row * 10.2 + Math.sin(row * 2.31) * 8;
    const yy = lib.lerp(looseY, targetY, gather);
    const amplitude = lib.lerp(9, 2.6, gather) * (1 - reclaim * 0.28);
    l.moveTo(625, yy);
    for (let j = 0; j < 12; j++) {
      const xx = 625 + j * 56;
      const wave = Math.sin(row * 0.61 + j * 0.72 + tl * 1.4);
      const a = amplitude * (0.7 + wave * 0.3);
      l.bezierCurveTo(xx + 17, yy - a, xx + 37, yy + a, xx + 56, yy);
    }
  }
  l.strokeStyle = lib.rgba("A", 0.14 + gather * 0.24 + reclaim * 0.13 - settle * 0.035);
  l.lineWidth = 1.05 + reclaim * 0.3;
  l.stroke();

  // Backlight strengthens on the narration onset without a blackout.
  l.globalCompositeOperation = "destination-over";
  lib.field(l, 970, 540, 610, "A", 0.07 + gather * 0.15 + reclaim * 0.045 + breathe);
  lib.glow(l, 965, 655, 245, "A", 0.05 + gather * 0.12);
  lib.field(l, 570, 610 + release * 200, 340, "B", 0.055 * (1 - release));
  l.globalCompositeOperation = "source-over";

  if (trayAlpha > 0.001) {
    lib.line(l, [[552, trayY + 44], [1368, trayY + 44]], {
      color: "A", width: 1.4, alpha: trayAlpha * 0.42
    });
    lib.line(l, [[636, trayY - 66], [1284, trayY - 66]], {
      color: "B", width: 1, alpha: trayAlpha * 0.17
    });
  }
  l.restore();
}
 return shot; })();

__AD_MODULES__["S9"] = (function(){ function shot(c) {
  const { scene: s, light: l, lib, tl, t } = c;
  const W = 1920, H = 1080;
  const p = (a, b) => lib.span(tl, a, b, lib.ease);
  const resolve = p(0.1, 0.7);
  const reveal = lib.span(t, 29.10, 29.42, lib.ease);
  const sweep = lib.span(t, 29.42, 29.74, lib.ease);
  const stride = p(2, 2.6);
  const poised = p(3.35, 3.95);
  const contact = lib.envelope(tl, [[2.56, 1]], 0.07, 0.3);
  const voice = lib.envelope(tl, [[0.1, 1]], 0.08, 0.4);
  const pan = -8 * tl - 12 * stride;
  const hero = {
    x: 1100 + 48 * stride + 28 * poised,
    y: 568 - 17 * Math.sin(Math.PI * stride) - 8 * poised,
    size: 648,
    rotate: -0.018 - 0.025 * poised,
    alpha: 1
  };
  const rear = {
    x: hero.x - 230 - 38 * (1 - reveal),
    y: hero.y - 110 - 44 * (1 - reveal),
    size: 518,
    rotate: hero.rotate - 0.045 * (1 - reveal),
    alpha: reveal
  };
  function product(ctx, q, only) {
    lib.product(ctx, {
      x: q.x, y: q.y, size: q.size,
      rotate: q.rotate, alpha: q.alpha, only
    });
  }
  function pair(ctx, only) {
    if (reveal > 0) product(ctx, rear, only);
    product(ctx, hero, only);
  }
  function ellipse(ctx, x, y, rx, ry, color, alpha) {
    ctx.fillStyle = lib.rgba(color, alpha);
    ctx.beginPath();
    ctx.ellipse(x, y, rx, ry, -0.025, 0, Math.PI * 2);
    ctx.fill();
  }

  s.save();
  s.fillStyle = lib.rgba("ground", 1);
  s.fillRect(0, 0, W, H);
  s.translate(pan, 0);
  const road = s.createLinearGradient(0, 650, 0, H);
  road.addColorStop(0, lib.rgba("#211b14", 0));
  road.addColorStop(1, lib.rgba("#211b14", 0.72));
  s.fillStyle = road;
  s.fillRect(-60, 620, 2040, 460);
  const roadAlpha = 0.025 + 0.065 * stride + 0.025 * poised;
  lib.line(s, [[430, 1080], [1630, 645]], {
    color: "A", width: 2, alpha: roadAlpha
  });
  lib.line(s, [[1150, 1080], [1790, 645]], {
    color: "ink", width: 1, alpha: roadAlpha * 0.4
  });
  ellipse(s, rear.x + 16, rear.y + 165, 209, 22, "#000000", 0.55 * reveal);
  ellipse(s, hero.x + 20, hero.y + 207, 265, 29, "#000000", 0.68);
  pair(s);
  s.restore();

  // Carry the gathered material forward inside the original silhouette.
  if (resolve < 1) {
    l.save();
    l.translate(pan, 0);
    product(l, hero, ["body", "sole"]);
    l.globalCompositeOperation = "source-in";
    l.translate(hero.x, hero.y);
    l.rotate(hero.rotate);
    l.beginPath();
    for (let i = 0; i < 26; i++) {
      const y = -140 + i * 11;
      const knot = (1 - resolve) * (24 + 12 * Math.sin(i * 1.7));
      l.moveTo(-340, y + 24 * Math.sin(i * 0.8));
      l.bezierCurveTo(
        -175 + knot, y - knot * 2,
        45 - knot, y + knot * 2.1,
        340, y + 31
      );
    }
    l.strokeStyle = lib.rgba("A", 0.48 * (1 - resolve));
    l.lineWidth = 1.4;
    l.stroke();
    l.restore();
    s.drawImage(l.canvas, 0, 0);
    l.clearRect(0, 0, W, H);
  }

  // A six-pixel amber light head sweeps only the existing fold artwork.
  l.save();
  l.translate(pan, 0);
  if (t >= 29.42 && t <= 29.74) {
    pair(l, ["fold-highlight"]);
    l.globalCompositeOperation = "source-in";
    const start = rear.x - rear.size * 0.5;
    const end = hero.x + hero.size * 0.5;
    const head = lib.lerp(start, end, sweep);
    const strength = Math.sin(Math.PI * sweep);
    const fold = l.createLinearGradient(0, 0, W, 0);
    fold.addColorStop(0, lib.rgba("A", 0));
    fold.addColorStop((head - 100) / W, lib.rgba("A", 0));
    fold.addColorStop((head - 35) / W, lib.rgba("A", 0.38 * strength));
    fold.addColorStop((head - 3) / W, lib.rgba("A", strength));
    fold.addColorStop((head + 3) / W, lib.rgba("A", strength));
    fold.addColorStop((head + 24) / W, lib.rgba("A", 0));
    fold.addColorStop(1, lib.rgba("A", 0));
    l.fillStyle = fold;
    l.fillRect(-80, 0, W + 160, H);
    l.globalCompositeOperation = "source-over";
  }
  lib.field(l, 620, 420, 670, "B", 0.055 * (1 - resolve));
  lib.field(l, 1200 + 12 * tl, 440, 660, "A", 0.10 + 0.085 * resolve);
  lib.glow(l, hero.x - 80, hero.y - 115, 240, "A", 0.045 + 0.055 * voice);
  lib.glow(l, hero.x + 65, hero.y + 190, 190, "A", 0.075 + 0.06 * resolve);
  if (reveal > 0) {
    lib.glow(l, rear.x + 45, rear.y + 150, 165, "A",
      reveal * (0.095 + 0.12 * contact));
    ellipse(l, rear.x + 45, rear.y + 163, 155 + 40 * contact, 8,
      "A", reveal * (0.035 + 0.11 * contact));
  }
  lib.field(l, 1510 + 45 * poised, 630, 360, "A", 0.025 + 0.04 * poised);
  l.restore();
}
 return shot; })();

__AD_MODULES__["S10"] = (function(){ function shot(c) {
  const { scene: s, light: l, lib, tl: t } = c;
  const E = lib.ease;
  const sp = (a, b) => lib.span(t, a, b, E);
  const kf = a => lib.kf(t, a, E);
  const push = sp(0.1, 0.6);
  const pass = sp(2, 2.5);
  const zoom = 1 + 0.105 * push;
  const pan = 30 * push + 75 * pass;
  const beatA = lib.envelope(t, [[0.1, 1]], 0.07, 0.43);
  const beatB = lib.envelope(t, [[2, 1]], 0.06, 0.4);
  const travel = t * 0.13 + push * 0.045 + pass * 0.09;
  const shoes = [
    {
      x: kf([[0, 990], [0.6, 1140], [1.35, 1090], [2.55, 930], [4, 1000]]),
      y: kf([[0, 577], [0.38, 623], [0.7, 618], [1.4, 543], [2.55, 574], [4, 564]]),
      r: kf([[0, -0.09], [0.38, 0.025], [0.7, 0], [1.4, -0.1], [2.55, 0.015], [4, -0.035]]),
      floor: kf([[0, 790], [1.3, 790], [2.55, 754], [4, 755]]),
      pulse: beatA,
      warmth: 0.78
    },
    {
      x: kf([[0, 675], [0.65, 770], [1.35, 805], [1.75, 1020], [2, 1290], [2.55, 1510], [4, 1780]]),
      y: kf([[0, 471], [0.65, 482], [1.35, 456], [1.75, 557], [2, 722], [2.2, 731], [2.55, 714], [4, 769]]),
      r: kf([[0, -0.04], [0.65, 0.015], [1.35, -0.16], [1.75, -0.08], [2, 0.03], [2.55, -0.035], [4, -0.055]]),
      floor: kf([[0, 650], [1.35, 650], [1.75, 745], [2, 888], [2.55, 890], [4, 935]]),
      pulse: beatB,
      warmth: 0.62 + 0.3 * pass
    }
  ];
  function camera(ctx) {
    ctx.save();
    ctx.translate(1040 - pan, 680 + 8 * push);
    ctx.scale(zoom, zoom);
    ctx.translate(-1040, -680);
  }
  function ellipse(ctx, x, y, rx, ry, color, alpha) {
    ctx.save();
    ctx.translate(x, y);
    ctx.scale(rx, ry);
    const g = ctx.createRadialGradient(0, 0, 0, 0, 0, 1);
    g.addColorStop(0, lib.rgba(color, alpha));
    g.addColorStop(0.38, lib.rgba(color, alpha * 0.58));
    g.addColorStop(1, lib.rgba(color, 0));
    ctx.fillStyle = g;
    ctx.beginPath();
    ctx.arc(0, 0, 1, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
  }

  camera(s);
  const sky = s.createLinearGradient(0, -200, 0, 1200);
  sky.addColorStop(0, "#080d13");
  sky.addColorStop(0.4, "#11171b");
  sky.addColorStop(1, "#090a0c");
  s.fillStyle = sky;
  s.fillRect(-500, -300, 3000, 1800);
  lib.field(s, 1390, 360, 780, "B", 0.075);
  lib.field(s, 1090, 680, 630, "A", 0.09);

  const road = s.createLinearGradient(0, 330, 0, 1250);
  road.addColorStop(0, "#12191e");
  road.addColorStop(0.32, "#17191a");
  road.addColorStop(1, "#0c0e10");
  s.fillStyle = road;
  s.beginPath();
  s.moveTo(1320, 330);
  s.lineTo(1430, 330);
  s.lineTo(2910, 1280);
  s.lineTo(-950, 1280);
  s.closePath();
  s.fill();
  [-820, -100, 2560, 2940].forEach((x, i) => {
    lib.line(s, [[1370 + (i - 1.5) * 23, 343], [x, 1270]],
      { color: i < 2 ? "B" : "ink", width: i === 1 ? 2 : 1, alpha: 0.065 });
  });
  for (let i = 0; i < 60; i++) {
    const q = ((i % 15) / 15 + travel) % 1;
    const depth = q * q;
    const lane = Math.floor(i / 15);
    const endX = -650 + lane * 940 + ((i * 71) % 170);
    const x = 1370 + (endX - 1370) * depth;
    const y = 345 + depth * 930;
    lib.line(s, [[x, y], [x + (1370 - endX) * 0.016 * q, y - 16 * q]],
      { color: lane === 0 ? "B" : "ink", width: 0.6 + q, alpha: 0.018 + 0.035 * q });
  }
  shoes.forEach(p => {
    ellipse(s, p.x - 25, p.floor + 6, 310, 39, "ground", 0.9);
    ellipse(s, p.x + 35, p.floor, 335 + p.pulse * 110, 34 + p.pulse * 14,
      "A", 0.16 * p.warmth + 0.23 * p.pulse);
    ellipse(s, p.x + 40, p.floor - 5, 208, 12, "A", 0.22 + 0.2 * p.pulse);
  });
  shoes.sort((a, b) => a.y - b.y);
  shoes.forEach(p => {
    lib.product(s, { x: p.x, y: p.y, size: 450, alpha: 1, rotate: p.r });
  });
  s.restore();

  camera(l);
  shoes.forEach(p => {
    ellipse(l, p.x + 55, p.floor - 4, 260 + 80 * p.pulse, 17,
      "A", 0.15 + 0.27 * p.pulse);
    if (p.pulse > 0.001) {
      ellipse(l, p.x + 110, p.floor, 420, 45, "A", 0.1 * p.pulse);
    }
    lib.product(l, {
      x: p.x, y: p.y, size: 450, rotate: p.r,
      alpha: 0.1 + 0.18 * p.pulse, only: ["highlight"]
    });
  });
  l.restore();
}
 return shot; })();

__AD_MODULES__["S11"] = (function(){ function shot(c) {
  const { scene: s, light: l, lib, tl } = c;
  const clamp = v => lib.clamp(v, 0, 1);
  const push = lib.span(tl, 0, 0.6, lib.ease);
  const crossing = lib.span(tl, 0, 0.54, lib.ease);
  const recession = lib.span(tl, 0.3, 0.96, lib.ease);
  const reveal = lib.span(tl, 2, 2.64, lib.ease);
  const settle = lib.span(tl, 3.35, 4, lib.ease);
  const beat = lib.envelope(tl, [[0.3, 1], [2, 0.65]], 0.09, 0.3);
  const zoom = lib.lerp(450 / 650, 1, push);
  const panX = 180 * reveal + 12 * settle;
  const panY = 12 * reveal;
  const x = lib.lerp(1880, 1080, crossing);
  const y = lib.lerp(670, 550, crossing);
  const rotation = lib.lerp(-0.085, -0.018, crossing) + 0.042 * reveal;
  const heelX = x - 194;
  const heelY = y + 42;
  const rgba = (color, a) => lib.rgba(color, a);

  function camera(ctx) {
    ctx.save();
    ctx.translate(960, 560);
    ctx.scale(zoom, zoom);
    ctx.translate(-960, -560);
    ctx.translate(panX, panY);
  }

  s.save();
  s.fillStyle = rgba("ground", 1);
  s.fillRect(0, 0, 1920, 1080);
  const atmosphere = s.createLinearGradient(0, 190, 0, 1080);
  atmosphere.addColorStop(0, rgba("B", 0.025 * (1 - recession)));
  atmosphere.addColorStop(0.64, rgba("ground", 0));
  atmosphere.addColorStop(1, rgba("A", 0.025));
  s.fillStyle = atmosphere;
  s.fillRect(0, 0, 1920, 1080);
  s.restore();

  camera(s);
  camera(l);

  lib.field(l, 720 - recession * 240, 380, 680, "B",
    0.085 - recession * 0.057 - reveal * 0.014);

  // The drawer structure withdraws in depth; its contents remain with it.
  s.save();
  s.translate(770 - 300 * recession - 100 * reveal, 330 - 60 * recession);
  const depth = 1 - 0.46 * recession;
  s.scale(depth, depth);
  s.translate(-770, -330);
  s.globalAlpha = 1 - 0.3 * recession - 0.2 * reveal;

  const floor = s.createLinearGradient(0, 410, 0, 900);
  floor.addColorStop(0, rgba("B", 0.035));
  floor.addColorStop(1, rgba("B", 0.095));
  s.beginPath();
  s.moveTo(390, 420);
  s.lineTo(1230, 420);
  s.lineTo(1710, 905);
  s.lineTo(-90, 905);
  s.closePath();
  s.fillStyle = floor;
  s.fill();
  lib.line(s, [[-90, 905], [1710, 905]], {
    color: "B", width: 2, alpha: 0.28
  });

  for (let i = 0; i < 6; i++) {
    const front = -90 + i * 360;
    const back = 390 + i * 168;
    s.beginPath();
    s.moveTo(back, 420);
    s.lineTo(front, 905);
    s.lineTo(front, 817);
    s.lineTo(back, 389);
    s.closePath();
    s.fillStyle = rgba("B", 0.055 + (i % 2) * 0.025);
    s.fill();
    lib.line(s, [[back, 389], [front, 817]], {
      color: "B", width: 2.2, alpha: 0.43
    });
    lib.line(s, [[front, 817], [front, 905]], {
      color: "B", width: 1.2, alpha: 0.2
    });
  }

  const random = lib.rng(11031);
  for (let i = 0; i < 13; i++) {
    const px = 210 + random() * 1010;
    const py = 520 + random() * 235;
    s.save();
    s.translate(px, py);
    s.rotate((random() - 0.5) * 0.65);
    s.fillStyle = rgba(i % 4 === 0 ? "A" : "B", 0.14 + random() * 0.12);
    s.fillRect(-7, -2, 6 + random() * 13, 2 + random() * 3);
    s.restore();
  }
  s.restore();

  // The incoming footfall leaves a skim of light, not another shoe.
  const skim = (1 - lib.span(tl, 0.18, 0.7, lib.ease)) * 0.3;
  lib.line(l, [[x - 730, y + 177], [x - 80, y + 177]], {
    color: "A", width: 3, alpha: skim, glow: 7
  });

  s.save();
  s.translate(x + 12, y + 174);
  s.scale(1, 0.12);
  const shadow = s.createRadialGradient(0, 0, 20, 0, 0, 345);
  shadow.addColorStop(0, "rgba(0,0,0,0.72)");
  shadow.addColorStop(1, "rgba(0,0,0,0)");
  s.fillStyle = shadow;
  s.fillRect(-350, -350, 700, 700);
  s.restore();

  lib.field(l, x - 35, y + 185, 365, "A", 0.055 + 0.035 * beat);
  lib.glow(s, heelX, heelY, 190, "A", 0.08 + 0.1 * reveal);
  lib.product(s, { x, y, size: 650, alpha: 1, rotate: rotation });

  // A lighting handover, rather than a new contour, reveals the rounded heel.
  lib.product(l, {
    x, y, size: 650, rotate: rotation,
    only: ["highlight"], alpha: 0.08 + 0.13 * reveal + 0.055 * beat
  });
  const lightX = lib.lerp(x + 94, heelX, reveal);
  const lightY = lib.lerp(y + 147, heelY, reveal);
  lib.glow(l, lightX, lightY, 128, "A",
    0.095 + 0.15 * reveal + 0.065 * beat + 0.01 * Math.sin(tl * 2.8));
  lib.field(l, heelX - 35, heelY + 65, 270, "A", 0.045 + 0.045 * reveal);

  s.restore();
  l.restore();
}
 return shot; })();

__AD_MODULES__["S12"] = (function(){ function shot(c) {
  const { scene, light, lib } = c;
  const tl = Math.max(0, c.tl);
  const reframe = lib.span(tl, 0, 0.32, lib.ease);
  const settle = lib.span(tl, 0, 0.6, lib.ease);
  const growth = lib.span(tl, 0, 0.7, lib.easeMark);
  const nameIn = lib.span(c.t, c.shot.start + 0.5, c.shot.start + 0.98, lib.ease);
  const nameRise = lib.span(c.t, c.shot.start + 0.5, c.shot.start + 1.1, lib.ease);
  const breathPhase = lib.span(tl, 0.6, 2, lib.linear);
  const breath = 1 + 0.003 * Math.sin(breathPhase * Math.PI * 2);
  const x = lib.lerp(680, 620, settle);
  const y = lib.lerp(630, 600, settle);
  const size = lib.lerp(650, 600, settle) * breath;
  const heelX = x - size * 0.31;
  const heelY = y + size * 0.055;
  const floorY = y + size * 0.34;
  const dx = lib.lerp(44, 0, reframe);
  const dy = lib.lerp(20, 0, reframe);

  scene.save();
  scene.fillStyle = lib.rgba("ground", 1);
  scene.fillRect(0, 0, 1920, 1080);
  scene.restore();

  for (const ctx of [scene, light]) {
    ctx.save();
    ctx.translate(dx, dy);
  }

  const floor = scene.createLinearGradient(0, 680, 0, 1080);
  floor.addColorStop(0, "rgba(30,26,21,0)");
  floor.addColorStop(0.55, "rgba(30,26,21,0.36)");
  floor.addColorStop(1, "rgba(21,19,17,0.62)");
  scene.fillStyle = floor;
  scene.fillRect(-80, 680, 2080, 480);

  lib.field(scene, 560, 760, 520, "A", 0.32);

  const ellipse =
    "M100 500 C100 458 279 424 500 424 C721 424 900 458 900 500 " +
    "C900 542 721 576 500 576 C279 576 100 542 100 500 Z";

  lib.shape(scene, ellipse, {
    x: x + 8, y: floorY + 4, size: size * 1.12,
    scaleY: 0.58, fill: "ground", alpha: 0.07
  });
  lib.shape(scene, ellipse, {
    x: x + 8, y: floorY + 3, size: size * 1.04,
    scaleY: 0.46, fill: "ground", alpha: 0.12
  });
  lib.shape(scene, ellipse, {
    x: x + 8, y: floorY, size,
    scaleY: 0.32, fill: "ground", alpha: 0.45
  });

  lib.product(scene, { x, y, size, alpha: 1, rotate: 0 });

  light.save();
  lib.product(light, {
    x, y, size, alpha: 1, rotate: 0,
    only: ["body", "sole"]
  });
  light.globalCompositeOperation = "source-in";

  const heel = light.createRadialGradient(
    heelX, heelY, 4, heelX, heelY, size * 0.38
  );
  heel.addColorStop(0, lib.rgba("A", 0.72));
  heel.addColorStop(0.3, lib.rgba("A", 0.38));
  heel.addColorStop(0.7, lib.rgba("A", 0.09));
  heel.addColorStop(1, lib.rgba("A", 0));
  light.fillStyle = heel;
  light.fillRect(-2048, -2048, 6000, 5000);
  light.restore();

  light.save();
  light.globalCompositeOperation = "destination-over";
  lib.glow(light, heelX, heelY, 140, "A", 0.12);
  light.restore();

  lib.mark(
    light, 1300, 360,
    lib.lerp(20, 100, growth),
    64, 0.88, 0.74, 0.14, 1
  );

  lib.text(light, "Onefold", {
    x: 1300,
    y: lib.lerp(568, 560, nameRise),
    size: 152,
    font: "serif",
    color: "ink",
    align: "center",
    alpha: nameIn
  });

  scene.restore();
  light.restore();
}
 return shot; })();

__AD_MODULES__["S13"] = (function(){ function shot(c) {
  const { scene, light, dom, lib, tl } = c;
  const start = c.shot.start;
  const reveal = lib.span(tl, 0.10, 0.52, lib.ease);
  const invitation = lib.span(tl, 0.04, 0.52, lib.ease);
  const sweep = lib.span(tl, 0.08, 0.40, lib.ease);
  const warmth = lib.span(tl, 0.08, 0.40, lib.ease);
  const second = lib.span(tl, 2.00, 2.32, lib.ease);
  const heroScale = lib.lerp(360 / 648, 1, reveal);
  const heroY = lib.lerp(825, 540, reveal);

  function heroCamera(ctx) {
    ctx.translate(960, heroY);
    ctx.scale(heroScale, heroScale);
    ctx.translate(-960, -540);
  }

  scene.save();
  scene.fillStyle = lib.hex("ground");
  scene.fillRect(0, 0, 1920, 1080);

  lib.field(
    scene, 960, 600, 490, "A",
    lib.lerp(0.035, 0.085, warmth)
  );

  if (tl >= 2.00) {
    lib.product(scene, {
      x: lib.lerp(2110, 1580, second),
      y: lib.lerp(675, 620, second),
      size: 320,
      rotate: lib.lerp(-0.12, -0.035, second),
      alpha: 1
    });
  }

  scene.save();
  heroCamera(scene);
  lib.product(scene, {
    x: 960,
    y: 540,
    size: 648,
    alpha: 1
  });
  scene.restore();
  scene.restore();

  light.save();
  heroCamera(light);

  if (tl >= 0.08 && tl < 0.40) {
    lib.product(light, {
      x: 960,
      y: 540,
      size: 648,
      alpha: 0.16,
      only: ["knit-upper", "knit-forefoot", "instep-knit", "sole-knit"]
    });
    lib.product(light, {
      x: 960,
      y: 540,
      size: 648,
      alpha: 1,
      only: ["fold-highlight", "seam"]
    });

    const head = 960 + lib.lerp(-0.46, 0.48, sweep) * 648;
    const width = 88;
    const band = light.createLinearGradient(
      head - width, 0, head + width, 0
    );
    band.addColorStop(0, lib.rgba("A", 0));
    band.addColorStop(0.38, lib.rgba("A", 0.35));
    band.addColorStop(0.55, lib.rgba("A", 1));
    band.addColorStop(1, lib.rgba("A", 0));

    light.globalCompositeOperation = "source-in";
    light.fillStyle = band;
    light.fillRect(580, 160, 780, 780);
    light.globalCompositeOperation = "source-over";
  }

  lib.glow(
    light, 960 - 648 * 0.34, 540 + 648 * 0.06,
    38, "A", lib.lerp(0.22, 0.30, warmth)
  );
  light.restore();

  dom.wordmark("Onefold", {
    size: lib.lerp(152, 144, reveal),
    top: lib.lerp(618, 60, reveal),
    alpha: 1
  });

  dom.tagline("Your next pair starts here.", {
    size: 72,
    top: 936,
    alpha: invitation
  });

  dom.copy("center", "Explore the shoe.", {
    size: 56,
    y: 864,
    color: "ink",
    tIn: start + 0.04,
    tOut: c.shot.end + 1
  });
}
 return shot; })();

__AD_MODULES__["score"] = (function(){ function score(h, D, SHOTS, SPEC) {
  const end = Math.min(Number.isFinite(D) ? D : 45, 45), stop = end - 0.2;
  const N = h.N, fifth = [N.A2, N.D3], warm = [N.A2, N.D3, N.Fs3];
  const cuts = [0, 3.5, 7, 11, 15, 18.5, 22.5, 24.5, 28.5, 32.5, 36.5, 40.5, 42.5];
  function note(f, t, d, level, lp = 180, pan = 0, release = 0.16) {
    if (t < 0 || t >= stop) return;
    const rel = Math.min(release, (stop - t) * 0.4);
    const dur = Math.min(d, stop - t - rel);
    if (dur > 0) h.tone(f, t, {
      dur, level, atk: 0.009, dec: 0.12, sus: 0.48, rel, lp, pan,
      partials: [[1, 1, "sine"], [2, 0.045, "triangle"]]
    });
  }
  function air(t, o) {
    if (t < 0 || t >= stop) return;
    h.burst(t, { ...o, dur: Math.min(o.dur, stop - t) });
  }
  function bed(freqs, a, b, level, lp, fadeIn, fadeOut) {
    b = Math.min(b, stop);
    if (a < b) h.pad(freqs, a, b, {
      level, lp, type: "sine",
      fadeIn: Math.min(fadeIn, (b - a) / 2),
      fadeOut: Math.min(fadeOut, (b - a) / 2)
    });
  }
  // Tonal weight stays below the narration; brushed detail lives above it.
  bed(fifth, 0, 3.5, 0.008, 190, 0.35, 0.12);
  bed(fifth, 3.5, 18.5, 0.009, 195, 0.2, 0.25);
  bed([N.D3], 18.5, 24.5, 0.008, 180, 0.08, 0.18);
  bed(fifth, 24.5, 28.5, 0.010, 195, 0.3, 0.1);
  bed(warm, 28.5, 40.5, 0.010, 240, 0.25, 0.16);
  // 120 BPM; the running section doubles the muted pulse.
  for (let i = 0; i < 162; i++) {
    const t = i * 0.25, running = t >= 32.5, rise = t / 40.5;
    if (!(i % 2) || running) {
      if (!cuts.includes(t)) air(t, {
        dur: running && i % 2 ? 0.065 : 0.095,
        level: 0.009 + rise * 0.006, f: 115, fTo: 48,
        q: 0.75, type: "lowpass", atk: 0.003, pan: 0
      });
      const tt = t + (running ? 0.125 : 0.25);
      if (tt < 40.5) air(tt, {
        dur: t < 7 ? 0.026 : 0.017, level: 0.005 + rise * 0.003,
        f: t < 7 ? 6200 : 7800, fTo: 5900, q: 3.5,
        type: "bandpass", atk: 0.002, pan: i % 4 ? 0.24 : -0.24
      });
    }
  }
  for (let i = 0, t = 3.5; t < 40.5; i++, t += 2) {
    if (!cuts.includes(t)) note(i % 4 === 2 ? N.A2 : N.D2, t, 0.28, 0.011, 155);
  }
  // A repeatable knit grain becomes denser, then releases at 36.5.
  for (let i = 0, t = 7; t < 36.5; i++, t += 0.125) {
    if (i % 4 >= (t < 15 ? 1 : t < 24.5 ? 2 : 3)) continue;
    if (t >= 18.5 && t < 22.5 && i % 8) continue;
    air(t + 0.035, {
      dur: 0.018 + (i % 3) * 0.007, level: 0.005 + (t >= 24.5 ? 0.001 : 0),
      f: (t < 28.5 ? 5600 : 7200) + (i % 5) * 310,
      fTo: 8400, q: 5, type: "bandpass", atk: 0.004,
      pan: ((i % 7) - 3) * 0.13
    });
  }
  cuts.forEach((t, i) => {
    air(t, { dur: 0.11, level: 0.014 + i * 0.0005, f: 125, fTo: 50, q: 0.8, type: "lowpass", atk: 0.002 });
    air(t, { dur: i === 6 ? 0.085 : 0.03, level: i === 6 ? 0.020 : 0.007, f: i === 5 ? 3900 : 6600, fTo: 5200, q: i === 6 ? 1.8 : 4, type: "bandpass", atk: 0.001 });
    if (i < 11) note(i === 7 ? N.A2 : N.D2, t, i === 1 || i === 7 ? 0.85 : 0.36, 0.014, 170);
  });
  air(18.5, { dur: 0.045, level: 0.010, f: 175, fTo: 105, q: 7, type: "bandpass", atk: 0.001 });
  note(N.Fs3, 28.5, 1.2, 0.011, 250, 0.08, 0.3);
  [24.18, 40.18].forEach(t => air(t, { dur: 0.32, level: 0.008, f: 5200, fTo: 8500, q: 3, type: "bandpass", atk: 0.25, pan: -0.15 }));
  // Wordmark: stop the machinery. Invitation: one warm, finite tail.
  [40.5, 42.5].forEach((t, j) => {
    [N.D2, ...warm].forEach((f, k) => note(f, t, j ? 1.65 : 1.28, k ? 0.010 : 0.013, 260, (k - 1.5) * 0.08, j ? 0.65 : 0.32));
  });
}
 return score; })();
