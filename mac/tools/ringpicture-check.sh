#!/bin/bash
# ── CAN YOU SEE WHO IS CALLING, OR ONLY BE TOLD THAT BYTES ARRIVED? ──────────
#
# `preanswer-check` proves an unanswered ring sends nothing and that the caller's
# packets ARRIVE. Neither of those is a face. Bytes on the wire, fragments in the
# assembler, even frames out of a decoder are all upstream of the only claim this
# feature makes -- "if someone is calling, their video should be visible to you so
# you know who is calling exactly" -- and this project has already shipped an
# upside-down picture past a rig whose every number was green. So this rig follows
# the frame all the way to the display layer, and then asks whether the card you
# decide with is still in front of it.
#
#   1. DECODED, not merely received: `dec N/s` in the callee's own video report.
#   2. ON THE LAYER: `window .../layer:rendering shown N enqFail 0` from the same
#      line. `shown` only moves when the sample buffer was ACCEPTED by the display
#      layer, and on a ring it can only be the far end -- a ring starts no camera,
#      which this rig asserts rather than assumes, so there are no local frames to
#      confuse it with.
#   3. A PICTURE AND NOT A BLACK RECTANGLE: `decLuma`, the mean luma of the
#      decoded far-end image, read from the pixels. A dead sender, a shut lid and
#      a corrupt stream all decode.
#   4. AND THE DECISION IS STILL THEIRS: `card=ringing` in the tree dump, and an
#      answer control the hit-test audit can still reach, FOURTEEN SECONDS in --
#      long after the first frame. A ring that turns itself into a call the moment
#      a picture lands is the 0.61.0 bug rebuilt out of the feature that needed
#      the socket, which is exactly what main.swift's own comment warns about.
#
# ── THE CONTROLS, AND WHY THERE ARE TWO ──────────────────────────────────────
#
# Every number above is a count, and a broken extractor reports zero for a healthy
# ring exactly as it does for a blind one. So the same pair runs again, twice, both
# times through the SAME extractor functions, and both times has to rank the other
# way. They fail for different reasons, and one of them is the reason this rig
# exists at all:
#
#   `--no-ring-preview` on the callee -- one flag, everything else identical. The
#      ring never joins the room, so nothing arrives and nothing can be shown.
#
#   `--video off` ON THE CALLER -- the ring joins, locks, and receives 1500
#      packets a second, and there is still no picture. This is the arm that
#      separates "the early connection works" from "a face reached the screen",
#      and it is exactly the arm preanswer-check cannot have: its caller runs
#      `--video off` in every part, so a preview that never receives a frame can
#      never reach the line that reacts to one. That blind spot hid a real bug --
#      see main.swift's note beside `if !ringPreview` in `vdec.onDecoded`.
#
# ── AND THE RING HAS TO BE FROM SOMEBODY THIS MAC KNOWS ─────────────────────
#
# 0.64 gates the preview on `gOffered.known`: the ring must carry a device key
# that is already in this Mac's contacts, or it does not connect early at all --
# a stranger who learns your handle must not get your address and a signal that
# you are at your Mac, before you have agreed to anything. So both arms seed a
# contacts.json in their own TK_KIN_DIR and pass the matching `--incoming-key`.
# Without that seeding this rig measures the STRANGER path in both arms, which
# ranks them equal and proves nothing -- it happened, mid-write, when the gate
# landed underneath it.
#
# ── LIMITATION, STATED ───────────────────────────────────────────────────────
#
# The caller's picture is a FILE -- `testbed/media/real/talkingheadA.mov`, a real
# 30 s 720p30 talking head already in this repo, not a synthetic pattern. It is
# the only moving picture a rig can produce here without a person clicking Allow,
# and it is the right one for this question: what is under test is the RECEIVE
# half -- assembler, decoder, layer, card -- which cannot tell a file from a
# sensor. The CALLEE is `--video camera` regardless, because that is what the real
# ring watcher passes, and a rig that asks for no camera cannot see a camera bug.
#
# ── A DEFECT THIS RIG HIT WHILE BEING WRITTEN ────────────────────────────────
#
# `--no-ring-preview` was read by main.swift and missing from KNOWN_FLAGS, so the
# unknown-option guard refused it and exited 2 before the line that reads it could
# run: the documented way to turn this feature off could not be used by anybody,
# and the only working switch was the undocumented TK_RING_PREVIEW=0. Fixed in
# 0.64 while this was being written. It needs no assertion of its own -- the
# control arm passes the flag, so a build that refuses it again never prints a
# banner and this rig stops at COULD NOT RUN with the refusal quoted.
set -u
# Ring windows do not throw themselves in front of whatever the person at this Mac
# is doing, and a rig must never take the screen from them either. Same switch and
# the same reason as every other script in this directory.
export TK_NO_RAISE=1
# ── KILLS ONLY WHAT THIS SCRIPT STARTED ─────────────────────────────────────
#
# Never `pkill -f`: it takes a REGEX, and in a path like `./.build/debug/tk` every
# `.` matches any character, so the pattern reaches into other checkouts and reaps
# another agent's processes. PIDs only.
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/ringpicture-check.$$"
mkdir -p "$SP"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
# A REAL MOVING PICTURE -- and the path has a space in it. `FileSource` carries a
# whole comment about the afternoon an unquoted expansion cut this path off at
# "video" and three runs labelled the video arm ran with no video at all.
MEDIA="${MEDIA:-$HERE/../../testbed/media/real/talkingheadA.mov}"
# ── `-f` ANSWERS A QUESTION THE APP DOES NOT ASK ─────────────────────────────
#
# This was `[ -f "$MEDIA" ]`, which stats. On 2026-08-26 the whole repo went
# EPERM for a while -- the harness lost its file-access permission -- and stat
# kept working while open() did not. So the guard passed, the rig ran, the app
# could not read a single byte of the picture, and the run reported 10 failing
# assertions that all read as product regressions.
#
# The guard has to do the thing the app does. One byte is enough.
if ! head -c 1 "$MEDIA" > /dev/null 2>&1; then
  echo "cannot READ $MEDIA -- this rig needs a real moving picture, and stat is not proof that one can be opened"
  exit 2
fi
# No handle claimed on the real server, and nothing read from or written to the
# user's real install: these are rig processes, not somebody's copy of Kin.
export TK_NO_IDENTITY=1
export TK_KIN_DIR="$SP/kin"
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT
# ── THE CALLER IS SOMEBODY THIS MAC HAS ALREADY TALKED TO ───────────────────
#
# Written into this rig's OWN contacts file, never the real one, and matched by
# `--incoming-key` below. Any string does: `known` is a literal comparison of the
# key in argv against the key stored under that handle.
KEY="kinrigtestkey0000"
mkdir -p "$TK_KIN_DIR"
printf '{"somebody":"%s"}\n' "$KEY" > "$TK_KIN_DIR/contacts.json"

# ── PART ONE: somebody is calling, and you can see them ─────────────────────
R1="ringpic$$a"
spawn "$TK" --window --room "$R1" --listen 8071 --peer 127.0.0.1:8072 --video "$MEDIA" \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --calling tester > "$SP/a.log" 2>&1
CALLER_A=$LAST_PID
perl -e 'select undef,undef,undef,2'
# Exactly the watcher's launch line. The audit fires at 14 s -- a dozen seconds
# after the first frame -- so "the card survived the picture" is a claim about the
# steady state and not about one lucky instant.
spawn "$TK" --window --room "$R1" --listen 8072 --peer 127.0.0.1:8071 --video camera \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --incoming somebody --incoming-key "$KEY" --press-after 14 --press "?" > "$SP/b.log" 2>&1
CALLEE_B=$LAST_PID
perl -e 'select undef,undef,undef,18'
# STILL ALIVE WHEN IT WAS MEASURED. An arm whose processes died reads zero for
# every count in it, which is indistinguishable from a feature that does nothing.
kill -0 "$CALLER_A" 2>/dev/null && ALIVE_A=yes || ALIVE_A=no
kill -0 "$CALLEE_B" 2>/dev/null && ALIVE_B=yes || ALIVE_B=no
reap
perl -e 'select undef,undef,undef,1'

# ── PART TWO: THE CONTROL -- the same pair, the preview switched off ────────
#
# Same binary, same media, same ports, same presses, same contact, same 14 s
# audit. `--no-ring-preview` is the only difference between the two arms.
R2="ringpic$$b"
spawn "$TK" --window --room "$R2" --listen 8071 --peer 127.0.0.1:8072 --video "$MEDIA" \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --calling tester > "$SP/c.log" 2>&1
CALLER_C=$LAST_PID
perl -e 'select undef,undef,undef,2'
spawn "$TK" --window --room "$R2" --listen 8072 --peer 127.0.0.1:8071 --video camera \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --incoming somebody --incoming-key "$KEY" --no-ring-preview \
      --press-after 14 --press "?" > "$SP/d.log" 2>&1
CALLEE_D=$LAST_PID
perl -e 'select undef,undef,undef,18'
kill -0 "$CALLER_C" 2>/dev/null && ALIVE_C=yes || ALIVE_C=no
kill -0 "$CALLEE_D" 2>/dev/null && ALIVE_D=yes || ALIVE_D=no
reap
perl -e 'select undef,undef,undef,1'

# ── PART THREE: THE CONTROL THAT ISOLATES THE PICTURE ───────────────────────
#
# The ring is armed, the room is joined, the transport locks and packets pour in
# -- and the caller has no camera. Every claim preanswer-check makes about this
# feature is still true here, and there is nothing to look at. If the numbers in
# part one came from the CONNECTION rather than from a picture, they would survive
# this arm unchanged.
R3="ringpic$$c"
spawn "$TK" --window --room "$R3" --listen 8071 --peer 127.0.0.1:8072 --video off \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --calling tester > "$SP/e.log" 2>&1
CALLER_E=$LAST_PID
perl -e 'select undef,undef,undef,2'
spawn "$TK" --window --room "$R3" --listen 8072 --peer 127.0.0.1:8071 --video camera \
      --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles \
      --incoming somebody --incoming-key "$KEY" --press-after 14 --press "?" > "$SP/f.log" 2>&1
CALLEE_F=$LAST_PID
perl -e 'select undef,undef,undef,18'
kill -0 "$CALLER_E" 2>/dev/null && ALIVE_E=yes || ALIVE_E=no
kill -0 "$CALLEE_F" 2>/dev/null && ALIVE_F=yes || ALIVE_F=no
reap

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }
note() { printf "  %-4s %s\n" "NOTE" "$1"; }
for f in a b c d e f; do
  grep -q "^tk " "$SP/$f.log" || {
    echo "RING PICTURE CHECK COULD NOT RUN -- tk never started in $f:"
    sed -n '1,5p' "$SP/$f.log" | sed 's/^/  /'; exit 2; }
done

# ── ONE RULER, READ THE SAME WAY IN BOTH ARMS ───────────────────────────────
#
# Every number below comes out of these four functions, so the control arm cannot
# be passed by a different measurement than the one the live arm was passed by.
max_of()    { grep -oE "$2" "$1" | grep -oE "[0-9]+" | sort -n | tail -1; }
dec_max()   { max_of "$1" "dec [0-9]+/s"; }
enc_max()   { max_of "$1" "enc [0-9]+/s"; }
shown_max() { max_of "$1" "shown [0-9]+ enqFail"; }
luma_max()  { max_of "$1" "decLuma [0-9]+"; }
recv_max()  { max_of "$1" "recv [0-9]+/s"; }

DEC_A=$(dec_max     "$SP/b.log"); DEC_A=${DEC_A:-0}
ENC_A=$(enc_max     "$SP/b.log"); ENC_A=${ENC_A:-0}
SHOWN_A=$(shown_max "$SP/b.log"); SHOWN_A=${SHOWN_A:-0}
LUMA_A=$(luma_max   "$SP/b.log"); LUMA_A=${LUMA_A:-0}
DEC_D=$(dec_max     "$SP/d.log"); DEC_D=${DEC_D:-0}
SHOWN_D=$(shown_max "$SP/d.log"); SHOWN_D=${SHOWN_D:-0}
LUMA_D=$(luma_max   "$SP/d.log"); LUMA_D=${LUMA_D:-0}
DEC_F=$(dec_max     "$SP/f.log"); DEC_F=${DEC_F:-0}
SHOWN_F=$(shown_max "$SP/f.log"); SHOWN_F=${SHOWN_F:-0}
LUMA_F=$(luma_max   "$SP/f.log"); LUMA_F=${LUMA_F:-0}
RECV_A=$(recv_max   "$SP/b.log"); RECV_A=${RECV_A:-0}
RECV_F=$(recv_max   "$SP/f.log"); RECV_F=${RECV_F:-0}
CALLER_ENC=$(enc_max "$SP/a.log"); CALLER_ENC=${CALLER_ENC:-0}
ENQF_A=$(max_of "$SP/b.log" "enqFail [0-9]+"); ENQF_A=${ENQF_A:-0}
CLICKS_A=$(grep -c "^audit [A-Z]" "$SP/b.log")
CLICKS_D=$(grep -c "^audit [A-Z]" "$SP/d.log")

# ── 0. THE ARMS RAN, AND WERE STILL RUNNING WHEN THEY WERE READ ─────────────
[ "$ALIVE_A" = yes ] && [ "$ALIVE_B" = yes ] \
  && say "OK" "both ends of the live arm were alive at the measurement" \
  || say "FAIL" "an end of the live arm died first (caller=$ALIVE_A callee=$ALIVE_B)"
[ "$ALIVE_C" = yes ] && [ "$ALIVE_D" = yes ] && [ "$ALIVE_E" = yes ] && [ "$ALIVE_F" = yes ] \
  && say "OK" "and both ends of both control arms, so their zeroes are switches not deaths" \
  || say "FAIL" "an end of a control arm died first (C=$ALIVE_C D=$ALIVE_D E=$ALIVE_E F=$ALIVE_F)"
# The press firing is the honest proof of life at the moment of the audit: it is
# dispatched on the callee's own main queue, so it cannot run in a dead process.
grep -q "^press ?: due at" "$SP/b.log" \
  && say "OK" "and the live arm's audit really fired at 14 s: $(grep -o 'ran at [0-9]* ms' "$SP/b.log" | head -1)" \
  || say "FAIL" "the live arm's audit press never ran, so its tree dump is from nowhere"
grep -q "^press ?: due at" "$SP/d.log" \
  && say "OK" "and the control arm's too: $(grep -o 'ran at [0-9]* ms' "$SP/d.log" | head -1)" \
  || say "FAIL" "the control arm's audit press never ran"
[ "$CALLER_ENC" -gt 0 ] \
  && say "OK" "the caller really sent a picture -- $CALLER_ENC frames/s of $(basename "$MEDIA")" \
  || say "FAIL" "the caller encoded nothing, so nothing below is about a picture"
grep -q "ring: waiting to be answered -- no microphone, no camera, their picture only" "$SP/b.log" \
  && say "OK" "and the callee took the ring-preview path" \
  || say "FAIL" "the callee never armed the preview: $(grep -o 'ring: waiting.*' "$SP/b.log" | head -1)"
# The 0.64 privacy gate, checked from the other side: if the seeded contact were
# not matching, BOTH arms would take the stranger path and rank equal -- a rig
# comparing an arm against itself, which this project has shipped three times.
grep -q "is not in this Mac's contacts" "$SP/b.log" \
  && say "FAIL" "the caller was a STRANGER to this Mac, so both arms are the same arm" \
  || say "OK" "and the caller is a known contact, which is what unlocks the preview"

echo
# ── 1. THE CALLEE DECODED, NOT MERELY RECEIVED ──────────────────────────────
#
# `recv N/s` is all preanswer-check can say, and it is true of a stream that never
# once produced an image. `dec` is frames out of the decoder.
[ "$DEC_A" -ge 10 ] \
  && say "OK" "their video DECODED on the ring -- $DEC_A frames/s out of the decoder" \
  || say "FAIL" "the ring decoded $DEC_A frames/s -- bytes arriving is not a picture"
[ "$ENC_A" = "0" ] \
  && say "OK" "while sending none of its own -- enc 0/s in every report" \
  || say "FAIL" "the unanswered ring sent $ENC_A frames/s of its own camera"

# ── 2. AND IT REACHED THE LAYER ─────────────────────────────────────────────
#
# Decoded frames live in memory. A frame refused by the display layer is invisible
# and every count above it still reads perfectly healthy.
[ "$SHOWN_A" -ge 30 ] \
  && say "OK" "and reached the window layer -- $SHOWN_A frames accepted for display" \
  || say "FAIL" "$DEC_A frames/s decoded and only $SHOWN_A reached the layer"
LAYER_A=$(grep -oE "layer:[A-Za-z?]+" "$SP/b.log" | tail -1)
[ "$LAYER_A" = "layer:rendering" ] \
  && say "OK" "with the layer rendering rather than failed ($LAYER_A)" \
  || say "FAIL" "the display layer was [${LAYER_A:-absent}] -- frames went into a layer that is not drawing"
[ "$ENQF_A" = "0" ] \
  && say "OK" "and it refused none of them" \
  || say "FAIL" "the layer refused $ENQF_A frames"
grep -q "window visible/onscreen" "$SP/b.log" \
  && say "OK" "in a window that is visible and not occluded" \
  || { STATE="$(grep -oE 'window [a-z]+/[a-z]+' "$SP/b.log" | tail -1 | sed 's/^window //')"
       # ── AN OCCLUDED WINDOW IS THIS MAC, NOT THE BUILD ──────────────────────
       #
       # The message used to read "the window was window visible/occluded", which
       # is both mangled and misleading: it looks like a broken assertion when it
       # is the rig correctly refusing to report on a photograph nobody could have
       # taken. On a Mac whose owner has Kin open -- the normal state of the
       # machine this suite runs on -- every rig window is parked at the desktop
       # level and sits behind it.
       case "$STATE" in
         *occluded*)
           say "FAIL" "the ring window was OCCLUDED ($STATE), so nothing could be"
           say "FAIL" "  photographed. Close any open Kin window and run this again:"
           say "FAIL" "  it is a fact about this Mac, not about the build." ;;
         *) say "FAIL" "the ring window was $STATE -- nobody could have seen it" ;;
       esac; }
# WHOSE FRAMES THOSE WERE. `shown` is incremented by the self-view too, so the
# claim "shown means the far end" holds only because a ring starts no camera --
# asserted here rather than assumed, since it is the guarantee a future change to
# this feature would break first.
grep -q "camera: bring-up" "$SP/b.log" \
  && say "FAIL" 'the ring started its own camera, so "shown" cannot mean the far end' \
  || say "OK" "and no camera ran on this end, so every one of them was THEIRS"
grep -q "the other side's picture is on screen" "$SP/b.log" \
  && say "OK" "the app says so itself: the other side's picture is on screen" \
  || say "FAIL" "the display never announced a remote frame"
# NOT PICTURE EVIDENCE, and it is worded so that nobody can read it as such. It
# is printed at the TRANSPORT LOCK, before a single frame has been decoded, so it
# says which branch was taken and nothing about anything being visible. It used
# to read "their picture is on the ring card" -- which part three below printed
# with no picture in existence, and which preanswer-check asserted on as proof of
# the entire feature. Both were corrected; part three now guards the correction.
grep -q "the ring card reached them" "$SP/b.log" \
  && say "OK" "and the lock took the ring branch rather than the connected one" \
  || say "FAIL" "the lock did not take the ring branch"

# ── 3. AND IT WAS A PICTURE, NOT A BLACK RECTANGLE ──────────────────────────
#
# A sender that died, a shut lid and a corrupt stream all produce frames.
# `decLuma` is the mean luma of the decoded far-end image, sampled from the
# pixels; a lit talking head sits well clear of both ends of the range.
[ "$LUMA_A" -ge 20 ] && [ "$LUMA_A" -le 245 ] \
  && say "OK" "and a lit picture rather than a black one -- decLuma $LUMA_A" \
  || say "FAIL" "the decoded picture read decLuma $LUMA_A -- black, blown out, or garbage"

echo
# ── 4. AND THE DECISION IS STILL THEIRS ─────────────────────────────────────
#
# Fourteen seconds in, with their face on screen for twelve of them. The whole
# feature is "see who is calling BEFORE you answer", so the card that lets
# somebody say no has to survive the thing that was added to help them decide.
AUD_A=$(grep '^audit state' "$SP/b.log" | tail -1)
echo "$AUD_A" | grep -q 'card=ringing' \
  && say "OK" "and after all that the ring card is STILL up -- nobody has decided" \
  || say "FAIL" "the picture took the card away: $(echo "$AUD_A" | grep -o 'card=[a-zA-Z]*') $(echo "$AUD_A" | grep -o 'status=[^ ]*') (the words are still set: $(echo "$AUD_A" | grep -o 'says=\"[^\"]*\"'))"
# A CARD IS NOT A CONTROL. `auditClicks` hit-tests every registered target, so
# this is the difference between a button being drawn and a finger being able to
# land on it -- the one gap every interaction bug in this project has lived in.
# `SELF` counts: the waiting card claims its own bounds and routes by frame in
# `mouseDown`, so a hit that lands on the card IS a hit on the button. `FAIL`, and
# a target that is not listed at all, are the two that mean nobody can press it.
grep -qE "^audit (OK|SELF) +answer at " "$SP/b.log" \
  && say "OK" "with an answer button a finger can still reach" \
  || say "FAIL" "no reachable answer control -- $CLICKS_A clickable things on the whole ring window"

echo
# ── 5. THE CONTROL, THROUGH THE SAME RULER ──────────────────────────────────
grep -q "ring: waiting to be answered -- no microphone, no camera, no room" "$SP/d.log" \
  && say "OK" "CONTROL: the preview is off, and the ring says so -- no room" \
  || say "FAIL" "CONTROL: the preview was never switched off, so this arm proves nothing"
[ "$DEC_D" = "0" ] \
  && say "OK" "CONTROL: it decoded nothing -- $DEC_A/s with the preview on, $DEC_D/s with it off" \
  || say "FAIL" "CONTROL: $DEC_D frames/s decoded with the preview OFF -- the switch does nothing"
[ "$SHOWN_D" = "0" ] \
  && say "OK" "CONTROL: and nothing reached the layer -- $SHOWN_A vs $SHOWN_D" \
  || say "FAIL" "CONTROL: $SHOWN_D frames reached the layer with the preview off"
[ "$LUMA_D" = "0" ] \
  && say "OK" "CONTROL: and there was no picture to measure -- decLuma $LUMA_A vs $LUMA_D" \
  || say "FAIL" "CONTROL: it measured a picture (decLuma $LUMA_D) with the preview off"
grep -q "the other side's picture is on screen" "$SP/d.log" \
  && say "FAIL" "CONTROL: it announced a remote frame with the preview off" \
  || say "OK" "CONTROL: and never announced one"
# THE OTHER HALF OF THE RANKING, and the reason the two arms are worth running:
# with no picture the card and its button are exactly where the live arm's should
# have been. So the instrument can see them, and the live arm's verdict is about
# the app rather than about the audit.
AUD_D=$(grep '^audit state' "$SP/d.log" | tail -1)
echo "$AUD_D" | grep -q 'card=ringing' \
  && say "OK" "CONTROL: while still asking -- card=ringing, so the arm was alive and drawing" \
  || say "FAIL" "CONTROL: no ring card either, so its zeroes are a dead window not a switch"
grep -qE "^audit (OK|SELF) +answer at " "$SP/d.log" \
  && say "OK" "CONTROL: with a reachable answer button ($CLICKS_D clickable), so the audit CAN see one" \
  || say "FAIL" "CONTROL: the audit sees no answer button even here -- the instrument is blind"

echo
# ── 6. AND THE CONTROL THAT KEEPS THE CONNECTION AND REMOVES THE PICTURE ────
#
# Everything preanswer-check checks is TRUE in this arm. If the numbers in part
# one were really about a connection rather than a face, they would survive here.
grep -q "ring: waiting to be answered -- no microphone, no camera, their picture only" "$SP/f.log" \
  && say "OK" "CAMERA-OFF CALLER: the preview is armed, exactly as in part one" \
  || say "FAIL" "CAMERA-OFF CALLER: the preview never armed, so this arm differs by more than a camera"
[ "$RECV_F" -gt 100 ] \
  && say "OK" "CAMERA-OFF CALLER: and the ring connected -- recv $RECV_F/s against $RECV_A/s in part one" \
  || say "FAIL" "CAMERA-OFF CALLER: it never connected ($RECV_F/s), so this is the same arm as the one above"
[ "$DEC_F" = "0" ] && [ "$SHOWN_F" = "0" ] && [ "$LUMA_F" = "0" ] \
  && say "OK" "CAMERA-OFF CALLER: and the ruler still read zero -- dec $DEC_F, layer $SHOWN_F, decLuma $LUMA_F" \
  || say "FAIL" "CAMERA-OFF CALLER: dec $DEC_F, layer $SHOWN_F, decLuma $LUMA_F from a caller with no camera"
grep -q "the other side's picture is on screen" "$SP/f.log" \
  && say "FAIL" "CAMERA-OFF CALLER: the display announced a remote frame that cannot exist" \
  || say "OK" "CAMERA-OFF CALLER: and announced no frame"
echo "$(grep '^audit state' "$SP/f.log" | tail -1)" | grep -q 'card=ringing' \
  && say "OK" "CAMERA-OFF CALLER: with the ring card up, so it is still a ring" \
  || say "FAIL" "CAMERA-OFF CALLER: the card went away without any picture to take it"
# ── THE REGRESSION GUARD FOR THE DEFECT THIS RIG FOUND ──────────────────────
#
# This arm is the one place in the repo where a ring locks and no picture can
# possibly exist, which makes it the only arm that can tell a claim about the
# TRANSPORT from a claim about a FACE. The app used to fail it: the lock printed
# "their picture is on the ring card" and counted `ring_preview_picture` right
# here, so the log line, the counter and the dashboard word all reported a face
# that nothing had drawn. If any of that language ever comes back to the lock,
# every instrument downstream goes blind again -- so it fails here, loudly.
grep -qE "picture is on the ring card|their picture is on" "$SP/f.log" \
  && say "FAIL" "CAMERA-OFF CALLER: the lock claimed a picture again -- the log line has regressed" \
  || say "OK" "CAMERA-OFF CALLER: and the lock claims a connection, never a face"

echo
if [ "$fail" = 0 ]; then
  echo "RING PICTURE CHECK PASSED -- you can SEE who is calling, and still say no"
else
  echo "RING PICTURE CHECK FAILED -- see above; logs in $SP"
  for f in a b c d e f; do cp "$SP/$f.log" "${SCRATCH:-${TMPDIR:-/tmp}}/ringpicture-$f.log" 2>/dev/null; done
  echo "  copies at ${SCRATCH:-${TMPDIR:-/tmp}}/ringpicture-{a,b,c,d,e,f}.log"
fi
exit $fail
