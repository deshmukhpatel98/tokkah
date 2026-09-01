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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * The rows on the front card, from `SheetRow` / `PersonRow` in Controls.swift
 * (1130-1200) and the layout walk in Launcher.swift.
 *
 * A row is `sheetRow` tall; its avatar sits at `s3` from the row's left edge
 * and its label at `rowAvatarInset`; a press is a vibrant fill INSIDE the
 * card's glass, never another pane. The label of a person row is "@" + handle,
 * and the right-hand column is when you last spoke.
 */
@Composable
fun KinRow(
    label: String,
    modifier: Modifier = Modifier,
    detail: String? = null,
    detailTone: Color = Palette.muted,
    leading: (@Composable () -> Unit)? = null,
    labelInset: Dp = Metric.s3,
    tone: Color = Palette.fg,
    onClick: (() -> Unit)? = null,
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val shape = RoundedCornerShape(Metric.concentric(Metric.cardRadius, Metric.cardPad))
    Row(
        modifier
            .fillMaxWidth()
            .height(Metric.sheetRow)
            .clip(shape)
            .background(if (pressed) Palette.fill(0.12f) else Color.Transparent, shape)
            .then(
                if (onClick != null) Modifier.clickable(interaction, indication = null, onClick = onClick)
                else Modifier,
            ),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (leading != null) {
            Box(Modifier.padding(start = Metric.s3), contentAlignment = Alignment.Center) { leading() }
            Spacer(Modifier.width(Metric.rowAvatarInset - Metric.s3 - Metric.avatar))
        } else {
            Spacer(Modifier.width(labelInset))
        }
        Text(
            label, color = tone,
            fontSize = Type.row.first, fontWeight = Type.row.second,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (detail != null) {
            Spacer(Modifier.width(Metric.s2))
            Text(
                detail, color = detailTone,
                fontSize = Type.row.first, fontWeight = Type.row.second, maxLines = 1,
                modifier = Modifier.padding(end = Metric.s3),
            )
        }
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
                clipPath(androidx.compose.ui.graphics.Path().apply {
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

/** The small explanatory line under a row: `SheetHint`. */
@Composable
fun KinHint(text: String, modifier: Modifier = Modifier, tone: Color = Palette.muted) {
    Text(
        text, color = tone,
        fontSize = Type.row.first, fontWeight = Type.row.second,
        modifier = modifier.fillMaxWidth().padding(start = Metric.s3, top = Metric.s1, bottom = Metric.s2),
    )
}

/** The pill that says what the camera is doing, over the picture. */
@Composable
fun HintPill(text: String, modifier: Modifier = Modifier, onClick: (() -> Unit)? = null) {
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
                text, color = Palette.fg,
                fontSize = Type.field.first, fontWeight = Type.status.second, maxLines = 1,
            )
        }
    }
}
