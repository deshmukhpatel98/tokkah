# Design: three people in a room

*Design document. Nothing here is implemented, and nothing in this document
should be read as measured unless it says where it was measured. Every claim
about the current system carries a file anchor; every claim about the proposed
system is marked **reasoned** and is a prediction that the rig in §7 exists to
falsify.*

The ask is 3 occupants, not N. That distinction is the whole document: almost
every hard part below is cheap at exactly 3 and expensive at "N", and the
places where a general solution would be natural are named in §8 so the next
person can see what was deliberately not built.

---

## 1. What the 2-person design actually assumes

Before proposing anything, the inventory. These are the load-bearing places
where "two" is written into the system, with anchors. Everything in §2–§6 is
an answer to one of these lines.

| # | Assumption | Where |
|---|---|---|
| 1 | The room holds 2. `evictAndCheckFull` returns `peers.size >= 2`; the upgrade path 409s **before** the WebSocketPair exists | `tape-app/src/worker.ts` `evictAndCheckFull`, `signal` |
| 2 | Roles are `a`/`b`, assigned by **free slot**, not arrival ordinal — `taken.has('a') ? 'b' : 'a'` | `worker.ts` `admit` |
| 3 | **Only `a` ever calls `offer()`.** The answerer that needs a new offer sends `{type:'reoffer'}` and asks | `app.js` `m.type === 'reoffer'` handler; `fallbackToRtp`'s `if (role === 'a') offer()` |
| 4 | The relay is a broadcast to "everyone who is not me" — which is exactly one socket | `worker.ts` `admit`'s `message` listener |
| 5 | `welcome` describes a single peer: `peerPresent`, `peerLane`, `peerPcm` (all scalars) | `worker.ts` `admit`; `app.js` welcome handler |
| 6 | `peer-joined` / `peer-left` carry no identity — there is only one thing they could be about | `worker.ts` `admit`, `teardown` |
| 7 | A `peer-joined` arriving at a page that already had a peer means **the page is spent** and must reset in place | `app.js` `resetForNextPeer`, guarded on `hadPeer` |
| 8 | Lane A is one `initPcmAudio` instance: one capture worklet on the mic, one playout worklet, one SAB ring, one AEC2 far-end ring, one turn-end predictor | `pcm.js` graph IIFE (`capNode`, `playNode`, `aecSab`) |
| 9 | Lane A stripes are `pairs` associations to **the** peer: association 0 on the main pc, 1..N−1 on their own pcs, addressed by `idx` alone | `app.js` `startPcmStripes`, `pcmStripeOfferAll`, `pcm-offer/answer/ice` handlers |
| 10 | Lane 2 is one carrier, one encoder, one governor, one duress input | `tape.js` `startTapeRtp`; `app.js` `duress: () => pcm?.duress?.()` |
| 11 | One DTLS certificate covers the whole call, so one safety code describes it | `app.js` `localCert` / `certArg` |
| 12 | The UI has one remote surface (`#remote` + `#remoteCanvas` inside `#remoteWrap`) and one self view | `index.html`, `app.js` `layout()` |

Assumption 3 is the one that has cost the most to establish and the one this
design is most careful with. Assumption 2 exists *because* of 3: the comment in
`admit` records that ordinal assignment produced two `b`s after a reload, and
since only `a` offers, nobody offered and both ends sat on "connecting…" 100%
of the time. Assumption 7 is the second most dangerous, because in a 3-person
room a second `peer-joined` is **normal traffic**, not evidence of a spent page.

---

## 2. Topology: full mesh, and where it runs out

### 2.1 The choice

Full mesh. Each of the three ordered pairs {AB, AC, BC} gets its own complete
call: a main `RTCPeerConnection` with the video carrier and `pcm-audio`
(association 0), plus `pairs−1` data-channel-only stripe pcs, plus that pair's
FEC, governor, and clock sync.

The alternative — an SFU — is not proposed, and the reason is not effort. The
product's spine is "quality is a constant, time is the only shock absorber"
with a fixed-QP bitstream that is never transcoded, and Lane A is 24-bit linear
PCM in unreliable datagrams with sender-driven FEC keyed on the receiver's own
loss reports. An SFU that forwards without touching either lane is possible in
principle, but it is a media plane on Cloudflare — a second product — and §14's
"the DO NEVER touches media" is the current architecture's load-bearing
promise. Mesh keeps every measured law in §17 intact and pays for it in the
third participant's uplink. That is the trade, stated rather than hidden.

### 2.2 The bandwidth math, per device

Lane A, per direction per peer, from `pcm.js`'s own header: 384 samples ×
int24 = 1,152 B every 8 ms = **1.152 Mbps** of payload before anything.
`pcmpack` compression measures **0.56 of raw on speech** (`core/pcmpack.js`,
6,827 real frames), sliding-window parity at the default stride adds ~⅓ of
what it protects, and the 5 B compact header is noise at this size. That lands
in the **0.75–1.0 Mbps** band per direction per peer in speech, rising toward
the header's "~1.5 Mbps with FEC" figure on uncompressible input (white noise
hits the verbatim escape) and higher again when the loss ladder climbs or the
burst shield doubles frames.

Lane 2, per direction per peer: the measured sustained rates are **9.07–11.98
Mbps** (§17.7 decisive run, 30 fps, QP24, real camera §17.10) and **8.51–9.86
Mbps** on the canvas display path (§17.8 `crit-canvas`).

So for a phone in a 3-way call, using the middle of both bands:

| | 1:1 today | 3-way mesh (reasoned) |
|---|---:|---:|
| Lane A up | ~0.9 Mbps | **~1.8 Mbps** |
| Lane A down | ~0.9 Mbps | **~1.8 Mbps** |
| Lane 2 up | ~10 Mbps | **~20 Mbps** |
| Lane 2 down | ~10 Mbps | **~20 Mbps** |
| **Total up** | **~11 Mbps** | **~22 Mbps** |
| Peer connections | 6 (1 main + 5 stripes at `pcmpairs=6`) | **12** |
| SCTP associations | 6 | **12** |
| ICE agents / DTLS handshakes at join | 6 | **12** |

The uplink is the wall and it is not close. §17.2's tier ladder puts consumer
uplink at 2.5–25 Mbps; a 22 Mbps ask is the top of that ladder for two people
who were each comfortable at 11. **Reasoned, not measured: at today's defaults
a 3-way call is a good-desktop-on-good-wifi feature, and a phone on LTE will
not carry it.** The rig in §7 must produce this number before any of it ships.

### 2.3 Where the ceiling actually is on phones, and the reduced profile

Three separate ceilings, in the order they will be hit:

1. **Uplink.** Above. The only real lever is the video budget: §17.16's VMAF
   work says there is no crossover — spending fewer pixels is not free — so
   the honest 3-person lever is *fewer pixels per tile*, justified by the fact
   that each tile is now half the screen. `sendResCeiling()` already caps
   mobile encode at 720p-class and already takes the peer's panel size as
   input (`app.js` `syncSendRes`, task #52). In 3-mode each peer's advertised
   `display` w/h **is** the tile, not the viewport, so this mechanism produces
   the reduction for free and by measurement instead of by a new constant.
2. **Encode CPU.** The M13 already delivers 5–20 fps from **one** encoder
   (HANDOFF sessions 4–6; the cause is exposure-bound capture, not encode, but
   the encoder is the next thing behind it). Two `VideoEncoder` instances on
   the same device is the thing most likely to turn a working call into a slide
   show. §5.2 proposes sharing the encoder for exactly this reason.
3. **Association count.** 12 SCTP associations, each with its own cwnd,
   ping/pong, and gate budget (§17.13). §17.12 measured that **3 associations
   carry 98.2% at RTT 80 / 1% loss** with age p50 43 ms, where 1 collapses —
   so the 3-person default should be `pcmpairs=3` per peer (6 total, the same
   number of associations a 1:1 call runs today) rather than 6 per peer.
   `pairs` is already a per-call config (`app.js` `PCM_CFG.pairs`); making it
   per-mode is a constant, not a mechanism.

**The 3-person profile, then:** `pcmpairs=3`, video ceiling driven by the peer's
tile size through the existing `display` path, everything else unchanged. That
is ~1.8 Mbps of Lane A and (reasoned) ~10–14 Mbps of Lane 2 uplink. Still a
desktop feature; possibly a phone-on-good-wifi feature. Measure it.

---

## 3. Signaling

### 3.1 The one-offerer law, generalized

Today: "only `a` ever calls `offer()`". The generalization is one line of
mechanism and it must be stated as a *pair* law, because with three peers
"offerer" is not a property of a person:

> **For any pair of occupants, the one whose role letter sorts first is the
> offerer for that pair.**

`a` offers to `b` and to `c`; `b` offers to `c`; `c` offers to nobody. At two
occupants this is byte-identical to today's law in every role combination the
room can produce, including the free-slot reuse cases: {a,b} → a offers, {a,c}
→ a offers, {b,c} → b offers. There is no arrival-order input, so the reload
failure that motivated free-slot assignment cannot come back in a new shape:
whatever letters are held, exactly one end of each pair offers.

`reoffer` keeps its meaning and gains an address: the non-offering end of a
pair sends `{type:'reoffer', to: <offerer's role>}` and the offerer answers by
offering to that peer only.

Corollary that must be written down because it is easy to lose: **`role` stops
being a global property of the page and becomes an index into a peer table.**
Everything currently reading `role === 'a'` (`app.js`: welcome handler,
peer-joined handler, `startTape(role === 'a')`, `startPcm(role === 'a')`,
`fallbackToRtp`'s renegotiate, `reoffer`) is really asking "am I the offerer
for *this* pair", and each site must be re-read that way rather than
mechanically renamed.

### 3.2 The relay becomes addressed

Today the DO's `message` listener forwards each frame to every socket that is
not the sender — a broadcast that happens to have one recipient. Three
occupants split the message set in two:

- **Pairwise** (must be addressed): `offer`, `answer`, `ice`, `reoffer`,
  `pcm-offer`, `pcm-answer`, `pcm-ice`, `audio-fallback`, `video-fallback`.
  Delivering any of these to the wrong peer is a broken call, and delivering
  an `offer` to both is glare by construction.
- **Room-wide** (broadcast is correct): `display`, `xlate-on`, `xlate-off`,
  `away`, `geom`.

Mechanism, in the DO's relay listener:

```
parse the frame as JSON (cheap: these are small control messages)
  if it has a `to` field → deliver to the single socket holding that role
  else                   → deliver to every other socket, exactly as today
in both cases, stamp `from` with THIS socket's role before forwarding
```

Two properties of that stamp matter. **`from` is server-stamped, never
client-claimed** — a client that sets its own `from` has it overwritten, so a
peer cannot impersonate the third occupant's signaling. And **an unparseable
frame keeps today's behaviour** (broadcast, unmodified), so nothing that
currently rides this socket can be broken by the router.

Cost, honestly: the DO now parses every relayed frame instead of forwarding an
opaque string. §17.19 measured no knee up to ~100 msg/s / 100 KB/s aggregate —
50× the design point — with SDP-sized (8 KB) bursts included, so the parse is
affordable at this traffic level. It is still a new per-message cost on the one
component the design promises never touches media, and it should be measured
again at 3 occupants rather than assumed to carry over.

### 3.3 `welcome`, `peer-joined`, `peer-left` carry who

```jsonc
// welcome — additive; every existing field keeps its exact meaning
{ "type": "welcome", "role": "b",
  "peerPresent": true,          // legacy: peers.length > 0
  "peerLane": 2, "peerPcm": 1,  // legacy: the FIRST other peer's caps
  "cap": 3,                     // the cap this room is currently enforcing
  "peers": [ { "role": "a", "lane": 2, "pcm": 1 } ],
  "session_epoch_us": 0, "logToken": "…" }

{ "type": "peer-joined", "peer": "c", "peerLane": 2, "peerPcm": 1 }
{ "type": "peer-left",   "peer": "c" }
```

`peers` is the new truth; `peerPresent`/`peerLane`/`peerPcm` are kept and keep
describing the first other occupant, so a client that never learned about
`peers` sees exactly today's message when the room has two people. The `peer`
field on join/left is additive for the same reason.

### 3.4 Compatibility gate: how a 3-cap room can never strand an old client

An old client in a 3-person room is a silent disaster: it would receive a
second peer's `offer` addressed to it, apply it to its single `pc`, and destroy
the call it already had. The gate must therefore be **admission-time and
server-enforced**, not a client-side check.

The client declares its wire version on the upgrade URL (and in the hold-mode
`{type:'join'}` body, alongside the `lane`/`pcm`/`sid` it already sends):
`&v=2`. The DO stores it per socket in a `vers` map, parallel to `laneCaps` and
`pcmCaps` — the same pattern, for the same stated reason: the role-assignment
logic stays untouched.

The effective cap is then a function of who is in the room:

```
cap() = (every socket in peers has v >= 2) && THREE_ENABLED ? 3 : 2
```

- An old client (no `v`, so `v = 1`) **anywhere** in the room drops the cap to
  2 for as long as it is present. The room is never in a state where a 3rd
  socket can be admitted alongside a client that cannot address messages.
- A third joiner arriving at a room whose cap is 2 gets exactly today's
  rejection: `409 room full` pre-open on the upgrade path, `{type:'full'}` +
  close on the hold path. Both are unchanged code paths.
- `THREE_ENABLED` is the server-side flag (§7). With it off, `cap()` is
  constant 2 and the entire feature is inert regardless of what clients
  declare.

The awkward case, named rather than hidden: **two v2 clients are in a 3-cap
room, a third joins, and then one of the three is an old client** — impossible
by the rule above, since the old client could not have been admitted. But the
reverse *is* reachable: a v2 client reloads into an older cached build and
rejoins as v1 while two peers are talking. The room is then over its own cap.
The rule is that `cap()` is evaluated at **admission only** — an already-seated
occupant is never evicted by a cap change — and the v1 client, seeing messages
it does not understand, drops them (`app.js`'s message handler is a chain of
`else if`, so unknown types fall off the end harmlessly), gets no addressed
offer from anyone (v2 peers read `peers[].v` and skip pairing with a v1 peer),
and lands in a call where it can see and hear one of the two others. Degraded,
honest, not broken — and the health beacon will show it.

---

## 4. The Room Durable Object

All changes are in `tape-app/src/worker.ts`, class `Room`. The interpreter
(`xlate`/`xlateGemini`) is explicitly **out of scope** — see §8.

### 4.1 Slot law for a/b/c

```ts
const ROLES = ['a', 'b', 'c'] as const;
const taken = new Set(this.peers.values());
const role = ROLES.find((r) => !taken.has(r));  // first FREE slot
```

This is the existing law, unchanged in kind: take the free slot, not the next
ordinal. The comment in `admit` explaining why (`two 'b's mean nobody offers`)
survives verbatim and gains one sentence: with the pair-ordering law of §3.1,
free-slot reuse is still what makes "exactly one offerer per pair" a property
of the room rather than an accident of arrival order. Concretely: `b` leaves,
rejoins, gets `b` back; the pair {a,b} still has `a` offering, and the pair
{b,c} still has `b` offering, with no state carried across the gap.

`role` must remain a **single letter** — it is the address in `to`/`from`, it is
the telemetry `role` column (`ingest`'s `String(body.role).slice(0,16)`), and
it is what `xl` keys sessions by.

### 4.2 Cap change

`evictAndCheckFull(sid)` grows one parameter and one line:

```ts
private evictAndCheckFull(sid: string | null, v: number): boolean {
  // …sweep dead sockets, evict same-sid ghosts: UNCHANGED, both loops already
  // iterate every peer and need no knowledge of how many there are…
  return this.peers.size >= this.cap(v);
}
```

where `cap(vArriving)` is §3.4's function, taking the arriving socket's version
into account so a v1 arrival is judged against a cap of 2 even in a room of two
v2 clients. Everything else about admission is unchanged, and that includes the
two things that must not move:

- The **upgrade path still checks before creating the `WebSocketPair`**, so an
  over-cap third (or fourth) join is a pre-open HTTP `409`, not an open-then-
  close. The spec that introduced hold-mode calls this out explicitly and the
  client's "room full" detection depends on it.
- The **hold path still checks inside the join handler**, sends
  `{type:'full'}`, and closes. A lurker is still never an occupant.

### 4.3 Hold-socket admission

Unchanged in structure. `{type:'join', lane, pcm, sid}` gains `v`. The 120 s
idle timer, the `joined` latch, the "held sockets ignore non-join messages"
rule, and the registry stamp all generalize without edit — none of them counts
occupants.

One new consideration: with a cap of 3, **two** lobby tabs can be holding while
two people talk. `held` is a Set and already supports that; the only thing to
check is that the timer map is keyed per socket (it is).

### 4.4 Ghost eviction

`evictAndCheckFull`'s sid loop already iterates all peers and closes every
socket with a matching sid. At 3 occupants it does the same thing for the same
reason. **No change.** What does change is the blast radius of a bug here: a
mis-keyed eviction now drops one of two live conversations instead of ending
the call outright, which is harder to notice. The rig should assert that a
rejoin by A evicts A's ghost and leaves both B and C's sockets open.

### 4.5 Teardown and `peer-left`

```ts
const teardown = () => {
  const gone = this.peers.get(server);
  this.peers.delete(server); this.laneCaps.delete(server);
  this.pcmCaps.delete(server); this.sids.delete(server); this.vers.delete(server);
  for (const [p] of this.peers) {
    try { p.send(JSON.stringify({ type: 'peer-left', peer: gone })); } catch { /* ignore */ }
  }
};
```

The loop is already a broadcast to all remaining peers; it gains the `peer`
field and the `vers` cleanup. Note `gone` must be read **before** the delete.

### 4.6 `peer-joined` fan-out

Today the incumbent is told only when `peers.size === 2`. The general form: on
every admission, tell **every other occupant** about the arriver, and tell the
arriver about everyone via `welcome.peers`. The `peers.size === 2` guard
disappears; the incumbent-learns-the-arriver's-transport comment stays true and
now applies to two incumbents.

### 4.7 Registry

`room-seen` is stamped per join, both at the route (non-hold upgrades) and
inside the DO (hold-joins). Three joins stamp three times and the `joins`
counter increments three times, which is what it already means. **No change.**

---

## 5. The lanes

### 5.1 Lane A: one instance with per-peer receive sets, not N−1 instances

Two candidate shapes:

**(a) Two full `initPcmAudio` instances, one per peer.** Cheap to write —
`startPcm(initiator)` becomes `startPcm(peer, initiator)` and the stripe
signalling already carries an index. It is also wrong, and the reasons are all
in `pcm.js`'s graph IIFE:

- It builds a **`pcm-capture` worklet node on the mic** (`source =
  ctx.createMediaStreamSource(stream); source.connect(capNode)`). Two instances
  means two capture worklets reading the same track, two `capSab` rings, two
  independent frame-sequence spaces, two `pcmpack` encoders doing identical
  compression work, and two turn-end predictors emitting `T_PRED` on
  independent clocks. The compression and packing cost doubles for zero
  benefit: the bytes are identical.
- It builds a **`pcm-playout` worklet whose `process()` writes the far-end
  reference ring for AEC2** (`pcm-worklet.js` `process`: `aecRing.subarray(...)
  .set(out)` keyed on `currentFrame/128`). Two playout worklets writing the
  same-index slot means the second one **overwrites** the first: the canceller's
  far-end reference becomes one of the two remote voices, chosen by graph order,
  and the other voice is uncancelled echo. This is the single most expensive
  failure in the list, because it presents as "the app has echo again" with
  every counter green.
- It allocates a second SAB ring, a second detector stream, and a second
  `snapshot()` surface that the stall machine (`app.js` `stallPcmSample`)
  reads as though it were the call.

**(b) One instance, per-peer receive/playout sets — the recommendation.** Split
`initPcmAudio` along a seam that already exists in the file:

```
  ONE per page (capture half)          PER PEER (receive half)
  ──────────────────────────           ───────────────────────
  pcm-capture worklet + capSab         association set (pairs pcs + channels)
  pcmpack compression                  RS/SW encoder state, parity ladder
  turn-end predictor (Lane 0)          T_LOSS ladder, burst shield, duress
  frame seq space                      SAB ring + pcm-playout worklet
  AEC2 far-end tap (see below)         onset detector stream, conceal counters
                                       ping/pong, baseRtt, gate budget
```

The seam is honest because the file already draws it: every congestion-flavoured
counter is documented as **per association** (§17.13, `newAssoc`), and "per
peer" is just a coarser grouping of the same thing. The capture worklet, the
frame numbering, and the SAB ring layout are all untouched — which is the test
the prompt asks for. *Least surgery* here means the worklets and `core/*` do not
change at all except for the AEC tap below.

Fan-out is one line at the send site: a captured frame is offered to each
peer's association set independently. Each peer runs its own FEC because each
peer reports its own loss — that is the ladder's whole design (`onPeerLoss`),
and collapsing it to a shared code rate would make the good path pay the bad
path's parity.

### 5.2 Playout mixing and the AEC far-end reference

Two `pcm-playout` nodes, each `connect(ctx.destination)`. The Web Audio graph
sums them at the destination — no mixer node, no gain staging, no change to
`fill()`, and each peer keeps its own concealment, drift correction, playhead,
and presence render. Both worklets run on the same audio thread, once per
render quantum, so the sum is sample-exact.

The one thing that does **not** compose is the AEC2 far-end reference ring. It
must contain the sum of both remote voices, and today each playout node writes
(not accumulates) its own block. Two options:

1. **Epoch-tagged accumulate.** Keep the write in `pcm-worklet.js`'s
   `process()`, but make it "first writer this quantum clears, subsequent
   writers add", using an `Atomics.compareExchange` on a per-slot epoch int
   next to `aecHi`. Order-independent, no graph change, ~128 extra adds per
   quantum. The tap stays exactly where the law requires it — after `fill()`,
   before `presence.render()` — so the canceller still sees the pristine mono
   lane and the room still exists only in the last metres before the DAC.
2. **A summing tap node.** Both playouts feed one passthrough worklet that
   writes the sum and forwards to the destination. Conceptually cleaner, but it
   moves the tap **after** presence renders stereo, which breaks the stated law
   of `presence-core.js` ("the canceller and every detector keep seeing the
   pristine mono lane"). Rejected for that reason.

**Recommendation: option 1.** It is ~10 lines in a worklet that otherwise does
not change, and it preserves the one property the AEC2 work was built on.

Two consequences to write down:

- **Detectors are per peer now.** The remote onset detector runs inside each
  playout worklet on that peer's samples; `TurnTaking` (`turntaking.js`,
  constructed once in `join()`) is a 1:1 model. At 3, instantiate one per
  remote peer and report `humanGapMs` per peer in the health beacon. Do **not**
  try to build a three-body turn model — see §8.
- **`stallPcmSample`'s HOLD state becomes per peer.** `frac > HOLD_ENTER_FRAC`
  on peer C's concealment does not mean the call is paused; it means C is
  unreachable. The badge text follows the UI in §6.

### 5.3 Lane A stripe signalling

`pcm-offer` / `pcm-answer` / `pcm-ice` currently carry `{idx}` and index
`pcmPcs[idx]`. They gain `to` (routed by the DO, §3.2) and index
`pcmPcs[peer][idx]`. The offerer for each pair is decided by §3.1's letter
ordering, exactly as the main pc's offer is, and `pcmStripeOfferAll` is called
from the same points it is today — per pair.

### 5.4 The safety code

`app.js` reuses one certificate across every pc so a single code covers the
whole call. With three, there are three pairwise DTLS relationships and this
page participates in two of them. The shared certificate still makes **our**
identity single, so the honest generalization is: **one code per pair**, shown
against that peer's tile, derived exactly as today from that pair's
fingerprints. A single room-wide code would be a claim the cryptography does
not support (it would say nothing about the B↔C leg, which this page cannot
see). If the UI cannot afford two codes, show none and say why — do not show
one and imply it covers the room.

---

## 6. Video: two tiles, and what duress does when two senders compete

### 6.1 One encoder or two

Lane 2 today: one `VideoEncoder` at fixed QP, admission control at **capture**
(law 7: frames already encoded are in the reference chain and must never be
dropped), a per-receiver AIMD governor driven by receiver-reported frame age
(law 10), per-receiver FEC, and a 90-frame retention ring for re-splice.

**Two encoders** is the obvious shape and is what a naive mesh does: two
`startTapeRtp` instances, each with its own carrier, governor, and FEC. It is
also 2× encode CPU on a device where the encoder is already the next ceiling
behind capture (§2.3), and it doubles the `configure()` churn that §17's rate
control is careful about.

**One shared encoder, per-peer transport** is the recommendation for the
3-only scope:

- One capture→admission→encode chain, unchanged.
- Each encoded chunk is handed to **both** peers' transport halves: each with
  its own parity group state, its own re-splice ring, its own carrier
  substitution, its own ctl channel.
- **Admission becomes `min` over the peers' governors.** The reference chain is
  shared, so a frame skipped for one peer is skipped for both — there is no
  such thing as a per-peer drop once one bitstream feeds two decoders.
- **Rate control (QP / VBR target) is driven by the worst peer**, for the same
  reason.

The cost is explicit and must be said in the product's own voice: **in a
3-person call, the person on the worst connection sets the video quality
everyone sends.** That is the price of one encoder, and it is the honest price —
the alternative charges the sender's CPU instead. Both should exist behind a
flag (`?l23enc=1|2`), with `1` (shared) the default, and the rig should measure
the CPU and quality difference rather than the doc asserting it.

### 6.2 Duress coupling when two senders compete

`duress()` is a single number from the single audio lane, consumed in
`tape.js`'s `rcPollBudget()`. At 3:

- Each peer's Lane A half produces its own `duress()` (its own loss ladder, its
  own burst-shield state).
- With one shared encoder there is one budget, so it consumes
  **`max(duressPerPeer)`** — video ducks when *either* audio path is drowning,
  because audio is the call and video yields first. That rule is unchanged; only
  the aggregation is new.
- With two encoders, each consumes its own peer's duress and the coupling stays
  strictly pairwise.

The new failure mode, named so the rig can look for it: **duress ping-pong**.
Two peers on marginal links can alternate duress, holding the shared budget
down continuously while neither link is individually bad enough to justify it.
Mitigation if it appears: hysteresis on the aggregated value (the ladder already
uses a fast/slow window pair for exactly this class of problem — `onPeerLoss`).
Do not pre-build it; measure first.

### 6.3 Presence, optionally

`presence-core.js` renders one fixed tap plan for the one remote voice. With two
remotes in one context, giving each a **different** tap table (the existing one,
and its L/R mirror) would put the two voices in different apparent places, which
is the cheapest real fix for the "who is talking" problem a 3-way call creates
and the one thing a mesh can do that an SFU mixdown cannot. It is a table swap,
not a mechanism. It is also **unproven** and outside the minimum scope: list it
as a flagged follow-up (`?presence3=1`), not as part of the ship.

---

## 7. Rollout

### 7.1 Flags

| Flag | Where | Default | Meaning |
|---|---|---|---|
| `THREE_ENABLED` | worker env/const | **off** | server-side master switch; off ⇒ `cap()` is constant 2 and the DO is byte-identical to today |
| `&v=2` | ws upgrade URL + hold `join` body | sent by new clients | wire version; the admission gate of §3.4 |
| `?three=0` | page | on once shipped | client opt-out: sends `v=1`, behaves exactly like today |
| `?l23enc=` | page | `1` (shared encoder) | `2` = one encoder per peer (§6.1) |
| `?pcmpairs=` | page | `6` at 2, **`3` at 3** | §2.3 |
| `?presence3=1` | page | off | per-peer tap tables (§6.3) |

The gate that matters: **with `THREE_ENABLED` off, the server is byte-identical
to today**, including the pre-open 409 — so the client work can ship and sit
inert, and the feature turns on in one place.

### 7.2 The live 3-browser rig

New: `testbed/call3.mjs`, modelled on `testbed/call.mjs` (three `launch()`
calls, three fake-mic WAVs, `--p2psim --rtt --loss` per side, room ids already
carry a random suffix to avoid the same-millisecond collision documented there).
It must assert, and fail on:

1. **Admission.** Three joins succeed; roles are `a`,`b`,`c`; a **fourth** join
   is rejected with a pre-open `409` and the three sitting calls are unaffected
   (echo RTT immediately after, no close frames) — the §17.19 method, one
   occupant further along.
2. **One offerer per pair.** Count `createOffer` per pc across all three pages:
   exactly one end of each of the three pairs offers, and no pair ever has two
   offers in flight. This is the assertion that protects assumption 3.
3. **Six live media legs.** Each page has 2 connected main pcs and
   2×(`pairs`−1) connected stripe pcs; every `pcm-audio*` channel open in both
   directions.
4. **Pristine audio.** Per peer: `drop(link) 0`, `fecFailed 0`, concealed ms at
   the §17.13 gate levels, `mode sab`, and the far-end reference carries **both**
   voices — assert on the AEC2 stats (`stats.aec2`), because §5.2's option-1 bug
   is invisible in every transport counter.
5. **Both video tiles alive.** `framesOut > 0` on both remote surfaces on all
   three pages; no `lane-watchdog` fallback; no `tape-fallback`.
6. **Free-slot reuse.** `b` reloads mid-call; it comes back as `b`, its two
   pairs re-negotiate with the same offerers, and **`a` and `c` do not reset**
   (assumption 7 — this is the assertion that catches the `hadPeer` bug).
7. **Departure.** `c` leaves; `a` and `b` receive `peer-left {peer:'c'}`, tear
   down only that pair, and their own call is byte-identical afterwards
   (echo RTT, concealment, `framesOut` all continuous across the event).
8. **Legacy interop.** One page pinned `?three=0`: the room's cap reads 2, the
   third join is refused, and the two-person call it does have is
   indistinguishable from a `call.mjs` run.
9. **Error counters.** `safe()` error counts are zero on all three pages. The
   UI-rewrite session's postmortem records that a `cap is not defined` bug lived
   inside `safe()` for a whole session because no suite asserted on this. Assert
   on it.

### 7.3 INVARIANTS THAT MUST NOT BREAK

Non-negotiable. Each has a live cost recorded in `DESIGN.md`/`HANDOFF.md`.

1. **Pre-open 409 for over-cap.** A join beyond the cap is refused *before* the
   WebSocketPair exists, as an HTTP status — never an open-then-close. Clients
   today read pre-open failure as "room full".
2. **One offerer per pair, always, decided without reference to arrival order.**
   Two offerers is glare; zero offerers is the reload bug that motivated
   free-slot assignment (100% reproducible, both ends stuck on "connecting…").
3. **Free-slot role assignment.** `a`/`b`/`c` is a *set of slots*, not a
   counter.
4. **Pristine-audio law.** Never downsampled, never ducked, never compressed
   lossily, never on a reliable channel; concealment bounded at 24 ms then HOLD.
   The AEC2 far-end tap and every detector see the pristine mono lane **before**
   presence renders. Adding a second remote must not move that tap.
5. **Pre-dial semantics.** A held socket is never an occupant: it does not count
   toward the cap, never relays, never receives relayed traffic, cannot inject
   signaling, times out at 120 s, and stamps the registry only on admission.
6. **Lane 2 never renegotiates**, and no runtime `setParameters` /
   `jitterBufferTarget` / `playoutDelayHint` write ever lands on a tape pc.
   Both laws are now per pair, and a shared encoder does not relax either.
7. **Frames already encoded are never dropped.** Admission is at capture. With
   a shared encoder, admission is `min` over peers — never a post-encode
   per-peer drop.
8. **Flag-off is byte-identical.** `THREE_ENABLED` off ⇒ the DO's wire
   behaviour is today's, byte for byte. `?three=0` ⇒ the client's is.
9. **A v1 client anywhere in the room caps it at 2.** No third socket is ever
   admitted alongside a client that cannot address messages.
10. **The DO never touches media.** The addressed relay parses control frames;
    it does not, and must not, grow toward forwarding anything else.

---

## 8. Cost

### 8.1 What this complicates forever

- **`role` stops being a scalar.** Every `role === 'a'` in `app.js` becomes a
  per-pair question. That is roughly a dozen sites today and it is a permanent
  tax on every future change to negotiation: from here on, "who offers" is
  never answerable without naming a peer.
- **Every lane counter becomes a table.** Concealment, loss, duress, HOLD, RTT,
  `framesOut`, the safety code, the stall regime — all of them are per peer
  now. The HUD, the telemetry schema, the health beacon's `concealPct` /
  `mouthToEarMs` / `glassToGlassMs` / `humanGapMs`, and every rig that reads
  them acquire a dimension. The beacon's allowlist (`HB_FIELDS`) is strict by
  design, so this is a schema change, not a shrug.
- **The single biggest UX regression is real and permanent: the worst link in
  the room governs.** Shared encoder ⇒ shared quality; `max` duress ⇒ everyone
  ducks. A 1:1 call degrades for the two people on it; a 3-way call degrades
  for the person who did nothing wrong.
- **Uplink triples the failure surface.** §17.19's "the real scaling axis is
  rooms, not occupants" stops being true of the client: 12 ICE agents at join,
  12 DTLS handshakes, 12 cwnds. Connect time, connect *success rate* (the
  beacon's headline number), and recovery all get harder in ways the 1:1
  numbers cannot predict.
- **The interpreter does not generalize.** `xl` is keyed by role `'a'|'b'` and
  `peer()` is literally `role === 'a' ? 'b' : 'a'`, with one upstream session
  per side opened against *the* peer's listening language. Three languages need
  either N−1 upstream sessions per speaker or a language-keyed session pool —
  a redesign of TRANSLATE-SPEC, not an edit. **Out of scope: translation is
  disabled in 3-person rooms**, and the 🌐 button says so.
- **Recovery gets a new state.** `recoverCall` reloads into the room; at 3 it
  reloads into a room that may have moved on. `resetForNextPeer` must become
  per-pair or it will tear down a healthy leg to fix a broken one.

### 8.2 The smallest 3-only scope

The version that avoids generalizing to N, and what each choice buys:

- **Cap 3, hard-coded.** `ROLES = ['a','b','c']` as a literal, not a count. No
  `maxPeers` config, no dynamic layout algebra. Buys: the UI is two tiles, a
  known geometry, not a grid solver.
- **Fixed pair table.** `[ab, ac, bc]` — three pairs, enumerable, testable
  exhaustively. Buys: assertion 2 in §7.2 can check *every* pair rather than
  sampling.
- **No active-speaker logic, no spotlight, no dominant-speaker switching.** All
  streams arrive; show both, equally, always. Buys: no new state machine, and
  it is what UI-SPEC's fatigue rules want anyway (§6, §8.3).
- **No per-peer video quality negotiation.** One encoder, `min` admission. Buys:
  no simulcast, no per-peer encoder ladder, no rate allocation problem.
- **No translation, no per-peer recording, no room-wide safety code.** Each is
  a redesign, not a feature flag.
- **`pcmpairs=3` in 3-mode.** Buys: the association count stays where §17.12
  measured it.

If a fourth participant is ever asked for, the honest answer is that this
design does not extend — the uplink math (§2.2) says a 4-way mesh asks ~33 Mbps
up at today's video budget, which is past the top of §17.2's tier ladder. Four
is an SFU conversation, and the mesh work here does not build toward one.

---

## 9. Phased work order

Sized for one worker per phase, each phase independently testable, each with a
flag that makes it inert until the next one lands. File anchors are exact;
line numbers drift, so anchors are function names and comment markers.

### Phase 1 — DO: roles, cap, addressed relay (server only)

**File: `tape-app/src/worker.ts` only.** No client changes; with the flag off,
prod behaviour is byte-identical.

1. Add `private vers = new Map<WebSocket, number>()` beside `laneCaps` /
   `pcmCaps`, torn down in the same places (`evictAndCheckFull`'s sid loop,
   `admit`'s `teardown`).
2. Add `const THREE_ENABLED = false;` (module const) and
   `private cap(vArriving: number): number` implementing §3.4.
3. `evictAndCheckFull(sid, v)`: signature + final line only. Both loops
   unchanged.
4. `admit`: free-slot over `['a','b','c']`; register `vers`; build
   `welcome.peers` + `welcome.cap` while keeping `peerPresent`/`peerLane`/
   `peerPcm` describing the first other peer; fan `peer-joined` (with `peer`,
   `peerLane`, `peerPcm`) to **all** other occupants, dropping the
   `peers.size === 2` guard; `teardown` sends `peer-left {peer}`.
5. Relay listener: parse, route on `to`, stamp `from`, broadcast otherwise,
   fall back to today's opaque broadcast on parse failure (§3.2).
6. Both admission call sites read `v` (`q.get('v')` on the upgrade path,
   `m.v` in the hold-join handler).

**Gate:** `testbed/lobby-probe.mjs` unchanged and green (it asserts today's
409, role order, epoch persistence, relay latency). `tsc` clean.

### Phase 2 — client: peer table, per-pair negotiation

**File: `tape-app/public/app.js`.**

1. `?three=` flag next to `PREDIAL` (`const PREDIAL = …`, ~line 1607); send
   `v=2` on the ws URL at the dial site and in the pre-dial `sendJoin()` body
   (`predial.join`).
2. Replace the module-scope `let role = null` (~line 68) reader pattern: keep
   `role` as *our* letter; add `const peers = new Map()` holding per-peer
   `{ role, pc, tape, tapePre, pcmPcs, lane, pcm, fellBack… }`.
3. Welcome handler (`m.type === 'welcome'`): iterate `m.peers ?? []` and build a
   pair for each; offer to each pair where our letter sorts first. The existing
   single-peer body becomes the per-pair body, called in a loop.
4. `peer-joined`: build the one new pair. **Delete the `hadPeer` →
   `resetForNextPeer` trigger for peers we have never paired with**; keep it
   for a `peer-joined` naming a peer we already hold a spent pc for. This is
   invariant-critical (§7.2 assertion 6).
5. `offer/answer/ice/reoffer` handlers: dispatch on `m.from` to that pair's pc.
6. `peer-left`: tear down that pair only; the "they left" UI moves to §6's
   per-tile state.

**Gate:** `testbed/call.mjs` unchanged and green with `?three=1` on both sides
(a 2-person call through the new code paths must be indistinguishable), plus
the same with `?three=0`.

### Phase 3 — Lane A split

**Files: `tape-app/public/pcm.js`, `tape-app/public/pcm-worklet.js`,
`tape-app/public/app.js`.** `core/*` untouched.

1. `pcm.js`: split `initPcmAudio` per §5.1 — capture half constructed once
   (`capNode`, `capSab`, `pcmpack`, turn-end); receive half (`assocs`, ring,
   `playNode`, FEC decode, ladder, ping/pong, `snapshot()`) constructed per
   peer. The send path offers each captured frame to every peer's half.
2. `pcm-worklet.js`: epoch-tagged accumulate on the AEC2 far-end ring in
   `process()` (§5.2 option 1), keeping the write **before**
   `presence.render()`. Nothing else in the worklet changes.
3. `app.js`: `startPcmStripes` / `pcmStripeOfferAll` / `pcm-offer|answer|ice`
   handlers become per peer (`pcmPcs[peer][idx]`, `to` on the wire);
   `PCM_CFG.pairs` default 3 when three-mode is on; `stallPcmSample` and
   `duress` consumption become per peer (`max` for the shared video budget).

**Gate:** `core/pcmrs.test.mjs`, `core/pcmsw.test.mjs`, `core/onset.test.mjs`,
`core/aec.test.mjs`, `tape-app/turntaking.test.mjs` all unchanged and green;
`testbed/call.mjs` at `pcmpairs=1` and `=6` byte-comparable to today's gate
numbers (§17.13 gate 1/2 levels).

### Phase 4 — Lane 2 shared encoder, two tiles

**Files: `tape-app/public/tape.js`, `tape-app/public/app.js`,
`tape-app/public/index.html`.**

1. `tape.js`: `startTapeRtp` gains a per-peer transport half (carrier
   substitution, FEC group state, re-splice ring, ctl channel, governor) behind
   a shared encode half; admission takes `min` over governors; `rcPollBudget`
   consumes `max` duress. `?l23enc=2` keeps two whole instances as the control
   arm.
2. `app.js`: `startTape(role === 'a')` becomes per pair; the `tape.slot`
   recvonly-transceiver block and `claimSlot` call run per pair, with the offerer
   decided by §3.1. **Laws 1, 2, 9, 11, 12 in HANDOFF's list apply per pc and
   none of them relax.**
3. `index.html`: a second `#remoteWrap`/`#remote`/`#remoteCanvas`/`#remoteFill`
   set; `#call.contain #remoteWrap canvas:not(#remoteFill)` and every other
   rule keyed on those ids must be re-checked (the letterbox-wash regression
   in the UI session came from exactly this class of selector collision).

**Gate:** `testbed/call.mjs` green (1:1 through the shared-encoder path),
`testbed/ui-call.mjs` + `testbed/fscheck-call.mjs` green on the new markup at
all five aspect ratios.

### Phase 5 — UI

**Files: `tape-app/public/index.html`, `tape-app/public/app.js`.**

Two equal tiles: side by side on landscape, stacked on portrait, each
contain-fit with its own letterbox wash, each carrying its own name-free state
line ("they left", "holding · audio live", "connection paused") in the existing
glass recipe. Self view stays press-and-hold PiP, unchanged. The control bar,
the more sheet, and the leave-confirm collapse are unchanged — the bar is
already at its width limit on a 390 px phone (the leave-pill overflow bug), so
**no new control ships in the bar**. No spotlight, no active-speaker swap, no
tile reordering: a tile that moves while someone is talking is exactly the
class of motion §1.1 is about.

**Gate:** `testbed/ui-call.mjs` extended to three peers, asserting the same
properties it asserts today (≥44 px controls, safe-area padding, bar × PiP ×
badge non-overlap measured on the buttons, no gap at any edge of either wash),
plus: neither tile ever overlaps the bar, and both tiles are on-screen at every
aspect ratio in the matrix.

### Phase 6 — Rig and enablement

**Files: `testbed/call3.mjs` (new), `tape-app/src/worker.ts` (flag flip).**

Build the rig of §7.2, run all nine assertions, and only then flip
`THREE_ENABLED`. The uplink number in §2.2 is a prediction until this rig
prints it; if it prints 22 Mbps and the phone arm fails, the profile in §2.3
is the lever to try, and the honest outcome may be "3-way is desktop-only",
documented as such.
