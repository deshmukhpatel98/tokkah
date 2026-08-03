#!/bin/zsh
# WHERE IS THE WINDOW? A release-rate A/B can only measure anything in a regime where the
# jitter estimator is ACTIVE — not pinned at maxTargetFrames, and not sitting on a clean link.
#
# Both failure modes are recorded and both have already wasted runs on this project:
#   - too tight  -> the estimator asks for more than the 15-frame ceiling continuously,
#                   `spreadHold` never enters the range the release acts on, and the two arms
#                   come out bit-for-bit identical (measured at 12 x 250 ms holes).
#   - too loose  -> the VIDEO lane's congestion control backs off, the link goes clean after
#                   ~25 s, and the run measures a 25 s transient plus 140 s of nothing.
#
# The one n=8 that favours the SLOW release was taken at --bw=0.3 with metrics that are not
# comparable to the 5%-loss n=8, and reln8.sh already records that --bw=0.3 does not hold its
# regime. So before spending 40 minutes reproducing it, find a bandwidth that HOLDS.
#
# Short runs on purpose — this is regime-finding, not an A/B. The arms are left at their
# default 1 vs 8 ms/s so a single run shows both extremes against the ceiling: if slow is
# pinned and fast is not, the window is between them.
set -e
S=/private/tmp/claude-501/-Users-earningsgpt-video-calling/477cd6ea-c192-43a3-b107-a2011157fa96/scratchpad
cd "/Users/earningsgpt/video calling"
mkdir -p $S/sweep
for bw in 0.3 0.8 1.5 2.5; do
  f=$S/sweep/bw${bw}.json
  echo "=== --bw=$bw   $(date +%H:%M:%S)"
  node testbed/relpair.mjs --bw=$bw --loss=0 --hole=0 --settle=15 --recover=45 \
    --json="$f" > "${f%.json}.log" 2>&1 || echo "  bw=$bw FAILED"
  sleep 30
done
echo SWEEP-DONE
