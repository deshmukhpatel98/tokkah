#!/bin/bash
# ── A DOCK CLICK MUST OPEN A WINDOW, EVEN WHEN THE RECORD IS A GHOST ────────
#
# 0.75.2 taught the resident to ask "is Kin already open?" before answering a
# reopen, because without that question every Dock click was a new copy of the
# app. 0.76.0 then answered six clicks in a row with
#
#     watch: somebody opened Kin -- handing it to a new process
#     watch: Kin is already open (pid -1) -- brought it forward instead
#
# `-1` is `NSRunningApplication`'s sentinel for a record with no process behind
# it. `activate` on that does nothing, and the reopen was over: no window, no
# second copy, no error. A yes/no question had a third answer and the code read
# it as yes.
#
# Two claims, and the second is the one the 0.75.2 fix is made of -- a rig that
# only checked the first would pass a build that never brings anything forward,
# which is the ten-copies bug all over again:
#
#   1. a reopen while the "open Kin" is a SENTINEL pid starts a real Kin
#   2. a reopen while the "open Kin" is a LIVE pid does not start a second one
#
# ── WHY THE PID IS INJECTED ────────────────────────────────────────────────
#
# There is no way to ask LaunchServices for a record carrying -1. So the rig
# hands `Target.launch` the pid to ask about (TK_WATCH_FAKE_OPEN_PID) and
# nothing else: the predicate, the activate, the log line and the `open -n` are
# all production code, so what runs here is the reported failure rather than a
# model of it. `tk --reopen-test` is the table-of-known-answers half.
#
# ── AND WHY ITS OWN BUNDLE ─────────────────────────────────────────────────
#
# The resident's whole job is to hold the registration for its bundle id, so a
# rig using com.tokkah.tk would take the door off the user's real Kin for as
# long as it ran, and `open -a` here would reach whichever of the two macOS
# felt like. Its own id, its own copy, its own launchd label, its own identity
# directory. TK_WATCH_OPEN_ARGS keeps the Kin it starts out of /Applications --
# and gives it a room, which is what makes it skip the double-click re-exec that
# would otherwise force `--video camera` and leave the window waiting forever on
# a camera this ad-hoc bundle has no grant for.
set -u
export TK_NO_RAISE=1
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/reopen-check.$$"
ID="com.tokkah.tk.reopenrig$$"
LABEL="$ID.watch"
APP="$SP/Kin.app"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
mkdir -p "$SP"

PIDS=""
# PIDs, never `pkill -f`: in a path like `./.build/debug/tk` every `.` is a
# regex wildcard, and that has already reaped another agent's processes in
# another checkout.
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
# The Kin that `open -n` starts is detached, so it outlives `reap`. Part two
# must start from nothing: a copy left over from part one both takes the
# registration and makes `open -a` fail with -600, which reads as "it did not
# start a second Kin" -- a pass for the wrong reason.
sweep() {
  for p in $(pgrep -f "$SP/Kin.app/Contents/MacOS/Tokkah" 2>/dev/null); do
    kill -9 "$p" 2>/dev/null
  done
  perl -e 'select undef,undef,undef,2'
}
cleanup() {
  reap
  # The Kin the rig started is not a child of this script -- `open -n` detaches
  # it -- so it is found by its own bundle id and ended by pid.
  for p in $(pgrep -f "$SP/Kin.app/Contents/MacOS/Tokkah" 2>/dev/null); do
    kill -9 "$p" 2>/dev/null
  done
  /bin/launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
  [ -n "${KEEP:-}" ] || rm -rf "$SP"
}
trap cleanup EXIT

# ── A BUNDLE, BECAUSE ONLY A BUNDLE GETS A REOPEN ──────────────────────────
# Ad-hoc signed on purpose: this copy must never match the real Kin's
# designated requirement, and it needs no camera or microphone grant -- it runs
# --video off --mute.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed -e "s|<string>com.tokkah.tk</string>|<string>$ID</string>|" \
    -e "s/__VERSION__/0.0.0-rig/g" "$HERE/../bundle/Info.plist" > "$APP/Contents/Info.plist"
cp "$TK" "$APP/Contents/MacOS/Tokkah"
chmod +x "$APP/Contents/MacOS/Tokkah"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign -s - -f "$APP" 2>/dev/null || { echo "REOPEN CHECK COULD NOT RUN -- ad-hoc sign failed"; exit 2; }
# LaunchServices will not send a reopen to a bundle it has never seen.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP" 2>/dev/null

export TK_WATCH_LABEL="$LABEL" TK_WATCH_ANYWHERE=1 TK_KIN_DIR="$SP/id" \
       TK_CRASH_DIR="$SP/crash" \
       TK_WATCH_OPEN_ARGS="--room reopenrig$$ --listen 0 --no-relocate --no-rings --no-update --no-telemetry --no-subtitles --mute --video off --window"

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }

# $1 = the pid the resident is told is "the open Kin", $2 = log name
# $1 = the pid to inject, or "" for no injection at all (the honest path)
run_reopen() {
  reap
  sweep
  if [ -z "$1" ]; then unset TK_WATCH_FAKE_OPEN_PID; else export TK_WATCH_FAKE_OPEN_PID="$1"; fi
  "$APP/Contents/MacOS/Tokkah" --watch \
    > "$SP/$2.log" 2>&1 &
  PIDS="$PIDS $!"
  perl -e 'select undef,undef,undef,4'
  grep -q "watch: resident" "$SP/$2.log" || return 1
  BEFORE=$(pgrep -f "$SP/Kin.app/Contents/MacOS/Tokkah" | wc -l | tr -d ' ')
  /usr/bin/open -a "$APP"
  perl -e 'select undef,undef,undef,6'
  perl -e 'select undef,undef,undef,6'
  AFTER=$(pgrep -f "$SP/Kin.app/Contents/MacOS/Tokkah" | wc -l | tr -d ' ')
  return 0
}

# ── 1. THE FIELD CASE: THE RECORD IS A GHOST ───────────────────────────────
echo "a reopen with no Kin running at all:"
run_reopen "" ghost || { echo "REOPEN CHECK COULD NOT RUN -- resident never started:"; sed -n '1,6p' "$SP/ghost.log" | sed 's/^/  /'; exit 2; }
grep -q "somebody opened Kin" "$SP/ghost.log" \
  || { echo "REOPEN CHECK COULD NOT RUN -- the reopen never reached the resident"; exit 2; }
echo "  processes for this bundle: $BEFORE before the click, $AFTER after"
[ "$AFTER" -gt "$BEFORE" ] \
  && say "OK" "and a real Kin came up ($BEFORE -> $AFTER)" \
  || say "FAIL" "the click opened nothing at all ($BEFORE -> $AFTER)"
# ── A PROCESS IS NOT A WINDOW ──────────────────────────────────────────────
# What was reported is "clicking does nothing", and a Kin that starts and shows
# nothing is still that. The resident points the launch's stderr at its own log
# lane (TK_KIN_DIR), and the app announces the window it opened by number.
RING="$SP/id/logs/ring.log"
WID=$(grep -o 'window id [0-9]*' "$RING" 2>/dev/null | tail -1)
if [ -n "$WID" ]; then
  say "OK" "and it put a window on the screen ($WID)"
else
  say "FAIL" "a process started but no window was ever opened"
  sed -n '1,8p' "$RING" 2>/dev/null | sed 's/^/      /'
fi

# ── THE RESIDENT MUST BE INVISIBLE ─────────────────────────────────────────
#
# It holds the bundle's registration all day and has no window, so a Dock icon
# for it is a second Kin sitting next to the real one -- which is exactly what
# the duplicate-icon report turned out to be. `setActivationPolicy` returns a
# Bool that was being thrown away, and it FAILS in a process that got here by
# execv. The resident now says so, and this reads it.
grep -q "could not go invisible" "$SP/ghost.log" \
  && say "FAIL" "the resident kept a Dock icon -- that is a second Kin in the Dock" \
  || say "OK" "the resident went invisible at startup"
# ── AND IT MUST STILL BE INVISIBLE AFTER A CLICK ───────────────────────────
#
# Answering a reopen PROMOTES this process: measured `.accessory` before a Dock
# click and `.regular` after one. Startup is therefore the wrong and only place
# this was ever checked, and every copy-counting claim above passes either way.
POL=$("$HERE/../.build/debug/tk" --watch-policy "$(pgrep -f "$SP/Kin.app/Contents/MacOS/Tokkah --watch" | head -1)" 2>&1)
echo "  the resident is now: $POL"
case "$POL" in
  *accessory*) say "OK" "and it is still invisible after the click" ;;
  *) say "FAIL" "the click gave the resident a Dock icon -- a second Kin in the Dock" ;;
esac

# ── A HANDLER NOBODY REACHES IS NOT A HANDLER ──────────────────────────────
#
# The raise is a signal handler, and the first version of it was installed at
# the foot of main.swift -- which a call with a window never reaches. It
# compiled, it read as finished, and it ran zero times. Nothing above would have
# noticed: the copy-counting claims pass either way. So the app is required to
# SAY the handler is armed, in the same log this rig already reads.
grep -q "raise: ready" "$RING" \
  && say "OK" "and that Kin can be asked to come forward" \
  || say "FAIL" "no raise handler was armed -- a click on an open Kin can only do nothing"

# ── 2. AND THE HALF 0.75.2 IS MADE OF, WITH THE REAL KIN FROM PART ONE ─────
#
# No injection here: the Kin that part one started is still running, so this is
# the actual question a second Dock click asks. It is the half that broke when
# `pid -1` was read as "nothing is running" -- every click became another copy.
echo "a second reopen while that Kin is still up:"
B2="$AFTER"
/usr/bin/open -a "$APP"
perl -e 'select undef,undef,undef,6'
A2=$(pgrep -f "$SP/Kin.app/Contents/MacOS/Tokkah" | wc -l | tr -d ' ')
echo "  processes for this bundle: $B2 before the second click, $A2 after"
[ "$A2" -le "$B2" ] \
  && say "OK" "no second copy" \
  || say "FAIL" "it opened another Kin -- this is the duplicate-app report"
grep -qE "watch: Kin is already open \(pid [0-9]+" "$SP/ghost.log" \
  && say "OK" "and it named the copy it found: $(grep -oE 'Kin is already open \(pid [0-9]+[^)]*\)' "$SP/ghost.log" | tail -1)" \
  || say "FAIL" "it did not recognise the Kin that was already running"

# ── 3. THE TWO INJECTED PIDS ───────────────────────────────────────────────
#
# `-1` is the sentinel the field reported and the one thing the process table
# can never produce, so it is injected. It must NOT be read as a running Kin --
# and `kill(-1, 0)` answers yes for it, which is how a liveness check written on
# kill(2) alone would pass this by signalling every process the user owns.
echo "a reopen told the open Kin is at pid -1, with no Kin running:"
run_reopen -1 sentinel || { echo "REOPEN CHECK COULD NOT RUN -- resident never started"; exit 2; }
echo "  processes for this bundle: $BEFORE before the click, $AFTER after"
[ "$AFTER" -gt "$BEFORE" ] \
  && say "OK" "the sentinel was not mistaken for a running Kin" \
  || say "FAIL" "a sentinel pid satisfied the is-it-running check -- the click did nothing"

# `$$` is this shell: a pid that is certainly alive and certainly not the
# resident. A build that answered "start one" to everything would pass part 1.
echo "a reopen while a live pid is open, which must NOT start a second Kin:"
run_reopen "$$" live || { echo "REOPEN CHECK COULD NOT RUN -- resident never started"; exit 2; }
echo "  processes for this bundle: $BEFORE before the click, $AFTER after"
if [ "$AFTER" -gt "$BEFORE" ]; then
  say "FAIL" "it started another copy -- every click is a new Kin again"
else
  say "OK" "no second copy was started"
fi
# Either answer is correct and which one appears depends on whether macOS still
# has an addressable record: `brought it forward` when it does, `asked it to
# come forward` (SIGWINCH, from the inside) when the app has re-exec'd. What
# must never appear is neither.
grep -qE "Kin is already open \(pid $$[,)]" "$SP/live.log" \
  && say "OK" "and it says so: $(grep -oE 'Kin is already open \(pid [0-9]+[^)]*\) -- [a-z ]*' "$SP/live.log" | tail -1)" \
  || say "FAIL" "a live pid was not recognised as the app being open"

[ "$fail" = "0" ] && echo "REOPEN CHECK: PASS" || echo "REOPEN CHECK: FAIL"
exit "$fail"
