# The far end of a cross-planet call.
#
# Exists because every latency number this project owns was measured on ONE
# laptop against a SIMULATED network, and the 150 ms goal turns on a number
# nobody has: what a REAL media path costs between two continents.
#
# Playwright's image already carries Chromium plus the system libraries a
# browser needs, so there is nothing to compile here — the whole point is that
# the far peer runs the SAME browser engine our rigs drive locally, or the
# comparison is not a comparison.
#
# linux/amd64 explicitly: Cloudflare's registry rejects an image whose platform
# metadata is absent, which is exactly what re-tagging a pulled manifest
# produces (it reported "Image platform (/)"). Building pins it.
FROM --platform=linux/amd64 mcr.microsoft.com/playwright:v1.49.0-noble

# Fake media, so a headless container can be a real participant: a synthetic
# camera and mic mean getUserMedia succeeds with no hardware. The MEASUREMENT
# is timing, not picture quality, and the local side of every A/B already runs
# the same flags — matching them is what keeps the two ends honest.
ENV PEER_FLAGS="--use-fake-device-for-media-stream --use-fake-ui-for-media-stream --autoplay-policy=no-user-gesture-required"

WORKDIR /peer
# The script is fetched at boot rather than baked in, so the experiment can
# change without rebuilding and re-pushing two gigabytes.
CMD ["bash", "-lc", "node -e \"process.stdout.write('peer image up: '+process.version+String.fromCharCode(10))\"; sleep infinity"]
