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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp

/**
 * The front door, laid out from Launcher.swift `home()` (0.125.0).
 *
 * Your own camera fills the window; ONE pane of glass floats at the bottom,
 * inset by `gutter`, and everything that is not the picture lives on it. Rows
 * are walked top-down in one list, so adding one is a line and cannot leave a
 * gap where a hidden view used to be. The order is the Mac's, and the ordering
 * is the whole design: a call you are still in, a link somebody just sent you,
 * the people, the one field, and last the link you hand OUT — reaching somebody
 * you have talked to before is the common case, inviting a stranger the rare one.
 */
class Person(
    val handle: String,
    val online: Boolean = false,
    val lastSeen: String? = null,
    /** Their picture, from a call you were in. Null until one has provided it. */
    val face: java.io.File? = null,
)

/** Everything the card shows, in one value, so a state cannot be half-drawn. */
class HomeCard(
    val people: List<Person>,
    val myHandle: String,
    /** Why this phone has no name, when it has none. */
    val nameTrouble: String,
    val resumeLabel: String?,
    val updateVersion: String?,
    val clipRoom: String?,
    val inviteLabel: String,
    val inviteValue: String,
    val mineValue: String,
    /** The field's last verdict that was a sentence, in the warn colour. */
    val status: String,
    val settingsOpen: Boolean,
    /** null = busy ("…"). */
    val reachOn: Boolean?,
    val reachHint: String,
)

@Composable
fun HomeScreen(
    room: String,
    onRoom: (String) -> Unit,
    card: HomeCard,
    cameraHint: String?,
    onUpdate: () -> Unit,
    onSettings: () -> Unit,
    onJoin: () -> Unit,
    onCall: (String) -> Unit,
    onResume: () -> Unit,
    onJoinClip: () -> Unit,
    onInvite: () -> Unit,
    onCopyMine: () -> Unit,
    onReach: () -> Unit,
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
                tint = if (card.settingsOpen) Palette.fill(0.14f) else androidx.compose.ui.graphics.Color.Transparent,
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
                        if (card.settingsOpen) {
                            // The card about YOU: your name and the one switch.
                            MineRows(card, onCopyMine, ruled = false)
                            KinRow(
                                "People can call me",
                                detail = if (card.reachOn == null) "…" else null,
                                switchState = card.reachOn,
                                labelInset = Metric.rowAvatarInset,
                                inert = card.reachOn == null,
                                onClick = onReach,
                            )
                            KinHint(card.reachHint)
                        } else {
                            // A call you are still in comes first: it is the only
                            // row on this card about something already happening.
                            card.resumeLabel?.let {
                                KinRow("Rejoin $it", detail = "still going",
                                    labelInset = Metric.rowAvatarInset, onClick = onResume)
                            }
                            // Checked and downloaded already; this row is the
                            // person's one tap, and it only appears off a call.
                            card.updateVersion?.let {
                                KinRow("Update Kin", detail = it, valueIsAction = true,
                                    labelInset = Metric.rowAvatarInset, onClick = onUpdate)
                            }
                            // A link on the clipboard is a knock on the door.
                            card.clipRoom?.let {
                                KinRow("Join $it", detail = "from your copied link",
                                    labelInset = Metric.rowAvatarInset, onClick = onJoinClip)
                            }
                            if (card.people.isEmpty()) {
                                KinHint("Talk to someone once and they’ll show up here.")
                            }
                            for (p in card.people) {
                                KinRow(
                                    "@" + p.handle,
                                    detail = p.lastSeen,
                                    leading = { Avatar(p.handle, online = p.online, face = faceOf(p)) },
                                    onClick = { onCall(p.handle) },
                                )
                            }
                            RoomField(room, onRoom, onJoin)
                            // The status line: 14 high, caption, warn. Only ever
                            // a refusal, and gone the moment the field commits.
                            Text(
                                card.status, color = Palette.warn,
                                fontSize = Type.caption.first, fontWeight = Type.caption.second,
                                maxLines = 1,
                                modifier = Modifier.fillMaxWidth().height(14.dp).padding(start = Metric.s3),
                            )
                            KinRow(card.inviteLabel, detail = card.inviteValue,
                                valueIsAction = card.inviteValue == "copy",
                                labelInset = Metric.rowAvatarInset, onClick = onInvite)
                            // A brand-new install has nobody to call until
                            // somebody knows this phone's name — so the name
                            // stays on the front card exactly until the first
                            // person is in the list, then moves behind the `…`.
                            if (card.people.isEmpty()) MineRows(card, onCopyMine, ruled = true)
                        }
                    }
                }
            }
        }
    }
}

/**
 * Your own name, and the one state that gets a sentence instead of a control:
 * a copy button over an empty value copies nothing, reports success, and
 * teaches the person the feature is broken.
 */
@Composable
private fun MineRows(card: HomeCard, onCopyMine: () -> Unit, ruled: Boolean) {
    if (card.myHandle.isEmpty()) {
        KinHint(card.nameTrouble)
    } else {
        KinRow("@" + card.myHandle, detail = card.mineValue, valueIsAction = true,
            leading = { Avatar(card.myHandle) }, ruled = ruled, onClick = onCopyMine)
    }
}

/** A face decoded once per file, not once per recomposition. */
@Composable
private fun faceOf(p: Person): androidx.compose.ui.graphics.ImageBitmap? {
    val f = p.face ?: return null
    return androidx.compose.runtime.remember(f.path, f.lastModified()) {
        runCatching {
            android.graphics.BitmapFactory.decodeFile(f.path)?.asImageBitmap()
        }.getOrNull()
    }
}

/** The one editable thing. Return is the commit; the placeholder is the label. */
@Composable
private fun RoomField(room: String, onRoom: (String) -> Unit, onJoin: () -> Unit) {
    // A FILL, not a second pane. "Avoid overcrowding or layering Liquid Glass
    // elements on top of each other" — and it is not only a rule: a pane inside
    // a pane re-blurred the card's own blur and photographed as dark blobs
    // smeared across the field.
    val shape = RoundedCornerShape(Metric.cardFieldRadius)
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
