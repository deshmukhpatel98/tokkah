# Signing, and why the permission prompts kept coming back

macOS pins a camera or microphone grant to the app's **designated requirement** — a rule
`tccd` evaluates against the running code every time it is asked for access. Get that rule wrong
and the grants evaporate on every release, which is what was happening here.

## What it used to be

Bundles were signed ad-hoc (`codesign -s -`), in three separate places: the web installer, the
self-install path, and the self-updater after every update. An ad-hoc signature's requirement is

```
designated => cdhash H"4d912c63e0b14021dc10dfa7b784d462b3768955"
```

a hash of the bundle's contents. `tccd` was observed refusing to match one:

```
-[TCCDAccessIdentity matchesCodeRequirement:]: SecStaticCodeCheckValidity()
  static code from com.tokkah.tk : cdhash H"4d912c63…"; status: 0
```

Every release changes the binary and `CFBundleVersion`, so the hash changes, so as far as TCC is
concerned a brand-new application is asking — and it asks the user again.

Worth being precise about the mechanism, because the obvious explanation is wrong: **ad-hoc
signing is deterministic over content.** Re-signing an unchanged bundle reproduces the identical
cdhash. Measured on a copy of the installed app:

| step | CDHash |
| --- | --- |
| as installed | `bde5c168…` |
| `codesign -s - -f --deep`, no content change | `bde5c168…` unchanged |
| again | `bde5c168…` unchanged |
| add one file under `Contents/Resources`, re-sign | `64f51b44…` changed |
| edit `Info.plist` version, re-sign | `c2dd4136…` changed |

So the re-signing was never the culprit. *Changing bytes* was, and the cdhash-based requirement
followed them. Removing the re-sign alone would have fixed nothing.

It was then caught happening. `/Applications/Kin.app` self-updated from 0.44.0 to 0.45.0 while
this was being written:

```
0.44.0   CDHash 4d912c63e0b14021dc10dfa7b784d462b3768955
0.45.0   CDHash eb514663b0139dd8303d825f60362e4e78979c27   designated => cdhash H"eb514663…"
```

One release, one brand-new identity, and every grant pinned to the old one gone with it.

## What it is now

Everything is signed at release time with one persistent self-signed certificate, giving

```
designated => identifier "com.tokkah.tk" and certificate root = H"ef8e905f…"
```

which is byte-identical for every build, because it names the certificate rather than the
contents. Verified on the real bundle: a content change that moved the cdhash `0cc9bae7…` →
`ac9f0b02…` left this requirement unchanged.

Two halves, and both are required:

1. **Release time** — `bundle/mkapp.sh` signs the whole bundle and asserts the requirement it
   produced. `release.sh` then extracts the packaged tarball and re-verifies the signature on the
   *extracted* copy, because an archive that drops what a signature covers produces a bundle that
   is broken on arrival.
2. **The user's machine** — nothing signs, ever. `Update.swift` swaps the whole bundle in one
   `renamex_np(RENAME_SWAP)` exchange rather than patching files inside it, because editing a
   bundle invalidates any real signature over it, and a machine with no private key cannot repair
   what it breaks.

## Setting it up

```bash
mac/tools/make-identity.sh
```

Creates the certificate, a dedicated keychain, and `~/.config/kin-signing/env`, which is what
`mkapp.sh` and `release.sh` read. Idempotent: run it again and it reuses what exists.

Deliberately **not** in this repo. The repo is AGPL and public, and this key is the app's
permission identity — publishing it would let anyone sign something macOS treats as this app.

### The key is now a build secret

- Back up `~/.config/kin-signing/kin-signing.p12` somewhere durable.
- Releases can only be cut on a machine that has it.
- Replacing it changes the requirement, which re-prompts **every** user exactly once.
- Certificate expiry (10 years) limits *signing*, not *matching* — the requirement is a hash
  comparison, so already-signed copies keep working past it.

### What this does not change

Gatekeeper. A self-signed certificate is no more trusted than ad-hoc, `spctl` still rejects the
bundle, and the one-time "Open Anyway" is unchanged. This buys permission persistence, not
notarisation.

Two things look alarming and are fine:

- `security find-identity -v -p codesigning` reports **0 valid identities** — the root is
  untrusted. `codesign` signs with it regardless. Do not gate CI on that command.
- `security import` succeeds silently. Check its exit code, not its output.

## The migration

The updater that applies release N+1 is the one already installed, so the archive cannot change
shape in a single step.

- **0.46.0** — ships the updater that understands a signed-bundle payload, and starts shipping
  that payload. New installs (`install.sh`, the `.dmg`) get the certificate identity immediately,
  since `install.sh` is fetched fresh and carries no compatibility debt. Copies updating *from*
  0.45.0 still come through the legacy path and pay one last prompt.
- **0.47.0 onward** — those copies are now running the new updater and swap the bundle whole.
  Identity becomes permanent.
- The legacy `tk` + `bundle/` payload comes out of the archive only once nobody is below 0.46.0.
  Until then the archive carries the binary twice and is about twice the size.

## What was measured

Two successive self-updates through the real updater, against a local server, with genuinely
different bundle contents at each hop:

```
hop 1  9.0.0 -> 9.0.1   cdhash abcce24c… -> 3ec2d86d…
hop 2  9.0.1 -> 9.0.2   cdhash 3ec2d86d… -> 9612a8c6…
requirement, all three:  identifier "…" and certificate root = H"ef8e905f…"
authority after each:    Kin Signing
```

The cdhash moved at every hop — under ad-hoc that *is* the requirement, so each hop would have
cost the user their grants. The requirement did not move.

Two absences in the updater's log are what prove the new path actually carried it, rather than the
legacy branch quietly doing the work: **zero** `re-sign returned` and **zero** `using legacy path`.
`Authority=Kin Signing` surviving both hops says the same thing from the other side — an ad-hoc
re-sign would have replaced it.

What this does **not** prove: that a *grant* survives. That needs a real grant against the
certificate identity, and the first one requires a human clicking Allow. The mechanism above is
the thing TCC keys on, but "the requirement held" and "TCC matched it" are different claims and
only the second one ends the bug.

## Checking it

```bash
codesign -dr - /Applications/Kin.app
```

must print

```
designated => identifier "com.tokkah.tk" and certificate root = H"ef8e905f64c0f5baf7f5bc84dcd0ad5d52e6a32e"
```

If it prints a `cdhash` instead, that copy is ad-hoc signed and will lose its permissions on the
next update. `mkapp.sh` and `release.sh` both fail the build if this string ever changes, since a
change means re-prompting everyone.

To see what TCC actually decided, rather than what the app believes:

```bash
/usr/bin/log show --last 1h --predicate 'process == "tccd"' --info | grep tokkah
```

Note the absolute path — `log` is shadowed by a shell function in some profiles here, and the
shadowed version silently returns nothing, which reads exactly like "no events".
