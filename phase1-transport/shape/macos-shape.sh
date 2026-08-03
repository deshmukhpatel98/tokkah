#!/usr/bin/env bash
#
# Inject RTT and packet loss on UDP traffic to a specific host, so the harness
# can be run across the DESIGN.md §19 matrix (20/80/150 ms RTT × 0/1/3% loss).
#
#   sudo ./macos-shape.sh <host-or-ip> <rtt-ms> <loss-pct>
#   sudo ./macos-unshape.sh
#
# Examples
#   sudo ./macos-shape.sh turn.cloudflare.com 80 1     # relay-mode tests
#   sudo ./macos-shape.sh 203.0.113.44 150 3           # P2P, peer's public IP
#
# Notes
#   · dummynet delay is ONE WAY per pipe, so we halve the requested RTT and put
#     the same delay on each direction. Requesting 80 gives 40+40.
#   · Loss is applied independently in each direction, so the requested figure
#     is per-direction, matching how loss is usually quoted.
#   · This rewrites the pf ruleset from /etc/pf.conf plus our anchors. It does
#     NOT blow away the system ruleset, but if you use Internet Sharing or a VPN
#     that installs pf rules, check them afterwards.
#   · If pfctl/dnctl are unavailable on your macOS build, use Xcode's Network
#     Link Conditioner instead (Additional Tools for Xcode → Hardware). It is
#     less precise and interface-wide rather than per-host, but it always works.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "must run as root: sudo $0 $*" >&2
  exit 1
fi

HOST="${1:?usage: $0 <host-or-ip> <rtt-ms> <loss-pct>}"
RTT="${2:?usage: $0 <host-or-ip> <rtt-ms> <loss-pct>}"
LOSS="${3:?usage: $0 <host-or-ip> <rtt-ms> <loss-pct>}"

# Resolve to every A record — turn.cloudflare.com is anycast but may return more
# than one address, and missing one silently leaves traffic unshaped.
IPS=$(dscacheutil -q host -a name "$HOST" 2>/dev/null | awk '/^ip_address:/{print $2}' | sort -u)
if [[ -z "$IPS" ]]; then
  if [[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IPS="$HOST"
  else
    echo "could not resolve $HOST" >&2
    exit 1
  fi
fi

ONE_WAY=$(echo "scale=0; $RTT / 2" | bc)
PLR=$(echo "scale=6; $LOSS / 100" | bc)

echo "shaping UDP to/from:"
echo "$IPS" | sed 's/^/  /'
echo "  one-way delay ${ONE_WAY} ms (RTT ${RTT} ms), loss ${LOSS}% each direction"

dnctl -q flush || true
dnctl pipe 1 config delay "$ONE_WAY" plr "$PLR"
dnctl pipe 2 config delay "$ONE_WAY" plr "$PLR"

RULES=$(mktemp /tmp/tape-rules.XXXXXX)
for ip in $IPS; do
  echo "dummynet out proto udp from any to $ip pipe 1"
  echo "dummynet in  proto udp from $ip to any pipe 2"
done > "$RULES"

BASE=$(mktemp /tmp/tape-pf.XXXXXX)
cat /etc/pf.conf > "$BASE"
{
  echo 'dummynet-anchor "tape"'
  echo 'anchor "tape"'
} >> "$BASE"

pfctl -q -f "$BASE"
pfctl -q -a tape -f "$RULES"
pfctl -E 2>/dev/null || pfctl -e 2>/dev/null || true

rm -f "$RULES" "$BASE"

echo
echo "active. verify with:  sudo pfctl -a tape -s rules ; sudo dnctl list"
echo "remove with:          sudo $(dirname "$0")/macos-unshape.sh"
