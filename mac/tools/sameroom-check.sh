#!/bin/bash
# ── "TWO DEVICES SIDE BY SIDE, AND A LOT OF ECHO" ────────────────────────────
#
# Reported from a live call, in these words: "two devices side by side, there was
# a lot of echo, and I don't know why since only one mic is active at a time.
# That was very confusing."
#
# It is confusing because it is not echo. One person, two Macs. This Mac's
# microphone hears them through the air; the OTHER Mac's microphone hears them
# too, ships it over the network, and this Mac's speaker plays it back into the
# same room a mouth-to-ear later. No echo canceller can touch that -- it is not
# this speaker feeding this microphone -- and the duplex gate cannot either,
# because the problem is a live SPEAKER and not a second live microphone.
#
# The signature is one a remote call cannot fake: the microphone had the far
# person's voice BEFORE the speaker played it. This script drives that signature
# through a real call and checks that the app notices it, silences the speaker,
# says so in words, and puts it back.
#
# ── THE CONTROL ARM IS THE POINT ────────────────────────────────────────────
#
# A detector that says "same room" is worthless unless something makes it say
# "remote", so this runs the identical call twice and changes ONE thing: whether
# the two ends are carrying the same voice. Same voice = one room. Different
# voices = a genuine remote call. The two must come out opposite ways, and the
# distance between them is printed as the verdict. A rig blind to the defect
# reports PASS while shipping it, and that has happened here repeatedly.
#
# The offline half -- the calibration that chose the thresholds -- is
# `tk --sameroom-test`, which this runs first. That one is arithmetic over a
# fixed buffer and needs no port, no device and no window.
set -u
# Ring windows do not throw themselves in front of the person using this Mac.
export TK_NO_RAISE=1
# NO HANDLE AT ALL: `--no-update` no longer disables the identity claim, so
# without this every run walks @devesh, @deveshp, @devesh2 ... on the REAL
# server, squatting names a person may want.
export TK_NO_IDENTITY=1

# ── KILLS ONLY WHAT THIS SCRIPT STARTED ─────────────────────────────────────
#
# Never `pkill -f "$TK"`. `pkill -f` takes a REGEX, and in a path like
# `./.build/debug/tk` every `.` matches any character -- it has already reaped
# another agent's processes in another checkout and corrupted their measurements
# from the outside. PIDs, therefore.
PIDS=""
spawn() { "$@" & PIDS="$PIDS $!"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
# There is no `timeout` on this machine.
nap() { perl -e "select undef,undef,undef,$1"; }

HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/sameroom-check.$$"
mkdir -p "$SP"
export TK_KIN_DIR="$SP/kin"
trap 'reap; rm -rf "$SP"' EXIT
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }

# ── REAL SPEECH, NOT A TONE AND NOT NOISE ───────────────────────────────────
#
# Two unrelated speech signals correlate: both carry speech's envelope and a
# pitch in the same octave, so the best of eighteen hundred candidate lags finds
# something. Noise does not do that, which means a rig built on noise reports a
# null near zero, a margin that looks enormous, and a detector that fires on the
# first real conversation. `say` is a real speech synthesiser producing real
# formants and real syllables, it is on every Mac, and it is byte-identical from
# run to run -- so the arms are comparable and nobody has to download anything.
mkdir -p "$SP/media"
say -v Daniel -o "$SP/media/one.aiff" \
  "The measurement that matters is the one taken on a live call between two machines, \
   not the one taken on a rig that chose its own conditions. Every millisecond that is \
   not propagation is still a defect, and a rig that is blind to a defect will report a \
   pass while shipping it. So the first thing to calibrate is the ruler itself, against \
   two inputs whose answers are already known." 2>/dev/null
say -v Samantha -o "$SP/media/two.aiff" \
  "Yesterday afternoon I walked down to the harbour and watched the boats coming in past \
   the breakwater. There were gulls everywhere, arguing over something one of the \
   fishermen had dropped, and the light was doing that thing it does in late August \
   where everything looks slightly gold. I sat on the wall for nearly an hour." 2>/dev/null
[ -s "$SP/media/one.aiff" ] && [ -s "$SP/media/two.aiff" ] \
  || { echo "  could not synthesise speech with \`say\` -- nothing to test with"; exit 2; }

bad=0
say_ok()    { echo "   ok   $1"; }
say_wrong() { echo "  WRONG $1"; bad=1; }

echo "── the ruler, before anything acts on it ────────────────────────────────"
# The offline calibration: does the detector rank two KNOWN inputs opposite ways,
# and by how much. Run on the same recorded speech the live arms use, so the
# offline margin and the live margin are about the same voices.
"$TK" --sameroom-test --sameroom-audio "$SP/media/one.aiff,$SP/media/two.aiff" \
  > "$SP/calib.log" 2>&1
CAL=$?
sed 's/^/  /' "$SP/calib.log" | grep -vE "^  room:"
[ "$CAL" = 0 ] || { echo "  the ruler failed its own calibration -- nothing below is worth reading"; exit 1; }

# ── ONE LIVE CALL, RUN TWICE, WITH ONE THING CHANGED ────────────────────────
#
# `--imp-delay 60` is not decoration. Two processes on one Mac have a
# mouth-to-ear of about 12 ms, and the two device latencies alone are 21 -- so
# the "one crossing" reference the attribution needs comes out NEGATIVE and the
# app correctly refuses to attribute anything. Sixty milliseconds of real one-way
# propagation, through the real impairment path, gives the call a crossing it can
# actually measure. It is also what the complaint describes: two machines far
# enough apart in time to hear yourself, close enough in space to be one room.
#
# TK_ROOM_WINDOW shortens the ten seconds the decision is taken over. It is a
# CADENCE override, the kind every timed thing in this project has; the enter and
# leave counts scale with it, so the RATE being demanded is unchanged.
#
# TK_SRC_WALLCLOCK phase-locks the `--audio` substitute to the host clock. Two
# microphones in one room receive the same sound at the same instant; two
# processes started a fifth of a second apart do not. Measured before this
# existed: the two ends' file positions were 215 ms out of phase, the backward
# search found the voice 266 ms early instead of 51, and the app -- correctly --
# called that the far end looping us back rather than one room. The rig was
# modelling the wrong thing, and it took the app's own attribution to say so.
C="--window --video off --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles"
D="--imp-delay 60"

run_arm() {                       # $1 name  $2 A's voice  $3 B's voice  $4 extra A args
  local name="$1" va="$2" vb="$3" extra="${4:-}"
  reap; nap 0.6
  spawn "$TK" $C $D --room "sr$name$$" --listen 8300 --peer 127.0.0.1:8301 \
        --audio "$SP/media/$va" $extra > "$SP/$name-a.log" 2>&1
  spawn "$TK" $C $D --room "sr$name$$" --listen 8301 --peer 127.0.0.1:8300 \
        --audio "$SP/media/$vb" > "$SP/$name-b.log" 2>&1
  nap 26
  reap; nap 0.4
}

# The strongest correlation this end reported, and the lag it was at.
best_corr() { grep -oE "backward [0-9.]+ at [0-9.]+ ms" "$1" | awk '{print $2}' | sort -g | tail -1; }
lag_at()    { grep -oE "backward [0-9.]+ at [0-9.]+ ms" "$1" | sort -g -k2 | tail -1 | awk '{print $4}'; }

echo
echo "── one person, two machines: THE SAME voice reaches both microphones ────"
export TK_ROOM_WINDOW=8
export TK_SRC_WALLCLOCK=1
run_arm same one.aiff one.aiff
SAME_A="$(best_corr "$SP/same-a.log")"; SAME_B="$(best_corr "$SP/same-b.log")"
SAME_LAG="$(lag_at "$SP/same-a.log")"
echo "  A saw ${SAME_A:-none} at ${SAME_LAG:-?} ms, B saw ${SAME_B:-none}"
grep -hoE "^  room: backward.*" "$SP/same-a.log" | tail -2 | sed 's/^/    /'

echo
echo "── the control: a GENUINELY remote call, two different voices ───────────"
run_arm remote one.aiff two.aiff
REM_A="$(best_corr "$SP/remote-a.log")"; REM_B="$(best_corr "$SP/remote-b.log")"
echo "  A saw ${REM_A:-none}, B saw ${REM_B:-none}"
grep -hoE "^  room: backward.*" "$SP/remote-a.log" | tail -2 | sed 's/^/    /'

echo
echo "── the verdict ─────────────────────────────────────────────────────────"
if [ -n "${SAME_A:-}" ] && [ -n "${REM_A:-}" ]; then
  MARGIN="$(awk -v a="$SAME_A" -v b="$REM_A" 'BEGIN{printf "%.3f", a-b}')"
  echo "  live margin: same room $SAME_A - remote $REM_A = $MARGIN"
  awk -v m="$MARGIN" 'BEGIN{exit !(m>=0.20)}' \
    && say_ok "the two arms rank opposite ways on a real call, by $MARGIN" \
    || say_wrong "the two arms are only $MARGIN apart -- the detector cannot tell them apart live"
else
  say_wrong "one of the arms produced no backward estimate at all"
fi

# The whole point of the feature: it must ACT, and only in the right arm.
if grep -q "you are both in the same room" "$SP/same-a.log"; then
  say_ok "it decided, and turned this Mac's speaker off"
else
  say_wrong "it never decided -- lag was ${SAME_LAG:-?} ms; see $SP/same-a.log"
fi
if grep -q "you are both in the same room" "$SP/remote-a.log"; then
  say_wrong "IT SILENCED A REMOTE CALL. This is the expensive failure."
else
  say_ok "and it left the genuinely remote call alone"
fi
# Consumer language, on screen, with no numbers in it.
if grep -q "warning: You're in the same room, so Kin turned this speaker off." "$SP/same-a.log"; then
  say_ok "and said so in one plain sentence, with no numbers in it"
else
  say_wrong "nothing appeared on screen"
fi

# ── AND IT MUST STILL BE SURE AFTER IT HAS ACTED ────────────────────────────
#
# A rig that only tests the entry condition cannot see an oscillation. The
# detector reads the DECODED far stream against the microphone, and `echoHist` is
# written with what was played whether or not the speaker is muted -- so
# silencing removes none of its evidence and the correlation survives its own
# fix. If it had been keyed to the speaker's actual output instead, it would
# silence, lose the evidence, unsilence, hear the room again, and silence again:
# a call flapping once a second. Two bugs in this codebase have that exact shape.
ENTERS="$(grep -c "you are both in the same room" "$SP/same-a.log")"
BACKS="$(grep -c "not the same room any more" "$SP/same-a.log")"
AFTER="$(awk '/you are both in the same room/{seen=1;next} seen && /room: backward/{print}' \
         "$SP/same-a.log" | grep -c "THE SAME ROOM")"
echo "  after silencing: $AFTER further estimates still read SAME ROOM"
if [ "$ENTERS" = 1 ] && [ "$BACKS" = 0 ]; then
  say_ok "one decision and no reversals -- it survives its own fix"
else
  say_wrong "it flapped: $ENTERS decisions, $BACKS reversals"
fi
[ "${AFTER:-0}" -ge 5 ] \
  && say_ok "and it kept agreeing with itself for $AFTER estimates afterwards" \
  || say_wrong "it stopped seeing the room right after acting on it ($AFTER estimates)"

# ── AND THE ARM THAT PROVES THIS SCRIPT CAN FAIL ────────────────────────────
#
# Identical to the first arm in every way except `--no-sameroom`, which leaves
# the detector measuring and reporting and takes away its ability to act. That is
# behaviourally the build from before this feature existed, so if the checks
# above pass here too, they were never testing the feature. Every rig should be
# able to answer "what would you have said about the code without the change",
# and this one can answer it in twenty-six seconds instead of a rebuild.
echo
echo "── the control arm: the same call, with the behaviour switched off ──────"
run_arm off one.aiff one.aiff "--no-sameroom"
OFF_CORR="$(best_corr "$SP/off-a.log")"
echo "  it still measured ${OFF_CORR:-nothing}, and:"
if grep -q "you are both in the same room" "$SP/off-a.log"; then
  say_wrong "it silenced the speaker anyway -- --no-sameroom does nothing"
else
  say_ok "never silenced anything, so the checks above were testing the feature"
fi
if [ -n "${OFF_CORR:-}" ]; then
  say_ok "and kept reporting the correlation, so the control arm is not just a dead build"
else
  say_wrong "it stopped measuring too -- one flag answering two questions"
fi

# ── THE PERSON CAN SAY NO, AND IT HAS TO STICK ──────────────────────────────
#
# An automatic action that re-applies itself over a decision somebody just made
# is worse than not having the action at all. `--press speaker` is that decision.
echo
echo "── and the person can put the speaker back ──────────────────────────────"
run_arm undo one.aiff one.aiff "--press speaker --press-after 14"
if grep -q "pressed speaker: this speaker is now on" "$SP/undo-a.log"; then
  say_ok "one control puts it back"
else
  say_wrong "the control did nothing -- see $SP/undo-a.log"
fi
LATE="$(awk '/pressed speaker: this speaker is now on/{seen=1;next} seen && /room: backward/{print}' \
        "$SP/undo-a.log" | grep -c "this speaker is OFF")"
[ "${LATE:-0}" = 0 ] \
  && say_ok "and it stays back -- the app does not argue with them" \
  || say_wrong "it silenced the speaker again $LATE times after being told not to"

echo
[ "$bad" = 0 ] \
  && echo "  SAME ROOM CHECK PASSED -- it notices one room, leaves a real call alone, says it in words, and can be told no" \
  || echo "  SAME ROOM CHECK FAILED"
exit $bad
