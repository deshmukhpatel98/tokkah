#!/bin/sh
# Install tk, the native macOS half of Kin.
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
# Overridable for the install-path arms of mac/tools/update-check.sh ONLY, which
# point them at its own signed fake server and its own scratch directories. The
# defaults are the production ones and are what every real install uses.
#
# It needed an override to be tested at all: until it had one, the only way to
# exercise this script was to run it, and running it writes /Applications/Kin.app
# on the machine doing the testing. So the install half -- the half that is
# ALREADY on somebody's Mac when a fix ships, and therefore the half that takes
# two releases to correct -- was the one half nothing could check.
BASE="${TK_INSTALL_BASE:-https://room.tokkah.com/macos}"
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
# The two staging names below are swept too. They are siblings of the real thing
# in directories the user keeps, so an interrupted install must not leave a
# half-written bundle sitting in Applications forever.
trap 'rm -rf "$TMP" "${DEST:-$TMP}/.tk.incoming" "${APPS:-$TMP}/.Kin.app.incoming" 2>/dev/null || true' EXIT
echo "downloading Kin $VER"
curl -fsSL "$URL" -o "$TMP/tk.tar.gz"
GOT=$(shasum -a 256 "$TMP/tk.tar.gz" | awk '{print $1}')
[ "$GOT" = "$WANT" ] || { echo "checksum mismatch: expected $WANT, got $GOT" >&2; exit 1; }

tar -xzf "$TMP/tk.tar.gz" -C "$TMP" \
  || { echo "the archive did not unpack -- nothing here was changed" >&2; exit 1; }

# ── NOTHING IS REPLACED UNTIL ITS REPLACEMENT HAS RUN ────────────────────────
#
# This was three lines: `mv "$TMP/tk" "$DEST/tk"`, chmod, and then -- AFTERWARDS
# -- `"$DEST/tk" --version` to print what had been installed. So the working
# binary was destroyed first and asked to prove itself second, and a payload that
# unpacked to something that does not run left the person with no working tk and
# no way back except finding this URL again. `set -e` does not save it: the mv
# had already happened.
#
# It is the same shape as the bug the Swift updater was built around -- it
# executes the candidate once, in a subprocess, before it is allowed to replace
# anything -- so the install half now does what the update half does:
#
#   1. find the executable, in the archive or in the bundle it carries
#   2. run it, from the temp directory, where failing costs nothing
#   3. copy it to a sibling of the real path and rename over it. Same directory,
#      so that last step is rename(2) and cannot be seen half done. `mv` across
#      filesystems is copy-then-unlink, and $TMPDIR is not always the same volume
#      as $HOME.
#
# ── AND BOTH DIRECTIONS OF THE VERSION SKEW ─────────────────────────────────
#
# `updater-ships-only-what-it-can-install`: this file is the half that is already
# on the person's Mac, so a fix here reaches nobody until they install again, and
# the pair that has to keep working is an OLD installer meeting a NEW payload and
# a NEW installer meeting an OLD payload.
#
#   new installer, old payload (tk + bundle/, no Kin.app)  -- takes tk, assembles
#     the bundle in the fallback below. Unchanged behaviour.
#   new installer, future payload (Kin.app, no bare tk)    -- takes the bundle's
#     own executable as the command-line tk instead of dying on a missing file.
#   old installer, future payload                          -- `mv` fails and the
#     script exits before touching Kin.app. It cannot be fixed from here, and it
#     is why the archive must keep carrying a bare `tk` until installers this old
#     are gone. Written down rather than assumed.
CLI="$TMP/tk"
if [ ! -f "$CLI" ]; then
  CLI=""
  for exe in "$TMP"/Kin.app/Contents/MacOS/*; do
    if [ -f "$exe" ]; then CLI="$exe"; break; fi
  done
  [ -z "$CLI" ] || echo "note: this release carries no bare tk; taking it from the bundle"
fi
[ -n "$CLI" ] && [ -s "$CLI" ] \
  || { echo "the archive contained no runnable tk -- nothing here was changed" >&2; exit 1; }
chmod +x "$CLI" 2>/dev/null || true
"$CLI" --version >/dev/null 2>&1 \
  || { echo "the downloaded tk does not run -- nothing here was changed" >&2; exit 1; }

mkdir -p "$DEST"
cp "$CLI" "$DEST/.tk.incoming"
chmod +x "$DEST/.tk.incoming"
mv "$DEST/.tk.incoming" "$DEST/tk"

echo "installed $DEST/tk ($("$DEST/tk" --version))"

# ── Kin.app, so this is something you can hand to another person ─────────────
#
# The bundle is assembled HERE rather than downloaded, so there is still exactly
# one archive in the world and it cannot fall out of step with the binary the
# self-updater fetches.
#
# It matters for more than the icon: a bare command-line binary has no code
# identity of its own, so macOS attributes its microphone and camera grants to
# whichever terminal launched it -- they cannot be reviewed in System Settings and
# they do not follow the program. A bundle owns its permissions.
APPS="${TK_APPS:-}"
if [ -z "$APPS" ]; then
  APPS="/Applications"
  [ -w "$APPS" ] || APPS="$HOME/Applications"
fi
mkdir -p "$APPS"
APP="$APPS/Kin.app"
# ── ASSEMBLED BESIDE THE REAL ONE, NOT OVER IT ──────────────────────────────
#
# This was `rm -rf "$APP"` here, and everything below wrote straight into the
# live path -- so from that line until the last `codesign`, the person had no
# Kin.app at all, and any failure in between (a `ditto` that ran out of disk, a
# Ctrl-C, a closed lid) left them with none permanently. Their working app was
# deleted to make room for one that had not been built yet.
#
# The whole bundle is assembled at a sibling path and swapped in at the end. The
# swap is a rename within one directory, which cannot be observed half done, and
# the copy being replaced stays intact and launchable until the moment it works.
STAGE="$APPS/.Kin.app.incoming"
rm -rf "$STAGE"

# ── PREFER THE SIGNED BUNDLE THE ARCHIVE ALREADY CARRIES ─────────────────────
#
# Assembling the bundle here and ad-hoc signing it is what made the permission
# prompts come back. macOS pins a camera or microphone grant to the app's
# designated requirement, and an ad-hoc signature's requirement is a hash of the
# bundle's contents -- so it changed on every release, and every change looked
# like a brand new application that had to ask again. It was worse than that:
# the icon below is fetched with `|| true` BEFORE the signature is made, so two
# machines that disagreed about whether that fetch succeeded ended up with two
# different identities for the same version.
#
# Releases now ship the finished bundle signed with a stable certificate, so the
# right thing to do is copy it and change nothing. `ditto` preserves the
# extended attributes parts of a signature live in.
if [ -d "$TMP/Kin.app" ]; then
  ditto "$TMP/Kin.app" "$STAGE"
  codesign --verify --deep --strict "$STAGE" 2>/dev/null \
    || echo "warning: the downloaded bundle does not verify"
else
# Fallback for an archive built before the bundle shipped inside it. Still
# ad-hoc, so permissions will be re-asked on each update until a release with
# the signed bundle arrives -- which is the bug, not the design.
echo "note: this release predates signed bundles; permissions may be re-asked"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$DEST/tk" "$STAGE/Contents/MacOS/Tokkah"
chmod +x "$STAGE/Contents/MacOS/Tokkah"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Kin</string>
  <key>CFBundleDisplayName</key><string>Kin</string>
  <key>CFBundleIdentifier</key><string>com.tokkah.tk</string>
  <!-- Stays Tokkah, and MUST match bundle/Info.plist: that one is written into
       existing installs by the self-updater, so if these two disagree about the
       executable's name, whichever install receives the other one stops
       launching. Both flip together, one release after the updater that can move
       the file has shipped. -->
  <key>CFBundleExecutable</key><string>Tokkah</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <!-- This was absent, so a curl install could not open a deep link at all: the
       scheme only ever existed in the .dmg's plist. Two hand-written copies of
       the same metadata, and they had already drifted. release.sh now compares
       them. -->
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>Kin call</string>
    <key>CFBundleURLSchemes</key><array><string>kin</string><string>tokkah</string></array>
  </dict></array>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundleVersion</key><string>$VER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Kin needs the microphone to carry your voice on a call.</string>
  <key>NSCameraUsageDescription</key>
  <string>Kin needs the camera to send your picture on a call.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Kin connects directly to the other person, including over your local network, so audio and video do not travel through a server.</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
# Best-effort: a missing icon is a generic app tile, not a broken install.
curl -fsSL "$BASE/AppIcon.icns" -o "$STAGE/Contents/Resources/AppIcon.icns" 2>/dev/null || true
codesign -s - -f --deep "$STAGE" >/dev/null 2>&1 || true
fi

# ── AND ONLY NOW DOES THE REAL PATH CHANGE ──────────────────────────────────
#
# Checked, not assumed: `ditto` and the fallback are both best-effort in places,
# and swapping in a bundle with no executable would replace a working Kin with
# one that cannot launch. The old copy is moved aside rather than deleted, so a
# failed rename can be undone; it is removed only once the new one is in place.
if [ ! -x "$STAGE/Contents/MacOS/Tokkah" ]; then
  rm -rf "$STAGE"
  echo "the new bundle did not assemble -- $APP was left as it is" >&2
  exit 1
fi
PREV="$APPS/.Kin.app.previous"
rm -rf "$PREV"
if [ -d "$APP" ]; then mv "$APP" "$PREV"; fi
if mv "$STAGE" "$APP"; then
  rm -rf "$PREV"
else
  echo "could not put the bundle at $APP" >&2
  if [ -d "$PREV" ]; then mv "$PREV" "$APP"; fi
  rm -rf "$STAGE"
  exit 1
fi
# Tell the Finder to notice the new icon straight away.
touch "$APP"
# ── The Tokkah.app this one renames must not survive alongside it ────────────
#
# Kin.app IS the old Tokkah.app under its new name. Leaving both would give the
# user two apps in /Applications, two copies updating themselves every minute,
# and two separate code identities holding two separate microphone grants --
# with no way to tell which one the invite link opens. Same bundle, new name, so
# the old directory goes.
if [ -d "$APPS/Tokkah.app" ]; then
  rm -rf "$APPS/Tokkah.app"
  echo "removed the older $APPS/Tokkah.app (this is the same app, renamed)"
fi
echo "installed $APP"
echo ""
echo "OPEN IT: double-click Kin in $APPS, type a room name, press Join."
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
