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

## Where the missing 25–40 ms cannot come from

The India↔US shortfall has to be found somewhere, so it is worth recording which
doors are already shut.

**Audio is at its floor.** The 48 ms decomposes as ~20 ms AudioContext
outputLatency + ~16 ms jitter target (2 frames) + ~8 ms framing. Each was
already won: a live A/B (2026-08-11, 3 calls/arm) took the latency hint to the
floor, which cut outputLatency 26 → 20 ms and halved arrival spread, letting the
jitter target settle at 2f instead of 3f — mouth-to-ear 62.6 → 45.6 ms. The
remaining 20 ms is the operating system's output buffer, not ours, and the 16 ms
is two 8 ms frames. Neither yields 25 ms without going lossy, which the goal
forbids.

**Video has ~9 ms available** behind `?vpd=1`, gated on the cadence check.

So the device pipeline cannot close a 25–40 ms gap. **The gap has to come from
the path** — which makes the unresolved question the only question:

> Neither measurement taken so far is a real media path. A Durable Object round
> trip is heavyweight control-plane RPC; a TCP handshake to AWS is the public
> internet to a third party. TURN media is lean UDP forwarding between two
> Cloudflare edges, and it has never been measured on a long route. It may be
> materially faster than both columns — or it may not — and that single number
> decides whether the goal is reachable on India↔US at all.

Everything now points at the same experiment: a real peer on another continent,
speaking real media, over both paths.

## CORRECTION 2: the 9.2 ms video saving is noise

Re-ran the `?vpd` A/B with the cadence numbers the first attempt lacked, and the
result reverses:

| arm | glass-to-glass | IPI p99 |
|---|---|---|
| `vpd=2` (shipped) | 35.2 / 46.6 ms | 132.5 / 101.7 ms |
| `vpd=1` (one slot) | 44.1 / 46.1 ms | 100.9 / 132.8 ms |

The one-slot arm came out WORSE. Within a single arm, present p50 ranged 11.5 to
22.7 ms — **run-to-run variance is larger than the ~9 ms effect**, so the first
A/B's apparent saving was luck. Two samples per arm was never enough to see that;
printing IPI is what made the spread visible.

Now that IPI is printed, two more things show: p50 is 66.5 ms, so these rig calls
present at **~15 fps**, and vp depth is **0** — the presenter anchor may not be
engaging in this configuration at all, which would explain why changing it moves
nothing.

**The claim that ~9 ms sat behind this flag is withdrawn.** The flag stays: it
costs nothing and prices the trade honestly. The win does not.

That leaves the India↔US gap with no device-side lever at all — audio is at its
floor, video offers nothing measurable — and the path as the only remaining
source of 25–40 ms.

---

## The path, finally measured (2026-08-14)

Every latency number above this line came from one laptop against a simulated
network, or from Cloudflare's control plane, or from third parties on the public
internet. None of them was WebRTC media on a long route. That was the last
unknown in the budget, and the budget's own conclusion — "the path as the only
remaining source of 25–40 ms" — could not be checked without it.

It is now measured, on a **live production call**, both ends driving the real
join UI on room.tokkah.com, both ends carrying **real talking-head video and
real speech** (side A from Delhi, side B from Seattle — two different speakers,
as an actual conversation has).

**Delhi ↔ Seattle (sea01), real WebRTC, UDP, two runs on separate fresh rooms:**

| Run | State | Packets received | Jitter | Path | **RTT** |
|---|---|---|---|---|---|
| gen 7 | connected | 6 962 | 8 ms | relay ↔ prflx, udp | **305 ms** |
| gen 8 (fresh room) | connected | 6 609 | 16 ms | relay ↔ prflx, udp | **337 ms** |

Great-circle Delhi→Seattle is ~11 300 km. Light in fibre (c/1.468 = 199 862
km/s) makes the physical floor **56.5 ms one-way, 113 ms round trip**. The
measured 305–337 ms is **2.7–3.0× the speed of light in fibre** — squarely in
the same band as the 2.14× this project already measured from Delhi over TCP,
so the figure is consistent with the rest of the evidence rather than an outlier.

### What that does to the goal

One-way network on this route is **152–169 ms**. The audio pipeline is 48 ms and
already at its floor (≈20 ms OS output buffer + 16 ms jitter target + 8 ms
framing), and the video A/B found no device-side lever at all.

> **The network alone exceeds 150 ms on India↔US, before the application does
> anything.** Mouth-to-ear on this route lands at roughly **200–217 ms**.

No device-side optimisation can close that, because the gap is not on the device.
The 25–40 ms deficit the budget predicted is real and, if anything, understated.

### The honest caveat

The far end is a Cloudflare container behind carrier NAT with **no public IP**,
so ICE had no direct candidate to offer and the call went over a **relay** —
`local: relay`. This is therefore the RELAY-path number for this route. A human
user on a normal home connection may negotiate a direct path, which could be
faster. **This measures the worst realistic case, not the typical one.** The
direct-path number for the same route is still unmeasured, and is now the single
highest-value thing left to measure.

### What made this measurable at all

Seven attempts produced perfect silence. The causes, in the order they were
peeled off, are worth keeping because every one of them presented identically:

1. `container.start({entrypoint})` — **the override is silently discarded**. The
   container runs its Dockerfile `CMD`. Staged reporting proved not even the
   first line ran.
2. The Playwright base image ships the **browsers but not the npm package**, so
   `require('playwright')` died instantly. Found in ten seconds by running the
   image locally — after four attempts guessing at it remotely.
3. Stage details were interpolated into a JSON literal in bash, so any detail
   containing a quote — i.e. **every stack trace** — broke the JSON and the
   error was destroyed by the thing meant to carry it.
4. `enableInternet` is **off by default**. The container had no outbound network
   at all: `assign_ipv4: none, assign_ipv6: none, mode: private`.
5. A container lives only as long as its Durable Object. Returning without
   holding the DO awake left the instance `inactive`, location `-` — never
   placed on hardware.
6. `locationHint` is **advisory** and was ignored: a run hinted `wnam` was placed
   in **bom10 (Mumbai)**, 1 200 km away, which would have quietly reported a
   domestic call as a cross-planet one. `constraints.regions` is what binds.
7. `max_instances: 1` is application-wide, so the alarm keeping one DO awake
   blocked the next run from ever being placed.
8. The container's `REPORT_URL` carried `region` but not `gen`, so a far peer
   that ran perfectly in Seattle posted into the default Durable Object while
   the experiment polled the one it had just created — **a working run read as
   total silence**.

The lesson under all eight: every failure mode here produced the same symptom, a
silent `pending`. What broke the deadlock was not a better guess but a channel
that could not lie — running the identical image locally, and reading the
platform's own state (`containers instances`, `containers info`) instead of
inferring it.

---

## The 2.7× is not routing waste — it is the shape of the ocean (2026-08-14)

The cross-planet measurement above put Delhi↔Seattle at 2.7× the speed of light
in fibre and read that as routing overhead to be reclaimed. **That reading was
wrong, and the instrument to disprove it is a two-leg probe.**

`/api/probe?region=X&via=Y` asks the Durable Object in Y to time its own hop to
X, so a route can be decomposed into legs measured from inside the network.
`&alt=1` targets a second DO in the SAME region — the calibration arm, covering
dispatch and no distance.

**Calibrate first.** DO→DO dispatch overhead: **1–3 ms** (apac→apac 2 ms,
wnam→wnam 3 ms, oc→oc 1 ms). The legs below are therefore very nearly pure
network. This also retires the old edge-side `region=none` calibration, which
reported 109 ms — *more* than the 81 ms Singapore hop, proving that DO was never
placed nearby and that every "overhead-subtracted" figure derived from it was
built on a bad constant.

| leg | measured (min of 10) |
|---|---|
| Delhi → Singapore | 81 ms |
| Singapore → US-West | 202 ms |
| **explicit two-leg total** | **283 ms** |
| **direct Delhi → US-West** | **289 ms** |

**The direct path costs the same as deliberately routing through Singapore.**
That is the finding. It means the direct path *already* runs through Southeast
Asia and across the Pacific — there is no shorter road being missed, and no
intermediate hop left to exploit. Steering media through Singapore buys ~6 ms,
which is noise.

### Re-basing the ratio on the path light can actually take

There is no direct India–US-West submarine cable. Traffic goes east through
Singapore and across the Pacific: **~17,600 km**, not the 12,416 km great
circle. The probe decomposition above is the evidence — a route that did not go
that way could not cost the same as the route that explicitly does.

    physical floor on the REAL cable path:  17,600 km / 199,862 km/s
                                            = 88 ms one-way, 176 ms RTT

| measurement | vs great circle | **vs real cable path** |
|---|---|---|
| DO probe, 289 ms | 2.33× | **1.64×** |
| WebRTC media, 305 ms | 2.70× | **1.73×** |

**1.64–1.73× of the achievable floor is respectable routing, not waste.** The
2.7× headline was measuring against a straight line through the Earth's crust.

### What this does to the goal

The lever that looked biggest — "fix the bad route" — does not exist. What
remains:

    perfect routing (1.0×, unattainable):  88 ms one-way + 45 video = 133 ms  ✅
    excellent routing (1.3×):             114 ms + 45 = 159 ms  ❌
    excellent routing + 25 ms video:      114 ms + 25 = 139 ms  ✅
    today (1.73×):                        152 ms + 45 = 197 ms  ❌

So India↔US-West needs **both** a better path *and* a shorter video pipeline,
and neither alone is enough. That is precisely why the video floor — the audio
floor's twin, still unestablished — is now the critical path: it is the half of
the budget we control outright.

---

## The video floor, named term by term (2026-08-14)

Audio's floor is credible because every term in it has a name: 20 ms OS output
buffer + 16 ms jitter target + 8 ms framing = 48 ms. Video had no such
accounting — only a coarse "45 ms" that turned out to be stale. Measured on live
prod calls, current build:

| term | A | B | status |
|---|---|---|---|
| capture → read | 0.1 | 0.1 | floor |
| encode | 3.2 | 3.2 | floor |
| **transport** | **18.9** | **18.3** | **the whole reducible budget** |
| decode | 1.3 | 1.4 | floor |
| present (decode → painted) | 8.8 | 8.6 | floor: half a 60 Hz refresh |
| **glass-to-glass** | **32.3** | **31.6** | |

The old 45 ms figure is retired: glass-to-glass is **~32 ms**, and present lag is
8.8 ms, not the 22.2 ms recorded earlier.

### Where the transport term actually goes

Not on the wire. The audio lane shows age p50 of 2.2 ms on the same call over the
same link, and per-association RTT is 0.24–0.66 ms. Two probes split it:

    main thread -> worker postMessage :  0.03-0.04 ms
    waiting for a carrier tick        : 13.8-19.0 ms   <-- all of it

Video does not ride a datachannel. Encoded frames are queued to a worker and
splice into an outgoing RTP **carrier track** driven by canvas `captureStream`,
so a frame waits for the next tick it is allowed to ride. Measured carrier rate:
**59.7 ticks/s** — one tick per 16.7 ms, capped by display refresh.

### Three levers tested, three answers

| lever | result | verdict |
|---|---|---|
| `?sendnow=1` — pull an extra tick per frame | 3072 requestFrame calls; age 18.9 → **18.0** | no effect |
| `?ctickhz=120` — halve the tick period | age 18.9 → **21.1** | **worse**: the display caps emission at ~60/s, so this only burned CPU |
| media before parity in the send ladder | tick-wait −1.3 to −2.8 ms; g2g unchanged | **kept** — strictly better, bounded, but not the win |

Parity used to outrank fresh media unconditionally. It now yields, bounded at two
ticks so redundancy is deferred and never starved (299 deferrals in a 100 s call,
zero frames lost or gapped). It only occupies 16% of ticks, which is why the
gain is small — the opportunity was never large.

### The floor

    capture 0.1 + encode 3.2 + half a tick period 8.35 + wire ~1
      + decode 1.3 + present 8.8  =  ~23 ms

**Video's floor on a 60 Hz display is ~23 ms, and we are at ~32 ms.** The 9 ms
gap is carrier-tick phase: a frame that finishes encoding just after a tick waits
nearly a full period rather than half of one, and encode and tick are driven by
the same compositor, so their phases are correlated rather than random.

The structural point, and the direct analogue of audio's 20 ms OS output buffer:
**17.2 ms of the 23 ms floor is pure display-refresh quantization** — 8.35 ms
waiting for a carrier tick, 8.8 ms waiting for vsync to paint. Both are 60 Hz
artefacts. Neither can be optimised away inside this architecture; they can only
be escaped by not riding a display-driven carrier at all.

### Cost of this session's error

Ship discipline note: a comment containing backticks was added inside
`l2WorkerSrc`, which is itself a template literal. The stray backticks ended the
literal and **a syntax error reached production for one deploy cycle**. It was
caught by parsing the deployed asset, not by any test. `node --input-type=module
--check` against BOTH the local file and the fetched prod asset is now the
minimum gate before calling a deploy done.

---

## Video: 32 ms → 25.5 ms, by taking the compositor out of the path (2026-08-14)

The video floor section above named the carrier tick as the whole reducible
budget and guessed at two fixes that failed. The third worked, and it worked by
removing the term rather than shrinking it.

**What the failures taught.** A canvas carrier cannot emit faster than the
compositor:

| arm | tick wait | why |
|---|---|---|
| auto 60 Hz (shipped) | 13.8–19.0 ms | one compositor frame, phase-correlated with encode |
| `?ctickhz=120` | **21.1 ms — worse** | display caps emission near 60/s; only burned CPU |
| `?ctickhz=0` + `requestFrame()` per frame | 16.3 / 10.9 ms | no better |

The third is the proof. In manual mode the carrier ran at **67.8 ticks/s**
against ~62 from the service interval alone, despite ~30 extra frames per second
being explicitly requested. **`requestFrame()` does not emit a frame — it marks
the canvas for capture at the compositor's next commit, and repeated calls
inside one commit coalesce into one.** Canvas capture is compositor-bound at any
setting, and about half a refresh of latency is the entry fee.

**The fix: `MediaStreamTrackGenerator` as the carrier.** Writing a `VideoFrame`
to a track generator delivers it to the sink with no compositor involved, so the
encoder drives the wire directly. Feature-detected; `?ctrack=canvas` is the
control arm.

Measured on live prod, two runs per arm, real talking-head media both ends:

| arm | carrier rate | tick wait | age p50 | **glass-to-glass** | lost/gapped | bitrate |
|---|---|---|---|---|---|---|
| canvas | 59.7 /s | 15.1 / 12.8 | 18.1 / 17.1 | **32.1 / 31.3** | 0 / 0 | 3.50 Mbps |
| canvas (run 2) | — | 19.0 / 13.8 | 18.9 / 18.3 | **32.3 / 31.6** | 0 / 0 | 3.53 Mbps |
| **generator** | **91.8 /s** | 8.3 / 6.4 | 11.9 / 12.2 | **26.2 / 25.1** | 0 / 0 | 3.56 Mbps |
| **generator (run 2)** | — | 8.9 / 5.1 | 11.7 / 11.8 | **25.1 / 24.5** | 0 / 0 | 3.51 Mbps |
| **shipped default** | — | 9.1 / 8.1 | 12.0 / 11.5 | **25.5 / 25.5** | 0 / 0 | — |

A 6–7 ms win against a ~1 ms run-to-run spread, at identical bitrate and
cadence, with zero frames lost or gapped and audio untouched (mouth-to-ear
44.4 / 51 ms, concealment 0). The carrier rate is the mechanism made visible:
59.7/s versus 91.8/s.

**Cross-engine verified.** WebKit has no `MediaStreamTrackGenerator`, so it takes
the canvas path: a real WebKit↔Chromium prod call connected with both sides
showing real picture, concealment 0.013%, `fellBack: false`.

**Two bugs found on the way, both of the same shape — a falsy zero:**
`Number(null)` is `0`, so an ABSENT `?ctickhz` read exactly like `?ctickhz=0` and
put every default call into manual carrier mode by accident; and
`Number(QS.get('ctickhz')) || null` would have turned the flag's most important
value — 0 — back into null.

### Where video stands now

    capture 0.1 + encode 3.2 + carrier ~8.5 + wire ~1 + decode 1.3 + present 8.8
      = 25.5 ms measured

Present lag (8.8 ms) is vsync and cannot move while the frame is painted to a
display. The carrier term is now ~8.5 ms and is **no longer a compositor
artefact** — it is the service interval plus contention inside the transform,
which means it is ordinary code and not a platform floor. That is the next
target: if it reaches ~1 ms, glass-to-glass lands near **18 ms**.

### Two more levers on the residual carrier term — both negative

With the compositor gone, ~8.5 ms of carrier wait remains. Two candidate causes,
both tested on live prod and both rejected:

| lever | result vs 25.5 ms default | reading |
|---|---|---|
| `?ccw=32` — shrink the dummy frame 320→32 px wide | 24.2 / 25.1 — no change | the carrier's own encode cost is not the term |
| `?csvc=50` — fewer idle service ticks (62/s → 20/s) | **27.0 / 26.8 — worse** | starving parity of ticks makes it force its way in front of media instead |

Both levers stay, defaulted to today's values, because they price the trade
honestly. The residual is neither the dummy frame's encode nor idle-tick
contention, and it is still unnamed.

### The residual, decomposed and cornered

Reporting the tick wait as a MEAN was hiding its shape. Its percentiles:

    tick wait   p50 2.78   p90 2.93   p99 3.21   mean 7.99

The typical frame waits **2.8 ms**, not 8.5 — the mean was carried by rare
stalls (qWaitMax reached 417 ms). The carrier is effectively solved. A second
probe, stamping the sender's wall clock and reading it in the RECEIVE transform,
places every remaining millisecond:

| span | p50 |
|---|---|
| encode output → send transform | 2.9 ms |
| **send transform → receive transform** | **9.0 ms** |
| receive transform → deliver (reassembly + hop to main) | 0.8 ms |
| decode | 1.3 ms |
| present (vsync) | 8.8 ms |

The 9.0 ms is measured on a rig where both browsers run on one machine and the
audio lane's RTT is 0.24 ms, so essentially none of it is the wire. Four
candidates, all rejected on live prod:

| lever | result | reading |
|---|---|---|
| `?ccw=32` — smaller carrier frame | 24.2 / 25.1 vs 25.5 | not the dummy frame's encode |
| `?csvc=50` — fewer idle service ticks | **27.0 / 26.8, worse** | starves parity, which then forces ahead of media |
| `?jbt=0` — ask the jitter buffer for nothing | 8.88 / 8.61 vs 9.06 / 9.02 | not the jitter buffer |
| `?maxbr=30000` — lift the pacer ceiling | estimate rose 6.3 → 11.5 Mbps; term 9.08 / 8.04 | not rate-limited serialization |

That last one is the most informative. If the term were a 14.7 KB frame paced at
the bandwidth estimate it would have fallen by nearly half when the estimate
almost doubled. It did not move. A term that is flat against frame size, against
tick supply, against buffer target and against bitrate looks like a fixed
per-packet pipeline cost — packetize, encrypt, socket, depacketize, decrypt,
reassemble, ~12 packets per frame — and there is no JS lever on any of it.

**Video stands at 25.5 ms**, from 32. Of what remains, 8.8 ms is vsync and 9.0 ms
is inside Chrome's RTP pipeline: **17.8 of 25.5 ms is platform, not ours.** All
four levers above ship as flags, defaulted to today's values, so the trade stays
priced rather than forgotten.

## Audio's floor, tested rather than asserted (2026-08-14)

Audio has been described as "at its floor" all session on the strength of an
accounting identity: 20 ms OS output buffer + 16 ms jitter target + 8 ms framing
= 44 ms, against 42.2-45.2 ms measured. An identity is not evidence. Each term
was pushed:

| term | can it move? | evidence |
|---|---|---|
| OS output buffer, 20 ms | **no** | already at Chrome's floor. `latencyHint: 0` was A/B'd on 2026-08-11 and shipped: outputLatency 26 → 20 ms, and the smaller device buffer halved arrival spread (age p95 8.2 → 4.6 ms). `?lat=int` is the control. |
| jitter target, 16 ms (2 frames) | **no** | `?pcmjb=1` drops the FLOOR to one frame. Result: **concealment 328 ms and 448 ms** where every other call this session ran at zero, depth unchanged at 13.1/13.8 ms, mouth-to-ear unchanged at 43.3/44 ms — and the adaptive controller climbed back to 2f on its own. It cost audible damage and bought nothing. |
| framing, 8 ms | not attempted | FRAME=384 at 48 kHz. Halving it would save 4 ms and double the packet rate, against a striping and FEC design built on this frame size. |
| transport | 2.2 ms | already smaller than any other term. |

**The jitter result is the useful one.** 2 frames is not a conservative guess, it
is the point where this pipeline stops being lossless — and the controller
knows it, because it raised the target back without being asked. Audio is at its
floor for real.

## Where the limit of light stands tonight

    audio pipeline    42-45 ms   at floor, every term tested
    video pipeline    25.5 ms    down from 32; 17.8 ms of it is platform
                                 (8.8 vsync + 9.0 Chrome's RTP pipeline)
    network one-way   ~152 ms    1.64x the real cable path; no hop beats it

Of the ~178 ms a Delhi-Seattle glass-to-glass call costs, **88 ms is light** and
must be paid. Of the remaining 90 ms, about 27 ms is ours to attack (7.7 ms of
video outside the platform, ~20 ms of audio pipeline that is at its floor but
not at zero) and roughly 64 ms is network overhead over the cable path.

## Two swings at the last big terms — both correctly dead (2026-08-14)

### Video over datachannels instead of RTP: a loopback illusion

Video's payload rides an RTP carrier and pays 9.0 ms in the platform pipeline,
while the audio lane rides striped datachannels on the same machine and pays
2.2 ms. `?tape=1` selects the datachannel video lane, and on the rig it looked
like the win of the session:

    tape=1, loopback:  video transport age p50 0.6 / 0.4 ms  (p95 1.2 / 0.8)
    tape=2, loopback:  video transport age p50 12 ms

Eleven milliseconds, same 3.5 Mbps, 3151 frames, zero lost. Then the same two
arms over an emulated Delhi-Seattle path (300 ms RTT, 1% loss):

| arm | video frames received | glass-to-glass | audio |
|---|---|---|---|
| `tape=1` datachannel | **8**, 11 lost, age p50 **5797 ms** | collapsed | concealed 6040 ms |
| `tape=2` RTP carrier | **2851 / 2974** | 250.7 / 259.7 ms | also degraded |

**The carrier's 9 ms is not waste, it is the price of a transport that survives a
real path** — exactly the head-of-line hazard DESIGN.md predicted for a Lane B
burst on a long fat path. The 0.6 ms was a loopback illusion. Idea closed.

### What the container harness can and cannot measure

The netsim arms also showed audio concealing badly at 300 ms even with NO loss
(11.4 s concealed, drift estimator pinned at its 2000 ppm clamp — a distortion a
real network does not produce). So the real question was put to the real path,
with the local joiner fixed to read `window.__tape.pcm` and `.video` the way the
rig does rather than through a `snapshot()` call that never existed.

The answer is that the question cannot be asked this way yet:

    LOCAL (Delhi):  tapeMode { wanted 2, running FALSE, fellBack TRUE }
                    assoc RTTs 83-92 SECONDS, drift pinned, concealed 135 s
    FAR (Seattle):  ice conn FAILED, iceState disconnected

The far peer's ICE **failed mid-call**. Every derived audio number above is a
lane whose clock never synced against a peer that went away, not a measurement
of audio at distance.

**So the harness's competence is now bounded, which is worth as much as a
result:** it measures the PATH reliably — its 305 / 337 ms agrees with the
independent Durable Object probe's 289–303 ms — but a 2-vCPU headless container
behind carrier NAT on a relay-only route is not a stable enough peer to measure
MEDIA QUALITY. Earlier runs connected cleanly (6962 packets); this one failed.
**Whether lossless audio holds up at intercontinental distance is still
unanswered**, and answering it needs a real second machine, not this container.

## The lane was never running on a real long call (2026-08-14)

Everything above this line measures a video pipeline that, on a real
intercontinental call, **was not running.** The number was honest; the claim
that it described a cross-planet call was not.

Found by reading telemetry from an actual Delhi ↔ Netherlands call — room
`ilx-swig-xox`, Safari 26.6 in Delhi against Brave/Chromium 151 in the
Netherlands behind a VPN, RTT 394 ms, **zero packet loss on both sides**:

```
framesIn 0   framesEncoded 0   framesOut 0   fragsRecv 0     ← both ends
Brave   tape-fallback { why: "no-frames",      quiet: false }
Safari  tape-fallback { why: "peer-no-frames", quiet: true  }
```

Both ends had fallen back to plain RTP video. Not once during the call did the
custom lane carry a frame.

### The cause is a constant, and the constant is a distance limit

`armLaneWatchdog` was armed from `pc.ontrack` with a flat 4000 ms budget, on the
belief written into the caller's comment — *"media is flowing at the RTP level
as of now."* In Chromium `ontrack` fires when the **remote description is set**:
before ICE, before DTLS, before SCTP, before the lane's own control channel.

That sequence is roughly nine round trips. At 394 ms each it costs 3.6 s:

```
BRAVE   +0.63s  ontrack — watchdog armed, 4000 ms budget starts
        +1.90s  ICE checking
        +2.47s  ICE connected
        +3.44s  DTLS connected
        +4.24s  tape-ctl-open — its OWN encoder configures
        +4.63s  lane-watchdog framesOut:0 → lane killed
SAFARI  +153.73s peer-joined
        +157.50s its lane ready (3.77 s of handshake)
        +158.32s told by Brave: peer-no-frames
```

Brave killed the lane **390 ms after its own encoder configured** — less than
one round trip on a 394 ms path, so no frame from Safari could physically have
arrived yet. This did not lose a race. **It could not win one.** Every long-haul
call this project has ever made fell back to plain RTP video, silently, with the
fallback logged as a media failure rather than as what it was: a timer that
expired during a handshake.

On a LAN the same handshake takes ~200 ms, so 4000 ms reads as 20× headroom.
That is why it survived months of testing.

`armPcmWatchdog` had the identical bug on a 6000 ms budget. It did **not** trip
here — the six audio associations opened at +4.0 to +4.6 s, leaving 1.4 s of
margin. Happening not to trip is not the same as being correct: a slightly
longer path, or one slower TURN allocation, and lossless audio becomes Opus with
nothing in the log but `no-audio`.

### The fix, and the proof

The clock now starts when there is something to judge. `tape.js` exposes
`laneReady()` — our ctl channel open **and** the peer's `ready` received — and
the grace runs from there. The pre-ready backstop scales with the measured path
RTT (`12·rtt + 4000`) instead of assuming a datacentre. Both watchdogs now log
`rtt`, whether readiness was ever reached, and how long they waited, so the next
one of these is one query rather than a telemetry excavation.

Verified on live prod at the distance that broke it — `call.mjs --rtt=394`
against room.tokkah.com, two real browsers, real talking-head media both ends:

```
tape lane   recv 2964 frames   4057 frags   decodeErr 0
            rtt 397.83 ms      age p50 223.8 ms
            cap→read 0.1   encode 2.9   present 9.6 ms
            glassToGlass 237.7 ms
audio       6 associations open, target 20f, depth 128.5 ms
```

**2964 frames through the custom lane on the exact path that previously
delivered zero.** The audio jitter buffer settling at 20–21 frames also shows
the `maxTargetFrames` 15 → 32 raise from earlier the same day is load-bearing
here rather than idle headroom — under the old ceiling it would have been pinned.

### The law this leaves behind

**Any constant compared against something that costs N round trips is a hidden
distance limit.** Three were found in one day — the lane watchdog at 4000 ms, the
pcm watchdog at 6000 ms, and the jitter-buffer ceiling at 15 frames — and all
three were invisible on short paths, because all three present as *quality*
symptoms (black video, choppy audio, "connection paused") and never as errors.

And the corollary, which is the more expensive lesson: **before trusting any
pipeline latency number, prove the pipeline was alive on the path being
measured.** `tape-stats framesIn > 0` for video, absence of `pcm-fallback` for
audio. Everything above this section was measured correctly and generalised
wrongly.

## A dead signaling socket while waiting alone is invisible and terminal (2026-08-14)

Found on the same call, immediately after a routine refresh-both-windows:

```
SAFARI  +0.6s  ws-rx welcome
        +1.7s  ws-error AND ws-close together
        +2.0s  ws-tx display with readyState 3 — sending into a dead socket
        then 12 MINUTES of floor/onset/stats, no recovery attempt
BRAVE   joined 8 s later, told role a / peerPresent false — correctly, the
        room really was empty. Its own socket died at +604s. Same silence.
```

Two windows, both looking completely alive — camera preview up, audio graph
running, telemetry posting on cadence — with no call between them and no error
on screen, for twelve minutes.

`recoverCall`'s first guard read `!hadPeer`, so own-side recovery ran only for a
socket that died *after* a peer had arrived. A socket that dies while waiting
alone took the early return and nothing ever retried — and that is precisely the
state that cannot heal by itself, because the signaling socket is the only way a
peer can ever be learned about. The room can fill up and you will never know.

The `ws-error` and `ws-close` firing together says this was an abrupt transport
failure, not a server close, so the drop itself is the Delhi network and not
something to fix in code. The defect was that nothing responded to it.

`joined` is the correct precondition: it means the server admitted us to a room,
so a close is loss rather than lobby noise. It is set only after the open promise
resolves, so a 409 room-full rejection still cannot reach recovery; `wsOpened`
still gates the caller for sockets that never opened; and RECOVER_MAX / WINDOW /
COOLDOWN still bound the attempts.

Worth stating plainly because it shaped a whole debugging session: **the user's
own workflow is to refresh both windows after every deploy.** This bug sat
directly on the hot path of how the project is tested.

## 150 ms met, and the pipeline is at its floor (2026-08-14)

Measured on deployed prod with two real browsers and real talking-head media,
at the true Delhi ↔ Netherlands distance — 156 ms RTT, which is Cloudflare's own
APAC↔WEUR backbone measured this session against a same-region calibration arm
that returned 0–1 ms:

```
mouth-to-ear      125.1 / 122.7 ms          the goal was 150
  network one-way   81.0        (RTT/2 is 78 — the audio lane adds 3 ms over raw transit)
  jitter buffer     16.1        (target 2 frames — the PROVEN floor)
  device output     20.0        (Chrome's OS buffer, already at latencyHint 0)
  framing            8.0        (design constant, 384 samples at 48 kHz)
concealment            0 ms     across the whole call, both directions
video glass-to-glass 103.8 ms   0 lost, 3 late, no stalls, no holds
```

**Ours is 44 ms of the 125, and every term of it is already at a floor that has
been tested rather than assumed:** the buffer at 2 frames (1 frame was tried and
cost 328/448 ms of concealment), the output buffer at Chrome's minimum, and
framing fixed by the 8 ms frame. There is no remaining JS lever in the audio
pipeline that does not cost more than it saves.

That leaves the network as the only pool with room in it: 81 ms one-way where
the fibre floor for Delhi↔Amsterdam is ~40 ms. That is Cloudflare's routing plus
the relay hop, and the relay hop is now priced — 5 ms, measured.

### Direct vs relay, at the same distance

```
direct   mouth-to-ear 127.1 / 124.9    depth 18.4    concealed 8 ms
relay    mouth-to-ear 132.3 / 131.0    depth 23.6    concealed 0 ms
```

The relay costs ~5 ms and bought zero concealment for it. **This is the relay's
PROCESSING cost only** — the delay line in the harness is local, so it says
nothing about a relay in the wrong region, which remains unmeasured (task #32).

Worth stating plainly because it is the reason the relay is not simply removed:
on the long path measured earlier, Cloudflare's private backbone ran at **1.64×**
the great-circle-corrected floor while public-internet transit from Delhi ran at
**2.14×**. Five milliseconds of relay hop is cheap against a road that is 30%
shorter. Between two peers in the same city it would not be, and ICE already
prefers direct there — the app has always been `p2pOnly: false`, offering STUN
and TURN and letting ICE choose.

Every call now records which road it took (`pair.path`, `pair.proto`), so this
stops being a question that needs a special run to answer.

## Two reliability defects that were costing whole calls (2026-08-14)

Neither is a latency bug and both were worth more than any millisecond left.

**A signaling blip ended the other person's call.** `peer-left` was broadcast the
instant a socket closed; the peer's handler treats that as the end — "they left",
back to the lobby, clock stopped — while the media connection underneath was
still connected and still carrying audio and video. Across the captured Delhi
calls, `recover {why:"ws-close"}` fired **37 times**. The room now holds that
announcement for 5 s and cancels it if the same tab returns (`sid` is in
sessionStorage, so it survives the recovery reload). The slot itself frees
immediately — only the message waits — so capacity and role reuse are unchanged.

**And the socket had no keepalive at all.** After the offer, answer and
candidates are exchanged it says nothing for the rest of the call, and an idle
TCP connection is exactly what a VPN or proxy reaps. That is the simplest
explanation for all 37. It now pings every 25 s; the room answers it and never
relays it.

`testbed/wsblip.mjs` and `testbed/wsping.mjs` assert both, on prod, with two real
browsers — and each has the arm that could actually fail: that a *genuine*
departure is still reported (else the "fix" merely deleted `peer-left`), and that
the ping is never observed on the peer's socket (recorded by wrapping
`WebSocket` before the app sees it).
