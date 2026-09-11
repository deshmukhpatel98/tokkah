package com.tokkah.kin.net

import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Adaptive jitter controller ported from mac/Sources/tk/Audio.swift:2442.
 *
 * Governs buffer depth based on arrival slack, late arrival magnitude, and packet loss evidence.
 * Enforces monotonic decay upon recovery and prevents deep outlier spikes from ratcheting the target.
 */
class JitterAdapter(
    var jitMin: Int = 2,
    var jitMax: Int = 20,
    var shrinkAboveMs: Double = 1.0,
) {
    var growLateMin = 8
    var growBelowMs = 1.0
    var shrinkHold = 5
    var shrinkHoldFast = 5
    var starveAudiblePct = 0.02

    var target = jitMin
    var grows = 0
    var shrinks = 0
    var calm = 0
    var deepRefused = 0
    var enoughRefused = 0
    var growSuppressed = 0
    var marginExcused = 0
    var unsafeBelow = 0
    var probeAt = 0.0
    var backoff = 60.0

    var lastConcealed = 0
    var lastSnapsBehind = 0
    var lastLate = 0
    var lastNearLate = 0
    var lastStarved = 0

    var redundancy = false
    var lastLostForFec = 0
    var fecCalm = 0
    var fecRecovered0 = 0
    var fecLost0 = 0
    var fecWindows = 0
    var fecUselessUntil = 0.0
    var fecBackoff = 60.0
    var fecAllowed = true

    fun step(t: Double, r: RecvRing, peerLost: Int = 0, peerRecovered: Int = 0, peerReportsLoss: Boolean = false) {
        if (r.pos < 0) return
        val conc = r.concealed - lastConcealed
        lastConcealed = r.concealed
        val late = r.lateArrivals - lastLate
        lastLate = r.lateArrivals
        val near = r.nearLate - lastNearLate
        lastNearLate = r.nearLate

        val lostTotal = if (peerReportsLoss) peerLost else r.concealLost
        val recTotal = if (peerReportsLoss) peerRecovered else r.recovered
        var lostNow = lostTotal - lastLostForFec
        if (lostNow < 0) { lostNow = 0; fecRecovered0 = recTotal; fecLost0 = lostTotal }
        lastLostForFec = lostTotal
        if (fecAllowed && lostNow > 0 && !redundancy && t >= fecUselessUntil) {
            redundancy = true
            fecRecovered0 = recTotal
            fecLost0 = lostTotal
            fecWindows = 0
            fecCalm = 0
        } else if (redundancy) {
            fecWindows += 1
            val rec = maxOf(0, recTotal - fecRecovered0)
            val lost = maxOf(0, lostTotal - fecLost0)
            if (fecWindows >= 5 && rec + lost >= 20) {
                val rate = rec.toDouble() / (rec + lost)
                if (rate < 0.4) {
                    redundancy = false
                    fecUselessUntil = t + fecBackoff
                    fecBackoff = minOf(fecBackoff * 2.0, 600.0)
                    fecCalm = 0
                    return
                }
            }
            if (lostNow > 0) { fecCalm = 0 } else {
                fecCalm += 1
                if (fecCalm >= 15) {
                    redundancy = false
                    fecCalm = 0
                    fecBackoff = 60.0
                }
            }
        }

        val snappedBehind = r.snapsBehind - lastSnapsBehind
        lastSnapsBehind = r.snapsBehind

        val starved = r.concealStarved - lastStarved
        lastStarved = r.concealStarved
        val expected = 2.0 * Wire.SR / Wire.FPP.toDouble()
        val starvedPct = (starved.toDouble() / expected) * 100.0
        val starving = starvedPct > starveAudiblePct
        val p01 = r.slackWin.p(0.01) ?: return
        r.slackWin.reset()
        val worst = if (r.slackWinMin == 1e9) p01 else r.slackWinMin
        r.slackWinMin = 1e9
        val pktMs = Wire.FPP.toDouble() / Wire.SR * 1000.0
        val head = worst - pktMs

        val converged = abs(r.errMs) < 2.0
        if (p01 < growBelowMs && !converged) growSuppressed += 1

        val senderGap = r.ipiCapWinMax
        val senderHiccup = senderGap > pktMs * 1.5
        r.ipiCapWinMax = 0.0
        val excusedDip = p01 < growBelowMs && senderHiccup && conc == 0 && late == 0
        if (excusedDip) marginExcused += 1

        if (snappedBehind > 0 && (!starving && conc == 0)) {
            calm = 0
        } else if (excusedDip) {
            calm = 0
        } else if (!starving && target > jitMin + 1 && (late >= growLateMin || p01 < growBelowMs)) {
            enoughRefused += 1
            calm = 0
        } else if (!starving && late >= growLateMin && near < growLateMin && p01 >= growBelowMs) {
            deepRefused += 1
            calm = 0
        } else if ((late >= growLateMin && (near >= growLateMin || starving)) || (p01 < growBelowMs && converged) || (starving && target < jitMax)) {
            if (target < jitMax) {
                val step = when {
                    starving && starvedPct > 10.0 -> minOf(32, maxOf(4, (starvedPct * 0.8).roundToInt()))
                    starving && starvedPct > 2.0 -> minOf(16, maxOf(2, (starvedPct * 0.5).roundToInt()))
                    starving -> minOf(4, maxOf(2, starvedPct.roundToInt()))
                    else -> 1
                }
                target = minOf(jitMax, target + step)
                grows += 1
                unsafeBelow = maxOf(unsafeBelow, target)
                probeAt = t + backoff
                backoff = minOf(backoff * 2.0, 120.0)
            }
            calm = 0
        } else if (target <= unsafeBelow && t < probeAt) {
            calm = 0
        } else if (head > shrinkAboveMs && converged && target > jitMin) {
            calm += 1
            val hold = if (unsafeBelow == 0) shrinkHoldFast else shrinkHold
            if (calm >= hold) {
                target -= 1
                shrinks += 1
                calm = 0
                if (target < unsafeBelow) { unsafeBelow = target; backoff = 60.0 }
            }
        } else {
            calm = 0
        }
    }
}
