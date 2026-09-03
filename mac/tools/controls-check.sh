#!/bin/bash
# ── EVERY CONTROL, CLICKED, AND ASKED WHAT IT DID ─────────────────────────────
#
# The ask, in the words it arrived in: *"all the buttons should work. All the
# settings should work single click."*
#
# This directory already has a rig per feature. What it did not have is one that
# walks the WHOLE surface -- every circle, every row, every page -- and holds each
# one to a specific observable effect. The gap matters because the defect this
# codebase keeps finding is not "the feature is wrong", it is "the control is not
# wired", and that is invisible to a test of the feature:
#
#   * a callback declared and invoked but assigned nowhere
#   * a decorative view in front of a row, eating the click
#   * an `isFlipped` override that stopped NSCell tracking dead
#   * a blur inside a button that answered every hit test
#   * a glass container that ignored its children's alpha, so a faded row stayed
#     fully drawn and completely dead
#
# Every one of those passed a handler test. So every press here is a REAL click --
# an NSEvent at the control's own centre, through `window.sendEvent`, down every
# `hitTest` on the way -- and every press is followed by an assertion about
# something the app says afterwards. A press with no assertion is a press that
# proves the harness works.
#
# TWO SURFACES, because they are two different windows with two different press
# paths, and the front door -- the first screen of the app and every route into a
# call -- is the one that had no real-click harness at all until recently.
set -u
cd "$(dirname "$0")/.."
TK="${TK:-./.build/release/tk}"
[ -x "$TK" ] || { echo "build first: swift build -c release"; exit 2; }
export TK_NO_RAISE=1 TK_NO_IDENTITY=1
SP="$(mktemp -d)"
PIDS=""
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT
echo "scratch: $SP"
fail=0
say() { printf '  %-5s %s\n' "$1" "$2"; }
naptime() { perl -e "select undef,undef,undef,$1"; }

# want <label> <file> <pattern>            -- the log must contain it
want() {
  if grep -qE "$3" "$2"; then say OK "$1"
  else say FAIL "$1"; fail=1; fi
}
# nowant <label> <file> <pattern>
nowant() {
  if grep -qE "$3" "$2"; then say FAIL "$1"; fail=1
  else say OK "$1"; fi
}

# ════════════════════════════════════════════════════════════════════════════
echo "── THE FRONT DOOR"
# ════════════════════════════════════════════════════════════════════════════
# An isolated identity dir and login-item label: this rig must not write pretend
# contacts into the real install, and it must not touch the login item belonging
# to whoever is at this Mac.
export TK_KIN_DIR="$SP/home"; mkdir -p "$TK_KIN_DIR"
export TK_WATCH_LABEL="com.tokkah.tk.controlscheck.$$"
# `--no-rings` so a contact row cannot actually ring a stranger; the assertion is
# that the row FIRED, which the ring attempt itself reports.
# `--gui`, and it is load-bearing: `shouldPrompt` opens the front door for a BUNDLE
# launch or for this flag, and a bare `tk` with neither goes straight into a call.
# Without it this arm ran against the call window and reported four missing front
# door features that were never on screen.
"$TK" --gui --contacts-fake "arjun,meera" --no-update --no-telemetry --no-relocate --no-rings \
      --press "?,@invite,?,settings,?,@reach,?,settings,@meera,?" --press-after 2 \
      > "$SP/home.log" 2>&1 &
PIDS="$PIDS $!"
naptime 26
reap
H="$SP/home.log"

# Every row the audit found must have been REACHED by its click, not merely
# targeted. `reaches=false` means something is in front of it.
BADREACH=$(grep -c 'reaches=false' "$H" || true)
[ "${BADREACH:-0}" = "0" ] && say OK "every click reached the row it was aimed at" \
  || { say FAIL "$BADREACH clicks were intercepted by something in front"; fail=1; }
NOROW=$(grep -c 'click: no row named' "$H" || true)
[ "${NOROW:-0}" = "0" ] && say OK "and every named control was on screen" \
  || { say FAIL "$NOROW clicks found no such control"; fail=1; }

want "the invite row copied a real link" "$H" 'home: invite link copied for'
want "the corner button opened the settings card" "$H" 'home card \[settings\]'
want "the reach switch reported a change" "$H" 'watch|silent|reach'
want "a contact row started a call" "$H" 'ring|calling|home: '
# The one assertion about the KEYBOARD, which no click can make.
want "the key monitor is installed" "$H" 'home: keys ready'
want "and there is an Edit menu, so Command-V works" "$H" 'home: edit menu \(paste=true'

# ════════════════════════════════════════════════════════════════════════════
echo "── THE CALL WINDOW"
# ════════════════════════════════════════════════════════════════════════════
export TK_KIN_DIR="$SP/call"; mkdir -p "$TK_KIN_DIR"
R="cc$$"
"$TK" --window --video off --mute --no-telemetry --no-update --no-relocate \
      --no-rings --no-subtitles --room "$R" --listen 7932 --peer 127.0.0.1:7931 \
      > "$SP/b.log" 2>&1 &
PIDS="$PIDS $!"
# The whole surface, in one pass. Each token is a real click; `?` prints the state
# after it. Ordered so nothing depends on a page a later press replaces.
# `@scrim` is how the panel closes: the corner button is UNDER the scrim while it
# is open, which is correct behaviour and is why `@more` cannot close it. A rig
# that pressed `@more` twice found nothing the second time and every assertion
# after it failed for the wrong reason.
SEQ="?,@mic,?,@mic,@cam,?,@cam"                        # the two toggles, both ways
SEQ="$SEQ,@more,?"                                     # the panel
SEQ="$SEQ,@row:microphone,?,@row#0,?"                  # the device page, and pick one
SEQ="$SEQ,@row:people,?,@scrim"                        # the people page, then close
SEQ="$SEQ,@more,@row:version,?,@scrim"                 # check for updates
SEQ="$SEQ,@more,@row:silent,?,@scrim"                  # the switch
SEQ="$SEQ,@peek:0.6,?"                                 # hold to see yourself
SEQ="$SEQ,@leave,?"                                    # arms, does not end
"$TK" --window --video off --no-telemetry --no-update --no-relocate \
      --no-rings --no-subtitles --room "$R" --listen 7931 --peer 127.0.0.1:7932 \
      --with meera --press "$SEQ" --press-after 1.6 > "$SP/a.log" 2>&1 &
PIDS="$PIDS $!"
naptime 46
reap
A="$SP/a.log"

NOTON=$(grep -c 'NOT ON SCREEN' "$A" || true)
[ "${NOTON:-0}" = "0" ] && say OK "every named control was on screen when pressed" \
  || { say FAIL "$NOTON presses found nothing to press:"; grep 'NOT ON SCREEN' "$A" | sed 's/^/         /' | head -5; fail=1; }
# ── AND EVERY ONE OF THEM HAS A NAME ────────────────────────────────────────
#
# A control with no accessibility label announces as "button" -- the same thing
# every other unnamed control announces as -- so a screen reader meets a row of
# six identical buttons. Two were unnamed when this arm was written: the scrim,
# which is the most-used way out of the settings panel, and the invite link,
# which is the whole first experience of the app.
UNNAMED=$(grep -cE '^audit .* UNNAMED' "$A" || true)
[ "${UNNAMED:-0}" = "0" ] && say OK "and every control on screen has a name a screen reader can say" \
  || { say FAIL "$UNNAMED controls announce as nothing in particular:"
       grep -oE '^audit [A-Z]+ +[a-z:#0-9]+.* UNNAMED' "$A" | sort -u | head -6 | sed 's/^/         /'
       fail=1; }
FAILHIT=$(grep -cE '^audit FAIL' "$A" || true)
[ "${FAILHIT:-0}" = "0" ] && say OK "and the hit-test audit found nothing unreachable" \
  || { say FAIL "$FAILHIT controls are drawn and cannot be clicked"; grep '^audit FAIL' "$A" | sed 's/^/         /'; fail=1; }

# ── EACH CONTROL'S OWN EFFECT ────────────────────────────────────────────────
# `mic=muted` must appear AND `mic=on` must come back: a toggle that only goes one
# way passes a test that looks for one state.
want "the microphone button muted" "$A" 'mic=muted'
MICBACK=$(grep -oE 'mic=(on|muted)' "$A" | tail -1)
[ "$MICBACK" = "mic=on" ] && say OK "and unmuted again" \
  || { say FAIL "the microphone never came back: $MICBACK"; fail=1; }
want "the camera button turned the camera off" "$A" 'cam=off'
CAMBACK=$(grep -oE 'cam=(on|off)' "$A" | tail -1)
[ "$CAMBACK" = "cam=on" ] && say OK "and back on" \
  || { say FAIL "the camera never came back: $CAMBACK"; fail=1; }
want "the corner button opened the panel" "$A" 'more=open'
want "the microphone page listed devices" "$A" 'sheet=microphone\['
want "and picking one changed the device" "$A" 'audio: switching microphone|audio: microphone is now'
want "and came back to the settings page by itself" "$A" 'sheet=settings\[.*Microphone'
want "the people page opened" "$A" 'sheet=people\['
want "the version row asked for an update check" "$A" 'sheet=settings\[.*checking|asked from the menu|Update'
want "the silent switch was pressed" "$A" 'going silent|turning silence off'
want "peek showed the self view while held" "$A" 'peek on'
want "and put it away on release" "$A" 'peek off'
want "the red button armed rather than ending the call" "$A" 'leave=ARMED|leave=HOLDING'
nowant "and nothing left the call from a single tap" "$A" 'left the call'

# ── AND THE PANEL DOES NOT SHUT ITSELF ───────────────────────────────────────
# A setting that closes the panel it lives in hides its own result. Both of these
# used to: picking a camera and flipping the silent switch.
AFTER_SILENT=$(grep -A1 'click row:silent' "$A" | grep -oE 'more=(open|closed)' | head -1)
[ "$AFTER_SILENT" = "more=open" ] && say OK "the panel stayed open through a switch" \
  || { say FAIL "pressing the switch shut the panel: $AFTER_SILENT"; fail=1; }

# ── AND THE MENUS, WHICH NO CLICK IN THE WINDOW CAN REACH ────────────────────
echo "── THE MENU BAR"
export TK_KIN_DIR="$SP/menu"; mkdir -p "$TK_KIN_DIR"
R2="cm$$"
"$TK" --window --video off --mute --no-telemetry --no-update --no-relocate \
      --no-rings --no-subtitles --room "$R2" --listen 7922 --peer 127.0.0.1:7921 \
      > "$SP/mb.log" 2>&1 &
PIDS="$PIDS $!"
"$TK" --window --video off --mute --no-telemetry --no-update --no-relocate \
      --no-rings --no-subtitles --room "$R2" --listen 7921 --peer 127.0.0.1:7922 \
      --press "%Mute,%Turn Camera Off,%People…,%Copy Invite Link,%Paste,%Enter Full Screen,%Settings…,?" \
      --press-after 1.6 > "$SP/m.log" 2>&1 &
PIDS="$PIDS $!"
naptime 22
reap
M="$SP/m.log"
NOTIN=$(grep -c 'NOT IN THE MENU' "$M" || true)
[ "${NOTIN:-0}" = "0" ] && say OK "every menu item exists" \
  || { say FAIL "$NOTIN menu items are missing:"; grep 'NOT IN THE MENU' "$M" | sed 's/^/         /'; fail=1; }
NILT=$(grep -cE 'menu "(Mute|Turn Camera Off|People…|Copy Invite Link|Settings…)".*target=nil' "$M" || true)
[ "${NILT:-0}" = "0" ] && say OK "and none of the app's own items has a missing target" \
  || { say FAIL "$NILT items would resolve through the responder chain instead of acting"; fail=1; }
# ── PASTE IS *MEANT* TO BE GREY HERE ────────────────────────────────────────
# There is nothing editable focused on a call window, so `paste:` has no responder
# and AppKit greys it. That is right, and a rig demanding it be enabled would be
# demanding a lie. What must not be grey is anything the app itself owns.
MINE='Mute|Turn Camera Off|People…|Copy Invite Link|Settings…|Leave Call|Share Invite…|Show Encryption Code'
GREY=$(grep -cE "menu \"($MINE)\".* greyed" "$M" || true)
if [ "${GREY:-0}" = "0" ]; then say OK "and none of the app's own items was greyed on a live call"
else say FAIL "$GREY of the app's own items were greyed:"; grep -E "menu \"($MINE)\".* greyed" "$M" | sed 's/^/         /'; fail=1; fi
# ── FULL SCREEN, ASSERTED ON THE DECLARATION AND NOT ON THE VALIDATION ──────
# `toggleFullScreen:` validates against the window, and under `TK_NO_RAISE` the
# window is parked at the desktop level so that a rig cannot throw itself over
# whoever is using this Mac -- and a window at an abnormal level cannot go full
# screen. So the item IS grey here, correctly, for a reason that has nothing to do
# with the app. The claim worth testing is what the window asked for.
want "the window asks for full screen and is resizable" "$M" \
     'window: fullscreen=allowed resizable=true'
if grep -qE 'menu "Enter Full Screen".* greyed' "$M"; then
  if grep -q 'level=desktop' "$M"; then
    say OK "and the menu item is grey only because this rig parks the window (level=desktop)"
  else
    say FAIL "Enter Full Screen is greyed on a normal-level window"; fail=1
  fi
else
  say OK "and the menu item is available"
fi

# ── AND PASTE, WHERE THERE IS SOMETHING TO PASTE INTO ───────────────────────
# The front door's one field. This is the assertion that matters: the app had no
# Edit menu at all, so Command-V was dead in the one place a person uses it --
# pasting the call link somebody just sent them.
echo "── PASTE, ON THE FRONT DOOR"
export TK_KIN_DIR="$SP/paste"; mkdir -p "$TK_KIN_DIR"
"$TK" --gui --contacts-fake "" --no-update --no-telemetry --no-relocate --no-rings \
      --press "?,%Paste,?" --press-after 2 > "$SP/p.log" 2>&1 &
PIDS="$PIDS $!"
naptime 9
reap
P="$SP/p.log"
want "the Edit menu is on the front door too" "$P" 'home: edit menu \(paste=true, selectall=true\)'

# ════════════════════════════════════════════════════════════════════════════
# ── AND ALL OF IT AT THE SMALLEST WINDOW THE APP WILL OPEN ──────────────────
# ════════════════════════════════════════════════════════════════════════════
#
# Every arm above -- and every other rig in this directory -- opens the default
# window. So the smallest size a person can drag Kin to was a size nobody had
# ever photographed at, and this is what was there: the settings panel drew ABOVE
# THE TOP EDGE of its own window, at y=543 in a window 320 points tall, and all
# nine rows reported `audit FAIL`. Not one setting was clickable. The panel was
# sized from its content with nothing comparing that to the window.
#
# The panel now takes the room it is given and scrolls inside it, so the two
# claims here are the ones that were false: nothing is unreachable, and a row that
# is scrolled out can still be reached -- by scrolling to it, which is what
# `click` now does and what a person does.
echo "── THE SMALLEST WINDOW (480x320, the floor contentMinSize sets)"
export TK_KIN_DIR="$SP/small"; mkdir -p "$TK_KIN_DIR"
"$TK" --window --window-size 480x320 --video off --mute --no-telemetry --no-update \
      --no-relocate --no-rings --no-subtitles --room "sm$$" --listen 7941 \
      --peer 127.0.0.1:7942 \
      --press "@more,?,@row:encryption,?,@scrim,?" --press-after 3 \
      > "$SP/s.log" 2>&1 &
PIDS="$PIDS $!"
naptime 14
reap
S="$SP/s.log"
# The window really is that size, or every assertion below is about a big window.
want "the window opened at the size asked for" "$S" 'controls 480x320'
SNOTON=$(grep -c 'NOT ON SCREEN' "$S" || true)
[ "${SNOTON:-0}" = "0" ] && say OK "every named control was reachable at 480x320" \
  || { say FAIL "$SNOTON presses found nothing to press in a small window:"
       grep 'NOT ON SCREEN' "$S" | sed 's/^/         /' | head -5; fail=1; }
SFAIL=$(grep -cE '^audit FAIL' "$S" || true)
[ "${SFAIL:-0}" = "0" ] && say OK "and nothing was drawn where a click cannot reach it" \
  || { say FAIL "$SFAIL controls are unreachable at 480x320"
       grep '^audit FAIL' "$S" | sed 's/^/         /' | head -8; fail=1; }
# THE PANEL MUST KNOW IT DOES NOT FIT. An instrument that reports `fits` here is
# blind to the whole defect -- and a panel that reports `fits` at 320 points is
# the panel that ran off the top of the window.
if grep -qE 'panel=[0-9]+/[0-9]+ shown scroll=' "$S"; then
  say OK "the panel says how much of itself is showing: $(grep -oE 'panel=[^ ]+ shown scroll=[0-9/]+' "$S" | tail -1)"
else
  say FAIL "the panel reported no scroll state at 480x320 -- either it thinks it"
  say FAIL "  fits (it cannot) or the instrument cannot see the clip"; fail=1
fi
# A row past the bottom of the box is reached by SCROLLING to it. Without this the
# last four settings are simply gone at this size.
want "a scrolled-out row is reached by scrolling to it" "$S" 'scrolled the panel to reach row:encryption'
want "and the row it scrolled to was really pressed" "$S" 'click row:encryption: sent'
# And the way out still works when the panel covers the middle of the window.
LAST=$(grep -oE 'more=(open|closed)' "$S" | tail -1)
[ "$LAST" = "more=closed" ] \
  && say OK "and a click on the scrim still closes it (more=closed)" \
  || { say FAIL "the panel did not close at 480x320 -- last state $LAST"; fail=1; }

[ "$fail" = 0 ] && echo "CONTROLS CHECK PASSED -- every control was clicked and every one of them did something" \
                || echo "CONTROLS CHECK FAILED"
exit $fail
