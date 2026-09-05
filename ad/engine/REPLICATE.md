# Replicating a reference film: the decomposition and the honest scope

Goal set 2026-09-05: take a reference ad (Apple, "The new Mac mini with M6",
43.0 s, 1920x1080, 23.976 fps) and make the engine reproduce it frame by frame
to measurable accuracy, then use the same machinery to make new ads, and get
the whole loop to about a minute per iteration.

## What "replicate" means here, and what it does not

- We replicate the CRAFT: shot structure, cut and dissolve rhythm, camera
  motion curves, lighting logic, framing, typography (face class, size,
  weight, tracking, position, timing, entrance and exit), transitions, colour,
  sound-design timing and dynamics. These are measured from the file and
  become the specification the engine must hit.
- We do not produce a copy of Apple's ad carrying Apple's marks and product.
  The stand-in is a fictional device with the same silhouette class (a small
  aluminium box) so that every technical problem is the same. The output is
  scored against the reference by metrics, not passed off as the reference.
- Photoreal product footage cannot be matched pixel for pixel by a vector
  canvas renderer. Achievable now: type cards near-exact; product shots exact
  in framing, motion and light logic, stylised in surface. Surface realism is
  a later stage that needs a 3D renderer (WebGL, physically based materials,
  an environment light) and a different render path.

## The decomposition: the parts

Every part is a measurement with a tolerance, so the engine can be scored.

1. **Edit**: shot boundaries (hard cuts from scene score peaks > 0.28; soft
   transitions from lower peaks with duration), shot lengths, the rhythm as a
   list of durations, hold times.
2. **Camera**: per shot, the motion curve (push, pan, orbit, rack) estimated
   from frame-to-frame flow; its easing; the framing of the subject (bounding
   box over time).
3. **Light**: per shot, luminance curve, key direction (from the product's
   shading), specular behaviour, background gradient, vignette.
4. **Colour**: palette per shot, grading (black level, white level, saturation).
5. **Type**: for every text frame: string, face class, size in px, weight,
   tracking, position, colour, entrance/exit timing and curve. Type is where
   near-pixel accuracy is reachable first.
6. **Motion design**: any non-camera motion (objects, particles, UI).
7. **Sound**: loudness envelope, transient list (hits), music structure,
   voice presence, how sound aligns with cuts.
8. **Product**: silhouette, proportions, material class, seams and ports as
   geometry, the views used.

`ref/<slug>/analysis.json` holds the measurements; `ref/` is ignored by git
because the reference and its frames are copyrighted material.

## The scoring

- Structure: shot boundaries within 2 frames; shot count exact.
- Type: per text frame, position within 4 px, size within 3%, timing within 2
  frames; a rendered-text SSIM over the text region > 0.9.
- Motion: per shot, subject bounding-box trajectory error < 3% of frame.
- Colour: per shot, mean colour delta E < 6; luminance curve correlation > 0.9.
- Whole-frame SSIM is reported but not a target for product shots.

## The speed target: an iteration in about a minute

A fresh film needs model calls that take 60-150 s each and cannot be made to
fit in a minute; an ITERATION can. The loop that must be fast is: notes in,
changed shots rewritten, only the changed spans re-rendered, re-assembled,
re-verified.

1. **Incremental render**: slices are keyed by a hash of the modules and spec
   fields that affect their span; unchanged slices are reused. A two-shot
   change re-renders two slices (about 10 s), not the film.
2. **In-page encoding**: frame capture over the debugging protocol costs
   15-30 ms per frame and dominates render time. Encoding frames inside the
   page with WebCodecs and pulling one file out removes that cost; the target
   is over 100 frames per second per worker.
3. **Effort by stage**: treatments at high; shot code at high; rewrites and
   repairs at medium (they carry the previous code); the judge and critique
   summaries at low.
4. **Caches that survive iterations**: the product illustration, the voice
   lines (by text hash), the score (by module hash), the treatment.
5. **The gateway cap**: the free tier allows 120k Astra output tokens per hour;
   a fresh v2 run spends most of it. Iterations are cheap; fresh runs are not.
   Bring-your-own-key is exempt.
