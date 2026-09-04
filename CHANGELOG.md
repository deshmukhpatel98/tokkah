# Changelog

Notable changes to Kin, and to the Tokkah worker behind it. Dates are the day
the change landed on `main`.

This project measures its claims; where a change has a number, the number is here.

## Kin 0.142.0 — 2026-09-04

### Added — Integrated VPN and exact country reporting for callers routed via VPN

- **Integrated VPN Shipped**: Shipped the integrated VPN relay across the entire app — available directly in the More sheet (`...`), the Call menu (⌘⇧T), and via the `--vpn` CLI flag (with complete backwards compatibility for `--far-test`). Media packets route end-to-end through Cloudflare's dedicated South America relay with live round trip timing and packet telemetry.
- **Exact Country Reporting**: For callers routed via a VPN (whether through the integrated VPN relay or via an external VPN detected over rendezvous), Kin now detects and shows the exact country and city they are routed through (e.g., Brazil (São Paulo), Chile (Santiago), Netherlands (Amsterdam), Norway (Oslo)) rather than generic continent names or silence.
- **Peer and Dual-End Visibility**: In-call sheets and status lines clearly indicate whenever you or the remote peer are routed via a VPN, showing the exact country of egress for each participant.

## Kin 0.141.0 — 2026-09-04

### Improved — Pure 48 kHz linear PCM audio preservation, turn cues, and anti-ratchet jitter recovery

- **Pure Mic & Linear Double-Talk**: Near voice is transmitted 100% bit-for-bit unadulterated (`0.0000%` sample modification), speaker echo is suppressed linearly (up to 120 dB quieter) without spectral ducking or half-duplex clipping, and headphone audio runs bit-exact at 48 kHz linear PCM.
- **Micro-Timing Cues & Floor Duplex Protection**: Low-amplitude pre-turn inhales are preserved at full 1.0 gain (0 dB attenuation) while keeping classifier in `.quiet`, and turn-end handoff eliminates ~450 ms of release delay. Holding the floor (`floorGranted = true`) guarantees 1.0 transmission gain against speaker playout.
- **Wire Forward Redundancy**: Packets encapsulate redundant uncompressed PCM frames via `Wire.packAudio` and `Wire.unpackAudio`, recovering dropped frames bit-exact without synthetic or robotic PLC generation.
- **Jitter Anti-Ratchet & Monotonic Decay**: Integrated `Audio.JitterAdapter` and playout rate governor clamped to `[0.996, 1.004]`; deep outlier latency spikes are rejected from target growth and depth decays monotonically to baseline (2 packets / 16 ms) upon network calm. Verified across 16 assertions in `--selftest-boost`.

## Kin 0.140.0 — 2026-09-03

### Fixed — the "connecting… reconnecting…" loop after the other person answers

- **Half of answered calls never keyed.** Answering a ring re-execs the callee, so the caller re-keys against a fresh offer. `Crypto.handshakePackets` decided "the peer has proved the key" from a **lifetime** `opened` counter, so after a re-key the side that came out as B sent HS3 alone and never re-sent its ML-KEM ciphertext — not even once, because the `.keyed` reply fires after `derive`. A stayed unkeyed and probed in the clear; B held a key and refused the plaintext. Live call `nxj-ltoi-nur` (2026-09-03 19:44): 20 minutes at a 3.5 s "reconnecting" period; far end `crypt=0`, 2,009,322 pre-key drops; near end `crypt=1`, 2,707 plaintext refusals. The ruler is now packets opened **since this key**. New selftest arm 1b (a restarted A after B has opened packets) fails on 0.139.0 and passes now.
- **Liveness is any authenticated packet, not just packets from the address we chose.** Two ends of one call can settle on different paths (LAN vs the router's hairpin); a decrypted packet is the peer, whichever address it came from.
- **The LAN is a one-way door.** 0.139.0 on two Macs on one Wi‑Fi: upgrade to LAN → 256 hairpin packets → back to public → LAN probe reply → upgrade, eleven times a second in the log. While the locked private path has answered a probe in the last 3 s, media arriving from the public address no longer moves us; the other end catches up on its own. Towards the LAN the move takes 4 packets.
- **Same Wi‑Fi**: private candidates win the race outright and the race settles the moment one answers (ICE host priority); a same-subnet peer's LAN address is the provisional destination; LAN candidates survive rediscovery and get an ARP warm-up burst when learned; handshakes go to every candidate, not only the provisional peer.
- **Bind**: after 5 s on a busy port the app takes any free port instead of dying — rendezvous publishes the port `getsockname` reports, so a second Kin on one Mac now works.
- **A plaintext probe from a keyed peer** (a restarted process racing in the clear) triggers an immediate handshake beat, at most once a second.

### Added — the far-away test (More sheet, Call menu ⌘⇧T, `--far-test`)

Two Macs in one room in Delhi can now make a call that travels to South America and back. With the switch on at either end, every media datagram of the call — both directions — goes over a WebSocket to a Durable Object created with `locationHint: 'sam'` (room `xcont-<code>`, its own object so the hint is honoured) and is fanned out to the other Mac. That is what one participant on a VPN in Santiago would cost the call, using Cloudflare only. The relay's own round trip is measured every 2 s with a ping the object answers and shown in the sheet; if the object landed nearby the sheet says so rather than claiming a far-away test. The far end learns of the switch through a sealed once-a-second beat (`XMAGIC`, new) and forgets it 5 s after the beats stop. Relay packets arrive on a loopback socket the tunnel owns and are treated as the locked path: never adopted, never off-path. Media stays direct until the relay reports both ends on it (`xcont-peers`, pushed on every join and leave) and whenever it drops.

Two things the new rig (`mac/tools/far-test-check.sh`, five arms against the live relay) found before anyone did: the beat's first magic number was the goodbye's (`0x544B_0008`), so the far end hung up on the first beat — `main.swift` now refuses to start if two packet kinds share a magic; and the relay object receives binary frames as a `Blob`, which `send()` forwards as the text "[object Blob]" — 28,000 packets a side sent, none received, until the fan-out read the bytes.

## Kin 0.139.0 — 2026-09-03

### Fixed — launch crash loop from stale resume video path, test isolation, and watcher Home window sibling detection

- **Stale video path in resume recovery**: When a call ran with a custom `--video <path>` (e.g. from an automated test or measurement run) and the video file was later deleted, `call.json` was left pointing at a non-existent file. On next launch, `Resume.pending()` re-execed with `--video <deleted>` and `resolveVideoArg()` called `exit(2)` before displaying any window, leaving `call.json` permanently on disk and creating an unrecoverable crash loop.
  - `Resume.argv(_:bundled:)` now falls back to `"camera"` if a configured video file does not exist.
  - `Resume.pending()` drops stale resume records if the video file is missing.
  - `resolveVideoArg()` falls back to `"camera"` when resuming instead of crashing with `exit(2)`, and clears any pending resume record before exiting on invalid arguments.
- **Test isolation in `record-check.sh`**: Exported `TK_KIN_DIR="$SP/kin"` and added `--no-rejoin` so test invocations never touch or pollute the user's real `~/Library/Application Support/Kin/call.json`.
- **Watcher Home window sibling detection**: In `Target.siblings()`, processes running the Home window (`Launcher.home`) without `--window` in argv are properly recognized as running instances of Kin, preventing duplicate instances from being launched when clicking the Dock icon. Installed a `SIGWINCH` raise handler in `Launcher.home` to activate and bring the Home window forward when reopened.

## Kin 0.138.0 — 2026-09-03

### Added — call recording UI, menu integration, and wire status synchronization

- Adds **Record Call** (`⌘⇧R`) and **Open Recordings in Finder** to the application menu and Call menu.
- Adds `Record call` row to the in-call More sheet (`...`) with live recording feedback and toggle controls.
- Introduces `Wire.ST_RECORDING` (bit 128) on the status byte so recording state synchronizes across ends, notifying the remote peer when a call is recorded locally.
- Recordings are cleanly saved to `~/Movies/Kin/Kin-<timestamp>.mov` with sample-accurate audio/video synchronization and real-time packet loss concealment.
- Automatically inhibits video pause on verified LAN paths (`inhibitPause`) to preserve full frame rate over local network.
- Sets local speech subtitles to default off (opt-in with `--subtitles`) to reduce unnecessary background CPU usage.

## Kin 0.137.0 — 2026-09-03

### Added — in-call recorder (⌘⇧R and in-call More sheet)

Records the call exactly as perceived and rendered: decoded audio with concealment
breaks directly from the CoreAudio playback buffer, and decoded video with freezes
and stalls directly onto a 30 fps movie file. Saved to `~/Movies/Kin/Kin-<timestamp>.mov`.
Toggled via `⌘⇧R`, the More sheet, or `--record`.

### Fixed — LAN candidate probes are dispatched while locked and sealed under crypto

0.136.0 fixed the probe reply path (`rawSendTo`), but the 19-minute live test call
remained on `lock_lan 0` with `path_priv_ms -1` because probe *requests* were never
delivered:
1. In `main.swift`, the rediscovery loop called `continue` when `wire.locked == true`,
   bypassing `wire.probeAllCandidates()`. Probes were never sent once locked.
2. In `Net.swift`, probe requests were sent unsealed via raw `sendto()`. The receiver
   drops all unsealed non-handshake packets once crypto is established.
Now `wire.probeAllCandidates()` runs periodically in the locked loop, and requests
are sealed via `rawSendTo`.

## Kin 0.136.0 — 2026-09-03

### Fixed — a path probe is answered on the path it arrived on

0.135.0 shipped the LAN upgrade below and, with it, the instrument that proved
the upgrade could never fire. The first live call on it read, on both ends and
every beat: `lock_lan 0` (locked the public hairpin), `cand_priv 1` (a LAN
candidate existed), `path_priv_ms -1` (the LAN **never answered a probe**),
`relocks 0` -- while each end was probing that LAN address every 0.5 s for the
whole call. The LAN was reachable: the other Mac was ARP-resolvable on
`192.168.1.x` and the firewall was off.

The probe *reply* was the bug. A clock-probe request was answered with
`rawSend`, which goes through `wireSend` to the locked `peer` address. A probe
that arrived on the LAN was therefore answered over the hairpin, to the public
address; the reply came back from the public IP, and the receiver booked its
round trip under the public path. The LAN could never be credited with the
round trip it had just completed -- the race could not see the very path it was
racing. A round trip only measures a path if it returns on it.

A request is now answered at the address it came from (`rawSendTo`), sealed
exactly as everything else is sealed and dropped under an impaired rig's loss.
A request that arrived through the TURN relay is still answered on the channel,
where a raw send to the relay's own address would not land.

## Kin 0.135.0 — 2026-09-03

### Fixed — a hairpinned call upgrades onto the LAN when it answers

A live 0.134.0 call between two Macs on the same Wi-Fi locked the public
hairpin path and stayed on it for 270 s: `route 1`, `relocks 0`, `rtt_jit`
60–92 ms on a 6 ms link, ~700 packets/s lost each way, 47,650 samples
concealed. The verdict was `audio_dropouts_in` (major).

Root cause: `pickBestPathLocked` settled the path race **once** and never
re-evaluated, and `probeAllCandidates` stopped the moment crypto keyed. The
same-router peer's LAN probe is routinely dropped during the first ARP (the
hairpin documented in 0.133), so the LAN lost the initial race; crypto then
keyed fast over the public path, collapsing the 400 ms private-candidate grace
to 150 ms, and the call hairpinned for its whole length with no way back.

Now `probeAllCandidates` keeps probing an unreplied private candidate after the
race settles (one 32-byte packet per 0.5 s, until it answers or this end is
already on a private path), and `pickBestPathLocked` takes a private path when
it answers: one way only (public/relay → private), so it cannot oscillate.
`--no-lan-upgrade` is the legacy control arm.

The beat now carries the diagnostic that `route` alone could not: `lock_lan`
(the locked path is a private address), `cand_priv` (private candidates
offered), `path_priv_ms` (best RTT a private path answered with, -1 = none). A
public lock with `cand_priv > 0` is a hairpin. It was this instrument that
found 0.136.0.

## Kin 0.134.0 — 2026-09-03

### Added — version row on the front-door settings card

The front-door settings card (opened by clicking `...` in the top right) now displays a
dedicated `Version` row with a pill chip showing the running version (e.g. `0.134.0`).
Matching the in-call controls sheet, tapping the version chip checks for updates
(`Update.checkNowForPerson()`), displays temporary feedback (`This is the newest version.`),
and turns into an `Update ready [restart]` action when a downloaded update is waiting.

## Kin 0.133.0 — 2026-09-03

### Changed — temporal denoise floorWeight tuned to 0.16 (-7 to -9% bytes/frame at q0.7)

Lowering the temporal denoise floor weight from 0.25 to 0.16 deepens temporal averaging
over stationary regions from ~4 frames (~133 ms) to ~6 frames (~200 ms), cutting static
background noise variance by ~35% without adding motion ghosting (moving pixels continue
to bypass at full weight).

Measured with the `--vpsnr` ruler across real sensor clips at the lossless rung (`q0.7`):
- `talkingheadA.mov`: 8,418 -> 7,686 B/frame (-732 B/frame, -8.7%, -175 kbps), filter-vs-raw 50.7 dB.
- `talkingheadB.mov`: 5,442 -> 5,085 B/frame (-357 B/frame, -6.6%, -85 kbps), filter-vs-raw 52.3 dB.
- `realA.mp4`:        6,196 -> 5,700 B/frame (-496 B/frame, -8.0%, -119 kbps), filter-vs-raw 51.8 dB.

Zero ghosting on difference dumps (`diff.png`); PSNR vs filtered reference 45.1–45.7 dB.
`--vdenoise-floor 0.25` is the control arm.

### Fixed — audio choppiness, AGC pumping distortion, and LAN hairpin stalls

Real call analysis (`38un3grj16gfk`, 134s, `choppy 183`) showed three compounding failures:
1. **Hairpin NAT lock**: Initial LAN UDP probe to `192.168.1.103` was dropped by macOS during
   ARP resolution, locking the call onto a 150 ms public hairpin NAT. `Net.swift` now grants
   a 400 ms settle window if an unreplied private candidate exists.
2. **Buffer freeze on network bursts**: Network clump arrivals caused starvation (`conc > 0`)
   followed by packet bursts (`snappedBehind > 0`). The jitter controller diagnosed this as an
   engine stall and vetoed expansion, pinning the buffer at 6 packets (~4 ms). The veto is now
   narrowed to true render stalls (`!starving && conc == 0`), allowing growth up to `JIT_MAX = 80ms`
   during starvation. `--jit-legacy-veto` is the control arm.
3. **AGC pumping & square-wave clipping**: Distance makeup gain climbed +4 dB/s to 4.0x (+12 dB),
   driving signals to 3.6x full scale and triggering cyclic 9-dB overload cuts and 38 AEC resets.
   `pack16` now applies `Wire.softLimit` ($C^1$ smooth $\tanh$ above 0.80 knee) instead of hard
   quantization clipping, and `InputGain` holds an overload cooldown with dynamic `makeupCeiling`
   and moderated climb rate (1.15x) post-cut.

## Kin 0.132.0 — 2026-09-03

### Fixed — video loss divided missing frames by received fragments, hiding real loss

The far end's receive-side loss counter (`peerVideoMissing`) counts missing whole
frames (`VideoAssembler.missing`), while `peerVideoFrags` counts individual fragments
(`fragsIn`). Dividing missing frames by received fragments divided a frame count by
~7x more fragments: at 7 fragments/frame, 1 lost frame out of 30 produced an apparent
loss of 1 / 204 = 0.49% — safely under the 2.0% retreat threshold. As a result,
1–3 dropped frames every second (up to 10% frame loss, a visibly stuttering picture)
were completely ignored by the quality controller, keeping the encoder at high bitrates
under link congestion. Conversely, during startup when few fragments had arrived
(`dFrags == 0`), a single dropped frame yielded 1 / 1 = 100% loss, instantly forcing a
2-rung collapse.

The denominator is now the number of frames actually sent in that tick (`sentFrames`).
Measured on loopback under 3% uniform packet loss: 1 dropped frame out of 30 now
correctly computes as 3.33% loss, prompting an immediate step down from q0.7 to q0.6
and q0.5 to relieve network congestion, whereas the legacy calculation held high quality
at 0.78%. `--vq-legacy-denom` is the control arm.

`namesAnotherJob` now also recognizes `--vpsnr` and `--camrec`, preventing rig and
measurement runs from accidentally resuming stale calls.

## Kin 0.131.0 — 2026-09-03

### Fixed — the denoise stage cost 3.2 ms a frame under -O

Measured on a quiet machine, the filter shipped in 0.129.0 spent 3.2 ms per 720p
frame on the capture thread: 32-bit SIMD lanes plus a histogram scatter inside the
hot loop. Standalone (`swiftc -O`): SIMD16<Int32> 1.00 ms, scalar 0.34 ms,
SIMD8<Int16> 0.25 ms. The loop now runs eight 16-bit lanes (the Q4 values fit; only
the weight multiply widens) and the noise statistics are a separate pass over every
fourth row. Output is byte-identical (6,631 vs 6,632 B/frame on the lit clip);
in-app cost reads 0.5–1.5 ms depending on the core's power state between frames.
`--vpsnr` now prints the stage breakdown (setup / luma / chroma).

### Added — `--vcodec hevc` decodes in the ruler

The HEVC decode path that the measured negative in 0.129.0 relied on was dropped
by a merge; it is back. Live calls still send H.264.

## Kin 0.130.0 / 0.130.0-android.32 — 2026-09-03

### Changed — the key exchange is post-quantum, and a release needs two signatures

**Hybrid key exchange: X25519 + ML-KEM-768 (FIPS 203).** A recording of a call
made today could be opened by whoever, one day, has a quantum computer large
enough to break the curve. The two ends now agree the call key twice, and both
agreements would have to fall. ML-KEM is implemented in Swift on the Mac
(`MlKem.swift`; CryptoKit has it only from macOS 26 and the floor is 14, and a
key exchange that is post-quantum on some Macs is a downgrade waiting to be
negotiated) and through BouncyCastle on Android. The two are held to each other:
the same seed produces the same key, a ciphertext made on either end decapsulates
on the other to the same secret, and the Android tests open the Mac's sealed
packets byte for byte.

The handshake is three packets, none over 1200 bytes: the signed offer (168 B,
now carrying the hash of the ML-KEM key), the key in two halves (629 B each,
bound by that signed hash), and the signed ciphertext (1188 B). Roles fall out of
the ephemeral keys with no extra message. **One round trip when the lower key's
packets land first, one and a half otherwise** -- the only latency this adds, at
connection, never on the media path. Measured: keygen 103 µs, encapsulate 110 µs,
decapsulate 116 µs, each once per call; seal still 0.67 µs.

Incompatible on purpose, again: 0.130 refuses v2 (0.128–0.129) handshakes as
`hs_old`. Both ends update, or neither talks. Beat: `crypt_v=3`, `crypt_pq=1`,
`crypt_role`, `hs_kem_bad`, `hs_ct_refused`.

**Two signatures on every release.** The Ed25519 release key is a file; whoever
copies it could ship an update to every Mac and phone. A second key -- ECDSA
P-256, created inside the kin-signing keychain and marked non-extractable, so no
keychain API can copy it off the release Mac -- now signs every manifest too
(`manifest.json.sig2`, `mac/tools/sign2`), and both apps require both signatures.
Older clients ignore the second file, so nothing is stranded. The Secure Enclave
would be stronger; a command-line tool cannot create enclave keys without an
Apple-provisioned entitlement (measured, `errSecMissingEntitlement`), and this is
the strongest thing a self-signed toolchain can hold. **Losing that keychain means
enrolling a new key in a release signed by the old one first** -- back it up, and
enroll a second Mac.

Also: the kin-signing keychain had stopped accepting its recorded password (it had
stayed unlocked since August, which masked the drift until the Mac slept). Rebuilt
from the saved certificate as `kin-signing2`; same certificate, same designated
requirement, no user re-prompted.

## Kin 0.129.0 — 2026-09-03

### Changed — bounds and overflow checks on, and what the fuzzers found under them

The Mac binary was built `-Ounchecked` from its first commit: no array bounds
checks, no integer overflow traps. Inside the encryption that costs nothing in
safety, since only the authenticated peer feeds those parsers. The STUN and TURN
reply parsers run **before any authentication** on bytes from anyone on the path,
where an out-of-bounds read is memory corruption rather than a crash. `-O` now.

**Cost: none the rig can see.** `mac/tools/bounds-ab.sh`, two binaries on live
loopback with real speech, null pair first: m2e p50 18.7 / 17.9 ms for the same
binary twice, 17.3 / 19.3 ms checked vs 17.1 / 20.4 ms unchecked; CPU 0.06–0.10
s/s on both. The cipher, timed on every self-test now: seal 276 B p50 0.71 µs
checked vs 0.79 µs unchecked.

**What turning the checks on found, before the fuzzers even ran:** the beat
literal had `aec_on` twice. Swift traps on a duplicate key; `-Ounchecked`
compiled the trap out and the stale second entry silently overwrote the
canceller's field on every beat. `mac/tools/dupkey-check.sh` scans every literal.

### Added — two fuzzers, built into the binary that ships

- `tk --fuzz-parsers <secs>` mutates valid templates and garbage into every
  pre-authentication parser in-process: STUN binding reply, TURN replies
  (success, error, realm/nonce/ERROR-CODE), ChannelData unwrap, the signed
  handshake -- plus video reassembly and the lossless audio decoder. 1.9 million
  inputs in 20 s, seeded and replayable.
- `tk --fuzz-send <count>` turns one end into a **hostile peer**: it completes the
  signed handshake honestly, then seals and sends mutated audio, video, probe,
  subtitle and keyframe packets at the other end beside its real speech.
  `mac/tools/fuzz-check.sh` runs both and requires the target alive, keyed and
  crash-free, reading the crash-report folder rather than trusting exit codes.

**Three real findings, all reachable by a peer holding a valid key, all fixed:**

1. **A time probe crashed the app.** Three of a probe's four timestamps come from
   the far end; a tick count near 2^64 overflowed the clock conversion
   (`ticks * 125 / 3`). One packet, one trap. Probes with impossible timestamps or
   a round trip over ten seconds are refused (`TimeSync.refused`), and the
   conversion saturates instead of wrapping or trapping.
2. **A video fragment longer than its slot was a heap write.** The datagram can be
   1400 bytes, the slot 1150, and the copy was `memcpy`, which no compiler flag
   checks; on the last fragment it wrote past the whole frame buffer. A negative
   frame number indexed the ring negatively. Both refused (`VideoAssembler.oversize`).
3. **Parity repair read a slot while writing it** -- an exclusivity violation the
   unchecked builds never enforced, so every parity repair since it landed ran on
   undefined behaviour. The parity block is copied out before the buffer opens.
4. **Room codes were on disk.** Every HTTP call used `URLSession.shared`, whose
   disk cache (`~/Library/Caches/com.tokkah.tk/Cache.db`) held the rendezvous URL
   of every call this Mac ever made: room code, public address, LAN address. Two
   instances writing that SQLite file at once is also what segfaulted the fuzz
   target inside CFNetwork. One ephemeral session now (`Http.session`), no cache,
   no cookies; the legacy database is deleted at launch.
### Also in 0.129.0 — the picture (the video line, merged)

### Changed — the sensor's noise is taken out before the encoder sees it

The "visually lossless" rung (q0.7) costs 1.2 Mbps on a clean file and read
4.4–4.7 Mbps (~18.5 KB/frame, 17 fragments) on every live call this month. The
difference is what a real camera adds to each frame: a fresh random pattern no
reference frame predicts, so the encoder pays for it in full and then pays again
when one of the extra fragments is lost. A motion-adaptive temporal filter now runs
on the capture thread in front of VideoToolbox (`Denoise.swift`): a pixel that
moved by a few levels is averaged with its own filtered past, a pixel that moved a
lot is taken whole, and the threshold between them follows the measured noise
(median |frame-to-frame difference|, ×12, clamped 6–40). Only the encoder sees the
filtered frame; the mouth detector and the self-view still get the raw one.

Measured with the `--vpsnr` ruler on real captures, q0.7, same encoder settings:

| source | bytes/frame off | on | filter's own change vs raw |
|---|---|---|---|
| lit room (H.264 recording, 1620×1080→720p) | 8,545 | 7,433 (−13%) | 48.5 dB (invisible) |
| dark room, raw sensor (`--camrec`, ProRes) | 57,662 | 28,611 (−50%) | 39.3 dB, difference image is pure grain, no trail |
| live loopback, lit clip, one end on / one off | 7,661 | 5,752 (−25%) | — |

Cost: ~2 ms per 720p frame in SIMD (measured on a machine at load 13; the scalar
version read 3.5 ms and its p99 showed as +3.4 ms glass-to-glass on the filtered
direction, which is why it was vectorised before shipping). Default ON;
`--no-vdenoise` is the control, `--vdenoise-t` pins the threshold,
`--vdenoise-floor` the still-pixel weight. New beat fields: `v_dn_on`, `v_dn_t`,
`v_noise` (the camera's noise in levels), `v_still_pct`, `v_dn_ms_p50/p99`,
`v_dn_bypassed`.

Two versions of the filter were discarded on measurement: an 8-bit reference
rounded the 1–2 level differences that ARE the noise to zero (raw and filtered
crops were indistinguishable; the reference is Q4 fixed point now), and a fixed
threshold of 24 treated dark-room grain (~8 levels frame to frame) as motion.
A fixed 40 took the grain out but turned a slow pan into a ghost (whole face in
the difference image at 40 dB); the adaptive threshold lands at ~8 lit and ~28 dark.

### Changed — a frame too big to send is harm before any packet is lost

The quality ladder stepped down on one signal only: the far end losing video. On
a clean link nothing ever stepped it down, so a dark room sat at q0.7 sending
28,600-byte frames -- 25 fragments each, 11 ms of serialisation on a 20 Mbps
uplink -- for a picture the ruler measures at 38.9 dB because the source is
grain-limited. One rung down that picture is 8,400 bytes and 36.2 dB. Bytes per
frame is now a second reason to step down: five consecutive seconds over 12,000 B
(`--vbytes-cap`, 0 disables) drops a rung and blocks it the way a lossy rung is
blocked. Loopback, dark capture as the camera: 37,200 B/frame at q0.7 → stepped to
q0.6 at 13 s → 11,300 B/frame for the rest of the call, `v_q_heavy_downs 1`. The
lit clip on the other end stayed at q0.7 (7–10 KB). The live calls this month that
read 18–19 KB/frame (dim rooms) would take this step; the 4.7–5.6 KB ones would not.

### Measured negative — HEVC does not buy the lossless rung anything

`--vpsnr --vcodec hevc` puts the same frames through Apple's hardware HEVC encoder
with the same realtime, no-B-frame settings. At equal PSNR against the filtered
source (interpolated across q0.5–0.8), bytes per frame relative to H.264:

| target | lit room | dark room |
|---|---|---|
| 40 dB | 0.86 | 1.14 |
| 43–44 dB | 0.93–0.98 | — |
| 45–46 dB (the lossless rung) | **1.15–1.26** | — |
| 36–37 dB | — | 0.73–0.74 |

So HEVC saves bytes only where the picture is already being given up, and costs
15–26% MORE at the quality a call actually runs at. Encode latency was lower
(1.4 vs 2.0 ms p50). Not wired into the call; the ruler option stays so the
result can be re-checked on a future chip.

### Measured negative — pinning the camera to 30 fps in the dark

`--camrec` showed the sensor delivering 16.7 fps in a dim room (exposure
stretched to keep the face visible), a 60 ms frame interval. Pinning
`activeVideoMaxFrameDuration` to 1/30 held 30 fps (298 frames in 10 s vs 170) and
the picture went from mean luma 8.6 to 3.0: near black, 428 B/frame, nothing to
see. The exposure stretch IS the picture in a dark room. Real calls this month all
encoded at 30–31 fps, so the auto behaviour already gives 30 in a lit room and the
only rooms this would have changed are the ones it would have blacked out. Not
shipped; the camera keeps its own pacing.

### Fixed — the camera delivered 1080p to a 720p encoder

`camera: mode 1280x720` was logged and the first frame measured 1920×1080: the
device was put in its 720p format and read back 1080p, and delivered 1080p, with
the session preset at 720p too. The encoder configured for 720p was handed 2.25×
the pixels on every frame and VideoToolbox scaled each one on the way in. The video
output now asks for 1280×720 explicitly and gets it (`camera: running in 1280x720`,
`FIRST FRAME 1280x720`); the beat records the delivered size as `v_cap_w/h`.
`--cam-native-size` is the control arm; A/B back to back, mean luma 5.1 vs 4.8.

### Added — rig modes

- `tk --camrec <out.mov> [--camrec-secs N]` records the raw sensor to ProRes 422 HQ
  for the ruler. Must be launched through the signed bundle (`open -n Kin.app
  --args ... --log <file>`): a shell-launched binary is the terminal for TCC and the
  camera answers `access DENIED` with no prompt.
- `--vpsnr` now reports PSNR against the filtered frame and the filter's own
  distance from raw, and `--vpsnr-dump <dir>` writes the middle frame as
  `raw/filtered/decoded/diff.png` — the difference image is what separates noise
  removal (even haze) from ghosting (a trail behind every moving edge).

## Kin 0.128.0–0.128.1 / 0.128.1-android.21 — 2026-09-03

### Changed — the handshake is signed, and there is no plaintext window

The call has been encrypted since 0.9 (X25519, AES-256-GCM, two directional
keys) and the file said what that did not defeat: an active man in the middle who
knows the room code. That understated it. The room code travels to the callee
**through the signalling server**, inside the ring, and the same server hands each
end the other's address -- so the one party positioned to sit in the middle was
the one party guaranteed to know the code. Three more things were true of v1 and
are not any more:

- **Anyone who could reach the port could re-key the call.** A 36-byte packet
  with the right magic and any X25519 point was adopted, unauthenticated, and
  every real packet after it failed to open.
- **Media flowed in the clear until the handshake completed**, deliberately and
  counted -- which is a downgrade an attacker holds open by dropping handshakes.
- **A recorded packet could be played back** into a call a minute later; GCM
  authenticates a packet, it does not stop the same one arriving twice.

Now (`Crypto.swift`, `Crypto.kt`, bit-exact with each other against the Mac's own
vectors):

- **The ephemeral key travels signed by the install's Ed25519 device key** -- the
  key that already signs every ring -- over a message that names the room.
  136 bytes. Refused unless the signature verifies AND the identity is the one
  this end expected: the key that signed the ring (callee), the key the server
  bound the handle to at registration, now returned with an accepted ring
  (caller), or the key pinned in `contacts.json` from a previous call. No
  expectation (an invite link, a stranger): pinned on first use for the call,
  remembered under the handle once the call is answered. Both ephemeral keys and
  both identities are in the HKDF transcript.
- **Nothing is read or written before a key.** `prekey_drop` counts what was held
  back; `prekey_rx` what arrived before this end had a key (the far end's first
  sealed probes, usually -- 0.128.0 miscounted those as `plaintext_rx`, fixed in
  0.128.1); `plaintext_rx` counts a recognised packet in the clear, refused.
- **A 2048-packet replay window** (about 1.4 s of audio). `replay_drop`.
- **Every refusal has a name in the beat**: `hs_bad_sig`, `hs_wrong_id`,
  `hs_id_changed`, `hs_old` (the far end still sends the unsigned v1 handshake),
  `hs_flood` (signature checks are budgeted at 20/s), `hs_weak`. `crypt_v=2`,
  `crypt_expected`, `crypt_pinned` say which trust path a call took.
- **`--no-crypt` is gone.** A consumer product with a switch that sends calls in
  the clear is a product that will one day be run with that switch on.
- The eight-character code now covers all four keys.

**Cost: none on the media path.** The signature is computed once per call and
cached; a same-key beat is compared before any arithmetic; verification happens
once, at connection, off the audio thread. Android has ONE curve implementation
(0.128.1-android.21): BouncyCastle's constant-time RFC 7748 / RFC 8032 code,
called directly. The platform-first-then-BigInteger arrangement -- two paths,
one not constant-time, chosen per phone invisibly -- is gone.

**Incompatible on purpose.** A 0.128 end refuses a 0.127 end and says so
(`hs_old`, "the other end is on an old build"); it does not fall back to an
unsigned exchange. Both ends must update before they can talk again -- Macs do on
their own; the phone asks.

Measured: `tk --selftest-crypto` (18 arms, including tampered signatures, tampered
capability bits, the wrong room, the wrong identity, a second identity mid-call,
the all-zero point, replay inside and outside the window, and nothing sealed
before a key) and `mac/tools/crypto-check.sh` -- two real processes on a live
socket: honest ends key and read one code; an end that expects the other's
identity reports `crypt_pinned=1`; an end that expects a different identity never
connects, seals nothing, drops 8,000 packets unsent; the installed 0.127.0 is
refused (`hs_old=21`) and named. 21 Android unit tests over the Mac's vectors.

## Kin 0.125.0 — 2026-09-02

### Fixed — the echo canceller stops throwing itself away

Three live calls on 0.124.0, read from their beats: **21, 17 and 32 re-aims** in
about 140 s each, 5–6 resets, the subtraction switched off for 82–97% of the call,
under 2 dB of echo removed. Every re-aim zeroes both filters. The delay estimator's
reading wanders on an intermittent playout, and three wandering readings in a row
threw a converged filter away for a delay the room had never moved to.

Two changes, both gated on evidence the filter cannot manufacture:

- **A working filter is not re-aimed.** A disagreeing estimate is held while the
  filter on the audio is measurably removing echo (6 dB, far-only). A room that
  really moves collapses that reading inside half a second and the re-aim
  proceeds. `aec_reaims_held` in the beat.
- **A wandering estimator is not a drifting clock.** The drift tracker believed
  slopes of −40 samples/s with an error of 17 — 830 ppm, which no crystal pair
  does — railed at −6 and walked a converged filter off its target: 24.5 → 8.1 dB
  in five seconds, traced. Fits are believed only under 1.0 sps of error and a
  physically possible slope. `aec_skew_rejects` in the beat.

Rig, with the live shape planted (readings 10 ms off for 2 s in every 6):
unguarded −12.5 dB and 7 re-aims; held 0.0 dB, 1 re-aim, 3 holds, skew 0.00;
a room that moves 15 ms at 8 s is followed to 22.6 dB. Drift arms unchanged
(1.45 sps read against 1.44 planted; 18.6 dB under 30 ppm). Near voice exact.

### Changed — both microphones may open on loudspeakers, when it is measured safe

`--speaker-duplex` (0.107.0) ships **on**. The floor stands down only in the
moments the canceller has the remaining echo path measured under −26 dB and
re-engages within one window when it has not — on a room the canceller cannot
hold this is exactly 0.124.0. `--no-speaker-duplex` is the arm;
`floor_aec_duplex_pct` says how much of a real call it bought. The voice is
never filtered, shaped or suppressed anywhere in this path: linear subtraction of
what this machine played, or the floor.

### Added — a loudspeaker distortion model, measured and left off

`--aec-nl`: bounded nonlinear basis signals from the reference (x|x|, two soft-clip
residuals) through their own short filters, summed into the same subtraction.
Still a function of what this machine played, so the near voice is still exact.
Measured (far-only / conversation): clean speaker 18.8/10.4 → 19.5/9.1; a speaker
driven hard 14.0/8.5 → 17.5/8.5. It wins 3.5 dB on a distorting speaker and
costs 1.3 dB in ordinary conversation, and the rule here is that nothing may be
lost — so it ships off, with the negative recorded in `mac/ECHO.md`. The first
version (x³, x⁵) detonated in the rig; that trace is in `Aec.swift`.

The tail sweep is also recorded: 4096 taps win 1.2 dB of the 5.6 dB an 80 ms
room costs. The filter is not short, it is slow — convergence on coloured speech
is where the remaining decibels are, and that is a separate release.

The telemetry reader gains a `CANCELLER` line (removed, path left, re-aims and
holds, drift fits rejected, resets, both-mics-open share).

## Kin 0.124.0 — 2026-09-02

### Added — the turn prediction is measured on a real call for the first time

Kin scores how likely it is that the person talking is about to finish, from the
recogniser's partial text and the shape of their voice, and both halves have been
wired since 0.92/0.93: this Mac's floor lets go of a floor it holds, and the same
number crosses the wire in TPKTX+7 so the **listener's microphone is already open
when the talker stops**. That far half is the only mechanism in the app that can
make a handover cost nothing instead of a release window.

Nothing had ever measured either half **on a call**. `predict-check` scores the
predictor inside one process; `floor-check` runs the floor with `--mute` and no
speech at all. The counters fired in production, the numbers went into every beat,
and there was nothing to compare them against — "handed over early 6 times, saving
1400 ms" is a number with no denominator.

There was also no way to turn it off, so `--no-predict` (and `--predict-p`) now
exist, for the same reason `--no-fec` does: a feature that cannot be A/B'd cannot
be shown to do anything.

Measured, two ends, two real recordings of real speech through `--audio` — the
production audio path, the production wire, the production floor:

| | early handovers | time saved | their p peaked |
|---|---|---|---|
| as shipped | **4** | **1675 ms** over 40 s of talk | 0.93 |
| `--no-predict` | 0 | 0 ms | 0.93 |

The control is deliberately not a blind arm: the prior is still computed and still
crosses the wire in both rows, so `--no-predict` removes the **action** and not the
**measurement**. A control that silenced the predictor too would make the second
row pass on a build where the recogniser had simply stopped.

`tools/predict-live-check.sh` holds all of it and is in the timing lane.

## Kin 0.123.0 — 2026-09-01

### Fixed — a camera another app is holding said so only in the window title

Zoom, Teams, Photo Booth, or a camera unplugged mid-call: the session fails to
start, and the handling for it set the **window title** to "Kin — no camera;
waiting for the other person". This app hides its title bar — `titleVisibility =
.hidden` under `.fullSizeContentView`, so the picture runs to the top edge and the
title is drawn nowhere at all. The sentence existed and had no surface. It now
uses the same place a denied permission does, and says which case it is: *"Kin
can't use your camera — another app may have it"*, or *"No camera on this Mac —
they will hear you but not see you"*. A notice rather than a button: there is no
pane to open, and a sentence that looks pressable and does nothing is worse than
one that plainly is not.

### Fixed — two controls announced as nothing in particular

A control with no accessibility label announces as "button" — the same thing every
other unnamed control announces as — so a screen reader meets a row of identical
buttons. Two were unnamed, and they were not minor ones: the **scrim**, which is
the most-used way out of the settings panel, and the **invite link**, which is the
whole first experience of the app. The hit-test audit that already walks every
control now reports `UNNAMED` per control, and `controls-check` fails on any.

### Added — the bright-environment requirement finally has a number

The one thing this app was asked for in the owner's own words — *"visibility has
to be best even in bright environments, because this is liquid glass"* — was the
only requirement with a meter in the app and **no threshold anywhere**.
`Glass.contrastRatios` has reported `ink=fg N muted N` for every surface since the
adaptive dim was built, and nothing ever held it to a number.

`glass-check` now does, over its brightest calibrated background, with two bars
from WCAG because they are different questions: **4.5:1 for text** (the panel, the
pills, the cards, the invite link — sentences somebody reads) and **3:1 for
glyphs** (the six round buttons; an icon is not a paragraph). Measured today:
text **8.6:1 and 6.4:1**, glyphs **4.4:1 and 3.3:1**. The arm was calibrated in
both directions — raised to an impossible 20:1 it named the three surfaces and
their numbers — and a third arm refuses to let the other two pass by having
nothing to judge: at least three surfaces must actually have been over a lit
picture when measured.

### Fixed — the four rigs that could never run, and one of them found a real bug

Four of the 32 checks in `mac/tools/` had been reporting COULD NOT RUN or FAILED
for weeks, none of them because of the app. All four run now, and the suite is
**31 of 32** (the one exception refuses to photograph a window that another Kin is
sitting in front of, which is this Mac and not the build).

- `doorbell-check` — "launchd never parked the rig job in 90 s". The job was
  `tk --version`, which exits in six milliseconds from a shell; under launchd it
  produced no output at all and sat at `runs = 1, last exit code = (never
  exited)`. Six substitutions, one variable at a time, and the first three answers
  were all wrong — it was not the signature (SwiftPM already ad-hoc signs),
  not the space in the path, not the `.build/debug` symlink. **It is the folder.**
  This repo lives in `~/Downloads`, which macOS protects with TCC, and a launchd
  agent has no session in which to ask — so the spawn stalls forever instead of
  failing. The rig runs from a copy outside the protected folder and refuses
  outright if its scratch dir is inside one. Now passes 10 assertions.
- `cancelrace-check` — three faults stacked, and behind them a real one. Its rig
  bundle was unsigned, so LaunchServices refused to open it silently; its launcher
  then exec'd the repo binary from *outside* the bundle, which a GUI launch also
  kills silently; and it timed a startup race with a `-Onone` build. With those
  fixed the launched copy stopped eight lines into its log, forever, at a
  microphone prompt for a brand-new bundle identity that no rig can answer —
  `--skip-mic-permission` exists for exactly that, loudly, and only from the
  command line. All three arms now pass, including the one that had never run.
  It also caught the **answer button announcing as nothing at all** to a screen
  reader, in the most important moment the app has.
- `relaunch-check` — slept a flat 4 s after `launchctl bootstrap` then pgrepped
  once, and reported "the agent never started" while the agent's own log showed it
  running. It polls now.
- `update-check` — was reading a stale debug binary. See above.

And the runner itself: a 30-minute suite **will** overlap with editing the tree,
and bash reads a script incrementally — so an edit two thirds of the way through a
run killed it with `line 219: syntax error near unexpected token 'fi'` after 17
rigs had gone green. It re-executes from a snapshot of itself now.

### Fixed — the binary now says when it is older than the code

Two binaries exist here, `.build/debug/tk` and `.build/release/tk`, and 23 rigs
default to the first while 7 default to the second. Building one and running a rig
that uses the other tests the **previous build** and reports PASS about it. That
happened three times in one session — twice as a whole suite, and once as a rig run
by hand where it looked exactly like a product bug, the arm asserting a sentence
the running binary had never contained. The binary now compares its own
modification time against `Sources/tk` and says so, loudly. `Sources` exists beside
a development build and nowhere near an installed app, so it is silent for every
real user.

## Kin 0.122.0 — 2026-09-01

### Added — you can answer a call without a mouse

A ringing call could only be answered by clicking it. Return answers now and
Escape declines, and the two are guarded differently on purpose:

- **Escape ends something.** The worst a stray one can do is refuse a call, which
  the caller sees and can repeat. No waiting period.
- **Return starts a camera and a microphone**, and the ring window raises itself
  in front of whatever somebody was typing in. This project has already had that
  accident with the mouse — real trackpad taps answered Kin calls because the card
  arrived under a finger that was already moving. So a Return inside the first
  **600 ms** of a ring is refused and says why.

Both halves are tested, because a defence whose passing half cannot be exercised
is one nobody has seen work. `window.isKeyWindow` was in that condition and came
out again: it adds nothing in production — a keyDown only reaches this app while
it is frontmost — and it made the guard untestable, since every rig here parks its
window so it never takes the front.

The keys reach the app through `NSApp.postEvent`, this process's own queue, so
they travel the path a real keystroke travels. Two other mechanisms were wrong
first: `window.sendEvent` does not pass through `addLocalMonitorForEvents`, which
is where the call window's key handling lives, so a press sent that way tests
nothing at all; and `CGEvent.post` is a **global** keystroke, which this project
has a law against — it hits whatever is frontmost, and it once quit the user's
browser and their editor.

## Kin 0.121.0 — 2026-09-01

### Fixed — a denied microphone was completely invisible

The worst failure in the app, and it said nothing at all. A person who has denied
microphone access got a call that looked entirely normal: the timer ran, the
picture was there, every control worked, and **nobody could hear them**. The app
knew — `gMicAccess` — and put it in two telemetry fields and a line on stderr
that nobody using Kin.app ever sees. The far end hears silence and both people
blame the app.

There is now a sentence on the call surface, and it is a control: *"Kin can't hear
you — turn on the microphone"*, clicked, opens the Microphone pane. Same for the
camera, which was half-handled — the front door drew a clickable hint, the call
surface set the **status** pill, which the next thing that happens ("connected",
"you are muted") overwrites within about a second. A local fault now outranks the
peer sentence in that pill, because a weak link mends itself and a permission does
not. The front door had never asked about the microphone at all: a missing preview
is self-evident, silence is not.

Three things had to be fixed before a click on that sentence worked, and none of
them would have been caught by testing the handler:

- the sentence was declared 2500 lines into `main.swift`, below
  `if let room = arg("room")`, which pumps AppKit until somebody joins — so it was
  unreachable in exactly the state it exists for. A probe on the line proved it:
  it never printed on a launch with nobody at the other end.
- the pill's own label (an `NSTextField`) swallowed the press. Third instance of
  decoration-inside-a-control eating clicks in that file.
- the first attempt used an `NSClickGestureRecognizer`, which never fires for a
  synthetic event in a window that is not key — so it worked by hand and could
  never be proved by a rig. Now the pill tracks its own press like every other
  control here.

`tools/permissions-check.sh` holds all of it, with `TK_FAKE_DENIED=microphone|camera`
so the state is reachable without touching the privacy settings of the Mac the
suite runs on, and a control arm: with both permissions in place, it says nothing.

### Fixed — asking for the camera froze the window for up to a minute

The camera permission was requested with a `DispatchSemaphore` waited on for up to
**60 seconds**, on the main thread, at a point in `main.swift` that runs before
`NSApplication.run()`. So on a first launch — the one launch that has to look
alive — the window sat frozen for exactly as long as the person took to answer the
system's dialog, and a full minute if they walked away. Nothing below it needed
the answer; the semaphore only kept the code in a straight line.

The microphone path forty lines above has the whole argument written out ("no
runloop turning, which is a frozen window in the one moment the app most needs to
look alive"). It was fixed there and the sibling kept the semaphore.

## Kin 0.120.0 — 2026-09-01

### Fixed — the settings panel drew itself above the top of its own window

Photographed at 480x320 — the smallest window Kin will now open — every row of
the settings panel came back unreachable, at y coordinates of **543, 495, 447,
399 and 351 in a window 320 points tall**. The panel was laid out with its bottom
edge pinned to the gutter and its top edge wherever the content wanted: nine rows
and three hint sentences want 565 points, and nothing in the arithmetic compared
that to the window. Not one setting was clickable, and there was no scrollbar and
no clipped edge to say why — the rows were not hidden, they were somewhere a
mouse cannot go.

It could not have been seen before: all thirty rigs in `mac/tools/` open the
default window, so the smallest legal size was a floor nobody had ever
photographed at. `--window-size WxH` exists now for exactly that, and
`contentMinSize` is 480x320 (the control row needs 344 points).

The panel now takes the room it is given and the content scrolls inside it. No
scroll view: the rows keep their own frames, so click routing, the hit-test audit
and `clickTargets` all work unchanged, and the clip is switched on **only** while
the content overflows — at any ordinary window size the glass is untouched.
`click("row:…")` scrolls to a row that is out of view before pressing it, which
is what a person does. Measured at 480x320: **0 unreachable controls**, the panel
reports `panel=5/12 shown scroll=143/333`, and a click on the scrim still closes
it.

That last one was a second defect hiding behind the first. The aim point for a
control is its centre — and at this size the panel covers the centre of the
window, which is where `scrim` sits. So the audit printed `FAIL scrim` about a
screen that worked, and `click("scrim")`, the way four rigs close the panel
between steps, would have silently pressed whichever setting happened to be in
the middle of the list. One `probeCentre(_:)`, shared by the audit and by `click`.

### Fixed — a NaN in any beat would have killed the app, mid-call

`JSONSerialization.data(withJSONObject:)` does not throw on a non-finite number.
It raises `NSInvalidArgumentException`, an ObjC exception Swift cannot catch and
`try?` cannot see:

```
*** Terminating app due to uncaught exception 'NSInvalidArgumentException',
    reason: 'Invalid number value (NaN) in JSON write'
```

Every beat is built from ratios — percentages of a call, per-second rates, ERLE
in dB, means of a window — and there was not one `isFinite` anywhere on the path.
Any one of those dividing by a zero denominator (a call with no frames yet, a
window with nothing in it, a device that never opened) aborted Kin at the next
beat, from a diagnostic. The guard has to be *before* the call, because there is
no after. Offenders are now replaced by null, **named** by full path in the beat
itself, and counted.

### Fixed — a fifth of the app's own record was unreadable

`~/Library/Logs/Kin/beats.ndjson` is the file that answers "what happened on that
call" an hour later. Read strictly for the first time:

```
1824 lines, 394 unparseable
  366  Illegal trailing comma before end of object
   17  Expecting value        (a line that starts mid-token)
    9  Extra data             (two records spliced into one line)
```

Two more faults behind that:

- **A comma too many.** Every strict parser refuses `{"a":1,}`; Apple's does not.
  `JSONSerialization` **and** `JSONDecoder` both accept it, so the stack that
  wrote these lines and the stack that would have caught them are the same
  tolerant one, and the first reader to complain was a person with python. Kin now
  scans its own output strictly and *repairs* that comma — the record on either
  side of it is perfectly good — counting the repairs and reporting them in the
  next beat.
- **Two Kins, one file, no `O_APPEND`.** The log path is fixed and does not move
  with `TK_KIN_DIR`; the handle was opened for writing and seeked to the end
  *once*. A second Kin — a rig, a second install — then wrote at its own advancing
  offset, straight over the first one's records. That is the spliced and mid-token
  lines. `O_APPEND` puts every write at the true end under the kernel's own lock.

`tools/beat-check.sh` holds all of it, on a real call's beats rather than a
fixture, and `--selftest-beat` calibrates the guard on sixteen known answers —
including the five inputs it must refuse.

### Fixed — the suite tested whatever binaries happened to be lying around

`all-checks.sh` never built anything. 23 of the rigs default to
`.build/debug/tk` and 7 to `.build/release/tk`, so a session that builds only
release runs two thirds of the suite **against the last release's code** and every
one of those rigs reports PASS about a build that does not contain the change
under test. Caught by the only rig that compares the two — `update-check`,
refusing with "the repo binary reports 0.118.0, not 0.119.0" — in a run where
`doorbell-check` rebuilt the debug binary half way through, so rigs before it and
rigs after it were testing different code. Both binaries are now built once,
before any lane starts, their versions printed, and a disagreement refuses to run
the suite at all.

Four rigs that had been reporting COULD NOT RUN, and what was really wrong:

- `relaunch-check` slept a flat 4 s after `launchctl bootstrap` and then pgrepped
  once, reporting "the agent never started" while the agent's own log — printed by
  the same message — showed it running. It polls now. **PASSES.**
- `update-check` was reading a stale debug binary. Fixed by the build step above.
  **PASSES.**
- `cancelrace-check` had three faults stacked. Its rig bundle was **not signed at
  all** (`spctl: rejected, source=no usable signature`), so LaunchServices refused
  to open it — silently: no process, no crash report, no line in any log, while
  the watcher had already said "is calling — opening Kin". Its launcher script
  then exec'd the repo binary *outside* the bundle, which a GUI launch also kills
  silently. And it timed a startup race with a `-Onone` build. Arm A now runs and
  proves the three claims that matter: the watcher takes the cancel while it is
  still the holder, opens no second window for a hang-up, and leaves nothing
  ringing. The remaining arm needs microphone access for a temporary bundle — a
  fresh ad-hoc bundle is a new TCC identity — and says so instead of reporting a
  failure it cannot see.
- `doorbell-check` still cannot park its launchd job on this Mac. Unfixed, and
  reported as such.

`recover-check` was written, passing, and **in no lane at all** — run by nobody.
It is registered now, and two of its assertions were blind: its precondition
waited on `cap N/s`, this end's *microphone*, which reads 1500/s on a Mac that has
never exchanged a packet with anyone. So an arm whose impairment began before the
two ends locked never had a working call to lose, and the rig recorded "A drew no
warning during the outage" about an app that says **"reconnecting…"** three
seconds in — it was grepping `warn=` and `poster=`, the video sentences, while the
app writes `status=`. Both fixed, and `--imp-after` exists so an outage can be an
event rather than a condition.

## Kin 0.102.0 — 2026-08-31

### Added — the camera signal now crosses the wire, and it can beat its own audio

0.100/0.101 were local-only: each Mac watched its own camera and the far end
learnt nothing. `ST_SEEN_TALKING` (status bit 64) carries it, with its own
edge-triggered flush so it never waits on a periodic carrier.

The point is not that it is fast. **A mouth opens for a vowel some tens of
milliseconds before sound leaves it**, so the cue can arrive at the far end
*before the audio of the same word would have* — one network hop paid out of
the pre-speech lead instead of added on top. It is the only mechanism in this
project that can make a handover cost nothing rather than merely cost little.

What the receiver may do with it is deliberately one thing: a holder who has
already stopped talking lets go **on sight**. Measured in the two-end rig:
their camera releases a finished turn in **0 ms**, against 400 ms waiting the
window out. Three rows guard the rest, all passing:

- a peer that *cannot* say (older build, no camera, dark room) reads as `nil`
  and waits the ordinary 400 ms — absence of evidence is never silence
- nothing is booked to a camera that said nothing
- **a talking holder keeps the floor however loudly their camera disagrees** —
  the signal can collapse a wait, never cut a sentence

### Added — a distant talker can finally be heard

Reported as *"if the mic is far away, it is failing to capture the speaking
person"*, and the cause was not tuning: **every path in the level loop was
`min(1, …)`**. The trim could only ever turn a microphone *down*. A talker
peaking at 0.06 got no help, because the device volume knob is the only makeup
path, most microphones do not expose one, and it caps at 0.95 regardless. The
old rig even asserted the ceiling — *"never climbs past unity, which would be a
gain"* — which was right while the only failure was a mic five times over full
scale, and exactly wrong for this one.

One target now (speech peaking at −5 dBFS), sought from either side, with a
dead band between so a healthy microphone is never touched. Measured: a mic
peaking at **0.06 is lifted 8× (+18 dB) to land speech at 0.48** — the level a
near talker gets. Three guards, each with a REJECT row that fails when removed:

- **speech only** — the loop already required 3 s of confirmed voice, so room
  tone is never amplified
- **not while the echo veto is claiming the mic** — a gain on our own
  loudspeaker is the last thing anybody needs
- **15 dB SNR minimum** — a voice only 6 dB over a noisy room is *not*
  amplified, because that produces loud noise rather than a clear voice

Bounded at +18 dB, and it comes back down: leaning in again takes 8.0× → 0.34×.
The learned value persists per device, so a habitually distant mic starts the
next call already lifted.

### Measured — video latency is already at its floor, and a CPU "optimisation" was a pessimisation

Video was checked before being touched, and there is nothing to win: **g2g p50
14.6 ms** on a real call (encode 4.7, decode 1.6), 0 freezes over 150 ms, 30 fps
solid, 3 frames lost in 10,194, jitter-queue depth 1–2. The dominant remaining
term is the 33 ms frame interval itself, so the only real lever is frame rate,
not the pipeline.

CPU on a two-way 720p30 call measures **0.162 CPU-s/s**, and the lip detector
adds **0.028–0.034 (≈20%)**. The obvious saving — hand Vision a small luma-only
copy instead of a 720p frame — was built, measured, and **reverted**:

| Vision input | cost |
|---|---|
| native 420v, no scaling | **2.90 ms/look** |
| grayscale 1280 wide | 4.58 ms/look |
| grayscale 320 wide | 7.17 ms/look |
| grayscale 240 wide | 10.65 ms/look |

Monotonically worse the smaller it got — the cost is not proportional to pixels.
Vision has a fast path for the biplanar format the camera already produces, and
a single-plane grayscale buffer leaves it. Recorded in `Mouth.swift` because it
is the first thing anybody will try. Also noted: the rig's own run-to-run noise
is ~8% of total CPU, which is why the per-look measurement was used to decide
rather than the A/B.

## Kin 0.101.0 — 2026-08-31

### Fixed — the visual signal was measured in a frame that turns with the camera

0.100.0 took the **vertical extent** of the inner lips. The rig arm added
straight afterwards found what that costs: the same talking clip turned 90°
still had its face detected in **100%** of frames — Vision does not need the
orientation hint to *find* a face — while the talking verdict fell from 100% to
**86%**, because "vertical extent" had quietly become partly mouth *width*.

That is a defect no orientation search can catch, which is why the search built
for it was the wrong answer: nothing fails, every face is still found, and the
signal simply gets worse. A Mac camera does not deliver `.up`, and a rig binary
on this machine is refused the camera outright (TCC binds the grant to code
identity), so the live rotation is not testable here at all — the code had to
stop depending on knowing it.

Aperture is now measured on the **lip contour's own two axes**: mouth opening
over mouth width, from a closed-form 2×2 eigen-decomposition of the point
cloud in image pixels. Dimensionless, and identical under any rotation, scale,
or distance from the camera. The mouth normalises itself, so no face-height
term is needed either.

It is also a **better** signal, not merely a safer one:

| | talking p50 | still p90 | separation | rotated verdict |
|---|---|---|---|---|
| 0.100.0 (vertical extent) | 0.09 | 0.02 | 4.4× | 86% |
| 0.101.0 (own axes) | 0.63 | 0.08 | **7.9×** | **96%** |

Talking now reads as moving 100% of the time and the same face held still 0%.

The threshold moved 0.03 → **0.15**, and the reason is worth naming: changing
the measure changed the **units** (aperture-ratio per second, not face-heights
per second), and the old constant survived the change looking perfectly
reasonable — it called a face sitting perfectly still "moving" 31% of the time.
That is `stale-constants-after-a-codec-win`, one release later.

The orientation search stays as a cheap safety net, and the rig now records
that Vision needed no hint rather than asserting it must have searched — the
row that claimed otherwise was asserting something false.

## Kin 0.100.0 — 2026-08-31

### Added — the app can see who is talking

Every turn-taking bug in this project has one root, and Audio.swift has stated
it in writing for months: *at the instant of decision, an interruption and an
echo are the same signal.* They are the same **acoustic** signal. A loudspeaker
has no mouth.

`Mouth.swift` watches the camera the call already runs — Apple's Vision
framework, so no dependency to vendor and no model to ship — and measures the
**rate of change** of lip aperture, normalised by the face's own bounding box.
Not "is the mouth open": a person sitting open-mouthed is not speaking, a
person mid-consonant has it shut, and mouth shapes differ enormously between
faces. What separates speech from a face at rest is that the aperture keeps
changing, roughly a syllable at a time.

Measured on real talking-head footage at 12 Hz: talking rate p50 **0.09**
face-heights/s against the same face held still at p90 **0.02** — 4.4× apart,
face found in 100% of frames, and 0% in a clip with no face in it. The
threshold was read off that measurement, and **the first guess was wrong by
4×** — it sat above the talking p90 and called a speaking face silent 100% of
the time while passing every other arm in the rig. `--mouth-test` sweeps
neighbouring thresholds on every run so the constant stays visible rather than
becoming folklore.

Three states, and the third is load-bearing: `moving`, `still`, and
**`unknown`** — no face, no camera, no frame, a failed request. Only the first
two influence anything, because `blind-instruments-report-negatives` would
otherwise turn every dark room into "this person is not talking".

The signal is allowed to do exactly two things, both of which can only open a
microphone or speed up a handover:

- **Withdraw the echo veto.** 0.94.0 shipped with a stated risk: a real voice
  quieter than the echo it sits under gets gagged for an estimator tick, and no
  acoustic threshold can fix it. A visible moving mouth overrules the
  correlation — and only ever in that direction.
- **Shorten the floor contest** from 180 ms to 80 ms, because two independent
  signals need less of each. Rig: a camera-confirmed voice takes the floor in
  **60 ms**, against 160 ms on audio alone and 1150 ms in 0.98.0.

It can never mute anybody, and a blind detector reverts everything to 0.99.0
exactly — asserted as a REJECT row in `strictSelfTest` ("blindness costs
nothing", 160 ms unchanged), alongside a row proving a blind camera cannot take
the floor from whoever holds it. `--no-mouth` is the control arm.

Cost: ~2.9 ms of CPU per look — an upper bound, since the measuring rig also
decoded the video — or about 0.035 CPU-s/s at 12 Hz against a 720p call's 0.16.
Frames that arrive while the last is still being looked at are dropped and
counted, never queued: a queued verdict describes a face that has already
stopped talking.

Every beat now carries `mouth_looks` / `mouth_faces` (which separate "never
ran" from "ran and saw nobody" from "saw somebody sitting quietly"),
`mouth_moving_pct`, `mouth_dropped`, `mouth_unveto_pct` and
`turn_visual_takes`, and the telemetry summary gains a `CAMERA` line.

**Not yet crossed to the far end.** The holder's own decision to release early
would benefit from seeing that somebody else has started talking; that is a
protocol change and a separate release.

## Kin 0.99.0 — 2026-08-31

### Fixed — interrupting took 1150 ms, so short interjections were deleted

Measured on a 333 s two-person call (`2p183qa061zcu` / `2adf00o87punm`, 0.98.0):
140 collisions and **50 whole utterances that never reached the wire at all** —
onset-to-wire p50 was 0 ms, so every utterance was either instant or entirely
gone. Reported as "it is still cutting people in between and words are dropping
while they speak".

The arithmetic behind the second everyone could feel: taking the floor from a
holder required `nearClaimMs >= deadlockMs` (450 ms), and `nearClaimMs` only
starts counting once the classifier promotes a voice to `.claim`, which needs
`claimMs` (700 ms) of sustained sound. **1150 ms** before an interruption was
formally allowed — and in strict mode every one of those milliseconds is
silence, not a duck. Anything shorter than that was not delayed, it was
deleted: "yeah", "no", "wait", every "mm-hm".

Three changes, and they work as one:

- **The contest runs on voice, from its first block** (`nearVoiceMs`), not on
  a 700 ms-old `.claim` verdict, and at **180 ms** instead of 450. Measured in
  the two-end rig: the floor changes hands after **160 ms** of voice.
- **The onset grace window** keeps that voice audible while the contest
  resolves, bounded at 400 ms. A 300 ms interjection now loses **0 ms** where
  0.98.0 lost all 300. This could not have shipped before 0.94.0: opening a
  microphone on "any near voice" over a live loudspeaker used to mean opening
  it on this machine's own echo, and the correlation veto is what tells those
  apart — a vetoed block classifies as `.quiet`, which is the one input the
  window refuses.
- **An "mm-hm" is heard again.** It still cannot take the floor from the person
  talking; it is simply no longer held back. The self-test row that asserted it
  was inaudible encoded the defect and now asserts both halves.

### Fixed — the turn-end predictor fired twenty times a second

`farPredArmed` was set whenever the far end's prior dipped below the threshold
and **never cleared when it fired**, so every subsequent block above the
threshold fired again. The same call recorded **6838 far releases** and a
claimed saving of **2,623,182 ms** — 7.9× the length of the call. That number
was not a win, it was a state machine thrashing between `theirs` and `idle`
twenty times a second, which the other end recorded as 241 choppy gate flaps.
Now disarmed on fire: 25 releases over 50 dip-rise cycles in the rig, and the
comment's "armed once per hold" is finally true.

### Added — the interjection rescue is counted

`turn_grace_pct`, `turn_grace_onsets` and `turn_fast_takes` ride every beat, so
a live call says whether the rescue fired and how often — "it never fired" and
"it fired and did not help" can no longer look the same. The telemetry summary
gains an `INTERJECT` line.

### Changed — the speaking edge is thick enough to feel

On the user's instruction: the hairline was "really hard to spot, and you have
to constantly look at [it]... you should FEEL, yes, your voice is going
through." Width is now the felt channel — 1.5 pt at rest, 3 pt listening,
4.5–8 pt while speaking and moving with your own syllables. Still a line and
never a light: `floor-check`'s halo band moved past the widest stroke and now
measures the ring just inside it as **unchanged from rest** (−4.933 vs −4.935),
which is stricter proof than the old band gave.

## Kin 0.98.0 — 2026-08-31

### Fixed — the second of delay was the app deciding who is speaking, in four places

Reported as "a delay of one second... latency in deciding who is speaking, not
in actual transportation of voice", and that diagnosis was exactly right: the
media path measures **17 ms** mouth-to-ear on these calls. The wait was in the
turn layer, and it was four separate things stacked on one another. Measured on
real recorded speech through the real gate and floor (`--turn-test`), the time
from a person starting to talk to being on the wire **when taking the turn**
fell from **395–547 ms to 101–112 ms**, and to **0 ms** for the end that was
not being talked over.

- **Any voice takes an empty floor.** Every vocalisation begins life classified
  as a continuer, and the classifier needs 700 ms to call it a bid. "A
  backchannel does not take the floor" was written when a pause still
  transmitted; under strict's silent pause it meant the first 700 ms of every
  sentence was dead air. From `idle` there is nobody to protect, so the first
  block of any voice takes it. An "mm-hm" over somebody who *holds* the floor
  still does not move it — that is what the rule was actually for, and it is
  asserted both ways. `Floor.Cfg.idleTakesAnyVoice` is the control arm.
- **A fast "voicing now" bit crosses the wire** (`ST_VOICING`, 120 ms
  hangover) beside the cue, which carries a 450 ms one so a breath between
  words cannot end a turn. One bit was answering two questions: the drawing
  needs the hangover, the floor must not have it. Older builds leave it clear
  and behave exactly as before.
- **The holder's own audio going silent is the fastest witness of all.** It
  needs no cue, no hangover and no protocol — the listener is already playing
  that stream. 60 ms of silence in it, while somebody at this end is talking,
  releases the floor. And the same silence is no longer charged for twice: a
  release proven by either witness no longer waits a further 120 ms.
- **A microphone whose own speaker is closed is no longer suppressed.** The
  level-based echo suppression was still attenuating a person the floor had
  *already* put on the wire — measured as a speaker holding the floor, floor
  gain 1.0, and inaudible because the echo gate held them at zero. Worst for a
  quiet voice far from the mic, which is where it was reported. It relaxes only
  once this machine's speaker is shut, which is the strongest form of the
  argument: no acoustic path, so nothing arriving can be echo. The classifier's
  echo test is untouched — deciding whether a sound may *claim* the floor still
  needs it, and the correlation veto still sits beside it.

Live calls now report `turn_onset_to_wire_p50` and `turn_onset_lost`: the old
`turn_to_floor_p50` started counting only once the gate had already decided a
voice was a bid, so it read 0 ms through the very call this was reported on.

### Fixed — the edge you were told to feel, but had to look for

"Really hard to spot, and you have to constantly look at them... you should
FEEL, yes, your voice is going through. Maybe a thicker bar." Width is now the
channel: speaking, the stroke is 4.5–8 pt and moves with your own syllables;
listening, a calm 3 pt; nobody's turn, the original hairline. Fast to widen (a
first syllable is news), slow to narrow (a breath must not flutter the frame).
Still no glow, no shadow, no gradient, and nothing painted over the picture —
that refusal stands, and `glass-check` still passes.

### Fixed — the microphone trim regulated to the loudspeaker

Both ends of the 14:22 call sat at the trim rail (0.17 and 0.06, i.e. −24 dB)
with a person underneath tuned toward inaudibility, and 0.96.0's persistence
carried the cut into the next call. The trim now learns nothing while the echo
detector says the microphone is mostly this machine's own speaker, walks back
up three times faster when the room is quiet (about fifteen seconds instead of
minutes), and a stored trim is floored at 0.3 on load — a deeper one is more
likely last call's loudspeaker than this microphone.

### Fixed — `--turn-test` was measuring a room the product never builds

Three rig faults, each of which looked exactly like a product defect. It fed
the far-end reference as one RMS per block where the app feeds a per-sample
peak envelope, understating it by the crest factor of speech, so the echo bar
sat four times too low and each end classified the other's echo as its own
voice — that alone reported 35% of a speaker silenced. It injected room echo
into a microphone whose speaker the floor had closed, so a holder heard itself
and claimed through its own silence for 8345 consecutive blocks. And it ended
an "utterance" at the first quiet 0.33 ms block, counting 201 glottal periods
as 201 late sentences. It now also runs soft and strict as separate arms judged
on what each one promises, prints the pre-0.98.0 rule beside the new one, and
fails if that arm is *not* measurably worse — a ruler that cannot see the
defect it certifies is worth nothing.

## Kin 0.97.0 — 2026-08-31

### Fixed — closing a window before the call connected told nobody

"Close keeps the call" is a promise about a call that exists. Before the
transport locks there is nothing to keep, and the red button told nobody:
closing a "Calling…" window never cancelled the ring, and closing an
answered-but-not-yet-connected window left the caller on "Calling…" until the
no-answer timeout. Measured live (call `244yp0liz2dio`): the callee answered
at 13:57:14, closed the window at 13:57:15, and the caller transmitted
2.4 Mbps at a dead socket for two minutes with `opened` frozen at 50.

A pre-connect close now sends the same mailbox bye a decline sends — the
caller gets the ordinary "can't talk right now" card within a poll. To make
that possible the answered image finally knows WHO it was answering:
`--with <handle>` rides the answer re-exec (`--incoming` is an event and
rightly dies there; who the room is shared with is a property of the room),
and is stripped at every later re-exec so a fresh room can never inherit an
old name. A connected call keeps today's behaviour: close, reopen, walk back
in. `calling-check` grew the two arms: closing a Calling… window cancels, and
closing an answered-unconnected window tells the caller.

## Kin 0.96.0 — 2026-08-31

### Fixed — a cancelled call rang on at the other end

Measured live (calls `odfvn792xwxx` → `jqgqxwt6jn6l`): the caller cancelled,
the mailbox was told instantly, and the callee rang on — the cancel landed
**6.8 s after the ring**, and an earlier one was drained by a copy of Kin that
was not showing that ring and dropped ("hung up on a call this Mac is not on —
ignored", in this repo's own logs). Four fixes, one per hole:

- **A second app copy no longer polls the mailbox.** The drain is destructive;
  two copies ate each other's messages, spent the shared arming budget, and
  crowded the four held-poll slots. A copy that does not win the line now
  waits behind the holder exactly like the watcher does, and inherits it
  within a second of the holder dying.
- **A drained bye that this copy cannot use is written as a cancel note, never
  dropped** — the app-side twin of the watcher bug `cancelrace-check` exists
  for. And **every ringing copy now watches for notes**: the 4 Hz note timer
  only existed on the watcher-launched path before, so the resident path had
  a writer and no reader.
- **The line lock is close-on-exec.** Placing and answering calls re-exec, and
  execv inherits plain fds — the new image carried the old image's flock as an
  orphan it could not see and then waited behind itself.
- **While a ring card is up, the fallback poll cadence is 1 s, not 5.** A
  cancel is only ever sent during a ring; bounded (rings last ≤ 45 s) and rare
  (held polls remain instant when the server holds). `ring_poll_slow` /
  `ring_poll_fail` now count the fallback itself — a Mac answering cancels
  late is no longer indistinguishable from a healthy one.

### Fixed — a ring at an open Kin showed a name, never the caller's face

The `--incoming` image the watcher launches shows the caller's live video on
the ring card before anybody answers (`ringpicture-check`, still green). A
ring that arrived at an **already-open, idle** Kin drew its own card in-process
— no preview join, no face, and none of the cancel-note machinery. An idle,
room-less copy now re-execs into exactly the image the watcher would have
launched: same argv, same rig coverage. A copy in a room, in a call, or
already ringing keeps the in-process card — consent must not tear down what a
person is looking at.

### Added — one location fix per connected call

For the launch phase: calls will happen from other people's Macs, and latency
numbers mean nothing without the distance they crossed. When the transport
locks on a real call — never at launch, never for a ring preview — Kin asks
CoreLocation once, at kilometre accuracy, and writes `geo_lat`/`geo_lon`
(2 decimals ≈ 1.1 km) and `geo_acc_km` to the beat; a denial writes `geo_err`
instead, so "no number" and "never asked" stay distinguishable. The telemetry
summary gains a `WHERE` line per end and a `RING` line that names what stopped
a ring and how late the cancel landed.

## Kin 0.95.0 — 2026-08-31

### Changed — the floor is strict: one microphone, one loudspeaker, never the same end

The user's decision, verbatim: "only one mic is enabled at any given moment in
time, and only one speaker is enabled, and it can't be the same person's."
The turn machinery is unchanged — who holds, who releases, the deadlock break,
the predictor, the ceiling — but its verdict is rendered without the soft
edges 0.94.0 still had:

- Out of turn is **silent**, not ducked at −20 dB. A barge-in crosses as a cue
  and flips the floor; until it flips the interrupter is not heard.
- A pause transmits **nothing**. The first voice takes the floor locally in
  its own block, so the first speaker still pays nothing.
- A dead cue channel **holds roles** instead of opening both mics. The holder
  keeps talking on its own evidence; a blind holder reads as quiet and the
  listener takes the empty floor in `releaseMs` (survivor of a dead peer
  speaks 9 ms after asking, in the self-test).
- The holder's **speaker is closed on every route**, headphones included.

The two-end self-test, with the network hop modeled at 40 and 100 ms, measures
0 ms of double-open in clean alternation (soft: 200 ms), one hop at a barge-in
(40 ms), and deadlock-plus-hops at a genuinely simultaneous start (480 ms) —
the one window physics keeps. Every live call now reports `floor_strict` and
`strict_overlap_pct` (on the wire while the far stream also carried voice),
and each strict scenario has a soft REJECT twin so the meter is proven able to
see the defect it guards. `--floor-soft` is the control arm and is exactly the
0.94.0 behaviour, kept for A/B on live calls and as the rollback that needs no
reinstall.

## Kin 0.94.0 — 2026-08-31

### Fixed — the listening end's own speaker was classified as its person talking

Measured on the first two-room 0.93.0 call (pair `8q0nwcduogm2`): the listening
end sat alone with a healthy microphone and its voice gate was **open 97% of
the call** — the only sound in that room was its own speaker. The level test
cannot win there by design ("suppress less rather than gate somebody"), so the
leak was classified a bid, and the floor answered with the −20 dB *duck*
instead of the mute. A faint copy of the talker's own voice came back for the
whole call. Echo correlation peaked 0.62/0.65 at the two ends.

The echo detector already computes the evidence the level test lacks: a
normalized correlation between this microphone and this machine's own playout
(unrelated speech ≈ 0.26, a real echo lock 0.65–0.76, every 500 ms). While it
reads ≥ 0.45 — the same number the telemetry has always called "speaker fed
the mic" — the classifier now refuses to call that sound a voice. No cue
crosses the wire, no claim takes the floor, the idle guard is no longer
bypassed, and the floor mutes fully instead of ducking. The veto is withdrawn
the moment a computation stops saying "echo" — a real voice wins it back
within one tick of dominating the microphone — and a computation older than
1.5 s clears it, so silence cannot gag the first word after it. Samples it
kills are counted (`a_corr_veto_pct`); `--no-corrveto` is the control arm.
The gate self-test reproduces the leak with a swinging room coupling and must
see the defect with the veto off for the fixed arm to mean anything.

### Fixed — the cue heartbeat had zero margin against the staleness limit

The floor stops believing far cues 1000 ms after the last one, and the probe
carrying them settled to exactly one per second. One late or lost probe put
the far floor into full-open fallback — both ears open, both mics allowed —
for a second at a time. On the same call the **talking** end ran on fallback
for 20.1% of the call, which is where much of the echo lived. The steady probe
now fires every 300 ms: three fit inside one staleness window, 32 bytes at
3/s against a 3 Mbps call.

### Fixed — a hot microphone re-taught the trim from scratch every call

The software trim converged to its rail (0.11) and the beat still recorded a
post-trim call-max peak of 3.08: the first sentence of every call shipped ~3×
over full scale while the loop re-learned what it knew yesterday. The learned
trim is now kept per device UID (`trim.json`) and applied from the first
sample of the next call; the existing relax path walks a stale entry back up,
so a microphone whose owner fixed its input gain is quietly forgiven.

## Kin 0.93.0 — 2026-08-31

### Added — the far end's turn-end number now crosses the wire

0.92.0 wired the local half: my transcript can release *my* turn early, at a
pause, instead of waiting the full 450 ms of silence. The bigger win is the
other way — knowing *their* turn is ending, so this microphone is already open
before they finish. That number lived only on the speaker's machine. Subtitles
cannot carry it: they only cross when the sender cannot be heard, which is
exactly not the case while they hold the floor.

It now rides the pad byte beside the vocal status (TPKTX+7), on every probe,
and an extra probe fires the moment it crosses the threshold — a prior that
only travelled once a second would arrive later than the wait it exists to
skip. An older build writes 0 there and never reads it, which is the value
that changes nothing, so a mixed-version call behaves as 0.92.0.

A leftover high number at the *start* of their next sentence does not release
the floor. The idle echo guard still shuts a microphone sitting next to a live
loudspeaker after the floor has let go. Both are cases the test is required to
fail when the fix is disabled.

On a live call: `predict_far_releases` / `predict_far_saved_ms` is the far
half, `predict_peer_p_peak` is whether their number arrived at all. Zero peak
on a 0.93 call where they talked is the protocol not landing; zero far-releases
with a high peak is the floor not consuming it. Those used to look the same.

## Kin 0.92.0 — 2026-08-31

### Fixed — the turn-end predictor was read by the floor and assigned nowhere

`Audio.turnEndProb` is read on every capture block by `Floor.step`, which uses it
to let go of the floor early at a pause instead of waiting out the full 450 ms of
silence that ends a turn. Nothing ever wrote to it. It was `0` for the life of
the app, so `predictedEnd` was always false and every turn cost the full 450 ms.

The predictor itself was finished, measured and running — `Subtitles.predictNow`
computes it on every block while somebody is speaking. There was simply no wire
between the value and its stated consumer.

This is the LOCAL half, and it needs no protocol: my own transcript predicts my
own turn ending, and `predictedEnd` is guarded by `state == .mine`, so all it can
do is release the floor early on behalf of whoever already holds it. It can never
take a turn from anybody. The other half — knowing the FAR end's turn is ending,
so this microphone is already open when this person starts — is the larger win
and needs the number to cross the wire beside the vocal byte.

### Added — telemetry that can answer "is the echo gone" without guessing

Every fix of the last two days is now countable on a live call, because the last
three echo theories all survived by being unmeasurable:

- `echo_guard_pct` / `echo_guard_idle_pct` — how much of the call the new idle
  guard muted a microphone, and how much of the call it could have. "It fired and
  did not help" and "it never fired" are different bugs and used to look the same
- `predict_releases` / `predict_saved_ms` — turns handed over early, and the
  milliseconds of the 450 ms rule that saved
- `playout_rms` — whether this machine's loudspeaker was actually making sound
- and `tools/telemetry.sh` prints them grouped by question, saying plainly when a
  field is missing because the call ran on an older build

## Kin 0.91.0 — 2026-08-31

### Fixed — 0.90.0's echo guard could re-gag the person it had just rescued

Found by being asked "so is the echo gone 100% of the time", which is a better
question than it looks: it forces you to name the paths still open, and one of
them turned out to be one I had made an hour earlier.

The floor has a ceiling on being held down — if this end has been talking and
suppressed for 1500 ms, whatever it believes about the far end is wrong in the
one direction that costs somebody their sentence, so it releases. That release
sets `idle`, and it runs at the very END of the decision, after the block that
would otherwise have made the floor `.mine`. 0.90.0's new guard then saw `idle`
plus a live loudspeaker and muted the microphone again — taking back the exact
sentence the ceiling exists to give.

The guard now applies only while this end is silent, which is what an echo
measure means and what a gag does not. A listening noise — "mm-hm" — is left
alone too: it is the thing the other person is listening for, and it does not
take the floor.

## Kin 0.90.0 — 2026-08-31

### Fixed — the echo was living in the state the floor had no opinion about

Reported again after 0.84.0, on a call where both ends ran 0.89.0. The floor
instruments added in 0.84.0 are what found it — the first release where this
question could be asked at all:

| | floor muted the mic | ran on the local gate | echo peak | mic open |
| --- | --- | --- | --- | --- |
| one end | 22% of the call | 0.03% | **0.81** | 99% |
| other end | 38% of the call | 5.5% | **0.72** | 99% |

Both ends were muting, both were believing each other's cues, and the echo was
still there. The missing 40% is `idle` — nobody's turn. It is reached by "the
holder went quiet for 450 ms", which is every pause between two sentences, and
in it BOTH ends may transmit and BOTH ears are open. That is not a turn-taking
state; it is a closed loop with a microphone sitting next to a live loudspeaker
at each end, and a call spends about two fifths of itself there.

So in `idle`, a microphone next to a live loudspeaker no longer transmits. The
floor is told the FACT — is this machine's speaker emitting anything right now,
measured on the render thread where the samples are — rather than being left to
infer it from whose turn it is, which is the belief that was wrong. 150 ms of
tail after the speaker falls quiet, because a room keeps returning the last
syllable for a while.

It costs nothing in a conversation. The instant this end actually speaks the
floor is already `.mine` and the guard does not apply, so barging in works
exactly as before — the classifier reads the microphone before the gate mutes
it. Headphones are untouched, because there is no echo path to close.

Measured on a loopback pair: the share of the call the microphone is muted for
the other person went from 22% to about 50%.

## Kin 0.89.0 — 2026-08-31

### Changed — the repository catches up with the app

Thirty-nine tags, no releases page, and a changelog that ended fifteen releases
before anything anybody is running. `release.sh` publishes the GitHub release
now, not only the tag, with notes lifted from this file's section for that
version so there is one place the story of a release is written. It can never
fail a release: by the time it runs the release has shipped and been verified.

The secret scanner also learned about `AGENT_KEY`, the operator read credential
added in 0.83.0 — a scanner is only evidence for the patterns it carries, so it
is in the calibration fixtures too, planted and required to be found.

## Kin 0.88.0 — 2026-08-31

### Fixed — macOS killed the background watcher once after every update

Every self-update filed exactly one crash report: `EXC_CRASH (SIGKILL (Code
Signature Invalid))`, `Termination: CODESIGNING, Launch Constraint Violation`,
67 ms after launch, parent `launchd`. KeepAlive retried and the second attempt
worked, so the Mac always ended up current — which is why it survived four
releases. "Recovers on its own" and "nobody has looked" draw the same graph.

Reproduced on a real machine, and the first two theories were both wrong:

| what was done | result |
| --- | --- |
| kill the watcher, no swap | relaunches cleanly |
| swap in a **byte-identical** copy, then kill | relaunches cleanly |
| swap in a validly signed copy with a **different cdhash**, then kill | **refused, once** |

So it is neither a race nor the swap. launchd holds a job to the code identity
it was *bootstrapped* with, and the first launch of a different one at that path
is refused. The designated requirement never changes — `identifier
"com.tokkah.tk" and certificate root = H"…"` — but the cdhash moves every
release, and that is what is pinned.

`Watch.reregister()` now tells launchd rather than letting it find out. The
ordering is the whole risk: the updating process *is* the job, so a bootout
kills it before it could bootstrap, and a bootout never followed by one leaves a
Mac unable to answer a call until the next login. The work is handed to a
detached `sh` that outlives it; every path through that script ends in a
bootstrap attempt, verified with `launchctl print`, retried five times, with
`kickstart -k` as a last resort so no Mac is left with no job at all.

## Kin 0.86.0 — 2026-08-31

### Changed — Kin checks for a new version when you open it, restart, or start a call

A cadence is a guess about when somebody will next care. The moments they
actually care about are knowable, and they are also the moments a stale build
shows, because the far end of the call is running a different one.

- **on open** — at once, rather than ten seconds later
- **on restart** — the watcher's first check was 60 s ("no hurry at login"),
  true at login and wrong every other time it starts: after an update, after a
  crash, whenever the binary moves underneath it. Two seconds now
- **on a call** — when the far end actually arrives. Not a licence to restart:
  anything found is held until the call ends and said on screen

The ten-second launch grace was never about the network. It existed because a
call is not "live" during setup, so an update found immediately would restart
the app while somebody was still reading their invite link. That wait moved onto
the *install*, which is what it was always protecting.

**And one thing this broke, caught by the rig.** "Urgent" meant two things, and
the second is about a person: the Check for Updates menu item is owed an answer
whatever happens, including "could not reach the server". Reading "a person
asked" off that flag was true while the menu was the only thing setting it — and
the moment opening the app checked too, every launch on a flaky network put
"couldn't check for updates" on somebody's status line.

## Kin 0.85.0 — 2026-08-31

### Fixed — hanging up ended the call *and* closed Kin

`leaveCall` was `exit(0)`, from when a call and a process were the same thing.
Closing the window had already stopped meaning "hang up"; this was the other
half of that correction, left behind. What stays on screen afterwards is the
screen Kin opens with — a fresh room, waiting, with its link — because that is
this app's idle state; a double-click starts a call.

### Changed — Macs pick up a new version in five minutes, not thirty

The update poll was 1800 s. The second Mac in the house sat on 0.82.0 while the
first ran 0.84.0, reported as "the update mechanism is not working". It was
working, half an hour behind — and half an hour behind is indistinguishable from
broken to the person waiting, especially when two Macs on one call disagree
about what the app does. Note that the poller doing the work is the version
already installed, so a cadence change takes effect one release later.

## Kin 0.84.0 — 2026-08-30

### Fixed — a microphone five times too loud, which was causing the echo *and* the cut-off voices

Reported as two problems — an echo across different rooms, and one person's
continuous speech being chopped up. One fault. From the call's own telemetry,
both ends:

| | mic peak | clipping | RMS | echo peak | mic open | gate flaps |
| --- | --- | --- | --- | --- | --- | --- |
| one end | **5.24** | 1.6% | 0.263 | 0.71 | 98% | 56 |
| other end | 0.85 | 0% | 0.031 | 0.52 | 90% | **409** |

Full scale is 1.0. `tuneInputGain` saw peaks of 1.40 and 1.03, walked the device
from 27% to 15%, and stopped: 15% was the floor written into it. It moved twice
in two minutes and never said it had given up.

A microphone that hot hears its own speaker — the loop is inside one laptop,
speaker about 15 cm from microphone, so being in different rooms does not help —
and it holds the local voice gate open, so the near mic is live while the far
person is talking, and their end chops its way through hundreds of gate flaps
trying to take a turn against it.

- the back-off is proportional to the overshoot now, not a fixed step
- a software trim at capture, which no hardware floor can block, decided
  *before* every device guard — it used to sit below them, so a microphone with
  no settable volume, the case that needs it most, could never reach it
- samples above 1.0 are not clipped: the float path carries them intact, so
  dividing recovers the signal exactly, with no limiter and no colour
- it comes back up when the room quietens, or one shout would be permanent

### Added — the floor's own numbers, and echo as a peak

`floor: yours N%` is named for the floor and does not measure it: it counts the
local voice gate. `one-at-a-time:` now prints on every call what share of it the
floor actually muted the microphone, and what share it had fallen back to the
local gate. Echo is recorded as a **peak** — the final beat of a call that
reached 0.71 read 0.04, so every summary built on the last value said "no echo"
about a call with a measured one.

## Kin 0.83.0 — 2026-08-30

### Added — every call keeps a copy of its own numbers on the Mac

The beats existed in exactly one place: a server behind a key that lives in a
browser cookie on one machine. So a real complaint about a real call was
investigated out of a stderr log, because the telemetry built to answer exactly
that question could not be opened. Every beat is now appended to
`~/Library/Logs/Kin/beats.ndjson` *before* it is posted — a beat that fails to
send is exactly the one worth having — and `mac/tools/telemetry.sh` reads either
the local copy or the server.

## Kin 0.82.0 — 2026-08-30

### Fixed — two Kin icons in the Dock, and clicking Kin opening another copy

Three faults, one after another, all in how a Dock click is answered.

**`pid -1` is a live Kin, not a dead one.** Kin re-launches itself a quarter of a
second after opening (`execv`), which keeps the window but makes macOS lose track
of the process: its record reads `pid -1` for the rest of the call. Reading that
as "still running" meant clicks did nothing; reading it as "gone" meant a new
copy on every click. Neither reading is right, so the question is answered from
the process table now, filtered by argv — the watcher and the ring watcher are
the same binary, and bringing forward a process with no window is a click that
does nothing. To raise it, the app is asked to raise *itself* (SIGWINCH, whose
default action is to do nothing, so a copy older than the handler ignores it;
SIGUSR1 would have hung up on a live call).

**The second icon was the watcher.** It is meant to be invisible, and two things
undid that silently: after an `execv` the call that hides it fails, and answering
a reopen promotes the process. It is re-asserted every tick now — a state that
repairs itself needs no list of everything that might break it.

Three traps found on the way, all worth reusing: `kill(-1, 0)` returns 0 because
it asks about *every* process the user can signal; `URL.resolvingSymlinksInPath`
left `/tmp/…` where the kernel reports `/private/tmp/…`, so the scan matched
nothing; and the raise handler was first installed at the foot of a file that a
call with a window never reaches — it compiled, read as finished, and ran zero
times.

## Kin 0.76.0 — 2026-08-30

### Changed — 12% less CPU for the same call, and a way to see the cost at all

## Kin 0.75.2 — 2026-08-30

### Fixed — a Dock click opened *another* Kin

The watcher registers as `com.tokkah.tk`, so every Dock click, Finder
double-click and Spotlight hit resolves to it and arrives as a reopen. Its answer
was an unconditional new instance, so ten clicks were ten copies of the app, each
with its own window, camera and microphone. Nothing asked whether Kin was already
open. (Answered incompletely here; finished in 0.82.0 above.)

## Kin 0.75.1 — 2026-08-30

### Fixed — the camera aborted the app when a call was answered

## Kin 0.75.0 — 2026-08-30

### Changed — green is speaking, blue is listening

Also: the Mac mini's camera was choosing 10 fps.

## Kin 0.74.0 — 2026-08-30

### Added — the floor, wired: a mute for a microphone nobody is talking into

## Kin 0.73.0 — 2026-08-26

### Fixed — two instruments that reported the opposite of the truth

Both found by checking a shipped build rather than trusting it, and both are
the same fault: a second copy of something, which then drifted.

**`--audio-route` said `vp` on a build that runs `hal`.** It recomputed the
rule -- `ioPinned ? ioKind : (speakers ? "vp" : "hal")` -- right next to the
block that actually decides it. When 0.72.0 changed the default from
VoiceProcessingIO to the plain path, calls changed and this did not, so the
tool built to answer "which path will this call take" answered the opposite,
on a machine already running the new build. It reads `Audio.ioKind` now, the
same value the audio engine reads, and it names the floor and the switch time
so the answer is checkable rather than just reassuring.

Two functions answering one question is how `reach()` and `status()` disagreed
for twenty hours in this same codebase.

**`/api/mac/macs` reported `stage: null` for every Mac.** Every beat carries
`facts` and `events` as their own objects; the view read `update_stage` flat,
so it was always `undefined` — while the beats it was reading had the stage in
them the whole time.

The test did not catch it because the test invented its own beat, flat, and so
tested the reader against a shape no client sends. It uses the real nested
shape now, and restoring the flat reader fails exactly those two assertions.

With both fixed, the fleet view answers the original question on sight: the
MacBook Air on 0.72.0 heard from 3 minutes ago, the Mac mini still on 0.71.0
and not heard from in 72 — two missed check-ins, which is asleep or a stopped
watcher, and either way now visible instead of invisible.

## Kin 0.72.0 — 2026-08-26

### Changed — one at a time, properly this time

0.71.0 answered the echo with Apple's canceller. The decision is the other way:
**whoever is not speaking is muted outright, and whoever is speaking is heard
raw** — plain hardware path, no cancellation, no noise suppression, no automatic
gain. The green edge and the subtitles are what make that liveable: they say
whose turn it is, so a quiet moment reads as "they are listening" rather than as
a fault.

That is what the duplex gate was always for. It was just never doing it.

**The floor was never the limit — the ramp was.** Closing was an exponential
decay with a 35 ms time constant, and an exponential approaches its target
asymptotically: reaching a real mute needed about fourteen of them, roughly
240 ms of unbroken far-end speech. Speech does not hold still that long, so the
gain never arrived. Proved by sweeping the floor and watching the answer stop
moving:

| asked | −6 dB | −22 dB | −60 dB | −120 dB |
|---|---|---|---|---|
| achieved | 5.9 dB | 19.3 dB | **23.6 dB** | **23.6 dB** |

Closing is a **timed linear ramp** now, so it reaches the number it was given in
the time it was given. Same test, same room, floor unchanged: **23.6 dB →
37.9 dB**. Fourteen decibels, a factor of five quieter.

**And the switch time was swept, not guessed**, because in a half-duplex call
the switching speed is the whole experience:

| close | 1 ms | 2 ms | 4 ms | 8 ms | 16 ms | 32 ms |
|---|---|---|---|---|---|---|
| suppression | 38.0 dB | 38.0 | 37.9 | 37.7 | 33.9 | 27.3 |

A plateau to 8 ms and a cliff after it. The default is **4 ms** — the fast end
of the plateau, giving up 0.1 dB for the quickest switch available, and still
several times longer than the ~1 ms at which a gain step becomes an audible
click. Opening keeps its 1 ms exponential: that direction protects the first
syllable of an interruption and was never the problem.

Your own voice is still bit-for-bit what the microphone heard (worst sample
differs by 0.0001%), and the deadlock duck is untouched at −9 dB.

`--io vp` still runs the full VoiceProcessingIO path, `--gate-floor` and
`--gate-close-ms` tune this one, so the two are A/B-able on a real call rather
than argued about.

## Kin 0.71.0 — 2026-08-26

### Fixed — the echo, which every call has had since the first one

Reported as echo on both ends, "ear deafening". The telemetry had been saying
so all along and nobody had asked it: across every reported call `aec_on` was
**0** and `output_route` was **speakers**. Nobody has ever been on headphones,
so the acoustic path from speaker to microphone was open on both ends of every
call this app has ever made, with nothing behind it.

The duplex gate was what stood in for a canceller, and the comment above
`ioKind` already admitted the hole: it "only ever acts while the near end is
NOT speaking", so "echo during double talk is not solved by this and is the
honest gap". Two people on speakers is that gap. And in the field the gate was
not even winning the easy half — `floor_held_pct` is **85–99.7% on both ends**
of every call over 15 s, so neither side was ever gated, with `turn_collisions`
reaching 39 in a four-minute call.

The route decides now, because the route is what makes the echo:

| output | audio path | why |
|---|---|---|
| speakers | `VoiceProcessingIO` | the unit FaceTime uses; real cancellation |
| headphones | `HAL`, unchanged | no path back to the mic, so nothing in the way |

**Measured, not argued.** New [mac/tools/io-ab.sh](mac/tools/io-ab.sh) runs both
ends locally, four arms in alternating order so machine drift cannot read as an
effect, and asserts each arm ran the unit it is named after. The canceller costs
**+7.61 ms** mouth-to-ear against **4.23 ms** of rig noise — 1.8× the noise, so
real — landing in device latency (mic 1.88 → 4.21 ms, speaker 2.58 → 4.92 ms).
Against a 150 ms budget and calls currently at 19 ms, that is the cheapest fix
available for a call nobody can hold.

`--io hal` still pins the old behaviour; `--io vp` pins the new one. New
`--audio-route` answers which way a call will go **without starting one** —
every previous way to find out ran `tk` with no `--room`, which joins a loopback
peer and opens the microphone.

### Added — telemetry for the stages that had none

The updater recorded **nothing**: 0 `Metrics.` calls in 1200 lines. The only
machine-readable trace of an update was the version changing on the next call
somebody happened to make, so a Mac that updated late and a Mac that made no
calls looked identical — the exact pair that had to be told apart. There is now
an `update_stage` fact (current, offered, downloading, staged, held-for-call,
blocked, installed, unreachable, bad-signature, download-failed), counters, and
`installBlocker`'s reason on the wire.

The background watcher now files a **210-byte** beat on every update check, so a
Mac reports 48 times a day whether or not anybody calls on it. `phase: "watch"`
is a real third phase server-side, kept out of the call listings. New
`/api/mac/macs` gives one row per Mac: last seen, version, update stage, blocked
reason.

The join had one mark for five phases, so a 2.5 s p50 was a total with no parts.
Now `stun_ms`, `peer_found_ms`, `turn_ms`, `turn_blocked_ms`, `join_polls` — and
they immediately refuted the first theory they were built to test. The 20 s TURN
barrier above the media loop looked like the cause; measured, `turn_blocked_ms`
is **6 ms** (TURN finishes at 323 ms, the peer is not found until 336 ms). They
also showed `connected_ms` is two numbers wearing one name: split by role, the
callee is **p50 2482 ms** — the reported "2–3 seconds" — while the mixed figure
of 3127 ms was inflated by callers counting the seconds the other person took to
pick up.

### Fixed — analytics that cost latency would be a defect, so it is enforced now

`Metrics.swift` has always said nothing there may lock on the audio path — the
SIGSEGV that ended live calls came from a Swift collection touched by the audio
thread. What kept it true was everybody remembering, which is a habit and not a
property. The render callback identifies its thread once, and `tap`/`mark`/
`count`/`fact` now return **without taking the lock** when called on it.
`tel_hot_refused` rides out on the beat, so a mark added to a hot path in future
is a number rather than an unexplained stall. Zero on every build today.

### Fixed — a rig could not be isolated from the production directory

`TK_NO_IDENTITY` was declared 260 lines below the `--watch` block, and
`Watch.run` returns `Never` — so the guard was unreachable from the one process
whose job is claiming a handle. A watcher rig walked @devesh through @devesh9
against the live server on every run. Guarding the call sites was not enough
either: the watcher's own site was correctly skipped and a different path still
reached the ladder. The guard is now inside `Identity.claim()`, where nothing
gets past it.

## Kin 0.70.0 — 2026-08-26

### Fixed — a Mac that stopped answering calls, and never said so

Reported as "I was calling from the Mac mini and this MacBook Air did not show
the call, both on the latest version". It was neither the versions nor the
network. Three separate faults, and the second is the one that made it last
twenty hours.

**The doorbell had been dead since the previous evening.** Kin's login agent is
what answers a call while the app is closed. It exited cleanly at 20:03, moments
after handing a real incoming call to a fresh Kin, and `KeepAlive
{ SuccessfulExit: false }` told launchd that a clean exit meant it had finished
on purpose. So launchd did nothing, and every call after that rang into an empty
house. This is the SECOND outage from that one policy — the comment above
`ringLoop` records the first, where a startup race let the agent exit 0 before
the handle claim landed and "the Mac was then uncallable until the next login, on
the very first launch, silently". That instance was fixed by deleting that exit.
The policy was left alone, so the class survived. It is fixed at the policy now:
launchd restarts the agent whatever happened, and the one exit that genuinely
means stop — **Quit Kin** in the menu bar — boots the job out of the login
session rather than picking an exit code and hoping the policy still reads it
that way. The asymmetry is the argument: an unintended clean exit costs every
incoming call until the next login, and an unnecessary restart costs one process.

**The app kept telling itself it was fine.** `Watch.reach()` — the single
function behind "can people reach you with Kin closed", read by the settings row,
the permissions check and the startup line — decided that from whether
`launchctl print` EXITED 0. It exits 0 for a job that is merely registered,
including one that ran, exited and was never restarted. Calibrated on a
purpose-built control: an agent running `/usr/bin/true` reports `state = not
running`, `runs = 1`, `last exit code = 0`, and `launchctl print` still exits 0.
So every screen said "reachable" for twenty hours, and the telemetry fact
`reachable_closed` recorded **yes** throughout. `status()` twenty lines below had
it right all along by reading `state = running`; the function everybody actually
calls did not. It now reads the same line, offers a repair the app can perform
by itself (`launchctl kickstart`, no consent needed — the login item is already
approved), and `--watch-status` prints the verdict the app itself acts on rather
than computing a second, similar answer that can drift.

**And the caller was told nothing.** `/api/kin/<who>/ring` answered
`{ok: true, queued: 1}` whether the callee's Mac was waiting or had stopped
listening the night before, so the Mac mini showed a ringing screen with nobody
on the other end. The server is the only party that can know this. It now says
so, from **last-heard-from** rather than from whether a socket is held — this
project already learned that ghost sockets outlive their processes — and with
three states, not two: `listening` is **omitted** when a freshly woken Durable
Object has heard from nobody, because "they are offline" is not a thing to guess.
Kin shows it on the outgoing card, carried across the re-exec as a flag: a status
line written immediately before `execv` is drawn by a process that is about to
stop existing, which is a message nobody can read.

New: [mac/tools/doorbell-check.sh](mac/tools/doorbell-check.sh), 10 assertions,
in CI. It asserts the calibration itself — that `launchctl print` really does
exit 0 for a dead job, because if it did not, the original code would have been
correct — and it has a live-agent control, so it cannot pass by always answering
"not reachable". Where there is no launchd session it prints a SKIP that says
plainly that nothing was checked.

### Fixed — three defects in the rig that was supposed to prove the above

Found by running it against the tree it was written to protect, which is the
only way any of this surfaced.

It **tested whatever was lying in `.build`**: the gate was `[ -x "$TK" ]`, and
existence is not currency. The debug binary was nine hours older than the fix,
so the rig reported FAILED (5 of 8) about a program nobody is shipping — and it
could as easily have reported PASSED. It builds the binary itself now, then
checks the timestamp anyway (`swift build` can succeed without relinking) and
refuses to print a verdict if any source is newer, naming the files. Calibrated
by backdating the binary: exit 2, sources named.

It **built its dead job with the fixed policy**. `write_plist` hardcoded
`KeepAlive true`, so the scenarios needing a registered-but-dead job were asking
launchd to restart the thing they wanted dead; they had only ever passed by
landing inside a 30 s `ThrottleInterval`. The policy is a parameter now.

And it **asserted the wrong repair**: for an old-shape plist `fix=install` is
right and `fix=restart` is not, because restarting puts the same policy back in
charge and the Mac is deaf again by morning. Now split into 2a (old policy →
rewrite the plist) and 2b (new policy, parked in `spawn scheduled` behind a 300 s
throttle → just start it). 2b is the state every Mac is in after this release,
and nothing covered it before.

### Fixed — the download page named no macOS version, and no licence

The OS floor is written down in four places. `Package.swift` builds
`.macOS(.v14)`, the binary's `LC_BUILD_VERSION` says `minos 14.0`, and both
plists say `14.0`; `release.sh` already proved those three agree **with the
binary** rather than merely with each other. The fourth copy is the web page and
nothing checked it. `/kin` advertised "macOS 13+" for weeks after the build moved
to 14, and `/macos` — the page the install instructions actually link, seven
references to `/kin`'s one — named no floor at all. That is the same failure with
nothing to read: a Mac on 13 downloads the .dmg, launches it, and dyld refuses
the binary. That page also carried no licence anywhere, on an AGPL project, at
the exact spot where the download happens.

`release.sh` now checks every page that tells a human the number, against the
binary, and a page that stops mentioning the floor fails too — silence is the
failure that just happened. Calibrated on four inputs: correct pages pass, a page
regressed to 13 fails, a page gone silent fails, an unreadable binary refuses to
report.

### Fixed — the embed loaded the download page instead of the call

`embed.js` pointed its iframe at the bare room URL, which now answers with "Join
on Kin" — a 14 KB page whose job is to send a visitor to the app. So every site
embedding a call got a download prompt in the frame. It appends `web=1`, the
escape hatch the worker already documents, and the frame loads the 55 KB call
again. Verified against production, not against the deploy log.

Also fixed while here: the source-reading gate in `contacts.test.mjs` counted
`queued:` inside comments, so documenting this outage above the code failed the
test that documents it — comments are stripped before counting now. And the
guard on exported constants only knew about strings: `export const
KIN_LISTEN_MS = 90_000` made workerd refuse to boot outright ("not of type
'function or ExportedHandler'"), caught only by the real-workerd section. It
refuses every primitive now, in a fast test.


### The open-source audit, 2026-08-26

The previous [OPENNESS.md](OPENNESS.md) scored this project **100 / 100** against
commit `HEAD` — which is not a commit, and by then described a product that had
been replaced. Re-audited properly against `13b85b3`. **The honest score is
88 / 100**, and the twelve missing points are named individually in that file.

What the audit found, in the order of how much it cost a real person:

- **The app could not be pointed at anyone else's server.**
  `https://room.tokkah.com` was written out seven times across six files, so you
  could clone Kin, build it, and the app you built still phoned ours. Now one
  `Server` type with three origins — signalling, updates, invite links — resolved
  from `--server`, the existing environment variables, a `server.json` beside the
  app, or the shipped defaults, in that order. With none of them set, every
  origin resolves to the byte-identical string 0.69.0 compiled in.
  [SELF-HOSTING.md](SELF-HOSTING.md) is the walkthrough.
- **The one-line browser embed had been silently rendering a download page
  instead of a call.** `embed.js` builds an iframe pointing at the room, and the
  invite funnel could not tell that frame apart from a person following a link,
  so it handed the frame the "Join on Kin" page. HTTP 200, a real page, no error
  anywhere. Fixed with `web=1` — the escape hatch `worker.ts` already served —
  on the *frame* and deliberately not on the shareable link. This is the third
  thing that funnel has silently eaten; the first two were the cross-planet lab
  room and all five testbed call sites.
- **The download page promised macOS 13.** `Package.swift` says `.macOS(.v14)`
  and `Info.plist` says `14.0`, so anyone on 13 downloaded 1.5 MB of app that
  could not launch. Three places corrected.
- **CI was red on `main`** and had been since the 0.69.0 push. `main` had gone
  thirteen days without a push, so the first one carried the verdict on ~380
  commits. The failing test — the only one that runs the real Worker in real
  `workerd` against real durable storage — had been written the day before
  against a Miniflare API that the pinned version does not accept. **It had never
  passed once.** Ported to Miniflare 5 and then mutation-tested: delete the
  durable write and it fails, restore it and it passes.
- **The flagship had no CI at all.** `ci.yml` ran on Linux and tested only the
  Worker. There is now a macOS job that builds `mac/` and runs twelve offline,
  credential-free self-tests, calibrated by rigging a test to fail and confirming
  the job fails with it.
- **`testbed/freetier-audit.mjs`, cited here as a live guard, had been dead** —
  dying on `JSON.parse` of a JSONC file. Revived, and it was also reporting the
  worker bundle **3.6× too large** by gzipping a 392 KB sourcemap along with it.
  The real figure is 42.3 KiB, 1.4% of the free-plan limit.
- **Two committed `node_modules` symlinks were still in `HEAD`**, dangling in
  every clone since the first commit — after this changelog said they had been
  removed. They survived because `.gitignore` said `node_modules/`, and a
  trailing slash matches directories only, so a *symlink* by that name was never
  ignored. Both removed; the rule no longer has the slash.
- **Zero git tags and zero GitHub releases**, for sixty-nine shipped versions,
  while the scorecard claimed "tagged releases". 17 annotated tags created, one
  for each commit that is genuinely a release.
- **`SECURITY.md` had no reporting instructions**, while the scorecard scored it
  full marks for "private reporting".
- 14 debug screenshots were sitting in the repository root, tracked.

### Added
- **A way to check that a Kin download is really ours.**
  `python3 tools/verify-release.py` verifies the Ed25519 signature over the
  release manifest and the sha256 of the archive. Zero dependencies on purpose:
  macOS ships LibreSSL 3.3.6, which cannot do Ed25519 at all, and the stock
  Command Line Tools `python3` has no CA bundle, so `urllib` fails on a machine
  nobody has set up. `tools/verify-release-selftest.sh` calibrates it first and
  requires a refusal for each of the five ways a release can be wrong.
  The public key is published in [tools/README.md](tools/README.md).
- **`tools/secret-scan.sh`** — scans every commit on every branch, and **plants
  three secrets in a throwaway repository and requires that it finds all three
  before it will scan anything real**. A blind scanner and a clean repository
  produce identical output.
- **`tools/link-check.sh`**, **`tools/reuse-check.sh`**.
- **REUSE 3.3 compliance** — [REUSE.toml](REUSE.toml) and `LICENSES/`, declaring
  every one of 434 distributed files. Declared centrally rather than as a header
  in each file: the opening comment of a source file here is the most-read part
  of this codebase, and two lines of boilerplate above 266 of them buys identical
  rights for a worse read. The identifier is `AGPL-3.0-only`.
- **[GOVERNANCE.md](GOVERNANCE.md)** — one maintainer, said plainly, including
  what happens if he disappears.
- **[CITATION.cff](CITATION.cff)**, **`.github/dependabot.yml`**, and GitHub
  Actions pinned by commit SHA rather than by a movable tag.
- The licence is now named beside the "Source" link on every public page. The
  AGPL §13 source offer was already there; what it did not do was tell a visitor
  what they were allowed to do with it.

### Changed
- **[README.md](README.md) rewritten for Kin.** It had opened with "Live demo:
  room.tokkah.com — open it in two tabs, that's a call" and a `<script>` tag
  described as "the entire integration", roughly 380 commits and one pivot after
  that stopped being true.
- `SUPPORT.md`, `CONTRIBUTING.md`, `SECURITY.md` and `ATTRIBUTION.md` brought to
  the current product; `LAB.md` carries a status note rather than a rewrite,
  because the rig has not been re-run since the pivot and a confidently rewritten
  procedure nobody has executed is worth less than an honest warning.
- Issue and PR templates rebuilt around the Mac app. The bug form had been asking
  which browser.

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
- `tape-app/node_modules` was a **committed symlink** pointing outside the repo
  (`../phase1-transport/node_modules`); it landed dangling in every clone, as did
  `fatigue-lab/node_modules`. **This entry previously said both were removed. They
  were not** — both were still in `HEAD` two weeks later, and a fresh
  `git clone` still produced two broken links. Actually removed now, and the
  reason they survived a deliberate removal is worth keeping: `.gitignore` said
  `node_modules/`, and a trailing slash matches directories only, so a *symlink*
  named `node_modules` was never ignored and could be re-added at any time. The
  rule is now `node_modules` with no slash. The two remaining tracked symlinks,
  `tape-app/public/core` and `fatigue-lab/public/core`, are deliberate and
  resolve in a fresh clone — verified.
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

## Kin 0.69.0 — 2026-08-26

### Added
- **The settings panel says which Kin you are running.** Asked for directly, and
  the reason is not vanity: this app updates itself silently, so the person
  testing it has no way to know which build is in front of them. Two Macs side
  by side on different versions look identical, behave differently, and make
  every conclusion drawn from the pair worthless. It is the first thing to check
  before any comparison and it was on no screen anywhere. Inert, like the
  encryption code above it — a fact about this copy, with nothing to press — and
  last in the panel, because it is the thing you go looking for rather than the
  thing you came here to do. `describeTree` prints the sheet's rows, so
  [mac/tools/watch-check.sh](mac/tools/watch-check.sh) asserts the version on
  screen IS `VERSION` rather than trusting that it is.
  [mac/Sources/tk/Controls.swift](mac/Sources/tk/Controls.swift)

## Kin 0.68.0 — 2026-08-26

### Added
- **Kin notices when both people are in the same room, and stops playing you
  out of two speakers at once.** Reported as "a lot of echo… only one mic is
  active at a time, so that was very confusing" — and it was never a canceller
  fault. Two Macs in one room means the far end's voice comes out of the OTHER
  machine's loudspeaker, which no echo canceller can reach. The signature it
  looks for cannot happen on a real call: **the microphone hears them before the
  network delivers them.** Calibrated before it was wired
  (`tk --sameroom-test`): a remote call scores 0.385–0.426 and one room scores
  0.792–0.901, on two independent sources — a margin of **0.376**. It requires 8
  agreeing estimates out of 20 to act and 2 to release, decides once, and holds
  through people talking over each other.
  [mac/tools/sameroom-check.sh](mac/tools/sameroom-check.sh), 33 assertions,
  including 20 estimates AFTER the speaker goes off — a detector whose evidence
  its own fix destroys is an oscillation, not a feature. `--no-sameroom` is the
  control arm.
- **A thin green line at the edge of the window while your voice is actually
  reaching the other person.** 1.5 pt, steady, no glow — measured 4–20 pt inside
  the stroke at −4.81 against −4.94 at rest, so nothing bleeds inward: it is a
  line, not a light. Dark when muted, dark while the gate is holding you, and
  dark when the OTHER person has the floor — that last one is the control arm,
  because a border that lit for them would say the opposite of the truth. It
  arrives at the instant the gate opens, which is the point: someone interrupting
  is told they are through rather than guessing.
- **A turn-end prior**, from the transcript Kin already produces for subtitles.
  Measured against the reactive rule that ships today, at the same instant and
  the same cost: **false handovers 52% → 12%**, catching 39% of turn ends early.
  Biased that way deliberately — a false "they have finished" arms the gate under
  somebody mid-sentence, and a miss costs a beat the reactive gate still
  recovers. Not yet connected to the gate.
  [mac/tools/predict-check.sh](mac/tools/predict-check.sh).

### Fixed
- **A first install that was refused its name gave up for good.** Asked the
  server for a handle, got `429 {"error":"rate"}`, and stopped — for the rest of
  that launch nobody could call that person and the app never said so. A laptop
  opened before Wi-Fi associates did the same thing, and that is the ordinary way
  this app starts. One condition was answering two questions: "may I take a
  different name" and "should I ask for this one again". It retries the same name
  now, honours the server's own hint, keeps trying for the life of the process,
  and the People panel says which of the three things went wrong in plain words.
- **And pressing Call between two attempts said there was no name.** The wait
  ended the moment the ladder went idle, which after the change above means
  "between passes" rather than "given up". It waits out the caller's budget and
  drives an attempt itself.
- **A warning could kill the app.** `setWarning` was the only setter on the
  control row that did not hop to the main thread, and it touches `NSView` state
  three ways. Every release so far has been one non-empty warning off the main
  thread away from aborting; it survived on a guard that returns early when
  clearing something already clear.
- **Two sentences fought over one warning line and the controls never faded
  again.** "their camera is off" and "you're in the same room" were written by
  two independent owners, once a second each, overwriting each other 150 times in
  one call — and every overwrite re-showed the control row and re-armed its
  stillness timer. The precedence is written down once now, in one place.
- **The breathing rim around the whole window is gone**, along with the dots that
  swelled on the picture. Measured at the window edge, it lit up 6.4× when the
  far end took the floor. Whose turn it is lives in the microphone button's own
  ink instead — full, dimmer, dimmest — with no glow, ring or pulse.
- **Subtitles appear in 33 ms instead of 400**, at full height instead of growing
  into place, and the dead second caption line is gone.
- **The updater failed silently in five different ways at once.** An unreachable
  server, a missing signature, a signature that did not verify, an unparseable
  manifest and "already up to date" were one indistinguishable `return nil`. Each
  says what happened now, and the ones a person can act on reach the window.
  A Mac that cannot write to its own copy of Kin stops re-downloading the release
  forever and says why. `install.sh` no longer moves a new binary over a working
  one before checking it runs — the old one did, **and exited 0 while doing it**.
  [mac/tools/update-check.sh](mac/tools/update-check.sh), 44 → 79 assertions.
- Every `--*-test` run took UDP 7001 before reaching the test, so a test on a Mac
  with a call in progress failed on a bind. They take any free port now.

### Changed
- A rig that could only `stat` the video it needs now reads a byte of it, and a
  turn-end verdict that could not decide a speaker says so on the verdict line
  rather than thirty lines above it.

## Kin 0.67.0 — 2026-08-26

### Added
- **A call ends when somebody hangs up, and at no other time.** Quit Kin
  mid-call, let it crash, let the updater restart it — reopen and you are back
  in the same call, with the same person, without either of you doing anything.
  The call is a fact on disk (`call.json`), and the only thing that deletes it is
  a hang-up at one of the two ends. The far side sees *"they'll be right back"*
  rather than a departure, holds the room, and keeps its lease alive.
  [mac/tools/leave-check.sh](mac/tools/leave-check.sh) now has two endings — a
  kill and a real hang-up — because held and *"the departure detector is dead"*
  draw the identical screen, and one rig ending could be satisfied by either.
- **Crashes report themselves.** If Kin dies on somebody else's Mac we hear
  about it without them filing anything: the next launch finds the report,
  summarises it, and sends it with the call record. 29 assertions in
  [mac/tools/crash-check.sh](mac/tools/crash-check.sh).

### Fixed
- **Two updaters could install an app with 3–9% of its files missing.** Measured
  in 4 of 6 runs, and the dropped tail was `_CodeSignature/` — which is what
  macOS pins camera and microphone grants to, so the visible symptom would have
  been an app that suddenly asks for permissions again and cannot be given them.
  The updater now has a rig of its own: 44 assertions in
  [mac/tools/update-check.sh](mac/tools/update-check.sh).
- **Subtitles are for a voice that cannot be heard, and appear once.** They went
  on the wire whether or not the microphone was muted, the far end drew them, and
  the near end drew them again — so two captions could share one screen, and the
  person shown their own words was the only one in the call who already knew what
  they had said. The decision is the sender's now, because the sender is the only
  end that knows whether its microphone is off, and a voice ducked by the echo or
  turn-taking gate counts as unheard too. Nothing new on the wire, and nothing
  sent at all in the ordinary case.
- **Nothing describes somebody who is not there.** Three things had not moved
  with the change above. A held peer was still being measured, so *"they'll be
  right back"* appeared beside a frozen *"23 ms — breaking up"*. The controls
  stayed faded through a hold, leaving a frozen frame, a pill, and no hang-up
  button anywhere. And `describeTree` pasted the clipboard in raw, so a copied
  URL containing a newline split the diagnostic line and made three healthy runs
  report broken subtitles.
- **The picture comes back with the voice, not a second after it.**

### Changed
- A rig that could only `stat` the picture it needs now reads a byte of it.
  During a machine-level permission outage, `stat` kept working while `open()`
  did not, so two picture rigs ran against a file the app could not read and
  produced 17 failing assertions that all read as product regressions.
- The release's dead-flag gate stopped reading its own comments as flag names.

## Kin 0.66.0 — 2026-08-26

### Changed
- **Transparent glass, and nothing painted on the person.** Every surface is
  `NSGlassEffectView` in its clear style rather than a frosted material, and the
  vignette and every other effect over the video are gone. 32 assertions in
  [mac/tools/glass-check.sh](mac/tools/glass-check.sh), including calibration of
  the instruments themselves against known-blurred and known-opaque references.

### Added
- **Calling someone writes them down.** A person you called appears in your
  people list, not only a person who answered you — and only their name is
  stored. 26 assertions in
  [mac/tools/contacts-check.sh](mac/tools/contacts-check.sh).

## Kin 0.65.0 — 2026-08-25

### Added
- **During a call the window becomes the other person.** Every control fades
  away, subtitles stay, and any input brings the controls back for a few seconds.
  32 assertions in [mac/tools/immersive-check.sh](mac/tools/immersive-check.sh).
- **One click that lands on the pane, not on System Settings.** Each permission
  Kin needs opens the exact panel that grants it. 28 assertions in
  [mac/tools/permissions-check.sh](mac/tools/permissions-check.sh).
- **A Mac that is always on keeps itself current.** The background watcher checks
  for a newer Kin on its own, so a machine nobody opens still updates. The call
  to start that polling sat about 350 lines below a function that returns
  `Never`, so it had never once run.

### Fixed
- **A cancel that arrives while the app is still starting** no longer leaves a
  ring on screen with nobody behind it.
- **The ring card stopped claiming a face it had not seen.** The counter said a
  picture had arrived when what had actually happened was that the card opened.
- The download pages describe the app that exists.

## Kin 0.64.0 — 2026-08-25

### Added — a ring you can see
- **A Mac that is being rung shows you the caller's picture before you answer.**
  It joins the room and receives, so the card that asks the question also shows
  the face behind it. Receive-only, and that is three separate guarantees: no
  microphone is opened, so there is nothing to send and no green
  light; no camera is opened, so there is no picture of this room; and the audio
  engine is never started, so the caller's voice arrives and is never played.
  [mac/tools/preanswer-check.sh](mac/tools/preanswer-check.sh) asserts all three
  on real processes — `cap 0/s` and `played 0/s` in *every* report the ringing
  copy makes, and no `camera: bring-up` line at all — alongside the new
  assertion that their stream did arrive and did reach the screen.
  `TK_RING_PREVIEW=0` turns it off.
- **The caller is told that packets arriving are not an answer.** New status bit
  `Wire.ST_RINGING`, set before the first probe goes out rather than on the
  first tick of the report loop. Arrival from an address has always meant "they
  are here" in this app, and that reading is what let a ring answer itself in
  0.61.0; the caller's card now stays on `Calling`, its window says *"they are
  being asked — not connected yet"*, and its microphone is zeroed rather than
  sent into a room nobody has agreed to open. A build older than the bit never
  sends one — and those never joined before answering — so an unheard status
  byte is treated as answered after about two seconds.
- Known trade-off, and it is not closed here: the Mac being rung joins the
  rendezvous before its owner has agreed to anything, so the caller learns its
  address before anybody answers. [RINGING.md](RINGING.md) names that leak and
  the mitigation it wants — connect early only for rings whose key is already a
  contact — which this change does not implement.

### Fixed
- **`--mute` silenced the call and left the ringtone playing.** Reported by the
  person whose Mac the rigs run on, while they were watching something. Every rig
  passes `--mute`, and `--mute` only ever silenced playout, because the ringtone
  is a separate `AVAudioPlayer` that was never asked. `--mute`, `TK_MUTE=1` and
  `TK_NO_RAISE=1` now silence the ring and stop it asking for attention.
- **The third camera bring-up had no gate.** Two of them have been gated on
  `ringPending` since 0.61.0. This one never needed a gate, because the ring
  parked above it and the line was unreachable — so the moment a ring was
  allowed to fall through and receive, the camera light came on next to somebody
  who had agreed to nothing. Caught on the first rig run: `camera: bring-up
  95 ms` inside an unanswered ring.

### Changed
- **The analytics can now name why a call never happened**, not just how one
  sounded. Every ending writes one `outcome` — *talked*, *no answer*,
  *cancelled*, *declined*, *being asked*, *could not ring them* — and beside it:
  the route taken (straight to them, or through a relay), whether this Mac can
  be rung while Kin is closed **and why not**, microphone and camera permission,
  the doorbell's own answers broken out by class (ok / refused / rate-limited /
  unreachable / error), rings dropped as malformed or unverified, and clicks the
  ring card refused. `/macos/calls` reads them as plain-word verdicts — *"this
  Mac cannot be rung when Kin is closed"*, *"the doorbell refused this Mac"*,
  *"the microphone was never allowed"* — rather than leaving the reader to
  notice a missing counter.
- Rig windows now sit on the desktop layer and are `.stationary`. Corner
  placement and click-through, added in 0.63.0, still left a 1280×720 window
  appearing over whatever the person at this Mac was watching, once per launch.

## Kin 0.63.0 — 2026-08-25

### Added
- **"Calls when Kin is closed" is a row in the panel now, with the one thing
  that fixes it underneath.** Being reachable with the app shut was already
  automatic — an installed copy writes its own login item on every launch — and
  then it did not work on a second Mac, and there was no way to find that out
  from inside the app. The only report was `--watch-status`, in a terminal,
  saying *"plist present, launchd running"*. Tapping the row turns it on, or
  moves Kin somewhere it can be turned on, or opens the exact Login Items panel
  where macOS is refusing. Three outcomes, no dead ends.

### Fixed
- **`Watch.install` required `/Applications` and nothing else**, while `Install`
  treats `~/Applications` as installed and never relocates a copy there. On a
  Mac where `/Applications` was not writable, Kin settled into the home folder
  and then silently never got a login item at all — which is exactly the symptom
  that was reported. Both are stable targets at login now.
- **A third test for a click nobody aimed**, because the first two kept missing
  real ones while the rigs ran. A trackpad tap landed 4.5 s after the card
  appeared with the pointer having moved — past both existing tests — and was
  still nobody's decision, because the pointer had been sitting where that pill
  landed the whole time. The card now asks whether the pointer travelled to the
  button or the button travelled to the pointer, answered two ways: hover age,
  and a plain geometric test of where the pointer was when the card took the
  screen. `TK_AIM_MS` is the rig override, and `preanswer-check` asserts the
  pair that must rank differently — the same gesture refused when it looks like
  a stray, and going through when it comes from the harness.

### Changed
- **Rigs stopped taking the screen.** Every windowed rig runs with
  `TK_NO_RAISE=1`: the ringer does not throw the window in front, the
  ring-pending copy does not activate, the window sits in a corner, and
  `ignoresMouseEvents` sends real clicks straight through to whatever is behind.
  Before this, five of five rigs failed whenever somebody used the Mac while
  they ran, and passed when nobody did.

## Kin 0.62.0 — 2026-08-25

### Added
- **Cancel and decline are a message now, not a wait. 346 ms on production**,
  from the press to the other Mac having it. Reported after a real call, in
  these words: *"when I cancelled the call it did not get instantly notified to
  the person who was calling, and just kept showing calling forever."* That was
  true and nothing was broken — there was no un-ring to send, so the ring sat in
  its mailbox for the 60 s lease while the caller's card rang out its 45 s. A
  bye is the same signed envelope with `kind: "bye"` on it, through the same
  doorbell, waking the same held poll:
  - it signs its **own** domain, `kin-bye-v1|…`. Every Kin ever shipped verifies
    a polled ring against the ring string, so a bye it has never heard of fails
    verification and is dropped — falling back to the timeout, which is what it
    did before byes existed. Sharing the domain would have had an old client
    draw a card for a call nobody is on.
  - it is matched on `from` **and** `room` before it changes anything, so a
    stranger who knows a handle can post signed byes all day and every one lands
    and is ignored.
  - it is metered on its own rate windows, at the same limits, never the ring's.
    Every window on `/ring` exists to bound *disturbance*, and a bye makes no
    sound and draws no card; charging it would halve an honest caller's hourly
    budget while a flooder, who never sends one, keeps all sixty.
  - it ignores silent mode, because the one person guaranteed to be staring at a
    "Calling…" card is someone who silenced their own Mac and then placed a call.
  - a cancel that arrives before the callee's first poll **replaces** the ring in
    the mailbox, so that Mac never rings at all.
  - [mac/tools/bye-check.sh](mac/tools/bye-check.sh): 13 assertions on real
    processes with real keys against the real server, both directions plus the
    wrong-room control — the case a client that tore down on any bye at all
    would fail while passing the other three.

### Fixed
- **A ring window was taking people's clicks**, and had been answering calls
  with them. Caught in the act while four rigs ran and somebody was using this
  Mac: real trackpad taps — non-zero event numbers, subtype 3, one of them a
  double-click — landing on a card that had just thrown itself in front of what
  that person was doing. One unattributed auto-answer had already been seen
  during testing and written off as a mystery — this is what it was.
  Three defences, none of which is the other's fallback: `answer`,
  `decline`, `cancel` and `call again` refuse `acceptsFirstMouse`, so a click
  that merely brings Kin forward cannot join a room; a consequential press
  within one second of the card appearing, or with a pointer that has not moved
  since, is ignored and says so; and every one of these presses now logs where
  it came from — event number, click count, pressure, subtype — because
  `currentEvent` alone could not tell a finger from a leftover, which is why the
  first sighting went unexplained.

---

Earlier history predates this changelog. `MEASURED.md` is the running lab
notebook and covers that period in far more detail, including the experiments
that failed.
