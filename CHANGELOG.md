# Changelog

Notable changes to Kin, and to the Tokkah worker behind it. Dates are the day
the change landed on `main`.

This project measures its claims; where a change has a number, the number is here.

## Kin 0.88.0 — 2026-08-31

### Fixed — macOS killed the background watcher once after every update

Every self-update filed exactly one crash report: `EXC_CRASH (SIGKILL (Code
Signature Invalid))`, `Termination: CODESIGNING, Launch Constraint Violation`,
67 ms after launch, parent `launchd`. KeepAlive retried and the second attempt
worked, so the Mac always ended up current — which is why it survived four
releases. "Recovers on its own" and "nobody has looked" draw the same graph.

Reproduced on a real machine, and the first two theories were both wrong:

| what was done | result |
| --- | --- |
| kill the watcher, no swap | relaunches cleanly |
| swap in a **byte-identical** copy, then kill | relaunches cleanly |
| swap in a validly signed copy with a **different cdhash**, then kill | **refused, once** |

So it is neither a race nor the swap. launchd holds a job to the code identity
it was *bootstrapped* with, and the first launch of a different one at that path
is refused. The designated requirement never changes — `identifier
"com.tokkah.tk" and certificate root = H"…"` — but the cdhash moves every
release, and that is what is pinned.

`Watch.reregister()` now tells launchd rather than letting it find out. The
ordering is the whole risk: the updating process *is* the job, so a bootout
kills it before it could bootstrap, and a bootout never followed by one leaves a
Mac unable to answer a call until the next login. The work is handed to a
detached `sh` that outlives it; every path through that script ends in a
bootstrap attempt, verified with `launchctl print`, retried five times, with
`kickstart -k` as a last resort so no Mac is left with no job at all.

## Kin 0.86.0 — 2026-08-31

### Changed — Kin checks for a new version when you open it, restart, or start a call

A cadence is a guess about when somebody will next care. The moments they
actually care about are knowable, and they are also the moments a stale build
shows, because the far end of the call is running a different one.

- **on open** — at once, rather than ten seconds later
- **on restart** — the watcher's first check was 60 s ("no hurry at login"),
  true at login and wrong every other time it starts: after an update, after a
  crash, whenever the binary moves underneath it. Two seconds now
- **on a call** — when the far end actually arrives. Not a licence to restart:
  anything found is held until the call ends and said on screen

The ten-second launch grace was never about the network. It existed because a
call is not "live" during setup, so an update found immediately would restart
the app while somebody was still reading their invite link. That wait moved onto
the *install*, which is what it was always protecting.

**And one thing this broke, caught by the rig.** "Urgent" meant two things, and
the second is about a person: the Check for Updates menu item is owed an answer
whatever happens, including "could not reach the server". Reading "a person
asked" off that flag was true while the menu was the only thing setting it — and
the moment opening the app checked too, every launch on a flaky network put
"couldn't check for updates" on somebody's status line.

## Kin 0.85.0 — 2026-08-31

### Fixed — hanging up ended the call *and* closed Kin

`leaveCall` was `exit(0)`, from when a call and a process were the same thing.
Closing the window had already stopped meaning "hang up"; this was the other
half of that correction, left behind. What stays on screen afterwards is the
screen Kin opens with — a fresh room, waiting, with its link — because that is
this app's idle state; a double-click starts a call.

### Changed — Macs pick up a new version in five minutes, not thirty

The update poll was 1800 s. The second Mac in the house sat on 0.82.0 while the
first ran 0.84.0, reported as "the update mechanism is not working". It was
working, half an hour behind — and half an hour behind is indistinguishable from
broken to the person waiting, especially when two Macs on one call disagree
about what the app does. Note that the poller doing the work is the version
already installed, so a cadence change takes effect one release later.

## Kin 0.84.0 — 2026-08-30

### Fixed — a microphone five times too loud, which was causing the echo *and* the cut-off voices

Reported as two problems — an echo across different rooms, and one person's
continuous speech being chopped up. One fault. From the call's own telemetry,
both ends:

| | mic peak | clipping | RMS | echo peak | mic open | gate flaps |
| --- | --- | --- | --- | --- | --- | --- |
| one end | **5.24** | 1.6% | 0.263 | 0.71 | 98% | 56 |
| other end | 0.85 | 0% | 0.031 | 0.52 | 90% | **409** |

Full scale is 1.0. `tuneInputGain` saw peaks of 1.40 and 1.03, walked the device
from 27% to 15%, and stopped: 15% was the floor written into it. It moved twice
in two minutes and never said it had given up.

A microphone that hot hears its own speaker — the loop is inside one laptop,
speaker about 15 cm from microphone, so being in different rooms does not help —
and it holds the local voice gate open, so the near mic is live while the far
person is talking, and their end chops its way through hundreds of gate flaps
trying to take a turn against it.

- the back-off is proportional to the overshoot now, not a fixed step
- a software trim at capture, which no hardware floor can block, decided
  *before* every device guard — it used to sit below them, so a microphone with
  no settable volume, the case that needs it most, could never reach it
- samples above 1.0 are not clipped: the float path carries them intact, so
  dividing recovers the signal exactly, with no limiter and no colour
- it comes back up when the room quietens, or one shout would be permanent

### Added — the floor's own numbers, and echo as a peak

`floor: yours N%` is named for the floor and does not measure it: it counts the
local voice gate. `one-at-a-time:` now prints on every call what share of it the
floor actually muted the microphone, and what share it had fallen back to the
local gate. Echo is recorded as a **peak** — the final beat of a call that
reached 0.71 read 0.04, so every summary built on the last value said "no echo"
about a call with a measured one.

## Kin 0.83.0 — 2026-08-30

### Added — every call keeps a copy of its own numbers on the Mac

The beats existed in exactly one place: a server behind a key that lives in a
browser cookie on one machine. So a real complaint about a real call was
investigated out of a stderr log, because the telemetry built to answer exactly
that question could not be opened. Every beat is now appended to
`~/Library/Logs/Kin/beats.ndjson` *before* it is posted — a beat that fails to
send is exactly the one worth having — and `mac/tools/telemetry.sh` reads either
the local copy or the server.

## Kin 0.82.0 — 2026-08-30

### Fixed — two Kin icons in the Dock, and clicking Kin opening another copy

Three faults, one after another, all in how a Dock click is answered.

**`pid -1` is a live Kin, not a dead one.** Kin re-launches itself a quarter of a
second after opening (`execv`), which keeps the window but makes macOS lose track
of the process: its record reads `pid -1` for the rest of the call. Reading that
as "still running" meant clicks did nothing; reading it as "gone" meant a new
copy on every click. Neither reading is right, so the question is answered from
the process table now, filtered by argv — the watcher and the ring watcher are
the same binary, and bringing forward a process with no window is a click that
does nothing. To raise it, the app is asked to raise *itself* (SIGWINCH, whose
default action is to do nothing, so a copy older than the handler ignores it;
SIGUSR1 would have hung up on a live call).

**The second icon was the watcher.** It is meant to be invisible, and two things
undid that silently: after an `execv` the call that hides it fails, and answering
a reopen promotes the process. It is re-asserted every tick now — a state that
repairs itself needs no list of everything that might break it.

Three traps found on the way, all worth reusing: `kill(-1, 0)` returns 0 because
it asks about *every* process the user can signal; `URL.resolvingSymlinksInPath`
left `/tmp/…` where the kernel reports `/private/tmp/…`, so the scan matched
nothing; and the raise handler was first installed at the foot of a file that a
call with a window never reaches — it compiled, read as finished, and ran zero
times.

## Kin 0.76.0 — 2026-08-30

### Changed — 12% less CPU for the same call, and a way to see the cost at all

## Kin 0.75.2 — 2026-08-30

### Fixed — a Dock click opened *another* Kin

The watcher registers as `com.tokkah.tk`, so every Dock click, Finder
double-click and Spotlight hit resolves to it and arrives as a reopen. Its answer
was an unconditional new instance, so ten clicks were ten copies of the app, each
with its own window, camera and microphone. Nothing asked whether Kin was already
open. (Answered incompletely here; finished in 0.82.0 above.)

## Kin 0.75.1 — 2026-08-30

### Fixed — the camera aborted the app when a call was answered

## Kin 0.75.0 — 2026-08-30

### Changed — green is speaking, blue is listening

Also: the Mac mini's camera was choosing 10 fps.

## Kin 0.74.0 — 2026-08-30

### Added — the floor, wired: a mute for a microphone nobody is talking into

## Kin 0.73.0 — 2026-08-26

### Fixed — two instruments that reported the opposite of the truth

Both found by checking a shipped build rather than trusting it, and both are
the same fault: a second copy of something, which then drifted.

**`--audio-route` said `vp` on a build that runs `hal`.** It recomputed the
rule -- `ioPinned ? ioKind : (speakers ? "vp" : "hal")` -- right next to the
block that actually decides it. When 0.72.0 changed the default from
VoiceProcessingIO to the plain path, calls changed and this did not, so the
tool built to answer "which path will this call take" answered the opposite,
on a machine already running the new build. It reads `Audio.ioKind` now, the
same value the audio engine reads, and it names the floor and the switch time
so the answer is checkable rather than just reassuring.

Two functions answering one question is how `reach()` and `status()` disagreed
for twenty hours in this same codebase.

**`/api/mac/macs` reported `stage: null` for every Mac.** Every beat carries
`facts` and `events` as their own objects; the view read `update_stage` flat,
so it was always `undefined` — while the beats it was reading had the stage in
them the whole time.

The test did not catch it because the test invented its own beat, flat, and so
tested the reader against a shape no client sends. It uses the real nested
shape now, and restoring the flat reader fails exactly those two assertions.

With both fixed, the fleet view answers the original question on sight: the
MacBook Air on 0.72.0 heard from 3 minutes ago, the Mac mini still on 0.71.0
and not heard from in 72 — two missed check-ins, which is asleep or a stopped
watcher, and either way now visible instead of invisible.

## Kin 0.72.0 — 2026-08-26

### Changed — one at a time, properly this time

0.71.0 answered the echo with Apple's canceller. The decision is the other way:
**whoever is not speaking is muted outright, and whoever is speaking is heard
raw** — plain hardware path, no cancellation, no noise suppression, no automatic
gain. The green edge and the subtitles are what make that liveable: they say
whose turn it is, so a quiet moment reads as "they are listening" rather than as
a fault.

That is what the duplex gate was always for. It was just never doing it.

**The floor was never the limit — the ramp was.** Closing was an exponential
decay with a 35 ms time constant, and an exponential approaches its target
asymptotically: reaching a real mute needed about fourteen of them, roughly
240 ms of unbroken far-end speech. Speech does not hold still that long, so the
gain never arrived. Proved by sweeping the floor and watching the answer stop
moving:

| asked | −6 dB | −22 dB | −60 dB | −120 dB |
|---|---|---|---|---|
| achieved | 5.9 dB | 19.3 dB | **23.6 dB** | **23.6 dB** |

Closing is a **timed linear ramp** now, so it reaches the number it was given in
the time it was given. Same test, same room, floor unchanged: **23.6 dB →
37.9 dB**. Fourteen decibels, a factor of five quieter.

**And the switch time was swept, not guessed**, because in a half-duplex call
the switching speed is the whole experience:

| close | 1 ms | 2 ms | 4 ms | 8 ms | 16 ms | 32 ms |
|---|---|---|---|---|---|---|
| suppression | 38.0 dB | 38.0 | 37.9 | 37.7 | 33.9 | 27.3 |

A plateau to 8 ms and a cliff after it. The default is **4 ms** — the fast end
of the plateau, giving up 0.1 dB for the quickest switch available, and still
several times longer than the ~1 ms at which a gain step becomes an audible
click. Opening keeps its 1 ms exponential: that direction protects the first
syllable of an interruption and was never the problem.

Your own voice is still bit-for-bit what the microphone heard (worst sample
differs by 0.0001%), and the deadlock duck is untouched at −9 dB.

`--io vp` still runs the full VoiceProcessingIO path, `--gate-floor` and
`--gate-close-ms` tune this one, so the two are A/B-able on a real call rather
than argued about.

## Kin 0.71.0 — 2026-08-26

### Fixed — the echo, which every call has had since the first one

Reported as echo on both ends, "ear deafening". The telemetry had been saying
so all along and nobody had asked it: across every reported call `aec_on` was
**0** and `output_route` was **speakers**. Nobody has ever been on headphones,
so the acoustic path from speaker to microphone was open on both ends of every
call this app has ever made, with nothing behind it.

The duplex gate was what stood in for a canceller, and the comment above
`ioKind` already admitted the hole: it "only ever acts while the near end is
NOT speaking", so "echo during double talk is not solved by this and is the
honest gap". Two people on speakers is that gap. And in the field the gate was
not even winning the easy half — `floor_held_pct` is **85–99.7% on both ends**
of every call over 15 s, so neither side was ever gated, with `turn_collisions`
reaching 39 in a four-minute call.

The route decides now, because the route is what makes the echo:

| output | audio path | why |
|---|---|---|
| speakers | `VoiceProcessingIO` | the unit FaceTime uses; real cancellation |
| headphones | `HAL`, unchanged | no path back to the mic, so nothing in the way |

**Measured, not argued.** New [mac/tools/io-ab.sh](mac/tools/io-ab.sh) runs both
ends locally, four arms in alternating order so machine drift cannot read as an
effect, and asserts each arm ran the unit it is named after. The canceller costs
**+7.61 ms** mouth-to-ear against **4.23 ms** of rig noise — 1.8× the noise, so
real — landing in device latency (mic 1.88 → 4.21 ms, speaker 2.58 → 4.92 ms).
Against a 150 ms budget and calls currently at 19 ms, that is the cheapest fix
available for a call nobody can hold.

`--io hal` still pins the old behaviour; `--io vp` pins the new one. New
`--audio-route` answers which way a call will go **without starting one** —
every previous way to find out ran `tk` with no `--room`, which joins a loopback
peer and opens the microphone.

### Added — telemetry for the stages that had none

The updater recorded **nothing**: 0 `Metrics.` calls in 1200 lines. The only
machine-readable trace of an update was the version changing on the next call
somebody happened to make, so a Mac that updated late and a Mac that made no
calls looked identical — the exact pair that had to be told apart. There is now
an `update_stage` fact (current, offered, downloading, staged, held-for-call,
blocked, installed, unreachable, bad-signature, download-failed), counters, and
`installBlocker`'s reason on the wire.

The background watcher now files a **210-byte** beat on every update check, so a
Mac reports 48 times a day whether or not anybody calls on it. `phase: "watch"`
is a real third phase server-side, kept out of the call listings. New
`/api/mac/macs` gives one row per Mac: last seen, version, update stage, blocked
reason.

The join had one mark for five phases, so a 2.5 s p50 was a total with no parts.
Now `stun_ms`, `peer_found_ms`, `turn_ms`, `turn_blocked_ms`, `join_polls` — and
they immediately refuted the first theory they were built to test. The 20 s TURN
barrier above the media loop looked like the cause; measured, `turn_blocked_ms`
is **6 ms** (TURN finishes at 323 ms, the peer is not found until 336 ms). They
also showed `connected_ms` is two numbers wearing one name: split by role, the
callee is **p50 2482 ms** — the reported "2–3 seconds" — while the mixed figure
of 3127 ms was inflated by callers counting the seconds the other person took to
pick up.

### Fixed — analytics that cost latency would be a defect, so it is enforced now

`Metrics.swift` has always said nothing there may lock on the audio path — the
SIGSEGV that ended live calls came from a Swift collection touched by the audio
thread. What kept it true was everybody remembering, which is a habit and not a
property. The render callback identifies its thread once, and `tap`/`mark`/
`count`/`fact` now return **without taking the lock** when called on it.
`tel_hot_refused` rides out on the beat, so a mark added to a hot path in future
is a number rather than an unexplained stall. Zero on every build today.

### Fixed — a rig could not be isolated from the production directory

`TK_NO_IDENTITY` was declared 260 lines below the `--watch` block, and
`Watch.run` returns `Never` — so the guard was unreachable from the one process
whose job is claiming a handle. A watcher rig walked @devesh through @devesh9
against the live server on every run. Guarding the call sites was not enough
either: the watcher's own site was correctly skipped and a different path still
reached the ladder. The guard is now inside `Identity.claim()`, where nothing
gets past it.

## Kin 0.70.0 — 2026-08-26

### Fixed — a Mac that stopped answering calls, and never said so

Reported as "I was calling from the Mac mini and this MacBook Air did not show
the call, both on the latest version". It was neither the versions nor the
network. Three separate faults, and the second is the one that made it last
twenty hours.

**The doorbell had been dead since the previous evening.** Kin's login agent is
what answers a call while the app is closed. It exited cleanly at 20:03, moments
after handing a real incoming call to a fresh Kin, and `KeepAlive
{ SuccessfulExit: false }` told launchd that a clean exit meant it had finished
on purpose. So launchd did nothing, and every call after that rang into an empty
house. This is the SECOND outage from that one policy — the comment above
`ringLoop` records the first, where a startup race let the agent exit 0 before
the handle claim landed and "the Mac was then uncallable until the next login, on
the very first launch, silently". That instance was fixed by deleting that exit.
The policy was left alone, so the class survived. It is fixed at the policy now:
launchd restarts the agent whatever happened, and the one exit that genuinely
means stop — **Quit Kin** in the menu bar — boots the job out of the login
session rather than picking an exit code and hoping the policy still reads it
that way. The asymmetry is the argument: an unintended clean exit costs every
incoming call until the next login, and an unnecessary restart costs one process.

**The app kept telling itself it was fine.** `Watch.reach()` — the single
function behind "can people reach you with Kin closed", read by the settings row,
the permissions check and the startup line — decided that from whether
`launchctl print` EXITED 0. It exits 0 for a job that is merely registered,
including one that ran, exited and was never restarted. Calibrated on a
purpose-built control: an agent running `/usr/bin/true` reports `state = not
running`, `runs = 1`, `last exit code = 0`, and `launchctl print` still exits 0.
So every screen said "reachable" for twenty hours, and the telemetry fact
`reachable_closed` recorded **yes** throughout. `status()` twenty lines below had
it right all along by reading `state = running`; the function everybody actually
calls did not. It now reads the same line, offers a repair the app can perform
by itself (`launchctl kickstart`, no consent needed — the login item is already
approved), and `--watch-status` prints the verdict the app itself acts on rather
than computing a second, similar answer that can drift.

**And the caller was told nothing.** `/api/kin/<who>/ring` answered
`{ok: true, queued: 1}` whether the callee's Mac was waiting or had stopped
listening the night before, so the Mac mini showed a ringing screen with nobody
on the other end. The server is the only party that can know this. It now says
so, from **last-heard-from** rather than from whether a socket is held — this
project already learned that ghost sockets outlive their processes — and with
three states, not two: `listening` is **omitted** when a freshly woken Durable
Object has heard from nobody, because "they are offline" is not a thing to guess.
Kin shows it on the outgoing card, carried across the re-exec as a flag: a status
line written immediately before `execv` is drawn by a process that is about to
stop existing, which is a message nobody can read.

New: [mac/tools/doorbell-check.sh](mac/tools/doorbell-check.sh), 10 assertions,
in CI. It asserts the calibration itself — that `launchctl print` really does
exit 0 for a dead job, because if it did not, the original code would have been
correct — and it has a live-agent control, so it cannot pass by always answering
"not reachable". Where there is no launchd session it prints a SKIP that says
plainly that nothing was checked.

### Fixed — three defects in the rig that was supposed to prove the above

Found by running it against the tree it was written to protect, which is the
only way any of this surfaced.

It **tested whatever was lying in `.build`**: the gate was `[ -x "$TK" ]`, and
existence is not currency. The debug binary was nine hours older than the fix,
so the rig reported FAILED (5 of 8) about a program nobody is shipping — and it
could as easily have reported PASSED. It builds the binary itself now, then
checks the timestamp anyway (`swift build` can succeed without relinking) and
refuses to print a verdict if any source is newer, naming the files. Calibrated
by backdating the binary: exit 2, sources named.

It **built its dead job with the fixed policy**. `write_plist` hardcoded
`KeepAlive true`, so the scenarios needing a registered-but-dead job were asking
launchd to restart the thing they wanted dead; they had only ever passed by
landing inside a 30 s `ThrottleInterval`. The policy is a parameter now.

And it **asserted the wrong repair**: for an old-shape plist `fix=install` is
right and `fix=restart` is not, because restarting puts the same policy back in
charge and the Mac is deaf again by morning. Now split into 2a (old policy →
rewrite the plist) and 2b (new policy, parked in `spawn scheduled` behind a 300 s
throttle → just start it). 2b is the state every Mac is in after this release,
and nothing covered it before.

### Fixed — the download page named no macOS version, and no licence

The OS floor is written down in four places. `Package.swift` builds
`.macOS(.v14)`, the binary's `LC_BUILD_VERSION` says `minos 14.0`, and both
plists say `14.0`; `release.sh` already proved those three agree **with the
binary** rather than merely with each other. The fourth copy is the web page and
nothing checked it. `/kin` advertised "macOS 13+" for weeks after the build moved
to 14, and `/macos` — the page the install instructions actually link, seven
references to `/kin`'s one — named no floor at all. That is the same failure with
nothing to read: a Mac on 13 downloads the .dmg, launches it, and dyld refuses
the binary. That page also carried no licence anywhere, on an AGPL project, at
the exact spot where the download happens.

`release.sh` now checks every page that tells a human the number, against the
binary, and a page that stops mentioning the floor fails too — silence is the
failure that just happened. Calibrated on four inputs: correct pages pass, a page
regressed to 13 fails, a page gone silent fails, an unreadable binary refuses to
report.

### Fixed — the embed loaded the download page instead of the call

`embed.js` pointed its iframe at the bare room URL, which now answers with "Join
on Kin" — a 14 KB page whose job is to send a visitor to the app. So every site
embedding a call got a download prompt in the frame. It appends `web=1`, the
escape hatch the worker already documents, and the frame loads the 55 KB call
again. Verified against production, not against the deploy log.

Also fixed while here: the source-reading gate in `contacts.test.mjs` counted
`queued:` inside comments, so documenting this outage above the code failed the
test that documents it — comments are stripped before counting now. And the
guard on exported constants only knew about strings: `export const
KIN_LISTEN_MS = 90_000` made workerd refuse to boot outright ("not of type
'function or ExportedHandler'"), caught only by the real-workerd section. It
refuses every primitive now, in a fast test.


### The open-source audit, 2026-08-26

The previous [OPENNESS.md](OPENNESS.md) scored this project **100 / 100** against
commit `HEAD` — which is not a commit, and by then described a product that had
been replaced. Re-audited properly against `13b85b3`. **The honest score is
88 / 100**, and the twelve missing points are named individually in that file.

What the audit found, in the order of how much it cost a real person:

- **The app could not be pointed at anyone else's server.**
  `https://room.tokkah.com` was written out seven times across six files, so you
  could clone Kin, build it, and the app you built still phoned ours. Now one
  `Server` type with three origins — signalling, updates, invite links — resolved
  from `--server`, the existing environment variables, a `server.json` beside the
  app, or the shipped defaults, in that order. With none of them set, every
  origin resolves to the byte-identical string 0.69.0 compiled in.
  [SELF-HOSTING.md](SELF-HOSTING.md) is the walkthrough.
- **The one-line browser embed had been silently rendering a download page
  instead of a call.** `embed.js` builds an iframe pointing at the room, and the
  invite funnel could not tell that frame apart from a person following a link,
  so it handed the frame the "Join on Kin" page. HTTP 200, a real page, no error
  anywhere. Fixed with `web=1` — the escape hatch `worker.ts` already served —
  on the *frame* and deliberately not on the shareable link. This is the third
  thing that funnel has silently eaten; the first two were the cross-planet lab
  room and all five testbed call sites.
- **The download page promised macOS 13.** `Package.swift` says `.macOS(.v14)`
  and `Info.plist` says `14.0`, so anyone on 13 downloaded 1.5 MB of app that
  could not launch. Three places corrected.
- **CI was red on `main`** and had been since the 0.69.0 push. `main` had gone
  thirteen days without a push, so the first one carried the verdict on ~380
  commits. The failing test — the only one that runs the real Worker in real
  `workerd` against real durable storage — had been written the day before
  against a Miniflare API that the pinned version does not accept. **It had never
  passed once.** Ported to Miniflare 5 and then mutation-tested: delete the
  durable write and it fails, restore it and it passes.
- **The flagship had no CI at all.** `ci.yml` ran on Linux and tested only the
  Worker. There is now a macOS job that builds `mac/` and runs twelve offline,
  credential-free self-tests, calibrated by rigging a test to fail and confirming
  the job fails with it.
- **`testbed/freetier-audit.mjs`, cited here as a live guard, had been dead** —
  dying on `JSON.parse` of a JSONC file. Revived, and it was also reporting the
  worker bundle **3.6× too large** by gzipping a 392 KB sourcemap along with it.
  The real figure is 42.3 KiB, 1.4% of the free-plan limit.
- **Two committed `node_modules` symlinks were still in `HEAD`**, dangling in
  every clone since the first commit — after this changelog said they had been
  removed. They survived because `.gitignore` said `node_modules/`, and a
  trailing slash matches directories only, so a *symlink* by that name was never
  ignored. Both removed; the rule no longer has the slash.
- **Zero git tags and zero GitHub releases**, for sixty-nine shipped versions,
  while the scorecard claimed "tagged releases". 17 annotated tags created, one
  for each commit that is genuinely a release.
- **`SECURITY.md` had no reporting instructions**, while the scorecard scored it
  full marks for "private reporting".
- 14 debug screenshots were sitting in the repository root, tracked.

### Added
- **A way to check that a Kin download is really ours.**
  `python3 tools/verify-release.py` verifies the Ed25519 signature over the
  release manifest and the sha256 of the archive. Zero dependencies on purpose:
  macOS ships LibreSSL 3.3.6, which cannot do Ed25519 at all, and the stock
  Command Line Tools `python3` has no CA bundle, so `urllib` fails on a machine
  nobody has set up. `tools/verify-release-selftest.sh` calibrates it first and
  requires a refusal for each of the five ways a release can be wrong.
  The public key is published in [tools/README.md](tools/README.md).
- **`tools/secret-scan.sh`** — scans every commit on every branch, and **plants
  three secrets in a throwaway repository and requires that it finds all three
  before it will scan anything real**. A blind scanner and a clean repository
  produce identical output.
- **`tools/link-check.sh`**, **`tools/reuse-check.sh`**.
- **REUSE 3.3 compliance** — [REUSE.toml](REUSE.toml) and `LICENSES/`, declaring
  every one of 434 distributed files. Declared centrally rather than as a header
  in each file: the opening comment of a source file here is the most-read part
  of this codebase, and two lines of boilerplate above 266 of them buys identical
  rights for a worse read. The identifier is `AGPL-3.0-only`.
- **[GOVERNANCE.md](GOVERNANCE.md)** — one maintainer, said plainly, including
  what happens if he disappears.
- **[CITATION.cff](CITATION.cff)**, **`.github/dependabot.yml`**, and GitHub
  Actions pinned by commit SHA rather than by a movable tag.
- The licence is now named beside the "Source" link on every public page. The
  AGPL §13 source offer was already there; what it did not do was tell a visitor
  what they were allowed to do with it.

### Changed
- **[README.md](README.md) rewritten for Kin.** It had opened with "Live demo:
  room.tokkah.com — open it in two tabs, that's a call" and a `<script>` tag
  described as "the entire integration", roughly 380 commits and one pivot after
  that stopped being true.
- `SUPPORT.md`, `CONTRIBUTING.md`, `SECURITY.md` and `ATTRIBUTION.md` brought to
  the current product; `LAB.md` carries a status note rather than a rewrite,
  because the rig has not been re-run since the pivot and a confidently rewritten
  procedure nobody has executed is worth less than an honest warning.
- Issue and PR templates rebuilt around the Mac app. The bug form had been asking
  which browser.

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
- `tape-app/node_modules` was a **committed symlink** pointing outside the repo
  (`../phase1-transport/node_modules`); it landed dangling in every clone, as did
  `fatigue-lab/node_modules`. **This entry previously said both were removed. They
  were not** — both were still in `HEAD` two weeks later, and a fresh
  `git clone` still produced two broken links. Actually removed now, and the
  reason they survived a deliberate removal is worth keeping: `.gitignore` said
  `node_modules/`, and a trailing slash matches directories only, so a *symlink*
  named `node_modules` was never ignored and could be re-added at any time. The
  rule is now `node_modules` with no slash. The two remaining tracked symlinks,
  `tape-app/public/core` and `fatigue-lab/public/core`, are deliberate and
  resolve in a fresh clone — verified.
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

## Kin 0.69.0 — 2026-08-26

### Added
- **The settings panel says which Kin you are running.** Asked for directly, and
  the reason is not vanity: this app updates itself silently, so the person
  testing it has no way to know which build is in front of them. Two Macs side
  by side on different versions look identical, behave differently, and make
  every conclusion drawn from the pair worthless. It is the first thing to check
  before any comparison and it was on no screen anywhere. Inert, like the
  encryption code above it — a fact about this copy, with nothing to press — and
  last in the panel, because it is the thing you go looking for rather than the
  thing you came here to do. `describeTree` prints the sheet's rows, so
  [mac/tools/watch-check.sh](mac/tools/watch-check.sh) asserts the version on
  screen IS `VERSION` rather than trusting that it is.
  [mac/Sources/tk/Controls.swift](mac/Sources/tk/Controls.swift)

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
