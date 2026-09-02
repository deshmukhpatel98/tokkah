package com.tokkah.kin.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.animation.core.animateFloat
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

/**
 * The calling card, from `CallCard` in Controls.swift (1511-1710).
 *
 * Five states and one card, because the caller's half and the callee's half are
 * the same object seen from two ends: what the person ringing sees, the person
 * being rung should see the mirror of.
 *
 * There is no sentence under the name. It used to read "answer and you will
 * both be in the same room" — which explained something nobody needs explaining,
 * in this app's own word for an implementation detail. You call a person. There
 * is no room.
 */
enum class CallCardMode { INVITE, DIAL, RINGING, CALLING, NO_ANSWER }

@Composable
fun CallCard(
    mode: CallCardMode,
    who: String,
    line: String? = null,
    because: String? = null,
    faceFile: java.io.File? = null,
    onAnswer: () -> Unit = {},
    onDecline: () -> Unit = {},
    onCancel: () -> Unit = {},
    onCallAgain: () -> Unit = {},
) {
    Box(
        Modifier.fillMaxSize().background(Palette.dimInk.copy(alpha = 0.55f)),
        contentAlignment = Alignment.Center,
    ) {
        GlassSurface(
            Modifier.fillMaxWidth().padding(Metric.gutter),
            radius = Metric.cardRadius,
        ) {
            Column(
                Modifier.fillMaxWidth().padding(Metric.cardPad),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(Metric.s4),
            ) {
                Spacer(Modifier.height(Metric.s2))
                // Their picture BEFORE you answer — and only theirs, and only
                // if you have answered them before. A stranger rings as a name
                // and nothing else, because drawing their picture would mean
                // opening a connection to them before you had agreed to it.
                Avatar(who, size = Metric.faceBig, ring = Metric.faceBigRing,
                    face = rememberFace(faceFile))
                Text(
                    line ?: when (mode) {
                        CallCardMode.RINGING -> "@$who is calling"
                        CallCardMode.CALLING -> "Calling @$who"
                        else -> "@$who"
                    },
                    color = Palette.fg, textAlign = TextAlign.Center,
                    fontSize = Type.name.first, fontWeight = Type.name.second,
                )
                if (because != null) {
                    Text(because, color = Palette.muted, textAlign = TextAlign.Center,
                        fontSize = Type.row.first, fontWeight = Type.row.second)
                }
                // While the ring travels, something that is obviously alive:
                // the Mac's three dots, pulsing in turn (`startDots`).
                if (mode == CallCardMode.CALLING) Dots()
                Spacer(Modifier.height(Metric.s1))
                when (mode) {
                    CallCardMode.RINGING -> Row(
                        horizontalArrangement = Arrangement.spacedBy(Metric.s3),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        CardButton("Decline", Palette.destructiveTint, Modifier.weight(1f), onDecline)
                        CardButton("Answer", Palette.ok.copy(alpha = 0.30f), Modifier.weight(1f), onAnswer)
                    }
                    // A ring in flight has a way out: hanging up on a phone that
                    // is still ringing un-rings it.
                    CallCardMode.CALLING ->
                        CardButton("Cancel", Palette.destructiveTint, Modifier.fillMaxWidth(), onCancel)
                    CallCardMode.NO_ANSWER -> Row(
                        horizontalArrangement = Arrangement.spacedBy(Metric.s3),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        CardButton("Close", Color.Transparent, Modifier.weight(1f), onCancel)
                        CardButton("Call again", Palette.fill(0.16f), Modifier.weight(1f), onCallAgain)
                    }
                    else -> {}
                }
                Spacer(Modifier.height(Metric.s1))
            }
        }
    }
}

/** Three 6 pt dots, 7 apart, each breathing on its own phase. */
@Composable
private fun Dots() {
    val t = androidx.compose.animation.core.rememberInfiniteTransition(label = "dots")
    val phase by t.animateFloat(
        0f, 1f,
        androidx.compose.animation.core.infiniteRepeatable(
            androidx.compose.animation.core.tween(1200, easing = androidx.compose.animation.core.LinearEasing),
        ),
        label = "dotPhase",
    )
    Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
        for (i in 0 until 3) {
            val k = ((phase - i / 3f + 1f) % 1f)
            val a = 0.25f + 0.75f * (0.5f + 0.5f * kotlin.math.sin(k * 2 * Math.PI).toFloat())
            Box(
                Modifier.padding(vertical = Metric.s1).height(6.dp).width(6.dp)
                    .background(Palette.fg.copy(alpha = a), androidx.compose.foundation.shape.CircleShape),
            )
        }
    }
}

@Composable
private fun rememberFace(file: java.io.File?): androidx.compose.ui.graphics.ImageBitmap? {
    if (file == null) return null
    return androidx.compose.runtime.remember(file.path, file.lastModified()) {
        runCatching {
            android.graphics.BitmapFactory.decodeFile(file.path)
                ?.asImageBitmap()
        }.getOrNull()
    }
}



@Composable
private fun CardButton(
    label: String,
    tint: Color,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    GlassSurface(
        modifier.height(Metric.control),
        radius = Metric.capsule(Metric.control),
        tint = tint,
        blurRadius = 20.dp,
        dim = if (tint == Color.Transparent) Palette.dimAlpha else 0.18f,
    ) {
        Box(Modifier.fillMaxSize().clickable(onClick = onClick), contentAlignment = Alignment.Center) {
            Text(label, color = Palette.fg,
                fontSize = Type.confirm.first, fontWeight = Type.confirm.second)
        }
    }
}
