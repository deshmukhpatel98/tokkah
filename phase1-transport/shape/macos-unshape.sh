#!/usr/bin/env bash
# Remove everything macos-shape.sh installed.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "must run as root: sudo $0" >&2
  exit 1
fi

pfctl -q -a tape -F all 2>/dev/null || true
dnctl -q flush 2>/dev/null || true
pfctl -q -f /etc/pf.conf 2>/dev/null || true
pfctl -d 2>/dev/null || true

echo "shaping removed; pf restored to /etc/pf.conf and disabled."
echo "verify: sudo dnctl list   (should be empty)"
