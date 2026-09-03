package com.tokkah.kin

import com.tokkah.kin.net.Crypto
import com.tokkah.kin.net.MlKem
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Two independent implementations of FIPS 203 held to each other: the Mac's
// Swift MlKem (which wrote /vectors/crypto.json) and BouncyCastle's here. Same
// (d, z) seed -> same encapsulation key; the Mac's ciphertext for a fixed m must
// decapsulate here to the Mac's secret; encapsulating here with the same m must
// reproduce the Mac's ciphertext byte for byte.
class MlKemTest {
    private val text by lazy { javaClass.getResourceAsStream("/vectors/crypto.json")!!.reader().readText() }
    private fun kem(k: String): ByteArray {
        val block = Regex("\"mlkem\"\\s*:\\s*\\{").find(text)!!
        val sub = text.substring(block.range.last)
        return Crypto.hexToBytes(Regex("\"$k\"\\s*:\\s*\"([0-9a-f]*)\"").find(sub)!!.groupValues[1])
    }

    @Test
    fun sizes() {
        assertEquals(1184, MlKem.PK_BYTES); assertEquals(1088, MlKem.CT_BYTES)
        val k = MlKem.generate()
        assertEquals(1184, k.publicKey.size)
        val e = MlKem.encapsulate(k.publicKey)!!
        assertEquals(1088, e.ciphertext.size); assertEquals(32, e.sharedSecret.size)
    }

    @Test
    fun sameSeedSameKeyAsTheMac() {
        val k = MlKem.fromSeed(kem("seedHex"))
        assertArrayEquals(kem("ekHex"), k.publicKey)
    }

    @Test
    fun macCiphertextDecapsulatesHere() {
        val k = MlKem.fromSeed(kem("seedHex"))
        assertArrayEquals(kem("ssHex"), k.decapsulate(kem("ctHex")))
    }

    @Test
    fun sameMessageSameCiphertextAsTheMac() {
        val e = MlKem.encapsulateWith(kem("ekHex"), kem("mHex"))!!
        assertArrayEquals(kem("ctHex"), e.ciphertext)
        assertArrayEquals(kem("ssHex"), e.sharedSecret)
    }

    @Test
    fun roundTripAndImplicitRejection() {
        val k = MlKem.generate()
        val e = MlKem.encapsulate(k.publicKey)!!
        assertArrayEquals(e.sharedSecret, k.decapsulate(e.ciphertext))
        val bad = e.ciphertext.copyOf(); bad[100] = (bad[100].toInt() xor 1).toByte()
        val rej = k.decapsulate(bad)
        assertNotNull(rej)
        assertFalse(rej!!.contentEquals(e.sharedSecret))
        assertNull(k.decapsulate(ByteArray(10)))
        assertNull(MlKem.encapsulate(ByteArray(5)))
    }
}
