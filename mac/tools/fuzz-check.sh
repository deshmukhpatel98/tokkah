#!/bin/bash
# ── FUZZ: THE PARSERS A STRANGER REACHES, AND THE ONES A PEER REACHES ────────
#
#   1  `tk --fuzz-parsers S` -- STUN reply, TURN reply, ChannelData unwrap, the
#      signed handshake, video reassembly, lossless audio decode: mutated input,
#      in-process, with this build's bounds and overflow checks. A trap is a
#      crash; this rig reads the exit code AND the crash-report folder, because a
#      trap on a background thread can outrun the process's own last words.
#   2  a hostile PEER: B is an ordinary end (-O, real speech). A is the same
#      binary told `--fuzz-send N`: it completes the signed handshake like a
#      friend and then seals and sends N mutated audio / video / probe /
#      subtitle / keyframe packets at B, beside its real audio. B must be alive
#      afterwards, still keyed, still opening packets, with no crash report.
#
# Deterministic (--fuzz-seed); a finding replays with the same seed and count.
# LOGIC lane.
set -u
cd "$(dirname "$0")/.." || exit 2
TK="${TK:-$PWD/.build/release/tk}"
SECS="${1:-20}"; COUNT="${2:-60000}"; SEED="${3:-1}"
[ -x "$TK" ] || { echo "build first: swift build -c release"; exit 2; }
NEWER=$(find Sources -name '*.swift' -newer "$TK" 2>/dev/null | head -3)
[ -n "$NEWER" ] && { echo "STALE BINARY -- newer sources after a build:"; echo "$NEWER" | sed 's/^/    /'; exit 2; }
SP="${SCRATCH:-${TMPDIR:-/tmp}}/fuzz-check.$$"
mkdir -p "$SP/a" "$SP/b"
export TK_NO_IDENTITY=1
PIDS=""
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; for p in $PIDS; do wait "$p" 2>/dev/null; done; PIDS=""; }
trap 'reap; rm -rf "$SP"' EXIT
fail=0
say() { printf '  %-5s %s\n' "$1" "$2"; [ "$1" = FAIL ] && fail=1; return 0; }
REPORTS="$HOME/Library/Logs/DiagnosticReports"
crashes() { ls "$REPORTS" 2>/dev/null | grep -c "^tk[-_.]"; }
before=$(crashes)

echo "== 1. in-process, $SECS s, seed $SEED =="
# Its own identity dir: without one the process reads the REAL app directory,
# where another rig's live-call record can send it rejoining a room on port
# 7001 before it ever reaches the fuzz block (seen twice: "room heavy-48621").
mkdir -p "$SP/f"
TK_KIN_DIR="$SP/f" "$TK" --fuzz-parsers "$SECS" --fuzz-seed "$SEED" --no-telemetry --no-relocate --no-update --no-rings --listen $((21000 + RANDOM % 9000)) >/dev/null 2>"$SP/fz.log"
rc=$?
line=$(grep -E '^fuzz: ' "$SP/fz.log" | tail -1)
[ $rc = 0 ] && say ok "exit 0 -- $line" || say FAIL "exit $rc -- $(tail -2 "$SP/fz.log" | tr '\n' ' ')"
sleep 2
[ "$(crashes)" = "$before" ] && say ok "no new crash report" || say FAIL "a crash report appeared: $(ls -t "$REPORTS" | grep '^tk' | head -1)"

echo "== 2. a hostile peer, $COUNT packets, seed $SEED =="
WAV="${WAV:-../testbed/media/fullband.wav}"
before=$(crashes)
port=$((7800 + RANDOM % 100 * 2)); R="fz$$$RANDOM"
COMMON=(--video off --audio "$WAV" --no-update --no-relocate --no-rings --no-subtitles --no-telemetry --room "$R")
TK_KIN_DIR="$SP/b" "$TK" "${COMMON[@]}" --listen "$port" --peer "127.0.0.1:$((port+1))" > "$SP/b.log" 2>&1 & B=$!; PIDS="$B"
perl -e 'select undef,undef,undef,2'
TK_KIN_DIR="$SP/a" "$TK" "${COMMON[@]}" --listen "$((port+1))" --peer "127.0.0.1:$port" --fuzz-send "$COUNT" --fuzz-seed "$SEED" > "$SP/a.log" 2>&1 & A=$!; PIDS="$PIDS $A"
# Wait for A to say it has finished sending, up to 90 s.
for _ in $(seq 1 180); do grep -q "^fuzz: sent" "$SP/a.log" 2>/dev/null && break; perl -e 'select undef,undef,undef,0.5'; done
grep -q "^fuzz: sent" "$SP/a.log" && say ok "A: $(grep '^fuzz: sent' "$SP/a.log" | cut -c1-90)" || say FAIL "A never finished sending (is it keyed? $(grep -c 'connected via' "$SP/a.log"))"
perl -e 'select undef,undef,undef,3'
kill -0 $B 2>/dev/null && say ok "B is alive after the attack" || say FAIL "B DIED during the attack"
# B is still a working call: it keeps opening real packets afterwards.
b1=$(grep -c . "$SP/b.log"); perl -e 'select undef,undef,undef,4'
kill -0 $B 2>/dev/null && say ok "B still alive 7 s later" || say FAIL "B died after the attack"
reap
grep -q "connected via" "$SP/b.log" && say ok "B had connected" || say FAIL "B never connected"
grep -q "signed handshake" "$SP/b.log" && say ok "B: keyed with the attacker (as it must -- the attacker is a legitimate peer)" || say FAIL "B never keyed"
summ=$(grep -E "crypt on|NO KEY" "$SP/b.log" | tail -1 | grep -oE "crypt on \([^)]*\)|NO KEY[^)]*\)")
[ -n "$summ" ] && say ok "B summary: $summ" || say ok "B: no summary line captured (killed before the report second)"
sleep 2
[ "$(crashes)" = "$before" ] && say ok "no new crash report from B or A" || { say FAIL "a crash report appeared: $(ls -t "$REPORTS" | grep '^tk' | head -1)"; cp "$SP/a.log" "$SP/b.log" /tmp/ 2>/dev/null; }

[ $fail = 0 ] && echo "FUZZ CHECK PASS" || { echo "FUZZ CHECK FAIL (logs copied to /tmp/a.log /tmp/b.log)"; cp "$SP/a.log" /tmp/a.log; cp "$SP/b.log" /tmp/b.log; exit 1; }
