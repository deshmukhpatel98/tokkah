#!/bin/bash
# make-identity.sh -- create/install a persistent self-signed code-signing identity,
# fully non-interactively (no GUI prompt, no sudo). Verified on macOS 27.0 (26A5416b).
#
# Why: ad-hoc signing gives a cdhash-based designated requirement (DR) that changes on
# every build, so macOS TCC camera/mic grants are dropped on every self-update.
# Signing with a stable self-signed cert gives a DR of the form
#     identifier "<bundle-id>" and certificate root = H"<sha1-of-cert>"
# which is IDENTICAL across rebuilds -> TCC grants survive self-updates.
#
# CRITICAL: the DR is anchored to the CERTIFICATE, not the machine and not the keychain.
# Keep P12_PATH under version control / secret storage and REUSE IT FOREVER.
# Generating a new cert changes the DR and drops every existing TCC grant (one-time
# re-prompt for all users). This script reuses an existing .p12 when it finds one.
#
# Usage:
#   ./make-identity.sh                       # defaults below
#   KEYCHAIN_NAME=tokkah-build.keychain-db \
#   KEYCHAIN_PW=... P12_PW=... P12_PATH=/secrets/tokkah-signing.p12 ./make-identity.sh
#
# Then sign with:
#   codesign -s "$CN" -f --timestamp=none /path/to/Kin.app
#
set -euo pipefail

say() { printf '==> %s\n' "$*"; }
rnd() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; }

SECDIR="${SECDIR:-$HOME/.config/kin-signing}"
ENVFILE="${KIN_SIGNING_ENV:-$SECDIR/env}"

# An existing env file is the source of truth: re-running must not mint a second
# identity. A new certificate is a new designated requirement, and that costs
# every existing user their camera and microphone grants exactly once.
if [ -f "$ENVFILE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$ENVFILE"; set +a
  say "Reusing identity described by $ENVFILE"
fi

CN="${CN:-Kin Signing}"
ORG="${ORG:-Tokkah}"
DAYS="${DAYS:-3650}"
KEYCHAIN_NAME="${KEYCHAIN_NAME:-kin-signing.keychain-db}"
KEYCHAIN_PW="${KEYCHAIN_PW:-$(rnd)}"
P12_PATH="${P12_PATH:-$SECDIR/kin-signing.p12}"
P12_PW="${P12_PW:-$(rnd)}"
WORKDIR="${WORKDIR:-$(dirname "$P12_PATH")}"
mkdir -p "$SECDIR"; chmod 700 "$SECDIR"

# ---------------------------------------------------------------------------
# 1. Certificate: reuse the existing .p12 if present, else mint one.
#    RSA 2048 / sha256, keyUsage=digitalSignature, EKU=codeSigning, CA:false.
#    All three extensions marked critical. Works with system LibreSSL (3.3.6).
# ---------------------------------------------------------------------------
if [ -f "$P12_PATH" ]; then
  say "Reusing existing identity: $P12_PATH (DR will be unchanged)"
else
  say "No .p12 at $P12_PATH -- generating a NEW identity (this CHANGES the DR)"
  mkdir -p "$WORKDIR"
  CNF="$WORKDIR/codesign-cert.cnf"
  cat > "$CNF" <<EOF
[ req ]
default_bits        = 2048
default_md          = sha256
distinguished_name  = dn
prompt              = no
x509_extensions     = v3_codesign

[ dn ]
CN = $CN
O  = $ORG
C  = US

[ v3_codesign ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
EOF
  openssl req -x509 -newkey rsa:2048 \
    -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" \
    -days "$DAYS" -nodes -config "$CNF" -extensions v3_codesign
  openssl pkcs12 -export \
    -inkey "$WORKDIR/key.pem" -in "$WORKDIR/cert.pem" \
    -name "$CN" -out "$P12_PATH" -passout "pass:$P12_PW"
  say "Created $P12_PATH -- BACK THIS UP. Losing it means losing every TCC grant."
fi

# ---------------------------------------------------------------------------
# 2. Keychain: create if absent, never auto-lock, unlock.
#    NOTE: do NOT call `security show-keychain-info` on a LOCKED keychain --
#    that is the one command in this flow that raises a GUI unlock dialog.
# ---------------------------------------------------------------------------
KC_PATH="$HOME/Library/Keychains/$KEYCHAIN_NAME"
if [ -f "$KC_PATH" ]; then
  say "Keychain already exists: $KC_PATH"
else
  say "Creating keychain $KEYCHAIN_NAME"
  security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN_NAME"
fi
security set-keychain-settings "$KEYCHAIN_NAME"          # no args => no auto-lock, no lock-on-sleep
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN_NAME"

# ---------------------------------------------------------------------------
# 3. Search list: append ours, preserving what is already there. Idempotent.
# ---------------------------------------------------------------------------
SEARCH=()
while IFS= read -r line; do
  # strip leading whitespace and surrounding quotes; tolerates spaces in paths
  line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
  [ -n "$line" ] && SEARCH+=("$line")
done < <(security list-keychains -d user)

ALREADY=0
for k in "${SEARCH[@]}"; do
  case "$k" in *"$KEYCHAIN_NAME") ALREADY=1;; esac
done

if [ "$ALREADY" -eq 1 ]; then
  say "Already in user search list"
else
  say "Adding to user search list (preserving ${#SEARCH[@]} existing entr(y/ies))"
  security list-keychains -d user -s "${SEARCH[@]}" "$KEYCHAIN_NAME"
fi

# ---------------------------------------------------------------------------
# 4. Import + authorise codesign to use the key without prompting.
#    -T grants tool access; set-key-partition-list is what actually stops the
#    "codesign wants to use key ... " GUI dialog. -k supplies the password so
#    this itself never prompts.
# ---------------------------------------------------------------------------
# Re-importing an identity the keychain already holds fails with "already
# exists", which under `set -e` would abort a re-run that had nothing to do.
if security find-identity -p codesigning "$KEYCHAIN_NAME" 2>/dev/null | grep -qF "\"$CN\""; then
  say "Identity already in $KEYCHAIN_NAME, skipping import"
else
  say "Importing identity"
  security import "$P12_PATH" -k "$KEYCHAIN_NAME" -P "$P12_PW" -f pkcs12 \
    -T /usr/bin/codesign -T /usr/bin/security
fi

say "Setting key partition list"
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PW" "$KEYCHAIN_NAME" >/dev/null

# ---------------------------------------------------------------------------
# 5. Report. find-identity -v will show 0 valid identities: the cert is an
#    UNTRUSTED self-signed root (CSSMERR_TP_NOT_TRUSTED). That is expected and
#    does NOT stop codesign from signing with it.
# ---------------------------------------------------------------------------
say "Identities in $KEYCHAIN_NAME (CSSMERR_TP_NOT_TRUSTED is expected & harmless):"
security find-identity -p codesigning "$KEYCHAIN_NAME" || true

FPR="$(security find-certificate -c "$CN" -p "$KEYCHAIN_NAME" \
       | openssl x509 -noout -fingerprint -sha1 \
       | cut -d= -f2 | tr -d ':' | tr 'A-Z' 'a-z')"
say "DR anchor (sha1 of cert): $FPR"

# ---------------------------------------------------------------------------
# 6. Write the file the build reads. bundle/mkapp.sh sources this to find the
#    identity and to assert the requirement it must produce. Passwords live here
#    and nowhere else, so it is 0600 and outside the repo -- this project is
#    AGPL and public, and this key IS the app's permission identity.
# ---------------------------------------------------------------------------
if [ -f "$ENVFILE" ] && grep -q "CERT_SHA1=\"$FPR\"" "$ENVFILE" 2>/dev/null; then
  say "$ENVFILE already describes this identity, leaving it alone"
else
  umask 077
  cat > "$ENVFILE" <<EOF
# Kin code-signing identity -- WRITTEN BY tools/make-identity.sh, DO NOT COMMIT.
#
# macOS pins camera and microphone grants to the app's designated requirement.
# Signed with this certificate that requirement is
#     identifier "com.tokkah.tk" and certificate root = H"$FPR"
# which is byte-identical for every build, so grants survive self-updates.
# Ad-hoc signing instead yields cdhash H"..." -- a hash of the bundle contents,
# which changes every release and costs every user a fresh prompt each time.
#
# Losing or replacing this key re-prompts every existing user exactly once.
# Back up $P12_PATH somewhere durable.
KEYCHAIN_NAME="$KEYCHAIN_NAME"
KEYCHAIN_PW="$KEYCHAIN_PW"
P12_PATH="$P12_PATH"
P12_PW="$P12_PW"
CN="$CN"
ORG="$ORG"
CERT_SHA1="$FPR"
EOF
  chmod 600 "$ENVFILE"
  say "Wrote $ENVFILE (0600)"
fi

cat <<EOF

Sign with:
    codesign -s "$CN" -f --timestamp=none /path/to/Your.app

Expected designated requirement -- asserted by bundle/mkapp.sh every release,
because if it ever changes every user is re-prompted:
    identifier "com.tokkah.tk" and certificate root = H"$FPR"

Check with:
    codesign -dr - /path/to/Your.app
EOF
