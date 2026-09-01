package com.tokkah.kin

import com.tokkah.kin.net.Crypto
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Vectors in /vectors/crypto.json were generated with CryptoKit and validated
// in both directions against the shipped mac/Sources/tk/Crypto.swift class.
class CryptoTest {
    private val text by lazy { javaClass.getResourceAsStream("/vectors/crypto.json")!!.reader().readText() }
    private fun top(k: String) = Regex("\"$k\"\\s*:\\s*\"([^\"]*)\"").find(text)!!.groupValues[1]
    private fun side(side: String, k: String): String {
        val block = Regex("\"$side\"\\s*:\\s*\\{").find(text)!!
        val sub = text.substring(block.range.last, minOf(text.length, block.range.last + 4000))
        return Regex("\"$k\"\\s*:\\s*\"([^\"]*)\"").find(sub)!!.groupValues[1]
    }
    private fun packets(side: String): List<ByteArray> {
        val block = Regex("\"$side\"\\s*:\\s*\\{").find(text)!!
        val sub = text.substring(block.range.last)
        val arr = Regex("\"packets\"\\s*:\\s*\\[([^\\]]*)\\]").find(sub)!!.groupValues[1]
        return Regex("\"([0-9a-f]+)\"").findAll(arr).map { hex(it.groupValues[1]) }.toList()
    }
    private fun plaintexts(): List<String> {
        val arr = Regex("\"plaintexts\"\\s*:\\s*\\[([^\\]]*)\\]").find(text)!!.groupValues[1]
        return Regex("\"([^\"]*)\"").findAll(arr).map { it.groupValues[1] }.toList()
    }
    private fun hex(s: String) = Crypto.hexToBytes(s)

    private fun pair(): Pair<Crypto, Crypto> {
        val a = Crypto(top("roomSalt"), hex(side("a", "privHex")))
        val b = Crypto(top("roomSalt"), hex(side("b", "privHex")))
        return a to b
    }

    @Test
    fun publicKeysMatchCryptoKit() {
        val (a, b) = pair()
        assertArrayEquals(hex(side("a", "pubHex")), a.myPublic)
        assertArrayEquals(hex(side("b", "pubHex")), b.myPublic)
    }

    @Test
    fun hkdfMatches() {
        val ikm = Regex("\"ikmUtf8\"\\s*:\\s*\"([^\"]*)\"").find(text)!!.groupValues[1]
        val salt = Regex("\"saltUtf8\"\\s*:\\s*\"([^\"]*)\"").find(text)!!.groupValues[1]
        val info = Regex("\"infoUtf8\"\\s*:\\s*\"([^\"]*)\"").find(text)!!.groupValues[1]
        val okm = Regex("\"okmHex\"\\s*:\\s*\"([^\"]*)\"").find(text)!!.groupValues[1]
        assertArrayEquals(hex(okm),
            Crypto.hkdfSha256(ikm.toByteArray(), salt.toByteArray(), info.toByteArray(), hex(okm).size))
    }

    @Test
    fun sealMatchesSwiftPacketsByteExact() {
        val (a, b) = pair()
        assertTrue(a.adoptPeer(b.myPublic))
        assertTrue(b.adoptPeer(a.myPublic))
        val pa = packets("a"); val pb = packets("b")
        for ((i, msg) in plaintexts().withIndex()) {
            assertArrayEquals("a pkt $i", pa[i], a.seal(msg.toByteArray()))
            assertArrayEquals("b pkt $i", pb[i], b.seal(msg.toByteArray()))
        }
    }

    @Test
    fun openSwiftPackets() {
        val (a, b) = pair()
        assertTrue(a.adoptPeer(b.myPublic))
        assertTrue(b.adoptPeer(a.myPublic))
        for ((i, msg) in plaintexts().withIndex()) {
            assertEquals(msg, String(a.open(packets("b")[i])!!))
            assertEquals(msg, String(b.open(packets("a")[i])!!))
        }
    }

    @Test
    fun safetyCodeMatches() {
        val (a, b) = pair()
        assertTrue(a.adoptPeer(b.myPublic))
        assertTrue(b.adoptPeer(a.myPublic))
        assertEquals(top("safetyCode"), a.safetyCode)
        assertEquals(top("safetyCodeB"), b.safetyCode)
    }

    @Test
    fun adoptPeerSemantics() {
        val (a, b) = pair()
        assertTrue(a.adoptPeer(b.myPublic))
        assertFalse("same key again is not new", a.adoptPeer(b.myPublic))
        assertFalse(a.adoptPeer(ByteArray(31)))
    }

    @Test
    fun tamperedPacketFailsOpen() {
        val (a, b) = pair()
        assertTrue(a.adoptPeer(b.myPublic))
        assertTrue(b.adoptPeer(a.myPublic))
        val p = a.seal("hello".toByteArray())!!
        p[p.size - 1] = (p[p.size - 1].toInt() xor 1).toByte()
        assertNull(b.open(p))
    }
}
