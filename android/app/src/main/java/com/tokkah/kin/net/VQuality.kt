package com.tokkah.kin.net

/**
 * Port of mac/Sources/tk/VQuality.swift — how good the picture is allowed to be.
 *
 * Aim high, and give up quality the instant the link complains: on a link that
 * cannot carry 1.2 Mbps, that video QUEUES, and a queue is latency, which is
 * the thing this whole program exists to remove. Better a slightly soft picture
 * than a call that feels laggy.
 *
 * Three rules the jitter-buffer controller learned the hard way, mirrored:
 *
 *  - ASYMMETRIC ON PURPOSE. Down is the safe direction, so it happens on the
 *    first sign of harm. Up is a bet, so it needs sustained quiet.
 *  - REMEMBER FAILED LEVELS, WITH BACKOFF. Without it the controller steps up
 *    into the level that just failed, hurts, steps down, waits out its timer,
 *    and does it again forever.
 *  - WATCH FOR HARM WE CAN ACTUALLY FIX. Lost frames and a grown audio buffer
 *    are "this link is unhappy about volume", which less video volume
 *    addresses. Round-trip time is not, so it is not wired in.
 */
class VQuality(
    ceiling: Double? = null,
    private val held: Boolean = false,
    private val canPause: Boolean = true,
    pauseAfter: Int = 3,
    resumeQuiet: Int = 8,
) {
    companion object {
        /**
         * Lowest first, and ALL NUMERIC. 0.3 is 35.6 dB at 0.089 Mbps on a 720p
         * frame with no resolution ladder under it — that is the picture two
         * people described as "highly pixelated", and a floor nobody wants to
         * land on is not a floor. 0.5 is 40.1 dB at 0.221 Mbps: soft, watchable,
         * and still an eighth of the lossless rung.
         */
        val LEVELS = doubleArrayOf(0.5, 0.6, 0.7)
    }

    private val ceilingIdx: Int
    var level: Int; private set
    private val blockedUntil = DoubleArray(LEVELS.size)
    private val penalty = DoubleArray(LEVELS.size) { 10.0 }
    private var quietFor = 0
    var stepDowns = 0; private set
    var stepUps = 0; private set
    var refusedUps = 0; private set
    var paused = false; private set
    var pauses = 0; private set
    var pausedTicks = 0; private set
    private var harmedAtFloor = 0
    private var quietPaused = 0
    private val pauseAfterN = maxOf(1, pauseAfter)
    private val resumeQuietBase = maxOf(1, resumeQuiet)
    private val quietNeeded = 15
    private val warmup = 8

    init {
        ceilingIdx = if (ceiling != null) {
            var best = 0
            for (i in LEVELS.indices) if (LEVELS[i] <= ceiling + 1e-9) best = i
            best
        } else LEVELS.size - 1
        level = ceilingIdx
    }

    val quality: Double get() = LEVELS[level]

    /** One second. Returns the new quality when it changed, else null. */
    fun tick(now: Double, framesLost: Int, concealed: Int, jitGrew: Boolean): Double? {
        if (held) return null
        if (now < warmup) return null
        val harmed = framesLost > 0 || concealed > 0 || jitGrew

        if (paused) {
            pausedTicks++
            if (harmed) { quietPaused = 0; return null }
            quietPaused++
            val need = minOf(resumeQuietBase shl minOf(pauses - 1, 3), 60)
            if (quietPaused < need) return null
            paused = false
            level = 0
            quietFor = 0
            harmedAtFloor = 0
            return null
        }

        if (harmed) {
            quietFor = 0
            if (level == 0) {
                if (!canPause) return null
                harmedAtFloor++
                if (harmedAtFloor < pauseAfterN) return null
                paused = true
                pauses++
                quietPaused = 0
                harmedAtFloor = 0
                return null
            }
            blockedUntil[level] = now + penalty[level]
            penalty[level] = minOf(penalty[level] * 2, 120.0)
            level--
            stepDowns++
            return quality
        }

        quietFor++
        harmedAtFloor = 0
        if (quietFor < quietNeeded || level >= ceilingIdx) return null
        val next = level + 1
        if (now < blockedUntil[next]) { refusedUps++; return null }
        level = next
        stepUps++
        quietFor = 0
        return quality
    }

    val describe: String
        get() = (if (paused) "PAUSED (was q" else if (held) "HELD q" else "q") +
            "%.1f".format(quality) + (if (paused) ")" else "") +
            " (level $level/$ceilingIdx, $stepDowns down $stepUps up" +
            (if (refusedUps > 0) " $refusedUps up-refused" else "") +
            (if (pauses > 0) ", $pauses pause${if (pauses == 1) "" else "s"} ${pausedTicks}s" else "") + ")"
}
