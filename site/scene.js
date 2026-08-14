import * as THREE from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';

const canvas = document.getElementById('stage');
const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const isPhone = () => window.innerWidth < 800;

const renderer = new THREE.WebGLRenderer({
  canvas,
  antialias: true,
  alpha: true,
  powerPreference: 'high-performance',
});
renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, isPhone() ? 1.4 : 1.85));
renderer.setSize(window.innerWidth, window.innerHeight, false);
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.05;

const scene = new THREE.Scene();
scene.fog = new THREE.FogExp2(0x05060a, 0.038);

const camera = new THREE.PerspectiveCamera(36, window.innerWidth / window.innerHeight, 0.1, 80);
camera.position.set(0, 0.15, 7.6);

const pmrem = new THREE.PMREMGenerator(renderer);
const envScene = new THREE.Scene();
envScene.background = new THREE.Color(0x05060a);
const lamp = (color, [x, y, z], s = 1.4) => {
  const m = new THREE.Mesh(
    new THREE.SphereGeometry(s, 16, 16),
    new THREE.MeshBasicMaterial({ color }),
  );
  m.position.set(x, y, z);
  envScene.add(m);
};
lamp(0xfff1d6, [-5, 3.2, 2.4], 1.8);
lamp(0x6ea8ff, [5.2, -1.4, 1.6], 1.6);
lamp(0xffffff, [0.4, 4.6, 3.2], 0.7);
scene.environment = pmrem.fromScene(envScene, 0.08).texture;
scene.environmentIntensity = 0.72;

const key = new THREE.PointLight(0xfff3dd, 18, 18, 2);
key.position.set(-2.4, 1.6, 3.2);
scene.add(key);
const fill = new THREE.PointLight(0x4d8dff, 14, 18, 2);
fill.position.set(2.6, -0.4, 2.4);
scene.add(fill);
scene.add(new THREE.AmbientLight(0x1a2233, 0.55));

const group = new THREE.Group();
group.position.set(isPhone() ? 0 : 2.55, isPhone() ? 1.55 : 0.06, 0);
group.scale.setScalar(isPhone() ? 0.78 : 1.12);
scene.add(group);

function glass(color, emissive) {
  return new THREE.MeshPhysicalMaterial({
    color,
    metalness: 0.0,
    roughness: 0.12,
    transmission: 0.88,
    thickness: 1.05,
    ior: 1.42,
    clearcoat: 0.8,
    clearcoatRoughness: 0.18,
    attenuationColor: color,
    attenuationDistance: 2.1,
    envMapIntensity: 0.85,
    emissive,
    emissiveIntensity: 0.22,
    iridescence: 0.35,
    iridescenceIOR: 1.3,
    iridescenceThicknessRange: [120, 380],
    transparent: true,
  });
}

const geo = new THREE.SphereGeometry(1.18, 96, 96);
const warm = new THREE.Mesh(geo, glass(0xf4f0e6, 0x3a2a18));
const cool = new THREE.Mesh(geo, glass(0x3b82f6, 0x12305a));
warm.position.set(-0.72, 0.06, 0.12);
cool.position.set(0.72, -0.04, -0.08);
group.add(warm, cool);

const coreGeo = new THREE.SphereGeometry(0.34, 32, 32);
const warmCore = new THREE.Mesh(coreGeo, new THREE.MeshBasicMaterial({ color: 0xffe8c2, transparent: true, opacity: 0.55 }));
const coolCore = new THREE.Mesh(coreGeo, new THREE.MeshBasicMaterial({ color: 0x7cb3ff, transparent: true, opacity: 0.5 }));
warm.add(warmCore);
cool.add(coolCore);

const haloGeo = new THREE.SphereGeometry(1.32, 32, 32);
const warmHalo = new THREE.Mesh(haloGeo, new THREE.MeshBasicMaterial({
  color: 0xf3e6c8, transparent: true, opacity: 0.045, blending: THREE.AdditiveBlending, depthWrite: false,
}));
const coolHalo = new THREE.Mesh(haloGeo, new THREE.MeshBasicMaterial({
  color: 0x4d8dff, transparent: true, opacity: 0.05, blending: THREE.AdditiveBlending, depthWrite: false,
}));
warm.add(warmHalo);
cool.add(coolHalo);

const count = isPhone() ? 220 : 520;
const positions = new Float32Array(count * 3);
for (let i = 0; i < count; i++) {
  const r = 3.2 + Math.random() * 10;
  const t = Math.random() * Math.PI * 2;
  const p = (Math.random() - 0.5) * 6.5;
  positions[i * 3] = Math.cos(t) * r;
  positions[i * 3 + 1] = p;
  positions[i * 3 + 2] = Math.sin(t) * r * 0.55;
}
const pts = new THREE.BufferGeometry();
pts.setAttribute('position', new THREE.BufferAttribute(positions, 3));
const dust = new THREE.Points(pts, new THREE.PointsMaterial({
  color: 0xc9d4ea, size: 0.018, transparent: true, opacity: 0.42, depthWrite: false,
}));
scene.add(dust);

let composer = null;
try {
  composer = new EffectComposer(renderer);
  composer.addPass(new RenderPass(scene, camera));
  const bloom = new UnrealBloomPass(new THREE.Vector2(window.innerWidth, window.innerHeight), 0.55, 0.7, 0.82);
  composer.addPass(bloom);
} catch {
  composer = null;
}

const pointer = { x: 0, y: 0 };
window.addEventListener('pointermove', (e) => {
  pointer.x = (e.clientX / window.innerWidth) * 2 - 1;
  pointer.y = (e.clientY / window.innerHeight) * 2 - 1;
}, { passive: true });

function scrollT() {
  const max = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
  return Math.min(1, Math.max(0, window.scrollY / max));
}

let raf = 0;
function frame(now) {
  const t = now * 0.001;
  const s = scrollT();
  const phone = isPhone();

  const sep = THREE.MathUtils.lerp(0.72, 1.18, ease(s));
  warm.position.x = -sep;
  cool.position.x = sep;
  warm.position.y = 0.06 + Math.sin(t * 0.45) * 0.05;
  cool.position.y = -0.04 + Math.cos(t * 0.38) * 0.05;
  if (!reduce) {
    warm.rotation.y = t * 0.12;
    cool.rotation.y = -t * 0.1;
    dust.rotation.y = t * 0.02;
  }

  group.rotation.y = THREE.MathUtils.lerp(group.rotation.y, pointer.x * 0.18, 0.04);
  group.rotation.x = THREE.MathUtils.lerp(group.rotation.x, -pointer.y * 0.1, 0.04);

  const targetX = phone ? 0 : THREE.MathUtils.lerp(2.55, 2.9, s);
  const targetY = phone ? THREE.MathUtils.lerp(1.55, 0.2, s) : 0.06;
  const targetScale = phone
    ? THREE.MathUtils.lerp(0.78, 0.55, s)
    : THREE.MathUtils.lerp(1.12, 0.78, s);
  group.position.x = THREE.MathUtils.lerp(group.position.x, targetX, 0.07);
  group.position.y = THREE.MathUtils.lerp(group.position.y, targetY, 0.07);
  const sc = THREE.MathUtils.lerp(group.scale.x, targetScale, 0.07);
  group.scale.setScalar(sc);

  const z = phone
    ? THREE.MathUtils.lerp(8.8, 12.2, s)
    : THREE.MathUtils.lerp(7.2, 10.4, s);
  const y = phone ? 0.35 : THREE.MathUtils.lerp(0.06, 0.22, s);
  camera.position.z = THREE.MathUtils.lerp(camera.position.z, z, 0.06);
  camera.position.y = THREE.MathUtils.lerp(camera.position.y, y, 0.06);
  camera.lookAt(phone ? 0 : 1.55, 0.04, 0);

  if (composer) composer.render();
  else renderer.render(scene, camera);
  raf = requestAnimationFrame(frame);
}

function ease(x) {
  return x < 0.5 ? 2 * x * x : 1 - Math.pow(-2 * x + 2, 2) / 2;
}

function onResize() {
  const w = window.innerWidth;
  const h = window.innerHeight;
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
  renderer.setSize(w, h, false);
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, isPhone() ? 1.4 : 1.85));
  if (composer) composer.setSize(w, h);
}

window.addEventListener('resize', onResize);
onResize();

if (reduce) {
  renderer.render(scene, camera);
} else {
  raf = requestAnimationFrame(frame);
}

document.addEventListener('visibilitychange', () => {
  if (document.hidden) cancelAnimationFrame(raf);
  else if (!reduce) raf = requestAnimationFrame(frame);
});
