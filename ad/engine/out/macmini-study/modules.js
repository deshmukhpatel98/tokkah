window.__AD_MODULES__ = {};
__AD_MODULES__["S1"] = (function(){ function shot(c) {
  const { three, lib, tl } = c;
  const smooth = (a, b) => {
    const u = lib.span(tl, a, b, lib.linear);
    return u * u * u * (u * (u * 6 - 15) + 10);
  };

  three.studio("white");
  three.camera.fov = 30;
  three.camera.position.set(0, 0.78, 7.9);
  three.camera.lookAt(0, 0.63, 0);
  three.camera.updateProjectionMatrix();

  const box = three.get("box", T => {
    const g = three.group();
    const body = three.roundedBox(
      1.97, 0.5, 1.97, 0.16, three.aluminium("A")
    );
    body.position.y = 0.024;
    g.add(body);

    const roundedPath = (path, h, r) => {
      path.moveTo(-h + r, -h);
      path.lineTo(h - r, -h);
      path.quadraticCurveTo(h, -h, h, -h + r);
      path.lineTo(h, h - r);
      path.quadraticCurveTo(h, h, h - r, h);
      path.lineTo(-h + r, h);
      path.quadraticCurveTo(-h, h, -h, h - r);
      path.lineTo(-h, -h + r);
      path.quadraticCurveTo(-h, -h, -h + r, -h);
      path.closePath();
      return path;
    };
    const outline = roundedPath(new T.Shape(), 0.875, 0.14);
    outline.holes.push(roundedPath(new T.Path(), 0.815, 0.10));
    const sole = new T.Mesh(
      new T.ExtrudeGeometry(outline, {
        depth: 0.024,
        bevelEnabled: false,
        curveSegments: 8,
        steps: 1
      }),
      three.rubber("#151515")
    );
    sole.rotation.x = -Math.PI / 2;
    sole.position.y = -0.25;
    sole.castShadow = true;
    sole.receiveShadow = true;
    g.add(sole);

    const power = three.cylinder(
      0.011, 0.011, 0.006, three.glow("#ffffff", 1.3)
    );
    power.rotation.x = Math.PI / 2;
    power.position.set(0.66, -0.105, 0.984);
    g.add(power);
    return g;
  });

  const hand = three.get("s1-sliding-hand", () => {
    const g = three.group();
    const blue = three.plastic("B", 0.62);

    const arm = three.capsule(0.115, 1.65, blue);
    arm.rotation.z = Math.PI / 2;
    arm.position.set(-1.27, -0.015, 0.065);
    g.add(arm);

    const palm = three.roundedBox(0.44, 0.34, 0.20, 0.095, blue);
    palm.position.set(-0.30, 0, 0.06);
    g.add(palm);

    const fingers = [];
    const lengths = [0.20, 0.27, 0.29, 0.23];
    for (let i = 0; i < 4; i++) {
      const joint = three.group();
      joint.position.set(-0.15, -0.12 + i * 0.081, 0.048);
      const finger = three.capsule(0.041, lengths[i], blue);
      finger.rotation.z = -Math.PI / 2;
      finger.position.x = lengths[i] * 0.5;
      joint.add(finger);
      g.add(joint);
      fingers.push(joint);
    }

    const thumb = three.capsule(0.06, 0.20, blue);
    thumb.position.set(-0.20, 0.19, -0.035);
    thumb.rotation.z = -0.85;
    g.add(thumb);
    g.userData.fingers = fingers;
    g.userData.thumb = thumb;
    return g;
  });

  // Empty hold, one deliberate push, release, then an undisturbed hero.
  const push = smooth(0.55, 1.66);
  const release = smooth(1.76, 2.22);
  const uncurl = smooth(1.76, 2.06);
  const x = -6 * (1 - push);

  box.visible = true;
  box.position.set(x, 0.25, 0);
  box.rotation.set(0, 0, 0);
  box.scale.set(1, 1, 1);

  hand.visible = tl >= 0.55 && tl < 2.24;
  hand.position.set(
    x - 0.99 - 4.5 * release,
    0.28 + 0.075 * Math.sin(Math.PI * release),
    0.985 + 0.12 * release
  );
  hand.rotation.set(0, 0, 0.025 * Math.sin(Math.PI * release));
  hand.scale.set(1, 1, 1);

  for (let i = 0; i < hand.userData.fingers.length; i++) {
    hand.userData.fingers[i].rotation.set(0, -0.32 * uncurl, 0);
  }
  hand.userData.thumb.rotation.set(0, -0.18 * uncurl, -0.85 - 0.12 * uncurl);
}
 return shot; })();

__AD_MODULES__["S2"] = (function(){ function shot(c) {
  const { three, lib, tl } = c;
  const u = lib.clamp(tl / 2.10, 0, 1);
  const push = u * u * (3 - 2 * u);

  three.studio("white");

  const box = three.get("box", T => {
    const hero = three.group();

    const metal = three.aluminium("A");
    const body = three.roundedBox(1.97, 0.5, 1.97, 0.16, metal);
    body.position.set(0, 0.012, 0);
    body.castShadow = true;
    body.receiveShadow = true;
    hero.add(body);

    function roundedContour(path, width, depth, radius) {
      const x = width / 2;
      const z = depth / 2;
      path.moveTo(-x + radius, -z);
      path.lineTo(x - radius, -z);
      path.quadraticCurveTo(x, -z, x, -z + radius);
      path.lineTo(x, z - radius);
      path.quadraticCurveTo(x, z, x - radius, z);
      path.lineTo(-x + radius, z);
      path.quadraticCurveTo(-x, z, -x, z - radius);
      path.lineTo(-x, -z + radius);
      path.quadraticCurveTo(-x, -z, -x + radius, -z);
      path.closePath();
      return path;
    }

    const ringShape = roundedContour(new T.Shape(), 1.78, 1.78, 0.13);
    ringShape.holes.push(
      roundedContour(new T.Path(), 1.62, 1.62, 0.08)
    );

    const ringGeometry = new T.ExtrudeGeometry(ringShape, {
      depth: 0.024,
      steps: 1,
      bevelEnabled: false,
      curveSegments: 10
    });
    const ring = new T.Mesh(ringGeometry, three.rubber("#171819"));
    ring.rotation.x = -Math.PI / 2;
    ring.position.set(0, -0.25, 0);
    ring.castShadow = true;
    ring.receiveShadow = true;
    hero.add(ring);

    const power = three.sphere(0.010, three.glow("#ffffff", 1.3));
    power.position.set(0.67, -0.105, 0.987);
    power.scale.set(1, 1, 0.32);
    power.castShadow = false;
    hero.add(power);

    return hero;
  });

  // Finish the incoming slide without repeating the hand's action.
  const settle = lib.span(tl, 0, 0.32);
  box.position.set(lib.lerp(-0.10, 0, settle), 0.25, 0);
  box.rotation.set(0, 0, 0);
  box.scale.set(1, 1, 1);

  // A restrained, axial push preserves the front-on silhouette.
  const distance = lib.lerp(5.55, 4.85, push);
  const topPreparation = lib.span(tl, 1.65, 2.10);
  const targetY = lib.lerp(0.29, 0.34, topPreparation);
  const camera = three.camera;
  camera.fov = 30;
  camera.position.set(0, targetY + distance * 0.205, distance);
  camera.up.set(0, 1, 0);
  camera.lookAt(0, targetY, 0);
  camera.updateProjectionMatrix();
}
 return shot; })();

__AD_MODULES__["S3"] = (function(){ function shot(c) {
  const { three, lib, light, tl: t } = c, T = three.THREE;
  const mix = (a, b, u) => a + (b - a) * u;
  const s = (a, b) => { const u = Math.max(0, Math.min(1, (t - a) / (b - a))); return u * u * (3 - 2 * u); };
  three.studio("white");
  const stage = three.get("s3-neutral-studio", () => {
    const g = three.group(), floors = [], lights = [];
    three.scene.traverse(o => {
      if (o.isDirectionalLight || o.isSpotLight) lights.push(o);
      if (o.isMesh && o.geometry && (/plane/i.test(o.geometry.type) || /floor|ground|sweep/i.test(o.name))) {
        o.geometry.computeBoundingBox();
        const b = o.geometry.boundingBox;
        if (b && Math.max(b.max.x - b.min.x, b.max.y - b.min.y, b.max.z - b.min.z) > 15) floors.push(o);
      }
    });
    const floor = new T.Mesh(new T.PlaneGeometry(200, 200), new T.MeshBasicMaterial({ color: "#b6b8bd" }));
    floor.rotation.x = -Math.PI / 2; floor.position.y = -0.009; g.add(floor);
    const shadow = new T.Mesh(new T.PlaneGeometry(200, 200), new T.ShadowMaterial({ color: "#17191d", opacity: 0.34 }));
    shadow.rotation.x = -Math.PI / 2; shadow.position.y = -0.008; shadow.receiveShadow = true; g.add(shadow);
    const key = lights.sort((a, b) => b.intensity - a.intensity)[0];
    if (key && key.shadow) { key.shadow.mapSize.set(1024, 1024); key.shadow.radius = 4.5; key.shadow.normalBias = 0.015; }
    g.userData = { floors, key, background: new T.Color("#aaabae"), p: Array.from({ length: 12 }, () => new T.Vector3()) };
    return g;
  });
  stage.position.set(0, 0, 0); stage.rotation.set(0, 0, 0); stage.scale.setScalar(1);
  stage.userData.floors.forEach(o => { o.visible = false; });
  three.scene.background = stage.userData.background;
  three.renderer.toneMapping = T.ACESFilmicToneMapping; three.renderer.toneMappingExposure = 0.57;
  three.renderer.shadowMap.enabled = true; three.renderer.shadowMap.type = T.PCFShadowMap;
  const key = stage.userData.key;
  if (key) { key.position.set(-3.5, 6, -4.5); key.intensity = 3.2; key.castShadow = true; if (key.target) key.target.position.set(0, 0, 0); }
  const box = three.get("box", () => {
    const g = three.group(), metal = three.aluminium("#bfc1c5");
    metal.metalness = 0.8; metal.roughness = 0.3;
    g.add(three.roundedBox(1.97, 0.5, 1.97, 0.16, metal));
    const foot = three.roundedBox(1.87, 0.017, 1.87, 0.15, three.rubber("#161719"));
    foot.position.y = -0.2485; g.add(foot);
    const led = three.sphere(0.012, three.glow("#ffffff", 2.5));
    led.position.set(0.66, -0.153, 0.986); led.scale.z = 0.35; g.add(led);
    return g;
  });
  box.position.set(0, 0.25, 0); box.rotation.set(0, 0, 0); box.scale.setScalar(1);
  box.traverse(o => {
    if (!o.isMesh) return;
    o.castShadow = true; o.receiveShadow = true;
    const mats = Array.isArray(o.material) ? o.material : [o.material];
    mats.forEach(m => { if (m && m.metalness > 0.3) { m.color.set("#bfc1c5"); m.metalness = 0.8; m.roughness = 0.3; } });
  });
  const high = s(0, 0.62), exit = s(2.38, 3.20), close = high * (1 - exit), cam = three.camera;
  cam.clearViewOffset(); cam.zoom = 1; cam.fov = 34;
  cam.position.set(0.85 * close, mix(mix(1.3, 3.65, high), 1.18, exit), mix(mix(5.15, 4.25, high), 5.65, exit));
  cam.lookAt(0, mix(0.3, 0.5, close), 0); cam.updateProjectionMatrix(); cam.updateMatrixWorld(true);
  const p = stage.userData.p;
  const bounds = () => {
    let left = Infinity, right = -Infinity, top = Infinity;
    for (let i = 0; i < 8; i++) {
      p[i].set(i & 1 ? 0.985 : -0.985, i & 2 ? 0.518 : 0, i & 4 ? 0.985 : -0.985).project(cam);
      left = Math.min(left, (p[i].x + 1) * 960); right = Math.max(right, (p[i].x + 1) * 960);
      top = Math.min(top, (1 - p[i].y) * 540);
    }
    return [left, right, top];
  };
  let b = bounds(); cam.zoom = mix(810, 1620, close) / (b[1] - b[0]); cam.updateProjectionMatrix();
  b = bounds();
  cam.setViewOffset(1920, 1080, (b[0] + b[1]) / 2 - 960, (b[2] - 565) * close, 1920, 1080);
  cam.updateProjectionMatrix(); cam.updateMatrixWorld(true);
  const chip = three.get("s3-upgrade-chip-v2", () => {
    const g = three.group();
    g.add(three.roundedBox(0.41, 0.043, 0.42, 0.025, three.plastic("B", 0.4)));
    const die = three.roundedBox(0.31, 0.026, 0.32, 0.018, three.aluminium("#252b35"));
    die.position.y = 0.034; g.add(die);
    const metal = three.aluminium("A");
    for (let side = 0; side < 4; side++) for (let i = 0; i < 6; i++) {
      const pin = three.roundedBox(0.018, 0.015, 0.05, 0.004, metal), v = (i - 2.5) * 0.058;
      if (side < 2) pin.position.set(v, -0.006, side ? -0.218 : 0.218);
      else { pin.rotation.y = Math.PI / 2; pin.position.set(side === 2 ? -0.213 : 0.213, -0.006, v); }
      g.add(pin);
    }
    return g;
  });
  const appear = s(0.18, 0.58), lower = s(0.80, 1.68);
  p[8].set(975 / 960 - 1, 1 - 365 / 540, 0.5).unproject(cam).sub(cam.position).normalize();
  p[9].copy(cam.position).addScaledVector(p[8], (1.25 - cam.position.y) / p[8].y);
  chip.position.set(mix(p[9].x, -0.14, lower), mix(1.25, 0.551, lower), mix(p[9].z, -0.63, lower));
  chip.rotation.set(0.66 * (1 - lower), -0.05 * (1 - lower), -0.055 * (1 - lower));
  chip.scale.setScalar(Math.max(0.001, appear)); chip.visible = t >= 0.18;
  const hand = three.get("s3-upgrade-hand-v2", () => {
    const g = three.group(), mat = three.plastic("A", 0.58);
    const link = (parent, a, b, r) => {
      const av = new T.Vector3(...a), bv = new T.Vector3(...b), m = three.capsule(r, av.distanceTo(bv), mat);
      m.position.copy(av).add(bv).multiplyScalar(0.5);
      m.quaternion.setFromUnitVectors(new T.Vector3(0, 1, 0), bv.sub(av).normalize()); parent.add(m);
    };
    const palm = three.roundedBox(0.32, 0.4, 0.25, 0.115, mat);
    palm.position.set(0.33, 0.44, 0); palm.rotation.z = -0.25; g.add(palm);
    link(g, [0.39, 0.60, 0], [0.69, 1.65, -0.03], 0.105);
    const index = three.group(); index.position.set(0.21, 0.42, -0.10);
    link(index, [0, 0, 0], [-0.27, -0.07, -0.07], 0.056);
    link(index, [-0.27, -0.07, -0.07], [-0.30, -0.38, -0.115], 0.056); g.add(index);
    const thumb = three.group(); thumb.position.set(0.23, 0.28, 0.10);
    link(thumb, [0, 0, 0], [0, -0.21, 0.13], 0.071);
    link(thumb, [0, -0.21, 0.13], [-0.11, -0.26, 0.12], 0.068); g.add(thumb);
    for (let i = 0; i < 3; i++) {
      const z = -0.07 + i * 0.085;
      link(g, [0.38 + i * 0.035, 0.36, z], [0.43 + i * 0.035, 0.17, z], 0.052);
      link(g, [0.43 + i * 0.035, 0.17, z], [0.34 + i * 0.035, 0.13, z], 0.052);
    }
    g.userData = { index, thumb }; return g;
  });
  const release = s(1.73, 2.04), withdraw = s(1.92, 2.58);
  hand.position.copy(chip.position); hand.position.x += 1.1 * withdraw; hand.position.y += 2.5 * withdraw;
  hand.rotation.set(chip.rotation.x, chip.rotation.y, chip.rotation.z - 0.18 * withdraw);
  hand.scale.copy(chip.scale); hand.visible = t >= 0.18 && t < 2.59;
  hand.userData.index.rotation.x = -0.55 * release; hand.userData.thumb.rotation.x = 0.65 * release;
  const spark = three.get("s3-contact-spark-v2", () => {
    const g = three.group(), mat = three.glow("#fff1bb", 5), up = new T.Vector3(0, 1, 0);
    for (let i = 0; i < 5; i++) for (let j = 0; j < 3; j++) {
      const a = i * Math.PI * 2 / 5, r = [0.025, 0.09, 0.12, 0.21], h = [0, 0.055, 0.025, 0.12];
      const v = new T.Vector3(Math.cos(a) * r[j], h[j], Math.sin(a) * r[j]);
      const w = new T.Vector3(Math.cos(a) * r[j + 1], h[j + 1], Math.sin(a) * r[j + 1]);
      const m = three.cylinder(0.007, 0.007, v.distanceTo(w), mat);
      m.position.copy(v).add(w).multiplyScalar(0.5); m.quaternion.setFromUnitVectors(up, w.sub(v).normalize()); g.add(m);
    }
    return g;
  });
  const flash = s(1.68, 1.72) * (1 - s(1.79, 1.96));
  spark.position.set(-0.36, 0.555, -0.40); spark.rotation.set(0, 0.12, 0);
  spark.scale.setScalar(Math.max(0.001, flash)); spark.visible = flash > 0.001;
  if (appear > 0.01) {
    chip.updateMatrixWorld(true);
    p[8].set(0, 0.049, 0.015); p[9].set(0.28, 0.049, 0.015); p[10].set(0, 0.049, -0.125);
    for (let i = 8; i < 11; i++) { p[i].applyMatrix4(chip.matrixWorld).project(cam); p[i].set((p[i].x + 1) * 960, (1 - p[i].y) * 540, p[i].z); }
    light.save();
    light.setTransform((p[9].x - p[8].x) / 180, (p[9].y - p[8].y) / 180, (p[8].x - p[10].x) / 80, (p[8].y - p[10].y) / 80, p[8].x, p[8].y);
    lib.text(light, "Pebble", { x: 0, y: 0, size: 56, font: "sans", color: "ink", align: "center", baseline: "middle", alpha: s(0.30, 0.78) });
    light.restore();
  }
}
 return shot; })();

__AD_MODULES__["S4"] = (function(){ function shot(c) {
  const { three, lib } = c, t = Math.max(0, c.tl);
  const mix = (a, b, u) => a + (b - a) * u;
  const E = (a, b) => { const u = Math.max(0, Math.min(1, (t - a) / (b - a))); return u * u * (3 - 2 * u); };
  const K = keys => {
    for (let i = 1; i < keys.length; i++) if (t < keys[i][0])
      return mix(keys[i - 1][1], keys[i][1], E(keys[i - 1][0], keys[i][0]));
    return keys[keys.length - 1][1];
  };
  const blend = (a, b, u) => a.map((v, i) => mix(v, b[i], u));
  three.studio("white");

  const box = three.get("box", T => {
    const g = three.group(), metal = three.aluminium("A");
    g.add(three.roundedBox(1.97, 0.5, 1.97, 0.16, metal));
    const rounded = (p, h, r) => {
      p.moveTo(-h + r, -h); p.lineTo(h - r, -h); p.quadraticCurveTo(h, -h, h, -h + r);
      p.lineTo(h, h - r); p.quadraticCurveTo(h, h, h - r, h);
      p.lineTo(-h + r, h); p.quadraticCurveTo(-h, h, -h, h - r);
      p.lineTo(-h, -h + r); p.quadraticCurveTo(-h, -h, -h + r, -h); p.closePath();
    };
    const outline = new T.Shape(), hole = new T.Path();
    rounded(outline, 0.905, 0.145); rounded(hole, 0.815, 0.105); outline.holes.push(hole);
    const ring = new T.Mesh(new T.ExtrudeGeometry(outline, { depth: 0.026, bevelEnabled: false, curveSegments: 8 }), three.rubber("#161719"));
    ring.rotation.x = Math.PI / 2; ring.position.y = -0.229; ring.castShadow = true; g.add(ring);
    const light = three.sphere(0.018, three.glow("#ffffff", 2));
    light.scale.set(1, 0.7, 0.3); light.position.set(0.61, -0.13, 0.982); g.add(light);
    return g;
  });

  const rise = E(2.15, 2.65), plant = E(0.73, 1.10), flex = E(2.17, 2.78);
  const height = K([[0, 0.25], [0.70, 0.25], [1.10, 0.94], [1.34, 0.55], [1.57, 0.94], [1.81, 0.54], [2.04, 0.95], [2.19, 0.90], [2.65, 1.20], [2.90, 1.20]]);
  const pitch = K([[0, 0], [1.10, 0.035], [1.34, 0.18], [1.57, 0.025], [1.81, 0.17], [2.04, 0.025], [2.48, 0], [2.90, 0]]);
  box.position.set(0, height, 0); box.rotation.set(pitch, 0, 0); box.scale.set(1, 1, 1);
  const anchor = (x, y, z) => [x, height + y * Math.cos(pitch) - z * Math.sin(pitch), y * Math.sin(pitch) + z * Math.cos(pitch)];
  const relative = (p, origin) => p.map((v, i) => v - origin[i]);

  const pull = E(0.02, 0.43), settle = E(2.32, 2.90);
  three.camera.fov = 30;
  three.camera.position.set(mix(1.85, 0, pull), mix(3.0, 1.65, pull), mix(2.9, 7.6 - 0.35 * settle, pull));
  three.camera.lookAt(0, mix(0.30, 0.83 + 0.10 * settle, pull), 0);
  three.camera.updateProjectionMatrix();

  for (const side of [-1, 1]) {
    const arm = three.get("pebble-arm-" + side, T => {
      const g = three.group(), m = three.plastic("A", 0.32), d = {};
      d.shoulder = three.sphere(0.175, m); d.upper = three.capsule(0.145, 0.46, m);
      d.muscle = three.sphere(0.225, m); d.elbow = three.sphere(0.148, m);
      d.fore = three.capsule(0.135, 0.42, m); d.cuff = three.cylinder(0.152, 0.152, 0.09, three.plastic("B"));
      d.fist = three.group(); d.fist.add(three.roundedBox(0.35, 0.34, 0.38, 0.105, m));
      for (let j = 0; j < 4; j++) {
        const knuckle = three.sphere(0.052, m);
        knuckle.position.set((j - 1.5) * 0.073, 0.09, 0.165); d.fist.add(knuckle);
      }
      for (const key of ["shoulder", "upper", "muscle", "elbow", "fore", "cuff", "fist"]) g.add(d[key]);
      d.up = new T.Vector3(0, 1, 0); d.direction = new T.Vector3(); g.userData.rig = d;
      return g;
    });
    const d = arm.userData.rig, root = anchor(side * 0.97, 0, 0.10);
    const onset = side === 1 ? 0.16 : 0.40, p = E(onset, onset + 0.36);
    const pop = p + Math.sin(p * Math.PI) * 0.10;
    arm.position.set(...root); arm.rotation.set(0, 0, 0); arm.scale.setScalar(Math.max(0.0001, pop));
    const punch = E(onset + 0.08, onset + 0.30);
    let elbow = [side * mix(0.28, 0.62, punch), 0.10, 0.03];
    let fist = [side * mix(0.43, 1.23, punch), 0.02, 0.12];
    elbow = blend(elbow, relative([side * mix(1.61, 1.39, (height - 0.54) / 0.40), 0.33 + height * 0.27, 0.43], root), plant);
    fist = blend(fist, relative([side * 1.51, 0.18, 0.78], root), plant);
    elbow = blend(elbow, relative([side * 1.48, height + 0.20, 0.06], root), flex);
    fist = blend(fist, relative([side * 1.40, height + 0.86, 0.10], root), flex);
    const rod = (mesh, a, b, length) => {
      mesh.position.set((a[0] + b[0]) / 2, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2);
      d.direction.set(b[0] - a[0], b[1] - a[1], b[2] - a[2]);
      const distance = d.direction.length(); d.direction.normalize();
      mesh.quaternion.setFromUnitVectors(d.up, d.direction); mesh.scale.set(1, distance / length, 1);
    };
    rod(d.upper, [0, 0, 0], elbow, 0.75); rod(d.fore, elbow, fist, 0.69);
    d.elbow.position.set(...elbow); d.muscle.position.set(...elbow.map(v => v * 0.55));
    d.muscle.position.y += 0.055; d.muscle.quaternion.copy(d.upper.quaternion); d.muscle.scale.set(1.02, 1.18, 0.95);
    rod(d.cuff, blend(elbow, fist, 0.82), blend(elbow, fist, 0.96), 0.09);
    d.fist.position.set(...fist); d.fist.rotation.set(plant * (1 - flex) * 0.25, 0, -side * flex * 0.25);

    const leg = three.get("pebble-leg-" + side, T => {
      const g = three.group(), m = three.plastic("A", 0.38), d = {};
      d.thigh = three.capsule(0.108, 0.28, m); d.knee = three.sphere(0.139, m);
      d.shin = three.capsule(0.10, 0.26, m); d.boot = three.roundedBox(0.33, 0.18, 0.53, 0.075, three.rubber("#25272a"));
      g.add(d.thigh, d.knee, d.shin, d.boot); d.up = new T.Vector3(0, 1, 0); d.v = new T.Vector3(); g.userData.rig = d; return g;
    });
    const l = leg.userData.rig, hip = anchor(side * 0.64, -0.20, -0.49);
    const knee = relative([side * mix(0.95, 0.72, rise), mix(0.34, 0.55, rise), mix(-0.38, 0.04, rise)], hip);
    const foot = relative([side * mix(0.94, 0.67, rise), 0.095, mix(-0.63, 0.10, rise)], hip);
    leg.position.set(...hip); leg.rotation.set(0, 0, 0); leg.scale.setScalar(Math.max(0.0001, E(0.73, 1.10)));
    const bone = (mesh, a, b, length) => {
      mesh.position.set(...blend(a, b, 0.5)); l.v.set(b[0] - a[0], b[1] - a[1], b[2] - a[2]);
      const n = l.v.length(); l.v.normalize(); mesh.quaternion.setFromUnitVectors(l.up, l.v); mesh.scale.set(1, n / length, 1);
    };
    bone(l.thigh, [0, 0, 0], knee, 0.496); bone(l.shin, knee, foot, 0.46);
    l.knee.position.set(...knee); l.boot.position.set(...foot); l.boot.rotation.set(0, side * 0.12 * rise, 0);
  }

  if (t < 0.34) {
    const transfer = three.get("s4-chip-handoff", T => {
      const g = three.group(), chip = three.group(), hand = three.group();
      chip.add(three.roundedBox(0.43, 0.035, 0.43, 0.025, three.plastic("B")));
      const die = three.roundedBox(0.25, 0.025, 0.25, 0.016, three.aluminium("#cbd4dd")); die.position.y = 0.025; chip.add(die);
      const skin = three.plastic("#f2eadb", 0.5); hand.add(three.roundedBox(0.32, 0.15, 0.34, 0.065, skin));
      for (let i = 0; i < 4; i++) {
        const finger = three.capsule(0.043, 0.20, skin); finger.rotation.x = Math.PI / 2;
        finger.position.set((i - 1.5) * 0.075, -0.015, 0.22); hand.add(finger);
      }
      const thumb = three.capsule(0.05, 0.14, skin); thumb.rotation.z = -0.65; thumb.position.set(0.19, -0.05, 0.04); hand.add(thumb);
      g.add(chip, hand); g.userData.chip = chip; g.userData.hand = hand; return g;
    });
    const q = E(0.06, 0.31);
    transfer.userData.chip.position.set(0, height + 0.27 - q * 0.045, 0);
    transfer.userData.chip.scale.setScalar(Math.max(0.001, 1 - q));
    transfer.userData.hand.position.set(0.16 + q * 0.75, 0.80 + q * 1.55, -0.04);
    transfer.userData.hand.rotation.set(-0.12 - q * 0.45, 0, -0.20);
    transfer.userData.hand.scale.setScalar(1 - E(0.20, 0.34));
  }
}
 return shot; })();

__AD_MODULES__["S5"] = (function(){ function shot(c) {
  const { three, lib } = c;
  if (!three) return;
  const t = Math.max(0, Math.min(2.7, c.tl));
  const span = (a, b) => lib.span(t, a, b);
  const rise = span(0, 0.5);
  const flex = span(0.32, 0.8);
  const retract = span(2.24, 2.7);
  const pump = (span(0.93, 1.08) - span(1.29, 1.47)) +
               (span(1.6, 1.75) - span(2.02, 2.22));
  const extension = 1 - retract;
  const legLength = 0.33 + 0.59 * rise;
  three.studio("white");

  const box = three.get("box", T => {
    const g = three.group();
    const shell = three.roundedBox(1.97, 0.5, 1.97, 0.16, three.aluminium("A"));
    shell.position.y = 0.012;
    g.add(shell);
    const rounded = (p, h, r) => {
      p.moveTo(-h + r, -h);
      p.lineTo(h - r, -h); p.quadraticCurveTo(h, -h, h, -h + r);
      p.lineTo(h, h - r); p.quadraticCurveTo(h, h, h - r, h);
      p.lineTo(-h + r, h); p.quadraticCurveTo(-h, h, -h, h - r);
      p.lineTo(-h, -h + r); p.quadraticCurveTo(-h, -h, -h + r, -h);
      p.closePath();
    };
    const outline = new T.Shape(), hole = new T.Path();
    rounded(outline, 0.885, 0.13);
    rounded(hole, 0.795, 0.09);
    outline.holes.push(hole);
    const ring = new T.Mesh(
      new T.ExtrudeGeometry(outline, { depth: 0.022, bevelEnabled: false, curveSegments: 6 }),
      three.rubber("#191919")
    );
    ring.rotation.x = -Math.PI / 2;
    ring.position.y = -0.25;
    ring.castShadow = ring.receiveShadow = true;
    g.add(ring);
    const bezel = three.roundedBox(0.045, 0.021, 0.012, 0.006, three.rubber("#32302a"));
    bezel.position.set(0.64, -0.157, 0.979);
    const led = three.roundedBox(0.029, 0.01, 0.013, 0.004, three.glow("#ffffff", 1.5));
    led.position.set(0.64, -0.157, 0.986);
    g.add(bezel, led);
    return g;
  });
  box.position.set(0, 0.25 + legLength * extension, 0);
  box.rotation.set(0, 0, 0);
  box.scale.setScalar(1);

  const rig = three.get("s5-flex-rig", T => {
    const g = three.group(), gold = three.plastic("A", 0.4);
    const rubber = three.rubber("#242320");
    const arms = [], legs = [];
    const ball = (parent, radius, material) => {
      const m = three.sphere(radius, material);
      parent.add(m);
      return m;
    };
    const bone = (parent, radius, length) => {
      const m = three.capsule(radius, length, gold);
      m.userData.length = length + radius * 2;
      parent.add(m);
      return m;
    };
    for (const sign of [-1, 1]) {
      const a = three.group();
      g.add(a);
      ball(a, 0.16, gold);
      const upper = bone(a, 0.135, 0.62);
      const muscle = ball(a, 1, gold);
      const elbow = ball(a, 0.151, gold);
      const forearm = bone(a, 0.142, 0.46);
      const fist = three.group();
      const palm = three.roundedBox(0.34, 0.35, 0.32, 0.125, gold);
      fist.add(palm);
      for (let j = 0; j < 3; j++) {
        const knuckle = ball(fist, 0.069, gold);
        knuckle.position.set((j - 1) * 0.093, 0.109, 0.111);
      }
      const thumb = ball(fist, 0.088, gold);
      thumb.scale.set(0.8, 1.28, 1);
      thumb.position.set(-sign * 0.142, -0.035, 0.11);
      a.add(fist);
      arms.push({ root: a, upper, muscle, elbow, forearm, fist, sign });
      const l = three.group();
      g.add(l);
      const thigh = bone(l, 0.124, 0.32);
      const knee = ball(l, 0.139, gold);
      const shin = bone(l, 0.114, 0.32);
      const foot = three.group();
      const shoe = three.roundedBox(0.35, 0.18, 0.55, 0.085, gold);
      const sole = three.roundedBox(0.37, 0.055, 0.59, 0.026, rubber);
      sole.position.y = -0.0875;
      foot.add(shoe, sole);
      l.add(foot);
      legs.push({ root: l, thigh, knee, shin, foot, sign });
    }
    g.userData = { arms, legs, up: new T.Vector3(0, 1, 0), delta: new T.Vector3() };
    return g;
  });
  rig.position.copy(box.position);
  rig.rotation.set(0, 0, 0);
  rig.scale.setScalar(1);
  const data = rig.userData;
  const segment = (m, ax, ay, az, bx, by, bz, base) => {
    data.delta.set(bx - ax, by - ay, bz - az);
    const length = Math.max(0.0001, data.delta.length());
    m.position.set((ax + bx) / 2, (ay + by) / 2, (az + bz) / 2);
    m.quaternion.setFromUnitVectors(data.up, data.delta.multiplyScalar(1 / length));
    m.scale.set(1, length / (base || m.userData.length), 1);
  };
  for (const a of data.arms) {
    const s = a.sign, ex = s * (0.4 + 0.42 * flex);
    const ey = -0.32 + 0.57 * flex + 0.035 * pump;
    const wx = s * (0.34 + 0.35 * flex - 0.09 * pump);
    const wy = (0.21 - (0.25 + legLength)) * (1 - flex) + 0.93 * flex + 0.065 * pump;
    a.root.position.set(s * 0.995, 0.025, 0.14);
    a.root.scale.setScalar(extension);
    segment(a.upper, 0, 0, 0, ex, ey, 0);
    segment(a.muscle, 0, 0, 0, ex, ey, 0, 2);
    a.muscle.scale.x = 0.215 * (1 + 0.16 * pump);
    a.muscle.scale.z = 0.205 * (1 + 0.12 * pump);
    a.elbow.position.set(ex, ey, 0);
    segment(a.forearm, ex, ey, 0, wx, wy, 0.035);
    a.fist.position.set(wx, wy, 0.035);
    a.fist.rotation.set(0, s * 0.12, s * (0.08 + 0.12 * pump));
  }
  for (const l of data.legs) {
    const s = l.sign, ky = -legLength * 0.53, kz = 0.12 + 0.21 * (1 - rise);
    l.root.position.set(s * 0.57, -0.25, 0);
    l.root.scale.setScalar(extension);
    segment(l.thigh, 0, 0, 0, s * 0.065, ky, kz);
    l.knee.position.set(s * 0.065, ky, kz);
    segment(l.shin, s * 0.065, ky, kz, s * 0.09, 0.16 - legLength, 0.23);
    l.foot.position.set(s * 0.09, 0.115 - legLength, 0.28);
    l.foot.rotation.set(0, s * 0.09, 0);
  }
  three.camera.fov = 31;
  three.camera.position.set(0, 1.46 - 0.39 * retract, 7.4 - 0.55 * rise + 0.75 * retract);
  three.camera.lookAt(0, 1.18 - 0.5 * retract, 0);
  three.camera.updateProjectionMatrix();
}
 return shot; })();

__AD_MODULES__["S6"] = (function(){ function shot(c) {
  const { three, lib } = c, t = c.tl;
  const clamp = v => Math.max(0, Math.min(1, v));
  const smooth = v => { v = clamp(v); return v * v * (3 - 2 * v); };
  const p = (a, b) => smooth((t - a) / (b - a));
  const pop = (a, b) => { const v = clamp((t - a) / (b - a)); return 1 - Math.pow(1 - v, 3) * Math.cos(v * Math.PI * 3); };
  const driveX = s => -.1 - 1.3 * smooth((s - .32) / .48) + 2.65 * smooth((s - .85) / 1.02) - .28 * smooth((s - 1.8) / .42);
  const driveZ = s => .14 * Math.sin(Math.PI * smooth((s - .8) / 1.5));
  const floor = .18;
  three.studio("white");

  const table = three.get("s6-table", () => {
    const o = three.roundedBox(12, .16, 6.4, .07, three.plastic("#eeefed", .7));
    o.position.set(0, .1, 0); return o;
  });
  table.position.set(0, .1, 0);

  const box = three.get("box", () => {
    const g = three.group();
    g.add(three.roundedBox(1.97, .5, 1.97, .16, three.aluminium("A")));
    const sole = three.roundedBox(1.82, .032, 1.82, .13, three.rubber("#161719"));
    sole.position.y = -.258; g.add(sole);
    const led = three.roundedBox(.055, .017, .012, .006, three.glow("#ffffff", 2));
    led.position.set(.63, -.158, .987); g.add(led);
    g.position.y = .25; return g;
  });
  const running = p(.65, 1.05) * (1 - p(1.95, 2.5));
  box.position.set(driveX(t), floor + .92 + .17 * (1 - p(.12, .65)) + .027 * Math.sin(t * 24) * running, driveZ(t));
  box.rotation.set(.025 * Math.sin(t * 16) * running, .12 + 1.38 * p(.1, .78) + .34 * Math.sin(Math.PI * p(1.1, 2.28)), -.065 * Math.sin(Math.PI * p(.94, 2.2)));
  box.scale.setScalar(1);

  const limbs = three.get("s6-flex-limbs", () => {
    const g = three.group(), gold = three.plastic("A"), black = three.rubber("#252629");
    for (const s of [-1, 1]) {
      const arm = three.group(); arm.position.set(s * 1.01, -.015, 0);
      const upper = three.capsule(.105, .36, gold);
      upper.position.set(s * .18, .17, 0); upper.rotation.z = -s * .82; arm.add(upper);
      const elbow = three.sphere(.12, gold); elbow.position.set(s * .35, .34, 0); arm.add(elbow);
      const fore = three.capsule(.105, .29, gold);
      fore.position.set(s * .30, .54, 0); fore.rotation.z = s * .27; arm.add(fore);
      const fist = three.sphere(.17, gold); fist.position.set(s * .24, .76, .015); arm.add(fist);
      g.add(arm);
    }
    for (const s of [-1, 1]) {
      const leg = three.group(); leg.position.set(s * .55, -.25, 0);
      const shin = three.capsule(.115, .43, gold); shin.position.y = -.30; leg.add(shin);
      const foot = three.roundedBox(.38, .15, .5, .07, black); foot.position.set(0, -.69, .09); leg.add(foot);
      g.add(leg);
    }
    return g;
  });
  limbs.position.copy(box.position); limbs.rotation.copy(box.rotation);
  limbs.children.forEach((o, i) => {
    const retract = i < 2 ? p(.08, .5) : p(.2, .64);
    o.scale.setScalar(Math.max(.001, 1 - retract)); o.visible = retract < .999;
  });

  const wheels = three.get("s6-wheel-build", () => {
    const g = three.group(), tire = three.rubber("#222428"), tread = three.rubber("#303237");
    const rim = three.aluminium("#dddcd4"), gold = three.plastic("A"), dark = three.aluminium("#555a60");
    for (const z of [-.69, .69]) for (const s of [-1, 1]) {
      const w = three.group(); w.position.set(s * 1.12, -.46, z);
      const rubber = three.cylinder(.43, .43, .28, tire); rubber.rotation.z = Math.PI / 2; w.add(rubber);
      for (let j = 0; j < 16; j++) {
        const a = j * Math.PI / 8, b = three.roundedBox(.295, .058, .12, .015, tread);
        b.position.set(0, Math.cos(a) * .421, Math.sin(a) * .421); b.rotation.x = a; b.castShadow = false; w.add(b);
      }
      const disc = three.cylinder(.263, .263, .032, rim);
      disc.rotation.z = Math.PI / 2; disc.position.x = s * .155; w.add(disc);
      const hub = three.cylinder(.155, .155, .044, gold);
      hub.rotation.z = Math.PI / 2; hub.position.x = s * .182; w.add(hub);
      for (let j = 0; j < 6; j++) {
        const a = j * Math.PI / 3, bolt = three.sphere(.023, dark);
        bolt.position.set(s * .181, .202 * Math.cos(a), .202 * Math.sin(a)); bolt.castShadow = false; w.add(bolt);
      }
      g.add(w);
    }
    const chassis = three.group();
    const pan = three.roundedBox(1.58, .12, 1.52, .06, gold); pan.position.y = -.31; chassis.add(pan);
    for (const z of [-.69, .69]) {
      const axle = three.cylinder(.075, .075, 2.24, dark);
      axle.rotation.z = Math.PI / 2; axle.position.set(0, -.46, z); chassis.add(axle);
    }
    g.add(chassis); return g;
  });
  wheels.position.copy(box.position); wheels.rotation.copy(box.rotation);
  wheels.children.forEach((o, i) => {
    const v = pop(.19 + Math.min(i, 3) * .045, .64 + Math.min(i, 3) * .045);
    o.scale.setScalar(Math.max(.001, v)); o.visible = v > .001;
    if (i < 4) o.rotation.x = (driveX(t) + .1) / .43;
  });

  const tracks = three.get("s6-tracks", T => {
    const vertices = [];
    for (let i = 0; i < 40; i++) for (const side of [-1, 1]) {
      const u = i / 40, v = (i + .88) / 40, x = -2.08 + u * 3.85, xx = -2.08 + v * 3.85;
      const z = side * 1.12 + .14 * Math.sin(u * Math.PI), zz = side * 1.12 + .14 * Math.sin(v * Math.PI), y = floor + .003;
      vertices.push(x,y,z-.095, xx,y,zz-.095, x,y,z+.095, x,y,z+.095, xx,y,zz-.095, xx,y,zz+.095);
    }
    const geometry = new T.BufferGeometry(); geometry.setAttribute("position", new T.Float32BufferAttribute(vertices, 3));
    const material = new T.MeshBasicMaterial({ color: "#697b95", transparent: true, opacity: .17, depthWrite: false, side: T.DoubleSide });
    return new T.Mesh(geometry, material);
  });
  tracks.geometry.setDrawRange(0, Math.floor(p(.79, 2.12) * 40) * 12);

  const dust = three.get("s6-dust", () => {
    const g = three.group(), rng = lib.rng(606);
    for (let i = 0; i < 18; i++) {
      const cloud = three.group(), mat = three.plastic("#e8e5dc", 1);
      mat.transparent = true; mat.depthWrite = false;
      for (let j = 0; j < 3; j++) {
        const sphere = three.sphere(.11 + rng() * .10, mat);
        sphere.position.set((rng() - .5) * .32, rng() * .15, (rng() - .5) * .26); sphere.castShadow = false; cloud.add(sphere);
      }
      cloud.userData.material = mat; g.add(cloud);
    }
    return g;
  });
  dust.children.forEach((o, i) => {
    const birth = .86 + i * .078, age = t - birth, life = clamp(age / .87), side = i % 2 ? 1 : -1;
    o.visible = age > 0 && age < .87;
    o.position.set(driveX(birth) - .65 - Math.max(0, age) * .60, floor + .10 + Math.max(0, age) * .30, driveZ(birth) + side * (1.06 + Math.max(0, age) * .24));
    o.scale.setScalar(.45 + smooth(age / .20) * .65 + Math.max(0, age) * .65);
    o.userData.material.opacity = .64 * smooth(age / .13) * (1 - smooth((life - .38) / .62));
  });

  const upgrade = three.get("s6-monster-seed", () => {
    const g = three.group(), green = three.plastic("#719c59"), metal = three.aluminium("#62686c");
    for (const s of [-1, 1]) {
      const post = three.capsule(.045, .48, green); post.position.set(s * .65, .29, -.65); g.add(post);
      const pipe = three.cylinder(.055, .055, .58, metal); pipe.position.set(s * .87, .12, -.81); g.add(pipe);
      const mouth = three.cylinder(.039, .039, .008, three.rubber("#181b1c")); mouth.position.set(s * .87, .414, -.81); g.add(mouth);
    }
    const bar = three.capsule(.045, 1.30, green); bar.rotation.z = Math.PI / 2; bar.position.set(0, .55, -.65); g.add(bar); return g;
  });
  upgrade.position.copy(box.position); upgrade.rotation.copy(box.rotation);
  upgrade.translateY(.25); upgrade.scale.set(1, Math.max(.001, pop(2.15, 2.55)), 1); upgrade.visible = t > 2.15;

  const cam = three.camera, low = p(0, .75);
  cam.position.set(3.6 + .25 * (1 - low), 2.55 - .84 * low, 6.4 + .8 * low);
  cam.fov = 38 + 4 * low; cam.lookAt(driveX(t) * .28, floor + .62, .05); cam.updateProjectionMatrix();
}
 return shot; })();

__AD_MODULES__["S7"] = (function(){ function shot(c) {
  const { three, lib, tl } = c;
  const t = Math.max(0, tl), P = Math.PI;
  const s = (a, b) => lib.span(t, a, b);
  const pop = (a, b) => { const v = s(a, b); return v + Math.sin(v * P) * 0.09; };
  const integral = (a, b) => { const q = Math.max(0, Math.min(1, (t - a) / (b - a))); return (b - a) * (q*q*q - q*q*q*q/2) + Math.max(0, t - b); };
  const build = s(0.08, 1.30), morph = s(5.42, 6.18);
  const drive = (0.22 + 0.78 * s(1.70, 2.60)) * (1 - s(4.50, 5.50));
  const distance = 1.5*t + 6*integral(1.70, 2.60) - 7.5*integral(4.50, 5.50);
  const bx = Math.sin(t*0.95)*0.16*drive;
  const by = (0.57 + 0.50*build + Math.sin(t*19)*0.022*drive)*(1-morph) + 0.99*morph;
  const yaw = (-0.20*(1-s(0,0.62)) + Math.sin(t*1.35)*0.10*drive - 0.13*s(3.50,4.50))*(1-morph);
  three.studio("white");

  const box = three.get("box", T => {
    const g = three.group(), metal = three.aluminium("#F0B64A");
    g.add(three.roundedBox(1.97, 0.5, 1.97, 0.16, metal));
    const rr = (p,h,r) => { p.moveTo(-h+r,-h); p.lineTo(h-r,-h); p.quadraticCurveTo(h,-h,h,-h+r); p.lineTo(h,h-r); p.quadraticCurveTo(h,h,h-r,h); p.lineTo(-h+r,h); p.quadraticCurveTo(-h,h,-h,h-r); p.lineTo(-h,-h+r); p.quadraticCurveTo(-h,-h,-h+r,-h); p.closePath(); };
    const outline = new T.Shape(), hole = new T.Path();
    rr(outline,0.91,0.14); rr(hole,0.81,0.10); outline.holes.push(hole);
    const sole = new T.Mesh(new T.ExtrudeGeometry(outline,{depth:0.026,bevelEnabled:false,curveSegments:6}),three.rubber("#17191a"));
    sole.rotation.x=P/2; sole.position.y=-0.25; sole.castShadow=true; g.add(sole);
    const led=three.sphere(0.013,three.glow("#ffffff",2.2));
    led.position.set(0.65,-0.145,0.986); led.scale.z=0.3; g.add(led);
    g.position.y=0.25; return g;
  });
  box.position.set(bx,by,0); box.rotation.set(Math.sin(t*15)*0.012*drive,yaw,Math.sin(t*9)*0.024*drive); box.scale.setScalar(1);

  const truck = three.get("S7-monster-hardware", T => {
    const g=three.group(), rubber=three.rubber("#202326"), tread=three.rubber("#111416");
    const metal=three.aluminium("#b9c0c4"), dark=three.plastic("#353e42",0.6), green=three.plastic("#64af49",0.34);
    const wheels=[], stacks=[], flames=[], axles=[];
    function beam(a,b,r,mat,parent) {
      const v=new T.Vector3(b[0]-a[0],b[1]-a[1],b[2]-a[2]), m=three.cylinder(r,r,v.length(),mat);
      m.position.set((a[0]+b[0])/2,(a[1]+b[1])/2,(a[2]+b[2])/2);
      m.quaternion.setFromUnitVectors(new T.Vector3(0,1,0),v.normalize()); parent.add(m); return m;
    }
    for(let k=0;k<4;k++){
      const side=k%2 ? 1:-1, front=k<2, w=three.group(), rotor=three.group(); w.add(rotor);
      const tire=three.cylinder(0.565,0.565,0.39,rubber); tire.rotation.z=P/2; rotor.add(tire);
      for(const sign of [-1,1]){
        const wall=new T.Mesh(new T.TorusGeometry(0.425,0.125,8,24),rubber);
        wall.rotation.y=P/2; wall.position.x=sign*0.17; wall.castShadow=true; rotor.add(wall);
      }
      for(let j=0;j<16;j++){
        const a=j*P/8, lug=three.roundedBox(0.45,0.085,0.18,0.025,tread);
        lug.position.set(0,Math.cos(a)*0.582,Math.sin(a)*0.582); lug.rotation.x=a; rotor.add(lug);
      }
      const hub=three.cylinder(0.252,0.252,0.435,metal); hub.rotation.z=P/2; rotor.add(hub);
      const cap=three.cylinder(0.13,0.13,0.453,three.plastic("#F0B64A",0.32)); cap.rotation.z=P/2; rotor.add(cap);
      for(let j=0;j<6;j++){
        const bolt=three.sphere(0.027,dark), a=j*P/3;
        bolt.position.set(side*0.229,Math.cos(a)*0.188,Math.sin(a)*0.188); rotor.add(bolt);
      }
      w.userData={side,front,rotor}; wheels.push(w); g.add(w);
    }
    for(const z of [-0.76,0.76]) axles.push(beam([-1.1,-0.43,z],[1.1,-0.43,z],0.055,dark,g));
    for(const side of [-1,1]){
      const stack=three.group(); stack.position.set(side*0.73,0.12,-0.74);
      beam([0,0,0],[0,1.03,0],0.07,metal,stack);
      const collar=three.cylinder(0.10,0.10,0.12,metal); collar.position.y=0.13; stack.add(collar);
      const lip=three.cylinder(0.092,0.078,0.12,metal); lip.position.y=1.04; stack.add(lip);
      const mouth=three.cylinder(0.068,0.068,0.006,rubber); mouth.position.y=1.102; stack.add(mouth);
      const fire=three.group(); fire.position.y=1.105;
      for(let j=0;j<3;j++){
        const f=new T.Mesh(new T.ConeGeometry(j===0?0.105:0.057,j===0?0.54:0.35,7),three.glow(j===0?"#f47824":"#fff0a3",j===0?1.4:2.1));
        f.position.set((j-1)*0.038,j===0?0.25:0.16,0.018*j); f.rotation.z=(j-1)*0.13; fire.add(f);
      }
      stack.add(fire); stacks.push(stack); flames.push(fire); g.add(stack);
    }
    const cage=three.group(); cage.position.y=0.25;
    for(const side of [-1,1]){
      beam([side*0.79,0,-0.46],[side*0.79,0.85,-0.46],0.057,green,cage);
      beam([side*0.79,0.85,-0.46],[side*0.79,0,0.66],0.052,green,cage);
      const joint=three.sphere(0.058,green); joint.position.set(side*0.79,0.85,-0.46); cage.add(joint);
    }
    beam([-0.79,0.85,-0.46],[0.79,0.85,-0.46],0.057,green,cage); g.add(cage);
    g.userData={wheels,stacks,flames,cage,axles}; return g;
  });
  truck.position.copy(box.position); truck.rotation.copy(box.rotation); truck.scale.setScalar(1);
  const hw=truck.userData, radius=0.30+0.30*build;
  hw.wheels.forEach((w,i)=>{
    w.position.set(w.userData.side*(1.04+0.12*build)*(1-0.27*morph),radius-by+0.40*morph,w.userData.front?0.77:-0.77);
    w.scale.setScalar(radius/0.60*(1-morph)); w.rotation.y=w.userData.front?-0.10*Math.sin(t*1.35)*drive:0;
    w.userData.rotor.rotation.x=-distance/0.60;
  });
  hw.axles.forEach(a=>{ a.position.y=radius-by; a.scale.setScalar(1-morph); });
  hw.stacks.forEach((a,i)=>a.scale.setScalar(pop(0.43+i*0.20,0.85+i*0.20)*(1-s(5.24,5.77))));
  hw.cage.scale.setScalar(pop(1.13,1.58)*(1-s(5.30,5.83)));
  hw.flames.forEach((f,i)=>{ const v=s(1.72,2.08)*(1-s(4.67,5.05)); f.scale.set(0.8+0.2*Math.sin(t*31+i),v*(0.76+0.28*Math.sin(t*37+i*2)),0.85); f.rotation.z=Math.sin(t*23+i)*0.15; });

  const tracks=three.get("S7-tire-tracks",T=>{
    const g=three.group(), mat=three.plastic("#a7a49a",1); mat.transparent=true; mat.opacity=0.27;
    for(let i=0;i<80;i++){ const m=three.roundedBox(0.44,0.007,0.115,0.025,mat); m.receiveShadow=true; g.add(m); } return g;
  });
  tracks.position.set(bx,0,0); tracks.rotation.y=yaw;
  tracks.children.forEach((m,i)=>{ const q=((i>>1)*0.43+distance)%17.2; m.position.set((i%2?1:-1)*1.16+0.10*Math.sin(q*0.42),0.009,-1.05-q); m.rotation.y=(i%2?1:-1)*0.18; m.scale.setScalar(Math.min(1,q*3+0.15)*(1-s(5.35,6.20))); });

  const dust=three.get("S7-dust",T=>{
    const g=three.group(), rng=lib.rng(707);
    for(let i=0;i<22;i++){
      const puff=three.group(), mat=three.plastic(i%3?"#e5e2d9":"#d8d6ce",1); mat.transparent=true; mat.depthWrite=false;
      for(let j=0;j<3;j++){ const m=three.sphere(0.13+rng()*0.12,mat); m.position.set((rng()-0.5)*0.30,(rng()-0.5)*0.17,(rng()-0.5)*0.27); puff.add(m); }
      puff.userData.mat=mat; g.add(puff);
    } return g;
  });
  dust.position.set(bx,0,0); dust.rotation.y=yaw;
  dust.children.forEach((p,i)=>{
    const age=((distance*0.16+i*0.173)%1), side=i%2?1:-1, fade=1-s(5.10,6.12);
    p.position.set(side*(1.15+age*0.92)+Math.sin(i*7)*age*0.32,0.13+age*0.59,-0.82-age*6.6);
    p.scale.setScalar((0.24+Math.sin(age*P)*1.65)*(0.45+0.55*build)); p.rotation.y=i+age;
    p.userData.mat.opacity=(1-age)*0.45*fade; p.visible=fade>0.001;
  });

  const robot=three.get("S7-robot-arrival",T=>{
    const g=three.group(), silver=three.aluminium("#bcc5c8"), joint=three.rubber("#424b50"), pink=three.plastic("#e890ae",0.65);
    const head=three.group(), neck=three.cylinder(0.072,0.09,0.34,silver); neck.position.y=0.41; head.add(neck);
    for(let side=-1;side<=1;side+=2) for(let j=0;j<5;j++){
      const lobe=three.sphere(0.148,pink); lobe.position.set(side*0.135,0.70+Math.sin(j*P/4)*0.055,(j-2)*0.108);
      lobe.scale.set(1.05,0.88,0.83); head.add(lobe);
    }
    g.add(head); const arms=[],legs=[];
    for(const side of [-1,1]){
      const arm=three.group(); arm.position.set(side*1.0,0,0);
      const shoulder=three.sphere(0.10,joint); arm.add(shoulder);
      const upper=three.capsule(0.066,0.30,silver); upper.position.set(side*0.19,-0.09,0); upper.rotation.z=side*1.12; arm.add(upper);
      const elbow=three.sphere(0.087,joint); elbow.position.set(side*0.36,-0.17,0); arm.add(elbow);
      const fore=three.capsule(0.057,0.29,silver); fore.position.set(side*0.40,0.02,0.05); fore.rotation.z=-side*0.20; arm.add(fore);
      const palm=three.sphere(0.09,silver); palm.position.set(side*0.44,0.21,0.08); arm.add(palm); g.add(arm); arms.push(arm);
      const leg=three.group(); leg.position.set(side*0.52,-0.25,0);
      const strut=three.capsule(0.078,0.42,silver); strut.position.y=-0.29; leg.add(strut);
      const knee=three.sphere(0.095,joint); knee.position.y=-0.30; leg.add(knee);
      const foot=three.roundedBox(0.32,0.13,0.46,0.055,joint); foot.position.set(0,-0.665,0.09); leg.add(foot); g.add(leg); legs.push(leg);
    }
    g.userData={head,arms,legs}; return g;
  });
  robot.position.copy(box.position); robot.rotation.copy(box.rotation); robot.visible=t>5.40;
  robot.userData.head.scale.setScalar(pop(5.62,6.18));
  robot.userData.arms.forEach((a,i)=>a.scale.setScalar(pop(5.70+i*0.08,6.10+i*0.08)));
  robot.userData.legs.forEach(a=>a.scale.setScalar(pop(5.50,6.06)));

  const turn=s(2.65,4.40), settle=s(5.18,6.20), cam=three.camera;
  cam.position.set(bx+3.65+0.35*turn-0.95*settle,1.28+1.25*turn+0.08*settle,5.55-0.25*turn+0.72*settle);
  cam.lookAt(bx,0.84+0.12*turn+0.09*settle,-0.12);
  cam.fov=35; cam.updateProjectionMatrix();
}
 return shot; })();

__AD_MODULES__["S8"] = (function(){ function shot(c) {
  const { three: th, tl: t, lib } = c, T = th.THREE;
  const s = (a, b) => lib.span(t, a, b), mix = (a, b, p) => a + (b - a) * p;
  const pop = (a, b) => { const q = s(a, b) - 1; return 1 + 2.4 * q * q * q + 1.4 * q * q; };
  const wide = s(1.30, 1.78) * (1 - s(3.72, 4.12)), walking = s(4.02, 4.42) * (1 - s(5.68, 5.98)), rocket = s(5.76, 6.10);
  th.studio("white");
  th.camera.fov = 31; th.camera.position.set(mix(.32, 0, rocket), 1.86 + .24 * wide, 6.15 + 2.35 * wide);
  th.camera.lookAt(.10 * walking, 1.17 + .12 * wide, 0); th.camera.updateProjectionMatrix();
  const add = (g, o, x = 0, y = 0, z = 0) => { o.position.set(x, y, z); g.add(o); return o; };
  const rod = (g, r, m) => { const o = add(g, th.cylinder(r, r, 1, m)); o.userData.v = new T.Vector3(); o.userData.up = new T.Vector3(0, 1, 0); return o; };
  const link = (o, a, b) => { const v = o.userData.v; v.set(b[0]-a[0], b[1]-a[1], b[2]-a[2]); const n = v.length(); o.position.set((a[0]+b[0])/2, (a[1]+b[1])/2, (a[2]+b[2])/2); o.scale.set(1, Math.max(.001, n), 1); o.quaternion.setFromUnitVectors(o.userData.up, v.normalize()); };
  const finish = g => { const m = new Set(); g.traverse(o => { if (o.material) m.add(o.material); }); g.userData.materials = [...m]; return g; };
  const fade = (g, a) => { g.visible = a > .001; for (const m of g.userData.materials) { m.opacity = a; m.transparent = a < .999; } };
  const attach = g => { g.position.copy(box.position); g.rotation.copy(box.rotation); };
  const box = th.get("box", () => {
    const g = th.group(), metal = th.aluminium("A"), rubber = th.rubber("#191b1d");
    add(g, th.roundedBox(1.97, .5, 1.97, .16, metal));
    add(g, th.roundedBox(1.85, .035, 1.85, .017, rubber), 0, -.254, 0);
    const bezel = add(g, th.cylinder(.026, .026, .012, rubber), .66, -.145, .984); bezel.rotation.x = Math.PI / 2;
    add(g, th.sphere(.017, th.glow("#ffffff", 2)), .66, -.145, .997);
    return g;
  });
  box.position.set(mix(-.14, 0, s(0, .32)) + .36 * walking * s(4.15, 5.65), mix(.66, 1.08, s(.08, .52)) + .027 * walking * Math.cos((t-4.1)*13) + .10 * rocket, 0);
  box.rotation.set(0, mix(-.22, .09, s(0, .55)) + .19 * walking - .09 * rocket, .013 * walking * Math.sin((t-4.1)*6.5)); box.scale.setScalar(1);
  if (t < .16) {
    const truck = th.get("s8-truck-handoff", () => {
      const g = th.group(), black = th.rubber("#222326"), silver = th.aluminium(), green = th.plastic("#73ad64"), amber = th.glow("#ff9b36", 1.5);
      g.userData.wheels = [];
      for (const x of [-1.07, 1.07]) for (const z of [-.68, .68]) {
        const w = add(g, th.group(), x, -.23, z); add(w, th.cylinder(.43, .43, .31, black)).rotation.z = Math.PI/2;
        add(w, th.cylinder(.235, .235, .327, silver)).rotation.z = Math.PI/2; g.userData.wheels.push(w);
      }
      for (const x of [-.70, .70]) {
        add(g, th.cylinder(.09, .09, .75, silver), x, .57, -.70);
        add(g, th.cylinder(0, .085, .37, amber), x, 1.10, -.70);
        link(rod(g, .064, green), [x,.27,.45], [x,.85,-.4]);
      }
      link(rod(g, .064, green), [-.7,.85,-.4], [.7,.85,-.4]);
      const dust = th.plastic("#e5e3df"); for (let i=0;i<7;i++) add(g, th.sphere(.15+i*.025,dust), -.4-i*.22,-.40+i*.035,-1.1-i*.24);
      return finish(g);
    });
    attach(truck); fade(truck, 1-s(.01,.12)); truck.scale.setScalar(mix(1,.88,s(.01,.12)));
    truck.userData.wheels.forEach(w => { w.rotation.x = -t*19; });
  }
  const robot = th.get("s8-robot", () => {
    const g = th.group(), metal = th.aluminium(), blue = th.plastic("B"), gold = th.plastic("A"), dark = th.rubber("#262a31"), pink = th.plastic("#ef8ea9", .48), pale = th.plastic("#f5a5ba", .43);
    const head = add(g, th.group(), 0, .31, -.02);
    add(head, th.cylinder(.105,.14,.27,metal),0,.12,0); add(head,th.cylinder(.19,.19,.055,blue),0,.025,0);
    for (const sign of [-1,1]) {
      add(head, th.sphere(.28,pink),sign*.19,.48,0).scale.set(1,1.05,1.34);
      for (let j=0;j<7;j++) {
        const l = add(head, th.capsule(.070,.19,pale),sign*(.16+.08*Math.sin(j*1.2)),.69-.075*Math.cos(j*.9),(j-3)*.092);
        l.rotation.set(Math.PI/2,sign*.32*Math.sin(j),sign*.25);
      }
      for (let j=0;j<3;j++) add(head,th.sphere(.095,pink),sign*.38,.43+.035*Math.sin(j), (j-1)*.19).scale.set(.75,1.1,1.2);
      add(head, th.sphere(.065,dark),sign*.15,.36,.346).scale.set(1,1,.42);
      add(head, th.sphere(.018,th.glow("#fff8ef",.8)),sign*.15-.012,.381,.374);
    }
    const arms = add(g,th.group()), legs = add(g,th.group()); g.userData.head=head; g.userData.arms=arms; g.userData.legs=legs;
    arms.userData.items=[]; legs.userData.items=[];
    for (const sign of [-1,1]) {
      const shoulder=add(arms,th.sphere(.15,blue)), elbow=add(arms,th.sphere(.105,dark)), hand=add(arms,th.group());
      add(hand,th.roundedBox(.19,.20,.17,.06,metal));
      for (const k of [-1,1]) link(rod(hand,.035,gold),[k*.075,-.055,0],[k*.12,-.20,.05]);
      arms.userData.items.push({sign,shoulder,elbow,upper:rod(arms,.076,metal),lower:rod(arms,.060,metal),hand});
      const hip=add(legs,th.sphere(.125,dark)), knee=add(legs,th.sphere(.115,blue)), foot=add(legs,th.group());
      add(foot,th.roundedBox(.43,.16,.62,.065,metal)); add(foot,th.roundedBox(.44,.035,.63,.017,dark),0,-.077,0);
      legs.userData.items.push({sign,hip,knee,upper:rod(legs,.088,gold),lower:rod(legs,.073,metal),foot});
    }
    finish(head); finish(arms); finish(legs); return g;
  });
  attach(robot); robot.scale.setScalar(1);
  const headOn = s(.03,.45)*(1-s(5.72,6.06)), armsOn = s(.06,.48)*(1-s(5.78,6.10)), legsOn = s(.08,.52)*(1-s(5.82,6.10));
  fade(robot.userData.head,headOn); robot.userData.head.scale.setScalar(Math.max(.001,pop(.03,.45)*(1-s(5.72,6.06))));
  robot.userData.head.rotation.set(.035*Math.sin(t*2.4),.06*Math.sin(t*1.7),-.045*Math.sin(t*2));
  fade(robot.userData.arms,armsOn); robot.userData.arms.scale.setScalar(Math.max(.001,pop(.06,.48)*(1-s(5.78,6.10))));
  for (const a of robot.userData.arms.userData.items) {
    const z=.22*walking*Math.sin((t-4.1)*6.5+a.sign), p=[a.sign*.98,.025,.02], q=[a.sign*(1.27+.10*wide),-.24+.12*wide,.16-z], r=[a.sign*(1.40+.20*wide),-.48+.26*wide,.26-z*1.5];
    a.shoulder.position.set(...p); a.elbow.position.set(...q); link(a.upper,p,q); link(a.lower,q,r); a.hand.position.set(...r); a.hand.rotation.set(.15,0,a.sign*.17);
  }
  fade(robot.userData.legs,legsOn); robot.userData.legs.scale.setScalar(Math.max(.001,pop(.08,.52)*(1-s(5.82,6.10))));
  for (const a of robot.userData.legs.userData.items) {
    const phase=(t-4.1)*6.5+(a.sign<0?Math.PI:0), stride=.31*walking*Math.sin(phase), lift=.14*walking*Math.max(0,Math.cos(phase));
    const p=[a.sign*.53,-.25,0], q=[a.sign*.55,-.59,.13+stride*.5], r=[a.sign*.56,.19+lift-box.position.y,stride];
    a.hip.position.set(...p); a.knee.position.set(...q); link(a.upper,p,q); link(a.lower,q,r); a.foot.position.set(a.sign*.56,.09+lift-box.position.y,stride+.12); a.foot.rotation.x=-.12*walking*Math.max(0,Math.cos(phase));
  }
  if (t >= 1.30 && t < 4.02) {
    const tentacles = th.get("s8-tentacle-tools", () => {
      const g=th.group(), metal=th.aluminium(), blue=th.plastic("B"), gold=th.plastic("A"), dark=th.rubber("#252932"), paper=th.plastic("#fffaf1"), pink=th.plastic("#ef8ea9");
      g.userData.arms=[];
      for (let i=0;i<6;i++) {
        const sign=i<3?-1:1, lane=i%3, a=add(g,th.group(),sign*.91,.04,-.39), rods=[], joints=[];
        for(let j=0;j<8;j++) { rods.push(rod(a,.059-j*.002,lane===1?blue:gold)); joints.push(add(a,th.sphere(.065-j*.002,metal))); }
        const tool=add(a,th.group()); add(tool,th.sphere(.075,metal));
        if(i===0) {
          add(tool,th.roundedBox(.60,.36,.25,.055,dark),0,.19,0); add(tool,th.roundedBox(.23,.09,.17,.025,dark),-.06,.41,0);
          add(tool,th.cylinder(.145,.145,.22,metal),.07,.19,.20).rotation.x=Math.PI/2;
          add(tool,th.cylinder(.115,.115,.026,dark),.07,.19,.32).rotation.x=Math.PI/2;
          add(tool,th.sphere(.090,blue),.07,.19,.339).scale.set(1,1,.16); add(tool,th.sphere(.026,paper),-.20,.31,.132);
        } else if(i===1) {
          const kb=add(tool,th.group(),0,.08,.04); kb.rotation.x=.69; add(kb,th.roundedBox(.90,.07,.43,.03,metal));
          for(let row=0;row<4;row++) for(let col=0;col<10;col++) add(kb,th.roundedBox(.067,.022,.064,.008,row===3&&col>2&&col<7?blue:paper),-.37+col*.082,.045,-.145+row*.089);
        } else if(i===3) {
          const pts=[[-.28,.12,0],[0,.32,.02],[.30,.16,0],[.07,-.09,.15],[.02,.22,-.29]];
          for(let j=1;j<5;j++) link(rod(tool,.025,metal),pts[j],pts[j===1?0:1]);
          pts.forEach((p,j)=>add(tool,th.sphere(j===1?.15:.105,j%3===0?pink:j%3===1?blue:gold),...p));
        } else if(i===4) {
          add(tool,th.roundedBox(.65,.77,.045,.027,paper),0,.28,0);
          link(rod(tool,.008,blue),[-.24,.04,.028],[.25,.04,.028]); link(rod(tool,.008,blue),[-.24,.04,.028],[-.24,.55,.028]);
          for(let j=0;j<3;j++) add(tool,th.roundedBox(.105,.15+j*.115,.018,.008,j===1?blue:gold),-.14+j*.15,.12+j*.0575,.033);
        } else for(const k of [-1,1]) { link(rod(tool,.032,metal),[k*.045,0,0],[k*.13,.16,0]); link(rod(tool,.028,metal),[k*.13,.16,0],[k*.075,.23,.035]); }
        finish(a); g.userData.arms.push({a,rods,joints,tool,sign,lane,i});
      }
      return g;
    });
    attach(tentacles); tentacles.scale.setScalar(1);
    for(const a of tentacles.userData.arms) {
      const onset=1.30+a.lane*.045, growth=pop(onset,onset+.38)*(1-s(3.78,3.92)), alpha=s(onset,onset+.32)*(1-s(3.78,3.92));
      fade(a.a,alpha); a.a.scale.setScalar(Math.max(.001,growth));
      const ex=a.sign*([1.43,1.95,1.35][a.lane]), ey=[1.20,.12,-.40][a.lane]+.055*Math.sin(t*2+a.i), ez=.63;
      const point=u=>[(2*(1-u)*u*a.sign*1.18+u*u*ex),2*(1-u)*u*(ey*.5+.49)+u*u*ey,2*(1-u)*u*.07+u*u*ez];
      for(let j=0;j<8;j++) { const p=point(j/8),q=point((j+1)/8); link(a.rods[j],p,q); a.joints[j].position.set(...p); }
      a.tool.position.set(ex,ey,ez); a.tool.rotation.set(0,-a.sign*.08,.045*Math.sin(t*1.8+a.i));
    }
  }
  if(t>5.76) {
    const pack=th.get("s8-rocket-handoff",()=>{
      const g=th.group(), red=th.plastic("#da514b"), metal=th.aluminium(), dark=th.rubber("#343842"), blue=th.glow("B",2), ice=th.glow("#a5e9ff",3); g.userData.flames=[];
      add(g,th.roundedBox(1.62,.55,.25,.08,dark),0,.08,-.88);
      for(const sign of [-1,1]) {
        const tank=add(g,th.group(),sign*1.025,.04,-.62);
        add(tank,th.cylinder(.205,.205,.78,metal),0,.12,0); add(tank,th.sphere(.205,red),0,.51,0).scale.y=.75;
        add(tank,th.cylinder(.219,.219,.12,red),0,.30,0); add(tank,th.cylinder(.19,.14,.20,dark),0,-.36,0);
        const flame=add(tank,th.group(),0,-.47,0); add(flame,th.cylinder(.14,0,.66,blue),0,-.33,0); add(flame,th.cylinder(.075,0,.43,ice),0,-.20,.015); g.userData.flames.push(flame);
      }
      return finish(g);
    });
    attach(pack); fade(pack,rocket); pack.scale.setScalar(Math.max(.001,pop(5.76,6.10)));
    pack.userData.flames.forEach((f,i)=>{ const p=s(5.94,6.10); f.visible=p>.001; f.scale.set(1,p*(1+.10*Math.sin(t*31+i*2)),1); });
  }
}
 return shot; })();

__AD_MODULES__["S9"] = (function(){ function shot(c) {
  const { three, lib } = c;
  const t = Math.max(0, Math.min(2.5, c.tl));
  const span = (a, b) => lib.span(t, a, b, lib.ease);
  three.studio("white");
  const box = three.get("box", T => {
    const g = three.group();
    g.add(three.roundedBox(1.97, 0.5, 1.97, 0.16, three.aluminium("A")));
    const rounded = (p, s, r) => {
      p.moveTo(-s + r, -s); p.lineTo(s - r, -s);
      p.quadraticCurveTo(s, -s, s, -s + r); p.lineTo(s, s - r);
      p.quadraticCurveTo(s, s, s - r, s); p.lineTo(-s + r, s);
      p.quadraticCurveTo(-s, s, -s, s - r); p.lineTo(-s, -s + r);
      p.quadraticCurveTo(-s, -s, -s + r, -s);
      return p;
    };
    const outline = rounded(new T.Shape(), 0.895, 0.14);
    outline.holes.push(rounded(new T.Path(), 0.825, 0.11));
    const ring = new T.Mesh(new T.ExtrudeGeometry(outline, {
      depth: 0.025, bevelEnabled: false, curveSegments: 6
    }), three.rubber("#17181a"));
    ring.rotation.x = -Math.PI / 2; ring.position.y = -0.265; ring.castShadow = true;
    g.add(ring);
    const light = three.sphere(0.014, three.glow("#ffffff", 1.8));
    light.position.set(0.69, -0.155, 0.978); light.scale.set(1, 0.65, 0.32);
    g.add(light); g.position.y = 0.25;
    return g;
  });
  const rocket = three.get("s9-upright-launch-carrier", T => {
    const g = three.group(), frame = three.group();
    const red = three.plastic("#cf403c", 0.34);
    const silver = three.aluminium("#a0a8af"), dark = three.rubber("#30363b");
    const add = (parent, mesh, x, y, z) => {
      mesh.position.set(x, y, z); parent.add(mesh); return mesh;
    };
    g.add(frame); g.userData.frame = frame; g.userData.pods = []; g.userData.engines = [];
    add(frame, three.roundedBox(2.28, 2.23, 0.16, 0.13, red), 0, 0, -0.39);
    for (const side of [-1, 1]) {
      add(frame, three.roundedBox(0.13, 2.17, 0.23, 0.04, silver), side * 1.065, 0, -0.18);
      add(frame, three.roundedBox(1.34, 0.19, 0.26, 0.045, silver), side * 1.63, -0.79, -0.22);
      add(frame, three.roundedBox(1.20, 0.15, 0.22, 0.04, dark), side * 1.59, 0.67, -0.28);
      for (const y of [-0.86, 0.86])
        add(frame, three.sphere(0.045, dark), side * 1.065, y, -0.045);
    }
    add(frame, three.roundedBox(2.20, 0.15, 0.24, 0.045, silver), 0, 1.08, -0.19);
    add(frame, three.roundedBox(0.76, 0.29, 0.34, 0.07, red), 0, 1.26, -0.24);
    add(frame, three.roundedBox(0.48, 0.075, 0.055, 0.018, silver), 0, 1.28, -0.045);
    add(frame, three.roundedBox(2.14, 0.27, 0.46, 0.075, silver), 0, -1.21, -0.08);
    add(frame, three.roundedBox(1.88, 0.095, 0.05, 0.02, red), 0, -1.19, 0.17);
    for (let i = 0; i < 4; i++) {
      const outer = i >= 2, side = i % 2 ? 1 : -1;
      const r = outer ? 0.35 : 0.30, h = outer ? 1.64 : 2.04;
      const pod = three.group(); pod.position.set(side * (outer ? 2.04 : 1.34), outer ? -0.09 : 0.18, -0.08);
      add(pod, three.cylinder(r, r, h, red), 0, 0, 0);
      add(pod, three.sphere(r, silver), 0, h / 2, 0);
      const base = add(pod, three.sphere(r, silver), 0, -h / 2, 0); base.scale.y = 0.65;
      for (const y of [-h * 0.40, 0, h * 0.40])
        add(pod, three.cylinder(r + (outer ? 0.05 : 0.035), r + (outer ? 0.05 : 0.035), 0.115, silver), 0, y, 0);
      add(pod, three.roundedBox(0.09, h * 0.66, 0.06, 0.025, dark), side * r * 0.45, 0, r - 0.005);
      add(pod, three.roundedBox(0.055, h * 0.51, 0.07, 0.02, silver), -side * r * 0.42, 0, r);
      g.add(pod); g.userData.pods.push(pod);
    }
    for (let i = 0; i < 3; i++) {
      const engine = three.group(); engine.position.set((i - 1) * 0.67, -1.39, 0.035);
      add(engine, three.cylinder(0.17, 0.18, 0.19, dark), 0, 0, 0);
      add(engine, three.cylinder(0.18, 0.285, 0.34, silver), 0, -0.15, 0);
      add(engine, three.cylinder(0.29, 0.29, 0.06, silver), 0, -0.31, 0);
      add(engine, three.cylinder(0.25, 0.25, 0.018, dark), 0, -0.345, 0);
      const flame = three.group(); flame.position.y = -0.355; engine.add(flame);
      const halo = three.glow("#4b7bd6", 1.6);
      halo.transparent = true; halo.opacity = 0.46; halo.depthWrite = false;
      const layers = [[0.235, 0.69, halo], [0.155, 0.59, three.glow("#55baff", 2)], [0.078, 0.38, three.glow("#e0f6ff", 2.5)]];
      for (const [r, h, mat] of layers) {
        const jet = add(flame, three.cylinder(r, 0.006, h, mat), 0, -h / 2, 0);
        jet.castShadow = false; jet.receiveShadow = false;
      }
      engine.userData.flame = flame; g.add(engine); g.userData.engines.push(engine);
    }
    return g;
  });
  const turn = span(0.06, 0.53), charge = span(2.04, 2.5);
  const shake = Math.sin(t * 58) * 0.0015 * charge;
  box.position.set(shake, lib.lerp(0.87, 2.50, turn) + 0.012 * charge, 0);
  box.rotation.set((Math.PI / 2 - 0.065) * turn, 0, shake * 0.32);
  box.scale.setScalar(1);
  rocket.position.copy(box.position); rocket.rotation.set(0, 0, shake * 0.32); rocket.scale.setScalar(1);
  rocket.userData.frame.scale.setScalar(Math.max(0.001, span(0.10, 0.50)));
  rocket.userData.pods.forEach((pod, i) => {
    const pop = span(0.12 + i * 0.035, 0.49 + i * 0.035);
    pod.scale.setScalar(Math.max(0.001, pop));
    pod.position.z = -0.08 - 0.40 * (1 - pop);
  });
  rocket.userData.engines.forEach((engine, i) => {
    engine.scale.setScalar(Math.max(0.001, span(0.26 + i * 0.025, 0.61 + i * 0.025)));
    const fire = span(0.57 + i * 0.035, 0.93 + i * 0.035);
    const flicker = 1 + 0.012 * Math.sin(t * 67 + i * 2.1) + 0.009 * Math.sin(t * 103 + i);
    engine.userData.flame.scale.set(fire, fire * (0.82 + 0.18 * charge) * flicker, fire);
  });
  if (t < 0.49) {
    const limbs = three.get("s9-walking-retraction", T => {
      const g = three.group(), metal = three.aluminium("#9da4ac"), rubber = three.rubber("#30363d");
      for (let i = 0; i < 4; i++) {
        const leg = i < 2, side = i % 2 ? 1 : -1, limb = three.group();
        limb.position.set(side * (leg ? 0.55 : 0.97), leg ? -0.23 : 0, 0.20);
        limb.add(three.sphere(0.08, rubber));
        const shaft = three.capsule(0.055, leg ? 0.34 : 0.25, metal); shaft.position.y = -0.22; limb.add(shaft);
        const tip = three.roundedBox(leg ? 0.24 : 0.13, 0.11, leg ? 0.34 : 0.15, 0.04, rubber);
        tip.position.y = leg ? -0.51 : -0.39; limb.add(tip); g.add(limb);
      }
      return g;
    });
    limbs.position.copy(box.position); limbs.rotation.set(0, 0, 0); limbs.scale.setScalar(1);
    limbs.children.forEach((limb, i) => {
      limb.scale.setScalar(Math.max(0.001, 1 - span(0.04, 0.49)));
      limb.rotation.set(Math.sin(t * 9 + i * Math.PI) * 0.12 * (1 - turn), 0, 0);
    });
  }
  three.camera.position.set(0, 2.005, 10.3);
  three.camera.fov = 22.35; three.camera.lookAt(0, 2.005, 0); three.camera.updateProjectionMatrix();
}
 return shot; })();

__AD_MODULES__["S10"] = (function(){ function shot(c) {
  const { three, lib } = c;
  const t = Math.max(0, Math.min(2.10, c.tl));
  const cut = t < .41 ? 0 : t < .83 ? 1 : t < 1.25 ? 2 : t < 1.67 ? 3 : 4;
  const starts = [0, .41, .83, 1.25, 1.67];
  const lengths = [.41, .42, .42, .42, .43];
  const p = Math.min(1, (t - starts[cut]) / lengths[cut]);
  three.studio("white");

  const box = three.get("box", T => {
    const g = three.group();
    const body = three.roundedBox(1.97, .5, 1.97, .16, three.aluminium("A"));
    body.position.y = .014;
    g.add(body);
    const sole = three.roundedBox(1.88, .032, 1.88, .145, three.rubber("#151515"));
    sole.position.y = -.233;
    g.add(sole);
    const light = three.sphere(.018, three.glow("#ffffff", 1.6));
    light.position.set(.64, -.135, .988);
    light.scale.set(1, .65, .35);
    g.add(light);
    return g;
  });

  const pack = three.get("s10-jetpack", T => {
    const g = three.group();
    const red = three.plastic("#bb3835", .34);
    const metal = three.aluminium("#969da7");
    const rubber = three.rubber("#282c33");
    const blue = three.glow("#327de9", 2.5);
    const core = three.glow("#c6edff", 3.4);
    const brace = three.roundedBox(1.9, .13, .22, .05, metal);
    brace.position.set(0, .08, -.88);
    g.add(brace);
    g.userData.flames = [];
    for (let i = 0; i < 2; i++) {
      const x = i ? .88 : -.88;
      const tank = three.capsule(.235, .91, red);
      tank.position.set(x, .19, -.77);
      g.add(tank);
      for (let j = 0; j < 2; j++) {
        const band = three.cylinder(.244, .244, .105, metal);
        band.position.set(x, j ? .48 : -.29, -.77);
        g.add(band);
      }
      const nozzle = three.cylinder(.16, .23, .25, rubber);
      nozzle.position.set(x, -.48, -.77);
      g.add(nozzle);
      const lip = three.cylinder(.236, .236, .048, metal);
      lip.position.set(x, -.595, -.77);
      g.add(lip);
      const flame = three.group();
      flame.position.set(x, -.62, -.77);
      const outer = three.cylinder(.155, .002, 1.12, blue);
      outer.position.y = -.56;
      const inner = three.cylinder(.082, .001, .82, core);
      inner.position.set(0, -.41, .025);
      outer.castShadow = inner.castShadow = false;
      flame.add(outer, inner);
      g.add(flame);
      g.userData.flames.push(flame);
    }
    const spill = new T.PointLight("#4b7bd6", 3, 4, 2);
    spill.position.set(0, -.9, -.4);
    g.add(spill);
    return g;
  });

  const clouds = three.get("s10-cloud-masses", T => {
    const g = three.group();
    const mat = three.plastic("#ffffff", 1);
    mat.transparent = true;
    g.userData.material = mat;
    const random = lib.rng(10731);
    for (let i = 0; i < 10; i++) {
      const cluster = three.group();
      for (let j = 0; j < 7; j++) {
        const radius = j ? .43 + random() * .3 : .82;
        const ball = three.sphere(radius, mat);
        const a = j * Math.PI / 3;
        ball.position.set(j ? Math.cos(a) * .66 : 0, j ? Math.sin(a) * .48 : 0, (random() - .5) * .6);
        ball.castShadow = false;
        ball.receiveShadow = false;
        cluster.add(ball);
      }
      g.add(cluster);
    }
    return g;
  });

  let x = 0, y = .25, rx = 0, ry = 0, rz = 0;
  const camera = three.camera;
  camera.fov = 32;
  if (cut === 0) {
    const lift = 2.45 * p * p;
    y += lift; ry = -.12; rz = -.025 * p;
    camera.position.set(2.25, 1.65 + lift * .62, 6.15);
    camera.lookAt(0, .56 + lift * .75, 0);
  } else if (cut === 1) {
    y = 8 + 1.8 * p; rx = .08; ry = .3; rz = -.22;
    camera.position.set(3.25, y + .85, 5.55);
    camera.lookAt(0, y - .05, 0);
  } else if (cut === 2) {
    x = -.45 + .65 * p; y = 17 + 1.8 * p; ry = -.3; rz = .12;
    camera.position.set(-.9, y + .9, 5.1);
    camera.lookAt(.1, y + .24, 0);
  } else if (cut === 3) {
    x = -.35 + .7 * p; y = 25 + 3 * p; rx = -.15; ry = -.65; rz = .24;
    camera.position.set(3.45, y + 4.1, 5.25);
    camera.lookAt(0, y - .18, 0);
  } else {
    camera.fov = 34;
    camera.position.set(0, 5.7, 10.5);
    camera.lookAt(0, .25, 0);
  }
  camera.updateProjectionMatrix();
  box.position.set(x, y, 0);
  box.rotation.set(rx, ry, rz);
  box.scale.setScalar(1);
  pack.position.copy(box.position);
  pack.rotation.copy(box.rotation);
  pack.scale.setScalar(1);
  pack.visible = cut < 4;
  pack.userData.flames.forEach((f, i) => {
    f.scale.set(1 + .045 * Math.sin(t * 93 + i), .89 + .17 * Math.sin(t * 81 + i * 2) + .28 * (cut === 0 ? p : 1), 1);
  });

  const layout = [[-2.4,1.7,-.8],[2.3,.8,.6],[-1.1,-1.5,-3],[1.3,2.8,-2],[-3,-.5,1.1],[3.2,2.6,-1],[-.3,3.7,-3.8],[.6,-3,.9],[-2.4,3.8,1.5],[2.4,-2.6,-2]];
  clouds.position.set(0, 0, 0);
  clouds.rotation.set(0, 0, 0);
  clouds.scale.setScalar(1);
  clouds.visible = t < 2.10;
  clouds.userData.material.opacity = 1 - lib.span(t, 2.08, 2.10, lib.ease);
  clouds.children.forEach((g, i) => {
    const a = layout[i];
    let s = .88 + (i % 3) * .13;
    if (cut === 0) g.position.set((i % 2 ? 1 : -1) * (3.2 + i % 3 * .5), 2.3 + Math.floor(i / 2) * 1.2 - p * 2, -1 - i % 3);
    else if (cut === 1) g.position.set(a[0], y + a[1] + 2.4 - 5 * p, a[2]);
    else if (cut === 2) { g.position.set(-2.1 + i % 4 * 1.4 + .45 * p, y + (Math.floor(i / 4) - 1) * 1.65 + .65 - 1.3 * p, i % 2 ? 2.2 : 1.4); s = 1.12; }
    else if (cut === 3) { g.position.set(a[0] * 1.2, y + a[1] - 1.7 - 4 * p, a[2]); s *= 1.1; }
    else { const row = Math.floor(i / 4) - 1; g.position.set((i % 4 - 1.5) * 2.05 + .18 * p, 3.4 + row * 1.73 - .28 * p, 6 - row * .9); s = 1.3; }
    g.scale.setScalar(s);
    g.rotation.set(.08 * (i % 3), .21 * i, .12 * Math.sin(i * 2));
  });
}
 return shot; })();

__AD_MODULES__["S11"] = (function(){ function shot(c) {
  const { three, lib, light } = c;
  three.studio("white");

  const box = three.get("box", T => {
    const hero = three.group();

    const metal = three.aluminium("A");
    metal.roughness = 0.34;
    const body = three.roundedBox(1.97, 0.5, 1.97, 0.16, metal);
    hero.add(body);

    function roundedPath(path, width, depth, radius) {
      const x = width / 2;
      const z = depth / 2;
      path.moveTo(-x + radius, -z);
      path.lineTo(x - radius, -z);
      path.quadraticCurveTo(x, -z, x, -z + radius);
      path.lineTo(x, z - radius);
      path.quadraticCurveTo(x, z, x - radius, z);
      path.lineTo(-x + radius, z);
      path.quadraticCurveTo(-x, z, -x, z - radius);
      path.lineTo(-x, -z + radius);
      path.quadraticCurveTo(-x, -z, -x + radius, -z);
      path.closePath();
      return path;
    }

    const footprint = roundedPath(new T.Shape(), 1.86, 1.86, 0.14);
    footprint.holes.push(roundedPath(new T.Path(), 1.66, 1.66, 0.08));
    const ringGeometry = new T.ExtrudeGeometry(footprint, {
      depth: 0.028,
      steps: 1,
      bevelEnabled: false,
      curveSegments: 6
    });
    const ring = new T.Mesh(ringGeometry, three.rubber("#171819"));
    ring.rotation.x = -Math.PI / 2;
    ring.position.y = -0.25;
    ring.castShadow = true;
    ring.receiveShadow = true;
    hero.add(ring);

    const power = three.sphere(0.011, three.glow("#ffffff", 1.2));
    power.position.set(0.64, -0.105, 0.985);
    hero.add(power);

    return hero;
  });

  box.position.set(0, 0.25, 0);
  box.rotation.set(0, 0, 0);
  box.scale.setScalar(1);
  box.visible = true;

  // Hold the next shot's measured product footprint without a camera move.
  const camera = three.camera;
  const elevation = 42 * Math.PI / 180;
  const s = Math.sin(elevation);
  const k = Math.cos(elevation);
  const fov = 35;
  const focal = 540 / Math.tan(fov * Math.PI / 360);
  const radius = 0.16;
  const coreX = 0.985 - radius;
  const coreY = 0.25 - radius;
  const coreZ = 0.985 - radius;
  const slope = 186.5 / focal;
  const distance =
    coreY * s + coreZ * k +
    (coreX + radius * Math.sqrt(1 + slope * slope)) / slope;

  function tangentSlope(height, depth) {
    return (
      height * depth +
      radius * Math.sqrt(depth * depth + height * height - radius * radius)
    ) / (depth * depth - radius * radius);
  }

  const verticalCore = coreY * k + coreZ * s;
  const upperDepth = distance - (coreY * s - coreZ * k);
  const lowerDepth = distance - (-coreY * s + coreZ * k);
  const upperPixels = focal * tangentSlope(verticalCore, upperDepth);
  const bodyLowerPixels = focal * tangentSlope(verticalCore, lowerDepth);
  const ringLowerPixels =
    focal * (0.25 * k + 0.93 * s) /
    (distance + 0.25 * s - 0.93 * k);
  const lowerPixels = Math.max(bodyLowerPixels, ringLowerPixels);
  const midpointCorrection = (lowerPixels - upperPixels) / 2;

  camera.clearViewOffset();
  camera.fov = fov;
  camera.aspect = 1920 / 1080;
  camera.near = 0.1;
  camera.far = 100;
  camera.up.set(0, 1, 0);
  camera.position.set(0, 0.25 + distance * s, distance * k);
  camera.lookAt(0, 0.25, 0);
  camera.setViewOffset(
    1920, 1080,
    -58, midpointCorrection - 78,
    1920, 1080
  );
  camera.updateProjectionMatrix();

  // Finish the incoming cloud-to-white dissolve; thereafter hold completely still.
  const cloudResidue = 1 - lib.span(c.tl, -0.02, 0.16, lib.ease);
  if (cloudResidue > 0) {
    light.save();
    light.globalAlpha = cloudResidue;
    light.fillStyle = "#ffffff";
    light.fillRect(0, 0, 1920, 1080);
    light.restore();
  }
}
 return shot; })();

__AD_MODULES__["S12"] = (function(){ function shot(c) {
  const { three, lib, light, tl } = c;
  const W = 1920, H = 1080;
  const fade = 1 - lib.span(tl, 2.10, 2.40, lib.ease);
  three.studio("white");

  const box = three.get("box", T => {
    const root = three.group();
    const metal = three.aluminium("A");
    const rubber = three.rubber("#171719");
    root.add(three.roundedBox(1.97, 0.5, 1.97, 0.16, metal));

    function contour(path, half, r) {
      path.moveTo(-half + r, -half);
      path.lineTo(half - r, -half);
      path.quadraticCurveTo(half, -half, half, -half + r);
      path.lineTo(half, half - r);
      path.quadraticCurveTo(half, half, half - r, half);
      path.lineTo(-half + r, half);
      path.quadraticCurveTo(-half, half, -half, half - r);
      path.lineTo(-half, -half + r);
      path.quadraticCurveTo(-half, -half, -half + r, -half);
      path.closePath();
    }

    const outline = new T.Shape(), hole = new T.Path();
    contour(outline, 0.915, 0.15);
    contour(hole, 0.835, 0.075);
    outline.holes.push(hole);
    const foot = new T.Mesh(new T.ExtrudeGeometry(outline, {
      depth: 0.022, bevelEnabled: false, curveSegments: 8, steps: 1
    }), rubber);
    foot.rotation.x = -Math.PI / 2;
    foot.position.y = -0.25;
    root.add(foot);

    const led = three.cylinder(0.009, 0.009, 0.004, three.glow("#ffffff", 1.8));
    led.rotation.x = Math.PI / 2;
    led.position.set(0.68, -0.08, 0.986);
    root.add(led);
    root.traverse(o => {
      if (!o.isMesh) return;
      o.castShadow = true;
      o.receiveShadow = true;
      const materials = Array.isArray(o.material) ? o.material : [o.material];
      materials.forEach(m => { m.transparent = true; });
    });
    return root;
  });

  box.position.set(0, 0.25, 0);
  box.rotation.set(0, 0, 0);
  box.scale.setScalar(1);
  box.visible = fade > 0;
  box.traverse(o => {
    if (!o.isMesh) return;
    o.castShadow = fade > 0.02;
    const materials = Array.isArray(o.material) ? o.material : [o.material];
    materials.forEach(m => {
      m.opacity = fade;
      m.depthWrite = fade > 0.5;
    });
  });

  // Fit the unchanged rounded box to [832, 440, 1205, 797].
  const fov = 35;
  const focal = 540 / Math.tan(fov * Math.PI / 360);
  const q = 186.5 / focal;
  function projection(angle) {
    const sn = Math.sin(angle), cs = Math.cos(angle);
    const distance = (0.825 + 0.16 * Math.sqrt(1 + q * q)) / q
      + 0.09 * sn + 0.825 * cs;
    const a = 0.09 * cs + 0.825 * sn;
    const b = 0.09 * sn - 0.825 * cs;
    function extent(e) {
      return (a * e + 0.16 * Math.sqrt(e * e + a * a - 0.0256))
        / (e * e - 0.0256);
    }
    const top = extent(distance - b), bottom = extent(distance + b);
    return { sn, cs, distance, top, bottom, height: focal * (top + bottom) };
  }
  let lo = Math.PI / 3, hi = Math.PI * 4 / 9;
  for (let i = 0; i < 26; i++) {
    const mid = (lo + hi) / 2;
    if (projection(mid).height < 357) lo = mid;
    else hi = mid;
  }
  const p = projection((lo + hi) / 2);
  const opticalY = 618.5 - focal * (p.bottom - p.top) / 2;
  const camera = three.camera;
  camera.fov = fov;
  camera.aspect = W / H;
  camera.near = 0.1;
  camera.far = 100;
  camera.position.set(0, 0.25 + p.distance * p.sn, p.distance * p.cs);
  camera.up.set(0, 1, 0);
  camera.lookAt(0, 0.25, 0);
  camera.setViewOffset(W, H, 960 - 1018.5, 540 - opticalY, W, H);
  camera.updateProjectionMatrix();

  function fittedText(text, x, baseline, width, capHeight, alpha) {
    if (alpha <= 0) return;
    const original = light.fillText;
    const descriptor = Object.getOwnPropertyDescriptor(light, "fillText");
    light.save();
    try {
      light.fillText = function (str, px, py) {
        this.save();
        this.font = this.font.replace(
          /^(?:(?:normal|bold|bolder|lighter|[1-9]00)\s+)?/, "600 "
        );
        const m = this.measureText(str);
        const left = m.actualBoundingBoxLeft || 0;
        const inkWidth = left + m.actualBoundingBoxRight || m.width;
        this.translate(px, py);
        this.scale(width / inkWidth, capHeight / (m.actualBoundingBoxAscent || 78));
        original.call(this, str, left, 0);
        this.restore();
      };
      lib.text(light, text, {
        x, y: baseline, size: 108, color: "#111111",
        align: "left", baseline: "alphabetic", font: "sans", alpha
      });
    } finally {
      if (descriptor) Object.defineProperty(light, "fillText", descriptor);
      else delete light.fillText;
      light.restore();
    }
  }

  // The first incoming frame already registers the headline.
  const headline = tl < 0 ? 0 : 0.35 + 0.65 * lib.span(tl, 0, 0.48, lib.ease);
  const name = lib.span(tl, 0.08, 0.56, lib.ease);
  const sub = lib.span(tl, 0.12, 0.60, lib.ease);
  fittedText("The Mighty", 90 - 3 * (1 - headline), 571, 553, 81, headline * fade);
  fittedText("Pebble", 1344 + 3 * (1 - name), 573, 429, 81, name * fade);
  fittedText("with M6", 1452, 645, 209, 43, sub * fade);
}
 return shot; })();

__AD_MODULES__["S13"] = (function(){ function shot(c) {
  const { light: ctx, lib, three } = c;
  const tl = c.tl;
  const clamp = v => Math.max(0, Math.min(1, v));
  const smooth = v => {
    v = clamp(v);
    return v * v * (3 - 2 * v);
  };

  three.studio("white");
  three.camera.position.set(0, 1.3, 5);
  three.camera.lookAt(0, 0.3, 0);

  ctx.save();

  if (tl >= 2.25) {
    ctx.fillStyle = "#000000";
    ctx.fillRect(0, 0, 1920, 1080);
    ctx.restore();
    return;
  }

  // Finish the outgoing lockup without moving its components.
  const outgoing = 1 - smooth(tl / 0.3);
  if (outgoing > 0) {
    lib.text(ctx, "The Little", {
      x: 90, y: 571, size: 112,
      color: "ground", font: "sans",
      align: "left", baseline: "alphabetic",
      alpha: outgoing
    });

    lib.product(ctx, {
      x: 1018, y: 618, size: 244,
      alpha: outgoing, rotate: 0
    });

    lib.text(ctx, "Pebble", {
      x: 1773, y: 573, size: 112,
      color: "ground", font: "sans",
      align: "right", baseline: "alphabetic",
      alpha: outgoing
    });

    lib.text(ctx, "with P2", {
      x: 1558.5, y: 645, size: 59,
      color: "ground", font: "sans",
      align: "center", baseline: "alphabetic",
      alpha: outgoing
    });
  }

  // At 36.0, the isolated mark enters; its geometry remains stationary.
  const logoAlpha = smooth((tl - 0.3) / 0.48);
  if (logoAlpha > 0) {
    ctx.save();
    ctx.translate(957, 516);
    ctx.scale(70.5, 70.5);
    lib.mark(ctx, 0, 0, 1, 0.95, 1, 1, 0.22, logoAlpha);
    ctx.restore();
  }

  ctx.restore();
}
 return shot; })();

__AD_MODULES__["S14"] = (function(){ function shot(c) {
  const { scene, light, dom, lib } = c;
  const t = Number.isFinite(c.t) ? c.t : 37.95 + c.tl;

  // Hard cut to opaque black; never reveal the studio or fade to ground.
  for (const ctx of [scene, light]) {
    ctx.save();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.globalAlpha = 1;
    ctx.globalCompositeOperation = "source-over";
    ctx.fillStyle = "#000000";
    ctx.fillRect(0, 0, 1920, 1080);
    ctx.restore();
  }

  // Explicitly clear the preceding lockup throughout the legal shot.
  dom.wordmark("", { size: 152, top: 618, alpha: 0 });
  dom.tagline("", { size: 56, top: 800, alpha: 0 });
  dom.cta([], 0);

  if (t < 38.4 || t > 43.0) return;

  const candidates = [
    c.shot && c.shot.legal,
    c.spec && c.spec.legal,
    c.shot && c.shot.copy
  ];
  const supplied = candidates.find(value =>
    typeof value === "string" &&
    value.trim() &&
    !/^(?:none|\(none\))\.?$/i.test(value.trim())
  );
  const legal = supplied
    ? supplied.replace(/\s+/g, " ").trim()
    : "© Pebble. All rights reserved.";

  light.save();
  light.setTransform(1, 0, 0, 1, 0, 0);
  light.globalAlpha = 1;
  light.globalCompositeOperation = "source-over";
  light.beginPath();
  light.rect(430, 1004, 1055, 27);
  light.clip();
  lib.text(light, legal, {
    x: 957.5,
    y: 1017.5,
    size: 23,
    color: "#777777",
    align: "center",
    baseline: "middle",
    font: "sans",
    alpha: 1
  });
  light.restore();
}
 return shot; })();

__AD_MODULES__["score"] = (function(){ function score(h, D, SHOTS, SPEC) {
  const end = Math.min(D, 35.7), beat = 0.5;
  const clamp = (x, a, b) => Math.max(a, Math.min(b, x));
  function tone(f, t, dur, level, pan = 0, lp = 220, partials = [[1, 1, "sine"]]) {
    const room = end - t - 0.04;
    if (t < 0 || room <= 0) return;
    h.tone(f, t, {dur: Math.min(dur, room), level: clamp(level, .01, .06),
      atk: .006, dec: .045, sus: .35, rel: .025, lp, pan, partials});
  }
  function noise(t, dur, level, f, fTo = f, pan = 0, type = "bandpass", q = .8) {
    if (t < 0 || t >= end) return;
    h.burst(t, {dur: Math.min(dur, end - t), level: clamp(level, .005, .03),
      f, fTo, q, type, atk: .002, pan});
  }
  const sections = [
    [.1, 1.17, 73.416, .008], [1.33, 2.5, 73.416, .008],
    [2.5, 4.6, 73.416, .009], [4.6, 7.8, 87.307, .009],
    [7.8, 10.7, 65.406, .009], [10.7, 13.4, 97.999, .009],
    [13.4, 15.9, 73.416, .009], [15.9, 22.1, 65.406, .01],
    [22.1, 28.2, 87.307, .009], [28.2, 30.7, 97.999, .01],
    [30.7, 32.8, 73.416, .011], [32.8, 33.6, 97.999, .008],
    [33.6, 35.58, 73.416, .009]
  ];
  for (const [a, b, root, level] of sections) {
    if (a >= end) continue;
    h.pad([root, root * 1.5], a, Math.min(b, end), {
      level, lp: 185, type: "sine", fadeIn: .045, fadeOut: Math.min(.15, (b - a) / 4)
    });
  }
  const rootAt = t => (sections.find(s => t >= s[0] && t < s[1]) || sections[0])[2];
  const glass = [2349.32, 3520, 2793.83, 4186.01, 3520, 3135.96, 2793.83, 3520];
  for (let n = 0, t = .1; t < end - .17; n++, t = .1 + n * beat) {
    if (t >= 32.8 && t < 33.6) continue;
    const e = t < 2.5 ? .65 : t < 15.9 ? .85 : t < 28.2 ? 1 : 1.12;
    const dip = t > 1.04 && t < 1.31 ? .45 : 1;
    noise(t, .095, .013 * e * dip, 125, 47, 0, "lowpass");
    if (n % 2 === 0 || t >= 15.9)
      tone(rootAt(t) / 2, t, .13, .016 * e * dip, 0, 130);
    noise(t + .25, .022, .006 * e, 6700, 4400, n % 2 ? -.22 : .22);
    if (t >= 7.8 && n % 2)
      noise(t, .037, .008 * e, 4200, 2100, -.12);
    if (t >= 13.4 && t < 32.8)
      noise(t + .375, .015, .0055 * e, 8200, 6100, .28);
    if (t >= 4.6 && n % (t < 22.1 ? 4 : 2) === 0)
      tone(glass[(n >> 1) % 8], t + .125, .095, .01, n % 4 ? -.3 : .3, 6500);
  }
  const cuts = [0, 2.5, 4.6, 7.8, 10.7, 13.4, 15.9, 22.1, 28.2, 30.7, 32.8, 33.6];
  cuts.forEach((t, i) => {
    noise(t, i === 0 ? .055 : .14, i === 0 ? .005 : .019, 190, 48, 0, "lowpass");
    if (i) {
      tone(rootAt(t) / 2, t, .18, t === 15.9 || t === 30.7 ? .03 : .021, 0, 150);
      noise(t, .043, .011, 5400 + (i % 3) * 700, 2600, i % 2 ? -.15 : .15);
      if (t > 2.5) noise(t - .16, .155, .008, 700, 6500, -.2);
    }
  });
  for (const t of [7.8, 10.7, 22.1])
    for (let j = 1; j <= 4; j++)
      noise(t + j * .065, .027, .008, 2300 + j * 780, 1200, j % 2 ? -.4 : .4, "bandpass", 3);
  for (let j = 0; j < 20; j++)
    noise(13.53 + j * .105, .043, .005 + j * .00018, 380 + j * 90, 240, (j % 3 - 1) * .22);
  for (let j = 0; j < 12; j++)
    noise(16.15 + j * .5, .1, .009, 95, 42, 0, "lowpass");
  for (let j = 0; j < 18; j++)
    noise(28.3 + j * .13, .14, .005 + j * .0006, 1000 + j * 330, 2400 + j * 280, j % 2 ? -.2 : .2);
  for (let j = 1; j < 5; j++) {
    const t = 30.7 + j * .42;
    noise(t, .12, .022, 210, 48, 0, "lowpass");
    noise(t, .065, .014, 6500, 3100, j % 2 ? -.24 : .24);
    tone([146.832, 174.614, 195.998, 220][j - 1], t, .11, .019, 0, 270);
  }
  tone(293.665, 33.6, .28, .012, 0, 850);
  tone(3520, 33.6, .24, .01, .15, 5000);
  noise(35.48, .22, .007, 5300, 300, 0);
  // The logo cut is the hard musical stop; logo and legal remain silent.
}
 return score; })();
