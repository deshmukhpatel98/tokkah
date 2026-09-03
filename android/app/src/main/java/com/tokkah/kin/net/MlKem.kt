package com.tokkah.kin.net

import org.bouncycastle.pqc.crypto.mlkem.MLKEMExtractor
import org.bouncycastle.pqc.crypto.mlkem.MLKEMGenerator
import org.bouncycastle.pqc.crypto.mlkem.MLKEMKeyGenerationParameters
import org.bouncycastle.pqc.crypto.mlkem.MLKEMKeyPairGenerator
import org.bouncycastle.pqc.crypto.mlkem.MLKEMParameters
import org.bouncycastle.pqc.crypto.mlkem.MLKEMPrivateKeyParameters
import org.bouncycastle.pqc.crypto.mlkem.MLKEMPublicKeyParameters
import java.security.SecureRandom

/**
 * ML-KEM-768 (FIPS 203), through BouncyCastle's implementation, called directly.
 * The post-quantum half of the call's key exchange; the Mac end is a Swift
 * implementation of the same standard (mac/Sources/tk/MlKem.swift), and the two
 * are held to each other in CryptoTest: a key generated from the same (d, z)
 * seed must encode to the same bytes, and a ciphertext made on one must
 * decapsulate on the other to the same secret.
 *
 * Sizes: encapsulation key 1184 B, ciphertext 1088 B, shared secret 32 B,
 * decapsulation key held here as its 64-byte seed (d || z) and re-derived.
 */
class MlKem private constructor(private val priv: MLKEMPrivateKeyParameters, val seed: ByteArray) {
    val publicKey: ByteArray get() = priv.publicKey

    /** Decapsulate [ct] (1088 B) to the 32-byte shared secret. Never throws on a
     *  bad ciphertext: FIPS 203 returns an implicit-rejection secret instead. */
    fun decapsulate(ct: ByteArray): ByteArray? {
        if (ct.size != CT_BYTES) return null
        return try { MLKEMExtractor(priv).extractSecret(ct) } catch (e: Exception) { null }
    }

    companion object {
        const val PK_BYTES = 1184
        const val CT_BYTES = 1088
        const val SS_BYTES = 32
        private val P = MLKEMParameters.ml_kem_768

        /** A fresh key pair from the system random source. */
        fun generate(): MlKem {
            val seed = ByteArray(64).also { SecureRandom().nextBytes(it) }
            return fromSeed(seed)
        }

        /** KeyGen_internal(d, z): deterministic, so a seed from a vector file
         *  reproduces the Mac's key byte for byte. */
        fun fromSeed(seed: ByteArray): MlKem {
            require(seed.size == 64)
            val d = seed.copyOfRange(0, 32); val z = seed.copyOfRange(32, 64)
            val g = MLKEMKeyPairGenerator()
            g.init(MLKEMKeyGenerationParameters(SecureRandom(), P))
            val kp = g.internalGenerateKeyPair(d, z)
            return MlKem(kp.private as MLKEMPrivateKeyParameters, seed.copyOf())
        }

        class Encaps(val ciphertext: ByteArray, val sharedSecret: ByteArray)

        /** Encapsulate to a peer's encapsulation key; null when the key is malformed. */
        fun encapsulate(peerPk: ByteArray, random: SecureRandom = SecureRandom()): Encaps? {
            if (peerPk.size != PK_BYTES) return null
            return try {
                val pk = MLKEMPublicKeyParameters(P, peerPk)
                val r = MLKEMGenerator(random).generateEncapsulated(pk)
                Encaps(r.encapsulation, r.secret)
            } catch (e: Exception) { null }
        }

        /** Encaps_internal(ek, m) with a fixed 32-byte m, for vectors only. */
        fun encapsulateWith(peerPk: ByteArray, m: ByteArray): Encaps? {
            if (peerPk.size != PK_BYTES || m.size != 32) return null
            return try {
                val pk = MLKEMPublicKeyParameters(P, peerPk)
                val r = MLKEMGenerator(SecureRandom()).internalGenerateEncapsulated(pk, m)
                Encaps(r.encapsulation, r.secret)
            } catch (e: Exception) { null }
        }
    }
}
