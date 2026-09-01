#!/bin/bash
# ── IS THE APP TRANSPARENT GLASS, AND IS THE PICTURE UNTOUCHED? ──────────────
#
# Two claims, from the person using this app, on two different days:
#
#     "everywhere I want transparent liquid glass, not frosted"
#     "there should be no vignette of any kind... it should all be very natural"
#
# Both had been contradicted by the code for months while the comments describing
# it said otherwise. `Glass.swift`'s header said "the control row is `.clear`" --
# true of the control row, false of the nine other surfaces, every one of which
# spelled `.regular` at its own call site. Four separate `CAGradientLayer`s dimmed
# the window, each justified in a comment citing the same HIG sentence, and
# together they were a vignette. Nothing in the running program ever stated what it
# was, so nothing could catch either.
#
# So the app says it now -- `Glass.describeGlass`, printed on the `?` audit -- and
# this holds it to it. Three kinds of evidence, because each is blind to something:
#
#   STRUCTURAL   what every surface asked the system for. Cheap, total, and the
#                only check that covers a surface which is not on screen.
#   PHOTOMETRIC  what a camera sees through it, over a calibrated background. The
#                structural check cannot see a fill painted behind the material;
#                this can.
#   VIGNETTE     what the app did to a flat, evenly lit picture. Any variation
#                across that frame is the app's, because there is none in the
#                source.
#
# ── AND EVERY ONE OF THEM HAS AN ARM THAT MUST RANK THE OTHER WAY ────────────
#
# `TK_GLASS_STYLE=regular` forces the frosted material, `TK_REDUCE_TRANSPARENCY=1`
# forces the opaque fallback, and the measuring script's `--calibrate` is run FIRST
# and asked six questions whose answers are already known. Without those, "every
# surface reports clear" is satisfied by a reader wired to a constant, and "no
# vignette" is satisfied by a meter that returns 1.000 for everything. Both of
# those bugs were real in this file's own history and both were found by an arm
# that had to fail.
set -u
# Nothing here goes in front of the person using this Mac. Also load-bearing for
# the numbers: see PART FOUR on what window activation does to the material.
export TK_NO_RAISE=1
PIDS=""
spawn() { "$@" & LAST_PID=$!; PIDS="$PIDS $LAST_PID"; }
reap() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=""; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HERE/../.build/debug/tk}"
MEASURE="$HERE/glass-measure.py"
BARS="$HERE/glass-bars.py"
SP="${SCRATCH:-${TMPDIR:-/tmp}}/glass-check.$$"
mkdir -p "$SP"
# TK_KIN_DIR because `.applicationSupportDirectory` resolves through the user
# record and not $HOME, so a rig without it reads and writes the REAL install's
# contact list.
export TK_KIN_DIR="$SP/id"
mkdir -p "$SP/id"
trap 'reap; [ -n "${KEEP:-}" ] || rm -rf "$SP"' EXIT

cant() { echo "GLASS CHECK COULD NOT RUN -- $1"; exit 2; }
[ -x "$TK" ] || cant "no tk at $TK -- swift build --package-path mac first"
[ -f "$MEASURE" ] || cant "no $MEASURE"
[ -f "$BARS" ] || cant "no $BARS"
command -v ffmpeg >/dev/null || cant "no ffmpeg -- the calibrated backgrounds are encoded with it"
command -v screencapture >/dev/null || cant "no screencapture"
python3 -c "import numpy, PIL" 2>/dev/null || cant "python3 needs numpy and Pillow"

# ── THE RULER IS CHECKED BEFORE ANYTHING IS MEASURED WITH IT ─────────────────
#
# First, and fatal, because this project has a law about it and this file earned
# the law twice over. The first measuring script built its reference by joining the
# strip left of the card to the strip right of it, which put a phase break in the
# middle of a periodic pattern; it then reported that NOTHING survives a pane of
# clear glass, a heavy blur, or an opaque grey rectangle -- the same answer for all
# three, and that answer looks exactly like a catastrophic real result. The second
# found text by brightness, which on a light background classified the background
# as text and returned no reading at all in the one case that had to fail loudly.
echo "── calibrating the instruments ──"
python3 "$MEASURE" --calibrate || cant "the measuring script fails its own known answers (above)"

# ── THE TWO BACKGROUNDS ──────────────────────────────────────────────────────
#
# BARS: vertical bars of two bright saturated colours at a known period. A material
# that blurs is a low-pass filter, so the amplitude at the bar frequency is exactly
# the thing frosting destroys and clear glass keeps. 40 pt bars, which is the scale
# of the features a face has -- an eye, a nostril, the edge of a jaw.
#
# FLAT: one even, bright colour. Any variation across THAT frame in a photograph is
# something the app painted, and a vignette becomes a number.
#
# Synthetic on purpose, and this project's rule is normally the opposite. The rule
# is about judging a decoder or a camera, where synthetic texture behaves
# differently from a real one. This is photometry: the ruler has to have a known
# answer, and a face does not. The real footage is used for the same comparison by
# eye, which is the half a number cannot do.
#
# `-src` on the sources, because the photographs are named after their arms and a
# capture called `flat.png` landing on a source called `flat.png` is a rig
# measuring its own input and reporting a perfect result.
python3 "$BARS" "$SP/bars-src.png" >/dev/null || cant "could not draw the bar pattern"
python3 - "$SP" <<'PY' || cant "could not draw the flat field"
import sys
from PIL import Image
Image.new("RGB", (1280, 720), (235, 233, 228)).save(f"{sys.argv[1]}/flat-src.png")
PY
for f in bars flat; do
  ffmpeg -y -loglevel error -loop 1 -i "$SP/$f-src.png" -t 40 -r 30 \
    -c:v libx264 -qp 0 -pix_fmt yuv444p "$SP/$f.mov" 2>/dev/null \
    || cant "ffmpeg could not encode $f.mov"
done

# ── ONE ARM: A CALL WINDOW OVER A KNOWN BACKGROUND, PHOTOGRAPHED ─────────────
#
# `--calling meera` because the card that started all of this is the one that says
# who you are ringing, and it is the largest surface in the app. One process and no
# peer: before the far end arrives you ARE the window, so the card sits over this
# process's own `--video` source and nothing has to be synchronised.
#
# `screencapture -l <id>`, never a screen grab: the id is printed by the app for
# exactly this, and a full-screen capture once swept up a person's own desktop.
# `-o` drops the window shadow, which is not part of the window.
#
# ── A ROOM PER ARM, WHICH IS NOT A DETAIL ───────────────────────────────────
#
# Every arm used `--room glass$$` -- one name for all four -- and the fourth one
# photographed a black window with "reconnecting…" in the status pill and no
# picture, no card and nothing to measure. Sharing a room made the rendezvous
# believe a peer had been there and gone, which hides the waiting card and stops
# the local picture.
#
# The reason it is worth a paragraph is what the rig then did with it: the vignette
# assertion PASSED. A flat, uniform, perfectly even black rectangle has no vignette
# in it, so the meter honestly reported 0.000 deviation and the rig honestly called
# it a pass. Nothing in the assertion was wrong; there was simply nothing in the
# photograph. The only thing that caught it is the control arm three lines further
# down, which laid a known gradient over the same photograph and expected the meter
# to notice -- and it could not, because you cannot darken black.
#
# Hence `saw_picture` below. An arm now has to prove there was something to look at
# before anything it says about it counts.
arm() {  # arm <label> <media> [env=val ...]
  local label="$1" media="$2"; shift 2
  local log="$SP/$label.log"
  spawn env "$@" "$TK" --window --room "glass$$$label" --listen 8095 --peer 127.0.0.1:8096 \
    --video "$media" --mute --no-telemetry --no-update --no-relocate --no-rings \
    --no-subtitles --calling meera --press-after 6 --press "?" > "$log" 2>&1
  perl -e 'select undef,undef,undef,8'
  local id
  id=$(grep -m1 -oE "^window id [0-9]+" "$log" | awk '{print $3}')
  [ -n "$id" ] || { reap; cant "$label never opened a window: $(sed -n '1,3p' "$log")"; }
  screencapture -o -x -l "$id" "$SP/$label.png"
  perl -e 'select undef,undef,undef,1'
  reap
  [ -s "$SP/$label.png" ] || cant "$label: screencapture produced nothing for window $id"
  grep -q "^glass card:" "$log" || cant "$label printed no glass audit -- the ? press never ran"
  # The card has to be on screen, or the rectangle every measurement below aims at
  # is a rectangle of whatever happened to be there instead.
  grep -q "^glass card:.*shown=true" "$log" \
    || cant "$label: the calling card was not on screen -- $(grep -m1 -oE 'card=[a-zA-Z]*' "$log" || echo 'no card state'); status was $(grep -m1 -oE 'status=[a-zA-Z]*' "$log" || echo unknown)"
  saw_picture "$label"
}

# The photograph has to contain the background it was supposed to contain. A window
# showing nothing is uniform, and uniform passes a vignette check perfectly.
saw_picture() {
  python3 - "$SP/$1.png" "$1" <<'PY' || cant "$1: the window was not showing the test picture -- see above"
import sys
import numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(float) / 255
# The left eighth of the frame: no control has ever been there, so it is the
# picture or it is nothing.
strip = a[:, :a.shape[1] // 8]
mean = float(strip.mean())
if mean < 0.25:
    print(f"  {sys.argv[2]}: the picture area is near-black (mean {mean:.3f});"
          " the window was not showing the video")
    sys.exit(1)
PY
}

echo "── photographing ──"
arm clear   "$SP/bars.mov"
arm regular "$SP/bars.mov" TK_GLASS_STYLE=regular
arm reduced "$SP/bars.mov" TK_REDUCE_TRANSPARENCY=1
arm flat    "$SP/flat.mov"

# ── AND THE JOIN WINDOW, WHICH NO RIG HAD EVER PHOTOGRAPHED ──────────────────
#
# Two of the app's surfaces live only here, and until `TK_NO_RAISE` was honoured in
# `Launcher.askRoom` this window could not be opened by a harness at all: it threw
# itself in front of whatever the person at this Mac was doing and then waited for
# a click. So the policy held for fifteen surfaces and was never once checked on
# the other two, which is the exact shape of how it drifted in the first place.
spawn "$TK" --gui --no-telemetry --no-update --no-relocate --mute > "$SP/gui.log" 2>&1
perl -e 'select undef,undef,undef,6'
reap

fail=0
say() { printf "  %-4s %s\n" "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }
val() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }

rect_of() {  # the card's rectangle, from the app's own audit
  grep -m1 -E "^glass card:" "$SP/$1.log" \
    | sed -E 's/.*at=([0-9]+),([0-9]+),([0-9]+),([0-9]+) win=([0-9]+)x.*/\1 \2 \3 \4 \5/'
}
active_of() { grep -m1 -oE "active=[^ ]+" "$SP/$1.log"; }
kept() { python3 "$MEASURE" "$SP/$1.png" $(rect_of "$1") | val "['kept']['$2']"; }

echo
echo "── 1. EVERY SURFACE ASKED FOR CLEAR LIQUID GLASS ────────────────────────"
# The whole policy, on every surface the process ever built -- including the ones
# not currently on screen, which a photograph can never reach and which are exactly
# where a `.regular` would survive unnoticed.
TOTAL=$(grep -c "^glass " "$SP/clear.log")
[ "${TOTAL:-0}" -ge 12 ] \
  && say "OK" "the call window reported $TOTAL surfaces" \
  || say "FAIL" "only ${TOTAL:-0} surfaces reported -- the audit is not seeing the app"
NOTCLEAR=$(grep "^glass " "$SP/clear.log" | grep -vc "style=clear")
[ "${NOTCLEAR:-1}" = "0" ] \
  && say "OK" "and every one of them is style=clear" \
  || { say "FAIL" "$NOTCLEAR surfaces are not clear:"
       grep "^glass " "$SP/clear.log" | grep -v "style=clear" | sed 's/^/         /'; }
# ── AND THE WORDS ON THEM CAN BE READ IN A BRIGHT ROOM ──────────────────────
#
# The one requirement this app was asked for in the person's own words --
# "visibility has to be best even in bright environments, because this is liquid
# glass" -- and the only one with a meter in the app and no threshold anywhere.
# `Glass.contrastRatios` has reported `ink=fg N muted N` for every surface since
# the adaptive dim was built, and nothing has ever held it to a number: a meter
# with no assertion is `green-metrics-can-hide-defects` waiting to happen, because
# the number can drift a long way before a photograph looks obviously wrong.
#
# Two bars, from WCAG, and they are different on purpose:
#
#   TEXT (`want=0.26` -- the panel, the pills, the cards, the invite link) has to
#   clear 4.5:1. These are sentences somebody reads.
#
#   GLYPHS (`want=0.42` -- the six round buttons) have to clear 3:1, the bar for
#   non-text contrast. An icon is not a paragraph.
#
# Measured on this rig's brightest calibrated background (behind=0.83): text 8.6
# and 6.4, glyphs 4.4 and 3.3. The thresholds are below those with real margin, so
# this arm fails on a regression rather than on noise.
contrast_floor() {                  # contrast_floor <want> <fg floor> <muted floor> <what>
  local want="$1" fgmin="$2" mutmin="$3" what="$4" bad=0 worst=""
  while read -r name behind fg muted; do
    [ -z "${fg:-}" ] && continue
    # Only surfaces that are actually over something bright: `behind=0.00` is a
    # surface the sampler never saw under a picture, and a ratio against black is
    # not evidence about a bright room.
    awk -v b="$behind" 'BEGIN{exit !(b+0 > 0.3)}' || continue
    if awk -v a="$fg" -v m="$fgmin" 'BEGIN{exit !(a+0 < m+0)}' \
       || awk -v a="$muted" -v m="$mutmin" 'BEGIN{exit !(a+0 < m+0)}'; then
      bad=$(( bad + 1 )); worst="$worst $name(fg $fg, muted $muted, behind $behind)"
    fi
  done < <(grep "^glass " "$SP/clear.log" \
           | grep "want=$want" \
           | sed -E 's/^glass ([^:]+):.*behind=([0-9.]+).*ink=fg ([0-9.]+) muted ([0-9.]+).*/\1 \2 \3 \4/' \
           | grep -E '^[^ ]+ [0-9.]+ [0-9.]+ [0-9.]+$')
  [ "$bad" = 0 ] \
    && say "OK" "$what over a bright picture: every surface clears ${fgmin}:1 / ${mutmin}:1" \
    || say "FAIL" "$bad $what surfaces are too faint to read over a bright picture:$worst"
}
contrast_floor "0.26" 4.5 4.5 "text"
contrast_floor "0.42" 3.0 3.0 "glyphs"
# AND THE METER MUST HAVE SEEN A BRIGHT PICTURE AT ALL. Every surface reporting
# `behind=0.00` means the backdrop sampler is blind, and both arms above would
# then pass by having nothing to judge -- `blind-instruments-report-negatives`.
LITSURF=$(grep "^glass " "$SP/clear.log" | grep -cE "behind=0\.[3-9]")
[ "${LITSURF:-0}" -ge 3 ] \
  && say "OK" "and $LITSURF surfaces really were over a lit picture when measured" \
  || say "FAIL" "only ${LITSURF:-0} surfaces saw any brightness -- the contrast arms judged nothing"

NOTLIQUID=$(grep "^glass " "$SP/clear.log" | grep -vc "path=liquid")
[ "${NOTLIQUID:-1}" = "0" ] \
  && say "OK" "and every one took the real Liquid Glass path, not a fallback" \
  || say "FAIL" "$NOTLIQUID surfaces fell back to a blur or an opaque surface"
# ── THE FILL IS THE ONE THAT MADE IT MILKY ──────────────────────────────────
# An opaque colour behind Liquid Glass is a rectangle with a material's rim on it,
# and it is what the class this replaced did for its entire life. `fill` is the
# heaviest alpha on the material's own layer AND on the wrapper's -- the wrapper
# because its layer is the un-rounded outer box, which is how a "harmless"
# background colour once painted a hard-edged black rectangle across a link.
FILLED=$(grep "^glass " "$SP/clear.log" | grep -vc "fill=none")
[ "${FILLED:-1}" = "0" ] \
  && say "OK" "and nothing is painted behind any of them (fill=none everywhere)" \
  || { say "FAIL" "$FILLED surfaces have a fill behind the material:"
       grep "^glass " "$SP/clear.log" | grep -v "fill=none" | sed 's/^/         /'; }
# The named surfaces, so a rename or a deletion cannot quietly shrink the audit to
# a set of things that all happen to pass.
for s in card sheet pill caption url dial camPicker; do
  grep -q "^glass $s:" "$SP/clear.log" \
    && say "OK" "$s is in the audit" \
    || say "FAIL" "$s never reported -- the policy is unproven for it"
done
BARBTNS=$(grep -c "^glass icon:" "$SP/clear.log")
[ "${BARBTNS:-0}" -ge 5 ] \
  && say "OK" "and $BARBTNS bar circles" \
  || say "FAIL" "only ${BARBTNS:-0} bar circles reported"

echo
echo "── 2. THE JOIN WINDOW'S TWO SURFACES, WHICH NOTHING USED TO REACH ───────"
if grep -q "^glass " "$SP/gui.log"; then
  for s in joinCard hintPill; do
    grep -q "^glass $s:.*style=clear" "$SP/gui.log" \
      && say "OK" "$s is clear Liquid Glass too" \
      || say "FAIL" "$s: $(grep -m1 "^glass $s:" "$SP/gui.log" || echo 'never reported')"
  done
  grep "^glass " "$SP/gui.log" | grep -vc "fill=none" | grep -q "^0$" \
    && say "OK" "and nothing is painted behind them either" \
    || say "FAIL" "the join window paints a fill behind a surface"
else
  say "FAIL" "the join window printed no glass audit: $(sed -n '1,3p' "$SP/gui.log" | tr '\n' ' ')"
fi

echo
echo "── 3. THE READER IS NOT WIRED TO A CONSTANT ─────────────────────────────"
# Everything above is satisfied by a `describeGlass` that returns "clear" whatever
# the object says. So the arm that must rank the other way: the one environment
# variable in the app that can produce a frosted surface, and the audit has to
# notice. Nothing in the product can set it -- there is no variant parameter and no
# branch on anything the app knows.
REG=$(grep -c "^glass .*style=regular" "$SP/regular.log")
[ "${REG:-0}" -ge 12 ] \
  && say "OK" "CONTROL: forced frosted, and the audit says style=regular ($REG surfaces)" \
  || say "FAIL" "CONTROL: the audit still said clear under TK_GLASS_STYLE=regular -- it is reading the argument, not the object"
# And the same for the fallback: a path and a fill it must be able to see.
PLAIN=$(grep -c "^glass .*path=plain" "$SP/reduced.log")
[ "${PLAIN:-0}" -ge 12 ] \
  && say "OK" "CONTROL: Reduce Transparency collapses all $PLAIN surfaces to path=plain" \
  || say "FAIL" "CONTROL: Reduce Transparency did not change the path -- the reader is blind to it"
OPAQUE=$(grep -c "^glass .*path=plain fill=none\|^glass .*path=plain.*fill=none" "$SP/reduced.log")
[ "${OPAQUE:-1}" = "0" ] \
  && say "OK" "CONTROL: and every one of them reports a fill, so fill=none above means something" \
  || say "FAIL" "CONTROL: an opaque surface reported fill=none -- the fill reader sees nothing"

echo
echo "── 4. AND A CAMERA AGREES, OVER A CALIBRATED BACKGROUND ─────────────────"
# ── WINDOW ACTIVATION CHANGES THE MATERIAL, SO IT IS READ AND REPORTED ──────
#
# Measured here: the same build with the same dim keeps either 0.67 or 0.17 of the
# picture depending only on whether Kin is the front application, stable to three
# decimals within a run and flipping between runs of an identical command. The
# rig's own null A/B -- four identical runs -- put its noise at 0.0003, which is
# what proved the two modes were real and not scatter.
#
# A rig cannot bring a window to the front on a Mac somebody is using, so the
# clear-versus-frosted comparison in pixels is only available some runs. It is
# reported when it lands and named as not-reached when it does not. It is NOT the
# load-bearing check: part 1 catches a frosted app in any state, and part 3 proves
# part 1 can see frosting.
A_CLEAR=$(active_of clear); A_REG=$(active_of regular); A_RED=$(active_of reduced)
K_CLEAR=$(kept clear bars); K_REG=$(kept regular bars); K_RED=$(kept reduced bars)
C_CLEAR=$(kept clear colour)
# ── AND THE PATTERN HAS TO BE IN THE PHOTOGRAPH ─────────────────────────────
# Every number in this part is a ratio against the bars beside the card. If the
# bars are not there -- a window that never showed the video, a phase the finder
# could not lock -- the denominator is noise and every ratio is meaningless while
# still being a number. `ref_skew` is the two halves of that reference disagreeing.
OUT_BARS=$(python3 "$MEASURE" "$SP/clear.png" $(rect_of clear) | val "['outside']['bars']")
SKEW=$(python3 "$MEASURE" "$SP/clear.png" $(rect_of clear) | val "['ref_skew']")
python3 -c "import sys; sys.exit(0 if $OUT_BARS > 0.2 and $SKEW < 0.05 else 1)" \
  || cant "the bar pattern is not in the photograph (amplitude $OUT_BARS, halves differ $SKEW)"
echo "       window state: clear=$A_CLEAR regular=$A_REG reduced=$A_RED"
echo "       picture surviving the card: clear=$K_CLEAR regular=$K_REG opaque=$K_RED"
# ── THESE TWO HOLD IN EITHER STATE ─────────────────────────────────────────
#
# As two absolute statements and not as a ratio between them. Written as a ratio,
# the first version divided by the opaque arm -- which measures 0.000, because that
# is what an opaque rectangle is -- and printed "the material keeps 169500x more of
# the picture than the opaque fallback". A number that large is not a strong pass,
# it is a division by nothing, and it would have passed just as loudly with a
# material that kept 0.001.
python3 -c "import sys; sys.exit(0 if $K_CLEAR > 0.08 else 1)" \
  && say "OK" "the picture is still visible through the card ($K_CLEAR of the pattern)" \
  || say "FAIL" "almost nothing survives the card ($K_CLEAR) -- it is paint, not a material"
python3 -c "import sys; sys.exit(0 if $K_RED < 0.08 else 1)" \
  && say "OK" "CONTROL: and the opaque fallback keeps $K_RED, so that number means something" \
  || say "FAIL" "CONTROL: an opaque surface also measured $K_RED -- the camera is not discriminating"
# ── AND THESE TWO NEED THE WINDOW IN FRONT ──────────────────────────────────
#
# Both the clear-versus-frosted ranking and how much colour survives are properties
# of the material's ACTIVE rendering, and a rig on somebody's Mac cannot ask for
# that. Reported as not-reached rather than skipped quietly.
if [ "$A_CLEAR" = "active=key/main/app" ] && [ "$A_REG" = "active=key/main/app" ]; then
  python3 -c "import sys; sys.exit(0 if $K_CLEAR > 3 * $K_REG else 1)" \
    && say "OK" "clear keeps $(python3 -c "print(round($K_CLEAR/max($K_REG,1e-6),1))")x what frosted does, photographed" \
    || say "FAIL" "clear and frosted photograph the same: $K_CLEAR vs $K_REG"
  python3 -c "import sys; sys.exit(0 if $C_CLEAR > 0.55 else 1)" \
    && say "OK" "and $(python3 -c "print(round($C_CLEAR*100))")% of the colour behind it survives" \
    || say "FAIL" "the card washes the colour out of what is behind it ($C_CLEAR)"
else
  say "NOTE" "clear-vs-frosted and colour survival need Kin to be the front application."
  say "NOTE" "  This run was not: the material renders subdued behind another app, and"
  say "NOTE" "  clear and frosted measure the same there ($K_CLEAR vs $K_REG). Part 1"
  say "NOTE" "  catches a frosted app in any state and part 3 proves it can see one."
fi

echo
echo "── 5. AND NOTHING AT ALL IS PAINTED ON THE PICTURE ──────────────────────"
# The flat field is one even colour, so every one of these is 1.000 unless the app
# put something on it. Four `CAGradientLayer`s used to: 190 pt up from the bottom,
# 130 pt down from the top, a window-wide radial ellipse behind this very card, and
# one over the join window's camera preview. Measured on that build: 0.758, 0.662
# and 1.186 -- a third of the picture, at the edges, gone.
# The SOURCE image first. If the flat field is not flat -- a bad encode, a chroma
# subsampling artefact -- then every number after it is about ffmpeg rather than
# about the app, and it would read as a vignette that nobody wrote.
python3 "$MEASURE" --vignette "$SP/flat-src.png" > "$SP/vig-src.json"
SRC=$(val "['worst_deviation']" < "$SP/vig-src.json")
python3 -c "import sys; sys.exit(0 if $SRC < 0.01 else 1)" \
  && say "OK" "the source field is flat to $SRC, so anything below is the app's doing" \
  || cant "the flat background is not flat ($SRC) -- the encoder, not the app"

python3 "$MEASURE" --vignette "$SP/flat.png" > "$SP/vig.json"
for k in top_over_middle bottom_over_middle edge_over_centre; do
  R=$(val "['$k']" < "$SP/vig.json")
  python3 -c "import sys; sys.exit(0 if abs($R - 1.0) < 0.01 else 1)" \
    && say "OK" "$k = $R" \
    || say "FAIL" "$k = $R -- the app is darkening one part of the picture and not another"
done
WORST=$(val "['worst_deviation']" < "$SP/vig.json")
python3 -c "import sys; sys.exit(0 if $WORST < 0.01 else 1)" \
  && say "OK" "worst deviation from a flat picture: $WORST" \
  || say "FAIL" "worst deviation from a flat picture: $WORST"
# ── AND THE METER IS NOT STUCK AT 1.000 ─────────────────────────────────────
#
# Everything above passes if `--vignette` returns 1.000 for any input at all, and
# that is not a hypothetical failure: the first version of the transparency meter
# in this same script returned an identical answer for a clear pane, a blur and a
# sheet of paint. So the same photograph is measured again with a gradient laid
# over it -- the exact gradient the app used to draw, 190 pt of `Palette.dim` up
# from the bottom edge -- and the meter has to notice.
python3 - "$MEASURE" "$SP/flat.png" "$SP/vig-arm.json" <<'PY' || cant "could not build the vignette control arm"
import sys, importlib.util, json
import numpy as np
from PIL import Image
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
a = np.asarray(Image.open(sys.argv[2]).convert("RGB")).astype(float)
H, W = a.shape[:2]
band = int(H * 0.264)                      # 190 pt of a 720 pt window
ramp = np.zeros(H)
ramp[H - band:] = np.linspace(0, 0.35, band)
a = a * (1 - ramp)[:, None, None] + np.array([6, 8, 13]) * ramp[:, None, None]
json.dump(m.vignette(Image.fromarray(a.astype("uint8"))), open(sys.argv[3], "w"))
PY
ARM=$(val "['worst_deviation']" < "$SP/vig-arm.json")
python3 -c "import sys; sys.exit(0 if $ARM > 0.10 else 1)" \
  && say "OK" "CONTROL: the old bottom scrim, re-applied, measures $ARM -- the meter can see one" \
  || say "FAIL" "CONTROL: a 35% gradient over the frame measured only $ARM -- the meter is stuck"

echo
if [ "$fail" = 0 ]; then
  echo "GLASS CHECK PASSED -- every surface is clear Liquid Glass, nothing is painted"
  echo "                     behind it, and nothing is painted on the picture"
else
  echo "GLASS CHECK FAILED -- see above; logs and photographs in $SP"
  echo "                     (re-run with KEEP=1 to keep them)"
fi
exit $fail
