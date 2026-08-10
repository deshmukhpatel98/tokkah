#!/bin/zsh
# WHERE DOES THE SLOW RELEASE START EARNING ITS DEPTH?
#
# Isolated and lightly-recurring holes both favour the FAST release, by 2-6x on the
# latency excursion, for +1 to +7 concealed frames out of ~18,000. But pcm.js records
# an n=8 A/B at --bw=0.3 where the SLOW release won on every mean with significantly
# lower variance. Both can be true: in those runs concealment was the binding cost,
# and here it is nothing (0.2% either way). A buffer that prevents no concealment is
# pure latency.
#
# So the discriminator is not recurrence — fast won in the recurring arm too. It is
# whether the buffer is actually PREVENTING anything. This drives concealment pressure
# up directly, with holes at and beyond the buffer's depth, rather than adding
# bandwidth shaping and its queueing as a second variable.
#
# Prediction, to be recorded before the runs so it can be wrong: at some hole
# size/rate the slow release's deeper buffer starts covering holes that the fast
# release's shallower one does not, concealment separates by more than the null arm's
# 1 frame, and the ranking flips.
set -e
S=/private/tmp/claude-501/-Users-earningsgpt-video-calling/477cd6ea-c192-43a3-b107-a2011157fa96/scratchpad
cd "/Users/deveshpatel/Downloads/video calling"
K='RESULT|release \(ms/s\)|baseline depth|baseline age|baseline e2e|peak target|peak depth|peak e2e|added latency|added e2e|excursion|recovered at|final target|frames concealed|─────|^ +A +B|stimulus|Error|VOID|ABORT|conceal '

echo "############ moderate pressure: 150 ms holes every 5 s x 12   (A slow, B fast)"
node testbed/relpair.mjs --relA=0.25 --relB=2 --hole=150 --holes=12 --gap=5 --recover=150 --json=$S/press150.json 2>&1 | grep -E "$K" || true
echo ""
echo "############ heavy pressure: 250 ms holes every 5 s x 12       (A slow, B fast)"
node testbed/relpair.mjs --relA=0.25 --relB=2 --hole=250 --holes=12 --gap=5 --recover=150 --json=$S/press250.json 2>&1 | grep -E "$K" || true
