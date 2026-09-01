package com.tokkah.kin.net

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import kotlin.random.Random

// Port of mac/Sources/tk/Stun.swift — RFC 5389 binding on the SAME socket the
// media uses (a mapping discovered on a second socket describes that socket's
// hole, not this one's).
object Stun {
    const val COOKIE = 0x2112A442.toInt()

    data class Mapped(val ip: String, val port: Int)

    val servers = listOf("stun.cloudflare.com", "stun.l.google.com:19302", "stun1.l.google.com:19302")

    fun discoverAny(sock: DatagramSocket, list: List<String> = servers, timeoutMs: Int = 1200): Mapped? {
        for (entry in list) {
            var host = entry
            var port = 3478
            val colon = entry.lastIndexOf(':')
            if (colon >= 0) entry.substring(colon + 1).toIntOrNull()?.let { host = entry.substring(0, colon); port = it }
            discover(sock, host, port, timeoutMs)?.let { return it }
        }
        return null
    }

    fun discover(sock: DatagramSocket, server: String, port: Int = 3478, timeoutMs: Int = 1200): Mapped? {
        val req = ByteArray(20)
        req[0] = 0x00; req[1] = 0x01                       // Binding Request
        req[4] = 0x21; req[5] = 0x12; req[6] = 0xA4.toByte(); req[7] = 0x42
        val txid = Random.nextBytes(12)
        System.arraycopy(txid, 0, req, 8, 12)

        val addr = try { InetAddress.getByName(server) } catch (e: Exception) { return null }
        try { sock.send(DatagramPacket(req, 20, InetSocketAddress(addr, port))) } catch (e: Exception) { return null }

        val prevTimeout = sock.soTimeout
        sock.soTimeout = timeoutMs
        try {
            val buf = ByteArray(512)
            val deadline = System.nanoTime() + timeoutMs * 1_000_000L
            while (System.nanoTime() < deadline) {
                val pkt = DatagramPacket(buf, buf.size)
                try { sock.receive(pkt) } catch (e: Exception) { return null }
                val n = pkt.length
                if (n < 20) continue
                if (buf[0].toInt() != 0x01 || buf[1].toInt() != 0x01) continue   // Binding Success
                if ((0 until 12).any { buf[8 + it] != txid[it] }) continue
                var i = 20
                val end = 20 + ((buf[2].toInt() and 0xff) shl 8 or (buf[3].toInt() and 0xff))
                while (i + 4 <= minOf(end, n)) {
                    val type = (buf[i].toInt() and 0xff) shl 8 or (buf[i + 1].toInt() and 0xff)
                    val len = (buf[i + 2].toInt() and 0xff) shl 8 or (buf[i + 3].toInt() and 0xff)
                    val v = i + 4
                    if ((type == 0x0020 || type == 0x0001) && len >= 8 && v + len <= n &&
                        buf[v + 1].toInt() == 0x01) {
                        val xor = type == 0x0020
                        val rawPort = (buf[v + 2].toInt() and 0xff) shl 8 or (buf[v + 3].toInt() and 0xff)
                        val p = if (xor) rawPort xor (COOKIE ushr 16) else rawPort
                        val o = IntArray(4) { k ->
                            val b = buf[v + 4 + k].toInt() and 0xff
                            if (xor) b xor ((COOKIE ushr (8 * (3 - k))) and 0xff) else b
                        }
                        return Mapped("${o[0]}.${o[1]}.${o[2]}.${o[3]}", p and 0xffff)
                    }
                    i = v + len + ((4 - len % 4) % 4)
                }
            }
        } finally {
            sock.soTimeout = prevTimeout
        }
        return null
    }
}

/** This machine's address on its own network (wifi first, like en0-first on the Mac). */
fun localIPv4(): String? {
    var best: String? = null
    val ifaces = try { NetworkInterface.getNetworkInterfaces() } catch (e: Exception) { return null }
    for (nif in ifaces) {
        if (!nif.isUp || nif.isLoopback) continue
        for (a in nif.inetAddresses) {
            if (a is java.net.Inet4Address) {
                val ip = a.hostAddress ?: continue
                if (nif.name.startsWith("wlan") || nif.name.startsWith("en")) return ip
                if (best == null) best = ip
            }
        }
    }
    return best
}
