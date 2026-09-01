package com.tokkah.kin

import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import com.tokkah.kin.net.CallSession
import com.tokkah.kin.net.Wire
import kotlin.concurrent.thread

/**
 * The Android half of Audio.swift: two low-latency streams at 48 kHz mono
 * float, capture and render on their own threads, feeding CallSession's two
 * entry points. The wire packet stays FPP=32 whatever the device block is —
 * Android's fast path will not deliver 0.667 ms callbacks, so a device block is
 * chunked into wire packets rather than the wire being bent to the device.
 *
 * PERFORMANCE_MODE_LOW_LATENCY routes both streams to AAudio's fast path. The
 * mic is UNPROCESSED where the device offers it: the product ships the raw
 * microphone (pure-mic beat Apple's voice processing on sound and by 9.5 ms),
 * and Android's VOICE_COMMUNICATION source would add AEC/AGC/NS we do not want.
 */
class AudioDevice(private val session: CallSession, private val am: AudioManager?) {
    @Volatile private var running = false
    private var record: AudioRecord? = null
    private var track: AudioTrack? = null

    var captureFrames = 0; private set
    var renderFrames = 0; private set
    var lastError: String? = null; private set
    /** What the device actually gave us, in frames — the real block size. */
    var inBurst = 0; private set
    var outBurst = 0; private set

    fun start(): Boolean {
        if (running) return true
        val fmt = AudioFormat.Builder()
            .setSampleRate(Wire.SR)
            .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
            .build()
        val minIn = AudioRecord.getMinBufferSize(Wire.SR, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_FLOAT)
        if (minIn <= 0) { lastError = "no 48 kHz float capture on this device"; return false }
        // UNPROCESSED when the device declares it, else VOICE_RECOGNITION, which
        // is the next least-processed source. Never VOICE_COMMUNICATION.
        val src = if (am?.getProperty("android.media.property.SUPPORT_AUDIO_SOURCE_UNPROCESSED") == "true")
            MediaRecorder.AudioSource.UNPROCESSED else MediaRecorder.AudioSource.VOICE_RECOGNITION
        val rec = try {
            AudioRecord.Builder()
                .setAudioSource(src)
                .setAudioFormat(fmt)
                .setBufferSizeInBytes(minIn * 2)
                .build()
        } catch (e: Exception) { lastError = "mic: ${e.message}"; return false }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            lastError = "microphone permission or device busy"; rec.release(); return false
        }

        val outFmt = AudioFormat.Builder()
            .setSampleRate(Wire.SR)
            .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build()
        val minOut = AudioTrack.getMinBufferSize(Wire.SR, AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_FLOAT)
        val trk = try {
            AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build())
                .setAudioFormat(outFmt)
                .setBufferSizeInBytes(minOut * 2)
                .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        } catch (e: Exception) { lastError = "speaker: ${e.message}"; rec.release(); return false }

        record = rec
        track = trk
        running = true
        // The device's own burst, rounded to a multiple of FPP so a capture
        // block maps to a whole number of wire packets.
        inBurst = maxOf(Wire.FPP, (minIn / 4 / Wire.FPP) * Wire.FPP)
        outBurst = maxOf(Wire.FPP, (minOut / 4 / Wire.FPP) * Wire.FPP)
        session.playout.devBuf = outBurst
        session.speakers = isOnSpeakers()

        trk.play()
        rec.startRecording()
        thread(isDaemon = true, name = "kin-capture") { captureLoop(rec) }
        thread(isDaemon = true, name = "kin-render") { renderLoop(trk) }
        return true
    }

    fun stop() {
        running = false
        try { record?.stop() } catch (_: Exception) {}
        try { track?.stop() } catch (_: Exception) {}
        record?.release(); track?.release()
        record = null; track = null
    }

    /** Headphones have no echo path, and the floor stands down on them. */
    fun isOnSpeakers(): Boolean {
        val devs = am?.getDevices(AudioManager.GET_DEVICES_OUTPUTS) ?: return true
        for (d in devs) when (d.type) {
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_USB_HEADSET -> return false
        }
        return true
    }

    private fun captureLoop(rec: AudioRecord) {
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
        val buf = FloatArray(inBurst)
        while (running) {
            val n = rec.read(buf, 0, buf.size, AudioRecord.READ_BLOCKING)
            if (n <= 0) continue
            captureFrames += n
            session.captureBlock(buf, n)
        }
    }

    private fun renderLoop(trk: AudioTrack) {
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
        val buf = FloatArray(outBurst)
        while (running) {
            session.renderBlock(buf, buf.size)
            val n = trk.write(buf, 0, buf.size, AudioTrack.WRITE_BLOCKING)
            if (n > 0) renderFrames += n
            // Route changes mid-call: headphones come out, and the floor must
            // learn immediately rather than resume a stale belief.
            if (renderFrames % (Wire.SR / 2) < buf.size) session.speakers = isOnSpeakers()
        }
    }
}
