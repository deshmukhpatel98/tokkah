#!/bin/bash
# ── DOES STOPPING THE PICTURE ACTUALLY HELP? ─────────────────────────────────
#
# The report that caused this file, in the words it arrived in:
#
#   "my Internet speed is quite good, even then when I'm trying to make a call it
#    is saying connection paused due to slow Internet speed... my Internet speed
#    is actually sometimes one Gbps."
#
# The telemetry from those calls said what happened, per beat:
#
#     dLost  vmbps  qlvl  paused
#       161  1.147     1       0     <- loss appears, the picture retreats
#       207  0.379     0       0
#        70      0     0       1     <- the video stops
#       171      0     0       1
#       162      0     0       1     <- ...and the loss is UNCHANGED
#
# The picture went away for the rest of the call, and the harm it went away to fix
# carried on at the same rate with nothing being sent. The signal `VQuality` acts
# on is the far end's AUDIO concealment: good evidence that a path is unhappy, and
# no evidence at all that our video is why.
#
# So the pause now has to earn its keep -- it is judged on whether the harm
# actually fell while the video was off -- and this holds it to that. TWO ARMS,
# and the second one is the whole reason this file is trustworthy:
#
#   A  RATE-INDEPENDENT LOSS (`--imp-drop`). A coin flip per packet: the loss
#      rate does not depend on how much is sent, so pausing CANNOT help. The
#      controller must pause, measure, and give the picture back.
#
#   B  A FULL QUEUE (`--imp-capacity`). A leaky bucket: packets that cannot be
#      paid for are dropped, so sending less genuinely reduces the loss. The
#      controller must pause and KEEP the pause.
#
# Without B, "the pause is always abandoned" would pass -- which is a controller
# that has simply had the feature deleted. An arm that must rank the other way is
# the difference between a test and a rubber stamp.
set -u
cd "$(dirname "$0")/.."
TK="${TK:-./.build/release/tk}"
[ -x "$TK" ] || { echo "build first: swift build -c release"; exit 2; }
export TK_NO_RAISE=1 TK_NO_IDENTITY=1
SP="$(mktemp -d)"
export TK_KIN_DIR="$SP/kin"; mkdir -p "$TK_KIN_DIR"
PIDS=""
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT
echo "scratch: $SP"

# A picture to send, so there is video volume to take away. `testsrc2` moves, so
# the encoder cannot cheat with a static frame.
MEDIA="$SP/talk.mp4"
command -v ffmpeg >/dev/null || { echo "no ffmpeg -- this arm needs a moving picture"; exit 2; }
ffmpeg -y -f lavfi -i "testsrc2=s=1280x720:r=30" -t 60 -c:v libx264 -pix_fmt yuv420p \
       -b:v 6M "$MEDIA" >/dev/null 2>&1

fail=0
say() { printf '  %-5s %s\n' "$1" "$2"; }

# `--vpause-after 2` and `--vquality 0.5` compress the wait: the product takes
# three harmed seconds at the floor and starts three rungs up, which is 20+ s of
# descending before the interesting moment. Every production cadence gets a rig
# override; the thing under test is the VERDICT, not the descent.
run() {                             # run <name> <impair flags...>
  local name="$1"; shift
  local R="vp${name}$$"
  reap; perl -e 'select undef,undef,undef,0.5'
  "$TK" --window --video "$MEDIA" --mute --no-telemetry --no-update --no-relocate \
        --no-rings --no-subtitles --room "$R" --listen 7861 --peer 127.0.0.1:7862 \
        --vquality 0.5 --vpause-after 2 "$@" > "$SP/$name-a.log" 2>&1 &
  PIDS="$PIDS $!"
  "$TK" --window --video off --mute --no-telemetry --no-update --no-relocate \
        --no-rings --no-subtitles --room "$R" --listen 7862 --peer 127.0.0.1:7861 \
        > "$SP/$name-b.log" 2>&1 &
  PIDS="$PIDS $!"
  perl -e 'select undef,undef,undef,42'
  reap
}

# ── A: LOSS THAT DOES NOT CARE HOW MUCH WE SEND ─────────────────────────────
echo "── A. rate-independent loss: the pause cannot help, so it must be abandoned"
run drop --imp-drop 4
VERDICT="$(grep -oE 'voice harm [^]]*with no video: [A-Za-z ]*' "$SP/drop-a.log" | head -1)"
[ -n "$VERDICT" ] && echo "     $VERDICT"
if grep -q "PAUSED" "$SP/drop-a.log"; then
  say OK "the picture did stop -- there is something to judge"
else
  say FAIL "the video never paused at all, so nothing here is being tested"; fail=1
fi
case "$VERDICT" in
  *"THE PAUSE IS NOT HELPING"*) say OK "and the app measured that it did not help" ;;
  "") say FAIL "no verdict was ever reached -- the pause was never judged"; fail=1 ;;
  *) say FAIL "it decided the pause was helping: $VERDICT"; fail=1 ;;
esac
if grep -q "pausing ABANDONED" "$SP/drop-a.log" || grep -q "video resumed" "$SP/drop-a.log"; then
  say OK "and gave the picture back"
else
  say FAIL "the picture never came back -- this is the reported bug, unfixed"; fail=1
fi
# The whole point: at the END of the run there is a picture again.
LASTQ="$(grep -c 'video PAUSED' "$SP/drop-a.log")"
TAILV="$(grep -o 'picture: video resumed' "$SP/drop-a.log" | wc -l | tr -d ' ')"
if [ "${TAILV:-0}" -ge 1 ]; then say OK "resumed $TAILV time(s) after $LASTQ pause(s)"
else say FAIL "never resumed"; fail=1; fi

# ── B: A QUEUE THAT IS ACTUALLY FULL ────────────────────────────────────────
# The control arm, and its number is the whole of its validity. MEASURED on this
# machine, on this media, with the quality pinned to the floor rung:
#
#     video flowing   3.4 Mbps up
#     video paused    1.28 Mbps up
#
# So a ceiling of 1.5 sits between the two: heavily over-committed while the
# picture flows -- over-committed enough that the VOICE suffers, which is what the
# pause exists to fix -- and comfortable the moment the picture stops.
#
# 2.0 was tried first and was the wrong side of the interesting line: the bucket
# dropped a quarter of every second's fragments, which destroyed the picture and
# left the voice untouched, because FEC repairs a proportional share of 1500 small
# packets easily. The controller correctly did nothing, and the arm measured
# nothing.
#
# Worth writing down, because the number that was guessed first was wrong by an
# order of magnitude. `VQuality`'s own header quotes 0.221 Mbps for this rung,
# from a 240-frame measurement -- and against real moving content the same rung
# costs 3.4. The quality knob is a quantiser, not a rate cap, so the "floor" of
# this ladder does not bound the bitrate at all. A first draft of this arm put the
# ceiling at 0.35 and then 1.45 on the strength of that 0.221, and both failed for
# the correct reason: the voice alone did not fit either, so pausing could not
# help and this arm was a second copy of arm A.
echo "── B. CONTROL: a full queue, where pausing DOES help and must be kept"
run cap --imp-capacity 1.5
VERDICT2="$(grep -oE 'voice harm [^]]*with no video: [A-Za-z ]*' "$SP/cap-a.log" | head -1)"
[ -n "$VERDICT2" ] && echo "     $VERDICT2"
case "$VERDICT2" in
  *"the pause is helping"*) say OK "the app measured that the pause worked, and kept it" ;;
  "") say FAIL "no verdict -- the control arm never paused, so arm A proves nothing"; fail=1 ;;
  *) say FAIL "it abandoned a pause that was working: $VERDICT2"; fail=1 ;;
esac
if grep -q "pausing ABANDONED" "$SP/cap-a.log"; then
  say FAIL "a working pause was abandoned -- the two arms agree and neither proves anything"
  fail=1
else
  say OK "and did not abandon it"
fi

[ "$fail" = 0 ] && echo "VPAUSE CHECK PASSED -- the app stops the picture only when that helps, and proves it" \
                || echo "VPAUSE CHECK FAILED"
exit $fail
