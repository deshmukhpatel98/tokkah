#!/bin/zsh
# The 2x2: {isolated, recurring} x {1 ms/s release, 8 ms/s release}.
#
# Written as explicit invocations, not a loop over packed strings, because zsh does
# NOT word-split unquoted parameters: `set -- $a` passes the whole line as ONE argv
# entry, so `--holes=` arrived empty and all four arms exited 2 before measuring
# anything. This has bitten this project before, in a version that silently took the
# default instead of failing, so the fatal-flag rule is what surfaced it this time.
#
# Recurring arm: 6 holes 10 s apart. At 1 ms/s a 90 ms hole needs ~90 s to decay, so
# 10 s spacing keeps the target pinned; at 8 ms/s it nearly clears between holes.
# That is the regime the slow release was introduced to protect, so it is where a
# faster release should LOSE if the original reasoning was right.
set -e
S=/private/tmp/claude-501/-Users-earningsgpt-video-calling/477cd6ea-c192-43a3-b107-a2011157fa96/scratchpad
cd "/Users/earningsgpt/video calling"
K='RESULT|^  baseline|^  peak|^  cost:|excursion|concealment|RECOVERED|DID NOT RISE|scheduler lateness|stimulus CONFIRMED|VOID|Error'

echo "=========== iso-slow  (1 hole, release 1 ms/s — the shipped default)"
node testbed/onehole.mjs --hole=90 --holes=1 --recover=150 --query='tape=2'              --json=$S/iso-slow.json 2>&1 | grep -E "$K" || true
echo "=========== iso-fast  (1 hole, release 8 ms/s)"
node testbed/onehole.mjs --hole=90 --holes=1 --recover=150 --query='tape=2&pcmjitrel=2'   --json=$S/iso-fast.json 2>&1 | grep -E "$K" || true
echo "=========== rec-slow  (6 holes / 10 s, release 1 ms/s)"
node testbed/onehole.mjs --hole=90 --holes=6 --gap=10 --recover=150 --query='tape=2'            --json=$S/rec-slow.json 2>&1 | grep -E "$K" || true
echo "=========== rec-fast  (6 holes / 10 s, release 8 ms/s)"
node testbed/onehole.mjs --hole=90 --holes=6 --gap=10 --recover=150 --query='tape=2&pcmjitrel=2' --json=$S/rec-fast.json 2>&1 | grep -E "$K" || true
