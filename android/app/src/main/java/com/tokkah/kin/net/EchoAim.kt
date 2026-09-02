package com.tokkah.kin.net

import kotlin.math.abs
import kotlin.math.sqrt

/**
 * Port of `Audio.echoEstimator` + `Audio.corrScan` (Audio.swift 2130-2330):
 * WHERE in the loudspeaker's past the microphone's present is.
 *
 * The canceller cannot aim itself. It needs a delay to start from, and the
 * Mac finds it by correlating 400 ms of the RAW microphone (decimated to 6 kHz)
 * against the last 600 ms of what left the speaker, every half second, and
 * handing the best lag to `Aec.aim`. On the phone this class did not exist:
 * `aimSamples` stayed at -1, the canceller's first guard returned on every
 * block, and `aec_off_pct` read 100 on every live call. A canceller that is
 * never aimed is a canceller that is off, and the beat is what said so.
 *
 * Reads the RAW microphone history, never the cancelled output: an estimator
 * fed the signal its own filter removed re-aims at noise.
 *
 * The scan runs on its own thread; the audio thread only appends.
 */
class EchoAim(private val aec: Aec) {
    private companion object {
        const val D = 8                          // decimation → 6 kHz
        const val CAPH = 131072                  // 2.7 s of raw capture
        const val ECHO_MAX = 48000               // 1 s of what the speaker played
        const val WIN = 19200 / D                // 400 ms of evidence
        const val MAX_LAG = (0.200 * Wire.SR).toInt() / D   // search out to 200 ms
    }

    private val cap = FloatArray(CAPH)
    @Volatile private var capW = 0L
    private val echo = FloatArray(ECHO_MAX)
    @Volatile private var echoW = 0L

    /** The best correlation this tick, and the peak over the call. */
    @Volatile var echoCorr = 0.0; private set
    @Volatile var echoCorrPeak = 0.0; private set
    @Volatile var echoDelayMs = -1.0; private set
    @Volatile var skips = 0; private set
    @Volatile var scans = 0; private set

    /** The raw microphone, before the canceller touches it. Audio thread. */
    fun noteCapture(x: FloatArray, n: Int) {
        var w = capW
        for (i in 0 until n) { cap[(w % CAPH).toInt()] = x[i]; w++ }
        capW = w
    }

    /** What the speaker is being fed. Render thread. */
    fun noteEmit(v: Float) {
        val w = echoW
        echo[(w % ECHO_MAX).toInt()] = v
        echoW = w + 1
    }

    fun noteEmit(x: FloatArray, n: Int) {
        var w = echoW
        for (i in 0 until n) { echo[(w % ECHO_MAX).toInt()] = x[i]; w++ }
        echoW = w
    }

    private val mic = FloatArray(WIN)
    private val spk = FloatArray(WIN + MAX_LAG)

    /** One estimate. Called every 500 ms from a thread of its own. */
    fun tick() {
        val cw = capW; val ew = echoW
        if (cw <= WIN * D + 2000 || ew <= (WIN + MAX_LAG) * D + 2000) { skips++; return }
        for (i in 0 until WIN) {
            var a = 0f
            val base = cw - (WIN - i).toLong() * D
            for (j in 0 until D) a += cap[((base + j) % CAPH).toInt()]
            mic[i] = a / D
        }
        for (i in 0 until WIN + MAX_LAG) {
            var a = 0f
            val base = ew - (WIN + MAX_LAG - i).toLong() * D
            for (j in 0 until D) a += echo[((base + j) % ECHO_MAX).toInt()]
            spk[i] = a / D
        }
        var micE = 0f
        for (v in mic) micE += v * v
        if (micE <= 1e-6f) { skips++; return }      // a silent mic has no echo to find
        val (best, score) = corrScan(mic, spk, WIN, MAX_LAG, micE, minOff = 1)
        if (best < 0) { skips++; return }
        scans++
        echoCorr = score.toDouble()
        if (echoCorr > echoCorrPeak) echoCorrPeak = echoCorr
        echoDelayMs = ((MAX_LAG - best) * D).toDouble() / Wire.SR * 1000.0
        aec.aim((echoDelayMs / 1000.0 * Wire.SR).toInt(), echoCorr)
    }

    /**
     * `Audio.corrScanSlow`, exactly: normalised cross-correlation of [fix]
     * against every offset of [slide], returning the best offset and its score.
     * The Mac's fast arm is vDSP; the arithmetic is this.
     */
    fun corrScan(fix: FloatArray, slide: FloatArray, win: Int, maxOff: Int, fixE: Float, minOff: Int = 0): Pair<Int, Float> {
        var best = -1; var bestScore = 0f
        // Prefix sums of slide², so each offset's energy is O(1).
        val pre = DoubleArray(slide.size + 1)
        for (i in slide.indices) pre[i + 1] = pre[i] + slide[i].toDouble() * slide[i]
        for (off in maxOf(0, minOff)..maxOff) {
            var num = 0f
            for (i in 0 until win) num += fix[i] * slide[i + off]
            val den = pre[off + win] - pre[off]
            if (den <= 1e-9) continue
            val r = (abs(num.toDouble()) / sqrt(den * fixE)).toFloat()
            if (r > bestScore) { bestScore = r; best = off }
        }
        return best to bestScore
    }
}
