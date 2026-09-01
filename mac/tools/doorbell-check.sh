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
LABEL="com.tokkah.tk.doorbellrig$$"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SP="$(mktemp -d)"
PRINT="$SP/print.txt"
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

# ── THE BINARY UNDER TEST MUST BE THE SOURCE UNDER TEST ──────────────────────
#
# This used to be `[ -x "$TK" ] || echo "build first"`, and existence is not
# currency. On 2026-08-26 the doorbell fix was written, committed, and then
# checked by this script against a .build/debug/tk that was NINE HOURS OLDER
# than the sources -- built before the fix existed. Five assertions failed and
# every one of them was about code nobody was shipping. A rig that tests a stale
# binary does not report "stale"; it reports a verdict, and the verdict is about
# the wrong program. It could as easily have been a PASS.
#
# So build it here rather than trusting whatever is lying in .build, and then
# check the timestamp anyway, because `swift build` can succeed without relinking.
#
# After the domain check, not before it: on a runner with no launchd session
# there is nothing to test, and a skip should not cost a Swift build first.
echo "== building the binary under test =="
if ! swift build --product tk >/dev/null 2>&1; then
  echo "BUILD FAILED -- cannot test the doorbell against a binary that does not compile"
  swift build --product tk 2>&1 | grep -E "error:" | head -5
  exit 2
fi
[ -x "$TK" ] || { echo "swift build reported success but $TK is not there"; exit 2; }
NEWER=$(find Sources -name '*.swift' -newer "$TK" 2>/dev/null | head -3)
if [ -n "$NEWER" ]; then
  echo "STALE BINARY -- these sources are newer than $TK even after a build:"
  echo "$NEWER" | sed 's/^/    /'
  echo "  Refusing to report a verdict about a binary that is not this source."
  exit 2
fi
echo "  $TK is current with Sources/"
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

# ── WAIT FOR THE JOB TO SETTLE, DO NOT SLEEP AT IT ───────────────────────────
#
# These were `sleep 2`, on the assumption that `tk --version` starts and exits
# inside two seconds. It usually does. This is a DEBUG build of a whole app, and
# on a slower run it does not -- scenario 1 read `state = running`, called it a
# failure, and the thing it was reporting was the sleep. A rig whose verdict
# depends on which side of a fixed delay it lands on is measuring the delay.
#
# Poll for the state instead, with a bound, and say plainly when the bound is
# hit rather than carrying on and blaming the product for it.
# The settled states, named. `state` has at least four spellings here and only
# two of them mean "nobody is listening and launchd is not mid-launch":
#
#   running          -- alive
#   xpcproxy         -- launchd's stub, about to exec: NOT running, NOT settled
#   not running      -- ran, exited, given up on
#   spawn scheduled  -- waiting out ThrottleInterval
#
# The first version of this waited for "not `running`" and returned during
# xpcproxy, which is how scenario 1 came to report `state = xpcproxy` as proof
# the job was dead and 2b came to find it running a moment later. Absence of
# "running" is not presence of settled.
SETTLED='^[[:space:]]*state = (not running|spawn scheduled)'

# ── bootout IS ASYNCHRONOUS ──────────────────────────────────────────────────
#
# It returns before the job is actually gone, so a `bootstrap` on the next line
# races it and silently loses -- leaving no job at all, which reads downstream as
# "kickstart did not start another run" with no `runs` line to explain it. This
# rig lost that race about one run in four, and the same race once left the
# user's real doorbell DOWN after a live plist patch.
#
# So: bootstrap through here, never directly.
rebootstrap() {
  local waited=0
  /bin/launchctl bootout "$DOM/$LABEL" 2>/dev/null
  while [ "$waited" -lt 20 ]; do
    /bin/launchctl print "$DOM/$LABEL" >/dev/null 2>&1 || break
    sleep 1; waited=$((waited+1))
  done
  /bin/launchctl bootstrap "$DOM" "$PLIST" 2>/dev/null
  # And prove it took, rather than assuming: a failed bootstrap is silent.
  waited=0
  while [ "$waited" -lt 20 ]; do
    /bin/launchctl print "$DOM/$LABEL" >/dev/null 2>&1 && return 0
    sleep 1; waited=$((waited+1))
  done
  echo "  BOOTSTRAP DID NOT TAKE for $LABEL -- nothing below this can mean anything"
  return 1
}

wait_settled() {       # $1 = seconds to allow
  local limit="$1" waited=0
  while [ "$waited" -lt "$limit" ]; do
    /bin/launchctl print "$DOM/$LABEL" > "$PRINT" 2>&1
    grep -qE "$SETTLED" "$PRINT" && return 0
    sleep 1; waited=$((waited+1))
  done
  return 1
}

wait_running() {       # $1 = seconds to allow
  local limit="$1" waited=0
  while [ "$waited" -lt "$limit" ]; do
    if /bin/launchctl print "$DOM/$LABEL" 2>/dev/null | grep -qE '^\s*state = running'; then
      return 0
    fi
    sleep 1; waited=$((waited+1))
  done
  return 1
}

# `--watch-status` writes to stderr, and the app reroutes stderr into
# ~/Library/Logs/Kin when it is a PIPE. A regular file is the one shape it
# leaves alone -- so capture to a file, never through `$( )`.
status() {
  local out="$SP/status.txt"
  TK_WATCH_LABEL="$LABEL" TK_WATCH_ANYWHERE=1 TK_KIN_DIR="$SP/id" \
    "$TK" --watch-status --mute 2>"$out"
  cat "$out"
}

# $1 = the argument that decides whether it stays alive
# $2 = the KeepAlive policy, and it has to be a PARAMETER
#
# This hardcoded <true/>, which is the FIXED policy -- the one that by design
# never leaves a job dead. The scenarios below that need a registered-but-dead
# job were therefore asking launchd to restart the thing they wanted dead, and
# only "passed" by catching it inside its 30 s ThrottleInterval. On 2026-08-26
# the same rig caught it a moment earlier, read `state = running`, and failed
# three assertions about a fix that was working. A rig whose verdict depends on
# which side of a sleep it lands on is not measuring the product.
#
# The dead-job scenarios now install the OLD policy on purpose: that is the
# historical condition being reproduced -- a job that ran, exited 0, and was
# never restarted -- and with KeepAlive false it settles there and stays.
# ── A LAUNCHD JOB CANNOT RUN ANYTHING UNDER ~/Downloads ─────────────────────
#
# This rig could not get past its own first step for weeks: "launchd never parked
# the rig job in 90 s (state = running)". The job was `tk --version`, which exits
# in six milliseconds from a shell. Under launchd it produced NO OUTPUT AT ALL and
# sat at:
#
#     state = running
#     runs = 1
#     last exit code = (never exited)
#
# Four substitutions, one variable at a time, found it -- and the first three
# answers were all wrong:
#
#   the same binary, ad-hoc signed, in a temp dir   -> ran, printed, parked
#   the repo copy (already ad-hoc signed by SwiftPM)-> hung          NOT signing
#   a copy at a path WITH a space in it             -> ran           NOT the space
#   the real path behind .build/debug's symlink     -> hung          NOT the symlink
#   a fresh copy inside ~/Downloads                 -> hung
#   the same copy in ~/Library/Caches               -> ran
#
# It is the FOLDER. This repo lives in `~/Downloads`, which macOS protects with
# TCC, and a launchd agent has no session in which to ask for access -- so the
# spawn stalls forever instead of failing. No error, no exit code, no output, and
# a rig left blaming its own timeout.
#
# Production never meets this: the agent points into `/Applications/Kin.app`. So
# the rig runs from a copy outside the protected folder, which is also the more
# faithful model. The ad-hoc re-sign is kept because the real install is signed
# and a copy is cheap, not because signing was ever the problem.
TKSIGNED="$SP/tk-signed"
case "$SP" in "$HOME/Downloads"*|"$HOME/Desktop"*|"$HOME/Documents"*)
  echo "DOORBELL CHECK COULD NOT RUN -- the scratch dir is inside a TCC-protected"
  echo "  folder ($SP). launchd cannot execute anything there and will hang."; exit 2 ;;
esac
cp "$TK" "$TKSIGNED" 2>/dev/null || { echo "DOORBELL CHECK COULD NOT RUN -- no $TK to copy"; exit 2; }
codesign --force --sign - "$TKSIGNED" > "$SP/sign.log" 2>&1 || true
# Everything from here runs the copy: the app compares the plist's program path
# against its OWN path when it decides whether a plist is stale, so a rig that
# loads one copy and interrogates another gets a true answer to a question nobody
# asked ("plist present (STALE -- points at a different copy)").
TK="$TKSIGNED"

write_plist() {
  local keep="$2" throttle="${3:-30}"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$TKSIGNED</string><string>$1</string><string>--mute</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><$keep/>
<key>ThrottleInterval</key><integer>$throttle</integer>
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
write_plist --version false                  # runs, prints, exits 0, STAYS exited
rebootstrap || bad "could not bootstrap the rig job" "launchd refused it"
# ── THE CALIBRATION NEEDS A PARKED JOB, AND ONLY LAUNCHD DECIDES WHEN ───────
#
# `tk --version` exits in 7 ms. How long launchd then takes to stop calling the
# job `running` is launchd's business: measured on this Mac it is usually a second
# or two and occasionally more than forty, on the same binary, in back-to-back
# runs. Reported as `FAIL the job should not be running here`, that read as the
# app being broken and made this whole file fail about one run in three -- on a
# pristine checkout as readily as on a patched one.
#
# It is a missing PRECONDITION, and this arm is the calibration the rest of the
# file rests on, so the honest verdict for the whole rig is "could not run".
if ! wait_settled 90; then
  echo "DOORBELL CHECK COULD NOT RUN -- launchd never parked the rig job in 90 s"
  echo "  ($(grep -m1 'state = ' "$PRINT" 2>/dev/null | tr -d '\t')). Nothing below can be"
  echo "  calibrated without it, and none of this is a verdict on the app."
  exit 2
fi
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

say "2a. a dead agent under the OLD policy: unreachable, and rewrite the plist"
# The plist written above is the old shape, so the honest repair is not "start it
# again" -- that would put the same policy back in charge and it would be dead
# again by morning. It is "write the plist this build ships and then start it".
S="$(status)"
printf '  %s\n' "$S"
case "$S" in
  *"reachable-closed no"*) ok "reach() says NO for a registered-but-dead agent" ;;
  *) bad "reach() must say no here" "this is the twenty-hour bug, exactly" ;;
esac
case "$S" in
  *"fix=install"*) ok "and the repair replaces the policy, not just the process" ;;
  *) bad "fix should be install for an old-shape plist" "$S" ;;
esac

say "2b. a dead agent under the NEW policy: unreachable, and just start it"
# The case every Mac is in AFTER this release. KeepAlive is true, so launchd is
# going to restart it -- but between the exit and the restart the job is loaded
# and not running, and reach() must not call that reachable. Parked with a long
# ThrottleInterval so the window is five minutes wide rather than a race: this
# is the same "loaded, registered, nobody listening" state launchd reports as
# `spawn scheduled`, which is the second spelling of the twenty-hour bug.
write_plist --version true 300
rebootstrap || bad "could not bootstrap the rig job" "launchd refused it"
# ── A PRECONDITION THAT DID NOT HAPPEN IS NOT A PRODUCT FAILURE ──────────────
#
# This arm needs launchd to have PARKED the job -- loaded, registered, nobody
# listening -- and only launchd decides when that is true. Measured on this Mac:
# it usually parks within a second or two and occasionally has not done so after
# forty, on the same binary, in back-to-back runs. `tk --version` exits in 7 ms
# either way, so the variance is entirely launchd's.
#
# It used to be reported as `FAIL could not park the job`, which reads as the app
# being broken and made this rig fail about one run in three -- on a pristine
# checkout as readily as on a patched one. A red that appears on unchanged code is
# worse than no test: it is the thing that teaches you to ignore the next red.
#
# So a missing precondition says so, out loud, and the arm is SKIPPED rather than
# scored. The rig's exit code separates the three cases: passed, failed, and could
# not be run.
SKIP2B=""
if ! wait_settled 60; then
  SKIP2B=1
  printf '  %-5s %s\n' "SKIP" "launchd never parked the job in 60 s ($(grep -m1 'state = ' "$PRINT" 2>/dev/null | tr -d '\t'))"
  printf '  %-5s %s\n' "" "-- 2b needs a parked job to test; nothing here is a verdict on the app"
fi
/bin/launchctl print "$DOM/$LABEL" > "$PRINT" 2>&1
if [ -n "$SKIP2B" ] || grep -qE '^\s*state = running' "$PRINT"; then
  [ -n "$SKIP2B" ] || printf '  %-5s %s\n' "SKIP" "the job is still running: $(grep -m1 'state = ' "$PRINT" | tr -d '\t')"
else
  S2b="$(status)"
  printf '  %s\n' "$S2b"
  case "$S2b" in
    *"reachable-closed no"*) ok "a throttled agent is not reachable ($(grep -m1 -oE 'state = [a-z ]+' "$PRINT"))" ;;
    *) bad "a throttled agent must read as unreachable" "$S2b" ;;
  esac
  case "$S2b" in
    *"fix=restart"*) ok "and offers the repair the app can perform itself" ;;
    *) bad "fix should be restart for a current-shape plist" "$S2b" ;;
  esac
fi

say "3. the control: a LIVE agent must still read as reachable"
# Without this arm the test passes just as well if reach() always says no, which
# would be a different outage with the same green tick.
write_plist --watch true                     # the real thing: stays resident
rebootstrap || bad "could not bootstrap the rig job" "launchd refused it"
wait_running 30 || bad "the live agent never came up" "the control arm proves nothing without it"
S2="$(status)"
printf '  %s\n' "$S2"
case "$S2" in
  *"reachable-closed yes"*) ok "reach() says YES while the agent is running" ;;
  *) bad "a running agent must read as reachable" "$S2" ;;
esac

say "4. Watch.restart() actually restarts, and reports what it found"
write_plist --version false
rebootstrap || bad "could not bootstrap the rig job" "launchd refused it"
wait_settled 40 || true
/bin/launchctl kickstart -k "$DOM/$LABEL" >/dev/null 2>&1
# ── WAIT FOR THE RUN, DO NOT READ FOR IT ─────────────────────────────────────
#
# `kickstart` returns as soon as launchd has ACCEPTED the request, not when the
# job has run, so reading `runs` on the next line is a race -- and one this rig
# lost 2 times in 3. It is the same fault as the fixed sleeps above it, wearing
# "no sleep at all" instead of "a sleep of the wrong length": both decide from a
# moment rather than from a state.
waited=0
while [ "$waited" -lt 20 ]; do
  /bin/launchctl print "$DOM/$LABEL" > "$PRINT" 2>&1
  grep -qE 'runs = [2-9]' "$PRINT" && break
  sleep 1; waited=$((waited+1))
done
if grep -qE 'runs = [2-9]' "$PRINT"; then ok "kickstart ran it again (runs > 1, after ${waited}s)"
else bad "kickstart should have started another run" "$(grep -m1 'runs' "$PRINT") after ${waited}s"; fi

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
