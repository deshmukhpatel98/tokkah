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
# This used to print the manifest and then say "released" regardless of what came
# back. It printed a STALE 0.6.0 manifest immediately after shipping 0.7.0 and
# still reported success -- so a genuinely failed deploy would have passed too.
# A verification that cannot fail is decoration. Now it polls until the edge
# agrees, checks the tarball is actually fetchable and hashes to what the
# manifest promises, and exits non-zero if any of that is untrue.
ok=""
for i in $(seq 1 20); do
  got="$(curl -fsS "https://room.tokkah.com/macos/manifest.json?cb=$$-$i" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null || true)"
  if [ "$got" = "$VER" ]; then ok=1; break; fi
  printf '  edge still on %s, waiting (%s/20)\n' "${got:-?}" "$i"
  sleep 3
done
[ -n "$ok" ] || { echo "FAILED: edge never served $VER"; exit 1; }

# The updater will fetch this exact URL and check this exact hash. If either is
# wrong, every running copy refuses the update -- so verify it the way the
# updater will, not the way that is convenient.
want="$(python3 -c 'import json;print(json.load(open("../tape-app/public/macos/manifest.json"))["sha256"])')"
tmp="$(mktemp)"
curl -fsS "https://room.tokkah.com/macos/dl/$TAR" -o "$tmp" || { echo "FAILED: tarball not fetchable"; exit 1; }
have="$(shasum -a 256 "$tmp" | awk '{print $1}')"
rm -f "$tmp"
[ "$want" = "$have" ] || { echo "FAILED: served tarball hashes $have, manifest promises $want"; exit 1; }
echo "  manifest $VER, tarball fetched and hash matches"
echo "released $VER"
