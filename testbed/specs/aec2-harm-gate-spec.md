# Work order: AEC2 do-no-harm gate

## The problem this solves

Live iOS finding (room ios-sim-first, 2026-08-11): with NO acoustic echo,
aec-core adapted to spurious correlations, the double-talk detector froze
the junk weights (`adapting:false`), and the output ran ~13 dB LOUDER than
the mic (erleDb −13.16) — the canceller was actively harming audio that had
nothing to cancel. Desktop timing reads ~0 dB in the same situation only by
luck. The lane's law is "never worse than pristine": the canceller may only
SUBTRACT while it is measurably helping.

## File to edit (ONLY this one)

- `core/aec-core.js`

## The change

Add an output harm gate to `process()`:

1. New state near `erleDbEma` (~line 135): `let gateOpen = false` and
   `let gateBlocks = 0`.

2. Where the block's output is written (`out[i] = e[i]` in BOTH the
   double-talk branch and the single-talk branch), route through the gate
   instead: compute the filtered output into `e` exactly as today (the
   filter always LEARNS at full fidelity — adaptation, DTD, delay tracking
   are untouched), but only DELIVER it when the gate is open:

   - Gate OPENS when `erleDbEma !== null && erleDbEma >= 3` (the canceller
     is provably removing ≥3 dB of echo).
   - Gate CLOSES when `erleDbEma !== null && erleDbEma < 1` (hysteresis —
     no flapping at the threshold).
   - While CLOSED: `out[i] = mic[i]` (the pristine input for this block,
     bit-exact — note `mic` must be the untouched input samples, not `e`).

3. Update the stats object (~line 454): add `gate: gateOpen ? 1 : 0` so
   telemetry can say which mode every call ran in.

4. Comment (in the file's voice) explaining WHY: a canceller with nothing
   to cancel can only do harm; measured live on iOS 2026-08-11 at −13 dB.
   The filter keeps learning while gated so the moment real echo appears
   and ERLE climbs, subtraction engages within the EMA's time constant.

## Constraints

- The silent-far bypass (zero-ref → bit-exact) must remain untouched and
  ahead of everything.
- No changes to adaptation, DTD, delay estimation, or the escape valve.
- Style: match the file exactly (no semicolons if the file omits them, same
  comment voice). Nothing outside the blocks above.
