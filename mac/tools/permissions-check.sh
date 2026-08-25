#!/bin/bash
# ── DOES THE PERMISSIONS PANEL KNOW ANYTHING, OR IS IT JUST OPTIMISTIC? ──────
#
# The user's report was that Kin sends people hunting: "not that they have to find
# the setting in the setting in the setting." The fix is a status reader and a
# `reveal` that opens the exact pane. Both halves have a way of being finished and
# useless, and this rig exists for those two ways.
#
#   1. A READER THAT ALWAYS SAYS YES. On the machine this was written on, most of
#      what Kin needs is already granted, so a status check prints "granted" down
#      the page and passes -- and a reader whose switch collapsed every case to
#      `.granted` prints exactly the same page and passes exactly as well. That is
#      `green-metrics-can-hide-defects` with a permissions panel attached. So no
#      claim below is made from a single arm: every state is asserted against
#      ANOTHER arm that has to come out differently, and the two that matter most
#      -- denied and restricted -- differ only in whether there is a button, which
#      is the discrimination a collapsed reader cannot fake.
#
#   2. A URL THAT SILENTLY OPENS THE TOP OF SYSTEM SETTINGS. This is the failure
#      wearing the fix's clothes, and nothing in the process can see it:
#      `NSWorkspace.open` returns true and `open(1)` exits 0 for a pane identifier
#      macOS no longer knows. It was therefore measured BY HAND, once, on macOS
#      27.0 (26A5421a), by opening each URL with `open -g` -- background, so
#      nothing was taken from the person using this Mac -- forcing System Settings
#      onto a different pane first so "did not move" could be told from "moved",
#      and reading the window title back:
#
#          ?Privacy_Camera        -> "Camera"            (and Kin is in the list)
#          ?Privacy_Microphone    -> "Microphone"
#          LoginItems-Settings    -> "Login Items"
#          ?Privacy_LocalNetwork  -> "Privacy & Security"   <- THE TOP LEVEL
#
#      What this script does is keep those strings from rotting afterwards. It
#      DOES NOT OPEN ANYTHING: a Settings window thrown at whoever is sitting at
#      this Mac is not an acceptable price for a test, and an automated rig has no
#      way to read where a window landed anyway. It asserts the URLs are still the
#      measured ones, and that the one which was measured NOT to land still admits
#      it in the API rather than claiming a pane it cannot reach.
set -u
# Nothing here opens a window, but the flag costs nothing and the day somebody
# adds an arm that does is the day they will not remember to add it.
export TK_NO_RAISE=1
PIDS=""
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
# Bounded, because `wait` on a wedged child hangs the rig forever and a rig that
# hangs is a rig people stop running. These arms exit in well under a second.
await() {
  local p="$1" limit="$2" spins=0
  while kill -0 "$p" 2>/dev/null; do
    perl -e 'select undef,undef,undef,0.1'
    spins=$((spins + 1))
    if [ "$spins" -gt $((limit * 10)) ]; then kill -9 "$p" 2>/dev/null; return 124; fi
  done
  wait "$p" 2>/dev/null
}
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/permissions-check.$$"
mkdir -p "$SP"
# ── ITS OWN EVERYTHING ──────────────────────────────────────────────────────
#
# TK_KIN_DIR because `.applicationSupportDirectory` resolves through the user
# record and not $HOME, so a rig without it reads and writes the REAL install's
# identity. TK_WATCH_LABEL for the same reason one level down: `ringWhenClosed`
# asks launchd about a label, and a label is global to the login session -- this
# rig has no business even LOOKING at the login item a person depends on to be
# reachable. Both are the standing rule here after
# `rig-isolation-that-does-not-isolate`.
export TK_KIN_DIR="$SP/id"
export TK_WATCH_LABEL="com.tokkah.tk.watch.permcheck.$$"
mkdir -p "$SP/id"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT

# ── THE ARMS ────────────────────────────────────────────────────────────────
#
# One live, four with a substituted OS answer. TK_PERM_FAKE replaces exactly one
# line -- the `AVCaptureDevice.authorizationStatus` call -- and everything the
# arms are judged on downstream (the state mapping, the sentence, the button
# words, the blocking verdict, the URL) is the shipping code. It does not prove
# the syscall is real; the LIVE arm is what covers that, and it is allowed to
# print anything at all, because a rig whose verdict depends on the host's TCC
# database is a rig that fails on somebody else's Mac for no reason.
capture() { # capture <logname> <TK_PERM_FAKE or empty> [extra env assignment]
  local log="$SP/$1.log" fake="${2:-}" anywhere="${3:-}"
  TK_PERM_FAKE="$fake" TK_WATCH_ANYWHERE="$anywhere" "$TK" --permissions --mute > "$log" 2>&1 &
  LAST_PID=$!
  PIDS="$PIDS $LAST_PID"
  await "$LAST_PID" 20
}
capture live      ""
capture granted   "camera=granted,microphone=granted"
capture denied    "camera=denied,microphone=denied"
capture notasked  "camera=notAsked,microphone=notAsked"
capture strict    "camera=restricted,microphone=restricted"
# The non-TCC row has two real branches and no fake at all: with Kin outside
# Applications macOS cannot keep a login item for it, and TK_WATCH_ANYWHERE is the
# product's own override for that check. Two live reads of `Watch.reach`, which
# have to say different things.
capture placed    "" "1"
reap

# ── A FLAG THAT DOES NOTHING QUIETLY IS THE OLDEST BUG HERE ─────────────────
#
# Three A/Bs in this project compared an arm against itself because a flag was
# never registered and was ignored in silence. `--permissions` must be IN
# KNOWN_FLAGS (exit 0), and a near miss must be refused (exit 2). Asserting only
# the first would pass for a build where every unknown flag is accepted.
"$TK" --permissions --mute > /dev/null 2>&1; RC_KNOWN=$?
"$TK" --permissons  --mute > /dev/null 2>&1; RC_TYPO=$?
# And the second token, on the path that refuses rather than the path that opens a
# window. `--permissions-open <nonsense>` names the four things it accepts and
# exits 2 without touching System Settings, which is the only part of `reveal`
# that can be exercised without taking the screen from somebody.
"$TK" --permissions-open nonsense --mute > "$SP/badname.log" 2>&1; RC_BADNAME=$?

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }

# ── COULD IT RUN AT ALL ─────────────────────────────────────────────────────
for ln in live granted denied notasked strict placed; do
  n=$(grep -c '^permission ' "$SP/$ln.log" 2>/dev/null || true)
  [ "${n:-0}" = "4" ] || {
    echo "PERMISSIONS CHECK COULD NOT RUN -- arm '$ln' printed ${n:-0} permission lines, wanted 4:"
    sed -n '1,6p' "$SP/$ln.log" 2>/dev/null | sed 's/^/  /'
    exit 2
  }
done

# One need's line from one arm, and the fields off it. `action`, `landing` and
# `says` all contain spaces, so each is cut at the NEXT key rather than at
# whitespace -- a `grep -o "action=[^ ]*"` reads "Turn on Camera" as "Turn", which
# is an assertion that passes on half a string.
pline() { grep "^permission $2 " "$SP/$1.log"; }
state() { pline "$1" "$2" | sed -e 's/.*state=//'   -e 's/ .*//'; }
block() { pline "$1" "$2" | sed -e 's/.*blocking=//' -e 's/ .*//'; }
land()  { pline "$1" "$2" | sed -e 's/.*landing=//' -e 's/ url=.*//'; }
urlof() { pline "$1" "$2" | sed -e 's/.*url=//'     -e 's/ action=.*//'; }
act()   { pline "$1" "$2" | sed -e 's/.*action=//'  -e 's/ says=.*//'; }
sez()   { pline "$1" "$2" | sed -e 's/.*says=//'; }

echo
echo "── the reader can tell four answers apart ──"
# ── 1. THE ANTI-CONSTANT ASSERTION ──────────────────────────────────────────
#
# The whole point. Four arms whose only difference is the answer macOS gives, and
# the four states must come out distinct. A reader that always says `granted` --
# or always says anything -- collapses these into one and fails here.
for a in granted denied notasked strict; do
  case "$a" in
    granted)  want=granted;;
    denied)   want=denied;;
    notasked) want=notAsked;;
    strict)   want=restricted;;
  esac
  got="$(state "$a" camera)"
  [ "$got" = "$want" ] \
    && say "OK" "camera reads '$want' when macOS says so" \
    || say "FAIL" "camera read [$got] when macOS said $want"
done
STATES=$(for a in granted denied notasked strict; do state "$a" camera; done | sort -u | wc -l | tr -d ' ')
[ "$STATES" = "4" ] \
  && say "OK" "and the four are DISTINCT -- the reader is not returning a constant" \
  || say "FAIL" "the four answers collapsed into $STATES distinct state(s)"
# The same reader, driven from the other media type, so a camera-only mapping
# cannot pass this file.
[ "$(state denied microphone)" = "denied" ] && [ "$(state granted microphone)" = "granted" ] \
  && say "OK" "and the microphone ranks the same two ways, not just the camera" \
  || say "FAIL" "the microphone did not track the answer it was given"

echo
echo "── and it ranks them the opposite way round ──"
# ── 2. THE VERDICT, NOT JUST THE LABEL ──────────────────────────────────────
#
# `blocking` is what a panel draws on. Reading the state right and then judging it
# wrong is a live failure mode -- it is one `!` away at all times -- so the verdict
# is asserted separately, in both directions.
[ "$(block denied camera)" = "true" ] \
  && say "OK" "a denied camera is reported as standing in the way" \
  || say "FAIL" "a denied camera was not reported as blocking"
[ "$(block granted camera)" = "false" ] \
  && say "OK" "CONTROL: a granted camera is not -- so the verdict discriminates" \
  || say "FAIL" "a granted camera was reported as blocking; the verdict is stuck on"
# notAsked is the one a naive implementation gets wrong in the OTHER direction: it
# is not granted, so it looks like a problem, and nagging somebody about a dialog
# macOS has not shown yet is how a panel becomes something people close.
[ "$(block notasked camera)" = "false" ] \
  && say "OK" "and a permission macOS has not asked about yet is not nagged about" \
  || say "FAIL" "it nags about a dialog that has not happened"
[ "$(sez notasked camera)" != "$(sez granted camera)" ] \
  && say "OK" "though it still says something different from granted" \
  || say "FAIL" "notAsked and granted produce the same sentence -- one of them is wrong"

echo
echo "── a button only where a button would help ──"
# ── 3. RESTRICTED IS NOT DENIED ─────────────────────────────────────────────
#
# The sharpest discriminator in the file, and the reason `restricted` is not
# folded into `denied` for convenience. Both block the call. Only one of them has
# a switch this person is allowed to move: under a restriction the pane opens onto
# a control that is greyed out, so a button there sends somebody to look at proof
# they are stuck. Same blocking verdict, opposite action.
[ "$(act denied camera)" != "-" ] \
  && say "OK" "denied offers a button: \"$(act denied camera)\"" \
  || say "FAIL" "denied offers no way to fix it"
[ "$(act strict camera)" = "-" ] \
  && say "OK" "restricted offers none -- the switch exists and they cannot move it" \
  || say "FAIL" "restricted offered a button [$(act strict camera)] for a control they cannot touch"
[ "$(block strict camera)" = "true" ] \
  && say "OK" "CONTROL: and restricted still blocks, so it is not being ignored" \
  || say "FAIL" "restricted was treated as fine"
[ "$(sez denied camera)" != "$(sez strict camera)" ] \
  && say "OK" "and the two say different things to the person" \
  || say "FAIL" "denied and restricted read identically"

echo
echo "── the URLs that were measured landing ──"
# ── 4. THE STRINGS, PINNED ──────────────────────────────────────────────────
#
# Not a test that they work -- nothing automated can test that, which is the whole
# problem with this class of bug. A record of what was verified by hand, placed
# where an edit trips over it.
CAMU="x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera"
MICU="x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
LOGU="x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
[ "$(urlof live camera)" = "$CAMU" ] \
  && say "OK" "camera  -> ?Privacy_Camera      (measured: landed on \"Camera\", Kin in the list)" \
  || say "FAIL" "camera URL is [$(urlof live camera)] -- changed, and nobody re-measured it"
[ "$(urlof live microphone)" = "$MICU" ] \
  && say "OK" "mic     -> ?Privacy_Microphone  (measured: landed on \"Microphone\")" \
  || say "FAIL" "microphone URL is [$(urlof live microphone)] -- changed, and nobody re-measured it"
[ "$(urlof live ringWhenClosed)" = "$LOGU" ] \
  && say "OK" "ringing -> LoginItems-Settings  (measured: landed on \"Login Items\")" \
  || say "FAIL" "login items URL is [$(urlof live ringWhenClosed)]"
[ "$(land live camera)" = "exact:Camera" ] \
  && say "OK" "and the camera row claims an EXACT landing, which is what was seen" \
  || say "FAIL" "the camera row claims [$(land live camera)]"

echo
echo "── and the one that does not land says so ──"
# ── 5. THE HONEST NEGATIVE ──────────────────────────────────────────────────
#
# Local Network has no anchor on this macOS. Privacy_LocalNetwork,
# privacy-localnetwork, Privacy_LocalNetworkService, LocalNetwork and
# Privacy_Network were all tried and all five opened the top of Privacy &
# Security; the pane's own binary contains no such string while it does contain
# Privacy_Camera and Privacy_Microphone. A row that claimed `exact` for it would
# be the original complaint shipped as its own fix, so the API has to admit it.
[ "$(land live localNetwork)" = "nearby:Privacy & Security" ] \
  && say "OK" "local network admits it lands NEARBY (\"Privacy & Security\"), not on a pane of its own" \
  || say "FAIL" "local network claims [$(land live localNetwork)] -- it was measured not to land"
[ "$(state live localNetwork)" = "cannotTell" ] \
  && say "OK" "and it says it cannot read the answer rather than assuming one" \
  || say "FAIL" "local network claims to know its state [$(state live localNetwork)]; macOS publishes no such API"
[ "$(block live localNetwork)" = "false" ] \
  && say "OK" "and does not report a problem it cannot see" \
  || say "FAIL" "an unreadable permission was reported as blocking"

echo
echo "── the row that is not a TCC permission at all ──"
# ── 6. TWO LIVE BRANCHES, NO FAKE ───────────────────────────────────────────
[ "$(state live ringWhenClosed)" = "denied" ] \
  && say "OK" "a copy outside Applications cannot be rung when closed" \
  || say "FAIL" "ringWhenClosed read [$(state live ringWhenClosed)] for a copy in a build tree"
[ "$(sez live ringWhenClosed)" != "$(sez placed ringWhenClosed)" ] \
  && say "OK" "CONTROL: and it says something ELSE once the copy is placed" \
  || say "FAIL" "both branches of Watch.reach produced the same sentence -- it is not being read"
case "$(sez placed ringWhenClosed)" in
  *"only rings while"*) say "OK" "naming the real reason: it only rings while Kin is open";;
  *) say "FAIL" "the placed branch said [$(sez placed ringWhenClosed)]";;
esac

echo
echo "── the flag is registered, and a near miss is refused ──"
[ "$RC_KNOWN" = "0" ] \
  && say "OK" "--permissions is in KNOWN_FLAGS and exits 0" \
  || say "FAIL" "--permissions exited $RC_KNOWN; an unregistered flag exits 2 and does nothing"
[ "$RC_TYPO" = "2" ] \
  && say "OK" "CONTROL: --permissons is refused (exit 2), so the guard is not waving flags through" \
  || say "FAIL" "a misspelled flag exited $RC_TYPO -- silent no-op flags have cost this project three A/Bs"
[ "$RC_BADNAME" = "2" ] \
  && say "OK" "--permissions-open refuses a name it has no pane for, without opening a window" \
  || say "FAIL" "--permissions-open <nonsense> exited $RC_BADNAME"
grep -q "camera, microphone, localNetwork, ringWhenClosed" "$SP/badname.log" \
  && say "OK" "and lists the four it does accept, rather than only complaining" \
  || say "FAIL" "it refused without saying what it accepts"

echo
if [ "$fail" = 0 ]; then
  echo "PERMISSIONS CHECK PASSED -- the reader tells four answers apart, and every"
  echo "  URL is the one measured landing on its pane (local network says it cannot)."
else
  echo "PERMISSIONS CHECK FAILED -- see above; logs in $SP"
  for ln in live granted denied notasked strict placed; do
    cp "$SP/$ln.log" "${SCRATCH:-${TMPDIR:-/tmp}}/permissions-$ln.log" 2>/dev/null
  done
fi
exit $fail
