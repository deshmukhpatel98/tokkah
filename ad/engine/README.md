# The ad engine

A product brief goes in; a finished, voiced, 1920×1080 brand film comes out.
Astra (`gpt-6-astra`, through the Experiential Labs gateway) does the
thinking: the tension, the idea, the tagline, the palette, the shot plan, the
narration, the voice casting. This code does the rendering: a deterministic
DOM + Canvas 2D film drawn from Astra's JSON, captured frame-exact in headless
Brave, muxed by ffmpeg, voiced by ElevenLabs (Eleven v3, lossless PCM).

```bash
EXPLABS_API_KEY=… ELEVENLABS_API_KEY=… \
node ad/engine/produce.mjs --product "Halcyon, a bedside sunrise lamp" \
  --audience "people who hate their phone alarm" --duration 40 --variants 3
# -> ad/engine/out/halcyon-a-bedside-sunrise-lamp/{spec.json, ad.html, final.mp4, contact.png}
```

Keys live in the environment only. Nothing here writes a secret to disk.

## Built for speed

Every stage that can overlap does. The critical path is one Astra call, then
one render slice, then one ffmpeg pass.

1. **Author: one call.** `generate.mjs` asks Astra for the whole ad as a
   single strict-JSON object (about 700 prompt tokens, one round trip, no
   context re-sent between stages). `--variants N` fires N candidates
   concurrently with different creative angles and a tiny `low`-effort judge
   picks one. Astra's `max` reasoning is not used: the gateway kills requests
   near 600 s and `max` never returns on a real prompt; `high` does, in
   20–60 s for this prompt size. `gateway.mjs` falls back one tier on a
   timeout or a 5xx.
2. **Build: inline.** `build-ad.mjs` writes one self-contained `ad.html`
   (spec + `render-lib.js` inlined, no external resources), hostable as-is.
3. **Render: K browsers at once.** `produce.mjs` splits the timeline into K
   slices (default: half your cores, max 6) and runs `ad/render.mjs` on each
   with `--out <dir> --no-score`, while a K+1th instance renders the score
   (`--score-only`) and `voice.mjs` synthesises every narration line in
   parallel. A single browser captures roughly 3 frames/s at 1080p; six cut a
   40 s film from ~7 minutes to under 2.
4. **Assemble: copy, don't re-encode.** Slices are concatenated with the
   ffmpeg concat demuxer (`-c copy`), the score is muxed once, the voice is
   ducked under it with a sidechain compressor, and `final.mp4` is written.
5. **Stills.** A 4×2 contact sheet for review.

`produce.mjs` prints a per-stage timing table. `--spec` skips authoring and
renders an existing spec; `--no-voice` skips ElevenLabs.

## The contract Astra writes to

`render-lib.js` implements a fixed primitive library; the authoring prompt is
generated from the same list, so the JSON is always renderable:

| primitive | what it is | the params |
|---|---|---|
| `title` | a full-frame type card | `copy`, `size`, `sub` |
| `glow` | a light field whose intensity ramps across the shot | `color A/B/ink`, `from`, `to`, `x`, `y`, `radius`, `curve` |
| `shape` | an object Astra draws as an SVG path in a 0..1000 box | `path`, `fill`, `stroke`, `strokeWidth`, `size`, `x`, `y`, `motion`, `glow` |
| `portrait` | one person on a video call, edge light at the frame | `who`, `edge` |
| `duo` | two call windows, the floor passing back and forth | — |
| `planet` | a lit planet with one route of light there and back | `from`, `to`, `number` |
| `mark` | two overlapping light discs and the wordmark | `wordmark`, `tagline` |
| `cta` | the end card | `lines[]` |

`glow` and `shape` are what make the engine product-agnostic: Astra can draw
a lamp, a phone, a cup, and light it. `portrait`, `duo` and `planet` are the
vocabulary of the hand-made Kin film and only make sense for products about
people talking or distance; the prompt says so.

`generate.mjs` repairs what Astra gets wrong (unknown primitives, gaps in the
timeline, bad hexes, paths with stray characters, a voice not in the roster)
rather than failing.

## Honest limits

- **Nothing here guarantees virality.** The engine produces a strong,
  consistent, fast first cut and a measurable loop. What travels is decided
  by distribution and audiences.
- **Quality bar.** The hand-tuned Kin film (`ad/kin-ad.js`) was made over a
  day with two director's treatments and three review passes. A one-call
  engine ad is a rough cut by comparison: fewer transitions, generic shot
  timing, portraits reused. The intended loop is: generate → review the
  contact sheet → re-author with notes → render.
- **Not 3D.** This is a 2D canvas with a shaded sphere; there is no WebGL
  pipeline. Frame-exact seeking, the thing that makes the render
  deterministic, is much harder with a 3D engine and is not attempted.
- **Voice** is Eleven v3 at 44.1 kHz PCM (falls back to 192 kbps MP3 if the
  plan refuses PCM). v3 takes ~20 s per line; lines run in parallel.

## Files

- `gateway.mjs` — Astra client: streamed, effort fallback, JSON extraction.
- `generate.mjs` — one-call authoring, variants, judge, repair → `spec.json`.
- `render-lib.template.js` → `render-lib.js` — the renderer (the portrait and
  mark modules were written by Astra to a fixed signature and stitched in).
- `engine.html`, `build-ad.mjs` — the page shell and the single-file build.
- `voice.mjs` — ElevenLabs lines in parallel, timed track, ducked mix.
- `produce.mjs` — the whole pipeline with parallel render slices and timings.
- `out/<slug>/` — everything for one ad.
