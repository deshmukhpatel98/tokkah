# Web → Mac feature parity

Audited 2026-08-24 against tape-app/public/app.js (the retired browser app) and
mac/Sources/tk/. The Mac app is the only product now; this is the port queue.
Anchors: W: = tape-app/public/app.js, H: = index.html, M: = mac/Sources/tk/.

## Port queue, by daily impact

1. **Held/paused shown honestly** — port stallUi (W:2741). Done = concealment past
   the HOLD fraction desaturates the window, runs an indeterminate hairline, says
   "connection paused — reconnecting" / "holding · audio live", clears on recovery.
   Today a bad minute looks like a crashed app (M: nothing; main.swift:829 comment; see HELD.md).
2. **Microphone picker** — port switchMicTo (W:7917) as a sheet section; switching
   retargets capture live, mute survives. (M: OS default only, Audio.swift:783.)
3. **Mic level meter** — port startLevelMeter (W:8557); RMS + slow peak-hold in sheet.
(cut 2026-08-24: loud-room warning — user ruling: "your room is loud — try
headphones" is annoying; DELETE it rather than improve it. Do not port the web version.)

4. **Tap picture toggles the bar** — port W:8250. (M: mouse-move reveal only.)
5. **Remembered camera + hot-plug** — port W:8706 + tape.cam (W:7899). (M: list read
   once at start, main.swift:534-545; nothing remembered.)
6. **Headphone check** — port headphoneCheck (W:8615): 660 Hz tone, mic-rise dB,
   "headphones — you're good" / "speakers — you'll echo". AEC is off by design.
7. **Blurred letterbox wash** — port startRemoteFill (W:774) + fit policy (W:751).
   (M: Display.swift:146 resizeAspect = black bars.)
8. **Blocked-permission recovery in-window** — port W:8738-8772. (M: only the
    --join-window launcher has an Open Settings button, Launcher.swift:200-210.)

Runners-up: auto-rejoin after quit (W:8306), h:mm:ss past an hour, peer-arrival
crossfade (W:355), click-link-to-copy (W:8001), dead-looking controls when no
device exists (W:7649). Camera-flip resilience: open-before-close, [250,600,1400]ms
backoff, restore-on-failure, report where it LANDED (W:7807) — mac flip lacks these.

## Mac is AHEAD — do not "port" web's absence

Keyboard shortcuts + menu bar; manual mirror toggle; self-update with in-call
deferral; window-close ends the call. Keep all four.

## Done / not gaps

Mute, camera toggle, hold-to-peek, flip (≥2 cams), safety code (pill in flight +
sheet row), two-tap leave, more sheet, bar auto-hide, status pill, clock, waiting
card + share, camera picker rows, deep links, minted rooms, Esc, tooltips,
fullscreen via green button, relay warning equivalent. Parked in both: translation,
frame-sense. Obsolete natively: pre-join screen, haptics, safe-area, tab tricks.

Full 49-row table with anchors: session transcript 2026-08-24 (parity audit agent).
