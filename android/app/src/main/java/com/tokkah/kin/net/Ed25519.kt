package com.tokkah.kin.net

import java.math.BigInteger
import java.security.MessageDigest

/**
 * Ed25519 (RFC 8032) sign/verify over a 32-byte seed.
 *
 * Hand-rolled because the platform will not do it: java.security's "Ed25519"
 * arrived in API 33 and Kin runs from API 29, and its KeyFactory cannot import
 * a raw seed anyway — which is exactly what identity.json holds, and what the
 * server's `k` field and every `kin-*-v1` signature are defined over.
 *
 * BigInteger, not constant-time. That is acceptable here and nowhere else: this
 * key signs ring messages, it never establishes a session secret (X25519 in
 * Crypto.kt does that, through the platform provider), and the signatures it
 * produces are public by construction.
 */
object Ed25519 {
    private val P = BigInteger.TWO.pow(255).subtract(BigInteger.valueOf(19))
    private val L = BigInteger("7237005577332262213973186563042994240857116359379907606001950938285454250989")
    private val D = BigInteger("-121665").multiply(BigInteger.valueOf(121666).modInverse(P)).mod(P)
    private val I = BigInteger.TWO.modPow(P.subtract(BigInteger.ONE).divide(BigInteger.valueOf(4)), P)
    private val BY = BigInteger.valueOf(4).multiply(BigInteger.valueOf(5).modInverse(P)).mod(P)
    private val BX = xRecover(BY)
    private val B = arrayOf(BX, BY, BigInteger.ONE, BX.multiply(BY).mod(P))

    private fun xRecover(y: BigInteger): BigInteger {
        val yy = y.multiply(y).mod(P)
        val u = yy.subtract(BigInteger.ONE).mod(P)
        val v = D.multiply(yy).add(BigInteger.ONE).mod(P)
        var x = u.multiply(v.modPow(BigInteger.valueOf(3), P)).multiply(
            u.multiply(v.modPow(BigInteger.valueOf(7), P))
                .modPow(P.subtract(BigInteger.valueOf(5)).divide(BigInteger.valueOf(8)), P)).mod(P)
        if (v.multiply(x).multiply(x).subtract(u).mod(P) != BigInteger.ZERO) x = x.multiply(I).mod(P)
        if (x.testBit(0)) x = P.subtract(x)
        return x
    }

    // Extended (X:Y:Z:T) coordinates.
    private fun edAdd(p: Array<BigInteger>, q: Array<BigInteger>): Array<BigInteger> {
        val a = p[1].subtract(p[0]).multiply(q[1].subtract(q[0])).mod(P)
        val b = p[1].add(p[0]).multiply(q[1].add(q[0])).mod(P)
        val c = p[3].multiply(BigInteger.TWO).multiply(D).multiply(q[3]).mod(P)
        val dd = p[2].multiply(BigInteger.TWO).multiply(q[2]).mod(P)
        val e = b.subtract(a); val f = dd.subtract(c); val g = dd.add(c); val h = b.add(a)
        return arrayOf(e.multiply(f).mod(P), g.multiply(h).mod(P),
            f.multiply(g).mod(P), e.multiply(h).mod(P))
    }

    private fun scalarMul(p: Array<BigInteger>, e: BigInteger): Array<BigInteger> {
        var q = arrayOf(BigInteger.ZERO, BigInteger.ONE, BigInteger.ONE, BigInteger.ZERO)
        var acc = p
        var k = e
        while (k.signum() > 0) {
            if (k.testBit(0)) q = edAdd(q, acc)
            acc = edAdd(acc, acc)
            k = k.shiftRight(1)
        }
        return q
    }

    private fun encodePoint(p: Array<BigInteger>): ByteArray {
        val zi = p[2].modInverse(P)
        val x = p[0].multiply(zi).mod(P)
        val y = p[1].multiply(zi).mod(P)
        val out = leBytes(y, 32)
        if (x.testBit(0)) out[31] = (out[31].toInt() or 0x80).toByte()
        return out
    }

    private fun decodePoint(b: ByteArray): Array<BigInteger>? {
        val y = leInt(b).clearBit(255)
        if (y >= P) return null
        var x = xRecover(y)
        if (x.testBit(0) != ((b[31].toInt() and 0x80) != 0)) x = P.subtract(x)
        val p = arrayOf(x, y, BigInteger.ONE, x.multiply(y).mod(P))
        // On the curve? -x^2 + y^2 = 1 + d x^2 y^2
        val xx = x.multiply(x).mod(P); val yy = y.multiply(y).mod(P)
        val lhs = yy.subtract(xx).mod(P)
        val rhs = BigInteger.ONE.add(D.multiply(xx).multiply(yy)).mod(P)
        return if (lhs == rhs) p else null
    }

    private fun leBytes(v: BigInteger, n: Int): ByteArray {
        val be = v.toByteArray()
        val out = ByteArray(n)
        var i = 0
        var j = be.size - 1
        while (i < n && j >= 0) { out[i] = be[j]; i++; j-- }
        return out
    }

    private fun leInt(b: ByteArray): BigInteger = BigInteger(1, b.reversedArray())

    private fun sha512(vararg parts: ByteArray): ByteArray {
        val md = MessageDigest.getInstance("SHA-512")
        for (p in parts) md.update(p)
        return md.digest()
    }

    private fun clamp(h: ByteArray): BigInteger {
        val a = h.copyOf(32)
        a[0] = (a[0].toInt() and 248).toByte()
        a[31] = ((a[31].toInt() and 63) or 64).toByte()
        return leInt(a)
    }

    fun publicFromSeed(seed: ByteArray): ByteArray {
        require(seed.size == 32) { "seed must be 32 bytes" }
        return encodePoint(scalarMul(B, clamp(sha512(seed))))
    }

    fun sign(seed: ByteArray, msg: ByteArray): ByteArray {
        require(seed.size == 32) { "seed must be 32 bytes" }
        val h = sha512(seed)
        val a = clamp(h)
        val prefix = h.copyOfRange(32, 64)
        val pub = encodePoint(scalarMul(B, a))
        val r = leInt(sha512(prefix, msg)).mod(L)
        val rPoint = encodePoint(scalarMul(B, r))
        val k = leInt(sha512(rPoint, pub, msg)).mod(L)
        val s = r.add(k.multiply(a)).mod(L)
        return rPoint + leBytes(s, 32)
    }

    fun verify(pub: ByteArray, msg: ByteArray, sig: ByteArray): Boolean {
        if (pub.size != 32 || sig.size != 64) return false
        return try {
            val rPoint = decodePoint(sig.copyOf(32)) ?: return false
            val aPoint = decodePoint(pub) ?: return false
            val s = leInt(sig.copyOfRange(32, 64))
            if (s >= L) return false
            val k = leInt(sha512(sig.copyOf(32), pub, msg)).mod(L)
            val lhs = scalarMul(B, s)
            val rhs = edAdd(rPoint, scalarMul(aPoint, k))
            encodePoint(lhs).contentEquals(encodePoint(rhs))
        } catch (e: Exception) { false }
    }
}
