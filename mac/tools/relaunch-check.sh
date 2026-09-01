#!/bin/bash
# ── DOES THE NEW BINARY LAUNCH, THE WAY LAUNCHD LAUNCHES IT? ────────────────
#
# Every self-update filed one crash report:
#
#   Parent: launchd   Coalition: com.tokkah.tk.watch
#   EXC_CRASH (SIGKILL (Code Signature Invalid))
#   Termination: CODESIGNING, Launch Constraint Violation
#
# 67 ms in, before anything but dyld, and then KeepAlive tried again and the
# second one worked. It self-heals, which is exactly why it survived four
# releases: "recovers on its own" and "nobody has looked" draw the same graph.
#
# `Update.launchable` waits for the swapped-in binary to start before letting go
# of the job. The danger in that fix is that it probes with a PLAIN fork/exec
# while the thing being refused is a LAUNCHD exec -- and an instrument that
# cannot see the failure returns the same answer as one that sees it pass.
#
# So this rig asks both questions on the same swapped bundle, at the same moment:
#
#   1. can a plain exec run it?            <- what Update.launchable measures
#   2. can LAUNCHD run it?                 <- what actually gets refused
#
# If 2 fails while 1 passes, the fix is blind and this says so in those words.
#
# Its own bundle id and its own launchd label throughout: the resident holds the
# registration for whatever id it runs under, and a rig using com.tokkah.tk would
# take the door off the user's real Kin for as long as it ran.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/relaunch-check.$$"
# ── THE PATH LaunchServices REPORTS IS NOT THE PATH WE TYPED ────────────────
# $TMPDIR ends in a slash, so this used to build ".../T//reopen-check.$$", and
# macOS resolves a launched bundle to its real path ("/private/var/...", one
# slash). Every `pgrep -f "$SP/..."` then matched NOTHING -- so the rig read
# "0 processes before, 0 after" for a click that had visibly opened a window,
# and reported the product broken because its ruler was.
SP="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SP")"
ID="com.tokkah.tk.relrig$$"
LABEL="$ID.watch"
APP="$SP/Kin.app"
OUT="$SP/agent.log"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
mkdir -p "$SP"
cleanup() {
  /bin/launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
  for p in $(pgrep -f "$SP/Kin.app/Contents/MacOS/Tokkah" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
  [ -n "${KEEP:-}" ] || rm -rf "$SP"
}
trap cleanup EXIT
fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }

# ── THE TWO BUNDLES MUST NOT BE THE SAME BUNDLE ────────────────────────────
#
# The first version of this rig built both copies identically, so they had the
# SAME cdhash -- and it reported PASS, because swapping a file for a byte-exact
# twin is not the thing that gets refused. What launchd pins is the code identity
# it bootstrapped the job with, so the ingredient is a DIFFERENT hash at the same
# path. `<tag>` is the whole difference.
mkapp() { # <dir> <tag>
  rm -rf "$1"; mkdir -p "$1/Contents/MacOS" "$1/Contents/Resources"
  sed -e "s|<string>com.tokkah.tk</string>|<string>$ID</string>|" \
      -e "s/__VERSION__/0.0.0-rig/g" "$HERE/../bundle/Info.plist" > "$1/Contents/Info.plist"
  cp "$TK" "$1/Contents/MacOS/Tokkah"; chmod +x "$1/Contents/MacOS/Tokkah"
  printf 'APPL????' > "$1/Contents/PkgInfo"
  printf '%s' "$2" > "$1/Contents/Resources/rig-tag"
  # Signed with the RELEASE certificate when it is available, ad-hoc otherwise.
  # A release is signed with the certificate, and the refusal under test is about
  # what macOS does to a signed, launchd-managed job -- so a rig that can only
  # ad-hoc sign is testing a neighbouring question and says so below.
  if [ -n "${CN:-}" ]; then codesign -s "$CN" -f --timestamp=none "$1" 2>/dev/null
  else codesign -s - -f "$1" 2>/dev/null; fi
}
if [ -f "$HOME/.config/kin-signing/env" ]; then
  set -a; . "$HOME/.config/kin-signing/env"; set +a
  security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN_NAME" 2>/dev/null
  echo "signing with the release certificate"
else
  CN=""; echo "NOTE: no release certificate here -- ad-hoc signing, a weaker arm"
fi
mkapp "$APP" first || { echo "RELAUNCH CHECK COULD NOT RUN -- signing failed"; exit 2; }
mkapp "$SP/next.app" second || exit 2
H1=$(codesign -d -vvv "$APP" 2>&1 | sed -n 's/^CDHash=//p' | head -1)
H2=$(codesign -d -vvv "$SP/next.app" 2>&1 | sed -n 's/^CDHash=//p' | head -1)
echo "  cdhash before ${H1:0:12}  after ${H2:0:12}"
[ -n "$H1" ] && [ "$H1" != "$H2" ] \
  || { echo "RELAUNCH CHECK COULD NOT RUN -- the two bundles hash the same, so there is nothing to refuse"; exit 2; }

# ── A REAL LAUNCHD AGENT, KeepAlive AND ALL ────────────────────────────────
cat > "$HOME/Library/LaunchAgents/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array>
  <string>$APP/Contents/MacOS/Tokkah</string><string>--watch</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>$OUT</string>
<key>StandardErrorPath</key><string>$OUT</string>
<key>EnvironmentVariables</key><dict>
  <key>TK_WATCH_LABEL</key><string>$LABEL</string>
  <key>TK_WATCH_ANYWHERE</key><string>1</string>
  <key>TK_NO_IDENTITY</key><string>1</string>
  <key>TK_KIN_DIR</key><string>$SP/id</string>
  <key>TK_CRASH_DIR</key><string>$SP/crash</string>
  <key>TK_WATCH_NO_DELEGATE</key><string>1</string>
</dict>
</dict></plist>
PLIST
/bin/launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
/bin/launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist" 2>/dev/null
# ── POLL FOR IT, DO NOT SLEEP AT IT ─────────────────────────────────────────
#
# This was a flat 4 s followed by one `pgrep`, and it reported "the agent never
# started" while the agent's own log -- printed by the same message -- showed it
# had started and got as far as claiming a handle. launchd's bootstrap, a code
# signature check on a freshly re-signed bundle, and the agent's first network
# call are not this rig's business and take as long as the machine takes; four
# other rigs on nine cores make that longer. A precondition that is a race is a
# precondition that fails on a busy Mac and passes on an idle one.
PID=""
for i in $(seq 1 50); do
  PID=$(pgrep -f "$SP/Kin.app/Contents/MacOS/Tokkah --watch" | head -1)
  [ -n "$PID" ] && break
  perl -e 'select undef,undef,undef,0.5'
done
[ -n "$PID" ] || { echo "RELAUNCH CHECK COULD NOT RUN -- the agent never started in 25 s:"
                   /bin/launchctl print "gui/$(id -u)/$LABEL" 2>&1 | grep -E "state|last exit|program" | sed 's/^/  /'
                   sed -n '1,6p' "$OUT" 2>/dev/null | sed 's/^/  /'; exit 2; }
echo "agent up as pid $PID"
BEFORE=$(ls "$SP/crash" 2>/dev/null | wc -l | tr -d ' ')

# ── THE SWAP THE UPDATER DOES, THEN THE RELAUNCH ───────────────────────────
python3 - "$SP" <<'PY'
import ctypes, sys
sp = sys.argv[1]
libc = ctypes.CDLL(None, use_errno=True)
RENAME_SWAP = 0x00000002
rc = libc.renamex_np(f"{sp}/next.app".encode(), f"{sp}/Kin.app".encode(), RENAME_SWAP)
print(f"  RENAME_SWAP rc={rc} errno={ctypes.get_errno()}")
PY

# 1. a plain exec, which is what Update.launchable uses
"$APP/Contents/MacOS/Tokkah" --version > "$SP/plain.out" 2>&1
PLAIN=$?
echo "  plain exec right after the swap: rc=$PLAIN ($(tr -d '\n' < "$SP/plain.out" | head -c 40))"

# 2. and launchd, which is what the crash report is about
kill -9 "$PID" 2>/dev/null
perl -e 'select undef,undef,undef,12'
NEW=$(pgrep -f "$SP/Kin.app/Contents/MacOS/Tokkah --watch" | head -1)
KILLED=0
for f in "$HOME/Library/Logs/DiagnosticReports"/Tokkah-*.ips; do
  [ -e "$f" ] || continue
  # Only reports written since this rig swapped, and only for THIS bundle path.
  [ "$f" -nt "$SP/plain.out" ] || continue
  grep -q "Launch Constraint Violation" "$f" 2>/dev/null && KILLED=$((KILLED+1))
done
echo "  after launchd relaunched: pid=${NEW:-none}, launch-constraint kills since the swap: $KILLED"

[ "$PLAIN" = "0" ] \
  && say "OK" "a plain exec of the swapped binary works" \
  || say "FAIL" "even a plain exec was refused (rc=$PLAIN)"
if [ "$KILLED" -gt 0 ] && [ "$PLAIN" = "0" ]; then
  say "FAIL" "launchd's exec was refused while a plain exec passed -- Update.launchable is BLIND to this failure and must probe the way launchd launches"
elif [ "$KILLED" -gt 0 ]; then
  say "OK" "the refusal reproduces, and the plain-exec probe sees it too"
else
  # ── AND A PASS HERE IS NOT MUCH OF A PASS ─────────────────────────────────
  #
  # This arm has never reproduced the refusal, even with the release certificate
  # and a genuinely different cdhash. The real one differs in two ways this rig
  # cannot safely copy: the bundle id is com.tokkah.tk and the path is
  # /Applications -- a registered, TCC-known app. Reproduced by hand there, three
  # times, which is where the fix was derived from.
  #
  # So this says what it is rather than banking a green tick: the swap machinery
  # works, and the constraint under test did not fire in this lane.
  say "OK" "launchd relaunched the swapped bundle with no refusal (NOTE: this lane"
  echo "         has never reproduced the /Applications refusal -- it is not proof of the fix)"
fi
[ -n "$NEW" ] \
  && say "OK" "and the agent is running again (pid $NEW)" \
  || say "FAIL" "the agent never came back after the swap"
[ "$fail" = "0" ] && echo "RELAUNCH CHECK: PASS" || echo "RELAUNCH CHECK: FAIL"
exit "$fail"
