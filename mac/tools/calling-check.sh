#!/bin/bash
# ── DOES THE PERSON PLACING THE CALL KNOW THEY ARE PLACING A CALL? ───────────
#
# Placing a call re-execs into the room that was just minted. The process that
# sent the ring dies at `execv` and its successor knows only that it is alone in a
# room -- so it drew the ordinary waiting card, "Waiting for the other person…"
# over an invite link, pixel-identical to an app somebody had just opened and left
# alone. The user's words: "you don't know if you're calling or something
# crashed."
#
# Three claims are checked here, and all three are about the CALLER's window:
#   1. it says who is being rung, on the same card the callee sees, and it is
#      visibly alive rather than a frozen caption
#   2. when they answer, the card gets out of the way
#   3. when they never answer, it says so -- and the countdown that says so must
#      not still be running during a call that WAS answered, or it fires mid-call
#      and leaves that verdict on screen for the moment the other person steps away
#
# Real processes, real UDP. `TK_RING_TIMEOUT` compresses the product's 45 s so
# claim 3 can be proven in seconds.
set -u
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/calling-check.$$"
mkdir -p "$SP"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT

BASE="--mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles"

# ── PART ONE: they answer ───────────────────────────────────────────────────
# A is the caller. B joins 4 s in, which is what answering looks like from here.
# The ring timeout is 6 s, so it WOULD fire during the call if nothing cancelled
# it -- which is the point of the run.
R1="callchk$$a"
spawn env TK_RING_TIMEOUT=6 "$TK" --window --room "$R1" --listen 7995 --peer 127.0.0.1:7996 \
      --video off $BASE --calling meera --press-after 2 --press "?,~,~,~,?" > "$SP/a.log" 2>&1
perl -e 'select undef,undef,undef,4'
spawn "$TK" --room "$R1" --listen 7996 --peer 127.0.0.1:7995 --video off $BASE > "$SP/b.log" 2>&1
perl -e 'select undef,undef,undef,10'
reap

# ── PART TWO: they never answer ─────────────────────────────────────────────
R2="callchk$$b"
spawn env TK_RING_TIMEOUT=3 "$TK" --window --room "$R2" --listen 7997 --peer 127.0.0.1:7998 \
      --video off $BASE --calling ravi --press-after 6 --press "?" > "$SP/c.log" 2>&1
perl -e 'select undef,undef,undef,9'
reap

# ── PART THREE: the way out actually goes out ───────────────────────────────
# `cancel` being ON SCREEN and `cancel` ENDING THE CALL are two claims, and only
# the second one is the way out of a card that otherwise sits there for 45 s. So
# it gets pressed, and what is asserted is that the process is gone afterwards --
# an observable effect, not a handler that ran.
R3="callchk$$c"
spawn env TK_RING_TIMEOUT=60 "$TK" --window --room "$R3" --listen 7999 --peer 127.0.0.1:8000 \
      --video off $BASE --calling nobody --press-after 3 --press "@cancel" > "$SP/d.log" 2>&1
CANCEL_PID=$LAST_PID
perl -e 'select undef,undef,undef,7'
if kill -0 "$CANCEL_PID" 2>/dev/null; then CANCELLED=no; else CANCELLED=yes; fi
reap

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }
for f in "$SP/a.log" "$SP/c.log"; do
  grep -q "^tk " "$f" || { echo "CALLING CHECK COULD NOT RUN -- tk never started:"; sed -n '1,6p' "$f" | sed 's/^/  /'; exit 2; }
done

# ── 1. THE CALLER'S SCREEN NAMES THE CALLEE, ON THE SAME CARD ───────────────
first=$(grep '^audit state' "$SP/a.log" | head -1)
echo "$first" | grep -q 'card=calling' \
  && say "OK" "the caller's card is the calling card, not the invite link" \
  || say "FAIL" "caller's card was [$(echo "$first" | grep -o 'card=[a-z]*')]"
echo "$first" | grep -q 'says="Calling Meera"' \
  && say "OK" 'and it says who, as a person and not a username: "Calling Meera"' \
  || say "FAIL" "it did not name the callee: [$(echo "$first" | grep -o 'says="[^"]*"')]"
# A caption alone cannot answer "or did it crash". The dots must be ANIMATING.
echo "$first" | grep -q 'dots=alive' \
  && say "OK" "and it is visibly alive -- the dots are animating" \
  || say "FAIL" "the waiting dots are not running: [$(echo "$first" | grep -o 'dots=[A-Za-z]*')]"
# The circle is the only picture of a person this app has. A card naming Meera
# over somebody else's initial and colour would pass every assertion above.
echo "$first" | grep -q 'face=meera' \
  && say "OK" "and it is their circle -- their initial, their colour" \
  || say "FAIL" "the face on the card was [$(echo "$first" | grep -o 'face=[a-z0-9]*')]"
# Exactly one thing to press, and it is the way out.
one=$(awk '/^audit state/{exit} /^audit (OK|SELF|FAIL)/{print $3}' "$SP/a.log" \
      | grep -E '^(cancel|again|link|call|dial|answer|decline)$' | paste -sd, -)
[ "$one" = "cancel" ] \
  && say "OK" "with one way out of it: $one" \
  || say "FAIL" "the calling card offered [$one], wanted [cancel]"

# ── 2. THEY ANSWERED: THE CARD GETS OUT OF THE WAY ─────────────────────────
last=$(grep '^audit state' "$SP/a.log" | tail -1)
echo "$last" | grep -q 'card=hidden' \
  && say "OK" "when they answered the card went away" \
  || say "FAIL" "after they answered the card was [$(echo "$last" | grep -o 'card=[a-z]*')]"

# ── 3. AND THE COUNTDOWN DIED WITH IT ──────────────────────────────────────
# The last audit is past TK_RING_TIMEOUT. If the timer survived being answered it
# has already fired, and `says=` carries the verdict it wrote.
echo "$last" | grep -q "didn" \
  && say "FAIL" "the no-answer countdown fired DURING the answered call" \
  || say "OK" "and the no-answer countdown was cancelled by the answer"

# ── 4. NOBODY ANSWERED: IT SAYS SO, AND OFFERS THE TWO THINGS YOU CAN DO ────
c=$(grep '^audit state' "$SP/c.log" | tail -1)
echo "$c" | grep -q 'card=noAnswer' \
  && say "OK" "an unanswered call ends in the no-answer card" \
  || say "FAIL" "an unanswered call ended as [$(echo "$c" | grep -o 'card=[a-z]*')]"
echo "$c" | grep -q 'says="Ravi didn' \
  && say "OK" 'and it names them: "Ravi didn’t answer"' \
  || say "FAIL" "it did not say who: [$(echo "$c" | grep -o 'says="[^"]*"')]"
two=$(awk '/^audit state/{exit} /^audit (OK|SELF|FAIL)/{print $3}' "$SP/c.log" \
      | grep -E '^(cancel|again|link|call|dial)$' | paste -sd, -)
[ "$two" = "again,cancel" ] \
  && say "OK" "offering both things a person would do next: $two" \
  || say "FAIL" "the no-answer card offered [$two], wanted [again,cancel]"

# ── 5. CANCEL ENDS IT ───────────────────────────────────────────────────────
grep -q "click cancel at" "$SP/d.log" \
  && say "OK" "cancel took a real click" \
  || say "FAIL" "cancel was not clickable"
[ "$CANCELLED" = "yes" ] \
  && say "OK" "and pressing it ended the call instead of just looking pressed" \
  || say "FAIL" "cancel was pressed and the call is still running"

echo
if [ "$fail" = 0 ]; then
  echo "CALLING CHECK PASSED -- the caller sees the mirror of what the callee sees"
else
  echo "CALLING CHECK FAILED -- see above; logs in $SP"
  for f in a c d; do
    cp "$SP/$f.log" "${SCRATCH:-${TMPDIR:-/tmp}}/calling-check-$f.log" 2>/dev/null
  done
fi
exit $fail
