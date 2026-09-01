package com.tokkah.kin.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * The control glyphs, drawn rather than typed.
 *
 * Emoji were standing in here and they were wrong in a way that is not taste:
 * an emoji is a colour picture from the system font, so the mic was blue-grey
 * and the camera brown on a surface whose whole palette is one foreground
 * colour and one accent — and OFF could not turn the glyph red, which is this
 * app's own rule for state (`Glass.swift`: OFF does not fill a circle red, it
 * turns the GLYPH red). Vectors take the tint they are given.
 *
 * Each is drawn in a 24x24 box and scaled, so weights match across sizes.
 */
private val W = 1.9.dp

@Composable
fun Glyph(kind: GlyphKind, tint: Color, size: Dp = 24.dp, slashed: Boolean = false) {
    Canvas(Modifier.size(size)) {
        val u = this.size.minDimension / 24f
        val stroke = Stroke(width = W.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round)
        when (kind) {
            GlyphKind.MIC -> mic(u, tint, stroke)
            GlyphKind.CAMERA -> camera(u, tint, stroke)
            GlyphKind.EYE -> eye(u, tint, stroke)
            GlyphKind.FLIP -> flip(u, tint, stroke)
            GlyphKind.CROSS -> cross(u, tint, stroke)
            GlyphKind.MORE -> more(u, tint)
            GlyphKind.LINK -> link(u, tint, stroke)
        }
        if (slashed) {
            drawLine(tint, Offset(5 * u, 5 * u), Offset(19 * u, 19 * u),
                strokeWidth = W.toPx(), cap = StrokeCap.Round)
        }
    }
}

enum class GlyphKind { MIC, CAMERA, EYE, FLIP, CROSS, MORE, LINK }

private fun DrawScope.mic(u: Float, c: Color, s: Stroke) {
    // The capsule, its cradle and the stand.
    drawRoundRect(
        c, topLeft = Offset(9 * u, 3 * u), size = Size(6 * u, 11 * u),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(3 * u, 3 * u), style = s,
    )
    val arc = Path().apply {
        arcTo(Rect(6 * u, 9 * u, 18 * u, 21 * u), 0f, 180f, false)
    }
    drawPath(arc, c, style = s)
    drawLine(c, Offset(12 * u, 18 * u), Offset(12 * u, 21 * u), W.toPx(), StrokeCap.Round)
}

private fun DrawScope.camera(u: Float, c: Color, s: Stroke) {
    drawRoundRect(
        c, topLeft = Offset(3 * u, 7 * u), size = Size(13 * u, 11 * u),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(2.5f * u, 2.5f * u), style = s,
    )
    // The lens barrel, which is what says "camera" and not "screen".
    val barrel = Path().apply {
        moveTo(16 * u, 11 * u); lineTo(21 * u, 8 * u)
        lineTo(21 * u, 17 * u); lineTo(16 * u, 14 * u); close()
    }
    drawPath(barrel, c, style = s)
}

private fun DrawScope.eye(u: Float, c: Color, s: Stroke) {
    val lid = Path().apply {
        moveTo(2.5f * u, 12 * u)
        cubicTo(6 * u, 6 * u, 18 * u, 6 * u, 21.5f * u, 12 * u)
        cubicTo(18 * u, 18 * u, 6 * u, 18 * u, 2.5f * u, 12 * u)
        close()
    }
    drawPath(lid, c, style = s)
    drawCircle(c, radius = 2.6f * u, center = Offset(12 * u, 12 * u), style = s)
}

private fun DrawScope.flip(u: Float, c: Color, s: Stroke) {
    // Two arrows chasing each other: the camera swaps ends.
    val top = Path().apply {
        moveTo(4 * u, 9 * u); cubicTo(7 * u, 4 * u, 17 * u, 4 * u, 20 * u, 9 * u)
    }
    val bottom = Path().apply {
        moveTo(20 * u, 15 * u); cubicTo(17 * u, 20 * u, 7 * u, 20 * u, 4 * u, 15 * u)
    }
    drawPath(top, c, style = s)
    drawPath(bottom, c, style = s)
    drawPath(Path().apply {
        moveTo(16.5f * u, 9.5f * u); lineTo(20.5f * u, 9 * u); lineTo(19.5f * u, 5 * u)
    }, c, style = s)
    drawPath(Path().apply {
        moveTo(7.5f * u, 14.5f * u); lineTo(3.5f * u, 15 * u); lineTo(4.5f * u, 19 * u)
    }, c, style = s)
}

private fun DrawScope.cross(u: Float, c: Color, s: Stroke) {
    drawLine(c, Offset(6.5f * u, 6.5f * u), Offset(17.5f * u, 17.5f * u), W.toPx() * 1.15f, StrokeCap.Round)
    drawLine(c, Offset(17.5f * u, 6.5f * u), Offset(6.5f * u, 17.5f * u), W.toPx() * 1.15f, StrokeCap.Round)
}

private fun DrawScope.more(u: Float, c: Color) {
    for (x in intArrayOf(6, 12, 18)) drawCircle(c, 1.5f * u, Offset(x * u, 12 * u))
}

private fun DrawScope.link(u: Float, c: Color, s: Stroke) {
    drawPath(Path().apply {
        moveTo(10 * u, 14 * u); lineTo(14 * u, 10 * u)
    }, c, style = s)
    drawRoundRect(
        c, topLeft = Offset(3 * u, 11 * u), size = Size(9 * u, 6 * u),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(3 * u, 3 * u), style = s,
    )
    drawRoundRect(
        c, topLeft = Offset(12 * u, 7 * u), size = Size(9 * u, 6 * u),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(3 * u, 3 * u), style = s,
    )
}
