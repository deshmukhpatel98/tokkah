# Openness scorecard

How open is this project, really? Not "we published the code" — *can a stranger
understand it, build it, run it on their own machines, verify what they
downloaded, change it, and know where they stand legally?*

This file is the rubric and the honest score. It is versioned with the code, so
when the score drops, that shows up in a diff like everything else.

**Current score: 88 / 100** · audited 2026-08-26 against commit `13b85b3` (0.69.0)

Every row was verified by running something. The command is written next to the
claim, so you can disagree with the score by running it yourself.

---

## What the last audit got wrong

The previous version of this file said **100 / 100**, "last audited 2026-08-12
against commit `HEAD`". That is worth opening with, because a scorecard that
cannot be wrong is decoration.

Three things were wrong with it, and they are three different kinds of wrong.

**It scored the wrong product.** Between that audit and this one the project
pivoted from a browser embed to Kin, a native macOS app, and ~380 commits
landed. An entire 15-point section graded the `<script>` embed; nothing
anywhere asked whether you could build the actual product, verify what you
downloaded, or point it at your own server. A rubric that does not follow the
product measures nothing.

**"Against commit `HEAD`" is not a commit.** `HEAD` moves. The audit could not
be reproduced or falsified even in principle. Hence a real sha above.

**Two rows were false at the time they were written**, and stayed false:

| Row | Claimed | Actually |
|---|---|---|
| 6.4 | "Versioned releases and a changelog · tagged releases" | `git tag` → **0 tags**. GitHub releases API → **`[]`**. Sixty-nine versions shipped and not one was tagged. |
| 5.3 | "Security policy with private reporting" | `SECURITY.md` existed but contained no reporting instructions at all, and GitHub private vulnerability reporting was **disabled**. |

A third claim was false in the changelog rather than here: it said two committed
`node_modules` symlinks had been removed. They were still in `HEAD`, dangling in
every clone, from the first commit. `.gitignore` said `node_modules/` — and a
trailing slash matches directories only, so a *symlink* by that name was never
ignored.

All of these are fixed. They are recorded here rather than quietly corrected,
because the previous 100 is the reason to distrust this 89, and pretending
otherwise would earn the distrust twice.

> **Three fixes in this audit are static assets and reach people only on the
> next Worker deploy**, which is a production action the maintainer takes
> deliberately: the licence name beside the Source link, the repaired `embed.js`,
> and the download page's minimum-macOS claim (it says **13**, the app needs
> **14** — `Package.swift` is `.macOS(.v14)` and `Info.plist` is `14.0`, so
> anyone on 13 currently downloads 1.5 MB that cannot launch). Verified still
> unshipped at the time of writing: `curl -s https://room.tokkah.com/embed.js |
> grep -c web=1` → `0`. Nothing else in this scorecard depends on a deploy.

---

## 1. Can I use it legally, and do I know when I owe money? — 15/15

| # | Criterion | Score | Evidence |
|---|---|---|---|
| 1.1 | An OSI-approved licence, in the repo, machine-detectable | 3/3 | [LICENSE](LICENSE) — GNU AGPL v3, verbatim FSF text. `gh api repos/deshmukhpatel98/tokkah --jq .license.spdx_id` → `AGPL-3.0` |
| 1.2 | Commercial terms stated publicly, not "contact sales" | 3/3 | [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md) — a table of who owes what, and an explicit list of who owes nothing |
| 1.3 | Contributor terms stated before you contribute | 3/3 | [CONTRIBUTING.md](CONTRIBUTING.md) — DCO sign-off plus the dual-licensing grant, in plain words, above the fold |
| 1.4 | Every file's licence is machine-readable | 3/3 | **REUSE 3.3 compliant**: `bash tools/reuse-check.sh` → "Congratulations!", **434/434 files** carry copyright *and* licence, 0 bad, 0 missing, 0 invalid SPDX expressions. Declared centrally in [REUSE.toml](REUSE.toml) rather than as headers — the reasoning is at the top of that file |
| 1.5 | AGPL §13: the running service offers its own source | 3/3 | The footer of every public page links the repo — live now, `curl -s https://room.tokkah.com/kin \| grep -i github`. This audit also added the licence **name** beside that link (`tape-app/public/kin.html`, `join.html`), because a bare "Source" tells a visitor nothing about their rights; **that part is in the repo and reaches people only on the next Worker deploy** |
| 1.6 | Licence history is honest (no silent relicensing) | ✓ | The MIT era is named by commit in LICENSE-COMMERCIAL.md; that grant is acknowledged as irrevocable |
| 1.7 | The identifier is precise, and the precision is explained | ✓ | `AGPL-3.0-only`, not `-or-later`: nothing in this repo has ever said "or any later version". Consistent across REUSE.toml, CITATION.cff and all five `package.json` files — checked, because one of them said `ISC` |

## 2. Can I get it, and know that what I got is really theirs? — 12/15

This section did not exist before. It is the one that matters most for a desktop
app you download and then let update itself.

| # | Criterion | Score | Evidence |
|---|---|---|---|
| 2.1 | Releases are signed, and the signature is enforced | 3/3 | Every manifest is Ed25519-signed; [mac/Sources/tk/Update.swift](mac/Sources/tk/Update.swift) verifies against a compiled-in key and **fails closed** — a missing `.sig`, a non-base64 `.sig`, or an invalid signature each refuse the update and say which, in plain words |
| 2.2 | The public key is published where you can compare it | 2/2 | [tools/README.md](tools/README.md) and `Update.swift`, in the open: `d07822ed…5b2a`. A signature checked against a key the same server handed you proves nothing |
| 2.3 | A stranger can verify a download, with what is on their machine | 3/3 | `python3 tools/verify-release.py` → VERIFIED, exit 0, against the live 0.69.0. **Zero dependencies on purpose**: macOS ships LibreSSL 3.3.6, which cannot do Ed25519 at all, and stock Command Line Tools `python3` has no CA bundle — both measured here, both worked around in the tool |
| 2.4 | The verifier is calibrated before it is trusted | 2/2 | `bash tools/verify-release-selftest.sh` → **SELF-TEST PASSED (7 checks)**. It requires a refusal for a manifest altered by one bit, a signature altered by one bit, a non-base64 signature, a wrong public key, and an archive whose bytes do not match the signed hash |
| 2.5 | Versioned releases you can actually fetch | 2/2 | **17 annotated tags** now exist (`git tag`), where there were none. The history has gaps — versions that shipped without a version-named commit are deliberately left untagged rather than guessed at. `mac/release.sh` now creates and pushes the tag itself, after the edge has served the manifest and the tarball has been fetched back and hashed, so a tag means "shipped and verified". It previously contained no git at all, which is why nobody was skipping a step: there was no step |
| 2.6 | The binary can be shown to come from this source | **0/3** | **It cannot.** Swift release builds here are not reproducible, and nothing attests that the shipped `tk` was built from the commit it claims. You can verify the download is the one *we signed*; you cannot verify we signed what is in this repo. This is the largest single gap in the project and it is not a small fix |
| 2.7 | Not notarized, and it says so | ✓ | There is no Apple Developer ID and there will not be one. Stated on the download page, in the README, and in `tools/README.md` next to the thing that replaces it |

## 3. Can I build it myself? — 14/15

| # | Criterion | Score | Evidence |
|---|---|---|---|
| 3.1 | Clean clone → the actual product builds | 4/4 | `git clone … && cd tokkah/mac && swift build` → **"Build complete!"**, exit 0, on a machine that had never built it |
| 3.2 | The thing you built runs and proves itself | 4/4 | `.build/debug/tk --version` → `0.69.0`; `tk --gate-test` → `GATE TEST PASSED`, exit 0; `tk --definitely-not-a-flag` → exit 2, because an unknown option is refused rather than ignored |
| 3.3 | The backend builds and deploys with no credentials | 3/3 | `npm ci` → 0; `npx tsc --noEmit` → 0; `npx wrangler deploy --dry-run` → 0, all bindings resolve. `--dry-run` touches no account, which is also the check that it stays deployable by anyone |
| 3.4 | Reproducible installs | 3/3 | `tape-app/package-lock.json` committed; `npm ci` pins exact versions; CI runs the same command |
| 3.5 | Build requirements are stated, including the awkward ones | 0/1 | Docked: the macOS job needs a **macOS 26 SDK** because `AppleSpeech.swift` uses `SpeechAnalyzer`/`SpeechTranscriber`, and `#available` is a runtime gate, not a compile-time one — so an older SDK fails to *compile*, not to run. That is now in CI but is not yet stated in the README |

## 4. Can I run it on my own infrastructure? — 12/15

| # | Criterion | Score | Evidence |
|---|---|---|---|
| 4.1 | The app can be pointed at a server that is not ours | 4/4 | `--server <url>`, `TK_KIN_BASE`, `TK_UPDATE_BASE`, or a `server.json` beside the app — [mac/Sources/tk/Server.swift](mac/Sources/tk/Server.swift). **Before this audit it could not**: `https://room.tokkah.com` was written out seven times across six files, so you could clone Kin, build it, and the app you built still phoned our server. Verified **at the receiving end**, not from the app's own log: a throwaway listener on `127.0.0.1` caught the rendezvous poll, the handle registration, `/api/mac/turn` and the telemetry POST — 30 requests — while the run made **zero** references to `room.tokkah.com` |
| 4.2 | Existing installs cannot tell the difference | 2/2 | With no flag, no environment variable and no file, all three origins resolve to the byte-identical strings compiled in at 0.69.0 — the proof is a command in [SELF-HOSTING.md](SELF-HOSTING.md) |
| 4.3 | Deploys on a **free** account | 3/3 | Both Durable Objects are declared `new_sqlite_classes`, which is what Workers Free requires. `node testbed/freetier-audit.mjs` → **FREE-TIER AUDIT PASSES**, worker bundle **42.3 KiB gzipped, 1.4% of the 3 MiB limit**, cross-checked against wrangler's own 42.33 KiB. (The previous audit said 52.6 KiB / 1.7%; that number was gzipping a 392 KB sourcemap and a README along with the worker) |
| 4.4 | No secrets or paid add-ons required | 2/2 | TURN keys are optional; without them the app falls back to STUN and degrades gracefully — see `/api/ice`. Enforced, not assumed: the free-tier audit rejects paid-only bindings, KV-backed DOs, oversized bundles, or a config needing a domain or a secret |
| 4.5 | A self-hoster can sign their own updates | 1/2 | Verification is correctly never optional, and a self-hoster supplies their own key ([SELF-HOSTING.md](SELF-HOSTING.md) Part 3 walks the keypair through). Docked one: the path is *documented rather than demonstrated* — no fork has been stood up end to end and measured |
| 4.6 | The whole call path can be yours | **0/2** | **It cannot, and the guide says so in Part 4.** There is no STUN server in the Worker: a fully self-hosted Kin still asks `stun.cloudflare.com`, then Google's, to learn its own address (`mac/Sources/tk/Stun.swift:28`). TURN is `rtc.live.cloudflare.com` with **no code path for coturn or any other relay** — pointing Kin at your own means writing it. Handles are per-server and do not migrate |

## 5. Can I understand it? — 10/12

| # | Criterion | Score | Evidence |
|---|---|---|---|
| 5.1 | The README describes the product that exists | 3/3 | Rewritten in this audit. It had opened with "Live demo: room.tokkah.com — open it in two tabs, that's a call" and a `<script>` tag called "the entire integration", ~380 commits and one pivot after that stopped being true |
| 5.2 | Architecture written down | 2/2 | [DESIGN.md](DESIGN.md), plus a repo map in the README pointing at real file paths |
| 5.3 | Claims are measured, and the measurements are published | 2/2 | [MEASURED.md](MEASURED.md) — including the ideas that lost to their own data. Where a number is a loopback or a simulation, the README says so next to the number |
| 5.4 | Comments explain *why*, not *what* | 2/2 | Source comments carry the reason and usually the measurement that forced the decision. This is the single best thing about the codebase and is why licensing is declared in REUSE.toml rather than stamped above every one of them |
| 5.5 | A newcomer is not made to wade | 1/3 | Docked two: **30 markdown files sit at the repository root** with no index, several of them internal engineering logs, and `DESIGN.md` alone is 720 KB. Nothing is hidden; a lot is unsorted |

## 6. Can I participate? — 11/13

| # | Criterion | Score | Evidence |
|---|---|---|---|
| 6.1 | CONTRIBUTING with a real quick-start | 2/2 | [CONTRIBUTING.md](CONTRIBUTING.md) — clone to running, for both halves |
| 6.2 | Code of conduct | 2/2 | [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) — Contributor Covenant 2.1, with a real contact address |
| 6.3 | Security policy that says how to report | 2/3 | [SECURITY.md](SECURITY.md) now has a reporting section and the Mac app's trust model — it had **neither**. Docked one: GitHub private vulnerability reporting is still **disabled** (`gh api …/private-vulnerability-reporting` → `{"enabled": false}`), which only the repository owner can change |
| 6.4 | How decisions get made | 3/4 | [GOVERNANCE.md](GOVERNANCE.md), new in this audit. One maintainer, said plainly, including what happens if he disappears and why the signing keys are a boundary a contributor cannot cross. Docked one: no outside contributor has ever tested any of it, so it is a stated intention rather than an observed practice |
| 6.5 | Issue and PR templates that ask the right questions | 2/2 | Rebuilt around the Mac app: Kin version (now visible in the app's settings panel), macOS version, output device and sample rate. The bug form had been asking which **browser** |
| 6.6 | Somewhere to ask a question that is not a bug | ✓ | GitHub Discussions enabled; [SUPPORT.md](SUPPORT.md) routes each kind of question |
| 6.7 | The project is citable | ✓ | [CITATION.cff](CITATION.cff) — `cffconvert --validate` → "valid according to schema version 1.2.0" |

## 7. Can I trust it? — 14/15

| # | Criterion | Score | Evidence |
|---|---|---|---|
| 7.1 | CI covers the actual product | 3/3 | `.github/workflows/ci.yml` builds `mac/` on macOS and runs **12 offline self-tests**, plus the Worker's tests, type-check and credential-free deploy build on Linux. **Before this audit the flagship had no CI at all** |
| 7.2 | CI is green, and can go red | 3/3 | It was **red** when this audit started — `main` had gone 13 days without a push and the first one failed in 13 seconds. Now: `npm test`, `tsc --noEmit`, `wrangler --dry-run` and `freetier-audit` all exit 0. The macOS job was calibrated by rigging a test to fail and confirming the job fails with it |
| 7.3 | Tests test, rather than exist | 3/3 | The one test that runs the real Worker in real `workerd` against real durable storage was ported to Miniflare 5 and then **mutation-tested**: with the durable write deleted, the test fails; with it restored, it passes. Zero assertions were removed in the port |
| 7.4 | No secrets in the repo, provably | 3/3 | `bash tools/secret-scan.sh` → CLEAN across **484 commits on every branch**, and it **calibrates itself first** by planting three secrets, deleting them, and requiring all three be found. Separately, the literal bytes of the real signing keys were searched for across all history: two hits, both investigated, both public-by-construction (an OpenSSL `keyUsage` string and the signing certificate's root hash, documented on purpose) |
| 7.5 | Supply chain of the build itself | 1/2 | GitHub Actions are pinned by commit SHA, not by a movable tag, and `.github/dependabot.yml` keeps those pins and the npm lockfile current. Docked one: no SLSA provenance, and see row 2.6 |
| 7.6 | Limitations stated, not hidden | 1/1 | Parked features are named as parked; MEASURED.md logs the retreats; this scorecard opens with its own last failure |
| 7.7 | Documentation links actually resolve | ✓ | `bash tools/link-check.sh --external` — every relative link, every `#anchor` against real headings, and every external URL |

---

## What "88" does and does not mean

It means a stranger can read it, build it, run it against their own backend,
check that a download is genuinely ours, contribute to it, and know exactly
where they stand legally — and that each of those was *checked* rather than
assumed.

It does not mean the software is finished, and it does not mean the remaining 12
points are cosmetic. They are, in order of how much they would actually cost
someone:

1. **You cannot prove the shipped binary came from this source** (2.6, −3). Every
   other trust property rests on the signing key rather than on the code you can
   read. Reproducible builds would fix it; nothing cheaper will.
2. **The repository root is a wall of 30 documents** (5.5, −2).
4. **Private vulnerability reporting is switched off** (6.3, −1) — one toggle,
   and only the owner can flip it.
5. **STUN and TURN are not yours** (4.6, −2). Self-hosting gets you the
   signalling, the API and the release feed; the two things that punch through a
   difficult network are still Cloudflare's and Google's.
6. **Governance is stated but never exercised** (6.4, −1): no outside contributor
   has tested any of it.
7. **Self-hosted signing is documented, not demonstrated** (4.5, −1), **no build
   provenance** (7.5, −1), and **the macOS SDK requirement is in CI but not in
   the README** (3.5, −1).

That is −12, and 100 − 12 = 88.

The scorecard measures openness, not completeness — conflating the two would be
exactly the kind of unmeasured claim this project exists to avoid.

## How to re-audit

Everything below is offline or credential-free, except where it says otherwise.

```bash
bash tools/secret-scan.sh          # self-calibrating; refuses to run if blind
bash tools/reuse-check.sh          # REUSE 3.3 over what a stranger receives
bash tools/link-check.sh --external
bash tools/verify-release-selftest.sh   # calibrate, then trust
python3 tools/verify-release.py         # the live release

cd mac && swift build && .build/debug/tk --version && .build/debug/tk --gate-test
cd tape-app && npm ci && npm test && npx tsc --noEmit && npx wrangler deploy --dry-run
node testbed/freetier-audit.mjs
```

Then, and this is the part no script does:

1. Clone into an empty directory, on a machine that has never built this.
2. Follow only the README. Time yourself. Anything that makes you open a source
   file to proceed is a documentation bug — file it.
3. Check every row above still has its evidence. **Lower the score honestly if
   not**, and pin the audit to a real commit sha, not to `HEAD`.
