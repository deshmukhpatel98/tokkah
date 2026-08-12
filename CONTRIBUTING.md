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

## Quick start

```bash
git clone https://github.com/deshmukhpatel98/tokkah.git
cd tokkah/tape-app
npm ci                 # exact versions from the lockfile
npm test               # unit suites
npx wrangler dev       # local dev server at http://localhost:8794
```

To deploy your own copy (works on a **free** Cloudflare account):

```bash
npx wrangler deploy
```

That gives you `tokkah.<your-subdomain>.workers.dev`. See the README for the
optional TURN and custom-domain steps.

## Before you open a pull request

1. **Run the tests**: `npm test` in `tape-app/`.
2. **Check the types**: `npx tsc --noEmit`.
3. **Verify a deploy still builds**: `npx wrangler deploy --dry-run`.
4. **Describe the measurement.** What did you run, on what, and what were the
   numbers before and after?

CI runs 1–3 automatically on every pull request. Step 4 is on you.

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

- **Bug fixes with a repro.** Best of all: a rig under `testbed/` that fails
  before your fix and passes after.
- **Measurements that contradict us.** Genuinely welcome. If a claim in
  `MEASURED.md` does not reproduce on your hardware, that is a finding, and it
  gets logged with your numbers.
- **Portability.** Browser or device combinations we do not have. Safari and
  Android reports are especially valuable.
- **Plain-language documentation.** If a paragraph in this repo needed two
  readings, it is a bug in the paragraph.

## What is likely to be declined

- Dependencies. The client ships with **zero runtime dependencies** and the
  Worker has none either. That is a deliberate constraint, not an oversight.
- Anything that adds latency to the audio or video path. Presence features
  must run on idle time or the compositor, never on the media pipeline.
- Claims without measurements (see above).

## Security issues

Do not open a public issue. See [SECURITY.md](SECURITY.md) for private
reporting.

## Code of conduct

Participation is governed by the [Contributor Covenant](CODE_OF_CONDUCT.md).
Report concerns to conduct@tokkah.com.
