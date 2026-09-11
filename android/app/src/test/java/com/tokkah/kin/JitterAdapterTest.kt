package com.tokkah.kin

import com.tokkah.kin.net.JitterAdapter
import com.tokkah.kin.net.RecvRing
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class JitterAdapterTest {

    @Test
    fun testAdaptiveGrowthOnNearLate() {
        val adapter = JitterAdapter(jitMin = 2, jitMax = 20, shrinkAboveMs = 1.0)
        val ring = RecvRing()
        ring.pos = 0.0

        // Near-late arrivals: packets missed deadline by under 1 packet -> grows
        ring.lateArrivals = 10
        ring.nearLate = 10
        ring.slackWin.add(0.5) // p01 < 1.0
        adapter.step(t = 2.0, r = ring)

        assertEquals(3, adapter.target)
        assertEquals(1, adapter.grows)
    }

    @Test
    fun testRatchetPreventionOnDeepOutliers() {
        val adapter = JitterAdapter(jitMin = 2, jitMax = 20, shrinkAboveMs = 1.0)
        val ring = RecvRing()
        ring.pos = 0.0

        // First near-late step to grow to 3
        ring.lateArrivals = 10
        ring.nearLate = 10
        ring.slackWin.add(0.5)
        adapter.step(t = 2.0, r = ring)
        assertEquals(3, adapter.target)

        // Deep outlier arrivals: 10 packets late by 20 ms (near = 0, deep = 10), margin fine
        ring.lateArrivals += 10
        ring.slackWin.add(3.0) // p01 >= 1.0
        adapter.step(t = 4.0, r = ring)

        assertEquals(1, adapter.deepRefused)
        assertEquals(3, adapter.target)
    }

    @Test
    fun testMonotonicTargetDecay() {
        val adapter = JitterAdapter(jitMin = 2, jitMax = 20, shrinkAboveMs = 1.0)
        val ring = RecvRing()
        ring.pos = 0.0

        // Near-late grows target to 3
        ring.lateArrivals = 10
        ring.nearLate = 10
        ring.slackWin.add(0.5)
        adapter.step(t = 2.0, r = ring)
        assertEquals(3, adapter.target)

        // Monotonic target decay upon network recovery after probeAt
        var decayedToMin = false
        val startT = adapter.probeAt
        for (win in 1..6) {
            ring.slackWin.add(4.5)
            ring.slackWinMin = 3.5 // head = 3.5 - 0.67 = 2.83 > 1.0
            adapter.step(t = startT + win * 2.0, r = ring)
            if (adapter.target == adapter.jitMin) {
                decayedToMin = true
                break
            }
        }

        assertTrue("Target should decay to jitMin upon calm", decayedToMin)
        assertTrue("Adapter should have recorded shrinks", adapter.shrinks >= 1)
        assertEquals(2, adapter.target)
    }
}
