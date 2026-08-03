#!/usr/bin/env bash
#
# phone-test.sh — one command, zero human input: run the task #37 camera
# measurement on the real Android phone over USB and print a verdict.
#
#   ./phone-test.sh                     default arm (ladder + low-light + revive on)
#   ./phone-test.sh --arm=control       ?ladder=0&lowlight=0&revive=0 — the honest control
#   ./phone-test.sh --sweep             exposure sweep (?llexp=) to find the best trade
#   ./phone-test.sh --url=https://room.tokkah.com   measure prod instead of dev
#   ./phone-test.sh --secs=90           longer soak (default 75 s)
#
# EXIT CODES ARE THE POINT. A harness that reports "failed" without saying
# WHICH failure wastes the next session's first twenty minutes, so every
# pre-flight failure has its own code and its own one-line remedy:
#
#   10  adb not installed
#   11  no device attached          (cable / USB mode / phone powered off)
#   12  device attached but UNAUTHORIZED  (confirm the RSA prompt on screen)
#   13  device offline              (replug; adb sees it but cannot talk to it)
#   14  more than one device        (set ANDROID_SERIAL=…)
#   20  dev server not reachable    (npm run dev in tape-app, or pass --url=)
#   21  adb reverse failed          (phone cannot reach the Mac's port)
#   30  no Chrome DevTools socket   (open Chrome on the phone once, then retry)
#   40  the drive itself failed     (see the driver's own message)
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="${PKG:-com.android.chrome}"
PORT="${PORT:-8794}"
CDP_PORT="${CDP_PORT:-9222}"
URL="http://127.0.0.1:${PORT}"
ARM="default"
SECS="75"
SWEEP=""

for a in "$@"; do
  case "$a" in
    --url=*)  URL="${a#*=}" ;;
    --arm=*)  ARM="${a#*=}" ;;
    --secs=*) SECS="${a#*=}" ;;
    --sweep)  SWEEP="1" ;;
    --pkg=*)  PKG="${a#*=}" ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "phone-test: unknown argument $a" >&2; exit 2 ;;
  esac
done

say() { printf '  %s\n' "$*"; }
die() { printf '\n  ✗ %s\n    → %s\n' "$1" "$2" >&2; exit "$3"; }

echo
echo "phone-test — real device, real camera, no human in the loop"
echo

# ── 1. adb and exactly one healthy device ────────────────────────────────────
command -v adb >/dev/null 2>&1 || die "adb is not installed" "brew install --cask android-platform-tools" 10

adb start-server >/dev/null 2>&1 || true
# `adb devices` prints one "serial<TAB>state" line per device after a header.
DEVLINES="$(adb devices | tail -n +2 | grep -v '^\s*$' || true)"
COUNT="$(printf '%s\n' "$DEVLINES" | grep -c . || true)"

if [ "$COUNT" -eq 0 ]; then
  die "no Android device is attached over USB" \
      "plug the phone in, unlock it, and set the USB mode to 'File transfer / Android Auto' (charging-only hides adb)" 11
fi

if [ -n "${ANDROID_SERIAL:-}" ]; then
  SERIAL="$ANDROID_SERIAL"
elif [ "$COUNT" -gt 1 ]; then
  printf '%s\n' "$DEVLINES" >&2
  die "$COUNT devices attached — ambiguous" "re-run with ANDROID_SERIAL=<serial> ./phone-test.sh" 14
else
  SERIAL="$(printf '%s\n' "$DEVLINES" | awk '{print $1}')"
fi
STATE="$(printf '%s\n' "$DEVLINES" | awk -v s="$SERIAL" '$1==s {print $2}')"

case "$STATE" in
  device) : ;;
  unauthorized) die "device $SERIAL is UNAUTHORIZED" \
      "unlock the phone and tap 'Allow' on the 'Allow USB debugging?' prompt (tick 'always allow')" 12 ;;
  offline) die "device $SERIAL is OFFLINE" \
      "unplug and replug the cable; if it persists, toggle Developer options → USB debugging" 13 ;;
  *) die "device $SERIAL is in state '$STATE'" "expected 'device' — see 'adb devices -l'" 13 ;;
esac

MODEL="$(adb -s "$SERIAL" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
REL="$(adb -s "$SERIAL" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
say "device    $SERIAL — $MODEL, Android $REL"

# ── 2. the page under test must actually be reachable ────────────────────────
if [ "${URL#http://127.0.0.1}" != "$URL" ] || [ "${URL#http://localhost}" != "$URL" ]; then
  curl -fsS -o /dev/null --max-time 5 "$URL/" \
    || die "dev server not answering at $URL" "run: cd tape-app && npm run dev   (or pass --url=https://…)" 20
  # The phone resolves 127.0.0.1 as ITSELF — reverse maps the Mac's port onto it.
  adb -s "$SERIAL" reverse "tcp:${PORT}" "tcp:${PORT}" >/dev/null \
    || die "adb reverse tcp:${PORT} failed" "another adb client may own the port; try 'adb reverse --remove-all'" 21
  say "reverse   phone:${PORT} → mac:${PORT}"
else
  say "target    $URL (remote — no reverse needed)"
fi

# ── 3. camera + mic, granted up front so no dialog can block the run ─────────
for p in android.permission.CAMERA android.permission.RECORD_AUDIO; do
  adb -s "$SERIAL" shell pm grant "$PKG" "$p" >/dev/null 2>&1 || true
done
say "granted   camera + microphone to $PKG"

# ── 4. Chrome and its DevTools socket ────────────────────────────────────────
# Launch Chrome at a BARE url only. `am start` goes through the device shell,
# which eats '&' — every query parameter after the first would be silently
# dropped. The driver navigates with the real URL over CDP instead.
adb -s "$SERIAL" shell am start -a android.intent.action.VIEW -d "about:blank" "$PKG" >/dev/null 2>&1 || true

adb -s "$SERIAL" forward --remove "tcp:${CDP_PORT}" >/dev/null 2>&1 || true
adb -s "$SERIAL" forward "tcp:${CDP_PORT}" localabstract:chrome_devtools_remote >/dev/null \
  || die "could not forward the Chrome DevTools socket" "open Chrome on the phone once, then re-run" 30

for i in $(seq 1 20); do
  if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:${CDP_PORT}/json/version"; then break; fi
  [ "$i" -eq 20 ] && die "Chrome DevTools did not answer on ${CDP_PORT}" \
      "check chrome://inspect on the Mac; make sure Chrome is in the foreground and unlocked" 30
  sleep 0.5
done
BROWSER="$(curl -fsS "http://127.0.0.1:${CDP_PORT}/json/version" | sed -n 's/.*"Browser": *"\([^"]*\)".*/\1/p')"
say "chrome    $BROWSER (CDP on ${CDP_PORT})"

# Keep the screen on and dimmed for the duration — a locked screen suspends the
# camera and every number afterwards is a measurement of nothing.
adb -s "$SERIAL" shell svc power stayon usb >/dev/null 2>&1 || true

echo
exec node "$HERE/testbed/phone-drive.mjs" \
  --cdp="http://127.0.0.1:${CDP_PORT}" \
  --url="$URL" \
  --arm="$ARM" \
  --secs="$SECS" \
  ${SWEEP:+--sweep}
