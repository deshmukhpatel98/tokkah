# Kin — the animated film. Creative brief and technical spec.

Owner of taste: the orchestrator. Owner of the build: the worker. Read all of it
before writing a line; every section is load-bearing.

## 1. What this is

A 75-second animated film, 16:9, 1920×1080, that sells Kin to two audiences at
once: people who will use it, and investors who should fund it. Pure animation:
no footage, no screenshots, no photographs. Everything is drawn in code
(DOM + CSS + Canvas 2D) so the same source runs as a web page, publishes as a
link, plays as the hero of kin.tokkah.com, and renders frame-exact to an MP4.

Two outcomes it must produce:
- A person wants to call someone on Kin today, or leave their name to be first
  when it reaches their device.
- An investor believes this team is building the one thing every call in the
  world is missing, and that it is already real and shipping.

## 2. The idea in one line

Between two people, the only delay that is real is the time light takes to
cross the distance. Everything else is a defect. Kin is a call that gets out of
the way until only the light is left.

Tagline: **Kin. As close as light allows.**

## 3. Tone

Apple-quiet, not startup-loud. Dark ground, cream type, one green and one blue.
Slow, confident motion. Silence used as a beat. Every word earns its place; most
shots are wordless. No bullet points, no feature lists, no numbers except the
ones that ARE the goal (150 milliseconds, the speed of light). If a shot could be
a slide, it is wrong.

## 4. Visual system (the app's own, not invented)

- Ground `#05060a`. Ink `#f3f1ec` (cream). Muted ink `#9aa3b2`. Green
  (speaking, "you are audible") `#4ade80`. Blue (listening) `#60a5fa`.
  Red never appears anywhere in the film.
- Type. Story headlines: `Baskerville, "Iowan Old Style", Georgia, serif`,
  weight 400, `letter-spacing: -0.01em`, `line-height: 1.08`. Sizes: 64px for
  story lines, 56px for Act II side-copy, 140px for the wordmark "Kin". The
  tagline is the same face in italic. UI text inside the fake app:
  `-apple-system, BlinkMacSystemFont, system-ui, sans-serif` (the app uses SF).
  Small labels (city names, the URL, the ms counter):
  `ui-monospace, Menlo, monospace`, 18px, letter-spacing `0.12em`, uppercase
  for city names.
- Glass: `rgba(10,14,22,.55)` fill + 1px hairline `rgba(255,255,255,.14)` +
  `backdrop-filter: blur(18px) saturate(1.3)`. Radii: 20px cards, 999px pills.
  At most two glass surfaces on screen at once.
- Film grain: an animated noise canvas over everything at ~4% opacity,
  regenerated every frame (seeded from the frame index when `?render=1`, so a
  re-render is byte-identical). Grain is the difference between a gradient and
  a photograph.
- The edge band (THE product's signature; reproduce it faithfully): a glow
  along the inside of the window edge, 48px deep at rest, alpha ramp
  `(1-t)^2.2` from the edge inward (t = 0 at the edge, 1 at 48px), plus a 1.5px
  hairline of the same colour on the very edge. Colour is green when "you" hold
  the floor, blue when "they" do; a handover eases the colour over 400ms (a
  colour moving, never cutting). Brightness = the live voice envelope of
  whoever holds the floor: `opacity = 0.55 + 0.45 * env`, envelope attack 90ms,
  release 260ms. Thickness follows level slowly (450ms attack / 1200ms
  release): 48px at rest, up to 96px at full voice. The band NEVER goes dark
  during a call; only colour and brightness move. Nothing ever reaches a face.
- Motion: easing `cubic-bezier(.2,.7,.2,1)` for entrances, 600–1400ms for
  scene elements, `ease-in-out` sines for breathing. Nothing snaps, except the
  one moment in S4 where snapping IS the point.
- Composition: generous margins (the safe area is 120px from every edge for
  copy). Copy sits either centered, or in the right third beside the window
  in Act II. One line of copy on screen at a time; a line fades in over 500ms
  (opacity + 12px rise), holds, fades out over 400ms before the next.

## 5. Shot list and copy (75 s). Times are seconds from the start.

Copy is exact. Do not paraphrase it, do not add words to it.

### Act I — The gap (0–15). The problem, felt, not explained.

- S1 0.0–3.5. Black. A single cream point of light at center breathes once
  (radius 3→7→3px, glow). Copy fades in at 0.8: **"Every call has a gap in it."**
- S2 3.5–9.0. The point splits into two soft orbs 900px apart, each ~150px
  across with a soft halo: cream on the left ("you"), blue on the right
  ("them"). Cream speaks: three concentric ripples leave it and travel right,
  visibly slowly (1.4 s to cross). Blue receives and glows, then replies; its
  reply ripples meet cream's next ripples mid-way and both shatter into
  particles. Both orbs dim to 40%. Copy at 3.9: **"You finish a sentence. Then
  you wait."** Copy at 7.0: **"Then you both talk at once."**
- S3 9.0–13.0. The blue orb's edge quantises into square blocks (a mosaic of
  24px cells, colours banding to 4 levels); the line between the orbs becomes a
  jagged, stepped waveform with dropouts (gaps). Copy at 9.3: **"When the line
  gets thin, the call spends your face."** Copy at 11.5: **"And invents your
  voice."**
- S4 13.0–15.0. One clean beat: in a single frame at 13.0 everything snaps
  crisp — the blocks become a perfect circle, the stepped waveform becomes a
  smooth continuous curve, both orbs return to full brightness. Copy at 13.2,
  centered, 72px: **"It doesn't have to."**

### Act II — The feel (15–45). Using Kin, exactly as it is.

- S5 15.0–17.0. A Mac window rises from the dark and settles at center: 1280×800
  (scaled to fit the 1080 stage with ~120px margin), 12px radius, hairline
  border, three dim traffic-light dots in the title strip. Inside: a soft,
  out-of-focus warm room (five blurred cream/amber bokeh discs drifting very
  slowly) — the camera preview. Over it, one glass card 560px wide, centered.
  A small serif wordmark "Kin" appears at the bottom-left of the stage and stays
  through Act II.
- S6 17.0–23.0. The card holds a text field with the placeholder **"Type a
  handle, like meera"**. A cursor blinks; **"meera"** is typed letter by letter
  (70ms per key). Below the field: three rows, each a 34px circle with an
  initial and a name, with a small presence dot to the right: **Meera** (green
  dot), **Arjun**, **Dad**. As the letters land, the Meera row lights (matches
  the prefix). Copy in the right third at 17.5, 56px: **"Call a person. Not a
  room."**
- S7 23.0–26.0. Return at 23.0. The Meera row holds lit and the others dim to
  40%. A pill appears under the card: **"Calling Meera   ·   esc to cancel"**
  with the three characters after "Meera" cycling as dots (400ms). At 24.4 the
  pill reads **"Connected"** for a beat; the card and pill dissolve by 26.0.
  Copy at 23.4: **"No link. No account. No waiting room."**
- S8 26.0–33.0. The window fills edge to edge with the other person: an
  abstract, out-of-focus portrait, head and shoulders, built from layered
  soft gradients (a warm cream/amber form against a darker warm ground, a rim of
  light on the left). No facial features at all — it must read as "a person,
  softly out of focus", never as a character or a silhouette icon. It breathes
  (scale 1.000→1.012 over 4 s, sine) and drifts a few pixels. No controls, no
  self-view, nothing else in the frame. Copy at 26.6: **"Just them. No mirror.
  No buttons."** At 29.0 the edge band lights GREEN and its brightness follows a
  pre-authored syllable envelope (eight syllables over 2.6 s, then rest); a faint
  cream waveform of "your" voice runs along the bottom hairline, 2px tall peaks.
  Copy at 29.6: **"Green means they can hear you."**
- S9 33.0–38.0. At 33.0 the band eases green→blue over 400ms; the portrait's
  warmth pulses slightly with THEIR syllable envelope (a different envelope, six
  syllables over 2.2 s). Copy at 33.3: **"Blue while you listen."** At 35.0 the
  camera pulls back: the window shrinks to 55% and a second Mac window slides in
  beside it — the same call from their side: an abstract portrait of you, cooler,
  blue-lit, with the complementary edge. When the left is green the right is
  blue. Two handovers happen (35.8 and 37.0), and both edges swap within 100ms of
  each other. Copy at 35.6: **"One voice at a time. The way a room works."**
- S10 38.0–45.0. Both windows drift apart to the left and right thirds and
  shrink to 40%; a single hairline of light connects them, with a faint pulse
  travelling along it every 1.2 s. Copy, centered, 64px: at 38.4 **"The voice is
  the recording."**; at 40.6 **"The picture is the camera's own."**; at 42.8
  **"Nothing in between is allowed to touch either."**

### Act III — The goal (45–63). Why this is a company.

- S11 45.0–52.0. The two windows collapse into two glowing dots. The ground
  tilts and a globe resolves: a wireframe sphere (meridians every 20°, parallels
  every 20°, hairlines at 14% cream; back-facing lines at 4%), radius 380px,
  rotating slowly (4°/s) so that both cities stay on the visible hemisphere.
  Two dots pinned to their true coordinates, labelled in mono above them:
  **DELHI** (28.6°N 77.2°E) and **AMSTERDAM** (52.4°N 4.9°E), with a great-circle
  arc between them (slerp on the sphere, lifted 2% above the surface). At 47.0 a
  photon — a bright cream point with a 60px fading trail — leaves Delhi and
  traces the arc to Amsterdam in exactly 1.0 s of screen time; a mono counter
  beside it counts **"0 ms"** → **"40 ms"**, then holds. Copy at 45.5: **"Between
  two people, one delay is real."** Copy at 48.5: **"The time light needs to
  cross the distance."** Copy at 50.5: **"Everything else is a defect."**
- S12 52.0–58.0. Faint arcs bloom from both cities to twenty other cities around
  the globe (use real coordinates: Tokyo, Sydney, São Paulo, Lagos, Nairobi,
  London, New York, San Francisco, Seattle, Toronto, Mexico City, Buenos Aires,
  Cape Town, Cairo, Dubai, Mumbai, Singapore, Jakarta, Seoul, Berlin), each with
  its own small photon. Copy at 52.4, 64px: **"Our goal: under 150 milliseconds.
  Anywhere on Earth."** Copy at 55.5, 48px: **"Lossless sound. A visually
  lossless picture. Measured on live calls, every release."**
- S13 58.0–63.0. The globe fades to two dots that drift toward each other. Copy
  at 58.3, 48px, muted ink: **"Every video call in the world still runs on a 2011
  design that spends your face when the network dips."** Copy at 61.0, cream:
  **"We rebuilt the call from the microphone up. It's shipping."**

### Act IV — Reveal (63–75)

- S14 63.0–68.0. The two dots grow into two large soft orbs, 420px across,
  overlapping by a third — cream left, blue right (the brand mark). At 64.0 the
  wordmark **"Kin"** rises under them at 140px; at 65.2 the tagline in italic,
  40px: **"As close as light allows."**
- S15 68.0–75.0. The orbs and wordmark shrink to 70% and move up; a quiet CTA
  stack fades in below, centered: **"Free on Mac today."** (32px serif); under it
  in mono **"kin.tokkah.com"**; under that, muted, 24px: **"Not on a Mac yet?
  Leave your name — you'll be first."** Hold. The orbs breathe. Everything fades
  to black from 74.2 to 75.0.

## 6. Score (synthesised in WebAudio, deterministic; one function builds the
graph on either a live AudioContext or an OfflineAudioContext)

- Pad: a D drone (D2 73.4 Hz + D3 146.8 Hz, two detuned sines ±3 cents each, a
  triangle at D4 at −12 dB) through a lowpass at 900 Hz, entering over 3 s to
  −26 dBFS. It darkens (lowpass → 400 Hz) through S2–S3 and opens (→ 2 kHz) at
  S4 exactly at 13.0.
- Ripples (S2): soft filtered-noise whooshes (bandpass 400–1200 Hz sweeping
  with the ripple) at −32 dBFS. The collision at ~7.4 s is a short dissonant
  cluster (D + E♭ sines, 300 ms) at −30 dBFS.
- S4 resolve at 13.0: a D-major bell chord (D3 F♯3 A3 D4): each note a sine plus
  2nd and 3rd partials at −10/−16 dB, exponential decay 3 s, through a feedback
  delay (375 ms, feedback 0.35, lowpassed) and a convolver whose impulse is
  generated noise with a 2.5 s exponential decay.
- Typing (S6): 8 ms noise ticks per key at −30 dBFS. Return at 23.0: a slightly
  longer tick. Connected at 24.4: two bell notes A4 → D5, 120 ms apart.
- Syllables (S8/S9): no voice. A very soft murmur — bandpassed noise 200–600 Hz
  following the same envelope that drives the band, at −34 dBFS — so light and
  sound share one envelope.
- Photon (S11 at 47.0): a sine sweep 220 → 880 Hz over 1.0 s at −28 dBFS with
  a soft sub thump at launch (55 Hz, 200 ms). S12's small photons: tiny high
  pings (2–4 kHz sines, 60 ms, −36 dBFS), staggered.
- Reveal (S14 at 63.0): the D-major bell chord again, larger (add D5 and a
  high D6 ping), sustained into the CTA; everything fades out from 73.5 and is
  silent by 75.0.
- Master: DynamicsCompressor (threshold −12 dB, ratio 3, attack 5 ms, release
  250 ms). Peaks never above −3 dBFS. A mute control on the live page.
- Everything scheduled from the timeline's t, never from wall-clock, so
  `seek()` and offline rendering agree exactly with live playback.

## 7. Technical requirements (the page)

- Files: `ad/kin-ad.html` (markup + inline `<style>`), `ad/kin-ad.js` (all
  behaviour — a SEPARATE file because the production site's CSP is
  `script-src 'self'`, no inline scripts). Plus `ad/build.mjs`, which produces
  `ad/kin-ad.single.html` — the same page with the JS inlined — for publishing
  as a standalone artifact. No external resources of any kind: no web fonts,
  no CDN, no images. Fonts are the system stacks in §4.
- A fixed 1920×1080 stage, CSS-scaled with `transform: scale()` to fit the
  viewport (letterboxed on `#05060a`), so it looks identical on every screen.
- Deterministic timeline. Every visual is a pure function of time.
  `render(t)` sets everything from `t` seconds. NO CSS animations or
  transitions that depend on wall-clock — they cannot be seeked. Write a
  keyframe helper `kf(t, [[t0,v0],[t1,v1],...], ease)` for interpolation and
  build every motion from it. Canvases (globe, ripples/particles, grain) are
  redrawn from `t` too; particle systems must be deterministic (seeded PRNG,
  positions computed from t, never accumulated across frames).
- Public API on `window.kinAd`:
  - `duration` (75)
  - `seek(t): Promise<void>` — renders frame `t` and resolves AFTER the frame
    has painted (resolve inside a nested `requestAnimationFrame`), so a
    screenshot taken after the promise is of that exact frame.
  - `play()`, `pause()`, `toggle()`, `time` (getter), `setMuted(bool)`.
  - `renderScoreOffline(sampleRate = 48000): Promise<Float32Array[]>` — builds
    the whole score in an `OfflineAudioContext` and returns the two channels.
  - `transcript` — the full copy in order, as an array of `{t, text}`.
- Player: a centered play control (a cream circle with a triangle, glass
  behind it) that starts the film with sound — required by autoplay policy. A
  thin progress hairline along the bottom (cream, 2px) that fills with time.
  Click anywhere to pause/resume; a mute toggle bottom-right (icon only);
  at the end, a replay control. Query flags: `?autoplay=1&muted=1` starts on
  load without a click (the website hero uses this); `?loop=1` loops;
  `?render=1` hides every control, seeds the grain from the frame index, and
  never auto-plays; `?t=12.5` seeks to a time and pauses (for review).
- Performance: hold 60 fps in Brave, Chrome and Safari on an M-series Mac at
  1920×1080. At most three canvases (globe/arcs, ripples/particles, grain).
  CSS transforms for everything DOM; no layout thrash (read no geometry
  inside `render`); `backdrop-filter` on at most two elements; no `filter:
  blur()` on large elements each frame — pre-render blurred discs once as
  radial gradients instead.
- Accessibility: `prefers-reduced-motion` keeps the film playing but disables
  grain and shattering particles. All copy also exists in a visually hidden
  `<ol id="transcript">`, one `<li>` per line, in order.
- Quality bar for the drawing (the orchestrator will review stills at every
  shot boundary): the portrait must read as a person out of focus and never as
  a clip-art silhouette; the globe must read as a globe at a glance (true
  sphere shading is not needed — the hemisphere fade of the back lines is);
  gradients must show no banding (use the grain, and 16-bit-safe colour steps);
  text must be pixel-crisp (no transforms that leave text on fractional pixels
  at rest).

## 8. Technical requirements (the render pipeline)

`ad/render.mjs`, Node 22, zero npm dependencies.

- Launch Brave headless:
  `/Applications/Brave Browser.app/Contents/MacOS/Brave Browser --headless=new
  --remote-debugging-port=<free port> --user-data-dir=<fresh temp dir>
  --no-first-run --no-default-browser-check --disable-gpu --hide-scrollbars
  --disable-component-update --disable-background-networking
  --window-size=1920,1080 about:blank`. (Verified 2026-09-05: this exposes CDP
  at `http://127.0.0.1:<port>/json/version` within ~3 s. Do NOT use Brave's
  `--screenshot` flag; it hangs.)
- Connect over CDP with Node's global `WebSocket`. Use `Target.createTarget`
  or the page listed at `/json/list`; `Page.enable`, `Runtime.enable`;
  `Emulation.setDeviceMetricsOverride` to 1920×1080 at deviceScaleFactor 1;
  `Page.navigate` to `file://<abs>/ad/kin-ad.html?render=1`; wait for
  `document.fonts.ready` and `window.kinAd`.
- For each frame i at `fps` (default 60): `Runtime.evaluate` with
  `awaitPromise:true` on `kinAd.seek(i/fps)`, then `Page.captureScreenshot`
  `{format:'png'}` → `ad/out/frames/%05d.png`. Print progress every 60 frames
  with an ETA.
- Score: `Runtime.evaluate` on `kinAd.renderScoreOffline(48000)`, encode a
  16-bit stereo WAV in the page, and pull it out in ≤4 MB base64 chunks
  through `Runtime.evaluate` → `ad/out/score.wav`.
- Mux: `ffmpeg -framerate <fps> -i frames/%05d.png -i score.wav -c:v libx264
  -crf 17 -preset slow -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 192k
  -shortest ad/out/kin-ad.mp4`. Also produce `ad/out/kin-ad-hero.mp4`: the
  26.0–38.0 s span, muted, 1280×720, `-crf 22`, for the website hero.
- Flags: `--fps 30` for quick previews; `--from S --to S` for partial renders;
  `--stills N` dumps N evenly spaced PNGs to `ad/out/stills/` and stops (no
  video); `--keep-frames` to keep the PNGs after muxing. Exit non-zero on any
  failure, with the reason; never leave a Brave process behind (kill it on
  exit and on SIGINT).
- Before reporting done, the worker MUST run `node ad/render.mjs --stills 16
  --fps 30` against the real page and look at the stills, and run one full
  `--fps 30` render and check `ffprobe` reports 75.0 s, 1920×1080, and an
  audio stream.

## 9. Non-negotiables

- No competitor names anywhere. No numbers except "150 milliseconds" and
  "40 ms" (the counter) and "2011".
- Plain words only. Never: latency, codec, P2P, PCM, bitrate, jitter, WebRTC.
  "Lossless" appears exactly once, in S12.
- Nothing ever reaches a face: the band glows at the frame, never over the
  portrait.
- The edge never goes dark during the call; only its colour and brightness move.
- Cream is "you", blue is "them", in every act.
- Copy is verbatim from §5.
- Do not touch any file outside `ad/` in this task.
