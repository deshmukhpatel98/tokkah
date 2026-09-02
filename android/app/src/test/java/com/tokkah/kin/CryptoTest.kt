package com.tokkah.kin

import com.tokkah.kin.net.Crypto
import com.tokkah.kin.net.Wire
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Vectors in /vectors/crypto.json are written by the Mac's own self-test
// (`tk --crypto-vectors <path>`): the handshake packets the shipped Crypto.swift
// signed and the packets it sealed. This port must VERIFY the former and open the
// latter byte for byte, and its own handshakes must be accepted by the same rules.
// (CryptoKit's Ed25519 is randomised, so the Mac's handshakes are checked, not
// compared; the derived keys are deterministic, so the sealed packets ARE compared.)
class CryptoTest {
    private val text by lazy { javaClass.getResourceAsStream("/vectors/crypto.json")!!.reader().readText() }
    private fun top(k: String) = Regex("\"$k\"\\s*:\\s*\"([^\"]*)\"").find(text)!!.groupValues[1]
    private fun side(side: String, k: String): String {
        val block = Regex("\"$side\"\\s*:\\s*\\{").find(text)!!
        val sub = text.substring(block.range.last, minOf(text.length, block.range.last + 4000))
        return Regex("\"$k\"\\s*:\\s*\"([^\"]*)\"").find(sub)!!.groupValues[1]
    }
    private fun list(k: String): List<String> {
        val arr = Regex("\"$k\"\\s*:\\s*\\[([^\\]]*)\\]").find(text)!!.groupValues[1]
        return Regex("\"([^\"]*)\"").findAll(arr).map { it.groupValues[1] }.toList()
    }
    private fun hex(s: String) = Crypto.hexToBytes(s)
    private val room get() = top("room")
    private val caps = Wire.CAP_PCM16 or Wire.CAP_PCM_LP

    private fun a(expected: ByteArray? = null) =
        Crypto(room, hex(side("a", "idSeedHex")), expected, hex(side("a", "privHex")))
    private fun b(expected: ByteArray? = null) =
        Crypto(room, hex(side("b", "idSeedHex")), expected, hex(side("b", "privHex")))
    private fun adopt(c: Crypto, p: ByteArray) = c.adoptHandshake(p, p.size)

    @Test
    fun publicKeysMatchCryptoKit() {
        assertArrayEquals(hex(side("a", "pubHex")), a().myPublic)
        assertArrayEquals(hex(side("b", "pubHex")), b().myPublic)
        assertArrayEquals(hex(side("a", "idPubHex")), a().myIdentity)
        assertArrayEquals(hex(side("b", "idPubHex")), b().myIdentity)
    }

    @Test
    fun macHandshakesVerifyAndKeyTheCall() {
        val a = a(); val b = b()
        // B adopts the Mac-signed A handshake; A adopts the Mac-signed B one.
        assertTrue(adopt(b, hex(side("a", "handshakeHex"))) is Crypto.Adopt.Adopted)
        assertTrue(adopt(a, hex(side("b", "handshakeHex"))) is Crypto.Adopt.Adopted)
        assertTrue(a.established && b.established)
        assertEquals(top("safetyCode"), a.safetyCode)
        assertEquals(top("safetyCode"), b.safetyCode)
    }

    @Test
    fun openMacSealedPacketsByteExact() {
        val a = a(); val b = b()
        assertTrue(adopt(b, hex(side("a", "handshakeHex"))) is Crypto.Adopt.Adopted)
        assertTrue(adopt(a, hex(side("b", "handshakeHex"))) is Crypto.Adopt.Adopted)
        val plains = list("plaintexts"); val pk = list("aToB")
        for ((i, msg) in plains.withIndex()) {
            assertEquals("packet $i", msg, String(b.open(hex(pk[i]))!!))
            // And this port seals the same bytes the Mac did: same key, same counter.
            assertArrayEquals("seal $i", hex(pk[i]), a.seal(msg.toByteArray()))
        }
    }

    @Test
    fun ownHandshakesKeyBothWays() {
        val a = a(); val b = b()
        assertTrue(adopt(b, a.handshakePacket(caps)) is Crypto.Adopt.Adopted)
        assertTrue(adopt(a, b.handshakePacket(caps)) is Crypto.Adopt.Adopted)
        assertEquals(top("safetyCode"), a.safetyCode)
        val p = a.seal("hello".toByteArray())!!
        assertEquals("hello", String(b.open(p)!!))
        // Same-key beat: unchanged, no verify spent.
        assertTrue(adopt(b, a.handshakePacket(caps)) is Crypto.Adopt.Unchanged)
        assertEquals(0, b.hsBadSig + b.hsWrongId + b.hsIdChanged)
    }

    @Test
    fun replayIsRefused() {
        val a = a(); val b = b()
        adopt(b, a.handshakePacket(caps)); adopt(a, b.handshakePacket(caps))
        val p1 = a.seal("one".toByteArray())!!
        assertNotNull(b.open(p1))
        assertNull("the same packet again", b.open(p1))
        assertEquals(1, b.replayDrops)
        // 2100 more; deliver the last, then the second-to-last (unseen, in the
        // window) and the first (older than the window).
        val late = (0 until 2100).map { a.seal("tick".toByteArray())!! }
        assertNotNull(b.open(late.last()))
        assertNotNull(b.open(late[late.size - 2]))
        assertNull(b.open(late[0]))
    }

    @Test
    fun wrongRoomIsRefused() {
        val c = Crypto("another-room", hex(side("b", "idSeedHex")), null, hex(side("b", "privHex")))
        val r = adopt(c, hex(side("a", "handshakeHex")))
        assertTrue(r is Crypto.Adopt.Refused)
        assertEquals(1, c.hsBadSig)
        assertFalse(c.established)
    }

    @Test
    fun unexpectedIdentityIsRefused() {
        val d = b(ByteArray(32) { 0x33 })
        assertTrue(adopt(d, hex(side("a", "handshakeHex"))) is Crypto.Adopt.Refused)
        assertEquals(1, d.hsWrongId)
        assertFalse(d.established)
        assertNull(d.seal("x".toByteArray()))
    }

    @Test
    fun expectedIdentityIsPinned() {
        val e = b(a().myIdentity)
        assertTrue(adopt(e, hex(side("a", "handshakeHex"))) is Crypto.Adopt.Adopted)
        assertTrue(e.pinned)
    }

    @Test
    fun secondIdentityMidCallIsRefused() {
        val b = b()
        adopt(b, hex(side("a", "handshakeHex")))
        val imp = Crypto(room, ByteArray(32) { 0x44 }, null, ByteArray(32) { 0x05 })
        assertTrue(adopt(b, imp.handshakePacket(caps)) is Crypto.Adopt.Refused)
        assertEquals(1, b.hsIdChanged)
        assertFalse(b.pinned)
    }

    @Test
    fun tamperedHandshakeIsRefused() {
        val bad = hex(side("a", "handshakeHex")); bad[100] = (bad[100].toInt() xor 1).toByte()
        val c1 = b(); assertTrue(adopt(c1, bad) is Crypto.Adopt.Refused); assertEquals(1, c1.hsBadSig)
        val badCaps = hex(side("a", "handshakeHex")); badCaps[36] = (badCaps[36].toInt() xor 1).toByte()
        val c2 = b(); assertTrue(adopt(c2, badCaps) is Crypto.Adopt.Refused); assertEquals(1, c2.hsBadSig)
        val old = ByteArray(40); Wire.putU32(old, 0, Wire.HMAGIC)
        val c3 = b(); assertTrue(adopt(c3, old) is Crypto.Adopt.Refused)
    }

    @Test
    fun nothingBeforeAKey() {
        val h = b()
        assertNull(h.seal("x".toByteArray()))
        assertNull(h.open(ByteArray(64)))
        assertNull(h.safetyCode)
    }

    @Test
    fun tamperedPacketFailsOpen() {
        val a = a(); val b = b()
        adopt(b, a.handshakePacket(caps)); adopt(a, b.handshakePacket(caps))
        val p = a.seal("hello".toByteArray())!!
        p[p.size - 1] = (p[p.size - 1].toInt() xor 1).toByte()
        assertNull(b.open(p))
        assertEquals(1, b.openFails)
        assertEquals(0, b.replayDrops)
    }
}
