# Changelog

Notable changes to Tokkah. Dates are the day the change landed on `main`.

This project measures its claims; where a change has a number, the number is here.

## Unreleased

### Licensing and openness
- **Relicensed to GNU AGPL v3** with a commercial license alongside it
  ([LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md)). Versions published before
  commit `6375ae4` remain MIT-licensed permanently.
- Added [OPENNESS.md](OPENNESS.md) — a self-graded scorecard of how usable this
  project is by a stranger, with the command that proves each row.
- Added `CONTRIBUTING.md` (DCO + licensing grant), `CODE_OF_CONDUCT.md`
  (Contributor Covenant 2.1), `SUPPORT.md`, `NOTICE`, issue and PR templates,
  `CODEOWNERS`, `.editorconfig`, and CI.

### Fixed — the documented install was broken for everyone
- `tape-app/node_modules` was a **committed symlink** pointing outside the repo;
  it landed broken in every clone. Removed (same for `fatigue-lab/node_modules`).
- `npm install` failed with `ERESOLVE` on a clean clone: `@cloudflare/workers-types`
  was pinned to `^4` while wrangler required `^5`. Dependencies aligned.
- Added `tape-app/package-lock.json` so `npm ci` installs exact, reproducible
  versions — the same command CI runs.
- Verified end to end from a fresh `git clone`: `npm ci` → 0 errors, then
  `wrangler deploy --dry-run` → builds, both Durable Object bindings resolve.

### Fixed
- A malformed room path returned a bodyless 404, which Safari treated as a **file
  download** instead of a page. Document 404s now redirect to the front door.

### Added
- **Hold-to-peek self-view**: a face button that shows your own camera only while
  held, and hides it on release. No persistent mirror — chronic self-view is among
  the largest measured drivers of video-call fatigue.
- **Call telemetry** (anonymous, zero added latency): device tier, tracker type,
  tracker coverage and cadence, alongside the existing echo and latency panels.
  This immediately showed Safari running the face tracker at ~15–19 Hz where
  Chrome ran at 30 — tuning had been done against the wrong engine.
- Operator-only `/api/health/recent` for reading raw beats during debugging.

### Changed
- The presence-window work (head-coupled parallax, peekaboo out-of-view state,
  liveness gate, low-end tracker tier) is **parked behind flags** (`?window=1`,
  `?frame=1`) rather than shipped on. It is built and live-verified, but it did
  not clear the quality bar in [testbed/specs/presence-2.0-plan.md](testbed/specs/presence-2.0-plan.md).
  With the flags off, no tracker bytes are fetched and no transform is applied.
- CSP `script-src` gained `'wasm-unsafe-eval'` for the self-hosted face tracker
  (WebAssembly only; the binaries still must come from `'self'`).
- Vendored MediaPipe binaries (26 MB) are no longer in the repository;
  `tape-app/public/vendor/fetch.sh` reproduces them.

## Kin 0.68.0 — 2026-08-26

### Added
- **Kin notices when both people are in the same room, and stops playing you
  out of two speakers at once.** Reported as "a lot of echo… only one mic is
  active at a time, so that was very confusing" — and it was never a canceller
  fault. Two Macs in one room means the far end's voice comes out of the OTHER
  machine's loudspeaker, which no echo canceller can reach. The signature it
  looks for cannot happen on a real call: **the microphone hears them before the
  network delivers them.** Calibrated before it was wired
  (`tk --sameroom-test`): a remote call scores 0.385–0.426 and one room scores
  0.792–0.901, on two independent sources — a margin of **0.376**. It requires 8
  agreeing estimates out of 20 to act and 2 to release, decides once, and holds
  through people talking over each other.
  [mac/tools/sameroom-check.sh](mac/tools/sameroom-check.sh), 33 assertions,
  including 20 estimates AFTER the speaker goes off — a detector whose evidence
  its own fix destroys is an oscillation, not a feature. `--no-sameroom` is the
  control arm.
- **A thin green line at the edge of the window while your voice is actually
  reaching the other person.** 1.5 pt, steady, no glow — measured 4–20 pt inside
  the stroke at −4.81 against −4.94 at rest, so nothing bleeds inward: it is a
  line, not a light. Dark when muted, dark while the gate is holding you, and
  dark when the OTHER person has the floor — that last one is the control arm,
  because a border that lit for them would say the opposite of the truth. It
  arrives at the instant the gate opens, which is the point: someone interrupting
  is told they are through rather than guessing.
- **A turn-end prior**, from the transcript Kin already produces for subtitles.
  Measured against the reactive rule that ships today, at the same instant and
  the same cost: **false handovers 52% → 12%**, catching 39% of turn ends early.
  Biased that way deliberately — a false "they have finished" arms the gate under
  somebody mid-sentence, and a miss costs a beat the reactive gate still
  recovers. Not yet connected to the gate.
  [mac/tools/predict-check.sh](mac/tools/predict-check.sh).

### Fixed
- **A first install that was refused its name gave up for good.** Asked the
  server for a handle, got `429 {"error":"rate"}`, and stopped — for the rest of
  that launch nobody could call that person and the app never said so. A laptop
  opened before Wi-Fi associates did the same thing, and that is the ordinary way
  this app starts. One condition was answering two questions: "may I take a
  different name" and "should I ask for this one again". It retries the same name
  now, honours the server's own hint, keeps trying for the life of the process,
  and the People panel says which of the three things went wrong in plain words.
- **And pressing Call between two attempts said there was no name.** The wait
  ended the moment the ladder went idle, which after the change above means
  "between passes" rather than "given up". It waits out the caller's budget and
  drives an attempt itself.
- **A warning could kill the app.** `setWarning` was the only setter on the
  control row that did not hop to the main thread, and it touches `NSView` state
  three ways. Every release so far has been one non-empty warning off the main
  thread away from aborting; it survived on a guard that returns early when
  clearing something already clear.
- **Two sentences fought over one warning line and the controls never faded
  again.** "their camera is off" and "you're in the same room" were written by
  two independent owners, once a second each, overwriting each other 150 times in
  one call — and every overwrite re-showed the control row and re-armed its
  stillness timer. The precedence is written down once now, in one place.
- **The breathing rim around the whole window is gone**, along with the dots that
  swelled on the picture. Measured at the window edge, it lit up 6.4× when the
  far end took the floor. Whose turn it is lives in the microphone button's own
  ink instead — full, dimmer, dimmest — with no glow, ring or pulse.
- **Subtitles appear in 33 ms instead of 400**, at full height instead of growing
  into place, and the dead second caption line is gone.
- **The updater failed silently in five different ways at once.** An unreachable
  server, a missing signature, a signature that did not verify, an unparseable
  manifest and "already up to date" were one indistinguishable `return nil`. Each
  says what happened now, and the ones a person can act on reach the window.
  A Mac that cannot write to its own copy of Kin stops re-downloading the release
  forever and says why. `install.sh` no longer moves a new binary over a working
  one before checking it runs — the old one did, **and exited 0 while doing it**.
  [mac/tools/update-check.sh](mac/tools/update-check.sh), 44 → 79 assertions.
- Every `--*-test` run took UDP 7001 before reaching the test, so a test on a Mac
  with a call in progress failed on a bind. They take any free port now.

### Changed
- A rig that could only `stat` the video it needs now reads a byte of it, and a
  turn-end verdict that could not decide a speaker says so on the verdict line
  rather than thirty lines above it.

## Kin 0.67.0 — 2026-08-26

### Added
- **A call ends when somebody hangs up, and at no other time.** Quit Kin
  mid-call, let it crash, let the updater restart it — reopen and you are back
  in the same call, with the same person, without either of you doing anything.
  The call is a fact on disk (`call.json`), and the only thing that deletes it is
  a hang-up at one of the two ends. The far side sees *"they'll be right back"*
  rather than a departure, holds the room, and keeps its lease alive.
  [mac/tools/leave-check.sh](mac/tools/leave-check.sh) now has two endings — a
  kill and a real hang-up — because held and *"the departure detector is dead"*
  draw the identical screen, and one rig ending could be satisfied by either.
- **Crashes report themselves.** If Kin dies on somebody else's Mac we hear
  about it without them filing anything: the next launch finds the report,
  summarises it, and sends it with the call record. 29 assertions in
  [mac/tools/crash-check.sh](mac/tools/crash-check.sh).

### Fixed
- **Two updaters could install an app with 3–9% of its files missing.** Measured
  in 4 of 6 runs, and the dropped tail was `_CodeSignature/` — which is what
  macOS pins camera and microphone grants to, so the visible symptom would have
  been an app that suddenly asks for permissions again and cannot be given them.
  The updater now has a rig of its own: 44 assertions in
  [mac/tools/update-check.sh](mac/tools/update-check.sh).
- **Subtitles are for a voice that cannot be heard, and appear once.** They went
  on the wire whether or not the microphone was muted, the far end drew them, and
  the near end drew them again — so two captions could share one screen, and the
  person shown their own words was the only one in the call who already knew what
  they had said. The decision is the sender's now, because the sender is the only
  end that knows whether its microphone is off, and a voice ducked by the echo or
  turn-taking gate counts as unheard too. Nothing new on the wire, and nothing
  sent at all in the ordinary case.
- **Nothing describes somebody who is not there.** Three things had not moved
  with the change above. A held peer was still being measured, so *"they'll be
  right back"* appeared beside a frozen *"23 ms — breaking up"*. The controls
  stayed faded through a hold, leaving a frozen frame, a pill, and no hang-up
  button anywhere. And `describeTree` pasted the clipboard in raw, so a copied
  URL containing a newline split the diagnostic line and made three healthy runs
  report broken subtitles.
- **The picture comes back with the voice, not a second after it.**

### Changed
- A rig that could only `stat` the picture it needs now reads a byte of it.
  During a machine-level permission outage, `stat` kept working while `open()`
  did not, so two picture rigs ran against a file the app could not read and
  produced 17 failing assertions that all read as product regressions.
- The release's dead-flag gate stopped reading its own comments as flag names.

## Kin 0.66.0 — 2026-08-26

### Changed
- **Transparent glass, and nothing painted on the person.** Every surface is
  `NSGlassEffectView` in its clear style rather than a frosted material, and the
  vignette and every other effect over the video are gone. 32 assertions in
  [mac/tools/glass-check.sh](mac/tools/glass-check.sh), including calibration of
  the instruments themselves against known-blurred and known-opaque references.

### Added
- **Calling someone writes them down.** A person you called appears in your
  people list, not only a person who answered you — and only their name is
  stored. 26 assertions in
  [mac/tools/contacts-check.sh](mac/tools/contacts-check.sh).

## Kin 0.65.0 — 2026-08-25

### Added
- **During a call the window becomes the other person.** Every control fades
  away, subtitles stay, and any input brings the controls back for a few seconds.
  32 assertions in [mac/tools/immersive-check.sh](mac/tools/immersive-check.sh).
- **One click that lands on the pane, not on System Settings.** Each permission
  Kin needs opens the exact panel that grants it. 28 assertions in
  [mac/tools/permissions-check.sh](mac/tools/permissions-check.sh).
- **A Mac that is always on keeps itself current.** The background watcher checks
  for a newer Kin on its own, so a machine nobody opens still updates. The call
  to start that polling sat about 350 lines below a function that returns
  `Never`, so it had never once run.

### Fixed
- **A cancel that arrives while the app is still starting** no longer leaves a
  ring on screen with nobody behind it.
- **The ring card stopped claiming a face it had not seen.** The counter said a
  picture had arrived when what had actually happened was that the card opened.
- The download pages describe the app that exists.

## Kin 0.64.0 — 2026-08-25

### Added — a ring you can see
- **A Mac that is being rung shows you the caller's picture before you answer.**
  It joins the room and receives, so the card that asks the question also shows
  the face behind it. Receive-only, and that is three separate guarantees: no
  microphone is opened, so there is nothing to send and no green
  light; no camera is opened, so there is no picture of this room; and the audio
  engine is never started, so the caller's voice arrives and is never played.
  [mac/tools/preanswer-check.sh](mac/tools/preanswer-check.sh) asserts all three
  on real processes — `cap 0/s` and `played 0/s` in *every* report the ringing
  copy makes, and no `camera: bring-up` line at all — alongside the new
  assertion that their stream did arrive and did reach the screen.
  `TK_RING_PREVIEW=0` turns it off.
- **The caller is told that packets arriving are not an answer.** New status bit
  `Wire.ST_RINGING`, set before the first probe goes out rather than on the
  first tick of the report loop. Arrival from an address has always meant "they
  are here" in this app, and that reading is what let a ring answer itself in
  0.61.0; the caller's card now stays on `Calling`, its window says *"they are
  being asked — not connected yet"*, and its microphone is zeroed rather than
  sent into a room nobody has agreed to open. A build older than the bit never
  sends one — and those never joined before answering — so an unheard status
  byte is treated as answered after about two seconds.
- Known trade-off, and it is not closed here: the Mac being rung joins the
  rendezvous before its owner has agreed to anything, so the caller learns its
  address before anybody answers. [RINGING.md](RINGING.md) names that leak and
  the mitigation it wants — connect early only for rings whose key is already a
  contact — which this change does not implement.

### Fixed
- **`--mute` silenced the call and left the ringtone playing.** Reported by the
  person whose Mac the rigs run on, while they were watching something. Every rig
  passes `--mute`, and `--mute` only ever silenced playout, because the ringtone
  is a separate `AVAudioPlayer` that was never asked. `--mute`, `TK_MUTE=1` and
  `TK_NO_RAISE=1` now silence the ring and stop it asking for attention.
- **The third camera bring-up had no gate.** Two of them have been gated on
  `ringPending` since 0.61.0. This one never needed a gate, because the ring
  parked above it and the line was unreachable — so the moment a ring was
  allowed to fall through and receive, the camera light came on next to somebody
  who had agreed to nothing. Caught on the first rig run: `camera: bring-up
  95 ms` inside an unanswered ring.

### Changed
- **The analytics can now name why a call never happened**, not just how one
  sounded. Every ending writes one `outcome` — *talked*, *no answer*,
  *cancelled*, *declined*, *being asked*, *could not ring them* — and beside it:
  the route taken (straight to them, or through a relay), whether this Mac can
  be rung while Kin is closed **and why not**, microphone and camera permission,
  the doorbell's own answers broken out by class (ok / refused / rate-limited /
  unreachable / error), rings dropped as malformed or unverified, and clicks the
  ring card refused. `/macos/calls` reads them as plain-word verdicts — *"this
  Mac cannot be rung when Kin is closed"*, *"the doorbell refused this Mac"*,
  *"the microphone was never allowed"* — rather than leaving the reader to
  notice a missing counter.
- Rig windows now sit on the desktop layer and are `.stationary`. Corner
  placement and click-through, added in 0.63.0, still left a 1280×720 window
  appearing over whatever the person at this Mac was watching, once per launch.

## Kin 0.63.0 — 2026-08-25

### Added
- **"Calls when Kin is closed" is a row in the panel now, with the one thing
  that fixes it underneath.** Being reachable with the app shut was already
  automatic — an installed copy writes its own login item on every launch — and
  then it did not work on a second Mac, and there was no way to find that out
  from inside the app. The only report was `--watch-status`, in a terminal,
  saying *"plist present, launchd running"*. Tapping the row turns it on, or
  moves Kin somewhere it can be turned on, or opens the exact Login Items panel
  where macOS is refusing. Three outcomes, no dead ends.

### Fixed
- **`Watch.install` required `/Applications` and nothing else**, while `Install`
  treats `~/Applications` as installed and never relocates a copy there. On a
  Mac where `/Applications` was not writable, Kin settled into the home folder
  and then silently never got a login item at all — which is exactly the symptom
  that was reported. Both are stable targets at login now.
- **A third test for a click nobody aimed**, because the first two kept missing
  real ones while the rigs ran. A trackpad tap landed 4.5 s after the card
  appeared with the pointer having moved — past both existing tests — and was
  still nobody's decision, because the pointer had been sitting where that pill
  landed the whole time. The card now asks whether the pointer travelled to the
  button or the button travelled to the pointer, answered two ways: hover age,
  and a plain geometric test of where the pointer was when the card took the
  screen. `TK_AIM_MS` is the rig override, and `preanswer-check` asserts the
  pair that must rank differently — the same gesture refused when it looks like
  a stray, and going through when it comes from the harness.

### Changed
- **Rigs stopped taking the screen.** Every windowed rig runs with
  `TK_NO_RAISE=1`: the ringer does not throw the window in front, the
  ring-pending copy does not activate, the window sits in a corner, and
  `ignoresMouseEvents` sends real clicks straight through to whatever is behind.
  Before this, five of five rigs failed whenever somebody used the Mac while
  they ran, and passed when nobody did.

## Kin 0.62.0 — 2026-08-25

### Added
- **Cancel and decline are a message now, not a wait. 346 ms on production**,
  from the press to the other Mac having it. Reported after a real call, in
  these words: *"when I cancelled the call it did not get instantly notified to
  the person who was calling, and just kept showing calling forever."* That was
  true and nothing was broken — there was no un-ring to send, so the ring sat in
  its mailbox for the 60 s lease while the caller's card rang out its 45 s. A
  bye is the same signed envelope with `kind: "bye"` on it, through the same
  doorbell, waking the same held poll:
  - it signs its **own** domain, `kin-bye-v1|…`. Every Kin ever shipped verifies
    a polled ring against the ring string, so a bye it has never heard of fails
    verification and is dropped — falling back to the timeout, which is what it
    did before byes existed. Sharing the domain would have had an old client
    draw a card for a call nobody is on.
  - it is matched on `from` **and** `room` before it changes anything, so a
    stranger who knows a handle can post signed byes all day and every one lands
    and is ignored.
  - it is metered on its own rate windows, at the same limits, never the ring's.
    Every window on `/ring` exists to bound *disturbance*, and a bye makes no
    sound and draws no card; charging it would halve an honest caller's hourly
    budget while a flooder, who never sends one, keeps all sixty.
  - it ignores silent mode, because the one person guaranteed to be staring at a
    "Calling…" card is someone who silenced their own Mac and then placed a call.
  - a cancel that arrives before the callee's first poll **replaces** the ring in
    the mailbox, so that Mac never rings at all.
  - [mac/tools/bye-check.sh](mac/tools/bye-check.sh): 13 assertions on real
    processes with real keys against the real server, both directions plus the
    wrong-room control — the case a client that tore down on any bye at all
    would fail while passing the other three.

### Fixed
- **A ring window was taking people's clicks**, and had been answering calls
  with them. Caught in the act while four rigs ran and somebody was using this
  Mac: real trackpad taps — non-zero event numbers, subtype 3, one of them a
  double-click — landing on a card that had just thrown itself in front of what
  that person was doing. One unattributed auto-answer had already been seen
  during testing and written off as a mystery — this is what it was.
  Three defences, none of which is the other's fallback: `answer`,
  `decline`, `cancel` and `call again` refuse `acceptsFirstMouse`, so a click
  that merely brings Kin forward cannot join a room; a consequential press
  within one second of the card appearing, or with a pointer that has not moved
  since, is ignored and says so; and every one of these presses now logs where
  it came from — event number, click count, pressure, subtype — because
  `currentEvent` alone could not tell a finger from a leftover, which is why the
  first sighting went unexplained.

---

Earlier history predates this changelog. `MEASURED.md` is the running lab
notebook and covers that period in far more detail, including the experiments
that failed.
