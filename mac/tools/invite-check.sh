#!/bin/bash
# ── IS THE INVITE A LINK AND A BUTTON, AND DOES EITHER ONE DO ANYTHING? ──────
#
# The waiting card used to be seven things: a title, a hint, the link, `share`,
# `copy`, a name field and `call`. It is two now -- the link, which copies when
# you click it, and a handset, which turns the link into "who do you want to
# call?" -- and both of those claims are about what happens when a finger lands,
# which is the half this project keeps shipping broken. A control that draws and
# does nothing passes every handler test ever written here.
#
# So every step below is a REAL click or a REAL key, through the app's own window,
# and every assertion is read back out of the app afterwards.
#
# The first assertion is also the ruler: on the build before this one the card
# offered `share`, `copy`, `link`, `dial` and `call` all at once, so "exactly link
# and call" is a sentence only the new card can say.
set -u
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/invite-check.$$"
mkdir -p "$SP"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
trap 'reap; rm -rf "$SP"' EXIT

# A room nobody is in. Reusing a real invite code puts this rig into somebody's
# call: an earlier version of this test joined the room in the screenshot that
# started the work and sat there sending sealed packets at a stranger.
R="invchk$$-$RANDOM"
L="$SP/a.log"

# --mute always: the machine's speakers belong to whoever is sitting at it.
# The sequence, in order:
#   ?          what is on the card at rest
#   @link      click the link itself -- the only way to copy from this screen
#   @call      the handset: the link goes, the question arrives
#   +meera     type a name into whatever that focused
#   ?          read it back
#   esc        a real Escape -- the question goes, the link comes back
#   ?          confirm it did
#   @call/+meera/@call   and this time go through with it
#
# There is deliberately no token after that last press. Placing a call RE-EXECS,
# and `Launcher.reexec` drops `--press` on purpose so the successor does not
# replay the sequence and place a second call. Anything queued behind the press
# therefore never runs, and a `?` written there would read as an audit that
# vanished. The press's own `click ... -> <tree>` line is the last thing this
# image says, so that is what gets read.
#
# Escape is tested BEFORE the call is placed, deliberately. It used to be tested
# after, back when placing a call left the invite card up -- and the moment the
# caller got a card of their own, that step was asserting that Escape cancels a
# call in flight. It does not, and it should not: Escape dismisses a question, and
# there is a `cancel` button for ending a call precisely because ending one should
# take aim. `calling-check.sh` owns everything past the press.
spawn "$TK" --window --room "$R" --listen 7981 --peer 127.0.0.1:7982 --video off \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --press-after 2 --press "?,@link,@call,+meera,?,esc,?,@call,+meera,@call" \
      > "$L" 2>&1
perl -e 'select undef,undef,undef,14'
reap

# ── DID IT EVEN RUN? ────────────────────────────────────────────────────────
#
# A refused flag exits 2 before the window opens, and the eight assertions below
# then measure an empty file. That is not eight findings, it is one, and it is
# not a finding about the product.
if ! grep -q "^tk " "$L"; then
  echo "INVITE CHECK COULD NOT RUN -- tk never started:"
  sed -n '1,6p' "$L" | sed 's/^/  /'
  exit 2
fi

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }

# The invite URL as the app itself reports it, so the clipboard is compared
# against the real thing rather than against a pattern that would match a
# truncated one.
URL=$(sed -n 's/.*link: copyable at [0-9]* ms (\(.*\))$/\1/p' "$L" | head -1)
[ -n "$URL" ] && say "OK" "the app published an invite: $URL" \
              || say "FAIL" "no invite URL in the log at all"

# ── 1. AT REST: A LINK AND A HANDSET, AND NOTHING ELSE ──────────────────────
first=$(awk '/^audit state/{exit} /^audit (OK|SELF|FAIL)/{print $3}' "$L" \
        | grep -E '^(link|call|share|copy|dial)$' | paste -sd, -)
[ "$first" = "link,call" ] \
  && say "OK" "at rest the card offers exactly: $first" \
  || say "FAIL" "at rest the card offers [$first], wanted [link,call]"

# ── 2. THE LINK IS THE COPY BUTTON ──────────────────────────────────────────
grep -q "click link at" "$L" \
  && say "OK" "the link took a real click" \
  || say "FAIL" "the link was not clickable"
# From the line the CLICK printed, not the first `clip=` in the file: the first
# one is the audit that ran BEFORE the click and reports whatever the machine's
# clipboard already held. Reading it made a working copy look broken and would
# have made a broken one look fine on a Mac that happened to have the URL on the
# clipboard already.
CLIP=$(grep 'click link: sent' "$L" | grep -o 'clip=[^ ]*' | sed 's/clip=//' | head -1)
[ -n "$URL" ] && [ "$CLIP" = "$URL" ] \
  && say "OK" "clicking it put the invite on the clipboard" \
  || say "FAIL" "clipboard was [$CLIP], wanted [$URL]"

# ── 3. THE HANDSET REPLACES THE LINK WITH THE QUESTION ──────────────────────
# Read from the audit that ran after `@call` and `+meera`: the card must be in
# dial mode, the typed name must have arrived, and `link` must be GONE -- not
# merely joined by a field, which is what the old card did.
# The audit AFTER the name was typed. The first `card=dial` in the file is the
# instant the handset was pressed, when the field is correctly empty -- asserting
# on that one asks whether an empty box is empty.
dialstate=$(grep '^audit state' "$L" | grep -o 'card=dial  dialtext="[^"]*"' | head -1)
[ "$dialstate" = 'card=dial  dialtext="meera"' ] \
  && say "OK" "the handset asked for a name and the name landed in it" \
  || say "FAIL" "after the handset the card was [$dialstate]"
second=$(awk '/^audit state/{n++} n==1 && /^audit (OK|SELF|FAIL)/{print $3}' "$L" \
         | grep -E '^(link|call|share|copy|dial)$' | paste -sd, -)
[ "$second" = "dial,call" ] \
  && say "OK" "and the link is gone while it is asking: $second" \
  || say "FAIL" "while asking, the card offered [$second], wanted [dial,call]"

# ── 4. THE SECOND PRESS RINGS THE NAME ──────────────────────────────────────
grep -q 'status=calling @meera…' "$L" \
  && say "OK" "pressing it again called @meera" \
  || say "FAIL" "the second press did not start a call"

# ── 5. ESCAPE PUTS THE LINK BACK ────────────────────────────────────────────
# Posted to the app queue, not handed to a handler: the key has to survive the
# field editor, which is the only reason this line can fail.
esc=$(grep '^audit state' "$L" | sed -n '3p' | grep -o 'card=[a-zA-Z]*')
[ "$esc" = "card=invite" ] \
  && say "OK" "Escape cancelled the question and the link came back" \
  || say "FAIL" "after Escape the card was [$esc]"

# ── 6. AND GOING THROUGH WITH IT LEAVES THE CALLER SOMETHING TO LOOK AT ─────
# The shallow end of it only -- that the press does not dump the caller back on
# the invite link, which is the bug `calling-check.sh` exists for.
#
# From the PRESS's own line, not from the last `audit state` in the file. The last
# audit in this log is the one after Escape, three tokens earlier, because the
# re-exec ended the image before any later token could run -- so `tail -1` reported
# a true reading of the wrong moment, which is the most expensive kind.
tail=$(grep 'click call: sent' "$L" | tail -1 | grep -o 'card=[a-zA-Z]*')
[ "$tail" = "card=calling" ] \
  && say "OK" "and placing the call leaves the calling card up, not the link" \
  || say "FAIL" "after placing the call the card was [$tail]"

echo
if [ "$fail" = 0 ]; then
  echo "INVITE CHECK PASSED -- the link copies itself and the handset asks who to call"
else
  echo "INVITE CHECK FAILED -- see above; full log at $L"
  cp "$L" "${SCRATCH:-${TMPDIR:-/tmp}}/invite-check-failed.log"
  echo "  (copied to ${SCRATCH:-${TMPDIR:-/tmp}}/invite-check-failed.log)"
fi
exit $fail
