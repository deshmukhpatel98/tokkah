package com.tokkah.kin.net

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Port of `FloorCue` from mac/Sources/tk/Cues.swift — how loud the far end's
 * intention looks, as one eased number.
 *
 * A listening noise and a bid for the floor are the same event acoustically,
 * separated only by how long it lasts, so they are ONE CONTINUUM rather than
 * two states: `level` eases toward 0.42 for a listening noise and toward 0.82+
 * for a bid, and a bid rises faster because the whole point of the cue is that
 * it lands one hop after somebody opens their mouth.
 *
 * Rise is faster than fall. The direction that says "they want to speak" is
 * never allowed to be the slow one; the direction that says "they stopped" can
 * afford to be gentle, because being slightly late to fade is invisible and
 * being late to appear is the whole cost.
 */
class FloorCue {
    /** 0 quiet, 1 listening noise, 2 bid for the floor — the wire's own values. */
    var vocal = 0
    /** The turn-end prior, 0..1: a bid arriving on a sentence that is ending. */
    var nudge = 0.0

    var level = 0f; private set

    private val target: Float
        get() = when (vocal) {
            1 -> 0.42f
            2 -> min(1.0, 0.82 + 0.18 * max(0.0, min(1.0, nudge))).toFloat()
            else -> 0f
        }

    fun step(dt: Float) {
        val t = target
        val riseTau =
            if (vocal == 2) (0.050 - 0.015 * max(0.0, min(1.0, nudge))).toFloat() else 0.16f
        val tau = if (t > level) riseTau else 0.34f
        level += (t - level) * min(1f, dt / tau)
        if (abs(t - level) < 0.002f) level = t
    }

    val idle: Boolean get() = level < 0.01f && target == 0f

    /**
     * How long this cue takes to reach [to] from where it is now, in ms.
     * Exposed because the claim "a bid crosses 0.75 inside 120 ms" is a
     * measurement, and a measurement nothing can take is an assertion.
     */
    fun timeTo(to: Float, frameMs: Float = 1000f / 30f, limitMs: Float = 4000f): Float? {
        val falling = level > to
        var t = 0f
        while (t < limitMs) {
            step(frameMs / 1000f)
            t += frameMs
            if (if (falling) level <= to else level >= to) return t
        }
        return null
    }
}
