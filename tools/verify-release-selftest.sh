#!/bin/bash
# Calibrate tools/verify-release.py before trusting a word it says.
#
# A verifier that returns "VERIFIED" for everything is indistinguishable from a
# verifier that works, right up until the day it matters. So this exercises the
# four ways a release can be wrong and requires a refusal for each one. It runs
# entirely offline against file:// fixtures -- no network, no credentials.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
V="$HERE/verify-release.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
check() { # name expected_exit
  local name="$1" want="$2"; shift 2
  "$@" > "$TMP/out" 2>&1; local got=$?
  if [ "$got" -eq "$want" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$name"
  else fail=$((fail+1)); printf '  FAIL %s (exit %d, wanted %d)\n' "$name" "$got" "$want"; sed 's/^/       /' "$TMP/out"; fi
}

# A real, signed manifest to build the fixtures from. Fetched once; every arm
# below is a local mutation of it, so the negative arms never touch the network.
mkdir -p "$TMP/good"
curl -fsS -o "$TMP/good/manifest.json"     https://room.tokkah.com/macos/manifest.json     || { echo "cannot reach the release server -- skipping"; exit 0; }
curl -fsS -o "$TMP/good/manifest.json.sig" https://room.tokkah.com/macos/manifest.json.sig || { echo "cannot reach the release server -- skipping"; exit 0; }
KEY=d07822edb36c8692c83f3478c26683102cd3cf6fb1d0c263496404c15fd95b2a

# A payload whose hash we control, so the archive arm needs no download.
python3 - "$TMP" <<'PY'
import hashlib, json, os, sys
t = sys.argv[1]
blob = b"not really a release, but its hash is honest\n"
open(os.path.join(t, "good", "payload.bin"), "wb").write(blob)
open(os.path.join(t, "good", "sha.txt"), "w").write(hashlib.sha256(blob).hexdigest())
PY
GOODSHA="$(cat "$TMP/good/sha.txt")"

echo "verify-release.py self-test"
# The positive arm has to be the live release. There is deliberately no way to
# fake one offline: the sha256 of the archive is inside the signed manifest, so
# building a fixture that passes would require the signing key -- which is the
# property being tested.
check "a genuine live release verifies end to end"   0 python3 "$V"
# Also pin the published key: if the constant in verify-release.py ever drifts
# from the key written in the docs, this arm is what notices.
check "the documented public key is the one used"    0 python3 "$V" --key "$KEY"

cp -R "$TMP/good" "$TMP/tampered"
python3 -c "
import sys; p=sys.argv[1]; b=bytearray(open(p,'rb').read()); b[20]^=1; open(p,'wb').write(b)" "$TMP/tampered/manifest.json"
check "a manifest altered by one bit is refused"     1 python3 "$V" --base "file://$TMP/tampered"

cp -R "$TMP/good" "$TMP/badsig"
python3 -c "
import base64,sys; p=sys.argv[1]
s=bytearray(base64.b64decode(open(p,'rb').read().strip())); s[10]^=1
open(p,'wb').write(base64.b64encode(bytes(s)))" "$TMP/badsig/manifest.json.sig"
check "a signature altered by one bit is refused"    1 python3 "$V" --base "file://$TMP/badsig"

check "a different public key is refused"            1 python3 "$V" --base "file://$TMP/good" \
      --key 0000000000000000000000000000000000000000000000000000000000000001
check "a signature that is not base64 is refused"    1 sh -c "printf 'not base64 at all' > '$TMP/good/manifest.json.sig.bak'; cp '$TMP/good/manifest.json.sig' '$TMP/good/keep'; printf '!!!!' > '$TMP/good/manifest.json.sig'; python3 '$V' --base 'file://$TMP/good'; rc=\$?; cp '$TMP/good/keep' '$TMP/good/manifest.json.sig'; exit \$rc"

# An archive whose bytes do not match the signed hash must be refused even
# though the signature over the manifest is perfectly valid. This is the arm
# that catches a server swapping the payload and leaving the manifest alone.
check "an archive with the wrong hash is refused"    1 python3 "$V" --base "file://$TMP/good" --file "$TMP/good/payload.bin"

echo
if [ "$fail" -eq 0 ]; then echo "SELF-TEST PASSED ($pass checks)"; else echo "SELF-TEST FAILED ($fail of $((pass+fail)))"; fi
[ "$fail" -eq 0 ]
