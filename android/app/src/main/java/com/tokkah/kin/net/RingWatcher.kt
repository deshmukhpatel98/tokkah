package com.tokkah.kin.net

import kotlin.concurrent.thread

/**
 * Port of the poll half of Watch.swift — the mailbox, held open.
 *
 * The Mac keeps a LaunchAgent alive from login so a call reaches it with the
 * app closed. Android will not keep a bare thread alive like that, so this is
 * only half the feature: it holds the poll while Kin is in front, and a
 * foreground service (and later a push) is what carries the other half. That
 * gap is named on the download page rather than implied.
 *
 * The poll is HELD: `wait=25000` asks the server to sit on the request until
 * something arrives, so a ring costs one round trip rather than up to a whole
 * poll interval. A server that does not hold says so by omitting `waitedMs`,
 * and this drops back to the plain cadence on the strength of that rather than
 * guessing from timing.
 */
class RingWatcher(private val identity: Identity) {
    @Volatile var running = false; private set
    @Volatile var quiet = false; private set
    @Volatile var serverHolds: Boolean? = null; private set
    @Volatile var lastError: String? = null; private set

    var onRing: ((Identity.Ring) -> Unit)? = null
    var onBye: ((Identity.Ring) -> Unit)? = null

    private var t: Thread? = null

    fun start() {
        if (running) return
        running = true
        t = thread(isDaemon = true, name = "kin-ring") { loop() }
    }

    fun stop() {
        running = false
        t = null
    }

    private fun loop() {
        var backoff = 1000L
        while (running) {
            if (!identity.claimed) { Thread.sleep(2000); continue }
            when (val r = identity.pollOnce(HELD_MS)) {
                is Identity.PollOutcome.Answer -> {
                    backoff = 1000
                    serverHolds = r.serverHolds
                    r.quiet?.let { quiet = it }
                    if (r.rings.isNotEmpty()) {
                        android.util.Log.i("kin", "mailbox: ${r.rings.size} ring(s), holds=${r.serverHolds}")
                    }
                    for (ring in r.rings) {
                        // A ring whose signature does not check is not a ring.
                        // The SERVER verifies nothing — that is the design — so
                        // this is the only place the claim is tested.
                        if (!ring.verified) { lastError = "a ring failed its signature"; continue }
                        if (ring.kind == "bye") onBye?.invoke(ring) else onRing?.invoke(ring)
                    }
                    // An old server answers at once; without the hold this
                    // would spin, so fall back to the 5 s cadence it expects.
                    if (serverHolds != true) Thread.sleep(5000)
                }
                is Identity.PollOutcome.Refused -> {
                    lastError = "the mailbox refused this phone"
                    Thread.sleep(30_000)
                }
                is Identity.PollOutcome.RateLimited -> {
                    lastError = "polling too fast"
                    Thread.sleep(30_000)
                }
                else -> {
                    lastError = "the mailbox is unreachable"
                    Thread.sleep(backoff)
                    backoff = minOf(backoff * 2, 30_000)
                }
            }
        }
    }

    companion object { const val HELD_MS = 25_000 }
}
