#!/bin/sh
# Vendored third-party tracker assets for the presence-window work
# (testbed/specs/presence-window.md). Self-hosted rather than CDN-loaded
# because the app's CSP is `default-src 'self'` and a call app has no business
# reaching a third-party origin mid-call.
#
# Binaries are gitignored (26 MB); this script reproduces them. Requires npm +
# curl. Run from anywhere: sh tape-app/public/vendor/fetch.sh
set -e
cd "$(dirname "$0")"
mkdir -p mediapipe/wasm
cd mediapipe

# MediaPipe Tasks-Vision runtime (ES module bundle + wasm).
TMP=$(mktemp -d)
(cd "$TMP" && npm pack @mediapipe/tasks-vision@1.0.1 >/dev/null && tar xzf mediapipe-tasks-vision-1.0.1.tgz)
cp "$TMP/package/vision_bundle.mjs" .
cp "$TMP/package/wasm/vision_wasm_internal.js" \
   "$TMP/package/wasm/vision_wasm_internal.wasm" \
   "$TMP/package/wasm/vision_wasm_nosimd_internal.js" \
   "$TMP/package/wasm/vision_wasm_nosimd_internal.wasm" wasm/
rm -rf "$TMP"

# Face models. face_landmarker (3.7 MB, 478 landmarks + blendshapes) is the
# strong-tier tracker; blaze_face_short_range (230 KB) is the low-end tier —
# same physics, ~1/16th the bytes, CPU delegate.
[ -f face_landmarker.task ] || curl -sL -o face_landmarker.task \
  "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task"
[ -f blaze_face_short_range.tflite ] || curl -sL -o blaze_face_short_range.tflite \
  "https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_short_range/float16/1/blaze_face_short_range.tflite"

ls -la . wasm
