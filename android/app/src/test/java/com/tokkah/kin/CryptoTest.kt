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
// (`tk --crypto-vectors <path>`, v3): the three handshake packets each end
// sends, from fixed ephemeral, identity and ML-KEM seeds and a fixed
// encapsulation m, plus the packets the Mac sealed under the resulting key.
// This port must VERIFY the Mac's signed packets (CryptoKit's Ed25519 is
// randomised, so they are checked, not compared), reproduce B's ciphertext
// byte for byte (the fixed m makes it deterministic), derive the same key, and
// open the Mac's sealed packets. Two implementations of X25519, Ed25519,
// HKDF, AES-GCM AND FIPS 203 held to each other.
class CryptoTest {
    private val text by lazy { javaClass.getResourceAsStream("/vectors/crypto.json")!!.reader().readText() }
    private fun top(k: String) = Regex("\"$k\"\\s*:\\s*\"([^\"]*)\"").find(text)!!.groupValues[1]
    private fun side(side: String, k: String): String {
        val block = Regex("\"$side\"\\s*:\\s*\\{").find(text)!!
        val sub = text.substring(block.range.last, minOf(text.length, block.range.last + 12000))
        return Regex("\"$k\"\\s*:\\s*\"([^\"]*)\"").find(sub)!!.groupValues[1]
    }
    private fun sideList(side: String, k: String): List<ByteArray> {
        val block = Regex("\"$side\"\\s*:\\s*\\{").find(text)!!
        val sub = text.substring(block.range.last, minOf(text.length, block.range.last + 12000))
        val arr = Regex("\"$k\"\\s*:\\s*\\[([^\\]]*)\\]").find(sub)!!.groupValues[1]
        return Regex("\"([0-9a-f]+)\"").findAll(arr).map { hex(it.groupValues[1]) }.toList()
    }
    private fun list(k: String): List<String> {
        val arr = Regex("\"$k\"\\s*:\\s*\\[([^\\]]*)\\]").find(text)!!.groupValues[1]
        return Regex("\"([^\"]*)\"").findAll(arr).map { it.groupValues[1] }.toList()
    }
    private fun hex(s: String) = Crypto.hexToBytes(s)
    private val room get() = top("room")
    private val caps = Wire.CAP_PCM16 or Wire.CAP_PCM_LP

    private fun a(expected: ByteArray? = null) = Crypto(room, hex(side("a", "idSeedHex")), expected,
        hex(side("a", "privHex")), hex(side("a", "kemSeedHex")))
    private fun b(expected: ByteArray? = null) = Crypto(room, hex(side("b", "idSeedHex")), expected,
        hex(side("b", "privHex")), hex(side("b", "kemSeedHex")), hex(side("b", "kemMHex")))
    private fun feed(c: Crypto, pkts: List<ByteArray>) = pkts.map { c.take(it, it.size) }
    private fun keyed(r: List<Crypto.Adopt>) = r.any { it is Crypto.Adopt.Keyed }
    private fun refused(r: List<Crypto.Adopt>) = r.count { it is Crypto.Adopt.Refused }

    @Test
    fun publicKeysMatchCryptoKit() {
        assertArrayEquals(hex(side("a", "pubHex")), a().myPublic)
        assertArrayEquals(hex(side("b", "pubHex")), b().myPublic)
        assertArrayEquals(hex(side("a", "idPubHex")), a().myIdentity)
        assertArrayEquals(hex(side("b", "idPubHex")), b().myIdentity)
        assertArrayEquals(hex(side("a", "kemPkHex")), a().myKemPk)
    }

    @Test
    fun macPacketsKeyBothEnds() {
        // The Mac's A beat (HS3 + halves) keys this B; the Mac's B beat (HS3 + halves + HSC) keys this A.
        val b = b(); val a = a()
        assertTrue(keyed(feed(b, sideList("a", "packetsHex"))))
        assertTrue(keyed(feed(a, sideList("b", "packetsHex"))))
        assertEquals(top("safetyCode"), a.safetyCode)
        assertEquals(top("safetyCode"), b.safetyCode)
    }

    @Test
    fun ownCiphertextMatchesTheMacsByteForByte() {
        // Same A key, same m: this B's HSC carries the Mac B's ciphertext.
        val b = b()
        feed(b, sideList("a", "packetsHex"))
        val mine = b.handshakePackets(caps)
        val macB = sideList("b", "packetsHex")
        assertEquals(4, mine.size); assertEquals(4, macB.size)
        val ctMine = mine[3].copyOfRange(36, 36 + 1088)
        val ctMac = macB[3].copyOfRange(36, 36 + 1088)
        assertArrayEquals(ctMac, ctMine)
    }

    @Test
    fun openMacSealedPacketsByteExact() {
        val b = b(); val a = a()
        feed(b, sideList("a", "packetsHex")); feed(a, sideList("b", "packetsHex"))
        val plains = list("plaintexts"); val pk = list("aToB")
        for ((i, msg) in plains.withIndex()) {
            assertEquals("packet $i", msg, String(b.open(hex(pk[i]))!!))
            assertArrayEquals("seal $i", hex(pk[i]), a.seal(msg.toByteArray()))
        }
    }

    @Test
    fun ownHandshakesKeyBothWaysEitherOrder() {
        // A first.
        var a = a(); var b = b()
        assertTrue(keyed(feed(b, a.handshakePackets(caps))))
        assertTrue(keyed(feed(a, b.handshakePackets(caps))))
        assertEquals(top("safetyCode"), a.safetyCode)
        assertEquals("hello", String(b.open(a.seal("hello".toByteArray())!!)!!))
        assertEquals("reply", String(a.open(b.seal("reply".toByteArray())!!)!!))
        // B first: A holds the offer, cannot key until the ciphertext.
        a = a(); b = b()
        assertFalse(keyed(feed(a, b.handshakePackets(caps))))
        assertFalse(a.established)
        assertTrue(keyed(feed(b, a.handshakePackets(caps))))
        assertTrue(keyed(feed(a, b.handshakePackets(caps))))
        assertEquals(a.safetyCode, b.safetyCode)
        // Same-key beat: unchanged, no verify spent.
        assertTrue(b.take(a.handshakePacket(caps), Crypto.HS_LEN) is Crypto.Adopt.Unchanged)
        assertEquals(0, b.hsBadSig + b.hsWrongId + b.hsIdChanged)
    }

    @Test
    fun keyedEndsBeatHs3Alone() {
        val a = a(); val b = b()
        feed(b, a.handshakePackets(caps)); feed(a, b.handshakePackets(caps))
        assertEquals(4, b.handshakePackets(caps).size)          // A has not proved the key yet
        assertNotNull(b.open(a.seal("x".toByteArray())!!))
        assertEquals(1, b.handshakePackets(caps).size)
    }

    @Test
    fun replayIsRefused() {
        val a = a(); val b = b()
        feed(b, a.handshakePackets(caps)); feed(a, b.handshakePackets(caps))
        val p1 = a.seal("one".toByteArray())!!
        assertNotNull(b.open(p1)); assertNull(b.open(p1)); assertEquals(1, b.replayDrops)
        val late = (0 until 2100).map { a.seal("tick".toByteArray())!! }
        assertNotNull(b.open(late.last())); assertNotNull(b.open(late[late.size - 2])); assertNull(b.open(late[0]))
    }

    @Test
    fun wrongRoomWrongIdentityRightIdentity() {
        val fresh = a().handshakePackets(caps)
        val c = Crypto("another-room", hex(side("b", "idSeedHex")), null, hex(side("b", "privHex")))
        assertEquals(1, refused(feed(c, listOf(fresh[0])))); assertEquals(1, c.hsBadSig)
        val d = b(ByteArray(32) { 0x33 })
        assertTrue(refused(feed(d, fresh)) >= 1); assertEquals(1, d.hsWrongId); assertFalse(d.established)
        val e = b(a().myIdentity)
        assertTrue(keyed(feed(e, fresh))); assertTrue(e.pinned)
        val imp = Crypto(room, ByteArray(32) { 0x44 }, null, ByteArray(32) { 0x05 })
        val bb = b(); feed(bb, fresh)
        assertEquals(1, refused(feed(bb, listOf(imp.handshakePacket(caps))))); assertEquals(1, bb.hsIdChanged)
    }

    @Test
    fun tamperingIsRefused() {
        val fresh = a().handshakePackets(caps)
        val bad = fresh[0].copyOf(); bad[130] = (bad[130].toInt() xor 1).toByte()
        val f = b(); assertEquals(1, refused(feed(f, listOf(bad)))); assertEquals(1, f.hsBadSig)
        val badHalf = fresh.map { it.copyOf() }; badHalf[1][100] = (badHalf[1][100].toInt() xor 1).toByte()
        val h = b(); assertFalse(keyed(feed(h, badHalf))); assertEquals(1, h.hsKemHashBad); assertFalse(h.established)
        // A tampered ciphertext fails its signature.
        val a2 = a(); val b2 = b()
        feed(b2, a2.handshakePackets(caps))
        val bPk = b2.handshakePackets(caps).map { it.copyOf() }
        bPk[3][200] = (bPk[3][200].toInt() xor 1).toByte()
        assertFalse(keyed(feed(a2, bPk))); assertFalse(a2.established); assertEquals(1, a2.hsCtRefused)
        // Old handshakes are refused by magic.
        val old = ByteArray(40); Wire.putU32(old, 0, Wire.HMAGIC)
        assertTrue(b().take(old, old.size) is Crypto.Adopt.Refused)
    }

    @Test
    fun nothingBeforeAKey() {
        val h = b()
        assertNull(h.seal("x".toByteArray())); assertNull(h.open(ByteArray(64))); assertNull(h.safetyCode)
    }

    @Test
    fun tamperedPacketFailsOpen() {
        val a = a(); val b = b()
        feed(b, a.handshakePackets(caps)); feed(a, b.handshakePackets(caps))
        val p = a.seal("hello".toByteArray())!!
        p[p.size - 1] = (p[p.size - 1].toInt() xor 1).toByte()
        assertNull(b.open(p)); assertEquals(1, b.openFails); assertEquals(0, b.replayDrops)
    }
}
