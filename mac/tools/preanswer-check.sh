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
# Ring windows do not throw themselves in front of whatever the person at this
# Mac is doing. That behaviour is right for a phone and is proved in
# firstrun-ring-check; here it only means their taps land on cards they cannot
# see, which made this rig's verdict depend on whether anybody touched the
# trackpad while it ran.
export TK_NO_RAISE=1
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/preanswer-check.$$"
mkdir -p "$SP"
# ── ITS OWN IDENTITY, AND ONE CONTACT IN IT ─────────────────────────────────
#
# TK_KIN_DIR because `.applicationSupportDirectory` resolves through the user
# record and not $HOME, so a rig without it reads and writes the REAL install's
# contact list. And a contact, because connecting before anybody answers is only
# allowed for somebody already in it -- see RINGING.md on what a stranger's ring
# would otherwise reveal. `somebody` is that contact; `astranger` deliberately is
# not, and part four is the arm that proves the difference.
export TK_KIN_DIR="$SP/id"
mkdir -p "$SP/id"
KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
printf '{"somebody":"%s"}' "$KEY" > "$SP/id/contacts.json"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT

# ── PART ONE: ringing, unanswered ───────────────────────────────────────────
# ── THE CALLER HAS TO HAVE A FACE ───────────────────────────────────────────
#
# This ran `--video off`, so the callee received audio and never a frame -- and
# the single worst bug this feature could have was on the path that runs when the
# FIRST FRAME decodes: it hid the ring card, both buttons and the whole decision,
# and left the ringtone playing at somebody with nothing to press. A rig whose
# caller has no picture cannot reach that line at all. A real downloaded talking
# head, never a synthetic pattern: a decoder and a display behave differently on
# real texture, and this project has a rule about it.
MEDIA="${MEDIA:-$HERE/../../testbed/media/real/talkingheadA.mov}"
# ── `-f` ANSWERS A QUESTION THE APP DOES NOT ASK ─────────────────────────────
#
# This was `[ -f "$MEDIA" ]`, which stats. On 2026-08-26 the whole repo went
# EPERM for a while -- the harness lost its file-access permission -- and stat
# kept working while open() did not. So the guard passed, the rig ran, the app
# could not read a single byte of the picture, and the run reported 7 failing
# assertions that all read as product regressions.
#
# The guard has to do the thing the app does. One byte is enough.
if ! head -c 1 "$MEDIA" > /dev/null 2>&1; then
  echo "cannot READ $MEDIA -- it exists but will not open; see testbed/media/real/fetch.sh, and check this Mac has not revoked file access"
  exit 2
fi
R1="preans$$a"
spawn "$TK" --window --room "$R1" --listen 8021 --peer 127.0.0.1:8022 --video "$MEDIA" \
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
      --incoming somebody --incoming-key "$KEY" --press-after 7 --press "?" > "$SP/b.log" 2>&1
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
      --incoming somebody --incoming-key "$KEY" --press-after 3 --press "@answer" > "$SP/d.log" 2>&1
perl -e 'select undef,undef,undef,14'
reap

# ── PART THREE: a click nobody aimed, and the same click from a finger ──────
#
# Three times in one afternoon a ring answered itself -- real trackpad taps, with
# device-shaped event numbers, landing on a window that had put itself in front
# of what somebody was doing. `@!answer` sends exactly that: the same gesture as
# `@answer` above, differing only in whether it claims to have come from a
# device. TK_AIM_MS widens the card's own "nobody could have aimed this yet"
# window so the refusal is reachable without a person at the trackpad.
R3="preans$$c"
spawn env TK_AIM_MS=60000 "$TK" --window --room "$R3" --listen 8025 --peer 127.0.0.1:8026 \
      --video off --mute --no-telemetry --no-update --no-relocate --no-rings \
      --no-subtitles --incoming somebody --incoming-key "$KEY" --press-after 3 --press "@!answer,?" \
      > "$SP/e.log" 2>&1
perl -e 'select undef,undef,undef,10'
reap

# ── PART FOUR: A STRANGER'S RING REVEALS NOTHING ────────────────────────────
#
# The same launch line with a caller who is NOT in the contact list. RINGING.md:
# "the callee's probes go to those candidates, so the CALLER learns the callee's
# IP and that the Mac is online and awake, before consent. This is the real
# leak." So this arm must behave like the app did before the preview existed --
# ring, and connect nothing. Without it, part one proves only that the feature
# works and says nothing about who it works FOR.
R4="preans$$d"
spawn "$TK" --window --room "$R4" --listen 8027 --peer 127.0.0.1:8028 \
      --video off --mute --no-telemetry --no-update --no-relocate --no-rings \
      --no-subtitles --calling tester > "$SP/f.log" 2>&1
perl -e 'select undef,undef,undef,2'
spawn "$TK" --window --room "$R4" --listen 8028 --peer 127.0.0.1:8027 \
      --video camera --mute --no-telemetry --no-update --no-relocate --no-rings \
      --no-subtitles --incoming astranger --press-after 6 --press "?" \
      > "$SP/g.log" 2>&1
perl -e 'select undef,undef,undef,10'
reap

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }
for f in a b c d e f g; do
  grep -q "^tk " "$SP/$f.log" || { echo "PRE-ANSWER CHECK COULD NOT RUN -- tk never started in $f:"; sed -n '1,5p' "$SP/$f.log" | sed 's/^/  /'; exit 2; }
done

# ── 1. AN UNANSWERED RING RECEIVES AND SENDS NOTHING ────────────────────────
#
# It joins the room now, on purpose -- that is how you get to see who is calling
# before you decide. So "did it run any media reports" is no longer the question;
# it would pass for a ring that never connected at all. The question is what is
# IN those reports, and every one of them has to read zero on the sending side.
#
#   cap 0/s      the microphone captured nothing, so there was nothing to send
#   played 0/s   their voice was received and never played into this room
#   no camera    no green light next to somebody who has not agreed to anything
grep -q "audio engine not started" "$SP/b.log" \
  && say "OK" "the audio engine was never started -- no capture, no playout" \
  || say "FAIL" "a ring that has not been answered started the audio engine"
CAPNZ=$(grep -oE "^cap [0-9]+/s" "$SP/b.log" | grep -vc "^cap 0/s")
[ "${CAPNZ:-1}" = "0" ] \
  && say "OK" "and the microphone captured nothing, in every report it made" \
  || say "FAIL" "the microphone captured audio in $CAPNZ reports before anybody answered"
PLAYNZ=$(grep -oE "played [0-9]+/s" "$SP/b.log" | grep -vc "played 0/s")
[ "${PLAYNZ:-1}" = "0" ] \
  && say "OK" "and nothing was played into a room nobody had opened" \
  || say "FAIL" "$PLAYNZ reports played their audio before anybody answered"
grep -q "no microphone, no camera" "$SP/b.log" \
  && say "OK" "and it says so: no microphone, no camera" \
  || say "FAIL" "it did not take the waiting path at all"
# The camera light next to somebody who has not agreed to be on a call.
grep -q "camera: bring-up" "$SP/b.log" \
  && say "FAIL" "it turned the camera on before anybody answered" \
  || say "OK" "and no camera light while somebody is only being asked"
# ── AND YET IT CAN SEE THEM ─────────────────────────────────────────────────
# The whole point of the change: "if someone is calling, their video should be
# visible to you so you know who is calling exactly."
RECVNZ=$(grep -oE "recv [0-9]+/s" "$SP/b.log" | grep -vc "recv 0/s")
[ "${RECVNZ:-0}" != "0" ] \
  && say "OK" "while RECEIVING them -- $RECVNZ reports with their stream arriving" \
  || say "FAIL" "it received nothing, so there is no picture of who is calling"
# NOT the picture assertion -- this line is printed at the transport LOCK, and
# for a while it claimed a picture there. A `--video off` caller reaches it
# identically, so asserting a face on it passed a ring with nothing to look at.
# The face is proven in part 3a, on the line that only a decoded frame prints.
grep -q "the ring card reached them" "$SP/b.log" \
  && say "OK" "and the card is JOINED to their call, not merely named after it" \
  || say "FAIL" "the ring card never reached them, so it has nothing to show"
# The caller must not read any of that as an answer.
grep -q "they are being asked -- not connected yet" "$SP/a.log" \
  && say "OK" "and the caller knows it is a ring, not an answer" \
  || say "FAIL" "the caller was never told the far end is only being asked"
grep -q "connected via" "$SP/a.log" \
  && say "FAIL" "the caller called it connected while nobody had answered" \
  || say "OK" "so the caller never said connected"

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
  || { grep -q "ring: silent -- this copy is muted" "$SP/b.log" \
       && say "OK" "the ring was silent, because --mute now covers the ringtone too" \
       || say "FAIL" "no ringtone was chosen; $(grep -o 'ring: no ringtone.*' "$SP/b.log" | head -1)"; }

echo
if # ── 3a. THEIR FACE ARRIVES AND THE CARD SURVIVES IT ─────────────────────────
#
# The critical one. `vdec.onDecoded` used to call `markConnected()` on the first
# frame, which sets `waiting.isHidden = true` -- and the answer and decline
# buttons are subviews of `waiting`. So the caller's picture arriving took the
# card, both buttons and the whole decision away, put "connected" in the status
# pill, and went on ringing for forty seconds at somebody with nothing to press.
# There is no way back: `showIncoming` refuses to re-open it.
grep -q "the other side's picture is on screen" "$SP/b.log" \
  && say "OK" "their picture really did reach the screen" \
  || say "FAIL" "no frame was ever drawn, so the card-survives test below proves nothing"
grep -q "behind the ring card, still nobody's decision" "$SP/b.log" \
  && say "OK" "and it went BEHIND the card rather than replacing it" \
  || say "FAIL" "the first frame took the ring card away"
grep -q "card=ringing" "$SP/b.log" \
  && say "OK" "the card is still ringing after their picture arrived" \
  || say "FAIL" "the card is [$(grep -o 'card=[a-zA-Z]*' "$SP/b.log" | tail -1)] after their picture arrived"
grep -q "status=connected" "$SP/b.log" \
  && say "FAIL" "and it told the person they were connected to a call nobody answered" \
  || say "OK" "and it never claimed to be connected"

# ── 3b. AND ONLY FOR SOMEBODY YOU HAVE TALKED TO BEFORE ─────────────────────
grep -q "is not in this Mac's contacts" "$SP/g.log" \
  && say "OK" "a stranger's ring does not connect early, and says why" \
  || say "FAIL" "a stranger's ring was treated like a contact's"
STRANGERECV=$(grep -oE "recv [0-9]+/s" "$SP/g.log" | grep -vc "recv 0/s")
[ "${STRANGERECV:-1}" = "0" ] \
  && say "OK" "and it received nothing, so it revealed nothing" \
  || say "FAIL" "a stranger's ring opened a path: $STRANGERECV reports received"
grep -q "card=ringing" "$SP/g.log" \
  && say "OK" "CONTROL: a stranger can still ring you -- the card is there" \
  || say "FAIL" "a stranger cannot ring at all now, which is not the rule"

# ── 4. A CLICK NOBODY AIMED IS NOT AN ANSWER ────────────────────────────────
grep -q "ignored a click nobody aimed" "$SP/e.log" \
  && say "OK" "a click nobody aimed was refused, and the log says so" \
  || say "FAIL" "a device-shaped click was taken at face value -- the guard never fired"
grep -q "^cap " "$SP/e.log" \
  && say "FAIL" "and it started a call anyway" \
  || say "OK" "and it started nothing"
grep -q "ignored a click nobody aimed" "$SP/d.log" \
  && say "FAIL" "CONTROL: the real answer press was refused too -- the guard is a wall" \
  || say "OK" "CONTROL: the real answer press went through, so it discriminates"

[ "$fail" = 0 ]; then
# ════════════════════════════════════════════════════════════════════════════
# ── AND YOU CAN ANSWER IT WITHOUT A MOUSE ───────────────────────────────────
# ════════════════════════════════════════════════════════════════════════════
#
# A ringing call could only be answered by clicking it. That is a gap on a Mac --
# Return answers in FaceTime -- and a wall for anybody who does not use a
# trackpad. Return answers now and Escape declines, and the two are guarded
# differently on purpose:
#
#   Escape ends something. The worst a stray one can do is refuse a call, which
#   the caller sees and can repeat.
#
#   Return STARTS A CAMERA AND A MICROPHONE, and the ring window raises itself in
#   front of whatever somebody was typing in. This project has already had that
#   accident with the mouse -- real trackpad taps answered Kin calls because the
#   card arrived under a finger already moving. So a Return is refused for the
#   first 600 ms of a ring, and both halves of that are tested here: a defence
#   that only ever runs in production is a defence nobody has seen work.
#
# The keys go through `NSApp.postEvent`, this process's own queue, so they travel
# the path a real keystroke travels and cannot reach any other app.
echo "── the keyboard: Return answers, Escape declines, and neither is a hair trigger"
RK="preans$$k"
spawn "$TK" --window --room "$RK" --listen 8027 --peer 127.0.0.1:8028 --video off \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --calling tester > "$SP/k1.log" 2>&1
perl -e 'select undef,undef,undef,2'
# `--press-after 0.2` puts the first Return inside the 600 ms window; the second,
# a token later, lands well outside it.
spawn "$TK" --window --room "$RK" --listen 8028 --peer 127.0.0.1:8027 --video off \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --incoming somebody --incoming-key "$KEY" --press-after 0.2 \
      --press "key:return,?,key:return,?" > "$SP/k2.log" 2>&1
perl -e 'select undef,undef,undef,12'
reap
K="$SP/k2.log"
grep -q "ring: Return ignored" "$K" \
  && say OK "a Return in the first 600 ms is refused, and says why" \
  || { say FAIL "an immediate Return was accepted -- a keystroke already in flight"
       say FAIL "  when the card appeared would answer a call"; fail=1; }
grep -q "ring: answered from the keyboard" "$K" \
  && say OK "and a Return after that answers" \
  || { say FAIL "Return never answered the call:"
       grep -E "^ring:|^key " "$K" | tail -3 | sed 's/^/         /'; fail=1; }
# ── AND IT REALLY ANSWERED, WHICH IS NOT WHAT THE CARD SAYS ─────────────────
#
# The obvious assertion -- the ring card is gone -- is the wrong one, and it fails
# on a build that works. Answering RE-EXECS this process (the callee walks into
# the call as a new image), so the card state after the press belongs to a process
# that is on its way out; the last `card=` in the log is from before the handover.
# What proves an answer is the handover itself.
grep -qE "re-exec|reexec|answering|joining" "$K" \
  && say OK "and the answer really started the handover into the call" \
  || { say FAIL "Return logged an answer and nothing followed it:"
       tail -4 "$K" | cut -c1-100 | sed 's/^/         /'; fail=1; }

# ── AND ESCAPE DECLINES ─────────────────────────────────────────────────────
RE="preans$$e"
spawn "$TK" --window --room "$RE" --listen 8029 --peer 127.0.0.1:8030 --video off \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --calling tester > "$SP/e1.log" 2>&1
perl -e 'select undef,undef,undef,2'
spawn "$TK" --window --room "$RE" --listen 8030 --peer 127.0.0.1:8029 --video off \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --incoming somebody --incoming-key "$KEY" --press-after 2 \
      --press "key:esc" > "$SP/e2.log" 2>&1
perl -e 'select undef,undef,undef,8'
reap
grep -q "ring: declined from the keyboard" "$SP/e2.log" \
  && say OK "Escape declines, with no waiting period" \
  || { say FAIL "Escape did not decline the call:"
       grep -E "^ring:|^key " "$SP/e2.log" | tail -3 | sed 's/^/         /'; fail=1; }

  echo "PRE-ANSWER CHECK PASSED -- a ring asks, and only an answer starts a call"
else
  echo "PRE-ANSWER CHECK FAILED -- see above; logs in $SP"
  for f in a b c d; do cp "$SP/$f.log" "${SCRATCH:-${TMPDIR:-/tmp}}/preanswer-$f.log" 2>/dev/null; done
fi
exit $fail
