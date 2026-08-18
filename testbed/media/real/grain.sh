#!/bin/sh
# Sensor-like fixtures — the pre-check that stands between the presence filter
# and a real camera.
#
# WHY THIS EXISTS. Every presence-filter number in this repo is measured on
# realA/realB.mjpeg, which are NASA interview footage: already compressed once
# by the source, then again by us at MJPEG q8. Compression is a denoiser. So
# the fixture arrives with most of its grain already gone, and the filter's
# first lever is being asked to remove something that is barely there. The
# real-sensor law says a camera claim needs a camera, and it is right — but two
# specific things can be asked of a fixture BEFORE the camera, and both of them
# could falsify the filter:
#
#   GRAIN. The claim is that denoise earns MORE on a real sensor because there
#   is more to remove. If it earns more here, that claim survives a test. If
#   the hold instead thrashes — grain constantly pushing pixels back over the
#   motion threshold, so nothing ever locks — the 61.5% is a fixture artefact
#   and we would rather learn it here than on a phone.
#
#   EXPOSURE DRIFT. The claim that worries me more. The hold repeats a pixel
#   exactly once it has been still for ~0.45 s, and a real camera's auto
#   exposure never stops moving. A slow global luma ramp is exactly the input
#   that could make the hold either useless (releasing constantly) or wrong
#   (holding a wall at yesterday's brightness). The design says it self-bounds:
#   drift is measured against the HELD value, so it accumulates until it
#   crosses the threshold and releases the pixel on its own. That is an
#   argument. This makes it a measurement.
#
# NOT A SUBSTITUTE FOR A SENSOR. Synthetic grain is iid and a real sensor's is
# not (it is correlated across the Bayer neighbourhood, stronger in shadow, and
# shaped by the ISP's own denoiser). Passing here does not license shipping;
# failing here is decisive.
#
#   sh testbed/media/real/grain.sh          # writes real{A,B}-grain.mjpeg + .wav symlinks
set -e
cd "$(dirname "$0")"

[ -f nasaA.mp4 ] || { echo "run fetch.sh first (needs nasaA.mp4/nasaB.mp4)"; exit 1; }

# alls=10 on ffmpeg's 0..100 scale lands near sigma 6 in 8-bit luma, which is
# roughly a phone sensor at indoor light (~32 dB luma SNR). allf=t+u makes it
# TEMPORAL and uniform — temporal is the property that matters, because
# temporally random noise is precisely what motion compensation cannot predict
# and what the encoder therefore re-buys every frame.
#
# The exposure term is a +/-10/255 sinusoid on a 25 s period: an auto-exposure
# that hunts, faster and deeper than most rooms produce, chosen so the hold is
# tested against drift rather than flattered by its absence.
#
# q:v 2, not the q:v 8 of fetch.sh: at q8 the MJPEG stage would quietly remove
# a good part of the grain this fixture exists to deliver, and the filter would
# again be handed a clean picture. The file is bigger; nothing else changes.
GRAIN="noise=alls=10:allf=t+u,eq=brightness='0.04*sin(2*PI*t/25)':eval=frame"

for S in A B; do
  case $S in
    A) SRC=nasaA.mp4; SS=300 ;;
    B) SRC=nasaB.mp4; SS=600 ;;
  esac
  ffmpeg -y -v error -ss $SS -t 90 -i $SRC \
    -vf "scale=1280:720,fps=30,$GRAIN" -c:v mjpeg -q:v 2 -an real$S-grain.mjpeg
  # Audio is unchanged — this fixture asks a question about pixels. Symlinked
  # rather than copied so the two stay identical by construction.
  ln -sf real$S.wav real$S-grain.wav
done

ls -la real*-grain*
