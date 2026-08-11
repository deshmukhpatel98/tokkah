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

[ -f nasaA.mp4 ] || curl -L -o nasaA.mp4 "https://images-assets.nasa.gov/video/$A_ID/$A_ID~large.mp4"
[ -f nasaB.mp4 ] || curl -L -o nasaB.mp4 "https://images-assets.nasa.gov/video/$B_ID/$B_ID~large.mp4"

# Offsets chosen where volumedetect confirms live speech (A@300s: mean
# -30.4 dB peak -10.5; B@600s: mean -27.6 peak -8.1).
ffmpeg -y -v error -ss 300 -t 90 -i nasaA.mp4 -vf "scale=1280:720,fps=30" -c:v mjpeg -q:v 8 -an realA.mjpeg
ffmpeg -y -v error -ss 300 -t 90 -i nasaA.mp4 -vn -ac 1 -ar 48000 -c:a pcm_s16le realA.wav
ffmpeg -y -v error -ss 600 -t 90 -i nasaB.mp4 -vf "scale=1280:720,fps=30" -c:v mjpeg -q:v 8 -an realB.mjpeg
ffmpeg -y -v error -ss 600 -t 90 -i nasaB.mp4 -vn -ac 1 -ar 48000 -c:a pcm_s16le realB.wav
ls -la real*
