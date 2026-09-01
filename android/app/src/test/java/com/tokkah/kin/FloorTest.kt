package com.tokkah.kin

import com.tokkah.kin.net.Floor
import com.tokkah.kin.net.Floor.State
import com.tokkah.kin.net.Floor.Voice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// Ports of Floor.echoStateSelfTest / strict behavior rows from Floor.swift
// (run on the Mac as `tk --floor-test`) — same scenarios, same expected rows.
class FloorTest {
    private fun fresh(): Floor {
        val f = Floor()
        f.cfg.strict = false      // the soft arm, as in echoStateSelfTest
        f.speakers = true
        f.noteFar(Voice.QUIET)
        f.step(0.02, Voice.QUIET)
        return f
    }

    @Test
    fun idleNextToLiveSpeakerDoesNotTransmit() {
        val a = fresh()
        a.notePlayout(live = true)
        val d = a.step(0.02, Voice.QUIET)
        assertEquals(State.IDLE, d.state)
        assertFalse("mic next to a live loudspeaker must not transmit", d.mayTransmit)
        assertTrue("the ear stays open", d.playoutOpen)
    }

    @Test
    fun echoGuardLetsGoAfterTail() {
        val b = fresh()
        b.notePlayout(live = true)
        b.step(0.02, Voice.QUIET)
        var waited = 0.0
        while (waited < 2.0 && !b.step(0.02, Voice.QUIET).mayTransmit) waited += 0.02
        assertTrue("opens ${(waited * 1000).toInt()} ms after quiet", waited > 0.05 && waited < 0.5)
    }

    @Test
    fun bargingInStillWorks() {
        val c = fresh()
        c.notePlayout(live = true)
        c.step(0.02, Voice.QUIET)
        val d = c.step(0.02, Voice.CLAIM)
        assertTrue(d.mayTransmit)
        assertEquals(State.MINE, d.state)
    }

    @Test
    fun ceilingRescuesHeldDownSpeaker() {
        val c2 = Floor()
        c2.cfg.strict = false
        c2.speakers = true
        c2.yieldsOnTie = true
        var held = 0.0
        var last: Floor.Decision? = null
        while (held < 4.0) {
            c2.noteFar(Voice.CLAIM)
            c2.notePlayout(live = true)
            last = c2.step(0.02, Voice.CLAIM)
            held += 0.02
            if (last.state == State.IDLE) break
        }
        assertEquals(State.IDLE, last!!.state)
        assertTrue("they get their sentence back", last.mayTransmit)
    }

    @Test
    fun headphonesAreLeftAlone() {
        val d = fresh()
        d.speakers = false
        d.notePlayout(live = true)
        assertTrue(d.step(0.02, Voice.QUIET).mayTransmit)
    }

    @Test
    fun backchannelStillReachesThem() {
        val bc = fresh()
        bc.notePlayout(live = true)
        bc.step(0.02, Voice.QUIET)
        assertTrue(bc.step(0.02, Voice.BACKCHANNEL).mayTransmit)
    }

    @Test
    fun silentSpeakerIsNotAnEchoPath() {
        val e = fresh()
        assertTrue(e.step(0.02, Voice.QUIET).mayTransmit)
    }

    @Test
    fun staleFarEndFallsBackOpen() {
        val f = Floor()
        f.cfg.strict = false
        f.speakers = true
        f.notePlayout(live = true)
        val d = f.step(2.0, Voice.QUIET)
        assertTrue(d.fallback)
        assertTrue(d.mayTransmit)
    }

    // ── strict arm (the shipping default) ────────────────────────────────────

    @Test
    fun strictIdleIsSilentUntilVoiceTakesIt() {
        val f = Floor()
        f.speakers = true
        f.noteFar(Voice.QUIET)
        val idle = f.step(0.02, Voice.QUIET)
        assertEquals(State.IDLE, idle.state)
        assertFalse("strict idle transmits nothing", idle.mayTransmit)
        // The first block of any voice takes an empty floor — even a backchannel.
        val take = f.step(0.02, Voice.BACKCHANNEL)
        assertEquals(State.MINE, take.state)
        assertTrue(take.mayTransmit)
    }

    @Test
    fun strictEarClosesOneHopIntoMyTurn() {
        val f = Floor()
        f.speakers = true
        f.noteFar(Voice.QUIET)
        f.step(0.02, Voice.QUIET)
        var d = f.step(0.02, Voice.CLAIM)     // floor becomes mine
        assertEquals(State.MINE, d.state)
        assertTrue("ear stays open one hop into my turn", d.playoutOpen)
        var open = 0.0
        while (open < 1.0) {
            f.noteFar(Voice.QUIET)
            d = f.step(0.02, Voice.CLAIM)
            if (!d.playoutOpen) break
            open += 0.02
        }
        assertFalse(d.playoutOpen)
        assertTrue("closed after ~playoutLagMs (60), was ${(open * 1000).toInt()} ms",
            open * 1000 >= 40 && open * 1000 <= 120)
    }

    @Test
    fun strictOnsetGraceLetsAnInterjectionThrough() {
        val f = Floor()
        f.speakers = true
        // They hold the floor.
        f.noteFar(Voice.CLAIM)
        f.step(0.02, Voice.QUIET)
        assertEquals(State.THEIRS, f.state)
        // This end starts speaking: audible during the contest (grace), then
        // the contest itself hands over at strictDeadlockMs of sustained voice.
        var d = f.step(0.02, Voice.CLAIM)
        assertTrue("first syllable is not deleted", d.mayTransmit)
        var t = 0.0
        while (t < 1.0 && f.state != State.MINE) {
            f.noteFar(Voice.CLAIM)
            d = f.step(0.02, Voice.CLAIM)
            t += 0.02
        }
        assertEquals("contest resolves to mine", State.MINE, f.state)
        assertTrue("within ~strictDeadlockMs+grace, was ${(t * 1000).toInt()} ms", t * 1000 <= 400)
    }

    @Test
    fun farPriorReleasesOnlyAfterArming() {
        val f = Floor()
        f.cfg.strict = false
        f.speakers = true
        // A leftover high p at the START of their turn must not fire.
        f.noteFarEndProb(0.9)
        f.noteFar(Voice.CLAIM)
        f.step(0.02, Voice.QUIET)
        assertEquals(State.THEIRS, f.state)
        repeat(5) { f.noteFar(Voice.CLAIM); f.step(0.02, Voice.QUIET) }
        assertEquals("stale 0.9 does not steal the first word", State.THEIRS, f.state)
        assertEquals(0, f.farPredictedReleases)
        // p dips below the threshold during the hold (arms), then rises: release.
        f.noteFarEndProb(0.1)
        f.noteFar(Voice.CLAIM); f.step(0.02, Voice.QUIET)
        f.noteFarEndProb(0.9)
        f.noteFar(Voice.CLAIM); f.step(0.02, Voice.QUIET)
        assertEquals(1, f.farPredictedReleases)
        assertEquals(State.IDLE, f.state)
    }
}
