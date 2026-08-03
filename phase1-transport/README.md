# Phase 1 — the transport gate

One question: **can an unordered/unreliable `RTCDataChannel` sustain 12 Mbps at realistic RTT, with
*our* pacer as the binding controller rather than usrsctp's congestion window?**

Nothing here touches a camera. This is deliberately the first thing built, because it's the only risk
in [DESIGN.md](../DESIGN.md) capable of invalidating the whole design, and it's cheap to settle. If it
fails, the transport changes — and the transport determines the packetizer, the ARQ deadlines, and the
congestion controller's entire input set.

---

## Run it

```bash
cd phase1-transport && npm install
```

```bash
npx wrangler dev --port 8791
```

### Automated, on one machine (how the gate was actually settled)

```bash
node gate.mjs --rtt=80 --mode=soak --target=12 --sec=30
node gate.mjs --matrix          # the whole table below, sequentially
node gate.mjs --headed          # watch it
```

`gate.mjs` drives two headless browsers and forces media through `testbed/netsim.mjs` — a UDP
delay line in front of a TURN relay we run ourselves. That gives real relay candidates with
settable RTT, jitter and loss, so the matrix runs unattended instead of waiting for a second
machine on another continent.

Three things it has to get right, each of which would otherwise produce a **wrong number that
looks fine**:

- **Renderer throttling.** A backgrounded renderer has its timers clamped to ~1 s. The pacer is
  a MessageChannel token bucket and the sampler is a 200 ms bucket, so throttling doesn't fail —
  it under-reports throughput and blames the transport. The driver passes
  `--disable-background-timer-throttling`, `--disable-renderer-backgrounding` and
  `--disable-backgrounding-occluded-windows`, and refuses to print a verdict if the harness's own
  `hiddenDuringTest` flag tripped anyway.
- **Relay policy.** With the simulator up, a host candidate over loopback bypasses the delay line
  entirely. `iceTransportPolicy: 'relay'` is forced, and the driver checks the harness reports
  `RELAY (TURN)` before believing anything.
- **Not shortening the run.** usrsctp only grows its path MTU, and therefore its congestion
  window, if it sees full-size datagrams early. The harness warms up for 1.5 s; a run cut below
  that silently caps throughput for the whole session.

Results land in `runs/gate-<timestamp>.json` with every 200 ms bucket, so a verdict can be
recomputed without re-running.

### By hand, on two machines (the honest version)

Open the URL on **two machines** with the same room code. `A` (first to join) drives the test.

Optional — real CF TURN, needed for the relay half of the matrix:

```bash
npx wrangler secret put TURN_KEY_ID && npx wrangler secret put TURN_KEY_API_TOKEN
```

Without them the harness runs P2P/STUN-only and says so in the UI rather than failing.

> **Both windows must be visible.** A hidden tab has its timers clamped to ~1 s and `rAF` stopped,
> which throttles the pacer and the sampler. The harness detects this, stamps `wasHidden` into the
> export, and prints **RESULTS INVALID** — but it can't fix it. Two side-by-side *windows* are fine;
> two tabs in one window are not.

---

## The gate

Judged over the steady-state 12 Mbps portion, skipping the first 3 s so SCTP slow-start and PMTUD
ramp-up don't pollute the verdict:

| Check | Threshold |
|---|---|
| **sender survived the plan** | **still writing at ≥ 95% of planned duration** |
| throughput, median | ≥ 97% of target |
| throughput, p5 bucket | ≥ 90% of target |
| loss | < 0.5% |
| **`bufferedAmount` p95** | **< 64 KB** |
| queueing delay p95 | < 30 ms above session floor |

### Result

Two answers to two different questions. **Distance is free; loss is fatal.**

#### Clean link — PASSES at every distance tested

12 Mbps bidirectional, relayed, 25 s soak, both directions verdicted independently:

| ICE RTT (set) | throughput median | p5 bucket | loss | **`bufferedAmount` p95** | queue delay p95 |
|---|---|---|---|---|---|
| 22.0 ms (20) | 12.00 Mbps | 11.91 | 0.000% | **1.1 KB** | 3.6 ms |
| 80.0 ms (80) | 12.00 Mbps | 11.90 | 0.000% | **1.1 KB** | 3.7 ms |
| 151.0 ms (150) | 12.00 Mbps | 11.88 | 0.000% | **2.2 KB** | 3.9 ms |

`bufferedAmount` does not move with distance — 1–2 KB against a 64 KB limit at 150 ms RTT. Our
pacer is the binding controller and usrsctp's congestion window is not, which is the hazard this
gate exists to test (DESIGN.md §8, hazard 3).

#### Under loss — FAILS, and the shape is the finding

Same cell at 80 ms RTT, sweeping loss. Loss shown is the measured application-level rate:

| measured loss | throughput median | `bufferedAmount` p95 | queue delay p95 |
|---|---|---|---|
| 0.000% | 12.00 Mbps | 1.1 KB | 3.7 ms |
| 0.617% | 2.12 Mbps | 257.0 KB | 1218 ms |
| 1.281% | 1.55 Mbps | 257.1 KB | 1600 ms |
| 2.169% | 1.11 Mbps | 257.1 KB | 2314 ms |
| 3.643% | 0.78 Mbps | 257.0 KB | 2091 ms |

`node lossfit.mjs` fits **BW = 0.1253·p^-0.564**, R² = 0.987. The exponent is the argument: AIMD
loss-based congestion control predicts -0.5. This is usrsctp reading random loss as congestion and
clamping its window, with our pacer's data piling up behind it — the pinned 257 KB and the seconds
of standing queue are the pile.

#### Open: a ~38.7 s cliff, and what it does to the pass above

Every passing cell above is a **25 s** soak. In every longer run — the three 45 s matrix soaks and
every ramp — the *receive* path stops dead while the sender is still writing at full rate;
`bufferedAmount` fills 0 → 24 → 218 → 256 KB over ~600 ms and the pacer wedges. It is a timeout, not
a volume: 8 Mbps stops at 38.6 s, 12 Mbps at 38.8 s. node-turn's allocation lifetime is 600 s, so
that is not it; the leading candidate is ICE consent freshness (libwebrtc gives up after 30 s, which
lands near 38.7 s with startup) with the delay line or node-turn failing to service STUN consent
under load. `cliff.sh` runs 90 s soaks with the emulator, without it (`--nosim`), and at 2 Mbps.

**Until that resolves, the clean-link pass holds only for runs shorter than the cliff** — which no
real call is.

> **To carry 12 Mbps at 80 ms RTT, the path must lose fewer than 0.011%–0.031% of packets — between
> 1 in 3,300 and 1 in 9,300.** Run `node lossfit.mjs injected` for the conservative end; the bracket
> exists because about half the measured loss is excess over what the delay line injected, so
> regressing on measured loss is partly circular. Both axes give the AIMD exponent and the same
> verdict.

**This cannot be fixed above the transport.** FEC recovers the payload but SCTP still sees the SACK
gap and still halves its window. ARQ is not the culprit either — the bulk channel already runs
`ordered: false, maxRetransmits: 0`. The congestion controller is in the way, it is not ours, and
the API offers no way to replace it. See DESIGN.md §19 for where that leaves the transport choice.

### Three harness bugs produced a confident wrong answer first

A `--matrix` run reported **0/12** side-verdicts, which read as total transport collapse. Three of
those cells were in fact carrying 12.00 Mbps at 2.2 KB buffered for every second the pacer wrote.
The third bug was created by the fix for the first, which is why it is listed here rather than
quietly corrected.

- **The verdict included the drain after sending stopped.** Bucketing outlives the pacer, so a run's
  tail is a quiet channel with a stale `bufferedAmount`; a p5 has no defence against a fifth of its
  samples being structural zeros. Now clipped to the send span — first write to last write — keeping
  every bucket *inside* it, including blocked-sender ones, since dropping those individually would
  have erased the loss collapse above.
- **The one-way-delay baseline was a session minimum.** One packet 275 ms below a steady state flat
  to within 1 ms poisoned every later reading, and the gate invented 277 ms of queueing while
  `bufferedAmount` read 3.4 KB. Two false FAILs on a real pass. Now a low percentile, with the gap
  to the raw minimum exported.
- **Then the span clip needed a check of its own.** It cannot tell a run that *finished* from one
  that *died* — both end with the pacer no longer writing. The next matrix passed a 45 s soak whose
  connection had been dead since 38.6 s, and passed it legitimately, because every bucket inside the
  truncated span was healthy. The verdict now checks coverage first: the sender must still be writing
  at 95% of the planned duration. It found the cliff in all six cells of the old matrix at 84–86%
  coverage, both directions, every distance, every loss level.

I suspected CPU starvation of the delay line and tested it directly: the gate cell run while macOS
Spotlight indexing consumed ~3 of 4 performance cores **passed**, at loop lag p95 of 2.3 ms. Wrong
hypothesis. The guard written for it stays anyway — `netsim.mjs` samples its own event-loop lag and
a cell over 20 ms p95 is reported `INVALID` rather than `FAIL`, because a jostled ruler must not be
able to fail what it measures.

One more fix landed alongside, unrelated to any of the above: **teardown actually tears down.** The
driver used to outlive its own final line by 16 minutes, still holding the emulator's UDP ports —
which is how a later run ends up bound next to a corpse. Sockets are now unref'd and closed, matrix
cells get their own port and a 4 s gap between them, and the driver exits when it is done.

**The `bufferedAmount` check is the one that actually decides it.** If `bufferedAmount` is pinned,
our pacer is not the binding controller — usrsctp's congestion window is — and we have lost control
of the policy the entire design rests on (DESIGN.md §8, hazard 3). Throughput can look fine while
this is quietly false.

### On failure, in order

1. **Stripe lane B across N parallel `RTCPeerConnection`s.** SCTP's cwnd is per-*association*, so
   multiple DataChannels on one PC share one window and add nothing; separate PCs don't.
2. **Switch to WebTransport-over-Spectrum** (DESIGN.md §8.1) and price it against §18 first.

Do not proceed to phase 2 on an unresolved gate.

---

## Test matrix

Run each cell for 60 s in soak mode, both `all` and `relay` ICE policies:

| | 0% loss | 1% | 3% |
|---|---|---|---|
| **20 ms RTT** | | | |
| **80 ms RTT** | ← the gate | | |
| **150 ms RTT** | | | |

Start with **ramp mode** (4→8→12→16→20 Mbps, 20 s each) — knowing *where* it breaks is far more
useful than pass/fail at one rate. Then soak the interesting rates.

### Getting realistic RTT, by fidelity

1. **Two machines in different regions** — best. Real jitter, real routing, real reordering. A cheap
   VM in another continent running headless Chrome against the same room code costs nothing and is
   more honest than any shaper.
2. **`dnctl`/`pfctl` shaping** — precise and per-host:
   ```bash
   sudo ./shape/macos-shape.sh turn.cloudflare.com 80 1
   ```
   Delay is one-way per pipe, so the script halves the RTT you ask for. Remove with
   `sudo ./shape/macos-unshape.sh`. In `relay` mode all traffic goes to `turn.cloudflare.com`, which
   makes it a clean shaping target; for P2P you need the peer's public IP.
3. **Network Link Conditioner** (Xcode Additional Tools) — always works, but interface-wide rather
   than per-host and less precise.

---

## Reading the output

| Field | Meaning |
|---|---|
| `spanMs` | Actual wall-clock span of the bucket. Should be ~200. If it isn't, the tab was throttled. |
| `recvMbps` / `sentMbps` | Computed from the real span, never the nominal one. |
| `owdP50/P95` | Queueing delay **relative to the session floor**. See caveat below. |
| `bufP95KB` | `dc.bufferedAmount` — the diagnostic that matters. |
| `reordered` | Out-of-order arrivals. Expected and harmless on an unordered channel; not loss. |
| `lost` | Only counted once the high-water mark has advanced 1500 packets past a gap. |

**One-way delay carries an unknown constant offset** from clock-sync path asymmetry. The gradient and
the spread are meaningful; the absolute number is not. This is why the gate tests delay *above the
session floor* rather than delay itself.

Loss accounting is deliberately conservative. On an unordered channel, arrival order tells you
nothing, so counting a gap as loss on sight would massively overstate it and produce a false FAIL.

---

## Layout

```
src/worker.ts   HTTP entry: TURN credential minting, WS upgrade. Never in the data path.
src/room.ts     Durable Object: pairs peers, relays opaque signaling, holds the clock epoch.
                Control plane only — if this file grows a `case 'media':`, something is wrong.
public/harness.js  PeerConnection, pacer, clock sync, test driver.
public/stats.js    Loss accounting, bucketing, verdict, chart, export.
gate.mjs           Drives two headless browsers through the matrix using testbed/netsim.mjs.
shape/             macOS traffic shaping. Superseded by netsim for most purposes — it needs
                   root, netsim does not — but kept because it shapes a real interface.
```

### Three details that matter more than they look

**PMTUD warm-up.** usrsctp only grows its path MTU — and therefore its congestion window — if it sees
reasonably large packets early. The harness sends 1.5 s of full-size datagrams *before* any small
control message touches the association. Skipping this silently caps throughput for the whole session
and is the easiest way to get a false FAIL.

**Packet size is 1150 B.** One SCTP message, no fragmentation, and it keeps us under CF TURN's
5–10 kpps per-allocation ceiling. At 12 Mbps that's ~1300 pps. A design using 300-byte packets would
hit the pps limit at a quarter of the bitrate and present as unexplained loss.

**The pacer is a token bucket on a `MessageChannel` loop**, not `setTimeout`. `setTimeout` clamps to
4 ms once nested, and we need ~1300 packets/sec. It hands time back with a real timer when ahead of
schedule so it doesn't peg a core and distort what it's measuring.

---

## Verified working

Smoke-tested on loopback (2026-08-01): handshake, DataChannel open, PMTUD warm-up, clock sync, pacer
at 12.0 Mbps sent / 12.1 Mbps received, 17,846 packets with zero loss, `bufferedAmount` p95 10 KB,
bucket spans 193–200 ms, peer report exchange, verdict, CSV/JSON export.

That run's verdict was FAIL on two tail metrics (p5 throughput, delay p95) purely because both tabs
were hidden and therefore throttled — which is the harness correctly refusing to rubber-stamp
compromised data. **Loopback is a machinery test, not a measurement.** The gate needs two machines.
