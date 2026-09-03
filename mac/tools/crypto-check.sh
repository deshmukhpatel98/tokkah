#!/bin/bash
# ── THE SIGNED HANDSHAKE, ON A LIVE SOCKET ──────────────────────────────────
#
# `tk --selftest-crypto` proves the class. This proves the WIRING: two real
# processes, two real identities, one loopback room, and the four things the
# header of Crypto.swift claims about a call:
#
#   1  two honest ends key, read the same safety code, and the beat says so
#      (crypt=1, crypt_v=2, first use: crypt_pinned=0)
#   2  an end that EXPECTS the other's identity (--peer-key) keys and reports
#      crypt_pinned=1 -- the "verified" path a ring or a contact takes
#   3  an end that expects a DIFFERENT identity never keys: no "connected",
#      hs_wrong_id counted, nothing sealed, nothing sent (prekey_drop counted).
#      This is the arm that separates "encrypted" from "authenticated": without
#      it, arms 1 and 2 are equally consistent with a checker that says yes.
#   4  the INSTALLED release -- an unsigned-handshake build, when one is still
#      in /Applications -- is refused by the new build and named as old
#      (hs_old counted, never "connected"). Skipped, and SAID, once the
#      installed copy is itself new.
#
# Distinct identity directories, distinct ports, a private beat sink: LOGIC lane.
set -u
cd "$(dirname "$0")/.." || exit 2
TK="${TK:-$PWD/.build/release/tk}"
[ -x "$TK" ] || { echo "build first: swift build -c release"; exit 2; }
NEWER=$(find Sources -name '*.swift' -newer "$TK" 2>/dev/null | head -3)
[ -n "$NEWER" ] && { echo "STALE BINARY -- newer sources after a build:"; echo "$NEWER" | sed 's/^/    /'; exit 2; }

SP="${SCRATCH:-${TMPDIR:-/tmp}}/crypto-check.$$"
mkdir -p "$SP/a" "$SP/b"
export TK_NO_IDENTITY=1
PIDS=""
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; for p in $PIDS; do wait "$p" 2>/dev/null; done; PIDS=""; }
trap 'reap; kill -9 $SINK 2>/dev/null; rm -rf "$SP"' EXIT
fail=0
say() { printf '  %-5s %s\n' "$1" "$2"; [ "$1" = FAIL ] && fail=1; return 0; }

PORT=9433
BEATS="$SP/beats.ndjson"; : > "$BEATS"
python3 "$(dirname "$0")/beat-sink.py" $PORT "$BEATS" & SINK=$!
perl -e 'select undef,undef,undef,1'
COMMON=(--video off --mute --no-update --no-relocate --no-rings --no-subtitles
        --tel-endpoint "http://127.0.0.1:$PORT/api/mac/beat")

echo "== 0. the class =="
# Its own port: the self-test runs after the socket is bound (top-level order),
# and 7001 is whatever other rig or resident happens to hold it.
if "$TK" --selftest-crypto --no-telemetry --listen $((21000 + RANDOM % 9000)) >/dev/null 2>"$SP/self.log"; then say ok "selftest PASS ($(grep -c '  ok ' "$SP/self.log") arms)"
else say FAIL "selftest: $(grep FAIL "$SP/self.log" | head -3)"; fi

# beats for one call id -> merged fields (last wins), as JSON on stdout
beat_of() {  # $1 = log file (to find the call id), $2 = field
  python3 - "$BEATS" "$1" "$2" <<'PY'
import json, sys, re
beats, log, field = sys.argv[1:]
txt = open(log, errors="replace").read()
m = re.search(r'call ([a-z0-9]+)', txt)          # "telemetry: call <id>" line
cid = m.group(1) if m else None
merged = {}
for line in open(beats):
    try: o = json.loads(line)
    except Exception: continue
    if cid and o.get("call") != cid: continue
    merged.update({k: v for k, v in o.items() if not isinstance(v, dict)})
print(json.dumps(merged.get(field)))
PY
}

run_pair() {  # $1 label  $2.. extra args for B ; A is plain first-use
  local label=$1; shift
  local port=$((7700 + RANDOM % 200 * 2)) R="cc$$$RANDOM"
  : > "$BEATS"
  TK_KIN_DIR="$SP/a" "$TK" "${COMMON[@]}" --room "$R" --listen "$port" --peer "127.0.0.1:$((port+1))" \
        > "$SP/$label.a.log" 2>&1 & PIDS="$PIDS $!"
  # A announces its identity only once somebody arrives, so it cannot be read
  # off A's log before B starts. It does not need to be: A's identity.json lives
  # in $SP/a for the whole run, so the key A said in the PREVIOUS arm is the key
  # it holds in this one. Arm 1 records it; arms 2 and 3 use it.
  local A_ID="${A_ID_SEEN:-}"
  local extra=()
  for x in "$@"; do extra+=("${x//@A_ID@/$A_ID}"); done
  # bash 3.2 + set -u: an EMPTY array is "unbound", and in a background command
  # that error runs the EXIT trap and deletes the scratch under every later arm.
  TK_KIN_DIR="$SP/b" "$TK" "${COMMON[@]}" --room "$R" --listen "$((port+1))" --peer "127.0.0.1:$port" ${extra[@]+"${extra[@]}"} \
        > "$SP/$label.b.log" 2>&1 & PIDS="$PIDS $!"
  perl -e 'select undef,undef,undef,9'
  reap
  local seen; seen=$(grep -oE 'crypto: my identity [A-Za-z0-9+/=]+' "$SP/$label.a.log" | awk '{print $4}' | head -1)
  [ -n "$seen" ] && A_ID_SEEN="$seen"
}
A_ID_SEEN=""

echo "== 1. two honest ends, first use =="
run_pair honest
codeA=$(grep -oE 'code [A-Z2-9]{4} [A-Z2-9]{4}' "$SP/honest.a.log" | head -1)
codeB=$(grep -oE 'code [A-Z2-9]{4} [A-Z2-9]{4}' "$SP/honest.b.log" | head -1)
grep -q "connected via" "$SP/honest.b.log" && say ok "B connected" || say FAIL "B never connected"
grep -q "signed handshake" "$SP/honest.b.log" && say ok "B: $(grep -oE 'encrypted \([^)]*\)' "$SP/honest.b.log" | head -1)" || say FAIL "B never reported the signed handshake"
[ -n "$codeA" ] && [ "$codeA" = "$codeB" ] && say ok "same safety code both ends ($codeA)" || say FAIL "safety codes differ: A '$codeA' B '$codeB'"
grep -q "first use" "$SP/honest.b.log" && say ok "B: first use (no expectation)" || say FAIL "B did not say first use"
[ "$(beat_of "$SP/honest.b.log" crypt)" = 1 ] && say ok "beat crypt=1" || say FAIL "beat crypt=$(beat_of "$SP/honest.b.log" crypt)"
[ "$(beat_of "$SP/honest.b.log" crypt_v)" = 3 ] && say ok "beat crypt_v=3 (x25519 + ml-kem-768)" || say FAIL "beat crypt_v=$(beat_of "$SP/honest.b.log" crypt_v)"
[ "$(beat_of "$SP/honest.b.log" crypt_pinned)" = 0 ] && say ok "beat crypt_pinned=0" || say FAIL "beat crypt_pinned=$(beat_of "$SP/honest.b.log" crypt_pinned)"
[ "$(beat_of "$SP/honest.b.log" plaintext_rx)" = null ] && say ok "nothing arrived in the clear" || say FAIL "plaintext_rx=$(beat_of "$SP/honest.b.log" plaintext_rx)"
[ "$(beat_of "$SP/honest.b.log" replay_drop)" = null ] && say ok "no replay drops on an honest path" || say FAIL "replay_drop=$(beat_of "$SP/honest.b.log" replay_drop) on a clean loopback"

echo "== 2. B expects A's identity =="
[ -n "$A_ID_SEEN" ] && say ok "A's identity from arm 1: ${A_ID_SEEN:0:12}…" || say FAIL "arm 1 never showed A's identity; arm 2 cannot expect it"
run_pair pinned --peer-key @A_ID@
grep -q "connected via" "$SP/pinned.b.log" && say ok "B connected" || say FAIL "B never connected"
grep -q "verified" "$SP/pinned.b.log" && say ok "B: verified" || say FAIL "B did not say verified"
[ "$(beat_of "$SP/pinned.b.log" crypt_pinned)" = 1 ] && say ok "beat crypt_pinned=1" || say FAIL "beat crypt_pinned=$(beat_of "$SP/pinned.b.log" crypt_pinned)"
[ "$(beat_of "$SP/pinned.b.log" crypt_expected)" = 1 ] && say ok "beat crypt_expected=1" || say FAIL "beat crypt_expected=$(beat_of "$SP/pinned.b.log" crypt_expected)"

echo "== 3. B expects SOMEBODY ELSE =="
WRONG=$(head -c 32 /dev/urandom | base64)
run_pair wrong --peer-key "$WRONG"
grep -q "connected via" "$SP/wrong.b.log" && say FAIL "B CONNECTED to an identity it did not expect" || say ok "B never connected"
grep -q "handshake refused (wrong identity)" "$SP/wrong.b.log" && say ok "B refused: wrong identity" || say FAIL "B did not name the refusal"
w=$(beat_of "$SP/wrong.b.log" hs_wrong_id); [ "$w" != null ] && [ "$w" -gt 0 ] && say ok "beat hs_wrong_id=$w" || say FAIL "beat hs_wrong_id=$w"
[ "$(beat_of "$SP/wrong.b.log" crypt)" = 0 ] && say ok "beat crypt=0" || say FAIL "beat crypt=$(beat_of "$SP/wrong.b.log" crypt)"
s=$(beat_of "$SP/wrong.b.log" sealed); [ "$s" = null ] || [ "$s" = 0 ] && say ok "B sealed nothing" || say FAIL "B sealed $s packets to an unverified peer"
p=$(beat_of "$SP/wrong.b.log" prekey_drop); [ "$p" != null ] && [ "$p" -gt 0 ] && say ok "beat prekey_drop=$p (media held back, not sent in the clear)" || say FAIL "prekey_drop=$p"

echo "== 4. the installed release, if it still speaks the unsigned handshake =="
OLD="/Applications/Kin.app/Contents/MacOS/Tokkah"
if [ -x "$OLD" ] && "$OLD" --version 2>/dev/null | grep -qvE "0\.(12[8-9]|1[3-9][0-9]|[2-9][0-9][0-9])\."; then
  port=$((7950 + RANDOM % 20 * 2)); R="cc$$$RANDOM"; : > "$BEATS"
  TK_KIN_DIR="$SP/a" "$OLD" "${COMMON[@]}" --room "$R" --listen "$port" --peer "127.0.0.1:$((port+1))" \
        > "$SP/old.a.log" 2>&1 & PIDS="$PIDS $!"
  perl -e 'select undef,undef,undef,2'
  TK_KIN_DIR="$SP/b" "$TK" "${COMMON[@]}" --room "$R" --listen "$((port+1))" --peer "127.0.0.1:$port" \
        > "$SP/old.b.log" 2>&1 & PIDS="$PIDS $!"
  perl -e 'select undef,undef,undef,9'
  reap
  echo "  installed: $("$OLD" --version 2>/dev/null | head -1)"
  grep -q "connected via" "$SP/old.b.log" && say FAIL "new build CONNECTED to an unsigned handshake" || say ok "new build never connected to the old one"
  o=$(beat_of "$SP/old.b.log" hs_old); [ "$o" != null ] && [ "$o" -gt 0 ] && say ok "beat hs_old=$o (named as an old build)" || say FAIL "beat hs_old=$o"
  grep -q "OLD BUILD" "$SP/old.b.log" && say ok "summary says OLD BUILD" || say FAIL "summary did not name the old build"
else
  echo "  skipped: no installed unsigned-handshake build to test against ($("$OLD" --version 2>/dev/null | head -1))"
fi

[ $fail = 0 ] && echo "CRYPTO CHECK PASS" || { echo "CRYPTO CHECK FAIL (logs in $SP)"; trap - EXIT; reap; kill -9 $SINK 2>/dev/null; exit 1; }
