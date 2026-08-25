# Tap a name to call — design (2026-08-24)

**"nothing implemented yet" is no longer true.** Shipped server-side as of
0.48.0: the doorbell (`register` / `ring` / `poll`, proof-of-possession) and
`quiet` (silent mode, contract below). The **client** half — `Identity.swift`,
the signed handshake, the handle ladder, the contacts panel — is still unbuilt,
and everything below the CORRECTIONS block was written before any of it existed.

Goal: after one call, call that person again by tapping their name. See memory
call-people-not-rooms. Anchors: mac/Sources/tk/*, tape-app/src/worker.ts.

## CORRECTIONS — read before implementing anything below (2026-08-24)

### Error 0 — the rotating 300 s rendezvous room guarantees a COLD room on every call

Measured: a room whose durable object has never been touched costs **1108 ms** on its
first request (median, n=27, range 883-2604). The epoch scheme below derives a new room
name every 300 seconds, so almost every call lands on a room nobody has warmed — the
design pays that 1108 ms **by construction**, on the one path that is supposed to feel
instant.

Worse, the fix has existed and been deployed for months and this app has never used it:
`GET /api/room/<code>/warm` pre-creates the object. The web client fires it and records
the same measurement in its own comment (`app.js:8386` — "the FIRST joiner's ws-open was
~1.1 s against ~0.3 s for the second"). `grep -rn "/warm" mac/Sources/tk` returns nothing.

**Two fixes, and take both:**

1. **Fire `/warm` the moment the room name is known**, on every path — typed room, link
   join, and contact call alike. This is worth ~1100 ms today, before any of the handle
   work exists, and costs about ten lines with no deploy.
2. **Drop the epoch entirely.** It was there so an observer could not link two calls
   between the same pair, but the caller now sends the room name inside the ring, so it
   never needs to be *derivable* by the callee at all. Let the caller mint a fresh random
   room per call and warm it while the callee's phone is still ringing. That is strictly
   better than the epoch on every axis: unlinkable (a new name each time, not one per
   300 s window), no clock-skew window to reason about, no epoch±1 fallback, and warm by
   the time it is used.

Consequence to keep in mind: warming is a stateful hop and costs ~127 ms itself, so fire
it concurrently with the ring rather than before it.


The body of this file was written before the code was checked line by line. Three
things in it are wrong, and two of them produce a feature that appears to work on
the first call and then fails silently forever. Fix these first.

### Error A — the pair key must NOT come from `Crypto`'s shared secret

The body writes `PS = HKDF(sharedSecret, …)`. The only `sharedSecret` in the code
is the **ephemeral** one at `Crypto.swift:104`; `mine` is a fresh
`Curve25519.KeyAgreement.PrivateKey()` per process (`Crypto.swift:41`). Deriving
PS from it makes PS different on every call.

Failure mode, and it is the nasty kind: pairing on call 1 works, and every later
call silently falls back to a room-name salt while the UI still claims a verified
contact. No error, no log line.

**PS must come from a second agreement: `devicePriv × peerDevicePub`.** A new
`sharedSecretFromKeyAgreement` call, not a reuse of `Crypto`'s.

### Error B — "nothing new on the wire" is false

`Wire.sendHandshake` (`Net.swift:334-344`) sends exactly
`HMAGIC(4) | ephemeralPub(32) | caps(4)` = `HPKTX` = 40 bytes. The **device**
public key is on the wire nowhere. Carrying it means extending that packet.

Do it in the existing idiom, which is already length-tolerant: `Net.swift:35`
defines `HPKTX = HPKT + 4` and the receiver tests `n >= HPKT` then `n >= HPKTX`
(`Net.swift:935`, `:937`), so an older build reads its 40 bytes unchanged. Add
`HPKTY = HPKTX + 32`, append `devicePub` after the caps store at `:341-343`, and
add a third `if Int(n) >= HPKTY` arm at `:937-943` handing the 32 bytes to an
`onPeerDevice` callback.

Keep it **out of** the `adoptPeer` reply gate at `Net.swift:958-962`. That gate
exists to stop the reply storm documented at `:945-952`; a device-key arrival
must never be able to provoke a handshake.

This is the riskiest change in v1: the only always-plaintext packet on the media
socket, parsed on the hot receive loop from raw pointer arithmetic, and it must
stay compatible across two builds that may be up to 60 s apart in version. All
three of its failure modes are quiet — a length check off by one is an overread on
a network-controlled buffer.

### Error C — do not put PS in argv, and do not change `Crypto(roomSalt:)`

`Update.commit` re-execs `CommandLine.arguments` verbatim (`Update.swift:438`,
`:485`) and argv is visible to `ps`. Re-exec with `--contact <handle>` instead and
resolve the salt from `contacts.json` in-process at `main.swift:1430`, which
already reads `arg("secret") ?? arg("room") ?? ""`. `Crypto.swift:99-157` is then
untouched — `salt` is only read at `:109` and `:111`, so a different salt changes
the HKDF inputs and nothing else. Cipher path unchanged: verified.

Corollary the body gets right and is worth doing early: compute `safetyCode` over
the two **device** keys and it becomes stable across every call with that person,
closing the gap admitted at `Crypto.swift:34-36`. Small diff, visible win, and it
is the cheapest possible proof that PS really is shared and stable.

### Keychain: still no, and the reason has changed

Measured on this Mac today: `/Applications/Kin.app` at 0.46.0 is
`flags=0x2(adhoc)`, `designated => cdhash H"fbfe9c05…"`. The prod 0.46.0 payload
**is** certificate-signed (`identifier "com.tokkah.tk" and certificate root =
H"ef8e905f…"`), but this copy arrived as an update from 0.45.0 and came through
the legacy ad-hoc path (`Update.swift:450-490`, resign at `:232`/`:474`).
Certificate identity therefore arrives on the **next** release for updated copies,
and immediately for a fresh `install.sh`/DMG. See `updater-ships-only-what-it-can-install`.

So Keychain items written today would become unreadable the moment the next
release swaps the bundle — the contact list would silently empty **once, for the
entire installed base, on the release that "fixes" identity**, with no rollback.
Also: the read happens on a background poll thread, where a failed ACL match
either returns `errSecInteractionNotAllowed` or raises a modal with no window
behind it — the least observable place in the program.

**File for v1 and v2.** `0600` JSON at
`~/Library/Application Support/Kin/contacts.json`, staged-then-swapped like
`Update.swift:176-231` (a torn contacts.json loses every pair key). Revisit at v3,
and the gate is not "Developer ID" — it is "every install is past the certificate
transition **and** the signing p12 is escrowed". Recorded so it is not re-derived.

### Anchors

`main.swift` numbers in the body are stale — the launch-speed lane is editing that
file now. Re-resolve **by symbol** at apply time. Corrections to the rest:
safety-code hint `Controls.swift:1567` (not 1569); `WaitingCard`
`Controls.swift:843` (not 829); telemetry POST `Telemetry.swift:75` (not 68);
room-seen stamp `worker.ts:2503-2509`, and it is **already** gated on
`m[2] === 'ws' && upgrade === 'websocket'`, so `/rv` never stamps it — that
requirement is satisfied structurally.

### Two server traps

`Room.fetch` (`worker.ts:225-236`) dispatches on `endsWith` and then falls through
to `this.signal(request)` at `:235`, which returns **426 "expected websocket"** for
anything without an upgrade header. New handlers must join the dispatch list at
`:230-234`, beside `/rv`. Add them after that fallthrough and the whole feature is
inert behind a plausible-looking log.

And the ring must reject `|t| > 60 s` skew **before** checking any signature, or a
captured ring replays forever.

Do not reuse `macPosts` (`worker.ts:1645`) for ring rate limits — telemetry beats
and rings would share one 5000/h budget. Sibling map, same shape.

### One decision that is the user's, not mine

The body proposes landing on the launch window when contacts exist. That reverses
a decision the user stated directly and which `Launcher.swift:27-41` exists to
defend — *"whenever you hit the site, the meeting starts"* — and it spends the
cold-launch budget the launch lane is earning right now (`instant-everywhere`).

**Do not ship it without asking.** Everything else in v1 ships without it: a
contact tap can arrive from a menu item or from `--gui`, and v1 is fully testable
that way. Ask once, after steps 1-6 below are working and there is something real
to look at.

### Build order — each step independently shippable

0. Prerequisite: the launch lane's background-STUN/TURN and poll-backoff changes
   land. Do not touch the rendezvous poll loop before then.
1. `Identity.swift` + `contacts.json`. No UI, no wire, no server. Ships dark.
2. Server routes. Ships alone with nothing calling them; verify by fetching prod,
   and deploy with `-c wrangler.prod.jsonc`.
3. Handshake extension + PS derivation. Old build ↔ new build must be unaffected.
4. Stable safety code over device keys. Cheapest proof step 3 worked.
5. Derived rotating room + ring POST + naming sheet. Contact calls work manually.
6. Inbox poll + incoming-call window. Works with the app open but not waiting.
7. Login item — **and the `LSUIElement`/status-item question must be answered
   first.** `SMAppService.mainApp.register()` with `LSUIElement` unset and
   `.regular` activation means every login opens a Dock icon, a window, and steals
   focus. That is worse than no feature, and it is the largest piece of unbuilt
   scope the phrase "login item" hides.
8. Launch-window landing — only after the user says yes.

## SHIPPED SERVER ROUTE — `quiet` (silent mode), 2026-08-24

Implemented, `tsc` clean, `npm test` exit 0 with two hand-run mutations (23 and 14
failures across disjoint guards). **Verified deployed to prod as part of 0.48.0** —
check `/api/kin/<handle>/quiet` before assuming, per `verify-deploy-by-parsing-prod`.

`POST /api/kin/{handle}/quiet` — POST only (405 otherwise), body cap 512 bytes.
Body is a JSON object with **exactly these six keys**; a seventh drops the request.

| field | type | rule |
|---|---|---|
| `to` | String | equals the path handle, `^[a-z][a-z0-9]{1,31}$` |
| `k` | String | base64 of the 32-byte Ed25519 **device** public key |
| `t` | Int | unix **seconds**, JSON integer, abs(now - t) <= 60 |
| `sig` | String | base64 of the 64-byte Ed25519 signature |
| `quiet` | Bool | true silences, false lifts |
| `until` | Int | unix seconds deadline, or `0` = indefinite. If non-zero: `until > t` and `until - t <= 315_360_000` |

Signed string (UTF-8, **its own domain** — never reuse the register context):

    "kin-quiet-v1|" + to + "|" + quiet + "|" + until + "|" + t
    kin-quiet-v1|devesh|true|1800003600|1800000000

`quiet` renders lowercase `true`/`false` (Swift's `String(Bool)` agrees). **Encode
`until` and `t` as `Int`, never `Double`** — `"\(0.0)"` is `"0.0"`, which verifies
on the device and never on the server. Base64 lengths are exact: 64 bytes -> 86
chars + `==` = 88; 32 bytes -> 43 + `=` = 44. Url-safe/unpadded spellings are
accepted and canonicalised. Signed with the same device key that registered the
handle, verified against the **stored** key.

Responses: `200 {"ok":true,"quiet":Bool,"until":Int,"exceptKnown":false}` (`quiet`
is the read-time verdict) - `400` (`bad handle|bad json|bad body|bad fields|to
mismatch|bad k|bad quiet|bad t|bad until|bad sig`, or `{"error":"skew","skewS":N}`)
- **`401 {"error":"no"}` for all three ways of not being the owner** (unclaimed
handle, wrong key, bad signature) - `405` - `413` - `429 {"error":"rate"}`.

Rate: 6/min per handle owner-keyed, 30/min non-owner in its **own** window so a
stranger cannot lock the owner out of their own toggle, 120/h per IP at the edge.

Poll gains one additive, always-present field:

    "quiet":{"on":false,"until":0,"exceptKnown":false,"dropped":0}

**The client must believe `on`, not `until`** — an expired deadline reports
`on:false` while the stored row still says `quiet:true`.

### The invariant, and what it costs

Silence is indistinguishable from away. A silenced ring travels the **entire**
normal path — all validation, all four rate windows, the same `kinBoxPut`, one
shared response line — and is dropped when the mailbox drains. Discarding at the
door was the first mutation: `queued` stops tracking the mailbox and the toggle
becomes legible after two doorbell presses. Ring's response is byte-identical
silent or not: `{"ok":true,"queued":N,"evicted":N,"leaseMs":60000}`.

Deliberate costs, all of them the price of the invariant: a silenced ring holds a
mailbox slot for its 60 s lease (bounded at 8, evict-oldest, so a real ring after
the toggle lifts still lands), and **silenced rings still spend the callee's
12/min and 60/h budget** — not charging would make silence legible.

Consequence for the brief: "the caller stops waiting sooner" is **incompatible**
with this and was not built. Anything that shortens the caller's wait is a signal.
All the savings are on the callee's side.

### Two traps recorded so nobody repays them

1. **A string `export` from `worker.ts` breaks the deploy.** It is the entry
   module, so every named export is an entrypoint. RegExps and Sets survive
   (objects); primitives do not — workerd refuses to start with *"the provided
   value is not of type 'function or ExportedHandler'"* while `tsc` passes. Both
   signing contexts are unexported, with a `(j4)` guard that no top-level string
   constant is exported at all.
2. **`Number.isInteger(1e21)` is `true`.** On `t` it is the *skew* gate that
   catches `"1e+21"`, not the integer check. `until` has no skew gate, so the
   ~10-year horizon is the only thing standing there — that constant is
   load-bearing, not hygiene.

`exceptKnown` is stored, always `false`, no wire field. When it gains one it
**must** join the signed string and the context must become `kin-quiet-v2`, or a
captured signature flips it.


## Constraints found in the code (not guesses)

- The Mac app has NO websocket. Rendezvous is a 1 Hz HTTP GET poll:
  Rendezvous.exchange (Stun.swift:173-211) against /api/room/<room>/rv, driven by
  main.swift:698-701. The web app's 37-dead-socket saga does not apply here.
- The room name IS the crypto salt: Crypto.init(roomSalt:) -> "tk-v1-"+salt into HKDF
  (Crypto.swift:92-94); :88-91 says it is the only thing not on the wire.
- The X25519 key is fresh per PROCESS (Crypto.swift:41), so safetyCode (:79-86) differs
  every call and is therefore UNCHECKABLE. Crypto.swift:34-36 names the gap: fixing it
  needs identity that outlives a call, which does not exist yet.
- Persisted today: tk.lastRoom (Launcher.swift:21), tk.recentRooms (:165), tk.installId
  (Telemetry.swift:28), tk.cameraId (Video.swift:160).
- CFBundleIdentifier stays com.tokkah.tk across the Kin rename (Info.plist:7) so the
  defaults domain survives; the BUNDLE does not (updater replaces + re-signs it,
  Update.swift:178-192/:354, and may move/rename it :481-513).
- Server: Room DO rendezvous() is memory-only, 90 s lease (worker.ts:254-283); edge regex
  :2496; /api/* 404s at :2519; per-IP hourly buckets exist at :2362-2375; the Health DO
  strips room/secret/peer from every beat (:1837).

## 1. Identity — a second, long-lived X25519 keypair per install

handle = base32(SHA256("tk-id-v1" | devicePub))[0..25]   (128 bits)

NOT tk.installId — that is a telemetry id already POSTed with model/version/call stats
(Telemetry.swift:68, stored worker.ts:1839-1844); making it the callable address welds the
contact graph to the telemetry table. NOT the existing Crypto key — ephemeral by design.

Bonus, and it is the point: compute safetyCode over the two DEVICE keys and it becomes the
SAME string on every call with that person, forever — so the app can check it itself. That
closes the gap admitted at Crypto.swift:34-36. Per-call ephemeral keys stay for forward secrecy.

Survives updates + the rename (lives outside the bundle; defaults domain pinned). Reinstall =
new handle, peer's stored row is dead; do not migrate, do not escrow. Add handle/contact/pair
to the beat strip-list at worker.ts:1837.

## 2. Naming — local only in v1

A name over the wire is a claim (needs trust model + conflict UI); a name you typed needs
neither. Sheet after the first call with an unknown device: "Who was that?" / placeholder
"Their name" / Save · Not now / hint "Saved on this Mac only. Next time you can just tap their
name." Row actions: Rename, Remove. v2: each side may SUGGEST its display name over the
encrypted channel (one new magic beside HMAGIC/KMAGIC, Net.swift:26-45); local label stays
authoritative.

## 3. Pair key — derived on the first call, replaces the room name

PS = HKDF(sharedSecret, salt:"tk-pair-v1", info: sorted(devicePubA|devicePubB), 32 B)
Both ends compute it independently. NOTHING NEW ON THE WIRE.
Later calls: Crypto(roomSalt: base64(PS)) — one line at the call site, zero change to the
cipher path (Crypto.swift:92-94, 99-119). The out-of-band secret becomes 256 machine bits
instead of a human phrase: stronger, not weaker.

Rendezvous room, also derived, so no new rendezvous route is needed:
  epoch = floor(unix/300)
  room  = base32(SHA256("tk-rv-v1" | PS | epoch))[0..20]     (matches ROOM_RE, worker.ts:1602)
Try epoch and epoch±1. Rotating means the pair has no permanent public identifier.

STORAGE: ~/Library/Application Support/Kin/contacts.json, file 0600, dir 0700.
NOT Keychain: ACLs pin to the designated requirement, and Update.swift:186 ad-hoc re-signs
every update so the DR's cdhash changes every release (and the bundle can move, :481-513) —
items written by version N would prompt or fail on N+1. Keychain becomes right once a stable
DR exists (v3). NOT UserDefaults: that plist is 0644, cfprefsd-cached, and swept by backup/sync.

safetyCode on later calls: stable, so the app compares and says so. Update the hint at
Controls.swift:1569.

## 4. Presence + ringing — no APNs (no Developer ID, see no-notarization-budget)

(a) login item + websocket — first ws client in Swift; would have to replicate 25 s ping/pong
    (worker.ts:732-740), ghost eviction on silence not readyState (:180-189, :588-608),
    LEAVE_GRACE_MS 5000 (:75, :837-841). Days of work + a new failure class.
(b) always-running helper — two release cycles to install (updater ships only what it can
    install) AND a second copy of every pair key. Rejected for v1.
(c) POLL a per-identity mailbox — reuses machinery that already works; the app IS a polling
    client (Stun.swift:173-211). One small GET per 5 s.
(d) reachable only while the app is open — free, not what was asked.

V1 = (c), degrading to (d). Ring payload is trivial: "someone wants you at rendezvous room R."
Caller starts publishing to R immediately (main.swift:698-760 unchanged); callee joins R and
existing rendezvous does the rest. NO NEW MEDIA PATH.
V2 = long-poll (DO holds the GET up to 25 s): ~0 ring latency, 5x fewer requests, SAME client
code. V3 = websocket only if long-poll measurably is not enough.
Note LSUIElement is unset and Menu.swift builds only the main menu bar — no NSStatusBar item yet.

## 5. Server — reuse the Room DO under a namespaced name

env.ROOM.idFromName("inbox:"+handle). New edge block BEFORE the /api/ 404 at worker.ts:2519:
  POST /api/kin/ring   {to,from,room,t,sig}
  GET  /api/kin/inbox?to=&t=&tok=
Mailbox mirrors rvPeers (worker.ts:254-283): in-memory Map, 60 s lease, max 8 per handle. A
ring is only true while the caller is still waiting, so persisting it would be worse than
persisting nothing (same argument as :249-253).

AUTH — the pair key is the credential and NEVER reaches the server:
  sig = HMAC-SHA256(PS, "ring|"+to+"|"+from+"|"+room+"|"+t)
The server CANNOT verify it (it has no PS) — correct: it only rate-limits and delivers. The
CALLEE verifies each ring against every stored contact's PS; a ring matching none is dropped
silently and counted. So a stranger who guesses a handle can write to a mailbox and can NEVER
make a Mac ring. Poll credential is separate (the poller does not yet know who is calling):
tok = SHA256("tk-inbox-v1" | devicePriv), first-writer-wins in DO storage — the only durable
state this design adds.
Rate limits: copy the /api/mac/beat per-IP bucket (:2362-2375), plus in-DO <=6 rings/min per
(from,to), <=30/min per `to` from any source (a leaked handle must not become a doorbell DoS),
<=1 poll per 2 s per handle. Inbox routes must NOT stamp the room-seen registry (:2502-2507).

## 6. UI

Home = the launch window (Launcher.askRoom(), Launcher.swift:187-414) — today off the default
path: shouldPrompt returns forced only (:42-44) and a double-click mints a room and dives into
a call (main.swift:194-202). PROPOSED: land on the launch window when contacts exist, keep
diving straight in when there are none. THIS REVERSES a deliberate decision (main.swift:186-202,
Launcher.swift:27-41) — user decision required.
Keep the camera preview (:215-290): it answers the permission prompt before a call. Replace the
inline Recent row (:376-394) with the contact list.
Rows = SheetRow (Controls.swift:567): glyph + text + right-aligned value, hover/press, a hitTest
that works (:609), acceptsFirstMouse (:602), and a `spoken` string (:582) — needed because the
harness must CLICK the list and read it back.
Tap = call now: derive the room, POST the ring, publish to /rv, show WaitingCard
(Controls.swift:829-928) with "Calling Meera…" instead of the link copy. Below the list, one row:
"Call someone new" -> today's room field.
Incoming call = a WINDOW, not a notification (a notification that gets Do-Not-Disturbed is a
missed call): full-window wash, "Meera is calling", Answer (filled) / Not now (glass), from the
existing IconButton/Glass idiom (:271). Ring tone via NSSound, deliberately NOT through the call
audio graph (a hardcoded rate went silently deaf once already).
Copy: section "People"; empty "Call someone once and they'll show up here."; "Calling Meera…" ->
"No answer. They may not be at their Mac."; dead contact "Meera got a new setup. Call her the old
way once and this will work again." + Remove; verification row hint "Same code as last time —
this is the same person." and on mismatch "This code changed. That shouldn't happen — check with
them before you talk."

## 7. Privacy / abuse

Only someone holding PS can make you ring, and PS only comes from having called together. A
handle alone gets into a mailbox, never onto a screen. Removing a contact deletes PS = a
permanent block enforced on the device, nothing told to the server.
WHAT THE SERVER LEARNS, plainly: opaque 128-bit handles, which handle rang which, and when — a
pseudonymous contact graph plus call timing. That is MORE than today (room names + IPs, no
durable identity). Mitigations: rendezvous room rotates per 5-min epoch; mailbox memory-only,
60 s lease; only durable row is the inbox-token registration; room-seen never fires for inbox
routes; handles never appear in a beat.
MEDIA PATH UNCHANGED: the ring carries a room name and nothing else; media still LAN/STUN/TURN
as main.swift:697-760, still end-to-end encrypted, server never holds PS.

## 8. Phases

V1 (days): device keypair; contacts.json 0600; pair key on first call; derived rotating
rendezvous room; local naming sheet; contact list in the launch window; 5 s inbox poll;
incoming-call window; login item.
  Acceptance (LIVE PROD, no harness verdict): two Macs; first call by typed room name; quit and
  reopen both; tapping the name on A rings B within 6 s and connects; safetyCode byte-identical
  to the first call; delete the contact on B and A's next ring produces NOTHING on B's screen.
V2: long-poll; presence dot; name suggestion over the encrypted channel; missed-call row.
  Acceptance: ring-to-screen p95 < 1.5 s over the Delhi<->NL pair, 20 rings.
V3: multiple devices per person; Keychain once a Developer ID gives a stable DR; MITM closed
properly — pin the device key at first contact and REFUSE a change rather than warn.
  Acceptance: a deliberately substituted device key is refused, not warned about.

## Decided without asking (defaults chosen 2026-08-24)

- Accept the pseudonymous contact graph for v1, with the mitigations above.
- 5 s poll for v1, long-poll in v2.
- Reinstall loses contacts both ways; a user-exportable backup is v2, not v1.
- Names local-only in v1.
- ~/Library/Application Support/Kin/ even though the bundle id stays com.tokkah.tk.
