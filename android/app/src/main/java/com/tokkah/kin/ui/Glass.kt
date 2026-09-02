package com.tokkah.kin.ui

import android.graphics.RenderEffect
import android.graphics.Shader
import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asComposeRenderEffect
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * A pane of Liquid Glass, used as a BACKGROUND rather than as a container —
 * the same stance as `Glass.swift`.
 *
 * What makes it glass rather than a dark wash is that it REFRACTS what is
 * behind it. [GlassBackdrop] records the picture into one layer, UNBLURRED;
 * each [GlassSurface] then re-records that layer into its own layer, offset to
 * its own position, and draws it through its own blur.
 *
 * ── ONE LAYER PER PANE, AND THE REASON IS NOT TIDINESS ──────────────────────
 *
 * The first version set `renderEffect` on the SHARED backdrop from inside each
 * pane's draw. Mutating a layer invalidates it, the invalidation scheduled
 * another draw, and that draw set it again: the screen never settled, and it
 * photographed as a completely black window with the camera light on and the
 * GC running flat out. Nothing threw. So the shared layer is now read-only to a
 * pane, its blur is computed once per radius, and each pane owns the layer it
 * mutates.
 *
 * The HIG rule the Mac file states, kept here: never layer glass on glass. A
 * press is a vibrant fill INSIDE the pane, never a second pane.
 */
val LocalBackdrop = staticCompositionLocalOf<GraphicsLayer?> { null }

/**
 * ── THE SURFACES MEASURE THE PICTURE BEHIND THEM (Backdrop.swift) ───────────
 *
 * A fixed dim is right over a dark picture and wrong over a bright one: on the
 * Mac, glyphs measured 1.3:1 over a lit room until the panes started reading
 * the backdrop under themselves and dimming to reach 4.5:1. The rule is the
 * Mac's `Backdrop.dim`: over a backdrop of luminance L above 0.42, dim by
 * (L − 0.42) / (L − 0.03), never below the base dim and never above 0.72.
 *
 * The backdrop layer is read into a coarse grid a few times a second — a
 * pane then averages the cells under its own rectangle. Sampling is the only
 * cost; every draw pass reads a float.
 */
class BackdropMeter {
    val cols = 12; val rows = 20
    @Volatile var grid = FloatArray(cols * rows) { 0f }
    @Volatile var everSampled = false
    var width = 1; var height = 1

    /** Mean luminance (0..1) under a rectangle in root pixels. */
    fun luma(left: Float, top: Float, right: Float, bottom: Float): Float {
        if (!everSampled || width <= 1 || height <= 1) return 0f
        val c0 = (left / width * cols).toInt().coerceIn(0, cols - 1)
        val c1 = (right / width * cols).toInt().coerceIn(0, cols - 1)
        val r0 = (top / height * rows).toInt().coerceIn(0, rows - 1)
        val r1 = (bottom / height * rows).toInt().coerceIn(0, rows - 1)
        var sum = 0f; var n = 0
        val g = grid
        for (r in r0..r1) for (c in c0..c1) { sum += g[r * cols + c]; n++ }
        return if (n == 0) 0f else sum / n
    }

    fun sample(bmp: androidx.compose.ui.graphics.ImageBitmap) {
        val w = bmp.width; val h = bmp.height
        if (w < 2 || h < 2) return
        width = w; height = h
        val px = IntArray(w * h)
        bmp.readPixels(px)
        val next = FloatArray(cols * rows)
        val cnt = IntArray(cols * rows)
        // Every 4th pixel each way is plenty for a mean over a cell.
        var y = 0
        while (y < h) {
            var x = 0
            val row = (y * rows / h).coerceAtMost(rows - 1)
            while (x < w) {
                val p = px[y * w + x]
                val l = (0.2126f * ((p shr 16) and 255) + 0.7152f * ((p shr 8) and 255) + 0.0722f * (p and 255)) / 255f
                val i = row * cols + (x * cols / w).coerceAtMost(cols - 1)
                next[i] += l; cnt[i]++
                x += 4
            }
            y += 4
        }
        val g = grid.copyOf()
        for (i in g.indices) if (cnt[i] > 0) {
            val v = next[i] / cnt[i]
            g[i] = if (everSampled) g[i] + (v - g[i]) * 0.25f else v
        }
        grid = g
        everSampled = true
    }

    companion object {
        /** `Backdrop.dim(base:backdrop:want:)`, number for number. */
        fun dim(base: Float, l: Float, want: Float = 0.42f): Float {
            if (base <= 0f) return 0f
            if (l <= want) return base
            val need = (l - want) / maxOf(0.05f, l - 0.03f)
            return maxOf(base, minOf(0.72f, need))
        }
    }
}

val LocalBackdropMeter = staticCompositionLocalOf<BackdropMeter?> { null }

/** How much light the material adds, measured off the Mac's own card. */
private const val LIFT = 0.13f

@Composable
fun GlassBackdrop(
    modifier: Modifier = Modifier,
    backdrop: @Composable BoxScope.() -> Unit,
    content: @Composable BoxScope.() -> Unit,
) {
    val layer = rememberGraphicsLayer()
    val meter = remember { BackdropMeter() }
    // Three reads a second: enough to follow a person moving into the light,
    // cheap enough to be invisible. Off the draw pass; the read is a suspend.
    LaunchedEffect(layer) {
        while (true) {
            kotlinx.coroutines.delay(330)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                runCatching { meter.sample(layer.toImageBitmap()) }
            }
        }
    }
    Box(modifier) {
        Box(
            Modifier
                .matchParentSize()
                .drawWithContent {
                    layer.record { this@drawWithContent.drawContent() }
                    drawLayer(layer)
                },
        ) { backdrop() }
        CompositionLocalProvider(LocalBackdrop provides layer, LocalBackdropMeter provides meter) {
            Box(Modifier.matchParentSize()) { content() }
        }
    }
}

@Composable
fun GlassSurface(
    modifier: Modifier = Modifier,
    radius: Dp = Metric.cardRadius,
    tint: Color = Color.Transparent,
    blurRadius: Dp = 28.dp,
    dim: Float = Palette.dimAlpha,
    content: @Composable BoxScope.() -> Unit = {},
) {
    val backdrop = LocalBackdrop.current
    val meter = LocalBackdropMeter.current
    val shape = RoundedCornerShape(radius)
    val density = LocalDensity.current
    var origin by remember { mutableStateOf(Offset.Zero) }
    var extent by remember { mutableStateOf(Offset.Zero) }
    val canRefract = backdrop != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
    val pane = rememberGraphicsLayer()

    // Computed once per radius, and assigned OUTSIDE any draw pass.
    val effect = remember(blurRadius, density) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val px = with(density) { blurRadius.toPx() }
            RenderEffect.createBlurEffect(px, px, Shader.TileMode.CLAMP).asComposeRenderEffect()
        } else null
    }
    LaunchedEffect(effect) { if (effect != null) pane.renderEffect = effect }

    Box(
        modifier
            .onGloballyPositioned {
                origin = it.positionInRoot()
                extent = Offset(it.size.width.toFloat(), it.size.height.toFloat())
            }
            .clip(shape)
            .drawWithContent {
                if (canRefract) {
                    pane.record(size = androidx.compose.ui.unit.IntSize(
                        size.width.toInt().coerceAtLeast(1), size.height.toInt().coerceAtLeast(1))) {
                        translate(-origin.x, -origin.y) { drawLayer(backdrop!!) }
                    }
                    drawLayer(pane)
                    // ── THE MATERIAL, NOT JUST A BLUR ────────────────────────
                    //
                    // A blur alone is not glass: the Mac's pane is a HUD
                    // material AND a dim, and the material is most of the
                    // darkening. Blurring only, with dim 0.35 over it, put
                    // muted grey text on a bright green picture and the hints
                    // were unreadable. `Palette.glass` is that material at the
                    // alpha the Mac ships, so both paths — refracting and
                    // fallback — land on the same colour, and the blur shows
                    // through it as the movement that makes it glass.
                    // The dim this pane needs for the picture under it, right now.
                    val l = meter?.luma(origin.x, origin.y, origin.x + extent.x, origin.y + extent.y) ?: 0f
                    val dimNow = BackdropMeter.dim(dim, l)
                    drawRect(Palette.glass.copy(alpha = Palette.glass.alpha * dimNow / Palette.dimAlpha))
                    // ── AND THE MATERIAL ADDS LIGHT ──────────────────────────
                    //
                    // A HUD material is vibrant: it does not only darken, it
                    // lifts. Photographed against the Mac's own front door over
                    // a black window, its card is a mid grey (~#2E3137) while
                    // dark-wash-only came out nearly black — the same layout
                    // reading as a different product. The lift is what makes a
                    // pane look like a pane sitting ON something.
                    drawRect(Palette.fill(LIFT))
                } else {
                    drawRect(Palette.glass)
                    drawRect(Palette.fill(LIFT))
                }
                if (tint != Color.Transparent) drawRect(tint)
                // The specular top edge that makes a pane read as a pane.
                drawRect(
                    Brush.verticalGradient(
                        0f to Palette.fill(0.10f),
                        0.35f to Palette.fill(0.03f),
                        1f to Color.Transparent,
                    ),
                )
                drawContent()
            }
            .border(1.dp, Palette.glassLine, shape),
        content = content,
    )
}
