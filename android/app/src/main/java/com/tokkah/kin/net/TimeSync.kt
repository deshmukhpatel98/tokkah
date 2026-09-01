package com.tokkah.kin.net

// Port of mac/Sources/tk/TimeSync.swift — NTP-style offset over the media
// socket. Timestamps on the wire are in the Mac's tick units (KinClock).
class TimeSync {
    private class S(val delayNs: Long, val thetaNs: Long)
    private val win = ArrayDeque<S>()
    private val cap = 16
    private val lock = Object()

    var samples = 0; private set
    var lastDelayNs = 0L; private set

    /** peer clock - my clock, from the least-queued sample in the window; null until >=3. */
    val thetaNs: Long?
        get() = synchronized(lock) {
            if (win.size < 3) null else win.minByOrNull { it.delayNs }!!.thetaNs
        }

    val bestRttMs: Double?
        get() = synchronized(lock) { win.minByOrNull { it.delayNs }?.let { it.delayNs / 1e6 } }

    val rttSpreadMs: Double?
        get() = synchronized(lock) {
            if (win.size < 2) null
            else (win.maxOf { it.delayNs } - win.minOf { it.delayNs }) / 1e6
        }

    fun note(t1: Long, t2: Long, t3: Long, t4: Long) {
        // Signed throughout: four numbers from two unrelated epochs.
        val a = KinClock.ns(t2) - KinClock.ns(t1)
        val b = KinClock.ns(t3) - KinClock.ns(t4)
        val theta = (a + b) / 2
        val delay = (KinClock.ns(t4) - KinClock.ns(t1)) - (KinClock.ns(t3) - KinClock.ns(t2))
        // A negative round trip is a corrupt sample: refuse it rather than let
        // it win the minimum and poison theta for the window.
        if (delay < 0) return
        synchronized(lock) {
            win.addLast(S(delay, theta))
            if (win.size > cap) win.removeFirst()
            samples++
            lastDelayNs = delay
        }
    }
}
