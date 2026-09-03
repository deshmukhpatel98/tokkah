# Kin

**A video call between two Macs. The audio is 48 kHz 16-bit PCM, compressed
losslessly — no lossy codec ever touches it — and it travels over a UDP
transport written for this one job, directly between the two machines. A call
that is lossless in both directions costs about 2.4 Mbps.**

Download: **[room.tokkah.com](https://room.tokkah.com)** · or one line in a
terminal:

```bash
curl -fsSL https://room.tokkah.com/macos/install.sh | sh
```

macOS 14+, Apple silicon, 1.7 MB, free, no account. The repository is called
`tokkah`; the app it now builds is called **Kin**, and its binary is `tk`.

---

## What this is, and what it is not

Kin is a **native macOS app** for one-to-one calls. There is no browser
involved, no meeting room to schedule, and no media server: the two Macs find
each other through a Cloudflare Worker and then send audio and video **directly
to each other** over UDP.

It is not a Zoom replacement. There are no group calls, no recording, no chat,
no calendar, no Windows or Linux or iOS build, and no Intel Mac build. It does
one thing: two people, talking, with as little between them as the hardware
allows.

**If you were here for the browser version, read
[The browser era](#the-browser-era-and-what-happened-to-it) before anything
else. Short version: an invite link now opens the Mac app instead of a browser
call, the embed still works but had to be repaired during this audit, and none
of the browser-era numbers carry over.**

## Install

Two routes. They install the same signed app; they differ only in whether you
meet Gatekeeper.

**The `.dmg`** — from [room.tokkah.com](https://room.tokkah.com). Open it,
double-click Kin, and **macOS will warn you once**, because of the next section.
Go to System Settings → Privacy & Security, scroll down, click **Open Anyway**.
After that the app moves itself to `/Applications` and keeps itself updated.

**Or `curl`**, which never meets Gatekeeper at all:

```bash
curl -fsSL https://room.tokkah.com/macos/install.sh | sh
```

Not because it is sneaking past anything — quarantine is set by *quarantine-aware*
applications like browsers, and a file fetched by `curl` never gets the
attribute, so Gatekeeper is never consulted. The script refuses anything that is
not `Darwin-arm64`, fetches the manifest, and checks the download's SHA-256
against it before unpacking.

### There is no Apple Developer ID, and there is not going to be one

Say it plainly, because it is the first thing that will happen to you: **this app
is not notarized.** There is no paid Apple Developer account behind it. `spctl`
rejects the bundle, and the one-time "Open Anyway" click is a permanent part of
the `.dmg` route.

What the app *does* have is a **persistent self-signed certificate**, and that is
a different problem being solved. macOS pins a camera or microphone grant to an
app's *designated requirement*; under ad-hoc signing that requirement is a hash
of the bundle's contents, so every release looked like a brand-new application
and re-asked every user for permission. Signing every build with one certificate
makes the requirement name the certificate instead:

```bash
codesign -dr - /Applications/Kin.app
# designated => identifier "com.tokkah.tk" and certificate root = H"ef8e905f…"
```

That string is asserted at build time and must never change. The full story,
including the measurements that ruled out the obvious wrong explanation, is
[mac/SIGNING.md](mac/SIGNING.md). To be exact about what it buys: **permission
persistence, not notarisation.** Gatekeeper is unchanged.

### Updates are signed, and the key is not in this repo

The app updates itself. Because an updater that installs whatever a URL serves
is a remote-code-execution channel into every machine running it, the release
manifest carries an **Ed25519 signature**, verified against a public key
compiled into the binary
([`mac/Sources/tk/Update.swift`](mac/Sources/tk/Update.swift)). There is no
override flag, deliberately — a security control with a bypass is decoration.

You can check the live channel yourself; this is the manifest every installed
copy is verifying right now:

```bash
curl -s https://room.tokkah.com/macos/manifest.json
# {"version":"0.69.0","url":"…/tk-0.69.0.tar.gz","sha256":"25c9d852…", …}
```

**The private half of that key, and the signing certificate, live outside this
repository** — on the maintainer's machine, under `~/.config/kin-signing/`.
Anyone can build this app. Only the maintainer can publish a release that
existing installations will accept. That is a deliberate boundary, and
[GOVERNANCE.md](GOVERNANCE.md#releases-and-the-keys-that-gate-them) spells out
exactly what it costs a fork.

## Build it yourself

No credentials, no signing identity, nothing outside the toolchain:

```bash
git clone https://github.com/deshmukhpatel98/tokkah.git
cd tokkah/mac
swift build              # → "Build complete!"
.build/debug/tk --version    # → 0.69.0
.build/debug/tk --help
```

Requires Swift 6 and macOS 14+. Verified from clean at commit `13b85b3`:
`swift build` finished in **25.7 s** with no configuration of any kind.

There is a self-contained check that needs no network, no second machine and no
microphone — it runs the duplex gate against synthesised audio and asserts the
property the gate exists to protect:

```bash
.build/debug/tk --gate-test
#   while only they are talking, the microphone is 19.3 dB quieter
#   while you are talking, the worst sample differs by 0.0001% -- untouched
#   GATE TEST PASSED -- your voice is bit-for-bit what the microphone heard
```

To build the `.app` bundle rather than the bare binary, `mac/bundle/mkapp.sh`
does it; without the signing identity it falls back to ad-hoc signing, which
works fine for a local build and will re-prompt for permissions on each rebuild.

## Make a call

Both people run Kin and type the same room name. That is the whole protocol.

```bash
tk --room our-room --video camera    # camera on
tk --room our-room                   # audio only
tk                                   # the window asks for a room name
```

Room names are the capability — anyone who knows one can join, so treat it like
a meeting link. The name also travels as `tokkah://join/<room>`, so an invite is
a link someone clicks rather than a string they have to retype.

`tk --help` is the reference and is kept honest by construction: **an unknown
option is refused, not ignored.** That is not fastidiousness — it has happened
twice in this project that an A/B experiment silently compared an arm against
itself, because a misspelled flag did nothing quietly and the damaged arm ran
with its impairment switched off.

## What is actually measured

This project's one real rule is that a claim ships with the number that proves
it. **Read the next section before you read this table** — it says what these
numbers are and are not, and it matters more than any single figure in them.

| Claim | Measured | Where |
|---|---|---|
| Mouth to ear | **9.23 ms**, fully attributed with 0.08 ms unaccounted: `cap→send 1.67 · recv→play 3.01 · mic 1.88 · spk 2.58`. **4.46 ms of that 9.23 is the microphone and the speaker** — hardware nobody can optimise | [DESIGN.md](DESIGN.md) §17.108 |
| Audio format | 48 kHz **16-bit PCM, losslessly compressed 2.6×** by fixed-order prediction + Rice coding (the FLAC/Shorten subset, no lookahead, so it costs no latency by construction): **1.16 Mbps** each way, was 1.64 uncompressed. 137,005 packets round-tripped with **0 mismatches** | [`mac/Sources/tk/Lpc.swift`](mac/Sources/tk/Lpc.swift), `tk --selftest-lpc` |
| Packet cadence | 32 samples per packet = **0.667 ms** of audio per datagram, 1511 packets/s. One UDP socket carries audio and video, so there is one port and one hole to punch | [`mac/Sources/tk/Net.swift`](mac/Sources/tk/Net.swift) |
| Encryption costs nothing | X25519 + ML-KEM-768 (post-quantum hybrid) + AES-256-GCM per packet, handshake signed by the device key, replay window: **0.78 µs** to seal 276 bytes, worst of 300,000 at 15 µs, against a 1333 µs deadline — 0.06% typical | [`mac/Sources/tk/Crypto.swift`](mac/Sources/tk/Crypto.swift) |
| Your voice is untouched | duplex gate: **19.3 dB** of attenuation while only the far end is talking, **0.0001%** worst-sample difference while you talk — bit-for-bit | `tk --gate-test` |
| Video | H.264 High through VideoToolbox: **45.5 dB PSNR at ~1.19 Mbps, 30 fps sustained**. Glass-to-glass **~34.8 ms** in the shipping default (5.6 ms capture→decoded, 29.2 ms decoded→glass) | [DESIGN.md](DESIGN.md), [`mac/Sources/tk/Video.swift`](mac/Sources/tk/Video.swift) |
| Loss repair | a second copy of each packet, offset in time: **94.8% recovered at 1% uniform loss for 1.2 ms** of added buffer — and it switches itself off under bursts, where it does not work | [DESIGN.md](DESIGN.md) §17.86 |
| Window on screen | **192 ms**, first camera frame **464 ms**, by starting the sensor before the window rather than after. 640 of the ~780 ms to first frame is the sensor itself and is not ours | [`mac/Sources/tk/main.swift`](mac/Sources/tk/main.swift) |
| Answering a ring | **429 ms** to first picture on a real answered ring | [`mac/Sources/tk/main.swift`](mac/Sources/tk/main.swift) |
| **Cancel and decline** | **346 ms on production**, from the press to the other Mac having it | [CHANGELOG.md](CHANGELOG.md) (0.62.0) |

### What these numbers are not

Almost every figure above is a **pipeline** number, measured **between two
processes on one Mac**. The network contributes nothing and both ends share one
clock. That is a deliberate instrument — it isolates the part that is not the
speed of light — but it means they are not a claim about what a call between two
people in two places costs.

Being exact about which is which:

- **Loopback** (two processes, one machine): mouth-to-ear, glass-to-glass, the
  audio format figures, the duplex gate, the video PSNR.
- **Injected impairment** (delay, jitter and loss added on one Mac — never a
  constant-delay pipe): the distance figures. A Delhi↔Netherlands path modelled
  at 45 ms one-way gives **59.2 ms** mouth-to-ear; the antipodes at 100 ms
  one-way give **116.7 ms**, leaving 33 ms of headroom against the project's
  150 ms goal. The download page states plainly that these two are simulated,
  and that real distance "will be worse in ways a rig cannot invent".
- **Real hardware, black box**: camera first frame, launch and window timings.
- **Live production**: the **346 ms** cancel/decline, and the server-side
  measurements in [RINGING.md](RINGING.md) (Durable Object cold start 1108 ms
  median over 27 fresh objects; warm round trip 127 ms median).

So: there is currently **one live-production latency receipt for a media
action** in this project, and it is the 346 ms one. A real two-Macs-two-places
mouth-to-ear has not been measured. That is the honest state, it is the next
thing worth measuring, and no number here should be read as if it had been.

Video is *visually* lossless at best and never bit-exact — 1080p60 raw is about
1.5 Gbps, so the audio promise is simply not available for the picture. The
audio deserves the same precision: 16-bit is lossless with respect to **what the
microphone captured**, and lossy with respect to the float the OS hands over.
The project's own word for that is **"transparent, not lossless"**, and it is the
better word.

## Where the interesting engineering is

Roughly in order of how much of the project's difficulty lives there:

- **[`mac/Sources/tk/Audio.swift`](mac/Sources/tk/Audio.swift)** (3,944 lines) —
  the real-time path. A CoreAudio render callback reading a lock-free ring
  written by a socket thread, with no locks anywhere, because a lock on the audio
  thread is a dropout. This is also why the package builds in Swift 5 language
  mode on purpose: Swift 6's actor isolation cannot model that, and its only
  available advice would break the thing it is protecting
  ([`mac/Package.swift`](mac/Package.swift)).
- **[`mac/Sources/tk/Net.swift`](mac/Sources/tk/Net.swift)** — the wire. A
  20-byte header, one datagram per 0.667 ms of audio, capability bits so that a
  format change is never assumed of the far end — the two ends of a call can be
  up to 60 s apart in version.
- **[`mac/Sources/tk/Crypto.swift`](mac/Sources/tk/Crypto.swift)** — X25519 and
  AES-256-GCM, **two keys, one per direction**, because a single key with a
  counter from zero would make every packet number a nonce reuse, and nonce reuse
  under GCM does not weaken the cipher, it forfeits it.
- **[`mac/Sources/tk/Update.swift`](mac/Sources/tk/Update.swift)** — the signed
  self-updater, which swaps the whole bundle in one `renamex_np(RENAME_SWAP)`
  because editing files inside a bundle invalidates the signature over it and a
  machine with no private key cannot repair what it breaks.
- **[`mac/Sources/tk/Controls.swift`](mac/Sources/tk/Controls.swift)** (5,282
  lines) — the interface, which has been a richer source of bugs than the codec.
- **[`mac/tools/`](mac/tools)** — 23 check scripts, one per behaviour that has
  broken before (`gate-check.sh`, `crash-check.sh`, `sameroom-check.sh`,
  `update-check.sh`, …). These are the regression suite for everything CI cannot
  reach, which is all of `mac/`.
- **[`tape-app/src/worker.ts`](tape-app/src/worker.ts)** — the entire server: one
  Cloudflare Worker, two Durable Object classes (`Room`, `Health`) and one R2
  bucket for the Mac releases. It does rendezvous, the doorbell, optional TURN
  credentials, telemetry, and it serves the download page. **Media never touches
  it** — except on a call where the two routers will not allow a direct path, in
  which case it falls back to Cloudflare's TURN relay, which forwards packets it
  has no key for.

Design notes are per-topic rather than in one file:
[RINGING.md](RINGING.md), [TURNS.md](TURNS.md), [HELD.md](HELD.md),
[VIDEOLOSS.md](VIDEOLOSS.md), [GESTURES.md](GESTURES.md),
[DIAGNOSE.md](DIAGNOSE.md), [LAUNCH.md](LAUNCH.md), [PARITY.md](PARITY.md),
[mac/SIGNING.md](mac/SIGNING.md), [mac/GLASS.md](mac/GLASS.md).

## Known limitations

Named here rather than discovered later:

- **Apple silicon Macs only**, macOS 14+. No Intel, Windows, Linux, iOS or
  Android build, and none planned.
- **Two people per call.** No group calls.
- **Not notarized** (above). One Gatekeeper click on the `.dmg` route.
- **No echo canceller — on purpose, and it has a cost.** It was built, measured
  at 11–13 dB on a simulated path, judged not good enough, and then **deleted**
  in 0.56.0, because turn-taking makes the echo not exist: only one microphone
  is open at a time, so there is nothing to subtract and nothing to damage.
  Nothing filters your microphone now. The cost is that **headphones change the
  call**, and two Macs in one room needed a separate detector to stop them
  playing each other out of two speakers at once.
- **No real two-machine latency measurement.** Every media figure above is
  loopback or injected impairment (see
  [What these numbers are not](#what-these-numbers-are-not)).
- **A first call between two strangers, through a server that also lies about
  their keys, is the one man-in-the-middle case left.** The media handshake is
  signed by each install's device key and checked against the key that rang, the
  key the server bound the name to, or the key pinned from the last call — so a
  substituted key is refused, not merely detectable, everywhere an expectation
  exists. Where none does (an invite link, a first call), the eight-character
  code the two of you can read aloud is the check, and the pin written after
  that call closes the window. Written out in full at the top of
  [`mac/Sources/tk/Crypto.swift`](mac/Sources/tk/Crypto.swift).
- **The window is invisible to accessibility tooling.** Kin reports zero
  accessibility elements, so screen readers and window automation cannot see it
  ([LAUNCH.md](LAUNCH.md)). That is a real defect, not a design choice.
- **CI cannot make a call.** [`.github/workflows/ci.yml`](.github/workflows/ci.yml)
  builds the Mac app on a macOS runner and runs its offline self-tests, and it
  builds and tests the Worker on Linux — but no runner has a camera, a
  microphone, or a second machine. Anything about how a real call *sounds or
  looks* is verified by a person, by hand.
- **There are no git tags and no GitHub Releases.** A release is a commit whose
  message is the version, plus a signed manifest. Pin a commit if you need to pin.
- **The documentation is split by era, and you have to know where the line is.**
  [MEASURED.md](MEASURED.md) is 4,600 lines of genuine lab notebook — every
  claim's receipt, every experiment that failed — and it is **entirely the
  browser product**, last touched 2026-08-13. [DESIGN.md](DESIGN.md) straddles
  both: §1–§17.76 are the browser, and **§17.77 onward is the native Mac app**,
  which is where most numbers in the table above come from. It stops around
  0.40.0, so releases 0.41.0–0.61.0 are documented only in
  [CHANGELOG.md](CHANGELOG.md) and in git commit messages. Several
  per-topic docs ([LAUNCH.md](LAUNCH.md), [RINGING.md](RINGING.md)) contain
  "nothing here is fixed yet" statements that the code has since overtaken.

## The browser era, and what happened to it

This repository began on 2026-08-04 as a browser product: a WebRTC call with a
lossless-PCM audio lane over datachannels, embeddable in any page with one
`<script>` tag. It worked, and it produced real results — sliding-window FEC
repairing a lost packet at a p50 of 8 ms where a block code needed 80 ms+,
VMAF 99.7 video, and a **127 ms mouth-to-ear on a genuine cross-planet call**
between Delhi and the Netherlands, which is the one long-distance media
measurement this project has ever taken on real machines in real places
([LATENCY-150.md](LATENCY-150.md)). Those measurements are all still in
[MEASURED.md](MEASURED.md), failures included.

The native macOS work starts on 2026-08-23; the app was renamed **Kin** at
0.56.0 on 2026-08-25. None of the browser-era numbers carry over — different
transport, different codec, different measurements — which is why the table
above shares none of them.

**An invite link is no longer a browser call.** Following a link that somebody
sent you now opens Kin, or offers the download. That was deliberate, and it is
what "open it in two tabs, that's a call" no longer describes.

**The embed still works — but it was broken, silently, and this audit is what
found it.** Worth writing down because of the shape of the failure rather than
the size of the fix:

- `embed.js` builds an iframe pointing at the room. The invite funnel above
  could not tell that iframe apart from a person following a link, so it sent
  the frame to the download page. The page did not error. It rendered a
  plausible "Join on Kin" panel where a call should have been, and returned
  HTTP 200 doing it. Nothing anywhere said anything was wrong.
- The fix is one parameter: `web=1`, the escape hatch `tape-app/src/worker.ts`
  already documented and already served. It belongs on the frame and not on the
  shareable link — a person sent a link may genuinely want the app; a page that
  embedded a call has already decided.
- Verified, in this order: the real `build()` run under Node emits
  `…/?r=standup&web=1`; that URL returns `<title>Kin</title>` on production
  where the one without it returns `<title>Join on Kin</title>`; and a real
  browser loading it renders the call surface — "Join call", camera state and
  all — rather than a download page.

So the one-line integration is true again — **once the Worker is redeployed.**
The fix is a static asset, so `https://room.tokkah.com/embed.js` still serves the
broken build until then (`curl -s …/embed.js | grep -c web=1` → `0`):

```html
<script src="https://room.tokkah.com/embed.js" data-room="standup"></script>
```

with the honest caveat that it embeds the **browser** client, which is not where
the work goes.

The browser client source is still in `tape-app/public/` and is still AGPL, so
nothing is lost if you want it — but **it is not where the work goes**, and it
is not maintained. Every commit since the pivot has been in `mac/`.

## Self-hosting

The Worker is in this repo and deploys on a **free** Cloudflare account.
[SELF-HOSTING.md](SELF-HOSTING.md) has the full walkthrough, including the
optional TURN credentials and pointing your own build at your own deployment.

## License

Dual-licensed, and for almost everyone the answer is "free, go ahead".

**Free, under the [GNU AGPL v3](LICENSE)** — OSI-approved. Use it, deploy it,
fork it, sell a service built on it. Two light obligations: if you modify it and
serve those modifications to other people, publish your modified source too; and
**credit it** with one line in an About screen, credits page or footer, linked.
That second one applies only to products other people use — running it for
yourself or your team requires nothing. Details:
[ATTRIBUTION.md](ATTRIBUTION.md).

**Commercially, under a paid license** — for the one case the AGPL does not
cover: shipping this inside a **closed-source** product, or running a modified
version as a service without publishing your changes. See
[LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md), which opens with a table telling
you whether you owe anything at all, or write to licensing@tokkah.com.

Contributions carry a DCO sign-off plus a licensing grant, both explained in
[CONTRIBUTING.md](CONTRIBUTING.md). Third-party components: [NOTICE](NOTICE) —
the shipped app has **zero runtime dependencies**. Everything published before
commit `6375ae4` was MIT-licensed, and that grant stands permanently for those
versions.

## Help, and who is behind this

- **Something broken?** [Open a bug report](https://github.com/deshmukhpatel98/tokkah/issues/new?template=bug_report.yml).
- **A question that is not a bug?** [Discussions](https://github.com/deshmukhpatel98/tokkah/discussions), or [SUPPORT.md](SUPPORT.md).
- **A security problem?** Do not open a public issue — [SECURITY.md](SECURITY.md).
- **Want to contribute?** [CONTRIBUTING.md](CONTRIBUTING.md). Be warned that the
  bar is a measurement, including for the maintainer.

This is a **one-person project** — 483 commits, one author, started three weeks
before this sentence was written. [GOVERNANCE.md](GOVERNANCE.md) says who decides
what, how a pull request gets accepted, what a fork can and cannot do with the
signing keys, and what happens to all of this if the maintainer disappears.

[OPENNESS.md](OPENNESS.md) is the scorecard the project grades itself against —
can a stranger license it, deploy it, understand it, contribute to it, trust it —
with the command that proves each row.
