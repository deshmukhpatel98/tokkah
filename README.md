# Tokkah

**Video calls where the audio is bit-exact lossless — not "high quality", *lossless* — with packet repair in ~8 ms and every claim measured on real browsers.**

Live demo: **[room.tokkah.com](https://room.tokkah.com)** — open it in two tabs, that's a call.

```html
<script src="https://room.tokkah.com/embed.js" data-room="standup"></script>
```

That one line is the entire integration. No SDK, no API key, no account, no build step.

---

## Why this exists

Every mainstream calling product runs your voice through a lossy codec designed for
2010-era networks. Modern uplinks can carry 48 kHz linear PCM with room to spare — so
Tokkah sends **the actual samples**, protects them with a sliding-window FEC that
repairs a lost packet in ~8 ms (vs the 80 ms+ a classic block code needs), and paces
video against your display's real refresh rate up to 72 fps at VMAF 99.7.

The whole backend is **one Cloudflare Worker + one Durable Object**. Media never
touches a server — calls are P2P WebRTC datachannels; the Worker only does signaling
and (optionally) mints short-lived TURN credentials.

## Numbers, not adjectives

Everything below was measured on real, shipping browsers over an emulated link, paired
inside a single call wherever the design allows (both arms, one network, one moment).
The full lab notebook — including every experiment that **failed** — is
[MEASURED.md](MEASURED.md).

| Claim | Measured |
|---|---|
| Lossless audio | 48 kHz PCM, bit-exact end to end at ~0.75 Mbps (Rice-coded, wasted-bits stripped) |
| Repair latency | sliding-window FEC: p50 **8 ms**, p95 56 ms; block RS(10,13) needed up to 80 ms+ |
| FEC A/B | window beat block RS **8/8 paired calls** at 5% loss: 5× less concealment AND −44 ms end-to-end |
| Scarcity | 6 wins / 1 tie / 0 losses at 0.7–0.8 Mbps — extra parity never feeds the queue |
| Video | VMAF 99.7 (visually lossless) on Chromium; 30/48/72 fps quality exchange quantified |
| Latency | ~45 ms audio buffer depth on clean links; concealment 0.08% |
| Glass-to-glass | camera → remote screen p50 **~36 ms** on a live call (capture-read 0.2 + encode 5 + wire/decode 28 + present 8) |
| Connect time | second joiner click→connected median **347 ms** live (WS pre-dial from the lobby: 565 → 347 ms, −39%) |
| Echo | in-house PBFDAF canceller on the raw PCM lane: 62 dB ERLE, double-talk survives at 0.95 correlation, bit-exact passthrough when the far end is silent |
| Heavy loss | above the parity ladder (~15%), every frame ships twice, 24 ms apart on opposite stripes — engages/disengages off live loss reads |

Truly bit-exact **video** is physics-bound (1080p60 raw is ~1.5 Gbps), so the video bar
is *visually* lossless, measured with VMAF against the camera's own frames.

## One-click deploy

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/deshmukhpatel98/tokkah)

Or by hand — it's three commands:

```bash
cd tape-app
npm install
npx wrangler deploy
```

That gives you `tokkah.<your-subdomain>.workers.dev`, fully working. Optional extras:

- **TURN relay** (for phone-on-cellular ↔ laptop-on-wifi calls): `wrangler secret put
  TURN_KEY_ID` and `wrangler secret put TURN_KEY_API_TOKEN` (Cloudflare dashboard →
  Calls → TURN). Without them the app falls back to STUN-only and same-network calls
  still work. Credentials are minted server-side per request with a 1-hour TTL — they
  never appear in code or the browser.
- **Custom domain**: copy `wrangler.jsonc` to `wrangler.prod.jsonc`, add a
  `routes` entry for your domain, deploy with `npm run deploy:prod`.

## Embed API

Script tag (replaces itself with the call iframe, in place):

```html
<script src="https://room.tokkah.com/embed.js" data-room="my-room"></script>
```

Add `data-translate="es"` (any language) and the embedded call opens with a live
interpreter — you speak your language, they hear theirs. Each room carries a
server-enforced daily interpreter budget, so a page can never overspend it.

Programmatic:

```js
const call = Tokkah.join({ room: 'my-room', container: document.querySelector('#call') });
call.url;     // shareable invite link
call.leave(); // hang up / remove
```

Omit `room` and a cryptographically random one is minted. Room ids are capability
URLs — anyone with the link can join, like a meeting link. Point `data-base` at your
own deployment to embed your fork instead of room.tokkah.com.

One nuance: inside an iframe the audio lane runs its message-port path unless the
*embedding* page opts into cross-origin isolation (`Cross-Origin-Opener-Policy:
same-origin` + `Cross-Origin-Embedder-Policy: require-corp`) — then the embedded
call gets the SharedArrayBuffer fast path too. Both are lossless; the difference is
scheduling jitter under load. The embed is tested live on every change
(`testbed/embed-call.mjs`).

## How it works (short version)

- **Audio (Lane A)**: mic → AudioWorklet → 8 ms PCM frames → lossless Rice coding
  (~0.56× on speech, wasted-bit stripping halves 16-bit-in-24-bit-container chains) →
  one unreliable/unordered datagram per frame, striped over 6 SCTP associations
  (the AIMD ceiling is per association) → sliding-window FEC (12-frame window, parity
  every 3 frames, deterministic Cauchy coefficients so the wire carries no
  coefficient bytes) → SharedArrayBuffer ring → playout worklet. Jitter buffer sized
  by *measured arrival spread*, never by concealment count (that law ratchets).
- **Video (Lane 2)**: WebCodecs, adaptive QP against a GCC-style budget, display
  refresh-matched capture up to 72 fps, VBR fallback for engines without quantizer
  control — measured to be no downgrade at matched bitrate.
- **Backend**: one Worker (signaling, COOP/COEP gating, hardened `/log` + `/api/ice`)
  + one Durable Object per room. That's the entire server bill.

The long version is [DESIGN.md](DESIGN.md) (~370 KB of it), and the honest version —
what actually happened, including ten plausible mechanisms that turned out to be wrong,
instruments that lied, and A/Bs that refused their own verdicts — is
[MEASURED.md](MEASURED.md). [SECURITY.md](SECURITY.md) covers the trust model.

## Repo map

```
tape-app/        the product: Cloudflare Worker + static app (deploy this)
  public/        app.js, pcm.js (audio lane), tape.js (video lane), embed.js
  public/core/   pcmsw.js (sliding-window FEC), pcmrs.js (block RS), pcmpack.js (lossless codec)
  src/worker.ts  signaling worker + Room durable object
core/            shared DSP/detector modules
testbed/         the measurement rig: real-browser harness, link shaper, VMAF scoring,
                 paired A/B runners (media fixtures and run outputs are not in the repo)
MEASURED.md      the lab notebook — every claim's receipt, every failure kept
DESIGN.md        architecture and laws
```

Dev-rig scripts under `testbed/` carry absolute paths from the original rig machine;
they document method and are runnable after adjusting paths — they are not needed to
deploy or embed.

## License

Tokkah is **dual-licensed**, and for almost everyone the answer is "free, go ahead".

**Free, under the [GNU AGPL v3](LICENSE)** — an OSI-approved open-source license.
Use it, deploy it, fork it, sell a service built on it. Two obligations, both light:

1. If you modify Tokkah and serve those modifications to other people, publish your
   modified source too. Deploying it unmodified satisfies this automatically, because
   the source is already right here.
2. **Credit it** — one line in your About screen, credits page, or footer:
   *"Built with Tokkah"*, linked. That is the entire ask, and it applies only to
   products other people use; running it for yourself or your team requires nothing.
   Details and examples: [ATTRIBUTION.md](ATTRIBUTION.md).

**Commercially, under a paid license** — for the one case the AGPL does not cover:
shipping Tokkah inside a **closed-source** product, or running a modified version as
a service without publishing your changes. That is the situation a large platform is
usually in. See [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md) — it starts with a
table telling you whether you owe anything at all — or write to licensing@tokkah.com.

Contributions are covered by a DCO sign-off plus a licensing grant, both explained
in [CONTRIBUTING.md](CONTRIBUTING.md). Third-party components: [NOTICE](NOTICE).

Everything published before commit `6375ae4` was MIT-licensed, and that grant stands
permanently for those versions.

## How open is this, really?

[OPENNESS.md](OPENNESS.md) is a scorecard we grade ourselves against: can a stranger
license it, deploy it on a **free** account, embed it, understand it, contribute to
it, and trust it? Each row cites the command that proves it. The audit that created
that file found the documented install was broken for every new user — that is
exactly the sort of thing it exists to catch.
