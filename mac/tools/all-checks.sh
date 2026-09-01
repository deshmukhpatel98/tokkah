#!/bin/bash
# ── EVERY CHECK, IN LANES, WITHOUT SPOILING ANY OF THEM ──────────────────────
#
#   tools/all-checks.sh            everything (about 30 min, bounded by predict)
#   tools/all-checks.sh fast       everything that can catch a UI or logic change
#   tools/all-checks.sh <names...> just those
#
# Run one after another, the 30 rigs in this directory take about 45 minutes and
# nearly all of that is one process waiting on a fixed sleep while nine CPUs sit
# idle. Run all at once, they ruin each other. So they run in LANES, and which
# lane a rig is in is decided by what it can collide over -- which is the whole
# content of this file:
#
#   TIME      Anything whose verdict is a latency, a percentile, or an audio rate.
#             This lane runs ALONE. Four other builds on the machine cannot
#             flatter a number, but they can certainly spoil one: a 720p call is
#             about 0.16 CPU-seconds per second, and a rig that shares the machine
#             with three others is measuring the machine.
#   LIGHT     Anything that photographs a window or measures light through the
#             material. These run ALONE TOO, and for a sharper reason: every rig
#             parks its window in the same bottom-left corner, so two at once
#             overlap and `glass-measure` would be reading one window's material
#             over another window's picture.
#   STATE     launchd jobs, login items, plists, crash folders. Parallel-safe
#             between themselves ONLY because every one of them labels its job
#             with its own pid -- except the crash folder, which is shared. That
#             is why `crash-check` sits at the end of the LOGIC lane rather than
#             in this one: it PLANTS crash reports, `stress-check`'s last verdict
#             is a delta over that folder, and the two must be serial with respect
#             to each other. Put in the two lanes that run together, stress-check
#             read crash-check's fixtures as its own deaths.
#   LOGIC     Sockets, cards, rows, byes, contacts. These are genuinely
#             independent: distinct ports, distinct scratch, distinct identity
#             directories. This is the lane that parallelises for free.
#
# `fast` drops the two rigs whose cost is a deliberate real-time pass over real
# recordings -- and it SAYS which, because a suite that quietly skips things
# reports the same green as one that ran them.
set -u
cd "$(dirname "$0")/.."
OUT="${OUT:-${TMPDIR:-/tmp}}/all-checks.$$"
mkdir -p "$OUT"
export TK_NO_RAISE=1

# ── THE LANES ────────────────────────────────────────────────────────────────
# Serial lanes, in the order they cost least to most, so a failure in something
# cheap is reported before the expensive one has finished.
LANE_TIME="aec-check mute-check subtitle-check immersive-check floor-check predict-check"
LANE_LIGHT="glass-check home-check ringpicture-check preanswer-check reopen-check"
# Parallel-safe lanes, run two at a time.
LANE_STATE="permissions-check firstrun-ring-check relaunch-check watch-check update-check doorbell-check cancelrace-check"
LANE_LOGIC="invite-check camoff-check calling-check bye-check leave-check contacts-check liveupdate-check controls-check vpause-check stress-check crash-check"

# The two whose whole cost is a real-time pass over real speech. `predict-check`
# feeds 600 s of recording at 1x on purpose -- the recogniser's partials arrive
# about once a second and surviving that staleness IS the thing under test, so
# there is no honest way to hurry it.
SLOW="predict-check floor-check"

MODE="${1:-full}"
case "$MODE" in
  fast)
    shift || true
    for s in $SLOW; do
      LANE_TIME="${LANE_TIME//$s/}"
      LANE_LIGHT="${LANE_LIGHT//$s/}"
    done
    echo "fast: skipping$(printf ' %s' $SLOW) -- their cost is a deliberate 1x pass"
    echo "      over real recordings, so run \`all-checks.sh\` before a release."
    ;;
  full) ;;
  *)
    # An explicit list: one lane, in the order given, so `all-checks.sh a b c`
    # cannot silently reorder or parallelise things the caller wanted serial.
    LANE_TIME="$*"; LANE_LIGHT=""; LANE_STATE=""; LANE_LOGIC=""
    ;;
esac

run_lane() {                     # run_lane <name> <checks...>
  local lane="$1"; shift
  for c in $@; do
    [ -f "tools/$c.sh" ] || { printf '%-24s MISSING\n' "$c" >> "$OUT/$lane.res"; continue; }
    local t0; t0=$(date +%s)
    bash "tools/$c.sh" > "$OUT/$c.txt" 2>&1
    local rc=$?
    local last; last=$(grep -E "PASSED|FAILED|PASS$|FAIL$|COULD NOT RUN" "$OUT/$c.txt" | tail -1 | cut -c1-72)
    printf '%-22s rc=%-3s %4ds  %s\n' "$c" "$rc" "$(( $(date +%s) - t0 ))" "$last" >> "$OUT/$lane.res"
  done
}

# ── IS SOMEBODY USING THIS MAC RIGHT NOW? ────────────────────────────────────
#
# The LIGHT lane photographs windows, and an installed Kin sitting in a real call
# is a full-screen-ish window in front of everything the rig parks at the desktop
# level. `ringpicture-check` correctly refused to report on an occluded window and
# the suite correctly called that a failure -- of a build that was fine, on a Mac
# whose owner was on a call.
#
# Said before anything runs, because it is the difference between a red to
# investigate and a red to ignore, and nobody can tell them apart afterwards.
if pgrep -f "/Applications/Kin.app/Contents/MacOS/Tokkah --room" >/dev/null 2>&1; then
  echo "NOTE: the installed Kin is in a call right now. Its window sits in front of"
  echo "      the ones these rigs park at the desktop level, so anything in the"
  echo "      photography lane may report an occluded window. That is this Mac, not"
  echo "      the build."
fi
echo "logs: $OUT"
# ── PHASE 1: the two independent lanes, together ─────────────────────────────
# Both are socket-and-state work with no timing verdict and no photograph, so
# sharing the machine costs them nothing.
if [ -n "$LANE_STATE$LANE_LOGIC" ]; then
  echo "── phase 1: state + logic, in parallel"
  run_lane state $LANE_STATE &
  P1=$!
  run_lane logic $LANE_LOGIC &
  P2=$!
  wait $P1 $P2 2>/dev/null
  cat "$OUT"/state.res "$OUT"/logic.res 2>/dev/null | sort
fi

# ── PHASE 2: the lanes that must be alone ────────────────────────────────────
if [ -n "$LANE_LIGHT" ]; then
  echo "── phase 2: window photography, alone"
  run_lane light $LANE_LIGHT
  cat "$OUT"/light.res 2>/dev/null
fi
if [ -n "$LANE_TIME" ]; then
  echo "── phase 3: timing, alone"
  run_lane time $LANE_TIME
  cat "$OUT"/time.res 2>/dev/null
fi

BAD=$(grep -hcv 'rc=0' "$OUT"/*.res 2>/dev/null | paste -sd+ - | bc 2>/dev/null || echo 0)
TOTAL=$(cat "$OUT"/*.res 2>/dev/null | wc -l | tr -d ' ')
echo
if [ "${BAD:-1}" = "0" ]; then
  echo "ALL $TOTAL CHECKS PASSED"
else
  echo "$BAD of $TOTAL CHECKS DID NOT PASS:"
  grep -hv 'rc=0' "$OUT"/*.res 2>/dev/null | sed 's/^/  /'
fi
exit "${BAD:-1}"
