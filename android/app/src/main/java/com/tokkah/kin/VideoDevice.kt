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
        /**
         * PORTRAIT, because a phone held upright frames a person tall. The Mac
         * sends 1280x720 because a Mac camera and a Mac window are both
         * landscape; sending that shape from a phone means the far end throws
         * most of its screen away on black bars. The receiver reads the size
         * out of the stream's own parameter sets, so no orientation field is
         * needed on the wire and an older peer needs no change.
         */
        const val W = 720
        const val H = 1280
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
    private var rotator: GlRotator? = null
    private var decoderConfigured = false
    private var sps: ByteArray? = null
    private var pps: ByteArray? = null

    var framesEncoded = 0; private set
    var framesDecoded = 0; private set
    /**
     * The far end's picture size, as the DECODER reports it — not as the
     * encoder was configured. They are not the same claim: a peer can send any
     * size, and a receiver that assumes 16:9 stretches a face the moment one
     * does not. Display.swift uses `.resizeAspect` for exactly this reason.
     */
    var decodedW = 0; private set
    var decodedH = 0; private set
    var onDecodedSize: ((Int, Int) -> Unit)? = null

    /**
     * One frame of the far end, for their picture on the front door. Taken from
     * the DECODED stream on a slow timer, never per frame: the crop and encode
     * are milliseconds, which is nothing at once-a-minute and an eternity in a
     * media callback. Null until something asks for one.
     */
    var wantFaceFor: String? = null
    var onFace: ((String, android.graphics.Bitmap) -> Unit)? = null
    private var lastFaceAt = 0L
    private var faceReader: android.media.ImageReader? = null
    var lastError: String? = null; private set
    var facingFront = true
    private var sensorOrientation = 90

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
            // The camera cannot write a turned picture, so it writes a texture
            // and one GL pass turns it into the encoder's portrait surface.
            val encSurface = enc.createInputSurface()
            val rot = GlRotator(encSurface, W, H)
            rotator = rot
            inputSurface = rot.inputSurface
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
        sensorOrientation = try {
            cm.getCameraCharacteristics(id).get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        } catch (e: Exception) { 90 }
        val t = HandlerThread("kin-cam").apply { start() }
        camThread = t
        val h = Handler(t.looper)
        rotator?.let { r ->
            r.rotation = sensorOrientation
            r.mirror = facingFront
            // Every camera frame becomes one encoder frame, turned. On the
            // camera's own thread, so the draw never sits on the UI.
            r.inputTexture.setOnFrameAvailableListener({
                try { r.draw(System.nanoTime()) }
                catch (e: Exception) { lastError = "rotator: ${e.message}" }
            }, h)
        }
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
        // Chained, not replaced: the face grabber also wants every payload, and
        // whichever was assigned second would otherwise silently win.
        val prior = session.onVideoFrame
        session.onVideoFrame = { payload, cap ->
            decode(payload, surface)
            prior?.invoke(payload, cap)
        }
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
                d.outputFormat.let { of ->
                    val w = runCatching { of.getInteger(MediaFormat.KEY_WIDTH) }.getOrDefault(W)
                    val h = runCatching { of.getInteger(MediaFormat.KEY_HEIGHT) }.getOrDefault(H)
                    if (w > 0 && h > 0) { decodedW = w; decodedH = h; onDecodedSize?.invoke(w, h) }
                }
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
            if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val of = d.outputFormat
                val w = runCatching { of.getInteger(MediaFormat.KEY_WIDTH) }.getOrDefault(0)
                val h = runCatching { of.getInteger(MediaFormat.KEY_HEIGHT) }.getOrDefault(0)
                if (w > 0 && h > 0 && (w != decodedW || h != decodedH)) {
                    decodedW = w; decodedH = h; onDecodedSize?.invoke(w, h)
                }
                o = d.dequeueOutputBuffer(info, 0)
            }
            while (o >= 0) {
                d.releaseOutputBuffer(o, true)   // render
                framesDecoded++
                o = d.dequeueOutputBuffer(info, 0)
            }
        } catch (e: Exception) { lastError = "decode: ${e.message}" }
    }

    /**
     * Their face, once a minute at most, and only when the call KNOWS who it is
     * with — a face filed under a room name would surface under whoever uses
     * that word next.
     */
    private fun maybeTakeFace(surface: Surface) {
        val who = wantFaceFor ?: return
        val now = System.currentTimeMillis()
        if (now - lastFaceAt < 60_000) return
        if (framesDecoded < 60) return          // let the picture settle first
        lastFaceAt = now
        // The decoder renders straight to a SurfaceView, which cannot be read
        // back — so the face comes from a second, tiny decode target rather
        // than from stealing the one the person is watching.
        pendingFaceFor = who
    }

    /** Set when a face is wanted; the next keyframe payload is decoded twice. */
    private var pendingFaceFor: String? = null

    /**
     * Decode one payload into a bitmap, off the display path. Called with a
     * KEYFRAME so it can stand alone.
     */
    fun faceFromKeyframe(payload: ByteArray) {
        val who = pendingFaceFor ?: return
        pendingFaceFor = null
        val f = VideoWire.parse(payload, payload.size) ?: return
        if (!f.isKeyframe) { pendingFaceFor = who; return }
        thread@ Thread {
            try {
                val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, W, H)
                for ((i, sps) in f.parameterSets.withIndex()) {
                    fmt.setByteBuffer("csd-$i", ByteBuffer.wrap(byteArrayOf(0, 0, 0, 1) + sps))
                }
                val reader = android.media.ImageReader.newInstance(
                    W, H, android.graphics.ImageFormat.YUV_420_888, 2,
                )
                val d = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
                d.configure(fmt, reader.surface, null, 0)
                d.start()
                val i = d.dequeueInputBuffer(200_000)
                if (i >= 0) {
                    val tmp = ByteArray(f.avcc.size + 64)
                    val n = VideoWire.avccToAnnexB(f.avcc, tmp)
                    d.getInputBuffer(i)!!.also { it.clear(); it.put(tmp, 0, n) }
                    d.queueInputBuffer(i, 0, n, 0, 0)
                    val info = MediaCodec.BufferInfo()
                    val o = d.dequeueOutputBuffer(info, 400_000)
                    if (o >= 0) {
                        d.releaseOutputBuffer(o, true)
                        Thread.sleep(80)
                        reader.acquireLatestImage()?.use { img ->
                            yuvToBitmap(img)?.let { onFace?.invoke(who, it) }
                        }
                    }
                }
                d.stop(); d.release(); reader.close()
            } catch (e: Exception) { lastError = "face: ${e.message}" }
        }.also { it.isDaemon = true; it.start() }
    }

    private fun yuvToBitmap(img: android.media.Image): android.graphics.Bitmap? = try {
        val y = img.planes[0].buffer
        val u = img.planes[1].buffer
        val v = img.planes[2].buffer
        val nv21 = ByteArray(y.remaining() + u.remaining() + v.remaining())
        y.get(nv21, 0, y.remaining())
        val chromaAt = nv21.size - u.remaining() - v.remaining()
        v.get(nv21, chromaAt, v.remaining())
        u.get(nv21, chromaAt + v.remaining(), u.remaining())
        val yuv = android.graphics.YuvImage(
            nv21, android.graphics.ImageFormat.NV21, img.width, img.height, null,
        )
        val out = java.io.ByteArrayOutputStream()
        yuv.compressToJpeg(android.graphics.Rect(0, 0, img.width, img.height), 85, out)
        val b = out.toByteArray()
        android.graphics.BitmapFactory.decodeByteArray(b, 0, b.size)
    } catch (e: Exception) { null }

    fun stop() {
        running = false
        try { camera?.close() } catch (_: Exception) {}
        try { encoder?.stop(); encoder?.release() } catch (_: Exception) {}
        try { decoder?.stop(); decoder?.release() } catch (_: Exception) {}
        rotator?.release(); rotator = null
        camThread?.quitSafely()
        codecThread?.quitSafely()
        camera = null; encoder = null; decoder = null; camThread = null; codecThread = null
        decoderConfigured = false
    }
}
