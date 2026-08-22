#!/bin/bash
# Cut a release of the native macOS app.
#
#   ./release.sh 0.2.0 "what changed"
#
# Builds release-optimised, ad-hoc signs (free -- no Apple Developer ID), tars,
# hashes, uploads the tarball to R2, writes a SIGNED manifest into the worker's
# static assets, and deploys. Every running copy picks it up within 60 s.
#
# Ad-hoc signing rather than notarised: files fetched with curl are never
# quarantined, so an install and an update over curl never meet Gatekeeper. The
# Ed25519 signature on the manifest is what actually protects the update path,
# and that is ours, not Apple's.
set -euo pipefail
cd "$(dirname "$0")"
VER="${1:?usage: release.sh <version> [notes]}"
NOTES="${2:-}"
REPO="$(cd .. && pwd)"
[ -f "$HOME/.config/tokkah/cf.env" ] && . "$HOME/.config/tokkah/cf.env"

# The version in the source is the authority; a manifest that advertises a
# version the binary does not report would make every client update forever.
SRCVER=$(grep -o 'let VERSION = "[^"]*"' Sources/tk/main.swift | sed 's/.*"\(.*\)"/\1/')
if [ "$SRCVER" != "$VER" ]; then
  echo "bumping Sources/tk/main.swift: $SRCVER -> $VER"
  sed -i '' "s/let VERSION = \"$SRCVER\"/let VERSION = \"$VER\"/" Sources/tk/main.swift
fi

echo "== build =="
swift build -c release
BIN=.build/release/tk
codesign -s - -f "$BIN" 2>/dev/null || echo "  (ad-hoc sign skipped)"
test "$("$BIN" --version)" = "$VER" || { echo "binary reports $("$BIN" --version), expected $VER"; exit 1; }

echo "== package =="
STAGE=$(mktemp -d)
cp "$BIN" "$STAGE/tk"
TAR="tk-$VER.tar.gz"
tar -czf "/tmp/$TAR" -C "$STAGE" tk
SHA=$(shasum -a 256 "/tmp/$TAR" | awk '{print $1}')
SIZE=$(stat -f%z "/tmp/$TAR")
echo "  $TAR  $SIZE bytes  sha256 $SHA"

echo "== upload =="
(cd "$REPO/tape-app" && npx wrangler r2 object put "tokkah-mac/$TAR" --file="/tmp/$TAR" --remote >/dev/null)

echo "== manifest =="
OUT="$REPO/tape-app/public/macos"
mkdir -p "$OUT"
cat > "$OUT/manifest.json" <<JSON
{"version":"$VER","url":"https://room.tokkah.com/macos/dl/$TAR","sha256":"$SHA","size":$SIZE,"notes":"$NOTES"}
JSON
./tools/sign "$OUT/manifest.json" > "$OUT/manifest.json.sig"
echo "  signed ($(wc -c < "$OUT/manifest.json.sig" | tr -d ' ') bytes)"

echo "== deploy =="
(cd "$REPO/tape-app" && npx wrangler deploy -c wrangler.prod.jsonc | tail -3)

echo "== verify from the outside =="
sleep 3
curl -fsS https://room.tokkah.com/macos/manifest.json && echo
curl -fsSI "https://room.tokkah.com/macos/dl/$TAR" | grep -iE '^(HTTP|content-length)' || true
echo "released $VER"
