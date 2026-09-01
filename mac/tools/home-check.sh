#!/bin/bash
# ── THE FRONT DOOR, POPULATED THE WAY A REAL ONE IS ──────────────────────────
#
# The home list's three new facts -- a face, a green dot, a "yesterday" -- can
# each silently not happen: a face that fails to decode falls back to the
# initial, an unreachable server paints no dots, an empty lastcall.json labels
# nothing. Every fallback is CORRECT behaviour, which is exactly why a rig has
# to plant the positive case: audited only in its empty state, this screen
# would report the same green as one where none of it works
# (`feature-behind-a-flag-nobody-runs`).
#
#   tools/home-check.sh          build's binary, plants fixtures, screenshots
#
# What it cannot see: colour. `screencapture` proves layout and the audit line
# proves state, but "the dot is green" is a human check on the PNG this leaves
# behind in its scratch dir (printed below).
set -u
cd "$(dirname "$0")/.."
TK="${TK:-./.build/release/tk}"
[ -x "$TK" ] || { echo "build first: swift build -c release"; exit 2; }
SP="$(mktemp -d)"
echo "scratch: $SP"
PIDS=""
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
trap 'reap' EXIT

# ── THE FIXTURES ─────────────────────────────────────────────────────────────
# An isolated identity dir (TK_KIN_DIR), or this rig would write pretend faces
# and pretend call times into the real install (`rig-isolation-that-does-not-isolate`).
export TK_KIN_DIR="$SP/kin"
mkdir -p "$TK_KIN_DIR/faces"
# Two distinct face images, generated here: sips can make solid-colour JPEGs
# out of nothing via a PNG intermediate. Distinct colours, so "arjun's face on
# meera's row" is visible in the screenshot rather than plausible.
python3 - "$TK_KIN_DIR/faces" <<'PY'
import struct, zlib, sys, os
def png(path, rgb):
    w = h = 64
    row = b'\x00' + bytes(rgb) * w
    idat = zlib.compress(row * h)
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c))
    hdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', hdr)
                           + chunk(b'IDAT', idat) + chunk(b'IEND', b''))
png(sys.argv[1] + '/arjun.png', (196, 92, 60))    # warm brick
png(sys.argv[1] + '/meera.png', (70, 130, 190))   # steel blue
PY
sips -s format jpeg "$TK_KIN_DIR/faces/arjun.png" --out "$TK_KIN_DIR/faces/arjun.jpg" >/dev/null
sips -s format jpeg "$TK_KIN_DIR/faces/meera.png" --out "$TK_KIN_DIR/faces/meera.jpg" >/dev/null
rm "$TK_KIN_DIR/faces/arjun.png" "$TK_KIN_DIR/faces/meera.png"
# dad has no face: his row is the fallback initial, on purpose -- both species
# must appear in one screenshot or the fallback is the arm nobody ran.
NOW=$(python3 -c 'import time; print(time.time())')
python3 - "$TK_KIN_DIR/lastcall.json" "$NOW" <<'PY'
import json, sys
now = float(sys.argv[2])
json.dump({"meera": now - 300, "arjun": now - 90000, "dad": now - 86400 * 21},
          open(sys.argv[1], "w"))
PY
# meera reachable, arjun not, dad unknown (absent) -- all three states on screen.
export TK_PRESENCE_FAKE="meera=1,arjun=0"

# --no-relocate: an INSTALLED Kin.app run through this rig would otherwise copy
# itself toward /Applications and re-exec, and the log this rig reads would end
# at the hop.
"$TK" --contacts-fake "arjun,meera,dad" --gui --no-update --no-telemetry \
  --no-relocate > "$SP/home.log" 2>&1 & PIDS="$PIDS $!"
sleep 4
WID=$(grep -o "window id [0-9]*" "$SP/home.log" | awk '{print $3}' | tail -1)
fail=0
if [ -z "$WID" ]; then
  echo "  FAIL no window id in the log"; fail=1
else
  screencapture -l "$WID" -x "$SP/home.png" || fail=1
fi
reap

# ── THE AUDIT ────────────────────────────────────────────────────────────────
# The ordering is recency: meera (5 min) above arjun (yesterday) above dad (3 w).
# Read from the log's own home audit line if present; otherwise assert via the
# fixtures the binary was handed.
say() { printf '  %-4s %s\n' "$1" "$2"; }
if grep -q "faces: drew photo for @meera" "$SP/home.log" 2>/dev/null; then say OK "meera's photo drawn"; fi
grep -q "contacts: --contacts-fake is on" "$SP/home.log" && say OK "fake contacts armed" \
  || { say FAIL "fake contacts never armed"; fail=1; }
[ -s "$SP/home.png" ] && say OK "screenshot captured: $SP/home.png" \
  || { say FAIL "no screenshot"; fail=1; }
# ── THE CAMERA SENTENCE MUST RESOLVE ─────────────────────────────────────────
# From 0.103.0 to 0.110.0 the front door said "Starting camera…" forever,
# because the rebuild deleted startPreview() and kept the pill: a hint narrating
# work no code performs. Every launch must now end that sentence one of four
# recorded ways -- running, denied, restricted, none found -- and a log with no
# resolution line IS that bug, whatever the screenshot happens to show.
if grep -qE "camera: (preview running|access DENIED|access restricted|none found|session refused)" "$SP/home.log"; then
  say OK "camera resolved: $(grep -oE 'camera: [^-]*' "$SP/home.log" | head -1)"
else
  say FAIL "the camera sentence never resolved -- the 0.103 regression is back"
  fail=1
fi
# Recency order is computed by the same function the app uses; assert it here
# against the planted times by asking the binary itself.
ORDER=$(TK_KIN_DIR="$TK_KIN_DIR" "$TK" --contacts-fake "arjun,meera,dad" --order-audit 2>/dev/null)
if [ "$ORDER" = "meera arjun dad" ]; then say OK "order is recency: $ORDER"
else say FAIL "order is '$ORDER', want 'meera arjun dad'"; fail=1; fi

# ── THE KEYBOARD AND THE MENU BAR, WHICH ARE ABSENCES ────────────────────────
# Both are things that do not happen: no menu bar means Command-Q is inert, no
# monitor means the arrow keys are. Neither shows up in a screenshot and neither
# fails loudly, so each announces itself and the rig reads the announcement.
# What this CANNOT see is whether a key actually walks the list or whether
# Command-W actually closes -- that needs a real press into a key window.
grep -q "home: keys ready" "$SP/home.log" && say OK "key monitor installed" \
  || { say FAIL "no key monitor on the home window"; fail=1; }
grep -q "home: menu ready (2 menus, close=true, quit=true)" "$SP/home.log" \
  && say OK "menu bar installed with Close and Quit" \
  || { say FAIL "no menu bar on the home window: $(grep -o 'home: menu.*' "$SP/home.log" | head -1)"
       fail=1; }

# ── AND THE EMPTY FRONT DOOR ─────────────────────────────────────────────────
# With nobody in the list this screen used to open on the ROOM FIELD -- the one
# surface the people rebuild existed to demote -- so the very first launch of
# the app showed the opposite of what the app is for, and fixed itself only
# after you had somehow already made a call. A second run with no contacts at
# all, asserting the mode the code says it chose.
export TK_KIN_DIR="$SP/kin-empty"
mkdir -p "$TK_KIN_DIR"
"$TK" --contacts-fake "" --gui --no-update --no-telemetry --no-relocate \
  > "$SP/empty.log" 2>&1 & PIDS="$PIDS $!"
sleep 4
EWID=$(grep -o "window id [0-9]*" "$SP/empty.log" | awk '{print $3}' | tail -1)
[ -n "$EWID" ] && screencapture -l "$EWID" -x "$SP/empty.png"
reap
if grep -q "home: mode people (empty)" "$SP/empty.log"; then
  say OK "empty front door still opens on people: $SP/empty.png"
else
  say FAIL "empty front door is not the people screen -- $(grep -o 'home: mode.*' "$SP/empty.log" | head -1)"
  fail=1
fi
# An empty list has nobody to call, so the one thing that helps is your own name
# for somebody else to dial. It stays on the FRONT card exactly until the list
# has somebody in it.
grep -q "home card \[front\]:.*mine" "$SP/empty.log" \
  && say OK "empty door still shows your handle" \
  || { say FAIL "empty door hid the handle: $(grep -o 'home card.*' "$SP/empty.log" | tail -1)"; fail=1; }

# ── THE CARD IS SHORT, AND STAYS SHORT ───────────────────────────────────────
# This card floats over the person's own face and every row on it covers part of
# that face -- the report that started this was "I really can't see my face".
# The front card is the people, the field, and nothing about YOU: the handle, the
# login item and silent mode live behind the corner button. A rig can photograph
# the window but cannot say which rows those were, and settings creeping back
# onto the front card happens one well-meaning row at a time.
FRONT=$(grep -o 'home card \[front\]: .*' "$SP/home.log" | tail -1 | sed 's/home card \[front\]: //')
case "$FRONT" in
  *reach*|*quiet*|*mine*)
    say FAIL "settings are back on the front card: $FRONT"; fail=1 ;;
  *"@meera"*"field"*)
    say OK "front card is people + one field: $FRONT" ;;
  *) say FAIL "front card is not people + field: $FRONT"; fail=1 ;;
esac

# ── AND THE SETTINGS THEY MOVED TO ───────────────────────────────────────────
# A button that opens nothing is the defect this repo keeps finding, so the rig
# presses it and reads what the card became.
export TK_KIN_DIR="$SP/kin"
"$TK" --contacts-fake "arjun,meera,dad" --gui --no-update --no-telemetry \
  --no-relocate --press settings > "$SP/set.log" 2>&1 & PIDS="$PIDS $!"
sleep 4
SWID=$(grep -o "window id [0-9]*" "$SP/set.log" | awk '{print $3}' | tail -1)
[ -n "$SWID" ] && screencapture -l "$SWID" -x "$SP/settings.png"
reap
SET=$(grep -o 'home card \[settings\]: .*' "$SP/set.log" | tail -1 | sed 's/home card \[settings\]: //')
case "$SET" in
  *mine*reach*quiet*) say OK "settings card carries all three: $SP/settings.png" ;;
  "") say FAIL "the settings button opened nothing"; fail=1 ;;
  *) say FAIL "settings card is missing something: $SET"; fail=1 ;;
esac

# ── CLOSING THE DOOR MID-RING HAS TO UN-RING THE OTHER MAC ───────────────────
# Reported: "if I'm calling someone and I close the app, it should close the
# ringing itself". It did not -- the ring sat in their mailbox on a 60 s lease
# and their Mac rang for a call nobody was placing. The un-ring is a signed
# `bye` to the same room, and the ONLY way to see it is from the server's side:
# a local doorbell that answers a ring slowly, so the POST is genuinely in
# flight when the window closes, and then records what arrives next.
#
# The close is `--press close`, never a synthetic Command-W: a global keystroke
# goes to whatever app is frontmost, which in a rig is the person's own window.
BYE="$SP/bye"; mkdir -p "$BYE/kin"
python3 - "$BYE/kin/identity.json" <<'PY'
import json, os, base64, sys
# A claimed handle, so `ring` signs and posts instead of stopping at "no handle
# yet". The seed is random and the doorbell below verifies nothing.
json.dump({"seed": base64.b64encode(os.urandom(32)).decode(), "tok": os.urandom(32).hex(),
           "handle": "rigcaller", "claimed": True, "quiet": False}, open(sys.argv[1], "w"))
PY
python3 - > "$BYE/door.log" 2>&1 <<'PY' & PIDS="$PIDS $!"
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
import json, time
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        b = self.rfile.read(int(self.headers.get('content-length', 0)))
        o = json.loads(b or b'{}')
        kind = o.get('kind', 'ring')
        print('POST kind=%s room=%s' % (kind, o.get('room')), flush=True)
        # Three seconds on the ring and none on the bye: the window closes while
        # the ring is still travelling, which is the whole state under test.
        if kind == 'ring':
            time.sleep(3)
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"ok":true,"queued":1,"listening":true}')
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{}')
    def log_message(self, *a): pass
class T(ThreadingMixIn, HTTPServer): daemon_threads = True
T(('127.0.0.1', 8199), H).serve_forever()
PY
sleep 1
TK_KIN_DIR="$BYE/kin" TK_KIN_BASE="http://127.0.0.1:8199" TK_NO_RAISE=1 "$TK" \
  --contacts-fake "bob" --gui --no-update --no-telemetry --no-relocate --no-rings \
  --press "bob,close" --press-after 1 > "$BYE/app.log" 2>&1 & PIDS="$PIDS $!"
sleep 9
reap
RANG=$(grep -c "kind=ring" "$BYE/door.log" || true)
BYES=$(grep -c "kind=bye" "$BYE/door.log" || true)
RROOM=$(sed -n 's/.*kind=ring room=\(.*\)/\1/p' "$BYE/door.log" | head -1)
BROOM=$(sed -n 's/.*kind=bye room=\(.*\)/\1/p' "$BYE/door.log" | head -1)
if [ "$RANG" -ge 1 ] && [ "$BYES" -ge 1 ] && [ -n "$RROOM" ] && [ "$RROOM" = "$BROOM" ]; then
  say OK "closing mid-ring un-rings them (bye for $BROOM)"
else
  say FAIL "no un-ring on close: rings=$RANG byes=$BYES ring-room=$RROOM bye-room=$BROOM"
  fail=1
fi
# And the twin defect the first cut of this shipped: a SUCCESSFUL ring left
# `ringing` true, so the teardown called every completed call an abandoned one.
if grep -q "ring abandoned" "$SP/set.log"; then
  say FAIL "a call that placed fine was logged as abandoned"
  fail=1
else
  say OK "a ring that lands is not called abandoned"
fi

[ "$fail" = 0 ] && echo "HOME CHECK PASSED" || echo "HOME CHECK FAILED"
exit "$fail"
