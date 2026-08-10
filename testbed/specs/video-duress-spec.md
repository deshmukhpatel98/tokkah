# Work order: video duress coupling — video ducks when the audio lane is in trouble

## The problem this solves

On the Aug 7 call the video lane discovered heavy loss on its own, slowly,
via a GCC estimate that was frozen — and spiraled into stall-HOLD while the
audio lane's loss ladder had known the truth for seconds. The audio lane now
also runs the burst shield (`dupOn`), which is the single strongest "this
network is drowning" signal we have. Couple them: when the audio lane reads
duress, the video budget ducks IMMEDIATELY — smaller frames, still moving —
instead of waiting to fail. Audio is the call; video yields first.

## Files to edit (ONLY these three)

- `tape-app/public/pcm.js` — expose `duress()` on the lane's API
- `tape-app/public/tape.js` — consume it in `rcPollBudget()`
- `tape-app/public/app.js` — wire them, one flag

Do NOT touch: worklets, `core/*`, the FEC/ladder/shield logic itself, any
other function in these files. No new files.

## Exact changes

### 1. pcm.js — duress() in the returned API

In the object returned by `initPcmAudio` (the `return {` near line 2270,
the one whose first field is `stats,`), add directly after `stats,` and
`mode,`:

```js
// The one-word answer to "how bad is my network right now", for consumers
// that must react faster than their own signals allow (the video lane's GCC
// estimate froze solid on the Aug 7 call while this lane's ladder read the
// loss within 250 ms). 2 = burst shield engaged (loss beyond the ladder's
// top rung); 1 = loss in the ladder's upper half; 0 = fine. Reads live
// state, never computes — safe at any call rate.
duress() {
  if (stats.dupOn) return 2;
  const cap = rungTop[Math.min(FEC_N_MAX, rungTop.length - 1)];
  return (stats.peerLossPct > cap / 2 || stats.peerLossFastPct > cap) ? 1 : 0;
},
```

Note `rungTop` and `FEC_N_MAX` are already in scope inside `initPcmAudio`.

### 2. tape.js — consume in startTapeRtp

a. Add `duress = null` to `startTapeRtp`'s destructured parameters
   (line ~1454: `export function startTapeRtp({ pc, track, initiator, pre,
   cfg, onRemote, log, onFail, displayCanvas, avsync = null, onStall =
   null })` — append `, duress = null` before the closing brace).

b. In the `stats` initializer field list where `rcQp: null, rcBudgetMbps:
   null` live (~line 1486), add `rcDuress: 0,` alongside them.

c. In `rcPollBudget()` (~line 1653), immediately AFTER the line
   `stats.rcEstMbps = est != null ? +(est / 1e6).toFixed(2) : null;` and
   BEFORE `rcVbrRetune();`, add:

```js
// Audio-lane duress overrides the estimate: GCC is exactly the instrument
// that failed on the Aug 7 call (froze at 37 Mbps on a drowning 4G link),
// while the audio ladder read the loss within 250 ms. Duress 2 (burst
// shield engaged) quarters the budget, 1 halves it — smaller frames that
// MOVE beat pristine frames that never arrive. The clamp floor keeps the
// encoder alive; recovery is automatic the moment duress reads 0.
const dd = duress?.() ?? 0;
if (dd) rcBudgetMbps = rcClamp(rcBudgetMbps * (dd === 2 ? 0.25 : 0.5), cfg.l2RcMinMbps, cfg.l2RcMaxMbps);
if (dd !== stats.rcDuress) log?.('rc-duress', { level: dd, budgetMbps: +rcBudgetMbps.toFixed(2) });
stats.rcDuress = dd;
stats.rcBudgetMbps = +rcBudgetMbps.toFixed(2);
```

### 3. app.js — wiring and flag

a. In `PCM_CFG` (near `pcmDup:` ~line 1565), no change needed.

b. Near the other lane-2 query flags — find `const TAPE` definition region —
   add at the module level right BEFORE the `const common = {` object
   (~line 1951) is simplest NOT: instead add the flag next to PCM_CFG
   (~line 1571, after `pcmDup` line):

```js
const L2_DURESS = QS.get('l2duress') !== '0'; // video ducks on audio-lane duress; `?l2duress=0` control
```

Place it OUTSIDE the PCM_CFG object literal, as its own `const` right after
the PCM_CFG closing `};`.

c. In the `common` object passed to the tape lanes (~line 1951), add after
   the `onFail:` field:

```js
// The audio lane's loss ladder is the fastest honest congestion signal in
// the app; the video budget listens to it (see rcPollBudget). Null keeps
// the old behaviour byte-for-byte.
duress: L2_DURESS ? () => pcm?.duress?.() ?? 0 : null,
```

## Style rules (mandatory)

- Comments explain WHY, matching each file's voice. No change-log comments.
- Touch nothing outside the blocks above. Keep 2-space indentation.

## Definition of done

Three files edited exactly as specified, no other diffs.
