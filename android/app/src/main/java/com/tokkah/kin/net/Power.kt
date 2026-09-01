package com.tokkah.kin.net

import java.io.File

/**
 * Port of mac/Sources/tk/Power.swift — CPU cost as a RATE, not a total.
 *
 * A total is a number that only grows, so it says nothing about whether the
 * call is expensive right now; and user and system time are kept apart because
 * they answer different questions — our own arithmetic versus the kernel
 * carrying our packets. The first sample is discarded: it spans process start,
 * where every cost is front-loaded and none of it is the call.
 */
class Power {
    private var lastUser = 0L
    private var lastSys = 0L
    private var lastAt = 0L
    private var primed = false

    /** utime and stime in clock ticks, from /proc/self/stat fields 14 and 15. */
    private fun read(): Pair<Long, Long>? = try {
        val f = File("/proc/self/stat").readText()
        // The comm field can contain spaces and parentheses, so parse AFTER
        // the last ')' rather than splitting the whole line.
        val rest = f.substring(f.lastIndexOf(')') + 2).split(" ")
        (rest[11].toLong()) to (rest[12].toLong())
    } catch (e: Exception) { null }

    /** CPU-seconds per wall second since the last call: (user, system). */
    fun sample(): Pair<Double, Double>? {
        val (u, s) = read() ?: return null
        val now = System.nanoTime()
        if (!primed) {
            lastUser = u; lastSys = s; lastAt = now; primed = true
            return null
        }
        val dt = (now - lastAt) / 1e9
        if (dt <= 0) return null
        // 100 Hz is the ticks-per-second every Android kernel uses; there is no
        // sysconf from Kotlin, and guessing wrong scales both numbers equally
        // so the RATIO a reader cares about survives either way.
        val hz = 100.0
        val du = (u - lastUser) / hz / dt
        val ds = (s - lastSys) / hz / dt
        lastUser = u; lastSys = s; lastAt = now
        return du to ds
    }
}
