#!/bin/bash
# ── DOES A CALL COME BACK? ───────────────────────────────────────────────────
#
# Every impairment in this repo used to be permanent for the life of the process,
# and this project has a recorded law about what that means: a rig that never
# heals tests only the giving-up half. The half that hands things back is the one
# that turns a bad minute into a bad call when it is wrong, and it had no rig at
# all.
#
# Two ways a call really stops and starts again, and they are different failures:
#
#   A  THE PATH DIES AND COMES BACK. Wifi drops, a router reboots, a phone moves
#      between access points. Every packet is lost for a while and then none are.
#      The claim: the app says something while it is out, the call RESUMES when the
#      path heals, and the sentence goes away again.
#
#   B  THE MACHINE STOPS AND STARTS. A lid closes, a laptop sleeps, the scheduler
#      loses a process for twenty seconds. SIGSTOP/SIGCONT is the faithful proxy --
#      the process is frozen mid-callback with its sockets open, exactly as sleep
#      leaves it, and this rig can do it to itself without touching the power
#      settings of the Mac it is running on.
#
#      The claim here is about the OTHER END: it must HOLD rather than hang up
#      (`HELD.md`), and it must come back when the peer does. `leave-check` covers
#      a peer that vanishes for good; this covers one that returns, which is the
#      case that only exists if somebody wrote a rig for it.
#
# Both arms assert RECOVERY, and recovery is measured in packets per second and
# playout -- not in the absence of an error line, which is what a call that died
# quietly also looks like.
set -u
cd "$(dirname "$0")/.."
TK="${TK:-./.build/release/tk}"
[ -x "$TK" ] || { echo "build first: swift build -c release"; exit 2; }
export TK_NO_RAISE=1 TK_NO_IDENTITY=1
SP="$(mktemp -d)"
export TK_KIN_DIR="$SP/kin"; mkdir -p "$SP/kin"
PIDS=""
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT
echo "scratch: $SP"
fail=0
say() { printf '  %-5s %s\n' "$1" "$2"; }
nap() { perl -e "select undef,undef,undef,$1"; }

# Packets a second, and playout, at the tail of a log. Two numbers because a call
# can be receiving and not playing -- which this repo has a whole watchdog arm for.
# ── AND THE PRECONDITION IS RECEIVE, NOT CAPTURE ────────────────────────────
#
# Both arms used to wait on `cap N/s`, which is THIS end's microphone. It reads
# 1500/s on a Mac that has never exchanged a packet with anybody, so "healthy
# first" was a claim about the local audio graph and nothing else -- and the arm
# then attributed everything after the outage to the outage.
#
# What that hid, measured: an arm whose impairment began BEFORE the two ends
# locked never had media flowing at all, so the app's silence detector had no
# `lastFromPeer` to go stale, correctly said nothing, and the rig recorded "A drew
# no warning during the outage" about a product that says "reconnecting…" three
# seconds in. A precondition that is true on a dead call cannot establish anything
# about a live one.
cap_of()    { grep -oE "cap [0-9]+/s" "$1" | tail -1 | grep -oE "[0-9]+"; }
recv_of()   { grep -oE "recv [0-9]+/s" "$1" | tail -1 | grep -oE "[0-9]+"; }
played_of() { grep -oE "played [0-9]+/s" "$1" | tail -1 | grep -oE "[0-9]+"; }
# The best rate seen anywhere in a window of the log, so a single slow second at
# the moment of sampling cannot read as "never recovered".
best_cap()  { grep -oE "cap [0-9]+/s" "$1" | grep -oE "[0-9]+" | sort -n | tail -1; }
# ── WAIT FOR HEALTH, DO NOT SLEEP AT IT ─────────────────────────────────────
# Arm B slept a flat 8 s for its precondition and reported "never got a healthy
# call" -- on the same machine where arm A had just measured 1505/s, seconds
# earlier. Two calls in a row need the second one's sockets, threads and audio
# graph to come up while the first one's are still going away, and how long that
# takes is not this rig's business. Poll for the thing being waited on.
wait_healthy() {                     # wait_healthy <log> <seconds>
  local w=0 lim=$(( ${2:-30} * 4 ))
  while [ "$w" -lt "$lim" ]; do
    local c; c="$(recv_of "$1")"
    [ "${c:-0}" -gt 1000 ] && { echo "$c"; return 0; }
    nap 0.25; w=$(( w + 1 ))
  done
  echo "${c:-0}"; return 1
}

# ══ A: THE PATH DIES AND COMES BACK ═════════════════════════════════════════
# `--imp-drop 100` loses every packet this end sends; `--imp-after 6` starts that
# at 6 s and `--imp-until 20` heals it at 20 s, both measured from the first packet
# rather than from launch (see Impair). So the shape is: a healthy call, an outage,
# and a path that is perfect again -- which is what wifi actually does.
#
# `--imp-after` exists because of this arm. Without it the loss began before the
# two ends had exchanged anything, so there was never a working call to lose: the
# app's silence detector had no "time since the last packet from the peer" to read,
# said nothing -- correctly -- and this rig wrote that down as an app that says
# nothing during an outage. An outage has to be an EVENT to be tested at all.
echo "── A. every packet lost for a while, then a path that is perfect again"
R="rc$$a"
"$TK" --window --video off --mute --no-telemetry --no-update --no-relocate \
      --no-rings --no-subtitles --room "$R" --listen 7841 --peer 127.0.0.1:7842 \
      > "$SP/a.log" 2>&1 &
PIDS="$PIDS $!"
"$TK" --window --video off --mute --no-telemetry --no-update --no-relocate \
      --no-rings --no-subtitles --room "$R" --listen 7842 --peer 127.0.0.1:7841 \
      --imp-drop 100 --imp-after 6 --imp-until 20 > "$SP/b.log" 2>&1 &
PIDS="$PIDS $!"
# Let it connect and prove it is healthy BEFORE the outage, or "it recovered" has
# nothing to be measured against.
HEALTHY="$(wait_healthy "$SP/a.log" 30)"
if [ "${HEALTHY:-0}" -gt 1000 ]; then
  say OK "healthy first: A is RECEIVING ${HEALTHY}/s -- media really was flowing"
else
  echo "  RECOVER CHECK COULD NOT RUN -- A was only at ${HEALTHY:-0}/s before the"
  echo "  outage, so nothing after it can be attributed to the outage."; exit 2
fi
# Mid-outage: A is sending fine, but nothing from B is arriving. The outage starts
# 6 s after the first packet and lasts to 20 s, so this samples the middle of it.
nap 8
OUTRECV="$(grep -oE "recv [0-9]+/s" "$SP/a.log" | tail -1 | grep -oE '[0-9]+')"
[ "${OUTRECV:-9999}" -lt 200 ] \
  && say OK "during the outage A receives almost nothing: ${OUTRECV}/s" \
  || { say FAIL "the outage never happened -- A still receives ${OUTRECV}/s"; fail=1; }
# ── AND IT MUST SAY SOMETHING, IN THE FIELD THE APP ACTUALLY WRITES ─────────
#
# This looked for `warn=` and `poster=`, which are the VIDEO sentences -- "their
# camera is off", "their connection is weak -- video paused". On an audio-only
# call neither can ever be set, so the rig's own conclusion was that the app draws
# nothing during an outage, and it wrote that down as a note and passed.
#
# What the app really does is `setStatus("reconnecting…")`, from the silence
# detector in the poll loop: three seconds with nothing from the locked address,
# measured on ARRIVING PACKETS, so it is the same sentence on a call with a
# picture and a call without one. Measured directly, with media flowing first and
# the far end frozen mid-call:
#
#     room oc35870: nothing from 43.248.153.253:34712 for 3 s -- looking again
#       telling them: reconnecting
#
# So it is asserted, on the log line AND on the status field, because the line
# proves the decision and the field proves a person can see it.
if grep -qE "telling them: reconnecting" "$SP/a.log"; then
  say OK "and A says so: the silence detector fired and set the status"
  grep -qE "status=reconnecting" "$SP/a.log" \
    && say OK "and the sentence is on the window, not only in the log" \
    || say note "status= was not sampled during the outage (no --press ? in this arm)"
else
  say FAIL "A said nothing during a total outage: no 'telling them: reconnecting'."
  say FAIL "  A call that goes silent with no explanation is the complaint this"
  say FAIL "  detector exists for."; fail=1
fi
# The healing, and the recovery.
nap 16
BEST="$(best_cap "$SP/a.log")"
NOWRECV="$(grep -oE "recv [0-9]+/s" "$SP/a.log" | tail -1 | grep -oE '[0-9]+')"
NOWPLAY="$(played_of "$SP/a.log")"
reap
if [ "${NOWRECV:-0}" -gt 1000 ]; then
  say OK "after the path healed A receives ${NOWRECV}/s again"
else
  say FAIL "A is still only receiving ${NOWRECV:-0}/s -- the call did not come back"; fail=1
fi
if [ "${NOWPLAY:-0}" -gt 1000 ]; then
  say OK "and playing ${NOWPLAY}/s -- the sound is actually back, not just the packets"
else
  say FAIL "packets are arriving at ${NOWRECV:-0}/s and only ${NOWPLAY:-0}/s is played"; fail=1
fi
grep -q "IMPAIRED: path healed" "$SP/b.log" \
  && say OK "and the impairment really did lift (its own line says so)" \
  || { say FAIL "the path never healed, so this arm proves nothing"; fail=1; }

# ══ B: THE MACHINE STOPS AND STARTS ═════════════════════════════════════════
# SIGSTOP freezes B mid-callback with its sockets open, which is what sleep looks
# like from the outside. The assertions are about A: it must not hang up, and it
# must come back.
echo "── B. one end frozen for 15 s, as a sleeping laptop is, then resumed"
R2="rc$$b"
"$TK" --window --video off --mute --no-telemetry --no-update --no-relocate \
      --no-rings --no-subtitles --room "$R2" --listen 7851 --peer 127.0.0.1:7852 \
      > "$SP/c.log" 2>&1 &
APID=$!; PIDS="$PIDS $APID"
"$TK" --window --video off --mute --no-telemetry --no-update --no-relocate \
      --no-rings --no-subtitles --room "$R2" --listen 7852 --peer 127.0.0.1:7851 \
      > "$SP/d.log" 2>&1 &
BPID=$!; PIDS="$PIDS $BPID"
H2="$(wait_healthy "$SP/c.log" 40)"
[ "${H2:-0}" -gt 1000 ] \
  && say OK "healthy first: A is RECEIVING ${H2}/s -- media really was flowing" \
  || { echo "  RECOVER CHECK COULD NOT RUN -- arm B never got a healthy call in 40 s"
       echo "  (last seen ${H2:-0}/s). Ports from arm A may still be closing."; exit 2; }
kill -STOP "$BPID"
say note "B frozen (SIGSTOP)"
nap 15
# THE CLAIM THAT MATTERS: A is still alive and still in the call.
if kill -0 "$APID" 2>/dev/null; then
  say OK "A is still running after 15 s of silence -- it did not hang up on a"
  say OK "  peer that had merely stopped"
else
  say FAIL "A exited while B was frozen: a sleeping laptop ends the call"; fail=1
fi
# A frozen peer is not a departed one, and the two have different sentences. The
# app must say ONE of them -- "reconnecting…" while it looks again, or
# "…'ll be right back" once it decides the peer is held -- and it must NOT say
# "the other person left", because they did not.
if grep -qE "telling them: reconnecting|right back|holding the call open" "$SP/c.log"; then
  say OK "and it said so rather than tearing the call down"
else
  say FAIL "A said nothing while its peer was frozen for 15 s"; fail=1
fi
grep -q "the other person left" "$SP/c.log" \
  && { say FAIL "A told the person their peer LEFT during a 15 s freeze -- they"
       say FAIL "  had not, and the invite card came back over a live call"; fail=1; } \
  || say OK "and it never claimed they had left"
kill -CONT "$BPID"
say note "B resumed (SIGCONT)"
nap 12
BACKRECV="$(grep -oE "recv [0-9]+/s" "$SP/c.log" | tail -1 | grep -oE '[0-9]+')"
BACKPLAY="$(played_of "$SP/c.log")"
ALIVE=$(kill -0 "$APID" 2>/dev/null && echo yes || echo no)
reap
[ "$ALIVE" = yes ] \
  && say OK "and both ends were still up at the end" \
  || { say FAIL "A died somewhere in the resume"; fail=1; }
if [ "${BACKRECV:-0}" -gt 1000 ] && [ "${BACKPLAY:-0}" -gt 1000 ]; then
  say OK "the call resumed by itself: recv ${BACKRECV}/s, played ${BACKPLAY}/s"
else
  say FAIL "after the resume: recv ${BACKRECV:-0}/s, played ${BACKPLAY:-0}/s -- it did not come back"
  fail=1
fi

[ "$fail" = 0 ] && echo "RECOVER CHECK PASSED -- a dead path and a frozen machine both come back" \
                || echo "RECOVER CHECK FAILED"
exit $fail
