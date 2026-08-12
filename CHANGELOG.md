# Changelog

Notable changes to Tokkah. Dates are the day the change landed on `main`.

This project measures its claims; where a change has a number, the number is here.

## Unreleased

### Licensing and openness
- **Relicensed to GNU AGPL v3** with a commercial license alongside it
  ([LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md)). Versions published before
  commit `6375ae4` remain MIT-licensed permanently.
- Added [OPENNESS.md](OPENNESS.md) — a self-graded scorecard of how usable this
  project is by a stranger, with the command that proves each row.
- Added `CONTRIBUTING.md` (DCO + licensing grant), `CODE_OF_CONDUCT.md`
  (Contributor Covenant 2.1), `SUPPORT.md`, `NOTICE`, issue and PR templates,
  `CODEOWNERS`, `.editorconfig`, and CI.

### Fixed — the documented install was broken for everyone
- `tape-app/node_modules` was a **committed symlink** pointing outside the repo;
  it landed broken in every clone. Removed (same for `fatigue-lab/node_modules`).
- `npm install` failed with `ERESOLVE` on a clean clone: `@cloudflare/workers-types`
  was pinned to `^4` while wrangler required `^5`. Dependencies aligned.
- Added `tape-app/package-lock.json` so `npm ci` installs exact, reproducible
  versions — the same command CI runs.
- Verified end to end from a fresh `git clone`: `npm ci` → 0 errors, then
  `wrangler deploy --dry-run` → builds, both Durable Object bindings resolve.

### Fixed
- A malformed room path returned a bodyless 404, which Safari treated as a **file
  download** instead of a page. Document 404s now redirect to the front door.

### Added
- **Hold-to-peek self-view**: a face button that shows your own camera only while
  held, and hides it on release. No persistent mirror — chronic self-view is among
  the largest measured drivers of video-call fatigue.
- **Call telemetry** (anonymous, zero added latency): device tier, tracker type,
  tracker coverage and cadence, alongside the existing echo and latency panels.
  This immediately showed Safari running the face tracker at ~15–19 Hz where
  Chrome ran at 30 — tuning had been done against the wrong engine.
- Operator-only `/api/health/recent` for reading raw beats during debugging.

### Changed
- The presence-window work (head-coupled parallax, peekaboo out-of-view state,
  liveness gate, low-end tracker tier) is **parked behind flags** (`?window=1`,
  `?frame=1`) rather than shipped on. It is built and live-verified, but it did
  not clear the quality bar in [testbed/specs/presence-2.0-plan.md](testbed/specs/presence-2.0-plan.md).
  With the flags off, no tracker bytes are fetched and no transform is applied.
- CSP `script-src` gained `'wasm-unsafe-eval'` for the self-hosted face tracker
  (WebAssembly only; the binaries still must come from `'self'`).
- Vendored MediaPipe binaries (26 MB) are no longer in the repository;
  `tape-app/public/vendor/fetch.sh` reproduces them.

---

Earlier history predates this changelog. `MEASURED.md` is the running lab
notebook and covers that period in far more detail, including the experiments
that failed.
