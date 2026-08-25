#!/bin/bash
# ── CAN WE TELL A TURN IS ENDING BEFORE IT ENDS? ────────────────────────────
#
# The gate in Audio.swift is reactive, and a reactive gate has to choose, every
# block, between clipping the first syllable of whoever speaks next and letting
# the room's echo through. That is not a tuning problem: it was tuned, and being
# kinder to interruptions took echo suppression from 19.3 dB to 1.7. At the
# moment of decision an interruption and an echo look the same.
#
# A PREDICTION escapes the trade, because it does not decide in the moment. This
# checks whether one is possible at all -- whether the words so far and the
# speaker's falling level really do separate "they have finished" from "they are
# thinking", far enough in advance to be worth having.
#
# ── WHAT IT MEASURES AND WHAT IT CANNOT ─────────────────────────────────────
#
# The recordings are real speech: NASA interview audio, the same fixtures the
# video work uses. The labels are what the speaker DID NEXT, which the predictor
# is never shown -- a gap of 700 ms or more is a place somebody could have taken
# the floor, a gap of 250 to 700 that they came back from is a place where
# speaking would have cut them off mid-sentence.
#
# That is a PROXY and it is stated rather than glossed: these are one person
# talking, so "a listener would have spoken here" is inferred from the length of
# the silence rather than observed. Two-party ground truth needs a two-party
# recording with both floors marked, which this repo does not have. What the
# proxy does capture exactly is the thing the shipping rule gets wrong -- it
# treats every pause the same, and most pauses are not turn ends.
#
# ── THE ARMS ────────────────────────────────────────────────────────────────
#
# `green-metrics-can-hide-defects`. A predictor scored on its own is a number
# with nothing behind it, so the same recording is scored by:
#
#   reactive, 450 ms      what ships today. It cannot be wrong about a gap it
#                         has not reached, and it cannot be early about one either.
#   reactive, 250 ms      the same rule made 200 ms braver, which is what a
#                         reactive design costs to speed up.
#   NULL, labels rotated  the ruler. Same scores, somebody else's pauses. If this
#                         ties with the real arm then the two kinds of pause are
#                         indistinguishable here and every number is noise.
#
# and they are compared AT THE SAME ERROR BUDGET, not at the same threshold: the
# shipping rule's own false-alarm rate is the ceiling, and each arm reports the
# recall it reaches without exceeding it.
#
# ── AND THE ARMS SHARE ONE PASS ─────────────────────────────────────────────
#
# `windowed-metrics-smear-experiments`. Two runs of a live recogniser over one
# file do not produce the same transcript, so an A/B across two runs compares two
# transcripts as much as two predictors. The audio is fed ONCE, at 1x, with the
# model on, and every arm is the shipping decision function over that one
# recorded trace with a different subset of its inputs.
set -u
export TK_NO_RAISE=1
export TK_NO_IDENTITY=1
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/predict-check.$$"
mkdir -p "$SP"
export TK_KIN_DIR="$SP/kin"
# Never `pkill -f`: it takes a REGEX, and in a path like `./.build/debug/tk`
# every `.` matches any character, so it reaps other checkouts' processes too.
PIDS=""
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }

# ── FINDING THE RECORDINGS ──────────────────────────────────────────────────
#
# The fixtures are gitignored -- reproducible, not committed -- so in a subagent
# worktree they exist in the MAIN checkout and not next to this script. The
# common git dir points at it, which is one line and saves the next person the
# twenty minutes it cost to work out why a rig could not find its own media.
MEDIA_DIR=""
for d in "$HERE/../../testbed/media/real" \
         "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/../testbed/media/real"; do
  [ -f "$d/realA.wav" ] && { MEDIA_DIR="$d"; break; }
done
# ── LONG ENOUGH TO HAVE SOMETHING TO COUNT ──────────────────────────────────
#
# Turn ends are RARE. Measured on this material: one gap of 700 ms or more about
# every thirty seconds, against four or five shorter hesitations a minute. The
# 90 s `realA.wav` fixture holds THREE turn ends, which is not a rate -- a rig
# run on it can only ever say "could not run", which is the most expensive kind
# of default because it looks like it works.
#
# `fetch.sh` already leaves the full 43-minute sources on disk, so ten minutes of
# each is one ffmpeg call away and gives about 28 turn ends and 155 hesitations.
# Cut into the scratch directory, never next to the fixtures.
SECONDS_EACH="${SECONDS_EACH:-600}"
WAVS="${WAVS:-}"
if [ -z "$WAVS" ]; then
  [ -n "$MEDIA_DIR" ] || {
    echo "PREDICT CHECK COULD NOT RUN -- no realA.wav found."
    echo "  testbed/media/real/fetch.sh reproduces it (needs ffmpeg + curl),"
    echo "  or set WAVS=/path/a.wav,/path/b.wav to point at your own 48 kHz mono speech."
    exit 2
  }
  if [ -f "$MEDIA_DIR/nasaA.mp4" ] && [ -f "$MEDIA_DIR/nasaB.mp4" ] && command -v ffmpeg > /dev/null; then
    # Offsets chosen where both speakers are answering rather than being asked;
    # 600 s from 900 s into B skips a stretch of DIGITAL SILENCE earlier in that
    # file, which the labeller reports as a room floor of -180 dB when you land
    # in it.
    ffmpeg -y -v error -ss 600 -t "$SECONDS_EACH" -i "$MEDIA_DIR/nasaA.mp4" \
           -vn -ac 1 -ar 48000 -c:a pcm_s16le "$SP/a.wav" || exit 2
    ffmpeg -y -v error -ss 900 -t "$SECONDS_EACH" -i "$MEDIA_DIR/nasaB.mp4" \
           -vn -ac 1 -ar 48000 -c:a pcm_s16le "$SP/b.wav" || exit 2
    WAVS="$SP/a.wav,$SP/b.wav"
  else
    echo "  (no nasaA.mp4/ffmpeg -- falling back to the 90 s fixtures, which hold about"
    echo "   three turn ends each and will almost certainly report COULD NOT RUN)"
    WAVS="$MEDIA_DIR/realA.wav,$MEDIA_DIR/realB.wav"
    SECONDS_EACH=90
  fi
fi

# ── THE ONE DIAL, AND IT IS A PRODUCT DECISION ──────────────────────────────
#
# How many hesitations the prior is allowed to get wrong. Not a threshold: each
# arm sweeps its own threshold to reach the most turn ends it can inside this,
# so the comparison is at equal COST rather than at equal dial setting. Raise it
# and every arm looks better, including the null one, which is what made the
# first version of this rig read as a tie.
BUDGET="${BUDGET:-0.15}"
# The lane's own ports. A `--*-test` run still opens a socket before it reaches
# the test, and the default 7001 belongs to whoever started first.
PORT="${PORT:-8340}"
MODEL="${MODEL:-1}"
ARGS="--predict-test --listen $PORT --predict-wav $WAVS --predict-seconds $SECONDS_EACH"
ARGS="$ARGS --predict-budget $BUDGET"
if [ "$MODEL" = "1" ]; then ARGS="$ARGS --predict-model"; fi

echo "── feeding $(echo "$WAVS" | tr ',' '\n' | wc -l | tr -d ' ') recording(s), ${SECONDS_EACH}s each, at 1x"
# ── THE ONE WALL-CLOCK NUMBER THIS RIG DEPENDS ON, SAID OUT LOUD ────────────
#
# Everything scored below is on the AUDIO timeline, derived from sample counts,
# so a busy machine cannot move it. The exception is the recogniser: its partials
# arrive on wall-clock time, so under load the transcript is staler and the
# predictor has LESS to work with. The bias is one-directional -- a loaded
# machine can only make this test harder -- which is why it is allowed to run on
# one at all. The load is printed so a surprising number can be read against it.
echo "   (takes about as long as the audio. load right now: $(uptime | sed -E 's/.*load averages?: //'))"
"$TK" $ARGS --mute --no-telemetry --no-update --no-relocate --no-rings \
      > "$SP/run.log" 2>&1 &
LAST=$!; PIDS="$PIDS $LAST"
wait $LAST
rc=$?
PIDS=""

# NEVER THROUGH A PIPE. A failing run once reported success because its exit code
# went into `| tail`, and this script's whole output is a verdict.
grep -vE "^install:|^tk [0-9]|^pid |^packet=|^telemetry:|^mic:|^bind:" "$SP/run.log"

echo
case $rc in
  0) echo "PREDICT CHECK PASSED -- a turn end is called before the silence that would"
     echo "  have proved it, and a hesitation is not";;
  2) echo "PREDICT CHECK COULD NOT RUN -- see above. This is not a pass and not a"
     echo "  failure: the rig could not reach the thing it tests."
     echo "  logs in $SP (KEEP=1 to keep them)";;
  *) echo "PREDICT CHECK FAILED -- see the table above; logs in $SP (KEEP=1 to keep them)";;
esac
exit $rc
