# The far end of a cross-planet call.
#
# Exists because every latency number this project owns was measured on ONE
# laptop against a SIMULATED network, and the 150 ms goal turns on a number
# nobody has: what a REAL media path costs between two continents.
#
# Playwright's image already carries Chromium plus the system libraries a
# browser needs, so there is nothing to compile — and the far peer runs the
# SAME engine our local rigs drive, or the comparison is not a comparison.
#
# linux/amd64 explicitly: Cloudflare's registry rejects an image whose platform
# metadata is absent, which is what re-tagging a pulled manifest produces (it
# reported "Image platform (/)"). Building pins it.
FROM --platform=linux/amd64 mcr.microsoft.com/playwright:v1.49.0-noble

WORKDIR /peer

# The base image ships the BROWSERS (/ms-playwright: chromium, firefox, webkit)
# and the system libraries they need -- but NOT the npm package that drives
# them. `npm root -g` holds only corepack, npm and yarn, so `require('playwright')`
# died instantly with MODULE_NOT_FOUND. Installing it globally puts it on the
# NODE_PATH the CMD exports.
#
# playwright-core, not playwright: core skips the postinstall browser download
# (they are already here, and re-downloading ~500 MB into an image that has them
# is pure waste) and it is the same package the local rig had to use for exactly
# this reason. Version pinned to the image's, or the driver and the browser
# binaries disagree.
RUN npm i -g playwright-core@1.49.0

# REAL MEDIA ON THE FAR END.
#
# Chromium's built-in fake device is a rolling colour pattern and a beep. Both
# compress to nearly nothing, so a call carrying them measures an empty pipe and
# reports it as a video call -- it cannot tell you whether a bitrate ceiling is
# honoured, what the encoder actually costs, or what a real conversation's
# packet cadence looks like on a long route. The testing-realism law says the
# default camera is a real talking head; a cross-planet measurement is the LAST
# place to break it.
#
# Baked in rather than fetched at runtime: ~96 MB against a 2 GB base is noise,
# and a download that fails mid-experiment is a failure mode this has already
# paid for six times. Side B here; the local end drives side A, so the two ends
# carry different speakers, as two people in a conversation do.
COPY media/realB.mjpeg media/realB.wav /peer/media/

# THE WORK LIVES IN CMD, NOT IN AN ENTRYPOINT OVERRIDE.
#
# Five attempts failed because `container.start({entrypoint})` is silently
# ignored — staged reporting proved it: not even the first line of the override
# ever ran, while the container sat healthy running this image's old CMD
# (`sleep infinity`) forever. So the logic moves where it cannot be discarded,
# and only ENV comes through start({env}), which is the half of that API there
# is no evidence against.
#
# Every step reports before it runs. Silence is the one outcome that teaches
# nothing, and that lesson cost four blind attempts.
#
# NODE_PATH from `npm root -g`: this image installs its packages GLOBALLY, so
# `node join.js` in /peer cannot resolve require('playwright') on its own.
# Every step reports TWICE: to stdout, and by HTTP.
#
# stdout because a Cloudflare container's output lands in the WORKER's log
# stream, readable with `wrangler tail` -- a channel that needs no outbound
# network from the container and no cooperation from anything. Four blind
# attempts were burned on a silent `pending` before that was used.
#
# The detail rides as a plain-text BODY with the stage name in the query string,
# because the previous version interpolated it into a JSON literal: the moment a
# detail contained a quote or a newline -- which every stack trace does -- the
# JSON broke and the worker stored an empty object. The error message was
# destroyed by the very thing meant to carry it.
CMD ["bash", "-lc", "\
stage(){ echo \"[stage] $1: $2\"; \
  curl -fsS -X POST \"$REPORT_URL&stage=$1\" --data-binary \"$2\" >/dev/null 2>&1 || true; }; \
stage boot \"cmd running\"; \
export NODE_PATH=\"$(npm root -g)\"; stage nodepath \"$NODE_PATH\"; \
if [ -z \"$JOIN_URL\" ]; then stage idle 'no JOIN_URL, sleeping'; sleep infinity; fi; \
curl -fsS \"$JOIN_URL\" -o /peer/join.js || { stage fetch-failed 'cannot reach worker'; sleep 300; exit 1; }; \
stage fetched \"$(wc -c < /peer/join.js) bytes\"; \
OUT=$(node /peer/join.js 2>&1) || stage node-failed \"$(echo \"$OUT\" | tail -c 400)\"; \
stage exited \"$(echo \"$OUT\" | tail -c 300)\"; \
sleep 30"]
