#!/bin/bash
# ── READ THE TELEMETRY. FROM ANYWHERE, WITHOUT A BROWSER. ──────────────────
#
# Every beat this app collects used to live behind MAC_DASH_KEY (a cookie in one
# browser on one Mac) or LOG_ADMIN_TOKEN (a wrangler secret nothing can read
# back). A real complaint about a real call was investigated out of a stderr log
# because none of it could be opened. AGENT_KEY is the same operator read held
# in a FILE instead, and this is the front door to it.
#
#   tools/telemetry.sh recent [n]     the last calls, both ends, one line each
#   tools/telemetry.sh call <id>      every beat of one call
#   tools/telemetry.sh pair <id>      that call AND the other end of it
#   tools/telemetry.sh diagnose       what is wrong with the calls happening now
#   tools/telemetry.sh local          this Mac's own copy (no network needed)
set -u
KEYFILE="${TOKKAH_DASH_ENV:-$HOME/.config/tokkah/dash.env}"
BASE="${TOKKAH_BASE:-https://room.tokkah.com}"
LOCAL="$HOME/Library/Logs/Kin/beats.ndjson"
cmd="${1:-recent}"

if [ "$cmd" = "local" ]; then
  [ -f "$LOCAL" ] || { echo "no local beats yet at $LOCAL"; exit 2; }
  echo "$LOCAL  ($(wc -l < "$LOCAL" | tr -d ' ') beats, $(du -h "$LOCAL" | cut -f1))"
  exec python3 "$(dirname "$0")/telemetry.py" local "$LOCAL"
fi

# The key is never passed on a command line: it would land in the shell history
# and in `ps` output for every process on this Mac.
[ -f "$KEYFILE" ] || { echo "no key at $KEYFILE -- see mac/tools/telemetry.sh"; exit 2; }
. "$KEYFILE"
: "${TOKKAH_AGENT_KEY:?TOKKAH_AGENT_KEY not set in $KEYFILE}"

get() { curl -sS -G "$BASE/api/mac/$1" --data-urlencode "key=$TOKKAH_AGENT_KEY" "${@:2}"; }

case "$cmd" in
  recent)   get recent -d "limit=${2:-20}" | python3 "$(dirname "$0")/telemetry.py" recent ;;
  call)     get call -d "id=${2:?usage: telemetry.sh call <id>}" | python3 "$(dirname "$0")/telemetry.py" call ;;
  pair)     ID="${2:?usage: telemetry.sh pair <id>}"
            get recent -d "limit=60" > "${TMPDIR:-/tmp}/tk-recent.$$"
            for c in $(python3 "$(dirname "$0")/telemetry.py" pairids "$ID" < "${TMPDIR:-/tmp}/tk-recent.$$"); do
              echo "── $c"
              get call -d "id=$c" | python3 "$(dirname "$0")/telemetry.py" call
            done
            rm -f "${TMPDIR:-/tmp}/tk-recent.$$" ;;
  diagnose) get diagnose | python3 -m json.tool ;;
  *)        sed -n '2,12p' "$0"; exit 2 ;;
esac
