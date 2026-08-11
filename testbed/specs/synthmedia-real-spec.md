# Work order: ?synthmedia=real — the iOS/Safari test hook gets a real human

## The problem this solves

The testing-realism law (2026-08-11): every test input must be as realistic
as a human video call. The `?synthmedia=1` hook (app.js ~line 481) — the
only way to feed media to real Safari and the iOS simulator, which have no
fake-device flags — draws gradient+noise squares and a noise audio graph.
`?synthmedia=real` must instead deliver a real talking head: the 90 s
public-domain NASA interview at `/testmedia/real720.mp4` (same-origin
asset, already created, deploys with the worker's assets).

## File to edit (ONLY this one)

- `tape-app/public/app.js`, inside the existing synthmedia block.

## The change

1. The guard `if (QS.get('synthmedia') === '1') {` becomes
   `const SYNTH_MODE = QS.get('synthmedia');` +
   `if (SYNTH_MODE === '1' || SYNTH_MODE === 'real') {` — `'1'` behavior
   must stay byte-identical.

2. In `'real'` mode:
   - Create `const vid = document.createElement('video')` with
     `src='/testmedia/real720.mp4'`, `muted=true`, `loop=true`,
     `playsInline=true`, and call `vid.play()` (muted autoplay is allowed;
     swallow the promise rejection with the file's safe() idiom if used
     nearby, else `.catch(() => {})`).
   - The existing `draw()` in real mode paints `g.drawImage(vid, 0, 0,
     cv.width, cv.height)` when `vid.readyState >= 2`, falling back to the
     existing gradient+noise body until the video is ready (the harness's
     black/flat threshold must never see an empty canvas). Keep the
     setInterval scheduling EXACTLY as-is — the comment explains why rAF is
     forbidden (Safari stops rAF when occluded).
   - Audio: instead of the noise graph's output track, route the video's
     audio through the SAME AudioContext machinery the hook already uses:
     `ctx.createMediaElementSource(vid)` → the existing
     `MediaStreamAudioDestinationNode` (do NOT also connect to
     ctx.destination — the mic must not be audible locally). If the hook
     currently builds a noise node chain, in real mode skip building the
     noise nodes entirely.
   - iOS Safari compatibility is the point: canvas.captureStream and
     MediaElementSource → MediaStreamDestination are both supported there;
     video.captureStream is NOT — do not use it.

3. Comment in the file's voice: why 'real' exists (the realism law, the
   iOS/Safari surface having no fake-device flags), and that '1' remains
   for rigs whose thresholds were calibrated on it.

## Constraints

- '1' mode byte-identical. No changes outside the synthmedia block.
- 2-space indent, why-comments, no change-log comments.
