#!/usr/bin/env bash
#
# emu-boot.sh — boot the Android emulator headless and leave Chrome reachable
# over CDP on 127.0.0.1:9223, camera+mic pre-granted. Idempotent: re-running
# against a booted emulator just refreshes the forward and exits 0.
#
# The emulator lane tests HALF of Android — real Android Chrome, real Android
# audio path, real lifecycle — from this Mac with no cable. The camera here is
# the emulator's virtual scene: fine for "does video flow", useless for sensor
# physics (exposure pinning, HAL death). Those stay on real silicon via the
# lab channel.
#
#   ./testbed/emu-boot.sh          boot (or reuse) + prepare Chrome
#   ./testbed/emu-boot.sh --stop   shut the emulator down
set -euo pipefail

SDK="$HOME/android-sdk"
ADB="$SDK/platform-tools/adb"
EMU="$SDK/emulator/emulator"
AVD="tokkah-a35"
CDP_PORT="${CDP_PORT:-9223}"   # 9222 is the real phone's port; never collide
PKG="com.android.chrome"

say() { printf '  %s\n' "$*"; }
die() { printf '\n  x %s\n' "$1" >&2; exit "${2:-1}"; }

[ -x "$ADB" ] || die "no adb at $ADB — run scratchpad/android-setup.sh first" 10
[ -x "$EMU" ] || die "no emulator at $EMU — run scratchpad/android-setup.sh first" 10

if [ "${1:-}" = "--stop" ]; then
  "$ADB" -s emulator-5554 emu kill >/dev/null 2>&1 || true
  say "emulator stopped"
  exit 0
fi

# ── 1. boot, unless already up ────────────────────────────────────────────────
if ! "$ADB" devices | grep -q "^emulator-5554[[:space:]]*device"; then
  say "booting $AVD headless"
  nohup "$EMU" -avd "$AVD" -no-window -no-audio -no-boot-anim \
    -camera-back virtualscene -camera-front emulated \
    > /tmp/tokkah-emu.log 2>&1 &
  "$ADB" wait-for-device
fi
say "waiting for sys.boot_completed"
for i in $(seq 1 120); do
  [ "$("$ADB" -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
  sleep 2
  [ "$i" = "120" ] && die "emulator never finished booting (see /tmp/tokkah-emu.log)" 11
done
say "booted"

# ── 2. Chrome: app permissions, first-run skip, one warm start ────────────────
for p in android.permission.CAMERA android.permission.RECORD_AUDIO; do
  "$ADB" -s emulator-5554 shell pm grant "$PKG" "$p" >/dev/null 2>&1 || true
done
# Chrome honors /data/local/tmp/chrome-command-line only for the debug app.
"$ADB" -s emulator-5554 shell am set-debug-app --persistent "$PKG" >/dev/null 2>&1 || true
"$ADB" -s emulator-5554 shell "echo '_ --disable-fre --no-default-browser-check --no-first-run' > /data/local/tmp/chrome-command-line" || true
"$ADB" -s emulator-5554 shell am force-stop "$PKG" || true
"$ADB" -s emulator-5554 shell am start -n "$PKG/com.google.android.apps.chrome.Main" -d "about:blank" >/dev/null
sleep 4

# ── 3. CDP forward ────────────────────────────────────────────────────────────
"$ADB" -s emulator-5554 forward --remove "tcp:${CDP_PORT}" >/dev/null 2>&1 || true
"$ADB" -s emulator-5554 forward "tcp:${CDP_PORT}" localabstract:chrome_devtools_remote \
  || die "could not forward Chrome's DevTools socket" 30
curl -fsS "http://127.0.0.1:${CDP_PORT}/json/version" | head -c 200 && echo
say "READY — Android Chrome on http://127.0.0.1:${CDP_PORT}"
