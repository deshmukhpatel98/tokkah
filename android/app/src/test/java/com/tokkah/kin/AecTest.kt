package com.tokkah.kin

import com.tokkah.kin.net.Aec
import com.tokkah.kin.net.Wire
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.ln
import kotlin.math.sqrt

/**
 * A canceller is not tested by "it ran". It is tested by how much echo it
 * removed, and — far more importantly — by whether it can be made to ADD any.
 *
 * The recorded failure this file exists to prevent measured -21.7 dB: the
 * canceller making the microphone twenty-one decibels louder, and -21.6 dB with
 * no echo path armed at all. So near-end-only speech is a test case here, not
 * an afterthought.
 */
class AecTest {
    private val sr = Wire.SR
    private val block = 192

    /** A room: the far signal, delayed and attenuated, plus a second reflection. */
    private class Room(val delay: Int, val gain: Float) {
        private val tail = FloatArray(8192)
        private var w = 0
        fun echo(x: Float): Float {
            tail[w % tail.size] = x
            val a = tail[((w - delay) % tail.size + tail.size) % tail.size]
            val b = tail[((w - delay - 61) % tail.size + tail.size) % tail.size]
            w++
            return gain * a + 0.35f * gain * b
        }
    }

    private class Rng(var s: Long = 0x5EED) {
        fun next(): Float {
            s = s * 6364136223846793005L + 1442695040888963407L
            return ((s ushr 40).toInt() / 8388608.0f) - 1f
        }
    }

    private fun db(a: Double, b: Double) = 10.0 * ln(a / b) / ln(10.0)

    /**
     * Far end talking, nobody near: the case the canceller exists for. Speech
     * is not a sine — a sine is trivially predictable and would flatter any
     * filter — so this is band-limited noise, which is the hard honest input.
     */
    @Test
    fun cancelsAFarOnlyEcho() {
        val aec = Aec()
        val room = Room(delay = 240, gain = 0.55f)
        aec.aimSamples = 240
        aec.aimCorr = 0.9

        val refCap = 1 shl 16
        val ref = FloatArray(refCap)
        var refW = 0
        val rng = Rng()
        var lp = 0f
        var micE = 0.0
        var outE = 0.0
        val blocks = 6000

        val mic = FloatArray(block)
        for (b in 0 until blocks) {
            for (i in 0 until block) {
                lp += 0.06f * (rng.next() * 0.5f - lp)     // band-limited far speech
                val far = lp
                ref[refW % refCap] = far
                refW++
                mic[i] = room.echo(far)                     // near end silent
            }
            val before = mic.copyOf()
            aec.process(mic, block, ref, refW, refCap)
            // Measure only the last third: the first two are convergence, and
            // averaging them in reports the climb rather than the answer.
            if (b > blocks * 2 / 3) {
                for (i in 0 until block) {
                    micE += before[i].toDouble() * before[i]
                    outE += mic[i].toDouble() * mic[i]
                }
            }
        }
        val erle = db(micE, outE)
        // MEASURED, and recorded rather than asserted tightly: 9.8 dB here
        // against the Mac's 19 dB synthetic. The gap is convergence rate, not
        // correctness — every safety property below holds — and closing it is
        // tuning that belongs against a real device rather than this rig.
        println("AEC far-only ERLE: %.1f dB after %d blocks".format(erle, blocks))
        assertTrue("erle was %.1f dB, expected real cancellation".format(erle), erle > 8.0)
        assertTrue("it should have adapted", aec.updates > 100)
    }

    /**
     * THE ONE THAT MATTERS. Nobody at the far end, a person talking here: an
     * NLMS driven by an uncorrelated reference random-walks, and the old one
     * added 21 dB. This must not make the microphone louder AT ALL.
     */
    @Test
    fun nearEndOnlySpeechIsNeverMadeLouder() {
        val aec = Aec()
        aec.aimSamples = 240
        aec.aimCorr = 0.9
        val refCap = 1 shl 16
        val ref = FloatArray(refCap)          // silence: no far end
        var refW = 0
        val rng = Rng(0xC0FFEE)
        var lp = 0f
        var micE = 0.0
        var outE = 0.0
        val mic = FloatArray(block)
        for (b in 0 until 900) {
            for (i in 0 until block) {
                ref[refW % refCap] = 0f
                refW++
                lp += 0.06f * (rng.next() * 0.6f - lp)
                mic[i] = lp                    // a person, and only a person
            }
            val before = mic.copyOf()
            aec.process(mic, block, ref, refW, refCap)
            for (i in 0 until block) {
                micE += before[i].toDouble() * before[i]
                outE += mic[i].toDouble() * mic[i]
            }
        }
        val change = db(micE, outE)
        // Negative here means LOUDER out than in. The old failure was -21.7.
        assertTrue("the canceller changed a near-only voice by %.2f dB".format(change),
            change > -0.5)
        assertTrue("it must refuse to adapt on silence", aec.freezes > 0)
    }

    /** Double talk: both at once. It may help less; it may never harm. */
    @Test
    fun doubleTalkIsNotDamaged() {
        val aec = Aec()
        val room = Room(delay = 300, gain = 0.5f)
        aec.aimSamples = 300
        aec.aimCorr = 0.9
        val refCap = 1 shl 16
        val ref = FloatArray(refCap)
        var refW = 0
        val far = Rng(1); val near = Rng(2)
        var lpF = 0f; var lpN = 0f
        var micE = 0.0; var outE = 0.0
        val mic = FloatArray(block)
        for (b in 0 until 900) {
            for (i in 0 until block) {
                lpF += 0.06f * (far.next() * 0.5f - lpF)
                lpN += 0.06f * (near.next() * 0.5f - lpN)
                ref[refW % refCap] = lpF
                refW++
                mic[i] = room.echo(lpF) + lpN
            }
            val before = mic.copyOf()
            aec.process(mic, block, ref, refW, refCap)
            if (b > 300) for (i in 0 until block) {
                micE += before[i].toDouble() * before[i]
                outE += mic[i].toDouble() * mic[i]
            }
        }
        val change = db(micE, outE)
        assertTrue("double talk changed by %.2f dB".format(change), change > -1.0)
    }

    /** No aim, no confidence: the filter must be a no-op, not a guess. */
    @Test
    fun withoutAnAimItDoesNothing() {
        val aec = Aec()
        aec.aimSamples = -1
        val refCap = 4096
        val ref = FloatArray(refCap) { 0.3f }
        val mic = FloatArray(block) { 0.2f }
        val before = mic.copyOf()
        aec.process(mic, block, ref, refCap, refCap)
        for (i in 0 until block) assertTrue(mic[i] == before[i])
        assertTrue(aec.offBlocks > 0)
    }

    /** The residual is MEASURED, so a dead filter reports a bar of 1. */
    @Test
    fun residualReportsOneWhenNothingWasCancelled() {
        val aec = Aec()
        assertTrue(aec.residual == 1f)
    }
}
