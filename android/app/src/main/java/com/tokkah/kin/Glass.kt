package com.tokkah.kin

import androidx.compose.ui.graphics.Color

// The design tokens, transcribed from mac/Sources/tk/Glass.swift:287-362.
// Copy the layout, not the tokens: these are the shipped values, not new ones.
object Glass {
    val fg = Color(0xFFE8EAED)
    val accent = Color(0xFF60A5FA)
    val ok = Color(0xFF4ADE80)
    val warn = Color(0xFFFBBF24)
    val bad = Color(0xFFEF4444)
    val bg = Color(0xFF06080D)
    val glass = Color(0xB80A0E16)
    val glassLine = Color(0x24FFFFFF)
    val destructive = Color(0xFFF24B4B)
    val opaqueSurface = Color(0xFF12151C)
    fun fill(alpha: Float) = Color(1f, 1f, 1f, alpha)

    /// Same construction as Glass.avatarHue: a handle always gets its own colour.
    fun avatarHue(handle: String): Float {
        var h = 0
        for (c in handle) h = (h * 31 + c.code) and 0xffffff
        return (h % 360).toFloat()
    }
}
