# Work order: burst shield — temporal frame duplication at heavy loss

## The problem this solves

The audio lane's parity ladder (RS / sliding-window) tops out around 12–15%
loss. Real calls have gone far beyond that (Aug 7: 49% concealment) — up
there, parity math collapses and the user hears HOLD silence. Audio is cheap
(~0.75 Mbps), so above the ladder's ceiling we can afford brute force: send
every frame TWICE, the twin 3 frames (24 ms) later on a different SCTP
association, so a burst shorter than 24 ms can never kill both copies. The
receiver is already idempotent to duplicate seqs (`noteSeen` re-marks,
`ringWrite` overwrites the same slot, `swDec.frame` is a map insert), so
this is a sender-side feature plus one receiver counter.

## Files to edit (ONLY these two)

- `tape-app/public/pcm.js`
- `tape-app/public/app.js`

Do NOT touch: worklets (`pcm-worklet.js`), `core/*`, parity/FEC logic,
`tape.js`, anything else. No new files.

## Exact changes

### 1. app.js — the flag (one line)

In the `PCM_CFG` object (near line 1564, next to `pcmSw:`), add:

```js
pcmDup: QS.get('pcmdup') ?? undefined, // burst shield: '0' never | '1' always | absent = auto
```

### 2. pcm.js — sender state

Near `const SW = !!cfg.pcmSw;` (~line 680), add a small block:

```js
// ── Burst shield (temporal duplication) ────────────────────────────────────
// Above the parity ladder's top rung, parity math stops paying: at 20%+ loss
// the odds of >n losses in a K-window exceed CONCEAL_TARGET for every n this
// lane can afford. Duplication does not care about loss patterns: the twin
// rides DUP_DELAY_F frames (24 ms) behind the original on a different
// association, so only a burst longer than 24 ms that spans both stripes
// kills a frame twice. Costs one extra audio lane (~0.75 Mbps) ONLY while
// engaged; `?pcmdup=0` never engages it, `?pcmdup=1` engages from the first
// frame, absent = auto on the same loss reads that drive the ladder.
const DUP_MODE = cfg.pcmDup; // '0' | '1' | undefined
let dupOn = DUP_MODE === '1';
let dupLowSince = 0;
const DUP_DELAY_F = 3;
const dupQ = []; // [{seq, msg}] — twin ArrayBuffers awaiting their send turn
```

### 3. pcm.js — stats fields

In the `stats` object initializer (near `aec2: null,` ~line 255), add:

```js
dupOn: 0, dupSent: 0, dupBytes: 0, dupRecv: 0,
```

### 4. pcm.js — auto engage/disengage inside `onPeerLoss` (~line 725)

At the END of `onPeerLoss` (after the existing ladder logic; do not modify
the ladder), add — and note `rungTop` is in scope (defined ~line 700) and
`FEC_N_MAX` is the existing cap used by `rung()`:

```js
// Burst shield engage/disengage. Same asymmetry as the ladder, same reason:
// engaging early costs bytes, disengaging early costs speech. Engage when
// EITHER window reads loss beyond what the max parity rung can hold under
// CONCEAL_TARGET; disengage only after the slow window has read less than
// half that for a continuous 3 s.
if (DUP_MODE === undefined) {
  const cap = rungTop[Math.min(FEC_N_MAX, rungTop.length - 1)];
  if (!dupOn && (fastPct > cap || pct > cap)) {
    dupOn = true; dupLowSince = 0; stats.dupOn = 1;
  } else if (dupOn) {
    if (pct < cap / 2) {
      if (!dupLowSince) dupLowSince = now();
      else if (now() - dupLowSince > 3000) {
        dupOn = false; dupLowSince = 0; stats.dupOn = 0; dupQ.length = 0;
      }
    } else dupLowSince = 0;
  }
}
```

### 5. pcm.js — twin association picker

Next to `pickDataAssoc` (~line 804), add:

```js
// The twin's home is offset half the stripe from the original's: on 6
// associations seq's data rides (seq % 6), its twin (seq+3) % 6 — maximally
// far in the round-robin, so one association's queue trouble cannot hold
// both copies. Falls forward like pickDataAssoc; over-budget everywhere
// drops the TWIN only (the original already went out — the shield is best-
// effort extra, never backpressure).
function pickTwinAssoc(seq) {
  const home = (seq + Math.max(1, PAIRS >> 1)) % PAIRS;
  for (let k = 0; k < PAIRS; k++) {
    const a = assocs[(home + k) % PAIRS];
    if (a.dc?.readyState !== 'open') continue;
    if (a.dc.bufferedAmount <= backlogLimit(a)) return a;
  }
  return null;
}
```

### 6. pcm.js — enqueue + drain in the data-send path

In `onCaptureFrame`'s send tail, immediately AFTER the line
`stats.bytesSent += msg.byteLength;` (~line 1030, the T_DATA/T_DATA_C/
T_DATA_Z `msg` — note `msg` is per-frame and never reused, so holding a
reference is free), add:

```js
// Burst shield: queue this frame's twin, and send the twin whose turn has
// come (DUP_DELAY_F frames of temporal diversity). Draining here — on the
// next frames' sends — needs no timer and dies with the lane.
if (dupOn) dupQ.push({ seq, msg });
while (dupQ.length && seq - dupQ[0].seq >= DUP_DELAY_F) {
  const tw = dupQ.shift();
  const ta = pickTwinAssoc(tw.seq);
  if (!ta) { stats.dupSkipped = (stats.dupSkipped ?? 0) + 1; continue; }
  try { ta.dc.send(tw.msg); } catch { continue; }
  ta.bytesSent += tw.msg.byteLength;
  stats.dupSent++;
  stats.dupBytes += tw.msg.byteLength;
}
```

(Do NOT increment `framesSent` for twins — they are not new frames, and the
loss accounting on the far side keys on seq, not arrival count.)

### 7. pcm.js — receiver counter

In the T_DATA/T_DATA_C/T_DATA_Z receive branch (~line 1461), immediately
BEFORE the existing `noteSeen(seq);` line, add:

```js
// A seq already marked seen is a shield twin whose original made it (or the
// reverse) — counted so telemetry can say how much of the dup spend was
// redundant vs. how much silently replaced a loss.
if (seq <= seenHi && seenHi - seq < SEEN_N && seen[seq % SEEN_N] === 1) stats.dupRecv++;
```

## Style rules (mandatory)

- Comments explain WHY (mechanism/cost), matching the file's voice; no
  "added by", no change-log comments.
- No optional-chaining changes to existing lines; touch nothing outside the
  blocks above.
- Keep exact existing indentation (2 spaces).

## Definition of done

Both files edited exactly as specified, no other diffs.
