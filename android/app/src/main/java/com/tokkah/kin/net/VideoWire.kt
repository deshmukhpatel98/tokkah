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

    private class SpsBitReader(private val buf: ByteArray) {
        private var bitOffset = 0
        fun readBit(): Int {
            if (bitOffset / 8 >= buf.size) return 0
            val b = buf[bitOffset / 8].toInt() and 0xff
            val bit = (b shr (7 - (bitOffset % 8))) and 1
            bitOffset++
            return bit
        }
        fun readBits(n: Int): Int {
            var v = 0
            for (i in 0 until n) v = (v shl 1) or readBit()
            return v
        }
        fun readUe(): Int {
            var zeros = 0
            while (readBit() == 0 && zeros < 32) zeros++
            if (zeros == 0) return 0
            return (1 shl zeros) - 1 + readBits(zeros)
        }
        fun readSe(): Int {
            val ue = readUe()
            val sign = if (ue and 1 != 0) 1 else -1
            return sign * ((ue + 1) shr 1)
        }
    }

    private fun removeEmulationPrevention(src: ByteArray, start: Int, len: Int): ByteArray {
        val out = ByteArray(len)
        var o = 0
        var i = start
        val end = start + len
        while (i < end) {
            if (i + 2 < end && src[i] == 0.toByte() && src[i + 1] == 0.toByte() && src[i + 2] == 3.toByte()) {
                out[o++] = src[i++]
                out[o++] = src[i++]
                i++
            } else out[o++] = src[i++]
        }
        return out.copyOf(o)
    }

    /** Parses (width, height) out of an H.264 SPS NAL, accounting for cropping. */
    fun parseSps(spsNal: ByteArray): Pair<Int, Int>? = runCatching {
        var off = 0
        while (off + 3 < spsNal.size && spsNal[off] == 0.toByte() && spsNal[off + 1] == 0.toByte()) {
            if (spsNal[off + 2] == 1.toByte()) { off += 3; break }
            if (off + 4 <= spsNal.size && spsNal[off + 2] == 0.toByte() && spsNal[off + 3] == 1.toByte()) { off += 4; break }
            off++
        }
        if (off >= spsNal.size) return null
        if (spsNal[off].toInt() and 0x1f != 7) return null
        val rbsp = removeEmulationPrevention(spsNal, off + 1, spsNal.size - (off + 1))
        val reader = SpsBitReader(rbsp)
        val profileIdc = reader.readBits(8)
        reader.readBits(8) // constraint flags
        reader.readBits(8) // level idc
        reader.readUe()    // seq_parameter_set_id

        if (profileIdc in intArrayOf(100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)) {
            val chromaFormatIdc = reader.readUe()
            if (chromaFormatIdc == 3) reader.readBit()
            reader.readUe() // bit_depth_luma_minus8
            reader.readUe() // bit_depth_chroma_minus8
            reader.readBit() // qpprime_y_zero_transform_bypass_flag
            val seqScalingMatrixPresent = reader.readBit()
            if (seqScalingMatrixPresent != 0) {
                val count = if (chromaFormatIdc != 3) 8 else 12
                for (i in 0 until count) {
                    val seqScalingListPresent = reader.readBit()
                    if (seqScalingListPresent != 0) {
                        val size = if (i < 6) 16 else 64
                        var lastScale = 8
                        var nextScale = 8
                        for (j in 0 until size) {
                            if (nextScale != 0) {
                                val deltaScale = reader.readSe()
                                nextScale = (lastScale + deltaScale + 256) % 256
                            }
                            lastScale = if (nextScale == 0) lastScale else nextScale
                        }
                    }
                }
            }
        }

        reader.readUe() // log2_max_frame_num_minus4
        val picOrderCntType = reader.readUe()
        if (picOrderCntType == 0) {
            reader.readUe() // log2_max_pic_order_cnt_lsb_minus4
        } else if (picOrderCntType == 1) {
            reader.readBit() // delta_pic_order_always_zero_flag
            reader.readSe()  // offset_for_non_ref_pic
            reader.readSe()  // offset_for_top_to_bottom_field
            val numRefFrames = reader.readUe()
            for (i in 0 until numRefFrames) reader.readSe()
        }

        reader.readUe() // max_num_ref_frames
        reader.readBit() // gaps_in_frame_num_value_allowed_flag
        val picWidthInMbsMinus1 = reader.readUe()
        val picHeightInMapUnitsMinus1 = reader.readUe()
        val frameMbsOnlyFlag = reader.readBit()
        if (frameMbsOnlyFlag == 0) reader.readBit()
        reader.readBit() // direct_8x8_inference_flag
        val frameCroppingFlag = reader.readBit()
        var cropLeft = 0; var cropRight = 0; var cropTop = 0; var cropBottom = 0
        if (frameCroppingFlag != 0) {
            cropLeft = reader.readUe()
            cropRight = reader.readUe()
            cropTop = reader.readUe()
            cropBottom = reader.readUe()
        }
        val width = (picWidthInMbsMinus1 + 1) * 16 - (cropLeft + cropRight) * 2
        val height = (2 - frameMbsOnlyFlag) * (picHeightInMapUnitsMinus1 + 1) * 16 - (cropTop + cropBottom) * 2
        if (width > 0 && height > 0) Pair(width, height) else null
    }.getOrNull()
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
