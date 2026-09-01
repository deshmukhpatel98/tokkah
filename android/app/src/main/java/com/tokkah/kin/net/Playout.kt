package com.tokkah.kin.net

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

// Port of the render half of mac/Sources/tk/Audio.swift (onRender, 4415-4860):
// the fractional read cursor, its governor, the snap tiers, and pitch-period
// concealment. Device-independent — the platform layer hands it a block to fill.
class Playout(val ring: RecvRing) {
    companion object {
        const val HIST = 1 shl 15
        const val HMASK = HIST - 1
        const val PMIN = 96          // 500 Hz
        const val PMAX = 600         // 80 Hz
        const val XFADE = 64         // 1.3 ms
        const val SNAP_PKTS = 45L    // 30 ms behind before skipping stale audio
        const val EAR_STEP = 1.0f / (48000f * 4f / 1000f)   // the 4 ms linear close
    }

    var jitTarget = 2
    var earOpen = true
    var mute = false

    /**
     * Callback size in frames, set by the device layer.
     *
     * ── THE BUFFER FLOOR IS A PROPERTY OF THE DEVICE, NOT A CONSTANT ─────────
     *
     * The Mac renders FPP frames per callback, so its jitter target of 2
     * packets is one device block plus one of margin. Android's fast path never
     * delivers 0.667 ms callbacks — a 192-frame burst consumes SIX packets in
     * one go — so a target of 2 is starving by construction: measured against
     * the shipped Mac app, 36191 packets accepted and 15871 samples concealed
     * as starved, with 19961 arrivals booked late because the cursor had
     * already run past their slot. Nothing was wrong with the path.
     *
     * So the floor is expressed in DEVICE BLOCKS, which is what it always
     * meant: one whole block, plus two packets of jitter margin.
     */
    var devBuf = 192
        set(v) {
            field = v
            jitTarget = max(jitTarget, v / Wire.FPP + 2)
        }

    private val hist = FloatArray(HIST)
    private var histW = 0
    private var plcPeriod = 0
    private var plcCursor = 0
    private var plcSamples = 0
    private var wasConcealing = false
    private var xfade = 0
    private var earGain = 1f
    private var aheadRun = 0
    private var concealRun = 0
    private var goodRun = 0
    private var lastGood = FloatArray(Wire.FPP)
    private var haveLastGood = false

    var playoutSumSq = 0.0; private set
    var playoutN = 0; private set
    var concealMaxRun = 0; private set
    var renderTicks = 0L; private set

    /** True while a sample left the speaker in this block — the fact Floor needs. */
    var playoutLive = false; private set

    /** The pitch period of what was just playing, coarse-to-fine autocorrelation. */
    private fun findPeriod(): Int {
        val w = 480                                  // 10 ms of evidence
        var e0 = 0f
        var i = 0
        while (i < w) { val v = hist[(histW - 1 - i) and HMASK]; e0 += v * v; i += 4 }
        if (e0 < 1e-6f) return 0

        var best = 0
        var bestScore = 0f
        var lag = PMIN
        while (lag <= PMAX) {
            var num = 0f; var den = 0f
            var k = 0
            while (k < w) {
                val a = hist[(histW - 1 - k) and HMASK]
                val b = hist[(histW - 1 - k - lag) and HMASK]
                num += a * b; den += b * b
                k += 4
            }
            if (den >= 1e-9f) {
                val score = num / sqrt(den)
                if (score > bestScore) { bestScore = score; best = lag }
            }
            lag += 2
        }
        if (best == 0) return 0

        // A period wrong by one sample is exactly the click this removes.
        var fine = best
        var fineScore = 0f
        for (l in max(PMIN, best - 3)..min(PMAX, best + 3)) {
            var num = 0f; var den = 0f
            for (k in 0 until w) {
                val a = hist[(histW - 1 - k) and HMASK]
                val b = hist[(histW - 1 - k - l) and HMASK]
                num += a * b; den += b * b
            }
            if (den < 1e-9f) continue
            val score = num / sqrt(den)
            if (score > fineScore) { fineScore = score; fine = l }
        }
        return fine
    }

    /** One concealed sample: forward through history, wrapping by one period. */
    private fun plcNext(): Float {
        if (plcPeriod <= 0) return 0f
        val v = hist[plcCursor and HMASK]
        plcCursor++
        if (plcCursor >= histW) plcCursor -= plcPeriod
        plcSamples++
        // Hold the level for 10 ms, then fade over 40 ms: a voice that stops dead
        // is a click; one that hangs on forever is a robot.
        val ms = plcSamples.toDouble() / Wire.SR * 1000.0
        val g = if (ms <= 10) 1f else max(0.0, 1.0 - (ms - 10) / 40.0).toFloat()
        return v * g
    }

    /**
     * Fill [out] with [n] frames. Returns true when real audio (not silence
     * before the stream starts) was produced. [gate] receives every played
     * sample for the far-end envelope.
     */
    fun render(out: FloatArray, n: Int, gate: DuplexGate?) {
        renderTicks++
        playoutLive = false
        val hi = ring.hiSeq.toLong()
        if (hi < 0) { java.util.Arrays.fill(out, 0, n, 0f); return }
        if (ring.pos < 0) {
            if (hi < jitTarget) { java.util.Arrays.fill(out, 0, n, 0f); return }
            ring.pos = ((hi - jitTarget) * Wire.FPP).toDouble()
        }
        var cur = ring.pos.toLong() / Wire.FPP
        // A jump is for a broken stream, not a drift: the stream outran the ring,
        // or the cursor is hundreds of packets past the head (a peer restart).
        if (hi - cur > (Wire.RING - 2).toLong() || cur > hi + (Wire.RING / 4).toLong()) {
            ring.pos = ((hi - jitTarget) * Wire.FPP).toDouble()
            ring.jumps++
            cur = ring.pos.toLong() / Wire.FPP
        }

        // The middle tier, asymmetric: behind means stale audio (skipping it is
        // right); past the head means nothing to play, and patience invents no
        // samples. Rewind only where unheard audio actually sits behind.
        val behind = hi - cur - jitTarget
        val past = cur - hi
        val unplayedBehind = hi - jitTarget > ring.maxPlayedSeq
        aheadRun = if (past > 1) aheadRun + 1 else 0
        val aheadHold = (0.010 * Wire.SR / devBuf).toInt()
        val snapBehind = behind > SNAP_PKTS
        val snapPast = past > 1 && aheadRun >= aheadHold && unplayedBehind
        if (snapBehind || snapPast) {
            ring.pos = ((hi - jitTarget) * Wire.FPP).toDouble()
            ring.snaps++
            if (snapBehind) ring.snapsBehind++ else ring.snapsPast++
            cur = ring.pos.toLong() / Wire.FPP
        }

        // The governor: occupancy error driven to zero by reading a hair off
        // real time. Bounded to ±0.4% — about 5 cents, inaudible.
        val errSamples = (hi - cur - jitTarget).toDouble() * Wire.FPP - (ring.pos % Wire.FPP)
        ring.rate = min(1.004, max(0.996, 1.0 + errSamples / (Wire.SR * 2.0)))
        ring.rateSum += ring.rate; ring.rateN++
        ring.errMs = errSamples / Wire.SR * 1000.0

        for (i in 0 until n) {
            val absI = ring.pos.toLong()
            val fr = (ring.pos - absI).toFloat()
            val seq = (absI / Wire.FPP).toInt()
            val off = (absI % Wire.FPP).toInt()
            val a = ring.sampleAt(absI)
            val b = ring.sampleAt(absI + 1)
            var value: Float
            if (a != null && b != null) {
                // Catmull-Rom: the buffer already holds the neighbours.
                val sm = ring.sampleAt(absI - 1) ?: a
                val s2 = ring.sampleAt(absI + 2) ?: b
                val t = fr; val t2 = t * t; val t3 = t2 * t
                value = 0.5f * ((2 * a) + (-sm + b) * t +
                    (2 * sm - 5 * a + 4 * b - s2) * t2 +
                    (-sm + 3 * a - 3 * b + s2) * t3)
                if (wasConcealing) {
                    // Do not step into the returning signal: cross-fade its first
                    // 1.3 ms against the synthesis already running.
                    wasConcealing = false
                    xfade = XFADE
                }
                if (xfade > 0) {
                    val w = (XFADE - xfade).toFloat() / XFADE
                    value = value * w + plcNext() * (1 - w)
                    xfade--
                    if (xfade == 0) { plcPeriod = 0; plcSamples = 0 }
                }
                hist[histW and HMASK] = value; histW++
                lastGood[off] = a
                goodRun++
                if (goodRun >= Wire.FPP) haveLastGood = true
                if (concealRun > concealMaxRun) concealMaxRun = concealRun
                concealRun = 0
                ring.playedS++
                if (seq.toLong() > ring.maxPlayedSeq) ring.maxPlayedSeq = seq.toLong()
            } else {
                if (!wasConcealing) {
                    // The period is decided ONCE, from the sound that was playing.
                    wasConcealing = true
                    xfade = 0
                    plcSamples = 0
                    plcPeriod = findPeriod()
                    plcCursor = histW - max(plcPeriod, 1)
                }
                value = plcNext()
                if (concealRun < 1_000_000_000) concealRun++
                goodRun = 0
                ring.concealedS++
                // Lost vs starved: past the head is starvation, behind it is loss.
                if (seq.toLong() > hi) ring.concealStarvedS++ else ring.concealLostS++
            }

            // The ear: Floor decides it, this ramps it. Down on the same 4 ms
            // linear close; back up fast, because restoring is never the slow one.
            val eWant = if (earOpen) 1f else 0f
            if (eWant < earGain) earGain = max(eWant, earGain - EAR_STEP)
            else earGain += (eWant - earGain) * 0.02f
            val played = value
            gate?.noteFar(played)
            val emitted = played * earGain
            out[i] = if (mute) 0f else emitted
            playoutSumSq += played.toDouble() * played
            playoutN++
            if (abs(emitted) > 1e-5f) playoutLive = true
            ring.pos += ring.rate
        }
    }

    /** RMS of what the speaker emitted since the last read, then reset. */
    fun takePlayoutRms(): Double {
        if (playoutN == 0) return 0.0
        val r = sqrt(playoutSumSq / playoutN)
        playoutSumSq = 0.0; playoutN = 0
        return r
    }
}
