#!/bin/bash
# ── THE RELAY CLIENT, HELD TO THE WIRE ───────────────────────────────────────
#
# `tk --selftest-turn` builds the relay's messages and reads them back the way
# the server does: CHANNEL-NUMBER is 0x000C and four bytes, the channel is in
# 0x4000...0x4FFF, a Data Indication unwraps to its payload and names its peer,
# a Send Indication carries both, a release is a Refresh with LIFETIME 0, 437
# and 438 parse to themselves, and the lease file round-trips. Two arms are
# negatives: the 0.161 encoding (0x001C) must read as "no channel number", and
# bytes from an address that is not our relay must be refused.
#
# No socket, no network: LOGIC lane. release.sh gates on the same flag.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.." || exit 2
TK="${TK:-$PWD/.build/release/tk}"
[ -x "$TK" ] || { echo "build first: swift build -c release"; exit 2; }
NEWER=$(find Sources -name '*.swift' -newer "$TK" 2>/dev/null | head -3)
[ -n "$NEWER" ] && { echo "STALE BINARY -- newer sources after a build:"; echo "$NEWER" | sed 's/^/    /'; exit 2; }
LOG="${TMPDIR:-/tmp}/turn-check.$$.log"
if "$TK" --selftest-turn --no-telemetry >/dev/null 2>"$LOG"; then
  echo "  ok    selftest PASS ($(grep -c '  ok ' "$LOG") arms)"
  rm -f "$LOG"; exit 0
else
  echo "  FAIL  selftest:"; grep -e FAIL -e error "$LOG" | head -6 | sed 's/^/    /'
  rm -f "$LOG"; exit 1
fi
