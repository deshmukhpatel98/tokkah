package com.tokkah.kin.net

/**
 * The video payload format, from Video.serialize / VideoNet in
 * mac/Sources/tk (0.113.0):
 *
 *   u8   parameter-set count (0 on a non-keyframe)
 *   per set: u16 LE length, then the raw NAL (no start code)
 *   u32  LE sample length
 *   AVCC sample: repeated [u32 BE NAL length][NAL]
 *
 * Parameter sets ride IN BAND with every keyframe on purpose: a receiver that
 * joins late, or loses the packet that carried them, must be able to start from
 * the next keyframe alone.
 */
object VideoWire {
    class Frame(val parameterSets: List<ByteArray>, val avcc: ByteArray) {
        val isKeyframe get() = parameterSets.isNotEmpty()
    }

    fun serialize(parameterSets: List<ByteArray>, avcc: ByteArray): ByteArray {
        var n = 1 + 4 + avcc.size
        for (p in parameterSets) n += 2 + p.size
        val out = ByteArray(n)
        var at = 0
        out[at++] = minOf(parameterSets.size, 255).toByte()
        for (p in parameterSets) {
            Wire.putU16(out, at, p.size); at += 2
            System.arraycopy(p, 0, out, at, p.size); at += p.size
        }
        Wire.putU32(out, at, avcc.size); at += 4
        System.arraycopy(avcc, 0, out, at, avcc.size)
        return out
    }

    fun parse(b: ByteArray, len: Int): Frame? {
        if (len < 5) return null
        var at = 0
        val count = b[at++].toInt() and 0xff
        val sets = ArrayList<ByteArray>(count)
        for (i in 0 until count) {
            if (at + 2 > len) return null
            val l = Wire.u16(b, at); at += 2
            if (at + l > len) return null
            sets.add(b.copyOfRange(at, at + l)); at += l
        }
        if (at + 4 > len) return null
        val total = Wire.u32(b, at); at += 4
        if (total < 0 || at + total > len) return null
        return Frame(sets, b.copyOfRange(at, at + total))
    }

    /** AVCC (4-byte BE lengths) to Annex-B, which is what MediaCodec eats. */
    fun avccToAnnexB(avcc: ByteArray, out: ByteArray): Int {
        var i = 0
        var o = 0
        while (i + 4 <= avcc.size) {
            val n = ((avcc[i].toInt() and 0xff) shl 24) or ((avcc[i + 1].toInt() and 0xff) shl 16) or
                    ((avcc[i + 2].toInt() and 0xff) shl 8) or (avcc[i + 3].toInt() and 0xff)
            i += 4
            if (n < 0 || i + n > avcc.size || o + 4 + n > out.size) return o
            out[o] = 0; out[o + 1] = 0; out[o + 2] = 0; out[o + 3] = 1
            System.arraycopy(avcc, i, out, o + 4, n)
            o += 4 + n
            i += n
        }
        return o
    }

    /** Annex-B (what MediaCodec emits) to AVCC, which is what the Mac expects. */
    fun annexBToAvcc(b: ByteArray, off: Int, len: Int): ByteArray {
        val nals = splitAnnexB(b, off, len)
        var n = 0
        for (x in nals) n += 4 + x.size
        val out = ByteArray(n)
        var o = 0
        for (x in nals) {
            out[o] = (x.size ushr 24).toByte(); out[o + 1] = (x.size ushr 16).toByte()
            out[o + 2] = (x.size ushr 8).toByte(); out[o + 3] = x.size.toByte()
            System.arraycopy(x, 0, out, o + 4, x.size)
            o += 4 + x.size
        }
        return out
    }

    fun splitAnnexB(b: ByteArray, off: Int, len: Int): List<ByteArray> {
        val out = ArrayList<ByteArray>(4)
        val end = off + len
        var i = off
        var start = -1
        while (i + 3 <= end) {
            val three = b[i].toInt() == 0 && b[i + 1].toInt() == 0 && b[i + 2].toInt() == 1
            val four = i + 4 <= end && b[i].toInt() == 0 && b[i + 1].toInt() == 0 &&
                       b[i + 2].toInt() == 0 && b[i + 3].toInt() == 1
            if (three || four) {
                if (start >= 0) out.add(b.copyOfRange(start, i))
                i += if (four) 4 else 3
                start = i
            } else i++
        }
        if (start in 0 until end) out.add(b.copyOfRange(start, end))
        return out
    }

    /** NAL type of a raw NAL (no start code). 7 = SPS, 8 = PPS, 5 = IDR. */
    fun nalType(nal: ByteArray): Int = if (nal.isEmpty()) -1 else nal[0].toInt() and 0x1f
}

/**
 * Reassembles VMAGIC fragments into whole frames. Port of the receive half of
 * VideoNet.swift: a frame is complete when every fragment of its sequence has
 * landed; incomplete frames age out rather than accumulating.
 */
class VideoAssembler(private val slots: Int = 8) {
    private val MAXFRAG = 4096
    private class Slot {
        var seq = -1
        var nfrag = 0
        var have = 0
        var lastLen = 0
        var bytes = ByteArray(Wire.VPAYLOAD * 48)
        var got = BooleanArray(48)
        var capHost = 0L
        fun room(n: Int) {
            if (n > got.size) got = BooleanArray(n)
            if (n * Wire.VPAYLOAD > bytes.size) bytes = ByteArray(n * Wire.VPAYLOAD)
        }
    }
    private val ring = Array(slots) { Slot() }
    var framesOut = 0; private set
    var fragsIn = 0; private set
    var dropped = 0; private set

    /** Returns the complete payload when this fragment finished a frame. */
    fun offer(h: Wire.VideoHeader, b: ByteArray, off: Int, len: Int): Pair<ByteArray, Long>? {
        fragsIn++
        // MAXFRAG bounds a corrupt header, nothing else: a real keyframe can run
        // to a hundred fragments and a fixed 64 silently discarded every one of
        // them (a 120 KB keyframe never reassembled).
        if (h.nfrag <= 0 || h.nfrag > MAXFRAG || h.frag > h.nfrag) return null
        if (h.isParity) return null                 // parity handled by the sender's XOR
        val s = ring[Math.floorMod(h.seq, slots)]
        if (s.seq != h.seq) {
            if (s.seq >= 0 && s.have < s.nfrag) dropped++
            s.seq = h.seq; s.nfrag = h.nfrag; s.have = 0
            s.room(h.nfrag)
            java.util.Arrays.fill(s.got, false)
            s.capHost = h.capHost
        }
        if (h.frag >= s.got.size || s.got[h.frag]) return null
        val need = h.frag * Wire.VPAYLOAD + len
        if (need > s.bytes.size) s.bytes = s.bytes.copyOf(maxOf(need, s.bytes.size * 2))
        System.arraycopy(b, off, s.bytes, h.frag * Wire.VPAYLOAD, len)
        s.got[h.frag] = true
        s.have++
        if (h.frag == h.nfrag - 1) s.lastLen = len
        if (s.have == s.nfrag && s.lastLen > 0) {
            val total = (s.nfrag - 1) * Wire.VPAYLOAD + s.lastLen
            framesOut++
            val payload = s.bytes.copyOf(total)
            s.seq = -1
            return payload to s.capHost
        }
        return null
    }
}
