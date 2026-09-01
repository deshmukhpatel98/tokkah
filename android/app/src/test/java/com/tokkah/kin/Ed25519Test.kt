package com.tokkah.kin

import com.tokkah.kin.net.Crypto
import com.tokkah.kin.net.Ed25519
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// Validate the ruler on known answers, including inputs it must REFUSE.
// Vectors are RFC 8032 §7.1 plus the app's own signed domains, produced by the
// CryptoKit that signs every ring on the Mac.
class Ed25519Test {
    private class V(val kind: String, val seed: ByteArray, val pub: ByteArray,
                    val msg: ByteArray, val sig: ByteArray)

    private fun vectors(): List<V> =
        javaClass.getResourceAsStream("/vectors/ed25519.csv")!!.reader().readLines()
            .filter { it.isNotBlank() }.map { line ->
                val p = line.split(",")
                val msg = if (p[3].startsWith("UTF8:")) p[3].removePrefix("UTF8:").toByteArray()
                          else Crypto.hexToBytes(p[3])
                V(p[0], Crypto.hexToBytes(p[1]), Crypto.hexToBytes(p[2]), msg, Crypto.hexToBytes(p[4]))
            }

    @Test
    fun publicKeyFromSeedMatches() {
        for (v in vectors()) assertArrayEquals(v.pub, Ed25519.publicFromSeed(v.seed))
    }

    @Test
    fun signaturesAreByteExactAgainstRfc8032() {
        // Only the "det" rows: CryptoKit's Ed25519 is randomized by design, so
        // its signatures are not the deterministic ones and cannot be compared
        // byte for byte. The generator makes CryptoKit VERIFY each of these,
        // so the Mac accepting what this port produces is proven, not assumed.
        val det = vectors().filter { it.kind == "det" }
        assertEquals(3, det.size)
        for (v in det) assertArrayEquals("msg=${String(v.msg)}", v.sig, Ed25519.sign(v.seed, v.msg))
    }

    @Test
    fun verifiesSignaturesTheMacActuallyProduced() {
        // The real interop requirement, over this app's own signed domains.
        val ck = vectors().filter { it.kind == "ck" }
        assertEquals(4, ck.size)
        for (v in ck) assertTrue(String(v.msg), Ed25519.verify(v.pub, v.msg, v.sig))
    }

    @Test
    fun verifyAcceptsGoodSignatures() {
        for (v in vectors()) assertTrue(Ed25519.verify(v.pub, v.msg, v.sig))
    }

    @Test
    fun verifyRefusesWhatItMust() {
        val v = vectors().last()
        // A flipped signature bit.
        val bad = v.sig.copyOf(); bad[10] = (bad[10].toInt() xor 1).toByte()
        assertFalse("tampered signature", Ed25519.verify(v.pub, v.msg, bad))
        // A different message under a good signature — the swap the ring domain
        // separation exists to stop.
        assertFalse("wrong message",
            Ed25519.verify(v.pub, "kin-ring-v1|arjun|devesh|other-room|1800000000".toByteArray(), v.sig))
        // A different signer.
        val otherPub = Ed25519.publicFromSeed(ByteArray(32) { 7 })
        assertFalse("wrong key", Ed25519.verify(otherPub, v.msg, v.sig))
        // Malformed inputs.
        assertFalse(Ed25519.verify(ByteArray(31), v.msg, v.sig))
        assertFalse(Ed25519.verify(v.pub, v.msg, ByteArray(63)))
    }

    @Test
    fun byeSignsADifferentDomainThanRing() {
        val seed = ByteArray(32) { it.toByte() }
        val pub = Ed25519.publicFromSeed(seed)
        val ring = "kin-ring-v1|a|b|room|100".toByteArray()
        val bye = "kin-bye-v1|a|b|room|100".toByteArray()
        val sigBye = Ed25519.sign(seed, bye)
        // An older client verifying a bye against the ring domain must FAIL —
        // that is the whole compatibility story.
        assertFalse(Ed25519.verify(pub, ring, sigBye))
        assertTrue(Ed25519.verify(pub, bye, sigBye))
    }

    @Test
    fun roundTripsRandomMessages() {
        val seed = ByteArray(32) { (it * 7 + 3).toByte() }
        val pub = Ed25519.publicFromSeed(seed)
        for (n in intArrayOf(0, 1, 31, 32, 33, 64, 200)) {
            val msg = ByteArray(n) { (it * 13).toByte() }
            assertTrue("len $n", Ed25519.verify(pub, msg, Ed25519.sign(seed, msg)))
        }
    }

    @Test
    fun signIsDeterministic() {
        val seed = ByteArray(32) { 5 }
        val msg = "kin-reg-v1|kin|tok|1".toByteArray()
        assertArrayEquals(Ed25519.sign(seed, msg), Ed25519.sign(seed, msg))
    }
}
