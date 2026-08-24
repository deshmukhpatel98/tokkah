#!/bin/bash
# Build Kin.app around an already-built `tk` binary.
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
APP="$OUT/Kin.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed "s/__VERSION__/$VER/g" "$HERE/Info.plist" > "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/Tokkah"
chmod +x "$APP/Contents/MacOS/Tokkah"
[ -f "$HERE/AppIcon.icns" ] && cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# ── SIGNED WITH A CERTIFICATE, NOT AD-HOC ────────────────────────────────────
#
# macOS pins a camera or microphone grant to the app's DESIGNATED REQUIREMENT.
# Ad-hoc signing produces
#     cdhash H"4d912c63..."
# which is a hash of the bundle's contents, so it changes whenever any byte
# changes -- that is, every release. tccd was observed refusing to match one:
#   matchesCodeRequirement: static code from com.tokkah.tk : cdhash H"4d912c63..."
# Signing with a stable certificate produces
#     identifier "com.tokkah.tk" and certificate root = H"ef8e905f..."
# which is byte-identical for every build, so the grants survive updates.
#
# Ad-hoc is NOT a fallback here. A bundle that ships unsigned or ad-hoc signed
# costs every user their permissions, and the old code hid exactly that behind
# `2>/dev/null || echo skipped` -- a failure nobody would ever read. Signing is
# now allowed to fail the build instead.
: "${KIN_SIGNING_ENV:=$HOME/.config/kin-signing/env}"
if [ ! -f "$KIN_SIGNING_ENV" ]; then
  echo "mkapp: no signing identity at $KIN_SIGNING_ENV" >&2
  echo "  Create one with mac/tools/make-identity.sh -- see mac/SIGNING.md." >&2
  echo "  Refusing to ad-hoc sign: it would drop every user's camera and mic grants." >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; . "$KIN_SIGNING_ENV"; set +a
# The keychain is locked after a reboot, and codesign's failure mode when it
# cannot reach the key is a GUI prompt on a machine that may be running this
# unattended. Unlocking first turns that into a clean exit.
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN_NAME" 2>/dev/null || {
  echo "mkapp: cannot unlock $KEYCHAIN_NAME" >&2; exit 1; }
codesign -s "$CN" -f --timestamp=none "$APP"

# The signature has to be checked against what it must be, not merely to exist.
# A signature that verifies is not evidence TCC will match it: only the exact
# requirement string is, and if this ever changes every user is re-prompted.
WANT="identifier \"com.tokkah.tk\" and certificate root = H\"$CERT_SHA1\""
GOT=$(codesign -dr - "$APP" 2>/dev/null | sed -n 's/^designated => //p')
if [ "$GOT" != "$WANT" ]; then
  echo "mkapp: DESIGNATED REQUIREMENT CHANGED -- this re-prompts every user." >&2
  echo "  want: $WANT" >&2
  echo "  got:  $GOT" >&2
  exit 1
fi
codesign --verify --deep --strict "$APP" || { echo "mkapp: signature does not verify" >&2; exit 1; }
echo "$APP"
