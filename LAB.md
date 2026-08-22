# The far-away lab

One permanent link, and a browser on the other side of the world to answer it.

```
https://room.tokkah.com/far-away-lab     ← the call. Bookmark it. It never changes.
https://lab.tokkah.com                   ← the console: who is where, and why.
```

Open the call link, press **Start a call**, and within about a minute the peer that
answers is a real Chromium in a Cloudflare container on another continent, carrying a
real recorded talking head and real speech. Close the tab and it is torn down two
minutes later. Nothing runs — and nothing bills — while nobody is looking.

The link is a *room*, so it survives every deploy: `room.tokkah.com/far-away-lab`
serves whatever `tape-app` currently is. There is nothing to re-mint, re-share or
re-bookmark, ever.

---

## Why this exists

Every latency number this project owned was measured on one laptop against a
simulated network. The 150 ms goal turns on a number that needs two places:
what a **real** media path costs between two continents, with real media on it.

This is that instrument. It is deliberately **not** a harness: both ends load
`room.tokkah.com` and press the same join button a person presses, so what it
measures is production.

---

## How far away is "far away"

Measured 2026-08-23 through the deployed `/api/probe`, which times a Durable
Object round trip over Cloudflare's own backbone. Minimum of four samples — the
floor is the path, anything above it is queueing.

**From the DEL edge (this operator's city):**

| region | RTT | one-way | honest? |
|---|---|---|---|
| `wnam` US West | **305 ms** | 152 ms | yes — and it lands in **Querétaro, Mexico** (`colo=QRO`), ~15,000 km |
| `enam` US East | 305 ms | 152 ms | yes |
| `sam` South America | 262 ms | 131 ms | yes |
| `weur` W Europe | 207 ms | 104 ms | yes |
| `oc` Oceania | 184 ms | 92 ms | yes |
| `eeur` E Europe | 170 ms | 85 ms | yes |
| `apac` Asia-Pacific | 81 ms | 41 ms | yes |
| `afr` Africa | 207 ms | — | **NO** — answers W Europe in 1 ms; the hint is ignored |
| `me` Middle East | 266 ms | — | **NO** — 266 ms to a region ~2,000 km away |

**Between regions (the furthest pairs):**

| pair | RTT | note |
|---|---|---|
| `eeur ↔ oc` | **320 ms** | the furthest pair the network will *route* |
| `oc ↔ weur` | 280 ms | |
| `enam ↔ apac` | **243 ms** | the furthest pair a **container** can be *placed* in |
| `sam ↔ apac` | 228 ms | |
| `wnam ↔ eeur` | 134 ms | |

Two limits, and they are not the same limit. `OC` and `AFR` are refused outright
by the container platform — *"Regions OC have limited capacity, and require
additional capabilities"* — so Oceania will route a packet but will not hold a
browser. The furthest a **browser** goes on this account is `enam ↔ apac`, 243 ms.

**The consequence, stated plainly: one-way exceeds 150 ms on propagation alone,
before the app runs a line of code.** `eeur↔oc` is 160 ms one way; Delhi↔Querétaro
is 152 ms. The 150 ms goal is not lost in the pipeline on these paths — it is lost
in the ground.

### `locationHint` lies; `constraints` binds; only the container tells the truth

Three separate mechanisms, and they disagree:

- **`locationHint`** on a Durable Object is *advisory*. A `wnam` hint has been
  caught placing a DO in Mumbai, and `afr`/`me` hints are plainly ignored today.
- **`constraints.regions`** on a container class *binds* — but to a region, not a
  city. `WNAM` put a browser in **Mexico**, not Seattle.
- So every far peer reports its own `cdn-cgi/trace` (`colo`, `loc`, `ip`) from the
  inside, and **that** is the only statement of where a measurement happened.

---

## What the rig is made of

```
room.tokkah.com/far-away-lab   the room (tape-app, unchanged)
lab.tokkah.com                 tokkah-peer-ctl — console, API, and the keeper
  ├── /join.js                 the script the container runs (served, not baked)
  ├── /api/summon?region=…     place a far peer, now
  ├── /api/pair?a=…&b=…        two containers, two continents, no laptop
  ├── /api/state               presence + latest tick per region + log
  └── cron  * * * * *          the keeper
testbed/peer/Dockerfile        the image: Playwright + Chromium + both speakers
testbed/nearside.mjs           a stand-in for the human, for proving the rig
```

**The keeper** is what makes the link feel permanent. Every minute it asks the room
who is in it — through tape-app's already-shipped lab channel, `{"op":"drain"}`,
which returns occupant roles and holds no room slot — and then:

- a human alone in the room → summon a far peer;
- a human and our peer → leave it alone;
- our peer alone, twice running → tear it down.

Zero changes to production for any of that. Zero idle cost. Two empty ticks before
teardown, so a page reload does not cost you your far end and another cold start.

**Presence is read from a join frame, never from "we started a container".** A
container takes 30–90 s to boot and says nothing while it does; a keeper that reads
its own summon as presence summons on top of the one already coming up, forever.
Same lesson as [once-fired probes record transients], one layer out.

---

## Running it

```bash
# the human way: open the link, press the button. Nothing else.
open https://room.tokkah.com/far-away-lab

# summon a far end yourself (or pick a different continent)
curl "https://lab.tokkah.com/api/summon?region=wnam&hold=1800"

# two containers, two continents, no laptop in the middle
curl "https://lab.tokkah.com/api/pair?a=enam&b=apac&hold=300"

# what is happening
curl -s https://lab.tokkah.com/api/state | jq

# stop paying for it
curl "https://lab.tokkah.com/api/stopall"

# a stand-in for the human, to prove the rig without a webcam
ROOM=far-away-lab HOLD_S=300 SIDE=A node testbed/nearside.mjs
```

Rebuild the image only when the **media** changes; `join.js` is served, so the
experiment itself changes with a `wrangler deploy`.

```bash
export PATH="$HOME/.local/bin:$PATH"
colima start --vm-type=vz --cpu 4 --memory 8 --disk 30
npx wrangler containers build -t tokkah-peer:v7 --push testbed/peer
docker rmi -f $(docker images -q); docker system prune -af --volumes   # ~4 GB each
```

Docker on this Mac needs `buildx` (`~/.docker/cli-plugins/docker-buildx`); without
it `wrangler containers build` dies on `unknown flag: --load`.

---

## What it found on its first run

A live Delhi ↔ Querétaro call: ICE connected over UDP, 320 ms round trip, 17,000
packets received — and **every pipeline number null on both ends**.

The instrument was extended to answer *why* rather than *whether*, and the answer
was not distance:

```
why=tape-fallback:peer-lane-0, pcm-fallback:peer-no-audio
container diag: { secure: true, enc: true, vTracks: 1, xform: FALSE }
container event: tape-unsupported
```

`RTCRtpScriptTransform` — the API the fast video lane's carrier is built on — **does
not exist in the container's Chromium.** The image was pinned to Playwright v1.49
(Chromium 131); this laptop drives Chromium 151. So the far end logged
`tape-unsupported`, advertised `lane: 0`, and the near end dutifully fell back to
plain RTP. Every cross-planet call ran the **fallback** path while reporting itself
as a video call.

Fixed in image v7 by pinning the base to `playwright:v1.62.1-noble`, the version the
local rig runs. Twenty Chromium versions of drift had turned "the same engine on both
ends" into a fiction — and a null is exactly what a blind instrument returns when the
thing it cannot see is broken.

**The lesson worth keeping:** a metric that reads the same for *"not measured yet"*
and *"the lane is dead on this path"* points investigation in the wrong direction.
Both ends now report `tapeMode`, `pcmUp`, and the lane's own fallback reason on every
tick.

### And then, with v7, the first honest cross-planet numbers

**Delhi ↔ Querétaro/Los Angeles (`wnam`), 265–290 ms ICE RTT, 4½ minutes, both lanes
alive (`pcm=up`, `tape=run`, no fallback):**

| | value | local same-machine control |
|---|---|---|
| glass-to-glass | **630–660 ms** | 25–27 ms |
| lane frames in | 7 395 (climbing) | climbing |
| concealment | ~980 ms per 15 s of wall clock | ~390 ms per call |
| mouth-to-ear | **null — never produced a value** | 79–87 ms |

**Houston (`enam`) ↔ Taipei (`apac`), container to container, no laptop in it,
210–290 ms ICE RTT:**

| | Houston | Taipei |
|---|---|---|
| glass-to-glass | 160–477 ms, ending 453 | 251–404 ms, ending 272 |
| inter-present interval p50 | 140 ms (≈7 fps) | 112 ms (≈9 fps) |
| concealment | 204 864 ms | 6 912 ms |
| ring depth | **−200 628 ms** (nonsense) | null |
| mouth-to-ear | null | null |

Four things fall out of that table and none of them were visible before:

1. **Glass-to-glass is 20× worse over distance than in the lab** — 640 ms against 26.
   The project's video budget was decomposed to 25.5 ms on a short path; on a real
   long path the picture is arriving two thirds of a second late.
2. **Video is presenting at 7–9 fps**, not 30+. `ipiP50` 112–140 ms.
3. **Mouth-to-ear does not exist on a long path.** It reports on a local call and
   nothing on any cross-planet call, so the headline audio number has no value
   here at all — an instrument gap, sitting exactly where the goal is measured.
4. **`ringDepthMs` came back as −200 628.** A negative depth is not a small number,
   it is a wrong one, and it is the audio side's own clock saying so.

The two ends also disagree by 30× on concealment (204 s vs 7 s) on the same call,
which means one direction of that Pacific link is far worse than the other.

None of these are conclusions yet. They are the first readings from an instrument
that, until today, had never once had the pipelines it measures switched on.

---

## Where this is still not real life

Honest gaps, in the order they matter:

1. **The far end has no last mile.** A container sits on datacenter fibre: no wifi,
   no cellular, no home router, no contending household. Real calls have a consumer
   network at *both* ends. This rig currently impairs neither.
2. **The far end is a recording, so it cannot converse.** Latency's cost is felt in
   turn-taking, and a clip does not wait for you to finish. Judging "does this feel
   like sitting next to each other" needs either a second human or a peer that
   reflects you back.
3. **Both ends are Chromium.** The fleet's own numbers say video glass-to-glass is
   1434 ms p50 on Chromium against 173 ms on WebKit — the single largest split this
   project has. A rig that never runs Safari cannot see it.
4. **Container ICE is relay-only.** No public IP, so the far end always goes through
   TURN. That is a realistic case (it is what a phone behind carrier NAT does) but it
   is not the *only* case, and direct-path numbers on a long route stay unmeasured.
5. **Two browsers on one desk cannot be far apart.** If both ends are in Delhi, any
   path through Mexico pays the distance twice. That is not a bug in the rig, it is
   geometry — which is why the far end has to be a machine that is actually far away.

---

## The first thing a human found on it

The operator opened the link and reported a **blurred picture and no sign of their own
camera**. **The cause was a wrong camera selected in the picker** — they found it and
said so, and that is the whole explanation of what they saw. Everything below is what
the investigation turned up on the way, kept because two of the three items are real
and one of them is a correction to this file's own earlier claim.

Their session's telemetry (`/api/room/far-away-lab/log`, session `x-mt4u0j9e-cokq`):

**1. The camera was live the whole time.** `camlock {ok: 1, luma: 100.2}`, `srcprobe 1280×720 @ 26 fps`
two seconds in, ~2 MB of encoded video sent in eight seconds. The self-view elements
(`#preview`, `#selfFull`, `#selfSense`) each carry the raw camera track at 1280×720/30
with `filter: none` — verified structurally on a live call. Nothing blurs the sensor.

**2. There is no self-view during a call, by design — and two comments lied about it.**
`peerArrived()` deliberately leaves the mirror off: the persistent self-view is the
best-evidenced fatigue driver in the literature (Fauville et al. 2021, N=10,322), so
looking at yourself is one *hold* of the `#peek` button. But the code claimed two
controls that were never built — *"toggleable via the c-selfview chip"* and *"pinnable
from the more sheet"*. Both comments are corrected, and the pin now exists as
**`?selfpin=1`** — and in the `far-away-*` rooms it is **on by default**, so the plain
link is enough and there is no flag to remember. Scoped by room, not globally: a real
call still gets no mirror, because the fatigue evidence against one is good. `?selfpin=0`
opts out, and `selfpin` is also a live lab-channel knob (`op: "set"`), so it can be
flipped mid-call without reloading the call you are measuring inside.

Verified both arms on prod: `far-away-max` with no query string pins the tile (opacity
.96, painting the raw sensor at 1280×720, unfiltered); an ordinary room with no query
string leaves it at opacity 0.

**3. Not the cause here — but the rate controller did something worth chasing.** Within
*seven seconds* of joining:

```
t+3.6s   rc-duress   level 1, budget 1.95 Mbps   (estimate was 4.6)
t+6.9s   rc-res      shrink 2, why "pinned-over", qp 42
t+7.4s   tape-resize 1280x720 -> 640x360
```

QP 42 at half resolution and 8–12 fps is exactly what "blurred" looks like. The
controller had **four seconds of history** when it made that call — no window, no
priors, on a 280–350 ms relay path. Textbook *startup poisons estimators*: sample
before the inputs converge and you learn a wrong number, then act on it.

QP 42 at half resolution and 8–12 fps would look blurry to anyone. It was **not** what
the operator was looking at — that was the camera picker — so this is a lead, not a
finding: the numbers are in the log, but they come from a session whose capture device
was not the intended one, and content changes what a quantiser does. **Re-run it on a
clean call before believing the magnitude.** What does not depend on the camera is the
shape of the decision: a controller acting on four seconds of history over a 280–350 ms
relay path, which is the *startup poisons estimators* pattern exactly.

Worth saying plainly: the first human contact with this rig produced one confirmed app
change (`?selfpin=1`, plus two comments that had documented controls nobody built), one
lead to re-measure, and one false alarm correctly identified by the operator. That is
what a working instrument looks like on day one.
