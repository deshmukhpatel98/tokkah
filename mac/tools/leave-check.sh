#!/bin/bash
# ── WHEN SOMEBODY LEAVES, DOES THE WINDOW STOP DESCRIBING THEM? ─────────────
#
# Two things had to be true and only the first one was.
#
#   1. A peer who leaves is DETECTED. That used to be gated on `sawRemote`, the
#      far end's first decoded video frame, so somebody who joined with their
#      camera off could not be detected leaving either -- the call sat on a dead
#      line saying "connected" forever.
#
#   2. Every readout ABOUT them stops. They hold their last value and the report
#      loop republishes them once a second, so after a departure the window said
#
#          the other person left     breaking up     their camera is off
#
#      all at once. Read together that is somebody still on the call with a bad
#      line and their camera off -- the opposite of what happened. A stale fact
#      beside a fresh one is read as current.
#
# The peer here has NO CAMERA, deliberately: that is the case that could not work
# at all before, so a rig using a normal peer would pass over the bug.
#
# ── AND THEN "LEAVING" STOPPED MEANING ONE THING ────────────────────────────
#
# A call is now a fact on disk and it ends for ONE reason: somebody hanging up.
# A process that is killed has not left -- the call is held open and the person
# is told "they'll be right back", because they will. So part one below, which
# kills the peer and its own comment calls "leaving without saying goodbye", now
# asserts the HOLD.
#
# That change alone would have gutted this rig. Held and "the departure detector
# is dead" produce the identical screen, so a build that had forgotten how to
# notice anybody leaving would sail through a rig that only kills processes.
# Part two is therefore a real hang-up -- `leave` twice, which arms the pill and
# then confirms it, the same two events a finger produces -- and it must still
# say they left. One rig, two endings, and neither can be satisfied by the other.
#
# Claim 2 is unchanged and is the reason this file exists: whatever the sentence
# says, every READOUT about them stops. That caught a real bug on the new path --
# `peerHere` deliberately stays true through a hold, so the report loop went on
# republishing "23 ms - breaking up" beside "they'll be right back". A fresh
# sentence next to a stale measurement, which is this rig's whole subject.
set -u
# Ring windows do not throw themselves in front of whatever the person at this
# Mac is doing. That behaviour is right for a phone and is proved in
# firstrun-ring-check; here it only means their taps land on cards they cannot
# see, which made this rig's verdict depend on whether anybody touched the
# trackpad while it ran.
export TK_NO_RAISE=1
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
SP="${SCRATCH:-${TMPDIR:-/tmp}}/leave-check.$$"
mkdir -p "$SP"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
# NO HANDLE AT ALL. `--no-update` no longer disables the identity claim, so
# without this every run of this script would claim a name on the REAL server,
# walking @devesh, @deveshp, @devesh2 ... and squatting names a person may want.
# Pinning `--handle` instead was tried and made this flaky: a first claim is 5-8
# seconds of network and these presses are timed in seconds.
export TK_NO_IDENTITY=1
export TK_KIN_DIR="$SP/kin"
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT

R="lvchk$$"
C="--window --video off --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles"
reap; perl -e 'select undef,undef,undef,0.6'

bad=0
chk() { case "$2" in (*"$3"*) echo "   ok   $1";; (*) echo "  WRONG $1 -- got: $2"; bad=1;; esac; }
audit_of() { grep -oE 'audit state controls.*' "$1" | tail -1; }
field() { sed -E "s/.*  $2=(.*)  $3=.*/\1/" <<< "$1"; }

# ── PART ONE: they vanish, and the call is HELD ─────────────────────────────
echo "── they vanish without hanging up"
spawn "$TK" $C --room "$R" --listen 7551 --peer 127.0.0.1:7552 > "$SP/a.log" 2>&1
A=$LAST_PID
spawn "$TK" $C --room "$R" --listen 7552 --peer 127.0.0.1:7551 --press "?" --press-after 22 > "$SP/b.log" 2>&1
perl -e 'select undef,undef,undef,9'
grep -q "connected via" "$SP/b.log" || { echo "  COULD NOT RUN: the two ends never connected"; exit 2; }
{ kill -9 "$A"; wait "$A"; } 2>/dev/null                     # killed, which is NOT hanging up
perl -e 'select undef,undef,undef,15'
reap; perl -e 'select undef,undef,undef,0.4'

AUDIT="$(audit_of "$SP/b.log")"
[ -n "$AUDIT" ] || { echo "  COULD NOT RUN: no audit line from B"; exit 2; }
STATUS="$(sed -E 's/.*status=(.*)  room=.*/\1/' <<< "$AUDIT")"
QUAL="$(field "$AUDIT" quality warn)"
WARN="$(field "$AUDIT" warn picker)"
chk "a peer who vanished is HELD, not written off" "$STATUS" "right back"
chk "and the app says why, in the log" "$(grep -o 'holding the call open' "$SP/b.log" | tail -1)" "holding the call open"
chk "the link readout stops describing them" "$QUAL" "-"
chk "and so does the camera/microphone banner" "$WARN" "-"

# ── PART TWO: they hang up, and that still ends it ──────────────────────────
#
# The arm that keeps part one honest. `leave` arms the pill, `leave` again
# confirms -- the two events a finger produces. If the departure detector ever
# dies, part one cannot notice (held looks identical) and this must.
echo "── and the same two ends, where one of them actually hangs up"
R2="lvchk$$b"
spawn "$TK" $C --room "$R2" --listen 7553 --peer 127.0.0.1:7554 --press "leave,leave" --press-after 11 > "$SP/c.log" 2>&1
spawn "$TK" $C --room "$R2" --listen 7554 --peer 127.0.0.1:7553 --press "?" --press-after 20 > "$SP/d.log" 2>&1
perl -e 'select undef,undef,undef,9'
grep -q "connected via" "$SP/d.log" || { echo "  COULD NOT RUN: the second pair never connected"; exit 2; }
perl -e 'select undef,undef,undef,13'
reap; perl -e 'select undef,undef,undef,0.4'

# The far end does not survive a hang-up to be photographed: `onPeerBye` ends the
# record, says so, and exits. So the log is the instrument here, not a tree dump
# -- and the third check below is what stops that being a weaker claim, because a
# build that had lost the departure path entirely would take the HELD branch and
# never print any of these lines.
# "heard at all", not "heard exactly once": the bye is announced by the wire and
# again by the call, and pinning the count would make this fail the day a third
# line is added -- a rig that breaks on wording is a rig people start ignoring.
BYE="$(grep -cE "the other end hung up|the other person hung up" "$SP/d.log")"
chk "CONTROL: a real hang-up is heard as a hang-up" \
    "$([ "${BYE:-0}" -ge 1 ] && echo heard || echo silent)" "heard"
chk "and the call record is gone, so nothing will rejoin it" \
    "$(grep -o 'the record is gone, nothing will rejoin' "$SP/d.log" | tail -1)" \
    "the record is gone"
chk "and it is NOT the held path -- the two endings are distinct" \
    "$(grep -c 'holding the call open' "$SP/d.log")" "0"
chk "and the end that hung up went away too" \
    "$(grep -c 'holding the call open' "$SP/c.log")" "0"

[ "$bad" = 0 ] && echo "  LEAVE CHECK PASSED -- a vanished peer is held, a goodbye ends it, and nothing on screen still describes either" \
                || echo "  LEAVE CHECK FAILED"
exit $bad
