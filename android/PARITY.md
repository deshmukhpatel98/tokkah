# Kin for Android — parity with Kin for macOS

Audited 2026-09-02 against `mac/Sources/tk` at **0.125.0**. The Mac app is the
product; this file is the port queue and the record of what is already the
same. Anchors: M: = mac/Sources/tk, A: = android/app/src/main/java/com/tokkah/kin.

Rule: a row here is closed by a behaviour on a phone that a rig or a screenshot
has confirmed, never by the code existing (`unrun-tests-are-not-coverage`).

## Front door (M: Launcher.swift `home()`)

| Mac | Android | State |
|---|---|---|
| card order: rejoin · link · people(≤5, by recency) · field · status · invite · mine(if nobody) | same walk | ✅ 0.116.11 |
| "Rejoin <room>" / "still going" | "Back to" | ✅ 0.126.12 |
| clipboard call link → "Join <room>" / "from your copied link", scanned when app comes forward | absent | ✅ 0.126.12 |
| empty list → "Talk to someone once and they’ll show up here." | absent | ✅ 0.126.12 |
| field: link joins its room; `-`/`_` joins as a room (validated); else rings a name; status line in warn colour | handle-or-room only, no status line | ✅ 0.126.12 |
| invite row → "Link copied — send it to anyone" + room for 4 s; one minted room per visit; warmed | copies, no feedback | ✅ 0.126.12 |
| mine row copies `@handle`, says "copied" for 2 s | copied the invite link | ✅ 0.126.12 |
| minted room `xxx-xxxx-xxx` | `word-word-NN` | ✅ 0.126.12 |
| settings: mine row/hint · ONE switch "People can call me" · hint only on trouble (only-when-open / 429 / unreachable), 12 s retry after 429, busy state "…" | two rows, two toggles | ✅ 0.126.12; the server refused the quiet request (400, old `tok` field) from the v2 identity port until 0.128.22 — verified 200 both ways |
| `…` top-right of the window, `on` while settings open | same | ✅ |
| hint pill "this is you" in the sky above the card | same | ✅ |
| camera / mic asked on arrival, sentence when denied (pill opens Settings) | same; seen on the emulator with the camera revoked | ✅ 0.126.13 |
| warm the room on hover / typed `-` room | warm on press (no hover on a phone) | ✅ close |
| glyphs are the Mac's paths (mic, cam, peek, flip, handset, more, lock, person, pencil, bell, phone, speaker) | approximations, cross for leave | ✅ 0.126.12 |
| row: glyph column, switch, chevron, action chip, rule | label + word only | ✅ 0.126.12 |

## Calling card (M: Controls.swift `WaitingCard`)

| Mac | Android | State |
|---|---|---|
| "Meera is calling" / "Calling Meera" (`Identity.display` capitalises) | "@meera is calling" | ✅ 0.126.12 |
| ring gives up at 45 s → "Meera didn’t answer" / "they might be away" | 30 s | ✅ 0.126.12 |
| ringtone stops itself at 40 s | same | ✅ |
| answer / decline / cancel / close / call again | same | ✅ |
| before ringing: Presence.ask — unregistered → "Nobody has the name X on Kin yet — check the spelling"; asleep → "X’s Mac is off right now — ringing it anyway"; refused → "Couldn’t reach X — check the name, and try again" | same; seen live with a name nobody has | ✅ 0.126.17 |
| three pulsing dots while the ring travels | same | ✅ 0.126.17 |
| their face on the card only if they have called before | same | ✅ |

## In a call (M: Controls.swift `CallControls`, Display.swift)

| Mac | Android | State |
|---|---|---|
| camera ON when the call starts | same | ✅ 0.126.12 |
| bar: mic · cam · peek · flip(≥2 cams) · leave(handset); `…` top-right | same | ✅ 0.126.12 |
| who pill top-left: "Meera  ·  0:12" (h:mm:ss past an hour), hidden with the bar | same | ✅ 0.126.12 |
| status pill: waiting for the other person · connected · you are muted · reconnecting… · Meera’ll be right back… · the other person left · the other person hung up · no network · this network only · can’t reach Kin — check your connection | same words, same precedence; hold/left from the directory's ageMs | ✅ 0.126.12 |
| waiting card when alone: "Waiting for the other person…", the invite link, click to copy → "copied ✓", dial field "who do you want to call?" | same | ✅ 0.126.12 |
| after "the other person left" the waiting card comes back | same | ✅ 0.126.12 (seen live: Mac pressed leave, phone said "the other person hung up" and showed the link) |
| camera-off poster: their face, name, note ("Camera off" / "Camera and microphone off" / "Reconnecting…") | same (seen live) | ✅ 0.126.12 |
| paused sentence in warn pill ("their microphone is off", "their connection is weak — video paused, audio is still on", …) | same (seen live: "their camera is off") | ✅ 0.126.12 |
| leave: tap arms "tap to leave", hold 0.6 s fills and leaves, disarms after 3 s | same | ✅ 0.126.12 |
| bar hides after stillness, pinned while armed / alone / holding | hides after 4 s | ✅ close |
| speaking edge: a frame round the whole window, colour = whose turn, width 4.5+3.5×loudness / 3 / 1.5 | same (was a bar along the top) | ✅ 0.126.15 |
| glass reads the picture under it and dims to Backdrop.dim (4.5:1 over a lit room) | same rule, 3 Hz grid sample of the backdrop layer | ✅ 0.126.15 |
| every control announces its name and state (0.123.0's audit) | mic/camera/switch camera/peek/leave/more, rows as label = value, scrim 'Close settings'; read back with uiautomator | ✅ 0.126.16 |
| peer video paused: blurred last frame + poster | dimmed frame + 'Reconnecting…' poster (a SurfaceView cannot be blurred without its latency) | ✅ 0.126.16 |
| Share Invite… (system share) | long-press the invite row → share sheet | ✅ 0.126.16 |
| a crash is booked with the fleet (Crash.swift) | uncaught exception written to disk, posted on the next launch under the route's fields | ✅ 0.126.15 |
| signed media handshake (Ed25519 over X25519, room in the signed message), expected identity from the ring / server / contacts, no plaintext window, 2048-packet replay window, `hs_*` + `crypt_v` + `crypt_pinned` in the beat; refuses the unsigned 0.127 handshake as `hs_old` | same class, bit-exact against the Mac's vectors (CryptoTest, 12 arms); one constant-time curve implementation (BouncyCastle rfc7748/rfc8032, direct), no platform lookup, no fallback | ✅ 0.128.21 |
| more sheet: Your name (copy) · People · Change your name · Camera/Microphone/Speaker · Calls when Kin is closed (switch) · Silent (switch) · Encryption code + hint · Version (press = check; "Update ready"/restart) · Licence + hint | same; Microphone is a fact (Android picks it with the route) | ✅ 0.126.12 |
| People page: faces, mine + copy, "Call someone new" while waiting, Back | same | ✅ 0.126.12 |
| Rename page: field pre-filled and selected, Save this name / Not now, rule sentence | same | ✅ 0.126.12 |
| bloom / caption band from the muted side | same | ✅ |
| mute badge persists with chrome gone | same | ✅ |
| update ready mid-call: "update X ready — restarts when the call ends" | same | ✅ 0.126.12 |

## Under the hood

| Mac | Android | State |
|---|---|---|
| update poll every 60 s, plus a check when opened and when a call starts | every 30 min | ✅ 0.126.12 |
| relay (TURN) on the media socket, raced with direct, fail-open | same; proven live 2026-09-03: harness KIN_RELAY_ONLY arm vs the live Mac 0.128 — Mac 'connected via 104.30.148.97:25666' (the phone's relay), audio 99.9% played both ways, rtt 8.4 ms (the Mac took 30 s to lock when its own allocation failed — a Mac-side wait) | ✅ 0.128.19 |
| decode off the receive thread | ported (DecodeQueue), v_dq_* in the beat | ✅ |
| audio redundancy under loss (repair copies, steered on the far end's report) | same rule; phone reports its loss in the probe; the live Mac 0.128 turned FEC on from the phone's report | ✅ 0.128.19 |
| signed v2 handshake (Mac 0.128 refuses v1) | shipped in lockstep as android.19; seen live: 'signed handshake, first use' | ✅ 0.128.19 |
| the beat under the Mac's field names (played_ps, floor_held_pct, v_*, route, …); absent where not measured | same names | ✅ 0.126.12 |
| AEC aimed by a delay estimator every 0.5 s (echoEstimator/corrScan); 0.125 re-aim hold | EchoAim ported + hold; validated on planted delays (EchoAimTest) | ✅ 0.126.12 |
| AEC clock-drift tracker (0.109 fractional window, carries without shifting taps) and 0.125 skew gate | ported; 30 ppm planted: 3.8 → 10.3 dB, skew 1.42 read vs 1.44 planted (AecDriftTest) | ✅ 0.126.14 |
| AEC re-aim hold under wandering readings (0.125 rig: 10 ms off 2 s in 6) | clean 19.9 dB, held 19.9 dB / 1 re-aim, unguarded 3.6 dB / 10 re-aims | ✅ 0.126.14 |
| NLMS step per second the same as the Mac's | the Mac's `mu` is per 16-frame block; the phone's 160–480-frame bursts adapted 10–30× slower with the same number — step now scales with block size (white-noise echo 4.8 → 30.9 dB at 192) | ✅ 0.126.14 |
| remove a person from the home list (hover ×, right-click; key kept) — 0.126.0 | long-press → "remove" chip; hidden.json | ✅ 0.126.12 |
| self-update: silent where installer of record, else one tap | same; seen live android.11 → android.12 on the emulator | ✅ 0.126.12 |
| speaker duplex behind the −26 dB gate, ON | same; the gate is fed from the canceller (it had been declared and fed by nothing) | ✅ 0.126.13 |
| turn-end prior's model term | the Mac's production Predict is built by `Subtitles(predictModel: Bool = false)` (Subtitles.swift 146) and nothing in main.swift turns it on; `--predict-model` exists only for the self-test rig, so a Mac in production runs the heuristic half only — exactly what the phone runs. Identical shipped behaviour; the flag-gated experiment is not ported because Android has no FoundationModels | ✅ shipped behaviour identical (⛔ only for the flag-gated experiment) |
| ringing with the app closed costs a notification | CLOSED 2026-09-03 without push. Android shows a foreground service's notification only while the app holds the notification permission; Kin no longer asks for it, so the listening service runs with NOTHING in the shade (measured: 0 notification records, "No notifications", isForeground=true). A ring opens the card directly from the service under the "display over other apps" grant — the Mac's `--incoming`: the card asks ("@devesh is calling", Decline / Answer), the ringtone plays, and no room, socket or camera exists until Answer (measured: 0 rv lines before Answer, 4 after). The switch asks for that one grant instead of notifications. Copies that already granted notifications keep ringing the old way | ✅ android.24 |
| the app icon | the shipped Mac icon (AppIcon.icns: Material `conversation`, two faces, on the #06080D→#1B2740 plate) was NOT what the phone showed — the repo's icon-1024.png was a stale three-bar drawing and the phone copied it. Android icon set now rendered from the real .icns: adaptive foreground = the plate fitted to the 72dp safe zone, background = the plate gradient, monochrome = the glyph alone; legacy = the icon as drawn. icon-1024.png refreshed from the .icns | ✅ android.24 |
| taking somebody off the list | the Mac's two ways (Controls.swift 1357): a right-click menu "Remove @meera" and an × at the row's end on hover. Phone: a long press opens the same menu (dark, on the card) AND shows the Mac's × (20 pt disc, fill 0.14, × 3.5/1.6); either removes. Verified: long press → "Remove @zzqqxxn" + × in the uiautomator dump | ✅ android.24 |
| the call's top line on a narrow screen | the Mac centres the sentence on the top edge beside the who-pill and `…` because its window is wide; on the phone "waiting for the other person" ran INTO the who-pill. Phone: one top line (who left, `…` right, both centred on the 48 pt line), sentence centred on the line below. Screenshot verified | ✅ android.24 |
| own mouth-to-ear (m2e_p50/95/99) | same names; basis = device buffer, said in the facts | ✅ 0.126.13 |

## Found on the way (fixed 0.126.0-android.12)

- Flip only chose the camera for the NEXT bring-up: the button did nothing on a
  running call (`dead-controls-declared-never-wired`).
- The camera button called `stop()`, which released the far end's DECODER with
  the local encoder: turning your camera off blanked THEIR picture.
- `--no-audio` on the emulator makes the phone's playout starve (conceal_frac
  0.79) and the Mac read an 83 s mouth-to-ear: the emulator lane needs audio on,
  and even then its user-mode NAT drops most of a 1500 pkt/s stream. The phone
  is the gate for anything about sound.
