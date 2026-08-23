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

# ── Tokkah.app, so this is something you can hand to another person ──────────
#
# The bundle is assembled HERE rather than downloaded, so there is still exactly
# one archive in the world and it cannot fall out of step with the binary the
# self-updater fetches.
#
# It matters for more than the icon: a bare command-line binary has no code
# identity of its own, so macOS attributes its microphone and camera grants to
# whichever terminal launched it -- they cannot be reviewed in System Settings and
# they do not follow the program. A bundle owns its permissions.
APPS="/Applications"
[ -w "$APPS" ] || APPS="$HOME/Applications"
mkdir -p "$APPS"
APP="$APPS/Tokkah.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DEST/tk" "$APP/Contents/MacOS/Tokkah"
chmod +x "$APP/Contents/MacOS/Tokkah"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tokkah</string>
  <key>CFBundleDisplayName</key><string>Tokkah</string>
  <key>CFBundleIdentifier</key><string>com.tokkah.tk</string>
  <key>CFBundleExecutable</key><string>Tokkah</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundleVersion</key><string>$VER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Tokkah needs the microphone to carry your voice on a call.</string>
  <key>NSCameraUsageDescription</key>
  <string>Tokkah needs the camera to send your picture on a call.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Tokkah connects directly to the other person, including over your local network, so audio and video do not travel through a server.</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
# Best-effort: a missing icon is a generic app tile, not a broken install.
curl -fsSL "$BASE/AppIcon.icns" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
# Ad-hoc signature gives the bundle one stable identity, which is what the
# permission grants attach to. The updater re-signs after it replaces the binary.
codesign -s - -f --deep "$APP" >/dev/null 2>&1 || true
# Tell the Finder to notice the new icon straight away.
touch "$APP"
echo "installed $APP"
echo ""
echo "OPEN IT: double-click Tokkah in $APPS, type a room name, press Join."
echo "Both people type the SAME room name and you are connected -- directly, with"
echo "no server in between. The room name is also the encryption key, so choose"
echo "something only the two of you would say."
echo ""
echo "It keeps itself up to date on its own; you never install it again."
echo ""
echo "The first call will ask for microphone and camera permission. Allow both."
echo ""
echo "There is a command-line version too, for measuring things:"
echo "  tk --room ripe-mango-jam --window"
case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo ""; echo "for that, add it to your PATH:"; echo "  echo 'export PATH=\"$DEST:\$PATH\"' >> ~/.zshrc && exec zsh" ;;
esac
