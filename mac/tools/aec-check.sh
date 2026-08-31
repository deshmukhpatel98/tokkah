#!/bin/bash
# ── THE CANCELLER, THROUGH THE REAL AUDIO DEVICE ────────────────────────────
#
# `tk --aec-test` drives `Aec` directly with a synthetic loop and is where the
# constants come from. It cannot see anything that only happens in the product:
# the real CoreAudio callback and its SIXTEEN-sample blocks, the real
# `emitHist`/`echoHist` pair, the real estimator aiming the filter from a real
# correlation rather than from a number the rig handed it, and the floor deciding
# whether this end's speaker is even on.
#
# Every one of those has broken something in this project before. A classifier
# whose smoothing constants were tuned at a 128-sample rig block ran eight times
# too fast on the machine's 16 and could never fire; a rig that chose its own
# block size could not see it (`rig-picks-a-parameter-the-product-does-not`).
#
# So this runs two real ends of a real call, with a real echo path in software,
# and reads the number the product itself prints once a second.
#
#   tools/aec-check.sh [seconds]
#
# WHAT IT CANNOT DO, said here rather than discovered later: both ends share this
# machine's one speaker and one microphone, so the echo path is SIMULATED
# (`--echo-sim`) and there is no loudspeaker nonlinearity in it -- which is
# exactly the part a linear filter cannot cancel. This proves the code path and
# the arithmetic. Only a two-room call proves the sound (`same-room-is-a-test-artifact`).
set -u
cd "$(dirname "$0")/.."
# Overridable so the SHIPPED binary can be run through this rig, not just the one
# on this desk. A release verified by testing the build directory has verified the
# build directory (`verify-deploy-by-parsing-prod`).
TK="${TK:-./.build/release/tk}"
[ -x "$TK" ] || { echo "build first: swift build -c release"; exit 2; }
SECS="${1:-30}"
SP="$(mktemp -d)"
R="aec$$"
PIDS=""
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
trap 'reap; rm -rf "$SP"' EXIT

# --mute because the machine's speakers belong to whoever is sitting at it, and
# the echo path this rig cares about is the simulated one either way.
COMMON=(--video off --mute --no-telemetry --no-update --no-relocate --no-rings
        --no-subtitles --no-floor)
# 22 ms and 0.55: a laptop's own speaker to its own microphone, which is the
# case the whole feature is for.
ECHO="22:0.55"

# `--no-floor` above is deliberate and it is the point: with the floor in force,
# strict closes the holder's ear, so the speaker emits nothing, so there is no
# echo for the canceller to work on -- the rig would measure the FLOOR and report
# it as the canceller doing nothing. The floor has its own rig (`--turn-test`).
# End A's own voice. The default is a real recording, so both ends talk almost
# continuously -- which is the STRESS case and not a conversation
# (`TurnRig.envelope` writes down why). `AVOICE=silence` makes A a listener, which
# is the far-only case: A's microphone then contains nothing but the echo of B,
# and that is the arm where an echo canceller has to score its headline number.
# Both are run, because a canceller judged only on the easy one is a canceller
# nobody has tested.
run() {                        # $1 = label, $2 = extra args...
  local label="$1"; shift
  "$TK" "${COMMON[@]}" "$@" --room "${R}${label}" --listen 7411 \
        --peer 127.0.0.1:7412 --audio "$AVOICE" \
        --echo-sim "$ECHO" > "$SP/$label.a.log" 2>&1 & PIDS="$PIDS $!"
  "$TK" "${COMMON[@]}" "$@" --room "${R}${label}" --listen 7412 \
        --peer 127.0.0.1:7411 --audio testbed/media/real/realB.wav \
        --echo-sim "$ECHO" > "$SP/$label.b.log" 2>&1 & PIDS="$PIDS $!"
  perl -e "select undef,undef,undef,$SECS"
  reap
}

echo "AEC LIVE CHECK  two real ends, ${SECS}s, echo path $ECHO simulated"
echo

# A silent A: 480 000 zero samples, which is a listener.
AVOICE="$SP/silence.wav"
python3 - "$AVOICE" <<'PY'
import struct, sys
n = 48000 * 30
d = b"\x00\x00" * n
h = (b"RIFF" + struct.pack("<I", 36 + len(d)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 48000, 96000, 2, 16)
     + b"data" + struct.pack("<I", len(d)))
open(sys.argv[1], "wb").write(h + d)
PY

# ── AND IT IS READ AS A DISTRIBUTION, NOT AS THE LAST LINE ──────────────────
#
# The first version of this took the LAST `echo:` line, which is the leaky ERLE at
# the instant the process was killed -- and the same binary read 16 dB on one run
# and 5 dB on the next, with the difference being entirely which syllable the kill
# happened to land on. A birth certificate rather than a health record, for the
# third time in this feature (`once-fired-probes-record-transients`).
#
# Every second of the call, then: the best the filter reached and the median it
# held. The median is the honest one; the best says whether it can converge at all.
lines_for() { grep -E '^  echo:' "$1" | sed -E 's/.*echo: (-?[0-9]+) dB removed.*/\1/'; }
stat_of() {                      # $1 = file, $2 = best|p50|n
  python3 - "$1" "$2" <<'PY'
import sys, re
vals = []
for ln in open(sys.argv[1], errors="replace"):
    m = re.match(r"\s*echo: (-?\d+) dB removed", ln)
    if m: vals.append(int(m.group(1)))
if not vals: print("none"); raise SystemExit
vals.sort()
print({"best": vals[-1], "p50": vals[len(vals)//2], "n": len(vals)}[sys.argv[2]])
PY
}

fail=0
for arm in on off; do
  if [ "$arm" = off ]; then run "$arm" --no-aec; else run "$arm"; fi
  for e in a b; do
    line="$(grep -E '^  echo:' "$SP/$arm.$e.log" | tail -1)"
    if [ -z "$line" ]; then
      if [ "$arm" = off ]; then
        echo "  --no-aec  end $e: silent, as it must be"
      else
        echo "  aec on    end $e: NO ECHO LINE AT ALL -- the canceller never ran"
        echo "$(tail -3 "$SP/$arm.$e.log" | sed 's/^/      /')"
        fail=1
      fi
    else
      if [ "$arm" = off ]; then
        echo "  --no-aec  end $e: REPORTED A LINE, so the control arm is not a control"
        echo "     $line"
        fail=1
      else
        printf "  aec on    end %s: best %s dB  p50 %s dB  over %s seconds\n" \
          "$e" "$(stat_of "$SP/$arm.$e.log" best)" \
          "$(stat_of "$SP/$arm.$e.log" p50)" "$(stat_of "$SP/$arm.$e.log" n)"
        echo "     last:$line"
      fi
    fi
  done
done

# ── AND THE BAR GOES ON THE MEDIAN, BECAUSE THE PEAK IS THE NOISY ONE ────────
#
# Three runs of one unchanged binary (`measure-the-rigs-noise-first`, done before
# believing any of this):
#
#              best   p50
#     run 1      9      6
#     run 2     36      9
#     run 3     32     10
#
# The peak swings by a factor of four and the median moves by 4 dB. So the bar is
# the median at 4 dB, and the peak is printed as information rather than asserted.
#
# THE GAP IS THE INTERESTING PART AND IT IS NOT THE FILTER. `--aec-test` gets 19 dB
# steadily on the same room; here the filter reaches 32-36 dB and then falls back to
# single digits, over and over. That shape is not a filter failing to converge, it
# is a filter converging and then losing its target: the capture and render streams
# are two independent device clocks, and the echo arrives at an offset that drifts
# between them while this rig injects it at a fixed integer delay. Tens of parts per
# million is tens of samples over twenty seconds, and the render-thread cursor jitters
# by up to a block on top of that.
#
# So the next thing worth doing to this canceller is not more taps or a different
# step -- it is tracking that alignment (a fractional delay, re-estimated
# continuously) instead of assuming it holds. Written down here rather than guessed
# at later.
best=0; p50=-99
for e in a b; do
  v="$(stat_of "$SP/on.$e.log" best)"
  case "$v" in ''|none|*[!0-9-]*) v=0 ;; esac
  [ "$v" -gt "$best" ] && best="$v"
  m="$(stat_of "$SP/on.$e.log" p50)"
  case "$m" in ''|none|*[!0-9-]*) m=-99 ;; esac
  [ "$m" -gt "$p50" ] && p50="$m"
done
echo
if [ "$p50" -ge 4 ]; then
  echo "  through the real device: p50 ${p50} dB, peak ${best} dB -- PASS"
else
  echo "  through the real device: p50 ${p50} dB, peak ${best} dB -- FAIL (want p50 >= 4)"
  fail=1
fi
[ "$fail" = 0 ] && echo "AEC LIVE CHECK PASSED" || echo "AEC LIVE CHECK FAILED"
exit "$fail"
