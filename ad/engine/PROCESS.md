# What made the hand-made film good, and how the engine now does the same

The Kin film (`ad/kin-ad.js`) took one day and reads as a film. The first
engine ad (Halcyon, `out/halcyon-v2`) took four minutes and reads as a
slideshow. The difference is not the model. It is the process the model was
allowed to run. This file is the study of that process and the design of
engine v2 around it.

## The eight things the hand-made process had

| # | In the hand-made film | In engine v1 (Halcyon) | Engine v2 |
|---|---|---|---|
| 1 | **A treatment in prose first.** Two director's treatments named a governing idea ("the film begins by losing someone"), a motif, an arc, and per-shot direction with numbers. | One call filled JSON slots. No idea was allowed to be bigger than a slot. | `direct.mjs` stage 1: N treatments in parallel (different angles), one judge. The treatment is the source of truth; the shot plan is extracted from it. |
| 2 | **A motif that recurs.** The three-stroke light phrase appears in Act I, at the call edge, across the gap, and lights the mark. | Nothing recurs. | The treatment must name one motif and where it returns; every shot module receives its description and draws it with `lib.line`/`lib.glow`. |
| 3 | **Transitions that mean something.** The repaired stroke bends into the window frame; the windows' lower edges become the globe's curves; two lights leave the windows and become the mark. | Every shot fades in and out on black. | Each shot receives `prev` and `next` (their direction and a named hand-off object) and must implement its own entrance from the previous shot's last state and its exit into the next. |
| 4 | **Code per shot, not data.** The best pieces (the portrait, the mark) were bounded functions Astra wrote to a fixed signature; everything else was hand-written `render(t)` code with easing, breathing, envelopes. | Eight fixed primitives with one motion preset each. | Astra writes `function shot(c)` for every shot, in parallel, against a documented drawing library (`host.js` exposes `lib` and `dom`). Primitives remain only as the fallback when a module throws. |
| 5 | **Stills, then a critique with the picture in front of the critic.** Three review rounds on contact sheets, one of them by Astra with the image attached. | No one looked. | After the smoke test: 10 stills → contact sheet → Astra image critique → JSON notes per shot → the flagged shot modules are rewritten with the notes, in parallel → stills again. `--rounds N`. |
| 6 | **A score written to the picture.** A three-event motif, a harmonic plan, hits on the visual beats, loudness measured and set. | A generic pad and a breath per shot. | Astra writes the WebAudio score to the treatment's beat list; the assemble step measures LUFS and true peak and applies the correction gain, every time. |
| 7 | **A type system.** 88/72/64/56, fixed positions, 480 ms in, 280 ms out, authored line breaks. | Generic. | `dom.copy` enforces the system; the treatment chooses sizes from it. |
| 8 | **A smoke test before the expensive render.** `render.mjs --stills`, `fps-probe.mjs`, ebur128. | None; the first full render found the bugs. | `smoke.mjs` seeks every shot at three times in a headless browser, collects thrown errors and ms/frame, and `direct.mjs` sends failures back to Astra for a repair pass before any stills. |

## Three notes from the first v2 screening (Onefold), and what they changed

The user's verdict on Onefold: the narration was barely there, the pace was
slow, and the film sold an idea without showing the product. All three were
the Kin film's taste leaking into the engine's prompts ("silence is welcome",
"Apple-quiet", "0 to 4 lines", shots no shorter than 2.5 s). They became
brief-level parameters and one new stage:

| note | before | now |
|---|---|---|
| narration | 0-4 lines, silence welcome | narration-led by default: about 2.2 words per second, lines timed to cover the film, the picture serves the words; `--words N` |
| pace | 6-9 shots, 600-1400 ms motion | `--tempo fast` (default): 12-18 shots for 45 s, something changes every 2-3 s, camera moves, a pulse in the score; `--tempo measured` keeps the old grammar |
| the product | each shot drew its own approximation | a product illustration stage: Astra draws the product once as 8-16 tagged SVG layers with gradients, in parallel with the shot code; every shot renders it through `lib.product`, so it is identical everywhere; the treatment must put it on screen 40% of the time with a hero at 60% frame height |

`voice.mjs` now ripples lines apart so narration never overlaps and reports
spoken seconds; the critique judges product visibility and pace explicitly.

## What stays from engine v1

The speed design: one-call JSON where JSON is enough (the plan extraction),
parallel candidates instead of serial stages, parallel shot-module calls,
parallel render slices, voice lines in parallel, `--reuse`. The token
discipline: every prompt is generated from the same library documentation the
host implements, so model output is always against a real contract.

## The rule for the next change

Before adding a stage, ask which of the eight rows it serves. Before removing
one, ask which row it breaks. When the output looks like a slideshow, it is
rows 2 and 3. When it looks amateurish, it is row 5. When it is silent or
loud, it is row 6.
