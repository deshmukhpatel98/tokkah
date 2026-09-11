package com.tokkah.kin.net

/**
 * Fixed-capacity percentile tracker ported from mac/Sources/tk/Clock.swift:98.
 * Allocation-free after construction for use on audio threads.
 */
class Quantiles(val cap: Int = 4096) {
    private val v = DoubleArray(cap)
    private var n = 0
    private var wrapped = false

    fun add(x: Double) {
        v[n % cap] = x
        n++
        if (n >= cap) wrapped = true
    }

    val count: Int get() = n

    fun reset() {
        n = 0
        wrapped = false
    }

    fun p(q: Double): Double? {
        val m = minOf(cap, if (wrapped) cap else n)
        if (m <= 0) return null
        val tmp = DoubleArray(m)
        System.arraycopy(v, 0, tmp, 0, m)
        tmp.sort()
        val idx = ((m - 1) * q.coerceIn(0.0, 1.0)).toInt()
        return tmp[idx]
    }
}
