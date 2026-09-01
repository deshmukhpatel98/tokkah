package com.tokkah.kin.net

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Port of mac/Sources/tk/Mouth.swift — the only signal that separates a person
 * from an echo.
 *
 * Not "is a mouth open": mouths differ between faces and a person at rest can
 * have a wide one. What separates speech from a face at rest is that the
 * aperture CHANGES, several times a second, so the signal is the rate of change
 * of lip aperture — which needs no per-face calibration and no threshold on
 * anybody's anatomy.
 *
 * The aperture is measured on the lip cloud's OWN AXES rather than vertically,
 * so a tilted head reads the same as a level one. That change was a change of
 * UNITS, and the threshold had to be re-measured for it — the old 0.03 called a
 * perfectly still face "moving" 31% of the time.
 */
object MouthConfig {
    const val HZ = 12.0
    /**
     * Aperture-ratio per second above which the mouth is doing what speech does.
     * MEASURED, twice, and wrong both times before it was measured. On real
     * talking-head footage at 12 Hz in the current units:
     *
     *   talking   p10 0.30  p50 0.63  p90 1.30
     *   same face p10 0.01  p50 0.02  p90 0.08   (one frame of it, held)
     *
     * 0.15 sits between the still p90 and the talking p10.
     */
    var moveThreshold = 0.15
    /** Speech pauses between words; a detector that drops on each is noise. */
    var hangoverMs = 250.0
}

/**
 * One face's mouth over time. Fed landmark points at [MouthConfig.HZ]; says
 * whether this face is doing what speech does.
 */
class Mouth {
    var on = true
    /** False when there is no face, no camera, or a dark room — say nothing. */
    var visualKnown = false; private set
    var visualVoice = false; private set

    var rateNow = 0.0; private set
    var faces = 0; private set
    var movingSamples = 0; private set
    var stillSamples = 0; private set

    private var lastAperture = -1.0
    private var lastAtMs = 0.0
    private var movingUntilMs = 0.0

    fun reset() {
        lastAperture = -1.0; lastAtMs = 0.0; movingUntilMs = 0.0
        rateNow = 0.0; faces = 0; movingSamples = 0; stillSamples = 0
        visualKnown = false; visualVoice = false
    }

    /** No face this frame: the detector is BLIND, which is not the same as "still". */
    fun noFace() {
        visualKnown = false
        visualVoice = false
        lastAperture = -1.0
    }

    /** [points] are the lip contour in image coordinates. */
    fun note(points: List<Pair<Float, Float>>, atMs: Double) {
        if (!on) return
        val ap = aperture(points) ?: run { noFace(); return }
        faces++
        visualKnown = true
        if (lastAperture >= 0 && lastAtMs != 0.0) {
            val dt = max(0.001, (atMs - lastAtMs) / 1000.0)
            val rate = abs(ap - lastAperture) / dt
            rateNow = rateNow * 0.5 + rate * 0.5
            if (rateNow >= MouthConfig.moveThreshold) {
                movingSamples++
                movingUntilMs = atMs
            } else stillSamples++
            visualVoice = movingUntilMs != 0.0 && (atMs - movingUntilMs) <= MouthConfig.hangoverMs
        }
        lastAperture = ap
        lastAtMs = atMs
    }

    /**
     * Mouth opening over mouth width, on the lip cloud's own principal axes —
     * the second moment's minor extent over its major one. Rotation-invariant
     * by construction rather than by correction.
     */
    fun aperture(pts: List<Pair<Float, Float>>): Double? {
        if (pts.size < 4) return null
        var mx = 0.0; var my = 0.0
        for ((x, y) in pts) { mx += x; my += y }
        mx /= pts.size; my /= pts.size
        var sxx = 0.0; var syy = 0.0; var sxy = 0.0
        for ((x, y) in pts) {
            val dx = x - mx; val dy = y - my
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        val n = pts.size.toDouble()
        sxx /= n; syy /= n; sxy /= n
        val tr = sxx + syy
        val det = sxx * syy - sxy * sxy
        val disc = max(0.0, tr * tr / 4 - det)
        val l1 = tr / 2 + sqrt(disc)     // larger: along the mouth
        val l2 = tr / 2 - sqrt(disc)     // smaller: across it
        if (l1 <= 1e-12) return null
        return sqrt(max(0.0, l2)) / sqrt(l1)
    }
}
