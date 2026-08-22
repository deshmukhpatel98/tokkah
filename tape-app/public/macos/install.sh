#!/bin/sh
# Install tk, the native macOS half of Tokkah.
#
#   curl -fsSL https://room.tokkah.com/macos/install.sh | sh
#
# WHY curl AND NOT A .dmg: macOS attaches a "quarantine" attribute to files
# downloaded by browsers, and Gatekeeper then refuses to run anything that is not
# notarised by Apple. Files fetched with curl are never quarantined, so this path
# has no security dialog to click through and needs no Apple Developer ID.
#
# The download is checked against the sha256 in the signed manifest. After that,
# tk updates itself and verifies an Ed25519 signature on every update it applies.
set -eu
BASE="https://room.tokkah.com/macos"
DEST="${TK_DEST:-$HOME/.local/bin}"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) : ;;
  Darwin-x86_64) echo "Intel Macs are not built yet -- ask and it will be added." >&2; exit 1 ;;
  *) echo "tk is macOS only (this is $(uname -s)-$(uname -m))." >&2; exit 1 ;;
esac

MAN=$(curl -fsSL "$BASE/manifest.json")
VER=$(printf '%s' "$MAN" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
URL=$(printf '%s' "$MAN" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
WANT=$(printf '%s' "$MAN" | sed -n 's/.*"sha256":"\([^"]*\)".*/\1/p')
[ -n "$VER" ] && [ -n "$URL" ] && [ -n "$WANT" ] || { echo "manifest at $BASE looks wrong" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "downloading tk $VER"
curl -fsSL "$URL" -o "$TMP/tk.tar.gz"
GOT=$(shasum -a 256 "$TMP/tk.tar.gz" | awk '{print $1}')
[ "$GOT" = "$WANT" ] || { echo "checksum mismatch: expected $WANT, got $GOT" >&2; exit 1; }

tar -xzf "$TMP/tk.tar.gz" -C "$TMP"
mkdir -p "$DEST"
mv "$TMP/tk" "$DEST/tk"
chmod +x "$DEST/tk"

echo "installed $DEST/tk ($("$DEST/tk" --version))"
case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo ""; echo "add it to your PATH:"; echo "  echo 'export PATH=\"$DEST:\$PATH\"' >> ~/.zshrc && exec zsh" ;;
esac
echo ""
echo "to make a call, on each Mac:"
echo "  tk --listen 7001 --peer <the-other-mac-ip>:7001"
echo ""
echo "it keeps itself up to date, and will ask for microphone permission the first time."
