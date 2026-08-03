/**
 * RS(10,13) for Lane A audio: 10 data symbols + 3 parity symbols over GF(2^8),
 * recovers any 3 of 13 lost. At 8 ms framing that is 30% overhead buying an
 * 80 ms protection span (DESIGN.md §9, §11).
 *
 * Every symbol is exactly 1,152 B (384 samples × int24), which makes this far
 * simpler than a video FEC: no length fields, no padding, no truncation case.
 *
 * Construction: systematic Cauchy — parity_j = Σ_i d_i / (x_j ⊕ y_i) with
 * x = {10,11,12}, y = {0..9}. Any square submatrix of a Cauchy matrix over
 * distinct, disjoint x/y sets is nonsingular, so ANY 10 of the 13 symbols
 * rebuild the data (MDS). Decode of e erasures is an e×e solve, e ≤ 3.
 *
 * The sender accumulates incrementally: each sent frame is multiplied into
 * the three parity accumulators as it goes out, so closing a group costs
 * nothing. Positions the sender dropped (capture-side backpressure) never
 * enter the accumulators, and the parity header's member bitmap says which
 * positions contributed — a dropped frame decodes as nothing, is never
 * "repaired" into zeros, and is left for the playout concealer to gap.
 *
 * Plain ESM, no dependencies, no browser or node APIs: runs on the main
 * thread of the app and under `node` for the self-test. See pcmrs.test.mjs.
 */

const POLY = 0x11d; // AES field polynomial; generator 2
const EXP = new Uint8Array(512);
const LOG = new Uint8Array(256);
(function init() {
  let x = 1;
  for (let i = 0; i < 255; i++) {
    EXP[i] = x;
    LOG[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= POLY;
  }
  for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
})();

const mul = (a, b) => (a === 0 || b === 0 ? 0 : EXP[LOG[a] + LOG[b]]);
const inv = (a) => EXP[255 - LOG[a]]; // a must be nonzero

// Data symbols per group. A `let` with a live ESM binding, not a constant,
// because the group SPAN is a latency term: parity cannot be computed until the
// group closes, so the frame at position 0 waits RS_K × 8 ms before its repair
// even exists. Measured at K=10: 67% of position-0 repairs arrived after the
// playhead had passed, against 0% at position 9. setRsK() exists to test
// shorter spans against that.
//
// BOTH ENDS MUST AGREE. The receiver derives a group from `seq - (seq % RS_K)`,
// so a mismatch is not a degradation, it is two peers grouping different frames
// together. Anything that sets this must set it identically on both sides.
export let RS_K = 10;
export const RS_P = 3; // parity symbols per group

// Cauchy coefficients: C[j][i] = 1 / ((RS_K+j) ⊕ i). The x set {RS_K..RS_K+P-1}
// and the y set {0..RS_K-1} are disjoint by construction, so no denominator is
// ever zero — which holds for any RS_K, not just 10.
let C = [];
function buildC() {
  C = [];
  for (let j = 0; j < RS_P; j++) {
    const row = new Uint8Array(RS_K);
    for (let i = 0; i < RS_K; i++) row[i] = inv((RS_K + j) ^ i);
    C.push(row);
  }
}
buildC();

/**
 * Set the group size. Must be called before any encoder or group exists, and
 * with the SAME value on both peers. Bounded at 16 because the member bitmap is
 * a u16 on the wire.
 */
export function setRsK(k) {
  if (!Number.isFinite(k) || k < 2 || k > 16) return RS_K; // NaN-hostile: keep the default
  RS_K = Math.floor(k);
  buildC();
  return RS_K;
}

/** Multiply-XOR: acc[k] ^= coef · src[k] for the whole symbol. */
function mulXor(acc, coef, src) {
  if (coef === 1) {
    for (let k = 0; k < src.length; k++) acc[k] ^= src[k];
    return;
  }
  const lc = LOG[coef];
  for (let k = 0; k < src.length; k++) {
    const s = src[k];
    if (s) acc[k] ^= EXP[lc + LOG[s]];
  }
}

/**
 * Incremental group encoder. add() each SENT frame at its position in the
 * group; parity(j) is final once all contributing positions were added.
 *
 * `nPar` is how many parity symbols this group will actually emit (default
 * RS_P, the old behaviour). The work is O(RS_K · nPar · symLen), so a sender
 * running a lower code rate pays proportionally less field arithmetic rather
 * than computing three symbols and discarding two. The receiver never needs
 * to be told: rsDecode() below collects whatever slots arrived and only
 * requires as many as there are erasures, so parity that was never sent is
 * indistinguishable from parity that was lost.
 */
export class RsEncoder {
  constructor(symLen, nPar = RS_P) {
    this.n = Math.max(0, Math.min(RS_P, nPar));
    this.acc = [];
    for (let j = 0; j < this.n; j++) this.acc.push(new Uint8Array(symLen));
  }
  add(pos, bytes) {
    for (let j = 0; j < this.n; j++) mulXor(this.acc[j], C[j][pos], bytes);
  }
  parity(j) {
    return this.acc[j];
  }
}

/**
 * Decode the erased members of a group.
 *
 * @param memberBitmap u16 — bit i set means position i CONTRIBUTED to the
 *   parity (sender dropped positions never contribute; they are not erasures,
 *   they are gaps the concealer owns).
 * @param data Array(RS_K) of Uint8Array|null — received data symbols.
 * @param parity Array(RS_P) of Uint8Array|null — received parity symbols.
 * @returns Map<pos, Uint8Array> of recovered symbols, or null if the group
 *   is not decodable (more erasures than received parity, or fewer than two
 *   members to reason over).
 */
export function rsDecode(memberBitmap, data, parity) {
  const erased = [];
  let present = 0;
  for (let i = 0; i < RS_K; i++) {
    if (!((memberBitmap >> i) & 1)) continue; // never contributed — a gap, not an erasure
    if (data[i]) present++;
    else erased.push(i);
  }
  if (!erased.length) return new Map(); // nothing to do
  if (present === 0) return null;
  const e = erased.length;
  // Which parity symbols arrived?
  const pr = [];
  for (let j = 0; j < RS_P; j++) if (parity[j]) pr.push(j);
  if (pr.length < e) return null;

  // b[r] = parity[pr[r]] ⊕ Σ_{i present} C[pr[r]][i]·data[i]  (per byte)
  // A[r][c] = C[pr[r]][erased[c]]   — solve A · x = b over GF(2^8).
  const symLen = parity[pr[0]].length;
  const A = [];
  const B = [];
  for (let r = 0; r < e; r++) {
    const j = pr[r];
    const row = new Uint8Array(e);
    for (let c = 0; c < e; c++) row[c] = C[j][erased[c]];
    A.push(row);
    const b = new Uint8Array(parity[j]); // copy — it gets XORed down
    for (let i = 0; i < RS_K; i++) {
      if (data[i] && ((memberBitmap >> i) & 1)) {
        const coef = C[j][i];
        const lc = LOG[coef];
        const d = data[i];
        if (coef === 1) for (let k = 0; k < symLen; k++) b[k] ^= d[k];
        else for (let k = 0; k < symLen; k++) { const s = d[k]; if (s) b[k] ^= EXP[lc + LOG[s]]; }
      }
    }
    B.push(b);
  }

  // Gaussian elimination, e ≤ 3 — the whole solve is a handful of field ops.
  for (let c = 0; c < e; c++) {
    let piv = -1;
    for (let r = c; r < e; r++) if (A[r][c]) { piv = r; break; }
    if (piv === -1) return null; // singular — cannot happen for distinct parity rows, fail safe
    if (piv !== c) {
      [A[piv], A[c]] = [A[c], A[piv]];
      [B[piv], B[c]] = [B[c], B[piv]];
    }
    const scale = inv(A[c][c]);
    if (scale !== 1) {
      for (let k = c; k < e; k++) A[c][k] = mul(A[c][k], scale);
      mulXorScale(B[c], scale);
    }
    for (let r = 0; r < e; r++) {
      if (r === c || !A[r][c]) continue;
      const f = A[r][c];
      for (let k = c; k < e; k++) A[r][k] ^= mul(f, A[c][k]);
      mulXor(B[r], f, B[c]);
    }
  }

  const out = new Map();
  for (let c = 0; c < e; c++) out.set(erased[c], B[c]);
  return out;
}

function mulXorScale(b, scale) {
  if (scale === 1) return;
  const ls = LOG[scale];
  for (let k = 0; k < b.length; k++) { const s = b[k]; if (s) b[k] = EXP[ls + LOG[s]]; }
}
