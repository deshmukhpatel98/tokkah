package com.tokkah.kin.net

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import kotlin.concurrent.thread

/**
 * One call: the socket, the handshake, the rendezvous race, the turn layer and
 * the jitter buffer. Platform-independent by design — the Android audio device
 * (or a test rig) drives [captureBlock] and [renderBlock]. Mirrors the wiring
 * main.swift does on the Mac.
 */
class CallSession(
    val room: String,
    val me: String = "droid-" + (100000..999999).random(),
    val base: String = Server.base,
) {
    val crypto = Crypto(room)
    val ring = RecvRing()
    val playout = Playout(ring)
    val gate = DuplexGate()
    val floor = Floor()
    val tsync = TimeSync()

    @Volatile var running = false; private set
    @Volatile var locked: InetSocketAddress? = null; private set
    @Volatile var peerCaps = 0; private set
    @Volatile var peerStatus = 0; private set
    @Volatile var peerStatusSeen = false; private set
    @Volatile var peerMuted = false; private set
    @Volatile var peerPlayed = 0; private set
    @Volatile var selfMuted = false
    @Volatile var speakers = true
    /** Set by the UI: this end has left, so stop sending. */
    @Volatile var ended = false

    var onState: ((String) -> Unit)? = null
    var onPeerVocal: ((Int) -> Unit)? = null
    /** A whole far-end video frame, reassembled. */
    var onVideoFrame: ((ByteArray, Long) -> Unit)? = null
    /** The far end asked for a keyframe (KMAGIC): make one now. */
    var onKeyframeRequest: (() -> Unit)? = null

    val video = VideoAssembler()
    @Volatile var camOn = false
    private var videoSeq = 0
    private val videoScratch = ByteArray(Wire.VHDR + Wire.VPAYLOAD)
    private var lastKeyReq = 0L
    private var firstVideoSeen = false

    private var sock: DatagramSocket? = null
    private var candidates = listOf<InetSocketAddress>()
    private var seq = 0
    private val sendScratch = ByteArray(Wire.HDR + 1 + Wire.FPP * 4 + 64)
    private val pcmScratch = ShortArray(Wire.FPP)
    private val lpcOut = ShortArray(Wire.FPP)
    private var mapped: Stun.Mapped? = null
    private var handshakesSent = 0
    private var lastStatusSent = -1

    val sendPcm16 get() = peerCaps and Wire.CAP_PCM16 != 0
    val sendLp get() = sendPcm16 && (peerCaps and Wire.CAP_PCM_LP != 0)
    val safetyCode get() = crypto.safetyCode

    fun start() {
        if (running) return
        running = true
        Rendezvous.warm(room)
        val s = DatagramSocket()
        s.reuseAddress = true
        sock = s
        // STUN BEFORE the receive loop starts, and on this same socket. It must
        // be this socket — a mapping discovered on another describes that
        // socket's hole — and it must be before, or the receive loop eats the
        // binding response, no public address is ever published, and the peer
        // can only find us by LAN candidate (measured: 28 s to connect).
        thread(isDaemon = true, name = "kin-signal") {
            mapped = Stun.discoverAny(s)
            thread(isDaemon = true, name = "kin-rx") { receiveLoop(s) }
            signalLoop(s)
        }
    }

    fun stop() {
        if (!running) return
        running = false
        repeat(4) { sendSealed(Wire.goodbye()) }
        Thread.sleep(120)
        sock?.close()
    }

    // ── the wire ─────────────────────────────────────────────────────────────

    var sendErrors = 0; private set
    var lastSendError: String? = null; private set
    var videoPacketsSent = 0; private set

    private fun sendRaw(b: ByteArray, n: Int = b.size) {
        val s = sock ?: return
        val targets = locked?.let { listOf(it) } ?: candidates
        for (t in targets) try { s.send(DatagramPacket(b, n, t)) }
        catch (e: Exception) { sendErrors++; lastSendError = "${e.javaClass.simpleName}: ${e.message}" }
    }

    private fun sendSealed(b: ByteArray, n: Int = b.size) {
        val sealed = crypto.seal(b, n)
        if (sealed != null) sendRaw(sealed) else { crypto.notePlaintextTx(); sendRaw(b, n) }
    }

    private fun signalLoop(s: DatagramSocket) {
        val local = localIPv4()?.let { "$it:${s.localPort}" }
        val addr = mapped?.let { "${it.ip}:${it.port}" }
        var lastRv = 0L
        var lastProbe = 0L
        var lastHello = 0L
        while (running) {
            val now = System.currentTimeMillis()
            if (now - lastRv > 1000) {
                lastRv = now
                val peers = Rendezvous.exchange(room, me, addr, local, base = base)
                if (peers != null) {
                    candidates = peers.filter { it.id != me }.flatMap { p ->
                        listOfNotNull(
                            InetSocketAddress(p.ip, p.port),
                            p.localIP?.let { InetSocketAddress(it, p.localPort!!) },
                            p.relayIP?.let { InetSocketAddress(it, p.relayPort!!) },
                        )
                    }
                }
            }
            if (candidates.isNotEmpty() || locked != null) {
                if (!crypto.established && now - lastHello > 300) {
                    lastHello = now
                    sendRaw(Wire.handshake(crypto.myPublic))
                    handshakesSent++
                }
                if (now - lastProbe > 500) {
                    lastProbe = now
                    sendSealed(Wire.packProbe(KinClock.now(), rxReport()))
                }
            }
            Thread.sleep(50)
        }
    }

    private fun rxReport(): Wire.RxReport {
        val r = Wire.RxReport()
        r.lost = ring.concealLost
        r.recovered = ring.recovered
        r.played = ring.played
        r.muted = selfMuted
        r.qLevel = 0
        var status = 0
        when (gate.vocal) {
            DuplexGate.Vocal.BACKCHANNEL -> status = status or Wire.ST_BACKCHAN
            DuplexGate.Vocal.CLAIM -> status = status or Wire.ST_CLAIM
            else -> {}
        }
        if (gate.voicingNow) status = status or Wire.ST_VOICING
        if (!camOn) status = status or Wire.ST_CAMOFF
        r.status = status
        r.endProbByte = 0
        return r
    }

    private fun receiveLoop(s: DatagramSocket) {
        val buf = ByteArray(4096)
        val plainBuf = ByteArray(4096)
        val fbuf = FloatArray(Wire.FPP)
        while (running) {
            val pkt = DatagramPacket(buf, buf.size)
            try { s.receive(pkt) } catch (_: Exception) { break }
            var b = buf
            var n = pkt.length
            var magic = Wire.magic(b, n)
            if (magic != Wire.HMAGIC) {
                val opened = crypto.open(buf.copyOf(n))
                if (opened != null) {
                    System.arraycopy(opened, 0, plainBuf, 0, opened.size)
                    b = plainBuf; n = opened.size
                    magic = Wire.magic(b, n)
                } else if (crypto.established) {
                    crypto.notePlaintextRx()
                }
            }
            when (magic) {
                Wire.HMAGIC -> {
                    val parsed = Wire.parseHandshake(b, n) ?: continue
                    peerCaps = parsed.second
                    if (crypto.adoptPeer(parsed.first)) {
                        locked = pkt.socketAddress as InetSocketAddress
                        sendRaw(Wire.handshake(crypto.myPublic))
                        onState?.invoke("encrypted")
                    }
                }
                Wire.TMAGIC -> {
                    val t4 = KinClock.now()
                    val p = Wire.parseT(b, n) ?: continue
                    locked = pkt.socketAddress as InetSocketAddress
                    p.report?.let { r ->
                        if (p.hasState) {
                            peerStatusSeen = true
                            peerStatus = r.status
                            peerMuted = r.muted
                            peerPlayed = r.played
                            val owd = (tsync.bestRttMs ?: 0.0) / 2
                            floor.noteFar(peerVoice(), transitMs = owd,
                                voicing = if (r.status and Wire.ST_VOICING != 0) true else false)
                            floor.noteFarEndProb(Wire.endProb(r.endProbByte))
                            val v = if (r.status and Wire.ST_CLAIM != 0) 2
                                    else if (r.status and Wire.ST_BACKCHAN != 0) 1 else 0
                            if (v != lastStatusSent) { lastStatusSent = v; onPeerVocal?.invoke(v) }
                        }
                    }
                    if (p.kind == 0) {
                        // Reply from THIS thread: a hop to another thread lands
                        // inside t3-t2 and biases the offset by half of it.
                        sendSealed(Wire.packReply(p.t1, t4, KinClock.now(), rxReport()))
                    } else {
                        tsync.note(p.t1, p.t2, p.t3, t4)
                    }
                }
                Wire.MAGIC -> {
                    locked = pkt.socketAddress as InetSocketAddress
                    val h = Wire.audioHeader(b, n) ?: continue
                    val frames = minOf(h.frames, Wire.FPP)
                    if (h.lp) {
                        val m = b[Wire.HDR].toInt() and 0xff
                        if (n < Wire.HDR + 1 + m) continue
                        val block = b.copyOfRange(Wire.HDR + 1, Wire.HDR + 1 + m)
                        if (!Lpc.decode(block, m, frames, lpcOut)) continue
                        for (i in 0 until frames) fbuf[i] = lpcOut[i] / 32767.0f
                    } else if (h.pcm16) {
                        if (n < Wire.HDR + frames * 2) continue
                        for (i in 0 until frames) {
                            val v = ((b[Wire.HDR + 2 * i].toInt() and 0xff) or
                                     (b[Wire.HDR + 2 * i + 1].toInt() shl 8)).toShort()
                            fbuf[i] = v / 32767.0f
                        }
                    } else {
                        if (n < Wire.HDR + frames * 4) continue
                        for (i in 0 until frames) {
                            fbuf[i] = java.lang.Float.intBitsToFloat(Wire.u32(b, Wire.HDR + 4 * i))
                        }
                    }
                    ring.write(h.seq, h.capHost, fbuf, frames)
                }
                Wire.VMAGIC -> {
                    val h = Wire.videoHeader(b, n) ?: continue
                    val len = n - Wire.VHDR
                    if (len <= 0) continue
                    video.offer(h, b, Wire.VHDR, len)?.let { (payload, cap) ->
                        firstVideoSeen = true
                        onVideoFrame?.invoke(payload, cap)
                    }
                    // Nothing decodable yet: ask for a keyframe, rate-limited.
                    // Parameter sets ride only with keyframes, so a receiver
                    // joining mid-stream has to ask rather than wait for a timer
                    // the sender does not run.
                    if (!firstVideoSeen) {
                        val now = System.currentTimeMillis()
                        if (now - lastKeyReq > 300) {
                            lastKeyReq = now
                            sendSealed(Wire.keyframeRequest())
                        }
                    }
                }
                Wire.KMAGIC -> onKeyframeRequest?.invoke()
                Wire.BMAGIC -> { onState?.invoke("peer left"); ended = true }
                else -> {}
            }
        }
    }

    private fun peerVoice(): Floor.Voice = when {
        peerStatus and Wire.ST_CLAIM != 0 -> Floor.Voice.CLAIM
        peerStatus and Wire.ST_BACKCHAN != 0 -> Floor.Voice.BACKCHANNEL
        else -> Floor.Voice.QUIET
    }

    // ── the audio device's two entry points ──────────────────────────────────

    /** One capture block: classify, apply the floor, and put it on the wire. */
    fun captureBlock(x: FloatArray, n: Int) {
        gate.process(x, n)
        floor.speakers = speakers
        val d = floor.step(n.toDouble() / Wire.SR, gate.toFloorVoice())
        gate.floorMuted = !d.mayTransmit
        gate.floorDucked = d.duckOnly
        gate.floorGranted = d.state == Floor.State.MINE
        playout.earOpen = d.playoutOpen
        floor.notePlayout(playout.playoutLive)
        if (ended || selfMuted || !crypto.established) return
        // FPP-sized packets on the wire whatever the device block size is.
        var at = 0
        while (at + Wire.FPP <= n) {
            val cap = KinClock.now()
            for (i in 0 until Wire.FPP) {
                val v = x[at + i]
                pcmScratch[i] = (maxOf(-1f, minOf(1f, v)) * 32767f).toInt().toShort()
            }
            val len = Wire.packAudio(seq, cap, pcmScratch, Wire.FPP,
                pcm16 = sendPcm16, lp = sendLp, out = sendScratch)
            sendSealed(sendScratch, len)
            seq++
            at += Wire.FPP
        }
    }

    /** One encoded frame out: fragmented to 1150-byte payloads, sealed per packet. */
    fun sendVideoFrame(payload: ByteArray) {
        if (ended || !crypto.established) return
        val cap = KinClock.now()
        val n = payload.size
        val nfrag = maxOf(1, (n + Wire.VPAYLOAD - 1) / Wire.VPAYLOAD)
        for (f in 0 until nfrag) {
            val off = f * Wire.VPAYLOAD
            val len = minOf(Wire.VPAYLOAD, n - off)
            val m = Wire.packVideoFragment(videoSeq, cap, f, nfrag, payload, off, len, videoScratch)
            sendSealed(videoScratch, m)
            videoPacketsSent++
        }
        videoSeq++
        if (videoSeq % 60 == 1) {
            android.util.Log.i("kin", "video out: seq=$videoSeq packets=$videoPacketsSent " +
                "errors=$sendErrors last=$lastSendError locked=$locked")
        }
    }

    /** One render block: the jitter buffer's answer for this device callback. */
    fun renderBlock(out: FloatArray, n: Int) {
        playout.render(out, n, gate)
    }

    fun statusLine(): String = buildString {
        append(if (crypto.established) "encrypted" else "connecting")
        safetyCode?.let { append(" · $it") }
        tsync.bestRttMs?.let { append(" · rtt %.0f ms".format(it)) }
        append(" · played ${ring.played} conceal ${ring.concealed}")
    }
}
