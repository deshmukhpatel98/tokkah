#!/bin/bash
# ── SHIP KIN FOR ANDROID ─────────────────────────────────────────────────────
#
# The Mac's release.sh, for the phone: build the APK, hash it, upload it to
# the SAME R2 bucket the disk image lives in (one bucket is one thing to forget
# to upload to), write a SIGNED manifest into the worker's public dir, bump the
# download page, deploy the worker, and then refuse to say "released" until the
# edge serves the new manifest and the served APK hashes to what it promises.
#
#   android/release.sh 0.126.0-android.12 "what changed, one sentence"
#
# The version is written INTO build.gradle.kts here, so the APK's own
# versionName, the manifest and the page cannot disagree: the installed copy
# asks the package manager what it is and compares that to the manifest, and a
# mismatch between the two is the "re-downloads forever" bug.
#
# SIGNING. The APK is signed with this Mac's Android debug key, which is what
# every copy in the field was signed with -- Android refuses an update signed by
# any other key, so changing it would strand every install. The manifest is
# signed with the Mac's Ed25519 release key (mac/tools/sign), the trust root
# Update.kt compiles in.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VER="${1:?usage: android/release.sh <version> <notes>}"
NOTES="${2:?usage: android/release.sh <version> <notes>}"
case "$VER" in
  *.*.*-android.*) ;;
  *) echo "FAILED: version must look like 0.126.0-android.12 (the Mac tree it was built from, then the phone's own count)"; exit 2 ;;
esac
CODE="${VER##*-android.}"
[ "$CODE" -eq "$CODE" ] 2>/dev/null || { echo "FAILED: the trailing number is the versionCode and must be an integer"; exit 2; }
[ -f "$REPO/tape-app/wrangler.prod.jsonc" ] || {
  echo "FAILED: no tape-app/wrangler.prod.jsonc -- it is gitignored, so this is not the main checkout"; exit 1; }
[ -x "$REPO/mac/tools/sign" ] || { echo "FAILED: mac/tools/sign missing -- build it from mac/tools/sign.swift"; exit 1; }
[ -f "$HOME/.android/debug.keystore" ] || { echo "FAILED: no debug keystore -- every installed copy is signed with it"; exit 1; }

export JAVA_HOME="${JAVA_HOME:-$HOME/android-sdk/jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"

echo "== version =="
# ── NEVER RELEASE BACKWARDS ─────────────────────────────────────────────────
# Two sessions once shipped 0.128.1-android.20 and 0.128.0-android.21 within
# minutes of each other. The phone orders versions numerically per segment, so
# every phone on the first could never see the second. The edge is the
# authority: refuse a version that does not compare greater than what is live.
LIVE="$(curl -fsS "https://room.tokkah.com/android/manifest.json?cb=$$" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null || true)"
if [ -n "$LIVE" ]; then
  python3 - "$VER" "$LIVE" <<'PY' || { echo "FAILED: $VER is not newer than the live $LIVE -- a phone on $LIVE would never take it"; exit 1; }
import re, sys
def parts(v): return [int(x) for x in re.split(r'[.-]', v) if x.isdigit()]
a, b = parts(sys.argv[1]), parts(sys.argv[2])
n = max(len(a), len(b)); a += [0] * (n - len(a)); b += [0] * (n - len(b))
sys.exit(0 if a > b else 1)
PY
  echo "  live is $LIVE"
fi
GR="$REPO/android/app/build.gradle.kts"
sed -i '' -E "s/versionCode = [0-9]+/versionCode = $CODE/; s/versionName = \"[^\"]+\"/versionName = \"$VER\"/" "$GR"
grep -E "versionCode = $CODE|versionName = \"$VER\"" "$GR" | wc -l | grep -q 2 || { echo "FAILED: build.gradle.kts did not take the version"; exit 1; }
echo "  $VER (code $CODE)"

echo "== build =="
# Pipes mask exit codes (pipes-mask-exit-codes): the build's status is read directly.
(cd "$REPO/android" && ./gradlew -q :app:assembleDebug :app:testDebugUnitTest)
APK_SRC="$REPO/android/app/build/outputs/apk/debug/app-debug.apk"
[ -f "$APK_SRC" ] || { echo "FAILED: no APK at $APK_SRC"; exit 1; }
# The APK must carry the version it claims.
"$ANDROID_HOME/build-tools/"*/aapt dump badging "$APK_SRC" 2>/dev/null | grep -q "versionName='$VER'" \
  || { echo "FAILED: the built APK does not say versionName=$VER"; exit 1; }
APK="kin-$VER.apk"
cp "$APK_SRC" "/tmp/$APK"
SHA="$(shasum -a 256 "/tmp/$APK" | awk '{print $1}')"
SIZE="$(stat -f%z "/tmp/$APK")"
echo "  $APK  $SIZE bytes  sha256 $SHA"

echo "== upload =="
(cd "$REPO/tape-app" && npx wrangler r2 object put "tokkah-mac/$APK" --file="/tmp/$APK" --remote >/dev/null)

echo "== manifest =="
OUT="$REPO/tape-app/public/android"
mkdir -p "$OUT"
python3 - "$OUT/manifest.json" "$VER" "$APK" "$SHA" "$SIZE" "$NOTES" <<'PY'
import json, sys
p, ver, apk, sha, size, notes = sys.argv[1:]
json.dump({"version": ver, "url": f"https://room.tokkah.com/android/dl/{apk}", "sha256": sha,
           "size": int(size), "appName": "Kin", "notes": notes}, open(p, "w"), separators=(",", ":"))
PY
(cd "$REPO/mac" && ./tools/sign "$OUT/manifest.json" > "$OUT/manifest.json.sig")
echo "  signed ($(wc -c < "$OUT/manifest.json.sig" | tr -d ' ') bytes)"

echo "== page =="
f="$OUT/index.html"
sed -i '' -E "s/kin-[0-9]+\.[0-9]+\.[0-9]+-android\.[0-9]+\.apk/$APK/g" "$f"
grep -q "$APK" "$f" || { echo "FAILED: $f has no APK link to bump"; exit 1; }

echo "== deploy =="
(cd "$REPO/tape-app" && npx wrangler deploy -c wrangler.prod.jsonc | tail -2)

echo "== verify from the outside =="
ok=""
for i in $(seq 1 20); do
  got="$(curl -fsS "https://room.tokkah.com/android/manifest.json?cb=$$-$i" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null || true)"
  if [ "$got" = "$VER" ]; then ok=1; break; fi
  printf '  edge still on %s, waiting (%s/20)\n' "${got:-?}" "$i"
  sleep 3
done
[ -n "$ok" ] || { echo "FAILED: edge never served $VER"; exit 1; }
tmp="$(mktemp)"
curl -fsS "https://room.tokkah.com/android/dl/$APK" -o "$tmp" || { echo "FAILED: APK not fetchable"; exit 1; }
have="$(shasum -a 256 "$tmp" | awk '{print $1}')"
rm -f "$tmp"
[ "$SHA" = "$have" ] || { echo "FAILED: served APK hashes $have, manifest promises $SHA"; exit 1; }
# And the signature the phone will check, checked here with the same key.
python3 - "$OUT/manifest.json" "$OUT/manifest.json.sig" <<'PY' || { echo "FAILED: manifest signature does not verify"; exit 1; }
import sys, base64, binascii
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
except ImportError:
    print("  (python cryptography not installed; signature not re-checked here)"); sys.exit(0)
pub = Ed25519PublicKey.from_public_bytes(bytes.fromhex("d07822edb36c8692c83f3478c26683102cd3cf6fb1d0c263496404c15fd95b2a"))
msg = open(sys.argv[1], "rb").read()
sig = open(sys.argv[2], "rb").read().strip()
try: raw = base64.b64decode(sig, validate=True)
except binascii.Error: raw = bytes.fromhex(sig.decode())
pub.verify(raw, msg); print("  signature verifies")
PY
echo "  manifest $VER, APK fetched and hash matches"
echo "released $VER"
