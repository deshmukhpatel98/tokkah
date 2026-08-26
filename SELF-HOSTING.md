# Running Kin on your own server

Kin is AGPL-3.0. That licence gives you the right to run your own copy — and
until this document existed, that right was theoretical: `https://room.tokkah.com`
was written into the Swift sources in seven places, so a stranger could clone the
repo, build the app, and the app they built still phoned our server.

That is fixed. This is the walkthrough, including the parts that do not work and
why. A limit you can read is worth more than a limit you discover.

Everything below was run against the code at `0.69.0`. Where a claim is about
behaviour, the command that proves it is next to it.

---

## The short version

```sh
# 1. your backend
cd tape-app && npx wrangler deploy          # → https://tokkah.<you>.workers.dev

# 2. your app
cd mac && swift build -c release
.build/release/tk --server https://tokkah.<you>.workers.dev --room hello
```

That is a working call on your own infrastructure. Updates are a separate step
and are covered below, because they involve a signing key and they **fail closed**
until you have one.

---

## Part 1 — the backend

The whole server is one Cloudflare Worker in `tape-app/`. It is a single file,
`tape-app/src/worker.ts`.

### Deploy it

```sh
cd tape-app
npm install
npx wrangler deploy
```

`tape-app/wrangler.jsonc` is deliberately fork-friendly and needs **no edits**: it
has no `routes` block and `workers_dev: true`, so it deploys to your own
`workers.dev` subdomain without trying to claim anybody's domain.

What it declares, and what you are agreeing to create in your account:

| Binding  | Kind           | Name / class                      |
| -------- | -------------- | --------------------------------- |
| `ASSETS` | static assets  | `./public`, `run_worker_first: true` |
| `ROOM`   | Durable Object | class `Room`                      |
| `HEALTH` | Durable Object | class `Health`                    |
| `MACREL` | R2 bucket      | `tokkah-mac`                      |

The two Durable Objects are created by the `migrations` block already in the file
(`v1` → `Room`, `v2` → `Health`); both use SQLite storage. You do not need to run
anything by hand for them.

**The R2 bucket is the one thing you must create yourself**, and its name is
hardcoded:

```sh
npx wrangler r2 bucket create tokkah-mac
```

Either create it under that name or change `bucket_name` in `wrangler.jsonc`. It
is only used to serve macOS release downloads (`/macos/dl/...`); if you are not
hosting updates, the route answers `503 {"error":"releases not configured"}` and
nothing else breaks.

> **`wrangler.prod.jsonc` is not in this repo.** `tape-app/package.json`'s
> `deploy:prod` script and `mac/release.sh` both pass `-c wrangler.prod.jsonc`,
> and that file is uncommitted — it is the same shape plus a custom-domain route
> for `room.tokkah.com`. You do not need it. Use plain `npx wrangler deploy`.

### What a fresh deploy gives you, with zero secrets set

Working immediately:

- **Rendezvous** — `GET /api/room/<room>/rv`. Two Macs publish their addresses and
  read each other's. This is the whole of Kin's signalling. It is held in memory
  in the `Room` Durable Object with a 90-second lease and is never persisted.
- **The invite funnel** — `/<room>`, `/?r=<room>` and `/join`, served out of
  `public/`.
- **Telemetry ingest** — `POST /api/mac/beat` and `POST /api/mac/crash`, stored in
  the `Health` Durable Object's SQLite (`mac_beats`, 7-day retention;
  `mac_crashes`, 30-day). The room name is never sent; see the comment at the top
  of `mac/Sources/tk/Telemetry.swift` for the full list of what is deliberately
  withheld.

Not working until you set something:

- **TURN relay** — `GET /api/mac/turn` returns `{"ok":false,"p2pOnly":true}` and
  the app quietly proceeds without a relay. Covered next.

### TURN, if you want calls that cross difficult networks

Kin uses Cloudflare's TURN service. The Worker mints short-lived credentials
per request; nothing is baked into the app.

```sh
npx wrangler secret put TURN_KEY_ID
npx wrangler secret put TURN_KEY_API_TOKEN
```

Both come from the Cloudflare dashboard under **Calls → TURN**.

Without them, `/api/mac/turn` answers `ok:false` and `TurnClient.fetch()` returns
`nil` — the app falls back to direct peer-to-peer. Same-network and most
home-NAT calls still connect. Symmetric NAT and some corporate networks will not.
**This is a degradation, not an error**, and the app does not currently tell the
person it happened.

### Other secrets, all optional

| Name                  | Turns on                                                        |
| --------------------- | --------------------------------------------------------------- |
| `MAC_DASH_KEY`        | the gate on the telemetry dashboard — **read the warning below** |
| `LOG_ADMIN_TOKEN`     | operator-only reads at `/api/health/rooms` and `/api/health/recent` |
| `LAB_KEY`             | the live-lab channel at `POST /api/room/<code>/lab` (503 when unset) |
| `GEMINI_API_KEY`, `ELEVENLABS_API_KEY`, `ANTHROPIC_API_KEY` | the translation/interpreter paths |

> ### ⚠ Set `MAC_DASH_KEY` before you point a real user at your deployment
>
> The telemetry dashboard lives at `/macos/calls`. Its gate is:
>
> ```ts
> if (!dashKey) return true;   // unset: open, as before
> ```
>
> — `tape-app/src/worker.ts:4650`. **With `MAC_DASH_KEY` unset the dashboard is
> served to anyone who asks.** That is a reasonable default for a private
> workers.dev URL nobody knows and a bad one for anything else. It shows call
> quality records and install ids, not audio, video or room names.

### Things in the Worker that still say `tokkah.com`

These do not stop a deployment working, but you should know they are there:

- `tape-app/src/worker.ts:4541` — the http→https redirect matches only
  `tokkah.com` and `workers.dev`. On a **custom domain** an `http://` request is
  not upgraded by the Worker. Cloudflare's own "Always Use HTTPS" covers this.
- `tape-app/src/worker.ts:4965` — `/mac` is a hardcoded 302 to
  `https://kin.tokkah.com/`.
- `tape-app/public/` — the browser-facing pages (`join.html`, `kin.html`,
  `macos/index.html`, `macos/install.sh`, `macos/join.html`) contain
  `room.tokkah.com` / `kin.tokkah.com` in copy and links. `macos/install.sh`
  honours `TK_INSTALL_BASE`; the HTML does not. Edit them if the pages matter to
  you; the macOS app does not read any of them.

---

## Part 2 — the app

### One flag

```sh
tk --server https://tokkah.<you>.workers.dev
```

`--server` moves **all three** origins Kin uses:

| Origin    | What it is                                          | Default                     |
| --------- | --------------------------------------------------- | --------------------------- |
| `base`    | rendezvous, TURN, telemetry, the handle registry     | `https://room.tokkah.com`   |
| `updates` | the signed release feed (`base` + `/macos`)          | `https://room.tokkah.com/macos` |
| `invite`  | the origin in a link you paste to a friend           | `https://kin.tokkah.com`    |

Ask any build where it is pointed:

```console
$ tk --server-print
base             https://room.tokkah.com
identity         https://room.tokkah.com
rendezvous       https://room.tokkah.com/api/room/<room>/rv
turn             https://room.tokkah.com/api/mac/turn
telemetry-beat   https://room.tokkah.com/api/mac/beat
telemetry-crash  https://room.tokkah.com/api/mac/crash
updates          https://room.tokkah.com/macos
invite           https://kin.tokkah.com/<room>
update-key       built-in d07822ed…
```

Those are read out of the live variables the app is holding, not rebuilt from the
defaults — a report that recomputes what it reports can agree with itself while
both halves are wrong.

### Resolution order, highest first

1. `--server <url>`
2. the per-purpose environment variables that already existed — `TK_KIN_BASE`,
   `TK_UPDATE_BASE`, and `TK_INVITE_BASE` for the invite origin
3. `server.json`, described next
4. the compiled-in defaults

**With none of those set, every origin resolves to exactly the string it resolved
to before any of this existed.** If you are not self-hosting, nothing changed.

### For an app you double-click

A flag is no use to somebody who never opens a terminal, so the answer can be
written down:

```sh
tk --server https://tokkah.<you>.workers.dev --save-server
tk --forget-server        # back to the built-in server
```

`--save-server` writes `server.json` next to `identity.json` in
`~/Library/Application Support/Kin/`. It is small and you can write it by hand:

```json
{ "base": "https://tokkah.you.workers.dev",
  "updates": "https://tokkah.you.workers.dev/macos",
  "invite": "https://tokkah.you.workers.dev" }
```

**There is no `updateKey` field in it, and that is deliberate.** See Part 3.

A bad address is refused at startup rather than becoming a call that connects to
nothing:

```console
$ tk --server kin.example.com
server: --server is "kin.example.com" -- it needs a scheme on the front, like https://kin.example.com
refusing to start against a server address this build cannot use.
$ echo $?
2
```

---

## Part 3 — your own updates, and the key

Kin updates itself. The manifest that describes a release is **Ed25519-signed**,
the public key is compiled into the binary, and an unverifiable manifest is a
no-op. There is no flag that skips the check and there never will be — a security
control with a bypass is decoration.

That has one consequence for you: **your releases are signed by your key, which
the app does not have.** So a copy pointed at your server with no key given
refuses to install anything at all, and says why:

```
update: pointed at https://tokkah.you.workers.dev/macos for updates with no key
to check it against -- this build has only Kin's own update key, which did not
sign that server's releases. Pass --update-key <base64> (or set TK_UPDATE_KEY)
with the public half of the key that signs .../manifest.json. Nothing will be
installed until then.
```

It does not fall back to unsigned, and it does not even fetch the manifest.

### Make a keypair

`mac/tools/sign` signs a file with an Ed25519 private key read as hex from
`~/.config/tokkah/mac-update-ed25519.key`. That path is hardcoded
(`mac/tools/sign.swift:14`), so put your key there or edit the file.

LibreSSL, which is what macOS ships as `openssl`, has no Ed25519. Generate the
pair with CryptoKit instead:

```sh
mkdir -p ~/.config/tokkah
cat > /tmp/genkey.swift <<'SWIFT'
import CryptoKit
import Foundation
let path = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent(".config/tokkah/mac-update-ed25519.key")
// REFUSES TO OVERWRITE, and that is not politeness. Losing the private half of a
// key you have already published releases with is unrecoverable: every copy in
// the field verifies against the old public key and will refuse everything you
// sign from then on. There is no way back from it and no way to notice quickly.
guard !FileManager.default.fileExists(atPath: path.path) else {
  FileHandle.standardError.write(
    "a key already exists at \(path.path) -- refusing to overwrite it\n".data(using: .utf8)!)
  exit(1)
}
let k = Curve25519.Signing.PrivateKey()
try! k.rawRepresentation.map { String(format: "%02x", $0) }.joined()
  .write(to: path, atomically: true, encoding: .utf8)
try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
print("public key (base64): " + k.publicKey.rawRepresentation.base64EncodedString())
SWIFT
swift /tmp/genkey.swift
```

The private half is the whole thing: keep it backed up, keep it out of the repo,
and never regenerate it once you have shipped a release signed with it.

The private half never leaves that file. The public half is what you hand to the
app, in one of two ways:

- **at launch** — `--update-key <base64>`, or `TK_UPDATE_KEY=<base64>`. Base64
  (44 chars) or hex (64 chars); anything else is refused at startup, because a
  key that does not parse must never quietly mean "use the shipped key instead".
- **at build time** — replace `publicKeyHex` at `mac/Sources/tk/Update.swift:23`
  with your own and rebuild. This is the only way a double-clicked app updates
  itself from your server.

### Why the key is not in `server.json`

The compiled-in key is the app's trust root. If a key could come from a file in
`~/Library/Application Support/Kin`, then writing one user-writable file would be
enough to point the updater at an attacker's host with the attacker's key — and
the payload would be installed by Kin's own updater, which re-signs the bundle and
keeps its TCC identity. Overwriting the app bundle directly does **not** get an
attacker that: it changes the ad-hoc cdhash, so macOS treats it as a different
app and asks for the camera and microphone again, which somebody would notice.

So the file may move where updates are *fetched from* — harmless, because a
manifest that cannot be verified is refused — and may not move what *verifies*
them.

### Publish a release

The manifest and its signature are **static assets**, not R2 objects: they live at
`tape-app/public/macos/manifest.json` and `.sig` and go live with
`npx wrangler deploy`. The tarball is an R2 object. `mac/release.sh` does all of
it, and **it will not run unmodified** — it hardcodes `room.tokkah.com`, the
`tokkah-mac` bucket, and `-c wrangler.prod.jsonc`.

The part that matters is the manifest, and the field to watch is `url`:

```json
{"version":"1.0.0",
 "url":"https://tokkah.you.workers.dev/macos/dl/tk-1.0.0.tar.gz",
 "sha256":"…","appName":"Kin","notes":"…"}
```

**`url` is absolute.** The updater downloads from that string, not from `--server`
— so pointing an app at your host is not enough on its own; your manifest has to
name your host too. Then:

```sh
./mac/tools/sign tape-app/public/macos/manifest.json > tape-app/public/macos/manifest.json.sig
npx wrangler r2 object put tokkah-mac/tk-1.0.0.tar.gz --file tk-1.0.0.tar.gz
cd tape-app && npx wrangler deploy
```

The tarball is checked against the manifest's `sha256` after the signature
verifies, so a payload that does not match what was signed is refused too.

---

## Part 4 — what you do not get

This is the part worth reading twice.

**STUN is not yours.** The Worker has no STUN server in it. The Mac app asks
`stun.cloudflare.com`, then `stun.l.google.com:19302`, then
`stun1.l.google.com:19302` (`mac/Sources/tk/Stun.swift:28`). A fully self-hosted
Kin still sends a 20-byte packet to Cloudflare or Google to learn its own public
address. `--stunserver <host>` points it at one server of your choosing for a
single run; there is no persisted setting for it and `Server` does not manage it.

**TURN is Cloudflare's, or nobody's.** `/api/mac/turn` calls
`rtc.live.cloudflare.com`. There is no code path for coturn or any other relay.
Pointing Kin at your own relay means writing that code.

**The update tooling assumes our deployment.** `mac/release.sh` is our release
script, not a general one; see above.

**The web pages are branded.** Everything in `tape-app/public/` says Kin and links
to `tokkah.com`. The AGPL lets you change all of it; nothing changes it for you.

**A self-hosted app is not a private one by default.** Telemetry follows
`--server`, so beats and crash reports go to *your* Worker rather than ours —
which is the right default, but it means you are now the one holding them. Turn
it off entirely with `--no-telemetry`.

**Your handle is per-server.** Handles are claimed against `base` and bound to a
device key on first claim. Move servers and you are a stranger there; your
`identity.json` handle is not portable and there is no migration path.

---

## Appendix — proving it, without trusting this document

**The default did not move.** With no flag, no environment variable and no file,
every origin must still be the string that was compiled in at `0.69.0`:

```sh
env -i .build/debug/tk --server-print
```

Compare against the literals as they were, straight out of git:

```sh
git show 13b85b3:mac/Sources/tk/Identity.swift  | grep -n 'room.tokkah.com'
git show 13b85b3:mac/Sources/tk/Telemetry.swift | grep -n 'room.tokkah.com'
git show 13b85b3:mac/Sources/tk/Update.swift    | grep -n 'room.tokkah.com'
git show 13b85b3:mac/Sources/tk/main.swift      | grep -n 'kin.tokkah.com'
```

**The override actually moves the app.** Run something that records requests and
point Kin at it — the app's own log is not evidence that it went there:

```sh
python3 -m http.server 8391 &
tk --server http://127.0.0.1:8391 --room proof --mute
```

You will see `/api/room/proof/rv` and `/api/mac/turn` arrive, and you will see
**no** request for `/macos/manifest.json` — that is the update gate refusing to
fetch what it could not check.

**The signature gate still bites.** Serve a manifest signed with one key and start
the app with a different one; `update: manifest signature INVALID -- ignoring`
is the gate working, and nothing downstream of it runs.
