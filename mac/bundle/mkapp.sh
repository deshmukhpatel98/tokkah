#!/bin/bash
# Build Tokkah.app around an already-built `tk` binary.
#
#   bundle/mkapp.sh <version> <path-to-tk> <output-dir>
#
# The bundle is not cosmetic. A bare CLI binary has no identity of its own, so
# macOS attributes its microphone and camera grants to whatever terminal launched
# it -- they cannot be reviewed or revoked in System Settings, and they do not
# survive being run a different way. A bundle owns its permissions, its icon and
# its name, which is what makes this installable on someone else's Mac.
#
# Same binary as the CLI, under a different name inside the bundle: one thing to
# build, one thing to test, and the self-updater's `Bundle.main.executableURL`
# resolves correctly either way.
set -euo pipefail
VER="$1"; BIN="$2"; OUT="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$OUT/Tokkah.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed "s/__VERSION__/$VER/g" "$HERE/Info.plist" > "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/Tokkah"
chmod +x "$APP/Contents/MacOS/Tokkah"
[ -f "$HERE/AppIcon.icns" ] && cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Ad-hoc signature over the whole bundle. Not notarisation -- it is what lets
# macOS treat the bundle as one stable identity, so the permission grants stick
# to it instead of being re-asked on every launch.
codesign -s - -f --deep "$APP" 2>/dev/null || echo "  (ad-hoc sign skipped)"
echo "$APP"
