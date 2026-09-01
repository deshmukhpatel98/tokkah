package com.tokkah.kin

import com.tokkah.kin.net.Mouth
import com.tokkah.kin.net.MouthConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * The measure has to survive a tilted head, because that is the property the
 * Mac changed the units for — and a rotated face that is still FOUND while the
 * quantity goes wrong is the failure no search can catch.
 */
class MouthTest {
    /** An ellipse of lip points: [open] is the aperture, rotated by [deg]. */
    private fun lips(open: Double, deg: Double = 0.0, n: Int = 12): List<Pair<Float, Float>> {
        val r = deg * PI / 180
        return (0 until n).map { i ->
            val a = 2 * PI * i / n
            val x = cos(a) * 1.0
            val y = sin(a) * open
            val rx = x * cos(r) - y * sin(r)
            val ry = x * sin(r) + y * cos(r)
            (rx.toFloat() to ry.toFloat())
        }
    }

    @Test
    fun apertureIsRotationInvariant() {
        val m = Mouth()
        val flat = m.aperture(lips(0.25))!!
        for (deg in listOf(0.0, 15.0, 30.0, 45.0, 90.0, 180.0)) {
            val got = m.aperture(lips(0.25, deg))!!
            assertEquals("rotated $deg°", flat, got, 0.02)
        }
    }

    @Test
    fun aWiderOpeningReadsHigher() {
        val m = Mouth()
        val closed = m.aperture(lips(0.05))!!
        val open = m.aperture(lips(0.60))!!
        assertTrue("closed $closed should be under open $open", open > closed * 3)
    }

    @Test
    fun aStillFaceIsNotSpeaking() {
        val m = Mouth()
        var t = 0.0
        // The same face, held, for two seconds at 12 Hz.
        repeat(24) { m.note(lips(0.30), t); t += 1000.0 / MouthConfig.HZ }
        assertTrue("it must know it can see a face", m.visualKnown)
        assertFalse("a held face is not speech", m.visualVoice)
        assertTrue(m.stillSamples > m.movingSamples)
    }

    @Test
    fun aMovingMouthIsSpeaking() {
        val m = Mouth()
        var t = 0.0
        // Aperture swinging the way speech does, several times a second.
        repeat(24) { i ->
            m.note(lips(if (i % 2 == 0) 0.12 else 0.52), t)
            t += 1000.0 / MouthConfig.HZ
        }
        assertTrue("rate was ${m.rateNow}", m.visualVoice)
        assertTrue(m.movingSamples > 0)
    }

    @Test
    fun noFaceMeansBlindNotStill() {
        val m = Mouth()
        var t = 0.0
        repeat(6) { i -> m.note(lips(if (i % 2 == 0) 0.12 else 0.52), t); t += 83.0 }
        assertTrue(m.visualKnown)
        m.noFace()
        // Blind is not a verdict: `visualKnown` false is how the floor knows to
        // ignore this signal rather than read it as "not talking".
        assertFalse(m.visualKnown)
        assertFalse(m.visualVoice)
    }

    @Test
    fun theHangoverBridgesAPauseBetweenWords() {
        val m = Mouth()
        var t = 0.0
        repeat(8) { i -> m.note(lips(if (i % 2 == 0) 0.12 else 0.52), t); t += 83.0 }
        assertTrue(m.visualVoice)
        // A gap shorter than the hangover: still speaking.
        m.note(lips(0.52), t + 150); assertTrue(m.visualVoice)
        // A gap past it, with a still mouth: stopped.
        var t2 = t + 150
        repeat(10) { m.note(lips(0.52), t2); t2 += 83.0 }
        assertFalse(m.visualVoice)
    }

    @Test
    fun tooFewPointsIsRefusedRatherThanGuessed() {
        val m = Mouth()
        assertTrue(m.aperture(listOf(0f to 0f, 1f to 1f)) == null)
    }
}
