package com.tokkah.kin.net

// Port of RecvRing from mac/Sources/tk/Net.swift:96-355 — the jitter buffer.
// The read cursor is ABSOLUTE and FRACTIONAL: latency has to be governed, not
// merely initialised, or the cursor keeps whatever distance it started with.
class RecvRing {
    val samples = FloatArray(Wire.RING * Wire.FPP)
    private val tags = IntArray(Wire.RING) { -1 }
    val capHost = LongArray(Wire.RING)
    val recvHost = LongArray(Wire.RING)
    var hiSeq = -1; private set

    var pos = -1.0
    var rate = 1.0
    var rateSum = 0.0
    var rateN = 0

    var recv = 0; var dup = 0; var jumps = 0; var tooOld = 0; var snaps = 0
    var snapsBehind = 0
    var snapsPast = 0
    // Counted in SAMPLES, never at packet boundaries: a fractional cursor can
    // skip the boundary sample for thousands of callbacks in a row.
    var playedS = 0; var concealedS = 0; var concealLostS = 0; var concealStarvedS = 0
    var maxPlayedSeq = -1L
    val played get() = playedS / Wire.FPP
    val concealed get() = concealedS / Wire.FPP
    var lateArrivals = 0
    var nearLate = 0
    var accepted = 0
    var recovered = 0
    private var oldRun = 0
    var restarts = 0
    val concealLost get() = concealLostS / Wire.FPP
    val concealStarved get() = concealStarvedS / Wire.FPP
    var errMs = 0.0

    var slackMin = 1e9
    var slackWinMin = 1e9
    var slackSum = 0.0; var slackN = 0

    private var lastIpiSeq = -1
    private var lastIpiCap = 0L
    private var lastIpiRecv = 0L
    var ipiCapMax = 0.0
    var ipiRecvMax = 0.0
    var ipiCapWinMax = 0.0

    fun present(seq: Int): Boolean = seq >= 0 && tags[seq % Wire.RING] == seq

    /** One sample by ABSOLUTE index, or null when its packet is not here. */
    fun sampleAt(i: Long): Float? {
        if (i < 0) return null
        val sq = (i / Wire.FPP).toInt()
        if (!present(sq)) return null
        return samples[(sq % Wire.RING) * Wire.FPP + (i % Wire.FPP).toInt()]
    }

    /** Socket thread. */
    fun write(seq: Int, cap: Long, src: FloatArray, n: Int, srcOff: Int = 0) {
        recv++
        val slot = seq % Wire.RING
        if (tags[slot] == seq) { dup++; return }
        if (pos >= 0) {
            val curSeq = pos.toLong() / Wire.FPP
            if (seq.toLong() < curSeq - Wire.RING) {
                tooOld++
                oldRun++
                // A peer that restarted is not a late packet: sequence numbers
                // begin at zero again, and refusing them kills the call for good.
                // 64 in a row with no successful write between them is the test.
                if (oldRun >= 64) {
                    restarts++
                    java.util.Arrays.fill(tags, -1)
                    hiSeq = -1
                    pos = -1.0
                    oldRun = 0
                } else return
            } else oldRun = 0
        }
        if (pos >= 0) {
            val ms = (seq.toLong() * Wire.FPP - pos) / Wire.SR * 1000.0
            slackSum += ms; slackN++
            if (ms < slackMin) slackMin = ms
            if (ms < slackWinMin) slackWinMin = ms
            if (ms < 0) {
                lateArrivals++
                // Only lateness under one packet is lateness one more packet of
                // buffer would have caught.
                if (ms > -(Wire.FPP.toDouble() / Wire.SR * 1000.0)) nearLate++
            }
        }
        System.arraycopy(src, srcOff, samples, slot * Wire.FPP, minOf(n, Wire.FPP))
        val now = KinClock.now()
        if (seq == lastIpiSeq + 1 && lastIpiCap != 0L) {
            val dc = KinClock.msSigned(cap, lastIpiCap)
            val dr = KinClock.msSigned(now, lastIpiRecv)
            if (dc > ipiCapMax) ipiCapMax = dc
            if (dc > ipiCapWinMax) ipiCapWinMax = dc
            if (dr > ipiRecvMax) ipiRecvMax = dr
        }
        lastIpiSeq = seq; lastIpiCap = cap; lastIpiRecv = now
        capHost[slot] = cap
        recvHost[slot] = now
        tags[slot] = seq
        accepted++
        if (seq > hiSeq) hiSeq = seq
    }
}
