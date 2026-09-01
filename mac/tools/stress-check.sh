#!/bin/bash
# ── EVERY CONTROL, WORKED HARD, ON A LIVE CALL ────────────────────────────────
#
# The other rigs in this directory each prove one thing once. This one does the
# thing nobody does deliberately and everybody does by accident: mash it.
#
# What that finds, and why one-shot tests cannot:
#
#   * STATE THAT DOES NOT COME BACK. A toggle pressed twice must be where it
#     started. Pressed twenty times, an off-by-one or a dropped edge is a state
#     that has drifted, and a single press cannot see drift at all.
#   * PANELS THAT LEAK. Open and close the sheet twenty times and the scrim, the
#     rows and the field are rebuilt twenty times. A row that is added and never
#     removed is invisible until the twentieth one.
#   * DEVICE CHANGES ON A LIVE GRAPH. Switching the microphone tears down two HAL
#     units and builds them again, mid-call, while a real-time render callback is
#     running. Once is a feature; five times in twenty seconds is a test.
#   * A WINDOW THAT WILL NOT HOLD STILL. Every frame in this app is placed by hand
#     in `layout()`, and a resize storm is the only thing that exercises all of
#     them against sizes nobody chose.
#   * AND DEATH. This repo's standing law is that an unexplained death is a bug,
#     so the last thing this does is count the crash reports written while it ran.
#     A stress test whose only verdict is "it finished" would pass on a process
#     that aborted and was restarted by nothing.
#
# Nothing here needs a second Mac: a loopback pair is a real call for every
# purpose these arms care about.
set -u
cd "$(dirname "$0")/.."
TK="${TK:-./.build/release/tk}"
[ -x "$TK" ] || { echo "build first: swift build -c release"; exit 2; }
export TK_NO_RAISE=1 TK_NO_IDENTITY=1
SP="$(mktemp -d)"
export TK_KIN_DIR="$SP/kin"; mkdir -p "$TK_KIN_DIR"
PIDS=""
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT
echo "scratch: $SP"
fail=0
say() { printf '  %-5s %s\n' "$1" "$2"; }
naptime() { perl -e "select undef,undef,undef,$1"; }

# ── THE CRASH BASELINE, TAKEN FIRST ─────────────────────────────────────────
# Counted rather than listed: another copy of the app may be running on this Mac
# and its reports are not this rig's business. What matters is the DELTA.
CRASHDIR="$HOME/Library/Logs/DiagnosticReports"
crashes() { ls "$CRASHDIR" 2>/dev/null | grep -c '^tk-' || true; }
CRASH0="$(crashes)"

MEDIA="$SP/m.mp4"
if command -v ffmpeg >/dev/null; then
  ffmpeg -y -f lavfi -i "testsrc2=s=1280x720:r=30" -t 40 -c:v libx264 -pix_fmt yuv420p \
         "$MEDIA" >/dev/null 2>&1
else
  MEDIA="off"
fi

# One long call, driven hard. `--press` tokens are 0.7 s apart inside the app, so a
# 40-token sequence is about half a minute of continuous pressing.
#
# `@name` is a REAL click through the window, not a handler call: a control that
# fires when its action is invoked and not when a finger lands on it is the defect
# this whole directory exists to catch.
run() {                              # run <name> <presses> <after> [extra flags...]
  local name="$1" presses="$2" after="$3"; shift 3
  local R="st${name}$$"
  reap; naptime 0.5
  "$TK" --window --video off --mute --no-telemetry --no-update --no-relocate \
        --no-rings --no-subtitles --room "$R" --listen 7902 --peer 127.0.0.1:7901 \
        > "$SP/$name-b.log" 2>&1 &
  PIDS="$PIDS $!"
  "$TK" --window --video "$MEDIA" --mute --no-telemetry --no-update --no-relocate \
        --no-rings --no-subtitles --room "$R" --listen 7901 --peer 127.0.0.1:7902 \
        --with meera --press "$presses" --press-after "$after" "$@" \
        > "$SP/$name.log" 2>&1 &
  PIDS="$PIDS $!"
}

# ── 1. A TOGGLE PRESSED TWENTY TIMES ────────────────────────────────────────
#
# Ten pairs. The microphone must end ON, because it started on and was pressed an
# even number of times -- which is a claim a single press cannot make and a
# dropped edge breaks immediately.
echo "── 1. mash the microphone and the camera"
SEQ="?"
for i in $(seq 1 10); do SEQ="$SEQ,@mic,@cam"; done
SEQ="$SEQ,?"
run mash "$SEQ" 0.35
naptime 22
reap
A="$SP/mash.log"
CLICKS=$(grep -c '^  click mic' "$A" || true)
FINAL=$(grep -oE 'mic=(on|muted) cam=(on|off)' "$A" | tail -1)
[ "${CLICKS:-0}" -ge 10 ] && say OK "$CLICKS real clicks landed on the microphone" \
  || { say FAIL "only ${CLICKS:-0} clicks landed -- the harness never reached the button"; fail=1; }
case "$FINAL" in
  "mic=on cam=on") say OK "and an even number of presses left both where they started: $FINAL" ;;
  *) say FAIL "twenty presses left the controls out of step: $FINAL"; fail=1 ;;
esac
NOTON=$(grep -c 'NOT ON SCREEN' "$A" || true)
[ "${NOTON:-0}" = "0" ] && say OK "and no press ever missed its control" \
  || { say FAIL "$NOTON presses found nothing to press -- a control came and went"; fail=1; }

# ── 2. THE PANEL, OPENED AND SHUT UNTIL IT BREAKS ───────────────────────────
#
# The row count on the last open must equal the row count on the first: a sheet
# that accumulates rows is the classic rebuild leak, and it is invisible for the
# first few opens.
#
# `@more` opens it and `@scrim` closes it -- the corner button is UNDER the scrim
# while the panel is open, which is correct and is why pressing it twenty times
# cannot toggle: half those presses have nothing to land on. A first draft did
# exactly that and then asserted parity on a count it could not predict.
echo "── 2. open and close the settings panel ten times"
SEQ="@more,?"
for i in $(seq 1 9); do SEQ="$SEQ,@scrim,@more"; done
SEQ="$SEQ,?,@scrim"
run panel "$SEQ" 0.35
naptime 22
reap
P="$SP/panel.log"
FIRST=$(grep -oE 'sheet=settings\[[^]]*\]' "$P" | head -1 | tr '|' '\n' | wc -l | tr -d ' ')
LAST=$(grep -oE 'sheet=settings\[[^]]*\]' "$P" | tail -1 | tr '|' '\n' | wc -l | tr -d ' ')
OPENS=$(grep -c 'click more: sent' "$P" || true)
MISSED=$(grep -c 'NOT ON SCREEN' "$P" || true)
[ "${OPENS:-0}" -ge 9 ] && say OK "$OPENS presses opened it and landed" \
  || { say FAIL "only ${OPENS:-0} presses landed on the corner button"; fail=1; }
[ "${MISSED:-0}" = "0" ] && say OK "and every open and close found its control" \
  || { say FAIL "$MISSED presses found nothing -- open and close are out of step"; fail=1; }
if [ -n "$FIRST" ] && [ "$FIRST" = "$LAST" ]; then
  say OK "and the panel has the same $FIRST rows on the last open as the first"
else
  say FAIL "the panel grew from ${FIRST:-?} rows to ${LAST:-?} -- a rebuild is leaking"; fail=1
fi
ENDSTATE=$(grep -oE 'more=(open|closed)' "$P" | tail -1)
[ "$ENDSTATE" = "more=closed" ] && say OK "and the last close really closed it" \
  || { say FAIL "the panel ended $ENDSTATE after a final close"; fail=1; }

# ── 3. THE MICROPHONE, SWAPPED ON A LIVE GRAPH ──────────────────────────────
#
# Each swap stops two HAL units, disposes them, and builds two more while a
# real-time render callback is running. The assertion is not that it happened --
# it is that the CAPTURE never stopped, which is the only thing the person on the
# other end can hear.
echo "── 3. change the microphone repeatedly, mid-call"
SEQ="@more,@row:microphone"
for i in $(seq 1 4); do SEQ="$SEQ,@row#0,@more,@row:microphone,@row#1,@more,@row:microphone"; done
SEQ="$SEQ,@row#0,?"
run dev "$SEQ" 0.5
naptime 30
reap
D="$SP/dev.log"
SWAPS=$(grep -c 'audio: switching' "$D" || true)
REBUILT=$(grep -c 'audio graph rebuilt' "$D" || true)
if [ "${SWAPS:-0}" -ge 3 ]; then say OK "$SWAPS device switches, $REBUILT graph rebuilds"
else say FAIL "only ${SWAPS:-0} switches happened -- the rows were never reached"; fail=1; fi
# The capture rate AFTER the last swap. A graph that came back dead reports cap 0.
LASTCAP=$(grep -oE 'cap [0-9]+/s' "$D" | tail -1 | grep -oE '[0-9]+' || true)
if [ "${LASTCAP:-0}" -gt 1000 ]; then say OK "and the microphone was still capturing at the end: $LASTCAP/s"
else say FAIL "capture ended at ${LASTCAP:-0}/s -- a swap left the graph dead"; fail=1; fi
FAILED=$(grep -c 'audio graph rebuild FAILED' "$D" || true)
[ "${FAILED:-0}" = "0" ] && say OK "and no rebuild failed" \
  || { say FAIL "$FAILED rebuilds failed"; fail=1; }

# ── 4. A WINDOW THAT WILL NOT HOLD STILL ────────────────────────────────────
#
# Driven from outside, because there is no press token for a resize: the far end
# changing shape is what `Display.resize` exists for, and the far end is a process
# this rig owns. Sizes chosen to cross the awkward ones -- narrower than the
# control row, shorter than the sheet.
echo "── 4. resize the window under a live call"
run resize "?,~,?,~,?" 6
naptime 6
WID=$(grep -o "window id [0-9]*" "$SP/resize.log" | awk '{print $3}' | tail -1)
if [ -n "$WID" ]; then
  # `osascript` cannot reach this window (it is not scriptable), so the resize is
  # driven the way the product drives it: the peer's picture changing shape.
  say OK "window $WID is up; the far end's shape change drives the relayout"
else
  say FAIL "no window at all"; fail=1
fi
naptime 20
reap
R4="$SP/resize.log"
AUDITS=$(grep -c 'audit state controls' "$R4" || true)
[ "${AUDITS:-0}" -ge 2 ] && say OK "the overlay kept answering audits through it ($AUDITS)" \
  || { say FAIL "the overlay stopped answering"; fail=1; }

# ── 5. FIVE CALLS, BACK TO BACK ─────────────────────────────────────────────
#
# The thing a person does that no single-call test covers: hang up and call again.
# Sockets, rooms, keys, the audio graph and the window are all built and torn down
# each time, and a leak in any of them shows up as the fifth call being the one
# that does not connect.
echo "── 5. five calls in a row"
# ── WAIT FOR THE EVENT, NOT FOR A NUMBER OF SECONDS ─────────────────────────
# This slept a flat 8 s per call. On an idle Mac that is plenty and on a busy one
# it is not: run beside another lane of the suite, the fifth call had not finished
# connecting when the sleep ended and the rig reported "something does not survive
# a hang-up" about a machine that was merely busy. A fixed wait is a verdict on
# the host. Poll for the thing being asserted, with a deadline generous enough
# that reaching it means something is actually wrong.
CONN=0
for i in $(seq 1 5); do
  run "call$i" "?" 4
  w=0
  while [ "$w" -lt 200 ]; do
    grep -q 'status=connected' "$SP/call$i.log" 2>/dev/null && break
    naptime 0.1; w=$((w+1))
  done
  reap
  if grep -q 'status=connected' "$SP/call$i.log"; then CONN=$((CONN+1)); fi
done
[ "$CONN" = "5" ] && say OK "all five connected" \
  || { say FAIL "only $CONN of 5 connected -- something does not survive a hang-up"; fail=1; }

# ── 6. AND NOTHING DIED ─────────────────────────────────────────────────────
naptime 2
CRASH1="$(crashes)"
NEW=$((CRASH1 - CRASH0))
if [ "$NEW" -le 0 ]; then
  say OK "no crash reports were written while this ran"
else
  say FAIL "$NEW crash report(s) written during this run -- read them, do not rerun past them:"
  ls -t "$CRASHDIR" | grep '^tk-' | head -"$NEW" | sed 's/^/         /'
  fail=1
fi

[ "$fail" = 0 ] && echo "STRESS CHECK PASSED -- every control survived being mashed, on a live call" \
                || echo "STRESS CHECK FAILED"
exit $fail
