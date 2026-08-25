#!/bin/bash
# ── IS A RING A CALL BEFORE ANYBODY ANSWERS IT? ──────────────────────────────
#
# It was. The watcher opens Kin with BOTH `--room <r>` and `--incoming <who>`, so
# the copy that exists to ASK fell through into the rendezvous and joined. With
# nobody having pressed anything, measured on two real processes:
#
#     the caller     status=connected   card=hidden
#     the callee     sent 1513/s  recv 1510/s  played 1503/s
#
# The ring answered itself. The caller saw the call connect, the callee's
# microphone was live in a room with them, and the arrival of a peer then HID the
# ringing card -- the control that would have let them say no. The ringtone playing
# into that live microphone is the echo that came with it.
#
# Three claims, and the third is the one a fix could pass while still being wrong:
#   1. an unanswered ring sends nothing
#   2. the caller still says it is calling, and the callee can still be asked
#   3. answering still works -- a fix that made the ring inert would pass 1 and 2
set -u
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/preanswer-check.$$"
mkdir -p "$SP"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT

# ── PART ONE: ringing, unanswered ───────────────────────────────────────────
R1="preans$$a"
spawn "$TK" --window --room "$R1" --listen 8021 --peer 127.0.0.1:8022 --video off \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --calling tester --press-after 8 --press "?" > "$SP/a.log" 2>&1
perl -e 'select undef,undef,undef,2'
# Exactly the watcher's launch line, which is the one that will keep arriving from
# an old resident watcher for as long as somebody stays logged in.
# ── `--video camera`, BECAUSE THAT IS WHAT THE WATCHER PASSES ──────────────
#
# This said `--video off`, and the first version of the fix passed the whole rig
# while still turning the camera on in production: the park was placed BELOW the
# camera bring-up, and a rig that never asks for a camera can never see a camera
# start. Sweep anything the harness hardcodes that the product picks at runtime.
spawn "$TK" --window --room "$R1" --listen 8022 --peer 127.0.0.1:8021 --video camera \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --incoming somebody --press-after 7 --press "?" > "$SP/b.log" 2>&1
perl -e 'select undef,undef,undef,12'
reap

# ── PART TWO: the same ring, answered ───────────────────────────────────────
R2="preans$$b"
spawn "$TK" --window --room "$R2" --listen 8023 --peer 127.0.0.1:8024 --video off \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --calling tester > "$SP/c.log" 2>&1
perl -e 'select undef,undef,undef,2'
spawn "$TK" --window --room "$R2" --listen 8024 --peer 127.0.0.1:8023 --video off \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --incoming somebody --press-after 3 --press "@answer" > "$SP/d.log" 2>&1
perl -e 'select undef,undef,undef,14'
reap

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }
for f in a b c d; do
  grep -q "^tk " "$SP/$f.log" || { echo "PRE-ANSWER CHECK COULD NOT RUN -- tk never started in $f:"; sed -n '1,5p' "$SP/$f.log" | sed 's/^/  /'; exit 2; }
done

# ── 1. AN UNANSWERED RING SENDS NOTHING ─────────────────────────────────────
# The report loop only exists once there is a call to report on, so the honest
# measure is whether it ran at all. A count, not a rate: a rate of zero and no
# rate at all are the same reading and only one of them is this fix.
sent=$(grep -cE "^cap " "$SP/b.log")
[ "$sent" = "0" ] \
  && say "OK" "an unanswered ring opened no socket and sent nothing" \
  || say "FAIL" "the unanswered ring ran $sent media reports -- it joined the call"
grep -q "no room, no microphone, no camera" "$SP/b.log" \
  && say "OK" "and it says so: no room, no microphone, no camera" \
  || say "FAIL" "it did not take the waiting path at all"
# The camera light next to somebody who has not agreed to be on a call.
grep -q "camera: bring-up" "$SP/b.log" \
  && say "FAIL" "it turned the camera on before anybody answered" \
  || say "OK" "and no camera light while somebody is only being asked"

# ── 2. BOTH ENDS STILL SHOW THE TRUTH ───────────────────────────────────────
a=$(grep '^audit state' "$SP/a.log" | tail -1)
echo "$a" | grep -q 'card=calling' \
  && say "OK" "the caller still says it is calling, not connected" \
  || say "FAIL" "the caller's card was [$(echo "$a" | grep -o 'card=[a-zA-Z]*')]"
b=$(grep '^audit state' "$SP/b.log" | tail -1)
echo "$b" | grep -q 'card=ringing' \
  && say "OK" "and the callee can still be asked -- the card is still there" \
  || say "FAIL" "the callee's card was [$(echo "$b" | grep -o 'card=[a-zA-Z]*')]"

# ── 3. AND ANSWERING STILL WORKS ────────────────────────────────────────────
# Without this, "sends nothing" is satisfied by a ring that can never become a
# call, which is a worse bug than the one being fixed.
grep -q "answer committed by NSEventType" "$SP/d.log" \
  && say "OK" "answering was a real click, not a handler call" \
  || say "FAIL" "the answer press never reached the button"
ans=$(grep -cE "^cap " "$SP/d.log")
[ "$ans" -gt 0 ] \
  && say "OK" "and after answering it is a real call ($ans media reports)" \
  || say "FAIL" "answering produced no media at all"
car=$(grep -cE "^cap " "$SP/c.log")
[ "$car" -gt 0 ] \
  && say "OK" "with the caller in it too ($car media reports)" \
  || say "FAIL" "the caller never got media after the answer"

# ── 4. AND IT SOUNDS LIKE A CALL ────────────────────────────────────────────
grep -q "ring: sounding" "$SP/b.log" \
  && say "OK" "the ring used a real ringtone: $(grep -o 'sounding [A-Za-z]*' "$SP/b.log" | head -1 | cut -d' ' -f2)" \
  || say "FAIL" "no ringtone was chosen; $(grep -o 'ring: no ringtone.*' "$SP/b.log" | head -1)"

echo
if [ "$fail" = 0 ]; then
  echo "PRE-ANSWER CHECK PASSED -- a ring asks, and only an answer starts a call"
else
  echo "PRE-ANSWER CHECK FAILED -- see above; logs in $SP"
  for f in a b c d; do cp "$SP/$f.log" "${SCRATCH:-${TMPDIR:-/tmp}}/preanswer-$f.log" 2>/dev/null; done
fi
exit $fail
