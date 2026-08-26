# Governance

This is a **one-person project**. Writing that down is the whole point of this
file: you should know who decides, how, and what happens to your pull request
before you spend an evening on it.

As of commit `13b85b3` (0.69.0), the repository has **483 commits and exactly one
author**:

```bash
git shortlog -sne --all
#   483  Devesh Patel <devesh.patel0922@gmail.com>
```

There is no steering committee, no foundation, no working groups, and no vote.
There is one maintainer — [@deshmukhpatel98](https://github.com/deshmukhpatel98),
who is also the sole entry in [`.github/CODEOWNERS`](.github/CODEOWNERS) — and
everything below describes how that one person actually behaves, not how a
larger project would like to be seen.

## Who decides

The maintainer decides. Every merge, every release, every architectural
direction, and every "no". If you want a real answer about direction, ask the
maintainer in an issue or a [discussion](https://github.com/deshmukhpatel98/tokkah/discussions);
nobody else can give you one.

This has an upside worth naming: decisions are fast, and you will never be told
that your change is blocked on a committee. It also has a downside worth naming
just as plainly: the project moves at one person's pace, and when that person is
busy, it does not move.

## How a change gets accepted

The bar is written in [CONTRIBUTING.md](CONTRIBUTING.md) and it is unusual, so
read it before you write code. In short:

1. **CI must pass.** [`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs
   the Worker's tests, the type check, a credential-free deploy build and the
   free-tier audit on Linux; and it builds the Mac app and runs its offline
   self-tests on a macOS runner.
2. **The claim must be measured.** "Should be faster" is not a result. A number
   before, a number after, and the command that produced both. This is the one
   rule the project is actually strict about, and it applies to the maintainer's
   own commits too — `MEASURED.md` is largely a record of ideas that lost to
   their own data.
3. **The commit must be signed off** (DCO) and carries a dual-licensing grant.
   Both are explained in
   [CONTRIBUTING.md](CONTRIBUTING.md#copyright-and-dual-licensing--please-read-this-part);
   they are not restated here so that there is only one copy to keep correct.

**A gap you should know about:** CI proves the Mac app *builds* and that its
offline self-tests pass. It cannot prove a **call** works — no CI runner has a
camera, a microphone, or a second machine. Everything about how a real call
sounds or looks is checked by the maintainer, by hand, using the scripts in
[`mac/tools/`](mac/tools). If your PR touches `mac/`, say what you ran and on
what hardware, because a green badge does not cover it.

## How disagreements end

By discussion in public, in the issue or PR, and then by the maintainer's call.
There is no appeal process, because there is nobody to appeal to. If you think a
decision is wrong, the most productive move is a measurement that contradicts
it — that is explicitly welcome, and it is the one argument that reliably
changes minds here.

If the decision still does not go your way, the AGPL guarantees your fallback:
fork it. That is not a brush-off, it is the deal the licence makes, and the
[licence position](#licensing-and-your-contributions) below explains what a fork
can and cannot do.

Conduct problems are a separate track and are **not** resolved by this file. See
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), which routes to `conduct@tokkah.com`.
Note that the same person reads that address — if that is a conflict for your
report, raise it directly with GitHub Support instead.

## How someone becomes a maintainer

Nobody has, yet, so there is no track record to describe and this section is
necessarily a statement of intent rather than a documented process.

What would earn it: a sustained series of merged changes that each carried their
own measurements, plus review comments on other people's changes that caught
real problems. Roughly "you have already been doing the job". The maintainer
would offer commit access; there is no application form and no vote.

The one hard limit is below: commit access is not the same thing as the ability
to cut a release.

## Releases, and the keys that gate them

Anyone can build this project. **Only the maintainer can ship the official
release**, and that is a deliberate, permanent property of the design rather
than an oversight.

Two secrets live outside this repository, on the maintainer's machine, under
`~/.config/kin-signing/`:

- **The code-signing certificate.** macOS pins a camera or microphone grant to
  the app's *designated requirement*. Signing every release with one persistent
  certificate is what stops macOS from treating each update as a brand-new
  application and re-asking every user for permission. The reasoning and the
  measurements are in [mac/SIGNING.md](mac/SIGNING.md).
- **The update-signing private key.** The updater verifies an Ed25519 signature
  over the release manifest against a public key compiled into the app
  (`mac/Sources/tk/Update.swift`). There is no override flag, on purpose — an
  updater that installs whatever a URL serves is a remote-code-execution channel
  into every machine running it.

Both are excluded from the repository for the obvious reason: this repo is
public and AGPL, and publishing either would let anyone sign something macOS and
the updater treat as this app.

**What this means for a fork.** You can clone, build, run, modify and distribute
the app — the AGPL grants all of it and nothing here restricts it. What you
cannot do is publish an update that existing Kin installations will accept, or
sign a build that inherits this app's permission identity. A fork that wants its
own release channel generates its own certificate
(`mac/tools/make-identity.sh`) and its own Ed25519 key, and its users install it
as a new app. That is the correct outcome — it is the same boundary that stops a
stranger from pushing code to your machine — but it does mean "fork it" costs
more here than in a pure-source project.

There are currently **no git tags and no GitHub Releases**:

```bash
git ls-remote --tags origin | wc -l   # 0
curl -s https://api.github.com/repos/deshmukhpatel98/tokkah/releases   # []
```

A release is a commit whose message is the version number, plus a signed
`manifest.json` published to `room.tokkah.com/macos/`. If you need to pin a
version, pin the commit.

## If the maintainer disappears

The realistic answer for a project with a bus factor of one:

- **The code survives, permanently.** It is AGPL-3.0 and mirrored on every clone
  in existence. Nobody can withdraw that grant, and everything published before
  commit `6375ae4` additionally remains MIT-licensed forever.
- **The running service does not.** `room.tokkah.com` is the maintainer's
  Cloudflare account. Signalling, the doorbell, the download and the update feed
  all live there, and they stop when that account does. The Worker is in this
  repo (`tape-app/`) and can be deployed by anyone on a free Cloudflare account,
  so a successor deployment is a real option rather than a theoretical one.
- **Installed copies keep working until they need something from the network.**
  Calls are peer-to-peer, but rendezvous is not.
- **The signing keys are not recoverable.** If they are lost, no one can ship an
  update that existing installations accept. A continuation would be a new app
  with new keys, and every user would install it once, by hand.

There is no succession plan, no named successor, and no organisation holding
anything in escrow. If you are deciding whether to depend on this project, that
paragraph is the one to weigh — and it is here precisely so that you can weigh
it before rather than after.

## Licensing and your contributions

The project is dual-licensed: [AGPL-3.0](LICENSE) plus
[attribution terms](ATTRIBUTION.md), with a
[commercial licence](LICENSE-COMMERCIAL.md) as the alternative for closed-source
use. That second option only stays possible while a single party can license the
whole codebase, which is why contributions carry a licensing grant alongside the
DCO sign-off.

Both are stated in full in
[CONTRIBUTING.md](CONTRIBUTING.md#copyright-and-dual-licensing--please-read-this-part).
If you are not comfortable with the grant, open an issue before writing code —
that conversation is much better had early than at the end.

## Changing this file

Like any other change: a pull request, and the maintainer decides. If this
document ever stops describing what actually happens, that is a bug in the
document, and it is worth reporting as one.
