# HANDOFF — custom video lane (tape=2), continue in fresh session

*Written 2026-08-01, updated same day after tasks #22, #14, #21 and #23 completed. This document is the single
source of truth for resuming. Read `DESIGN.md` §16–§17.9 for the full story; this file is
the working state.*

## The goal (user's words, verbatim)

> "our custom app and custom everything without breaking things, lowest latency physics can
> buy us across the globe, video that feels like a video recording quality that is absolutely
> lossless and the audio as well, and every other pain point today with video calling solved
> plus everything that causes zoom fatigue gone: this is our goal and if we have to build a
> custom android app to achieve it fast instead of taking days so be it"

Design spine: **quality is a constant, time is the only shock absorber.** Fixed-QP encoding
(QP24), never degrade pixels; drop at capture (pre-encode) so the reference chain has no holes.

## Standing mandates from the user

- **Full autonomy**: build AND test everything yourself, creatively (download videos, emulated
  geolocation, whatever gets closest to real). Don't check in; keep going.
- **Plain language**: user has asked for "simple lang" five times. Lead with the everyday version.
- **Move fast** (asked explicitly this session).
- Memory files at `~/.claude/projects/-Users-earningsgpt-video-calling/memory/` — especially
  `measure-before-claiming.md` (nine wrong-mechanism postmortems; run the arm where the cause
  is absent) and `stimulus-can-be-the-bottleneck.md` (it struck again this session, see v12).

## Session 5 — 2026-08-02 ~05:30–06:45, user asleep, resumed after the API outage

**Why there is a gap in the log:** the two overnight agents (#37 ladder, #41 latency levers)
were both killed mid-flight by `502 / 429 usage limit reached` on every pool endpoint, and the
scheduled watch kept failing the same way for about an hour. Nothing was corrupted by it.

**The dead agents' work was COMPLETE, not half-applied** — verified, not assumed: every JS file
parses (`node --check`), every identifier the new code references resolves, there are no
TODO/FIXME/WIP stubs, and #41's lever is `?sendnow=1`, default OFF (flag-off is byte-identical).
Regression suites all green on the resumed tree: onset **69/69**, turn-taking **45/45**, AEC
**45/45**, pcmrs byte-exact, `tsc` clean.

**NEW `testbed/ladder-sim.mjs` — 67 assertions, 0 failures.** It SLICES THE REAL LADDER SOURCE
out of `app.js` at run time by comment marker (no copy, so it cannot drift; a moved marker fails
the run) and drives it against a Samsung M13 model on a virtual clock. The model is calibrated to
session 4's three live points and reproduces the third exactly (20.4 fps). It proves the decision
logic — trigger conditions, the revive→lowlight→devstep order, hysteresis, one-way tier walk,
revive→re-acquire escalation, the kill switches, and that no `applyConstraints` ever mixes
ImageCapture with stream constraints (the OverconstrainedError trap is armed in the model, so a
regression is a test failure instead of a field report). It does NOT prove physics: every fps and
luma it prints is a model number.

**NEW `phone-test.sh` + `testbed/phone-drive.mjs`** — one command, zero human input, drives the
phone's Chrome over CDP (playwright `connectOverCDP`, same driver family as `call.mjs`), joins
solo (capture starvation happens before any encoder or peer exists), and prints fps/exposure/
luma/tier per arm with a verdict. Arms: `default`, `control` (everything off), `lowlight`,
`stepper`, and `--sweep` over `?llexp=`. Every pre-flight failure has its own exit code and its
own remedy line (10 no adb, 11 no device, 12 unauthorized, 13 offline, 14 ambiguous, 20 no dev
server, 21 reverse failed, 30 no DevTools socket, 40 drive failed). Traps already encoded:
`am start` goes through the device shell and eats `&` (navigate over CDP instead), the lobby's
"starting…" never clears so `#call` visibility is the join signal, and the driver disconnects
rather than closes. The debug surface it reads (`__tape.srcprobe.settings/caps`, `__tape.lowlight`)
was exercised against a REAL MediaStreamTrack, not just type-checked: full settings incl.
`frameRate:20` / `exposureTime:50` / `exposureMode:"manual"` (camlock visibly applied), 12
capability keys, 121 frames, zero page errors.

**FIXED — the stepper was judging delivery against a rate the camera never agreed to.**
`devTargetFps()` returned the tier constant (30 for `strong`). Measured in the two-browser
regression, with the newly-logged `fr` field naming the denominator: the camera **negotiated 20
fps** (`fr:20`) and delivered **19.6–20.5** — 98–100% of its own agreement — which the old code
scored as 65% of a 30 it had never accepted, leaving an 8% margin (19.6 against an 18.0 trip
point) before a spurious downstep. `ladder-sim`'s
`honest-camera-below-30fps` scenario crosses it outright: a webcam that negotiates 15 fps and
delivers all 15 was stepped 1920×1080 → 960×540 for nothing. Now the target is
`min(tier, getSettings().frameRate)` — the camera's own answer to our constraint — so full
delivery of an accepted rate is healthy by definition, while the M13 (accepts 30, delivers 5)
still trips. `?fpsagree=0` restores the old behaviour. RESIDUAL: this assumes `getSettings()`
reports the NEGOTIATED rate; a HAL reporting the ACHIEVED rate would look healthy at 5 fps and
would silence low-light too. `phone-test.sh` prints the M13's own `settings.frameRate` — confirm
before trusting it.

**Two findings, one falsified hypothesis:**

1. **`exposureTime` is in 100-MICROSECOND units, and the device's own numbers prove it** — AE in
   the dark reported ~1200 while still delivering ~8 fps; 8 fps allows ≤125 ms/frame, so 1200 can
   only be 120 ms. Consequence: `1000/fps` in `applyLowlightExposure` asks for a TENTH of a frame
   period (4.2 ms at 24 fps), not a frame period. It is kept because 20.4 fps was measured with
   it — the value is proven, its derivation is a coincidence — and it is now documented in place
   with `?llexp=<units>` to sweep the trade on the device.
2. **The dim-room gap (open, not fixed).** Low-light triggers on "is the image DARK" (luma < 20)
   when the mechanism is "is the EXPOSURE long". In a merely dim room the model sits at ~14 fps
   with a perfectly well-exposed picture (luma 110/255, exposure 50 ms) — starving, but not dark,
   so the exposure lever stays gated off and the resolution ladder burns TWO tiers down to
   640×360 and still delivers 14.3 fps. Resolution was never the lever there either. Suggested:
   trigger on measured `exposureTime`, not luma. Needs device confirmation first.
3. ~~**FALSIFIED before it reached DESIGN.md**: the camlock freezing a mid-climb exposure as the
   cause of "goes dark after a few seconds". At 2.5 s the AE is already ~80% converged (luma
   90/255), so the lock freezes a fine exposure. Ran the arm first; cost nothing.~~
   **↑ THIS WAS WRONG. The camlock IS the cause — proven on the device in session 6.** The
   simulator only showed that freezing a converged exposure *should* be harmless; the M13 does not
   freeze anything. Read session 6 before trusting any other simulator verdict about hardware.

**BLOCKED, and this is the important one: THE PHONE IS NOT CONNECTED.** `adb devices` is empty
and the USB tree shows only the Dell keyboard, an iPad and the Logitech mouse — no Android device
at all, and `adb kill-server`/`start-server` does not bring it back. It was working earlier in the
night (session 4's numbers are real), so it dropped at some point. **Every M13 number in this
section is either a session-4 measurement or a model number. Nothing was measured on the device
tonight.** Re-plug the phone (unlock it, set USB mode to file transfer, accept the RSA prompt) and
run `./phone-test.sh` — it will say exactly what is wrong if anything still is.

**Two-browser regression, 4 arms × 30 s, all clean** (`testbed/runs/ladder-{on,off}-*`,
`agree-{on,off}-*`): errors 0 on every browser, connect 832–909 ms, onsets 3/3, turns 2/4,
perceived gap 1876–1910 ms and lead 236–246 ms across all four — inside run-to-run noise. And the
ladder was PROVEN TO HAVE RUN rather than assumed to have: 16 `srcprobe` samples per arm, tier
`strong`/`h264-present`, `measure:1`, taking correctly ZERO actions on a healthy bright camera.
What this does NOT cover: the acting paths (low-light, revive, downstep) never fire on a healthy
fake camera — those are covered by `ladder-sim` for logic and by the phone for physics.

**DEPLOYED 2026-08-02** — tape-app version `0c9563e3`, plus tape-phase1 `cb31390c` and
tape-fatigue-lab `11ee43d2`. Every asset in all three `public/` trees was verified byte-identical
(md5) to what the edge serves. The gate ran on the M13 first and found two real bugs before the
push; see "Session 6" below. Note for the next session: `/index.html` and `/sctp-probe.html`
return 307 — Cloudflare's asset handler serves them extensionless, so a diff against the `.html`
path compares against an empty body and every file looks 100% changed. Diff `/` and `/sctp-probe`,
and strip the CF challenge script Cloudflare injects before `</body>` or index.html never matches.

## Session 6 — 2026-08-02, phone reconnected, TWO REAL BUGS FOUND, THEN DEPLOYED

The user asked to "deploy everything". The gate ran first and it was worth it: the deploy that
was queued would have made the M13 *worse*, not better.

**BUG 1 — the luma watchdog read 0.0 forever on Chrome-Android, so it could never be right.**
It drew a hidden `2px / left:-9999px` `<video>` to a canvas. `autoplay` does not start such an
element, and a PAUSED element still reports `readyState 4` and a real `videoWidth`, so the guard
`readyState < 2 || !videoWidth` passed and `drawImage` copied a never-painted black frame.
Decisive arm — one track, one second, three readers: hidden element **0.0**, visible element
**96.2**, VideoFrame **97.4**. Since the low-light trigger is `luma < 20`, low-light would have
engaged on EVERY M13 call in ANY lighting, capping exposure and maxing ISO on a good picture.
Measured end state of that path: **luma 1.5 at 30 fps** — a black screen, smoothly.
Fix: read the VideoFrame `srcProbe` already holds (free; it pulls every frame for its fps count).
The element is now the Safari/Firefox fallback only, with `.play()` called and `!paused` in the
guard. When no frame can be had it records NOTHING rather than 0 — a watchdog that cannot see
must not vote. `__tape.camlock.blindTicks` counts those; `luma {blind:1}` fires once at 3 ticks.

**BUG 2 — the 2.5 s camlock collapses M13 brightness 6x. This is the user's original bug.**
`applyConstraints({exposureMode:'manual'})` with no `exposureTime` does NOT freeze the exposure
AE chose; the M13 drops to a dark default. Same room, minutes apart, everything else identical:
locked **luma 16**, `?nolock=1` **luma 101** — with frame rate unchanged at ~16 fps in both, so
it is gain, not exposure length. 2.5 s is "goes dark after a few seconds", verbatim.
Fix: the lock verifies itself. Sample luma before; poll for ~8 s after; revert to
`exposureMode:'continuous'` if it fell below `LOCK_DARK_FRAC` (0.6). Two subtleties, both learned
the hard way — (a) POLL, don't glance: the sensor takes ~1.5 s to darken and a single check at a
fixed offset made one arm read 16 and the identical arm 101; (b) a luma baseline is a
PRECONDITION of the exposure lock, not a nicety — with no baseline there is nothing to compare
and the lock can never be undone, so with no reading (or luma < 8) it now locks white balance and
focus ONLY. Kill switches: `?lockverify=0` restores the old always-lock, `?lockdark=` moves the
threshold, `?nolock=1` still disables the lock entirely.

**Device facts worth not re-deriving:**
- `getSettings().exposureTime` on the M13 is NOT reliable — it returned 600 (60 ms) while the
  camera delivered 30 fps, which needs <=33 ms. It read 300 back correctly when set to 300, and 0
  under continuous AE. Corroborate with delivered fps; never quote it alone.
- `getSettings().exposureMode` reads back **'none'** after a manual apply, though capabilities
  list `['continuous','manual']`. Any `=== 'manual'` check is wrong here. The app only ever reads
  `caps.exposureMode.includes('manual')`, which is fine.
- Measured caps: `exposureTime {min 0.6546, max 1420, step 0.1}` (100-us units, so 0.065-142 ms),
  `iso {min 40, max 2500}`. A stale comment claiming "0.65-1420 ms" was corrected in place.
- Applying the low-light constraints renegotiates capture from **1080x1920 to 1088x1088** (square).
- The camera is single-holder and needs **~6 s** to release. Reusing one tab across arms yields
  `frames: 0 1 1 1 1 1 1 1 1 5 21` — one frame then an 8 s stall — so everything the app times
  from join runs against a frozen picture. `phone-drive.mjs` now opens a FRESH TAB per arm with a
  6 s settle, and waits for `srcprobe.frames > 5` (not just a non-null probe) before sampling.
- Chrome needs BOTH `pm grant` (app permission) and `ctx.grantPermissions({origin})` (site
  permission). Missing the second makes getUserMedia HANG, not fail.

**Falsified along the way** (cost ~10 min because the arm ran first): "the M13 rejects the app's
1920x1080 + resizeMode:'none' cold-join ask". All 8 constraint variants opened fine; the
audio-only joins were HAL release timing.

**VERIFIED IN PRODUCTION on the real M13**, 4 runs (2 control, 2 default) against
https://room.tokkah.com: luma settles 101-102, `camlock.locked=false` (lock applied then
correctly reverted), `lowlight.on=false` (correctly does NOT engage in a normal room), frames
steady. The 2 s dip at 2.5 s is the lock landing and being undone — visible and expected.

**Deployed:** tape-app `0c9563e3`, tape-phase1 `cb31390c`, tape-fatigue-lab `11ee43d2`. All
assets md5-verified against the edge.

**Still open:** the dim-room gap from session 5 (low-light gates on luma when the mechanism is
exposure length) is unchanged. Note that BUG 2's fix makes it less urgent — the dim readings that
motivated it were partly the camlock. Re-measure before acting on it. `--sweep` (`?llexp=`) has
still not been run on the device.

## Session 7 — 2026-08-02, task #38 Phase 2: the UI/UX rewrite, IMPLEMENTED + TESTED, NOT DEPLOYED

User directive #4/#5 ("the ui is pretty bad… simple icons… dark glass circle… self view only on long
press… make a list… currently its bad"), plus "resume from the subagents, not from scratch".

**Phase 1 was recovered, not redone.** The research spec existed as a subagent transcript under a
DIFFERENT project dir (`~/.claude/projects/-Users-earningsgpt/…/subagents/agent-a8d5f11be8613fa3d.jsonl`
— the video-calling project's own transcripts contain zero Agent calls, which is why the first search
found nothing). Its output file had been wiped from tmp; it was reconstructed by replaying the agent's
`Write` then applying its `Edit`, and is now persisted in the repo as **`UI-SPEC.md`** (32 KB: research
digest with citations, 38 numbered P0/P1/P2 items, fatigue-mechanism→decision map, cross-device aspect
policy, loud-room, room links, camera flip). **If you need the reasoning behind any UI decision, it is
in that file, not here.** Do not re-derive it.

All 38 items are implemented in `tape-app/public/index.html` (rewritten, ~37 KB) and
`tape-app/public/app.js` (~15 edits). Summary of the design in **DESIGN.md §15**, which now carries a
second build-status note naming which half changed (control surface, yes; presentation, no).

**Gates, all green on the final tree:**

| Suite | Result |
|---|---|
| `testbed/ui-call.mjs` (5 aspect ratios × 2 peers) | **ALL PASS**, no `pageerror` |
| `core/onset.test.mjs` | 69 passed, 0 failed |
| `tape-app/turntaking.test.mjs` | 45 passed, 0 failed |
| `core/aec.test.mjs` | 45 passed, 0 failed |
| `testbed/fscheck-call.mjs` | PASS |
| `testbed/lobby-probe.mjs` | clean (admission, 409 cap, echo RTT, epoch persistence) |
| `testbed/call.mjs` | full 105 s call, 0 app errors |

**Four bugs this session were mine, found by measuring rather than by assuming — the pattern to
repeat:**

1. `cap is not defined` (×3 per call, silent inside `safe()`): extracting `captureConstraints()` out of
   `getMedia()` orphaned two references. Found only by reading the telemetry error counter in a
   `call.mjs` run, NOT by any test. **The suites do not assert on `safe()` error counts — they should.**
2. The leave-confirm pill overflowed a 390 px row: six circles + a 150 px pill does not fit, so the bar
   clipped at both edges and left a live mute button under the finger travelling toward "leave". Found
   by *looking at a screenshot*, not by a passing test. Fixed by collapsing the siblings to zero width
   (`#bar.confirming`); `#save` also moved out of the bar into the more sheet.
3. The matrix measured only the RESTING bar, which is the narrowest state it ever has. `#flip` never
   renders under a fake camera (one device) and the confirm pill was never measured. `ui-call.mjs` now
   measures both worst cases and asserts exactly one hittable control while armed.
4. `fscheck-call.mjs` had been broken since the chips moved into the more sheet (clicked a hidden row)
   and its `object-fit === 'cover'` assertion predated the contain-fit policy. **It was not in the
   suite list I ran from memory.** Run every UI-touching suite: `ui-call`, `fscheck-call`,
   `lobby-probe`, `call`.
5. Spec item 24 (sender rotates mid-call) was only half built — `layout()` re-ran on OUR resize but
   nothing watched THEIR track dimensions, and on the canvas path there is no element resize event at
   all because the tape renderer owns the canvas. Closed by adding a `resize` listener on `#remote`
   (video path, instant) and a two-integer dimension check inside the existing 2 Hz `startRemoteFill()`
   tick (both paths). That timer now also runs on weak devices, where it skips the paint but still
   watches. **This one is reasoned, not measured** — the fake camera has fixed dimensions, so no suite
   can rotate a sender. If a real two-phone test ever runs, verify it there.

**Then three subagents audited all 38 items against the shipped code, one slice each.** That found
eight more real gaps, all now fixed and gated. The one that mattered: **item 22's blurred wash was
not filling on any non-16:9 viewport.** `#call.contain #remoteWrap canvas` (written for the lane-2
display canvas) also matched `#remoteFill` and outranked its own `object-fit: cover`, so the 32×18
wash canvas letterboxed ITSELF — a phone in portrait watching a landscape caller got exactly the
black bars the directive was written to remove. Fixed with `:not(#remoteFill)` and gated in
`checkFull()`. Note the gate must assert "no gap at any edge", NOT equality with the viewport: the
wash carries a deliberate `transform: scale(1.14)` and `getBoundingClientRect()` reports the
transformed box. The other seven: "they left" never faded (the fade was hard-coded to the literal
string `'connected'`); the auto-hide timer was not re-armed by taps on the bar's own controls, so
muting at t=2.5 s made the row vanish under your finger on touch; `#mic`/`#cam` never entered a
disabled state on an audio-only join; the loud-room card did not close on a tap elsewhere; the
camera flip stopped the old sensor BEFORE `replaceTrack` landed, parking an ended track on the
sender; flip telemetry omitted `from`/`to` device ids; and `ui-call.mjs` enumerated four properties
in item 20 it never asserted. A subagent added those four gates (48 px floor above the 380 px
breakpoint, safe-area padding, bar × PiP × badge non-overlap measured on the BUTTONS not the bar
box, PiP on-screen when pinned) and — correctly distrusting a first-run pass on four
never-asserted properties — verified each with an injected-regression negative control before
declaring them real.

Two deliberate deviations from `UI-SPEC.md`, both commented at the site: the letterbox wash is a 32×18
sampled canvas (on the lane-2 canvas path `#remote`'s srcObject is the carrier, not the presented
picture), and self view is press-and-hold with a 900 ms floor rather than a 500 ms threshold +
double-tap. New real instruments on `window.__tape`: `micEnabled` (under `?pcmaudio=1` there is no audio
RTP sender, so `getSenders` cannot see the mute) and `chrome` (`barShown`, `pinnedForMs`, `sheetOpen`,
`leaveArmed`, `selfPinned`, `selfPeek`).

**DEPLOYED 2026-08-02 as version `ed7f1854`** (full `ed7f1854-d7e7-4846-9fca-92c9409ec16d`), on user
instruction, after the full gate above was green. Two assets changed: `index.html`, `app.js`.
Verified rather than assumed: `app.js` sha256 at `room.tokkah.com` and `tape-app.deshmukh.workers.dev`
is byte-identical to the tree; `index.html` is byte-identical except for Cloudflare's own
bot-challenge script injected before `</body>` at the edge (`/index.html` 307s to `/`, so hash the
root, not the path). Then a real two-browser smoke against **https://room.tokkah.com** (not
localhost): both peers connected over the real internet, self view off by default on both, selfFull
handed off, letterbox wash correct (`contain=true, fit=cover`), bar reveals with all controls ≥44 px
and on-screen, mute badge + `__tape.micEnabled === false`. Screenshot confirms the wash fix live —
the bands above and below the frame are blurred picture, not black.

**Pre-existing, NOT from this deploy, but worth knowing:** the strict CSP from #32 hardening
(`script-src 'self'`) blocks Cloudflare's own injected scripts — the `cloudflareinsights.com` beacon
and the inline bot-challenge shim both throw CSP violations in the console on every page load. The
app is unaffected. If Cloudflare Web Analytics is ever expected to report, it currently cannot.

## Where we are RIGHT NOW (end of this session)

**Task #22 is COMPLETE — criterion met 2026-08-01.** The decisive run, verbatim from this
ledger (`lane2-loss1`, `--ms=30000 --p2psim --rtt=80 --loss=1`):

| direction | sustained (last 10 s) | frames lost | keyReqs | age p50 | FEC repairs |
|---|---:|---:|---:|---:|---:|
| A → B | **11.98 Mbps** | 0 | 0 | 132 ms | 26 |
| B → A | **9.07 Mbps** | 0 | 0 | 90 ms | 33 |

Control arms (measure-before-claiming): no-FEC → 3,709–5,387 lost, 47–54 keyReqs, decoders
stalled 20+ s; FEC-without-governor → 177–412 lost, age p50 1,535 ms. All three pieces were
needed. Survival batch 4/4 both directions. Loss-0 steady state: 30 fps admitted, age p50
71–73 ms through an 80 ms path. Regressions green: 54/54 onset, 45/45 turn-taking, tsc clean.
The full write-up is **DESIGN.md §17.7** (new this session).

**Task #14 is COMPLETE — the display was the network, four times over.** New probes
(capLag / encLat / fullAge / presentLag; §17.8) measured past the decoder for the first
time: the `MediaStreamTrackGenerator`→`<video>` display path was an UNCONTROLLABLE adaptive
jitter buffer — present lag p50 280 ms clean, 740–875 ms at 1% loss (it reads our FEC-hold
delivery as jitter and grows; never shrinks). True glass-to-glass was ~356 ms clean, not the
~75 ms the lane age suggested. Fix: paint-on-arrival canvas (`?l2canvas=`, DEFAULT ON,
`=0` is the control arm) — decode output → `ctx.drawImage`, no buffer by construction.
Result (cap3): present p50 0.3–0.4 ms, p95 ~15 ms (one vsync), identical at both loss
levels. **Glass-to-glass now ~75 ms clean / ~75–92 ms at 1% loss, RTT 80** (was ~356 /
~810–950). Criterion re-passed on the new path (crit-canvas: 9.86/8.51 Mbps sustained
last-10s, 0 lost, 0 keyReqs); regressions green. Write-up **DESIGN.md §17.8**.

The three pieces that landed this session, in order:

1. **Slot + claim signaling** (killed the answerer-carrier death at RTT 80): offerer's first
   offer carries a recvonly video slot; answerer's `claimSlot()` moves its carrier into it
   before createAnswer. One offer, one answer, no reoffer ever (lane 2's
   `onnegotiationneeded` is hard-gated). Runs `lane2-slot5/6`, `claim2`–`claim7`.
2. **XOR-parity FEC** ported from lane 1 (group `?l2fec=3` default, keyframe duplication
   `?l2fkey=1`, 250 ms hold `?l2hold=`): single-loss groups repair in-worker; reference
   chain never sees the 1%.
3. **The governor** (AIMD on receiver-reported frame age over the ctl channel, 1 s cadence):
   the receiver's age is the ONLY signal that sees Chrome's pacer backlog. Sender paces
   capture admission 5→34 fps on it. Killed the 1.44 s pacer drop-ceiling queue AND the
   GCC-ramp startup hole AND the FEC hold-expiry losses with one mechanism. Plus the carrier
   clock is now a `canvas.captureStream(60)` — parity ticks no longer tax data (was 22.5 fps
   ceiling at 30 fps carrier). Runs `lane2-pace1`–`pace4`.

## The laws this lane obeys (all measured, do not relearn them)

1. **Any runtime `setParameters` (or receiver jitterBufferTarget/playoutDelayHint write) on
   the tape=2 pc rebuilds Chrome's pipeline WITHOUT the attached transform.** Every timing
   tried died (pre-negotiation, clock+delay, first-substitution+800ms). Four callers were
   found and neutralized: tape.js carrier params (deleted), app.js sender-params loop
   (skips video when `wantTape===2`), app.js receiver jbt/pdh writes (skips video receivers),
   tape.js second setCodecPreferences (deleted). **Never add one back.**
2. **The pipeline reads `.transform` once, at build time — find what builds the pipeline and
   attach before that.** Sender: `replaceTrack()` builds it, so transform goes on BEFORE the
   track (claim3: attach after = hooked yet bypassed, 447 raw frames, 0 ticks). Offerer's
   slot receiver: built inside `setRemoteDescription(answer)`, BEFORE `ontrack` fires — so
   the offerer attaches at slot creation, next to `addTransceiver` (claim6/7). The
   answerer's receiver is safe inside `ontrack` (its pipeline is built later).
3. One direction per m-line: sendrecv transceiver starves the recv transform.
4. Carrier must be VP8 (H264 packetizer parses NALs and mangles foreign bytes to nothing).
5. Carrier pacer budget rides in SDP: `b=AS:24000` on video m-line + `x-google` fmtp on BOTH
   offer and answer (`tuneVideoCarrier()`). NOTE: `x-google-min/start-bitrate` are confirmed
   NOT honored (v15-autopsy) — they remain in the munge harmlessly; the actual ramp control
   is the governor (law 10).
6. The carrier clock is a 320×180 `canvas.captureStream(60)` (its pixels are irrelevant;
   static P-frames cost ~tens of bytes on idle ticks). A cloned camera track caps ticks at
   the camera's rate (pace3), and one tick = one tape frame = parity spends ticks too
   (pace2: 22.5 fps data ceiling at 30 fps carrier, G=3). Fallback replaceTracks the camera
   onto `tapePre.getCarrierSender()`.
7. Frames already encoded are in the reference chain and must never be dropped — admission
   control happens at capture (pacing token || `inFlight >= 5 || q > cfg.maxEncQueue ||
   !remoteReady` skip; `?tif=` default 5 — 3 phase-locks with the carrier at equal rates).
8. Chrome ships `e.transformer` not spec's `e.transform` in the worker (tape.js handles both).
9. **Chrome's m-section matching never matches a pre-created transceiver** (slot5): the
   answerer's pre-created carrier transceiver matched nothing in the offer — both offered
   video sections got FRESH transceivers. Hence the explicit `claimSlot()`.
10. **The pacer queue is invisible locally; govern injection by receiver-reported age.**
    GCC starts ~2.6–3 Mbps and ramps ~12 s regardless of knobs. Over-inject and the price is
    a 1.44 s queue-age drop ceiling + a contiguous 36–44-frame SENDER-side hole at startup
    (receiver packetsLost=0). AIMD: +3 fps per 1 s tick while age p50 < 250 ms, ×0.6 on
    p50 > 400 or p95 > 900, clock offset EWMA-smoothed (single-ping offsets trip false
    halvings). `?l2pace=0` is the control arm; `?l2pstart=`, `?l2pai=` tune.
11. **Neutralize the orphaned carrier transceiver; never `tx.stop()` it** (claim2): stopping
    starved the claimed slot's encoder (shared track) AND queued an unsettleable
    negotiationneeded → ~1000-cycle offer/answer storm in 15 s.
12. **Lane 2 never renegotiates** (claim5): processing a reoffer rebuilds the answerer's
    receive pipeline without the transform (law 2 again, from the peer's side). The
    `onnegotiationneeded` handler is hard-gated on `wantTape === 2`.
13. **`MediaStreamTrackGenerator`→`<video>` is an adaptive jitter buffer with no knob**
    (cap2): p50 280 ms clean, 740–875 ms at 1% loss, grows on FEC-hold delivery and never
    shrinks. Lane 2 displays by paint-on-arrival canvas (`l2Canvas` default on): decode
    output → drawImage, `desynchronized: true`, backing store = frame size so the CSS
    object-fit: cover crop matches. Present p50 0.3–0.4 ms at any loss (cap3).
14. **Clock bases, measured not assumed** (cap1): the camera's `VideoFrame.timestamp` is a
    small media-pipeline clock, NOT `performance.now()`'s base (raw subtraction read
    1.785e12 ms), and rVFC's timestamp argument is on a third base (stamp with `now()`
    inside the callback). The sender ships its media-clock offset (running-min of raw
    capture lag) on the 1 s age report; the receiver adds it to the ping offset — that's
    what makes `fullAge` (capture→decode-out, cross-browser) real.
15. **Never spend a carrier tick on a gap parity can heal** (retx1/retx-s1 death spiral):
    fire-on-every-gap re-splice = 227–318 requests/run, each stealing a data tick → worker
    FIFO drops → more holes → admission collapse 43–74%. The two-phase hold is the law:
    parity gets `l2RetxWaitMs` (120) first, only survivors draw a `fragreq` (§17.9).
16. **ctl is not a real-time channel**: it is SCTP over the same lossy path — fine for 1 Hz
    reports, too slow to win a 250 ms race during congestion (retx-s3: 83 requests sent,
    15 across in time). Redundancy heals loss; only pacing heals congestion.

Unexplained but bypassed (slot6): an answer received by the peer's ws was neither applied
nor thrown by `setRemoteDescription` — silent. The claim architecture means no answer is
load-bearing anymore. Written up in §17.7.

## Key files

- `tape-app/public/tape.js` — both lanes. Lane 2: `prepareTapeRtp` (phase A: canvas carrier
  clock, carrier transceiver, `claimSlot`, `getCarrierSender`), `startTapeRtp` (phase B:
  FEC + #23 two-phase re-splice (90-frame worker retention ring, `fragreq` ctl), AIMD
  governor, capture admission, paint-on-arrival canvas display + #14 probes),
  `l2WorkerSrc` (worker: FIFO, splice-after-preserved-header, MAGIC 0x54415045, preserve
  10 B key / 3 B delta VP8 clear region, XOR parity send/repair). Hardlink warning:
  `core/onset.js` = `tape-app/public/core/onset.js` (one inode).
- `tape-app/public/app.js` — `TAPE_CFG` knobs (qp/tcm/tif/l2fec/l2pace/l2canvas/etc, all
  URL-overridable), `tuneVideoCarrier`, phase-A call in start(), recvonly slot +
  receiver pre-attach in the welcome handler (`tape.slot`), claimSlot call in the offer
  handler, `onnegotiationneeded` hard-gated on `wantTape === 2`, ontrack attach (guarded
  against double-attach), `remoteCanvas` creation for the #14 display path,
  fallbackToRtp (replaceTrack camera onto `getCarrierSender()`, removes the canvas).
  `index.html`: the `#remoteWrap` CSS rule covers `video, canvas` identically.
- `testbed/call.mjs` — two-browser driver. `--q='tape=2&...'` page query, `--video=` fake
  camera file, `--wavA=/--wavB=` fake mic files (pass ABSOLUTE — Chrome resolves them against
  its own cwd), `--spectap` far-end PCM tap (capture worklet — AnalyserNode is deaf on this
  graph), `--p2psim --rtt --loss` emulation, prints lane stats at end. Room ids carry
  a random suffix (parallel runs collided on same-millisecond `Date.now()` ids — both runs'
  A browsers ended up calling each other).
- `tape-app/public/spec-worklet.js` + `testbed/specband.mjs` + `testbed/media/fullband.wav`
  (25 s white noise) — the #21 far-end spectrum rig. Reusable for any audio-fidelity question.
- `testbed/media/cam1080.mjpeg` — regenerate any time:
  `ffmpeg -f lavfi -i "testsrc2=size=1920x1080:rate=30,noise=alls=3:allf=t" -t 30 -c:v mjpeg -q:v 3 -y media/cam1080.mjpeg`
  (alls=3 ≈ 12 Mbps at QP24; alls=10 ≈ 88 Mbps stress. zsh gotcha: brace `${n}` in loops,
  `$n:a` is a path modifier. `/tmp` writes blocked — use scratchpad. Run dirs accumulate:
  `runs/` has stale same-tag dirs from older sessions — always analyze the dir the run
  just printed, not a name search.)
- Local dev server: workerd on port 8794 (`wrangler dev` in tape-app). **Lane 2 DEPLOYED
  2026-08-01**: version 1ab82c63 at https://tape-app.deshmukh.workers.dev, propagation
  uniform from the first wave. Deploy auth gotcha: the `CLOUDFLARE_API_TOKEN` env var is
  broken (error 10000) — deploy with `env -u CLOUDFLARE_API_TOKEN npx wrangler deploy`
  so the saved OAuth login is used.
- **Production domain: https://room.tokkah.com** (custom domain on the same worker,
  current version **95336e2f** (full 95336e2f-75be-4f31-8067-0cad98a94546, deployed 2026-08-02: #37 weak-device ladder — no-H.264 ⇒ capture ceiling tiers 960×540/640×360@24, VP8-over-VP9 on software-only encoders, luma/AE watchdog w/ relock, srcprobe armed at join; suites green, 2 arms (default no-regression + forced-weak ceiling applied); served app.js sha256 == tree), previously b7aa7fc6 (#33 v-presenter §17.23)
  **DEPLOYED 2026-08-02 as version 0c9563e3 (this superseded the pending-deploy block below; tree tape.js now == prod):** #37 v2 measured-adaptive ladder (devstep: srcprobe delivered fps vs ask, <60% sustained 5 s after 6 s warmup ⇒ applyConstraints one tier down, one-way, `devstep` telemetry, ?ladder=0/?stepper=0/?devtier= kills; agent arms: default 0 steps, forced-weak dead-band holds, 5 fps fake-cam ⇒ exactly 2 steps to floor) + #37 v3 low-light motion-priority mode + stall-revival (spec below; implementing at handoff time).
  **USB PHONE RIG (2026-08-02 ~04:00, full autonomy night session):** M13 on USB, adb authorized (RZ8W90A1VQK, SM-M135FU, Android 14, Chrome 150.0.7871.186). Rig: `adb forward tcp:9222 localabstract:chrome_devtools_remote` + scratchpad/cdp.cjs (list/nav/eval/close/listen — Runtime.evaluate with awaitPromise/returnByValue; console+exception streaming). Traps hit: adb `am start` device-shell eats `&` in URLs (navigate via CDP instead); pm grant covers camera+mic; "starting…" status text never clears after a successful join (cosmetic — check #call display instead); closing a target prints non-JSON "Target is closing".
  **M13 ROOT CAUSE COMPLETE (scratchpad/m13-diagnosis.md session 4, all numbers live-proven):** the starvation is **exposure-bound, not resolution-bound** — AE stretches exposureTime to ~1200 ms in low light, capping delivered fps at ~8 at ANY resolution (5 fps @ 1080×1920, 8 fps @ 720×960); frame delivery can stall to 0 with track readyState 'live' (applyConstraints revives it); sequential constraints {frameRate:24} then {exposureMode:'manual', exposureTime:33, iso:2500} lifted delivered fps **8 → 20.4** in the same pitch-dark room (2.5×); Chrome-Android rejects mixing ImageCapture + stream constraints in one applyConstraints (OverconstrainedError) — always sequential. Device caps: exposureTime 0.65–1420 ms, iso 40–2500, exposureMode continuous+manual. Ladder v1's forced-weak tier worked mechanically but barely moved fps (5→8) — resolution was never the M13's lever.
  lobby full-screen pre-join + waiting, zero-stats default UI — HUD gated behind
  `?stats=1`, corner PiP in-call, aspect matrix 16:9/9:19.5/21:9/4:3/square all
  asserted), stall machine (§17.18: regime classifier, VIDEO HELD + lane-P stills,
  sender shed + clean-cut resume, `?stall=0` kill switch), worker hardening (#32:
  logToken-gated /log + /summary, /api/ice fetch-metadata gate + per-IP mint limit,
  CSP script-src 'self' + XFO DENY + nosniff + Referrer-Policy — all verified live
  in prod post-deploy)**. Previously **78d917c1** (2026-08-01 night: **Lane 0 lands
  (§17.15) — onset preemption (lever 3: 40 ms Lane B yield at each local onset)
  + turn-end predictive pre-warm (lever 4: turnend.js in the capture worklet →
  duplicated 13 B T_PRED on the pcm channel → receiver, only in a genuine
  ≥2 s listening stretch, pads ~25 KB T_PAD round-robin across ALL stripe
  associations + pre-stalls its Lane B 400 ms; coalesced 2 s/fall; T_PAD
  discarded on sight, never in RS groups; `?lane0=0` kill switch; tape worker
  FIFO 6→12 disclosed)**. Previously 42323653 (§10 session epoch + TIME_SYNC +
  A-V sync), 3fe1876b (Lane A v2 striping + fullscreen default), c50c847f
  (Lane A PCM + detector fix + noise-ceiling).
  Fullscreen detail (user request 2026-08-01 — `view.lifesize`
  default false; fill mode = `#remoteWrap` viewport-sized + `object-fit: cover`,
  camera aspect kept, crop never stretch; §1.1a life-size stays as the c-lifesize
  chip; verified two-browser: wrap == viewport both sides, chip round-trip clean.
  NOTE the lobby auto-calibrates pxPerMm=320/85.6 on every load, so life-size
  engages whenever the chip is on and peerGeom arrived). Wrangler
  now has `run_worker_first: true` so the worker can gate COOP/COEP on the flag —
  flag-off responses verified byte/header-identical in prod). TURN keys live as worker secrets (`TURN_KEY_ID`,
  `TURN_KEY_API_TOKEN`); `/api/ice` mints full TURN iceServers per request, 3600 s TTL,
  `p2pOnly:false`. Two measured device traps, both fixed 2026-08-01:
  1. **http:// loads the page but WebRTC is dead there** — Chrome throws
     `RTCPeerConnection is not allowed` on Join. The worker 301s http→https, and
     app.js catches a blocked constructor with a human message ("open in
     Chrome/Safari directly" for in-app browsers, which block WebRTC even on
     https). Never serve the app without the redirect. **The redirect is gated
     on the `cf-ray` request header, not the hostname** — `wrangler dev`
     rewrites `request.url` to the route's production host (measured: a
     localhost curl arrived as `http://room.tokkah.com/...`), so any
     hostname-based rule 301s local testing into a TLS-less https. `cf-ray`
     exists only on requests that crossed the real edge. (workers.dev serves
     http 200 anyway — the platform gateway canonicalizes scheme before the
     worker; the app.js catch covers that case.)
  2. **`routes` in wrangler.jsonc silently drops the workers.dev route** — keep
     `"workers_dev": true` or tape-app.deshmukh.workers.dev goes 404.
  3. **Camera busy must not kill the call** (user hit `Could not start video
     source` = NotReadableError on a real device, 2026-08-01). getMedia now:
     reuses the lobby preview's live camera track (opening the same camera
     twice is what trips finicky drivers), retries once after 700 ms, then
     joins AUDIO-ONLY (`videoDegraded` = 'busy'|'none', previewBadge says why,
     `join-novideo` telemetry, tape lane forced off — no video → no carrier).
     Permission denial still fails the join, with instructions. Test hook:
     `?novideo=1` (runs busyfix-normal2 / busyfix-novideo).
  End-to-end verified on room.tokkah.com 2026-08-01 (run `room1`): joined via the
  domain, connected in 2 s, lane 2 live both directions, 0 lost frames, glass-to-glass
  ~31 ms.

## Next (was "after #22")

**Remaining-work inventory taken 2026-08-01** (full ranked list in this session's ledger):
critical path = ~~PCM audio lane~~ **LANE A LANDED 2026-08-01** behind `?pcmaudio=1`
(default OFF, flag-off byte-identical — verified): 48 kHz/24-bit linear PCM, no codec,
8 ms frames, own unreliable/unordered `pcm-audio` datachannel, RS(10,13) FEC (30%,
recovers any 3/10, paced parity), SAB-ring worklet playout ±0.2% resample drift,
remote OnsetDetector inside the playout worklet (what the detector hears = what the
ear hears), concealment ≤24 ms then HOLD. Mouth-to-ear 115 → **46 ms RTT** (−69 ms,
the NetEq+codec budget deleted). Full fixture: 0 dropped/lost/late, concealed 0 ms,
onset median error 0 ms all four paths, inhales 100%. **Found a transport wall
(§17.11) — SOLVED same day (§17.12): the wall is SCTP's RFC 4960 AIMD, per
ASSOCIATION, per BYTE — the Reno ceiling 1.22·MTU/(RTT·√p) ≈ 1.5 Mbps at 80/1
prices every measured point; message size/rate/pacing are all innocent (37 KB
messages collapse WORST). §17.11's "14.5 Mbps video shape" was never SCTP —
those bytes rode the VP8 RTP carrier under GCC (loss-tolerant); the mystery was
a cross-stack comparison. THE LEVER: stripe frames round-robin across N
data-channel-only peer connections (cwnd is per-association → ceilings add).
Measured with Lane A's exact byte stream at 80/1: 3 associations → 98.2%
carried, age p50 43 ms / p95 82 ms, ZERO added latency (no bundling; bundling
measured and rejected — buys nothing, costs 8–24 ms). Residual 1.8% loss =
RS(10,13)'s repair class. **App-side stripe LANDED 2026-08-01 (§17.13), DEPLOYED
in 3fe1876b behind `?pcmpairs=N`** (default 1 = byte-identical; both sides must
pass the same N): at 80/1, 3 associations carry 99.4–99.7% of capture with
drop(link) 0, concealed ~2% (the playhead warm-up window — `?pcmjb=15` starts at
the steady state directly: 0.06–0.13%, fecFailed 30/30; whether initial depth
should follow expected path D is an open product decision), age p50 43–46 ms,
ping at path RTT, split even to the frame. Dose-response monotone: 1 collapses
(61–64%), 2 survives warm-tailed (96.7%), 3 is clean. Gate 4 caught+fixed a
parity-routing degeneracy (base%N → group-ordinal (base/RS_K)%N). Independently
verified post-review (`stripe-verify` reproduced every bar). **Relayed-path check
DONE 2026-08-01** (§17.13 follow-up, `testbed/relay-call.mjs`, 4 runs vs prod, every
pc relay-proven via getStats): **3-NEUTRAL on relay** — no Reno wall at ~15 ms
anycast-POP RTT (ceiling ∝ 1/RTT → 15–25 Mbps headroom); stripes land on DIFFERENT
TURN servers per pc, so the send-side gain (drop 395–729 → 149–449) trades a
receive-side skew tax (late ×3, fecFailed ×3–7, age p95 ×3) and concealment — what
the ear hears — is identical. Video lane indifferent to the arm (the p1 rerun
starved exactly as hard as both p3 runs; the fourth run killed the "3-hurts-video"
hypothesis). IMPLICATION: pcmpairs stays default 1; the stripe is 80/1-class
medicine — enable when association 0's measured baseRtt × loss presents the wall,
not by transport type alone. Untested corner: high-RTT AND lossy relay (skew tax
would apply; benefit unproven, not free). NOTE: every
datachannel lane inherits the per-association wall,
including ctl retransmit storms under loss. Passes at RTT 20/1% on ONE
association (99.8% sent, FEC repaired 115+108, concealed ≤1.2%).** Residuals: port-fallback ring untested, both-sides-flag required.
**Detector quiet-wall + classifier fix LANDED same day** (§17.1 follow-up: end-gate
max(floor+3, peak−20), second-look floor-gate −42, await-voice hang 1200 ms): corpus
clean-merge 60%→19.3%, breath classification ~16%→5/5, loud-floor false alarms
bit-identical; app-side `detfix` run = **7/7 turns on ALL FOUR paths, inhales 100%
mic AND far end, m2e RTT 68 ms, human gap 296.7 vs Boland 297**; suites 54/54 +
45/45 green. **DEPLOYED to room.tokkah.com (c50c847f)** with the noise-ceiling pill;
prod verified (redirect, header gating both ways, /api/ice, pcm.js). ~~Next: session
clock/TIME_SYNC/drift resampling/A-V
sync (§10)~~ **§10 LANDED + DEPLOYED 2026-08-01 (§17.14, version 42323653):
session epoch + TIME_SYNC (spread ≤2.7 ms at 80/1, drift fit in ppm) + video
presented on the sender's audio clock (applied offset p50 +27–30 ms in the queued
regime, inside §3's [0,45]; paint-on-arrival fallback with the flag off or
`?avsync=0`). Open §17.14 residuals: offset sign-convention naming (knob
direction vs regime), port-mode playhead staleness untested under load, two-machine
crystal drift is estimator-proven only (one-machine fixture), no perceptual
lip-sync fixture exists.** ~~Next: Lane 0 preemptive onset (§4) → turn-end predictor (§3.1 lever 4 — MODEL BUILT
2026-08-01: `tape-app/public/core/turnend.js`, measured on 204 held-out utterances: fall-in-progress
detector, 290 ms median lead, 17.5% recall at low waste, zero late fires; anticipation 250 ms out
is physically absent on read speech — doc updated. App wiring now unblocked —
Lane A's mic worklet is the integration point)~~ **LANE 0 + TURN-END WIRING LANDED
+ DEPLOYED 2026-08-01 (§17.15, version 78d917c1 — levers 3+4 together: onset yields
+ listening-gated pre-warm, wire cross-checks balance to the byte, §17.13/§17.14
bars unmoved, `?lane0=0` kill switch)** → ~~Lane A v2 striping~~ **LANDED
+ DEPLOYED 2026-08-01 (§17.13, `?pcmpairs=`, task #16 done)** →
**human turn-taking gate** (Boland paradigm, falsifies or confirms the §1.1c thesis —
HARNESS READY AND DEPLOYED 2026-08-01: https://tape-fatigue-lab.deshmukh.workers.dev/turns,
TURN secrets set; audit+dry-run in `fatigue-lab/GATE-READINESS.md`. It caught a blocking
bug: t0 was stamped at message arrival, but `end` events emit only after 350 ms of quiet —
every gap would have read ~315 ms short and genuinely fast turns would have been discarded
as interruptions. Fixed with ctxTime-stamped events; dry-run produced exact expected numbers.
Rule: stamp an event with the event's own clock time, never its delivery time.) →
stall machine (§12–13, IMPLEMENTED+VERIFIED 2026-08-02 — §17.18: regime classifier (nominal/squeeze/absorb + shed/HOLD), age-only shed trigger (p50>400ms OR fps≤3, 3s dwell), lane-P JPEG stills @1fps while held, sender shed via ctl, clean-cut resume on fresh keyframe; gates green incl. independent stall-verify2 (PCM 99.42/99.63%, video 96/98%, zero false sheds; HOLD fired both sides at 0.5 Mbps); DEPLOYED 2026-08-02 in version 35118ff8 — train: #22 stall + #32 hardening + #28 UI, one deploy, headers + served code verified live in prod). #32 worker hardening DONE 2026-08-02 (verified): DO-minted persisted logToken in welcome (additive) gates GET /log + /summary (403 without); POST /log bounded 1 MiB/3000 batches/hr; /api/ice gated on fetch-metadata + 20 mints/10min/IP with STUN-only graceful fallback (strict room-binding needs next client deploy); strict CSP script-src self + XFO DENY + nosniff + Referrer-Policy, COOP/COEP preserved; E2E proven on ephemeral dev (2 browsers, CSP clean, token harvest works); old-client impact: none for calls (client never GETs /log — verified: only fetches are /api/ice ×2); testbed call.mjs captures welcome.logToken with unhardened fallback; DESIGN.md §8 lane-1/lane-2 track claim corrected → lobby capacity probe (§15, DONE 2026-08-02 — §17.19: room DO hard-caps at 2 BY DESIGN so no occupancy tiers exist to find; control plane flat to 50× the §14 design load with zero lost messages, no knee; cold-DO first join ~1 s, warm 175 ms; session_epoch_us survives eviction; real lever is DO locationHint, designed-not-applied) → fatigue validation →
native client. USER PRODUCT DIRECTIVES 2026-08-02 (verbatim bar): remote view as close to SELF-VIEW as possible (resolution/fps/rendering/latency); measure BOTH glass-to-glass latencies precisely (telemetry only, NEVER in UI); UI dead simple — no stats; full-screen self-view until peer joins; E2E-secure with ZERO added latency (transport DTLS already E2E; add out-of-band safety numbers); flawless on all aspect ratios. Tasks: #28 UI/lobby/aspect (queued behind #22), #29 dual G2G probe (DONE 2026-08-02 — §17.20: self 27.1 ms p50 fake-cam / 44.1 real-cam; remote loopback 56–59 ms (+29–32 vs self), 80/1 122–145 ms; bounds ride every number; biggest lever = render-queue/audio-depth coupling; additive hooks ?selfprobe=1 / ?g2gprobe=1 / presentLag-under-engagement SPECIFIED, queued post-train. Mutex fix: gate on `ps -eo comm,args` node-executable match, loose pgrep deadlocks on wrapper shells), #30 E2EE verify+safety numbers. USER FEEDBACK 2026-08-02 #2: "remote rendering very far off self-view smoothness, no frame dropping" → task #33 cadence-locked presentation for the DEFAULT path (decouple §17.14 scheduler from avsync bundle; bounded disclosed queue; gate: remote IPI p99 ≤ 1.5× self-view). #34 codec frontier DONE 2026-08-02 (§17.24, testbed-only): AV1 REJECTED with numbers — 99.7 bar crossing at q100 costs +1.3% bits for −0.03 VMAF vs H.264 QP24 (RD curves coincide at the transparency ceiling; AV1 enc latency genuinely better 5.7 vs 6.4 ms p50 but the spine's bottleneck is bits); ROI/QP-raise REJECTED — center-region degrades at ≥ global slope (no face reserve to spend); §6 premise UPDATED: AV1 is PRESENT on Chrome 149 (quantizer mode honored, real 0–255 qindex) but not better at our point — a stronger reason to stay H.264; calibration fallout: §6 Tier B bitrate ~27% optimistic (9.53 not 7 Mbps-at-fps; real uplink ~11 Mbps); content dynamic range at constant quality ~7× (1.74↔12.0 Mbps-at-fps) — lane-P stills earn in SQUEEZE/SHED, not calm scenes. USER DIRECTIVE 2026-08-02 #3 (verbatim): "i just hope with all the requests that i have made, we when we launch , we have shipped something that feels 10x better than zoom or google meet in every way possible and especially on the zoom fatigue thing, we really have to nail that 10x or maybe 1000x better than existing solutions" → task #36 launch 10x audit (every dimension scored vs Zoom/Meet baseline, proven-vs-unproven honesty; fatigue validation still needs the two-human gate). USER DIRECTIVE 2026-08-02 #4 (verbatim): "and the ui is pretty bad and due to some error in android smasung m13, the video goes dark not completely after a few seconds opens up pretty good but then sucks, also the ui has to simply icons and maybe a dark glass circle behind them looking completely simple and premium at the same time and things like self view only appears on long press on the icon otherwise self view when in a call should be by default off and a lot of things please make a list that makes the ui/ux something that clear and for the best user experience ever in the software industry you pronbably need to think about this and read some research papaers currently its bad" → task #37 (Android Samsung M13: video darkens after a few seconds, then quality degrades — diagnose from prod telemetry on a user repro session, then fix) + task #38 (premium UI/UX redesign: icon-only controls on dark-glass circles, in-call self view OFF by default and shown on long-press only, full research-backed UX list; spec first, implementation queued behind #33 tree ownership). USER DIRECTIVE 2026-08-02 #5 (verbatim): "we also have to make a lot of decisions like how do we show aspect ratio from desktop in mobile and aspect ratio from mobile in desktop do we directly take the camera feed and show it according to the remote viewer or soemthign so we dont have a crop in either devices also end up showing the highest quality, things like room is too loud pop is covering a lot of screen should it fade away or should it be just an icon which when viewer taps they know what the issue is and a lot of ui/ux decisions like this need to made so that we can take over zoom and google meet in every way, things like admittig participants and links that are unique not like us" + "things like rear camera" → all folded into #38 spec: cross-device aspect-ratio policy (no crop on either side, highest quality), loud-room indicator → ambient icon not popover, participant admission model, unguessable unique room links, rear-camera flip. USER DIRECTIVE 2026-08-02 #6 (verbatim): "i think apart from all the things that are going, our goal even now should be to keep cutting latency and maybe glass to glass have latency only one way not two way latency which doubles and is currently what it is, we need some innovation here read all the technical computer scienece papers and then whatever the latency is of the devices cut that to the absolute minimum too maybe like under 10ms from processign to rendering" → task #39 latency innovation: one-way g2g accounting (already the §17.20 convention), device-pipeline budget target <10 ms processing→render, literature sweep for implementable ideas, stacked on #33 v-presenter. USER DIRECTIVE 2026-08-02 #7 (verbatim): "my point currently i can see the latency and it is visible to me, what i want to achieve and this needs to be achieved i dont know how but we have to do it, the latency should not be noticable even with a india and us west call, we really need to hit the floor on across earth communication and keep innovating until we hit every possible physics software and hardware walls from every angle" → #39 scope expanded: target = PERCEPTUALLY INVISIBLE latency India↔US-West (physics floor: fiber one-way ~110–140 ms real routes; ITU G.114 noticeability ~150 ms); attack every wall: network path (edge/anycast/path racing #24), device pipeline both ends, perceptual masking (onset head start already hides 320 ms of the perceptually-critical moment). Parallel autonomous items: real-camera capture measurement (DONE this
session — §17.10), path racing (§8), reference-based AEC (§5 v2), noise-ceiling
honesty (§17.1, DONE 2026-08-01: `floor-high` hint at −49 dBFS app-units — §17.1's −45
physics threshold minus the measured 4 dB fixture-label offset; 3 dB hysteresis, 2 s
persistence both ways, `?floorhi=` override; DEPLOYED in c50c847f), measurement debt (own-cost slope repeats; VMAF crossover MEASURED 2026-08-01, §17.16 —
no crossover ≥ ~2 Mbps; QP24 lane at rig floor 99.7 VMAF, beats VP8 ceiling 77.6 at half
the bits and full fps; crossing only QP ≳47/≤1.5 Mbps; fixed-QP spine justified). Onset-corpus miss rate MEASURED 2026-08-01 (`testbed/corpus-score.mjs`,
209 files, addendum in §17.1): speech hard-miss 0%, breath 3.6%; NO loud-floor
detection collapse (classification dies instead: 1/8 at −30 dBFS — the §17.1 window in
detector units); the real collapse is the QUIET wall — fixed 3 dB end-gate never closes
turns at −57 dBFS floors, 60% of utterances get no fresh onset; real-breath
classification 16% vs fixture's 100% (context: real breaths follow loud exhales).
Operating band −50…−40 dBFS. Detector-fix follow-up DONE 2026-08-02 (§17.17): fixes (peak-relative end-gate TURN_DROP_DB=20, floor-gated 150 ms second look, await-voice hang 1200 ms) pre-existed from the fix session but were unpinned — now 15 new tests (69/69), exact before/after corpus re-score via BEFORE=1 reconstruction: clean-floor fresh-onset 39.8→80.7%, breath classification 16→32% (100% at clean floor), speech hard-miss held 0%, breath 3.6→1.8%, loud floors bit-identical; residual: clean-floor FAs 27→62/24 min (cost datagrams, not ms). core/onset.js itself unchanged — no deploy needed. Needs two machines: real-distance soak, cross-device
pipeline numbers, drift over 60 min. Human-validation protocol for two non-technical
users is ready at `testbed/HUMAN-VALIDATION.md`.
**Real camera measured (§17.10)**: `call.mjs --realcam[=a|b]` — real 720p scene at
QP24 = 10.1 Mbps at-fps (fixture was 0.43); lane holds it (95% admitted, 0 lost, age
p50 21 ms). `cap→read` CANNOT see absolute sensor depth (law-14 running-min absorbs
constants) — that number needs two devices, Phase 1.

- ~~#14~~ DONE (§17.8): the browser playout tax was 280–875 ms, not 40–58 — the `<video>`
  element itself. Canvas paint-on-arrival is the default; glass-to-glass ~75 ms at RTT 80.
  What remains on this front needs real hardware: capture-side sensor/ISP pipeline depth
  (15–35 ms by the §19.1 ladder, invisible to the fake camera) — measure in Phase 1.
- ~~#21~~ DONE (§17.3): the Opus application-mode lever is a **measured no-op at 128 kbps —
  dropped**. Full-band white noise at A arrives at B flat to 20 kHz in BOTH arms
  (`astereo=0/1`, Δ ≤ 0.4 dB per band, decision rule needed ≥10 dB). The default chain already
  passes fullband audio; the voip/audio segSNR gap is a low-bitrate decision this project
  never operates at. Harness finding behind the measurement: **AnalyserNode is deaf on this
  graph** (−58 dB where the app's AudioWorkletNode hears −18 dB on the same context+stream,
  direct and clone-track alike) — spectrum/PCM taps must use a capture worklet
  (`public/spec-worklet.js`, `call.mjs --spectap`, FFT in `testbed/specband.mjs`).
- ~~TURN keys~~ DONE (2026-08-01): stored as worker secrets, `/api/ice` mints full TURN
  iceServers (udp/tcp/turns on 3478/5349/53/80/443), verified live on room.tokkah.com.
- ~~#23~~ DONE (§17.9): the FEC hole nobody could see — a group whose parity packet dies
  with its data has nothing to repair it and nothing to count (11–14 lost frames/run at 1%
  loss, fec-loss-rerun1/2). Fixed with receiver-initiated re-splice from a 90-frame worker
  retention ring (`?l2retx=0` control), two-phase so parity's window comes first
  (`?l2retxwait=`, default 120 ms — the fire-on-every-gap version ate its own carrier
  budget, measured). After: 2+0 and 0+60 (congestion episode; ctl is SCTP-delayed under
  backlog — law 16) vs 11+14 before; keyReq 0 in the clean run. Regression suites must stay
  green: 54/54 onset, 45/45 turn-taking, tsc clean. ✓ all green at #23 completion.
- ~~Deploy lane 2~~ DONE (version 1ab82c63). First live-worker run: 98% admission, 0 lost
  frames, glass-to-glass ~30 ms at real 0.4 ms RTT (media is P2P; cloud carries signaling).
- Phase 1 on two real machines; real-human fatigue validation. Watch on
  real machines: the governor's ramp (first ~15–25 s climb 5→30 fps as GCC's grant ramps) —
  expected, not a bug; and whether real NICs/cameras move the AIMD equilibrium.

## Session 8 — 2026-08-02, JOINING WAS BROKEN BY ONE LINE. FIXED + DEPLOYED (6272f3b3)

User: "fix call joining logic and deploy the fix … its also not working … simplest and fastest fix".
Scope held to the join path. Reproduced first, on prod, before touching anything.

**BUG 1 — the offerer slot was assigned by arrival order, so one reload killed the call
permanently.** `worker.ts signal()` had `const role = this.peers.size === 0 ? 'a' : 'b'`. When the
offerer reloads, the answerer is still holding `'b'`, the room is down to one occupant, and the
returning peer is handed `'b'` as well. Only `'a'` ever calls `offer()`, so **two `'b'`s mean nobody
offers** and both sides sit on "connecting…" forever. Reproduced 100% of the time on room.tokkah.com
by one reload (`testbed/.joinrepro.mjs`: both peers `role:b`, `pc:new`, no recovery in 8 s).
Fix: take the FREE slot — `const taken = new Set(this.peers.values()); taken.has('a') ? 'b' : 'a'`.
Exactly one offerer is now an invariant of the room instead of an accident of arrival order.

**BUG 2 — a spent page half-works when someone rejoins, which is worse than failing.** With bug 1
fixed the returning peer offers and the incumbent *answers* — and the incumbent still shows nothing.
`ontrack`'s once-guard (`remoteAttaching || remoteMon`) refuses a second remote stream, and the
receiver's track ended with the peer who left. **Measured on the rejoin arm: `framesDecoded`
148 → 208 while `#remote` stayed 0×0, `currentTime` frozen, "waiting for the other person" still up.**
Inbound RTP said healthy; the picture was dead. Fix: the incumbent re-arms from a clean page
(`reArmForNewPeer`, app.js) the moment `peer-joined` arrives — **synchronously, before it negotiates**,
because negotiating first lets the newcomer reach `peerArrived`, inherit a spent page of its own and
re-arm on the NEXT arrival (that is the ping-pong). Guards: only a page that actually connected
(`hadPeer`, set in `peerArrived`) re-arms — the normal "A waits, B joins" flow has `hadPeer` false and
never reloads — plus a 20 s per-tab cooldown in `sessionStorage` so the pathological simultaneous
case settles instead of looping. `?rejoin=1` (set by the re-arm and nothing else) auto-joins at boot.

**BUG 3 — dead sockets wedged rooms at "room full" forever.** `close`/`error` fire on a clean
teardown; a slept phone, dropped cellular or killed tab does not. Two ghosts and nobody can ever get
in. `signal()` now sweeps non-OPEN sockets before the capacity check. **This is not theoretical —
the prod trace shows it firing**: the returning peer's welcome is followed by TWO `peer-left`s,
i.e. the old socket was still registered at admission time and would have 409'd the rejoin. It never
showed on loopback; only real network latency makes close events lag.

**BUG 4 — pasting the invite link into the room box reported "this call may already have two people
in it".** A URL fails the server's `[A-Za-z0-9_-]{1,64}` room regex, the ws upgrade 400s, and the
browser exposes no status code for a failed upgrade — so the client's one guess was printed with
confidence. `roomFromInput()` now pulls `?r=` out of a pasted link, turns spaces into `-`
("morning call" is a room name, not a mistake), and refuses the genuinely impossible in words.
Arriving by link also hides the named-room row: leaving the raw 128-bit key in an editable box
invites the one edit that puts you alone in a different room.

**Gates (new, `testbed/.joingate.mjs` + `.joininput.mjs`).** Verdicts read off the PICTURE — element
dimensions plus a moving `currentTime` — never off status text, which said "connected" through the
whole of bug 2. Scenarios: cold start, full room (third person told, stays in lobby), reload mid-call,
drop-and-return, second return inside the cooldown. **3 consecutive 5/5 runs against prod**, plus 5/5
on the input gate. Regression suites green: onset 69/69, turn-taking 45/45, AEC 45/45, pcmrs
byte-exact, `tsc` clean. One 4/5 run happened in the minute after `wrangler deploy` (scenario 3, B
showing the exact pre-fix symptom) — consistent with asset propagation; three clean runs after.

**DEPLOYED** version `6272f3b3` to room.tokkah.com; served `/app.js` md5 verified identical to local.
The deploy also carried task #39's encoder knobs (`?hint= ?degrade= ?maxfps= ?scaledown=` + the
`__tape.encpolicy` getter) which were sitting undeployed in `public/app.js` — all four default to the
previously shipped values, so flag-off behaviour is unchanged. index.html was already byte-identical
to prod before this deploy (the session-7 "NOT DEPLOYED" note above is stale).

**Known, NOT fixed, in rough priority order:**
1. **No signaling reconnect.** If the ws drops mid-call while media survives, that side is deaf to
   the room forever — it never learns the peer left or came back. The re-arm cannot help, because
   `peer-joined` is the thing it never receives. This is the next real join bug.
2. **`/api/ice` is 20 mints / 10 min / IP** and two people behind one NAT share that bucket (2 mints
   per join, and a re-arm costs 2 more). On 429 the client silently falls back to STUN-only, so
   cross-network calls just fail to connect. Deliberately not touched — it is a security limit with
   stated reasoning — but it is a live join risk worth a decision.
3. The re-arm is a page reload. It is the only reset with no state left over, which is why it was
   chosen over rebuilding the pc by hand, but it costs ~1–2 s and a camera re-open.

## Distance to goal (as told to user)

~80%. Working and DEPLOYED: fixed-QP video on the transform lane at the design point WITH
loss survival (proven at 1% loss, RTT 80: ~9–12 Mbps sustained, zero lost frames), a
measured glass-to-glass of ~75–92 ms at RTT 80 (~30 ms on the live worker at real 0.4 ms
RTT), fullband audio proven flat to 20 kHz at 128 kbps (#21), fatigue fixes, telemetry,
emulated-distance testbed.
Blockers: capture-side sensor tax + real-distance AIMD equilibrium (needs Phase 1, two
real machines), real-human validation. TURN is live on room.tokkah.com (verified).

## Session 2026-08-02 (late): camera flip, lane parity, lane latency

Deployed, in order: `7f3f72c7` encodeSize, `14c0d93e` `?upscale=1` control arm,
`9b383106` mid-call resize, `48d7fd34` lane 2 adoptTrack, `8da092ef`
`__tape.lane`, `51831abb` **lane 1 parity**, `f13e8c59` **carrier preservation**
(current live).

Three shipped bugs closed, each with a control arm on the same live build:

1. **Camera flip killed the video lane, on BOTH lanes.** The capture pump read
   the camera through one `MediaStreamTrackProcessor` and returned for good on
   `done`. Far end fell to 0.4 fps permanently with no RTP fallback. Fixed with
   `adoptTrack(nv)` + a re-attach loop in both `startTapeVideo` and
   `startTapeRtp`; `adoptVideoTrack` calls it before stopping the old sensor.
   Lane 1: 0.4 → 29.9 fps. Lane 2: 0.4 → 29.0 fps.
2. **`adoptVideoTrack` overwrote lane 2's carrier.** That sender holds a 320×180
   canvas ticking at 60/s, not the camera; replacing it with the 30 fps camera
   dropped throughput to the 30 × G/(G+1) = 22.5 fps ceiling the carrier exists
   to lift, and made libwebrtc encode a discarded 720p frame per tick. Measured
   22.7 → 29.0 fps. This is the "~22 fps, reported not explained" note from the
   previous session; it is now explained and fixed.
3. **Both lanes now carry the mid-call encoder resize**, not just lane 1's
   join-time `encodeSize`.

Open, recorded in MEASURED.md, deliberately NOT acted on: **lane 1 is faster
than the shipping default** — 3.3 vs 24.6 ms p50 on loopback, 45.4 vs 62.6 at
RTT 80/1% loss (t = 15.7, n=3). RESOLVED, and the answer inverts. The
first loss numbers were void: every timecode-fixture frame is a single 1100 B
fragment (`fragsSent == framesEncoded`, unchanged at `qp=10`), so lane 1's
parity never fired (`paritySent 0`). `testbed/mktimecode.mjs` rebuilds the pair
over real camera footage - same bar, same 256 frames, 13.7 fragments/frame,
`paritySent` 1591. On those frames lane 1 COLLAPSES: 1% loss gives 1638 ms p50 /
12.9% delivered / `skipBuffered` 747, and 5% loss gives no picture at all, while
lane 2 holds 65.3 ms / 100% and 114.8 ms / 98.4%. That is SCTP congestion
control, invisible on 1 KB frames. The 17 ms carrier hop is the price of a
transport that survives loss, not shavable overhead - the shipping default is
right and the lane question is closed. Reference envelope, from Microsoft's
published Teams/Skype thresholds at the 90th percentile: 0.5% average loss,
5% burst.

Testbed: `competitor.mjs` gained `--rtt/--loss/--jitter/--bw` (candidate-rewrite
delay line lifted from `call.mjs`), a `cov %` delivery column, NaN-hostile flag
parsing, and an abort if either side rewrote no candidates. `ab.mjs` gained
`NET=` passthrough. New: `flip-lane1.mjs`, `flip-carrier.mjs`.

Still blocked and not mine to clear: competitor accounts (Meet/Zoom/WhatsApp/
FaceTime), two-person human validation, Cloudflare beacon (`task_600a3d58`),
the real relay rate `r`, `style-src 'unsafe-inline'`, and the flip button's own
`enumerateDevices` path (fake-device browsers expose one camera).

### Lane 2's ~17 ms is the carrier trick, not a setting

Nine levers off one at a time (`avoff`, `avsync`, `vprev`, `sendnow`, `l2fec`,
`l2retx`, `l2pace`, `l2rc`, `l2canvas`) — none is where the time goes.
`sendnow=1` re-run properly is a null (22.0 vs 22.2 ms, t = 0.16, n=4).
`avsync=0` costs **+41 ms**, so A/V sync pulls video forward rather than
delaying it; the 20 ms `AV_OFFSET` is not a latency tax and zeroing it does not
help. Transport age (post-encode → ready-to-decode, both lanes, synced clock):
lane 2 **17.2 ms** vs lane 1 **−0.1 ms**, which matches the 18.3 ms
glass-to-glass gap within ~1 ms. The cost is the carrier hop itself:
main→worker, wait for a tick, splice, pacer, wire, depacketizer, worker→main.

Ways out, all needing the unmeasured real loss rate: raise the tick rate above
60/s (~8 ms mean wait → ~4 ms, paid in discarded carrier frames); drop the
carrier and accept lane 1's delivery under loss; or pick the lane from measured
loss. `testbed/lane-age.mjs`.

### Loss-condition measurement discipline (2026-08-02)

`testbed/mktimecode.mjs` builds `camcode720{,b}.y4m` — the 11-cell timecode bar
over real camera footage, 13.7 fragments/frame vs the old fixture's 1.0. Pass
`--fixture=camcode720` to `competitor.mjs` for anything touching fragmentation,
FEC, buffering or loss. `ab.mjs` now reports a delivered% column alongside
p50/p95, and takes `NET=` for shared network flags.

The ±1.7 ms spread is clean-path only. Under RTT 80 / 5% loss the same
unchanged arm gives p50 66.9 +/- 5.7 and p95 109.2 +/- 30.5, and single runs of
it ranged 59-114.8 ms. A lever scan at n=1 under loss resolves nothing: an arm
that appeared to beat the default on both latency and delivery (`l2retx=0`) was
noise at n=4 (t = -1.07). The one surviving result is that `l2fec=0` costs ~22
points of delivered frames at 5% loss, so lane 2's FEC is load-bearing.

RESOLVED, and it was the wrong question. `--rtt=80` with loss OFF already costs
+45 ms over loopback against a 40 ms delay line, so the "loss latency" was mostly
propagation. But the rig was lying about the rest: both y4m fixtures are 256
frames, Chrome loops them, and `competitor.mjs` deduped on the raw timecode index
-- so every run reported only its first 8.5 seconds, and `cov` was a ratio of two
Sets that saturate at 256. Fixed by unwrapping with the period derived from the
data (hardcoding 512 made the fix silently inert; 255 -> 0 is not a backward jump
of more than 256).

With that fixed, the real finding: **latency ratchets under loss.** p50 by third
of a 30 s run at RTT 80 / 5% loss is 66.1 -> 81.1 -> 97.5 ms, +31.4 ms and not
recovering, with delivery 84.3% rather than the ~99% the saturated metric
reported. Both clean paths are flat (loopback 21.0/21.4/21.8, RTT 80 clean
69.7/69.4/68.8), which rules out propagation and the rig.

Mechanism candidate: `armHoldDeadline()` dumps the whole hold buffer on expiry
(~8-10 frames each), `fecHoldExpired` fired in half of runs, and `fecUnrepairable`
was 0 throughout -- the repairs run out of clock, they do not fail. Raising
`?l2hold=400` does NOT help (n=6, t = 0.71 on delivery), though that A/B predates
the rig fix and is worth redoing.

Also fixed in shipping code: both lanes computed transport age as
`now() - (wall + (stats.clockOffsetMs ?? 0))`, and the offset starts null, so
pre-ping samples compared two unrelated performance.now() origins and fed the
AIMD controller clock skew. Guarded in both lanes; deployed as 81e57018.

## Session 2026-08-03: the ratchet, and three broken instruments

**Shipped.** `81e57018` guards both lanes' transport-age sampling against a null
clock offset (it was subtracting the peer's performance.now() origin and feeding
the AIMD controller the result). `21e42360` raises the default `AV_OFFSET` from
20 to 45 ms.

**The AV_OFFSET change is the day's real result.** Video is paced to the PCM
audio playhead; that playhead's depth goes 12.4 -> 135.2 ms at 5% loss (41% of
audio concealed, so the depth is earned), and video is towed out with it.
Lip-sync perception is asymmetric -- BT.1359 puts detectability at ~45 ms for
audio ahead of video but ~125 ms for audio behind -- and the old default left
that second band unspent. Measured n=3/arm: settled latency 133.5 +/- 7.2 ->
108.3 +/- 7.3 ms, t = 4.26. Self-gating: on a clean link the applied offset does
not move at either setting, because there is no slack to spend until the buffer
has grown.

**Three instrument bugs, all found by a bound being violated.** (1) Both y4m
fixtures are 256 frames and Chrome loops them, so `competitor.mjs` -- which
deduped on the raw timecode index -- reported only the first 8.5 s of every run
ever measured, and `cov` saturated toward 100%. (2) The transport-age percentile
compared two unrelated clock origins. (3) The first unwrap fix hardcoded 512 and
was silently inert. The rig now prints `timecode: N-frame loop, K wraps` and
`p50 by third of run`, and `ab.mjs` runs Welch's t on delivery as well as
latency.

**Still open.** The ratchet is reduced, not gone (+15 to +33 ms at 5% loss).
`fecHoldExpired` dumps ~8-10 frames per expiry and fires in about half of runs.
Delivery under loss is 89%, and 41% audio concealment disqualifies "lossless"
under loss. No competitor measurement exists; no two humans have used this.

**Method note worth keeping.** The v-presenter hypothesis had servo numbers that
matched the prediction exactly (clean shift -3, loss shift 0) and would have
justified a code change -- to a path that had presented 16 frames in 90 seconds.
What killed it was `presents`, a counter nobody was interested in, sitting in the
same output line. Print the volume next to the ratio.

## Session 2026-08-03b: the 1-in-8 collapse, found and closed

**The collapse was a shed the peer was never told to end.** §13's VIDEO HELD is
a two-party state — the receiver sends `shed`, the sender stops admitting
captures, and only the receiver's `resume` restarts it. The receiver's exit test
accepted any keyframe with `id > shedMaxId`, and `shedMaxId` is its own
`lastDecoded`, so every frame already in flight when the shed landed qualified.
One in-flight keyframe and the receiver went nominal *without sending a resume*;
`exitProbe()` only runs while held, so it never sent one afterwards. The peer's
video stayed off for the rest of the call, with no error on either side. The
comment above that line already said "the fresh **post-resume** keyframe" —
post-resume was never checked. Intermittent because it needs a keyframe to be in
flight at that instant.

Fixed in `tape.js`: the held-exit requires `resumeSentAt >= shedAt`; a stale
in-flight key is counted (`shedStaleKey`) and skipped; if we have resumed and
only deltas arrive the post-resume key was lost, so `requestKey('post-resume')`
asks again. Plus a sender-side dead-man (`stallShedMaxMs`, 8 s): anything that
disables our own output on a peer's say-so needs a local timeout, because the
peer may reload, be on a stale bundle, or simply be wrong. Live as `17283f97`.

**Reproduce with a capacity ceiling, never with loss:** `--bw=4` and
`--bw=2.5 --rtt=80 --fixture=camcode720`. That hit it twice in one batch, in
both directions. At bw=2.5 the pre-fix run gave the harness **9 matched samples**
in 90 s (`B framesOut 35`); post-fix, 1276-2249. Four post-fix runs: `shedSent`
always has a matching `resume`, no side ends `shedded`, holds are the 4 s
minimum rather than the 60 s `stallMaxHoldMs` hatch.

**A bandwidth ceiling had never actually been tested.** Two faults, both making a
constrained link look healthy: `--bw` is in **Mbps** (`--bw=1500` asks for 1500
Mbps, and the honest `netsim:` line saying so is easy to lose to a grep), and
with the units right `timecode720` still cannot fill a 1.5 Mbps pipe because it
compresses to ~0.26 Mbps. So the entire §12/§13 apparatus built for constrained
links — classifier, lane P, AIMD governor — had only ever run unconstrained.
Keep `netsim:` in every grep.

**The dead-man was demonstrated by accident.** One verification run had A on a
cached pre-fix bundle and B on the fix — the real mixed-version case. A did the
old stale-key exit and stranded B; B recovered itself after 8 s
(`shedDeadman 1`, `skipShed 240` not 2155, `framesEncoded 2619` not 808).

**Instrument caveat that nearly became a claim.** Post-fix normal-path runs read
72.0 ms at 5% loss (97.1% delivered, flat thirds) and 26.9 ms clean (98%) —
better than this file's previous 79.5/59.7. Not attributable to the fix: the
stall machine never engaged in those runs. Glass-to-glass carries a CPU-bound
presentation term, and absolute figures drift by tens of ms with machine state
across a long session — always in the flattering direction for the later run.
Compare only within one quiet session, or use interleaved `ab.mjs`.

**Still open.** p95 variance under loss; 41% audio concealment under loss;
`fecHoldExpired`; delivery short of 100%. No competitor measurement (account
creation is prohibited); no two humans have ever used this.

## Next: audio is not lossless under loss, and it is one byte count

Measured this session, not yet fixed. The PCM frame is 384 samples × int24 =
1152 B + 24 B header = **1176 B**, and it does not fit one datagram. At RTT 80 /
5% loss the emulator dropped **5.56%** of datagrams with `sendErrors 0`, while
**13.4%** of audio frames never arrived (B sent 12686, A got 10982; sender
`skipBuffered` ~110, so it did send them). A message split across k datagrams
dies if any piece does: 1 − (1 − 0.0556)^k = 13.4% at k ≈ 2.4. Counted directly,
23,346 audio messages of 1176 B went out in 60 s but only 16,666 datagrams
≥1100 B were carried.

That is the whole explanation for 36–41% concealment. RS(10,13) leaves ~0.3% of
groups unrepairable at 5.6% and ~8% at 13.4%, and `fecFailed` is the largest term
in the accounting. The FEC is sized correctly for the link; the framing hands it
a channel 2.4× worse. The video lane already fragments at 1100 B — audio sits
76 B over the line. Clean-path audio is genuinely bit-exact (`concealedMs 8`), so
this is specifically a loss-path defect.

Fix direction, in preference order: (1) lossless compression of the frame —
linear prediction + Rice takes 30–50% off 24-bit speech, fits one datagram,
cuts the lane's 1.52 Mbps, and keeps "truly lossless" literally true; (2) a
smaller frame (320 samples → 984 B), simpler but 384 and the 8 ms unit are
hardcoded across the SAB ring and both worklets. **Measure the real usable
payload first** — k ≈ 2.4 suggests the limit is well under 1100 B on these three
striped associations, which would change the answer.

**Two counter sets the rig had never read**, both of which existed all along:
the PCM FEC accounting (`fecRepaired`/`fecRepairedLate`/`fecFailed`/`late`, and
`captureFrames` vs `framesSent` vs `framesRecv`), and the **emulator's own**
`dropped`/`bwDropped`/`sendErrors`/`unreachable`. The latter now prints on every
run as `netsim actual:` with a HARNESS LOSS warning above 0.5%. It is what
exonerated the harness here and made the 13.4% attributable to framing — an
application counter can never tell an injected drop from an emulator one.

**The budget is now measured: 1160 B.** `testbed/mtuprobe.mjs` (new) wires two
peer connections through the same UDP proxy the loss tests use, sends 150
messages per size, and reads the proxy's packet-size histogram — the answer comes
from the emulator, not from the application. One datagram up to **1160 B**, two
from **1162 B**, ~77 B DTLS/SCTP overhead per datagram. The PCM frame is over by
exactly **16 bytes**. Note `sctp.maxMessageSize` is 262144 and says nothing about
fragmentation; and the baseline is ~1.5 datagrams/message rather than 1.0 because
SACKs share the path, so the tell is the 1.5 -> 3.0 step.

Trimming the header cannot reach it: demoting both f64s (`wall`, `capUs`) to u32
saves 8 of the needed 16, so 1160 requires an 8-byte header — deriving both from
`seq` (`capUs = base + seq * 8000`, base sent once on ctl). Exact, but a
wire-format change and an `age` semantics change, both sides together. And 1160
was measured on a 1500 B path, so a VPN or a 1400 PMTU puts us back over. Hence
the durable fix is lossless compression of the frame (linear prediction + Rice,
30-50% off 24-bit speech): clears the budget at any plausible PMTU, cuts 1.52
Mbps by a third, keeps bit-exactness.

Two harness traps worth knowing for any future probe: Chrome publishes host
candidates as mDNS `.local` names unless launched with
`--disable-features=WebRtcHideLocalIpsWithMdns`, and spreading an
`RTCIceCandidate` (`{...cand}`) copies NOTHING because its fields are on the
prototype — that silently drops `sdpMid`/`sdpMLineIndex` and every
`addIceCandidate` fails.

## Session 2026-08-03c: audio under loss, both causes, fixed and deployed

Concealment at 5% loss **36–41% → 2.5–4.3%**; at 10% loss **60–76% → 4–10%**.
Clean path unchanged (0.0% concealed). Two defects in series, and the first was
large enough to hide the second.

**Cause 1 — the 16 bytes (fixed, shipped).** Compact framing: the data header's
bytes 1–3 were written as zero and never read, so a data frame is now
`type`(1)+`seq`(4) = 5 B → **1157 B**; parity reads only idx/bitmap/base, so 8 B
→ **1160 B**. Both f64s moved to a 21 B `T_ANCH` at 4×/s. `capUs` extrapolates
exactly (8000 µs/seq — the mechanism `capUsFor()` already used for FEC-repaired
frames); `wall` becomes time-since-ideal-capture. The anchor is the
**least-delayed** frame of each window (min `wall − seq×8`), not the latest —
the receiver derives ~31 frames from one anchor and would otherwise smear that
one frame's main-thread jitter across all of them. RS untouched (parity covers
payload only). `?pcmc=0` is the control arm; the receiver reads both formats.
Effect on its own: frame loss 13.5% → 10.0%, `fecFailed` 5393 → 3260.

**Cause 2 — the lane is bigger than one SCTP association (fixed by config).**
10.0% is still not the link's 5.6%, and the rest is not framing. Holding size at
1157 B and varying only *rate* on one association at RTT 80 / 5% loss:

| offered | loss | peak bufferedAmount |
|---|---:|---:|
| 25 msg/s (0.23 Mbps) | 7.0% | 1,157 |
| 42 msg/s (0.39 Mbps) | 8.0% | 3,471 |
| 59 msg/s (0.54 Mbps) | **12.6%** | **120,717** |
| 83 msg/s (0.77 Mbps) | 38.0% | 297,386 |

The congestion window is **per association**; `MSS×1.22/(RTT×√p)` is ~0.67 Mbps
at MSS 1234 / RTT 80 / p=0.05, and the lane offers 1.95 Mbps (1.5 + 30% FEC),
which over 3 associations is 0.65 Mbps each — exactly on the ceiling.
`?pcmpairs=N` is the lever and already existed:

| loss | pairs 3 | pairs 5 | pairs 6 | pairs 8 |
|---|---|---|---|---|
| 0% conceal | 0.0% | — | 0.0% | — |
| 5% conceal | 27.0/25.2% | 4.3/1.6% | 3.1/2.7% | 2.5/2.5% |
| 5% frames missing | 10.0% | 6.7% | 5.8% | 6.0% |
| 10% conceal | **76.5/60.2%** | — | 9.6/4.1% | — |

At 10% loss `pairs=3` cannot even drain its own sender (`framesSent` 8143 of
10327 captured, bufferedAmount 16 KB / 57 KB). **`pcmpairs` default is now 6**
(deployed `eafbce0f`). No clean-path cost is measurable: video latency 62.2±2.1
vs 64.3±1.2 ms over 4 interleaved reps (t=1.80, not distinguishable), and a
first reading of jitter depth 12.9 → 17.8 ms did not replicate (12.3/12.2 at
N=6 on the shipped default) — that was run noise, withdrawn. The safety code is
unaffected: both `RTCPeerConnection` sites pass `certArg()`, so all seven pcs
per side share the one call certificate.

**Both fixes are load-bearing.** The 2×2 at `pairs=6` says the framing change is
not made redundant by the wider stripe — concealment 6.5/6.7/7.3/7.0% legacy
against 2.5/1.2/2.9/1.1% compact at 5% loss, and 18.3/12.3% against 7.9/5.4% at
10%. Audio frame loss at `pairs=6` is 10.9% legacy against 5.9% compact, exactly
the two-datagram versus one-datagram prediction, and legacy offers ~30% more
datagrams for the same call. **A/V sync did not regress** when `capUs` moved onto
the anchor — `avDrops 0` everywhere, `avOffP50` 50.8/63.7 compact against
66.8/66.4 legacy. The extrapolation is exact, not approximate, because
`onset-monitor.js` constructs the `AudioContext` with an explicit
`sampleRate: 48000`, making 384 samples exactly 8 ms.

**Shipped defaults verified end to end** (no overrides): `bPerFrame 1157`,
concealment 0.0% clean / 3.3%-0.5% at 5% / 9.0%-10.0% at 10%, `avDrops 0`.

**Harness changes.** `testbed/mtuprobe.mjs` now measures **message survival** at a
known link loss (`--loss`, `--sizes`, `--n`, `--gap`) instead of counting
datagrams — on a live call the proxy histogram mixes SRTP, STUN, SACKs and every
association into one bucket and attributes to nothing. It prints `maxBuf` per row
because it twice measured its own backpressure and reported it as path loss: 80%
at every size when blasting 1250 msg/s, 40–58% at 125 msg/s. The sender now
reports `bPerFrame` / `bPerParity` off its own byte counters, so "deployed" and
"1157 B on this call" are separate, checkable claims.

## Session 2026-08-03d: lossless frame compression (shipped, `fd6ac0e6`)

`tape-app/public/core/pcmpack.js` — FLAC's core and deliberately only that:
fixed-order linear prediction (orders 0–4, no coefficients on the wire),
partitioned Rice (4 partitions of 96), warm-up samples as 24-bit literals, and a
verbatim escape that BOUNDS the payload at 1153 B — so the worst frame is
5 + 1153 = 1158 B and still inside the 1160 B single-datagram budget.

**Measured live, `?pcmz=0` as the control arm, 60 s per arm at RTT 80:**

| | zip off | zip on |
|---|---:|---:|
| bytes per data frame | 1157 | **709–714** |
| lane rate | 1.50 Mbps | **1.06 Mbps** |
| conceal, 0% loss | 0.0% | 0.0% |
| conceal, 5% loss | 3.2 / 1.5% | 2.1 / 2.1% |
| conceal, 10% loss | 8.2 / 8.1% | **5.7 / 3.5%** |
| `fecFailed`, 10% loss | 939 / 1035 | 672 / 373 |

`avDrops 0` in every arm; glass-to-glass 64–67 ms across all of them (noise).

**Offline proof** (`testbed/pcmpack-test.mjs`, `node` only, ~2 s): 6,851 frames
round-tripped and compared SAMPLE BY SAMPLE, 0 failures — real audio plus
adversarial cases (silence, ±full-scale DC, alternating extremes, impulse, ramp,
step, full-scale sine, white noise at both full scale and LSB). Ratios: speech
0.557, natural sound 0.675, tonal 0.620, white noise 0.957 (incompressible by
construction — lag-1 autocorrelation 0.001 — and the floor, not a failure).
Encode 25 µs/frame = 0.32% of a core at 125 fps; decode 6.6 µs.

**Two traps, both caught by measurement rather than reasoning:**
1. The dither arm of `testbed/pcmpack.mjs` came back byte-identical to the
   undithered one, which is impossible. Cause: an LCG written in doubles —
   `rng * 1103515245` exceeds 2^53, so the product's low bits are unrepresentable
   zeros and `& 0x7fffffff` collapses the sequence. Use xorshift32 via
   `Math.imul`-style int ops. (The finding survived: with a working generator the
   ratio moves <0.3%, because Rice already spends its low k bits verbatim. So the
   ratio does NOT depend on the source being genuinely 24-bit.)
2. First codec version measured 0.88 on speech and sent a perfect *ramp* to the
   verbatim escape. Cause: one Rice k for the whole frame, and the first `order`
   samples have no predecessors, so their residual IS the raw sample — two such
   samples forced k≈23 onto all 384. Warm-up literals + partitioned k took speech
   0.88 → 0.56 and ramp 1153 B → 106 B.

**RS is untouched.** Compressed payloads are zero-padded to a fixed 1152 B symbol
for the group only; parity messages are byte-identical to before. A repaired
frame comes back as 1152 B with NO length field anywhere on the wire, and that
works only because Rice decoding self-terminates after exactly 384 samples — the
test asserts this path explicitly (313 padded frames, 0 mismatches), because if
it ever broke, audio would decode to plausible garbage rather than error.
`g.zip` is tracked PER GROUP, not per module, so a repaired frame is read the way
its own group's members arrived.

**Next, and now the biggest single term:** parity is 32% of the lane's bytes
(2712 × 1160 B against 9037 × 714 B). Shrinking the RS symbol from a fixed 1152
to the group's max compressed length (~850 B) is worth roughly another 8% of
total rate. It needs RS to run at group close rather than incrementally, since
the max is not known until then.

## Session 2026-08-03e: group-sized RS symbols (shipped, `45b344fe`)

Compression made parity the lane's biggest term: at ~714 B per data frame the
fixed 1152 B RS symbol meant 2712 × 1160 B of parity against 9037 × 714 B of
data — **32% of all bytes**, roughly 38% of it zero padding. The symbol is now
the group's own longest compressed frame.

**Measured, live:** `bPerParity` 1160 → **725–736 B**, lane **1.06 → 0.92–0.94
Mbps**, clean path still 0.0% conceal and `avDrops 0`.

**The concealment claim is a NULL and is recorded as one.** Interleaved A/B
against `?pcmrsfixed=1` at 10% loss (n=5 / n=4): 9.78 ± 1.99% vs 9.71 ± 2.90%,
t = 0.04. A second A/B under a 2 Mbps cap agreed (t = 0.06, though the rig lost
2 of 5 reps in one arm and that run is weak). Why it is the right answer: at
`pcmpairs=6` the lane offers ~0.18 Mbps per association against a ~0.28 Mbps
ceiling at 10% loss — already under the wall, so the saved rate had nothing to
buy. **This is a cost and headroom win, not a quality win.** Do not let it get
quoted as one.

**Design notes for whoever touches this next.**
- The symbol length is on the wire ONLY as the length of the parity message.
  Data frames are stored at natural length and padded in `maybeResolve()`, not
  at receive time — the group's length is not knowable when its first frames
  land.
- RS can no longer accumulate incrementally, since the max is not known until
  close. Zero latency cost: parity was already emitted at close (on the first
  frame of the next group). ~30 µs of concentrated field work per 80 ms.
- Ceiling is `1160 − HDR_PAR_C` = 1152 B, so parity still never fragments. The
  codec's verbatim escape is 1153 B and cannot fit; such a frame is EXCLUDED
  from its group (bitmap bit clear = "never contributed", the existing
  sender-drop path) rather than allowed to fragment all three parity messages.
  Fires on 0 of 6,827 real frames — white noise only. Counter: `rsOversize`.
- A contributing member longer than the symbol is impossible by construction, so
  `fecSymMismatch` counts disagreements about the group, not losses, and the
  decode is REFUSED rather than guessed at. Solving anyway would XOR the wrong
  bytes out and hand the concealer confident garbage.

**New/changed harnesses.**
- `testbed/pcmrs-group.mjs` — NEW. Full sender→loss→receiver path on real audio:
  769 groups, 1,355 repairs, **0 wrong**, 185 groups that lost their longest
  member (only the parity knows the size), 963 exact-fit members. Fails if it
  did not hit those cases, so it cannot pass by not running.
- `testbed/pcmpack-test.mjs` — **had a silent hole**: it resolved fixtures from
  `cwd`, so run from the repo root every real-audio case was skipped by a bare
  `catch {}` and it still printed "0 failures". Now resolves from the script and
  treats an empty corpus as a failure.
- `testbed/ab.mjs` — now passes `--dump` and extracts audio conceal + bPerParity,
  with a Welch t on conceal. It was blind to lane A entirely.
- `testbed/competitor.mjs` — `pcmsend` prints `rsOversize`, `pcmfec` prints
  `fecSymMismatch`.

## Session 2026-08-03f: jitter target measures instead of guessing (shipped, `c10c0f6d`)

The `/goal`'s "erase zoom fatigue" clause, attacked on the axis FATIGUE.md
already defined: the turn-gap proxy, `2 x (ageP50 + depthMs)`, and how much it
MOVES. New harness `testbed/fatigue.mjs` reports it as a trajectory through a
mid-call loss burst (15 s clean / 30 s at 5% / clean), ~90 s per run.

**What it found in the shipped build:** the old jitter target grew one frame per
concealment and shrank one frame per 4 s — 24 ms/s up against 2 ms/s down, a
12:1 ratchet — and the proxy peaked TEN SECONDS AFTER the network healed, then
never recovered inside the run. The conceptual error: concealment has two causes
and buffering only cures one. A LATE frame says "you needed this many more ms";
a LOST frame says nothing, because waiting does not produce a packet that is not
coming.

**Replacement:** target = `secondLargest(d) - min(d)` over 320 frames, where
`d = now() - seq*FRAME_MS` for every frame that becomes available. No clock sync
(the offset cancels). Losses contribute no sample. FEC repairs contribute at
repair time, which is correct. Up immediately, down at 1 frame/s.

**Measured against its own control (`?pcmjit=0`, identical build, one flag):**
clean baseline 117 vs 116 ms; peak under loss 230 vs 229 ms; **45 s after the
network healed, +1 ms vs +89 ms**; recovery **27 s vs never**; wander after
recovery **28 vs 72 ms**; concealment 1.07% vs 1.07%. Same protection during the
event, same peak, and the latency comes back. Not a quality-for-latency trade.
Clean path, n=4 interleaved (`testbed/ab.mjs`): conceal 0.05 +/- 0.06% vs
0.01 +/- 0.03%, t = 1.19, NOT distinguishable — an earlier n=1 reading of 0.2%
looked like a regression and was not one.

**Sanity check worth keeping:** at 5% loss the estimator reports p99 spread
76–84 ms while p90 stays at 4.3 ms. That is the RS(10,13) span (10 x 8 ms) —
the estimator independently rediscovered our own FEC latency. If that number
ever stops matching the RS span, either the estimator or the FEC has changed.

**THE TRAP, and it produced a flattering result.** The first version stored `d`
in a `Float32Array`. `d` is a wall-clock epoch around 1.75e12; Float32 has ~7
decimal digits and ~131072 spacing up there, so every sample rounded to the SAME
float and the spread was **exactly 0.0**. The estimator was blind, the target
never left its floor, and the run reported "latency perfectly flat through 5%
loss" — which reads as a triumph and was deployed for one version before the
diagnostics caught it. `jitSpreadMs/jitP90Ms/jitP99Ms/jitMaxMs/jitWant/jitN` are
now published for exactly this reason.

**Also fixed here:** `P2P_REWRITE` was duplicated by hand into the new harness
and the copy silently did not work (it hooked only `setRemoteDescription`, but
this app trickles candidates, and it rewrote the IP instead of the port). It is
now one shared module, `testbed/p2p-rewrite.mjs`, imported by both. The zero-
rewrite guard is what caught it; anything subtler would have reported loopback
numbers under an "80 ms" heading.

**Still open on fatigue:** video has no equivalent drift-over-time run; the
Bailenson face-size remedy still has no citable target; no competitor
turn-gap comparison (account creation is prohibited, so this stays blocked).

## Session 2026-08-03g: the video half of the fatigue metric

FATIGUE.md's first "Not done" item — video had a glass-to-glass rig but no
drift-over-time run — is now closed. `competitor.mjs` gained `--burst=on,off`
`--burstLoss=N` (loss injected for a window INSIDE the recording) and reports
p50 per **10 s window** next to frames decoded. A run without `--burst` sleeps
exactly as before.

**Sustained 5% loss, 90 s:** p50 by window 66.8 / 66.3 / 66.3 / 61.6 / 66.7 /
66.5 / 62.6 / 65.8 / 66.2. Thirds 66.4 -> 65.8 -> 65.2. **Flat — no ratchet.**

**30 s burst inside a 90 s call:** peak **+7 ms** (70.2 against a 63 ms
baseline), back to baseline within one window. Delivery is what moves: frames
decoded 287 -> 235 -> 284. Same with `?pcmjit=0`, so the audio buffer is not
towing video latency.

**Corrects an earlier finding.** The recorded video ratchet (66 -> 81 -> 97 ms
across 30 s at 5% loss) does NOT reproduce, over a span three times as long.
Most plausible cause is Lane A's rate falling 1.5 -> 0.92 Mbps across the
compression and parity work, removing contention with lane 1 — not isolated, so
it is an observation, not a mechanism.

**Still blocked, and it needs the user, not more engineering:** competitor
benchmarking. The rig measures ANY service from a join link by pixels alone and
needs no cooperation from it — but CREATING a Meet/Zoom meeting requires an
account, and account creation and credential entry are prohibited. One join link
per service, pasted in, unblocks the entire comparison immediately.

## Session 2026-08-03h: the code rate stops being a constant (shipped, `9080820c`)

User redirected: competitor benchmarking is a launch-time task, not now — the
standing goal is exploiting the available physics on the real pain points.

**Diagnosis.** RS(10,13) applied 30% redundancy to every link, and both ends of
that were wrong. Clean: 1577 parity packets, **zero** repairs, ~0.30 Mbps —
a third of the audio lane buying nothing. 20% loss: `fecFailed 1415`, conceal
26.1% — the 23.1% erasure tolerance exhausted regardless. Matching code rate to
the channel is textbook, and we were not doing it.

**Shipped.** A loss-driven ladder (n = 0/1/2/3 at 0 / ≤1.5% / ≤4% / >4%, each
rung the smallest whose binomial group-failure rate stays near 1%). Entirely
**sender-local**: `rsDecode()` already needs only `pr.length >= erasures`, so
fewer symbols is indistinguishable from parity lost in flight — no negotiation,
no audio wire change. Feedback is a 3-B `T_LOSS` datagram 4×/s travelling
opposite to the audio it describes. Loss is read off the **data sequence**, not
the group bitmap: the bitmap is only set by arriving parity, so at n=0 it is
zero forever and that ladder could never climb back out. Control `?pcmfecadapt=0`,
plus `?pcmfecmin=` / `?pcmfecmax=` to pin a rung.

**Result (interleaved `ab.mjs`, n=4/arm).** Clean lane **0.730 vs 0.925 Mbps,
−21.1%, zero spread in both arms** — derived, not sampled. Conceal t = −0.63,
delivery t = 0.61: nothing else moved. At sustained 10% loss both arms sit at
n=3 and are byte-identical, so there is no regression to find.

**The honest cost.** clean→burst→clean runs ~**+0.2 pp** concealment (3.1% vs
2.9%): the ladder starts at n=0 and needs about a second to believe a burst.
Never reached t ≥ 2.5 in any single A/B (2.40, 1.75, 1.69) but the same sign and
size in all three. **Two obvious cures were built and both failed** — a fast
512 ms raise-only window (reaction 1.5 s → 0.9 s) moved it the WRONG way, +0.21
→ +0.25 pp; a floor of n=1, which repairs isolated loss with zero reaction time,
gave +0.17 pp for 0.035 Mbps more. Reaction time was never the constraint. Do
not retry either.

**Two instruments lied, both caught by their own counters.** `onMessage` opened
with `data.byteLength < 9` — right when the smallest type was a 9-B ping, fatal
for a 2-B report. The first deployed build printed `fecN 3/3, up 0, down 0`,
identical to a link that never needed to adapt; only having `lossPct` and
`peerLossPct` as SEPARATE counters localised it. And `ab.mjs` scored the
0.195 Mbps clean-link win as `t = 0.00, do not claim a winner`, because Welch
divides by a pooled error of zero — now reported as `EXACT, not statistical`.

**Corrects a recorded number.** "1.9% conceal at 10% loss" was a lucky n=1 run;
eight interleaved runs say 4.5–6.0%.

**Next on this lane:** `fecRepairedLate` (161–224) now rivals `fecRepaired`
(161–478). Over half the RS repairs arrive too late to play — that is a bigger
prize than anything left in the code rate. `skipBuffered` was 0 on all six
associations throughout, so sender backpressure is not implicated below 10%.

## Session 2026-08-03i: the RS span is a latency term (measured, NOT shipped)

`?pcmrsk=` is a test flag; the default is unchanged at K=10 and production
behaviour is untouched (`cfg.rsK == null` never calls `setRsK`).

**`fecRepairedLate` had grown to rival `fecRepaired`** — a third of successful
RS decodes discarded because the playhead had already passed. Parity cannot
exist until its group closes, so position 0 waits `RS_K × 8` = 80 ms while
position 9 waits 8 ms. Predicted a monotonic gradient; found one, in both
directions: 63/69/58/47/48/29/26/13/4/**0** percent late by position.

**Halving the span (K=5, n≤2) halves the waste** — late fraction 34% → 15%,
worst position 69% → 32%, mean late 29 → 16 ms. And the finding that matters
more: **jitter buffer depth 104–109 → 56–58 ms.** The measured jitter target
sizes itself from arrival spread, and repaired frames are part of that spread,
so an 80 ms RS span was inflating our own playout latency by ~48 ms under loss.
The span was designed as a repair-deadline term; it is also a latency term.

**The per-5 s columns confirm the mechanism and clear the two objections.**
Settled during the burst, the measured jitter p99 arrival spread is **~49 ms at
K=5 and ~91 ms at K=10** — `span + ~10 ms` in both arms, so the estimator is
measuring the RS span and nothing else is that size. Target follows: 7–8 frames
vs 12–14. Concealment events over the burst 324 vs 547; late frames 117 vs 370.

- *Why the gap proxy saw only 12 ms:* `gapAdded` uses **achieved** depth, and
  under loss depth is ratchet-driven, not target-driven — 20→68 (K=5) and 16→66
  (K=10), two curves a few ms apart. Neither arm reaches its target in a 30 s
  burst. K=10 asks 104 ms, gets 66, so it pays latency it never receives and
  still conceals 68% more late frames. The 40 s sustained runs *do* reach steady
  state, hence 56 vs 104 there. 12 ms was the right answer, not an anomaly.
- *Why the clean baseline looked worse:* K=5's clean depth alternates
  22/13/20/12/20 — an 8 ms flip, exactly `FRAME_MS`, doubled to ~17 ms by the
  proxy's 2×. Quantisation between holding 2 and 3 frames, the floor of what the
  buffer can express. Not a latency cost.
- *Understated in K=10's favour:* its true peak is **249 ms at t=55, five
  seconds after loss stops**; the harness reports 227 because its peak window
  closes at the loss boundary. K=5 peaks 218 at t=50 and is at 190 by t=55.

**Still not shipped.** Concealment −1.41 pp at t = −1.80 has not cleared the
2.5 bar; K=5 costs **+9% lane** under loss; and **both peers must agree on
RS_K** (the receiver derives groups from `seq % RS_K`, so a mismatch groups
different frames together rather than degrading) — that needs a migration story.

`setRsK()` rebuilds the Cauchy matrix; verified bit-exact at K=5/8/10/16 over
800 groups, junk inputs leave RS_K at 10.

## Session 2026-08-03j: the ladder was tuned for a group size we do not use

**K=6 n=2 was a dominated config and the criterion that picked it was wrong.**
The ladder chose rungs by group-FAILURE RATE — smallest n with
`P(Bin(K+n, p) > n)` near 1%. That counts a failed group of 5 the same as a
failed group of 10, though the first conceals half as much speech. The right
criterion is expected concealed FRAMES per frame. Re-derived:

| | n=1 up to | n=2 up to | n=3 up to |
|---|---:|---:|---:|
| shipped (hand-tuned) | 1.5% | 4.0% | — |
| correct for K=10 | **1.02%** | **2.78%** | 5.03% |
| correct for K=5 | 1.43% | 4.21% | 7.76% |

**The shipped pair is the K=5 ladder running on a K=10 codec** — 2.1× over the
0.1-per-100 concealment target at the top of the n=1 rung, 2.8× at the top of
n=2; avoidable 0.19 pp at p=1.5% and 0.23 pp at p=4%.

`pcm.js` now derives `rungTop[]` from `RS_K` at stream start (~40 binomial
evals per rung, once) instead of carrying constants, so the ladder cannot go
stale against its own block size again. New stats: `rsK`, `rsSpanMs`,
`fecRungTop`. `testbed/kchoice.mjs` prints the same table and is the source of
the target; the in-app derivation is verified against it at K=5/6/8/10/12/16
plus monotonicity, `clean → n=0`, saturation at `RS_P`, and that K=5 reproduces
the old 1.5/4 exactly. Offline suites green (`pcmrs-group`, `pcmpack-test`,
`rsk`, `protocol-check` — its one STALE line is the pre-existing 1080p badge).

**It also reinterpreted data already on disk.** K=5 n=2 is coding-EQUAL to
K=10 n=3 (1.14 vs 1.11 concealed per 100), so the earlier K=5 A/B had isolated
the **span effect with coding held constant** — its −1.41 pp was not a weak
mixed result, it was a clean measurement of one variable. And K=6 n=2 is 35%
*worse* than shipped; three reps measured +0.60 pp against a predicted +0.39
before it was killed. Run `kchoice.mjs` before booking rig time.

**DEPLOYED** as version `8702e8ba`; served `pcm.js` sha256 == tree, and the
derived rungs were then read back off a live call rather than trusted from
source: `--self --dump` at 3% loss prints `pcmrsk: K 10 span 80ms rungTop
[0.1, 1.02, 2.78, 5.03]` on both sides. That readback exists because `fecN`
alone cannot tell a correct ladder from one still holding stale constants —
the same blind spot that hid the dead T_LOSS dispatcher for a whole build.
Still unmeasured end-to-end: the predicted 0.19 pp at p=1.5%. To validate,
A/B `pcmfecmax=1` (old behaviour) vs default at 1.5% loss.

## Session 2026-08-03k: the audio win is paid for in video

**K=5 n=3 vs shipped, n=8/arm, 10% loss, uncapped:**

| | K=5 n=3 | K=10 n=3 | |
|---|---:|---:|---|
| audio conceal | **2.97 ± 0.79%** | 5.61 ± 0.91% | −2.64 pp, **t = −6.21** |
| video delivered | 89.8 ± 1.1% | **91.3 ± 1.1%** | −1.54 pp, **t = −2.73** |
| latency p50 | 66.2 | 64.8 | t = 0.57 |
| audio lane | 1.140 Mbps | **0.925** | +23%, exact |

Concealment beat prediction (−2.64 vs −2.26), the strongest confirmation the
span mechanism has. **But `cov` is VIDEO delivery and it moved significantly
the other way.** Dose-response is clean: n=2 (+9% lane) gave delivery +1.48 pp,
n=3 (+23%) gives −1.54. More audio parity, less video delivered — the
`latency-needs-a-delivery-column` trap in a new costume.

Mechanism NOT established. No `--bw` cap, so not bandwidth competition; encode
cost is identical at either K (3 accumulations/frame either way). What differs
is parity PACKET rate, 0.6/frame vs 0.3/frame. Per-packet send overhead and the
emulator's own per-packet cost are both open. An uncapped link *understates*
this, so the next run shapes it.

**K=5 n=2 on a SHAPED link is the result that matters** (n=8/7, 10% loss,
`--bw=2.5`):

| | K=5 n=2 | K=10 n=3 | |
|---|---:|---:|---|
| audio conceal | **3.26 ± 0.73%** | 6.53 ± 0.38% | −3.27 pp, **t = −11.03** |
| video delivered | **91.4 ± 1.1%** | 90.6 ± 1.7% | +0.76, t = 1.01 |
| latency p50 | 65.2 | 64.2 | t = 0.48 |
| audio lane | 1.010 | **0.925** | +9%, exact |

Every K=5 rep (2.35–4.60%) beat every K=10 rep (5.90–7.05%) across 15 runs —
zero overlap, a stronger statement than the t. Delivery does not regress.

**Read the RATIO, not the difference.** The same config measured −1.41 pp in an
earlier session and −3.27 here. The whole gap is the CONTROL arm: K=5 held at
3.45 → 3.26% while K=10 drifted 4.86 → 6.53% at nominally identical settings.
Interleaving makes each run's comparison valid; it does not make absolute levels
comparable across sessions. As a ratio K=5 is 0.71 / 0.50 / 0.53 of K=10 across
three runs — consistently about half.

**A pacing explanation for that gap was written and then withdrawn.** It rested
on `--bw=2.5` shaping the link, which had never been verified. `bwDropped`
counts only queue OVERFLOW, so it reads 0 both on a link that queues constantly
and on one that never shaped. Queue delay tells the truth: at `--bw=2.5`,
31,883 packets took the queue path but p50 0 / p95 0 / max 30.2 ms, no drops —
the cap binds on bursts only and the sustained rate never approaches it (same
shape at 1.0 and 0.8). `competitor.mjs` now prints `bwQueue: queued N / p50 /
p95 / max`, warns `shaper NEVER BOUND` below max 5 ms, and otherwise says when
it binds in bursts only. **Every capped-link claim in this file predates that
instrument.**

`ab.mjs` also now parses `bwDropped` / `sendErrors` per arm into a `rig` line.
The K=5 n=3 vs n=2 run has it (both arms 0.00%); the two earlier runs predate
it, so their zero-overlap separation is what carries them.

**At K=5 the third parity buys nothing measurable:** n=3 vs n=2, n=8/arm,
conceal 3.31 ± 0.87 vs 3.67 ± 1.17, difference −0.36 at **t = −0.69** against a
predicted −0.88. So prefer n=2 and its 0.13 Mbps saving. **Do not act on the
`cov` column here** — it has now produced two significant results in opposite
directions for same-signed changes (K5n3 worse than K10n3 at t = −2.73; K5n3
better than K5n2 at t = 2.72, i.e. more audio parity delivering more video,
which has no mechanism). Its per-rep spread is 1.1–1.7 pp, the size of the
claims. Treat ~1 pp `cov` moves as noise.

**Gate on shipping is no longer measurement, it is peer agreement** (task #17).
The receiver derives groups from `seq % RS_K`, so a rolling deploy putting a
K=5 sender against a K=10 receiver corrupts grouping rather than degrading.
`startPcm()` is called inside the welcome handler, so the SECOND joiner can
negotiate at init but the FIRST cannot — it learns the peer's build only at
`peer-joined`, after its own `initPcmAudio`. Solvable because no frames flow
until ICE completes; needs a pre-first-frame reconfigure in pcm.js.

**Also open:** the derived ladder picks **n=3** at K=5 for 10% loss — the arm
that cost video uncapped. The ladder's objective is audio-only and has no term
for what parity bytes take from the other lane.

## Session 2026-08-03l: K=5 dies on a constrained link — block size is a dead end

`--bw=0.3` is what actually constrains this app (p95 58.7 ms of queue, 0.68%
overflow, cov 69%). Re-run there, n=8/arm, 10% loss:

| | K=5 n=2 | K=10 n=3 (shipped) | |
|---|---:|---:|---|
| latency p50 | 99.0 ± 6.5 ms | **83.1 ± 6.6** | **+15.9 ms, t = 4.83 WORSE** |
| video delivered | 68.1 ± 6.6% | **74.6 ± 5.6** | −6.49 pp, t = −2.13 |
| audio conceal | 11.96 ± 3.43% | 12.17 ± 3.22% | −0.21, **t = −0.12, gone** |
| audio lane | 1.008 Mbps | **0.925** | +9%, exact |
| rig `bwDropped` | 0.83 ± 0.06% | **0.55 ± 0.17%** | K=5 overflows more |

**The concealment win was an artifact of free bandwidth.** With slack, the
shorter span halves concealment; without slack the same config returns nothing
and charges 16 ms of latency. The rig counters name the mechanism: K=5 offers
9% more and drives 50% more queue overflow, so its own parity pushes the shaper
past its limit and everything behind that queue — video included — waits.

**K=5 is not shippable at any n. Default stays K=10 and `?pcmrsk=` stays a test
flag.** Tasks #14 and #17 are closed.

**What survives, and it is the useful part.** The span mechanism is real: RS
span shows up one-for-one in the measured jitter spread (`span + ~10 ms`), which
sets the buffer target, because repaired frames are part of the spread the
estimator measures. Block size is a latency term, not only a repair-deadline
term. It just cannot be *bought with redundancy*, because redundancy is exactly
what a constrained link has none of. The only remaining path is to stop tying
repair delay to block size — a sliding-window code (task #16) emits parity every
frame covering the last W, so the first repair for a frame arrives ~1 frame
later instead of up to K, at whatever rate you choose. That is now the priority.

**Harness defect found, and it invalidated three earlier A/Bs.** netsim's bucket
is keyed on `address:port` — one per SOURCE PORT, not per client. Lane A stripes
across 6 data PCs plus the media PC, so each browser draws ~7 buckets and the
effective ceiling is ~7× the flag. Runs at `--bw=2.5` believed the lanes
competed for 2.5 Mbps; they competed for ~17. Appeared silently when `pcmpairs`
went 3 → 6. Documented at the `bwMbps` definition in `netsim.mjs`.

**Also seen, not yet fixed:** every rep printed
`ERR_SOCKET_DGRAM_NOT_RUNNING` from `netsim.mjs:290`/`:300` — a delayed
`setTimeout` send firing after the socket closed at teardown. It happens after
the result line, so no rep was lost and all 8 counted in both arms, but it
crashes the netsim process on the way out and should be guarded.

## Session 2026-08-11 — the live-only marathon: 7 multipliers, 5 surfaces, the realism law

New machine (deveshpatel; earningsgpt is gone — testbed paths were de-hardcoded,
node/gh/ffmpeg installed per-user, wrangler OAuth re-authed, LOG_ADMIN_TOKEN
rotated again: scratchpad log_admin_token.txt). Operator rules now in Claude's
persistent memory: live-prod-calls-only testing, features default ON (?flag=0
control), Claude orchestrates + agy(gemini-3.6-flash-high)/opus workers code,
REAL talking-head media everywhere (never synthetic artifacts), never subagents
except one sanctioned Opus 5 Max worker used sparingly.

**Shipped, all live-verified:** presence stereo room renderer (presence-core.js,
default on) · AEC2 default on + DO-NO-HARM GATE (delivery only at ERLE>=3 dB —
iOS froze at -13 dB shadow without it) · burst shield (frame twins 24 ms apart
above the parity ladder; two false-trigger bugs found live) · video duress
coupling (pcm.duress() quarters the budget when the audio ladder reads trouble) ·
WS pre-dial from the lobby (second joiner 565->347 ms, -39%; hold-state admission
in the Room DO) · latency floor default (mouth-to-ear 62.6->45.6 ms; the first
A/B was Bluetooth-confounded — the retry is in onset-monitor.js comments) ·
embed UNBROKEN (frame-ancestors 'none' had blanked it since it shipped;
now '*', X-Frame-Options gone, embed-call.mjs holds the line).

**Instruments:** mouthToEarMs + glassToGlassMs + humanGapMs per call, on the
anonymous beat, aggregated in /api/health/summary. The #14 present probe was
silent on the real present paths (v-presenter, avTick) — both stamp now.

**iOS Simulator is a first-class surface** (Xcode installed, iPhone 17 Pro
'tokkah-iphone'; DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer).
It found: the pre-dial timeout lie (adopted-OPEN sockets never fire onopen),
the AEC2 freeze, and page suspension on backgrounding -> shipped 'away'
presence (peer sees 'they switched apps'). ?synthmedia=real plays
/testmedia/real720.mp4 through the test hook for engines without fake-device
flags.

**Testbed realism:** media/real/fetch.sh reproduces NASA-interview fixtures;
all rigs default to them (decodeURIComponent the paths — the repo dir has a
space). aec-call's auto arm now asserts NO false latch on real speech (the
beep-periodicity fake-echo premise died with realism).

**Deploy ritual:** env -u CLOUDFLARE_API_TOKEN npx -y wrangler@4.120.1 deploy
-c wrangler.prod.jsonc (local node_modules wrangler 4.86.0 errors mutely);
md5-settle 3 consecutive; edge POPs can lag each other (a sim fetched a
one-deploy-stale bundle minutes after settle).

**Waiting on the real world:** speakerphone call (AEC2 gate-open + echo-detect
real trigger), ears on presence, a bad network for the shield. ~35 commits
local-only: user deprioritized GitHub push (gh authed as deveshpat, which
lacks repo perms — owner is deshmukhpatel98).

## Session 2026-08-11 (later) — the interpreter ships, three-person exists, voices get seats

**One-line interpreter (LIVE on prod):** `<script src=.../embed.js data-room=x
data-translate=es>` opens the embedded call with the live interpreter (embed.js
forwards to ?xlate=). Metered FIRST-CLASS: worker.ts xlateMeter charges 600 s
grains vs XLATE_DAY_SECONDS/room/UTC-day (default 7200, '0' disables); over
budget the socket is ACCEPTED, sends {type:'limit'} (xlate.js renders it as a
caption), then closes. Proven live both ways (prod attribute flow; staging cap=1
visible refusal).

**Three-person rooms (BUILT, dormant, prod-safe):** all six design phases landed
(testbed/specs/three-person-design.md). Prod serves the full client with
THREE_ENABLED=false in worker.ts — verified inert live (3rd join refused, 1:1
byte-clean). Staging (wrangler.jsonc → tokkah.deshmukh.workers.dev) is where the
flag goes true for testing: perl-flip the const, deploy -c wrangler.jsonc,
REVERT THE SOURCE IMMEDIATELY. testbed/call3.mjs is the gate: nine assertions +
4b (per-half FLOW — connection state cannot see a silent voice), ALL PASS.
Mesh uplink MEASURED 10.6-11.7 Mbps/device (half the design's guess): phones are
not bandwidth-limited; CPU/thermal needs a REAL phone. Bugs the staging gate
caught (all fixed): b<->c pair never formed (answerer built lazily, racing its
own setup - both roles now build eagerly); 4th joiner hung on 'starting…' (full
message raced the spent join-promise rejector - UI driven directly now); DO
teardown double-fired on abrupt drop broadcasting a fieldless peer-left that
cleared survivors' tables (idempotency guard).

**Spatial voices (LIVE dormant):** presence-core placement — azimuthDeg via
Woodworth ITD + <=2.2 dB broadband ILD (lossless; NO pinna filtering); az 0 IS
the original loop (1:1 bit-identical). addPeer seats voice 2 at +28 deg;
?spatial=0 pins center. Proven on staging 3-way; the 'silent second voice'
scare was a still-priming snapshot, disproven by per-half flow discriminators.

**Still gated on the human:** prod THREE_ENABLED flip (costs: worst-link-
governs, translation-off-at-3, per-peer telemetry — needs explicit yes); real
phone (mesh thermal + speakerphone AEC2/echo real-air verdicts); ears on
presence/spatial; GitHub push (~65 commits local; gh authed as deveshpat which
lacks perms — owner is deshmukhpatel98).

## Session 2026-08-11 (final arc) — the echo campaign, driven by the first real calls

The user's first real calls arrived (rooms eqx-oxuk-wnq, tgv-glvl-ppd,
xow-offc-apz — two Macs one room apart). Verdict on record: beats Google Meet;
competition is a real room. Their echo report + telemetry drove the arc:

- ECHO OBSERVABILITY (end beat + fleet summary): echoCorrMax, aecGateOpenPct,
  aecGateFlips, aecErleMaxDb, aecDtPct — all zero-latency accumulations of
  numbers the audio thread already ships. DEVICE CENSUS on the connect beat:
  cores/mem/downlink/rtt/camWxH@fps/dpr, coarse buckets.
- duress() latches (35 flaps in a real call), gate close is two-tier (instant
  on proven harm < -2 dB — the live rig caught my own dwell delivering -6.6 dB;
  dwell only in the ambiguous band).
- THE SHADOW FILTER (core/aec-core.js, Opus 5 Max worker): background adapts
  every block at full mu (corruption harmless — never delivered), foreground
  only inherits on proof (bg>=3 dB and bg-fg>=3 dB, 1 s cooldown; instant
  rescue on fg harm), delivery gate unchanged. DT leak/freeze gone from
  adaptation; DTD survives as dtPct only. Six arms pass, DT arm near-corr
  1.0000 / post-DT 64.8 dB; cost 1.09x. Escape valve rewired (shadow restarts
  when it can't earn a promotion against a mispredicting fg for 6 s).
- Bleed pre-flight learning: moderate bleed fine, equal-level erodes single
  filters; the DTD-poisoning theory did NOT reproduce synthetically — the
  field dtPct discriminates between theories on the next same-room call.

THE DECISIVE EXPERIMENT (waiting): one more call, same room, same Macs.
Read aecGateOpenPct (was effectively 0), dtPct (theory pick), copies
(promotions = shadow at work). Staging resynced to HEAD flag-off.
