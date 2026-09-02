package com.tokkah.kin

import com.tokkah.kin.net.Aec
import com.tokkah.kin.net.EchoAim
import com.tokkah.kin.net.Wire
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.sin
import kotlin.random.Random

/**
 * The ruler, validated on known inputs (`validate-the-ruler-against-known-inputs`):
 * a delay it MUST find, a silent microphone it MUST refuse, and an unrelated
 * microphone it must NOT confidently aim at.
 */
class EchoAimTest {
    /** Speech-shaped noise: white noise through a leaky one-pole, with a pitch. */
    private fun voice(n: Int, seed: Int, hz: Double = 180.0): FloatArray {
        val r = Random(seed)
        val out = FloatArray(n)
        var lp = 0f
        for (i in 0 until n) {
            lp += 0.15f * ((r.nextFloat() * 2 - 1) - lp)
            out[i] = 0.3f * lp + 0.05f * sin(2 * Math.PI * hz * i / Wire.SR).toFloat()
        }
        return out
    }

    private fun run(delayMs: Double, micGain: Float, micFrom: FloatArray?): Pair<EchoAim, Aec> {
        val aec = Aec()
        val aim = EchoAim(aec)
        val secs = 2
        val far = voice(secs * Wire.SR, 1)
        val d = (delayMs / 1000 * Wire.SR).toInt()
        val block = 480
        var i = 0
        while (i + block <= far.size) {
            // What the speaker plays now …
            aim.noteEmit(far.copyOfRange(i, i + block), block)
            // … and what the mic hears: the speaker, `d` samples ago, quieter.
            val mic = FloatArray(block) { k ->
                val src = i + k - d
                val echo = if (src >= 0) far[src] * micGain else 0f
                echo + (micFrom?.get(i + k) ?: 0f)
            }
            aim.noteCapture(mic, block)
            i += block
        }
        aim.tick()
        return aim to aec
    }

    @Test fun findsAKnownDelay() {
        for (want in listOf(20.0, 55.0, 120.0)) {
            val (aim, aec) = run(want, micGain = 0.3f, micFrom = null)
            assertTrue("scanned", aim.scans == 1)
            assertTrue("aimed: corr ${aim.echoCorr}", aim.echoCorr > 0.8)
            assertEquals("delay $want ms, found ${aim.echoDelayMs}", want, aim.echoDelayMs, 2.0)
            assertEquals((aim.echoDelayMs / 1000 * Wire.SR).toInt(), aec.aimSamples)
        }
    }

    @Test fun refusesASilentMicrophone() {
        val (aim, aec) = run(40.0, micGain = 0f, micFrom = null)
        assertEquals("a silent mic has no echo to find", 0, aim.scans)
        assertEquals(-1, aec.aimSamples)
    }

    @Test fun doesNotBelieveAnUnrelatedVoice() {
        // The mic hears a DIFFERENT talker and none of the speaker.
        // A different person: a different noise AND a different pitch. The same
        // pitch in both would be a real correlation, not a false one.
        val other = voice(2 * Wire.SR, 7, hz = 233.0)
        val (aim, _) = run(40.0, micGain = 0f, micFrom = other)
        assertTrue("uncorrelated: corr ${aim.echoCorr}", aim.echoCorr < Aec().cfg.minCorr)
    }
}
