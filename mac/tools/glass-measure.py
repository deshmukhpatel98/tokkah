#!/usr/bin/env python3
# ── HOW MUCH OF THE PICTURE SURVIVES THE SURFACE ────────────────────────────────
#
# Reads a window capture and a surface rectangle (both from the app's own `glass`
# audit line) and returns three numbers for the pixels inside that rectangle, each
# as a FRACTION OF THE SAME MEASUREMENT ON THE RAW PICTURE in the same photograph.
# A ratio, deliberately: the app's encoder has already been over these bars once,
# the window scales them, and neither is a property of the material. Dividing by
# the picture beside the surface takes both out.
#
#   bars    amplitude of the bar square wave at its own period. A blur is a
#           low-pass filter and this is the term it removes. 1.0 = the surface is
#           not there; 0.0 = you cannot tell what is behind it.
#   colour  mean saturation, so a wash toward grey shows up as a number.
#   light   mean luminance. This one is SUPPOSED to fall -- it is what a dimming
#           layer is for, and a surface where it does not fall has unreadable text.
#
# ── THE FIRST VERSION OF THIS FILE WAS BLIND ───────────────────────────────────
#
# It built its reference by concatenating the strip left of the surface with the
# strip right of it. Two strips joined at their ends are not one strip: the bars
# have a phase discontinuity in the middle of the result, so yellow columns and
# blue columns averaged into each other and the reference amplitude came out 0.000
# -- on the calibration case that is a bare photograph of the bars with nothing
# over it at all. Every `kept` ratio was then 0/0 -> 0.0, so the ruler ranked a
# clear pane, a heavy blur and an opaque grey rectangle IDENTICALLY, and the
# identical answer it gave was "nothing survives" -- which reads exactly like a
# real, terrible result rather than like a broken instrument.
#
# So everything below works in ABSOLUTE column coordinates: the period and phase
# are found once for the whole photograph and every region indexes into the same
# mask. And `--calibrate` exists, because the only reason that bug was ever found
# is that the ruler was asked four questions it already knew the answers to.
import sys, json
import numpy as np
from PIL import Image

LUMA = np.array([0.2126, 0.7152, 0.0722])
# `Palette.fg` -- the colour every word on every surface in this app is drawn in.
FG = (0xe8 / 255.0, 0xea / 255.0, 0xed / 255.0)


def rel_luminance(rgb):
    """WCAG relative luminance: sRGB is gamma-encoded and a plain weighted mean of
    the stored bytes is not a luminance. Everything else in this file is happy with
    the encoded value because it only ever compares like with like; a contrast
    RATIO is the one number that has to be in linear light."""
    a = np.asarray(rgb, dtype=np.float64)
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    return lin @ LUMA


def contrast_against_fg(bg_luma):
    l1, l2 = max(rel_luminance(FG), bg_luma), min(rel_luminance(FG), bg_luma)
    return (l1 + 0.05) / (l2 + 0.05)


def find_period_phase(luma, cols):
    """The bar period and phase in absolute column coordinates, measured from the
    photograph rather than assumed. The window scales the video by whatever fits,
    so a hardcoded period samples the wrong half of every bar and reports a pane of
    clear glass as an opaque one.

    `cols` is a boolean mask over absolute columns, and it does NOT have to be
    contiguous -- the strips either side of the surface are used together, on
    purpose. Absolute x in the cosine means a gap in the middle costs nothing and
    the long baseline is what pins the period down. Measured with only the left
    strip, the answer came out 80.25 against a true 80.00: a 0.3% error, which is
    invisible until it has accumulated four pixels of drift across 1280 columns,
    and then it reads as a real 34% loss of picture. Both halves of the reference
    are compared afterwards for exactly this reason.

    Two passes, because a step fine enough to matter is too fine to sweep."""
    prof = luma[:, cols].mean(axis=0)
    prof = prof - prof.mean()
    x = np.arange(luma.shape[1])[cols]

    def best_over(periods):
        b = (0.0, 80.0, 0.0)
        for period in periods:
            ang = 2 * np.pi * x / period
            c = float((prof * np.cos(ang)).sum())
            s = float((prof * np.sin(ang)).sum())
            mag = (c * c + s * s) ** 0.5
            if mag > b[0]:
                b = (mag, float(period), float(np.arctan2(s, c)))
        return b

    coarse = best_over(np.arange(20.0, 300.0, 0.25))
    fine = best_over(np.arange(max(4.0, coarse[1] - 0.4), coarse[1] + 0.4, 0.004))
    return fine[1], fine[2]


def bar_mask(width, period, phase):
    """Which absolute columns are the bright lobe of the square wave."""
    x = np.arange(width)
    return np.cos(2 * np.pi * x / period - phase) > 0


def measure(rgb, rows, cols, mask):
    """rows: (r0, r1). cols: a boolean array over absolute columns."""
    sub = rgb[rows[0]:rows[1]]
    luma = sub @ LUMA
    hi, lo = cols & mask, cols & ~mask
    if hi.sum() < 4 or lo.sum() < 4:
        return None
    mx, mn = sub.max(axis=2), sub.min(axis=2)
    sat = np.where(mx > 1e-6, (mx - mn) / np.maximum(mx, 1e-6), 0.0)
    mean = float(luma[:, cols].mean())
    amp = float(abs(luma[:, hi].mean() - luma[:, lo].mean()))
    # ── AMPLITUDE OVER MEAN, NOT AMPLITUDE ─────────────────────────────────────
    #
    # Divided by the region's own brightness, so this is CONTRAST and answers only
    # "can you still make out what is behind this". The raw amplitude cannot: a
    # dimming layer multiplies every luminance by 0.65, so it takes the amplitude
    # down by 0.65 too, and the calibration case that is a perfectly clear 35% dim
    # scored 0.669 -- indistinguishable from a real blur. Dividing by the mean
    # cancels the multiplication and leaves the low-pass filtering, which is the
    # only thing frosting does that dimming does not. How dark it got is `light`,
    # and that is a separate question with a separate answer.
    return {
        "bars": amp / max(1e-6, mean),
        "colour": float(sat[:, cols].mean()),
        "light": mean,
    }


# ── THE NUMBER THAT STOPS THIS BECOMING A DIFFERENT BUG ────────────────────────
#
# Transparency has an obvious failure mode in the other direction, and it is worse
# than the one being fixed: a surface you can see straight through is a surface
# whose white text disappears into a bright face. So every arm reports what the
# words on it are up against, and any sweep for more transparency is bounded by it.
#
# ── AND IT IS MEASURED WHERE THE LETTERS ARE ───────────────────────────────────
#
# The first version took the 98th percentile of the whole surface, which is a
# different question: "is there a bright patch anywhere on this card". There
# usually is -- a highlight on somebody's forehead in a corner where no glyph ever
# goes -- and judging a name by it condemns a card that reads perfectly.
#
# So the glyphs are found (they are the only near-`Palette.fg` pixels on the
# surface), grown by a few pixels, and the ring that appears around them is what
# each letter is actually sitting on. p98 of THAT: contrast is a property of the
# worst place a letter lands, not of the average of the card.
#
# ── READ IT AS A COMPARISON, NOT AS A WCAG VERDICT ─────────────────────────────
#
# The ring necessarily contains the ANTI-ALIASED edge of every glyph -- pixels part
# way between `Palette.fg` and the background, and therefore bright -- so the 98th
# percentile of it is biased toward the text's own colour and the absolute number
# comes out lower than a person's eye would agree with. Measured on the real
# talking head, the calling card reads 1.30 on the old frosted build and 1.31 on
# the clear one, while both are comfortably readable in the photographs.
#
# That is exactly what it is for: the two builds are measured identically, so the
# DIFFERENCE is sound and it is the difference that decides whether transparency
# was bought with legibility. Do not quote the absolute figure as a contrast ratio.
def worst_text_contrast(rgb, rows, cols):
    sub = rgb[rows[0]:rows[1]][:, cols]
    if sub.size < 4096:
        return float("nan")
    # ── THE GLYPHS ARE FOUND BY COLOUR, NOT BY BRIGHTNESS ──────────────────────
    #
    # `luma > 0.78` was the first attempt and it is blind in exactly the case this
    # number exists for. On the calibration case that is white text on a light grey
    # -- the low-contrast one, the one that has to fail loudly -- the BACKGROUND is
    # brighter than 0.78, so the whole surface was classified as ink, the ring
    # around the ink was empty, and the meter returned `nan`: no reading at all on
    # the only input where a bad reading was the right answer.
    #
    # Everything in this app is drawn in one colour, so ink is "within a few
    # levels of `Palette.fg` on all three channels". A grey of the same luminance
    # is not within a few levels of it, and neither is anything the camera saw.
    ink = (np.abs(sub - np.array(FG)) < 0.055).all(axis=2)
    frac = ink.mean()
    # No words here (a bar circle, an empty pill), or the detector has swallowed the
    # background and the reading would be fiction. Both are "no reading", and `nan`
    # says so out loud rather than returning a number that looks like an answer.
    if ink.sum() < 150 or frac > 0.25:
        return float("nan")
    from PIL import ImageFilter
    grown = np.asarray(
        Image.fromarray((ink * 255).astype("uint8")).filter(ImageFilter.MaxFilter(9))) > 127
    ring = grown & ~ink
    if ring.sum() < 150:
        return float("nan")
    lin = rel_luminance(sub[ring])
    return float(contrast_against_fg(float(np.percentile(lin, 98))))


def analyse(im, x, y, w, h, win_w, pad_pt=14.0):
    a = np.asarray(im.convert("RGB")).astype(np.float64) / 255.0
    H, W = a.shape[:2]
    # `screencapture` returns backing-store pixels; the audit reports points.
    scale = W / float(win_w)
    sx, sy, sw, sh = (int(round(v * scale)) for v in (x, y, w, h))
    # Liquid Glass draws a specular rim and the corners are round, so the outermost
    # few points are the material's own edge treatment rather than a sample of what
    # is behind it. Inset past them.
    pad = max(2, int(round(pad_pt * scale)))
    rows = (max(0, sy + pad), min(H, sy + sh - pad))
    inside = np.zeros(W, bool)
    inside[max(0, sx + pad):min(W, sx + sw - pad)] = True

    left = np.zeros(W, bool)
    left[:max(0, sx - pad)] = True
    right = np.zeros(W, bool)
    right[min(W, sx + sw + pad):] = True
    if rows[1] - rows[0] < 8 or inside.sum() < 8:
        raise SystemExit("surface rectangle is too small to measure")

    # Period and phase from both reference strips at once -- see the note there.
    period, phase = find_period_phase(a[rows[0]:rows[1]] @ LUMA, left | right)
    mask = bar_mask(W, period, phase)

    got = measure(a, rows, inside, mask)
    ref = measure(a, rows, left | right, mask)
    got["text"] = worst_text_contrast(a, rows, inside)
    ref["text"] = worst_text_contrast(a, rows, left | right)
    # The two halves of the reference are the same picture through nothing, so they
    # must agree. If they do not, the phase is wrong and every number here is
    # fiction -- a check the first version of this file did not have.
    l = measure(a, rows, left, mask)
    r = measure(a, rows, right, mask)
    skew = abs(l["bars"] - r["bars"]) / max(1e-6, ref["bars"]) if l and r else 9.9
    return {
        "period": round(period, 2),
        "ref_skew": round(skew, 3),
        "outside": {k: round(v, 4) for k, v in ref.items()},
        "inside": {k: round(v, 4) for k, v in got.items()},
        # `text` is an absolute contrast ratio and is deliberately NOT in here: a
        # ratio of two contrast ratios answers no question anybody has.
        "kept": {k: round(got[k] / ref[k], 4) if ref[k] > 1e-6 else 0.0
                 for k in got if k != "text"},
    }


# ── THE RULER IS CHECKED BEFORE IT IS BELIEVED ─────────────────────────────────
#
# Four treatments pasted into the middle of the bars, with answers known in
# advance, and two of them MUST rank differently or the instrument proves nothing:
#
#   none    a bare photograph      bars ~1.00   colour ~1.00   light ~1.00
#   dim35   the HIG's dim, clear   bars ~1.00   colour ~1.00   light ~0.66
#   blur    a frost                bars  LOW    colour  LOW    light ~1.00
#   opaque  paint                  bars ~0.00   colour ~0.00
def calibrate():
    from PIL import ImageFilter
    W, H, BAR = 1280, 720, 40
    base = Image.new("RGB", (W, H))
    px = base.load()
    for cx in range(W):
        c = (255, 214, 10) if (cx // BAR) % 2 == 0 else (10, 132, 255)
        for cy in range(H):
            px[cx, cy] = c
    X, Y, BW, BH = 440, 250, 400, 220
    cases = {}
    cases["none"] = base.copy()
    b = base.copy()
    b.paste(b.crop((X, Y, X + BW, Y + BH)).filter(ImageFilter.GaussianBlur(18)), (X, Y))
    cases["blur"] = b
    o = base.copy()
    o.paste(Image.new("RGB", (BW, BH), (90, 94, 102)), (X, Y))
    cases["opaque"] = o
    d = np.asarray(base).astype(float)
    d[Y:Y + BH, X:X + BW] = d[Y:Y + BH, X:X + BW] * 0.65 + np.array([6, 8, 13]) * 0.35
    cases["dim35"] = Image.fromarray(d.astype("uint8"))

    ok = True
    want = {"none": (0.94, 1.06, 0.95, 1.05, 0.95, 1.05),
            "dim35": (0.94, 1.06, 0.92, 1.02, 0.60, 0.72),
            "blur": (0.00, 0.45, 0.00, 0.70, 0.90, 1.10),
            "opaque": (0.00, 0.02, 0.00, 0.20, 0.00, 1.00)}
    for name, im in cases.items():
        r = analyse(im, X, Y, BW, BH, W)
        k = r["kept"]
        lo_b, hi_b, lo_c, hi_c, lo_l, hi_l = want[name]
        good = (lo_b <= k["bars"] <= hi_b and lo_c <= k["colour"] <= hi_c
                and lo_l <= k["light"] <= hi_l and r["ref_skew"] < 0.05)
        ok &= good
        print(f"  {'OK  ' if good else 'FAIL'} {name:<7} bars={k['bars']:.3f}"
              f" colour={k['colour']:.3f} light={k['light']:.3f}"
              f" (period {r['period']}, ref halves differ {r['ref_skew']:.3f})")

    # ── AND THE CONTRAST METER, ON TWO ANSWERS ARITHMETIC ALREADY KNOWS ───────
    #
    # Text is drawn in `Palette.fg` on a flat known grey, so the right answer is a
    # WCAG contrast ratio that can be worked out by hand -- and the two cases must
    # come out far apart or the meter is measuring something other than contrast.
    from PIL import ImageDraw
    for shade, lo, hi in ((40, 10.0, 14.0), (200, 1.2, 1.9)):
        im = Image.new("RGB", (W, H), (shade, shade, shade))
        d = ImageDraw.Draw(im)
        # Thin strokes at a few percent coverage, which is what a line of text is.
        # The first version drew fat bars covering a sixth of the surface, and a
        # detector tuned against that would have been tuned against nothing real.
        for i in range(8):
            d.rectangle([X + 60, Y + 60 + i * 14, X + BW - 60, Y + 62 + i * 14],
                        fill=(0xe8, 0xea, 0xed))
        a = np.asarray(im).astype(np.float64) / 255.0
        got = worst_text_contrast(a, (Y, Y + BH), np.isin(np.arange(W),
                                                          np.arange(X, X + BW)))
        want_ = contrast_against_fg(rel_luminance((shade / 255.0,) * 3))
        good = lo <= got <= hi and abs(got - want_) < 0.15
        ok &= good
        print(f"  {'OK  ' if good else 'FAIL'} text on grey {shade:<3}"
              f" measured {got:.2f}, arithmetic says {want_:.2f}")
    if not ok:
        print("  the ruler is wrong -- nothing measured with it means anything")
    return 0 if ok else 1


# ── A VIGNETTE IS A NUMBER ─────────────────────────────────────────────────────
#
# "There should be no vignette of any kind" is checkable to three decimal places,
# and it needs a different background from the one above: a FLAT bright field, so
# that any variation across the frame is the app's and not the picture's.
#
# Three ratios, each edge over the middle, all of which read 1.000 when the app is
# painting nothing on the picture. The bands are chosen to miss every control --
# the left fifteenth of the width has no button, no pill and no card in it at any
# window size, and the rows a fifth of the way down are above the card and below
# anything at the top.
def vignette(im):
    a = np.asarray(im.convert("RGB")).astype(np.float64) / 255.0
    luma = a @ LUMA
    H, W = luma.shape

    def band(r0, r1, c0, c1):
        return float(luma[int(H * r0):int(H * r1), int(W * c0):int(W * c1)].mean())

    mid_v = band(0.45, 0.55, 0.02, 0.15)
    # ── THE TOP BAND STARTS AFTER THE TRAFFIC LIGHTS ───────────────────────────
    #
    # It was x 0.02..0.15, which is exactly where macOS puts the close, minimise
    # and zoom buttons -- this window is `.fullSizeContentView`, so they float on
    # the picture. Measured that way, a photograph with NO vignette in it reported
    # the top of the frame 13% BRIGHTER than the middle, and the rig called it a
    # vignette. The three brightest objects in the frame were a window control.
    top = band(0.02, 0.10, 0.16, 0.30)
    bot = band(0.90, 0.98, 0.02, 0.15)
    mid_h = band(0.20, 0.30, 0.40, 0.60)
    edge_h = (band(0.20, 0.30, 0.02, 0.10) + band(0.20, 0.30, 0.90, 0.98)) / 2
    r = {
        "top_over_middle": round(top / max(1e-6, mid_v), 4),
        "bottom_over_middle": round(bot / max(1e-6, mid_v), 4),
        "edge_over_centre": round(edge_h / max(1e-6, mid_h), 4),
    }
    r["worst_deviation"] = round(max(abs(v - 1.0) for v in r.values()), 4)
    return r


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--calibrate":
        sys.exit(calibrate())
    if len(sys.argv) == 3 and sys.argv[1] == "--vignette":
        print(json.dumps(vignette(Image.open(sys.argv[2]))))
        sys.exit(0)
    png, x, y, w, h, win_w = sys.argv[1:7]
    print(json.dumps(analyse(Image.open(png), *(int(v) for v in (x, y, w, h, win_w)))))
