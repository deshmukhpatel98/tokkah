package com.tokkah.kin.net

import java.io.File

/**
 * Port of the half of Crash.swift a phone can have: an unexplained death is a
 * bug (`unexplained-death-is-a-bug`), and a death nobody is told about is not
 * even that. The Mac books every run and reads the system's crash report on the
 * next launch; Android hands a process its own uncaught exception first, so the
 * report is written HERE, to disk, in the last milliseconds — and posted on the
 * next launch, when there is a network and time. Never posted from the dying
 * process: a report that has to survive its own author is written, not sent.
 *
 * Fields are the Mac's (`kind`, `app_version`, `frames`, `reason`), so the
 * dashboard's `crashes` reads a phone's death beside a Mac's.
 */
object Crash {
    private const val LIMIT = 6000

    /** Install the handler. Idempotent; chains to whatever was there. */
    fun arm(dir: File, version: String) {
        val prior = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            runCatching { write(dir, version, t, e) }
            prior?.uncaughtException(t, e)
        }
    }

    private fun write(dir: File, version: String, t: Thread, e: Throwable) {
        val frames = ArrayList<String>()
        var cause: Throwable? = e
        var depth = 0
        while (cause != null && depth < 3) {
            if (depth > 0) frames.add("caused by ${cause.javaClass.name}: ${cause.message}")
            for (f in cause.stackTrace.take(12)) frames.add("$f")
            cause = cause.cause; depth++
        }
        // The worker's route (worker.ts `/mac/crash`) keys a report on
        // `incident` and `install`, and files `exc`, `where`, `os`, `ran_ms`
        // in their own columns; everything else rides in `fields`.
        val incident = (1..16).joinToString("") { "0123456789abcdef".random().toString() }
        val f = linkedMapOf<String, Any?>(
            "incident" to incident,
            "kind" to "crash",
            "app_version" to version,
            "proc" to "kin-android",
            "os" to "Android ${android.os.Build.VERSION.RELEASE}",
            "exc" to e.javaClass.simpleName,
            "where" to (e.stackTrace.firstOrNull()?.toString() ?: "").take(160),
            "thread" to t.name,
            "reason" to "${e.javaClass.name}: ${e.message}".take(400),
            "frames" to frames,
            "ran_ms" to Metrics.sinceLaunch(),
            "at" to System.currentTimeMillis() / 1000.0,
            "facts" to Metrics.snapshot().facts,
        )
        dir.mkdirs()
        var body = Telemetry(dir).encode(f)
        if (body.length > LIMIT) { f["frames"] = frames.take(6); f["dropped"] = listOf("frames>6"); body = Telemetry(dir).encode(f) }
        File(dir, "crash.json").writeText(body)
    }

    /**
     * On launch: if the last run died, say so — to the log and to the fleet —
     * then forget it. The file is removed only once the post is accepted, so a
     * report waits out a bad network rather than evaporating.
     */
    fun reportPrevious(dir: File, telemetry: Telemetry): Boolean {
        val f = File(dir, "crash.json")
        if (!f.isFile) return false
        val body = runCatching { f.readText() }.getOrNull() ?: run { f.delete(); return false }
        android.util.Log.i("kin", "crash: a previous run died -- ${body.take(200)}")
        Metrics.count("crash_reported")
        val fields = parse(body)
        val ok = telemetry.postCrash(fields)
        if (ok) f.delete() else android.util.Log.i("kin", "crash: could not book it yet (${telemetry.lastError}); keeping the report")
        return ok
    }

    /** The file is our own JSON with flat strings/numbers and one string list. */
    private fun parse(body: String): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        val strs = Regex("\"([a-z_]+)\":\"((?:[^\"\\\\]|\\\\.)*)\"").findAll(body)
        for (m in strs) out[m.groupValues[1]] = m.groupValues[2].replace("\\\"", "\"").replace("\\n", "\n").replace("\\\\", "\\")
        val nums = Regex("\"([a-z_]+)\":(-?[0-9.]+)").findAll(body)
        for (m in nums) out[m.groupValues[1]] = m.groupValues[2].toDoubleOrNull()
        Regex("\"frames\":\\[(.*?)\\]").find(body)?.let { m ->
            out["frames"] = Regex("\"((?:[^\"\\\\]|\\\\.)*)\"").findAll(m.groupValues[1]).map { it.groupValues[1] }.toList()
        }
        out["kind"] = "crash"
        // A report written by an older build had no incident id; the route
        // refuses one without. Better booked under a fresh id than kept forever.
        if (out["incident"] !is String) out["incident"] = (1..16).joinToString("") { "0123456789abcdef".random().toString() }
        return out
    }
}
