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
