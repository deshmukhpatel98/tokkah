# The 150 ms budget — anywhere on earth to anywhere on earth

Goal set 2026-08-14: **any call, anywhere to anywhere, under 150 ms**, with audio
lossless and video visually lossless. 150 ms is ITU-T G.114's threshold — below
it conversational delay stops being noticeable and turn-taking feels natural.

This file is the governing budget. Every latency decision gets scored against it.

## The physics, first

Light in standard single-mode fibre travels at c/1.468 ≈ **199,862 km/s**. Real
routes are not straight lines: submarine cables land where geography and politics
allow, so the fibre path runs **1.25× (good) to 1.5× (typical)** the great circle.

| Route | great circle | prop @1.25× | prop @1.5× | device budget left |
|---|---|---|---|---|
| Mumbai → San Jose | 13,553 km | **84.8 ms** | 101.7 ms | 48–65 ms |
| Mumbai → London | 7,192 km | 45.0 ms | 54.0 ms | 96–105 ms |
| Sydney → San Jose | 11,964 km | 74.8 ms | 89.8 ms | 60–75 ms |
| Sydney → London | 16,994 km | 106.3 ms | 127.5 ms | 22–44 ms |
| São Paulo → Tokyo | 18,537 km | 115.9 ms | 139.1 ms | **11–34 ms** |

**The hard wall:** a truly antipodal pair (~20,000 km great circle) costs ≈125 ms
of pure propagation at *best-case* routing and ~150 ms at typical routing. No
device pipeline, however perfect, buys that back. "Anywhere to anywhere" is
therefore achievable for the overwhelming majority of real routes and is
physically impossible for the exact antipode — and the honest target is stated
that way rather than quietly dropped.

## Where we stand today

Measured on loopback (network ≈ 0), so these ARE the device pipeline:

| Path | measured |
|---|---|
| audio mouth-to-ear | **48 ms** |
| video glass-to-glass (remote) | **56–59 ms** |
| video glass-to-glass (self view) | 27.1 ms fake-cam / 44.1 ms real-cam |

Add the propagation column and the picture is not far off:

  Mumbai→San Jose @1.25×:  85 + 48 = **133 ms** audio, 85 + 57 = **142 ms** video
  Mumbai→San Jose @1.5×:  102 + 48 = 150 ms audio, 102 + 57 = 159 ms video

**So the target is already met on a major long route IF the path is near the
physics floor, and missed if the path wanders.** That single fact sets the
priority order below.

## Priority order (biggest lever first)

1. **Routing efficiency.** 1.5× → 1.25× on a 13,500 km route is worth **17 ms**;
   on Sydney→London it is **21 ms**. That is more than any plausible win inside
   the encoder, and it is bought with infrastructure rather than invention.
   Cloudflare's private backbone exists precisely to skip congested public
   peering, and TURN over it is already live on every call. The usual assumption
   that "a relay is always slower than P2P" may INVERT on very long paths —
   a relayed hop over a good backbone can beat a direct path over a bad one.
   This is a measurable hypothesis and it is hypothesis #1.
2. **The audio pipeline (48 ms).** Frame granularity, ring depth, output latency.
   Lossless is non-negotiable, so this is about scheduling, not compression.
3. **The video pipeline (56–59 ms).** Capture cadence, encode (~6.4 ms p50
   measured), decode, present. Visually lossless is non-negotiable.

## The blocking problem

Every latency number above was measured on **one laptop against a simulated
network**. Not one real long-distance call has ever been measured. Until a real
cross-planet call can be made ON DEMAND, none of the three levers can be scored
— including whether routing is 1.25× or 1.5× in practice, which is the whole
ball game.

Building that capability is therefore step one, and it is what the real-path
telemetry (icePath / iceProto / iceRttMs, shipped 2026-08-14) begins to answer
for calls that happen in the wild.

## First planet-scale measurements (2026-08-14, from Delhi / colo DEL)

This machine sits in India on Cloudflare colo **DEL** — which makes it the hard
endpoint for free. `/api/probe?region=` pins a Durable Object on a named
continent and times a round trip **from the edge**, so the client's own access
link is excluded rather than baked in.

| region | assumed site | km from DEL | ideal RTT @1.25× | measured RTT | ratio |
|---|---|---|---|---|---|
| apac | Singapore | 4,142 | 51.8 ms | **81 ms** | 1.56× |
| oc | Sydney | 10,428 | 130.4 ms | **186 ms** | 1.43× |
| sam | São Paulo | 14,428 | 180.5 ms | **261 ms** | 1.45× |
| afr | Johannesburg | 8,042 | 100.6 ms | 197 ms | 1.96× |
| wnam | San Jose | 12,416 | 155.3 ms | 303 ms | 1.95× |
| enam | Ashburn | 12,048 | 150.7 ms | 323 ms | 2.14× |
| weur | London | 6,712 | 84.0 ms | 202 ms | 2.41× |
| eeur | Warsaw | 5,264 | 65.8 ms | 162 ms | 2.46× |
| me | Dubai | 2,205 | 27.6 ms | 264 ms | **9.57×** |

**Read the outliers as instrument error, not physics.** `locationHint` is
ADVISORY. The Middle East ratio of 9.57× is proof the hint was not honoured —
Dubai is 2,205 km away and no real path costs 264 ms — so that DO landed on
another continent, and by the same logic the weur/eeur/afr rows are suspect too.
Only the low ratios can be trusted, because a number cannot come in BELOW the
speed of light by being mis-placed.

**Two calibration facts:**
1. An UNHINTED DO answers Delhi in **104–108 ms**, which is *slower* than the
   apac-hinted one (81 ms). Durable Objects are not placed in India at all —
   worth knowing on its own, since it is the signalling path for every Indian
   user (media is P2P, so this costs connect time, not call latency).
2. Taking Singapore as the reference, DO dispatch overhead is ≈ 81 − 51.8 =
   **~29 ms**. Subtracting it: **oc = 1.20× and sam = 1.29× the speed of light
   in fibre.**

**That is the headline, and it is good news.** Where placement is honest,
Cloudflare's fabric runs at 1.2–1.3× the physics floor, comfortably better than
the 1.5× typical-routing assumption the budget was drawn against. On the
Mumbai→San Jose case that is the difference between a 133 ms call and a 150 ms
one.

**Caveat that keeps this honest:** a Durable Object round trip is Cloudflare's
CONTROL plane — internal RPC and DO dispatch — not a UDP media path. These
numbers bound what the backbone can do; they do not prove what a WebRTC call
gets. Only a real peer on another continent settles that.

## Next: a real peer on another continent

Cloudflare Containers are enabled on this account (an ML fleet, `tokkah-lab`,
4 vCPU / 12 GiB, already runs there), and container instances are bound to
Durable Objects — so the same `locationHint` that pinned these probes can pin a
container running headless Chrome. India ↔ that container is a real
cross-planet WebRTC call, on demand, as many times as we want.

## The first mile is nearly free (measured, real UDP)

`testbed/stun-rtt.mjs` speaks actual STUN over UDP — the same protocol, port and
servers WebRTC itself uses to find a path — so the number is the one a call pays
rather than a TCP proxy for it. From Delhi:

| server | min RTT | p50 | p95 | loss |
|---|---|---|---|---|
| stun.cloudflare.com | **5.37 ms** | 8.86 ms | 24.59 ms | 0% |
| stun.l.google.com | 5.01 ms | 8.83 ms | 19.33 ms | 0% |

**~2.7 ms one way to leave the building.** The access link was a suspected term
in the budget and it is not one. Both vendors land equally close, so this is the
local ISP's distance to a peering point, not a Cloudflare-specific advantage.

## The budget, with every term now measured

first mile 2.7 ms one-way (STUN, real UDP) · backbone 1.25× the speed of light
in fibre (DO probe, dispatch overhead subtracted) · pipeline 48 ms audio /
57 ms video (loopback, so network ≈ 0 and these ARE the device cost)

| route | km | propagation | + first mile | AUDIO | VIDEO | verdict |
|---|---|---|---|---|---|---|
| Delhi → Singapore | 4,142 | 25.9 | 31.3 | **79.3** | **88.3** | both pass |
| Delhi → London | 6,712 | 42.0 | 47.3 | **95.3** | **104.3** | both pass |
| Delhi → Sydney | 10,428 | 65.2 | 70.6 | **118.6** | **127.6** | both pass |
| Delhi → Ashburn | 12,048 | 75.4 | 80.7 | **128.7** | **137.7** | both pass |
| Delhi → San Jose | 12,416 | 77.7 | 83.0 | **131.0** | **140.0** | both pass |
| Delhi → São Paulo | 14,428 | 90.2 | 95.6 | **143.6** | 152.6 | audio only |

**The 150 ms goal is reachable on every major route with the code that exists
today** — provided the media path achieves the 1.25× the backbone demonstrably
does. The one failure is video on the near-antipodal route, and it misses by
2.6 ms.

### Which turns the goal into two specific pieces of work

1. **Cut the video pipeline from 57 ms to under 54 ms.** That is the exact
   figure that clears every route in the table, including São Paulo. Three
   milliseconds, and the whole planet fits. Encode is 6.4 ms p50 measured, so
   the rest is capture cadence, present scheduling and decode — and none of it
   requires giving up visually-lossless.
2. **Prove the path.** Everything above assumes a real call routes as well as
   Cloudflare's backbone. Public-internet P2P between two consumer ISPs often
   does NOT — 2× is common, which would put San Jose at ~180 ms and fail. This
   is the central bet:

   > **Hypothesis #1: on long paths, relaying through Cloudflare's backbone
   > BEATS direct P2P**, inverting the usual assumption that a relay is always
   > worse. TURN is already live on every call, and `icePath` / `iceRttMs`
   > telemetry now records which path each real call took and what it cost.

The instrument to settle it is a real peer on another continent. Containers are
enabled here and are bound to Durable Objects, so the same `locationHint` that
pinned these probes pins a container — but the account has no browser image and
this machine has no Docker, so that image has to be built before the experiment
can run. That is the next blocking step, not a conceptual one.

## The video pipeline is 45 ms, not 57 — and every route already fits

Measured on live prod calls, current build (the 56–59 ms figure came from older
HANDOFF notes and no longer describes this code):

| arm | cap→read | encode | fullAge p50 | present p50 | **glass-to-glass** |
|---|---|---|---|---|---|
| `vpd=2` (shipped) | 0.1 ms | 3.0 ms | 23.2 ms | 22.2 ms | **45.4 / 45.0 ms** |
| `vpd=1` (one slot) | 0.1 ms | 3.0 ms | 22.9 ms | 10.4–14.7 ms | **37.6 / 34.3 ms** |

Re-running the budget with the real 45 ms number, the "3 ms short" problem
disappears — **every route in the table clears 150 ms on the shipped build**:

    Delhi → São Paulo (14,428 km, near-antipodal):  95.6 + 45 = 140.6 ms
    Delhi → San Jose:                               83.0 + 45 = 128.0 ms

### A 9.2 ms saving is available, and it is NOT yet earned

Dropping the presenter anchor from two slots to one takes glass-to-glass from
45.2 ms to 36.0 ms — present lag falls 22.2 → 10.4 ms, which is exactly the one
frame interval predicted, servo-pulled.

**But the anchor is not overhead, it is the fix for a complaint.** It exists
because the operator reported "remote rendering very far off self-view
smoothness", and it is bought with a cadence gate: remote IPI p99 within 1.5× of
self-view. `call.mjs` does not print IPI, so this A/B measured the thing the
change WINS and not the thing it SPENDS. Taking the 9.2 ms on that evidence
would be trading away a fix the user asked for, to buy margin the budget above
says we do not currently need.

Held at `vpd=2`. The flag ships so the trade can be priced properly: re-run with
IPI p50/p95/p99 captured from the snapshot on both arms, and spend the 9.2 ms
only if the cadence gate still holds — or if a real long path turns out worse
than 1.25× and the margin is actually needed.

## HYPOTHESIS #1 CONFIRMED: the relay is the shortcut

`testbed/route-efficiency.mjs` times TCP handshakes to REGION-PINNED cloud
endpoints (AWS regional hostnames resolve into that region's own address space,
unlike a STUN or CDN probe which answers from the nearest edge and measures only
the local ISP). Minimum of 7, because the floor is the path and everything above
it is queueing.

**Public internet, measured from Delhi:**

| site | km | straight-line RTT | measured RTT | vs light |
|---|---|---|---|---|
| Singapore | 4,142 | 41.5 ms | 71.6 ms | 1.73× |
| Sydney | 10,428 | 104.4 ms | 163.5 ms | 1.57× |
| N. Virginia | 12,048 | 120.6 ms | 227.7 ms | 1.89× |
| N. California | 12,416 | 124.2 ms | 252.5 ms | 2.03× |
| London | 6,712 | 67.2 ms | 143.6 ms | 2.14× |
| Oregon | 11,562 | 115.7 ms | 270.6 ms | 2.34× |
| São Paulo | 14,428 | 144.4 ms | 346.8 ms | 2.40× |
| Tokyo | 5,834 | 58.4 ms | 142.9 ms | 2.45× |

**Median 2.14× the speed of light in fibre. Cloudflare's backbone, same
yardstick: 1.20–1.29×.** The public internet from India is roughly TWICE as long
as the glass it runs on.

### What that does to the goal

| route | direct P2P (video) | relay over backbone | winner |
|---|---|---|---|
| Singapore | 80.8 ms | **76.3 ms** | relay |
| Tokyo | 116.5 ms | **86.9 ms** | relay |
| London | 116.8 ms | **92.3 ms** | relay |
| Sydney | 126.8 ms | **115.6 ms** | relay |
| N. Virginia | 158.8 ms ✗ | **125.7 ms** | relay |
| N. California | 171.2 ms ✗ | **128.0 ms** | relay |
| Oregon | 180.3 ms ✗ | **122.7 ms** | relay |
| São Paulo | 218.4 ms ✗ | **140.6 ms** | relay |

**Direct P2P clears 150 ms on 4 of 8 routes. Relaying clears it on 8 of 8, and
wins on every route including the short ones.**

This is the opposite of the rule every WebRTC stack is built on. A relay is
normally a penalty — an extra hop, taken only when NAT leaves no choice, and
ICE priority is defined to avoid it. Over 12,000 km that logic breaks: the extra
hop buys a private backbone, and a straight line on a good road beats a detour
on a bad one. The relay is not the long way round. It IS the short way.

**Honesty about what is measured vs modelled.** The P2P column is measured
(TCP RTT over the real public internet). The relay column is MODELLED from two
measured terms — first mile 2.7 ms one-way (STUN, real UDP) and backbone 1.25×
(DO probe) — plus the assumption that TURN itself adds little. The direction is
strongly evidenced; the exact figures still need a real relayed call to confirm,
and the far-side first mile is assumed equal to ours.

Caveat on the short routes: a TCP handshake carries fixed cost that inflates the
ratio more when the distance is small, so Tokyo's 2.45× overstates the routing
loss. The long-haul numbers (2.0–2.4×) are the ones that matter, and they are
where the goal is won or lost.

### Which makes the engineering direction concrete

Prefer the relay on long paths. ICE will not do this by itself: candidate
priority is specified to rank host and server-reflexive ABOVE relay, so the
stack will choose the slow direct route precisely when the fast relayed one
matters most. The work is to measure both and pick by latency instead of by
category.

## What a relay actually costs (measured, `?ice=relay` on a live prod call)

The relay column above was modelled. This prices its two components on a real
call — loopback, so the only thing that changed is the path.

| | direct (control) | forced relay |
|---|---|---|
| lane baseRtt | ~0.3 ms | **6.78 / 6.98 ms** |
| mouth-to-ear | 48 ms | 65.5 / 67.8 ms |
| glass-to-glass | 45.4 / 45.0 ms | 53.7 / 45.0 ms |
| jitter buffer depth | ~20 ms | **37.3 / 34.9 ms** |

**The raw path cost is small and the model was right:** 6.6 ms of added RTT is
**~3.3 ms one way**, against the 2.7 ms predicted from the STUN first mile. TURN
itself adds well under a millisecond; almost all of it is the trip to the edge.

**But the buffer amplifies it 2.3×.** Mouth-to-ear rose ~18 ms, not ~3 ms,
because the jitter buffer grew from ~20 ms to ~37 ms in response. That is the
adaptive depth doing its job on a path it reads as worse.

**Loopback overstates this badly, and the reason matters.** Here the relay
competes against a 0.3 ms direct path — a route no real call ever has. On a
Delhi→California call the direct path is ~250 ms RTT over public internet with
public-internet jitter, while the relayed path is ~155 ms over a private
backbone. The buffer would then grow on the DIRECT arm and shrink on the
relayed one, so the amplification runs in the relay's favour rather than
against it. Nothing here contradicts the 8-of-8 result; it does mean the margin
on short paths is thinner than the model implies, which is exactly why the
eventual policy must pick by measured latency and not force relay everywhere.

**A lever worth its own arc:** 6.6 ms of RTT bought 15 ms of buffer. The jitter
buffer is that sensitive, so on real paths its behaviour may matter as much as
the route. Worth measuring before it is tuned.

## Status of the end-to-end proof (open)

The relay result is measured on one side and modelled on the other, so it is not
yet fact. Closing it needs a real browser on another continent. Progress and the
exact obstacle, so the next attempt starts where this one stopped:

- Containers are enabled on the account, and instances bind to Durable Objects —
  so the same `locationHint` that pinned the region probes pins a container.
  Placement is honoured for wnam/enam/sam/oc and demonstrably ignored for `me`.
- This machine has no Docker, podman, colima or brew, so `wrangler containers
  build` cannot run here.
- Using a ready-made public image instead of building one was rejected:
  `mcr.microsoft.com/playwright:v1.49.0-noble` → `IMAGE_REGISTRY_NOT_CONFIGURED`.
  `wrangler containers registries configure <domain>` is the intended fix and
  insists on `--secret-name` even with `-y`; whether a public no-auth registry is
  accepted at all is the open question.
- A path that needs no image: the existing ML fleet's runner execs Python fetched
  from its coordinator at boot, so a job can `pip install playwright` and pull
  Chromium at runtime. The container's network is outbound-only, which WebRTC
  handles through STUN/TURN.

Until that runs, the honest statement of where the goal stands is: **the budget
says it is met on 8 of 8 routes via the backbone, on the build already shipped,
and half of that claim is measured.**

## CORRECTION: the 8-of-8 relay result was wrong

The section above compared a MODELLED relay path against a MEASURED direct one,
and the model was over-generalised. I took 1.25× from the two best-placed
regions (oc, sam) and applied it to every route — but the wnam probe measured
1.95×, not 1.25×. A best case generalised into a rule, then scored against
reality. That is the same error this project keeps catching in its rigs, made
here in analysis instead.

Measured against measured (Cloudflare DO RTT less the ~29 ms dispatch estimate,
versus direct public-internet TCP RTT):

| site | Cloudflare | direct | winner |
|---|---|---|---|
| Singapore | 52 ms | 71.6 ms | Cloudflare by 19.6 |
| Sydney | 157 ms | 163.5 ms | Cloudflare by 6.5 |
| São Paulo | 232 ms | 346.8 ms | **Cloudflare by 114.8** |
| London | 173 ms | 143.6 ms | direct by 29.4 |
| N. California | 274 ms | 252.5 ms | direct by 21.5 |
| N. Virginia | 294 ms | 227.7 ms | direct by 66.3 |

**Cloudflare wins 3 of 6, not 8 of 8. And on the US routes neither path reaches
150 ms**: N. California is 182 ms via Cloudflare and 171 ms direct, against a
45 ms video pipeline.

### What survives the correction

- The public internet really is ~2.14× the speed of light from Delhi. Measured.
- Every pipeline number stands: 48 ms audio, 45 ms video, 5.4 ms first mile,
  3.3 ms relay path cost. Measured.
- Routing efficiency really does vary enormously by destination — São Paulo
  differs by 115 ms between the two paths. **Which path is faster is a
  per-route question with no general answer**, which kills "always relay" just
  as firmly as it killed "never relay".

### What this does to the goal

On the routes that matter most (India↔US), **the goal is currently NOT met by
either path** — roughly 170–190 ms against a 150 ms target, so ~25–40 ms short.
The gap has to come from somewhere real:

1. A better path than either measured here. Neither column is a fair proxy for
   TURN media: a DO round trip is control-plane RPC, and TURN is lean UDP
   forwarding at the edge. The relayed media path may well beat both, and that
   is now an open question rather than a settled one.
2. The jitter buffer, which turned 6.6 ms of RTT into 15 ms of depth. On a
   250 ms path its behaviour is worth more than it is on loopback.
3. The 9.2 ms sitting behind `?vpd=1`, if the cadence gate allows it.

The honest status of the goal: **met comfortably on Asia-Pacific routes, close
on Sydney, and ~25–40 ms short on India↔US, which is the route the operator
actually cares about.**
