package com.tokkah.kin

import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import android.view.TextureView

/**
 * The self-view on the front door, before you commit to a call.
 *
 * A TextureView, not a SurfaceView, and that is the whole reason this file
 * exists: a SurfaceView is its own hardware layer, so nothing above it can
 * sample it — the glass card would have had nothing to refract and would have
 * degraded to a flat dark wash. A TextureView draws INTO the view hierarchy, so
 * the backdrop layer can record it and the card really does refract the face
 * behind it. The cost is a frame of latency, which is free here: this picture
 * is a mirror, not a call.
 *
 * The far end's video in-call keeps its SurfaceView, where latency is the
 * product.
 */
class CameraPreview(ctx: Context) : TextureView(ctx), TextureView.SurfaceTextureListener {
    private var camera: CameraDevice? = null
    private var thread: HandlerThread? = null
    var facingFront = true
    var onHint: ((String) -> Unit)? = null

    companion object {
        const val BUF_W = 1280
        const val BUF_H = 720
    }

    init { surfaceTextureListener = this }

    override fun onSurfaceTextureAvailable(st: SurfaceTexture, w: Int, h: Int) {
        fit(w, h); open(st, w, h)
    }
    override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, w: Int, h: Int) = fit(w, h)

    /**
     * Put the sensor's picture the right way up and fill the window with it.
     *
     * Two rotations, and they are different facts: SENSOR_ORIENTATION is how the
     * sensor is mounted in THIS phone (90 on most, 270 on some fronts), and the
     * display rotation is how the person is holding it. A preview that only
     * corrects one of them is upright on the phone it was written on and on its
     * side everywhere else — which no emulator can show, because its fake camera
     * reports 0.
     *
     * Then centre-crop rather than letterbox: a face in a black frame is not the
     * front door this app has.
     */
    private var sensorOrientation = 0

    private fun fit(viewW: Int, viewH: Int) {
        if (viewW <= 0 || viewH <= 0) return
        val display = when (context.display?.rotation) {
            Surface.ROTATION_90 -> 1
            Surface.ROTATION_180 -> 2
            Surface.ROTATION_270 -> 3
            else -> 0
        }
        val view = android.graphics.RectF(0f, 0f, viewW.toFloat(), viewH.toFloat())
        // The buffer is landscape; the window is portrait. Map one onto the
        // other with setRectToRect and then rotate, which is the only ordering
        // that stays correct at every display rotation.
        val buffer = android.graphics.RectF(0f, 0f, BUF_H.toFloat(), BUF_W.toFloat())
        val cx = view.centerX()
        val cy = view.centerY()
        val m = android.graphics.Matrix()
        buffer.offset(cx - buffer.centerX(), cy - buffer.centerY())
        m.setRectToRect(view, buffer, android.graphics.Matrix.ScaleToFit.FILL)
        val scale = maxOf(viewH.toFloat() / BUF_H, viewW.toFloat() / BUF_W)
        m.postScale(scale, scale, cx, cy)
        val turn = (sensorOrientation - display * 90 + 360) % 360
        if (turn != 0) m.postRotate(turn.toFloat(), cx, cy)
        // A mirror is a mirror: your own face, the way a bathroom shows it.
        if (facingFront) m.postScale(-1f, 1f, cx, cy)
        setTransform(m)
    }

    override fun onSurfaceTextureUpdated(st: SurfaceTexture) {}
    override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean { close(); return true }

    private fun open(st: SurfaceTexture, w: Int, h: Int) {
        val cm = context.getSystemService(CameraManager::class.java) ?: return
        val id = try {
            cm.cameraIdList.firstOrNull {
                val f = cm.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING)
                if (facingFront) f == CameraMetadata.LENS_FACING_FRONT
                else f == CameraMetadata.LENS_FACING_BACK
            } ?: cm.cameraIdList.firstOrNull()
        } catch (e: Exception) { null }
        if (id == null) { onHint?.invoke("no camera on this phone"); return }
        sensorOrientation = try {
            cm.getCameraCharacteristics(id).get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        } catch (e: Exception) { 0 }
        fit(width, height)
        st.setDefaultBufferSize(BUF_W, BUF_H)
        val surface = Surface(st)
        val t = HandlerThread("kin-preview").apply { start() }
        thread = t
        val handler = Handler(t.looper)
        try {
            cm.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(dev: CameraDevice) {
                    camera = dev
                    val req = dev.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                        .apply { addTarget(surface) }
                    dev.createCaptureSession(
                        listOf(surface),
                        object : android.hardware.camera2.CameraCaptureSession.StateCallback() {
                            override fun onConfigured(s: android.hardware.camera2.CameraCaptureSession) {
                                try {
                                    s.setRepeatingRequest(req.build(), null, handler)
                                    onHint?.invoke("this is you")
                                } catch (e: Exception) {
                                    onHint?.invoke("the camera would not start")
                                }
                            }
                            override fun onConfigureFailed(s: android.hardware.camera2.CameraCaptureSession) {
                                onHint?.invoke("the camera would not start")
                            }
                        }, handler,
                    )
                }
                override fun onDisconnected(dev: CameraDevice) { dev.close(); camera = null }
                override fun onError(dev: CameraDevice, err: Int) {
                    dev.close(); camera = null
                    onHint?.invoke("the camera is busy in another app")
                }
            }, handler)
        } catch (e: SecurityException) {
            onHint?.invoke("Kin has not been allowed the camera")
        } catch (e: Exception) {
            onHint?.invoke("the camera would not start")
        }
    }

    fun close() {
        try { camera?.close() } catch (_: Exception) {}
        camera = null
        thread?.quitSafely()
        thread = null
    }
}
