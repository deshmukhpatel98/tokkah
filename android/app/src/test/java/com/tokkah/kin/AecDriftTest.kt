package com.tokkah.kin

import com.tokkah.kin.net.Aec
import com.tokkah.kin.net.Wire
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.sin
import kotlin.random.Random

/**
 * The clock-drift tracker, on a planted drift (`aec-limited-by-clock-drift`).
 *
 * Two crystals: the echo the microphone hears is the reference resampled at
 * 1 + ppm·1e-6, generated with a WINDOWED SINC — linear interpolation plants a
 * morphing colouration no real clock produces, and the rig would then be
 * measuring its own artifact. The estimator's readings are fed the way the live
 * one feeds them: the planted delay at that moment, every half second of
 * signal time, with a little noise.
 *
 * The block is 160 frames: a real phone's capture burst (`io` in the beat), and
 * the size at which the step scaling gives the Mac's adaptation per second.
 *
 * Arms: 30 ppm tracked must beat 30 ppm untracked by a margin and read the
 * skew within 0.3 sps of the planted 1.44; 0 ppm must read a skew of 0.
 */
class AecDriftTest {
    private fun far(n: Int, lpk: Float = 0.25f): FloatArray {
        val r = Random(3); val out = FloatArray(n); var lp = 0f
        // Whiter than speech on purpose: this is a ruler for the TRACKER, and an
        // NLMS on heavily coloured input converges too slowly to read it in 30 s.
        for (i in 0 until n) { lp += lpk * ((r.nextFloat() * 2 - 1) - lp); out[i] = 0.4f * lp }
        return out
    }

    /** x(t) at a fractional position, 16-tap Hann-windowed sinc. */
    private fun sincAt(x: FloatArray, pos: Double): Float {
        val i0 = floor(pos).toInt(); val f = pos - i0
        var acc = 0.0
        for (k in -8..7) {
            val idx = i0 + k
            if (idx < 0 || idx >= x.size) continue
            val u = k - f
            val s = if (abs(u) < 1e-9) 1.0 else sin(PI * u) / (PI * u)
            val w = 0.5 * (1 + kotlin.math.cos(PI * u / 8.5))
            acc += x[idx] * s * w
        }
        return acc.toFloat()
    }

    class Out(val erleDb: Double, val skew: Float, val carries: Int, val reaims: Int, val held: Int)

    private fun run(ppm: Double, track: Boolean, secs: Int = 30, integer: Boolean = false, block: Int = 160, lpk: Float = 0.25f, skewMin: Float? = null, wrongMs: Double = 0.0, cfgOf: Aec.Cfg? = null): Out {
        val aec = Aec()
        cfgOf?.let { aec.cfg = it }
        aec.cfg.driftTrack = track
        skewMin?.let { aec.cfg.skewMin = it }
        val n = secs * Wire.SR
        val ref = far(n + 4096, lpk)
        val delay0 = 31.0 / 1000 * Wire.SR          // 31 ms room
        val refCap = 1 shl 16
        val ring = FloatArray(refCap)
        var refW = 0
        val mic = FloatArray(block)
        var micE = 0.0; var outE = 0.0
        var nextAim = 0.0
        var aimCount = 0
        var i = 0
        while (i + block <= n) {
            // The speaker plays the reference; the ring is what the AEC reads.
            for (k in 0 until block) { ring[(refW + k) % refCap] = ref[i + k] }
            refW += block
            // The mic hears it `delay(t)` later through a clock running fast by ppm.
            for (k in 0 until block) {
                val t = i + k
                val d = delay0 + ppm * 1e-6 * t
                mic[k] = if (integer) (if (t - d.toInt() >= 0) 0.5f * ref[t - d.toInt()] else 0f) else 0.5f * sincAt(ref, t - d)
            }
            val tSec = i.toDouble() / Wire.SR
            if (tSec >= nextAim) {
                nextAim += 0.5
                val d = delay0 + ppm * 1e-6 * i
                // As the live estimator reads: decimated by 8, so a reading is a
                // multiple of 8 samples (the Mac's rig: `(Int(dNow + jit) / 8) * 8`).
                // A finer noise than the instrument has is a fixture that is not
                // the real shape — it fed the fit a ±3-sample wander it believed.
                // `wrongMs` plants the 0.125 rig's episodes instead: a reading
                // 10 ms off for 2 s in every 6, which is what an intermittent
                // playout does to the estimator.
                val episode = aimCount / 12
                val wrong = wrongMs > 0 && aimCount % 12 >= 8
                val jit = if (wrong) (if (episode % 2 == 0) 1.0 else -1.0) * wrongMs / 1000 * Wire.SR else 0.0
                aimCount++
                aec.aim(((d + jit).toInt() / 8) * 8, 0.9)
            }
            val before = mic.copyOf()
            aec.process(mic, block, ring, refW, refCap)
            if (tSec >= secs - 10) {
                for (k in 0 until block) { micE += before[k] * before[k]; outE += mic[k] * mic[k] }
            }
            i += block
        }
        val erle = if (outE > 0) 10 * ln(micE / outE) / ln(10.0) else 99.0
        println("  aec: ${aec.describe} blocks=${aec.blocks} ran=${aec.ranBlocks} off=${aec.offBlocks} freezes=${aec.freezes} reaims=${aec.reaims} held=${aec.reaimsHeld} resets=${aec.dllResets} rejects=${aec.skewRejects} delay=${aec.delayNow} frac=${aec.fracNow}")
        return Out(erle, aec.skewSps, aec.carries, aec.reaims, aec.reaimsHeld)
    }

    @Test fun trackedBeatsUntrackedUnderThirtyPpm() {
        val off = run(30.0, track = false)
        val on = run(30.0, track = true)
        println("drift 30 ppm: untracked ${"%.1f".format(off.erleDb)} dB, tracked ${"%.1f".format(on.erleDb)} dB, skew ${on.skew} sps, ${on.carries} carries")
        assertTrue("tracked ${on.erleDb} should beat untracked ${off.erleDb} by 3 dB", on.erleDb - off.erleDb >= 3.0)
        assertEquals("skew reads the planted 1.44 sps", 1.44f, on.skew, 0.3f)
        assertTrue("whole samples carried", on.carries >= 10)
    }

    @Test fun noDriftReadsNoSkewAndCostsNothing() {
        val off = run(0.0, track = false)
        val on = run(0.0, track = true)
        println("drift 0 ppm: untracked ${"%.1f".format(off.erleDb)} dB, tracked ${"%.1f".format(on.erleDb)} dB, skew ${on.skew}")
        assertEquals(0f, on.skew, 0.15f)
        assertTrue("tracking a still room must cost nothing: ${off.erleDb} → ${on.erleDb}", off.erleDb - on.erleDb < 1.0)
        assertTrue("still cancels: ${on.erleDb}", on.erleDb > 8.0)
    }

    /**
     * The 0.125.0 rig: readings 10 ms off for 2 s in every 6. Unguarded, every
     * episode re-aims and zeroes a converged filter; held, a working filter is
     * kept and the wander costs nothing.
     */
    @Test fun aWorkingFilterIsNotReaimed() {
        val clean = run(0.0, track = true)
        val held = run(0.0, track = true, wrongMs = 10.0)
        val unguarded = Aec().let { a -> a.cfg.reaimHoldDb = 1e9; run(0.0, track = true, wrongMs = 10.0, cfgOf = a.cfg) }
        println("wandering readings: clean ${"%.1f".format(clean.erleDb)} dB; held ${"%.1f".format(held.erleDb)} dB (${held.reaims} re-aims, ${held.held} holds); unguarded ${"%.1f".format(unguarded.erleDb)} dB (${unguarded.reaims} re-aims)")
        assertTrue("held re-aims ${held.reaims} should be ≤ 2", held.reaims <= 2)
        assertTrue("holds happened: ${held.held}", held.held >= 3 && held.held <= 12)
        assertTrue("held ${held.erleDb} within 1.5 dB of clean ${clean.erleDb}", clean.erleDb - held.erleDb < 1.5)
        assertTrue("unguarded re-aims ${unguarded.reaims} should be many", unguarded.reaims >= 4)
    }
}
