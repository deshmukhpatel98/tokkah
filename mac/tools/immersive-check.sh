#!/bin/bash
# ── DOES THE CALL EVER BECOME JUST THE OTHER PERSON'S FACE? ──────────────────
#
# Asked for in these words: "while the call is on, like two people are doing the
# video call, all the controls should fade away. Except subtitles only. And they
# should only come back when there is a touch of a mouse or a keyboard or
# something like that. And they will again fade away in two to three seconds. So
# it's truly immersive."
#
# Most of the timer was already here. What was not is the half that decides
# whether the feature is a feature or a trap:
#
#     bar-tap: the row was HIDDEN when the click landed -- hit=CallControls
#              mic on->on row now shown
#
# `alphaValue` is a drawing property and AppKit's hit testing has no opinion
# about it, so for as long as the fade was only opacity the row was invisible and
# fully armed -- five circles nobody can see, with the hang-up in the middle of
# them, over the other person's face. That line is this rig's whole reason to
# exist, and every arm below is paired with one that has to rank the other way.
#
# Seven claims, in the order the sections below make them. The fourth is the one
# a broken fix passes the first three of:
#   1. on a real connected call the row is there, and then it goes -- and on a
#      window with nobody in it, never
#   2. a real click brings it back
#   3. and it goes AGAIN -- one-shot is not the feature
#   4. an invisible control is not clickable, and pressing where one used to be
#      wakes the row instead of firing it
#   5. it does NOT go mid-decision: panel open, finger down, hang-up armed
#   6. it does NOT go while the waiting card is the only way off the screen
#   7. the subtitles are not controls and never move
set -u
# Ring windows do not throw themselves in front of whatever the person at this
# Mac is doing, and neither may this. Every copy below is also `--mute`: the
# speakers belong to whoever is sitting here.
export TK_NO_RAISE=1
# ── KILLS ONLY WHAT THIS SCRIPT STARTED ─────────────────────────────────────
#
# Never `pkill -f`, which takes a REGEX: in a path like `./.build/debug/tk` every
# `.` matches any character, and that pattern has reaped another agent's
# processes in another checkout for hours. A rig may only end processes it
# started, by pid.
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/immersive-check.$$"
mkdir -p "$SP"
# `.applicationSupportDirectory` resolves through the user record and not $HOME,
# so a rig without this reads and writes the REAL install's contact list and
# identity. And no identity at all: a claim walks @devesh, @deveshp, @devesh2 on
# the real server, squatting names a person may want.
export TK_KIN_DIR="$SP/id"
export TK_NO_IDENTITY=1
mkdir -p "$SP/id"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT

# ── ONE SECOND OF STILLNESS, NOT TWO AND A HALF ─────────────────────────────
#
# `TK_IMMERSIVE_MS` is the product's own cadence with a rig override on it, the
# same move `TK_RING_TIMEOUT` and `TK_LEAVE_HOLD_MS` make. The number is not
# arbitrary: `--press` steps are 700 ms apart, so the stillness has to be LONGER
# than one step -- or the `?` straight after a press already reads hidden and
# "input brings it back" can never be observed -- and SHORTER than two, or the
# `?` after that has not faded yet and "it goes again" can never be observed.
# 1000 ms is the middle of the only window this harness can see.
STILL=1000

# ── WHAT THE ROW DID, IN ORDER, AS ONE STRING ───────────────────────────────
#
# One letter per `?`, and the token names in angle brackets between them, so the
# whole run reads as a sentence and an assertion can be about a SEQUENCE rather
# than about whichever audit line happened to be last. A per-line grep cannot
# tell "it faded and came back" from "it never faded".
#
#   W  before the call        S  shown, and free to fade
#   H  faded away             C  held up by the waiting card
#   P  held up by the panel   D  held up by a finger on a button
#   A  held up by an empty room   L  by a half-confirmed hang-up   T  by a caret
#
# ── AND A STRAY `S` IS A PERSON, NOT A DEFECT ───────────────────────────────
#
# These windows open wherever macOS puts them, and somebody is usually using this
# Mac: a pointer crossing one of them is real input and the row comes back, which
# is the whole feature. So every arm that says "it fades" asks for an `H`
# ANYWHERE in its stretch rather than at a fixed step, and every arm that says
# "it does not fade" is immune to the same event by construction -- a stray nudge
# can only ever push toward shown, which is what those already expect.
trace() {
  awk '
    /^press [^ ]+: due at/ { t=$2; sub(/:$/, "", t); if (t != "?") printf "<%s>", t; next }
    /^audit state / {
      match($0, /bar=[^ ]+/); b = substr($0, RSTART+4, RLENGTH-4)
      if      (b == "shown")             printf "S"
      else if (b == "hidden")            printf "H"
      else if (b == "shown/held:notyet") printf "W"
      else if (b == "shown/held:card")   printf "C"
      else if (b == "shown/held:alone")  printf "A"
      else if (b == "shown/held:panel")  printf "P"
      else if (b == "shown/held:leaving") printf "L"
      else if (b == "shown/held:held")   printf "D"
      else if (b == "shown/held:typing") printf "T"
      else printf "{%s}", b
      next
    }
    END { printf "\n" }
  ' "$1"
}

# ── AND WHAT A FINGER COULD HAVE REACHED, AT EACH OF THOSE MOMENTS ──────────
#
# `?` runs the hit-test audit over `clickTargets` and then prints the state, in
# that order, so the audit lines belong to the state line that follows them.
# Pairing them here is what turns "the bar is invisible" into the stronger claim
# the feature actually makes: there was nothing on screen to press.
targets() {
  awk '
    /^audit (OK|FAIL|SELF)/ { n++; names = names " " $3; next }
    /^audit state / {
      match($0, /bar=[^ ]+/); b = substr($0, RSTART+4, RLENGTH-4)
      print b "|" n "|" names; n = 0; names = ""
    }
  ' "$1"
}

# ── PART ZERO: A WINDOW WITH NOBODY IN IT KEEPS ITS CONTROLS ────────────────
#
# One process, no peer, nothing to connect to. "Before the call the screen is
# your own mirror and one button, and hiding the controls there just makes the
# app look broken" -- so this is the arm that ranks the other way for the whole
# of part one: an app that faded from the first frame would satisfy every timing
# assertion below and be worse than one that never faded at all.
#
# Its own part rather than the first seconds of part one, because the two ends
# below have connected in under three seconds and in over eight, and an arm whose
# validity depends on which of those happened is not an arm.
spawn env TK_IMMERSIVE_MS="$STILL" "$TK" --window --room "imchk${$}z" --listen 8081 \
      --video off --mute --no-telemetry --no-update --no-relocate --no-rings \
      --no-subtitles --press-after 3 --press "?,?,?,?,?,?,?,?" > "$SP/z.log" 2>&1
perl -e 'select undef,undef,undef,11'
reap

# ── PART ONE: one connected call, and everything that happens on it ─────────
#
# Two real processes, because "the call is connected and the other person is
# here" is the entire precondition for the fade and there is no way to fake it
# from one. A joins and does nothing; B is the one being watched.
#
# The token sequence is a story, and the `?`s between the acts are what make it
# one. Read with --press-after 3 and 700 ms a step:
#
#   before, during and after the connection -- W then S then H
#   a real click at the invisible mute button
#   `fade`, the token that puts the row where the timer would
#   a press-and-hold
#   a half-confirmed hang-up
#   the settings panel -- and, while it holds the row up, a caption
#   the panel closed again, and the same caption with the row free to go
#   the same click as before, with the row shown: the control arm
#
# ── AND EVERY HELD STATE HAS TO OUTLIVE A STALL ─────────────────────────────
#
# `@peek:5` and not `@peek:2.5`. The fade timer is a `.default`-mode timer, so it
# fires when the main thread next gets a turn -- and these presses have been
# measured queueing 1228 ms behind their own deadlines while the sheet shelled
# out to check the login item. Twice in one run the only free turn inside a 2.5 s
# hold fell outside it, so the timer never came for the row at all and "it was
# refused" was a claim about an event that had not happened. Five seconds is
# longer than any stall seen here.
#
# ── AND THE HANG-UP HAS TO OUTLIVE ITS OWN PIN ──────────────────────────────
#
# `TK_LEAVE_HOLD_MS` is here for one reason. Arming the pill pins the row for
# `barPin`, and the pill forgets itself after `max(3, hold * 5)` -- so at the
# shipped 600 ms hold the pin OUTLASTS the arm, the fade timer never fires while
# it is armed, and an assertion about `held:leaving` would pass over a check that
# is not there. Three seconds of hold makes the arm 15 s and the pin 3.85 s, so
# the timer fires four times inside the armed window and has to refuse each one.
R1="imchk${$}a"
spawn "$TK" --window --room "$R1" --listen 8081 --peer 127.0.0.1:8082 --video off \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      > "$SP/a.log" 2>&1
spawn env TK_IMMERSIVE_MS="$STILL" TK_LEAVE_HOLD_MS=3000 "$TK" --window --room "$R1" \
      --listen 8082 --peer 127.0.0.1:8081 --video off \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --press-after 3 \
      --press "?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,blind-tap,?,?,?,?,fade,?,?,?,@peek:5,?,?,?,?,?,?,?,?,?,?,?,?,leave,?,?,?,?,?,?,?,?,?,unleave,?,?,?,?,@more,?,?,?,?,said,mine,?,?,esc,?,?,?,?,said,mine,?,?,?,?,?,sighted-tap,?,?" \
      > "$SP/b.log" 2>&1
perl -e 'select undef,undef,undef,88'
reap

# ── PART TWO: the other person leaves ───────────────────────────────────────
#
# The waiting card is the only way off that screen -- it holds the invite link
# and every button that could start another call -- so the row may not fade
# behind it. The same process proves both halves: it has to have faded during
# the call, or "it did not fade after the departure" is a sentence about a
# feature that never worked.
#
# A is killed rather than asked to leave, which is the case that could not be
# detected at all before `setPeerPresent`: no goodbye, just silence.
DOTS="?"
for _ in $(seq 2 51); do DOTS="$DOTS,?"; done
R2="imchk${$}b"
spawn "$TK" --window --room "$R2" --listen 8081 --peer 127.0.0.1:8082 --video off \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      > "$SP/c.log" 2>&1
A2=$LAST_PID
spawn env TK_IMMERSIVE_MS="$STILL" "$TK" --window --room "$R2" --listen 8082 \
      --peer 127.0.0.1:8081 --video off \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --press-after 3 --press "$DOTS" > "$SP/d.log" 2>&1
perl -e 'select undef,undef,undef,14'
{ kill -9 "$A2"; wait "$A2"; } 2>/dev/null
perl -e 'select undef,undef,undef,26'
reap

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }
for f in z a b c d; do
  grep -q "^tk " "$SP/$f.log" || {
    echo "IMMERSIVE CHECK COULD NOT RUN -- tk never started in $f:"
    sed -n '1,6p' "$SP/$f.log" | sed 's/^/  /'; exit 2; }
done
for f in b d; do
  grep -q "connected via" "$SP/$f.log" || {
    echo "IMMERSIVE CHECK COULD NOT RUN -- the two ends never connected in $f."
    echo "  Every claim below is about a CONNECTED call; without one there is nothing to test."
    exit 2; }
done

T0="$(trace "$SP/z.log")"
T1="$(trace "$SP/b.log")"
T2="$(trace "$SP/d.log")"
echo "  what the row did, in order:"
echo "    part zero $T0"
echo "    part one  $T1"
echo "    part two  $T2"
echo

# ── 1. IT IS THERE, AND THEN IT IS NOT ──────────────────────────────────────
echo "── 1. on a connected call the row is there, and then it goes"
case "$T0" in
  W*) case "$T0" in
        *H*) say "FAIL" "a window with nobody in it faded its controls away: [$T0]" ;;
        *)   say "OK" "CONTROL: with nobody on the call the controls never move (held:notyet)" ;;
      esac ;;
  *) say "FAIL" "the waiting window did not report itself as pre-call: [$T0]" ;;
esac
PRE="${T1%%<*}"
BEFORE_H="${PRE%%H*}"
case "$PRE" in *H*) HID=yes ;; *) HID=no ;; esac
case "$BEFORE_H" in
  *S*) say "OK" "the call connects and the row is SHOWN first" ;;
  *)   say "FAIL" "the row was never shown-and-free between connecting and fading: [$PRE]" ;;
esac
[ "$HID" = yes ] \
  && say "OK" "and then it faded away on its own" \
  || say "FAIL" "it never faded at all on a connected call: [$PRE]"

# ── 2 and 3. A CLICK BRINGS IT BACK, AND IT GOES AGAIN ──────────────────────
#
# Two different instruments, because they are two different claims. That it CAME
# BACK is the token's own line -- it read the row at the instant of the press and
# again after it, so no sampling can miss it. That it WENT AGAIN can only be seen
# by watching afterwards, and one `H` anywhere in the stretch before the next act
# is the whole of it: one-shot never gets there at all.
#
# Neither is a fixed `SH`. These presses queue -- measured at up to 1338 ms behind
# their own deadline while the main thread was busy -- so two audits can fall
# inside one stillness and read `SSH`, and a pointer crossing the window puts an
# `S` anywhere it likes. The ORDER is the claim; how many samples land either
# side of the fade is the harness's weather.
echo "── 2. a real click brings it back, and 3. it goes again"
BT="$(grep -m1 'bar-tap: the row was HIDDEN' "$SP/b.log")"
[ -n "$BT" ] && echo "     $BT"
case "$BT" in
  *"row now shown"*) say "OK" "a click on the invisible row brought the controls back" ;;
  *) say "FAIL" "a click on the invisible row did not bring it back" ;;
esac
BACK="${T1#*<blind-tap>}"; BACK="${BACK%%<*}"
case "$BACK" in
  *H*) say "OK" "and it faded AGAIN after the next stillness -- not one-shot [$BACK]" ;;
  *)   say "FAIL" "it came back and never went away again: [$BACK]" ;;
esac
FADE="${T1#*<fade>}"; FADE="${FADE%%<*}"
case "$FADE" in
  *H*) say "OK" "and \`--press fade\` puts it where the timer would, on demand [$FADE]" ;;
  *)   say "FAIL" "the fade token did nothing: [$FADE]" ;;
esac

# ── 4. AN INVISIBLE CONTROL IS NOT A CONTROL ────────────────────────────────
#
# Two claims, and the second is the one only a real click can make.
#
# `clickTargets` is documented as "only what is on screen right now", so while
# the row is faded it must name nothing -- an audit that lists five buttons a
# person cannot see is an instrument describing the code's intent instead of the
# screen. And the finger: the same click, at the same pixel, differing ONLY in
# what the row was doing. Muting on one and not the other is the whole test; if
# both arms rank the same way the click never reached anything.
echo "── 4. a faded control is not clickable"
BADT="$(targets "$SP/b.log" | grep '^hidden|' | grep -vc '|0|')"
GOODT="$(targets "$SP/b.log" | grep -c '^shown|.*mic')"
[ "${BADT:-1}" = "0" ] \
  && say "OK" "while faded, clickTargets names nothing at all" \
  || say "FAIL" "$BADT faded audits still offered buttons to press"
[ "${GOODT:-0}" -gt 0 ] \
  && say "OK" "CONTROL: while shown it names them ($GOODT audits list mic)" \
  || say "FAIL" "CONTROL: it never named the buttons even while shown -- this proves nothing"
case "$BT" in
  *"hit=CallControls"*) say "OK" "the click landed on the overlay, not on the mute button" ;;
  *) say "FAIL" "the click reached [$(printf '%s' "$BT" | sed -E 's/.*(hit=[^ ]*).*/\1/')]" ;;
esac
case "$BT" in
  *"mic on->on"*) say "OK" "and nothing was pressed -- the microphone is untouched" ;;
  *) say "FAIL" "the invisible mute button fired: $BT" ;;
esac
ST="$(grep -m1 'bar-tap: the row was SHOWN' "$SP/b.log")"
[ -n "$ST" ] && echo "     $ST"
case "$ST" in
  *"hit=IconButton"*"mic on->muted"*)
    say "OK" "CONTROL: the same click with the row shown DOES mute" ;;
  *) say "FAIL" "CONTROL: the same click did not mute even with the row shown -- both arms agree, so neither proves anything" ;;
esac

# ── 5. NOT WHILE SOMETHING IS OPEN, HELD, OR BEING DECIDED ──────────────────
echo "── 5. it does not fade mid-decision"
PANEL="${T1#*<@more>}"; PANEL="${PANEL%%<*}"
case "$PANEL" in
  P*) case "$PANEL" in
        *H*) say "FAIL" "the row faded with the settings panel open: [$PANEL]" ;;
        *)   say "OK" "with the panel open the row stays, and says why (held:panel) [$PANEL]" ;;
      esac ;;
  *) say "FAIL" "the panel never opened -- got [$PANEL]" ;;
esac
AFTER="${T1#*<esc>}"; AFTER="${AFTER%%<*}"
case "$AFTER" in
  *H*) say "OK" "CONTROL: the same call, panel closed, fades again [$AFTER]" ;;
  *)   say "FAIL" "CONTROL: it never faded after the panel closed, so 'held:panel' proves nothing" ;;
esac
HOLD="${T1#*<@peek:5>}"; HOLD="${HOLD%%<*}"
case "$HOLD" in
  D*) say "OK" "and a finger held on a button keeps it up too (held:held) [$HOLD]" ;;
  *)  say "FAIL" "a press-and-hold did not hold the row up: [$HOLD]" ;;
esac
grep -q "peek=true/held" "$SP/b.log" \
  && say "OK" "the hold really was in progress -- peek=true/held" \
  || say "FAIL" "nothing was ever held, so 'held:held' is describing a button nobody touched"
# ── AND THE ONE THAT COSTS A CALL IF IT IS WRONG ────────────────────────────
#
# The row must not vanish between the two clicks of a hang-up. `L` for four
# audits past the pin is the check firing; a pin alone would read `S`.
ARMED="${T1#*<leave>}"; ARMED="${ARMED%%<*}"
case "$ARMED" in
  L*H*) say "FAIL" "the row faded between the two clicks of a hang-up: [$ARMED]" ;;
  L*)   say "OK" "an armed hang-up holds the row up too (held:leaving) [$ARMED]" ;;
  *)    say "FAIL" "arming the hang-up did not hold the row up: [$ARMED]" ;;
esac
grep -q "leave=ARMED" "$SP/b.log" \
  && say "OK" "and the pill really was armed -- leave=ARMED" \
  || say "FAIL" "nothing was ever armed, so 'held:leaving' is describing an idle button"
# ── THE APP'S OWN ACCOUNT OF THE CHECK FIRING ───────────────────────────────
#
# The letters above say the row was up; this says the timer CAME FOR IT and was
# refused, by name. Without it a long-enough pin would produce the same picture,
# which is why `TK_LEAVE_HOLD_MS` is set on this process at all.
for why in panel held leaving; do
  grep -q "bar: staying up -- $why" "$SP/b.log" \
    && say "OK" "the fade timer fired during '$why' and refused" \
    || say "FAIL" "the timer never even fired during '$why' -- a pin could explain the whole arm"
done
DISARM="${T1#*<unleave>}"; DISARM="${DISARM%%<*}"
case "$DISARM" in
  *H*) say "OK" "CONTROL: and it fades once the hang-up is called off [$DISARM]" ;;
  *)   say "FAIL" "CONTROL: it never faded after the disarm, so 'held:leaving' proves nothing" ;;
esac
case "$HOLD" in
  *H*) say "OK" "CONTROL: and it fades once the finger comes off [$HOLD]" ;;
  *)   say "FAIL" "CONTROL: it never faded after the hold ended" ;;
esac

# ── 6. NOT WHILE THE WAITING CARD IS THE ONLY WAY OFF THIS SCREEN ───────────
#
# The card came back because somebody left without saying goodbye. Its buttons
# ARE the card -- the invite link, the name field, the handset -- so a fade here
# is a window with a dead frame in it and nothing on it at all.
echo "── 6. the waiting card keeps the controls"
case "$T2" in
  *C*) BEFORE_C="${T2%%C*}"; AFTER_C="${T2#*C}" ;;
  *)   BEFORE_C=""; AFTER_C="" ;;
esac
case "$T2" in
  *C*) say "OK" "the other person left and the row is held up by the card (held:card)" ;;
  *)   say "FAIL" "the card never came back in this run: [$T2]" ;;
esac
case "$BEFORE_C" in
  *H*) say "OK" "CONTROL: the SAME call faded while they were still here" ;;
  *)   say "FAIL" "CONTROL: it never faded before the departure either, so this proves nothing" ;;
esac
case "$AFTER_C" in
  *H*) say "FAIL" "and then it faded behind the card anyway: [$AFTER_C]" ;;
  *)   say "OK" "and it never faded again for the rest of the run" ;;
esac
grep -q "card=invite" "$SP/d.log" \
  && say "OK" "the card really is on screen -- card=invite, with the link on it" \
  || say "FAIL" "nothing shows a card, so 'held:card' is describing an empty screen"
grep -q "bar: staying up -- card" "$SP/d.log" \
  && say "OK" "and the fade timer came for it and was refused, by name" \
  || say "FAIL" "the timer never fired after the departure -- the row is up for some other reason"

# ── 7. THE SUBTITLES ARE NOT CONTROLS ───────────────────────────────────────
#
# "Except subtitles only." ONE audit has to show the row gone and the words still
# there in the same instant -- the two halves cannot be read off two different
# lines, because a caption that arrived after the fade would satisfy that and be
# the opposite of the claim.
#
# The control is the same caption with the row up, and it is driven while the
# settings panel is open ON PURPOSE. A caption expires on the speaker's own clock
# -- 2.2 s after they stop, 3 s for your own words -- and these presses queue by
# up to 1.3 s, so an arm that needs the row to still be shown when the audit
# lands is an arm that fails on a busy machine and says the subtitles broke. With
# the panel open the row is held up by something that is not a timer.
echo "── 7. the subtitles stay"
CAP='theirs="|mine="'
SUB="$(grep -oE 'audit state controls.*' "$SP/b.log" | grep 'bar=hidden' | grep -m1 -E "$CAP")"
if [ -n "$SUB" ]; then
  echo "     $(printf '%s' "$SUB" | sed -E 's/.*(row=\[[^]]*\]).*(bar=[^ ]*).*(theirs=.*)/\1  \2  \3/')"
  say "OK" "with the row gone the caption is still on screen, in the same audit"
  case "$SUB" in
    *"row=[]"*) say "OK" "and the row really was empty at that moment" ;;
    *) say "FAIL" "the row was not actually empty there: $SUB" ;;
  esac
  case "$SUB" in
    *"band=0%"*) say "FAIL" "the caption band had faded to nothing" ;;
    *) say "OK" "and the band is drawn, not merely remembered" ;;
  esac
else
  say "FAIL" "no audit ever showed a caption with the row faded away"
fi
SHOWNSUB="$(grep -oE 'audit state controls.*' "$SP/b.log" | grep 'bar=shown' | grep -cE "$CAP")"
[ "${SHOWNSUB:-0}" -gt 0 ] \
  && say "OK" "CONTROL: the same caption is there with the row shown, so the fade changed nothing about it" \
  || say "FAIL" "CONTROL: the caption was never seen with the row shown -- nothing to compare"

echo
if [ "$fail" = 0 ]; then
  echo "IMMERSIVE CHECK PASSED -- the call becomes the whole window, and comes back when you touch it"
else
  echo "IMMERSIVE CHECK FAILED -- see above; logs in $SP"
  for f in b d; do cp "$SP/$f.log" "${SCRATCH:-${TMPDIR:-/tmp}}/immersive-$f.log" 2>/dev/null; done
fi
exit $fail
