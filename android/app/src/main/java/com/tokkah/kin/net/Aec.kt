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
        /** The NLMS step, PER MAC BLOCK — see [muBlock]. */
        var mu = 0.10f
        /**
         * ── PER-BLOCK CONSTANTS HIDE BLOCK SIZE ─────────────────────────────
         *
         * The Mac runs this filter once per HAL callback of 16 frames: 3000
         * updates a second at `mu`. A phone's capture burst is 160–480 frames,
         * so the SAME `mu` adapted 10–30× slower here — measured in the drift
         * rig, a white-noise echo reached 1.7 dB in 30 s at a 480 block and
         * 10 dB at 192 — and the port's "slower convergence" was nothing but
         * the block size wearing the Mac's coefficient. The step is scaled by
         * n / muBlock so a second of adaptation is a second, capped at 1.0 for
         * stability (the window this normalises by is ~1.5 taps' worth at 480).
         */
        var muBlock = 16f
        var muStepMax = 1.0f
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

        // ── THE CANCELLER TRACKS THE CLOCKS (0.109.0; 0.125.0 gate) ─────────
        //
        // Capture and render are two crystals; the echo's delay drifts (30 ppm
        // is 1.44 samples/s), and a filter aimed at a fixed integer delay
        // converges and loses its target over and over. The reference window
        // is read at a FRACTIONAL delay advancing at the measured skew; whole
        // samples carry into the integer delay WITHOUT shifting the taps
        // (delay+1 / frac−1 is the identical window — shifting was the bug that
        // hid the whole win, see `aec-limited-by-clock-drift`).
        //
        // The sensor is the estimator's readings regressed over signal time:
        // ground truth outside the loop, which cannot oscillate. Fits are
        // believed only under `skewMaxSe` of error and a physically possible
        // slope; a wandering estimator is not a drifting clock.
        var driftTrack = true
        var skewMinReads = 8
        var skewMinSpanS = 6f
        var skewGain = 0.6f
        var skewMin = 0.15f
        var dllSkewMax = 6f
        var skewMaxSe = 1.0f
        var dllResetMs = 2000.0
    }

    var cfg = Cfg()

    private val maxTaps = 4096
    private var fFg = FloatArray(maxTaps)
    private var fBg = FloatArray(maxTaps)

    /** Where in the reference the echo is, in samples, and its confidence. */
    var aimSamples = -1
    var aimCorr = 0.0

    private var delay = 0
    /** The fractional part of the delay, 0 ≤ frac < 1, advanced by the skew. */
    private var frac = 0f
    var skewSps = 0f; private set
    private var sigSec = 0f
    private val aimT = FloatArray(64)
    private val aimD = FloatArray(64)
    private var aimN = 0
    private var notHelpingMs = 0.0
    var dllSteps = 0; private set
    var dllResets = 0; private set
    var skewRejects = 0; private set
    var carries = 0; private set
    /** For rigs: where the window is read from right now. */
    val delayNow: Int get() = delay
    val fracNow: Float get() = frac
    private var rawWin = FloatArray(0)
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
    private var holdingReaim = false
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

    /**
     * The estimator's reading: where in the reference the echo is, and how
     * sure. Records the reading against signal time and, with eight readings
     * over six seconds, fits a line: the slope is the clock skew in samples per
     * second. `Aec.aim` in Aec.swift, number for number.
     */
    fun aim(delaySamples: Int, corr: Double) {
        aimSamples = delaySamples
        aimCorr = corr
        if (!cfg.driftTrack || corr < cfg.minCorr) return
        val t = sigSec
        if (aimN > 0 && t - aimT[aimN - 1] < 0.25f) return
        if (aimN == aimT.size) {
            for (i in 1 until aimN) { aimT[i - 1] = aimT[i]; aimD[i - 1] = aimD[i] }
            aimN--
        }
        aimT[aimN] = t; aimD[aimN] = delaySamples.toFloat(); aimN++
        if (aimN < cfg.skewMinReads || aimT[aimN - 1] - aimT[0] < cfg.skewMinSpanS) return
        var st = 0f; var sd = 0f
        for (i in 0 until aimN) { st += aimT[i]; sd += aimD[i] }
        val mt = st / aimN; val md = sd / aimN
        var stt = 0f; var std = 0f
        for (i in 0 until aimN) { stt += (aimT[i] - mt) * (aimT[i] - mt); std += (aimT[i] - mt) * (aimD[i] - md) }
        if (stt <= 1e-3f) return
        val slope = std / stt
        var rss = 0f
        for (i in 0 until aimN) { val r = aimD[i] - md - slope * (aimT[i] - mt); rss += r * r }
        val se = if (aimN > 2) sqrt(rss / (aimN - 2) / stt) else 1e9f
        if (se > cfg.skewMaxSe || abs(slope) > cfg.dllSkewMax * 1.5f) {
            // A fit with 17 samples of error, or −40 sps: no crystal pair does
            // that. Refused, counted.
            skewRejects++
        } else if (abs(slope) > max(cfg.skewMin, 1.5f * se) || (slope == 0f && se < cfg.skewMin)) {
            val target = max(-cfg.dllSkewMax, min(cfg.dllSkewMax, slope))
            skewSps += (target - skewSps) * cfg.skewGain
            dllSteps++
        } else if (abs(slope) < cfg.skewMin && se < cfg.skewMin && skewSps != 0f) {
            skewSps += (0 - skewSps) * cfg.skewGain
        }
    }

    fun reset() {
        skewSps = 0f; frac = 0f; aimN = 0; notHelpingMs = 0.0
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
        if (abs(want - delay) <= (0.002 * Wire.SR).toInt()) holdingReaim = false
        if (abs(want - delay) > (0.002 * Wire.SR).toInt()) {
            if (mix >= 0.5f && erleDb >= cfg.reaimHoldDb) {
                // Held: the estimator says the room moved; the audio says the
                // filter still fits. The audio is the thing being subtracted.
                // Counted once per disagreement, not once per block.
                if (!holdingReaim) { holdingReaim = true; reaimsHeld++ }
            } else {
                delay = want
                frac = 0f
                holdingReaim = false
                reaims++
                java.util.Arrays.fill(fFg, 0f)
                java.util.Arrays.fill(fBg, 0f)
                cmpFgE = 0.0; cmpBgE = 0.0; cmpMicE = 0.0; betterMs = 0.0
            }
        }

        val track = cfg.driftTrack
        val span = t - 1 + n
        val endIdx = refW - delay
        if (endIdx - span - (if (track) 2 else 0) < 0 || (track && delay < 1)) { rampMix(0f, dt); offBlocks++; return }

        // The reference window, oldest first — read at a FRACTIONAL delay when
        // tracking: four raw neighbours per output sample through a cubic
        // Lagrange kernel whose phase is `frac` (`buildWindow`, Aec.swift 1318).
        val xwin = FloatArray(span)
        val start = endIdx - span
        if (track) {
            val r = span + 3
            if (rawWin.size < r) rawWin = FloatArray(r)
            for (i in 0 until r) rawWin[i] = ref[(((start - 2 + i) % refCap) + refCap) % refCap]
            val tt = 1 - frac
            if (tt >= 0.9999f) {
                System.arraycopy(rawWin, 2, xwin, 0, span)
            } else {
                val c0 = -tt * (tt - 1) * (tt - 2) / 6
                val c1 = (tt + 1) * (tt - 1) * (tt - 2) / 2
                val c2 = -tt * (tt + 1) * (tt - 2) / 2
                val c3 = tt * (tt + 1) * (tt - 1) / 6
                for (i in 0 until span) {
                    xwin[i] = c0 * rawWin[i] + c1 * rawWin[i + 1] + c2 * rawWin[i + 2] + c3 * rawWin[i + 3]
                }
            }
        } else {
            for (i in 0 until span) xwin[i] = ref[(((start + i) % refCap) + refCap) % refCap]
        }

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
        val step = min(cfg.muStepMax, cfg.mu * n / cfg.muBlock)
        val scale = step / (n * max(refSq, span * cfg.refRmsFloor * cfg.refRmsFloor))
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

        if (track) {
            sigSec += dt.toFloat()
            frac += skewSps * dt.toFloat()
            // A carry is the SAME window written differently: the taps stay.
            while (frac >= 1f) { frac -= 1f; delay += 1; carries++ }
            while (frac < 0f) { frac += 1f; delay -= 1; carries++ }
        }

        val helping = erleDb >= cfg.helpDb && coolMsLeft <= 0
        rampMix(if (helping) 1f else 0f, dt)
        if (track) {
            // Two seconds of not helping: the skew being applied is not the
            // room's. Drop it and let the fit start over.
            notHelpingMs = if (mix < 0.05f) notHelpingMs + dt * 1000 else 0.0
            if (notHelpingMs >= cfg.dllResetMs && (skewSps != 0f || frac != 0f)) {
                skewSps = 0f; frac = 0f; aimN = 0; notHelpingMs = 0.0
                dllResets++
            }
        }

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
        get() = "erle %.1f dB (mix %.2f, %d updates, %d diverges, %d promotions, skew %.2f sps, %d carries)"
            .format(erleDb, mix, updates, diverges, promotions, skewSps, carries)
}
