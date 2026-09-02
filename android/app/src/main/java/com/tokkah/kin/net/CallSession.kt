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
    /** Where the call record, telemetry and identity live. */
    val store: java.io.File? = null,
    /** The handle on the other end, when a ring told us. */
    val who: String = "",
    /** This install's Ed25519 seed (identity.json); a throwaway one when absent. */
    identitySeed: ByteArray? = null,
    /** The identity the other end MUST present, or null for first use. */
    peerKey: ByteArray? = null,
) {
    val crypto = Crypto(room,
        identitySeed ?: ByteArray(32).also { java.security.SecureRandom().nextBytes(it) },
        peerKey)
    /**
     * Fired on the receive thread when a NEW, verified identity keyed the call.
     * The argument is the peer's Ed25519 identity, raw -- what contacts.json
     * pins under the handle this call is with.
     */
    var onPeerIdentity: ((ByteArray) -> Unit)? = null
    val ring = RecvRing()
    val playout = Playout(ring)
    val gate = DuplexGate()
    val floor = Floor()
    val tsync = TimeSync()
    val held = Held()
    val vquality = VQuality()
    val resume: Resume? = store?.let { Resume(it) }
    val telemetry: Telemetry? = store?.let { Telemetry(it) }
    private val power = Power()
    val aec = Aec()
    /** Aims the canceller: without it `aimSamples` stays -1 and the AEC never runs. */
    val echoAim = EchoAim(aec)
    val predict = Predict()

    /**
     * The camera's verdict about THIS end. Only ever WITHDRAWS the echo veto:
     * it can open a microphone the correlation would have gagged, and it can
     * never close one. When the detector is blind it says nothing at all.
     */
    @Volatile var visualKnown = false
    @Volatile var visualVoice = false

    /**
     * What LEFT the speaker, for the canceller to subtract. Not what the far
     * end sent: the estimator that aims the filter reads the RAW microphone,
     * and a canceller keyed on its own success collapses the correlation it
     * steers by.
     */
    val emitRing = FloatArray(1 shl 16)
    @Volatile var emitW = 0
    @Volatile private var cpuUser = 0.0
    @Volatile private var cpuSys = 0.0

    @Volatile var running = false; private set
    @Volatile var locked: InetSocketAddress? = null; private set
    @Volatile var peerCaps = 0; private set
    @Volatile var peerStatus = 0; private set
    @Volatile var peerStatusSeen = false; private set
    @Volatile var peerMuted = false; private set
    /** The two reasons a picture stops, kept apart (Net.swift 917-918). */
    val peerVideoPaused: Boolean get() = peerStatus and Wire.ST_VPAUSED != 0
    val peerCamOff: Boolean get() = peerStatus and Wire.ST_CAMOFF != 0
    /** Our own video, stopped because the link could not carry it. */
    val selfVideoPaused: Boolean get() = vquality.paused
    @Volatile var peerPlayed = 0; private set
    @Volatile var peerSeenTalking = false; private set
    @Volatile var peerSeenTalkingSeen = false; private set
    @Volatile var selfMuted = false
    @Volatile var speakers = true
    /** Set by the UI: this end has left, so stop sending. */
    @Volatile var ended = false
    // ── A BLIP AND A DEPARTURE ARE NOT THE SAME THING (main.swift 3915-4000) ─
    //
    // From the media side they are identical: silence. From the DIRECTORY they
    // are not: a peer that has left stops republishing, and every entry carries
    // `ageMs`. While a call is open this end HOLDS — the timer keeps running,
    // the picture stays — until the room forgets them (90 s with nobody
    // republishing), which is the shared fact both ends read.
    /** Rendezvous ticks in a row with no fresh peer entry (< 4 s old). */
    @Volatile var peerGone = 0; private set
    /** The far end went quiet without a goodbye; the call is being held open. */
    @Volatile var holding = false; private set
    /** The room's lease on them expired: they are gone, not paused. */
    @Volatile var left = false; private set
    /** Host ms of the last packet that came from the peer, 0 before any. */
    @Volatile var lastFromPeerMs = 0L; private set
    /** Media silent for a moment while the directory still has them. */
    val reconnecting: Boolean get() =
        crypto.established && !ended && !left && !holding && lastFromPeerMs != 0L &&
            System.currentTimeMillis() - lastFromPeerMs > 2000

    /** The honest sentence, or null when there is nothing to say. */
    @Volatile var heldSentence: String? = null; private set
    @Volatile var callSeconds = 0; private set

    var onState: ((String) -> Unit)? = null
    var onPeerVocal: ((Int) -> Unit)? = null
    /** A word from the quiet side, and whether the recogniser is done with it. */
    var onText: ((String, Boolean, Boolean) -> Unit)? = null
    /** The far end's cue level, eased. */
    val cue = FloorCue()

    /** Text only, never audio: the words cross, the microphone does not. */
    fun sendText(text: String, final: Boolean, listening: Boolean) {
        if (ended || !crypto.established) return
        predict.noteText(text, System.currentTimeMillis().toDouble())
        sendSealed(Wire.packText(text, final, listening))
    }

    /** A whole far-end video frame, reassembled. */
    /**
     * A completed video frame. Delivered on the DECODE thread, not the receive
     * thread — see [DecodeQueue]. The array handed over is the queue's own slot
     * and is valid only for the length of the call, which is why the handler
     * must not retain it.
     */
    var onVideoFrame: ((ByteArray, Long) -> Unit)? = null
        set(v) {
            field = v
            // The queue exists only while somebody is decoding, and it holds
            // 768 KiB of slots: on an audio-only call that is memory for nothing.
            //
            // It reads `onVideoFrame` at DECODE time rather than capturing the
            // handler here. This callback is deliberately chained — VideoDevice
            // wraps whatever MainActivity installed — so a queue built around
            // the first assignment would have pinned the face-detector and
            // silently dropped the decoder that replaced it. A handler that is
            // assigned and never invoked reads as finished and does nothing.
            if (v != null && decodeQueue == null && useDecodeQueue) {
                decodeQueue = DecodeQueue { buf, n, host ->
                    onVideoFrame?.invoke(if (n == buf.size) buf else buf.copyOf(n), host)
                }
            }
        }

    @Volatile private var decodeQueue: DecodeQueue? = null

    /**
     * RIG ONLY. Off puts the decode back inline on the receive thread, which is
     * the behaviour this replaced — so a video call that goes wrong can be
     * attributed to the queue or cleared of it in one arm, instead of being
     * argued about.
     */
    @Volatile var useDecodeQueue = true

    /** Frames that had to decode inline anyway, for the beat. */
    val decodeInline: Int get() = (decodeQueue?.inlineFull ?: 0) + (decodeQueue?.inlineTooBig ?: 0)
    val decodeDepth: Int get() = decodeQueue?.maxDepth ?: 0
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
    /**
     * The relay. FAIL-OPEN: every failure leaves the direct paths racing
     * exactly as they were, because a relay that cannot be allocated must never
     * stop a call that would have worked without it.
     */
    @Volatile var turn: Turn? = null; private set
    /** Control arm: prove what the relay costs before believing it is free. */
    @Volatile var useTurn = true
    /** Only once a peer is actually bound is the channel worth sending into. */
    @Volatile private var turnBound = false
    private val bound = HashSet<String>()
    private var handshakesSent = 0
    private var lastStatusSent = -1
    // ── AUDIO REDUNDANCY (main.swift 6380-6440) ─────────────────────────────
    //
    // Turned on when the far end reports loss, off after 30 s without any, and
    // switched off with a backoff when what it recovers is under 40% of what is
    // lost -- bursts a one-packet offset cannot reach, not worth the bandwidth.
    @Volatile var redundancy = false; private set
    private val prevBlock = ShortArray(Wire.FPP)
    private var prevCap = 0L
    private var havePrev = false
    @Volatile var peerRxLost = 0; private set
    @Volatile var peerRxRecovered = 0; private set
    @Volatile var peerReportsLoss = false; private set
    private var lastLostForFec = 0
    private var fecRecovered0 = 0; private var fecLost0 = 0
    private var fecWindows = 0; private var fecCalm = 0
    private var fecUselessUntil = 0.0; private var fecBackoff = 60.0
    var redundantSent = 0; private set
    // ── THE BEAT'S DENOMINATORS ─────────────────────────────────────────────
    @Volatile private var txBytes = 0L
    @Volatile private var rxBytes = 0L
    @Volatile private var capFrames = 0L
    @Volatile private var floorBlocks = 0
    @Volatile private var floorHeldBlocks = 0
    @Volatile private var keyAsksIn = 0
    /** Per-second rates, computed once a beat in [reportLoop]. */
    @Volatile private var upMbps = 0.0
    @Volatile private var downMbps = 0.0
    @Volatile private var playedPs = 0
    @Volatile private var concealPs = 0
    @Volatile private var capPs = 0
    /** What the video device knows and this class does not: enc/dec fps, size. */
    var videoStats: (() -> IntArray)? = null   // [encoded, decoded, w, h]
    private var lastVideoStats = IntArray(4)
    @Volatile private var vEncPs = 0
    @Volatile private var vDecPs = 0

    val sendPcm16 get() = peerCaps and Wire.CAP_PCM16 != 0
    val sendLp get() = sendPcm16 && (peerCaps and Wire.CAP_PCM_LP != 0)
    val safetyCode get() = crypto.safetyCode

    companion object {
        /** worker.ts: short enough that a stale mapping is never offered as a live one. */
        const val ROOM_LEASE_MS = 90_000L
    }

    fun start() {
        if (running) return
        running = true
        playout.emit = { v ->
            emitRing[emitW % emitRing.size] = v
            emitW++
            echoAim.noteEmit(v)
        }
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
            Metrics.mark("stun_ms", Metrics.sinceLaunch())
            // On the SAME socket as the media and STUN, before the receive loop
            // starts: an allocation on another socket relays that socket, and
            // the round trips here would be eaten by the reader.
            if (useTurn) runCatching {
                val t = Turn.mint(base)
                android.util.Log.i("kin", "turn: mint ${if (t == null) "failed" else "ok"}")
                if (t != null) {
                    // Reads for itself only here, before the loop exists.
                    t.readDirectly = true
                    val okA = t.allocate(s)
                    android.util.Log.i("kin", "turn: allocate=$okA relay=${t.relay} err=${t.lastError}")
                    if (okA) {
                        turn = t
                        Metrics.mark("turn_ms", Metrics.sinceLaunch())
                    } else {
                        // Named, not merely absent: a relay that could not be
                        // allocated and a relay nobody asked for read the same
                        // on a dashboard, and only one of them is a fault.
                        Metrics.mark("turn_blocked_ms", Metrics.sinceLaunch())
                        Metrics.fact("turn_blocked", t.lastError ?: "?")
                    }
                }
                android.util.Log.i("kin", "turn: soTimeout after = ${s.soTimeout}")
            }
            // From here the receive loop owns the socket, and TURN's replies
            // come through it.
            turn?.readDirectly = false
            thread(isDaemon = true, name = "kin-rx") { receiveLoop(s) }
            thread(isDaemon = true, name = "kin-report") { reportLoop(s) }
            // The Mac's cadence: a delay estimate every half second, off every
            // hot path. Only while the sound could be coming back through a
            // loudspeaker — on headphones there is no echo to aim at.
            thread(isDaemon = true, name = "kin-echo-aim") {
                while (running) {
                    Thread.sleep(500)
                    if (speakers) runCatching { echoAim.tick() }
                }
            }
            signalLoop(s)
        }
    }

    /**
     * Once a second, off every hot path: the honesty state, the call record on
     * disk, the quality controller, and the beat.
     */
    private fun reportLoop(s: DatagramSocket) {
        var lastPlayed = 0
        var lastConceal = 0
        var lastFrames = 0
        var lastFrags = 0
        var t0 = 0L
        var beatAt = 0L
        var lastTx = 0L; var lastRx = 0L; var lastCap = 0L
        while (running) {
            Thread.sleep(1000)
            val played = ring.played - lastPlayed
            val concealed = ring.concealed - lastConceal
            // Per-second, the Mac's units: packets played and concealed, frames
            // captured, megabits each way.
            playedPs = played; concealPs = concealed
            capPs = ((capFrames - lastCap) / Wire.FPP).toInt(); lastCap = capFrames
            upMbps = (txBytes - lastTx) * 8 / 1e6; lastTx = txBytes
            downMbps = (rxBytes - lastRx) * 8 / 1e6; lastRx = rxBytes
            // ── REDUNDANCY, STEERED ON THE FAR END'S LOSS ────────────────────
            if (crypto.established && callSeconds % 2 == 0) {
                val t = callSeconds.toDouble()
                val lostTotal = if (peerReportsLoss) peerRxLost else ring.concealLost
                val recTotal = if (peerReportsLoss) peerRxRecovered else ring.recovered
                var lostNow = lostTotal - lastLostForFec
                if (lostNow < 0) { lostNow = 0; fecRecovered0 = recTotal; fecLost0 = lostTotal }
                lastLostForFec = lostTotal
                if (lostNow > 0 && !redundancy && t >= fecUselessUntil) {
                    redundancy = true; fecRecovered0 = recTotal; fecLost0 = lostTotal; fecWindows = 0; fecCalm = 0
                    Metrics.count("fec_on")
                    android.util.Log.i("kin", "redundancy ON ($lostNow lost in 2 s) -- each packet now carries the previous one")
                } else if (redundancy) {
                    fecWindows++
                    val rec = maxOf(0, recTotal - fecRecovered0); val lost = maxOf(0, lostTotal - fecLost0)
                    if (fecWindows >= 5 && rec + lost >= 20 && rec.toDouble() / (rec + lost) < 0.4) {
                        redundancy = false; fecUselessUntil = t + fecBackoff; fecBackoff = minOf(fecBackoff * 2, 600.0); fecCalm = 0
                        Metrics.count("fec_useless")
                        android.util.Log.i("kin", "redundancy OFF -- recovered only $rec of ${rec + lost}; retrying in ${(fecBackoff / 2).toInt()} s")
                    } else if (lostNow > 0) fecCalm = 0 else if (++fecCalm >= 15) {
                        redundancy = false; fecCalm = 0; fecBackoff = 60.0
                        android.util.Log.i("kin", "redundancy OFF (30 s without a lost packet)")
                    }
                }
            }
            // peer − mine, refreshed once a beat for the playout's ear stamp.
            playout.thetaMs = tsync.thetaNs?.let { it / 1e6 }
            videoStats?.invoke()?.let { v ->
                vEncPs = v[0] - lastVideoStats[0]; vDecPs = v[1] - lastVideoStats[1]
                lastVideoStats = v
            }
            val frames = video.framesOut - lastFrames
            val frags = video.fragsIn - lastFrags
            lastPlayed = ring.played; lastConceal = ring.concealed
            lastFrames = video.framesOut; lastFrags = video.fragsIn

            cue.vocal = when {
                peerStatus and Wire.ST_CLAIM != 0 -> 2
                peerStatus and Wire.ST_BACKCHAN != 0 -> 1
                else -> 0
            }
            cue.step(1f)
            held.beat(concealed, played, frames, frags)
            heldSentence = held.sentence

            if (crypto.established) {
                if (t0 == 0L) {
                    t0 = System.currentTimeMillis()
                    // The record is written at the TRANSPORT LOCK, not at
                    // launch: a process that never found anybody was never in
                    // a call, and a hopeful record sends the next launch into
                    // an empty room.
                    resume?.begin(room, s.localPort, locked?.toString() ?: "",
                        who, telemetry?.call ?: "")
                    onTransportLock?.invoke()
                }
                callSeconds = ((System.currentTimeMillis() - t0) / 1000).toInt()
                resume?.touch(locked?.toString())
                power.sample()?.let { (u, sy) -> cpuUser = u; cpuSys = sy }
                vquality.tick(callSeconds.toDouble(), 0, concealed, false)
                    ?.let { onQuality?.invoke(it) }

                val now = System.currentTimeMillis()
                if (now - beatAt > 5000) {
                    beatAt = now
                    telemetry?.post(beatFields(), version = appVersion)
                }
            }
        }
    }

    var onQuality: ((Double) -> Unit)? = null
    /** Fired once, when the transport locks: the only moment geo may be taken. */
    var onTransportLock: (() -> Unit)? = null
    @Volatile var geoLat: Double? = null
    @Volatile var geoLon: Double? = null
    @Volatile var geoErr: String? = null
    /** What is actually installed, so a beat cannot claim a version it is not. */
    @Volatile var appVersion: String = Telemetry.VERSION

    /**
     * The beat, under the MAC'S FIELD NAMES. The fleet dashboard reads one
     * schema, and a phone that invented its own showed up in `telemetry.sh
     * recent` as a row of -1s: a call with no floor, no echo and no turns, which
     * is not what happened on it. Every number here is one the phone actually
     * measures; a quantity this build does not measure is ABSENT, never zero
     * (`blind-instruments-report-negatives`). The room name is never here: it
     * is the encryption salt.
     */
    fun beatFields(): Map<String, Any?> {
        val f = LinkedHashMap<String, Any?>()
        val vs = lastVideoStats
        f["platform"] = "android"
        f["uptime_s"] = Metrics.sinceLaunch() / 1000
        f["up_mbps"] = upMbps; f["down_mbps"] = downMbps
        f["played_ps"] = playedPs; f["conceal_ps"] = concealPs; f["cap_ps"] = capPs
        f["mic_muted"] = if (selfMuted) 1 else 0
        f["mic_access"] = 1
        f["io"] = "hal"
        if (!crypto.established) { f["pre_connect"] = 1; f.putAll(Metrics.beatFields()); return f }
        f["jit"] = playout.jitTarget
        f["devbuf"] = playout.devBuf
        f["secs"] = callSeconds
        f["ended"] = if (ended) 1 else 0
        // the far end, as it reports itself
        f["peer_played"] = peerPlayed
        f["mute"] = if (peerMuted) 1 else 0; f["a_peer_muted"] = if (peerMuted) 1 else 0
        f["peer_status"] = peerStatus
        f["peer_state_reports"] = if (peerStatusSeen) 1 else 0
        f["peer_seen_talking"] = if (!peerSeenTalkingSeen) -1 else if (peerSeenTalking) 1 else 0
        f["v_peer_cam_off"] = if (peerCamOff) 1 else 0
        f["v_peer_paused_now"] = if (peerVideoPaused) 1 else 0
        // the floor and the gate
        f["floor_blocks"] = floorBlocks
        f["floor_held_pct"] = if (floorBlocks > 0) 100.0 * floorHeldBlocks / floorBlocks else 0.0
        f["floor_muted_pct"] = if (floorBlocks > 0) 100.0 * floorHeldBlocks / floorBlocks else 0.0
        f["floor_strict"] = 1
        f["floor_duplex_pct"] = if (floor.askedBlocks > 0) 100.0 * floor.duplexBlocks / floor.askedBlocks else 0.0
        f["floor_aec_duplex_pct"] = if (floor.askedBlocks > 0) 100.0 * floor.aecDuplexBlocks / floor.askedBlocks else 0.0
        f["floor_spk_duplex"] = if (floor.cfg.speakerDuplex) 1 else 0
        f["floor_hp_duplex"] = if (floor.cfg.headphoneDuplex) 1 else 0
        f["echo_guard_pct"] = if (floor.guardableBlocks > 0) 100.0 * floor.echoGuardBlocks / floor.guardableBlocks else 0.0
        f["turn_claims"] = gate.claims; f["turn_backchannels"] = gate.backchannels
        f["backchannels"] = gate.backchannels
        f["turn_grace_onsets"] = floor.graceOnsets; f["turn_fast_takes"] = floor.fastTakes
        f["turn_visual_takes"] = floor.visualTakes; f["turn_seen_releases"] = floor.seenReleases
        f["predict_releases"] = floor.predictedReleases
        f["predict_saved_ms"] = floor.predictedSavedMs
        f["predict_far_releases"] = floor.farPredictedReleases
        f["predict_far_saved_ms"] = floor.farPredictedSavedMs
        f["predict_p_now"] = predict.probability(System.currentTimeMillis().toDouble())
        f["predict_peer_p_peak"] = floor.farEndProbPeak
        f["pred_syntax"] = predict.lastSyntax; f["pred_fall"] = predict.lastFall
        f["speakers"] = if (speakers) 1 else 0
        // the canceller
        f["aec_on"] = 1
        f["aec_erle_db"] = aec.erleDb
        f["aec_erle_life_db"] = aec.erleLifetimeDb
        f["aec_residual"] = aec.residual.toDouble()
        f["aec_diverges"] = aec.diverges
        f["aec_reaims"] = aec.reaims; f["aec_reaims_held"] = aec.reaimsHeld
        f["aec_skew_sps"] = aec.skewSps.toDouble(); f["aec_carries"] = aec.carries
        f["aec_skew_updates"] = aec.dllSteps; f["aec_track_resets"] = aec.dllResets
        f["aec_skew_rejects"] = aec.skewRejects
        f["aec_off_pct"] = if (aec.blocks > 0) 100.0 * aec.offBlocks / aec.blocks else 0.0
        f["aec_delay_ms"] = aec.aimSamples.toDouble() / Wire.SR * 1000
        f["echo_corr"] = echoAim.echoCorr; f["echo_corr_peak"] = echoAim.echoCorrPeak
        f["echo_ticks"] = echoAim.scans; f["echo_skips"] = echoAim.skips
        // the ring
        f["played"] = ring.played
        f["conceal_total"] = ring.concealed; f["conceal_lost"] = ring.concealLost
        f["conceal_starved"] = ring.concealStarved
        f["a_conceal_ms_max"] = playout.concealMaxRun * 1000.0 / Wire.SR
        f["late"] = ring.lateArrivals; f["near_late"] = ring.nearLate
        f["snaps"] = ring.snaps; f["snaps_behind"] = ring.snapsBehind; f["snaps_past"] = ring.snapsPast
        f["dup"] = ring.dup; f["too_old"] = ring.tooOld; f["jumps"] = ring.jumps
        f["recv"] = ring.recv; f["accepted"] = ring.accepted
        f["peer_restarts"] = ring.restarts
        f["fec_on"] = if (redundancy) 1 else 0; f["fec_sent"] = redundantSent
        f["recovered"] = ring.recovered
        f["peer_rx_lost"] = peerRxLost; f["peer_rx_recovered"] = peerRxRecovered
        f["peer_reports"] = if (peerReportsLoss) 1 else 0
        f["hold"] = held.sentence ?: "-"
        f["conceal_frac"] = held.lastFrac
        // the wire
        f["route"] = if (locked == null) 0 else if (locked == relaySocketAddr()) 2 else 1
        f["turn_ok"] = if (turn != null) 1 else 0
        f["relay"] = turn?.relay ?: "-"
        f["probes"] = tsync.samples
        playout.m2eP(0.50)?.let { f["m2e_p50"] = it }
        playout.m2eP(0.95)?.let { f["m2e_p95"] = it }
        playout.m2eP(0.99)?.let { f["m2e_p99"] = it }
        f["in_lat_ms"] = playout.inLatencyMs; f["out_lat_ms"] = playout.outLatencyMs
        tsync.bestRttMs?.let { f["rtt_ms"] = it }
        tsync.rttSpreadMs?.let { f["rtt_jit_ms"] = it }
        crypto.beatFields(f)
        f["send_errors"] = sendErrors; f["rx_errors"] = rxErrors
        f["peer_held"] = if (holding) 1 else 0
        // the picture
        f["v_enc_ps"] = vEncPs; f["v_dec_ps"] = vDecPs
        f["v_rx_w"] = vs[2]; f["v_rx_h"] = vs[3]
        f["v_frags"] = video.fragsIn; f["v_partial_drops"] = video.dropped
        f["vframes"] = video.framesOut
        f["v_key_asks_in"] = keyAsksIn
        f["v_q_level"] = vquality.level; f["vquality"] = vquality.quality
        f["v_q_downs"] = vquality.stepDowns; f["v_q_ups"] = vquality.stepUps
        f["v_paused_now"] = if (vquality.paused) 1 else 0; f["v_pauses"] = vquality.pauses
        f["v_paused_s"] = vquality.pausedTicks
        f["v_dq_inline_full"] = decodeQueue?.inlineFull ?: 0
        f["v_dq_inline_big"] = decodeQueue?.inlineTooBig ?: 0
        f["v_dq_depth_max"] = decodeDepth
        // vision, and where
        f["seen_talking"] = peerSeenTalkingSeen
        f["visual_known"] = visualKnown
        f["geo_lat"] = geoLat; f["geo_lon"] = geoLon
        f["geo_err"] = geoErr
        // the machine
        f["cpu"] = cpuUser + cpuSys; f["cpu_usr"] = cpuUser; f["cpu_sys"] = cpuSys
        f["cpu_valid"] = 1
        f["tel_hot_refused"] = Metrics.refusedOnAudioThread
        f.putAll(Metrics.beatFields())
        return f
    }

    /**
     * A person hung up. THE ONLY thing that ends a call: not the process
     * ending, not a crash, which is the whole reason the record exists.
     */
    fun stop(hungUp: Boolean = true) {
        if (!running) return
        running = false
        Metrics.fact("outcome", if (hungUp) "hung_up" else "ended")
        repeat(4) { sendSealed(Wire.goodbye()) }
        telemetry?.post(beatFields(), phase = "final", version = appVersion)
        if (hungUp) resume?.end()
        Thread.sleep(150)
        decodeQueue?.stop()
        sock?.close()
    }

    // ── the wire ─────────────────────────────────────────────────────────────

    var sendErrors = 0; private set
    var rxErrors = 0; private set
    var rxPackets = 0; private set
    private var rvLogs = 0
    var lastSendError: String? = null; private set
    var videoPacketsSent = 0; private set

    /**
     * RIG ONLY. Suppresses the direct sends so every packet has to ride the
     * relay, because a relayed path that is never exercised is a path nobody
     * has tested: on a LAN both ends lock to each other in a tenth of a
     * millisecond and the channel data is ignored, so "the relay did not break
     * the call" is not the same claim as "the relay works".
     */
    @Volatile var relayOnly = false

    private fun sendRaw(b: ByteArray, n: Int = b.size) {
        val s = sock ?: return
        val targets = if (relayOnly && turnBound) emptyList()
                      else locked?.let { listOf(it) } ?: candidates
        for (t in targets) try { s.send(DatagramPacket(b, n, t)); txBytes += n + 28 }
        catch (e: Exception) { sendErrors++; lastSendError = "${e.javaClass.simpleName}: ${e.message}" }
        // And through our own allocation, so the relayed path is in the same
        // race rather than a thing we fall back to after failing. ADDITIVE:
        // never instead of the direct send, so a relay that is wrong about
        // anything cannot cost a call that would have worked without it.
        if (turnBound) turn?.let { runCatching { it.sendChannel(s, b, n) } }
    }

    private fun sendSealed(b: ByteArray, n: Int = b.size) {
        // No key, nothing sent. v1 fell through to plaintext here "until the
        // handshake completed", which an attacker could hold open by dropping
        // handshakes. Dropped and counted instead.
        val sealed = crypto.seal(b, n)
        if (sealed != null) sendRaw(sealed) else crypto.notePreKeyDrop()
    }

    private fun signalLoop(s: DatagramSocket) {
        val local = localIPv4()?.let { "$it:${s.localPort}" }
        val addr = mapped?.let { "${it.ip}:${it.port}" }
        // Published beside the direct ones, and raced by measured round trip
        // rather than preferred or avoided: on a long route the relay's
        // backbone is sometimes genuinely shorter than the public internet.
        val relay = turn?.relay
        var lastRv = 0L
        var lastProbe = 0L
        var lastHello = 0L
        while (running) {
            val now = System.currentTimeMillis()
            if (now - lastRv > 1000) {
                lastRv = now
                val peers = Rendezvous.exchange(room, me, addr, local, relay, base = base)
                if (peers != null) {
                    val others = peers.filter { it.id != me }
                    // The directory is consulted only while the MEDIA is silent,
                    // the way the Mac only refreshes it once unlocked: a peer that
                    // is talking to us is here whatever its entry's age says (a
                    // locked Mac stops republishing, and its entry goes stale
                    // while its voice keeps arriving).
                    val mediaFresh = lastFromPeerMs != 0L &&
                        System.currentTimeMillis() - lastFromPeerMs < 2000
                    if (mediaFresh || others.any { it.ageMs < 4000 }) {
                        peerGone = 0
                        if (holding) { holding = false; Metrics.count("peer_back") }
                    } else if (crypto.established && !ended) {
                        peerGone++
                        if (peerGone >= 4 && !holding && !left) {
                            holding = true
                            Metrics.count("peer_held")
                            android.util.Log.i("kin", "room $room: they went quiet without hanging up -- holding the call open")
                        }
                        // The room has forgotten them: nobody publishing for
                        // the lease. Only a REAL answer with an empty list
                        // counts; null is this end failing to ask.
                        if (others.isEmpty() && lastFromPeerMs != 0L &&
                            System.currentTimeMillis() - lastFromPeerMs > ROOM_LEASE_MS && !left) {
                            left = true; holding = false
                            Metrics.count("peer_left")
                            android.util.Log.i("kin", "room $room: nobody has been here for ${ROOM_LEASE_MS / 1000} s -- treating that as gone")
                            resume?.end()
                        }
                    }
                    candidates = others.flatMap { p ->
                        listOfNotNull(
                            InetSocketAddress(p.ip, p.port),
                            p.localIP?.let { InetSocketAddress(it, p.localPort!!) },
                            p.relayIP?.let { InetSocketAddress(it, p.relayPort!!) },
                        )
                    }
                    // Permission and a channel for each peer candidate, so the
                    // relay will actually carry to them — ONCE per peer, not on
                    // every rendezvous tick. The channel is a standing binding,
                    // and re-issuing it every second is work that buys nothing.
                    turn?.let { t ->
                        for (p in peers.filter { it.id != me }) {
                            val k = "${p.ip}:${p.port}"
                            if (k in bound) continue
                            if (runCatching { t.bindPeer(s, p.ip, p.port) }.getOrDefault(false)) {
                                bound.add(k)
                                turnBound = true
                            }
                        }
                    }
                }
                if (rvLogs < 4) {
                    rvLogs++
                    android.util.Log.i("kin", "rv: addr=$addr local=$local relay=$relay " +
                        "peers=${peers?.size ?: -1} cands=${candidates.size} bound=$turnBound")
                }
            }
            if (candidates.isNotEmpty() || locked != null) {
                // The Mac's cadence: every 250 ms until the key is agreed, then
                // every 5 s as a keepalive of the key -- a peer that restarts
                // learns our key again without waiting for us to notice.
                if (now - lastHello > (if (crypto.established) 5000 else 300)) {
                    lastHello = now
                    sendRaw(crypto.handshakePacket())
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

    /** The address our own allocation would appear as, for the `path` fact. */
    private fun relaySocketAddr(): InetSocketAddress? =
        turn?.let { if (it.relayIP.isEmpty()) null else InetSocketAddress(it.relayIP, it.relayPort) }

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
        // Their camera's verdict, on the wire beside the voice cue it belongs
        // with — the earliest evidence anywhere in this system that somebody is
        // about to speak.
        if (visualKnown && visualVoice) status = status or Wire.ST_SEEN_TALKING
        if (!camOn) status = status or Wire.ST_CAMOFF
        r.status = status
        // Computed where the words are, applied where the gate is. Zero is what
        // an older build writes, and zero changes nothing.
        r.endProbByte = Wire.endProbByte(
            predict.probability(System.currentTimeMillis().toDouble()))
        return r
    }

    private fun receiveLoop(s: DatagramSocket) {
        android.util.Log.i("kin", "rx: loop started")
        try {
            receiveLoopInner(s)
        } catch (t: Throwable) {
            // A receive loop that dies takes the whole call with it and says
            // nothing: every counter stays healthy and the audio simply never
            // arrives. It must never end silently.
            rxErrors++
            android.util.Log.e("kin", "rx: loop died — ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    private fun receiveLoopInner(s: DatagramSocket) {
        val buf = ByteArray(4096)
        val plainBuf = ByteArray(4096)
        val fbuf = FloatArray(Wire.FPP)
        while (running) {
            val pkt = DatagramPacket(buf, buf.size)
            try {
                s.receive(pkt)
            } catch (e: java.net.SocketTimeoutException) {
                // A DEADLINE IS NOT A DEAD SOCKET. This loop used to break on
                // any exception, so one leftover SO_TIMEOUT — set by STUN or by
                // a TURN round trip and restored a moment later — killed the
                // receive path for the whole call. The symptom was total
                // silence with every other counter healthy, and it looked
                // exactly like the relay being at fault.
                continue
            } catch (e: Exception) {
                if (s.isClosed || !running) break
                // Anything else: count it and carry on rather than ending the
                // call on one bad datagram.
                rxErrors++
                continue
            }
            var b = buf
            var n = pkt.length
            // A relayed datagram arrives wrapped in a 4-byte channel header.
            val fromAddr = pkt.socketAddress as? InetSocketAddress
            // A TURN control reply belongs to whoever asked for it, not here.
            if (fromAddr != null && turn?.offerReply(buf, n, fromAddr) == true) continue
            if (fromAddr != null) turn?.unwrap(buf, n, fromAddr)?.let { (o, len) ->
                n = len
                b = buf.copyOfRange(o, o + len)
            }
            rxPackets++
            rxBytes += pkt.length + 28
            if (rxPackets % 500 == 1) {
                android.util.Log.i("kin", "rx: $rxPackets packets, established=${crypto.established}")
            }
            var magic = Wire.magic(b, n)
            if (locked != null && fromAddr == locked) lastFromPeerMs = System.currentTimeMillis()
            // An UNSIGNED (v1) handshake: the far end is a build from before the
            // handshake was signed. Refused and counted; never keyed.
            if (magic == Wire.HMAGIC) { crypto.noteOldHandshake(); continue }
            if (magic == Crypto.HS_MAGIC) {
                Metrics.mark("peer_found_ms", Metrics.sinceLaunch())
                when (val a = crypto.adoptHandshake(b, n)) {
                    is Crypto.Adopt.Adopted -> {
                        android.util.Log.i("kin", "rx: handshake -- ${crypto.summary}")
                        peerCaps = Crypto.capsOf(b, n)
                        // A fresh handshake is somebody ARRIVING: a call that
                        // said "hung up" and then met a new key is live again.
                        ended = false; left = false; holding = false; peerGone = 0
                        // The address is adopted only from a VERIFIED handshake.
                        locked = pkt.socketAddress as InetSocketAddress
                        sendRaw(crypto.handshakePacket())
                        Metrics.mark("connected_ms", Metrics.sinceLaunch())
                        // Which path won the race, which is the first question
                        // asked of any call that sounded wrong.
                        Metrics.fact("path", if (locked == relaySocketAddr()) "relay" else "direct")
                        crypto.peerIdentity?.let { onPeerIdentity?.invoke(it) }
                        onState?.invoke("encrypted")
                    }
                    is Crypto.Adopt.Unchanged -> { if (locked == null) locked = pkt.socketAddress as InetSocketAddress }
                    is Crypto.Adopt.Refused -> android.util.Log.i("kin", "rx: handshake refused (${a.why}) from ${pkt.socketAddress}")
                }
                continue
            }
            // Before a key exists NOTHING else is read: there is no plaintext
            // window. After it, a datagram that fails to open is not dispatched.
            if (!crypto.established) { crypto.notePreKeyRx(); continue }
            // `b`, NOT `buf`: a relayed datagram has already been unwrapped
            // out of its 4-byte channel header, and decrypting from offset 0
            // would feed the header to AES-GCM.
            val opened = crypto.open(b.copyOf(n))
            if (opened == null) {
                // A recognised magic in the clear while a key exists: an old
                // build on the far end, or someone probing. Counted, never used.
                if (magic == Wire.MAGIC || magic == Wire.VMAGIC || magic == Wire.TMAGIC ||
                    magic == Wire.KMAGIC || magic == Wire.SMAGIC || magic == Wire.BMAGIC) crypto.notePlaintextRx()
                continue
            }
            System.arraycopy(opened, 0, plainBuf, 0, opened.size)
            b = plainBuf; n = opened.size
            magic = Wire.magic(b, n)
            when (magic) {
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
                            peerRxLost = r.lost; peerRxRecovered = r.recovered
                            peerReportsLoss = true
                            val owd = (tsync.bestRttMs ?: 0.0) / 2
                            floor.noteFar(peerVoice(), transitMs = owd,
                                voicing = if (r.status and Wire.ST_VOICING != 0) true else false)
                            floor.noteFarEndProb(Wire.endProb(r.endProbByte))
                            // Consumed only where this end acts on vision at
                            // all; RECORDED either way, so a live call can say
                            // whether the bit ever crossed.
                            peerSeenTalking = r.status and Wire.ST_SEEN_TALKING != 0
                            floor.farSeenTalking =
                                if (peerSeenTalkingSeen) peerSeenTalking else null
                            if (peerSeenTalking) peerSeenTalkingSeen = true
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
                    // The redundant tail, if the sender carried one: seq-1.
                    val redOff = Wire.audioPayloadEnd(b, n, h)
                    if (h.seq > 0 && n > redOff + 8 && !ring.present(h.seq - 1)) {
                        val rCap = Wire.u64(b, redOff)
                        val at = redOff + 8
                        var ok = false
                        if (h.lp) {
                            val m = b[at].toInt() and 0xff
                            if (n >= at + 1 + m) {
                                val block = b.copyOfRange(at + 1, at + 1 + m)
                                if (Lpc.decode(block, m, frames, lpcOut)) {
                                    for (i in 0 until frames) fbuf[i] = lpcOut[i] / 32767.0f; ok = true
                                }
                            }
                        } else if (h.pcm16) {
                            if (n >= at + frames * 2) {
                                for (i in 0 until frames) {
                                    val v = ((b[at + 2 * i].toInt() and 0xff) or (b[at + 2 * i + 1].toInt() shl 8)).toShort()
                                    fbuf[i] = v / 32767.0f
                                }
                                ok = true
                            }
                        } else if (n >= at + frames * 4) {
                            for (i in 0 until frames) fbuf[i] = java.lang.Float.intBitsToFloat(Wire.u32(b, at + 4 * i))
                            ok = true
                        }
                        if (ok) {
                            ring.write(h.seq - 1, rCap, fbuf, frames)
                            if (ring.present(h.seq - 1)) ring.recovered++
                        }
                    }
                }
                Wire.VMAGIC -> {
                    val h = Wire.videoHeader(b, n) ?: continue
                    val len = n - Wire.VHDR
                    if (len <= 0) continue
                    video.offer(h, b, Wire.VHDR, len)?.let { (payload, cap) ->
                        firstVideoSeen = true
                        // Off this thread. Invoking the decoder here stopped
                        // audio being received for the length of every video
                        // frame — the jitter buffer grew and was right to.
                        val q = decodeQueue
                        if (q != null) q.submit(payload, payload.size, cap)
                        else onVideoFrame?.invoke(payload, cap)
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
                Wire.SMAGIC -> {
                    val t = Wire.parseText(b, n) ?: continue
                    onText?.invoke(t.text, t.final, t.listening)
                }
                Wire.KMAGIC -> { keyAsksIn++; onKeyframeRequest?.invoke() }
                Wire.BMAGIC -> { onState?.invoke("peer left"); ended = true; holding = false; Metrics.count("peer_bye") }
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

    /** One capture block: cancel, classify, apply the floor, put it on the wire. */
    fun captureBlock(x: FloatArray, n: Int) {
        capFrames += n
        floorBlocks++
        if (floor.state == Floor.State.THEIRS) floorHeldBlocks++
        // Subtract before classifying: the bar the classifier builds is made
        // from what is LEFT after cancellation, so a person under a cancelled
        // echo is heard rather than explained away.
        // The RAW microphone, for the estimator, before anything is subtracted.
        echoAim.noteCapture(x, n)
        if (speakers) {
            aec.process(x, n, emitRing, emitW, emitRing.size)
            gate.echoResidual = aec.residual
            // The floor's speaker-duplex gate reads the canceller (Audio.swift
            // 1116-1119). These two were declared on the floor and fed by
            // nothing, so the gate could never open.
            floor.aecErleDb = aec.erleDb
            floor.aecEchoPath = aec.echoPathNow
        } else {
            gate.echoResidual = 1f
            floor.aecErleDb = 0.0
            floor.aecEchoPath = 1f
        }
        floor.speakers = speakers
        // The mouth outranks the correlation, and in one direction only.
        gate.mouthSays = visualKnown && visualVoice
        // The prior is computed on THIS machine's own voice, and travels: it
        // is applied where the gate is, which is the far end's floor.
        var sum = 0.0
        for (i in 0 until n) sum += x[i].toDouble() * x[i]
        predict.noteLoud(kotlin.math.sqrt(sum / n).toFloat())
        gate.process(x, n)
        floor.speakers = speakers
        floor.nearVisualVoice = visualKnown && visualVoice
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
            val carry = redundancy && havePrev
            val len = Wire.packAudio(seq, cap, pcmScratch, Wire.FPP,
                pcm16 = sendPcm16, lp = sendLp, out = sendScratch,
                redundant = if (carry) prevBlock else null, redundantCap = prevCap)
            if (carry) redundantSent++
            sendSealed(sendScratch, len)
            System.arraycopy(pcmScratch, 0, prevBlock, 0, Wire.FPP); prevCap = cap; havePrev = true
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
