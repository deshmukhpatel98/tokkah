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

# ── A REGISTERED FLAG THAT NOTHING READS IS A NO-OP WITH CONSEQUENCES ────────
#
# `--help` sat in KNOWN_FLAGS for weeks, so the misspelled-flag guard accepted it
# and then nobody read it -- and because tk with no --room falls back to a
# loopback peer, the most common first command anyone types STARTED A CALL and
# opened the microphone. The guard only catches names it does not know; this
# catches names it knows and ignores. Checked at release, not at runtime, because
# the answer is a property of the source.
echo "== flags =="
python3 - <<'EOF'
import re, io, glob, sys
src = "".join(io.open(f, encoding="utf-8").read() for f in glob.glob("Sources/tk/*.swift"))
names = re.findall(r'"([^"]+)"', re.search(r"let KNOWN_FLAGS: Set<String> = \[(.*?)\]", src, re.S).group(1))
seen = set(re.findall(r'(?:arg|flag)\("([^"]+)"\)', src)) | set(re.findall(r'arguments\.contains\("--([^"]+)"\)', src))
dead = [n for n in names if n not in seen]
print("  %d flags registered, all read" % len(names) if not dead
      else "  REGISTERED BUT NEVER READ: %s" % ", ".join(dead))
sys.exit(1 if dead else 0)
EOF

echo "== build =="
swift build -c release
BIN=.build/release/tk
codesign -s - -f "$BIN" 2>/dev/null || echo "  (ad-hoc sign skipped)"
test "$("$BIN" --version)" = "$VER" || { echo "binary reports $("$BIN" --version), expected $VER"; exit 1; }

echo "== icon =="
# Regenerated every release from the Material Symbols path, so the icon in the
# repo can never drift from the source it claims to come from.
swift bundle/mkicon.swift bundle/AppIcon.icns

echo "== package =="
STAGE=$(mktemp -d)
cp "$BIN" "$STAGE/tk"
# ── The archive carries the BUNDLE too ────────────────────────────────────────
#
# It used to be exactly one binary, which meant Contents/ was frozen at install
# time: a machine here had a 0.28.0 Info.plist around a 0.33.0 binary. Anything
# outside the executable -- the icon, the URL scheme, the permission strings --
# could ship and reach nobody who already had the app. The self-updater applies
# these when it finds them, and ignores them when it does not, so an old binary
# updating to a new release is unaffected by their presence.
mkdir -p "$STAGE/bundle"
cp bundle/Info.plist "$STAGE/bundle/Info.plist"
cp bundle/AppIcon.icns "$STAGE/bundle/AppIcon.icns"
TAR="tk-$VER.tar.gz"
tar -czf "/tmp/$TAR" -C "$STAGE" tk bundle
SHA=$(shasum -a 256 "/tmp/$TAR" | awk '{print $1}')
SIZE=$(stat -f%z "/tmp/$TAR")
echo "  $TAR  $SIZE bytes  sha256 $SHA"

# ── Tokkah.app, and a .dmg for people who would rather drag than curl ────────
#
# The TARBALL STAYS EXACTLY ONE BINARY, because that is what every running copy's
# self-updater fetches and expects. The bundle is assembled around that same
# binary -- here for the .dmg, and on the user's own machine by install.sh -- so
# there is one artefact to hash and one thing that can be stale.
echo "== bundle =="
APPDIR=$(mktemp -d)
./bundle/mkapp.sh "$VER" "$BIN" "$APPDIR" >/dev/null
DMG="Tokkah-$VER.dmg"
rm -f "/tmp/$DMG"
STAGE2=$(mktemp -d)
cp -R "$APPDIR/Tokkah.app" "$STAGE2/"
ln -s /Applications "$STAGE2/Applications"
hdiutil create -quiet -volname "Tokkah $VER" -srcfolder "$STAGE2" -ov -format UDZO "/tmp/$DMG"
DMGSHA=$(shasum -a 256 "/tmp/$DMG" | awk '{print $1}')
echo "  $DMG  $(stat -f%z "/tmp/$DMG") bytes"
# The icon travels as a static asset so install.sh can assemble a bundle without a
# second archive to keep in step.
cp bundle/AppIcon.icns "$REPO/tape-app/public/macos/AppIcon.icns"

echo "== upload =="
(cd "$REPO/tape-app" && npx wrangler r2 object put "tokkah-mac/$TAR" --file="/tmp/$TAR" --remote >/dev/null)
(cd "$REPO/tape-app" && npx wrangler r2 object put "tokkah-mac/$DMG" --file="/tmp/$DMG" --remote >/dev/null)
# A stable name as well as the versioned one, because the link a human shares
# should not go stale the next time this runs.
(cd "$REPO/tape-app" && npx wrangler r2 object put "tokkah-mac/Tokkah.dmg" --file="/tmp/$DMG" --remote >/dev/null)

echo "== manifest =="
OUT="$REPO/tape-app/public/macos"
mkdir -p "$OUT"
cat > "$OUT/manifest.json" <<JSON
{"version":"$VER","url":"https://room.tokkah.com/macos/dl/$TAR","sha256":"$SHA","size":$SIZE,"notes":"$NOTES","dmg":"https://room.tokkah.com/macos/dl/$DMG","dmgSha256":"$DMGSHA"}
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
