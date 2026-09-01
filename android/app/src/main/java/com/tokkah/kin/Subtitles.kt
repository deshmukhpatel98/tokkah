package com.tokkah.kin

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.os.Handler
import android.os.Looper
import com.tokkah.kin.net.CallSession
import com.tokkah.kin.net.Wire

/**
 * Port of the product decision in mac/Sources/tk/Subtitles.swift: when the
 * floor has muted you, the words still get through.
 *
 * THE AUDIO NEVER LEAVES THIS PHONE. Recognition is on-device, and only the
 * text crosses — dozens of bytes, in an SMAGIC packet, sealed like everything
 * else. That is not an optimisation; it is the reason the feature is allowed to
 * exist at all in an app whose whole claim is that the room name never leaves
 * the two devices.
 *
 * It runs only while this end is MUTED or floor-muted. A person who can be
 * heard does not need to be read, and transcribing them anyway would be
 * spending a microphone on something nobody asked for.
 *
 * Android's on-device recognizer is not Whisper and not the Mac's Qwen daemon.
 * It is what the platform gives for free with no network, and where a device
 * cannot do it offline this simply never starts — a caption that silently went
 * to a server would be the one failure this feature must not have.
 */
class Subtitles(private val ctx: Context, private val session: CallSession) {
    private var rec: SpeechRecognizer? = null
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var wanted = false
    @Volatile var lastPartial = ""; private set
    var sent = 0; private set
    var available = false; private set
    var lastError: String? = null; private set

    fun start() {
        if (rec != null) return
        main.post {
            if (!SpeechRecognizer.isRecognitionAvailable(ctx)) {
                lastError = "this phone has no recogniser"
                return@post
            }
            // On-device only. If the device cannot, we do not fall back to a
            // network recogniser: the audio staying here is the feature.
            val r = if (android.os.Build.VERSION.SDK_INT >= 33 &&
                SpeechRecognizer.isOnDeviceRecognitionAvailable(ctx)
            ) {
                SpeechRecognizer.createOnDeviceSpeechRecognizer(ctx)
            } else {
                lastError = "no on-device recogniser — captions stay off rather than " +
                    "sending this microphone to a server"
                return@post
            }
            available = true
            r.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(p: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(v: Float) {}
                override fun onBufferReceived(b: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onError(e: Int) { restart() }
                override fun onEvent(t: Int, p: Bundle?) {}

                override fun onPartialResults(p: Bundle?) {
                    val t = first(p) ?: return
                    if (t == lastPartial) return
                    lastPartial = t
                    // Revised as the recogniser changes its mind: the band on
                    // the far end rewrites rather than appending, so a wrong
                    // first guess is corrected in place instead of stacking up.
                    send(t, final = false)
                }

                override fun onResults(p: Bundle?) {
                    first(p)?.let { send(it, final = true) }
                    lastPartial = ""
                    restart()
                }

                private fun first(p: Bundle?): String? =
                    p?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull()?.takeIf { it.isNotBlank() }
            })
            rec = r
            listen()
        }
    }

    private fun listen() {
        val r = rec ?: return
        val i = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        }
        runCatching { r.startListening(i) }
    }

    private fun restart() {
        if (!wanted) return
        main.postDelayed({ if (wanted) listen() }, 250)
    }

    /** Only the text, and only while this end cannot be heard. */
    private fun send(text: String, final: Boolean) {
        if (!wanted) return
        session.sendText(text.take(180), final = final, listening = true)
        sent++
    }

    /** Called once a block: captions run only while the floor has muted you. */
    fun setMuted(muted: Boolean) {
        if (muted == wanted) return
        wanted = muted
        if (muted) { start(); main.post { listen() } }
        else main.post { runCatching { rec?.stopListening() } }
    }

    fun stop() {
        wanted = false
        main.post {
            runCatching { rec?.destroy() }
            rec = null
        }
    }
}
