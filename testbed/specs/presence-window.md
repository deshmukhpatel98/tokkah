# Presence Window — a research brief on depth, scale and self-perception for a two-person call

Status: research brief + ranked build queue. Not yet a build spec (candidate 1 has a
build sketch detailed enough to spec from).
Date: 2026-08-11.
Scope constraints assumed throughout: two people, Chrome + Safari, no wearables, one
fixed webcam per side, nothing may add latency to the existing audio/video pipeline
(extra work must be compositor/GPU-side or idle-time), everything ships default-on and
must therefore be subtle and do-no-harm.

---

## 0. What the product already gets right (so the brief doesn't re-litigate it)

Two things in `tape-app/public/app.js` and `index.html` matter for everything below,
and both are already correct:

- **Self-view is default OFF after peer arrival.** `peerArrived()` deliberately does
  not force the PiP on, citing Bailenson (2021) and Fauville et al. (2021). Section 1
  of this brief confirms that is the single best-evidenced UI decision in the app, and
  quantifies how much it buys.
- **The remote view is already a two-layer composite.** `#remoteFill` is a 32×18 canvas
  resampled and blurred (`blur(28px) brightness(.42) saturate(1.25) scale(1.14)`) at
  z-index 0; `#remote` / `#remoteCanvas` is the contain-fit picture at z-index 1
  (`index.html:250-277`). **This is already the layer separation that head-coupled
  parallax needs.** That single fact is why candidate 1 below is cheap. Nobody has to
  build segmentation or depth estimation to get a first convincing window.

The `?l2canvas=1` default display path already paints decoded frames onto a canvas, so
any geometric transform can be a `ctx.setTransform` on the existing `drawImage`, or a
CSS `transform` on the canvas element — either way it is a compositor-side change with
no touch of the decode or the audio path.

---

## 1. Self-perception on calls: what dose of mirror is harmful

### 1.1 The theory (Bailenson 2021)

Jeremy Bailenson, *"Nonverbal Overload: A Theoretical Argument for the Causes of Zoom
Fatigue,"* **Technology, Mind, and Behavior 2(1)**, 23 Feb 2021 — the first peer-reviewed
psychological deconstruction of videoconference fatigue. Four mechanisms:

1. **Excessive close-up eye contact.** Two separate problems fused: (a) everyone looks
   at everyone all the time, so a *listener* is treated nonverbally like a *speaker*,
   which recruits the public-speaking anxiety response; (b) **apparent face size**. On a
   typical monitor at typical viewing distance, a one-on-one call renders the other
   person's face at an angular size that "simulates a personal space that you normally
   experience when you're with somebody intimately" — Hall's intimate zone (0–18 in /
   0–0.45 m). Bailenson's claim is that the brain reads a face at that apparent distance
   as a precursor to mating or conflict and holds the viewer in a **hyper-aroused
   state** for the duration of the call.
   *His recommended fix is purely geometric: get out of full-screen, shrink the window,
   push the keyboard away to enlarge the personal-space bubble.* That is a scale
   intervention, and it is the research base for candidate 2.
2. **The all-day mirror.** "In the real world, if somebody was following you around with
   a mirror constantly … that would just be crazy." Recommends platforms change the
   default of beaming video to self as well as others.
3. **Reduced mobility.** A fixed camera field of view pins the body in place; movement
   improves cognition, so pinning it costs.
4. **Cognitive load of nonverbal production.** Exaggerated nods, thumbs-up, keeping the
   head centred in frame — "mental calories" spent on signalling that is free in person.

*(Note for this product: mechanism 1a — hyper-gaze from a grid of staring faces — is
largely a group-call artefact and mostly does not apply at N=2. Mechanism 1b, apparent
face size, applies **more** at N=2 because the single remote face is full-screen.)*

### 1.2 The measurement (ZEF scale, and the N=10,591 study)

Geraldine Fauville, Mufan Luo, Anna Carolina Muller Queiroz, Jeremy Bailenson, Jeff
Hancock — *"Zoom Exhaustion & Fatigue Scale,"* **Computers in Human Behavior Reports**
4:100119 (2021). 49 items reduced to 15, five factors: general, social, emotional,
visual, motivational fatigue.

Companion paper, *"Nonverbal Mechanisms Predict Zoom Fatigue and Explain Why Women
Experience Higher Levels than Men"* (SSRN 3820035, later published in **Computers in
Human Behavior Reports** 2023). Read the full text; the numbers are:

- **N = 10,591** (ZEF distribution computed on N = 10,332; mechanism regression on
  N = 7,846).
- Multiple linear regression of the five mechanisms on ZEF score was significant,
  and **every mechanism was an independent positive predictor**: mirror anxiety
  **B = .17, SE = .06, p < .001** — the **largest** of the five; hyper-gaze B = .09,
  SE = .01, p < .001; producing/interpreting nonverbal cues around B = .06, SE = .01.
- Gender differences (Cohen's d): mirror anxiety **d = .57** (largest), physically
  trapped d = .40, hyper-gaze d = .33.
- Mediation: the gender→fatigue effect was significantly mediated by mirror anxiety,
  **ACME = .19, 95% CI [.16, .20]**. Replicated with an *independent* linguistic marker
  — first-person-singular pronoun rate in open-ended text (Tausczik & Pennebaker's
  self-focused-attention marker) correlated with mirror anxiety (r = .09, p < .001) and
  with fatigue (r = .06, p < .001), and itself mediated the gender effect
  (ACME = .01, small but significant).
- In the multiple-mediator model, the indirect effects of **mirror anxiety and feeling
  physically trapped were significantly larger than hyper-gaze or nonverbal production**
  (χ²(1) > 44.4, p's < .001).

So: of the four Bailenson mechanisms, the two that dominate at N=2 are **the mirror**
and **feeling physically trapped** — i.e. *self-view* and *fixed viewpoint*. That is a
remarkably precise mandate for this brief: kill the mirror (done) and unpin the
viewpoint (candidate 1).

### 1.3 Does the causal evidence hold up? (honest answer: partially)

The 10k study is cross-sectional self-report. The experimental follow-ups are messier
and it would be dishonest to present the effect as settled:

- Jin Xu, Eoin Whelan, Ann O'Brien, Denis O'Hora, *"Does Self-View Mode Generate More
  Videoconferencing Fatigue in Women than Men? An Experiment Using EEG Signals,"*
  **Cyberpsychology, Behavior, and Social Networking** (2024). N = 32 (16 M / 16 F),
  within-subject, real live meeting with self-view on and off. **Confirmed** the main
  effect — significantly greater alpha activity with self-view ON (alpha power being a
  standard fatigue/disengagement index). **Did not replicate** the gender moderation,
  and alpha did not grow across a 20-minute session.
- Li & Lee, *"Filters uncovered,"* **Telematics and Informatics Reports** 11 (2023),
  N = 154 dyadic 2×2: AR beauty filters intended to reduce self-focus **increased**
  videoconference fatigue, and neither filters nor self-view moved affect. Cosmetic
  softening of the mirror is not a fix; removing it is.

**Dose read.** The defensible synthesis is: self-view harm is *tonic, not phasic* — it
scales with exposure duration, not with a within-session ramp (Xu et al. found no
20-minute ramp; Fauville et al. found fatigue rising with total daily videoconference
minutes and shorter breaks). The useful dose of self-view is therefore **brief,
self-initiated, and framing-related**: enough to confirm you are in frame, then gone.
That is exactly the design already specified in `frame-sense.md` (transient peripheral
edge cue, motion-breathing low-opacity tile) and it is well-supported. A persistent
tile is the harmful arm.

### 1.4 Background manipulation is not a free win

Relevant because two of the candidates below are tempted to synthesise or blur
background. Two 2024–25 results argue for restraint:

- *"Exploring the links between type and content of virtual background use during
  videoconferencing and videoconference fatigue,"* **Frontiers in Psychology** 15:1408481
  (2024): virtual-image backgrounds produced the **highest** fatigue; **blurred
  backgrounds also produced higher fatigue than static images**. Proposed mechanism:
  segmentation artefacts intermittently reveal the real room, and each reveal is new
  information → extraneous cognitive load.
- Follow-up in **International Journal of Human–Computer Interaction** (2025) on
  attention control: differing backgrounds raised attention-control demand → cognitive
  load → negative affect → fatigue.

**Design consequence, and it is a hard one:** *any feature whose failure mode is a
flickering segmentation boundary is a fatigue-increasing feature.* This is the single
strongest argument in this brief against segmentation-based 2.5D as a first build.

---

## 2. Presence and depth: how strong is the window illusion, really

### 2.1 The founding results

- Colin Ware, Kevin Arthur, Kellogg S. Booth, *"Fish Tank Virtual Reality,"*
  **INTERACT '93 / CHI '93**, pp. 37–42. Defines fishtank VR: perspective projection on
  an ordinary monitor coupled to head position. The headline number that matters here:
  in their tree-tracing task, **error rate was 14.7% with stereo alone but 3.2% with
  head coupling alone** — they concluded head coupling is *probably more important than
  stereo* for the impression of three-dimensionality. **This is the licence for a
  monocular, no-glasses, single-webcam window.** The illusion does not need stereo.
- Johnny Chung Lee, *"Head Tracking for Desktop VR Displays using the Wii Remote"*
  (2007–08; TED 2008; CMU). Two IR LEDs on the head + the Wii Remote's 1024×768 / 100 Hz
  IR camera → view-dependent rendering that "transforms your display into a portal."
  Not a peer-reviewed perceptual study, but it is the canonical existence proof that
  **coarse, cheap, monocular head tracking is enough** for a compelling portal, and its
  100 Hz / low-latency sensing is precisely the property a webcam pipeline lacks.
- The counterweight, which the operator should hear: Dan Zhang / Ware-lineage work
  reported in **PRESENCE** 27(2):206 (2018), *"User Behavior and the Importance of Stereo
  for Depth Perception in Fish Tank Virtual Reality"* — for tasks requiring **depth
  acuity**, users rely on stereopsis more than on motion parallax, and parallax-only
  performance is poor. Read together with Ware 1993, the resolution is:
  **head-coupled parallax is excellent for the *feeling* of a volumetric scene and poor
  for *metric depth judgement*.** For a video call, feeling is the whole product and
  metric depth is worth nothing. That asymmetry is favourable.

### 2.2 How much latency before the illusion breaks

This is the number that decides whether the feature is shippable in a browser.

- Jason Jerald & Mary Whitton, *"Relating Scene-Motion Thresholds to Latency Thresholds
  for Head-Mounted Displays,"* **IEEE VR 2009** (and UNC TR 10-013). Measured on
  head-mounted displays with active head yaw:
  - **latency JND mean 16.6 ms (SD 9.7; range 3.2–51.0 ms)**
  - **PSE mean 38.9 ms (SD 18.1; range 9.9–103.2 ms)**
  - governing relation **θ′ = Δt · φ″** — peak erroneous scene velocity equals latency
    times peak head acceleration.
  - Their recommendation for HMDs: end-to-end latency **≈5 ms**.
- Ellis, Adelstein, Mania and colleagues (NASA Ames / Univ. of Kent line of work,
  2004–2010) place display-lag detection thresholds for well-trained observers **below
  20 ms**, with fidelity degradation from **40–60 ms**; and show thresholds are not
  strongly affected by field of view or psychophysical technique.

**The honest translation to this product.** A webcam face tracker in a browser gives, at
best: 30 fps capture (33 ms) + detector inference (5–15 ms) + rAF/compositor
(16–33 ms) ≈ **60–90 ms motion-to-photon**. That is 2–5× the HMD latency JND. If this
product tried to build a *rigorous* fishtank VR window, it would fail on latency and it
would feel like jelly.

**The escape hatch is `θ′ = Δt · φ″` itself.** Perceived error is proportional to
*latency × head acceleration × parallax gain*. The product controls the gain. Ship the
parallax at a **low gain** (a few percent of screen width for a full natural head
excursion) and apply **critically-damped smoothing**, and the erroneous scene velocity
stays under the scene-motion threshold even at 80 ms of lag. The trade is: a low-gain
window is not a Johnny-Lee portal. It is a *subtle* window. Given "features ship
default-on so they must be subtle and do-no-harm," low gain was the required design
point anyway. **The constraint and the latency budget agree.** That is the central
technical finding of this brief.

Corollary, equally important: **never chase the head with a spring that overshoots**,
and **never let the picture keep moving after the head stops**. Overshoot converts a
latency problem into an oscillopsia problem, and the literature on scene motion is
unambiguous that scene motion during head movement is the thing observers report.

### 2.3 The operator's instinct, evaluated honestly

> *"Head-coupled parallax makes the remote video a window."*

**Correct in mechanism, and correct that this is the right family of effect.** Ware 1993
supports monocular head coupling as the dominant cue for three-dimensionality. And the
product's north star — "sitting next to the person" — is fundamentally a *spatial*
claim, which no amount of audio fidelity can carry alone.

**But the known objection is real and must be designed around.** A flat remote video has
**zero internal parallax**. Translating a flat picture in response to head motion
produces a rigid image displacement with no differential motion between near and far
points — the retinal signature is that of *a photograph being slid around*, not a scene
being looked into. The kinetic-depth / motion-parallax literature is clear that depth
from parallax comes from **differential** retinal velocity across depth planes
(see Rogers & Graham's classic parallax work, and the motion/pursuit-ratio model of
Nawrot & Stroyan, e.g. *"Modeling depth from motion parallax with the motion/pursuit
ratio,"* Frontiers in Psychology 2014 / PMC4186274). No differential velocity, no depth.
Naive whole-frame parallax on a flat video is a well-founded criticism.

**The cheapest convincing layer separation — and it already exists in the codebase.**
There are four options, in ascending cost:

| # | Layer separation | Cost | Verdict |
|---|---|---|---|
| A | **Aperture framing**: contain-fit picture plane moving inside a fixed blurred surround | **~0** — already built (`#remote` over `#remoteFill`) | **Ship this** |
| B | Person/background segmentation → 2 planes | MediaPipe Selfie Segmentation, 144×256 or 256×256 MobileNetV3-derived, full-GPU pipeline; a few ms/frame on strong tier | Deferred — boundary flicker is a *documented fatigue source* (§1.4) |
| C | Monocular depth → continuous 2.5D mesh warp | Depth Anything V2 Small = 25M params, DINOv2 ViT-S + DPT decoder; ONNX quantised ~18–26 MB; WebGPU only, Safari support absent/unreliable | Not viable per-frame in 2026 Safari |
| D | Depth + disocclusion inpainting (Shih, Su, Kopf, Huang, *"3D Photography using Context-aware Layered Depth Inpainting,"* CVPR 2020) | Offline-grade | Not viable live |

Why **A** is not a cheat. The illusion the operator wants is *"window into a room."* A
window has two perceptually necessary parts: **the scene** and **the frame the scene is
seen through**. In a contain-fit letterboxed layout, the blurred wash *is* the frame —
it is a static, screen-locked surround at a different apparent depth from the picture.
Moving the picture plane against a static surround creates **exactly the differential
retinal velocity the parallax literature requires**, between the aperture edge and the
scene. The percept is not "a photograph sliding" — it is "a scene shifting behind an
aperture," which is the definition of looking through a window and is the same trick a
peephole plays. It gets *genuine* two-plane parallax without a single pixel of ML.

The remaining loss is that the *person* and *their room* stay in one plane, so leaning
sideways does not reveal any of the wall behind their head. That is the honest
limitation, and it is invisible at low gain because at low gain nobody expects a reveal.

Precedent that low-amplitude two-plane parallax is enough for consumers to read as
depth: **Apple's iOS 26 "Spatial Scenes"** — on-device separation of a still photo into
foreground/mid/background layers, shifted at different rates against
gyroscope/accelerometer motion, shipped as a lock-screen default on iPhone 12 and later
without special sensors. Small amplitude, few layers, no stereo, no inpainting-grade
disocclusion, and the consumer read is "3D." Also **Apple Vision Pro Spatial Personas**
(visionOS 1.1, April 2024) for the far end of the same axis: full shared spatial frame
between two people, which is the effect this brief is approximating on hardware that
costs nothing.

---

## 3. What makes a conversation feel like home

### 3.1 Social presence

John Short, Ederyn Williams, Bruce Christie, *The Social Psychology of
Telecommunications* (Wiley, 1976). Social presence = "the degree of salience of the other
person in the interaction and the consequent salience of the interpersonal
relationships," treated as a property **of the medium**, varying with its capacity to
carry nonverbal cues. The whole framing of this brief — that a medium can be engineered
to raise or lower felt presence — is Short/Williams/Christie's.

### 3.2 Proxemics and apparent size (this is the underrated one)

- Edward T. Hall, *The Hidden Dimension* (1966): intimate 0–18 in (0–0.45 m), personal
  1.5–4 ft (0.45–1.2 m), social 4–12 ft (1.2–3.7 m).
- Michael Argyle & Janet Dean, *"Eye-contact, distance and affiliation,"* **Sociometry**
  28:289–304 (1965): **equilibrium theory** — mutual gaze and interpersonal distance are
  inversely coupled; when one rises past comfort, the other compensates.
- Jeremy Bailenson, Jim Blascovich, Andrew Beall, Jack Loomis,
  *"Equilibrium Theory Revisited: Mutual Gaze and Personal Space in Virtual
  Environments,"* **Presence** 10(6):583–598 (2001), and *"Interpersonal Distance in
  Immersive Virtual Environments,"* **PSPB** (2003): the compensation is **automatic and
  survives into mediated/virtual representations** — people maintain personal space
  around a virtual agent that gazes at them, and **women compensate more strongly than
  men**.

Chain the three together and you get the sharpest under-exploited insight available to
this product:

> A full-screen remote face renders at intimate-zone angular size. Equilibrium theory
> says the viewer must then compensate — by breaking gaze, leaning back, or absorbing
> arousal. On a call, leaning back does nothing (the face does not shrink) and breaking
> gaze is socially costly. **The compensation channel is blocked, so the arousal has
> nowhere to go.** That is a mechanistic account of Bailenson's "hyper-aroused state,"
> and it predicts that (a) rendering the face at *social/personal* angular size and
> (b) *letting the face shrink when the viewer leans back* would both discharge it.

(b) is the same head tracker as candidate 1, on the z axis. This is why candidates 1 and
2 are the same build. The one-line version: **make leaning back work again.**

### 3.3 Gaze and eye contact

- Milton Chen, *"Leveraging the asymmetric sensitivity of eye contact for
  videoconference,"* **CHI 2002**: tolerance for gaze deviation is asymmetric; roughly
  ±5° is the operating envelope.
- Alice Gao, Samyukta Jayakumar, Marcello Maniglia, Brian Curless, Ira
  Kemelmacher-Shlizerman, Aaron R. Seitz, Steven M. Seitz, *"Don't look at the camera:
  Achieving perceived eye contact in remote video communication,"* **Journal of Vision**
  25(11):8 (2025); arXiv:2404.17104. 57 cm viewing distance (typical VC geometry).
  Key result: **perceived eye contact peaks at ≈1.76° *below* the camera axis**, not at
  it — looking straight into the lens is perceived as looking slightly *upward*.
  Reported loss-of-eye-contact thresholds: **4.5° above and 5.5° below** the camera.
- Jesper Kjeldskov et al. / the "snap to contact" account: unless certain the other is
  *not* looking, perceivers bias toward reading eye contact. Perception is generous;
  geometry only has to get inside the cone.

**Product consequence.** With a laptop at 57 cm, 5° ≈ 5 cm of screen. Where the remote
eyes sit on the screen decides whether both parties fall in the eye-contact cone, and it
is a **free, static, layout-only** decision — no ML, no pixels touched. Most products
never make it deliberately. This is candidate 3.

### 3.4 Turn-taking latency — the bar the audio side has already cleared

- Tanya Stivers, N. J. Enfield, Penelope Brown, Christina Englert, Makoto Hayashi, Trine
  Heinemann, Gertie Hoymann, Federico Rossano, Jan Peter de Ruiter, Kyung-Eun Yoon,
  Stephen C. Levinson, *"Universals and cultural variation in turn-taking in
  conversation,"* **PNAS** 106(26):10587–10592 (2009). Ten languages including small
  unwritten ones; **unimodal peak of response within 200 ms of question end**; modes
  0–200 ms, means 7–468 ms, cross-language variation within ~250 ms of the mean. Turn
  transition timing is a human universal, and 200 ms is the shape of it.
- **ITU-T G.114** (05/2003): ≤150 ms one-way is "essentially transparent interactivity";
  400 ms generally unacceptable; and explicitly, **highly interactive tasks including
  videoconferencing may be affected below 100 ms**.
- Katrin Schoenenberg, Alexander Raake, Judith Koeppe, *"Why are you so slow? —
  Misattribution of transmission delay to attributes of the conversation partner at the
  far-end,"* **International Journal of Human-Computer Studies** 72(5):477–487 (2014).
  The most important social-psychological result in real-time comms: with symmetric and
  asymmetric delay (tested up to 1200 ms), listeners **do not perceive the delay as
  delay** — they perceive the *partner* as less attentive, less friendly, less
  conscientious. Latency is silently converted into a negative judgement of a person.

**Why this matters for a brief about video.** The product's sub-50 ms mouth-to-ear puts
it far inside the Stivers window and far inside G.114's stricter clause — it is already
buying the thing Schoenenberg showed is at stake. Therefore: **the constraint that no
visual feature may add pipeline latency is not conservatism, it is the whole moat.**
Every candidate below is architected as viewer-local compositor work precisely so it
cannot spend that moat. Anything that would put a model in the send or receive path is
disqualified on this ground alone, regardless of how good it looks.

### 3.5 F-formations

Adam Kendon, *Conducting Interaction* (CUP, 1990), ch. 7, and *"Spatial organization in
social encounters: the F-formation system."* Participants sustain a spatial/orientational
arrangement giving equal, direct, exclusive access to a shared **o-space** (the convex
space between them); **p-space** is the band they stand in; **r-space** beyond. At N=2 the
canonical forms are **vis-à-vis** (associated with competitive/confrontational
interaction) and **L-shape** (associated with cooperative interaction).

Uncomfortable implication for every video call ever built: **a full-screen frontal face
is a permanent, inescapable vis-à-vis with no o-space at all.** Two people sitting
together in a room almost never hold rigid vis-à-vis for an hour; they drift to L, share
an o-space with objects in it, and re-form. This is the deepest structural gap between a
call and "sitting next to someone," and it is *not* addressable by parallax, scale, or
gaze. Naming it is the honest thing to do; a shared o-space is a much larger product bet
(shared spatial content between the two views) and is out of scope here. Flagged as the
long-horizon multiplier.

---

## 4. Fatigue causes beyond self-view

- **Feeling physically trapped** — in the multiple-mediator model this was **statistically
  tied with mirror anxiety for the largest indirect effect** (B = .08, SE = .01,
  95% CI [.07, .09]), and larger than hyper-gaze or nonverbal production. Bailenson's
  mechanism is a fixed camera FOV pinning the body. There is a second, unnamed half of
  the same mechanism: **the viewpoint is also pinned.** Moving your head changes nothing
  about what you see. A room does not behave that way. **Head-coupled parallax is a
  direct intervention on the single largest non-mirror mediator of videoconference
  fatigue** — this is the strongest evidence-backed argument for the operator's instinct,
  and it is stronger than the "it looks cool" argument.
- **Hyper-gaze** — B = .09, d = .33. Largely a grid artefact; at N=2 it survives only as
  the one unblinking frontal face. Partly addressed by §3.3 geometry and §3.2 scale.
- **Audio-visual asynchrony** — **ITU-R BT.1359-1**: detectability **+45 ms to −125 ms**,
  acceptability **+90 ms to −190 ms** (positive = audio leads video). The asymmetry is
  ecological: sound arriving *after* light is natural, sound arriving *before* it is not,
  so the tolerance for video-lags-audio is ~3× wider. For a product with sub-50 ms audio,
  this is the operative risk: **audio that fast can outrun the video by more than 45 ms
  and land outside the detectability threshold.** Worth measuring on a live call
  independently of anything in this brief.
- **Cognitive load of a fixed field of view / attention control** — Frontiers in
  Psychology 15:1408481 (2024) and IJHCI (2025), §1.4. Any per-frame visual change with a
  flickering or intermittent boundary *adds* load.

---

## 5. Ranked candidates

Ranking is (impact on felt presence) ÷ (browser engineering effort), with a hard filter
on do-no-harm and zero pipeline latency.

---

### ★ 1. Aperture Parallax — the two-plane window (RECOMMENDED FIRST BUILD)

**Research base.** Ware/Arthur/Booth CHI '93 (head coupling ≥ stereo for felt 3D,
monocular sufficient); Jerald & Whitton 2009 (θ′ = Δt·φ″ — gain is the free variable that
buys back latency); Fauville et al. (feeling physically trapped, B = .08, tied for the
largest non-mirror mediator); Apple iOS 26 Spatial Scenes (consumer proof that few-layer
low-amplitude parallax reads as depth); Rogers & Graham / Nawrot & Stroyan (depth
requires *differential* velocity — supplied here by picture-plane vs. static surround).

**Illusion mechanism.** The screen becomes an aperture. The blurred `#remoteFill` wash is
screen-locked and reads as the frame/wall; the contain-fit picture plane translates a few
percent **opposite** to the viewer's head translation, and scales slightly with viewer
distance. Differential motion between aperture edge and scene = two-plane parallax = the
percept of looking *through* rather than *at*. Simultaneously it un-pins the viewpoint,
which is a direct hit on the trapped mediator.

**Browser implementation sketch.**
- **Tracking (viewer's own camera, viewer-local, never transmitted).** The local capture
  element is already alive. Run **MediaPipe Tasks-Vision FaceLandmarker** (`@mediapipe/
  tasks-vision`, BlazeFace short-range → FaceMesh-V2, 192×192–256×256 input, 478 landmarks
  + facial transformation matrix) in `LIVE_STREAM` mode with the GPU delegate, at a
  **capped 10–15 Hz on a `requestIdleCallback`/`setTimeout` loop, never on rAF and never
  on the encoder path.** Cross-browser: use `FaceLandmarker`, **not** `FaceDetector` —
  the Shape Detection API is Chrome-only (Firefox declined it, bug 1553738; Safari has
  never shipped it), so `FaceDetector` cannot be the primary path for a Chrome+Safari
  product. Optional: use `FaceDetector` as a zero-download fast path where it exists and
  FaceLandmarker as the portable path, but a single code path is worth more than the few
  ms.
  Only three numbers leave the tracker: **head x, head y, and inter-pupillary distance in
  pixels** (a monotone proxy for viewer distance). No image, no landmarks, no network.
- **Smoothing.** One-Euro filter or a critically damped spring (ζ = 1.0, no overshoot —
  see failure modes) at ~8–10 Hz cutoff, plus a small **dead zone** (~1.5% of frame
  width) so a still head produces a *perfectly* still picture.
- **Render.** The transform is a translate+scale on the already-composited picture layer:
  `#remoteCanvas` / `#remote` gets `transform: translate3d(dx, dy, 0) scale(s)` with
  `will-change: transform` — a compositor-only property, no layout, no paint, no repaint
  of `#remoteFill`. Alternatively fold it into the existing `drawImage` on the
  `?l2canvas=1` path as a `ctx.setTransform`. Both are strictly cheaper than the existing
  2 Hz wash sampler.
- **Overscan.** Render the picture plane at ~1.06× so translation never exposes an edge
  gap. On the contain-fit path this eats a little of the letterbox, which is the wash —
  visually free.
- **Gain.** Start at **max ±2.5% of viewport width** for a full natural head excursion
  (~±15 cm), z-gain ±3% scale. Tune upward only if live A/B shows it is invisible.
- **Tier gate.** Reuse `resolveDevTier()`; `!== 'strong'` gets no tracker at all (the
  existing `flat` class already turns off the wash on weak devices, which also removes
  the second plane — so on weak devices the feature would be both expensive *and*
  ineffective. Gate on `strong` only.)
- **Flag.** `?window=0` disables (control arm), default ON per the defaults law.

**Failure modes that would make it gimmicky.**
1. **Jelly / swimming** — tracker lag beating the head. Mitigated by low gain
   (θ′ = Δt·φ″) and hard-capped velocity.
2. **Overshoot** — an underdamped spring keeps the picture moving after the head stops.
   This is the worst failure: it converts lag into oscillopsia. ζ = 1.0, never < 1.0.
3. **Idle wobble** — detector jitter with a still head. Dead zone + the "picture is
   *perfectly* still when you are still" acceptance test.
4. **Wrong sign** — parallax inverted reads as the room being pushed, deeply wrong.
   Fixed by a written sign convention and a live check.
5. **Laptop-on-lap** — the *device* moves, not the head, so head-relative-to-camera
   reads as motion when the geometry did not change. Mitigated by low gain and by
   high-pass-free absolute positioning with slow recentering (~10 s time constant) so a
   sustained new pose becomes the new zero.
6. **Two people at one camera** — pick the largest face box, hysteresis on the choice.
7. **Dark room / tracker loss** — ease to zero over ~400 ms, never snap.
8. Battery/thermal on laptops from a 10 Hz GPU-delegate model — measure, and drop the
   tracker to 5 Hz or off under `navigator.getBattery()` saver / sustained high frame
   time.

**Live-production verification** (`room.tokkah.com`, real calls, real media — no synthetic
harness verdicts):
- Two arms, `?window=1` (default) vs `?window=0`, same room, real conversation.
- **Do-no-harm gate, must pass before any presence claim:** `mouthToEarMs`, conceal rate,
  `framesDecoded` rate, RTP jitter and freeze count **statistically unchanged** vs
  control; long-frame count (rAF > 20 ms) and dropped-frame count unchanged; CPU/GPU
  time per frame logged via `requestVideoFrameCallback` deltas.
- **Correctness on a live call:** log tracker Hz, tracker→transform lag, applied
  (dx, dy, s), and head velocity. Assert: picture displacement is anti-correlated with
  head displacement (r < −0.8); zero applied displacement for > 2 s whenever head
  velocity is below the dead zone; no applied velocity exceeding the cap.
- **Felt effect:** single post-call item ("did it feel like they were in the room with
  you? 1–7"), and the behavioural tell that is cheap to log and hard to fake — **does the
  viewer's head move more on the parallax arm?** A window invites you to look around it;
  a photograph does not. Head-position variance on arm 1 > arm 0 is a strong, unprompted
  signal that the illusion landed.
- Ship-blocking regression: audio↔video sync stays inside BT.1359 detectability
  (+45/−125 ms).

---

### ★ 2. True-Scale Presence — render the face at social-zone angular size

**Research base.** Bailenson 2021 mechanism 1b (apparent face size at intimate-zone
distance → hyper-arousal; his own fix is to shrink the window); Hall 1966 zones;
Argyle & Dean 1965 equilibrium theory; Bailenson, Blascovich, Beall & Loomis 2001/2003
(the compensation is automatic and mediated-representation-transferable, and stronger in
women — which lines up with Fauville's d = .57 gender effect).

**Illusion mechanism.** Two parts. (a) **Static:** scale the remote picture so the face
subtends the angle it would at ~1.2 m (top of Hall's personal / bottom of social), not at
0.45 m. Full-screen edge-to-edge is currently rendering an intimate-zone face by default,
and the app's own design deliberately made that full-screen. (b) **Dynamic, and this is
the real prize:** couple scale to the *viewer's* distance from their own screen (same
IPD-in-pixels signal as candidate 1's z axis, higher gain). **Leaning back makes them
smaller again** — the equilibrium-theory compensation channel is reopened, and the
arousal that currently has nowhere to go gets somewhere to go.

**Browser implementation.** Nothing new: it is the `scale(s)` term already in candidate
1, plus a static baseline scale. Estimate the *remote* face's pixel size from the same
FaceLandmarker run on the remote canvas at 2 Hz (cheap, and the 2 Hz wash sampler is
already reading that surface), estimate the viewer's viewing distance from their own IPD,
and solve for the scale that puts the remote face at a target visual angle. Everything
composites; nothing enters the media path. Flag `?scale=0`.

**Failure modes.** (1) Overshrinking → the "doll on a shelf" percept, which is a
documented telepresence failure and *reduces* presence; the target must be
personal/social boundary, not social/public. (2) On a phone, correct angular size may
demand a face smaller than the useful pixel budget — gate to viewports above some
diagonal. (3) Scale that visibly pumps with breathing or slouching → hard low-pass, big
dead zone, ~2 s time constant; scale must move an order of magnitude slower than
translation. (4) Cropping: shrinking inside a fixed frame grows the letterbox, which is
the wash — acceptable, and it strengthens the aperture of candidate 1, but it must not
read as "they got further away and the app got smaller."

**Live verification.** Same two-arm structure. Log rendered face angular size (deg) and
viewer distance. Post-call item specifically on comfort/arousal rather than presence
("how tiring was that call? 1–7"), since the predicted effect is *fatigue reduction*, and
Bailenson's mechanism predicts the effect grows with call length — so stratify by
duration. Do-no-harm gate identical to candidate 1.

---

### ★ 3. Eye-Line Placement — put the remote eyes in the eye-contact cone

**Research base.** Gao, Jayakumar, Maniglia, Curless, Kemelmacher-Shlizerman, Seitz &
Seitz, *Journal of Vision* 25(11):8 (2025) — perceived eye contact **peaks at 1.76° below
the camera**, loss thresholds **4.5° above / 5.5° below**, at 57 cm; Chen, CHI 2002
(asymmetric ±5° tolerance); "snap to contact" (perception biases toward eye contact when
uncertain).

**Illusion mechanism.** If the remote person's eyes are rendered ~1.5–2° below the local
camera axis, the viewer looking at those eyes is gazing 1.76° below their own lens — the
exact peak of the perceived-eye-contact function — so **the far end sees them making eye
contact**. Symmetrically applied, both parties get it. This is free mutual gaze,
purchased with layout arithmetic.

**Browser implementation.** Estimate camera position relative to the viewport (top-centre
for the overwhelming majority of laptops/phones; refine with the screen/viewport metrics
available and a conservative default). Estimate viewing distance from IPD. Compute the
pixel offset for 1.76° at that distance. Apply as a **static vertical bias** to the same
transform candidate 1 already owns, and prefer face-anchored contain-fit framing so the
*eyes*, not the frame centre, land on that line. Zero new machinery. Flag `?eyeline=0`.

**Failure modes.** (1) Wrong camera-position assumption (external monitor with a
separate webcam, iPad in landscape with a side camera) puts the eyes on the wrong line —
detectable by checking whether the local face is centred horizontally in capture; when
uncertain, apply no bias. (2) Over-correction pushing the composition low enough to read
as bad framing — cap the bias, and note that 1.76° at 57 cm is only ~1.75 cm, so the cap
is naturally tight. (3) Interaction with candidate 1: eye-line bias is a *static* offset
added to the parallax origin, not a competing dynamic term; keep them additive and
separately loggable.

**Live verification.** Log the applied bias in degrees and the assumed camera position.
The behavioural read is the one that matters and it is measurable on a live call:
**mutual-gaze duration** — with the tracker already running on both ends, log the
fraction of the call each party's gaze falls inside their own ±4.5°/5.5° cone, and
compare arms. Bonus: Schoenenberg-style post-call attribution items ("did they seem
attentive?"), since gaze and attribution are the same currency.

---

### 4. Motion-Coupled Ambience — the wash as a room, not a wallpaper

**Research base.** Nawrot & Stroyan's motion/pursuit account (differential velocity is the
carrier of depth); §1.4's warning that *content-bearing* background change costs attention
control — which is exactly why this candidate makes the background **less** informative,
not more.

**Illusion mechanism.** The `#remoteFill` wash currently sits static. Give it a *very*
small **same-sign** motion (a fraction of the picture plane's, e.g. 0.2×) instead of zero.
That converts a two-plane system into a three-depth-cue system (aperture edge, wash,
picture) and makes the wash read as *far wall* rather than *screen decoration*, without
adding any recognisable content for attention to latch onto — the wash is a 32×18 blurred
resample, it has no detail to distract with.

**Browser implementation.** One more `transform` on an element that already exists, driven
by the same smoothed signal. Effort: hours. Fold into candidate 1's flag.

**Failure modes.** Wash motion large enough to be individually noticeable breaks the
aperture (the frame must not move, or the window becomes a floating rectangle). Keep it
below the just-noticeable and be willing to ship it at zero. Weak-tier devices have no
wash at all (`.flat`), so this is a strong-tier-only garnish.

**Live verification.** Only meaningful as an A/B *within* the parallax arm
(gain 0 vs 0.2), on the same felt-presence item. Low expected effect; ship only if free.

---

### 5. Person/Background 2.5D (segmentation parallax) — DEFERRED

**Research base.** MediaPipe Selfie Segmentation (MobileNetV3-derived, 144×256 landscape /
256×256 general, designed for subject < 2 m — exactly video-call geometry, and documented
as a fully-on-GPU pipeline from acquisition through inference to render). Against it:
Frontiers in Psychology 15:1408481 (2024) — **blurred backgrounds measurably increased
videoconference fatigue**, mechanism = intermittent boundary failures presenting new
information.

**Illusion mechanism.** Genuine person-vs-room layer separation → leaning sideways reveals
a sliver of the room behind their shoulder. This is the *real* window, and it is what the
operator's instinct is ultimately reaching for.

**Why it is ranked below the cheap ones.** (a) Disocclusion: parallax on a segmented
person exposes background pixels that do not exist. Options are all bad in a browser —
stretch-fill (rubber-sheet smearing at the silhouette), inpaint (Shih et al. CVPR 2020 is
offline-grade), or a **background plate accumulated over time** from frames where the
person moved (viable! idle-time, no per-frame cost) which is the only genuinely promising
route. (b) Boundary flicker is a *documented fatigue increaser*, and this product ships
default-on — a feature whose failure mode raises fatigue cannot be default-on. (c) It is
per-frame ML in the display path on both browsers, which is the largest do-no-harm risk
in this brief.

**If it is ever built:** run it on the **sender** side out-of-band (send an alpha/edge hint
alongside, never blocking the frame), accumulate the background plate over ~30 s of idle
time, and gate it behind the parallax A/B already having shown a positive effect.

---

### 6. Monocular depth → continuous 2.5D warp — NOT VIABLE (documented so it is not
re-proposed)

**Research base.** Depth Anything V2 (Yang et al., NeurIPS 2024); ONNX-community
`depth-anything-v2-small` with transformers.js; browser demos exist and run on **WebGPU**.

**Why not.** ViT-S DINOv2 backbone + DPT decoder ≈ 25M params; browser bundles ~97 MB
unquantised, ~18–26 MB quantised. Real-time in-browser demos are WebGPU-dependent, and
WebGPU on Safari is not a foundation a default-on feature can stand on in this product's
support matrix. Convolution ops are the documented bottleneck. Per-frame depth in the
display path also violates the do-no-harm constraint at the exact moment the machine is
already spending its budget on a fixed-QP WebCodecs lane and PBFDAF echo cancellation.
**Conclusion: not per-frame, not now.** The only defensible use is *one* depth inference
at ~0.2 Hz on a strong-tier device to parameterise a static two-plane split — which is
strictly more expensive and only marginally better than candidate 5's background plate.

---

## 6. Recommendation

**Build candidate 1 (Aperture Parallax) with candidate 3 (Eye-Line) folded in as a static
term, behind one flag, gated to strong-tier devices, at a deliberately low gain.**

The three reasons, in order of weight:

1. **It is the only candidate that intervenes on a top-two mediator of videoconference
   fatigue** (feeling physically trapped, B = .08, tied with mirror anxiety and
   significantly larger than hyper-gaze) rather than on a nice-to-have. The self-view
   decision already banked the *other* top-two mediator. This is the matching pair.
2. **The layer separation is already in the DOM.** `#remoteFill` + contain-fit
   `#remoteCanvas` is a two-plane composite that nobody built for this purpose, and it
   defeats the "moving a photograph" objection without a single line of ML. Every other
   route to layer separation costs a model, and the two best-documented ones cost either
   Safari support or a fatigue regression.
3. **The latency budget and the subtlety requirement point at the same gain.** A
   60–90 ms browser tracker cannot support a Johnny-Lee portal (Jerald & Whitton put the
   latency JND at 16.6 ms), but θ′ = Δt·φ″ says the perceptual error scales with gain,
   and a default-on feature had to be low-gain regardless. The physics and the product
   constraint agree on the same number, which almost never happens and should be taken.

Candidate 2 (True-Scale) is the highest-ceiling idea in the brief — reopening the
Argyle-Dean compensation channel is a genuinely novel move, and if it works it reduces
call fatigue rather than merely adding pleasure. But it changes the *composition* of the
call, which is a bigger aesthetic bet than adding a few percent of motion, and it should
ride on candidate 1's already-verified tracker rather than gamble the tracker's
introduction on it.

Build order: **1+3 together → measure on live calls → 2 → 4 → revisit 5 only if 1 shows a
positive felt-presence effect.**

The long-horizon item that none of these touch, recorded here so it does not get lost:
**a shared o-space (Kendon)**. A permanent full-screen vis-à-vis is structurally unlike
sitting next to someone, and no amount of parallax, scale, or gaze correction changes
that. Whatever gives two people a shared space *between* them, that both can point into,
is a larger multiplier than everything in this brief combined.

---

## References

Fetched and read (full text or full abstract with extracted statistics):

- Fauville, Luo, Queiroz, Bailenson, Hancock — *Nonverbal Mechanisms Predict Zoom Fatigue
  and Explain Why Women Experience Higher Levels than Men* (full PDF read; N, betas, d's,
  ACMEs above) — https://lemanncenter.stanford.edu/sites/default/files/Queiroz_Zoom_gender_effect_SSRN_2021.pdf
  · SSRN record: https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3820035
- Bailenson (2021), *Nonverbal Overload*, Technology, Mind, and Behavior 2(1) —
  https://tmb.apaopen.org/pub/nonverbal-overload
  · Full four-cause exposition with his interface fixes, read via the Stanford News
  release (PDF read in full): https://news.stanford.edu/2021/02/23/four-causes-zoom-fatigue-solutions/
- Fauville et al., *Zoom Exhaustion & Fatigue Scale*, Computers in Human Behavior Reports
  (2021) — https://www.sciencedirect.com/science/article/pii/S2451958821000671
  · Scale PDF: https://pro-a.org/wp-content/uploads/2021/09/02e-Zoom-Fatigue-Paper-Scale.pdf
- Fauville et al. (2023), *Video-conferencing usage dynamics and nonverbal mechanisms
  exacerbate Zoom Fatigue, particularly for women*, CHBR —
  https://www.sciencedirect.com/science/article/pii/S2451958823000040
- Xu, Whelan, O'Brien, O'Hora (2024), *Does Self-View Mode Generate More Videoconferencing
  Fatigue in Women than Men? An Experiment Using EEG Signals*, Cyberpsychology Behavior
  and Social Networking — https://www.liebertpub.com/doi/10.1089/cyber.2023.0577
- Li & Lee (2023), *Filters uncovered*, Telematics and Informatics Reports 11 —
  https://www.benjy.li/pdfs/Li%20and%20Lee%20-%20Filters%20uncovered.pdf
- *Exploring the links between type and content of virtual background use during
  videoconferencing and videoconference fatigue*, Frontiers in Psychology 15:1408481 (2024)
  — https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2024.1408481/full
- *Investigating the Effect of Virtual Backgrounds … on Attention Control and
  Videoconference Fatigue*, IJHCI (2025) —
  https://www.tandfonline.com/doi/full/10.1080/10447318.2025.2588711
- Jerald & Whitton (2009), *Relating Scene-Motion Thresholds to Latency Thresholds for
  Head-Mounted Displays* (full text read; JND 16.6 ms, PSE 38.9 ms, θ′ = Δt·φ″) —
  https://pmc.ncbi.nlm.nih.gov/articles/PMC3095496/
  · UNC TR 10-013: https://www.cs.unc.edu/techreports/10-013.pdf
- Ware, Arthur & Booth (1993), *Fish Tank Virtual Reality*, CHI '93 —
  https://dl.acm.org/doi/10.1145/169059.169066 · https://scholars.unh.edu/ccom/178/
- *User Behavior and the Importance of Stereo for Depth Perception in Fish Tank Virtual
  Reality*, PRESENCE 27(2):206 (2018) —
  https://direct.mit.edu/pvar/article/27/2/206/96076/User-Behavior-and-the-Importance-of-Stereo-for
- Johnny Chung Lee, *Head Tracking for Desktop VR Displays using the Wii Remote* —
  http://johnnylee.net/projects/wii/ · https://www.youtube.com/watch?v=Jd3-eiid-Uw
  · code mirror: https://github.com/MoralCode/WiiDesktopVR
- Nawrot & Stroyan, *Modeling depth from motion parallax with the motion/pursuit ratio* —
  https://www.ncbi.nlm.nih.gov/pmc/articles/PMC4186274/
  · *The pursuit theory of motion parallax*, Vision Research —
  https://www.sciencedirect.com/science/article/pii/S0042698906003129
- Shih, Su, Kopf & Huang (2020), *3D Photography using Context-aware Layered Depth
  Inpainting*, CVPR — https://arxiv.org/abs/2004.04727 ·
  https://shihmengli.github.io/3D-Photo-Inpainting/ ·
  https://github.com/vt-vl-lab/3d-photo-inpainting
- Apple iOS 26 Spatial Scenes (foreground/mid/background layer separation + motion
  parallax, on-device, no special sensors) —
  https://www.macrumors.com/how-to/ios-3d-lock-screen-effect-spatial-scenes/
- Apple Vision Pro Spatial Personas (visionOS 1.1, Apr 2024) —
  https://www.uploadvr.com/apple-vision-pro-spatial-personas-launch/
- Gao, Jayakumar, Maniglia, Curless, Kemelmacher-Shlizerman, Seitz & Seitz, *Don't look at
  the camera: Achieving perceived eye contact in remote video communication*, Journal of
  Vision 25(11):8 (2025) — https://jov.arvojournals.org/article.aspx?articleid=2810811
  · preprint https://arxiv.org/abs/2404.17104 · https://pubmed.ncbi.nlm.nih.gov/40932449/
- Chen (2002), *Leveraging the asymmetric sensitivity of eye contact for videoconference*,
  CHI — referenced via https://dl.acm.org/doi/10.1145/2366145.2366193 (Kuster et al., Gaze
  Correction for Home Video Conferencing, which surveys the ±5° envelope)
- Stivers, Enfield, Brown, Englert, Hayashi, Heinemann, Hoymann, Rossano, de Ruiter, Yoon
  & Levinson (2009), *Universals and cultural variation in turn-taking in conversation*,
  PNAS 106(26) — https://www.pnas.org/doi/10.1073/pnas.0903616106 ·
  https://pubmed.ncbi.nlm.nih.gov/19553212/
- Schoenenberg, Raake & Koeppe (2014), *Why are you so slow? — Misattribution of
  transmission delay to attributes of the conversation partner at the far-end*, IJHCS
  72(5):477–487 — https://www.sciencedirect.com/science/article/abs/pii/S1071581914000287
- ITU-T G.114 (05/2003), *One-way transmission time* —
  http://www.cs.columbia.edu/~andreaf/new/documents/other/T-REC-G.114-200305.pdf
- ITU-R BT.1359-1, *Relative timing of sound and vision for broadcasting* (detectability
  +45/−125 ms; acceptability +90/−190 ms) —
  https://www.semanticscholar.org/paper/0ee98071da172de6e1d6d1fcd560bad9e0a87d5e ·
  https://en.wikipedia.org/wiki/Audio_sync
- Bailenson, Blascovich, Beall & Loomis (2001), *Equilibrium Theory Revisited: Mutual Gaze
  and Personal Space in Virtual Environments*, Presence 10(6):583–598 —
  https://vhil.stanford.edu/sites/g/files/sbiybj29011/files/media/file/bailenson-equilibrium.pdf
  · https://direct.mit.edu/pvar/article-abstract/10/6/583/18392/
- Kendon, F-formation system (o-space / p-space / r-space; vis-à-vis vs L-shape) —
  https://emcawiki.net/F-formation ·
  https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0123783 ·
  https://www.mdpi.com/2414-4088/3/4/69
- Short, Williams & Christie (1976), social presence theory —
  https://en.wikipedia.org/wiki/Social_presence_theory
- MediaPipe Face Landmarker (BlazeFace short-range + FaceMesh-V2 + blendshapes; 478
  landmarks; 192×192–256×256 input; JS package `@mediapipe/tasks-vision`) —
  https://developers.google.com/edge/mediapipe/solutions/vision/face_landmarker ·
  web guide https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker/web_js
- MediaPipe Selfie Segmentation (MobileNetV3-derived; general 256×256 and landscape
  144×256; full-GPU pipeline; designed for subject < 2 m) —
  https://github.com/google-ai-edge/mediapipe/blob/master/docs/solutions/selfie_segmentation.md
- Shape Detection API `FaceDetector` — Chrome-only; Firefox declined
  (https://bugzilla.mozilla.org/show_bug.cgi?id=1553738); Chrome docs
  https://developer.chrome.com/docs/capabilities/shape-detection
- Depth Anything V2 in-browser: ONNX community weights
  https://huggingface.co/onnx-community/depth-anything-v2-small · browser demo repo with
  model sizes (~97 MB / ~26 MB / ~18 MB)
  https://github.com/akbartus/DepthAnything-on-Browser
