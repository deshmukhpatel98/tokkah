#!/bin/bash
# ── IS THE APP'S OWN RECORD READABLE? ────────────────────────────────────────
#
# Kin writes a beat every few seconds: a few hundred numbers about the call,
# appended to `~/Library/Logs/Kin/beats.ndjson` before it is sent, because a beat
# that fails to send is exactly the one worth having. It is the file that answers
# "what happened on that call" an hour later, and this repo has a standing rule
# that the telemetry must NAME the fault rather than merely record numbers.
#
# Read strictly for the first time, the real file said this:
#
#     1824 lines, 394 unparseable
#       366  Illegal trailing comma before end of object
#        17  Expecting value            (a line that starts mid-token)
#         9  Extra data                 (two records spliced into one line)
#
# 21% of the record was unreadable, and three separate faults were behind it:
#
#   1  A COMMA TOO MANY. Every strict parser refuses `{"a":1,}` -- and Apple's
#      does not. `JSONSerialization` and `JSONDecoder` both ACCEPT it, so the
#      stack that wrote these lines and the stack that would have caught them are
#      the same tolerant one, and the first reader to complain was a person with
#      python. Hence a scanner of our own, and a repair: the record either side of
#      that comma is perfectly good.
#
#   2  TWO PROCESSES, ONE FILE, NO O_APPEND. The log path is fixed; the handle was
#      opened for writing and seeked to the end ONCE. A second Kin -- a rig, a
#      second install -- then wrote at its own advancing offset, straight over the
#      first one's records. That is the spliced and mid-token lines.
#
#   3  A NaN WOULD HAVE KILLED THE APP. Not corrupted a line: ended the process.
#      `JSONSerialization.data(withJSONObject:)` RAISES `NSInvalidArgumentException`
#      on a non-finite number, an ObjC exception Swift cannot catch and `try?`
#      cannot see. Every beat is built from ratios and there was not one
#      `isFinite` on the path, so any zero denominator aborted Kin mid-call, from
#      a diagnostic.
#
# Two arms: the writer's own calibration (including the inputs it must REJECT),
# and then the real thing -- a live call's beats, read strictly, because a
# hand-written fixture only ever tests the fixture.
set -u
cd "$(dirname "$0")/.."
TK="${TK:-./.build/release/tk}"
[ -x "$TK" ] || { echo "BEAT CHECK COULD NOT RUN -- no tk at $TK"; exit 2; }
SP="$(mktemp -d)"
trap 'kill -9 $PIDS 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT
PIDS=""
fail=0
say() { printf '  %-5s %s\n' "$1" "$2"; }
nap() { perl -e "select undef,undef,undef,$1"; }

# ── A. THE WRITER, ON KNOWN ANSWERS ─────────────────────────────────────────
# `validate-the-ruler-against-known-inputs`: the arms that matter are the five
# inputs it must refuse, two of which Apple's own parsers accept.
echo "── A. the writer calibrated on known input (and on input it must reject)"
if TK_KIN_DIR="$SP/a" "$TK" --selftest-beat > "$SP/self.log" 2>&1; then
  sed 's/^/  /' "$SP/self.log"
else
  sed 's/^/  /' "$SP/self.log"; say FAIL "the beat writer's own selftest failed"; fail=1
fi

# ── B. AND THE REAL SHAPE, FROM A REAL CALL ─────────────────────────────────
# The beats a call actually produces -- 250-odd keys, nested objects, floats from
# every estimator in the app -- read with a parser that refuses what the RFC
# refuses. A fixture cannot fail the way the real record failed.
echo "── B. a real call's beats, read strictly"
R="bt$$"
TK_KIN_DIR="$SP/b1" "$TK" --window --video off --mute --no-update --no-relocate \
  --no-rings --no-subtitles --room "$R" --listen 7871 --peer 127.0.0.1:7872 \
  --tel-endpoint "http://127.0.0.1:9/beat" > "$SP/b1.log" 2>&1 &
PIDS="$PIDS $!"
TK_KIN_DIR="$SP/b2" "$TK" --window --video off --mute --no-update --no-relocate \
  --no-rings --no-subtitles --room "$R" --listen 7872 --peer 127.0.0.1:7871 \
  --tel-endpoint "http://127.0.0.1:9/beat" > "$SP/b2.log" 2>&1 &
PIDS="$PIDS $!"
# Wait for media, so the beats describe a call and not a launch.
for i in $(seq 1 60); do
  V="$(grep -oE 'recv [0-9]+/s' "$SP/b1.log" | tail -1 | grep -oE '[0-9]+')"
  [ "${V:-0}" -gt 500 ] && break; nap 0.5
done
[ "${V:-0}" -gt 500 ] \
  && say OK "media flowing at ${V}/s, so the beats are about a call" \
  || { echo "  BEAT CHECK COULD NOT RUN -- never got a call (recv ${V:-0}/s)"; exit 2; }
nap 12
kill -9 $PIDS 2>/dev/null; PIDS=""
LOG="$SP/b1/logs/beats.ndjson"
[ -f "$LOG" ] || { echo "  BEAT CHECK COULD NOT RUN -- no beat log at $LOG"; exit 2; }
RES="$(python3 - "$LOG" <<'PY'
import json,sys,collections
tot=bad=0; why=collections.Counter(); keys=0
for ln in open(sys.argv[1],errors='replace'):
    ln=ln.strip()
    if not ln: continue
    tot+=1
    try:
        o=json.loads(ln); keys=max(keys,len(o))
    except Exception as e:
        bad+=1; why[str(e).split(':')[0][:44]]+=1
print(f"{tot} {bad} {keys} " + ("|".join(f"{v}x {k}" for k,v in why.most_common(3)) or "-"))
PY
)"
TOT=$(echo "$RES" | cut -d' ' -f1); BAD=$(echo "$RES" | cut -d' ' -f2)
KEYS=$(echo "$RES" | cut -d' ' -f3); WHY=$(echo "$RES" | cut -d' ' -f4-)
[ "${TOT:-0}" -ge 2 ] \
  && say OK "$TOT beats written" \
  || { say FAIL "only ${TOT:-0} beats -- nothing to judge"; fail=1; }
# THE ASSERTION. Strict, because the tolerant reading of this file was green for
# months while a fifth of it was unreadable.
[ "${BAD:-1}" = "0" ] \
  && say OK "and every one of them is strictly valid JSON (largest $KEYS keys)" \
  || { say FAIL "$BAD of $TOT beats are not valid JSON: $WHY"; fail=1; }
# And the app's own counters agree: a repair or an unreadable beat is REPORTED, so
# the fault is visible on the dashboard without anybody opening this file.
if grep -q "beat_repaired_total\|beat_unreadable_total" "$LOG"; then
  say note "the app repaired at least one beat and says so in the next one:"
  grep -oE '"beat_(repaired|unreadable)_total":[0-9]+' "$LOG" | tail -2 | sed 's/^/         /'
else
  say OK "and none of them needed repairing"
fi
# The other half of fault 2: two Kins wrote to one file above (b1 and b2 have
# their own dirs, so this arm proves the append path, not the collision). The
# collision itself is proved by O_APPEND being on the handle -- asserted here
# because a flag nobody checks is a flag that gets dropped in a refactor.
grep -q "O_APPEND" Sources/tk/Telemetry.swift \
  && say OK "and the writer still opens the log with O_APPEND" \
  || { say FAIL "the beat log handle is no longer O_APPEND -- two Kins will tear it"; fail=1; }

[ "$fail" = 0 ] && echo "BEAT CHECK PASSED -- the app's own record is readable, and says when it is not" \
                || echo "BEAT CHECK FAILED"
exit $fail
