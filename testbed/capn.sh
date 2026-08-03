#!/bin/zsh
# WHAT DOES THE 120 ms BUFFER CEILING BUY?
#
# `maxTargetFrames = 15` at 8 ms per frame is a 120 ms ceiling, and under bandwidth
# shaping the depth ratchets straight up to it: 45 ms at t=0, ~123 ms at t=44. A
# 4-bandwidth sweep found the target pinned there for 46-48 of 48 samples at 0.3, 0.8
# and 1.5 Mbps -- which is also why the release rate could not be measured in that
# regime (`want = min(cap, raw)` discards the release term whenever raw > cap, so both
# arms of a release A/B run the identical control law). The cap is the only knob with
# authority on a starved link, and it has never been measured.
#
# The reason to look: at 0.3 and 0.8 Mbps BOTH arms concealed ZERO frames while
# carrying 94-100 ms of buffer. Zero is the floor -- you cannot conceal less than
# nothing -- so any depth the cap gives back while concealment stays at zero is free
# latency. How much is unknown, and stays unknown until measured: this project once
# predicted +80 ms for a deeper buffer and measured latency FALL.
#
# CONDITION: --bw=0.8. Chosen because the sweep measured 48/48 samples clamped there
# (so both caps actually bind) with zero concealment in both arms (so there is headroom
# to spend). NOT --bw=0.3, which is on file as failing to hold its regime -- video's
# congestion control frees the link after ~25 s.
#
# 8f = 64 ms, 15f = 120 ms (the shipping default).
#
# THE NULL ARM RUNS FIRST, not last. Equal caps on both ends of one call measures this
# rig's own spread with the parameter provably inert, and three inert-lever points from
# the sweep already differed by 6.1 / 8.9 / 3.0 ms of mean depth. If the cap contrast
# does not clear that, there is nothing here and the remaining reps are not worth the
# machine time.
#
# SIDES ALTERNATE. Side A carries ~3 ms more baseline depth than side B (found by an
# earlier null arm), so a fixed assignment would fold that asymmetry into the effect.
# The statistic is the WITHIN-CALL difference, and swapping which end runs which cap
# cancels the side term.
#
# Sign convention for analysis: report low-cap minus high-cap, so NEGATIVE means the
# smaller ceiling carried less latency. Report concealment beside it always -- a lower
# ceiling that empties the buffer buys its latency with dropouts, and on this project a
# run with the BEST p50 was the run that lost 127 frames.
set -e
S=/private/tmp/claude-501/-Users-earningsgpt-video-calling/477cd6ea-c192-43a3-b107-a2011157fa96/scratchpad
cd "/Users/earningsgpt/video calling"
mkdir -p $S/cap

REPS=${1:-1}   # capn.sh 1 = scout (3 runs). capn.sh 4 = the full n=8 contrast.

# RESUMABLE. `have` checks for the `result` block, not merely the file: relpair.mjs
# writes its JSON from a `finally`, so an ABORTED run still leaves a file behind.
have() { node -e 'try{process.exit(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).result?0:1)}catch{process.exit(1)}' "$1"; }

run() { # run <json> <jbmaxA> <jbmaxB> <label>
  if have "$1"; then echo "  SKIP $4 — already has a result"; return; fi
  echo "=== $4   $(date +%H:%M:%S)"
  # Release rate pinned EQUAL on both sides (the shipping default). relpair's own
  # --relA/--relB defaults are asymmetric (0.25 vs 2) because its native experiment is a
  # release A/B; inheriting them here would confound the cap contrast with a release
  # contrast. One parameter per experiment ([[pair-the-arms-inside-one-trial]]).
  node testbed/relpair.mjs --relA=2 --relB=2 --jbmaxA=$2 --jbmaxB=$3 --bw=0.8 --loss=0 --hole=0 \
    --settle=15 --recover=45 --json="$1" > "${1%.json}.log" 2>&1 || echo "  $4 FAILED (see log)"
  sleep 45
}

# The noise floor, with the caps EQUAL and everything else identical.
run $S/cap/null8.json 8 8 "null   (both ends 8f = 64 ms)"

for i in $(seq 1 $REPS); do
  run $S/cap/c${i}a.json 15 8 "rep $i a  (A 15f/120ms, B 8f/64ms)"
  run $S/cap/c${i}b.json 8 15 "rep $i b  (A 8f/64ms, B 15f/120ms, swapped)"
done
echo CAP-SEQUENCE-DONE
