# Frame Sense — natural self-awareness of what the camera sees

## Problem
In a real room you always know, proprioceptively and peripherally, what of you the
other person can see. On a call you either stare at a mirror self-view (raises
self-focus, breaks presence — the known "Zoom fatigue" mirror effect) or you have
nothing and drift half out of frame without knowing.

## Anti-goals (explicitly rejected)
- Persistent large mirror self-view.
- 3D body reconstruction / avatar ("see your legs and arms"). Heavy, uncanny,
  latency risk, opposite of the low-effort multiplier method.

## Design: transient peripheral edge cue
The line of visibility/invisibility is the frame edge. Make the edge *felt* only
when it matters, invisible otherwise:

1. **Detection** (zero pipeline impact): sample the local capture video element to
   a tiny offscreen canvas (~64×36) at ~2 fps via requestIdleCallback (never
   rAF-coupled, never on the worklet/encoder path). Compute a luma-motion centroid
   + occupancy per edge band (top/bottom/left/right 12% strips). Where the
   FaceDetector API exists (Chrome), prefer face box; fall back to motion centroid.
2. **Cue**: when your centroid drifts into an edge band, or edge-band occupancy
   spikes (body part crossing the visibility line), fade in a soft inner glow along
   that screen edge (CSS gradient overlay, opacity 0→~0.25 over 300 ms). Fade out
   within ~1 s of re-centering. No text, no icons, no border boxes.
3. **Motion-breathing self-view** (part 2, same flag): the small self-view tile
   idles at low opacity (~0.35) and breathes up to full when you move
   significantly, back down when still — like catching yourself in peripheral
   vision, not a mirror you stare at.

## Flag
`?frame=0` disables (control); default ON per defaults law. All work is
main-thread-idle + CSS compositing; the audio/video pipeline is untouched, so
zero added latency by construction.

## Verification (live prod, real media)
Rig: testbed room on room.tokkah.com, real talking-head fixture. Assert:
(a) cue overlay opacity > 0 within 1.5 s when the subject enters an edge band
    (use a fixture segment where the speaker leans/exits frame, or drive the
    element with a cropped variant), and returns to 0 after re-centering;
(b) ?frame=0 arm never shows the overlay;
(c) no change in mouthToEarMs / conceal vs control arm (pipeline untouched);
(d) self-view opacity rises on motion, falls when still.
