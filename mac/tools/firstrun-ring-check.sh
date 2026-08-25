#!/bin/bash
# ── CAN A BRAND-NEW USER BE RUNG? ───────────────────────────────────────────
#
# Claiming a handle is a network round trip, and on a first install it is
# SEVERAL -- the obvious names are taken and it walks down the list, which took
# 5-8 seconds every time it was measured here. The doorbell used to be started by
# a single `if Identity.claimed` in top-level code that runs long before any of
# that finishes, so on a fresh install it read false and the poll thread never
# started. You claim a name, you tell somebody, and you cannot be rung until you
# quit and reopen Kin. First run is exactly when a person tries this.
#
# Both launches are checked, because either alone is passable by a broken build:
#   fresh   -- the handle is won WHILE running, so the late edge must fire
#   second  -- the handle is on disk, so the early edge must fire
#
# Windowed on purpose. `Identity.onClaimed` is delivered on the main queue, so
# without a run loop it cannot fire at all -- a headless run of this test reports
# a failure that is its own, not the app's (`blind-instruments-report-negatives`).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/firstrun-ring.$$"
mkdir -p "$SP"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
trap 'pkill -f "$TK" 2>/dev/null; rm -rf "$SP"' EXIT

# An isolated identity dir AND a rig handle, so this never touches the handle the
# person at this Mac actually uses, and never squats a real-looking name.
export TK_KIN_DIR="$SP/kin"
H="kinrig$$"
ARGS="--window --video off --mute --no-telemetry --no-update --no-relocate --no-subtitles"
bad=0

run() { # log, extra args
  "$TK" $ARGS --room "frcheck$$" --listen "$2" $3 > "$1" 2>&1 &
  perl -e "select undef,undef,undef,$4"
  pkill -f "$TK" 2>/dev/null; wait 2>/dev/null; perl -e 'select undef,undef,undef,0.4'
}

run "$SP/a.log" 7451 "--handle $H" 20
CLAIM="$(grep -n 'identity: you are' "$SP/a.log" | head -1 | cut -d: -f1)"
LISTEN="$(grep -n 'ring: listening' "$SP/a.log" | head -1 | cut -d: -f1)"
if [ -z "$CLAIM" ]; then
  echo "  SKIPPED: no handle was claimed (offline?) -- this test needs the real server"
  exit 0
fi
if [ -n "$LISTEN" ] && [ "$LISTEN" -gt "$CLAIM" ]; then
  echo "   ok   fresh install: doorbell starts when the handle is won (line $CLAIM -> $LISTEN)"
else
  echo "  WRONG fresh install: handle won at line $CLAIM, doorbell never started"
  bad=1
fi

run "$SP/b.log" 7452 "" 9
if grep -q 'ring: listening' "$SP/b.log"; then
  echo "   ok   second launch: doorbell starts from the handle on disk"
else
  echo "  WRONG second launch: a handle was on disk and the doorbell still did not start"
  bad=1
fi
# One thread, not two. Both edges fire on a second launch if the latch is wrong,
# and two pollers on one mailbox take turns losing rings to each other.
N="$(grep -c 'ring: listening' "$SP/b.log")"
if [ "$N" = 1 ]; then echo "   ok   and exactly one poll thread ($N)"
else echo "  WRONG $N doorbell threads -- they will steal rings from each other"; bad=1; fi

[ "$bad" = 0 ] && echo "  FIRST-RUN RING CHECK PASSED -- a new user is reachable without restarting Kin" \
                || echo "  FIRST-RUN RING CHECK FAILED"
exit $bad
