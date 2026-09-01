package com.tokkah.kin

import com.tokkah.kin.net.Lpc
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LpcTest {
    // Hand-rolled parser for the fixed vector shape — no JSON dependency in JVM tests.
    private data class Case(val name: String, val n: Int, val samples: ShortArray, val encoded: ByteArray)

    private fun loadCases(): List<Case> {
        val text = javaClass.getResourceAsStream("/vectors/lpc.json")!!.reader().readText()
        val cases = mutableListOf<Case>()
        val caseRe = Regex("\\{[^{}]*\"name\"[^{}]*\\}")
        for (m in caseRe.findAll(text)) {
            val c = m.value
            fun str(k: String) = Regex("\"$k\"\\s*:\\s*\"([^\"]*)\"").find(c)!!.groupValues[1]
            fun int(k: String) = Regex("\"$k\"\\s*:\\s*(-?\\d+)").find(c)!!.groupValues[1].toInt()
            val samples = Regex("\"samples\"\\s*:\\s*\\[([^\\]]*)\\]").find(c)!!.groupValues[1]
                .split(',').filter { it.isNotBlank() }.map { it.trim().toInt().toShort() }.toShortArray()
            val enc = str("encoded")
            val bytes = ByteArray(enc.length / 2) {
                ((Character.digit(enc[it * 2], 16) shl 4) + Character.digit(enc[it * 2 + 1], 16)).toByte()
            }
            cases.add(Case(str("name"), int("n"), samples, bytes))
        }
        return cases
    }

    @Test
    fun encodeMatchesSwiftByteExact() {
        val cases = loadCases()
        assertTrue("vectors present", cases.size >= 12)
        for (c in cases) {
            val out = ByteArray(Lpc.bound(c.n) + 64)
            val m = Lpc.encode(c.samples, c.n, out)
            assertEquals("${c.name}: length", c.encoded.size, m)
            assertArrayEquals("${c.name}: bytes", c.encoded, out.copyOf(m))
        }
    }

    @Test
    fun decodeSwiftBytesSampleExact() {
        for (c in loadCases()) {
            val out = ShortArray(c.n)
            assertTrue("${c.name}: decode ok", Lpc.decode(c.encoded, c.encoded.size, c.n, out))
            assertArrayEquals("${c.name}: samples", c.samples, out)
        }
    }

    @Test
    fun corruptPacketFailsNotCrashes() {
        val samples = ShortArray(32) { (it * 1000 - 16000).toShort() }
        val out = ByteArray(Lpc.bound(32))
        val m = Lpc.encode(samples, 32, out)
        val dec = ShortArray(32)
        // Truncations must return false, never throw.
        for (len in 0 until m) Lpc.decode(out, len, 32, dec)
    }
}
