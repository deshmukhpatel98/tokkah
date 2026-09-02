package com.tokkah.kin.net

import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/**
 * Port of mac/Sources/tk/Telemetry.swift — what a call did, so a problem on
 * somebody else's phone is visible at all.
 *
 * NEVER SENT: the room name (it is the encryption salt and never leaves the two
 * devices), any audio or video, anything identifying the person. The install id
 * is a random number made here and kept here.
 *
 * A copy is appended locally BEFORE the request, deliberately: a beat that
 * fails to send is exactly the beat somebody will want to read, and one that
 * exists only in a server nobody can open is how a real complaint about a real
 * call ends up being investigated out of a log.
 */
class Telemetry(private val root: File, private val base: String = Server.base) {
    var enabled = true
    var sent = 0; private set
    var failed = 0; private set
    var lastError: String? = null; private set

    private val idFile get() = File(root, "install.txt")
    private val localFile get() = File(root, "beats.ndjson")

    /** Random per install: repeat calls from one phone group without naming it. */
    val install: String by lazy {
        if (idFile.isFile) idFile.readText().trim().ifEmpty { newInstall() }
        else newInstall()
    }

    private fun newInstall(): String {
        val v = (1..16).joinToString("") { "0123456789abcdef".random().toString() }
        root.mkdirs()
        runCatching { idFile.writeText(v) }
        return v
    }

    /** One call's id, so its beats group. */
    var call: String = newCallId(); private set
    fun newCall() { call = newCallId() }
    private fun newCallId() = (1..12).joinToString("") { "0123456789abcdef".random().toString() }

    private val model = "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}"

    /**
     * Post one beat. [phase] is `live`, `final`, or `watch`; a final beat gets a
     * longer timeout because it is the last thing this process will say.
     */
    fun post(fields: Map<String, Any?>, phase: String = "live", version: String = VERSION) {
        if (!enabled) return
        val f = LinkedHashMap<String, Any?>(fields)
        f["install"] = install
        f["call"] = call
        f["version"] = version
        f["model"] = model
        f["phase"] = phase
        // The platform, because a fleet with two clients in it cannot read a
        // number without knowing which app produced it.
        f["platform"] = "android"
        val body = json(f)
        keep(body)
        thread(isDaemon = true) {
            try {
                val c = URL("$base/api/mac/beat").openConnection() as HttpURLConnection
                c.requestMethod = "POST"
                c.setRequestProperty("content-type", "application/json")
                c.doOutput = true
                // Short: this is a report about a live call, and one that takes
                // ten seconds to deliver is describing the past.
                c.connectTimeout = if (phase == "final") 6000 else 4000
                c.readTimeout = c.connectTimeout
                c.outputStream.use { it.write(body.toByteArray()) }
                if (c.responseCode >= 300) { failed++; lastError = "http ${c.responseCode}" }
                else sent++
            } catch (e: Exception) {
                failed++; lastError = e.message
            }
        }
    }

    /** The same JSON the server gets, appended here first. */
    /**
     * A record that is not a beat: the crash report. Same install id, same
     * version, a different door (`/api/mac/crash`, the Mac's `crashEndpoint`).
     * Blocking, because the caller is about to die or has just come back to
     * life and wants to know it was booked.
     */
    fun postCrash(fields: Map<String, Any?>, version: String = VERSION): Boolean {
        val f = LinkedHashMap<String, Any?>(fields)
        f["install"] = install
        f["version"] = version
        f["model"] = model
        f["platform"] = "android"
        f["reporter"] = "crash"
        val body = json(f)
        return try {
            val c = URL("$base/api/mac/crash").openConnection() as HttpURLConnection
            c.requestMethod = "POST"
            c.setRequestProperty("content-type", "application/json")
            c.doOutput = true
            c.connectTimeout = 6000; c.readTimeout = 6000
            c.outputStream.use { it.write(body.toByteArray()) }
            c.responseCode < 300
        } catch (e: Exception) { lastError = e.message; false }
    }

    fun encode(m: Map<String, Any?>): String = json(m)

    private fun keep(body: String) {
        runCatching {
            root.mkdirs()
            // Bounded, or a long-lived install writes until the disk complains.
            if (localFile.length() > 4L * 1024 * 1024) localFile.delete()
            localFile.appendText(body + "\n")
        }
    }

    private fun json(m: Map<String, Any?>): String = buildString {
        append('{')
        var first = true
        for ((k, v) in m) {
            if (v == null) continue
            if (!first) append(',')
            first = false
            append('"').append(esc(k)).append("\":")
            when (v) {
                is Number, is Boolean -> append(v.toString())
                is Map<*, *> -> append(json(v.entries.associate { it.key.toString() to it.value }))
                // A list is a list, not the string of one: the crash report's
                // frames arrived as "[android.app..." and the dashboard could
                // not read a single line of them.
                is List<*> -> {
                    append('[')
                    v.forEachIndexed { i, e ->
                        if (i > 0) append(',')
                        when (e) {
                            null -> append("null")
                            is Number, is Boolean -> append(e.toString())
                            is Map<*, *> -> append(json(e.entries.associate { it.key.toString() to it.value }))
                            else -> append('"').append(esc(e.toString())).append('"')
                        }
                    }
                    append(']')
                }
                else -> append('"').append(esc(v.toString())).append('"')
            }
        }
        append('}')
    }

    private fun esc(s: String) = s
        .replace("\\", "\\\\").replace("\"", "\\\"")
        .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")

    companion object { const val VERSION = "0.114.0-android" }
}
