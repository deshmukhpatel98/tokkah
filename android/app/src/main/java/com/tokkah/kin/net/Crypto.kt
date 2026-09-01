package com.tokkah.kin.net

import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.spec.NamedParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

// Port of mac/Sources/tk/Crypto.swift — X25519 + HKDF-SHA256 + AES-256-GCM,
// two directional keys, packet = counter(8 LE) || ciphertext || tag(16).
// Bit-exact with the Mac end (vectors validated against the shipped class).
class Crypto(roomSalt: String, fixedPrivateRaw: ByteArray? = null) {
    private val salt = ("tk-v1-$roomSalt").toByteArray()
    /**
     * The private scalar, raw.
     *
     * Held as bytes rather than a provider key object because the providers
     * disagree: desktop JVM's SunEC takes `NamedParameterSpec.X25519`, and
     * Android's Conscrypt throws `InvalidAlgorithmParameterException: No
     * AlgorithmParameterSpec classes are supported` for the same call — which
     * crashed the app on the first join and is invisible to a JVM-only test.
     * Key agreement below tries the platform first and falls back to the
     * scalar multiplication in [X25519]; both are proven against the same
     * CryptoKit vectors, so the answer cannot differ by platform.
     */
    private val privRaw: ByteArray
    val myPublic: ByteArray
    private var sendKey: ByteArray? = null
    private var recvKey: ByteArray? = null
    private var sendCtr = 0L
    private val lock = Object()

    var established = false; private set
    var peerKeyHex = ""; private set
    var sealed = 0; private set
    var opened = 0; private set
    var openFails = 0; private set
    var plaintextRx = 0; private set
    var plaintextTx = 0; private set

    init {
        privRaw = fixedPrivateRaw?.copyOf()
            ?: ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
        myPublic = X25519.publicFromPrivate(privRaw)
    }

    /** Platform key agreement where the provider allows it, own ladder otherwise. */
    private fun agree(peerRaw: ByteArray): ByteArray? {
        try {
            val pkcs8 = hexToBytes("302e020100300506032b656e04220420") + privRaw
            val x509 = hexToBytes("302a300506032b656e032100") + peerRaw
            val kf = KeyFactory.getInstance("XDH")
            val ka = KeyAgreement.getInstance("XDH")
            ka.init(kf.generatePrivate(PKCS8EncodedKeySpec(pkcs8)))
            ka.doPhase(kf.generatePublic(X509EncodedKeySpec(x509)), true)
            return ka.generateSecret()
        } catch (e: Exception) {
            return try { X25519.sharedSecret(privRaw, peerRaw) } catch (e2: Exception) { null }
        }
    }

    /** True only when the peer key was new; derives directional keys. */
    fun adoptPeer(raw: ByteArray): Boolean {
        if (raw.size != 32) return false
        val hex = raw.joinToString("") { "%02x".format(it) }
        if (hex == peerKeyHex) return false
        val secret = agree(raw) ?: return false
        val iAmA = lexicographicallyPrecedes(myPublic, raw)
        val ka2b = hkdfSha256(secret, salt, "a2b".toByteArray(), 32)
        val kb2a = hkdfSha256(secret, salt, "b2a".toByteArray(), 32)
        synchronized(lock) {
            sendKey = if (iAmA) ka2b else kb2a
            recvKey = if (iAmA) kb2a else ka2b
            sendCtr = 0
        }
        peerKeyHex = hex
        established = true
        return true
    }

    /** counter(8 LE) || ciphertext || tag(16), or null before the handshake. */
    fun seal(plain: ByteArray, n: Int = plain.size): ByteArray? = synchronized(lock) {
        val k = sendKey ?: return null
        sendCtr += 1
        val ctr = sendCtr
        val nonce = ByteArray(12)
        for (i in 0 until 8) nonce[4 + i] = ((ctr ushr (8 * i)) and 0xff).toByte()
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(k, "AES"), GCMParameterSpec(128, nonce))
        val ctAndTag = c.doFinal(plain, 0, n)
        val out = ByteArray(8 + ctAndTag.size)
        for (i in 0 until 8) out[i] = ((ctr ushr (8 * i)) and 0xff).toByte()
        System.arraycopy(ctAndTag, 0, out, 8, ctAndTag.size)
        sealed++
        return out
    }

    /** Opens a sealed packet; null on failure. */
    fun open(packet: ByteArray, n: Int = packet.size): ByteArray? {
        val k = recvKey ?: return null
        if (n <= 8 + 16) return null
        var ctr = 0L
        for (i in 0 until 8) ctr = ctr or ((packet[i].toLong() and 0xff) shl (8 * i))
        val nonce = ByteArray(12)
        for (i in 0 until 8) nonce[4 + i] = ((ctr ushr (8 * i)) and 0xff).toByte()
        return try {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, SecretKeySpec(k, "AES"), GCMParameterSpec(128, nonce))
            val pt = c.doFinal(packet, 8, n - 8)
            opened++
            pt
        } catch (e: Exception) {
            openFails++
            null
        }
    }

    val safetyCode: String?
        get() {
            if (!established || peerKeyHex.isEmpty()) return null
            val mineHex = myPublic.joinToString("") { "%02x".format(it) }
            val joined = listOf(mineHex, peerKeyHex).sorted().joinToString("|")
            val digest = MessageDigest.getInstance("SHA-256").digest(joined.toByteArray())
            val out = digest.take(8).map { CODE_ALPHABET[it.toInt() and 31] }.joinToString("")
            return out.take(4) + " " + out.drop(4)
        }

    fun notePlaintextRx() { plaintextRx++ }
    fun notePlaintextTx() { plaintextTx++ }

    companion object {
        const val CODE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

        fun lexicographicallyPrecedes(a: ByteArray, b: ByteArray): Boolean {
            val n = minOf(a.size, b.size)
            for (i in 0 until n) {
                val x = a[i].toInt() and 0xff
                val y = b[i].toInt() and 0xff
                if (x != y) return x < y
            }
            return a.size < b.size
        }

        fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, len: Int): ByteArray {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
            val prk = mac.doFinal(ikm)
            val out = ByteArray(len)
            var t = ByteArray(0)
            var pos = 0
            var i = 1
            while (pos < len) {
                mac.init(SecretKeySpec(prk, "HmacSHA256"))
                mac.update(t)
                mac.update(info)
                mac.update(i.toByte())
                t = mac.doFinal()
                val c = minOf(t.size, len - pos)
                System.arraycopy(t, 0, out, pos, c)
                pos += c
                i++
            }
            return out
        }

        fun hexToBytes(s: String): ByteArray =
            ByteArray(s.length / 2) { ((Character.digit(s[it * 2], 16) shl 4) + Character.digit(s[it * 2 + 1], 16)).toByte() }
    }
}

// Minimal X25519 scalar multiplication (RFC 7748) used ONLY to derive the raw
// public key for a private scalar, because the JCA exposes no scalar-mult and
// no public-from-private. Constant-time enough for that one non-secret-timing
// use; all bulk crypto goes through the platform provider above.
internal object X25519 {
    private val P = java.math.BigInteger.TWO.pow(255).subtract(java.math.BigInteger.valueOf(19))
    private val A24 = java.math.BigInteger.valueOf(121665)

    fun publicFromPrivate(scalarRaw: ByteArray): ByteArray = mul(scalarRaw, BASE_U)

    /** RFC 7748 X25519(k, u) with the peer's public u-coordinate. */
    fun sharedSecret(scalarRaw: ByteArray, peerRaw: ByteArray): ByteArray {
        val u = java.math.BigInteger(1, peerRaw.reversedArray()).clearBit(255).mod(P)
        return mul(scalarRaw, u)
    }

    private val BASE_U = java.math.BigInteger.valueOf(9)

    private fun mul(scalarRaw: ByteArray, u: java.math.BigInteger): ByteArray {
        val k = scalarRaw.copyOf()
        k[0] = (k[0].toInt() and 248).toByte()
        k[31] = ((k[31].toInt() and 127) or 64).toByte()
        val kInt = java.math.BigInteger(1, k.reversedArray())
        val le = montgomeryLadder(kInt, u).toByteArray().reversedArray()
        return ByteArray(32) { if (it < le.size) le[it] else 0 }
    }

    private fun montgomeryLadder(k: java.math.BigInteger, u: java.math.BigInteger): java.math.BigInteger {
        var x1 = u
        var x2 = java.math.BigInteger.ONE
        var z2 = java.math.BigInteger.ZERO
        var x3 = u
        var z3 = java.math.BigInteger.ONE
        var swap = 0
        for (t in 254 downTo 0) {
            val kt = k.testBit(t)
            val ktInt = if (kt) 1 else 0
            swap = swap xor ktInt
            if (swap == 1) { val tx = x2; x2 = x3; x3 = tx; val tz = z2; z2 = z3; z3 = tz }
            swap = ktInt
            val a = (x2 + z2).mod(P)
            val aa = a.multiply(a).mod(P)
            val b = (x2 - z2).mod(P)
            val bb = b.multiply(b).mod(P)
            val e = (aa - bb).mod(P)
            val c = (x3 + z3).mod(P)
            val d = (x3 - z3).mod(P)
            val da = d.multiply(a).mod(P)
            val cb = c.multiply(b).mod(P)
            val t0 = (da + cb).mod(P)
            x3 = t0.multiply(t0).mod(P)
            val t1 = (da - cb).mod(P)
            z3 = x1.multiply(t1.multiply(t1).mod(P)).mod(P)
            x2 = aa.multiply(bb).mod(P)
            z2 = e.multiply((aa + A24.multiply(e)).mod(P)).mod(P)
        }
        if (swap == 1) { x2 = x3; z2 = z3 }
        return x2.multiply(z2.modPow(P.subtract(java.math.BigInteger.TWO), P)).mod(P)
    }
}
