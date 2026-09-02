package com.tokkah.kin.harness

import com.tokkah.kin.net.Crypto
import com.tokkah.kin.net.KinClock
import com.tokkah.kin.net.Lpc
import com.tokkah.kin.net.Rendezvous
import com.tokkah.kin.net.Stun
import com.tokkah.kin.net.TimeSync
import com.tokkah.kin.net.Wire
import com.tokkah.kin.net.localIPv4
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress

// The Phase-1 gate: the exact net/ sources the APK ships, driven from a JVM
// process, against the real Mac app through the real signaling server.
// Success = handshake adopted both ways, safety codes match, encrypted
// time-sync converges, audio packets decode losslessly.
fun main(args: Array<String>) {
    val room = args.getOrNull(0) ?: error("usage: harness <room> [seconds]")
    val seconds = args.getOrNull(1)?.toIntOrNull() ?: 20
    val me = "droid-" + (100000..999999).random()

    Rendezvous.warm(room)
    val sock = DatagramSocket()
    sock.reuseAddress = true
    println("harness: socket on local port ${sock.localPort}")

    val mapped = Stun.discoverAny(sock)
    println("harness: stun says ${mapped?.ip}:${mapped?.port}")
    val local = localIPv4()?.let { "$it:${sock.localPort}" }
    val addr = mapped?.let { "${it.ip}:${it.port}" }

    val crypto = Crypto(room, ByteArray(32).also { java.security.SecureRandom().nextBytes(it) })
    val tsync = TimeSync()
    var peerAddrs = listOf<InetSocketAddress>()
    var lockedFrom: InetSocketAddress? = null
    var audioRx = 0
    var audioLpOk = 0
    var audioLpBad = 0
    var probesAnswered = 0
    var handshakesSent = 0
    var peerStatusSeen = false
    var peerMuted = false

    fun sendTo(b: ByteArray, n: Int = b.size) {
        val targets = lockedFrom?.let { listOf(it) } ?: peerAddrs
        for (t in targets) try { sock.send(DatagramPacket(b, n, t)) } catch (_: Exception) {}
    }
    fun sendMaybeSealed(b: ByteArray) {
        val sealed = crypto.seal(b)
        sendTo(sealed ?: b)
    }

    // Receive loop.
    val rx = Thread {
        val buf = ByteArray(4096)
        val plain = ByteArray(4096)
        while (!sock.isClosed) {
            val pkt = DatagramPacket(buf, buf.size)
            try { sock.receive(pkt) } catch (_: Exception) { break }
            var b = buf
            var n = pkt.length
            var magic = Wire.magic(b, n)
            if (magic == Wire.HMAGIC) { crypto.noteOldHandshake(); println("harness: UNSIGNED handshake refused"); continue }
            if (magic == Crypto.HS_MAGIC) {
                if (crypto.adoptHandshake(b, n) is Crypto.Adopt.Adopted) {
                    println("harness: peer key adopted (caps=${Crypto.capsOf(b, n)}) — ${crypto.summary}")
                    sendTo(crypto.handshakePacket()); handshakesSent++
                    lockedFrom = pkt.socketAddress as InetSocketAddress
                }
                continue
            }
            if (!crypto.established) { crypto.notePlaintextRx(); continue }
            val opened = crypto.open(buf.copyOf(n)) ?: continue
            System.arraycopy(opened, 0, plain, 0, opened.size)
            b = plain; n = opened.size
            magic = Wire.magic(b, n)
            when (magic) {
                Wire.TMAGIC -> {
                    val t4 = KinClock.now()
                    val p = Wire.parseT(b, n) ?: continue
                    lockedFrom = pkt.socketAddress as InetSocketAddress
                    if (p.hasState) { peerStatusSeen = true; peerMuted = p.report!!.muted }
                    if (p.kind == 0) {
                        // Reply from this thread, immediately (Net.swift:1702).
                        sendMaybeSealed(Wire.packReply(p.t1, t4, KinClock.now(), Wire.RxReport()))
                        probesAnswered++
                    } else {
                        tsync.note(p.t1, p.t2, p.t3, t4)
                    }
                }
                Wire.MAGIC -> {
                    audioRx++
                    lockedFrom = pkt.socketAddress as InetSocketAddress
                    val h = Wire.audioHeader(b, n) ?: continue
                    if (h.lp) {
                        val m = b[Wire.HDR].toInt() and 0xff
                        val dec = ShortArray(h.frames)
                        val block = b.copyOfRange(Wire.HDR + 1, Wire.HDR + 1 + m)
                        if (Lpc.decode(block, m, h.frames, dec)) audioLpOk++ else audioLpBad++
                    }
                }
                Wire.BMAGIC -> println("harness: peer said goodbye")
                else -> {}
            }
        }
    }
    rx.isDaemon = true
    rx.start()

    // Rendezvous + probe loop.
    val deadline = System.currentTimeMillis() + seconds * 1000L
    var lastRv = 0L
    var lastProbe = 0L
    var lastHello = 0L
    while (System.currentTimeMillis() < deadline) {
        val now = System.currentTimeMillis()
        if (now - lastRv > 1000) {
            lastRv = now
            val peers = Rendezvous.exchange(room, me, addr, local) ?: emptyList()
            val other = peers.filter { it.id != me }
            if (other.isNotEmpty() && peerAddrs.isEmpty()) println("harness: rendezvous sees ${other.size} peer(s)")
            peerAddrs = other.flatMap { p ->
                listOfNotNull(
                    InetSocketAddress(p.ip, p.port),
                    p.localIP?.let { InetSocketAddress(it, p.localPort!!) },
                    p.relayIP?.let { InetSocketAddress(it, p.relayPort!!) },
                )
            }
        }
        if (peerAddrs.isNotEmpty() || lockedFrom != null) {
            if (!crypto.established && now - lastHello > 300) {
                lastHello = now
                sendTo(crypto.handshakePacket()); handshakesSent++
            }
            if (now - lastProbe > 500) {
                lastProbe = now
                sendMaybeSealed(Wire.packProbe(KinClock.now(), Wire.RxReport()))
            }
        }
        Thread.sleep(50)
    }

    repeat(4) { sendMaybeSealed(Wire.goodbye()) }
    Thread.sleep(200)
    sock.close()

    println("=== P1 GATE RESULT ===")
    println("established: ${crypto.established}")
    println("safetyCode:  ${crypto.safetyCode}")
    println("sealed/opened/openFails: ${crypto.sealed}/${crypto.opened}/${crypto.openFails}")
    println("plaintextRxAfterKey: ${crypto.plaintextRx}")
    println("timeSync: samples=${tsync.samples} rtt=${tsync.bestRttMs?.let { "%.2f ms".format(it) }} spread=${tsync.rttSpreadMs?.let { "%.2f ms".format(it) }} theta=${tsync.thetaNs?.let { "%.3f ms".format(it / 1e6) }}")
    println("probesAnswered: $probesAnswered")
    println("audio: rx=$audioRx lpOk=$audioLpOk lpBad=$audioLpBad")
    println("peerStateSeen: $peerStatusSeen muted=$peerMuted")
    // A few open failures are the documented handshake race: plaintext still in
    // flight when the key lands (Crypto.swift:37-39 accepts and counts these).
    val pass = crypto.established && crypto.opened > 10 &&
        crypto.openFails <= 5 && crypto.openFails.toLong() == crypto.plaintextRx.toLong() &&
        tsync.samples >= 3 && audioLpBad == 0
    println(if (pass) "PASS" else "FAIL")
    kotlin.system.exitProcess(if (pass) 0 else 1)
}
