package com.tokkah.kin.net

// Wire constants and packet layouts, transcribed from mac/Sources/tk/Net.swift.
// Every multi-byte field is LITTLE-ENDIAN (Net.swift stores `.littleEndian`
// throughout). All offsets cited against Net.swift in Kin 0.111.0.
object Wire {
    const val SR = 48000
    const val FPP = 32
    const val RING = 2048
    const val HDR = 20                    // magic(4) seq(4) capHost(8) tag(4)   Net.swift:25
    const val HMAGIC = 0x544B_0006        // key handshake — the only packet in the clear
    const val HPKT = 4 + 32
    const val HPKTX = HPKT + 4            // + capability bits                    Net.swift:34
    const val CAP_PCM16 = 1
    const val CAP_PCM_LP = 2
    const val MAGIC = 0x544B_0001         // audio
    const val VMAGIC = 0x544B_0002        // video fragment
    const val KMAGIC = 0x544B_0003        // keyframe request (8 bytes)
    const val TMAGIC = 0x544B_0005        // time sync + piggybacked state
    const val SMAGIC = 0x544B_0007        // subtitle/cue text
    const val BMAGIC = 0x544B_0008        // in-band goodbye (8 bytes, sent 4x)

    const val VHDR = 24                   // magic(4) seq(4) capHost(8) frag(2) nfrag(2) flags(2) lastLen(2)
    const val VPAYLOAD = 1150

    const val TPKT = 4 + 4 + 8 + 8 + 8    // magic, kind, t1, t2, t3             TimeSync.swift:40
    const val TPKTX = TPKT + 8            // + rxLost(u32) rxRecovered(u32)
    const val TPKTY = TPKTX + 8           // + played(u32) muted(u8) qLevel(u8) status(u8) endProb(u8)

    // Status bits (Net.swift:903-955)
    const val ST_VPAUSED = 1
    const val ST_CAMOFF = 2
    const val ST_BACKCHAN = 4
    const val ST_CLAIM = 8
    const val ST_RINGING = 16
    const val ST_VOICING = 32
    const val ST_SEEN_TALKING = 64

    // Audio tag high bits (Net.swift:512): frames | pcm16<<16 | lp<<17
    const val TAG_PCM16 = 1 shl 16
    const val TAG_LP = 1 shl 17

    fun endProbByte(p: Double): Int = (p.coerceIn(0.0, 1.0) * 255.0 + 0.5).toInt().coerceIn(0, 255)
    fun endProb(b: Int): Double = (b and 0xff) / 255.0

    // ── little-endian primitives over ByteArray ──────────────────────────────
    fun putU32(b: ByteArray, off: Int, v: Int) {
        b[off] = v.toByte(); b[off + 1] = (v shr 8).toByte()
        b[off + 2] = (v shr 16).toByte(); b[off + 3] = (v shr 24).toByte()
    }
    fun putU16(b: ByteArray, off: Int, v: Int) {
        b[off] = v.toByte(); b[off + 1] = (v shr 8).toByte()
    }
    fun putU64(b: ByteArray, off: Int, v: Long) {
        for (i in 0 until 8) b[off + i] = (v ushr (8 * i)).toByte()
    }
    fun u32(b: ByteArray, off: Int): Int =
        (b[off].toInt() and 0xff) or ((b[off + 1].toInt() and 0xff) shl 8) or
        ((b[off + 2].toInt() and 0xff) shl 16) or ((b[off + 3].toInt() and 0xff) shl 24)
    fun u16(b: ByteArray, off: Int): Int =
        (b[off].toInt() and 0xff) or ((b[off + 1].toInt() and 0xff) shl 8)
    fun u64(b: ByteArray, off: Int): Long {
        var v = 0L
        for (i in 0 until 8) v = v or ((b[off + i].toLong() and 0xff) shl (8 * i))
        return v
    }

    fun magic(b: ByteArray, n: Int): Int = if (n >= 4) u32(b, 0) else 0

    // ── handshake ────────────────────────────────────────────────────────────
    fun handshake(myPublic: ByteArray, caps: Int = CAP_PCM16 or CAP_PCM_LP): ByteArray {
        val out = ByteArray(HPKTX)
        putU32(out, 0, HMAGIC)
        System.arraycopy(myPublic, 0, out, 4, 32)
        putU32(out, HPKT, caps)
        return out
    }
    /** Returns (peerKey, caps) or null. Old builds send HPKT bytes: caps read as 0. */
    fun parseHandshake(b: ByteArray, n: Int): Pair<ByteArray, Int>? {
        if (n < HPKT || u32(b, 0) != HMAGIC) return null
        val key = b.copyOfRange(4, 36)
        val caps = if (n >= HPKTX) u32(b, HPKT) else 0
        return key to caps
    }

    // ── audio ────────────────────────────────────────────────────────────────
    // Header: magic seq capHost tag; payload per format. Redundant block rides
    // past the primary payload as capHost(8)+payload (Net.swift:493-537).
    class AudioHeader(val seq: Int, val capHost: Long, val frames: Int, val pcm16: Boolean, val lp: Boolean)

    fun audioHeader(b: ByteArray, n: Int): AudioHeader? {
        if (n < HDR || u32(b, 0) != MAGIC) return null
        val tag = u32(b, 16)
        return AudioHeader(u32(b, 4), u64(b, 8), tag and 0xffff,
            tag and TAG_PCM16 != 0, tag and TAG_LP != 0)
    }
    /** Packs header + payload; [samples] as pcm16+lp when caps allow, exactly like Net.send. */
    fun packAudio(seq: Int, capHost: Long, samples: ShortArray, n: Int,
                  pcm16: Boolean, lp: Boolean, out: ByteArray): Int {
        putU32(out, 0, MAGIC)
        putU32(out, 4, seq)
        putU64(out, 8, capHost)
        putU32(out, 16, n or (if (pcm16) TAG_PCM16 else 0) or (if (lp) TAG_LP else 0))
        var at = HDR
        if (lp) {
            // A compressed block is variable length, so it carries its own length
            // byte, exactly as Net.send does (Net.swift:516-527).
            val m = Lpc.encode(samples, n, lpcScratch)
            out[at] = m.toByte()
            System.arraycopy(lpcScratch, 0, out, at + 1, m)
            at += 1 + m
        } else if (pcm16) {
            for (i in 0 until n) {
                out[at + 2 * i] = (samples[i].toInt() and 0xff).toByte()
                out[at + 2 * i + 1] = ((samples[i].toInt() shr 8) and 0xff).toByte()
            }
            at += n * 2
        } else {
            for (i in 0 until n) {
                val f = java.lang.Float.floatToIntBits(samples[i] / 32767.0f)
                putU32(out, at + 4 * i, f)
            }
            at += n * 4
        }
        return at
    }
    private val lpcScratch = ByteArray(1 + Lpc.MAXN * 2)

    // ── video fragment ───────────────────────────────────────────────────────
    class VideoHeader(val seq: Int, val capHost: Long, val frag: Int, val nfrag: Int,
                      val flags: Int, val lastLen: Int) {
        val isParity get() = flags and 1 != 0
    }
    fun videoHeader(b: ByteArray, n: Int): VideoHeader? {
        if (n < VHDR || u32(b, 0) != VMAGIC) return null
        return VideoHeader(u32(b, 4), u64(b, 8), u16(b, 16), u16(b, 18), u16(b, 20), u16(b, 22))
    }
    fun packVideoFragment(seq: Int, capHost: Long, frag: Int, nfrag: Int,
                          payload: ByteArray, off: Int, len: Int, out: ByteArray): Int {
        putU32(out, 0, VMAGIC); putU32(out, 4, seq); putU64(out, 8, capHost)
        putU16(out, 16, frag); putU16(out, 18, nfrag); putU16(out, 20, 0); putU16(out, 22, 0)
        System.arraycopy(payload, off, out, VHDR, len)
        return VHDR + len
    }

    // ── keyframe request / goodbye: 8 bytes, magic + zero ────────────────────
    fun keyframeRequest(): ByteArray = ByteArray(8).also { putU32(it, 0, KMAGIC) }
    fun goodbye(): ByteArray = ByteArray(8).also { putU32(it, 0, BMAGIC) }

    // ── subtitles / cues ─────────────────────────────────────────────────────
    fun packText(text: String, final: Boolean, listening: Boolean): ByteArray {
        val bytes = text.toByteArray(Charsets.UTF_8)
        val out = ByteArray(7 + bytes.size)
        putU32(out, 0, SMAGIC)
        out[4] = ((if (final) 1 else 0) or (if (listening) 2 else 0)).toByte()
        out[5] = (bytes.size and 0xff).toByte()
        out[6] = (bytes.size shr 8).toByte()
        System.arraycopy(bytes, 0, out, 7, bytes.size)
        return out
    }
    class TextPacket(val text: String, val final: Boolean, val listening: Boolean)
    fun parseText(b: ByteArray, n: Int): TextPacket? {
        if (n < 7 || u32(b, 0) != SMAGIC) return null
        val len = (b[5].toInt() and 0xff) or ((b[6].toInt() and 0xff) shl 8)
        if (n < 7 + len) return null
        val f = b[4].toInt()
        return TextPacket(String(b, 7, len, Charsets.UTF_8), f and 1 != 0, f and 2 != 0)
    }

    // ── time-sync probe / reply, with the piggybacked receive report ─────────
    class RxReport(var lost: Int = 0, var recovered: Int = 0, var played: Int = 0,
                   var muted: Boolean = false, var qLevel: Int = 0, var status: Int = 0,
                   var endProbByte: Int = 0)

    fun packProbe(t1: Long, report: RxReport): ByteArray =
        packT(kind = 0, t1 = t1, t2 = 0, t3 = 0, report)

    fun packReply(t1: Long, t2: Long, t3: Long, report: RxReport): ByteArray =
        packT(kind = 1, t1 = t1, t2 = t2, t3 = t3, report)

    private fun packT(kind: Int, t1: Long, t2: Long, t3: Long, r: RxReport): ByteArray {
        val out = ByteArray(TPKTY)
        putU32(out, 0, TMAGIC)
        putU32(out, 4, kind)
        putU64(out, 8, t1)
        putU64(out, 16, t2)
        putU64(out, 24, t3)
        putU32(out, TPKT, r.lost)
        putU32(out, TPKT + 4, r.recovered)
        putU32(out, TPKTX, r.played)
        out[TPKTX + 4] = if (r.muted) 1 else 0
        out[TPKTX + 5] = r.qLevel.toByte()
        out[TPKTX + 6] = r.status.toByte()
        out[TPKTX + 7] = r.endProbByte.toByte()
        return out
    }

    class TPacket(val kind: Int, val t1: Long, val t2: Long, val t3: Long,
                  val report: RxReport?, val hasState: Boolean)
    fun parseT(b: ByteArray, n: Int): TPacket? {
        if (n < TPKT || u32(b, 0) != TMAGIC) return null
        val kind = u32(b, 4)
        var r: RxReport? = null
        var hasState = false
        if (n >= TPKTX) {
            r = RxReport(lost = u32(b, TPKT), recovered = u32(b, TPKT + 4))
            if (n >= TPKTY) {
                hasState = true
                r.played = u32(b, TPKTX)
                r.muted = b[TPKTX + 4].toInt() == 1
                r.qLevel = b[TPKTX + 5].toInt() and 0xff
                r.status = b[TPKTX + 6].toInt() and 0xff
                r.endProbByte = b[TPKTX + 7].toInt() and 0xff
            }
        }
        return TPacket(kind, u64(b, 8), u64(b, 16), u64(b, 24), r, hasState)
    }
}

// One clock, in the MAC'S UNITS. The Mac applies its own mach timebase (125/3
// on Apple silicon) to timestamp fields from BOTH ends (Clock.ns in
// TimeSync.note), so an Android peer must speak Apple-silicon tick units on the
// wire or it corrupts the Mac's theta and RTT. nanoTime*3/125 here; *125/3 to
// read a duration back. (Intel Macs have a 1/1 timebase — a call against one
// would mis-scale; Kin's fleet is Apple silicon, and the divergence is recorded.)
object KinClock {
    fun now(): Long = System.nanoTime() * 3 / 125
    fun ns(ticks: Long): Long = ticks * 125 / 3
    fun ms(ticks: Long): Double = ns(ticks) / 1e6
    fun msSigned(a: Long, b: Long): Double = if (a >= b) ms(a - b) else -ms(b - a)
}
