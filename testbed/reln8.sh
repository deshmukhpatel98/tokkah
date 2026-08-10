#!/bin/zsh
# THE n=8 THE OTHER RESULT DESERVES.
#
# Seven paired regimes all favour the fast release. pcm.js records an n=8 A/B at
# --bw=0.3 that favours the slow one. Seven consistent n=1 runs do not beat one
# careful n=8, so nothing changes until this matches that standard.
#
# 5% sustained loss is the condition, not --bw=0.3: under a bandwidth ceiling the
# video lane's congestion control backs off and the link goes clean after ~25 s, so
# that arm cannot hold the lossy regime it is supposed to test. Sustained datagram
# loss cannot be backed away from. Shaper counters confirm ~5.87% actual per run.
#
# EIGHT PAIRED CALLS, sides ALTERNATING. Pairing is not a nicety here: at this loss
# level the same setting concealed 201 frames in one call and 300 in another (a 50%
# between-call swing) while the two ends of one call agreed to within 2 frames. So
# the statistic is the WITHIN-CALL DIFFERENCE, eight of them, and alternating which
# end runs which rate cancels the side asymmetry the null arm found (side A carries
# ~3 ms more baseline depth).
#
# Sign convention for analysis: report fast-minus-slow, so NEGATIVE favours fast.
set -e
S=/private/tmp/claude-501/-Users-earningsgpt-video-calling/477cd6ea-c192-43a3-b107-a2011157fa96/scratchpad
cd "/Users/deveshpatel/Downloads/video calling"
mkdir -p $S/n8

# FIRST ATTEMPT PRODUCED ONE RESULT AND SEVEN ABORTS, all reading
# "ABORT: host at 7x% -- this would measure the laptop", every one within a second of
# the previous run ending. relpair.mjs was gating on os.loadavg()[0], the ONE-MINUTE
# average, which at that instant still contained the two browsers of the run that had
# just exited. A back-to-back sequence could never pass it. relpair.mjs now waits for
# the decay instead of voiding the run; the cooldown below means it usually has nothing
# to wait for, and the run records hostLoadStart/hostLoadWaitedS either way.
# RESUMABLE. A rep whose JSON already carries a `result` block is left alone, so a
# partial sequence can be topped up without discarding the runs that survived — this
# laptop aborted 7 of 8 once already and each rep costs ~5 minutes. `have` looks for
# the result block specifically, not merely the file: relpair.mjs writes its JSON from
# a `finally`, so an ABORTED run still leaves a file behind (that exact trap already
# made one `until [ -f ... ]` wait exit instantly).
have() { node -e 'try{process.exit(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).result?0:1)}catch{process.exit(1)}' "$1"; }

run() { # run <json> <relA> <relB> <label>
  if have "$1"; then echo "  SKIP $4 — already has a result"; return; fi
  echo "=== $4   $(date +%H:%M:%S)"
  node testbed/relpair.mjs --relA=$2 --relB=$3 --loss=5 --hole=0 --recover=140 \
    --json="$1" > "${1%.json}.log" 2>&1 || echo "  $4 FAILED (see log)"
  sleep 45
}

for i in 1 2 3 4; do
  run $S/n8/r${i}a.json 0.25 2 "rep $i a  (A slow, B fast)"
  run $S/n8/r${i}b.json 2 0.25 "rep $i b  (A fast, B slow, swapped)"
done
echo ALL-EIGHT-DONE
