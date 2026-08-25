#!/bin/bash
# ── DOES THE OTHER MAC EVER FIND OUT THE CALL IS OFF? ────────────────────────
#
# Reported after a real call, in these words: "when I cancelled the call it did
# not get instantly notified to the person who was calling, and just kept showing
# calling forever." It did, and nothing was broken -- there was simply no un-ring
# to send. A ring sat in a mailbox with a 60 s lease and both ends waited it out.
#
# A `bye` is the same signed envelope with one extra word on it, through the same
# doorbell, waking the same held poll. This drives it on REAL processes against
# the REAL server with real signing keys, because every part of it that could be
# wrong lives between two machines.
#
# Four claims, and the fourth is the one a broken fix passes the first three of:
#   1. cancel -> the Mac that was ringing stops, and says who stopped it
#   2. decline -> the caller's card says so, in words, instead of ringing on
#   3. both ends actually exit rather than lingering with a dead card
#   4. a bye for a DIFFERENT call changes nothing. A client that tore down on any
#      bye at all would pass 1, 2 and 3 and would let a stranger end your calls.
set -u
# Ring windows do not throw themselves in front of whatever the person at this
# Mac is doing. That behaviour is right for a phone and is proved in
# firstrun-ring-check; here it only means their taps land on cards they cannot
# see, which made this rig's verdict depend on whether anybody touched the
# trackpad while it ran.
export TK_NO_RAISE=1
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
alive() { kill -0 "$1" 2>/dev/null; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/bye-check.$$"
# ── TWO REAL IDENTITIES, KEPT ───────────────────────────────────────────────
# A handle is claimed against the real server and bound to the key that claimed
# it, so a rig that mints a fresh key each run would be refused as a squatter on
# its second run. These two live outside the repo and outside the scratch dir for
# the same reason the signing key does: they are what makes the rig repeatable.
ID1="${KIN_RIG_ONE:-$HOME/.config/kin-rig/one}"
ID2="${KIN_RIG_TWO:-$HOME/.config/kin-rig/two}"
H1=kinrigone
H2=kinrigtwo
mkdir -p "$SP"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
for d in "$ID1" "$ID2"; do
  [ -f "$d/identity.json" ] || {
    echo "no rig identity at $d. Claim the pair once:"
    echo "  TK_KIN_DIR=$ID1 $TK --claim --handle $H1 --no-update"
    echo "  TK_KIN_DIR=$ID2 $TK --claim --handle $H2 --no-update"
    exit 2; }
done
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT

# `--mute` on every one of them. The speakers belong to whoever is at this Mac.
COMMON="--window --video off --mute --no-telemetry --no-update --no-relocate --no-subtitles"
# Loopback rather than the rendezvous: what is under test is the doorbell, and a
# room nobody else joins is one fewer thing that can fail for another reason.
one() { TK_KIN_DIR="$ID1" "$TK" $COMMON --listen 8041 --peer 127.0.0.1:8042 "$@"; }
two() { TK_KIN_DIR="$ID2" "$TK" $COMMON --listen 8042 --peer 127.0.0.1:8041 "$@"; }

# ── RUN 1: the caller presses cancel ────────────────────────────────────────
R1="byerig${$}aaaa1"
spawn env TK_KIN_DIR="$ID1" "$TK" $COMMON --listen 8041 --peer 127.0.0.1:8042 \
      --room "$R1" --calling "$H2" --press-after 9 --press "@cancel" > "$SP/a.log" 2>&1
A1=$LAST_PID
spawn env TK_KIN_DIR="$ID2" "$TK" $COMMON --listen 8042 --peer 127.0.0.1:8041 \
      --room "$R1" --incoming "$H1" --press-after 25 --press "?" > "$SP/b.log" 2>&1
B1=$LAST_PID
perl -e 'select undef,undef,undef,17'
A1_GONE=no; B1_GONE=no
alive "$A1" || A1_GONE=yes
alive "$B1" || B1_GONE=yes
reap

# ── RUN 2: the callee presses decline ───────────────────────────────────────
R2="byerig${$}bbbb2"
spawn env TK_KIN_DIR="$ID1" "$TK" $COMMON --listen 8041 --peer 127.0.0.1:8042 \
      --room "$R2" --calling "$H2" --press-after 17 --press "?" > "$SP/c.log" 2>&1
A2=$LAST_PID
spawn env TK_KIN_DIR="$ID2" "$TK" $COMMON --listen 8042 --peer 127.0.0.1:8041 \
      --room "$R2" --incoming "$H1" --press-after 9 --press "@decline" > "$SP/d.log" 2>&1
B2=$LAST_PID
perl -e 'select undef,undef,undef,20'
B2_GONE=no
alive "$B2" || B2_GONE=yes
reap

# ── RUN 3: THE CONTROL -- a bye about some other call ───────────────────────
# Same sender, same signature, valid in every way, for a room this Mac is not in.
R3="byerig${$}cccc3"
spawn env TK_KIN_DIR="$ID1" "$TK" $COMMON --listen 8041 --peer 127.0.0.1:8042 \
      --room "$R3" --calling "$H2" --press-after 15 --press "?" > "$SP/e.log" 2>&1
A3=$LAST_PID
perl -e 'select undef,undef,undef,5'
env TK_KIN_DIR="$ID2" "$TK" --bye-only "$H1" --room "byerig${$}zzzz9" --no-update \
    > "$SP/f.log" 2>&1
perl -e 'select undef,undef,undef,13'
A3_GONE=no
alive "$A3" || A3_GONE=yes
reap

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }
for f in a b c d e; do
  grep -q "^tk " "$SP/$f.log" || {
    echo "BYE CHECK COULD NOT RUN -- tk never started in $f:"
    sed -n '1,6p' "$SP/$f.log" | sed 's/^/  /'; exit 2; }
done
grep -q "told @$H1" "$SP/f.log" \
  || { echo "BYE CHECK COULD NOT RUN -- the control bye was not sent:"
       sed -n '1,6p' "$SP/f.log" | sed 's/^/  /'; exit 2; }

echo "── 1. cancel: the caller tells them, and the ringing Mac stops"
grep -q "bye (cancelled): @$H2 told" "$SP/a.log" \
  && say "OK" "cancel sent a bye to @$H2" \
  || say "FAIL" "cancel sent nothing: $(grep -c '^bye' "$SP/a.log") bye lines in the caller's log"
grep -q "bye: @$H1 stopped calling" "$SP/b.log" \
  && say "OK" "and the ringing Mac heard it, by name" \
  || say "FAIL" "the ringing Mac never heard the cancel"
grep -q "ring: sounding\|ring: alert" "$SP/b.log" \
  && say "OK" "it really was ringing first, so stopping it means something" \
  || say "FAIL" "it never started ringing -- this run proved nothing"
[ "$B1_GONE" = "yes" ] \
  && say "OK" "and the copy that existed only to ask is gone" \
  || say "FAIL" "the ringing copy is still running with a dead card in it"
[ "$A1_GONE" = "yes" ] \
  && say "OK" "the caller left too, rather than hanging on its own message" \
  || say "FAIL" "the caller is still running after pressing cancel"

echo "── 2. decline: the caller is told, in words"
grep -q "bye (declined): @$H1 told" "$SP/d.log" \
  && say "OK" "decline sent a bye to @$H1" \
  || say "FAIL" "decline sent nothing"
grep -q "bye: @$H2 is not taking the call" "$SP/c.log" \
  && say "OK" "and the caller heard it" \
  || say "FAIL" "the caller never heard the decline"
TREE2=$(grep -m1 "card=" "$SP/c.log" | tail -1)
echo "     caller's card: ${TREE2:-<nothing>}"
case "$TREE2" in
  *card=noAnswer*) say "OK" "the card stopped saying it is calling" ;;
  *) say "FAIL" "the card is still $(echo "$TREE2" | sed 's/.*card=\([a-zA-Z]*\).*/\1/') after a decline" ;;
esac
case "$TREE2" in
  *"can’t talk right now"*) say "OK" "and says so in plain words" ;;
  *) say "FAIL" "the card gives no reason" ;;
esac
[ "$B2_GONE" = "yes" ] \
  && say "OK" "and the declining copy is gone" \
  || say "FAIL" "the declining copy is still running"

echo "── 3. CONTROL: a valid bye about a different call"
grep -q "hung up on a call this Mac is not on" "$SP/e.log" \
  && say "OK" "a bye for another room is seen and ignored" \
  || say "FAIL" "the stray bye was not even noticed -- this control proves nothing"
TREE3=$(grep -m1 "card=" "$SP/e.log" | tail -1)
echo "     caller's card: ${TREE3:-<nothing>}"
case "$TREE3" in
  *card=calling*) say "OK" "and the call in flight is untouched" ;;
  *) say "FAIL" "a stranger's bye changed this call: $TREE3" ;;
esac
[ "$A3_GONE" = "no" ] \
  && say "OK" "the caller is still up, still calling" \
  || say "FAIL" "a bye about another call ended this process"

[ "$fail" = "0" ] && echo "BYE CHECK: PASS" || echo "BYE CHECK: FAIL"
exit "$fail"
