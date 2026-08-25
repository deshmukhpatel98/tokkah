# Launch and join budgets — measured 2026-08-24

Goal: instant. See memory instant-everywhere. Nothing here is fixed yet.
Harness: /private/tmp/.../scratchpad/instant/ (winwait.swift, cold2.py, gap.py, join.py, press.py)

## Harness noise floor (measured FIRST, per project law)

/usr/bin/true spawn 1.2/1.4 ms · open --help 2.3/2.7 ms · `open -a` returns in 20-36 ms
(LaunchServices handoff, NOT the app) · window detector CGWindowListCopyWindowInfo 0.17 ms/poll
=> detection granularity < 1 ms.
REJECTED as a detector: System Events AX polling — 17 ms/query AND Kin reports 0 windows / 0 UI
elements to AX. That is a finding in itself: any accessibility tooling, screen reader, or window
automation is BLIND to this window.

## Cold launch -> window actually composited (n=5)

  Calculator   322 / **334** / 405 ms
  TextEdit     571 / **770** / 913 ms
  Kin.app     4707 / **4757** / 5415 ms      <- 14x Calculator, 6x TextEdit

(Safari deliberately not killed — it held the user's live windows. Calculator/TextEdit bracket
the same class.)

## Where the 4.9 s goes (median of 4 instrumented LaunchServices runs)

Process starts per launch: 1 pid, **2 program images** — execv keeps the pid (so pgrep/ps cannot
see it), and dyld + Swift runtime init is therefore paid TWICE.

| ms   | phase                                                        | verdict    |
|------|--------------------------------------------------------------|------------|
| 1639 | Stun.discoverAny + TurnClient.fetch() + Turn.allocate        | REDUCIBLE  |
|      |   main.swift:667-680. Blocking network ON THE MAIN THREAD, after                     |
|      |   makeKeyAndOrderFront. `turn: allocate failed` in 9/9 runs — the                    |
|      |   entire 1.6-2.7 s buys NOTHING today.                                              |
| 1155 | Update.available(current:) — main.swift:263, 2x HTTPS GET     | REMOVABLE  |
|      |   12 s timeout, synchronous, BEFORE the window is created.                          |
|      |   A/B: window at 2036 ms default vs 881 ms with --no-update.                         |
| 1113 | Rendezvous.exchange — main.swift:700, main-thread HTTPS       | REDUCIBLE  |
|      |   The LOCAL picture does not depend on it.                                          |
|  700 | Launcher.awaitURLRoom(within: 0.7) — main.swift:199           | REMOVABLE  |
|      |   A plain launch has no URL, so the FULL budget burns every time.                    |
|      |   Confirmed: first stderr at 818 ms plain vs 44 ms with --room.                      |
|      |   (Introduced by today's deep-link fix — the wait is right, the                      |
|      |   unconditional budget is not. Fix: also handle kAEOpenApplication                   |
|      |   and return the instant EITHER launch event arrives; measured AE                    |
|      |   delivery was 27 ms.)                                                              |
|   93 | camera open -> first local picture                            | REDUCIBLE  |
|   78 | re-exec + SECOND dyld/Swift init                              | REMOVABLE  |
|      |   A whole second image init to decide a room name (microseconds of work).            |
|   33 | run loop -> first composited frame                            | IRREDUCIBLE|
|  ~20 | LaunchServices + first dyld/Swift init                        | IRREDUCIBLE|
| 4914 | total (black-box median 4757)                                 |            |

## The structural finding

The window is created and ordered front at **2036 ms** and is not composited until **4914 ms** —
a **2878 ms gap in which the window exists, is key, and shows nothing**, because the main thread
is inside STUN -> TURN -> rendezvous and never returns to the run loop. The rendezvous POLL loop
does pump AppKit (main.swift:733); everything before the first poll does not.

3907 of 4914 ms are network round-trips blocking first paint. Removing ONLY the update check saved
~100 ms end-to-end (4813 vs 4914) because TURN/rendezvous absorbed the slack — **these must be
fixed together or the win hides.** (Rate-control-hides-quality-wins, same shape.)

## Join time (two legs, same room, LaunchServices so camera is granted)

  launch -> first stderr                44 ms   (44)
  -> window created                    167 ms   (211)
  -> FIRST LOCAL PICTURE               396 ms   (607)
  STUN + TURN (allocate failed)       1632 ms   (2239)
  Rendezvous.exchange                  875 ms   (3114)
  waiting for peer to publish         2104 ms   (5218)   <- the 2 s poll cadence, main.swift:735-744
  encoder + audio device start          61 ms   (5279)
  candidate race settles               164 ms   (5443)   path: direct, rtt 8.56 ms
  -> FIRST REMOTE FRAME               126 ms   (5569)

The 2104 ms is paid only by whoever arrives first; when the peer was already published it was
found on the first exchange (`peer legA (14 ms old)`). Resulting call healthy: rtt 8.56, m2e 18.62.
UNEXPLAINED: an earlier pair sat 12 s between peer-found and encoder start, at the same absolute
instant on both legs. Not reproduced. Flagged, not explained.

## Control response — no perceptible lag

Real synthetic clicks through window.sendEvent: click -> describeTree reflecting new state =
1, 1, 1, 2, 2 ms over 5 clicks. Hit-test audit: all 8 controls OK. Caveat: this is click ->
handler -> state, not pixels; and a click during the 2878 ms pre-paint block would be QUEUED,
but there is nothing on screen to click.

## Incidental

The app self-updated 0.44.0 -> 0.45.0 mid-measurement. That run cost +2.4 s (download 900 ms,
stage/verify 130 ms, install 130 ms, then a THIRD image init) — a first-launch-of-the-day path
a real user pays.

## Fix order (do 1-4 together; separately the win hides)

1. Move Update.available OFF the launch path entirely — poll only, after first paint. (-1155 ms)
2. Make awaitURLRoom return on kAEOpenApplication as well as kAEGetURL. (-700 ms on plain launch)
3. Move STUN/TURN/rendezvous off the main thread, or after first paint. TURN is failing 9/9 —
   fix or skip it, but do not block the screen on it. (-1600 to -2700 ms)
4. Delete the re-exec: decide the room in-process instead of re-launching the image. (-78 ms and
   one whole dyld+Swift init; also removes the LaunchServices -600 flake seen on warm URL opens)
5. Then: first rendezvous exchange concurrently with camera open, and drop the 2 s poll cadence
   for the first few seconds. (join, up to -2100 ms for the first arriver)
6. Separately: the window is invisible to accessibility (0 AX elements) — real bug, own fix.

# ============ IMPLEMENTATION BRIEF (prepared 2026-08-24, not yet applied) ============

## Line numbers above are STALE — the tree moved ~35 lines. Correct anchors (main.swift):
  199 awaitURLRoom (ok) · 263 Update.available (ok) · 706-722 STUN+TURN (discoverAny 706,
  TurnClient.fetch 713, tc.allocate 714) · 738-786 poll loop (first exchange IS attempt 1,
  at 741; AppKit pump 775-785; usleep(2_000_000) 784).
  There is no separate "first exchange" — items 3 and 5 are ONE edit, not two.

## The structural fact everything hangs off

main.swift:442-477 creates the window; :588-654 opens the camera; :622 starts it. NEITHER
touches the network — CameraSource.start (Video.swift:189-215) is pure AVFoundation and the
frame sink at :593-603 only calls display?.showSelf. The local picture is ALREADY above the
network in program order. Nothing paints because the main thread runs 654 -> 706 -> 741 without
returning to the runloop. The poll loop at 775-785 pumps AppKit; everything before it does not.
=> The cheapest correct fix is NOT "move the network", it is "PUMP THE RUNLOOP BEFORE IT".
Backgrounding the network is the second half, and it buys responsiveness, not first paint.

## Ordering invariants — violating any is a SILENT failure

1. wire.fd has exactly ONE reader. Stun.discover (Stun.swift:49) and TurnClient.roundTrip
   (Turn.swift:165-197) both recvfrom on the media socket and both setsockopt(SO_RCVTIMEO);
   roundTrip's defer resets it to BLOCKING (Turn.swift:182-185). wire.recvLoop starts at
   main.swift:1441 — any backgrounded STUN/TURN MUST finish before that line. Reason is written
   at main.swift:794-800. FAILURE: intermittent unattributable audio loss at call start plus a
   TURN allocate that fails for no visible reason.
2. STUN and TURN-allocate stay serialized with EACH OTHER (same fd). TurnClient.fetch()
   (Turn.swift:38-60) is pure HTTPS and MAY overlap STUN — that is the free parallelism.
3. wire.turn (:714) and wire.setPeer/addCandidate (:746-764) must be published before
   audio.start() (:1444) and before the crypto handshake thread (:1406-1414) sends.
4. Any display?.controls?.setStatus moved off main MUST hop to main (:727, :732 would start
   violating; :814, :833, :864 already do). FAILURE: off-main AppKit mutation — the class that
   has already SIGSEGV'd this process.
5. `let videoArg = resolveVideoArg()` at :159 is computed BEFORE the room decision at :194. On a
   plain launch it is "off"; only the re-exec's injected --video camera makes image 2 see a
   camera. FAILURE: the exact regression documented at :134-146 — double-click, no camera.

## 1. Update check off the launch path

Delete :263 outright (Update.available = 2 sequential BLOCKING HTTPS GETs, Update.swift:82-97,
12 s timeout each, measured 1155 ms). Keep :270-274 (onPending, must be assigned before the
poller can fire) and the poller. Move :266 repairBundleIfStale to its OWN Thread — free on a
healthy install (one Info.plist read) but when it fires it does 2 GETs + a tarball download at
timeout:120 on the MAIN THREAD before the window: a latent 100x worse version of the same bug.
It must not share the poller thread — the poller's 0.5 s cadence is what lands a pending update
the instant a call ends.
Add `firstAfter:` to Update.startPolling (Update.swift:606-654); change the due test at :633 to
`waited >= (firstTick ? firstAfter : seconds)`.
The poller is a strict SUPERSET of the launch check (:641 same available(), :645 same stage(),
:646-651 commits when !callIsLive()). Nothing is lost.
GRACE MUST NOT BE 2 s: callIsLive() (Update.swift:576-579) is false during the ENTIRE call setup
(no peer packet yet), so a 2 s first tick on the first launch after a release re-execs at ~2.5-3 s
— the window vanishes while the user reads their invite link. Use 10 s, as a NAMED CONSTANT.
Do NOT use a "setup in flight" flag instead: the far lab machine sits solo for long stretches and
a flag clearing only on peer arrival would strand it un-updateable.

## 2. awaitURLRoom returns immediately on a plain launch

Launcher.swift:146-158, called main.swift:199 with 0.7 s. Exits only on urlRoom or deadline, so a
plain launch burns the whole budget (first stderr 818 ms plain vs 44 ms with --room; AE delivery
on a URL launch measured 27 ms).
Add a second mailbox: handlers for kAEOpenApplication AND kAEReopenApplication on kCoreEventClass
(idiom: Launcher.swift:71-77), a `sawLaunchEvent` flag, and make the wait `while urlRoom == nil,
!sawLaunchEvent, Date() < deadline`.
REGISTRATION ORDER IS LOAD-BEARING AND COUNTERINTUITIVE: finishLaunching() installs AppKit's own
kCoreEventClass handlers, so register OURS AFTER it (:151) or AppKit overwrites us.
Fallback 250 ms (down from 700) for the three launches that deliver neither event.
RISK, named: we replace AppKit's oapp handler. No app delegate and no NSDocument here so the
default is near-no-op, but that is not provable by reading — acceptance must show a plain launch
still activates/comes forward (Display.swift:187) and the menu still builds. If off, CHAIN via
AEGetEventHandler instead of replacing.
Apply the same at Install.swift:246 (awaitURLRoom(within: 0.5) on a first-ever DMG launch).
FAILURE if wrong: the flag is set before the GURL event and every invite mints a stranger's room —
the exact bug Launcher.swift:123-145 exists to kill. The deep-link regression check is mandatory.

## 3. Network off the main thread + TURN IS ACTUALLY BROKEN

3a — ONE LINE, most of the win: pump AppKit immediately before :706. Factor :778-782 into a
reusable `pumpAppKit(until:)`. There are already THREE hand-rolled copies (Launcher.swift:153-156,
:402-407, main.swift:778-782) — collapse to one; a fourth is how they drift.
3b — background STUN/TURN behind a semaphore, pump until signalled (signal-aware: poll
netDone.wait(timeout: .now()+0.02) between nextEvent turns). Move the :723-733 diagnostics into
that thread; their setStatus calls get DispatchQueue.main.async (invariant 4). The exit(1) at :728
is already inside asyncAfter and survives unchanged.
Do NOT move the media pipeline (:898+) above the room block in this pass.

*** TURN: root cause found by reading. Turn.swift:81-86 builds the Allocate as
    var attrs: [(UInt16, [UInt8])] = [(0x000D, u32(600))]   // LIFETIME only
    There is NO REQUESTED-TRANSPORT (0x0019). RFC 5766 6.1 makes it MANDATORY and a server MUST
    reject an Allocate without it with 400. `grep -rn "0x0019\|REQUESTED"` over mac/Sources/tk
    and mac/tools returns NOTHING — the attribute does not exist in the repo. That fully explains
    `turn: allocate failed` 9/9 (credentials are fine: worker.ts:2274 mints real
    rtc.live.cloudflare.com creds).
    FIX (2 lines): append (0x0019, [17, 0, 0, 0]) — UDP + 3 bytes RFFU — to attrs at :81, and to
    the unauthenticated probe at :80 too (some servers validate before challenging).
    ALSO: parse (Turn.swift:199-215) walks error attributes for REALM/NONCE and THROWS AWAY
    ERROR-CODE (0x0009). Capture and print it at :91 — today the log cannot tell 400 from 401
    from a timeout, a blind instrument returning the same value as a real negative.
    This matters beyond launch: TURN is the long-haul relay, i.e. the 150 ms goal.

DECOUPLE TURN FROM THE JOIN ENTIRELY (highest-value line in item 3): myRelay is only a query
param to Rendezvous.exchange (:741, :841, :878), the loop republishes every iteration, and the
worker overwrites each time (worker.ts:277). Make myRelay a var written by the TURN thread and
read by the poll loop: publish immediately WITHOUT a relay, republish when it arrives. TURN
latency then costs nothing whether or not the allocate is fixed.

## 4. DELETE THE RE-EXEC — DO NOT DO THIS IN THIS PASS

main.swift:194-202 (and :215 from the --gui branch). What re-exec preserves:
  --room in argv -> read at :194, :205, :240 (the "link we are already in" dedup), :461 (window
    label -> inviteText), :696 (the whole room block), and **:1402 cryptoSalt** — a missing room
    SILENTLY changes the HKDF salt, so both ends encrypt with different keys.
  --video camera -> `let videoArg` at :159, evaluated BEFORE the decision (invariant 5).
  --window -> :442.
  argv for Update.commit -> Update.swift:438, :485 re-exec CommandLine.arguments VERBATIM. Today
    argv contains --room <minted> because the re-exec put it there, so a mid-run update rejoins
    the same room. Remove the re-exec without rewriting what commit re-execs and AN UPDATE
    LANDING AFTER LAUNCH DROPS THE USER INTO A FRESH ROOM AND KILLS THE LINK THEY ALREADY SENT.
    Item 1 makes that routine where today it is impossible. Tightest coupling in the change.
VERDICT: 78 ms for two silent-failure modes. DEFER to its own pass. Items 1,2,3,5 are independent
and deliver ~3.9 of the 4.9 s.
SAFE SUBSET IF TOUCHED NOW: keep the execv, and only add gArgv plumbing to Update.commit so the
update path re-execs an EXPLICIT argv rather than an inherited one. That is the guard item 1
needs anyway and the prerequisite for deleting the re-exec later.

## 5. Join — the 2 s poll cadence

main.swift:738-786. Worker limits CHECKED: /rv (worker.ts:2496 -> :234 -> rendezvous() :256-283)
is an in-memory Map write + filter with a 90 s lease sweep, NO rate limit, NO 429 path. Fast
polling is safe. The only nearby limit is /api/mac/turn: ICE_MINT_MAX 20 per 10 min per IP
(worker.ts:1627-1628, enforced :2264-2270) — we mint once per launch.
Backoff: 100 ms x10 (first ~1 s), 250 ms to 3 s, 500 ms to 10 s, 2 s after. Real cadence is
exchange_latency + sleep (exchange is synchronous, timeoutInterval 8, semaphore 10 — Stun.swift:
183, :209), so ~400 ms at the fast end. Two peers = ~5 rps against one DO: nothing.
*** THE TRAP: `for attempt in 1...60` is a COUNT standing in for two minutes. Speed up the polls
and the give-up window at :787-790 silently collapses from 120 s to ~6 s — the "nobody else
arrived in 2 minutes" message becomes a lie and a peer 10 s late gets exit(1). CONVERT TO A
DEADLINE (let giveUp = Date() + 120; while Date() < giveUp) and leave the message alone. Same
class as the RTT-blind timeouts: a threshold in the wrong unit is a hidden limit.
FOLLOW-ON (not needed for the headline): fire a READ-ONLY first exchange (addr: nil) concurrently
with STUN — the worker only registers a peer when addr is present (worker.ts:267), so it is a
legal query, and it moves peer discovery ~1.6 s earlier for whoever arrives second.

## Acceptance

Noise floor FIRST, same session as the after-run: cold2.py on Calculator (~334) and TextEdit
(~770). If they moved, the Kin comparison is confounded.
  cold -> composited (cold2.py, n=5):   4757 -> TARGET <= 600 median, <= 900 max
  phases (gap.py, n=4): created 2036 / visible 4914 -> created <= 350, cam <= 500, visible <= 600,
    and visible-created <= 150 (today 2878). turn/stun_pub/waiting markers STILL PRESENT, all
    AFTER visible.
  join (join.py): first remote 5569 -> first local <= 700 both legs, first remote <= 2500 for the
    first arriver.
  controls: 8/8 OK, and a click at 500 ms LANDS rather than queues.
REGRESSIONS THAT MEAN IT IS WRONG:
 1. Deep link: cold app, `open "tokkah://join/accept-link-1"` must show `url: joining` AND
    `room accept-link-1:`. A 3-4-3 minted name = item 2 broke the invite path. Run 5x — a 1-in-5
    race is still broken.
 2. Plain launch still mints and shows a link; `preview: camera` present, `camera: not permitted`
    absent.
 3. Update still lands INTO THE SAME ROOM: TK_UPDATE_BASE + TK_UPDATE_POLL=2, launched with an
    explicit --room, assert the new image reports that same room (the item-4 guard).
 4. Call still healthy: connected via, path: direct, loopback rtt ~8-9 ms, m2e p50 ~18-20 ms.
 5. Give-up window still ~120 s, not ~6 s (item 5's deadline conversion).
 6. Query flags still touch no hardware: --version, --help, --no-update, --stun, and both
    release.sh gates.
RIG HAZARD: each launch mints one TURN credential; /api/mac/turn caps at 20 per 10 min per IP. A
full pass is ~11 mints, so a second pass inside 10 minutes gets 429s, TURN silently becomes "no
credentials", and the timing profile changes between before and after. Space passes >= 10 min.
MEASURE 1+2+3 TOGETHER — removing only the update check already read as ~100 ms because TURN and
rendezvous absorbed the slack (see above). One at a time will read as "no effect" and invite a
revert of a correct change.
