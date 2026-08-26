#!/bin/bash
# Is every file in this project's DISTRIBUTION licensed and attributed?
#
# The REUSE specification (https://reuse.software) answers that. This project
# declares licensing centrally in REUSE.toml rather than as a header in every
# source file -- the rights are identical, and the reasoning is written at the
# top of REUSE.toml.
#
#   bash tools/reuse-check.sh
#
# Why this wrapper exists instead of just `reuse lint`: run bare in a working
# directory, the linter walks node_modules/ and .build/ too and reports missing
# license texts for every dependency's MIT and Apache-2.0 -- a failure about
# somebody else's code, in files no one ever receives from us. Measured here:
# 2229 files scanned against 470 tracked. So this exports exactly what a
# stranger gets -- tracked files plus anything new that is not gitignored -- and
# lints that.
set -u
cd "$(dirname "$0")/.." || exit 2
command -v uvx >/dev/null || { echo "needs uvx (https://docs.astral.sh/uv/) or a 'reuse' on PATH"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LIST="$TMP/files.txt"
# `-f` and not just the listing: a file staged as deleted is still named by
# ls-files, and rsync aborts the whole transfer on the first one it cannot stat.
git ls-files --cached --others --exclude-standard | while IFS= read -r f; do
  [ -f "$f" ] && printf '%s\n' "$f"
done > "$LIST"
echo "exporting $(wc -l < "$LIST" | tr -d ' ') distributed files"
rsync -a --files-from="$LIST" . "$TMP/tree/" || exit 2
( cd "$TMP/tree" && git init -q . && git add -A ) >/dev/null 2>&1

cd "$TMP/tree" || exit 2
uvx --with charset-normalizer reuse lint
