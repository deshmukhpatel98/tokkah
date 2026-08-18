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
#   2. THE 5 Mbps CUT IS FINE, AND THIS WAS MEASURED RATHER THAN ASSUMED.
#      `~large` is 4996 kb/s against `~orig`'s 16151 at the same resolution, so
#      the worry was that the input had already been through a lossy encode
#      which smoothed exactly the high-frequency detail the presence filter is
#      judged on — meaning part of what the filter got credit for "removing"
#      might be h264 artifacts rather than sensor grain. That would have
#      undermined every presence-filter number measured to date.
#
#      Tested by fetching the 2.4 GB ~orig and cutting the identical 90 s at the
#      identical settings. MJPEG at a fixed -q:v is a detail meter: more
#      high-frequency content costs more bits, unconditionally.
#
#          realA.mjpeg       (from ~large, 4996 kb/s)   133,497,598 B
#          realA-orig.mjpeg  (from ~orig, 16151 kb/s)   134,935,637 B   +1.08%
#
#      1.08%. Tripling the source bitrate buys about one percent more detail at
#      720p, so the ~large encode was not throwing away the grain the filter is
#      graded on, and the fixtures are sound. `realA-orig.mjpeg` is kept as the
#      reference; regenerate with the ~orig URL if the question is ever reopened.
#      The 2.4 GB master is deleted after cutting — reproducible, not worth the
#      disk.
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
