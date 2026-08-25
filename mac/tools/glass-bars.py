#!/usr/bin/env python3
# ── A BACKGROUND WITH A KNOWN ANSWER ────────────────────────────────────────────
#
# A material can only be judged over content (GLASS.md §1), and "over content" is
# usually a talking head -- which is right for judging how a screen LOOKS and
# useless for putting a number on it, because nobody knows what a face is supposed
# to measure.
#
# This is the ruler instead: vertical bars of two bright, saturated colours at a
# known period. Three properties survive or do not survive a material, and each is
# a number:
#
#   structure   the bars are a square wave. A blur is a low-pass filter, so its
#               amplitude at the bar frequency is the thing `.regular` destroys and
#               `.clear` keeps. This is the headline number.
#   colour      both colours are near the sRGB gamut edge, so any wash toward grey
#               shows up as lost saturation.
#   brightness  both are bright, which is the case the HIG's dimming rule is about
#               and the case the person reported: a card over a lit face.
#
# 40 pt bars because that is the scale of the features a face has -- an eye, a
# nostril, the edge of a jaw -- so a filter that erases these erases those.
import sys
from PIL import Image

W, H, BAR = 1280, 720, 40
YELLOW, BLUE = (255, 214, 10), (10, 132, 255)

img = Image.new("RGB", (W, H))
px = img.load()
for x in range(W):
    c = YELLOW if (x // BAR) % 2 == 0 else BLUE
    for y in range(H):
        px[x, y] = c
img.save(sys.argv[1] if len(sys.argv) > 1 else "bars.png")
print(f"bars {W}x{H} period {BAR * 2} px")
