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
block = re.search(r"let KNOWN_FLAGS: Set<String> = \[(.*?)\]", src, re.S).group(1)
# ── A COMMENT IS NOT A FLAG ──────────────────────────────────────────────────
# The comments INSIDE this literal quote things -- they are where the reason a
# flag exists gets written down, and reasons contain sentences. One of them
# quotes a rig's negative arm, `"the same crash, and it does NOT come back"`,
# and this check read that sentence as two flag names nobody reads and failed
# the release. Strip line comments before looking for names.
block = re.sub(r"//[^\n]*", "", block)
names = re.findall(r'"([^"]+)"', block)
seen = set(re.findall(r'(?:arg|flag)\("([^"]+)"\)', src)) | set(re.findall(r'arguments\.contains\("--([^"]+)"\)', src))
dead = [n for n in names if n not in seen]
print("  %d flags registered, all read" % len(names) if not dead
      else "  REGISTERED BUT NEVER READ: %s" % ", ".join(dead))
sys.exit(1 if dead else 0)
EOF

echo "== build =="
swift build -c release
BIN=.build/release/tk
# Signed with the release certificate, not ad-hoc, and not allowed to fail
# quietly. The old line ended in `2>/dev/null || echo skipped`, so a machine
# without a working identity shipped an unsigned binary and said so in passing.
: "${KIN_SIGNING_ENV:=$HOME/.config/kin-signing/env}"
[ -f "$KIN_SIGNING_ENV" ] || { echo "no signing identity at $KIN_SIGNING_ENV -- run tools/make-identity.sh"; exit 1; }
# shellcheck disable=SC1090
set -a; . "$KIN_SIGNING_ENV"; set +a
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN_NAME" 2>/dev/null || { echo "cannot unlock $KEYCHAIN_NAME"; exit 1; }
codesign -s "$CN" -f --timestamp=none "$BIN"
test "$("$BIN" --version)" = "$VER" || { echo "binary reports $("$BIN" --version), expected $VER"; exit 1; }

# ── the two plists must agree ────────────────────────────────────────────────
#
# The bundle's metadata is written by hand in TWO places: `bundle/Info.plist`,
# which ships in the archive and is installed over existing copies by the
# updater, and the heredoc in `install.sh`, which builds the bundle for a fresh
# curl install. They had already drifted -- the URL scheme existed in one and not
# the other, so a curl install could not open a deep link -- and the dangerous
# field is CFBundleExecutable: if the two disagree, whichever install receives the
# other one's plist looks for an executable that is not there and stops launching.
# The migration that renames the app runs once, on a machine that is not this
# one, and its failure mode is an app that will not launch. Gated, not trusted.
echo "== rename migration =="
"$REPO/mac/.build/release/tk" --selftest-rename || { echo "FAILED: rename self-test"; exit 1; }

# relocateIfHomeless fires exactly once, on somebody else's Mac, the first time
# they open the copy that came out of the DMG -- and it moves the app they just
# downloaded. Get it wrong and the thing they were about to run is somewhere they
# did not put it, or gone. There is no second attempt, so it is proven here.
echo "== install migration =="
"$REPO/mac/.build/release/tk" --selftest-install || { echo "FAILED: install self-test"; exit 1; }

echo "== plists =="
python3 - "$REPO/mac/bundle/Info.plist" "$REPO/tape-app/public/macos/install.sh" <<'PYCHK'
import plistlib, re, sys
bundle = plistlib.load(open(sys.argv[1], "rb"))
sh = open(sys.argv[2], encoding="utf-8").read()
def sh_key(k):
    m = re.search(r"<key>" + k + r"</key>\s*<string>([^<]*)</string>", sh)
    return m.group(1) if m else None
bad = 0
# ── THE KEYS WHOSE ABSENCE IS A CRASH, NOT A DIFF ────────────────────────────
#
# This compared the four identity keys and stopped. The three usage strings are
# duplicated in both files too, and macOS treats a MISSING one as a fatal error
# the first time the app touches that device -- not a warning, not a silent
# denial: the process dies. `install.sh` ad-hoc signs in its fallback branch, so
# a drift here does not show up as a cosmetic difference between two plists, it
# shows up as Kin dying on somebody's first call with nothing to read.
#
# LSMinimumSystemVersion is here for the opposite reason: it was 13.0 in both
# files while Package.swift builds for 14 and the binary's own LC_BUILD_VERSION
# says minos 14.0. Agreeing with each other was never the property that mattered
# -- they agreed perfectly, and both were wrong. So it is checked against the
# BINARY below rather than only across the pair.
for k in ("CFBundleExecutable", "CFBundleIdentifier", "CFBundleName", "CFBundleDisplayName",
          "LSMinimumSystemVersion",
          "NSCameraUsageDescription", "NSMicrophoneUsageDescription",
          "NSLocalNetworkUsageDescription"):
    a, b = bundle.get(k), sh_key(k)
    if a != b:
        print(f"  MISMATCH {k}: bundle={a!r} install.sh={b!r}")
        bad = 1
    else:
        print(f"  {k} = {a}")
for k in ("NSCameraUsageDescription", "NSMicrophoneUsageDescription"):
    if not bundle.get(k):
        print(f"  MISSING {k} in the bundle -- the app will DIE on first use of that device")
        bad = 1
sys.exit(bad)
PYCHK

# ── AND THE FLOOR MUST BE ONE THE BINARY CAN ACTUALLY MEET ───────────────────
#
# Both plists said macOS 13 while the binary is built for 14. That combination
# is worse than either mistake alone: macOS reads the plist, decides the app is
# allowed to run, launches it, and dyld then refuses the binary -- so a Mac on
# 13 gets a launch failure rather than the honest "requires macOS 14" it would
# have got from a truthful plist. Nothing in the repo could notice, because the
# two files agreed with each other.
echo "== os floor =="
python3 - "$REPO/mac/bundle/Info.plist" "$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')" <<'PYMIN'
import plistlib, sys
said = plistlib.load(open(sys.argv[1], "rb")).get("LSMinimumSystemVersion")
real = sys.argv[2]
def v(x): return tuple(int(n) for n in (x or "0").split(".")[:2])
if not real:
    print("  COULD NOT READ minos from the binary -- not proven"); sys.exit(1)
if v(said) < v(real):
    print(f"  MISMATCH: the plist admits {said} and the binary needs {real} --"
          f" a Mac on {said} would be allowed to launch something dyld refuses")
    sys.exit(1)
print(f"  plist says {said}, binary needs {real}")
PYMIN

echo "== icon =="
# Regenerated every release from the Material Symbols path, so the icon in the
# repo can never drift from the source it claims to come from.
swift bundle/mkicon.swift bundle/AppIcon.icns

echo "== bundle =="
# Built BEFORE packaging, because the archive now carries the finished, signed
# bundle as well as the loose binary. The .dmg is cut from this same directory,
# so there is one signed artefact and it cannot disagree with itself.
APPDIR=$(mktemp -d)
./bundle/mkapp.sh "$VER" "$BIN" "$APPDIR" >/dev/null
echo "  signed: $(codesign -dr - "$APPDIR/Kin.app" 2>/dev/null | sed -n 's/^designated => //p')"

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
# ── AND THE WHOLE SIGNED BUNDLE, WHICH IS WHAT NEW UPDATERS TAKE ─────────────
#
# `tk` + `bundle/` above is the LEGACY payload and stays for now: the updater
# that applies this release is the one already installed, and every updater at
# 0.45.0 or older refuses a stage that has no bare `tk` in it. Removing it would
# strand exactly the people furthest behind.
#
# `Kin.app/` is the new payload. An updater that understands it replaces the
# whole bundle in one move and never runs codesign on the user's machine, so the
# certificate signature made here survives intact -- which is the entire point:
# the designated requirement is what a camera or microphone grant is pinned to,
# and patching files inside a bundle invalidates any real signature over them.
# Old updaters do not look for this directory and ignore it.
#
# `ditto` rather than `cp -R`: it preserves the extended attributes the
# signature is stored in for some resources. A bundle copied with anything less
# arrives with a signature that no longer verifies.
ditto "$APPDIR/Kin.app" "$STAGE/Kin.app"
TAR="tk-$VER.tar.gz"
tar -czf "/tmp/$TAR" -C "$STAGE" tk bundle Kin.app
SHA=$(shasum -a 256 "/tmp/$TAR" | awk '{print $1}')
SIZE=$(stat -f%z "/tmp/$TAR")
echo "  $TAR  $SIZE bytes  sha256 $SHA"

# ── THE SIGNATURE HAS TO SURVIVE THE ARCHIVE ─────────────────────────────────
#
# A bundle can be signed correctly here and still arrive broken, because an
# archive that drops the wrong metadata invalidates the signature over it. The
# user's machine cannot re-sign -- that is the whole design -- so a signature
# damaged in transit is permanent and shows up as a permission prompt nobody can
# explain. Checked on the extracted copy, which is the artefact that actually
# reaches people, rather than on the one still sitting in $APPDIR.
ROUND=$(mktemp -d)
tar -xzf "/tmp/$TAR" -C "$ROUND"
codesign --verify --deep --strict "$ROUND/Kin.app" \
  || { echo "FAILED: signature does not survive the tarball"; exit 1; }
GOT=$(codesign -dr - "$ROUND/Kin.app" 2>/dev/null | sed -n 's/^designated => //p')
WANT="identifier \"com.tokkah.tk\" and certificate root = H\"$CERT_SHA1\""
[ "$GOT" = "$WANT" ] || { echo "FAILED: requirement changed in transit"; echo "  want: $WANT"; echo "  got:  $GOT"; exit 1; }
echo "  survives extraction, requirement intact"
rm -rf "$ROUND"

# ── a .dmg for people who would rather drag than curl ────────────────────────
#
# Cut from the same signed $APPDIR the archive carries, so the bundle a person
# drags out of the .dmg and the bundle an updater installs are the same bytes
# under the same signature.
echo "== dmg =="
DMG="Kin-$VER.dmg"
rm -f "/tmp/$DMG"
STAGE2=$(mktemp -d)
cp -R "$APPDIR/Kin.app" "$STAGE2/"
ln -s /Applications "$STAGE2/Applications"
hdiutil create -quiet -volname "Kin $VER" -srcfolder "$STAGE2" -ov -format UDZO "/tmp/$DMG"
DMGSHA=$(shasum -a 256 "/tmp/$DMG" | awk '{print $1}')
echo "  $DMG  $(stat -f%z "/tmp/$DMG") bytes"
# The icon travels as a static asset so install.sh can assemble a bundle without a
# second archive to keep in step.
cp bundle/AppIcon.icns "$REPO/tape-app/public/macos/AppIcon.icns"

# ── AND AS A PNG, BECAUSE A BROWSER CANNOT RENDER .icns ──────────────────────
#
# The download page at /mac shows the app's own mark. The first version of that
# page REDREW it as inline SVG, off a stale bundle/icon-1024.png, and so spent a
# day advertising the previous logo while the .icns next to it was already the
# current one. Exporting from the icns the release just generated means the page
# cannot disagree with the app it hands you.
ICONSET=$(mktemp -d)
iconutil -c iconset bundle/AppIcon.icns -o "$ICONSET/AppIcon.iconset" >/dev/null
cp "$ICONSET/AppIcon.iconset/icon_512x512.png" "$REPO/tape-app/public/macos/AppIcon.png"
rm -rf "$ICONSET"

echo "== upload =="
(cd "$REPO/tape-app" && npx wrangler r2 object put "tokkah-mac/$TAR" --file="/tmp/$TAR" --remote >/dev/null)
(cd "$REPO/tape-app" && npx wrangler r2 object put "tokkah-mac/$DMG" --file="/tmp/$DMG" --remote >/dev/null)
# A stable name as well as the versioned one, because the link a human shares
# should not go stale the next time this runs. Kin.dmg is that name now; the old
# Tokkah.dmg keeps being written so links already shared out in the world still
# resolve, at the cost of one extra R2 put per release.
(cd "$REPO/tape-app" && npx wrangler r2 object put "tokkah-mac/Kin.dmg" --file="/tmp/$DMG" --remote >/dev/null)
(cd "$REPO/tape-app" && npx wrangler r2 object put "tokkah-mac/Tokkah.dmg" --file="/tmp/$DMG" --remote >/dev/null)

# ── THE RENAME FLIPS HERE, AND ONLY THE DIRECTORY ────────────────────────────
#
# `appName` has been an optional field the updater knows how to act on for
# several releases, proven every release by --selftest-rename above; setting it
# is the whole flip. An updater too old to know the field parses the manifest
# and ignores it, so those copies stay Tokkah.app and keep updating -- nobody is
# stranded. CFBundleExecutable does NOT flip in this release, so relocate() only
# moves the directory and never has to find a renamed binary inside it.
echo "== manifest =="
OUT="$REPO/tape-app/public/macos"
mkdir -p "$OUT"
cat > "$OUT/manifest.json" <<JSON
{"version":"$VER","url":"https://room.tokkah.com/macos/dl/$TAR","sha256":"$SHA","size":$SIZE,"appName":"Kin","notes":"$NOTES","dmg":"https://room.tokkah.com/macos/dl/$DMG","dmgSha256":"$DMGSHA"}
JSON
./tools/sign "$OUT/manifest.json" > "$OUT/manifest.json.sig"
echo "  signed ($(wc -c < "$OUT/manifest.json.sig" | tr -d ' ') bytes)"

# ── keep the no-JS floor honest ──────────────────────────────────────────────
#
# Three pages bake the current version into the download link so they still work
# with JavaScript off, and their JS moves them forward from the signed manifest at
# runtime. Without this the baked value drifts: both kin.html and join.html were
# advertising 0.41.0 while 0.46.0 was live. The manifest is the authority; this
# only stops the fallback from lying.
#
# Asserted, not assumed -- a sed that silently matches nothing is exactly how a
# "fix" ships as a no-op.
echo "== page versions =="
for f in "$REPO/tape-app/public/kin.html" "$REPO/tape-app/public/join.html" \
         "$REPO/tape-app/public/macos/index.html"; do
  before=$(grep -coE "Kin-$VER\.dmg" "$f" || true)
  sed -i '' -E "s/Kin-[0-9]+\.[0-9]+\.[0-9]+\.dmg/Kin-$VER.dmg/g; \
                s/(<span id=ver>)v[0-9]+\.[0-9]+\.[0-9]+/\1v$VER/g" "$f"
  after=$(grep -coE "Kin-$VER\.dmg" "$f" || true)
  [ "$after" -gt 0 ] || { echo "FAILED: $f has no Kin-<version>.dmg link to bump"; exit 1; }
  echo "  $(basename "$f"): $after link(s) at $VER (was $before)"
done

echo "== deploy =="
(cd "$REPO/tape-app" && npx wrangler deploy -c wrangler.prod.jsonc | tail -3)

# ── kin.tokkah.com rides a zone route, not a custom domain ───────────────────
#
# Custom-domain attach wedged this hostname (ghost Workers-managed DNS entry,
# 2026-08-24), so the front door is: plain DNS records + this route. The route
# survives deploys, but a deploy from a fresh account state would drop it --
# so every release re-asserts it. Duplicate-route errors are the success case.
if [ -n "${CF_DNS_API_TOKEN:-}" ]; then
  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/646e49643a10c7406f2188eb2bae412b/workers/routes" \
    -H "Authorization: Bearer $CF_DNS_API_TOKEN" -H "Content-Type: application/json" \
    --data '{"pattern":"kin.tokkah.com/*","script":"tape-app"}' \
    | grep -q '"success": *true\|already exists\|duplicate' && echo "  kin route ok" || echo "  WARNING: kin route assert failed"
fi

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

# ── AND TAG IT, BECAUSE FOR SIXTY-NINE VERSIONS NOTHING DID ─────────────────
#
# This script had no git in it at all. It built, signed, deployed and verified a
# release and then left no mark in the history, so `git tag` returned nothing and
# the releases API returned [] while OPENNESS.md scored the project full marks
# for "tagged releases". Nobody was skipping a step; there was no step.
#
# It runs LAST, after the edge has served the manifest and the tarball has been
# fetched back and hashed, so a tag means "this shipped and was verified" rather
# than "somebody started a release". Nothing below can fail the release: it has
# already happened, and a script that succeeds at shipping and then exits
# non-zero teaches the operator to ignore its exit code.
if [ "${NO_TAG:-}" = 1 ]; then
  echo "  NO_TAG=1, not tagging"
elif git rev-parse "v$VER" >/dev/null 2>&1; then
  echo "  tag v$VER already exists, leaving it alone"
else
  if git tag -a "v$VER" -m "Kin $VER

The release commit for $VER. What changed is in CHANGELOG.md under
\"Kin $VER\"; the shipped binary can be checked against its signature
with tools/verify-release.py." 2>/dev/null; then
    echo "  tagged v$VER"
    if git push origin "v$VER" >/dev/null 2>&1; then
      echo "  pushed tag v$VER"
    else
      echo "  NOTE: could not push v$VER (wrong account? try: gh auth switch)."
      echo "        The tag exists locally: git push origin v$VER"
    fi
  else
    echo "  NOTE: could not create tag v$VER -- release is fine, tag it by hand"
  fi
fi

echo "released $VER"
