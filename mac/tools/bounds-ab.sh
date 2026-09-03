#!/bin/bash
# ── BOUNDS CHECKS ON vs OFF, measured on a live loopback call ────────────────
#
# The Mac binary was built -Ounchecked since the first commit: no array bounds
# checks, no integer overflow traps. Inside the encryption that costs nothing in
# safety (only the authenticated peer feeds those parsers). The STUN and TURN
# parsers run BEFORE any authentication on bytes from anyone on the internet,
# and there an out-of-bounds read is memory corruption rather than a crash.
#
# So: what does -O cost? Two binaries, same sources, real speech both ways, four
# arms interleaved (U O U O) plus a null pair (U U) so the rig's own noise is
# known before any delta is believed. Read from the beats: m2e p50/p99, slack
# p01, CPU seconds per second, concealment.
#
#   tools/bounds-ab.sh <tk-unchecked> <tk-checked> [secs]
#
# TIME lane: runs alone.
set -u
cd "$(dirname "$0")/.." || exit 2
U="${1:?tk built -Ounchecked}"; O="${2:?tk built -O}"; SECS="${3:-30}"
WAV="${WAV:-../testbed/media/fullband.wav}"
[ -f "$WAV" ] || { echo "no speech at $WAV"; exit 2; }
SP="${SCRATCH:-${TMPDIR:-/tmp}}/bounds-ab.$$"
mkdir -p "$SP/a" "$SP/b"
export TK_NO_IDENTITY=1
PIDS=""
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; for p in $PIDS; do wait "$p" 2>/dev/null; done; PIDS=""; }
trap 'reap; kill -9 $SINK 2>/dev/null; rm -rf "$SP"' EXIT
PORT=9437
BEATS="$SP/beats.ndjson"; : > "$BEATS"
python3 "$(dirname "$0")/beat-sink.py" $PORT "$BEATS" & SINK=$!
perl -e 'select undef,undef,undef,1'
COMMON=(--video off --audio "$WAV" --no-update --no-relocate --no-rings --no-subtitles
        --tel-endpoint "http://127.0.0.1:$PORT/api/mac/beat")

arm() {  # $1 label $2 binary
  local label=$1 bin=$2 port=$((7500 + RANDOM % 200 * 2)) R="ab$$$RANDOM"
  : > "$BEATS"
  TK_KIN_DIR="$SP/a" "$bin" "${COMMON[@]}" --room "$R" --listen "$port" --peer "127.0.0.1:$((port+1))" > "$SP/$label.a.log" 2>&1 & PIDS="$PIDS $!"
  perl -e 'select undef,undef,undef,2'
  TK_KIN_DIR="$SP/b" "$bin" "${COMMON[@]}" --room "$R" --listen "$((port+1))" --peer "127.0.0.1:$port" > "$SP/$label.b.log" 2>&1 & PIDS="$PIDS $!"
  perl -e "select undef,undef,undef,$SECS"
  reap
  python3 - "$BEATS" "$label" <<'PY'
import json, sys, statistics as st
beats, label = sys.argv[1:]
rows = {}
for line in open(beats):
    try: o = json.loads(line)
    except Exception: continue
    if o.get("phase") not in ("live", None): continue
    rows.setdefault(o.get("call"), []).append(o)
def last(k, cid):
    v = [r[k] for r in rows[cid] if isinstance(r.get(k), (int, float))]
    return v[-1] if v else None
def med(k):
    v = [last(k, c) for c in rows]; v = [x for x in v if x is not None]
    return st.median(v) if v else float("nan")
print(f"  {label:4} m2e p50 {med('m2e_p50'):6.2f}  p99 {med('m2e_p99'):6.2f}  slack p01 {med('slack_p01'):6.2f}  cpu {med('cpu'):5.3f} s/s  crypt {med('crypt'):.0f}")
PY
}

echo "== null pair (same binary twice) =="
arm U1 "$U"; arm U2 "$U"
echo "== interleaved =="
arm O1 "$O"; arm U3 "$U"; arm O2 "$O"; arm U4 "$U"
echo
echo "Read it as: if O differs from U by less than U1 differs from U2, the flag costs nothing the rig can see."
