# TAPE — Premium UI/UX Specification (Task #38, Phase 1: research + spec)

Date: 2026-08-02. Status: SPEC ONLY — no code changed. Phase 2 implements this verbatim.
Scope: `/Users/earningsgpt/video calling/tape-app/public/index.html` and `app.js` only (phase 2). Nothing in `tape.js`, `pcm.js`, `worklets/`, `core/`, `worker`.

Tag legend:
- **[RESEARCH]** — backed by a cited study or standard.
- **[INDUSTRY]** — what FaceTime / WhatsApp / Meet / Zoom / iOS system UI ship today.
- **[JUDGMENT]** — our call, with reasoning stated. Marked honestly where evidence is thin.

Source-verification honesty note: live web access during this research pass was partially degraded (several searches/fetches failed or 403'd). The Bailenson and Fauville summaries below were corroborated by at least one successful live search; the remaining citations are from established, well-known literature/standards (HIG, Material, WCAG, caniuse) that are stable references. Nothing below depends on a shaky or obscure source.

---

## 1. Research digest (distilled)

### 1.1 Zoom fatigue — the anchor paper
Bailenson, J. N. (2021). *Nonverbal Overload: A Theoretical Argument for the Causes of Zoom Fatigue.* Technology, Mind, and Behavior, 2(1). https://doi.org/10.1037/tmb0000030 — four mechanisms:

1. **Excessive close-up eye gaze ("hypergaze")** — faces shown larger and closer than any real conversation, and everyone stares at everyone constantly. Real meetings have glances away, note-taking, shared objects. Sustained mutual gaze at intimate distance is arousing and exhausting.
2. **The all-day mirror (self-view)** — a continuous live mirror is unnatural. Bailenson cites mirror-exposure and self-focused-attention research (Fejfar & Hoyle 2000; Ingram 1990): seeing yourself increases self-evaluation and self-criticism, with stronger effects on women. His explicit mitigation: **"hide self-view."**
3. **Reduced mobility** — the camera's field of view is a cage. In person we lean, pace, gesture wide; on calls we hold still to stay framed, and movement is linked to better cognitive performance.
4. **Higher cognitive load** — sending nonverbal cues deliberately (exaggerated nods, camera-directed eye contact) and decoding degraded/delayed cues costs working memory that face-to-face gets for free.

### 1.2 Self-view evidence (is default-off justified? — yes)
- Fauville, G., Luo, M., Queiroz, A. C. M., Bailenson, J. N., & Hancock, J. (2021). *Zoom Exhaustion & Fatigue Scale.* Computers in Human Behavior Reports, 4, 100119. https://doi.org/10.1016/j.chbr.2021.100119 — N=10,322. **Mirror anxiety is a significant predictor of videoconference fatigue**; women report more fatigue, statistically mediated by self-focused attention from self-view. Authors' stated mitigation: hide self-view.
- Ratan, R., Miller, D. B., & Bailenson, J. N. (2022). *Facial Appearance Dissatisfaction Explains Differences in Zoom Fatigue.* Cyberpsychology, Behavior, and Social Networking, 25(2). https://doi.org/10.1089/cyber.2021.0112 — appearance dissatisfaction correlates with fatigue; self-view is the delivery mechanism.
- Honesty note [JUDGMENT]: the *direct experimental* evidence that hiding self-view reduces fatigue in a randomized design is thinner than the correlational evidence. But the direction is consistent across every study, the cost of default-off is near zero, and self-view still exists on demand — so default-off + long-press peek is the right risk posture.

### 1.3 Adjacent fatigue evidence
- Riedl, R. (2022). *On the stress potential of videoconferencing: definition and root causes of Zoom fatigue.* Electronic Markets, 32, 153–177. https://doi.org/10.1007/s12525-021-00501-3 — neurophysiological (fNIRS) evidence that videoconferencing is measurably more fatiguing than face-to-face; supports an overall "less chrome, less stimulus" posture.
- Practical corollaries in the literature: audio-only breaks help; shrinking/moving the video away reduces hypergaze load; fewer on-screen distractors reduce cognitive load.

### 1.4 Mobile control patterns [INDUSTRY]
- FaceTime, Google Meet mobile, Zoom mobile, and every mainstream video player use **auto-hiding chrome**: controls visible at call start and on tap, auto-hide after ~3–5 s of inactivity. Reveal = single tap on the video surface. This is the converged-on pattern; deviating from it costs discoverability.
- The destructive control (end call) is always visually distinct (red) and spatially separated from toggles. Zoom adds a confirmation on leave; WhatsApp/FaceTime do not but isolate the button.
- Muted state is **always visible somewhere** even when chrome is hidden (Meet/Zoom keep a persistent mic-off indicator) — this addresses the near-universal "am I muted?" anxiety. Direct academic research on mute-state anxiety is thin; this is [INDUSTRY]+[JUDGMENT], not [RESEARCH].

### 1.5 Touch targets and reach [RESEARCH]
- Apple HIG: minimum hit area **44×44 pt** (hit area may exceed the visible glyph).
- Material 3: **48×48 dp** targets, ≥8 dp separation.
- WCAG 2.2 SC 2.5.8 (AA): 24×24 CSS px minimum; SC 2.5.5 (AAA): 44 px. We target 48 px effective — satisfies all three.
- Steven Hoober's thumb-zone studies (UXmatters 2013, *Designing for Touch*, 2015): ~49% of phone use is one-handed; the easy zone is the bottom-center/bottom-thumb arc, the top corners are hardest on tall phones. Primary controls belong in the bottom third, centered toward the dominant-thumb side; nothing critical in the top corners.

### 1.6 Glassmorphism, tastefully [RESEARCH]
- WCAG 1.4.3 requires 4.5:1 contrast for text, 1.4.11 requires 3:1 for UI-component boundaries/states. **A translucent surface has no fixed contrast ratio** — it depends on whatever video is behind it. This is the single failure mode that makes glass look cheap *and* fail accessibility. Fixes: (a) enough blur (≥16–20 px) that background detail can't compete, (b) a dark tint base (rgba black ~50–65%) so luminance is bounded even over bright video, (c) a 1 px hairline border at ~12–18% white to define the edge, (d) icons at full opacity white — never translucent glyphs on translucent glass.
- `backdrop-filter` support (caniuse.com/css-backdrop-filter): Chrome 76+, Safari 9+ (unprefixed 15.4+/18), Edge 79+, Firefox 103+. **Older Samsung Internet (<18) and Firefox <103 have no support** — every glass element must carry an opaque `@supports not (backdrop-filter: …)` fallback that is merely slightly darker, not a different design.
- Premium-vs-cheap heuristics [JUDGMENT]: glass reads premium when blur is strong, tint is dark and consistent, borders are hairlines, radii are generous (circles/pills), motion is short (≤250 ms, ease-out), and there are ≤2 glass layers on screen. It reads cheap when tint is light gray over busy video, blur is weak, borders are thick, or everything on the screen is glass.

### 1.7 Dark patterns / accidental actions
- Avoid [RESEARCH+JUDGMENT]: hidden destructive controls that share a target with frequent taps; confirm-shaming; controls that appear under the finger after an auto-show (layout shift); low-contrast "premium" glass that hides state; auto-hiding the *state* of the mic (state ≠ chrome — state must persist).
- Accidental hangup: the leave button gets a two-step confirm in-call [JUDGMENT — Zoom precedent, and a dropped 1:1 call is unrecoverable embarrassment], but the confirm must be a *different gesture location* (tap "leave" → it morphs into "tap again to leave" for 3 s), not a modal — modals over live video are hostile.
- "Am I muted?" solution [INDUSTRY+JUDGMENT]: persistent mic-off badge (small red-slashed glass dot, bottom-left, always visible when muted, zero when unmuted), plus a spoken-state text in the status pill at call start, plus a light haptic on every mute toggle so the state change is felt, not just seen.

---

## 2. THE LIST — prioritized UX spec by call lifecycle

Priority: P0 = must ship in phase 2, P1 = ship if cheap, P2 = polish.

### A. Global design system (applies everywhere)

1. **P0 — Icon-only controls on dark-glass circles** (user mandate) [JUDGMENT per directive; glass treatment per §1.6].
   - Every in-call control is a **circular button, 48 px diameter visible, 56 px hit area** (44 pt / 48 dp satisfied with margin), glyph = 22 px SF-style stroke icon at 100% white, no labels.
   - Circle style: `background: rgba(10,14,22,.55); backdrop-filter: blur(18px) saturate(1.4); border: 1px solid rgba(255,255,255,.14); border-radius: 50%;` — dark-tinted, heavily blurred, hairline edge. `@supports not (backdrop-filter)` fallback: `rgba(10,14,22,.88)`, same border. Identical look over dark video; slightly less pretty over bright video, never unreadable.
   - **State language, no exceptions:** ON/active state = glass circle with a soft white inner glow (e.g. `box-shadow: inset 0 0 0 1.5px rgba(255,255,255,.35)`). Muted/camera-OFF = icon turns `--bad` (#ef4444) with a slash glyph — red means "you are dark/silent to them," instantly parseable. Leave = the only filled circle: solid `--bad` red, white phone-down glyph.
   - Text labels exist only as `aria-label` / `title` (screen readers, desktop hover) — never rendered.
2. **P0 — One chrome bar, bottom, auto-hiding.** [INDUSTRY] Single row: `mic · camera · self-view · save log · spacer · leave`. Chips (life size / gaze / stats) move out of the always-visible bar into a **long-press-anywhere-on-bar "more" sheet** (§B.9) — the default bar is five circles and nothing else. Bar sits `max(14px, env(safe-area-inset-bottom))` off the bottom edge, horizontally centered, `gap: 14px`.
3. **P0 — Auto-hide timing.** [INDUSTRY] Bar visible: on call entry, on any tap/pointermove, on any state change. Hides after **2.6 s** of no interaction (matches current 2600 ms constant — keep; it tested well). Fade `opacity .22s ease-out` (existing). **First 10 s of every call the bar stays pinned visible** (discoverability), then the timer starts.
4. **P0 — Tap-to-reveal discipline.** [INDUSTRY] A tap on empty video toggles the bar; that tap must never also trigger a control (event hits the video layer, not the bar; bar taps stopPropagation). A tap while the bar is hidden only reveals — second tap acts. No layout shift on reveal: the bar is `position:absolute`, video rect never changes.
5. **P0 — Persistent mute badge.** [JUDGMENT per §1.7] When mic is muted, a 34 px glass circle with red slashed-mic sits bottom-left (opposite the bar's visual weight), visible **even when the bar is hidden**. Unmuted = nothing. Camera-off shows a matching small badge only while the bar is visible (camera-off is already obvious to the user; mute is the invisible one).
6. **P0 — Haptics** [INDUSTRY+JUDGMENT] (`navigator.vibrate`, iOS gets nothing — acceptable, iOS haptics need native): light 8 ms tick on any control toggle; 12 ms + 40 ms pause + 12 ms double-tick on long-press threshold crossing (self-view peek, more-sheet). Never on auto-hide/show.
7. **P0 — Motion budget.** Every transition ≤250 ms, ease-out, opacity/transform only (no layout). Reduced-motion: `prefers-reduced-motion` collapses all fades to instant.
8. **P1 — Rotation.** Layout is orientation-independent: bar stays at physical bottom (`safe-area-inset` re-read on `resize`/`orientationchange`); video keeps `object-fit: cover` per the existing aspect matrix. No controls move between portrait and landscape except bar width clamps to `min(92vw, 560px)`.

### B. In-call (the core state — remote fullscreen)

9. **P0 — Self-view: default OFF, hold-to-peek** (user mandate) [RESEARCH §1.2 + directive].
   - On peer arrival: `view.selfview` stays **false** — no PiP appears. (This *changes* current behavior: `peerArrived()` currently force-enables the PiP; phase 2 removes that line. The `c-selfview` chip logic becomes the peek/pin system below.)
   - **Gesture:** long-press the self-view icon (mirror glyph) for **≥500 ms** (UIKit `UILongPressGestureRecognizer.minimumPressDuration` default — the platform-standard threshold) → the 132 px corner PiP appears **while the finger is held**, release hides it. Pure peek, no state change.
   - **Pin:** double-tap the self-view icon toggles persistent PiP (the old chip behavior, discoverable via the more-sheet hint "double-tap to pin"). Icon shows active-state glow while pinned.
   - Rationale: the default call face is *just their face* — zero mirror anxiety [RESEARCH]; the peek gives the "is my hair okay / am I framed" check in one gesture without re-entering the all-day mirror. Peek-while-held (not toggle) chosen so the mirror can never be left on accidentally.
   - Degraded camera: self-view icon renders disabled (40% opacity, no glow); peek does nothing.
10. **P0 — The idle face.** After the first 10 s, a healthy in-call screen is: their video, nothing else. Status pill faded (existing behavior, kept), bar hidden, no PiP, no dots? — **dots stay**: the two speaking dots (breath/voice) are the product's whole thesis and are 9 px; they remain top-right always. Stall badges remain whenever they fire (mission exception, never regress).
11. **P0 — Leave protection.** [JUDGMENT §1.7] Tap leave → the red circle morphs in place to a wider red pill reading "tap to leave" (this one string allowed — destructive confirm is the one place a word beats an icon), 3 s window, tap again anywhere on the pill to leave; timeout or any other tap reverts. Haptic on each step. On confirm, run existing leave teardown.
12. **P0 — More sheet** (where chips went). Long-press (≥500 ms) anywhere on the bar, or a small glass "…" circle as the bar's leftmost item: bottom sheet (glass, same recipe, `border-radius: 20px` top corners) slides up 220 ms: life size / gaze / stats (only with `?stats=1`) / "pin self view" as icon+word rows, 48 px rows. Tap outside or swipe down dismisses. Stats gating logic unchanged.
13. **P1 — Mic/cam edge cases:** track missing (degraded/audio-only) → icon disabled state, tap does nothing, no fake toggle. Camera toggled off mid-call → remote sees last frame or black per current track-enabled behavior (unchanged); local camera-off badge per item 5.

### C. Pre-join lobby (must NOT regress — user directive from task #28)

14. **P0 — Keep the full-screen mirrored self view pre-join** (`#previewWrap` fixed inset-0, cover, `scaleX(-1)`) — this is the *right* place for a mirror: framing check before anyone sees you. Bailenson's objection is the mirror *during* the conversation, not before it [JUDGMENT, research-consistent].
15. **P1 — Restyle the join panel to the same glass recipe** (it already uses backdrop-filter; align tint/border/radius to §A.1: darker base, hairline border, 20 px radius). Join button stays filled accent (the one filled element per screen rule), min 48 px tall. No other visual changes; recording/screen-size disclosures stay as-is.

### D. Joining / waiting alone

16. **P0 — Keep `#selfFull` fullscreen while waiting** (existing task-#28 behavior) — again, pre-conversation mirror is fine, and it confirms "camera works, you look right" during the anxious waiting moment [JUDGMENT]. Waiting overlay, share field, copy button: keep; restyle copy button to glass circle-with-icon? — no: it needs its word. Keep as small glass pill with "copy" text (P1).
17. **P1 — The moment the peer's first track lands:** crossfade 250 ms selfFull → remote video (currently a hard swap). Cheapest premium-feel win in the whole app.

### E. Peer-left

18. **P0 — Existing behavior kept:** waiting overlay + selfFull return. Restyle "they left" into the auto-fading status pill (it already is). The bar stays visible for the 10 s pinned window on re-wait so leave is findable.

### F. Ending

19. **P1 — After confirmed leave:** existing `location.href = location.pathname` return to lobby is fine; no goodbye screen (P2 at most). Save-log affordance: the save icon lives in the bar (download glyph); on tap, immediate haptic + the icon flashes `--ok` green for 600 ms as confirmation — no toast, no modal.

### G. Aspect / device matrix (all P0, gates)

20. All five aspect ratios from the task-#28 matrix (16:9, 9:19.5, 21:9, 4:3, square) must re-pass with: bar fully on-screen with safe-area padding, 48 px targets, no overlap of bar × PiP × badges at any state, PiP fully on-screen when pinned, zero stat-like text in default UI, mirrored self views (`matrix(-1`) intact. One-handed phone portrait (390×844): every control reachable in the bottom 55% of the screen.

---

## 3. "Kills Zoom fatigue" — mechanism → decision map

| Bailenson mechanism | Concrete spec decision |
|---|---|
| All-day mirror (self-view → self-evaluation, mirror anxiety; Fauville: fatigue predictor; Ratan: appearance dissatisfaction) | Self-view default OFF in-call (B.9); exists only as hold-to-peek (500 ms, release-to-hide) or explicit pin; mirror confined to pre-join/waiting where framing anxiety is real and social exposure isn't (C.14, D.16) |
| Hypergaze (faces too big/close, everyone staring) | Existing life-size + distance calibration kept and promoted in the more-sheet (B.12) — it literally shrinks the face to true size at true distance; idle UI removes all non-face stimulus so the gaze target is singular, not a grid of faces (A.3, B.10) |
| Reduced mobility | Nothing in the UI punishes moving: no self-view to fall out of frame from, no chrome to babysit, camera-off is one tap with no confirm (B.13) — the UI actively permits leaning back, looking away, audio-only posture |
| Cognitive load (deliberate cue production/decoding) | Fewer, calmer signals: icon-only bar (no reading), state by color (red = silent), breath/voice dots carry turn-taking info the brain otherwise strains to infer from delayed video, auto-hide removes the "is something on screen?" monitoring loop; mute state is ambient (persistent badge) instead of requiring a check |
| (Cross-cutting, Riedl: videoconference stress) | First-10-s pinned controls then vanish (learn once, then clean); motion budget ≤250 ms; reduced-motion honored |

---

## 4. Implementation notes (phase 2 map)

**index.html:**
- `#bar`: replace text buttons with the five icon circles (inline SVG glyphs — mic, camera, mirror, download, phone-down; no icon-font dependency). Add `#muteBadge` (bottom-left persistent) and `#moreSheet` markup. Move the four chips into `#moreSheet` (keep their existing IDs — `c-lifesize`, `c-gaze`, `c-selfview`, `c-hud` — so app.js handlers and any tests that query them keep working).
- CSS: add the glass-circle recipe + `@supports` fallback (§A.1), `.icon-btn` 48/56 px sizing, bar safe-area padding (`padding-bottom: max(14px, env(safe-area-inset-bottom))`), `#selfWrap` unchanged geometry (132 px) but border-radius 12 px + hairline border to match, leave-pill morph state (`.confirming`), crossfade classes for selfFull→remote, `prefers-reduced-motion` block.
- Keep: `#status` text in DOM (tests read it — only opacity fades), `?stats=1` gating logic, `#floorHint`, `#dots`, stall badge plumbing, all video element structure.

**app.js:**
- `peerArrived()`: delete the `view.selfview = true` force-enable (B.9) — self-view defaults OFF in-call.
- Chip handlers: unchanged for the four chips, now living in `#moreSheet`; add the sheet open/close (long-press 500 ms on bar / "…" button, swipe-down, outside-tap).
- New gesture layer on the self-view icon: pointerdown timer → 500 ms → peek-on; pointerup/pointercancel → peek-off (only if not pinned); double-tap (≤300 ms pair) → pin toggle. Haptics via `navigator.vibrate` guarded (`if ('vibrate' in navigator)`).
- Leave: two-step confirm state machine (3 s window) wrapping the existing teardown.
- Bar visibility: keep the existing pointermove 2600 ms timer; add the 10 s post-join pin, tap-on-video toggle, and "don't hide while muted-badge just changed / while more-sheet open."
- Mic/cam toggles: swap textContent changes for icon/state classes (`track.enabled` logic untouched); drive `#muteBadge` visibility.
- Crossfade on first remote track (D.17): opacity transition on `#selfFull` before removing `.on`.

**Must NOT regress (explicit phase-2 gates):**
1. Zero-stats default UI — no HUD, no stat text anywhere without `?stats=1` (DOM scan per state, as in task #28).
2. Full-screen mirrored lobby self-view pre-join (user's prior directive).
3. Aspect matrix: 16:9 / 9:19.5 / 21:9 / 4:3 / square — all states, all assertions.
4. Stall badges, `#floorHint`, speaking dots, `#status` pill text-in-DOM — visible/queriable exactly as today.
5. Telemetry: every new gesture (peek, pin, sheet, leave-confirm) gets a `tel?.log('toggle'|'gesture', …)` line; logging cadence/content otherwise untouched.
6. Chrome-layer taps never toggle controls accidentally (A.4); auto-hide never hides state (A.5).

---

## 5. Cross-device aspect-ratio policy — no crop on either side, highest quality (user directive #1)

The user's question: when a desktop (16:9) and a phone (9:19.5) call each other, does the sender capture to the receiver's aspect, or send native and let the receiver fit — such that neither side ever sees a crop and quality stays maximal?

21. **P0 — Sender always sends native. Sender capture NEVER adapts to the receiver's aspect.** [JUDGMENT, four reasons]
    - (a) Re-applying capture constraints mid-call re-opens the sensor pipeline on Android — it re-triggers exactly the auto-exposure/white-balance hunting the `lockCamera()` work (app.js §5, tell 9) exists to kill. You would have to re-lock after every receiver window-drag or rotation.
    - (b) The receiver's viewport is unstable (rotation, window resize, split-screen) — sender capture churn per receiver event is unbounded and benefits nothing.
    - (c) WebRTC already delivers the native frame; rendering fit is free on the receiver (`object-fit` / canvas). There is zero quality gain from sender-side aspect matching — the pixels that don't fit are the same pixels either way, and receiver-side fit loses nothing.
    - (d) Our capture constraints already protect native aspect: `resizeMode: 'none'` (app.js getMedia) forbids the browser from cropping or scaling the sensor output. Keep it. Bandwidth-driven downscaling stays the AIMD governor's job and is aspect-preserving.
22. **P0 — Receiver default fit = "fit" (contain, zero crop) with live blurred fill — not black bars.** [INDUSTRY: Meet letterboxes; Instagram/TikTok-style blurred fill for portrait-in-landscape] [JUDGMENT on blur-over-black]
    - Desktop watching a portrait phone caller: the 9:16 frame sits centered, full frame visible, and the side space is a heavily blurred, dimmed clone of the same video — edge luminance stays continuous so the face pops, and it reads premium instead of "letterboxed."
    - Phone watching a desktop caller: same, top/bottom fill.
    - Implementation: a second `<video>` with the same `srcObject`, `object-fit: cover; filter: blur(40px) brightness(.45) saturate(1.2); transform: scale(1.1)` (scale hides blur-edge falloff), z-under the contain layer. Fallback on weak devices (reuse the degraded/weak-device signal): solid `--bg` (#06080d) panels — no blur, no second decoder.
    - GPU note: one extra decoded video + a CSS filter. On the ?l2canvas=1 paint path the fill is drawn into the same canvas (draw the frame twice: cover-blurred beneath, contain above) — no extra element needed there.
23. **P0 — "life size" stays the opt-in crop mode, and the tradeoff is documented.** [JUDGMENT] Cover+face-centered crop (app.js:242 — "positioning is by the face; hair, ceiling and room are croppable") is the *mechanism* of true scale: a head rendered at real 165 mm width on a small letterboxed frame is physically impossible without cropping. So: default fit = contain (no crop ever, per directive); life-size toggle = cover (crop is the point, user opted in via the more-sheet). Gaze alignment works in both fits — `layout()` positions by the face either way.
24. **P1 — Mid-call orientation change.** Track dimensions flip (video `resize` event) → relayout contain + fill layers; the fill is aspect-agnostic so only the contain rect animates (250 ms). No renegotiation, no capture change, sender completely unaware — that is the payoff of item 21.
25. **P0 — Highest-quality guarantee stated as an invariant:** aspect handling never triggers a capture re-acquisition, a renegotiation, or a resolution change. The only knob that ever touches send resolution/fps remains the AIMD governor.

## 6. Loud-room indicator — ambient icon, tap-to-explain (user directive #2)

Current behavior: `#floorHint` is a full-width amber sentence pill pinned top-center under the status pill (`max-width: min(520px, 86vw)`, wraps to 2–3 lines) for as long as the room-noise detector is hot (app.js:1077 toggles `.on`, 3 dB clear hysteresis). The user is right: in cover-fit mode top-center is forehead/eye territory — it sits on the face, and it demands *reading* mid-call, which is the exact cognitive-load channel §3 is removing.

26. **P0 — Replace the persistent sentence with a 34 px ambient glass icon** (amber, waveform-with-slash glyph), top-left (mirrors the speaking dots top-right, pairs with the bottom-left mute badge: state lives at edges, never on the face). Same persistence semantics as the detector: icon visible while the floor is hot, gone when it clears — the existing hysteresis prevents flapping. **State persists as icon; explanation is on demand.** Same philosophy as the mute badge (A.5): ambient state, hidden chrome.
27. **P0 — Tap the icon → the sentence appears** in a glass card anchored under the status pill (existing sentence verbatim — it's good copy: "Your room is loud — the other person won't hear the breath before you start talking. A quieter room or a closer mic fixes it."), auto-collapses after 6 s or on any other tap. Never a centered popover over the face.
28. **P1 — First-fire notice:** one 600 ms amber pulse on the icon + a single light haptic, then it settles to static. It must not pulse forever (attention is the budget we're spending).
29. **P0 — Test compatibility:** `#floorHint` stays in the DOM with the sentence as its textContent and keeps its class-toggle contract — the icon becomes the visible default state, `#floorHint.on` becomes the *expanded* state (icon tap while condition hot). Telemetry logging of floor transitions is untouched.

## 7. Room links & admission — unguessable links, 1:1 admission model (user directive #3)

Current: lobby text input defaults to `morning`; share URL is `?r=<plain name>` (app.js:1816, 1988). Room names are guessable/enumerable and there is no admission concept at all.

30. **P0 — Crypto-random room links, minted client-side.** [INDUSTRY: Meet's `abc-defg-hij`, FaceTime call links, Jitsi random names] `crypto.getRandomValues` → 128 bits → base64url (~22 chars). Meet gets away with ~47 bits because Google rate-limits guessing; we have no rate limiter, so we take the full 128 bits — brute force is then not a threat model. **No server change needed**: the room Durable Object already keys on an arbitrary string; the mint is `join(randomId())` + `history.replaceState` to `?r=<id>`.
31. **P0 — Lobby flow inversion:** the primary button becomes **"Start a new call"** (mints an ID and joins). The room text input demotes to an advanced row ("join a named room") — pasted links pre-fill from `?r=` as today. Named rooms keep working for backward compatibility (old `?r=morning` links don't break).
32. **P0 — Admission model: link-as-key + hard occupancy cap of 2.** Recommendation with reasoning:
    - **Recommended: link-as-key** — possessing the link *is* the credential, exactly Meet/FaceTime-links semantics [INDUSTRY]. For a 1:1 intimacy product, a knock/admit state machine adds a second waiting room, an interrupt to the occupant, and a decision UI — friction that buys nothing once links are unguessable.
    - The admission control is the **1:1 occupancy cap**: a third party holding the link while two are present gets an honest "this call is full" screen — no queue, no knock, no presence leak (they learn only that the room is occupied, which the link already told them).
    - **P2 optional: "lock the room"** — once both parties are in, either can lock it (glass padlock in the more-sheet); late link-holders get "this call is locked." This is the 1:1-appropriate form of admission: zero friction, no knock UI, protects against the link being forwarded mid-call.
33. **P1 — Waiting-state share UX upgrades to match:** the share field shows the full unguessable URL (already does), copy button gets the icon+word pill treatment (C.16), and the waiting copy changes from "Send them this link" to "This link is the key — anyone who has it can join." Honesty about the capability model in one line.

## 8. Camera flip — rear camera (user directive #4)

34. **P0 — Flip control appears only when it can work.** After the lobby preview grants camera permission, `enumerateDevices()` → if ≥2 `videoinput` devices, a sixth glass circle (camera-rotate glyph) joins the bar; otherwise it never renders [INDUSTRY: FaceTime/WhatsApp always show flip on phones, never on single-camera desktops]. Hidden too when `videoDegraded` is set.
35. **P0 — Mid-call flip via new capture + `replaceTrack`.** Sequence: `getUserMedia({ video: { deviceId: { exact: nextId }, ...videoConstraints } })` → `videoSender.replaceTrack(newTrack)` (precedent: app.js:844) → point `#preview`/`#selfFull`/`#self` srcObject at the new stream → **stop the old track only after replace succeeds** (releases the sensor). Android devices that can't dual-open throw `NotReadableError` on step 1 → fallback: stop old track first, then acquire (accept a ~0.5 s black gap, logged honestly — the same "busy camera must not kill the call" posture as getMedia).
36. **P0 — Mirror only the front camera.** Apply `scaleX(-1)` to self views only when `track.getSettings().facingMode === 'user'`; fallbacks: label match `/front|user|facetime/i`, else remember-and-keep the previous mirror state [INDUSTRY: universal — front mirrored, rear never]. Remote side never mirrors.
37. **P0 — Re-lock exposure/WB/focus after every flip.** The new sensor powers up in full auto and *will* hunt — the §5 tell-9 problem applies to the rear sensor exactly as to the front. Re-run the `lockCamera` sequence (2.5 s settle → `exposureMode/whiteBalanceMode/focusMode: 'manual'`) on the new track, same `safeAsync` wrapping; devices whose `getCapabilities()` lack manual modes skip and log, which is the existing weak-Android posture.
38. **P1 — Remember the choice:** `localStorage['tape.cam'] = deviceId`; lobby preview and join prefer it while it's still enumerated. Telemetry logs every flip with `{ from, to, facingMode, fallbackUsed }`.

---

## 9. Implementation addendum (sections 5–8)

**index.html:** fit/blur layer for `#remoteWrap` (fill `<video>` beneath the contain layer; canvas path draws both into the one canvas); floor-icon element + expanded-card restyle of `#floorHint`; flip circle in `#bar` (hidden by default); lobby primary-button copy change; "call is full / locked" screens.

**app.js:** fit-mode state (`view.fit: 'contain' | 'cover'`, contain default — note this *changes* today's cover-everywhere default; life-size flips it to cover); video `resize` listener for mid-call rotation; `#floorHint` rewire (icon default, tap expands, class contract kept); `randomId()` mint + lobby flow inversion + occupancy-full message handling (server's room DO already rejects/holds third joiners — verify the current 1:1 signaling behavior before speccing the client screen's trigger message in phase 2); flip state machine (34–38); `localStorage` camera preference.

**Server:** untouched. Room minting is client-side; occupancy cap uses existing room semantics. (If the room DO does not currently send an explicit "full" signal to a third joiner, that one message is a phase-3 server task — flagged, not assumed.)

**New gates:** cross-aspect pairing runs (sender 16:9 → receiver 9:19.5 and inverse; assert zero crop in contain mode, fill present, mirror intact); flip test with fake device enumeration (icon appears/disappears, replaceTrack path, mirror rule, re-lock logged); floor-icon interaction test (icon default, tap expands, clears with condition); room-link test (minted ID unguessable-length, named-room backward compat, full-room screen).
