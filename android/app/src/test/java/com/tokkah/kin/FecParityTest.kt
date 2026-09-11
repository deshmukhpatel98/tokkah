package com.tokkah.kin

import com.tokkah.kin.net.RecvRing
import com.tokkah.kin.net.Wire
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FecParityTest {

    @Test
    fun testBlockParityRecoveryBitExact() {
        val ring = RecvRing()
        val f8 = FloatArray(Wire.FPP) { it * 0.01f + 0.1f }
        val f9 = FloatArray(Wire.FPP) { it * 0.02f + 0.2f }
        val f10 = FloatArray(Wire.FPP) { it * 0.03f + 0.3f }
        val f11 = FloatArray(Wire.FPP) { it * 0.04f + 0.4f }

        // Compute bitwise XOR parity across f8, f9, f10, f11
        val par = FloatArray(Wire.FPP)
        for (k in 0 until Wire.FPP) {
            val pBits = java.lang.Float.floatToRawIntBits(f8[k]) xor
                        java.lang.Float.floatToRawIntBits(f9[k]) xor
                        java.lang.Float.floatToRawIntBits(f10[k]) xor
                        java.lang.Float.floatToRawIntBits(f11[k])
            par[k] = java.lang.Float.intBitsToFloat(pBits)
        }

        // Packets 8, 9, 11 arrive; 10 is lost
        ring.write(8, 8000L, f8, Wire.FPP)
        ring.write(9, 9000L, f9, Wire.FPP)
        ring.write(11, 11000L, f11, Wire.FPP)

        assertFalse("Packet 10 must be missing before parity recovery", ring.present(10))

        // Parity recovery logic
        val baseSeq = 8
        val count = 4
        var missingSeq = -1
        var missingCount = 0
        for (s in baseSeq until (baseSeq + count)) {
            if (!ring.present(s)) {
                missingSeq = s
                missingCount++
            }
        }
        assertEquals(1, missingCount)
        assertEquals(10, missingSeq)

        val rec = par.clone()
        val tmp = FloatArray(Wire.FPP)
        for (s in baseSeq until (baseSeq + count)) {
            if (s == missingSeq) continue
            assertTrue(ring.readSamples(s, tmp))
            for (k in 0 until Wire.FPP) {
                val pBits = java.lang.Float.floatToRawIntBits(rec[k]) xor java.lang.Float.floatToRawIntBits(tmp[k])
                rec[k] = java.lang.Float.intBitsToFloat(pBits)
            }
        }

        ring.write(missingSeq, 10000L, rec, Wire.FPP)
        assertTrue(ring.present(10))

        for (k in 0 until Wire.FPP) {
            val sample = ring.sampleAt((10 * Wire.FPP + k).toLong())
            assertEquals(
                "Sample $k of recovered packet 10 must match original bit-for-bit",
                java.lang.Float.floatToRawIntBits(f10[k]),
                java.lang.Float.floatToRawIntBits(sample)
            )
        }
    }
}
