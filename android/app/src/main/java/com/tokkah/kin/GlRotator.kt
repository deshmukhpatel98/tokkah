package com.tokkah.kin

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Turns the camera's landscape frames into a PORTRAIT picture for the encoder.
 *
 * ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
 *
 * A Mac's camera is landscape and its window is landscape, so 1280x720 is the
 * right picture there. A phone held upright is not: the person occupies a tall
 * frame, and sending them as a wide one means the far end either letterboxes
 * most of the screen away or sees a face lying on its side. So Android captures
 * and encodes 720x1280, and the far end reads the size out of the stream's own
 * parameter sets — the wire carries no orientation field and needs none.
 *
 * Camera2 writes sensor-oriented frames straight into whatever Surface it is
 * given, and it will not rotate them. `KEY_ROTATION` does not help either: that
 * is muxer metadata, and there is no muxer here. So the camera writes into a
 * texture, and this draws that texture into the encoder's surface with the
 * rotation applied to the pixels.
 *
 * TWO ROTATIONS, and they are different facts (the same pair the preview has to
 * get right): SENSOR_ORIENTATION is how the sensor is mounted in this phone,
 * and the display rotation is how the person is holding it.
 */
class GlRotator(
    encoderSurface: Surface,
    private val outW: Int,
    private val outH: Int,
) {
    private var egl: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var ctx: EGLContext = EGL14.EGL_NO_CONTEXT
    private var surf: EGLSurface = EGL14.EGL_NO_SURFACE
    private var program = 0
    private var texId = 0
    private var aPos = 0
    private var aTex = 0
    private var uSt = 0
    private var uRot = 0

    /** Where the camera writes. Hand this to the capture session. */
    lateinit var inputTexture: SurfaceTexture; private set
    lateinit var inputSurface: Surface; private set

    /** Degrees to turn the picture, and whether to mirror it (front camera). */
    var rotation = 0
    var mirror = false

    private val stMatrix = FloatArray(16)
    private val rotMatrix = FloatArray(16)

    private val quad = ByteBuffer.allocateDirect(8 * 4).order(ByteOrder.nativeOrder())
        .asFloatBuffer().apply {
            put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)); position(0)
        }
    private val uv = ByteBuffer.allocateDirect(8 * 4).order(ByteOrder.nativeOrder())
        .asFloatBuffer().apply {
            put(floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)); position(0)
        }

    private val vs = """
        attribute vec4 aPos;
        attribute vec4 aTex;
        uniform mat4 uSt;
        uniform mat4 uRot;
        varying vec2 vTex;
        void main() {
          gl_Position = uRot * aPos;
          vTex = (uSt * aTex).xy;
        }
    """
    private val fs = """
        #extension GL_OES_EGL_image_external : require
        precision mediump float;
        varying vec2 vTex;
        uniform samplerExternalOES tex;
        void main() { gl_FragColor = texture2D(tex, vTex); }
    """

    init {
        egl = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        EGL14.eglInitialize(egl, IntArray(1), 0, IntArray(1), 0)
        val cfgs = arrayOfNulls<EGLConfig>(1)
        EGL14.eglChooseConfig(
            egl,
            intArrayOf(
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                0x3040 /* EGL_RECORDABLE_ANDROID */, 1,
                EGL14.EGL_NONE,
            ),
            0, cfgs, 0, 1, IntArray(1), 0,
        )
        ctx = EGL14.eglCreateContext(
            egl, cfgs[0], EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
        surf = EGL14.eglCreateWindowSurface(
            egl, cfgs[0], encoderSurface, intArrayOf(EGL14.EGL_NONE), 0,
        )
        EGL14.eglMakeCurrent(egl, surf, surf, ctx)

        program = link(vs, fs)
        aPos = GLES20.glGetAttribLocation(program, "aPos")
        aTex = GLES20.glGetAttribLocation(program, "aTex")
        uSt = GLES20.glGetUniformLocation(program, "uSt")
        uRot = GLES20.glGetUniformLocation(program, "uRot")

        val t = IntArray(1)
        GLES20.glGenTextures(1, t, 0)
        texId = t[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texId)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        inputTexture = SurfaceTexture(texId)
        // The camera's own buffer stays LANDSCAPE — it is the sensor's shape,
        // and asking for a portrait buffer would make the driver scale rather
        // than rotate. The turn happens here, in one draw.
        inputTexture.setDefaultBufferSize(outH, outW)
        inputSurface = Surface(inputTexture)

        // RELEASED from this thread, or the draw thread cannot have it. An EGL
        // context is current on at most ONE thread, and the frame callback runs
        // on the camera's. Left current here, every draw failed with
        // EGL_BAD_ACCESS and the encoder produced nothing at all — a camera
        // open, a session configured, and zero frames, with nothing thrown.
        EGL14.eglMakeCurrent(egl, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
    }

    /** One frame: pull the newest camera image and draw it, turned. */
    var drawFails = 0; private set

    fun draw(presentationNs: Long) {
        if (!EGL14.eglMakeCurrent(egl, surf, surf, ctx)) {
            // Never silent: a rotator that cannot bind is a camera that sends
            // nothing, and it looks exactly like a camera that is off.
            if (drawFails++ % 60 == 0) {
                android.util.Log.e("kin", "rotator: eglMakeCurrent failed 0x%x"
                    .format(EGL14.eglGetError()))
            }
            return
        }
        inputTexture.updateTexImage()
        inputTexture.getTransformMatrix(stMatrix)

        Matrix.setIdentityM(rotMatrix, 0)
        // Aspect: the camera frame is outH x outW (landscape) and the target is
        // outW x outH (portrait), so after turning it a quarter the long edge
        // is scaled to COVER rather than to fit — a face in a letterbox is not
        // what a phone held upright should send.
        Matrix.rotateM(rotMatrix, 0, -rotation.toFloat(), 0f, 0f, 1f)
        if (mirror) Matrix.scaleM(rotMatrix, 0, -1f, 1f, 1f)
        val turned = rotation % 180 != 0
        val srcAspect = if (turned) outW.toFloat() / outH else outH.toFloat() / outW
        val dstAspect = outW.toFloat() / outH
        if (srcAspect > dstAspect) Matrix.scaleM(rotMatrix, 0, srcAspect / dstAspect, 1f, 1f)
        else Matrix.scaleM(rotMatrix, 0, 1f, dstAspect / srcAspect, 1f)

        GLES20.glViewport(0, 0, outW, outH)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texId)
        GLES20.glUniformMatrix4fv(uSt, 1, false, stMatrix, 0)
        GLES20.glUniformMatrix4fv(uRot, 1, false, rotMatrix, 0)
        GLES20.glEnableVertexAttribArray(aPos)
        GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 0, quad)
        GLES20.glEnableVertexAttribArray(aTex)
        GLES20.glVertexAttribPointer(aTex, 2, GLES20.GL_FLOAT, false, 0, uv)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        // The encoder stamps its output from this, so it has to be the capture
        // time and not now: a presentation stamp taken at draw folds this
        // rotation's own cost into the far end's glass-to-glass.
        android.opengl.EGLExt.eglPresentationTimeANDROID(egl, surf, presentationNs)
        EGL14.eglSwapBuffers(egl, surf)
    }

    fun release() {
        runCatching { inputSurface.release() }
        runCatching { inputTexture.release() }
        if (egl != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(egl, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            runCatching { EGL14.eglDestroySurface(egl, surf) }
            runCatching { EGL14.eglDestroyContext(egl, ctx) }
            runCatching { EGL14.eglTerminate(egl) }
        }
        egl = EGL14.EGL_NO_DISPLAY
    }

    private fun link(v: String, f: String): Int {
        fun shader(type: Int, src: String): Int {
            val s = GLES20.glCreateShader(type)
            GLES20.glShaderSource(s, src)
            GLES20.glCompileShader(s)
            val ok = IntArray(1)
            GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
            check(ok[0] != 0) { "shader: " + GLES20.glGetShaderInfoLog(s) }
            return s
        }
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, shader(GLES20.GL_VERTEX_SHADER, v))
        GLES20.glAttachShader(p, shader(GLES20.GL_FRAGMENT_SHADER, f))
        GLES20.glLinkProgram(p)
        return p
    }
}
