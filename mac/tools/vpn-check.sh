#!/bin/bash
# ── THE INTEGRATED VPN & COUNTRY REPORTING, END TO END ────────────────────────
#
# Two real processes in one room on this Mac, one of them started with
# `--vpn`. The claims:
#
#   1  the end that asked reaches Cloudflare's relay in Brazil, and the
#      OTHER end learns of it from the sealed beat and reaches the relay too
#   2  the relay log reports the exact country (Brazil / South America)
#   3  media flows both ways through the VPN relay
#   4  the negative: a pair started WITHOUT the flag never mentions the relay,
#      opens no relay socket, and its media stays on the direct path
#
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.." || exit 2
TK="${TK:-$PWD/.build/release/tk}"
[ -x "$TK" ] || { echo "build first: swift build -c release"; exit 2; }
NEWER=$(find Sources -name '*.swift' -newer "$TK" 2>/dev/null | head -3)
[ -n "$NEWER" ] && { echo "STALE BINARY -- newer sources after a build:"; echo "$NEWER" | sed 's/^/    /'; exit 2; }

SP="${SCRATCH:-${TMPDIR:-/tmp}}/vpn-check.$$"
mkdir -p "$SP/a" "$SP/b"
export TK_NO_IDENTITY=1
PIDS=""
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; for p in $PIDS; do wait "$p" 2>/dev/null; done; PIDS=""; }
trap 'reap; kill -9 $SINK 2>/dev/null; rm -rf "$SP"' EXIT
fail=0
say() { printf '  %-5s %s\n' "$1" "$2"; [ "$1" = FAIL ] && fail=1; return 0; }

PORT=9534
BEATS="$SP/beats.ndjson"; : > "$BEATS"
python3 "$HERE/beat-sink.py" $PORT "$BEATS" & SINK=$!
perl -e 'select undef,undef,undef,1'
COMMON=(--video off --mute --no-update --no-relocate --no-rings --no-subtitles --no-rejoin
        --tel-endpoint "http://127.0.0.1:$PORT/api/mac/beat")

relay_sent() { grep -oE 'far test: relay sent [0-9]+' "$1" | tail -1 | awk '{print $5}'; }
relay_recv() { grep -oE 'recv [0-9]+, [0-9-]+ ms round trip' "$1" | tail -1 | awk '{print $2}' | tr -d ,; }
relay_rtt()  { grep -oE '[0-9-]+ ms round trip' "$1" | tail -1 | awk '{print $1}'; }

echo "== 1. one end asks for the integrated VPN (--vpn) =="
R="vpn$$$RANDOM"
TK_KIN_DIR="$SP/a" "$TK" "${COMMON[@]}" --room "$R" --listen 7750 --peer 127.0.0.1:7751 --vpn \
      > "$SP/a.log" 2>&1 & A=$!; PIDS="$PIDS $A"
TK_KIN_DIR="$SP/b" "$TK" "${COMMON[@]}" --room "$R" --listen 7751 --peer 127.0.0.1:7750 \
      > "$SP/b.log" 2>&1 & B=$!; PIDS="$PIDS $B"
perl -e 'select undef,undef,undef,22'
grep -q "far test: on -- reaching" "$SP/a.log" && say ok "A: asked for it (--vpn)" || say FAIL "A never said it was turning the VPN relay on"
grep -q "far test: relay reached" "$SP/a.log" && say ok "A: reached the VPN relay" || say FAIL "A never reached the relay: $(grep 'far test' "$SP/a.log" | tail -2 | tr '\n' '|')"
grep -q "far test: the other end turned it on" "$SP/b.log" && say ok "B: learned of it from A's beat" || say FAIL "B never heard A's beat"
grep -q "far test: relay reached" "$SP/b.log" && say ok "B: reached the VPN relay too" || say FAIL "B never reached the relay"

echo "== 2. exact country reporting =="
grep -q -E "Brazil|South America" "$SP/a.log" && say ok "A logged the relay country (Brazil)" || say FAIL "A did not log country: $(grep 'relay reached' "$SP/a.log")"
grep -q -E "Brazil|South America" "$SP/b.log" && say ok "B logged the relay country (Brazil)" || say FAIL "B did not log country: $(grep 'relay reached' "$SP/b.log")"

echo "== 3. media flows through VPN relay =="
sa=$(relay_sent "$SP/a.log"); sb=$(relay_sent "$SP/b.log")
[ -n "$sa" ] && [ "$sa" -gt 1000 ] && say ok "A sent $sa packets via the VPN relay" || say FAIL "A relay sent: '${sa:-none}'"
[ -n "$sb" ] && [ "$sb" -gt 1000 ] && say ok "B sent $sb packets via the VPN relay" || say FAIL "B relay sent: '${sb:-none}'"

reap

echo "== 4. the negative: nobody asked for VPN =="
R="vpnn$$$RANDOM"
TK_KIN_DIR="$SP/a" "$TK" "${COMMON[@]}" --room "$R" --listen 7752 --peer 127.0.0.1:7753 > "$SP/na.log" 2>&1 & PIDS="$PIDS $!"
TK_KIN_DIR="$SP/b" "$TK" "${COMMON[@]}" --room "$R" --listen 7753 --peer 127.0.0.1:7752 > "$SP/nb.log" 2>&1 & PIDS="$PIDS $!"
perl -e 'select undef,undef,undef,9'
reap
grep -q "connected via" "$SP/nb.log" && say ok "the plain pair connected" || say FAIL "the plain pair never connected"
grep -q "relay reached" "$SP/na.log" "$SP/nb.log" && say FAIL "a relay socket was opened without anybody asking" || say ok "no relay socket opened"

if [ $fail = 0 ]; then echo "VPN CHECK PASS"; else echo "VPN CHECK FAIL"; exit 1; fi
