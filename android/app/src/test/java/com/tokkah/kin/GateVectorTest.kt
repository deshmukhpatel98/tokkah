package com.tokkah.kin

import com.tokkah.kin.net.DuplexGate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.sqrt

// Differential test against the SHIPPED Audio.DuplexGate. gate.csv is produced
// by compiling the class's own source, extracted from Audio.swift at generation
// time, so the reference cannot drift from what the Mac actually runs.
class GateVectorTest {
    private class LCG(var s: Long) {
        fun next(): Int {
            s = s * 6364136223846793005L + 1442695040888963407L
            return ((s ushr 33) and 0xffffffffL).toInt()
        }
    }

    @Test
    fun everyBlockMatchesTheSwiftOriginal() {
        val lines = javaClass.getResourceAsStream("/vectors/gate.csv")!!.reader().readLines()
        var i = 0
        var scenarios = 0
        var blocksChecked = 0
        while (i < lines.size) {
            val header = lines[i]
            assertTrue("scenario header at $i: $header", header.startsWith("# "))
            val meta = header.removePrefix("# ").split("|")
            val name = meta[0]
            fun f(k: String) = meta.first { it.startsWith("$k=") }.substringAfter("=")
            val g = DuplexGate()
            g.cfg.on = f("on") == "1"
            g.corrVeto = f("veto") == "1"
            g.mouthSays = f("mouth") == "1" && g.corrVeto
            g.echoResidual = f("residual").toFloat()
            g.yielding = f("yield") == "1"
            g.floorMuted = f("fmute") == "1"
            g.floorDucked = f("fduck") == "1"
            g.floorGranted = f("fgrant") == "1"
            val blocks = f("blocks").toInt()
            val n = f("n").toInt()
            val nearAmp = f("near").toFloat()
            val farAmp = f("far").toFloat()
            val rng = LCG(f("seed").toLong())
            i++

            val x = FloatArray(n)
            // Triangle waves, matching the generator: IEEE-754 +,-,*,/ are
            // exactly specified in both languages, while sinf and Math.sin
            // differ by an ULP that phase accumulation turns into drift.
            var idx = 0
            for (b in 0 until blocks) {
                val nearOn = (b / 60) % 2 == 0
                val farOn = (b / 90) % 2 == 1
                for (k in 0 until n) {
                    val nearT = (idx % 267).toFloat() / 267f
                    val farT = (idx % 200).toFloat() / 200f
                    val nearW = if (nearT < 0.5f) 4f * nearT - 1f else 3f - 4f * nearT
                    val farW = if (farT < 0.5f) 4f * farT - 1f else 3f - 4f * farT
                    idx++
                    val noise = (rng.next() % 1000).toFloat() / 1_000_000f
                    x[k] = (if (nearOn) nearAmp * nearW else 0f) + noise
                    g.noteFar(if (farOn) farAmp * farW else 0f)
                }
                g.process(x, n)
                var sum = 0.0
                var peak = 0f
                for (k in 0 until n) { sum += x[k].toDouble() * x[k]; if (abs(x[k]) > peak) peak = abs(x[k]) }
                val exp = lines[i].split(",")
                i++
                assertEquals("$name block $b: index", b.toString(), exp[0])
                // Float arithmetic in the same order: exact to 1e-6 relative.
                assertEquals("$name block $b: rms", exp[3].toDouble(), sqrt(sum / n), 1e-6)
                assertEquals("$name block $b: peak", exp[4].toDouble(), peak.toDouble(), 1e-6)
                assertEquals("$name block $b: gain", exp[5].toDouble(), g.gain.toDouble(), 1e-6)
                assertEquals("$name block $b: vocal", exp[6].toInt(), g.vocal.v)
                assertEquals("$name block $b: quietMs", exp[7].toDouble(), g.quietMsNow, 1e-3)
                assertEquals("$name block $b: vocalMs", exp[8].toDouble(), g.vocalMsNow, 1e-3)
                blocksChecked++
            }
            val end = lines[i].split(",")
            i++
            assertEquals("$name: claims", end[1].toInt(), g.claims)
            assertEquals("$name: backchannels", end[2].toInt(), g.backchannels)
            assertEquals("$name: closedFrames", end[3].toInt(), g.closedFrames)
            assertEquals("$name: openFrames", end[4].toInt(), g.openFrames)
            assertEquals("$name: vetoFrames", end[5].toInt(), g.vetoFrames)
            assertEquals("$name: unvetoFrames", end[6].toInt(), g.unvetoFrames)
            assertEquals("$name: vetoArmedFrames", end[7].toInt(), g.vetoArmedFrames)
            assertEquals("$name: levelVoiceFrames", end[8].toInt(), g.levelVoiceFrames)
            assertEquals("$name: yieldSamples", end[9].toInt(), g.yieldSamples)
            scenarios++
        }
        assertEquals(11, scenarios)
        assertTrue("checked $blocksChecked blocks", blocksChecked >= 3000)
    }
}
