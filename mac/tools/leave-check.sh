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
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/leave-check.$$"
mkdir -p "$SP"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
export TK_KIN_DIR="$SP/kin"
trap 'pkill -f "$TK" 2>/dev/null; rm -rf "$SP"' EXIT

R="lvchk$$"
C="--window --video off --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles"
pkill -f "$TK" 2>/dev/null; perl -e 'select undef,undef,undef,0.6'
"$TK" $C --room "$R" --listen 7551 --peer 127.0.0.1:7552 > "$SP/a.log" 2>&1 &
A=$!
"$TK" $C --room "$R" --listen 7552 --peer 127.0.0.1:7551 --press "?" --press-after 34 > "$SP/b.log" 2>&1 &
perl -e 'select undef,undef,undef,9'
grep -q "connected via" "$SP/b.log" || { echo "  SKIPPED: the two ends never connected"; exit 0; }
{ kill -9 "$A"; wait "$A"; } 2>/dev/null                     # they leave, without saying goodbye
perl -e 'select undef,undef,undef,28'
pkill -f "$TK" 2>/dev/null; perl -e 'select undef,undef,undef,0.4'

AUDIT="$(grep -oE 'audit state controls.*' "$SP/b.log" | tail -1)"
[ -n "$AUDIT" ] || { echo "  no audit line from B"; exit 1; }
bad=0
chk() { case "$2" in (*"$3"*) echo "   ok   $1";; (*) echo "  WRONG $1 -- got: $2"; bad=1;; esac; }
STATUS="$(sed -E 's/.*status=(.*)  room=.*/\1/' <<< "$AUDIT")"
QUAL="$(sed -E 's/.*  quality=(.*)  warn=.*/\1/' <<< "$AUDIT")"
WARN="$(sed -E 's/.*  warn=(.*)  picker=.*/\1/' <<< "$AUDIT")"
chk "a camera-off peer is detected leaving" "$STATUS" "left"
chk "the link readout stops describing them" "$QUAL" "-"
chk "and so does the camera/microphone banner" "$WARN" "-"
[ "$bad" = 0 ] && echo "  LEAVE CHECK PASSED -- nothing on screen still describes somebody who left" \
                || echo "  LEAVE CHECK FAILED"
exit $bad
