#!/bin/bash
# ── DOES A CALL WITH SOMEBODY WHOSE CAMERA IS OFF LOOK LIKE A CALL? ──────────
#
# Two real processes, real UDP, real media. One of them has no camera at all.
#
# This exists because presence used to be keyed on the far end's first decoded
# VIDEO FRAME, so a person who joined with their camera off was, to this app,
# a person who never arrived. Measured before the fix: 59,574 audio frames
# played, session encrypted, their turn cue drawing -- and the window still
# showing "Waiting for the other person..." with the invite link over the top,
# for the whole call. Turning your camera off is an ordinary thing to do.
#
# Both halves are asserted, because either alone is passable by a broken build:
# the call must say CONNECTED, and it must say WHY there is no picture. A build
# that connects and explains nothing is the same silence in a new place.
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
SP="${SCRATCH:-${TMPDIR:-/tmp}}/camoff-check.$$"
mkdir -p "$SP"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
trap 'reap; rm -rf "$SP"' EXIT

R="camoffchk$$"
# --mute on both ends, always: the machine's speakers belong to whoever is
# sitting at it, and a rig that plays out loud gets turned off.
A_ARGS="--mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles"
reap; perl -e 'select undef,undef,undef,0.6'
# A HAS NO CAMERA. This is the whole subject.
spawn "$TK" --room "$R" --listen 7911 --peer 127.0.0.1:7912 --video off $A_ARGS > "$SP/a.log" 2>&1
# B is watching, and B's window is what gets inspected.
spawn "$TK" --window --room "$R" --listen 7912 --peer 127.0.0.1:7911 --video off $A_ARGS \
      --press "?" --press-after 9 > "$SP/b.log" 2>&1
perl -e 'select undef,undef,undef,12'
reap; perl -e 'select undef,undef,undef,0.4'

AUDIT="$(grep -oE 'audit state controls.*' "$SP/b.log" | head -1)"
[ -n "$AUDIT" ] || { echo "  no audit line -- B never opened a window"; sed -n '1,20p' "$SP/b.log"; exit 1; }
bad=0
say() { # label, got, want-substring
  case "$2" in (*"$3"*) echo "   ok   $1: $2";; (*) echo "  WRONG $1: $2  (want $3)"; bad=1;; esac
}
# ── THE DELIMITER MOVED, AND THIS DID NOT NOTICE ────────────────────────────
# `room=` was a dead field -- built, laid out, never given a string -- and it is
# now `who=`, the name and clock of whoever is on the call. This sed kept the old
# delimiter, stopped matching, and handed the WHOLE audit line to a `case` looking
# for "connected" somewhere in it. It passed, and it would have passed on a build
# with no status pill at all. Anchored on a field that carries something now.
STATUS="$(sed -E 's/.*status=(.*)  who=.*/\1/' <<< "$AUDIT")"
# ── ONE FIELD, NOT EVERYTHING UP TO A NAMED NEIGHBOUR ───────────────────────
#
# These were `sed -E 's/.*  warn=(.*)  card=.*/\1/'` -- greedy, and anchored on
# whichever field happened to come next in the state dump. The moment a new field
# was added between them (`trouble=`, which belongs beside `warn=`: they are two
# sentences for one pill) this captured "-  trouble=-" and the arm reported that
# the pill was saying something twice. A true statement about a screen that was
# perfectly correct, from a pattern that had quietly encoded the ORDER of a dump
# it does not own.
#
# Non-greedy, and terminated by "any next key", so adding to the dump cannot
# break it again. sed has no non-greedy quantifier; perl does.
WARN="$(perl -pe 's/.*  warn=(.*?)  \w+=.*/$1/' <<< "$AUDIT")"
POSTER="$(perl -pe 's/.*  poster=(.*?)  \w+=.*/$1/' <<< "$AUDIT")"
say "the call says it is connected" "$STATUS" "connected"
# ── AND IT SAYS IT WHERE A PERSON IS LOOKING ────────────────────────────────
# The pill was the whole of what a camera-off call said, at 12 pt, in a corner,
# fading with the control row: a working call was a black rectangle. The face and
# the name in the middle are what a person actually sees, so that is what is
# asserted -- and the pill must NOT repeat it, or the app says one thing twice.
say "and puts their face and the reason in the middle" "$POSTER" "Camera off"
say "and the pill does not say it a second time" "[$WARN]" "[-]"
# The pair: the far end really was heard, or "connected" is a label over nothing.
PLAYED="$(grep -oE 'played [0-9]+' "$SP/b.log" | tail -1 | awk '{print $2}')"
if [ "${PLAYED:-0}" -gt 1000 ]; then echo "   ok   and their audio arrived: $PLAYED frames"
else echo "  WRONG their audio never arrived: ${PLAYED:-0} frames"; bad=1; fi

# And the window is not left holding a frozen frame of YOU while a banner above
# it says "their camera is off" -- which reads as them, stopped.
if grep -q 'clearing the mirror' "$SP/b.log"; then
  echo "   ok   and the window is not a frozen mirror of yourself"
else
  echo "  WRONG the window kept your own last frame under \"their camera is off\""; bad=1
fi

[ "$bad" = 0 ] && echo "  CAMERA-OFF CHECK PASSED -- a call with no picture is still visibly a call" \
                || echo "  CAMERA-OFF CHECK FAILED"
exit $bad
