package com.tokkah.kin.net

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.security.MessageDigest
import java.util.zip.CRC32
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.random.Random

/**
 * Port of mac/Sources/tk/Turn.swift — the relay, for the calls that cannot go
 * direct.
 *
 * Without this a phone behind a symmetric NAT simply fails where a Mac in the
 * same place connects, which is not a degraded call, it is no call.
 *
 * FAIL-OPEN throughout: every failure here returns false and leaves the direct
 * paths racing exactly as they were. A relay that cannot be allocated must
 * never be able to stop a call that would have worked without it.
 *
 * The relay is also not only a fallback. Cloudflare's backbone is SHORTER than
 * the public internet on long routes, so the relayed candidate is entered into
 * the same round-trip race as the direct ones and sometimes wins on merit.
 */
class Turn(
    private val host: String,
    private val port: Int,
    private val username: String,
    private val credential: String,
) {
    private var realm = ""
    private var nonce = ""
    private var channel = 0x4000
    private var turnAddr: InetSocketAddress? = null

    var relayIP = ""; private set
    var relayPort = 0; private set
    var lastError: String? = null; private set

    val relay: String? get() = if (relayIP.isEmpty()) null else "$relayIP:$relayPort"

    fun isTurnServer(a: InetSocketAddress): Boolean =
        turnAddr != null && a.address == turnAddr!!.address && a.port == turnAddr!!.port

    /** Ask the server for a relayed address on THIS socket. */
    fun allocate(sock: DatagramSocket): Boolean {
        turnAddr = try {
            InetSocketAddress(InetAddress.getByName(host), port)
        } catch (e: Exception) { lastError = "cannot resolve $host"; return false }

        val udp = 0x0019 to byteArrayOf(17, 0, 0, 0)   // REQUESTED-TRANSPORT udp
        // The first request is unauthenticated on purpose: a 401 is how the
        // server hands back the realm and nonce the real one needs.
        roundTrip(sock, method = 0x0003, extra = listOf(udp), integrity = false)

        val attrs = mutableListOf(udp, 0x000D to u32(600))   // LIFETIME 10 min
        if (realm.isNotEmpty()) {
            attrs.add(0x0006 to username.toByteArray())
            attrs.add(0x0014 to realm.toByteArray())
            attrs.add(0x0015 to nonce.toByteArray())
        }
        val r = roundTrip(sock, 0x0003, attrs, integrity = true)
        if (r == null) { lastError = "no reply from $host:$port"; return false }
        if (!r.ok || r.relayed == null) {
            lastError = if (r.errorCode != 0) "allocate failed — ${r.errorCode} ${r.errorReason}"
                        else "allocate failed"
            return false
        }
        relayIP = r.relayed.first
        relayPort = r.relayed.second
        return true
    }

    /** Permission plus a channel, so media rides 4 bytes of overhead and not 36. */
    fun bindPeer(sock: DatagramSocket, ip: String, peerPort: Int): Boolean {
        val xor = xorPeer(ip, peerPort)
        val perm = mutableListOf(0x0012 to xor)
        auth(perm)
        val p = roundTrip(sock, 0x0008, perm, integrity = true)
        if (p == null || !p.ok) { lastError = "CreatePermission $ip:$peerPort failed"; return false }

        val ch = mutableListOf(
            0x000C to byteArrayOf((channel shr 8).toByte(), channel.toByte(), 0, 0),
            0x0012 to xor,
        )
        auth(ch)
        val b = roundTrip(sock, 0x0009, ch, integrity = true)
        if (b == null || !b.ok) { lastError = "ChannelBind failed"; return false }
        return true
    }

    /** Media, wrapped in a 4-byte channel header. */
    fun sendChannel(sock: DatagramSocket, p: ByteArray, n: Int): Boolean {
        val a = turnAddr ?: return false
        val pad = (4 - (n % 4)) % 4
        val out = ByteArray(4 + n + pad)
        out[0] = (channel shr 8).toByte()
        out[1] = channel.toByte()
        out[2] = (n shr 8).toByte()
        out[3] = n.toByte()
        System.arraycopy(p, 0, out, 4, n)
        return try { sock.send(DatagramPacket(out, out.size, a)); true } catch (e: Exception) { false }
    }

    /** Strip the channel header off something the relay handed back. */
    fun unwrap(buf: ByteArray, n: Int, from: InetSocketAddress): Pair<Int, Int>? {
        if (!isTurnServer(from) || n < 4) return null
        val ch = ((buf[0].toInt() and 0xff) shl 8) or (buf[1].toInt() and 0xff)
        if (ch != channel) return null
        val len = ((buf[2].toInt() and 0xff) shl 8) or (buf[3].toInt() and 0xff)
        if (4 + len > n) return null
        return 4 to len
    }

    // ── the protocol ─────────────────────────────────────────────────────────

    private class Reply(
        val ok: Boolean, val relayed: Pair<String, Int>?,
        val errorCode: Int, val errorReason: String,
    )

    private fun auth(attrs: MutableList<Pair<Int, ByteArray>>) {
        if (username.isNotEmpty()) attrs.add(0x0006 to username.toByteArray())
        if (realm.isNotEmpty()) attrs.add(0x0014 to realm.toByteArray())
        if (nonce.isNotEmpty()) attrs.add(0x0015 to nonce.toByteArray())
    }

    /**
     * ── ONE READER OF THE SOCKET ────────────────────────────────────────────
     *
     * These round trips used to read the socket themselves. Once the media
     * receive loop is running that is TWO readers of one socket, and they steal
     * from each other: a `bindPeer` on the signal thread swallowed the peer's
     * handshakes for up to 800 ms every second, and the call went completely
     * silent with every counter healthy and the relay looking like the culprit.
     *
     * So the reply arrives the same way media does — through the receive loop,
     * which hands it here by transaction id. Before that loop exists (the first
     * allocate, on a fresh socket) [readDirectly] is set and this reads for
     * itself, because there is nobody else to.
     */
    @Volatile var readDirectly = true
    private val waiters = HashMap<String, java.util.concurrent.ArrayBlockingQueue<Reply>>()

    /** Called by the receive loop for anything from the TURN server. */
    fun offerReply(buf: ByteArray, n: Int, from: InetSocketAddress): Boolean {
        if (!isTurnServer(from) || n < 20) return false
        // Channel data has its top two bits set; a STUN/TURN message does not.
        if ((buf[0].toInt() and 0xC0) != 0) return false
        val key = txKey(buf, 8)
        val q = synchronized(waiters) { waiters[key] } ?: return false
        q.offer(parse(buf, n))
        return true
    }

    private fun txKey(b: ByteArray, off: Int) =
        (0 until 12).joinToString("") { "%02x".format(b[off + it]) }

    private fun roundTrip(
        sock: DatagramSocket, method: Int,
        extra: List<Pair<Int, ByteArray>>, integrity: Boolean, timeoutMs: Int = 800,
    ): Reply? {
        val a = turnAddr ?: return null
        val txid = Random.nextBytes(12)
        val pkt = build(method, txid, extra, integrity)
        val key = txKey(txid, 0)
        val q = java.util.concurrent.ArrayBlockingQueue<Reply>(2)
        synchronized(waiters) { waiters[key] = q }
        try {
            sock.send(DatagramPacket(pkt, pkt.size, a))
            if (!readDirectly) {
                return q.poll(timeoutMs.toLong(), java.util.concurrent.TimeUnit.MILLISECONDS)
            }
            val prev = sock.soTimeout
            try {
                sock.soTimeout = timeoutMs
                val buf = ByteArray(1500)
                val deadline = System.nanoTime() + timeoutMs * 1_000_000L
                while (System.nanoTime() < deadline) {
                    val p = DatagramPacket(buf, buf.size)
                    try { sock.receive(p) } catch (e: Exception) { return null }
                    if (p.length < 20) continue
                    if ((0 until 12).any { buf[8 + it] != txid[it] }) continue
                    return parse(buf, p.length)
                }
                return null
            } finally { sock.soTimeout = prev }
        } catch (e: Exception) {
            return null
        } finally {
            synchronized(waiters) { waiters.remove(key) }
        }
    }

    private fun parse(buf: ByteArray, n: Int): Reply {
        val type = ((buf[0].toInt() and 0xff) shl 8) or (buf[1].toInt() and 0xff)
        val ok = (type and 0x0110) == 0x0100
        var relayed: Pair<String, Int>? = null
        var code = 0
        var reason = ""
        var i = 20
        val end = 20 + (((buf[2].toInt() and 0xff) shl 8) or (buf[3].toInt() and 0xff))
        while (i + 4 <= minOf(end, n)) {
            val at = ((buf[i].toInt() and 0xff) shl 8) or (buf[i + 1].toInt() and 0xff)
            val al = ((buf[i + 2].toInt() and 0xff) shl 8) or (buf[i + 3].toInt() and 0xff)
            val v = i + 4
            if (v + al > n) break
            when (at) {
                0x0016 -> if (al >= 8 && buf[v + 1].toInt() == 0x01) {   // XOR-RELAYED-ADDRESS
                    val rp = (((buf[v + 2].toInt() and 0xff) shl 8) or (buf[v + 3].toInt() and 0xff)) xor
                        (Stun.COOKIE ushr 16)
                    val o = IntArray(4) { k ->
                        (buf[v + 4 + k].toInt() and 0xff) xor ((Stun.COOKIE ushr (8 * (3 - k))) and 0xff)
                    }
                    relayed = "${o[0]}.${o[1]}.${o[2]}.${o[3]}" to (rp and 0xffff)
                }
                0x0014 -> realm = String(buf, v, al)
                0x0015 -> nonce = String(buf, v, al)
                0x0009 -> if (al >= 4) {                                  // ERROR-CODE
                    code = (buf[v + 2].toInt() and 0x7) * 100 + (buf[v + 3].toInt() and 0xff)
                    if (al > 4) reason = String(buf, v + 4, al - 4)
                }
            }
            i = v + al + ((4 - al % 4) % 4)
        }
        return Reply(ok, relayed, code, reason)
    }

    private fun build(
        method: Int, txid: ByteArray,
        extra: List<Pair<Int, ByteArray>>, integrity: Boolean,
    ): ByteArray {
        fun attr(out: MutableList<Byte>, t: Int, v: ByteArray) {
            out.add((t shr 8).toByte()); out.add(t.toByte())
            out.add((v.size shr 8).toByte()); out.add(v.size.toByte())
            out.addAll(v.toList())
            repeat((4 - (v.size % 4)) % 4) { out.add(0) }
        }
        val body = mutableListOf<Byte>()
        for ((t, v) in extra) attr(body, t, v)

        fun header(len: Int): ByteArray {
            val h = ByteArray(20)
            h[0] = (method shr 8).toByte(); h[1] = method.toByte()
            h[2] = (len shr 8).toByte(); h[3] = len.toByte()
            h[4] = 0x21; h[5] = 0x12; h[6] = 0xA4.toByte(); h[7] = 0x42
            System.arraycopy(txid, 0, h, 8, 12)
            return h
        }

        if (integrity) {
            // MESSAGE-INTEGRITY is HMAC-SHA1 over the message with its length
            // ALREADY counting the attribute about to be appended — get that
            // wrong and every authenticated request is refused with a 401 that
            // looks like bad credentials.
            val msg = header(body.size + 24) + body.toByteArray()
            val mac = Mac.getInstance("HmacSHA1")
            mac.init(SecretKeySpec(longTermKey(), "HmacSHA1"))
            attr(body, 0x0008, mac.doFinal(msg))
            val forCrc = header(body.size + 8) + body.toByteArray()
            val crc = CRC32().apply { update(forCrc) }.value.toInt() xor 0x5354554E
            attr(body, 0x8028, u32(crc.toLong() and 0xffffffffL))
            return header(body.size) + body.toByteArray()
        }
        return header(body.size) + body.toByteArray()
    }

    /** MD5(username ":" realm ":" password) — RFC 5389 long-term credentials. */
    private fun longTermKey(): ByteArray =
        MessageDigest.getInstance("MD5").digest("$username:$realm:$credential".toByteArray())

    private fun xorPeer(ip: String, p: Int): ByteArray {
        val out = ByteArray(8)
        out[1] = 0x01
        val xp = p xor (Stun.COOKIE ushr 16)
        out[2] = (xp shr 8).toByte(); out[3] = xp.toByte()
        val parts = ip.split(".").map { it.toInt() }
        for (k in 0 until 4) {
            out[4 + k] = (parts[k] xor ((Stun.COOKIE ushr (8 * (3 - k))) and 0xff)).toByte()
        }
        return out
    }

    private fun u32(v: Long) = byteArrayOf(
        (v shr 24).toByte(), (v shr 16).toByte(), (v shr 8).toByte(), v.toByte(),
    )

    companion object {
        /** Mint short-lived credentials from our own server. Fail-open. */
        fun mint(base: String = Server.base): Turn? {
            val body = httpGet("$base/api/mac/turn", 4000) ?: return null
            if (!body.contains("\"ok\":true")) return null
            fun s(k: String) = Regex("\"$k\"\\s*:\\s*\"([^\"]*)\"").find(body)?.groupValues?.get(1)
            fun n(k: String) = Regex("\"$k\"\\s*:\\s*(\\d+)").find(body)?.groupValues?.get(1)?.toIntOrNull()
            val h = s("host") ?: return null
            val u = s("username") ?: return null
            val c = s("credential") ?: return null
            return Turn(h, n("port") ?: 3478, u, c)
        }
    }
}
