#!/bin/bash
# ── DOES THE TURN PREDICTION DO ANYTHING ON A REAL CALL? ─────────────────────
#
# `Predict.swift` scores how likely it is that the person talking is about to
# finish, from the recogniser's partial text and the shape of their voice. Both
# halves have been wired since 0.92/0.93:
#
#   LOCAL  this Mac's floor reads `Audio.turnEndProb` and lets go of a floor it
#          already holds, before the silence that would have proved the turn ended.
#   FAR    the same number is packed into TPKTX+7 and read by the OTHER end's
#          floor, so the listener's microphone is already open when the talker
#          stops. This is the half that matters: it is the only mechanism in the
#          app that can make a handover cost nothing instead of a release window.
#
# And until this rig, nothing had ever measured either half ON A CALL. Everything
# that existed tested the PREDICTOR -- `predict-check` feeds recordings through
# the scorer in one process -- or the floor's logic with `--mute` and no speech at
# all. The counters fired in production, the numbers went into every beat, and
# there was no comparison anywhere: "handed over early 6 times, saving 1400 ms" is
# a number with nothing to divide by. A feature nobody has A/B'd is a feature
# nobody has shown to work (`feature-behind-a-flag-nobody-runs`).
#
# Two ends, two real recordings of real speech through `--audio` (which replaces
# the microphone on a LIVE call, so this is the production audio path, the
# production wire and the production floor), and the same call twice:
#
#   A  default. The prior fires.
#   B  `--no-predict` at both ends. The prior is computed, still crosses the wire,
#      and nothing acts on it.
#
# The control is not a blind arm: `their p peaked` must be high in BOTH, which is
# what proves --no-predict switches off the ACTION and not the MEASUREMENT. A
# control that silenced the predictor as well would make arm B pass for the wrong
# reason and this whole rig meaningless.
set -u
cd "$(dirname "$0")/.."
TK="${TK:-./.build/release/tk}"
[ -x "$TK" ] || { echo "PREDICT-LIVE CHECK COULD NOT RUN -- no tk at $TK"; exit 2; }
MEDIA=""
for d in ../testbed/media/real ../testbed/peer/media testbed/media/real; do
  [ -f "$d/realA.wav" ] && { MEDIA="$d"; break; }
done
[ -n "$MEDIA" ] || { echo "PREDICT-LIVE CHECK COULD NOT RUN -- no realA.wav under testbed/"; exit 2; }
SP="$(mktemp -d)"
PIDS=""
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT
export TK_NO_RAISE=1 TK_NO_IDENTITY=1
echo "scratch: $SP   media: $MEDIA"
fail=0
say() { printf '  %-5s %s\n' "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }
nap() { perl -e "select undef,undef,undef,$1"; }

# 40 s of the recordings: `realA.wav` and `realB.wav` are two sides of a real
# conversation, so the turn ends are where a person actually took a turn.
TALK="${TALK:-40}"

arm() {                              # arm <label> <extra flags...>
  local label="$1"; shift
  local R="pl$$$label"
  reap; nap 0.5
  "$TK" --window --video off --audio "$MEDIA/realA.wav" --no-telemetry --no-update \
        --no-relocate --no-rings --room "$R" --listen 8161 --peer 127.0.0.1:8162 "$@" \
        > "$SP/$label-a.log" 2>&1 &
  PIDS="$PIDS $!"
  "$TK" --window --video off --audio "$MEDIA/realB.wav" --no-telemetry --no-update \
        --no-relocate --no-rings --room "$R" --listen 8162 --peer 127.0.0.1:8161 "$@" \
        > "$SP/$label-b.log" 2>&1 &
  PIDS="$PIDS $!"
  # WAIT FOR MEDIA, not for a clock: a call that never connected produces zero
  # handovers and would read exactly like a prediction that never fired.
  local w=0 v=0
  while [ "$w" -lt 120 ]; do
    v="$(grep -oE 'recv [0-9]+/s' "$SP/$label-a.log" | tail -1 | grep -oE '[0-9]+')"
    [ "${v:-0}" -gt 500 ] && break
    nap 0.5; w=$(( w + 1 ))
  done
  if [ "${v:-0}" -le 500 ]; then
    echo "  PREDICT-LIVE CHECK COULD NOT RUN -- arm $label never got a call"
    echo "  (recv ${v:-0}/s), so nothing after it is about the prediction."; exit 2
  fi
  say note "arm $label: connected at ${v}/s, talking for ${TALK}s"
  nap "$TALK"
  reap
}

# The per-call line, which the app prints on the way out:
#   handed over early 5 time(s), saving 2230 ms (far 5 / 2230 ms, their p peaked 0.96)
early() { grep -oE "handed over early [0-9]+" "$1" | tail -1 | grep -oE "[0-9]+"; }
far()   { grep -oE "far [0-9]+ / [0-9.]+ ms" "$1" | tail -1 | grep -oE "^far [0-9]+" | grep -oE "[0-9]+"; }
saved() { grep -oE "far [0-9]+ / [0-9.]+ ms" "$1" | tail -1 | sed -E 's|.*/ ([0-9.]+) ms|\1|'; }
peak()  { grep -oE "their p peaked [0-9.]+" "$1" | tail -1 | grep -oE "[0-9.]+"; }

# ══ A: THE PREDICTION AS IT SHIPS ═══════════════════════════════════════════
echo "── A. the prior fires (as shipped)"
arm on
A_FAR_A="$(far "$SP/on-a.log")"; A_FAR_B="$(far "$SP/on-b.log")"
A_SAV_A="$(saved "$SP/on-a.log")"; A_SAV_B="$(saved "$SP/on-b.log")"
A_PK_A="$(peak "$SP/on-a.log")"; A_PK_B="$(peak "$SP/on-b.log")"
A_FAR_TOTAL=$(( ${A_FAR_A:-0} + ${A_FAR_B:-0} ))
A_SAV_TOTAL="$(python3 -c "print(f'{${A_SAV_A:-0} + ${A_SAV_B:-0}:.0f}')")"
if [ "$A_FAR_TOTAL" -gt 0 ]; then
  say OK "the far end's prior released the floor early $A_FAR_TOTAL time(s), saving ${A_SAV_TOTAL} ms"
  say note "  (A: ${A_FAR_A:-0} / ${A_SAV_A:-0} ms, peak p ${A_PK_A:-0} · B: ${A_FAR_B:-0} / ${A_SAV_B:-0} ms, peak p ${A_PK_B:-0})"
else
  say FAIL "the prior never released a floor on a real call. Both halves are wired"
  say FAIL "  (Floor.swift reads farEndProb at three sites), so either the prior did"
  say FAIL "  not cross the wire or nothing acts on it: peak p A ${A_PK_A:-0} B ${A_PK_B:-0}"
fi
# The saving has to be worth having. A release window is ~400 ms, so a handover
# that saves 20 ms is a rounding error dressed as a feature.
python3 -c "import sys; sys.exit(0 if ${A_SAV_TOTAL:-0} >= 200 else 1)" \
  && say OK "and the time saved is worth having (${A_SAV_TOTAL} ms over ${TALK}s of talk)" \
  || say FAIL "only ${A_SAV_TOTAL} ms saved -- a release window is about 400 ms, so this is noise"

# ══ B: THE CONTROL ══════════════════════════════════════════════════════════
echo "── B. CONTROL: the same call with --no-predict"
arm off --no-predict
B_FAR=$(( $(far "$SP/off-a.log" || echo 0) + $(far "$SP/off-b.log" || echo 0) ))
B_PK_A="$(peak "$SP/off-a.log")"; B_PK_B="$(peak "$SP/off-b.log")"
[ "${B_FAR:-1}" = "0" ] \
  && say OK "with the prior off, nothing handed over early -- so arm A measured the prior" \
  || say FAIL "$B_FAR early handovers with --no-predict: the switch does not switch it off"
# AND THE CONTROL IS NOT BLIND. The predictor must still be running and the number
# must still be crossing the wire; only the action is suppressed. Without this,
# arm B would pass on a build where the recogniser had simply stopped.
python3 -c "import sys; sys.exit(0 if max(${B_PK_A:-0}, ${B_PK_B:-0}) >= 0.5 else 1)" \
  && say OK "and the prior still crossed the wire (peak p $(python3 -c "print(max(${B_PK_A:-0}, ${B_PK_B:-0}))")) -- the control switches off the ACTION, not the measurement" \
  || { say FAIL "the control arm saw no prior at all (peak p A ${B_PK_A:-0} B ${B_PK_B:-0}),"
       say FAIL "  so it proves nothing: a predictor that stopped looks the same."; }

[ "$fail" = 0 ] && echo "PREDICT-LIVE CHECK PASSED -- on a real call, the far end's turn-end prior opens
                        the listener's microphone early, and turning it off removes exactly that" \
                || echo "PREDICT-LIVE CHECK FAILED"
exit $fail
