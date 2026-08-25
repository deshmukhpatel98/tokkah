#!/bin/bash
# ── DOES THE OTHER PERSON KNOW YOU MUTED YOURSELF? ──────────────────────────
#
# A muted microphone sounds exactly like a dead call, a broken microphone, and
# somebody who has simply stopped talking. Four situations, one silence.
#
# The signal was already on the wire -- `selfMuted`/`peerMuted`, its own byte at
# TPKTX+4, sent once a second -- and the only thing reading it was a telemetry
# field. The person watching an unexplained silence was told nothing. Shipping a
# fact to a dashboard and not to the user is `feature-behind-a-flag-nobody-runs`
# with the flag being "nobody rendered it".
#
# BOTH EDGES. A rig that only ever mutes proves the giving-up half and nothing
# about recovery (`permanent-impairment-hides-recovery`), and a banner that never
# clears is worse than no banner: it tells you somebody is muted for the rest of
# a call they are talking on.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/mute-check.$$"
mkdir -p "$SP"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
export TK_KIN_DIR="$SP/kin"
trap 'pkill -f "$TK" 2>/dev/null; rm -rf "$SP"' EXIT

R="mutechk$$"
# --mute is the RIG's speaker flag (the machine's speakers belong to whoever is
# sitting at it). `--press mic` is the app's microphone button. Different things.
C="--window --video off --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles"
pkill -f "$TK" 2>/dev/null; perl -e 'select undef,undef,undef,0.6'
# A mutes at 6 s and unmutes at 12 s.
"$TK" $C --room "$R" --listen 7471 --peer 127.0.0.1:7472 \
      --press "mic" --press-after 6 > "$SP/a.log" 2>&1 &
"$TK" $C --room "$R" --listen 7472 --peer 127.0.0.1:7471 > "$SP/b.log" 2>&1 &
perl -e 'select undef,undef,undef,10'
# Second press on A, from a fresh process is not possible -- so drive the second
# edge by pressing again through the same --press list.
pkill -f "$TK" 2>/dev/null; perl -e 'select undef,undef,undef,0.6'
"$TK" $C --room "${R}b" --listen 7473 --peer 127.0.0.1:7474 \
      --press "mic,~,~,mic" --press-after 4 > "$SP/a2.log" 2>&1 &
"$TK" $C --room "${R}b" --listen 7474 --peer 127.0.0.1:7473 > "$SP/b2.log" 2>&1 &
perl -e 'select undef,undef,undef,18'
pkill -f "$TK" 2>/dev/null; perl -e 'select undef,undef,undef,0.4'

bad=0
if grep -q "voice: the far end's microphone is OFF" "$SP/b.log"; then
  echo "   ok   the far end is told the microphone went off"
else
  echo "  WRONG the far end was never told about the mute"; bad=1
fi
SEQ="$(grep -oE "microphone is (OFF|on)" "$SP/b2.log" | tr '\n' ' ')"
case "$SEQ" in
  *"microphone is OFF"*"microphone is on"*)
    echo "   ok   and told again when it came back: $SEQ";;
  *) echo "  WRONG the banner never cleared after unmute: [$SEQ]"; bad=1;;
esac
[ "$bad" = 0 ] && echo "  MUTE CHECK PASSED -- an unexplained silence is now explained, and it clears" \
                || echo "  MUTE CHECK FAILED"
exit $bad
