#!/bin/bash
# ── CAN PEOPLE REACH THIS MAC WHEN KIN IS CLOSED, AND CAN YOU TELL? ─────────
#
# It was already automatic -- an installed copy writes its own login item every
# launch -- and then it did not work on somebody's second Mac. From inside the
# app there was no way to find that out: the only report was `--watch-status`,
# in a terminal, saying "plist present, launchd running". A feature whose whole
# promise is "people can reach you" has to say on the screen whether they can.
#
# Four claims, and the third is the one a dead control passes the first two of:
#   1. the panel carries the row, and it reads OFF when nothing is installed
#   2. a real click on it turns it on -- through launchd, not a flag in memory
#   3. and the row then reads ON, so the readout follows the world
#   4. clicking again turns it off. A switch that only goes one way is a button.
#
# ── IT MUST NOT TOUCH THE REAL LOGIN ITEM ──────────────────────────────────
# Same label means the same launchd job, so a rig using the default label would
# bootout the user's own watcher and leave their Mac unreachable. TK_WATCH_LABEL
# gives this run its own, and the trap removes it however the script ends.
set -u
# Ring windows do not throw themselves in front of whatever the person at this
# Mac is doing. That behaviour is right for a phone and is proved in
# firstrun-ring-check; here it only means their taps land on cards they cannot
# see, which made this rig's verdict depend on whether anybody touched the
# trackpad while it ran.
export TK_NO_RAISE=1
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/watch-check.$$"
LABEL="com.tokkah.tk.watchrig$$"
mkdir -p "$SP"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
export TK_WATCH_LABEL="$LABEL" TK_WATCH_ANYWHERE=1 TK_KIN_DIR="$SP/id"
cleanup() {
  reap
  /bin/launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
  [ -n "${KEEP:-}" ] || rm -rf "$SP"
}
trap cleanup EXIT
# Start from nothing, or claim 1 is measuring a leftover.
/bin/launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"

# `?` -> `@more` -> `?` -> click the row -> `?` -> click again -> `?`
# The row's index is not knowable before the panel is built, so the presses are
# split across two launches: the first one reads it, the second one uses it.
spawn "$TK" --window --video off --mute --no-telemetry --no-update --no-relocate \
      --no-subtitles --no-rings --listen 8061 --room "watchchk$$" \
      --press-after 3 --press "@more,?" > "$SP/a.log" 2>&1
perl -e 'select undef,undef,undef,8'
reap

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }
grep -q "^tk " "$SP/a.log" || { echo "WATCH CHECK COULD NOT RUN -- tk never started:"; sed -n '1,6p' "$SP/a.log" | sed 's/^/  /'; exit 2; }

# ── ONLY THE `?` DUMPS COUNT ────────────────────────────────────────────────
# Every click ALSO prints the tree, on its way out, before anything it started
# has finished. Reading those as state made this rig report a switch that never
# flipped -- the readout was right and the ruler was off by one press.
sheets() { grep -A2 '^audit state' "$1" | grep -o 'sheet=settings\[[^]]*\]'; }
SHEET=$(sheets "$SP/a.log" | head -1)
echo "  panel: ${SHEET:-<no panel>}"
case "$SHEET" in
  *"Calls when Kin is closed"*) say "OK" "the panel carries the row" ;;
  *) say "FAIL" "the row is not in the panel at all" ;;
esac
case "$SHEET" in
  *"Calls when Kin is closed ✓"*) say "FAIL" "it reads ON with nothing installed" ;;
  *"Calls when Kin is closed"*)   say "OK" "and it reads OFF, which is the truth here" ;;
  *) ;;
esac
# Which row it is, counted the way clickTargets numbers them.
IDX=$(printf '%s' "$SHEET" | sed 's/^sheet=settings\[//; s/\]$//' | awk -F' \\| ' '{for(i=1;i<=NF;i++) if ($i ~ /Calls when Kin is closed/) print i-1}')
[ -n "$IDX" ] || { echo "WATCH CHECK COULD NOT RUN -- no row index"; exit 2; }
echo "  it is row#$IDX"

# ── ON, then OFF, through real clicks ──────────────────────────────────────
spawn "$TK" --window --video off --mute --no-telemetry --no-update --no-relocate \
      --no-subtitles --no-rings --listen 8061 --room "watchchk$$" \
      --press-after 3 --press "@more,?,@row#$IDX,?,?,?,?,@row#$IDX,?,?" \
      > "$SP/b.log" 2>&1
perl -e 'select undef,undef,undef,18'
reap

# launchctl's own answer, taken while the second process was still up, is not
# available after the fact -- so the app's word is checked against the plist,
# which is the half that outlives it.
grep -q "watch: asked from the panel -- .*installed" "$SP/b.log" \
  && say "OK" "the click really ran the install, not a flag in memory" \
  || say "FAIL" "clicking the row did not install anything: $(grep -c 'asked from the panel' "$SP/b.log") attempts"
# Second and third `?` bracket the install; the readout must have flipped.
# The LAST reading before the second click, not the Nth. Two launchctl spawns
# take as long as this Mac is busy, and a fixed index read the panel mid-install
# on a loaded machine -- a rig whose verdict depends on how busy the host is.
CUT=$(grep -n 'press @row#' "$SP/b.log" | sed -n '2p' | cut -d: -f1)
AFTER=$(head -n "${CUT:-99999}" "$SP/b.log" | grep -A2 '^audit state' | grep -o 'sheet=settings\[[^]]*\]' | tail -1)
echo "  after the click: ${AFTER:-<nothing>}"
case "$AFTER" in
  *"Calls when Kin is closed ✓"*) say "OK" "and the row now reads ON" ;;
  *) say "FAIL" "the world changed and the row did not" ;;
esac
LAST=$(sheets "$SP/b.log" | tail -1)
echo "  after the second: ${LAST:-<nothing>}"
case "$LAST" in
  *"Calls when Kin is closed ✓"*) say "FAIL" "clicking it again did not turn it off" ;;
  *"Calls when Kin is closed"*)   say "OK" "and clicking it again turns it off" ;;
  *) say "FAIL" "the row vanished" ;;
esac
[ -f "$HOME/Library/LaunchAgents/$LABEL.plist" ] \
  && say "FAIL" "the login item was left behind after turning it off" \
  || say "OK" "and nothing is left behind on disk"

[ "$fail" = "0" ] && echo "WATCH CHECK: PASS" || echo "WATCH CHECK: FAIL"
exit "$fail"
