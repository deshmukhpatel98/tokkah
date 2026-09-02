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
| "Rejoin <room>" / "still going" | "Back to" | 🔧 this pass |
| clipboard call link → "Join <room>" / "from your copied link", scanned when app comes forward | absent | 🔧 this pass |
| empty list → "Talk to someone once and they’ll show up here." | absent | 🔧 this pass |
| field: link joins its room; `-`/`_` joins as a room (validated); else rings a name; status line in warn colour | handle-or-room only, no status line | 🔧 this pass |
| invite row → "Link copied — send it to anyone" + room for 4 s; one minted room per visit; warmed | copies, no feedback | 🔧 this pass |
| mine row copies `@handle`, says "copied" for 2 s | copied the invite link | 🔧 this pass |
| minted room `xxx-xxxx-xxx` | `word-word-NN` | 🔧 this pass |
| settings: mine row/hint · ONE switch "People can call me" · hint only on trouble (only-when-open / 429 / unreachable), 12 s retry after 429, busy state "…" | two rows, two toggles | 🔧 this pass |
| `…` top-right of the window, `on` while settings open | same | ✅ |
| hint pill "this is you" in the sky above the card | same | ✅ |
| camera / mic asked on arrival, sentence when denied | asked; no sentence when denied | 🔧 next |
| warm the room on hover / typed `-` room | warm on press only | 🔧 this pass (typed) |
| glyphs are the Mac's paths (mic, cam, peek, flip, handset, more, lock, person, pencil, bell, phone, speaker) | approximations, cross for leave | 🔧 this pass |
| row: glyph column, switch, chevron, action chip, rule | label + word only | 🔧 this pass |

## Calling card (M: Controls.swift `WaitingCard`)

| Mac | Android | State |
|---|---|---|
| "Meera is calling" / "Calling Meera" (`Identity.display` capitalises) | "@meera is calling" | 🔧 this pass |
| ring gives up at 45 s → "Meera didn’t answer" / "they might be away" | 30 s | 🔧 this pass |
| ringtone stops itself at 40 s | same | ✅ |
| answer / decline / cancel / close / call again | same | ✅ |
| their face on the card only if they have called before | same | ✅ |

## In a call (M: Controls.swift `CallControls`, Display.swift)

| Mac | Android | State |
|---|---|---|
| camera ON when the call starts | off until pressed | 🔧 next |
| bar: mic · cam · peek · flip(≥2 cams) · leave(handset); `…` top-right | mic · cam · peek · flip · leave(cross); no `…` | 🔧 next |
| who pill top-left: "Meera  ·  0:12" (h:mm:ss past an hour), hidden with the bar | absent | 🔧 next |
| status pill: waiting for the other person · connected · you are muted · reconnecting… · Meera’ll be right back… · the other person left · the other person hung up · no network · this network only · can’t reach Kin — check your connection | connecting · connected · they left · they are muted · held sentences | 🔧 next |
| waiting card when alone: "Waiting for the other person…", the invite link, click to copy → "copied ✓", dial field "who do you want to call?" | nothing — a black screen | 🔧 next |
| after "the other person left" the waiting card comes back | stays on dead frame | 🔧 next |
| camera-off poster: their face, name, note ("Camera off" / "Camera and microphone off" / "Reconnecting…") | absent | 🔧 next |
| paused sentence in warn pill ("their microphone is off", "their connection is weak — video paused, audio is still on", …) | absent | 🔧 next |
| leave: tap arms "tap to leave", hold 0.6 s fills and leaves, disarms after 3 s | tap twice | 🔧 next |
| bar hides after stillness, pinned while armed / alone / holding | hides after 4 s | ✅ close |
| speaking edge: colour = whose turn, thickness = how audible | same | ✅ |
| more sheet: Your name (copy) · People · Change your name · Camera/Microphone/Speaker · Calls when Kin is closed (switch) · Silent (switch) · Encryption code + hint · Version (press = check; "Update ready"/restart) · Licence + hint | absent | 🔧 next |
| People page: faces, mine + copy, "Call someone new" while waiting, Back | absent | 🔧 next |
| Rename page: field pre-filled and selected, Save this name / Not now, rule sentence | absent | 🔧 next |
| bloom / caption band from the muted side | same | ✅ |
| mute badge persists with chrome gone | same | ✅ |
| update ready mid-call: "update X ready — restarts when the call ends" | deferred silently | 🔧 next |

## Under the hood

| Mac | Android | State |
|---|---|---|
| update poll every 60 s, plus a check when opened and when a call starts | every 30 min | 🔧 this pass |
| relay (TURN) on the media socket, raced with direct, fail-open | ported, not yet proven on a live call | 🔧 test |
| decode off the receive thread | ported (DecodeQueue) | 🔧 test |
| taps / marks / facts / events in the beat | ported (Metrics) | 🔧 test |
| AEC 0.125: re-aim held while the filter works (6 dB), skew fits rejected over 1.0 sps / impossible slope | 0.109-era canceller | 🔧 later |
| speaker duplex behind the −26 dB gate, ON | floor only | 🔧 later |
| turn-end prior with the on-device model | heuristic half | ⛔ no model on Android |
| ringing with the app closed costs a notification | — | ⛔ platform |
| own mouth-to-ear instrumented | not measured | 🔧 later |
