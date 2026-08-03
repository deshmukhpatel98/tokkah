# fatigue-lab

An A/B rig for the fatigue half of the design (`DESIGN.md` §1.1). Five fixes, each
switchable mid-call, so you can feel what each one is individually worth.

It runs on **ordinary WebRTC media transport**, on purpose. None of these fixes depend
on the custom pipeline, so all of them can be tested before the pipeline exists. When
the transport gets replaced, nothing in this lab changes.

---

## Run it

```bash
cd "/Users/earningsgpt/video calling/fatigue-lab" && npx wrangler dev --port 8793
```

Then open `http://localhost:8793/`.

**Two machines need HTTPS.** `localhost` works for a solo look at the lab, but the
moment a second computer joins over `http://<lan-ip>`, the browser refuses it the
microphone — getUserMedia requires a secure context, and a LAN IP is not one. For a
real two-person session, deploy once (needs the Cloudflare login, one time):

```bash
npm run deploy    # → https://tape-fatigue-lab.<your-subdomain>.workers.dev
```

Then both people just open that URL. No developer needed from that point on.

Two machines, not two tabs. A loopback call shares one camera, one mic, and one
speaker, which defeats the audio test outright and makes the geometry meaningless.

### TURN (optional)

Without secrets the lab is P2P/STUN-only, which is fine on most home networks and on
the same LAN. To add Cloudflare TURN for symmetric-NAT cases:

```bash
npx wrangler secret put TURN_KEY_ID
```

```bash
npx wrangler secret put TURN_KEY_API_TOKEN
```

`/api/ice` mints short-lived (3600s) credentials server-side. The long-term key never
reaches the browser and is never written to `wrangler.jsonc`. If either secret is
absent the endpoint returns `p2pOnly: true` and STUN alone — it degrades, it doesn't
fail.

---

## Two pages

| URL | What it is |
|---|---|
| `/` | The fatigue A/B — five switchable fixes, plus a solo breath-lead meter |
| `/turns` | The turn-taking gate — the falsification test for §1.1c |

---

## /turns — the falsification gate

This is the most important page in the repo, because it is the one that can prove the
design wrong cheaply.

§1.1c claims Zoom loses 179 ms *beyond* its own latency to destroyed turn-end cues
(Boland's 976 ms measured, minus 797 ms explained by latency). Two of §3.1's three
biggest levers rest on that attribution — and it is an **inference**, not a
measurement. Nobody has shown that *restoring* the cues recovers the time.

So: run Boland's paradigm. Timed yes/no questions, two machines, headphones. One run
with raw audio, one with processed. Compare.

### How it measures without clock sync

Everything is timed on the **asker's** clock. Two detectors run per machine — one on
the local mic, one on the *received* remote audio:

```
t0 = my own speech ends          (local detector, 'end')
t1 = their breath reaches me     (remote detector, 'breath')
t2 = their first word reaches me (remote detector, 'voiced')

time to first evidence = t1 − t0     ← the honest perceived gap
time to first word     = t2 − t0     ← what everyone else reports
breath head start      = t2 − t1
human-only             = (t2 − t0) − RTT   ← comparable to Boland Exp 1's 297 ms
                                              LOCAL STRUCTURED-Q&A control, only
                                              if the task is also structured Q&A
```

**No clock synchronisation is involved and none is needed.** That removes the single
largest error source a two-machine timing experiment normally has. Network latency
sits *inside* these numbers rather than being added to them, which is correct — we
want what the human perceived, not a model of it.

RTT comes from WebRTC's own `candidate-pair` stats, so it tracks the real media path
and keeps updating.

### The gate

| Check | Threshold |
|---|---|
| human-only transition | within 120 ms of the 297 ms control — **valid only for a structured-Q&A task**; free conversation should be scored against 135 ms (Boland Exp 2) |
| turns opening with an audible breath | > 50% |
| breath head start | ≥ 100 ms |
| first evidence | < Zoom's measured 976 ms |

Turns are discarded if the reply lands before the question ends (an interruption) or
after 4 s (a distraction). Both are real conversational events; neither is a turn
transition.

**297 ms is not "the" face-to-face number.** It is Exp 1's local control for a
structured Q&A task, paired with that same experiment's 976 ms Zoom arm — which
is why the two are used together here and why the pairing is sound. Boland's
*conversational* face-to-face figure is 135 ms and Stivers 2009's cross-linguistic
mean is ~208 ms. Match the baseline to the task or the gate is simply lenient.

**A FAIL is information, not a bug.** If the human-only figure sits far above 297 ms
with raw audio on, §1.1c's attribution is wrong and §3.1 levers 1–2 need rewriting —
which is exactly what you want to learn before writing an encoder.

Verified with synthetic turns: a raw-audio scenario (RTT 40 ms, ~200 ms breath lead,
300 ms human gap) passes all four checks; a processed-audio scenario (breath gated,
480 ms human gap) fails three of four. Arithmetic cross-checked — `voice − rtt = human`
and `voice − ttfe = credit` both hold exactly. CSV export carries every column plus both
machines' audio modes and the run label, so the two runs can be compared offline.

**Events are timestamped on the AudioContext clock (`ctxTime`), not on message
delivery.** An `end` event is only emitted after 350 ms of quiet, so delivery-time
stamping would anchor t0 ~315 ms late relative to t1 and throw away exactly the fast
turns this experiment exists to collect — the same artefact tape-app's live analyser
hit on a real call (see the comment in `tape-app/public/app.js`). Both detectors share
one AudioContext, so no clock conversion is needed.

---

## The five fixes

| Toggle | Default | What it does | Fatigue cause it targets |
|---|---|---|---|
| **raw audio** | on | `echoCancellation`, `noiseSuppression`, `autoGainControl` all **off**; 48 kHz mono | Deletes the audible inhale and room tone that people use to know whose turn it is — worth ~200 ms (§3.1 lever 1) |
| **life size** | on | Angular-size match against a 1100 mm target | Faces rendered at ~40 cm read as intimacy or threat; the body responds to it for the whole call |
| **gaze aligned** | on | Puts their eye line where the lens is | Sustained mutual gaze without real eye contact |
| **self view** | **off** | Removes the mirror | The one thing no in-person conversation has: watching yourself all day |
| **locked exposure** | on | `exposureMode`/`whiteBalanceMode`/`focusMode: 'manual'`, 2.5 s after join | The webcam hunting — the single loudest "this is a video call" tell |

**Hold SPACE** to flip every *visual* fix off at once and hold the comparison. That is
the fastest way to feel what they're worth. Audio is excluded from the SPACE bundle
because re-acquiring the mic takes long enough to be its own distraction — toggle that
one deliberately.

---

## Calibration, and why it's unavoidable

Life size requires knowing your display's real physical size. A browser cannot know
this: CSS pixels are nominally 1/96", which is fiction on essentially every modern
panel. Matching a known physical object is the only reliable route, so the lobby asks
for three things:

1. **Screen scale** — drag until the box matches a credit card (ISO/IEC 7810 ID-1,
   85.6 mm). Yields `px/mm`.
2. **Viewing distance** — eye to screen, 300–1200 mm.
3. **Your face** — eye line height and temple-to-temple width, as fractions of frame,
   plus your head width in mm (adult average ≈ 150).

All three persist to `localStorage` under `tape.cal`. Face geometry is exchanged over
the signaling channel: each side renders the *other* person, so each side needs the
other's numbers.

### The size math

```
wantHeadMm = peerHeadMm × (yourDistance / 1100)
W          = wantHeadMm × pxPerMm / peerHeadWidthFrac
H          = W × videoHeight / videoWidth
```

1100 mm is Hall's *personal* distance — where conversation actually happens. Not
400 mm, which is what filling a laptop screen simulates.

The formula has a clean self-check: set your viewing distance to exactly 1100 mm and
the rendered head width equals the peer's real head width, literally. Verified —
`headMm = 150.0` at `distMm = 1100`.

Measured on a 3.738 px/mm display at 600 mm:

| Your distance | Head on screen | Frame |
|---:|---:|---:|
| 400 mm | 54.5 mm | 600 × 337 |
| 600 mm | 81.8 mm | 900 × 506 |
| 800 mm | 109.1 mm | 1199 × 675 |
| 1100 mm | 150.0 mm | 1649 × 928 |

Sitting further back means a *larger* on-screen face, which is initially
counter-intuitive and geometrically correct: the same angular size subtended from
further away needs more pixels.

The frame is often wider than the viewport — the readout says `sides cropped —
correct`. Cropping the sides of a 16:9 frame to hold a face at true scale is the right
trade; scaling the face down to fit the frame is not.

---

## Gaze: measured, not claimed

The lab reports the residual angle between "looking at their eyes" and "looking at the
lens", from your seat:

```
gazeErrDeg = atan( hypot(faceCx − camX, eyeY − camY) / pxMm , viewingDistance )
```

This is reported rather than asserted because the browser **cannot** put pixels behind
its own toolbar. There is always a residual on a windowed page, so the honest move is
to show the number and name what closes it. Measured at 600 mm on a 1920×1080 display:

| Situation | Residual | Dominated by |
|---|---:|---|
| Fullscreen | **0.6°** | the 24 px eye-line floor, and nothing else |
| Windowed 1400 px, centred, 120 px chrome | 3.7° | browser chrome (`dy = 144`) |
| Windowed 865 px at `screenX = 0` | 6.3° | window not under the lens (`dx = −248`) |
| **Gaze fix off** (frame centred) | **16.6°** | — |

The readout names whichever axis dominates, because "go fullscreen" alone doesn't tell
you *why* — and the two failures have different causes.

**The finding worth carrying into the design:** fullscreen is not cosmetic here, it is
load-bearing. It is the difference between 3.7° and 0.6° — roughly a 6× reduction in
gaze error, for free. Any real client should be fullscreen or near-borderless by
default, and this is the measurement that says so.

No ML gaze correction, deliberately. Warping someone's eyes synthesises data the
sender never produced, which violates invariant 4. Moving a rectangle is honest.

---

## A bug worth knowing about

The first version of `layout()` clamped the video frame's `top` to `−0.12 × H`, meaning
gaze alignment **never ran**: putting an eye line at the top of the viewport requires
`top ≈ −0.42 × H`, so the clamp won on every frame at every setting. The symptom was
subtle — the layout looked plausible and the eye line was merely *lowish*.

The fix was to clamp the **face**, not the frame: constrain the eye line's on-screen Y
and the head's centre X, then derive the frame position from those. Hair, ceiling and
room are croppable; the head is not.

General lesson, and the reason it's recorded here: a clamp that silently defeats the
feature it's protecting produces output that looks fine. Nothing errors. This is the
same failure class as the phase-1 harness reporting 60 Mbps against a 12 Mbps target —
plausible numbers are more dangerous than missing ones.

---

## What this lab does not test

- **Latency.** Ordinary WebRTC transport, so latency is Zoom-class. That's
  `phase1-transport`'s job.
- **Lossless video.** WebRTC picks its own quantizer. `maintain-resolution` +
  6 Mbps cap keeps it from shrinking the picture — which would break life size — but
  it's a stopgap, not the §6 encoder.
- **Anything on one machine.** See above.

## Files

| Path | Role |
|---|---|
| `src/worker.ts` | Signaling + `/api/ice`. Deliberately duplicated from phase 1 so experiments can't break each other. |
| `public/lab.js` | All five fixes, calibration, geometry, and the solo breath meter. `window.__lab` exposes `{state, cal, layout, peerGeom, turns, handleOnset}`. |
| `public/index.html` | Lobby (calibration + breath meter) and call surface. |
| `public/turns.html` · `turns.js` | The §1.1c falsification gate. `window.__turns` exposes the scoring path. |
| `public/onset-worklet.js` | AudioWorklet wrapper around the shared detector. Runs on the audio thread — the main thread will hand you a 50 ms hitch during layout and spend a quarter of the head start on nothing. |
| `public/onset-monitor.js` | Creates detectors over a MediaStream. One shared `AudioContext` so timestamps share an origin. |
| `public/core` → `../../core` | Symlink to the shared media core. Served directly by `wrangler dev`, no build step. |

### Step 4 of the lobby needs no peer

The breath meter runs on your own mic, so the largest claim in the design is testable
by one person alone: say a few sentences with pauses and read the median lead. It uses
a **separate, always-raw** mic stream, deliberately — an instrument whose sensitivity
changes when you flip the thing you're measuring is useless, and it means you can A/B
processed vs raw call audio while the measurement stays comparable.

See `core/README.md` for the detector's measured latency, sensitivity floor, and
reported-lead bias.

### Poking at the geometry without a camera

`window.__lab` is settable, so the layout math can be exercised with synthetic values —
which is how the numbers above were verified:

```js
__lab.peerGeom = { eyeLineY: 0.42, headWidthFrac: 0.34, headMm: 150 };
__lab.cal.distMm = 600;
__lab.layout();
__lab.layout.info;   // { W, H, wantHeadMm, gazeErrDeg, dx, dy, cropped }
```
