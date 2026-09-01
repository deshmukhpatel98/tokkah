package com.tokkah.kin.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

/**
 * The call surface, from Controls.swift and UI-SPEC.md §B.
 *
 * Their face is the whole screen. One chrome bar at the bottom that auto-hides
 * after 4 s and comes back on a tap anywhere; self-view is OFF by default with
 * hold-to-peek (the mirror is the fatigue mechanism, so it can never be left on
 * by accident); the mute BADGE persists even when the chrome is gone, because
 * state is not chrome; and leave is a two-step confirm that morphs in place
 * rather than a modal over live video.
 *
 * No numbers anywhere: the status pill speaks in plain words.
 */
@Composable
fun CallScreen(
    room: String,
    sentence: String,
    safetyCode: String?,
    turnMine: Boolean,
    turnTheirs: Boolean,
    voicing: Boolean,
    muted: Boolean,
    camOn: Boolean,
    onMute: () -> Unit,
    onCamera: () -> Unit,
    onFlip: () -> Unit,
    onLeave: () -> Unit,
    peeking: Boolean,
    onPeek: (Boolean) -> Unit,
    caption: String?,
    bloom: String?,
    cueLevel: Float,
    farVideo: @Composable () -> Unit,
    selfVideo: @Composable () -> Unit,
) {
    var chromeShown by remember { mutableStateOf(true) }
    var lastTouch by remember { mutableIntStateOf(0) }
    var leaveArmed by remember { mutableStateOf(false) }
    val haptics = LocalHapticFeedback.current

    // Auto-hide after 4 s of no interaction; any tap brings it back.
    LaunchedEffect(lastTouch) {
        chromeShown = true
        delay(4000)
        chromeShown = false
        leaveArmed = false
    }

    GlassBackdrop(
        Modifier.fillMaxSize().background(Palette.bg),
        backdrop = { Box(Modifier.fillMaxSize()) { farVideo() } },
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    detectTapGestures(onTap = { lastTouch++ })
                },
        ) {
            // ── the speaking edge: colour is whose turn, never dark ──────────
            val edgeAlpha by animateFloatAsState(
                if (voicing) 1f else 0.35f, tween(120), label = "edge",
            )
            Box(
                Modifier
                    .align(Alignment.TopCenter)
                    .statusBarsPadding()
                    .fillMaxWidth()
                    .padding(horizontal = Metric.gutter)
                    .height(if (turnMine) 5.dp else 3.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(
                        when {
                            turnMine -> Palette.ok.copy(alpha = edgeAlpha)
                            turnTheirs -> Palette.accent.copy(alpha = 0.9f)
                            else -> Palette.fill(0.12f)
                        },
                    ),
            )

            // ── the status pill, in the sky ─────────────────────────────────
            AnimatedVisibility(
                chromeShown,
                Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(top = Metric.topInset),
                enter = fadeIn(tween(140)), exit = fadeOut(tween(220)),
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    HintPill(sentence)
                    if (safetyCode != null) {
                        Spacer(Modifier.height(Metric.s2))
                        GlassSurface(
                            radius = Metric.capsule(Metric.pillHeight),
                            blurRadius = 18.dp,
                        ) {
                            Column(
                                Modifier.padding(horizontal = Metric.s4, vertical = Metric.s2),
                                horizontalAlignment = Alignment.CenterHorizontally,
                            ) {
                                Text(safetyCode, color = Palette.fg,
                                    fontSize = Type.code.first, fontWeight = Type.code.second)
                                Text(
                                    "read this aloud to check nobody is in the middle",
                                    color = Palette.muted, textAlign = TextAlign.Center,
                                    fontSize = Type.caption.first, fontWeight = Type.caption.second,
                                )
                            }
                        }
                    }
                }
            }

            // ── THE BLOOM ────────────────────────────────────────────────────
            //
            // A listening noise, as a word: brief, large and warm, in the
            // middle of their face rather than in a caption band. It is not
            // something to READ — it is the sound somebody makes to say they
            // are still with you, and it should register the way that does.
            if (bloom != null) {
                Text(
                    bloom, color = Palette.fg.copy(alpha = (0.35f + 0.65f * cueLevel)),
                    fontSize = Type.bloom.first, fontWeight = Type.bloom.second,
                    modifier = Modifier.align(Alignment.Center),
                )
            }

            // ── THE CAPTION BAND ─────────────────────────────────────────────
            //
            // A real utterance from the muted side, revised in place as the
            // recogniser changes its mind rather than appended to, so a wrong
            // first guess is corrected instead of stacking up. Sits above the
            // chrome, because reading competes with listening and this is the
            // thing you do INSTEAD of hearing them.
            if (caption != null) {
                GlassSurface(
                    Modifier
                        .align(Alignment.BottomCenter)
                        .navigationBarsPadding()
                        .padding(horizontal = Metric.gutter)
                        .padding(bottom = Metric.control + Metric.s8 + Metric.s5)
                        .fillMaxWidth(),
                    radius = Metric.captionRadius,
                    blurRadius = 22.dp,
                ) {
                    Text(
                        caption, color = Palette.fg,
                        fontSize = Type.said.first, fontWeight = Type.said.second,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth().padding(Metric.s4),
                    )
                }
            }

            // ── the peek: only while the finger is held ─────────────────────
            if (peeking) {
                Box(
                    Modifier
                        .align(Alignment.TopEnd)
                        .statusBarsPadding()
                        .padding(Metric.gutter)
                        .size(width = 108.dp, height = 148.dp)
                        .clip(RoundedCornerShape(Metric.captionRadius)),
                ) { selfVideo() }
            }

            // ── the mute badge: state is not chrome, so it never hides ──────
            if (muted) {
                GlassSurface(
                    Modifier
                        .align(Alignment.BottomStart)
                        .navigationBarsPadding()
                        .padding(Metric.gutter)
                        .padding(bottom = Metric.control + Metric.s6)
                        .size(Metric.avatar),
                    radius = Metric.capsule(Metric.avatar),
                    blurRadius = 14.dp,
                ) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Glyph(GlyphKind.MIC, Palette.bad, size = 18.dp, slashed = true)
                    }
                }
            }

            // ── one chrome bar ──────────────────────────────────────────────
            AnimatedVisibility(
                chromeShown,
                Modifier.align(Alignment.BottomCenter).navigationBarsPadding(),
                enter = fadeIn(tween(140)) + slideInVertically(tween(180)) { it / 3 },
                exit = fadeOut(tween(220)) + slideOutVertically(tween(220)) { it / 3 },
            ) {
                Row(
                    Modifier.padding(Metric.barInset),
                    horizontalArrangement = Arrangement.spacedBy(Metric.controlGap),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    ControlButton(GlyphKind.MIC, on = !muted, slashed = muted,
                        tone = if (muted) Palette.bad else Palette.fg) {
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        lastTouch++; onMute()
                    }
                    ControlButton(GlyphKind.CAMERA, on = camOn,
                        slashed = !camOn, tone = if (camOn) Palette.fg else Palette.muted) {
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        lastTouch++; onCamera()
                    }
                    // Hold to peek. Never a toggle: a mirror you can leave on by
                    // accident is the thing the research says to remove.
                    PeekButton(onPeek) { lastTouch++ }
                    ControlButton(GlyphKind.FLIP, on = false) { lastTouch++; onFlip() }
                    Spacer(Modifier.width(Metric.s4))
                    LeaveButton(leaveArmed) {
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        lastTouch++
                        if (leaveArmed) onLeave() else leaveArmed = true
                    }
                }
            }
        }
    }
}

@Composable
private fun ControlButton(
    glyph: GlyphKind,
    on: Boolean,
    tone: Color = Palette.fg,
    slashed: Boolean = false,
    onClick: () -> Unit,
) {
    GlassSurface(
        Modifier.size(Metric.control),
        radius = Metric.capsule(Metric.control),
        tint = if (on) Palette.fill(0.10f) else Color.Transparent,
        blurRadius = 20.dp,
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null, onClick = onClick,
                ),
            contentAlignment = Alignment.Center,
        ) {
            Glyph(glyph, tone, slashed = slashed)
        }
    }
}

/** ≥500 ms hold shows the mirror; release hides it. Pure peek, no state change. */
@Composable
private fun PeekButton(onPeek: (Boolean) -> Unit, onTouch: () -> Unit) {
    GlassSurface(
        Modifier.size(Metric.control),
        radius = Metric.capsule(Metric.control),
        blurRadius = 20.dp,
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    detectTapGestures(
                        onPress = {
                            onTouch()
                            onPeek(true)
                            tryAwaitRelease()
                            onPeek(false)
                        },
                    )
                },
            contentAlignment = Alignment.Center,
        ) {
            Glyph(GlyphKind.EYE, Palette.fg)
        }
    }
}

/** Morphs in place into its own confirm — never a modal over live video. */
@Composable
private fun LeaveButton(armed: Boolean, onClick: () -> Unit) {
    GlassSurface(
        Modifier.height(Metric.control).then(
            if (armed) Modifier.width(168.dp) else Modifier.width(Metric.control),
        ),
        radius = Metric.capsule(Metric.control),
        tint = Palette.destructiveTint,
        blurRadius = 20.dp,
        dim = 0.15f,
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null, onClick = onClick,
                ),
            contentAlignment = Alignment.Center,
        ) {
            if (armed) {
                Text("tap again to leave", color = Palette.fg,
                    fontSize = Type.button.first, fontWeight = Type.buttonProminent.second,
                    maxLines = 1)
            } else {
                Glyph(GlyphKind.CROSS, Palette.fg)
            }
        }
    }
}
