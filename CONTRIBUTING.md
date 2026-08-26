# Contributing to Tokkah

Thanks for being here. This file is short on ceremony and specific about the
two things that actually matter in this project: **measured claims** and
**clear copyright**.

## The one rule that makes this project different

**Every claim in this repo is measured, or it does not ship.**

Not "improves quality" — *"mouth-to-ear went 62.6 ms → 45.6 ms, measured on a
live call, both arms in the same session."* If you cannot measure your change
on a real call, say so in the pull request and we will work out how to measure
it together. A PR that says "should be faster" gets a friendly request for
numbers, not a merge.

Why so strict? Because this is a media product, and media products are full of
changes that feel better and measure worse. The repo's `MEASURED.md` is a log
of ideas that sounded great and lost to their own data. That file is the point.

## Which half of the repo you are in

This matters more than anything else here, because the two halves have different
toolchains and different verification.

- **`mac/` — the Mac app (Kin). This is where the work goes.** Every commit
  since the pivot has been here.
- **`tape-app/` — the Cloudflare Worker.** Still live and still essential: it
  does rendezvous, the doorbell, TURN credentials and the download page. Its
  `public/` directory is the **retired browser client**, kept but not developed.

## Quick start — the Mac app

```bash
git clone https://github.com/deshmukhpatel98/tokkah.git
cd tokkah/mac
swift build                    # → "Build complete!"
.build/debug/tk --version      # → the version you just built
.build/debug/tk --gate-test    # a real check that needs no network and no mic
```

Swift 6 toolchain, macOS 14+, Apple silicon. No credentials and no signing
identity needed — those are only required to cut an official release
([GOVERNANCE.md](GOVERNANCE.md#releases-and-the-keys-that-gate-them)).

To make an actual call, two machines, same room name:

```bash
.build/debug/tk --room our-room --video camera
```

If you are testing on one machine, **pass `--mute`** so the two processes do not
play into each other's microphones.

## Quick start — the Worker

```bash
cd tokkah/tape-app
npm ci                 # exact versions from the lockfile
npm test               # unit suites
npx wrangler dev       # local dev server at http://localhost:8794
npx wrangler deploy    # your own copy, on a free Cloudflare account
```

See [SELF-HOSTING.md](SELF-HOSTING.md) for running the whole thing yourself.

## Before you open a pull request

**If you touched `tape-app/`:**

1. **Run the tests**: `npm test` in `tape-app/`.
2. **Check the types**: `npx tsc --noEmit`.
3. **Verify a deploy still builds**: `npx wrangler deploy --dry-run`.
4. **Keep it free-plan deployable**: `node testbed/freetier-audit.mjs` from the
   repo root.

**If you touched `mac/`:**

5. **Build it**: `swift build` in `mac/`.
6. **Run the check scripts for what you touched.** There are 23 of them in
   [`mac/tools/`](mac/tools), one per behaviour that has broken before —
   `gate-check.sh`, `crash-check.sh`, `sameroom-check.sh`, `update-check.sh` and
   so on. They are the regression suite.
7. **Make an actual call and say what hardware you made it on.** CI builds the
   app and runs its offline self-tests, but **no CI runner has a camera, a
   microphone, or a second machine** — so a green badge says the code compiles
   and the pure-computation tests pass, and says nothing about how the call
   sounds or looks. Only you can check that.

**Always:**

8. **Describe the measurement.** What did you run, on what, and what were the
   numbers before and after? This step is on you, and it is the one that decides
   whether the change lands.

A note on measuring, learned the expensive way: **measure the rig's own noise
before believing any delta**, and prefer a rig that can run both arms in one
session. This project has had A/B results inverted by a moving average, by a
misspelled flag that silently disabled the arm it named, and by a harness
parameter the product actually chooses at runtime.

### The promise that must never break

Anyone must be able to **deploy the Worker on a free Cloudflare account**. That
is easy to break by accident, so it is tested rather than trusted:

- `node testbed/freetier-audit.mjs` — static, credential-free, runs in CI. Fails
  on paid-only bindings, key-value-backed Durable Objects, a bundle over the
  free-plan size limit, or a config that needs a custom domain or a secret.

If your change touches `wrangler.jsonc` or the Worker's routing, run it before
you open the PR rather than waiting for CI.

`testbed/forkdeploy-call.mjs` does the heavier version — clone the public repo,
deploy it under a throwaway name, run real browsers through it — but it exercises
the **retired browser client**, so it now proves the Worker deploys and serves,
not that a call works. A Mac-app equivalent does not exist yet, and writing one
would be a genuinely valuable contribution.

**A second promise used to live here — "embed it in any product" — and it is no
longer true.** `embed.js` still serves, but what it loads is now a hand-off page
that opens the call in the Mac app rather than a call in the browser. It is not
maintained. Do not add checks that assert the old behaviour.

## Sign-off: the DCO

Every commit must carry a `Signed-off-by` line. Add it automatically:

```bash
git commit -s -m "your message"
```

That line means you agree to the [Developer Certificate of
Origin](https://developercertificate.org/) — in plain terms: *you wrote this,
or you have the right to contribute it, and you are okay with it being
distributed under this project's licenses.*

## Copyright and dual licensing — please read this part

Tokkah is [dual-licensed](LICENSE-COMMERCIAL.md): free and open under the
AGPL v3, and available under a separate commercial license for companies that
cannot accept copyleft. That second option only remains possible if a single
party can license the whole codebase.

**So, by contributing, you grant the project maintainers a perpetual,
worldwide, royalty-free, irrevocable, non-exclusive right to use, reproduce,
modify, and distribute your contribution — including under the commercial
license described in [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md) — while you
keep your own copyright and may use your contribution however you like.**

That is the same arrangement used by most dual-licensed projects. It is stated
here, up front, so nobody discovers it later. If you are not comfortable with
it, please open an issue to discuss before writing code — we would rather have
that conversation early than turn away good work at the end.

## What good contributions look like

- **Bug fixes with a repro.** Best of all: a check script under
  [`mac/tools/`](mac/tools) that fails before your fix and passes after.
- **Measurements that contradict us.** Genuinely welcome. If a claim in this
  repo does not reproduce on your hardware, that is a finding, and it gets
  logged with your numbers.
- **A call between two real Macs, in two real places, with a number on it.**
  Every media latency figure the Mac app owns is loopback or injected
  impairment. Nobody has measured a real one. This is the single most valuable
  thing an outside contributor could bring.
- **Macs and audio devices we do not have.** Different Mac models, different
  interfaces, different sample rates. A hardcoded 48 kHz once went silently deaf
  on a machine whose default was 44.1 kHz, so this class of report is worth a
  lot.
- **Accessibility.** The window currently reports no accessibility elements at
  all, which makes Kin invisible to screen readers. That is an open defect and
  help with it is welcome.
- **Plain-language documentation.** If a paragraph in this repo needed two
  readings, it is a bug in the paragraph.

## What is likely to be declined

- Dependencies. The shipped app has **zero runtime dependencies** and the Worker
  has none either. That is a deliberate constraint, not an oversight.
- Anything that adds latency to the audio or video path, or that does work on
  the CoreAudio render callback. A lock on the audio thread is a dropout.
- Anything that filters the microphone. Since 0.56.0 the microphone reaches the
  wire exactly as captured, or is turned down whole — never filtered, never
  guessed at. That is the product, not an implementation detail.
- New work on the retired browser client in `tape-app/public/`.
- Claims without measurements (see above).

## Security issues

Do not open a public issue. See [SECURITY.md](SECURITY.md) for private
reporting.

## Code of conduct

Participation is governed by the [Contributor Covenant](CODE_OF_CONDUCT.md).
Report concerns to conduct@tokkah.com.
