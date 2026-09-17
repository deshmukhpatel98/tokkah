#!/bin/bash
# ── DOES CALLING SOMEBODY PUT THEM IN YOUR LIST? ─────────────────────────────
#
# It did not. `Identity.remember` had exactly ONE call site in the whole app --
# `onAnswerRing` -- so a person was written down only when you ANSWERED their
# call. Place the call yourself and nobody was recorded; meet on an invite link
# and neither end recorded the other. Meanwhile the People panel said, in words:
#
#     "Call someone once and they'll show up here."
#
# For a product whose whole direction is calling people rather than rooms, the
# person who does the calling had an empty panel for ever, under a hint promising
# the opposite.
#
# (2026-09-11: since 0.128.0 the media handshake is signed by the device key and
# `wire.onPeerIdentity` pins the PROVEN key under the handle a call was placed to
# -- so the caller does learn the callee's key now, at the lock, and the claims
# about "no key" below became claims about "the right key". `called.json` is still
# the panel's own record of who was actually talked to.)
#
# The fix cannot be "write the callee into contacts.json when you dial them",
# because THE CALLER NEVER LEARNS THE CALLEE'S KEY: the doorbell answers
# {ok,queued,...} and there is deliberately no handle->key route, and the key on
# the media socket is an unsigned ephemeral X25519 one with no identity in it. So
# the caller records a NAME with no key, in its own file, and that is what this
# rig has to hold to.
#
# Five claims, and the fifth is the one a broken fix passes the first four of:
#   1. the caller's list contains the callee after a real call
#   2. the callee's list still contains the caller, with the RIGHT key
#   3. a call nobody answers records nobody, on either side, even though the
#      transport really locked and their picture really arrived
#   4. two people who met on a link record nobody -- there is no name to record
#   5. the entry is the right KEY. A rig that only checks that a name is present
#      cannot tell a correct contact list from a poisoned one, and would pass
#      identically on a fix that wrote the wrong key or invented one.
set -u
# Ring windows do not throw themselves in front of whatever the person at this
# Mac is doing. Here it only means presses land on cards nobody can see, which
# would make this rig's verdict depend on whether anybody touched the trackpad.
export TK_NO_RAISE=1
# ── NOT ONE HANDLE ON THE REAL SERVER ───────────────────────────────────────
#
# Every rig in tools/ that claims walks @devesh, @deveshp, @devesh2 ... squatting
# plausible names a person might want. Nothing here needs a claim: the ring is
# handed to each end in argv, so the doorbell is never used. TK_KIN_BASE points
# the identity code at a port nothing listens on, so even the dial in part five --
# which really does call `Identity.ring` off a real click -- cannot leave this Mac.
export TK_NO_IDENTITY=1
export TK_KIN_BASE="http://127.0.0.1:9"
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
# ── A PROCESS THAT LEFT ON ITS OWN SAYS HOW ─────────────────────────────────
#
# `wait <pid>` on a child that has already exited returns its status: 0 is a
# clean exit and 128+N a signal; a child still running is left for `reap`. This
# rig reported "part one's caller never connected … status=can't reach Kin" twice
# on 2026-09-11, and the cause was neither the caller nor the server: the CALLEE
# had answered and died with SIGSEGV on the way into the call (the final beat read
# the audio engine before it existed). A rig that cannot see a death diagnoses the
# nearest thing it can see (`unexplained-death-is-a-bug`).
status_of() { # <pid> -> alive | exit N | signal N
  if kill -0 "$1" 2>/dev/null; then echo alive; return; fi
  wait "$1" 2>/dev/null; local st=$?
  if [ "$st" -ge 128 ]; then echo "signal $((st - 128))"; else echo "exit $st"; fi
}
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/contacts-check.$$"
mkdir -p "$SP"
# ── ITS OWN IDENTITY DIRECTORY, AND THAT IS NOT POLITENESS ──────────────────
#
# `.applicationSupportDirectory` resolves through the USER RECORD and not $HOME,
# so a rig without TK_KIN_DIR reads and WRITES the real install's contact list --
# and this rig's whole subject is the contact list. Exported as a default so a
# launch that forgets to override it still lands in scratch; every end below
# overrides it, because the two ends of a call keep two different lists and a
# shared directory would let one end's write satisfy an assertion about the other.
export TK_KIN_DIR="$SP/id"
mkdir -p "$SP/id"
# ── ALICE'S KEY IS ALICE'S KEY ──────────────────────────────────────────────
#
# KA used to be 32 zero bytes. Since 0.128.0 the media handshake is signed by the
# device key, so a callee told "alice's key is KA" refuses a handshake from a
# caller who cannot prove KA -- and a caller minted on first run never can. Parts
# one and two put alice's REAL key on the ring: her identity is seeded from a fixed
# Ed25519 seed in her directories (the file the app would otherwise mint), and its
# public half is derived here and checked against what the app says it is. KB is
# any other 32 bytes -- part four only checks that the value on the ring is the
# value written down, and part six that a dialled name unlocks nothing.
seed_identity() { # <dir> <32-byte seed, 64 hex chars> -> base64 Ed25519 public key on stdout
  mkdir -p "$1"
  local seed_b64; seed_b64="$(printf '%s' "$2" | xxd -r -p | base64)"
  printf '{"seed":"%s","tok":"%s","handle":"rig","claimed":false,"quiet":false}' \
    "$seed_b64" "$(printf '%064d' 0)" > "$1/identity.json"
  chmod 600 "$1/identity.json"
  { printf '302e020100300506032b657004220420' | xxd -r -p; printf '%s' "$2" | xxd -r -p; } \
    | openssl pkey -inform DER -pubout -outform DER 2>/dev/null | tail -c 32 | base64
}
ALICE_SEED=0303030303030303030303030303030303030303030303030303030303030303
KA="$(seed_identity "$SP/a1" "$ALICE_SEED")"
seed_identity "$SP/a2" "$ALICE_SEED" > /dev/null
[ "${#KA}" = 44 ] || { echo "CONTACTS CHECK COULD NOT RUN -- this openssl ($(openssl version)) cannot derive an Ed25519 public key"; exit 2; }
KB="AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
[ -x "$TK" ] || { echo "CONTACTS CHECK COULD NOT RUN -- no tk at $TK; swift build first"; exit 2; }
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT

# `--video off` everywhere. Nothing here is about a picture, and a person is using
# this Mac: a rig that turns the camera on puts a green light next to them for no
# assertion's sake. `--mute` for the same reason -- the speakers are theirs.
# `--route headphones` since 0.166.0: answering is refused on a loudspeaker
# route, and this rig's subject is the contact list, not the door. Earbuds is
# the only route a real call has now, so pinning it is the product config --
# the door has its own rig (`earbuds-check`).
BASE="--window --video off --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles --route headphones"

# ── THE FILE IS EVIDENCE OF A DIFFERENT KIND FROM A TREE DUMP ───────────────
#
# A `?` dump is what a person can see and press RIGHT NOW; the contact file is
# what the NEXT launch will read. Both matter and they are not interchangeable:
# the panel is built from the file at the moment it opens, so a fix that writes
# the file correctly and a fix that only decorates the panel are told apart by
# reading both. Parts one to four read the file. Part five presses the screen.
called_has() { [ -f "$1/called.json" ] && grep -q "\"$2\"" "$1/called.json"; }
keyfor() { # <dir> <handle> -> the stored key, JSON-decoded: the file escapes "/" as "\/"
  [ -f "$1/contacts.json" ] || return 0
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1/contacts.json" "$2"
}
identity_of() { grep -oE 'crypto: my identity [^,]+' "$1" | head -1 | awk '{print $4}'; }
dump() { for f in "$1/contacts.json" "$1/called.json"; do
           [ -f "$f" ] && printf '       %s = %s\n' "$(basename "$f")" "$(cat "$f")"
         done; : ; }

# ── PART ONE: alice calls bob, and bob answers ──────────────────────────────
#
# The ring is handed to each end in argv exactly as the watcher hands it over, so
# no server is involved: `--calling bob` is the flag the caller's re-exec sets
# after the doorbell accepted the ring, and `--incoming alice --incoming-key` is
# the watcher's own launch line. Answering re-execs, and TK_KIN_DIR survives it
# because execv inherits the environment.
R1="conchk$$a"
mkdir -p "$SP/a1" "$SP/b1"
spawn env TK_KIN_DIR="$SP/a1" "$TK" $BASE --room "$R1" --listen 8105 --peer 127.0.0.1:8106 \
      --calling bob --press-after 16 --press "?" > "$SP/a1.log" 2>&1
perl -e 'select undef,undef,undef,2'
spawn env TK_KIN_DIR="$SP/b1" "$TK" $BASE --room "$R1" --listen 8106 --peer 127.0.0.1:8105 \
      --incoming alice --incoming-key "$KA" --press-after 4 --press "@answer" > "$SP/b1.log" 2>&1
B1PID=$LAST_PID
perl -e 'select undef,undef,undef,19'
B1_ST="$(status_of "$B1PID")"
reap

# ── PART TWO: the same call, never answered ─────────────────────────────────
#
# THE ARM THAT SEPARATES LOCKED FROM ANSWERED, and it is the reason bob's end is
# seeded with alice's key here. A ring from somebody already in your contacts
# joins the room before anybody presses anything, so that you can see who is
# calling -- the transport really locks and packets really flow, and the CALLER
# sees a live peer. If the caller recorded at the lock rather than at the answer,
# this arm records bob and part one could never tell the difference.
R2="conchk$$b"
mkdir -p "$SP/a2" "$SP/b2"
printf '{"alice":"%s"}' "$KA" > "$SP/b2/contacts.json"
cp "$SP/b2/contacts.json" "$SP/b2.seed"
spawn env TK_KIN_DIR="$SP/a2" "$TK" $BASE --room "$R2" --listen 8105 --peer 127.0.0.1:8106 \
      --calling bob --press-after 14 --press "?" > "$SP/a2.log" 2>&1
perl -e 'select undef,undef,undef,2'
spawn env TK_KIN_DIR="$SP/b2" "$TK" $BASE --room "$R2" --listen 8106 --peer 127.0.0.1:8105 \
      --incoming alice --incoming-key "$KA" --press-after 12 --press "?" > "$SP/b2.log" 2>&1
perl -e 'select undef,undef,undef,17'
reap

# ── PART THREE: two people who met on a link ────────────────────────────────
#
# No `--calling`, no `--incoming`: just a room, which is what clicking an invite
# gives you. `Rendezvous.exchange` sends `me=mac-<pid>` and the media handshake
# carries "no identity, no room code, nothing that is worth anything to a
# listener", so neither end ever utters a handle. The claim is that both lists
# stay empty -- and it is only worth anything alongside "connected via" in both
# logs, or it would pass for two processes that never found each other.
R3="conchk$$c"
mkdir -p "$SP/a3" "$SP/b3"
spawn env TK_KIN_DIR="$SP/a3" "$TK" $BASE --room "$R3" --listen 8105 --peer 127.0.0.1:8106 \
      --press-after 12 --press "?" > "$SP/a3.log" 2>&1
perl -e 'select undef,undef,undef,1'
spawn env TK_KIN_DIR="$SP/b3" "$TK" $BASE --room "$R3" --listen 8106 --peer 127.0.0.1:8105 \
      --press-after 12 --press "?" > "$SP/b3.log" 2>&1
perl -e 'select undef,undef,undef,16'
reap

# ── PART FOUR: THE SAME ANSWER WITH A DIFFERENT KEY ON THE RING ─────────────
#
# Everything about this run is part one's callee except the key in the envelope.
# A rig that asserted only "alice is in bob's list" passes this byte for byte,
# which is the difference between checking a contact list and checking that it is
# not poisoned. The contact is written BEFORE the re-exec, synchronously, so no
# second process and no peer is needed to observe it.
mkdir -p "$SP/b4"
spawn env TK_KIN_DIR="$SP/b4" "$TK" $BASE --room "conchk$$d" --listen 8106 --peer 127.0.0.1:8105 \
      --incoming alice --incoming-key "$KB" --press-after 4 --press "@answer" > "$SP/b4.log" 2>&1
perl -e 'select undef,undef,undef,9'
reap

# ── PART FIVE: THE PANEL A PERSON ACTUALLY PRESSES ──────────────────────────
#
# Everything above reads a file. This part opens the People panel over the list
# part one produced and CLICKS the first row, because a handler that fills an
# array proves nothing about a row a finger can reach -- every interaction bug in
# this project has lived between the handler and the finger.
#
# `people` is navigation and is a token, not a click: it is how the rig reaches
# the page without guessing which sheet row opens it. `@row#0` is the assertion
# and it is a real synthetic click through the window, at the row's own centre,
# hit-tested exactly as a press arrives. `dial` sets the card BEFORE it rings, so
# the tree dump straight after names whoever the row actually was.
#
# The control ranks the opposite way and is not a variation on the same run: an
# EMPTY list builds the same page with the same first row index, and that row is
# your own circle with `copy` on it. Same click, same coordinates, different
# person -- so `face=bob` is a statement about the list and not about the layout.
spawn env TK_KIN_DIR="$SP/a1" "$TK" $BASE --room "conchk$$e" --listen 8105 \
      --press-after 3 --press "people,?,@row#0,?" > "$SP/p1.log" 2>&1
perl -e 'select undef,undef,undef,9'
reap
mkdir -p "$SP/empty"
spawn env TK_KIN_DIR="$SP/empty" "$TK" $BASE --room "conchk$$f" --listen 8105 \
      --press-after 3 --press "people,?,@row#0,?" > "$SP/p2.log" 2>&1
perl -e 'select undef,undef,undef,9'
reap

# ── PART SIX: A NAME IN THE PANEL IS NOT A KEY IN THE DOOR ──────────────────
#
# bob is in the caller's panel now. bob has never proved anything to this Mac --
# the caller typed the name and the doorbell hands back no key. So a ring
# CLAIMING to be bob must get exactly what a stranger's ring gets: a card, and no
# socket. `known` is what opens that socket before anybody agrees to talk, and
# RINGING.md is explicit about what it costs -- "the CALLER learns the callee's IP
# and that the Mac is online and awake, before consent. This is the real leak."
spawn env TK_KIN_DIR="$SP/a1" "$TK" $BASE --room "conchk$$g" --listen 8105 --peer 127.0.0.1:8106 \
      --incoming bob --incoming-key "$KB" --press-after 5 --press "?" > "$SP/s1.log" 2>&1
perl -e 'select undef,undef,undef,9'
reap

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }
for f in a1 b1 a2 b2 a3 b3 b4 p1 p2 s1; do
  grep -q "^tk " "$SP/$f.log" || {
    echo "CONTACTS CHECK COULD NOT RUN -- tk never started in $f:"
    sed -n '1,6p' "$SP/$f.log" | sed 's/^/  /'; exit 2; }
done
# The two runs that have to be real calls, checked as a precondition rather than
# as a claim. Every "recorded nobody" assertion below is worthless if the call
# never happened, and a rig that cannot see the event returns the same value as a
# real negative.
grep -q "answer committed by NSEventType" "$SP/b1.log" || {
  echo "CONTACTS CHECK COULD NOT RUN -- part one was never answered by a click:"
  grep -m3 "ring: answer" "$SP/b1.log" | sed 's/^/  /'; exit 2; }
# THE RULER: the key this rig derived is the identity alice says she has.
grep -qF "crypto: my identity $KA," "$SP/a1.log" || {
  echo "CONTACTS CHECK COULD NOT RUN -- alice's identity is not the key this rig derived:"
  grep -m1 "crypto: my identity" "$SP/a1.log" | sed 's/^/  app: /'; echo "  rig: $KA"; exit 2; }
# A callee that answered and DIED is a product failure, and it is named as one
# before the caller's silence can be blamed on the network.
case "$B1_ST" in
  alive) ;;
  *) echo "CONTACTS CHECK FAILED -- the callee answered and then died ($B1_ST) on the way into"
     echo "  the call. That is a crash, not a network problem: read the newest tk-*.ips in"
     echo "  ~/Library/Logs/DiagnosticReports before touching anything else."
     tail -3 "$SP/b1.log" | cut -c1-120 | sed 's/^/  /'; exit 1 ;;
esac
grep -q "connected via" "$SP/a1.log" || {
  echo "CONTACTS CHECK COULD NOT RUN -- part one's caller never connected, so"
  echo "  there was no call to record. Last state:"
  grep -m2 "^audit state" "$SP/a1.log" | sed 's/^/  /'; exit 2; }

echo "── 1. the person you CALLED is in your list"
echo "     caller's dir after the call:"; dump "$SP/a1"
called_has "$SP/a1" bob \
  && say "OK" "alice called bob, they talked, and bob is written down" \
  || say "FAIL" "the caller recorded NOBODY -- called.json is $(cat "$SP/a1/called.json" 2>/dev/null || echo missing)"
# ── AND THE KEY AGAINST THE NAME IS THE ONE BOB'S MAC PROVED ────────────────
#
# This asserted NO key for bob, on the reasoning that the caller is never handed
# one. Since 0.128.0 it is: the handshake is signed by the device key, and the
# proven key is pinned under the handle the call was placed to. So the claim is
# the stronger one -- the caller holds exactly the key bob's Mac proved, and any
# other value is the poisoned list this rig exists to see. (With the fake keys
# this rig used to carry, the handshake never keyed, nothing was ever pinned, and
# the old row passed for the wrong reason.)
B1ID="$(identity_of "$SP/b1.log")"; K1="$(keyfor "$SP/a1" bob)"
[ -n "$B1ID" ] || say "FAIL" "bob's Mac never stated its identity, so the pinned key cannot be checked"
[ -n "$K1" ] && [ "$K1" = "$B1ID" ] \
  && say "OK" "and the key against the name is the one bob's Mac proved in the handshake (${K1:0:12}…)" \
  || say "FAIL" "the caller holds [${K1:-nothing}] for bob; bob's Mac proved [${B1ID:-?}]"

echo "── 2. and the person who called YOU still is, with the right key"
echo "     callee's dir after the call:"; dump "$SP/b1"
[ "$(keyfor "$SP/b1" alice)" = "$KA" ] \
  && say "OK" "bob answered alice and stored the key that actually rang" \
  || say "FAIL" "the callee stored [$(keyfor "$SP/b1" alice)], wanted [$KA]"

echo "── 3. a call nobody answered records nobody"
grep -q "the ring card reached them" "$SP/b2.log" \
  && say "OK" "PRECONDITION: the ring really did join the room and lock" \
  || say "FAIL" "the ring never connected, so this part tests nothing at all"
grep -q "they are being asked -- not connected yet" "$SP/a2.log" \
  && say "OK" "and the caller saw a live peer that had answered nothing" \
  || say "FAIL" "the caller never saw the ringing peer -- the arm is not armed"
grep -q "connected via" "$SP/a2.log" \
  && say "FAIL" "the caller called an unanswered ring a connection" \
  || say "OK" "so the caller never called it connected"
called_has "$SP/a2" bob \
  && say "FAIL" "and wrote bob down anyway -- a lock is not an answer" \
  || say "OK" "and wrote nobody down"
# The lock keyed the handshake, so the caller learned bob's PROVEN identity and
# pinned it (0.128.0, see part one). What an unanswered call must not do is put
# bob in the People panel (`called.json`, asserted above) or pin a key bob's Mac
# did not prove.
B2ID="$(identity_of "$SP/b2.log")"; K2="$(keyfor "$SP/a2" bob)"
if [ -z "$K2" ]; then
  say "OK" "and pinned no key either"
elif [ -n "$B2ID" ] && [ "$K2" = "$B2ID" ]; then
  say "OK" "and the only key it pinned is the one bob's Mac proved at the lock (the People panel still waits for an answer)"
else
  say "FAIL" "an unanswered call pinned a key bob never proved: [$K2] vs bob's [${B2ID:-?}]"
fi
cmp -s "$SP/b2/contacts.json" "$SP/b2.seed" \
  && say "OK" "and the ringing end's list is byte-identical to what it started with" \
  || say "FAIL" "the ringing end changed its own list: $(cat "$SP/b2/contacts.json")"

echo "── 4. two people who met on a link record nobody"
grep -q "connected via" "$SP/a3.log" && grep -q "connected via" "$SP/b3.log" \
  && say "OK" "PRECONDITION: both ends really connected to each other" \
  || say "FAIL" "the link call never connected, so recording nothing proves nothing"
[ ! -f "$SP/a3/called.json" ] && [ ! -f "$SP/a3/contacts.json" ] \
  && say "OK" "and one end's list is still empty -- a link is a capability, not a name" \
  || { say "FAIL" "a link call wrote something:"; dump "$SP/a3"; }
[ ! -f "$SP/b3/called.json" ] && [ ! -f "$SP/b3/contacts.json" ] \
  && say "OK" "and so is the other's" \
  || { say "FAIL" "a link call wrote something at the far end:"; dump "$SP/b3"; }
say "OK" "CONTROL: part one is the same two processes WITH names, and recorded both"

echo "── 5. the right key, not merely the right name"
K4="$(keyfor "$SP/b4" alice)"
echo "     the ring carried $KB"
echo "     the list says    ${K4:-<nothing>}"
[ "$K4" = "$KB" ] \
  && say "OK" "a different key on the ring produced a different entry" \
  || say "FAIL" "the ring carried $KB and the list says [${K4:-nothing}]"
[ "$K4" != "$KA" ] \
  && say "OK" "and it is NOT part one's key, so this rig can see a poisoned list" \
  || say "FAIL" "the rig reads the same key whatever rang -- it checks names only"

echo "── 6. the list is a thing a person can see and press"
# The panel BEFORE the click. `people=N` is what the page was built from and the
# row's own class is what it became -- a `ContactRow` is a face with a handle on
# it, an ordinary `SheetRow` is a line of text. Asserted separately from the click
# because "the list is populated" and "the populated row is reachable" are two
# claims, and only the second one is about a finger.
grep -m1 "^audit state" "$SP/p1.log" | grep -q "people=1" \
  && say "OK" "the panel was built from a list with one person in it" \
  || say "FAIL" "the panel says [$(grep -m1 '^audit state' "$SP/p1.log" | grep -o 'people=[0-9]*')]"
R0=$(grep -m1 "^audit OK   row#0" "$SP/p1.log")
echo "     ${R0:-<no row#0>}"
echo "$R0" | grep -q "ContactRow" \
  && say "OK" "and the first row is a face with a handle on it, not a line of text" \
  || say "FAIL" "the first row is not a contact row"
grep -q "click row#0: sent" "$SP/p1.log" \
  && say "OK" "which took a real click, hit-tested through the window" \
  || say "FAIL" "the contact row was not clickable: $(grep -m1 'click row#0' "$SP/p1.log")"
P1=$(grep -m1 "^click row#0" "$SP/p1.log")
echo "     ${P1:-<no click line>}"
echo "$P1" | grep -q 'face=bob' \
  && say "OK" "and clicking it dialled BOB -- their initial, their colour" \
  || say "FAIL" "clicking the first row reached [$(echo "$P1" | grep -o 'face=[a-z0-9]*')]"
echo "$P1" | grep -q 'card=calling' \
  && say "OK" "and the card says it is calling them" \
  || say "FAIL" "the card was [$(echo "$P1" | grep -o 'card=[a-z]*')]"
# ── THE CONTROL, WHICH MUST LAND SOMEWHERE ELSE AND SAY SO ─────────────────
#
# Not merely "not bob". An empty People page has the same first row INDEX at
# nearly the same coordinates, and it is "Call someone new" -- so the same click
# opens the dial field instead. Stating where it lands is what makes this a
# control rather than an absence: a click that silently did nothing would satisfy
# "not bob" and prove nothing about the list.
P2=$(grep -m1 "^click row#0" "$SP/p2.log")
echo "     CONTROL, empty list: ${P2:-<no click line>}"
echo "$P2" | grep -q 'face=bob' \
  && say "FAIL" "CONTROL: an EMPTY list dialled bob too -- the row is not the list" \
  || say "OK" "CONTROL: an empty list does not dial bob"
echo "$P2" | grep -q 'card=dial' \
  && say "OK" "CONTROL: the same click lands on \"call someone new\" instead" \
  || say "FAIL" "CONTROL: the same click on an empty list did nothing observable at all"

echo "── 7. a name you dialled confers no trust on a ring claiming it"
# NOT VACUOUS. This whole part is about a name that IS in the panel, so it is
# stated here rather than assumed from part one: an empty list refuses the same
# ring for a completely different reason, and would print the same green line.
called_has "$SP/a1" bob \
  && say "OK" "PRECONDITION: this is the list bob is actually in" \
  || say "FAIL" "bob is not in this list, so refusing his ring proves nothing"
grep -q "is not in this Mac's contacts" "$SP/s1.log" \
  && say "OK" "bob is in the panel and a ring claiming bob still opens no socket" \
  || say "FAIL" "a dialled name unlocked the pre-answer connection"
SRECV=$(grep -oE "recv [0-9]+/s" "$SP/s1.log" | grep -vc "recv 0/s")
[ "${SRECV:-1}" = "0" ] \
  && say "OK" "and it received nothing, so it revealed nothing" \
  || say "FAIL" "a ring claiming a dialled name opened a path: $SRECV reports received"
grep -q "card=ringing" "$SP/s1.log" \
  && say "OK" "CONTROL: they can still ring you -- the card is there" \
  || say "FAIL" "CONTROL: that ring drew no card at all, so this part proves nothing"

echo
if [ "$fail" = 0 ]; then
  echo "CONTACTS CHECK PASSED -- calling someone remembers them, and only a name"
else
  echo "CONTACTS CHECK FAILED -- see above; logs in $SP"
  for f in a1 b1 a2 a3 p1 s1; do
    cp "$SP/$f.log" "${SCRATCH:-${TMPDIR:-/tmp}}/contacts-check-$f.log" 2>/dev/null
  done
fi
exit $fail
