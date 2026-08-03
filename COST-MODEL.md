# Cost per minute — what a 1:1 call actually costs us

Every input here is either measured on production or a published price. Where a
number is an assumption it is labelled as one, because this document exists to
make the launch blog defensible line by line.

## Measured inputs

Production, default configuration (custom video lane + lossless audio lane),
1080p motion fixture, 20 s window:

| quantity | measured |
|---|---|
| transport up, per peer | 9.80 Mbps = **73.5 MB/min** |
| transport down, per peer | 10.04 Mbps = **75.3 MB/min** |
| signalling, whole session | **38.5 KB** over one Worker + Durable Object WebSocket |
| selected candidate pair | `host <-> host`, UDP — **media never touched a server** |

The candidate-pair result is architecturally meaningful but is *not* evidence of a
real-world hole-punching rate: both browsers ran on one machine, so a direct pair
was guaranteed. What it confirms is the design — this is peer-to-peer WebRTC, not
an SFU. Media transits our infrastructure only when ICE fails to find a direct
path and falls back to TURN.

## Published prices

- Cloudflare Realtime TURN: **$0.05 per GB** egress (Cloudflare → TURN client),
  first 1,000 GB free.
- Durable Objects: **$12.50 per million GB-s** duration (billed at a fixed
  **128 MB** per object regardless of usage) and **$0.15 per million requests**
  (WebSocket messages count as requests). Free tiers: **400,000 GB-s/month** and
  **1 million requests/month**.

## The model

Let `r` = fraction of calls that cannot go direct and fall back to TURN.

**Direct call (probability `1 − r`).** Media cost to us is **exactly zero** — the
bytes go peer to peer and never enter our network. The only cost is the
signalling room: 38.5 KB and a Durable Object alive for the call. A 10-minute
call holds one 128 MB DO for 600 s = 75 GB-s, which at $12.50 per million GB-s is
**$0.00094 per call**, under a tenth of a cent. Per minute: ~$0.0001.

**Relayed call (probability `r`).** Cloudflare bills egress toward each TURN
client, so a relayed 1:1 call bills what *both* peers receive:

```
2 peers x 75.3 MB/min = 150.6 MB/min = 0.1506 GB/min
0.1506 GB/min x $0.05/GB = $0.0075 per minute
```

**Blended:** `cost/min ≈ r × $0.0075`.

| relay rate `r` | our cost/min | our cost/hour |
|---|---|---|
| 5% | $0.00038 | $0.023 |
| 15% (industry-typical assumption) | $0.0011 | $0.068 |
| 30% | $0.0023 | $0.135 |

`r` is **assumed, not measured.** Measuring it needs real users on real networks
behind real NATs; a two-browser loopback cannot produce it. This is the single
biggest open variable in the model.

## Honest comparison to an SFU

Zoom and Google Meet are SFU architectures: **100% of media transits their
servers, on every call, always.** There is no direct-path case for them. But they
also send far less data — a typical 1:1 Meet/Zoom stream is ~2.5 Mbps against our
~11.5 Mbps.

Taking 2.5 Mbps and the same $0.05/GB egress as a like-for-like yardstick:

```
2 peers x 18.75 MB/min = 37.5 MB/min = 0.0366 GB/min -> $0.0018 per minute
```

So the truthful headline is **not** "100× cheaper":

- At `r` = 15% we are about **1.6× cheaper per minute** than an SFU carrying a
  quarter of our bitrate.
- We are cheaper *despite* pushing ~4.6× the data, because ~85% of our calls cost
  us nothing at all.
- Per unit of delivered quality the gap is much larger: we deliver 1080p plus
  48 kHz/24-bit lossless audio where the SFU comparison is 2.5 Mbps of lossy
  video and Opus.
- If we ever needed to match their bitrate, our relayed cost would fall ~4.6× and
  the per-minute advantage would become roughly 7×.

The structural claim that survives scrutiny: **our cost scales with the relay
rate, theirs scales with total call volume.** Ours can approach zero. An SFU's
cannot, by construction.

## What would make this model stronger

1. Measure `r` from real traffic — the `ice-tier-fallback` and candidate-pair
   telemetry already logged can carry it once there are real users.
2. Confirm Zoom/Meet bitrates by measurement rather than the ~2.5 Mbps figure
   assumed above. This needs an account-gated join link.
3. Add the free tiers to the blended figure, which currently ignores them and so
   overstates our cost. They are not rounding errors at launch scale:
   - TURN: 1,000 GB ≈ **6,600 relayed call-minutes/month** at zero cost.
   - DO duration: 400,000 GB-s ≈ **5,300 ten-minute calls/month** at zero cost.
   - DO requests: 1M/month, against ~38.5 KB and a few hundred messages per call.

   Below roughly 5,000 calls a month, this service costs **nothing at all** to
   run. That is the version of the cost claim that is both striking and true, and
   it is the one the blog should lead with rather than a fabricated 100×.
