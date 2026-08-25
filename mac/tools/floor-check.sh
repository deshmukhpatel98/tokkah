#!/bin/bash
# ── KNOWING WHOSE TURN IT IS, WITHOUT A LIGHT SHOW ──────────────────────────
#
# Two things were asked for, two messages apart, by the same person:
#
#   "People should know when someone is speaking and that they will now be on
#    mute, and then they can also speak back... It has to be a flawless magical
#    experience, because we cannot have two people speaking at the same time."
#
#   "There should be no vignette of any kind. There should not be any effect.
#    It should all be very natural."
#
# The build before this rig answered the first by breaking the second: a
# three-point accent stroke around the whole window with an eighteen-point glow,
# breathing at 0.55 Hz, plus three dots on the picture that swelled into a lit bar
# with a highlight travelling along it. Photographed, window edge, 0-4 pt in, as
# mean (blue - max(red, green)): +4.9 quiet, +25.5 when the far end claimed the
# floor. The edge was 6.4x brighter. That is the effect that was refused.
#
# The answer is not a dimmer glow. It is that the fact belongs on a CONTROL --
# the microphone button, which is already the thing that claims to say whether
# your voice is going out -- and that the picture gets nothing at all.
#
# ── WHAT THIS RIG CLAIMS, AND WHICH ARM RANKS THE OTHER WAY ─────────────────
#
#   1. the picture is not painted on: the window's own edge does not change when
#      the far end takes the floor                       (old build: +20.5)
#   2. the microphone button says it instead: its glyph loses contrast against
#      the button next door                              (old build: no change)
#   3. and the CAMERA button does not move, in any arm -- or 2 is measuring the
#      photograph's exposure and not the microphone
#   4. the three states are three different pictures, in the right order
#   5. a real CLICK on a held microphone still mutes, through the window, and
#      the hit-test audit still reaches the button
#   6. LIVE, with no pin and a real gate on a real call, the state actually
#      leaves `through`
#   7. CONTROL for 6: with the gate off (`--no-gate`, which is what headphones
#      do), it never leaves `through` at all
#   8. the caption is readable in ONE frame, not in twelve
#
# Every one of those numbers was measured against the build before this change,
# by running this rig with TK= pointed at a binary built from b6616e5: arm 1
# reported +20.27 at the edge, arm 4 reported the same 0.8865 mic/cam ratio for
# all three states, and the build had no micfloor= field at all -- so the rig
# stops rather than passing blind. Arm 8 was measured by putting only the
# instrument into that copy and leaving its easing alone: 12 frames.
#
# 5 exists because every interaction bug in this app has lived between the
# handler and the finger, and this change draws inside a button. 3 and 7 exist
# because a rig blind to its own subject reports PASS while shipping the defect,
# which has happened here repeatedly.
#
# Numbers reported, never asserted: the two turn-taking latencies. `cue out` and
# `cue in` bracket classify -> wire -> far end reacts, and `sub out`/`sub in`
# bracket a recognised word to its arrival on the far screen. Both are absolute
# epoch stamps under KIN_CUE_DEBUG so two processes can be subtracted.
set -u
# Ring windows do not throw themselves in front of whatever the person at this
# Mac is doing, and neither may this.
export TK_NO_RAISE=1
# ── KILLS ONLY WHAT THIS SCRIPT STARTED ─────────────────────────────────────
#
# Never `pkill -f`, which takes a REGEX: in a path like `./.build/debug/tk` every
# `.` matches any character, and that pattern has reaped another agent's
# processes in another checkout for hours. A rig may only end what it started.
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/floor-check.$$"
mkdir -p "$SP"
# `.applicationSupportDirectory` resolves through the user record and not $HOME,
# so a rig without this reads and writes the REAL install's contacts and
# identity. And no identity at all: a claim walks @devesh, @deveshp, @devesh2 on
# the real server, squatting names a person may want.
export TK_KIN_DIR="$SP/id"
export TK_NO_IDENTITY=1
export KIN_CUE_DEBUG=1
mkdir -p "$SP/id"
[ -x "$TK" ] || { echo "no tk at $TK -- swift build first"; exit 2; }
python3 -c "import numpy, PIL" 2>/dev/null \
  || { echo "COULD NOT RUN: python3 needs numpy and Pillow to read a photograph"; exit 2; }
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }
note() { printf "       %s\n" "$1"; }
cant() { echo "  COULD NOT RUN: $1"; exit 2; }
# `--mute` is the RIG's speaker flag: the speakers belong to whoever is sitting at
# this Mac, and a rig that plays audio at them is a defect. `--press mic` is the
# app's own microphone button, which is a different thing entirely.
C="--window --video off --mute --no-telemetry --no-update --no-relocate --no-rings"

# ── ONE PHOTOGRAPH, AND THE RECTANGLES THAT GO WITH IT ──────────────────────
#
# `screencapture -l <id>` and never a screen grab: the id is printed by the app
# for exactly this, and a full-screen capture once swept up a person's own
# desktop. `-o` drops the window shadow, so the image is the window and the
# app's own `at=x,y,w,h win=WxH` audit line indexes straight into it.
shoot() {   # $1 = press tokens, $2 = name, $3 = extra flags
  reap
  # `~,~` before the audit, and it is not padding. The reach is EASED -- 300 ms
  # down -- so an audit 0.7 s after the press reads 0.40 on its way to 0.34 and
  # an assertion written against the settled number fails on a working build.
  # The photograph is taken later still, so without this the rig would be
  # asserting one moment and measuring another.
  spawn "$TK" $C ${3:-} --room "flr$$$2" --listen 8334 \
        --press "$1,~,~,?" --press-after 3 > "$SP/$2.log" 2>&1
  perl -e 'select undef,undef,undef,12'
  WID="$(grep -oE 'window id [0-9]+' "$SP/$2.log" | head -1 | grep -oE '[0-9]+')"
  [ -n "$WID" ] || { reap; return 1; }
  screencapture -l "$WID" -o -x "$SP/$2.png"
  grep -oE 'glass icon:(microphone|camera): .*at=[0-9]+,[0-9]+,[0-9]+,[0-9]+ win=[0-9]+x[0-9]+' \
    "$SP/$2.log" > "$SP/$2.rects"
  grep -oE 'audit state controls.*' "$SP/$2.log" | tail -1 > "$SP/$2.state"
  reap
  [ -s "$SP/$2.png" ] && [ -s "$SP/$2.rects" ]
}

# ── THE RULER ───────────────────────────────────────────────────────────────
#
# Two numbers per photograph:
#
#   edge    mean (blue - max(red, green)) in the ring 0-4 pt inside the window's
#           own edge. The accent in this app is blue and the picture behind it in
#           these arms is black, so any accent laid on the edge shows up here and
#           nothing else does. The band has to START at 0: the stroke was drawn at
#           `insetBy(1.5)` with `lineWidth 3`, so a band beginning at 3 pt walks
#           straight past it -- measured, and it reported +1.2 for a rim that is
#           really +20.5, which is a ruler that would have passed the old build.
#
#   ink     mean of the brightest tenth of the pixels inside a button's own
#           rectangle: the glyph, and not the disc it sits on. Reported as a RATIO
#           against the camera button beside it, because that is what a person
#           actually judges -- the row is the reference, nobody reads a glyph's
#           opacity in the absolute -- and because a ratio cancels the window's
#           exposure, its scale and the material underneath.
measure() {  # $1 = name -> "edge micink camink ratio"
  python3 - "$SP/$1.png" "$SP/$1.rects" <<'PY'
import sys, re, numpy as np
from PIL import Image
png, rectfile = sys.argv[1], sys.argv[2]
a = np.asarray(Image.open(png).convert("RGB")).astype(np.float64)
rc = {}
for ln in open(rectfile):
    m = re.search(r'glass icon:(\w+):.*at=(\d+),(\d+),(\d+),(\d+) win=(\d+)x(\d+)', ln)
    if m:
        rc[m.group(1)] = tuple(int(m.group(i)) for i in range(2, 8))
if "microphone" not in rc or "camera" not in rc:
    print("nan nan nan nan"); raise SystemExit
winw = rc["microphone"][4]
H, W = a.shape[:2]
s = W / float(winw)
i0, i1 = 0, int(round(4 * s))
m = np.zeros((H, W), bool)
m[i0:i1, i0:W-i0] = True
m[H-i1:H-i0, i0:W-i0] = True
m[i0:H-i0, i0:i1] = True
m[i0:H-i0, W-i1:W-i0] = True
r, g, b = a[...,0][m], a[...,1][m], a[...,2][m]
edge = float(np.mean(b - np.maximum(r, g)))
def ink(rect):
    x, y, w, h = rect[:4]
    sx, sy, sw, sh = (int(round(v * s)) for v in (x, y, w, h))
    crop = a[sy:sy+sh, sx:sx+sw]
    L = 0.2126*crop[...,0] + 0.7152*crop[...,1] + 0.0722*crop[...,2]
    return float(np.mean(np.sort(L.ravel())[-max(1, int(L.size*0.10)):]))
mi, ca = ink(rc["microphone"]), ink(rc["camera"])
print(f"{edge:.3f} {mi:.2f} {ca:.2f} {mi/ca if ca else float('nan'):.4f}")
PY
}
# `and`, not `&&`. Python is not the shell, and a `&&` inside here is a
# SyntaxError -- which `python3 -c` exits 1 for, so every compound assertion
# quietly reported FAIL on a build that was fine. Caught on the first run of this
# rig; a ruler that fails closed is still a broken ruler.
f() { python3 -c "import sys; sys.exit(0 if ($1) else 1)" 2>"$SP/f.err" || {
        grep -q SyntaxError "$SP/f.err" && cant "assertion is not valid python: $1"; return 1; }; }
r() { python3 -c "print(round($1, 3))"; }

echo "── 1-3. the picture, and the control"
shoot cue-quiet quiet || cant "the window never came up for the quiet arm"
shoot cue-claim claim || cant "the window never came up for the claiming arm"
read -r E_Q MIC_Q CAM_Q R_Q <<<"$(measure quiet)"
read -r E_C MIC_C CAM_C R_C <<<"$(measure claim)"
[ "$E_Q" = "nan" ] && cant "the app did not print both button rectangles"
note "edge accent: quiet $E_Q, far end claiming $E_C"

# THE ONE THE OLD BUILD FAILS. The rim was +20.5 here.
f "abs($E_C - $E_Q) < 2.0" \
  && say "OK" "the window's own edge does not change when the far end takes the floor (Δ$(r "$E_C-$E_Q"))" \
  || say "FAIL" "something is still painted on the picture: the edge moved by $(r "$E_C-$E_Q") -- the old build's rim was +20.5"

echo "── 4. three states, three pictures"
shoot floor-through through || cant "the window never came up for the through arm"
shoot floor-bid bid || cant "the window never came up for the bidding arm"
shoot floor-held held || cant "the window never came up for the held arm"
read -r E_T MIC_T CAM_T R_T <<<"$(measure through)"
read -r E_B MIC_B CAM_B R_B <<<"$(measure bid)"
read -r E_H MIC_H CAM_H R_H <<<"$(measure held)"
note "mic ink / cam ink:  through $R_T   bidding $R_B   held $R_H"

for n in through bid held; do
  grep -qE "micfloor=" "$SP/$n.state" \
    || cant "this build's audit line has no micfloor= field -- the instrument cannot see the subject"
done
grep -qE "micfloor=held/0\.3[0-9]" "$SP/held.state" \
  && say "OK" "PRECONDITION: the app says it is drawing the held state ($(grep -oE 'micfloor=[^ ]+' "$SP/held.state"))" \
  || say "FAIL" "the app did not reach the held state: $(grep -oE 'micfloor=[^ ]+' "$SP/held.state")"

# 2. THE CONTROL SAYS IT. A quarter of the contrast is a large step; the old
# build cannot move this at all, because it has no such state.
f "$R_H < 0.75 * $R_T" \
  && say "OK" "held: the microphone glyph falls to $(r "$R_H/$R_T")x its own through-state, against the button next door" \
  || say "FAIL" "the microphone button says nothing about being held ($R_H vs $R_T)"

f "$R_B < $R_T - 0.03 and $R_B > $R_H + 0.03" \
  && say "OK" "and bidding sits between them ($(r "$R_B/$R_T")x), so the three states are three pictures" \
  || say "FAIL" "bidding is not between held and through: $R_H / $R_B / $R_T"

# 3. THE CONTROL ARM THAT MUST NOT MOVE. If the camera glyph tracks the mic
# glyph, the measurement is of the photograph and not of the microphone.
CAMSPREAD="$(r "max($CAM_T,$CAM_B,$CAM_H)/max(1e-6,min($CAM_T,$CAM_B,$CAM_H))")"
f "$CAMSPREAD < 1.05" \
  && say "OK" "CONTROL: the camera button is unmoved across all three (${CAMSPREAD}x), so this is the microphone and not the exposure" \
  || say "FAIL" "CONTROL: the camera glyph moved ${CAMSPREAD}x too -- this ruler is measuring the whole photograph"

echo "── 5. a held microphone is still a button"
# ── THE RIG HAS TO CLICK ────────────────────────────────────────────────────
#
# `@mic` builds a real NSEvent at the control's own centre and sends it through
# `window.sendEvent`, so it goes through every `hitTest` on the way down. Every
# interaction bug in this app has lived between the handler and the finger, and
# this change draws inside that button -- a decoration that eats clicks is the
# exact defect this project has shipped before (`hitTest` returned the blur).
reap
spawn "$TK" $C --room "flr$$click" --listen 8335 \
      --press "floor-held,?,@mic,?" --press-after 3 > "$SP/click.log" 2>&1
perl -e 'select undef,undef,undef,10'
reap
grep -qE "^audit OK   mic " "$SP/click.log" \
  && say "OK" "the hit test reaches the microphone while it is held: $(grep -oE '^audit OK   mic .*' "$SP/click.log" | head -1)" \
  || say "FAIL" "a finger cannot reach the microphone button: $(grep -oE '^audit (OK|FAIL|SELF) *mic .*' "$SP/click.log" | head -1)"
grep -qE "click mic: sent" "$SP/click.log" \
  || say "FAIL" "the click was never sent -- nothing below this line means anything"
grep -oE 'audit state controls.*' "$SP/click.log" | tail -1 | grep -qE "mic=muted" \
  && say "OK" "and a real click through the window still mutes it" \
  || say "FAIL" "the click landed and the microphone did not mute: $(grep -oE 'mic=[a-z]+' "$SP/click.log" | tail -1)"
grep -oE 'audit state controls.*' "$SP/click.log" | tail -1 | grep -qE "micfloor=muted" \
  && say "OK" "and a muted microphone stops reporting a floor, which is the slash's job now" \
  || say "FAIL" "muted and still reporting a floor state: $(grep -oE 'micfloor=[^ ]+' "$SP/click.log" | tail -1)"

echo "── 6-7. LIVE: a real gate on a real call, and the arm that must not move"
# ── NO PIN BELOW THIS LINE ──────────────────────────────────────────────────
#
# Two processes, one room, one Mac, both microphones live, so each end's decoded
# audio really does arrive at the other's gate and the gate really does decide.
# Nothing is injected: what this shows is that the state arm 4 photographed is
# one the product reaches on its own.
#
# ── AND WHY THE MARGIN IS TURNED UP ────────────────────────────────────────
#
# Two co-located copies cannot produce a hold at the shipped margin, and the
# reason is geometry rather than code. The gate holds this end when the far end
# is talking AND the near microphone is not louder than the echo can explain:
# `nearEnv > coupling * far * effMargin`. Both copies hear the SAME room at the
# same instant, so `nearEnv` and `far` are the same sound -- and with coupling
# measured at 0.56 here and `effMargin` floored at 1.35, near always wins by 1.5x
# and neither end is ever held. Measured: a full 20 s live call, seven bids, all
# seven granted in a median of 0 ms, `micfloor` never once leaving `through`.
#
# That is not the gate failing. It is this rig standing in the far end's room.
# `--gate-margin 20` restores the asymmetry a real call has for free, and it
# changes a THRESHOLD and not a decision -- the same class of rig override as
# TK_CAPTION_SCALE. The control arm below gets the identical margin and differs
# only in `--no-gate`, so the two arms are separated by one boolean and nothing
# else.
live() {   # $1 = name, $2 = extra flags, $3/$4 = ports
  reap
  spawn "$TK" $C $2 --room "flr$$$1" --listen "$3" --peer "127.0.0.1:$4" \
        > "$SP/$1-a.log" 2>&1
  spawn "$TK" $C $2 --room "flr$$$1" --listen "$4" --peer "127.0.0.1:$3" \
        --press "utter:so_the_thing_about_a_call_is_you_never_know_whose_turn_it_is" \
        --press-after 8 > "$SP/$1-b.log" 2>&1
  perl -e 'select undef,undef,undef,22'
  reap
}
# The record is `mic floor <epoch> a -> b`, printed on every CHANGE by the app
# itself, not an audit line sampled five times. A state that is true for half a
# call can be missed by five samples, and this rig's first run missed it.
seen() { grep -oE '^mic floor [0-9.]+  [a-z]+ -> [a-z]+' "$1" \
           | sed -E 's/.* -> //' | sort -u | tr '\n' ' '; }

live gate "--force-gate --gate-margin 20" 8330 8331
grep -q "connected via" "$SP/gate-a.log" || cant "the live pair never connected"
grep -qE "^\[in\] " "$SP/gate-a.log" \
  || cant "no microphone opened on the live arm -- silence here is not evidence"
SEEN="$(seen "$SP/gate-a.log")"
note "live transitions on A: [$SEEN]  ($(grep -cE '^mic floor ' "$SP/gate-a.log") changes)"
echo " $SEEN" | grep -qE "held|bidding" \
  && say "OK" "on a live call with a real gate the microphone button actually leaves 'through': [$SEEN]" \
  || say "FAIL" "the gate never reached the button on a live call -- arm 4 proved a drawing and nothing else"

live nogate "--no-gate --gate-margin 20" 8332 8333
grep -q "connected via" "$SP/nogate-a.log" || cant "the control pair never connected"
grep -qE "^\[in\] " "$SP/nogate-a.log" \
  || cant "no microphone opened on the control arm -- it cannot rank anything"
SEEN2="$(seen "$SP/nogate-a.log")"
# ── AN ARM THAT NEVER RAN IS NOT AN ARM THAT PASSED ─────────────────────────
#
# The control's evidence is an ABSENCE -- no transition to `held` -- and an
# instrument that never looked returns exactly the same absence. What runs the
# floor ticker is a far-end vocal edge (`cue in`), so if there were none of those
# this arm proves nothing at all and has to say so rather than pass.
CUEIN="$(grep -cE '^cue in' "$SP/nogate-a.log")"
[ "$CUEIN" -gt 0 ] \
  || cant "the control arm saw no far-end vocal edges at all ($CUEIN), so nothing ever woke the thing it is supposed to be watching"
note "control arm was awake: $CUEIN far-end vocal edges arrived"
echo " $SEEN2" | grep -qE "held|bidding" \
  && say "FAIL" "CONTROL: with the gate OFF the button still claimed to be held: [$SEEN2]" \
  || say "OK" "CONTROL: same room, same margin, gate off -- which is what headphones do -- and it never leaves 'through' [${SEEN2:-no transitions at all}]"

echo "── 8. the caption is readable in one frame"
reap
spawn "$TK" $C --room "flr$$rise" --listen 8336 \
      --press "band-rise" --press-after 3 > "$SP/rise.log" 2>&1
perl -e 'select undef,undef,undef,7'
reap
# ANCHORED. `press band-rise: due at 3218 ms...` is the press loop announcing the
# token and it matches an unanchored pattern first, so the rig parsed "due at
# 3218 ms" as a frame count and reported it as a failure.
RISE="$(grep -oE '^band-rise: .*' "$SP/rise.log" | head -1)"
[ -n "$RISE" ] || cant "this build has no band-rise token -- the instrument cannot see the subject"
note "$RISE"
FR="$(echo "$RISE" | sed -E 's/.*readable\(>=90%\) after ([0-9-]+) frame.*/\1/')"
HT="$(echo "$RISE" | sed -E 's/.*height on frame 1 = ([0-9]+)%.*/\1/')"
case "$FR" in ''|*[!0-9]*) cant "could not read a frame count out of: $RISE";; esac
f "$FR >= 1 and $FR <= 2" \
  && say "OK" "a caption is readable $FR frame(s) after it arrives (measured on the build before this one: 12 frames, 400 ms)" \
  || say "FAIL" "a caption takes $FR frames to become readable"
f "$HT >= 99" \
  && say "OK" "and it is laid out at full height on the first frame, so nothing is clipped while it grows" \
  || say "FAIL" "the band is only $HT% of the height it needs on the first frame"

echo "── numbers, reported not asserted"
# ── A SUBTITLE ONLY TRAVELS IF IT CANNOT BE HEARD ───────────────────────────
#
# The rule is the sender's: nothing goes on the wire while your voice is audible.
# So the first version of this measurement caught nothing at all -- both ends
# were audible for the whole call, correctly, and the stopwatch had no event to
# time. B mutes itself first, exactly as `tools/subtitle-check.sh` does, which is
# the only condition under which the words this measures exist.
reap
spawn "$TK" $C --room "flr$$sub" --listen 8337 --peer "127.0.0.1:8338" \
      > "$SP/sub-a.log" 2>&1
spawn "$TK" $C --room "flr$$sub" --listen 8338 --peer "127.0.0.1:8337" \
      --press "mic,utter:so_the_thing_about_a_call_is_you_never_know_whose_turn_it_is,~,~" \
      --press-after 8 > "$SP/sub-b.log" 2>&1
perl -e 'select undef,undef,undef,20'
reap
# A missing number has to be distinguishable from a failed run. Silence from a
# pair that never connected is not "the subtitles are fast".
grep -q "connected via" "$SP/sub-a.log" \
  || note "subtitle arm never connected -- no number below, and it is not a result"

# ── TWO LATENCIES, FROM ABSOLUTE STAMPS ON TWO PROCESSES ────────────────────
#
# `cue out` is this end classifying, `cue in` is the far end being told. Matched
# in order on the VALUE, so a bid is paired with a bid. These are WALL CLOCK on a
# shared machine and are reported for shape, never asserted: while this was
# written, four agents were building Swift on ten cores and the load average hit
# 56. A threshold here would be measuring the other agents.
python3 - "$SP" <<'PY'
import sys, re, os
sp = sys.argv[1]
def stamps(path, pat):
    out = []
    if not os.path.exists(path): return out
    for ln in open(path, errors="replace"):
        m = re.match(pat, ln)
        if m: out.append((float(m.group(1)), m.group(2)))
    return out
# ── AND THE MATCHER HAS TO ADMIT WHAT IT CANNOT PAIR ────────────────────────
#
# These two sequences are NOT guaranteed one-to-one. The status byte is sent
# edge-triggered and repaired level-triggered once a second, so a dropped edge
# means the far end learns the value a whole second later -- and a matcher that
# greedily takes "the next cue in with this value" then pairs an early departure
# with a late arrival and calls the result a latency. It did: 4 ms on one run and
# 3365 ms on the next, off the same build, which is a broken ruler and not a
# variable network.
#
# So: bounded, and the two populations reported separately. Under 200 ms is an
# edge that flew; anything past that is the once-a-second backstop doing its job,
# which is a real and different event. `measure-the-rigs-noise-first`.
outs = stamps(f"{sp}/gate-b.log", r"cue out ([0-9.]+)\s+me -> (\d+)")
ins  = stamps(f"{sp}/gate-a.log", r"cue in\s+([0-9.]+)\s+peer -> (\d+)")
# LOCAL, never a moving pointer. The first version walked a monotonic index, so a
# single unreflected edge -- the classifier going 0->2->0 faster than the flush --
# shifted every pair after it, and the rig reported a MEDIAN OF 7 SECONDS off a
# build whose real answer is a few milliseconds. It looked exactly like a
# catastrophic finding. Each departure is now matched inside its own 1.5 s window
# or not at all, so a desync costs one pair instead of all of them.
used, fast, slow, lost = set(), [], [], 0
for t, v in outs:
    hit = None
    for k, (t2, v2) in enumerate(ins):
        if k in used or v2 != v or t2 < t or t2 > t + 1.5:
            continue
        hit = k; break
    if hit is None:
        lost += 1; continue
    used.add(hit)
    dt = (ins[hit][0] - t) * 1000.0
    (fast if dt <= 200 else slow).append(dt)
if fast:
    fast.sort()
    print(f"       floor cue, classify -> far end told: n={len(fast)} within a hop, "
          f"p50 {fast[len(fast)//2]:.1f} ms  min {fast[0]:.1f}  max {fast[-1]:.1f}   (loopback)")
else:
    print("       floor cue: no edge arrived within 200 ms in this run")
print(f"       ... {len(slow)} took longer (the 1 Hz level-triggered repair), "
      f"{lost} of {len(outs)} departures never matched an arrival")
# ── ONLY THE ONES THAT ACTUALLY WENT ────────────────────────────────────────
#
# `sub out` is printed for EVERY utterance, including the ones the send rule
# correctly refuses because the speaker can be heard -- those carry
# "(not sent -- audible)". Counting them made a working run read as "3 sent,
# 0 arrived", which looks like a transport failure and is the send rule doing its
# job. The negative lookahead is the whole fix.
so = stamps(f"{sp}/sub-b.log", r'sub out ([0-9.]+)\s+"([^"]*)"(?!.*not sent)')
si = stamps(f"{sp}/sub-a.log", r'sub in\s+([0-9.]+)\s+"([^"]*)"')
pairs = []
for t, w in so:
    for t2, w2 in si:
        if w2 == w and t2 >= t:
            pairs.append((t2 - t) * 1000.0); break
if pairs:
    pairs.sort()
    print(f"       subtitle, recognised -> drawn on the far screen: n={len(pairs)} "
          f"p50 {pairs[len(pairs)//2]:.1f} ms  min {pairs[0]:.1f}  max {pairs[-1]:.1f}")
    # ── AND WHAT THIS NUMBER IS NOT ────────────────────────────────────────
    #
    # It is the TRANSPORT, from the recogniser publishing a revision to the far
    # end's caption layer being handed it. It is not "how long after somebody
    # speaks do the words appear", and reporting it as if it were would be the
    # most flattering possible reading. Everything upstream of `sub out` is
    # bigger than everything downstream of it by two orders of magnitude:
    # a 120 ms poll before audio is even fed to the recogniser (main.swift's
    # subtitle thread), Subtitles.MIN_MS = 260 ms of audio before a request is
    # worth making, and then the engine -- Apple's own analyzer is measured in
    # AppleSpeech.swift at ~989 ms to a first word and ~960 ms between
    # revisions; the daemon path revises every 350 ms plus ~85 ms per request.
    print("       (that is the TRANSPORT only. Upstream of it: a 120 ms feed poll, "
          "260 ms minimum audio,")
    print("        and the recogniser itself -- ~989 ms to a first word on Apple's, "
          "~350 ms/revision on the daemon)")
else:
    print(f"       subtitle: {len(so)} sent, {len(si)} arrived, none matched -- "
          "no number from this run")
PY
# ── TIME TO FLOOR, FROM THE PRODUCT'S OWN ACCOUNTING ────────────────────────
#
# `TurnLedger.timeToFloorMs`, which the app already keeps: from the classifier
# calling this end a bid to this end's microphone actually being audible. It is
# the number the interruption question is really asking, it is measured inside
# one process so no clock has to be reconciled, and it is the app's instrument
# rather than this rig's -- which is why it is quoted rather than recomputed.
# `a A` / `b B` rather than `${e^^}`: that is a bash 4 expansion and macOS ships
# bash 3.2, where it is a "bad substitution" that kills the line at runtime and
# nothing at parse time -- so `bash -n` passed and the rig printed an error where
# a number should have been.
set -- a A b B
while [ $# -gt 0 ]; do
  TTF="$(grep -oE 'bids \([0-9]+ heard, median [^)]*\)' "$SP/gate-$1.log" | tail -1)"
  [ -n "$TTF" ] && note "time to floor, end $2: $TTF"
  shift 2
done
FLOOR="$(grep -oE 'floor: yours .*' "$SP/gate-a.log" | tail -1)"
[ -n "$FLOOR" ] && note "ledger on A: $FLOOR"
FLOOR2="$(grep -oE 'floor: yours .*' "$SP/gate-b.log" | tail -1)"
[ -n "$FLOOR2" ] && note "ledger on B: $FLOOR2"

echo
if [ "$fail" = 0 ]; then
  echo "FLOOR CHECK PASSED -- the picture is untouched, the microphone button carries"
  echo "  the three states, a finger still reaches it, and a real gate gets there"
else
  echo "FLOOR CHECK FAILED -- see above; logs and photographs in $SP (KEEP=1 to keep them)"
fi
exit $fail
