## What changed

<!-- One or two sentences. -->

## Why

<!-- The problem this solves. Link an issue if there is one. -->

## Measurements

<!--
  This project ships measured claims only. Before/after numbers, and how you
  produced them (which rig, which browsers, live call or local).

  If your change cannot be measured — a docs fix, a rename — write "n/a" and
  why. If it *should* be measurable and you are not sure how, say so and ask;
  that is a normal conversation here, not a blocker.
-->

## How to verify

<!-- What a reviewer should run or watch to see it working. -->

## Checklist

- [ ] `npm test` passes in `tape-app/`
- [ ] `npx tsc --noEmit` is clean
- [ ] `npx wrangler deploy --dry-run` builds
- [ ] Commits are signed off (`git commit -s`) per the DCO in CONTRIBUTING.md
- [ ] No new runtime dependencies (the shipped app has zero, deliberately)
