# Where the interesting engineering is

Part of [Kin](../README.md). Moved from the main README.

Roughly in order of how much of the project's difficulty lives there:

- **[`../mac/Sources/tk/Audio.swift`](../mac/Sources/tk/Audio.swift)** (3,944 lines) —
  the real-time path. A CoreAudio render callback reading a lock-free ring
  written by a socket thread, with no locks anywhere, because a lock on the audio
  thread is a dropout. This is also why the package builds in Swift 5 language
  mode on purpose: Swift 6's actor isolation cannot model that, and its only
  available advice would break the thing it is protecting
  ([`../mac/Package.swift`](../mac/Package.swift)).
- **[`../mac/Sources/tk/Net.swift`](../mac/Sources/tk/Net.swift)** — the wire. A
  20-byte header, one datagram per 0.667 ms of audio, capability bits so that a
  format change is never assumed of the far end — the two ends of a call can be
  up to 60 s apart in version.
- **[`../mac/Sources/tk/Crypto.swift`](../mac/Sources/tk/Crypto.swift)** — X25519 and
  AES-256-GCM, **two keys, one per direction**, because a single key with a
  counter from zero would make every packet number a nonce reuse, and nonce reuse
  under GCM does not weaken the cipher, it forfeits it.
- **[`../mac/Sources/tk/Update.swift`](../mac/Sources/tk/Update.swift)** — the signed
  self-updater, which swaps the whole bundle in one `renamex_np(RENAME_SWAP)`
  because editing files inside a bundle invalidates the signature over it and a
  machine with no private key cannot repair what it breaks.
- **[`../mac/Sources/tk/Controls.swift`](../mac/Sources/tk/Controls.swift)** (5,282
  lines) — the interface, which has been a richer source of bugs than the codec.
- **[`../mac/tools/`](../mac/tools)** — 23 check scripts, one per behaviour that has
  broken before (`gate-check.sh`, `crash-check.sh`, `sameroom-check.sh`,
  `update-check.sh`, …). These are the regression suite for everything CI cannot
  reach, which is all of `mac/`.
- **[`../tape-app/src/worker.ts`](../tape-app/src/worker.ts)** — the entire server: one
  Cloudflare Worker, two Durable Object classes (`Room`, `Health`) and one R2
  bucket for the Mac releases. It does rendezvous, the doorbell, optional TURN
  credentials, telemetry, and it serves the download page. **Media never touches
  it** — except on a call where the two routers will not allow a direct path, in
  which case it falls back to Cloudflare's TURN relay, which forwards packets it
  has no key for.

Design notes are per-topic rather than in one file:
[../RINGING.md](../RINGING.md), [../TURNS.md](../TURNS.md), [../HELD.md](../HELD.md),
[../VIDEOLOSS.md](../VIDEOLOSS.md), [../GESTURES.md](../GESTURES.md),
[../DIAGNOSE.md](../DIAGNOSE.md), [../LAUNCH.md](../LAUNCH.md), [../PARITY.md](../PARITY.md),
[../mac/SIGNING.md](../mac/SIGNING.md), [../mac/GLASS.md](../mac/GLASS.md).
