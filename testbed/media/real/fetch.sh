#!/bin/sh
# Real talking-head fixtures — the testing-realism law (2026-08-11): every
# test input must be as realistic as a human video call. Two public-domain
# NASA astronaut interviews (different speakers, one per call side),
# converted to Chrome's fake-device formats. Binaries are gitignored; this
# script reproduces them on any machine. Requires ffmpeg + curl.
set -e
cd "$(dirname "$0")"

A_ID=iss061m2627771232_Live_Interviews_Jeanette_Epps_191004
B_ID=iss063m261222124_NASA_SpaceX_Demo2_Robert_Behnken_Interviews

# TWO THINGS MEASURED ABOUT THIS SOURCE, 2026-08-18, both worth knowing before
# trusting a filter number taken from it:
#
#   1. IT IS 720p AND THERE IS NO 1080p VERSION. `~orig.mp4` is 2.4 GB and also
#      1280x720. So the "measure the filter at 1080p" task cannot be done with
#      these files — scaling up to 1920x1080 adds no detail, and a filter that
#      looked cheap on upscaled pixels would be reporting a number that is false
#      for a real 1080p sensor, where the extra high-frequency detail costs real
#      bits. That needs genuinely-1080p talking-head source, not a scale filter.
#
#   2. THESE FIXTURES COME FROM THE 5 Mbps CUT. `~large` is 4996 kb/s; `~orig`
#      is 16151 kb/s at the same resolution. So the input has already been
#      through a lossy encode that smoothed exactly the high-frequency detail
#      the presence filter is judged on, and part of what the filter is measured
#      "removing" may be h264 artifacts rather than sensor grain. The realism law
#      says test inputs must be as realistic as a human video call; a
#      thrice-compressed one is not. Fixing it is a 2.4 GB fetch and a re-encode
#      from ~orig, which is why it is recorded here rather than silently done.
#
[ -f nasaA.mp4 ] || curl -L -o nasaA.mp4 "https://images-assets.nasa.gov/video/$A_ID/$A_ID~large.mp4"
[ -f nasaB.mp4 ] || curl -L -o nasaB.mp4 "https://images-assets.nasa.gov/video/$B_ID/$B_ID~large.mp4"

# Offsets chosen where volumedetect confirms live speech (A@300s: mean
# -30.4 dB peak -10.5; B@600s: mean -27.6 peak -8.1).
ffmpeg -y -v error -ss 300 -t 90 -i nasaA.mp4 -vf "scale=1280:720,fps=30" -c:v mjpeg -q:v 8 -an realA.mjpeg
ffmpeg -y -v error -ss 300 -t 90 -i nasaA.mp4 -vn -ac 1 -ar 48000 -c:a pcm_s16le realA.wav
ffmpeg -y -v error -ss 600 -t 90 -i nasaB.mp4 -vf "scale=1280:720,fps=30" -c:v mjpeg -q:v 8 -an realB.mjpeg
ffmpeg -y -v error -ss 600 -t 90 -i nasaB.mp4 -vn -ac 1 -ar 48000 -c:a pcm_s16le realB.wav
ls -la real*
