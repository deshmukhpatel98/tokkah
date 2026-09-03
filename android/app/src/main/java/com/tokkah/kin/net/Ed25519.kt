package com.tokkah.kin.net

/**
 * Ed25519 (RFC 8032) sign/verify over a 32-byte seed -- the device identity that
 * signs every ring, every media handshake, and verifies every release manifest.
 *
 * ONE PATH. BouncyCastle's RFC 8032 implementation, called directly: constant-time
 * field arithmetic, the same bytes on API 29 and on a desktop JVM, so the unit
 * tests run the code that ships. There is deliberately no platform lookup and no
 * fallback: the previous version tried `java.security` first (API 33+) and fell
 * back to BigInteger arithmetic that was not constant-time, which meant two
 * implementations and no way to tell from a test which one a phone was on.
 *
 * Deterministic (RFC 8032), so a signature over the same message is the same
 * bytes -- unlike CryptoKit's, which is randomised; both verify everywhere.
 */
object Ed25519 {
    fun publicFromSeed(seed: ByteArray): ByteArray {
        require(seed.size == 32) { "seed must be 32 bytes" }
        val pk = ByteArray(32)
        org.bouncycastle.math.ec.rfc8032.Ed25519.generatePublicKey(seed, 0, pk, 0)
        return pk
    }

    fun sign(seed: ByteArray, msg: ByteArray): ByteArray {
        require(seed.size == 32) { "seed must be 32 bytes" }
        val sig = ByteArray(64)
        org.bouncycastle.math.ec.rfc8032.Ed25519.sign(seed, 0, msg, 0, msg.size, sig, 0)
        return sig
    }

    fun verify(pub: ByteArray, msg: ByteArray, sig: ByteArray): Boolean {
        if (pub.size != 32 || sig.size != 64) return false
        return try {
            org.bouncycastle.math.ec.rfc8032.Ed25519.verify(sig, 0, pub, 0, msg, 0, msg.size)
        } catch (e: Exception) { false }
    }
}
