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
# ── WHAT A CLEAN RUN MEASURED, AND WHERE THE FIRST DRAFT WAS WRONG ───────────
#
# The first version of this file put `vpause-check`, `stress-check` and
# `bye-check` in the parallel LOGIC lane on the reasoning that they are "sockets
# and cards". All three failed, and every failure was the machine rather than the
# build:
#
#     stress-check   capture ended at 552/s -- a swap left the graph dead
#                    (idle: 1515/s. The graph was fine.)
#     vpause-check   the control arm never paused
#                    (its ceiling was calibrated on an idle Mac)
#     bye-check      a stranger's bye changed this call: <empty audit line>
#                    (the press had not landed yet)
#
# So the rule is not "does it use sockets", it is WHAT THE ASSERTION IS MADE OF.
# Anything whose verdict is a rate, a percentile, a latency or a per-second count
# is measuring the machine as much as the build, and belongs alone.
# `recover-check` verdicts are packets and playout per second, so it belongs here
# and not in the parallel lane -- and it was in NO lane at all until this line:
# written, passing, and run by nobody. `unrun-tests-are-not-coverage`.
LANE_TIME="aec-check mute-check subtitle-check immersive-check vpause-check stress-check bye-check recover-check floor-check"
LANE_LIGHT="glass-check home-check ringpicture-check preanswer-check reopen-check"
# ── AND ONE LANE THAT LOAD CANNOT FLATTER ───────────────────────────────────
#
# `predict-check` is twenty minutes of real speech at 1x and it was in the
# exclusive lane, which put its twenty minutes on the critical path. Its own
# comment is the reason it does not have to be: "under load the feed loop can only
# slip LATE, which makes the text staler and the test harder, so three other
# builds running on this machine cannot flatter the number." A rig that can only
# be made harder by company is a rig that can keep company.
LANE_SLOW="predict-check"
# Parallel-safe lanes.
LANE_STATE="permissions-check firstrun-ring-check relaunch-check watch-check update-check doorbell-check cancelrace-check"
LANE_LOGIC="invite-check camoff-check calling-check leave-check contacts-check liveupdate-check controls-check beat-check crash-check seal-check"

# The two whose whole cost is a real-time pass over real speech. `predict-check`
# feeds 600 s of recording at 1x on purpose -- the recogniser's partials arrive
# about once a second and surviving that staleness IS the thing under test, so
# there is no honest way to hurry it.
# The three that cost minutes rather than seconds. `fast` drops them and names
# them; `full` is what runs before a release.
SLOW="predict-check floor-check update-check"

MODE="${1:-full}"
case "$MODE" in
  fast)
    shift || true
    # ── DROP WHOLE NAMES, NOT SUBSTRINGS ────────────────────────────────────
    #
    # `${LANE_LOGIC//update-check/}` turned `liveupdate-check` into `live`, and the
    # runner then reported `live  MISSING` -- a rig silently removed from the suite
    # by a string substitution that matched inside another rig's name. Sibling of
    # `pkill -f is a regex`: a pattern applied to a list of words has to be applied
    # a word at a time.
    drop_from() {                    # drop_from <lane> ; echoes the lane without $SLOW
      local out=""
      for c in $1; do
        local skip=""
        for s in $SLOW; do [ "$c" = "$s" ] && skip=1; done
        [ -n "$skip" ] || out="$out $c"
      done
      echo "$out"
    }
    LANE_TIME="$(drop_from "$LANE_TIME")"
    LANE_LIGHT="$(drop_from "$LANE_LIGHT")"
    LANE_STATE="$(drop_from "$LANE_STATE")"
    LANE_LOGIC="$(drop_from "$LANE_LOGIC")"
    LANE_SLOW="$(drop_from "$LANE_SLOW")"
    echo "fast: skipping$(printf ' %s' $SLOW) -- their cost is a deliberate 1x pass"
    echo "      over real recordings, so run \`all-checks.sh\` before a release."
    ;;
  full) ;;
  *)
    # An explicit list: one lane, in the order given, so `all-checks.sh a b c`
    # cannot silently reorder or parallelise things the caller wanted serial.
    LANE_TIME="$*"; LANE_LIGHT=""; LANE_STATE=""; LANE_LOGIC=""; LANE_SLOW=""
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
# ANY window, not only a call. The first version of this looked for `--room`, and
# the front door occludes exactly as well as a call does: `ringpicture-check`
# reported "the window was occluded -- nobody could have seen it" with the
# installed Kin sitting on its home screen. A rig that photographs windows cannot
# be trusted while another copy of the app has one.
# ── AND WHAT ARE THEY TESTING? ───────────────────────────────────────────────
#
# This runner never built anything. It ran 29 rigs against whatever binaries
# happened to be in `.build`, and there are TWO of them: 23 of the rigs default to
# `.build/debug/tk` and 7 to `.build/release/tk`. A session that builds only
# release therefore runs two thirds of the suite against the LAST RELEASE'S CODE,
# and every one of those rigs reports PASS about a build that does not contain the
# change under test.
#
# Measured, in the run that found this: `update-check` refused with "the repo
# binary reports 0.118.0, not 0.119.0" -- the only rig that compares the two --
# while `doorbell-check` rebuilt the debug binary half way through the same run,
# so rigs before it and rigs after it were testing different code. A suite that
# cannot say which build it exercised has no verdict to give.
#
# So both are built here, once, before any lane starts, and the versions are
# printed. Nothing after this point touches the tree -- that is the other half of
# the rule, and the reason this is the only build in the file.
echo "== building both binaries (23 rigs use debug, 7 use release) =="
BUILD_LOG="$OUT/build.log"
if ! swift build -c release --product tk > "$BUILD_LOG" 2>&1; then
  echo "RELEASE BUILD FAILED -- nothing below would mean anything:"; tail -20 "$BUILD_LOG"; exit 1
fi
if ! swift build --product tk >> "$BUILD_LOG" 2>&1; then
  echo "DEBUG BUILD FAILED -- nothing below would mean anything:"; tail -20 "$BUILD_LOG"; exit 1
fi
RV="$(./.build/release/tk --version 2>/dev/null)"
DV="$(./.build/debug/tk --version 2>/dev/null)"
echo "   release $RV   debug $DV"
[ -n "$RV" ] && [ "$RV" = "$DV" ] \
  || { echo "THE TWO BINARIES DISAGREE ($RV vs $DV) -- refusing to run a suite"
       echo "that would report on two different builds."; exit 1; }

if pgrep -f "/Applications/Kin.app/Contents/MacOS/Tokkah" | grep -qv "^$$" 2>/dev/null \
   && pgrep -fl "/Applications/Kin.app/Contents/MacOS/Tokkah" | grep -qv -- "--watch"; then
  echo "NOTE: the installed Kin is open right now (a call or its home screen). Its"
  echo "      window sits in front of the ones these rigs park at the desktop level,"
  echo "      so anything in the photography lane may report an occluded window."
  echo "      That is this Mac, not the build."
  # AND THE WATCHER LANE, for a different reason: a Kin that is open holds the
  # ring line, so a rig watcher correctly stands down ("Kin is open and listening
  # for calls itself") and never opens the copy its arm is about. Measured:
  # `cancelrace-check` reporting "the watcher never opened Kin" on a Mac whose
  # owner had the app on screen.
  echo "      cancelrace-check and doorbell-check may also report COULD NOT RUN:"
  echo "      an open Kin holds the ring line, so a rig watcher stands down by design."
fi
echo "logs: $OUT"
# ── PHASE 1: the two independent lanes, together ─────────────────────────────
# Both are socket-and-state work with no timing verdict and no photograph, so
# sharing the machine costs them nothing.
if [ -n "$LANE_STATE$LANE_LOGIC$LANE_SLOW" ]; then
  echo "── phase 1: slow + state + logic, in parallel"
  PP=""
  [ -n "$LANE_SLOW" ]  && { run_lane slow  $LANE_SLOW  & PP="$PP $!"; }
  [ -n "$LANE_STATE" ] && { run_lane state $LANE_STATE & PP="$PP $!"; }
  [ -n "$LANE_LOGIC" ] && { run_lane logic $LANE_LOGIC & PP="$PP $!"; }
  # shellcheck disable=SC2086
  wait $PP 2>/dev/null
  cat "$OUT"/slow.res "$OUT"/state.res "$OUT"/logic.res 2>/dev/null | sort
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
