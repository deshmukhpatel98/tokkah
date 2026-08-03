#!/bin/zsh
# The ~38.7 s cliff: transport, or emulator?
#
# In every ramp and every 45 s matrix soak, RECEIVE stops at t≈38.6-38.8 s while the sender is
# still writing at full rate; the buffer then fills 0->24->218->256 KB over about 600 ms and the
# pacer wedges at its high-water mark. Same time at 8 and at 12 Mbps — so it is a timeout, not a
# byte count. Every soak that passed was 25 s, i.e. it ended before the cliff, which means the
# clean-link PASS is currently only established for runs shorter than the cliff.
#
# --nosim removes the delay line and the TURN relay entirely and goes direct over loopback. If the
# no-simulator arm survives 90 s and the emulated arm dies at ~39 s, the cliff is mine. If both
# die, it is the browser's SCTP stack and the gate result needs a much bigger caveat.
cd "/Users/earningsgpt/video calling/phase1-transport"
echo "### ARM 1: NO SIMULATOR, 90 s at 12 Mbps ###"
node gate.mjs --nosim --mode=soak --target=12 --sec=90 2>&1 | tail -14
echo "### ARM 2: WITH SIMULATOR at 80 ms, 90 s at 12 Mbps ###"
node gate.mjs --rtt=80 --mode=soak --target=12 --sec=90 2>&1 | tail -14
echo "### ARM 3: WITH SIMULATOR, 90 s at 2 Mbps — is the cliff load-dependent? ###"
node gate.mjs --rtt=80 --mode=soak --target=2 --sec=90 2>&1 | tail -8
echo "CLIFF-DONE"
