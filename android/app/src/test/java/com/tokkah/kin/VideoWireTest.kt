package com.tokkah.kin

import com.tokkah.kin.net.Crypto
import com.tokkah.kin.net.VideoAssembler
import com.tokkah.kin.net.VideoWire
import com.tokkah.kin.net.Wire
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoWireTest {
    private class C(val name: String, val sets: List<ByteArray>, val sample: ByteArray,
                    val serialized: ByteArray, val frags: List<Triple<Int, Int, Int>>)

    private fun cases(): List<C> =
        javaClass.getResourceAsStream("/vectors/video.csv")!!.reader().readLines()
            .filter { it.isNotBlank() }.map { line ->
                val p = line.split("|")
                val sets = if (p[1].isEmpty()) emptyList()
                           else p[1].split(";").map { Crypto.hexToBytes(it) }
                val frags = p[4].split(" ").map {
                    val f = it.split(","); Triple(f[0].toInt(), f[1].toInt(), f[2].toInt())
                }
                C(p[0], sets, Crypto.hexToBytes(p[2]), Crypto.hexToBytes(p[3]), frags)
            }

    @Test
    fun serializeMatchesTheMacByteForByte() {
        val cs = cases()
        assertEquals(6, cs.size)
        for (c in cs) assertArrayEquals(c.name, c.serialized, VideoWire.serialize(c.sets, c.sample))
    }

    @Test
    fun parseRecoversSetsAndSample() {
        for (c in cases()) {
            val f = VideoWire.parse(c.serialized, c.serialized.size)!!
            assertEquals(c.name, c.sets.size, f.parameterSets.size)
            for (i in c.sets.indices) assertArrayEquals(c.name, c.sets[i], f.parameterSets[i])
            assertArrayEquals(c.name, c.sample, f.avcc)
            assertEquals(c.name, c.sets.isNotEmpty(), f.isKeyframe)
        }
    }

    @Test
    fun fragmentationMatchesTheMacsBoundaries() {
        for (c in cases()) {
            val n = c.serialized.size
            val nfrag = maxOf(1, (n + Wire.VPAYLOAD - 1) / Wire.VPAYLOAD)
            assertEquals(c.name, c.frags.size, nfrag)
            for ((f, expNfrag, expLen) in c.frags) {
                val off = f * Wire.VPAYLOAD
                val len = minOf(Wire.VPAYLOAD, n - off)
                assertEquals("${c.name} frag $f nfrag", expNfrag, nfrag)
                assertEquals("${c.name} frag $f len", expLen, len)
            }
        }
    }

    @Test
    fun fragmentsReassembleToTheSameFrame() {
        val asm = VideoAssembler()
        var seq = 0
        for (c in cases()) {
            val n = c.serialized.size
            val nfrag = maxOf(1, (n + Wire.VPAYLOAD - 1) / Wire.VPAYLOAD)
            var got: ByteArray? = null
            val out = ByteArray(Wire.VHDR + Wire.VPAYLOAD)
            for (f in 0 until nfrag) {
                val off = f * Wire.VPAYLOAD
                val len = minOf(Wire.VPAYLOAD, n - off)
                val m = Wire.packVideoFragment(seq, 12345L, f, nfrag, c.serialized, off, len, out)
                val h = Wire.videoHeader(out, m)!!
                asm.offer(h, out, Wire.VHDR, len)?.let { got = it.first }
            }
            assertNotNull("${c.name}: reassembled", got)
            assertArrayEquals(c.name, c.serialized, got)
            seq++
        }
    }

    @Test
    fun aLostFragmentYieldsNothingRatherThanGarbage() {
        val c = cases().first { it.name == "keyframe-big" }
        val asm = VideoAssembler()
        val n = c.serialized.size
        val nfrag = (n + Wire.VPAYLOAD - 1) / Wire.VPAYLOAD
        assertTrue(nfrag > 2)
        val out = ByteArray(Wire.VHDR + Wire.VPAYLOAD)
        for (f in 0 until nfrag) {
            if (f == 1) continue                     // drop one
            val off = f * Wire.VPAYLOAD
            val len = minOf(Wire.VPAYLOAD, n - off)
            val m = Wire.packVideoFragment(7, 1L, f, nfrag, c.serialized, off, len, out)
            assertNull(asm.offer(Wire.videoHeader(out, m)!!, out, Wire.VHDR, len))
        }
    }

    @Test
    fun annexBAvccRoundTrip() {
        // What MediaCodec emits (Annex-B) must become exactly what the Mac reads.
        val nal1 = ByteArray(23) { (it + 1).toByte() }
        val nal2 = ByteArray(8) { (it + 40).toByte() }
        val annexB = byteArrayOf(0, 0, 0, 1) + nal1 + byteArrayOf(0, 0, 1) + nal2
        val avcc = VideoWire.annexBToAvcc(annexB, 0, annexB.size)
        assertEquals(4 + 23 + 4 + 8, avcc.size)
        val back = ByteArray(avcc.size + 16)
        val m = VideoWire.avccToAnnexB(avcc, back)
        val nals = VideoWire.splitAnnexB(back, 0, m)
        assertEquals(2, nals.size)
        assertArrayEquals(nal1, nals[0])
        assertArrayEquals(nal2, nals[1])
    }

    @Test
    fun truncatedPayloadsAreRefused() {
        val c = cases().first()
        for (len in 0 until minOf(40, c.serialized.size)) {
            // Never throw; either null or a frame whose declared lengths fit.
            VideoWire.parse(c.serialized, len)
        }
        assertNull(VideoWire.parse(c.serialized, 4))
    }
}
