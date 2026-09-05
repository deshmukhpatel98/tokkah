The film needs a change of hierarchy. At present, everything is an illustration of a sentence. The better film lets the image make the argument, then uses a few words to name what we have already felt.

For the last two acts, the progression should be: distance becomes physical; the ambition becomes global; the product becomes tangible again; the name arrives as the consequence.

Keep the duration at 75 seconds. Keep the existing shot boundaries. Spend the improvement on scale, continuity, material and restraint—not more events.

All numbers below are production instructions unless explicitly quoted as screen copy.

## 1. Shot-by-shot: Act III and Act IV

### 1. S11, 45.0–52.0 — CHANGE: a planet, not a diagram

Remove every meridian and parallel. A wireframe says “network presentation.” We need the feeling of looking across an enormous, quiet physical object.

Composition:

- Place the planet at `(1320, 555)`, radius `480px`. Its right edge is at `1800px`; its lower limb nearly touches the bottom safe area.
- Reserve `x=120–780` for type. The planet owns the right half; the words own the left. Neither competes for the centre.
- Start with the globe facing latitude `25°N`, longitude `45°E`. Rotate westward at `3°/s` during this shot. Delhi and Amsterdam remain visible.
- Do not introduce the globe with a generic scale-up. From 45.0–45.9, reveal the illuminated limb first, then the surface beneath it. The preceding connection should appear to acquire curvature.

Material:

- Draw an opaque sphere. Its dark side must conceal anything behind it.
- Build recognisable land shapes from manually authored geographic polygons stored in JavaScript. These are code geometry, not imported assets. Use roughly `600` coastline vertices, subdivided into a modest spherical triangle mesh.
- Ocean: ground mixed with muted ink at approximately `12%`.
- Land: muted ink at `24%`, with broad cream variation no stronger than `5%`.
- Light comes from upper-left. The brightest surface region should still be substantially darker than the copy.
- Bake a sphere-lighting plate using surface normals and a light vector of approximately `(-0.62, -0.30, 0.72)`. Let illumination fall through a broad terminator rather than applying a symmetrical radial gradient.
- Add a `1.25px` illuminated limb at cream `38%`, with a `10px` falloff at no more than `9%`. Fade the limb to `8%` on the night side.
- No stars. No cloud noise. No luminous continents. Scale and shadow will do more than decorative detail.

The cities:

- Delhi is cream; Amsterdam is blue.
- Each endpoint has a `4px` core and a cached `22px` halo at `18%`.
- Labels are `20px` mono, muted at `90%`, with cream or blue used only for the endpoint.
- Put DELHI `20px` right and `28px` below its point. Put AMSTERDAM `24px` left and `30px` above its point, right-aligned.
- Project those offsets from the geographic anchors every frame. Keep the labels unrotated.
- Use a short `1px`, `25%` leader when necessary. Do not attach a numerical label to a moving photon.

The route and the number:

- The great-circle route rises `4%` above the surface. Its visible portion is `2px`, cream at `45%`; hidden portions are genuinely occluded.
- At 47.0, send one cream point Delhi → Amsterdam over `500ms`, then return over `500ms`.
- The point has a `4px` core, a `14px` halo and a `44px` tapered trail. Sample the trail along the curve; do not draw a straight smear.
- Each arrival briefly brightens the destination halo over `70ms`, releasing over `220ms`.
- Display only the final permitted value, “40 ms”. Do not count through unapproved intermediate numbers.
- Put the value in the left text column, never on the globe: `84px` mono, baseline `525px`, left edge `120px`.

There is also a factual repair here. Delhi–Amsterdam does not take forty milliseconds for light to travel one way. Present this as an approximate round trip for light, not a measured Kin call and not the duration of the screen animation.

At 48.35, the left-hand statement becomes:

“Light there and back. About 40 ms.”

Set the words in `56px` serif above the larger numerical value. It is one typographic statement, not a headline plus a dashboard. Its transcript reads in that order.

Motion and copy:

- 45.45: “Distance takes time.”
- 48.35: the light-round-trip statement.
- 50.55: “The rest is ours to remove.”
- Use `480ms` entrances and `320ms` exits. Keep the planet moving through all three; do not restart its motion at each caption.

Score:

- Strip away the upper register at 45.0 over `450ms`.
- No upward electronic sweep.
- Give the departure a small, dry struck-string sound; the arrival answers it. Sound should establish two ends of a distance, not impersonate a spacecraft.
- The return completes the same musical phrase. Nothing explodes when the number appears.

### 2. S12, 52.0–58.0 — CHANGE: a connected planet with a visible crescendo

The current bloom is too faint to register and too evenly distributed to feel intentional. Make it a single accumulating event.

Composition and camera:

- From 52.0–53.2, move the globe centre to `(1260, 555)` and reduce its radius to `430px`.
- Use `cubic-bezier(.2,.7,.2,1)`.
- Increase westward rotation smoothly to `8°/s`; maintain that through 57.6.
- Fade the two city labels out over `250ms`. Keep their coloured anchors.
- Keep the left copy column fixed. The camera moves; the typography does not.

The bloom:

- Use the specified twenty destinations and both origins: forty routes.
- Divide destinations into four geographically authored groups of five. Launch the groups at `52.25`, `52.85`, `53.45` and `54.05`.
- Offset individual routes within a group by `70ms`.
- Each route is drawn by its moving head over `1300ms`. Do not first reveal a complete line and then send a dot along it.
- Route lift varies deterministically from `6%` to `13%` of the globe radius. Longer routes receive greater lift.
- Cream-origin routes are cream at `48%`; blue-origin routes are blue at `38%`.
- Main strokes are `1.75px`. Add a second `5px` stroke at `7%` beneath them. That is enough glow.
- Heads are `3px` cores with `12px` cached halos. Arrival rings expand from `3px` to `14px` over `280ms`, fading from `35%` to zero.
- After arrival, each route settles to `22%` opacity over `500ms`. The accumulated field remains clearly visible.

Do not fake visibility to show every destination at once. Some routes disappear behind the planet; a few raised sections emerge beyond the limb. That occlusion is what makes this a world rather than a circular route map.

The spectacle peaks around 55.4: a solid, dim planet carrying a bright, inhabited surface of connections. No camera shake, no flare, no global flash.

Copy:

- 52.25: retain “Our goal: under 150 milliseconds. Anywhere on Earth.”
- Break it deliberately into three lines in the left column, at `64px`.
- 55.35: “Lossless sound. Picture kept true.”
- Set the second statement at `56px`. Hold through 57.7.

The word “goal” must remain conspicuous. Neither the route animation nor its speed is evidence of achieved performance.

Score:

- Four musical events, one per group—not forty pings.
- Each adds a note to an open, unresolved harmony.
- Raise the musical body by approximately `4dB` from 52.0–55.4, then stop growing.
- Let the final second hold the completed image and harmony. Do not continue adding particles simply because time remains.

### 3. S13, 58.0–63.0 — CUT the historical accusation; CHANGE to product proof

Two dots and an industry indictment are not a climax. Return to the thing somebody can use.

Composition:

- Crossfade the planet away from 58.0–58.4.
- Reveal two large call windows:
  - Left: `(120, 160)`, `812×508px`.
  - Right: `(988, 160)`, `812×508px`.
- These are the same two people and the same interface established earlier. No newly invented controls, meters or verification badges.
- Enter each window from `16px` below and scale `0.97→1.00` over `640ms`.
- Offset the second entrance by `100ms`. This should feel like an answer, not a symmetrical layout animation.

Continuity:

- Let the last two route endpoints resolve into small glints at the windows’ inner corners. They stop at the frames. Nothing flies into a portrait.
- Both call edges are already illuminated when the windows become visible.
- Use three natural floor changes at `58.85`, `60.15` and `61.40`, each with the established `400ms` colour handover.
- The portraits make tiny, distinct movements: one settles back `3px`; the other inclines `2px` toward the camera. No synchronised breathing.

Copy, centred below the windows, baseline around `835px`:

- 58.45: “Rebuilt from the microphone up.”
- 60.55: “Shipping on Mac.”

Use `64px` serif. The second line gets the same size and treatment as the first. Do not make “shipping” a tiny qualification.

This is not laboratory proof. It is product proof: the film has returned from ambition to the supported experience. Do not add simulated live measurements to make it appear more evidential than it is.

Transition into the brand:

- At 62.15, two small lights separate from the window perimeters: cream from the left, blue from the right.
- Their paths are shallow curves toward the future mark centres.
- Windows dissolve from 62.25–62.95; their edges never independently extinguish while the call remains visible.
- The two lights settle at `(780, 340)` and `(1140, 340)` by 63.0.
- Keep the windows and lights on independent opacity curves. Do not shrink the people into dots.

Score:

- Remove the globe’s upper notes over `500ms`.
- Return to the intimate, dry conversational sounds from Act II.
- This return should be recognisable. We have travelled around the world and arrived back at a person.
- Allow a short, genuine opening in the sound from 62.72–62.90 before the reveal begins.

### 4. S14, 63.0–68.0 — KEEP the mark; CHANGE its material and landing

The mark must stop looking like two CSS gradients. It should look like two sources of light sharing a volume.

Mark:

- Final orb diameter: `560px`.
- Centres: `(780, 340)` and `(1140, 340)`.
- Total mark width: `920px`.
- Cream remains left; blue remains right.
- Give each orb an asymmetric density field: the brightest region sits `14%` toward the shared overlap and `10%` above centre.
- Use a restrained interior, not a white core: peak cream opacity around `62%`, blue around `54%`.
- Add a narrower inner light field, approximately `180×340px`, facing the overlap.
- The intersection receives a separate cream veil at `14%`. Do not use unrestricted additive blending; it will wash the intersection into a generic white blob.
- Build the edge from a solid form with a `20–28px` optical falloff and a much dimmer `70px` exterior halo. The object needs a body before it earns a glow.

Motion:

- From 63.0–63.85, expand the settled lights into the full mark.
- Use `cubic-bezier(.16,.75,.18,1)`.
- Scale monotonically. No overshoot, bounce or recoil.
- Let the overlap become luminous `160ms` after the outer forms begin to resolve.
- After 64.0, motion falls almost to zero: maximum scale variation `0.3%` over `6s`. A logo should not pant.

Wordmark:

- Set “Kin” at `204px`, normal weight, the specified serif stack.
- Use normal font kerning and `-0.025em` tracking.
- Centre optically, not solely by the text box.
- Final baseline: approximately `790px`.
- From 64.0–64.6: opacity `0→1`, vertical movement `8px→0`.
- No mask slicing through letters. No glow. No blur. No letter-by-letter reveal.
- At rest, the wordmark is the sharpest and most stable object in the film.

Tagline:

- Baseline `895px`, `46px` italic.
- Enter from 65.15–65.75 with opacity only.
- Keep “Kin. As close as light allows.” intact in the transcript and accessible description, with the name carried visually by the wordmark.

Score:

- Begin the low foundation as the mark grows.
- Introduce the first clear major third exactly when “Kin” begins appearing at 64.0.
- The emotional arrival is harmonic, not louder percussion.
- No high sparkle on the final letter.

### 5. S15, 68.0–75.0 — KEEP the offer; CHANGE the exit into a usable end card

Do not let a CTA stack push the identity out of the way. Establish one permanent final composition.

From 68.0–69.15:

- Scale the mark to `65%`, moving its centre to `(960, 285)`.
- Reduce the wordmark to `152px`, baseline `635px`.
- Move the tagline to baseline `710px`, `42px`.
- Use the same entrance easing. All elements settle together; none arrives in a separate flourish.

Then:

- “Free on Mac today.” at baseline `805px`, `36px` serif.
- “kin.tokkah.com” at baseline `858px`, `24px` mono, tracking `0.06em`.
- “Not on Mac? Leave your name.” at baseline `916px`, `26px` system sans, muted at `90%`.
- Fade the entire CTA group in over `500ms`, beginning at 68.85. Do not staircase three more messages into the final seconds.
- Hold completely still from 69.6–74.2, apart from the mark’s barely perceptible light variation.
- Fade the film to ground from 74.2–75.0.

On the live page, make the download and name-leaving actions actual semantic links with transparent `48px`-minimum hit areas. Stop their pointer events from triggering pause. The rendered MP4 retains their visible typography but no hover treatment.

Score:

- No CTA hit.
- Let the reveal’s sound decay naturally.
- Begin the final musical withdrawal at 71.8; reach silence at 73.6.
- The last visible hold belongs to the offer, not the composer.

## 2. Typography and copy across the film

### 1. Establish a small, deliberate size system

Use these sizes at the design resolution:

- Opening sentence and S4 resolve: `88px`.
- Main story statements: `72px`.
- Act II side-copy and dense Act III statements: `64px`.
- Secondary evidence copy: `56px`.
- Labels: `20px` mono.
- Wordmark: `204px` at reveal, `152px` on the end card.

The current near-uniform scale makes every sentence equally important. The opening, correction and name need visibly different authority.

Use the specified serif stack throughout. Do not introduce a second display personality.

### 2. Give text a position system, not an approximate region

- Opening and problem act: centred statements, maximum width `1440px`, with a fixed baseline system rather than vertical centring per sentence.
- Act II: window at approximately `(120, 160)`, `1056×660px`; copy begins at `x=1264`, width `536px`.
- Act III globe: copy begins at `x=120`, width `660px`, first baseline around `310px`.
- Product proof and reveal: centred.

The Act II window must give up width so the copy can breathe. Do not shrink text to rescue a window that was composed too large.

Use authored line breaks. Normally allow two lines; allow three for the globe goal. One story statement at a time. UI text and geographic labels are not competing headlines.

### 3. Move statements, not words

- Standard entrance: `480ms`, opacity `0→1`, vertical movement `8px→0`, `cubic-bezier(.2,.7,.2,1)`.
- Standard exit: `280ms`, opacity only.
- Allow at least `120ms` of clean separation between statements.
- No tracking animation, character cascades, word highlighting or typewriter effect outside the actual handle input.
- The opening sentence appears as a whole. Its confidence comes from refusing to perform.
- The only hard editorial event remains S4. Its copy begins after the visual correction, not on the same frame.

Use `letter-spacing:-0.015em` for story type and line-height `1.04`. Keep mono labels at `0.08em`; the existing wide tracking makes small labels occupy too much territory.

At settled states, use integer CSS positions and `transform:none`. Grain belongs beneath typography so it does not erode letter edges.

### 4. Make these copy changes

These are the only proposed new film lines. Everything not listed remains unchanged.

1. COPY CHANGE — S2  
   Old: “You finish a sentence. Then you wait.”  
   New: “You finish. You wait.”

2. COPY CHANGE — S2  
   Old: “Then you both talk at once.”  
   New: “Then you both start.”

3. COPY CHANGE — S3  
   Old: “When the line gets thin, the call spends your face.”  
   New: “The picture breaks.”

4. COPY CHANGE — S3  
   Old: “And invents your voice.”  
   New: “Words go missing.”

5. COPY CHANGE — S7  
   Old: “No link. No account. No waiting room.”  
   New: “No link. No waiting room.”

6. COPY CHANGE — S8  
   Old: “Just them. No mirror. No buttons.”  
   New: “Just them.”

7. COPY CHANGE — S8  
   Old: “Green means they can hear you.”  
   New: “They can hear you.”

8. COPY CHANGE — S9  
   Old: “One voice at a time. The way a room works.”  
   New: “Back and forth.”

9. COPY CHANGE — S10  
   Old: “The voice is the recording.”  
   New: “Their voice, kept whole.”

10. COPY CHANGE — S10  
    Old: “The picture is the camera’s own.”  
    New: “Their picture, kept true.”

11. COPY CHANGE — S10  
    Old: “Nothing in between is allowed to touch either.”  
    New: Cut. Let the connection carry the final part of the shot.

12. COPY CHANGE — S11  
    Old: “Between two people, one delay is real.”  
    New: “Distance takes time.”

13. COPY CHANGE — S11  
    Old: “The time light needs to cross the distance.”  
    New: “Light there and back. About 40 ms.”

14. COPY CHANGE — S11  
    Old: “Everything else is a defect.”  
    New: “The rest is ours to remove.”

15. COPY CHANGE — S12  
    Old: “Lossless sound. A visually lossless picture. Measured on live calls, every release.”  
    New: “Lossless sound. Picture kept true.”

16. COPY CHANGE — S13  
    Old: “Every video call in the world still runs on a 2011 design that spends your face when the network dips.”  
    New: Cut.

17. COPY CHANGE — S13  
    Old: “We rebuilt the call from the microphone up. It’s shipping.”  
    New: “Rebuilt from the microphone up.” followed by “Shipping on Mac.”

18. COPY CHANGE — S15  
    Old: “Not on a Mac yet? Leave your name — you’ll be first.”  
    New: “Not on Mac? Leave your name.”

Keep “Every call has a gap in it.” exactly. Keep the tagline exactly.

The revised rendered copy uses the protected sound-quality word once. It also removes the sweeping historical claim and distinguishes aspiration from demonstrated shipping status.

## 3. Score: replace the anonymous pad with a conversation

### 1. Write one small musical identity

Use a three-event rhythm: a short gesture, a longer answer, a settling note.

Its nominal spacing is `0ms`, `310ms`, `790ms`. Reuse the rhythm in the opening exchange, the call, the light journey and the reveal. Change its spacing when the connection fails; restore it when the call clears.

That recurrence is the identity. A constant drone is not.

Harmonic plan:

- 0–13: A and E, open and unresolved.
- 13–45: D and A, grounded but without a defining third.
- 45–63: D, A and E, opening into a larger space.
- At 64.0: introduce F-sharp. The name supplies the resolution.

Do not fill every gap with sustained sound.

### 2. Build three related timbres

The cream voice:

- Sine fundamental plus triangle at `-20dB` relative to it.
- A quiet second partial at `-24dB`.
- Low-pass around `1500Hz`.
- Attack `18ms`, decay `180ms`, release `140ms`.
- Pan approximately `-0.22`.

The blue answer:

- Same construction, slightly rounder: low-pass `1100Hz`.
- Attack `28ms`, decay `240ms`, release `180ms`.
- Pan `+0.22`.
- Do not make it colder through brittle high frequencies.

The shared body:

- D2 and A2 sines, with a restrained D3 triangle.
- No continuous detuned beating.
- Low-pass `700Hz`, opening only to `1200Hz` at the global bloom.
- Normally around `-36dBFS`; absent during several deliberate rests.

For struck sounds, add a seeded `8–15ms` noise excitation through a low-pass filter. Avoid bell-like upper partial stacks.

Use one generated stereo room response, `650ms` long, with an early reflection around `43ms` and a dark decay. Keep wet level near `12%`. This is a room, not a cathedral.

### 3. Score the opening as interrupted human timing

- 0.0–0.8: silence.
- 0.8: the first point receives one soft A3 gesture.
- 3.95: cream begins its phrase.
- 5.35: the response arrives at the far end.
- 6.40: blue starts answering.
- 7.00: cream starts again.
- 7.40: the phrases collide.

At the collision, do not add a dramatic dissonant chord. Briefly truncate both gestures with `12ms` ramps and leave `180ms` of exposed space. It should feel like an awkward interruption.

At S3, derive the damaged sound from the same authored phrase:

- Remove two short sections.
- Hold one section too long.
- Repeat one `70ms` fragment.
- Use `6ms` ramps to prevent unintended clicks.

The visual waveform must be drawn from this actual generated signal, not a random stepped line.

From 12.88–13.0, pull all sound, including the room tail, into a `120ms` silence.

At 13.0, play one dry, intact phrase over the new D foundation. The correction should sound simpler than the failure.

### 4. Let the UI be nearly silent

- Typing: `7ms` seeded noise ticks, low-pass `1800Hz`, approximately `-40dBFS`.
- Return at 23.0: one `14ms` tick at `-35dBFS`.
- Connected at 24.4: one rounded D4 note, `12ms` attack, `180ms` release, no two-note notification.
- Fade the musical foundation down through 25.5. Leave room for the first exchange.

The product should not announce every state change.

### 5. Make speaking light and sound share one authored source

Keep the required edge behaviour, but drive both picture and sound from explicit syllable events.

For the first cream phrase, use onset times:

`29.06, 29.36, 29.67, 29.97, 30.35, 30.70, 31.05, 31.38`.

Peak levels:

`0.45, 0.70, 0.52, 0.84, 0.60, 0.42, 0.67, 0.34`.

Each syllable has a `90ms` attack and `260ms` release. Author the blue phrase with six unevenly spaced syllables from 33.06–34.90.

Generate the audible texture from quiet noise through broad bands around `320Hz` and `850Hz`, with a sine component approximately `18dB` below the noise. Keep the result around `-38dBFS`.

It should suggest breath and vocal presence without pretending to contain intelligible speech.

The band must already be on at connection, including before anyone speaks. Its rest level is not silence rendered as black.

### 6. Make the global passage expansive without becoming “technology music”

- 45.0: upper notes withdraw.
- 47.0: cream struck tone.
- 47.5: blue answer.
- 48.0: cream settling note.
- No pitch sweep and no launch thump.

At the four route-group launches:

- 52.25: D4.
- 52.85: A4.
- 53.45: E5.
- 54.05: D5.

Give these `35ms` attacks and `900ms` decays. Keep the highest notes softer, not louder. Pan within `±0.3`; no headphones-only trick.

The underlying harmony remains unresolved. At 58.0, remove the upper layer and return to the dry conversational rhythm.

At 63.0, introduce the low reveal foundation. At 64.0, add F-sharp with a soft, felt-like attack and approximately `4s` decay. No second bell chord. No high ping.

### 7. Control dynamics deliberately

- Aim for approximately `-21 LUFS` integrated.
- Keep the quiet middle genuinely quieter than the reveal.
- Use compression gently: ratio `1.5:1`, attack `30ms`, release `180ms`.
- Measure the completed audio and apply downward gain as needed to remain below `-3dBTP`; the compressor alone is not a peak guarantee.
- Do not normalise each scene independently.

The full score should be rendered once to an audio buffer from the deterministic synthesis graph. Live playback starts that buffer at the current timeline offset. Seeking therefore preserves tails and timing instead of reconstructing a room effect from an arbitrary point.

## 4. Implementation notes and build order

### 1. Spend the three canvases intentionally

Canvas one: scene imagery.

- Planet, surface geometry, lighting plate, portraits and other generated picture material.
- Use one full-stage canvas, clearing only what the active scene requires.

Canvas two: light and movement.

- Routes, photons, ripples, particles, perimeter light and reveal mark.
- Draw full-window edge fields here so their clipping and corner behaviour are exact.

Canvas three: grain.

- Render seeded monochrome noise at `480×270`, scale to the stage.
- Use approximately `1.5–2%` opacity, not a blanket `4%` veil.
- Change the grain at `30Hz`, even during `60fps` playback.
- Keep it below DOM typography.
- Disable it for reduced motion.

DOM owns all text, window chrome, cards and interactive controls.

Do not quietly add a fourth scratch canvas. During preparation, reuse one of the three to create cached `ImageBitmap` objects from procedurally drawn material, then clear it. Those caches are generated by the page; no image files are loaded.

### 2. Repair the portrait before refining any light around it

The new S13 cannot work if the person remains a smudge.

Build an asymmetric anatomical light study:

- A tilted head mass, distinct jaw-to-neck transition and unequal shoulder heights.
- One shoulder closer and larger.
- Hair or outer head shape with an irregular contour.
- Broad cheek and forehead planes, but no eyes, nose or mouth.
- A narrow cream rim on one side, not a halo around the entire head.
- Structural transitions around `6–10px`; soft interior transitions around `18–30px` at a `960×600` working size.

Do not blur the complete construction. A defocused person retains readable anatomy.

Reuse this exact portrait source in S3’s degradation and the later call. Then the earlier damage happens to someone we eventually meet, rather than to an abstract blue object.

### 3. Fix the edge through containment, not redesign

Retain its specified depth, brightness, voice response and colour handover.

The current heaviness is partly a compositing error:

- Clip the band to the call-content rectangle, excluding the title strip.
- Evaluate the depth in the original window’s coordinate system, then scale it with the window.
- Calculate distance to the nearest edge once. Do not add four overlapping gradients and make the corners twice as bright.
- Keep the face region at least `120px` inside the content boundary at source scale.
- Preserve the `1.5px` perimeter line.
- Do not add a second exterior glow.
- Never lower the band below its resting floor during an active call.

This makes the signature faithful without allowing it to eat the picture.

### 4. Keep globe work geometric and bounded

- Store geographic vertices as unit vectors.
- Compute one camera matrix per frame.
- Transform vertices with matrix multiplication; do not repeatedly calculate geographic trigonometry.
- Clip land triangles and route segments against the visible hemisphere.
- Group land triangles into a small number of fill paths.
- Precompute each route as approximately `96` three-dimensional samples.
- Locate the moving head by interpolation between samples.
- Draw trails from the same samples, preserving curvature.

Bake the lighting plate and particle halos once. Never calculate sphere illumination for every pixel on every frame.

### 5. Make determinism include the quiet details

- No accumulated particle positions.
- No analyser-driven edge light.
- No fresh random values in `render(t)`.
- Seed every noise event by a stable event identifier.
- Precompute the slow thickness response on a `240Hz` timeline, then interpolate it by `t`.
- Use `floor(t × 30)` for grain identity.
- Derive every portrait movement from authored time functions, not independently running animations.

A seek to any moment must produce the same frame as playing through it.

### 6. Replace the poster, not merely its dimming amount

Build a dedicated static composition with the same finished mark material.

- Mark above centre.
- Reserve a clear `96×96px` area around the required centred play control at `(960,540)`.
- Place the wordmark and tagline below that gap.
- Put the offer and URL near the bottom safe area.
- Use a `72px` play circle with a cream triangle and restrained glass backing.
- Apply no global dimming.

The poster is the film’s first advertisement. It should not look like someone paused the real advertisement and placed a grey sheet over it.

For the muted hero excerpt, keep the existing call span, but ensure the edge is already alive at its first frame and the framing remains legible at the smaller output size.

### 7. Build in this order

1. Lock the new copy, line breaks and stage geometry. Make static DOM frames first.
2. Rebuild the portrait and correctly contained call edge. These improve the hero and the new product-proof climax simultaneously.
3. Build the solid globe, geography, occlusion and fixed numerical lockup. Approve S11 as a still before adding routes.
4. Build the forty-route bloom and its four-group timing.
5. Build S13’s return to the two large call windows.
6. Build the reveal material, wordmark landing, end card and dedicated poster.
7. Replace the score and connect its authored envelopes to the light.
8. Add grain last.

After each visual stage, inspect the image at full resolution and at `480px` wide. If the person, planet, route or wordmark disappears at the smaller size, it is not a subtle detail; it is an unreadable decision.

Finally, run the required still pass and a complete preview render. Inspect transitions in motion, not only shot-boundary stills. Confirm the duration, frame size, audio stream, deterministic seeks and actual frame time in all three target browsers.

The intended result is not “more cinematic effects.” It is a film in which distance has mass, conversation has rhythm, the product has presence, and the name arrives only after it has earned the screen.