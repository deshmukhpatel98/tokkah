package com.tokkah.kin

import com.tokkah.kin.net.Floor
import com.tokkah.kin.net.Floor.Voice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

// Differential test: the same deterministic scripts driven through the SHIPPED
// Swift Floor (mac/Sources/tk/Floor.swift) produced floor.csv; the Kotlin port
// must reproduce every decision and every counter, block by block.
class FloorVectorTest {
    private class LCG(var s: Long) {
        fun next(): Long {
            s = s * 6364136223846793005L + 1442695040888963407L
            return (s ushr 33) and 0xffffffffL
        }
    }

    private fun voice(n: String) = when (n) {
        "QUIET" -> Voice.QUIET
        "BACKCHANNEL" -> Voice.BACKCHANNEL
        else -> Voice.CLAIM
    }

    @Test
    fun everyDecisionMatchesTheSwiftOriginal() {
        val lines = javaClass.getResourceAsStream("/vectors/floor.csv")!!.reader().readLines()
        var i = 0
        var scenarios = 0
        var rowsChecked = 0
        while (i < lines.size) {
            val header = lines[i]
            assertTrue("expected scenario header at $i, got: $header", header.startsWith("# "))
            val meta = header.removePrefix("# ").split("|")
            val name = meta[0]
            fun flag(k: String) = meta.first { it.startsWith("$k=") }.substringAfter("=")
            val f = Floor()
            f.cfg.strict = flag("strict") == "1"
            f.speakers = flag("speakers") == "1"
            f.yieldsOnTie = flag("tie") == "1"
            val g = LCG(flag("seed").toLong())
            val blocks = flag("blocks").toInt()
            i++

            var near = Voice.QUIET
            var far = Voice.QUIET
            var voicing = false
            var play = false
            var prob = 0.0
            for (b in 0 until blocks) {
                val r = g.next()
                if (b % 7 == 0) near = arrayOf(Voice.QUIET, Voice.BACKCHANNEL, Voice.CLAIM)[(r % 3).toInt()]
                if (b % 11 == 0) far = arrayOf(Voice.QUIET, Voice.BACKCHANNEL, Voice.CLAIM)[((r shr 3) % 3).toInt()]
                if (b % 13 == 0) voicing = (r shr 6) % 2 == 0L
                if (b % 5 == 0) play = (r shr 9) % 2 == 0L
                if (b % 17 == 0) prob = ((r shr 12) % 101).toDouble() / 100.0
                if (b % 23 == 0) f.farSeenTalking = when ((r shr 16) % 3) {
                    0L -> true; 1L -> false; else -> null
                }
                if (b % 29 == 0) f.nearVisualVoice = (r shr 20) % 2 == 0L
                if (b % 3 == 0) f.noteFar(far, transitMs = 40.0, voicing = voicing)
                f.notePlayout(play)
                f.noteEndProb(prob)
                f.noteFarEndProb(1.0 - prob)
                val d = f.step(0.02, near)

                val exp = lines[i].split(",")
                i++
                assertEquals("$name block $b: input drift (near)", exp[1], near.name)
                assertEquals("$name block $b: input drift (far)", exp[2], far.name)
                assertEquals("$name block $b: mayTransmit", exp[6], if (d.mayTransmit) "1" else "0")
                assertEquals("$name block $b: duckOnly", exp[7], if (d.duckOnly) "1" else "0")
                assertEquals("$name block $b: playoutOpen", exp[8], if (d.playoutOpen) "1" else "0")
                assertEquals("$name block $b: fallback", exp[9], if (d.fallback) "1" else "0")
                assertEquals("$name block $b: state", exp[10], d.state.name)
                rowsChecked++
            }
            val end = lines[i].split(",")
            i++
            assertEquals("$name: predictedReleases", end[1].toInt(), f.predictedReleases)
            assertEquals("$name: farPredictedReleases", end[2].toInt(), f.farPredictedReleases)
            assertEquals("$name: echoGuardBlocks", end[3].toInt(), f.echoGuardBlocks)
            assertEquals("$name: guardableBlocks", end[4].toInt(), f.guardableBlocks)
            assertEquals("$name: duplexBlocks", end[5].toInt(), f.duplexBlocks)
            assertEquals("$name: graceBlocks", end[6].toInt(), f.graceBlocks)
            assertEquals("$name: graceOnsets", end[7].toInt(), f.graceOnsets)
            assertEquals("$name: fastTakes", end[8].toInt(), f.fastTakes)
            assertEquals("$name: visualTakes", end[9].toInt(), f.visualTakes)
            assertEquals("$name: seenReleases", end[10].toInt(), f.seenReleases)
            scenarios++
        }
        assertEquals(5, scenarios)
        assertTrue("checked $rowsChecked blocks", rowsChecked >= 3000)
    }
}
