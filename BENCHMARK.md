# Competitor benchmarking — the rig is built; it needs one link from you

The launch blog has to be truthful line by line, which means our numbers and
theirs must come from the *same* instrument. That instrument now exists and is
validated. What it cannot do is create accounts, so the competitor half is
blocked on one action only you can take.

## What is blocked, and why — tested, not assumed

| service | status |
|---|---|
| Google Meet | creating a meeting requires a signed-in Google account |
| Zoom | joining requires a meeting ID that only an account holder can create |
| WhatsApp / FaceTime | phone/Apple ID; no web join |
| **meet.jit.si** | **re-tested 2026-08-02: now moderator-gated too** |

Jitsi was the one account-free option and an earlier note here said its two
browsers "just failed to join, fix the harness." That is now wrong. Both
browsers reach the conference and are refused:

```
CONFERENCE FAILED: conference.connectionError.membersOnly
"The conference has not yet started because no moderators have yet arrived.
 If you'd like to become a moderator please log-in."
```

Its prejoin screen also ignores `#config.prejoinPageEnabled=false`, and the
element the old rig decoded — `prejoinVideo` / `#largeVideo` — is the **self
view**. That is the whole origin of the fabricated "Jitsi 836.7 ms" figure: not
a measurement of Jitsi, just two readers of the same looped fixture at different
phases. It was discarded, and nothing like it will pass the current rig.

One account-free SFU does survive: **`meet.ffmuc.net`**, a community-run Jitsi,
found by probing five open deployments for "can a browser publish media without
logging in" (`liveVideos=2, authWall=false`). It has been measured — 179.2 ms
p50 — and the decomposition that makes that number honest, along with the
finding that *their* pipeline is faster than ours, is in `MEASURED.md`.

So there is exactly one measurable opponent, and it is a volunteer-run bridge in
Munich rather than a commercial product. Every **named** competitor remains an
access limit, not a missing capability.

## What you need to do — one link, about two minutes

Start a Google Meet or Zoom meeting from your own account, leave it open, and
paste the join link into one command:

```bash
node competitor.mjs --url="<paste the join link>" --label=Meet --sec=25
```

The script lives in the session scratchpad; copy it into `testbed/` to keep it.
It handles the prejoin click-through itself (`Join now`, `Ask to join`, etc.).
If the meeting has a waiting room you may need to admit the two participants.

## Why the result can be trusted

Two browsers each get a 1280×720 fixture with a 10-bit timecode burned into the
frame, and latency is *when the receiver displayed frame i* minus *when the
sender's own preview first showed frame i*. Reading only pixels means it works
identically on any service, ours included, with no cooperation from either.

The hard part is knowing which element on the receiving page is actually the far
end, and getting it wrong does not produce a small error — it produces a
confident wrong number, as the Jitsi figure showed. Three fixes, each found by a
validation run against our own app where the true answer was already known:

1. **Source tags, not timing heuristics.** The first version rejected self-views
   by looking for a large offset with no jitter. That fails: two independent
   in-page rAF samplers show 12–14 ms of spread on a pure phase offset, which
   passes for network jitter. Now the two browsers get *different* fixtures,
   identical but for a source bit, so the far end is the element carrying the
   other browser's tag. Nothing to tune.
2. **Canvases as well as `<video>`.** Our own remote tile is painted to a canvas.
   A version that queried only `<video>` found no remote tile at all and reported
   a self-view as 2287 ms of glass-to-glass latency.
3. **A decoder cheap enough not to distort the measurement.** Drawing six
   candidates at full 1280×720 with ten `getImageData` calls each, inside the very
   rAF loop being timed, reported 404 ms for a path known to run at 27 ms. The
   instrument was measuring itself. It now scales the bar strip to 11×1 pixels:
   one `drawImage`, one `getImageData`.

**Validation.** Against `room.tokkah.com`, where the answer is independently
known from a separate rig:

```
discovery: sender element "preview#0", far-end element "remoteCanvas#3"
  B had preview#0(src=1), remoteFill#1(src=0), remoteCanvas#3(src=0),
       selfFull#4(src=1), self#5(src=1), v#6(src=1)

room.tokkah.com: glass-to-glass p50 27.2 ms, p95 46.6 ms, 1280x720
```

against a known 27.3 ms / 46.9 ms — and all four self-view elements correctly
rejected. A run where no element carries the sender's tag exits with an explicit
refusal to report a number rather than a plausible one.

**One run of this rig is not a measurement.** Repeating the *identical* build
and arm ten times gives p50 23.0 ± 1.7 ms (range 19.8–25.3). Anything smaller
than about 4 ms is invisible at n=1, and two claims in `MEASURED.md` had to be
withdrawn for exactly that. `ab.mjs` runs two arms interleaved with n reps and
refuses to name a winner below t = 2.5:

```bash
REPS=5 node testbed/ab.mjs "canvas=" "video=l2canvas=0"
```

**A fourth bug, found by this rig and living in the app rather than the rig.**
The run above used to end `1920x1080` from a 1280×720 fixture. The rig was
right: the far-end canvas really was 1080p, because the encoder was hard-coded
to 1920×1080 and WebCodecs upscaled everything to fit. The instrument had
faithfully reported a defect as a feature, and it took a source whose true
resolution was already known to notice. Fixed in `tape.js`; see `MEASURED.md`.

## What the number will and will not mean

- It is **remote view minus local self-view**, so the camera and preview stack
  are common to both sides of the comparison and cancel out.
- The reported frames-per-second is the **rig's sampling floor**, not the video's
  frame rate — the sender's own preview decodes at the same rate. Comparable
  between services, not quotable as an absolute.
- Both browsers run on one machine, so this measures the service's path, not
  real-world geography. For a distance comparison the shaping harness
  (`--p2psim --rtt`) has to be pointed at both arms equally, which is not
  possible for a competitor whose traffic we cannot route.
