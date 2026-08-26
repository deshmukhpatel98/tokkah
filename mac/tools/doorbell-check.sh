#!/bin/bash
# Can this Mac still be rung when Kin is closed -- and does the app KNOW?
#
# Two outages came out of this one area, and the second is the reason for this
# file. On 2026-08-26 the login agent had exited 0 the previous evening, launchd
# was told (`KeepAlive { SuccessfulExit: false }`) that a clean exit meant "it
# meant to stop", and so nothing on this Mac was listening for twenty hours. A
# call from another Mac rang into an empty house.
#
# The part worth testing is not the outage, it is the silence. `Watch.reach()`
# decided "people can reach you with Kin closed" from whether `launchctl print`
# EXITED 0 -- and it exits 0 for a job that is merely registered, including one
# that ran, exited, and was never restarted. So every screen that asks said yes.
#
#   bash mac/tools/doorbell-check.sh
#
# Isolated: its own TK_WATCH_LABEL, its own TK_KIN_DIR, and it boots out only the
# label it created. It must never be able to touch com.tokkah.tk.watch -- that is
# the user's actual doorbell and this script runs on the user's actual Mac.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
TK="$PWD/.build/debug/tk"
[ -x "$TK" ] || { echo "build first: swift build"; exit 2; }

LABEL="com.tokkah.tk.doorbellrig$$"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SP="$(mktemp -d)"
UID_="$(id -u)"

# ── WHICH launchd DOMAIN THIS MACHINE HAS ────────────────────────────────────
#
# `gui/<uid>` exists only where somebody is logged into a window server. A
# hosted CI runner may only have `user/<uid>`, and a container has neither. Try
# for a real domain, and if there is none, SAY SO AND STOP rather than failing
# eight assertions about launchd on a machine that does not run launchd jobs --
# a red build for the wrong reason teaches people to ignore red builds.
DOM=""
for d in "gui/$UID_" "user/$UID_"; do
  if /bin/launchctl print "$d" >/dev/null 2>&1; then DOM="$d"; break; fi
done
if [ -z "$DOM" ]; then
  echo "DOORBELL CHECK SKIPPED -- no launchd domain here (tried gui/$UID_ and user/$UID_)."
  echo "  This test installs a real LaunchAgent, so it needs a logged-in session."
  echo "  It is NOT a pass: nothing about the doorbell was checked on this machine."
  exit 0
fi
echo "launchd domain: $DOM"
pass=0; fail=0
cleanup() {
  /bin/launchctl bootout "$DOM/$LABEL" 2>/dev/null
  rm -f "$PLIST"; rm -rf "$SP"
}
trap cleanup EXIT

# A guard, not a comment. A typo that let this run against the real label would
# stop the user's Mac answering calls, which is the exact bug being tested.
case "$LABEL" in
  com.tokkah.tk.watch) echo "REFUSING: rig label collided with the real one"; exit 2;;
esac

ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
say()  { printf '\n%s\n' "$1"; }

# `--watch-status` writes to stderr, and the app reroutes stderr into
# ~/Library/Logs/Kin when it is a PIPE. A regular file is the one shape it
# leaves alone -- so capture to a file, never through `$( )`.
status() {
  local out="$SP/status.txt"
  TK_WATCH_LABEL="$LABEL" TK_WATCH_ANYWHERE=1 TK_KIN_DIR="$SP/id" \
    "$TK" --watch-status --mute 2>"$out"
  cat "$out"
}

write_plist() {   # $1 = the argument that decides whether it stays alive
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$TK</string><string>$1</string><string>--mute</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>30</integer>
<key>ProcessType</key><string>Interactive</string>
<key>StandardOutPath</key><string>$SP/rig.log</string>
<key>StandardErrorPath</key><string>$SP/rig.log</string>
</dict></plist>
EOF
}

say "1. the instrument itself: does launchctl distinguish loaded from running?"
# THE CALIBRATION. If launchctl reported a dead job as not-loaded, the original
# code would have been correct and there would be nothing here to fix. It does
# not, and that is the whole bug -- so assert it rather than assume it.
write_plist --version                        # runs, prints, exits 0 at once
/bin/launchctl bootstrap "$DOM" "$PLIST" 2>/dev/null
sleep 2
PRINT="$SP/print.txt"
/bin/launchctl print "$DOM/$LABEL" > "$PRINT" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok "launchctl print exits 0 for this job"
else bad "launchctl print exits 0" "got $RC -- the premise of this test is gone"; fi
# Assert the exact property reach() leans on, rather than one spelling of it.
# launchd says "not running" for a job it has given up on and "spawn scheduled"
# for one waiting out ThrottleInterval; both are "nobody is listening", and a
# test that only knew the first spelling would fail on a working fix.
if grep -qE '^\s*state = running' "$PRINT"; then
  bad "the job should not be running here" "$(grep -m1 'state = ' "$PRINT")"
else
  ok "...and it is not running ($(grep -m1 -oE 'state = [a-z ]+' "$PRINT"))"
fi

say "2. the fix: does the app call that unreachable?"
S="$(status)"
printf '  %s\n' "$S"
case "$S" in
  *"reachable-closed no"*) ok "reach() says NO for a registered-but-dead agent" ;;
  *) bad "reach() must say no here" "this is the twenty-hour bug, exactly" ;;
esac
case "$S" in
  *"fix=restart"*) ok "and offers the repair the app can perform itself" ;;
  *) bad "fix should be restart" "$S" ;;
esac

say "3. the control: a LIVE agent must still read as reachable"
# Without this arm the test passes just as well if reach() always says no, which
# would be a different outage with the same green tick.
/bin/launchctl bootout "$DOM/$LABEL" 2>/dev/null
write_plist --watch                          # the real thing: stays resident
/bin/launchctl bootstrap "$DOM" "$PLIST" 2>/dev/null
sleep 4
S2="$(status)"
printf '  %s\n' "$S2"
case "$S2" in
  *"reachable-closed yes"*) ok "reach() says YES while the agent is running" ;;
  *) bad "a running agent must read as reachable" "$S2" ;;
esac

say "4. Watch.restart() actually restarts, and reports what it found"
/bin/launchctl bootout "$DOM/$LABEL" 2>/dev/null
write_plist --version
/bin/launchctl bootstrap "$DOM" "$PLIST" 2>/dev/null
sleep 2
/bin/launchctl kickstart -k "$DOM/$LABEL" >/dev/null 2>&1
/bin/launchctl print "$DOM/$LABEL" > "$PRINT" 2>&1
if grep -qE 'runs = [2-9]' "$PRINT"; then ok "kickstart ran it again (runs > 1)"
else bad "kickstart should have started another run" "$(grep -m1 'runs' "$PRINT")"; fi

say "5. the plist this build writes carries the fixed policy"
# The outage was a POLICY, and a policy only reaches a Mac that already has a
# login item if staleReason() knows to care about it.
/bin/launchctl bootout "$DOM/$LABEL" 2>/dev/null; rm -f "$PLIST"
TK_WATCH_LABEL="$LABEL" TK_WATCH_ANYWHERE=1 TK_KIN_DIR="$SP/id" \
  "$TK" --watch-install --mute 2>"$SP/inst.txt"
if /usr/libexec/PlistBuddy -c "Print :KeepAlive" "$PLIST" 2>/dev/null | grep -qi true; then
  ok "install() writes KeepAlive = true"
else
  bad "install() must write KeepAlive true" "$(/usr/libexec/PlistBuddy -c 'Print :KeepAlive' "$PLIST" 2>&1 | head -2)"
fi
# And the migration: an old-shape plist must read as stale, or the fix ships to
# new installs only -- which is how a shipped fix reaches nobody.
/usr/libexec/PlistBuddy -c "Delete :KeepAlive" "$PLIST" >/dev/null 2>&1
/usr/libexec/PlistBuddy -c "Add :KeepAlive dict" "$PLIST" >/dev/null 2>&1
/usr/libexec/PlistBuddy -c "Add :KeepAlive:SuccessfulExit bool false" "$PLIST" >/dev/null 2>&1
S3="$(status)"
case "$S3" in
  *"STALE"*"clean exit"*) ok "an old-shape plist reads as stale, so it gets rewritten" ;;
  *) bad "old-shape plist must read as stale" "$S3" ;;
esac

printf '\n'
if [ "$fail" -eq 0 ]; then echo "DOORBELL CHECK PASSED ($pass assertions)"; else echo "DOORBELL CHECK FAILED ($fail of $((pass+fail)))"; fi
[ "$fail" -eq 0 ]
