# Getting help

**Kin is a native macOS app**, not a web page. If you are trying to make a call,
install it from [room.tokkah.com](https://room.tokkah.com) — or
`curl -fsSL https://room.tokkah.com/macos/install.sh | sh` — and have the other
person do the same. Both of you type the same room name. There is no browser
version any more; see
[docs/BROWSER-ERA.md](docs/BROWSER-ERA.md) if you are
looking for it.

Before reporting anything, check which version you are on. The panel shows it,
and so does:

```bash
tk --version
```

## Where to go

| I want to… | Go here |
|---|---|
| Ask "how do I…" or "has anyone tried…" | [Discussions](https://github.com/deshmukhpatel98/tokkah/discussions) |
| Report something broken | [Open a bug report](https://github.com/deshmukhpatel98/tokkah/issues/new?template=bug_report.yml) |
| Suggest a feature | [Open a feature request](https://github.com/deshmukhpatel98/tokkah/issues/new?template=feature_request.yml) |
| Report a security vulnerability | **Do not open an issue** — see [SECURITY.md](SECURITY.md) |
| Understand who decides what | [GOVERNANCE.md](GOVERNANCE.md) |
| Run your own server | [SELF-HOSTING.md](SELF-HOSTING.md) |
| Use this in a closed-source product | [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md), or licensing@tokkah.com |

## Things that are working as intended

Worth checking before you file, because these are all deliberate:

- **macOS warns you the first time you open it.** There is no Apple Developer
  ID and the app is not notarized. System Settings → Privacy & Security →
  **Open Anyway**, once. The `curl` install never meets this at all.
- **Nothing happens on an Intel Mac.** Apple silicon only, macOS 14+.
- **Echo when you are both in the same room, or when someone wears headphones.**
  There is no echo canceller — it was deleted deliberately in 0.56.0 and
  replaced by turn-taking. Kin detects the same-room case and handles it; the
  headphones case is a known consequence.
- **The room name is the password.** Anyone who knows it can join.

## Before you ask

- **[CHANGELOG.md](CHANGELOG.md)** — what changed in each release, with the
  numbers. This is the current record for the Mac app.
- **[DESIGN.md](DESIGN.md)** — how the pieces fit together. §17.77 onward is the
  native app; everything before it is the retired browser product.
- **[MEASURED.md](MEASURED.md)** — the browser-era lab notebook, including every
  experiment that failed. Still the best explanation of the audio ideas, but its
  numbers do not describe the Mac app.

## What we can and cannot promise

This is a one-person project ([GOVERNANCE.md](GOVERNANCE.md)). Issues and
discussions are read; bug reports with a reproduction get attention first. There
is no support SLA on the open-source license — an SLA is one of the things a
[commercial license](LICENSE-COMMERCIAL.md) can include.

Reports that cannot be reproduced are not dismissed; they are usually a Mac,
audio device or network we do not have. Your macOS version, Mac model, `tk
--version`, and which audio input and output you were using genuinely help — the
output device in particular, because it has silently invalidated listening tests
here before.
