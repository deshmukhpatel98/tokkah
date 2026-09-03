#!/bin/bash
# ── DOES CALL RECORDING CAPTURE THE REAL PLAYOUT PATH? ──────────────────────
#
# A normal recording on device records local camera and mic before network transmission,
# completely hiding what actually happened during the call.
#
# Kin's call recording captures the PLAYOUT path in real time:
#   - Decoded video frames as they reach the screen
#   - Decoded audio samples with concealment/breaks as fed to CoreAudio playback buffer
#   - If voice breaks or frames drop, the recording captures that exact glitchy sequence.
#
# Real processes, real UDP, real video/audio media.
set -u
export TK_NO_RAISE=1 TK_NO_IDENTITY=1
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
reap() {
  for p in $PIDS; do kill -TERM "$p" 2>/dev/null; done
  for p in $PIDS; do
    for i in $(seq 1 40); do
      kill -0 "$p" 2>/dev/null || break
      perl -e 'select undef,undef,undef,0.1'
    done
    kill -9 "$p" 2>/dev/null
  done
  wait 2>/dev/null
  PIDS=""
}
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/record-check.$$"
mkdir -p "$SP"
export TK_KIN_DIR="$SP/kin"
mkdir -p "$SP/kin"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT

echo "scratch: $SP"

# Ensure ffmpeg is available
FFMPEG="$(command -v ffmpeg || echo "/Users/deveshpatel/.local/bin/ffmpeg")"
[ -x "$FFMPEG" ] || { echo "no ffmpeg found"; exit 2; }

# Generate test moving video (1280x720 @ 30 fps)
MEDIA="$SP/test_video.mp4"
"$FFMPEG" -y -f lavfi -i "testsrc2=s=1280x720:r=30" -t 15 -c:v libx264 -pix_fmt yuv420p \
       -b:v 3M "$MEDIA" >/dev/null 2>&1

# Test audio sample
AUDIO="$HERE/../../testbed/media/real/realA.wav"
[ -f "$AUDIO" ] || { echo "no audio sample at $AUDIO"; exit 2; }

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }

BASE="--mute --no-telemetry --no-update --no-relocate --no-rings --no-subtitles --no-rejoin"

# ── ARM 1: Call recording under network loss (10% drop) ────────────────────────
# Injected packet drop causes video frame stalls/repeats and audio concealment/breaks.
# The recording must capture both the repeated frames and the concealed audio.
R1="recchk1$$"
REC1="$SP/call_drops.mov"
echo "── ARM 1: recording under network impairment (10% drop) ──"
# Leg A: sender impaired by packet loss
spawn "$TK" --room "$R1" --listen 7931 --peer 127.0.0.1:7932 --video "$MEDIA" --audio "$AUDIO" $BASE --imp-drop 10 > "$SP/a1.log" 2>&1
# Leg B: receiver recording the playout path
spawn "$TK" --room "$R1" --listen 7932 --peer 127.0.0.1:7931 --video off $BASE \
      --record "$REC1" > "$SP/b1.log" 2>&1

perl -e 'select undef,undef,undef,6.0'
reap

# Verify recording 1 exists
if [ -f "$REC1" ] && [ -s "$REC1" ]; then
  say "PASS" "Arm 1: output file created ($REC1, $(wc -c < "$REC1" | tr -d ' ') bytes)"
else
  say "FAIL" "Arm 1: output file missing or empty"
fi

# Verify container streams and decodability with ffmpeg
INFO1="$("$FFMPEG" -i "$REC1" 2>&1)"
if echo "$INFO1" | grep -q "Video: h264.*1280x720"; then
  say "PASS" "Arm 1: video track is H.264 1280x720"
else
  say "FAIL" "Arm 1: video track missing or incorrect"
fi

if echo "$INFO1" | grep -q "Audio: aac.*48000 Hz, mono"; then
  say "PASS" "Arm 1: audio track is AAC 48000 Hz mono"
else
  say "FAIL" "Arm 1: audio track missing or incorrect"
fi

# Full container decoding test (ensure no corrupted frames / moov atom)
if "$FFMPEG" -v error -i "$REC1" -f null - > "$SP/dec1.err" 2>&1; then
  say "PASS" "Arm 1: movie file is 100% valid and decodable"
else
  say "FAIL" "Arm 1: decoding error: $(cat "$SP/dec1.err")"
fi

# Check log for repeated/stalled frames due to drops
REP1=$(grep -oE 'saved [0-9]+ frames \([0-9]+ repeated/stalled\)' "$SP/b1.log" | head -1)
if echo "$REP1" | grep -qE '\([1-9][0-9]* repeated/stalled\)'; then
  say "PASS" "Arm 1: network drops recorded as repeated stall frames ($REP1)"
else
  say "FAIL" "Arm 1: expected >0 repeated stall frames under 10% packet drop, got: $REP1"
fi

# ── ARM 2: Audio-only call recording ──────────────────────────────────────────
R2="recchk2$$"
REC2="$SP/call_audio_only.mov"
echo "── ARM 2: audio-only call recording ──"
spawn "$TK" --room "$R2" --listen 7933 --peer 127.0.0.1:7934 --video off --audio "$AUDIO" $BASE > "$SP/a2.log" 2>&1
spawn "$TK" --room "$R2" --listen 7934 --peer 127.0.0.1:7933 --video off $BASE \
      --record "$REC2" > "$SP/b2.log" 2>&1

perl -e 'select undef,undef,undef,4.0'
reap

if [ -f "$REC2" ] && [ -s "$REC2" ]; then
  say "PASS" "Arm 2: audio-only file created ($(wc -c < "$REC2" | tr -d ' ') bytes)"
else
  say "FAIL" "Arm 2: audio-only file missing or empty"
fi

INFO2="$("$FFMPEG" -i "$REC2" 2>&1)"
if echo "$INFO2" | grep -q "Audio: aac.*48000 Hz, mono"; then
  say "PASS" "Arm 2: audio track valid"
else
  say "FAIL" "Arm 2: audio track missing"
fi

if "$FFMPEG" -v error -i "$REC2" -f null - > "$SP/dec2.err" 2>&1; then
  say "PASS" "Arm 2: audio-only movie decodable without errors"
else
  say "FAIL" "Arm 2: decoding error: $(cat "$SP/dec2.err")"
fi

# ── ARM 3: Clean call recording (clean media, high quality playout) ───────────
R3="recchk3$$"
REC3="$SP/call_clean.mov"
echo "── ARM 3: clean call recording ──"
spawn "$TK" --room "$R3" --listen 7935 --peer 127.0.0.1:7936 --video "$MEDIA" --audio "$AUDIO" $BASE > "$SP/a3.log" 2>&1
spawn "$TK" --room "$R3" --listen 7936 --peer 127.0.0.1:7935 --video off $BASE \
      --record "$REC3" > "$SP/b3.log" 2>&1

perl -e 'select undef,undef,undef,5.0'
reap

if [ -f "$REC3" ] && [ -s "$REC3" ]; then
  say "PASS" "Arm 3: clean recording created ($(wc -c < "$REC3" | tr -d ' ') bytes)"
else
  say "FAIL" "Arm 3: clean recording missing or empty"
fi

INFO3="$("$FFMPEG" -i "$REC3" 2>&1)"
if echo "$INFO3" | grep -q "Video: h264.*1280x720" && echo "$INFO3" | grep -q "Audio: aac.*48000 Hz, mono"; then
  say "PASS" "Arm 3: video and audio tracks valid"
else
  say "FAIL" "Arm 3: stream format issue"
fi

if "$FFMPEG" -v error -i "$REC3" -f null - > "$SP/dec3.err" 2>&1; then
  say "PASS" "Arm 3: decodable with zero errors"
else
  say "FAIL" "Arm 3: decode error"
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "ALL RECORDING CHECKS PASSED."
  exit 0
else
  echo "RECORDING CHECKS FAILED."
  exit 1
fi
