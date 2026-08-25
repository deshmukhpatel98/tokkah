#!/bin/bash
# ── A CANCELLED CALL THAT RINGS AT SOMEBODY ANYWAY ──────────────────────────
#
# Kin can be rung while it is closed: a background watcher polls the doorbell and
# launches a NEW copy of the app to show the ring card. Draining that mailbox is
# DESTRUCTIVE -- whichever poll returns first takes the message and it is gone for
# everybody else -- so the watcher yields the line to the app the moment the app
# claims it, and the app claims it a second or so into its own launch.
#
# Between those two moments the WATCHER is still the one polling. A `bye` that
# lands in that window is drained by the watcher, which has no window to take
# down and drops it on the floor. The copy it just launched never hears that the
# call was cancelled, and it rings at the person for the full 45 s for a call
# that no longer exists. The comment in that closure asserted "the copy it
# launched does its own polling and will hear its own"; that sentence is false
# for exactly the window that matters, and the first second or two after a
# misdial is precisely when people cancel.
#
# Three arms, and the second is the one that makes the first mean anything:
#
#   A  cancel EARLY -- one beat after the watcher opened Kin, while the watcher
#      is still the holder. This is the bug. The rig refuses to grade it unless
#      the watcher's own log shows it really did eat the bye BEFORE it stood
#      down, so a lucky run cannot read as a pass.
#   B  cancel LATE -- not sent until the launched copy has taken the line and the
#      watcher has said, in its own log, that it is standing by. This path has
#      always worked, and if the rig cannot tell it from A then the rig is
#      measuring the doorbell rather than the race.
#   C  the handoff's own guards. A local note that names a different caller, and
#      one that is older than a ring's lease, must NOT take down a live ring --
#      and each must be CONSUMED, or "it kept ringing" would also be what a
#      reader that never ran looks like. Then a good note, and the ring stops.
#
# ── WHAT THIS RIG TOUCHES AND WHAT IT REFUSES TO ────────────────────────────
#
# Real processes, the real doorbell at room.tokkah.com, real signing keys: every
# part of this that can be wrong lives between two processes and a server. It
# runs against the two long-lived rig identities (same pair `bye-check.sh` uses),
# never the handle of whoever owns this Mac, and it builds its own throwaway .app
# under the scratch directory with its own bundle id -- because the watcher opens
# Kin with `open -n -a <bundle>`, and there is no way to exercise that line
# without a bundle to open. `--no-relocate` keeps that copy from installing
# itself over somebody's real Kin -- which has destroyed a release here once
# already -- and off the login item, which is the same flag's other job.
#
# A phone icon appears in the menu bar while a watcher is up; it goes when the
# rig reaps it. Nothing is ever raised in front of the person using this Mac, and
# nothing makes a sound: TK_NO_RAISE and --mute, on every process this starts.
set -u
export TK_NO_RAISE=1
PIDS=""
LAUNCHED=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
alive() { kill -0 "$1" 2>/dev/null; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/cancelrace-check.$$"
# ── TWO REAL IDENTITIES, KEPT ───────────────────────────────────────────────
# A handle is bound to the key that first claimed it, so a rig minting a fresh
# key each run would be refused as a squatter on its second run. Same pair, same
# place, same reason as bye-check.sh.
ID1="${KIN_RIG_ONE:-$HOME/.config/kin-rig/one}"
ID2="${KIN_RIG_TWO:-$HOME/.config/kin-rig/two}"
H1=kinrigone
H2=kinrigtwo
# Its own launchd label, never the product's. Nothing here installs a login item
# -- `--watch` runs the resident directly -- but a label is global to the login
# session, and if anything ever did install one under the default name it would
# bootout the watcher belonging to the person at this Mac.
LABEL="com.tokkah.tk.cancelrace$$"
NOTES="$ID2/cancelled"
mkdir -p "$SP"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
for d in "$ID1" "$ID2"; do
  [ -f "$d/identity.json" ] || {
    echo "no rig identity at $d. Claim the pair once:"
    echo "  TK_KIN_DIR=$ID1 $TK --claim --handle $H1 --no-update"
    echo "  TK_KIN_DIR=$ID2 $TK --claim --handle $H2 --no-update"
    exit 2; }
done
# ── A PATH WITH A SPACE IN IT WOULD SWITCH HALF THE RIG OFF ─────────────────
# TK_WATCH_OPEN_ARGS is split on spaces by the watcher, so a scratch path
# containing one would hand the launched copy a mangled argv -- `--log` pointing
# somewhere else, `--no-relocate` missing -- and every arm would still produce a
# verdict. This repo has lost three A/Bs to flags that quietly did nothing.
case "$SP" in *\ *) echo "CANCEL-RACE CHECK COULD NOT RUN -- scratch path has a space: $SP"; exit 2 ;; esac
cleanup() {
  reap
  for p in $LAUNCHED; do kill -9 "$p" 2>/dev/null; done
  /bin/launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
  # The handoff's drop box lives in the rig identity, so it is the rig's to tidy.
  rm -rf "$NOTES"
  [ -n "${KEEP:-}" ] || rm -rf "$SP"
}
trap cleanup EXIT

# ── THE BUNDLE THE WATCHER OPENS ────────────────────────────────────────────
#
# `Bundle.main.bundleURL` of a bare binary is the directory it sits in, and
# `open -a <a directory>` opens nothing -- so a rig running `.build/debug/tk
# --watch` can never reach the line under test. This is the smallest thing that
# is a real .app: a copy of the binary for the WATCHER to be, an Info.plist with
# its OWN bundle id (sharing com.tokkah.tk would make LaunchServices resolve the
# user's Kin to this process, which has made Kin unlaunchable from the Finder
# here before), and a `CFBundleExecutable` that is a wrapper script.
#
# ── AND THE WRAPPER EXECS THE BINARY OUTSIDE THE BUNDLE, ON PURPOSE ────────
#
# The obvious wrapper execs the copy inside `Contents/MacOS`, and every launched
# copy was killed two seconds in with no output past `mic: asking for
# permission`. From the crash report:
#
#   "termination": { "namespace": "TCC", "details": [ "This app has crashed
#    because it attempted to access privacy-sensitive data without a usage
#    description ... NSMicrophoneUsageDescription" ]}
#
# Kin asks for the microphone on EVERY launch, deliberately, so the grant is
# settled before a call needs it -- and a bundle without the string is killed for
# asking. Adding the string is worse than useless here: a bundle id nobody has
# ever answered for would put a permission dialog in front of whoever is using
# this Mac. Exec'ing the binary at its ordinary path leaves the process with no
# bundle of its own, which is exactly what every other rig in this directory
# runs, and the question resolves against the same grant they use.
#
# The wrapper is also how the rig's environment survives the launch. `open` does
# forward the caller's environment today -- measured -- but under launchd the
# resident gets a nearly empty one, and a rig whose isolation depends on a
# behaviour it does not control is a rig that will one day claim a handle into
# somebody's real install.
APP="$SP/KinRig.app"
mkdir -p "$APP/Contents/MacOS"
cp "$TK" "$APP/Contents/MacOS/tkreal"
{
  echo '#!/bin/sh'
  echo "export TK_KIN_DIR=\"$ID2\""
  echo 'export TK_NO_RAISE=1'          # never in front of whoever is using this Mac
  echo 'export TK_MUTE=1'              # and never out loud
  # NOT TK_NO_IDENTITY. It reads like the safe belt to add here and it switches
  # the launched copy's DOORBELL OFF: `noIdentity` skips `Identity.start()`,
  # which is the only call that loads identity.json, so `Identity.claimed` is
  # false, `startRingingOnce` never runs, the line is never claimed and the
  # watcher never stands down. Measured -- arm B could not even be set up. The
  # login item is kept away from by `--no-relocate` instead, which is the switch
  # that actually guards it.
  echo "export TK_WATCH_LABEL=\"$LABEL\""
  echo "exec \"$TK\" \"\$@\""
} > "$APP/Contents/MacOS/tk"
chmod +x "$APP/Contents/MacOS/tk"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>tk</string>
<key>CFBundleIdentifier</key><string>$LABEL</string>
<key>CFBundleName</key><string>KinRig</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST

# What the watcher adds to its own fixed launch line. `--no-ring-preview` because
# whether the caller is in this identity's contact list decides whether the copy
# joins the room, and a rig whose shape depends on a file it did not write is a
# rig that passes on one Mac and hangs on another. `--listen 8091` for the same
# reason: the default port belongs to whatever else is running here.
copyargs() { # log path
  echo "--no-relocate --no-update --no-telemetry --no-subtitles --no-ring-preview" \
       "--mute --listen 8091 --log $1 --press-after 4 --press ?"
}
# The pid the launched copy printed for itself. `--log` writes it as its first
# line, and it is the only handle this shell has on a process `open` started.
copypid() { sed -n 's/^log: tk [^ ]* pid \([0-9][0-9]*\) .*/\1/p' "$1" 2>/dev/null | head -1; }
waitfor() { # file, pattern, seconds
  n=0; lim=$(( $3 * 10 ))
  while [ "$n" -lt "$lim" ]; do
    [ -f "$1" ] && grep -q "$2" "$1" && return 0
    perl -e 'select undef,undef,undef,0.1'
    n=$((n + 1))
  done
  return 1
}
nap() { perl -e "select undef,undef,undef,$1"; }
ring() { # id dir -> prints the room it minted
  TK_KIN_DIR="$1" "$TK" --ring-only "$H2" --no-update > "$2" 2>&1
  sed -n 's/^ring-only: rang @[a-z0-9]*, room \([a-z0-9-]*\)$/\1/p' "$2" | head -1
}
# Where the watcher leaves a hang-up it could not deliver: one file per call,
# named by a hash of the room so that a room name -- which the CALLER chooses and
# signs, `../../` included -- can never become a path.
notefile() { echo "$NOTES/$(printf '%s' "$1" | shasum -a 256 | cut -c1-32).json"; }
plant() { # room, from, t-ms
  mkdir -p "$NOTES"
  printf '{"from":"%s","room":"%s","t":%s}' "$2" "$1" "$3" > "$(notefile "$1")"
}
nowms() { perl -e 'printf "%d", time()*1000'; }

startwatcher() { # log, copy-log, ms to hold the launched copy's doorbell shut
  rm -rf "$NOTES"
  # The COPY INSIDE the bundle, so `Bundle.main` is the .app and `open -a` has
  # something to open -- the wrapper above is for the launched copy only, and a
  # watcher started through it would report the ordinary build directory and
  # warn that a ring can open nothing.
  #
  # TK_WATCH_NO_DELEGATE, because a resident that takes `NSApp.delegate` becomes
  # the answer to every Finder double-click of Kin on this Mac for as long as it
  # runs. That is right for the product and unacceptable for a test.
  #
  # TK_RING_START_MS is set on the WATCHER and reaches the copy because `open`
  # forwards the environment -- which is also how the plist's variables reach a
  # real one under launchd. It does nothing to the watcher itself: the resident
  # drives `ringLoop` directly and only the app's own `startRinging` reads it.
  spawn env TK_KIN_DIR="$ID2" TK_WATCH_LABEL="$LABEL" TK_RING_DEBUG=1 \
        TK_RING_START_MS="$3" \
        TK_WATCH_NO_DELEGATE=1 TK_WATCH_OPEN_ARGS="$(copyargs "$2")" \
        "$APP/Contents/MacOS/tkreal" --watch > "$1" 2>&1
  waitfor "$1" "watch: resident for @$H2" 15 || return 1
  # One full poll out and back before anybody rings, or the ring lands on a
  # doorbell that has not started listening yet.
  nap 2
  return 0
}

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }
cannot() { echo "CANCEL-RACE CHECK COULD NOT RUN -- $1"; exit 2; }

# ── ARM A: THE CANCEL ARRIVES WHILE KIN IS STILL STARTING ───────────────────
echo "── A. cancelled one beat after the watcher opened Kin"
startwatcher "$SP/a-watch.log" "$SP/a-copy.log" 6000 || cannot "the watcher never came up:
$(sed -n '1,6p' "$SP/a-watch.log" | sed 's/^/  /')"
grep -q "is not an app bundle" "$SP/a-watch.log" \
  && cannot "the watcher does not think it is in a bundle, so it can open nothing"
RA=$(ring "$ID1" "$SP/a-ring.log")
[ -n "$RA" ] || cannot "the caller could not ring:
$(sed -n '1,6p' "$SP/a-ring.log" | sed 's/^/  /')"
waitfor "$SP/a-watch.log" "is calling -- opening Kin" 20 \
  || cannot "the watcher never opened Kin for room $RA:
$(sed -n '1,20p' "$SP/a-watch.log" | sed 's/^/  /')"
# THE WINDOW ITSELF. `open` has returned and the new copy is somewhere between
# exec and its own first poll; the watcher is still the only process listening
# for @$H2, and TK_RING_START_MS holds it that way for six seconds so the cancel
# lands inside the seam rather than beside it.
nap 1
TK_KIN_DIR="$ID1" "$TK" --bye-only "$H2" --room "$RA" --no-update > "$SP/a-bye.log" 2>&1
grep -q "bye-only: told @$H2" "$SP/a-bye.log" \
  || cannot "the cancel was never sent:
$(sed -n '1,6p' "$SP/a-bye.log" | sed 's/^/  /')"
nap 16
APID=$(copypid "$SP/a-copy.log")
[ -n "$APID" ] || cannot "the copy the watcher launched never wrote a log at $SP/a-copy.log:
$(sed -n '1,10p' "$SP/a-watch.log" | sed 's/^/  /')"
# ── HOW THIS ARM GOT ITS WINDOW ────────────────────────────────────────────
#
# Printed, not asserted, and the difference matters. What makes this arm real is
# the check below -- the watcher took the bye while it was still the holder --
# because the drain is destructive, so a message the watcher took is a message
# the launched copy cannot have received over the doorbell, whatever it was
# doing at the time. TK_RING_START_MS only makes that reliable instead of a coin
# flip, and once the handoff works the copy exits before it would ever have
# printed the line, which is why requiring it read as a broken rig for one run.
if grep -q "TK_RING_START_MS" "$SP/a-copy.log"; then
  echo "     the launched copy held its own doorbell shut for 6000 ms"
elif grep -q "ring: listening for calls" "$SP/a-copy.log"; then
  echo "     NOTE: TK_RING_START_MS did nothing and the copy was already listening"
else
  echo "     the launched copy never got as far as listening for calls"
fi
LAUNCHED="$LAUNCHED $APID"
A_ALIVE=no; alive "$APID" && A_ALIVE=yes
# ── THE RIG REFUSES TO GRADE A RACE IT DID NOT RUN ─────────────────────────
# If the bye went to the launched copy's own poll instead, this arm is arm B
# wearing arm A's name and its verdict means nothing either way.
grep -q "sent bye for room $RA" "$SP/a-watch.log" \
  || cannot "the watcher never took the bye -- the launch window was missed, so
  this run proves nothing. The watcher saw:
$(grep -E 'watch:|ring: poll' "$SP/a-watch.log" | sed -n '1,12p' | sed 's/^/  /')"
BYE_LINE=$(grep -n "sent bye for room $RA" "$SP/a-watch.log" | head -1 | cut -d: -f1)
DOWN_LINE=$(grep -n "standing by" "$SP/a-watch.log" | head -1 | cut -d: -f1)
[ -n "$DOWN_LINE" ] && [ "$BYE_LINE" -gt "$DOWN_LINE" ] \
  && cannot "the watcher had already stood down when it took the bye"
say "OK" "the watcher took the cancel while it was still the holder (line $BYE_LINE)"
[ "$(grep -c 'is calling -- opening Kin' "$SP/a-watch.log")" = 1 ] \
  && say "OK" "and opened no second window for it -- a hang-up is not a doorbell" \
  || say "FAIL" "the watcher opened a window for a bye"
kill -9 "$APID" 2>/dev/null
reap

TREEA=$(grep -m1 "card=" "$SP/a-copy.log" | tail -1)
[ "$A_ALIVE" = "no" ] \
  && say "OK" "the copy that was launched to ask is gone" \
  || say "FAIL" "it is STILL RINGING a call that was cancelled 16 s ago: ${TREEA:-<no card dump>}"
grep -q "cancel: @$H1 called it off" "$SP/a-copy.log" \
  && say "OK" "and it says how it found out: the watcher left the message" \
  || say "FAIL" "nothing told the launched copy the call was off"

# ── ARM B: THE SAME CANCEL, TEN SECONDS LATER ───────────────────────────────
#
# The opposite ranking. By now the launched copy holds the line and the watcher
# has stood down, so the bye goes straight to the copy over the network -- the
# path that has always worked. An arm A that could not be told apart from this
# would be measuring the doorbell, not the race.
echo "── B. CONTROL: the same cancel, after the launched copy is listening"
startwatcher "$SP/b-watch.log" "$SP/b-copy.log" 0 || cannot "the watcher never came up (B)"
RB=$(ring "$ID1" "$SP/b-ring.log")
[ -n "$RB" ] || cannot "the caller could not ring (B)"
waitfor "$SP/b-watch.log" "is calling -- opening Kin" 20 || cannot "no window opened (B)"
waitfor "$SP/b-watch.log" "standing by" 20 \
  || cannot "the watcher never stood down, so this is not the late path"
nap 6
BPID=$(copypid "$SP/b-copy.log")
[ -n "$BPID" ] || cannot "the launched copy wrote no log (B)"
LAUNCHED="$LAUNCHED $BPID"
# It really is ringing, and the card really is a card: `?` hit-tests every
# control on screen from the content view down, the way a click arrives.
TREEB=$(grep -m1 "card=" "$SP/b-copy.log" | tail -1)
echo "     ringing card: ${TREEB:-<nothing>}"
case "$TREEB" in
  *card=ringing*) say "OK" "it is ringing, with the card up" ;;
  *) say "FAIL" "the card is [$(echo "$TREEB" | sed 's/.*card=\([a-zA-Z]*\).*/\1/')] before the cancel" ;;
esac
# ── THE BUTTON A FINGER WOULD LAND ON ──────────────────────────────────────
# `?` hit-tests every control on screen from the content view down, the way a
# click arrives, and reports OK, SELF or FAIL. SELF is the ring card's own
# documented answer -- it claims its own bounds and routes by frame in
# `mouseDown` -- so the assertion is "not FAIL", which is the verdict that means
# a person could not have pressed it.
ANSWERHIT=$(grep -E "^audit (OK|SELF|FAIL) +answer at" "$SP/b-copy.log" | head -1)
echo "     answer button: ${ANSWERHIT:-<never hit-tested>}"
case "$ANSWERHIT" in
  "audit OK"*|"audit SELF"*) say "OK" "and a finger could have reached the answer button" ;;
  *) say "FAIL" "the answer button was not reachable, so nothing was really being asked" ;;
esac
TK_KIN_DIR="$ID1" "$TK" --bye-only "$H2" --room "$RB" --no-update > "$SP/b-bye.log" 2>&1
grep -q "bye-only: told @$H2" "$SP/b-bye.log" || cannot "the cancel was never sent (B)"
nap 8
B_ALIVE=no; alive "$BPID" && B_ALIVE=yes
kill -9 "$BPID" 2>/dev/null
reap
[ "$B_ALIVE" = "no" ] \
  && say "OK" "a late cancel still takes the ring down" \
  || say "FAIL" "the late cancel did not stop the ring either -- the doorbell is broken, not the race"
grep -q "bye: @$H1 stopped calling" "$SP/b-copy.log" \
  && say "OK" "and it heard it itself, over the doorbell" \
  || say "FAIL" "the copy never heard the cancel it was polling for"
grep -q "cancel: @$H1 called it off" "$SP/b-copy.log" \
  && say "FAIL" "it took the local handoff on the late path -- the two arms are the same arm" \
  || say "OK" "CONTROL: no local handoff was involved, so A and B are different paths"

# ── ARM C: THE HANDOFF MUST NOT BE A WAY TO END SOMEBODY'S CALL ─────────────
#
# The note is a file in the identity directory, which is the directory holding
# the Ed25519 seed: anyone who can write one can already BE this install. So the
# threat it has to survive is not forgery, it is a note that is about some other
# call, or about this one an hour ago. Each is planted at a live ring, and each
# must be consumed and ignored -- consumed, because "the ring kept going" is also
# what a reader that never ran looks like.
echo "── C. a note that is not about this call, and one that is too old"
startwatcher "$SP/c-watch.log" "$SP/c-copy.log" 0 || cannot "the watcher never came up (C)"
RC=$(ring "$ID1" "$SP/c-ring.log")
[ -n "$RC" ] || cannot "the caller could not ring (C)"
waitfor "$SP/c-watch.log" "is calling -- opening Kin" 20 || cannot "no window opened (C)"
nap 6
CPID=$(copypid "$SP/c-copy.log")
[ -n "$CPID" ] || cannot "the launched copy wrote no log (C)"
LAUNCHED="$LAUNCHED $CPID"
alive "$CPID" || cannot "the copy was already gone before anything was planted (C)"

plant "$RC" "someoneelse" "$(nowms)"
nap 2
C1_FILE=no; [ -f "$(notefile "$RC")" ] && C1_FILE=yes
C1_ALIVE=no; alive "$CPID" && C1_ALIVE=yes
[ "$C1_FILE" = "no" ] \
  && say "OK" "a note naming a different caller was read and thrown away" \
  || say "FAIL" "nothing ever read the note -- the two claims below prove nothing"
[ "$C1_ALIVE" = "yes" ] \
  && say "OK" "and the ring is untouched by it" \
  || say "FAIL" "a note from somebody else ended this ring"

plant "$RC" "$H1" "$(( $(nowms) - 300000 ))"
nap 2
C2_FILE=no; [ -f "$(notefile "$RC")" ] && C2_FILE=yes
C2_ALIVE=no; alive "$CPID" && C2_ALIVE=yes
[ "$C2_FILE" = "no" ] \
  && say "OK" "a five-minute-old note was read and thrown away too" \
  || say "FAIL" "the stale note was never read"
[ "$C2_ALIVE" = "yes" ] \
  && say "OK" "and it did not end the ring either" \
  || say "FAIL" "a note older than a ring's whole lease ended this ring"

plant "$RC" "$H1" "$(nowms)"
nap 3
C3_ALIVE=no; alive "$CPID" && C3_ALIVE=yes
kill -9 "$CPID" 2>/dev/null
reap
[ "$C3_ALIVE" = "no" ] \
  && say "OK" "CONTROL: the same note, current and from the right caller, stops it" \
  || say "FAIL" "a good note did nothing, so the two refusals above are a wall, not a guard"

[ "$fail" = "0" ] && echo "CANCEL-RACE CHECK: PASS" \
                  || echo "CANCEL-RACE CHECK: FAIL -- logs in $SP (KEEP=1 to keep them)"
exit "$fail"
