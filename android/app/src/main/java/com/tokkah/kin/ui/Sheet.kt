package com.tokkah.kin.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/**
 * The `…` sheet, from `Sheet` in Controls.swift (1689-1904): one pane of glass,
 * `sheetRadius` corners, `sheetPad` inside, `sheetWidth` wide or the window
 * less two gutters, hung from just under the `…` button at the top right. A
 * scrim over everything else closes it — the most-used way out, and named for
 * a screen reader ("Close settings"), which the Mac had once forgotten.
 *
 * Its contents are a LIST: rows, hints and at most one field, walked top-down,
 * the way every card in this app is built. Pages (settings, people, rename,
 * camera, speaker) are different lists, not different components.
 */
sealed class SheetItem {
    class Row(
        val label: String,
        val detail: String? = null,
        /**
         * The Mac indents ONLY the People page's glyph-less rows to the avatar
         * column so "Call someone new" lines up with the names above it
         * (Controls.swift 5446). Every other row starts at the sheet's s3.
         */
        val indent: Boolean = false,
        val valueIsWord: Boolean = true,
        val valueIsAction: Boolean = false,
        val switchState: Boolean? = null,
        val chevron: Boolean = false,
        val glyph: GlyphKind? = null,
        val avatar: String? = null,
        val checked: Boolean = false,
        val inert: Boolean = false,
        val ruled: Boolean = false,
        val onClick: (() -> Unit)? = null,
    ) : SheetItem()
    class Hint(val text: String) : SheetItem()
    /** `SheetField`: pre-filled and SELECTED, so the first thing typed replaces. */
    class Field(
        val placeholder: String,
        val text: String,
        val onChange: (String) -> Unit,
        val onCommit: () -> Unit,
    ) : SheetItem()
}

@Composable
fun KinSheet(
    items: List<SheetItem>,
    onClose: () -> Unit,
    /** Where the `…` button's bottom edge is: the sheet hangs `s2` under it. */
    topInset: Dp,
) {
    Box(Modifier.fillMaxSize()) {
        // The scrim. Transparent, and every touch on it closes the sheet.
        Box(
            Modifier.fillMaxSize().clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null, onClick = onClose,
            ).semantics {
                contentDescription = "Close settings"
                role = Role.Button
            },
        )
        androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize().statusBarsPadding()) {
            val w = minOf(maxWidth - Metric.gutter * 2, Metric.sheetWidth)
            val room = maxHeight - topInset - Metric.s2 - Metric.s3 - Metric.barInset - Metric.control
            GlassSurface(
                Modifier
                    .align(Alignment.TopEnd)
                    .padding(top = topInset + Metric.s2, end = Metric.gutter)
                    .width(w),
                radius = Metric.sheetRadius,
                blurRadius = 26.dp,
            ) {
                Column(
                    Modifier
                        .heightIn(max = room.coerceAtLeast(Metric.sheetRow * 2))
                        .verticalScroll(rememberScrollState())
                        .padding(Metric.sheetPad),
                ) {
                    for (it in items) when (it) {
                        is SheetItem.Row -> SheetRowView(it)
                        is SheetItem.Hint -> KinHint(it.text)
                        is SheetItem.Field -> SheetFieldView(it)
                    }
                }
            }
        }
    }
}


@Composable
private fun SheetRowView(r: SheetItem.Row) {
    KinRow(
        r.label,
        detail = r.detail,
        valueIsWord = r.valueIsWord,
        valueIsAction = r.valueIsAction,
        switchState = r.switchState,
        chevron = r.chevron,
        glyph = r.glyph,
        leading = r.avatar?.let { h -> { Avatar(h) } },
        labelInset = if (r.indent && r.glyph == null && r.avatar == null) Metric.rowAvatarInset else Metric.s3,
        tone = if (r.checked) Palette.fg else Palette.rowInk,
        ruled = r.ruled,
        inert = r.inert,
        onClick = r.onClick,
        trailingTick = r.checked,
    )
}

/** The well the rename field sits in: `Vibrant`, `cardFieldRadius`, `sheetRow` tall. */
@Composable
private fun SheetFieldView(f: SheetItem.Field) {
    val shape = RoundedCornerShape(Metric.cardFieldRadius)
    val focus = remember { FocusRequester() }
    // The old name is SELECTED, not sitting there waiting: somebody who came
    // here to become `meera` must not get `deveshmeera`.
    var value by remember { androidx.compose.runtime.mutableStateOf(TextFieldValue(f.text, TextRange(0, f.text.length))) }
    LaunchedEffect(Unit) { focus.requestFocus() }
    Box(
        Modifier
            .fillMaxWidth()
            .height(Metric.sheetRow)
            .padding(vertical = Metric.s1)
            .clip(shape)
            .background(Palette.fill(0.10f), shape)
            .border(1.dp, Palette.glassLine, shape),
    ) {
        Box(Modifier.fillMaxSize().padding(horizontal = Metric.s4), contentAlignment = Alignment.CenterStart) {
            BasicTextField(
                value = value,
                onValueChange = { value = it; f.onChange(it.text) },
                singleLine = true,
                textStyle = TextStyle(color = Palette.fg, fontSize = Type.field.first, fontWeight = Type.field.second),
                cursorBrush = SolidColor(Palette.accent),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { f.onCommit() }),
                modifier = Modifier.fillMaxWidth().focusRequester(focus),
                decorationBox = { inner ->
                    if (value.text.isEmpty()) {
                        Text(f.placeholder, color = Palette.muted,
                            fontSize = Type.field.first, fontWeight = Type.field.second)
                    }
                    inner()
                },
            )
        }
    }
}
