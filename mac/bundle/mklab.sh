#!/bin/bash
# Build Voice Lab.app around an already-built `voicelab` binary.
# Same signing identity as Kin -- a different certificate would be a second
# thing to keep alive, and this is a tool, not a product.
set -euo pipefail
BIN="$1"; OUT="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$OUT/Voice Lab.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/lab/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/VoiceLab"
chmod +x "$APP/Contents/MacOS/VoiceLab"
printf 'APPL????' > "$APP/Contents/PkgInfo"
: "${KIN_SIGNING_ENV:=$HOME/.config/kin-signing/env}"
if [ ! -f "$KIN_SIGNING_ENV" ]; then echo "mklab: no signing identity" >&2; exit 1; fi
set -a; . "$KIN_SIGNING_ENV"; set +a
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN_NAME" 2>/dev/null || {
  echo "mklab: cannot unlock $KEYCHAIN_NAME" >&2; exit 1; }
codesign -s "$CN" -f --timestamp=none "$APP"
codesign --verify --deep --strict "$APP" || { echo "mklab: signature does not verify" >&2; exit 1; }
echo "$APP"
