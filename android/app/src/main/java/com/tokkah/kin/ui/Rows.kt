package com.tokkah.kin.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/**
 * The rows on the front card, from `SheetRow` / `PersonRow` in Launcher.swift.
 * A row is `sheetRow` tall, its glyph sits at `rowGlyphInset`, an avatar at
 * `rowAvatarInset`, and a press is a vibrant fill INSIDE the card's glass —
 * never another pane.
 */
@Composable
fun KinRow(
    label: String,
    modifier: Modifier = Modifier,
    detail: String? = null,
    leading: (@Composable () -> Unit)? = null,
    ruled: Boolean = false,
    enabled: Boolean = true,
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
                if (onClick != null && enabled)
                    Modifier.clickable(interaction, indication = null, onClick = onClick)
                else Modifier,
            )
            .drawBehind {
                if (ruled) {
                    drawRect(
                        Palette.glassLine,
                        topLeft = androidx.compose.ui.geometry.Offset(0f, 0f),
                        size = androidx.compose.ui.geometry.Size(size.width, 1f),
                    )
                }
            }
            .padding(horizontal = Metric.s3),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (leading != null) {
            Box(Modifier.width(Metric.rowAvatarInset - Metric.s3), contentAlignment = Alignment.CenterStart) {
                leading()
            }
        }
        Text(
            label,
            color = if (enabled) Palette.fg else Palette.muted,
            fontSize = Type.row.first, fontWeight = Type.row.second,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (detail != null) {
            Spacer(Modifier.width(Metric.s2))
            Text(detail, color = Palette.muted,
                fontSize = Type.caption.first, fontWeight = Type.caption.second, maxLines = 1)
        }
    }
}

/**
 * A person's circle. The hue lands on the RING and the initial, never on a
 * filled disc: one saturation cannot carry white text across the wheel (white
 * on the blue end measures 6.4:1 and on yellow 1.71:1).
 */
@Composable
fun Avatar(handle: String, size: androidx.compose.ui.unit.Dp = Metric.avatar, online: Boolean = false) {
    val ink = Palette.avatarInk(handle)
    Box(contentAlignment = Alignment.Center) {
        Box(
            Modifier
                .size(size)
                .clip(CircleShape)
                .background(Palette.fill(0.10f))
                .border(Metric.avatarRing, ink, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                handle.take(1).uppercase(), color = ink,
                fontSize = if (size >= Metric.faceBig) Type.avatarBig.first else Type.avatar.first,
                fontWeight = Type.avatar.second,
            )
        }
        if (online) {
            Box(
                Modifier
                    .size(size)
                    .padding(top = size - 10.dp, start = size - 10.dp)
                    .size(9.dp)
                    .clip(CircleShape)
                    .background(Palette.ok),
            )
        }
    }
}

/** The small explanatory line under a row: `SheetHint`. */
@Composable
fun KinHint(text: String, modifier: Modifier = Modifier, tone: Color = Palette.muted) {
    Text(
        text, color = tone,
        fontSize = Type.caption.first, fontWeight = Type.caption.second,
        modifier = modifier.fillMaxWidth().padding(horizontal = Metric.s3, vertical = Metric.s1),
    )
}

/** The pill that says what the camera is doing, over the picture. */
@Composable
fun HintPill(text: String, modifier: Modifier = Modifier) {
    GlassSurface(
        modifier.height(Metric.pillHeight),
        radius = Metric.capsule(Metric.pillHeight),
        blurRadius = 18.dp,
    ) {
        Box(Modifier.padding(horizontal = Metric.s3), contentAlignment = Alignment.Center) {
            Text(text, color = Palette.fg,
                fontSize = Type.status.first, fontWeight = Type.status.second, maxLines = 1)
        }
    }
}
