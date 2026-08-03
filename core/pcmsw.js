/**
 * pcmsw.js — sliding-window FEC for Lane A audio. STATUS: THE DEFAULT since
 * 2026-08-04 (T_PAR_SW on the wire; `?pcmsw=0` restores block RS as the
 * control arm; the receive path decodes both unconditionally). The paired
 * A/Bs that moved the default: 8/8 at 5% iid loss — concealment 5x lower AND
 * e2e −44 ms — and 6/1/0 (win/tie/loss) under 0.7-0.8 Mbps scarcity, where
 * redundancy-is-congestion predicted it could lose. MEASURED.md has both.
 *
 * WHY A WINDOW INSTEAD OF A BLOCK. RS(K, K+P) cannot emit parity until the group
 * closes, so a frame at position 0 waits K x 8 ms before its repair even EXISTS —
 * measured at K=10: 67% of position-0 repairs arrived after the playhead had passed,
 * 0% at position 9. Shrinking K fixes the delay but pays P/K rate everywhere
 * ("the RS span is a latency term": K=5 reversed the whole win on constrained
 * links). A sliding window decouples the two: parity is emitted every STRIDE data
 * frames covering the last WINDOW frames, so repair latency is bounded by STRIDE
 * while the coding span stays WINDOW.
 *
 * CONSTRUCTION. Parity p_s (s = parity sequence number) covers data frames
 * [end-WINDOW+1 .. end] where end = anchor(s). Coefficients are Cauchy-style
 * 1/(x ⊕ y) with x derived from s and y from the frame seq, both mod-mapped into
 * disjoint ranges of GF(2^8) — deterministic on both ends from (s, seq) alone, so
 * the wire carries NO coefficient bytes, only s, the end seq, and a member bitmap
 * (frames the sender actually put in — capture-side drops never enter, same
 * contract as pcmrs.js: a dropped frame is gapped, never "repaired" into zeros).
 *
 * DECODE. The receiver keeps the last HORIZON frames and parities. For each
 * missing seq it gathers parities whose window covers it, subtracts known frames,
 * and solves the residual system by Gaussian elimination over GF(2^8). Random-ish
 * Cauchy coefficients make any e x e submatrix nonsingular with overwhelming
 * probability but NOT provably (this is not MDS across overlapping windows); the
 * self-test measures the actual failure rate instead of assuming zero.
 *
 * Plain ESM, no dependencies, runs in the browser and under node for the
 * self-test (pcmsw.test.mjs).
 */

const POLY = 0x11d;
const EXP = new Uint8Array(512);
const LOG = new Uint8Array(256);
(function init() {
  let x = 1;
  for (let i = 0; i < 255; i++) {
    EXP[i] = x; LOG[x] = i;
    x <<= 1; if (x & 0x100) x ^= POLY;
  }
  for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
})();
const mul = (a, b) => (a === 0 || b === 0 ? 0 : EXP[LOG[a] + LOG[b]]);
const inv = (a) => EXP[255 - LOG[a]];

// Window geometry. Both ends must agree (negotiated like rsK — see pcm.js `hello`).
// Defaults sized against RS(10,13): same 30% overhead (1 parity per stride of 3.33
// doesn't exist, so 1-in-3 = 33%) but repair latency bounded by 3 frames = 24 ms
// instead of up to 80 ms.
export const SW_WINDOW = 12;  // frames each parity covers
export const SW_STRIDE = 3;   // data frames between parity emissions

// Deterministic coefficient for (paritySeq s, frameSeq q). x and y live in
// disjoint ranges so x ⊕ y is never 0: x in [128..255], y in [0..127].
const coeff = (s, q) => inv((128 + (s % 128)) ^ (q % 128));

/** Sender: incremental accumulator. add() every sent frame; parity() every
 * SW_STRIDE frames returns {s, end, bitmap, sym}. Frames are VARIABLE length
 * (Rice-compressed PCM, 300-1150 B): the symbol is sized to the longest member
 * of THIS window — the same group-sized-symbol economics pcm.js already ships
 * (padding 6.3% instead of 38%) — and every shorter member contributes as if
 * zero-padded. The symbol's length rides as the message length, no field. */
export function SwEncoder(window = SW_WINDOW, stride = SW_STRIDE) {
  const ring = []; // {seq, data} — last `window` frames actually sent
  let parSeq = 0, sinceParity = 0;
  return {
    add(seq, data) {
      ring.push({ seq, data });
      if (ring.length > window) ring.shift();
      sinceParity++;
    },
    // Adaptive code rate lives HERE, in the stride, not in parity count: the
    // decoder never needs to know it (it just receives whatever parities come),
    // so — exactly like RS's sender-local fecN — it may move mid-call at zero
    // negotiation cost. stride 0 = parity off.
    setStride(n) { stride = n; },
    stride: () => stride,
    due: () => stride > 0 && sinceParity >= stride,
    parity() {
      sinceParity = 0;
      const s = parSeq++;
      const end = ring.length ? ring[ring.length - 1].seq : 0;
      // A member the BITMAP cannot name must not be in the SYMBOL. The wire
      // carries the bitmap as u16, so offsets stop at 15; the ring holds the
      // last `window` ADDED frames, and skipped oversize frames stretch its
      // seq span past `window`. Folding an unnameable member in would hand the
      // receiver a parity it subtracts wrongly — a repair into confident
      // garbage, the exact failure the RS path's symLen refusal exists for.
      const use = ring.filter(({ seq }) => end - seq <= 15);
      let symLen = 0, bitmap = 0;
      for (const { data } of use) if (data.length > symLen) symLen = data.length;
      const sym = new Uint8Array(symLen);
      for (const { seq, data } of use) {
        const c = coeff(s, seq);
        for (let i = 0; i < data.length; i++) sym[i] ^= mul(c, data[i]);
        bitmap |= 1 << (end - seq);
      }
      return { s, end, bitmap, sym, window: use.length };
    },
  };
}

/** Receiver: hold frames+parities, repair() solves for the missing seqs it can.
 * Returns Map<seq, Uint8Array> of recovered frames. */
export function SwDecoder(horizon = SW_WINDOW * 3) {
  const frames = new Map();   // seq -> Uint8Array (data actually received or repaired)
  const parities = [];        // {s, end, bitmap, sym}
  const evict = (before) => {
    for (const k of frames.keys()) if (k < before) frames.delete(k);
    while (parities.length && parities[0].end < before) parities.shift();
  };
  return {
    frame(seq, data) { frames.set(seq, data); },
    parity(p) { parities.push(p); parities.sort((a, b) => a.s - b.s); },
    has: (seq) => frames.has(seq),
    /** Try to recover every missing member seq <= maxSeq. */
    repair(maxSeq) {
      const floor = maxSeq - horizon;
      evict(floor);
      // A parity whose window reaches below the eviction floor is unusable FOREVER:
      // its below-floor members can never be subtracted out (evicted if known,
      // unrecoverable if missing). Without this pruning, every evicted-but-missing
      // seq re-entered the system as an unknown on every call — the first self-test
      // run "repaired" 7070 frames against 1115 losses, all at a constant delay of
      // exactly horizon+1, which is what a decoder chewing its own eviction tail
      // looks like.
      const minMember = (p) => {
        let d = 0;
        for (let i = 30; i >= 0; i--) if ((p.bitmap >> i) & 1) { d = i; break; }
        return p.end - d;
      };
      for (let i = parities.length - 1; i >= 0; i--) {
        if (minMember(parities[i]) < floor) parities.splice(i, 1);
      }
      // Collect solvable unknowns: for each parity, members = seqs in bitmap.
      const unknownSet = new Set();
      const eqs = [];
      for (const p of parities) {
        const members = [];
        for (let d = 0; d < 31; d++) {
          if ((p.bitmap >> d) & 1) members.push(p.end - d);
        }
        const missing = members.filter((q) => !frames.has(q));
        if (!missing.length) continue;
        if (missing.some((q) => q > maxSeq)) continue; // future members: not yet decidable
        // residual = parity minus contributions of KNOWN members. Each frame
        // contributes only its own length — reading to the parity's length would
        // walk off the end of shorter frames (OOB Uint8Array reads are undefined,
        // and mul(c, undefined) is NaN poisoning the whole residual). Zero-padding
        // is implicit: XOR with zero is a no-op.
        const res = Uint8Array.from(p.sym);
        for (const q of members) {
          if (missing.includes(q)) continue;
          const f = frames.get(q);
          const c = coeff(p.s, q);
          const L = Math.min(f.length, res.length);
          for (let i = 0; i < L; i++) res[i] ^= mul(c, f[i]);
        }
        eqs.push({ missing, res, s: p.s });
        for (const q of missing) unknownSet.add(q);
      }
      if (!unknownSet.size || eqs.length < 1) return new Map();
      const unknowns = [...unknownSet].sort((a, b) => a - b);
      const col = new Map(unknowns.map((q, i) => [q, i]));
      // Build matrix rows [coeffs | residual]
      const n = unknowns.length;
      const symLen = Math.max(...eqs.map((e) => e.res.length));
      const rows = eqs.map((e) => {
        // residuals to a common length; shorter ones are implicitly zero-padded
        const b = e.res.length === symLen ? e.res : (() => { const x = new Uint8Array(symLen); x.set(e.res); return x; })();
        const r = { a: new Uint8Array(n), b };
        for (const q of e.missing) r.a[col.get(q)] = coeff(e.s, q);
        return r;
      });
      // Gaussian elimination over GF(256)
      const solved = new Map();
      let rank = 0;
      for (let c = 0; c < n && rank < rows.length; c++) {
        let piv = -1;
        for (let r = rank; r < rows.length; r++) if (rows[r].a[c]) { piv = r; break; }
        if (piv === -1) continue;
        [rows[rank], rows[piv]] = [rows[piv], rows[rank]];
        const ic = inv(rows[rank].a[c]);
        const R = rows[rank];
        if (ic !== 1) {
          for (let i = 0; i < n; i++) R.a[i] = mul(R.a[i], ic);
          const nb = Uint8Array.from(R.b);
          for (let i = 0; i < symLen; i++) nb[i] = mul(nb[i], ic);
          R.b = nb;
        }
        for (let r = 0; r < rows.length; r++) {
          if (r === rank || !rows[r].a[c]) continue;
          const f = rows[r].a[c];
          const O = rows[r];
          const nb = Uint8Array.from(O.b);
          for (let i = 0; i < n; i++) O.a[i] ^= mul(f, R.a[i]);
          for (let i = 0; i < symLen; i++) nb[i] ^= mul(f, R.b[i]);
          O.b = nb;
        }
        rank++;
      }
      // Back-substitute solved unit rows
      for (const R of rows) {
        let nz = -1, cnt = 0;
        for (let i = 0; i < n; i++) if (R.a[i]) { nz = i; cnt++; }
        if (cnt === 1 && R.a[nz] === 1) {
          const seq = unknowns[nz];
          if (!frames.has(seq)) { frames.set(seq, R.b); solved.set(seq, R.b); }
        }
      }
      return solved;
    },
  };
}
