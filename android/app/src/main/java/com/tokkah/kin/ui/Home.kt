package com.tokkah.kin.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp

/**
 * The front door, laid out from Launcher.swift (0.113.0, "one field, one card").
 *
 * Your own camera fills the window; ONE pane of glass floats at the bottom,
 * inset by `gutter`, and everything that is not the picture lives on it. Rows
 * are walked top-down in one list, so adding one is a line and cannot leave a
 * gap where a hidden view used to be — the order is: a call still running, a
 * link somebody sent, the people, the field, the invite.
 */
class Person(val handle: String, val online: Boolean = false, val lastSeen: String? = null)

@Composable
fun HomeScreen(
    room: String,
    onRoom: (String) -> Unit,
    people: List<Person>,
    myHandle: String,
    cameraHint: String?,
    resumeRoom: String?,
    pastedLink: String?,
    settingsOpen: Boolean,
    onSettings: () -> Unit,
    onJoin: () -> Unit,
    onCall: (String) -> Unit,
    onResume: () -> Unit,
    onInvite: () -> Unit,
    quiet: Boolean,
    onQuiet: (Boolean) -> Unit,
    preview: @Composable () -> Unit,
) {
    GlassBackdrop(
        Modifier.fillMaxSize().background(Palette.bg),
        backdrop = {
            // Nothing over the picture: it is the person's own face and the
            // card is the only thing allowed to sit on it.
            Box(Modifier.fillMaxSize()) { preview() }
        },
    ) {
        Box(Modifier.fillMaxSize().statusBarsPadding()) {
            // Top-right of the WINDOW, so the control does not travel when the
            // card changes height — a control that moves is one you must find again.
            GlassSurface(
                Modifier
                    .align(Alignment.TopEnd)
                    .padding(Metric.gutter)
                    .size(Metric.controlSmall),
                radius = Metric.capsule(Metric.controlSmall),
                tint = if (settingsOpen) Palette.fill(0.14f) else androidx.compose.ui.graphics.Color.Transparent,
                blurRadius = 20.dp,
            ) {
                Box(Modifier.fillMaxSize().clickable(onClick = onSettings),
                    contentAlignment = Alignment.Center) {
                    Glyph(GlyphKind.MORE, Palette.fg, size = 22.dp)
                }
            }

            Column(
                Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .padding(Metric.gutter)
                    .navigationBarsPadding()
                    .imePadding(),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                // The pill sits in the SKY above the card, in the picture,
                // with a clear band between them.
                if (cameraHint != null) {
                    HintPill(cameraHint)
                    Spacer(Modifier.height(Metric.s8))
                }
                GlassSurface(Modifier.fillMaxWidth(), radius = Metric.cardRadius) {
                    Column(
                        Modifier.padding(Metric.cardPad),
                        verticalArrangement = Arrangement.spacedBy(Metric.s1),
                    ) {
                        if (settingsOpen) {
                            SettingsRows(myHandle, quiet, onQuiet)
                        } else {
                            resumeRoom?.let {
                                KinRow("Back to $it", detail = "still going", onClick = onResume)
                            }
                            pastedLink?.let {
                                KinRow("Join $it", detail = "from a link", onClick = { onRoom(it); onJoin() })
                            }
                            for (p in people) {
                                KinRow(
                                    "@" + p.handle,
                                    detail = p.lastSeen,
                                    leading = { Avatar(p.handle, online = p.online) },
                                    onClick = { onCall(p.handle) },
                                )
                            }
                            RoomField(room, onRoom, onJoin)
                            KinRow("Copy a link to invite someone", detail = "copy",
                                onClick = onInvite)
                            // A brand-new install has nobody to call until
                            // somebody knows this phone's name — so the name
                            // stays on the front card exactly until the first
                            // person is in the list, then moves behind the `…`.
                            if (people.isEmpty()) {
                                KinRow("@$myHandle", detail = "copy",
                                    leading = { Avatar(myHandle) }, onClick = onInvite)
                                KinHint("Give this to someone and they can call you.")
                            }
                        }
                    }
                }
            }
        }
    }
}

/** The one editable thing. Return is the commit; the placeholder is the label. */
@Composable
private fun RoomField(room: String, onRoom: (String) -> Unit, onJoin: () -> Unit) {
    // A FILL, not a second pane. "Avoid overcrowding or layering Liquid Glass
    // elements on top of each other" — and it is not only a rule: a pane inside
    // a pane re-blurred the card's own blur and photographed as dark blobs
    // smeared across the field.
    val shape = RoundedCornerShape(Metric.capsule(Metric.fieldHeight))
    Box(
        Modifier
            .fillMaxWidth()
            .height(Metric.fieldHeight)
            .clip(shape)
            .background(Palette.fill(0.10f), shape)
            .border(1.dp, Palette.glassLine, shape),
    ) {
        Box(Modifier.fillMaxSize().padding(horizontal = Metric.s4), contentAlignment = Alignment.CenterStart) {
            BasicTextField(
                value = room,
                onValueChange = onRoom,
                singleLine = true,
                textStyle = TextStyle(
                    color = Palette.fg,
                    fontSize = Type.field.first, fontWeight = Type.field.second,
                ),
                cursorBrush = SolidColor(Palette.accent),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { onJoin() }),
                modifier = Modifier.fillMaxWidth(),
                decorationBox = { inner ->
                    if (room.isEmpty()) {
                        Text("Type a handle, like meera", color = Palette.muted,
                            fontSize = Type.field.first, fontWeight = Type.field.second)
                    }
                    inner()
                },
            )
        }
    }
}

@Composable
private fun SettingsRows(myHandle: String, quiet: Boolean, onQuiet: (Boolean) -> Unit) {
    if (myHandle.isEmpty()) {
        KinHint("This phone has no name yet, so nobody can call it. It takes one the first time it reaches the server.")
    } else {
        KinRow("@$myHandle", detail = "copy", leading = { Avatar(myHandle) })
        KinHint("Give this to someone and they can call you.")
    }
    KinRow("Let people reach you when Kin is closed", detail = "off",
        labelInset = Metric.rowAvatarInset, tone = Palette.muted)
    KinHint("Not built on Android yet — the phone has to hold a connection for this.")
    KinRow(
        "Don't ring me", detail = if (quiet) "on" else "off",
        labelInset = Metric.rowAvatarInset,
        onClick = { onQuiet(!quiet) },
    )
    KinHint("Calls to you are quietly declined until you turn this off.")
}
