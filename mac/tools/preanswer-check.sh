#!/bin/bash
# ── IS A RING A CALL BEFORE ANYBODY ANSWERS IT? ──────────────────────────────
#
# `--route headphones` on every launch since 0.166.0: answering is refused on a
# loudspeaker route, and this rig's subject is the ring-then-answer flow, not
# the door (the door has its own rig, `earbuds-check`).
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
# ── NOT ONE HANDLE ON THE REAL SERVER ───────────────────────────────────────
#
# Without this every end in here walked @devesh, @deveshp, @devesh2 … @devesh9
# against the production directory on every run -- squatting names a person may
# want, and spending the registration budget (ten a minute) so the next rig's
# ends read `429 rate`. Nothing here needs a claim: the ring is handed to the
# callee in argv exactly as the watcher hands it over.
export TK_NO_IDENTITY=1
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
# ── A PROCESS THAT LEFT ON ITS OWN SAYS HOW ─────────────────────────────────
#
# `wait <pid>` on a child that has already exited returns its status: 0 is a
# clean exit and 128+N is a signal. A child still running is left for `reap`.
# Eleven crash reports in one suite run -- the final beat read the audio engine
# before it existed, on every exit that happens before a call -- came from rigs
# whose assertions were all satisfied by a goodbye that had already left the
# socket. The death was the one thing nobody looked at
# (`unexplained-death-is-a-bug`).
status_of() { # <pid> -> alive | exit N | signal N
  if kill -0 "$1" 2>/dev/null; then echo alive; return; fi
  wait "$1" 2>/dev/null; local st=$?
  if [ "$st" -ge 128 ]; then echo "signal $((st - 128))"; else echo "exit $st"; fi
}
CRASHDIR="$HOME/Library/Logs/DiagnosticReports"
crashes() { ls "$CRASHDIR" 2>/dev/null | grep -c '^tk-' || true; }
CRASH0="$(crashes)"
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
# ── TWO MACS, TWO KEYS, AND THE CALLEE IS TOLD THE CALLER'S REAL ONE ────────
#
# This used to give every end one shared directory and hand the callee a made-up
# key of 32 zero bytes. That stopped meaning anything in 0.128.0, when the media
# handshake became signed by the device key: a callee told "the caller's key is
# K" refuses a handshake from anybody who cannot prove K, so a fake K is a call
# that never keys -- "NO KEY", recv 0/s at the callee, and "connected" at the
# caller once the ten-second deadline passes. Every FAIL row in the preview
# section read as a product regression for eight days, and the "real call" rows
# in part two were passing on `cap` lines with nothing in them.
#
# So the caller's identity is SEEDED -- a fixed Ed25519 seed in its own directory,
# the file the app would otherwise mint on first run -- its public key is derived
# here with openssl, and that key is what goes into the callee's contact list and
# onto the ring: the same three facts the watcher and the server line up on a
# real Mac. The derivation is then checked against the app's own statement of its
# identity, so a wrong key fails as COULD NOT RUN and never as a verdict.
CALLER="$SP/caller"; CALLEE="$SP/callee"; STRANGER="$SP/stranger"; CALLER4="$SP/caller4"
mkdir -p "$CALLER" "$CALLEE" "$STRANGER" "$CALLER4"
seed_identity() { # <dir> <32-byte seed, 64 hex chars> -> base64 Ed25519 public key on stdout
  local seed_b64; seed_b64="$(printf '%s' "$2" | xxd -r -p | base64)"
  printf '{"seed":"%s","tok":"%s","handle":"rig","claimed":false,"quiet":false}' \
    "$seed_b64" "$(printf '%064d' 0)" > "$1/identity.json"
  chmod 600 "$1/identity.json"
  # A PKCS#8 wrapper around the raw seed; the last 32 bytes of the SPKI DER are
  # the raw public key, which is exactly what the app puts on the wire.
  { printf '302e020100300506032b657004220420' | xxd -r -p; printf '%s' "$2" | xxd -r -p; } \
    | openssl pkey -inform DER -pubout -outform DER 2>/dev/null | tail -c 32 | base64
}
KEY="$(seed_identity "$CALLER" 0101010101010101010101010101010101010101010101010101010101010101)"
[ "${#KEY}" = 44 ] || { echo "PRE-ANSWER CHECK COULD NOT RUN -- this openssl ($(openssl version)) cannot derive an Ed25519 public key, so the rig cannot seed a caller"; exit 2; }
printf '{"somebody":"%s"}' "$KEY" > "$CALLEE/contacts.json"
# Part four's caller is a different Mac on purpose: the first call pins the
# callee's key under `tester` in the caller's contacts, and the stranger's Mac
# holds a different key -- a caller that had already met `tester` would refuse it.
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
spawn env TK_KIN_DIR="$CALLER" "$TK" --window --room "$R1" --listen 8021 --peer 127.0.0.1:8022 --video "$MEDIA" \
      --mute --route headphones --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
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
spawn env TK_KIN_DIR="$CALLEE" "$TK" --window --room "$R1" --listen 8022 --peer 127.0.0.1:8021 --video camera \
      --mute --route headphones --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --incoming somebody --incoming-key "$KEY" --press-after 7 --press "?" > "$SP/b.log" 2>&1
perl -e 'select undef,undef,undef,12'
reap

# ── PART TWO: the same ring, answered ───────────────────────────────────────
R2="preans$$b"
spawn env TK_KIN_DIR="$CALLER" "$TK" --window --room "$R2" --listen 8023 --peer 127.0.0.1:8024 --video off \
      --mute --route headphones --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --calling tester > "$SP/c.log" 2>&1
perl -e 'select undef,undef,undef,2'
spawn env TK_KIN_DIR="$CALLEE" "$TK" --window --room "$R2" --listen 8024 --peer 127.0.0.1:8023 --video off \
      --mute --route headphones --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --incoming somebody --incoming-key "$KEY" --press-after 3 --press "@answer" > "$SP/d.log" 2>&1
DPID=$LAST_PID
perl -e 'select undef,undef,undef,14'
D_ST="$(status_of "$DPID")"
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
spawn env TK_AIM_MS=60000 TK_KIN_DIR="$CALLEE" "$TK" --window --room "$R3" --listen 8025 --peer 127.0.0.1:8026 \
      --video off --mute --route headphones --no-telemetry --no-update --no-relocate --no-rings \
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
spawn env TK_KIN_DIR="$CALLER4" "$TK" --window --room "$R4" --listen 8027 --peer 127.0.0.1:8028 \
      --video off --mute --route headphones --no-telemetry --no-update --no-relocate --no-rings \
      --no-subtitles --calling tester > "$SP/f.log" 2>&1
perl -e 'select undef,undef,undef,2'
# `?` first -- the stranger's card, un-connected, is the assertion of part 3b --
# and THEN the answer. A stranger's ring is the earliest exit in the whole app (its
# card lives in `NSApplication.run()` above the audio block), which is exactly
# where 0.157.0 died; see the verdicts under 3b.
spawn env TK_KIN_DIR="$STRANGER" "$TK" --window --room "$R4" --listen 8028 --peer 127.0.0.1:8027 \
      --video camera --mute --route headphones --no-telemetry --no-update --no-relocate --no-rings \
      --no-subtitles --incoming astranger --press-after 6 --press "?,@answer" \
      > "$SP/g.log" 2>&1
GPID=$LAST_PID
perl -e 'select undef,undef,undef,16'
G_ST="$(status_of "$GPID")"
reap

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }
for f in a b c d e f g; do
  grep -q "^tk " "$SP/$f.log" || { echo "PRE-ANSWER CHECK COULD NOT RUN -- tk never started in $f:"; sed -n '1,5p' "$SP/$f.log" | sed 's/^/  /'; exit 2; }
done
# THE RULER FIRST. The key this rig derived must be the identity the caller says
# it has; otherwise every key-shaped verdict below is about the rig's arithmetic.
grep -qF "crypto: my identity $KEY," "$SP/a.log" || {
  echo "PRE-ANSWER CHECK COULD NOT RUN -- the caller's identity is not the key this rig derived:"
  grep -m1 "crypto: my identity" "$SP/a.log" | sed 's/^/  app: /'
  echo "  rig: $KEY"; exit 2; }

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
# MEDIA, not report lines. `cap` prints every second whether or not anything
# arrives; counting lines passed a call that never keyed ("NO KEY", recv 0/s).
ans=$(grep -oE "recv [0-9]+/s" "$SP/d.log" | grep -vc "recv 0/s")
[ "${ans:-0}" -gt 0 ] \
  && say "OK" "and after answering it is a real call ($ans reports with the caller's stream arriving)" \
  || say "FAIL" "answering produced a call that carried nothing: $(grep -oE 'NO KEY|crypt on' "$SP/d.log" | sort | uniq -c | tr '\n' ' ')"
car=$(grep -oE "recv [0-9]+/s" "$SP/c.log" | grep -vc "recv 0/s")
[ "${car:-0}" -gt 0 ] \
  && say "OK" "with the caller receiving too ($car reports)" \
  || say "FAIL" "the caller never received anything after the answer"
case "$D_ST" in
  alive) say "OK" "and the process that answered is still running as the call" ;;
  *) say "FAIL" "the process that answered died: $D_ST -- read the crash report, do not rerun past it" ;;
esac

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
# Only the RING phase: the same log goes on into the answered call below (the
# re-exec keeps the file descriptor), and that call is supposed to carry media.
STRANGERECV=$(sed -n '1,/ring: answer committed/p' "$SP/g.log" | grep -oE "recv [0-9]+/s" | grep -vc "recv 0/s")
[ "${STRANGERECV:-1}" = "0" ] \
  && say "OK" "and it received nothing while ringing, so it revealed nothing" \
  || say "FAIL" "a stranger's ring opened a path before it was answered: $STRANGERECV reports received"
grep -q "card=ringing" "$SP/g.log" \
  && say "OK" "CONTROL: a stranger can still ring you -- the card is there" \
  || say "FAIL" "a stranger cannot ring at all now, which is not the rule"
# ── AND ANSWERING A STRANGER STARTS A CALL, INSTEAD OF ENDING KIN ───────────
#
# 0.157.0 read the audio engine on the way out of every exit that happens before
# a call -- this answer, a cancel, a caller hanging up while this Mac rang -- and
# died with SIGSEGV each time. The bye had already left, so every rig that pressed
# those buttons stayed green. The verdict is therefore the process itself: it
# re-execs into the call (same pid, new image), is still there afterwards, and the
# call it walked into carries media.
grep -q "ring: answer committed by NSEventType" "$SP/g.log" \
  && say "OK" "the stranger's ring took a real answer click" \
  || say "FAIL" "the answer press never reached the stranger's card"
grep -q "re-exec into $R4 -- ring answered" "$SP/g.log" \
  && say "OK" "and the answer handed over into the call" \
  || say "FAIL" "the answer never handed over: $(grep -E '^launch:|^ring:' "$SP/g.log" | tail -2 | tr '\n' ' ')"
case "$G_ST" in
  alive) say "OK" "and the process that answered a stranger is still running as the call" ;;
  *) say "FAIL" "the process that answered a stranger's ring died: $G_ST -- read the crash report, do not rerun past it" ;;
esac
GRECV=$(grep -oE "recv [0-9]+/s" "$SP/g.log" | grep -vc "recv 0/s")
[ "${GRECV:-0}" -gt 0 ] \
  && say "OK" "and the call it walked into carried media ($GRECV reports with the caller's stream)" \
  || say "FAIL" "the answered stranger's call carried nothing"

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
spawn env TK_KIN_DIR="$CALLER" "$TK" --window --room "$RK" --listen 8027 --peer 127.0.0.1:8028 --video off \
      --mute --route headphones --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --calling tester > "$SP/k1.log" 2>&1
perl -e 'select undef,undef,undef,2'
# `--press-after 0.2` puts the first Return inside the 600 ms window; the second,
# a token later, lands well outside it.
spawn env TK_KIN_DIR="$CALLEE" "$TK" --window --room "$RK" --listen 8028 --peer 127.0.0.1:8027 --video off \
      --mute --route headphones --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
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
spawn env TK_KIN_DIR="$CALLER" "$TK" --window --room "$RE" --listen 8029 --peer 127.0.0.1:8030 --video off \
      --mute --route headphones --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --calling tester > "$SP/e1.log" 2>&1
perl -e 'select undef,undef,undef,2'
spawn env TK_KIN_DIR="$CALLEE" "$TK" --window --room "$RE" --listen 8030 --peer 127.0.0.1:8029 --video off \
      --mute --route headphones --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --incoming somebody --incoming-key "$KEY" --press-after 2 \
      --press "key:esc" > "$SP/e2.log" 2>&1
E2PID=$LAST_PID
perl -e 'select undef,undef,undef,8'
E2_ST="$(status_of "$E2PID")"
reap
grep -q "ring: declined from the keyboard" "$SP/e2.log" \
  && say OK "Escape declines, with no waiting period" \
  || { say FAIL "Escape did not decline the call:"
       grep -E "^ring:|^key " "$SP/e2.log" | tail -3 | sed 's/^/         /'; fail=1; }
# A decline is an exit too, and it must be exit 0 -- not the third crash path.
case "$E2_ST" in
  "exit 0") say OK "and the declining copy left cleanly (exit 0)" ;;
  alive) say FAIL "the declining copy is still running after Escape"; fail=1 ;;
  *) say FAIL "the declining copy died: $E2_ST -- read the crash report"; fail=1 ;;
esac
fi

# ── AND NOTHING DIED ─────────────────────────────────────────────────────────
# Counted as a delta, like stress-check: another copy of the app may be running
# on this Mac and its reports are not this rig's business.
NEWCRASH=$(( $(crashes) - CRASH0 ))
if [ "$NEWCRASH" -le 0 ]; then
  say OK "no crash reports were written while this ran"
else
  say FAIL "$NEWCRASH crash report(s) written during this run -- read them, do not rerun past them:"
  ls -t "$CRASHDIR" | grep '^tk-' | head -"$NEWCRASH" | sed 's/^/         /'
fi

# The final line used to be printed unconditionally inside the keyboard block, so
# a keyboard failure exited 1 under a line that said PASSED.
if [ "$fail" = 0 ]; then
  echo "PRE-ANSWER CHECK PASSED -- a ring asks, and only an answer starts a call"
else
  echo "PRE-ANSWER CHECK FAILED -- see above; logs in $SP"
  for f in a b c d g; do cp "$SP/$f.log" "${SCRATCH:-${TMPDIR:-/tmp}}/preanswer-$f.log" 2>/dev/null; done
fi
exit $fail
