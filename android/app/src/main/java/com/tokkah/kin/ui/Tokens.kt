package com.tokkah.kin.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// Transcribed from mac/Sources/tk/Glass.swift (Metric, Type_, Palette) at
// 0.113.0. Copy the layout, not the tokens: these ARE the shipped numbers.
// macOS points and Android dp are both 1/163"-ish logical units, so the
// geometry carries over directly; only the touch minimums below are added.
object Metric {
    val s1 = 4.dp
    val s2 = 8.dp
    val s3 = 12.dp
    val s4 = 16.dp
    val s5 = 20.dp
    val s6 = 24.dp
    val s8 = 32.dp

    /** The control bar's buttons. 58 already clears the 48dp touch minimum. */
    val control = 58.dp
    val controlSmall = 48.dp
    val controlGap = 18.dp
    val barInset = 24.dp
    val gutter = 20.dp
    val topInset = 36.dp

    val sheetRadius = 26.dp
    val sheetPad = 10.dp
    val sheetRow = 48.dp
    val sheetHint = 34.dp
    val sheetWidth = 420.dp
    val rowGlyphInset = 42.dp
    val rowAvatarInset = 56.dp

    val avatar = 34.dp
    val avatarRing = 1.5.dp
    val faceBig = 64.dp
    val faceBigRing = 2.dp

    val cardRadius = 30.dp
    val cardPad = 22.dp
    val captionRadius = 22.dp
    val pillHeight = 30.dp
    val fieldHeight = 36.dp
    val windowRadius = 32.dp

    /** Glass.Metric.concentric: an inner corner inside an outer one. */
    fun concentric(outer: androidx.compose.ui.unit.Dp, inset: androidx.compose.ui.unit.Dp) =
        (outer - inset).coerceAtLeast(0.dp)

    fun capsule(height: androidx.compose.ui.unit.Dp) = height / 2
}

object Palette {
    val fg = Color(0xFFE8EAED)
    val muted = Color(0xFF9AA4B2)
    val accent = Color(0xFF60A5FA)
    val ok = Color(0xFF4ADE80)
    val warn = Color(0xFFFBBF24)
    val bad = Color(0xFFEF4444)
    val bg = Color(0xFF06080D)

    /** The material's fallback, and the right answer wherever glass cannot be. */
    val glass = Color(red = 10 / 255f, green = 14 / 255f, blue = 22 / 255f, alpha = 0.72f)
    val glassLine = Color(1f, 1f, 1f, 0.14f)

    /** A tint BLENDS toward a colour; the fill behind it does the rest. */
    val destructiveTint = Color(red = 0xF2 / 255f, green = 0x4B / 255f, blue = 0x4B / 255f, alpha = 0.35f)

    /** The HIG's dimming number, in one place. */
    const val dimAlpha = 0.35f
    val dimInk = Color(red = 6 / 255f, green = 8 / 255f, blue = 13 / 255f, alpha = 1f)
    val opaqueSurface = Color(red = 18 / 255f, green = 21 / 255f, blue = 28 / 255f, alpha = 1f)

    /** A press inside glass: a vibrant fill, never a second pane of glass. */
    fun fill(alpha: Float) = Color(1f, 1f, 1f, alpha)

    /**
     * FNV-1a over the HANDLE, 22 buckets of 15 degrees, steps 0 and 23 dropped.
     * Not the platform hash: that is seeded per process, so the same person
     * would be a different colour on every launch and stable within a session —
     * green here, wrong only in the field.
     */
    fun avatarHue(handle: String): Float {
        var h = 2166136261u
        for (b in handle.lowercase().toByteArray()) h = (h xor b.toUInt().and(0xFFu)) * 16777619u
        return (((h % 22u) + 1u) * 15u).toFloat()
    }

    /** The hue lands on the RING and the letter, never on a filled disc. */
    fun avatarInk(handle: String): Color = Color.hsv(avatarHue(handle), 0.55f, 0.98f)
}

object Type {
    val status = 12.sp to FontWeight.Medium
    val row = 13.sp to FontWeight.Normal
    val title = 17.sp to FontWeight.SemiBold
    val caption = 11.sp to FontWeight.Normal
    val button = 12.sp to FontWeight.Medium
    val mono = 12.sp to FontWeight.Medium
    val code = 13.sp to FontWeight.SemiBold
    val field = 14.sp to FontWeight.Normal
    val buttonProminent = 12.sp to FontWeight.SemiBold
    val confirm = 13.sp to FontWeight.SemiBold
    val avatar = 15.sp to FontWeight.SemiBold
    val avatarBig = 28.sp to FontWeight.SemiBold
    val name = 22.sp to FontWeight.SemiBold
    val said = 16.sp to FontWeight.Medium
    val bloom = 30.sp to FontWeight.SemiBold
}
