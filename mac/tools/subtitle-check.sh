#!/bin/bash
# ── WHOSE WORDS, ON WHOSE SCREEN, AND ONLY WHEN ─────────────────────────────
#
# The rule, in the words it was asked for:
#
#   "Subtitles should be there only once -- in a lot of cases they are appearing
#    twice on the screen. Subtitles are for the other person, not the person who
#    is speaking: if person A said something, the subtitles should appear on
#    person B's screen, and nowhere on person A's. And subtitles should only be
#    appearing for the person who is on mute -- if person B is on mute, subtitles
#    should be displayed on person A's screen of what person B is saying."
#
# So: a voice that cannot be heard is read instead, on the OTHER screen, once.
#
# What was there before did three of those four things wrong. Every utterance
# went on the wire whether or not it could be heard; the far end drew it; and
# THIS end drew it too, as a second caption, whenever your own voice was not the
# audible one. Two captions on one screen, and the one person in the call who
# already knew what had just been said was the one being shown it.
#
# ── SPEAKING WITHOUT A MICROPHONE ───────────────────────────────────────────
#
# The `said` and `mine` press tokens write straight into the caption layer. They
# prove the band draws and they can say NOTHING about the rule, because the rule
# lives upstream of them -- in the recogniser's callback, where the decision to
# send is taken. A rig built on those tokens would pass on a build that had lost
# the rule entirely.
#
# `--press "utter:<words>"` calls the recogniser's own callback instead. From
# that point on it is the shipping path: the gate, the packet, the far end's
# decode, the far end's caption. Only the microphone is simulated, which is the
# one part a headless Mac cannot supply.
set -u
export TK_NO_RAISE=1
# ── KILLS ONLY WHAT THIS SCRIPT STARTED ─────────────────────────────────────
# Never `pkill -f`: it takes a REGEX, and in a path like `./.build/debug/tk`
# every `.` matches any character, so it reaps other checkouts' processes too.
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/subtitle-check.$$"
mkdir -p "$SP"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
export TK_NO_IDENTITY=1
export TK_KIN_DIR="$SP/kin"
# The caption clock, slowed so an audit cannot land after the words expire. The
# words live 2.2 s and a queued press can cost 1.5 s of that; an assertion that
# needs to win that race is an assertion that fails on a busy machine and blames
# the subtitles. Proven: it did, three runs running.
export TK_CAPTION_SCALE=8
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }
audits() { grep -oE 'audit state controls.*' "$1"; }
# What a screen is actually showing, quoted, so a failure names the words rather
# than asserting that a pattern matched. `grep -E` throughout: this machine
# resolves `grep` to ugrep, where a BRE `\|` is not the alternation it looks like
# -- a pattern that means something different from what it reads is how a rig
# reports a fault nobody can reproduce.
caps() { audits "$1" | grep -oE '(theirs|mine)="[^"]*"' | tail -2 | tr '\n' ' '; }
C="--window --video off --mute --no-telemetry --no-update --no-relocate --no-rings"

# ── 1. A MUTED VOICE IS READ ON THE OTHER SCREEN ────────────────────────────
#
# A mutes itself, then speaks. B must show the words. A must not.
echo "── the muted one speaks"
R="subchk$$"
spawn "$TK" $C --room "$R" --listen 8113 --peer 127.0.0.1:8114 \
      --press "mic,utter:they_can_hear_none_of_this,?,?" --press-after 9 > "$SP/a.log" 2>&1
spawn "$TK" $C --room "$R" --listen 8114 --peer 127.0.0.1:8113 \
      --press "?,?,?" --press-after 11 > "$SP/b.log" 2>&1
perl -e 'select undef,undef,undef,20'
reap; perl -e 'select undef,undef,undef,0.4'

grep -q "connected via" "$SP/b.log" || { echo "  COULD NOT RUN: the two ends never connected"; exit 2; }
grep -q "utter:" "$SP/a.log" || { echo "  COULD NOT RUN: the utterance hook never fired"; exit 2; }
grep -qE "micMuted=true|mic=muted" "$SP/a.log" \
  && say "OK" "PRECONDITION: the speaker really was muted" \
  || say "FAIL" "the mic was never muted, so this proves nothing about muting"

audits "$SP/b.log" | grep -q 'theirs="' \
  && say "OK" "the words reached the OTHER person's screen" \
  || say "FAIL" "a muted voice was not read anywhere -- the one case subtitles exist for"

audits "$SP/a.log" | grep -qE 'theirs="|mine="' \
  && say "FAIL" "the speaker was shown their own words: $(audits "$SP/a.log" | tail -1 | grep -oE '(theirs|mine)="[^"]*"' | head -2 | tr '\n' ' ')" \
  || say "OK" "and nowhere on the speaker's own screen"

# Once, not twice. `mine` is the second caption the band can draw, and it is the
# one that used to appear beside the first.
audits "$SP/b.log" | grep -q 'mine="' \
  && say "FAIL" "two captions at once on the listener's screen" \
  || say "OK" "and only once -- the second caption line is empty"

# ── 2. CONTROL: AN AUDIBLE VOICE IS NOT SUBTITLED ───────────────────────────
#
# The arm that ranks the other way. Same two processes, same sentence, same
# everything -- except nobody presses mute. If this shows a caption too, then
# part one proved that the app draws text, not that it follows the rule.
echo "── CONTROL: the same sentence, said out loud"
R2="subchk$$b"
spawn "$TK" $C --room "$R2" --listen 8115 --peer 127.0.0.1:8116 \
      --press "utter:they_can_hear_all_of_this,?,?" --press-after 9 > "$SP/c.log" 2>&1
spawn "$TK" $C --room "$R2" --listen 8116 --peer 127.0.0.1:8115 \
      --press "?,?,?" --press-after 11 > "$SP/d.log" 2>&1
perl -e 'select undef,undef,undef,20'
reap; perl -e 'select undef,undef,undef,0.4'

grep -q "connected via" "$SP/d.log" || { echo "  COULD NOT RUN: the control pair never connected"; exit 2; }
grep -q "utter:" "$SP/c.log" || { echo "  COULD NOT RUN: the control's utterance hook never fired"; exit 2; }
grep -qE "micMuted=true" "$SP/c.log" \
  && say "FAIL" "the control muted itself, so it is not a control" \
  || say "OK" "PRECONDITION: nobody muted anything in this arm"

audits "$SP/d.log" | grep -q 'theirs="' \
  && say "FAIL" "an audible voice was subtitled anyway -- the rule is not being applied" \
  || say "OK" "CONTROL: an audible voice is not subtitled at all"

audits "$SP/c.log" | grep -qE 'theirs="|mine="' \
  && say "FAIL" "CONTROL: and the speaker was shown their own words" \
  || say "OK" "CONTROL: and still nothing on the speaker's screen"

# Both arms have to have been ALIVE and drawing, or two empty screens rank
# identically to a rule that works.
for f in b d; do
  audits "$SP/$f.log" | grep -q 'card=' \
    && say "OK" "PRECONDITION: arm '$f' was drawing and audited" \
    || say "FAIL" "arm '$f' never produced a state dump -- its silence is not evidence"
done

echo
if [ "$fail" = 0 ]; then
  echo "SUBTITLE CHECK PASSED -- a voice that cannot be heard is read on the other"
  echo "  screen, once, and a voice that can be heard is not read at all"
else
  echo "SUBTITLE CHECK FAILED -- see above; logs in $SP (KEEP=1 to keep them)"
fi
exit $fail
