/**
 * Self-test for pcmrs.js — run with `node pcmrs.test.mjs` from core/.
 * Random groups, random erasures, byte-exact recovery or a loud failure.
 */
import { RsEncoder, rsDecode, RS_K, RS_P } from './pcmrs.js';

const SYM = 1152;
let failures = 0;
const fail = (msg) => { failures++; console.error('FAIL:', msg); };

// Deterministic PRNG so a failure reproduces exactly.
let seed = 0xC0FFEE;
const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;

const randSym = () => {
  const b = new Uint8Array(SYM);
  for (let i = 0; i < SYM; i++) b[i] = (rnd() * 256) | 0;
  return b;
};

const TRIALS = 300;
let recoveredTotal = 0;
for (let t = 0; t < TRIALS; t++) {
  const datas = Array.from({ length: RS_K }, randSym);
  // Sender drops 0-2 positions (capture-side backpressure): they contribute nothing.
  const dropped = new Set();
  const nDrop = (rnd() * 3) | 0;
  for (let i = 0; i < nDrop; i++) dropped.add((rnd() * RS_K) | 0);
  let bitmap = 0;
  const enc = new RsEncoder(SYM);
  for (let i = 0; i < RS_K; i++) {
    if (dropped.has(i)) continue;
    enc.add(i, datas[i]);
    bitmap |= 1 << i;
  }
  const parity = [enc.parity(0), enc.parity(1), enc.parity(2)];

  // Network erasures on contributing positions.
  const contributing = [...Array(RS_K).keys()].filter((i) => !dropped.has(i));
  const maxEras = Math.min(RS_P, contributing.length);
  const nEras = (rnd() * (maxEras + 1)) | 0;
  const erased = new Set();
  while (erased.size < nEras) erased.add(contributing[(rnd() * contributing.length) | 0]);

  const rxData = datas.map((d, i) => (dropped.has(i) || erased.has(i) ? null : d));
  // Parity loss is allowed too, as long as enough survives.
  const rxPar = parity.map((p) => (rnd() < 0.15 ? null : p));

  const rec = rsDecode(bitmap, rxData, rxPar);
  const parityAlive = rxPar.filter(Boolean).length;
  if (erased.size <= parityAlive && rec === null) {
    fail(`trial ${t}: ${erased.size} erasures with ${parityAlive} parity alive decoded null`);
    continue;
  }
  if (rec === null) continue; // genuinely undecodable — expected branch
  for (const i of erased) {
    const r = rec.get(i);
    if (!r) { fail(`trial ${t}: erased pos ${i} not recovered`); continue; }
    for (let k = 0; k < SYM; k++) {
      if (r[k] !== datas[i][k]) { fail(`trial ${t}: pos ${i} byte ${k} mismatch`); break; }
    }
    recoveredTotal++;
  }
  // Recovered symbols must satisfy every parity that arrived.
  const full = datas.map((d, i) => rec.get(i) ?? (dropped.has(i) || erased.has(i) ? null : d));
  for (let j = 0; j < RS_P; j++) {
    if (!rxPar[j]) continue;
    const acc = new Uint8Array(SYM);
    for (let i = 0; i < RS_K; i++) {
      if (!((bitmap >> i) & 1) || !full[i]) continue;
      const coef = 0; // recompute via encoder path below
      void coef;
    }
    // Re-encode from scratch and compare against the original parity.
    const re = new RsEncoder(SYM);
    for (let i = 0; i < RS_K; i++) if ((bitmap >> i) & 1) re.add(i, full[i]);
    const p = re.parity(j);
    for (let k = 0; k < SYM; k++) {
      if (p[k] !== parity[j][k]) { fail(`trial ${t}: parity ${j} inconsistent after repair at byte ${k}`); break; }
    }
  }
}

// Over-erasure must decode null, never garbage.
for (let t = 0; t < 50; t++) {
  const datas = Array.from({ length: RS_K }, randSym);
  const enc = new RsEncoder(SYM);
  let bitmap = 0;
  for (let i = 0; i < RS_K; i++) { enc.add(i, datas[i]); bitmap |= 1 << i; }
  const rxData = datas.map((d, i) => (i < RS_P + 1 ? null : d)); // 4 erasures
  const rxPar = [enc.parity(0), enc.parity(1), enc.parity(2)];
  const rec = rsDecode(bitmap, rxData, rxPar);
  if (rec !== null) fail(`over-erasure trial ${t}: 4 erasures did not fail cleanly`);
}

if (failures) {
  console.error(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log(`ok — ${TRIALS} groups, ${recoveredTotal} erased symbols recovered byte-exact, over-erasure fails clean`);
