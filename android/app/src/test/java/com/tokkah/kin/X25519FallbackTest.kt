package com.tokkah.kin

import com.tokkah.kin.net.Crypto
import com.tokkah.kin.net.X25519
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The fallback path must give the same answer as the platform provider, or the
 * two ends of a call disagree by platform. Android's Conscrypt refuses
 * NamedParameterSpec (it crashed the app on its first join), so the fallback is
 * not hypothetical — on a phone it may be the path that actually runs.
 */
class X25519FallbackTest {
    private val text by lazy { javaClass.getResourceAsStream("/vectors/crypto.json")!!.reader().readText() }
    private fun top(k: String) = Regex("\"$k\"\\s*:\\s*\"([^\"]*)\"").find(text)!!.groupValues[1]
    private fun side(s: String, k: String): String {
        val b = Regex("\"$s\"\\s*:\\s*\\{").find(text)!!
        val sub = text.substring(b.range.last, minOf(text.length, b.range.last + 4000))
        return Regex("\"$k\"\\s*:\\s*\"([^\"]*)\"").find(sub)!!.groupValues[1]
    }
    private fun hex(s: String) = Crypto.hexToBytes(s)

    @Test
    fun sharedSecretMatchesCryptoKit() {
        val a = hex(side("a", "privHex"))
        val bPub = hex(side("b", "pubHex"))
        val b = hex(side("b", "privHex"))
        val aPub = hex(side("a", "pubHex"))
        val expected = hex(top("sharedSecretHex"))
        // Own ladder, both directions.
        assertArrayEquals("A·bPub", expected, X25519.sharedSecret(a, bPub))
        assertArrayEquals("B·aPub", expected, X25519.sharedSecret(b, aPub))
    }

    @Test
    fun publicKeysMatchCryptoKit() {
        assertArrayEquals(hex(side("a", "pubHex")), X25519.publicFromPrivate(hex(side("a", "privHex"))))
        assertArrayEquals(hex(side("b", "pubHex")), X25519.publicFromPrivate(hex(side("b", "privHex"))))
    }

    @Test
    fun rfc7748Vector() {
        // RFC 7748 §5.2: a known scalar and u-coordinate with a published answer.
        val k = hex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4")
        val u = hex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")
        val want = hex("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
        assertArrayEquals(want, X25519.sharedSecret(k, u))
    }

    @Test
    fun twoFreshSessionsAgree() {
        // Whatever path each Crypto instance takes, the pair must derive the
        // same keys and the same safety code.
        val a = Crypto("a-room")
        val b = Crypto("a-room")
        assertTrue(a.adoptPeer(b.myPublic))
        assertTrue(b.adoptPeer(a.myPublic))
        assertEquals(a.safetyCode, b.safetyCode)
        val msg = "one voice at a time".toByteArray()
        assertArrayEquals(msg, b.open(a.seal(msg)!!))
        assertArrayEquals(msg, a.open(b.seal(msg)!!))
    }
}
