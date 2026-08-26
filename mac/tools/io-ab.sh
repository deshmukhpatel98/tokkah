#!/bin/bash
# What does the echo canceller COST, in milliseconds?
#
# The field said `aec_on 0` and `output_route speakers` on every reported call,
# which means every call this app has ever made had an open acoustic path from
# the speaker to the microphone with nothing behind it. The fix is to run
# Apple's VoiceProcessingIO whenever the sound leaves into a room. The comment
# above `ioKind` says what that costs -- "what it costs is latency, and this
# project's whole point is latency" -- and until now the number was an argument
# rather than a measurement.
#
#   bash mac/tools/io-ab.sh [seconds-per-arm]
#
# Both ends local, both `--mute`, no telemetry, no identity, no login item.
# This CANNOT measure whether the echo is gone: both ends are one machine and
# the mic is muted, so there is no acoustic path to cancel. It measures the
# price, which is the half of the decision that does not need two rooms.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

SECS="${1:-30}"
HERE="$PWD"
TK="$HERE/.build/release/tk"

echo "== building the binary under test =="
if ! swift build -c release --product tk >/dev/null 2>&1; then
  echo "BUILD FAILED"; swift build -c release --product tk 2>&1 | grep -E "error:" | head -5; exit 2
fi
NEWER=$(find Sources -name '*.swift' -newer "$TK" 2>/dev/null | head -3)
if [ -n "$NEWER" ]; then
  echo "STALE BINARY -- newer sources after a build:"; echo "$NEWER" | sed 's/^/    /'; exit 2
fi
echo "  $TK is current with Sources/"

SP="${SCRATCH:-${TMPDIR:-/tmp}}/io-ab.$$"
mkdir -p "$SP/kin"
# Never the real identity, never the real login item, never the real dir.
export TK_NO_IDENTITY=1
export TK_KIN_DIR="$SP/kin"
PIDS=""
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
trap 'reap; rm -rf "$SP"' EXIT

# --mute is the RIG's flag: the machine's speakers belong to whoever is sitting
# at it. Recorded here because forgetting it once made a rig ring out loud.
COMMON=(--video off --mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles)

# One arm: two local ends, both pinned to the same io, for SECS seconds.
# Returns the LAST m2e p50 printed, not the first: m2e descends for the first
# ~20 s while the jitter buffer sizes itself, and reading it early measures the
# warm-up instead of the steady state.
run_arm() {                     # $1 = io kind, $2 = label, $3 = base port
  local io="$1" label="$2" p="$3"
  local R="ioab$$$p"
  "$TK" "${COMMON[@]}" --io "$io" --room "$R" --listen "$p"       --peer "127.0.0.1:$((p+1))" \
        > "$SP/$label.a.log" 2>&1 & PIDS="$PIDS $!"
  "$TK" "${COMMON[@]}" --io "$io" --room "$R" --listen "$((p+1))" --peer "127.0.0.1:$p" \
        > "$SP/$label.b.log" 2>&1 & PIDS="$PIDS $!"
  perl -e "select undef,undef,undef,$SECS"
  reap
  # Prove the arm ran the io it is NAMED after. An arm that silently fell back
  # to the other unit would produce a number and a conclusion, both wrong.
  local said
  said=$(grep -m1 -oE '^\[io\] (VoiceProcessingIO|HAL)' "$SP/$label.a.log" | awk '{print $2}')
  local want; [ "$io" = "vp" ] && want="VoiceProcessingIO" || want="HAL"
  if [ "$said" != "$want" ]; then
    echo "  $label: ARM DID NOT RUN $want -- log says '${said:-nothing}'"
    return 1
  fi
  local m2e stages
  m2e=$(grep -oE 'm2e p50 [0-9.]+' "$SP/$label.a.log" | tail -1 | awk '{print $3}')
  stages=$(grep -oE 'stages: .*' "$SP/$label.a.log" | tail -1)
  [ -n "$m2e" ] || { echo "  $label: no m2e in the log"; return 1; }
  printf '  %-10s io=%-18s m2e p50 %6.2f ms\n' "$label" "$said" "$m2e"
  echo "$m2e" > "$SP/$label.m2e"
  echo "      $stages" | cut -c1-150
  return 0
}

echo "== ${SECS}s per arm, alternating order so a drift in the machine cannot"
echo "   be read as a difference between the arms =="
bad=0
run_arm hal hal-1 7501 || bad=1
run_arm vp  vp-1  7511 || bad=1
run_arm vp  vp-2  7521 || bad=1
run_arm hal hal-2 7531 || bad=1
[ "$bad" -eq 0 ] || { echo; echo "IO A/B FAILED -- an arm did not run what it claimed"; exit 1; }

python3 - "$SP" <<'PY'
import sys, os
sp = sys.argv[1]
def v(n):
    with open(os.path.join(sp, n + ".m2e")) as f: return float(f.read().strip())
h = [v("hal-1"), v("hal-2")]
p = [v("vp-1"),  v("vp-2")]
hm, pm = sum(h)/2, sum(p)/2
noise = abs(h[0] - h[1])
delta = pm - hm
print()
print(f"  hal : {h[0]:6.2f}  {h[1]:6.2f}   mean {hm:6.2f} ms")
print(f"  vp  : {p[0]:6.2f}  {p[1]:6.2f}   mean {pm:6.2f} ms")
print()
# The null first. Two arms of the SAME thing disagree by some amount; an effect
# smaller than that disagreement is not an effect, it is the machine.
print(f"  rig noise (hal vs hal) : {noise:5.2f} ms")
print(f"  effect    (vp  -  hal) : {delta:+5.2f} ms")
if abs(delta) <= noise:
    print(f"  -> the canceller costs LESS than this rig can measure ({noise:.2f} ms of noise)")
else:
    print(f"  -> the canceller costs {delta:+.2f} ms, which is {abs(delta)/max(noise,0.01):.1f}x the noise")
print()
print("  Budget: the goal is 150 ms mouth-to-ear anywhere on earth. Both arms are")
print(f"  local, so this is the floor, not a call: the question is only whether")
print(f"  {delta:+.2f} ms is worth an echo canceller on every call made on speakers.")
PY
echo
echo "IO A/B DONE"
