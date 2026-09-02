package com.tokkah.kin.net

import java.util.concurrent.atomic.AtomicInteger

/**
 * Port of mac/Sources/tk/Metrics.swift — every control, every phase, counted.
 *
 * A dashboard that carries only rates and averages can say a call was bad. It
 * cannot say WHICH THING a person pressed and whether pressing it did anything,
 * and that is the difference between "audio was poor" and "they pressed mute
 * four times and it never took". The interaction bugs in this codebase lived
 * between the handler and the finger, and none of them would show up in a rate —
 * on Android that list already includes a row that rang the wrong person, a
 * blurred control that ate its own clicks, and a verified ring that drew nothing.
 *
 * Rules this file follows, because analytics that costs latency is a defect:
 *
 *   · NOTHING here allocates or locks on the audio or video path. Counters are
 *     bumped from the main thread (controls) or the report thread, never from a
 *     render callback.
 *   · The beat already leaves once a second. This adds fields to a message that
 *     was being sent anyway; it opens no socket and starts no timer.
 *   · A counter that is zero is still reported, because "nobody pressed it" and
 *     "the field was dropped" must not look the same.
 *
 * ── AND THE RULE ABOVE IS ENFORCED, NOT JUST WRITTEN ────────────────────────
 *
 * The audio thread identifies itself once, and every entry point checks. On the
 * render thread the call takes NO LOCK and returns: a blocked audio callback is
 * a glitch in somebody's ear, and no counter is worth that. It is not silent
 * about it either — [refusedOnAudioThread] rides out on the next beat, so a mark
 * added to a hot path in future shows up as a number rather than as an
 * unexplained stall. Reported, dropped, never blocking.
 */
object Metrics {
    @Volatile private var audioThreadId = 0L
    private val refused = AtomicInteger(0)

    /** Called once by the render callback, the first time it runs. */
    fun claimAudioThread() {
        if (audioThreadId == 0L) audioThreadId = Thread.currentThread().id
    }

    private fun hot(): Boolean {
        val a = audioThreadId
        if (a == 0L || Thread.currentThread().id != a) return false
        refused.incrementAndGet()
        return true
    }

    /** How many telemetry calls were refused for being on the audio thread. */
    val refusedOnAudioThread: Int get() = refused.get()

    private val lock = Any()
    private val taps = LinkedHashMap<String, Int>()
    private val fails = LinkedHashMap<String, Int>()
    private val marks = LinkedHashMap<String, Int>()    // one-shot ms stamps
    private val counts = LinkedHashMap<String, Int>()   // free-form counters
    private val facts = LinkedHashMap<String, String>() // WHAT this call was made WITH

    /**
     * A control was pressed. [ok] false means the press was received and did NOT
     * do its job — a dead control, a refused action, a tap that did not land.
     */
    fun tap(name: String, ok: Boolean = true) {
        if (hot()) return
        synchronized(lock) {
            taps[name] = (taps[name] ?: 0) + 1
            if (!ok) fails[name] = (fails[name] ?: 0) + 1
        }
    }

    /**
     * A named moment, in milliseconds since launch. FIRST WRITER WINS: these are
     * "when did this first happen", and a second write would turn a birth
     * certificate into a health record.
     */
    fun mark(name: String, ms: Int) {
        if (hot()) return
        synchronized(lock) { if (name !in marks) marks[name] = ms }
    }

    fun mark(name: String) = mark(name, sinceLaunch())

    fun count(name: String, n: Int = 1) {
        if (hot()) return
        synchronized(lock) { counts[name] = (counts[name] ?: 0) + n }
    }

    /**
     * ── WHAT THE CALL WAS MADE WITH, NOT JUST HOW IT WENT ───────────────────
     *
     * Rates and counters describe the RESULT. They cannot tell you that the
     * phone with the soft picture was encoding on a software codec because the
     * hardware one refused 720x1280, which looks exactly like "it goes blocky
     * when he moves" and is nothing to do with the network.
     *
     * LAST writer wins, unlike [mark]: a camera can be switched mid-call, and
     * the one being used is the one that matters.
     */
    fun fact(name: String, value: String) {
        if (hot()) return
        synchronized(lock) { facts[name] = value.take(64) }
    }

    fun has(name: String): Boolean = synchronized(lock) { name in marks }

    class Snap(
        val taps: Map<String, Int>,
        val fails: Map<String, Int>,
        val marks: Map<String, Int>,
        val counts: Map<String, Int>,
        val facts: Map<String, String>,
    )

    /**
     * Snapshot for the beat. Sampled ONCE per beat and read many times: two
     * calls would be two different windows sharing one name.
     */
    fun snapshot(): Snap = synchronized(lock) {
        Snap(
            LinkedHashMap(taps), LinkedHashMap(fails), LinkedHashMap(marks),
            LinkedHashMap(counts), LinkedHashMap(facts),
        )
    }

    private val launch = System.currentTimeMillis()

    /** Milliseconds since this process started, which is what `mark` records. */
    fun sinceLaunch(): Int = (System.currentTimeMillis() - launch).toInt()

    /**
     * The five dictionaries as the beat carries them, under the SAME field names
     * the Mac uses — the fleet dashboard reads one schema, and a phone that
     * invented its own would show up as a call with no controls on it.
     */
    fun beatFields(): Map<String, Any?> {
        val m = snapshot()
        return mapOf(
            "taps" to m.taps, "tap_fails" to m.fails, "marks" to m.marks,
            "events" to m.counts, "facts" to m.facts,
            "telemetry_on_audio_thread" to refusedOnAudioThread,
        )
    }
}
