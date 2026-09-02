package com.tokkah.kin.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * The rows on a card or a sheet, from `SheetRow` / `ContactRow` in
 * Controls.swift (911-1360) and the layout walk in Launcher.swift.
 *
 * A row is `sheetRow` tall. On the left, one of: a glyph at 12 from the edge
 * with the label at `rowGlyphInset`; an avatar at `s3` with the label at
 * `rowAvatarInset`; or the label alone at `labelInset`. On the right, exactly
 * one of: a switch, a chevron, or a value — and a value is either a WORD
 * ("yesterday", "copy", "on") in the button face or a CODE in monospace; an
 * ACTION word ("copy") sits in a chip so it is visibly something you press,
 * because "copy" drawn exactly like "yesterday" was the first thing photographs
 * of the Mac's own card taught this port.
 *
 * A press is a vibrant fill INSIDE the card's glass, never another pane.
 * `inert` rows are facts, not controls: no press fill, no hand.
 */
@Composable
fun KinRow(
    label: String,
    modifier: Modifier = Modifier,
    detail: String? = null,
    detailTone: Color = Palette.muted,
    /** The value is a WORD ("copy", "on"), not a code — drawn in the button face. */
    valueIsWord: Boolean = true,
    /** The value is something you press: drawn as a chip in the foreground ink. */
    valueIsAction: Boolean = false,
    switchState: Boolean? = null,
    chevron: Boolean = false,
    glyph: GlyphKind? = null,
    leading: (@Composable () -> Unit)? = null,
    labelInset: Dp = Metric.s3,
    tone: Color = Palette.rowInk,
    ruled: Boolean = false,
    inert: Boolean = false,
    onClick: (() -> Unit)? = null,
    /** `checked`: the 18 pt green tick, 12 from the edge — "this one is selected". */
    trailingTick: Boolean = false,
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val shape = RoundedCornerShape(Metric.sheetRowRadius)
    val pressable = onClick != null && !inert
    Row(
        modifier
            .fillMaxWidth()
            .height(Metric.sheetRow)
            .clip(shape)
            .background(if (pressed && pressable) Palette.fill(0.12f) else Color.Transparent, shape)
            .then(
                if (pressable) Modifier.clickable(interaction, indication = null, onClick = onClick!!)
                else Modifier,
            )
            .drawBehind {
                // `ruled`: a hairline along the TOP edge, separating this row
                // from the list above it.
                if (ruled) drawLine(Palette.fill(0.09f), Offset(0f, 0.5f), Offset(size.width, 0.5f), 1f)
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        when {
            leading != null -> {
                Box(Modifier.padding(start = Metric.s3), contentAlignment = Alignment.Center) { leading() }
                Spacer(Modifier.width(Metric.rowAvatarInset - Metric.s3 - Metric.avatar))
            }
            glyph != null -> {
                // 18 pt, 12 from the edge — the Mac's glyph column.
                Box(Modifier.padding(start = 12.dp), contentAlignment = Alignment.Center) {
                    Glyph(glyph, Palette.rowInk, size = 18.dp)
                }
                Spacer(Modifier.width(Metric.rowGlyphInset - 12.dp - 18.dp))
            }
            else -> Spacer(Modifier.width(labelInset))
        }
        Text(
            label, color = tone,
            fontSize = Type.row.first, fontWeight = Type.row.second,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        when {
            switchState != null -> {
                Spacer(Modifier.width(Metric.s2))
                RowSwitch(switchState, Modifier.padding(end = Metric.s3))
            }
            detail != null -> {
                Spacer(Modifier.width(Metric.s2))
                val pending = detail == "…"
                val ink = if (valueIsAction) Palette.fg else if (pending || valueIsWord) detailTone else Palette.fg
                val style = if (valueIsWord) Type.button else Type.code
                if (valueIsAction) {
                    // The chip: fill 0.10, a hairline, 24 tall, 10 of padding.
                    val chip = RoundedCornerShape(12.dp)
                    Box(
                        Modifier
                            .padding(end = Metric.s3 + if (chevron) Metric.s4 else 0.dp)
                            .height(24.dp)
                            .clip(chip)
                            .background(Palette.fill(if (pressed) 0.20f else 0.10f), chip)
                            .drawBehind {
                                drawRoundRect(Palette.chipLine, style = Stroke(1f),
                                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(12.dp.toPx()))
                            }
                            .padding(horizontal = 10.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(detail, color = ink, fontSize = style.first, fontWeight = style.second, maxLines = 1)
                    }
                } else {
                    Text(
                        detail, color = ink, maxLines = 1,
                        fontSize = style.first, fontWeight = style.second,
                        fontFamily = if (valueIsWord || pending) FontFamily.Default else FontFamily.Monospace,
                        letterSpacing = if (valueIsWord || pending) 0.sp else (13 * 0.09).sp,
                        modifier = Modifier.padding(end = Metric.s3 + if (chevron) Metric.s4 else 0.dp),
                    )
                }
                if (chevron) Chevron(Modifier.padding(end = Metric.s3))
            }
            chevron -> Chevron(Modifier.padding(end = Metric.s3))
            trailingTick -> Canvas(Modifier.padding(end = Metric.s3).size(18.dp)) {
                val y = size.height / 2
                drawPath(Path().apply {
                    moveTo(0f, y); lineTo(4.5f.dp.toPx(), y + 4.5f.dp.toPx()); lineTo(14.dp.toPx(), y - 6.dp.toPx())
                }, Palette.ok, style = Stroke(2.2f.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
            }
        }
    }
}

private val Int.sp get() = androidx.compose.ui.unit.TextUnit(this.toFloat(), androidx.compose.ui.unit.TextUnitType.Sp)
private val Double.sp get() = androidx.compose.ui.unit.TextUnit(this.toFloat(), androidx.compose.ui.unit.TextUnitType.Sp)

/** SheetRow's switch: 34 × 20, a white knob 2 in from the end it is on. */
@Composable
private fun RowSwitch(on: Boolean, modifier: Modifier = Modifier) {
    Canvas(modifier.size(34.dp, 20.dp)) {
        val th = size.height
        val r = androidx.compose.ui.geometry.CornerRadius(th / 2, th / 2)
        drawRoundRect(if (on) Palette.switchOn else Palette.switchOff, cornerRadius = r)
        drawRoundRect(Palette.chipLine, topLeft = Offset(0.5f, 0.5f),
            size = Size(size.width - 1f, th - 1f), cornerRadius = r, style = Stroke(1f))
        val k = th - 4.dp.toPx()
        val kx = if (on) size.width - k - 2.dp.toPx() else 2.dp.toPx()
        drawCircle(Color.White, radius = k / 2, center = Offset(kx + k / 2, th / 2))
    }
}

/** SheetRow's chevron: a 5-high caret, 4 in from the right pad. */
@Composable
private fun Chevron(modifier: Modifier = Modifier) {
    Canvas(modifier.size(10.dp, 12.dp)) {
        val cx = size.width - 4.dp.toPx(); val cy = size.height / 2
        drawPath(Path().apply {
            moveTo(cx - 4.dp.toPx(), cy - 5.dp.toPx()); lineTo(cx + 1.dp.toPx(), cy)
            lineTo(cx - 4.dp.toPx(), cy + 5.dp.toPx())
        }, Palette.rowInk.copy(alpha = 0.55f),
            style = Stroke(1.8.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

/**
 * One face, drawn in one place — a row has one and the calling card has one
 * four times the size, and two copies would drift apart the first time either
 * was nudged.
 *
 * The hue is the RING and the initial, never a filled disc: at one fixed
 * saturation white text measures 6.4:1 on the blue end and 1.71:1 on yellow.
 * When a call has actually provided a face it fills the circle and the ring
 * stays, so a face arriving does not make the row a stranger.
 *
 * The presence dot is punched OUT of the avatar rather than drawn over it,
 * because this row sits on glass and there is no one background colour to
 * imitate.
 */
@Composable
fun Avatar(
    handle: String,
    size: Dp = Metric.avatar,
    online: Boolean = false,
    ring: Dp = Metric.avatarRing,
    face: androidx.compose.ui.graphics.ImageBitmap? = null,
) {
    val ink = Palette.avatarInk(handle)
    Box(Modifier.size(size), contentAlignment = Alignment.Center) {
        // Offscreen, or BlendMode.Clear punches to BLACK instead of to
        // nothing — and this row sits on glass, where there is no one
        // background colour to imitate.
        Canvas(
            Modifier.size(size).graphicsLayer {
                compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.Offscreen
            },
        ) {
            val d = this.size.minDimension
            val r = d / 2f
            val rw = ring.toPx()
            if (face != null) {
                // Clipped to the same circle the initial lived in.
                clipPath(Path().apply {
                    addOval(androidx.compose.ui.geometry.Rect(Offset.Zero, Size(d, d)))
                }) {
                    drawImage(face, dstSize = androidx.compose.ui.unit.IntSize(d.toInt(), d.toInt()))
                }
            }
            drawCircle(ink, radius = r - rw / 2, style = Stroke(width = rw))
            if (online) {
                val dd = 9.dp.toPx()
                val at = Offset(d - dd / 2 + 1.dp.toPx(), d - dd / 2 - 1.dp.toPx())
                // A gap the colour of nothing, then the dot.
                drawCircle(Color.Transparent, dd / 2 + 2.dp.toPx(), at, blendMode = BlendMode.Clear)
                drawCircle(Palette.ok, dd / 2, at)
            }
        }
        if (face == null) {
            Text(
                handle.take(1).uppercase(), color = ink,
                fontSize = if (size >= Metric.faceBig) Type.avatarBig.first else Type.avatar.first,
                fontWeight = Type.avatar.second,
            )
        }
    }
}

/** The small explanatory line under a row: `SheetHint`. Nothing when empty. */
@Composable
fun KinHint(text: String, modifier: Modifier = Modifier, tone: Color = Palette.muted) {
    if (text.isEmpty()) return
    Text(
        text, color = tone,
        fontSize = Type.row.first, fontWeight = Type.row.second,
        modifier = modifier.fillMaxWidth().padding(start = Metric.s3, top = Metric.s1, bottom = Metric.s2),
    )
}

/** The pill that says what the camera is doing, over the picture. */
@Composable
fun HintPill(text: String, modifier: Modifier = Modifier, tone: Color = Palette.fg, onClick: (() -> Unit)? = null) {
    GlassSurface(
        modifier.height(Metric.pillHeight + Metric.s2),
        radius = Metric.capsule(Metric.pillHeight + Metric.s2),
        blurRadius = 18.dp,
    ) {
        Box(
            Modifier
                .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
                .padding(horizontal = Metric.s5),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text, color = tone,
                fontSize = Type.field.first, fontWeight = Type.status.second, maxLines = 1,
            )
        }
    }
}
