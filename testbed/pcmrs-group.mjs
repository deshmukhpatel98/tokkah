/**
 * End-to-end RS with GROUP-SIZED symbols, on real audio.
 *
 * core/pcmrs.test.mjs proves the field arithmetic on fixed-length symbols.
 * This proves the thing that arithmetic sits inside: the sender sizes each
 * group's symbol to its own longest COMPRESSED frame, the receiver learns that
 * length only from the length of the parity message, and a repaired frame must
 * still decompress to the exact samples that went in.
 *
 * The bugs it is built to catch, all of which produce plausible audio rather
 * than an error:
 *   - the encoder's padding scratch not cleared between members, so parity
 *     carries the previous frame's tail;
 *   - the receiver padding to the wrong length (1152, or the longest frame IT
 *     happened to receive, rather than the parity's);
 *   - a group whose longest frame is one of the LOST ones — then no surviving
 *     data frame is symLen long, and only the parity knows the size;
 *   - the exact-fit member, which has no padding at all.
 *
 *   node testbed/pcmrs-group.mjs
 */
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
import { packFrame, unpackFrame, PACK_SAMPLES as N } from '../tape-app/public/core/pcmpack.js';
import { RsEncoder, rsDecode, RS_K, RS_P } from '../tape-app/public/core/pcmrs.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const RS_SYM_MAX = 1160 - 8; // 1152: parity header is 8 B, one datagram is 1160

let rng = 20260803;
const rnd = () => { rng ^= rng << 13; rng |= 0; rng ^= rng >>> 17; rng ^= rng << 5; rng |= 0; return (rng >>> 0) / 4294967296; };

// ── corpus ──────────────────────────────────────────────────────────────────
function wav(path) {
  const b = readFileSync(path);
  let off = 12, ch = 1, data = null;
  while (off + 8 <= b.length) {
    const id = b.toString('ascii', off, off + 4), sz = b.readUInt32LE(off + 4);
    if (id === 'fmt ') ch = b.readUInt16LE(off + 10);
    if (id === 'data') data = b.subarray(off + 8, off + 8 + sz);
    off += 8 + sz + (sz & 1);
  }
  const n = Math.floor(data.length / 2 / ch), s = new Int32Array(n);
  for (let i = 0; i < n; i++) s[i] = data.readInt16LE(i * 2 * ch);
  return s;
}
const corpus = [];
for (const f of ['floor-fall.wav', 'probe.wav', 'fullband.wav']) {
  try { corpus.push([f, wav(`${HERE}/media/${f}`)]); } catch (e) { console.log(`  (skipped ${f}: ${e.code || e.message})`); }
}
try {
  const flac = execFileSync('find', [`${HERE}/media/LibriSpeech`, '-name', '*.flac']).toString().split('\n')[0];
  const raw = execFileSync('ffmpeg', ['-v', 'quiet', '-i', flac, '-ar', '48000', '-ac', '1', '-f', 's16le', '-'], { maxBuffer: 1 << 28 });
  const n = raw.length / 2, s = new Int32Array(n);
  for (let i = 0; i < n; i++) s[i] = raw.readInt16LE(i * 2);
  corpus.push(['LibriSpeech', s]);
} catch (e) { console.log(`  (skipped LibriSpeech: ${e.code || e.message})`); }
if (!corpus.length) { console.log('FAIL: no corpus'); process.exit(1); }

// ── sender: exactly what pcm.js does ────────────────────────────────────────
// Returns { symLen, bitmap, data:[Uint8Array|null], parity:[Uint8Array] } plus
// the source samples, so a repair can be compared against what went in.
function encodeGroup(frames, dropPositions, nPar = RS_P) {
  const stage = new Array(RS_K).fill(null);
  let bitmap = 0, oversize = 0;
  for (let pos = 0; pos < frames.length; pos++) {
    if (dropPositions.has(pos)) continue;            // sender-side backpressure drop
    const out = new Uint8Array(1 + N * 3);
    const len = packFrame(frames[pos], out);
    if (len > RS_SYM_MAX) { oversize++; continue; }  // verbatim escape: not a member
    stage[pos] = out.subarray(0, len);
    bitmap |= 1 << pos;
  }
  let symLen = 0;
  for (let i = 0; i < RS_K; i++) if (((bitmap >> i) & 1) && stage[i].length > symLen) symLen = stage[i].length;
  const enc = new RsEncoder(symLen, nPar);
  const scratch = new Uint8Array(RS_SYM_MAX);        // reused, as in pcm.js
  for (let i = 0; i < RS_K; i++) {
    if (!((bitmap >> i) & 1)) continue;
    const sym = scratch.subarray(0, symLen);
    sym.fill(0);
    sym.set(stage[i]);
    enc.add(i, sym);
  }
  // Slots beyond nPar stay null — the adaptive code rate emits fewer symbols,
  // and the receiver is supposed to be unable to tell that from parity lost in
  // flight. Modelling them as null rather than as a short array is the whole
  // point: a bug that pushes `undefined` into the queue would otherwise be
  // hidden by a shorter array that still looks well-formed.
  const parity = new Array(RS_P).fill(null);
  for (let j = 0; j < nPar; j++) parity[j] = enc.parity(j).slice(0);
  return { symLen, bitmap, wire: stage, parity, oversize };
}

// ── receiver: exactly what pcm.js does ──────────────────────────────────────
function decodeGroup(bitmap, recvData, recvPar) {
  let symLen = 0;
  for (let j = 0; j < RS_P; j++) if (recvPar[j]) { symLen = recvPar[j].length; break; }
  if (!symLen) return null;
  const padded = new Array(RS_K).fill(null);
  for (let i = 0; i < RS_K; i++) {
    const d = recvData[i];
    if (!d) continue;
    if (d.length === symLen) { padded[i] = d; continue; }
    if (d.length < symLen) { const c = new Uint8Array(symLen); c.set(d); padded[i] = c; continue; }
    if ((bitmap >> i) & 1) return 'mismatch';
  }
  return rsDecode(bitmap, padded, recvPar);
}

// ── run ─────────────────────────────────────────────────────────────────────
// Swept across every code rate the adaptive ladder can select. n=3 is the old
// fixed rate; n=1 and n=2 are what a good link now gets, and they are exactly
// where a wrong Cauchy row or an accumulator sized for three symbols would go
// unnoticed — a lower rate repairs FEWER frames, so a broken one looks quiet
// rather than wrong.
let groups = 0, repaired = 0, wrong = 0, undecodable = 0, mismatches = 0;
let symSum = 0, paySum = 0, fixedSum = 0, exactFit = 0, longestLost = 0, oversizeTotal = 0;
let badSlot = 0;
const got = new Int32Array(N);

for (const N_PAR of [1, 2, RS_P]) {
  let nWrong = 0, nRep = 0, nSym = 0, nUndec = 0;
  for (const [name, sig] of corpus) {
    const nf = Math.min(4000, Math.floor(sig.length / N));
    const nGroups = Math.floor(nf / RS_K);
    for (let g = 0; g < nGroups; g++) {
      const frames = [];
      for (let m = 0; m < RS_K; m++) {
        const s = new Int32Array(N);
        for (let i = 0; i < N; i++) s[i] = (sig[(g * RS_K + m) * N + i] << 8) + ((rnd() * 256) | 0);
        frames.push(s);
      }
      // A sender drop on ~1 group in 8, so "never contributed" is exercised
      // alongside erasure rather than only in the RS unit test.
      const senderDrops = new Set();
      if (rnd() < 0.12) senderDrops.add((rnd() * RS_K) | 0);

      const enc = encodeGroup(frames, senderDrops, N_PAR);
      // Nothing may be emitted past the selected rate. A symbol in a slot the
      // sender never accumulated would decode into confident garbage.
      for (let j = N_PAR; j < RS_P; j++) if (enc.parity[j]) badSlot++;
      oversizeTotal += enc.oversize;
      if (!enc.symLen) continue;
      groups++; nSym++;
      symSum += enc.symLen; fixedSum += RS_SYM_MAX;
      for (let i = 0; i < RS_K; i++) if (enc.wire[i]) { paySum += enc.wire[i].length; if (enc.wire[i].length === enc.symLen) exactFit++; }

      // Wire loss scales with the rate: 1..N_PAR members, plus sometimes one of
      // the parity symbols that was actually sent.
      const members = [];
      for (let i = 0; i < RS_K; i++) if ((enc.bitmap >> i) & 1) members.push(i);
      const nErase = Math.min(members.length - 1, 1 + ((rnd() * N_PAR) | 0));
      const erase = new Set();
      while (erase.size < nErase) erase.add(members[(rnd() * members.length) | 0]);
      // Did we erase the frame that SET the symbol length? Then no surviving data
      // frame is symLen long and only the parity carries the size.
      let lostLongest = false;
      for (const i of erase) if (enc.wire[i].length === enc.symLen) lostLongest = true;
      if (lostLongest) longestLost++;

      const recvData = new Array(RS_K).fill(null);
      for (let i = 0; i < RS_K; i++) if (enc.wire[i] && !erase.has(i)) recvData[i] = enc.wire[i].slice(0);
      const recvPar = enc.parity.map((p) => (p ? p.slice(0) : null));
      if (rnd() < 0.25) recvPar[(rnd() * N_PAR) | 0] = null;

      const rec = decodeGroup(enc.bitmap, recvData, recvPar);
      if (rec === 'mismatch') { mismatches++; continue; }
      if (!rec) { undecodable++; nUndec++; continue; }
      for (const [pos, bytes] of rec) {
        repaired++; nRep++;
        if (bytes.length !== enc.symLen) { wrong++; nWrong++; console.log(`  n=${N_PAR} ${name} g${g} pos${pos}: symbol ${bytes.length} B, expected ${enc.symLen}`); continue; }
        got.fill(0);
        unpackFrame(bytes, got);
        for (let i = 0; i < N; i++) {
          if (got[i] !== frames[pos][i]) { wrong++; nWrong++; console.log(`  n=${N_PAR} ${name} g${g} pos${pos}: sample ${i} ${frames[pos][i]} -> ${got[i]} (sym ${enc.symLen} B)`); break; }
        }
      }
    }
  }
  console.log(`  n=${N_PAR} (${Math.round((100 * N_PAR) / RS_K)}% redundancy): ${nSym} groups, ` +
              `${nRep} frames repaired, ${nUndec} over-erased (correctly refused), ${nWrong} wrong`);
  if (!nRep) { console.log(`FAIL: n=${N_PAR} repaired nothing — that rate is untested, not proven.`); process.exit(1); }
}

const meanSym = symSum / groups;
console.log(`\n${groups} groups, ${repaired} frames repaired from parity, ${wrong} decoded wrong.`);
console.log(`${undecodable} groups not decodable (over-erasure, failed clean), ${mismatches} symbol mismatches, ${oversizeTotal} frames excluded as verbatim.`);
console.log(`${badSlot} parity symbols emitted past the selected code rate (must be 0).`);
console.log(`${longestLost} groups lost their LONGEST member — the case where only the parity knows the symbol length.`);
console.log(`${exactFit} exact-fit members (no padding at all).`);
console.log(`mean symbol ${meanSym.toFixed(0)} B vs a fixed ${RS_SYM_MAX} B: parity is ${(100 * (1 - symSum / fixedSum)).toFixed(1)}% smaller.`);
console.log(`padding is ${(100 * (1 - paySum / symSum / RS_K)).toFixed(1)}% of the group's symbol bytes.`);

// A run that repaired nothing, or never hit the interesting cases, is not a
// pass — it is a test that did not run.
const ok = !wrong && !mismatches && !badSlot && repaired > 100 && longestLost > 10 && exactFit > 10;
console.log(ok ? '\nok' : '\nFAIL');
process.exit(ok ? 0 : 1);
