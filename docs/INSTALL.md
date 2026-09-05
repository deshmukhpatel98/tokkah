# Installing Kin

Part of [Kin](../README.md). Moved from the main README.

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

## There is no Apple Developer ID, and there is not going to be one

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
[../mac/SIGNING.md](../mac/SIGNING.md). To be exact about what it buys: **permission
persistence, not notarisation.** Gatekeeper is unchanged.

## Updates are signed, and the key is not in this repo

The app updates itself. Because an updater that installs whatever a URL serves
is a remote-code-execution channel into every machine running it, the release
manifest carries an **Ed25519 signature**, verified against a public key
compiled into the binary
([`../mac/Sources/tk/Update.swift`](../mac/Sources/tk/Update.swift)). There is no
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
[../GOVERNANCE.md](../GOVERNANCE.md#releases-and-the-keys-that-gate-them) spells out
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

To build the `.app` bundle rather than the bare binary, `../mac/bundle/mkapp.sh`
does it; without the signing identity it falls back to ad-hoc signing, which
works fine for a local build and will re-prompt for permissions on each rebuild.
