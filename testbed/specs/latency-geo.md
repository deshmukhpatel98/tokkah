# Intercontinental latency: an architecture brief

**Scope.** What happens to Tokkah when the two people are on different continents.
Written against the code as it stands (`tape-app/src/worker.ts`, `tape-app/public/pcm.js`,
`tape-app/public/app.js`, `core/pcmsw.js`, `testbed/netsim.mjs`), and against published
measurements, every one of which is cited in **§7 References** with the URL that was read.

**The honest headline up front.** On a US-East↔India call the speed of light in glass
costs more than every other term in our budget combined. Nothing in this codebase can
move it. What the codebase *can* move is the ~35–90 ms of local budget sitting on top of
it, and the evidence below says the largest single controllable term on a long path is
**per-lane RTT divergence across the six SCTP stripes**, which the jitter estimator pays
for as buffer depth, and which we have never measured on a path long enough for the lanes
to diverge.

---

## 0. What our budget is actually made of

`pcm.js:2238` composes the number the latency campaign moves:

```js
mouthToEarMs = 8 + ageP50 + depthMs + outputLatency
```

- **8 ms** — frame assembly (`FRAME_MS = 8`, 384 samples @ 48 kHz). Fixed.
- **ageP50** — capture→arrival, measured against the peer's clock. This is the term
  distance lands in.
- **depthMs** — jitter buffer occupancy. Floor is `targetFrames = 2` → **16 ms**
  (`app.js:1573`); ceiling is `maxTargetFrames = 15` → **120 ms** (`app.js:1578`).
- **outputLatency** — **11 ms** measured on real Macs (`MEASURED.md:4307`).

So the **local fixed floor is 8 + 11 + 16 = 35 ms**, and everything else is transit and
buffer. Fleet `mouthToEar` p50 today is **48.3 ms** (`MEASURED.md:4308`), i.e. same-city
transit plus buffer growth is running ~13 ms over floor.

> **Caveat that gets worse with distance.** `ageMs` is computed as
> `now() - wall - clockOffsetMs` (`pcm.js:1587`), and `clockOffsetMs` comes from
> `b - (ts + rtt/2)` (`pcm.js:1544`) — a **symmetric-path assumption**. Intercontinental
> routes are routinely asymmetric (different cables each way, especially India↔US where
> one direction may go east via Singapore/Pacific and the other west via Suez/Atlantic).
> Half the asymmetry lands directly in `ageP50` as bias, with the *opposite* sign at each
> end. The tell is cheap and we already log it: **`clockOffsetMs` measured at A and at B
> should sum to ~0. If it doesn't, the residual is the path asymmetry**, and each side's
> `mouthToEarMs` is wrong by half of it in opposite directions. Add that check before
> publishing any intercontinental m2e number.

---

## 1. The physics floor

### 1.1 The constant

Light in single-mode fibre travels at ~2/3 c ≈ **200,000 km/s = 5 µs/km**, i.e.
**5 ms per 1000 km one-way, 10 ms per 1000 km RTT**. That "10 ms round-trip delay per
1000 km of route distance" rule is the standard submarine-cable planning figure
([GeoCables][geocables]).

Cable *route* distance is not great-circle distance. Real systems run 1.2–1.6× great
circle depending on landing points; the Pacific is close to direct, the India↔US-East
path is not (it goes around a continent whichever way it goes).

### 1.2 Floor vs measured, per pair

| Pair | Great-circle | Fibre floor (RTT) | Backbone measured (RTT) | Public-internet measured (RTT) |
|---|---|---|---|---|
| US-East ↔ India | ~13,700 km (Chennai–Ashburn) | **~137 ms** | **202.9 ms** (Verizon NA↔India, Jun 2026) | **217.7 ms** Chennai↔Washington DC; **246.8 ms** Chennai↔New York |
| US-West ↔ Japan | ~7,700 km (Tokyo–Seattle) | **~77 ms** | **111.4 ms** (Verizon Trans-Pacific, Jun 2026) | **94.6 ms** Tokyo↔Seattle; **104.3 ms** Tokyo↔SF |
| EU ↔ India | ~7,200 km (London–Mumbai) | **~72 ms** | **115.4 ms** (Verizon India↔UK, Jun 2026) | **149.5 ms** Chennai↔Frankfurt; **171.4 ms** Chennai↔London |

Backbone numbers: [Verizon IP Latency Statistics][verizon], monthly means from 5-minute
samples, Jul 2025–Jun 2026. Public-internet numbers: [WonderNetwork global ping][wn-chennai]
[matrix][wn-tokyo], VPS-to-VPS ICMP.

**Three things fall out of that table.**

1. **The Pacific is nearly free.** Tokyo↔Seattle measures 94.6 ms against a 77 ms floor —
   a route factor of ~1.23. There is almost nothing to win on US-West↔Japan; the path is
   already close to physics.
2. **India↔US is 1.5–1.8× floor.** 218–247 ms measured against 137 ms of great circle.
   Some of that is genuine cable geography, some is transit routing. This is the pair
   where path selection has headroom.
3. **EU↔India is where backbone beats transit by the most.** Verizon's private backbone
   measures **115.4 ms** where public-internet VPS pings measure **149.5–171.4 ms**. That
   is a **34–56 ms RTT** (17–28 ms one-way) gap on the same geography — the single
   largest backbone-vs-transit delta in the table, and it is entirely a routing artifact.

### 1.3 What that puts mouth-to-ear at

Fixed local terms: 8 (framing) + 11 (output) = **19 ms**. Add one-way transit and buffer.

| Pair | One-way transit | m2e @ 16 ms buffer (floor, unrealistic) | m2e @ 24–40 ms buffer (realistic) |
|---|---|---|---|
| **US-West ↔ Japan** | 47–52 ms | **82–87 ms** | **90–111 ms** |
| **EU ↔ India** (backbone) | 58 ms | **93 ms** | **101–117 ms** |
| **EU ↔ India** (public) | 75–86 ms | **110–121 ms** | **118–145 ms** |
| **US-East ↔ India** | 101–123 ms | **136–158 ms** | **144–182 ms** |

Against [ITU-T G.114][g114] ("if delays were kept below 150 ms, then most applications
would not be significantly affected"):

- **US-West↔Japan and EU↔India sit comfortably inside the transparent band.** These are
  not compromise calls. 90–110 ms mouth-to-ear intercontinentally is a real product.
- **US-East↔India straddles the 150 ms line.** Best case we are just under; a buffer that
  climbs to 40 ms puts us just over. Every millisecond of buffer we hand back is the
  difference between "transparent" and "noticeably delayed" on that specific pair.

G.114's 400 ms upper planning limit is not our problem; the 150 ms line is, and only on
one of the three pairs.

---

## 2. Signaling: where the Room DO lands, and what it costs

### 2.1 What the code does

`worker.ts:1603`:

```ts
return env.ROOM.get(env.ROOM.idFromName(code)).fetch(new Request(doUrl.toString(), request));
```

No `locationHint`, no jurisdiction. Per [Cloudflare's data-location docs][do-loc], "a
Durable Object is instantiated in a data center close to where the initial `get()` request
is made" — so **the DO pins near whoever opens the room first**, for the life of that DO.
Also from the same docs: **"Durable Objects do not currently change locations after they
are created."** There is no mid-call migration to consider; the option does not exist.

Worse than "near the first requester": DOs are not in every colo. The community tracker
[where.durableobjects.live][wdl] reports Durable Objects available in **~11% of Cloudflare
PoPs**, and gives a worked example of a worker in **Delhi (DEL) creating a Durable Object
in Hong Kong**. So an India-first room may already be signalling via East Asia even for the
*local* party. This is measurable from our side and we do not currently measure it.

### 2.2 What the far party pays

We have the decomposition, measured live (`testbed/specs/ws-predial-spec.md`, room
`bot-msntyeea-shue`, 2026-08-11): the second joiner's **472 ms click→connected** was
**241 ms ws dial + welcome**, 75 ms offer generation, 12 ms ICE, 144 ms DTLS/stripes.

The WS dial and the offer/answer exchange are the DO-distance-sensitive terms. Model them
as RTTs to the DO:

- **WS dial + welcome** ≈ 1 TLS+WS setup to the DO's colo. On a same-region path that
  measured 241 ms. If the DO is a full ocean away, the TCP+TLS+WS handshake is roughly
  3 round trips before the first frame, so at 220 ms RTT that is **~660 ms** instead of
  ~241 ms: **+420 ms**.
- **Offer→answer→ICE trickle** each cost one DO-relay hop each way. At 220 ms RTT that is
  ~220 ms per exchange instead of ~30 ms: **+~200 ms** for the SDP round trip and
  candidate relay.

**Quantified: the far party's click→connected goes from ~470 ms to roughly 1.0–1.2 s.**
That is the whole penalty, and it is real but bounded. Cloudflare's own figure for
PeerConnection establishment is **"about 100-250ms to get connected"** including consensus,
STUN and DTLS ([Cloudflare Calls anycast post][cf-calls-anycast]) — consistent with our
12 ms ICE + 144 ms DTLS on a short path; DTLS costs 2 RTT and will grow to ~450 ms on a
220 ms path regardless of where the DO is, because DTLS is peer-to-peer.

### 2.3 Does the DO matter after connection?

**Essentially no, and this is the load-bearing good news.** Media never touches the DO —
audio rides the SCTP datachannels between peers. Post-connect, the DO carries only:
relayed control messages (`app.js` relay path), the telemetry `POST /log` batches, and the
optional translation proxy. None of those are in the mouth-to-ear path. A far DO adds
latency to *reconnects, renegotiation, and the peer-left/peer-joined signals*, not to
speech.

The exception worth naming: **ICE restart and lane-flip recovery** go through the DO. On a
long-DO path, a mid-call network change costs an extra ~2 DO round trips of dead air. That
argues for DO placement mattering to *robustness*, not steady-state latency.

### 2.4 Should we set `locationHint`?

`locationHint` accepts `wnam, enam, sam, weur, eeur, apac, apac-ne, apac-se, oc, afr, me`
and is explicitly **"a best effort and not a guarantee"** ([docs][do-loc]).

Recommendation: **do not hint globally.** A global hint helps one hemisphere and hurts the
other. Two options that are actually defensible:

- **(a) Do nothing.** The DO already lands near the room creator, which is the person most
  likely to reconnect and re-invite. The joiner pays a one-time ~500–700 ms on setup, and
  we already have the pre-dial machinery (`ws-predial-spec.md`) that hides dial cost behind
  the lobby — **pre-dial is worth strictly more on a long DO path than on a short one**,
  because it moves the 660 ms handshake off the click path entirely. This is a
  latency-campaign win that costs nothing new to build; it is already built.
- **(b) Room-code-carried hint.** The invite link is minted client-side (`worker.ts:1612`,
  `/^\/[a-z]{3}-[a-z]{4}-[a-z]{3}$/`). A future code format could carry a region nibble so
  `env.ROOM.get(id, { locationHint })` places the DO between the two parties. This only
  pays off if we know both parties' regions at mint time, which we generally do not.

**Verdict: (a), plus make the DO's actual colo observable.** The DO can read
`request.cf.colo` on the first request and store it; publish it in the welcome frame. Then
"the DO was in Hong Kong for a Chennai↔Ashburn call" becomes a fact instead of a guess.

---

## 3. Media path: P2P vs relayed-over-backbone

### 3.1 What we ship today

`worker.ts:1504–1545` mints ICE servers from
`rtc.live.cloudflare.com/v1/turn/keys/.../generate-ice-servers` with a 1 h TTL, falling back
to `stun:stun.cloudflare.com:3478` and `p2pOnly: true` when TURN is unconfigured.
`app.js:5181–5204` builds the `RTCPeerConnection` with a **ladder of degradations**
(`full` → `no-query` → `stun-only`) so a bad relay URL costs relay candidates and never the
call. There is **no `iceTransportPolicy`** anywhere and no per-pair preference: ICE picks
by its own priority rules, which means **host/srflx (direct P2P) always outranks relay**.

### 3.2 Does Cloudflare TURN carry the middle mile?

This is the crux, and the documentation is *almost* explicit. What is stated:

- **"[clients] automatically connect to the Cloudflare location closest to them. We achieve
  this using anycast routing."** ([TURN docs][cf-turn])
- **"When a client sends a request to an anycast address, the network automatically routes
  the request via BGP to the topologically nearest server."** ([TURN+anycast blog][cf-turn-anycast])
- **"If a packet arrives at the wrong Cloudflare location, we forward it over our backbone
  to the correct datacenter, rather than sending it back over the public Internet."**
  ([same][cf-turn-anycast])
- **"about 95% of the Internet connected population is within 50ms of a Cloudflare data
  center."** ([Calls anycast post][cf-calls-anycast])
- Once traffic is inside, "the underlying media can be managed carefully and routed through
  the Cloudflare backbone." ([same][cf-calls-anycast])

What is **not** stated anywhere I could find: whether the *relayed transport address* handed
to peer B is itself anycast. Cloudflare's own ["What is TURN"][cf-what-turn] page describes
the relayed address purely functionally — "the IP address and port reserved on the TURN
server that others on the Internet can use to send data to the TURN client" — with no
anycast claim attached.

**The inference, labelled as an inference:** if the relayed address is anycast (which the
architecture strongly implies — the whole point of the Unimog/backbone-forwarding machinery
described in the blog is to make an anycast STUN/TURN address behave like a pinned one),
then peer B's packets enter Cloudflare at *B's* nearest colo and cross the ocean on
Cloudflare's backbone, and peer A's egress leaves from *A's* nearest colo. That is the
"last mile short, middle mile on our network" shape. **If it is not anycast**, peer B sends
across the public internet to A's colo and the relay buys nothing but NAT traversal.

**This is a one-experiment question and we should just answer it.** With a forced-relay
peer connection, read the `remote-candidate` / selected-pair IP from `getStats()` at each
end and geolocate it. If A and B see *different* relay IPs (or the same anycast IP
resolving to different colos via a `cf-ray`-style probe), the middle mile is Cloudflare's.

### 3.3 When does relay beat direct?

Three regimes:

1. **US-West↔Japan.** Public transit already measures 94.6 ms against a 77 ms floor
   (route factor 1.23). There is ~18 ms RTT of theoretical headroom total. **Relay almost
   certainly loses** — a relay adds two extra hops of processing and cannot beat a path
   that is already near-geodesic. Prefer direct.
2. **EU↔India.** Backbone 115.4 ms vs public 149.5–171.4 ms. **A backbone-carried relay
   should win by 34–56 ms RTT** — the largest available win in this brief. Prefer relay,
   if §3.2's inference holds.
3. **US-East↔India.** Public 218–247 ms vs a 137 ms floor. Verizon's *backbone* gets
   202.9 ms, so a well-routed private path buys **~15–45 ms RTT**. Prefer relay, weakly.

**Caution on Argo.** Cloudflare's headline "**35% decrease in latency**" for Argo Smart
Routing ([Argo announcement][cf-argo]) is a claim about **HTTP traffic to customer
origins**, measured on cache-miss requests. It is not a claim about UDP media between two
TURN edges and **must not be quoted as one**. The relevant claim for us is the narrower,
verbatim one from §3.2: misrouted packets are carried on the backbone rather than the
public internet.

### 3.4 What ICE configuration would prefer the better path per-pair

Standard ICE cannot express "prefer relay on this pair, direct on that one" — priorities are
per-candidate-type and global. Three mechanisms, in increasing order of intrusiveness:

- **(i) Candidate-priority rewrite in the SDP.** Before `setLocalDescription`, rewrite the
  `a=candidate` priority fields to raise `relay` above `srflx` for pairs we have decided
  should relay. Cheap, no new signalling, entirely client-side, and reversible per-call by
  query flag. This is the one I'd build.
- **(ii) `iceTransportPolicy: 'relay'`** on the whole PeerConnection for chosen pairs.
  Blunt — it also forfeits the direct path as a *fallback*, which is a robustness
  regression, and our ladder in `app.js:5181` exists precisely to never forfeit fallbacks.
  Not recommended.
- **(iii) Race both and keep the winner.** We already stripe six associations
  (`app.js:1602`, `pairs: 6`). Nothing stops **one lane from being pinned to relay while
  the rest go direct**, measuring `baseRttMs` on each (`pcm.js:1541` already tracks the
  running minimum per association), and promoting whichever family wins after ~2 s. This
  is the design that suits this codebase, because the instrument already exists and the
  multi-association plumbing already exists.

**But see §4.3 first** — striping across paths with different RTTs has a cost the buffer pays.

---

## 4. Jitter buffer economics at 250 ms RTT

### 4.1 What to expect on the wire

Reported global internet jitter runs **10–80 ms** ([RIPE Atlas / jitter characterisation
survey material][ripe-jitter]); practical netem guidance for a transatlantic path is
**200 ms latency with 0.5% loss**, and for a lower-tier international path **200 ms ±40 ms
with 25% correlation and materially higher loss** ([Calomel netem profiles][calomel]).
The mechanisms that produce that spread on an oceanic path are:

- **Access-link bufferbloat at either end** — the dominant jitter source, and it is
  *local*, not oceanic. It does not scale with distance.
- **Cross-ocean congestion and cable-segment queuing** — real but modest on lit capacity.
- **Route changes / ECMP rehashing** — a mid-call re-route across a 13,700 km path can
  shift baseline delay by tens of ms in one step. This is qualitatively different from
  jitter: it is a *step change in the mean*, and a spread-sized buffer handles it badly
  (it reads as a permanent ramp).
- **Reordering across ECMP** — long paths cross more equal-cost fabrics, so reorder
  probability is materially higher than on a metro path. Our transport is
  unreliable/unordered by design (`pcm.js` header comment: "any arrival order was already
  tolerated"), so reordering costs us *spread*, not loss.

### 4.2 What our estimator does with that

`pcm.js:1907`:

```js
const raw = Math.max(cfg.targetFrames, Math.ceil(spreadHold / FRAME_MS) + D_MARGIN_FRAMES);
const want = Math.min(cfg.maxTargetFrames, raw);
```

The buffer is sized from **arrival spread**, not from RTT. That is the right design for
distance: **a 250 ms path with 5 ms of spread gets a 16 ms buffer, exactly as a 5 ms path
would.** Distance itself does not inflate our buffer. Confirmed by the code: `D_WIN = 320`
frames (2.56 s), spread is `(second-largest − min)` of `arrival − seq·8`, and nothing in
the control law reads RTT.

So the buffer cost of going intercontinental is **entirely the cost of extra spread**, and
extra spread on a long path comes from the four mechanisms above plus one of our own
making (§4.3). At 15 frames the clamp binds at **120 ms**, which on a US-East↔India path
would put mouth-to-ear at ~240 ms — deep into G.114's degraded region. `jitClampedTicks`
(`pcm.js:1910`) is the counter that would show it.

### 4.3 The lever nobody has looked at: per-lane RTT divergence

We open **six** SCTP associations (`app.js:1602`). Six associations means six distinct
5-tuples, which means six independent ECMP hashes across every fabric on the path. On a
metro path all six take the same route and `baseRttMs` is identical across lanes. **On a
13,700 km path with a dozen ECMP fabrics, they need not be** — different transoceanic
segments, different peering exits, genuinely different one-way delays.

And here is the trap: **the jitter estimator sees the union of all six lanes as one arrival
stream.** `noteArrival` (`pcm.js:1778`) is called per frame regardless of which lane
carried it. If lane 3 is 12 ms slower than lane 1, that 12 ms appears as **arrival spread**,
the estimator adds ⌈12/8⌉+1 = 3 frames of target, and **every frame on every lane pays
24 ms of buffer** to absorb a difference that is structural rather than stochastic.

We already have the instrument: `perAssoc[i].baseRttMs` is published in every snapshot
(`pcm.js:2259`). **Nobody has read it on a long path**, because we have never had one.

**Predicted lever size:** if lanes diverge by 10–25 ms on a US↔India path — plausible for
six independent ECMP selections across ~13,000 km — the induced buffer cost is **16–32 ms
of mouth-to-ear, on both directions, for free.** That is 2–4× larger than any other
controllable term in the budget for that pair, and it is a *pure loss*: the striping buys
loss-independence, not latency, and the divergence penalty was invisible at metro
distances.

**Three fixes, cheapest first:**

1. **Measure it.** Report `max(baseRttMs) − min(baseRttMs)` across `perAssoc` as a
   first-class stat. If it is ~0 on long paths, this whole section is a null and we've
   learned something cheap.
2. **Per-lane de-skew.** Subtract each lane's own `baseRttMs − min(baseRttMs)` from that
   lane's arrival timestamp before feeding `noteArrival`. The structural offset stops
   being spread; only genuine jitter remains. This is a handful of lines and it is the
   correct fix — the spread estimator should measure *variance*, not *path diversity*.
3. **Prune slow lanes on long paths.** Drop from 6 to 3–4 associations when divergence
   exceeds a frame. Costs some loss-independence, buys buffer depth back.

Fix (2) is strictly better than (3) and should be tried first.

### 4.4 Per-path FEC tuning vs buffer depth

The literature answer is unambiguous and it favours FEC at high RTT. [RFC 8854][rfc8854]
§8: implementations **"SHOULD prefer using RTX or Flexible FEC retransmissions instead of
FEC when the connection RTT is within the application's latency budget"** — i.e. once RTT
exceeds the budget, retransmission is off the table and FEC is the only recovery mechanism
that does not cost a round trip. At 220 ms RTT with a 16–40 ms buffer, a retransmit arrives
5–10 playout slots late. **Correct by construction: this codebase has no RTX.** Good.

RFC 8854 also warns the other way: implementations **"SHOULD only transmit the amount of
FEC needed to protect against the observed packet loss"**, and "if the loss is caused by
network congestion, the additional bandwidth used by the redundant data may actually make
the situation worse." So "more parity on long paths" as a blanket policy is wrong — the
adaptive ladder in `pcm.js:239–266` (`rungTop[n]` = highest loss % that n parity symbols
holds under a 10% conceal target) is already the RFC-compliant shape. What *should* change
per-path is not the ladder's target but its **reaction time**: `FEC_N_MIN` defaults to 0,
and the code comments note that n=0 "is the only rung with a REACTION TIME: no parity is in
flight, so the first loss is a conceal." At 220 ms RTT the loss-signal→ladder-climb loop is
a full round trip slower than at 20 ms. **Recommendation: `FEC_N_MIN = 1` on long paths** —
one parity symbol always in flight repairs any single erasure in its group instantly, and
costs ~10% bitrate. That is a latency win (fewer conceals → less pain → estimator does not
ratchet the target up) bought with bandwidth, not with delay.

**And the repair-latency term is already solved.** `core/pcmsw.js` is the default: sliding
window with `SW_WINDOW = 12`, `SW_STRIDE = 3`, so **repair latency is bounded by 3 frames
= 24 ms** rather than the RS group span (K=10 → 80 ms, of which "67% of position-0 repairs
arrived after the playhead had passed"). Since a repair that lands late is exactly what
forces the buffer to grow, sliding-window FEC is *already* the "FEC-over-buffer" trade the
literature recommends, and it was shipped for the right reason.

**Verdict on the split:** at high RTT the correct order of operations is
**(1) remove structural spread (§4.3), (2) bound repair latency (done: pcmsw), (3) keep a
minimal parity floor so the first loss isn't a conceal, (4) only then let the buffer grow.**
Buffer depth is the term of last resort because it is the only one that is 1:1 mouth-to-ear.

---

## 5. Turn-taking: what is impossible, and what is still available

### 5.1 The bar

[Stivers et al. 2009, PNAS][stivers] measured turn-transition gaps across ten languages from
traditional indigenous communities to major world languages and found "striking universals in
the underlying pattern of response latency," with cross-language variation confined to within
250 ms of the mean. The ~208 ms figure is the cross-language modal gap. This is not a
preference; it is infrastructure.

[Boland et al. 2022, JEP:General][boland] measured the same dyads face-to-face and over Zoom:
**face-to-face transition times averaged 135 ms; the same dyads over Zoom averaged 487 ms.**
In a controlled Q&A paradigm, local responses averaged 297 ms and remote 976 ms.

### 5.2 The arithmetic

A turn transition costs **one full round trip of end-to-end delay**: the responder hears the
turn-end late by one m2e, and their response arrives late by another. So:

**predicted turn gap ≈ 135 ms (native) + 2 × mouth-to-ear**

| Configuration | m2e | Predicted turn gap |
|---|---|---|
| In-person (Stivers/Boland) | — | **135–208 ms** |
| Tokkah, same city (measured 48.3 ms) | 48 ms | **~231 ms** |
| Tokkah, US-West↔Japan | ~95 ms | **~325 ms** |
| Tokkah, EU↔India (backbone relay) | ~105 ms | **~345 ms** |
| Tokkah, US-East↔India | ~155 ms | **~445 ms** |
| Zoom, domestic (measured) | — | **487 ms** |

**The honest framing to use publicly: Tokkah across the Pacific is roughly twice as
responsive as Zoom is across town. Tokkah across the Indian Ocean to US-East is about
where Zoom is domestically.** The 208 ms bar is met same-city and is physically
unreachable US-East↔India — 2 × 101 ms of pure fibre transit is already 202 ms of gap
before a single line of our code runs. Say so plainly; the alternative is a claim that
cannot survive a measurement.

### 5.3 Which artifacts actually hurt

The literature is specific, and it does *not* say "delay is uniformly bad."

- **Interactivity mediates everything.** [Kitawaki & Itoh 1991][kitawaki] ran six tasks with
  different temporal characteristics and found the more interactive the conversation (a
  random-number verification task vs free conversation), the worse the rated quality **at
  equal delay**. Low-interactivity conversation tolerates delay that ruins high-interactivity
  conversation. Practical consequence: our worst-case pair will feel fine in storytelling
  mode and bad in rapid Q&A, and any subjective evaluation that doesn't control the task is
  measuring the task.
- **The damage is attributed to the person, not the network.** [Schoenenberg, Raake & Koeppe
  2014][schoenenberg] found delayed partners are perceived as **less attentive, less
  extraverted, less conscientious** — users misattribute a technical delay to the other
  person's character. This is the actual product harm and it is not captured by any
  latency number.
- **The mechanism is unintended interruption.** The same line of work uses **unintended
  interruption rate (UIR)** as the metric that reveals a conversation's delay sensitivity;
  [Seuren et al. 2021][seuren] describe the mechanism concretely — participants perceive
  silence at transition-relevance places where talk should be occurring, begin talking in
  overlap, and then struggle to return to one-speaker-at-a-time. **The collision, and the
  repair after it, is what people experience as "bad." Mean delay is only the cause.**

**Design consequence: UIR and overlap-collision rate are better product metrics than m2e
for intercontinental calls, and they are measurable from audio we already have.** Both
peers' VAD state is available; a collision is "both talking within 300 ms of each other
after a gap." This is a real instrument we do not have and should build.

### 5.4 What local techniques can still buy

Given the one-way floor is irreducible, the only remaining levers act on *variance* and on
*turn boundaries*:

1. **Adaptive playout with time-scale modification.** [Liang, Färber & Girod][liang] adjust
   playout time not just between talkspurts but **within** them, using WSOLA-based
   time-scale modification which "modif[ies] speech rate without impairing quality or
   changing pitch." The relevant application here: after a silence, **play out faster than
   real time to burn off accumulated buffer**, arriving at the *next* turn boundary with a
   shallower buffer than the estimator would otherwise hold. Speech at 1.02–1.05× is
   perceptually free; over a 3 s turn, 3% catch-up recovers ~90 ms of accumulated delay.
   **This is the single technique in the literature that directly attacks turn-taking
   latency without touching the network.** It is also the one this codebase is best
   positioned for: playout is already a worklet reading a ring at a controlled rate with a
   drift compensator (`driftPpm`, clamped at 0.2%) — the machinery is there, the clamp is
   the only thing in the way.
2. **Faster end-of-turn playout specifically.** The buffer only needs to be deep *during*
   speech. At a detected turn end, the remaining buffer contents can be drained at
   1.1–1.3× (a few hundred ms of tail) so the listener reaches "they've stopped" sooner.
   Risk: this changes prosody at exactly the point where prosody signals turn-completion,
   which is what listeners use to project turn ends. **Test this against UIR, not against
   m2e** — it could easily make collisions worse while making the number better.
3. **Do not add a visual latency indicator.** Tempting, and it addresses §5.3's
   misattribution finding directly. But it also makes the delay salient, and Kitawaki &
   Itoh found the *talker's knowledge of the cause of delay* was a controlled variable
   precisely because it matters. Worth a real experiment, not a default.

**Ranking for this codebase:** (1) is the highest-value unbuilt idea in this brief after
§4.3. It is bounded, testable, and it attacks the exact quantity — turn gap — that the
physics floor otherwise makes untouchable.

---

## 6. Measurement design from one location

### 6.1 The constraint

We test from one machine near Chennai (MAA). `testbed/rig.mjs` launches both browsers
locally via Playwright and its stated non-claim is explicit: "this is two browsers on one
host against production signalling. It is not a real internet path." `testbed/netsim.mjs`
adds an emulated path through a local TURN server with a UDP delay proxy, and is equally
explicit: "It emulates distance, not the internet."

### 6.2 Evaluating the three options

**(a) SOCKS5 / VPN exit for one browser arm.**
- ✅ Real internet path, real cross-traffic, real bufferbloat, real ECMP.
- ❌ **Fatal for our numbers:** a SOCKS5 or VPN exit puts a *tunnel* in the path. Both
  browsers are still on one machine, so the "distance" is Chennai→exit→Chennai — the
  packets cross the ocean **twice**, and the tunnel's own MTU, encapsulation and single-
  flow behaviour destroy the six-lane ECMP diversity that §4.3 says is the thing we most
  need to observe. A VPN collapses six 5-tuples into one tunnel.
- ❌ Chrome's `--proxy-server` does not proxy WebRTC UDP by default anyway.
- **Verdict: reject for latency numbers.** Useful only for a crude "does it connect at
  all across a NAT in another country" smoke test.

**(b) Cloud VM vantage.**
- ✅ **The only option that produces trustworthy absolute numbers.** A headless Chrome on a
  VM in `us-east-1` / `us-west-2` / `ap-northeast-1` joining a room hosted from Chennai is
  a genuine intercontinental call: real path, real asymmetry, real ECMP diversity across
  six associations, real Cloudflare anycast behaviour at both ends.
- ✅ `rig.mjs` already drives Playwright and already has a preflight-abort discipline; the
  change is `chromium.connect(browserWSEndpoint)` against a remote Playwright server
  instead of `chromium.launch()`. The rig's existing per-page scheduler-lag instrumentation
  (contract item 4) matters more than usual here, because a small cloud VM starves easily
  and starved-page jitter would be indistinguishable from oceanic jitter — the rig already
  refuses to publish timing metrics it cannot separate from CPU. Use a VM with ≥4 dedicated
  vCPU.
- ⚠️ **Caveat to state in every result:** a cloud VM is on a tier-1-adjacent network with
  excellent peering. It measures the **good** version of the path, not the residential
  version. Numbers from it are a **floor for real users**, not a median.
- ⚠️ No real microphone. Use the existing realistic-media fixtures via
  `--use-file-for-fake-audio-capture`; do not measure with synthetic tones.

**(c) Network emulation (netsim / netem).**
- ✅ Reproducible, seeded, free, no second site, and the only way to sweep a parameter.
- ✅ `netsim.mjs` already takes `oneWayMs`, `jitterMs`, `lossPct`, `bwMbps`, `queueMs`,
  applies delay across two proxy crossings correctly (`delayMs: oneWayMs / 2`), and
  compounds loss correctly (`perCrossingPct` from the two-crossing binomial).
- ❌ **Two honest gaps for this specific job.** First, `netsim.mjs` draws jitter from a
  **uniform** distribution (`(rnd() * 2 - 1) * jitterMs`, line 268). Real long-path delay
  is **heavy-tailed**, and our buffer is sized from a p99-of-spread statistic — a uniform
  ±J understates the tail that actually sets our depth. netem's `distribution
  pareto`/`paretonormal` exists for exactly this reason ([tc-netem][netem]). Second, both
  browsers remain on one host, so **all six associations share one emulated path** and
  §4.3's per-lane divergence is structurally unmeasurable in emulation. That is the one
  question emulation cannot answer.

### 6.3 Recommendation

**Use (b) and (c) together, for different questions, and never let one stand in for the
other.**

- **(c) netsim, for control-law work.** Sweeping `targetFrames`, `FEC_N_MIN`, `JIT_RELEASE`,
  the governor, and the §5.4 time-stretch idea. Seeded, paired A/B, n≥8 — the discipline
  the repo already uses. Fix the jitter distribution first: add a heavy-tailed option
  (paretonormal-shaped) alongside the uniform one, because at 250 ms the tail is the whole
  story. Add a **step-change** mode (route flap: +30 ms baseline shift, once, mid-run) —
  no current knob produces it and it is a real long-path event our spread-sized buffer
  will handle badly.
- **(b) cloud VM, for truth.** Every claim that leaves the building ("mouth-to-ear on
  US↔India is X") must come from a real path. Three vantages cover the brief: `us-east-1`
  (Virginia), `us-west-2` (Oregon) or `ap-northeast-1` (Tokyo), and `eu-west-2` (London).
  Report `perAssoc[].baseRttMs` spread, `clockOffsetMs` at both ends (the §0 asymmetry
  check), `jitClampedTicks`, `jitSpreadMaxLate`, and the selected ICE candidate pair at
  each end — that last one answers §3.2 in the same run.
- **Reject (a).**

### 6.4 Profiles to configure

Derived from §1.2. `netsim.mjs` takes end-to-end one-way, so these are one-way values.

| Profile | `oneWayMs` | `jitterMs` | `lossPct` | Rationale |
|---|---|---|---|---|
| **us-east↔india (public)** | **109** | 12 | 0.5 | Chennai↔Washington DC 217.7 ms RTT (WonderNetwork) |
| **us-east↔india (worst)** | **123** | 20 | 1.0 | Chennai↔New York 246.8 ms RTT |
| **us-east↔india (backbone)** | **101** | 6 | 0.2 | Verizon NA↔India 202.9 ms RTT, Jun 2026 |
| **us-west↔japan** | **47** | 5 | 0.2 | Tokyo↔Seattle 94.6 ms RTT |
| **us-west↔japan (SF)** | **52** | 6 | 0.3 | Tokyo↔SF 104.3 ms RTT |
| **eu↔india (backbone)** | **58** | 6 | 0.2 | Verizon India↔UK 115.4 ms RTT |
| **eu↔india (public)** | **86** | 15 | 0.7 | Chennai↔London 171.4 ms RTT |

Jitter values follow the shape of published international-path guidance (transatlantic
"200 ms latency, 0.5% loss"; lower-tier international "200 ms ±40 ms, 25% correlation",
[Calomel][calomel]) scaled to each pair's route quality — backbone paths get tight jitter
and low loss, public transit gets wider. **These are starting points, not measurements.**
The moment (b) is running, replace every one of them with the pair's *measured* RTT
percentiles and loss, and label the profiles with the date they were measured. A profile
that isn't traceable to a measurement is a guess wearing a table.

Also add, per netem's own vocabulary: **reordering**. Long paths reorder more (more ECMP
fabrics), our transport tolerates it by design, and it costs *spread* — which is the
quantity that sets our buffer. `netsim.mjs` mentions reordering in its contract; verify the
knob exists and exercise it at 0.5–2% on the long profiles.

---

## 7. What to do, ranked

1. **Read `perAssoc[].baseRttMs` on a real long path** (§4.3). Cheapest possible test of the
   largest predicted lever. Instrument exists; only the path is missing.
2. **Stand up one cloud-VM vantage** (§6.3b) — `us-east-1` first, since it is the hardest
   pair and the one that straddles G.114's 150 ms line.
3. **Per-lane de-skew in `noteArrival`** (§4.3 fix 2) if divergence is real. A few lines;
   stops path diversity from being read as jitter.
4. **Answer §3.2 empirically** — read the selected ICE pair at both ends under forced relay
   and find out whether Cloudflare carries our middle mile. Everything in §3.3 is
   conditional on this.
5. **`clockOffsetMs` symmetry check** (§0) before any intercontinental m2e number is
   published. Cheap, and without it our headline metric is silently biased on exactly the
   paths this brief is about.
6. **`FEC_N_MIN = 1` on long paths** (§4.4). Bandwidth for latency, the right direction at
   high RTT per RFC 8854.
7. **Build the UIR / overlap-collision instrument** (§5.3). The right product metric for
   intercontinental calls; m2e alone will mislead.
8. **Prototype post-silence time-stretch catch-up** (§5.4). The only technique that attacks
   turn-gap without touching the network.
9. **Fix netsim's jitter distribution and add a route-flap step mode** (§6.2c).
10. **Do not set `locationHint`** (§2.4). Instead publish the DO's actual colo so the
    question stops being speculative — and lean harder on pre-dial, which is worth more on
    a long DO path than it ever was locally.

---

## 8. References

Every URL below was fetched or searched for this brief.

- [verizon]: Verizon, *IP Latency Statistics* — https://www.verizon.com/business/terms/latency/
  (monthly means from 5-minute samples, Jul 2025–Jun 2026; Jun 2026: NA↔India 202.851 ms,
  Trans-Pacific 111.370 ms, India↔UK 115.364 ms, Trans-Atlantic 70.485 ms)
- [wn-chennai]: WonderNetwork, *Global Ping Statistics — Chennai* — https://wondernetwork.com/pings/Chennai
- [wn-tokyo]: WonderNetwork, *Global Ping Statistics — Tokyo* — https://wondernetwork.com/pings/Tokyo
- [geocables]: GeoCables, *Internet Latency Explained: RTT, Speed of Light & Real-World Delays* — https://geocables.com/internet-latency
- [g114]: ITU-T Recommendation G.114 (05/2003), *One-way transmission time* — https://www.itu.int/rec/dologin_pub.asp?lang=e&id=T-REC-G.114-200305-I!!PDF-E
  (mirror: http://www.cs.columbia.edu/~andreaf/new/documents/other/T-REC-G.114-200305.pdf)
- [do-loc]: Cloudflare, *Durable Objects — Data location* — https://developers.cloudflare.com/durable-objects/reference/data-location/
- [wdl]: *where.durableobjects.live* — https://where.durableobjects.live/
- [cf-turn]: Cloudflare, *Realtime TURN* — https://developers.cloudflare.com/realtime/turn/
- [cf-what-turn]: Cloudflare, *What is TURN?* — https://developers.cloudflare.com/realtime/turn/what-is-turn/
- [cf-turn-anycast]: Cloudflare blog, *TURN and anycast: making peer connections work globally* — https://blog.cloudflare.com/webrtc-turn-using-anycast/
- [cf-calls-anycast]: Cloudflare blog, *Cloudflare Calls: anycast WebRTC* — https://blog.cloudflare.com/cloudflare-calls-anycast-webrtc
- [cf-argo]: Cloudflare blog, *Introducing Argo — A faster, more reliable, more secure Internet for everyone* — https://blog.cloudflare.com/argo/
  (**35% latency decrease claim is for HTTP-to-origin traffic, not UDP media**)
- [rfc8854]: RFC 8854, *WebRTC Forward Error Correction Requirements* — https://www.rfc-editor.org/rfc/rfc8854.html
- [stivers]: Stivers et al. (2009), *Universals and cultural variation in turn-taking in conversation*, PNAS 106(26):10587–10592 — https://www.pnas.org/doi/10.1073/pnas.0903616106
- [boland]: Boland et al. (2022), *Zoom disrupts the rhythm of conversation*, J. Exp. Psychol. General — https://pubmed.ncbi.nlm.nih.gov/34748361/ · https://news.umich.edu/zoom-disrupts-the-rhythm-of-conversation
- [schoenenberg]: Schoenenberg, Raake & Koeppe (2014), *Why are you so slow? — Misattribution of transmission delay to attributes of the conversation partner at the far-end*, Int. J. Human-Computer Studies 72(5):477–487 — https://www.sciencedirect.com/science/article/abs/pii/S1071581914000287
- [kitawaki]: Kitawaki & Itoh (1991), *Pure delay effects on speech quality in telecommunications*, IEEE JSAC 9(4):586–593 — https://ieeexplore.ieee.org/document/81952/
- [seuren]: Seuren et al. (2021), *Whose turn is it anyway? Latency and the organization of turn-taking in video-mediated interaction*, J. Pragmatics — https://www.sciencedirect.com/science/article/pii/S0378216620302782 (abstract only; full text 403 to automated fetch)
- [liang]: Liang, Färber & Girod, *Adaptive playout scheduling and loss concealment for voice communication over IP networks*, IEEE Trans. Multimedia — https://web.stanford.edu/~bgirod/pdfs/LiangMM2003.pdf
  (also: Microsoft Research, *Enhanced Adaptive Playout Scheduling and Loss Concealment* — https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/AudioHealer.pdf)
- [netem]: `tc-netem(8)` manual — https://man.archlinux.org/man/core/iproute2/tc-netem.8.en
- [calomel]: Calomel.org, *Network Latency and Packet Loss Emulation* — https://calomel.org/network_loss_emulation.html
- [ripe-jitter]: Cyber Raiden, *Understanding packet jitter (packet delay variation)* — https://cyberraiden.wordpress.com/2026/05/02/understanding-the-packet-jitter-packet-delay-variation-in-computer-network/ ·
  arXiv, *Day in the Life of RIPE Atlas* — https://arxiv.org/html/2511.22474v1 ·
  arXiv, *Large-Scale Characterization and Segmentation of Internet Path Delays with Infinite HMMs* — https://arxiv.org/pdf/1910.12714

### Repo sources read

- `/Users/deveshpatel/Downloads/video calling/tape-app/src/worker.ts` — Room DO routing (`idFromName`, line 1603), `/api/ice` TURN minting (1504–1545)
- `/Users/deveshpatel/Downloads/video calling/tape-app/public/pcm.js` — jitter estimator (1690–1935), m2e accounting (2238), per-assoc RTT (1541, 2259), clock offset (1544, 1587)
- `/Users/deveshpatel/Downloads/video calling/tape-app/public/app.js` — jitter config (1573, 1578), `pairs: 6` (1602), ICE ladder (5181–5204)
- `/Users/deveshpatel/Downloads/video calling/core/pcmsw.js` — sliding-window FEC, `SW_WINDOW=12`, `SW_STRIDE=3`
- `/Users/deveshpatel/Downloads/video calling/testbed/netsim.mjs` — delay proxy, uniform jitter (268), two-crossing accounting (558–570)
- `/Users/deveshpatel/Downloads/video calling/testbed/rig.mjs` — measurement contract and non-claims
- `/Users/deveshpatel/Downloads/video calling/testbed/specs/ws-predial-spec.md` — 472 ms click→connected decomposition
- `/Users/deveshpatel/Downloads/video calling/MEASURED.md` — outputLatency 11 ms (4307), fleet m2e p50 48.3 ms (4308)
