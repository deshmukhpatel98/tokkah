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
# ── KILLS ONLY WHAT THIS SCRIPT STARTED ─────────────────────────────────────
#
# This used to `pkill -f "$TK"`, and `pkill -f` takes a REGEX: in a path like
# `./.build/debug/tk` every `.` matches any character, so the pattern also matched
# `/Users/.../worktrees/agent-XXXX/mac/.build/debug/tk`. It was reaping another
# agent's processes in another checkout and corrupting their measurements from the
# outside -- the exact thing lane isolation is supposed to prevent.
#
# PIDs, therefore. A rig may only end processes it started.
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/firstrun-ring.$$"
mkdir -p "$SP"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
trap 'reap; rm -rf "$SP"' EXIT

# An isolated identity dir AND a rig handle, so this never touches the handle the
# person at this Mac actually uses, and never squats a real-looking name.
export TK_KIN_DIR="$SP/kin"
H="kinrig$$"
ARGS="--window --video off --mute --no-telemetry --no-update --no-relocate --no-subtitles"
bad=0

run() { # log, extra args
  spawn "$TK" $ARGS --room "frcheck$$" --listen "$2" $3 > "$1" 2>&1
  perl -e "select undef,undef,undef,$4"
  reap; perl -e 'select undef,undef,undef,0.4'
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

# ── AND CAN A BRAND-NEW USER PLACE ONE? ─────────────────────────────────────
#
# The mirror of the bug above, found while measuring ring latency on production.
# `Identity.ring` refused outright unless a handle was already claimed, and a
# first install spends 5-8 seconds walking @devesh, @deveshp, @devesh2 ... before
# it owns one. So: launch Kin, type a friend's name, press call -- and the first
# thing the app ever does is fail. A one-shot read of a value that arrives later,
# exactly like the doorbell above it.
export TK_KIN_DIR="$SP/kin-caller"
rm -rf "$TK_KIN_DIR"
# `--mute` here too, and not because this line plays call audio. A ring is a
# SOUND, and it is the one sound `--mute` was found not to be covering: rigs
# rang out loud at the person sitting in front of this Mac. Every launch in
# this file carries it through $ARGS; this one was assembled by hand and did
# not, which is exactly how the gap gets back in.
if "$TK" --mute --handle "kinrigcall$$" --ring-only "kinrig-nobody-$$" > "$SP/c.log" 2>&1; then
  : # a ring to a handle nobody owns should NOT succeed
fi
if grep -q "this Mac has no handle yet" "$SP/c.log"; then
  echo "  WRONG a fresh install cannot place a call at all"
  bad=1
else
  echo "   ok   a fresh install gets a name before it needs one"
fi

[ "$bad" = 0 ] && echo "  FIRST-RUN RING CHECK PASSED -- a new user is reachable without restarting Kin" \
                || echo "  FIRST-RUN RING CHECK FAILED"
exit $bad
