package com.tokkah.kin.net

import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Port of mac/Sources/tk/Crypto.swift, v2 — the SIGNED handshake.
 *
 * X25519 + HKDF-SHA256 + AES-256-GCM, two directional keys, packet =
 * counter(8 LE) || ciphertext || tag(16). Bit-exact with the Mac end: the
 * vectors in /vectors/crypto.json are the Mac's own sealed packets.
 *
 * What changed from v1, and why (the long version is at the top of the Swift):
 *
 *  - the ephemeral X25519 key travels SIGNED by this phone's Ed25519 identity
 *    (identity.json), over a message that names the room. A stranger who does
 *    not know the room cannot make this end adopt a key; the signalling server,
 *    which does know the room, can no longer substitute one without presenting
 *    an identity — and the identity is checked against the one this end EXPECTS
 *    (the key that signed the ring, the key the server bound the handle to, or
 *    the key pinned from a previous call), or pinned on first use for the call;
 *  - both ephemeral and both identity keys are in the HKDF info, so a key
 *    belongs to exactly one transcript;
 *  - there is no plaintext window: nothing is read or written before a key;
 *  - a sliding window over the counter refuses replayed packets.
 *
 *   packet:  magic(4) || eph(32) || caps(4 LE) || id(32) || sig(64)      136 bytes
 *   signed:  "kin-hs-v2|" + room + "|" || eph(32) || caps(4 LE)
 */
class Crypto(
    private val room: String,
    /** This install's Ed25519 seed (identity.json). */
    identitySeed: ByteArray,
    /** The 32-byte identity the other end must present, or null for first use. */
    expectedPeer: ByteArray? = null,
    /** Vector generation only: a fixed ephemeral key makes a run reproducible. */
    fixedPrivateRaw: ByteArray? = null,
) {
    private val salt = ("tk-v2-$room").toByteArray()
    private val idSeed: ByteArray = identitySeed.copyOf()
    private val expected: ByteArray? = expectedPeer?.takeIf { it.size == 32 }?.copyOf()
    /** The private scalar, raw. Proven against the CryptoKit vectors. */
    private val privRaw: ByteArray
    val myPublic: ByteArray
    val myIdentity: ByteArray
    private var sendKey: ByteArray? = null
    private var recvKey: ByteArray? = null
    private var sendCtr = 0L
    private val lock = Object()

    // ── replay window ─────────────────────────────────────────────────────
    private var rxHigh = 0L
    private val rxBits = LongArray(REPLAY_WINDOW / 64)

    @Volatile var established = false; private set
    var peerKeyHex = ""; private set
    var peerIdHex = ""; private set
    /** The peer's identity matched a key this end already expected. */
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

    // A budget on signature checks: 20 a second. The legitimate cadence is one
    // handshake per 300 ms and a same-key beat is compared before any arithmetic,
    // so only a flood of fresh keys can spend this, and on a phone verifying in
    // BigInteger a verify is tens of milliseconds on the receive thread.
    private var verifyTokens = 20.0
    private var verifyRefill = System.nanoTime()

    val hasExpectation get() = expected != null
    val peerIdentity: ByteArray? get() = if (peerIdHex.isEmpty()) null else hexToBytes(peerIdHex)

    init {
        privRaw = fixedPrivateRaw?.copyOf()
            ?: ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
        myPublic = X25519.publicFromPrivate(privRaw)
        myIdentity = Ed25519.publicFromSeed(idSeed)
    }

    /** X25519(mine, peer), constant-time, one implementation on every phone. */
    private fun agree(peerRaw: ByteArray): ByteArray? =
        try { X25519.sharedSecret(privRaw, peerRaw) } catch (e: Exception) { null }

    // ── the handshake packet ──────────────────────────────────────────────

    private var hsCache: Pair<Int, ByteArray>? = null

    /** Signed once per (key, caps) and reused; a beat is a 136-byte copy. */
    fun handshakePacket(caps: Int = Wire.CAP_PCM16 or Wire.CAP_PCM_LP): ByteArray = synchronized(lock) {
        hsCache?.takeIf { it.first == caps }?.let { return it.second }
        val out = ByteArray(HS_LEN)
        Wire.putU32(out, 0, HS_MAGIC)
        System.arraycopy(myPublic, 0, out, 4, 32)
        Wire.putU32(out, 36, caps)
        System.arraycopy(myIdentity, 0, out, 40, 32)
        val sig = Ed25519.sign(idSeed, signedMessage(room, myPublic, caps))
        System.arraycopy(sig, 0, out, 72, 64)
        hsCache = caps to out
        out
    }

    sealed class Adopt {
        object Unchanged : Adopt()
        object Adopted : Adopt()
        class Refused(val why: String) : Adopt()
    }

    /**
     * Consider a received handshake. The signature is only checked when the key
     * is new to us; a same-key beat is compared and returned without arithmetic.
     */
    fun adoptHandshake(b: ByteArray, n: Int): Adopt {
        if (n < HS_LEN || Wire.u32(b, 0) != HS_MAGIC) return Adopt.Refused("short")
        val eph = b.copyOfRange(4, 36)
        val caps = Wire.u32(b, 36)
        val id = b.copyOfRange(40, 72)
        val sig = b.copyOfRange(72, 136)
        val ephHex = hex(eph); val idHex = hex(id)
        if (ephHex == peerKeyHex && idHex == peerIdHex) return Adopt.Unchanged

        val now = System.nanoTime()
        verifyTokens = minOf(20.0, verifyTokens + (now - verifyRefill) / 1e9 * 20)
        verifyRefill = now
        if (verifyTokens < 1) { hsFlood++; return Adopt.Refused("flood") }
        verifyTokens -= 1

        // 1. Proof of the identity key AND of the room.
        if (!Ed25519.verify(id, signedMessage(room, eph, caps), sig)) { hsBadSig++; return Adopt.Refused("bad signature") }
        // 2. The identity we were told to expect.
        if (expected != null && !expected.contentEquals(id)) { hsWrongId++; return Adopt.Refused("wrong identity") }
        // 3. First-use pin for the call.
        if (expected == null && peerIdHex.isNotEmpty() && idHex != peerIdHex) { hsIdChanged++; return Adopt.Refused("identity changed") }
        val secret = agree(eph)
        if (secret == null || secret.all { it == 0.toByte() }) { hsWeak++; return Adopt.Refused("weak key") }

        val iAmA = lexicographicallyPrecedes(myPublic, eph)
        val transcript = transcript(myPublic, eph, myIdentity, id)
        val ka2b = hkdfSha256(secret, salt, "a2b".toByteArray() + transcript, 32)
        val kb2a = hkdfSha256(secret, salt, "b2a".toByteArray() + transcript, 32)
        synchronized(lock) {
            sendKey = if (iAmA) ka2b else kb2a
            recvKey = if (iAmA) kb2a else ka2b
            sendCtr = 0
            rxHigh = 0
            rxBits.fill(0)
            peerKeyHex = ephHex
            peerIdHex = idHex
            pinned = expected != null
            established = true
        }
        return Adopt.Adopted
    }

    /** An unsigned (v1) handshake arrived: refused, always; counted. */
    fun noteOldHandshake() { hsOld++ }

    // ── the packets ───────────────────────────────────────────────────────

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

    /** Opens a sealed packet; null on failure, on replay, or before a key. */
    fun open(packet: ByteArray, n: Int = packet.size): ByteArray? = synchronized(lock) {
        val k = recvKey ?: return null
        if (n <= 8 + 16) return null
        var ctr = 0L
        for (i in 0 until 8) ctr = ctr or ((packet[i].toLong() and 0xff) shl (8 * i))
        // Replay, judged before the arithmetic. Counters are compared unsigned.
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
        } catch (e: Exception) {
            openFails++
            return null
        }
        // Authenticated: now, and only now, it counts as seen.
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
    /** Not a handshake, and this end has no key yet: the far end's first sealed
     *  probes, usually. Ciphertext, not plaintext -- its own name. */
    fun notePreKeyRx() { preKeyRx++ }

    /** What the beat carries: every refusal has its own name. */
    fun beatFields(f: MutableMap<String, Any?>) {
        f["crypt"] = if (established) 1 else 0
        f["crypt_v"] = 2
        f["crypt_bad"] = openFails
        f["crypt_pinned"] = if (pinned) 1 else 0
        f["crypt_expected"] = if (expected != null) 1 else 0
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
    }

    val summary: String
        get() = if (established)
            "encrypted (aes-256-gcm, signed handshake, peer id ${peerIdHex.take(8)}… " +
                (if (pinned) "verified" else "first use") + ", code ${safetyCode ?: "-"})"
        else "NO KEY YET" +
            (if (hsOld > 0) " -- the other end is on an old build ($hsOld unsigned handshakes refused)" else "") +
            (if (hsWrongId > 0) " -- $hsWrongId handshakes from the WRONG identity refused" else "") +
            (if (hsBadSig > 0) " -- $hsBadSig bad signatures refused" else "")

    companion object {
        /** The signed handshake. 0x544B0006 (unsigned) is refused and counted. */
        const val HS_MAGIC = 0x544B_0009
        const val HS_LEN = 4 + 32 + 4 + 32 + 64
        const val HS_CONTEXT = "kin-hs-v2|"
        const val REPLAY_WINDOW = 2048
        const val CODE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

        fun signedMessage(room: String, eph: ByteArray, caps: Int): ByteArray {
            val head = (HS_CONTEXT + room + "|").toByteArray()
            val c = ByteArray(4); Wire.putU32(c, 0, caps)
            return head + eph + c
        }

        /** Both ephemeral keys then both identities, each pair sorted. */
        fun transcript(ephA: ByteArray, ephB: ByteArray, idA: ByteArray, idB: ByteArray): ByteArray {
            val e = listOf(ephA, ephB).sortedWith { x, y -> if (lexicographicallyPrecedes(x, y)) -1 else if (x.contentEquals(y)) 0 else 1 }
            val i = listOf(idA, idB).sortedWith { x, y -> if (lexicographicallyPrecedes(x, y)) -1 else if (x.contentEquals(y)) 0 else 1 }
            return e[0] + e[1] + i[0] + i[1]
        }

        fun capsOf(b: ByteArray, n: Int): Int = if (n >= HS_LEN) Wire.u32(b, 36) else 0

        fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

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

// X25519 (RFC 7748): BouncyCastle's constant-time implementation, called directly.
// One path on every phone and in every JVM test. The BigInteger ladder that used
// to live here was the fallback for a platform provider that might refuse a raw
// key; a fallback that is not constant-time is a second, weaker implementation
// chosen by the phone, invisibly. Gone.
internal object X25519 {
    fun publicFromPrivate(scalarRaw: ByteArray): ByteArray {
        require(scalarRaw.size == 32)
        val out = ByteArray(32)
        org.bouncycastle.math.ec.rfc7748.X25519.scalarMultBase(scalarRaw, 0, out, 0)
        return out
    }

    /** RFC 7748 X25519(k, u) with the peer's public u-coordinate. */
    fun sharedSecret(scalarRaw: ByteArray, peerRaw: ByteArray): ByteArray {
        require(scalarRaw.size == 32 && peerRaw.size == 32)
        val out = ByteArray(32)
        org.bouncycastle.math.ec.rfc7748.X25519.scalarMult(scalarRaw, 0, peerRaw, 0, out, 0)
        return out
    }
}
