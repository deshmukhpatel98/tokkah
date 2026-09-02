package com.tokkah.kin.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * The control glyphs — the Mac's own paths (`enum Glyph` in Controls.swift),
 * transcribed number for number.
 *
 * The first version here drew approximations: a mic that was roughly a mic, a
 * cross for leave where the Mac draws a handset. Two apps that are "the same"
 * and whose buttons are different drawings are two products, and the drawing
 * is the cheapest thing in the app to get exactly right. So every path below is
 * the Swift path in a 24-unit box, scaled. The Mac builds in a y-down design
 * space and flips for AppKit; Compose is y-down already, so the numbers carry
 * over unchanged, and an AppKit `clockwise: true` arc is a negative sweep here.
 *
 * Stroke is `1.8 × (size / 24)`, the Mac's rule, so weights match at every size.
 */
@Composable
fun Glyph(kind: GlyphKind, tint: Color, size: Dp = 24.dp, slashed: Boolean = false) {
    Canvas(Modifier.size(size)) {
        val u = this.size.minDimension / 24f
        val stroke = Stroke(width = 1.8f * u, cap = StrokeCap.Round, join = StrokeJoin.Round)
        when (kind) {
            GlyphKind.MIC -> mic(u, tint, stroke)
            GlyphKind.SPEAKER -> speaker(u, tint, stroke)
            GlyphKind.CAMERA -> camera(u, tint, stroke)
            GlyphKind.PEEK -> peek(u, tint, stroke)
            GlyphKind.FLIP -> flip(u, tint, stroke)
            GlyphKind.XLATE -> xlate(u, tint, stroke)
            GlyphKind.LEAVE -> drawPath(handset(u), tint)
            GlyphKind.PHONE -> rotate(135f) { drawPath(handset(u), tint) }
            GlyphKind.MORE -> more(u, tint)
            GlyphKind.LOCK -> lock(u, tint, stroke)
            GlyphKind.PERSON -> person(u, tint, stroke)
            GlyphKind.PENCIL -> pencil(u, tint, stroke)
            GlyphKind.BELL -> bell(u, tint, stroke)
            GlyphKind.LINK -> link(u, tint, stroke)
        }
        // `Glyph.slash`: (4,4) → (20,20).
        if (slashed) {
            drawLine(tint, Offset(4 * u, 4 * u), Offset(20 * u, 20 * u),
                strokeWidth = 1.8f * u, cap = StrokeCap.Round)
        }
    }
}

enum class GlyphKind {
    MIC, SPEAKER, CAMERA, PEEK, FLIP, XLATE, LEAVE, PHONE, MORE, LOCK, PERSON, PENCIL, BELL, LINK,
}

private fun Path.m(u: Float, x: Float, y: Float) = moveTo(x * u, y * u)
private fun Path.l(u: Float, x: Float, y: Float) = lineTo(x * u, y * u)
private fun Path.c(u: Float, x1: Float, y1: Float, x2: Float, y2: Float, x: Float, y: Float) =
    cubicTo(x1 * u, y1 * u, x2 * u, y2 * u, x * u, y * u)

/** `appendArc(withCenter:radius:startAngle:endAngle:clockwise:)`, in Compose terms. */
private fun Path.arc(u: Float, cx: Float, cy: Float, r: Float, start: Float, end: Float, clockwise: Boolean) {
    var sweep = end - start
    if (clockwise && sweep > 0) sweep -= 360f
    if (!clockwise && sweep < 0) sweep += 360f
    arcTo(Rect(Offset(cx * u, cy * u), r * u), start, sweep, forceMoveTo = false)
}

private fun DrawScope.rr(c: Color, s: Stroke, u: Float, x: Float, y: Float, w: Float, h: Float, r: Float) {
    drawRoundRect(c, topLeft = Offset(x * u, y * u), size = Size(w * u, h * u),
        cornerRadius = CornerRadius(r * u, r * u), style = s)
}

private fun DrawScope.mic(u: Float, c: Color, s: Stroke) {
    rr(c, s, u, 9f, 3f, 6f, 10.5f, 3f)
    drawPath(Path().apply {
        m(u, 5f, 11f)
        arc(u, 12f, 11f, 7f, 180f, 0f, clockwise = true)
        m(u, 12f, 18f); l(u, 12f, 21f)
    }, c, style = s)
}

private fun DrawScope.speaker(u: Float, c: Color, s: Stroke) {
    drawPath(Path().apply {
        m(u, 4f, 9.5f); l(u, 7.5f, 9.5f); l(u, 12f, 5.5f); l(u, 12f, 18.5f)
        l(u, 7.5f, 14.5f); l(u, 4f, 14.5f); close()
        m(u, 16f, 9.5f); c(u, 18.2f, 10.6f, 18.2f, 13.4f, 16f, 14.5f)
        m(u, 18.6f, 7f); c(u, 22.2f, 9.2f, 22.2f, 14.8f, 18.6f, 17f)
    }, c, style = s)
}

private fun DrawScope.camera(u: Float, c: Color, s: Stroke) {
    rr(c, s, u, 2.5f, 6f, 13f, 12f, 3f)
    drawPath(Path().apply {
        m(u, 15.5f, 10.5f); l(u, 21.5f, 7f); l(u, 21.5f, 17f); l(u, 15.5f, 13.5f); close()
    }, c, style = s)
}

private fun DrawScope.peek(u: Float, c: Color, s: Stroke) {
    drawCircle(c, radius = 3.2f * u, center = Offset(12 * u, 9 * u), style = s)
    drawPath(Path().apply {
        m(u, 5.5f, 19f)
        c(u, 6.7f, 16f, 9.1f, 14.5f, 12f, 14.5f)
        c(u, 14.9f, 14.5f, 17.3f, 16f, 18.5f, 19f)
    }, c, style = s)
    rr(c, s, u, 2.8f, 3.2f, 18.4f, 17.6f, 4.5f)
}

private fun DrawScope.flip(u: Float, c: Color, s: Stroke) {
    rr(c, s, u, 2.6f, 10.2f, 11.4f, 10.2f, 2.6f)
    drawPath(Path().apply {
        m(u, 13.9f, 13.7f); l(u, 19.4f, 10.7f); l(u, 19.4f, 19.3f); l(u, 13.9f, 16.3f); close()
        m(u, 5.2f, 7.6f)
        arc(u, 12.223f, 10.994f, 7.8f, -154.2f, -32.5f, clockwise = false)
        m(u, 18.9f, 2.9f); l(u, 18.9f, 6.9f); l(u, 14.9f, 6.9f)
        m(u, 5.1f, 3.4f); l(u, 5.1f, 7.4f); l(u, 9.1f, 7.4f)
    }, c, style = s)
}

private fun DrawScope.xlate(u: Float, c: Color, s: Stroke) {
    drawCircle(c, radius = 9 * u, center = Offset(12 * u, 12 * u), style = s)
    drawPath(Path().apply {
        m(u, 3f, 12f); l(u, 21f, 12f)
        m(u, 12f, 3f)
        c(u, 18f, 8f, 18f, 16f, 12f, 21f)
        c(u, 6f, 16f, 6f, 8f, 12f, 3f)
    }, c, style = s)
}

/** `Glyph.leave`, filled. `Glyph.phone` is this turned through 135°. */
private fun handset(u: Float): Path = Path().apply {
    m(u, 2.6f, 14.9f)
    c(u, 7.8f, 9.8f, 16.2f, 9.8f, 21.4f, 14.9f)
    l(u, 19.1f, 17.2f)
    c(u, 18.5f, 17.8f, 17.6f, 17.8f, 17.0f, 17.2f)
    l(u, 15.5f, 15.8f)
    c(u, 15.15f, 15.45f, 14.95f, 14.9f, 15.05f, 14.35f)
    l(u, 15.3f, 13.05f)
    c(u, 13.2f, 12.5f, 10.9f, 12.5f, 8.8f, 13.05f)
    l(u, 9.05f, 14.35f)
    c(u, 9.15f, 14.9f, 8.95f, 15.45f, 8.6f, 15.8f)
    l(u, 7.1f, 17.2f)
    c(u, 6.5f, 17.8f, 5.6f, 17.8f, 5.0f, 17.2f)
    close()
}

private fun DrawScope.more(u: Float, c: Color) {
    for (cx in floatArrayOf(5.5f, 12f, 18.5f)) drawCircle(c, 1.7f * u, Offset(cx * u, 12 * u))
}

private fun DrawScope.lock(u: Float, c: Color, s: Stroke) {
    rr(c, s, u, 4f, 10.5f, 16f, 10.5f, 2.5f)
    drawPath(Path().apply {
        m(u, 8f, 10.5f); l(u, 8f, 7f)
        arc(u, 12f, 7f, 4f, 180f, 360f, clockwise = false)
        l(u, 16f, 10.5f)
    }, c, style = s)
}

private fun DrawScope.person(u: Float, c: Color, s: Stroke) {
    drawCircle(c, radius = 3.6f * u, center = Offset(12 * u, 8.5f * u), style = s)
    drawPath(Path().apply {
        m(u, 5f, 19.5f)
        c(u, 8f, 13f, 16f, 13f, 19f, 19.5f)
    }, c, style = s)
}

private fun DrawScope.pencil(u: Float, c: Color, s: Stroke) {
    drawPath(Path().apply {
        m(u, 4f, 20f); l(u, 5f, 16f); l(u, 16.5f, 4.5f); l(u, 19.5f, 7.5f); l(u, 8f, 19f); close()
        m(u, 14.5f, 6.5f); l(u, 17.5f, 9.5f)
    }, c, style = s)
}

private fun DrawScope.bell(u: Float, c: Color, s: Stroke) {
    drawPath(Path().apply {
        m(u, 6.5f, 17f); l(u, 6.5f, 10f)
        arc(u, 12f, 10f, 5.5f, 180f, 0f, clockwise = false)
        l(u, 17.5f, 17f)
        m(u, 4.5f, 17f); l(u, 19.5f, 17f)
        m(u, 10f, 20f)
        arc(u, 12f, 20f, 2f, 180f, 0f, clockwise = true)
    }, c, style = s)
}

/** Not on the Mac (it has no link glyph); kept for the invite row's chip. */
private fun DrawScope.link(u: Float, c: Color, s: Stroke) {
    drawPath(Path().apply { m(u, 10f, 14f); l(u, 14f, 10f) }, c, style = s)
    rr(c, s, u, 3f, 11f, 9f, 6f, 3f)
    rr(c, s, u, 12f, 7f, 9f, 6f, 3f)
}
