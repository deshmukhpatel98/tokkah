package com.tokkah.kin.net

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Port of mac/Sources/tk/Aec.swift — LINEAR echo subtraction, and nothing else.
 *
 * No spectral suppression: what makes calls sound underwater is guessing which
 * parts of a person's voice are echo. This subtracts what it can model and
 * leaves the rest alone, and the turn-taking floor carries what is left.
 *
 * ── WHY THE PREVIOUS ONE MEASURED MINUS TWENTY-ONE DECIBELS ─────────────────
 *
 * Its update was `g = mu * e / (xe + 1e-6)`. During near-end-only speech `xe`
 * is nearly zero, `1e-6` is not a level, and the step explodes: an NLMS driven
 * by an uncorrelated reference does not converge slowly, it random walks — and
 * it made the microphone 21 dB LOUDER. Three things make that death impossible
 * here, and all three are ported because all three are load-bearing:
 *
 *  1. THE NORMALISER HAS A REAL FLOOR, and adaptation requires the reference to
 *     be above a real level. Dividing by silence is the bug.
 *  2. A DIVERGENCE GUARD. Residual louder than the microphone for a tenth of a
 *     second zeroes the filter. -21 dB cannot be reached.
 *  3. THE SUBTRACTION IS SCALED BY WHETHER IT IS HELPING. `mix` ramps to 1 only
 *     while measured ERLE is positive, and away in 4 ms when it is not — down
 *     on a linear ramp, up on an exponential, the same asymmetry as every other
 *     gain in this app.
 *
 * Two filters: a BACKGROUND one that always adapts, and a FOREGROUND one that
 * is copied from it only when it is measurably better. A single filter that
 * adapts and subtracts at once has no way to reject its own bad step.
 */
class Aec {
    class Cfg {
        var on = true
        var taps = 1024
        /** The NLMS step. One BLOCK step made of n per-sample steps. */
        var mu = 0.10f
        var leadMs = 2.0
        var minCorr = 0.35
        /** Below this the filter neither adapts nor subtracts. */
        var refRmsFloor = 0.003f
        var leakTau = 0.0
        var helpDb = 0.5
        var divergeMs = 100.0
        var divergeFloorRms = 0.002
        var promoteMs = 200.0
        var coolMs = 400.0
        /**
         * A WORKING FILTER IS NOT RE-AIMED (0.125.0). A disagreeing delay estimate
         * is held while the filter on the audio is measurably removing this much
         * echo: three wandering readings in a row used to throw a converged filter
         * away for a delay the room had never moved to. A room that really moves
         * collapses the ERLE inside half a second and the re-aim proceeds.
         */
        var reaimHoldDb = 6.0
    }

    var cfg = Cfg()

    private val maxTaps = 4096
    private var fFg = FloatArray(maxTaps)
    private var fBg = FloatArray(maxTaps)

    /** Where in the reference the echo is, in samples, and its confidence. */
    var aimSamples = -1
    var aimCorr = 0.0

    private var delay = 0
    private var mix = 0f
    private var micE = 0.0
    private var eE = 0.0
    private var refE = 0.0
    private var cmpFgE = 0.0
    private var cmpBgE = 0.0
    private var cmpMicE = 0.0
    private var betterMs = 0.0
    private var divergeMsRun = 0.0
    private var coolMsLeft = 0.0
    private var lifeMicE = 0.0
    private var lifeOutE = 0.0

    var blocks = 0; private set
    var ranBlocks = 0; private set
    var offBlocks = 0; private set
    var updates = 0; private set
    var freezes = 0; private set
    var diverges = 0; private set
    var promotions = 0; private set
    /** Re-aims refused because the filter in use was still earning its keep. */
    var reaimsHeld = 0; private set
    var reaims = 0; private set

    /** Instantaneous echo return loss enhancement, in dB. */
    val erleDb: Double
        get() = if (micE > 1e-12 && eE > 1e-12) 10.0 * log10(micE / eE) else 0.0

    val erleLifetimeDb: Double
        get() = if (lifeMicE > 1e-12 && lifeOutE > 1e-12) 10.0 * log10(lifeMicE / lifeOutE) else 0.0

    /**
     * What survived, 0..1 — the bar the voice classifier builds from. MEASURED,
     * so a filter that stops working takes that bar straight back to where it
     * was rather than leaving a stale constant behind.
     */
    val residual: Float
        get() {
            val e = erleDb
            if (e <= 0) return 1f
            return max(0.02f, min(1f, 10.0.pow(-e / 20.0).toFloat()))
        }

    /**
     * `Aec.echoPathNow`: how much of what the speaker played is still in the
     * microphone after subtraction, as an amplitude ratio (1 = nothing removed).
     * The floor's speaker-duplex gate opens only under 0.05 (−26 dB). The Mac
     * measures this over far-only speech; here the smoothed energies include
     * near speech, which can only make the path read HIGHER — a gate that stays
     * shut when it could open, never one that opens on a lie.
     */
    val echoPathNow: Float
        get() {
            if (!cfg.on || mix <= 0.05f || refE <= 1e-12 || eE <= 1e-12) return 1f
            return min(1f, max(0.0005f, sqrt(eE / refE).toFloat()))
        }

    private fun log10(x: Double) = ln(x) / ln(10.0)
    private fun Double.pow(p: Double) = Math.pow(this, p)

    fun reset() {
        java.util.Arrays.fill(fFg, 0f)
        java.util.Arrays.fill(fBg, 0f)
        micE = 0.0; eE = 0.0; refE = 0.0; mix = 0f; divergeMsRun = 0.0
        cmpFgE = 0.0; cmpBgE = 0.0; cmpMicE = 0.0; betterMs = 0.0
    }

    /**
     * One capture block, in place.
     *
     * [ref] is the ring of what LEFT the speaker, [refW] its write head, and
     * [refCap] its capacity. The estimator that aims this filter must read the
     * RAW microphone history, never this output: a control loop reading a
     * signal its own action removed re-aims at noise (46 re-aims in 90 s, each
     * zeroing the filter).
     */
    fun process(x: FloatArray, n: Int, ref: FloatArray, refW: Int, refCap: Int) {
        blocks++
        if (!cfg.on || n <= 0) return
        val dt = n.toDouble() / Wire.SR
        val t = min(cfg.taps, maxTaps)
        coolMsLeft = max(0.0, coolMsLeft - dt * 1000)
        val lead = (cfg.leadMs / 1000 * Wire.SR).toInt()

        if (aimSamples < 0 || aimCorr < cfg.minCorr) {
            rampMix(0f, dt); offBlocks++; return
        }
        val want = max(0, aimSamples - lead)
        if (abs(want - delay) > (0.002 * Wire.SR).toInt()) {
            if (mix >= 0.5f && erleDb >= cfg.reaimHoldDb) {
                // Held: the estimator says the room moved; the audio says the
                // filter still fits. The audio is the thing being subtracted.
                reaimsHeld++
            } else {
                delay = want
                reaims++
                java.util.Arrays.fill(fFg, 0f)
                java.util.Arrays.fill(fBg, 0f)
                cmpFgE = 0.0; cmpBgE = 0.0; cmpMicE = 0.0; betterMs = 0.0
            }
        }

        val span = t - 1 + n
        val endIdx = refW - delay
        if (endIdx - span < 0) { rampMix(0f, dt); offBlocks++; return }

        // The reference window, oldest first.
        val xwin = FloatArray(span)
        val start = endIdx - span
        for (i in 0 until span) xwin[i] = ref[(((start + i) % refCap) + refCap) % refCap]

        var refSq = 0f
        for (v in xwin) refSq += v * v
        val refRms = sqrt(refSq / span)
        // Dividing by silence is the bug; refusing to is the fix, and it sits
        // upstream of any double-talk logic.
        if (refRms <= cfg.refRmsFloor) { rampMix(0f, dt); freezes++; offBlocks++; return }
        ranBlocks++

        var refAlnSq = 0f
        for (i in 0 until n) { val v = xwin[t - 1 + i]; refAlnSq += v * v }
        var micSq = 0f
        for (i in 0 until n) micSq += x[i] * x[i]

        // y[i] = sum_j f[j] * xwin[t-1+i-j]  — the filter's estimate of the echo.
        val y = FloatArray(n)
        val yBg = FloatArray(n)
        for (i in 0 until n) {
            var a = 0f
            var b = 0f
            val base = t - 1 + i
            for (j in 0 until t) {
                val s = xwin[base - j]
                a += fFg[j] * s
                b += fBg[j] * s
            }
            y[i] = a; yBg[i] = b
        }

        val e = FloatArray(n)
        val eBg = FloatArray(n)
        var eSq = 0f; var eBgSq = 0f
        for (i in 0 until n) {
            e[i] = x[i] - y[i]; eSq += e[i] * e[i]
            eBg[i] = x[i] - yBg[i]; eBgSq += eBg[i] * eBg[i]
        }

        val k = 1 - exp(-dt / 0.040)
        micE += (micSq.toDouble() / n - micE) * k
        eE += (eSq.toDouble() / n - eE) * k
        refE += (refAlnSq.toDouble() / n - refE) * k
        lifeMicE += micSq.toDouble()
        lifeOutE += eSq.toDouble()

        val kc = 1 - exp(-dt / 0.200)
        cmpFgE += (eSq.toDouble() / n - cmpFgE) * kc
        cmpBgE += (eBgSq.toDouble() / n - cmpBgE) * kc
        cmpMicE += (micSq.toDouble() / n - cmpMicE) * kc

        // ── THE DIVERGENCE GUARD ────────────────────────────────────────────
        val floorSq = cfg.divergeFloorRms * cfg.divergeFloorRms
        if (cmpMicE > floorSq && cmpFgE > cmpMicE) {
            divergeMsRun += dt * 1000
            if (divergeMsRun >= cfg.divergeMs) {
                java.util.Arrays.fill(fFg, 0f)
                java.util.Arrays.fill(fBg, 0f)
                diverges++
                divergeMsRun = 0.0
                coolMsLeft = cfg.coolMs
                mix = 0f
                cmpFgE = 0.0; cmpBgE = 0.0; cmpMicE = 0.0; betterMs = 0.0
            }
        } else divergeMsRun = 0.0

        // The background filter always adapts; the foreground is copied from it
        // only once it has been measurably better for long enough.
        val scale = cfg.mu / (n * max(refSq, span * cfg.refRmsFloor * cfg.refRmsFloor))
        if (cfg.leakTau > 0) {
            val keep = exp(-dt / cfg.leakTau).toFloat()
            for (j in 0 until t) fBg[j] *= keep
        }
        for (j in 0 until t) {
            var g = 0f
            for (i in 0 until n) g += xwin[t - 1 + i - j] * eBg[i]
            fBg[j] += scale * g
        }
        updates++

        if (cmpBgE < cmpFgE) {
            betterMs += dt * 1000
            if (betterMs >= cfg.promoteMs) {
                System.arraycopy(fBg, 0, fFg, 0, t)
                promotions++
                betterMs = 0.0
                cmpFgE = cmpBgE
            }
        } else betterMs = 0.0

        val helping = erleDb >= cfg.helpDb && coolMsLeft <= 0
        rampMix(if (helping) 1f else 0f, dt)

        // Apply what was earned, and only that.
        for (i in 0 until n) x[i] = x[i] - mix * y[i]
    }

    /** Up on an exponential, down on a 4 ms linear ramp. */
    private fun rampMix(toward: Float, dt: Double) {
        if (toward < mix) {
            val step = (dt * 1000 / 4.0).toFloat()
            mix = max(toward, mix - step)
        } else {
            mix += (toward - mix) * (1 - exp(-dt / 0.030)).toFloat()
        }
        if (abs(toward - mix) < 0.001f) mix = toward
    }

    val describe: String
        get() = "erle %.1f dB (mix %.2f, %d updates, %d diverges, %d promotions)"
            .format(erleDb, mix, updates, diverges, promotions)
}
