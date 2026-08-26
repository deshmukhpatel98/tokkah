# tools/

Small things a stranger needs, that do not belong to either half of the project.

## verify-release.py — check that a Kin download is really ours

Kin is **not notarized by Apple**. There is no Apple Developer ID behind this
project and there never will be one, so macOS will show a Gatekeeper warning the
first time you open it. That is stated here rather than buried, because the
honest version of "we are not notarized" has to come with the thing that
replaces it.

What replaces it: every release manifest is signed with an Ed25519 key that
lives on the maintainer's machine and is never in this repository. The public
half is printed below and compiled into the app, so Kin refuses an update that
the key did not sign — see [`mac/Sources/tk/Update.swift`](../mac/Sources/tk/Update.swift),
which fails closed and says why in plain words.

    Kin update-signing public key (Ed25519)
    d07822edb36c8692c83f3478c26683102cd3cf6fb1d0c263496404c15fd95b2a

You can run the same check by hand, before you install anything:

```bash
python3 tools/verify-release.py
```

```
ok  manifest signature is valid under d07822edb36c8692...
ok  manifest says version 0.69.0
ok  https://room.tokkah.com/macos/dl/tk-0.69.0.tar.gz matches the signed sha256 (2504953 bytes)

VERIFIED. This is the release the signing key signed.
```

Other ways to run it:

```bash
python3 tools/verify-release.py --file ~/Downloads/tk-0.69.0.tar.gz   # a file you already have
python3 tools/verify-release.py --dmg                                 # check the .dmg instead
python3 tools/verify-release.py --base https://your.host/macos --key <your-hex-key>
```

Exit code 0 means every check passed. Anything else means do not install what
you downloaded.

**No dependencies.** Stock `python3` on a clean Mac, no `pip`, no Homebrew. The
RFC 8032 verify is written out in the file rather than imported, for two
reasons: the machines most likely to run this are the ones that have installed
nothing yet, and `openssl` on macOS is LibreSSL 3.3.6, which cannot do Ed25519
at all. Fetching goes through `curl` for a related reason — the `python3` that
ships with the Command Line Tools has no CA bundle wired up until someone runs
`Install Certificates.command`, so `urllib` fails with
`CERTIFICATE_VERIFY_FAILED` on a machine that has never been set up. Both of
those were measured on this Mac, not assumed.

## verify-release-selftest.sh — calibrate the verifier first

A verifier that prints VERIFIED for everything looks exactly like one that
works, until the day it matters. So before trusting the tool above, run:

```bash
bash tools/verify-release-selftest.sh
```

It requires a refusal for each of the ways a release can be wrong — a manifest
altered by one bit, a signature altered by one bit, a signature that is not
base64, a different public key, and an archive whose bytes do not match the
signed hash — plus an acceptance of the genuine live release, and a check that
the key documented above is the key the tool actually uses.

```
SELF-TEST PASSED (7 checks)
```

There is deliberately no way to fake a passing fixture offline: the sha256 of
the archive is inside the signed manifest, so constructing one that verifies
would need the signing key. That is the property being tested.

## If you fork this

The key above is ours, and you do not have its private half. A fork that ships
its own builds needs its own keypair — [SELF-HOSTING.md](../SELF-HOSTING.md)
covers generating one and pointing the app at your own release feed. Anyone can
build Kin from source; only the holder of the private key can sign a release
that the official app will accept. That asymmetry is the point of it.
