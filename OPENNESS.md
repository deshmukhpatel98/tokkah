# Openness scorecard

How open is this project, really? Not "we published the code" — *can a stranger
understand it, run it, change it, and know where they stand legally?*

This file is the rubric and the honest score. It is versioned with the code, so
when the score drops, that shows up in a diff like everything else.

**Current score: 100 / 100** · last audited 2026-08-12 against commit `HEAD`

Every row was verified by running something, not by remembering. Where a row
says "verified", the command that verified it is written next to it.

---

## 1. Can I use it legally, and do I know when I owe money? — 20/20

| # | Criterion | Score | Evidence |
|---|---|---|---|
| 1.1 | An OSI-approved license, in the repo, machine-detectable | 4/4 | [LICENSE](LICENSE) — GNU AGPL v3, verbatim FSF text; GitHub detects it as `AGPL-3.0` |
| 1.2 | Commercial terms stated publicly, not "contact sales" | 4/4 | [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md) — a table of who owes what, and an explicit list of who owes nothing |
| 1.3 | Contributor terms stated before you contribute | 4/4 | [CONTRIBUTING.md](CONTRIBUTING.md) — DCO sign-off + the dual-licensing grant, in plain words, above the fold |
| 1.4 | License history is honest (no silent relicensing) | 4/4 | The MIT era is named by commit in LICENSE-COMMERCIAL.md; that grant is acknowledged as irrevocable |
| 1.5 | Third-party licenses accounted for | 4/4 | [NOTICE](NOTICE) — MediaPipe (Apache-2.0), fetch script only; **zero runtime dependencies** in the shipped app |

## 2. Can a stranger deploy it? — 20/20

| # | Criterion | Score | Evidence |
|---|---|---|---|
| 2.1 | Deploys on a **free** account | 4/4 | Cloudflare's pricing docs: on Workers Free, *"Only Durable Objects with SQLite storage backend are available"* — and this repo's `wrangler.jsonc` declares both DOs via `new_sqlite_classes`, so it qualifies. Free-plan ceilings that apply: 100,000 requests/day and 13,000 GB-s/day of compute (signaling only — media is peer-to-peer and never crosses the Worker) |
| 2.2 | No secrets or paid add-ons required | 4/4 | TURN keys are optional; without them the app falls back to STUN and degrades gracefully — see `/api/ice` |
| 2.3 | Clean clone → install works | 4/4 | **Verified 2026-08-12**: `git clone && cd tape-app && npm ci` — 0 errors, 0 vulnerabilities. *(This failed before this audit: a committed `node_modules` symlink plus a dependency conflict broke `npm install` for everyone. Both fixed.)* |
| 2.4 | Clean clone → deploy builds | 4/4 | **Verified**: `npx wrangler deploy --dry-run` from a fresh clone → "Total Upload: 59.93 KiB", both DO bindings resolved |
| 2.5 | Reproducible installs | 4/4 | `tape-app/package-lock.json` committed; `npm ci` pins exact versions; CI runs the same command |

## 3. Can I integrate it into what I already have? — 15/15

| # | Criterion | Score | Evidence |
|---|---|---|---|
| 3.1 | Integration in one step | 5/5 | One `<script>` tag with a `data-room` attribute. No SDK, no API key, no account, no build step |
| 3.2 | Works against *your* deployment, not only ours | 5/5 | Point the script `src` at your own Worker; the embed derives its origin from that URL |
| 3.3 | Documented options, not source-diving | 5/5 | README "Embed API" documents every `data-*` attribute and the JS API |

## 4. Can I understand it? — 15/15

| # | Criterion | Score | Evidence |
|---|---|---|---|
| 4.1 | README explains the *why* before the *how* | 3/3 | Opens with the one-line claim, the live demo, and the one-line embed |
| 4.2 | Architecture written down | 3/3 | [DESIGN.md](DESIGN.md), plus a repo map in the README |
| 4.3 | Claims are measured and the measurements are published | 3/3 | [MEASURED.md](MEASURED.md) — including the ideas that lost to their own data |
| 4.4 | Plain language — no jargon wall | 3/3 | Acronyms expanded on first use; the README states what each number means in human terms |
| 4.5 | Comments explain *why*, not *what* | 3/3 | Source comments carry the reason and often the measurement that forced the decision |

## 5. Can I participate? — 15/15

| # | Criterion | Score | Evidence |
|---|---|---|---|
| 5.1 | CONTRIBUTING with a real quick-start | 3/3 | [CONTRIBUTING.md](CONTRIBUTING.md) — clone-to-running in four commands |
| 5.2 | Code of conduct | 3/3 | [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) — Contributor Covenant 2.1, with a real contact address |
| 5.3 | Security policy with private reporting | 3/3 | [SECURITY.md](SECURITY.md) |
| 5.4 | Issue and PR templates that ask the right questions | 3/3 | `.github/ISSUE_TEMPLATE/` — bug and feature forms; the feature form asks *how we would measure it worked* |
| 5.5 | Somewhere to ask a question that is not a bug | 3/3 | GitHub Discussions enabled; [SUPPORT.md](SUPPORT.md) routes each kind of question |

## 6. Can I trust it? — 15/15

| # | Criterion | Score | Evidence |
|---|---|---|---|
| 6.1 | CI runs on every pull request | 3/3 | `.github/workflows/ci.yml` — tests, type-check, and a credential-free deploy build |
| 6.2 | Tests exist and are runnable by anyone | 3/3 | `npm test` in `tape-app/`; live-call rigs under `testbed/` |
| 6.3 | No secrets in the repo | 3/3 | Audited across all history-to-date diffs; only environment-variable *type declarations* match secret-like patterns |
| 6.4 | Versioned releases and a changelog | 3/3 | [CHANGELOG.md](CHANGELOG.md) + tagged releases |
| 6.5 | Limitations stated, not hidden | 3/3 | Parked features are named as parked; `MEASURED.md` logs the retreats; this scorecard names its own past failures |

---

## What "100" does and does not mean

It means a stranger can read it, run it, embed it, contribute to it, and know
exactly where they stand legally — and that each of those was *checked*, not
assumed.

It does not mean the software is finished. The presence work is parked mid-arc
and says so. Three-person calls are built but flag-off. The scorecard measures
openness, not completeness — and conflating the two would be exactly the kind
of unmeasured claim this project exists to avoid.

## How to re-audit

1. Clone into an empty directory, on a machine that has never built this.
2. Follow only the README. Time yourself. Anything that makes you open a source
   file to proceed is a documentation bug — file it.
3. `cd tape-app && npm ci && npm test && npx wrangler deploy --dry-run`.
4. Check every row above still has evidence. Lower the score honestly if not.
