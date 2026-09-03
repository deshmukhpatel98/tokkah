#!/bin/bash
# ── THE FAR-AWAY TEST, END TO END ────────────────────────────────────────────
#
# Two real processes in one room on this Mac, one of them started with
# `--far-test`. The claims, in the order a person would check them:
#
#   1  the end that asked reaches Cloudflare's relay in South America, and the
#      OTHER end learns of it from the sealed beat and reaches the relay too
#   2  the relay is FAR: its own round trip, measured by the app, is over 220 ms
#      from here (Delhi <-> South America is ~300; an object that landed in
#      Asia or Europe reads 100-150, and the sentence on screen must say so)
#   3  media still flows both ways -- through the relay, which the per-2-second
#      line shows as relay packet counts climbing on both ends
#   4  when the asking end leaves, the other end notices the beat stop and turns
#      the relay off within a few seconds, rather than holding a socket open to
#      South America for a call that no longer wants it
#   5  the negative: a pair started WITHOUT the flag never mentions the far test,
#      opens no relay socket, and its media stays on the direct path
#
# Talks to the live worker (the relay object is Cloudflare's), like the other
# rigs that use a room. Distinct ports, its own beat sink, its own scratch.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.." || exit 2
TK="${TK:-$PWD/.build/release/tk}"
[ -x "$TK" ] || { echo "build first: swift build -c release"; exit 2; }
NEWER=$(find Sources -name '*.swift' -newer "$TK" 2>/dev/null | head -3)
[ -n "$NEWER" ] && { echo "STALE BINARY -- newer sources after a build:"; echo "$NEWER" | sed 's/^/    /'; exit 2; }

SP="${SCRATCH:-${TMPDIR:-/tmp}}/far-test-check.$$"
mkdir -p "$SP/a" "$SP/b"
export TK_NO_IDENTITY=1
PIDS=""
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; for p in $PIDS; do wait "$p" 2>/dev/null; done; PIDS=""; }
trap 'reap; kill -9 $SINK 2>/dev/null; rm -rf "$SP"' EXIT
fail=0
say() { printf '  %-5s %s\n' "$1" "$2"; [ "$1" = FAIL ] && fail=1; return 0; }

PORT=9533
BEATS="$SP/beats.ndjson"; : > "$BEATS"
python3 "$HERE/beat-sink.py" $PORT "$BEATS" & SINK=$!
perl -e 'select undef,undef,undef,1'
COMMON=(--video off --mute --no-update --no-relocate --no-rings --no-subtitles --no-rejoin
        --tel-endpoint "http://127.0.0.1:$PORT/api/mac/beat")

# The last "far test:" relay line of a log: "far test: relay sent N recv N, N ms round trip"
relay_sent() { grep -oE 'far test: relay sent [0-9]+' "$1" | tail -1 | awk '{print $5}'; }
relay_recv() { grep -oE 'recv [0-9]+, [0-9-]+ ms round trip' "$1" | tail -1 | awk '{print $2}' | tr -d ,; }
relay_rtt()  { grep -oE '[0-9-]+ ms round trip' "$1" | tail -1 | awk '{print $1}'; }
recv_rate()  { grep -oE 'recv [0-9]+/s' "$1" | tail -1 | awk '{print $2}' | tr -d /s; }

echo "== 1. one end asks for the far-away test =="
R="ft$$$RANDOM"
TK_KIN_DIR="$SP/a" "$TK" "${COMMON[@]}" --room "$R" --listen 7740 --peer 127.0.0.1:7741 --far-test \
      > "$SP/a.log" 2>&1 & A=$!; PIDS="$PIDS $A"
TK_KIN_DIR="$SP/b" "$TK" "${COMMON[@]}" --room "$R" --listen 7741 --peer 127.0.0.1:7740 \
      > "$SP/b.log" 2>&1 & B=$!; PIDS="$PIDS $B"
# Long enough for two WebSockets to South America, a key, and several 2 s lines.
perl -e 'select undef,undef,undef,22'
grep -q "far test: on -- reaching" "$SP/a.log" && say ok "A: asked for it (--far-test)" || say FAIL "A never said it was turning the far test on"
grep -q "far test: relay reached" "$SP/a.log" && say ok "A: reached the relay" || say FAIL "A never reached the relay: $(grep 'far test' "$SP/a.log" | tail -2 | tr '\n' '|')"
grep -q "far test: the other end turned it on" "$SP/b.log" && say ok "B: learned of it from A's beat" || say FAIL "B never heard A's far-test beat"
grep -q "far test: relay reached" "$SP/b.log" && say ok "B: reached the relay too" || say FAIL "B never reached the relay: $(grep 'far test' "$SP/b.log" | tail -2 | tr '\n' '|')"
grep -q "connected via" "$SP/b.log" && say ok "the call keyed and connected underneath it" || say FAIL "B never connected"

echo "== 2. the relay is far =="
ra=$(relay_rtt "$SP/a.log"); rb=$(relay_rtt "$SP/b.log")
[ -n "$ra" ] && [ "$ra" -gt 220 ] && say ok "A measured the relay at $ra ms round trip (over 220)" || say FAIL "A's relay round trip: '${ra:-none}' ms -- not South America from here"
[ -n "$rb" ] && [ "$rb" -gt 220 ] && say ok "B measured the relay at $rb ms round trip" || say FAIL "B's relay round trip: '${rb:-none}' ms"

echo "== 3. media flows through it, both ways =="
sa=$(relay_sent "$SP/a.log"); sb=$(relay_sent "$SP/b.log"); ca=$(relay_recv "$SP/a.log"); cb=$(relay_recv "$SP/b.log")
[ -n "$sa" ] && [ "$sa" -gt 1000 ] && say ok "A sent $sa packets via the relay" || say FAIL "A relay sent: '${sa:-none}'"
[ -n "$sb" ] && [ "$sb" -gt 1000 ] && say ok "B sent $sb packets via the relay" || say FAIL "B relay sent: '${sb:-none}'"
[ -n "$ca" ] && [ "$ca" -gt 1000 ] && say ok "A received $ca via the relay" || say FAIL "A relay recv: '${ca:-none}'"
[ -n "$cb" ] && [ "$cb" -gt 1000 ] && say ok "B received $cb via the relay" || say FAIL "B relay recv: '${cb:-none}'"
rr=$(recv_rate "$SP/b.log"); [ -n "$rr" ] && [ "$rr" -gt 500 ] && say ok "B's audio still arrives ($rr packets/s) with a 300 ms detour in it" || say FAIL "B recv rate '${rr:-none}'/s"
grep -q "moving to theirs" "$SP/a.log" "$SP/b.log" && say FAIL "an end adopted the relay's loopback address as the peer" || say ok "neither end mistook the relay's loopback packets for a moved peer"
grep -q "nothing from .* for 3 s" "$SP/a.log" "$SP/b.log" && say FAIL "the 3 s silence detector fired on a call whose media all arrived via the relay" || say ok "no false silence alarms"

echo "== 4. the asking end leaves; the other end lets go =="
kill -9 "$A" 2>/dev/null; wait "$A" 2>/dev/null; PIDS="$B"
perl -e 'select undef,undef,undef,9'
grep -q "far test: the other end's beat stopped" "$SP/b.log" && say ok "B: noticed the beat stop" || say FAIL "B kept the far test on after A died"
grep -q "far test: off -- back on the direct path" "$SP/b.log" && say ok "B: relay closed, direct path" || say FAIL "B never turned the relay off"
reap

echo "== 5. the negative: nobody asked =="
R="fn$$$RANDOM"
TK_KIN_DIR="$SP/a" "$TK" "${COMMON[@]}" --room "$R" --listen 7742 --peer 127.0.0.1:7743 > "$SP/na.log" 2>&1 & PIDS="$PIDS $!"
TK_KIN_DIR="$SP/b" "$TK" "${COMMON[@]}" --room "$R" --listen 7743 --peer 127.0.0.1:7742 > "$SP/nb.log" 2>&1 & PIDS="$PIDS $!"
perl -e 'select undef,undef,undef,9'
reap
grep -q "connected via" "$SP/nb.log" && say ok "the plain pair connected" || say FAIL "the plain pair never connected"
grep -q "far test" "$SP/na.log" "$SP/nb.log" && say FAIL "a pair that never asked mentioned the far test: $(grep -h 'far test' "$SP/na.log" "$SP/nb.log" | head -1)" || say ok "no far-test line without the flag"
grep -q "relay reached" "$SP/na.log" "$SP/nb.log" && say FAIL "a relay socket was opened without anybody asking" || say ok "no relay socket opened"

if [ $fail = 0 ]; then echo "FAR-TEST CHECK PASS"; else echo "FAR-TEST CHECK FAIL"; exit 1; fi
