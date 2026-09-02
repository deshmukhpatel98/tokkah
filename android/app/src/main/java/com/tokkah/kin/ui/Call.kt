package com.tokkah.kin.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import androidx.compose.runtime.withFrameNanos

/**
 * The call surface, from `CallControls` in Controls.swift (0.125.0).
 *
 * Their face is the whole screen. One chrome bar at the bottom — mic, camera,
 * peek, flip (only with two cameras), the handset — that hides after 2.6 s of
 * stillness and comes back on a touch anywhere; the `…` top-right opens the
 * sheet; the who-pill top-left says who and for how long, and goes with the
 * bar; the status pill in the sky says one thing in plain words; a warn pill
 * under it says what is wrong with the picture, when something is. Self-view is
 * OFF with hold-to-peek, and a TAP on peek opens the People page. The mute
 * BADGE persists when the chrome is gone, because state is not chrome.
 *
 * Alone in the call there is no panel and no words: the invite link, which
 * copies when you press it, and one round button that turns it into a name
 * field. The call is already live behind this — the card is only how you tell
 * somebody else where it is.
 *
 * Leave is the Mac's: a tap arms "tap to leave" and a second tap leaves; a hold
 * fills the pill over 0.6 s and leaves by itself; an armed pill disarms after
 * three seconds so it is not a trap for the next touch.
 *
 * No numbers anywhere: every pill speaks in words.
 */
class CallUi(
    /** Who is on the other end, for the who-pill and the poster. "" for a room. */
    val peerHandle: String,
    /** Seconds since the call connected; null before it has. */
    val elapsed: Int?,
    val sentence: String,
    /** The warn pill's line, or "". */
    val warning: String,
    /** Somebody is actually here. False = the waiting state. */
    val peerPresent: Boolean,
    /** The far end's picture is intentionally blank, and why ("Camera off" …). */
    val noPicture: String?,
    val inviteLink: String,
    val safetyCode: String?,
    val turnMine: Boolean,
    val turnTheirs: Boolean,
    val voicing: Boolean,
    /** How audible this end is right now, 0..1 (`Audio.sharedGate.nearLoudNow`). */
    val loud: Float = 0f,
    val muted: Boolean,
    val camOn: Boolean,
    val canFlip: Boolean,
    val peeking: Boolean,
    val caption: String?,
    val bloom: String?,
    val cueLevel: Float,
    val sheet: List<SheetItem>?,
    /** Bumped to put the caret in the dial field ("Call someone new"). */
    val dialFocus: Int = 0,
)

@Composable
fun CallScreen(
    ui: CallUi,
    onMute: () -> Unit,
    onCamera: () -> Unit,
    onFlip: () -> Unit,
    onLeave: () -> Unit,
    onPeek: (Boolean) -> Unit,
    onPeople: () -> Unit,
    onMore: () -> Unit,
    onCloseSheet: () -> Unit,
    onCopyInvite: () -> Boolean,
    onDial: (String) -> Unit,
    farVideo: @Composable () -> Unit,
    selfVideo: @Composable () -> Unit,
) {
    var lastTouch by remember { mutableIntStateOf(0) }
    var chromeShown by remember { mutableStateOf(true) }
    var leaveArmed by remember { mutableStateOf(false) }
    var leaveArmedAt by remember { mutableIntStateOf(0) }
    val haptics = LocalHapticFeedback.current
    // Pinned: alone, holding for somebody, armed, or the sheet is open. The
    // bar never hides while there is nobody to look at instead of it.
    val pinned = !ui.peerPresent || leaveArmed || ui.sheet != null || ui.noPicture != null

    // Hide after 2.6 s of stillness (`barStillness`); any touch brings it back.
    LaunchedEffect(lastTouch, pinned) {
        chromeShown = true
        if (pinned) return@LaunchedEffect
        delay(2600)
        chromeShown = false
    }
    // An armed hang-up left on screen is a trap for the next touch: 3 s.
    LaunchedEffect(leaveArmedAt) {
        if (!leaveArmed) return@LaunchedEffect
        delay(3000)
        leaveArmed = false
    }

    GlassBackdrop(
        Modifier.fillMaxSize().background(Palette.bg),
        backdrop = { Box(Modifier.fillMaxSize()) { farVideo() } },
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .pointerInput(Unit) { detectTapGestures(onTap = { lastTouch++ }) },
        ) {
            // ── the speaking edge: colour is whose turn, thickness is how ────
            //    audible you are, and it is never dark (`layoutEdge`, `floorTick`)
            //
            // The Mac strokes the whole window's rounded rectangle: green is
            // speaking (this mic reaching them), blue is listening, and the
            // width breathes with the voice — 4.5 + 3.5 × loudness speaking,
            // 3 listening, 1.5 at rest. A bar along one edge was this app's
            // first draft; the Mac's edge is a frame, and so is this.
            val wTarget = when {
                ui.turnMine -> 4.5f + 3.5f * ui.loud.coerceIn(0f, 1f)
                ui.turnTheirs -> 3f
                else -> 1.5f
            }
            val edgeW by animateFloatAsState(wTarget, tween(if (wTarget > 3f) 50 else 200), label = "edgeW")
            val edgeHue by animateFloatAsState(if (ui.turnMine) 1f else 0f, tween(160), label = "edgeHue")
            val edgeAlpha by animateFloatAsState(
                if (ui.turnMine || ui.turnTheirs) 1f else 0.35f, tween(120), label = "edge",
            )
            androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
                val w = edgeW.dp.toPx()
                val ins = w / 2
                val r = Metric.windowRadius.toPx() - ins
                val tint = androidx.compose.ui.graphics.lerp(Palette.accent, Palette.ok, edgeHue)
                drawRoundRect(
                    tint.copy(alpha = edgeAlpha),
                    topLeft = Offset(ins, ins),
                    size = Size(size.width - w, size.height - w),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(r.coerceAtLeast(0f)),
                    style = androidx.compose.ui.graphics.drawscope.Stroke(width = w),
                )
            }

            // ── THE POSTER: their face where their picture would be ─────────
            //
            // The Mac blurs the last frame under the poster (`pauseLayer`); a
            // SurfaceView cannot be blurred without giving up the latency it is
            // there for, so the frozen frame is dimmed instead and the poster
            // says why.
            if (ui.noPicture != null) {
                Box(Modifier.fillMaxSize().background(Palette.dimInk.copy(alpha = 0.55f)))
            }
            if (ui.noPicture != null) {
                Column(
                    Modifier.align(Alignment.Center),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    if (ui.peerHandle.isNotEmpty()) {
                        Avatar(ui.peerHandle, size = Metric.faceBig * 2, ring = Metric.faceBigRing)
                        Spacer(Modifier.height(Metric.s4))
                        Text(display(ui.peerHandle), color = Palette.fg,
                            fontSize = Type.name.first, fontWeight = Type.name.second)
                        Spacer(Modifier.height(Metric.s2))
                    }
                    Text(ui.noPicture, color = Palette.muted,
                        fontSize = Type.status.first, fontWeight = Type.status.second)
                }
            }

            // ── the pills in the sky ────────────────────────────────────────
            Column(
                Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(top = Metric.s4),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                if (ui.sentence.isNotEmpty()) HintPill(ui.sentence)
                if (ui.warning.isNotEmpty()) {
                    Spacer(Modifier.height(Metric.s2))
                    HintPill(ui.warning, tone = Palette.warn)
                }
            }

            // ── who, and for how long: top-left, with the bar ───────────────
            val who = whoLine(ui.peerHandle, ui.elapsed)
            AnimatedVisibility(
                chromeShown && who.isNotEmpty(),
                Modifier.align(Alignment.TopStart).statusBarsPadding().padding(start = Metric.gutter, top = Metric.topInset),
                enter = fadeIn(tween(140)), exit = fadeOut(tween(220)),
            ) { HintPill(who) }

            // ── `…` top-right of the window ─────────────────────────────────
            GlassSurface(
                Modifier
                    .align(Alignment.TopEnd)
                    .statusBarsPadding()
                    .padding(Metric.gutter)
                    .size(Metric.controlSmall)
                    .semantics { contentDescription = "more"; role = Role.Button },
                radius = Metric.capsule(Metric.controlSmall),
                tint = if (ui.sheet != null) Palette.fill(0.14f) else Color.Transparent,
                blurRadius = 20.dp,
            ) {
                Box(Modifier.fillMaxSize().clickable { lastTouch++; onMore() },
                    contentAlignment = Alignment.Center) {
                    Glyph(GlyphKind.MORE, Palette.fg, size = 22.dp)
                }
            }

            // ── THE BLOOM ────────────────────────────────────────────────────
            if (ui.bloom != null) {
                Text(
                    ui.bloom, color = Palette.fg.copy(alpha = (0.35f + 0.65f * ui.cueLevel)),
                    fontSize = Type.bloom.first, fontWeight = Type.bloom.second,
                    modifier = Modifier.align(Alignment.Center),
                )
            }

            // ── THE CAPTION BAND ─────────────────────────────────────────────
            if (ui.caption != null) {
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
                        ui.caption, color = Palette.fg,
                        fontSize = Type.said.first, fontWeight = Type.said.second,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth().padding(Metric.s4),
                    )
                }
            }

            // ── WAITING: the link and one round button ──────────────────────
            if (!ui.peerPresent) {
                WaitingRow(ui.inviteLink, onCopyInvite, onDial, ui.dialFocus, Modifier.align(Alignment.Center))
            }

            // ── the peek: only while the finger is held ─────────────────────
            if (ui.peeking) {
                Box(
                    Modifier
                        .align(Alignment.TopEnd)
                        .statusBarsPadding()
                        .padding(Metric.gutter)
                        .padding(top = Metric.controlSmall + Metric.s2)
                        .size(width = 108.dp, height = 148.dp)
                        .clip(RoundedCornerShape(Metric.captionRadius)),
                ) { selfVideo() }
            }

            // ── the mute badge: state is not chrome, so it never hides ──────
            if (ui.muted && !chromeShown) {
                GlassSurface(
                    Modifier
                        .align(Alignment.BottomStart)
                        .navigationBarsPadding()
                        .padding(Metric.gutter)
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
                    horizontalArrangement = Arrangement.spacedBy(if (leaveArmed) 64.dp else Metric.controlGap),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (!leaveArmed) {
                        ControlButton(GlyphKind.MIC, on = !ui.muted, name = "microphone",
                            state = if (ui.muted) "muted" else "on",
                            slashed = ui.muted, tone = if (ui.muted) Palette.bad else Palette.fg) {
                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            lastTouch++; onMute()
                        }
                        ControlButton(GlyphKind.CAMERA, on = ui.camOn, name = "camera",
                            state = if (ui.camOn) "on" else "off",
                            slashed = !ui.camOn, tone = if (ui.camOn) Palette.fg else Palette.muted) {
                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            lastTouch++; onCamera()
                        }
                        // Tap for people · hold to see yourself. Never a toggle:
                        // a mirror you can leave on by accident is the thing the
                        // research says to remove.
                        PeekButton(onPeek, onTap = { lastTouch++; onPeople() }) { lastTouch++ }
                        if (ui.canFlip) ControlButton(GlyphKind.FLIP, on = false, name = "switch camera") { lastTouch++; onFlip() }
                    }
                    LeaveButton(
                        armed = leaveArmed,
                        onArm = {
                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            lastTouch++
                            if (!leaveArmed) { leaveArmed = true; leaveArmedAt++ }
                        },
                        onTapArmed = { lastTouch++; onLeave() },
                        onHeldThrough = { lastTouch++; onLeave() },
                    )
                }
            }

            // ── the sheet, over everything, with its scrim ──────────────────
            if (ui.sheet != null) {
                KinSheet(ui.sheet, onClose = onCloseSheet,
                    topInset = Metric.gutter + Metric.controlSmall)
            }
        }
    }
}

/** "Meera  ·  0:12", h:mm:ss past an hour — `renderWho`. */
private fun whoLine(handle: String, elapsed: Int?): String {
    val name = if (handle.isEmpty()) "" else display(handle)
    val t = elapsed?.let { s ->
        if (s >= 3600) "%d:%02d:%02d".format(s / 3600, (s / 60) % 60, s % 60)
        else "%d:%02d".format(s / 60, s % 60)
    } ?: ""
    return listOf(name, t).filter { it.isNotEmpty() }.joinToString("  ·  ")
}

private fun display(handle: String) = com.tokkah.kin.net.Identity.display(handle)

/**
 * `WaitingCard` in `.invite` / `.dial`: the link in a `cardFieldRadius` well,
 * `fieldHeight` tall, 12 pt mono; pressing it copies and it says "copied ✓"
 * for two seconds; the round phone button beside it turns the well into a
 * field — "who do you want to call?" — and Return rings the name.
 */
@Composable
private fun WaitingRow(
    link: String,
    onCopy: () -> Boolean,
    onDial: (String) -> Unit,
    dialFocus: Int,
    modifier: Modifier = Modifier,
) {
    var dialing by remember { mutableStateOf(false) }
    LaunchedEffect(dialFocus) { if (dialFocus > 0) dialing = true }
    var copied by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    LaunchedEffect(copied) { if (copied) { delay(2000); copied = false } }
    LaunchedEffect(dialing) { if (dialing) focus.requestFocus() }
    val shape = RoundedCornerShape(Metric.cardFieldRadius)
    Row(modifier.padding(horizontal = Metric.gutter), verticalAlignment = Alignment.CenterVertically) {
        GlassSurface(
            Modifier.widthIn(min = 180.dp, max = 320.dp).height(Metric.fieldHeight),
            radius = Metric.cardFieldRadius, blurRadius = 18.dp,
        ) {
            if (dialing) {
                Box(Modifier.fillMaxSize().padding(horizontal = Metric.s4), contentAlignment = Alignment.CenterStart) {
                    BasicTextField(
                        value = name, onValueChange = { name = it }, singleLine = true,
                        textStyle = TextStyle(color = Palette.fg, fontSize = Type.field.first, fontWeight = Type.field.second),
                        cursorBrush = SolidColor(Palette.accent),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                        keyboardActions = KeyboardActions(onGo = { onDial(name); name = ""; dialing = false }),
                        modifier = Modifier.fillMaxWidth().focusRequester(focus),
                        decorationBox = { inner ->
                            if (name.isEmpty()) Text("who do you want to call?", color = Palette.muted,
                                fontSize = Type.field.first, fontWeight = Type.field.second, maxLines = 1)
                            inner()
                        },
                    )
                }
            } else {
                Box(
                    Modifier.fillMaxSize().clickable { if (onCopy()) copied = true }
                        .semantics { contentDescription = "Invite link $link, tap to copy"; role = Role.Button }
                        .padding(horizontal = Metric.s3),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        if (copied) "copied ✓" else link.removePrefix("https://"),
                        color = Palette.fg, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        fontFamily = FontFamily.Monospace,
                        fontSize = Type.mono.first, fontWeight = Type.mono.second,
                    )
                }
            }
        }
        Spacer(Modifier.width(Metric.s2))
        GlassSurface(Modifier.size(Metric.fieldHeight), radius = Metric.capsule(Metric.fieldHeight), blurRadius = 18.dp) {
            Box(
                Modifier.fillMaxSize().clickable {
                    if (dialing && name.isNotBlank()) { onDial(name); name = ""; dialing = false }
                    else dialing = !dialing
                }.semantics {
                    contentDescription = if (dialing) "Call this name" else "Call someone by name"; role = Role.Button
                },
                contentAlignment = Alignment.Center,
            ) { Glyph(GlyphKind.PHONE, Palette.fg, size = 20.dp) }
        }
    }
}

/**
 * Every control announces itself. A control with no name announces as "button"
 * — the same thing every other unnamed control announces as — so a screen
 * reader met a row of identical buttons (Kin 0.123.0). The names are the Mac's
 * `help` strings, and a switch-like control also says which way it is.
 */
@Composable
private fun ControlButton(
    glyph: GlyphKind,
    on: Boolean,
    name: String,
    state: String? = null,
    tone: Color = Palette.fg,
    slashed: Boolean = false,
    onClick: () -> Unit,
) {
    GlassSurface(
        Modifier.size(Metric.control).semantics {
            contentDescription = name; role = Role.Button
            if (state != null) stateDescription = state
        },
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

/**
 * Two gestures on one circle: a hold ≥ 350 ms shows the mirror until release
 * (reveal at down, decide at up — the hold stays instant); a shorter press is
 * a tap, and the tap opens the People page.
 */
@Composable
private fun PeekButton(onPeek: (Boolean) -> Unit, onTap: () -> Unit, onTouch: () -> Unit) {
    GlassSurface(
        Modifier.size(Metric.control).semantics {
            contentDescription = "tap for people · hold to see yourself"; role = Role.Button
        },
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
                            val down = System.currentTimeMillis()
                            onPeek(true)
                            tryAwaitRelease()
                            onPeek(false)
                            if (System.currentTimeMillis() - down < 350) onTap()
                        },
                    )
                },
            contentAlignment = Alignment.Center,
        ) {
            Glyph(GlyphKind.PEEK, Palette.fg)
        }
    }
}

/**
 * The handset. Tap → armed, 150 wide, "tap to leave"; tap again → leave.
 * Hold → the red rises across the pill over 0.6 s and it leaves by itself.
 */
@Composable
private fun LeaveButton(
    armed: Boolean,
    onArm: () -> Unit,
    onTapArmed: () -> Unit,
    onHeldThrough: () -> Unit,
) {
    var fill by remember { mutableFloatStateOf(0f) }
    var holding by remember { mutableStateOf(false) }
    LaunchedEffect(holding) {
        if (!holding) { fill = 0f; return@LaunchedEffect }
        val start = System.nanoTime()
        while (isActive) {
            withFrameNanos { }
            val k = (System.nanoTime() - start) / 600_000_000f
            fill = k.coerceAtMost(1f)
            if (k >= 1f) { holding = false; onHeldThrough(); break }
        }
    }
    GlassSurface(
        Modifier.height(Metric.control).width(if (armed) 150.dp else Metric.control).semantics {
            contentDescription = if (armed) "tap again to leave" else "leave call"; role = Role.Button
        },
        radius = Metric.capsule(Metric.control),
        tint = Palette.destructiveTint,
        blurRadius = 20.dp,
        dim = 0.15f,
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .drawBehind {
                    if (fill > 0f) drawRect(Palette.bad.copy(alpha = 0.55f),
                        size = Size(size.width * fill, size.height))
                }
                .pointerInput(armed) {
                    detectTapGestures(
                        onPress = {
                            val wasArmed = armed
                            onArm()
                            holding = true
                            val released = tryAwaitRelease()
                            val through = fill >= 1f
                            holding = false
                            if (released && !through && wasArmed) onTapArmed()
                        },
                    )
                },
            contentAlignment = Alignment.Center,
        ) {
            if (armed) {
                Text("tap to leave", color = Palette.fg,
                    fontSize = Type.button.first, fontWeight = Type.buttonProminent.second,
                    maxLines = 1)
            } else {
                Glyph(GlyphKind.LEAVE, Palette.fg)
            }
        }
    }
}

@Suppress("unused")
private val keepImports = Brush.verticalGradient(listOf(Color.Transparent, Color.Transparent))
