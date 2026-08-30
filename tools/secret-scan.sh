#!/bin/bash
# Is there a credential anywhere in this repository's history?
#
# "We checked" is not evidence, so this is the check, written down and runnable.
# It scans every commit on every branch, not just the working tree -- a secret
# that was committed and then deleted is still public forever.
#
#   bash tools/secret-scan.sh
#
# It CALIBRATES ITSELF FIRST. A scanner with a broken pattern reports the same
# clean sweep as a repository with nothing to find, and the two are impossible
# to tell apart from the output alone. So before scanning anything real it
# builds a throwaway repository, commits three known secrets, deletes them, and
# requires that all three are still found. If that arm fails, the scan does not
# run at all -- a blind instrument's negative is worth nothing.
set -u
cd "$(dirname "$0")/.." || exit 2
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

PAT='(-----BEGIN [A-Z ]*PRIVATE KEY-----|CLOUDFLARE_API_TOKEN[[:space:]]*[=:][[:space:]]*[A-Za-z0-9_-]{20,}|MAC_DASH_KEY[[:space:]]*[=:][[:space:]]*[A-Za-z0-9_/+=-]{12,}|(TOKKAH_)?AGENT_KEY[[:space:]]*[=:][[:space:]]*[A-Za-z0-9_/+=-]{12,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{32,}|eyJhbGciOi[A-Za-z0-9_-]{20,}|"?private_?key"?[[:space:]]*[=:][[:space:]]*"[A-Za-z0-9+/=]{40,}"|[Aa][Ww][Ss].{0,20}[Ss][Ee][Cc][Rr][Ee][Tt].{0,20}[=:][[:space:]]*[A-Za-z0-9/+=]{40})'

# THIS FILE CONTAINS FOUR FAKE SECRETS ON PURPOSE -- the calibration fixtures
# below. So it matches its own pattern, and would report itself forever. It is
# excluded from the real scan BY PATH, narrowly, and the count of matches inside
# it is printed rather than hidden: if that number is not exactly 4, something
# changed in here and you should look. Excluding a file from a secret scan is
# the kind of thing that goes wrong silently, so it is done out loud.
SELF="tools/secret-scan.sh"

scan_history() { git -C "$1" log -p --all --no-color 2>/dev/null | grep -cE "^\+.*$PAT"; }
scan_history_excl_self() {
  git -C "$1" log -p --all --no-color -- . ":(exclude)$SELF" 2>/dev/null | grep -cE "^\+.*$PAT"
}

# ---- calibration -----------------------------------------------------------
( cd "$TMP" && git init -q . \
  && printf 'CLOUDFLARE_API_TOKEN=abcdefghijklmnopqrstuvwxyz0123456789\n' > a.env \
  && printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEA\n-----END OPENSSH PRIVATE KEY-----\n' > id_ed25519 \
  && printf 'MAC_DASH_KEY: s3cr3t-dash-key-value-here\n' > c.yml \
  && printf 'TOKKAH_AGENT_KEY=planted-agent-key-not-a-real-one\n' > d.env \
  && git add -A && git -c user.email=a@b -c user.name=c commit -qm planted \
  && git rm -q a.env id_ed25519 c.yml d.env \
  && git -c user.email=a@b -c user.name=c commit -qm "deleted, but history keeps them" ) >/dev/null 2>&1
CAL=$(scan_history "$TMP")
if [ "${CAL:-0}" -lt 4 ]; then
  echo "CALIBRATION FAILED: planted 4 secrets, the scanner found $CAL."
  echo "Its patterns are broken. Refusing to scan -- a blind scan reports clean."
  exit 2
fi
echo "calibration: 4 planted secrets, $CAL found, and 0 left in the working tree.  OK"

# ---- the real scan ---------------------------------------------------------
COMMITS=$(git rev-list --all --count)
WT=$(git grep -InE "$PAT" -- . ":(exclude)$SELF" 2>/dev/null | wc -l | tr -d ' ')
HI=$(scan_history_excl_self .)
OWN=$(git grep -InE "$PAT" -- "$SELF" 2>/dev/null | wc -l | tr -d ' ')
echo "scanned: $COMMITS commits across every branch"
echo "  working tree matches: $WT"
echo "  history matches:      $HI"
echo "  (inside $SELF: $OWN -- its own fixtures, expected 4)"
if [ "$OWN" -ne 4 ]; then
  echo "  ^^ that is not 4. The fixtures in this file changed; read them."
fi

if [ "$WT" -eq 0 ] && [ "$HI" -eq 0 ]; then
  echo
  echo "CLEAN. No credential pattern in the working tree or in any commit."
  echo
  echo "Two things this does NOT claim, so that the claim it does make is worth"
  echo "something. It cannot see a secret that looks like ordinary text, and it"
  echo "is not a substitute for keeping secrets out in the first place: this"
  echo "project's signing keys live in ~/.config, outside the repository, and"
  echo "the maintainer additionally greps history for their literal bytes."
  echo "What IS in the open on purpose: the Ed25519 update public key"
  echo "(tools/README.md) and the signing certificate's root hash"
  echo "(mac/SIGNING.md). Both are public by construction -- a signature you"
  echo "cannot check against a published key proves nothing."
  exit 0
fi
echo; echo "*** MATCHES FOUND -- look at every one before pushing ***"
git grep -InE "$PAT" -- . ":(exclude)$SELF" 2>/dev/null | head -40
exit 1
