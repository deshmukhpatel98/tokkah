#!/bin/bash
# ── EARBUDS ONLY, HELD TO ITS OWN DOORS (0.166.0) ────────────────────────────
#
# Calls are placed, answered and carried on earbuds; a loudspeaker route is
# refused at both doors and holds the microphone silent mid-call. Every arm
# here FORCES the route with `--route`, because a rig whose verdict depends on
# what is plugged into the Mac running it is measuring the Mac, not the build
# (`rig-picks-a-parameter-the-product-does-not`). The one transition argv cannot
# make -- earbuds going in mid-ring -- is proven by its two sides instead.
#
# `--earbuds-test` proves the decision table (known answers, three rejects).
# The arms below prove the DOORS with real synthetic clicks through the window,
# because every interaction bug this project has shipped lived between the
# handler and the finger (`dead-controls-declared-never-wired`).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.." || exit 2
TK="${TK:-$HERE/../.build/debug/tk}"
[ -x "$TK" ] || { echo "EARBUDS CHECK COULD NOT RUN -- no tk at $TK; swift build first"; exit 2; }
SP="${SCRATCH:-${TMPDIR:-/tmp}}/earbuds-check.$$"
mkdir -p "$SP/homeA" "$SP/homeB" "$SP/ringA" "$SP/ringB" "$SP/callA" "$SP/callB"
PIDS=""
spawn() { "$@" & PIDS="$PIDS $!"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT
export TK_NO_IDENTITY=1 TK_NO_RAISE=1
fail=0
say() { printf '  %-5s %s\n' "$1" "$2"; [ "$1" = FAIL ] && fail=1; return 0; }
want() { if grep -qE "$3" "$2"; then say OK "$1"; else say FAIL "$1"; fi; }
nowant() { if grep -qE "$3" "$2"; then say FAIL "$1"; else say OK "$1"; fi; }
nap() { perl -e "select undef,undef,undef,$1"; }
# Any 32 bytes: the card shows for whatever key rides the ring, and nothing here
# reaches a handshake (the refusal is the point, and the allowed arm re-execs
# into an empty room).
K="AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
BASE="--window --video off --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles"

echo "── the decision table, on known routes"
"$TK" --earbuds-test > "$SP/unit.log" 2>&1
want "known answers pass, three rejects included" "$SP/unit.log" 'EARBUDS TEST PASSED'

echo "── the front door, clicked"
# The same real click controls-check makes on a contact row, on a FORCED
# loudspeaker route: the row must fire, and the refusal must be what it fires --
# before anything is warmed, minted or rung.
env TK_KIN_DIR="$SP/homeA" "$TK" --gui --contacts-fake "meera" --route speakers \
    --no-update --no-telemetry --no-relocate --no-rings \
    --press "@meera" --press-after 2 > "$SP/homeA.log" 2>&1 &
PIDS="$PIDS $!"
nap 8
reap
want "a loudspeaker route refuses the row's call" "$SP/homeA.log" 'ring: @meera needs earbuds -- not rung'
nowant "and the network was never asked about anybody" "$SP/homeA.log" 'is not registered|Couldn.t reach|ring sent'

# REJECT: the same click on the same route under the control arm must ring --
# an arm that cannot reach the old behaviour is a flag, not a control.
env TK_KIN_DIR="$SP/homeB" "$TK" --gui --contacts-fake "meera" --route speakers --no-earbuds-gate \
    --no-update --no-telemetry --no-relocate --no-rings \
    --press "@meera" --press-after 2 > "$SP/homeB.log" 2>&1 &
PIDS="$PIDS $!"
nap 8
reap
nowant "REJECT: --no-earbuds-gate never refuses the row" "$SP/homeB.log" 'needs earbuds'

echo "── the answer door, clicked"
# One process, ringing from argv exactly as the watcher launches it. On
# speakers the press is refused and the ring keeps ringing; on earbuds the
# same press answers. No peer: both claims are this end's alone.
spawn env TK_KIN_DIR="$SP/ringA" "$TK" $BASE --room "ebchk$$a" --listen 8125 --peer 127.0.0.1:8126 \
      --route speakers --incoming meera --incoming-key "$K" \
      --press-after 3 --press "@answer" > "$SP/ringA.log" 2>&1
nap 8
reap
want "on speakers the press is refused, and says so" "$SP/ringA.log" 'ring: answer needs earbuds -- still ringing'
nowant "and the answer never committed" "$SP/ringA.log" 'ring: answer committed'

spawn env TK_KIN_DIR="$SP/ringB" "$TK" $BASE --room "ebchk$$b" --listen 8125 --peer 127.0.0.1:8126 \
      --route headphones --incoming meera --incoming-key "$K" \
      --press-after 3 --press "@answer" > "$SP/ringB.log" 2>&1
nap 8
reap
want "on earbuds the same press answers" "$SP/ringB.log" 'ring: answer committed'

echo "── the hold, mid-call, and its control arm"
# Two ends of one loopback room: the loudspeaker end holds its microphone and
# says so; the earbuds end is the full-duplex product. Then the SAME
# loudspeaker end under --no-earbuds-gate must raise the floor instead, which
# is 0.165.0 -- fresh room, same ports, serial (`reap` between).
spawn env TK_KIN_DIR="$SP/callA" "$TK" $BASE --room "ebchk$$c" --listen 8127 --peer 127.0.0.1:8128 \
      --route speakers > "$SP/callA.log" 2>&1
spawn env TK_KIN_DIR="$SP/callB" "$TK" $BASE --room "ebchk$$c" --listen 8128 --peer 127.0.0.1:8127 \
      --route headphones > "$SP/callB.log" 2>&1
nap 10
reap
want "the loudspeaker end holds its microphone" "$SP/callA.log" 'earbuds only: the microphone is held'
want "and says so in plain words when it engages" "$SP/callA.log" 'route: no earbuds -- the microphone is held silent'
want "the earbuds end is full duplex, nothing in the way" "$SP/callB.log" 'both at once, no turns'

# A peer, because the route line prints on the way INTO a call: an end waiting
# alone never gets there, and this arm's first draft asserted on a log the
# process had not written yet.
spawn env TK_KIN_DIR="$SP/callA" "$TK" $BASE --room "ebchk$$d" --listen 8127 --peer 127.0.0.1:8128 \
      --route speakers --no-earbuds-gate > "$SP/ctrl.log" 2>&1
spawn env TK_KIN_DIR="$SP/callB" "$TK" $BASE --room "ebchk$$d" --listen 8128 --peer 127.0.0.1:8127 \
      --route headphones > "$SP/ctrlB.log" 2>&1
nap 10
reap
want "REJECT: the control arm raises the floor instead (0.165.0)" "$SP/ctrl.log" 'one at a time, so nobody hears themselves'
nowant "REJECT: and never holds the microphone" "$SP/ctrl.log" 'microphone is held'

echo
if [ "$fail" = 0 ]; then
  echo "EARBUDS CHECK PASSED -- both doors refuse a loudspeaker route and open on earbuds,"
  echo "the hold engages mid-call and speaks, and the control arm is exactly 0.165.0"
else
  echo "EARBUDS CHECK FAILED -- see above; logs in $SP"
  KEEP=1
fi
exit "$fail"
