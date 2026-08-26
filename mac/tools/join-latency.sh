#!/bin/bash
# Where do the seconds before "connected" go?
#
# This is the callee's shape. When somebody answers a ring the app re-execs, and
# the successor joins a room the caller is already sitting in -- so: one end
# waiting, a second end starting cold. Split by role in the field that end is
# p50 2482 ms, which is the reported "there is a lag of 2-3 seconds in
# connecting the call".
#
#   bash mac/tools/join-latency.sh [runs]
#
# Both ends local, both `--mute`, no identity, no login item, no camera, so the
# absolute number is a FLOOR and not a call -- a real one pays a real network
# and a camera as well. What it gives honestly is the BREAKDOWN, which is the
# thing that was missing: `connected_ms` was the only mark on the whole path, so
# a 2.5 s total had no parts and every theory about it was a guess.
#
# It exists because one of those guesses was mine and it was wrong twice over.
# The 20 s TURN barrier above the media loop looked like the cause: measured,
# `turn_blocked_ms` is 6 ms. Then a faster poll looked like a 482 ms win: it was
# the app announcing "connected" on a tick-counted timeout without ever hearing
# the far end, which is why that deadline is now expressed in seconds.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

RUNS="${1:-3}"
TK="$PWD/.build/release/tk"

echo "== building the binary under test =="
if ! swift build -c release --product tk >/dev/null 2>&1; then
  echo "BUILD FAILED"; swift build -c release --product tk 2>&1 | grep -E "error:" | head -5; exit 2
fi
NEWER=$(find Sources -name '*.swift' -newer "$TK" 2>/dev/null | head -3)
if [ -n "$NEWER" ]; then
  echo "STALE BINARY -- newer sources after a build:"; echo "$NEWER" | sed 's/^/    /'; exit 2
fi
echo "  $TK is current with Sources/"

SP="${SCRATCH:-${TMPDIR:-/tmp}}/join-lat.$$"
mkdir -p "$SP/kin"
export TK_NO_IDENTITY=1
export TK_KIN_DIR="$SP/kin"
PIDS=""
# Recorded pids only, and never a bare `wait`: one of this script's children is
# the telemetry sink, which never exits, and `wait` with no argument waits for
# it too -- two ten-minute timeouts came out of exactly that.
reap() {
  for p in $PIDS; do kill -9 "$p" 2>/dev/null; done
  for p in $PIDS; do wait "$p" 2>/dev/null; done
  PIDS=""
}
trap 'reap; kill -9 $SINK 2>/dev/null; rm -rf "$SP"' EXIT

BEATS="$SP/beats.ndjson"; : > "$BEATS"
python3 "$(dirname "$0")/beat-sink.py" 9421 "$BEATS" & SINK=$!
perl -e 'select undef,undef,undef,1'

COMMON=(--video off --mute --no-update --no-relocate --no-rings --no-subtitles
        --tel-endpoint "http://127.0.0.1:9421/api/mac/beat")

port=7600
for i in $(seq 1 "$RUNS"); do
  R="jl$$$port"
  "$TK" "${COMMON[@]}" --room "$R" --listen "$port" --peer "127.0.0.1:$((port+1))" \
        > "$SP/a.$i.log" 2>&1 & PIDS="$PIDS $!"
  perl -e 'select undef,undef,undef,5'          # A is published and waiting
  "$TK" "${COMMON[@]}" --room "$R" --listen "$((port+1))" --peer "127.0.0.1:$port" \
        > "$SP/b.$i.log" 2>&1 & PIDS="$PIDS $!"
  perl -e 'select undef,undef,undef,11'
  reap
  ms=$(grep -oE 'connected via .* at [0-9]+ ms' "$SP/b.$i.log" | tail -1 \
       | grep -oE '[0-9]+ ms$' | awk '{print $1}')
  printf '  run %d  joiner connected at %s ms\n' "$i" "${ms:-?}"
  port=$((port+4))
done

# The phases come from the beats the joiner posted, not from the log, because
# the marks are the thing being validated and reading them anywhere else would
# test a different code path than the one the dashboard shows.
python3 - "$BEATS" <<'PY'
import json, sys, statistics as st
best = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if not line: continue
    try: o = json.loads(line)
    except Exception: continue
    m = o.get("marks") or {}
    if m:
        c = o.get("call", "?")
        best[c] = {**best.get(c, {}), **m}
# The JOINER is the one whose peer was already there: its peer_found is early.
# The waiter's is whenever the second end turned up, which is the rig's own
# 5-second pause and not a property of anything.
joiners = [m for m in best.values()
           if isinstance(m.get("peer_found_ms"), (int, float)) and m["peer_found_ms"] < 3000]
if not joiners:
    print("\n  NO JOINER BEATS -- the marks did not arrive"); sys.exit(1)
PHASES = [("stun_ms", "STUN answers"), ("turn_ms", "TURN allocated"),
          ("peer_found_ms", "peer found in the room"),
          ("turn_blocked_ms", "connect blocked on TURN"),
          ("connected_ms", "said connected")]
print(f"\n  {len(joiners)} joiner(s), median of each phase:\n")
prev = 0
for k, label in PHASES:
    v = [m[k] for m in joiners if isinstance(m.get(k), (int, float))]
    if not v: continue
    med = st.median(v)
    if k == "turn_blocked_ms":
        print(f"    {label:26} {med:7.0f} ms   (a duration, not a stamp)")
    else:
        print(f"    {label:26} {med:7.0f} ms   (+{med - prev:5.0f} since the line above)")
        prev = med
polls = [m.get("join_polls") for m in joiners if isinstance(m.get("join_polls"), (int, float))]
if polls: print(f"\n    rendezvous polls to find the peer: {st.median(polls):.0f}")
PY
echo
echo "JOIN LATENCY DONE"
