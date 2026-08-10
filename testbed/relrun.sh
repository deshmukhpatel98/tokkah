#!/bin/zsh
# The real comparison, after the null arm established the noise floor
# (added latency 0.0 ms apart, excursion area 0.7%, recovery 2.0 s, conceal 1 frame).
#
# Three calls:
#   real  A = 1 ms/s (shipped), B = 8 ms/s          isolated hole
#   swap  A = 8 ms/s,           B = 1 ms/s          isolated hole, sides exchanged
#   recur A = 1 ms/s,           B = 8 ms/s          6 holes 10 s apart
#
# The swap matters: the null arm showed side A carrying a consistently higher baseline
# depth (17.5 vs 14.7 ms), so there is a small fixed side asymmetry. If the effect
# reverses with the sides, it is the release rate; if it does not, it is the side.
#
# The recurring arm is where a faster release should LOSE, because protecting against
# recurrence is the entire reason the slow release was introduced. An experiment that
# only runs the regime favouring the change is not a test of it.
#
# Explicit invocations, not a loop over packed strings: zsh does not word-split
# unquoted parameters, and that already cost one full 2x2 today.
set -e
S=/private/tmp/claude-501/-Users-earningsgpt-video-calling/477cd6ea-c192-43a3-b107-a2011157fa96/scratchpad
cd "/Users/deveshpatel/Downloads/video calling"
K='RESULT|release \(ms/s\)|predicted hold|baseline depth|peak target|peak depth|added latency|excursion|recovered at|final target|frames concealed|─────|^ +A +B|scheduler|PASS|stimulus|Error|VOID|ABORT'

echo "###################### real: A slow (1 ms/s) vs B fast (8 ms/s), isolated hole"
node testbed/relpair.mjs --relA=0.25 --relB=2 --hole=90 --holes=1 --recover=140 --json=$S/real1.json 2>&1 | grep -E "$K" || true
echo ""
echo "###################### swap: A fast (8 ms/s) vs B slow (1 ms/s), isolated hole"
node testbed/relpair.mjs --relA=2 --relB=0.25 --hole=90 --holes=1 --recover=140 --json=$S/swap1.json 2>&1 | grep -E "$K" || true
echo ""
echo "###################### recur: A slow vs B fast, 6 holes 10 s apart"
node testbed/relpair.mjs --relA=0.25 --relB=2 --hole=90 --holes=6 --gap=10 --recover=150 --json=$S/recur1.json 2>&1 | grep -E "$K" || true
