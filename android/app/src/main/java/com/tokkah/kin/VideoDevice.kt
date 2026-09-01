package com.tokkah.kin

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import com.tokkah.kin.net.CallSession
import com.tokkah.kin.net.VideoWire
import java.nio.ByteBuffer

/**
 * Camera2 → MediaCodec H.264 → the wire, and the wire → MediaCodec → a Surface.
 *
 * The encoder settings mirror VideoToolbox in mac/Sources/tk/Video.swift:709-717
 * exactly, because they are product decisions, not defaults:
 *   RealTime               → KEY_LATENCY 1 + KEY_PRIORITY 0 (encode on arrival)
 *   AllowFrameReordering=0 → NO B-FRAMES. A B-frame is a frame you cannot send
 *                            until you have encoded the one after it.
 *   MaxKeyFrameInterval    → keyframes ON DEMAND only (KMAGIC), never on a timer
 *   1280x720 @ 30, High profile, ~1.2 Mbps aiming at visually lossless
 */
class VideoDevice(private val ctx: Context, private val session: CallSession) {
    companion object {
        const val W = 1280
        const val H = 720
        const val FPS = 30
        const val BITRATE = 1_200_000
    }

    @Volatile private var running = false
    private var camera: CameraDevice? = null
    private var encoder: MediaCodec? = null
    private var decoder: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var camThread: HandlerThread? = null
    private var codecThread: HandlerThread? = null
    private var decoderConfigured = false
    private var sps: ByteArray? = null
    private var pps: ByteArray? = null

    var framesEncoded = 0; private set
    var framesDecoded = 0; private set
    var lastError: String? = null; private set
    var facingFront = true

    fun startEncode(): Boolean {
        return try {
            val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, W, H).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, BITRATE)
                setInteger(MediaFormat.KEY_FRAME_RATE, FPS)
                // Keyframes on demand only. A timer would spend bandwidth on
                // frames nobody asked for, and the receiver requests one the
                // moment it needs to start (KMAGIC).
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, Int.MAX_VALUE / 1000)
                setInteger(MediaFormat.KEY_PROFILE,
                    MediaCodecInfo.CodecProfileLevel.AVCProfileHigh)
                setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel31)
                setInteger(MediaFormat.KEY_BITRATE_MODE,
                    MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
                // RealTime: encode on arrival, never batch for quality.
                setInteger(MediaFormat.KEY_LATENCY, 1)
                setInteger(MediaFormat.KEY_PRIORITY, 0)
                // No B-frames. Where the vendor honours it, say it explicitly.
                setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            }
            // The codec's callbacks must NOT land on the main thread: they put
            // packets on the wire, and Android kills network I/O there
            // (NetworkOnMainThreadException, swallowed by the send path — the
            // Mac saw "frags 0" while this end happily encoded 361 frames).
            // It is also a real-time path and has no business on the UI thread.
            val ct = HandlerThread("kin-codec").apply { start() }
            codecThread = ct
            val ch = Handler(ct.looper)
            val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            // setCallback BEFORE configure: that is the documented order for
            // asynchronous mode, and getting it wrong is silent — the codec
            // starts, the camera fills its surface, and no output callback ever
            // arrives (measured: the Mac saw "frags 0" for a whole call).
            enc.setCallback(object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(c: MediaCodec, i: Int) {}
                override fun onOutputBufferAvailable(c: MediaCodec, i: Int, info: MediaCodec.BufferInfo) {
                    val buf = c.getOutputBuffer(i)
                    if (buf != null) onEncoded(buf, info)
                    c.releaseOutputBuffer(i, false)
                }
                override fun onError(c: MediaCodec, e: MediaCodec.CodecException) {
                    lastError = "encoder: ${e.message}"
                }
                override fun onOutputFormatChanged(c: MediaCodec, f: MediaFormat) {
                    // csd-0 / csd-1 are the SPS and PPS. They must ride with
                    // every keyframe, so they are kept, not merely applied once.
                    f.getByteBuffer("csd-0")?.let { sps = bytesOf(it) }
                    f.getByteBuffer("csd-1")?.let { pps = bytesOf(it) }
                }
            }, ch)
            enc.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            inputSurface = enc.createInputSurface()
            enc.start()
            encoder = enc
            android.util.Log.i("kin", "encoder started ${W}x$H @$FPS ${BITRATE / 1000} kbps")
            running = true
            openCamera()
            true
        } catch (e: Exception) { lastError = "video: ${e.message}"; false }
    }

    private fun bytesOf(b: ByteBuffer): ByteArray {
        val out = ByteArray(b.remaining())
        b.duplicate().get(out)
        // csd buffers are Annex-B; the wire wants raw NALs.
        val nals = VideoWire.splitAnnexB(out, 0, out.size)
        return if (nals.isNotEmpty()) nals[0] else out
    }

    private fun onEncoded(buf: ByteBuffer, info: MediaCodec.BufferInfo) {
        if (info.size <= 0) return
        val raw = ByteArray(info.size)
        buf.position(info.offset)
        buf.get(raw, 0, info.size)
        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
            // The config blob: SPS and PPS, kept for the next keyframe.
            val nals = VideoWire.splitAnnexB(raw, 0, raw.size)
            for (n in nals) when (VideoWire.nalType(n)) {
                7 -> sps = n
                8 -> pps = n
            }
            return
        }
        val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
        val sets = if (key) listOfNotNull(sps, pps) else emptyList()
        val avcc = VideoWire.annexBToAvcc(raw, 0, raw.size)
        session.sendVideoFrame(VideoWire.serialize(sets, avcc))
        framesEncoded++
        if (framesEncoded % 60 == 1) {
            android.util.Log.i("kin", "encoded $framesEncoded frames, last ${avcc.size} B key=$key")
        }
    }

    /** The receiver asked for a keyframe (KMAGIC), so make one now. */
    fun requestKeyframe() {
        try {
            encoder?.setParameters(android.os.Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            })
        } catch (_: Exception) {}
    }

    private fun openCamera() {
        val cm = ctx.getSystemService(CameraManager::class.java) ?: return
        val id = cm.cameraIdList.firstOrNull {
            val f = cm.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING)
            if (facingFront) f == CameraMetadata.LENS_FACING_FRONT else f == CameraMetadata.LENS_FACING_BACK
        } ?: cm.cameraIdList.firstOrNull() ?: return
        val t = HandlerThread("kin-cam").apply { start() }
        camThread = t
        val h = Handler(t.looper)
        try {
            cm.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(dev: CameraDevice) {
                    camera = dev
                    val surface = inputSurface ?: return
                    val req = dev.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                        addTarget(surface)
                        set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, android.util.Range(FPS, FPS))
                    }
                    dev.createCaptureSession(listOf(surface),
                        object : android.hardware.camera2.CameraCaptureSession.StateCallback() {
                            override fun onConfigured(s: android.hardware.camera2.CameraCaptureSession) {
                                try { s.setRepeatingRequest(req.build(), null, h) }
                                catch (e: Exception) { lastError = "capture: ${e.message}" }
                            }
                            override fun onConfigureFailed(s: android.hardware.camera2.CameraCaptureSession) {
                                lastError = "camera session failed"
                            }
                        }, h)
                    android.util.Log.i("kin", "camera $id opened")
                }
                override fun onDisconnected(dev: CameraDevice) { dev.close(); camera = null }
                override fun onError(dev: CameraDevice, err: Int) {
                    lastError = "camera error $err"; dev.close(); camera = null
                }
            }, h)
        } catch (e: SecurityException) { lastError = "camera permission"; android.util.Log.e("kin", "camera permission") }
        catch (e: Exception) { lastError = "camera: ${e.message}"; android.util.Log.e("kin", "camera: ${e.message}") }
    }

    // ── decode ───────────────────────────────────────────────────────────────

    fun attachDisplay(surface: Surface) {
        session.onVideoFrame = { payload, _ -> decode(payload, surface) }
    }

    private fun decode(payload: ByteArray, surface: Surface) {
        val f = VideoWire.parse(payload, payload.size) ?: return
        if (!decoderConfigured) {
            // Cold start from a keyframe alone: the parameter sets are in band.
            if (!f.isKeyframe) return
            try {
                val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, W, H)
                for ((i, s) in f.parameterSets.withIndex()) {
                    fmt.setByteBuffer("csd-$i", ByteBuffer.wrap(byteArrayOf(0, 0, 0, 1) + s))
                }
                val d = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
                d.configure(fmt, surface, null, 0)
                d.start()
                decoder = d
                decoderConfigured = true
            } catch (e: Exception) { lastError = "decoder: ${e.message}"; return }
        }
        val d = decoder ?: return
        try {
            val i = d.dequeueInputBuffer(0)
            if (i < 0) return
            val buf = d.getInputBuffer(i) ?: return
            val tmp = ByteArray(f.avcc.size + 64)
            val n = VideoWire.avccToAnnexB(f.avcc, tmp)
            buf.clear(); buf.put(tmp, 0, n)
            d.queueInputBuffer(i, 0, n, System.nanoTime() / 1000, 0)
            val info = MediaCodec.BufferInfo()
            var o = d.dequeueOutputBuffer(info, 0)
            while (o >= 0) {
                d.releaseOutputBuffer(o, true)   // render
                framesDecoded++
                o = d.dequeueOutputBuffer(info, 0)
            }
        } catch (e: Exception) { lastError = "decode: ${e.message}" }
    }

    fun stop() {
        running = false
        try { camera?.close() } catch (_: Exception) {}
        try { encoder?.stop(); encoder?.release() } catch (_: Exception) {}
        try { decoder?.stop(); decoder?.release() } catch (_: Exception) {}
        camThread?.quitSafely()
        codecThread?.quitSafely()
        camera = null; encoder = null; decoder = null; camThread = null; codecThread = null
        decoderConfigured = false
    }
}
