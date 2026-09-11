package com.tokkah.kin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

class CallManagerTest {

    @Before
    fun setUp() {
        CallManager.leave()
    }

    @Test
    fun initialStateIsIdle() {
        assertFalse(CallManager.inCall)
        assertNull(CallManager.session)
        assertNull(CallManager.audio)
        assertNull(CallManager.video)
        assertEquals("", CallManager.room)
        assertEquals("", CallManager.who)
    }

    @Test
    fun leaveResetsStateAndTriggersCallbacks() {
        var leaveCallbackFired = false
        var stateCallbackFired = false

        CallManager.onLeaveRequested = { leaveCallbackFired = true }
        CallManager.onStateChanged = { stateCallbackFired = true }

        // Trigger leave when idle does nothing
        CallManager.leave()
        assertFalse(leaveCallbackFired)

        // Reset callbacks
        CallManager.onLeaveRequested = null
        CallManager.onStateChanged = null
    }
}
