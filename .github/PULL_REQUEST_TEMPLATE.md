## What changed

<!-- One or two sentences. -->

## Why

<!-- The problem this solves. Link an issue if there is one. -->

## Measurements

<!--
  This project ships measured claims only. Before/after numbers, and how you
  produced them: which rig, which machines, a live call or a local run. If two
  Macs were involved, say whether both were on the same build — `tk --version`,
  or the last row of Kin's settings panel. Two builds that look identical and
  behave differently make a paired comparison worthless.

  If your change cannot be measured — a docs fix, a rename — write "n/a" and
  why. If it *should* be measurable and you are not sure how, say so and ask;
  that is a normal conversation here, not a blocker.
-->

## How to verify

<!-- What a reviewer should run or watch to see it working. -->

## Checklist

Only tick the group your change touches.

**The Worker (`tape-app/`)**

- [ ] `npm test` passes
- [ ] `npx tsc --noEmit` is clean
- [ ] `npx wrangler deploy --dry-run` builds

**Kin, the macOS app (`mac/`)**

- [ ] `swift build` succeeds
- [ ] The offline self-tests pass. CI runs them; locally it is
      `swift build && .build/debug/tk --sameroom-test --mute` and the same for
      `--gate-test --ledger-test --cue-test --yield-test --decimator-test
      --headphone-test --subtitle-test` (those seven also want
      `--listen <a free port> --video off --no-telemetry --no-update`).
- [ ] If it touches audio, video or the call path: exercised on a real call
      between two machines, not only on a rig. Say so under Measurements.

**Everything**

- [ ] Commits are signed off (`git commit -s`) per the DCO in CONTRIBUTING.md
- [ ] No new runtime dependencies (the shipped app has zero, deliberately)
- [ ] No screenshots, captures or rig output committed. `.gitignore` covers
      the known shapes; `git status` before you push is the real check.
