# Ringing and connect — budgets measured 2026-08-24

Goal: tap a name, the other Mac rings, they tap once, they are in. See memory
`call-people-not-rooms`, `instant-everywhere`. Design context: **CONTACTS.md** (identity, pair
key, mailbox, abuse model). This file is only the **ring and connect path** — what it costs,
what of that is physics, and what of it is ours.

> **Re-pointed at the deployed server, 2026-08-24.** Every `worker.ts` reference in this file
> is now **by symbol name and never by line.** The 21 line numbers that used to be here were
> all wrong within days of being written — the doorbell section is under active edit, and a
> doc sitting next to a file being edited cannot hold line numbers. Resolve one with
> `grep -n '<symbol>' tape-app/src/worker.ts`. Do not reintroduce numbers here.
>
> The shapes below now match the deployed server. What changed since the first draft:
> - the ring is **6 fields**, not 5 (`KIN_RING_KEYS` = `to, from, room, sig, t, k`). `k` is the
>   caller's base64 Ed25519 public key, and `sig` is made with the caller's **device key**, not
>   with a shared pair secret. The callee looks `k` up in its own contact list and verifies
>   `sig` under it, so a stranger's first-ever ring is verifiable with no prior key exchange.
>   The server still verifies **nothing** about a ring — by design.
> - `register` is **no longer unsigned**: `{to, tok, k, t, sig}`, where `sig` is Ed25519 over
>   the UTF-8 string `"kin-reg-v1|" + to + "|" + tok + "|" + t`. Clock skew beyond 60 s is
>   refused *before* any crypto, and a re-register must present the **same key**. Without
>   that, first-come-first-served meant the handle was held by the first HTTP request rather
>   than the first device, and anyone could take `devesh` from its owner.
> - handles are `^[a-z][a-z0-9]{1,31}$` — lowercase names like `devesh`, assigned by the
>   machine at first launch from the Mac's short username, walking a collision ladder
>   (`devesh` → `deveshp` → `devesh2` → …) until a register succeeds. Not 26 base32
>   characters. Verified at the edge: `devesh` routes (401 on a bad credential), `DEVESH` and
>   `d` are 404.
> - the ring budget is **4/min per (k,to), 4/min per (from,to), 12/min and 60/h per `to`** —
>   was 6/min per pair and 30/min per `to`. The per-pair cap was worthless on its own because
>   `from` is free to mint; the hour cap is the denial-of-sleep bound.
>
> The **measurements** in this file were not invalidated by any of that and still stand,
> including the one that matters most: a never-touched room costs **1.63 s** on its first
> request (independently re-measured, n=5, spread 1.0-3.4 s) against **0.126 s** warmed,
> where warmed is byte-for-byte the same as an already-used room. `/api/room/<code>/warm`
> is deployed and this app has never called it.


Nothing here is implemented on the Mac. The server half of the doorbell IS deployed
(`/api/kin/<handle>/(register|ring|poll)`, dispatched at the edge on `KIN_ROUTE_RE`). The Swift
side is zero lines: no `Identity.swift`, no `/api/kin` call, no incoming-call window, no
`/warm`, and **no process that runs when
a call does not** — `NSApplication.shared.run()` is reached only when a display exists
(main.swift:2853).

## Instruments first (measured before any conclusion, per project law)

Delhi, home Wi-Fi, `colo=DEL`, `loc=IN`, 2026-08-24. Every number below is min/median of a
real run, not an estimate.

```
client -> nearest CF edge (DEL)        TCP connect  4.6 - 9.1 ms      => RTT ~5 ms, one way ~2.5
                                       ping min     3.594 ms
TLS handshake to that edge             appconnect  13.1 - 21.2 ms
STUN binding, stun.cloudflare.com      min 3.8  med 4.3  max 8.4 ms   (n=8; both Google servers identical)
WORKER-only route (/api/ice), warm     ttfb 11.5 / 11.6 / 12.4 / 13.1 ms
DURABLE-OBJECT route, warm conn, hot   ttfb 99 - 156 ms, median 127   (/rv and /kin/poll identical)
DO cold start (first request ever)     883 - 2604 ms, median 1108     (n=27 fresh objects)
DO stays resident after last request   >= 120 s   (5/10/20/30/45/60/90/120 s gaps: 119-316 ms, never cold)
```

Edge -> DO round trip, measured two independent ways and agreeing:

```
/api/probe?region=none  (DO created near the asking edge)   minMs 111  med 113
/api/probe?region=apac                                      minMs  88  med  89
                        eeur 163 · afr 189 · oc 190 · weur 196 · me 276 · sam 279 · wnam 288 · enam 301
subtraction: 127 (DO route) - 12 (worker route)          =  ~115 ms
DO -> DO, distinct regions:  apac->weur 164 · apac->eeur 185 · apac->enam 256 · weur->enam 109
```

**How much of that is distance and how much is Cloudflare's own dispatch.** I first measured
DO->DO *inside* one region and got 0-1 ms — but `via=apac&region=apac` makes a DO fetch
**itself**, which short-circuits, so that number was an artefact and I discarded it. The
cross-region hops above are real two-object round trips, and against known backbone RTTs
(`weur<->enam` ~85 ms, `apac<->enam` ~230 ms, `DEL<->apac` ~60 ms) they imply a consistent
**~20-30 ms of DO dispatch overhead** per round trip, on top of propagation.

So an 88 ms edge->DO round trip from Delhi is roughly **60 ms of propagation + 28 ms of
dispatch**. Both are floors from our side: we cannot move India closer to Singapore and we do
not control Cloudflare's dispatch. A Durable Object is a fixed point on the planet, both ends
pay the trip to it, and there is a fixed ~25 ms toll for touching it at all.

### The two findings that reorganise this whole document

**1. Every stateful server hop from Delhi costs 88-115 ms, and a Worker hop costs 12 ms.**
There is no DO region in India. An unhinted DO created *by a Delhi request* still answers
111 ms away; the nearest reachable one (`apac`) is 88 ms. So a same-city ring between two
people 5 ms apart travels ~90 ms because the rendezvous is on another continent. This is
not a bug and it is not fixable below ~88 ms while the ring goes through a DO.

**2. A fresh room's Durable Object costs 1108 ms (median) on its first request.**
This is almost certainly the largest single item inside the other lane's 2907 ms
`connected via`, and it is already a solved problem *on the web side only*:

> "the FIRST joiner's ws-open was ~1.1 s against ~0.3 s for the second (measured,
> ttc-measure, prod medians) — the difference is the room Durable Object's cold start,
> paid by whoever CREATES the room" — app.js:8386

The web app therefore calls `GET /api/room/<code>/warm` while the human is still looking at
the preview (`prewarmRoom`, app.js:8404; server `Room.warm`). **The Mac app has never called
it.** Measured here: fresh room cold 1085/1116/1377 ms, then 125/149/153 ms.
`grep -rn "/warm" mac/Sources/tk` returns nothing.

And it gets worse for the feature being designed: CONTACTS.md §3 derives the rendezvous room
from a **300-second epoch**, so a contact call lands on a room name that has almost never
existed. The design as written *guarantees* a cold DO on nearly every call.

---

## Stage-by-stage budget: floor vs ours

Press -> both people see and hear each other. One-way values; `A` = as placed today,
`B` = doorbell DO hinted to the callee's continent.

| # | stage | irreducible (propagation + platform floor) | ours (removable) |
|---|-------|---------------------------|------------------|
| 1 | caller -> ring at the server | 2.5 ms to own edge; +30 ms edge->DO one way (B) / +42 ms (A); **+28 ms DO dispatch toll, paid once** | TLS handshake 13-21 ms if the connection is cold (0 with a held socket). **DO cold start 1108 ms** if the callee's inbox DO is not resident. App's own sign+serialise: <1 ms. |
| 2 | server -> callee's Mac | 30 ms (B) / 42 ms (A) DO->edge one way, +2.5 ms edge->Mac | **the 5 s poll: 0-5000 ms, mean 2500 ms.** Held socket -> 0. `KIN_POLL_GAP_MS` = 2000 caps how far fast-polling could ever help. |
| 3 | callee's screen shows the call | one display refresh, 8-16 ms at 60-120 Hz | **cold launch 4757 ms** (LAUNCH.md, n=5 median) if the app is not running — and today *nothing launches it*, so the real number is ∞. Resident process -> ~0. Window create->composite must add nothing: LAUNCH.md measured a 2878 ms gap where a window existed and showed nothing. |
| 4 | callee taps answer | human, 1000-3000 ms | 0 removable. **This is the budget the pre-warm spends.** |
| 5 | media both ways | 2.5-5 ms same city; **63 ms Delhi<->NL** (from the measured 127 ms m2e) + encode/decode/jitter | **2907 ms today.** Of which: DO cold start ~1108, fixed sleep cadences ~1400, local picture 258. Tap->media after pre-warm ≈ **190 ms** (LAUNCH.md's own encoder+audio 61 ms + first remote frame 126 ms). |

### Achievable ring latency, three distances

Ring = press -> ring bytes on the callee's Mac. Add 8-16 ms for photons.

**Architecture A — server ring over a held socket.** One-way legs derived from the measured
round trips as `(RTT − 28) / 2`, with the 28 ms dispatch toll counted once at the DO.

| pair | caller->edge | ->DO | dispatch | DO->callee | ring | to photons |
|---|---|---|---|---|---|---|
| same LAN (one Wi-Fi) | 2.5 | 30 | 28 | 30 | **~93 ms** | ~105 ms |
| same city (Delhi<->Delhi) | 2.5 | 30 | 28 | 30 | **~93 ms** | ~105 ms |
| same country (Delhi<->Mumbai) | 2.5 | 30 | 28 | ~31 | **~94 ms** | ~106 ms |
| intercontinental (Delhi->NL), doorbell in `weur` | 2.5 | 84 | 28 | ~2 | **~119 ms** | ~133 ms |
| the same call, doorbell left in `apac` | 2.5 | 30 | 28 | 68 | **~131 ms** | ~145 ms |

The counter-intuitive result, and it is a good one: **the ring costs about the same
(~93-119 ms) no matter how far apart the two people are.** The cost is the trip to the DO plus
the dispatch toll, not the distance between the humans. An intercontinental ring is only
~26 ms worse than a same-city one. The ring is already near-constant-time worldwide — and the
LAN row is the damning one: two Macs on **one Wi-Fi network, 1 ms apart**, ring each other in
93 ms via Singapore.

**Architecture B — direct UDP ring to a cached address, server ring racing it:**

| pair | direct ring, one way |
|---|---|
| same LAN | **0.5 - 2 ms** — under 10 ms |
| same city | **4 - 6 ms** — under 10 ms (measured STUN RTT 4.3 ms; this project's own same-city peer RTT 8.56 ms) |
| same country | 12 - 25 ms |
| Delhi <-> NL | **~63 ms** — propagation, and that is the end of it |

### So: is 10 milliseconds available?

Plainly, three answers, and only the first is a yes:

- **LAN: yes, comfortably.** 0.5-2 ms of wire, one refresh for photons. 10 ms is reachable
  end to end.
- **Same city: yes for ring *bytes* (4-6 ms), no for ring *photons*.** One display refresh
  is 8-16 ms on its own, so ring-to-visible is 15-25 ms and 10 ms is already spent on the
  screen. And this requires Architecture B; through a DO it is ~93 ms.
- **Intercontinental: no, and not by a factor of six.** Delhi->NL one-way propagation is
  ~63 ms. Fibre carries light at c/1.468 and no engineering removes it. 10 ms is not a hard
  target there, it is a physically empty statement.

The correct target to hold this to is not 10 ms. It is: **the ring adds nothing above
propagation, and the answer adds nothing at all.** That is achievable everywhere, and it is
what the rest of this file designs.

---

## The ring is NOT the small part — correcting the brief with numbers

The claim I was asked to check: measured today, first local picture 258 ms, peer found
1330-1534 ms, `connected via` 2907 ms, therefore the ring is a small fraction.

**On today's numbers that is wrong.** Today's ring is a 5-second poll, mean 2500 ms. The
entire connect is 2907 ms. They are the same size, and the ring is very slightly cheaper
only because a poll's *mean* is being compared with a connect's *total*; at the 95th
percentile the poll (4750 ms) is worse than the whole connect.

The claim becomes **true, and permanently true, the moment the poll is replaced by a held
socket**: the ring drops to ~93 ms and then it is 3% of the path. So the conclusion the brief
reached is the right one to design toward — but it is a consequence of fixing the ring, not a
reason to skip it.

And the largest number in the whole path is neither: it is stage 3. The user's ask was
explicitly *"they don't even have to open the app"*. In that case the callee's app must be
launched, and LAUNCH.md measured cold launch -> composited window at **4757 ms** — larger
than the ring and the connect put together. Today it is not 4757 ms, it is infinite, because
nothing launches it.

### Ranked removable milliseconds, largest first

This is the part to act on.

| # | what | today | after | removable | cost to do it |
|---|------|-------|-------|-----------|---------------|
| 1 | **callee's app is not running** | never rings | ~0 | **the whole feature** | `LSUIElement` + status item + `SMAppService`; one release; see below |
| 2 | **5 s inbox poll -> held socket** | mean 2500, p95 4750 | ~93 | **-2400 ms** | new hibernatable DO class; the biggest server change here |
| 3 | **room DO cold start** | 1108 (median, n=27) | ~0 | **-1100 ms** | ~10 lines of Swift. `/warm` already exists and is already deployed |
| 4 | **fixed sleep cadences, peer-found -> connected** | ~1400 | ~400 | **-700 to -1000 ms** | handshake sleeps 0.25 s (main.swift:1729), candidate re-probe sleeps 0.5 s (main.swift:1143, :1178). Fire on the event, not on the timer |
| 5 | **first `/rv` concurrent with STUN, not after** | serial | overlapped | **-300 to -1600 ms** | a read-only exchange (`addr: nil`) is legal — `Room.rendezvous` only registers a peer inside its `if (addr)` branch |
| 6 | doorbell DO placement | 131 ms | 119 ms | **-12 ms** | one `locationHint` at register time; only honoured at creation |
| 7 | direct UDP ring (Architecture B) | 93 ms | 5-10 ms | **-85 ms** | largest privacy cost in the document; see the verdict below |
| 8 | TLS handshake per ring | 13-21 ms | 0 | **-15 ms** | free, subsumed by #2 |
| 9 | STUN server ordering | 4 ms typical | 4 ms | **-0 typical, -1200 worst** | `Stun.discoverAny` budgets 1200 ms per server (Stun.swift:32) against a measured 4.3 ms. Latent, not current |

Items 4 and 5 are *inside* the human's answer time once pre-warm exists, so they stop being
wall clock at all. That is the whole argument for pre-warming.

**Headline, case "app running and registered":**

```
today:  ring 2500 + window 50 + human 2000 + connect 2907   = ~7457 ms,  4457 ms of it machine
after:  ring   93 + window 100 + human 2000 + tap->media 190 = ~2385 ms,   385 ms of it machine
                                                                machine time: 11.6x
```

---

## Pre-warm during ringing

The idea: at the instant the callee taps answer, the path is already probed and open, so
answering is closer to unmuting than to connecting. Judged below, then cut down.

### Timeline (full version)

**T+0 — caller presses the name.** The window says "Calling Meera…" *immediately*; it must
not wait on any of the following. Fired concurrently, none blocking the UI:

- `Stun.discoverAny` on the media fd (Stun.swift:32) — 4 ms measured
- `TurnClient.fetch()` (Turn.swift:38) — worker-only route, ~13 ms. **Credentials only.**
- `GET /api/room/<R>/warm` — pays the 1108 ms cold start now, inside the human's answer time
- camera / local picture, which is already above the network in program order (LAUNCH.md)

**T+20 — candidates known** (`Stun.localIPv4`, Stun.swift:136, plus the mapped address).

**T+20 — POST the ring**, carrying `cands`. ~127 ms cold connection, ~93 ms over a held one.

**T+~150 — the ring lands on the callee's held socket.** Before the human touches anything:
look `k` up in the contact list and verify `sig` under that key — one lookup, not a loop over
every stored secret — and drop silently if the key is unknown or the signature fails; draw the
window; fire the callee's own `/warm`; run STUN (4 ms); publish to `/rv`; **begin connectivity
checks against the caller's candidates.** No camera. No microphone. Nothing captured, nothing
sent as media.

**T+~300 — the path is open.** Candidate race settled (LAUNCH.md measured 164 ms), crypto
handshake done (40 bytes, one RTT — `Wire.sendHandshake`, Net.swift:334).

**T+1500-3000 — the human taps Answer.** Open camera and mic, start encoder and audio device
(61 ms measured), unmute. **Zero network work.** Tap -> first remote frame ≈ **190 ms**.

### Privacy — what leaks, precisely

1. The ring carries the caller's candidates, so the **callee** learns the caller's IP before
   answering. Acceptable: the caller chose to call.
2. The callee's probes go to those candidates, so the **caller** learns the callee's IP and
   that the Mac is online and awake, **before consent.** This is the real leak. It turns a
   ring into a reliable presence-and-address oracle for anyone whose device key the callee
   has already accepted.
3. Even with no probes at all, delivery-vs-queue tells the caller the callee is online. That
   leak is inherent to presence and *is* the feature.

**Is relay-only-until-answer worth it? No.** It works — the callee probes only the caller's
TURN relay, so the caller learns Cloudflare's view and not the callee's address. But the
pre-warmed path is then the *relay* path, and promoting to direct on answer is a fresh
candidate race (164 ms measured) plus relay latency until it lands. It gives back most of the
win to close a leak that a better mitigation closes for free.

**The mitigation to ship instead:** probe only for rings whose `k` is already in the contact
list and whose `sig` verifies under it. A stranger's ring never probes and never leaks, because
it never reaches the UI layer at all (CONTACTS.md §7). The residual leak is then exactly
*"people you have already called can learn you are at your Mac and at address X"* — which is
the FaceTime/Signal contract and is what the feature is for. Plus one honest setting, **off by
default**: "Ring
without connecting first — slower to answer, doesn't reveal your address." Name the trade in
the UI rather than hiding it.

### Waste — and the one allocation that must not happen

- **Do not allocate TURN before answer.** `Turn.allocate` takes a 600 s LIFETIME
  (Turn.swift:81). Every ignored ring would burn one, and `/api/mac/turn` is capped at 20
  mints per 10 min per IP (`ICE_MINT_MAX` / `ICE_MINT_WINDOW_MS`). Fetching *credentials*
  early is free (13 ms); **allocating the relay waits for answer, or for the direct probes
  to fail.** Pre-warm's job is to prove the direct path, which is the case where TURN is not
  needed.
- Probe traffic: ~40 bytes × 4 candidates × 2 Hz × 30 s ≈ 10 KB. Negligible.
- A warmed room DO: one request, goes cold on its own. Negligible.
- The real waste is the callee's radio staying awake for a call nobody answers. Bound it:
  2 Hz, **30 s hard deadline** (a deadline, not a loop count — LAUNCH.md's named trap), and
  **stop the instant the ring is dismissed**, or a declined call leaves a live path open.

### Correctness — four cases, and the fourth is the dangerous one

1. **Never answered.** Both sides stop at the 30 s deadline. But `KIN_LEASE_MS` is 60 s, so a
   queued ring *outlives the ring window*: the poll fallback could drain a 55-second-old ring
   and start ringing for a caller who gave up 25 s ago. **The app must reject any ring with
   `ageMs > 30000`** — `kinPollDecide` already returns that field on every ring. This is
   `final-record-is-not-final`: a record that outlives the thing it describes. And if the
   caller re-rings while it waits, `KIN_RING_PER_KEY` is **4 per minute per (k,to)**: no faster
   than one press every 15 s, or the fifth inside a minute is a 429.
2. **Answers on a different network.** The pre-warmed candidates are dead. So answer is
   *"flip the pre-warmed path live IF proven, else run today's join unchanged"* — never a
   branch that only works when pre-warm succeeded. `Wire.unlockForRediscovery`
   (Net.swift:781) already exists for this. **The pre-warm is an optimisation with a
   mandatory fallback, and the fallback is today's code path byte for byte.** This is the
   single most important correctness rule here.
3. **Two rings at once.** The mailbox holds up to 8 (`KIN_BOX_MAX`) and a poll drains all of
   them destructively (`kinBoxTake`). Show the first verified ring, queue the rest as "also
   calling", and **pre-warm only the first** — two paths at once doubles the leak and the
   waste for a call that can only have one answer. Repeat rings already replace each other
   server-side (`kinBoxPut`) — but the replacement key is `(from, room)` and **not `k`**, so a
   caller that re-mints `from` or changes room takes a second slot instead of replacing its
   first.
4. **Callee is already on a call — pre-warm is FORBIDDEN.** `Stun.discover` (Stun.swift:49)
   and `TurnClient.roundTrip` (Turn.swift:199) both `recvfrom` on the media fd and both set
   `SO_RCVTIMEO`; `Wire.recvLoop` (Net.swift:879) is reading that same fd for the live call,
   started at main.swift:1758. LAUNCH.md's invariant 1 states it: **`wire.fd` has exactly one
   reader.** A pre-warm during a live call steals packets from the call in progress —
   intermittent, unattributable audio loss, exactly the failure that invariant names. So:
   show the ring, offer "Answer (leaves your current call)", and pre-warm only after teardown.
   There is one media socket; there is never a second live call.

### The cheaper design that gets most of the win — ship this one first

**Warm-only pre-warm.** On ring display the callee fires exactly one request:
`GET /api/room/<R>/warm`. Nothing else. The caller fires the same at press time.

- takes **~1100 of the ~2100 removable ms** in stage 5 — over half the win
- **zero** privacy leak: the callee talks to Cloudflare, which it already does; the caller
  learns nothing at all
- **zero** waste: one request, no allocation, no probe traffic
- **zero** server change: the route is deployed and the web app already uses it
- **zero** new failure modes: a failed warm is indistinguishable from not warming
- ~10 lines of Swift, and the 120 s residency I measured means one warm covers a 30 s ring
  window with 4x margin

The full candidate pre-warm buys the other ~1000 ms and costs a server change (see below), a
signed-payload version bump, a pre-consent address leak, and four new correctness cases.

**Recommendation: warm-only first, measured on its own. Candidate pre-warm second, and only
if the warm-only number proves the remaining gap is worth the leak.** These two do *not* hide
each other — they are sequential stages, not competitors for the same slack, which is the
condition that forced LAUNCH.md's items 1-4 to be measured together. Say so explicitly when
the results come in, or someone will invoke that lesson and bundle them wrongly.

### If candidate pre-warm is built: the server change it needs

`kinRingDecide` enforces an **exact-arity** field allowlist:
`keys.length !== KIN_RING_KEYS.size` is a hard 400, and that size is now **6**
(`to, from, room, sig, t, k`). An extra `cands` field is rejected today.

- relax to allowlist-with-optional; keep `KIN_RING_MAX_BODY` at 1024. Recomputed for the
  six-field ring: ~220 bytes typical (an 88-char Ed25519 `sig`, a 44-char `k`) and ~330 with
  every field at its regex maximum, so ~700 remain; four `ip:port` strings are ~120 bytes.
  Fits.
- **`cands` must be inside the signed string.** `sig` is the caller's Ed25519 signature over
  `"ring|"+to+"|"+from+"|"+room+"|"+t`, which the callee verifies against `k`. If candidates
  are unsigned, anything on the path can rewrite them and aim the callee's probes at an
  arbitrary host — a scanning and amplification primitive built out of a doorbell. Use a new
  tag, `"ring2|"+to+"|"+from+"|"+room+"|"+t+"|"+cands`, so an old ring cannot be replayed as a
  new one. `k` needs no place in that string: the signature verifies *under* it, so a swapped
  `k` is simply a signature that does not check out.
- keep `KIN_SIG_RE` as it is: it is deliberately length-bounded so "sig can never become a
  payload channel", and that property must survive.

---

## Ringing a Mac whose app is not open

`SMAppService`, `NSStatusBar`, `LSUIElement`, `launchAtLogin`: **zero hits** in
`mac/Sources/tk/*.swift`, `mac/bundle/Info.plist`, `mac/bundle/mkapp.sh`. There is no host
process for a doorbell. `LSMinimumSystemVersion` is 13.0, so `SMAppService` is available.

### 1. What runs — recommendation: `LSUIElement` + runtime promotion + a status item

**Not a separate helper.** CONTACTS.md §4(b) already rejected it and the decision holds — but
one of its reasons is **weaker** under device keys than it was under pair secrets, and saying
so is the honest version. The helper must verify every ring, which used to mean a second copy
of every PS; it now means a copy of the contact list, and those are **public** keys, not
secrets. What it does still need duplicated is `tok`, the mailbox poll credential, which is a
real one. The two reasons that carry the decision on their own are unchanged: it is a second
payload item, and `updater-ships-only-what-it-can-install` means it takes two releases to land
with the install half being the old version; and `tcc-identity-is-a-content-hash` — a second
binary is a second TCC identity needing its own Local Network grant.

**Recommendation:** `LSUIElement = <true/>` in `mac/bundle/Info.plist`, plus
`NSApp.setActivationPolicy(.regular)` at every site that opens a window, plus an
`NSStatusBar` item so the app is reachable while it has none. One binary, one signing
identity, one copy of the keys, and it ships in **one** release: `Update.installBundle`
explicitly writes `Info.plist` into installed bundles (Update.swift:143-147) and the modern
`swapBundle` path replaces the bundle whole.

**What it costs, and the failure mode it creates.** In accessory mode the app has no Dock
icon, no ⌘-Tab entry and no menu bar until the policy is promoted. Today the promotion sites
and the activation sites **do not match**:

```
main.swift:597      app.setActivationPolicy(.regular)   -- but INSIDE `if flag("window")`
Launcher.swift:307  app.setActivationPolicy(.regular)   -- Launcher.askRoom
Launcher.swift:513  app.activate(ignoringOtherApps:)    -- Launcher.askRoom (paired, OK)
Display.swift:187   NSApp.activate(ignoringOtherApps:)  -- NO POLICY SET
main.swift:2853     NSApplication.shared.activate(...)  -- NO POLICY SET
```

A normal call launch has no `--window` flag, so under `LSUIElement` **the call window itself
would appear with no Dock icon, no ⌘-Tab entry and no menu bar** — a window you cannot get
back to once it loses focus. This is `dead-controls-declared-never-wired` raised to the level
of the whole app. The plist change and the promotion fix are **one patch, never two**: order
is `setActivationPolicy(.regular)` *then* `activate`, or the menu bar does not appear.

**Named acceptance trap.** `LSUIElement` is evaluated by LaunchServices at *launch*. The
updater installs and then `execv`s, and an `execv` keeps the process's existing window-server
registration — so the first process after an update is still `.regular`. **You cannot verify
this change by updating; you must quit and relaunch.** A tester who updates, sees a Dock icon
and concludes it did not ship will be wrong. (The direction is benign — it fails toward
visible, not invisible.)

Do **not** use option 3, gating on "was I launched at login". The signal
(`NSApplicationLaunchIsDefaultLaunchKey`) requires an app delegate this app does not have
(LAUNCH.md: "No app delegate and no NSDocument here"), and if the gate is ever wrong at login
you get precisely the Dock-icon-and-focus-steal that is worse than having no feature. The
plist is a static fact; a runtime guess is not.

### 2. Asking permission

A silent login item is how an app gets uninstalled. Ask **at the end of the first successful
call with a contact you just named** — the moment the feature first means something, in the
same sheet as CONTACTS.md §2's "Who was that?", because both questions have one answer: *so
Meera can reach you.* Not at install (nothing to explain), not at first launch (no contacts).

> "Let Meera reach you? Kin will sit quietly in the menu bar so her call can ring this Mac.
> It uses no camera or microphone until you answer."  [Yes, let calls ring] [Not now]

**And read `SMAppService.mainApp.status` at every launch.** macOS 13 puts the toggle in
System Settings > General > Login Items and the user can flip it off without telling the app.
An app that assumes `register()` stuck will tell someone they are reachable when they are not
— a blind instrument reporting a negative. The status item must show the true state, and
`.requiresApproval` is its own message, not an error.

### 3. How the ring arrives — held socket, and skip long-poll entirely

`Room.signal` uses **plain `server.accept()`** on both its hold and upgrade paths, not
`state.acceptWebSocket`. Repo-wide grep for `hibernat|acceptWebSocket|webSocketMessage`:
**zero hits.** So a held socket on today's machinery keeps the DO resident, billed at a fixed
128 MB (COST-MODEL.md:29-31).

```
0.128 GB x 2,592,000 s/month = 331,776 GB-s per idle user
x $12.50/M GB-s              = $4.15 per idle user per month
free tier 400,000 GB-s       = 1.2 users
```

**One idle presence socket costs what ~4,400 ten-minute calls cost** (COST-MODEL.md:41 prices
a call at 75 GB-s). That is decisive.

| option | ring latency | idle server cost | battery | verdict |
|---|---|---|---|---|
| held WS, **non**-hibernatable (today’s code) | ~93 ms | **$4.15/user/mo**; free tier = 1 user | best — one connection, radio idle | **reject on cost** |
| held WS, **hibernatable** (new DO class) | ~93 ms | ~$0 idle; ~$0.02/user/mo of pings, or ~$0 with auto-response | best | **BUILD THIS** |
| long-poll (DO parks the GET 25 s) | ~93 ms + a ~127 ms gap between parks | same $4.15 — **a parked request cannot hibernate** | good | ~~reject; strictly worse than a WS~~ **SHIPPED — see the correction below** |
| fast poll (1 s) | mean 500 ms | 2.6M req/user/mo vs a 1M free tier | worst — a radio wake every second | reject |
| 5 s poll (deployed) | mean 2500, p95 4750 | 518k req/user/mo | poor | today; the thing being replaced |

**This corrects CONTACTS.md §4/§8**, which plans "V2 = long-poll … V3 = websocket only if
long-poll measurably is not enough." Long-poll delivers the *same* latency as a socket (in
both cases the client is already parked at the DO when the ring arrives) and carries the
*same* duration billing with no hibernation path ever. **Skip V2. V3 is the answer.**

> ### CORRECTION, 2026-08-25 — the long-poll row is priced against nothing
>
> **The row above rejects long-poll on a cost it shares with the row below it, and the
> disproof is four lines up this same page.** `DO stays resident after last request >= 120 s`
> — 5/10/20/30/45/60/90/120 s gaps, never cold, measured here. **A 5-second poll therefore
> never lets the object go cold**, so the deployed doorbell is already paying the whole
> $4.15/user/month of duration this table charges only to long polling. The two rows were
> priced on different axes: requests for one, duration for the other. Compared like for like
> against *what actually ships*, holding the request costs the **same duration and fewer
> requests** — the client's steady state is three 25 s holds and one plain re-read, so ~138k
> requests/user/month against 518k, both inside the free tier.
>
> So **long-poll is shipped**, and the verdict above is wrong only relative to today. Nothing
> it says about the hibernatable WebSocket changes: that is still the only option that makes
> an *idle* user free, and it is still worth building. But it is a **cost** project, not a
> latency one, and should be measured as one — the latency it buys over a held GET is zero,
> which this table already says.
>
> Measured after shipping, through two real `tk` processes, same binary both arms, against a
> local worker so the network leg is excluded and the poll interval is what is isolated. The
> before-arm is that same binary talking to a worker WITHOUT the endpoint — the committed
> `worker.ts` from this branch — so the before-number and the proof that the fallback fires
> are the same experiment.
>
> One matched pair, n=12 each:
>
> ```
> before (5 s poll)   min 115   median 1159   mean 1819   p95 4905   max 4905 ms
> after  (held GET)   min  14   median   17   mean   18   p95   25   max   25 ms
> ```
>
> **Quote the mean, not the median.** Twelve samples of a uniform 0–5000 ms distribution give
> a median that wanders — 1159, 1485, 2794, 3021 and 3302 ms across five runs of the before
> arm, all of the same thing. The mean is the stable statistic and it converges where theory
> says it must, on half a poll interval. Pooled across every run taken:
>
> ```
> before   n=57   mean 2346 ms      after   n=70   mean 21 ms      112x
> ```
>
> The number that changes the feel of it is not the mean anyway. It is the tail: the worst
> ring went from 4905 ms to 25 ms, because there is no longer an interval to be unlucky in.
>
> The "~127 ms gap between parks" the row charges long-poll is real but is not a latency
> cost: the mailbox is durable, so a ring landing in that gap is delivered by the next park
> rather than lost. And it is smaller than written — a poll that delivered a ring costs no
> arming budget on the server, so the client re-arms immediately instead of waiting out a
> rate window.
>
> **Two pollers, one handle.** The menu-bar resident and the open app both listen for the
> same person. That was already producing 429s, and it is worse than wasteful: a drain is
> destructive, so whichever poll returns first TAKES the ring and the other gets an empty
> answer — a ring could launch a second copy of the app while the copy already open shows
> nothing. The resident now stands down while the app is open, signalled by an exclusive
> `flock` the app holds for its life (`Identity.claimLine`). A lock dies with its holder, so
> a crashed app cannot leave this Mac uncallable — which a marker file or a pid file both
> allow, and which is the worse failure by a distance.

Build it as a **new `Doorbell` DO class, not a retrofit of `Room`.** `Room` holds eight
`WebSocket`-keyed maps plus `heldTimers`, `pendingLeaves` and `lastSeen` (the field block at
the top of the class), and every liveness rule lives in isolate-local `setTimeout` closures
with **zero `setAlarm` calls in the file.** Hibernating that means moving all of it, including
the 5 s `LEAVE_GRACE_MS` that exists because of the 37-drop saga. Not worth risking the live
call path for a presence feature. The kin mailbox, by contrast, is already hibernation-clean:
no sockets, no timers, and two durable rows — `kin_tok` and, since proof-of-possession,
`kin_key`.

Reuse from the web app what is already proven: **`?hold=1`** (the hold branch of
`Room.signal`) accepts a socket without admitting it, so a lurker occupies no slot and cannot
inject, and `{type:'join'}` flips it live in one RTT. That is exactly "answer is unmuting, not
connecting", already built and already measured ("the second joiner's 241 ms click->welcome
was the largest slice of click->connected", app.js:8412).

**Platform assumptions to verify before writing code** (compat date 2026-05-01; the repo uses
none of these today, so nothing here is proven in-tree):
`state.acceptWebSocket` + `webSocketMessage`/`webSocketClose`;
`state.setWebSocketAutoResponse` for ping/pong; `ws.getAutoResponseTimestamp()`.
If auto-response is unavailable, a 20 s ping costs ~130k requests/user/month — about 7 users
inside the free tier, then ~$0.02/user/month. Affordable either way, but auto-response is the
difference between "free" and "metered", so measure it rather than assume it. *Validate the
ruler first.*

### 4. The idle socket dies — and this hits presence harder than signalling

37 WebSocket drops were observed in this project, each one ending a call while media was
fine. A presence connection is idle **by definition**, so it meets this constantly. Worse,
the existing defence does not apply: `GHOST_MS` is 60 s, but its sweep lives inside
`evictAndCheckFull` and **runs only when the room is already at cap** — there is no timer. A
ghost is reaped only when a live person is at the door. On a doorbell there never is one, so a
dead socket would hold a registration forever and every ring to it would succeed into nothing.
The caller sees "no answer." That is `blind-instruments-report-negatives` and
`open-socket-is-not-a-live-peer` in the same line of code.

- **Keepalive 20 s**, client -> server, server replies. Not 25 s (the web app's value,
  app.js:6933): macOS timer coalescing and App Nap stretch a nominal interval, and this
  project has already been bitten by timer clamping. 20 s nominal that drifts to 25-30 s still
  fits twice inside a 60 s idle timeout, and it also keeps a UDP NAT binding alive should
  Architecture B ever be built.
- **The app must prove it is registered, never assume it.** The DO sends
  `{type:'hello', armed:true}` unsolicited on accept, and every pong carries the server's own
  view. Presence is `armed` only while a pong newer than 2x keepalive exists. Otherwise
  `unknown`. **Never `offline`.**
- **Reconnect: immediate first retry (0 ms)** — the common cause is a network transition and
  the right action is *now* — then 0.5, 1, 2, 4, 8 s, capped **30 s**, with ±25% jitter.
  Jitter is not decoration: without it a DO restart reconnects the entire installed base in
  lockstep. Cap at 30 and not 60 because the cap *is* the worst-case added ring latency for
  someone whose Wi-Fi just returned.
- **Server liveness must not be a 30 s alarm** — that is 86,400 alarms/user/month, worse than
  the pings it replaces. Evaluate staleness **lazily, at ring time**, from
  `ws.getAutoResponseTimestamp()`; handle `webSocketClose` for clean closes; run one
  garbage-collection alarm every few hours. Liveness = last-heard-from, never `readyState`.
  This is the inverse of `once-fired-probes-record-transients`: do not sample on a timer,
  evaluate at the moment of use.

### 5. Battery, sleep, and the ceiling that has no workaround

**A sleeping Mac cannot be rung. There is no mechanism.** APNs is the only thing that wakes a
sleeping Mac, APNs needs a paid Developer ID, and there is not going to be one
(`no-notarization-budget`). Power Nap does not resume arbitrary app sockets and must not be
designed around. **This is the ceiling of the feature and it should be said out loud rather
than engineered around with something fragile.**

What can be done, cheaply and honestly:

- One message on `NSWorkspace.willSleepNotification` so the server knows the difference
  between "asleep at 23:41" and "socket died". The caller then sees *"Asleep — she'll see you
  called"* instead of a lie.
- `KIN_LEASE_MS` is 60 s, so **a lid opened within a minute of the call still rings, late.**
  That is worth having and worth saying. Past 60 s it must become a missed-call row, which
  needs durable storage the mailbox deliberately does not have (`kinBox` is in memory; only
  `kin_tok` and `kin_key` are persisted) — a named gap, not a solved problem.
- On `didWakeNotification`, reconnect with **zero** backoff.
- Wi-Fi changes: `NWPathMonitor` and reconnect on the transition. Do not wait for the
  keepalive to time out — that is up to 60 s of falsely reading "unknown".

**Three UI states, and the third is the one that earns trust:**

- `reachable` — a pong newer than 2x keepalive. Just a name you can tap.
- `asleep` — a `willSleep` and nothing since. "Asleep — she'll see you called."
- `unknown` — no registration, stale last-heard-from, **or our own network is down**. "Not
  sure — ringing anyway." And *ring anyway*: the poll fallback may still land it.

That last clause matters. If the **caller** has no path to the server, presence for everyone
reads stale, and a naive UI would report the whole address book offline. The UI must
distinguish "I cannot see the server" from "she is not there" —
`control-plane-rides-its-own-resource`, where a health signal travels over the resource it
reports on and goes silent exactly when it matters.

---

## What the callee sees — the contract

Ringing UI belongs to another lane. This is the interface it can build against.

The ring delivers exactly the fields `kinPollDecide` puts in each `rings[]` entry:

```
k       43-44 char base64  the caller's Ed25519 public key — THE IDENTITY. Resolve to a local
                           name by looking `k` up in contacts.json; if it is not there, DROP
from    2-32 char name     ^[a-z][a-z0-9]{1,31}$ — a display name only. Unauthenticated and
                           free to mint, so it decides nothing; never key anything off it
room    8..64 chars        the rendezvous room, and an input to the crypto salt
t       unix seconds       integer; the 60 s skew gate (`KIN_SKEW_S`), checked first of all
sig     40..96 chars       Ed25519 over "ring|"+to+"|"+from+"|"+room+"|"+t, verified against
                           `k`; MUST verify before anything is drawn
ageMs   int                server-computed; REJECT if > 30000
cands   [ip:port, ...]     phase 2 only; absent in phase 1
```

Guarantees the window lane may rely on:

- **The window is only ever asked to appear for a ring whose `k` is a stored contact and whose
  `sig` verified under that key.** Unverifiable rings are dropped and counted before the UI
  layer. There is no "unknown caller" state to design.
- **Ring bytes -> photons: 100 ms budget.** Not 16 ms: in accessory mode this includes
  creating and compositing a window. Hard rule — **the first paint depends on nothing but the
  ring struct.** No network, no disk. The name comes from a `contacts.json` loaded at
  register time. LAUNCH.md measured a 2878 ms window that existed, was key, and showed
  nothing, because the main thread never returned to the run loop; that must not repeat here.
- **Visible above a fullscreen app**: floating window level, `.regular` policy, then activate.
- **Answer must work on the FIRST click while the app is not frontmost.** This project has a
  named failure for exactly this: `decoration-inside-a-control-eats-clicks` — `hitTest`
  returns the blur and `acceptsFirstMouse` is asked of *that* view, and "every glass button
  was dead while the app was behind." `acceptsFirstMouse` must be on the view that receives
  the hit test, and the acceptance test must be a synthetic click **with the app in the
  background** (`handler-tests-cannot-see-interaction-bugs`: the harness must CLICK).
- Timeout 30 s, expressed as a **deadline, not a loop count**, then close and leave a missed
  call.
- Ring tone via `NSSound`, deliberately **not** through the call audio graph
  (`audio-device-is-not-a-constant`: a hardcoded 48 kHz went silently deaf).

State cases:

- **Asleep** — cannot be rung; see above. Rings on wake if inside 60 s.
- **Locked / screen saver** — the app is running and the socket is up, but macOS will not put
  an app window over the login window. Play the tone, show the window behind the lock, let it
  appear on unlock. Do **not** record it as answered.
- **Do Not Disturb / Focus** — a *window* is not a notification, so Focus does not suppress
  it; that is precisely why CONTACTS.md §6 chose a window. Reading Focus state needs an
  entitlement this app does not have, so **do not attempt to detect it** — play the tone and
  let the system's own volume handle it. A per-contact "always ring" is a later ask.
- **Already on a call** — show the ring, **do not pre-warm** (the `wire.fd` single-reader
  invariant), and offer only "Answer (leaves your current call)" / "Not now".

---

## Anchors (by symbol; `main.swift` is being edited, re-resolve by name)

```
mac/Sources/tk/main.swift
  231, 246, 281   room decision / shouldPrompt / deep-link dedup
  591-597         `if flag("window")` + app.setActivationPolicy(.regular)   <- promotion site 1
  891             `if let room = arg("room") {`  -- the whole room block opens here
  937             creds = TurnClient.fetch()          (async, worker-only route, ~13 ms)
  941             mapped = Stun.discoverAny(fd:)      (4 ms measured; 1200 ms budget)
  949             tc.allocate(fd: wire.fd)            <- must NOT run before answer
  1007            let giveUp = Date().addingTimeInterval(120)
  1028            Rendezvous.exchange(...)            first exchange; fire /warm before this
  1068            let gap: Double = attempt <= 10 ? 0.1 : ...   join-loop backoff
  1143, 1178      Thread.sleep(forTimeInterval: 0.5)  candidate re-probe cadence   <- item 4
  1148, 1185      Rendezvous.exchange(...)            re-probe / slow refresh
  1719            let cryptoSalt = arg("secret") ?? arg("room") ?? ""
  1729            Thread.sleep(... c.established ? 5.0 : 0.25)  handshake cadence  <- item 4
  1758            Thread { wire.recvLoop(into:video:) }   <- the single reader of wire.fd
  2853            NSApplication.shared.activate(...)  <- NO POLICY SET

mac/Sources/tk/Launcher.swift
  21 lastRoomKey · 48 mintRoom · 147 pumpAppKit · 186 runPumping · 284 remember
  302 askRoom · 307 setActivationPolicy(.regular)  <- promotion site 2 · 513 activate

mac/Sources/tk/Display.swift
  187  NSApp.activate(ignoringOtherApps:)  <- NO POLICY SET; the asymmetry to fix

mac/Sources/tk/Stun.swift
  28 server list · 32 Stun.discoverAny · 49 Stun.discover (recvfrom on the media fd)
  136 localIPv4 · 170 Rendezvous.Peer · 173 Rendezvous.exchange (timeoutInterval 8, sem 10)

mac/Sources/tk/Turn.swift
  29 relayed · 38 TurnClient.fetch · 68 allocate · 81 LIFETIME 600
  91 REQUESTED-TRANSPORT 0x0019 (present now) · 199 roundTrip (800 ms) · 365 RelayBox

mac/Sources/tk/Net.swift
  320 Wire · 334 sendHandshake · 378 socket · 607 setPeer · 629 addCandidate
  644 probeAllCandidates · 691 notePath · 781 unlockForRediscovery · 879 recvLoop

mac/Sources/tk/Update.swift
  143-147 installBundle writes Info.plist  <- why LSUIElement ships in ONE release
  317 repairBundleIfStale · 438, 485 commit re-execs CommandLine.arguments verbatim

mac/bundle/Info.plist        14 keys; LSUIElement ABSENT; CFBundleExecutable pinned to "Tokkah"
                             (Info.plist:20-29 — renaming bricks every installed copy)

tape-app/src/worker.ts      SYMBOLS ONLY — this file is under active edit; every line number
                            this section once carried was wrong within days
  Room.fetch                the /kin/* handlers MUST return before the signal() fallthrough,
                            which answers 426 to anything with no upgrade header
  Room.kinRegister/kinRing/kinPoll   the four-line DO wrappers around the pure deciders
  Room.warm                 the prewarm route; 200-with-a-body, deliberately not 204 (item 3)
  Room.rendezvous           /rv; registers a peer only inside `if (addr)` (item 5)
  Room.signal               plain server.accept() on the hold and upgrade paths — NOT
                            hibernatable; the ?hold=1 branch is the predial primitive
  Room.admit                shared admission: role, caps, relay listener, welcome
  evictAndCheckFull         GHOST_MS 60_000, swept ONLY on the room-full path, never on a timer
  LEAVE_GRACE_MS 5000       the 37-drop saga
  Room's field block        peers · laneCaps · pcmCaps · pcmFrameCaps · sids · geo · vers ·
                            held + heldTimers · pendingLeaves · lastSeen; the ping/pong reply
                            lives in the relay listener and the server sends no pings of its
                            own; ZERO setAlarm calls anywhere in the file
  Room.kinBox / kinHits     the mailbox and its rate windows, both IN MEMORY
  Room.kinTokLoad/kinKeyLoad  kin_tok + kin_key — the only durable rows the feature adds
  KIN_ROUTE_RE              edge dispatch -> ROOM.idFromName('inbox:' + handle); still no
                            locationHint (item 6)
  KIN_HANDLE_RE             ^[a-z][a-z0-9]{1,31}$ — must agree with KIN_ROUTE_RE's capture
                            group character class for character class (contacts.test.mjs b3)
  KIN_LEASE_MS 60_000 · KIN_BOX_MAX 8 · KIN_POLL_GAP_MS 2000 · KIN_SKEW_S 60
  KIN_RING_MAX_BODY 1024 · KIN_REG_MAX_BODY 512
  KIN_RING_KEYS             SIX fields: to, from, room, sig, t, k
  KIN_REG_KEYS              five fields: to, tok, k, t, sig
  KIN_SIG_RE                the ring sig, 40..96 — length-bounded on purpose; leave it alone
  KIN_KEY_RE · KIN_REG_SIG_RE   exact lengths, because unlike the ring sig these ARE decoded
  KIN_REG_CONTEXT           'kin-reg-v1|', the version prefix of the signed registration
  KIN_RING_PER_KEY 4 · KIN_RING_PER_FROM 4 · KIN_RING_PER_TO 12 · KIN_RING_PER_TO_HOUR 60
  KIN_REG_PER_MIN 10 · KIN_BAD_AUTH_PER_MIN 30
  kinRingDecide             skew FIRST, then the EXACT-ARITY allowlist (what blocks `cands`);
                            the server verifies no ring signature, by design
  kinPollDecide             immediate return, pollMs 5000, ageMs, and `k` handed back out
  kinRegisterDecide         skew -> verify sig under the presented k -> first-writer-wins on
                            the KEY; 403 taken vs 401 no, kept tellable apart
  kinVerifyEd25519          KIN_ED_ALGS = 'Ed25519' then 'NODE-ED25519'
  kinBoxPut / kinBoxTake    replace-on-(from,room), evict-oldest-at-cap; destructive drain
  KIN_EDGE_CAP              per IP per hour: ring 240, poll 20_000, register 120
  ICE_MINT_MAX 20 / ICE_MINT_WINDOW_MS 10 min    the /api/mac/turn mint cap

tape-app/public/app.js
  6933 pingSec 25 · 6945-6963 3-missed-pong watchdog
  8386-8408 prewarmRoom + the measurement that justifies it · 8412-8428 predialWs(?hold=1)
```

---

## What I would build first, given one day

**Items 3 and 5: fire `/warm` the instant the room name is known, and make the first `/rv`
exchange a read-only query concurrent with STUN.** One edit, in one place (the room block at
main.swift:891), no server deploy, no new failure mode.

Why this and not the presence socket, which is a bigger number: the socket is a new
hibernatable DO class plus a first-ever Swift WebSocket client (`URLSessionWebSocketTask`
appears nowhere in the tree) plus a liveness protocol — days, not a day. Whereas `/warm`:

- takes **~1100 ms** of the 2907, the largest item reachable in a day
- **helps today's calls immediately**, before any of the contact feature exists — the room
  name is known at `Launcher.mintRoom()` (Launcher.swift:48) or deep-link parse, ~200 ms
  before the first exchange
- is the same primitive the pre-warm design needs later, so it is not throwaway
- has a deployed server route and a working precedent to copy (app.js:8404)

### The measurement that would prove it, on a live prod call between two Macs

Live prod only (`test-on-live-calls-only`), real sensors, two Macs, `room.tokkah.com`.

1. **Noise floor first, same session.** Default vs default, n=5. My measurement says DO cold
   start alone ranges **883-2604 ms**, so the noise floor on press->connected is **~900 ms or
   worse.** State it before the A/B, or the A/B is uninterpretable.
2. **Primary metric: press -> `connected via`.** Baseline is n=1 today (2907 ms). **A single
   run cannot detect an 1100 ms effect against a 900 ms spread.** n>=5 per arm, compare
   **medians**, arms rotated A/B/A/B (`windowed-metrics-smear-experiments`: a 30 s average
   once inverted a result here).
3. **Secondary metric, and the one the user actually feels: tap -> first remote frame.**
   Measure this separately. Press->connected is dominated by the human's answer time, so a
   win inside that window is *invisible* on the primary metric. Measuring only the wrong
   interval would make a correct change read as nothing.
4. **Prove the flag is not a no-op** (`silent-no-op-flags`, which has already cost this
   project three A/Bs): assert the warm request appears in the app's own stderr, and that
   `TK_NO_WARM=1` makes it **absent**. Refuse the flag if unknown.
5. **Validate the ruler** (`validate-the-ruler-against-known-inputs`): run one arm against a
   room warmed by hand 5 s earlier (`curl .../warm`). That arm **must** be as fast as the warm
   arm. If it is not, the instrument is not measuring cold start and the result is void. Also
   run one arm on a room used 30 s ago — my sweep says it is still resident, so warm must
   show **no** effect there. Two inputs the ruler must rank differently.
6. **Regressions that mean it is wrong:** `path: direct` still, loopback rtt ~8-9 ms, m2e p50
   ~18-20 ms. A warm that raced the `/rv` publish into `path: relay` would be a loss wearing
   a win's numbers (`rate-control-hides-quality-wins`).
7. **Rig hazard:** each launch mints one TURN credential and `/api/mac/turn` caps at 20 per
   10 min per IP. A full pass is ~11 mints; a second pass inside 10 minutes gets 429s, TURN
   silently becomes "no credentials", and the timing profile changes between before and
   after. Space passes >= 10 min.

## Open questions that are the user's, not mine

1. **`LSUIElement` changes what the app *is*** — a background agent that becomes a window,
   rather than an app. That is the right shape for a phone, and it is a product decision, not
   a technical one. The technical part (one release, one patch, the Display.swift:187
   asymmetry) is settled above.
2. **Architecture B (direct UDP ring) is the only path under 10 ms, and I recommend against
   it — for now.** It saves 85 ms, which is the smallest item on the ranked list, and it
   carries the largest privacy cost in the document plus a permanently bound UDP socket with
   its own failure modes. Build it only if, after items 1-5, press->media is genuinely
   dominated by the ring. It will not be. If the 10 ms number matters as a *goal* rather than
   as a feeling, this is the conversation to have.

---

## The watcher made the app unlaunchable

Found 2026-08-25 from a user report: double-clicking Kin gave

> The application "Kin" is not open anymore.

every time, forever — not intermittently. Closing the call window and reopening
reproduced it immediately.

**Cause.** `Watch.run` opened with

```swift
NSApplication.shared.setActivationPolicy(.prohibited)
```

to keep the watcher out of the Dock. Reaching `NSApplication.shared` connects the
process to the window server, and *that* is what registers it with LaunchServices
as a running instance of `com.tokkah.tk`. From then on the bundle looks already
open, so a double-click does not launch anything — it sends `kAEReopenApplication`
to the instance LaunchServices believes is running. That instance is
`while true { poll; sleep }` on the main thread and never pumps an event queue, so
the event is never answered, LaunchServices times out, and Finder reports the app
as gone.

`open -n` worked throughout, which is the tell: `-n` means *new instance, do not
reuse the running one*.

**Fix.** Not to answer the event — to stop claiming to be the app. The watcher
needs no AppKit at all: it polls over HTTPS and spawns `open`. With the line gone
(and `import AppKit` with it, so the invariant is the compiler's) the process never
registers, a double-click finds nothing running and launches normally, and there is
no Dock icon to suppress because there is no application object to give it one.
The activation policy was solving a problem it created.

**Verified.** Open → close → open → close → open, watcher running throughout: three
fresh call windows, `rc=0` each time. `lsappinfo find bundleid=com.tokkah.tk`
returns nothing while only the watcher runs, and returns `"Kin" (in front)` once a
call window is up. The watcher's own log still shows
`watch: listening for calls to @devesh every 4000 ms`.

**The general shape.** A background helper that shares its parent's bundle
identifier must never touch AppKit. The moment it does, it becomes the app as far
as the system is concerned — and it is exactly the process least able to behave
like one.
