# Security

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report it through **[GitHub's private vulnerability
reporting](https://github.com/deshmukhpatel98/tokkah/security/advisories/new)** —
it opens a private thread visible only to you and the maintainer.

If that form is not accepting reports, open a **public issue containing no
details** — just "security issue, please make contact" — and you will be
contacted privately to take it from there. Do not put the vulnerability in that
issue.

### What to expect

This is a single-maintainer project ([GOVERNANCE.md](GOVERNANCE.md)), so the
honest version rather than a service-level agreement:

| | |
|---|---|
| First human reply | within **7 days**. If you have not heard back by then, assume it did not arrive and ping the public issue. |
| Assessment of whether it is real | within **14 days** of that first reply |
| Fix for something remotely exploitable | as fast as one person can, and shipped through the normal signed release channel |
| Credit | you will be credited in [CHANGELOG.md](CHANGELOG.md) unless you ask not to be |
| Bounty | **none.** There is no money in this project and no bug-bounty programme. |

There is no embargo policy beyond common sense: tell us, give us a reasonable
window to ship a fix, and publish whatever you like afterwards.

### What is in scope

The app (`mac/`), the Worker (`tape-app/src/`), the update channel, and the
signing and rendezvous design. Reports about the retired browser client in
`tape-app/public/` are still welcome but are lower priority — see
[the note on the posture section below](#a-note-on-what-follows).

Out of scope: anything requiring physical access to an unlocked Mac; the
one-time Gatekeeper prompt (there is no Apple Developer ID, by decision — see
the README); and the one residual named at the top of
[`mac/Sources/tk/Crypto.swift`](mac/Sources/tk/Crypto.swift) -- a first call
between two strangers through a server that also lies about their keys -- which
is documented, visible in the safety code, and closed by the pin after that call.

---

## A note on what follows

Everything below was measured on **the browser product**, on 2026-08-02, and has
not been re-measured since the project became a native macOS app. It is kept
because it is accurate about the browser client, which is still in the
repository, and because its final section is a list of things that are *not* yet
true — a security document that only lists strengths is marketing.

**The Mac and Android apps have a different trust model and it is documented in
the source rather than here.** Since Kin 0.128.0 / 0.128.0-android.19:

- **X25519 + AES-256-GCM per packet over raw UDP, two keys (one per direction),
  a sliding replay window** of 2048 packets. Nothing is read or written before a
  key exists: there is no plaintext window.
- **The handshake is signed by each install's Ed25519 device key** -- the same
  key that already signs and verifies every ring -- over a message that names the
  room. A handshake is refused unless the signature verifies, AND the identity is
  the one this end expected: the key that signed the ring (callee), the key the
  server bound the handle to at registration and returns with the ring (caller),
  or the key pinned in `contacts.json` from a previous call. With no expectation
  (an invite link, a first call to a stranger) the first identity is pinned for
  the call, and remembered under the handle once the call is answered.
- **What the signalling server can and cannot do.** It still sees who calls whom
  and when. It can no longer read or alter a call, and it can no longer sit in
  the middle of one between two people who have called each other before, or of
  a Kin-to-Kin call at all unless it also lied about the callee's key on the very
  first call -- in which case the two eight-character codes differ, and the pin
  written after that call makes it a one-shot. The precise statement, including
  every counter the beat carries for a refused handshake, is at the top of
  [`mac/Sources/tk/Crypto.swift`](mac/Sources/tk/Crypto.swift); the Android port
  is [`android/app/src/main/java/com/tokkah/kin/net/Crypto.kt`](android/app/src/main/java/com/tokkah/kin/net/Crypto.kt)
  and is held to the Mac's own vectors.
- **Bounds and overflow checks are on** (`-O`, since 0.129.0), and the parsers a
  stranger reaches before any key exists are fuzzed in-process by
  `tk --fuzz-parsers`; the ones a peer reaches after the key are fuzzed by a
  hostile-peer mode, `tk --fuzz-send`, on a live socket.
- **Measured, not asserted:** `tk --selftest-crypto` (18 arms, including the
  inputs that must be refused) and [`mac/tools/crypto-check.sh`](mac/tools/crypto-check.sh),
  which runs two real processes and proves an end that expects a different
  identity never keys, seals nothing and sends nothing, and that a build still
  sending the unsigned 0.127 handshake is refused and named as old.

---

# Security posture (browser client) — measured, not asserted

Everything below was read off a live production call or the live production
response headers on 2026-08-02.

## Measured on a live call

| property | observed |
|---|---|
| DTLS state | `connected` |
| DTLS version | `FEFC` = DTLS 1.2 |
| DTLS cipher | `TLS_AES_128_GCM_SHA256` |
| SRTP cipher | `SRTP_AES128_CM_HMAC_SHA1_80` |
| certificate fingerprints | `sha-256`, **distinct per peer** (a real two-party handshake) |
| selected candidate | `host` / UDP — **peer-to-peer, no media server** |
| encryption code | 8 chars, **identical on both peers**, covers all DTLS associations |

## Production response headers

```
content-security-policy: default-src 'self'; script-src 'self'; style-src 'unsafe-inline';
  img-src 'self' data:; connect-src 'self' wss://room.tokkah.com ws://room.tokkah.com;
  media-src 'self' blob:; worker-src 'self' blob:; font-src 'self'; object-src 'none';
  base-uri 'none'; form-action 'self'; frame-ancestors 'none'
strict-transport-security: max-age=31536000; includeSubDomains; preload
cross-origin-opener-policy: same-origin
cross-origin-embedder-policy: require-corp
x-content-type-options: nosniff
x-frame-options: DENY
referrer-policy: strict-origin-when-cross-origin
```

Room identifiers are **128 bits** from `crypto.getRandomValues`, base64url encoded
(`mintRoom()`), so a link is not guessable and the room is the capability.

## The structural advantage over an SFU, and its exact limit

Zoom and Google Meet are SFU architectures. Media arrives at their server, is
**decrypted there**, and is re-encrypted onward. That server is a point at which
plaintext media exists, by design. Zoom offers an opt-in E2EE mode; Google Meet's
default is transport encryption to Google.

This app is peer-to-peer with DTLS-SRTP, so **there is no such point**. Two
properties follow, and both survive scrutiny:

1. **Both custom lanes stay inside that encryption.** The video lane's
   `RTCRtpScriptTransform` substitutes payload bytes *before* packetization and
   SRTP, so substituted frames get identical SRTP protection to ordinary ones.
   The lossless audio lane rides SCTP data channels, which are carried over the
   same DTLS association. Neither lane is a plaintext side channel.
2. **Even the TURN fallback cannot read the media.** A TURN server forwards
   packets; it does not terminate DTLS. So on a relayed call Cloudflare relays
   ciphertext it has no key for. This is categorically different from an SFU,
   which must decrypt in order to do its job.

## The signalling server, and the encryption code that answers it

**The signalling server is trusted for key exchange.** DTLS-SRTP authenticates
the peer against a certificate fingerprint exchanged **through our own signalling
channel**. A malicious or compromised signalling server could substitute its own
fingerprints and machine-in-the-middle the call. This is the standard WebRTC
trust model, not a bug unique to this app.

**This is now detectable.** Every call shows an eight-character *encryption code*
under the more sheet, derived as:

```
SHA-256( sorted( "sha-256 <fpA>", "sha-256 <fpB>" ) )  ->  first 8 x 5 bits
                                                       ->  32-char alphabet (no 0/O/1/I)
```

Sorting is what makes it symmetric: each side sees the pair in the opposite order
(my local certificate is your remote one), so sorting before hashing is what makes
the two independently-computed codes equal. If both people see the same code, no
key was substituted. 40 bits — an attacker cannot grind a colliding certificate
pair inside a live handshake.

**One certificate covers the whole call.** By default each `RTCPeerConnection`
mints its own, which at `pcmpairs=3` would mean four independent DTLS identities
and a code that said nothing about the three audio stripes. One certificate is
generated at page parse and passed to the main pc and every stripe, so the code
covers every association. Verified live: `mismatch=0` on both peers, every arm.

Measured on production, 2026-08-02:

| check | result |
|---|---|
| both peers compute the same code | **yes**, Chromium↔Chromium and WebKit↔Chromium, both join orders |
| code differs between calls | yes (`5UXK CNKP` / `GW8R VE8L`) |
| stripes share the main identity | yes — `mismatch=0`, `allShare=true` |
| certificate generation cost | **0.1 ms** median (800 ms deadline never reached) |
| join time | 705 ms median — no regression |

What this does **not** do: it is a manual check. Two people who never read the
code aloud get no protection from it, and the app cannot tell whether they did.
So the honest phrasing is that a substituted key is now **detectable by the
users**, not that it is prevented. That is the same guarantee Zoom's E2EE security
code gives, and it is the strongest one available without a pre-shared secret or
a key-transparency log.

Auditable in the console rather than asserted here: `__tape.safetyCode()`,
`__tape.security`, `__tape.certAudit()`.

## Remaining findings

- **Cloudflare injects scripts we did not ask for. One of the two is now off.**
  Our `index.html` contains exactly one `<script>`; the edge served three. An
  earlier version of this document called them one finding — "the beacon plus an
  inline snippet" — which was wrong, and the error mattered: they are two
  unrelated products with two separate switches, so turning off the one everybody
  names would have left an inline script still being injected and looked like a
  failed fix.
  - *Web Analytics beacon* — `static.cloudflareinsights.com/beacon.min.js`,
    carrying `data-cf-beacon` site token `be462a71…`. **Switched off 2026-08-03**
    by disabling the RUM ruleset on the zone (`PUT rum/site_info`,
    `ruleset.enabled=false`), which stops injection without deleting the site, so
    historical analytics data survives. Note the API refuses `auto_install=false`
    outright on a proxied zone (`autoInstallRequired`) — the ruleset flag is the
    non-destructive lever, and it takes ~2 min to reach the edge.
  - *Bot JavaScript Detections* — an inline script that builds a hidden 1×1
    iframe to load `/cdn-cgi/challenge-platform/scripts/jsd/main.js`. **Still
    injected.** It is Enterprise Bot Management, off at Security → Bots →
    Configure → JavaScript Detections, and needs a token with Zone → Bot
    Management → Edit, which we do not currently hold.

  **The CSP blocks what remains** — `script-src-elem <- inline`, confirmed by
  `securitypolicyviolation` on a live call, so nothing executes. Measure the cost
  before repeating it: `script-src` blocks the element *before* the fetch, so a
  blocked script costs **no network request at all**. A real browser load makes 12
  requests, every one of them ours, and none to `/cdn-cgi/challenge-platform/`
  (nor, while it was still injected, to `static.cloudflareinsights.com`). The only
  cost is bytes — the snippet is 938 raw, **434 gzipped on the wire**, against a
  13 kB page. That is not a latency problem and should not be sold as one.

  The reason to switch it off is therefore the privacy claim, not performance: a
  browser-fingerprinting script on a product sold as the most private way to make
  a call is wrong even when it is inert, and the CSP is the only thing keeping it
  inert. Loosen `script-src` once — an `'unsafe-inline'` added for some widget —
  and it silently begins running, with nothing to warn you.

  **Do not "fix" this with `Cache-Control: no-transform`.** It is Cloudflare's
  documented opt-out from edge HTML rewriting and it does work — deployed and
  measured on 2026-08-03, both injected scripts disappeared. But the edge counts
  compression as a transform too: gzip vanished and the page went 13,423 → 41,776
  wire bytes, 3.1×, for every visitor. Spending 28 kB a load to suppress a script
  the CSP already blocks is the wrong trade. Reverted; see the comment in
  `tape-app/src/worker.ts`.

  Beware the measurement itself: a bare `curl | grep` does **not** reproduce the
  beacon. It is injected only when the request carries `Accept: text/html`, so
  without that header the page looks clean and you will conclude it is already
  fixed. `testbed/csp-check.mjs` drives a real browser and is the verdict.
- `style-src 'unsafe-inline'` weakens the CSP against injected styles. Low
  severity given `script-src 'self'`, but it is not nothing.

Also not done: no third-party security audit and no penetration test. The Mac
app's parsers are fuzzed by two harnesses built into the binary
(`tk --fuzz-parsers`, `tk --fuzz-send`; see `mac/tools/fuzz-check.sh` and the
0.129.0 changelog for the three findings they produced on their first run); the
retired browser client's FEC and reassembly code was never fuzzed.
