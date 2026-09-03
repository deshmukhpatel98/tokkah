package com.tokkah.kin.net

import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Port of mac/Sources/tk/Crypto.swift, v3 — the SIGNED, HYBRID handshake.
 *
 * X25519 + ML-KEM-768 (FIPS 203, BouncyCastle) agree the call key; AES-256-GCM
 * per packet, two directional keys, a 2048-packet replay window. Bit-exact with
 * the Mac end: /vectors/crypto.json holds the Mac's packets and sealed bytes.
 *
 * Three handshake packets, all under 1200 bytes:
 *
 *   HS3  magic | eph(32) | caps(4) | id(32) | kemHash(32) | sig(64)         168 B
 *   HSK  magic | eph(32) | half(1) | 592 B of the ML-KEM public key           629 B
 *   HSC  magic | eph(32) | ct(1088) | sig(64)                                1188 B
 *
 * Whoever's ephemeral key sorts lower is A and owns the ML-KEM key that gets
 * used; B encapsulates to it and sends HSC. The call key is
 * HKDF(x25519 || kemSecret) over the whole transcript. See the Swift header for
 * the threat model, which is unchanged from v2 except that a recording can no
 * longer be opened by a quantum computer built later.
 */
class Crypto(
    private val room: String,
    identitySeed: ByteArray,
    expectedPeer: ByteArray? = null,
    fixedPrivateRaw: ByteArray? = null,
    fixedKemSeed: ByteArray? = null,
    /** Vectors only: a fixed m makes B's ciphertext reproducible. */
    private val fixedKemM: ByteArray? = null,
) {
    private val salt = ("tk-v3-$room").toByteArray()
    private val idSeed: ByteArray = identitySeed.copyOf()
    private val expected: ByteArray? = expectedPeer?.takeIf { it.size == 32 }?.copyOf()
    private val privRaw: ByteArray
    val myPublic: ByteArray
    val myIdentity: ByteArray
    private val kem: MlKem
    val myKemPk: ByteArray get() = kem.publicKey
    private var sendKey: ByteArray? = null
    private var recvKey: ByteArray? = null
    private var sendCtr = 0L
    private val lock = Object()

    private var rxHigh = 0L
    private val rxBits = LongArray(REPLAY_WINDOW / 64)

    @Volatile var established = false; private set
    var peerKeyHex = ""; private set
    var peerIdHex = ""; private set
    var peerCaps = 0; private set
    private var peerEph = ByteArray(0)
    private var peerId = ByteArray(0)
    private var peerKemHash = ByteArray(0)
    private val peerKemHalves = arrayOfNulls<ByteArray>(2)
    private var peerKemPk: ByteArray? = null
    private var myCt: ByteArray? = null
    private var iAmA = false
    var pinned = false; private set
    var sealed = 0; private set
    var opened = 0; private set
    var openFails = 0; private set
    var replayDrops = 0; private set
    var preKeyDrops = 0; private set
    var preKeyRx = 0; private set
    var plaintextRx = 0; private set
    var hsBadSig = 0; private set
    var hsWrongId = 0; private set
    var hsIdChanged = 0; private set
    var hsOld = 0; private set
    var hsFlood = 0; private set
    var hsWeak = 0; private set
    var hsKemHashBad = 0; private set
    var hsCtRefused = 0; private set

    private var verifyTokens = 20.0
    private var verifyRefill = System.nanoTime()

    val hasExpectation get() = expected != null
    val peerIdentity: ByteArray? get() = if (peerIdHex.isEmpty()) null else hexToBytes(peerIdHex)

    init {
        privRaw = fixedPrivateRaw?.copyOf() ?: ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
        myPublic = X25519.publicFromPrivate(privRaw)
        myIdentity = Ed25519.publicFromSeed(idSeed)
        kem = if (fixedKemSeed != null) MlKem.fromSeed(fixedKemSeed) else MlKem.generate()
    }

    // ── the packets this end sends ────────────────────────────────────────

    private var hsCache: Pair<Int, ByteArray>? = null
    fun handshakePacket(caps: Int = Wire.CAP_PCM16 or Wire.CAP_PCM_LP): ByteArray = synchronized(lock) {
        hsCache?.takeIf { it.first == caps }?.let { return it.second }
        val out = ByteArray(HS_LEN)
        Wire.putU32(out, 0, HS_MAGIC)
        System.arraycopy(myPublic, 0, out, 4, 32)
        Wire.putU32(out, 36, caps)
        System.arraycopy(myIdentity, 0, out, 40, 32)
        val kh = kemHash(myKemPk)
        System.arraycopy(kh, 0, out, 72, 32)
        val sig = Ed25519.sign(idSeed, signedMessage(room, myPublic, caps, kh))
        System.arraycopy(sig, 0, out, 104, 64)
        hsCache = caps to out
        out
    }

    private val kemHalves: List<ByteArray> by lazy {
        (0 until 2).map { h ->
            val out = ByteArray(HSK_LEN)
            Wire.putU32(out, 0, HSK_MAGIC)
            System.arraycopy(myPublic, 0, out, 4, 32)
            out[36] = h.toByte()
            System.arraycopy(myKemPk, h * HSK_HALF, out, 37, HSK_HALF)
            out
        }
    }

    private var hscCache: ByteArray? = null
    /** HS3, then (while unkeyed or unconfirmed) the two halves and, for B, the ciphertext. */
    fun handshakePackets(caps: Int = Wire.CAP_PCM16 or Wire.CAP_PCM_LP): List<ByteArray> {
        val out = mutableListOf(handshakePacket(caps))
        val done: Boolean; val ct: ByteArray?
        synchronized(lock) { done = established && opened > 0; ct = myCt }
        if (done) return out
        out.addAll(kemHalves)
        if (ct != null) out.add(hscPacket(ct))
        return out
    }

    private fun hscPacket(ct: ByteArray): ByteArray {
        hscCache?.let { return it }
        val out = ByteArray(HSC_LEN)
        Wire.putU32(out, 0, HSC_MAGIC)
        System.arraycopy(myPublic, 0, out, 4, 32)
        System.arraycopy(ct, 0, out, 36, MlKem.CT_BYTES)
        val sig = Ed25519.sign(idSeed, ctMessage(room, myPublic, peerEph, ct))
        System.arraycopy(sig, 0, out, 36 + MlKem.CT_BYTES, 64)
        hscCache = out
        return out
    }

    sealed class Adopt {
        object Unchanged : Adopt()
        object Adopted : Adopt()
        object Keyed : Adopt()
        class Refused(val why: String) : Adopt()
    }

    private fun spendVerify(): Boolean {
        val now = System.nanoTime()
        verifyTokens = minOf(20.0, verifyTokens + (now - verifyRefill) / 1e9 * 20)
        verifyRefill = now
        if (verifyTokens < 1) { hsFlood++; return false }
        verifyTokens -= 1
        return true
    }

    /** Any of the three handshake packets, by magic. */
    fun take(b: ByteArray, n: Int): Adopt = when (Wire.magic(b, n)) {
        HS_MAGIC -> adoptHandshake(b, n)
        HSK_MAGIC -> takeKemHalf(b, n)
        HSC_MAGIC -> takeCiphertext(b, n)
        else -> Adopt.Refused("magic")
    }

    fun adoptHandshake(b: ByteArray, n: Int): Adopt {
        if (n < HS_LEN || Wire.u32(b, 0) != HS_MAGIC) return Adopt.Refused("short")
        val eph = b.copyOfRange(4, 36)
        val caps = Wire.u32(b, 36)
        val id = b.copyOfRange(40, 72)
        val kh = b.copyOfRange(72, 104)
        val sig = b.copyOfRange(104, 168)
        val ephHex = hex(eph); val idHex = hex(id)
        if (ephHex == peerKeyHex && idHex == peerIdHex) return Adopt.Unchanged
        if (!spendVerify()) return Adopt.Refused("flood")
        if (!Ed25519.verify(id, signedMessage(room, eph, caps, kh), sig)) { hsBadSig++; return Adopt.Refused("bad signature") }
        if (expected != null && !expected.contentEquals(id)) { hsWrongId++; return Adopt.Refused("wrong identity") }
        if (expected == null && peerIdHex.isNotEmpty() && idHex != peerIdHex) { hsIdChanged++; return Adopt.Refused("identity changed") }
        val secret = try { X25519.sharedSecret(privRaw, eph) } catch (e: Exception) { null }
        if (secret == null || secret.all { it == 0.toByte() }) { hsWeak++; return Adopt.Refused("weak key") }
        synchronized(lock) {
            peerEph = eph; peerId = id; peerKemHash = kh; peerCaps = caps
            peerKeyHex = ephHex; peerIdHex = idHex
            peerKemHalves[0] = null; peerKemHalves[1] = null; peerKemPk = null
            myCt = null; hscCache = null
            iAmA = lexicographicallyPrecedes(myPublic, eph)
            established = false; sendKey = null; recvKey = null
            pinned = expected != null
        }
        return Adopt.Adopted
    }

    fun takeKemHalf(b: ByteArray, n: Int): Adopt {
        if (n < HSK_LEN || Wire.u32(b, 0) != HSK_MAGIC) return Adopt.Refused("short")
        val eph = b.copyOfRange(4, 36)
        if (peerEph.isEmpty() || !eph.contentEquals(peerEph)) return Adopt.Refused("unknown eph")
        val h = b[36].toInt()
        if (h != 0 && h != 1) return Adopt.Refused("bad half")
        val pk: ByteArray; val amA: Boolean
        synchronized(lock) {
            if (peerKemPk != null) return Adopt.Unchanged
            peerKemHalves[h] = b.copyOfRange(37, 37 + HSK_HALF)
            val a = peerKemHalves[0] ?: return Adopt.Unchanged
            val c = peerKemHalves[1] ?: return Adopt.Unchanged
            pk = a + c
            if (!kemHash(pk).contentEquals(peerKemHash)) {
                peerKemHalves[0] = null; peerKemHalves[1] = null; hsKemHashBad++
                return Adopt.Refused("kem key does not match the signed hash")
            }
            peerKemPk = pk; amA = iAmA
        }
        if (!amA) {
            val enc = (if (fixedKemM != null) MlKem.encapsulateWith(pk, fixedKemM) else MlKem.encapsulate(pk))
                ?: run { hsKemHashBad++; return Adopt.Refused("kem key invalid") }
            synchronized(lock) { myCt = enc.ciphertext; hscCache = null }
            derive(enc.sharedSecret, enc.ciphertext)
            return Adopt.Keyed
        }
        return Adopt.Adopted
    }

    fun takeCiphertext(b: ByteArray, n: Int): Adopt {
        if (n < HSC_LEN || Wire.u32(b, 0) != HSC_MAGIC) return Adopt.Refused("short")
        val sender = b.copyOfRange(4, 36)
        if (peerEph.isEmpty() || !sender.contentEquals(peerEph)) return Adopt.Refused("unknown eph")
        val amA: Boolean; val done: Boolean
        synchronized(lock) { amA = iAmA; done = established }
        if (!amA) return Adopt.Refused("not the decapsulator")
        if (done) return Adopt.Unchanged
        val ct = b.copyOfRange(36, 36 + MlKem.CT_BYTES)
        val sig = b.copyOfRange(36 + MlKem.CT_BYTES, 36 + MlKem.CT_BYTES + 64)
        if (!spendVerify()) return Adopt.Refused("flood")
        if (!Ed25519.verify(peerId, ctMessage(room, sender, myPublic, ct), sig)) { hsCtRefused++; return Adopt.Refused("ciphertext bad signature") }
        val ss = kem.decapsulate(ct) ?: run { hsCtRefused++; return Adopt.Refused("ciphertext bad length") }
        derive(ss, ct)
        return Adopt.Keyed
    }

    private fun derive(kemSecret: ByteArray, ct: ByteArray) {
        val secret = X25519.sharedSecret(privRaw, peerEph)
        val aEph = if (iAmA) myPublic else peerEph; val bEph = if (iAmA) peerEph else myPublic
        val aId = if (iAmA) myIdentity else peerId; val bId = if (iAmA) peerId else myIdentity
        val aKemHash = if (iAmA) kemHash(myKemPk) else peerKemHash
        val transcript = aEph + bEph + aId + bId + aKemHash + sha256(ct)
        val ikm = secret + kemSecret
        val ka2b = hkdfSha256(ikm, salt, "a2b".toByteArray() + transcript, 32)
        val kb2a = hkdfSha256(ikm, salt, "b2a".toByteArray() + transcript, 32)
        synchronized(lock) {
            sendKey = if (iAmA) ka2b else kb2a
            recvKey = if (iAmA) kb2a else ka2b
            sendCtr = 0; rxHigh = 0; rxBits.fill(0)
            established = true
        }
    }

    fun noteOldHandshake() { hsOld++ }

    // ── the packets ───────────────────────────────────────────────────────

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

    fun open(packet: ByteArray, n: Int = packet.size): ByteArray? = synchronized(lock) {
        val k = recvKey ?: return null
        if (n <= 8 + 16) return null
        var ctr = 0L
        for (i in 0 until 8) ctr = ctr or ((packet[i].toLong() and 0xff) shl (8 * i))
        if (ctr == 0L) { replayDrops++; return null }
        if (java.lang.Long.compareUnsigned(ctr, rxHigh) <= 0) {
            val back = rxHigh - ctr
            if (java.lang.Long.compareUnsigned(back, REPLAY_WINDOW.toLong()) >= 0) { replayDrops++; return null }
            if (bit(ctr)) { replayDrops++; return null }
        }
        val nonce = ByteArray(12)
        for (i in 0 until 8) nonce[4 + i] = ((ctr ushr (8 * i)) and 0xff).toByte()
        val pt = try {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, SecretKeySpec(k, "AES"), GCMParameterSpec(128, nonce))
            c.doFinal(packet, 8, n - 8)
        } catch (e: Exception) { openFails++; return null }
        if (java.lang.Long.compareUnsigned(ctr, rxHigh) > 0) {
            val jump = ctr - rxHigh
            if (java.lang.Long.compareUnsigned(jump, REPLAY_WINDOW.toLong()) >= 0) rxBits.fill(0)
            else { var c = rxHigh + 1; while (java.lang.Long.compareUnsigned(c, ctr) <= 0) { clearBit(c); c++ } }
            rxHigh = ctr
        }
        setBit(ctr)
        opened++
        return pt
    }

    private fun slot(ctr: Long) = ((ctr ushr 6) % rxBits.size).toInt()
    private fun mask(ctr: Long) = 1L shl (ctr and 63).toInt()
    private fun bit(ctr: Long) = rxBits[slot(ctr)] and mask(ctr) != 0L
    private fun setBit(ctr: Long) { rxBits[slot(ctr)] = rxBits[slot(ctr)] or mask(ctr) }
    private fun clearBit(ctr: Long) { rxBits[slot(ctr)] = rxBits[slot(ctr)] and mask(ctr).inv() }

    val safetyCode: String?
        get() {
            if (!established || peerKeyHex.isEmpty() || peerIdHex.isEmpty()) return null
            val parts = listOf(hex(myPublic), peerKeyHex, hex(myIdentity), peerIdHex).sorted()
            val digest = MessageDigest.getInstance("SHA-256").digest(parts.joinToString("|").toByteArray())
            val out = digest.take(8).map { CODE_ALPHABET[it.toInt() and 31] }.joinToString("")
            return out.take(4) + " " + out.drop(4)
        }

    fun notePlaintextRx() { plaintextRx++ }
    fun notePreKeyDrop() { preKeyDrops++ }
    fun notePreKeyRx() { preKeyRx++ }

    fun beatFields(f: MutableMap<String, Any?>) {
        f["crypt"] = if (established) 1 else 0
        f["crypt_v"] = 3
        f["crypt_pq"] = 1
        f["crypt_bad"] = openFails
        f["crypt_pinned"] = if (pinned) 1 else 0
        f["crypt_expected"] = if (expected != null) 1 else 0
        if (peerEph.isNotEmpty()) f["crypt_role"] = if (iAmA) "a" else "b"
        f["sealed"] = sealed; f["opened"] = opened
        if (replayDrops > 0) f["replay_drop"] = replayDrops
        if (preKeyDrops > 0) f["prekey_drop"] = preKeyDrops
        if (preKeyRx > 0) f["prekey_rx"] = preKeyRx
        if (plaintextRx > 0) f["plaintext_rx"] = plaintextRx
        if (hsBadSig > 0) f["hs_bad_sig"] = hsBadSig
        if (hsWrongId > 0) f["hs_wrong_id"] = hsWrongId
        if (hsIdChanged > 0) f["hs_id_changed"] = hsIdChanged
        if (hsOld > 0) f["hs_old"] = hsOld
        if (hsFlood > 0) f["hs_flood"] = hsFlood
        if (hsWeak > 0) f["hs_weak"] = hsWeak
        if (hsKemHashBad > 0) f["hs_kem_bad"] = hsKemHashBad
        if (hsCtRefused > 0) f["hs_ct_refused"] = hsCtRefused
    }

    val summary: String
        get() = if (established)
            "encrypted (aes-256-gcm, x25519 + ml-kem-768, signed handshake, role ${if (iAmA) "A" else "B"}, peer id ${peerIdHex.take(8)}… " +
                (if (pinned) "verified" else "first use") + ", code ${safetyCode ?: "-"})"
        else "NO KEY YET" +
            (if (hsOld > 0) " -- the other end is on an old build ($hsOld pre-v3 handshakes refused)" else "") +
            (if (hsWrongId > 0) " -- $hsWrongId handshakes from the WRONG identity refused" else "") +
            (if (hsBadSig > 0) " -- $hsBadSig bad signatures refused" else "")

    companion object {
        const val HS_MAGIC = 0x544B_000A
        const val HSK_MAGIC = 0x544B_000B
        const val HSC_MAGIC = 0x544B_000C
        const val HS_V2_MAGIC = 0x544B_0009
        const val HS_LEN = 4 + 32 + 4 + 32 + 32 + 64
        const val HSK_HALF = MlKem.PK_BYTES / 2
        const val HSK_LEN = 4 + 32 + 1 + HSK_HALF
        const val HSC_LEN = 4 + 32 + MlKem.CT_BYTES + 64
        const val HS_CONTEXT = "kin-hs-v3|"
        const val HSC_CONTEXT = "kin-hs-v3c|"
        const val REPLAY_WINDOW = 2048
        const val CODE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

        fun isHandshake(magic: Int) = magic == HS_MAGIC || magic == HSK_MAGIC || magic == HSC_MAGIC
        fun sha256(b: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(b)
        fun kemHash(pk: ByteArray) = sha256(pk)
        fun signedMessage(room: String, eph: ByteArray, caps: Int, kemHash: ByteArray): ByteArray {
            val c = ByteArray(4); Wire.putU32(c, 0, caps)
            return (HS_CONTEXT + room + "|").toByteArray() + eph + c + kemHash
        }
        fun ctMessage(room: String, sender: ByteArray, recipient: ByteArray, ct: ByteArray): ByteArray =
            (HSC_CONTEXT + room + "|").toByteArray() + sender + recipient + ct
        fun capsOf(b: ByteArray, n: Int): Int = if (n >= HS_LEN) Wire.u32(b, 36) else 0
        fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

        fun lexicographicallyPrecedes(a: ByteArray, b: ByteArray): Boolean {
            val n = minOf(a.size, b.size)
            for (i in 0 until n) {
                val x = a[i].toInt() and 0xff; val y = b[i].toInt() and 0xff
                if (x != y) return x < y
            }
            return a.size < b.size
        }

        fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, len: Int): ByteArray {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
            val prk = mac.doFinal(ikm)
            val out = ByteArray(len)
            var t = ByteArray(0); var pos = 0; var i = 1
            while (pos < len) {
                mac.init(SecretKeySpec(prk, "HmacSHA256"))
                mac.update(t); mac.update(info); mac.update(i.toByte())
                t = mac.doFinal()
                val c = minOf(t.size, len - pos)
                System.arraycopy(t, 0, out, pos, c)
                pos += c; i++
            }
            return out
        }

        fun hexToBytes(s: String): ByteArray =
            ByteArray(s.length / 2) { ((Character.digit(s[it * 2], 16) shl 4) + Character.digit(s[it * 2 + 1], 16)).toByte() }
    }
}

// X25519 (RFC 7748): BouncyCastle's constant-time implementation, called directly.
internal object X25519 {
    fun publicFromPrivate(scalarRaw: ByteArray): ByteArray {
        require(scalarRaw.size == 32)
        val out = ByteArray(32)
        org.bouncycastle.math.ec.rfc7748.X25519.scalarMultBase(scalarRaw, 0, out, 0)
        return out
    }
    fun sharedSecret(scalarRaw: ByteArray, peerRaw: ByteArray): ByteArray {
        require(scalarRaw.size == 32 && peerRaw.size == 32)
        val out = ByteArray(32)
        org.bouncycastle.math.ec.rfc7748.X25519.scalarMult(scalarRaw, 0, peerRaw, 0, out, 0)
        return out
    }
}
